//! robot_track_resident - SuperTrack's training loop with everything but the simulation on the GPU.
//!
//! One round is the paper's iteration, split by what each processor is good at:
//!
//!   * **The CPU simulates and acts.** For every character, every step: its features, the policy's
//!     action from a MIRROR of the GPU's weights, and the step. Acting stays here because reading
//!     anything back from a GPU is asynchronous - the answer arrives a frame or so later - while the
//!     simulator needs its action now. The mirror is refreshed whenever the weights are read back;
//!     being a frame behind costs nothing, since weights move slowly.
//!   * **The CPU records** each step into the ring - one small upload for every character at once.
//!   * **The GPU learns.** The world model trains through its own rollouts, and the policy through the
//!     world model, on windows the GPU gathers itself from the ring and the reference tables. Each
//!     update takes its own window-start slot, because in a frame every upload lands before any of
//!     the frame's work runs.
//!
//! The pieces below it are checked against the CPU reference elsewhere: the gather and both training
//! steps follow `robot_latent`'s and `robot_track_st`'s own code to a few parts in a million. What
//! this file adds is the loop that puts them together, and the mirror that lets the simulation act.

const std = @import("std");
const zeroes = std.mem.zeroes;
const Io = std.Io;
const zm = @import("zm");
const floatMax = zm.floatMax;
const rbt = @import("robot");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const latent = @import("robot_latent.zig");
const kit_mod = @import("robot_latent_kit.zig");
const bmpc_kit = @import("robot_bmpc_kit.zig");
const zrl = @import("zrl");
const zn = @import("zn");
const kit_mlp = @import("kit_mlp.zig");
const compute_host = @import("compute_host.zig");

const bytesToValue = std.mem.bytesToValue;
const Allocator = std.mem.Allocator;
const Random = std.Random;
const asBytes = std.mem.asBytes;
const sliceAsBytes = std.mem.sliceAsBytes;
const eql = std.mem.eql;
const readInt = std.mem.readInt;
const float = zm.float;
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;
const metaEql = std.meta.eql;
const ArenaAllocator = std.heap.ArenaAllocator;
const startsWith = std.mem.startsWith;
const isFinite = zm.isFinite;

// ============================================================================================================
// PLANNING FOR CHARACTERS IN DANGER
// ============================================================================================================
//
// SuperTrack's policy learns from windows of tracking - rollouts that start near the reference - which makes it
// precise near the reference and weak after a big push, far from anything its windows showed it. For a character in
// danger, the learner searches over its next few actions by SuperTrack's own objective, through SuperTrack's own world
// model, and the character acts on the answer. The pieces, in the order a step meets them:
//
//     every acting step, every character
//         features --> its hazard (`planningHazard`), projected along its rise (`projectedHazard`)
//                  --> the flags (`PlanningFlags`): who plans, and whether everyone planning decides now
//
//     on a decision (`planDecision`: all planning characters together, on the flags' one clock)
//         each one's state and its rows in the reference table, uploaded to its planner slot
//         --> the planner (`robot_latent_kit.TrackingPlanner`): its rows gathered on the device as a training
//             window's are; the flow's own plans rolled; MPPI's rounds, every plan scored by SuperTrack's cost and
//             the critic's pessimistic tail (`TrackingScorer`); an elite chosen per slot
//         --> each slot's CHOSEN plan, stamped with the decision's step, into the MAILBOX after the parameters
//
//     every acting step, each planning character
//         the mailbox, as the newest readback brought it (`refreshMailbox`)
//         --> the policy's reaction to the state it is in, plus its plan's correction for this step
//             (`plannedCorrection`: the plan its own, the step within the horizon) - or the policy alone
//
// What a decision costs the host is one small upload - a state and two row numbers per slot, and the warm flags -
// and what it costs the readback is the mailbox: a few hundred numbers, which ride the parameter buffer's readback
// the learner makes every frame anyway.

/// WHICH CHARACTERS PLAN, AND WHEN. Planning costs a search per planned character every few steps, and matters only
/// near a fall, so a character plans only while its hazard (`planningHazard`) says it is in danger:
///
///     start     its hazard reaches `start_hazard` and a planner slot is free - at most `budget` characters plan at
///               once; when more want to start than slots are free, the most endangered start first
///     keep      it keeps its slot until its hazard has stayed below `stop_hazard` for `calm_steps` steps in a row.
///               The gap between the two thresholds and the wait are the HYSTERESIS: a character keeps planning
///               through a recovery instead of flickering in and out as its hazard wavers
///     decide    ALL planning characters decide together, on ONE clock: every `replan_every` steps, and at once when
///               a character starts (which restarts the clock); each acts from its plan in between
///
/// One clock, because the search warm-starts every state from its last plan moved forward by the steps since it was
/// made: with every slot deciding at once, that number - the PLAN AGE `step` returns with each decision - is the same
/// for all, and no slot's plan is moved by the wrong amount. The clock runs only while someone plans; idle, it rests
/// at zero.
///
/// Worked, with three characters, a budget of two, start 0.5, stop 0.1, two calm steps, a decision every three:
///
///     step   hazards           planning (slot)        decide   age
///     0      0.6  0.9  0.7     1 (0), 2 (1)           1, 2     1      the two most endangered start; 0 waits
///     1      0.6  0.3  0.05    1 (0), 2 (1)           -               2 is calm once
///     2      0.6  0.05 0.05    0 (1), 1 (0)           0, 1     2      2, calm twice, stops; 0 takes its slot
///     3      0.2  0.05 0.8     0 (1), 2 (0)           0, 2     1      1, calm twice, stops; 2 takes its slot
///     6      0.2  0.05 0.8     0 (1), 2 (0)           0, 2     3      three steps since the last decision
///
/// (A plan that has just started has no last plan: its warm flag is 0, and the age moves nothing.)
///
/// A decision can be DEFERRED: when the caller says it may not decide (`may_decide` false), a decision that falls
/// due stays PENDING - the clock keeps counting - and is made at the first step the caller allows, with the true age.
/// The learner allows one decision per frame: a decision's device work reads inputs uploaded in its frame, and the
/// device receives every upload of a frame before any of the frame's work runs, so a second decision in the same
/// frame would overwrite the first's inputs before the first had read them.
pub const PlanningFlags = struct {
    pub const Settings = extern struct {
        start_hazard: f32 = 0.5,
        stop_hazard: f32 = 0.1,
        calm_steps: u32 = 30,
        budget: u32 = 2,
        replan_every: u32 = 4,
    };

    /// Each character's planner slot - which of the planner's states it is - or none while it does not plan.
    slots: []?u32,
    /// Steps since the planning characters last decided - one clock for all of them, at rest (zero) while nobody plans.
    steps_since_decision: u32,
    /// A decision fell due while the caller did not allow one: it is made at the next step that is allowed.
    decision_pending: bool,
    /// Steps in a row each planning character's hazard has stayed below `stop_hazard`.
    calm_streaks: []u32,
    /// Which planner slots are taken.
    slot_taken: []bool,

    /// Flags for `character_count` characters and `budget` planner slots, none planning. Memory: `gpa`, the caller's
    /// to free with `deinit`.
    pub fn init(gpa: Allocator, character_count: usize, budget: u32) !PlanningFlags {
        const flags: PlanningFlags = .{
            .slots = try gpa.alloc(?u32, character_count),
            .steps_since_decision = 0,
            .decision_pending = false,
            .calm_streaks = try gpa.alloc(u32, character_count),
            .slot_taken = try gpa.alloc(bool, budget),
        };
        @memset(flags.slots, null);
        @memset(flags.calm_streaks, 0);
        @memset(flags.slot_taken, false);
        return flags;
    }

    pub fn deinit(flags: PlanningFlags, gpa: Allocator) void {
        gpa.free(flags.slots);
        gpa.free(flags.calm_streaks);
        gpa.free(flags.slot_taken);
    }

    /// One step (this type's head): each character's `hazards` in; who stops, who starts, and - in `deciding`, one
    /// flag per character - who decides now. In that order: stopping first frees slots for this step's starters.
    /// Returns, when the planning characters decide, the PLAN AGE - how many steps their last plans have aged, the
    /// shift their warm starts need - and null when nobody decides. With `may_decide` false, a decision that falls
    /// due waits, pending, for a step that allows it.
    pub fn step(
        flags: *PlanningFlags,
        hazards: []const f32,
        settings: Settings,
        may_decide: bool,
        deciding: []bool,
    ) ?u32 {
        @memset(deciding, false);
        // STOP: a planning character calm for long enough gives its slot back.
        for (flags.slots, flags.calm_streaks, hazards) |*slot, *calm_streak, hazard| {
            const slot_number: u32 = slot.* orelse continue;
            calm_streak.* = if (hazard < settings.stop_hazard) calm_streak.* + 1 else 0;
            if (calm_streak.* >= settings.calm_steps) {
                flags.slot_taken[slot_number] = false;
                slot.* = null;
            }
        }
        // START: while a slot is free, the most endangered character not planning whose hazard reaches the start.
        var anyone_started: bool = false;
        while (firstFreeSlot(flags.slot_taken)) |free_slot| {
            var most_endangered: ?usize = null;
            for (flags.slots, hazards, 0..) |slot, hazard, character| {
                const can_start: bool = slot == null and hazard >= settings.start_hazard;
                if (!can_start) {
                    continue;
                }
                const is_more_endangered: bool = if (most_endangered) |other| hazard > hazards[other] else true;
                if (is_more_endangered) {
                    most_endangered = character;
                }
            }
            const starter: usize = most_endangered orelse break;
            flags.slots[starter] = free_slot;
            flags.slot_taken[free_slot] = true;
            flags.calm_streaks[starter] = 0;
            anyone_started = true;
        }
        // The clock runs only while someone plans.
        var anyone_plans: bool = false;
        for (flags.slots) |slot| {
            anyone_plans = anyone_plans or slot != null;
        }
        if (!anyone_plans) {
            flags.steps_since_decision = 0;
            flags.decision_pending = false;
            return null;
        }
        // DECIDE on the one clock: every planning character, when the clock comes round or someone has started - or
        // when a decision deferred earlier is still pending.
        flags.steps_since_decision += 1;
        const clock_came_round: bool = flags.steps_since_decision >= settings.replan_every;
        const decision_due: bool = anyone_started or clock_came_round or flags.decision_pending;
        if (!decision_due) {
            return null;
        }
        if (!may_decide) {
            flags.decision_pending = true;
            return null;
        }
        flags.decision_pending = false;
        for (flags.slots, deciding) |slot, *decides| {
            decides.* = slot != null;
        }
        const plan_age: u32 = flags.steps_since_decision;
        flags.steps_since_decision = 0;
        return plan_age;
    }

    fn firstFreeSlot(slot_taken: []const bool) ?u32 {
        for (slot_taken, 0..) |taken, slot| {
            if (!taken) {
                return @intCast(slot);
            }
        }
        return null;
    }
};

/// How SuperTrack's learner plans for characters in danger (`PlanningFlags`, `robot_latent_kit.TrackingPlanner`):
/// whether it does, which characters and when (the flags' settings), and the search for each - its candidates, the
/// plans' horizon in steps, its rounds and elites, how many of the candidates are the flow's own plans, and the
/// temperature, read relative to the elites' own spread. A fixed-width struct, so a learner's state file can hold it.
///
/// The defaults fit beside SuperTrack's own training in the kit's buffers: the planner's kits are world-model kits
/// of slots x candidates rows over the horizon, and the layout refuses, by its numbers, a planner the buffers cannot
/// hold (2 slots x 16 candidates x 4 steps needs about a sixth of what 8 x 64 x 8 does).
pub const PlanningSettings = extern struct {
    enabled: bool = false,
    /// The three bytes after a bool, written as zeros: the settings are saved byte for byte (`hasNoPadding`).
    padding_after_enabled: [3]u8 = @splat(0),
    flags: PlanningFlags.Settings = .{},
    /// How many steps ahead a rising hazard is projected before the flags read it (`projectedHazard`): a fall in
    /// progress is flagged while its hazard is still climbing, not only once it is high. 0 reads the hazard as it is.
    lookahead_steps: f32 = 10,
    candidates: u32 = 16,
    horizon: u32 = 4,
    rounds: u32 = 2,
    elites: u32 = 4,
    flow_plans: u32 = 2,
    /// THE PLAN'S KNOTS (`KitMppi.Options.fine_steps`, `knot_span`): the points of a plan the search draws, the
    /// steps between two knots a straight line - its first `fine_steps` steps each a knot, near the state where every
    /// step of a correction matters, then a knot every `knot_span` steps to the horizon's last. A candidate is drawn in
    /// knots x actions numbers rather than horizon x actions: smooth where it is far, and with fewer of the world
    /// model's loopholes to find. 0 fine steps: every step a knot. (horizon - fine steps) must divide by the span.
    fine_steps: u32 = 0,
    knot_span: u32 = 1,
    /// THE PLAN'S OBJECTIVE (`zimrrl.PlanObjective`, `TrackingScorer`): `final` - the plan's costs, then the critic
    /// after its last step - or `mean_over_depths` - EfficientTDMPC's mean over every prefix of the plan, each its
    /// costs and then the critic, which prefers plans that stay good wherever the policy would take over. Either way
    /// the costs and the critic's values are weighed with the critic's own discount.
    objective: zrl.PlanObjective = .final,
    temperature: f32 = 2.0,
    /// TEACHER 2 (`robot_latent_kit.FlowActor.Distillation`), with a flow actor: each step a character takes from its
    /// plan is kept as an example - the condition it acted in, the plan's correction - in a ring of `distill_examples`;
    /// each round a batch of `distill_rows` of them is drawn, and every policy update adds `distill_weight` x the flow
    /// matching loss on it to FlowDPG's gradient.
    distill_weight: f32 = 0.5,
    distill_rows: u32 = 32,
    distill_examples: u32 = 512,

    /// Whether the plan's knots end on its last step (`robot_bmpc_kit.planKnotsFit`).
    pub fn knotsFit(planning: PlanningSettings) bool {
        return bmpc_kit.planKnotsFit(planning.fine_steps, planning.knot_span, planning.horizon);
    }
};

/// A character's PLANNING HAZARD: how far toward a fall its state is, by the failure barrier's own measures
/// (`zn_mlp.barrierMeasuresOf`) against the barrier's own margins - the larger of its two fractions,
///
///     hazard = max( |head height error| / head margin,  (1 - cos(up, up_ref)) / tilt margin )
///
/// 0 on the reference, 1 at a margin, where the failure rule fires; 0.5 is halfway to a fall. Not the barrier's
/// hinged value, which stays near zero until a few widths before the margin - by then a fall is under way, too late
/// to start planning. The same measures and margins as the barrier, so the planner and the policy agree on what
/// danger is. `state` and `goal` are normalised features, `means` and `spreads` the normaliser's; `head_column` and
/// `up_column` where the head's height and the up direction are; the barrier's margins must be above zero.
///
/// Worked: a head 0.1 m below the reference's, against a margin of 0.25 m, is 0.4 of the way; an up direction 60
/// degrees from the reference's (1 - cos = 0.5), against a margin of 1, is 0.5 - the hazard is 0.5.
pub fn planningHazard(
    comptime M: type,
    state: []const f32,
    goal: []const f32,
    means: []const f32,
    spreads: []const f32,
    head_column: u32,
    up_column: u32,
    barrier: kit_mod.FailureBarrier,
) f32 {
    const Row = zn.SliceRow(f32);
    const state_row: Row = .{ .values = state };
    const goal_row: Row = .{ .values = goal };
    const means_row: Row = .{ .values = means };
    const spreads_row: Row = .{ .values = spreads };
    const measures: M.BarrierMeasures =
        M.barrierMeasuresOf(Row, state_row, goal_row, means_row, spreads_row, head_column, up_column);
    const head_fraction: f32 = @abs(measures.height_error) / barrier.head_margin;
    const lengths_product: f32 = @sqrt(measures.up_square) * @sqrt(measures.reference_up_square);
    // Two up directions of no length count as aligned, as in the barrier.
    const cosine: f32 = if (lengths_product < 1.0e-6) 1.0 else measures.up_dot / lengths_product;
    const tilt_fraction: f32 = (1.0 - cosine) / barrier.tilt_margin;
    return @max(head_fraction, tilt_fraction);
}

/// A hazard PROJECTED ahead along its rise - what the flags read, so a fall in progress is caught early:
///
///     projected = hazard + lookahead x max(0, hazard - previous hazard)
///
/// The hazard of one step, `hazard`, and of the step before, `previous_hazard`; their difference is how fast the
/// character is heading toward its margins, and `lookahead_steps` steps of it are added. Only a RISING hazard is
/// projected: a falling one is not trusted to keep falling - a character that has only begun to recover is still in
/// danger - so it is read as it is, and stopping stays the calm wait's to decide.
///
/// Worked: a hazard rising from 0.2 to 0.3 in one step, ten steps ahead, reads 0.3 + 10 x 0.1 = 1.3 - past a start
/// threshold of 0.5 already, where the hazard itself would have needed two more steps of that rise; falling from 0.4
/// to 0.3, it reads 0.3.
pub fn projectedHazard(hazard: f32, previous_hazard: f32, lookahead_steps: f32) f32 {
    const rise_per_step: f32 = @max(hazard - previous_hazard, 0);
    return hazard + lookahead_steps * rise_per_step;
}

pub const Options = struct {
    /// Windows per update, and the world model's window in steps: it is fit on windows this long, rolled forward on
    /// the actions the simulator took, so it learns to correct its own errors.
    rows: u32 = 16,
    window: u32 = 8,
    /// THE POLICY'S HORIZON: the steps it imagines through the world model, with the critic's tail past them - at
    /// least `window`; 0: the world model's window (`horizon`). The windows drawn are this long, and the world model
    /// learns from their first `window` steps (`LatentKit.world_steps`). With a critic, a horizon of 8 learns poorly,
    /// 16 matches a critic-free 32, and 32 learns fastest (Liao et al. 2026, SuperMimic).
    policy_window: u32 = 0,
    /// THE SHARE OF THE POLICY'S WINDOWS DRAWN INSIDE RETURNS, when the fleet has returns
    /// (`track.Fleet.Options.return_steps`; `Resident.returnWindowShare`): the rest start before a loss. A window
    /// inside a return carries the large squared distances of a body on its way back, and with them large gradients;
    /// the share keeps them from drowning the tracking near the reference while the policy learns the way back.
    return_window_share: f32 = 0.25,
    /// THE TIME-TO-RETURN COST: the per-step cost's cap far from the reference (`zn_mlp.boundedCost`) for the critic's
    /// targets, the planner's scores and teacher 3's advantages - so far from the reference every step costs the cap
    /// and the critic values a fallen state by its time to return, inside its bins; near it the cost is SuperTrack's.
    /// The policy's pathwise loss keeps SuperTrack's cost. 0: no cap.
    return_cost_cap: f32 = 0,
    /// The world model's width, and the policy's.
    hidden: u32 = 64,
    policy_hidden: u32 = 64,
    world_rate: f32 = 1.0e-3,
    policy_rate: f32 = 3.0e-4,
    /// THE POLICY'S OPTIMISER (`LatentKit.policy_optimizer`): its gradient's whole length bounded, then each number
    /// (0: no bound), and Adam's second-moment decay - 0.95 follows the gradient's scale faster than 0.999, which
    /// back-propagation through a long rollout wants. SuperMimic bounds its policy's length to 1.0 and each number to
    /// 0.1 in its loss's units; ours is a sum over the horizon of per-step mean squared distances, so the bounds are
    /// set against the logged `policy_gradient_norm`. The defaults bound nothing: the same numbers as an unclipped
    /// Adam.
    policy_gradient_clip: f32 = 0,
    /// THE WORLD MODEL'S GRADIENT BOUND: its update's global length clipped to this (`LatentKit.world_optimizer`) -
    /// a fall's hard-to-predict contacts can give a window's gradient hundreds of times a tracking window's. 0: none,
    /// the kit's own Adam.
    world_gradient_clip: f32 = 0,
    /// THE SKIP HEAD (`robot_latent_kit.SkipModel`): a head on the world model's second hidden layer, trained on the
    /// same windows to predict this many steps at once - what a planner's far half jumps with. 0: none; otherwise at
    /// least 2 (one step is the world model's own) and at most the world model's window (`window`), which holds
    /// window / span of its jumps.
    skip_span: u32 = 0,
    /// THE WORLD MODEL'S CHANGE IN UNITS OF THE TYPICAL CHANGE (Uni-SuperMimic's increment normalisation): above 0,
    /// each feature's change in one step is measured from the reference clips, as the normaliser is
    /// (`robot_latent.measureClipIncrements`) - its mean and spread, each spread at least this - and the world model
    /// predicts the change in those units (`LatentKit.increments_at`), its loss weighing each feature's error by
    /// 1 / spread squared (`LatentKit.loss_weights_at`). A feature that moves little in a step is then predicted, and
    /// judged, as finely as one that moves much. The floor keeps a feature that never moves in the reference from
    /// weighing without bound: 0.03 is about the twentieth percentile of Geno's measured spreads (the median 0.13),
    /// against which the eighteen features constant in the reference would otherwise weigh a million times the rest.
    /// 0: the network's output is the change itself, every feature weighing 1.
    increment_spread_floor: f32 = 0,
    policy_element_clip: f32 = 0,
    policy_beta2: f32 = 0.999,
    /// THE RATES' SCHEDULE (`zn.cosineLearningRate`): every network's learning rate - the world model's, the policy's,
    /// the critic's, the flow's - a share of its base by a cosine over this many of its own updates, down to
    /// `rate_floor_share` of it and kept there; 0: the rates stay as given. SuperMimic decays to 0.03 over 250,000.
    rate_decay_updates: u32 = 0,
    /// THE RATES' SCHEDULE IN TRAINING HOURS (`Resident.training_hours`, told by the program that trains): the same
    /// cosine, over hours rather than updates. A run's length is planned in hours, while how many updates those hours
    /// hold depends on the machine and is known only once it has run; over hours, the rates reach their floor at the
    /// planned end on any machine. Above 0 it is the schedule, `rate_decay_updates` set aside.
    rate_decay_hours: f32 = 0,
    rate_floor_share: f32 = 0.03,
    /// Exploration noise, in units of the policy's raw output - in the simulator while collecting, and
    /// inside every training rollout.
    sigma: f32 = 0.1,
    /// THE ACTION FILTER (DReCon's action smoothing, `track.filterAction`): at every decision the action the fleet is
    /// given is `filter` x the action chosen + (1 - filter) x the action it was given at the character's previous
    /// decision - so no joint's target ever jumps, and the policy must ask for more than it wants to move one quickly.
    /// The fleet records what it is given, so the replay holds the applied actions; the filter's state is the
    /// previous one. A character's filter starts at rest, a zero action, with every episode. 1 is no filter: the
    /// chosen action given exactly. DReCon's is 0.2 - set once training passes its imagined actions through the
    /// filter too, so the world model and the policy learn the actions the physics is given.
    filter: f32 = 0.25,
    /// THE ACTION FILTER's SHARE FOR THE LIMBS' STIFFNESSES, at each decision as `filter` is for the joints' offsets
    /// (`writeAction`; the kit's `stiffness_filter`): a stiffness may want to move faster or slower than a pose. 1: no
    /// filter. A run parameter, as `filter` is. This trainer's policy outputs the offsets alone (a fleet with limb
    /// stiffness is refused), so the share acts once a policy has stiffness outputs.
    stiffness_filter: f32 = 0.5,
    /// THE POLICY SEES THE ACTION APPLIED BEFORE ITS DECISION (the kit's `sees_applied`): with the action filter on,
    /// what is applied is half of the control state - a policy blind to it cannot tell where its filtered action
    /// stands. Its block starts at zero, so the policy begins exactly as one that cannot see it.
    sees_applied: bool = true,
    /// The price on the size of the raw action, beside the policy's tracking loss.
    w_action: f32 = 0.01,
    /// The smoothness price on the policy's action along a window (CAPS; `robot_latent.LearnerOptions.w_smooth`).
    w_smooth: f32 = 0.0,
    /// The failure barrier in the policy's loss (`robot_latent_kit.FailureBarrier`): off - weight 0 - by default.
    barrier: kit_mod.FailureBarrier = .{},
    /// Whether SuperTrack's critic trains (`robot_latent_kit.LatentCritic`), and its settings: off by default. It
    /// learns the tracking cost to come by temporal differences, on the real transitions of every window the world
    /// model trains on. Kept in the state file with the two networks: its weights, its optimiser's moments and its
    /// updates.
    train_critic: bool = false,
    critic: kit_mod.CriticOptions = .{},
    /// The value tail in the policy's loss (`robot_latent_kit.LatentCritic.Tail`) - the critic's estimate of the cost
    /// after each window's last state - at its full weight, and the policy updates over which its weight ramps up from
    /// 0 to that, linearly: an untrained critic's slope is noise, so the tail starts silent and grows as the critic
    /// learns. With a full weight of 1 and a ramp of 1000 updates, the 250th policy update weighs the tail at 0.25,
    /// the 500th at 0.5, and every update from the 1000th on at 1. 0 leaves the policy's loss as it was; the tail
    /// needs the critic (`train_critic`).
    value_tail: f32 = 0,
    /// The ramp of TRUST IN THE CRITIC (`criticTrust`): over these many policy updates, everything that leans on the
    /// critic grows from nothing to its full weight - the tail, its pessimism, the planner's tail, teachers 2 and 3.
    value_tail_ramp_updates: u32 = 1000,
    /// The tail's pessimism (beta): it reads the critic's heads' mean plus beta of their spread, so the policy pays
    /// for what the critic disputes (`robot_latent_kit.LatentCritic.Tail.pessimism`). 0 reads the plain mean.
    value_tail_pessimism: f32 = 0,
    /// Which policy acts - in the rollout, in the fleet, for the judge (`robot_latent_kit.PolicyActor`): the Gaussian
    /// policy, or a flow policy (`robot_latent_kit.FlowActor`) that learns from SuperTrack's gradient through FlowDPG
    /// and acts with each character's own drifting noise. The flow needs the critic's layout, not the critic itself.
    actor: kit_mod.PolicyActor = .gaussian,
    /// The flow actor's settings, read when `actor` is `.flow`.
    flow: kit_mod.FlowSettings = .{},
    /// Planning for characters in danger (`PlanningSettings`); off unless enabled. It reads the head's height, so it
    /// needs the task's head body.
    planning: PlanningSettings = .{},
    /// One round: this many simulation steps, then this many updates of each network.
    collect: u32 = 32,
    world_updates: u32 = 1,
    policy_updates: u32 = 1,
    seed: u64 = 1,

    /// The policy's horizon in steps: `policy_window`, or the world model's `window` when that is 0.
    pub fn horizon(options: Options) u32 {
        return if (options.policy_window > 0) options.policy_window else options.window;
    }
};

/// The first bytes of a SuperTrack state file (`Resident.exportState`). The digit is the layout's version: it changes
/// whenever the layout below changes, so that a file of an older layout is refused rather than read as this one.
const state_file_magic: [8]u8 = "ZSTSTA18".*;

/// `Options` as a state file holds them: the same fields, with the same names and types, in an `extern struct`, so
/// that their bytes have one fixed layout on every machine. The check below keeps the two in step: an option added to
/// `Options` and forgotten here fails the build, instead of going unsaved and unchecked on resume.
pub const SavedOptions = extern struct {
    rows: u32,
    window: u32,
    policy_window: u32,
    return_window_share: f32,
    return_cost_cap: f32,
    hidden: u32,
    policy_hidden: u32,
    world_rate: f32,
    policy_rate: f32,
    policy_gradient_clip: f32,
    world_gradient_clip: f32,
    skip_span: u32,
    increment_spread_floor: f32,
    policy_element_clip: f32,
    policy_beta2: f32,
    rate_decay_updates: u32,
    rate_decay_hours: f32,
    rate_floor_share: f32,
    sigma: f32,
    filter: f32,
    // The two filter shares, eight bytes together: every later field stays where it is aligned.
    stiffness_filter: f32,
    w_action: f32,
    w_smooth: f32,
    barrier: kit_mod.FailureBarrier,
    train_critic: bool,
    sees_applied: bool,
    /// The two bytes after the two bools, written as zeros (`hasNoPadding`, `savedOptionsOf`).
    padding_after_train_critic: [2]u8,
    critic: kit_mod.CriticOptions,
    value_tail: f32,
    value_tail_ramp_updates: u32,
    value_tail_pessimism: f32,
    actor: kit_mod.PolicyActor,
    flow: kit_mod.FlowSettings,
    planning: PlanningSettings,
    collect: u32,
    world_updates: u32,
    policy_updates: u32,
    seed: u64,
};

// Every option is saved, with its own type, and nothing is saved that is not an option.
comptime {
    for (@typeInfo(Options).@"struct".field_names) |field_name| {
        if (!@hasField(SavedOptions, field_name)) {
            @compileError("robot_track_resident.Options." ++ field_name ++ " is no field of SavedOptions");
        }
        if (@FieldType(SavedOptions, field_name) != @FieldType(Options, field_name)) {
            @compileError("SavedOptions." ++ field_name ++ " has another type than the option it saves");
        }
    }
    for (@typeInfo(SavedOptions).@"struct".field_names) |field_name| {
        // A padding word saves no option: it is there so the saved bytes are all written (`hasNoPadding`).
        const is_padding: bool = startsWith(u8, field_name, "padding_");
        if (!is_padding and !@hasField(Options, field_name)) {
            @compileError("SavedOptions." ++ field_name ++ " saves no option of the learner");
        }
    }
}

/// Everything a state file holds before its numbers.
///
/// THE SHAPE comes first - how many features, references and actions the networks were built for, and how many
/// parameters each network has - so that a file from a differently built learner is refused by name instead of
/// loaded as the first N numbers of something else. THE OPTIONS the learner was trained with follow, then THE
/// COUNTERS, which are what makes a resumed learner the same learner rather than a new one holding old weights:
/// the update counters are also Adam's step counts, and the random stream's state decides every window drawn and
/// every exploration draw from here on.
///
/// Why Adam's step count matters: Adam divides its first moment by `1 - beta1^t` and its second by `1 - beta2^t`,
/// to undo their start at zero. With the kit's betas (0.9 and 0.999), after 1000 updates those divisors are about 1
/// and 0.632. A learner resumed with its moments but its count restarted at `t = 1` would divide by 0.1 and 0.001
/// instead: the first moment read 10 times too large, the second 1000 / 1.58 = 632 times, and the step - their
/// ratio, the second under a square root - `10 / sqrt(632)`, about 0.4 times what it should be, recovering only
/// over the next few thousand updates.
///
/// Numbers follow the header, every one an f32, in this order: the parameters of both networks (the world model's
/// then the policy's, as the kit packs them), Adam's first moments, Adam's second moments (each laid out like the
/// parameters), then the feature normaliser's means and spreads.
pub const StateHeader = extern struct {
    magic: [8]u8,
    feature_count: u32,
    reference_count: u32,
    action_count: u32,
    world_parameter_count: u32,
    policy_parameter_count: u32,
    /// The critic's parameters (its online and target heads), saved straight after the policy's - 0 without one.
    critic_parameter_count: u32,
    /// The flow actor's parameters, saved straight after the critic's - 0 without one - and how many numbers its
    /// characters' noise holds (characters x actions - 0 without a flow): a file from a fleet of another size is
    /// refused by name, not only by its length.
    flow_parameter_count: u32,
    flow_noise_count: u32,
    /// The skip model's parameters, saved straight after the flow's - 0 without one - and a word that keeps the header
    /// free of padding (`hasNoPadding`).
    skip_parameter_count: u32,
    reserved_after_skip: u32 = 0,
    options: SavedOptions,
    world_updates: u32,
    policy_updates: u32,
    /// The critic's updates - its Adam step count - and a word that keeps the counters after it 8-byte aligned.
    critic_updates: u32,
    reserved: u32 = 0,
    exposure: u64,
    failures: u64,
    judged_exposure: u64,
    judged_failures: u64,
    mirror_rejected: u64,
    nonfinite_actions: u64,
    /// The steps the fleet has taken under the learner (`Resident.acting_steps`): every hashed noise stream - the
    /// flow's, FPO's draws, the planner's - is seeded from it, so a resumed run carries on from it rather than starting
    /// them all over.
    acting_steps: u64,
    /// The xoshiro256 generator's four words - the whole of its state.
    random_stream_state: [4]u64,
};

/// Whether `T` - an extern struct, and every extern struct inside it, through arrays - has no padding: its fields'
/// sizes add up to its own. A state file copies its header byte for byte, so a padding byte would carry whatever the
/// stack held, and a learner saved twice would write two different files.
fn hasNoPadding(comptime T: type) bool {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |struct_info| {
            var field_bytes: usize = 0;
            inline for (struct_info.field_names) |field_name| {
                const FieldType: type = @FieldType(T, field_name);
                field_bytes += @sizeOf(FieldType);
                if (!hasNoPadding(FieldType)) {
                    return false;
                }
            }
            return field_bytes == @sizeOf(T);
        },
        .array => |array_info| return hasNoPadding(array_info.child),
        else => return true,
    }
}

comptime {
    if (!hasNoPadding(StateHeader)) {
        @compileError("StateHeader has padding: a state file would hold bytes the learner never wrote");
    }
}

/// Whether every f32 in `number_bytes` (little-endian, as a state file holds them, with no alignment owed) is finite,
/// and, with `must_be_positive`, above zero. Read one at a time, so a file's numbers are checked before any is copied.
fn numbersAreUsable(number_bytes: []const u8, must_be_positive: bool) bool {
    const number_count: usize = number_bytes.len / @sizeOf(f32);
    for (0..number_count) |number_index| {
        const number_at: usize = number_index * @sizeOf(f32);
        const number_bits: u32 = readInt(u32, number_bytes[number_at..][0..@sizeOf(f32)], .little);
        const number: f32 = @bitCast(number_bits);
        const is_finite: bool = isFinite(number);
        const sign_is_right: bool = !must_be_positive or number > 0.0;
        if (!is_finite or !sign_is_right) {
            return false;
        }
    }
    return true;
}

/// Whether no f32 in `number_bytes` (as `numbersAreUsable` reads them) is below zero.
fn noNumberIsNegative(number_bytes: []const u8) bool {
    const number_count: usize = number_bytes.len / @sizeOf(f32);
    for (0..number_count) |number_index| {
        const number_at: usize = number_index * @sizeOf(f32);
        const number_bits: u32 = readInt(u32, number_bytes[number_at..][0..@sizeOf(f32)], .little);
        const number: f32 = @bitCast(number_bits);
        if (number < 0.0) {
            return false;
        }
    }
    return true;
}

/// `options` in the form a state file holds them, copied field by field.
fn savedOptionsOf(options: Options) SavedOptions {
    // Zeros first: the bytes no option names - the padding words - are saved as zeros, not as whatever was there.
    var saved_options: SavedOptions = zeroes(SavedOptions);
    inline for (@typeInfo(Options).@"struct".field_names) |field_name| {
        @field(saved_options, field_name) = @field(options, field_name);
    }
    return saved_options;
}

/// The path of the first option a saved learner was trained with that differs from `wanted_options` - for example
/// `"options.policy_rate"` - or null when every option agrees.
///
/// Every option must agree, the step sizes and the noise included, and not only the ones that shape the networks. A
/// resumed run is meant to be the SAME run carried on, so its curves can be read as one; a run continued under
/// another setting is a different experiment, and is started as a run of its own.
fn optionsProblem(saved_options: SavedOptions, wanted_options: Options) ?[]const u8 {
    inline for (@typeInfo(Options).@"struct".field_names) |field_name| {
        const saved_value: @FieldType(Options, field_name) = @field(saved_options, field_name);
        const wanted_value: @FieldType(Options, field_name) = @field(wanted_options, field_name);
        // Field by field for a struct option (the failure barrier), as `==` is for a number.
        if (!metaEql(saved_value, wanted_value)) {
            return "options." ++ field_name;
        }
    }
    return null;
}

/// What `supertrackFeaturesInto` works in: the character's state, the reference's state, a model data the reference
/// is posed in (so the fleet's own is never disturbed), and one feature vector before it is normalised. Borrowed
/// pointers and slices, owned by whoever builds the scratch.
pub const FeatureScratch = struct {
    simulated: *track.State,
    reference: *track.State,
    probe: *rbt.Data,
    raw_features: []f32,
};

/// SuperTrack's two feature vectors for character `character` of `fleet`, normalised by `normalizer`: the STATE - the
/// character's simulated bodies in its root's frame (`robot_track.local`) - into `out_state`, and the GOAL - the
/// reference one frame ahead of the character's frame, in the same root's frame - into `out_goal`. The goal is where
/// the servo aims next, so the policy sees both where the character is and where it is meant to be a step from now,
/// each in the character's own frame of reference. Each feature becomes `(x - mean) / spread`.
///
/// One definition for every place a SuperTrack policy acts: the learner while it collects and is judged
/// (`Resident.featuresOf`), and the lab's player of its policy file (`robot_lab.PolicyDecider`). `scratch` holds the
/// intermediate states and is the caller's; nothing is allocated.
pub fn supertrackFeaturesInto(
    fleet: *track.Fleet,
    character: usize,
    normalizer: latent.Normalizer,
    scratch: FeatureScratch,
    out_goal: []f32,
    out_state: []f32,
) void {
    track.stateOf(fleet.m, &fleet.data[character], scratch.simulated);
    track.local(scratch.simulated.*, fleet.root, scratch.raw_features);
    normalizer.toNormal(scratch.raw_features, out_state);
    const clip: *const dance.Clip = fleet.clips[fleet.clip_of[character]];
    const next_frame: u32 = fleet.frame[character] + 1;
    fleet.referenceStateInto(clip, next_frame, scratch.probe, scratch.reference);
    track.local(scratch.reference.*, fleet.root, scratch.raw_features);
    normalizer.toNormal(scratch.raw_features, out_goal);
}

/// What a SuperTrack policy file is made of (`robot_lab.policyOfSuperTrack`), as the learner holds it: the policy's
/// weights as acting uses them (the mirror, packed as `LatentKit.packPolicy` packs them - the first layer reading the
/// goal then the state as one input, then the two later layers, each its weights then its biases), the network's
/// widths, and the feature normaliser. Every slice is the learner's, borrowed.
pub const PolicyParts = struct {
    packed_weights: []const f32,
    feature_count: usize,
    hidden_width: usize,
    action_count: usize,
    normalizer: latent.Normalizer,
    /// The action filter the policy acted through in training (`Options.filter`, the joints' offsets' share): a player
    /// gives its actions through the same filter, so it acts as the policy learned to.
    filter: f32,
};

/// THE POLICY AS THE CPU ACTS WITH IT: the policy's weights as the CPU last saw them, the flow's and the synergies'
/// when the learner has a flow, and the rows inference works in - everything choosing an action needs, and nothing of
/// the GPU's kit. An actor that runs on another thread or in a worker carries one of these: the weights arrive with
/// each round, the shapes are numbers. `goal` and `z` are the character's normalised goal and state
/// (`Resident.features` fills them), `raw` the action the inference leaves.
pub fn HostPolicy(comptime M: type) type {
    return struct {
        const Self = @This();

        /// The policy's weights as the CPU last saw them, and the rows its two hidden layers are computed in.
        mirror: []f32 = &.{},
        hidden1: []f32 = &.{},
        hidden2: []f32 = &.{},
        /// The character's normalised state and goal, and the raw action the inference leaves.
        z: []f32 = &.{},
        goal: []f32 = &.{},
        /// The action applied before this decision - the character's last given action - which the policy reads
        /// through the block packed after its layers (zero until trained). Empty: the policy does not read it.
        applied: []const f32 = &.{},
        raw: []f32 = &.{},
        /// The flow's value - its shapes and offsets, the same for the whole run - when the learner has a flow.
        flow: ?kit_mod.FlowActor(M) = null,
        /// The flow's weights as the CPU last saw them - the whole parameter buffer's length, as the flow's layers are
        /// addressed from the buffer's start, only the flow's range filled - and the host sampler's scratch: a
        /// condition, a wide row, two layer outputs, a velocity.
        flow_mirror: []f32 = &.{},
        flow_condition: []f32 = &.{},
        flow_input_scratch: []f32 = &.{},
        flow_layer_scratch: []f32 = &.{},
        flow_velocity_scratch: []f32 = &.{},
        /// A character's coefficients, as the host sampler leaves them, and the host's copy of the flow's synergies,
        /// [synergy][action] - written where the learner is built and restored on resume; never trained, so never
        /// read back.
        flow_coefficients: []f32 = &.{},
        synergies: []f32 = &.{},

        /// The policy's raw action for one character, from whatever `z` and `goal` hold, left in `raw`.
        /// It reads the mirror - the packed weights in `LatentKit.packPolicy`'s order: the goal block,
        /// the state block, then the later layers. Public so a page can ask the policy for an action
        /// without collecting a step, and so a test can put the GPU's own rows through it.
        pub fn policyRow(self: *Self) void {
            const hp: usize = self.hidden1.len;
            const f: usize = self.z.len;
            // Walking the packed weights, in the order `packPolicy` writes them. The first layer is two
            // blocks because a row is [goal | state] and the policy reads both: the goal block first
            // (the row starts with the goal), then the state block, then that layer's bias. After it,
            // the ordinary pairs. Every weight matrix is stored row by row of its INPUT - element
            // (i, j) at i * outputs + j - which is why each inner loop strides by `hp` (or by the
            // action count in the last layer).
            const w_goal: usize = 0;
            const w_state: usize = f * hp;
            const b1: usize = w_state + f * hp;
            const w2: usize = b1 + hp;
            const b2: usize = w2 + hp * hp;
            const w3: usize = b2 + hp;
            const b3: usize = w3 + hp * self.raw.len;
            // The block reading the action applied before the decision, after the third layer's bias, `actions x hp`.
            const w_applied: usize = b3 + self.raw.len;
            // The two input blocks are summed into one pre-activation in the kit's own order (`dense_fwd`
            // over the row [goal | state]): the bias, then every goal term, then every state term. Float
            // addition is not associative, so the order is what makes this policy and the kit's - on the
            // CPU twin, and the device's but for its own rounding - give the same actions to the bit.
            for (0..hp) |j| {
                var sum: f32 = self.mirror[b1 + j];
                for (self.goal, 0..) |g, i| {
                    sum += g * self.mirror[w_goal + i * hp + j];
                }
                for (self.z, 0..) |x, i| {
                    sum += x * self.mirror[w_state + i * hp + j];
                }
                // The action applied before this decision, through its own block, after the goal's and the state's
                // terms - the kit's order (`applied_add_activate`) - and only then the tanh.
                for (self.applied, 0..) |x, i| {
                    sum += x * self.mirror[w_applied + i * hp + j];
                }
                self.hidden1[j] = zm.tanh(sum);
            }
            for (0..hp) |j| {
                var sum: f32 = self.mirror[b2 + j];
                for (self.hidden1, 0..) |x, i| {
                    sum += x * self.mirror[w2 + i * hp + j];
                }
                self.hidden2[j] = zm.tanh(sum);
            }
            for (self.raw, 0..) |*out, j| {
                var sum: f32 = self.mirror[b3 + j];
                for (self.hidden2, 0..) |x, i| {
                    sum += x * self.mirror[w3 + i * self.raw.len + j];
                }
                out.* = sum;
            }
        }

        /// The policy's raw action CORRECTED by its flow, for one character, from whatever `goal` and `z` hold and
        /// the flow's starting noise `start_noise` (k coefficients' worth, already at its scale), left in `raw`: the
        /// policy's raw action (`policyRow`), then the flow's coefficients - K Euler steps on the host from the flow's
        /// mirror (`KitFlow.sampleHost`, the kit's own arithmetic) - decoded through the synergies and added,
        /// raw += B^T c, as the kit's `synergy_decode_add` does.
        pub fn correctedRow(self: *Self, start_noise: []const f32) void {
            const has_flow_actor: bool = self.flow != null;
            assertf(has_flow_actor, @src(), "correctedRow: this learner has no flow (`Options.actor`)", .{});
            const flow_actor: kit_mod.FlowActor(M) = self.flow.?;
            self.policyRow();
            const goal_width: usize = self.goal.len;
            @memcpy(self.flow_condition[0..goal_width], self.goal);
            @memcpy(self.flow_condition[goal_width..], self.z);
            flow_actor.flow.sampleHost(
                self.flow_mirror,
                self.flow_condition,
                start_noise,
                self.flow_input_scratch,
                self.flow_layer_scratch,
                self.flow_velocity_scratch,
                self.flow_coefficients,
            );
            self.addCorrection(self.flow_coefficients);
        }

        /// A correction added to `raw`, decoded as the device decodes it: through the flow's synergies - the host's
        /// copy - when the learner has a flow, and otherwise directly: the planner's own basis is the identity.
        fn addCorrection(self: *Self, correction: []const f32) void {
            const action_width: usize = self.raw.len;
            if (self.flow == null) {
                for (self.raw, correction) |*raw, correction_value| {
                    raw.* += correction_value;
                }
                return;
            }
            for (correction, 0..) |coefficient, synergy| {
                const direction: []const f32 = self.synergies[synergy * action_width ..][0..action_width];
                for (self.raw, direction) |*raw, direction_value| {
                    raw.* += coefficient * direction_value;
                }
            }
        }
    };
}

/// ONE TASK'S SCRATCH FOR ACTING (`Resident.computeAction`): the host policy's rows - its own, while the mirrored
/// weights are the learner's, read by every task - the states and the probe the features are computed in, and the
/// flow's starting noise. One per task the characters' actions are split into (`Resident.computeEveryAction`), so tasks
/// computing different characters at once share nothing they write.
pub fn ActingScratch(comptime M: type) type {
    return struct {
        const Self = @This();

        host: HostPolicy(M),
        simulated: track.State,
        reference: track.State,
        probe: rbt.Data,
        raw_features: []f32,
        flow_start_noise: []f32,

        /// Scratch shaped like `shape`'s rows, reading `shape`'s mirrored weights and flow, for model `m`. Memory:
        /// `gpa`, freed by `deinit`.
        pub fn init(
            gpa: Allocator,
            shape: HostPolicy(M),
            m: *const rbt.Model,
            flow_numbers: usize,
        ) !Self {
            var host: HostPolicy(M) = shape;
            host.hidden1 = try gpa.alloc(f32, shape.hidden1.len);
            host.hidden2 = try gpa.alloc(f32, shape.hidden2.len);
            host.z = try gpa.alloc(f32, shape.z.len);
            host.goal = try gpa.alloc(f32, shape.goal.len);
            host.raw = try gpa.alloc(f32, shape.raw.len);
            host.flow_condition = try gpa.alloc(f32, shape.flow_condition.len);
            host.flow_input_scratch = try gpa.alloc(f32, shape.flow_input_scratch.len);
            host.flow_layer_scratch = try gpa.alloc(f32, shape.flow_layer_scratch.len);
            host.flow_velocity_scratch = try gpa.alloc(f32, shape.flow_velocity_scratch.len);
            host.flow_coefficients = try gpa.alloc(f32, shape.flow_coefficients.len);
            const scratch: Self = .{
                .host = host,
                .simulated = try track.State.init(gpa, m.body_count),
                .reference = try track.State.init(gpa, m.body_count),
                .probe = try rbt.Data.init(gpa, m),
                .raw_features = try gpa.alloc(f32, track.localSize(m.body_count)),
                .flow_start_noise = try gpa.alloc(f32, flow_numbers),
            };
            return scratch;
        }

        /// Everything `init` allocated; the mirrored weights stay the learner's.
        pub fn deinit(scratch: *Self, gpa: Allocator) void {
            const host: HostPolicy(M) = scratch.host;
            gpa.free(host.hidden1);
            gpa.free(host.hidden2);
            gpa.free(host.z);
            gpa.free(host.goal);
            gpa.free(host.raw);
            gpa.free(host.flow_condition);
            gpa.free(host.flow_input_scratch);
            gpa.free(host.flow_layer_scratch);
            gpa.free(host.flow_velocity_scratch);
            gpa.free(host.flow_coefficients);
            scratch.simulated.deinit(gpa);
            scratch.reference.deinit(gpa);
            scratch.probe.deinit();
            gpa.free(scratch.raw_features);
            gpa.free(scratch.flow_start_noise);
        }

        /// The feature computation's view of this scratch (`supertrackFeaturesInto`).
        fn featureScratch(scratch: *Self) FeatureScratch {
            const view: FeatureScratch = .{
                .simulated = &scratch.simulated,
                .reference = &scratch.reference,
                .probe = &scratch.probe,
                .raw_features = scratch.raw_features,
            };
            return view;
        }
    };
}

pub fn Resident(comptime M: type) type {
    return struct {
        const Self = @This();
        const Kit = kit_mod.LatentKit(M);

        gpa: Allocator,
        options: Options,
        fleet: *track.Fleet,
        kit: Kit,
        data: kit_mod.Resident(M),
        /// Physics steps watched while collecting, and the failures among them - the reference LOST,
        /// not a clip simply running out. Exactly what the PPO bench counts, so a milestone reached
        /// here and one reached there mean the same thing.
        ///
        /// These are steps taken WITH exploration noise, because that is how data is collected. They
        /// therefore say how long the policy-plus-noise tracks, which is not the same question as how
        /// long the POLICY tracks - and comparing them against a servo measured without noise flatters
        /// the servo. The pair below answers the second question.
        exposure: u64,
        failures: u64,
        /// The same, per clip of the fleet: the steps each clip's characters were watched for while exploring, and the
        /// references they lost - so a run on two clips sees each on its own. Counted since the learner was made and
        /// not saved: only their recent rounds are read (the trainer's per-clip windows), while the totals above carry
        /// a run's whole history.
        exposure_by_clip: []u64,
        failures_by_clip: []u64,
        /// The same two, for steps taken with the noise turned off: the policy as it would actually be
        /// used, and the only number comparable with the servo's own.
        judged_exposure: u64,
        judged_failures: u64,
        /// Updates so far, which also seed the rollouts' noise.
        world_updates: u32,
        policy_updates: u32,
        /// The critic, when it trains (`Options.train_critic`), with the arena its descriptors live in, and its
        /// updates so far - Adam's step count.
        critic: ?kit_mod.LatentCritic(M),
        critic_arena: ArenaAllocator,
        critic_updates: u32,
        /// Where the learner's parameters end. Everything it keeps lies in [0, `params_end`) of the parameter buffer,
        /// in the order it is placed: the world model, the policy (by the kit), then the critic's heads and the flow's
        /// network (by the extras' layout, `buildExtras`). The readback reaches it and the state file saves that
        /// range, both from this one number - so a block placed later is read back and saved without anyone having to
        /// remember to add it.
        params_end: u32,
        /// The critic's parameters, placed straight after the two networks' (0 without a critic).
        critic_parameter_count: u32,
        /// The flow actor's parameters, placed straight after the critic's (0 without a flow actor); each character's
        /// drifting noise [envs][action] and the noise a sample starts from (the host's sampling itself is `host`'s).
        flow_parameter_count: u32,
        /// The skip model's parameters, after the flow's (`SkipModel`) - 0 without one.
        skip_parameter_count: u32,
        flow_noise: []f32,
        flow_start_noise: []f32,
        /// Planning (`Options.planning`): which characters plan and when, each character's hazard of the step being
        /// taken, who decides after it, and how many decisions have been due - none while planning is off.
        planning_flags: ?PlanningFlags,
        hazards: []f32,
        deciding: []bool,
        planning_decisions: u64,
        /// How many decisions have been made (each for every planning character at once).
        decisions_made: u64,
        /// The tracking planner (`Options.planning`); its MAILBOX in the parameter buffer - after the parameters,
        /// outside the saved range - where every decision leaves its chosen plans for the readback to bring back; and
        /// where the readback ends (the mailbox's end, or the parameters' without one).
        planner: ?kit_mod.TrackingPlanner(M),
        mailbox_at: u32,
        readback_end: u32,
        /// The device's numbers for the log (`kit_mod.DeviceStats`): where their block starts in the parameter buffer,
        /// after everything else the readback brings back, and the host's copy from the newest readback.
        stats_at: u32,
        device_stats: kit_mod.DeviceStats,
        /// The acting steps taken so far, which stamp each decision (its step plus one: 0 is "no decision yet"); which
        /// character held each planner slot at the last decision (a slot still held by the same character starts its
        /// search warm, from its last plan); and a decision's scratch - one slot's inputs, every slot's warm flag.
        acting_steps: u64,
        slot_owners: []?usize,
        slot_inputs: []f32,
        slot_warm_flags: []f32,
        /// For each slot, the decision step from which its current character has held it: a plan in the mailbox is
        /// this character's only if its decision came at or after that step - the readback can still be carrying a
        /// plan decided for the slot's previous character.
        slot_owner_since: []u32,
        /// Teacher 2's examples, a ring of [goal | state | correction] - every step a character took from its plan, its
        /// condition then and the plan's correction - how many it holds and where the next goes; and a round's batch,
        /// staged for upload.
        distillation_examples: []f32,
        distillation_example_count: usize,
        distillation_next: usize,
        distillation_batch_conditions: []f32,
        distillation_batch_corrections: []f32,
        /// Teacher 3's examples (`FlowActor.Fpo`), a ring of [own goal | goal | state | coefficients | next state] - a
        /// step the flow chose for a character in recovery and where it led - how many it holds and where the next
        /// goes; each character's PENDING example, all but the next state, waiting for the next step; and a round's
        /// batch, staged for upload.
        fpo_examples: []f32,
        fpo_example_count: usize,
        fpo_next: usize,
        fpo_pending: []f32,
        fpo_pending_valid: []bool,
        fpo_batch: []f32,
        /// Each character's goal at its last acting step - the goal of the frame it is in now, which the critic reads
        /// beside its state (`FlowActor.Fpo`) - and whether that step was in the same episode.
        fpo_own_goals: []f32,
        fpo_own_goal_valid: []bool,
        /// The host's copy of the mailbox, refreshed from the newest readback at every acting step; and each
        /// character's hazard at the step before, for the projection - KNOWN only once it has had a step in its
        /// current episode (not at the start, not after a restart, where a "rise" from another episode's hazard would
        /// be invented).
        mailbox_copy: []f32,
        previous_hazards: []f32,
        previous_hazard_known: []bool,
        /// Readbacks refused because a weight was not finite (the mirror kept the last good ones), and
        /// actions the policy produced that were not finite (replaced by zero - the servo alone). Both
        /// should stay 0; if either climbs, training has blown up on the device - and now it says so
        /// instead of feeding NaN to the physics.
        mirror_rejected: u64,
        nonfinite_actions: u64,
        /// Updates SKIPPED because the replay could not supply their windows (`drawWindows`): a window must lie
        /// inside one segment, so pushes and restarts that cut the replay into stretches shorter than the policy's
        /// horizon starve training without an error. Logged, so a run that has stopped learning says why.
        windows_refused: u64,
        /// How much of each kernel buffer the learner's layout uses - activations, their gradients, parameters, in
        /// floats (`kit_mlp.KitLayout`) - for a run to say at its start how much room it has.
        buffers_used: kit_mlp.KitLayout = .{},
        /// The hours this learner's training has run, told each round by the program that trains (the trainer's saved
        /// clock): what the rates' schedule in hours follows (`Options.rate_decay_hours`). 0 for a learner nobody
        /// times.
        training_hours: f32 = 0,
        /// Exploring steps a character took from its plan (`finishActing`) - over the steps watched, the share of the
        /// acting the planner steered.
        planned_steps: u64,
        rng: Random.DefaultPrng,
        /// The normaliser, host-side, for the features acting needs.
        norm: latent.Normalizer,
        /// THE POLICY AS THE CPU ACTS WITH IT (`HostPolicy`): the mirrored weights and the rows inference works in.
        host: HostPolicy(M),
        // Scratch for acting.
        sim: track.State,
        reference: track.State,
        probe: rbt.Data,
        raw_features: []f32,
        actions: []f32,
        /// ONE ACTING STEP, A ROW PER CHARACTER - what `act`'s three phases hand one another (`prepareActing`,
        /// `computeAction`, `finishActing`). Each character's normalised state and goal (`features`), [characters]
        /// [features] each, and the raw action it chose, [characters][actions]: written by its own phase 2, read back
        /// by its phase 3.
        acting_z: []f32 = &.{},
        acting_goal: []f32 = &.{},
        acting_raw: []f32 = &.{},
        /// The random numbers each character's action uses, drawn in phase 1 in the characters' order: the flow's
        /// fresh noise (one per synergy, with a flow), then the exploration's (one per action) - `acting_noise_width` a
        /// character. Untouched for a character acting from its plan, which draws none.
        acting_noise: []f32 = &.{},
        acting_noise_width: usize = 0,
        /// The plan each character acts from this step, if any: its correction, a slice of `mailbox_copy`, which does
        /// not change within a step.
        acting_planned: []?[]const f32 = &.{},
        /// One scratch per task phase 2 is split into (`computeEveryAction`) - as many as the fleet's physics tasks.
        acting_scratches: []ActingScratch(M) = &.{},
        starts: []kit_mod.Start,

        /// The policy's optimiser's settings from the learner's options (`Options.policy_gradient_clip` and the two
        /// after it): a bound of 0 is none - the largest float, so the clipping's factor is exactly 1 - and Adam's
        /// first-moment decay is the kit's own, so the defaults reproduce the kit's unclipped Adam number for number.
        fn policyOptimizerSettings(options: Options) kit_mlp.ClippedAdam.Settings {
            const largest: f32 = floatMax(f32);
            const gradient_clip: f32 = if (options.policy_gradient_clip > 0) options.policy_gradient_clip else largest;
            const settings: kit_mlp.ClippedAdam.Settings = .{
                .gradient_clip = gradient_clip,
                .element_clip = options.policy_element_clip,
                .beta1 = Kit.beta1,
                .beta2 = options.policy_beta2,
            };
            return settings;
        }

        /// Build the loop on a fleet whose replay already holds data, with the normaliser it should
        /// use (the reference clips' statistics, or the replay's). The tables are uploaded here; the
        /// ring is filled by `act`, so call it before training on anything.
        pub fn init(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            fleet: *track.Fleet,
            norm: latent.Normalizer,
            options: Options,
        ) !*Self {
            const filter_in_range: bool = options.filter > 0.0 and options.filter <= 1.0;
            assertf(filter_in_range, @src(), "the filter {d}: a share of the new action, in (0, 1]", .{options.filter});
            const self: *Self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const m: *rbt.Model = fleet.m;
            const feature_count: u32 = @intCast(track.localSize(m.body_count));
            const actions: u32 = @intCast(track.actionSize(m));
            // This trainer's policy outputs the joints' offsets alone: a fleet whose actions also hold each limb's
            // stiffness is refused by name, not read with the wrong width.
            const fleet_learns_offsets_alone: bool = fleet.action_width == actions;
            if (!fleet_learns_offsets_alone) {
                return error.LimbStiffnessNotLearnedByThisTrainer;
            }
            // whole-init-first: the whole struct first - defaults applied, every field named.
            self.* = .{
                .gpa = undefined,
                .options = undefined,
                .fleet = undefined,
                .kit = undefined,
                .data = undefined,
                .exposure = undefined,
                .exposure_by_clip = &.{},
                .failures_by_clip = &.{},
                .failures = undefined,
                .judged_exposure = undefined,
                .judged_failures = undefined,
                .world_updates = undefined,
                .critic = null,
                .critic_arena = ArenaAllocator.init(gpa),
                .critic_updates = 0,
                .params_end = 0,
                .critic_parameter_count = 0,
                .host = .{},
                .flow_parameter_count = 0,
                .skip_parameter_count = 0,
                .flow_noise = &.{},
                .flow_start_noise = &.{},
                .planning_flags = null,
                .hazards = &.{},
                .deciding = &.{},
                .planning_decisions = 0,
                .decisions_made = 0,
                .planner = null,
                .mailbox_at = 0,
                .readback_end = 0,
                .stats_at = 0,
                .device_stats = .{},
                .acting_steps = 0,
                .slot_owners = &.{},
                .slot_inputs = &.{},
                .slot_warm_flags = &.{},
                .slot_owner_since = &.{},
                .distillation_examples = &.{},
                .distillation_example_count = 0,
                .distillation_next = 0,
                .distillation_batch_conditions = &.{},
                .distillation_batch_corrections = &.{},
                .fpo_examples = &.{},
                .fpo_example_count = 0,
                .fpo_next = 0,
                .fpo_pending = &.{},
                .fpo_pending_valid = &.{},
                .fpo_batch = &.{},
                .fpo_own_goals = &.{},
                .fpo_own_goal_valid = &.{},
                .mailbox_copy = &.{},
                .previous_hazards = &.{},
                .previous_hazard_known = &.{},
                .policy_updates = undefined,
                .mirror_rejected = undefined,
                .nonfinite_actions = undefined,
                .windows_refused = undefined,
                .planned_steps = undefined,
                .rng = undefined,
                .norm = undefined,
                .sim = undefined,
                .reference = undefined,
                .probe = undefined,
                .raw_features = undefined,
                .actions = undefined,
                .starts = undefined,
            };
            self.gpa = gpa;
            self.options = options;
            self.fleet = fleet;
            // Everything set here rather than by field defaults: `gpa.create` hands back uninitialised
            // memory, so a default written on a field would never be applied.
            self.exposure = 0;
            self.failures = 0;
            self.exposure_by_clip = try gpa.alloc(u64, fleet.clips.len);
            errdefer gpa.free(self.exposure_by_clip);
            @memset(self.exposure_by_clip, 0);
            self.failures_by_clip = try gpa.alloc(u64, fleet.clips.len);
            errdefer gpa.free(self.failures_by_clip);
            @memset(self.failures_by_clip, 0);
            self.mirror_rejected = 0;
            self.nonfinite_actions = 0;
            self.windows_refused = 0;
            self.planned_steps = 0;
            self.judged_exposure = 0;
            self.judged_failures = 0;
            self.world_updates = 0;
            self.policy_updates = 0;
            self.rng = Random.DefaultPrng.init(options.seed);
            // The kit as long as the policy's horizon, the world model's passes stopping at its own window.
            const horizon: u32 = options.horizon();
            const fits_window: bool = horizon >= options.window;
            assertf(fits_window, @src(), "a policy window of {d} is shorter than the world model's {d}", .{
                horizon,
                options.window,
            });
            self.kit = try Kit.init(
                pipe,
                feature_count,
                @intCast(track.targetSize(m)),
                actions,
                options.hidden,
                options.rows,
                horizon,
                feature_count,
                options.policy_hidden,
            );
            self.kit.world_steps = options.window;
            self.kit.sigma = options.sigma;
            self.kit.w_action = options.w_action;
            self.kit.w_smooth = options.w_smooth;
            // The action filter as this trainer applies it when acting (`writeAction`), so the rollouts blend the same
            // way. Its actions are the joints' offsets alone (refused otherwise above): no number is a stiffness.
            self.kit.filter = options.filter;
            self.kit.stiffness_filter = options.stiffness_filter;
            self.kit.stiffness_count = 0;
            self.kit.sees_applied = options.sees_applied;
            // The failure barrier reads two features of the rolled state: the head's world height, and the world's up
            // seen from the root. Where they are follows from `track.local`'s layout, which writes, for the B
            // character bodies (every body but the world), four blocks of per-body numbers, then one height per
            // body, then up's three numbers:
            //
            //     positions 3B | rotations 6B | velocities 3B | angular velocities 3B | heights B | up 3
            //
            // so the heights start at 15B, the head's is the head body's entry among them (bodies counted from 1, the
            // world being body 0), and up starts right after the heights.
            self.kit.barrier = options.barrier;
            self.kit.cost_cap = options.return_cost_cap;
            const barrier_has_its_head: bool = options.barrier.weight == 0 or fleet.head != null;
            assertf(barrier_has_its_head, @src(), "the failure barrier needs the task's head body", .{});
            // With the barrier off there may be no head; any body serves, as nothing reads the column.
            const head_body: usize = fleet.head orelse 1;
            self.kit.barrier_head_column = @intCast(track.localHeightColumn(m.body_count, head_body));
            self.kit.barrier_up_column = @intCast(track.localUpColumn(m.body_count));
            // Planning judges danger by the head's height and the up direction, so it needs the task's head body.
            if (options.planning.enabled) {
                const has_head: bool = fleet.head != null;
                assertf(has_head, @src(), "planning reads the head's height: the task needs a head body", .{});
                // The hazard is a fraction of the barrier's margins: they must be above zero.
                const barrier: kit_mod.FailureBarrier = options.barrier;
                const margins_positive: bool = barrier.head_margin > 0 and barrier.tilt_margin > 0;
                assertf(margins_positive, @src(), "planning measures danger against the barrier's margins", .{});
                const character_count: usize = fleet.options.envs;
                const flags: PlanningFlags = try .init(gpa, character_count, options.planning.flags.budget);
                self.planning_flags = flags;
                self.hazards = try gpa.alloc(f32, character_count);
                @memset(self.hazards, 0);
                self.deciding = try gpa.alloc(bool, character_count);
                @memset(self.deciding, false);
                self.previous_hazards = try gpa.alloc(f32, character_count);
                @memset(self.previous_hazards, 0);
                self.previous_hazard_known = try gpa.alloc(bool, character_count);
                @memset(self.previous_hazard_known, false);
            }
            // The kit's action scale stays 1: the fleet applies the one scale, and the world model
            // learns from the action the fleet records - the raw output plus its noise.
            const slots: u32 = options.world_updates + options.policy_updates;
            self.data = try kit_mod.Resident(M).init(gpa, pipe, fleet, self.kit.total, options.rows, slots);
            errdefer self.data.deinit();
            self.data.uploadTables(fleet);
            self.data.uploadNormalizer(norm);
            self.kit.norm_at = self.data.norm_at;
            const tail_without_critic: bool = options.value_tail > 0 and !options.train_critic;
            assertf(!tail_without_critic, @src(), "the value tail needs the critic (train_critic)", .{});
            // The parameters end where the kit's policy ends - or, with extras, where their layout ends - and the
            // readback ends with them, unless a mailbox follows them.
            self.params_end = self.kit.p_at + self.kit.policy_count;
            self.readback_end = self.params_end;
            const has_skip_model: bool = options.skip_span > 0;
            const has_extras: bool = options.train_critic or options.actor == .flow or options.planning.enabled or
                has_skip_model;
            // Everything the learner adds after the kit and its data, reserved from ONE layout so that their regions
            // follow one another: the policy's optimiser, then - with extras - the critic, the flow and the planner.
            var layout: kit_mlp.KitLayout = .{
                .acts_floats = self.data.end,
                .params_floats = self.params_end,
                .dacts_floats = self.kit.dtotal,
            };
            // The change's statistics first - every kit placed after this one copies them from it.
            if (options.increment_spread_floor > 0) {
                // The normaliser given to `init`: the learner keeps its own copy only further on.
                try self.placeIncrements(&layout, options.increment_spread_floor, norm);
            }
            if (self.kit.policy_count > 0) {
                self.kit.policy_optimizer = kit_mlp.ClippedAdam.reserve(&layout, self.kit.p_at, self.kit.policy_count);
                self.kit.policy_optimizer_settings = policyOptimizerSettings(options);
            }
            // The world model's own clipped optimiser, when its gradient is bounded.
            if (options.world_gradient_clip > 0) {
                self.kit.world_optimizer = kit_mlp.ClippedAdam.reserve(&layout, self.kit.w1, self.kit.param_count);
                self.kit.world_optimizer_settings = .{ .gradient_clip = options.world_gradient_clip };
            }
            if (has_extras) {
                try self.buildExtras(options, &layout);
            }
            try layout.checkFitsKit(M);
            self.buffers_used = layout;
            // The device's numbers for the log, after everything else the readback brings back - every learner keeps
            // them, extras or not (`kit_mod.DeviceStats`).
            self.stats_at = self.readback_end;
            self.readback_end += kit_mod.DeviceStats.floats;
            self.kit.stats_at = self.stats_at;
            if (self.critic) |*critic| {
                critic.stats_at = self.stats_at;
            }
            if (self.planner) |*planner| {
                planner.stats_at = self.stats_at;
            }
            self.norm = .{
                .mean = try gpa.dupe(f32, norm.mean),
                .spread = try gpa.dupe(f32, norm.spread),
            };
            errdefer gpa.free(self.norm.mean);
            errdefer gpa.free(self.norm.spread);
            self.host.mirror = try gpa.alloc(f32, self.kit.policy_count);
            errdefer gpa.free(self.host.mirror);
            // ZEROED, not left as `alloc` found it: if the first readback cannot fill it (the host's
            // readback window starts at nothing), acting would otherwise run on uninitialised memory
            // and simulate nonsense for a whole round. All zeros is the servo alone - no correction.
            @memset(self.host.mirror, 0.0);
            self.sim = try track.State.init(gpa, m.body_count);
            errdefer self.sim.deinit(gpa);
            self.reference = try track.State.init(gpa, m.body_count);
            errdefer self.reference.deinit(gpa);
            self.probe = try rbt.Data.init(gpa, m);
            errdefer self.probe.deinit();
            self.raw_features = try gpa.alloc(f32, feature_count);
            errdefer gpa.free(self.raw_features);
            self.host.z = try gpa.alloc(f32, feature_count);
            errdefer gpa.free(self.host.z);
            self.host.goal = try gpa.alloc(f32, feature_count);
            errdefer gpa.free(self.host.goal);
            self.host.raw = try gpa.alloc(f32, actions);
            errdefer gpa.free(self.host.raw);
            self.host.hidden1 = try gpa.alloc(f32, options.policy_hidden);
            errdefer gpa.free(self.host.hidden1);
            self.host.hidden2 = try gpa.alloc(f32, options.policy_hidden);
            errdefer gpa.free(self.host.hidden2);
            self.actions = try gpa.alloc(f32, fleet.options.envs * actions);
            errdefer gpa.free(self.actions);
            self.starts = try gpa.alloc(kit_mod.Start, options.rows);
            errdefer gpa.free(self.starts);
            // The readback has to reach the policy's weights, or the mirror can never be refreshed and
            // the simulation would act on the seeded weights for ever. Widen it, never narrow it: the
            // caller may want more of the buffers than this.
            // Every parameter the learner keeps must come back in the readback, or the mirrors and the state file would
            // be left without them: the readback reaches `params_end`.
            pipe.element_count = @max(pipe.element_count, self.readback_end);
            try self.seedWeights();
            self.syncMirror();
            // One step's acting, per character (`act`'s phases) - every row it copies, and the flow's width, known now.
            const acting_feature_count: usize = self.host.z.len;
            const acting_action_count: usize = self.host.raw.len;
            const acting_characters: usize = fleet.options.envs;
            const flow_numbers: usize = if (self.kit.flow_actor != null) self.flow_start_noise.len else 0;
            self.acting_noise_width = flow_numbers + acting_action_count;
            self.acting_z = try gpa.alloc(f32, acting_characters * acting_feature_count);
            self.acting_goal = try gpa.alloc(f32, acting_characters * acting_feature_count);
            self.acting_raw = try gpa.alloc(f32, acting_characters * acting_action_count);
            self.acting_noise = try gpa.alloc(f32, acting_characters * self.acting_noise_width);
            self.acting_planned = try gpa.alloc(?[]const f32, acting_characters);
            @memset(self.acting_planned, null);
            // One acting scratch per physics task: phase 2 is split as the fleet's physics is.
            self.acting_scratches = try gpa.alloc(ActingScratch(M), fleet.drive_scratches.len);
            for (self.acting_scratches) |*scratch| {
                scratch.* = try ActingScratch(M).init(gpa, self.host, fleet.m, flow_numbers);
            }
            return self;
        }

        /// THE CHANGE'S STATISTICS (`Options.increment_spread_floor`): measured from the fleet's clips in
        /// `normalizer`'s units (`robot_latent.measureClipIncrements`), each spread at least `spread_floor`, and placed
        /// for the kit - the means and spreads, then each feature's loss weight 1 / spread squared - in regions
        /// reserved in `layout`. Fixed before the first step and measured again, identically, on a resume. Memory:
        /// the measurement's slices with the learner's `gpa`, freed before it returns.
        fn placeIncrements(
            self: *Self,
            layout: *kit_mlp.KitLayout,
            spread_floor: f32,
            normalizer: latent.Normalizer,
        ) !void {
            const gpa: Allocator = self.gpa;
            const fleet_clips: []const *const dance.Clip = self.fleet.clips;
            const increments: latent.Normalizer =
                try latent.measureClipIncrements(gpa, self.fleet.m, fleet_clips, normalizer, spread_floor);
            defer gpa.free(increments.mean);
            defer gpa.free(increments.spread);
            const feature_count: u32 = self.kit.features;
            const statistics: []f32 = try gpa.alloc(f32, 3 * feature_count);
            defer gpa.free(statistics);
            @memcpy(statistics[0..feature_count], increments.mean);
            @memcpy(statistics[feature_count..][0..feature_count], increments.spread);
            for (statistics[2 * feature_count ..][0..feature_count], increments.spread) |*weight, spread| {
                weight.* = 1.0 / (spread * spread);
            }
            const increments_at: u32 = layout.reserveActs(2 * feature_count);
            const loss_weights_at: u32 = layout.reserveActs(feature_count);
            self.kit.pipe.uploadAt(.acts, increments_at, statistics[0 .. 2 * feature_count]);
            self.kit.pipe.uploadAt(.acts, loss_weights_at, statistics[2 * feature_count ..][0..feature_count]);
            self.kit.increments_at = increments_at;
            self.kit.loss_weights_at = loss_weights_at;
        }

        /// Both networks' starting weights, and a clean optimiser: Xavier for the tanh layers, and a
        /// near-zero output layer each, so the world model starts as "nothing changes" and the policy
        /// as "no correction" - the servo alone. Without this the weights would be whatever the buffer
        /// held; all zeros, and no gradient could ever break their symmetry.
        fn seedWeights(self: *Self) !void {
            const kit: Kit = self.kit;
            const total: usize = kit.param_count + kit.policy_count;
            const weights: []f32 = try self.gpa.alloc(f32, total);
            defer self.gpa.free(weights);
            const random: Random = self.rng.random();
            const f: usize = self.host.z.len;
            const r: usize = kit.references;
            const a: usize = self.host.raw.len;
            const h: usize = kit.hidden;
            const hp: usize = self.host.hidden1.len;
            // Each layer as (how many weights, its fan-in, whether it is a hidden layer): the world
            // model's stacked first layer and its two more, then the policy's, in the packed order the
            // kit reads them. Fan-in 0 marks a BIAS - zeroed, as biases should start. A hidden layer
            // gets Xavier's 1/sqrt(fan-in), which keeps a tanh layer's outputs in its useful range
            // instead of saturated; an output layer gets a hundredth of that, so both networks begin as
            // the identity of their job - the world model predicting "nothing changes", the policy
            // "no correction", which is the servo alone. Last, the policy's block for the action applied
            // before its decision, at ZERO like a bias: the policy starts out as the one that cannot see it.
            const layers = [_][3]usize{
                .{ (f + r + a) * h, f + r + a, 1 }, .{ h, 0, 0 },
                .{ h * h, h, 1 },                   .{ h, 0, 0 },
                .{ h * f, h, 0 },                   .{ f, 0, 0 },
                .{ 2 * f * hp, 2 * f, 1 },          .{ hp, 0, 0 },
                .{ hp * hp, hp, 1 },                .{ hp, 0, 0 },
                .{ hp * a, hp, 0 },                 .{ a, 0, 0 },
                .{ a * hp, 0, 0 },
            };
            var at: usize = 0;
            for (layers) |layer| {
                const count: usize = layer[0];
                const fan: usize = layer[1];
                const deviation: f32 = if (fan == 0)
                    0.0
                else
                    @sqrt(1.0 / float(fan)) * @as(f32, if (layer[2] == 0) 0.01 else 1.0);
                for (weights[at..][0..count]) |*w| {
                    w.* = deviation * random.floatNorm(f32);
                }
                at += count;
            }
            assertf(at == total, @src(), "seedWeights: filled {d} of {d} weights", .{ at, total });
            kit.pipe.upload(.params, weights);
            @memset(weights, 0.0);
            kit.pipe.upload(.adam_m, weights);
            kit.pipe.upload(.adam_v, weights);
        }

        pub fn deinit(self: *Self) void {
            const gpa: Allocator = self.gpa;
            gpa.free(self.exposure_by_clip);
            gpa.free(self.failures_by_clip);
            self.critic_arena.deinit();
            gpa.free(self.host.flow_mirror);
            gpa.free(self.flow_noise);
            gpa.free(self.host.flow_condition);
            gpa.free(self.host.flow_input_scratch);
            gpa.free(self.host.flow_layer_scratch);
            gpa.free(self.host.flow_velocity_scratch);
            gpa.free(self.flow_start_noise);
            gpa.free(self.host.flow_coefficients);
            gpa.free(self.host.synergies);
            gpa.free(self.acting_z);
            gpa.free(self.acting_goal);
            gpa.free(self.acting_raw);
            gpa.free(self.acting_noise);
            gpa.free(self.acting_planned);
            for (self.acting_scratches) |*scratch| {
                scratch.deinit(gpa);
            }
            gpa.free(self.acting_scratches);
            if (self.planning_flags) |flags| {
                flags.deinit(gpa);
            }
            gpa.free(self.hazards);
            gpa.free(self.deciding);
            gpa.free(self.slot_owners);
            gpa.free(self.slot_inputs);
            gpa.free(self.slot_warm_flags);
            gpa.free(self.slot_owner_since);
            gpa.free(self.distillation_examples);
            gpa.free(self.distillation_batch_conditions);
            gpa.free(self.distillation_batch_corrections);
            gpa.free(self.fpo_examples);
            gpa.free(self.fpo_pending);
            gpa.free(self.fpo_pending_valid);
            gpa.free(self.fpo_batch);
            gpa.free(self.fpo_own_goals);
            gpa.free(self.fpo_own_goal_valid);
            gpa.free(self.mailbox_copy);
            gpa.free(self.previous_hazards);
            gpa.free(self.previous_hazard_known);
            gpa.free(self.starts);
            gpa.free(self.actions);
            gpa.free(self.host.hidden2);
            gpa.free(self.host.hidden1);
            gpa.free(self.host.raw);
            gpa.free(self.host.goal);
            gpa.free(self.host.z);
            gpa.free(self.raw_features);
            self.probe.deinit();
            self.reference.deinit(gpa);
            self.sim.deinit(gpa);
            gpa.free(self.host.mirror);
            gpa.free(self.norm.spread);
            gpa.free(self.norm.mean);
            self.data.deinit();
            gpa.destroy(self);
        }

        /// The policy's weights as the CPU sees them from here on. On a GPU the readback is a frame or
        /// so old, which is why acting can use it at all: waiting for a fresh one would stall the
        /// simulation every step.
        pub fn syncMirror(self: *Self) void {
            // No readback yet (nothing has come back from the device), or one too narrow to reach the
            // policy's weights: keep the mirror as it is rather than copy half a policy. `init` widens
            // the readback so this cannot be the steady state - it is the first frame or two, when the
            // mirror still holds the weights the driver seeded.
            const params: []const f32 = self.kit.pipe.readLatest(.params) orelse return;
            if (params.len < self.kit.p_at + self.kit.policy_count) {
                return;
            }
            const weights: []const f32 = params[self.kit.p_at..][0..self.kit.policy_count];
            for (weights) |w| {
                if (!(w == w and @abs(w) < 1.0e30)) {
                    self.mirror_rejected += 1;
                    return;
                }
            }
            @memcpy(self.host.mirror, weights);
            // The flow's weights, when it acts: its range of the buffer into its mirror, all finite or none.
            if (self.kit.flow_actor) |flow_actor| {
                const flow_start: u32 = flow_actor.flow.network.paramsStart();
                const flow_end: u32 = flow_actor.flow.network.paramsEnd();
                if (params.len < flow_end) {
                    return;
                }
                const flow_weights: []const f32 = params[flow_start..flow_end];
                for (flow_weights) |weight| {
                    if (!(weight == weight and @abs(weight) < 1.0e30)) {
                        self.mirror_rejected += 1;
                        return;
                    }
                }
                @memcpy(self.host.flow_mirror[flow_start..flow_end], flow_weights);
            }
        }

        /// How one call to `act` acts, the same for every character and step of it: its noise scale, whether
        /// characters may act from plans (not when judging), and how much of itself each character's flow noise keeps
        /// from one step to the next - longer while it plans.
        const Acting = struct {
            noise_scale: f32,
            may_act_from_plans: bool,
            noise_correlation: f32,
            flagged_noise_correlation: f32,
        };

        /// Character `env`'s hazard - of whatever `z` and `goal` hold (`features`) - projected a few steps ahead along
        /// its rise, for the planning flags (`projectedHazard`). With no hazard before it in this episode there is no
        /// rise to project, and the hazard is read as it is. Nothing without planning.
        fn projectHazard(self: *Self, env: usize) void {
            if (self.planning_flags == null) {
                return;
            }
            const hazard: f32 = self.characterHazard();
            const is_known: bool = self.previous_hazard_known[env];
            const previous_hazard: f32 = if (is_known) self.previous_hazards[env] else hazard;
            const lookahead_steps: f32 = self.options.planning.lookahead_steps;
            self.hazards[env] = projectedHazard(hazard, previous_hazard, lookahead_steps);
            self.previous_hazards[env] = hazard;
            self.previous_hazard_known[env] = true;
        }

        /// PHASE 1 OF AN ACTING STEP, character `env` (`act`): whether it acts from a plan, and - when it does not -
        /// every random number its action will use: the flow's fresh noise (one per synergy) when the learner has a
        /// flow, then the exploration's (one per action); none at a noise scale of zero, none for a character acting
        /// from its plan. The flow's come from the learner's one random stream, so they are drawn here, on the
        /// calling thread, in the characters' order; the exploration's are drawn by counter (`rbt.explorationNoise`'s
        /// draws), the same on a device. Each character then holds its own numbers, and its action - phase 2 - comes
        /// out the same wherever and in whatever order it is computed.
        fn prepareActing(self: *Self, env: usize, acting: Acting, random: Random) void {
            const planned: ?[]const f32 = if (acting.may_act_from_plans) self.plannedCorrection(env) else null;
            self.acting_planned[env] = planned;
            if (planned != null or acting.noise_scale == 0.0) {
                return;
            }
            const numbers: []f32 = self.acting_noise[env * self.acting_noise_width ..][0..self.acting_noise_width];
            const flow_count: usize = if (self.kit.flow_actor != null) self.flow_start_noise.len else 0;
            for (numbers[0..flow_count]) |*fresh| {
                fresh.* = random.floatNorm(f32);
            }
            const spread: f32 = acting.noise_scale * self.options.sigma;
            if (spread == 0.0) {
                return;
            }
            // The exploration's numbers by counter - the world, the decision about to be stepped (the fleet's step
            // advances its number first, so this decision's pushes share the count), the action - exactly the draws of
            // `rbt.explorationNoise`, so a simulator on the device explores with the very same numbers.
            const decision: u32 = self.fleet.decision_number + 1;
            const world: u32 = @intCast(env);
            for (numbers[flow_count..][0..self.host.raw.len], 0..) |*exploration, action_index| {
                const action: u32 = @intCast(action_index);
                exploration.* = rbt.drawNormal(self.fleet.draw_seed, world, decision, .explore_action, action);
            }
        }

        /// PHASE 2, character `env`: its features and its raw action - from its plan, or from the policy (and the
        /// flow, from its drifting noise one step further) plus the exploration, with the numbers phase 1 drew - into
        /// its own rows (`acting_z`, `acting_goal`, `acting_raw`). Nothing another character's phase 2 reads or writes.
        fn computeAction(
            self: *Self,
            env: usize,
            acting: Acting,
            scratch: *ActingScratch(M),
        ) void {
            const host: *HostPolicy(M) = &scratch.host;
            supertrackFeaturesInto(self.fleet, env, self.norm, scratch.featureScratch(), host.goal, host.z);
            // The action applied before this decision - the character's slot, holding what it was given last - which
            // the policy reads through its block.
            const action_width: usize = host.raw.len;
            host.applied = self.actions[env * action_width ..][0..action_width];
            if (self.acting_planned[env]) |planned_correction| {
                host.policyRow();
                host.addCorrection(planned_correction);
            } else {
                const is_planning: bool = if (self.planning_flags) |flags| flags.slots[env] != null else false;
                const flagged_correlation: f32 = acting.flagged_noise_correlation;
                const correlation: f32 = if (is_planning) flagged_correlation else acting.noise_correlation;
                const width: usize = self.acting_noise_width;
                const numbers: []const f32 = self.acting_noise[env * width ..][0..width];
                self.exploringActionFrom(env, acting.noise_scale, correlation, numbers, scratch);
            }
            const feature_count: usize = host.z.len;
            const action_count: usize = host.raw.len;
            @memcpy(self.acting_z[env * feature_count ..][0..feature_count], host.z);
            @memcpy(self.acting_goal[env * feature_count ..][0..feature_count], host.goal);
            @memcpy(self.acting_raw[env * action_count ..][0..action_count], host.raw);
        }

        /// PHASE 2 FOR EVERY CHARACTER (`computeAction`): split into tasks of consecutive characters, one per acting
        /// scratch, on the fleet's threads (`track.Fleet.physics_io`) and waited for - or, without threads, one loop
        /// here. Each character's action depends on its own numbers and the shared, unchanging weights alone, so the
        /// split changes nothing in them.
        fn computeEveryAction(self: *Self, acting: Acting) void {
            const character_count: usize = self.fleet.options.envs;
            const task_count: usize = self.acting_scratches.len;
            const io: Io = self.fleet.physics_io orelse {
                computeActionsOf(self, 0, character_count, acting, 0);
                return;
            };
            if (task_count <= 1) {
                computeActionsOf(self, 0, character_count, acting, 0);
                return;
            }
            var group: Io.Group = .init;
            for (0..task_count) |task| {
                const first: usize = task * character_count / task_count;
                const end: usize = (task + 1) * character_count / task_count;
                group.async(io, computeActionsOf, .{ self, first, end, acting, task });
            }
            group.await(io) catch |err| {
                assertUnreachable(@src(), "the acting tasks were canceled: {s}", .{@errorName(err)});
            };
        }

        /// Characters [`first`, `end`)'s phase 2, in task `task`'s scratch - one of `computeEveryAction`'s tasks.
        fn computeActionsOf(
            self: *Self,
            first: usize,
            end: usize,
            acting: Acting,
            task: usize,
        ) void {
            const scratch: *ActingScratch(M) = &self.acting_scratches[task];
            for (first..end) |env| {
                self.computeAction(env, acting, scratch);
            }
        }

        /// PHASE 3, character `env`, in the characters' order: its features and action back in the host's rows, then
        /// what acting keeps - teacher 3's example its last step completes, its hazard, the planned step's count and
        /// teacher 2's example or teacher 3's pending one, its own goal, and its action into the fleet's.
        fn finishActing(self: *Self, env: usize, acting: Acting) void {
            const feature_count: usize = self.host.z.len;
            const action_count: usize = self.host.raw.len;
            @memcpy(self.host.z, self.acting_z[env * feature_count ..][0..feature_count]);
            @memcpy(self.host.goal, self.acting_goal[env * feature_count ..][0..feature_count]);
            @memcpy(self.host.raw, self.acting_raw[env * action_count ..][0..action_count]);
            self.completeFpoExample(env);
            self.projectHazard(env);
            if (self.acting_planned[env]) |planned_correction| {
                self.planned_steps += 1;
                self.keepDistillationExample(planned_correction);
            } else if (acting.noise_scale != 0.0) {
                self.keepFpoPending(env);
            }
            self.rememberFpoOwnGoal(env);
            self.writeAction(env);
        }

        /// A character's EXPLORING ACTION from its numbers drawn in phase 1 (`prepareActing`), into `host.raw`:
        ///
        ///     the policy's raw action                                   (`policyRow`)
        ///     plus, with a flow, its correction from the character's drifting noise one step further: the fresh noise
        ///         (the first numbers) folded into the character's Ornstein-Uhlenbeck noise (`zrl.ouStep`, at
        ///         `noise_correlation`), times the flow's noise scale and `noise_scale`, as the flow's starting point
        ///                                                               (`correctedRow`)
        ///     plus sigma x `noise_scale` x each of the remaining numbers - SuperTrack's own exploration
        ///
        /// At a noise scale of zero the flow starts from zero - its typical correction - and nothing is added.
        fn exploringActionFrom(
            self: *Self,
            env: usize,
            noise_scale: f32,
            noise_correlation: f32,
            numbers: []const f32,
            scratch: *ActingScratch(M),
        ) void {
            const host: *HostPolicy(M) = &scratch.host;
            const start_noise: []f32 = scratch.flow_start_noise;
            var flow_count: usize = 0;
            if (self.kit.flow_actor != null) {
                flow_count = start_noise.len;
                const character_noise: []f32 = self.flow_noise[env * flow_count ..][0..flow_count];
                if (noise_scale == 0.0) {
                    @memset(start_noise, 0);
                } else {
                    @memcpy(start_noise, numbers[0..flow_count]);
                    zrl.ouStep(f32, character_noise, noise_correlation, start_noise);
                    const flow_noise_scale: f32 = self.kit.flow_actor.?.correction.noise_scale;
                    const start_scale: f32 = noise_scale * flow_noise_scale;
                    for (start_noise, character_noise) |*start_value, noise_value| {
                        start_value.* = start_scale * noise_value;
                    }
                }
                host.correctedRow(start_noise);
            } else {
                host.policyRow();
            }
            const spread: f32 = noise_scale * self.options.sigma;
            if (spread == 0.0) {
                return;
            }
            for (host.raw, numbers[flow_count..][0..host.raw.len]) |*raw, exploration| {
                raw.* += spread * exploration;
            }
        }

        /// Character `env`'s action - whatever `raw` holds - into the fleet's actions, never a non-finite one: NaN
        /// targets make NaN bodies, which are never "terminated" (every comparison with NaN is false) and poison the
        /// world. Such an action is replaced by zero, and counted.
        fn writeAction(self: *Self, env: usize) void {
            const action_width: usize = self.host.raw.len;
            const chosen: []f32 = self.host.raw;
            const given: []f32 = self.actions[env * action_width ..][0..action_width];
            const offset_count: usize = track.actionSize(self.fleet.m);
            const nonfinite_count: usize = giveAction(self.options, offset_count, chosen, given);
            self.nonfinite_actions += nonfinite_count;
        }

        /// GIVES ONE CHARACTER ITS CHOSEN ACTION, as training does (`writeAction`) and as the judge does
        /// (`actOnJudgedFleet`), so a judged policy acts exactly as it trained. Never a non-finite action into the
        /// physics: each such component asks for nothing (`chosen` is its decision's scratch, read by nothing after,
        /// so it is made safe in place). Then the action filter into the character's slot, which holds the action
        /// given at its previous decision: the joints' offsets at `filter`, the limbs' stiffnesses after them at
        /// `stiffness_filter`. Returns how many components were not finite.
        fn giveAction(
            options: Options,
            offset_count: usize,
            chosen: []f32,
            given: []f32,
        ) usize {
            var nonfinite_count: usize = 0;
            for (chosen) |*component| {
                const usable: bool = isFinite(component.*);
                if (!usable) {
                    component.* = 0.0;
                    nonfinite_count += 1;
                }
            }
            filterActionPart(options.filter, chosen[0..offset_count], given[0..offset_count]);
            filterActionPart(options.stiffness_filter, chosen[offset_count..], given[offset_count..]);
            return nonfinite_count;
        }

        /// One part of an action into its slot at `share` (`track.filterAction`). At 1 the chosen numbers are copied
        /// exactly - the blend would turn a negative zero positive.
        fn filterActionPart(share: f32, chosen: []const f32, given: []f32) void {
            if (share == 1.0) {
                @memcpy(given, chosen);
                return;
            }
            track.filterAction(share, chosen, given);
        }

        /// What each character whose episode just ended forgets, after the fleet's step: the action it was given - its
        /// filter starts at rest in the new episode - its hazard history - the new episode's first hazard has no rise -
        /// and teacher 3's pending example and own goal - no next step will complete the example, and the goal it
        /// aimed at is no goal of the episode it starts.
        fn forgetEndedEpisodes(self: *Self) void {
            const action_width: usize = self.host.raw.len;
            for (self.fleet.dones, 0..) |ended, env| {
                if (!ended) {
                    continue;
                }
                // The new episode's filter starts at rest (`Options.filter`).
                @memset(self.actions[env * action_width ..][0..action_width], 0.0);
                if (self.planning_flags != null) {
                    self.previous_hazard_known[env] = false;
                }
                if (self.fpo_pending_valid.len > 0) {
                    self.fpo_pending_valid[env] = false;
                    self.fpo_own_goal_valid[env] = false;
                }
            }
        }

        /// `steps` simulation steps with the policy acting - its raw output plus exploration noise,
        /// which the fleet scales into a pose offset - every one recorded into the ring.
        ///
        /// `noise_scale` of zero is the policy ALONE: no draw is made at all (so judging cannot shift
        /// the random stream and change what training does afterwards), and those steps are counted
        /// into the judged pair rather than the collected one. They are still recorded: noise-free
        /// on-policy steps are perfectly good data, and the ring must stay in step with the replay.
        ///
        /// ONE STEP. Every character in turn - all from the same mirror, then they step together:
        ///
        ///     features            its goal and state                                      `features`
        ///     teacher 3           where its last flow step led, completing its pending     `completeFpoExample`
        ///                         example
        ///     hazard              projected a few steps ahead, for the planning flags      `projectHazard`
        ///     action              its plan's correction on the policy, when it has one     `computeAction`
        ///                         (teacher 2's example) - or the policy with the flow's
        ///                         correction and exploration (teacher 3's, pending)
        ///     own goal            the goal it aims at: the next state's own                 `rememberFpoOwnGoal`
        ///     written             never a non-finite action into the physics               `writeAction`
        ///
        /// then the fleet steps; a character whose episode ended forgets what was its episode's
        /// (`forgetEndedEpisodes`); the flags decide who plans next; and the step is counted and recorded.
        pub fn act(self: *Self, steps: u32, noise_scale: f32) void {
            const random: Random = self.rng.random();
            // How much of itself each character's flow noise keeps from one step to the next - the same for every
            // character and step of the call; a character that plans keeps it longer, so it commits to the way back
            // it began. A judged call (no noise) is the policy alone: no character acts from a plan in it.
            const step_seconds: f32 = self.fleet.m.opt.timestep;
            const correlation_seconds: f32 = self.options.flow.noise_correlation_seconds;
            const flagged_seconds: f32 = self.options.flow.flagged_noise_correlation_seconds;
            const acting: Acting = .{
                .noise_scale = noise_scale,
                .may_act_from_plans = noise_scale != 0.0,
                .noise_correlation = zrl.ouCorrelation(f32, step_seconds, correlation_seconds),
                .flagged_noise_correlation = zrl.ouCorrelation(f32, step_seconds, flagged_seconds),
            };
            // Decisions only at the round's LAST step. A decision's work on the device is submitted with the frame
            // wherever in the round it is called, so its plans arrive with the next frame's readback either way;
            // made at the end it plans from the freshest states, rather than from ones up to a round old by the time
            // its plans are acted on. One falling due earlier waits, pending, its warm start shifted by every step it
            // waited (`PlanningFlags.step`) - and a round decides at most once, so a second decision can never
            // overwrite a first one's inputs before they are read.
            // THE PLANS IN HAND before the round acts. A round's decision is made at its end and its plans cover the
            // round after it; but they reach the host only with a readback, and a readback lands when the device has
            // finished the round's work - training included - which is after the next round has begun. Read without
            // waiting, the plans would arrive a round late, every one of them already past its horizon, and the search
            // would be thrown away: so a learner that plans waits for the newest readback before it explores. The
            // device's round is short beside the round's acting, so the wait is small.
            const acts_from_plans: bool = self.planner != null and noise_scale != 0.0;
            if (acts_from_plans) {
                self.waitForReadback();
            }
            for (0..steps) |step_index| {
                const is_last_step: bool = step_index + 1 == steps;
                // The newest plans the readback has brought, before anyone acts.
                if (self.planner != null) {
                    self.refreshMailbox();
                }
                // Every character chooses its action from the SAME mirror within a step - the weights
                // as of the last readback - and then they all step together, which is what lets the
                // whole step become one upload into the ring.
                //
                // In three phases: every character's plan and random numbers, in the characters' order
                // (`prepareActing`); every character's features and action, each from its own numbers and nothing
                // shared (`computeAction`); then the bookkeeping, in order (`finishActing`). The numbers are those of
                // one character after another, and the middle phase - the policy and the flow, the expensive part -
                // could run on any thread.
                const character_count: usize = self.fleet.options.envs;
                for (0..character_count) |env| {
                    self.prepareActing(env, acting, random);
                }
                self.computeEveryAction(acting);
                for (0..character_count) |env| {
                    self.finishActing(env, acting);
                }
                _ = self.fleet.step(self.actions);
                self.acting_steps += 1;
                self.forgetEndedEpisodes();
                // Who plans next, from the hazards of the step just taken: decisions are made between steps, so a
                // character that starts planning acts from its plan from the next step on. Only while exploring -
                // a judged step is the policy alone.
                if (self.planning_flags) |*flags| {
                    if (noise_scale != 0.0) {
                        const settings: PlanningFlags.Settings = self.options.planning.flags;
                        if (flags.step(self.hazards, settings, is_last_step, self.deciding)) |plan_age| {
                            for (self.deciding) |decides| {
                                self.planning_decisions += @intFromBool(decides);
                            }
                            self.planDecision(plan_age);
                        }
                    }
                }
                // One step watched per character, and a failure for each that just lost its reference.
                // The fleet raises that flag on the step an episode ENDS, and only when it ended badly
                // - a clip running out is a character that survived to the end of the motion.
                //
                // Noise-free steps are counted apart: those are the policy being judged, not explored
                // with, and mixing the two would leave a number that answers neither question.
                //
                // Each step counted on its clip too: the clip it was on - the one its episode ended on, when it just
                // ended (`terminal_clip`, kept before the restart chose the next), and otherwise the one it is still
                // on.
                const fleet: *track.Fleet = self.fleet;
                //
                // A step taken in an aftermath - after its character lost the reference, on its way back or falling
                // - is not time at risk (`track.Fleet.in_aftermath`), so it is not watched: counted, it would lengthen
                // the time to failure of a run with aftermaths and returns against one without.
                for (fleet.failures, fleet.dones, fleet.in_aftermath, 0..) |lost, ended, after_loss, env| {
                    const clip: usize = if (ended) fleet.terminal_clip[env] else fleet.clip_of[env];
                    const at_risk: u64 = if (after_loss) 0 else 1;
                    if (noise_scale == 0.0) {
                        self.judged_exposure += at_risk;
                        if (lost) {
                            self.judged_failures += 1;
                        }
                    } else {
                        self.exposure += at_risk;
                        self.exposure_by_clip[clip] += at_risk;
                        if (lost) {
                            self.failures += 1;
                            self.failures_by_clip[clip] += 1;
                        }
                    }
                }
                self.data.appendLatest(self.fleet);
            }
        }

        /// The critic over the kit's gathered windows (`Options.train_critic`), placed after everything the kit and its
        /// data use - acts after the data's end, parameters after both networks', gradients after the kit's - its
        /// starting weights uploaded and its optimiser's moments zeroed; and its value tail in the kit, when the
        /// policy's loss carries one (`Options.value_tail`). Its descriptors live in `critic_arena`.
        fn buildExtras(self: *Self, options: Options, layout: *kit_mlp.KitLayout) !void {
            const kit: Kit = self.kit;
            // The critic reads the goals the policy reads, so the windows must carry them.
            const windows_have_goals: bool = kit.lead > 0;
            assertf(windows_have_goals, @src(), "the critic needs the policy's goals in its windows", .{});
            const source: kit_mod.LatentCritic(M).Source = .{
                .features = kit.features,
                .rows = kit.rows,
                .steps = kit.steps,
                .states_at = kit.blockT(1),
                .goals_at = kit.blockG(1),
                .norm_at = self.data.norm_at,
                .barrier = kit.barrier,
                .barrier_head_column = kit.barrier_head_column,
                .cost_cap = kit.cost_cap,
                .barrier_up_column = kit.barrier_up_column,
            };
            const networks_params_end: u32 = kit.param_count + kit.policy_count;
            // The layout `init` began - after the kit, its data and the policy's optimiser - continued here.
            const critic_arena: Allocator = self.critic_arena.allocator();
            if (options.train_critic) {
                var critic: kit_mod.LatentCritic(M) = try .init(critic_arena, layout, source, options.critic);
                // The imagined fit reads the policy rollout's states, in the kit's blocks from step 1.
                if (options.critic.imagined_share > 0) {
                    critic.reserveImagined(layout, kit.blockZ(1));
                }
                // The value tail at the policy rollout's end, when the policy's loss carries one.
                if (options.value_tail > 0) {
                    var value_tail: kit_mod.LatentCritic(M).Tail = try critic.initTail(critic_arena, layout, kit.rows);
                    value_tail.pessimism = options.value_tail_pessimism;
                    self.kit.value_tail = value_tail;
                }
                self.critic = critic;
            }
            self.critic_parameter_count = layout.params_floats - networks_params_end;
            const critic_params_end: u32 = layout.params_floats;
            // The flow actor, its parameters straight after the critic's.
            var flow_velocity: ?zn.Mlp(f32) = null;
            if (options.actor == .flow) {
                flow_velocity = try self.buildFlowActor(critic_arena, layout, options);
                // Teacher 3's advantages need the critic: reserved when there is one.
                const learning: *kit_mod.FlowActor(M).Learning = &self.kit.flow_actor.?.learning.?;
                if (learning.fpo) |*fpo| {
                    if (self.critic) |critic| {
                        try fpo.reserveAdvantage(critic_arena, layout, critic);
                    }
                }
            }
            self.flow_parameter_count = layout.params_floats - critic_params_end;
            // The skip model after the flow - inside the saved parameters, the flow's count taken before it.
            if (options.skip_span > 0) {
                const skip_shape: kit_mod.SkipModel(M).Shape = .{
                    .features = self.kit.features,
                    .step_columns = self.kit.inputs - self.kit.features,
                    .hidden = self.kit.hidden,
                    .rows = self.kit.rows,
                    .window_steps = self.kit.world_steps,
                };
                const span: u32 = options.skip_span;
                const clip: f32 = options.world_gradient_clip;
                const skip_params_start: u32 = layout.params_floats;
                const skip_model: kit_mod.SkipModel(M) = try .init(critic_arena, layout, skip_shape, span, clip);
                self.kit.skip_model = skip_model;
                self.skip_parameter_count = layout.params_floats - skip_params_start;
            }
            // The parameters end here: what follows - the planner's mailbox - is read back, never saved.
            self.params_end = layout.params_floats;
            if (options.planning.enabled) {
                try self.buildPlanner(critic_arena, layout, options);
            }
            self.readback_end = layout.params_floats;
            try layout.checkFitsKit(M);
            // Its starting weights into its own range of the parameters, and its moments zeroed.
            const params: []f32 = try critic_arena.alloc(f32, layout.params_floats);
            @memset(params, 0);
            if (self.critic) |critic| {
                critic.writeParams(params);
            }
            // The skip head's starting weights from a stream of their own (`SkipModel.writeStartingParams`): drawn from
            // the learner's, they would move every draw after them, and a learner with a head would act and learn
            // otherwise than one without - not only by what the head adds.
            if (self.kit.skip_model) |skip_model| {
                const skip_stream_seed: u64 = options.seed ^ 0x5C1B_4EAD_0000_0001;
                var skip_stream: Random.DefaultPrng = .init(skip_stream_seed);
                skip_model.writeStartingParams(skip_stream.random(), params);
            }
            if (self.kit.flow_actor) |flow_actor| {
                flow_actor.flow.network.writeParams(flow_velocity.?, params);
                // The synergies: the identity, the full width (`buildFlowActor`).
                const correction: kit_mod.FlowActor(M).Correction = flow_actor.correction;
                const synergy_floats: u32 = correction.synergy_count * correction.action_width;
                const synergies: []f32 = params[correction.synergies_at..][0..synergy_floats];
                @memset(synergies, 0);
                for (0..correction.synergy_count) |synergy| {
                    synergies[synergy * correction.action_width + synergy] = 1;
                }
                @memcpy(self.host.synergies, synergies);
                // The mirror starts as the starting weights, so the fleet can act before the first readback.
                @memcpy(self.host.flow_mirror, params[0..self.host.flow_mirror.len]);
            }
            // A planner without a flow decodes its corrections through a basis of its own, the identity.
            if (self.planner) |planner| {
                planner.writeOwnSynergies(params);
            }
            const extra_params: []const f32 = params[networks_params_end..];
            kit.pipe.uploadAt(.params, networks_params_end, extra_params);
            const zero_moments: []f32 = try critic_arena.alloc(f32, extra_params.len);
            @memset(zero_moments, 0);
            kit.pipe.uploadAt(.adam_m, networks_params_end, zero_moments);
            kit.pipe.uploadAt(.adam_v, networks_params_end, zero_moments);
            // No policy update yet: everything that leans on the critic starts at no trust.
            self.applyCriticTrust();
        }

        /// The tracking planner (`Options.planning`): sized by the planning settings - a slot for each character the
        /// flags may let plan - over the learner's own world model, with the critic's pessimistic tail when there is a
        /// critic and the flow's plans among its candidates when the flow acts; its elites weighed relative to their
        /// spread (SuperTrack's costs are hundredths). Its mailbox goes into the parameter buffer after the
        /// parameters; its regions into `layout`; the decisions' scratch is allocated with the learner's allocator.
        fn buildPlanner(
            self: *Self,
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            options: Options,
        ) !void {
            const gpa: Allocator = self.gpa;
            const planning: PlanningSettings = options.planning;
            const flow_actor: ?kit_mod.FlowActor(M) = self.kit.flow_actor;
            const flow_plans: u32 = if (flow_actor != null) planning.flow_plans else 0;
            const slot_count: u32 = planning.flags.budget;
            const scorer_options: kit_mod.TrackingScorer(M).Options = .{
                .states = slot_count,
                .candidates = planning.candidates,
                .horizon = planning.horizon,
                .tail_weight = 1.0,
                .pessimism = options.value_tail_pessimism,
                .objective = planning.objective,
                // The critic's discount, so a plan's future is costed as the critic costs one; a plain sum without it.
                .discount = if (self.critic) |critic| critic.options.discount else 1.0,
            };
            const search_options: bmpc_kit.KitMppi(M).Options = .{
                .policy_candidates = flow_plans,
                .fine_steps = planning.fine_steps,
                .knot_span = planning.knot_span,
                .elites = planning.elites,
                .temperature = planning.temperature,
                .temperature_mode = .relative_to_elites,
                .rounds = planning.rounds,
            };
            const planner: kit_mod.TrackingPlanner(M) =
                try .init(arena, layout, self.kit, self.critic, flow_actor, scorer_options, search_options);
            self.planner = planner;
            self.mailbox_at = layout.reserveParams(planner.mailboxFloats());
            self.slot_owners = try gpa.alloc(?usize, slot_count);
            @memset(self.slot_owners, null);
            self.slot_inputs = try gpa.alloc(f32, self.kit.features + 2);
            self.slot_warm_flags = try gpa.alloc(f32, slot_count);
            self.slot_owner_since = try gpa.alloc(u32, slot_count);
            @memset(self.slot_owner_since, 0);
            self.mailbox_copy = try gpa.alloc(f32, planner.mailboxFloats());
            @memset(self.mailbox_copy, 0);
            // Teacher 2's examples, when the flow acts and so can learn them.
            if (self.kit.flow_actor != null) {
                const example_width: usize = 2 * self.kit.features + self.kit.actions;
                self.distillation_examples = try gpa.alloc(f32, planning.distill_examples * example_width);
                self.distillation_batch_conditions = try gpa.alloc(f32, planning.distill_rows * 2 * self.kit.features);
                self.distillation_batch_corrections = try gpa.alloc(f32, planning.distill_rows * self.kit.actions);
            }
        }

        /// Keeps the step character `env` is about to take from its plan as one of teacher 2's examples: the condition
        /// it acts in - whatever `goal` and `z` hold (`features`) - and the plan's correction. The ring overwrites its
        /// oldest example once full.
        fn keepDistillationExample(self: *Self, planned_correction: []const f32) void {
            if (self.distillation_examples.len == 0) {
                return;
            }
            const feature_count: usize = self.kit.features;
            const action_width: usize = self.kit.actions;
            const example_width: usize = 2 * feature_count + action_width;
            const capacity: usize = self.distillation_examples.len / example_width;
            const example_start: usize = self.distillation_next * example_width;
            const example: []f32 = self.distillation_examples[example_start..][0..example_width];
            @memcpy(example[0..feature_count], self.host.goal);
            @memcpy(example[feature_count..][0..feature_count], self.host.z);
            @memcpy(example[2 * feature_count ..][0..action_width], planned_correction);
            self.distillation_next = (self.distillation_next + 1) % capacity;
            self.distillation_example_count = @min(self.distillation_example_count + 1, capacity);
        }

        /// Whether character `env` is in recovery, for teacher 3: planning, or with a hazard - of whatever `z` and
        /// `goal` hold (`features`) - of at least the flow's `fpo_start_hazard`. Danger, however it came: a push, a
        /// stumble, a drift from the reference.
        fn isRecovering(self: *const Self, env: usize) bool {
            const is_planning: bool = if (self.planning_flags) |flags| flags.slots[env] != null else false;
            if (is_planning) {
                return true;
            }
            return self.characterHazard() >= self.options.flow.fpo_start_hazard;
        }

        /// Keeps the step character `env` is about to take, the flow having chosen its correction, as its PENDING
        /// example for teacher 3 - when the learner keeps teacher 3's examples and the character is in recovery
        /// (`isRecovering`): the condition it acts in - whatever `goal` and `z` hold - and the flow's coefficients
        /// (`flow_coefficients`, as `correctedRow` left them: the flow's own sample, before SuperTrack's exploration is
        /// added, which from the flow's side is part of the world). The next step completes it.
        fn keepFpoPending(self: *Self, env: usize) void {
            // The character's own goal - the goal it aimed at the step before, in this episode - or no example.
            if (self.fpo_examples.len == 0 or !self.fpo_own_goal_valid[env] or !self.isRecovering(env)) {
                return;
            }
            const feature_count: usize = self.host.goal.len;
            const synergy_count: usize = self.host.flow_coefficients.len;
            const columns: kit_mod.FlowActor(M).Fpo.Columns = .of(@intCast(feature_count), @intCast(synergy_count));
            const pending: []f32 = self.fpo_pending[env * columns.next_state ..][0..columns.next_state];
            const own_goal: []const f32 = self.fpo_own_goals[env * feature_count ..][0..feature_count];
            @memcpy(pending[columns.own_goal..][0..feature_count], own_goal);
            @memcpy(pending[columns.goal..][0..feature_count], self.host.goal);
            @memcpy(pending[columns.state..][0..feature_count], self.host.z);
            @memcpy(pending[columns.coefficients..][0..synergy_count], self.host.flow_coefficients);
            self.fpo_pending_valid[env] = true;
        }

        /// Remembers the goal character `env` aims at this step - whatever `goal` holds - as the own goal of the state
        /// it will be in at the next (`FlowActor.Fpo`).
        fn rememberFpoOwnGoal(self: *Self, env: usize) void {
            if (self.fpo_examples.len == 0) {
                return;
            }
            const feature_count: usize = self.host.goal.len;
            @memcpy(self.fpo_own_goals[env * feature_count ..][0..feature_count], self.host.goal);
            self.fpo_own_goal_valid[env] = true;
        }

        /// Completes character `env`'s pending example, if it has one, with the state it is in now - whatever `z`
        /// holds, the step after - into teacher 3's ring, which overwrites its oldest once full.
        fn completeFpoExample(self: *Self, env: usize) void {
            if (self.fpo_examples.len == 0 or !self.fpo_pending_valid[env]) {
                return;
            }
            const feature_count: usize = self.host.goal.len;
            const synergy_count: usize = self.host.flow_coefficients.len;
            const columns: kit_mod.FlowActor(M).Fpo.Columns = .of(@intCast(feature_count), @intCast(synergy_count));
            const capacity: usize = self.fpo_examples.len / columns.width;
            const example: []f32 = self.fpo_examples[self.fpo_next * columns.width ..][0..columns.width];
            const pending: []const f32 = self.fpo_pending[env * columns.next_state ..][0..columns.next_state];
            @memcpy(example[0..columns.next_state], pending);
            @memcpy(example[columns.next_state..][0..feature_count], self.host.z);
            self.fpo_pending_valid[env] = false;
            self.fpo_next = (self.fpo_next + 1) % capacity;
            self.fpo_example_count = @min(self.fpo_example_count + 1, capacity);
        }

        /// The round's batch for teacher 3: its rows drawn from the ring, with replacement, uploaded once - before the
        /// round's recording opens - and FPO told whether there is a batch at all.
        fn uploadFpoBatch(self: *Self) void {
            const flow_actor: *kit_mod.FlowActor(M) = if (self.kit.flow_actor) |*actor| actor else return;
            const learning: *kit_mod.FlowActor(M).Learning = if (flow_actor.learning) |*part| part else return;
            const fpo: *kit_mod.FlowActor(M).Fpo = if (learning.fpo) |*part| part else return;
            // Teacher 3 needs the critic for its advantages: without it, no batch.
            fpo.has_batch = self.fpo_example_count > 0 and fpo.advantage != null;
            if (!fpo.has_batch) {
                return;
            }
            const random: Random = self.rng.random();
            const example_width: usize = self.fpo_batch.len / fpo.rows;
            for (0..fpo.rows) |row| {
                const example_index: usize = random.uintLessThan(usize, self.fpo_example_count);
                const example: []const f32 = self.fpo_examples[example_index * example_width ..][0..example_width];
                @memcpy(self.fpo_batch[row * example_width ..][0..example_width], example);
            }
            self.kit.pipe.uploadAt(.acts, fpo.examples_at, self.fpo_batch);
        }

        /// The stream teacher 3's draws are hashed from, apart from every other hashed noise of the learner's.
        const fpo_draw_stream: u32 = 0xF9_0D;

        /// Teacher 3's round start (`LatentKit.fpoRoundStart`) when its batch holds examples - first in the round's
        /// recording, so its advantages and old losses are those of the weights and the critic the round starts from.
        /// The round's draws are seeded by the acting steps, which move every round and are saved with the run.
        fn startFpoRound(self: *Self) void {
            const flow_actor: *kit_mod.FlowActor(M) = if (self.kit.flow_actor) |*actor| actor else return;
            const learning: *kit_mod.FlowActor(M).Learning = if (flow_actor.learning) |*part| part else return;
            const fpo: *kit_mod.FlowActor(M).Fpo = if (learning.fpo) |*part| part else return;
            if (!fpo.has_batch) {
                return;
            }
            const steps_seed: u32 = @truncate(self.acting_steps);
            fpo.draw_seed = M.latStepSeed(steps_seed, fpo_draw_stream);
            self.kit.fpoRoundStart(flow_actor.*, fpo.*);
        }

        /// The round's batch for teacher 2: `distill_rows` examples drawn from the ring, with replacement, uploaded
        /// once - before the round's recording opens, so every update in it reads them - and the distillation told
        /// whether there is a batch at all.
        fn uploadDistillationBatch(self: *Self) void {
            const flow_actor: *kit_mod.FlowActor(M) = if (self.kit.flow_actor) |*actor| actor else return;
            const learning: *kit_mod.FlowActor(M).Learning = if (flow_actor.learning) |*part| part else return;
            const Distillation = kit_mod.FlowActor(M).Distillation;
            const distillation: *Distillation = if (learning.distillation) |*part| part else return;
            distillation.has_batch = self.distillation_example_count > 0;
            if (!distillation.has_batch) {
                return;
            }
            const random: Random = self.rng.random();
            const feature_count: usize = self.kit.features;
            const action_width: usize = self.kit.actions;
            const condition_width: usize = 2 * feature_count;
            const example_width: usize = condition_width + action_width;
            const batch_rows: usize = distillation.trainer.rows;
            for (0..batch_rows) |row| {
                const example_index: usize = random.uintLessThan(usize, self.distillation_example_count);
                const example_start: usize = example_index * example_width;
                const example: []const f32 = self.distillation_examples[example_start..][0..example_width];
                const conditions: []f32 = self.distillation_batch_conditions;
                const actions_staged: []f32 = self.distillation_batch_corrections;
                @memcpy(conditions[row * condition_width ..][0..condition_width], example[0..condition_width]);
                @memcpy(actions_staged[row * action_width ..][0..action_width], example[condition_width..]);
            }
            self.kit.pipe.uploadAt(.acts, distillation.conditions_at, self.distillation_batch_conditions);
            self.kit.pipe.uploadAt(.acts, distillation.trainer.actions_at, self.distillation_batch_corrections);
        }

        /// ONE DECISION for every planning character, after the step that called for it (`PlanningFlags.step`
        /// returned `plan_age`): each one's current state and its rows in the reference table into its slot, its
        /// slot's warm flag - 1 when the same character held the slot at the last decision, so its search starts from
        /// its last plan moved forward `plan_age` steps - the rows gathered on the device, the search, and the chosen
        /// plans into the mailbox, stamped with this step (plus one).
        fn planDecision(self: *Self, plan_age: u32) void {
            const planner: kit_mod.TrackingPlanner(M) = self.planner.?;
            const flags: PlanningFlags = self.planning_flags.?;
            const pipe: *compute_host.Compute(M) = self.kit.pipe;
            const feature_count: usize = self.kit.features;
            @memset(self.slot_warm_flags, 0);
            for (flags.slots, 0..) |slot_or_none, character| {
                const slot: u32 = slot_or_none orelse continue;
                const is_same_character: bool = self.slot_owners[slot] == character;
                self.slot_warm_flags[slot] = if (is_same_character) 1 else 0;
                self.slot_owners[slot] = character;
                if (!is_same_character) {
                    self.slot_owner_since[slot] = @truncate(self.acting_steps);
                }
                // The state it is in now, and where its reference runs from in the table: its clip's row of the frame
                // it tracks next, held at the clip's last row.
                self.features(character);
                @memcpy(self.slot_inputs[0..feature_count], self.host.z);
                const clip_index: usize = self.fleet.clip_of[character];
                const last_frame: u32 = @intCast(self.fleet.clips[clip_index].frame_count - 1);
                const frame: u32 = @min(self.fleet.frame[character], last_frame);
                const clip_first_row: u32 = self.data.clip_rows[clip_index];
                self.slot_inputs[feature_count] = float(clip_first_row + frame);
                self.slot_inputs[feature_count + 1] = float(clip_first_row + last_frame);
                pipe.uploadAt(.acts, planner.stateInputsAt(slot), self.slot_inputs);
            }
            // A slot no one holds any more has no owner: its next character starts cold.
            for (self.slot_owners, flags.slot_taken) |*owner, taken| {
                if (!taken) {
                    owner.* = null;
                }
            }
            pipe.uploadAt(.acts, planner.mppi.warm_flags_offset, self.slot_warm_flags);
            planner.gather(pipe, self.data.table_at, self.data.norm_at);
            const decision_step: u32 = @truncate(self.acting_steps);
            // The decision's random numbers: the run's seed, folded to the hash's width, and this step.
            const run_seed: u32 = @truncate(self.options.seed ^ (self.options.seed >> 32));
            const decision_seed: u32 = M.latStepSeed(run_seed, decision_step);
            planner.decide(pipe, decision_seed, plan_age);
            planner.writeMailbox(pipe, self.mailbox_at, decision_step + 1);
            self.decisions_made += 1;
        }

        /// The flow actor (`Options.actor` `.flow`): its velocity network drawn as zimrrl's `FlowPolicy` draws it
        /// (its last layer at zero, so it starts exactly as a zero Gaussian policy exploring at sigma), placed in
        /// `layout`, set on the kit; its mirror, each character's noise (started at standard normals) and the host
        /// sampler's scratch allocated with the learner's allocator. Returns the velocity network, whose numbers the
        /// caller writes and uploads.
        fn buildFlowActor(
            self: *Self,
            arena: Allocator,
            layout: *kit_mlp.KitLayout,
            options: Options,
        ) !zn.Mlp(f32) {
            const gpa: Allocator = self.gpa;
            const settings: kit_mod.FlowSettings = options.flow;
            // Settings a flow cannot be built from, refused by name: no Euler step leaves the action unwritten; a
            // hidden layer of no width is a network that cannot learn; a negative correlation time makes the noise's
            // correlation above 1 and its fresh share the root of a negative number.
            assertf(settings.euler_steps >= 1, @src(), "flow.euler_steps must be at least 1", .{});
            const has_hidden_width: bool = settings.hidden_layers == 0 or settings.hidden_width > 0;
            assertf(has_hidden_width, @src(), "flow.hidden_width must be above 0 with hidden layers", .{});
            const correlation_time_valid: bool = settings.noise_correlation_seconds >= 0;
            assertf(correlation_time_valid, @src(), "flow.noise_correlation_seconds must not be negative", .{});
            const condition_width: u32 = self.kit.lead + self.kit.features;
            const action_width: u32 = self.kit.actions;
            const hidden: []usize = try arena.alloc(usize, settings.hidden_layers);
            @memset(hidden, settings.hidden_width);
            const flow_rng: zn.Rng = .init(settings.seed);
            // The flow's own noise: a share of sigma (`FlowSettings.noise_share`).
            const flow_noise_scale: f32 = self.options.sigma * settings.noise_share;
            const flow_options: zrl.FlowPolicy(f32).Options = .{
                .euler_steps = settings.euler_steps,
                .time_frequencies = settings.time_frequencies,
                .noise_scale = flow_noise_scale,
                .starts_at_zero_velocity = true,
            };
            // The flow's coefficients: the full width for now - its synergies the actions themselves, the identity.
            const full_width: bool = settings.synergies == 0 or settings.synergies == action_width;
            assertf(full_width, @src(), "flow.synergies: only the full width (0) - no basis is fitted for fewer", .{});
            const synergy_count: u32 = action_width;
            const flow_policy: zrl.FlowPolicy(f32) =
                try .init(arena, flow_rng, condition_width, synergy_count, hidden, flow_options);
            const flow_actor: kit_mod.FlowActor(M) = try .init(
                arena,
                layout,
                flow_policy.velocity,
                condition_width,
                action_width,
                synergy_count,
                flow_noise_scale,
                self.kit.rows,
                self.kit.steps,
                .{ .euler_steps = settings.euler_steps, .time_frequencies = settings.time_frequencies },
                .{
                    .share_teachers = settings.share_teachers,
                    .dpg_share = settings.dpg_share,
                    .step_share = settings.step_share,
                    .anchor = settings.anchor,
                    .learning_rate = settings.learning_rate,
                    .gradient_clip = settings.gradient_clip,
                },
                // Teacher 2's batch: the planner's answers, when the learner plans.
                if (options.planning.enabled) options.planning.distill_rows else 0,
                options.planning.distill_weight,
                // Teacher 3: the flow's own steps in recovery, their draws, its weight and clip.
                .{
                    .rows = settings.fpo_rows,
                    .draws = settings.fpo_draws,
                    .weight = settings.fpo_weight,
                    .clip = settings.fpo_clip,
                },
            );
            self.kit.flow_actor = flow_actor;
            // The host's inference samples through the same flow's shapes.
            self.host.flow = flow_actor;
            const flow_end: u32 = flow_actor.flow.network.paramsEnd();
            const character_count: usize = self.fleet.options.envs;
            self.host.flow_mirror = try gpa.alloc(f32, flow_end);
            @memset(self.host.flow_mirror, 0);
            // Each character's drifting noise, in the flow's coefficients; the sampler's scratch, likewise.
            self.flow_noise = try gpa.alloc(f32, character_count * synergy_count);
            const random: Random = self.rng.random();
            for (self.flow_noise) |*noise_value| {
                noise_value.* = random.floatNorm(f32);
            }
            self.host.flow_condition = try gpa.alloc(f32, condition_width);
            self.host.flow_input_scratch = try gpa.alloc(f32, flow_actor.flow.wideRowWidth());
            self.host.flow_layer_scratch = try gpa.alloc(f32, 2 * flow_actor.flow.network.widestOutput());
            self.host.flow_velocity_scratch = try gpa.alloc(f32, synergy_count);
            self.flow_start_noise = try gpa.alloc(f32, synergy_count);
            self.host.flow_coefficients = try gpa.alloc(f32, synergy_count);
            self.host.synergies = try gpa.alloc(f32, synergy_count * action_width);
            // Teacher 3's ring, each character's pending example, and the round's batch.
            if (settings.fpo_rows > 0) {
                const feature_count: u32 = condition_width / 2;
                const columns: kit_mod.FlowActor(M).Fpo.Columns = .of(feature_count, synergy_count);
                self.fpo_examples = try gpa.alloc(f32, settings.fpo_examples * columns.width);
                self.fpo_pending = try gpa.alloc(f32, character_count * columns.next_state);
                self.fpo_pending_valid = try gpa.alloc(bool, character_count);
                @memset(self.fpo_pending_valid, false);
                self.fpo_batch = try gpa.alloc(f32, settings.fpo_rows * columns.width);
                self.fpo_own_goals = try gpa.alloc(f32, character_count * feature_count);
                self.fpo_own_goal_valid = try gpa.alloc(bool, character_count);
                @memset(self.fpo_own_goal_valid, false);
            }
            return flow_policy.velocity;
        }

        /// The share of a network's base learning rate at its `updates`-th update, by the rates' schedule: the cosine
        /// schedule's rate for a base of 1 (`zn.cosineLearningRate`), over the training hours when the schedule is in
        /// hours (`Options.rate_decay_hours`, counted in tenths of a minute), else over the network's updates
        /// (`Options.rate_decay_updates`); 1 with no schedule.
        fn rateShare(self: *const Self, updates: u32) f32 {
            const options: Options = self.options;
            if (options.rate_decay_hours > 0) {
                const tenths_of_a_minute_per_hour: f32 = 600;
                const elapsed: usize = @floor(self.training_hours * tenths_of_a_minute_per_hour);
                const total: usize = @floor(options.rate_decay_hours * tenths_of_a_minute_per_hour);
                return zn.cosineLearningRate(f32, elapsed, total, 1, options.rate_floor_share);
            }
            if (options.rate_decay_updates == 0) {
                return 1;
            }
            return zn.cosineLearningRate(f32, updates, options.rate_decay_updates, 1, options.rate_floor_share);
        }

        /// One world-model update on freshly drawn windows, in its own start slot - windows from anywhere in a
        /// segment, a fall's aftermath included: how a body falls is what the model must know to be trusted there.
        pub fn trainWorld(self: *Self, slot: u32) void {
            if (!self.drawWindows(slot, .anywhere)) {
                self.windows_refused += 1;
                return;
            }
            self.data.gather(&self.kit, slot);
            self.world_updates += 1;
            const world_rate: f32 = self.options.world_rate * self.rateShare(self.world_updates);
            self.kit.trainStep(world_rate, self.world_updates);
            // The critic, on the same gathered windows: their real states and goals are still where the gather left
            // them, since the world model's step writes only its own rollout.
            if (self.critic) |*critic| {
                self.critic_updates += 1;
                const critic_share: f32 = self.rateShare(self.critic_updates);
                critic.options.learning_rate = self.options.critic.learning_rate * critic_share;
                critic.update(self.kit.pipe, self.critic_updates);
            }
        }

        /// TRUST IN THE CRITIC: a share from 0 to 1 that grows linearly with the policy's updates and is whole after
        /// `value_tail_ramp_updates` - with a ramp of 1000, the 250th update trusts it at 0.25, the 1000th and every
        /// one after at 1. An untrained critic's numbers are noise - its slope, its heads' disagreement, the
        /// advantages it gives - so everything that leans on it is weighed by this share (`applyCriticTrust`).
        pub fn criticTrust(self: *const Self) f32 {
            const ramp_updates: f32 = float(@max(self.options.value_tail_ramp_updates, 1));
            return @min(1.0, float(self.policy_updates) / ramp_updates);
        }

        /// Everything that leans on the critic, weighed by the trust in it (`criticTrust`) - set before each policy
        /// update from the full settings:
        ///
        ///     the policy's value tail     its weight, and its pessimism: an untrained critic's disagreement is no
        ///                                 warning yet
        ///     the planner's tail          likewise, for the plans it scores next
        ///     teacher 2                   the planner's corrections, scored by the critic's tail
        ///     teacher 3                   its advantages are the critic's
        ///
        /// Teacher 1, FlowDPG, leans on the world model's gradient, which trains from the first round as SuperTrack's
        /// policy assumes: it is not ramped.
        fn applyCriticTrust(self: *Self) void {
            const trust: f32 = self.criticTrust();
            const pessimism: f32 = self.options.value_tail_pessimism * trust;
            if (self.kit.value_tail) |*value_tail| {
                value_tail.weight = self.options.value_tail * trust;
                value_tail.pessimism = pessimism;
            }
            if (self.planner) |*planner| {
                planner.scorer.options.tail_weight = trust;
                planner.scorer.options.pessimism = pessimism;
            }
            const flow_actor: *kit_mod.FlowActor(M) = if (self.kit.flow_actor) |*actor| actor else return;
            const learning: *kit_mod.FlowActor(M).Learning = if (flow_actor.learning) |*part| part else return;
            if (learning.distillation) |*distillation| {
                distillation.weight = self.options.planning.distill_weight * trust;
            }
            if (learning.fpo) |*fpo| {
                fpo.weight = self.options.flow.fpo_weight * trust;
            }
        }

        /// One policy update, likewise - through the world model, which this leaves untouched - on windows that start
        /// before a loss, and, when the fleet has returns, a share of them inside returns (`returnWindowShare`). The
        /// tracking loss is a squared distance from the goal: in a fall it is large and its gradient large with it.
        /// Without returns such a window points at a reference the fallen body is never asked to reach again, and
        /// would only swamp the update; with them, it is exactly what the policy must learn - the way back - and the
        /// share keeps those large gradients from drowning the tracking near the reference.
        pub fn trainPolicy(self: *Self, slot: u32) void {
            if (!self.drawPolicyWindows(slot)) {
                self.windows_refused += 1;
                return;
            }
            self.data.gather(&self.kit, slot);
            // The rollout's noise comes from this update's seed, hashed per step, row and action.
            self.kit.seed = self.policy_updates;
            self.policy_updates += 1;
            // Everything that leans on the critic, weighed by the trust in it so far.
            self.applyCriticTrust();
            // The policy's rate on its schedule, and the flow's beside it: the two learn in the same update.
            const policy_share: f32 = self.rateShare(self.policy_updates);
            if (self.kit.flow_actor) |*flow_actor| {
                if (flow_actor.learning) |*learning| {
                    learning.teacher.learning_rate = self.options.flow.learning_rate * policy_share;
                }
            }
            self.kit.policyTrainStep(self.options.policy_rate * policy_share, self.policy_updates);
            // The critic fitted to this update's imagined rollout, still in the kit's blocks (`imagined_share`): where
            // the policy reads it, under the policy it judges. Its steps count with the real ones' - one optimiser.
            if (self.critic) |*critic| {
                if (critic.options.imagined_share > 0) {
                    self.critic_updates += 1;
                    const critic_share: f32 = self.rateShare(self.critic_updates);
                    critic.options.learning_rate = self.options.critic.learning_rate * critic_share;
                    critic.updateImagined(self.kit.pipe, self.critic_updates);
                }
            }
        }

        /// One round of the loop: simulate, then train each network, each update in its own slot.
        ///
        /// ONE RECORDING PER ROUND, and not one for several. Every `run` inside a recording carries
        /// its own parameters - without it each dispatch would read whichever parameters were written
        /// last, which on a device means every kernel in the frame running with the final one's. But a
        /// recording may not span rounds either: an upload made while one is open lands before the
        /// WHOLE recording executes, so a later round's appends would overwrite ring slots this
        /// round's gathers are still about to read. Simulate, record this round's dispatches, submit.
        pub fn simulateAndTrain(self: *Self) void {
            self.act(self.options.collect, 1.0);
            self.train();
        }

        /// The round's training, after its acting (`simulateAndTrain`, which a caller timing the two halves apart
        /// may replace by `act` and this): the teachers' batches uploaded, the round's updates recorded and
        /// submitted, the mirror and the device's numbers taken from the readback.
        pub fn train(self: *Self) void {
            // Teacher 2's batch, uploaded before the recording opens: an upload made while one is open lands before
            // the whole recording, and this one is meant for all of it.
            self.uploadDistillationBatch();
            self.uploadFpoBatch();
            self.kit.pipe.beginRecording();
            self.startFpoRound();
            var slot: u32 = 0;
            for (0..self.options.world_updates) |_| {
                self.trainWorld(slot);
                slot += 1;
            }
            for (0..self.options.policy_updates) |_| {
                self.trainPolicy(slot);
                slot += 1;
            }
            self.kit.pipe.submitRecording();
            // The weights the simulation acts from, as of this round.
            self.syncMirror();
            // The device's numbers from the same readback, whether or not the mirror took its weights: a non-finite
            // number in them is what the log most needs to show.
            self.refreshDeviceStats();
        }

        /// Windows the CPU replay draws - it knows where episodes begin and end - staged into `slot`, each
        /// starting where `window_start` allows (`track.WindowStart`). False when the replay cannot supply them yet.
        /// Public because a caller may want a batch of windows staged without an update following it, and
        /// because the tests compare both learners on the SAME windows.
        pub fn drawWindows(self: *Self, slot: u32, window_start: track.WindowStart) bool {
            return self.drawWindowsMixed(slot, window_start, 0);
        }

        /// The policy's windows (`trainPolicy`): before a loss, a share inside returns.
        pub fn drawPolicyWindows(self: *Self, slot: u32) bool {
            return self.drawWindowsMixed(slot, .before_loss, self.returnWindowShare());
        }

        /// The share of the policy's windows drawn inside returns: `Options.return_window_share` when the fleet has
        /// returns (`track.Fleet.Options.return_steps`), none otherwise - after a loss there is then nothing to return
        /// to.
        pub fn returnWindowShare(self: *const Self) f32 {
            const fleet_has_returns: bool = self.fleet.options.return_steps > 0;
            return if (fleet_has_returns) self.options.return_window_share else 0;
        }

        /// `drawWindows`, each window drawn inside a return (`track.WindowStart.after_loss`) with probability
        /// `return_share` - falling back to `window_start` while the replay holds none - and otherwise where
        /// `window_start` allows. A share of 0 draws nothing more from the random stream: the windows of a learner
        /// without returns are the ones it always drew.
        fn drawWindowsMixed(
            self: *Self,
            slot: u32,
            window_start: track.WindowStart,
            return_share: f32,
        ) bool {
            const random: Random = self.rng.random();
            // Only what the RING holds. The replay knows where episodes begin and end, so it draws the
            // windows - but it may also hold steps from before the learner existed, or more of them
            // than the ring has room for, and a window the ring never received would be assembled out
            // of whatever those slots happen to contain. So: draw, and keep only what the ring carries.
            const range: kit_mod.Resident(M).HeldSteps = self.data.held() orelse return false;
            // As long as the policy's horizon: the world model learns from their first `window` steps.
            const window_length: u32 = self.kit.steps;
            for (self.starts) |*start| {
                const tries_inside_return: bool = return_share > 0 and random.float(f32) < return_share;
                // The window inside a return, offered once: if the ring does not hold it, ordinary draws follow.
                var inside_return: ?track.Replay.Window = if (tries_inside_return)
                    self.fleet.replay.sampleWindowStarting(random, window_length, .after_loss)
                else
                    null;
                var tries: u32 = 0;
                const window: track.Replay.Window = while (tries < 64) : (tries += 1) {
                    const offered: ?track.Replay.Window = inside_return;
                    inside_return = null;
                    const drawn: track.Replay.Window = offered orelse
                        self.fleet.replay.sampleWindowStarting(random, window_length, window_start) orelse
                        return false;
                    const inside: bool =
                        drawn.first >= range.first and drawn.first + window_length <= range.last;
                    if (inside) {
                        break drawn;
                    }
                } else {
                    // The ring is still far behind the replay - the first rounds, or just after a
                    // warm-up. Train nothing this round rather than train on slots we cannot vouch for.
                    return false;
                };
                // Whether the window continues its episode: the record before it is the same segment's, so the
                // window's first decision blends into, and reads, the action given just before it.
                const has_previous: bool = window.first > 0;
                const replay: track.Replay = self.fleet.replay;
                const first_segment: u32 = replay.segmentAt(window.env, window.first);
                const continues_segment: bool = has_previous and
                    replay.segmentAt(window.env, window.first - 1) == first_segment;
                start.* = .{
                    .env = @intCast(window.env),
                    .index = window.first,
                    .continues_segment = continues_segment,
                };
            }
            self.data.stageStarts(self.starts, slot, window_length);
            return true;
        }

        /// A character's features and its goal - where the reference is going, the frame the servo aims
        /// at - both normalised, as the policy reads them. Left in `z` and `goal`.
        pub fn features(self: *Self, env: usize) void {
            self.featuresOf(self.fleet, env);
        }

        /// The same for a character of ANY fleet on this model - the judge's (`judgeActor`), not only the
        /// learner's own. Everything read comes from `fleet`; only the scratch is the learner's.
        pub fn featuresOf(self: *Self, fleet: *track.Fleet, env: usize) void {
            const scratch: FeatureScratch = .{
                .simulated = &self.sim,
                .reference = &self.reference,
                .probe = &self.probe,
                .raw_features = self.raw_features,
            };
            supertrackFeaturesInto(fleet, env, self.norm, scratch, self.host.goal, self.host.z);
        }

        /// What this learner's policy file is made of (`PolicyParts`, `robot_lab.policyOfSuperTrack`): the mirror -
        /// the weights acting uses - and the normaliser, borrowed. Call `waitForReadback` and `syncMirror` first, in a
        /// program without frames, for the newest policy.
        pub fn policyParts(self: *const Self) PolicyParts {
            return .{
                .packed_weights = self.host.mirror,
                .feature_count = self.host.z.len,
                .hidden_width = self.host.hidden1.len,
                .action_count = self.host.raw.len,
                .normalizer = self.norm,
                .filter = self.options.filter,
            };
        }

        /// The JUDGE's actor (plan F1): the policy's MEAN action - no exploration - for every character of the
        /// judge's fleet, from the mirror (the weights as of the last readback). Call `syncMirror` first to judge the
        /// latest policy. The learner is only borrowed for its scratch: judging does not touch its fleet, its ring or
        /// its random stream, so a judged run trains exactly as an unjudged one would.
        pub fn judgeActor(self: *Self) track.Actor {
            return .{ .context = self, .act = actOnJudgedFleet };
        }

        fn actOnJudgedFleet(
            context: *anyopaque,
            fleet: *track.Fleet,
            actions: []f32,
        ) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const per_character: usize = self.host.raw.len;
            const offset_count: usize = track.actionSize(fleet.m);
            for (0..fleet.options.envs) |env| {
                self.featuresOf(fleet, env);
                // The judged character's slot holds the action it was given last (at rest when its judgement began):
                // the action applied before this decision, which the policy reads.
                const slot: []f32 = actions[env * per_character ..][0..per_character];
                self.host.applied = slot;
                // Judged: the policy, with a flow's typical correction - from zero noise, nothing drawn.
                if (self.kit.flow_actor != null) {
                    @memset(self.flow_start_noise, 0);
                    self.host.correctedRow(self.flow_start_noise);
                } else {
                    self.host.policyRow();
                }
                // Given as training gives it: never non-finite, then through the action filter into the slot. The
                // judge counts no non-finite actions of its own; training's count is the one watched.
                _ = giveAction(self.options, offset_count, self.host.raw, slot);
            }
        }

        /// The host's copy of the mailbox from the newest readback of the parameter buffer, when the readback reaches
        /// it. On a GPU the readback is a few frames old, so the copy may lag the newest decision by those frames;
        /// `plannedCorrection` accounts for that through the stamp.
        pub fn refreshMailbox(self: *Self) void {
            const readback: []const f32 = self.kit.pipe.readLatest(.params) orelse return;
            const mailbox_end: usize = self.mailbox_at + self.mailbox_copy.len;
            if (readback.len < mailbox_end) {
                return;
            }
            @memcpy(self.mailbox_copy, readback[self.mailbox_at..mailbox_end]);
        }

        /// The host's copy of the device's numbers (`device_stats`) from the newest readback of the parameter
        /// buffer, when the readback reaches them - a frame or so old on a GPU, which a log of rounds does not mind.
        pub fn refreshDeviceStats(self: *Self) void {
            const readback: []const f32 = self.kit.pipe.readLatest(.params) orelse return;
            const stats_floats: u32 = kit_mod.DeviceStats.floats;
            const stats_end: usize = self.stats_at + stats_floats;
            if (readback.len < stats_end) {
                return;
            }
            const stats_numbers: []const f32 = readback[self.stats_at..stats_end];
            self.device_stats = bytesToValue(kit_mod.DeviceStats, sliceAsBytes(stats_numbers));
        }

        /// Character `env`'s planned CORRECTION for this acting step - what the plan adds to the policy's reaction to
        /// the state the character is in (`TrackingScorer`) - or null when it has none. It has one when:
        ///
        ///     it holds a slot                        it plans (`PlanningFlags`)
        ///     the mailbox holds a decision           its stamp is not 0
        ///     the decision is this character's      made at or after the step it took the slot - the readback may
        ///                                            still carry a plan made for the slot's previous character
        ///     the plan reaches this step            index = acting steps - decision step, below the horizon
        ///
        /// THE INDEX. A decision is made right after the step that called for it, when the acting steps have just
        /// become N; its stamp is N + 1. The next action chosen - at acting steps N - is the plan's step 0, the one
        /// after its step 1, and so on: index = acting steps - (stamp - 1). If the plan reaches the host late, as it
        /// does on a GPU, the index has moved on by the frames it took, and the character joins its plan where the
        /// plan has got to. Worked: a decision stamped 41 (made at step 40) reaching the host at step 42 is acted on
        /// from its step 2, then 3; with a horizon of 4, at step 44 it has run out and the policy acts until the next.
        pub fn plannedCorrection(self: *const Self, env: usize) ?[]const f32 {
            const flags: PlanningFlags = self.planning_flags orelse return null;
            if (self.planner == null) {
                return null;
            }
            const slot: u32 = flags.slots[env] orelse return null;
            const stamp: u32 = @bitCast(self.mailbox_copy[0]);
            if (stamp == 0) {
                return null;
            }
            const decision_step: u32 = stamp - 1;
            const holds_slot_now: bool = self.slot_owners[slot] == env;
            const decided_since_taking_it: bool = decision_step >= self.slot_owner_since[slot];
            const is_this_characters: bool = holds_slot_now and decided_since_taking_it;
            if (!is_this_characters) {
                return null;
            }
            const acting_step: u32 = @truncate(self.acting_steps);
            const plan_index: u32 = acting_step -% decision_step;
            const shape: bmpc_kit.SearchShape = self.planner.?.scorer.searchShape();
            if (plan_index >= shape.horizon) {
                return null;
            }
            const action_width: u32 = shape.action_width;
            const plan_action_at: usize = 1 + (slot * shape.horizon + plan_index) * action_width;
            return self.mailbox_copy[plan_action_at..][0..action_width];
        }

        /// The planning hazard (`planningHazard`) of whatever `z` and `goal` hold (`features`): how far toward a fall
        /// the character is, as a fraction of the failure barrier's margins.
        pub fn characterHazard(self: *const Self) f32 {
            return planningHazard(
                M,
                self.host.z,
                self.host.goal,
                self.norm.mean,
                self.norm.spread,
                self.kit.barrier_head_column,
                self.kit.barrier_up_column,
                self.options.barrier,
            );
        }

        // ===== The state file: stop a run, and carry it on later exactly =====

        /// The parameters a state file holds, with Adam's two moments for each - everything in [0, `params_end`).
        /// The header names its parts (the world model's, the policy's, the critic's, the flow's, the skip model's) to
        /// check a file's
        /// shape; here the parts must cover the range exactly, so a block placed without being named in the header
        /// is caught at once rather than saved without its name.
        fn parameterCount(self: *const Self) usize {
            const named_parts: usize = self.kit.param_count + self.kit.policy_count + self.critic_parameter_count +
                self.flow_parameter_count + self.skip_parameter_count;
            const parts_cover_the_range: bool = named_parts == self.params_end;
            assertf(parts_cover_the_range, @src(), "the named parameter blocks ({d}) do not cover [0, {d})", .{
                named_parts,
                self.params_end,
            });
            return self.params_end;
        }

        /// The size of this learner's state file (`exportState`), in bytes. Known from the learner's shape alone,
        /// before anything has been read back from the GPU.
        pub fn stateByteCount(self: *const Self) usize {
            const parameter_float_count: usize = 3 * self.parameterCount();
            const normalizer_float_count: usize = self.norm.mean.len + self.norm.spread.len;
            const float_count: usize = parameter_float_count + normalizer_float_count + self.flow_noise.len;
            return @sizeOf(StateHeader) + float_count * @sizeOf(f32);
        }

        /// The header this learner would write now: its shape, its options and every counter.
        fn stateHeader(self: *const Self) StateHeader {
            return .{
                .magic = state_file_magic,
                .feature_count = @intCast(self.host.z.len),
                .reference_count = self.kit.references,
                .action_count = @intCast(self.host.raw.len),
                .world_parameter_count = self.kit.param_count,
                .policy_parameter_count = self.kit.policy_count,
                .critic_parameter_count = self.critic_parameter_count,
                .flow_parameter_count = self.flow_parameter_count,
                .flow_noise_count = @intCast(self.flow_noise.len),
                .skip_parameter_count = self.skip_parameter_count,
                .options = savedOptionsOf(self.options),
                .world_updates = self.world_updates,
                .policy_updates = self.policy_updates,
                .critic_updates = self.critic_updates,
                .exposure = self.exposure,
                .failures = self.failures,
                .judged_exposure = self.judged_exposure,
                .judged_failures = self.judged_failures,
                .mirror_rejected = self.mirror_rejected,
                .nonfinite_actions = self.nonfinite_actions,
                .acting_steps = self.acting_steps,
                .random_stream_state = self.rng.s,
            };
        }

        /// Whether the readback reflects every update dispatched so far. On a GPU the parameters and Adam's moments
        /// come back a frame or so late, while the counters are the CPU's own and always current: a file saved before
        /// the two agree would pair one update's weights with the next update's step count. On the CPU and worker
        /// backends there is no queue, and this is always true.
        pub fn isReadbackCurrent(self: *Self) bool {
            const generation: compute_host.Compute(M).Generation = self.kit.pipe.readGeneration();
            return generation.mirrored >= generation.submitted;
        }

        /// Waits until the readback holds something and is current (`isReadbackCurrent`), by polling it: each poll
        /// starts a copy when none is in flight and takes one that has landed. For a program without frames - the
        /// trainer, natively; never in a page, whose readbacks land only between its frames.  Both conditions, because
        /// a readback can be current and empty: after `importState` forgets the copy in flight
        /// (`Compute.discardReadback`), a round that dispatched nothing - the first after a resume, while the replay
        /// refills - leaves no newer dispatch to wait for, yet nothing to read until a fresh copy lands. WHAT IS NOT
        /// FINITE, if anything - a run's watchdog: the newest readback's weights (everything below `params_end`: the
        /// world model's from 0, the policy's from `LatentKit.p_at`, then the critic's and the flow's), then the
        /// device's numbers (`DeviceStats`), the first not finite named - or null when all are finite. On the device a
        /// weight that has stopped being finite never comes back, and every update after spreads it: a run should stop
        /// before anything saves it, its last saved state intact.
        pub fn nonfiniteCause(self: *const Self) ?[]const u8 {
            const params: []const f32 = self.kit.pipe.readLatest(.params) orelse return null;
            const policy_end: u32 = self.kit.p_at + self.kit.policy_count;
            for (params[0..self.params_end], 0..) |weight, index| {
                if (isFinite(weight)) {
                    continue;
                }
                if (index < self.kit.p_at) {
                    return "the world model's weights";
                }
                if (index < policy_end) {
                    return "the policy's weights";
                }
                return "the critic's or the flow's weights";
            }
            inline for (@typeInfo(kit_mod.DeviceStats).@"struct".field_names) |stat_name| {
                const stat: f32 = @field(self.device_stats, stat_name);
                if (!isFinite(stat)) {
                    return stat_name;
                }
            }
            return null;
        }

        pub fn waitForReadback(self: *Self) void {
            while (true) {
                const holds_a_readback: bool = self.kit.pipe.readLatest(.params) != null;
                if (holds_a_readback and self.isReadbackCurrent()) {
                    return;
                }
            }
        }

        /// The learner's whole state as a file's worth of bytes: its shape, options and counters (`StateHeader`),
        /// then both networks' parameters, Adam's two moments and the feature normaliser. Enough to carry training on
        /// exactly; the replay is not kept - a resumed learner refills it by acting before its first update.
        ///
        /// The parameters and moments come from the latest readback, so call `waitForReadback` first in a program
        /// that has no frames. Memory: the bytes are allocated with `gpa` and become the caller's to free.
        pub fn exportState(self: *Self, gpa: Allocator) ![]u8 {
            const parameter_count: usize = self.parameterCount();
            const parameters: []const f32 = self.kit.pipe.readLatest(.params) orelse return error.NoReadback;
            const first_moments: []const f32 = self.kit.pipe.readLatest(.adam_m) orelse return error.NoReadback;
            const second_moments: []const f32 = self.kit.pipe.readLatest(.adam_v) orelse return error.NoReadback;
            const parameters_reached: bool = parameters.len >= parameter_count;
            const moments_reached: bool = first_moments.len >= parameter_count and
                second_moments.len >= parameter_count;
            if (!parameters_reached or !moments_reached) {
                return error.NoReadback;
            }
            const header: StateHeader = self.stateHeader();
            const state_bytes: []u8 = try gpa.alloc(u8, self.stateByteCount());
            @memcpy(state_bytes[0..@sizeOf(StateHeader)], asBytes(&header));
            // The numbers in the order `StateHeader` documents, each section's bytes straight after the last.
            const sections: [6][]const f32 = .{
                parameters[0..parameter_count],
                first_moments[0..parameter_count],
                second_moments[0..parameter_count],
                self.norm.mean,
                self.norm.spread,
                self.flow_noise,
            };
            var write_offset: usize = @sizeOf(StateHeader);
            for (sections) |section| {
                const section_bytes: []const u8 = sliceAsBytes(section);
                @memcpy(state_bytes[write_offset..][0..section_bytes.len], section_bytes);
                write_offset += section_bytes.len;
            }
            assertf(write_offset == state_bytes.len, @src(), "exportState: wrote {d} of {d} bytes", .{
                write_offset,
                state_bytes.len,
            });
            return state_bytes;
        }

        /// Why `state_bytes` cannot be this learner's state, named - `"shape.actions"`, `"options.hidden"`, ... - or
        /// null when it can. The header is read and compared field by field before any number is trusted: a file of
        /// another layout, another shape or other options is refused, never read as the wrong thing. Then every number
        /// is checked: finite, Adam's second moments not below zero, the normaliser's spreads above zero.
        pub fn stateProblem(self: *const Self, state_bytes: []const u8) ?[]const u8 {
            const header_size: usize = @sizeOf(StateHeader);
            if (state_bytes.len < header_size) {
                return "not a SuperTrack state file: shorter than its header";
            }
            const saved: StateHeader = std.mem.bytesToValue(StateHeader, state_bytes[0..header_size]);
            if (!eql(u8, &saved.magic, &state_file_magic)) {
                return "not a SuperTrack state file of this layout: magic";
            }
            const own: StateHeader = self.stateHeader();
            if (saved.feature_count != own.feature_count) {
                return "shape.features";
            }
            if (saved.reference_count != own.reference_count) {
                return "shape.references";
            }
            if (saved.action_count != own.action_count) {
                return "shape.actions";
            }
            const same_network_sizes: bool = saved.world_parameter_count == own.world_parameter_count and
                saved.policy_parameter_count == own.policy_parameter_count and
                saved.critic_parameter_count == own.critic_parameter_count and
                saved.flow_parameter_count == own.flow_parameter_count and
                saved.skip_parameter_count == own.skip_parameter_count;
            if (!same_network_sizes) {
                return "shape.parameters";
            }
            if (saved.flow_noise_count != own.flow_noise_count) {
                return "shape.flow_noise: another number of characters";
            }
            if (optionsProblem(saved.options, self.options)) |differing_option| {
                return differing_option;
            }
            if (state_bytes.len != self.stateByteCount()) {
                return "the file's length";
            }
            // The numbers themselves, section by section: a NaN weight or moment would poison every update that reads
            // it, and a spread of zero divides a feature by zero. Adam's second moments are averages of squares, so
            // they may be zero but never negative; the spreads must be above zero.
            const float_size: usize = @sizeOf(f32);
            const parameter_bytes: usize = self.parameterCount() * float_size;
            const feature_bytes: usize = self.norm.mean.len * float_size;
            const parameters_at: usize = header_size;
            const first_moments_at: usize = parameters_at + parameter_bytes;
            const second_moments_at: usize = first_moments_at + parameter_bytes;
            const means_at: usize = second_moments_at + parameter_bytes;
            const spreads_at: usize = means_at + feature_bytes;
            const parameter_section: []const u8 = state_bytes[parameters_at..][0..parameter_bytes];
            const first_moment_section: []const u8 = state_bytes[first_moments_at..][0..parameter_bytes];
            const second_moment_section: []const u8 = state_bytes[second_moments_at..][0..parameter_bytes];
            const mean_section: []const u8 = state_bytes[means_at..][0..feature_bytes];
            const spread_section: []const u8 = state_bytes[spreads_at..][0..feature_bytes];
            if (!numbersAreUsable(parameter_section, false)) {
                return "numbers.parameters: not finite";
            }
            if (!numbersAreUsable(first_moment_section, false)) {
                return "numbers.first_moments: not finite";
            }
            const second_moments_usable: bool = numbersAreUsable(second_moment_section, false) and
                noNumberIsNegative(second_moment_section);
            if (!second_moments_usable) {
                return "numbers.second_moments: not finite, or below zero";
            }
            if (!numbersAreUsable(mean_section, false)) {
                return "numbers.normalizer_means: not finite";
            }
            if (!numbersAreUsable(spread_section, true)) {
                return "numbers.normalizer_spreads: not finite, or not above zero";
            }
            const flow_noise_at: usize = spreads_at + feature_bytes;
            const flow_noise_section: []const u8 = state_bytes[flow_noise_at..][0 .. self.flow_noise.len * float_size];
            if (!numbersAreUsable(flow_noise_section, false)) {
                return "numbers.flow_noise: not finite";
            }
            return null;
        }

        /// Carry on from a state saved by `exportState` - on this device or another - or fail with
        /// `error.StateFileRefused`, `stateProblem` saying why. The weights, Adam's moments and the normaliser go to
        /// the GPU; the counters and the random stream to this learner; and the mirror takes the saved policy at once,
        /// so acting does not wait for a readback to catch up with the upload.
        ///
        /// Memory: `gpa` holds a temporary aligned copy of the numbers (a file's bytes owe nothing to an f32's
        /// alignment), freed before this returns; nothing allocated outlives the call.
        pub fn importState(self: *Self, gpa: Allocator, state_bytes: []const u8) !void {
            if (self.stateProblem(state_bytes) != null) {
                return error.StateFileRefused;
            }
            const header_size: usize = @sizeOf(StateHeader);
            const saved: StateHeader = std.mem.bytesToValue(StateHeader, state_bytes[0..header_size]);
            const number_bytes: []const u8 = state_bytes[header_size..];
            const saved_numbers: []f32 = try gpa.alloc(f32, number_bytes.len / @sizeOf(f32));
            defer gpa.free(saved_numbers);
            @memcpy(sliceAsBytes(saved_numbers), number_bytes);
            // The sections, in the order `StateHeader` documents.
            const parameter_count: usize = self.parameterCount();
            const feature_count: usize = self.norm.mean.len;
            const normalizer_at: usize = 3 * parameter_count;
            const parameters: []const f32 = saved_numbers[0..parameter_count];
            const first_moments: []const f32 = saved_numbers[parameter_count..][0..parameter_count];
            const second_moments: []const f32 = saved_numbers[2 * parameter_count ..][0..parameter_count];
            const means: []const f32 = saved_numbers[normalizer_at..][0..feature_count];
            const spreads: []const f32 = saved_numbers[normalizer_at + feature_count ..][0..feature_count];
            const flow_noise_at: usize = normalizer_at + 2 * feature_count;
            const saved_flow_noise: []const f32 = saved_numbers[flow_noise_at..][0..self.flow_noise.len];
            self.kit.pipe.upload(.params, parameters);
            self.kit.pipe.upload(.adam_m, first_moments);
            self.kit.pipe.upload(.adam_v, second_moments);
            // A readback copy encoded before these uploads would bring back the replaced weights, and the next
            // `syncMirror` would put them in the mirror: forget it, so that the mirror takes only a copy made after.
            self.kit.pipe.discardReadback();
            @memcpy(self.norm.mean, means);
            @memcpy(self.norm.spread, spreads);
            self.data.uploadNormalizer(self.norm);
            // The mirror takes the saved policy at once: acting does not wait for a readback to catch up.
            const saved_policy: []const f32 = parameters[self.kit.p_at..][0..self.kit.policy_count];
            @memcpy(self.host.mirror, saved_policy);
            // And the flow's - its mirror, its synergies and each character's noise - so acting resumes where it
            // stopped.
            if (self.host.flow_mirror.len > 0) {
                @memcpy(self.host.flow_mirror, parameters[0..self.host.flow_mirror.len]);
            }
            if (self.kit.flow_actor) |flow_actor| {
                const synergies_at: u32 = flow_actor.correction.synergies_at;
                @memcpy(self.host.synergies, parameters[synergies_at..][0..self.host.synergies.len]);
            }
            @memcpy(self.flow_noise, saved_flow_noise);
            self.world_updates = saved.world_updates;
            self.policy_updates = saved.policy_updates;
            self.critic_updates = saved.critic_updates;
            self.exposure = saved.exposure;
            self.failures = saved.failures;
            self.judged_exposure = saved.judged_exposure;
            self.judged_failures = saved.judged_failures;
            self.mirror_rejected = saved.mirror_rejected;
            self.nonfinite_actions = saved.nonfinite_actions;
            self.acting_steps = saved.acting_steps;
            self.rng.s = saved.random_stream_state;
            // The trust in the critic the restored updates have earned, before anything is planned or trained.
            self.applyCriticTrust();
        }
    };
}
