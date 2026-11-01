//! robot_latent_kit - the latent world model on the kit: the GPU, or its CPU twin.
//!
//! `robot_latent` is the CPU reference: zimrnum's autodiff, clear and slow. This is the same model
//! laid out for the kit's kernels, so it can run - and, next, train - where the phone has compute
//! to spare. The plan's T9a design, in code:
//!
//!   * **One wide row per step.** Block `X_k` holds `rows` rows of `[z | reference | action]`,
//!     `width` floats apart. The dense layers read their input with a stride, so the first layer
//!     sees the three as one input and the concatenation is only this layout.
//!   * **The first layer, stacked.** The CPU model's first layer is three weight blocks summed
//!     (`W_z`, `W_r`, `W_a`); stacked in that order they ARE one layer over the wide row - and the
//!     kit adds its inputs in the same order the CPU model does, bias first.
//!   * **Steps joined by `lat_advance`**, which writes z + change into the next block's z columns
//!     and into a contiguous copy `Z_{k+1}` for the loss kernels.
//!
//! It holds the whole training step - `forward`, `backward` (weight gradients accumulated across the
//! rollout's steps; the loss SUMMED over steps), `adamStep` (epsilon scaled so the sum takes the CPU
//! model's exact step) and `trainStep`, all three - each checked against the CPU reference: the
//! rollout bitwise, every gradient to rounding, Adam to half an ulp.
//!
//! What it does NOT have yet is its data. Today the caller stages every window's inputs and targets
//! from the host - fine for tests, wrong for a phone: on one wasm core, computing features for every
//! record of every sampled window, every training step, is the most expensive thing training would
//! do, on the wrong processor. The plan's T9b replaces it: the replay of features lives on the GPU,
//! appended once per simulation step; the reference's goals are a table uploaded once per clip; and a
//! gather kernel builds each window on the GPU, normalising as it goes.

const std = @import("std");
const zn = @import("zn");
const compute_host = @import("compute_host.zig");
const latent = @import("robot_latent.zig");

const rbt = @import("robot");
const track = @import("robot_track.zig");
const kit_mlp = @import("kit_mlp.zig");
const bmpc_kit = @import("robot_bmpc_kit.zig");

const Allocator = std.mem.Allocator;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const zm = @import("zm");
const float = zm.float;
const assertf = zm.assertf;
const Random = std.Random;
const zrl = @import("zrl");
const Tensor = zn.Tensor(f32);

/// How many floats a kit buffer holds: its field's own array length.
fn floatsIn(comptime M: type, comptime field: []const u8) u32 {
    return @typeInfo(@FieldType(M.Buffers, field)).array.len;
}

/// SuperTrack's failure barrier (`zn_mlp.lat_barrier_bwd`): a smooth hinge, in the policy's loss at every rolled
/// step, on two of the task's failure measures read from the rolled features - the head's height error and the tilt
/// between the character's up and the reference's - so the pathwise gradient feels the failure rule's cliff before
/// the fall. Its weight 0, the loss is exactly the barrier-free one. An `extern struct`, so a learner's state file can
/// hold it as it holds every option.
pub const FailureBarrier = extern struct {
    /// The barrier's weight in the policy's loss, per metre (or per unit of tilt error) past a margin.
    weight: f32 = 0,
    /// The head height error the task's rule fails at (`robot_geno`'s 0.25 m), and the width the hinge rounds over.
    head_margin: f32 = 0.25,
    head_width: f32 = 0.05,
    /// The tilt error 1 - cos(up, up_ref) at 90 degrees, and its width.
    tilt_margin: f32 = 1.0,
    tilt_width: f32 = 0.1,
};

/// SUPERTRACK'S PER-STEP COST - its settings (`runTrackingCost`): the feature width, the failure barrier and the two
/// columns it reads (the head's height, the up direction), and where the normaliser is - read by the barrier alone, so
/// 0 when the barrier is off.
pub const TrackingCost = struct {
    features: u32,
    barrier: FailureBarrier,
    barrier_head_column: u32,
    barrier_up_column: u32,
    norm_at: u32,
    /// The cost's cap far from the reference (`zn_mlp.boundedCost`): what makes a critic's value there a time to
    /// return. 0 for none.
    cap: f32 = 0,
};

/// SUPERTRACK'S PER-STEP COST of `rows` states against their goals - the distance from the goal plus the failure
/// barrier (`zn_mlp.lat_tracking_cost`) - into acts at `costs_at` [rows], the states and goals packed [rows][features]
/// at `states_at` and `goals_at`. The one cost the critic's targets, the planner's scores and teacher 3's advantages
/// all charge - the cost the policy's loss charges a rolled step - written once, so a change to it reaches them all.
pub fn runTrackingCost(
    comptime M: type,
    pipe: *compute_host.Compute(M),
    cost: TrackingCost,
    rows: u32,
    states_at: u32,
    goals_at: u32,
    costs_at: u32,
) void {
    pipe.params = .{
        .rows = rows,
        .out_dim = cost.features,
        .y_off = states_at,
        .t_off = goals_at,
        .u_off = cost.norm_at,
        .x_off = costs_at,
        .barrier_head_column = cost.barrier_head_column,
        .barrier_up_column = cost.barrier_up_column,
        .barrier_weight = cost.barrier.weight,
        .barrier_head_margin = cost.barrier.head_margin,
        .barrier_head_width = cost.barrier.head_width,
        .barrier_tilt_margin = cost.barrier.tilt_margin,
        .barrier_tilt_width = cost.barrier.tilt_width,
        .cost_cap = cost.cap,
    };
    pipe.run("lat_tracking_cost", rows);
}

// ============================================================================================================
// THE CRITIC
// ============================================================================================================

/// SuperTrack's critic's settings (`LatentCritic`): its shape, its discount, and how each update steps -
/// EfficientTDMPC's value heads' settings. An `extern struct`, so a learner's state file can hold it as it holds every
/// option.
pub const CriticOptions = extern struct {
    heads: u32 = 2,
    hidden: u32 = 32,
    /// gamma per physics step: 1 - 1/90, a horizon of a second and a half at 60 Hz - about how long a fall and what
    /// follows it take.
    discount: f32 = 1.0 - 1.0 / 90.0,
    seed: u32 = 1,
    learning_rate: f32 = 3e-4,
    /// The limit on the online heads' global gradient norm.
    gradient_clip: f32 = 20,
    /// The fraction of the way each target head follows its online twin every update.
    target_follow: f32 = 0.01,
    beta1: f32 = 0.9,
    beta2: f32 = 0.999,
    epsilon: f32 = 1e-8,
};

/// THE DEVICE'S NUMBERS FOR THE LOG: statistics the learner's kernels write into a block of the parameter buffer,
/// inside the range the learner reads back every frame - so they reach the host with the weights, at no transfer of
/// their own, a frame or so late on a GPU. One definition for both sides: a kernel is told a field's place (`slot`),
/// and the host reads the copied numbers as this struct. A number whose part the learner does not have stays 0, and
/// each holds the latest update's value.
pub const DeviceStats = extern struct {
    /// The world model: its training loss on the latest update - the mean squared difference between the states it
    /// predicts over the whole window and the recorded ones, per number; the page's `loss` is the same number
    /// (`LatentKit.recordWorldModelLoss`).
    world_model_loss: f32 = 0,
    /// The policy: its tracking term on the latest update - the mean squared difference between the states its
    /// rollout reaches through the world model and the reference's goals, per number.
    policy_tracking_loss: f32 = 0,
    /// The world model's gradient's length on the latest update, before its clipping (`LatentKit.world_optimizer`) -
    /// what its bound is set against. 0 without the bound.
    world_gradient_norm: f32 = 0,
    /// The skip model on its latest update (`SkipModel`): its loss - the mean squared error of its predicted change
    /// over a jump against the recorded one, every jump of every window - and, from the SAME start on the same windows,
    /// its first jump's error beside the world model's error rolled the same steps (`world_model_span_error`): the
    /// pair that says whether one prediction of the whole span beats the steps rolled one by one.
    skip_model_loss: f32 = 0,
    skip_model_jump_error: f32 = 0,
    world_model_span_error: f32 = 0,
    /// The policy's gradient's length on the latest update, BEFORE its clipping (`LatentKit.policy_optimizer`): what
    /// the clipping bounds should be set against, in the units of our loss.
    policy_gradient_norm: f32 = 0,
    /// The policy's rollout against the failure rule: the mean of every rolled state's barrier hinges, unweighted - 0
    /// while the imagined states keep well inside the rule (`stat_barrier`).
    policy_barrier_hinge: f32 = 0,
    /// The critic's tail at the policy's horizon: its heads' values there, their mean and their standard deviation
    /// over the windows and the heads - the cost the policy is told lies beyond its rollout.
    policy_tail_value: f32 = 0,
    policy_tail_deviation: f32 = 0,
    /// The planner on its latest decision (`plan_gain_stats`): the chosen plans' score less the best of the actor's own
    /// proposals (the flow's plans), averaged over the deciding states, and the share of choices the search drew - what
    /// says whether the search finds anything the actor does not already propose.
    planner_gain: f32 = 0,
    planner_search_share: f32 = 0,
    /// The critic on its latest batch (`critic_value_stats`): its heads' mean value, their mean spread - the
    /// disagreement its pessimism adds - and their error against the targets as a root mean square, all in the units
    /// of the cost the critic sums: SuperTrack's near the reference, bounded far from it (`TrackingCost.cap`).
    critic_value_mean: f32 = 0,
    critic_head_spread: f32 = 0,
    critic_value_error: f32 = 0,
    /// Teacher 1: the root mean square of FlowDPG's velocity gradient - how hard the world model's gradient pushes the
    /// flow (`stat_root_mean_square`). Small by construction: each target is a step of a tenth of the flow's own
    /// motion (`FlowSettings.step_share`), and the loss is a mean over every training row and every action, so with a
    /// thousand rows and Geno's 69 actions it reads around 1e-7. Its size alone says little - Adam rescales the flow's
    /// whole gradient - but the teachers' gradients are summed before Adam sees them, so its share beside teacher 2's
    /// and teacher 3's is what decides how much FlowDPG teaches.
    flow_dpg_gradient_rms: f32 = 0,
    /// With the teachers sharing the update (`FlowActor.Teacher.share_teachers`): each teacher's gradient over the
    /// flow's weights, its natural length before it is scaled to its share - teacher 1's (FlowDPG), teacher 2's,
    /// teacher 3's - what the shares even out.
    flow_dpg_weight_gradient: f32 = 0,
    flow_distill_weight_gradient: f32 = 0,
    flow_fpo_weight_gradient: f32 = 0,
    /// Teacher 2: the flow matching loss on the plans' corrections - the mean squared difference between the velocity
    /// the flow gives and the path's, per number (`stat_mean_square_difference`).
    distillation_loss: f32 = 0,
    /// Teacher 3, at its round's start: the old losses' mean and sample deviation - how likely the flow found its own
    /// corrections when it gave them - and the raw advantages' (before normalising): a mean far from 0 says the
    /// critic is off on average, a small deviation that there is little to learn from (`stat_mean_and_deviation`).
    fpo_old_loss_mean: f32 = 0,
    fpo_old_loss_deviation: f32 = 0,
    fpo_advantage_mean: f32 = 0,
    fpo_advantage_deviation: f32 = 0,
    /// Teacher 3, after each update: the likelihood ratios' mean and the share of examples the clip holds - how far
    /// the round's updates have moved the flow from where its examples were taken (`fpo_ratio_stats`).
    fpo_ratio_mean: f32 = 0,
    fpo_clipped_share: f32 = 0,

    /// The block's size, in floats.
    pub const floats: u32 = @sizeOf(DeviceStats) / @sizeOf(f32);

    /// Where `field` sits in the block, in floats from its start.
    pub fn slot(comptime field: []const u8) u32 {
        return @offsetOf(DeviceStats, field) / @sizeOf(f32);
    }
};

/// A statistic into a stats block's `field` (`DeviceStats`): `kernel` run once with `inputs`, writing at the place
/// set here (`stat_off`, where every statistic writes), and nothing when there is no block (`stats_at` null). The
/// kit's and the critic's statistics alike.
fn recordDeviceStat(
    comptime M: type,
    pipe: *compute_host.Compute(M),
    stats_at: ?u32,
    comptime field: []const u8,
    comptime kernel: []const u8,
    inputs: M.Params,
) void {
    const block_at: u32 = stats_at orelse return;
    var stat_params: M.Params = inputs;
    stat_params.stat_off = block_at + DeviceStats.slot(field);
    pipe.params = stat_params;
    pipe.run(kernel, 1);
}

/// SUPERTRACK'S CRITIC - the tracking cost a character can expect from a state onward, discounted:
///
///     C(s_k) = c(s_(k+1)) + gamma x C(s_(k+1))
///
/// with c the per-step cost SuperTrack's policy loss charges (`zn_mlp.lat_tracking_cost`: the distance from the goal,
/// plus the failure barrier). Learned by temporal differences on the REAL transitions of the windows the world model
/// trains on, as an ensemble of EfficientTDMPC's two-hot value heads with target copies. Its input has the policy's
/// layout - a goal, then the state, both normalised - but not the policy's goal: beside state k it reads goal k, the
/// goal that state was meant to match (its own frame's), where the policy reads the goal the next step aims at. It is
/// what SuperTrack's window cannot see: the cost after the window's last step, which the policy's loss can add at the
/// window's end.
///
/// ---- ONE UPDATE'S TARGETS (`computeTargets`) ----
///
///     inputs        each real step k = 1 .. W - 1 of each window: [goal_k | state_k]     (two `place_columns`)
///     next inputs   the step after:                         [goal_(k+1) | state_(k+1)]
///     costs         c(state_(k+1)) against goal_(k+1)                                     (`lat_tracking_cost`)
///     target heads  on the next inputs, decoded                                           (`twohot_decode`)
///     targets       cost + gamma x the target heads' mean                                 (`value_target_combine`)
///
/// Every step's states and goals lie in consecutive blocks after the window's gather - [step][row][feature] - so one
/// placement carries all of a window batch's steps at once. The window's first step is left out: its state sits in
/// the window's first wide row, apart from the others.
///
/// A fall is no terminal: in a fleet that lives on after a loss, a fallen state is a costly one, and its cost-to-go is
/// what the critic learns - nothing in the targets ends at a loss.
///
/// ---- WHY EACH PIECE ----
///
/// TEMPORAL DIFFERENCES. The cost-to-go is an infinite discounted sum no window contains. Its recursion does fit in
/// one transition: what a state is worth is what its next step costs plus the discount times what the next state is
/// worth. Regressing C(s_k) toward c(s_(k+1)) + gamma x C(s_(k+1)), over many transitions, makes the recursion hold
/// everywhere the data goes - and a function that satisfies it is the cost-to-go (the Bellman equation's fixed point,
/// under the policy that collected the data).
///
/// TARGET HEADS. The right side of that regression is itself the critic's prediction. Computed with the very heads
/// being trained, every update would move its own target, and the regression can chase itself; computed with copies
/// that follow the trained heads slowly (Polyak averaging, a small step each update), the target stands nearly still
/// while the heads move toward it.
///
/// AN ENSEMBLE, AVERAGED. Each head is trained the same way from its own initial weights, so where the data is thick
/// they agree, and where it is thin they differ. Their mean is a steadier target than any one of them; their spread
/// says where the critic is unsure.
///
/// TWO-HOT HEADS. A cost-to-go ranges from nearly nothing (tracking well) to a hundred times a step's cost (lying on
/// the floor for the whole horizon). A regression in raw units would be dominated by the largest; a two-hot head
/// predicts a distribution over bins of the symlog axis, so a target of 0.1 and one of 100 are learned with the same
/// care (zimrrl 9.5).
pub fn LatentCritic(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = kit_mlp.KitNetwork(M);
        pub const Pipe = Network.Pipe;
        const Mlp = zn.Mlp(f32);

        /// Where the critic reads a gathered window batch, and the cost's settings (`LatentKit` and its resident data
        /// hold them all).
        pub const Source = struct {
            features: u32,
            rows: u32,
            steps: u32,
            /// The real states after each step, and the goals: [steps][rows][features] each, from step 1.
            states_at: u32,
            goals_at: u32,
            /// The normaliser's means, then its spreads.
            norm_at: u32,
            barrier: FailureBarrier,
            barrier_head_column: u32,
            barrier_up_column: u32,
            /// The cost's cap far from the reference (`TrackingCost.cap`), 0 for none.
            cost_cap: f32 = 0,

            /// The per-step cost these windows are charged by (`TrackingCost`) - the policy's, barrier and all.
            pub fn trackingCost(source: Source) TrackingCost {
                const cost: TrackingCost = .{
                    .features = source.features,
                    .barrier = source.barrier,
                    .barrier_head_column = source.barrier_head_column,
                    .barrier_up_column = source.barrier_up_column,
                    .norm_at = source.norm_at,
                    .cap = source.cost_cap,
                };
                return cost;
            }
        };

        /// The critic's shape, its discount, and how each update steps (`CriticOptions`).
        pub const Options = CriticOptions;

        source: Source,
        options: Options,
        bins: bmpc_kit.TwoHotBins(M),
        /// Real transitions per batch: (steps - 1) x rows.
        transitions: u32,
        heads: []const Network,
        target_heads: []const Network,
        target_passes: []const Network.Application,
        /// Each online head applied to the transitions' inputs - forward and backward - and where its logits'
        /// gradient goes [transitions][bins].
        head_passes: []const Network.Application,
        logits_gradient_offsets: []const u32,
        /// The online heads' parameters, one contiguous range (all of them placed before any target head), which the
        /// clip and Adam step over; and the clip's per-chunk sums of squares and its norm and factor.
        online_params_start: u32,
        online_params_end: u32,
        /// The online heads' optimiser step.
        optimizer: kit_mlp.ClippedAdam,
        /// [transitions][2 features] each.
        inputs_at: u32,
        next_inputs_at: u32,
        /// [transitions]; the decoded target values [heads][transitions]; the targets [transitions].
        costs_at: u32,
        decoded_at: u32,
        targets_at: u32,
        /// Where the learner's stats block starts (`DeviceStats`), or null without one - set by the learner after it
        /// reserves the block; the critic records its numbers there (`critic_value_stats`).
        stats_at: ?u32 = null,
        /// The CPU networks the heads start from, kept to write the parameters (`writeParams`).
        mlps: []Mlp,
        target_mlps: []Mlp,

        /// A critic over `source`'s windows, its heads drawn from `options.seed` and placed in `layout` (which must
        /// start past everything the latent kit and its data already use). Memory: `arena`.
        pub fn init(
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            source: Source,
            options: Options,
        ) !Self {
            assertf(source.steps >= 2, @src(), "a critic needs windows of 2 steps or more, not {d}", .{source.steps});
            // The critic reads the policy's own input: the goal, then the state.
            const input_width: usize = 2 * source.features;
            const default_bins: zn.CategoricalScalar(f32) = .{};
            const bin_count: usize = default_bins.bin_count;
            const hidden_pair: []const usize = try arena.dupe(usize, &.{ options.hidden, options.hidden });
            const mlps: []Mlp = try arena.alloc(Mlp, options.heads);
            const target_mlps: []Mlp = try arena.alloc(Mlp, options.heads);
            const heads: []Network = try arena.alloc(Network, options.heads);
            const target_heads: []Network = try arena.alloc(Network, options.heads);
            const transitions: u32 = (source.steps - 1) * source.rows;
            const target_passes: []Network.Application = try arena.alloc(Network.Application, options.heads);
            const head_passes: []Network.Application = try arena.alloc(Network.Application, options.heads);
            const logits_gradient_offsets: []u32 = try arena.alloc(u32, options.heads);
            const critic_generator: zn.Rng = .init(options.seed);
            // The online heads first, so their parameters are one contiguous range for the clip and Adam.
            const online_params_start: u32 = layout.params_floats;
            for (0..options.heads) |head_index| {
                // Each head from its own stream: different starting weights are what make the ensemble's members
                // disagree where the data is thin.
                const head_rng: zn.Rng = critic_generator.split(@intCast(head_index));
                mlps[head_index] = try Mlp.init(arena, head_rng, .{
                    .input = input_width,
                    .hidden = hidden_pair,
                    .output = bin_count,
                    .zero_last = true,
                });
                heads[head_index] = try Network.init(arena, layout, mlps[head_index]);
            }
            const online_params_end: u32 = layout.params_floats;
            // Then the target heads, each starting as an exact copy of its online twin and following it from there.
            for (0..options.heads) |head_index| {
                const target_starting_params: zn.Params(f32) = try (try mlps[head_index].params(arena)).clone(arena);
                target_mlps[head_index] = try mlps[head_index].withParams(target_starting_params, arena);
                target_heads[head_index] = try Network.init(arena, layout, target_mlps[head_index]);
            }
            // The applications: the target heads forward only; the online heads forward and backward, each with
            // somewhere for its logits' gradient.
            for (0..options.heads) |head_index| {
                const target_head: Network = target_heads[head_index];
                target_passes[head_index] = try target_head.forwardOnlyApplication(arena, layout, transitions);
                head_passes[head_index] = try heads[head_index].application(arena, layout, transitions);
                const logits_gradient_floats: u32 = transitions * @as(u32, @intCast(bin_count));
                logits_gradient_offsets[head_index] = layout.reserveDacts(logits_gradient_floats);
            }
            const online_floats: u32 = online_params_end - online_params_start;
            const input_block_floats: u32 = transitions * 2 * source.features;
            const critic: Self = .{
                .source = source,
                .options = options,
                .bins = .{},
                .transitions = transitions,
                .heads = heads,
                .target_heads = target_heads,
                .target_passes = target_passes,
                .head_passes = head_passes,
                .logits_gradient_offsets = logits_gradient_offsets,
                .online_params_start = online_params_start,
                .online_params_end = online_params_end,
                .optimizer = .reserve(layout, online_params_start, online_floats),
                .inputs_at = layout.reserveActs(input_block_floats),
                .next_inputs_at = layout.reserveActs(input_block_floats),
                .costs_at = layout.reserveActs(transitions),
                .decoded_at = layout.reserveActs(options.heads * transitions),
                .targets_at = layout.reserveActs(transitions),
                .mlps = mlps,
                .target_mlps = target_mlps,
            };
            return critic;
        }

        /// Every head's and target head's numbers into `params`, the layout's parameter block.
        pub fn writeParams(critic: Self, params: []f32) void {
            for (critic.heads, critic.mlps) |head, mlp| {
                head.writeParams(mlp, params);
            }
            for (critic.target_heads, critic.target_mlps) |target_head, target_mlp| {
                target_head.writeParams(target_mlp, params);
            }
        }

        /// The TD targets of the gathered window batch (this type's head): every real transition's inputs, its next
        /// inputs, its cost and its target, in acts.
        pub fn computeTargets(critic: Self, pipe: *Pipe) void {
            const source: Source = critic.source;
            const features: u32 = source.features;
            const input_row_width: u32 = 2 * features;
            // One step's states (or goals) for every window: the distance from one step's block to the next.
            const step_block_floats: u32 = source.rows * features;
            // THE INPUTS. Transition j of the batch is step k = 1 + j / rows of window j % rows: its input row is
            // [goal_k | state_k], its next input row [goal_(k+1) | state_(k+1)]. Because the gathered blocks are
            // [step][window][feature], the states of steps 1 .. W - 1 are ONE contiguous run, as are their goals, and
            // those of steps 2 .. W start exactly one step's block later - so four placements lay out every
            // transition of the batch: goals into the first half of each row, states into the second.
            const next_goals_at: u32 = source.goals_at + step_block_floats;
            const next_states_at: u32 = source.states_at + step_block_floats;
            const placement_sources = [_]u32{ source.goals_at, source.states_at, next_goals_at, next_states_at };
            const inputs_at: u32 = critic.inputs_at;
            const next_inputs_at: u32 = critic.next_inputs_at;
            const placement_destinations = [_]u32{ inputs_at, inputs_at, next_inputs_at, next_inputs_at };
            const placement_first_columns = [_]u32{ 0, features, 0, features };
            for (placement_sources, placement_destinations, placement_first_columns) |from, to, first_column| {
                bmpc_kit.placeColumns(M, pipe, .{
                    .rows = critic.transitions,
                    .count = features,
                    .source_offset = from,
                    .destination_offset = to,
                    .row_stride = input_row_width,
                    .first_column = first_column,
                });
            }
            // THE COSTS. Each transition is charged for where it led - the next state, against the goal there - as the
            // policy's loss charges each rolled step.
            const cost: TrackingCost = source.trackingCost();
            runTrackingCost(M, pipe, cost, critic.transitions, next_states_at, next_goals_at, critic.costs_at);
            // THE TARGET HEADS' VALUES where each transition led, each decoded from its bins to a number:
            // [head][transition], as `value_target_combine` reads them.
            for (critic.target_passes, 0..) |target_pass, head_index| {
                target_pass.forward(pipe, critic.next_inputs_at, input_row_width);
                const head_block_start: u32 = @as(u32, @intCast(head_index)) * critic.transitions;
                const head_values_at: u32 = critic.decoded_at + head_block_start;
                bmpc_kit.decodeTwoHotRows(M, pipe, target_pass, critic.bins, head_values_at);
            }
            // THE TARGETS: cost + gamma x the heads' mean. EfficientTDMPC's own combination, with the cost in the
            // reward's place and a single "dynamics head" - the real transition itself.
            pipe.params = .{
                .rows = critic.transitions,
                .x_off = critic.costs_at,
                .v_off = critic.decoded_at,
                .y_off = critic.targets_at,
                .gamma = critic.options.discount,
                .target_dynamics_heads = 1,
                .target_value_heads = critic.options.heads,
            };
            pipe.run("value_target_combine", critic.transitions);
        }

        /// THE VALUE TAIL: the critic's estimate of the cost after a window's last state, added to SuperTrack's policy
        /// loss - so that the policy's gradient, which sees only the window, also sees what the window's end leads
        /// to. The loss gains
        ///
        ///     weight x (1 / rows) x (1 / heads) x sum over rows and heads of  C_h([goal_W | state_W])
        ///
        /// - the window's own steps already cost sum_k c(state_k), and C(state_W) is what comes after them, so the two
        /// add up to the whole objective. Its gradient in the last state goes, for each head, back through the
        /// decoded value (`twohot_value_bwd`) and the head (its input gradient), and the state half of that input
        /// gradient is ADDED into the last state's gradient (`lat_take`): from there the world model's adjoint carries
        /// it back through the window to the policy, as it carries the tracking terms. The critic's weights are not
        /// trained by the tail - their gradients land in the critic's own gradient region, which its next update
        /// overwrites.
        pub const Tail = struct {
            /// The online heads applied to the policy rollout's last state, `rows` of them - forward and backward.
            passes: []const Network.Application,
            logits_gradient_offsets: []const u32,
            /// [rows][2 features]: each window's [goal | state] at the window's end.
            inputs_at: u32,
            features: u32,
            rows: u32,
            bins: bmpc_kit.TwoHotBins(M),
            /// The tail's weight in the loss, set before each policy update (it ramps up from 0: an untrained
            /// critic's slope is noise). At 0 nothing is computed, and the policy's gradients are the tail-free ones.
            weight: f32 = 0,
            /// PESSIMISM (beta): the tail reads the heads' mean plus beta of their spread, so a state whose cost the
            /// heads dispute counts as costlier, and the policy is pushed away from what the critic is unsure of
            /// (`zn_mlp.ensemble_tail_weights`). At 0 the tail is the plain mean, computed exactly as without it.
            pessimism: f32 = 0,
            /// Each head's decoded value and its weight in the pessimistic mean, [head][row] each.
            head_values_at: u32,
            head_weights_at: u32,

            /// The tail's gradient for a rolled window batch (this type's head), ADDED into the last state's gradient:
            /// the goals at `goals_at` and the rolled states at `states_at` ([rows][features] each), the gradient at
            /// `state_gradient_at` (the same shape). Every head's value is left decoded at `head_values_at` when the
            /// tail is pessimistic - its weights need them - and, with `decode_values`, when it is not: for the log.
            pub fn addGradient(
                tail: Tail,
                pipe: *Pipe,
                goals_at: u32,
                states_at: u32,
                state_gradient_at: u32,
                decode_values: bool,
            ) void {
                if (tail.weight == 0) {
                    return;
                }
                const features: u32 = tail.features;
                const input_row_width: u32 = 2 * features;
                const head_count: u32 = @intCast(tail.passes.len);
                const is_pessimistic: bool = tail.pessimism != 0;
                // Pessimism needs every head's value before any head's slope: each head's weight depends on all of
                // them. `forwardValues` runs every head's forward (leaving its activations for its backward) and
                // decodes it; the weights follow from the values. Without pessimism each head's weight is the mean's
                // share, and the forward runs head by head below.
                if (is_pessimistic) {
                    tail.forwardValues(pipe, goals_at, states_at, tail.head_values_at);
                    pipe.params = .{
                        .rows = tail.rows,
                        .target_value_heads = head_count,
                        .v_off = tail.head_values_at,
                        .y_off = tail.head_weights_at,
                        .plan_pessimism = tail.pessimism,
                    };
                    pipe.run("ensemble_tail_weights", tail.rows);
                } else {
                    tail.placeInputs(pipe, goals_at, states_at);
                }
                // The loss is the mean over the rows; within a row, each head's share: 1/H, or its pessimistic weight.
                const weight_per_row: f32 = tail.weight / float(tail.rows);
                const weight_per_value: f32 = weight_per_row / float(head_count);
                for (tail.passes, tail.logits_gradient_offsets, 0..) |tail_pass, logits_gradient_offset, head_index| {
                    if (!is_pessimistic) {
                        tail_pass.forward(pipe, tail.inputs_at, input_row_width);
                        if (decode_values) {
                            const head_number_now: u32 = @intCast(head_index);
                            const values_block_at: u32 = tail.head_values_at + head_number_now * tail.rows;
                            bmpc_kit.decodeTwoHotRows(M, pipe, tail_pass, tail.bins, values_block_at);
                        }
                    }
                    const head_number: u32 = @intCast(head_index);
                    const head_weights_at: u32 = tail.head_weights_at + head_number * tail.rows;
                    const row_mask: M.RowMask = if (is_pessimistic) .weight_column else .every_row;
                    pipe.params = .{
                        .rows = tail.rows,
                        .out_dim = tail_pass.network.outputWidth(),
                        .x_off = tail_pass.outputsOffset(),
                        .dy_off = logits_gradient_offset,
                        .loss_weight = if (is_pessimistic) weight_per_row else weight_per_value,
                        .row_mask = @backingInt(row_mask),
                        .mask_off = head_weights_at,
                        .twohot_low = tail.bins.low,
                        .twohot_high = tail.bins.high,
                        .twohot_axis = @backingInt(tail.bins.axis),
                    };
                    pipe.run("twohot_value_bwd", tail.rows);
                    tail_pass.backward(
                        pipe,
                        tail.rows,
                        tail.inputs_at,
                        input_row_width,
                        logits_gradient_offset,
                        .overwrite,
                    );
                    // The input gradient's state half - its columns after the goal's - added into the last state's.
                    const input_gradient_at: u32 = tail_pass.layer_regions[0].inputs_gradient;
                    pipe.params = .{
                        .rows = tail.rows,
                        .count = features,
                        .stride = input_row_width,
                        .dy_off = state_gradient_at,
                        .dx_off = input_gradient_at + features,
                    };
                    pipe.run("lat_take", tail.rows * features);
                }
            }

            /// Every head's value at each window's end, decoded, into acts at `values_at` [head][row] - the tail's
            /// value before its weight and its mean, for watching it, or for checking its gradient.
            pub fn forwardValues(
                tail: Tail,
                pipe: *Pipe,
                goals_at: u32,
                states_at: u32,
                values_at: u32,
            ) void {
                const input_row_width: u32 = 2 * tail.features;
                tail.placeInputs(pipe, goals_at, states_at);
                for (tail.passes, 0..) |tail_pass, head_index| {
                    tail_pass.forward(pipe, tail.inputs_at, input_row_width);
                    const head_values_at: u32 = values_at + @as(u32, @intCast(head_index)) * tail.rows;
                    bmpc_kit.decodeTwoHotRows(M, pipe, tail_pass, tail.bins, head_values_at);
                }
            }

            /// [goal | state] for each window's end, the critic's own input layout, into the tail's input rows.
            fn placeInputs(tail: Tail, pipe: *Pipe, goals_at: u32, states_at: u32) void {
                const features: u32 = tail.features;
                const placement_sources = [_]u32{ goals_at, states_at };
                const placement_first_columns = [_]u32{ 0, features };
                for (placement_sources, placement_first_columns) |from, first_column| {
                    bmpc_kit.placeColumns(M, pipe, .{
                        .rows = tail.rows,
                        .count = features,
                        .source_offset = from,
                        .destination_offset = tail.inputs_at,
                        .row_stride = 2 * features,
                        .first_column = first_column,
                    });
                }
            }
        };

        /// The value tail over `rows` windows' last states (`Tail`), its regions reserved in `layout`: the critic's
        /// online heads applied once more, to those rows. Memory: `arena`.
        pub fn initTail(
            critic: Self,
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            rows: u32,
        ) !Tail {
            const passes: []Network.Application = try arena.alloc(Network.Application, critic.heads.len);
            const logits_gradient_offsets: []u32 = try arena.alloc(u32, critic.heads.len);
            for (critic.heads, passes, logits_gradient_offsets) |head, *pass, *logits_gradient_offset| {
                pass.* = try head.application(arena, layout, rows);
                logits_gradient_offset.* = layout.reserveDacts(rows * head.outputWidth());
            }
            const features: u32 = critic.source.features;
            const head_count: u32 = @intCast(critic.heads.len);
            const tail: Tail = .{
                .passes = passes,
                .logits_gradient_offsets = logits_gradient_offsets,
                .inputs_at = layout.reserveActs(rows * 2 * features),
                .features = features,
                .rows = rows,
                .bins = critic.bins,
                .head_values_at = layout.reserveActs(head_count * rows),
                .head_weights_at = layout.reserveActs(head_count * rows),
            };
            return tail;
        }

        /// One update of the critic on the gathered window batch (this type's head), its `update_count`-th (Adam's
        /// step count, from 1):
        ///
        ///     targets   every transition's TD target (`computeTargets`)
        ///     loss      each online head's two-hot cross-entropy against the targets, its mean over the
        ///               transitions; its gradient at the logits (`twohot_bwd`), back through the head
        ///     step      the online heads' gradients clipped to a global norm, then Adam
        ///     follow    each target head a small step toward its online twin (`polyak`)
        ///
        /// Each head learns from its own loss only - their parameters are separate, so the sum of the heads' losses
        /// and each head's own give every parameter the same gradient.
        ///
        /// THE CLIP. Every online head's weight gradients together are one vector; when its length passes
        /// `gradient_clip`, the whole vector is scaled down to that length - its direction kept - so one batch with an
        /// outlying target cannot throw the weights far. Most updates are not clipped at all.
        ///
        /// ADAM'S BIAS CORRECTION. Adam keeps running means of each gradient and of its square, both started at zero,
        /// so early on they are too small: after one update the first is (1 - beta1) g = 0.1 g. Dividing by
        /// 1 - beta1^t (here 1 - 0.9 = 0.1) gives g back; as t grows the divisor tends to 1 and the correction fades.
        ///
        /// THE FOLLOW. Each update moves a target weight `target_follow` of the way to its online twin: at 0.01, the
        /// target is a running average of the online weights over roughly the last 1 / 0.01 = 100 updates - each
        /// older update's weight in it smaller by a factor 0.99 - which is what keeps the regression's targets still
        /// enough to be chased.
        pub fn update(critic: Self, pipe: *Pipe, update_count: u32) void {
            const options: Options = critic.options;
            critic.computeTargets(pipe);
            // THE LOSS'S GRADIENT, head by head, into its own weight gradients.
            const input_row_width: u32 = 2 * critic.source.features;
            const head_passes: []const Network.Application = critic.head_passes;
            const gradient_offsets: []const u32 = critic.logits_gradient_offsets;
            for (head_passes, gradient_offsets, 0..) |head_pass, logits_gradient_offset, head_index| {
                head_pass.forward(pipe, critic.inputs_at, input_row_width);
                // For the log, each head's values decoded - into the targets' scratch, free once they are combined.
                if (critic.stats_at != null) {
                    const head_block_start: u32 = @as(u32, @intCast(head_index)) * critic.transitions;
                    bmpc_kit.decodeTwoHotRows(M, pipe, head_pass, critic.bins, critic.decoded_at + head_block_start);
                }
                const bin_count: u32 = head_pass.network.outputWidth();
                pipe.params = .{
                    .rows = critic.transitions,
                    .out_dim = bin_count,
                    .x_off = head_pass.outputsOffset(),
                    .t_off = critic.targets_at,
                    .dy_off = logits_gradient_offset,
                    .twohot_low = critic.bins.low,
                    .twohot_high = critic.bins.high,
                    .twohot_axis = @backingInt(critic.bins.axis),
                    .twohot_divisor = @floatFromInt(critic.transitions),
                    .loss_weight = 1.0,
                    .row_mask = @backingInt(M.RowMask.every_row),
                };
                pipe.run("twohot_bwd", critic.transitions);
                head_pass.backward(
                    pipe,
                    critic.transitions,
                    critic.inputs_at,
                    input_row_width,
                    logits_gradient_offset,
                    .overwrite,
                );
            }
            // For the log: the heads' mean value, their spread, their error against the targets.
            recordDeviceStat(M, pipe, critic.stats_at, "critic_value_mean", "critic_value_stats", .{
                .rows = critic.transitions,
                .count = options.heads,
                .x_off = critic.decoded_at,
                .t_off = critic.targets_at,
            });
            // THE STEP: the online heads' gradients clipped to a global norm, then Adam (`kit_mlp.ClippedAdam`).
            critic.optimizer.step(M, pipe, .{
                .learning_rate = options.learning_rate,
                .gradient_clip = options.gradient_clip,
                .beta1 = options.beta1,
                .beta2 = options.beta2,
                .epsilon = options.epsilon,
            }, update_count);
            // THE FOLLOW: each target head a `target_follow` share of the way to its online twin.
            for (critic.target_heads, critic.heads) |target_head, online_head| {
                const head_floats: u32 = target_head.paramsEnd() - target_head.paramsStart();
                pipe.params = .{
                    .count = head_floats,
                    .w_off = target_head.paramsStart(),
                    .v_off = online_head.paramsStart(),
                    .tau = options.target_follow,
                };
                pipe.run("polyak", head_floats);
            }
        }
    };
}

/// Which policy acts in SuperTrack's rollout and in its fleet: the Gaussian policy SuperTrack is built with, or a flow
/// policy (`FlowActor`). A tag of fixed width, so a learner's state file can hold it.
pub const PolicyActor = enum(u32) {
    gaussian = 0,
    flow = 1,
};

/// A flow actor's settings, as a learner's options hold them: the velocity network's shape, the sampler's, how the
/// flow learns (`FlowActor.Teacher`: FlowDPG's step share and anchor, the optimiser's rate and clip), and how long
/// each character's noise remembers itself (`zimrrl.ouCorrelation`'s correlation time). An `extern struct`, so a
/// learner's state file can hold it as it holds every option.
pub const FlowSettings = extern struct {
    hidden_width: u32 = 64,
    hidden_layers: u32 = 2,
    /// How many synergies the flow's correction is in (`FlowActor.Correction`): 0 is the full width, the synergies
    /// the actions themselves.
    synergies: u32 = 0,
    /// The flow's Euler steps - its dial between speed and how sharply it keeps a push's different ways back apart.
    /// Its paths to two modes bend, and straight steps cut across the bends: learning two actions 1.2 apart, four
    /// steps left a tenth of the samples between them, eight about one in seventy (`gpu_learn_tests`, two plans
    /// distilled). Five to start; raised if the ways back are seen to blur.
    euler_steps: u32 = 5,
    time_frequencies: u32 = 3,
    step_share: f32 = 0.1,
    anchor: f32 = 1.0,
    learning_rate: f32 = 3e-4,
    gradient_clip: f32 = 20,
    /// The flow's own noise, as a share of sigma. Its noise and SuperTrack's exploration both act while collecting,
    /// and their variances add: at half of sigma, the two together explore 1.25 times as much as SuperTrack alone.
    noise_share: f32 = 0.5,
    /// The correlation time of each character's noise, in seconds: about how long it keeps to one way back.
    noise_correlation_seconds: f32 = 0.5,
    /// The correlation time while the character plans - longer, so it commits to the way back it began.
    flagged_noise_correlation_seconds: f32 = 2.0,
    /// TEACHER 3 (`FlowActor.Fpo`): every step the flow chose for a character in recovery - planning, or with a
    /// hazard of at least `fpo_start_hazard` (the planning hazard: 0 on the reference, 1 at the failure margins) - is
    /// kept as an example in a ring of `fpo_examples`; each round a batch of `fpo_rows` is drawn.
    fpo_rows: u32 = 32,
    fpo_examples: u32 = 512,
    fpo_start_hazard: f32 = 0.5,
    /// Draws of a time and a noise per example, for FPO's likelihood (`KitFlow.drawLosses`). Teacher 3 needs the
    /// critic for its advantages: without `train_critic` it keeps no batch.
    fpo_draws: u32 = 4,
    /// Teacher 3's weight beside the others - small to start: its signal, real returns, is the noisiest - and PPO's
    /// clip.
    fpo_weight: f32 = 0.1,
    fpo_clip: f32 = 0.2,
    /// THE TEACHERS' SHARES of each update (`FlowActor.Teacher.share_teachers`, `kit_mlp.TeacherShares`): each
    /// teacher's gradient scaled to its share before they are summed - FlowDPG's to `dpg_share`, the planner's
    /// distillation's to its weight (`PlanningSettings.distill_weight`), FPO's to `fpo_weight` - rather than summed as
    /// they come, when the teachers' natural sizes differ by orders of magnitude.
    share_teachers: bool = false,
    /// The three bytes after a bool, written as zeros: a learner's state file saves these settings byte for byte.
    padding_after_share_teachers: [3]u8 = @splat(0),
    dpg_share: f32 = 1.0,
    seed: u32 = 1,
};

/// SuperTrack's FLOW ACTOR: a flow policy (`kit_mlp.KitFlow`) that CORRECTS SuperTrack's policy. The policy acts
/// exactly as it would without it; the flow adds a correction drawn from its own noise, and different noises give
/// different corrections - so where the policy has one answer for a situation, the flow can hold several, a step left
/// and a step right, and keep them apart. Its condition is the policy's own [goal | state]. Its regions sit after
/// everything the latent kit uses, in the caller's layout, as the critic's do.
///
/// ---- ONE STEP OF THE ROLLOUT (`LatentKit.policyStep`) ----
///
///     the policy       its layers, from the step's [goal | state] to the raw action
///     the correction   the flow's K Euler steps from its own noise (`LatentKit.flowNoiseSeed`) to k coefficients,
///                      decoded through its synergies and added: raw += B^T c (`LatentKit.flowCorrection`)
///     the action       SuperTrack's exploration added, and the action written (`lat_act`)
///
/// With the flow at rest and its noise at zero the correction is exactly zero, and the rollout is SuperTrack's own, to
/// the bit.
///
/// ---- THE THREE TEACHERS ----
///
/// Each gives the flow's weights a gradient; the first writes them, the others add theirs at their weights, and one
/// clipped Adam step follows on the sum (`LatentKit.policyTrainStep`). Their mistakes differ - that is why there are
/// three:
///
///     teacher      learns from                where                                               holds its data
///     1 FlowDPG    the world model's gradient  the rollout's backward keeps each step's gradient,   `Learning`
///                                              projected onto the synergies
///                                              (`keepFlowCostGradient`); FlowDPG's targets on the
///                                              rollout's own rows (`flowTrainingGradient`)
///     2 planner    the plans' corrections      the steps characters took from their plans, by flow  `Distillation`
///                                              matching (`distillFlow`)
///     3 FPO        what really happened        real steps in danger, scored against the critic;     `Fpo`
///                                              PPO's clipped update (`fpoRoundStart`, `fpoFlow`)
///
/// The first is fast and precise where the model is right; the second can find a whole new way back by searching the
/// model; the third is the one no error of the model can fool.
///
/// ONE APPROXIMATION, in the first teacher, said where it is made: the backward does not pass through the flow, so the
/// gradient a correction is given holds every LATER correction where it was - its effect on the states after it is
/// counted, but not how the flow would have answered those states differently. It is the open-loop gradient that
/// deterministic policy gradients and FlowDPG use, and the rollout's next update sees the answers' change. The policy's
/// own gradient is not approximated: the backward passes through its layers as SuperTrack's always does.
pub fn FlowActor(comptime M: type) type {
    return struct {
        const Self = @This();
        const Flow = kit_mlp.KitFlow(M);

        /// How the flow learns: FlowDPG's step share (alpha), its step floor - by default the typical length of the
        /// flow's noise, sigma sqrt(action width), so a flow that starts at rest takes noise-sized steps - its anchor
        /// (lambda), and its optimiser's settings.
        pub const Teacher = struct {
            /// THE TEACHERS' SHARES (`kit_mlp.TeacherShares`): with `share_teachers`, each teacher's gradient over the
            /// flow's weights is measured alone and scaled to its share before they are summed - FlowDPG's to
            /// `dpg_share`, teacher 2's to its weight (`Distillation.weight`), teacher 3's to its own (`Fpo.weight`) -
            /// so the update's direction is theirs in those proportions, whatever the natural sizes of their losses.
            /// Without it the teachers' gradients are summed as they come.
            share_teachers: bool = false,
            dpg_share: f32 = 1.0,
            step_share: f32 = 0.1,
            step_floor: ?f32 = null,
            anchor: f32 = 1.0,
            learning_rate: f32 = 3e-4,
            gradient_clip: f32 = 20,
            beta1: f32 = 0.9,
            beta2: f32 = 0.999,
            epsilon: f32 = 1e-8,
        };

        /// How the flow learns: from its rollout (TEACHER 1, FlowDPG: the trainer over every (step, row) of it, the
        /// teacher's settings), from the planner's answers when it has them (TEACHER 2, `Distillation`), and the
        /// optimiser's step over the flow's parameters, on the sum of what they give.
        pub const Learning = struct {
            trainer: Flow.Trainer,
            teacher: Teacher,
            distillation: ?Distillation,
            fpo: ?Fpo,
            optimizer: kit_mlp.ClippedAdam,
            /// The teachers' shares of each update, when the teacher asks for them (`Teacher.share_teachers`).
            shares: ?kit_mlp.TeacherShares = null,
        };

        /// TEACHER 3 - FPO ON REAL RETURNS (`zimrrl.fpoLoss`). A batch of steps the flow chose for characters in
        /// recovery, which the learner uploads once per round, packed:
        ///
        ///     [ own goal | goal | state | coefficients | next state ]       one row per example
        ///
        ///     goal, state    the flow's condition at the step: the state, and the goal the step aimed at (the frame
        ///                    the servo was going to) - where FPO measures the coefficients' likelihood
        ///     own goal       the goal of the state's OWN frame - the one the step before aimed at - which the critic
        ///                    reads beside a state: it learns [goal_k | state_k] (`LatentCritic`), a state with the
        ///                    goal it was meant to match, not the policy's next goal
        ///     next state     where the step led
        ///
        /// so the step's advantage, A = -c - gamma C(next) + C(this), has all it needs: the cost is the next state
        /// against the goal the step aimed at, C(next) the critic at [goal | next state], C(this) at [own goal |
        /// state].
        ///
        /// From them FPO raises the flow's likelihood of corrections that turned out better than the critic expected,
        /// and lowers it for those that turned out worse - learning from what happened, which no error of the world
        /// model can fool.
        /// Teacher 3's settings: its batch's rows (0: no teacher 3), the draws per example, its weight beside the other
        /// teachers, and PPO's clip.
        pub const FpoSettings = struct {
            rows: u32 = 0,
            draws: u32 = 4,
            weight: f32 = 0.1,
            clip: f32 = 0.2,
        };

        pub const Fpo = struct {
            examples_at: u32,
            rows: u32,
            features: u32,
            synergy_count: u32,
            /// Its weight beside the other teachers, and PPO's clip (`FpoSettings`).
            weight: f32 = 0,
            clip: f32 = 0.2,
            /// Whether this round's batch holds examples: none until a character in recovery has acted from the flow.
            has_batch: bool = false,
            /// Where each example's advantage is worked out (`Advantage`), once the learner reserves it - it needs
            /// the critic.
            advantage: ?Advantage = null,
            /// Everything one of FPO's updates reads (`Update`), reserved with the flow (`reserveUpdate`).
            update: ?Update = null,
            /// The seed of this round's draws: set where the round's old losses are taken (`LatentKit.fpoRoundStart`),
            /// and the same for every update of the round, so its new losses come from the same draws as the old.
            draw_seed: u32 = 0,

            /// EVERYTHING ONE OF FPO'S UPDATES READS: the draws - a flow trainer over `draws` rows per example,
            /// example b's in rows b x draws .. b x draws + draws - 1, each holding the example's condition and
            /// coefficients with a noise and a time of its own - the conditions and coefficients packed before they
            /// are broadcast to them, and, [rows] each, the old losses (the round's start), the new (each update's),
            /// and the advantages normalised over the batch.
            pub const Update = struct {
                draws: u32,
                trainer: Flow.Trainer,
                conditions_at: u32,
                coefficients_at: u32,
                old_losses_at: u32,
                new_losses_at: u32,
                advantages_at: u32,
            };

            /// Where the advantages are worked out (`LatentKit.fpoAdvantages`): the critic's inputs packed - goals
            /// [own goals; goals] and states [states; next states], [2 x rows][features] each, so one tail over
            /// 2 x rows rows values every example's start and where it led - the steps' costs [rows], the heads'
            /// values [head][2 x rows], the advantages [rows], and the critic's discount and heads.
            pub const Advantage = struct {
                goals_at: u32,
                states_at: u32,
                costs_at: u32,
                values_at: u32,
                advantages_at: u32,
                tail: LatentCritic(M).Tail,
                discount: f32,
                heads: u32,
            };

            /// WHERE EACH PART OF AN EXAMPLE LIES in its row - the one definition the learner writing examples and the
            /// kit reading them both go through:
            ///
            ///     [ own goal | goal | state | coefficients | next state ]
            ///       0          f      2f      3f             3f + k            width 4f + k
            ///
            /// The flow's condition, [goal | state], is the 2f columns from `goal`; a pending example - kept before
            /// the step it waits for - is the `next_state` columns before the next state.
            pub const Columns = struct {
                own_goal: u32,
                goal: u32,
                state: u32,
                coefficients: u32,
                next_state: u32,
                width: u32,

                pub fn of(features: u32, synergy_count: u32) Columns {
                    const columns: Columns = .{
                        .own_goal = 0,
                        .goal = features,
                        .state = 2 * features,
                        .coefficients = 3 * features,
                        .next_state = 3 * features + synergy_count,
                        .width = 4 * features + synergy_count,
                    };
                    return columns;
                }
            };

            /// A batch of `rows` examples of `features`-wide feature rows and `synergy_count` coefficients, its region
            /// reserved in `layout`.
            pub fn init(
                layout: *kit_mlp.KitLayout,
                rows: u32,
                features: u32,
                synergy_count: u32,
            ) Fpo {
                const columns: Columns = .of(features, synergy_count);
                const fpo: Fpo = .{
                    .examples_at = layout.reserveActs(rows * columns.width),
                    .rows = rows,
                    .features = features,
                    .synergy_count = synergy_count,
                };
                return fpo;
            }

            /// Where each part of this batch's examples lies (`Columns`).
            pub fn exampleColumns(fpo: Fpo) Columns {
                return .of(fpo.features, fpo.synergy_count);
            }

            /// Everything one of FPO's updates reads (`Update`) for `flow`, `draws` per example, reserved in `layout`.
            /// Memory: `arena`.
            pub fn reserveUpdate(
                fpo: *Fpo,
                arena: Allocator,
                layout: *kit_mlp.KitLayout,
                flow: Flow,
                draws: u32,
            ) !void {
                // Normalising over the batch takes a sample deviation: two examples at least.
                const has_two: bool = fpo.rows >= 2;
                const message: []const u8 = "teacher 3's batch of {d}: normalising needs two examples or more";
                assertf(has_two, @src(), message, .{fpo.rows});
                fpo.update = .{
                    .draws = draws,
                    .trainer = try flow.initTrainer(arena, layout, fpo.rows * draws),
                    .conditions_at = layout.reserveActs(fpo.rows * 2 * fpo.features),
                    .coefficients_at = layout.reserveActs(fpo.rows * fpo.synergy_count),
                    .old_losses_at = layout.reserveActs(fpo.rows),
                    .new_losses_at = layout.reserveActs(fpo.rows),
                    .advantages_at = layout.reserveActs(fpo.rows),
                };
            }

            /// Where the advantages are worked out (`Advantage`), reserved in `layout`, with `critic`'s tail over twice
            /// the batch's rows. Memory: `arena`.
            pub fn reserveAdvantage(
                fpo: *Fpo,
                arena: Allocator,
                layout: *kit_mlp.KitLayout,
                critic: LatentCritic(M),
            ) !void {
                const critic_rows: u32 = 2 * fpo.rows;
                const heads: u32 = @intCast(critic.heads.len);
                fpo.advantage = .{
                    .goals_at = layout.reserveActs(critic_rows * fpo.features),
                    .states_at = layout.reserveActs(critic_rows * fpo.features),
                    .costs_at = layout.reserveActs(fpo.rows),
                    .values_at = layout.reserveActs(heads * critic_rows),
                    .advantages_at = layout.reserveActs(fpo.rows),
                    .tail = try critic.initTail(arena, layout, critic_rows),
                    .discount = critic.options.discount,
                    .heads = heads,
                };
            }
        };

        /// TEACHER 2 - THE PLANNER, DISTILLED. A batch of the steps characters took from their plans - each step's
        /// condition (the goal and state the character acted in) and the plan's correction - which the learner uploads
        /// once per round; each policy update adds `weight` x the flow matching loss on them
        /// (`KitFlow.flowMatchingGradient`) to FlowDPG's gradient, before the one optimiser step. Flow matching, not
        /// a regression: where the plans for a situation differ - a step left, a step right - the flow learns both,
        /// each from its share of the noise.
        ///
        ///     the learner, once per round     conditions [rows][condition] to `conditions_at`, actions [rows][action]
        ///                                     to the trainer's `actions_at`; `has_batch` set when there are any
        ///     each policy update              conditions copied into the trainer's wide rows, each row's noise and
        ///                                     flow time hashed from the update's seed, the gradient added
        pub const Distillation = struct {
            trainer: Flow.Trainer,
            conditions_at: u32,
            weight: f32,
            /// Whether this round's batch holds examples: none before any character has acted from a plan, and then
            /// the update is FlowDPG's alone.
            has_batch: bool = false,
        };

        /// What the flow's coefficients mean and how they are drawn - shared by every actor over the same flow: where
        /// the synergies are, [synergy][action] in the parameter buffer (written by the learner, never trained), how
        /// many, the full action's width, and the spread of the noise the flow starts from - its own, not the
        /// policy's exploration. At zero, a flow at rest corrects nothing - and learns nothing from FlowDPG either,
        /// whose step floor is this noise's length: a flow with no noise is a deterministic correction.
        pub const Correction = struct {
            synergies_at: u32,
            synergy_count: u32,
            action_width: u32,
            noise_scale: f32,
        };

        /// The flow - from [goal | state] to `synergy_count` coefficients - and what its coefficients mean.
        flow: Flow,
        correction: Correction,
        /// The sampler over the rollout's rows, and each step's coefficients, [step][row][synergy].
        sampler: Flow.Sampler,
        coefficients_at: u32,
        /// How it learns - present for a learner's flow actor, absent for one that only acts over the same flow (the
        /// tracking planner's flow plans: `actingOnly`).
        learning: ?Learning,

        /// A flow actor correcting a policy of `action_width` actions in `synergy_count` synergies, for a rollout of
        /// `steps` steps over `rows` rows: its velocity network `velocity_mlp` (from [goal | state], `condition_width`
        /// numbers, to the coefficients), its noise of `noise_scale`, its regions in `layout` (which must start past
        /// everything the latent kit uses) - the synergies' among the parameters. Memory: `arena`.
        pub fn init(
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            velocity_mlp: zn.Mlp(f32),
            condition_width: u32,
            action_width: u32,
            synergy_count: u32,
            noise_scale: f32,
            rows: u32,
            steps: u32,
            flow_options: Flow.Options,
            teacher: Teacher,
            distillation_rows: u32,
            distillation_weight: f32,
            fpo_settings: FpoSettings,
        ) !Self {
            const flow: Flow = try .init(arena, layout, velocity_mlp, condition_width, synergy_count, flow_options);
            const correction: Correction = .{
                .synergies_at = layout.reserveParams(synergy_count * action_width),
                .synergy_count = synergy_count,
                .action_width = action_width,
                .noise_scale = noise_scale,
            };
            const sampler: Flow.Sampler = try flow.initSampler(arena, layout, rows);
            const coefficients_at: u32 = layout.reserveActs(steps * rows * synergy_count);
            const trainer: Flow.Trainer = try flow.initTrainer(arena, layout, steps * rows);
            // Teacher 2's batch, when the learner plans (0 rows: no distillation).
            var distillation: ?Distillation = null;
            // Teacher 3's batch, when the learner gathers real steps for it (0 rows: no FPO).
            var fpo: ?Fpo = null;
            if (fpo_settings.rows > 0) {
                fpo = Fpo.init(layout, fpo_settings.rows, condition_width / 2, synergy_count);
                fpo.?.weight = fpo_settings.weight;
                fpo.?.clip = fpo_settings.clip;
                try fpo.?.reserveUpdate(arena, layout, flow, fpo_settings.draws);
            }
            if (distillation_rows > 0) {
                distillation = .{
                    .trainer = try flow.initTrainer(arena, layout, distillation_rows),
                    .conditions_at = layout.reserveActs(distillation_rows * condition_width),
                    .weight = distillation_weight,
                };
            }
            const params_start: u32 = flow.network.paramsStart();
            const flow_floats: u32 = flow.network.paramsEnd() - params_start;
            const learning: Learning = .{
                .trainer = trainer,
                .teacher = teacher,
                .distillation = distillation,
                .fpo = fpo,
                .optimizer = .reserve(layout, params_start, flow_floats),
                .shares = if (teacher.share_teachers) .reserve(layout, params_start, flow_floats) else null,
            };
            const actor: Self = .{
                .flow = flow,
                .correction = correction,
                .sampler = sampler,
                .coefficients_at = coefficients_at,
                .learning = learning,
            };
            return actor;
        }

        /// A flow actor that only acts, as `acting_like` does - the same flow, so the SAME weights, and the same
        /// synergies - with a sampler and coefficients of its own over `rows` rows and `steps` steps, its regions
        /// reserved in `layout`. It has no learning part: a rollout with it rolls forward only. Memory: `arena`.
        pub fn actingOnly(
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            acting_like: Self,
            rows: u32,
            steps: u32,
        ) !Self {
            const flow: Flow = acting_like.flow;
            const sampler: Flow.Sampler = try flow.initSampler(arena, layout, rows);
            const coefficients_at: u32 = layout.reserveActs(steps * rows * acting_like.correction.synergy_count);
            const actor: Self = .{
                .flow = flow,
                .correction = acting_like.correction,
                .sampler = sampler,
                .coefficients_at = coefficients_at,
                .learning = null,
            };
            return actor;
        }

        /// The learning part, which a learner's flow actor has; asking it of one that only acts is a mistake, named.
        pub fn learningPart(actor: Self) Learning {
            const learns: bool = actor.learning != null;
            assertf(learns, @src(), "this flow actor only acts (`actingOnly`): it has no trainer to learn with", .{});
            return actor.learning.?;
        }

        /// The flow's optimiser step on the gradients its training left (`update_count`-th, from 1): the global norm
        /// of every weight's gradient clipped to the teacher's limit, then Adam - the critic's step, on the flow.
        pub fn optimizerStep(actor: Self, pipe: *Flow.Pipe, update_count: u32) void {
            const learning: Learning = actor.learningPart();
            const teacher: Teacher = learning.teacher;
            learning.optimizer.step(M, pipe, .{
                .learning_rate = teacher.learning_rate,
                .gradient_clip = teacher.gradient_clip,
                .beta1 = teacher.beta1,
                .beta2 = teacher.beta2,
                .epsilon = teacher.epsilon,
            }, update_count);
        }
    };
}

/// CORRECTIONS GIVEN, NOT SAMPLED: coefficients for every step and row of a rollout, [step][row][synergy] at acts
/// `coefficients_at`, each step's decoded through the synergies at params `synergies_at` (`synergy_count` of them) and
/// added to the policy's raw action, as a flow's correction is (`FlowActor`). A rollout with them is the policy acting
/// closed-loop - its reaction to every state the model reaches - plus a correction chosen in advance: how the tracking
/// planner rolls its candidates. All-zero coefficients are the policy alone.
pub const GivenCorrections = struct {
    coefficients_at: u32,
    synergies_at: u32,
    synergy_count: u32,
};

/// THE SKIP MODEL - a HEAD of the world model that predicts a whole SPAN of steps at once. The world model's second
/// hidden layer h2 is its own encoding of a step's state, reference and action; the head reads that encoding at the
/// span's first step, with the references and actions of the span's remaining steps, and predicts the change of the
/// state over all of them:
///
///     world model    [ z_k | reference_k | action_k ] -> h1 -> h2 -> z_k+1 - z_k
///     skip head      [ h2_k | reference_k+1 | action_k+1 | ... | reference_k+s-1 | action_k+s-1 ]
///                    -> h -> z_k+s - z_k
///
/// The start state and its first step are encoded once, by the layers the one-step model trains - in training the
/// rollout has already computed them - and the head's first layer reads hidden + (s - 1) x (reference + action)
/// numbers rather than a whole state and s steps. Its gradient STOPS at h2: the one-step model, whose accuracy the
/// policy's gradient depends on, never learns from the head.
///
/// It learns from the world model's own windows: a window of W steps holds W / s jumps (`lat_skip_gather`,
/// `lat_skip_targets`). The first starts from the window's RECORDED state; a later one from the state the rollout
/// PREDICTED there - and its target is the change from that prediction to the recorded state after its last step, so
/// it learns to land on what happened from where the world model had drifted to, as a planner's far half needs (its
/// jumps start from predicted states too). The target is the physics, which does not change as the policy learns, and
/// one prediction of a span escapes the compounding of s one-step predictions each read by the next. Whether that
/// makes it the more accurate is measured on every update: its first jump's error beside the world model's rolled the
/// same steps, both from the same recorded start.
pub fn SkipModel(comptime M: type) type {
    return struct {
        const Self = @This();
        const Network = kit_mlp.KitNetwork(M);

        network: Network,
        /// The network over every jump of every window: [jump][row] rows.
        application: Network.Application,
        optimizer: kit_mlp.ClippedAdam,
        optimizer_settings: kit_mlp.ClippedAdam.Settings,
        /// The steps one prediction covers, and the jumps a window of the world model holds.
        span: u32,
        jumps: u32,
        rows: u32,
        features: u32,
        /// The world model's hidden width: the encoding the head reads.
        hidden: u32,
        input_width: u32,
        /// acts: the jumps' input rows [jump][row][input] and their recorded changes [jump][row][feature]; dacts: the
        /// loss's gradient at the network's output, [jump][row][feature].
        inputs_at: u32,
        targets_at: u32,
        outputs_gradient_at: u32,

        /// The world model's numbers a skip head is built against (`LatentKit`): the state's features, a step's
        /// columns after them (its reference and action), its hidden layers' width (the encoding the head reads), the
        /// rows of a window batch, and the steps of the world model's window.
        pub const Shape = struct {
            features: u32,
            step_columns: u32,
            hidden: u32,
            rows: u32,
            window_steps: u32,
        };

        /// Where one update reads the world model's rollout over its windows, in acts (`LatentKit.blockX`, `blockT`,
        /// `blockZ`): block 0's state columns and its reference columns (each block's action after its reference),
        /// the blocks' rows `block_row_stride` apart, a block `rows` x stride after the one before; the world model's
        /// second hidden layer at every step, [step][row][hidden]; the recorded states after steps 1 .. window,
        /// [step][row][feature]; and, for the gate's comparison, the world model's own state rolled `span` steps from
        /// the recorded start, and the recorded state there.
        pub const Windows = struct {
            states_at: u32,
            references_at: u32,
            block_row_stride: u32,
            hidden_at: u32,
            recorded_states_at: u32,
            world_prediction_at: u32,
            recorded_at_span: u32,
        };

        /// A skip head of `span` steps on a world model of `shape`, its regions reserved in `layout`: one hidden layer
        /// as wide as the world model's, an application over every jump of a window, its optimiser with
        /// `gradient_clip` (0: never clipped). The span must be at least 2 - one step is the world model's own - and
        /// fit the world model's window. Memory: the network's and the application's region lists in `arena`.
        pub fn init(
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            shape: Shape,
            span: u32,
            gradient_clip: f32,
        ) !Self {
            const fits_window: bool = span >= 2 and span <= shape.window_steps;
            assertf(fits_window, @src(), "a skip of {d} steps does not fit the world model's window of {d}", .{
                span,
                shape.window_steps,
            });
            const jumps: u32 = shape.window_steps / span;
            const input_width: u32 = shape.hidden + (span - 1) * shape.step_columns;
            const hidden_widths = [_]u32{shape.hidden};
            const network: Network = try .initDense(arena, layout, input_width, &hidden_widths, shape.features, .tanh);
            const row_count: u32 = jumps * shape.rows;
            const application: Network.Application = try network.application(arena, layout, row_count);
            const params_start: u32 = network.paramsStart();
            const params_count: u32 = network.paramsEnd() - params_start;
            // Without a bound, a ceiling no length reaches: a clip of 0 would scale every update to nothing.
            const never_clipped: f32 = 1.0e30;
            const clip: f32 = if (gradient_clip > 0) gradient_clip else never_clipped;
            const skip_model: Self = .{
                .network = network,
                .application = application,
                .optimizer = .reserve(layout, params_start, params_count),
                .optimizer_settings = .{ .gradient_clip = clip },
                .span = span,
                .jumps = jumps,
                .rows = shape.rows,
                .features = shape.features,
                .hidden = shape.hidden,
                .input_width = input_width,
                .inputs_at = layout.reserveActs(row_count * input_width),
                .targets_at = layout.reserveActs(row_count * shape.features),
                .outputs_gradient_at = layout.reserveDacts(row_count * shape.features),
            };
            return skip_model;
        }

        /// Its starting weights into `params`, as the world model's (`Resident.seedWeights`): Xavier's 1/sqrt(fan-in)
        /// for the tanh layers, a hundredth of it for the output - so it begins predicting "nothing changes" - and
        /// every bias zero.
        pub fn writeStartingParams(skip_model: Self, random: Random, params: []f32) void {
            const layers: []const kit_mlp.KitLayer = skip_model.network.layers;
            for (layers, 0..) |layer, layer_index| {
                const is_output: bool = layer_index + 1 == layers.len;
                const weight_floats: u32 = layer.input_width * layer.output_width;
                const output_scale: f32 = if (is_output) 0.01 else 1.0;
                const deviation: f32 = @sqrt(1.0 / float(layer.input_width)) * output_scale;
                for (params[layer.weights_offset..][0..weight_floats]) |*weight| {
                    weight.* = deviation * random.floatNorm(f32);
                }
                @memset(params[layer.weights_offset + weight_floats ..][0..layer.output_width], 0);
            }
        }

        /// One update on the world model's `windows` (`LatentKit.trainStep`, after its recorded rollout): every jump's
        /// inputs and recorded change gathered from the windows, the network forward, its loss and the gate's pair
        /// recorded into the stats block at `stats_at` (if any), the loss's gradient back through it, and its
        /// optimiser's step at the world model's `rate` (`update_count`-th, from 1).
        pub fn train(
            skip_model: Self,
            pipe: *compute_host.Compute(M),
            stats_at: ?u32,
            windows: Windows,
            rate: f32,
            update_count: u32,
        ) void {
            const row_count: u32 = skip_model.jumps * skip_model.rows;
            pipe.params = .{
                .count = skip_model.jumps,
                .rows = skip_model.rows,
                .col = skip_model.span,
                .in_dim = skip_model.hidden,
                .out_dim = skip_model.input_width,
                .stride = windows.block_row_stride,
                .x_off = windows.references_at,
                .t_off = windows.hidden_at,
                .y_off = skip_model.inputs_at,
            };
            pipe.run("lat_skip_gather", row_count * skip_model.input_width);
            pipe.params = .{
                .count = skip_model.jumps,
                .rows = skip_model.rows,
                .col = skip_model.span,
                .in_dim = skip_model.features,
                .stride = windows.block_row_stride,
                .x_off = windows.states_at,
                .t_off = windows.recorded_states_at,
                .y_off = skip_model.targets_at,
            };
            pipe.run("lat_skip_targets", row_count * skip_model.features);
            skip_model.application.forward(pipe, skip_model.inputs_at, 0);
            const outputs_at: u32 = skip_model.application.outputsOffset();
            // For the log: the loss over every jump, and the gate's pair from the window's recorded start - the first
            // jump against the world model rolled the same steps.
            const jump_floats: u32 = skip_model.rows * skip_model.features;
            recordDeviceStat(M, pipe, stats_at, "skip_model_loss", "stat_mean_square_difference", .{
                .rows = row_count * skip_model.features,
                .x_off = outputs_at,
                .t_off = skip_model.targets_at,
            });
            recordDeviceStat(M, pipe, stats_at, "skip_model_jump_error", "stat_mean_square_difference", .{
                .rows = jump_floats,
                .x_off = outputs_at,
                .t_off = skip_model.targets_at,
            });
            recordDeviceStat(M, pipe, stats_at, "world_model_span_error", "stat_mean_square_difference", .{
                .rows = jump_floats,
                .x_off = windows.world_prediction_at,
                .t_off = windows.recorded_at_span,
            });
            pipe.params = .{
                .rows = row_count,
                .out_dim = skip_model.features,
                .y_off = outputs_at,
                .t_off = skip_model.targets_at,
                .dy_off = skip_model.outputs_gradient_at,
                .loss_weight = 1,
            };
            pipe.run("mse_bwd", row_count * skip_model.features);
            // Back through the head alone: its input gradient - toward h2 - goes nowhere, so the world model never
            // learns from it.
            const gradient_at: u32 = skip_model.outputs_gradient_at;
            skip_model.application.backward(pipe, row_count, skip_model.inputs_at, 0, gradient_at, .overwrite);
            var settings: kit_mlp.ClippedAdam.Settings = skip_model.optimizer_settings;
            settings.learning_rate = rate;
            skip_model.optimizer.step(M, pipe, settings, update_count);
        }
    };
}

pub fn LatentKit(comptime M: type) type {
    return struct {
        const Self = @This();

        pipe: *compute_host.Compute(M),
        features: u32,
        references: u32,
        actions: u32,
        hidden: u32,
        rows: u32,
        steps: u32,
        /// THE WORLD MODEL'S WINDOW: the steps its own passes run - its rollout on the recorded actions, its backward,
        /// its loss - at most `steps`, which is the POLICY's horizon. The two need not agree: the world model is fit
        /// on short windows (8 steps, rolled forward on what the simulator did, so it learns to correct its own
        /// errors), while the policy imagines further (32) with a critic past its end. One kit, sized for the longer,
        /// serves both: the world model's update costs what an 8-step kit's does, the gathered windows are the
        /// policy's length, and the world model learns from their first `world_steps`. `steps` by default.
        world_steps: u32,
        /// Columns in front of the state in every wide row - the policy's goal, when the policy
        /// trains through this rollout (0 when only the world model trains). The rows then read
        /// `[goal | z | reference | action]`: the policy's input is the first `lead + features`
        /// columns, the world model's the rest - both contiguous slices of the same row.
        lead: u32,
        /// The world model's input width: features + references + actions.
        inputs: u32,
        /// Floats per wide row - its STRIDE: `lead + inputs`. Not the same as `inputs` once there is a
        /// lead, and the two must never be mixed up: the layers read their slice of a row with this
        /// stride, but the input-gradient block they write back (`dx_at`) is `inputs` wide.
        width: u32,
        // Where things live in the kit's activation buffer, in floats.
        /// `steps + 1` wide blocks.
        x_at: u32,
        /// Per step: the two hidden layers and the predicted change.
        h1_at: u32,
        h2_at: u32,
        change_at: u32,
        /// `steps` contiguous states, Z_1 .. Z_steps.
        z_at: u32,
        /// `steps` targets, T_1 .. T_steps: where the simulator actually went.
        t_at: u32,
        /// `steps` goals, G_1 .. G_steps, when there is a lead: where the reference is - the policy's
        /// tracking target. Empty without a lead.
        g_at: u32,
        // In the gradient buffer: every state's gradient dZ_1 .. dZ_steps, then one slot each for
        // the two hidden layers' and the wide block's gradients, reused step after step.
        dz_at: u32,
        dh1_at: u32,
        dh2_at: u32,
        dx_at: u32,
        /// dacts: a step's change's gradient in the network's own units - the next state's gradient times each
        /// feature's spread - when the change is predicted in units of the typical change (`changeGradient`).
        dchange_at: u32,
        /// acts: THE CHANGE IN UNITS OF THE TYPICAL CHANGE, when the learner asks for it - each feature's mean and
        /// spread of its change in one step, `features` of each (`robot_latent.measureClipIncrements`). The network
        /// predicts the change in those units (`lat_advance`: mean + spread x output), so a feature that moves little
        /// in a step is predicted as finely as one that moves much. Null: the network's output is the change itself.
        increments_at: ?u32 = null,
        /// acts: each feature's weight in the world model's loss, `features` of them - 1 / its change's spread
        /// squared, so each feature's error counts in units of how much that feature changes in a step. Null: every
        /// feature weighs 1.
        loss_weights_at: ?u32 = null,
        /// Floats of gradient buffer the backward pass uses.
        dtotal: u32,
        /// THE POLICY, when one acts in the rollout (`policy_hidden` > 0; it needs the goal lead). Its
        /// weights follow the world model's in the parameter buffer (from `p_at`, `policy_count`
        /// floats); its layers' blocks follow the rollout's (`ph1_at`, `ph2_at`, `raw_at`, a block per
        /// step each). Its actions are written into the rows scaled by `action_scale`.
        policy_hidden: u32,
        p_at: u32,
        policy_count: u32,
        ph1_at: u32,
        ph2_at: u32,
        raw_at: u32,
        action_scale: f32 = 1.0,
        /// The price on the size of the raw action, beside the tracking loss (the CPU learner's).
        w_action: f32 = 0.0,
        /// The smoothness price (CAPS): `w_smooth * |a_k - a_(k-1)|^2` along the window - see `lat_act_bwd`.
        w_smooth: f32 = 0.0,
        /// The failure barrier (`FailureBarrier`), and what it reads: the feature columns of the head's height and of
        /// the up direction's first number (`robot_track.local`'s layout), and where the normaliser's means and
        /// spreads are in acts (the resident data's) - null until the learner places it, so that a barrier switched
        /// on without a normaliser fails by name (`normaliserOffset`) instead of reading the buffer's start as one.
        /// Off - weight 0 - unless the learner sets it.
        barrier: FailureBarrier = .{},
        /// The per-step cost's cap far from the reference (`TrackingCost.cap`, `zn_mlp.boundedCost`) - the critic's,
        /// the planner's and FPO's cost; the policy's pathwise loss keeps SuperTrack's. 0 for none.
        cost_cap: f32 = 0,
        barrier_head_column: u32 = 0,
        barrier_up_column: u32 = 0,
        norm_at: ?u32 = null,
        /// The critic's value tail at the window's end (`LatentCritic.Tail`), when the learner has one.
        value_tail: ?LatentCritic(M).Tail = null,
        /// Where the learner's stats block starts in the parameter buffer (`DeviceStats`), or null without one.
        stats_at: ?u32 = null,
        /// The POLICY's optimiser, when its gradient is clipped (`kit_mlp.ClippedAdam`): its global length bounded,
        /// then each number - back-propagation through a long rollout can produce a rare huge gradient, and one such
        /// step can undo many. Without one, the policy steps with the kit's own Adam (`adamPolicy`). Its
        /// `learning_rate` and `epsilon` are set at each step (`policyTrainStep`).
        policy_optimizer: ?kit_mlp.ClippedAdam = null,
        policy_optimizer_settings: kit_mlp.ClippedAdam.Settings = .{},
        /// THE WORLD MODEL'S OPTIMISER, clipped (`kit_mlp.ClippedAdam`), when the learner bounds its gradient: a fall's
        /// contacts are the hardest steps to predict, and a window through one can give a gradient hundreds of times
        /// a tracking window's - one such update can undo what the model learned of tracking. Its gradient's length is
        /// kept for the log either way the clip goes. Null: the kit's own Adam (`adamStep`).
        world_optimizer: ?kit_mlp.ClippedAdam = null,
        world_optimizer_settings: kit_mlp.ClippedAdam.Settings = .{},
        /// THE SKIP MODEL (`SkipModel`), when the learner has one: trained beside the world model, on the same windows,
        /// to predict a whole span of steps at once.
        skip_model: ?SkipModel(M) = null,
        /// A flow correcting the policy in the rollout (`FlowActor`), when the learner has one.
        flow_actor: ?FlowActor(M) = null,
        /// Corrections GIVEN rather than sampled (`GivenCorrections`) - the tracking planner's candidates, each a
        /// sequence of corrections around the policy. A kit takes its corrections from a flow or from these, not both.
        given_corrections: ?GivenCorrections = null,
        // The policy's gradient slots, one each, reused step after step: the raw action, its two
        // hidden layers, and its input [goal | state] (`lead + features` wide).
        draw_at: u32,
        dph1_at: u32,
        dph2_at: u32,
        dp_at: u32,
        /// Exploration noise on the policy's actions, in units of its raw output (0: none), and the
        /// seed this rollout's noise comes from - one per training step, mixed per step by the kit.
        sigma: f32 = 0.0,
        seed: u32 = 0,
        /// Floats of activation buffer the rollout uses.
        total: u32,
        // Where each layer's weights (then its bias) live in the parameter buffer.
        w1: u32,
        w2: u32,
        w3: u32,
        param_count: u32,

        /// Lay the rollout out in the kit's buffers - or refuse, by name, if it does not fit. Each
        /// kit buffer has its own size (the activation buffer is the large one), and on a GPU a
        /// layout past a buffer's end is not an error anywhere: the dispatches write past it
        /// SILENTLY. So every region is checked against the buffer it lives in.
        /// The kit's offsets, by the buffer each indexes - so that a kit can be placed after another in the same
        /// buffers (`placedAt`): ACTIVATION offsets (the regions it writes as it runs; `total` is their end),
        /// GRADIENT offsets (`dtotal` their end), and SHARED ones - the world model's and the policy's weights, the
        /// resident data's normaliser, and the stats block - which a second kit of the same shape finds where the
        /// first one does.
        const activation_offset_fields = [_][]const u8{
            "x_at", "h1_at", "h2_at", "change_at", "z_at", "t_at", "g_at", "ph1_at", "ph2_at", "raw_at", "total",
        };
        const gradient_offset_fields = [_][]const u8{
            "dz_at", "dh1_at", "dh2_at", "dx_at", "draw_at", "dph1_at", "dph2_at", "dp_at", "dchange_at", "dtotal",
        };
        const shared_offset_fields = [_][]const u8{
            "w1",
            "w2",
            "w3",
            "p_at",
            "norm_at",
            "stats_at",
            "increments_at",
            "loss_weights_at",
        };

        comptime {
            // Every offset field is in exactly one of the three lists: a field added later cannot be left out of
            // `placedAt` without this failing to compile.
            @setEvalBranchQuota(20_000);
            const all_listed: []const []const u8 = &(activation_offset_fields ++ gradient_offset_fields ++
                shared_offset_fields);
            for (@typeInfo(@This()).@"struct".field_names) |field_name| {
                const is_offset: bool = endsWith(u8, field_name, "_at");
                if (!is_offset) {
                    continue;
                }
                var listed: bool = false;
                for (all_listed) |listed_name| {
                    listed = listed or eql(u8, listed_name, field_name);
                }
                if (!listed) {
                    @compileError("LatentKit." ++ field_name ++ ": an offset `placedAt` does not know - list it");
                }
            }
        }

        /// This kit placed after `activations_base` floats of activations and `gradients_base` of gradients - every
        /// activation and gradient offset moved by them, every shared one (the weights, the normaliser) left where it
        /// is. A second kit of the same world model's shape, placed so, rolls ITS OWN rows through the SAME weights:
        /// how the tracking planner scores its candidates (`TrackingScorer`) beside the kit that trains.
        pub fn placedAt(kit: Self, activations_base: u32, gradients_base: u32) Self {
            var placed: Self = kit;
            inline for (activation_offset_fields) |field_name| {
                @field(placed, field_name) += activations_base;
            }
            inline for (gradient_offset_fields) |field_name| {
                @field(placed, field_name) += gradients_base;
            }
            return placed;
        }

        pub fn init(
            pipe: *compute_host.Compute(M),
            features: u32,
            references: u32,
            actions: u32,
            hidden: u32,
            rows: u32,
            steps: u32,
            lead: u32,
            policy_hidden: u32,
        ) error{ KitActivationsTooSmall, KitGradientsTooSmall, KitParametersTooSmall, PolicyWithoutGoals }!Self {
            // A policy acts on [goal | state], so it needs the goal columns in front.
            if (policy_hidden > 0 and lead != features) {
                return error.PolicyWithoutGoals;
            }
            const inputs: u32 = features + references + actions;
            const width: u32 = lead + inputs;
            const x_at: u32 = 0;
            const h1_at: u32 = x_at + (steps + 1) * rows * width;
            const h2_at: u32 = h1_at + steps * rows * hidden;
            const change_at: u32 = h2_at + steps * rows * hidden;
            const z_at: u32 = change_at + steps * rows * features;
            const t_at: u32 = z_at + steps * rows * features;
            const dh1_at: u32 = steps * rows * features;
            const dh2_at: u32 = dh1_at + rows * hidden;
            const dx_at: u32 = dh2_at + rows * hidden;
            // (The input-gradient block is `inputs` wide - see `width`.)
            // The policy's blocks come after the targets and the goals.
            const policy_blocks: u32 = t_at + steps * rows * features + (if (lead > 0) steps * rows * features else 0);
            // The packed actions of every step, [step][row][action] (`raw_at`), and their gradient (`draw_at`), belong
            // to ANY actor - a Gaussian policy's raw output, or a flow's action - so they are counted whether or not
            // this kit has a Gaussian policy; only that policy's own hidden layers and input gradient are counted with
            // it. (A kit counted without them, then given a flow, would write its actions past its own end.)
            const policy_hidden_floats: u32 = 2 * steps * rows * policy_hidden;
            const step_actions_floats: u32 = steps * rows * actions;
            const activations_end: u32 = policy_blocks + policy_hidden_floats + step_actions_floats;
            const has_gaussian_policy: bool = policy_hidden > 0;
            const policy_gradient_width: u32 = 2 * policy_hidden + lead + features;
            const policy_gradient_floats: u32 = if (has_gaussian_policy) rows * policy_gradient_width else 0;
            // A step's change's gradient in the network's own units (`changeGradient`), after everything else.
            const dchange_at: u32 = dx_at + rows * inputs + rows * actions + policy_gradient_floats;
            const gradients_end: u32 = dchange_at + rows * features;
            const w1: u32 = 0;
            const w2: u32 = w1 + inputs * hidden + hidden;
            const w3: u32 = w2 + hidden * hidden + hidden;
            const layout: Self = .{
                .pipe = pipe,
                .features = features,
                .references = references,
                .actions = actions,
                .hidden = hidden,
                .rows = rows,
                .steps = steps,
                .world_steps = steps,
                .lead = lead,
                .inputs = inputs,
                .width = width,
                .x_at = x_at,
                .h1_at = h1_at,
                .h2_at = h2_at,
                .change_at = change_at,
                .z_at = z_at,
                .t_at = t_at,
                .g_at = t_at + steps * rows * features,
                .policy_hidden = policy_hidden,
                .p_at = w3 + hidden * features + features,
                .policy_count = if (policy_hidden == 0)
                    0
                else
                    (lead + features) * policy_hidden + policy_hidden + policy_hidden * policy_hidden +
                        policy_hidden + policy_hidden * actions + actions,
                .ph1_at = policy_blocks,
                .ph2_at = policy_blocks + steps * rows * policy_hidden,
                .raw_at = policy_blocks + 2 * steps * rows * policy_hidden,
                .total = activations_end,
                .dz_at = 0,
                .dh1_at = dh1_at,
                .dh2_at = dh2_at,
                .dx_at = dx_at,
                .draw_at = dx_at + rows * inputs,
                .dph1_at = dx_at + rows * inputs + rows * actions,
                .dph2_at = dx_at + rows * inputs + rows * actions + rows * policy_hidden,
                .dp_at = dx_at + rows * inputs + rows * actions + 2 * rows * policy_hidden,
                .dchange_at = dchange_at,
                .dtotal = gradients_end,
                .w1 = w1,
                .w2 = w2,
                .w3 = w3,
                .param_count = w3 + hidden * features + features,
            };
            // Each buffer refused by its own name: a run that does not fit says which buffer to enlarge.
            if (layout.total > floatsIn(M, "acts")) {
                return error.KitActivationsTooSmall;
            }
            if (layout.dtotal > floatsIn(M, "dacts")) {
                return error.KitGradientsTooSmall;
            }
            if (layout.param_count + layout.policy_count > floatsIn(M, "params")) {
                return error.KitParametersTooSmall;
            }
            return layout;
        }

        /// Where step k's wide block starts (k = 0 .. steps).
        pub fn blockX(self: Self, k: u32) u32 {
            return self.x_at + k * self.rows * self.width;
        }

        /// Where the contiguous state after step k starts (k = 1 .. steps).
        pub fn blockZ(self: Self, k: u32) u32 {
            return self.z_at + (k - 1) * self.rows * self.features;
        }

        /// Where step k's target starts (k = 1 .. steps), and its state's gradient.
        pub fn blockT(self: Self, k: u32) u32 {
            return self.t_at + (k - 1) * self.rows * self.features;
        }

        /// Where step k's goal starts (k = 1 .. steps), when there is a lead.
        pub fn blockG(self: Self, k: u32) u32 {
            return self.g_at + (k - 1) * self.rows * self.features;
        }

        fn blockDZ(self: Self, k: u32) u32 {
            return self.dz_at + (k - 1) * self.rows * self.features;
        }

        /// The rollout, backward: the gradient of the rollout's loss with respect to every weight,
        /// into the kit's gradient buffer (in `packWeights`' layout). `forward` must have run, and
        /// the targets be staged at `blockT`.
        ///
        /// THE LOSS IS THE SUM over steps of each step's mean squared error - `steps` times the CPU
        /// model's, which averages over steps. The kit has no kernel to divide by a constant, and
        /// needs none: Adam divides every gradient by its own running size, so a constant factor
        /// cancels (bar the epsilon). Stated here so nobody mistakes the factor for a bug.
        ///
        /// Walking back from the last step: a step's change has exactly the next state's gradient
        /// (z' = z + change), so layer 3 reads dZ_{k+1} directly. Through the three layers, weight
        /// gradients ACCUMULATED across steps; then a state's own gradient is its loss term, plus
        /// the next state's (the residual path, `add_block`), plus what came back through the
        /// network into its block's z columns (`lat_take`).
        pub fn backward(self: Self) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            // The world model's own window (`world_steps`): its loss, and so its gradient, ends there.
            var step: u32 = self.world_steps;
            self.mse(step);
            self.weighLoss(step);
            var first: bool = true;
            while (step > 0) {
                step -= 1;
                const k: u32 = step;
                const h1: u32 = self.h1_at + k * self.rows * self.hidden;
                const h2: u32 = self.h2_at + k * self.rows * self.hidden;
                const accumulate: u32 = if (first) 0 else 1;
                first = false;
                // Layer 3: into the change, whose gradient is the next state's - in the network's own units.
                const change_gradient: u32 = self.changeGradient(k + 1);
                self.weightGrads(h2, 0, self.hidden, self.features, change_gradient, self.w3, accumulate);
                self.inputGrads(self.hidden, self.features, change_gradient, self.w3, self.dh2_at);
                self.activationGrads(h2, self.dh2_at, tanh, self.hidden);
                // Layer 2.
                self.weightGrads(h1, 0, self.hidden, self.hidden, self.dh2_at, self.w2, accumulate);
                self.inputGrads(self.hidden, self.hidden, self.dh2_at, self.w2, self.dh1_at);
                self.activationGrads(h1, self.dh1_at, tanh, self.hidden);
                // Layer 1, over the wide block.
                self.weightGrads(
                    self.blockX(k) + self.lead,
                    self.width,
                    self.inputs,
                    self.hidden,
                    self.dh1_at,
                    self.w1,
                    accumulate,
                );
                if (k == 0) {
                    break;
                }
                self.inputGrads(self.inputs, self.hidden, self.dh1_at, self.w1, self.dx_at);
                // State k's gradient: its own loss term, the residual path, and the network path.
                self.mse(k);
                self.weighLoss(k);
                self.pipe.params = .{
                    .count = self.rows * self.features,
                    .dy_off = self.blockDZ(k),
                    .dx_off = self.blockDZ(k + 1),
                };
                self.pipe.run("add_block", self.rows * self.features);
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = self.features,
                    // The input-gradient block's rows are `inputs` apart, not `width`.
                    .stride = self.inputs,
                    .dy_off = self.blockDZ(k),
                    .dx_off = self.dx_at,
                };
                self.pipe.run("lat_take", self.rows * self.features);
            }
        }

        /// The gradient of the change that led to state `k` (k = 1 .. steps), in the network's own units: the state's
        /// gradient itself - z_k = z_(k-1) + change - or, with the change predicted in units of the typical change
        /// (`increments_at`), times each feature's spread, since change = mean + spread x output.
        fn changeGradient(self: Self, k: u32) u32 {
            const increments_at: u32 = self.increments_at orelse return self.blockDZ(k);
            self.pipe.params = .{
                .rows = self.rows,
                .count = self.features,
                .x_off = self.blockDZ(k),
                .y_off = self.dchange_at,
                .u_off = increments_at + self.features,
            };
            self.pipe.run("lat_scale_columns", self.rows * self.features);
            return self.dchange_at;
        }

        /// State k's loss term weighed feature by feature (`loss_weights_at`), in place, when the learner weighs them.
        fn weighLoss(self: Self, k: u32) void {
            const loss_weights_at: u32 = self.loss_weights_at orelse return;
            self.pipe.params = .{
                .rows = self.rows,
                .count = self.features,
                .x_off = self.blockDZ(k),
                .y_off = self.blockDZ(k),
                .u_off = loss_weights_at,
            };
            self.pipe.run("lat_scale_columns", self.rows * self.features);
        }

        /// Adam's hyperparameters: zimrnum's defaults, which the CPU model trains with.
        pub const beta1: f32 = 0.9;
        pub const beta2: f32 = 0.999;
        pub const epsilon: f32 = 1.0e-8;

        /// One Adam step over every weight, from the gradient buffer. `t` counts steps from 1, for
        /// the bias corrections (computed here, in f32, the way zimrnum does). `epsilon_scale` is
        /// the constant this gradient carries relative to the CPU model's: Adam cancels a constant
        /// factor in the gradient EXACTLY when epsilon carries the same factor - 8m / (8 sqrt(v) + 8e)
        /// is m / (sqrt(v) + e) - so a kit step on `backward`'s summed loss, with `steps` here, is
        /// the CPU model's step on its averaged one.
        pub fn adamStep(self: Self, rate: f32, t: u32, epsilon_scale: f32) void {
            self.adamOver(self.w1, self.param_count, rate, t, epsilon_scale);
        }

        /// The same step for the POLICY's weights only - its own region of the parameter buffer, from
        /// `p_at`. The kit's `adam` offsets all four of its buffers (weights, gradients, both moments)
        /// by the same `w_off`, so the world model's weights and optimiser state are never touched.
        pub fn adamPolicy(self: Self, rate: f32, t: u32, epsilon_scale: f32) void {
            self.adamOver(self.p_at, self.policy_count, rate, t, epsilon_scale);
        }

        /// The policy's optimiser step: clipped (`policy_optimizer`) when the kit has one - the global length, then
        /// each number, then Adam with its settings - and its length before clipping kept for the log; the kit's own
        /// Adam otherwise. Epsilon carries the steps either way: the policy's gradient is a sum over the horizon.
        fn stepPolicy(self: Self, rate: f32, t: u32) void {
            const horizon: f32 = @floatFromInt(self.steps);
            const optimizer: kit_mlp.ClippedAdam = self.policy_optimizer orelse {
                self.adamPolicy(rate, t, horizon);
                return;
            };
            var settings: kit_mlp.ClippedAdam.Settings = self.policy_optimizer_settings;
            settings.learning_rate = rate;
            settings.epsilon = epsilon * horizon;
            optimizer.step(M, self.pipe, settings, t);
            self.recordStat("policy_gradient_norm", "stat_copy", .{ .x_off = optimizer.norm_offset });
        }

        /// One Adam step over `count` weights from `offset`, `t` counting from 1.
        fn adamOver(
            self: Self,
            offset: u32,
            count: u32,
            rate: f32,
            t: u32,
            epsilon_scale: f32,
        ) void {
            const corrections: zn.AdamCorrections(f32) = zn.adamCorrectionMultipliers(f32, beta1, beta2, t);
            self.pipe.params = .{
                .count = count,
                .w_off = offset,
                .rate = rate,
                .beta1 = beta1,
                .beta2 = beta2,
                .epsilon = epsilon * epsilon_scale,
                .correction1 = corrections.first,
                .correction2 = corrections.second,
            };
            self.pipe.run("adam", count);
        }

        /// One training step of the POLICY on the kit, its windows staged (goals, references, the
        /// first state): the rollout with the policy acting, backward through the fixed world model,
        /// and Adam on the policy's weights - epsilon carrying the steps, as for the world model.
        pub fn policyTrainStep(self: Self, rate: f32, t: u32) void {
            self.forward();
            self.policyBackward();
            // For the log: how hard the rollout presses against the failure rule - measured in raw units, so only
            // where the kit holds the feature normaliser (a learner's does) - and what the critic says lies beyond
            // it: its heads' values at the horizon, decoded by the tail in the backward just run.
            if (self.norm_at != null) {
                self.recordStat("policy_barrier_hinge", "stat_barrier", .{
                    .rows = self.rows,
                    .out_dim = self.features,
                    .count = self.steps,
                    .y_off = self.blockZ(1),
                    .t_off = self.blockG(1),
                    .u_off = self.normaliserOffset(),
                    .barrier_head_column = self.barrier_head_column,
                    .barrier_up_column = self.barrier_up_column,
                    .barrier_head_margin = self.barrier.head_margin,
                    .barrier_head_width = self.barrier.head_width,
                    .barrier_tilt_margin = self.barrier.tilt_margin,
                    .barrier_tilt_width = self.barrier.tilt_width,
                });
            }
            if (self.value_tail) |tail| {
                self.recordStat("policy_tail_value", "stat_mean_and_deviation", .{
                    .rows = @as(u32, @intCast(tail.passes.len)) * tail.rows,
                    .x_off = tail.head_values_at,
                });
            }
            // For the log: how far the rollout's states are from the goals, through the world model.
            self.recordStat("policy_tracking_loss", "stat_mean_square_difference", .{
                .rows = self.steps * self.rows * self.features,
                .x_off = self.z_at,
                .t_off = self.g_at,
            });
            // The policy's Adam, as always; and a flow actor's: teacher 2's gradient added to teacher 1's
            // (`policyBackward` wrote it), then its own optimiser's step on the sum.
            self.stepPolicy(rate, t);
            if (self.flow_actor) |flow_actor| {
                self.distillFlow(flow_actor);
                self.fpoFlow(flow_actor);
                // With shares, the teachers' scaled sum is the gradient the step reads.
                if (flow_actor.learningPart().shares) |shares| {
                    shares.finish(M, self.pipe);
                }
                flow_actor.optimizerStep(self.pipe, t);
            }
        }

        /// The rollout's loss into the kit's loss buffer (`loss[0]`), for the page to show. The
        /// predictions `Z_1 .. Z_steps` are contiguous and so are their targets, so ONE mean over
        /// the lot is the mean over steps of each step's mean - exactly the CPU model's loss, with
        /// no kernel of its own. Call it after `forward`.
        ///
        /// Two things to know. `mse_value` is ONE thread summing every number - fine for a value the
        /// page shows (tens of thousands of floats), wrong for anything on the training's hot path.
        /// And on a GPU the value arrives by readback, a frame or so later; only the CPU twin (the
        /// tests) can read it straight after the dispatch.
        pub fn loss(self: Self) void {
            self.pipe.params = .{
                .rows = self.world_steps * self.rows,
                .out_dim = self.features,
                .y_off = self.z_at,
                .t_off = self.t_at,
            };
            self.pipe.run("mse_value", 1);
        }

        /// One training step of the latent model on the kit, inputs and targets staged: the
        /// rollout forward, backward through it, and Adam - `t` counting from 1.
        pub fn trainStep(self: Self, rate: f32, t: u32) void {
            // The RECORDED actions: see `forwardRecorded`.
            self.forwardRecorded();
            self.recordWorldModelLoss();
            self.backward();
            self.stepWorld(rate, t);
            // The skip model on the same windows, its inputs the recorded ones the rollout left in place.
            if (self.skip_model) |skip_model| {
                skip_model.train(self.pipe, self.stats_at, .{
                    .states_at = self.blockX(0) + self.lead,
                    .references_at = self.blockX(0) + self.lead + self.features,
                    .block_row_stride = self.width,
                    .hidden_at = self.h2_at,
                    .recorded_states_at = self.blockT(1),
                    .world_prediction_at = self.blockZ(skip_model.span),
                    .recorded_at_span = self.blockT(skip_model.span),
                }, rate, t);
            }
        }

        /// The world model's optimiser step: clipped (`world_optimizer`) when the kit has one - the global length, then
        /// Adam with its settings - its length before clipping kept for the log; the kit's own Adam otherwise. Epsilon
        /// carries the world model's window either way: its gradient is a sum over the window's steps.
        fn stepWorld(self: Self, rate: f32, t: u32) void {
            const window: f32 = @floatFromInt(self.world_steps);
            const optimizer: kit_mlp.ClippedAdam = self.world_optimizer orelse {
                self.adamStep(rate, t, window);
                return;
            };
            var settings: kit_mlp.ClippedAdam.Settings = self.world_optimizer_settings;
            settings.learning_rate = rate;
            settings.epsilon = epsilon * window;
            optimizer.step(M, self.pipe, settings, t);
            self.recordStat("world_gradient_norm", "stat_copy", .{ .x_off = optimizer.norm_offset });
        }

        /// The world model's loss for the log (`DeviceStats.world_model_loss`): its predictions against the recorded
        /// states over the whole window - the same arithmetic on the same numbers as the page's `loss`. After
        /// `forwardRecorded`; nothing without a stats block.
        pub fn recordWorldModelLoss(self: Self) void {
            self.recordStat("world_model_loss", "stat_mean_square_difference", .{
                .rows = self.world_steps * self.rows * self.features,
                .x_off = self.z_at,
                .t_off = self.t_at,
            });
        }

        /// The rollout, backward, for the POLICY: the gradient of its loss - every step's mean squared
        /// distance from the reference's GOAL, plus the price on the raw action's size - with respect
        /// to the policy's weights, into the gradient buffer at `p_at`, through the world model held
        /// FIXED (its layers pass input gradients only; its weights get none). Summed over steps, like
        /// `backward`: `steps` times the CPU learner's mean. `forward` must have run with the policy.
        ///
        /// A state's gradient now gathers from FOUR places: its own tracking term; the next state's
        /// (the residual); the world model's input gradient in its state columns; and the POLICY's -
        /// the policy reads the state too - which sits at offset `lead` of the policy's input block,
        /// a block `lead + features` wide (a third width, beside `width` and `inputs`).
        pub fn policyBackward(self: Self) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            const hp: u32 = self.policy_hidden;
            const policy_inputs: u32 = self.lead + self.features;
            const w2p: u32 = self.p_at + policy_inputs * hp + hp;
            const w3p: u32 = w2p + hp * hp + hp;
            var step: u32 = self.steps;
            self.trackingGrad(step);
            self.barrierGrad(step);
            // The window's last state also carries the cost after the window: the critic's value tail.
            if (self.value_tail) |value_tail| {
                // Its heads' values decoded for the log when the learner keeps one (`policy_tail_value`).
                const decode_values: bool = self.stats_at != null;
                const goals_at: u32 = self.blockG(step);
                const states_at: u32 = self.blockZ(step);
                value_tail.addGradient(self.pipe, goals_at, states_at, self.blockDZ(step), decode_values);
            }
            var first: bool = true;
            while (step > 0) {
                step -= 1;
                const k: u32 = step;
                const h1: u32 = self.h1_at + k * self.rows * self.hidden;
                const h2: u32 = self.h2_at + k * self.rows * self.hidden;
                // The world model, frozen: input gradients only, down to its wide-row slice.
                self.inputGrads(self.hidden, self.features, self.changeGradient(k + 1), self.w3, self.dh2_at);
                self.activationGrads(h2, self.dh2_at, tanh, self.hidden);
                self.inputGrads(self.hidden, self.hidden, self.dh2_at, self.w2, self.dh1_at);
                self.activationGrads(h1, self.dh1_at, tanh, self.hidden);
                self.inputGrads(self.inputs, self.hidden, self.dh1_at, self.w1, self.dx_at);
                // The action columns' gradient, back to the policy's raw output - plus the price.
                const raw: u32 = self.raw_at + k * self.rows * self.actions;
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = self.actions,
                    .stride = self.inputs,
                    .dx_off = self.dx_at + self.features + self.references,
                    .x_off = raw,
                    .dy_off = self.draw_at,
                    .lat_scale = self.action_scale,
                    .lat_penalty = 2.0 * self.w_action / float(self.rows * self.actions),
                    .lat_smooth = 2.0 * self.w_smooth / float(self.rows * self.actions),
                    // A missing neighbour is this step itself: raw - raw, exactly zero.
                    .lat_prev = if (k > 0) raw - self.rows * self.actions else raw,
                    .lat_next = if (k + 1 < self.steps) raw + self.rows * self.actions else raw,
                };
                self.pipe.run("lat_act_bwd", self.rows * self.actions);
                // A flow actor keeps the raw action's gradient projected onto its synergies, as its training row's
                // cost gradient; the policy then takes the gradient as it always does.
                if (self.flow_actor) |flow_actor| {
                    self.keepFlowCostGradient(flow_actor, k);
                }
                // The policy: weight gradients accumulated across the steps, input gradients down.
                const accumulate: u32 = if (first) 0 else 1;
                first = false;
                const ph1: u32 = self.ph1_at + k * self.rows * hp;
                const ph2: u32 = self.ph2_at + k * self.rows * hp;
                self.weightGrads(ph2, 0, hp, self.actions, self.draw_at, w3p, accumulate);
                self.inputGrads(hp, self.actions, self.draw_at, w3p, self.dph2_at);
                self.activationGrads(ph2, self.dph2_at, tanh, hp);
                self.weightGrads(ph1, 0, hp, hp, self.dph2_at, w2p, accumulate);
                self.inputGrads(hp, hp, self.dph2_at, w2p, self.dph1_at);
                self.activationGrads(ph1, self.dph1_at, tanh, hp);
                self.weightGrads(self.blockX(k), self.width, policy_inputs, hp, self.dph1_at, self.p_at, accumulate);
                if (k == 0) {
                    break;
                }
                self.inputGrads(policy_inputs, hp, self.dph1_at, self.p_at, self.dp_at);
                // State k's gradient, from all four places - and the barrier, when there is one.
                self.trackingGrad(k);
                self.barrierGrad(k);
                self.pipe.params = .{
                    .count = self.rows * self.features,
                    .dy_off = self.blockDZ(k),
                    .dx_off = self.blockDZ(k + 1),
                };
                self.pipe.run("add_block", self.rows * self.features);
                self.take(self.dx_at, self.inputs, k);
                self.take(self.dp_at + self.lead, policy_inputs, k);
            }
            // The flow learns from every (step, row) of the rollout at once, its cost gradients now all kept.
            if (self.flow_actor) |flow_actor| {
                self.flowTrainingGradient(flow_actor);
            }
        }

        /// TEACHER 3'S ADVANTAGES (`FlowActor.Fpo`): how each of the round's real steps turned out against what the
        /// critic expected, A = -c - gamma C(next) + C(this), into the batch's advantages. In order:
        ///
        ///     the example's parts, packed     goals [own goals; goals], states [states; next states]  (`copyColumns`)
        ///     each step's cost                the next state against the goal it aimed at - this kit's cost and
        ///                                     barrier, as the critic's own targets charge (`lat_tracking_cost`)
        ///     the critic's heads              at [own goal | state] and at [goal | next state]: one tail over
        ///                                     twice the batch's rows (`LatentCritic.Tail.forwardValues`)
        ///     the advantage                   -c - gamma x the heads' mean where it led + their mean where it
        ///                                     started (`fpo_advantages`)
        ///
        /// The batch must hold examples, and its advantage must be reserved (`Fpo.reserveAdvantage`).
        pub fn fpoAdvantages(self: Self, fpo: FlowActor(M).Fpo) void {
            const is_reserved: bool = fpo.advantage != null;
            assertf(is_reserved, @src(), "fpoAdvantages: the batch's advantage is not reserved", .{});
            const advantage: FlowActor(M).Fpo.Advantage = fpo.advantage.?;
            const rows: u32 = fpo.rows;
            const features: u32 = fpo.features;
            const columns: FlowActor(M).Fpo.Columns = fpo.exampleColumns();
            // The parts, packed: each example's four feature parts, each into its half of the critic's goals or
            // states.
            const half_floats: u32 = rows * features;
            const sources = [4]u32{ columns.own_goal, columns.goal, columns.state, columns.next_state };
            const destinations = [4]u32{
                advantage.goals_at,
                advantage.goals_at + half_floats,
                advantage.states_at,
                advantage.states_at + half_floats,
            };
            for (sources, destinations) |first_column, destination_at| {
                const example_part: kit_mlp.RowColumns = .{
                    .offset = fpo.examples_at,
                    .row_stride = columns.width,
                    .first_column = first_column,
                };
                const packed_part: kit_mlp.RowColumns = .packedRows(destination_at, features);
                kit_mlp.copyColumns(M, self.pipe, rows, features, example_part, packed_part);
            }
            // Each step's cost: where it led, against the goal it aimed at.
            const next_states_at: u32 = advantage.states_at + half_floats;
            const aimed_goals_at: u32 = advantage.goals_at + half_floats;
            const cost: TrackingCost = self.trackingCost();
            runTrackingCost(M, self.pipe, cost, rows, next_states_at, aimed_goals_at, advantage.costs_at);
            // The critic's heads, at every start and every next step at once.
            advantage.tail.forwardValues(self.pipe, advantage.goals_at, advantage.states_at, advantage.values_at);
            // The advantages.
            self.pipe.params = .{
                .rows = rows,
                .count = advantage.heads,
                .x_off = advantage.costs_at,
                .v_off = advantage.values_at,
                .y_off = advantage.advantages_at,
                .gamma = advantage.discount,
            };
            self.pipe.run("fpo_advantages", rows);
        }

        /// A statistic into the stats block's `field` (`DeviceStats`): `kernel` run once with `inputs`, its output
        /// place set here - nothing when the learner keeps no block.
        fn recordStat(
            self: Self,
            comptime field: []const u8,
            comptime kernel: []const u8,
            inputs: M.Params,
        ) void {
            recordDeviceStat(M, self.pipe, self.stats_at, field, kernel, inputs);
        }

        /// TEACHER 3's gradient (`FlowActor.Fpo`), added to the flow's gradients when the round's batch holds
        /// examples: FPO's update on the round's draws (`KitFlow.fpoGradient`) - the new losses on the same rows at
        /// the current weights, PPO's clipped surrogate with the normalised advantages - at teacher 3's weight.
        fn fpoFlow(self: Self, flow_actor: FlowActor(M)) void {
            const learning: FlowActor(M).Learning = flow_actor.learningPart();
            const fpo: FlowActor(M).Fpo = learning.fpo orelse return;
            if (!fpo.has_batch) {
                return;
            }
            const update: FlowActor(M).Fpo.Update = fpo.update.?;
            const fpo_numbers: kit_mlp.KitFlow(M).FpoNumbers = .{
                .old_losses_at = update.old_losses_at,
                .new_losses_at = update.new_losses_at,
                .advantages_at = update.advantages_at,
            };
            const flow: kit_mlp.KitFlow(M) = flow_actor.flow;
            const writes: kit_mlp.ParameterGradients = if (learning.shares != null) .overwrite else .add;
            flow.fpoGradient(self.pipe, update.trainer, update.draws, fpo_numbers, fpo.clip, fpo.weight, writes);
            if (learning.shares) |shares| {
                shares.absorb(M, self.pipe, fpo.weight, false);
                self.recordStat("flow_fpo_weight_gradient", "stat_copy", .{ .x_off = shares.factor_offset });
            }
            // For the log: how far the round's updates have moved the flow from where its examples were taken.
            self.recordStat("fpo_ratio_mean", "fpo_ratio_stats", .{
                .rows = fpo.rows,
                .x_off = update.old_losses_at,
                .u_off = update.new_losses_at,
                .v_off = update.advantages_at,
                .clip = fpo.clip,
            });
        }

        /// TEACHER 3'S ROUND START (`FlowActor.Fpo`): with the round's batch uploaded, everything FPO's updates will
        /// read, at the weights and the critic the round starts from -
        ///
        ///     the advantages     (`fpoAdvantages`), then normalised over the batch (`fpo_normalize_advantages`)
        ///     the old losses     each example's condition and coefficients copied packed (`Fpo.Columns`), then
        ///                        broadcast to its draws' rows (`broadcast_rows`); each row's noise - the flow's own,
        ///                        at its scale - and time hashed from the batch's `draw_seed`; the flow's draw losses
        ///                        (`KitFlow.drawLosses`)
        ///
        /// The draws' rows are left as they are for the round: its updates compute their new losses on the same rows
        /// and draws, so the ratio of new to old is exactly 1 until the weights move.
        pub fn fpoRoundStart(
            self: Self,
            flow_actor: FlowActor(M),
            fpo: FlowActor(M).Fpo,
        ) void {
            const has_losses: bool = fpo.update != null;
            assertf(has_losses, @src(), "fpoRoundStart: the batch's draws are not reserved", .{});
            const update: FlowActor(M).Fpo.Update = fpo.update.?;
            self.fpoAdvantages(fpo);
            // The advantages normalised over the batch, where the update reads them.
            self.pipe.params = .{
                .rows = fpo.rows,
                .x_off = fpo.advantage.?.advantages_at,
                .y_off = update.advantages_at,
            };
            self.pipe.run("fpo_normalize_advantages", 1);
            // For the log: the raw advantages' mean and spread.
            self.recordStat("fpo_advantage_mean", "stat_mean_and_deviation", .{
                .rows = fpo.rows,
                .x_off = fpo.advantage.?.advantages_at,
            });
            const flow: kit_mlp.KitFlow(M) = flow_actor.flow;
            const trainer: kit_mlp.KitFlow(M).Trainer = update.trainer;
            const columns: FlowActor(M).Fpo.Columns = fpo.exampleColumns();
            const condition_width: u32 = 2 * fpo.features;
            const synergy_count: u32 = fpo.synergy_count;
            // Each example's condition and coefficients, packed ...
            const conditions: kit_mlp.RowColumns = .{
                .offset = fpo.examples_at,
                .row_stride = columns.width,
                .first_column = columns.goal,
            };
            const packed_conditions: kit_mlp.RowColumns = .packedRows(update.conditions_at, condition_width);
            kit_mlp.copyColumns(M, self.pipe, fpo.rows, condition_width, conditions, packed_conditions);
            const coefficients: kit_mlp.RowColumns = .{
                .offset = fpo.examples_at,
                .row_stride = columns.width,
                .first_column = columns.coefficients,
            };
            const packed_coefficients: kit_mlp.RowColumns = .packedRows(update.coefficients_at, synergy_count);
            kit_mlp.copyColumns(M, self.pipe, fpo.rows, synergy_count, coefficients, packed_coefficients);
            // ... then into each of its draws' rows: the conditions into the wide rows, the coefficients as actions.
            self.pipe.params = .{
                .rows = fpo.rows,
                .row_copies = update.draws,
                .count = condition_width,
                .x_off = update.conditions_at,
                .y_off = trainer.wide_rows_at,
                .stride = flow.wideRowWidth(),
                .col = 0,
            };
            self.pipe.run("broadcast_rows", trainer.rows * condition_width);
            self.pipe.params = .{
                .rows = fpo.rows,
                .row_copies = update.draws,
                .count = synergy_count,
                .x_off = update.coefficients_at,
                .y_off = trainer.actions_at,
                .stride = synergy_count,
                .col = 0,
            };
            self.pipe.run("broadcast_rows", trainer.rows * synergy_count);
            // Each row's noise and time, from the round's seed.
            self.pipe.params = .{
                .rows = trainer.rows,
                .count = synergy_count,
                .y_off = trainer.noise_at,
                .stride = synergy_count,
                .col = 0,
                .lat_sigma = flow_actor.correction.noise_scale,
                .lat_seed = fpo.draw_seed,
            };
            self.pipe.run("hashed_noise", trainer.rows * synergy_count);
            self.pipe.params = .{
                .rows = trainer.rows,
                .y_off = trainer.times_at,
                .lat_seed = M.latStepSeed(fpo.draw_seed, 1),
            };
            self.pipe.run("hashed_uniforms", trainer.rows);
            // The old losses.
            flow.drawLosses(self.pipe, trainer, update.draws, update.old_losses_at);
            // For the log: how likely the flow found its own corrections, and how evenly.
            self.recordStat("fpo_old_loss_mean", "stat_mean_and_deviation", .{
                .rows = fpo.rows,
                .x_off = update.old_losses_at,
            });
        }

        /// TEACHER 2's gradient (`FlowActor.Distillation`), added to the flow's gradients when the round's batch holds
        /// examples: the batch's conditions into the trainer's wide rows, each row's noise and flow time hashed from
        /// this update's seed (at step numbers past those the rollout and FlowDPG use), and the flow matching gradient
        /// at the distillation's weight.
        fn distillFlow(self: Self, flow_actor: FlowActor(M)) void {
            const learning: FlowActor(M).Learning = flow_actor.learningPart();
            const distillation: FlowActor(M).Distillation = learning.distillation orelse return;
            if (!distillation.has_batch) {
                return;
            }
            const flow: kit_mlp.KitFlow(M) = flow_actor.flow;
            const trainer: kit_mlp.KitFlow(M).Trainer = distillation.trainer;
            const condition_width: u32 = flow.condition_width;
            const batch_conditions: kit_mlp.RowColumns = .packedRows(distillation.conditions_at, condition_width);
            const wide_row_conditions: kit_mlp.RowColumns = .{
                .offset = trainer.wide_rows_at,
                .row_stride = flow.wideRowWidth(),
            };
            kit_mlp.copyColumns(M, self.pipe, trainer.rows, condition_width, batch_conditions, wide_row_conditions);
            const correction: FlowActor(M).Correction = flow_actor.correction;
            self.pipe.params = .{
                .rows = trainer.rows,
                .count = correction.synergy_count,
                .y_off = trainer.noise_at,
                .stride = correction.synergy_count,
                .col = 0,
                .lat_sigma = correction.noise_scale,
                .lat_seed = M.latStepSeed(self.seed, self.steps + 1),
            };
            self.pipe.run("hashed_noise", trainer.rows * correction.synergy_count);
            self.pipe.params = .{
                .rows = trainer.rows,
                .y_off = trainer.times_at,
                .lat_seed = M.latStepSeed(self.seed, self.steps + 2),
            };
            self.pipe.run("hashed_uniforms", trainer.rows);
            // Written over the flow's gradients and absorbed at its share when the teachers share the update; added to
            // teacher 1's otherwise.
            const writes: kit_mlp.ParameterGradients = if (learning.shares != null) .overwrite else .add;
            flow.flowMatchingGradient(self.pipe, trainer, distillation.weight, writes);
            if (learning.shares) |shares| {
                shares.absorb(M, self.pipe, distillation.weight, false);
                self.recordStat("flow_distill_weight_gradient", "stat_copy", .{ .x_off = shares.factor_offset });
            }
            // For the log: how far the flow's velocity is from the plans' paths.
            self.recordStat("distillation_loss", "stat_mean_square_difference", .{
                .rows = trainer.rows * flow.action_width,
                .x_off = trainer.application.outputsOffset(),
                .t_off = trainer.path_velocities_at,
            });
        }

        /// Step k's cost gradient for the flow: the raw action's gradient - prices included (`lat_act_bwd`), in the
        /// gradient buffer - projected onto the synergies, g_c = B g (`synergy_project_gradient`), into the flow
        /// trainer's cost gradients, the rows of step k.
        fn keepFlowCostGradient(self: Self, flow_actor: FlowActor(M), k: u32) void {
            const correction: FlowActor(M).Correction = flow_actor.correction;
            const synergy_count: u32 = correction.synergy_count;
            const trainer: kit_mlp.KitFlow(M).Trainer = flow_actor.learningPart().trainer;
            self.pipe.params = .{
                .rows = self.rows,
                .count = synergy_count,
                .out_dim = self.actions,
                .x_off = self.draw_at,
                .w_off = correction.synergies_at,
                .y_off = trainer.cost_gradients_at + k * self.rows * synergy_count,
            };
            self.pipe.run("synergy_project_gradient", self.rows * synergy_count);
        }

        /// The flow's training rows laid out from the rollout - one per (step, row): the step's [goal | state] as its
        /// condition, the action the flow took, the noise it took it from (the step's base noise again), a drawn
        /// flow time - and FlowDPG's gradient over them, into the flow's weights' gradients.
        fn flowTrainingGradient(self: Self, flow_actor: FlowActor(M)) void {
            const flow: kit_mlp.KitFlow(M) = flow_actor.flow;
            const learning: FlowActor(M).Learning = flow_actor.learningPart();
            const trainer: kit_mlp.KitFlow(M).Trainer = learning.trainer;
            const correction: FlowActor(M).Correction = flow_actor.correction;
            const synergy_count: u32 = correction.synergy_count;
            const condition_width: u32 = self.lead + self.features;
            const flow_width: u32 = flow.wideRowWidth();
            for (0..self.steps) |step_index| {
                const k: u32 = @intCast(step_index);
                // The condition, from the step's wide row.
                const step_condition: kit_mlp.RowColumns = .{ .offset = self.blockX(k), .row_stride = self.width };
                const training_condition: kit_mlp.RowColumns = .{
                    .offset = trainer.wide_rows_at + k * self.rows * flow_width,
                    .row_stride = flow_width,
                };
                kit_mlp.copyColumns(M, self.pipe, self.rows, condition_width, step_condition, training_condition);
                // The noise the step's coefficients came from: the flow's own, drawn again from the same seed.
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = synergy_count,
                    .y_off = trainer.noise_at + k * self.rows * synergy_count,
                    .stride = synergy_count,
                    .col = 0,
                    .lat_sigma = correction.noise_scale,
                    .lat_seed = self.flowNoiseSeed(k),
                };
                self.pipe.run("hashed_noise", self.rows * synergy_count);
            }
            // The coefficients the flow chose, every step's at once - they lie packed, step after step.
            const training_rows: u32 = self.steps * self.rows;
            const chosen: kit_mlp.RowColumns = .packedRows(flow_actor.coefficients_at, synergy_count);
            const training_coefficients: kit_mlp.RowColumns = .packedRows(trainer.actions_at, synergy_count);
            kit_mlp.copyColumns(M, self.pipe, training_rows, synergy_count, chosen, training_coefficients);
            // Each row's flow time, under a seed of its own - a step number past the rollout's.
            self.pipe.params = .{
                .rows = training_rows,
                .y_off = trainer.times_at,
                .lat_seed = M.latStepSeed(self.seed, self.steps),
            };
            self.pipe.run("hashed_uniforms", training_rows);
            const teacher: FlowActor(M).Teacher = learning.teacher;
            // The floor: the typical length of the flow's own noise, in its k coefficients.
            const noise_length: f32 = correction.noise_scale * @sqrt(float(synergy_count));
            const step_floor: f32 = teacher.step_floor orelse noise_length;
            // Teacher 1 writes the flow's gradients first; the others add theirs.
            flow.flowDpgGradient(self.pipe, trainer, teacher.step_share, step_floor, teacher.anchor, .overwrite);
            // Its share of the update, the first of the round's teachers, and its natural length for the log.
            if (learning.shares) |shares| {
                shares.absorb(M, self.pipe, teacher.dpg_share, true);
                self.recordStat("flow_dpg_weight_gradient", "stat_copy", .{ .x_off = shares.factor_offset });
            }
            // For the log: how hard the world model's gradient pushes the flow.
            self.recordStat("flow_dpg_gradient_rms", "stat_root_mean_square", .{
                .rows = trainer.rows * flow.action_width,
                .x_off = trainer.velocity_gradient_at,
            });
        }

        /// dZ_k = 2 (Z_k - G_k) / (rows x features): step k's TRACKING term - distance from the goal.
        fn trackingGrad(self: Self, k: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .out_dim = self.features,
                .y_off = self.blockZ(k),
                .t_off = self.blockG(k),
                .dy_off = self.blockDZ(k),
            };
            self.pipe.run("mse_bwd", self.rows * self.features);
        }

        /// This kit's per-step cost settings (`TrackingCost`): its barrier, the barrier's columns, and the normaliser
        /// when the barrier is on (it must then be placed) - 0 when it is off, for nothing reads it.
        pub fn trackingCost(self: Self) TrackingCost {
            const has_barrier: bool = self.barrier.weight != 0;
            const cost: TrackingCost = .{
                .features = self.features,
                .barrier = self.barrier,
                .barrier_head_column = self.barrier_head_column,
                .barrier_up_column = self.barrier_up_column,
                .norm_at = if (has_barrier) self.normaliserOffset() else 0,
                .cap = self.cost_cap,
            };
            return cost;
        }

        /// Step k's failure barrier, added into its state gradient (`lat_barrier_bwd`) - nothing at weight 0.
        /// Where the feature normaliser is - what the failure barrier reads to put its margins in the world's units.
        /// The learner must have placed it (`norm_at`) before turning the barrier on.
        pub fn normaliserOffset(self: Self) u32 {
            const has_normaliser: bool = self.norm_at != null;
            const reason: []const u8 = "the failure barrier reads the feature normaliser: place it (norm_at)";
            assertf(has_normaliser, @src(), "{s}", .{reason});
            return self.norm_at.?;
        }

        fn barrierGrad(self: Self, k: u32) void {
            const barrier: FailureBarrier = self.barrier;
            if (barrier.weight == 0) {
                return;
            }
            self.pipe.params = .{
                .rows = self.rows,
                .out_dim = self.features,
                .y_off = self.blockZ(k),
                .t_off = self.blockG(k),
                .u_off = self.normaliserOffset(),
                .dy_off = self.blockDZ(k),
                .barrier_head_column = self.barrier_head_column,
                .barrier_up_column = self.barrier_up_column,
                .barrier_weight = barrier.weight,
                .barrier_head_margin = barrier.head_margin,
                .barrier_head_width = barrier.head_width,
                .barrier_tilt_margin = barrier.tilt_margin,
                .barrier_tilt_width = barrier.tilt_width,
            };
            self.pipe.run("lat_barrier_bwd", self.rows);
        }

        /// The state columns of an input-gradient block (starting at `from`, rows `stride` apart)
        /// added into state k's gradient.
        fn take(self: Self, from: u32, stride: u32, k: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .count = self.features,
                .stride = stride,
                .dy_off = self.blockDZ(k),
                .dx_off = from,
            };
            self.pipe.run("lat_take", self.rows * self.features);
        }

        /// dZ_k = 2 (Z_k - T_k) / (rows x features): one step's loss term, written fresh.
        fn mse(self: Self, k: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .out_dim = self.features,
                .y_off = self.blockZ(k),
                .t_off = self.blockT(k),
                .dy_off = self.blockDZ(k),
            };
            self.pipe.run("mse_bwd", self.rows * self.features);
        }

        fn weightGrads(
            self: Self,
            x: u32,
            stride: u32,
            in_dim: u32,
            out_dim: u32,
            dy: u32,
            w: u32,
            accumulate: u32,
        ) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = in_dim,
                .out_dim = out_dim,
                .x_off = x,
                .stride = stride,
                .dy_off = dy,
                .w_off = w,
                .accumulate = accumulate,
            };
            self.pipe.run("dense_bwd_w", in_dim * out_dim + out_dim);
        }

        fn inputGrads(
            self: Self,
            in_dim: u32,
            out_dim: u32,
            dy: u32,
            w: u32,
            dx: u32,
        ) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = in_dim,
                .out_dim = out_dim,
                .dy_off = dy,
                .w_off = w,
                .dx_off = dx,
            };
            self.pipe.run("dense_bwd_x", self.rows * in_dim);
        }

        fn activationGrads(
            self: Self,
            y: u32,
            dy: u32,
            act: u32,
            width: u32,
        ) void {
            self.pipe.params = .{
                .rows = self.rows,
                .out_dim = width,
                .y_off = y,
                .dy_off = dy,
                .act = act,
            };
            self.pipe.run("act_bwd", self.rows * width);
        }

        /// The CPU model's eight parameter tensors in the kit's layout: the first layer's three
        /// blocks stacked (features, reference, action - the order of the wide row) then its bias;
        /// then each later layer's weights and bias. `out` holds `param_count` floats.
        pub fn packWeights(self: Self, params: [8]Tensor, out: []f32) void {
            assertf(out.len == self.param_count, @src(), "packWeights: {d} floats given, the layout holds {d}", .{
                out.len,
                self.param_count,
            });
            var at: usize = 0;
            for (params) |p| {
                @memcpy(out[at..][0..p.data.len], p.data);
                at += p.data.len;
            }
            // The eight tensors must fill the layout exactly - a model of another width would not.
            assertf(at == self.param_count, @src(), "packWeights: tensors hold {d} floats, layout {d}", .{
                at,
                self.param_count,
            });
        }

        /// The CPU learner's seven policy tensors in the kit's layout, `policy_count` floats, uploaded
        /// at `p_at`. The CPU's first layer is two blocks - state (`params[0]`), goal (`params[1]`) -
        /// and the row puts the GOAL first, so they are stacked goal block, then state block.
        pub fn packPolicy(self: Self, params: [7]Tensor, out: []f32) void {
            assertf(out.len == self.policy_count, @src(), "packPolicy: {d} floats given, the layout holds {d}", .{
                out.len,
                self.policy_count,
            });
            var at: usize = 0;
            for ([_]usize{ 1, 0, 2, 3, 4, 5, 6 }) |i| {
                @memcpy(out[at..][0..params[i].data.len], params[i].data);
                at += params[i].data.len;
            }
            assertf(at == self.policy_count, @src(), "packPolicy: tensors hold {d} floats, layout {d}", .{
                at,
                self.policy_count,
            });
        }

        /// The policy's turn at step k: its three layers over the row's [goal | state] slice, and
        /// its action written into the row's action columns - before the world model reads the row.
        fn policyStep(self: Self, k: u32) void {
            // A correction corrects a policy: without one there is nothing to correct. And it comes from one place.
            const has_flow: bool = self.flow_actor != null;
            const has_given: bool = self.given_corrections != null;
            const correction_without_policy: bool = (has_flow or has_given) and self.policy_hidden == 0;
            assertf(!correction_without_policy, @src(), "a correction corrects a policy: this kit has none", .{});
            assertf(!(has_flow and has_given), @src(), "corrections from a flow and given ones, both: one only", .{});
            const tanh: u32 = @backingInt(M.Act.tanh);
            const linear: u32 = @backingInt(M.Act.linear);
            const hp: u32 = self.policy_hidden;
            const h1: u32 = self.ph1_at + k * self.rows * hp;
            const h2: u32 = self.ph2_at + k * self.rows * hp;
            const raw: u32 = self.raw_at + k * self.rows * self.actions;
            const w1: u32 = self.p_at;
            const w2: u32 = w1 + (self.lead + self.features) * hp + hp;
            const w3: u32 = w2 + hp * hp + hp;
            // The policy's slice: the row's first `lead + features` columns - the goal and the state -
            // read with the row's full stride, so the reference and action columns beyond them are
            // simply not part of this layer's input. Its weights are stacked in that same order
            // (`packPolicy`), which is what makes one matrix multiply do the work of two.
            self.dense(self.blockX(k), self.width, self.lead + self.features, hp, w1, h1, tanh);
            self.dense(h1, 0, hp, hp, w2, h2, tanh);
            self.dense(h2, 0, hp, self.actions, w3, raw, linear);
            // A correction - a flow's, or one given - added to the policy's raw action before the exploration and the
            // write.
            if (self.flow_actor) |flow_actor| {
                self.flowCorrection(flow_actor, k, raw);
            } else if (self.given_corrections) |given| {
                self.givenCorrection(given, k, raw);
            }
            // And the action into the row: `lat_act` scales the raw output (and adds this step's noise)
            // straight into the action columns the world model's layers will read next - the two
            // networks never exchange a buffer, only columns of one row.
            self.pipe.params = .{
                .rows = self.rows,
                .count = self.actions,
                .stride = self.width,
                .x_off = raw,
                .y_off = self.blockX(k) + self.lead + self.features + self.references,
                .lat_scale = self.action_scale,
                .lat_sigma = self.sigma,
                .lat_seed = M.latStepSeed(self.seed, k),
            };
            self.pipe.run("lat_act", self.rows * self.actions);
        }

        /// Whether a policy acts in this kit's rollout (`policy_hidden` above 0) - with a flow actor's correction on
        /// top, when it has one.
        pub fn actsWithPolicy(self: Self) bool {
            return self.policy_hidden > 0;
        }

        /// The flow's CORRECTION at step k (`FlowActor`), added to the policy's raw action at `raw`: the policy's
        /// [goal | state] from the step's wide row into every block of the sampler, the flow's own noise into the
        /// first (`flowNoiseSeed`, at the correction's noise scale), the sample - k coefficients, kept with the step's
        /// (`coefficients_at`) - and their synergies decoded and added (`synergy_decode_add`): raw += B^T c.
        fn flowCorrection(self: Self, flow_actor: FlowActor(M), k: u32, raw: u32) void {
            const flow: kit_mlp.KitFlow(M) = flow_actor.flow;
            const correction: FlowActor(M).Correction = flow_actor.correction;
            const sampler: kit_mlp.KitFlow(M).Sampler = flow_actor.sampler;
            const condition_width: u32 = self.lead + self.features;
            const condition_matches: bool = flow.condition_width == condition_width;
            assertf(condition_matches, @src(), "the flow reads a {d}-wide condition, the policy's is {d}", .{
                flow.condition_width,
                condition_width,
            });
            const actions_match: bool = correction.action_width == self.actions;
            assertf(actions_match, @src(), "the flow corrects {d} actions, the policy has {d}", .{
                correction.action_width,
                self.actions,
            });
            const flow_width: u32 = flow.wideRowWidth();
            const synergy_count: u32 = correction.synergy_count;
            const step_condition: kit_mlp.RowColumns = .{ .offset = self.blockX(k), .row_stride = self.width };
            for (sampler.blocks_at) |block_at| {
                const block_condition: kit_mlp.RowColumns = .{ .offset = block_at, .row_stride = flow_width };
                kit_mlp.copyColumns(M, self.pipe, self.rows, condition_width, step_condition, block_condition);
            }
            self.pipe.params = .{
                .rows = self.rows,
                .count = synergy_count,
                .y_off = sampler.blocks_at[0],
                .stride = flow_width,
                .col = flow.pointColumn(),
                .lat_sigma = correction.noise_scale,
                .lat_seed = self.flowNoiseSeed(k),
            };
            self.pipe.run("hashed_noise", self.rows * synergy_count);
            const step_coefficients_at: u32 = flow_actor.coefficients_at + k * self.rows * synergy_count;
            flow.sample(self.pipe, sampler, .packedRows(step_coefficients_at, synergy_count));
            self.pipe.params = .{
                .rows = self.rows,
                .count = synergy_count,
                .out_dim = self.actions,
                .x_off = step_coefficients_at,
                .w_off = correction.synergies_at,
                .y_off = raw,
            };
            self.pipe.run("synergy_decode_add", self.rows * self.actions);
        }

        /// The given correction at step k (`GivenCorrections`), added to the policy's raw action at `raw`: the step's
        /// coefficients decoded through the synergies (`synergy_decode_add`), raw += B^T c.
        fn givenCorrection(self: Self, given: GivenCorrections, k: u32, raw: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .count = given.synergy_count,
                .out_dim = self.actions,
                .x_off = given.coefficients_at + k * self.rows * given.synergy_count,
                .w_off = given.synergies_at,
                .y_off = raw,
            };
            self.pipe.run("synergy_decode_add", self.rows * self.actions);
        }

        /// The seed of the flow's own noise at step k: a stream of its own, apart from the exploration's (which is
        /// `latStepSeed(seed, k)`) - hashed per (row, index) alike, the two would otherwise be the same numbers, the
        /// flow's noise for synergy j the exploration's for action j. The rollout and the flow's training rows both
        /// draw it here, so the noise a step's coefficients came from is drawn again exactly.
        fn flowNoiseSeed(self: Self, k: u32) u32 {
            const flow_stream_seed: u32 = M.latStepSeed(self.seed, self.steps + 3);
            return M.latStepSeed(flow_stream_seed, k);
        }

        /// The rollout, forward: for every step, three dense layers over the wide block and the
        /// join into the next. The caller has staged every block's reference and action columns
        /// and block 0's features; the kit fills the rest.
        pub fn forward(self: Self) void {
            self.rollout(self.actsWithPolicy());
        }

        /// The same rollout on the actions AS GATHERED - the ones the simulator really took - with no
        /// policy acting. This is the rollout the world model is trained through: trained through the
        /// acting one, it would learn to match the simulator's outcomes to actions the simulator never
        /// took, which is a world that does not exist.
        pub fn forwardRecorded(self: Self) void {
            self.rollout(false);
        }

        fn rollout(self: Self, acting: bool) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            const linear: u32 = @backingInt(M.Act.linear);
            // The policy's horizon when it acts; the world model's own window on the recorded actions.
            const rollout_steps: u32 = if (acting) self.steps else self.world_steps;
            for (0..rollout_steps) |step| {
                const k: u32 = @intCast(step);
                // When acting, the policy goes first: its action is what the world model's step reads.
                if (acting) {
                    self.policyStep(k);
                }
                const h1: u32 = self.h1_at + k * self.rows * self.hidden;
                const h2: u32 = self.h2_at + k * self.rows * self.hidden;
                const change: u32 = self.change_at + k * self.rows * self.features;
                // The world model's slice of the row: from `lead` on, `inputs` wide, rows `width` apart.
                self.dense(self.blockX(k) + self.lead, self.width, self.inputs, self.hidden, self.w1, h1, tanh);
                self.dense(h1, 0, self.hidden, self.hidden, self.w2, h2, tanh);
                self.dense(h2, 0, self.hidden, self.features, self.w3, change, linear);
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = self.features,
                    .stride = self.width,
                    .x_off = self.blockX(k) + self.lead,
                    .t_off = change,
                    .y_off = self.blockX(k + 1) + self.lead,
                    .z_off = self.blockZ(k + 1),
                    .lat_increments_on = if (self.increments_at != null) 1 else 0,
                    .lat_increments_at = self.increments_at orelse 0,
                };
                self.pipe.run("lat_advance", self.rows * self.features);
            }
        }

        fn dense(
            self: Self,
            x: u32,
            stride: u32,
            in_dim: u32,
            out_dim: u32,
            w: u32,
            y: u32,
            act: u32,
        ) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = in_dim,
                .out_dim = out_dim,
                .act = act,
                .x_off = x,
                .stride = stride,
                .w_off = w,
                .y_off = y,
            };
            self.pipe.run("dense_fwd", self.rows * out_dim);
        }
    };
}

/// Where a training window starts: a character, and its first record's replay index.
pub const Start = struct {
    env: u32,
    index: u64,
};

/// THE TRACKING PLANNER'S SCORER: how good a plan is - H actions from a state - by SuperTrack's own objective. A plan
/// is rolled through SuperTrack's world model, each step charged as the policy's loss charges a rolled step (c, the
/// tracking cost - `lat_tracking_cost`: the distance from the goal, plus the failure barrier - against the reference as
/// it will be k steps on), and the critic's cost-to-go C read after it. The cost of the plan's first h steps, then
/// the critic at the state they reach, is the critic's own recursion C(z_0) = c(z_1) + gamma C(z_1) cut at depth h:
///
///     Q_h = c(z_1) + gamma c(z_2) + ... + gamma^(h-1) c(z_h)  +  tail weight x gamma^h C(z_h)
///
/// and the OBJECTIVE (`zimrrl.PlanObjective`) says which prefixes count:
///
///     final              Q_H: the whole plan, then the critic after its last step
///     mean_over_depths   (Q_1 + ... + Q_H) / H: every prefix - EfficientTDMPC's multi-horizon objective, which
///                        prefers plans that stay good wherever the policy would take over, to plans whose worth
///                        appears only at the horizon, where the world model's errors have had longest to grow
///
/// Both are weights on the step costs and the critic's values (`zimrrl.planObjectiveWeights`), so the score is
/// EfficientTDMPC's own combination (`zn_mlp.plan_score_combine`) with the costs and the cost-to-go weighed negatively
/// - the search ranks a higher score better - and its pessimism: beta standard deviations of the estimate's mean over
/// the critic's heads (eq. 10), so a plan the heads disagree on scores lower. The same cost, model and critic the
/// policy learns from: a plan the search prefers is one the policy would prefer if it could see as far.
///
/// ---- ONE KIT, PLACED AFTER THE OTHERS ----
///
/// A candidate is a sequence of CORRECTIONS AROUND THE POLICY, not of actions: its rollout is a `LatentKit`'s acting
/// rollout - the policy reacting to every state the model reaches, closed loop - with the candidate's correction for
/// each step added to the policy's raw action (`GivenCorrections`), over rows that are candidates rather than windows:
/// [state][candidate], H steps, no exploration. A candidate of zeros is the policy itself. Corrections stay meaningful
/// when the state drifts - a plan acted on late adds its correction to the policy's reaction to the state actually
/// reached - and a search around the policy starts where the policy already is. The kit has the training kit's world
/// model's and policy's shapes, so its weights ARE the training kit's (a kit's weights start at the buffer's start);
/// its activations are its own, placed after everything else in the buffers (`LatentKit.placedAt`).
///
/// ---- WHAT THE CALLER STAGES ----
///
///     the start state of each candidate    block X_0's state columns   (a state's, repeated over its candidates)
///     the reference at each step           blocks X_0 .. X_(H-1), reference columns
///     the goal after each step             blocks G_1 .. G_H
///     each candidate's corrections          packed step by step, [step][candidate row][action] - where a search
///                                          samples them (`searchShape`), and where the rollout reads them
///
/// `writeInputs` stages all of them from the host; a search writes the corrections on the device.
pub fn TrackingScorer(comptime M: type) type {
    return struct {
        const Self = @This();
        pub const Pipe = compute_host.Compute(M);

        pub const Options = struct {
            states: u32,
            candidates: u32,
            horizon: u32,
            /// The critic's tail: its weight in the cost, and its pessimism (beta, `plan_score_combine`'s).
            tail_weight: f32 = 1.0,
            pessimism: f32 = 0.0,
            /// Which prefixes of a plan count (`zimrrl.PlanObjective`, this type's head), and the discount its costs
            /// and the critic's values are weighed with - the critic's own, for a plan costed as the critic costs a
            /// future; 1 for a plain sum.
            objective: zrl.PlanObjective = .final,
            discount: f32 = 1.0,
        };

        /// The placed kit the plans roll in, and its options.
        kit: LatentKit(M),
        options: Options,
        /// The candidates' corrections, packed step by step [step][row][action]; each step's cost [horizon][rows]; the
        /// critic's tail (none without a critic) and its heads' values at every depth, [depth][value head][rows] -
        /// written where the objective weighs a depth; the objective's weights, `horizon` on the costs then as many on
        /// the values (`objectiveWeights`); the scores [rows] and their variances [rows].
        candidate_actions_at: u32,
        step_costs_at: u32,
        tail: ?LatentCritic(M).Tail,
        /// The critic's heads - or 1 without a critic, whose values every weight of 0 leaves unread.
        value_heads: u32,
        values_at: u32,
        weights_at: u32,
        scores_at: u32,
        variances_at: u32,
        /// The host's room for the objective's weights before each upload (`writeObjective`), 2 x horizon.
        objective_weights: []f32,

        /// A scorer for `options`' states, candidates and horizon, beside `training_kit` - its world model's and its
        /// policy's shapes and weights, its tracking cost's settings - with `critic`'s heads for the tail when there is
        /// a critic, the candidates' corrections decoded through the synergies at params `synergies_at` (as many as the
        /// actions). Its regions are reserved in `layout` (which must start past everything already placed).
        /// Memory: `arena`.
        pub fn init(
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            training_kit: LatentKit(M),
            critic: ?LatentCritic(M),
            synergies_at: u32,
            options: Options,
        ) !Self {
            const has_policy: bool = training_kit.policy_hidden > 0;
            assertf(has_policy, @src(), "the scorer corrects the training kit's policy: it has none", .{});
            const rows: u32 = options.states * options.candidates;
            const unplaced: LatentKit(M) = try .init(
                training_kit.pipe,
                training_kit.features,
                training_kit.references,
                training_kit.actions,
                training_kit.hidden,
                rows,
                options.horizon,
                training_kit.features,
                training_kit.policy_hidden,
            );
            const activations_base: u32 = layout.reserveActs(unplaced.total);
            const gradients_base: u32 = layout.reserveDacts(unplaced.dtotal);
            var kit: LatentKit(M) = unplaced.placedAt(activations_base, gradients_base);
            // The policy acts as the training kit's does, with no exploration: a candidate is its own exploration.
            kit.action_scale = training_kit.action_scale;
            kit.sigma = 0;
            // The tracking cost's settings are the training kit's: the same barrier, read through the same normaliser.
            kit.barrier = training_kit.barrier;
            kit.barrier_head_column = training_kit.barrier_head_column;
            kit.barrier_up_column = training_kit.barrier_up_column;
            kit.norm_at = training_kit.norm_at;
            // Its change predicted in the training kit's units, as the training kit's own rollouts predict it.
            kit.increments_at = training_kit.increments_at;
            var tail: ?LatentCritic(M).Tail = null;
            if (critic) |plan_critic| {
                tail = try plan_critic.initTail(arena, layout, rows);
            }
            const head_count: u32 = if (critic) |plan_critic| @intCast(plan_critic.heads.len) else 0;
            const value_heads: u32 = @max(head_count, 1);
            // The candidates' corrections: where the search samples them and where the rollout reads them.
            const candidate_actions_at: u32 = layout.reserveActs(rows * options.horizon * kit.actions);
            kit.given_corrections = .{
                .coefficients_at = candidate_actions_at,
                .synergies_at = synergies_at,
                .synergy_count = kit.actions,
            };
            const scorer: Self = .{
                .kit = kit,
                .options = options,
                .candidate_actions_at = candidate_actions_at,
                .step_costs_at = layout.reserveActs(options.horizon * rows),
                .tail = tail,
                .value_heads = value_heads,
                .values_at = layout.reserveActs(options.horizon * value_heads * rows),
                .weights_at = layout.reserveActs(2 * options.horizon),
                .scores_at = layout.reserveActs(rows),
                .variances_at = layout.reserveActs(rows),
                .objective_weights = try arena.alloc(f32, 2 * options.horizon),
            };
            return scorer;
        }

        /// Whether the objective weighs the critic at `depth` (1 .. horizon): every depth for the mean over prefixes,
        /// the last alone for the final objective.
        fn weighsDepth(scorer: Self, depth: u32) bool {
            return scorer.options.objective == .mean_over_depths or depth == scorer.options.horizon;
        }

        /// The objective's weights into `weights` (2 x horizon): first each step cost's, then each depth's critic
        /// value's - `zimrrl.planObjectiveWeights` at the scorer's discount, NEGATED (a cost lowers a score), the
        /// values' times the tail's weight as it is now. Without a critic every value weight is 0.
        pub fn objectiveWeights(scorer: Self, weights: []f32) void {
            const horizon: u32 = scorer.options.horizon;
            const cost_weights: []f32 = weights[0..horizon];
            const value_weights: []f32 = weights[horizon..][0..horizon];
            // The shapes are this function's own: the objective's weights cannot refuse them.
            const options: Options = scorer.options;
            zrl.planObjectiveWeights(f32, options.objective, options.discount, cost_weights, value_weights) catch {
                unreachable;
            };
            const value_scale: f32 = if (scorer.tail != null) -options.tail_weight else 0;
            for (cost_weights) |*weight| {
                weight.* = -weight.*;
            }
            for (value_weights) |*weight| {
                weight.* *= value_scale;
            }
        }

        /// The objective's weights with the tail's weight as it is now (`objectiveWeights`), uploaded where the
        /// scores read them: at the start of every decision, since the critic's trust moves the tail's weight.
        pub fn writeObjective(scorer: Self, pipe: *Pipe) void {
            scorer.objectiveWeights(scorer.objective_weights);
            pipe.uploadAt(.acts, scorer.weights_at, scorer.objective_weights);
        }

        /// The candidates' rows: states x candidates.
        pub fn rowCount(scorer: Self) u32 {
            return scorer.options.states * scorer.options.candidates;
        }

        /// What a search over these candidates is over (`bmpc_kit.SearchShape`): MPPI samples into the candidates'
        /// packed actions and reads their scores.
        pub fn searchShape(scorer: Self) bmpc_kit.SearchShape {
            const shape: bmpc_kit.SearchShape = .{
                .states = scorer.options.states,
                .candidates = scorer.options.candidates,
                .horizon = scorer.options.horizon,
                .action_width = scorer.kit.actions,
                .candidate_actions_at = scorer.candidate_actions_at,
                .scores_at = scorer.scores_at,
            };
            return shape;
        }

        /// THE SCORES (this type's head), once the inputs are staged: the rollout, each step's cost, the critic's
        /// values at the plan's end, and each candidate's score, at `scores_at`.
        pub fn score(scorer: Self, pipe: *Pipe) void {
            const kit: LatentKit(M) = scorer.kit;
            const rows: u32 = scorer.rowCount();
            const horizon: u32 = scorer.options.horizon;
            // The rollout: the policy acting closed loop, each candidate's correction added at each step.
            kit.forward();
            // Each step's cost: where the step led, against the goal there.
            const cost: TrackingCost = kit.trackingCost();
            for (1..horizon + 1) |step_index| {
                const k: u32 = @intCast(step_index);
                const step_costs_at: u32 = scorer.step_costs_at + (k - 1) * rows;
                runTrackingCost(M, pipe, cost, rows, kit.blockZ(k), kit.blockG(k), step_costs_at);
            }
            // The critic's heads at every depth the objective weighs, each depth's values [value head][rows].
            if (scorer.tail) |tail| {
                for (1..horizon + 1) |depth_index| {
                    const depth: u32 = @intCast(depth_index);
                    if (!scorer.weighsDepth(depth)) {
                        continue;
                    }
                    const depth_values_at: u32 = scorer.values_at + (depth - 1) * scorer.value_heads * rows;
                    tail.forwardValues(pipe, kit.blockG(depth), kit.blockZ(depth), depth_values_at);
                }
            }
            // The objective's combination: one world model, the critic's heads, the weights `writeObjective` left.
            pipe.params = .{
                .rows = rows,
                .plan_horizon = horizon,
                .plan_dynamics_heads = 1,
                .plan_value_heads = scorer.value_heads,
                .plan_pessimism = scorer.options.pessimism,
                .x_off = scorer.step_costs_at,
                .v_off = scorer.values_at,
                .u_off = scorer.weights_at,
                .y_off = scorer.scores_at,
                .z_off = scorer.variances_at,
            };
            pipe.run("plan_score_combine", rows);
        }

        /// The inputs staged from the host (this type's head, "what the caller stages") into the host's copy of acts:
        /// `start_states` [states][features], `references` [horizon][states][references], `goals` [horizon][states]
        /// [features] (the goal after each step), `actions` [horizon][rows][actions] - each candidate's corrections,
        /// into the packed candidates.
        pub fn writeInputs(
            scorer: Self,
            host_acts: []f32,
            start_states: []const f32,
            references: []const f32,
            goals: []const f32,
            actions: []const f32,
        ) void {
            const kit: LatentKit(M) = scorer.kit;
            const shape: bmpc_kit.SearchShape = scorer.searchShape();
            const features: usize = kit.features;
            const reference_width: usize = kit.references;
            const action_width: usize = kit.actions;
            const states: usize = scorer.options.states;
            const candidates: usize = scorer.options.candidates;
            const rows: usize = states * candidates;
            const state_column: usize = kit.lead;
            const reference_column: usize = kit.lead + features;
            for (0..scorer.options.horizon) |step| {
                const block_at: usize = kit.blockX(@intCast(step));
                const goals_at: usize = kit.blockG(@intCast(step + 1));
                for (0..rows) |row| {
                    const state: usize = row / candidates;
                    const row_start: usize = block_at + row * kit.width;
                    if (step == 0) {
                        const start_state: []const f32 = start_states[state * features ..][0..features];
                        @memcpy(host_acts[row_start + state_column ..][0..features], start_state);
                    }
                    const reference_start: usize = (step * states + state) * reference_width;
                    const reference: []const f32 = references[reference_start..][0..reference_width];
                    @memcpy(host_acts[row_start + reference_column ..][0..reference_width], reference);
                    const action: []const f32 = actions[(step * rows + row) * action_width ..][0..action_width];
                    const packed_at: usize = shape.candidateActionAt(@intCast(step), @intCast(row));
                    @memcpy(host_acts[packed_at..][0..action_width], action);
                    // The goal after this step, in both places the gather puts it: the wide row's goal columns, where
                    // the policy reads it, and the goal block, where the cost reads it.
                    const goal: []const f32 = goals[(step * states + state) * features ..][0..features];
                    @memcpy(host_acts[row_start..][0..features], goal);
                    @memcpy(host_acts[goals_at + row * features ..][0..features], goal);
                }
            }
            // The objective's weights with the tail's weight as it is now (`objectiveWeights`).
            const horizon_weights: usize = 2 * scorer.options.horizon;
            scorer.objectiveWeights(host_acts[scorer.weights_at..][0..horizon_weights]);
        }
    };
}

/// THE TRACKING PLANNER: MPPI (`bmpc_kit.KitMppi`, EfficientTDMPC's search on the kit) over SuperTrack's own objective
/// (`TrackingScorer`). For each state, a Gaussian over plans - H corrections around the policy - is refined round by
/// round:
///
///     plans     with a flow: several of the flow's own plans, each rolled closed-loop through the world model from
///               a noise of its own (`FlowPlans`) - the flow's several ways back - as the first candidates of every
///               state, left alone by the sampling
///     begin     each state's Gaussian: the last decision's plan shifted one step on (warm), or zero (cold); every
///               spread at its ceiling
///     a round   the other candidates drawn from the Gaussian (`hashed_noise`, the round's seed), every plan scored -
///               rolled through the world model and charged - and the Gaussian refitted to the elites, weighted by
///               their scores (a softmax at the search's temperature)
///     choose    one elite drawn by its weight (`hashed_uniforms`): its first action is the decision, its plan the
///               next decision's warm start
///
/// The search is EfficientTDMPC's, unchanged, seeded as EfficientTDMPC seeds it with its policy's plans; only what
/// scores a plan differs - here, the cost SuperTrack's policy learns from, through SuperTrack's world model, with its
/// critic after the plan's end.
pub fn TrackingPlanner(comptime M: type) type {
    return struct {
        const Self = @This();
        pub const Pipe = compute_host.Compute(M);
        const Mppi = bmpc_kit.KitMppi(M);

        /// The flow's own plans: a world-model kit whose rollout is the flow acting (`FlowActor.actingOnly`, over the
        /// learner's flow - its weights), rows [state][plan], the plans' horizon. Its rollout's actions are the plans.
        pub const FlowPlans = struct {
            kit: LatentKit(M),
            plans_per_state: u32,
        };

        scorer: TrackingScorer(M),
        mppi: Mppi,
        /// The flow's plans, when the planner has a flow (none otherwise: every candidate is the search's own).
        flow_plans: ?FlowPlans,
        /// Each state's inputs, [state][features + 2] in acts: its normalised start features, then its start row in
        /// the reference table and its clip's last row (`plan_gather`).
        state_inputs_at: u32,
        /// The basis the candidates' corrections decode through: the flow's synergies when the planner has a flow, so
        /// a flow's plans and the search's speak the same coefficients; otherwise the planner's OWN, the identity -
        /// reserved here among the parameters, written by the caller (`writeOwnSynergies`). Like the mailbox, it lies
        /// past the saved parameters: it is constant, and written again whenever a learner is built.
        own_synergies_at: ?u32,
        /// Where the learner's stats block starts (`DeviceStats`), or null without one - set by the learner after it
        /// reserves the block; each decision records the planner's gain there (`plan_gain_stats`).
        stats_at: ?u32 = null,

        /// A planner over `scorer_options`' states, candidates and horizon, searching as `search_options` says,
        /// beside `training_kit` and with `critic`'s tail (`TrackingScorer.init`). With the learner's `flow_actor`, the
        /// first `search_options.policy_candidates` candidates of every state are its own plans: the policy rolled
        /// with the flow's correction, each from a noise of its own. Memory: `arena`.
        pub fn init(
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            training_kit: LatentKit(M),
            critic: ?LatentCritic(M),
            flow_actor: ?FlowActor(M),
            scorer_options: TrackingScorer(M).Options,
            search_options: Mppi.Options,
        ) !Self {
            // The corrections' basis: the flow's synergies, or the planner's own identity.
            var own_synergies_at: ?u32 = null;
            var synergies_at: u32 = 0;
            if (flow_actor) |learner_flow_actor| {
                const correction: FlowActor(M).Correction = learner_flow_actor.correction;
                const full_width: bool = correction.synergy_count == training_kit.actions;
                assertf(full_width, @src(), "the planner's corrections are full width; the flow's are {d} of {d}", .{
                    correction.synergy_count,
                    training_kit.actions,
                });
                synergies_at = correction.synergies_at;
            } else {
                synergies_at = layout.reserveParams(training_kit.actions * training_kit.actions);
                own_synergies_at = synergies_at;
            }
            const scorer: TrackingScorer(M) =
                try .init(arena, layout, training_kit, critic, synergies_at, scorer_options);
            const mppi: Mppi = .init(layout, scorer.searchShape(), search_options);
            // The flow's plans are the candidates the search leaves alone - as many of them as it leaves.
            const plans_per_state: u32 = search_options.policy_candidates;
            const has_plans_without_flow: bool = plans_per_state > 0 and flow_actor == null;
            const reason: []const u8 = "policy_candidates are the flow's plans: give the planner a flow";
            assertf(!has_plans_without_flow, @src(), "{s}", .{reason});
            var flow_plans: ?FlowPlans = null;
            if (flow_actor) |learner_flow_actor| {
                if (plans_per_state > 0) {
                    const plan_rows: u32 = scorer_options.states * plans_per_state;
                    const unplaced: LatentKit(M) = try .init(
                        training_kit.pipe,
                        training_kit.features,
                        training_kit.references,
                        training_kit.actions,
                        training_kit.hidden,
                        plan_rows,
                        scorer_options.horizon,
                        training_kit.features,
                        training_kit.policy_hidden,
                    );
                    const activations_base: u32 = layout.reserveActs(unplaced.total);
                    const gradients_base: u32 = layout.reserveDacts(unplaced.dtotal);
                    var plans_kit: LatentKit(M) = unplaced.placedAt(activations_base, gradients_base);
                    // The plans roll the learner's policy - its weights shared, as the world model's are - with the
                    // flow's correction on top; they explore only through the flow's own noise.
                    const plan_steps: u32 = scorer_options.horizon;
                    plans_kit.flow_actor =
                        try FlowActor(M).actingOnly(arena, layout, learner_flow_actor, plan_rows, plan_steps);
                    plans_kit.sigma = 0;
                    plans_kit.increments_at = training_kit.increments_at;
                    flow_plans = .{ .kit = plans_kit, .plans_per_state = plans_per_state };
                }
            }
            const state_input_floats: u32 = scorer_options.states * (training_kit.features + 2);
            const planner: Self = .{
                .scorer = scorer,
                .mppi = mppi,
                .flow_plans = flow_plans,
                .state_inputs_at = layout.reserveActs(state_input_floats),
                .own_synergies_at = own_synergies_at,
            };
            return planner;
        }

        /// Writes the planner's own corrections' basis - the identity - into `params`, the host's copy of the
        /// parameter buffer, when it keeps one (a planner without a flow; with one, the flow's synergies serve).
        pub fn writeOwnSynergies(planner: Self, params: []f32) void {
            const own_synergies_at: u32 = planner.own_synergies_at orelse return;
            const action_width: u32 = planner.scorer.kit.actions;
            const synergies: []f32 = params[own_synergies_at..][0 .. action_width * action_width];
            @memset(synergies, 0);
            for (0..action_width) |action| {
                synergies[action * action_width + action] = 1;
            }
        }

        /// Where state `state`'s inputs go (`state_inputs_at`): its normalised start features, then its start row and
        /// its clip's last row.
        pub fn stateInputsAt(planner: Self, state: u32) u32 {
            const features: u32 = planner.scorer.kit.features;
            return planner.state_inputs_at + state * (features + 2);
        }

        /// Every planner row's inputs gathered on the device (`plan_gather`) - the scorer's candidates and the flow's
        /// plans alike - from each state's inputs (`stateInputsAt`) and the resident reference table at `table_at`,
        /// normalised by the normaliser at `normaliser_at`.
        pub fn gather(
            planner: Self,
            pipe: *Pipe,
            table_at: u32,
            normaliser_at: u32,
        ) void {
            const candidates: u32 = planner.scorer.options.candidates;
            planner.gatherInto(pipe, planner.scorer.kit, candidates, table_at, normaliser_at);
            if (planner.flow_plans) |flow_plans| {
                planner.gatherInto(pipe, flow_plans.kit, flow_plans.plans_per_state, table_at, normaliser_at);
            }
        }

        /// The mailbox's size in floats: the decision's step, then every state's chosen plan, [state][step][action].
        pub fn mailboxFloats(planner: Self) u32 {
            const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
            return 1 + shape.states * shape.horizon * shape.action_width;
        }

        /// Every state's chosen plan, with the decision's step `decision_step`, into the mailbox at `mailbox_at` in
        /// the PARAMETER buffer (`plan_mailbox`) - which the host reads back every frame.
        pub fn writeMailbox(
            planner: Self,
            pipe: *Pipe,
            mailbox_at: u32,
            decision_step: u32,
        ) void {
            const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
            pipe.params = .{
                .rows = shape.states,
                .out_dim = shape.action_width,
                .plan_horizon = shape.horizon,
                .plan_candidates = shape.candidates,
                .x_off = shape.candidate_actions_at,
                .e_off = planner.mppi.chosen_offset,
                .y_off = mailbox_at,
                .plan_decision_step = decision_step,
            };
            pipe.run("plan_mailbox", shape.states * shape.horizon * shape.action_width);
        }

        fn gatherInto(
            planner: Self,
            pipe: *Pipe,
            kit: LatentKit(M),
            rows_per_state: u32,
            table_at: u32,
            normaliser_at: u32,
        ) void {
            pipe.params = .{
                .rows = kit.rows,
                .lat_features = kit.features,
                .lat_references = kit.references,
                .lat_actions = kit.actions,
                .lat_steps = kit.steps,
                .lat_lead = kit.lead,
                .plan_candidates = rows_per_state,
                .table_off = table_at,
                .norm_off = normaliser_at,
                .starts_off = planner.state_inputs_at,
                .blocks_off = kit.x_at,
                .goals_off = kit.g_at,
            };
            pipe.run("plan_gather", kit.rows * (kit.steps + 1) * kit.width);
        }

        /// ONE DECISION for every state (this type's head), its random numbers hashed from `seed`: the chosen
        /// elite's first action at `mppi.targets_offset` (its spread after it), the refined Gaussians kept for the
        /// next decision's warm start. Each state's warm flag (`mppi.warm_flags_offset`) is the caller's: 1 to start
        /// from its last plan - moved forward by `plan_age_steps`, the steps since that plan was decided - 0 to start
        /// cold.
        pub fn decide(planner: Self, pipe: *Pipe, seed: u32, plan_age_steps: u32) void {
            const mppi: Mppi = planner.mppi;
            // The objective as the critic's trust weighs it now - the same for every round of this decision.
            planner.scorer.writeObjective(pipe);
            const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
            const rows: u32 = shape.rowCount();
            // A candidate's drawn numbers: one per knot and action (`KitMppi.knotCount`).
            const plan_floats: u32 = mppi.knotCount() * shape.action_width;
            // The flow's plans first, from their own seed (a round number past the search's).
            if (planner.flow_plans) |flow_plans| {
                planner.rollFlowPlans(pipe, flow_plans, M.latStepSeed(seed, mppi.options.rounds + 1));
            }
            mppi.begin(pipe, plan_age_steps);
            for (0..mppi.options.rounds) |round_index| {
                const round_number: u32 = @intCast(round_index);
                // The round's sampling noise: a standard normal per candidate value, from the round's own seed.
                pipe.params = .{
                    .rows = rows,
                    .count = plan_floats,
                    .y_off = mppi.noise_offset + round_number * mppi.round_noise_floats,
                    .stride = plan_floats,
                    .col = 0,
                    .lat_sigma = 1.0,
                    .lat_seed = M.latStepSeed(seed, round_number),
                };
                pipe.run("hashed_noise", rows * plan_floats);
                mppi.sample(pipe, round_number);
                planner.scorer.score(pipe);
                mppi.refit(pipe);
            }
            // The choice among each state's elites, by their weights, from a uniform draw per state.
            pipe.params = .{
                .rows = shape.states,
                .y_off = mppi.choice_draws_offset,
                .lat_seed = M.latStepSeed(seed, mppi.options.rounds),
            };
            pipe.run("hashed_uniforms", shape.states);
            mppi.choose(pipe);
            // For the log: how much the chosen plans beat the actor's own proposals, and how often the search chose.
            const shape_now: bmpc_kit.SearchShape = planner.scorer.searchShape();
            recordDeviceStat(M, pipe, planner.stats_at, "planner_gain", "plan_gain_stats", .{
                .rows = shape_now.states,
                .plan_candidates = shape_now.candidates,
                .plan_policy_plans = mppi.options.policy_candidates,
                .x_off = shape_now.scores_at,
                .e_off = mppi.chosen_offset,
            });
            mppi.takeTargets(pipe);
        }

        /// The flow's plans rolled - the flow acting closed-loop through the world model from each plan's own noise
        /// (`plan_seed`) - and each step's plan actions copied into every state's first candidates for that step.
        fn rollFlowPlans(
            planner: Self,
            pipe: *Pipe,
            flow_plans: FlowPlans,
            plan_seed: u32,
        ) void {
            var plans_kit: LatentKit(M) = flow_plans.kit;
            plans_kit.seed = plan_seed;
            plans_kit.forward();
            const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
            const plans_per_state: u32 = flow_plans.plans_per_state;
            const action_width: u32 = shape.action_width;
            const plan_rows: u32 = plans_kit.rows;
            // A flow plan is the corrections the flow chose - kept packed by the rollout, [row][synergy], one block per
            // step (`FlowActor.coefficients_at`) - in the basis the scorer decodes through, so the scorer re-rolls each
            // plan exactly as the flow made it.
            const plans_coefficients_at: u32 = plans_kit.flow_actor.?.coefficients_at;
            for (0..shape.horizon) |step_index| {
                const k: u32 = @intCast(step_index);
                const step_plan_actions_at: u32 = plans_coefficients_at + k * plan_rows * action_width;
                for (0..shape.states) |state_index| {
                    const state: u32 = @intCast(state_index);
                    const state_plans_at: u32 = step_plan_actions_at + state * plans_per_state * action_width;
                    const first_candidate_at: u32 = shape.candidateActionAt(k, state * shape.candidates);
                    const state_plans: kit_mlp.RowColumns = .packedRows(state_plans_at, action_width);
                    const state_candidates: kit_mlp.RowColumns = .packedRows(first_candidate_at, action_width);
                    kit_mlp.copyColumns(M, pipe, plans_per_state, action_width, state_plans, state_candidates);
                }
            }
        }

        /// The planner's inputs staged from the host into the host's copy of acts - the scorer's (`TrackingScorer.
        /// writeInputs`, the candidates' actions left to the search) and, with a flow, its plans' rollout's: each
        /// plan's start state, the reference at each step, and the goal it acts toward at each step - the goal after
        /// that step, in its wide row's goal columns, as SuperTrack's own rollouts have it. `start_states`
        /// [states][features], `references` [horizon][states][references], `goals` [horizon][states][features].
        pub fn writeInputs(
            planner: Self,
            arena: Allocator,
            host_acts: []f32,
            start_states: []const f32,
            references: []const f32,
            goals: []const f32,
        ) !void {
            const scorer: TrackingScorer(M) = planner.scorer;
            const horizon: usize = scorer.options.horizon;
            const no_actions: []f32 = try arena.alloc(f32, horizon * scorer.rowCount() * scorer.kit.actions);
            @memset(no_actions, 0);
            scorer.writeInputs(host_acts, start_states, references, goals, no_actions);
            const flow_plans: FlowPlans = planner.flow_plans orelse return;
            const kit: LatentKit(M) = flow_plans.kit;
            const features: usize = kit.features;
            const reference_width: usize = kit.references;
            const states: usize = scorer.options.states;
            const plans_per_state: usize = flow_plans.plans_per_state;
            for (0..horizon) |step| {
                const block_at: usize = kit.blockX(@intCast(step));
                for (0..states * plans_per_state) |row| {
                    const state: usize = row / plans_per_state;
                    const row_start: usize = block_at + row * kit.width;
                    const goal: []const f32 = goals[(step * states + state) * features ..][0..features];
                    @memcpy(host_acts[row_start..][0..features], goal);
                    if (step == 0) {
                        const start_state: []const f32 = start_states[state * features ..][0..features];
                        @memcpy(host_acts[row_start + kit.lead ..][0..features], start_state);
                    }
                    const reference_start: usize = (step * states + state) * reference_width;
                    const reference: []const f32 = references[reference_start..][0..reference_width];
                    @memcpy(host_acts[row_start + kit.lead + features ..][0..reference_width], reference);
                }
            }
        }
    };
}

/// The training data, RESIDENT in the kit's activation buffer: the reference TABLES, uploaded once per
/// clip, and the replay of FEATURES, appended once per simulation step. What the CPU would otherwise
/// recompute for every record of every window, every training step - forward kinematics, the feature
/// map, the reference's too - is computed once, when a state is new, and never again.
///
///   * **A table row per clip frame:** the reference's RAW features at that frame (the policy's goal)
///     and its encoded targets (the world model's reference input). Raw, not normalised: the gather
///     normalises as it reads, so the normaliser can change without rewriting anything.
/// WHY EVERYTHING SHARES ONE BUFFER: a compute stage is guaranteed only eight storage buffers on
/// WebGPU, and the networks already spend most of them. So the tables and the ring live inside the
/// activations buffer, at offsets past the kit's blocks, rather than in buffers of their own. That is
/// a WEB limit, not a physical one - a native backend allows far more, and this packing could relax
/// there. Nothing above this line depends on the packing: regions are found through named offsets.
///
///   * **A record per character per step:** its raw features, the action it took, and the table row
///     of the frame it was at - `features + actions + 1` floats. The ring has the fleet's replay's
///     capacity, so it holds exactly the records the CPU replay can still sample windows from; the
///     CPU keeps sampling (it knows where episodes break), and only the chosen starts go up.
///   * **Step-major:** all characters' records for one step sit side by side. Every character
///     appends at every step, in lockstep, so a step is ONE upload - not one per character.
///
/// The whole activation buffer, then, from the start:
///
///     [ rollout blocks (LatentKit) | tables | ring | normaliser | window starts | ... free ]
///       0                          ^ table_at      ^ ring_at     ^ norm_at        ^ starts_at
///
/// Nothing here is checked by the GPU - it would happily read a ring slot nobody wrote, or gather a
/// window over a step that was never appended - so the host keeps the books: which replay indices
/// the ring has actually received (`first_appended` .. `appended`), checked on every append (no gaps)
/// and on every gather (every window inside what the ring still holds).
pub fn Resident(comptime M: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        pipe: *compute_host.Compute(M),
        features: u32,
        references: u32,
        actions: u32,
        envs: u32,
        capacity: u32,
        /// Floats per ring record, and per table row.
        record: u32,
        row: u32,
        /// Where the tables start, and where each clip's first frame sits among the rows.
        table_at: u32,
        clip_rows: []u32,
        /// Where the ring starts; then the normaliser (means, then spreads); then the window starts -
        /// `slots` regions of `rows` windows (two floats each), one per update of a frame; then the end.
        ring_at: u32,
        norm_at: u32,
        starts_at: u32,
        rows: u32,
        /// How many updates of one frame can have their starts staged at once.
        slots: u32,
        end: u32,
        /// The replay indices the ring has received: the first ever, and the latest. Null until the
        /// first append. The ring holds the last `capacity` of them.
        first_appended: ?u64 = null,
        appended: ?u64 = null,
        // Host scratch, for computing features once.
        state: track.State,
        data: rbt.Data,
        staging: []f32,

        /// Lay the tables and the ring out from `start` in the activation buffer (after whatever
        /// else lives there, the rollout's blocks for one) - or refuse, by name, if they do not fit.
        pub fn init(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            fleet: *const track.Fleet,
            start: u32,
            rows: u32,
            slots: u32,
        ) !Self {
            const m: *const rbt.Model = fleet.m;
            const features: u32 = @intCast(track.localSize(m.nbody));
            const references: u32 = @intCast(track.targetSize(m));
            const actions: u32 = @intCast(track.actionSize(m));
            const envs: u32 = @intCast(fleet.options.envs);
            const capacity: u32 = @intCast(fleet.replay.capacity);
            const clip_rows: []u32 = try gpa.alloc(u32, fleet.clips.len);
            errdefer gpa.free(clip_rows);
            var table_rows: u32 = 0;
            for (fleet.clips, clip_rows) |clip, *first| {
                first.* = table_rows;
                table_rows += @intCast(clip.frame_count);
            }
            // Both shapes come from the kernel module, not from arithmetic repeated here: the gather
            // reads records and table rows with the same functions, and a future kernel writing the
            // records will too.
            const row: u32 = M.latTableWidth(features, references);
            const record: u32 = M.latRecordWidth(features, actions);
            const ring_at: u32 = start + table_rows * row;
            const norm_at: u32 = ring_at + capacity * envs * record;
            const starts_at: u32 = norm_at + 2 * features;
            const end: u32 = starts_at + slots * 2 * rows;
            // The tables and the ring after the kit's own activations.
            if (end > floatsIn(M, "acts")) {
                return error.KitActivationsTooSmall;
            }
            var data: rbt.Data = try .init(gpa, m);
            errdefer data.deinit();
            var state: track.State = try .init(gpa, m.nbody);
            errdefer state.deinit(gpa);
            return .{
                .gpa = gpa,
                .pipe = pipe,
                .features = features,
                .references = references,
                .actions = actions,
                .envs = envs,
                .capacity = capacity,
                .record = record,
                .row = row,
                .table_at = start,
                .clip_rows = clip_rows,
                .ring_at = ring_at,
                .norm_at = norm_at,
                .starts_at = starts_at,
                .rows = rows,
                .slots = slots,
                .end = end,
                .state = state,
                .data = data,
                .staging = try gpa.alloc(f32, @max(table_rows * row, @max(envs * record, 2 * rows))),
            };
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.staging);
            self.state.deinit(self.gpa);
            self.data.deinit();
            self.gpa.free(self.clip_rows);
        }

        /// Where a clip frame's table row starts.
        pub fn rowAt(self: Self, clip: usize, frame: usize) u32 {
            return self.table_at + (self.clip_rows[clip] + @as(u32, @intCast(frame))) * self.row;
        }

        /// Where a character's record for replay index `index` starts: step-major, so the index
        /// picks a block of `envs` records and the character one record within it.
        pub fn recordAt(self: Self, env: usize, index: u64) u32 {
            const slot: u32 = @intCast(index % self.capacity);
            return self.ring_at + (slot * self.envs + @as(u32, @intCast(env))) * self.record;
        }

        /// Every clip's table, computed and uploaded once: per frame, the reference's raw features
        /// and its encoded targets.
        pub fn uploadTables(self: *Self, fleet: *track.Fleet) void {
            const m: *const rbt.Model = fleet.m;
            var at: usize = 0;
            for (fleet.clips) |clip| {
                const root_len: usize = clip.nq - m.nq;
                for (0..clip.frame_count) |frame| {
                    const out: []f32 = self.staging[at..][0..self.row];
                    fleet.referenceStateInto(clip, @intCast(frame), &self.data, &self.state);
                    track.local(self.state, fleet.root, out[0..self.features]);
                    track.encodeTargets(m, clip.pose(frame)[root_len..], out[self.features..]);
                    at += self.row;
                }
            }
            self.pipe.uploadAt(.acts, self.table_at, self.staging[0..at]);
        }

        /// The normaliser the gather applies, from a CPU `Normalizer`'s means and spreads.
        pub fn uploadNormalizer(self: *Self, norm: latent.Normalizer) void {
            self.pipe.uploadAt(.acts, self.norm_at, norm.mean);
            self.pipe.uploadAt(.acts, self.norm_at + self.features, norm.spread);
        }

        /// A batch of windows into `kit`'s blocks - its first wide row and its targets filled, and
        /// every wide row's reference and action - assembled on the GPU from the ring and tables.
        /// `starts` holds each window's character and first replay index (windows the CPU replay
        /// sampled, so none crosses an episode's end); only they travel, two floats a window.
        ///
        /// ONE START REGION: two gathers in the same frame would both upload their starts to the same
        /// place, and WebGPU lands every upload of a frame before any of its work runs - so both
        /// dispatches would see the second batch's starts. One gather per frame, or give this a
        /// region per step (the training driver's job, when it runs several steps a frame).
        pub fn stageStarts(
            self: *Self,
            starts: []const Start,
            slot: u32,
            steps: u32,
        ) void {
            assertf(slot < self.slots, @src(), "stageStarts: slot {d} of {d}", .{ slot, self.slots });
            // A FULL batch: a slot holds `rows` windows, and a partial staging would leave the rest of
            // them as they were - the previous update's windows, gathered again as if they were this
            // update's.
            assertf(starts.len == self.rows, @src(), "stageStarts: {d} starts, the slot holds {d}", .{
                starts.len,
                self.rows,
            });
            // Every window must lie inside what the ring has received AND still holds: from the later
            // of its first append and `capacity` behind its latest, through its latest.
            assertf(self.appended != null, @src(), "stageStarts: the ring has received nothing yet", .{});
            const latest: u64 = self.appended.?;
            const oldest: u64 = @max(self.first_appended.?, (latest + 1) -| self.capacity);
            for (starts, 0..) |start, i| {
                // The window's LAST record (its final target) must be in the ring as well.
                const inside: bool = start.index >= oldest and start.index + steps <= latest;
                assertf(inside, @src(), "stageStarts: window at {d} is outside the ring's {d}..{d}", .{
                    start.index,
                    oldest,
                    latest,
                });
                self.staging[2 * i] = float(start.env);
                self.staging[2 * i + 1] = float(@as(u32, @intCast(start.index % self.capacity)));
            }
            // Staging is shared with the appends and the tables. Safe: an upload copies its data when
            // it is made (WebGPU's writeBuffer), so the buffer is free again the moment it returns.
            self.pipe.uploadAt(.acts, self.startsAt(slot), self.staging[0 .. 2 * starts.len]);
        }

        /// The steps the replay holds, the oldest and the newest, both inclusive - what `held` answers.
        pub const HeldSteps = struct { first: u64, last: u64 };

        /// The replay indices the ring actually carries right now: from the later of its first append
        /// and `capacity` behind its latest, through its latest. Null while it has received nothing.
        ///
        /// Worth asking before sampling windows, because the CPU's replay is NOT the ring: the replay
        /// may hold steps taken before the learner existed (a warm-up the ring never saw), and it may
        /// hold more of them than the ring has room for.
        pub fn held(self: Self) ?HeldSteps {
            const latest: u64 = self.appended orelse return null;
            const oldest: u64 = @max(self.first_appended.?, (latest + 1) -| self.capacity);
            return .{ .first = oldest, .last = latest };
        }

        /// Where a slot's window starts live.
        fn startsAt(self: Self, slot: u32) u32 {
            return self.starts_at + slot * 2 * self.rows;
        }

        /// A batch of windows into `kit`'s blocks - its first wide row and its targets filled, its rows'
        /// goals, references and recorded actions - assembled on the GPU from the ring and the tables,
        /// for the windows staged in `slot`.
        ///
        /// WHY A SLOT PER UPDATE: in a frame, every upload lands before any of the frame's work runs,
        /// while dispatches run in order. So two updates may share the rollout's blocks - each one's
        /// dispatches read them before the next gather overwrites them - but NOT one place for their
        /// window starts: the second upload would overwrite the first before either gather ran, and both
        /// updates would train on the same windows.
        pub fn gather(self: *Self, kit: anytype, slot: u32) void {
            assertf(slot < self.slots, @src(), "gather: slot {d} of {d}", .{ slot, self.slots });
            const fits: bool = kit.rows <= self.rows;
            assertf(fits, @src(), "gather: {d} rows, room for {d}", .{ kit.rows, self.rows });
            // The kit's blocks are written by this gather; the tables and ring are read by it. They
            // must not overlap, or the gather would overwrite its own sources mid-dispatch.
            const apart: bool = kit.total <= self.table_at;
            assertf(apart, @src(), "gather: the kit's blocks end at {d}, past the tables at {d}", .{
                kit.total,
                self.table_at,
            });
            // A goal IS a feature vector, so the lead is either nothing or exactly the features.
            const lead_ok: bool = kit.lead == 0 or kit.lead == self.features;
            assertf(lead_ok, @src(), "gather: a lead of {d} columns - it must be 0 or {d}", .{
                kit.lead,
                self.features,
            });
            self.pipe.params = .{
                .rows = kit.rows,
                .lat_features = self.features,
                .lat_references = self.references,
                .lat_actions = self.actions,
                .lat_steps = kit.steps,
                .lat_envs = self.envs,
                .lat_capacity = self.capacity,
                .ring_off = self.ring_at,
                .table_off = self.table_at,
                .norm_off = self.norm_at,
                .starts_off = self.startsAt(slot),
                .blocks_off = kit.x_at,
                .targets_off = kit.t_at,
                .lat_lead = kit.lead,
                .goals_off = kit.g_at,
            };
            self.pipe.run("lat_gather", kit.rows * (kit.steps + 1) * kit.width);
        }

        /// The step the fleet just took, into the ring - one upload for every character. Call it
        /// after every `Fleet.step`: the replay's newest record is the state that step started from. The step's
        /// records built where the characters are (`buildStepRecords`), then placed (`uploadStep`): an actor builds
        /// them on its own thread or worker, and the learner places what it is given.
        pub fn appendLatest(self: *Self, fleet: *track.Fleet) void {
            const index: u64 = fleet.replay.written[0] - 1;
            const records: []f32 = self.staging[0 .. self.envs * self.record];
            const features: u32 = self.features;
            const actions: u32 = self.actions;
            buildStepRecords(fleet, index, features, actions, self.clip_rows, &self.data, &self.state, records);
            self.uploadStep(index, records);
        }

        /// A step's records - [character][record], every character of `fleet` - built from its replay at `index`:
        /// each character's state that step started from, in its root's frame (`track.local`); the action it took;
        /// and the row its reference frame has in the tables (`clip_rows`, each clip's first row). Nothing of the
        /// device: `data` and `state` are scratch, so an actor builds its characters' records wherever it runs.
        pub fn buildStepRecords(
            fleet: *track.Fleet,
            index: u64,
            features: u32,
            actions: u32,
            clip_rows: []const u32,
            data: *rbt.Data,
            state: *track.State,
            records: []f32,
        ) void {
            const record: u32 = M.latRecordWidth(features, actions);
            for (0..fleet.options.envs) |env| {
                // Lockstep: every character appends every step, which is what makes a step one
                // contiguous upload.
                const lockstep: bool = fleet.replay.written[env] - 1 == index;
                assertf(lockstep, @src(), "buildStepRecords: character {d} at {d}, the step {d}", .{
                    env,
                    fleet.replay.written[env] - 1,
                    index,
                });
                const out: []f32 = records[env * record ..][0..record];
                fleet.stateAt(env, index, data, state);
                track.local(state.*, fleet.root, out[0..features]);
                @memcpy(out[M.latRecordAction(features)..][0..actions], fleet.replay.actionAt(env, index));
                const clip: usize = fleet.replay.clipAt(env, index);
                const last_frame: usize = fleet.clips[clip].frame_count - 1;
                const frame: usize = @min(@as(usize, fleet.replay.frameAt(env, index)), last_frame);
                out[M.latRecordTableRow(features, actions)] = float(clip_rows[clip] + @as(u32, @intCast(frame)));
            }
        }

        /// A step's records, built by `buildStepRecords`, into the ring at `index` - one upload for every character -
        /// right after the step before it.
        pub fn uploadStep(self: *Self, index: u64, records: []const f32) void {
            // No gaps: a step the ring missed would still be sampled by the CPU replay, and the gather
            // would read whatever that slot held before - wrong data, with no error anywhere.
            if (self.appended) |previous| {
                assertf(index == previous + 1, @src(), "uploadStep: index {d} after {d} - a step was not placed", .{
                    index,
                    previous,
                });
            } else {
                self.first_appended = index;
            }
            self.appended = index;
            self.pipe.uploadAt(.acts, self.recordAt(0, index), records);
        }
    };
}
