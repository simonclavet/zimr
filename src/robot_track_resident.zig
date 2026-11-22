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
const maxInt = zm.maxInt;
const rbt = @import("robot");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const latent = @import("robot_latent.zig");
const kit_mod = @import("robot_latent_kit.zig");
const wgpu = @import("wgpu.zig");
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
const isNan = zm.isNan;
const float64 = zm.float64;
const poseSeenFrom = zm.poseSeenFrom;

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

/// THE WORLD MODEL's GATE (`Phases.gate`) - what opens phase 2 before its bound. The world model is measured on
/// lookaheads none of its updates has drawn (`Resident.measureWorldModel`), at the first round that can, then every
/// `measure_every_minutes` of training, in phase 1 and after it, so that the log shows its error and its answer to an
/// action through the whole run. Each measurement is judged against the bars (`gatePasses`), and `passes_needed`
/// measurements passing in a row open phase 2 (`Resident.judgeGate`). A fixed-width struct, saved with the phases.
pub const Gate = extern struct {
    /// The training minutes from one measurement to the next; 0 measures at every round.
    measure_every_minutes: f32 = 0.5,
    /// The world model's error, rolled open loop over the windows, at most this share of the error of a model that
    /// predicts no change.
    state_error_ratio_bar: f32 = 0.25,
    /// Its answer to an action, after the first step and at the window's last: a cosine of at least this against the
    /// physics' answer...
    response_cosine_bar: f32 = 0.8,
    /// ...and a length ratio within this factor of 1, either way - from 1 / band to band.
    response_ratio_band: f32 = 2,
    /// The measurements passing in a row that open the gate; 0 never opens it - phase 2 then begins at phase 1's
    /// bound alone.
    passes_needed: u32 = 2,
};

/// ONE MEASUREMENT OF THE WORLD MODEL FOR ITS GATE, as the stats block holds it (`kit_mod.DeviceStats.gate_*`): its
/// error and the no-change model's on the same windows, per number, in the loss's own units - each feature's square
/// weighed by its loss weight, so their ratio is the one XMimic's loss would give; its answer to an action against the
/// physics', the cosine and the length ratio, after the first step and at the window's last
/// (`kit_mod.LatentKit.recordWorldModelGate`).
pub const GateReading = struct {
    world_error: f32,
    no_change_error: f32,
    first_response_cosine: f32,
    first_response_ratio: f32,
    last_response_cosine: f32,
    last_response_ratio: f32,

    /// The reading the device's numbers hold.
    pub fn of(stats: kit_mod.DeviceStats) GateReading {
        return .{
            .world_error = stats.gate_world_error,
            .no_change_error = stats.gate_no_change_error,
            .first_response_cosine = stats.gate_first_response_cosine,
            .first_response_ratio = stats.gate_first_response_ratio,
            .last_response_cosine = stats.gate_last_response_cosine,
            .last_response_ratio = stats.gate_last_response_ratio,
        };
    }
};

/// WHETHER A MEASUREMENT PASSES THE GATE's BARS (`Gate`): the world model's error at most `state_error_ratio_bar` of
/// the no-change model's, and its answer to an action - after the first step and at the window's last - a cosine of
/// at least `response_cosine_bar` and a length ratio from 1 / `response_ratio_band` to `response_ratio_band`, each
/// bar included. A number that is not finite passes nothing; nor does a no-change error of 0: windows in which nothing
/// moved say nothing of a model.
///
/// Worked, at the default bars: an error of 0.02 against the no-change model's 0.4 is a twentieth of it, under a
/// quarter; cosines of 0.93 and 0.85, at least 0.8; ratios of 0.7 and 1.4, inside a half to two - it passes. A last
/// ratio of 0.45 - the model's answer to an action less than half the physics' by the window's end - fails it.
pub fn gatePasses(gate: Gate, reading: GateReading) bool {
    const numbers = [_]f32{
        reading.world_error,
        reading.no_change_error,
        reading.first_response_cosine,
        reading.first_response_ratio,
        reading.last_response_cosine,
        reading.last_response_ratio,
    };
    for (numbers) |number| {
        if (!isFinite(number)) {
            return false;
        }
    }
    if (reading.no_change_error <= 0) {
        return false;
    }
    const error_bar: f32 = gate.state_error_ratio_bar * reading.no_change_error;
    if (reading.world_error > error_bar) {
        return false;
    }
    const cosines = [2]f32{ reading.first_response_cosine, reading.last_response_cosine };
    for (cosines) |cosine| {
        if (cosine < gate.response_cosine_bar) {
            return false;
        }
    }
    const lowest_ratio: f32 = 1.0 / gate.response_ratio_band;
    const ratios = [2]f32{ reading.first_response_ratio, reading.last_response_ratio };
    for (ratios) |ratio| {
        const inside_band: bool = ratio >= lowest_ratio and ratio <= gate.response_ratio_band;
        if (!inside_band) {
            return false;
        }
    }
    return true;
}

/// WHAT A LABEL UPDATE TEACHES THE POLICY, each phase its own (`Phases.phase_one_labels`, `phase_two_labels`;
/// `Resident.trainPolicyByKind`):
///
///     recorded_actions   the planners' actions as they were recorded, the squared distance to each
///                        (`Resident.trainPolicyOnLabels`) - where the plans for a situation split, their average
///     flow_mode          the flow's main mode around the flow's base: the base's answer plus the flow run from
///                        the centre of its noise, in raw actions (`Resident.trainPolicyOnFlowMode`,
///                        `LatentKit.policyModeTrainStep`) - the flow learning the plans by flow matching in the
///                        same update. Where the plans split unevenly, the side more of them took
///
/// The flow's mode needs a flow that learns from the plans on the device (`FlowExamples`). Either way, a label update
/// gives the flow its turn at the plans (teacher 2): in phase 1 there is no other.
pub const LabelTarget = enum(u8) {
    recorded_actions = 0,
    flow_mode = 1,
};

/// THE TRAINING's TWO PHASES - the teacher alone first, the world model's gradient once the world model is good:
///
///     phase 1   from the start         every policy update a label update: the policy distilled from the planners
///                                      (`Resident.trainPolicyOnLabels`); the world model learns - most of its batches
///                                      the candidates' lookaheads - and gives the policy nothing
///     phase 2   once the world model   the policy's updates through the world model ramped in: their share rising
///               passes its gate, or    from none to `1 - label_share_after_ramp` over `ramp_minutes`, the labels'
///               at `phase_one_minutes`  falling to `label_share_after_ramp`; the candidates' batches back at the
///                                      run's `candidate_batch_share`
///
/// Early in training the world model's answer to an action is poor, and its gradient would move the policy in
/// directions no physics backs, against a teacher right from the first minute; so the policy learns from the teacher
/// until the world model is trusted. Off (`enabled` false), every policy update is a rollout's through the world
/// model, as it always was. A fixed-width struct, so a learner's state file can hold it.
pub const Phases = extern struct {
    enabled: bool = false,
    /// What a label update teaches the policy in each phase (`LabelTarget`): in phase 1 the recorded actions start
    /// it fastest - the flow, learning the plans in the same updates, has no modes yet - and from phase 2 the flow's
    /// main mode can take over, once the flow has learned the plans' ways.
    phase_one_labels: LabelTarget = .recorded_actions,
    phase_two_labels: LabelTarget = .recorded_actions,
    /// The byte after them, written as zero: the settings are saved byte for byte (`hasNoPadding`).
    padding_after_labels: u8 = 0,
    /// Phase 1's bound: past it phase 2 begins whatever the world model's gate says.
    phase_one_minutes: f32 = 10,
    /// The minutes over which phase 2's rollouts take their share from the labels.
    ramp_minutes: f32 = 3,
    /// The share of the policy's updates still on the labels once the ramp is over: what remains of the teacher.
    label_share_after_ramp: f32 = 0.1,
    /// The candidates' share of the world model's batches in phase 1 - most of them: their lookaheads are the many
    /// actions from one state the world model's answer to an action is learned from. Phase 2's is the run's
    /// `candidate_batch_share`.
    phase_one_candidate_batch_share: f32 = 0.8,
    /// The world model's gate: how it is measured.
    gate: Gate = .{},
};

/// THE SHARE OF THE POLICY's UPDATES THAT ARE LABEL UPDATES at a moment of the training (`Phases`): every one in
/// phase 1 (`hours_into_phase_two` null); from phase 2's start, falling in a straight line to `label_share_after_ramp`
/// over `ramp_minutes` - the rollouts through the world model taking the rest - and held there. A ramp of no minutes
/// falls at once.
///
/// Worked, with a ramp of 3 minutes down to 0.1: at phase 2's start 1; a minute in 1 - 0.9 x 1/3 = 0.7; three minutes
/// in and every minute after, 0.1.
pub fn labelUpdateShare(phases: Phases, hours_into_phase_two: ?f32) f32 {
    const into_phase_two: f32 = hours_into_phase_two orelse return 1.0;
    const ramp_hours: f32 = phases.ramp_minutes / 60.0;
    const ramp_done: f32 = if (ramp_hours > 0) @min(1.0, into_phase_two / ramp_hours) else 1.0;
    const share_given_up: f32 = 1.0 - phases.label_share_after_ramp;
    return 1.0 - share_given_up * ramp_done;
}

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
    /// THE PLAN's LAST STEPS THROUGH THE SKIP HEAD (`TrackingScorer.Options.skip_steps`): this many of the horizon's
    /// steps, at its end, jump the skip head's decisions - the search screens each candidate further ahead for the
    /// same steps. 0: every step one decision. Needs the skip head (`Options.skip_steps`).
    skip_steps: u32 = 0,
    /// Four bytes written as zeros, so the settings stay a whole number of eight-byte words in a state file.
    padding_after_skip_steps: [4]u8 = @splat(0),
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

/// A hazard projected ahead along its rise - what the flags read, so a fall in progress is caught early: robot.zig's
/// (`rbt.projectedHazard`), which the device's teacher reads too.
pub const projectedHazard = rbt.projectedHazard;

/// THE POLICY's RATE BOOST (`Options.policy_rate_boost`, XMimic's `pi_mult`): the policy's learning rate times
/// `multiplier` for its first `held_rounds` rounds of training, then a straight ramp to 1 over `ramp_rounds` more -
/// a policy far from its reference has much to learn and little to lose, so it steps larger, and settles at its base
/// rate once its episodes hold. XMimic's: 4, until its training episodes' normalised return per decision, averaged
/// over 50 iterations, reaches 0.75 - or iteration 1,400 at the latest - then 300. Here the bound alone ends it: the
/// return's trigger needs each finished episode's reward on the host, which a device keeps to itself (the plan's
/// later turn). A round is an iteration - one collection, its updates - counted from training's first
/// (`Resident.training_rounds`), the warm-up's left out. A multiplier of 1: no boost.
pub const RateBoost = extern struct {
    multiplier: f32 = 1,
    held_rounds: u32 = 1400,
    ramp_rounds: u32 = 300,

    /// The multiplier at training round `round`, counted from 0:
    ///
    ///     round < held                     multiplier
    ///     held <= round < held + ramp      multiplier + (1 - multiplier) x (round - held) / ramp
    ///     past them                        1
    ///
    /// Worked, at XMimic's 4, 1,400 and 300: 4 through round 1,399; 4 at round 1,400, 2.5 at 1,550, 1 from 1,700.
    pub fn at(boost: RateBoost, round: u64) f32 {
        const held: u64 = boost.held_rounds;
        if (round < held) {
            return boost.multiplier;
        }
        const ramp_rounds_done: u64 = round - held;
        if (ramp_rounds_done >= boost.ramp_rounds) {
            return 1;
        }
        const progress: f32 = float(ramp_rounds_done) / float(boost.ramp_rounds);
        return boost.multiplier + (1 - boost.multiplier) * progress;
    }
};

/// THE WORLD MODEL's FORM, as an option (`Options.world_form`, `Options.kitWorldForm`): an enum of a fixed integer, so
/// that a state file saves it as it saves every option.
pub const WorldModelForm = enum(u32) {
    /// SuperTrack's: two hidden layers of tanh (`robot_latent_kit.WorldForm.dense_tanh`) - the skip head's trunk.
    dense_tanh,
    /// SuperMimic's, the foundation's: hidden layers each linear, layer norm and SiLU
    /// (`robot_latent_kit.WorldForm.normed_silu`).
    normed_silu,
};

/// THE WORLD MODEL's RUNNING STATISTICS (`Options.world_statistics`), as XMimic keeps them for its world model
/// (`zn_mlp.lat_world_moments`), folded every round from every transition collected - each pair of records the books
/// say is one step of unbroken motion (`track.Replay.Books.continuesAt`) - in raw units, from a count of 0. ITS
/// INPUT: every column its first layer reads - the state, the servo's encoded targets, the action - read as
/// (raw - mean) / sqrt(var + inputs_epsilon^2), XMimic's `in_norm`. ITS CHANGE, in units of its typical change: the
/// network predicts each feature's change over a decision as mean + spread x its output, and its loss weighs each
/// feature's error by 1 / max(spread, floor)^2 - every feature's error in units of how much it changes in a step,
/// measured where the model is used: the transitions collected hold the falls, which the reference clips do not.
///
/// The floors are XMimic's (`err_floor`), in its units, each kind of feature (`rbt.LocalFeatureKind`) taking the
/// floor of what it is in XMimic's state: a body's position and height are positions, its rotation in the root's
/// frame is its joints' turns composed, the world's up seen from the root is the root's own rotation. The epsilons
/// are the ones its spreads take (`rn_apply(in_norm, .., 1e-2)`, `rn_std(inc_norm, 1e-4)`, `rn_std(out_norm, 1e-4)`),
/// and the limit the count at which its running statistics stop (`rn_update`'s `max_count`) - far past any run
/// here: XMimic's iteration collects 10,240 transitions, so 2e8 is about 20,000 iterations. An extern struct of
/// words, as a state file saves it.
pub const WorldStatistics = extern struct {
    /// Metres: the bodies' positions in the root's frame, and their heights - XMimic's root position's.
    position_floor: f32 = 3.0e-3,
    /// The numbers of the bodies' rotations' two axes in the root's frame - XMimic's joint angles'.
    rotation_floor: f32 = 3.0e-3,
    /// The numbers of the world's up seen from the root - XMimic's root rotation's.
    up_floor: f32 = 5.0e-3,
    /// Metres a second - XMimic's root velocity's.
    velocity_floor: f32 = 2.0e-2,
    /// Radians a second - XMimic's root angular velocity's and joint rates' alike.
    angular_velocity_floor: f32 = 5.0e-2,
    /// Added, squared, to each change's variance before its root is taken: the spread of a feature that never
    /// changes.
    change_epsilon: f32 = 1.0e-4,
    /// Added, squared, to each input column's variance before its root is taken: the spread of a column that never
    /// moves.
    inputs_epsilon: f32 = 1.0e-2,
    /// The transitions the moments take, after which they stay as they are.
    moments_limit: f32 = 2.0e8,

    /// Feature `feature`'s floor, in its raw units, by its kind in `layout`.
    pub fn floorOf(
        statistics: WorldStatistics,
        layout: rbt.LocalLayout,
        feature: u32,
    ) f32 {
        return switch (layout.kindOf(feature)) {
            .position, .height => statistics.position_floor,
            .rotation_axis => statistics.rotation_floor,
            .up => statistics.up_floor,
            .velocity => statistics.velocity_floor,
            .angular_velocity => statistics.angular_velocity_floor,
        };
    }
};

pub const Options = struct {
    /// Windows per update, and the world model's window in steps: it is fit on windows this long, rolled forward on
    /// the actions the simulator took, so it learns to correct its own errors. Its windows are drawn at this length,
    /// whatever the policy's horizon (`Resident.drawWindows`), from anywhere in a segment - the last ones before a loss
    /// among them, as XMimic's `sample_windows` draws them.
    rows: u32 = 16,
    window: u32 = 8,
    /// THE POLICY'S HORIZON: the single steps it imagines through the world model, before its skip steps
    /// (`policy_skip_steps`) and the critic's tail past them all - the steps of both together at least `window`; 0:
    /// the world model's window (`horizon`). The policy's rollouts are imagined for the horizon's decisions from
    /// starts of a record each (`Resident.drawPolicyStarts`); the world model's windows are its own `window`. With a
    /// critic, a horizon of 8 learns poorly, 16 matches a critic-free 32, and 32 learns fastest (Liao et al. 2026,
    /// SuperMimic).
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
    /// THE WORLD MODEL's FORM (`robot_latent_kit.WorldForm`): the foundation's normed form - `world_hidden_layers`
    /// layers of `hidden`, each linear, layer norm (epsilon 1e-5) and SiLU, every layer started as PyTorch starts a
    /// linear one, weights and biases uniform within 1/sqrt(fan-in), the last exactly zero: XMimic's `wm_init`
    /// (`robot_latent_kit.NormedWorld`). SuperTrack's two hidden layers of tanh remain only as the trunk the skip head
    /// reads - its second layer - so a run with a skip head names that form.
    world_form: WorldModelForm = .normed_silu,
    world_hidden_layers: u32 = 3,
    /// THE WORLD MODEL ALONE FIRST: the policy's first rollout update through the world model waits until the world
    /// model has had this many updates; until then a rollout's turn passes (a label update still takes its own). A
    /// world model in the normed form starts predicting "nothing changes", whatever the action, so a policy learning
    /// through it from the start learns at first only its action's price. SuperMimic's own code has no such wait; a
    /// reproduction of it trained its world model alone for its first 500 iterations, of 10 updates each. 0, the
    /// default: no wait.
    world_alone_updates: u32 = 0,
    /// THE WORLD MODEL's LEARNING RATE: XMimic's 4e-4, its one rate for Muon's matrices and Adam's other numbers
    /// (Muon's step at 0.2 sqrt(side) times it, which gives an update of about Adam's root-mean-square size). XMimic
    /// lowers it by a cosine to 3% over 250,000 iterations, which over the 3,500 it trains leaves it at 99.95% of
    /// itself - so the rate here stays as given (`rate_decay_updates` 0).
    world_rate: f32 = 4.0e-4,
    policy_rate: f32 = 3.0e-4,
    /// THE POLICY'S OPTIMISER (`LatentKit.policy_optimizer`): its gradient's whole length bounded, then each number
    /// (0: no bound), and Adam's second-moment decay - 0.95 follows the gradient's scale faster than 0.999, which
    /// back-propagation through a long rollout wants. SuperMimic bounds its policy's length to 1.0 and each number to
    /// 0.1 in its loss's units; ours is a sum over the horizon of per-step mean squared distances, so the bounds are
    /// set against the logged `policy_gradient_norm`. The defaults bound nothing: the same numbers as an unclipped
    /// Adam.
    policy_gradient_clip: f32 = 0,
    /// THE WORLD MODEL'S GRADIENT BOUND: its update's global length clipped to this (`LatentKit.world_optimizer`) -
    /// a fall's hard-to-predict contacts can give a window's gradient hundreds of times a tracking window's. XMimic's
    /// 1, in its loss's own units, which are this loss's: each state's term the mean over rows and features of its
    /// error over the change's spread squared, summed over the window's steps (`WorldStatistics`). Above 0.
    world_gradient_clip: f32 = 1,
    /// THE SKIP HEAD (`robot_latent_kit.SkipModel`): a head on the world model's second hidden layer, trained on the
    /// same windows to predict this many steps at once - what a planner's far half jumps with. 0: none; otherwise at
    /// least 2 (one step is the world model's own) and at most the world model's window (`window`), which holds
    /// window / span of its jumps.
    skip_span: u32 = 0,
    /// THE WORLD MODEL's SKIP HEAD (`robot_latent_kit.WorldHeads`): a second last layer over the world model's trunk,
    /// for a step of this many decisions - each head's output then the projection of the state `projection_steps`
    /// decisions on, a step the lerp toward it. 0: SuperTrack's single head, its output the change.
    skip_steps: u32 = 0,
    /// The decisions on of the heads' projection, K: a step of k decisions takes k / K of its head's output. Read
    /// only with a skip head.
    projection_steps: u32 = 6,
    /// THE SKIP HEAD's SHARE OF THE WORLD MODEL's UPDATES (`Resident.trainWorld`): at this share, spread evenly
    /// (`dueAtShare`), an update's windows are rolled as `window / skip_steps` steps of the skip head - the states the
    /// records reached at each step's end its targets, the mean of the actions given over each step its action - and
    /// its loss trains the trunk with the skip head. Read only with a skip head.
    skip_batch_share: f32 = 0.25,
    /// THE POLICY THROUGH SKIPS: after its single steps (`policy_window`), this many steps of the skip head's
    /// decisions in the policy's imagined rollout - the policy acting at each, the action it gives held over the step,
    /// the step's cost weighted by its decisions - so the policy sees a horizon of `horizonDecisions` decisions in
    /// `horizon` steps. 0: none. Needs the skip head.
    policy_skip_steps: u32 = 0,
    /// THE SKIP HEAD's CONSISTENCY (`Resident.trainSkipConsistency`): the share of the skip head's updates that train
    /// it toward the world model's slow average's one-step head chained over its skip under a held action - the
    /// recorded actions' mean - rather than toward the records. 0: none.
    skip_consistency_share: f32 = 0.5,
    /// The world model's slow average's decay d, the consistency's target: after every world model update each
    /// averaged weight moves (1 - d) of the way to the live one. Read only with the consistency.
    world_average_decay: f32 = 0.99,
    /// THE WORLD MODEL's RUNNING STATISTICS (`WorldStatistics`), every round from every transition collected
    /// (`zn_mlp.lat_world_moments`): each input column read by its running mean and spread
    /// (`LatentKit.inputs_affine_at`); each feature's change predicted in units of its running spread
    /// (`LatentKit.increments_at`), its error weighed by 1 / max(spread, floor)^2 (`LatentKit.loss_weights_at`). A
    /// feature that moves little in a step is predicted, and judged, as finely as one that moves much - to its floor.
    world_statistics: WorldStatistics = .{},
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
    /// filter. A run parameter, as `filter` is. It acts where the fleet's action carries the limbs' stiffnesses
    /// (`track.Fleet.Options.limb_stiffness`); a policy of the offsets alone has nothing for it to filter.
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
    /// MUON ON THE POLICY (`kit_mlp.Muon`): the policy's hidden-to-hidden matrix steps by Muon - its gradient's
    /// Nesterov momentum orthogonalised - and every other weight by Adam, one rate for both. The world model's
    /// hidden-to-hidden matrices always do (`Resident.placeWorldMuon`). Needs the policy's clip
    /// (`policy_gradient_clip`).
    policy_muon: bool = false,
    /// THE ROOT TARGET (`rbt.root_target_size`): whether the policy's goal carries, in its slots after the reference's
    /// features, where the reference's root is seen from the character's - the position in the character's frame and
    /// the turn between them as two axes - or zeros. The features are each in their own root's frame, so they show
    /// the reference's pose and motion but not where the reference is: a character that drifts off the reference's
    /// path, or turns away from its heading, sees the same goal as one on it. The root target shows the drift. The
    /// goal has the slots either way (`supertrackGoalWidth`), so the networks are the same shape on and off. Where
    /// the characters act, the slots are filled (`supertrackFeaturesInto`, robotgpu's `policy_inputs`). In the windows
    /// the policy trains on, the first row's are exact - the gather's, from the recorded roots - and every later row's
    /// are imagined: the root moved through the rollout by the velocities the world model predicts, the policy's
    /// gradient carried back through it (`LatentKit.imagined_root`). The policy's loss charges the root's drift from
    /// the reference's at every rolled state (`LatentKit.ImaginedRoot`), weighed against the bodies' features as
    /// SuperMimic weighs its root (`root_cost`).
    root_target: bool = false,
    /// THE ROOT's COST, with the root target on: its position's and its rotation's shares of the bodies' weight in the
    /// policy's loss (`track.rootCostWeights`, from the feature normaliser) - SuperMimic's half by default. A share of
    /// 0 takes its term out; both at 0 leave the policy reading a target nothing teaches it to act on.
    root_cost: track.RootCostShares = .{},
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
    /// The share of the world model's updates whose batch is a planner's candidates' lookaheads, not the characters'
    /// own records (`Resident.trainWorld`), while the learner records its candidates (`acceptCandidateRecording`): a
    /// fixed share, never in proportion to the records - the candidates make many more of them than the characters.
    candidate_batch_share: f32 = 0.25,
    /// THE LABELS' WEIGHT (`Resident.trainPolicyOnLabels`): the policy's distillation toward the planners' labels is
    /// the mean squared distance between the action it would give and each label, times this. Label updates and
    /// rollout updates share the policy's optimiser - its Adam moments - so the weight sets the labels' gradient beside
    /// the rollout's; on its own, an Adam step hardly depends on it.
    label_weight: f32 = 1.0,
    /// THE POLICY's SLOW AVERAGE (Polyak averaging): after every policy update, avg <- d avg + (1 - d) w over the
    /// policy's weights, d this decay. The judge, the recovery probes and the policy file read the average; the acting,
    /// the planners and every loss read the live weights. An average of the last few hundred updates (1 / (1 - d):
    /// 200 at 0.995) jitters less than any one of them - BlinkMimic reaches its tracking bar in about three quarters
    /// of the iterations with it. 0: no average, the live weights judged.
    policy_average_decay: f32 = 0,
    /// The training's two phases (`Phases`): off, every policy update is a rollout's through the world model.
    phases: Phases = .{},
    /// One round: this many simulation steps, then this many updates of each network.
    collect: u32 = 32,
    world_updates: u32 = 1,
    policy_updates: u32 = 1,
    seed: u64 = 1,
    /// THE WARM-UP (XMimic's `warmup_steps`): rounds collect and fold the world model's running statistics
    /// (`foldWorldStatistics`) but update no network until every character's ring holds this many decisions
    /// (`Resident.warmingUp`) - so the first update draws from a replay of varied states, and its statistics are the
    /// transitions' own, not the first round's. The foundation's 256 is XMimic's 262,144 records at 1,024 characters.
    /// At most the ring's capacity. 0: no warm-up.
    warmup_decisions: u32 = 0,
    /// THE POLICY's RATE BOOST (`RateBoost`): off - a multiplier of 1 - unless a recipe asks for XMimic's.
    policy_rate_boost: RateBoost = .{},

    /// The policy's horizon in steps: `policy_window`, or the world model's `window` when that is 0 - and its skip
    /// head's steps after them (`policy_skip_steps`).
    pub fn horizon(options: Options) u32 {
        const fine_steps: u32 = if (options.policy_window > 0) options.policy_window else options.window;
        return fine_steps + options.policy_skip_steps;
    }

    /// The policy's horizon in decisions: its single steps, and its skip steps of the skip head's decisions each - the
    /// records a window must hold.
    pub fn horizonDecisions(options: Options) u32 {
        const fine_steps: u32 = options.horizon() - options.policy_skip_steps;
        return fine_steps + options.policy_skip_steps * options.skip_steps;
    }

    /// The kit's form of the world model these options ask for (`world_form`, `world_hidden_layers`).
    /// The world model's heads (`robot_latent_kit.WorldHeads`): one, or a skip head beside it.
    pub fn kitHeads(options: Options) kit_mod.WorldHeads {
        return .{ .skip_steps = options.skip_steps, .projection_steps = options.projection_steps };
    }

    pub fn kitWorldForm(options: Options) kit_mod.WorldForm {
        return switch (options.world_form) {
            .dense_tanh => .dense_tanh,
            .normed_silu => .{ .normed_silu = .{ .hidden_layers = options.world_hidden_layers } },
        };
    }
};

/// The first bytes of a SuperTrack state file (`Resident.exportState`). The digit is the layout's version: it changes
/// whenever the layout below changes, so that a file of an older layout is refused rather than read as this one.
const state_file_magic: [8]u8 = "ZSTSTA28".*;

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
    world_form: WorldModelForm,
    world_hidden_layers: u32,
    world_alone_updates: u32,
    skip_steps: u32,
    policy_skip_steps: u32,
    /// The word that keeps the options a multiple of the seed's 8-byte alignment.
    world_rate: f32,
    policy_rate: f32,
    policy_gradient_clip: f32,
    world_gradient_clip: f32,
    skip_span: u32,
    /// Eight words.
    world_statistics: WorldStatistics,
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
    policy_muon: bool,
    /// The fourth bool, which fills the bools' word.
    root_target: bool,
    root_cost: track.RootCostShares,
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
    /// The word before the seed, which brings it to its 8-byte alignment.
    projection_steps: u32,
    seed: u64,
    candidate_batch_share: f32,
    label_weight: f32,
    policy_average_decay: f32,
    skip_batch_share: f32,
    skip_consistency_share: f32,
    /// The word that keeps the options a multiple of the seed's 8-byte alignment.
    world_average_decay: f32,
    phases: Phases,
    warmup_decisions: u32,
    /// The word after the warm-up's, which keeps the options a multiple of the seed's 8-byte alignment.
    padding_after_warmup: u32,
    /// Three words, and the one after them that keeps the options a multiple of 8 bytes.
    policy_rate_boost: RateBoost,
    padding_after_boost: u32,
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
    /// The policy's slow average (`Options.policy_average_decay`), saved straight after the policy's own weights - 0
    /// without one.
    policy_average_count: u32,
    options: SavedOptions,
    world_updates: u32,
    policy_updates: u32,
    /// The critic's updates - its Adam step count - and a word that keeps the counters after it 8-byte aligned.
    critic_updates: u32,
    /// The world model's slow average's floats (`Resident.world_average_count`): 0 without the skip head's
    /// consistency.
    world_average_count: u32,
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
    /// The rounds of training so far (`Resident.training_rounds`): where the policy's rate boost stands
    /// (`RateBoost.at`), so a resumed run does not boost its policy again from the start.
    training_rounds: u64,
    /// The xoshiro256 generator's four words - the whole of its state.
    random_stream_state: [4]u64,
    /// Whether phase 2 had begun (1) or phase 1 lasts (0) - and the training hours it began at - so a resumed run
    /// carries on in its phase (`Resident.phase_two_began_hours`).
    phase_two_began: u32,
    phase_two_began_hours: f32,
    /// How far the fleet's pushes' top had opened (`robot.PushTop.share`), so a resumed run goes on pushing as hard
    /// as it did.
    push_top_share: f32,
    /// The world model's running statistics' floats (`Resident.world_statistics_count`), saved straight after the
    /// skip model's - the word that keeps the header free of padding.
    world_statistics_count: u32,
};

/// Whether `T` - an extern struct, and every extern struct inside it, through arrays - has no padding: its fields'
/// sizes add up to its own. A state file copies its header byte for byte, so a padding byte would carry whatever the
/// stack held, and a learner saved twice would write two different files. A policy file's headers are held to it too
/// (`robot_lab.PolicyFile`).
pub fn hasNoPadding(comptime T: type) bool {
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

/// HOW WIDE SuperTrack's GOAL IS for `feature_count` features (`supertrackFeaturesInto`): the reference's features,
/// then the root target's slots (`rbt.root_target_size`). The policy reads the goal, then the state's features.
pub fn supertrackGoalWidth(feature_count: usize) usize {
    return feature_count + rbt.root_target_size;
}

/// SuperTrack's two feature vectors for character `character` of `fleet`, normalised by `normalizer`: the STATE - the
/// character's simulated bodies in its root's frame (`robot_track.local`) - into `out_state`, and the GOAL - the
/// reference one frame ahead of the character's frame, each in its own root's frame - into `out_goal`. The goal is
/// where the servo aims next, so the policy sees both where the character is and where it is meant to be a step from
/// now. Each feature becomes `(x - mean) / spread`.
///
///     out_goal    [ the reference's features | the root target's slots ]     features + `rbt.root_target_size`
///     out_state   [ the character's features ]                                features
///
/// The goal's slots after its features hold THE ROOT TARGET when `root_target` is on - where that reference frame's
/// root is, seen from the character's root (`poseSeenFrom`): metres and unit axes, read as they are - and zeros when
/// it is off. Each feature vector is in its own root's frame, so the features alone never show how far the character
/// has drifted from where the reference is.
///
/// One definition for every place a SuperTrack policy acts: the learner while it collects and is judged
/// (`Resident.featuresOf`), and the lab's player of its policy file (`robot_lab.PolicyDecider`). `scratch` holds the
/// intermediate states and is the caller's; nothing is allocated.
pub fn supertrackFeaturesInto(
    fleet: *track.Fleet,
    character: usize,
    normalizer: latent.Normalizer,
    root_target: bool,
    scratch: FeatureScratch,
    out_goal: []f32,
    out_state: []f32,
) void {
    const feature_count: usize = out_state.len;
    const goal_fits: bool = out_goal.len == supertrackGoalWidth(feature_count);
    assertf(goal_fits, @src(), "supertrackFeaturesInto: a goal of {d} for {d} features", .{
        out_goal.len,
        feature_count,
    });
    track.stateOf(fleet.m, &fleet.data[character], scratch.simulated);
    track.local(scratch.simulated.*, fleet.root, scratch.raw_features);
    normalizer.toNormal(scratch.raw_features, out_state);
    const clip: *const dance.Clip = fleet.clips[fleet.clip_of[character]];
    const next_frame: u32 = fleet.frame[character] + 1;
    fleet.referenceStateInto(clip, next_frame, scratch.probe, scratch.reference);
    track.local(scratch.reference.*, fleet.root, scratch.raw_features);
    normalizer.toNormal(scratch.raw_features, out_goal[0..feature_count]);
    const root_target_slots: *[rbt.root_target_size]f32 = out_goal[feature_count..][0..rbt.root_target_size];
    if (!root_target) {
        @memset(root_target_slots, 0);
        return;
    }
    const character_root: rbt.Pose = .{
        .pos = scratch.simulated.positions[fleet.root],
        .rot = scratch.simulated.rotations[fleet.root],
    };
    const reference_root: rbt.Pose = .{
        .pos = scratch.reference.positions[fleet.root],
        .rot = scratch.reference.rotations[fleet.root],
    };
    root_target_slots.* = poseSeenFrom(character_root, reference_root);
}

/// THE FLOW CORRECTING A POLICY, as its policy file takes it (`robot_lab.PolicyFlow`): its network's layers - their
/// shapes, kinds and offsets - and the CPU's copy of the parameters they are addressed in, its sampler's steps and
/// time frequencies, and the synergies its coefficients are decoded through, [coefficient][action].
pub const FlowPolicyParts = struct {
    layers: []const kit_mlp.KitLayer,
    parameters: []const f32,
    euler_steps: u32,
    time_frequencies: u32,
    synergies: []const f32,
};

/// What a SuperTrack policy file is made of (`robot_lab.policyOfSuperTrack`), as the learner holds it: the policy's
/// weights as acting uses them (the mirror, packed as `LatentKit.packPolicy` packs them - the first layer reading the
/// goal then the state as one input, then the two later layers, each its weights then its biases), the network's
/// widths, and the feature normaliser. Every slice is the learner's, borrowed.
pub const PolicyParts = struct {
    packed_weights: []const f32,
    /// The state's features; the goal is these and the root target's slots after them (`supertrackFeaturesInto`).
    feature_count: usize,
    /// Whether the goal's slots hold the root target or zeros (`Options.root_target`).
    root_target: bool,
    hidden_width: usize,
    action_count: usize,
    normalizer: latent.Normalizer,
    /// The action filter the policy acted through in training (`Options.filter`, the joints' offsets' share): a player
    /// gives its actions through the same filter, so it acts as the policy learned to.
    filter: f32,
    /// The limbs' stiffnesses at the action's end - the fleet's limbs where its action carries them
    /// (`track.Fleet.Options.limb_stiffness`), else 0 - and the filter's share they were given through
    /// (`Options.stiffness_filter`).
    stiffness_count: usize,
    stiffness_filter: f32,
    /// The flow correcting the policy, when the learner has one (`Options.actor`): what the policy file keeps of it.
    flow: ?FlowPolicyParts = null,
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
        /// THE WEIGHTS THE POLICY IS JUDGED WITH, as the CPU last saw them: the policy's slow average where the learner
        /// keeps one (`Options.policy_average_decay`), else the live weights again. The judge, the probes and the
        /// policy file read these (`policyRowOf`); acting reads `mirror`.
        judged: []f32 = &.{},
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
            self.policyRowOf(self.mirror);
        }

        /// `policyRow` with the packed weights `weights` - the live ones (`mirror`) or the judged ones (`judged`).
        pub fn policyRowOf(self: *Self, weights: []const f32) void {
            const hp: usize = self.hidden1.len;
            const goal_width: usize = self.goal.len;
            const f: usize = self.z.len;
            // Walking the packed weights, in the order `packPolicy` writes them. The first layer is two
            // blocks because a row is [goal | state] and the policy reads both: the goal block first
            // (the row starts with the goal - its features, then the root target's slots), then the state
            // block, then that layer's bias. After it, the ordinary pairs. Every weight matrix is stored row
            // by row of its INPUT - element (i, j) at i * outputs + j - which is why each inner loop strides
            // by `hp` (or by the action count in the last layer).
            const w_goal: usize = 0;
            const w_state: usize = goal_width * hp;
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
                var sum: f32 = weights[b1 + j];
                for (self.goal, 0..) |g, i| {
                    sum += g * weights[w_goal + i * hp + j];
                }
                for (self.z, 0..) |x, i| {
                    sum += x * weights[w_state + i * hp + j];
                }
                // The action applied before this decision, through its own block, after the goal's and the state's
                // terms - the kit's order (`applied_add_activate`) - and only then the tanh.
                for (self.applied, 0..) |x, i| {
                    sum += x * weights[w_applied + i * hp + j];
                }
                self.hidden1[j] = zm.tanh(sum);
            }
            for (0..hp) |j| {
                var sum: f32 = weights[b2 + j];
                for (self.hidden1, 0..) |x, i| {
                    sum += x * weights[w2 + i * hp + j];
                }
                self.hidden2[j] = zm.tanh(sum);
            }
            for (self.raw, 0..) |*out, j| {
                var sum: f32 = weights[b3 + j];
                for (self.hidden2, 0..) |x, i| {
                    sum += x * weights[w3 + i * self.raw.len + j];
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
            self.correctedRowOf(self.mirror, start_noise);
        }

        /// `correctedRow` with the policy's packed weights `weights` - the live ones or the judged ones.
        pub fn correctedRowOf(
            self: *Self,
            weights: []const f32,
            start_noise: []const f32,
        ) void {
            const has_flow_actor: bool = self.flow != null;
            assertf(has_flow_actor, @src(), "correctedRow: this learner has no flow (`Options.actor`)", .{});
            const flow_actor: kit_mod.FlowActor(M) = self.flow.?;
            self.policyRowOf(weights);
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

/// EACH PLANNER's BEST QUARTER OF ITS CANDIDATES BY SCORE, marked in `out_favoured`, one flag a candidate: the
/// candidates are blocks of `candidates_per_planner`, planner after planner, and in each block the `ceil(n / 4)` best
/// scores are favoured - the winner always among them. A score that is not a number is a candidate whose physics
/// failed: never favoured, and ranked behind every other. Of equal scores the earlier candidate ranks first, as the
/// planner's own choice does (`robotgpu_host.bestInBlock`).
pub fn favourBestQuarter(
    scores: []const f32,
    candidates_per_planner: u32,
    out_favoured: []bool,
) void {
    assertf(scores.len == out_favoured.len, @src(), "{d} scores for {d} flags", .{ scores.len, out_favoured.len });
    const block_size: usize = candidates_per_planner;
    const whole_blocks: bool = block_size > 0 and scores.len % block_size == 0;
    assertf(whole_blocks, @src(), "{d} scores in blocks of {d}", .{ scores.len, block_size });
    const favoured_per_block: usize = (block_size + 3) / 4;
    var block_start: usize = 0;
    while (block_start < scores.len) : (block_start += block_size) {
        const block_scores: []const f32 = scores[block_start..][0..block_size];
        const block_favoured: []bool = out_favoured[block_start..][0..block_size];
        for (block_scores, block_favoured, 0..) |score, *favoured, candidate| {
            if (isNan(score)) {
                favoured.* = false;
                continue;
            }
            // The candidates ranked before this one: a better score, or an equal one earlier in the block.
            var ranked_before: usize = 0;
            for (block_scores, 0..) |other_score, other| {
                const better: bool = other_score > score;
                const equal_and_earlier: bool = other_score == score and other < candidate;
                ranked_before += @intFromBool(better or equal_and_earlier);
            }
            favoured.* = ranked_before < favoured_per_block;
        }
    }
}

/// One of `flags`' favoured candidates, each as likely: null when none is.
fn drawFavoured(flags: []const bool, random: Random) ?u32 {
    var favoured_count: u32 = 0;
    for (flags) |favoured| {
        favoured_count += @intFromBool(favoured);
    }
    if (favoured_count == 0) {
        return null;
    }
    var favoured_left: u32 = random.uintLessThan(u32, favoured_count);
    for (flags, 0..) |favoured, candidate| {
        if (!favoured) {
            continue;
        }
        if (favoured_left == 0) {
            return @intCast(candidate);
        }
        favoured_left -= 1;
    }
    unreachable;
}

/// WHAT RECORDING A PLANNER's CANDIDATES KEEPS (`Resident.acceptCandidateRecording`): their lookaheads, in a ring of
/// their own in the learner's kit beside the characters' (`kit_mod.RecordRing`), and which candidates each lookahead
/// favoured. The candidates step together, so their records keep one count, as the characters' do; but they record
/// only in lookaheads - every step of a lookahead at once, at a replan - so they cannot share the characters' steps.
///
///     a replan's lookahead     d = 0    1    2   ...   H - 1    H
///     a candidate's records    s0 a0  s1 a1  s2 a2 ... sH-1 aH-1  sH        (state, the action taken from it)
///
/// THE LOOKAHEAD IS THE UNIT. Lookahead L's decision d is the ring's step L (H + 1) + d (`stepOf`), and the ring holds
/// `lookaheads_kept` lookaheads' steps - always the newest, whole. A lookahead is unbroken motion from a copy, and the
/// next begins from another copy, so a window is drawn inside one (`drawStart`). Its last record, the state after its
/// last decision, is at most a window's last target; its action is read by nothing.
///
/// THE FAVOURED. Once a lookahead's scores are known (`complete`), each planner's best quarter of its candidates is
/// marked (`favourBestQuarter`): the winner and those nearest it, which the world model sees more of.
/// TEACHER 2's EXAMPLES ON THE DEVICE (`kit_mod.FlowActor.Distillation`): every decision at which a planner follows
/// its plan around the policy, what its acting row held - the [goal | state] it acted from, the action applied before
/// - and the planner's whole choice, the policy's action plus the plan's offset, kept in a ring in the kit
/// (`zn_mlp.gather_flow_examples`); each round a batch is drawn from it on the device (`zn_mlp.gather_flow_batch`).
/// What the flow learns from the planners: the offset they found, where the policy alone fell short.
///
/// THE OFFSET IS TAKEN WHEN IT IS LEARNED, not when it was found (`Resident.retargetFlowBatch`). Before every policy
/// update the policy answers the batch's rows again, and the flow's target is the choice less that answer, in the
/// flow's coefficients (`zn_mlp.synergy_project_difference`). The policy learns from the same plans (the labels), so
/// an offset kept as it was found would be counted twice once the policy has taken part of it in - the flow adding
/// it again on top - and the two would chase each other through the plans. Taken now, the policy and the flow share
/// one target, the planner's choice: whatever the policy learns of it, the flow's part shrinks by exactly as much.
///
///     ring             `capacity` slots of (condition | applied | choice), the oldest overwritten once full
///     plan numbers     the characters' plans' numbers at the decision, copied from the simulator - their offsets
///                      around the policy, or the actions given as whole actions: [character][stride]
///     example table    a decision's examples, [example][acting row, slot] - one row a character at most
///     batch table      a round's batch, [batch row] slot
///     batch            the batch's applied actions and choices, [batch row][action] - its conditions are the
///                      distillation's own - and the policy's rows answering them (`batch_policy`)
///
/// ONLY PLANS THAT ENDED WELL ARE LEARNED. Each slot remembers whose it is - the character and the record its example
/// was kept with - and is good once the label books keep that record's label: the plan's stretch settled with no
/// decision of it failed (`track.LabelBooks`; `Resident.appendBooksStep`). Teacher 2's batch and the flow's mode rows
/// are drawn from the good slots alone (`goodSlots`). A slot whose stretch failed, or has not settled yet, is never
/// drawn, and waits to be overwritten: the flow learns the ways back that worked, not every way a plan tried.
///
/// The counts and the slots' owners are the host's; the numbers stay on the device, and are not saved: a resumed
/// run's ring starts empty.
pub const FlowExamples = struct {
    ring_at: u32,
    capacity: u32,
    count: u32 = 0,
    next: u32 = 0,
    plan_numbers_at: u32,
    table_at: u32,
    batch_table_at: u32,
    /// The batch's applied actions and choices, [batch row][action]; the policy's two hidden layers over the batch's
    /// rows and its answers, [batch row][action] - the rows the policy acts on (`Resident.batchPolicyRows`), their
    /// inputs the distillation's conditions.
    batch_applied_at: u32,
    batch_choices_at: u32,
    batch_hidden1_at: u32,
    batch_hidden2_at: u32,
    batch_answers_at: u32,
    /// THE FLOW's MODE's ROWS (`Resident.trainPolicyOnFlowMode`): a batch of the kit's rows drawn from the ring - its
    /// table [row] slot, the choices [row][action] (their conditions and applied actions go straight into the kit's
    /// label rows, `LatentKit.labelRows`) - and the policy's targets there, [row][action].
    mode_table_at: u32,
    mode_choices_at: u32,
    mode_targets_at: u32,
    /// The host's tables before their upload, as floats: room for one a character's two numbers, for the batch, and
    /// for the mode's rows.
    table: []f32,
    batch_table: []f32,
    mode_table: []f32,
    /// Each slot's owner - the character, as an acting row, and the record its example was kept with (none: the
    /// largest record number) - and whether its stretch ended well; [slot] each. And room to gather the good slots.
    slot_character: []u32,
    slot_record: []u64,
    slot_good: []bool,
    good_slots: []u32,

    /// A slot no example has taken: its record number, which no record reaches.
    const no_record: u64 = maxInt(u64);

    /// The slots teacher 2 may learn from: those kept whose stretch ended well, gathered in slot order.
    pub fn goodSlots(examples: FlowExamples) []const u32 {
        var good_count: usize = 0;
        for (examples.slot_good[0..examples.count], 0..) |is_good, slot| {
            if (!is_good) {
                continue;
            }
            examples.good_slots[good_count] = @intCast(slot);
            good_count += 1;
        }
        return examples.good_slots[0..good_count];
    }

    /// The slots of character `character`'s examples kept with the records `labels` name - labels the books have just
    /// kept, their stretches ended well - made good. A record's example is in one slot at most (a character keeps one
    /// a decision); one the ring has already overwritten is found nowhere.
    pub fn markKept(examples: FlowExamples, labels: []const track.Label) void {
        for (labels) |label| {
            const label_character: u32 = label.env;
            for (examples.slot_character[0..examples.count], 0..) |character, slot| {
                const is_its_slot: bool = character == label_character and examples.slot_record[slot] == label.index;
                if (is_its_slot) {
                    examples.slot_good[slot] = true;
                    break;
                }
            }
        }
    }
};

pub const CandidateRecording = struct {
    ring: kit_mod.RecordRing,
    /// A planner's candidates: a block of the ring's envs, planner after planner.
    candidates_per_planner: u32,
    /// The records a lookahead keeps: its H decisions', and the state after them.
    lookahead_records: u32,
    /// The lookaheads the ring holds.
    lookaheads_kept: u32,
    /// The lookaheads complete - recorded whole, their candidates ranked. Also the number of the lookahead being
    /// recorded.
    lookaheads_complete: u64 = 0,
    /// Each kept lookahead's favoured, a flag a candidate (`favouredOf`): `lookaheads_kept` rows.
    favoured: []bool,
    /// Each kept lookahead's planners - its first blocks of candidates, the only ones it ran (`plannersOf`): fewer
    /// than the ring's blocks where the planners are chosen by trouble (`robot.PlanningOptions.trouble_planners`);
    /// a block past them holds an older lookahead's records, never drawn. `lookaheads_kept` numbers.
    planners_recorded: []u32,

    /// The ring's step of lookahead `lookahead`'s decision `decision` - H for the state after its last.
    pub fn stepOf(recording: CandidateRecording, lookahead: u64, decision: u32) u64 {
        const in_lookahead: bool = decision < recording.lookahead_records;
        assertf(in_lookahead, @src(), "decision {d} of a lookahead of {d} records", .{
            decision,
            recording.lookahead_records,
        });
        return lookahead * recording.lookahead_records + decision;
    }

    /// Lookahead `lookahead`'s favoured flags, a flag a candidate: the row of the kept lookaheads it occupies.
    pub fn favouredOf(recording: CandidateRecording, lookahead: u64) []bool {
        const candidate_count: usize = recording.ring.envs;
        const row: usize = @intCast(lookahead % recording.lookaheads_kept);
        return recording.favoured[row * candidate_count ..][0..candidate_count];
    }

    /// Lookahead `lookahead`'s planners: its first blocks of candidates, the ones it ran.
    pub fn plannersOf(recording: CandidateRecording, lookahead: u64) u32 {
        const row: usize = @intCast(lookahead % recording.lookaheads_kept);
        return recording.planners_recorded[row];
    }

    /// The candidates lookahead `lookahead` ran: its planners' blocks, from the first.
    pub fn candidatesOf(recording: CandidateRecording, lookahead: u64) u32 {
        return recording.plannersOf(lookahead) * recording.candidates_per_planner;
    }

    /// THE LOOKAHEAD BEING RECORDED, COMPLETE: its last record must be in the ring; it ran the first `planner_count`
    /// planners' blocks, whose candidates' scores, read back after it (`scores`, one a candidate of every block the
    /// ring holds), mark its favoured - no candidate past them is; and the next lookahead's records follow it.
    pub fn complete(
        recording: *CandidateRecording,
        scores: []const f32,
        planner_count: u32,
    ) void {
        const lookahead: u64 = recording.lookaheads_complete;
        const last_step: u64 = recording.stepOf(lookahead, recording.lookahead_records - 1);
        const recorded_whole: bool = recording.ring.appended == last_step;
        assertf(recorded_whole, @src(), "lookahead {d} completed before its last record", .{lookahead});
        const blocks_held: u32 = recording.ring.envs / recording.candidates_per_planner;
        assertf(planner_count >= 1 and planner_count <= blocks_held, @src(), "{d} planners of {d} blocks", .{
            planner_count,
            blocks_held,
        });
        const row: usize = @intCast(lookahead % recording.lookaheads_kept);
        recording.planners_recorded[row] = planner_count;
        const candidates_run: u32 = planner_count * recording.candidates_per_planner;
        const favoured: []bool = recording.favouredOf(lookahead);
        @memset(favoured, false);
        favourBestQuarter(scores[0..candidates_run], recording.candidates_per_planner, favoured[0..candidates_run]);
        recording.lookaheads_complete += 1;
    }

    /// A WINDOW's START FOR THE WORLD MODEL, `window_steps` long, inside a lookahead the ring holds whole: the
    /// lookahead drawn among those, each as likely; its candidate among its favoured (`favoured_only` - among all
    /// when none is, every score failed) or among all; its first record among the window's places in the lookahead.
    /// Null when there is none to draw: no lookahead complete yet, or a window longer than a lookahead.
    ///
    /// WHAT WAS APPLIED BEFORE IT (`kit_mod.Start.continues_episode`): past the lookahead's first decision, the action
    /// of the record before - the lookahead's own, held with it. At the first, the candidate's applied action as it
    /// was copied from its planner, which this ring does not hold: the window is staged as opening, from rest. Nothing
    /// reads it: only the world model learns from these windows, and it reads each step's recorded action, never the
    /// action applied before a window.
    pub fn drawStart(
        recording: CandidateRecording,
        random: Random,
        window_steps: u32,
        favoured_only: bool,
    ) ?kit_mod.Start {
        const lookahead_steps: u32 = recording.lookahead_records - 1;
        if (window_steps > lookahead_steps or recording.lookaheads_complete == 0) {
            return null;
        }
        const kept: u64 = @min(recording.lookaheads_complete, recording.lookaheads_kept);
        const lookahead: u64 = recording.lookaheads_complete - kept + random.uintLessThan(u64, kept);
        // Among the candidates the lookahead ran: its planners' blocks.
        const candidates_run: u32 = recording.candidatesOf(lookahead);
        const favoured_run: []const bool = recording.favouredOf(lookahead)[0..candidates_run];
        const favoured_candidate: ?u32 = if (favoured_only) drawFavoured(favoured_run, random) else null;
        const candidate: u32 = favoured_candidate orelse random.uintLessThan(u32, candidates_run);
        const start_places: u32 = lookahead_steps - window_steps + 1;
        const first_decision: u32 = random.uintLessThan(u32, start_places);
        return .{
            .env = candidate,
            .index = recording.stepOf(lookahead, first_decision),
            .continues_episode = first_decision > 0,
        };
    }

    /// THE GATE's WINDOWS, IN PAIRS (`kit_mod.LatentKit.recordWorldModelGate`), `window_steps` long, into `starts`
    /// two by two: rows 2p and 2p + 1 are two different candidates of one planner in one lookahead, each window from
    /// the lookahead's first decision - one state, two actions:
    ///
    ///     the lookahead    among the FRESH ones the ring holds - complete from `first_fresh` on, none of which an
    ///                      update has drawn - each as likely
    ///     the planner      among the planners the lookahead ran, each as likely
    ///     two candidates   of the planner's, different, each pair as likely
    ///
    /// Each window opens from rest, as `drawStart`'s do at a first decision: what a candidate applied before its
    /// lookahead is not in this ring, and the world model never reads it. False when there is nothing to draw: no
    /// fresh lookahead the ring still holds, fewer than two candidates a planner, or a window longer than a
    /// lookahead. `starts` holds pairs: an even number of rows.
    pub fn drawPairStarts(
        recording: CandidateRecording,
        random: Random,
        window_steps: u32,
        first_fresh: u64,
        starts: []kit_mod.Start,
    ) bool {
        const in_pairs: bool = starts.len % 2 == 0;
        assertf(in_pairs, @src(), "{d} rows for the gate's pairs", .{starts.len});
        const lookahead_steps: u32 = recording.lookahead_records - 1;
        const candidates_per_planner: u32 = recording.candidates_per_planner;
        if (window_steps > lookahead_steps or candidates_per_planner < 2) {
            return false;
        }
        const kept: u64 = @min(recording.lookaheads_complete, recording.lookaheads_kept);
        const oldest_held: u64 = recording.lookaheads_complete - kept;
        const first_drawable: u64 = @max(first_fresh, oldest_held);
        if (first_drawable >= recording.lookaheads_complete) {
            return false;
        }
        const fresh_count: u64 = recording.lookaheads_complete - first_drawable;
        for (0..starts.len / 2) |pair| {
            const lookahead: u64 = first_drawable + random.uintLessThan(u64, fresh_count);
            // Among the planners the lookahead ran.
            const planner: u32 = random.uintLessThan(u32, recording.plannersOf(lookahead));
            const first_candidate: u32 = random.uintLessThan(u32, candidates_per_planner);
            // The second among the others: drawn from one fewer, and stepped past the first.
            const other_draw: u32 = random.uintLessThan(u32, candidates_per_planner - 1);
            const second_candidate: u32 = if (other_draw >= first_candidate) other_draw + 1 else other_draw;
            const block_first_env: u32 = planner * candidates_per_planner;
            const first_decision_index: u64 = recording.stepOf(lookahead, 0);
            starts[2 * pair] = .{
                .env = block_first_env + first_candidate,
                .index = first_decision_index,
                .continues_episode = false,
            };
            starts[2 * pair + 1] = .{
                .env = block_first_env + second_candidate,
                .index = first_decision_index,
                .continues_episode = false,
            };
        }
        return true;
    }
};

/// A DRAWN WINDOW AS A KIT's GATHER TAKES IT (`kit_mod.Start`), when the learner's ring - holding `ring_held` - can
/// give it whole: every record of the window, `window_length` steps from its first, and what was applied just before
/// it (`track.Replay.Books.appliedBeforeAt`) - rest on its episode's first step, otherwise the action of the record
/// before, which the ring must hold as well. Null when any of it is missing: the ring has not received the window, or
/// no longer holds the record before it (a window at its oldest record), or the books cannot say what was applied.
/// The window's drawer then draws another, as the CPU learner does (robot_latent's `Learner.drawWindow`), rather than
/// start it from a rest that never was.
pub fn windowStartInRing(
    books: track.Replay.Books,
    ring_held: kit_mod.RecordRing.HeldSteps,
    window: track.Replay.Window,
    window_length: u32,
) ?kit_mod.Start {
    const first_held: bool = window.first >= ring_held.first;
    const last_held: bool = window.first + window_length <= ring_held.last;
    if (!first_held or !last_held) {
        return null;
    }
    const applied_before: track.AppliedBefore = books.appliedBeforeAt(window.env, window.first) orelse return null;
    const continues_episode: bool = applied_before == .previous_record;
    const previous_in_ring: bool = window.first > ring_held.first;
    if (continues_episode and !previous_in_ring) {
        return null;
    }
    return .{
        .env = @intCast(window.env),
        .index = window.first,
        .continues_episode = continues_episode,
    };
}

/// WHETHER UPDATE `update_number` (counted from 1) IS ONE OF A KIND THAT HAS A SHARE `share` of the updates - the world
/// model's batches from the candidates (`Resident.trainWorld`), the policy's updates on labels
/// (`Resident.trainPolicyByKind`): those where the count of the kind's updates due by then,
/// `floor(update_number x share)`, steps up. Any run of updates then holds the share to within one update, spread
/// evenly - at a quarter every fourth update, at 0.8 four in five, at 0 none, at 1 all. A share that changes from one
/// update to the next - a ramp - is held as it stands at each.
pub fn dueAtShare(update_number: u64, share: f32) bool {
    assertf(update_number > 0, @src(), "updates count from 1", .{});
    const share_wide: f64 = share;
    const due_by_now: f64 = @floor(float64(update_number) * share_wide);
    const due_before: f64 = @floor(float64(update_number - 1) * share_wide);
    return due_by_now > due_before;
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
        /// The host's clock over a round's phases (`rbt.PhaseClock`), where a trainer accounts for its time: the
        /// learner tells it each phase it enters and each wait for the device (`enterPhase`, `waitForReadback`).
        /// Null: nobody is counting. The trainer's, which outlives the learner's rounds.
        phase_clock: ?*rbt.PhaseClock = null,
        /// Decisions watched while collecting, and the failures among them - the reference LOST,
        /// not a clip simply running out (`countDecision`): a decision of each character, so seconds are these
        /// counts over the decisions a second, not over the physics steps.
        ///
        /// These are decisions taken WITH exploration noise, because that is how data is collected. They
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
        /// THE TEACHER's PLANNERS' part of `exposure` and `failures`: the decisions at risk of the characters that
        /// were planners when they took them, and the references they lost (`countPlannerDecision`) - read against
        /// everyone's, whether the teacher tracks better than the characters around it. Not saved: a round counts
        /// their differences.
        planner_exposure: u64,
        planner_failures: u64,
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
        /// THE WORLD MODEL's RUNNING STATISTICS, after the skip model's parameters (`placeWorldStatistics`,
        /// `zn_mlp.lat_world_moments`): its input columns' moments from `input_moments_at` - a count for each input,
        /// then a mean for each, then a variance - then the affine the world model's first layer reads from them
        /// (`LatentKit.inputs_affine_at`), a shift and a scale for each input, then its change's moments from
        /// `change_moments_at`, laid out as the inputs', one of each a feature. Saved with the parameters, so a resumed
        /// world model reads and predicts as it did; `world_statistics_count` floats in all.
        input_moments_at: u32,
        change_moments_at: u32,
        world_statistics_count: u32,
        /// Where the fold's transitions are flagged (`ChangeFolding`): null only until `init` places it.
        change_folding: ?ChangeFolding = null,
        /// The last replay index the world model's statistics have taken (`foldWorldStatistics`); null before this
        /// start's first fold, which takes everything the ring holds.
        statistics_folded_through: ?u64 = null,
        /// THE POLICY's SLOW AVERAGE (`Options.policy_average_decay`): its weights, placed straight after the policy's
        /// own and in the same order, and how many - the policy's count with an average, 0 without.
        policy_average_at: u32,
        policy_average_count: u32,
        /// THE WORLD MODEL's SLOW AVERAGE (`Options.world_average_decay`): its weights straight after the policy's
        /// average, inside the parameters - read back and saved - the target of the skip head's consistency. Its
        /// count 0 without the consistency.
        world_average_at: u32,
        world_average_count: u32,
        /// The skip head's updates, and of them the consistency's (`Options.skip_consistency_share`).
        skip_head_updates: u64 = 0,
        skip_consistency_updates: u64 = 0,
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
        /// The readback generation the host's copy of the device's numbers reflects (`refreshDeviceStats`): every
        /// submission up to it is in them. Null before the first copy.
        device_stats_mirrored: ?u64 = null,
        /// The device's numbers for the log (`kit_mod.DeviceStats`): where their block starts in the parameter buffer,
        /// after everything else the readback brings back, and the host's copy from the newest readback.
        stats_at: u32,
        device_stats: kit_mod.DeviceStats,
        /// The acting steps taken so far, which stamp each decision (its step plus one: 0 is "no decision yet"); which
        /// character held each planner slot at the last decision (a slot still held by the same character starts its
        /// search warm, from its last plan); and a decision's scratch - one slot's inputs, every slot's warm flag.
        acting_steps: u64,
        /// The rounds of training so far - each a collection and its updates, the warm-up's left out (`train`): the
        /// iteration the policy's rate boost is at (`policyRateMultiplier`).
        training_rounds: u64 = 0,
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
        /// The world model's updates on the candidates' windows (`trainWorld`, at `Options.candidate_batch_share`), and
        /// those due that drew none - no lookahead recorded yet, or the world model's window longer than a lookahead -
        /// and drew the characters' instead.
        candidate_world_updates: u64 = 0,
        /// The world model's updates on a schedule of the skip head's steps (`skip_batch_share`).
        skip_world_updates: u64 = 0,
        /// THE SKIP HEAD's SCHEDULE: its steps, each of the skip head's decisions - `window / skip_steps` of them -
        /// and where in acts their record offsets are (0, k, 2k, ...), written once when the learner is made. Empty
        /// without a skip head.
        skip_schedule: []u32 = &.{},
        skip_schedule_at: u32 = 0,
        /// THE POLICY's SCHEDULE (`Options.policy_skip_steps`): each step's decisions - its single steps' 1s, then its
        /// skip steps' - and where in acts their record offsets are. Empty without skip steps.
        policy_schedule: []u32 = &.{},
        policy_schedule_at: u32 = 0,
        /// THE RECORDS A DRAWN WINDOW HOLDS, each network its own (`drawWindowsMixed`): the world model's its own
        /// window (`Options.window`, 8 - so its windows end anywhere, the last transitions into a fall included), the
        /// policy's its horizon in decisions (`Options.horizonDecisions`).
        world_window_records: u32 = 0,
        policy_window_records: u32 = 0,
        /// Each of the fleet's clips' frames, in its order: what the books need to draw a policy's starts inside a
        /// clip (`track.Replay.Books.clip_frames`). The learner's `gpa`'s, freed with it.
        clip_frame_counts: []u32 = &.{},
        candidate_batches_refused: u64 = 0,
        /// The policy's updates on the planners' labels (`trainPolicyOnLabels`) - counted among `policy_updates`, which
        /// are the policy optimiser's steps of either kind - and those refused: no label kept yet, or none the ring
        /// can give whole.
        label_updates: u64 = 0,
        label_batches_refused: u64 = 0,
        /// THE WORLD MODEL MEASURED FOR ITS GATE (`measureWorldModel`, `Gate`): the measurements made, and those due
        /// that drew none - no fresh lookahead yet - which wait for a round that can; and the training hours of the
        /// latest made, null before the first.
        gate_measurements: u64 = 0,
        gate_measurements_refused: u64 = 0,
        gate_measured_hours: ?f32 = null,
        /// THE GATE's JUDGEMENT (`judgeGate`): the submission the latest measurement was recorded in, while its numbers
        /// are awaited from the readback - null when none is, and no other measurement is made meanwhile; the
        /// measurements judged, the latest's reading, and the passes in a row. Not saved: a resumed run counts its
        /// passes again.
        gate_awaited_submission: ?u64 = null,
        gate_judged: u64 = 0,
        gate_latest: ?GateReading = null,
        gate_passes_in_a_row: u32 = 0,
        /// The lookaheads complete when the world model's updates last drew (`noteLookaheadsDrawable`): any of these
        /// an update may have drawn. Those completed after them are fresh - the gate's next measurement is made on
        /// them, before any update reaches them.
        lookaheads_drawable: u64 = 0,
        /// How much of each kernel buffer the learner's layout uses - activations, their gradients, parameters, in
        /// floats (`kit_mlp.KitLayout`) - for a run to say at its start how much room it has.
        buffers_used: kit_mlp.KitLayout = .{},
        /// ACTING THROUGH A SIMULATOR ON THE DEVICE (`acceptDeviceActing`), or null while the learner acts on its CPU
        /// fleet: the kit's rows the simulator's worlds act through, and the books kept from the flags the
        /// simulator reports, which the learner's windows are then drawn from.
        device_acting: ?DeviceActing = null,
        /// RECORDING A PLANNER's CANDIDATES (`acceptCandidateRecording`), or null: their lookaheads' records in a ring
        /// of their own beside the characters', and each lookahead's favoured.
        candidate_recording: ?CandidateRecording = null,
        /// The hours this learner's training has run, told each round by the program that trains (the trainer's saved
        /// clock): what the rates' schedule in hours follows (`Options.rate_decay_hours`), and the phases
        /// (`Options.phases`). 0 for a learner nobody times.
        training_hours: f32 = 0,
        /// THE TRAINING's PHASE (`Phases`): the training hours phase 2 began at - where the world model passed its
        /// gate, or phase 1's bound passed (`beginPhaseTwo`) - or null while phase 1 lasts, and always without
        /// phases.
        phase_two_began_hours: ?f32 = null,
        /// Exploring steps a character took from its plan (`finishActing`) - over the steps watched, the share of the
        /// acting the planner steered.
        planned_steps: u64,
        rng: Random.DefaultPrng,
        /// The gate's own stream, for its windows (`measureWorldModel`): drawn from the learner's, a measurement would
        /// move every window drawn after it, and a learner measured would learn otherwise than one not.
        gate_rng: Random.DefaultPrng,
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
            // The policy outputs the fleet's whole action: the joints' offsets (`track.actionSize`), then - when the
            // fleet's limbs have a stiffness of their own (`Options.limb_stiffness`) - one stiffness a limb. The kit,
            // the ring's records and the acting all take this width; the filter tells the two parts apart by the
            // offsets' count (`giveAction`, the kit's `stiffness_count`).
            const actions: u32 = @intCast(fleet.action_width);
            const offset_count: u32 = @intCast(track.actionSize(m));
            const stiffness_count: u32 = actions - offset_count;
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
                .planner_exposure = undefined,
                .planner_failures = undefined,
                .world_updates = undefined,
                .critic = null,
                .critic_arena = ArenaAllocator.init(gpa),
                .critic_updates = 0,
                .params_end = 0,
                .critic_parameter_count = 0,
                .host = .{},
                .flow_parameter_count = 0,
                .skip_parameter_count = 0,
                .input_moments_at = 0,
                .change_moments_at = 0,
                .world_statistics_count = 0,
                .policy_average_at = 0,
                .policy_average_count = 0,
                .world_average_at = 0,
                .world_average_count = 0,
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
                .gate_rng = undefined,
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
            // What the steps below allocate without an errdefer of its own - the planning flags, the extras, the
            // schedules, the acting rows - each empty or null until then: freed whatever step refuses the learner.
            errdefer self.freeLateParts();
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
            self.planner_exposure = 0;
            self.planner_failures = 0;
            self.world_updates = 0;
            self.policy_updates = 0;
            self.rng = Random.DefaultPrng.init(options.seed);
            const gate_stream_seed: u64 = options.seed ^ 0x6A7E_0000_0000_0001;
            self.gate_rng = Random.DefaultPrng.init(gate_stream_seed);
            // The kit as long as the policy's horizon, the world model's passes stopping at its own window.
            const horizon: u32 = options.horizon();
            const fits_window: bool = horizon >= options.window;
            assertf(fits_window, @src(), "a policy window of {d} is shorter than the world model's {d}", .{
                horizon,
                options.window,
            });
            // The policy's goal: the reference's features, then the root target's slots (`Options.root_target`) -
            // always there, so the networks are one shape whether the slots are filled or zero.
            const goal_width: u32 = @intCast(supertrackGoalWidth(feature_count));
            self.kit = try Kit.initInForm(
                pipe,
                feature_count,
                @intCast(track.targetSize(m)),
                actions,
                options.hidden,
                options.rows,
                horizon,
                goal_width,
                options.policy_hidden,
                options.kitWorldForm(),
                options.kitHeads(),
            );
            self.kit.world_steps = options.window;
            self.kit.sigma = options.sigma;
            self.kit.w_action = options.w_action;
            self.kit.w_smooth = options.w_smooth;
            // The action filter as this trainer applies it when acting (`writeAction`), so the rollouts blend the same
            // way: the offsets at `filter`, the limbs' stiffnesses after them at `stiffness_filter`.
            self.kit.filter = options.filter;
            self.kit.stiffness_filter = options.stiffness_filter;
            self.kit.stiffness_count = stiffness_count;
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
            // The planning flags, for characters acting on the CPU (on the device the teacher's replans choose who the
            // planner plans for, by the judgement's loss fraction).
            if (options.planning.enabled) {
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
            // A slot for each update, and the first for the gate's measurement (`measureWorldModel`).
            const gate_slots: u32 = 1;
            const slots: u32 = gate_slots + options.world_updates + options.policy_updates;
            // The ring's records hold the policy's whole action, as wide as the kit's.
            self.data = try kit_mod.Resident(M).initWithActions(
                gpa,
                pipe,
                fleet,
                self.kit.total,
                options.rows,
                slots,
                actions,
            );
            errdefer self.data.deinit();
            // Each clip's frames, which the policy's starts are drawn within (`drawPolicyStarts`).
            self.clip_frame_counts = try gpa.alloc(u32, fleet.clips.len);
            errdefer gpa.free(self.clip_frame_counts);
            for (self.clip_frame_counts, fleet.clips) |*frame_count, clip| {
                frame_count.* = @intCast(clip.frame_count);
            }
            // The warm-up waits for the ring to hold its decisions: one longer than the ring would never end.
            const warmup_fits: bool = options.warmup_decisions <= self.data.ring.capacity;
            assertf(warmup_fits, @src(), "a warm-up of {d} decisions, the ring holds {d}", .{
                options.warmup_decisions,
                self.data.ring.capacity,
            });
            self.data.uploadTables(fleet);
            self.data.uploadNormalizer(norm);
            self.kit.norm_at = self.data.norm_at;
            const tail_without_critic: bool = options.value_tail > 0 and !options.train_critic;
            assertf(!tail_without_critic, @src(), "the value tail needs the critic (train_critic)", .{});
            const policy_skips_without_head: bool = options.policy_skip_steps > 0 and !options.kitHeads().hasSkipHead();
            assertf(!policy_skips_without_head, @src(), "the policy's skip steps need the skip head", .{});
            const imagined_through_skips: bool = options.policy_skip_steps > 0 and options.train_critic and
                options.critic.imagined_share > 0;
            assertf(!imagined_through_skips, @src(), "the critic's imagined fit reads one decision a step", .{});
            // The parameters end where the kit's policy ends - or, with extras, where their layout ends - and the
            // readback ends with them, unless a mailbox follows them.
            // The policy's slow average straight after the policy, when there is one: inside the parameters, so the
            // readback brings it and the state file saves it.
            const has_policy_average: bool = options.policy_average_decay > 0 and self.kit.policy_count > 0;
            self.policy_average_at = self.kit.p_at + self.kit.policy_count;
            self.policy_average_count = if (has_policy_average) self.kit.policy_count else 0;
            // The world model's slow average after it, when the skip head has a consistency to aim at.
            const has_world_average: bool = options.kitHeads().hasSkipHead() and options.skip_consistency_share > 0;
            self.world_average_at = self.policy_average_at + self.policy_average_count;
            self.world_average_count = if (has_world_average) self.kit.param_count else 0;
            self.params_end = self.world_average_at + self.world_average_count;
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
                .ring_floats = self.data.ring_end,
            };
            // Where the kit finds its change's statistics first - every kit placed after this one copies them from it.
            try self.placeChangeFolding(&layout, options.world_statistics);
            // The world model's running statistics likewise, every learner's, straight after the networks: the
            // parameters of a learner without extras end with them. Then the kit's change's statistics from their
            // moments as they start.
            try self.placeWorldStatistics(&layout);
            self.writeWorldStatistics();
            self.params_end = layout.params_floats;
            self.readback_end = self.params_end;
            if (self.kit.policy_count > 0) {
                self.kit.policy_optimizer = kit_mlp.ClippedAdam.reserve(&layout, self.kit.p_at, self.kit.policy_count);
                self.kit.policy_optimizer_settings = policyOptimizerSettings(options);
            }
            // The world model's own clipped optimiser, XMimic's MuonAdam: its gradient's whole length bounded, Muon on
            // every hidden-to-hidden matrix, Adam on every other number.
            const world_clip_set: bool = options.world_gradient_clip > 0;
            assertf(world_clip_set, @src(), "the world model's gradient bound {d}: above 0", .{
                options.world_gradient_clip,
            });
            self.kit.world_optimizer = kit_mlp.ClippedAdam.reserve(&layout, self.kit.w1, self.kit.param_count);
            self.kit.world_optimizer_settings = .{ .gradient_clip = options.world_gradient_clip };
            const muon_settings: kit_mlp.MuonSettings = .{};
            self.placeWorldMuon(&layout, muon_settings);
            // Muon on the policy's hidden-to-hidden matrix, its second layer's, when asked.
            if (options.policy_muon) {
                const policy_has_optimizer: bool = self.kit.policy_optimizer != null;
                assertf(policy_has_optimizer, @src(), "the policy's Muon needs its clipped optimiser", .{});
                const policy_hidden: u32 = self.kit.policy_hidden;
                const policy_second: u32 = self.kit.policyWeights().second;
                const policy_muon: kit_mlp.Muon = .reserve(&layout, policy_second, policy_hidden, muon_settings);
                self.kit.policy_optimizer.?.addMuon(policy_muon);
            }
            // The root in imagination, when the policy's goal carries the root target: its two blocks beside the rest,
            // and what moves it - the root's velocities among the features, and a decision's seconds; its cost's
            // weights from the normaliser's spreads (`track.rootCostWeights`), and a block where its drift is measured
            // for the log. Before the extras: a planner imagines the root as the kit it is built beside does.
            if (options.root_target) {
                const steps: u32 = self.kit.steps;
                const rows: u32 = self.kit.rows;
                const bodies: usize = self.fleet.m.body_count;
                const root_body: usize = self.fleet.root;
                const cost_weights: track.RootCostWeights =
                    track.rootCostWeights(norm.spread, bodies, root_body, options.root_cost);
                self.kit.imagined_root = .{
                    .roots_at = layout.reserveActs(Kit.ImaginedRoot.rootBlockFloats(steps, rows)),
                    .goal_roots_at = layout.reserveActs(Kit.ImaginedRoot.goalRootBlockFloats(steps, rows)),
                    .velocity_column = @intCast(track.localVelocityColumn(bodies, root_body)),
                    .angular_column = @intCast(track.localAngularColumn(bodies, root_body)),
                    .decision_seconds = self.fleet.decisionSeconds(),
                    .gradient_at = layout.reserveDacts(rows * M.lat_root_gradient_numbers),
                    .position_weight = cost_weights.position,
                    .rotation_weight = cost_weights.rotation,
                    .drift_at = layout.reserveActs(Kit.ImaginedRoot.driftBlockFloats(steps, rows)),
                };
            }
            if (has_extras) {
                try self.buildExtras(options, &layout);
            }
            // The skip head's schedule: its record offsets in acts, a float each, beside everything else.
            const has_skip_head: bool = options.kitHeads().hasSkipHead();
            const skip_schedule_steps: u32 = if (has_skip_head) options.window / options.skip_steps else 0;
            if (skip_schedule_steps > 0) {
                self.skip_schedule_at = layout.reserveActs(skip_schedule_steps + 1);
            }
            // The policy's schedule likewise, when it steps through skips.
            const policy_steps: u32 = options.horizon();
            const has_policy_skips: bool = options.policy_skip_steps > 0;
            if (has_policy_skips) {
                self.policy_schedule_at = layout.reserveActs(policy_steps + 1);
            }
            self.world_window_records = options.window;
            self.policy_window_records = options.horizonDecisions();
            // The device's numbers for the log, after everything else the readback brings back - every learner keeps
            // them, extras or not (`kit_mod.DeviceStats`) - and after them the statistics' chunks' sums, which stay
            // on the device.
            const readback_reaches_the_layout: bool = self.readback_end == layout.params_floats;
            assertf(readback_reaches_the_layout, @src(), "the readback ends at {d}, the parameters at {d}", .{
                self.readback_end,
                layout.params_floats,
            });
            self.stats_at = layout.reserveParams(kit_mod.DeviceStats.reserved_floats);
            self.readback_end = self.stats_at + kit_mod.DeviceStats.floats;
            try layout.checkFitsKit(M);
            self.buffers_used = layout;
            if (skip_schedule_steps > 0) {
                self.skip_schedule = try self.gpa.alloc(u32, skip_schedule_steps);
                @memset(self.skip_schedule, options.skip_steps);
                try self.writeScheduleOffsets(self.skip_schedule, self.skip_schedule_at);
            }
            if (has_policy_skips) {
                self.policy_schedule = try self.gpa.alloc(u32, policy_steps);
                const fine_steps: u32 = policy_steps - options.policy_skip_steps;
                @memset(self.policy_schedule[0..fine_steps], 1);
                @memset(self.policy_schedule[fine_steps..], options.skip_steps);
                try self.writeScheduleOffsets(self.policy_schedule, self.policy_schedule_at);
            }
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
            // The judged weights the same way, and zeroed for the same reason.
            self.host.judged = try gpa.alloc(f32, self.kit.policy_count);
            errdefer gpa.free(self.host.judged);
            @memset(self.host.judged, 0.0);
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
            self.host.goal = try gpa.alloc(f32, self.kit.lead);
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
            const acting_goal_width: usize = self.host.goal.len;
            const acting_action_count: usize = self.host.raw.len;
            const acting_characters: usize = fleet.options.envs;
            const flow_numbers: usize = if (self.kit.flow_actor != null) self.flow_start_noise.len else 0;
            self.acting_noise_width = flow_numbers + acting_action_count;
            self.acting_z = try gpa.alloc(f32, acting_characters * acting_feature_count);
            self.acting_goal = try gpa.alloc(f32, acting_characters * acting_goal_width);
            self.acting_raw = try gpa.alloc(f32, acting_characters * acting_action_count);
            self.acting_noise = try gpa.alloc(f32, acting_characters * self.acting_noise_width);
            self.acting_planned = try gpa.alloc(?[]const f32, acting_characters);
            @memset(self.acting_planned, null);
            // One acting scratch per physics task: phase 2 is split as the fleet's physics is. Kept by the learner once
            // every one is made, so the late parts never free a scratch that was not.
            const scratches: []ActingScratch(M) = try gpa.alloc(ActingScratch(M), fleet.drive_scratches.len);
            var scratches_made: usize = 0;
            errdefer {
                for (scratches[0..scratches_made]) |*scratch| {
                    scratch.deinit(gpa);
                }
                gpa.free(scratches);
            }
            for (scratches) |*scratch| {
                scratch.* = try ActingScratch(M).init(gpa, self.host, fleet.m, flow_numbers);
                scratches_made += 1;
            }
            self.acting_scratches = scratches;
            return self;
        }

        /// MUON ON THE WORLD MODEL's HIDDEN-TO-HIDDEN MATRICES, each added to its clipped optimiser
        /// (`kit_mlp.ClippedAdam.addMuon`) and all sharing one set of working matrices (`kit_mlp.Muon.reserveSharing`):
        /// SuperMimic's MuonAdam takes every linear layer's weights but the first's and the last's - the first reads
        /// the inputs, the last writes the change, and neither is square. In the normed form, every hidden layer's
        /// after the first (two, of three hidden layers); in the dense form, its second layer's.
        fn placeWorldMuon(
            self: *Self,
            layout: *kit_mlp.KitLayout,
            settings: kit_mlp.MuonSettings,
        ) void {
            const side: u32 = self.kit.hidden;
            const optimizer: *kit_mlp.ClippedAdam = &self.kit.world_optimizer.?;
            const world: kit_mod.NormedWorld(M) = self.kit.normed_world orelse {
                const dense_muon: kit_mlp.Muon = .reserve(layout, self.kit.w2, side, settings);
                optimizer.addMuon(dense_muon);
                return;
            };
            const later_hidden_layers: []const kit_mlp.KitLayer = world.layers[1 .. world.layer_count - 1];
            if (later_hidden_layers.len == 0) {
                return;
            }
            for (later_hidden_layers) |layer| {
                const square: bool = layer.input_width == side and layer.output_width == side;
                assertf(square, @src(), "a hidden layer of {d} x {d}, Muon's side {d}", .{
                    layer.input_width,
                    layer.output_width,
                    side,
                });
            }
            const first_muon: kit_mlp.Muon = .reserve(layout, later_hidden_layers[0].weights_offset, side, settings);
            optimizer.addMuon(first_muon);
            for (later_hidden_layers[1..]) |layer| {
                optimizer.addMuon(first_muon.reserveSharing(layer.weights_offset));
            }
        }

        /// WHERE THE WORLD MODEL's STATISTICS ARE FOLDED (`placeChangeFolding`, `foldWorldStatistics`), in acts: each
        /// feature's floor, in its raw units (`WorldStatistics.floorOf`), written once; and the flags of a fold's
        /// records, [step][character], room for every record the ring holds - 1 where a record continues the one
        /// before it (`track.Replay.Books.continuesAt`) - with the host's copy they are filled in before each upload,
        /// owned by the learner's `gpa`.
        pub const ChangeFolding = struct {
            floors_at: u32,
            flags_at: u32,
            flags: []f32,
        };

        /// THE CHANGE IN UNITS OF ITS TYPICAL CHANGE, placed (`WorldStatistics`): in `layout`'s acts, the kit's
        /// statistics - the change's means and spreads (`LatentKit.increments_at`), then each feature's loss weight
        /// (`LatentKit.loss_weights_at`) - and the fold's floors and flags (`ChangeFolding`). The running moments they
        /// come from are saved parameters, placed with the world model's other running statistics
        /// (`placeWorldStatistics`). Memory: the floors' numbers with the learner's `gpa`, freed before it returns;
        /// the flags' host copy kept, freed with the learner.
        fn placeChangeFolding(
            self: *Self,
            layout: *kit_mlp.KitLayout,
            statistics: WorldStatistics,
        ) !void {
            const gpa: Allocator = self.gpa;
            const feature_count: u32 = self.kit.features;
            const body_count: u32 = @intCast(self.fleet.m.body_count);
            const features_are_local: bool = feature_count == rbt.localSize(body_count);
            assertf(features_are_local, @src(), "{d} features, {d} in the local layout of {d} bodies", .{
                feature_count,
                rbt.localSize(body_count),
                body_count,
            });
            self.kit.increments_at = layout.reserveActs(2 * feature_count);
            self.kit.loss_weights_at = layout.reserveActs(feature_count);
            self.kit.feature_kinds_at = layout.reserveActs(feature_count);
            const floors_at: u32 = layout.reserveActs(feature_count);
            const ring: kit_mod.RecordRing = self.data.ring;
            const flag_count: u32 = ring.capacity * ring.envs;
            const flags_at: u32 = layout.reserveActs(flag_count);
            const floors: []f32 = try gpa.alloc(f32, feature_count);
            defer gpa.free(floors);
            const local_layout: rbt.LocalLayout = .of(body_count);
            for (floors, 0..) |*floor, feature| {
                floor.* = statistics.floorOf(local_layout, @intCast(feature));
            }
            self.kit.pipe.uploadAt(.acts, floors_at, floors);
            // Each feature's kind, by which the world model's loss in its own units is logged.
            const kinds: []f32 = try gpa.alloc(f32, feature_count);
            defer gpa.free(kinds);
            kit_mod.writeFeatureKinds(local_layout, kinds);
            self.kit.pipe.uploadAt(.acts, self.kit.feature_kinds_at.?, kinds);
            const flags: []f32 = try gpa.alloc(f32, flag_count);
            @memset(flags, 0);
            self.change_folding = .{ .floors_at = floors_at, .flags_at = flags_at, .flags = flags };
        }

        /// THE WORLD MODEL's RUNNING STATISTICS, placed in `layout`'s parameters - inside the saved ones - and uploaded
        /// at their start (`zn_mlp.lat_world_moments`): the input columns' moments (`input_moments_at`), the affine
        /// the first layer reads from them (`LatentKit.inputs_affine_at`), and the change's moments
        /// (`change_moments_at`) - every moment a count of 0, a mean of 0 and a variance of 1, XMimic's start
        /// (`rn_init`), so the first round's transitions become the statistics. The affine and the kit's change
        /// statistics are written from the moments by a fold of no steps (`writeWorldStatistics`).
        ///
        /// The world model reads [state | the servo's encoded targets | the action], and in their own units the three
        /// differ by orders of magnitude: positions of a few centimetres from the root, velocities of metres a second,
        /// the targets' encodings (sines, cosines and the two axes of each joint's rotation) spread a few tenths, and
        /// the action - an offset of 0.6 radian a unit of the policy's output, explored at a tenth of a unit - a few
        /// hundredths. A first layer reading them as they are moves its output by an action a hundredth as much per
        /// step of its weights as by a velocity: it learns what an action does that much later. So each column is read
        /// as (raw - mean) / sqrt(var + 1e-2^2), by its running moments over the very transitions the model learns
        /// from - XMimic's `in_norm` over its whole input. Measured on the clips instead, a feature that hardly moves
        /// in the reference but swings in a fall (a spine's turn, floored at 1e-3) would be read at hundreds of its
        /// clip spreads.
        ///
        /// Memory: the starting numbers with the learner's `gpa`, freed before it returns.
        fn placeWorldStatistics(self: *Self, layout: *kit_mlp.KitLayout) !void {
            const gpa: Allocator = self.gpa;
            const feature_count: u32 = self.kit.features;
            const target_count: u32 = self.kit.references;
            const action_count: u32 = self.data.actions;
            const input_count: u32 = self.kit.inputs;
            const inputs_add_up: bool = feature_count + target_count + action_count == input_count;
            assertf(inputs_add_up, @src(), "the world model's {d} inputs: {d} features, {d} targets, {d} actions", .{
                input_count,
                feature_count,
                target_count,
                action_count,
            });
            const statistics_start: u32 = layout.params_floats;
            self.input_moments_at = layout.reserveParams(3 * input_count);
            self.kit.inputs_affine_at = layout.reserveParams(2 * input_count);
            self.change_moments_at = layout.reserveParams(3 * feature_count);
            self.world_statistics_count = layout.params_floats - statistics_start;
            const block: []f32 = try gpa.alloc(f32, self.world_statistics_count);
            defer gpa.free(block);
            @memset(block, 0);
            // Every moment: no count, mean 0, variance 1. The affine between them the fold writes.
            const input_variances: []f32 = block[self.input_moments_at - statistics_start + 2 * input_count ..];
            @memset(input_variances[0..input_count], 1);
            const change_variances: []f32 = block[self.change_moments_at - statistics_start + 2 * feature_count ..];
            @memset(change_variances[0..feature_count], 1);
            self.kit.pipe.uploadAt(.params, statistics_start, block);
            // No optimiser steps these numbers, but a state file saves Adam's moments for every saved parameter: zeros,
            // as the extras' start, whatever the buffers held before.
            @memset(block, 0);
            self.kit.pipe.uploadAt(.adam_m, statistics_start, block);
            self.kit.pipe.uploadAt(.adam_v, statistics_start, block);
        }

        /// ONE FOLD OF THE WORLD MODEL's STATISTICS (`zn_mlp.lat_world_moments`): `step_count` replay steps of the ring
        /// from slot `first_slot`, their flags already uploaded (`ChangeFolding`), then the inputs' affine and the
        /// kit's change statistics written from the moments.
        fn runWorldMoments(self: *Self, first_slot: u32, step_count: u32) void {
            const folding: ChangeFolding = self.change_folding.?;
            const statistics: WorldStatistics = self.options.world_statistics;
            const ring: kit_mod.RecordRing = self.data.ring;
            self.kit.pipe.params = .{
                .x_off = self.input_moments_at,
                .w_off = self.change_moments_at,
                .y_off = self.kit.inputs_affine_at.?,
                .z_off = self.kit.increments_at.?,
                .l_off = self.kit.loss_weights_at.?,
                .u_off = folding.floors_at,
                .t_off = folding.flags_at,
                .norm_off = self.data.norm_at,
                .table_off = self.data.table_at,
                .lat_features = self.data.features,
                .lat_references = self.data.references,
                .lat_actions = self.data.actions,
                .lat_envs = ring.envs,
                .lat_capacity = ring.capacity,
                .ring_off = ring.at,
                .lat_steps = step_count,
                .lat_first_slot = first_slot,
                .lat_norm_epsilon = statistics.inputs_epsilon,
                .lat_change_epsilon = statistics.change_epsilon,
                .lat_moments_limit = statistics.moments_limit,
            };
            const threads: u32 = self.kit.inputs + self.data.features;
            self.kit.pipe.run("lat_world_moments", threads);
        }

        /// THE WORLD MODEL's STATISTICS WRITTEN FROM THE MOMENTS AS THEY STAND - the inputs' affine and the kit's
        /// change statistics: a fold of no records, at a start and on a resume, so the model never reads statistics
        /// its moments do not give.
        fn writeWorldStatistics(self: *Self) void {
            const no_step: u32 = 0;
            self.runWorldMoments(0, no_step);
        }

        /// THE WORLD MODEL's STATISTICS GIVEN THE NEWEST TRANSITIONS (`zn_mlp.lat_world_moments`): every record the
        /// ring has received since the last fold - everything it holds from its second record on, at this start's
        /// first - each flagged where it continues the record before it (`track.Replay.Books.continuesAt`), and every
        /// flagged transition folded into the input columns' moments and the change's, the inputs' affine and the
        /// kit's change statistics written from them. Recorded with the round's training, after the gate's
        /// measurement and before the world model's updates: the gate measures the model as the last round left it,
        /// and every update of this round reads and predicts in units measured on every transition collected so far.
        pub fn foldWorldStatistics(self: *Self) void {
            const folding: ChangeFolding = self.change_folding.?;
            const ring: kit_mod.RecordRing = self.data.ring;
            const held: kit_mod.RecordRing.HeldSteps = ring.held() orelse return;
            // A transition ends at a record whose record before the ring still holds: from the second on.
            const first_with_record_before: u64 = held.first + 1;
            const folded_through: ?u64 = self.statistics_folded_through;
            const first_unfolded: u64 = if (folded_through) |folded| folded + 1 else first_with_record_before;
            const first_index: u64 = @max(first_unfolded, first_with_record_before);
            if (first_index > held.last) {
                return;
            }
            const step_count: u32 = @intCast(held.last + 1 - first_index);
            const books: track.Replay.Books = self.windowBooks();
            const flags: []f32 = folding.flags[0 .. step_count * ring.envs];
            for (0..step_count) |step| {
                const index: u64 = first_index + step;
                const step_flags: []f32 = flags[step * ring.envs ..][0..ring.envs];
                for (step_flags, 0..) |*flag, env| {
                    const continues: bool = books.continuesAt(env, index);
                    flag.* = if (continues) 1 else 0;
                }
            }
            self.kit.pipe.uploadAt(.acts, folding.flags_at, flags);
            const first_slot: u32 = @intCast(first_index % ring.capacity);
            self.runWorldMoments(first_slot, step_count);
            self.statistics_folded_through = held.last;
        }

        /// Both networks' starting weights, and a clean optimiser: each network begins as the identity of its job -
        /// the world model predicting "nothing changes", the policy "no correction", which is the servo alone.
        /// Without this the weights would be whatever the buffer held; all zeros, and no gradient could ever break
        /// their symmetry.
        ///
        /// SuperTrack's world model and the policy layer by layer, each as (how many weights, its fan-in, whether it is
        /// a hidden layer), in the packed order the kit reads them. Fan-in 0 marks a BIAS - zeroed, as biases should
        /// start. A hidden layer gets Xavier's 1/sqrt(fan-in), which keeps a tanh layer's outputs in its useful range
        /// instead of saturated; an output layer gets a hundredth of that. Last, the policy's block for the action
        /// applied before its decision, at ZERO like a bias: the policy starts out as the one that cannot see it.
        ///
        /// A world model in the normed form starts as its zimrnum network does (`NormedWorld.mlpSpec`): the hidden
        /// layers as PyTorch starts a linear layer, uniform within 1/sqrt(fan-in), each norm's gain 1 and bias 0, and
        /// the last layer exactly zero. Memory: the network's tensors in an arena on the learner's `gpa`, freed here.
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
            const world_weights: []f32 = weights[0..kit.param_count];
            if (kit.normed_world) |*world| {
                var network_arena: ArenaAllocator = .init(self.gpa);
                defer network_arena.deinit();
                var hidden_widths: [kit_mod.NormedWorld(M).max_layers]usize = undefined;
                const spec: zn.Mlp(f32).Spec = world.mlpSpec(&hidden_widths);
                const network_seed: u32 = random.int(u32); // lint:off redundant-cast: std.Random's draw, not zm.int
                const network: zn.Mlp(f32) = try .init(network_arena.allocator(), zn.Rng.init(network_seed), spec);
                world.writeParams(network, world_weights);
            } else {
                // The skip head, when there is one, an output layer after the one-step head's, started as it is.
                const dense_world_layers = [_][3]usize{
                    .{ (f + r + a) * h, f + r + a, 1 }, .{ h, 0, 0 },
                    .{ h * h, h, 1 },                   .{ h, 0, 0 },
                    .{ h * f, h, 0 },                   .{ f, 0, 0 },
                    .{ h * f, h, 0 },                   .{ f, 0, 0 },
                };
                const layer_count: usize = if (kit.heads.hasSkipHead()) 8 else 6;
                const filled: usize = fillLayers(world_weights, dense_world_layers[0..layer_count], random);
                assertf(filled == world_weights.len, @src(), "seedWeights: filled {d} of the world model's {d}", .{
                    filled,
                    world_weights.len,
                });
            }
            // The policy reads [goal | state]: the goal's features and the root target's slots, then the state.
            const policy_inputs: usize = self.host.goal.len + f;
            const policy_layers = [_][3]usize{
                .{ policy_inputs * hp, policy_inputs, 1 }, .{ hp, 0, 0 },
                .{ hp * hp, hp, 1 },                       .{ hp, 0, 0 },
                .{ hp * a, hp, 0 },                        .{ a, 0, 0 },
                .{ a * hp, 0, 0 },
            };
            const policy_weights: []f32 = weights[kit.param_count..];
            const policy_filled: usize = fillLayers(policy_weights, &policy_layers, random);
            assertf(policy_filled == policy_weights.len, @src(), "seedWeights: filled {d} of the policy's {d}", .{
                policy_filled,
                policy_weights.len,
            });
            kit.pipe.upload(.params, weights);
            // The world model's slow average starts as the world model itself.
            if (self.world_average_count > 0) {
                kit.pipe.uploadAt(.params, self.world_average_at, world_weights);
            }
            // The policy's slow average starts as the policy itself.
            const average_count: usize = self.policy_average_count;
            if (average_count > 0) {
                kit.pipe.uploadAt(.params, self.policy_average_at, policy_weights);
            }
            @memset(weights, 0.0);
            kit.pipe.upload(.adam_m, weights);
            kit.pipe.upload(.adam_v, weights);
            // Its moments too, which no optimiser steps: zero, so a state file holds no number the learner never
            // wrote.
            if (average_count > 0) {
                kit.pipe.uploadAt(.adam_m, self.policy_average_at, weights[0..average_count]);
                kit.pipe.uploadAt(.adam_v, self.policy_average_at, weights[0..average_count]);
            }
            // The world model's slow average likewise: the starting world model, its moments zero.
            const world_average_count: usize = self.world_average_count;
            if (world_average_count > 0) {
                kit.pipe.uploadAt(.adam_m, self.world_average_at, weights[0..world_average_count]);
                kit.pipe.uploadAt(.adam_v, self.world_average_at, weights[0..world_average_count]);
            }
        }

        /// `seedWeights`' layers into `weights`, from its start: each (count, fan-in, hidden) a normal draw of
        /// 1/sqrt(fan-in) - a hundredth of it for an output layer, nothing for a bias. Returns how many it filled.
        fn fillLayers(weights: []f32, layers: []const [3]usize, random: Random) usize {
            var at: usize = 0;
            for (layers) |layer| {
                const count: usize = layer[0];
                const fan: usize = layer[1];
                const is_hidden: bool = layer[2] == 1;
                const scale: f32 = if (is_hidden) 1.0 else 0.01;
                const deviation: f32 = if (fan == 0) 0.0 else @sqrt(1.0 / float(fan)) * scale;
                for (weights[at..][0..count]) |*w| {
                    w.* = deviation * random.floatNorm(f32);
                }
                at += count;
            }
            return at;
        }

        /// THE LATE PARTS (`init`): what `init` allocates after its first steps without an errdefer of its own - the
        /// planning flags and their rows, the extras (the critic's arena, the flow's rows, the teachers', the
        /// planner's), the schedules and the acting rows. Each is an empty slice or null until it is allocated, so
        /// this frees what there is at any point of `init` - which an error there calls - and `deinit` with the rest.
        fn freeLateParts(self: *Self) void {
            const gpa: Allocator = self.gpa;
            gpa.free(self.skip_schedule);
            gpa.free(self.policy_schedule);
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
            if (self.change_folding) |folding| {
                gpa.free(folding.flags);
            }
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.clip_frame_counts);
            if (self.candidate_recording) |recording| {
                self.gpa.free(recording.favoured);
                self.gpa.free(recording.planners_recorded);
            }
            if (self.device_acting) |acting| {
                acting.books.deinit(self.gpa);
                self.gpa.free(acting.model_table);
                if (acting.flow_examples) |examples| {
                    self.gpa.free(examples.table);
                    self.gpa.free(examples.batch_table);
                    self.gpa.free(examples.mode_table);
                    self.gpa.free(examples.slot_character);
                    self.gpa.free(examples.slot_record);
                    self.gpa.free(examples.slot_good);
                    self.gpa.free(examples.good_slots);
                }
            }
            const gpa: Allocator = self.gpa;
            gpa.free(self.exposure_by_clip);
            gpa.free(self.failures_by_clip);
            self.freeLateParts();
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
            gpa.free(self.host.judged);
            gpa.free(self.norm.spread);
            gpa.free(self.norm.mean);
            self.data.deinit();
            gpa.destroy(self);
        }

        /// The policy's weights as the CPU sees them from here on. On a GPU the readback is a frame or
        /// so old, which is why acting can use it at all: waiting for a fresh one would stall the
        /// simulation every step.
        /// The judged weights (`HostPolicy.judged`) from a readback `params` whose live policy weights `weights` were
        /// just taken: the slow average's range when the learner keeps one, else `weights`.
        fn syncJudged(self: *Self, params: []const f32, weights: []const f32) void {
            const count: u32 = self.policy_average_count;
            if (count == 0) {
                @memcpy(self.host.judged, weights);
                return;
            }
            const average: []const f32 = params[self.policy_average_at..][0..count];
            for (average) |w| {
                if (!(w == w and @abs(w) < 1.0e30)) {
                    self.mirror_rejected += 1;
                    return;
                }
            }
            @memcpy(self.host.judged, average);
        }

        pub fn syncMirror(self: *Self) void {
            // No readback yet (nothing has come back from the device), or one too narrow to reach the
            // policy's weights: keep the mirror as it is rather than copy half a policy. `init` widens
            // the readback so this cannot be the steady state - it is the first frame or two, when the
            // mirror still holds the weights the driver seeded.
            const params: []const f32 = self.kit.pipe.readLatest(.params) orelse return;
            if (params.len < self.params_end) {
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
            // The judged weights: the slow average where there is one - all finite, or none - else the live ones.
            self.syncJudged(params, weights);
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
            // Planning on the CPU fleet chooses its characters by the hazard: it must be measurable.
            assertf(self.measuresHazard(), @src(), "planning measures danger by the head's height against the " ++
                "barrier's margins: the task needs a head body, and margins above zero", .{});
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
            const root_target: bool = self.options.root_target;
            const feature_scratch: FeatureScratch = scratch.featureScratch();
            supertrackFeaturesInto(self.fleet, env, self.norm, root_target, feature_scratch, host.goal, host.z);
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
            const goal_width: usize = host.goal.len;
            const action_count: usize = host.raw.len;
            @memcpy(self.acting_z[env * feature_count ..][0..feature_count], host.z);
            @memcpy(self.acting_goal[env * goal_width ..][0..goal_width], host.goal);
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
            const goal_width: usize = self.host.goal.len;
            const action_count: usize = self.host.raw.len;
            @memcpy(self.host.z, self.acting_z[env * feature_count ..][0..feature_count]);
            @memcpy(self.host.goal, self.acting_goal[env * goal_width ..][0..goal_width]);
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

        /// A PHASE OF A TRAINING ROUND ENTERED (`rbt.RoundPhase`), for the round's time: the kit's dispatches from
        /// here on are timed under it, where its pipe is timed (`Compute.setPhase`), and the host's clock, where a
        /// trainer attached one (`phase_clock`), counts the host's time under it.
        pub fn enterPhase(self: *Self, phase: rbt.RoundPhase) void {
            self.kit.pipe.setPhase(@backingInt(phase));
            if (self.phase_clock) |clock| {
                clock.enter(wgpu.nowMs(), phase);
            }
        }

        /// `steps` simulation steps with the policy acting - its raw output plus exploration noise,
        /// which the fleet scales into a pose offset - every one recorded into the ring.
        ///
        /// A ROUND's TIME: the acting is the `acting` phase, the CPU fleet's step inside it the `physics` - with the
        /// judgement and the resets a fleet's step holds - and a planning decision the `planner`.
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
            defer self.enterPhase(.other);
            self.enterPhase(.acting);
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
                // The CPU fleet's step is the round's physics, with the judgement and the resets it holds.
                self.enterPhase(.physics);
                _ = self.fleet.step(self.actions);
                self.enterPhase(.acting);
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
                            self.enterPhase(.planner);
                            self.planDecision(plan_age);
                            self.enterPhase(.acting);
                        }
                    }
                }
                // Each character's decision counted (`countDecision`): the clip it was on - the one its episode
                // ended on, when it just ended (`terminal_clip`, kept before the restart chose the next), and
                // otherwise the one it is still on.
                const fleet: *track.Fleet = self.fleet;
                const judged: bool = noise_scale == 0.0;
                for (fleet.failures, fleet.dones, fleet.in_aftermath, 0..) |lost, ended, after_loss, env| {
                    const clip: usize = if (ended) fleet.terminal_clip[env] else fleet.clip_of[env];
                    self.countDecision(clip, lost, after_loss, judged);
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
            // Its real fit reads the world model's gathered windows (`trainWorld`), which hold the world model's own
            // steps (`world_window_records`), not the policy's horizon: so many steps, and no further.
            const source: kit_mod.LatentCritic(M).Source = .{
                .features = kit.features,
                .rows = kit.rows,
                .steps = kit.world_steps,
                .states_at = kit.blockT(1),
                .goals_at = kit.blockG(1),
                .norm_at = self.data.norm_at,
                .barrier = kit.barrier,
                .barrier_head_column = kit.barrier_head_column,
                .cost_cap = kit.cost_cap,
                .barrier_up_column = kit.barrier_up_column,
            };
            // The extras' parameters start after the networks' - their slow averages among them - and the world model's
            // running statistics (`placeWorldStatistics`): their counts and their starting upload from there.
            const extras_params_start: u32 = self.input_moments_at + self.world_statistics_count;
            // The layout `init` began - after the kit, its data and the policy's optimiser - continued here.
            const critic_arena: Allocator = self.critic_arena.allocator();
            if (options.train_critic) {
                var critic: kit_mod.LatentCritic(M) = try .init(critic_arena, layout, source, options.critic);
                // The imagined fit reads the policy rollout's states, in the kit's blocks from step 1.
                if (options.critic.imagined_share > 0) {
                    critic.reserveImagined(kit.blockZ(1));
                }
                // The value tail at the policy rollout's end, when the policy's loss carries one.
                if (options.value_tail > 0) {
                    var value_tail: kit_mod.LatentCritic(M).Tail = try critic.initTail(critic_arena, layout, kit.rows);
                    value_tail.pessimism = options.value_tail_pessimism;
                    self.kit.value_tail = value_tail;
                }
                self.critic = critic;
            }
            self.critic_parameter_count = layout.params_floats - extras_params_start;
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
                // Its encoding is the dense world model's second hidden layer (`SkipModel`).
                if (options.world_form != .dense_tanh) {
                    return error.SkipHeadWithoutDenseWorld;
                }
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
            const extra_params: []const f32 = params[extras_params_start..];
            kit.pipe.uploadAt(.params, extras_params_start, extra_params);
            const zero_moments: []f32 = try critic_arena.alloc(f32, extra_params.len);
            @memset(zero_moments, 0);
            kit.pipe.uploadAt(.adam_m, extras_params_start, zero_moments);
            kit.pipe.uploadAt(.adam_v, extras_params_start, zero_moments);
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
                .skip_steps = planning.skip_steps,
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
            // Its rollouts act with the flow's base (`baseKit`): its plans are offsets around the same policy as the
            // physics' plans and the flow.
            const base_kit: Kit = self.baseKit();
            const planner: kit_mod.TrackingPlanner(M) =
                try .init(arena, layout, base_kit, self.critic, flow_actor, scorer_options, search_options);
            self.planner = planner;
            self.mailbox_at = layout.reserveParams(planner.mailboxFloats());
            self.slot_owners = try gpa.alloc(?usize, slot_count);
            @memset(self.slot_owners, null);
            const slot_input_floats: u32 =
                kit_mod.TrackingPlanner(M).stateInputFloats(self.kit.features, planner.imaginesRoot());
            self.slot_inputs = try gpa.alloc(f32, slot_input_floats);
            self.slot_warm_flags = try gpa.alloc(f32, slot_count);
            self.slot_owner_since = try gpa.alloc(u32, slot_count);
            @memset(self.slot_owner_since, 0);
            self.mailbox_copy = try gpa.alloc(f32, planner.mailboxFloats());
            @memset(self.mailbox_copy, 0);
            // Teacher 2's examples, when the flow acts and so can learn them.
            if (self.kit.flow_actor != null) {
                const condition_width: usize = self.kit.lead + self.kit.features;
                const example_width: usize = condition_width + self.kit.actions;
                self.distillation_examples = try gpa.alloc(f32, planning.distill_examples * example_width);
                self.distillation_batch_conditions = try gpa.alloc(f32, planning.distill_rows * condition_width);
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
            const goal_width: usize = self.kit.lead;
            const condition_width: usize = goal_width + feature_count;
            const action_width: usize = self.kit.actions;
            const example_width: usize = condition_width + action_width;
            const capacity: usize = self.distillation_examples.len / example_width;
            const example_start: usize = self.distillation_next * example_width;
            const example: []f32 = self.distillation_examples[example_start..][0..example_width];
            @memcpy(example[0..goal_width], self.host.goal);
            @memcpy(example[goal_width..][0..feature_count], self.host.z);
            @memcpy(example[condition_width..][0..action_width], planned_correction);
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

        /// Where each part of teacher 3's examples lies (`FlowActor.Fpo.Columns`), for this learner's goals, states and
        /// coefficients.
        fn fpoColumns(self: *const Self) kit_mod.FlowActor(M).Fpo.Columns {
            const synergy_count: u32 = @intCast(self.host.flow_coefficients.len);
            return .of(self.kit.lead, self.kit.features, synergy_count);
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
            const goal_width: usize = self.host.goal.len;
            const feature_count: usize = self.host.z.len;
            const synergy_count: usize = self.host.flow_coefficients.len;
            const columns: kit_mod.FlowActor(M).Fpo.Columns = self.fpoColumns();
            const pending: []f32 = self.fpo_pending[env * columns.next_state ..][0..columns.next_state];
            const own_goal: []const f32 = self.fpo_own_goals[env * goal_width ..][0..goal_width];
            @memcpy(pending[columns.own_goal..][0..goal_width], own_goal);
            @memcpy(pending[columns.goal..][0..goal_width], self.host.goal);
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
            const goal_width: usize = self.host.goal.len;
            @memcpy(self.fpo_own_goals[env * goal_width ..][0..goal_width], self.host.goal);
            self.fpo_own_goal_valid[env] = true;
        }

        /// Completes character `env`'s pending example, if it has one, with the state it is in now - whatever `z`
        /// holds, the step after - into teacher 3's ring, which overwrites its oldest once full.
        fn completeFpoExample(self: *Self, env: usize) void {
            if (self.fpo_examples.len == 0 or !self.fpo_pending_valid[env]) {
                return;
            }
            const feature_count: usize = self.host.z.len;
            const columns: kit_mod.FlowActor(M).Fpo.Columns = self.fpoColumns();
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
            // On the device, the planners' examples are drawn there.
            const device_examples: ?FlowExamples = if (self.device_acting) |acting| acting.flow_examples else null;
            if (device_examples) |examples| {
                self.drawFlowBatchOnDevice(examples, distillation);
                return;
            }
            distillation.has_batch = self.distillation_example_count > 0;
            if (!distillation.has_batch) {
                return;
            }
            const random: Random = self.rng.random();
            const action_width: usize = self.kit.actions;
            const condition_width: usize = self.kit.lead + self.kit.features;
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

        /// THE MODEL PLANNER's CHARACTERS ON THE DEVICE, from the next decision on: `characters`, acting rows - one a
        /// state of the planner, as many as it has - chosen by trouble at a replan (`robotgpu_host.Sim
        /// .chooseModelCharacters`). A state that keeps its character keeps planning warm from its last plan; one
        /// that changes starts cold.
        pub fn chooseModelCharacters(self: *Self, characters: []const u32) void {
            const acting: *DeviceActing = &self.device_acting.?;
            assertf(characters.len == self.slot_owners.len, @src(), "{d} characters for {d} planner states", .{
                characters.len,
                self.slot_owners.len,
            });
            for (self.slot_owners, self.slot_warm_flags, characters) |*owner, *warm_flag, character| {
                const keeps_its_character: bool = if (owner.*) |held| held == character else false;
                if (!keeps_its_character) {
                    warm_flag.* = 0;
                }
                owner.* = character;
            }
            acting.model_characters_chosen = true;
        }

        /// THE MODEL PLANNER's DECISION ON THE DEVICE, numbered `decision_number` (`TrackingPlanner.RowsDecision`): its
        /// states'
        /// table - each state's acting row, its clip's row of the frame it tracks next (`clips`, `frames`: each
        /// state's character's, as the simulator holds them; the frame held at the clip's last) and its clip's last
        /// row - and its warm flags uploaded, the flags then warm for the decision after; the decision's seed from the
        /// run's on a stream of the planner's own. Null without a planner, or before its characters are chosen.
        pub fn modelPlanningAt(
            self: *Self,
            decision_number: u32,
            clips: []const u32,
            frames: []const u32,
        ) ?kit_mod.TrackingPlanner(M).RowsDecision {
            const planner: kit_mod.TrackingPlanner(M) = self.planner orelse return null;
            const acting: *DeviceActing = &(self.device_acting orelse return null);
            if (!acting.model_characters_chosen) {
                return null;
            }
            for (self.slot_owners, clips, frames, 0..) |owner, clip, frame, state| {
                const last_frame: u32 = @intCast(self.fleet.clips[clip].frame_count - 1);
                const clip_first_row: u32 = self.data.clip_rows[clip];
                const row_entry: []f32 = acting.model_table[3 * state ..][0..3];
                row_entry[0] = float(owner.?);
                row_entry[1] = float(clip_first_row + @min(frame, last_frame));
                row_entry[2] = float(clip_first_row + last_frame);
            }
            const pipe: *compute_host.Compute(M) = self.kit.pipe;
            pipe.uploadAt(.acts, acting.model_table_at, acting.model_table);
            pipe.uploadAt(.acts, planner.mppi.warm_flags_offset, self.slot_warm_flags);
            @memset(self.slot_warm_flags, 1);
            const model_stream: u32 = 0x7A_11;
            const run_seed: u32 = @truncate(self.options.seed ^ (self.options.seed >> 32));
            const stream_seed: u32 = M.latStepSeed(run_seed, model_stream);
            // A decision for every state at once; each one a character's decision in the log's count.
            self.decisions_made += 1;
            self.planning_decisions += self.slot_owners.len;
            const model: kit_mod.TrackingPlanner(M).RowsDecision = .{
                .planner = planner,
                .table_at = acting.model_table_at,
                .reference_table_at = self.data.table_at,
                .normaliser_at = self.data.norm_at,
                .seed = M.latStepSeed(stream_seed, decision_number),
                .mailbox_at = self.mailbox_at,
                .decision_number = decision_number,
            };
            return model;
        }

        /// THE MODEL PLANNER's LAST PLANS, read back from its mailbox (`TrackingPlanner.writeMailbox`): every state's
        /// chosen plan, [state][step][action], into `out_plans` - the states' characters those of `slot_owners` at
        /// the decision that wrote them. The host waits for the device. Memory: scratch from `gpa`, freed before the
        /// return.
        pub fn readModelPlans(self: *Self, gpa: Allocator, out_plans: []f32) !void {
            const planner: kit_mod.TrackingPlanner(M) = self.planner.?;
            const plan_floats: u32 = planner.mailboxPlanFloats();
            assertf(out_plans.len == plan_floats, @src(), "{d} numbers for the mailbox's {d}", .{
                out_plans.len,
                plan_floats,
            });
            // The mailbox's first number is the decision's stamp; the plans follow it.
            const plans_at: u32 = self.mailbox_at + 1;
            var plans_read: compute_host.Compute(M).RangeRequest(.params) =
                try self.kit.pipe.requestRange(gpa, .params, plans_at, plan_floats);
            while (!plans_read.collect(out_plans)) {
                std.atomic.spinLoopHint();
            }
        }

        /// A NETWORK OF THE LEARNER, by its weights in the parameters (`networkParameters`): the world model and the
        /// policy - the kit's - then what `buildExtras` places after the policy's and the world model's averages: the
        /// critic's heads and the flow. (The averages are no networks of their own: they follow the live weights.)
        pub const Network = enum {
            world_model,
            policy,
            critic,
            flow,

            /// Its name as a person reads it - in a tripwire's words (`lab.TripwireFired`).
            pub fn label(network: Network) []const u8 {
                return switch (network) {
                    .world_model => "the world model",
                    .policy => "the policy",
                    .critic => "the critic",
                    .flow => "the flow",
                };
            }
        };

        /// Where a network's weights lie in the parameters: its first number and how many.
        pub const ParameterRange = struct {
            first: u32,
            count: u32,
        };

        /// Where network `network`'s weights lie in [0, `params_end`) - null for a network this learner does not
        /// have. The order is `buildExtras`'s: the world model from 0, the policy at the kit's `p_at`, its average and
        /// the world model's after it, then the critic's heads (and their targets) and the flow's network.
        pub fn networkParameters(self: *const Self, network: Network) ?ParameterRange {
            const extras_first: u32 = self.world_average_at + self.world_average_count;
            const flow_first: u32 = extras_first + self.critic_parameter_count;
            const range: ParameterRange = switch (network) {
                .world_model => .{ .first = 0, .count = self.kit.p_at },
                .policy => .{ .first = self.kit.p_at, .count = self.kit.policy_count },
                .critic => .{ .first = extras_first, .count = self.critic_parameter_count },
                .flow => .{ .first = flow_first, .count = self.flow_parameter_count },
            };
            if (range.count == 0) {
                return null;
            }
            return range;
        }

        /// How many of teacher 2's examples the learner learns from now: the device ring's good ones - their
        /// stretches ended well (`FlowExamples.goodSlots`) - where the planners are the device's, else the CPU's.
        pub fn distillationExamples(self: *const Self) u64 {
            const device_examples: ?FlowExamples = if (self.device_acting) |acting| acting.flow_examples else null;
            if (device_examples) |examples| {
                return examples.goodSlots().len;
            }
            return self.distillation_example_count;
        }

        /// ONE STEP INTO THE DEVICE ACTING's BOOKS (`track.KeptBooks.appendStep`), one moment a character - and the
        /// labels it settled into the books marking teacher 2's examples of their records good (`FlowExamples
        /// .markKept`): the stretches that ended well are the ones the flow learns from.
        pub fn appendBooksStep(self: *Self, moments: []const rbt.RecordMoment) void {
            const acting: *DeviceActing = &self.device_acting.?;
            const labels: *const track.LabelBooks = &acting.books.labels;
            const kept_before: u64 = labels.labels_kept;
            acting.books.appendStep(moments);
            const examples: FlowExamples = acting.flow_examples orelse return;
            // The labels this step kept are the last of the kept, in the order they were settled.
            const newly_kept: usize = @intCast(labels.labels_kept - kept_before);
            const kept_end: usize = labels.kept_count;
            const settled_now: []const track.Label = labels.kept[kept_end - newly_kept .. kept_end];
            examples.markKept(settled_now);
        }

        /// Teacher 2's round's batch from the device's ring (`FlowExamples`): `distill_rows` slots drawn with
        /// replacement among the good ones - their stretches ended well - gathered on the device
        /// (`zn_mlp.gather_flow_batch`): their conditions into the distillation's, their applied actions and choices
        /// into the batch's own rows. None before a planner's stretch has ended well. The flow's targets are taken
        /// from them before each update (`retargetFlowBatch`).
        pub fn drawFlowBatchOnDevice(
            self: *Self,
            examples: FlowExamples,
            distillation: *kit_mod.FlowActor(M).Distillation,
        ) void {
            const good_slots: []const u32 = examples.goodSlots();
            distillation.has_batch = good_slots.len > 0;
            if (!distillation.has_batch) {
                return;
            }
            const random: Random = self.rng.random();
            for (examples.batch_table) |*slot| {
                slot.* = float(good_slots[random.uintLessThan(usize, good_slots.len)]);
            }
            self.kit.pipe.uploadAt(.acts, examples.batch_table_at, examples.batch_table);
            const condition_width: u32 = self.kit.lead + self.kit.features;
            const action_width: u32 = self.kit.actions;
            const batch_rows: u32 = distillation.trainer.rows;
            self.kit.pipe.params = .{
                .rows = batch_rows,
                .in_dim = condition_width,
                .out_dim = action_width,
                .x_off = examples.ring_at,
                .y_off = distillation.conditions_at,
                .v_off = examples.batch_applied_at,
                .z_off = examples.batch_choices_at,
                .t_off = examples.batch_table_at,
            };
            self.kit.pipe.run("gather_flow_batch", batch_rows * (condition_width + 2 * action_width));
        }

        /// THE KIT THE BASE ACTS THROUGH (`kit_mod.FlowBase`): the kit itself, or - when the flow's base is the
        /// policy's slow average, and the learner keeps one - the kit reading the average's weights
        /// (`Kit.withPolicyWeightsAt`). Every forward pass of the policy that the flow corrects or a plan offsets goes
        /// through it: the characters' acting, the lookahead's candidates, the model planner's rollouts, teacher 2's
        /// targets. Never for an update.
        pub fn baseKit(self: *const Self) Kit {
            const on_average: bool = self.options.flow.base == .policy_average and self.policy_average_count > 0;
            if (!on_average) {
                return self.kit;
            }
            return self.kit.withPolicyWeightsAt(self.policy_average_at);
        }

        /// The rows the policy answers teacher 2's batch on (`FlowExamples`): the distillation's conditions as their
        /// inputs - [goal | state], packed - the batch's applied actions, and the batch's own hidden layers and
        /// answers.
        fn batchPolicyRows(
            self: *const Self,
            examples: FlowExamples,
            distillation: kit_mod.FlowActor(M).Distillation,
        ) Kit.PolicyRows {
            const condition_width: u32 = self.kit.lead + self.kit.features;
            return .{
                .rows = distillation.trainer.rows,
                .input_stride = condition_width,
                .raw_stride = self.kit.actions,
                .inputs_at = distillation.conditions_at,
                .hidden1_at = examples.batch_hidden1_at,
                .hidden2_at = examples.batch_hidden2_at,
                .raw_at = examples.batch_answers_at,
                .applied_at = examples.batch_applied_at,
            };
        }

        /// TEACHER 2's TARGETS, TAKEN NOW (`FlowExamples`): before a policy update, the flow's base (`baseKit`) - the
        /// policy the flow corrects - answers the batch's rows (`Kit.actOnRows`), and each row's target is its choice
        /// less that answer, in the flow's coefficients (`zn_mlp.synergy_project_difference`), into the distillation
        /// trainer's actions. Nothing without a device's batch.
        pub fn retargetFlowBatch(self: *Self) void {
            const acting: DeviceActing = self.device_acting orelse return;
            const examples: FlowExamples = acting.flow_examples orelse return;
            const flow_actor: kit_mod.FlowActor(M) = self.kit.flow_actor orelse return;
            const learning: kit_mod.FlowActor(M).Learning = flow_actor.learningPart();
            const distillation: kit_mod.FlowActor(M).Distillation = learning.distillation orelse return;
            if (!distillation.has_batch) {
                return;
            }
            const correction: kit_mod.FlowActor(M).Correction = flow_actor.correction;
            assertf(correction.action_width == self.kit.actions, @src(), "a flow over {d} actions, a policy of {d}", .{
                correction.action_width,
                self.kit.actions,
            });
            // The policy's answers, then the choices less them in the flow's coefficients.
            const policy_rows: Kit.PolicyRows = self.batchPolicyRows(examples, distillation);
            const base_kit: Kit = self.baseKit();
            base_kit.actOnRows(policy_rows);
            const batch_rows: u32 = policy_rows.rows;
            self.kit.pipe.params = .{
                .rows = batch_rows,
                .count = correction.synergy_count,
                .out_dim = correction.action_width,
                .x_off = examples.batch_choices_at,
                .z_off = examples.batch_answers_at,
                .w_off = correction.synergies_at,
                .y_off = distillation.trainer.actions_at,
            };
            self.kit.pipe.run("synergy_project_difference", batch_rows * correction.synergy_count);
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
                // With the root imagined, its root target as the policy reads it: the goal's slots.
                if (planner.imaginesRoot()) {
                    const root_target: []const f32 = self.host.goal[feature_count..][0..rbt.root_target_size];
                    @memcpy(self.slot_inputs[feature_count + 2 ..][0..rbt.root_target_size], root_target);
                }
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
                self.kit.features,
                action_width,
                synergy_count,
                flow_noise_scale,
                self.kit.rows,
                self.kit.steps,
                .{ .euler_steps = settings.euler_steps, .time_frequencies = settings.time_frequencies },
                .{
                    .share_teachers = settings.share_teachers,
                    .flow_dpg = settings.flow_dpg,
                    .dpg_share = settings.dpg_share,
                    .step_share = settings.step_share,
                    .anchor = settings.anchor,
                    .learning_rate = settings.learning_rate,
                    .gradient_clip = settings.gradient_clip,
                },
                // Teacher 2's batch: the planners' answers - the CPU's search when the learner plans, the device's
                // physics planners when it has phases (their plans around the policy, from phase 2).
                if (options.planning.enabled or options.phases.enabled) options.planning.distill_rows else 0,
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
                const goal_width: u32 = self.kit.lead;
                const columns: kit_mod.FlowActor(M).Fpo.Columns = .of(goal_width, self.kit.features, synergy_count);
                self.fpo_examples = try gpa.alloc(f32, settings.fpo_examples * columns.width);
                self.fpo_pending = try gpa.alloc(f32, character_count * columns.next_state);
                self.fpo_pending_valid = try gpa.alloc(bool, character_count);
                @memset(self.fpo_pending_valid, false);
                self.fpo_batch = try gpa.alloc(f32, settings.fpo_rows * columns.width);
                self.fpo_own_goals = try gpa.alloc(f32, character_count * goal_width);
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

        /// WHETHER THE WORLD MODEL IS MEASURED FOR ITS GATE THIS ROUND (`Gate`): with phases and a candidates'
        /// recording, at the first round that can, then once `Gate.measure_every_minutes` of training have passed since
        /// the latest measurement made - and never while the latest's numbers are still awaited from the readback, so
        /// each measurement is judged on its own numbers. A measurement refused stays due.
        fn gateMeasurementDue(self: *const Self) bool {
            const measured: bool = self.options.phases.enabled and self.candidate_recording != null;
            if (!measured or self.gate_awaited_submission != null) {
                return false;
            }
            const measured_hours: f32 = self.gate_measured_hours orelse return true;
            const interval_hours: f32 = self.options.phases.gate.measure_every_minutes / 60.0;
            return self.training_hours - measured_hours >= interval_hours;
        }

        /// THE WORLD MODEL MEASURED FOR ITS GATE (`Gate`), in `slot`: pairs of windows from the fresh lookaheads - the
        /// ones completed since the updates last drew (`lookaheads_drawable`), which no update has reached - two
        /// candidates of one replan to a pair (`CandidateRecording.drawPairStarts`), drawn from the gate's own stream;
        /// rolled open loop on their recorded actions by the world model as it stands, and measured into the stats
        /// block (`kit_mod.LatentKit.recordWorldModelGate`). Nothing is trained. Refused while there is no fresh
        /// lookahead: the measurement stays due.
        pub fn measureWorldModel(self: *Self, slot: u32) void {
            const recording: CandidateRecording = self.candidate_recording orelse {
                self.gate_measurements_refused += 1;
                return;
            };
            const window_steps: u32 = self.kit.world_steps;
            const random: Random = self.gate_rng.random();
            const drawn: bool = recording.drawPairStarts(random, window_steps, self.lookaheads_drawable, self.starts);
            if (!drawn) {
                self.gate_measurements_refused += 1;
                return;
            }
            self.data.stageStartsFrom(recording.ring, self.starts, slot, window_steps);
            self.data.gather(&self.kit, slot);
            self.kit.forwardRecorded();
            self.kit.recordWorldModelGate();
            self.gate_measurements += 1;
            self.gate_measured_hours = self.training_hours;
        }

        /// The lookaheads the world model's updates may draw from this round on: every one complete now. Those
        /// completed later are fresh for the gate's next measurement.
        fn noteLookaheadsDrawable(self: *Self) void {
            const recording: CandidateRecording = self.candidate_recording orelse return;
            self.lookaheads_drawable = recording.lookaheads_complete;
        }

        /// THE GATE JUDGED, at a round's end, once the host's copy of the device's numbers holds the awaited
        /// measurement's: the copy reflects every submission up to `device_stats_mirrored`, and the measurement was
        /// recorded in submission `gate_awaited_submission` - both 0 on a backend whose readback is immediate, so there
        /// it is judged in its own round; on a device, a round or a few later. Its reading (`GateReading`) passes the
        /// bars or not (`gatePasses`), and `Gate.passes_needed` passes in a row open phase 2 - in phase 1 only: after
        /// it the gate is measured and judged for the log alone. A failure starts the count again.
        pub fn judgeGate(self: *Self) void {
            const awaited_submission: u64 = self.gate_awaited_submission orelse return;
            const stats_mirrored: u64 = self.device_stats_mirrored orelse return;
            if (stats_mirrored < awaited_submission) {
                return;
            }
            self.gate_awaited_submission = null;
            const gate: Gate = self.options.phases.gate;
            const reading: GateReading = .of(self.device_stats);
            self.gate_latest = reading;
            self.gate_judged += 1;
            const passed: bool = gatePasses(gate, reading);
            self.gate_passes_in_a_row = if (passed) self.gate_passes_in_a_row + 1 else 0;
            const gate_can_open: bool = gate.passes_needed > 0;
            const enough_passes: bool = self.gate_passes_in_a_row >= gate.passes_needed;
            if (gate_can_open and enough_passes and self.inPhaseOne()) {
                self.beginPhaseTwo();
            }
        }

        /// One world-model update on freshly drawn windows, in its own start slot. Its batch is of one kind: at the
        /// candidates' share of the updates (`candidateBatchShare`, spread by `dueAtShare`) a planner's candidates'
        /// lookaheads, the winners favoured (`drawCandidateWindows`), while their ring holds one to draw; otherwise
        /// the characters' own, from anywhere in a segment, a fall's aftermath included - how a body falls is what
        /// the model must know to be trusted there. The critic learns from the characters' batches alone: its values
        /// are the policy's, and the candidates' actions are plans, many of them drawn to lose.
        pub fn trainWorld(self: *Self, slot: u32) void {
            const update_number: u64 = @as(u64, self.world_updates) + 1;
            const records_candidates: bool = self.candidate_recording != null;
            const candidates_due: bool =
                records_candidates and dueAtShare(update_number, self.candidateBatchShare());
            const of_candidates: bool = candidates_due and self.drawCandidateWindows(slot);
            if (candidates_due and !of_candidates) {
                self.candidate_batches_refused += 1;
            }
            if (!of_candidates and !self.drawWindows(slot, .anywhere)) {
                self.windows_refused += 1;
                return;
            }
            self.world_updates += 1;
            const world_rate: f32 = self.options.world_rate * self.rateShare(self.world_updates);
            defer self.followWorldAverage();
            // The round's gradient tally restarts at its first update only (`train`), whichever kind of update it is.
            defer self.kit.gradient_tally_restarts = false;
            if (self.skipBatchDue()) {
                self.skip_head_updates += 1;
                const consistency_due: bool = self.world_average_count > 0 and
                    dueAtShare(self.skip_head_updates, self.options.skip_consistency_share);
                if (consistency_due) {
                    self.trainSkipConsistency(slot, world_rate);
                } else {
                    self.trainSkipHead(slot, world_rate);
                }
                if (of_candidates) {
                    self.candidate_world_updates += 1;
                }
                return;
            }
            self.data.gather(&self.kit, slot);
            self.kit.trainStep(world_rate, self.world_updates);
            if (of_candidates) {
                self.candidate_world_updates += 1;
                return;
            }
            // The critic, on the same gathered windows: their real states and goals are still where the gather left
            // them, since the world model's step writes only its own rollout.
            if (self.critic) |*critic| {
                self.critic_updates += 1;
                const critic_share: f32 = self.rateShare(self.critic_updates);
                critic.options.learning_rate = self.options.critic.learning_rate * critic_share;
                critic.update(self.kit.pipe, self.critic_updates);
            }
        }

        /// Whether the world model's next update - the `world_updates`-th, already counted - is the skip head's: at its
        /// share of the updates (`Options.skip_batch_share`), spread evenly, when the learner has a skip head.
        fn skipBatchDue(self: *const Self) bool {
            if (self.skip_schedule.len == 0) {
                return false;
            }
            return dueAtShare(self.world_updates, self.options.skip_batch_share);
        }

        /// THE SKIP HEAD's UPDATE, on the windows staged in `slot`: gathered on the skip head's schedule
        /// (`Kit.Resident.gatherOnSchedule`) - each step's target the state recorded at its end, its action the mean
        /// of the actions given over it - and rolled as that many steps of the skip head, their loss trained into the
        /// trunk and the skip head by the world model's optimiser, its step the world model's. The kit is a one-step
        /// model again after it. The critic learns nothing from it: its windows are one decision a step.
        fn trainSkipHead(self: *Self, slot: u32, world_rate: f32) void {
            const steps: u32 = @intCast(self.skip_schedule.len);
            const schedule: kit_mod.GatherSchedule = .{
                .steps = steps,
                .records = steps * self.options.skip_steps,
                .at = self.skip_schedule_at,
            };
            self.data.gatherOnSchedule(&self.kit, slot, schedule);
            const one_step_window: u32 = self.kit.world_steps;
            self.kit.world_steps = steps;
            self.kit.skips = self.skip_schedule;
            self.kit.batch_kind = .skip;
            defer {
                self.kit.world_steps = one_step_window;
                self.kit.skips = &.{};
                self.kit.batch_kind = .one_step;
            }
            self.kit.trainStep(world_rate, self.world_updates);
            self.skip_world_updates += 1;
        }

        /// THE SKIP HEAD's CONSISTENCY UPDATE, on the windows staged in `slot` (`Options.skip_consistency_share`). Its
        /// target is where the world model's SLOW AVERAGE (`world_average_at`) takes the window's first recorded
        /// state through its one-step head, chained over the skip's decisions under one held action - the mean of the
        /// actions the records took over them - each step reading its recorded reference:
        ///
        ///     held          a = (a_0 + a_1 + a_2 + a_3) / 4                         over a skip of 4
        ///     target        z_4 = step1(step1(step1(step1(z_0, ref_1, a), ref_2, a), ref_3, a), ref_4, a)
        ///                   through the averaged weights
        ///     trained       the skip head from z_0, reading ref_4 and a, toward z_4, through the live weights
        ///
        /// The target is held - a copy of the weights that moves slowly, its rollout no part of the gradient - so the
        /// two sides cannot collapse onto each other. A held action is exactly what a skip head is asked about when the
        /// policy or a plan holds one; the records give the mean of actions that varied, which this target corrects
        /// for, while the skip head's own batches anchor it to what the physics did. Measured on the way: the chain's
        /// and the skip head's errors against the state recorded at the skip's end.
        pub fn trainSkipConsistency(self: *Self, slot: u32, world_rate: f32) void {
            const kit: *Kit = &self.kit;
            const pipe: *compute_host.Compute(M) = kit.pipe;
            const skip: u32 = self.options.skip_steps;
            self.data.gather(kit, slot);
            // The recorded actions over the skip held as their mean, in each of its blocks.
            pipe.params = .{
                .rows = kit.rows,
                .count = kit.actions,
                .stride = kit.width,
                .x_off = kit.x_at,
                .col = kit.lead + kit.features + kit.references,
                .lat_steps = skip,
            };
            pipe.run("lat_hold_mean_action", kit.rows * kit.actions);
            // The averaged one-step head chained over the skip, and its error against the state recorded at its end.
            var chain: Kit = kit.withWorldWeightsAt(self.world_average_at);
            chain.world_steps = skip;
            chain.skips = &.{};
            chain.forwardRecorded();
            kit.recordStatesDifference("chained_one_step_error", kit.blockZ(skip), kit.blockT(skip));
            // The chain's end as the skip's target, and the reference at the skip's end in its first block.
            pipe.params = .{
                .rows = kit.rows,
                .count = kit.features,
                .stride = kit.features,
                .x_off = kit.blockZ(skip),
                .destination_stride = kit.features,
                .y_off = kit.blockT(1),
            };
            pipe.run("copy_columns", kit.rows * kit.features);
            const reference_column: u32 = kit.lead + kit.features;
            pipe.params = .{
                .rows = kit.rows,
                .count = kit.references,
                .stride = kit.width,
                .col = reference_column,
                .x_off = kit.blockX(skip - 1),
                .destination_stride = kit.width,
                .destination_column = reference_column,
                .y_off = kit.blockX(0),
            };
            pipe.run("copy_columns", kit.rows * kit.references);
            // One step of the skip head, trained toward the chain's end.
            const one_step_window: u32 = kit.world_steps;
            kit.world_steps = 1;
            kit.skips = self.skip_schedule[0..1];
            kit.batch_kind = .skip_consistency;
            defer {
                kit.world_steps = one_step_window;
                kit.skips = &.{};
                kit.batch_kind = .one_step;
            }
            kit.trainStep(world_rate, self.world_updates);
            kit.recordStatesDifference("skip_head_error", kit.blockZ(1), kit.blockT(skip));
            self.skip_consistency_updates += 1;
        }

        /// THE WORLD MODEL's SLOW AVERAGE FOLLOWS (`Options.world_average_decay`): after a world model update, every
        /// averaged weight moved (1 - d) of the way to the live one, by the `polyak` kernel. Nothing without one.
        pub fn followWorldAverage(self: *Self) void {
            const count: u32 = self.world_average_count;
            if (count == 0) {
                return;
            }
            const pipe: *compute_host.Compute(M) = self.kit.pipe;
            pipe.params = .{
                .count = count,
                .w_off = self.world_average_at,
                .v_off = self.kit.w1,
                .tau = 1.0 - self.options.world_average_decay,
            };
            pipe.run("polyak", count);
        }

        /// A SCHEDULE's RECORD OFFSETS, written once into acts at `offsets_at`, where every gather on it reads them:
        /// each step's first record - the decisions of the steps before it, summed - and one past the last step.
        fn writeScheduleOffsets(
            self: *Self,
            schedule: []const u32,
            offsets_at: u32,
        ) !void {
            const offsets: []f32 = try self.gpa.alloc(f32, schedule.len + 1);
            defer self.gpa.free(offsets);
            var decisions_before: u32 = 0;
            for (schedule, 0..) |decisions, step| {
                offsets[step] = float(decisions_before);
                decisions_before += decisions;
            }
            offsets[schedule.len] = float(decisions_before);
            self.kit.pipe.uploadAt(.acts, offsets_at, offsets);
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
        ///     teacher 2                   the CPU planner's corrections, scored by the critic's tail - not the
        ///                                 device's, whose plans are the physics' planners', scored in the physics
        ///                                 alone (`FlowExamples`): those are as good from the first round
        ///     teacher 3                   its advantages are the critic's
        ///
        /// Teacher 1, FlowDPG, leans on the world model's gradient, which trains from the first round as SuperTrack's
        /// policy assumes: it is not ramped. Set before every policy update of every kind.
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
                const device_acting: ?DeviceActing = self.device_acting;
                const plans_from_physics: bool = if (device_acting) |acting| acting.flow_examples != null else false;
                const distillation_trust: f32 = if (plans_from_physics) 1.0 else trust;
                distillation.weight = self.options.planning.distill_weight * distillation_trust;
            }
            if (learning.fpo) |*fpo| {
                fpo.weight = self.options.flow.fpo_weight * trust;
            }
        }

        /// THE POLICY's SLOW AVERAGE FOLLOWS (`Options.policy_average_decay`): after a policy update, every averaged
        /// weight moved (1 - d) of the way to the live one - avg <- d avg + (1 - d) w - on the device, by the kernel
        /// the critic's target heads follow by (`polyak`). Nothing without an average.
        fn followPolicyAverage(self: *Self) void {
            const count: u32 = self.policy_average_count;
            if (count == 0) {
                return;
            }
            const pipe: *compute_host.Compute(M) = self.kit.pipe;
            pipe.params = .{
                .count = count,
                .w_off = self.policy_average_at,
                .v_off = self.kit.p_at,
                .tau = 1.0 - self.options.policy_average_decay,
            };
            pipe.run("polyak", count);
        }

        /// One policy update, likewise - through the world model, which this leaves untouched - from starts before a
        /// loss (`drawPolicyStarts`), and, when the fleet has returns, a share of them inside returns. The
        /// tracking loss is a squared distance from the goal: in a fall it is large and its gradient large with it.
        /// Without returns such a window points at a reference the fallen body is never asked to reach again, and
        /// would only swamp the update; with them, it is exactly what the policy must learn - the way back - and the
        /// share keeps those large gradients from drowning the tracking near the reference.
        pub fn trainPolicy(self: *Self, slot: u32) void {
            if (!self.drawPolicyStarts(slot)) {
                self.windows_refused += 1;
                return;
            }
            // On the policy's schedule when it steps through skips: each step's goal the frame its records begin
            // with, its reference the frame it ends on, the skip head's steps after the single ones.
            const through_skips: bool = self.policy_schedule.len > 0;
            if (through_skips) {
                const schedule: kit_mod.GatherSchedule = .{
                    .steps = @intCast(self.policy_schedule.len),
                    .records = self.policy_window_records,
                    .at = self.policy_schedule_at,
                };
                self.data.gatherOnSchedule(&self.kit, slot, schedule);
                self.kit.skips = self.policy_schedule;
            } else {
                self.data.gather(&self.kit, slot);
            }
            defer self.kit.skips = &.{};
            // The rollout's noise comes from this update's seed, hashed per step, row and action.
            self.kit.seed = self.policy_updates;
            self.policy_updates += 1;
            // Everything that leans on the critic, weighed by the trust in it so far.
            self.applyCriticTrust();
            // The policy's rate on its schedule, and the flow's beside it: the two learn in the same update.
            const policy_share: f32 = self.rateShare(self.policy_updates);
            self.setFlowRate(policy_share);
            // Teacher 2's targets against the policy as it is now, before the update that learns them.
            self.retargetFlowBatch();
            self.kit.policyTrainStep(self.policyRate(policy_share), self.policy_updates);
            self.followPolicyAverage();
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

        /// WHETHER THE TRAINING IS IN PHASE 1 (`Phases`): the teacher alone, until phase 2 begins. Never without
        /// phases.
        pub fn inPhaseOne(self: *const Self) bool {
            return self.options.phases.enabled and self.phase_two_began_hours == null;
        }

        /// PHASE 2 BEGINS, now - at the training hours the program has told (`training_hours`): where the world model
        /// has passed its gate (`judgeGate`), or where phase 1's bound has passed (`advancePhase`). Once, from phase 1.
        pub fn beginPhaseTwo(self: *Self) void {
            assertf(self.inPhaseOne(), @src(), "phase 2 begins from phase 1, and once", .{});
            self.phase_two_began_hours = self.training_hours;
        }

        /// PHASE 1's BOUND (`Phases.phase_one_minutes`), at the start of each round's training: past it phase 2
        /// begins, whatever the world model's gate says.
        fn advancePhase(self: *Self) void {
            if (!self.inPhaseOne()) {
                return;
            }
            const bound_hours: f32 = self.options.phases.phase_one_minutes / 60.0;
            if (self.training_hours >= bound_hours) {
                self.beginPhaseTwo();
            }
        }

        /// What a label update teaches now: its phase's label target (`Phases`).
        pub fn labelTargetNow(self: *const Self) LabelTarget {
            const phases: Phases = self.options.phases;
            return if (self.inPhaseOne()) phases.phase_one_labels else phases.phase_two_labels;
        }

        /// The share of the policy's updates that are label updates now (`labelUpdateShare`): every one in phase 1,
        /// fewer over phase 2's ramp - and none without phases, whose policy learns by rollouts alone.
        pub fn labelShare(self: *const Self) f32 {
            if (!self.options.phases.enabled) {
                return 0;
            }
            const hours_into_phase_two: ?f32 = if (self.phase_two_began_hours) |began_hours|
                self.training_hours - began_hours
            else
                null;
            return labelUpdateShare(self.options.phases, hours_into_phase_two);
        }

        /// The candidates' share of the world model's batches now: phase 1's - most of them - or the run's.
        pub fn candidateBatchShare(self: *const Self) f32 {
            if (self.inPhaseOne()) {
                return self.options.phases.phase_one_candidate_batch_share;
            }
            return self.options.candidate_batch_share;
        }

        /// ONE POLICY UPDATE, OF THE KIND ITS TURN CALLS FOR: a label update (`trainPolicyOnLabels`) at the share the
        /// training's moment sets (`labelShare`), spread evenly over the updates (`dueAtShare`); otherwise a
        /// rollout's through the world model (`trainPolicy`). Each kind is a whole step of the policy's optimiser,
        /// never summed with the other. A label update refused - no label to draw yet - gives its turn to a rollout
        /// where rollouts have a share; in phase 1 they have none: the world model gives the policy nothing.
        pub fn trainPolicyByKind(self: *Self, slot: u32) void {
            const label_share: f32 = self.labelShare();
            const update_number: u64 = @as(u64, self.policy_updates) + 1;
            const label_due: bool = label_share > 0 and dueAtShare(update_number, label_share);
            if (label_due) {
                const label_updates_before: u64 = self.label_updates;
                switch (self.labelTargetNow()) {
                    .recorded_actions => self.trainPolicyOnLabels(slot),
                    .flow_mode => self.trainPolicyOnFlowMode(),
                }
                const trained_on_labels: bool = self.label_updates > label_updates_before;
                const rollouts_have_a_share: bool = label_share < 1;
                if (trained_on_labels or !rollouts_have_a_share) {
                    return;
                }
            }
            // The world model alone first (`Options.world_alone_updates`): until it has had its updates, a rollout's
            // turn passes.
            const world_model_alone: bool = self.world_updates < self.options.world_alone_updates;
            if (world_model_alone) {
                return;
            }
            self.trainPolicy(slot);
        }

        /// ONE POLICY UPDATE ON THE PLANNERS' LABELS - the policy's distillation toward the planners
        /// (`LatentKit.policyLabelTrainStep`): a batch of labels drawn uniformly from those the books keep
        /// (`track.LabelBooks`), each gathered as a one-step window of the characters' ring from its record - the
        /// state, the goal it aimed at, the planner's action, and what was applied just before it (`drawLabelWindows`)
        /// - then the flow's turn at the plans (teacher 2, `LatentKit.flowPlansStep`), its batch's targets taken
        /// against the base, and the label step, at the policy's rate on its schedule and the labels' weight
        /// (`Options.label_weight`).
        /// One step of the policy's optimiser, counted among `policy_updates` as a rollout's is: the two kinds share
        /// its moments. Nothing is rolled and the world model is not read, so a policy learns this way before any world
        /// model is good. Refused and counted (`label_batches_refused`) while there is no label to draw.
        pub fn trainPolicyOnLabels(self: *Self, slot: u32) void {
            if (!self.drawLabelWindows(slot)) {
                self.label_batches_refused += 1;
                return;
            }
            self.data.gather(&self.kit, slot);
            self.kit.seed = self.policy_updates;
            self.policy_updates += 1;
            self.label_updates += 1;
            const policy_share: f32 = self.rateShare(self.policy_updates);
            const label_rate: f32 = self.policyRate(policy_share);
            // The flow's turn at the plans (teacher 2), its batch's targets taken against the base: in phase 1 a
            // label update is the only update there is.
            self.applyCriticTrust();
            self.setFlowRate(policy_share);
            self.retargetFlowBatch();
            self.kit.flowPlansStep(self.policy_updates);
            self.kit.policyLabelTrainStep(label_rate, self.policy_updates, self.options.label_weight);
            self.followPolicyAverage();
        }

        /// ONE POLICY UPDATE ON THE FLOW's MAIN MODE (`LabelTarget.flow_mode`, `LatentKit.policyModeTrainStep`): the
        /// kit's label rows drawn from teacher 2's ring (`drawModeRows`), teacher 2's batch's targets taken against
        /// the base (`retargetFlowBatch`), then the step - the flow learning the plans, the policy its main mode - at
        /// the policy's rate on its schedule and the labels' weight; the flow at its own rate. Counted among
        /// `policy_updates` and `label_updates` as a label update is. Refused and counted (`label_batches_refused`)
        /// while the ring holds no good example.
        pub fn trainPolicyOnFlowMode(self: *Self) void {
            if (!self.drawModeRows()) {
                self.label_batches_refused += 1;
                return;
            }
            self.kit.seed = self.policy_updates;
            self.policy_updates += 1;
            self.label_updates += 1;
            const policy_share: f32 = self.rateShare(self.policy_updates);
            self.applyCriticTrust();
            self.setFlowRate(policy_share);
            self.retargetFlowBatch();
            const mode_rate: f32 = self.policyRate(policy_share);
            const examples: FlowExamples = self.device_acting.?.flow_examples.?;
            const base_kit: Kit = self.baseKit();
            const weight: f32 = self.options.label_weight;
            self.kit.policyModeTrainStep(base_kit, examples.mode_targets_at, mode_rate, self.policy_updates, weight);
            self.followPolicyAverage();
        }

        /// THE FLOW's MODE's ROWS (`trainPolicyOnFlowMode`): one of the ring's good examples - its stretch ended well -
        /// drawn for each of the kit's rows, with replacement, gathered on the device (`zn_mlp.gather_flow_batch`):
        /// each condition into the kit's first wide row, each applied action into its starting actions
        /// (`LatentKit.labelRows`), each choice beside them. False without a ring on the device or before it holds a
        /// good example.
        fn drawModeRows(self: *Self) bool {
            const acting: DeviceActing = self.device_acting orelse return false;
            const examples: FlowExamples = acting.flow_examples orelse return false;
            const good_slots: []const u32 = examples.goodSlots();
            if (good_slots.len == 0) {
                return false;
            }
            const random: Random = self.rng.random();
            for (examples.mode_table) |*slot| {
                slot.* = float(good_slots[random.uintLessThan(usize, good_slots.len)]);
            }
            self.kit.pipe.uploadAt(.acts, examples.mode_table_at, examples.mode_table);
            const label_rows: Kit.LabelRows = self.kit.labelRows();
            const condition_width: u32 = self.kit.lead + self.kit.features;
            const action_width: u32 = self.kit.actions;
            const mode_rows: u32 = @intCast(examples.mode_table.len);
            self.kit.pipe.params = .{
                .rows = mode_rows,
                .in_dim = condition_width,
                .out_dim = action_width,
                .x_off = examples.ring_at,
                .y_off = label_rows.conditions_at,
                .stride = label_rows.condition_stride,
                .v_off = label_rows.applied_at,
                .z_off = examples.mode_choices_at,
                .t_off = examples.mode_table_at,
            };
            self.kit.pipe.run("gather_flow_batch", mode_rows * (condition_width + 2 * action_width));
            return true;
        }

        /// The flow's rate for an update at `policy_share` of the policy's schedule: the flow learns beside the
        /// policy, on the same schedule.
        fn setFlowRate(self: *Self, policy_share: f32) void {
            const flow_actor: *kit_mod.FlowActor(M) = if (self.kit.flow_actor) |*actor| actor else return;
            const learning: *kit_mod.FlowActor(M).Learning = if (flow_actor.learning) |*part| part else return;
            learning.teacher.learning_rate = self.options.flow.learning_rate * policy_share;
        }

        /// A BATCH OF LABELS STAGED for slot `slot` (`trainPolicyOnLabels`): each of the batch's windows a label drawn
        /// from the books' kept labels, as a window of ONE step of the characters' ring from the label's record - its
        /// record and the next, whose frame is the label's goal, and the record before where the window continues its
        /// episode (`windowStartInRing`). A label whose window the ring cannot give whole - one at its oldest record,
        /// its record before already gone - is drawn again. False while the learner keeps no labels (it acts on its
        /// CPU fleet, whose records carry none), none is kept yet, or 64 draws in a row gave none whole.
        fn drawLabelWindows(self: *Self, slot: u32) bool {
            const acting: DeviceActing = self.device_acting orelse return false;
            const labels: track.LabelBooks = acting.books.labels;
            const books: track.Replay.Books = acting.books.view();
            const ring_held: kit_mod.RecordRing.HeldSteps = self.data.ring.held() orelse return false;
            const random: Random = self.rng.random();
            const label_steps: u32 = 1;
            for (self.starts) |*start| {
                var tries: u32 = 0;
                start.* = while (tries < 64) : (tries += 1) {
                    const label: track.Label = labels.drawLabel(random) orelse return false;
                    const window: track.Replay.Window = .{
                        .env = label.env,
                        .first = label.index,
                        .steps = label_steps,
                    };
                    if (windowStartInRing(books, ring_held, window, label_steps)) |in_ring| {
                        break in_ring;
                    }
                } else {
                    return false;
                };
            }
            self.data.stageStarts(self.starts, slot, label_steps);
            return true;
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
        /// may replace by `act` and this): the training's phase advanced, the teachers' batches uploaded, the round's
        /// updates recorded and submitted - the world model's, then the policy's, each of its kind
        /// (`trainPolicyByKind`) - and the mirror and the device's numbers taken from the readback. Through the
        /// warm-up (`warmingUp`) the round measures and updates nothing: the world model's running statistics fold
        /// the round's records, and that is all.
        pub fn train(self: *Self) void {
            const warming_up: bool = self.warmingUp();
            // The training's phase, at the hours the program has told: phase 1's bound may have passed.
            self.advancePhase();
            // Teacher 2's batch, uploaded before the recording opens: an upload made while one is open lands before
            // the whole recording, and this one is meant for all of it.
            self.uploadDistillationBatch();
            self.uploadFpoBatch();
            // The round's time: the gate's measurement and the world model's updates, then the policy's.
            self.enterPhase(.world_model);
            self.kit.pipe.beginRecording();
            self.startFpoRound();
            // The gate's measurement first, in a slot of its own: the world model as the last round left it, on
            // lookaheads none of its updates has drawn. From then on every lookahead complete is the updates' to draw.
            const gate_slot: u32 = 0;
            const gate_measurements_before: u64 = self.gate_measurements;
            if (!warming_up and self.gateMeasurementDue()) {
                self.measureWorldModel(gate_slot);
            }
            const measured_this_round: bool = self.gate_measurements > gate_measurements_before;
            self.noteLookaheadsDrawable();
            self.foldWorldStatistics();
            // The world model's gradient tally counts this round's updates (`DeviceStats.world_updates_in_round`).
            self.kit.gradient_tally_restarts = true;
            const world_updates_this_round: u32 = if (warming_up) 0 else self.options.world_updates;
            const policy_updates_this_round: u32 = if (warming_up) 0 else self.options.policy_updates;
            var slot: u32 = gate_slot + 1;
            for (0..world_updates_this_round) |_| {
                self.trainWorld(slot);
                slot += 1;
            }
            self.enterPhase(.policy);
            for (0..policy_updates_this_round) |_| {
                self.trainPolicyByKind(slot);
                slot += 1;
            }
            // A round of training done - the iteration the policy's rate boost counts (`policyRateMultiplier`).
            if (!warming_up) {
                self.training_rounds += 1;
            }
            self.kit.pipe.submitRecording();
            self.enterPhase(.other);
            // The measurement's numbers arrive with the readback of this submission, or of a later one.
            if (measured_this_round) {
                self.gate_awaited_submission = self.kit.pipe.readGeneration().submitted;
            }
            // The weights the simulation acts from, as of this round.
            self.syncMirror();
            // The device's numbers from the same readback, whether or not the mirror took its weights: a non-finite
            // number in them is what the log most needs to show.
            self.refreshDeviceStats();
            self.judgeGate();
        }

        /// THE POLICY's RATE MULTIPLIER NOW (`Options.policy_rate_boost`, `RateBoost.at`): at the round of training
        /// this learner is in. Every step of the policy's optimiser takes it - a rollout's, a label's, the flow's
        /// mode's.
        pub fn policyRateMultiplier(self: *const Self) f32 {
            return self.options.policy_rate_boost.at(self.training_rounds);
        }

        /// The policy's learning rate for a step at its schedule's `share` (`rateShare`), the boost's multiplier with
        /// it.
        fn policyRate(self: *const Self, share: f32) f32 {
            return self.options.policy_rate * share * self.policyRateMultiplier();
        }

        /// WHETHER THE LEARNER IS STILL WARMING UP (`Options.warmup_decisions`): its ring holds fewer decisions of each
        /// character than the warm-up asks - every character appends every decision, so one count is everyone's.
        pub fn warmingUp(self: *const Self) bool {
            return self.decisionsHeld() < self.options.warmup_decisions;
        }

        /// The decisions of each character the ring holds: from its oldest held to its newest, at most its capacity.
        pub fn decisionsHeld(self: *const Self) u64 {
            const held: kit_mod.RecordRing.HeldSteps = self.data.ring.held() orelse return 0;
            return held.last - held.first + 1;
        }

        /// THE WORLD MODEL's WINDOWS (`trainWorld`): windows the CPU replay draws - it knows where episodes begin and
        /// end - as long as the world model's own window (`world_window_records`), staged into `slot`, each starting
        /// where `window_start` allows (`track.WindowStart`). The world model's are drawn `.anywhere`, so a window of 8
        /// can end on the transition into a loss, where the policy's horizon would have stopped it a horizon before.
        /// False when the replay cannot supply them yet. Public because a caller may want a batch of windows staged
        /// without an update following it, and because the tests compare both learners on the SAME windows.
        pub fn drawWindows(self: *Self, slot: u32, window_start: track.WindowStart) bool {
            return self.drawWindowsMixed(slot, window_start, 0, self.world_window_records);
        }

        /// THE POLICY's STARTS (`trainPolicy`), staged into `slot`: single records, each the first state of a rollout
        /// imagined for the policy's horizon, its references read from the clip's tables (`kit_mod.Resident.
        /// stagePolicyStarts`). Drawn uniformly over the characters and the records their rings hold
        /// (`track.Replay.Books.sampleStart`) wherever a horizon of their clip follows - the clip's frames of
        /// `policy_window_records` decisions - before a loss, and with returns a share inside them
        /// (`returnWindowShare`); so a record a decision before a fall is a start, where a window had to end a horizon
        /// before it. Each start as the ring holds it (`windowStartInRing` at no length: the record, and the one before
        /// where the start continues its episode). False when the books or the ring cannot give them yet.
        pub fn drawPolicyStarts(self: *Self, slot: u32) bool {
            const random: Random = self.rng.random();
            const books: track.Replay.Books = self.windowBooks();
            const range: kit_mod.RecordRing.HeldSteps = self.data.ring.held() orelse return false;
            const frames_needed: u32 = self.policy_window_records * self.data.decision_frames;
            const return_share: f32 = self.returnWindowShare();
            const only_the_record: u32 = 0;
            for (self.starts) |*start| {
                const tries_inside_return: bool = return_share > 0 and random.float(f32) < return_share;
                // A start inside a return, offered once: if the ring does not hold it, ordinary draws follow.
                var inside_return: ?track.Replay.Window = if (tries_inside_return)
                    books.sampleStart(random, frames_needed, .after_loss)
                else
                    null;
                var tries: u32 = 0;
                start.* = while (tries < 64) : (tries += 1) {
                    const offered: ?track.Replay.Window = inside_return;
                    inside_return = null;
                    const drawn: track.Replay.Window = offered orelse
                        books.sampleStart(random, frames_needed, .before_loss) orelse
                        return false;
                    if (windowStartInRing(books, range, drawn, only_the_record)) |in_ring| {
                        break in_ring;
                    }
                } else {
                    return false;
                };
            }
            self.data.stagePolicyStarts(self.starts, slot, self.policy_window_records);
            return true;
        }

        /// The share of the policy's windows drawn inside returns: `Options.return_window_share` when the fleet has
        /// returns (`track.Fleet.Options.return_steps`), none otherwise - after a loss there is then nothing to return
        /// to.
        pub fn returnWindowShare(self: *const Self) f32 {
            const fleet_has_returns: bool = self.fleet.options.return_steps > 0;
            return if (fleet_has_returns) self.options.return_window_share else 0;
        }

        /// ONE CHARACTER's DECISION IN THE LEARNER's COUNTS, whoever simulated it - the CPU fleet (`act`) or a
        /// simulator on the device (`robotgpu_host.Sim.actTrainerOnDevice`). A decision watched, and a failure if the
        /// character just lost its reference: the flag is raised on the decision an episode ENDS, and only when it
        /// ended badly - a clip running out is a character that survived to the end of the motion.
        ///
        /// A decision taken in an aftermath - after the character lost the reference, on its way back or falling -
        /// is not time at risk, so it is not watched: counted, it would lengthen the time to failure of a run with
        /// aftermaths and returns against one without. Decisions acted without noise (`judged`) are counted apart:
        /// those are the policy being judged, not explored with, and mixing the two would leave a number that
        /// answers neither question. Each decision is counted on `clip` too, the clip it was taken on.
        pub fn countDecision(
            self: *Self,
            clip: usize,
            lost: bool,
            in_aftermath: bool,
            judged: bool,
        ) void {
            const at_risk: u64 = if (in_aftermath) 0 else 1;
            if (judged) {
                self.judged_exposure += at_risk;
                if (lost) {
                    self.judged_failures += 1;
                }
                return;
            }
            self.exposure += at_risk;
            self.exposure_by_clip[clip] += at_risk;
            if (lost) {
                self.failures += 1;
                self.failures_by_clip[clip] += 1;
            }
        }

        /// ONE PLANNER's DECISION in the teacher's counts (`planner_exposure`, `planner_failures`), beside its count
        /// among everyone's (`countDecision`): at risk outside an aftermath, a failure where it lost the reference.
        /// Judged decisions are the policy alone, never a planner's: not counted.
        pub fn countPlannerDecision(
            self: *Self,
            lost: bool,
            in_aftermath: bool,
            judged: bool,
        ) void {
            if (judged) {
                return;
            }
            const at_risk: u64 = if (in_aftermath) 0 else 1;
            self.planner_exposure += at_risk;
            if (lost) {
                self.planner_failures += 1;
            }
        }

        /// The books this learner's windows are drawn from (`track.Replay.Books`): which records belong to one
        /// stretch of unbroken motion, and which came after a loss. Acting on its CPU fleet, the fleet's replay
        /// keeps them; acting through a simulator on the device, the books kept from that simulator's flags.
        fn windowBooks(self: *const Self) track.Replay.Books {
            var books: track.Replay.Books = if (self.device_acting) |acting|
                acting.books.view()
            else
                self.fleet.replay.books();
            books.clip_frames = self.clip_frame_counts;
            return books;
        }

        /// What acting through a simulator on the device needs of the learner: the kit's rows for every world's
        /// policy inputs and actions (`Kit.PolicyRows`), and the books of its records (`track.KeptBooks`).
        pub const DeviceActing = struct {
            rows: Kit.PolicyRows,
            books: track.KeptBooks,
            /// The simulator's world that is the learner's first character: its characters are the worlds from it
            /// on, one a character. The worlds before it are no characters of this learner - a planner's candidates,
            /// which sit first in the batch.
            first_world: u32,
            /// The kit's rows for the policy to choose for the candidates in a lookahead around it
            /// (`robot.PlanForm.offsets_around_policy`), one a candidate (`acceptCandidateActing`); none until then.
            candidate_rows: ?Kit.PolicyRows = null,
            /// With a flow actor (`Options.actor` `.flow`): its correction over the characters' rows, each with its
            /// own drifting noise (`Kit.FlowRows`). The noise lives on the device and is not saved: a resumed run's
            /// starts from zero, as a new run's does.
            flow: ?Kit.FlowRows = null,
            /// With a flow that learns from plans: the planners' examples around the policy (`acceptCandidateActing`).
            flow_examples: ?FlowExamples = null,
            /// With the model planner (`Options.planning`): its states' table in the kit - [state][3], each state's
            /// acting row and its reference table's two rows (`TrackingPlanner.RowsDecision`) - and the host's copy of
            /// it; and
            /// whether its characters have been chosen yet (`chooseModelCharacters`).
            model_table_at: u32 = 0,
            model_table: []f32 = &.{},
            model_characters_chosen: bool = false,
        };

        /// MADE TO ACT THROUGH A SIMULATOR ON THE DEVICE. The kit gains rows for `worlds` worlds' policy inputs and
        /// actions at the simulator's own strides (`Kit.reservePolicyRows`), placed after everything the learner
        /// already uses, so the simulator's arrays are copied into them and out of them whole. The learner gains
        /// empty books, which the simulator's flags will keep, one decision at a time; its windows are drawn from
        /// them from now on. A world is a character of the fleet: the ring holds one record a character, so there
        /// are as many worlds as characters.
        pub fn acceptDeviceActing(
            self: *Self,
            first_world: u32,
            worlds: u32,
            input_stride: u32,
            action_stride: u32,
        ) !void {
            const characters: usize = self.fleet.options.envs;
            assertf(worlds == characters, @src(), "{d} worlds for {d} characters", .{ worlds, characters });
            assertf(self.device_acting == null, @src(), "the learner already acts through a simulator", .{});
            // The rows go after everything the learner already uses: its buffers as `init` left them, extended.
            var layout_with_rows: kit_mlp.KitLayout = self.buffers_used;
            const policy_rows: Kit.PolicyRows =
                self.kit.reservePolicyRows(&layout_with_rows, worlds, input_stride, action_stride);
            // A flow actor corrects the characters' actions with its own drifting noise, row by row.
            var flow_rows: ?Kit.FlowRows = null;
            if (self.kit.flow_actor != null) {
                const descriptors: Allocator = self.critic_arena.allocator();
                flow_rows = try self.kit.reserveFlowRows(descriptors, &layout_with_rows, policy_rows);
            }
            // The model planner's states' table, when it plans on the device.
            var model_table_at: u32 = 0;
            var model_table: []f32 = &.{};
            if (self.planner) |planner| {
                const states: u32 = planner.scorer.options.states;
                model_table_at = layout_with_rows.reserveActs(3 * states);
                model_table = try self.gpa.alloc(f32, 3 * states);
            }
            errdefer self.gpa.free(model_table);
            layout_with_rows.requireFitsKit(M);
            // As many records a world as the ring holds.
            const ring_capacity: usize = self.data.ring.capacity;
            const books: track.KeptBooks = try .init(self.gpa, worlds, ring_capacity);
            self.buffers_used = layout_with_rows;
            self.device_acting = .{
                .rows = policy_rows,
                .books = books,
                .first_world = first_world,
                .flow = flow_rows,
                .model_table_at = model_table_at,
                .model_table = model_table,
            };
        }

        /// THE FLOW's NOISE FOR A DEVICE DECISION (`Kit.FlowNoise`), numbered `decision_number`, at the acting's
        /// `noise_scale` (1 while training, 0 for the policy alone): fresh normals from the run's seed and the
        /// decision's number on a stream of the flow's own, and the drifting noise's correlation over one decision -
        /// its time `flow.noise_correlation_seconds`, as the CPU's characters keep theirs (`zimrrl.ouCorrelation`).
        pub fn flowNoiseAt(
            self: *const Self,
            decision_number: u32,
            noise_scale: f32,
        ) Kit.FlowNoise {
            const flow_acting_stream: u32 = 0xF1_0A;
            const run_seed: u32 = @truncate(self.options.seed ^ (self.options.seed >> 32));
            const stream_seed: u32 = M.latStepSeed(run_seed, flow_acting_stream);
            const decision_seconds: f32 =
                track.secondsPerDecision(self.fleet.m.opt.timestep, self.fleet.options.decide_every);
            const correlation_seconds: f32 = self.options.flow.noise_correlation_seconds;
            const noise: Kit.FlowNoise = .{
                .seed = M.latStepSeed(stream_seed, decision_number),
                .correlation = zrl.ouCorrelation(f32, decision_seconds, correlation_seconds),
                .scale = noise_scale,
            };
            return noise;
        }

        /// MADE TO ACT FOR A PLANNER's CANDIDATES: rows for `candidate_count` candidates - the simulator's first worlds
        /// - in the kit, at the strides of the characters' rows, after everything the learner already uses: a
        /// lookahead around the policy has the policy choose for every candidate at each of its decisions
        /// (`robotgpu_host.Sim.stepCandidatesAroundPolicy`). The learner must act through the simulator already
        /// (`acceptDeviceActing`).
        pub fn acceptCandidateActing(self: *Self, candidate_count: u32) !void {
            assertf(self.device_acting != null, @src(), "candidates act through the learner's simulator", .{});
            const acting: *DeviceActing = &self.device_acting.?;
            assertf(acting.candidate_rows == null, @src(), "the learner already acts for candidates", .{});
            const character_rows: Kit.PolicyRows = acting.rows;
            var layout_with_rows: kit_mlp.KitLayout = self.buffers_used;
            const candidate_rows: Kit.PolicyRows = self.kit.reservePolicyRows(
                &layout_with_rows,
                candidate_count,
                character_rows.input_stride,
                character_rows.raw_stride,
            );
            // Teacher 2's examples, when the flow learns from plans (`FlowExamples`).
            const distillation: ?kit_mod.FlowActor(M).Distillation = if (self.kit.flow_actor) |actor|
                actor.learningPart().distillation
            else
                null;
            if (distillation) |part| {
                const action_width: u32 = self.kit.actions;
                const example_width: u32 = self.kit.lead + self.kit.features + 2 * action_width;
                const capacity: u32 = self.options.planning.distill_examples;
                const characters: u32 = character_rows.rows;
                const batch_rows: u32 = part.trainer.rows;
                const policy_hidden_width: u32 = self.kit.policy_hidden;
                const table: []f32 = try self.gpa.alloc(f32, 2 * characters);
                errdefer self.gpa.free(table);
                const batch_table: []f32 = try self.gpa.alloc(f32, batch_rows);
                errdefer self.gpa.free(batch_table);
                const mode_rows: u32 = self.kit.rows;
                const mode_table: []f32 = try self.gpa.alloc(f32, mode_rows);
                errdefer self.gpa.free(mode_table);
                const slot_character: []u32 = try self.gpa.alloc(u32, capacity);
                errdefer self.gpa.free(slot_character);
                const slot_record: []u64 = try self.gpa.alloc(u64, capacity);
                errdefer self.gpa.free(slot_record);
                const slot_good: []bool = try self.gpa.alloc(bool, capacity);
                errdefer self.gpa.free(slot_good);
                const good_slots: []u32 = try self.gpa.alloc(u32, capacity);
                @memset(slot_character, 0);
                @memset(slot_record, FlowExamples.no_record);
                @memset(slot_good, false);
                acting.flow_examples = .{
                    .ring_at = layout_with_rows.reserveActs(capacity * example_width),
                    .capacity = capacity,
                    .plan_numbers_at = layout_with_rows.reserveActs(characters * character_rows.raw_stride),
                    .table_at = layout_with_rows.reserveActs(2 * characters),
                    .batch_table_at = layout_with_rows.reserveActs(batch_rows),
                    .batch_applied_at = layout_with_rows.reserveActs(batch_rows * action_width),
                    .batch_choices_at = layout_with_rows.reserveActs(batch_rows * action_width),
                    .batch_hidden1_at = layout_with_rows.reserveActs(batch_rows * policy_hidden_width),
                    .batch_hidden2_at = layout_with_rows.reserveActs(batch_rows * policy_hidden_width),
                    .batch_answers_at = layout_with_rows.reserveActs(batch_rows * action_width),
                    .mode_table_at = layout_with_rows.reserveActs(mode_rows),
                    .mode_choices_at = layout_with_rows.reserveActs(mode_rows * action_width),
                    .mode_targets_at = layout_with_rows.reserveActs(mode_rows * action_width),
                    .table = table,
                    .batch_table = batch_table,
                    .mode_table = mode_table,
                    .slot_character = slot_character,
                    .slot_record = slot_record,
                    .slot_good = slot_good,
                    .good_slots = good_slots,
                };
            }
            layout_with_rows.requireFitsKit(M);
            self.buffers_used = layout_with_rows;
            acting.candidate_rows = candidate_rows;
        }

        /// TEACHER 2's EXAMPLES FROM A DECISION (`FlowExamples`): the characters `followers` - acting rows, each a
        /// planner that followed its plan at this decision - each an example in the ring, from its acting row: its
        /// condition, the action applied before, and its whole choice as a raw action. The plan's numbers - every
        /// character's block of them from `plan_numbers_from` on in the simulator, copied in first - are in the plans'
        /// form (`robot.PlanForm`): around the policy its offsets (`plan_offsets`), the choice the policy's raw action
        /// plus the offset (`zn_mlp.gather_flow_examples`); as whole actions the actions given (`actions`), the
        /// choice the raw action the filter would have made each (`zn_mlp.gather_flow_examples_given`). Each slot
        /// taken is the follower's, with the decision's record `record_index`, and not yet good: its stretch has not
        /// settled (`FlowExamples`). Nothing without examples or followers.
        pub fn keepFlowExamples(
            self: *Self,
            simulator: compute_host.DeviceField,
            plan_numbers_from: u32,
            form: rbt.PlanForm,
            record_index: u64,
            followers: []const u32,
        ) void {
            const acting: *DeviceActing = &(self.device_acting orelse return);
            const examples: *FlowExamples = if (acting.flow_examples) |*kept| kept else return;
            if (followers.len == 0) {
                return;
            }
            const rows: Kit.PolicyRows = acting.rows;
            const float_bytes: u32 = @sizeOf(f32);
            const plan_bytes: u32 = rows.rows * rows.raw_stride * float_bytes;
            const kit_acts: compute_host.DeviceField = self.kit.pipe.deviceField(.acts);
            compute_host.copyFieldBetween(
                simulator,
                plan_numbers_from * float_bytes,
                kit_acts,
                examples.plan_numbers_at * float_bytes,
                plan_bytes,
            );
            // The table: each follower's row and the slot it takes - the oldest once the ring is full.
            for (followers, 0..) |row, example| {
                const slot: u32 = examples.next;
                examples.table[2 * example] = float(row);
                examples.table[2 * example + 1] = float(slot);
                examples.slot_character[slot] = row;
                examples.slot_record[slot] = record_index;
                examples.slot_good[slot] = false;
                examples.next = (slot + 1) % examples.capacity;
                examples.count = @min(examples.count + 1, examples.capacity);
            }
            const table_numbers: usize = 2 * followers.len;
            self.kit.pipe.uploadAt(.acts, examples.table_at, examples.table[0..table_numbers]);
            const condition_width: u32 = self.kit.lead + self.kit.features;
            const action_width: u32 = self.kit.actions;
            const example_count: u32 = @intCast(followers.len);
            self.kit.pipe.params = .{
                .rows = example_count,
                .in_dim = condition_width,
                .count = action_width,
                .x_off = rows.inputs_at,
                .stride = rows.input_stride,
                .v_off = rows.applied_at,
                .u_off = rows.raw_at,
                .z_off = examples.plan_numbers_at,
                .destination_stride = rows.raw_stride,
                .y_off = examples.ring_at,
                .t_off = examples.table_at,
                // The action filter, for whole actions to be undone into raw ones.
                .lat_scale = self.kit.action_scale,
                .lat_filter = self.kit.filter,
                .lat_stiffness_filter = self.kit.stiffness_filter,
                .lat_stiffness_count = self.kit.stiffness_count,
            };
            // The kernel by the plans' form - a name fixed when compiled, so one call each.
            const invocations: u32 = example_count * (condition_width + 2 * action_width);
            switch (form) {
                .offsets_around_policy => self.kit.pipe.run("gather_flow_examples", invocations),
                .whole_actions => self.kit.pipe.run("gather_flow_examples_given", invocations),
            }
        }

        /// MADE TO RECORD A PLANNER's CANDIDATES: `candidate_count` candidates - the simulator's first worlds, in
        /// blocks of `candidates_per_planner` - every lookahead of `horizon` decisions kept whole, the newest
        /// `lookaheads_kept` of them, in a ring reserved in the kit after everything the learner already uses
        /// (`CandidateRecording`). The learner must act through the simulator already (`acceptDeviceActing`): the
        /// records come from it, one copy a step (`appendCandidateStep`).
        pub fn acceptCandidateRecording(
            self: *Self,
            candidate_count: u32,
            candidates_per_planner: u32,
            horizon: u32,
            lookaheads_kept: u32,
        ) !void {
            const acts_through_a_simulator: bool = self.device_acting != null;
            assertf(acts_through_a_simulator, @src(), "candidates are recorded from the learner's simulator", .{});
            assertf(self.candidate_recording == null, @src(), "the learner already records candidates", .{});
            const whole_blocks: bool = candidates_per_planner > 0 and candidate_count % candidates_per_planner == 0;
            assertf(whole_blocks, @src(), "{d} candidates in blocks of {d}", .{
                candidate_count,
                candidates_per_planner,
            });
            assertf(lookaheads_kept > 0, @src(), "a ring of no lookahead", .{});
            const lookahead_records: u32 = horizon + 1;
            const capacity: u32 = lookaheads_kept * lookahead_records;
            var layout_with_ring: kit_mlp.KitLayout = self.buffers_used;
            const record: u32 = self.data.ring.record;
            const ring: kit_mod.RecordRing = .{
                .at = layout_with_ring.reserveRing(capacity * candidate_count * record),
                .envs = candidate_count,
                .capacity = capacity,
                .record = record,
            };
            layout_with_ring.requireFitsKit(M);
            const favoured: []bool = try self.gpa.alloc(bool, lookaheads_kept * candidate_count);
            errdefer self.gpa.free(favoured);
            @memset(favoured, false);
            // Every block, until a lookahead says how many it ran.
            const planners_recorded: []u32 = try self.gpa.alloc(u32, lookaheads_kept);
            @memset(planners_recorded, candidate_count / candidates_per_planner);
            self.buffers_used = layout_with_ring;
            self.candidate_recording = .{
                .ring = ring,
                .candidates_per_planner = candidates_per_planner,
                .lookahead_records = lookahead_records,
                .lookaheads_kept = lookaheads_kept,
                .favoured = favoured,
                .planners_recorded = planners_recorded,
            };
        }

        /// A LOOKAHEAD DECISION's CANDIDATE RECORDS INTO THEIR RING, from the simulator they were packed in: the
        /// candidates' blocks - the simulator's first worlds', `records_at` on, `record_stride` apart - moved by one
        /// copy on the GPU (`kit_mod.RecordRing.appendFromSimulator`) to the ring's step for the lookahead being
        /// recorded and its decision `lookahead_decision`, H for the state after its last.
        pub fn appendCandidateStep(
            self: *Self,
            simulator: compute_host.DeviceField,
            records_at: u32,
            record_stride: u32,
            lookahead_decision: u32,
        ) void {
            const recording: *CandidateRecording = &self.candidate_recording.?;
            const step: u64 = recording.stepOf(recording.lookaheads_complete, lookahead_decision);
            const ring_field: compute_host.DeviceField = self.data.pipe.deviceField(.ring);
            recording.ring.appendFromSimulator(ring_field, step, simulator, records_at, record_stride);
        }

        /// THE CANDIDATES' WINDOWS for one update of the world model, staged into `slot` from the candidates' ring for
        /// the world model's own window (`kit.world_steps`) - all its update reads, however long the policy's horizon:
        /// the first half of the rows from each lookahead's favoured, the rest from all its candidates
        /// (`CandidateRecording.drawStart`). False when there is none to draw.
        fn drawCandidateWindows(self: *Self, slot: u32) bool {
            const recording: CandidateRecording = self.candidate_recording orelse return false;
            const random: Random = self.rng.random();
            const window_steps: u32 = self.kit.world_steps;
            const favoured_rows: usize = self.starts.len / 2;
            for (self.starts, 0..) |*start, row| {
                const favoured_only: bool = row < favoured_rows;
                start.* = recording.drawStart(random, window_steps, favoured_only) orelse return false;
            }
            self.data.stageStartsFrom(recording.ring, self.starts, slot, window_steps);
            return true;
        }

        /// WINDOWS OF `window_length` RECORDS staged into `slot` - each drawn inside a return
        /// (`track.WindowStart.after_loss`) with probability `return_share`, falling back to `window_start` while the
        /// replay holds none, and otherwise where `window_start` allows - and checked against the ring at that length.
        /// A share of 0 draws nothing more from the random stream: the windows of a learner without returns are the
        /// ones it always drew: the world model's (`drawWindows`); the policy draws starts (`drawPolicyStarts`).
        fn drawWindowsMixed(
            self: *Self,
            slot: u32,
            window_start: track.WindowStart,
            return_share: f32,
            window_length: u32,
        ) bool {
            const random: Random = self.rng.random();
            const books: track.Replay.Books = self.windowBooks();
            // Only what the RING holds. The books know where episodes begin and end, so they draw the
            // windows - but they may also hold steps from before the learner existed, or more of them
            // than the ring has room for, and a window the ring never received would be assembled out
            // of whatever those slots happen to contain. So: draw, and keep only what the ring carries.
            const range: kit_mod.RecordRing.HeldSteps = self.data.ring.held() orelse return false;
            for (self.starts) |*start| {
                const tries_inside_return: bool = return_share > 0 and random.float(f32) < return_share;
                // The window inside a return, offered once: if the ring does not hold it, ordinary draws follow.
                var inside_return: ?track.Replay.Window = if (tries_inside_return)
                    books.sampleWindowStarting(random, window_length, .after_loss)
                else
                    null;
                var tries: u32 = 0;
                start.* = while (tries < 64) : (tries += 1) {
                    const offered: ?track.Replay.Window = inside_return;
                    inside_return = null;
                    const drawn: track.Replay.Window = offered orelse
                        books.sampleWindowStarting(random, window_length, window_start) orelse
                        return false;
                    if (windowStartInRing(books, range, drawn, window_length)) |in_ring| {
                        break in_ring;
                    }
                } else {
                    // The ring is still far behind the replay - the first rounds, or just after a
                    // warm-up. Train nothing this round rather than train on slots we cannot vouch for.
                    return false;
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
            const root_target: bool = self.options.root_target;
            supertrackFeaturesInto(fleet, env, self.norm, root_target, scratch, self.host.goal, self.host.z);
        }

        /// What this learner's policy file is made of (`PolicyParts`, `robot_lab.policyOfSuperTrack`): the judged
        /// weights - the slow average where the learner keeps one, else the weights acting uses - and the normaliser,
        /// borrowed. Call `waitForReadback` and `syncMirror` first, in a
        /// program without frames, for the newest policy.
        pub fn policyParts(self: *const Self) PolicyParts {
            return .{
                // The judged weights: what the judge, the probes and the policy file play.
                .packed_weights = self.host.judged,
                .feature_count = self.host.z.len,
                .root_target = self.options.root_target,
                .hidden_width = self.host.hidden1.len,
                .action_count = self.host.raw.len,
                .normalizer = self.norm,
                .filter = self.options.filter,
                .stiffness_count = self.host.raw.len - track.actionSize(self.fleet.m),
                .stiffness_filter = self.options.stiffness_filter,
                .flow = self.flowPolicyParts(),
            };
        }

        /// The flow as the policy file keeps it (`FlowPolicyParts`): its weights as the CPU last saw them - what the
        /// judge's own actor samples from (`HostPolicy.correctedRowOf`). Null without a flow.
        fn flowPolicyParts(self: *const Self) ?FlowPolicyParts {
            const flow_actor: kit_mod.FlowActor(M) = self.host.flow orelse return null;
            const parts: FlowPolicyParts = .{
                .layers = flow_actor.flow.network.layers,
                .parameters = self.host.flow_mirror,
                .euler_steps = flow_actor.flow.options.euler_steps,
                .time_frequencies = flow_actor.flow.options.time_frequencies,
                .synergies = self.host.synergies,
            };
            return parts;
        }

        /// The JUDGE's actor: the policy's MEAN action - no exploration - for every character of the
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
            // The judged fleet's action is the learner's own: its limbs' stiffnesses after the offsets where the
            // learner's policy gives them.
            const same_action: bool = fleet.action_width == per_character;
            assertf(same_action, @src(), "a judged fleet of actions {d} wide, the learner's are {d}", .{
                fleet.action_width,
                per_character,
            });
            const offset_count: usize = track.actionSize(fleet.m);
            for (0..fleet.options.envs) |env| {
                self.featuresOf(fleet, env);
                // The judged character's slot holds the action it was given last (at rest when its judgement began):
                // the action applied before this decision, which the policy reads.
                const slot: []f32 = actions[env * per_character ..][0..per_character];
                self.host.applied = slot;
                // Judged: the policy, with a flow's typical correction - from zero noise, nothing drawn.
                // The judged weights: the slow average where the learner keeps one.
                if (self.kit.flow_actor != null) {
                    @memset(self.flow_start_noise, 0);
                    self.host.correctedRowOf(self.host.judged, self.flow_start_noise);
                } else {
                    self.host.policyRowOf(self.host.judged);
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
        /// buffer, when the readback reaches them - a frame or so old on a GPU, which a log of rounds does not mind -
        /// and the readback's generation with it (`device_stats_mirrored`): which submissions the numbers reflect.
        pub fn refreshDeviceStats(self: *Self) void {
            const readback: []const f32 = self.kit.pipe.readLatest(.params) orelse return;
            const stats_floats: u32 = kit_mod.DeviceStats.floats;
            const stats_end: usize = self.stats_at + stats_floats;
            if (readback.len < stats_end) {
                return;
            }
            const stats_numbers: []const f32 = readback[self.stats_at..stats_end];
            self.device_stats = bytesToValue(kit_mod.DeviceStats, sliceAsBytes(stats_numbers));
            // Read after the readback: the generation of the very mirror the numbers were copied from.
            self.device_stats_mirrored = self.kit.pipe.readGeneration().mirrored;
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

        /// Whether the hazard can be measured (`characterHazard`): it reads the head's height and the up direction
        /// against the barrier's margins, so the task needs a head body and the margins must be above zero.
        fn measuresHazard(self: *const Self) bool {
            const has_head: bool = self.fleet.head != null;
            const barrier: kit_mod.FailureBarrier = self.options.barrier;
            const margins_positive: bool = barrier.head_margin > 0 and barrier.tilt_margin > 0;
            return has_head and margins_positive;
        }

        /// The planning hazard (`planningHazard`) of whatever `z` and `goal` hold (`features`): how far toward a fall
        /// the character is, as a fraction of the failure barrier's margins. A task that cannot measure it - no head
        /// body, or a barrier without margins (`measuresHazard`) - measures none: 0, its characters never in danger by
        /// it. Planning, which chooses its characters by it, refuses such a task where it reads it (`projectHazard`).
        pub fn characterHazard(self: *const Self) f32 {
            if (!self.measuresHazard()) {
                return 0;
            }
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
            const named_parts: usize = self.kit.param_count + self.kit.policy_count + self.policy_average_count +
                self.world_average_count + self.critic_parameter_count + self.flow_parameter_count +
                self.skip_parameter_count + self.world_statistics_count;
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
                .policy_average_count = self.policy_average_count,
                .world_average_count = self.world_average_count,
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
                .training_rounds = self.training_rounds,
                .random_stream_state = self.rng.s,
                .phase_two_began = @intFromBool(self.phase_two_began_hours != null),
                .phase_two_began_hours = self.phase_two_began_hours orelse 0,
                .push_top_share = self.fleet.push_top.share,
                .world_statistics_count = self.world_statistics_count,
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
                const statistics_end: u32 = self.input_moments_at + self.world_statistics_count;
                const in_statistics: bool = index >= self.input_moments_at and index < statistics_end;
                if (in_statistics) {
                    return "the world model's running statistics";
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

        /// Waits until the newest readback has landed: the parameters and the device's numbers of the last
        /// submission, for a program without frames - before a save, a judgement, or acting from plans. The wait is
        /// counted in the round's phase the host is in, where a trainer keeps a clock (`phase_clock`).
        pub fn waitForReadback(self: *Self) void {
            const wait_began_ms: f64 = wgpu.nowMs();
            while (true) {
                const holds_a_readback: bool = self.kit.pipe.readLatest(.params) != null;
                if (holds_a_readback and self.isReadbackCurrent()) {
                    break;
                }
            }
            // A wait for the device, in the phase the host is in.
            if (self.phase_clock) |clock| {
                clock.addWait(wgpu.nowMs() - wait_began_ms);
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
                saved.skip_parameter_count == own.skip_parameter_count and
                saved.policy_average_count == own.policy_average_count and
                saved.world_average_count == own.world_average_count and
                saved.world_statistics_count == own.world_statistics_count;
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
            // The pushes' top is a share of their range: a NaN fails both comparisons.
            const is_top_a_share: bool = saved.push_top_share >= 0 and saved.push_top_share <= 1;
            if (!is_top_a_share) {
                return "numbers.push_top_share: from 0 to 1";
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
            // The inputs' affine and the kit's change statistics from the moments as they were saved.
            self.writeWorldStatistics();
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
            self.training_rounds = saved.training_rounds;
            self.rng.s = saved.random_stream_state;
            self.phase_two_began_hours = if (saved.phase_two_began != 0) saved.phase_two_began_hours else null;
            // The pushes' top as far open as it was, its clock starting again at the hours the program tells first.
            self.fleet.push_top = .resumedAt(saved.push_top_share);
            // The trust in the critic the restored updates have earned, before anything is planned or trained.
            self.applyCriticTrust();
        }
    };
}
