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
const assertUnreachable = zm.assertUnreachable;
const Random = std.Random;
const zrl = @import("zrl");
const Tensor = zn.Tensor(f32);
const vec = zm.vec;
const normalizeQuat = zm.normalizeQuat;
const inf = zm.inf;
const isFinite = zm.isFinite;
const FieldEnum = std.meta.FieldEnum;
const wgpu = @import("wgpu.zig");

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

/// THE ROOT's DRIFT AT ONE STEP, charged in the per-step cost (`zn_mlp.lat_tracking_cost`): where each row's imagined
/// root is at the step ([row][pose]), where the reference's root is at the step's own frame ([row][pose]), and the
/// cost's two weights (`LatentKit.ImaginedRoot`) - what the policy's loss charges the same rolled state.
pub const RootStepCost = struct {
    roots_at: u32,
    reference_roots_at: u32,
    position_weight: f32,
    rotation_weight: f32,
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
    /// The root's drift at the step, with a root imagined and its cost weighed (`RootStepCost`): none by default.
    root: ?RootStepCost = null,
};

/// SUPERTRACK'S PER-STEP COST of `rows` states against their goals - the distance from the goal plus the failure
/// barrier (`zn_mlp.lat_tracking_cost`), and with the root's step the root's drift - into acts at `costs_at` [rows],
/// the states and goals packed [rows][features] at `states_at` and `goals_at`. The one cost the critic's targets, the
/// planner's scores and teacher 3's advantages all charge - the cost the policy's loss charges a rolled step - written
/// once, so a change to it reaches them all.
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
    if (cost.root) |root| {
        pipe.params.lat_roots_off = root.roots_at;
        pipe.params.lat_goal_roots_off = root.reference_roots_at;
        pipe.params.lat_root_position_weight = root.position_weight;
        pipe.params.lat_root_rotation_weight = root.rotation_weight;
    }
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
    /// gamma per DECISION - per step of the fleet's clock (`robot_track.Fleet.Options.decide_every`), as every step
    /// the critic sees is one: 1 - 1/90 is a horizon of a second and a half at 60 decisions a second - about how long
    /// a fall and what follows it take - and the same second and a half at 30 a second is 1 - 1/45.
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
    /// THE IMAGINED FIT (`LatentCritic.updateImagined`), SuperTrack's critic only: after each policy update the critic
    /// is also fitted to lambda-returns along the policy's own imagined rollout - the states where the policy reads it,
    /// under the policy it judges - its two-hot loss weighted by this share, the real fit's weight being 1. 0: no
    /// imagined fit.
    imagined_share: f32 = 0,
    /// Lambda per decision for those returns (`value_lambda_combine`): 0.92 is 0.4 s at 30 decisions a second,
    /// SuperMimic's 0.95 at 50 in seconds.
    imagined_lambda: f32 = 0.92,
    /// THE REAL FIT's LAMBDA (`LatentCritic.computeTargets`): the real targets are lambda-returns over each recorded
    /// window's own costs, the target heads read at the recorded states - no model in them. At 0 they are the
    /// one-step temporal differences, computed exactly as before; above it, what a recorded fall cost reaches the
    /// states before it in one update instead of a window's length of them. Modest, since the records are the
    /// acting's - its noise and the planners' actions in them - and a multi-step return without a correction leans
    /// toward the behaviour that recorded it: 0.5 is a trace that halves each decision.
    real_lambda: f32 = 0,
};

/// A FEATURE's KIND AS THE WORLD MODEL's LOSS IS LOGGED BY IT (`zn_mlp.stat_world_loss_in_units`, `DeviceStats`'s
/// `world_loss_positions` to `world_loss_up`): robot.zig's kinds in their order, 0 to 5. The switch names every kind,
/// so a kind added to robot.zig fails to compile here until it has a number and a field.
pub fn worldLossKind(kind: rbt.LocalFeatureKind) u32 {
    return switch (kind) {
        .position => 0,
        .rotation_axis => 1,
        .velocity => 2,
        .angular_velocity => 3,
        .height => 4,
        .up => 5,
    };
}

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
    /// THE WORLD MODEL's LOSS IN ITS OWN UNITS on the latest one-step update, XMimic's
    /// (`LatentKit.recordWorldModelLoss`, `zn_mlp.stat_world_loss_in_units`): each feature's error weighed by its loss
    /// weight - 1 / its change's spread squared - so a number counts in units of how much that feature changes in a
    /// step. The window's mean step, then its last step's (step 8 at XMimic's window, where the open-loop rollout has
    /// drifted furthest), then the mean step over each kind of feature's own numbers, in robot.zig's `LocalFeatureKind`
    /// order. A model predicting no change scores about 1 at a window's first step. Eight side by side, as the kernel
    /// writes them.
    world_loss: f32 = 0,
    world_loss_last_step: f32 = 0,
    world_loss_positions: f32 = 0,
    world_loss_rotation_axes: f32 = 0,
    world_loss_velocities: f32 = 0,
    world_loss_angular_velocities: f32 = 0,
    world_loss_heights: f32 = 0,
    world_loss_up: f32 = 0,
    /// THE WORLD MODEL's GRADIENT OVER THE ROUND (`zn_mlp.stat_gradient_tally`, after each step of its clipped
    /// optimiser): the round's world updates so far, the share of them its bound clipped, and the gradient's length
    /// before the clip - its mean and its most over them. With XMimic's bound of 1 in the loss's own units, a share
    /// near 1 says the bound sets every step's length. Four side by side, as the kernel writes them.
    world_updates_in_round: f32 = 0,
    world_gradient_clipped_share: f32 = 0,
    world_gradient_norm_mean: f32 = 0,
    world_gradient_norm_most: f32 = 0,
    /// The policy: its tracking term on the latest update - the mean squared difference between the states its
    /// rollout reaches through the world model and the reference's goals, per number.
    policy_tracking_loss: f32 = 0,
    /// The policy on its latest update from labels (`LatentKit.policyLabelTrainStep`): the mean squared distance
    /// between the action it would give and the label, per number, unweighted - in action units squared.
    policy_label_loss: f32 = 0,
    /// THE WORLD MODEL MEASURED FOR ITS GATE, on its latest measurement (`LatentKit.recordWorldModelGate`): windows of
    /// planners' lookaheads it has not trained on, each from its lookahead's start, in pairs - two candidates of one
    /// replan, one state and two actions. Its error rolled open loop over the windows, per number, beside the error of
    /// a model that predicts no change on the same windows - both in the loss's own units when the learner weighs its
    /// features (`LatentKit.loss_weights_at`), as `world_loss` is; and its answer to an action against the physics',
    /// the pairs' changes pooled (`stat_pair_response`), after the first decision and at the windows' last: the
    /// cosine, then the ratio of the lengths - each pair of numbers side by side, as the kernel writes them.
    gate_world_error: f32 = 0,
    gate_no_change_error: f32 = 0,
    gate_first_response_cosine: f32 = 0,
    gate_first_response_ratio: f32 = 0,
    gate_last_response_cosine: f32 = 0,
    gate_last_response_ratio: f32 = 0,
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
    /// THE WORLD MODEL's SKIP HEAD on its latest update on a schedule (`WorldHeads`, `LatentKit.recordWorldModelLoss`):
    /// the mean squared difference between the states its steps reach and the recorded ones, per number - beside the
    /// one-step loss (`world_model_loss`), which a skip head's batches leave as the last one-step batch set it.
    skip_head_loss: f32 = 0,
    /// THE SKIP HEAD's CONSISTENCY, on its latest consistency update (`Resident.trainSkipConsistency`), each a mean
    /// squared difference per number over a skip from a recorded state under the recorded actions' mean, held: the
    /// skip head's prediction against the averaged one-step head chained over the skip (its loss); the skip head's
    /// against the state recorded at the skip's end; and the chain's against that state. The last two side by side say
    /// whether one jump beats the one-step head chained - and how much holding the mean action costs both.
    skip_consistency_loss: f32 = 0,
    skip_head_error: f32 = 0,
    chained_one_step_error: f32 = 0,
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
    /// THE ROOT's DRIFT in the policy's rollout, with the root imagined (`LatentKit.recordRootDrift`): how far the
    /// imagined root is from the reference's at every rolled state - the distance in metres, and the angle between
    /// their rotations in radians, the judgement's two root measures - each its mean and standard deviation over the
    /// window's decisions and rows. What the root's cost charges; the judgement ends an episode at 0.6 m and 1.5 rad.
    policy_root_drift: f32 = 0,
    policy_root_drift_deviation: f32 = 0,
    policy_root_turn: f32 = 0,
    policy_root_turn_deviation: f32 = 0,
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
    /// THE STATISTICS' CHUNKS' SUMS (`kit_mlp.runStatistic`), straight after the block, outside the range the host
    /// reads back: room for 6,144 chunks of a statistic of one sum, 2,048 of three, 768 of the world model's eight - at
    /// chunks of 1,024 terms, statistics of 6 million terms (of 786,432 for the eight), and longer chunks past that:
    /// XMimic's batch of 2,048 windows of 8 steps of 387 numbers is 768 chunks of 8,256.
    pub const partials_floats: u32 = 2048 * 3;
    /// What a learner reserves for a block: the block, then its chunks' sums.
    pub const reserved_floats: u32 = floats + partials_floats;

    /// Where the chunks' sums of the block at `block_at` lie.
    pub fn partialsAfter(block_at: u32) kit_mlp.StatisticPartials {
        const partials: kit_mlp.StatisticPartials = .{ .at = block_at + floats, .floats = partials_floats };
        return partials;
    }

    // The numbers one statistic writes lie side by side, in its order: a response's cosine and length ratio
    // (`zn_mlp.stat_pair_response`), the world model's loss in its own units (`stat_world_loss_in_units`), its
    // gradient's tally (`stat_gradient_tally`).
    comptime {
        const side_by_side = [_][]const []const u8{
            &.{ "gate_first_response_cosine", "gate_first_response_ratio" },
            &.{ "gate_last_response_cosine", "gate_last_response_ratio" },
            &.{
                "world_loss",
                "world_loss_last_step",
                "world_loss_positions",
                "world_loss_rotation_axes",
                "world_loss_velocities",
                "world_loss_angular_velocities",
                "world_loss_heights",
                "world_loss_up",
            },
            &.{
                "world_updates_in_round",
                "world_gradient_clipped_share",
                "world_gradient_norm_mean",
                "world_gradient_norm_most",
            },
        };
        for (side_by_side) |run| {
            for (run[0 .. run.len - 1], run[1..]) |earlier, later| {
                const after: bool = @offsetOf(DeviceStats, later) == @offsetOf(DeviceStats, earlier) + @sizeOf(f32);
                if (!after) {
                    @compileError("DeviceStats." ++ later ++ " must follow " ++ earlier);
                }
            }
        }
        // The whole window, its last step, then one a kind - the kinds numbered by `worldLossKind`, the last `up`.
        const world_loss_numbers: u32 = slot("world_loss_up") - slot("world_loss") + 1;
        const kinds_numbered: u32 = worldLossKind(.up) + 1;
        if (world_loss_numbers != 2 + kinds_numbered) {
            @compileError(
                "DeviceStats: the world model's loss in its own units - the window, its last step, a kind each",
            );
        }
    }

    /// Where `field` sits in the block, in floats from its start.
    pub fn slot(comptime field: []const u8) u32 {
        return @offsetOf(DeviceStats, field) / @sizeOf(f32);
    }
};

/// THE TABLE OF FEATURE KINDS the world model's loss reads (`LatentKit.feature_kinds_at`): each of `local_layout`'s
/// features' kind (`worldLossKind`), as a float - small integers, exact - into `out_kinds`, one a feature.
pub fn writeFeatureKinds(local_layout: rbt.LocalLayout, out_kinds: []f32) void {
    for (out_kinds, 0..) |*out_kind, feature| {
        const kind: rbt.LocalFeatureKind = local_layout.kindOf(@intCast(feature));
        out_kind.* = float(worldLossKind(kind));
    }
}

/// A statistic into a stats block's `field` (`DeviceStats`): `kernel` with `inputs` (`kit_mlp.runStatistic`: in its
/// two passes when the kernels sum it in chunks, the chunks' sums after the block), writing at the place set here
/// (`stat_off`, where every statistic writes) - and nothing when there is no block (`stats_at` null). The kit's, the
/// critic's and the planner's statistics alike.
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
    kit_mlp.runStatistic(M, pipe, kernel, stat_params, DeviceStats.partialsAfter(block_at));
}

/// WHETHER `lead` COLUMNS ARE A GOAL for `features` of state: the reference's features alone, or followed by the root
/// target's slots (`rbt.root_target_size`) - where the reference's root is, seen from the character's. A policy reads
/// [goal | state]; a learner's goal has the slots always, filled or left zero (robot_track_resident's
/// `Options.root_target`).
pub fn isGoalWidth(lead: u32, features: u32) bool {
    const root_target_size: u32 = @intCast(rbt.root_target_size);
    return lead == features or lead == features + root_target_size;
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
/// or, with `CriticOptions.real_lambda` above 0, LAMBDA-RETURNS over the window's recorded steps: the target heads
/// read at each transition's own state too, and the returns walked back from the window's last transition
/// (`combineLambdaReturns`) - the last its one-step target, each earlier one leaning on the recorded path after it.
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
            /// The steps of a window the critic fits on - a resident learner's world model's windows - and of the
            /// policy rollout's first steps that its imagined fit reads.
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
        /// THE IMAGINED FIT's states (`reserveImagined`), when it has them: the imagined states after each step,
        /// [steps][rows][features] from step 1 as the real ones are.
        imagined_states_at: ?u32 = null,
        /// What every lambda-return needs, real or imagined (`combineLambdaReturns`): the target values at each
        /// transition's own state [heads][transitions], and the running advantage [rows].
        own_values_at: u32,
        running_at: u32,
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
                .own_values_at = layout.reserveActs(options.heads * transitions),
                .running_at = layout.reserveActs(source.rows),
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

        /// THE FIRST HALF OF EVERY TARGET: from the states after each step at `states_at` - the recorded ones
        /// (`computeTargets`) or the imagined ones (`computeImaginedTargets`), [steps][rows][features] from step 1 -
        /// and the goals beside them, each transition's input rows, its cost where it led, and the target heads' values
        /// there.
        fn prepareTransitions(critic: Self, pipe: *Pipe, states_at: u32) void {
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
            const next_states_at: u32 = states_at + step_block_floats;
            const placement_sources = [_]u32{ source.goals_at, states_at, next_goals_at, next_states_at };
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
        }

        /// The TD targets of the gathered window batch (this type's head): every real transition's inputs, its next
        /// inputs, its cost and its target, in acts.
        pub fn computeTargets(critic: Self, pipe: *Pipe) void {
            critic.prepareTransitions(pipe, critic.source.states_at);
            const real_lambda: f32 = critic.options.real_lambda;
            if (real_lambda > 0) {
                critic.combineLambdaReturns(pipe, real_lambda);
                return;
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
            critic.computeTargets(pipe);
            const real_weight: f32 = 1.0;
            critic.fitTargets(pipe, update_count, real_weight, .record_stats);
        }

        /// THE IMAGINED FIT's states, named after `init` (`CriticOptions.imagined_share`): `imagined_states_at` is
        /// where the policy rollout leaves its imagined states, [steps][rows][features] from step 1 - the kit's own
        /// blocks (`LatentKit.blockZ`), laid out as the real ones the critic reads, so the same placements serve.
        pub fn reserveImagined(critic: *Self, imagined_states_at: u32) void {
            critic.imagined_states_at = imagined_states_at;
        }

        /// LAMBDA-RETURNS for the transitions `prepareTransitions` laid out - their inputs, costs and the target
        /// heads' values where each led - into the targets, at `lambda`:
        ///
        ///     values        the target heads where each transition BEGAN, V_k, beside V_(k+1)  (`twohot_decode`)
        ///     returns       walked back from each window's last transition, the running advantage starting at zero
        ///                   (`value_lambda_combine`: zimrrl's GAE recurrence)
        ///
        /// Transition block j holds step k = j + 1 of every window, so the walk takes the blocks last to first.
        fn combineLambdaReturns(critic: Self, pipe: *Pipe, lambda: f32) void {
            const source: Source = critic.source;
            const input_row_width: u32 = 2 * source.features;
            for (critic.target_passes, 0..) |target_pass, head_index| {
                const head_block_start: u32 = @as(u32, @intCast(head_index)) * critic.transitions;
                const own_values_at: u32 = critic.own_values_at + head_block_start;
                target_pass.forward(pipe, critic.inputs_at, input_row_width);
                bmpc_kit.decodeTwoHotRows(M, pipe, target_pass, critic.bins, own_values_at);
            }
            const rows: u32 = source.rows;
            pipe.params = .{ .rows = rows, .y_off = critic.running_at };
            pipe.run("zero_rows", rows);
            var transition_block: u32 = source.steps - 1;
            while (transition_block > 0) {
                transition_block -= 1;
                const block_start: u32 = transition_block * rows;
                pipe.params = .{
                    .rows = rows,
                    .x_off = critic.costs_at + block_start,
                    .v_off = critic.decoded_at + block_start,
                    .u_off = critic.own_values_at + block_start,
                    .t_off = critic.running_at,
                    .y_off = critic.targets_at + block_start,
                    .gamma = critic.options.discount,
                    .target_lambda = lambda,
                    .target_value_heads = critic.options.heads,
                    .target_head_stride = critic.transitions,
                };
                pipe.run("value_lambda_combine", rows);
            }
        }

        /// THE IMAGINED TARGETS: lambda-returns along the policy's imagined rollout, for every transition the real
        /// targets have - step k = 1 .. steps - 1 of each window - in the same places, so the same fit learns them:
        ///
        ///     inputs        [goal_k | imagined state_k], and the step after's        (the same four placements)
        ///     costs         c(imagined state_(k+1)) against goal_(k+1)               (`lat_tracking_cost`)
        ///     values        the target heads at both - V_(k+1) and V_k               (`twohot_decode`)
        ///     returns       walked back from the last transition, the running advantage starting at zero
        ///                   (`value_lambda_combine`: zimrrl's GAE recurrence)
        ///
        /// The last transition's return is its one-step target, c + gamma V; each earlier one leans on the path after
        /// it by `imagined_lambda`. The goals are the real ones: imagination aims at the reference as the policy did.
        pub fn computeImaginedTargets(critic: Self, pipe: *Pipe) void {
            const imagined_states_at: u32 = critic.imagined_states_at orelse {
                assertUnreachable(@src(), "the imagined fit has no places: `reserveImagined` first", .{});
                return;
            };
            critic.prepareTransitions(pipe, imagined_states_at);
            critic.combineLambdaReturns(pipe, critic.options.imagined_lambda);
        }

        /// ONE IMAGINED UPDATE (`CriticOptions.imagined_share`): the imagined targets, then the same fit as a real
        /// update, its loss weighted by the share - right after a policy update, while its rollout is in the kit's
        /// blocks. The real update's log numbers are left as they are.
        pub fn updateImagined(critic: Self, pipe: *Pipe, update_count: u32) void {
            critic.computeImaginedTargets(pipe);
            critic.fitTargets(pipe, update_count, critic.options.imagined_share, .leave_stats);
        }

        /// Whether a fit writes the critic's numbers for the log - the real fit does; the imagined one leaves them to
        /// it, so the log reads one kind of target.
        pub const StatsRecording = enum { record_stats, leave_stats };

        /// THE FIT: the online heads regressed toward the targets the last `computeTargets` or
        /// `computeImaginedTargets` left, the two-hot loss weighted by `loss_weight`, then one optimiser step and the
        /// target heads' follow.
        fn fitTargets(
            critic: Self,
            pipe: *Pipe,
            update_count: u32,
            loss_weight: f32,
            stats: StatsRecording,
        ) void {
            const options: Options = critic.options;
            const records_stats: bool = stats == .record_stats and critic.stats_at != null;
            // THE LOSS'S GRADIENT, head by head, into its own weight gradients.
            const input_row_width: u32 = 2 * critic.source.features;
            const head_passes: []const Network.Application = critic.head_passes;
            const gradient_offsets: []const u32 = critic.logits_gradient_offsets;
            for (head_passes, gradient_offsets, 0..) |head_pass, logits_gradient_offset, head_index| {
                head_pass.forward(pipe, critic.inputs_at, input_row_width);
                // For the log, each head's values decoded - into the targets' scratch, free once they are combined.
                if (records_stats) {
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
                    .loss_weight = loss_weight,
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
            const stats_at: ?u32 = if (records_stats) critic.stats_at else null;
            recordDeviceStat(M, pipe, stats_at, "critic_value_mean", "critic_value_stats", .{
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

/// THE POLICY A FLOW CORRECTS - and the plans around the policy, which take the flow's place: the policy as it learns,
/// or its slow average (`robot_track_resident.Options.policy_average_decay`). The policy learns toward targets built
/// from the flow and the plans; when the flow's offsets are taken against the policy that learns from them, each
/// chases the other. Against the slow average they are taken against a base that hardly moves between two of the
/// flow's updates, while the policy, learning, is never its own target.
pub const FlowBase = enum(u8) {
    live_policy = 0,
    policy_average = 1,
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
    /// TEACHER 1, FlowDPG (`FlowActor.Teacher.flow_dpg`): whether the flow learns from the world model's gradient in
    /// the policy's rollout. Off, the flow learns only from what was found - the plans and the real returns - and the
    /// rollout is the policy's own, no correction in it.
    flow_dpg: bool = true,
    /// The policy the flow corrects, and the plans around the policy offset (`FlowBase`).
    base: FlowBase = .live_policy,
    /// The byte after them, written as zero: a learner's state file saves these settings byte for byte.
    padding_after_base: u8 = 0,
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
/// Each gives the flow's weights a gradient; the first to teach writes them, the others add theirs at their weights,
/// and one clipped Adam step follows on the sum (`LatentKit.policyTrainStep`) - none when none had anything to teach.
/// With FlowDPG off (`Teacher.flow_dpg`) the flow learns from what was found alone, and the policy's rollout carries
/// no correction. Their mistakes differ - that is why there are three:
///
///     teacher      learns from                where                                               holds its data
///     1 FlowDPG    the world model's gradient  the rollout's backward keeps each step's gradient,   `Learning`
///                                              projected onto the synergies
///                                              (`keepFlowCostGradient`); FlowDPG's targets on the
///                                              rollout's own rows (`flowTrainingGradient`)
///     2 planner    the plans' corrections      the steps characters took from their plans, by flow  `Distillation`
///                                              matching (`distillFlow`); on the device the physics'
///                                              planners' choices, each against the policy the flow
///                                              corrects at the update
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
            /// TEACHER 1 AT ALL: FlowDPG learns from the rollout - the world model's gradient at every sample's
            /// action - and the rollout carries the flow's correction for it. Off, the rollout is the policy's own
            /// (`correctsRollout`), and the flow learns from its other teachers alone. Around a policy that climbs
            /// the same gradient, FlowDPG duplicates it: a sample beside the policy is pulled back toward it, so the
            /// flow's other ways - the plans' - are worn away rather than kept.
            flow_dpg: bool = true,
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
        /// state]. The two goals are as wide as the flow's goal (`isGoalWidth`: the features, and possibly the root
        /// target's slots after them); the critic and the cost read each goal's features.
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
            /// A goal's numbers - the features, and possibly the root target's slots after them - and the state's.
            goal_width: u32,
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
            /// kit reading them both go through, for goals `g` wide, states `f` wide and `k` coefficients:
            ///
            ///     [ own goal | goal | state | coefficients | next state ]
            ///       0          g      2g      2g + f         2g + f + k        width 2g + 2f + k
            ///
            /// The flow's condition, [goal | state], is the g + f columns from `goal`; a pending example - kept before
            /// the step it waits for - is the `next_state` columns before the next state.
            pub const Columns = struct {
                own_goal: u32,
                goal: u32,
                state: u32,
                coefficients: u32,
                next_state: u32,
                width: u32,

                pub fn of(goal_width: u32, features: u32, synergy_count: u32) Columns {
                    const goals_end: u32 = 2 * goal_width;
                    const columns: Columns = .{
                        .own_goal = 0,
                        .goal = goal_width,
                        .state = goals_end,
                        .coefficients = goals_end + features,
                        .next_state = goals_end + features + synergy_count,
                        .width = goals_end + 2 * features + synergy_count,
                    };
                    return columns;
                }
            };

            /// A batch of `rows` examples of `goal_width`-wide goals, `features`-wide states and `synergy_count`
            /// coefficients, its region reserved in `layout`.
            pub fn init(
                layout: *kit_mlp.KitLayout,
                rows: u32,
                goal_width: u32,
                features: u32,
                synergy_count: u32,
            ) Fpo {
                const columns: Columns = .of(goal_width, features, synergy_count);
                const fpo: Fpo = .{
                    .examples_at = layout.reserveActs(rows * columns.width),
                    .rows = rows,
                    .goal_width = goal_width,
                    .features = features,
                    .synergy_count = synergy_count,
                };
                return fpo;
            }

            /// Where each part of this batch's examples lies (`Columns`).
            pub fn exampleColumns(fpo: Fpo) Columns {
                return .of(fpo.goal_width, fpo.features, fpo.synergy_count);
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
                    .conditions_at = layout.reserveActs(fpo.rows * (fpo.goal_width + fpo.features)),
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
        /// condition (the goal and state the character acted in) and the plan's correction - drawn once per round:
        /// the CPU's examples uploaded, or the device's ring gathered where it lies
        /// (`robot_track_resident.FlowExamples`). Each policy update adds `weight` x the flow matching loss on them
        /// (`KitFlow.flowMatchingGradient`) to the flow's gradient, before the one optimiser step, and a label update
        /// gives it a step of its own (`LatentKit.flowPlansStep`). Flow matching, not a regression: where the plans for
        /// a situation differ - a step left, a step right - the flow learns both, each from its share of the noise.
        ///
        ///     once per round      conditions [rows][condition] to `conditions_at`, corrections [rows][action] to the
        ///                         trainer's `actions_at` - the device's taken again before every update, against the
        ///                         policy the flow corrects (`robot_track_resident.Resident.retargetFlowBatch`);
        ///                         `has_batch` set when there are any
        ///     each update         the conditions copied into the trainer's wide rows, each row's noise and flow time
        ///                         hashed from the update's seed, the gradient added
        pub const Distillation = struct {
            trainer: Flow.Trainer,
            conditions_at: u32,
            weight: f32,
            /// Whether this round's batch holds examples: none before any plan has taught, and then teacher 2 gives
            /// nothing.
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
        /// numbers, the last `features` of them the state, to the coefficients), its noise of `noise_scale`, its
        /// regions in `layout` (which must start past everything the latent kit uses) - the synergies' among the
        /// parameters. Memory: `arena`.
        pub fn init(
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            velocity_mlp: zn.Mlp(f32),
            condition_width: u32,
            features: u32,
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
                // FPO reads its examples' goals and states apart: the condition must be a goal, then the state.
                const goal_width: u32 = condition_width -| features;
                const condition_is_goal_and_state: bool = isGoalWidth(goal_width, features);
                assertf(condition_is_goal_and_state, @src(), "FPO: a condition of {d} for states of {d}", .{
                    condition_width,
                    features,
                });
                fpo = Fpo.init(layout, fpo_settings.rows, goal_width, features, synergy_count);
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

        /// Whether the flow learns from the policy's rollout (`Teacher.flow_dpg`): a flow that learns, with FlowDPG on.
        pub fn learnsFromRollout(actor: Self) bool {
            const learning: Learning = actor.learning orelse return false;
            return learning.teacher.flow_dpg;
        }

        /// Whether the flow's correction is in a rollout of a kit that holds it: always for a flow that only acts - a
        /// planner's flow plans are its corrections, rolled - and for a learning flow only when it learns from the
        /// rollout. Otherwise the rollout is the policy's own: a correction it does not learn from would only bend
        /// the policy's gradient, the policy learning to make up for the flow's offset.
        pub fn correctsRollout(actor: Self) bool {
            const learning: Learning = actor.learning orelse return true;
            return learning.teacher.flow_dpg;
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

/// THE WORLD MODEL's HEADS (`LatentKit.initInForm`). SuperTrack's world model has one: a step of one decision, its
/// output the change of the state. A model with a SKIP HEAD has two last layers over one trunk - the same hidden
/// layers - one for a step of one decision and one for a step of `skip_steps`, and each head's output is a PROJECTION:
/// where the state would be `projection_steps` = K decisions on, moving at the step's mean rate. The state a step of
/// k decisions reaches is the lerp toward it,
///
///     z_k  =  lerp(z, P_k, k / K)  =  z + (k / K)(P_k - z)            P_k - z the head's output, K x the mean rate
///
/// so the heads' outputs share one scale, a velocity's, whatever their step - which, with a trunk both heads train,
/// makes the second head easy to learn. Over a step of k decisions the row reads the reference the servo aimed at
/// during its last decision and the mean of the actions given over it (`zn_mlp.lat_gather` on a schedule).
pub const WorldHeads = struct {
    /// The skip head's step, in decisions: 0 for no skip head; otherwise 2 to `projection_steps`.
    skip_steps: u32 = 0,
    /// K, the decisions on of the heads' projection; read only with a skip head.
    projection_steps: u32 = 6,

    pub fn hasSkipHead(heads: WorldHeads) bool {
        return heads.skip_steps > 1;
    }
};

/// THE KINDS OF THE WORLD MODEL's BATCHES (`LatentKit.batch_kind`), each its loss logged under its own statistic: the
/// one-step head's windows (`world_model_loss`), the skip head's on its schedule (`skip_head_loss`), and the skip head
/// against the one-step head chained (`skip_consistency_loss`).
pub const WorldBatchKind = enum { one_step, skip, skip_consistency };

/// THE WORLD MODEL's FORM (`LatentKit.initInForm`): the network that predicts a step's change from the wide row's
/// state, reference and action.
pub const WorldForm = union(enum) {
    /// SuperTrack's form: two hidden layers of the kit's `hidden`, tanh, then a linear layer to the change - the CPU
    /// model's own (`robot_latent.LatentWorld`), whose eight tensors `LatentKit.packWeights` lays out.
    dense_tanh,
    /// THE NORMED FORM (`NormedWorld`): hidden layers of the kit's `hidden`, each linear, layer norm and SiLU, then a
    /// linear layer to the change, started at zero - the world model of SuperMimic's reproductions, BlinkMimic's among
    /// them. SuperMimic's own code ends each hidden layer in GELU and leaves every layer to PyTorch's start.
    normed_silu: NormedSilu,

    pub const NormedSilu = struct {
        /// The most hidden layers the kit's world model holds (`NormedWorld.max_layers`, with the last layer).
        pub const max_hidden_layers: u32 = 4;
        /// How many hidden layers: SuperMimic's world model has three, of 2048 - its own code's and its reproductions'.
        hidden_layers: u32 = 3,
        /// The layer norm's epsilon, added to the variance inside the root: PyTorch's default, and zimrnum's.
        norm_epsilon: f32 = 1.0e-5,
    };
};

/// THE WORLD MODEL IN THE NORMED FORM, ON THE KIT (`WorldForm.normed_silu`). Its hidden layers are TD-MPC2's
/// normed layer ending in SiLU (`kit_mlp.KitLayerKind.normed_silu`), its last a plain linear layer to the change:
///
///     [z | reference | action]  ->  linear -> layer norm -> SiLU  ->  ...  ->  linear  ->  the change
///
/// with a gain and a bias per output after each norm. It is a zimrnum `Mlp` with SiLU in its hidden layers and a
/// plain last layer (`mlpSpec`), laid out as `kit_mlp.KitNetwork` lays one out, its parameters from params 0 - where
/// the dense model's are - and run by that network's own forward and backward.
///
/// A rollout applies it once per step, and the backward needs every step's values, so each step has its own
/// activations: step k's regions are step 0's moved by k x `step_floats`. The gradient regions are one set, reused
/// step after step as a backward walks back from the window's end - as the dense model's `dh1_at` and `dh2_at` are.
/// Everything is held in arrays, by value, so a kit stays a plain value that can be copied and placed (`placedAt`).
pub fn NormedWorld(comptime M: type) type {
    return struct {
        const Self = @This();
        pub const Network = kit_mlp.KitNetwork(M);
        /// The hidden layers at most, then the last.
        pub const max_layers: usize = WorldForm.NormedSilu.max_hidden_layers + 1;

        layers: [max_layers]kit_mlp.KitLayer,
        layer_count: u32,
        /// Step 0's regions, layer by layer (`kit_mlp.LayerRegions`): its activations, and the gradient regions every
        /// step uses.
        first_step_regions: [max_layers]kit_mlp.LayerRegions,
        /// Floats of acts one step's application holds.
        step_floats: u32,
        rows: u32,

        /// The world model for `rows` rows and `steps` steps, reserved in `layout`: its layers' parameters in params
        /// (the hidden layers `hidden` wide, from `inputs` to `features` outputs), step 0's regions in acts and the
        /// gradient regions in dacts, then the other steps' activations after step 0's.
        pub fn reserve(
            layout: *kit_mlp.KitLayout,
            form: WorldForm.NormedSilu,
            inputs: u32,
            hidden: u32,
            features: u32,
            rows: u32,
            steps: u32,
        ) Self {
            const layer_count_fits: bool = form.hidden_layers >= 1 and form.hidden_layers < max_layers;
            assertf(layer_count_fits, @src(), "a world model of {d} hidden layers: the kit's holds 1 to {d}", .{
                form.hidden_layers,
                max_layers - 1,
            });
            // Step 0's regions are reserved whatever the count, the other steps' after them: a rollout of no step has
            // no first step to place.
            assertf(steps >= 1, @src(), "a world model applied over {d} steps: a rollout has one or more", .{steps});
            var world: Self = .{
                .layers = undefined,
                .layer_count = form.hidden_layers + 1,
                .first_step_regions = undefined,
                .step_floats = 0,
                .rows = rows,
            };
            var layer_input_width: u32 = inputs;
            for (world.layers[0..world.layer_count], 0..) |*layer, layer_index| {
                const is_last: bool = layer_index + 1 == world.layer_count;
                layer.* = .{
                    .kind = if (is_last) .plain else .normed_silu,
                    .input_width = layer_input_width,
                    .output_width = if (is_last) features else hidden,
                    .weights_offset = 0,
                    .norm_epsilon = if (is_last) 0 else form.norm_epsilon,
                    // A SiLU layer's group is never read; the kit's own default stands in for it.
                    .simnorm_group = 8,
                };
                layer.weights_offset = layout.reserveParams(layer.parameterFloats());
                layer_input_width = layer.output_width;
            }
            const step_start: u32 = layout.acts_floats;
            const layers: []const kit_mlp.KitLayer = world.layers[0..world.layer_count];
            const regions: []kit_mlp.LayerRegions = world.first_step_regions[0..world.layer_count];
            for (layers, regions) |layer, *layer_regions| {
                layer_regions.* = Network.reserveLayerRegions(layout, layer, rows, .forward_and_backward);
            }
            world.step_floats = layout.acts_floats - step_start;
            const later_steps_floats: u32 = (steps - 1) * world.step_floats;
            _ = layout.reserveActs(later_steps_floats);
            return world;
        }

        /// The layers as a `kit_mlp.KitNetwork` - a view of this world model's own array, valid while it is.
        pub fn network(world: *const Self) Network {
            const layers_view: Network = .{ .layers = world.layers[0..world.layer_count] };
            return layers_view;
        }

        /// Where the network's parameters end in params: one past its last layer's last number (they begin at 0).
        pub fn paramsEnd(world: *const Self) u32 {
            return world.network().paramsEnd();
        }

        /// Step `k`'s application (k = 0 .. steps - 1): step 0's regions with the activations moved to step k's,
        /// written into `regions` - the storage the application's view reads, which must outlive its use.
        pub fn stepApplication(
            world: *const Self,
            k: u32,
            regions: *[max_layers]kit_mlp.LayerRegions,
        ) Network.Application {
            const shift: u32 = k * world.step_floats;
            const first: []const kit_mlp.LayerRegions = world.first_step_regions[0..world.layer_count];
            for (first, regions[0..world.layer_count]) |first_regions, *moved| {
                moved.* = first_regions;
                moved.linear_outputs += shift;
                moved.normalised_rows += shift;
                moved.inverse_spreads += shift;
                moved.scaled_values += shift;
                moved.outputs += shift;
            }
            const application: Network.Application = .{
                .network = world.network(),
                .row_count = world.rows,
                .layer_regions = regions[0..world.layer_count],
            };
            return application;
        }

        /// Where the gradient at the network's inputs is after a step's backward: the first layer's input gradient,
        /// `inputs` wide - the same region at every step.
        pub fn inputsGradientAt(world: *const Self) u32 {
            return world.first_step_regions[0].inputs_gradient;
        }

        /// This world model placed after `activations_base` floats of acts and `gradients_base` of dacts, as
        /// `LatentKit.placedAt` places a kit: every region moved, the parameters left where they are.
        pub fn placedAt(world: Self, activations_base: u32, gradients_base: u32) Self {
            var placed: Self = world;
            for (placed.first_step_regions[0..placed.layer_count]) |*regions| {
                regions.linear_outputs += activations_base;
                regions.normalised_rows += activations_base;
                regions.inverse_spreads += activations_base;
                regions.scaled_values += activations_base;
                regions.outputs += activations_base;
                regions.scaled_values_gradient += gradients_base;
                regions.linear_outputs_gradient += gradients_base;
                regions.inputs_gradient += gradients_base;
            }
            return placed;
        }

        /// The world model as a zimrnum `Mlp`'s spec, started as SuperMimic's reproductions start it: SiLU in its
        /// hidden layers, their weights as PyTorch starts a linear layer (`zn.InitScheme.fan_in_uniform`) -
        /// SuperMimic's code leaves its layers to it - and a plain last layer at zero (the reproductions' choice), so
        /// that the model begins predicting "nothing changes". Its hidden
        /// widths written into `hidden_widths`, which the spec reads and must outlive it. `NormedWorld.writeParams`
        /// puts such a network's numbers where the kit reads them.
        pub fn mlpSpec(world: *const Self, hidden_widths: *[max_layers]usize) zn.Mlp(f32).Spec {
            const hidden_count: usize = world.layer_count - 1;
            for (world.layers[0..hidden_count], hidden_widths[0..hidden_count]) |layer, *width| {
                width.* = layer.output_width;
            }
            const first_layer: kit_mlp.KitLayer = world.layers[0];
            const last_layer: kit_mlp.KitLayer = world.layers[hidden_count];
            const spec: zn.Mlp(f32).Spec = .{
                .input = first_layer.input_width,
                .hidden = hidden_widths[0..hidden_count],
                .output = last_layer.output_width,
                .hidden_activation = .silu,
                .output_activation = .none,
                .scheme = .fan_in_uniform,
                .zero_last = true,
            };
            return spec;
        }

        /// `mlp`'s numbers into the host's copy of params, where the kit reads them (`kit_mlp.KitNetwork.writeParams`)
        /// - a network of this world model's shape: as many layers, each as wide, each normed one with the same
        /// epsilon.
        pub fn writeParams(world: *const Self, mlp: zn.Mlp(f32), params: []f32) void {
            const same_depth: bool = mlp.hidden.len + 1 == world.layer_count;
            assertf(same_depth, @src(), "a network of {d} hidden layers for a world model of {d}", .{
                mlp.hidden.len,
                world.layer_count - 1,
            });
            for (mlp.hidden, world.layers[0..mlp.hidden.len]) |hidden_layer, layer| {
                const same_shape: bool = hidden_layer.dense.weight.shape[0] == layer.input_width and
                    hidden_layer.dense.weight.shape[1] == layer.output_width and
                    hidden_layer.activation == .silu and hidden_layer.norm.epsilon == layer.norm_epsilon;
                assertf(same_shape, @src(), "a hidden layer of {d} -> {d} for the world model's {d} -> {d}", .{
                    hidden_layer.dense.weight.shape[0],
                    hidden_layer.dense.weight.shape[1],
                    layer.input_width,
                    layer.output_width,
                });
            }
            world.network().writeParams(mlp, params);
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
        /// columns, the world model's the rest - both contiguous slices of the same row. A goal is
        /// the reference's features, and possibly the root target's slots after them (`isGoalWidth`):
        /// the cost's goals (`g_at`) are the features alone.
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
        /// THE WORLD MODEL's HEADS (`WorldHeads`): one, SuperTrack's - a step of one decision, its output the change
        /// - or two over one trunk, a step of one decision and a step of `skip_steps`, each head's output the
        /// PROJECTION of the state `projection_steps` decisions on, the state a step reaches the lerp toward it.
        heads: WorldHeads = .{},
        /// params: the skip head's last layer - its weights, then its bias - beside the one-step head's (`w3`); 0
        /// without a skip head.
        w4: u32 = 0,
        /// The kind of the world model's batch in hand (`WorldBatchKind`): which statistic its loss is logged under.
        batch_kind: WorldBatchKind = .one_step,
        /// THE ROLLOUT's SCHEDULE: each step's skip, in decisions - 1 or the skip head's `skip_steps`; the steps past
        /// its end, and every step of an empty schedule, of 1. Host memory, the caller's: a learner sets it before a
        /// rollout through skips, and the kit reads it as it issues each step (`skipAt`). A gather on a schedule needs
        /// the same skips as the window's record offsets (`zn_mlp.lat_gather`).
        skips: []const u32 = &.{},
        /// acts: THE CHANGE IN UNITS OF THE TYPICAL CHANGE, when the learner asks for it - each feature's mean and
        /// spread of its change in one step, `features` of each, in the features' units (the learner's running ones,
        /// `zn_mlp.lat_world_moments`). The network predicts the change in those units (`lat_advance`: mean + spread
        /// x output), so a feature that moves little in a step is predicted as finely as one that moves much. Null:
        /// the network's output is the change itself.
        increments_at: ?u32 = null,
        /// acts: each feature's weight in the world model's loss, `features` of them - 1 / its change's spread
        /// squared (floored, `zn_mlp.lat_world_moments`), so each feature's error counts in units of how much that
        /// feature changes in a step. Null: every feature weighs 1.
        loss_weights_at: ?u32 = null,
        /// acts: EACH FEATURE's KIND, `features` small integers (`worldLossKind`, written once by the learner:
        /// `writeFeatureKinds`), by which the world model's loss in its own units is logged (`recordWorldModelLoss`).
        /// Null - or no loss weights - and that log is not kept.
        feature_kinds_at: ?u32 = null,
        /// WHETHER THE WORLD MODEL's NEXT UPDATE STARTS ITS GRADIENT's TALLY AFRESH
        /// (`DeviceStats.world_updates_in_round`, `stepWorld`): true for each update its own tally; a learner counting
        /// by rounds sets it before a round's first update and clears it after.
        gradient_tally_restarts: bool = true,
        /// params: THE WORLD MODEL's INPUTS' NORMALISER, when the learner keeps one - each of its `inputs` columns'
        /// shift, then each one's scale, read by its first layer as (input - shift) x scale (zn_mlp's `inputAffine`).
        /// The wide rows keep the inputs in their own units - the state already normalised, the servo's encoded
        /// targets, the action given - and the model reads them normalised, its forward and its backward alike: as
        /// SuperMimic's world model normalises its state and its action and XMimic's its whole input. Null: the
        /// inputs as they are.
        inputs_affine_at: ?u32 = null,
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
        /// THE WINDOW's STARTING ACTIONS, `rows x actions`: the action each row was given before its window began - the
        /// previous action the action filter blends the window's first decision into (`policyStep`). Rest, zero, unless
        /// the trainer stages the replay's.
        start_actions_at: u32,
        action_scale: f32 = 1.0,
        /// THE ACTION FILTER IN THE ROLLOUT (`zn_mlp.lat_act`, `lat_act_bwd`), as the trainer applies it when it acts:
        /// each decision's action blended into the one before - the joints' offsets at `filter`, the limbs' stiffnesses
        /// (an action's last `stiffness_count` numbers) at `stiffness_filter` - and differentiated exactly, a
        /// decision's gradient reaching every later decision it still shapes. 1 and 1: no filter, the rollout as it
        /// always was.
        filter: f32 = 1.0,
        stiffness_filter: f32 = 1.0,
        stiffness_count: u32 = 0,
        /// THE POLICY SEES THE ACTION APPLIED BEFORE ITS DECISION (the CPU learner's `sees_applied`): its block -
        /// packed after the layers, zero at the start - is trained, from its weights' gradient and the gradient its
        /// reading sends to the earlier decision's action. Off, the block is read but never trained, so it stays zero
        /// and the policy is exactly the one that cannot see it. Every acting path reads the block with the action
        /// applied before its decision - the trainer's mirror (its slot), the judge (its slots), the lab's player (its
        /// controller's filtered action) and a device (its worlds' actions) - so a trained block acts everywhere alike.
        sees_applied: bool = false,
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
        /// THE ROOT IN IMAGINATION (`ImaginedRoot`), when the policy's goal carries the root target
        /// (`rbt.root_target_size`): where the window's root is at each decision, and the reference's root at each
        /// decision's goal. The gather writes the first root, every goal's root, and the first row's root target
        /// (`zn_mlp.lat_gather`); the acting rollout moves the root decision by decision, by the velocities the world
        /// model predicts, and writes each later row's target (`imaginedRootStep`); the policy's backward carries the
        /// targets' gradient back through the root into the states (`imaginedRootBackward`). Null: the goal's slots
        /// stay zero.
        imagined_root: ?ImaginedRoot = null,
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
        /// THE WORLD MODEL IN THE NORMED FORM (`NormedWorld`), when the kit was laid out in it (`initInForm`); null:
        /// the dense tanh model, its layers at `h1_at`, `h2_at` and `change_at`, its weights at `w1`, `w2` and `w3`.
        /// In the normed form those name the world model's region as a whole, which `normed_world` divides.
        normed_world: ?NormedWorld(M) = null,
        /// A flow correcting the policy in the rollout (`FlowActor`), when the learner has one.
        flow_actor: ?FlowActor(M) = null,
        /// Corrections GIVEN rather than sampled (`GivenCorrections`) - the tracking planner's candidates, each a
        /// sequence of corrections around the policy. A kit takes its corrections from a flow or from these, not both.
        given_corrections: ?GivenCorrections = null,
        // The policy's gradient slots, one each, reused step after step: the raw action, its two
        // hidden layers, and its input [goal | state] (`lead + features` wide).
        draw_at: u32,
        /// The action filter's CARRY in the gradients, `rows x actions` (`lat_act_bwd`): the action columns' whole
        /// gradient so far, carried from each step to the one before; zero before the window's last step.
        filter_carry_at: u32,
        /// The gradient the policy's reading of the action applied before decision k sends to decision k-1's action,
        /// `rows x actions` (`lat_act_bwd`'s `lat_applied_gradient`): written at step k, added at step k-1; zero
        /// before the window's last step.
        applied_gradient_at: u32,
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
            "x_at",
            "h1_at",
            "h2_at",
            "change_at",
            "z_at",
            "t_at",
            "g_at",
            "ph1_at",
            "ph2_at",
            "raw_at",
            "start_actions_at",
            "total",
        };
        const gradient_offset_fields = [_][]const u8{
            "dz_at",
            "dh1_at",
            "dh2_at",
            "dx_at",
            "draw_at",
            "dph1_at",
            "dph2_at",
            "dp_at",
            "dchange_at",
            "filter_carry_at",
            "applied_gradient_at",
            "dtotal",
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
            "feature_kinds_at",
            "inputs_affine_at",
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
            // The kernels' kinds of feature are robot.zig's, as `worldLossKind` numbers them.
            const kinds_numbered: u32 = worldLossKind(.up) + 1;
            if (M.world_loss_kinds != kinds_numbered) {
                @compileError("zn_mlp.world_loss_kinds must count robot.zig's LocalFeatureKind");
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
            if (kit.normed_world) |world| {
                placed.normed_world = world.placedAt(activations_base, gradients_base);
            }
            return placed;
        }

        /// WHERE THE ROOT IN IMAGINATION LIVES (`imagined_root`): two blocks in the activations, each [step][row][pose]
        /// (`zn_mlp.lat_root_pose_numbers` a pose, as `zm.Pose.numbers` writes one) - the root at each state of the
        /// rollout, the first and the last included (`rootBlockFloats`), and the reference's root at each decision's
        /// goal (`goalRootBlockFloats`) - placed by the learner, beside its other blocks. And what moves it: where the
        /// root's velocity and angular velocity begin in the features (robot_track's `localVelocityColumn`,
        /// `localAngularColumn` - both in the root's own frame), and a decision's seconds. And in the gradients, the
        /// root's gradient carried from decision to decision in the backward, [row][6]
        /// (`zn_mlp.lat_root_gradient_numbers`).
        ///
        /// THE ROOT's COST: the policy's loss charges the root's DRIFT at every rolled state k - where the reference's
        /// root at state k's frame is, seen from the root imagined there (`zm.poseSeenFrom`, the root target's own nine
        /// numbers: the position, then the two axes less those of no rotation) - as
        ///
        ///     cost_k = decisions_k x mean over rows of ( w_position |d_position|^2 + w_rotation |d_axes|^2 )
        ///
        /// in the squared-distance form of the tracking terms, weighted like them by the decisions the step spans.
        /// |d_position|^2 is the squared distance between the two roots, SuperMimic's root position error; |d_axes|^2
        /// is how far the two axes turned, 2 - 2 cos of each axis's angle - about twice the squared angle for a turn
        /// about the vertical, once for a tilt, which the features see already. Its gradient reaches the root through
        /// `zm.poseSeenFromBackward`, the one the root target's slots send: the same nine numbers, read where the
        /// reference's root is the state's own frame's rather than the goal's. Off at weights of zero.
        ///
        /// With `drift_at`, a block of 2 x steps x rows floats where the drift is measured for the log
        /// (`recordRootDrift`).
        pub const ImaginedRoot = struct {
            roots_at: u32,
            goal_roots_at: u32,
            velocity_column: u32,
            angular_column: u32,
            decision_seconds: f32,
            /// Null for a kit whose rollouts are never differentiated: a planner's (`forPlans`).
            gradient_at: ?u32,
            position_weight: f32 = 0,
            rotation_weight: f32 = 0,
            drift_at: ?u32 = null,

            /// The floats the roots' block takes, for a kit's `steps` and `rows`: the root at each of the rollout's
            /// steps + 1 states.
            pub fn rootBlockFloats(steps: u32, rows: u32) u32 {
                return (steps + 1) * rows * M.lat_root_pose_numbers;
            }

            /// The floats the goals' roots take: one at each of the rollout's `steps` decisions' goals.
            pub fn goalRootBlockFloats(steps: u32, rows: u32) u32 {
                return steps * rows * M.lat_root_pose_numbers;
            }

            /// The floats the drift's block takes for the log (`drift_at`): a distance and an angle per state rolled.
            pub fn driftBlockFloats(steps: u32, rows: u32) u32 {
                return 2 * steps * rows;
            }

            /// Whether the policy's loss charges the root's drift.
            pub fn hasCost(root: ImaginedRoot) bool {
                return root.position_weight != 0 or root.rotation_weight != 0;
            }

            /// Where the root's gradient is carried in a kit that differentiates its rollouts (the training kit's).
            fn carriedGradientAt(root: ImaginedRoot) u32 {
                const reason: []const u8 = "a planner's root is never differentiated: it has no gradient's block";
                assertf(root.gradient_at != null, @src(), "{s}", .{reason});
                return root.gradient_at.?;
            }

            /// THE ROOT IMAGINED IN A PLANNER's KIT, as `root` imagines it in the training kit's rollouts - the same
            /// columns, step and cost's weights - with blocks of its own for that kit's `steps` and `rows`, reserved in
            /// `layout`: a planner's rollouts are scored, never differentiated, and no drift is measured there.
            pub fn forPlans(
                root: ImaginedRoot,
                layout: *kit_mlp.KitLayout,
                steps: u32,
                rows: u32,
            ) ImaginedRoot {
                var plans_root: ImaginedRoot = root;
                plans_root.roots_at = layout.reserveActs(rootBlockFloats(steps, rows));
                plans_root.goal_roots_at = layout.reserveActs(goalRootBlockFloats(steps, rows));
                plans_root.gradient_at = null;
                plans_root.drift_at = null;
                return plans_root;
            }

            /// The root's drift at rolled state k (1 .. steps) for the per-step cost (`RootStepCost`): the roots at
            /// state k, the reference's at state k's frame - goal roots k - 1. Null without a cost.
            pub fn stepCost(root: ImaginedRoot, k: u32, rows: u32) ?RootStepCost {
                if (!root.hasCost()) {
                    return null;
                }
                const pose_floats: u32 = rows * M.lat_root_pose_numbers;
                const step_cost: RootStepCost = .{
                    .roots_at = root.roots_at + k * pose_floats,
                    .reference_roots_at = root.goal_roots_at + (k - 1) * pose_floats,
                    .position_weight = root.position_weight,
                    .rotation_weight = root.rotation_weight,
                };
                return step_cost;
            }
        };

        /// Why a kit could not be laid out: a buffer of the kit too small for it (each by its own name), or a policy
        /// without the goal columns it reads.
        pub const InitError = error{
            KitActivationsTooSmall,
            KitGradientsTooSmall,
            KitParametersTooSmall,
            PolicyWithoutGoals,
            SkipHeadNeedsDenseForm,
        };

        /// The form the world model was laid out in (`initInForm`): what a second kit over the same weights is laid out
        /// in (`TrackingScorer`, `TrackingPlanner`).
        pub fn worldForm(kit: Self) WorldForm {
            const world: NormedWorld(M) = kit.normed_world orelse return .dense_tanh;
            const first_layer: kit_mlp.KitLayer = world.layers[0];
            const normed_form: WorldForm.NormedSilu = .{
                .hidden_layers = world.layer_count - 1,
                .norm_epsilon = first_layer.norm_epsilon,
            };
            return .{ .normed_silu = normed_form };
        }

        /// A kit with the world model in SuperTrack's dense tanh form (`initInForm`).
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
        ) InitError!Self {
            const dense_tanh: WorldForm = .dense_tanh;
            const one_head: WorldHeads = .{};
            return initInForm(
                pipe,
                features,
                references,
                actions,
                hidden,
                rows,
                steps,
                lead,
                policy_hidden,
                dense_tanh,
                one_head,
            );
        }

        /// The kit laid out for `rows` windows of `steps` steps, the world model in `world_form`: in the activations,
        /// the wide blocks, the world model's own values, the states, targets and goals, the policy's blocks; in the
        /// gradients, the states', the world model's, the policy's slots; in params, the world model's weights from 0,
        /// then the policy's (`p_at`).
        pub fn initInForm(
            pipe: *compute_host.Compute(M),
            features: u32,
            references: u32,
            actions: u32,
            hidden: u32,
            rows: u32,
            steps: u32,
            lead: u32,
            policy_hidden: u32,
            world_form: WorldForm,
            heads: WorldHeads,
        ) InitError!Self {
            // A policy acts on [goal | state], so it needs the goal columns in front: the reference's features, and
            // possibly the root target's slots after them (`rbt.root_target_size`).
            if (policy_hidden > 0 and !isGoalWidth(lead, features)) {
                return error.PolicyWithoutGoals;
            }
            // The skip head is a last layer beside the dense model's: the normed form has none yet.
            if (heads.hasSkipHead() and world_form != .dense_tanh) {
                return error.SkipHeadNeedsDenseForm;
            }
            const inputs: u32 = features + references + actions;
            const width: u32 = lead + inputs;
            const x_at: u32 = 0;
            // The world model's own regions follow the wide blocks in acts, the states' gradients in dacts, and start
            // params: the dense model's two hidden layers and its change at every step, and its slots for the
            // backward, reused step after step; or the normed form's step regions (`NormedWorld.reserve`).
            const world_at: u32 = x_at + (steps + 1) * rows * width;
            const states_gradient_floats: u32 = steps * rows * features;
            var world_layout: kit_mlp.KitLayout = .{
                .acts_floats = world_at,
                .dacts_floats = states_gradient_floats,
                .params_floats = 0,
            };
            var normed_world: ?NormedWorld(M) = null;
            const h1_at: u32 = world_at;
            var h2_at: u32 = world_at;
            var change_at: u32 = world_at;
            const dh1_at: u32 = states_gradient_floats;
            var dh2_at: u32 = states_gradient_floats;
            var dx_at: u32 = states_gradient_floats;
            const w1: u32 = 0;
            var w2: u32 = w1;
            var w3: u32 = w1;
            var w4: u32 = 0;
            switch (world_form) {
                .dense_tanh => {
                    h2_at = h1_at + steps * rows * hidden;
                    change_at = h2_at + steps * rows * hidden;
                    _ = world_layout.reserveActs(2 * steps * rows * hidden + steps * rows * features);
                    dh2_at = dh1_at + rows * hidden;
                    dx_at = dh2_at + rows * hidden;
                    // (The input-gradient block is `inputs` wide - see `width`.)
                    _ = world_layout.reserveDacts(2 * rows * hidden + rows * inputs);
                    w2 = w1 + inputs * hidden + hidden;
                    w3 = w2 + hidden * hidden + hidden;
                    const head_floats: u32 = hidden * features + features;
                    // The skip head's last layer straight after the one-step head's, inside the world model's weights:
                    // its optimiser and its gradient's bound cover both heads.
                    if (heads.hasSkipHead()) {
                        w4 = w3 + head_floats;
                    }
                    const head_count: u32 = if (heads.hasSkipHead()) 2 else 1;
                    _ = world_layout.reserveParams(w3 + head_count * head_floats);
                },
                .normed_silu => |normed_form| {
                    const world: NormedWorld(M) = .reserve(
                        &world_layout,
                        normed_form,
                        inputs,
                        hidden,
                        features,
                        rows,
                        steps,
                    );
                    normed_world = world;
                    dx_at = world.inputsGradientAt();
                },
            }
            const z_at: u32 = world_layout.acts_floats;
            const t_at: u32 = z_at + steps * rows * features;
            // The policy's blocks come after the targets and the goals.
            const policy_blocks: u32 = t_at + steps * rows * features + (if (lead > 0) steps * rows * features else 0);
            // The packed actions of every step, [step][row][action] (`raw_at`), and their gradient (`draw_at`), belong
            // to ANY actor - a Gaussian policy's raw output, or a flow's action - so they are counted whether or not
            // this kit has a Gaussian policy; only that policy's own hidden layers and input gradient are counted with
            // it. (A kit counted without them, then given a flow, would write its actions past its own end.)
            const policy_hidden_floats: u32 = 2 * steps * rows * policy_hidden;
            const step_actions_floats: u32 = steps * rows * actions;
            const start_actions_at: u32 = policy_blocks + policy_hidden_floats + step_actions_floats;
            const activations_end: u32 = start_actions_at + rows * actions;
            const has_gaussian_policy: bool = policy_hidden > 0;
            const policy_gradient_width: u32 = 2 * policy_hidden + lead + features;
            const policy_gradient_floats: u32 = if (has_gaussian_policy) rows * policy_gradient_width else 0;
            // The policy's gradient slots after the world model's: its raw action, its hidden layers, its input.
            const draw_at: u32 = world_layout.dacts_floats;
            const policy_slots_at: u32 = draw_at + rows * actions;
            // A step's change's gradient in the network's own units (`changeGradient`), after everything else.
            const dchange_at: u32 = policy_slots_at + policy_gradient_floats;
            const filter_carry_at: u32 = dchange_at + rows * features;
            const applied_gradient_at: u32 = filter_carry_at + rows * actions;
            const gradients_end: u32 = applied_gradient_at + rows * actions;
            // The policy's weights follow the world model's.
            const world_params_end: u32 = world_layout.params_floats;
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
                .heads = heads,
                .w4 = w4,
                .x_at = x_at,
                .h1_at = h1_at,
                .h2_at = h2_at,
                .change_at = change_at,
                .z_at = z_at,
                .t_at = t_at,
                .g_at = t_at + steps * rows * features,
                .policy_hidden = policy_hidden,
                .p_at = world_params_end,
                .policy_count = if (policy_hidden == 0)
                    0
                else
                    (lead + features) * policy_hidden + policy_hidden + policy_hidden * policy_hidden +
                        policy_hidden + policy_hidden * actions + actions + actions * policy_hidden,
                .ph1_at = policy_blocks,
                .ph2_at = policy_blocks + steps * rows * policy_hidden,
                .raw_at = policy_blocks + 2 * steps * rows * policy_hidden,
                .start_actions_at = start_actions_at,
                .total = activations_end,
                .dz_at = 0,
                .dh1_at = dh1_at,
                .dh2_at = dh2_at,
                .dx_at = dx_at,
                .draw_at = draw_at,
                .filter_carry_at = filter_carry_at,
                .applied_gradient_at = applied_gradient_at,
                .dph1_at = policy_slots_at,
                .dph2_at = policy_slots_at + rows * policy_hidden,
                .dp_at = policy_slots_at + 2 * rows * policy_hidden,
                .dchange_at = dchange_at,
                .dtotal = gradients_end,
                .w1 = w1,
                .w2 = w2,
                .w3 = w3,
                .param_count = world_params_end,
                .normed_world = normed_world,
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
            self.zeroHeadGradients();
            // The world model's own window (`world_steps`): its loss, and so its gradient, ends there.
            var step: u32 = self.world_steps;
            self.mse(step);
            self.weighLoss(step);
            var first: bool = true;
            while (step > 0) {
                step -= 1;
                const k: u32 = step;
                // Every step used the same weights: the last step's gradient written, every earlier one's added.
                const parameter_gradients: kit_mlp.ParameterGradients = if (first) .overwrite else .add;
                first = false;
                // Into the change, whose gradient is the next state's - in the network's own units. At the window's
                // first step nothing reads the gradient at the inputs: the first state is given, not predicted.
                const change_gradient: u32 = self.changeGradient(k + 1);
                const wants_inputs_gradient: bool = k > 0;
                self.worldBackward(k, change_gradient, parameter_gradients, wants_inputs_gradient);
                if (k == 0) {
                    break;
                }
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
            // The step that led to state k is step k - 1; a step that takes a share of its head's projection scales its
            // change's gradient by that share.
            const step_scale: f32 = self.stepScale(k - 1);
            if (step_scale != 1.0) {
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = self.features,
                    .x_off = self.blockDZ(k),
                    .y_off = self.dchange_at,
                    .lat_step_scale = step_scale,
                    .lat_increments_on = if (self.increments_at != null) 1 else 0,
                    .lat_increments_at = self.increments_at orelse 0,
                };
                self.pipe.run("lat_step_gradient", self.rows * self.features);
                return self.dchange_at;
            }
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
        /// Adam otherwise. Epsilon is scaled by `epsilon_scale` either way, the number of terms the gradient sums: a
        /// rollout's horizon (`policyTrainStep`), or 1 for one decision's (`policyLabelTrainStep`).
        fn stepPolicy(self: Self, rate: f32, t: u32, epsilon_scale: f32) void {
            const optimizer: kit_mlp.ClippedAdam = self.policy_optimizer orelse {
                self.adamPolicy(rate, t, epsilon_scale);
                return;
            };
            var settings: kit_mlp.ClippedAdam.Settings = self.policy_optimizer_settings;
            settings.learning_rate = rate;
            settings.epsilon = epsilon * epsilon_scale;
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
            // For the log: how far the rollout's states are from the goals, through the world model - and with the root
            // imagined, how far the root drifted from the reference's.
            self.recordStat("policy_tracking_loss", "stat_mean_square_difference", .{
                .rows = self.steps * self.rows * self.features,
                .x_off = self.z_at,
                .t_off = self.g_at,
            });
            if (self.imagined_root) |root| {
                self.recordRootDrift(root);
            }
            // The policy's Adam, as always - epsilon carrying the steps: the gradient is a sum over the horizon; and a
            // flow actor's: teacher 1's gradient when it learns from the rollout (`policyBackward` wrote it), the
            // others' written over it when none has been yet, else added, then its own optimiser's step on the sum -
            // none when no teacher had anything to teach.
            const horizon: f32 = @floatFromInt(self.steps);
            self.stepPolicy(rate, t, horizon);
            if (self.flow_actor) |flow_actor| {
                const dpg_wrote: bool = flow_actor.learnsFromRollout();
                const distillation_wrote: bool = self.distillFlow(flow_actor, dpg_wrote);
                const fpo_wrote: bool = self.fpoFlow(flow_actor, dpg_wrote or distillation_wrote);
                const gradient_written: bool = dpg_wrote or distillation_wrote or fpo_wrote;
                if (gradient_written) {
                    // With shares, the teachers' scaled sum is the gradient the step reads.
                    if (flow_actor.learningPart().shares) |shares| {
                        shares.finish(M, self.pipe);
                    }
                    flow_actor.optimizerStep(self.pipe, t);
                }
            }
        }

        /// ONE TRAINING STEP OF THE POLICY ON LABELS, its windows staged and gathered - each starting at a labelled
        /// record, one step long: the labels' gradient (`labelBackward`), their loss for the log, and the policy's
        /// optimiser step. The gradient is one decision's mean, not a horizon's sum, so epsilon is taken as it is. A
        /// flow actor is no part of the step: the labels teach the policy's own action.
        pub fn policyLabelTrainStep(
            self: Self,
            rate: f32,
            t: u32,
            label_weight: f32,
        ) void {
            self.labelBackward(label_weight);
            self.recordStat("policy_label_loss", "stat_label_loss", self.labelInputs());
            const one_decision: f32 = 1.0;
            self.stepPolicy(rate, t, one_decision);
        }

        /// WHERE A LABEL STEP's ROWS ARE STAGED (`policyLabelTrainStep`, `policyModeTrainStep`): each row's goal and
        /// state at the start of its first wide row - `width` apart - and the action applied before it, packed
        /// [rows][actions]. A gather of labels' windows fills them; so can a batch drawn straight into them.
        pub const LabelRows = struct {
            conditions_at: u32,
            condition_stride: u32,
            applied_at: u32,
        };

        pub fn labelRows(self: Self) LabelRows {
            const first_decision: u32 = 0;
            return .{
                .conditions_at = self.blockX(first_decision),
                .condition_stride = self.width,
                .applied_at = self.appliedBeforeAt(first_decision),
            };
        }

        /// THE FLOW's STEP ON THE PLANS ALONE, outside a rollout: teacher 2's gradient on its batch (`distillFlow`) and
        /// the flow's optimiser step - the turn a label update gives it. Nothing without a flow that learns, or
        /// without a batch.
        pub fn flowPlansStep(self: Self, t: u32) void {
            const flow_actor: FlowActor(M) = self.flow_actor orelse return;
            if (flow_actor.learning == null) {
                return;
            }
            const earlier_wrote: bool = false;
            if (!self.distillFlow(flow_actor, earlier_wrote)) {
                return;
            }
            if (flow_actor.learningPart().shares) |shares| {
                shares.finish(M, self.pipe);
            }
            flow_actor.optimizerStep(self.pipe, t);
        }

        /// ONE TRAINING STEP OF THE POLICY ON THE FLOW's MAIN MODE - the plans' answer, which the policy is to make
        /// its own (`robot_track_resident.LabelTarget.flow_mode`). Its rows staged as a label step's (`labelRows`):
        ///
        ///     the flow      teacher 2's step (`distillFlow`), its batch's targets already taken against the base, and
        ///                   the flow's optimiser step - so the flow learns the plans where the policy learns from it
        ///     the target    the base's raw action - `base`, the kit reading the flow's base - plus the flow's sample
        ///                   from the centre of its noise, decoded: base(s) + B^T F(s, 0), into `targets_at`
        ///                   [rows][actions]
        ///     the policy    its raw action toward the target - the mean squared distance times `mode_weight`
        ///                   (`mse_bwd`) - back through its layers, and its optimiser's step
        ///
        /// The flow learns every way back the plans took, each from its share of the noise; run from the noise's
        /// centre it lands in the heavier of them - where the plans for a situation split unevenly, the side more of
        /// them took, not the average a squared distance to every plan would give. The target is in raw actions, so
        /// the policy is matched where it answers, before the action filter.
        pub fn policyModeTrainStep(
            self: Self,
            base: Self,
            targets_at: u32,
            rate: f32,
            t: u32,
            mode_weight: f32,
        ) void {
            assertf(self.actsWithPolicy(), @src(), "the flow's mode teaches a policy: this kit has none", .{});
            assertf(self.flow_actor != null, @src(), "the flow's mode needs a flow", .{});
            const flow_actor: FlowActor(M) = self.flow_actor.?;
            // 1  The flow learns the plans first, so its mode is the freshest.
            self.flowPlansStep(t);
            // 2  The target: the base's answer, plus the flow's sample from its noise's centre decoded.
            const first_decision: u32 = 0;
            const raw: u32 = self.policyBlocks(first_decision).raw;
            const action_count: u32 = self.actions;
            base.policyLayers(first_decision);
            const answers: kit_mlp.RowColumns = .packedRows(raw, action_count);
            const targets: kit_mlp.RowColumns = .packedRows(targets_at, action_count);
            kit_mlp.copyColumns(M, self.pipe, self.rows, action_count, answers, targets);
            const correction: FlowActor(M).Correction = flow_actor.correction;
            const noise_centre: f32 = 0;
            const no_seed: u32 = 0;
            self.flowSample(flow_actor, first_decision, noise_centre, no_seed, flow_actor.coefficients_at);
            self.pipe.params = .{
                .rows = self.rows,
                .count = correction.synergy_count,
                .out_dim = action_count,
                .x_off = flow_actor.coefficients_at,
                .w_off = correction.synergies_at,
                .y_off = targets_at,
            };
            self.pipe.run("synergy_decode_add", self.rows * action_count);
            // 3  The live policy toward it, through its layers, and its step - one decision's mean.
            self.policyLayers(first_decision);
            self.pipe.params = .{
                .rows = self.rows,
                .out_dim = action_count,
                .y_off = raw,
                .t_off = targets_at,
                .dy_off = self.draw_at,
                .loss_weight = mode_weight,
            };
            self.pipe.run("mse_bwd", self.rows * action_count);
            const written_afresh: u32 = 0;
            self.policyLayersBackward(first_decision, written_afresh);
            self.recordStat("policy_label_loss", "stat_mean_square_difference", .{
                .rows = self.rows * action_count,
                .x_off = raw,
                .t_off = targets_at,
            });
            const one_decision: f32 = 1.0;
            self.stepPolicy(rate, t, one_decision);
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
                // Its encoding is the dense model's second hidden layer, a block per step (`h2_at`).
                const reads_dense_layers: bool = self.normed_world == null;
                assertf(reads_dense_layers, @src(), "the skip model reads the dense world model's layers", .{});
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
            // The round's tally: the length and the clip's factor beside it (`kit_mlp.ClippedAdam.reserve`).
            const tally_continues: u32 = if (self.gradient_tally_restarts) 0 else 1;
            self.recordStat("world_updates_in_round", "stat_gradient_tally", .{
                .x_off = optimizer.norm_offset,
                .accumulate = tally_continues,
            });
        }

        /// THE WORLD MODEL MEASURED FOR ITS GATE (`DeviceStats.gate_*`), on gathered windows that set out in pairs -
        /// rows 2p and 2p + 1 from one state, with different actions - after `forwardRecorded` has rolled it open loop
        /// over them on their recorded actions:
        ///
        ///     its error            its predictions against the recorded states, every step, per number
        ///     the no-change error  every recorded state against its window's first (`stat_no_change_error`) - the
        ///                          baseline: a model worth its gradient is far below it
        ///     its answer to an     each pair's change between its two predictions against the physics' change
        ///     action               between its two recorded states, pooled (`stat_pair_response`): the cosine and
        ///                          the length ratio after the first step, and at the last
        ///
        /// The two errors in the loss's own units when the kit weighs its features (`loss_weights_at`) - each square
        /// weighed by its feature's loss weight, as `world_loss` is: the clips' units leave the gate. Nothing without a
        /// stats block.
        pub fn recordWorldModelGate(self: Self) void {
            const window_numbers: u32 = self.world_steps * self.rows * self.features;
            const weighs: u32 = if (self.loss_weights_at != null) 1 else 0;
            const weights_at: u32 = self.loss_weights_at orelse 0;
            self.recordStat("gate_world_error", "stat_mean_square_difference", .{
                .rows = window_numbers,
                .count = self.features,
                .x_off = self.z_at,
                .t_off = self.t_at,
                .u_off = weights_at,
                .stat_weights_on = weighs,
            });
            const first_states_at: u32 = self.blockX(0) + self.lead;
            self.recordStat("gate_no_change_error", "stat_no_change_error", .{
                .rows = self.rows,
                .count = self.features,
                .lat_steps = self.world_steps,
                .x_off = first_states_at,
                .stride = self.width,
                .t_off = self.t_at,
                .u_off = weights_at,
                .stat_weights_on = weighs,
            });
            const first_step: u32 = 1;
            self.recordStat("gate_first_response_cosine", "stat_pair_response", .{
                .rows = self.rows,
                .count = self.features,
                .x_off = self.blockZ(first_step),
                .t_off = self.blockT(first_step),
            });
            const last_step: u32 = self.world_steps;
            self.recordStat("gate_last_response_cosine", "stat_pair_response", .{
                .rows = self.rows,
                .count = self.features,
                .x_off = self.blockZ(last_step),
                .t_off = self.blockT(last_step),
            });
        }

        /// The world model's loss for the log (`DeviceStats.world_model_loss`): its predictions against the recorded
        /// states over the whole window - the same arithmetic on the same numbers as the page's `loss`. On a one-step
        /// batch, beside it, the same predictions in the loss's own units (`world_loss` and the seven after it,
        /// `zn_mlp.stat_world_loss_in_units`), when the kit weighs its features and knows their kinds. After
        /// `forwardRecorded`; nothing without a stats block.
        pub fn recordWorldModelLoss(self: Self) void {
            const inputs: M.Params = .{
                .rows = self.world_steps * self.rows * self.features,
                .x_off = self.z_at,
                .t_off = self.t_at,
            };
            // The skip head's batches are logged apart from the one-step model's.
            switch (self.batch_kind) {
                .one_step => {
                    self.recordStat("world_model_loss", "stat_mean_square_difference", inputs);
                    self.recordWorldLossInUnits();
                },
                .skip => self.recordStat("skip_head_loss", "stat_mean_square_difference", inputs),
                .skip_consistency => self.recordStat("skip_consistency_loss", "stat_mean_square_difference", inputs),
            }
        }

        /// THE WORLD MODEL's LOSS IN ITS OWN UNITS for the log (`DeviceStats.world_loss` to `world_loss_up`): the
        /// rollout's predictions against the recorded states, each feature's error weighed by its loss weight, as the
        /// window's mean step, its last step and by kind of feature. Nothing without loss weights or the kinds' table.
        fn recordWorldLossInUnits(self: Self) void {
            const loss_weights_at: u32 = self.loss_weights_at orelse return;
            const feature_kinds_at: u32 = self.feature_kinds_at orelse return;
            self.recordStat("world_loss", "stat_world_loss_in_units", .{
                .rows = self.rows,
                .count = self.features,
                .lat_steps = self.world_steps,
                .x_off = self.z_at,
                .t_off = self.t_at,
                .u_off = loss_weights_at,
                .z_off = feature_kinds_at,
            });
        }

        /// THE POLICY's LAYERS, BACKWARD, AT DECISION k: from the raw action's gradient (`draw_at`) to every layer's
        /// weight gradients - written, or added to what the gradients hold (`accumulate`: 1, 0) - through the two
        /// hidden layers, whose gradients are left in `dph2_at` and `dph1_at`. The first layer's is there for whoever
        /// carries it further: a rollout sends it on into the state and into the action applied before
        /// (`policyBackward`); a label's stops here (`labelBackward`). The block reading the applied action takes a
        /// gradient only where it is trained (`sees_applied`).
        fn policyLayersBackward(self: Self, k: u32, accumulate: u32) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            const hp: u32 = self.policy_hidden;
            const policy_inputs: u32 = self.lead + self.features;
            const blocks: PolicyBlocks = self.policyBlocks(k);
            const weights: PolicyWeights = self.policyWeights();
            self.weightGrads(blocks.hidden2, 0, hp, self.actions, self.draw_at, weights.third, accumulate);
            self.inputGrads(hp, self.actions, self.draw_at, weights.third, self.dph2_at);
            self.activationGrads(blocks.hidden2, self.dph2_at, tanh, hp);
            self.weightGrads(blocks.hidden1, 0, hp, hp, self.dph2_at, weights.second, accumulate);
            self.inputGrads(hp, hp, self.dph2_at, weights.second, self.dph1_at);
            self.activationGrads(blocks.hidden1, self.dph1_at, tanh, hp);
            self.weightGrads(self.blockX(k), self.width, policy_inputs, hp, self.dph1_at, weights.first, accumulate);
            // The block reading the action applied before decision k: its weights' gradient.
            if (self.sees_applied) {
                const applied_before_at: u32 = self.appliedBeforeAt(k);
                const applied_before_stride: u32 = self.appliedBeforeStride(k);
                const actions: u32 = self.actions;
                const first_layer_gradient: u32 = self.dph1_at;
                self.weightGrads(
                    applied_before_at,
                    applied_before_stride,
                    actions,
                    hp,
                    first_layer_gradient,
                    weights.applied,
                    accumulate,
                );
            }
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
        /// a block `lead + features` wide (a third width, beside `width` and `inputs`). With a root imagined, a
        /// fifth: the root targets of every later decision, through the root its velocities moved
        /// (`imaginedRootBackward`).
        pub fn policyBackward(self: Self) void {
            const hp: u32 = self.policy_hidden;
            const policy_inputs: u32 = self.lead + self.features;
            var step: u32 = self.steps;
            // The action filter carries each decision's whole gradient to the one before: zero before the last.
            const filtering: bool = self.filter < 1.0 or self.stiffness_filter < 1.0;
            if (filtering) {
                self.pipe.params = .{ .rows = self.rows * self.actions, .y_off = self.filter_carry_at };
                self.pipe.run("zero_gradient_rows", self.rows * self.actions);
            }
            // The policy's reading of each applied action sends gradient to the decision before: none to the last.
            self.pipe.params = .{ .rows = self.rows * self.actions, .y_off = self.applied_gradient_at };
            self.pipe.run("zero_gradient_rows", self.rows * self.actions);
            // The root's gradient, carried from each decision to the one before: none past the last.
            if (self.imagined_root) |root| {
                const carried_floats: u32 = self.rows * M.lat_root_gradient_numbers;
                self.pipe.params = .{ .rows = carried_floats, .y_off = root.carriedGradientAt() };
                self.pipe.run("zero_gradient_rows", carried_floats);
            }
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
            // And the root's cost there, back through the step that moved the root: no policy step reads its target.
            if (self.imagined_root) |root| {
                const read_by_policy: bool = false;
                self.imaginedRootBackward(root, step, read_by_policy);
            }
            var first: bool = true;
            while (step > 0) {
                step -= 1;
                const k: u32 = step;
                // The world model, frozen: input gradients only, down to its wide-row slice - the action columns'
                // reach the policy at every step, the first included.
                const wants_inputs_gradient: bool = true;
                self.worldBackward(k, self.changeGradient(k + 1), .none, wants_inputs_gradient);
                // The action columns' gradient, back to the policy's raw output - plus the price.
                const step_actions: u32 = self.rows * self.actions;
                const raw: u32 = self.policyBlocks(k).raw;
                const action_gradient_at: u32 = self.dx_at + self.features + self.references;
                // The action price and the smoothness, each a mean over the step's numbers: d/dx of w x^2 is 2 w x.
                const step_action_count: f32 = float(step_actions);
                const penalty_coefficient: f32 = 2.0 * self.w_action / step_action_count;
                const smooth_coefficient: f32 = 2.0 * self.w_smooth / step_action_count;
                // A missing neighbour is this step itself: raw - raw, exactly zero.
                const has_previous_step: bool = k > 0;
                const has_next_step: bool = k + 1 < self.steps;
                const previous_raw: u32 = if (has_previous_step) raw - step_actions else raw;
                const next_raw: u32 = if (has_next_step) raw + step_actions else raw;
                self.pipe.params = .{
                    .rows = self.rows,
                    .count = self.actions,
                    .stride = self.inputs,
                    .dx_off = action_gradient_at,
                    .x_off = raw,
                    .dy_off = self.draw_at,
                    .lat_scale = self.action_scale,
                    .lat_penalty = penalty_coefficient,
                    .lat_smooth = smooth_coefficient,
                    .lat_prev = previous_raw,
                    .lat_next = next_raw,
                    .lat_filter = self.filter,
                    .lat_stiffness_filter = self.stiffness_filter,
                    .lat_stiffness_count = self.stiffness_count,
                    .lat_carry = self.filter_carry_at,
                    .lat_applied_gradient = self.applied_gradient_at,
                };
                self.pipe.run("lat_act_bwd", self.rows * self.actions);
                // A flow actor keeps the raw action's gradient projected onto its synergies, as its training row's
                // cost gradient; the policy then takes the gradient as it always does.
                if (self.flow_actor) |flow_actor| {
                    if (flow_actor.learnsFromRollout()) {
                        self.keepFlowCostGradient(flow_actor, k);
                    }
                }
                // The policy: weight gradients accumulated across the steps (`policyLayersBackward`), input gradients
                // down.
                const accumulate: u32 = if (first) 0 else 1;
                first = false;
                self.policyLayersBackward(k, accumulate);
                // The gradient the block reading the action applied before decision k sends that action - decision
                // k-1's - which step k-1's `lat_act_bwd` adds in.
                const policy_weights: PolicyWeights = self.policyWeights();
                const is_first_decision: bool = k == 0;
                const applied_block: u32 = policy_weights.applied;
                if (is_first_decision) {
                    break;
                }
                if (self.sees_applied) {
                    self.inputGrads(self.actions, hp, self.dph1_at, applied_block, self.applied_gradient_at);
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
                // And the root's: decision k's root target and the root's cost at state k, with every later state's,
                // back through the root.
                if (self.imagined_root) |root| {
                    const read_by_policy: bool = true;
                    self.imaginedRootBackward(root, k, read_by_policy);
                }
            }
            // The flow learns from every (step, row) of the rollout at once, its cost gradients now all kept.
            if (self.flow_actor) |flow_actor| {
                if (flow_actor.learnsFromRollout()) {
                    self.flowTrainingGradient(flow_actor);
                }
            }
        }

        /// WHAT THE LABELS' KERNELS READ (`zn_mlp.lat_label_bwd`, `stat_label_loss`), at the gathered windows' first
        /// decision: the policy's raw output there; the label - the recorded action, in the first wide row's action
        /// columns; and the action filter, with the action given before the window (its starting actions).
        fn labelInputs(self: Self) M.Params {
            const first_decision: u32 = 0;
            return .{
                .rows = self.rows,
                .count = self.actions,
                .x_off = self.policyBlocks(first_decision).raw,
                .t_off = self.actionColumns(first_decision),
                .stride = self.width,
                .lat_scale = self.action_scale,
                .lat_filter = self.filter,
                .lat_stiffness_filter = self.stiffness_filter,
                .lat_stiffness_count = self.stiffness_count,
                .lat_prev_action = self.appliedBeforeAt(first_decision),
                .lat_prev_action_stride = self.appliedBeforeStride(first_decision),
            };
        }

        /// THE POLICY's GRADIENT FROM LABELS - behaviour cloning. A LABEL is an action recorded where a teacher acted
        /// (a planner following its plan), kept with the state it was taken from: the first record of a gathered
        /// window. After the gather of windows that start at labelled records - one step each is enough - the kit's
        /// blocks hold all the pass reads:
        ///
        ///     the first wide row      [ goal | state | reference | the recorded action ]      the label is its action
        ///     the starting actions    the action given before the window: the action filter blends into it, and
        ///                             the policy reads it
        ///
        /// The policy's layers run on each row's goal and state (`policyLayers`). The loss is how far the action the
        /// policy would give there - its raw output scaled, through the action filter, with no exploration and no
        /// correction - is from the label: the mean of their squared distance over every row and action number, times
        /// `label_weight` (`zn_mlp.lat_label_bwd`). Its gradient goes back through the policy's layers into the
        /// policy's weight gradients, written afresh (`policyLayersBackward`). Nothing is rolled and the world model
        /// is not read: a policy can learn this way before any world model is good.
        pub fn labelBackward(self: Self, label_weight: f32) void {
            assertf(self.actsWithPolicy(), @src(), "labels teach a policy: this kit has none", .{});
            const first_decision: u32 = 0;
            self.policyLayers(first_decision);
            var gradient_inputs: M.Params = self.labelInputs();
            gradient_inputs.dy_off = self.draw_at;
            gradient_inputs.loss_weight = label_weight;
            self.pipe.params = gradient_inputs;
            self.pipe.run("lat_label_bwd", self.rows * self.actions);
            const written_afresh: u32 = 0;
            self.policyLayersBackward(first_decision, written_afresh);
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
            // The parts, packed: each example's four feature parts - each goal's features, each state - each into its
            // half of the critic's goals or states.
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

        /// TEACHER 3's gradient (`FlowActor.Fpo`), when the round's batch holds examples: FPO's update on the round's
        /// draws (`KitFlow.fpoGradient`) - the new losses on the same rows at the current weights, PPO's clipped
        /// surrogate with the normalised advantages - at teacher 3's weight, added to the flow's gradients when an
        /// earlier teacher wrote them (`earlier_wrote`), written over them otherwise. Whether it wrote.
        fn fpoFlow(self: Self, flow_actor: FlowActor(M), earlier_wrote: bool) bool {
            const learning: FlowActor(M).Learning = flow_actor.learningPart();
            const fpo: FlowActor(M).Fpo = learning.fpo orelse return false;
            if (!fpo.has_batch) {
                return false;
            }
            const update: FlowActor(M).Fpo.Update = fpo.update.?;
            const fpo_numbers: kit_mlp.KitFlow(M).FpoNumbers = .{
                .old_losses_at = update.old_losses_at,
                .new_losses_at = update.new_losses_at,
                .advantages_at = update.advantages_at,
            };
            const flow: kit_mlp.KitFlow(M) = flow_actor.flow;
            const overwrites: bool = learning.shares != null or !earlier_wrote;
            const writes: kit_mlp.ParameterGradients = if (overwrites) .overwrite else .add;
            flow.fpoGradient(self.pipe, update.trainer, update.draws, fpo_numbers, fpo.clip, fpo.weight, writes);
            if (learning.shares) |shares| {
                shares.absorb(M, self.pipe, fpo.weight, !earlier_wrote);
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
            return true;
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
            const condition_width: u32 = fpo.goal_width + fpo.features;
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

        /// TEACHER 2's gradient (`FlowActor.Distillation`), when the round's batch holds examples: the batch's
        /// conditions into the trainer's wide rows, each row's noise and flow time hashed from this update's seed (at
        /// step numbers past those the rollout and FlowDPG use), and the flow matching gradient at the distillation's
        /// weight - added to the flow's gradients when teacher 1 wrote them (`earlier_wrote`), written over them
        /// otherwise. Whether it wrote.
        fn distillFlow(self: Self, flow_actor: FlowActor(M), earlier_wrote: bool) bool {
            const learning: FlowActor(M).Learning = flow_actor.learningPart();
            const distillation: FlowActor(M).Distillation = learning.distillation orelse return false;
            if (!distillation.has_batch) {
                return false;
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
            // Written over the flow's gradients and absorbed at its share when the teachers share the update, or when
            // no teacher wrote before it; added to teacher 1's otherwise.
            const overwrites: bool = learning.shares != null or !earlier_wrote;
            const writes: kit_mlp.ParameterGradients = if (overwrites) .overwrite else .add;
            flow.flowMatchingGradient(self.pipe, trainer, distillation.weight, writes);
            if (learning.shares) |shares| {
                shares.absorb(M, self.pipe, distillation.weight, !earlier_wrote);
                self.recordStat("flow_distill_weight_gradient", "stat_copy", .{ .x_off = shares.factor_offset });
            }
            // For the log: how far the flow's velocity is from the plans' paths.
            self.recordStat("distillation_loss", "stat_mean_square_difference", .{
                .rows = trainer.rows * flow.action_width,
                .x_off = trainer.application.outputsOffset(),
                .t_off = trainer.path_velocities_at,
            });
            return true;
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
                .loss_weight = self.stepDecisions(k),
            };
            self.pipe.run("mse_bwd", self.rows * self.features);
        }

        /// THE DECISIONS THE STEP REACHING STATE k SPANS - 1, or the skip head's for a step of it (`skips`): the weight
        /// of the cost charged at state k in the policy's loss, so a step of 4 decisions costs as 4 single steps
        /// ending where it does would, each at the cost of its end. The window's loss is then a sum over decisions.
        fn stepDecisions(self: Self, k: u32) f32 {
            return float(self.skipAt(k - 1));
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

        /// Where the feature normaliser is - what the failure barrier reads to put its margins in the world's units,
        /// and the root in imagination to take its velocities out of the normaliser's. The learner must have placed it
        /// (`norm_at`) before turning either on.
        pub fn normaliserOffset(self: Self) u32 {
            const has_normaliser: bool = self.norm_at != null;
            const reason: []const u8 = "the barrier and the imagined root read the normaliser: place it (norm_at)";
            assertf(has_normaliser, @src(), "{s}", .{reason});
            return self.norm_at.?;
        }

        /// Step k's failure barrier, added into its state gradient (`lat_barrier_bwd`) - nothing at weight 0.
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
                .barrier_weight = barrier.weight * self.stepDecisions(k),
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
            // In tiles (`zn_mlp.dense_bwd_w_tiled`): the weights' rows and the bias's as one more.
            const invocations: u32 = M.denseTiledInvocations(in_dim + 1, out_dim);
            self.pipe.run("dense_bwd_w_tiled", invocations);
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
            // In tiles (`zn_mlp.dense_bwd_x_tiled`).
            const invocations: u32 = M.denseTiledInvocations(self.rows, in_dim);
            self.pipe.run("dense_bwd_x_tiled", invocations);
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
            // The eight tensors are the dense model's; the normed form takes a zimrnum network instead
            // (`NormedWorld.writeParams`).
            const dense_world: bool = self.normed_world == null;
            const no_dense_tensors: []const u8 = "packWeights: a dense model's tensors for a normed world model";
            assertf(dense_world, @src(), no_dense_tensors, .{});
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
        /// and the row puts the GOAL first, so they are stacked goal block, then state block. The applied action's
        /// block after them at ZERO: a policy that does not yet read the action it applies
        /// (`packPolicyWithApplied`).
        pub fn packPolicy(self: Self, params: [7]Tensor, out: []f32) void {
            self.packPolicyWithApplied(params, null, out);
        }

        /// `packPolicy`, with the applied action's block given (`actions x policy_hidden`, the CPU learner's
        /// `AppliedRow.weights`), or zero when none is.
        pub fn packPolicyWithApplied(
            self: Self,
            params: [7]Tensor,
            applied_block: ?[]const f32,
            out: []f32,
        ) void {
            assertf(out.len == self.policy_count, @src(), "packPolicy: {d} floats given, the layout holds {d}", .{
                out.len,
                self.policy_count,
            });
            var at: usize = 0;
            for ([_]usize{ 1, 0, 2, 3, 4, 5, 6 }) |i| {
                @memcpy(out[at..][0..params[i].data.len], params[i].data);
                at += params[i].data.len;
            }
            const block_size: usize = self.actions * self.policy_hidden;
            const block_out: []f32 = out[at..][0..block_size];
            if (applied_block) |given| {
                @memcpy(block_out, given);
            } else {
                @memset(block_out, 0);
            }
            at += block_size;
            assertf(at == self.policy_count, @src(), "packPolicy: tensors hold {d} floats, layout {d}", .{
                at,
                self.policy_count,
            });
        }

        /// Where the policy's three layers keep their weights in `params` (`packPolicy`): the first over the goal and
        /// the state, `(lead + features) x policy_hidden` then its bias; the second, `policy_hidden` square then its
        /// bias; the third, `policy_hidden x actions` then its bias.
        pub const PolicyWeights = struct {
            first: u32,
            second: u32,
            third: u32,
            /// The applied action's block, `actions x policy_hidden`, after the third layer's bias: the policy's view
            /// of the action applied before its decision, summed into the first layer (`applied_add_activate`).
            applied: u32,
        };

        pub fn policyWeights(self: Self) PolicyWeights {
            const hp: u32 = self.policy_hidden;
            const first: u32 = self.p_at;
            const second: u32 = first + (self.lead + self.features) * hp + hp;
            const third: u32 = second + hp * hp + hp;
            const applied: u32 = third + hp * self.actions + self.actions;
            return .{ .first = first, .second = second, .third = third, .applied = applied };
        }

        /// THE POLICY ACTING ON ROWS OF ITS OWN - one row per simulated world rather than the kit's training rows:
        /// each row's goal and state (`lead + features` numbers, `input_stride` apart: the simulator pads its rows,
        /// `policy_inputs`), its two hidden layers, and its raw actions (`actions` numbers, `raw_stride` apart, the
        /// simulator's action rows). Reserved after the kit's own regions (`reservePolicyRows`).
        pub const PolicyRows = struct {
            rows: u32,
            input_stride: u32,
            raw_stride: u32,
            inputs_at: u32,
            hidden1_at: u32,
            hidden2_at: u32,
            raw_at: u32,
            /// The action applied before each row's decision, rows `raw_stride` apart as the simulator's actions are:
            /// what the policy's block reads (`applied_add_activate`) - for a simulated world, the action it was given
            /// at its previous decision.
            applied_at: u32,
        };

        /// Room in the activations for the policy to act on `rows` rows (`actOnRows`), its inputs and raw actions
        /// laid out with the given strides - each at least a row's numbers.
        pub fn reservePolicyRows(
            self: Self,
            layout: *kit_mlp.KitLayout,
            rows: u32,
            input_stride: u32,
            raw_stride: u32,
        ) PolicyRows {
            assertf(self.policy_hidden > 0, @src(), "a kit without a policy cannot act", .{});
            // A row's input: the goal's features, then the state's.
            const input_width: u32 = self.lead + self.features;
            const strides_hold_rows: bool = input_stride >= input_width and raw_stride >= self.actions;
            assertf(strides_hold_rows, @src(), "strides {d} and {d} for rows of {d} and {d}", .{
                input_stride,
                raw_stride,
                input_width,
                self.actions,
            });
            const policy_hidden_width: u32 = self.policy_hidden;
            const acting: PolicyRows = .{
                .rows = rows,
                .input_stride = input_stride,
                .raw_stride = raw_stride,
                .inputs_at = layout.reserveActs(rows * input_stride),
                .hidden1_at = layout.reserveActs(rows * policy_hidden_width),
                .hidden2_at = layout.reserveActs(rows * policy_hidden_width),
                .raw_at = layout.reserveActs(rows * raw_stride),
                .applied_at = layout.reserveActs(rows * raw_stride),
            };
            return acting;
        }

        /// The policy's raw actions for every row of `acting`: the three dense layers of its rollout's step
        /// (`policyStep`) - tanh, tanh, linear, the same weights - over packed rows. No correction and no exploration:
        /// those are added where the actions are written.
        pub fn actOnRows(self: Self, acting: PolicyRows) void {
            // The activations as the dense kernel takes them: the number of an `Act`.
            const tanh_activation: u32 = @backingInt(M.Act.tanh);
            const linear_activation: u32 = @backingInt(M.Act.linear);
            const policy_hidden_width: u32 = self.policy_hidden;
            // A row's input: the goal's features, then the state's - the order `policy_inputs` writes them in.
            const input_width: u32 = self.lead + self.features;
            const weights: PolicyWeights = self.policyWeights();
            const rows: u32 = acting.rows;
            // Rows wider than the policy's actions - a simulator's, with room for each limb's stiffness - are zeroed
            // first: the layers write the policy's numbers alone, so the rest are nothing, never what memory held.
            const raw_is_wider: bool = acting.raw_stride > self.actions;
            if (raw_is_wider) {
                const raw_numbers: u32 = rows * acting.raw_stride;
                self.pipe.params = .{ .rows = raw_numbers, .y_off = acting.raw_at };
                self.pipe.run("zero_rows", raw_numbers);
            }
            // The first layer: each row's goal and state, rows `input_stride` apart, into the first hidden layer -
            // linear, for the block reading the action applied before each row's decision is summed after them, and
            // only then the tanh (`applied_add_activate`), the rollout's own order.
            self.denseRows(
                rows,
                acting.inputs_at,
                acting.input_stride,
                input_width,
                policy_hidden_width,
                weights.first,
                acting.hidden1_at,
                0,
                linear_activation,
            );
            self.pipe.params = .{
                .rows = rows,
                .in_dim = self.actions,
                .out_dim = policy_hidden_width,
                .x_off = acting.applied_at,
                .stride = acting.raw_stride,
                .w_off = weights.applied,
                .y_off = acting.hidden1_at,
                .act = tanh_activation,
            };
            self.pipe.run("applied_add_activate", rows * policy_hidden_width);
            // The second: the first hidden layer into the second, both packed.
            self.denseRows(
                rows,
                acting.hidden1_at,
                0,
                policy_hidden_width,
                policy_hidden_width,
                weights.second,
                acting.hidden2_at,
                0,
                tanh_activation,
            );
            // The third: the second hidden layer into the raw actions, linear, rows `raw_stride` apart - the spacing of
            // the simulator's action rows, so one copy moves them all.
            self.denseRows(
                rows,
                acting.hidden2_at,
                0,
                policy_hidden_width,
                self.actions,
                weights.third,
                acting.raw_at,
                acting.raw_stride,
                linear_activation,
            );
        }

        /// THE POLICY ACTING FOR A SIMULATOR ON THE SAME DEVICE: every world's row of goal and state, written by the
        /// simulator one block world after world (`robotgpu.policy_inputs`), copied into the acting rows in one copy;
        /// the action each world was given at its previous decision (`given_at`, the simulator's actions) copied in
        /// as the action applied before this one, which the policy's block reads; the policy's layers (`actOnRows`);
        /// and its raw actions copied into the simulator's choices (`chosen_at`), again one block - the exploration
        /// and the action filter then make them the decision's actions (`robotgpu.give_program`). Every block's rows
        /// are laid out with the strides the acting rows were reserved with (`reservePolicyRows`).
        ///
        /// FOUR SUBMISSIONS: the two copies in, the layers' dispatches as ONE recording, and the copy out. Each
        /// copy is a submission of its own, and the device runs a queue's submissions in their order, so the layers
        /// read what the copies wrote and the copy out takes what they wrote. Unrecorded, every dispatch would be a
        /// submission too - a planner's lookahead chooses at each of its decisions, and the device would wait on
        /// the host between dispatches of microseconds.
        pub fn actWithSimulator(
            self: Self,
            acting: PolicyRows,
            simulator: compute_host.DeviceField,
            inputs_at: u32,
            given_at: u32,
            chosen_at: u32,
        ) void {
            const float_bytes: u32 = @sizeOf(f32);
            const kit_acts: compute_host.DeviceField = self.pipe.deviceField(.acts);
            const input_bytes: u32 = acting.rows * acting.input_stride * float_bytes;
            const input_from: u32 = inputs_at * float_bytes;
            const input_to: u32 = acting.inputs_at * float_bytes;
            compute_host.copyFieldBetween(simulator, input_from, kit_acts, input_to, input_bytes);
            const action_bytes: u32 = acting.rows * acting.raw_stride * float_bytes;
            const given_from: u32 = given_at * float_bytes;
            const applied_to: u32 = acting.applied_at * float_bytes;
            compute_host.copyFieldBetween(simulator, given_from, kit_acts, applied_to, action_bytes);
            self.pipe.beginRecording();
            self.actOnRows(acting);
            self.pipe.submitRecording();
            const action_from: u32 = acting.raw_at * float_bytes;
            const chosen_to: u32 = chosen_at * float_bytes;
            compute_host.copyFieldBetween(kit_acts, action_from, simulator, chosen_to, action_bytes);
        }

        /// THE FLOW's CORRECTION FOR ROWS OF THEIR OWN - the policy's acting rows (`PolicyRows`), one a simulated
        /// world: a flow actor that only acts, over those rows (`FlowActor.actingOnly`, one step); each row's drifting
        /// noise in the flow's synergies, kept from one decision to the next; and each row's correction decoded into
        /// the action's numbers, rows `raw_stride` apart as the simulator's action rows are, so one copy hands them
        /// all over. Reserved after the kit's own regions (`reserveFlowRows`).
        pub const FlowRows = struct {
            actor: FlowActor(M),
            noise_at: u32,
            corrections_at: u32,
        };

        /// One decision's draw of a flow's drifting noise (`correctOnRows`): the seed of its fresh normals, how much of
        /// itself the noise keeps (the Ornstein-Uhlenbeck correlation over a decision), and the acting's noise scale -
        /// 1 while training, 0 for the policy alone, whose flow then starts from zero, its typical correction.
        pub const FlowNoise = struct {
            seed: u32,
            correlation: f32,
            scale: f32,
        };

        /// A decision's flow correction to act with: the rows it corrects, and the decision's noise.
        pub const FlowActing = struct {
            rows: FlowRows,
            noise: FlowNoise,
        };

        /// Room for the flow's correction over the rows of `acting` (`FlowRows`), its sampler's regions reserved in
        /// `layout`, the noise zero. The kit must have a flow actor. Memory: `arena`, for the sampler's descriptors.
        pub fn reserveFlowRows(
            self: Self,
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            acting: PolicyRows,
        ) !FlowRows {
            assertf(self.flow_actor != null, @src(), "a kit without a flow actor has no correction to act with", .{});
            const one_step: u32 = 1;
            const actor: FlowActor(M) = try .actingOnly(arena, layout, self.flow_actor.?, acting.rows, one_step);
            const synergy_count: u32 = actor.correction.synergy_count;
            const flow_rows: FlowRows = .{
                .actor = actor,
                .noise_at = layout.reserveActs(acting.rows * synergy_count),
                .corrections_at = layout.reserveActs(acting.rows * acting.raw_stride),
            };
            return flow_rows;
        }

        /// THE FLOW's CORRECTION OF THE ROWS' ACTIONS (`FlowActor`), after the policy has acted on them (`actOnRows`),
        /// into `flow_rows.corrections_at` - the policy's raw actions untouched:
        ///
        ///     the condition    each row's [goal | state] from the acting rows into every block of the sampler
        ///     the noise        fresh standard normals (`hashed_noise`, `noise.seed`), folded into each row's
        ///                      drifting noise (`ou_noise_step`, `noise.correlation`), the noise times the acting's
        ///                      scale and the flow's own as the starting point - zero at a scale of zero, the noise
        ///                      left as it was
        ///     the sample       K Euler steps to k coefficients a row (`KitFlow.sample`)
        ///     the correction   B^T c a row, decoded into the action's numbers (`synergy_decode_strided`); the rest of
        ///                      each row zero
        ///
        /// What a CPU character's `correctedRow` computes from its own noise, for every row at once.
        pub fn correctOnRows(
            self: Self,
            acting: PolicyRows,
            flow_rows: FlowRows,
            noise: FlowNoise,
        ) void {
            const actor: FlowActor(M) = flow_rows.actor;
            const flow: kit_mlp.KitFlow(M) = actor.flow;
            const sampler: kit_mlp.KitFlow(M).Sampler = actor.sampler;
            const rows: u32 = acting.rows;
            const condition_width: u32 = self.lead + self.features;
            const flow_width: u32 = flow.wideRowWidth();
            const synergy_count: u32 = actor.correction.synergy_count;
            const acting_condition: kit_mlp.RowColumns = .{
                .offset = acting.inputs_at,
                .row_stride = acting.input_stride,
            };
            for (sampler.blocks_at) |block_at| {
                const block_condition: kit_mlp.RowColumns = .{ .offset = block_at, .row_stride = flow_width };
                kit_mlp.copyColumns(M, self.pipe, rows, condition_width, acting_condition, block_condition);
            }
            // The starting point: zero without noise (a draw at no spread), else the drifting noise one decision on.
            const draws_noise: bool = noise.scale != 0;
            const fresh_spread: f32 = if (draws_noise) 1.0 else 0.0;
            self.pipe.params = .{
                .rows = rows,
                .count = synergy_count,
                .y_off = sampler.blocks_at[0],
                .stride = flow_width,
                .col = flow.pointColumn(),
                .lat_sigma = fresh_spread,
                .lat_seed = noise.seed,
            };
            self.pipe.run("hashed_noise", rows * synergy_count);
            if (draws_noise) {
                self.pipe.params = .{
                    .rows = rows,
                    .count = synergy_count,
                    .x_off = flow_rows.noise_at,
                    .y_off = sampler.blocks_at[0],
                    .stride = flow_width,
                    .col = flow.pointColumn(),
                    .flow_noise_correlation = noise.correlation,
                    .flow_noise_scale = noise.scale * actor.correction.noise_scale,
                };
                self.pipe.run("ou_noise_step", rows * synergy_count);
            }
            flow.sample(self.pipe, sampler, .packedRows(actor.coefficients_at, synergy_count));
            const correction_numbers: u32 = rows * acting.raw_stride;
            self.pipe.params = .{ .rows = correction_numbers, .y_off = flow_rows.corrections_at };
            self.pipe.run("zero_rows", correction_numbers);
            self.pipe.params = .{
                .rows = rows,
                .count = synergy_count,
                .out_dim = self.actions,
                .x_off = actor.coefficients_at,
                .w_off = actor.correction.synergies_at,
                .y_off = flow_rows.corrections_at,
                .stride = acting.raw_stride,
            };
            self.pipe.run("synergy_decode_strided", rows * self.actions);
        }

        /// Where the action applied before decision `k` sits - the one the action filter blends into and the policy
        /// reads: decision `k - 1`'s action columns, or before the window its starting actions.
        fn appliedBeforeAt(self: Self, k: u32) u32 {
            const is_first_decision: bool = k == 0;
            return if (is_first_decision) self.start_actions_at else self.actionColumns(k - 1);
        }

        /// The rows' stride of `appliedBeforeAt`: the wide row's, or the starting actions' packed rows.
        fn appliedBeforeStride(self: Self, k: u32) u32 {
            const is_first_decision: bool = k == 0;
            return if (is_first_decision) self.actions else self.width;
        }

        /// Where decision `k`'s action sits: the action columns of its wide row, after the goal, the state and the
        /// reference.
        fn actionColumns(self: Self, k: u32) u32 {
            const row_start: u32 = self.blockX(k);
            const columns_before_action: u32 = self.lead + self.features + self.references;
            return row_start + columns_before_action;
        }

        /// Where decision k's policy blocks sit in the activations: its two hidden layers and its raw action, a block
        /// per decision each.
        const PolicyBlocks = struct {
            hidden1: u32,
            hidden2: u32,
            raw: u32,
        };

        fn policyBlocks(self: Self, k: u32) PolicyBlocks {
            const hidden_block: u32 = self.rows * self.policy_hidden;
            const raw_block: u32 = self.rows * self.actions;
            return .{
                .hidden1 = self.ph1_at + k * hidden_block,
                .hidden2 = self.ph2_at + k * hidden_block,
                .raw = self.raw_at + k * raw_block,
            };
        }

        /// THE POLICY's THREE LAYERS AT DECISION k: the row's [goal | state] slice and the action applied before the
        /// decision into the first hidden layer, that into the second, and the second into the raw action - each in
        /// decision k's block (`policyBlocks`). The first half of the policy's turn in a rollout (`policyStep`), and
        /// its whole forward pass where it learns from labels (`labelBackward`).
        fn policyLayers(self: Self, k: u32) void {
            const tanh: u32 = @backingInt(M.Act.tanh);
            const linear: u32 = @backingInt(M.Act.linear);
            const hp: u32 = self.policy_hidden;
            const blocks: PolicyBlocks = self.policyBlocks(k);
            const weights: PolicyWeights = self.policyWeights();
            // The policy's slice: the row's first `lead + features` columns - the goal and the state -
            // read with the row's full stride, so the reference and action columns beyond them are
            // simply not part of this layer's input. Its weights are stacked in that same order
            // (`packPolicy`), which is what makes one matrix multiply do the work of two.
            // The first layer's linear sum - the bias, the goal's terms, the state's - then the action applied before
            // this decision, through its own block, summed after them, and only then the tanh.
            const policy_inputs: u32 = self.lead + self.features;
            self.dense(self.blockX(k), self.width, policy_inputs, hp, weights.first, blocks.hidden1, linear);
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = self.actions,
                .out_dim = hp,
                .x_off = self.appliedBeforeAt(k),
                .stride = self.appliedBeforeStride(k),
                .w_off = weights.applied,
                .y_off = blocks.hidden1,
                .act = tanh,
            };
            self.pipe.run("applied_add_activate", self.rows * hp);
            self.dense(blocks.hidden1, 0, hp, hp, weights.second, blocks.hidden2, tanh);
            self.dense(blocks.hidden2, 0, hp, self.actions, weights.third, blocks.raw, linear);
        }

        /// The policy's turn at step k: its three layers over the row's [goal | state] slice (`policyLayers`), and
        /// its action written into the row's action columns - before the world model reads the row.
        fn policyStep(self: Self, k: u32) void {
            // A correction corrects a policy: without one there is nothing to correct. And it comes from one place.
            const has_flow: bool = self.flow_actor != null;
            const has_given: bool = self.given_corrections != null;
            const correction_without_policy: bool = (has_flow or has_given) and self.policy_hidden == 0;
            assertf(!correction_without_policy, @src(), "a correction corrects a policy: this kit has none", .{});
            assertf(!(has_flow and has_given), @src(), "corrections from a flow and given ones, both: one only", .{});
            self.policyLayers(k);
            const raw: u32 = self.policyBlocks(k).raw;
            // A correction - a flow's, or one given - added to the policy's raw action before the exploration and the
            // write.
            const flow_corrects: bool = if (self.flow_actor) |flow_actor| flow_actor.correctsRollout() else false;
            if (flow_corrects) {
                self.flowCorrection(self.flow_actor.?, k, raw);
            } else if (self.given_corrections) |given| {
                self.givenCorrection(given, k, raw);
            }
            // And the action into the row: `lat_act` scales the raw output (and adds this step's noise)
            // straight into the action columns the world model's layers will read next - the two
            // networks never exchange a buffer, only columns of one row.
            const action_columns_at: u32 = self.actionColumns(k);
            const step_seed: u32 = M.latStepSeed(self.seed, k);
            // The action before, for the action filter - the one the first layer read: the previous decision's
            // action columns in its wide row, or before the window its starting actions, packed one row after another.
            const previous_action_at: u32 = self.appliedBeforeAt(k);
            const previous_action_stride: u32 = self.appliedBeforeStride(k);
            self.pipe.params = .{
                .rows = self.rows,
                .count = self.actions,
                .stride = self.width,
                .x_off = raw,
                .y_off = action_columns_at,
                .lat_scale = self.action_scale,
                .lat_sigma = self.sigma,
                .lat_seed = step_seed,
                .lat_filter = self.filter,
                .lat_stiffness_filter = self.stiffness_filter,
                .lat_stiffness_count = self.stiffness_count,
                .lat_prev_action = previous_action_at,
                .lat_prev_action_stride = previous_action_stride,
            };
            self.pipe.run("lat_act", self.rows * self.actions);
        }

        /// Whether a policy acts in this kit's rollout (`policy_hidden` above 0) - with a flow actor's correction on
        /// top, when it has one.
        pub fn actsWithPolicy(self: Self) bool {
            return self.policy_hidden > 0;
        }

        /// THE FLOW's SAMPLE at step k's rows (`FlowActor`): each row's [goal | state] from the step's wide row into
        /// every block of the sampler, the flow's starting point into the first - its noise at `noise_scale`, hashed
        /// from `noise_seed`; at a scale of 0 the noise's centre, the same point for every row - and the K Euler
        /// steps' coefficients to `coefficients_at`, [rows][synergies].
        fn flowSample(
            self: Self,
            flow_actor: FlowActor(M),
            k: u32,
            noise_scale: f32,
            noise_seed: u32,
            coefficients_at: u32,
        ) void {
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
                .lat_sigma = noise_scale,
                .lat_seed = noise_seed,
            };
            self.pipe.run("hashed_noise", self.rows * synergy_count);
            flow.sample(self.pipe, sampler, .packedRows(coefficients_at, synergy_count));
        }

        /// The flow's CORRECTION at step k (`FlowActor`), added to the policy's raw action at `raw`: the flow's
        /// sample from its own noise (`flowSample`, at the correction's noise scale, from `flowNoiseSeed`) - k
        /// coefficients, kept with the step's (`coefficients_at`) - and their synergies decoded and added
        /// (`synergy_decode_add`): raw += B^T c.
        fn flowCorrection(self: Self, flow_actor: FlowActor(M), k: u32, raw: u32) void {
            const correction: FlowActor(M).Correction = flow_actor.correction;
            const synergy_count: u32 = correction.synergy_count;
            const step_coefficients_at: u32 = flow_actor.coefficients_at + k * self.rows * synergy_count;
            self.flowSample(flow_actor, k, correction.noise_scale, self.flowNoiseSeed(k), step_coefficients_at);
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

        /// THE ROOT AT STATE k IN IMAGINATION (k >= 1, `zn_mlp.lat_root_step`): moved from state k - 1's by the root
        /// velocities the world model predicted for state k - wide row k's state columns - over the step's span of
        /// decisions (`skipAt`); and below the last state, the root target the policy reads there, into the row's
        /// slots after its goal's features. At the last state, k = `steps`, the root alone: for its cost and the log.
        fn imaginedRootStep(self: Self, root: ImaginedRoot, k: u32) void {
            const span_seconds: f32 = float(self.skipAt(k - 1)) * root.decision_seconds;
            const row_at: u32 = self.blockX(k);
            self.pipe.params = .{
                .rows = self.rows,
                .lat_features = self.features,
                .lat_steps = self.steps,
                .x_off = row_at + self.lead,
                .y_off = row_at + self.features,
                .stride = self.width,
                .norm_off = self.normaliserOffset(),
                .lat_root_target = 1,
                .lat_roots_off = root.roots_at,
                .lat_goal_roots_off = root.goal_roots_at,
                .lat_root_decision = k,
                .lat_root_velocity_column = root.velocity_column,
                .lat_root_angular_column = root.angular_column,
                .lat_root_seconds = span_seconds,
            };
            self.pipe.run("lat_root_step", self.rows);
        }

        /// THE ROOT AT STATE k, BACKWARD (k >= 1, `zn_mlp.lat_root_bwd`), once state k's gradient has its other parts
        /// and, where a policy step read decision k's root target (`read_by_policy`: every state but the last), the
        /// policy's input gradient is in its slot (`dp_at`): the gradient that target sends the root, the root's cost
        /// at state k (`ImaginedRoot`), and the one carried from the states after, through the step that moved the
        /// root - into state k's root velocities, and on to the root before.
        fn imaginedRootBackward(
            self: Self,
            root: ImaginedRoot,
            k: u32,
            read_by_policy: bool,
        ) void {
            const span_seconds: f32 = float(self.skipAt(k - 1)) * root.decision_seconds;
            const row_at: u32 = self.blockX(k);
            // The cost's scale: the decisions the step spans, as the tracking terms weigh a state, over the rows.
            const cost_scale: f32 = self.stepDecisions(k) / float(self.rows);
            self.pipe.params = .{
                .rows = self.rows,
                .lat_features = self.features,
                .lat_lead = self.lead,
                .x_off = row_at + self.lead,
                .stride = self.width,
                .norm_off = self.normaliserOffset(),
                .dx_off = self.dp_at,
                .dy_off = self.blockDZ(k),
                .lat_root_target = 1,
                .lat_roots_off = root.roots_at,
                .lat_goal_roots_off = root.goal_roots_at,
                .lat_root_decision = k,
                .lat_root_velocity_column = root.velocity_column,
                .lat_root_angular_column = root.angular_column,
                .lat_root_seconds = span_seconds,
                .lat_root_gradient_off = root.carriedGradientAt(),
                .lat_root_position_weight = root.position_weight,
                .lat_root_rotation_weight = root.rotation_weight,
                .lat_root_cost_scale = cost_scale,
                .lat_root_read_by_policy = @intFromBool(read_by_policy),
            };
            self.pipe.run("lat_root_bwd", self.rows);
        }

        /// THE ROOT's DRIFT FOR THE LOG (`zn_mlp.lat_root_drift`, `DeviceStats.policy_root_drift`): after a rollout
        /// with the policy acting, the distance and the angle between the imagined root and the reference's at every
        /// rolled state, into the drift's block, then each one's mean and deviation into the device's statistics.
        /// Nothing without a block for it (`ImaginedRoot.drift_at`).
        fn recordRootDrift(self: Self, root: ImaginedRoot) void {
            const drift_at: u32 = root.drift_at orelse return;
            const drift_count: u32 = self.steps * self.rows;
            self.pipe.params = .{
                .rows = self.rows,
                .lat_steps = self.steps,
                .y_off = drift_at,
                .lat_roots_off = root.roots_at,
                .lat_goal_roots_off = root.goal_roots_at,
            };
            self.pipe.run("lat_root_drift", drift_count);
            self.recordStat("policy_root_drift", "stat_mean_and_deviation", .{
                .rows = drift_count,
                .x_off = drift_at,
            });
            self.recordStat("policy_root_turn", "stat_mean_and_deviation", .{
                .rows = drift_count,
                .x_off = drift_at + drift_count,
            });
        }

        fn rollout(self: Self, acting: bool) void {
            // The policy's horizon when it acts; the world model's own window on the recorded actions.
            const rollout_steps: u32 = if (acting) self.steps else self.world_steps;
            for (0..rollout_steps) |step| {
                const k: u32 = @intCast(step);
                // When acting, the policy goes first: its action is what the world model's step reads - after the root
                // it imagines has moved to this decision, and its target is in the row the policy reads.
                if (acting) {
                    const moves_root: bool = k > 0 and self.imagined_root != null;
                    if (moves_root) {
                        self.imaginedRootStep(self.imagined_root.?, k);
                    }
                    self.policyStep(k);
                }
                const change: u32 = self.worldForward(k);
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
                    .lat_step_scale = self.stepScale(k),
                };
                self.pipe.run("lat_advance", self.rows * self.features);
            }
            // The root at the last state, which no policy step reads: what its cost and the log measure there.
            if (acting) {
                if (self.imagined_root) |root| {
                    self.imaginedRootStep(root, rollout_steps);
                }
            }
        }

        /// Step k's skip, in decisions (`skips`): 1 past the schedule's end, and for every step of an empty one;
        /// otherwise 1 or the skip head's.
        pub fn skipAt(self: Self, k: u32) u32 {
            if (k >= self.skips.len) {
                return 1;
            }
            const skip: u32 = self.skips[k];
            const has_head: bool = skip == 1 or (self.heads.hasSkipHead() and skip == self.heads.skip_steps);
            assertf(has_head, @src(), "step {d}'s skip of {d}: no head takes it", .{ k, skip });
            return skip;
        }

        /// The last layer step k takes: the one-step head's, or the skip head's for a step of its skip.
        fn headWeights(self: Self, k: u32) u32 {
            return if (self.skipAt(k) == 1) self.w3 else self.w4;
        }

        /// THE SHARE OF ITS HEAD's OUTPUT A STEP ADDS TO THE STATE (`zn_mlp.lat_advance`). One head: 1, the output
        /// the change. Two: the output is the projection's offset P - z, the state `projection_steps` = K decisions on
        /// less the state, and a step of k decisions reaches lerp(z, P, k / K) = z + (k / K)(P - z). With the change
        /// in units of the typical change per decision (`increments_at`) the offset is K x (mean + spread x output),
        /// so the share of (mean + spread x output) is k itself.
        pub fn stepScale(self: Self, k: u32) f32 {
            if (!self.heads.hasSkipHead()) {
                return 1.0;
            }
            const skip: f32 = float(self.skipAt(k));
            if (self.increments_at != null) {
                return skip;
            }
            return skip / float(self.heads.projection_steps);
        }

        /// The mean squared difference, per number, between `rows` x `features` states at acts `states_at` and as many
        /// at `recorded_at`, into the device's statistic `field` (`DeviceStats`).
        pub fn recordStatesDifference(
            self: Self,
            comptime field: []const u8,
            states_at: u32,
            recorded_at: u32,
        ) void {
            self.recordStat(field, "stat_mean_square_difference", .{
                .rows = self.rows * self.features,
                .x_off = states_at,
                .t_off = recorded_at,
            });
        }

        /// THE SAME KIT READING THE POLICY's WEIGHTS FROM `weights_at` - a copy of them elsewhere in the parameters,
        /// laid out as the kit's own (the learner's slow average of the policy, `Resident.policy_average_at`). For
        /// the policy's forward passes alone - acting on rows (`actOnRows`), a planner's rollouts: its updates and
        /// gradients belong to the live weights, and a copy that read the average would train the average.
        pub fn withPolicyWeightsAt(self: Self, weights_at: u32) Self {
            var reading_copy: Self = self;
            reading_copy.p_at = weights_at;
            return reading_copy;
        }

        /// THE SAME KIT READING THE WORLD MODEL's WEIGHTS FROM `weights_at` - a copy of them elsewhere in the
        /// parameters, laid out as the kit's own (the learner's slow average of the world model,
        /// `Resident.world_average_at`): its blocks and everything else the kit's, so a rollout of it overwrites the
        /// kit's activations. The dense form only.
        pub fn withWorldWeightsAt(self: Self, weights_at: u32) Self {
            assertf(self.normed_world == null, @src(), "a copy of the world model's weights: the dense form only", .{});
            var reading_copy: Self = self;
            reading_copy.w1 = self.w1 + weights_at;
            reading_copy.w2 = self.w2 + weights_at;
            reading_copy.w3 = self.w3 + weights_at;
            if (self.heads.hasSkipHead()) {
                reading_copy.w4 = self.w4 + weights_at;
            }
            return reading_copy;
        }

        /// THE TWO HEADS' WEIGHT GRADIENTS ZEROED, before a backward that may meet either or neither - with one head
        /// nothing: the first step met writes its gradient over the last update's.
        fn zeroHeadGradients(self: Self) void {
            if (!self.heads.hasSkipHead()) {
                return;
            }
            const head_floats: u32 = self.hidden * self.features + self.features;
            self.pipe.params = .{ .count = 2 * head_floats, .w_off = self.w3 };
            self.pipe.run("zero_weight_gradients", 2 * head_floats);
        }

        /// THE WORLD MODEL AT STEP k, FORWARD: from the wide block's world model slice - from `lead` on, `inputs` wide,
        /// rows `width` apart - to the step's change, whose offset it returns. The dense model through its three
        /// layers into its own blocks; the normed form through step k's application (`NormedWorld`).
        fn worldForward(self: Self, k: u32) u32 {
            const inputs_at: u32 = self.blockX(k) + self.lead;
            if (self.normed_world) |*world| {
                var step_regions: [NormedWorld(M).max_layers]kit_mlp.LayerRegions = undefined;
                var application: NormedWorld(M).Network.Application = world.stepApplication(k, &step_regions);
                application.inputs_affine = self.worldInputsAffine();
                application.forward(self.pipe, inputs_at, self.width);
                return application.outputsOffset();
            }
            const tanh: u32 = @backingInt(M.Act.tanh);
            const linear: u32 = @backingInt(M.Act.linear);
            const h1: u32 = self.h1_at + k * self.rows * self.hidden;
            const h2: u32 = self.h2_at + k * self.rows * self.hidden;
            const change: u32 = self.change_at + k * self.rows * self.features;
            self.worldFirstLayer(inputs_at, h1);
            self.dense(h1, 0, self.hidden, self.hidden, self.w2, h2, tanh);
            self.dense(h2, 0, self.hidden, self.features, self.headWeights(k), change, linear);
            return change;
        }

        /// THE WORLD MODEL AT STEP k, BACKWARD, from its change's gradient at `change_gradient` (`worldForward`'s
        /// values still in place): its weights' gradients as `parameter_gradients` says - none for a world model held
        /// fixed while a policy learns through it - and the gradient at its inputs into `dx_at`, `inputs` wide, when
        /// `wants_inputs_gradient`. The normed form computes that gradient either way: its network's backward always
        /// ends there.
        fn worldBackward(
            self: Self,
            k: u32,
            change_gradient: u32,
            parameter_gradients: kit_mlp.ParameterGradients,
            wants_inputs_gradient: bool,
        ) void {
            const inputs_at: u32 = self.blockX(k) + self.lead;
            if (self.normed_world) |*world| {
                var step_regions: [NormedWorld(M).max_layers]kit_mlp.LayerRegions = undefined;
                var application: NormedWorld(M).Network.Application = world.stepApplication(k, &step_regions);
                application.inputs_affine = self.worldInputsAffine();
                application.backward(self.pipe, self.rows, inputs_at, self.width, change_gradient, parameter_gradients);
                return;
            }
            const tanh: u32 = @backingInt(M.Act.tanh);
            const h1: u32 = self.h1_at + k * self.rows * self.hidden;
            const h2: u32 = self.h2_at + k * self.rows * self.hidden;
            const trains: bool = parameter_gradients != .none;
            const accumulate: u32 = if (parameter_gradients == .add) 1 else 0;
            // Layer 3 - the step's head - into the change. With two heads either may be the first a backward meets,
            // or meet none: both start zeroed (`zeroHeadGradients`), and every step adds into its own.
            const head: u32 = self.headWeights(k);
            const head_accumulate: u32 = if (self.heads.hasSkipHead()) 1 else accumulate;
            if (trains) {
                self.weightGrads(h2, 0, self.hidden, self.features, change_gradient, head, head_accumulate);
            }
            self.inputGrads(self.hidden, self.features, change_gradient, head, self.dh2_at);
            self.activationGrads(h2, self.dh2_at, tanh, self.hidden);
            // Layer 2.
            if (trains) {
                self.weightGrads(h1, 0, self.hidden, self.hidden, self.dh2_at, self.w2, accumulate);
            }
            self.inputGrads(self.hidden, self.hidden, self.dh2_at, self.w2, self.dh1_at);
            self.activationGrads(h1, self.dh1_at, tanh, self.hidden);
            // Layer 1, over the wide block.
            if (trains) {
                self.worldFirstLayerWeightGrads(inputs_at, accumulate);
            }
            if (wants_inputs_gradient) {
                self.worldFirstLayerInputGrads();
            }
        }

        /// Where the world model's inputs' normaliser is, as its first layer's dispatches take it
        /// (`zn_mlp.inputAffine`): `inputs_affine_at`, or 0 - none.
        fn worldInputsAffine(self: Self) u32 {
            return self.inputs_affine_at orelse 0;
        }

        /// THE DENSE WORLD MODEL's FIRST LAYER, FORWARD (`dense_fwd_tiled`): the wide block's world model slice -
        /// `inputs` columns from `inputs_at`, rows `width` apart - each input read through the normaliser
        /// (`worldInputsAffine`), into `h1`, through tanh.
        fn worldFirstLayer(self: Self, inputs_at: u32, h1: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = self.inputs,
                .out_dim = self.hidden,
                .act = @backingInt(M.Act.tanh),
                .x_off = inputs_at,
                .stride = self.width,
                .w_off = self.w1,
                .y_off = h1,
                .in_affine_off = self.worldInputsAffine(),
            };
            const invocations: u32 = M.denseTiledInvocations(self.rows, self.hidden);
            self.pipe.run("dense_fwd_tiled", invocations);
        }

        /// The first layer's weights' gradient (`dense_bwd_w_tiled`), from the gradient at its tanh's input
        /// (`dh1_at`), its inputs read through the normaliser as the forward read them: written, or added
        /// (`accumulate`).
        fn worldFirstLayerWeightGrads(self: Self, inputs_at: u32, accumulate: u32) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = self.inputs,
                .out_dim = self.hidden,
                .x_off = inputs_at,
                .stride = self.width,
                .dy_off = self.dh1_at,
                .w_off = self.w1,
                .accumulate = accumulate,
                .in_affine_off = self.worldInputsAffine(),
            };
            const invocations: u32 = M.denseTiledInvocations(self.inputs + 1, self.hidden);
            self.pipe.run("dense_bwd_w_tiled", invocations);
        }

        /// The gradient at the world model's inputs (`dense_bwd_x_tiled`), in their own units - back through the
        /// normaliser's scales - into `dx_at`: what a policy acting in the rollout receives at its action.
        fn worldFirstLayerInputGrads(self: Self) void {
            self.pipe.params = .{
                .rows = self.rows,
                .in_dim = self.inputs,
                .out_dim = self.hidden,
                .dy_off = self.dh1_at,
                .w_off = self.w1,
                .dx_off = self.dx_at,
                .in_affine_off = self.worldInputsAffine(),
            };
            const invocations: u32 = M.denseTiledInvocations(self.rows, self.inputs);
            self.pipe.run("dense_bwd_x_tiled", invocations);
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
            self.denseRows(self.rows, x, stride, in_dim, out_dim, w, y, 0, act);
        }

        /// One dense layer over `rows` rows (`dense_fwd`): each row's `in_dim` inputs from `x`, `stride` floats
        /// apart (0: packed), times the weights at `w` with their bias after them, activated, into `y`, its rows
        /// `y_stride` floats apart (0: packed).
        fn denseRows(
            self: Self,
            rows: u32,
            x: u32,
            stride: u32,
            in_dim: u32,
            out_dim: u32,
            w: u32,
            y: u32,
            y_stride: u32,
            act: u32,
        ) void {
            self.pipe.params = .{
                .rows = rows,
                .in_dim = in_dim,
                .out_dim = out_dim,
                .act = act,
                .x_off = x,
                .stride = stride,
                .w_off = w,
                .y_off = y,
                .y_stride = y_stride,
            };
            // In tiles (`zn_mlp.dense_fwd_tiled`): the same sums in the same order, a fraction of the global reads.
            const invocations: u32 = M.denseTiledInvocations(rows, out_dim);
            self.pipe.run("dense_fwd_tiled", invocations);
        }
    };
}

/// Where a training window starts: a character - an env of the ring the window is staged from - and its first
/// record's replay index.
pub const Start = struct {
    env: u32,
    index: u64,
    /// Whether the window CONTINUES ITS EPISODE: its first record is not its episode's first step, so what was
    /// applied just before it is the action of the record before - which the ring must still hold - and the window's
    /// first decision blends into it, and the policy reads it (`lat_gather_start_actions`). Otherwise the window
    /// opens its episode, from rest. A push ends a segment, never an episode: what the controller applies carries
    /// straight through it, so a window starting just after a push continues its episode
    /// (`track.Replay.Books.appliedBeforeAt`).
    continues_episode: bool = false,
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
            /// THE PLAN's LAST STEPS THROUGH THE SKIP HEAD: this many of the horizon's steps, at its end, are the
            /// training kit's skip head's (`Heads.skip_steps` decisions each), the first ones single decisions - the
            /// plan sees further for the same steps, a cheap screen of what each candidate leads to (`spans`). 0: every
            /// step one decision.
            skip_steps: u32 = 0,
        };

        /// The placed kit the plans roll in, and its options.
        kit: LatentKit(M),
        options: Options,
        /// Each step's span in decisions, host memory (the kit's `skips` reads it): 1 for the first steps, the skip
        /// head's for the last `options.skip_steps`. And the schedule's decision offsets - off(k), the decisions
        /// before step k, `horizon` + 1 of them - at `schedule_at` in acts, where the gather reads them
        /// (`zn_mlp.plan_gather`), and the host's copy uploaded with the objective (`writeObjective`).
        spans: []u32,
        schedule_at: u32,
        schedule: []f32,
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
            const unplaced: LatentKit(M) = try .initInForm(
                training_kit.pipe,
                training_kit.features,
                training_kit.references,
                training_kit.actions,
                training_kit.hidden,
                rows,
                options.horizon,
                training_kit.lead,
                training_kit.policy_hidden,
                training_kit.worldForm(),
                training_kit.heads,
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
            // The root imagined as the training kit imagines it, in blocks of its own: the policy reads its target, and
            // each step's cost charges its drift as the policy's loss does.
            if (training_kit.imagined_root) |training_root| {
                kit.imagined_root = training_root.forPlans(layout, options.horizon, rows);
            }
            // The plan's steps: single decisions, then the skip head's.
            const skip_steps_fit: bool = options.skip_steps <= options.horizon and
                (options.skip_steps == 0 or training_kit.heads.hasSkipHead());
            assertf(skip_steps_fit, @src(), "{d} skip steps in a plan of {d}: at most its horizon, with a skip head", .{
                options.skip_steps,
                options.horizon,
            });
            const spans: []u32 = try arena.alloc(u32, options.horizon);
            const schedule: []f32 = try arena.alloc(f32, options.horizon + 1);
            const single_steps: u32 = options.horizon - options.skip_steps;
            var decisions_before: u32 = 0;
            for (spans, 0..) |*span, step| {
                span.* = if (step < single_steps) 1 else training_kit.heads.skip_steps;
                schedule[step] = float(decisions_before);
                decisions_before += span.*;
            }
            schedule[options.horizon] = float(decisions_before);
            if (options.skip_steps > 0) {
                kit.skips = spans;
            }
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
                .spans = spans,
                .schedule_at = layout.reserveActs(options.horizon + 1),
                .schedule = schedule,
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
            const spans: ?[]const u32 = if (options.skip_steps > 0) scorer.spans else null;
            zrl.planObjectiveWeightsOver(
                f32,
                options.objective,
                options.discount,
                spans,
                cost_weights,
                value_weights,
            ) catch {
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
            if (scorer.options.skip_steps > 0) {
                pipe.uploadAt(.acts, scorer.schedule_at, scorer.schedule);
            }
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
            // Each step's cost: where the step led, against the goal there - and with a root imagined, its drift.
            const cost: TrackingCost = kit.trackingCost();
            for (1..horizon + 1) |step_index| {
                const k: u32 = @intCast(step_index);
                const step_costs_at: u32 = scorer.step_costs_at + (k - 1) * rows;
                var step_cost: TrackingCost = cost;
                if (kit.imagined_root) |root| {
                    step_cost.root = root.stepCost(k, rows);
                }
                runTrackingCost(M, pipe, step_cost, rows, kit.blockZ(k), kit.blockG(k), step_costs_at);
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
            // The host stages no root: a planner that imagines one gathers its states on the device, from the acting
            // rows' root targets (`TrackingPlanner.RowsDecision`).
            const reason: []const u8 = "the host's staging places no root: gather on the device";
            assertf(kit.imagined_root == null, @src(), "{s}", .{reason});
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
        /// Each state's inputs, [state][`stateInputFloats`] in acts: its normalised start features, then its start row
        /// in the reference table and its clip's last row - and with the root imagined, its root target as the acting
        /// row read it (`gather_plan_states`, `plan_gather`).
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
                    const unplaced: LatentKit(M) = try .initInForm(
                        training_kit.pipe,
                        training_kit.features,
                        training_kit.references,
                        training_kit.actions,
                        training_kit.hidden,
                        plan_rows,
                        scorer_options.horizon,
                        training_kit.lead,
                        training_kit.policy_hidden,
                        training_kit.worldForm(),
                        training_kit.heads,
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
                    // The root imagined as the scorer's candidates imagine it: the policy reads its target - the root
                    // moved by velocities out of the training kit's normaliser.
                    plans_kit.norm_at = training_kit.norm_at;
                    if (training_kit.imagined_root) |training_root| {
                        plans_kit.imagined_root = training_root.forPlans(layout, plan_steps, plan_rows);
                    }
                    // On the scorer's schedule, as the candidates beside them roll.
                    if (scorer_options.skip_steps > 0) {
                        plans_kit.skips = scorer.spans;
                    }
                    flow_plans = .{ .kit = plans_kit, .plans_per_state = plans_per_state };
                }
            }
            const has_root: bool = training_kit.imagined_root != null;
            const state_input_floats: u32 = scorer_options.states * stateInputFloats(training_kit.features, has_root);
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

        /// How many floats a state's inputs take (`zn_mlp.planStateInputFloats`): `features` normalised features, the
        /// start row and the clip's last row - and with the root imagined (`has_root`), the root target's nine.
        pub fn stateInputFloats(features: u32, has_root: bool) u32 {
            const root_slots: u32 = if (has_root) rbt.root_target_size else 0;
            return features + 2 + root_slots;
        }

        /// Whether the planner's rollouts imagine the root: the training kit's did, and the scorer's kit took it.
        pub fn imaginesRoot(planner: Self) bool {
            return planner.scorer.kit.imagined_root != null;
        }

        /// Where state `state`'s inputs go (`state_inputs_at`): its normalised start features, then its start row and
        /// its clip's last row, then with the root imagined its root target.
        pub fn stateInputsAt(planner: Self, state: u32) u32 {
            const features: u32 = planner.scorer.kit.features;
            return planner.state_inputs_at + state * stateInputFloats(features, planner.imaginesRoot());
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

        /// The mailbox's plans in floats: every state's chosen plan, [state][step][action].
        pub fn mailboxPlanFloats(planner: Self) u32 {
            const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
            return shape.states * shape.horizon * shape.action_width;
        }

        /// The mailbox's size in floats: the decision's step, then every state's chosen plan (`mailboxPlanFloats`).
        pub fn mailboxFloats(planner: Self) u32 {
            const decision_stamp: u32 = 1;
            return decision_stamp + planner.mailboxPlanFloats();
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
                .lat_schedule_on = @intFromBool(planner.scorer.options.skip_steps > 0),
                .lat_schedule_at = planner.scorer.schedule_at,
                .lat_root_target = @intFromBool(kit.imagined_root != null),
                .lat_roots_off = if (kit.imagined_root) |root| root.roots_at else 0,
                .lat_goal_roots_off = if (kit.imagined_root) |root| root.goal_roots_at else 0,
            };
            pipe.run("plan_gather", kit.rows * (kit.steps + 1) * kit.width);
        }

        /// A DECISION FOR SOME OF A SIMULATOR's ACTING ROWS (`decideForRows`): the planner, whose states are the
        /// rows its table names - [state][3] at `table_at`, an acting row, the reference table's start row and its
        /// clip's last row, uploaded by the caller with the states' warm flags - the resident reference table and
        /// normaliser its gather reads, and the decision's seed.
        pub const RowsDecision = struct {
            planner: Self,
            table_at: u32,
            reference_table_at: u32,
            normaliser_at: u32,
            seed: u32,
            /// Where every state's chosen plan goes after the decision (`writeMailbox`, in the parameter buffer), and
            /// the decision's number it is stamped with: the funnel reads the plans back at a replan.
            mailbox_at: u32,
            decision_number: u32,

            /// THE PLANNER's DECISION FOR SOME ACTING ROWS, after the flow's corrections of them
            /// (`LatentKit.correctOnRows`): every state's inputs from its acting row (`gather_plan_states`), the
            /// search - its candidates around the policy, the flow's own plans among them, through the world model and
            /// the critic (`decide`, a plan one decision older than the last) - and each state's chosen first
            /// correction decoded into its row's correction in the flow's place (`scatter_plan_corrections`). Each
            /// decision's plan warm-starts the next for a state whose flag says it holds the same character.
            pub fn decideForRows(
                decision: RowsDecision,
                kit: LatentKit(M),
                acting: LatentKit(M).PolicyRows,
                flow_rows: LatentKit(M).FlowRows,
            ) void {
                const planner: Self = decision.planner;
                const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
                const states: u32 = shape.states;
                const feature_count: u32 = kit.features;
                const has_root: bool = planner.imaginesRoot();
                const input_floats: u32 = stateInputFloats(feature_count, has_root);
                kit.pipe.params = .{
                    .rows = states,
                    .count = feature_count,
                    .x_off = acting.inputs_at,
                    .stride = acting.input_stride,
                    .col = kit.lead,
                    .y_off = planner.state_inputs_at,
                    .t_off = decision.table_at,
                    .lat_root_target = @intFromBool(has_root),
                };
                kit.pipe.run("gather_plan_states", states * input_floats);
                planner.gather(kit.pipe, decision.reference_table_at, decision.normaliser_at);
                const one_decision_older: u32 = 1;
                planner.decide(kit.pipe, decision.seed, one_decision_older);
                planner.writeMailbox(kit.pipe, decision.mailbox_at, decision.decision_number);
                const synergies_at: u32 = planner.own_synergies_at orelse flow_rows.actor.correction.synergies_at;
                kit.pipe.params = .{
                    .rows = states,
                    .count = shape.action_width,
                    .out_dim = kit.actions,
                    .x_off = planner.mppi.actions_offset,
                    .w_off = synergies_at,
                    .y_off = flow_rows.corrections_at,
                    .stride = acting.raw_stride,
                    .t_off = decision.table_at,
                };
                kit.pipe.run("scatter_plan_corrections", states * kit.actions);
            }
        };

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
///     of the frame it was at - `features + actions + 1` floats, padded to a multiple of four
///     (`latRecordWidth`: a simulator's block for them is that long). The ring has the fleet's replay's
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
/// A RING OF RECORDS ON THE DEVICE, in a kit's replay buffer (`zn_mlp.Buffers.ring`, a buffer of its own beside the
/// activations), from float `at` on: `capacity` steps of `envs` records each, each record `record` floats
/// (`M.latRecordWidth`). STEP-MAJOR - a step's records side by side - so a step goes in as ONE copy or upload:
///
///     at:   [ step s: env 0's record | env 1's | ... | env envs-1's ][ step s + 1: ... ] ...
///           a step's slot: its replay index modulo `capacity`
///
/// It keeps its own count of the replay indices it has received (`first_appended` .. `appended`): checked on every
/// append - no gaps - and read by every draw (`held`), since nothing on the GPU knows which slots were written. A
/// learner's characters have one (`Resident.ring`); a trainer's planners' candidates may have another.
pub const RecordRing = struct {
    at: u32,
    envs: u32,
    capacity: u32,
    record: u32,
    /// The replay indices the ring has received: the first ever, and the latest. Null until the first append. The
    /// ring holds the last `capacity` of them.
    first_appended: ?u64 = null,
    appended: ?u64 = null,

    /// The steps a ring holds, the oldest and the newest, both inclusive (`held`).
    pub const HeldSteps = struct { first: u64, last: u64 };

    /// The floats the ring takes: every step's records.
    pub fn floats(ring: RecordRing) u32 {
        return ring.capacity * ring.envs * ring.record;
    }

    /// Where env `env`'s record for replay index `index` starts: step-major, so the index picks a block of `envs`
    /// records and the env one record within it.
    pub fn recordAt(ring: RecordRing, env: usize, index: u64) u32 {
        const slot: u32 = @intCast(index % ring.capacity);
        const record_in_step: u32 = slot * ring.envs + @as(u32, @intCast(env));
        return ring.at + record_in_step * ring.record;
    }

    /// The replay indices the ring actually carries right now: from the later of its first append and `capacity`
    /// behind its latest, through its latest. Null while it has received nothing.
    ///
    /// Worth asking before drawing windows, because the books that draw them are NOT the ring: they may hold steps
    /// taken before the ring existed (a warm-up it never saw), and more of them than it has room for.
    pub fn held(ring: RecordRing) ?HeldSteps {
        const latest: u64 = ring.appended orelse return null;
        const oldest: u64 = @max(ring.first_appended.?, (latest + 1) -| ring.capacity);
        return .{ .first = oldest, .last = latest };
    }

    /// The ring's own count of what it holds, for a step placed at `index`: right after the step before it. No gaps:
    /// a step the ring missed would still be drawn as if it were there, and the gather would read whatever that slot
    /// held before - wrong data, with no error anywhere.
    pub fn markAppended(ring: *RecordRing, index: u64) void {
        if (ring.appended) |previous| {
            assertf(index == previous + 1, @src(), "the ring: index {d} after {d} - a step was not placed", .{
                index,
                previous,
            });
        } else {
            ring.first_appended = index;
        }
        ring.appended = index;
    }

    /// A STEP's RECORDS FROM A SIMULATOR ON THE SAME DEVICE, into the ring at `index`: every world's record, which the
    /// simulator wrote one block world after world (`robotgpu.record_rows`), moved by ONE COPY ON THE GPU into
    /// `ring_field` - the replay buffer of the kit the ring lives in (`.ring`). `records_at` is where the simulator's
    /// first world's block starts in its field, in floats. A block there must
    /// be as long as a record here - both round a record's live floats up to four (`latRecordWidth`, robotgpu's
    /// `padToVector`), and the ring must be laid out for the simulator's action - so `record_stride`, the simulator's
    /// block, is checked against the ring's record before anything moves. Call it after the simulator's record
    /// program is submitted, as every copy between pipelines (`compute_host.copyFieldBetween`).
    pub fn appendFromSimulator(
        ring: *RecordRing,
        ring_field: compute_host.DeviceField,
        index: u64,
        simulator: compute_host.DeviceField,
        records_at: u32,
        record_stride: u32,
    ) void {
        const blocks_are_records: bool = record_stride == ring.record;
        assertf(blocks_are_records, @src(), "the simulator's block is {d} floats, the ring's record {d}", .{
            record_stride,
            ring.record,
        });
        ring.markAppended(index);
        const float_bytes: u32 = @sizeOf(f32);
        const from_byte: u32 = records_at * float_bytes;
        const to_byte: u32 = ring.recordAt(0, index) * float_bytes;
        const byte_count: u32 = ring.envs * ring.record * float_bytes;
        compute_host.copyFieldBetween(simulator, from_byte, ring_field, to_byte, byte_count);
    }
};

/// WHAT A SLOT's WINDOWS WERE STAGED AS (`Resident.stageStartsFrom`), which the slot's gather reads: the ring the
/// windows are read from, and their steps - every window checked to lie in what that ring holds for exactly these
/// steps. So a slot is gathered as it was staged.
/// A GATHER's SCHEDULE (`Resident.gatherOnSchedule`): its steps, the records they span - the last offset - and where in
/// acts the `steps + 1` offsets are, floats holding integers from 0.
pub const GatherSchedule = struct {
    steps: u32,
    records: u32,
    at: u32,
};

/// What a slot's starts begin (`StagedWindows.kind`).
pub const StagedKind = enum { windows, policy_starts };

pub const StagedWindows = struct {
    ring: RecordRing,
    /// The windows' transitions; 0 while the slot was never staged.
    steps: u32 = 0,
    /// What the slot's starts are: windows of records (`lat_gather`), or a policy's starts, a record each, the rest of
    /// each rollout from the clip's tables (`lat_gather_policy_starts`).
    kind: StagedKind = .windows,
};

pub fn Resident(comptime M: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        pipe: *compute_host.Compute(M),
        features: u32,
        references: u32,
        actions: u32,
        /// Floats per table row.
        row: u32,
        /// The clip's frames one decision advances (the fleet's `decide_every`): how far a policy's start reads its
        /// clip's table rows ahead a step (`lat_gather_policy_starts`).
        decision_frames: u32,
        /// Where the tables start, and where each clip's first frame sits among the rows.
        table_at: u32,
        clip_rows: []u32,
        /// The characters' ring: a record per character per step (`RecordRing`), from the start of the replay's own
        /// buffer (`M.Buffers.ring`); a planner's candidates' may follow it there, from `ring_end`. In the activations,
        /// after the tables: the normaliser (means, then spreads); then the window starts - `slots` regions of `rows`
        /// windows (two floats each), one per update of a frame; then the end.
        ring: RecordRing,
        ring_end: u32,
        norm_at: u32,
        starts_at: u32,
        /// The starts' flags, `rows` per slot (`Start.continues_episode`): 1 or 0.
        continues_at: u32,
        rows: u32,
        /// How many updates of one frame can have their starts staged at once.
        slots: u32,
        /// What each slot's windows were staged as (`stageStartsFrom`), which the slot's gather reads: the ring - the
        /// characters', or another, a planner's candidates' say - and the windows' steps. Kept per slot, so a slot's
        /// windows are gathered from the very ring whose steps their starts count, for the steps checked to be held.
        staged: []StagedWindows,
        end: u32,
        // Host scratch, for computing features once.
        state: track.State,
        data: rbt.Data,
        staging: []f32,

        /// Lay the tables out from `start` in the activation buffer (after whatever else lives there, the rollout's
        /// blocks for one), and the ring from the start of the replay's buffer - or refuse, by name, if they do not
        /// fit.
        /// `actions` is how many numbers a record's action has: the joints' offsets alone for a CPU
        /// fleet's learner (`init`), or a device's whole action - offsets, then every limb's stiffness,
        /// which a simulator keeps whether the task uses them or not (robotgpu's `action_count`) - for a
        /// ring a simulator's records are copied into (`appendFromSimulator`).
        pub fn initWithActions(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            fleet: *const track.Fleet,
            start: u32,
            rows: u32,
            slots: u32,
            actions: u32,
        ) !Self {
            const m: *const rbt.Model = fleet.m;
            const features: u32 = @intCast(track.localSize(m.body_count));
            const references: u32 = @intCast(track.targetSize(m));
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
            const ring: RecordRing = .{
                .at = 0,
                .envs = envs,
                .capacity = capacity,
                .record = record,
            };
            const ring_end: u32 = ring.at + ring.floats();
            const norm_at: u32 = start + table_rows * row;
            const starts_at: u32 = norm_at + 2 * features;
            // Each start's flag beside the starts: whether its window continues its episode.
            const continues_at: u32 = starts_at + slots * 2 * rows;
            const end: u32 = continues_at + slots * rows;
            // The tables after the kit's own activations; the ring in its own buffer.
            if (end > floatsIn(M, "acts")) {
                return error.KitActivationsTooSmall;
            }
            if (ring_end > floatsIn(M, "ring")) {
                return error.KitRingTooSmall;
            }
            var data: rbt.Data = try .init(gpa, m);
            errdefer data.deinit();
            var state: track.State = try .init(gpa, m.body_count);
            errdefer state.deinit(gpa);
            // No slot staged yet.
            const staged: []StagedWindows = try gpa.alloc(StagedWindows, slots);
            errdefer gpa.free(staged);
            @memset(staged, .{ .ring = ring });
            return .{
                .gpa = gpa,
                .pipe = pipe,
                .features = features,
                .references = references,
                .actions = actions,
                .row = row,
                .decision_frames = @intCast(fleet.options.decide_every),
                .table_at = start,
                .clip_rows = clip_rows,
                .ring = ring,
                .ring_end = ring_end,
                .norm_at = norm_at,
                .starts_at = starts_at,
                .continues_at = continues_at,
                .rows = rows,
                .slots = slots,
                .staged = staged,
                .end = end,
                .state = state,
                .data = data,
                .staging = try gpa.alloc(f32, @max(table_rows * row, @max(envs * record, 3 * rows))),
            };
        }

        /// The tables and the ring of a CPU fleet's learner, whose policy outputs the joints' offsets alone
        /// (`track.actionSize`): `initWithActions` for that width.
        pub fn init(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            fleet: *const track.Fleet,
            start: u32,
            rows: u32,
            slots: u32,
        ) !Self {
            const offsets_alone: u32 = @intCast(track.actionSize(fleet.m));
            return initWithActions(gpa, pipe, fleet, start, rows, slots, offsets_alone);
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.staging);
            self.gpa.free(self.staged);
            self.state.deinit(self.gpa);
            self.data.deinit();
            self.gpa.free(self.clip_rows);
        }

        /// Where a clip frame's table row starts.
        pub fn rowAt(self: Self, clip: usize, frame: usize) u32 {
            return self.table_at + (self.clip_rows[clip] + @as(u32, @intCast(frame))) * self.row;
        }

        /// Every clip's table, computed and uploaded once: per frame, the reference's raw features, its encoded
        /// targets and its root's world pose (`Pose.numbers`) - the same reference state the device's judgement
        /// and policy inputs read (`track.Fleet.clipReferenceBodies`).
        pub fn uploadTables(self: *Self, fleet: *track.Fleet) void {
            const m: *const rbt.Model = fleet.m;
            var at: usize = 0;
            for (fleet.clips) |clip| {
                const root_len: usize = clip.nq - m.coordinate_count;
                for (0..clip.frame_count) |frame| {
                    const out: []f32 = self.staging[at..][0..self.row];
                    fleet.referenceStateInto(clip, @intCast(frame), &self.data, &self.state);
                    track.local(self.state, fleet.root, out[0..self.features]);
                    track.encodeTargets(m, clip.pose(frame)[root_len..], out[self.features..][0..self.references]);
                    const root_pose: rbt.Pose = .{
                        .pos = self.state.positions[fleet.root],
                        .rot = self.state.rotations[fleet.root],
                    };
                    const pose_at: u32 = M.latTableRootPose(self.features, self.references);
                    const pose_numbers: [M.lat_root_pose_numbers]f32 = root_pose.numbers();
                    @memcpy(out[pose_at..][0..M.lat_root_pose_numbers], &pose_numbers);
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

        /// A BATCH OF WINDOWS STAGED for slot `slot`'s gather (`gather`), read from `ring`: the characters' ring
        /// (`stageStarts`), or another laid out in the same replay buffer with records of the same layout - a planner's
        /// candidates', kept apart because they record on a cadence of their own. `starts` holds each window's env of
        /// that ring and first replay index (windows the books sampled, so none crosses a stretch's end); only they
        /// travel, two floats a window: its env, and the ring slot of its first record. The ring's geometry turns an
        /// index into a slot, and what the ring holds bounds every window over `steps` transitions; the slot keeps the
        /// ring and the steps (`staged`), so its gather reads that ring for those steps - no more than the kit's, and
        /// fewer where an update reads fewer: the world model's alone reads its own window, not the policy's horizon.
        ///
        /// A SLOT PER UPDATE: two gathers in the same frame staged in one place would both see the second batch's
        /// starts - WebGPU lands every upload of a frame before any of its work runs. So each update of a frame stages
        /// into a slot of its own.
        pub fn stageStartsFrom(
            self: *Self,
            ring: RecordRing,
            starts: []const Start,
            slot: u32,
            steps: u32,
        ) void {
            self.stageInto(ring, starts, slot, steps, .windows);
        }

        /// A POLICY's STARTS staged for slot `slot`'s gather, from the characters' ring: a record each, which the ring
        /// must hold - with the record before it where it continues its episode - and nothing after it, since the
        /// rollout of `steps` decisions from it is imagined and its references come from the clip's tables
        /// (`lat_gather_policy_starts`). The starts' drawer keeps every horizon inside its clip
        /// (`track.Replay.Books.sampleStart`).
        pub fn stagePolicyStarts(
            self: *Self,
            starts: []const Start,
            slot: u32,
            steps: u32,
        ) void {
            self.stageInto(self.ring, starts, slot, steps, .policy_starts);
        }

        /// Starts of either kind staged for slot `slot`: windows, every record of which the ring must hold, or
        /// policy starts, whose first record alone it must.
        fn stageInto(
            self: *Self,
            ring: RecordRing,
            starts: []const Start,
            slot: u32,
            steps: u32,
            kind: StagedKind,
        ) void {
            assertf(slot < self.slots, @src(), "stageStartsFrom: slot {d} of {d}", .{ slot, self.slots });
            // The gather reads a record with this resident's layout: features, the action, the table row.
            const records_alike: bool = ring.record == self.ring.record;
            assertf(records_alike, @src(), "stageStartsFrom: a ring of {d}-float records, this resident's are {d}", .{
                ring.record,
                self.ring.record,
            });
            // A FULL batch: a slot holds `rows` windows, and a partial staging would leave the rest of
            // them as they were - the previous update's windows, gathered again as if they were this
            // update's.
            assertf(starts.len == self.rows, @src(), "stageStartsFrom: {d} starts, the slot holds {d}", .{
                starts.len,
                self.rows,
            });
            // Every window must lie inside what the ring has received AND still holds: from the later
            // of its first append and `capacity` behind its latest, through its latest.
            const ring_held: ?RecordRing.HeldSteps = ring.held();
            assertf(ring_held != null, @src(), "stageStartsFrom: the ring has received nothing yet", .{});
            const held_steps: RecordRing.HeldSteps = ring_held.?;
            const latest: u64 = held_steps.last;
            const oldest: u64 = held_steps.first;
            // A window's LAST record (its final target) must be in the ring as well; a policy's start is its record.
            const records_after_start: u32 = switch (kind) {
                .windows => steps,
                .policy_starts => 0,
            };
            for (starts, 0..) |start, i| {
                const inside: bool = start.index >= oldest and start.index + records_after_start <= latest;
                assertf(inside, @src(), "stageStartsFrom: window at {d} is outside the ring's {d}..{d}", .{
                    start.index,
                    oldest,
                    latest,
                });
                const env_in_ring: bool = start.env < ring.envs;
                assertf(env_in_ring, @src(), "stageStartsFrom: env {d} of a ring of {d}", .{ start.env, ring.envs });
                self.staging[2 * i] = float(start.env);
                self.staging[2 * i + 1] = float(@as(u32, @intCast(start.index % ring.capacity)));
                // A window continuing its episode starts from the action of the record before it, which the ring must
                // still hold: where it is gone, what was applied is unknown - not rest - and the window's drawer must
                // draw another (`track.Replay.Books.appliedBeforeAt`).
                const previous_held: bool = start.index > oldest;
                const start_known: bool = !start.continues_episode or previous_held;
                assertf(start_known, @src(), "stageStartsFrom: window at {d} continues its episode; the ring holds " ++
                    "{d}..{d}, not the record before it", .{ start.index, oldest, latest });
                self.staging[2 * starts.len + i] = if (start.continues_episode) 1.0 else 0.0;
            }
            // Staging is shared with the appends and the tables. Safe: an upload copies its data when
            // it is made (WebGPU's writeBuffer), so the buffer is free again the moment it returns.
            self.pipe.uploadAt(.acts, self.startsAt(slot), self.staging[0 .. 2 * starts.len]);
            const flags: []const f32 = self.staging[2 * starts.len ..][0..starts.len];
            self.pipe.uploadAt(.acts, self.continuesAt(slot), flags);
            self.staged[slot] = .{ .ring = ring, .steps = steps, .kind = kind };
        }

        /// A batch of windows from the characters' ring (`ring`) staged for slot `slot`: `stageStartsFrom` it.
        pub fn stageStarts(
            self: *Self,
            starts: []const Start,
            slot: u32,
            steps: u32,
        ) void {
            self.stageStartsFrom(self.ring, starts, slot, steps);
        }

        /// Where a slot's window starts live.
        fn startsAt(self: Self, slot: u32) u32 {
            return self.starts_at + slot * 2 * self.rows;
        }

        /// Where slot `slot`'s flags sit: `rows` of them, one per start.
        fn continuesAt(self: Self, slot: u32) u32 {
            return self.continues_at + slot * self.rows;
        }

        /// A batch of windows into `kit`'s blocks - its first wide row and its targets filled, its rows'
        /// goals, references and recorded actions, and with a root imagined (`LatentKit.imagined_root`) the root's
        /// blocks and the first row's root target - assembled on the GPU from a ring and the tables, for the
        /// windows staged in `slot`, as they were staged (`staged`): from their ring, over their steps.
        ///
        /// WHY A SLOT PER UPDATE: in a frame, every upload lands before any of the frame's work runs,
        /// while dispatches run in order. So two updates may share the rollout's blocks - each one's
        /// dispatches read them before the next gather overwrites them - but NOT one place for their
        /// window starts: the second upload would overwrite the first before either gather ran, and both
        /// updates would train on the same windows.
        pub fn gather(self: *Self, kit: anytype, slot: u32) void {
            self.gatherSteps(kit, slot, null);
        }

        /// THE WINDOWS OF SLOT `slot` GATHERED ON A SCHEDULE (`zn_mlp.lat_gather`): `schedule.steps` steps, step k from
        /// the window's record at the offset the acts hold at `schedule.at` + k, the last offset `schedule.records` -
        /// within the records the slot was staged with. Each step's target is the state recorded where it ends, its
        /// reference that record's frame, its action the mean of the actions over its records.
        pub fn gatherOnSchedule(
            self: *Self,
            kit: anytype,
            slot: u32,
            schedule: GatherSchedule,
        ) void {
            const staged: StagedWindows = self.staged[slot];
            const within: bool = schedule.records <= staged.steps;
            assertf(within, @src(), "a schedule over {d} records of windows staged with {d}", .{
                schedule.records,
                staged.steps,
            });
            self.gatherSteps(kit, slot, schedule);
        }

        fn gatherSteps(
            self: *Self,
            kit: anytype,
            slot: u32,
            schedule: ?GatherSchedule,
        ) void {
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
            // A goal is a feature vector, and possibly the root target's slots after it: the lead is nothing or a goal.
            const lead_ok: bool = kit.lead == 0 or isGoalWidth(kit.lead, self.features);
            assertf(lead_ok, @src(), "gather: a lead of {d} columns - it must be 0 or a goal of {d} features", .{
                kit.lead,
                self.features,
            });
            const staged: StagedWindows = self.staged[slot];
            assertf(staged.steps > 0, @src(), "gather: slot {d} was never staged", .{slot});
            // The steps gathered must fit the kit's blocks; a schedule's are its own steps, over more records.
            const single_steps: u32 = @min(staged.steps, kit.steps);
            const gathered_steps: u32 = if (schedule) |on_schedule| on_schedule.steps else single_steps;
            const steps_fit: bool = gathered_steps <= kit.steps;
            assertf(steps_fit, @src(), "gather: {d} steps, the kit's blocks hold {d}", .{ gathered_steps, kit.steps });
            const ring: RecordRing = staged.ring;
            // One decision a step: as many steps as the kit has blocks for, of the records staged - which may be more,
            // for a policy whose schedule of skips spans more decisions than it has steps.
            const steps: u32 = if (schedule) |on_schedule| on_schedule.steps else @min(staged.steps, kit.steps);
            // The root in imagination writes the root target's slots: the goal must have them.
            const imagined_root: ?LatentKit(M).ImaginedRoot = kit.imagined_root;
            const has_slots: bool = kit.lead == self.features + @as(u32, rbt.root_target_size);
            assertf(imagined_root == null or has_slots, @src(), "gather: a root imagined, a goal of {d} columns", .{
                kit.lead,
            });
            self.pipe.params = .{
                .rows = kit.rows,
                .lat_features = self.features,
                .lat_references = self.references,
                .lat_actions = self.actions,
                .lat_steps = steps,
                .lat_envs = ring.envs,
                .lat_capacity = ring.capacity,
                .ring_off = ring.at,
                .table_off = self.table_at,
                .norm_off = self.norm_at,
                .starts_off = self.startsAt(slot),
                .blocks_off = kit.x_at,
                .targets_off = kit.t_at,
                .lat_lead = kit.lead,
                .goals_off = kit.g_at,
                .lat_schedule_on = if (schedule != null) 1 else 0,
                .lat_schedule_at = if (schedule) |on_schedule| on_schedule.at else 0,
                .lat_root_target = @intFromBool(imagined_root != null),
                .lat_roots_off = if (imagined_root) |root| root.roots_at else 0,
                .lat_goal_roots_off = if (imagined_root) |root| root.goal_roots_at else 0,
                .lat_decision_frames = self.decision_frames,
            };
            // Windows from their records; a policy's starts from one record each, the rest from the clip's tables.
            const threads: u32 = kit.rows * (steps + 1) * kit.width;
            switch (staged.kind) {
                .windows => self.pipe.run("lat_gather", threads),
                .policy_starts => self.pipe.run("lat_gather_policy_starts", threads),
            }
            // And each window's starting action - the one given before it, or rest when it opens its episode.
            self.pipe.params = .{
                .rows = kit.rows,
                .lat_features = self.features,
                .lat_actions = self.actions,
                .lat_envs = ring.envs,
                .lat_capacity = ring.capacity,
                .ring_off = ring.at,
                .starts_off = self.startsAt(slot),
                .x_off = self.continuesAt(slot),
                .y_off = kit.start_actions_at,
            };
            self.pipe.run("lat_gather_start_actions", kit.rows * self.actions);
        }

        /// The step the fleet just took, into the ring - one upload for every character. Call it
        /// after every `Fleet.step`: the replay's newest record is the state that step started from. The step's
        /// records built where the characters are (`buildStepRecords`), then placed (`uploadStep`): an actor builds
        /// them on its own thread or worker, and the learner places what it is given.
        pub fn appendLatest(self: *Self, fleet: *track.Fleet) void {
            const index: u64 = fleet.replay.written[0] - 1;
            const records: []f32 = self.staging[0 .. self.ring.envs * self.ring.record];
            const features: u32 = self.features;
            const actions: u32 = self.actions;
            buildStepRecords(fleet, index, features, actions, self.clip_rows, &self.data, &self.state, records);
            self.uploadStep(index, records);
        }

        /// A step's records - [character][record], every character of `fleet` - built from its replay at `index`:
        /// each character's state that step started from, in its root's frame (`track.local`); the action it took;
        /// the row its reference frame has in the tables (`clip_rows`, each clip's first row); and its root's world
        /// pose (`Pose.numbers`), as a simulator's kernel writes it (robotgpu's `record_rows`). Nothing of the
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
                const root_pose: rbt.Pose = .{
                    .pos = state.positions[fleet.root],
                    .rot = state.rotations[fleet.root],
                };
                const pose_at: u32 = M.latRecordRootPose(features, actions);
                const pose_numbers: [M.lat_root_pose_numbers]f32 = root_pose.numbers();
                @memcpy(out[pose_at..][0..M.lat_root_pose_numbers], &pose_numbers);
                // What is left of the record after its root pose is padding (`latRecordWidth`): written as zero, so
                // every float of the ring is defined, and a row packed here is the row a simulator's kernel packs.
                const padding_at: usize = pose_at + M.lat_root_pose_numbers;
                @memset(out[padding_at..], 0);
            }
        }

        /// A step's records, built by `buildStepRecords`, into the ring at `index` - one upload for every character -
        /// right after the step before it.
        pub fn uploadStep(self: *Self, index: u64, records: []const f32) void {
            self.ring.markAppended(index);
            self.pipe.uploadAt(.ring, self.ring.recordAt(0, index), records);
        }
    };
}

// ============================================================================================================
// THE KIT's KERNELS AGAINST THEIR CPU TWIN
// ============================================================================================================

/// How a kernel check judges and waits (`checkKitKernels`, `checkBlockedProducts`).
pub const KernelCheckOptions = struct {
    /// The largest relative gap from the CPU twin a value may have: float rounding, a few in a hundred thousand. The
    /// device and the twin run the same Zig source, but the device's transcendental functions are zimrmath's portable
    /// forms where the twin's are the host's, and its compiler may fuse a multiply into an add - so the bar is a
    /// relative 1e-5, not equality.
    gap_limit: f32 = 1.0e-5,
    /// How long a device's readback may take before the check gives it up, in milliseconds.
    readback_ms: f64 = 10_000,
};

/// WHAT A KERNEL CHECK FOUND: each sequence's largest relative gap from the twin, in the order the sequences ran, and
/// for each one past the bar its worst value. The sequences run one after another on the same buffers, so the first
/// one past the bar is the one that went wrong; the later ones may only carry its error on.
pub const KernelCheckReport = struct {
    /// More than the kit's sequences and the blocked products together.
    pub const most_sequences: usize = 16;

    /// One sequence's result: its name, its largest gap over every value it leaves, and - past the bar - the worst
    /// value of its worst field.
    pub const Sequence = struct {
        name: []const u8,
        largest_gap: f32,
        worst: ?WorstValue,
    };

    /// A FIELD PAST THE BAR (`worstValueOf`): how many of its values are, and its worst - the first not finite on
    /// either side, or else the largest relative gap - its index, the device's value and the twin's.
    pub const WorstValue = struct {
        field: []const u8,
        values_past_bar: usize,
        index: usize,
        gap: f32,
        device_value: f32,
        twin_value: f32,
    };

    sequences: [most_sequences]Sequence = undefined,
    sequence_count: usize = 0,
    /// False when a readback never came: the sequences after it were not measured.
    complete: bool = true,

    /// The sequences measured, in the order they ran.
    pub fn measured(report: *const KernelCheckReport) []const Sequence {
        return report.sequences[0..report.sequence_count];
    }

    /// The largest gap over every sequence measured.
    pub fn largestGap(report: *const KernelCheckReport) f32 {
        var largest: f32 = 0;
        for (report.measured()) |sequence| {
            largest = @max(largest, sequence.largest_gap);
        }
        return largest;
    }

    /// Whether every sequence was measured and every value it left is within `gap_limit` of the twin's.
    pub fn passes(report: *const KernelCheckReport, gap_limit: f32) bool {
        if (!report.complete) {
            return false;
        }
        for (report.measured()) |sequence| {
            if (sequence.largest_gap > gap_limit) {
                return false;
            }
        }
        return true;
    }

    fn add(report: *KernelCheckReport, sequence: Sequence) void {
        const has_room: bool = report.sequence_count < most_sequences;
        assertf(has_room, @src(), "a kernel check of more than {d} sequences", .{most_sequences});
        report.sequences[report.sequence_count] = sequence;
        report.sequence_count += 1;
    }
};

/// One dispatch of a kernel check (`KernelCheck`, `BlockedProductCheck`): the kernel, its uniform, its thread count.
pub fn KernelCheckStep(comptime M: type) type {
    return struct {
        kernel: []const u8,
        params: M.Params,
        threads: u32,
    };
}

/// THE KIT CHECK: its sizes, where its values live, and its sequences of dispatches - for one build of the kernel
/// module, `M` (the pages' `gpu/zn_mlp.zig`, or a program's own build of it at other buffer sizes: the layout is the
/// same, at the start of each buffer). A normed layer of 6 inputs and 16 outputs on 3 rows (SimNorm in groups of 8),
/// and a two-hot head of BMPC's 101 bins on 5 rows. Params hold W, b, the gains, the norm biases; acts the input, the
/// pre-activations, the normalised rows, the scaled values, the outputs, the inverse spreads, the targets, then the
/// two-hot head's logits, targets, losses and values; dacts the gradients at the output, at the scaled values, at the
/// pre-activations, at the input, and at the two-hot head's logits - as `gpu_learn_tests.zig`'s known answers place
/// them. After them, each in regions of its own: the flow policy's kernels, the tracking planner's, the labels', the
/// world model's gate's, the root in imagination's, the running statistics', and the log's (the world model's loss in
/// its own units, its gradient's tally). The second check, the blocked products over several blocks,
/// is `BlockedProductCheck`, on the same buffers.
pub fn KernelCheck(comptime M: type) type {
    return struct {
        pub const Step = KernelCheckStep(M);

        /// A named sequence of dispatches, run in order and then compared.
        pub const Sequence = struct {
            name: []const u8,
            steps: []const Step,
        };

        const rows: u32 = 3;
        const inputs: u32 = 6;
        const outputs: u32 = 16;
        const group: u32 = 8;
        const bins: u32 = 101;
        const two_hot_rows: u32 = 5;

        const block: u32 = rows * outputs;
        const gains: u32 = inputs * outputs + outputs;
        /// Where the labels' loss is written among the parameters (`stat_label_loss`), after the layer's.
        const label_loss: u32 = gains + 2 * outputs;
        /// Where the gate's numbers are written among the parameters, after the labels' loss: the no-change model's
        /// error, then a response's cosine and its length ratio, side by side (`stat_pair_response`).
        const gate_no_change: u32 = label_loss + 1;
        const gate_response: u32 = gate_no_change + 1;
        /// The statistics' chunks' sums (`kit_mlp.runStatistic`), after the gate's numbers: one chunk at these sizes.
        const stat_partials: u32 = gate_response + 2;
        // The world model's running statistics on a ring of 3 steps of 2 characters, records of 3 features and 2
        // actions, a reference table of 4 rows of 2 servo targets (`moments_steps`): the input columns' moments
        // (inputs [state 3 | targets 2 | action 2]) and the affine the fold writes, then the change's moments - each
        // already holding a count, so the pooled update's every term counts.
        const moment_features: u32 = 3;
        const moment_references: u32 = 2;
        const moment_actions: u32 = 2;
        const moment_envs: u32 = 2;
        const moment_capacity: u32 = 3;
        const moment_steps: u32 = 2;
        const moment_first_slot: u32 = 2;
        const moment_table_rows: u32 = 4;
        const moment_inputs: u32 = moment_features + moment_references + moment_actions;
        const input_moments: u32 = stat_partials + M.stat_most_sums;
        const inputs_affine: u32 = input_moments + 3 * moment_inputs;
        const change_moments: u32 = inputs_affine + 2 * moment_inputs;
        /// The log's statistics' numbers (`log_steps`): the world model's loss in its own units (eight), the gate's
        /// no-change error weighed, and the gradient's tally (four).
        const log_world_loss: u32 = change_moments + 3 * moment_features;
        const log_no_change: u32 = log_world_loss + M.stat_most_sums;
        const log_tally: u32 = log_no_change + 1;
        pub const params_end: u32 = log_tally + 4;
        const input: u32 = 0;
        const linear: u32 = rows * inputs;
        const normalised: u32 = linear + block;
        const scaled: u32 = normalised + block;
        const output: u32 = scaled + block;
        const inverse_spreads: u32 = output + block;
        const targets: u32 = inverse_spreads + rows;
        const logits: u32 = targets + block;
        const two_hot_targets: u32 = logits + two_hot_rows * bins;
        const losses: u32 = two_hot_targets + two_hot_rows;
        const values: u32 = losses + two_hot_rows;
        // The flow policy's kernels on 3 rows of 2 actions, their wide rows [condition 4 | x 2 | time 6] 12 wide: the
        // wide rows, a velocity as the network would leave it, the rows an Euler step writes into, and each row's
        // action, noise, time, path velocity and cost gradient.
        const flow_rows: u32 = 3;
        const flow_actions: u32 = 2;
        const flow_width: u32 = 12;
        const flow_point_column: u32 = 4;
        const flow_time_column: u32 = 6;
        const flow_wide: u32 = values + two_hot_rows;
        const flow_velocity: u32 = flow_wide + flow_rows * flow_width;
        const flow_next: u32 = flow_velocity + flow_rows * flow_actions;
        const flow_action_values: u32 = flow_next + flow_rows * flow_width;
        const flow_noise: u32 = flow_action_values + flow_rows * flow_actions;
        const flow_times: u32 = flow_noise + flow_rows * flow_actions;
        const flow_path_velocities: u32 = flow_times + flow_rows;
        const flow_cost_gradients: u32 = flow_path_velocities + flow_rows * flow_actions;
        // The tracking planner's kernels: MPPI's warm start (2 states, a plan of 4 steps of 2 actions, shifted by 2),
        // its elites weighed relative to their spread (2 states, 8 candidates, 4 elites), and the planner's gather (2
        // states x 2 rows, 3 steps, wide rows [goal 4 | state 4 | reference 3 | action 2], a reference table of 6
        // rows).
        const plan_states: u32 = 2;
        const plan_horizon: u32 = 4;
        const plan_actions: u32 = 2;
        const warm_flags: u32 = flow_cost_gradients + flow_rows * flow_actions;
        const warm_means: u32 = warm_flags + plan_states;
        const warm_spreads: u32 = warm_means + plan_states * plan_horizon * plan_actions;
        const elite_candidates: u32 = 8;
        const elite_count: u32 = 4;
        const elite_scores: u32 = warm_spreads + plan_states * plan_horizon * plan_actions;
        const elite_numbers: u32 = elite_scores + plan_states * elite_candidates;
        const elite_weights: u32 = elite_numbers + plan_states * elite_count;
        const gather_features: u32 = 4;
        const gather_references: u32 = 3;
        const gather_actions: u32 = 2;
        const gather_steps: u32 = 3;
        const gather_rows: u32 = 4;
        const gather_rows_per_state: u32 = 2;
        const gather_width: u32 = 2 * gather_features + gather_references + gather_actions;
        const gather_table_rows: u32 = 6;
        // A table row as the kernel strides it (`M.latTableWidth`): features, servo targets, then the reference root's
        // pose - a narrower layout lets the later rows read past the table, into what the kernel itself is writing.
        const gather_table_width: u32 = M.latTableWidth(gather_features, gather_references);
        const gather_table: u32 = elite_weights + plan_states * elite_count;
        const gather_normaliser: u32 = gather_table + gather_table_rows * gather_table_width;
        const gather_inputs: u32 = gather_normaliser + 2 * gather_features;
        const gather_blocks: u32 = gather_inputs + plan_states * (gather_features + 2);
        const gather_goals: u32 = gather_blocks + (gather_steps + 1) * gather_rows * gather_width;
        // The labels' kernels on 3 rows of 4 action numbers - three offsets filtered at 0.25, one stiffness at 0.5: the
        // policy's raw outputs, packed; wide rows 7 wide whose last 4 columns hold each row's label; the action given
        // before each row, packed; and the action the policy would give, as `lat_act` writes it, packed.
        const label_rows: u32 = 3;
        const label_actions: u32 = 4;
        const label_width: u32 = 7;
        const label_column: u32 = 3;
        const label_raw: u32 = gather_goals + gather_steps * gather_rows * gather_features;
        const label_wide: u32 = label_raw + label_rows * label_actions;
        const label_previous: u32 = label_wide + label_rows * label_width;
        const label_given: u32 = label_previous + label_rows * label_actions;
        // The world model's gate on 4 rows - two pairs of candidates - of 3 state numbers over a window of 2 steps: the
        // windows' first wide rows, 5 wide with the state from column 1; the model's predictions and the recorded
        // states, each a packed block a step.
        const gate_rows: u32 = 4;
        const gate_features: u32 = 3;
        const gate_window_steps: u32 = 2;
        const gate_width: u32 = 5;
        const gate_state_column: u32 = 1;
        const gate_block_numbers: u32 = gate_rows * gate_features;
        const gate_last_block: u32 = (gate_window_steps - 1) * gate_block_numbers;
        const gate_first_rows: u32 = label_given + label_rows * label_actions;
        const gate_predictions: u32 = gate_first_rows + gate_rows * gate_width;
        const gate_targets: u32 = gate_predictions + gate_window_steps * gate_block_numbers;
        // The root in imagination's two kernels on 3 rows, for decision 1: features 8 long, the root's velocity from
        // column 1, its angular velocity from column 4; a wide row a row, [goal 8 | the root target's slots | state 8];
        // the normaliser; the roots of decisions 0 and 1 and their goal roots; and the numbers the gradients are seeded
        // from (`root_steps`): the slots' - a whole input row's - the state's, and the carried one's.
        const root_rows: u32 = 3;
        const root_features: u32 = 8;
        const root_velocity_column: u32 = 1;
        const root_angular_column: u32 = 4;
        const root_lead: u32 = root_features + @as(u32, rbt.root_target_size);
        const root_width: u32 = root_lead + root_features;
        const root_carried_numbers: u32 = M.lat_root_gradient_numbers;
        const root_pose_floats: u32 = 2 * root_rows * M.lat_root_pose_numbers;
        const root_wide: u32 = gate_targets + gate_window_steps * gate_block_numbers;
        const root_normaliser: u32 = root_wide + root_rows * root_width;
        const root_roots: u32 = root_normaliser + 2 * root_features;
        const root_goal_roots: u32 = root_roots + root_pose_floats;
        const root_seeds: u32 = root_goal_roots + root_pose_floats;
        const root_seed_floats: u32 = root_rows * (root_width + root_features + root_carried_numbers);
        // The running statistics' ring, at the start of the replay's buffer (`M.Buffers.ring`). In acts, one float past
        // the seeds (a seed's partner, read one along: `root_steps`): the reference table, the clips' normaliser, the
        // change's floors, the fold's flags [step][character], and the kit's change statistics and loss weights the
        // fold writes.
        const moment_record_width: u32 = M.latRecordWidth(moment_features, moment_actions);
        const moment_table_width: u32 = M.latTableWidth(moment_features, moment_references);
        const moment_ring: u32 = 0;
        pub const ring_end: u32 = moment_ring + moment_capacity * moment_envs * moment_record_width;
        const moment_table: u32 = root_seeds + root_seed_floats + 1;
        const moment_normaliser: u32 = moment_table + moment_table_rows * moment_table_width;
        const moment_floors: u32 = moment_normaliser + 2 * moment_features;
        const moment_flags: u32 = moment_floors + moment_features;
        const moment_increments: u32 = moment_flags + moment_steps * moment_envs;
        const moment_weights: u32 = moment_increments + 2 * moment_features;
        // The log's statistics on the gate's predictions and recorded states: a loss weight and a kind for each of the
        // gate's features, then a gradient's length and its clip's factor.
        const log_weights: u32 = moment_weights + moment_features;
        const log_kinds: u32 = log_weights + gate_features;
        const log_gradient: u32 = log_kinds + gate_features;
        // A policy's starts on the running statistics' ring and table (`policy_starts_steps`): 2 rows of 2 steps, wide
        // rows [goal 3 | state 3 | servo targets 2 | action 2]; the starts, the wide blocks, the goal block.
        const policy_starts_rows: u32 = 2;
        const policy_starts_count: u32 = 2;
        const policy_starts_width: u32 = 2 * moment_features + moment_references + moment_actions;
        const policy_starts_at: u32 = log_gradient + 2;
        const policy_starts_blocks: u32 = policy_starts_at + 2 * policy_starts_rows;
        const policy_starts_goals: u32 =
            policy_starts_blocks + (policy_starts_count + 1) * policy_starts_rows * policy_starts_width;
        pub const acts_end: u32 = policy_starts_goals + policy_starts_count * policy_starts_rows * moment_features;
        const output_gradient: u32 = 0;
        const scaled_gradient: u32 = block;
        const linear_gradient: u32 = 2 * block;
        const input_gradient: u32 = 3 * block;
        const logit_gradient: u32 = input_gradient + rows * inputs;
        const flow_velocity_gradient: u32 = logit_gradient + two_hot_rows * bins;
        const label_gradient: u32 = flow_velocity_gradient + flow_rows * flow_actions;
        const root_slot_gradient: u32 = label_gradient + label_rows * label_actions;
        const root_state_gradient: u32 = root_slot_gradient + root_rows * root_width;
        const root_carried: u32 = root_state_gradient + root_rows * root_features;
        pub const dacts_end: u32 = root_carried + root_rows * root_carried_numbers;

        /// A normed layer forward and backward, its activation's kernels named: Mish's, SiLU's or SimNorm's.
        fn normedLayerSteps(
            comptime forward_kernel: []const u8,
            comptime backward_kernel: []const u8,
            comptime activation_threads: u32,
        ) [9]Step {
            const steps = [9]Step{
                .{
                    .kernel = "dense_fwd",
                    .params = .{
                        .rows = rows,
                        .in_dim = inputs,
                        .out_dim = outputs,
                        .act = @backingInt(M.Act.linear),
                        .x_off = input,
                        .y_off = linear,
                        .w_off = 0,
                    },
                    .threads = block,
                },
                .{
                    .kernel = "norm_fwd",
                    .params = .{
                        .rows = rows,
                        .out_dim = outputs,
                        .x_off = linear,
                        .w_off = gains,
                        .z_off = normalised,
                        .y_off = scaled,
                        .l_off = inverse_spreads,
                    },
                    .threads = rows,
                },
                .{
                    .kernel = forward_kernel,
                    .params = .{
                        .rows = rows,
                        .out_dim = outputs,
                        .x_off = scaled,
                        .y_off = output,
                        .simnorm_group = group,
                    },
                    .threads = activation_threads,
                },
                .{
                    .kernel = "mse_bwd",
                    .params = .{
                        .rows = rows,
                        .out_dim = outputs,
                        .y_off = output,
                        .t_off = targets,
                        .dy_off = output_gradient,
                    },
                    .threads = block,
                },
                .{
                    .kernel = backward_kernel,
                    .params = .{
                        .rows = rows,
                        .out_dim = outputs,
                        .x_off = scaled,
                        .y_off = output,
                        .dy_off = output_gradient,
                        .dx_off = scaled_gradient,
                        .simnorm_group = group,
                    },
                    .threads = activation_threads,
                },
                .{
                    .kernel = "norm_params_bwd",
                    .params = .{
                        .rows = rows,
                        .out_dim = outputs,
                        .dy_off = scaled_gradient,
                        .z_off = normalised,
                        .w_off = gains,
                    },
                    .threads = 2 * outputs,
                },
                .{
                    .kernel = "norm_bwd",
                    .params = .{
                        .rows = rows,
                        .out_dim = outputs,
                        .dy_off = scaled_gradient,
                        .w_off = gains,
                        .z_off = normalised,
                        .l_off = inverse_spreads,
                        .dx_off = linear_gradient,
                    },
                    .threads = rows,
                },
                .{
                    .kernel = "dense_bwd_w",
                    .params = .{
                        .rows = rows,
                        .in_dim = inputs,
                        .out_dim = outputs,
                        .x_off = input,
                        .dy_off = linear_gradient,
                        .w_off = 0,
                    },
                    .threads = inputs * outputs + outputs,
                },
                .{
                    .kernel = "dense_bwd_x",
                    .params = .{
                        .rows = rows,
                        .in_dim = inputs,
                        .out_dim = outputs,
                        .dy_off = linear_gradient,
                        .w_off = 0,
                        .dx_off = input_gradient,
                    },
                    .threads = rows * inputs,
                },
            };
            return steps;
        }

        /// The two-hot head's dispatches (BMPC's bins: symlog, [-10, 10]), the mean's divisor its rows.
        fn twoHotStep(
            comptime kernel: []const u8,
            comptime y_off: u32,
            comptime dy_off: u32,
        ) Step {
            const params: M.Params = .{
                .rows = two_hot_rows,
                .out_dim = bins,
                .x_off = logits,
                .t_off = two_hot_targets,
                .y_off = y_off,
                .dy_off = dy_off,
                .twohot_divisor = two_hot_rows,
            };
            return .{ .kernel = kernel, .params = params, .threads = two_hot_rows };
        }

        /// The sequences, run in this order on each pipe: the Mish layer, the SiLU layer, then the SimNorm layer (whose
        /// dispatches overwrite the one before's values - each comparison is of what its sequence leaves), then the
        /// two-hot head.
        const simnorm_groups: u32 = rows * (outputs / group);
        /// The dense layer in tiles (`M.dense_fwd_tiled` and its two gradients): forward through tanh, the weights'
        /// gradient written then added to, the input's gradient - the tiles' masked edges (3 rows, 6 inputs, 16
        /// outputs: partial tiles everywhere) and a sum over two tiles (the input's gradient, over 16 outputs).
        const tiled_layer_steps = [4]Step{
            .{
                .kernel = "dense_fwd_tiled",
                .params = .{
                    .rows = rows,
                    .in_dim = inputs,
                    .out_dim = outputs,
                    .act = @backingInt(M.Act.tanh),
                    .x_off = input,
                    .y_off = linear,
                    .w_off = 0,
                },
                .threads = M.denseTiledInvocations(rows, outputs),
            },
            .{
                .kernel = "dense_bwd_w_tiled",
                .params = .{
                    .rows = rows,
                    .in_dim = inputs,
                    .out_dim = outputs,
                    .x_off = input,
                    .dy_off = linear_gradient,
                    .w_off = 0,
                },
                .threads = M.denseTiledInvocations(inputs + 1, outputs),
            },
            .{
                .kernel = "dense_bwd_w_tiled",
                .params = .{
                    .rows = rows,
                    .in_dim = inputs,
                    .out_dim = outputs,
                    .x_off = input,
                    .dy_off = linear_gradient,
                    .w_off = 0,
                    .accumulate = 1,
                },
                .threads = M.denseTiledInvocations(inputs + 1, outputs),
            },
            .{
                .kernel = "dense_bwd_x_tiled",
                .params = .{
                    .rows = rows,
                    .in_dim = inputs,
                    .out_dim = outputs,
                    .dy_off = linear_gradient,
                    .w_off = 0,
                    .dx_off = input_gradient,
                },
                .threads = M.denseTiledInvocations(rows, inputs),
            },
        };
        /// Muon's kernels (`kit_mlp.Muon`) on a 3 x 3 matrix - the first nine weights, the first nine inputs as its
        /// iterate - into the pre-activations' region: the momentum, the product with B transposed (G = X X^T) and the
        /// polynomial's (U = c G G + b G), the length's partial sums in chunks of 4 and its inverse, the scale, the
        /// step.
        const muon_side: u32 = 3;
        const muon_count: u32 = muon_side * muon_side;
        const muon_steps = [7]Step{
            .{
                .kernel = "muon_momentum",
                .params = .{
                    .count = muon_count,
                    .w_off = 0,
                    .x_off = input,
                    .y_off = linear + 40,
                    .muon_momentum = 0.95,
                },
                .threads = muon_count,
            },
            .{
                .kernel = "muon_matmul_tiled",
                .params = .{
                    .rows = muon_side,
                    .in_dim = muon_side,
                    .out_dim = muon_side,
                    .x_off = input,
                    .v_off = input,
                    .y_off = linear,
                    .muon_b_transposed = 1,
                },
                .threads = M.denseTiledInvocations(muon_side, muon_side),
            },
            .{
                .kernel = "muon_matmul_tiled",
                .params = .{
                    .rows = muon_side,
                    .in_dim = muon_side,
                    .out_dim = muon_side,
                    .x_off = linear,
                    .v_off = linear,
                    .u_off = linear,
                    .y_off = linear + 16,
                    .muon_alpha = 2.0315,
                    .muon_beta = -4.7750,
                },
                .threads = M.denseTiledInvocations(muon_side, muon_side),
            },
            .{
                .kernel = "muon_square_partials",
                .params = .{ .count = muon_count, .stride = 4, .x_off = linear + 16, .y_off = linear + 32 },
                .threads = 3,
            },
            .{
                .kernel = "muon_inverse_length",
                .params = .{ .rows = 3, .x_off = linear + 32, .z_off = linear + 36, .epsilon = 1e-7 },
                .threads = 1,
            },
            .{
                .kernel = "muon_scale",
                .params = .{ .count = muon_count, .x_off = linear + 16, .y_off = linear + 16, .z_off = linear + 36 },
                .threads = muon_count,
            },
            .{
                .kernel = "muon_apply",
                .params = .{
                    .count = muon_count,
                    .w_off = 0,
                    .x_off = linear + 16,
                    .muon_decay = 2e-5,
                    .muon_step = 0.01,
                },
                .threads = muon_count,
            },
        };
        const mish_layer_steps: [9]Step = normedLayerSteps("mish_fwd", "mish_bwd", block);
        const silu_layer_steps: [9]Step = normedLayerSteps("silu_fwd", "silu_bwd", block);
        const simnorm_layer_steps: [9]Step = normedLayerSteps("simnorm_fwd", "simnorm_bwd", simnorm_groups);
        const two_hot_steps = [3]Step{
            twoHotStep("twohot_fwd", losses, 0),
            twoHotStep("twohot_bwd", 0, logit_gradient),
            twoHotStep("twohot_decode", values, 0),
        };

        /// The flow policy's kernels in the order a rollout's turn and a training step run them: the training times
        /// drawn and the base noise written (both hashed, so the device's integer hashing is compared with the twin's),
        /// the condition copied into the next rows, each row's time features at its own time, its point on the straight
        /// path and the path's velocity, one Euler step into the next rows, FlowDPG's gradient at the velocity, and
        /// that gradient carried back into acts.
        const flow_steps = [8]Step{
            .{
                .kernel = "hashed_uniforms",
                .params = .{
                    .rows = flow_rows,
                    .y_off = flow_times,
                    .lat_seed = 55,
                },
                .threads = flow_rows,
            },
            .{
                .kernel = "hashed_noise",
                .params = .{
                    .rows = flow_rows,
                    .count = flow_actions,
                    .y_off = flow_wide,
                    .stride = flow_width,
                    .col = flow_point_column,
                    .lat_sigma = 0.3,
                    .lat_seed = 77,
                },
                .threads = flow_rows * flow_actions,
            },
            .{
                .kernel = "copy_columns",
                .params = .{
                    .rows = flow_rows,
                    .count = flow_point_column,
                    .x_off = flow_wide,
                    .stride = flow_width,
                    .col = 0,
                    .y_off = flow_next,
                    .destination_stride = flow_width,
                    .destination_column = 0,
                },
                .threads = flow_rows * flow_point_column,
            },
            .{
                .kernel = "flow_time_features",
                .params = .{
                    .rows = flow_rows,
                    .y_off = flow_wide,
                    .stride = flow_width,
                    .col = flow_time_column,
                    .t_off = flow_times,
                    .flow_time_per_row = 1,
                    .flow_frequencies = 3,
                },
                .threads = flow_rows * 3,
            },
            .{
                .kernel = "flow_path_points",
                .params = .{
                    .rows = flow_rows,
                    .count = flow_actions,
                    .x_off = flow_action_values,
                    .z_off = flow_noise,
                    .t_off = flow_times,
                    .y_off = flow_wide,
                    .stride = flow_width,
                    .col = flow_point_column,
                    .u_off = flow_path_velocities,
                },
                .threads = flow_rows * flow_actions,
            },
            .{
                .kernel = "flow_euler_step",
                .params = .{
                    .rows = flow_rows,
                    .count = flow_actions,
                    .x_off = flow_wide,
                    .stride = flow_width,
                    .col = flow_point_column,
                    .z_off = flow_velocity,
                    .y_off = flow_next,
                    .flow_step = 0.25,
                    .destination_stride = flow_width,
                    .destination_column = flow_point_column,
                },
                .threads = flow_rows * flow_actions,
            },
            .{
                .kernel = "flow_dpg_bwd",
                .params = .{
                    .rows = flow_rows,
                    .count = flow_actions,
                    .x_off = flow_velocity,
                    .u_off = flow_path_velocities,
                    .v_off = flow_cost_gradients,
                    .t_off = flow_times,
                    .dy_off = flow_velocity_gradient,
                    .flow_step_share = 0.3,
                    .flow_step_floor = 0.2,
                    .flow_anchor = 0.5,
                },
                .threads = flow_rows,
            },
            .{
                .kernel = "copy_columns_from_gradients",
                .params = .{
                    .rows = flow_rows,
                    .count = flow_actions,
                    .x_off = flow_velocity_gradient,
                    .stride = flow_actions,
                    .col = 0,
                    .y_off = flow_next,
                    .destination_stride = flow_width,
                    .destination_column = flow_point_column,
                },
                .threads = flow_rows * flow_actions,
            },
        };

        /// The tracking planner's kernels: a warm start moving each warm plan forward two steps, the elites weighed
        /// relative to their own spread, and the planner's gather - whose table rows are integers carried as floats,
        /// the kind of arithmetic a device may round differently.
        const planner_steps = [3]Step{
            .{
                .kernel = "mppi_begin",
                .params = .{
                    .rows = plan_states,
                    .out_dim = plan_actions,
                    .plan_horizon = plan_horizon,
                    .mppi_max_spread = 1.5,
                    .mppi_warm_shift = 2,
                    .x_off = warm_flags,
                    .t_off = warm_means,
                    .u_off = warm_spreads,
                },
                .threads = plan_states * plan_actions,
            },
            .{
                .kernel = "mppi_elites",
                .params = .{
                    .rows = plan_states,
                    .plan_candidates = elite_candidates,
                    .mppi_elites = elite_count,
                    .mppi_temperature = 2,
                    .mppi_temperature_mode = 1,
                    .x_off = elite_scores,
                    .y_off = elite_numbers,
                    .z_off = elite_weights,
                },
                .threads = plan_states,
            },
            .{
                .kernel = "plan_gather",
                .params = .{
                    .rows = gather_rows,
                    .lat_features = gather_features,
                    .lat_references = gather_references,
                    .lat_actions = gather_actions,
                    .lat_steps = gather_steps,
                    .lat_lead = gather_features,
                    .plan_candidates = gather_rows_per_state,
                    .table_off = gather_table,
                    .norm_off = gather_normaliser,
                    .starts_off = gather_inputs,
                    .blocks_off = gather_blocks,
                    .goals_off = gather_goals,
                },
                .threads = gather_rows * (gather_steps + 1) * gather_width,
            },
        };

        /// A STATISTIC's TWO PASSES as the kit runs them (`kit_mlp.runStatistic`), its chunks' sums at `stat_partials`:
        /// one chunk at these sizes, so one thread each.
        fn statisticSteps(comptime kernel: []const u8, statistic_inputs: M.Params) [2]Step {
            var chunked: M.Params = statistic_inputs;
            chunked.stat_chunk = M.stat_least_chunk;
            chunked.stat_partials_off = stat_partials;
            const steps: [2]Step = .{
                .{ .kernel = kernel ++ "_partials", .params = chunked, .threads = 1 },
                .{ .kernel = kernel, .params = chunked, .threads = 1 },
            };
            return steps;
        }

        /// The policy learning from labels: the action it would give written through the action filter with no
        /// exploration (`lat_act`), the labels' gradient at its raw outputs, and the labels' loss for the log in its
        /// two passes - the three share the filter's blend (`M.latGivenAction`), here compiled for the device.
        const label_steps = [2]Step{
            .{
                .kernel = "lat_act",
                .params = .{
                    .rows = label_rows,
                    .count = label_actions,
                    .x_off = label_raw,
                    .y_off = label_given,
                    .stride = label_actions,
                    .lat_scale = 0.3,
                    .lat_filter = 0.25,
                    .lat_stiffness_filter = 0.5,
                    .lat_stiffness_count = 1,
                    .lat_prev_action = label_previous,
                    .lat_prev_action_stride = label_actions,
                },
                .threads = label_rows * label_actions,
            },
            .{
                .kernel = "lat_label_bwd",
                .params = .{
                    .rows = label_rows,
                    .count = label_actions,
                    .x_off = label_raw,
                    .t_off = label_wide + label_column,
                    .stride = label_width,
                    .dy_off = label_gradient,
                    .loss_weight = 1.5,
                    .lat_scale = 0.3,
                    .lat_filter = 0.25,
                    .lat_stiffness_filter = 0.5,
                    .lat_stiffness_count = 1,
                    .lat_prev_action = label_previous,
                    .lat_prev_action_stride = label_actions,
                },
                .threads = label_rows * label_actions,
            },
        } ++ statisticSteps("stat_label_loss", .{
            .rows = label_rows,
            .count = label_actions,
            .x_off = label_raw,
            .t_off = label_wide + label_column,
            .stride = label_width,
            .stat_off = label_loss,
            .lat_scale = 0.3,
            .lat_filter = 0.25,
            .lat_stiffness_filter = 0.5,
            .lat_stiffness_count = 1,
            .lat_prev_action = label_previous,
            .lat_prev_action_stride = label_actions,
        });

        /// The world model's gate (`LatentKit.recordWorldModelGate`): the no-change model's error over the windows, and
        /// the model's answer to an action against the physics' at the window's last step.
        const gate_steps = statisticSteps("stat_no_change_error", .{
            .rows = gate_rows,
            .count = gate_features,
            .lat_steps = gate_window_steps,
            .x_off = gate_first_rows + gate_state_column,
            .stride = gate_width,
            .t_off = gate_targets,
            .stat_off = gate_no_change,
        }) ++ statisticSteps("stat_pair_response", .{
            .rows = gate_rows,
            .count = gate_features,
            .x_off = gate_predictions + gate_last_block,
            .t_off = gate_targets + gate_last_block,
            .stat_off = gate_response,
        });

        /// The log's statistics (`LatentKit.recordWorldModelLoss`, `recordWorldModelGate`, `stepWorld`): the world
        /// model's loss in its own units over the gate's windows, its eight numbers; the no-change error weighed by the
        /// same weights; and the gradient's tally, restarted and then folded once more.
        const log_steps = statisticSteps("stat_world_loss_in_units", .{
            .rows = gate_rows,
            .count = gate_features,
            .lat_steps = gate_window_steps,
            .x_off = gate_predictions,
            .t_off = gate_targets,
            .u_off = log_weights,
            .z_off = log_kinds,
            .stat_off = log_world_loss,
        }) ++ statisticSteps("stat_no_change_error", .{
            .rows = gate_rows,
            .count = gate_features,
            .lat_steps = gate_window_steps,
            .x_off = gate_first_rows + gate_state_column,
            .stride = gate_width,
            .t_off = gate_targets,
            .u_off = log_weights,
            .stat_weights_on = 1,
            .stat_off = log_no_change,
        }) ++ [2]Step{
            .{
                .kernel = "stat_gradient_tally",
                .params = .{ .x_off = log_gradient, .stat_off = log_tally, .accumulate = 0 },
                .threads = 1,
            },
            .{
                .kernel = "stat_gradient_tally",
                .params = .{ .x_off = log_gradient, .stat_off = log_tally, .accumulate = 1 },
                .threads = 1,
            },
        };

        /// A POLICY's STARTS GATHERED (`lat_gather_policy_starts`): each start's state from its record in the ring, its
        /// two steps' goals and servo targets from the table rows after its record's, normalised by the clips'
        /// normaliser.
        const policy_starts_steps = [1]Step{
            .{
                .kernel = "lat_gather_policy_starts",
                .params = .{
                    .rows = policy_starts_rows,
                    .lat_features = moment_features,
                    .lat_references = moment_references,
                    .lat_actions = moment_actions,
                    .lat_steps = policy_starts_count,
                    .lat_envs = moment_envs,
                    .lat_capacity = moment_capacity,
                    .ring_off = moment_ring,
                    .table_off = moment_table,
                    .norm_off = moment_normaliser,
                    .starts_off = policy_starts_at,
                    .blocks_off = policy_starts_blocks,
                    .goals_off = policy_starts_goals,
                    .lat_lead = moment_features,
                    .lat_decision_frames = 1,
                },
                .threads = policy_starts_rows * (policy_starts_count + 1) * policy_starts_width,
            },
        };

        /// A gradient seeded from the seeds (`mse_bwd`, with a weight that cancels its mean): each of `count` numbers
        /// at dacts `at` the difference of two neighbouring seeds from acts `seeds_at` - the backward's gradients, the
        /// slots', the state's and the carried one's, as the steps before it would leave them.
        fn rootSeedStep(seeds_at: u32, count: u32, at: u32) Step {
            const step: Step = .{
                .kernel = "mse_bwd",
                .params = .{
                    .rows = root_rows,
                    .out_dim = count / root_rows,
                    .y_off = seeds_at,
                    .t_off = seeds_at + 1,
                    .dy_off = at,
                    .loss_weight = float(count) / 2,
                },
                .threads = count,
            };
            return step;
        }

        /// The root's parameters for decision 1, both kernels': the blocks, the columns, a step of 0.15 s, the wide
        /// rows' state and slots, the normaliser.
        const root_params: M.Params = .{
            .rows = root_rows,
            .lat_features = root_features,
            .lat_lead = root_lead,
            .x_off = root_wide + root_lead,
            .y_off = root_wide + root_features,
            .stride = root_width,
            .norm_off = root_normaliser,
            .dx_off = root_slot_gradient,
            .dy_off = root_state_gradient,
            .lat_root_target = 1,
            .lat_roots_off = root_roots,
            .lat_goal_roots_off = root_goal_roots,
            .lat_root_decision = 1,
            .lat_root_velocity_column = root_velocity_column,
            .lat_root_angular_column = root_angular_column,
            .lat_root_seconds = 0.15,
            .lat_root_gradient_off = root_carried,
        };

        /// THE ROOT IN IMAGINATION, forward and backward, at decision 1: the gradients seeded, the root moved and its
        /// target written (`lat_root_step`), then its gradient carried back (`lat_root_bwd`) - into the state's
        /// gradient, and to the root before.
        const root_steps = [5]Step{
            rootSeedStep(root_seeds, root_rows * root_width, root_slot_gradient),
            rootSeedStep(root_seeds + root_rows * root_width, root_rows * root_features, root_state_gradient),
            rootSeedStep(
                root_seeds + root_rows * (root_width + root_features),
                root_rows * root_carried_numbers,
                root_carried,
            ),
            .{ .kernel = "lat_root_step", .params = root_params, .threads = root_rows },
            .{ .kernel = "lat_root_bwd", .params = root_params, .threads = root_rows },
        };

        /// The root's data (`root_steps`), by formulas: the wide rows, the normaliser, each row's first root and its
        /// goal root at decision 1 - unit rotations of every kind - and the seeds.
        fn fillRootData(acts: []f32) void {
            for (acts[root_wide..][0 .. root_rows * root_width], 0..) |*value, index| {
                value.* = 0.8 * @sin(0.31 * float(index) + 0.2);
            }
            for (0..root_features) |feature| {
                acts[root_normaliser + feature] = 0.05 * @cos(0.7 * float(feature));
                acts[root_normaliser + root_features + feature] = 0.6 + 0.04 * float(feature);
            }
            const pose_numbers: u32 = M.lat_root_pose_numbers;
            const decision_block: u32 = root_rows * pose_numbers;
            for (0..root_rows) |row| {
                const at: f32 = float(row);
                const root: rbt.Pose = .{
                    .pos = vec(0.3 * at, -0.2 + 0.1 * at, 0.9),
                    .rot = normalizeQuat(.{ 0.1 + 0.2 * at, -0.3, 0.25 * at, 0.9 }),
                };
                const goal_root: rbt.Pose = .{
                    .pos = vec(0.5 - 0.2 * at, 0.4, 0.95),
                    .rot = normalizeQuat(.{ -0.2, 0.15 * at, 0.4, 0.8 - 0.1 * at }),
                };
                @memcpy(acts[root_roots + row * pose_numbers ..][0..pose_numbers], &root.numbers());
                const goal_at: u32 = root_goal_roots + decision_block + @as(u32, @intCast(row)) * pose_numbers;
                @memcpy(acts[goal_at..][0..pose_numbers], &goal_root.numbers());
            }
            for (acts[root_seeds..][0 .. root_seed_floats + 1], 0..) |*value, index| {
                value.* = 0.5 * @sin(0.23 * float(index) + 0.7);
            }
        }

        /// The world model's running statistics in one fold (`lat_world_moments`): the input columns' moments and the
        /// affine from them - the state's composed with the clips' normaliser, the servo targets read from the table
        /// row of each transition's second record - and the change's moments with the kit's statistics, over the
        /// flagged transitions: the ring wrapped, one record unflagged, one floor above its feature's spread.
        const moments_steps = [1]Step{
            .{
                .kernel = "lat_world_moments",
                .params = .{
                    .x_off = input_moments,
                    .w_off = change_moments,
                    .y_off = inputs_affine,
                    .z_off = moment_increments,
                    .l_off = moment_weights,
                    .u_off = moment_floors,
                    .t_off = moment_flags,
                    .norm_off = moment_normaliser,
                    .table_off = moment_table,
                    .lat_features = moment_features,
                    .lat_references = moment_references,
                    .lat_actions = moment_actions,
                    .lat_envs = moment_envs,
                    .lat_capacity = moment_capacity,
                    .ring_off = moment_ring,
                    .lat_steps = moment_steps,
                    .lat_first_slot = moment_first_slot,
                    .lat_norm_epsilon = 1.0e-2,
                    .lat_change_epsilon = 1.0e-4,
                    .lat_moments_limit = 1.0e9,
                },
                .threads = moment_inputs + moment_features,
            },
        };

        /// The running statistics' numbers (`moments_steps`): the ring's records - features and actions by formulas,
        /// each record's table row an exact integer - the table, the moments' counts, means and variances as earlier
        /// folds would leave them, a normaliser, floors, and flags with one record of the four unflagged.
        fn fillMomentData(parameters: []f32, acts: []f32, ring: []f32) void {
            for (0..moment_capacity * moment_envs) |record| {
                const record_at: usize = moment_ring + record * moment_record_width;
                for (0..moment_features) |feature| {
                    const index: f32 = float(record * moment_features + feature);
                    ring[record_at + feature] = 0.8 * @sin(0.9 * index + 0.3) + 0.1 * float(record);
                }
                const actions_at: usize = record_at + M.latRecordAction(moment_features);
                for (0..moment_actions) |number| {
                    const index: f32 = float(record * moment_actions + number);
                    ring[actions_at + number] = 0.6 * @cos(1.3 * index + 0.2);
                }
                const table_row_at: usize = record_at + M.latRecordTableRow(moment_features, moment_actions);
                ring[table_row_at] = float((record * 3 + 1) % moment_table_rows);
            }
            for (0..moment_table_rows * moment_table_width) |index| {
                acts[moment_table + index] = 0.5 * @sin(0.41 * float(index) + 0.6);
            }
            const MomentsBlock = struct { at: u32, count: u32 };
            const blocks = [2]MomentsBlock{
                .{ .at = input_moments, .count = moment_inputs },
                .{ .at = change_moments, .count = moment_features },
            };
            for (blocks) |moments_block| {
                for (0..moments_block.count) |number| {
                    parameters[moments_block.at + number] = 5 + float(number);
                    parameters[moments_block.at + moments_block.count + number] = 0.1 * float(number) - 0.05;
                    parameters[moments_block.at + 2 * moments_block.count + number] = 0.3 + 0.05 * float(number);
                }
            }
            for (0..moment_features) |feature| {
                acts[moment_normaliser + feature] = 0.2 * float(feature);
                acts[moment_normaliser + moment_features + feature] = 0.5 + 0.25 * float(feature);
            }
            const floor_values = [moment_features]f32{ 1.0e-3, 10.0, 1.0e-3 };
            @memcpy(acts[moment_floors..][0..moment_features], &floor_values);
            const flag_values = [moment_steps * moment_envs]f32{ 1, 0, 1, 1 };
            @memcpy(acts[moment_flags..][0 .. moment_steps * moment_envs], &flag_values);
        }

        /// The data both pipes start from: weights, inputs, gains and targets by formulas of their indices - spread
        /// enough that every kernel's arithmetic is exercised (a softmax far from uniform, gains away from 1) - and
        /// two-hot targets inside a pair of bins, on one, and past both ends; and the running statistics' records in
        /// `ring`, the replay buffer's first `ring_end` numbers.
        pub fn fillData(parameters: []f32, acts: []f32, ring: []f32) void {
            @memset(parameters, 0);
            @memset(acts, 0);
            @memset(ring, 0);
            fillRootData(acts);
            fillMomentData(parameters, acts, ring);
            for (parameters[0..gains], 0..) |*value, index| {
                value.* = 0.4 * @sin(0.7 * float(index) + 0.3);
            }
            const gain_values: []f32 = parameters[gains..][0..outputs];
            const norm_bias_values: []f32 = parameters[gains + outputs ..][0..outputs];
            for (gain_values, norm_bias_values, 0..) |*gain, *norm_bias, feature| {
                gain.* = 0.5 + 0.1 * float(feature);
                norm_bias.* = 0.2 - 0.03 * float(feature);
            }
            for (acts[input..][0 .. rows * inputs], 0..) |*value, index| {
                value.* = 1.5 * @cos(0.9 * float(index));
            }
            for (acts[targets..][0..block], 0..) |*value, index| {
                value.* = 0.3 * @sin(float(index));
            }
            for (acts[logits..][0 .. two_hot_rows * bins], 0..) |*logit, index| {
                logit.* = 2.0 * @sin(0.37 * float(index)) + 0.5 * @cos(0.11 * float(index));
            }
            const target_values = [two_hot_rows]f32{ 0.5, -3.0, 0.0, 1.0e9, -1.0e9 };
            @memcpy(acts[two_hot_targets..][0..two_hot_rows], &target_values);
            // The flow's: a velocity, actions, noise, cost gradients by formulas, and times spread over [0, 1).
            const flow_packed: u32 = flow_rows * flow_actions;
            for (0..flow_packed) |index| {
                acts[flow_velocity + index] = 0.6 * @sin(0.8 * float(index) + 0.2);
                acts[flow_action_values + index] = 0.5 * @cos(0.6 * float(index));
                acts[flow_noise + index] = 0.9 * @sin(1.1 * float(index) + 0.4);
                acts[flow_cost_gradients + index] = 0.7 * @cos(0.5 * float(index) + 0.9);
            }
            const flow_time_values = [flow_rows]f32{ 0.1, 0.45, 0.8 };
            @memcpy(acts[flow_times..][0..flow_rows], &flow_time_values);
            // The planner's: one warm state and one cold, plans, scores and a reference table by formulas, a
            // normaliser, and each gathered state's start - its features, then its start row and its clip's last row,
            // exact integers.
            acts[warm_flags] = 1;
            acts[warm_flags + 1] = 0;
            for (0..plan_states * plan_horizon * plan_actions) |index| {
                acts[warm_means + index] = 0.4 * @sin(0.9 * float(index) + 0.3);
            }
            for (0..plan_states * elite_candidates) |index| {
                acts[elite_scores + index] = -0.05 * (1.0 + @sin(1.7 * float(index)));
            }
            const table_floats: u32 = gather_table_rows * gather_table_width;
            for (0..table_floats) |index| {
                acts[gather_table + index] = @sin(0.37 * float(index) + 0.2);
            }
            for (0..gather_features) |column| {
                acts[gather_normaliser + column] = 0.1 * float(column);
                acts[gather_normaliser + gather_features + column] = 0.5 + 0.1 * float(column);
            }
            const start_rows = [plan_states]f32{ 1, 4 };
            for (0..plan_states) |state| {
                const inputs_at: usize = gather_inputs + state * (gather_features + 2);
                for (0..gather_features) |column| {
                    acts[inputs_at + column] = 0.3 * float(state + 1) - 0.05 * float(column);
                }
                acts[inputs_at + gather_features] = start_rows[state];
                acts[inputs_at + gather_features + 1] = float(gather_table_rows - 1);
            }
            // The labels': raw outputs, the actions given before and each row's label by formulas.
            for (0..label_rows * label_actions) |index| {
                acts[label_raw + index] = 1.2 * @sin(0.7 * float(index) + 0.5);
                acts[label_previous + index] = 0.4 * @cos(1.3 * float(index));
            }
            for (0..label_rows) |row| {
                const row_labels_at: usize = label_wide + row * label_width + label_column;
                for (0..label_actions) |number| {
                    acts[row_labels_at + number] = 0.8 * @cos(0.9 * float(row * label_actions + number) + 0.1);
                }
            }
            // The gate's: first states, predictions and recorded states by formulas, so that a pair's two rows differ
            // on both sides and the model's answer to an action neither matches the physics' nor opposes it.
            for (0..gate_rows * gate_width) |index| {
                acts[gate_first_rows + index] = 0.6 * @sin(0.8 * float(index) + 0.4);
            }
            for (0..gate_window_steps * gate_block_numbers) |index| {
                acts[gate_predictions + index] = 0.7 * @cos(0.6 * float(index) + 0.2);
                acts[gate_targets + index] = 0.5 * @sin(1.1 * float(index) + 0.9);
            }
            // The log's: weights not all 1, three kinds of the six - one feature each - and a gradient past its bound.
            const log_weight_values = [gate_features]f32{ 0.5, 2.0, 1.25 };
            @memcpy(acts[log_weights..][0..gate_features], &log_weight_values);
            const log_kind_values = [gate_features]f32{ 0, 2, 5 };
            @memcpy(acts[log_kinds..][0..gate_features], &log_kind_values);
            acts[log_gradient] = 1.5;
            acts[log_gradient + 1] = 1.0 / 1.5;
            // The policy's starts: character 0's and character 1's records of the ring's first slot - table rows 1 and
            // 0 (`fillMomentData`), so their two steps' rows stay inside the table's four.
            const policy_start_values = [2 * policy_starts_rows]f32{ 0, 0, 1, 0 };
            @memcpy(acts[policy_starts_at..][0 .. 2 * policy_starts_rows], &policy_start_values);
        }

        /// The sequences in the order they run, each named for the report.
        pub const sequences = [14]Sequence{
            .{ .name = "tiled layer", .steps = &tiled_layer_steps },
            .{ .name = "Muon", .steps = &muon_steps },
            .{ .name = "Mish layer", .steps = &mish_layer_steps },
            .{ .name = "SiLU layer", .steps = &silu_layer_steps },
            .{ .name = "SimNorm layer", .steps = &simnorm_layer_steps },
            .{ .name = "two-hot head", .steps = &two_hot_steps },
            .{ .name = "flow", .steps = &flow_steps },
            .{ .name = "planner", .steps = &planner_steps },
            .{ .name = "labels", .steps = &label_steps },
            .{ .name = "gate", .steps = &gate_steps },
            .{ .name = "root", .steps = &root_steps },
            .{ .name = "running statistics", .steps = &moments_steps },
            .{ .name = "the log's statistics", .steps = &log_steps },
            .{ .name = "the policy's starts", .steps = &policy_starts_steps },
        };

        /// Every step of `steps` on `pipe`, in order: a kernel is named to its pipe by a comptime string.
        pub fn runSteps(pipe: *compute_host.Compute(M), comptime steps: []const Step) void {
            inline for (steps) |step| {
                pipe.params = step.params;
                pipe.run(step.kernel, step.threads);
            }
        }
    };
}

/// THE BLOCKED PRODUCTS CHECK, OVER SEVERAL BLOCKS (`blockedProduct` in `gpu/zn_mlp.zig`): a dense layer of 70 rows, 75
/// inputs and 130 outputs - two blocks of rows, two of inputs, three of outputs, every block at an edge partial, and
/// each sum over steps of 8 with a partial last - its inputs strided 77 apart and read through an input affine, its
/// outputs written 131 apart; its weights' gradient written, then added to; its inputs' gradient. Then Muon's product
/// at the same sizes, B read straight and transposed, with alpha and beta. In acts the layer's inputs and outputs, then
/// Muon's A, B, D and its two outputs; in dacts the gradient at the outputs, then at the inputs; in params the weights
/// and their bias, then the affine (shifts, then scales).
pub fn BlockedProductCheck(comptime M: type) type {
    return struct {
        const Step = KernelCheckStep(M);

        const rows: u32 = 70;
        const inputs: u32 = 75;
        const outputs: u32 = 130;
        const input_stride: u32 = 77;
        const output_stride: u32 = 131;
        const input: u32 = 0;
        const output: u32 = input + rows * input_stride;
        const muon_left: u32 = output + rows * output_stride;
        const muon_right: u32 = muon_left + rows * inputs;
        const muon_added: u32 = muon_right + inputs * outputs;
        const muon_straight: u32 = muon_added + rows * outputs;
        const muon_transposed: u32 = muon_straight + rows * outputs;
        pub const acts_end: u32 = muon_transposed + rows * outputs;
        const output_gradient: u32 = 0;
        const input_gradient: u32 = output_gradient + rows * outputs;
        pub const dacts_end: u32 = input_gradient + rows * inputs;
        const weights: u32 = 0;
        const affine: u32 = weights + inputs * outputs + outputs;
        pub const params_end: u32 = affine + 2 * inputs;

        const layer_params: M.Params = .{
            .rows = rows,
            .in_dim = inputs,
            .out_dim = outputs,
            .w_off = weights,
            .in_affine_off = affine,
        };
        const muon_params: M.Params = .{
            .rows = rows,
            .in_dim = inputs,
            .out_dim = outputs,
            .x_off = muon_left,
            .v_off = muon_right,
            .u_off = muon_added,
            .muon_alpha = 1.5,
            .muon_beta = -0.5,
        };

        /// The layer's dispatches and Muon's, each from the shared params with its own places.
        fn steps() [6]Step {
            var forward: M.Params = layer_params;
            forward.act = @backingInt(M.Act.tanh);
            forward.x_off = input;
            forward.stride = input_stride;
            forward.y_off = output;
            forward.y_stride = output_stride;
            var weights_gradient: M.Params = layer_params;
            weights_gradient.x_off = input;
            weights_gradient.stride = input_stride;
            weights_gradient.dy_off = output_gradient;
            var weights_gradient_added: M.Params = weights_gradient;
            weights_gradient_added.accumulate = 1;
            var inputs_gradient: M.Params = layer_params;
            inputs_gradient.dy_off = output_gradient;
            inputs_gradient.dx_off = input_gradient;
            var straight: M.Params = muon_params;
            straight.y_off = muon_straight;
            var transposed: M.Params = muon_params;
            transposed.y_off = muon_transposed;
            transposed.muon_b_transposed = 1;
            const output_blocks: u32 = M.denseTiledInvocations(rows, outputs);
            const weight_blocks: u32 = M.denseTiledInvocations(inputs + 1, outputs);
            const input_blocks: u32 = M.denseTiledInvocations(rows, inputs);
            return .{
                .{ .kernel = "dense_fwd_tiled", .params = forward, .threads = output_blocks },
                .{ .kernel = "dense_bwd_w_tiled", .params = weights_gradient, .threads = weight_blocks },
                .{ .kernel = "dense_bwd_w_tiled", .params = weights_gradient_added, .threads = weight_blocks },
                .{ .kernel = "dense_bwd_x_tiled", .params = inputs_gradient, .threads = input_blocks },
                .{ .kernel = "muon_matmul_tiled", .params = straight, .threads = output_blocks },
                .{ .kernel = "muon_matmul_tiled", .params = transposed, .threads = output_blocks },
            };
        }

        /// The dispatches, made at compile time: a kernel is named to its pipe by a comptime string.
        pub const blocked_steps: [6]Step = steps();

        /// Every number the products read, by formulas - the affine's shifts near zero and its scales from a half
        /// to two.
        pub fn fillData(parameters: []f32, acts: []f32, gradients: []f32) void {
            for (acts, 0..) |*value, index| {
                value.* = 1.2 * @sin(0.37 * float(index) + 0.2);
            }
            for (gradients, 0..) |*value, index| {
                value.* = 0.8 * @cos(0.53 * float(index) + 0.7);
            }
            for (parameters[weights..affine], 0..) |*value, index| {
                value.* = 0.3 * @sin(0.71 * float(index) + 0.4);
            }
            for (0..inputs) |column| {
                parameters[affine + column] = 0.1 * @sin(float(column));
                parameters[affine + inputs + column] = 0.5 + 1.5 * (0.5 + 0.5 * @cos(1.3 * float(column)));
            }
        }
    };
}

/// A buffer a kernel check compares, by name, and how far into it.
const ComparedField = struct {
    name: []const u8,
    end: u32,
};

/// The largest difference between two runs of values, relative to the CPU twin's magnitude where it is above 1 - the
/// conformance sweep's measure. A value that is not finite on either side is no gap at all but a failure, and is
/// reported as an infinite one: `@max` returns its other operand when one is NaN, so a kernel writing NaN on the
/// device would otherwise pass as a gap of zero.
pub fn largestRelativeGap(device_values: []const f32, twin_values: []const f32) f32 {
    var largest: f32 = 0;
    for (device_values, twin_values) |device_value, twin_value| {
        const both_finite: bool = isFinite(device_value) and isFinite(twin_value);
        if (!both_finite) {
            return inf(f32);
        }
        const scale: f32 = @max(1.0, @abs(twin_value));
        largest = @max(largest, @abs(device_value - twin_value) / scale);
    }
    return largest;
}

/// A FIELD PAST THE BAR, measured: how many of its values are past `gap_limit`, and its worst - the first not finite
/// on either side, or else the largest relative gap.
pub fn worstValueOf(
    field_name: []const u8,
    device_values: []const f32,
    twin_values: []const f32,
    gap_limit: f32,
) KernelCheckReport.WorstValue {
    var worst: KernelCheckReport.WorstValue = .{
        .field = field_name,
        .values_past_bar = 0,
        .index = 0,
        .gap = 0,
        .device_value = device_values[0],
        .twin_value = twin_values[0],
    };
    for (device_values, twin_values, 0..) |device_value, twin_value, index| {
        const both_finite: bool = isFinite(device_value) and isFinite(twin_value);
        const scale: f32 = @max(1.0, @abs(twin_value));
        const gap: f32 = if (both_finite) @abs(device_value - twin_value) / scale else inf(f32);
        if (gap <= gap_limit) {
            continue;
        }
        worst.values_past_bar += 1;
        if (gap > worst.gap) {
            worst.gap = gap;
            worst.index = index;
            worst.device_value = device_value;
            worst.twin_value = twin_value;
        }
    }
    return worst;
}

/// A pipe's field once its readback holds every dispatch so far - the CPU twin's at once, a device's polled as the
/// engine polls - or null when it has not come within `deadline_ms`.
fn kernelCheckReadback(
    comptime M: type,
    pipe: *compute_host.Compute(M),
    comptime field_name: []const u8,
    deadline_ms: f64,
) ?[]const f32 {
    const field: FieldEnum(M.Buffers) = @field(FieldEnum(M.Buffers), field_name);
    const dispatched: u64 = pipe.readGeneration().submitted;
    const started_ms: f64 = wgpu.nowMs();
    while (wgpu.nowMs() - started_ms < deadline_ms) {
        const latest: ?[]const f32 = pipe.readLatest(field);
        const holds_every_dispatch: bool = pipe.readGeneration().mirrored >= dispatched;
        if (latest != null and holds_every_dispatch) {
            return latest;
        }
    }
    return null;
}

/// One sequence's values compared on both pipes, field by field as far as `fields` says: its largest gap, and its
/// worst field's worst value when one is past the bar - or null when a readback never came.
fn compareKernelCheck(
    comptime Device: type,
    comptime Twin: type,
    device_pipe: *compute_host.Compute(Device),
    twin_pipe: *compute_host.Compute(Twin),
    name: []const u8,
    comptime fields: []const ComparedField,
    options: KernelCheckOptions,
) ?KernelCheckReport.Sequence {
    var sequence: KernelCheckReport.Sequence = .{ .name = name, .largest_gap = 0, .worst = null };
    const deadline_ms: f64 = options.readback_ms;
    inline for (fields) |compared| {
        const device_values: []const f32 = kernelCheckReadback(Device, device_pipe, compared.name, deadline_ms) orelse
            return null;
        const twin_values: []const f32 = kernelCheckReadback(Twin, twin_pipe, compared.name, deadline_ms) orelse
            return null;
        const device_compared: []const f32 = device_values[0..compared.end];
        const twin_compared: []const f32 = twin_values[0..compared.end];
        const gap: f32 = largestRelativeGap(device_compared, twin_compared);
        const worst_so_far: f32 = if (sequence.worst) |worst| worst.gap else 0;
        if (gap > options.gap_limit and gap > worst_so_far) {
            sequence.worst = worstValueOf(compared.name, device_compared, twin_compared, options.gap_limit);
        }
        sequence.largest_gap = @max(sequence.largest_gap, gap);
    }
    return sequence;
}

/// THE KIT's LEARNING KERNELS ON A DEVICE AGAINST THEIR CPU TWIN (`KernelCheck`): every sequence from the same data on
/// both pipes, in the same order, and every value each leaves compared - the activations, their gradients, the
/// parameters' gradients, and the parameters, where statistics are written too - each sequence added to `report`.
/// `Device` and `Twin` are one build of the kernel module, or two of the same source at different buffer sizes: the
/// trainer checks its own pipe, the very SPIR-V it trains with, against the CPU twin of the pages' build. The check
/// writes from the start of each buffer: a pipe to be used afterwards is cleared (`clearKernelCheckData`).
pub fn checkKitKernels(
    comptime Device: type,
    comptime Twin: type,
    gpa: Allocator,
    device_pipe: *compute_host.Compute(Device),
    twin_pipe: *compute_host.Compute(Twin),
    options: KernelCheckOptions,
    report: *KernelCheckReport,
) !void {
    // Every field read by name builds the fields' enum at compile time: more evaluation than the default allows.
    @setEvalBranchQuota(20_000);
    const DeviceCheck: type = KernelCheck(Device);
    const TwinCheck: type = KernelCheck(Twin);
    const parameters: []f32 = try gpa.alloc(f32, DeviceCheck.params_end);
    defer gpa.free(parameters);
    const acts: []f32 = try gpa.alloc(f32, DeviceCheck.acts_end);
    defer gpa.free(acts);
    const ring: []f32 = try gpa.alloc(f32, DeviceCheck.ring_end);
    defer gpa.free(ring);
    DeviceCheck.fillData(parameters, acts, ring);
    // Each pipe's readback length and uniform given back as they were: the check leaves no setting of its own.
    const device_count_before: u32 = device_pipe.element_count;
    defer device_pipe.element_count = device_count_before;
    const twin_count_before: u32 = twin_pipe.element_count;
    defer twin_pipe.element_count = twin_count_before;
    const device_params_before: Device.Params = device_pipe.params;
    defer device_pipe.params = device_params_before;
    const twin_params_before: Twin.Params = twin_pipe.params;
    defer twin_pipe.params = twin_params_before;
    device_pipe.element_count = DeviceCheck.acts_end;
    twin_pipe.element_count = DeviceCheck.acts_end;
    device_pipe.upload(.params, parameters);
    device_pipe.upload(.acts, acts);
    device_pipe.upload(.ring, ring);
    twin_pipe.upload(.params, parameters);
    twin_pipe.upload(.acts, acts);
    twin_pipe.upload(.ring, ring);
    // The ring too: no kernel writes it, so a gap there is an upload or a binding gone wrong.
    const fields = [5]ComparedField{
        .{ .name = "acts", .end = DeviceCheck.acts_end },
        .{ .name = "dacts", .end = DeviceCheck.dacts_end },
        .{ .name = "grads", .end = DeviceCheck.params_end },
        .{ .name = "params", .end = DeviceCheck.params_end },
        .{ .name = "ring", .end = DeviceCheck.ring_end },
    };
    inline for (DeviceCheck.sequences, TwinCheck.sequences) |device_sequence, twin_sequence| {
        DeviceCheck.runSteps(device_pipe, device_sequence.steps);
        TwinCheck.runSteps(twin_pipe, twin_sequence.steps);
        const sequence: KernelCheckReport.Sequence =
            compareKernelCheck(Device, Twin, device_pipe, twin_pipe, device_sequence.name, &fields, options) orelse {
                report.complete = false;
                return;
            };
        report.add(sequence);
    }
}

/// THE BLOCKED PRODUCTS ON A DEVICE AGAINST THEIR CPU TWIN (`BlockedProductCheck`): from the same data, in the same
/// order, every value they leave compared as the kit check compares its own - one sequence added to `report`.
pub fn checkBlockedProducts(
    comptime Device: type,
    comptime Twin: type,
    gpa: Allocator,
    device_pipe: *compute_host.Compute(Device),
    twin_pipe: *compute_host.Compute(Twin),
    options: KernelCheckOptions,
    report: *KernelCheckReport,
) !void {
    @setEvalBranchQuota(20_000);
    const Blocked: type = BlockedProductCheck(Device);
    const TwinBlocked: type = BlockedProductCheck(Twin);
    const parameters: []f32 = try gpa.alloc(f32, Blocked.params_end);
    defer gpa.free(parameters);
    const acts: []f32 = try gpa.alloc(f32, Blocked.acts_end);
    defer gpa.free(acts);
    const gradients: []f32 = try gpa.alloc(f32, Blocked.dacts_end);
    defer gpa.free(gradients);
    Blocked.fillData(parameters, acts, gradients);
    // Each pipe's readback length and uniform given back as they were: the check leaves no setting of its own.
    const device_count_before: u32 = device_pipe.element_count;
    defer device_pipe.element_count = device_count_before;
    const twin_count_before: u32 = twin_pipe.element_count;
    defer twin_pipe.element_count = twin_count_before;
    const device_params_before: Device.Params = device_pipe.params;
    defer device_pipe.params = device_params_before;
    const twin_params_before: Twin.Params = twin_pipe.params;
    defer twin_pipe.params = twin_params_before;
    device_pipe.element_count = Blocked.acts_end;
    twin_pipe.element_count = Blocked.acts_end;
    device_pipe.upload(.params, parameters);
    device_pipe.upload(.acts, acts);
    device_pipe.upload(.dacts, gradients);
    twin_pipe.upload(.params, parameters);
    twin_pipe.upload(.acts, acts);
    twin_pipe.upload(.dacts, gradients);
    KernelCheck(Device).runSteps(device_pipe, &Blocked.blocked_steps);
    KernelCheck(Twin).runSteps(twin_pipe, &TwinBlocked.blocked_steps);
    const fields = [3]ComparedField{
        .{ .name = "acts", .end = Blocked.acts_end },
        .{ .name = "dacts", .end = Blocked.dacts_end },
        .{ .name = "grads", .end = Blocked.params_end },
    };
    const sequence: KernelCheckReport.Sequence =
        compareKernelCheck(Device, Twin, device_pipe, twin_pipe, "blocked products", &fields, options) orelse {
            report.complete = false;
            return;
        };
    report.add(sequence);
}

/// EVERY CHECK OF THE KIT's KERNELS, one after the other into one report: the kit's sequences, then the blocked
/// products - what a program runs on its device before trusting it (the trainer at its start).
pub fn checkKernelsAgainstTwin(
    comptime Device: type,
    comptime Twin: type,
    gpa: Allocator,
    device_pipe: *compute_host.Compute(Device),
    twin_pipe: *compute_host.Compute(Twin),
    options: KernelCheckOptions,
) !KernelCheckReport {
    var report: KernelCheckReport = .{};
    try checkKitKernels(Device, Twin, gpa, device_pipe, twin_pipe, options, &report);
    if (!report.complete) {
        return report;
    }
    try checkBlockedProducts(Device, Twin, gpa, device_pipe, twin_pipe, options, &report);
    return report;
}

/// How far into its buffers a kernel check writes: the furthest either check reaches into any of them - what
/// `clearKernelCheckData` sets back to zero in every buffer.
pub fn kernelCheckReach(comptime M: type) u32 {
    const Check: type = KernelCheck(M);
    const Blocked: type = BlockedProductCheck(M);
    const kit_reach: u32 = @max(@max(Check.acts_end, Check.ring_end), @max(Check.dacts_end, Check.params_end));
    const blocked_reach: u32 = @max(Blocked.acts_end, @max(Blocked.dacts_end, Blocked.params_end));
    return @max(kit_reach, blocked_reach);
}

/// A PIPE GIVEN BACK AS IT WAS MADE after a kernel check: the first numbers of every buffer - as far as either check
/// writes into any of them (`kernelCheckReach`) - set to zero again, as a device's new buffers are, so a learner that
/// uploads only what it needs finds the rest as on a pipe never checked. (The pipe's readback length and its uniform
/// the checks give back themselves.)
pub fn clearKernelCheckData(
    comptime M: type,
    gpa: Allocator,
    pipe: *compute_host.Compute(M),
) !void {
    const most_written: u32 = kernelCheckReach(M);
    const zeros: []f32 = try gpa.alloc(f32, most_written);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    inline for (@typeInfo(M.Buffers).@"struct".field_names) |field_name| {
        const field_length: usize = @typeInfo(@FieldType(M.Buffers, field_name)).array.len;
        const cleared: usize = @min(field_length, most_written);
        pipe.upload(@field(FieldEnum(M.Buffers), field_name), zeros[0..cleared]);
    }
}
