//! robot_bmpc.zig - BMPC (Bootstrapped Model Predictive Control) assembled from zimrnum's ingredients.
//!
//! BMPC learns a WORLD MODEL in a latent space - an encoder that turns an observation into a latent state, dynamics
//! that move a latent state forward under an action, a reward head and value heads that read a latent - and it ACTS
//! by planning in that space: at every decision, MPPI searches over short action sequences, scoring each by what the
//! model imagines it would earn. A POLICY network rides along: it proposes plans of its own into every search, and
//! it is trained to imitate the searches' answers (that is the "bootstrapped" part - the planner teaches the policy,
//! the policy gives the planner better places to start). The ingredients each live in zimrnum with their known
//! answers; this file only puts them together.
//!
//! The file holds the agent's six networks, acting (one decision), the replay row, and learning: the world-model
//! update, the policy update and reanalyze. Chapter 9 of the zimrrl tutorial covers all of it with diagrams and
//! worked examples: its opening section shows the whole agent, 9.17 this file's `act`, and 9.18 to 9.20 its learning.
//!
//! ---- THE TWO LOOPS ----
//!
//!     every frame - ACT                                     every update - LEARN
//!       observation -> encoder -> latent                      windows of H rows from the replay
//!       the policy's plans --+                                value targets, from the TARGET heads
//!       MPPI's samples ------+--> scored by imagination       world-model loss -> one clip -> Adam
//!       elites -> refit, 6 rounds -> draw one elite           the policy distilled toward the stored targets
//!       -> the TARGET (kept) -> jittered -> the action        the target heads follow, slowly
//!       -> the replay row: obs | action | reward | next obs | done | terminated | target
//!
//!   Both loops share the networks: LEARN trains them; ACT reads them, frozen, as they are at that moment.
//!
//! ---- ONE DECISION ----
//!
//!   1. The POLICY'S OWN PLANS (`LatentPolicyPlans`) go into the first `policy_candidates` rows of every state's
//!      block of candidates - encode the observation, then let the policy draw an action and the dynamics move the
//!      latent on, step after step. Those rows stay fixed through the whole search.
//!   2. MPPI (`Mppi.plan`) fills every other row from its Gaussian, scores every row by IMAGINATION
//!      (`LatentPlanScorer`: the model's discounted rewards along the plan plus its value where the plan ends), keeps
//!      the elites, refits the Gaussian, and does it again `iterations` times. It starts from the last decision's
//!      plan shifted by one step (the warm start), or from zero where an episode begins.
//!   3. One elite is drawn by the refit's weights; its FIRST action, with the first step's spread, is the decision's
//!      TARGET - what the replay keeps for the policy to imitate. While training, the action actually taken is that
//!      target jittered by spread x noise and clamped to [-1, 1] (`Mppi.explore`); evaluating takes the target as is.
//!
//! The networks are bound FROZEN into the planning graphs: they read the live weights - whatever the last optimiser
//! step left - and never train through a plan.

const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");
const zrl = @import("zrl");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FailingAllocator = std.testing.FailingAllocator;
const testing_allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
const clamp = zm.clamp;
const float64 = zm.float64;
const Rng = zn.Rng;
const Var = zn.Var;
const Tensor = zn.Tensor;
const Graph = zn.Graph;
const Mlp = zn.Mlp;
const Mppi = zrl.Mppi;
const LatentPlanScorer = zrl.LatentPlanScorer;
const PlanObjective = zrl.PlanObjective;
const LatentPolicyPlans = zrl.LatentPolicyPlans;
const CategoricalScalar = zn.CategoricalScalar;
const TanhMeanGaussian = zrl.TanhMeanGaussian;
const RunningScale = zn.RunningScale;
const PolicyDistillationLoss = zrl.PolicyDistillationLoss;
const Params = zn.Params;
const Optimizer = zn.Optimizer;
const SequenceReplay = zrl.SequenceReplay;
const LatentValueTargets = zrl.LatentValueTargets;
const WorldModelLoss = zrl.WorldModelLoss;
const LatentRollout = zrl.LatentRollout;

/// What a decision is for: `explore` while training (the target jittered by spread x noise, BMPC's exploration),
/// `evaluate` to judge the agent (the target itself).
pub const Mode = enum { explore, evaluate };

/// BMPC over the float type `T` (f32 for running, f64 for exact tests).
pub fn Bmpc(comptime T: type) type {
    return struct {
        /// BMPC's constants for `discountFor` (config.yaml: discount_denom, discount_min, discount_max).
        pub const discount_horizon_divisor: T = 5;
        pub const discount_floor: T = 0.95;
        pub const discount_ceiling: T = 0.995;

        /// THE DISCOUNT FROM THE EPISODE'S LENGTH (BMPC's `_get_discount`).
        ///
        /// A discount gamma = (n - 1) / n weighs rewards over an effective horizon of about n = 1 / (1 - gamma) steps.
        /// BMPC sets that horizon to a fifth of the episode, n = L / 5, and clamps the discount to [0.95, 0.995],
        /// which keeps the horizon between 20 and 200 steps.
        ///
        ///     L = 50:     n = 10,    gamma = 0.9, clamped to 0.95
        ///     L = 100:    n = 20,    gamma = 0.95
        ///     L = 500:    n = 100,   gamma = 0.99
        ///     L = 1000:   n = 200,   gamma = 0.995, the upper bound
        pub fn discountFor(steps_per_episode: usize) T {
            const episode_steps: T = @floatFromInt(steps_per_episode);
            const effective_horizon: T = episode_steps / discount_horizon_divisor;
            const discount: T = (effective_horizon - 1) / effective_horizon;
            return clamp(discount, discount_floor, discount_ceiling);
        }

        /// ONE PLANNER'S SETTINGS: how far its plans look, and how widely MPPI searches.
        ///
        /// The agent plans for two jobs: to ACT, and to REANALYZE - re-planning stored states so the policy imitates
        /// fresh answers. BMPC gives both the same planner; EfficientTDMPC configures them apart, looking further
        /// when acting and searching far less in reanalyze, which re-plans many stored states at every round:
        ///
        ///                    horizon    candidates    elites    the policy's plans    objective
        ///     BMPC
        ///       acting          3          512          64              24              final
        ///       reanalyzing     3          512          64              24              final
        ///     EfficientTDMPC
        ///       acting          6          512          64              24              mean over depths
        ///       reanalyzing     3           64           8               3              final
        ///
        /// The planner's horizon is the length of its PLANS. It is independent of `Config.horizon`, the training
        /// window: how many stored steps every sampled window covers.
        pub const PlannerConfig = struct {
            /// The length of a plan, in decisions.
            horizon: usize = 3,
            /// Candidates per state, the policy's plans included.
            candidates: usize = 512,
            /// How many of the candidates are the policy's own plans.
            policy_candidates: usize = 24,
            /// The elites each refit keeps.
            elites: usize = 64,
            /// MPPI's rounds for an action of fewer than 20 dimensions (`iterationsFor`).
            iterations: usize = 6,
            /// How a plan's score is formed: the whole plan then the value at its end (`final`), or the mean over the
            /// plan's prefixes (`mean_over_depths`, EfficientTDMPC's acting objective) - zrl's `PlanObjective`.
            objective: PlanObjective = .final,
            /// beta: each plan's score loses beta standard deviations of the heads' disagreement (zrl's
            /// `LatentPlanScorer`, eq. 10 of EfficientTDMPC). EfficientTDMPC's reanalyze planner uses 10 on tasks whose
            /// episodes can end early; acting never.
            pessimism: T = 0,

            /// From this many action dimensions up, MPPI runs `large_action_extra_iterations` more rounds.
            pub const large_action_width: usize = 20;
            pub const large_action_extra_iterations: usize = 2;

            /// MPPI's rounds for an action of `action_width` dimensions: `iterations`, and two more from 20 dimensions
            /// up - a larger action space takes more refits to settle. BMPC's code, inherited from TD-MPC2's, adds them
            /// at `action_dim >= 20`; the papers write "more than 20", and the code is what produced their numbers.
            ///
            ///     action dimensions    19    20    21
            ///     rounds (iterations 6)  6     8     8
            pub fn iterationsFor(planner: PlannerConfig, action_width: usize) usize {
                if (action_width >= large_action_width) {
                    return planner.iterations + large_action_extra_iterations;
                }
                return planner.iterations;
            }
        };

        /// BMPC's settings - its config.yaml's numbers as the defaults; a task shrinks the widths.
        pub const Config = struct {
            /// The latent state's width, and the hidden width of every network but the encoder (mlp_dim).
            latent_width: usize = 512,
            hidden_width: usize = 512,
            /// The encoder's one hidden layer (enc_dim).
            encoder_hidden_width: usize = 256,
            /// SimNorm's group size on the encoder's and the dynamics' outputs: the latent is a row of little
            /// probability simplices, which keeps it bounded however long a rollout runs.
            simnorm_group: usize = 8,
            /// How many dynamics heads: 1 for BMPC; EfficientTDMPC trains an ensemble of 4 (value-equivalently - every
            /// head's rollout trains the shared reward and value heads), with distinct initial weights.
            dynamics_heads: usize = 1,
            /// How many value heads (num_q), and the dropout on their first hidden layer.
            value_heads: usize = 2,
            value_dropout: T = 0.01,
            /// The reward's and the values' bins: 101 on [-10, 10] in symlog space.
            bins: CategoricalScalar(T) = .{},
            /// The TRAINING WINDOW: the stored steps every sampled window covers - the world model's rollout, the
            /// policy's loss, and the steps reanalyze plans again. BMPC: 3.
            horizon: usize = 3,
            /// The two planners (`PlannerConfig`): the one that acts, and the one reanalyze plans stored states with.
            acting: PlannerConfig = .{},
            reanalyzing: PlannerConfig = .{},
            /// Shared by both planners: the refit's temperature, and the spread's floor and ceiling.
            temperature: T = 0.5,
            min_spread: T = 0.05,
            max_spread: T = 2,
            /// The policy's spread range while acting: log std in [-3, 1].
            spread: TanhMeanGaussian(T).Options = .{},
            /// The discount used by the planner's scores and the value targets. BMPC derives it from the episode's
            /// length (`discountFor`); a task fills it in.
            discount: T,
            /// Learning (config.yaml): windows per update (batch_size), the rollout's per-step weight rho^t, the
            /// loss's three weights, Adam's rate and the encoder's share of it, the clip on the gradient's global
            /// norm, the fraction the target heads follow each update (tau), and how many policy steps a value target
            /// looks ahead (td_horizon).
            windows: usize = 256,
            rho: T = 0.5,
            consistency_weight: T = 20,
            reward_weight: T = 0.1,
            value_weight: T = 0.1,
            learning_rate: T = 3e-4,
            encoder_rate_scale: T = 0.3,
            gradient_clip: T = 20,
            target_follow: T = 0.01,
            lookahead: usize = 1,
            /// The policy update: the weight of the entropy bonus (BMPC: 1e-4, multiplied by the number of action
            /// dimensions) and the epsilon of the policy's Adam optimiser (BMPC: 1e-5; larger than the world model's
            /// 1e-8, it damps the steps taken on very small gradients).
            entropy_coefficient: T = 1e-4,
            policy_epsilon: T = 1e-5,
            /// Reanalyze: on every `reanalyze_interval`-th update outside pretraining, the first `reanalyze_windows`
            /// windows of the batch are planned again at all H steps, with the policy's plans drawn using
            /// `exploration_spread` (log std in [-2, 1] instead of [-3, 1]).
            reanalyze_interval: usize = 10,
            reanalyze_windows: usize = 20,
            exploration_spread: TanhMeanGaussian(T).Options = .{ .log_std_low = -2, .log_std_high = 1 },

            /// BMPC's configuration - Table 2's BMPC column, which is every field's default - with the discount BMPC
            /// derives from the episode's length (`discountFor`).
            pub fn bmpc(episode_length: usize) Config {
                return .{ .discount = discountFor(episode_length) };
            }

            /// EfficientTDMPC's configuration - Table 2's EfficientTDMPC column: BMPC's, with four dynamics heads
            /// trained value-equivalently, the acting planner looking six decisions ahead and scoring a plan by the
            /// mean over its prefixes (`mean_over_depths`), and reanalyze searching an eighth as widely (64
            /// candidates, 8 elites, 3 of them the policy's plans) with the final objective. Reanalyze re-plans many
            /// stored states at every round and dominates the training time; the narrower search keeps that time
            /// close to BMPC's.
            /// `episodes_can_end_early`: whether the task can end an episode before its length (a fall) - then the
            /// reanalyze planner is pessimistic, beta = 10.
            pub fn efficientTdmpc(episode_length: usize, episodes_can_end_early: bool) Config {
                var config: Config = .bmpc(episode_length);
                config.dynamics_heads = 4;
                config.acting.horizon = 6;
                config.acting.objective = .mean_over_depths;
                config.reanalyzing = .{ .horizon = 3, .candidates = 64, .policy_candidates = 3, .elites = 8 };
                // Pessimism pays where episodes can end early - the policy learns to stay where the model is sure -
                // and costs elsewhere (the paper's fig. 5): beta 10 there, 0 otherwise.
                config.reanalyzing.pessimism = if (episodes_can_end_early) 10 else 0;
                return config;
            }
        };

        /// BMPC's seeding constants (online_trainer.py: `seed_steps = max(1000, 5 x episode_length)`), counted in
        /// frames: five whole episodes in every environment, and never fewer than 1000 frames.
        pub const seed_episodes: usize = 5;
        pub const min_seed_frames: usize = 1000;

        /// BMPC'S TRAINING SCHEDULE: SEEDING, ONE BURST, THEN STEADY UPDATES.
        ///
        /// A FRAME is one step of every environment at once. With S seed frames, E environments and an
        /// update-to-data ratio u (updates per environment step), a run goes through three phases:
        ///
        ///     frame     0       1       ...   S-2     S-1     |  S        S+1      S+2      ...
        ///     actions   random  random  ...   random  random  |  planned  planned  planned
        ///     updates   -       -       ...   -       burst   |  E x u    E x u    E x u
        ///                                             ^
        ///                                   pretraining: the world model only
        ///
        ///   SEEDING, frames 0 to S-1. Random actions and no updates. No planner has answered for these steps,
        ///   so every row stores the empty target N(0, 1).
        ///
        ///   THE BURST, after frame S-1. Many updates at once, as PRETRAINING: the world model learns from the
        ///   seeded data while the policy and reanalyze wait. Every stored target is still the empty one, so
        ///   imitating the targets would teach the policy nothing, and re-planning with an untrained model would
        ///   store nothing better.
        ///
        ///   STEADY, from frame S. The planner acts, and every frame is followed by E x u updates.
        ///
        /// HOW LONG TO SEED: FIVE EPISODES IN EVERY ENVIRONMENT
        ///
        /// BMPC seeds its one environment for max(5 x episode length, 1000) steps: at least five whole episodes,
        /// so the world model has seen episodes from their start to their end before the planner relies on it.
        /// With E environments the count is in FRAMES, so that every environment completes those episodes. Three
        /// environments with episodes of L = 4 steps (the 1000-frame floor set aside for the picture):
        ///
        ///     frame    0   4   8   12  16  20
        ///     env 0    [...|...|...|...|...]     five episodes
        ///     env 1    [...|...|...|...|...]     five episodes
        ///     env 2    [...|...|...|...|...]     five episodes
        ///
        /// Dividing the 20 seed steps among the environments instead would stop after 7 frames, with no
        /// environment past its second episode - and with 8 environments and episodes of 200 steps it would stop
        /// after 125 frames, before any episode had ended at all.
        ///
        /// HOW MANY UPDATES: THE RATIO u FROM THE BURST ON
        ///
        /// Seeding gathers S x E steps and makes no updates, so the burst catches up with S x E x u of them: one
        /// update for every seeded step, times u. Each later frame adds E steps and E x u updates. From the burst
        /// on, the updates made are exactly u times the steps gathered:
        ///
        ///     after frame S - 1 + k:   updates = S x E x u + k x E x u = u x (S + k) x E = u x steps
        ///
        /// With one environment and u = 1 this is torch's schedule (online_trainer.py): seed_steps random steps,
        /// a burst of seed_steps updates, then one update per step. (Torch's loop acts randomly while
        /// step <= seed_steps, one step more than S; the burst is the same.)
        ///
        ///     E = 1, u = 1, L = 1000:   5000 seed frames, a burst of 5000, then 1 update per frame
        ///     E = 8, u = 1, L = 200:    1000 seed frames (8000 steps), a burst of 8000, then 8 per frame
        ///     E = 8, u = 2, L = 200:    1000 seed frames, a burst of 16 000, then 16 per frame
        ///
        /// A schedule can also be written out directly - a short test run seeds for a handful of frames. With no
        /// seed frames at all there is no burst, and the planner acts from frame 0.
        pub const Schedule = struct {
            /// S: the frames of random actions, numbered from 0.
            seed_frames: usize,
            /// The pretraining burst, run after the last seed frame.
            burst_updates: usize,
            /// E x u: the updates after every frame from S on.
            updates_per_frame: usize,

            /// What a frame's actions are and what follows it.
            pub const Frame = struct {
                /// Whether the planner chose the frame's actions (false: random, while seeding).
                planned: bool,
                /// How many updates follow the frame.
                updates: usize,
                /// Whether those updates are pretraining: the world model only.
                pretraining: bool,
            };

            /// BMPC's schedule for `environments` stepping together, episodes of `episode_length` steps, and
            /// `update_to_data` updates per environment step.
            pub fn bmpc(
                environments: usize,
                episode_length: usize,
                update_to_data: usize,
            ) Schedule {
                const seed_frames: usize = @max(seed_episodes * episode_length, min_seed_frames);
                const updates_per_frame: usize = environments * update_to_data;
                return .{
                    .seed_frames = seed_frames,
                    .burst_updates = seed_frames * updates_per_frame,
                    .updates_per_frame = updates_per_frame,
                };
            }

            /// Frame `frame`'s actions and the updates after it - one column of the timeline above.
            pub fn at(self: Schedule, frame: usize) Frame {
                if (frame >= self.seed_frames) {
                    return .{ .planned = true, .updates = self.updates_per_frame, .pretraining = false };
                }
                // Seeding, so seed_frames >= 1 here: the burst follows the last seed frame only.
                const last_seed_frame: bool = frame == self.seed_frames - 1;
                return .{
                    .planned = false,
                    .updates = if (last_seed_frame) self.burst_updates else 0,
                    .pretraining = last_seed_frame,
                };
            }
        };

        /// The agent's networks. Reward and value heads start with a ZERO last layer, so the model begins by
        /// predicting exactly zero everywhere - early targets are not chased through random noise. The target value
        /// heads start as exact copies of the value heads (`params().clone()`) and later follow them slowly.
        pub const Networks = struct {
            encoder: Mlp(T),
            /// `config.dynamics_heads` dynamics networks (at least one), each initialised from its own random stream.
            /// Training rolls, scores and updates every head; planning reads the first.
            dynamics: []Mlp(T),
            reward: Mlp(T),
            policy: Mlp(T),
            values: []Mlp(T),
            target_values: []Mlp(T),

            pub fn init(
                allocator: Allocator,
                rng: Rng,
                observation_width: usize,
                action_width: usize,
                config: Config,
            ) !Networks {
                const latent: usize = config.latent_width;
                const hidden_width: usize = config.hidden_width;
                const hidden_pair: []const usize = try allocator.dupe(usize, &.{ hidden_width, hidden_width });
                const encoder_hidden: []const usize = try allocator.dupe(usize, &.{config.encoder_hidden_width});
                const encoder: Mlp(T) = try .init(allocator, rng.split(0), .{
                    .input = observation_width,
                    .hidden = encoder_hidden,
                    .output = latent,
                    .output_activation = .{ .sim_norm = config.simnorm_group },
                });
                // Head 0 draws from stream 1, as the single dynamics network always has; head h > 0 from stream 1's own
                // split h - distinct initial weights, the ensemble's first source of disagreement.
                if (config.dynamics_heads == 0) {
                    return error.NoDynamicsHead;
                }
                const dynamics: []Mlp(T) = try allocator.alloc(Mlp(T), config.dynamics_heads);
                for (dynamics, 0..) |*dynamics_head, head| {
                    const dynamics_stream: Rng = if (head == 0) rng.split(1) else rng.split(1).split(@intCast(head));
                    dynamics_head.* = try Mlp(T).init(allocator, dynamics_stream, .{
                        .input = latent + action_width,
                        .hidden = hidden_pair,
                        .output = latent,
                        .output_activation = .{ .sim_norm = config.simnorm_group },
                    });
                }
                const reward: Mlp(T) = try .init(allocator, rng.split(2), .{
                    .input = latent + action_width,
                    .hidden = hidden_pair,
                    .output = config.bins.bin_count,
                    .zero_last = true,
                });
                // The policy's head: a mean and a log spread per action dimension (`TanhMeanGaussian` reads them).
                const policy: Mlp(T) = try .init(allocator, rng.split(3), .{
                    .input = latent,
                    .hidden = hidden_pair,
                    .output = 2 * action_width,
                });
                const values: []Mlp(T) = try allocator.alloc(Mlp(T), config.value_heads);
                const target_values: []Mlp(T) = try allocator.alloc(Mlp(T), config.value_heads);
                for (values, target_values, 0..) |*value, *target, head| {
                    value.* = try Mlp(T).init(allocator, rng.split(@intCast(4 + head)), .{
                        .input = latent,
                        .hidden = hidden_pair,
                        .output = config.bins.bin_count,
                        .first_dropout = config.value_dropout,
                        .zero_last = true,
                    });
                    const copied: zn.Params(T) = try (try value.params(allocator)).clone(allocator);
                    target.* = try value.withParams(copied, allocator);
                }
                return .{
                    .encoder = encoder,
                    .dynamics = dynamics,
                    .reward = reward,
                    .policy = policy,
                    .values = values,
                    .target_values = target_values,
                };
            }
        };

        /// Where a decision's numbers go, `states * action_width` each: the action to take, and the TARGET the
        /// replay keeps - the drawn elite's first action and the first step's spread.
        pub const Decision = struct {
            actions: []T,
            target_means: []T,
            target_spreads: []T,
        };

        /// The planner's answer for one step - what the policy is trained to imitate: per action dimension, the
        /// drawn elite's first action and the first step's spread (`Decision.target_means`, `.target_spreads`).
        pub const Target = struct {
            means: []const T,
            spreads: []const T,
        };

        /// One step of one environment, as it happened.
        pub const Step = struct {
            observation: []const T,
            /// What was ACTED ON - the explored action while training: what the environment saw, so what the
            /// world model must learn to predict from.
            action: []const T,
            reward: T,
            /// The TRUE successor, even when this step ended the episode: the environment reports its final
            /// observation before it resets.
            next_observation: []const T,
            /// The environment's state is final - nothing more can be earned from it.
            terminated: bool,
            /// The episode was cut short by a time limit - the state is not final, the episode just stops.
            truncated: bool,
            /// Null while no planner has answered for this step (BMPC's random warm-up): the row then stores the
            /// EMPTY target, N(0, 1) - no preference, unit spread - which the first reanalyze to reach it replaces.
            target: ?Target,
        };

        /// ONE STEP AS THE REPLAY KEEPS IT - BMPC's row (its jax buffer's layout), one per environment per frame:
        ///
        ///     [ observation | action | reward | next observation | done | terminated | target mean | spread ]
        ///
        /// WHY EACH ROW CARRIES ITS OWN NEXT OBSERVATION. The world model learns to predict, from a step's latent
        /// and action, the latent of what followed. The step that ends an episode is real - its reward and its
        /// successor happened - so it must count in every loss. If rows held only their own observation, a
        /// window would take the NEXT row's observation as this step's successor, and after an episode's end that
        /// is the next episode's first state, after the reset: the model would be taught a jump that never
        /// happens. With the successor in the row, the ending step teaches the true final state, `done` marks it,
        /// and the replay's `finished` masks only the steps AFTER it, which belong to the next episode. A window
        /// is therefore H rows - not H + 1 observations - and each row's target sits in the row it was planned
        /// from, so reanalyze writes back from step 0.
        ///
        /// A WINDOW ACROSS AN EPISODE'S END, worked through (H = 4, the episode ending at step 3):
        ///
        ///       step in the ring:     2      3      4      5
        ///       done column:          0      1      0      0     step 3's next observation: the TRUE final state
        ///       finished:             0      0      1      1     steps 4 and 5 belong to the next episode
        ///
        /// Step 3 counts in every loss; steps 4 and 5 count for nothing in this window (they will in their own).
        ///
        /// done = terminated OR truncated: either way the episode ends at this step. `terminated` alone says the
        /// state is truly final (no value beyond it) - kept for when the model learns to predict endings; BMPC's
        /// own value target does not read it, because its tasks only ever truncate.
        pub const Row = struct {
            observation_width: usize,
            action_width: usize,

            /// 2 observations + 3 action-wide blocks (action, target mean, target spread) + reward, done and
            /// terminated.
            pub fn width(self: Row) usize {
                return 2 * self.observation_width + 3 * self.action_width + 3;
            }

            pub fn actionStart(self: Row) usize {
                return self.observation_width;
            }

            pub fn rewardColumn(self: Row) usize {
                return self.actionStart() + self.action_width;
            }

            pub fn nextObservationStart(self: Row) usize {
                return self.rewardColumn() + 1;
            }

            /// The column `SequenceReplay` reads to know where an episode ended.
            pub fn doneColumn(self: Row) usize {
                return self.nextObservationStart() + self.observation_width;
            }

            pub fn terminatedColumn(self: Row) usize {
                return self.doneColumn() + 1;
            }

            /// Where the target starts - reanalyze's `writeBack` column: the means, then the spreads.
            pub fn targetMeanStart(self: Row) usize {
                return self.terminatedColumn() + 1;
            }

            pub fn targetSpreadStart(self: Row) usize {
                return self.targetMeanStart() + self.action_width;
            }

            /// `step` written into `row` (`width()` values), every column at its place.
            pub fn fill(self: Row, row: []T, step: Step) error{ShapeMismatch}!void {
                const target_widths_ok: bool = if (step.target) |target|
                    target.means.len == self.action_width and target.spreads.len == self.action_width
                else
                    true;
                const shapes_ok: bool = row.len == self.width() and
                    step.observation.len == self.observation_width and step.action.len == self.action_width and
                    step.next_observation.len == self.observation_width and target_widths_ok;
                if (!shapes_ok) {
                    return error.ShapeMismatch;
                }
                @memcpy(row[0..self.observation_width], step.observation);
                @memcpy(row[self.actionStart()..][0..self.action_width], step.action);
                row[self.rewardColumn()] = step.reward;
                @memcpy(row[self.nextObservationStart()..][0..self.observation_width], step.next_observation);
                const episode_ends_here: bool = step.terminated or step.truncated;
                row[self.doneColumn()] = if (episode_ends_here) 1 else 0;
                row[self.terminatedColumn()] = if (step.terminated) 1 else 0;
                const target_means: []T = row[self.targetMeanStart()..][0..self.action_width];
                const target_spreads: []T = row[self.targetSpreadStart()..][0..self.action_width];
                if (step.target) |target| {
                    @memcpy(target_means, target.means);
                    @memcpy(target_spreads, target.spreads);
                } else {
                    // The empty target: N(0, 1) in every action dimension.
                    @memset(target_means, 0);
                    @memset(target_spreads, 1);
                }
            }
        };

        /// A plan scorer and the graph it lives on.
        pub const PlanScoring = struct {
            graph: *Graph(T),
            scorer: LatentPlanScorer(T),
        };

        /// THE PLAN SCORER OVER THE WORLD MODEL'S NETWORKS: the encoder, every dynamics head in `networks`, the reward
        /// head and every value head, bound `.frozen` on a graph of its own - a planner reads the live weights and
        /// never trains them. The actor scores its candidates with one; the cross-scoring diagnostic evaluates plans
        /// with others. The graph and the scorer come from `allocator`, which should be an arena.
        pub fn buildPlanScoring(
            allocator: Allocator,
            networks: Networks,
            observation_width: usize,
            action_width: usize,
            options: LatentPlanScorer(T).Options,
        ) !PlanScoring {
            const graph: *Graph(T) = try allocator.create(Graph(T));
            graph.* = Graph(T).init(allocator);
            const value_bounds: [][]const Var = try allocator.alloc([]const Var, networks.values.len);
            for (networks.values, value_bounds) |value, *bound| {
                bound.* = try value.bind(graph, .frozen, allocator);
            }
            // Every dynamics head scores every candidate: the score is their mean (EfficientTDMPC's eq. 9).
            const dynamics_bounds: [][]const Var = try allocator.alloc([]const Var, networks.dynamics.len);
            for (networks.dynamics, dynamics_bounds) |dynamics_head, *bound| {
                bound.* = try dynamics_head.bind(graph, .frozen, allocator);
            }
            const scorer: LatentPlanScorer(T) = try .build(
                graph,
                networks.encoder,
                try networks.encoder.bind(graph, .frozen, allocator),
                networks.dynamics,
                dynamics_bounds,
                networks.reward,
                try networks.reward.bind(graph, .frozen, allocator),
                networks.values,
                value_bounds,
                observation_width,
                action_width,
                options,
                allocator,
            );
            return .{ .graph = graph, .scorer = scorer };
        }

        /// THE ACTOR: ONE DECISION PER STATE, BY PLANNING IN THE LEARNED MODEL (BMPC's `_plan`, then the action).
        ///
        /// For every state at once, MPPI (`Mppi`) searches over plans of H actions, and every plan is scored by
        /// imagining it in the learned model (`LatentPlanScorer`): no environment is touched while deciding.
        ///
        ///     observation --encoder--> z
        ///        |
        ///        +--> the policy's own plans (24), rolled through the model once - fixed for the whole search
        ///        |
        ///        +--> each round (6; 8 from 20 action dimensions):
        ///        |      the other candidates (488) drawn from N(mean, spread), clamped to [-1, 1]
        ///        |      every candidate scored in the model:  sum_t gamma^t r(z_t, a_t) + gamma^H V(z_H)
        ///        |      the best 64 are the elites, weighted exp(0.5 x (score - best score))
        ///        |      mean and spread <- the elites' weighted mean and deviation, the spread kept in [0.05, 2]
        ///        |
        ///        +--> ONE elite drawn by its weight: its first action and the first step's spread are the TARGET
        ///        |
        ///        +--> the action: the target jittered by spread x N(0, 1) when exploring, the target itself when
        ///             evaluating, clamped to [-1, 1]
        ///
        /// THE CANDIDATES OF ONE STATE (BMPC's defaults), one block of rows per state in `candidate_scores` and in
        /// the scorer's actions:
        ///
        ///     | the policy's plans: rows 0 .. 23 | drawn by MPPI: rows 24 .. 511 |
        ///
        /// THE WARM START. Where an episode goes on, the search starts from the last decision's mean, shifted one step
        /// (that step has been taken); at an episode's first step it starts from 0. The spread starts at its ceiling,
        /// 2, every time. Reanalyze marks every state as an episode's first, so it never warm-starts.
        ///
        /// Built once over frozen handles of the live networks and re-run at every decision. `allocator` should be an
        /// arena: it lives as long as the actor.
        pub const Actor = struct {
            observation_width: usize,
            action_width: usize,
            states: usize,
            mppi: Mppi(T),
            scorer: LatentPlanScorer(T),
            plans: LatentPolicyPlans(T),
            scorer_graph: *Graph(T),
            plans_graph: *Graph(T),
            /// One score per candidate per state, the scorer's: a block of `candidates` scores for each state.
            candidate_scores: []T,
            /// Per state: start this decision's search from the last one's plan (false at an episode's first step).
            warm_starts: []bool,

            pub fn init(
                allocator: Allocator,
                networks: Networks,
                observation_width: usize,
                action_width: usize,
                states: usize,
                config: Config,
                planner: PlannerConfig,
            ) !Actor {
                const mppi: Mppi(T) = try .init(allocator, .{
                    .horizon = planner.horizon,
                    .action_width = action_width,
                    .states = states,
                    .candidates = planner.candidates,
                    .policy_candidates = planner.policy_candidates,
                    .elites = planner.elites,
                    .iterations = planner.iterationsFor(action_width),
                    .temperature = config.temperature,
                    .min_spread = config.min_spread,
                    .max_spread = config.max_spread,
                });
                // The scorer: the encoder, every dynamics head, the reward and value heads, frozen, on its own graph.
                const scorer_options: LatentPlanScorer(T).Options = .{
                    .horizon = planner.horizon,
                    .states = states,
                    .candidates = planner.candidates,
                    .discount = config.discount,
                    .bins = config.bins,
                    .objective = planner.objective,
                    .pessimism = planner.pessimism,
                };
                const scoring: PlanScoring = try buildPlanScoring(
                    allocator,
                    networks,
                    observation_width,
                    action_width,
                    scorer_options,
                );
                // The policy's plans: the encoder, the policy and the dynamics, frozen, on another graph.
                const plans_graph: *Graph(T) = try allocator.create(Graph(T));
                plans_graph.* = Graph(T).init(allocator);
                const plans: LatentPolicyPlans(T) = try .build(
                    plans_graph,
                    networks.encoder,
                    try networks.encoder.bind(plans_graph, .frozen, allocator),
                    networks.dynamics[0],
                    try networks.dynamics[0].bind(plans_graph, .frozen, allocator),
                    networks.policy,
                    try networks.policy.bind(plans_graph, .frozen, allocator),
                    .{
                        .horizon = planner.horizon,
                        .states = states,
                        .plans = planner.policy_candidates,
                        .candidates = planner.candidates,
                        .spread = config.spread,
                    },
                    allocator,
                );
                const candidate_scores: []T = try allocator.alloc(T, states * planner.candidates);
                const warm_starts: []bool = try allocator.alloc(bool, states);
                @memset(warm_starts, false);
                return .{
                    .observation_width = observation_width,
                    .action_width = action_width,
                    .states = states,
                    .mppi = mppi,
                    .scorer = scoring.scorer,
                    .plans = plans,
                    .scorer_graph = scoring.graph,
                    .plans_graph = plans_graph,
                    .candidate_scores = candidate_scores,
                    .warm_starts = warm_starts,
                };
            }

            /// After `act`: the plan the actor chose for `state` - every one of its H actions, the drawn elite's row of
            /// the scorer's actions step by step - into `plan` ([horizon][action width]). Its first action is the
            /// decision's target. `error.NoChosenPlan` before any decision.
            ///
            ///     scorer.actions[0]    ... | row chosen_rows[state] | ...    ->  plan[0 .. A]          (the target)
            ///     scorer.actions[1]    ... | the same row           | ...    ->  plan[A .. 2A]
            ///     ...
            ///     scorer.actions[H-1]  ... | the same row           | ...    ->  plan[(H-1)A .. HA]
            pub fn copyChosenPlan(self: Actor, state: usize, plan: []T) !void {
                if (state >= self.states) {
                    return error.ShapeMismatch;
                }
                const chosen_row: usize = self.mppi.chosen_rows[state];
                if (chosen_row == Mppi(T).not_a_candidate) {
                    return error.NoChosenPlan;
                }
                try self.copyPlanOfRow(chosen_row, plan);
            }

            /// After `act`: the first of the policy's own plans for `state` - its candidate row 0, which the planner's
            /// sampling never overwrites - into `plan` ([horizon][action width]). `error.NoPolicyPlan` when the planner
            /// keeps no policy plans.
            pub fn copyPolicyPlan(self: Actor, state: usize, plan: []T) !void {
                if (state >= self.states) {
                    return error.ShapeMismatch;
                }
                if (self.mppi.options.policy_candidates == 0) {
                    return error.NoPolicyPlan;
                }
                const policy_row: usize = state * self.mppi.options.candidates;
                try self.copyPlanOfRow(policy_row, plan);
            }

            /// Every step's action of one candidate row of the scorer's actions, into `plan` ([horizon][action width]).
            fn copyPlanOfRow(self: Actor, row: usize, plan: []T) !void {
                const horizon: usize = self.scorer.actions.len;
                if (plan.len != horizon * self.action_width) {
                    return error.ShapeMismatch;
                }
                for (self.scorer.actions, 0..) |step_actions, step| {
                    const step_plan: []T = plan[step * self.action_width ..][0..self.action_width];
                    for (step_plan, 0..) |*value, dimension| {
                        value.* = step_actions.at2(row, dimension);
                    }
                }
            }

            /// One decision for every state: `observations` one row per state; `first_steps` true where an episode
            /// has just begun (the search starts from zero there, from the last plan shifted elsewhere).
            ///
            /// The warm start, worked through (horizon 3): last decision's plan of means [0.2, 0.5, -0.1] -> this
            /// decision starts from [0.5, -0.1, 0] - step one has already been taken, every later step moves up one,
            /// the new last step starts at zero. Exploring, worked through: the target 0.6 with spread 0.3 and noise
            /// 1.5 -> 0.6 + 0.45 = 1.05, clamped to 1.0 - the environment gets 1.0, the replay keeps (0.6, 0.3).
            pub fn act(
                self: Actor,
                observations: []const T,
                first_steps: []const bool,
                mode: Mode,
                rng: Rng,
                decision: Decision,
            ) !void {
                const decided_numbers: usize = self.states * self.action_width;
                const shapes_match: bool = observations.len == self.states * self.observation_width and
                    first_steps.len == self.states and decision.actions.len == decided_numbers and
                    decision.target_means.len == decided_numbers and decision.target_spreads.len == decided_numbers;
                if (!shapes_match) {
                    return error.ShapeMismatch;
                }
                @memcpy(self.scorer.observations.data, observations);
                @memcpy(self.plans.observations.data, observations);
                // 1. The policy's own plans into each state's first candidate rows - fixed for the whole search.
                try self.plans.fill(self.plans_graph, rng.split(0), self.scorer.actions);
                // 2. MPPI's search, scored by imagination, warm-started but where an episode begins. Noise-free:
                //    what comes back is the TARGET - the drawn elite's first action, and the first step's spread.
                for (self.warm_starts, first_steps) |*warm_start, first_step| {
                    warm_start.* = !first_step;
                }
                try self.mppi.plan(
                    self.scorer,
                    self.scorer_graph,
                    self.warm_starts,
                    .draw_elite,
                    rng.split(1),
                    null,
                    self.candidate_scores,
                    decision.target_means,
                    decision.target_spreads,
                );
                // 3. What is acted on: the target jittered while training, the target itself when evaluating.
                switch (mode) {
                    .explore => try self.mppi.explore(
                        decision.target_means,
                        decision.target_spreads,
                        rng.split(2),
                        decision.actions,
                    ),
                    .evaluate => @memcpy(decision.actions, decision.target_means),
                }
            }
        };

        /// THE CROSS-SCORING DIAGNOSTIC (EfficientTDMPC's appendix C.1): DOES THE PLANNER EXPLOIT ITS MODEL?
        ///
        /// A planner searching hard against a learned model finds the plans the model OVERRATES - actions whose
        /// predicted value is the model's error rather than the world's. The diagnostic plans the same states twice,
        /// under one dynamics head and under the ensemble, and scores three plans per state - the two chosen plans and
        /// the policy's own - under each model:
        ///
        ///                             under one head    under the ensemble
        ///     the single-head plan        Q                  Q
        ///     the ensemble's plan         Q                  Q
        ///     the policy's plan           Q                  Q
        ///
        /// Delta R = a plan's value minus the policy plan's, averaged over the states, per evaluator (`meanAdvantage`).
        /// A planner that exploits its model shows a large Delta R under the model it planned with and a small one in
        /// the environment: the ensemble's plans should be the less exploited. Every value is the plan's plain
        /// estimate - the final objective, no pessimism: H steps of predicted reward, then the value where the plan
        /// ends. The policy's plan is the first of the policy's own plans, drawn under the first dynamics head with the
        /// same random stream in both planners - the same plan for both.
        pub const CrossScoring = struct {
            /// The plans scored for every state, in this order: an evaluator's row `state x 3 + kind`.
            pub const PlanKind = enum(usize) { single_head_plan = 0, ensemble_plan = 1, policy_plan = 2 };
            pub const plan_kind_count: usize = 3;
            /// The models a plan is scored under.
            pub const Evaluator = enum(usize) { single_head = 0, ensemble = 1 };
            pub const evaluator_count: usize = 2;

            states: usize,
            horizon: usize,
            action_width: usize,
            /// The two planners: the networks seen through their first dynamics head only, and the whole ensemble.
            single_head_actor: Actor,
            ensemble_actor: Actor,
            /// One scorer per model, three candidate rows per state - one per plan kind.
            evaluators: [evaluator_count]PlanScoring,
            /// Every state starts its search afresh: no warm start from an earlier decision.
            episode_starts: []bool,
            decision: Decision,
            /// [states][plan kind][horizon][action width]: every state's three plans.
            plans: []T,
            /// [evaluator][states][plan kind]: each plan's value under each model.
            model_values: []T,
            /// One evaluator's scores, a row per state and plan kind.
            evaluator_scores: []T,

            /// The diagnostic's planners and evaluators for `states` states at once, with the acting planner's
            /// settings. `allocator` should be an arena.
            pub fn init(
                allocator: Allocator,
                networks: Networks,
                observation_width: usize,
                action_width: usize,
                states: usize,
                config: Config,
            ) !CrossScoring {
                const planner: PlannerConfig = config.acting;
                var single_head_networks: Networks = networks;
                single_head_networks.dynamics = networks.dynamics[0..1];
                const single_head_actor: Actor = try .init(
                    allocator,
                    single_head_networks,
                    observation_width,
                    action_width,
                    states,
                    config,
                    planner,
                );
                const ensemble_actor: Actor = try .init(
                    allocator,
                    networks,
                    observation_width,
                    action_width,
                    states,
                    config,
                    planner,
                );
                const evaluator_options: LatentPlanScorer(T).Options = .{
                    .horizon = planner.horizon,
                    .states = states,
                    .candidates = plan_kind_count,
                    .discount = config.discount,
                    .bins = config.bins,
                    .objective = .final,
                    .pessimism = 0,
                };
                const single_head_evaluator: PlanScoring = try buildPlanScoring(
                    allocator,
                    single_head_networks,
                    observation_width,
                    action_width,
                    evaluator_options,
                );
                const ensemble_evaluator: PlanScoring = try buildPlanScoring(
                    allocator,
                    networks,
                    observation_width,
                    action_width,
                    evaluator_options,
                );
                const evaluators = [evaluator_count]PlanScoring{ single_head_evaluator, ensemble_evaluator };
                const episode_starts: []bool = try allocator.alloc(bool, states);
                @memset(episode_starts, true);
                const decided_numbers: usize = states * action_width;
                const plan_numbers: usize = planner.horizon * action_width;
                return .{
                    .states = states,
                    .horizon = planner.horizon,
                    .action_width = action_width,
                    .single_head_actor = single_head_actor,
                    .ensemble_actor = ensemble_actor,
                    .evaluators = evaluators,
                    .episode_starts = episode_starts,
                    .decision = .{
                        .actions = try allocator.alloc(T, decided_numbers),
                        .target_means = try allocator.alloc(T, decided_numbers),
                        .target_spreads = try allocator.alloc(T, decided_numbers),
                    },
                    .plans = try allocator.alloc(T, states * plan_kind_count * plan_numbers),
                    .model_values = try allocator.alloc(T, evaluator_count * states * plan_kind_count),
                    .evaluator_scores = try allocator.alloc(T, states * plan_kind_count),
                };
            }

            /// Plan from `observations` ([states][observation width]) under one head and under the ensemble - the same
            /// states, the same random stream, evaluation mode - gather every state's three plans, and score them under
            /// both models into `model_values`.
            pub fn scoreUnderModels(
                self: CrossScoring,
                observations: []const T,
                rng: Rng,
            ) !void {
                // 1. The two planners decide; each keeps its chosen plans, and the policy's plan is read once.
                try self.single_head_actor.act(observations, self.episode_starts, .evaluate, rng, self.decision);
                for (0..self.states) |state| {
                    try self.single_head_actor.copyChosenPlan(state, self.planOf(state, .single_head_plan));
                }
                try self.ensemble_actor.act(observations, self.episode_starts, .evaluate, rng, self.decision);
                for (0..self.states) |state| {
                    try self.ensemble_actor.copyChosenPlan(state, self.planOf(state, .ensemble_plan));
                    try self.ensemble_actor.copyPolicyPlan(state, self.planOf(state, .policy_plan));
                }
                // 2. Every evaluator scores every state's three plans, one candidate row each:
                //
                //        evaluator rows   | state 0: single-head plan, ensemble plan, policy plan | state 1: ... |
                const values_per_evaluator: usize = self.states * plan_kind_count;
                for (self.evaluators, 0..) |evaluation, evaluator_index| {
                    @memcpy(evaluation.scorer.observations.data, observations);
                    for (0..self.states) |state| {
                        for (0..plan_kind_count) |kind_index| {
                            const kind: PlanKind = @fromBackingInt(@intCast(kind_index));
                            const plan: []const T = self.planOf(state, kind);
                            const evaluator_row: usize = state * plan_kind_count + kind_index;
                            for (evaluation.scorer.actions, 0..) |step_actions, step| {
                                const step_plan: []const T = plan[step * self.action_width ..][0..self.action_width];
                                for (step_plan, 0..) |action_value, dimension| {
                                    step_actions.setAt2(evaluator_row, dimension, action_value);
                                }
                            }
                        }
                    }
                    try evaluation.scorer.score(evaluation.graph, self.evaluator_scores);
                    const evaluator_start: usize = evaluator_index * values_per_evaluator;
                    const evaluator_values: []T = self.model_values[evaluator_start..][0..values_per_evaluator];
                    @memcpy(evaluator_values, self.evaluator_scores);
                }
            }

            /// `state`'s plan of `kind`: [horizon][action width].
            pub fn planOf(self: CrossScoring, state: usize, kind: PlanKind) []T {
                const plan_numbers: usize = self.horizon * self.action_width;
                const plan_index: usize = state * plan_kind_count + @backingInt(kind);
                return self.plans[plan_index * plan_numbers ..][0..plan_numbers];
            }

            /// The value of `state`'s plan of `kind` under `evaluator`.
            pub fn modelValue(
                self: CrossScoring,
                evaluator: Evaluator,
                state: usize,
                kind: PlanKind,
            ) T {
                const values_per_evaluator: usize = self.states * plan_kind_count;
                const evaluator_start: usize = @backingInt(evaluator) * values_per_evaluator;
                return self.model_values[evaluator_start + state * plan_kind_count + @backingInt(kind)];
            }

            /// Delta R under `evaluator`: `kind`'s plan minus the policy's plan, averaged over the states.
            pub fn meanAdvantage(
                self: CrossScoring,
                evaluator: Evaluator,
                kind: PlanKind,
            ) T {
                var advantage_sum: T = 0;
                for (0..self.states) |state| {
                    const plan_value: T = self.modelValue(evaluator, state, kind);
                    const policy_value: T = self.modelValue(evaluator, state, .policy_plan);
                    advantage_sum += plan_value - policy_value;
                }
                const state_count: T = @floatFromInt(self.states);
                return advantage_sum / state_count;
            }
        };

        /// Row `index` of row-major numbers whose rows are `width` wide.
        fn rowOf(data: []T, index: usize, width: usize) []T {
            return data[index * width ..][0..width];
        }

        /// What one world-model update measured: the loss and its three parts after the forward pass, and the
        /// gradient's global norm BEFORE the clip - the number worth logging (a spike says a batch was bad).
        pub const WorldModelReport = struct {
            consistency: T,
            reward: T,
            value: T,
            total: T,
            gradient_norm: T,
        };

        /// THE WORLD MODEL LEARNS - one update (BMPC's `_update`, its world-model half; the policy's half comes next).
        ///
        /// ---- THE PIPELINE ----
        ///
        ///     the replay --sample--> W windows of H rows (step-major), and which steps are `finished`
        ///       |
        ///       +--> the rollout's inputs:  observations [ o_0 | n_0 | n_1 | ... | n_(H-1) ]  - H + 1 blocks of W
        ///       |                           rows (o: a row's observation, n: its NEXT observation)
        ///       |                           actions a_0 .. a_(H-1) - one block of W rows per step
        ///       +--> the targets:           rewards r_t, two-hot (9.3)
        ///       |                           value targets, two-hot - LatentValueTargets from each stored step's TRUE
        ///       |                           latent, through the TARGET heads (9.16)
        ///       v
        ///     encoder(o_0) = z_0 --dynamics--> z_1 --> ... --> z_H        the ROLLOUT, trained (9.4)
        ///     loss = 20 consistency + 0.1 reward + 0.1 value, step t weighted rho^t, finished steps masked (9.5)
        ///     backward --> ONE clip of the global norm at 20 --> Adam, the encoder at 0.3 x the rate
        ///              --> the target heads follow their online twins, 1% of the way
        ///
        /// WHY [ o_0 | n_0 | ... ]: the rollout encodes block 0 as z_0 and compares step t's prediction with the
        /// encoding of block t + 1. Feeding each row's OWN successor makes every step's target the state that really
        /// followed it - at an episode's end the true final state, not the next episode's first (9.9's figure).
        ///
        /// WHY ONE CLIP OVER EVERYTHING: scaling every gradient by the same factor keeps the update's direction and
        /// only shortens it; clipping tensor by tensor would turn it. WHY THE ENCODER SLOWER: everything downstream
        /// reads its latents - a fast-moving encoder shifts the ground under the dynamics, the heads and the planner.
        /// WHY THE TARGET HEADS FOLLOW SLOWLY: the value targets read them, so a target never chases the network it is
        /// training (9.16).
        ///
        /// WORKED NUMBERS: a global gradient norm of 40 is clipped by scaling EVERY gradient by 20 / 40 = 0.5. Adam's
        /// very first step moves each parameter by about its rate whatever the gradient's size (it divides the step by
        /// the gradient's own running size) - 3e-4 for the dynamics and the heads, 0.3 x 3e-4 = 9e-5 for the encoder.
        /// A target-head weight at 1.0 whose online twin is now 2.0 follows to 1.0 + 0.01 x (2.0 - 1.0) = 1.01.
        ///
        /// Built once, like the planner: the world model bound TRAINED on a graph of its own (its gradients are what
        /// the update is for), the value targets on another, frozen. `allocator` should be an arena.
        pub const WorldModelLearner = struct {
            config: Config,
            row: Row,
            graph: *Graph(T),
            /// The rollout's observation input: H + 1 blocks of `config.windows` rows - each window's first
            /// observation, then every step's NEXT observation.
            observations: Tensor(T),
            /// The rollout's actions, one tensor per step, `config.windows` rows each.
            actions: []Tensor(T),
            rollout: LatentRollout(T),
            loss: WorldModelLoss(T),
            /// Every trained parameter of the world model - what the clip measures and scales.
            model_parameters: []const Var,
            encoder_optimizer: Optimizer(T),
            model_optimizer: Optimizer(T),
            targets: LatentValueTargets(T),
            targets_graph: *Graph(T),
            /// The value heads' numbers and their slow copies', for the follow.
            online_value_numbers: []Params(T),
            target_value_numbers: []Params(T),
            /// One update's scratch: where the windows came from, their rows (step-major), which steps are
            /// finished, the value targets, and one step's numbers on their way to two-hots.
            origins: []SequenceReplay(T).WindowOrigin,
            window_rows: []T,
            finished: []T,
            value_target_values: []T,
            step_values: []T,

            pub fn init(
                allocator: Allocator,
                networks: Networks,
                observation_width: usize,
                action_width: usize,
                config: Config,
            ) !WorldModelLearner {
                const horizon: usize = config.horizon;
                const windows: usize = config.windows;
                const row: Row = .{ .observation_width = observation_width, .action_width = action_width };
                // The world model, TRAINED on this graph: the gradients flow into these handles.
                const graph: *Graph(T) = try allocator.create(Graph(T));
                graph.* = Graph(T).init(allocator);
                const encoder_bound: []Var = try networks.encoder.bind(graph, .trained, allocator);
                // Every dynamics head, trained: each rolls the same encoded latent forward on its own.
                const dynamics_bounds: [][]const Var = try allocator.alloc([]const Var, networks.dynamics.len);
                for (networks.dynamics, dynamics_bounds) |dynamics_head, *bound| {
                    bound.* = try dynamics_head.bind(graph, .trained, allocator);
                }
                const reward_bound: []Var = try networks.reward.bind(graph, .trained, allocator);
                const value_bounds: [][]const Var = try allocator.alloc([]const Var, networks.values.len);
                for (networks.values, value_bounds) |value, *bound| {
                    bound.* = try value.bind(graph, .trained, allocator);
                }
                // The rollout's inputs: tensors the graph reads, rewritten before every update.
                const observations: Tensor(T) = try .alloc(allocator, &.{ (horizon + 1) * windows, observation_width });
                observations.fill(0);
                const actions: []Tensor(T) = try allocator.alloc(Tensor(T), horizon);
                const action_inputs: []Var = try allocator.alloc(Var, horizon);
                for (actions, action_inputs) |*step_actions, *input| {
                    step_actions.* = try Tensor(T).alloc(allocator, &.{ windows, action_width });
                    step_actions.fill(0);
                    input.* = try graph.constant(step_actions.*);
                }
                const rollout: LatentRollout(T) = try .build(
                    graph,
                    networks.encoder,
                    encoder_bound,
                    networks.dynamics,
                    dynamics_bounds,
                    try graph.constant(observations),
                    action_inputs,
                    .{ .horizon = horizon, .batch = windows, .rho = config.rho },
                    allocator,
                );
                // The value heads' dropout masks are drawn afresh every update (`resampleDropout`); this seed only
                // makes the first ones.
                const loss: WorldModelLoss(T) = try .build(
                    graph,
                    rollout,
                    action_inputs,
                    networks.reward,
                    reward_bound,
                    networks.values,
                    value_bounds,
                    Rng.init(0),
                    .{
                        .horizon = horizon,
                        .batch = windows,
                        .bins = config.bins.bin_count,
                        .rho = config.rho,
                        .consistency_weight = config.consistency_weight,
                        .reward_weight = config.reward_weight,
                        .value_weight = config.value_weight,
                    },
                    allocator,
                );
                // Two optimisers over disjoint parameters - the encoder at its share of the rate, the rest at the
                // full rate - which is exactly Adam with two parameter groups: its state is per parameter anyway. The
                // model's parameters in one order - every dynamics head, the reward head, every value head - which is
                // also the order the clip sums their squares in.
                const model_group_count: usize = dynamics_bounds.len + 1 + value_bounds.len;
                const model_groups: [][]const Var = try allocator.alloc([]const Var, model_group_count);
                @memcpy(model_groups[0..dynamics_bounds.len], dynamics_bounds);
                model_groups[dynamics_bounds.len] = reward_bound;
                @memcpy(model_groups[dynamics_bounds.len + 1 ..], value_bounds);
                var model_count: usize = 0;
                for (model_groups) |group| {
                    model_count += group.len;
                }
                const model_handles: []Var = try allocator.alloc(Var, model_count);
                var filled: usize = 0;
                for (model_groups) |group| {
                    @memcpy(model_handles[filled..][0..group.len], group);
                    filled += group.len;
                }
                const model_parameters: []Var = try allocator.alloc(Var, encoder_bound.len + model_count);
                @memcpy(model_parameters[0..encoder_bound.len], encoder_bound);
                @memcpy(model_parameters[encoder_bound.len..], model_handles);
                const encoder_rate: T = config.learning_rate * config.encoder_rate_scale;
                const encoder_optimizer: Optimizer(T) = try .init(allocator, graph, encoder_bound, .{
                    .adam = .{ .rate = encoder_rate },
                });
                const model_optimizer: Optimizer(T) = try .init(allocator, graph, model_handles, .{
                    .adam = .{ .rate = config.learning_rate },
                });
                // The value targets: frozen handles of the live networks and the TARGET heads, on a graph of their own.
                const targets_graph: *Graph(T) = try allocator.create(Graph(T));
                targets_graph.* = Graph(T).init(allocator);
                const target_bounds: [][]const Var = try allocator.alloc([]const Var, networks.target_values.len);
                for (networks.target_values, target_bounds) |target, *bound| {
                    bound.* = try target.bind(targets_graph, .frozen, allocator);
                }
                // The lookahead runs through every dynamics head: the target averages where they lead.
                const frozen_dynamics_bounds: [][]const Var = try allocator.alloc([]const Var, networks.dynamics.len);
                for (networks.dynamics, frozen_dynamics_bounds) |dynamics_head, *bound| {
                    bound.* = try dynamics_head.bind(targets_graph, .frozen, allocator);
                }
                const targets: LatentValueTargets(T) = try .build(
                    targets_graph,
                    networks.encoder,
                    try networks.encoder.bind(targets_graph, .frozen, allocator),
                    networks.policy,
                    try networks.policy.bind(targets_graph, .frozen, allocator),
                    networks.dynamics,
                    frozen_dynamics_bounds,
                    networks.reward,
                    try networks.reward.bind(targets_graph, .frozen, allocator),
                    networks.target_values,
                    target_bounds,
                    .{
                        .rows = horizon * windows,
                        .lookahead = config.lookahead,
                        .discount = config.discount,
                        .bins = config.bins,
                        .spread = config.spread,
                    },
                    allocator,
                );
                const online_value_numbers: []Params(T) = try allocator.alloc(Params(T), networks.values.len);
                const target_value_numbers: []Params(T) = try allocator.alloc(Params(T), networks.values.len);
                for (networks.values, networks.target_values, online_value_numbers, target_value_numbers) |
                    value,
                    target,
                    *online_numbers,
                    *target_numbers,
                | {
                    online_numbers.* = try value.params(allocator);
                    target_numbers.* = try target.params(allocator);
                }
                return .{
                    .config = config,
                    .row = row,
                    .graph = graph,
                    .observations = observations,
                    .actions = actions,
                    .rollout = rollout,
                    .loss = loss,
                    .model_parameters = model_parameters,
                    .encoder_optimizer = encoder_optimizer,
                    .model_optimizer = model_optimizer,
                    .targets = targets,
                    .targets_graph = targets_graph,
                    .online_value_numbers = online_value_numbers,
                    .target_value_numbers = target_value_numbers,
                    .origins = try allocator.alloc(SequenceReplay(T).WindowOrigin, windows),
                    .window_rows = try allocator.alloc(T, horizon * windows * row.width()),
                    .finished = try allocator.alloc(T, horizon * windows),
                    .value_target_values = try allocator.alloc(T, horizon * windows),
                    .step_values = try allocator.alloc(T, windows),
                };
            }

            /// The sampled windows (`window_rows`, step-major) laid out for the graphs: block 0 of the rollout's
            /// observations is each window's first observation, block t + 1 step t's NEXT observation; step t's
            /// actions; step t's rewards, two-hot, straight into the loss; every stored step's own observation for
            /// the value targets.
            fn loadWindows(self: WorldModelLearner) !void {
                const windows: usize = self.config.windows;
                const width: usize = self.row.width();
                const observation_width: usize = self.row.observation_width;
                const action_width: usize = self.row.action_width;
                const target_observations: []T = self.targets.observations.data;
                for (0..self.config.horizon) |step| {
                    for (0..windows) |window| {
                        const stored_index: usize = step * windows + window;
                        const stored: []const T = self.window_rows[stored_index * width ..][0..width];
                        const observation: []const T = stored[0..observation_width];
                        const next_start: usize = self.row.nextObservationStart();
                        const next_observation: []const T = stored[next_start..][0..observation_width];
                        const action: []const T = stored[self.row.actionStart()..][0..action_width];
                        // Block 0: where the window starts. Block step + 1: what really followed this step.
                        if (step == 0) {
                            @memcpy(rowOf(self.observations.data, window, observation_width), observation);
                        }
                        const successor_row: usize = (step + 1) * windows + window;
                        @memcpy(rowOf(self.observations.data, successor_row, observation_width), next_observation);
                        @memcpy(rowOf(self.actions[step].data, window, action_width), action);
                        self.step_values[window] = stored[self.row.rewardColumn()];
                        @memcpy(rowOf(target_observations, stored_index, observation_width), observation);
                    }
                    try self.config.bins.encodeRows(self.step_values, self.loss.reward_targets[step]);
                }
            }

            /// One world-model update from `replay`: `sample`, then `learn`.
            pub fn update(
                self: *WorldModelLearner,
                replay: *const SequenceReplay(T),
                rng: Rng,
                update_index: u32,
            ) !WorldModelReport {
                try self.sample(replay, rng, update_index);
                return self.learn(rng);
            }

            /// Sample W windows of H rows into `window_rows` (step-major), with the `finished` flag of each of their
            /// steps. Reanalyze may replace some of the batch's targets before `learn` runs.
            pub fn sample(
                self: *WorldModelLearner,
                replay: *const SequenceReplay(T),
                rng: Rng,
                update_index: u32,
            ) !void {
                const horizon: usize = self.config.horizon;
                try replay.sample(rng.split(0), update_index, horizon, self.origins, self.window_rows, self.finished);
            }

            /// Learn from the sampled batch: the steps of the pipeline above that follow sampling. Pass the same `rng`
            /// as to `sample`; each step uses its own split of it.
            pub fn learn(self: *WorldModelLearner, rng: Rng) !WorldModelReport {
                const horizon: usize = self.config.horizon;
                const windows: usize = self.config.windows;
                // 2. The rollout's inputs and the reward targets.
                try self.loadWindows();
                // 3. The value targets - frozen, from each stored step's true latent - two-hot, step by step.
                try self.targets.compute(self.targets_graph, rng.split(1), self.value_target_values);
                for (0..horizon) |step| {
                    const step_targets: []const T = self.value_target_values[step * windows ..][0..windows];
                    try self.config.bins.encodeRows(step_targets, self.loss.value_targets[step]);
                }
                // 4. The masks, fresh dropout, the forward pass and the backward one.
                try self.rollout.setFinished(self.finished);
                self.graph.resampleDropout(rng.split(2));
                try self.graph.recompute();
                try self.graph.backward(self.loss.total);
                // 5. One clip over everything, the two Adams, and the target heads' slow follow.
                const clip_limit: T = self.config.gradient_clip;
                const gradient_norm: T = try zn.clipGradNorm(T, self.graph, self.model_parameters, clip_limit);
                try self.encoder_optimizer.step(self.graph);
                try self.model_optimizer.step(self.graph);
                for (self.target_value_numbers, self.online_value_numbers) |target_numbers, online_numbers| {
                    try target_numbers.follow(online_numbers, self.config.target_follow);
                }
                return .{
                    .consistency = self.graph.valueOf(self.loss.consistency).data[0],
                    .reward = self.graph.valueOf(self.loss.reward).data[0],
                    .value = self.graph.valueOf(self.loss.value).data[0],
                    .total = self.graph.valueOf(self.loss.total).data[0],
                    .gradient_norm = gradient_norm,
                };
            }
        };

        /// What one policy update measured: the loss (computed with the updated scale), the running KL scale, and the
        /// policy's gradient norm before clipping.
        pub const PolicyReport = struct {
            total: T,
            kl_scale: T,
            gradient_norm: T,
        };

        /// THE POLICY UPDATE (BMPC's `update_pi`).
        ///
        /// The policy is trained to reproduce the planner's answers. Its inputs are the latents z_0 .. z_(H-1) that the
        /// world model's rollout computed in this update; its targets are the Gaussians the planner stored with each
        /// step: their means, and the logarithms of their spreads.
        ///
        ///     world model's rollout:       z_0 --> z_1 --> ... --> z_H
        ///                                    |  copied as values: no gradient reaches the world model
        ///                                    v
        ///     policy at z_0 .. z_(H-1) --> KL(policy || planner) / scale  -  1e-4 x dims x entropy
        ///                                    ^
        ///     the batch's rows:            the planner's means and log spreads
        ///
        ///     then the policy's gradients are clipped at 20 and its Adam optimiser (epsilon 1e-5) takes one step
        ///
        /// Why the rolled latents: during planning, the policy's plans are evaluated inside the model (9.15), so the
        /// policy is trained on latents that the model produces. The values are those of the world model's forward
        /// pass in this update. The world model's optimiser has changed its weights since, but not the values the
        /// pass computed, so the copy matches torch BMPC's `zs.detach()`.
        ///
        /// Why a running scale: the size of the KL changes as the planner and the policy change. Dividing it by a
        /// running estimate of its spread (`RunningScale`, 9.12) keeps the loss at a steady size, so one learning
        /// rate suits the whole run. Each batch updates the scale first; the loss is then recomputed with it.
        ///
        /// The policy has its own graph and its own optimiser, so neither half of an update changes the other's
        /// networks.
        pub const PolicyLearner = struct {
            config: Config,
            row: Row,
            graph: *Graph(T),
            /// How many dynamics heads the world model rolls: the policy learns on every head's latents (eq. 16 of
            /// EfficientTDMPC), stacked into its batch - `dynamics_head_count x windows` rows per step.
            dynamics_head_count: usize,
            /// The latents z_0 .. z_(H-1) of every head, step-major, copied from the world model's rollout in every
            /// update - each step a block of rows per head (`update` draws the layout).
            latents: Tensor(T),
            /// With several heads: per step, which stacked rows still count - the world model's column for its windows,
            /// repeated once per head, refreshed in every update. Empty with one head, where the loss reads the world
            /// model's own columns.
            unfinished_by_head: []Tensor(T),
            loss: PolicyDistillationLoss(T),
            /// The policy's trained parameters: what its clip and its optimiser act on.
            parameters: []const Var,
            optimizer: Optimizer(T),
            kl_scale: RunningScale(T),
            /// Working space for `updateScale`, one value per stacked window.
            scratch: []T,

            /// `world_model` provides its rollout's `unfinished` columns, so that one `setFinished` masks both
            /// losses.
            pub fn init(
                allocator: Allocator,
                networks: Networks,
                world_model: *const WorldModelLearner,
                config: Config,
            ) !PolicyLearner {
                const dynamics_head_count: usize = networks.dynamics.len;
                const stacked_windows: usize = dynamics_head_count * config.windows;
                const rows: usize = config.horizon * stacked_windows;
                const graph: *Graph(T) = try allocator.create(Graph(T));
                graph.* = Graph(T).init(allocator);
                const parameters: []Var = try networks.policy.bind(graph, .trained, allocator);
                const latents: Tensor(T) = try .alloc(allocator, &.{ rows, networks.encoder.spec.output });
                latents.fill(0);
                // Which rows count: with one head, the world model's own columns - one `setFinished` masks both
                // losses; with several, columns of their own, every head's copy of a window counting as the window.
                var unfinished_by_head: []Tensor(T) = &.{};
                if (dynamics_head_count > 1) {
                    unfinished_by_head = try allocator.alloc(Tensor(T), config.horizon);
                    for (unfinished_by_head) |*column| {
                        column.* = try zn.ones(T, allocator, &.{ stacked_windows, 1 });
                    }
                }
                const unfinished: []const Tensor(T) = if (dynamics_head_count == 1)
                    world_model.rollout.unfinished
                else
                    unfinished_by_head;
                const loss: PolicyDistillationLoss(T) = try .build(
                    graph,
                    try graph.constant(latents),
                    unfinished,
                    networks.policy,
                    parameters,
                    .{
                        .horizon = config.horizon,
                        .batch = stacked_windows,
                        .rho = config.rho,
                        .entropy_coefficient = config.entropy_coefficient,
                        .log_std_low = config.spread.log_std_low,
                        .log_std_high = config.spread.log_std_high,
                    },
                    allocator,
                );
                const optimizer: Optimizer(T) = try .init(allocator, graph, parameters, .{
                    .adam = .{ .rate = config.learning_rate, .epsilon = config.policy_epsilon },
                });
                return .{
                    .config = config,
                    .row = world_model.row,
                    .graph = graph,
                    .dynamics_head_count = dynamics_head_count,
                    .latents = latents,
                    .unfinished_by_head = unfinished_by_head,
                    .loss = loss,
                    .parameters = parameters,
                    .optimizer = optimizer,
                    .kl_scale = .{},
                    .scratch = try allocator.alloc(T, stacked_windows),
                };
            }

            /// One policy update. Call it after `world_model` has learned from its batch: it reads that batch and the
            /// rollout's latents.
            pub fn update(self: *PolicyLearner, world_model: *const WorldModelLearner) !PolicyReport {
                const horizon: usize = self.config.horizon;
                const windows: usize = self.config.windows;
                const dynamics_head_count: usize = self.dynamics_head_count;
                const action_width: usize = self.row.action_width;
                const row_width: usize = self.row.width();
                const latent_numbers_per_block: usize = windows * self.latents.shape[1];
                // 1. Every head's latents z_0 .. z_(H-1), copied as values from the world model's forward pass.
                //    Latents, loss rows and targets share one STEP-MAJOR layout, each step a block of W rows per
                //    head, so row r of each is the same stored step seen through the same head:
                //
                //        latents   | z_0 head 0, windows 0 .. W-1 | z_0 head 1, ... | ... | z_1 head 0, ... | ...
                //        targets   | step 0                       | step 0          | ... | step 1          | ...
                //
                //    With one head the blocks are the steps: the layout BMPC's policy loss always had.
                for (0..horizon) |step| {
                    for (0..dynamics_head_count) |dynamics_head_index| {
                        const rolled_latent: Var = world_model.rollout.rolled[dynamics_head_index][step];
                        const rolled_latent_values: []const T = world_model.graph.valueOf(rolled_latent).data;
                        const block_index: usize = step * dynamics_head_count + dynamics_head_index;
                        const block_start: usize = block_index * latent_numbers_per_block;
                        const block_latents: []T = self.latents.data[block_start..][0..latent_numbers_per_block];
                        @memcpy(block_latents, rolled_latent_values);
                    }
                }
                // 2. The planner's targets for each stored step, the same for every head's copy of it: the means as
                //    stored, the spreads as logarithms - the loss compares log spreads, and every stored spread is at
                //    least the planner's floor (0.05) or exactly 1 (the empty target), so the logarithm is finite.
                for (0..horizon) |step| {
                    for (0..windows) |window| {
                        const batch_row_index: usize = step * windows + window;
                        const stored_row: []const T = rowOf(world_model.window_rows, batch_row_index, row_width);
                        const stored_means: []const T = stored_row[self.row.targetMeanStart()..][0..action_width];
                        const stored_spreads: []const T = stored_row[self.row.targetSpreadStart()..][0..action_width];
                        for (0..dynamics_head_count) |dynamics_head_index| {
                            const block_index: usize = step * dynamics_head_count + dynamics_head_index;
                            const loss_row: usize = block_index * windows + window;
                            const target_means: []T = rowOf(self.loss.target_means.data, loss_row, action_width);
                            @memcpy(target_means, stored_means);
                            const target_log_stds: []T = rowOf(self.loss.target_log_stds.data, loss_row, action_width);
                            for (target_log_stds, stored_spreads) |*target_log_std, stored_spread| {
                                target_log_std.* = @log(stored_spread);
                            }
                        }
                    }
                }
                // With several heads, every head's copy of a window counts exactly as the window does. (With one,
                // there are no columns of its own: the loss reads the world model's.)
                for (self.unfinished_by_head, 0..) |stacked_column, step| {
                    const window_column: Tensor(T) = world_model.rollout.unfinished[step];
                    for (0..dynamics_head_count) |dynamics_head_index| {
                        const head_rows: []T = stacked_column.data[dynamics_head_index * windows ..][0..windows];
                        @memcpy(head_rows, window_column.data[0..windows]);
                    }
                }
                // 3. The scale is updated from this batch first; the loss is then recomputed with it and
                // differentiated.
                try self.graph.recompute();
                try self.loss.updateScale(self.graph, &self.kl_scale, self.scratch);
                try self.graph.recompute();
                try self.graph.backward(self.loss.total);
                // 4. The policy's gradients are clipped, and its optimiser takes one step.
                const clip_limit: T = self.config.gradient_clip;
                const gradient_norm: T = try zn.clipGradNorm(T, self.graph, self.parameters, clip_limit);
                try self.optimizer.step(self.graph);
                return .{
                    .total = self.graph.valueOf(self.loss.total).data[0],
                    .kl_scale = self.kl_scale.value,
                    .gradient_norm = gradient_norm,
                };
            }
        };

        /// REANALYZE (BMPC's "lazy reanalyze").
        ///
        /// A stored target is the answer the planner gave when that step was played, computed with the networks of
        /// that time. The networks improve afterwards, so older targets become outdated, and the policy would keep
        /// imitating them. On every `reanalyze_interval`-th update outside pretraining, BMPC plans again with the
        /// current networks at the stored states of the first `reanalyze_windows` windows of the sampled batch, at
        /// every one of their H steps. The new targets replace the old ones in the replay and in the batch, so the
        /// policy update that follows already uses them.
        ///
        ///     the batch: W windows of H rows          the first R windows: H x R stored states
        ///       window 0      [ s0  s1  s2 ] ----+
        ///       window 1      [ s0  s1  s2 ] ----+--> one decision over the H x R states: no warm start, the
        ///       ...                              |      policy's plans drawn with the exploration bounds
        ///       window R-1    [ s0  s1  s2 ] ----+      (log std in [-2, 1]), evaluated
        ///       windows R .. W-1: unchanged          --> the new targets, written to the replay and to the batch
        ///
        /// Reanalyze is a decision (`Actor.act`) over the stored states, laid out step-major, with three settings.
        /// Every state is marked as an episode's first step, so the search starts from scratch. The decision is
        /// evaluated, since only the target is kept. The policy's plans are drawn with the exploration bounds: with
        /// log std in [-2, 1], a plan's spread is at least e^-2 = 0.14, where acting allows e^-3 = 0.05, so the
        /// search considers actions further from the policy's proposal.
        ///
        /// Worked numbers (BMPC's defaults): every 10 updates, 20 windows x 3 steps = 60 stored targets are planned
        /// again, while each update reads 256 x 3 = 768 targets.
        pub const Reanalyzer = struct {
            config: Config,
            row: Row,
            /// The windows planned again per reanalyze: `reanalyze_windows`, at most the batch's windows.
            reanalyzed_windows: usize,
            actor: Actor,
            /// The H x R stored states, step-major: state index = step x R + window.
            observations: []T,
            /// All true: every state is planned from scratch.
            first_steps: []bool,
            decision: Decision,
            /// The new targets in the layout `writeBack` takes: one row per state, its means then its spreads.
            target_rows: []T,

            pub fn init(
                allocator: Allocator,
                networks: Networks,
                observation_width: usize,
                action_width: usize,
                config: Config,
            ) !Reanalyzer {
                const reanalyzed_windows: usize = @min(config.reanalyze_windows, config.windows);
                const states: usize = config.horizon * reanalyzed_windows;
                // The actor used for acting, with the policy's plans drawn using the exploration bounds.
                var exploring_config: Config = config;
                exploring_config.spread = config.exploration_spread;
                const actor: Actor = try .init(
                    allocator,
                    networks,
                    observation_width,
                    action_width,
                    states,
                    exploring_config,
                    config.reanalyzing,
                );
                const first_steps: []bool = try allocator.alloc(bool, states);
                @memset(first_steps, true);
                return .{
                    .config = config,
                    .row = .{ .observation_width = observation_width, .action_width = action_width },
                    .reanalyzed_windows = reanalyzed_windows,
                    .actor = actor,
                    .observations = try allocator.alloc(T, states * observation_width),
                    .first_steps = first_steps,
                    .decision = .{
                        .actions = try allocator.alloc(T, states * action_width),
                        .target_means = try allocator.alloc(T, states * action_width),
                        .target_spreads = try allocator.alloc(T, states * action_width),
                    },
                    .target_rows = try allocator.alloc(T, states * 2 * action_width),
                };
            }

            /// Plan again at the stored states of the first `reanalyzed_windows` windows of the batch `world_model`
            /// has sampled, and write the new targets to `replay` and to the batch.
            pub fn reanalyze(
                self: Reanalyzer,
                world_model: *WorldModelLearner,
                replay: *SequenceReplay(T),
                rng: Rng,
            ) !void {
                const horizon: usize = self.config.horizon;
                const batch_windows: usize = self.config.windows;
                const reanalyzed_windows: usize = self.reanalyzed_windows;
                const observation_width: usize = self.row.observation_width;
                const action_width: usize = self.row.action_width;
                const row_width: usize = self.row.width();
                // A target is 2 x action_width columns: the means, then the spreads.
                const target_column_start: usize = self.row.targetMeanStart();
                const target_column_count: usize = 2 * action_width;
                // Two step-major layouts meet here: the batch's rows hold W windows per step, the planned states only
                // the first R of them. Every loop below maps one to the other:
                //
                //     batch rows  (row = step x W + window)       states  (state = step x R + window)
                //
                //     step 0  | w0 w1 .. w(R-1) | wR .. w(W-1) |  ->  | w0 w1 .. w(R-1) |
                //     step 1  | w0 w1 .. w(R-1) | wR .. w(W-1) |  ->  | w0 w1 .. w(R-1) |
                //     ...                                              ...
                //
                // 1. The stored states, read from the batch's rows.
                for (0..horizon) |step| {
                    for (0..reanalyzed_windows) |window| {
                        const batch_row_index: usize = step * batch_windows + window;
                        const state_index: usize = step * reanalyzed_windows + window;
                        const batch_row: []const T = rowOf(world_model.window_rows, batch_row_index, row_width);
                        const state_observation: []T = rowOf(self.observations, state_index, observation_width);
                        @memcpy(state_observation, batch_row[0..observation_width]);
                    }
                }
                // 2. One decision over all the states, from scratch and evaluated.
                try self.actor.act(self.observations, self.first_steps, .evaluate, rng, self.decision);
                // 3. The new targets, laid out as target columns and copied into the batch's rows ...
                for (0..horizon) |step| {
                    for (0..reanalyzed_windows) |window| {
                        const batch_row_index: usize = step * batch_windows + window;
                        const state_index: usize = step * reanalyzed_windows + window;
                        const new_means: []const T = rowOf(self.decision.target_means, state_index, action_width);
                        const new_spreads: []const T = rowOf(self.decision.target_spreads, state_index, action_width);
                        const target_row: []T = rowOf(self.target_rows, state_index, target_column_count);
                        @memcpy(target_row[0..action_width], new_means);
                        @memcpy(target_row[action_width..], new_spreads);
                        const batch_row: []T = rowOf(world_model.window_rows, batch_row_index, row_width);
                        @memcpy(batch_row[target_column_start..][0..target_column_count], target_row);
                    }
                }
                // ... and written to the replay's stored rows. `writeBack` reads its values step-major over the
                // windows it is given - state = step x R + window, the layout of `target_rows` - and every step's
                // target goes back to that step's own stored row.
                const WindowOrigin = SequenceReplay(T).WindowOrigin;
                const reanalyzed_origins: []const WindowOrigin = world_model.origins[0..reanalyzed_windows];
                try replay.writeBack(reanalyzed_origins, 0, horizon, target_column_start, self.target_rows);
            }
        };

        /// What one whole update measured. `policy` is null during pretraining; `reanalyzed` tells whether the update
        /// planned part of its batch again first.
        pub const LearnerReport = struct {
            world_model: WorldModelReport,
            policy: ?PolicyReport,
            reanalyzed: bool,
        };

        /// THE WHOLE UPDATE.
        ///
        ///     1. sample W windows of H rows from the replay
        ///     2. on every `reanalyze_interval`-th update outside pretraining: reanalyze the first windows
        ///     3. the world model learns from the batch (`WorldModelLearner`)
        ///     4. outside pretraining: the policy learns from the world model's latents and the batch's targets
        ///
        /// Reanalyze runs before any learning, so the planner uses the networks as they are at the start of the
        /// update, and the policy update in step 4 uses the new targets. During pretraining (BMPC's burst of updates
        /// at the end of the seeding phase, before the stored targets carry information), steps 2 and 4 are
        /// skipped and the update does not count toward the reanalyze interval.
        ///
        /// The target heads follow their value heads at the end of step 3. Torch BMPC does this after the policy
        /// update; the policy's loss does not read the value heads, so the order does not change the result.
        pub const Learner = struct {
            config: Config,
            world_model: WorldModelLearner,
            reanalyzer: Reanalyzer,
            policy: PolicyLearner,
            /// The number of updates made outside pretraining.
            updates: usize = 0,

            pub fn init(
                allocator: Allocator,
                networks: Networks,
                observation_width: usize,
                action_width: usize,
                config: Config,
            ) !Learner {
                const world_model: WorldModelLearner = try .init(
                    allocator,
                    networks,
                    observation_width,
                    action_width,
                    config,
                );
                const reanalyzer: Reanalyzer = try .init(allocator, networks, observation_width, action_width, config);
                const policy: PolicyLearner = try .init(allocator, networks, &world_model, config);
                return .{ .config = config, .world_model = world_model, .reanalyzer = reanalyzer, .policy = policy };
            }

            pub fn update(
                self: *Learner,
                replay: *SequenceReplay(T),
                rng: Rng,
                update_index: u32,
                pretraining: bool,
            ) !LearnerReport {
                try self.world_model.sample(replay, rng, update_index);
                // Real updates are counted from 1, so reanalyze falls on the 10th, the 20th, ... (interval 10);
                // pretraining updates are not counted at all.
                if (!pretraining) {
                    self.updates += 1;
                }
                const reanalyze_interval: usize = self.config.reanalyze_interval;
                const interval_reached: bool = reanalyze_interval > 0 and self.updates % reanalyze_interval == 0;
                const reanalyzing: bool = !pretraining and interval_reached;
                if (reanalyzing) {
                    try self.reanalyzer.reanalyze(&self.world_model, replay, rng.split(3));
                }
                const world_model_report: WorldModelReport = try self.world_model.learn(rng);
                const world_model: *const WorldModelLearner = &self.world_model;
                const policy_report: ?PolicyReport = if (pretraining) null else try self.policy.update(world_model);
                return .{ .world_model = world_model_report, .policy = policy_report, .reanalyzed = reanalyzing };
            }
        };

        /// WHAT THE TRAINING LOOP NEEDS FROM AN ENVIRONMENT, checked when a trainer is built:
        ///
        ///     pub fn reset(self: *Environment, rng: Rng, observation: []T) void
        ///         start an episode and write its first observation
        ///     pub fn step(self: *Environment, action: []const T, observation: []T) T
        ///         act once, write the observation that follows, and return the reward
        ///
        /// An environment never ends an episode itself: BMPC has no notion of termination, so the loop cuts every
        /// episode at a fixed length (a truncation, never a terminal state).
        pub fn requireEnvironment(comptime Environment: type) void {
            const reset_type: type = fn (*Environment, Rng, []T) void;
            const step_type: type = fn (*Environment, []const T, []T) T;
            if (!@hasDecl(Environment, "reset") or @TypeOf(Environment.reset) != reset_type) {
                @compileError("bmpc: an environment needs `pub fn reset(self: *" ++ @typeName(Environment) ++
                    ", rng: Rng, observation: []T) void`");
            }
            if (!@hasDecl(Environment, "step") or @TypeOf(Environment.step) != step_type) {
                @compileError("bmpc: an environment needs `pub fn step(self: *" ++ @typeName(Environment) ++
                    ", action: []const T, observation: []T) T`");
            }
        }

        /// THE TRAINING LOOP: ONE FRAME AT A TIME, AS THE SCHEDULE SAYS.
        ///
        /// A frame is one step of every environment at once, then the updates the `Schedule` asks for:
        ///
        ///     observation --> act --> action --> environment.step --> reward, next observation
        ///          |      (random while seeding,                                 |
        ///          |       the planner after)                                    v
        ///          +------------------------------------------------------> row --> the replay
        ///
        ///     then: the schedule's updates for this frame (none, the burst, or E x u)
        ///
        /// WHAT A ROW STORES. The observation the decision was made from, the action ACTED ON (the planner's target
        /// jittered by exploration noise, or a random action while seeding), the reward, the true next
        /// observation, whether the episode ended there, and the planner's target - or, while seeding, the empty
        /// target N(0, 1), since no planner answered for that step.
        ///
        /// EPISODES HAVE A FIXED LENGTH L. The L-th step of an episode is stored as truncated, with the TRUE next
        /// observation; the environment is then reset, and the next decision is marked as an episode's first step,
        /// so the planner starts from scratch rather than from the last plan:
        ///
        ///     frame          0      1      2    |  3      4      5    |  6
        ///     episode step   1      2      3    |  1      2      3    |  1          (L = 3)
        ///     truncated      -      -      yes  |  -      -      yes  |  -
        ///     first step     yes    -      -    |  yes    -      -    |  yes
        ///
        /// The discount comes from L, by BMPC's rule (`discountFor`): `init` sets it, whatever the config says.
        ///
        /// RANDOMNESS. Seeding's actions and acting draw from one labelled stream, environment resets from a
        /// second, updates from a third, each split by frame, environment or update index - so the same seeds
        /// replay the same run, and adding updates never shifts what the environments see.
        ///
        /// `allocator` should be an arena: it lives as long as the trainer, as for the actor and the learner.
        pub fn Trainer(comptime Environment: type) type {
            comptime requireEnvironment(Environment);
            return struct {
                const Self = @This();

                /// The labels of the random streams: actions, environment resets, updates.
                const acting_stream: u32 = 1;
                const reset_stream: u32 = 2;
                const update_stream: u32 = 3;

                environments: []Environment,
                schedule: Schedule,
                episode_length: usize,
                row: Row,
                actor: Actor,
                learner: Learner,
                replay: SequenceReplay(T),
                rng: Rng,
                /// What every environment shows now, one row each: what the next decision is made from.
                observations: []T,
                /// Where each environment's step writes the observation that follows.
                next_observations: []T,
                /// True where the next decision begins an episode.
                first_steps: []bool,
                /// The steps taken in each environment's current episode.
                episode_steps: []usize,
                /// The episodes begun in each environment; each reset draws from its own stream.
                episodes: []u32,
                /// The frame's actions and, when the planner acted, its targets.
                decision: Decision,
                /// One replay row per environment, filled every frame.
                rows: []T,
                /// Every environment steps every frame.
                active: []bool,
                /// The frames run so far: the next frame's number.
                frame: usize,
                /// The updates made so far, pretraining included: the next update's index.
                update_index: u32,
                /// The latest update's report - the world model's losses and gradient norm, and the policy's when it
                /// learned - so a run can be watched. Null until the first update.
                last_report: ?LearnerReport,

                /// `replay_capacity` rows per environment; the networks are shared by the actor and the learner.
                pub fn init(
                    allocator: Allocator,
                    environments: []Environment,
                    networks: Networks,
                    observation_width: usize,
                    action_width: usize,
                    config: Config,
                    schedule: Schedule,
                    episode_length: usize,
                    replay_capacity: usize,
                    rng: Rng,
                ) !Self {
                    const count: usize = environments.len;
                    var learning: Config = config;
                    learning.discount = discountFor(episode_length);
                    const row: Row = .{ .observation_width = observation_width, .action_width = action_width };
                    const actor: Actor = try .init(
                        allocator,
                        networks,
                        observation_width,
                        action_width,
                        count,
                        learning,
                        learning.acting,
                    );
                    const learner: Learner = try .init(allocator, networks, observation_width, action_width, learning);
                    const replay: SequenceReplay(T) = try .init(
                        allocator,
                        count,
                        replay_capacity,
                        row.width(),
                        row.doneColumn(),
                    );
                    const decided: usize = count * action_width;
                    var trainer: Self = .{
                        .environments = environments,
                        .schedule = schedule,
                        .episode_length = episode_length,
                        .row = row,
                        .actor = actor,
                        .learner = learner,
                        .replay = replay,
                        .rng = rng,
                        .observations = try allocator.alloc(T, count * observation_width),
                        .next_observations = try allocator.alloc(T, count * observation_width),
                        .first_steps = try allocator.alloc(bool, count),
                        .episode_steps = try allocator.alloc(usize, count),
                        .episodes = try allocator.alloc(u32, count),
                        .decision = .{
                            .actions = try allocator.alloc(T, decided),
                            .target_means = try allocator.alloc(T, decided),
                            .target_spreads = try allocator.alloc(T, decided),
                        },
                        .rows = try allocator.alloc(T, count * row.width()),
                        .active = try allocator.alloc(bool, count),
                        .frame = 0,
                        .update_index = 0,
                        .last_report = null,
                    };
                    @memset(trainer.active, true);
                    @memset(trainer.episodes, 0);
                    for (trainer.environments, 0..) |*environment, index| {
                        trainer.beginEpisode(environment, index);
                    }
                    return trainer;
                }

                /// Reset one environment: its first observation becomes what the next decision sees.
                fn beginEpisode(
                    self: *Self,
                    environment: *Environment,
                    index: usize,
                ) void {
                    const observation_width: usize = self.row.observation_width;
                    const environment_rng: Rng = self.rng.split(reset_stream).split(@intCast(index));
                    const reset_rng: Rng = environment_rng.split(self.episodes[index]);
                    environment.reset(reset_rng, self.observations[index * observation_width ..][0..observation_width]);
                    self.episodes[index] += 1;
                    self.episode_steps[index] = 0;
                    self.first_steps[index] = true;
                }

                /// One frame - act, step every environment, store the rows, then the schedule's updates. Returns what
                /// the schedule asked of this frame.
                pub fn runFrame(self: *Self) !Schedule.Frame {
                    const frame_plan: Schedule.Frame = self.schedule.at(self.frame);
                    const frame_rng: Rng = self.rng.split(acting_stream).split(@intCast(self.frame));
                    if (frame_plan.planned) {
                        try self.actor.act(self.observations, self.first_steps, .explore, frame_rng, self.decision);
                    } else {
                        for (self.decision.actions, 0..) |*action, index| {
                            action.* = frame_rng.uniform(T, @intCast(index), -1, 1);
                        }
                    }
                    const observation_width: usize = self.row.observation_width;
                    const action_width: usize = self.row.action_width;
                    const row_width: usize = self.row.width();
                    for (self.environments, 0..) |*environment, index| {
                        const begin: usize = index * observation_width;
                        const observation: []const T = self.observations[begin..][0..observation_width];
                        const next_observation: []T = self.next_observations[begin..][0..observation_width];
                        const action: []const T = self.decision.actions[index * action_width ..][0..action_width];
                        const reward: T = environment.step(action, next_observation);
                        self.episode_steps[index] += 1;
                        const target: ?Target = if (frame_plan.planned) .{
                            .means = self.decision.target_means[index * action_width ..][0..action_width],
                            .spreads = self.decision.target_spreads[index * action_width ..][0..action_width],
                        } else null;
                        try self.row.fill(self.rows[index * row_width ..][0..row_width], .{
                            .observation = observation,
                            .action = action,
                            .reward = reward,
                            .next_observation = next_observation,
                            .terminated = false,
                            .truncated = self.episode_steps[index] == self.episode_length,
                            .target = target,
                        });
                    }
                    try self.replay.push(self.rows, self.active);
                    // Advance every environment: the successor becomes what the next decision sees, or, at the end
                    // of an episode, a fresh episode begins.
                    for (self.environments, 0..) |*environment, index| {
                        if (self.episode_steps[index] == self.episode_length) {
                            self.beginEpisode(environment, index);
                        } else {
                            const begin: usize = index * observation_width;
                            @memcpy(
                                self.observations[begin..][0..observation_width],
                                self.next_observations[begin..][0..observation_width],
                            );
                            self.first_steps[index] = false;
                        }
                    }
                    for (0..frame_plan.updates) |_| {
                        const update_rng: Rng = self.rng.split(update_stream).split(self.update_index);
                        self.last_report = try self.learner.update(
                            &self.replay,
                            update_rng,
                            self.update_index,
                            frame_plan.pretraining,
                        );
                        self.update_index += 1;
                    }
                    self.frame += 1;
                    return frame_plan;
                }
            };
        }
    };
}

// ---- Known answers, on networks small enough to reason about: observations 4 wide, actions 2, latents 6 (two
// simplices of 3), two states, sixteen candidates each - four of them the policy's.

const TestBmpc = Bmpc(f64);
const test_observation_width: usize = 4;
const test_action_width: usize = 2;
const test_states: usize = 2;
/// The small planner the tests use, for acting and for reanalyze alike.
const test_planner: TestBmpc.PlannerConfig = .{
    .horizon = 3,
    .iterations = 4,
    .candidates = 16,
    .policy_candidates = 4,
    .elites = 6,
};

const test_config: TestBmpc.Config = .{
    .latent_width = 6,
    .hidden_width = 8,
    .encoder_hidden_width = 8,
    .simnorm_group = 3,
    .horizon = 3,
    .acting = test_planner,
    .reanalyzing = test_planner,
    .discount = 0.95,
};

fn testActor(arena: Allocator) !TestBmpc.Actor {
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        test_config,
    );
    return TestBmpc.Actor.init(
        arena,
        networks,
        test_observation_width,
        test_action_width,
        test_states,
        test_config,
        test_config.acting,
    );
}

/// Two observations from a seed - spread out but tame.
fn testObservations(seed: usize) [test_states * test_observation_width]f64 {
    var observations: [test_states * test_observation_width]f64 = undefined;
    for (&observations, 0..) |*entry, index| {
        const phase: f64 = @floatFromInt(index + 7 * seed);
        entry.* = @sin(0.9 * phase) + 0.2;
    }
    return observations;
}

const TestDecision = struct {
    actions: [test_states * test_action_width]f64 = undefined,
    target_means: [test_states * test_action_width]f64 = undefined,
    target_spreads: [test_states * test_action_width]f64 = undefined,

    fn slices(self: *TestDecision) TestBmpc.Decision {
        return .{
            .actions = &self.actions,
            .target_means = &self.target_means,
            .target_spreads = &self.target_spreads,
        };
    }
};

test "bmpc: a fresh agent's imagination is flat - zero-initialised reward and value heads score every plan 0" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const actor: TestBmpc.Actor = try testActor(arena_state.allocator());
    const observations: [test_states * test_observation_width]f64 = testObservations(1);
    @memcpy(actor.scorer.observations.data, &observations);
    @memcpy(actor.plans.observations.data, &observations);
    try actor.plans.fill(actor.plans_graph, Rng.init(3), actor.scorer.actions);
    try actor.scorer.score(actor.scorer_graph, actor.candidate_scores);
    // Uniform bins over a symmetric support decode to zero - up to the rounding of summing the bins' centres.
    for (actor.candidate_scores) |score| {
        try expect(@abs(score) < 1e-12);
    }
}

test "bmpc: act keeps the drawn elite's first action as the target; exploring jitters it, evaluating does not" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const actor: TestBmpc.Actor = try testActor(arena_state.allocator());
    const observations: [test_states * test_observation_width]f64 = testObservations(2);
    const first_steps: [test_states]bool = .{ true, true };
    const rng: Rng = .init(21);
    var explored: TestDecision = .{};
    try actor.act(&observations, &first_steps, .explore, rng, explored.slices());
    // The exploration by hand: the target plus its spread x the decision's own noise, clamped.
    for (0..test_states) |state| {
        for (0..test_action_width) |dimension| {
            const at: usize = state * test_action_width + dimension;
            const noise: f64 = rng.split(2).split(@intCast(state)).normal(f64, @intCast(dimension));
            const unclamped: f64 = explored.target_means[at] + explored.target_spreads[at] * noise;
            const jittered: f64 = clamp(unclamped, -1, 1);
            try expectEqual(jittered, explored.actions[at]);
            try expect(explored.target_spreads[at] >= test_config.min_spread);
            try expect(explored.target_spreads[at] <= test_config.max_spread);
        }
    }
    // Evaluating from the same seed: the same search, the same target - and the target itself acted on.
    var evaluated: TestDecision = .{};
    try actor.act(&observations, &first_steps, .evaluate, rng, evaluated.slices());
    try expect(eql(f64, &explored.target_means, &evaluated.target_means));
    try expect(eql(f64, &evaluated.target_means, &evaluated.actions));
}

test "bmpc: act puts the policy's own plans into the search, untouched by MPPI's sampling" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const actor: TestBmpc.Actor = try testActor(arena);
    const observations: [test_states * test_observation_width]f64 = testObservations(3);
    const first_steps: [test_states]bool = .{ true, false };
    const rng: Rng = .init(31);
    var decision: TestDecision = .{};
    try actor.act(&observations, &first_steps, .explore, rng, decision.slices());
    // The same plans again, into fresh tensors: the search's policy rows must still hold them, bit for bit.
    var fresh: [3]Tensor(f64) = undefined;
    for (&fresh) |*step_actions| {
        const candidate_rows: usize = test_states * test_config.acting.candidates;
        step_actions.* = try Tensor(f64).alloc(arena, &.{ candidate_rows, test_action_width });
        step_actions.fill(0);
    }
    try actor.plans.fill(actor.plans_graph, rng.split(0), &fresh);
    for (actor.scorer.actions, fresh) |searched, planned| {
        for (0..test_states) |state| {
            for (0..test_config.acting.policy_candidates) |plan| {
                const row: usize = state * test_config.acting.candidates + plan;
                for (0..test_action_width) |dimension| {
                    try expectEqual(planned.at2(row, dimension), searched.at2(row, dimension));
                }
            }
        }
    }
}

test "bmpc: the same seed decides the same, bit for bit, and every action stays in [-1, 1]" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const actor: TestBmpc.Actor = try testActor(arena_state.allocator());
    const first_steps: [test_states]bool = .{ true, true };
    for (0..40) |seed| {
        const observations: [test_states * test_observation_width]f64 = testObservations(seed);
        const rng: Rng = .init(@intCast(100 + seed));
        var once: TestDecision = .{};
        var again: TestDecision = .{};
        try actor.act(&observations, &first_steps, .explore, rng, once.slices());
        try actor.act(&observations, &first_steps, .explore, rng, again.slices());
        try expect(eql(f64, &once.actions, &again.actions));
        try expect(eql(f64, &once.target_means, &again.target_means));
        for (once.actions) |action| {
            try expect(action >= -1 and action <= 1);
        }
    }
}

// ---- The replay row's known answers: observations 3 wide, actions 2, so a row is 2 x 3 + 3 x 2 + 3 = 15 values.

const row_test_layout: TestBmpc.Row = .{ .observation_width = 3, .action_width = 2 };

test "bmpc row: every column at its place - written out by hand" {
    const target_means: [2]f64 = .{ 0.1, 0.2 };
    const target_spreads: [2]f64 = .{ 0.3, 0.4 };
    const step: TestBmpc.Step = .{
        .observation = &.{ 1, 2, 3 },
        .action = &.{ 0.5, -0.5 },
        .reward = 2,
        .next_observation = &.{ 4, 5, 6 },
        .terminated = false,
        .truncated = true,
        .target = .{ .means = &target_means, .spreads = &target_spreads },
    };
    var row: [15]f64 = undefined;
    try row_test_layout.fill(&row, step);
    // observation | action | reward | next observation | done | terminated | target mean | target spread
    const expected: [15]f64 = .{ 1, 2, 3, 0.5, -0.5, 2, 4, 5, 6, 1, 0, 0.1, 0.2, 0.3, 0.4 };
    try expect(eql(f64, &expected, &row));
    try expectEqual(@as(usize, 15), row_test_layout.width());
    try expectEqual(@as(usize, 5), row_test_layout.rewardColumn());
    try expectEqual(@as(usize, 9), row_test_layout.doneColumn());
    try expectEqual(@as(usize, 11), row_test_layout.targetMeanStart());
}

test "bmpc row: a step no planner answered for stores the empty target N(0, 1)" {
    const step: TestBmpc.Step = .{
        .observation = &.{ 1, 2, 3 },
        .action = &.{ 0, 0 },
        .reward = 0,
        .next_observation = &.{ 1, 2, 3 },
        .terminated = false,
        .truncated = false,
        .target = null,
    };
    var row: [15]f64 = undefined;
    try row_test_layout.fill(&row, step);
    const target_part: []const f64 = row[row_test_layout.targetMeanStart()..];
    try expect(eql(f64, &.{ 0, 0, 1, 1 }, target_part));
    try expectEqual(@as(f64, 0), row[row_test_layout.doneColumn()]);
}

test "bmpc row: through the replay, the step that ends an episode counts; the steps after it are finished" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const window_length: usize = 4;
    var replay: zrl.SequenceReplay(f64) = try .init(
        arena,
        1,
        16,
        row_test_layout.width(),
        row_test_layout.doneColumn(),
    );
    // Four steps of one environment; the second is cut short by a time limit - truncated, not terminated.
    var pushed: [4][15]f64 = undefined;
    for (&pushed, 0..) |*row, index| {
        const value: f64 = @floatFromInt(index);
        const step: TestBmpc.Step = .{
            .observation = &.{ value, value, value },
            .action = &.{ 0.1 * value, -0.1 * value },
            .reward = value,
            .next_observation = &.{ value + 0.5, value + 0.5, value + 0.5 },
            .terminated = false,
            .truncated = index == 1,
            .target = null,
        };
        try row_test_layout.fill(row, step);
        try replay.push(row, &.{true});
    }
    // Exactly four steps stored and a window of four: the only window there is.
    var origins: [1]zrl.SequenceReplay(f64).WindowOrigin = undefined;
    var windows: [4 * 15]f64 = undefined;
    var finished: [4]f64 = undefined;
    try replay.sample(Rng.init(1), 0, window_length, &origins, &windows, &finished);
    // The truncated step itself is real; only what follows it is finished.
    try expect(eql(f64, &.{ 0, 0, 1, 1 }, &finished));
    for (pushed, 0..) |row, step| {
        try expect(eql(f64, &row, windows[step * 15 ..][0..15]));
    }
}

test "bmpc row: refusals - a row or a step of the wrong width" {
    const step: TestBmpc.Step = .{
        .observation = &.{ 1, 2, 3 },
        .action = &.{ 0, 0 },
        .reward = 0,
        .next_observation = &.{ 1, 2 },
        .terminated = false,
        .truncated = false,
        .target = null,
    };
    var row: [15]f64 = undefined;
    try expectError(error.ShapeMismatch, row_test_layout.fill(&row, step));
    var short_row: [14]f64 = undefined;
    const fitting: TestBmpc.Step = .{
        .observation = &.{ 1, 2, 3 },
        .action = &.{ 0, 0 },
        .reward = 0,
        .next_observation = &.{ 1, 2, 3 },
        .terminated = false,
        .truncated = false,
        .target = null,
    };
    try expectError(error.ShapeMismatch, row_test_layout.fill(&short_row, fitting));
}

// ---- The world-model update's known answers: horizon 3, two windows, on the acting tests' small networks. The replay
// holds exactly three steps of one character, so both windows are that whole stretch - every number is known.

const learner_test_row: TestBmpc.Row = .{ .observation_width = 4, .action_width = 2 };

fn learnerTestConfig(gradient_clip: f64) TestBmpc.Config {
    var config: TestBmpc.Config = test_config;
    config.windows = 2;
    config.gradient_clip = gradient_clip;
    return config;
}

/// Step i's observation is [i, i + 0.1, i + 0.2, i + 0.3]; its successor starts at i + 1.
fn learnerTestObservation(step: usize) [4]f64 {
    const base: f64 = @floatFromInt(step);
    return .{ base, base + 0.1, base + 0.2, base + 0.3 };
}

fn learnerTestAction(step: usize) [2]f64 {
    const base: f64 = @floatFromInt(step);
    return .{ 0.1 * base, -0.1 * base };
}

fn learnerTestReward(step: usize) f64 {
    const base: f64 = @floatFromInt(step);
    return 0.5 + base;
}

/// The planner's target stored with step i: means [0.1 i, -0.2 i], spreads [0.2 + 0.1 i, 0.5].
fn learnerTestTargetMeans(step: usize) [2]f64 {
    const base: f64 = @floatFromInt(step);
    return .{ 0.1 * base, -0.2 * base };
}

fn learnerTestTargetSpreads(step: usize) [2]f64 {
    const base: f64 = @floatFromInt(step);
    return .{ 0.2 + 0.1 * base, 0.5 };
}

/// One character's ring holding exactly three steps - with the planner's targets when `planned`, empty otherwise.
fn learnerTestReplay(arena: Allocator, planned: bool) !zrl.SequenceReplay(f64) {
    var replay: zrl.SequenceReplay(f64) = try .init(
        arena,
        1,
        16,
        learner_test_row.width(),
        learner_test_row.doneColumn(),
    );
    for (0..3) |step| {
        const observation: [4]f64 = learnerTestObservation(step);
        const next_observation: [4]f64 = learnerTestObservation(step + 1);
        const action: [2]f64 = learnerTestAction(step);
        const target_means: [2]f64 = learnerTestTargetMeans(step);
        const target_spreads: [2]f64 = learnerTestTargetSpreads(step);
        const planned_target: TestBmpc.Target = .{ .means = &target_means, .spreads = &target_spreads };
        const stored_step: TestBmpc.Step = .{
            .observation = &observation,
            .action = &action,
            .reward = learnerTestReward(step),
            .next_observation = &next_observation,
            .terminated = false,
            .truncated = false,
            .target = if (planned) planned_target else null,
        };
        var row: [17]f64 = undefined;
        try learner_test_row.fill(&row, stored_step);
        try replay.push(&row, &.{true});
    }
    return replay;
}

/// Every number of `network`, flattened, copied out.
fn copyNumbers(arena: Allocator, network: Mlp(f64)) ![]f64 {
    const numbers: zn.Params(f64) = try network.params(arena);
    var total: usize = 0;
    for (numbers.tensors) |tensor| {
        total += tensor.data.len;
    }
    const copied: []f64 = try arena.alloc(f64, total);
    var filled: usize = 0;
    for (numbers.tensors) |tensor| {
        @memcpy(copied[filled..][0..tensor.data.len], tensor.data);
        filled += tensor.data.len;
    }
    return copied;
}

/// The largest |after - before| over two copies of the same numbers.
fn largestChange(before: []const f64, after: []const f64) f64 {
    var largest: f64 = 0;
    for (before, after) |old, new| {
        largest = @max(largest, @abs(new - old));
    }
    return largest;
}

test "bmpc learner: the windows laid out - observation blocks, actions, targets' observations, reward two-hots" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = learnerTestConfig(20);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    const learner: TestBmpc.WorldModelLearner = try .init(arena, networks, 4, 2, config);
    const replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, false);
    try replay.sample(Rng.init(1), 0, 3, learner.origins, learner.window_rows, learner.finished);
    try learner.loadWindows();
    for (0..2) |window| {
        // Block 0: where the window starts - step 0's observation.
        const start: [4]f64 = learnerTestObservation(0);
        try expect(eql(f64, &start, learner.observations.data[window * 4 ..][0..4]));
        for (0..3) |step| {
            // Block step + 1: the observation that FOLLOWED step `step` - its successor, from its own row.
            const successor: [4]f64 = learnerTestObservation(step + 1);
            const successor_row: usize = (step + 1) * 2 + window;
            try expect(eql(f64, &successor, learner.observations.data[successor_row * 4 ..][0..4]));
            const action: [2]f64 = learnerTestAction(step);
            try expect(eql(f64, &action, learner.actions[step].data[window * 2 ..][0..2]));
            const observation: [4]f64 = learnerTestObservation(step);
            const stored_index: usize = step * 2 + window;
            try expect(eql(f64, &observation, learner.targets.observations.data[stored_index * 4 ..][0..4]));
        }
    }
    // The reward targets read back as the rewards (a two-hot holds its number exactly, up to rounding).
    for (0..3) |step| {
        var decoded: [2]f64 = undefined;
        try config.bins.decodeRows(learner.loss.reward_targets[step], &decoded);
        for (decoded) |reward| {
            try expect(@abs(reward - learnerTestReward(step)) < 1e-9);
        }
    }
}

test "bmpc learner: one update - the clip to its limit, the encoder's step 0.3 x the rest, the target heads' follow" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // A tiny clip limit, so the clip surely bites.
    const clip_limit: f64 = 1e-3;
    const config: TestBmpc.Config = learnerTestConfig(clip_limit);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.WorldModelLearner = try .init(arena, networks, 4, 2, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, false);
    const encoder_before: []f64 = try copyNumbers(arena, networks.encoder);
    const dynamics_before: []f64 = try copyNumbers(arena, networks.dynamics[0]);
    const target_before: []f64 = try copyNumbers(arena, networks.target_values[0]);
    const report: TestBmpc.WorldModelReport = try learner.update(&replay, Rng.init(5), 0);
    // The clip: the norm was above the limit; every gradient is now scaled so the global norm IS the limit.
    try expect(report.gradient_norm > clip_limit);
    var squares: f64 = 0;
    for (learner.model_parameters) |parameter| {
        for ((try learner.graph.gradOf(parameter)).data) |slope| {
            squares += slope * slope;
        }
    }
    try expect(@abs(@sqrt(squares) - clip_limit) < 1e-12);
    // Adam's first step: about the rate whatever the gradient - never more - and the encoder at 0.3 x it.
    const rate: f64 = config.learning_rate;
    const encoder_rate: f64 = rate * config.encoder_rate_scale;
    const encoder_change: f64 = largestChange(encoder_before, try copyNumbers(arena, networks.encoder));
    const dynamics_change: f64 = largestChange(dynamics_before, try copyNumbers(arena, networks.dynamics[0]));
    try expect(encoder_change <= encoder_rate * (1 + 1e-9) and encoder_change > encoder_rate * 0.99);
    try expect(dynamics_change <= rate * (1 + 1e-9) and dynamics_change > rate * 0.99);
    // The follow, number by number: the target moves 1% of the way to its online twin as it is NOW.
    const online_after: []f64 = try copyNumbers(arena, networks.values[0]);
    const target_after: []f64 = try copyNumbers(arena, networks.target_values[0]);
    for (target_before, online_after, target_after) |before, online, after| {
        const followed: f64 = before + config.target_follow * (online - before);
        try expect(@abs(followed - after) < 1e-15);
    }
}

test "bmpc learner: the same seed makes the same update, every number bit for bit" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = learnerTestConfig(20);
    var reports: [2]TestBmpc.WorldModelReport = undefined;
    var encoders: [2][]f64 = undefined;
    var target_heads: [2][]f64 = undefined;
    for (&reports, &encoders, &target_heads) |*report, *encoder, *target_head| {
        const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
        var learner: TestBmpc.WorldModelLearner = try .init(arena, networks, 4, 2, config);
        var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, false);
        report.* = try learner.update(&replay, Rng.init(9), 0);
        encoder.* = try copyNumbers(arena, networks.encoder);
        target_head.* = try copyNumbers(arena, networks.target_values[1]);
    }
    try expectEqual(reports[0].total, reports[1].total);
    try expectEqual(reports[0].gradient_norm, reports[1].gradient_norm);
    try expect(eql(f64, encoders[0], encoders[1]));
    try expect(eql(f64, target_heads[0], target_heads[1]));
}

// ---- The policy's half and the whole update: the same small agent, the same three stored steps.

test "bmpc policy learner: the latents are those of the world model's forward pass" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = learnerTestConfig(20);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.Learner = try .init(arena, networks, 4, 2, config);
    const replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    _ = try learner.world_model.update(&replay, Rng.init(3), 0);
    // z_0 .. z_2 as the world model's forward pass computed them. Its optimiser has since changed the weights, but
    // not these values.
    const forward_latents: []f64 = try arena.alloc(f64, learner.policy.latents.data.len);
    const block: usize = forward_latents.len / 3;
    for (0..3) |step| {
        const rolled: []const f64 = learner.world_model.graph.valueOf(learner.world_model.rollout.rolled[0][step]).data;
        @memcpy(forward_latents[step * block ..][0..block], rolled);
    }
    _ = try learner.policy.update(&learner.world_model);
    try expect(eql(f64, forward_latents, learner.policy.latents.data));
}

test "bmpc policy learner: the targets are the stored means and the logarithms of the stored spreads" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = learnerTestConfig(20);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.Learner = try .init(arena, networks, 4, 2, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    _ = try learner.update(&replay, Rng.init(3), 0, false);
    for (0..3) |step| {
        const means: [2]f64 = learnerTestTargetMeans(step);
        const spreads: [2]f64 = learnerTestTargetSpreads(step);
        for (0..2) |window| {
            const stored_index: usize = step * 2 + window;
            for (0..2) |dimension| {
                const at: usize = stored_index * 2 + dimension;
                try expectEqual(means[dimension], learner.policy.loss.target_means.data[at]);
                try expectEqual(@log(spreads[dimension]), learner.policy.loss.target_log_stds.data[at]);
            }
        }
    }
}

test "bmpc learner: each half updates only its own networks; pretraining leaves the policy unchanged" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = learnerTestConfig(20);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.Learner = try .init(arena, networks, 4, 2, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    const policy_before: []f64 = try copyNumbers(arena, networks.policy);
    const encoder_before: []f64 = try copyNumbers(arena, networks.encoder);
    // Pretraining: the world model learns; the policy stays unchanged.
    const pretraining_report: TestBmpc.LearnerReport = try learner.update(&replay, Rng.init(4), 0, true);
    try expect(pretraining_report.policy == null);
    try expect(eql(f64, policy_before, try copyNumbers(arena, networks.policy)));
    try expect(!eql(f64, encoder_before, try copyNumbers(arena, networks.encoder)));
    // The policy update alone: the policy changes; the world model's networks do not.
    const world_model_networks = [_]Mlp(f64){
        networks.encoder,
        networks.dynamics[0],
        networks.reward,
        networks.values[0],
    };
    var world_model_before: [4][]f64 = undefined;
    for (world_model_networks, &world_model_before) |network, *numbers| {
        numbers.* = try copyNumbers(arena, network);
    }
    _ = try learner.policy.update(&learner.world_model);
    try expect(!eql(f64, policy_before, try copyNumbers(arena, networks.policy)));
    for (world_model_networks, world_model_before) |network, numbers| {
        try expect(eql(f64, numbers, try copyNumbers(arena, network)));
    }
}

test "bmpc policy learner: the policy's gradients are clipped to the limit" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // A very small limit, so that the clip applies.
    const clip_limit: f64 = 1e-6;
    const config: TestBmpc.Config = learnerTestConfig(clip_limit);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.Learner = try .init(arena, networks, 4, 2, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    const report: TestBmpc.LearnerReport = try learner.update(&replay, Rng.init(6), 0, false);
    const policy_report: TestBmpc.PolicyReport = report.policy orelse return error.TestUnexpectedResult;
    try expect(policy_report.gradient_norm > clip_limit);
    var squares: f64 = 0;
    for (learner.policy.parameters) |parameter| {
        for ((try learner.policy.graph.gradOf(parameter)).data) |slope| {
            squares += slope * slope;
        }
    }
    try expect(@abs(@sqrt(squares) - clip_limit) < 1e-15);
}

test "bmpc: the discount for episodes of 50, 100, 500 and 1000 steps" {
    // n = L / 5, gamma = (n - 1) / n, clamped to [0.95, 0.995].
    try expectEqual(@as(f64, 0.95), TestBmpc.discountFor(50)); // frac 10 -> 0.9, clamped up
    try expect(@abs(TestBmpc.discountFor(100) - 0.95) < 1e-15); // frac 20 -> 19 / 20
    try expect(@abs(TestBmpc.discountFor(500) - 0.99) < 1e-15); // frac 100 -> 99 / 100
    try expectEqual(@as(f64, 0.995), TestBmpc.discountFor(1000)); // frac 200 -> 0.995, the ceiling itself
}

test "bmpc config: BMPC's preset is every default, with the discount from the episode's length" {
    const config: TestBmpc.Config = .bmpc(1000);
    // L = 1000: gamma = 0.995, the ceiling.
    try expectEqual(@as(f64, 0.995), config.discount);
    const defaults: TestBmpc.Config = .{ .discount = 0.995 };
    try expectEqualDeep(defaults, config);
    // Table 2's BMPC column, spot-checked: both planners alike.
    try expectEqual(@as(usize, 3), config.acting.horizon);
    try expectEqual(@as(usize, 512), config.reanalyzing.candidates);
    try expectEqual(@as(usize, 256), config.windows);
}

test "bmpc config: EfficientTDMPC's preset differs from BMPC's exactly where Table 2 says" {
    const efficient: TestBmpc.Config = .efficientTdmpc(1000, true);
    try expectEqual(@as(usize, 4), efficient.dynamics_heads);
    try expectEqual(@as(usize, 6), efficient.acting.horizon);
    try expectEqual(PlanObjective.mean_over_depths, efficient.acting.objective);
    try expectEqual(PlanObjective.final, efficient.reanalyzing.objective);
    // Pessimism in reanalyze only, and only where episodes can end early.
    try expectEqual(@as(f64, 10), efficient.reanalyzing.pessimism);
    try expectEqual(@as(f64, 0), efficient.acting.pessimism);
    const without_falls: TestBmpc.Config = .efficientTdmpc(1000, false);
    try expectEqual(@as(f64, 0), without_falls.reanalyzing.pessimism);
    try expectEqual(@as(usize, 3), efficient.reanalyzing.horizon);
    try expectEqual(@as(usize, 64), efficient.reanalyzing.candidates);
    try expectEqual(@as(usize, 8), efficient.reanalyzing.elites);
    try expectEqual(@as(usize, 3), efficient.reanalyzing.policy_candidates);
    // With those set back to BMPC's, nothing else differs.
    var restored: TestBmpc.Config = efficient;
    restored.dynamics_heads = 1;
    restored.acting.horizon = 3;
    restored.acting.objective = .final;
    restored.reanalyzing = .{};
    try expectEqualDeep(TestBmpc.Config.bmpc(1000), restored);
}

test "bmpc networks: an ensemble of dynamics heads - the first is the single head's, the others differ" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const single: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        test_config,
    );
    var ensemble_config: TestBmpc.Config = test_config;
    ensemble_config.dynamics_heads = 4;
    const ensemble: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        ensemble_config,
    );
    try expectEqual(@as(usize, 1), single.dynamics.len);
    try expectEqual(@as(usize, 4), ensemble.dynamics.len);
    // Head 0 draws from the single head's stream: the same numbers. And the other networks are untouched by the
    // extra heads - their streams are their own.
    const single_networks = [_]Mlp(f64){
        single.dynamics[0], single.encoder, single.reward, single.policy, single.values[0], single.target_values[0],
    };
    const ensemble_networks = [_]Mlp(f64){
        ensemble.dynamics[0],      ensemble.encoder, ensemble.reward, ensemble.policy, ensemble.values[0],
        ensemble.target_values[0],
    };
    for (single_networks, ensemble_networks) |single_network, ensemble_network| {
        const single_numbers: []f64 = try copyNumbers(arena, single_network);
        try expect(eql(f64, single_numbers, try copyNumbers(arena, ensemble_network)));
    }
    // Every pair of heads starts different.
    for (0..4) |first| {
        for (first + 1..4) |second| {
            const first_numbers: []f64 = try copyNumbers(arena, ensemble.dynamics[first]);
            const second_numbers: []f64 = try copyNumbers(arena, ensemble.dynamics[second]);
            try expect(!eql(f64, first_numbers, second_numbers));
        }
    }
    // No dynamics head at all is not a configuration.
    var headless_config: TestBmpc.Config = test_config;
    headless_config.dynamics_heads = 0;
    try expectError(
        error.NoDynamicsHead,
        TestBmpc.Networks.init(arena, Rng.init(70), test_observation_width, test_action_width, headless_config),
    );
}

/// An exact copy of `network`: the same numbers in tensors of its own.
fn twinOf(network: Mlp(f64), arena: Allocator) !Mlp(f64) {
    const copied: Params(f64) = try (try network.params(arena)).clone(arena);
    return network.withParams(copied, arena);
}

test "bmpc ensemble: two identical dynamics heads report exactly the one-head world-model loss" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // No dropout: two graphs hold different dropout nodes, and the comparison is to the bit.
    var config: TestBmpc.Config = learnerTestConfig(20);
    config.value_dropout = 0;
    var ensemble_config: TestBmpc.Config = config;
    ensemble_config.dynamics_heads = 2;
    const single: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    const ensemble: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, ensemble_config);
    // The second head made an exact copy of the first: the heads agree everywhere.
    ensemble.dynamics[1] = try twinOf(ensemble.dynamics[0], arena);
    var single_learner: TestBmpc.WorldModelLearner = try .init(arena, single, 4, 2, config);
    var ensemble_learner: TestBmpc.WorldModelLearner = try .init(arena, ensemble, 4, 2, ensemble_config);
    var single_replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, false);
    var ensemble_replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, false);
    const single_report: TestBmpc.WorldModelReport = try single_learner.update(&single_replay, Rng.init(5), 0);
    const ensemble_report: TestBmpc.WorldModelReport = try ensemble_learner.update(
        &ensemble_replay,
        Rng.init(5),
        0,
    );
    // The same targets (both heads lead to the same latents) and every term averaged: (x + x) / 2 = x.
    try expectEqual(single_report.consistency, ensemble_report.consistency);
    try expectEqual(single_report.reward, ensemble_report.reward);
    try expectEqual(single_report.value, ensemble_report.value);
    try expectEqual(single_report.total, ensemble_report.total);
}

test "bmpc ensemble: one update moves every dynamics head, and the policy learns on every head's latents" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var config: TestBmpc.Config = learnerTestConfig(20);
    config.dynamics_heads = 3;
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.Learner = try .init(arena, networks, 4, 2, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    var heads_before: [3][]f64 = undefined;
    for (&heads_before, networks.dynamics) |*before, dynamics_head| {
        before.* = try copyNumbers(arena, dynamics_head);
    }
    _ = try learner.update(&replay, Rng.init(6), 0, false);
    // Every head trained.
    for (heads_before, networks.dynamics) |before, dynamics_head| {
        try expect(largestChange(before, try copyNumbers(arena, dynamics_head)) > 0);
    }
    // The policy's batch: every head's windows at every step - H x heads x W rows.
    const policy: TestBmpc.PolicyLearner = learner.policy;
    const latent_width: usize = policy.latents.shape[1];
    try expectEqual(config.horizon * 3 * config.windows, policy.latents.shape[0]);
    // At step 0 every head's block is the one encoded latent; at step 1 the heads have parted.
    const block_numbers: usize = config.windows * latent_width;
    const step_zero_head_zero: []const f64 = policy.latents.data[0..block_numbers];
    const step_one_head_zero: []const f64 = policy.latents.data[3 * block_numbers ..][0..block_numbers];
    for (1..3) |dynamics_head_index| {
        const step_zero_start: usize = dynamics_head_index * block_numbers;
        const step_zero_block: []const f64 = policy.latents.data[step_zero_start..][0..block_numbers];
        try expect(eql(f64, step_zero_head_zero, step_zero_block));
        const step_one_start: usize = (3 + dynamics_head_index) * block_numbers;
        const step_one_block: []const f64 = policy.latents.data[step_one_start..][0..block_numbers];
        try expect(!eql(f64, step_one_head_zero, step_one_block));
    }
}

/// BMPC starts the reward and value heads' last layers at zero, so an untrained model scores every plan alike - the
/// same reward and the same value whatever the latent. This gives both heads random numbers, in place, so that plans'
/// scores differ: what a test of planning diagnostics needs to see.
fn wakeScoringHeads(networks: TestBmpc.Networks, arena: Allocator, rng: Rng) !void {
    const reward_parameters: Params(f64) = try networks.reward.params(arena);
    var head_parameters: [8]Params(f64) = undefined;
    head_parameters[0] = reward_parameters;
    for (networks.values, 1..) |value_head, head_index| {
        head_parameters[head_index] = try value_head.params(arena);
    }
    const head_count: usize = 1 + networks.values.len;
    for (head_parameters[0..head_count], 0..) |parameters, head_index| {
        const head_rng: Rng = rng.split(@intCast(head_index));
        for (parameters.tensors, 0..) |tensor, tensor_index| {
            const tensor_rng: Rng = head_rng.split(@intCast(tensor_index));
            for (tensor.data, 0..) |*number, number_index| {
                number.* = 0.3 * tensor_rng.normal(f64, @intCast(number_index));
            }
        }
    }
}

test "bmpc config: reanalyze's pessimism reaches the reanalyze planner and leaves acting untouched" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var config: TestBmpc.Config = learnerTestConfig(20);
    config.dynamics_heads = 2;
    var pessimistic: TestBmpc.Config = config;
    pessimistic.reanalyzing.pessimism = 10;
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        config,
    );
    // Awake heads: the scores differ and the heads disagree, so a pessimism that leaked into acting would show.
    try wakeScoringHeads(networks, arena, Rng.init(71));
    // The acting planners of the two configurations decide alike, to the bit.
    const plain_actor: TestBmpc.Actor = try .init(
        arena,
        networks,
        test_observation_width,
        test_action_width,
        test_states,
        config,
        config.acting,
    );
    const pessimistic_actor: TestBmpc.Actor = try .init(
        arena,
        networks,
        test_observation_width,
        test_action_width,
        test_states,
        pessimistic,
        pessimistic.acting,
    );
    try expectEqual(@as(f64, 0), pessimistic_actor.scorer.options.pessimism);
    const observations: [test_states * test_observation_width]f64 = testObservations(1);
    const first_steps: [test_states]bool = @splat(true);
    const decided: usize = test_states * test_action_width;
    var decisions: [2]TestBmpc.Decision = undefined;
    for (&decisions, [_]TestBmpc.Actor{ plain_actor, pessimistic_actor }) |*decision, actor| {
        decision.* = .{
            .actions = try arena.alloc(f64, decided),
            .target_means = try arena.alloc(f64, decided),
            .target_spreads = try arena.alloc(f64, decided),
        };
        try actor.act(&observations, &first_steps, .explore, Rng.init(4), decision.*);
    }
    try expectEqualSlices(f64, decisions[0].actions, decisions[1].actions);
    try expectEqualSlices(f64, decisions[0].target_means, decisions[1].target_means);
    // The reanalyze planner carries it.
    const learner: TestBmpc.Learner = try .init(
        arena,
        networks,
        test_observation_width,
        test_action_width,
        pessimistic,
    );
    try expectEqual(@as(f64, 10), learner.reanalyzer.actor.scorer.options.pessimism);
}

test "bmpc actor: the chosen plan's first action is the decision's target" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const actor: TestBmpc.Actor = try testActor(arena);
    var plan: [3 * test_action_width]f64 = undefined;
    try expectError(error.NoChosenPlan, actor.copyChosenPlan(0, &plan));
    const observations: [test_states * test_observation_width]f64 = testObservations(1);
    const first_steps: [test_states]bool = @splat(true);
    const decided: usize = test_states * test_action_width;
    const decision: TestBmpc.Decision = .{
        .actions = try arena.alloc(f64, decided),
        .target_means = try arena.alloc(f64, decided),
        .target_spreads = try arena.alloc(f64, decided),
    };
    try actor.act(&observations, &first_steps, .evaluate, Rng.init(2), decision);
    for (0..test_states) |state| {
        try actor.copyChosenPlan(state, &plan);
        const target: []const f64 = decision.target_means[state * test_action_width ..][0..test_action_width];
        try expectEqualSlices(f64, target, plan[0..test_action_width]);
    }
}

test "bmpc cross-scoring: each model scores its planner's chosen plan as the planner did, Delta R by hand" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var config: TestBmpc.Config = learnerTestConfig(20);
    config.dynamics_heads = 2;
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        config,
    );
    try wakeScoringHeads(networks, arena, Rng.init(71));
    const cross_scoring: TestBmpc.CrossScoring = try .init(
        arena,
        networks,
        test_observation_width,
        test_action_width,
        test_states,
        config,
    );
    const observations: [test_states * test_observation_width]f64 = testObservations(1);
    try cross_scoring.scoreUnderModels(&observations, Rng.init(5));
    const plan_numbers: usize = cross_scoring.horizon * test_action_width;
    const policy_plan: []f64 = try arena.alloc(f64, plan_numbers);
    for (0..test_states) |state| {
        // The single-head planner's own score of the plan it chose is the single-head evaluator's, to the bit; the
        // same for the ensemble.
        const single_head_row: usize = cross_scoring.single_head_actor.mppi.chosen_rows[state];
        const single_head_score: f64 = cross_scoring.single_head_actor.candidate_scores[single_head_row];
        try expectEqual(single_head_score, cross_scoring.modelValue(.single_head, state, .single_head_plan));
        const ensemble_row: usize = cross_scoring.ensemble_actor.mppi.chosen_rows[state];
        const ensemble_score: f64 = cross_scoring.ensemble_actor.candidate_scores[ensemble_row];
        try expectEqual(ensemble_score, cross_scoring.modelValue(.ensemble, state, .ensemble_plan));
        // Both planners drew the same policy plan.
        try cross_scoring.single_head_actor.copyPolicyPlan(state, policy_plan);
        try expectEqualSlices(f64, policy_plan, cross_scoring.planOf(state, .policy_plan));
    }
    // The heads disagree: the policy's plan scores differently under one head and under the ensemble.
    const policy_under_one_head: f64 = cross_scoring.modelValue(.single_head, 0, .policy_plan);
    try expect(policy_under_one_head != cross_scoring.modelValue(.ensemble, 0, .policy_plan));
    // Delta R: each plan's value minus the policy's, averaged over the states - by hand.
    const evaluators = [_]TestBmpc.CrossScoring.Evaluator{ .single_head, .ensemble };
    const kinds = [_]TestBmpc.CrossScoring.PlanKind{ .single_head_plan, .ensemble_plan };
    for (evaluators) |evaluator| {
        for (kinds) |kind| {
            var advantage_sum: f64 = 0;
            for (0..test_states) |state| {
                const plan_value: f64 = cross_scoring.modelValue(evaluator, state, kind);
                const policy_value: f64 = cross_scoring.modelValue(evaluator, state, .policy_plan);
                advantage_sum += plan_value - policy_value;
            }
            const state_count: f64 = @floatFromInt(test_states);
            const by_hand: f64 = advantage_sum / state_count;
            try expectApproxEqAbs(by_hand, cross_scoring.meanAdvantage(evaluator, kind), 1e-12);
        }
    }
}

test "bmpc cross-scoring: identical heads plan alike and score alike" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var config: TestBmpc.Config = learnerTestConfig(20);
    config.dynamics_heads = 2;
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        config,
    );
    networks.dynamics[1] = try twinOf(networks.dynamics[0], arena);
    try wakeScoringHeads(networks, arena, Rng.init(71));
    const cross_scoring: TestBmpc.CrossScoring = try .init(
        arena,
        networks,
        test_observation_width,
        test_action_width,
        test_states,
        config,
    );
    const observations: [test_states * test_observation_width]f64 = testObservations(1);
    try cross_scoring.scoreUnderModels(&observations, Rng.init(5));
    for (0..test_states) |state| {
        const single_head_plan: []const f64 = cross_scoring.planOf(state, .single_head_plan);
        const ensemble_plan: []const f64 = cross_scoring.planOf(state, .ensemble_plan);
        try expectEqualSlices(f64, single_head_plan, ensemble_plan);
    }
    const values_per_evaluator: usize = test_states * TestBmpc.CrossScoring.plan_kind_count;
    const single_head_values: []const f64 = cross_scoring.model_values[0..values_per_evaluator];
    const ensemble_values: []const f64 = cross_scoring.model_values[values_per_evaluator..][0..values_per_evaluator];
    try expectEqualSlices(f64, single_head_values, ensemble_values);
}

test "bmpc config: two more MPPI rounds from 20 action dimensions, as BMPC's code counts them" {
    // test_config plans 4 rounds: 19 dimensions keep them, 20 and 21 get two more.
    try expectEqual(@as(usize, 4), test_config.acting.iterationsFor(19));
    try expectEqual(@as(usize, 6), test_config.acting.iterationsFor(20));
    try expectEqual(@as(usize, 6), test_config.acting.iterationsFor(21));
    // And an actor for a 20-dimensional action plans with them.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const wide_action: usize = 20;
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        wide_action,
        test_config,
    );
    const actor: TestBmpc.Actor = try .init(
        arena,
        networks,
        test_observation_width,
        wide_action,
        1,
        test_config,
        test_config.acting,
    );
    try expectEqual(@as(usize, 6), actor.mppi.options.iterations);
}

test "bmpc config: the acting planner's horizon sets the plans' length, and the training window stays" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // EfficientTDMPC's acting horizon, with BMPC's training window and reanalyze planner.
    var config: TestBmpc.Config = learnerTestConfig(20);
    config.acting.horizon = 6;
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        config,
    );
    const actor: TestBmpc.Actor = try .init(
        arena,
        networks,
        test_observation_width,
        test_action_width,
        test_states,
        config,
        config.acting,
    );
    try expectEqual(@as(usize, 6), actor.mppi.options.horizon);
    const learner: TestBmpc.Learner = try .init(arena, networks, test_observation_width, test_action_width, config);
    // The training window: three steps, one action tensor each.
    try expectEqual(@as(usize, 3), learner.world_model.actions.len);
    // Reanalyze plans with its own planner.
    try expectEqual(@as(usize, 3), learner.reanalyzer.actor.mppi.options.horizon);
    // A decision with the longer plans runs.
    const observations: [test_states * test_observation_width]f64 = testObservations(1);
    const decided: usize = test_states * test_action_width;
    const decision: TestBmpc.Decision = .{
        .actions = try arena.alloc(f64, decided),
        .target_means = try arena.alloc(f64, decided),
        .target_spreads = try arena.alloc(f64, decided),
    };
    const first_steps: [test_states]bool = @splat(true);
    try actor.act(&observations, &first_steps, .evaluate, Rng.init(1), decision);
    for (decision.actions) |action| {
        try expect(action >= -1 and action <= 1);
    }
}

test "bmpc schedule: one environment at ratio 1 is torch's - 5000 random steps, a burst of 5000, then 1" {
    // L = 1000: max(5 x 1000, 1000) = 5000 seed frames, and with one environment frames are steps.
    const schedule: TestBmpc.Schedule = .bmpc(1, 1000, 1);
    try expectEqual(@as(usize, 5000), schedule.seed_frames);
    try expectEqual(@as(usize, 5000), schedule.burst_updates);
    try expectEqual(@as(usize, 1), schedule.updates_per_frame);
}

test "bmpc schedule: eight environments each seed five episodes - 1000 frames, a burst of 8000, then 8 a frame" {
    // L = 200: max(5 x 200, 1000) = 1000 seed frames in every environment, 8000 steps in all.
    const schedule: TestBmpc.Schedule = .bmpc(8, 200, 1);
    try expectEqual(@as(usize, 1000), schedule.seed_frames);
    try expectEqual(@as(usize, 8000), schedule.burst_updates);
    try expectEqual(@as(usize, 8), schedule.updates_per_frame);
    // Ratio 2: twice the updates for the same data, in the burst and after it.
    const doubled: TestBmpc.Schedule = .bmpc(8, 200, 2);
    try expectEqual(@as(usize, 1000), doubled.seed_frames);
    try expectEqual(@as(usize, 16000), doubled.burst_updates);
    try expectEqual(@as(usize, 16), doubled.updates_per_frame);
}

test "bmpc schedule: every environment finishes five episodes before the planner acts, whatever E and L" {
    const cases = [_]struct { environments: usize, episode_length: usize }{
        .{ .environments = 1, .episode_length = 50 },
        .{ .environments = 3, .episode_length = 4 },
        .{ .environments = 8, .episode_length = 200 },
        .{ .environments = 64, .episode_length = 1000 },
    };
    for (cases) |case| {
        const schedule: TestBmpc.Schedule = .bmpc(case.environments, case.episode_length, 1);
        // Seeding is counted per environment, so each one runs seed_frames steps: five episodes at least.
        try expect(schedule.seed_frames >= 5 * case.episode_length);
        try expect(schedule.seed_frames >= 1000);
        // One burst update for every seeded step.
        try expectEqual(schedule.seed_frames * case.environments, schedule.burst_updates);
    }
}

test "bmpc schedule: random until the last seed frame, the burst right after it, the planner from the next" {
    const schedule: TestBmpc.Schedule = .bmpc(8, 200, 1);
    const first: TestBmpc.Schedule.Frame = schedule.at(0);
    try expect(!first.planned and first.updates == 0 and !first.pretraining);
    const before_last: TestBmpc.Schedule.Frame = schedule.at(998);
    try expect(!before_last.planned and before_last.updates == 0);
    const last_seed: TestBmpc.Schedule.Frame = schedule.at(999);
    try expect(!last_seed.planned and last_seed.pretraining);
    try expectEqual(@as(usize, 8000), last_seed.updates);
    const first_steady: TestBmpc.Schedule.Frame = schedule.at(1000);
    try expect(first_steady.planned and !first_steady.pretraining);
    try expectEqual(@as(usize, 8), first_steady.updates);
    // Frames 0 to 1000: 8008 steps gathered and 8008 updates made - ratio 1 from the burst on.
    var steps: usize = 0;
    var updates: usize = 0;
    for (0..1001) |frame| {
        steps += 8;
        updates += schedule.at(frame).updates;
    }
    try expectEqual(@as(usize, 8008), steps);
    try expectEqual(steps, updates);
}

test "bmpc schedule: written out directly - a short seeding, and no seed frames means no burst" {
    // Two seed frames: random, then random followed by the burst, then the planner.
    const short: TestBmpc.Schedule = .{ .seed_frames = 2, .burst_updates = 6, .updates_per_frame = 3 };
    try expect(!short.at(0).planned and short.at(0).updates == 0);
    try expect(!short.at(1).planned and short.at(1).pretraining and short.at(1).updates == 6);
    try expect(short.at(2).planned and !short.at(2).pretraining and short.at(2).updates == 3);
    // No seed frames: the planner from frame 0, steady updates, and the burst never runs.
    const unseeded: TestBmpc.Schedule = .{ .seed_frames = 0, .burst_updates = 50, .updates_per_frame = 4 };
    try expect(unseeded.at(0).planned and !unseeded.at(0).pretraining and unseeded.at(0).updates == 4);
}

// ---- Reanalyze: the same small agent, with the first of its two windows planned again (both windows cover the
// replay's three steps).

fn reanalyzeTestConfig(interval: usize) TestBmpc.Config {
    var config: TestBmpc.Config = learnerTestConfig(20);
    config.reanalyze_windows = 1;
    config.reanalyze_interval = interval;
    return config;
}

/// A new actor with the exploration bounds, and its decision over the stored steps 0, 1 and 2, from scratch and
/// evaluated: the expected result of reanalyzing them.
const FreshReanalyze = struct {
    actor: TestBmpc.Actor,
    decision: TestBmpc.Decision,
};

fn freshReanalyze(
    arena: Allocator,
    networks: TestBmpc.Networks,
    config: TestBmpc.Config,
    rng: Rng,
) !FreshReanalyze {
    var exploring_config: TestBmpc.Config = config;
    exploring_config.spread = config.exploration_spread;
    const actor: TestBmpc.Actor = try .init(
        arena,
        networks,
        4,
        2,
        3,
        exploring_config,
        exploring_config.reanalyzing,
    );
    var observations: [12]f64 = undefined;
    for (0..3) |step| {
        const observation: [4]f64 = learnerTestObservation(step);
        @memcpy(observations[step * 4 ..][0..4], &observation);
    }
    const first_steps = [_]bool{ true, true, true };
    const decision: TestBmpc.Decision = .{
        .actions = try arena.alloc(f64, 6),
        .target_means = try arena.alloc(f64, 6),
        .target_spreads = try arena.alloc(f64, 6),
    };
    try actor.act(&observations, &first_steps, .evaluate, rng, decision);
    return .{ .actor = actor, .decision = decision };
}

test "bmpc reanalyze: the first windows are planned again and written to the replay and the batch" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = reanalyzeTestConfig(10);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.Learner = try .init(arena, networks, 4, 2, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    try learner.world_model.sample(&replay, Rng.init(2), 0);
    const fresh: FreshReanalyze = try freshReanalyze(arena, networks, config, Rng.init(8));
    const expected: TestBmpc.Decision = fresh.decision;
    try learner.reanalyzer.reanalyze(&learner.world_model, &replay, Rng.init(8));
    // The candidate plans match, including the policy's rows drawn with the exploration bounds. Fresh networks give
    // every candidate the same score, so the targets alone do not depend on the bounds.
    for (fresh.actor.scorer.actions, learner.reanalyzer.actor.scorer.actions) |fresh_step, reanalyzed_step| {
        try expect(eql(f64, fresh_step.data, reanalyzed_step.data));
    }
    const target_start: usize = learner_test_row.targetMeanStart();
    for (0..3) |step| {
        // The batch: window 0's rows hold the new targets; window 1's rows keep the old ones.
        const fresh_row: []const f64 = learner.world_model.window_rows[(step * 2) * 17 ..][0..17];
        try expect(eql(f64, expected.target_means[step * 2 ..][0..2], fresh_row[target_start..][0..2]));
        try expect(eql(f64, expected.target_spreads[step * 2 ..][0..2], fresh_row[target_start + 2 ..][0..2]));
        const old_row: []const f64 = learner.world_model.window_rows[(step * 2 + 1) * 17 ..][0..17];
        const old_means: [2]f64 = learnerTestTargetMeans(step);
        try expect(eql(f64, &old_means, old_row[target_start..][0..2]));
    }
    // The replay, sampled again with the same generator: its stored rows hold the new targets.
    var origins: [2]zrl.SequenceReplay(f64).WindowOrigin = undefined;
    var again: [3 * 2 * 17]f64 = undefined;
    var finished: [3 * 2]f64 = undefined;
    try replay.sample(Rng.init(2).split(0), 0, 3, &origins, &again, &finished);
    for (0..3) |step| {
        const stored_row: []const f64 = again[(step * 2) * 17 ..][0..17];
        try expect(eql(f64, expected.target_means[step * 2 ..][0..2], stored_row[target_start..][0..2]));
    }
}

test "bmpc reanalyze: every reanalyze starts from scratch" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = reanalyzeTestConfig(10);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.Learner = try .init(arena, networks, 4, 2, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    try learner.world_model.sample(&replay, Rng.init(2), 0);
    // The first reanalyze leaves its plans in the planner; the second still starts from scratch.
    try learner.reanalyzer.reanalyze(&learner.world_model, &replay, Rng.init(8));
    try learner.reanalyzer.reanalyze(&learner.world_model, &replay, Rng.init(9));
    const expected: TestBmpc.Decision = (try freshReanalyze(arena, networks, config, Rng.init(9))).decision;
    try expect(eql(f64, expected.target_means, learner.reanalyzer.decision.target_means));
    try expect(eql(f64, expected.target_spreads, learner.reanalyzer.decision.target_spreads));
}

test "bmpc learner: reanalyze runs every interval-th update outside pretraining, before the policy update" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = reanalyzeTestConfig(2);
    const networks: TestBmpc.Networks = try .init(arena, Rng.init(70), 4, 2, config);
    var learner: TestBmpc.Learner = try .init(arena, networks, 4, 2, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    // Pretraining does not count. Of the two updates after it, the second reanalyzes.
    try expect(!(try learner.update(&replay, Rng.init(11), 0, true)).reanalyzed);
    try expect(!(try learner.update(&replay, Rng.init(12), 1, false)).reanalyzed);
    try expect((try learner.update(&replay, Rng.init(13), 2, false)).reanalyzed);
    // The policy update used the new targets: window 0's rows of its targets come from this reanalyze.
    const fresh: TestBmpc.Decision = learner.reanalyzer.decision;
    for (0..3) |step| {
        const policy_row: usize = step * 2;
        for (0..2) |dimension| {
            const at: usize = policy_row * 2 + dimension;
            try expectEqual(fresh.target_means[step * 2 + dimension], learner.policy.loss.target_means.data[at]);
            const fresh_log_std: f64 = @log(fresh.target_spreads[step * 2 + dimension]);
            try expectEqual(fresh_log_std, learner.policy.loss.target_log_stds.data[at]);
        }
    }
    try expect(!(try learner.update(&replay, Rng.init(14), 3, false)).reanalyzed);
}

// ---- The whole agent: one set of networks, trained by the learner and read by the actor.

test "bmpc: what the learner changes, the actor reads at its next decision - one set of networks" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const config: TestBmpc.Config = learnerTestConfig(20);
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        config,
    );
    const actor: TestBmpc.Actor = try .init(
        arena,
        networks,
        test_observation_width,
        test_action_width,
        test_states,
        config,
        config.acting,
    );
    var learner: TestBmpc.Learner = try .init(arena, networks, test_observation_width, test_action_width, config);
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    const observations: [test_states * test_observation_width]f64 = testObservations(1);
    @memcpy(actor.scorer.observations.data, &observations);
    @memcpy(actor.plans.observations.data, &observations);
    try actor.plans.fill(actor.plans_graph, Rng.init(3), actor.scorer.actions);
    // Before learning, the zero-initialised reward and value heads score every plan 0.
    try actor.scorer.score(actor.scorer_graph, actor.candidate_scores);
    for (actor.candidate_scores) |score| {
        try expect(@abs(score) < 1e-12);
    }
    // One update moves the reward and value heads. The actor's graphs hold the SAME tensors, bound frozen, so the
    // same plans now score differently - with nothing rebuilt and nothing bound again.
    _ = try learner.update(&replay, Rng.init(5), 0, false);
    try actor.scorer.score(actor.scorer_graph, actor.candidate_scores);
    for (actor.candidate_scores) |score| {
        try expect(@abs(score) >= 1e-12);
    }
}

test "bmpc: once warm, an update asks its allocator for nothing - reanalyze included" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // The learner's allocator, counted. Its graphs size their scratch on first use; after that, every update - the
    // world model's half, the policy's, and every tenth one's reanalyze - must reuse what it has, or a run's memory
    // grows with its length.
    var counted: FailingAllocator = .init(arena, .{});
    const config: TestBmpc.Config = learnerTestConfig(20);
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        config,
    );
    var learner: TestBmpc.Learner = try .init(
        counted.allocator(),
        networks,
        test_observation_width,
        test_action_width,
        config,
    );
    var replay: zrl.SequenceReplay(f64) = try learnerTestReplay(arena, true);
    // Twelve updates warm everything up, the 10th of them reanalyzing.
    for (0..12) |index| {
        const update_index: u32 = @intCast(index);
        _ = try learner.update(&replay, Rng.init(5).split(update_index), update_index, false);
    }
    const warm: usize = counted.allocations;
    // Ten more, the 20th reanalyzing again.
    for (12..22) |index| {
        const update_index: u32 = @intCast(index);
        _ = try learner.update(&replay, Rng.init(5).split(update_index), update_index, false);
    }
    try expectEqual(warm, counted.allocations);
}

test "bmpc: once warm, a decision asks its allocator for nothing" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var counted: FailingAllocator = .init(arena, .{});
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(70),
        test_observation_width,
        test_action_width,
        test_config,
    );
    var actor: TestBmpc.Actor = try .init(
        counted.allocator(),
        networks,
        test_observation_width,
        test_action_width,
        test_states,
        test_config,
        test_config.acting,
    );
    const observations: [test_states * test_observation_width]f64 = testObservations(1);
    const decided: usize = test_states * test_action_width;
    const decision: TestBmpc.Decision = .{
        .actions = try arena.alloc(f64, decided),
        .target_means = try arena.alloc(f64, decided),
        .target_spreads = try arena.alloc(f64, decided),
    };
    // A first decision from scratch and a warm-started one size everything.
    const cold: [test_states]bool = @splat(true);
    const warm_start: [test_states]bool = @splat(false);
    try actor.act(&observations, &cold, .explore, Rng.init(1), decision);
    try actor.act(&observations, &warm_start, .explore, Rng.init(2), decision);
    const warm: usize = counted.allocations;
    for (3..8) |seed| {
        try actor.act(&observations, &warm_start, .explore, Rng.init(@intCast(seed)), decision);
    }
    try expectEqual(warm, counted.allocations);
}

// ---- The training loop, on a stand-in environment.

/// A stand-in environment for the loop's tests: a counter that climbs by one per step, shown as the observation's first
/// entry (the rest a constant 0.5). The reward is the action's first entry, so the replay's rewards show what was acted
/// on.
const RampEnvironment = struct {
    position: f64 = 0,
    resets: usize = 0,

    pub fn reset(self: *RampEnvironment, rng: Rng, observation: []f64) void {
        _ = rng;
        self.position = 0;
        self.resets += 1;
        observation[0] = self.position;
        @memset(observation[1..], 0.5);
    }

    pub fn step(self: *RampEnvironment, action: []const f64, observation: []f64) f64 {
        self.position += 1;
        observation[0] = self.position;
        @memset(observation[1..], 0.5);
        return action[0];
    }
};

const RampTrainer = TestBmpc.Trainer(RampEnvironment);

fn rampTrainer(
    arena: Allocator,
    environments: []RampEnvironment,
    schedule: TestBmpc.Schedule,
    episode_length: usize,
) !RampTrainer {
    const config: TestBmpc.Config = learnerTestConfig(20);
    const networks: TestBmpc.Networks = try .init(
        arena,
        Rng.init(90),
        test_observation_width,
        test_action_width,
        config,
    );
    return RampTrainer.init(
        arena,
        environments,
        networks,
        test_observation_width,
        test_action_width,
        config,
        schedule,
        episode_length,
        64,
        Rng.init(91),
    );
}

test "bmpc trainer: seeding acts at random in [-1, 1], stores the empty target and makes no update" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var environments = [_]RampEnvironment{ .{}, .{} };
    const schedule: TestBmpc.Schedule = .{ .seed_frames = 4, .burst_updates = 3, .updates_per_frame = 2 };
    var trainer: RampTrainer = try rampTrainer(arena, &environments, schedule, 5);
    for (0..3) |frame| {
        const ran: TestBmpc.Schedule.Frame = try trainer.runFrame();
        try expect(!ran.planned and ran.updates == 0);
        for (0..environments.len) |index| {
            const row: []const f64 = trainer.replay.environment_rings[index].row(frame);
            const action: []const f64 = row[trainer.row.actionStart()..][0..test_action_width];
            for (action) |value| {
                try expect(value >= -1 and value <= 1);
            }
            // The reward echoes what was acted on.
            try expectEqual(action[0], row[trainer.row.rewardColumn()]);
            // No planner answered: the empty target N(0, 1).
            for (row[trainer.row.targetMeanStart()..][0..test_action_width]) |mean| {
                try expectEqual(@as(f64, 0), mean);
            }
            for (row[trainer.row.targetSpreadStart()..][0..test_action_width]) |spread| {
                try expectEqual(@as(f64, 1), spread);
            }
        }
    }
    try expectEqual(@as(u32, 0), trainer.update_index);
}

test "bmpc trainer: the burst follows the last seed frame as pretraining, then the planner acts and updates count" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var environments = [_]RampEnvironment{ .{}, .{} };
    const schedule: TestBmpc.Schedule = .{ .seed_frames = 4, .burst_updates = 3, .updates_per_frame = 2 };
    var trainer: RampTrainer = try rampTrainer(arena, &environments, schedule, 5);
    for (0..3) |_| {
        _ = try trainer.runFrame();
    }
    try expect(trainer.last_report == null);
    // Frame 3, the last seed frame: still random, then the burst - three updates that train the world model only,
    // so the learner's count of real updates (which paces reanalyze) stays at zero.
    const burst: TestBmpc.Schedule.Frame = try trainer.runFrame();
    try expect(!burst.planned and burst.pretraining and burst.updates == 3);
    try expectEqual(@as(u32, 3), trainer.update_index);
    try expectEqual(@as(usize, 0), trainer.learner.updates);
    // The burst's report has the world model's half only: pretraining leaves the policy alone.
    try expect(trainer.last_report.?.policy == null);
    // Frame 4: the planner acts, and its two updates are real ones.
    const planned: TestBmpc.Schedule.Frame = try trainer.runFrame();
    try expect(planned.planned and !planned.pretraining and planned.updates == 2);
    try expectEqual(@as(u32, 5), trainer.update_index);
    try expectEqual(@as(usize, 2), trainer.learner.updates);
    try expect(trainer.last_report.?.policy != null);
    // The planned frame's rows hold the planner's targets, not the empty one.
    for (0..environments.len) |index| {
        const row: []const f64 = trainer.replay.environment_rings[index].row(4);
        const begin: usize = index * test_action_width;
        const means: []const f64 = trainer.decision.target_means[begin..][0..test_action_width];
        const spreads: []const f64 = trainer.decision.target_spreads[begin..][0..test_action_width];
        try expect(eql(f64, means, row[trainer.row.targetMeanStart()..][0..test_action_width]));
        try expect(eql(f64, spreads, row[trainer.row.targetSpreadStart()..][0..test_action_width]));
    }
}

test "bmpc trainer: an episode ends at its L-th step - truncated, the true final observation kept, then a reset" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var environments = [_]RampEnvironment{ .{}, .{} };
    const seeding_only: TestBmpc.Schedule = .{ .seed_frames = 100, .burst_updates = 0, .updates_per_frame = 0 };
    var trainer: RampTrainer = try rampTrainer(arena, &environments, seeding_only, 3);
    // `init` began the first episode in every environment.
    try expectEqual(@as(usize, 1), environments[0].resets);
    try expect(trainer.first_steps[0]);
    for (0..3) |_| {
        _ = try trainer.runFrame();
    }
    // The third step ended the episode: a fresh one has begun, and the next decision is its first.
    try expect(trainer.first_steps[0] and trainer.first_steps[1]);
    _ = try trainer.runFrame();
    try expect(!trainer.first_steps[0]);
    for (0..environments.len) |index| {
        const ring: zrl.ReplayBuffer(f64) = trainer.replay.environment_rings[index];
        // Steps 1 to 3: observations 0, 1, 2 and successors 1, 2, 3 - the last successor the TRUE final state.
        for (0..3) |step| {
            const row: []const f64 = ring.row(step);
            const ends: bool = step == 2;
            try expectEqual(float64(step), row[0]);
            try expectEqual(float64(step + 1), row[trainer.row.nextObservationStart()]);
            try expectEqual(@as(f64, if (ends) 1 else 0), row[trainer.row.doneColumn()]);
            try expectEqual(@as(f64, 0), row[trainer.row.terminatedColumn()]);
        }
        // The fourth row starts the second episode from the reset observation.
        try expectEqual(@as(f64, 0), ring.row(3)[0]);
        try expectEqual(@as(usize, 2), environments[index].resets);
    }
}

test "bmpc trainer: the same seeds run the same frames, bit for bit, through the burst and the planner" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const schedule: TestBmpc.Schedule = .{ .seed_frames = 4, .burst_updates = 2, .updates_per_frame = 1 };
    var first_environments = [_]RampEnvironment{ .{}, .{} };
    var second_environments = [_]RampEnvironment{ .{}, .{} };
    var first: RampTrainer = try rampTrainer(arena, &first_environments, schedule, 5);
    var second: RampTrainer = try rampTrainer(arena, &second_environments, schedule, 5);
    for (0..6) |_| {
        _ = try first.runFrame();
        _ = try second.runFrame();
        try expect(eql(f64, first.rows, second.rows));
    }
    for (0..first_environments.len) |index| {
        for (0..6) |step| {
            const first_row: []const f64 = first.replay.environment_rings[index].row(step);
            const second_row: []const f64 = second.replay.environment_rings[index].row(step);
            try expect(eql(f64, first_row, second_row));
        }
    }
}

test "bmpc trainer: the discount comes from the episode's length" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var environments = [_]RampEnvironment{.{}};
    const schedule: TestBmpc.Schedule = .{ .seed_frames = 10, .burst_updates = 0, .updates_per_frame = 0 };
    const trainer: RampTrainer = try rampTrainer(arena, &environments, schedule, 500);
    // L = 500: n = 100, gamma = 0.99 - whatever the config said (0.95).
    try expectEqual(TestBmpc.discountFor(500), trainer.learner.config.discount);
}
