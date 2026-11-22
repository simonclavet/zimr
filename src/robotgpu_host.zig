//! robotgpu_host.zig - THE SIMULATOR'S HOST SIDE: one robot.zig model's worlds, on a GPU or on the CPU twin - packed
//! and uploaded once, stepped by the step program, and read back without ever waiting for the GPU.
//!
//! -- A SIM AND ITS STEPS --
//!
//! A `Sim` owns a pipe - robotgpu's kernels on a device, or the same kernels run as a loop on the CPU - and what a step
//! needs to know about the model: its counts and the layout of every array. Creating one packs the model into images
//! of the two model arenas and uploads them; after that a step is a single batch of dispatches:
//!
//!     host:   submitStep ... other work ... requestOverflow ... other work ... collect? -> each world's overflow word
//!     GPU:            [ the step program's dispatches ]   [ the copy back ]
//!
//! Nothing here waits for the GPU: a step is submitted and returns, and what the host wants back is REQUESTED and
//! COLLECTED later (`RangeRequest`) - at once natively if the caller likes, a frame later in a browser, where a copy
//! finishes only once control returns to the page. So the same `Sim` serves the native host and the web.
//!
//! -- THE STEP PROGRAM --
//!
//! A step is a fixed list of dispatches (`robotgpu.step_program`), each a kernel and HOW MANY INVOCATIONS it runs as a
//! rule the counts turn into a number - one per world, one per world and body, one per world and branch - so the same
//! program serves every model and any number of worlds.
//!
//! -- THE TRACKING TASK: A DECISION, THEN ITS OBSERVATION --
//!
//! A tracking simulator is made with its clips (`initGpuTracking`, `initTwinTracking`), each clip's poses and - where
//! its worlds are observed - the reference's half of the observation at every frame. Each world follows a clip from a
//! frame (`setWorldClip`); the servo's law, the floor, the action's scale and filter and the limbs' stiffness are set
//! for every world (`setServo`, `setFloor`, `setActionScale`, `setActionFilter`, `setLimbStiffness`). Then, once a
//! decision:
//!
//!     host:   each world's action uploaded           `uploadWorldArray("actions", world, action)`
//!             the decision submitted                 `submitDecision(physics_steps)`: for each physics step the
//!                                                    filter and the servo's targets, the step, the clip's frame
//!             the decision's end submitted           `submitDecisionEnd`: each world's observation, then its
//!                                                    tracking error, rewards and episode
//!     GPU:    [ the decision's dispatches ][ the observation's ]      read back later, never waited on
//!
//! -- EACH WORLD ITS OWN STATE --
//!
//! Every world starts as the model's rest state. A caller gives a world its own - its joint coordinates, its joint
//! velocities, any other array of its state - by uploading that world's numbers of the array (`Sim.uploadWorldArray`)
//! before the steps that should see them. That is how a test poses each world differently, and how a page shows many
//! worlds doing many things.
//!
//! -- THE DEVICE AGAINST THE TWIN --
//!
//! The twin runs the kernels on the CPU, and where robot.zig has a function for a piece of the physics the kernels call
//! that very function, so the twin matches the CPU engine to the bit. The device cannot: a GPU's division and square
//! root are allowed to round a few units in the last place differently, and mobile GPUs use that freedom. So the device
//! is COMPARED with the twin (`StepComparison`), and the difference is measured against the size of the quantity it
//! belongs to - an inertia as a whole, a velocity as a whole, the mass matrix world by world - in units of float
//! precision, epsilons (`largestGapEpsilons`):
//!
//!     an inertia     [ 52.1   0.0004   -0.0002   12.3 ... ]          its scale: 52.1, its largest entry
//!     the gap        |device - twin| / (epsilon * scale)             the largest over every quantity
//!
//! Each array has a bar (`step_array_bars`). Most of the step comes within a few epsilons; the factor of the mass
//! matrix and what is solved with it come less close, because a factorisation carries the matrix's conditioning - a
//! small error in M can grow by up to its condition number. A kernel that computed the wrong thing misses by thousands
//! of epsilons, far beyond any bar.

const std = @import("std");
const z = @import("zimr");
const robot = @import("robot");
const eql = std.mem.eql;
const robotgpu = @import("robotgpu");
const zm = @import("zm");
const assertf = zm.assertf;
const float = zm.float;
const Random = std.Random;
const clamp = zm.clamp;
const inf = zm.inf;
const isFinite = zm.isFinite;
const isNan = zm.isNan;
const indexOfScalar = std.mem.indexOfScalar;

const Allocator = std.mem.Allocator;
const sortSlice = std.mem.sort;
const wgpu = z.wgpu;
const track = z.robot_track;

/// The pipe that runs robotgpu's kernels: on a device, or as the CPU twin.
pub const Pipe = z.Compute(robotgpu);

/// One array the step writes, how many of its numbers share one scale when its gap is measured
/// (`largestGapEpsilons`) - one for a scalar, an item's width for a vector, a motion or an inertia, zero for a world's
/// whole block (the mass matrix) - and how close the device must come to the twin in it, in epsilons at that scale.
pub const StepArrayBar = struct {
    name: [:0]const u8,
    numbers_sharing_scale: u32,
    bar_epsilons: f32,
    /// When the step writes the array: always, or only for a model with damping - the damped velocity update's arrays.
    /// An array the step leaves unwritten holds whatever its buffer held, and is not compared.
    written: Written = .always,

    pub const Written = enum { always, when_damped };
};

/// THE GAP BETWEEN ONE NUMBER OF THE DEVICE'S AND THE TWIN'S, as a multiple of `unit` (`zm.gapInUnits`, the one rule
/// every check measures its gaps by): the device's number measured, the twin's its reference - a number that is not
/// finite infinitely far from every number but itself, so a NaN cannot hide under `@max`.
pub const gapInUnits = zm.gapInUnits;

/// THE GAP BETWEEN THE DEVICE'S NUMBERS AND THE TWIN'S, in epsilons - each difference measured against the size of the
/// quantity it belongs to, not of the number alone. A vector, a motion or an inertia is judged as a whole: an error
/// that is small beside the inertia's large diagonal is small, even where it falls on a component close to zero. So
/// the numbers go in groups of `numbers_sharing_scale` (zero: the whole of `numbers`, one world's block), and each
/// group's scale is its largest finite magnitude on the twin, at least 1:
///
///     group            [ 52.1   0.0004   -0.0002   12.3 ]           scale 52.1
///     gap of a number  |device - twin| / (epsilon * scale)          the largest over every group returned
///
/// A number that is not finite sets no scale, and is as far as can be from every number but itself (`gapInUnits`):
/// the gap returned is then infinite.
pub fn largestGapEpsilons(
    device_numbers: []const f32,
    twin_numbers: []const f32,
    numbers_sharing_scale: u32,
) f32 {
    // f32's epsilon, 2^-23: the gap between 1 and the next float.
    const epsilon: f32 = 0x1p-23;
    const group_length: usize = if (numbers_sharing_scale == 0) twin_numbers.len else numbers_sharing_scale;
    var largest_gap: f32 = 0;
    var group_start: usize = 0;
    while (group_start < twin_numbers.len) : (group_start += group_length) {
        const group_end: usize = @min(group_start + group_length, twin_numbers.len);
        const device_group: []const f32 = device_numbers[group_start..group_end];
        const twin_group: []const f32 = twin_numbers[group_start..group_end];
        // The group's scale. An infinity sets none: against an infinite scale every difference in its group would
        // measure nothing.
        var scale: f32 = 1.0;
        for (twin_group) |twin_number| {
            if (isFinite(twin_number)) {
                scale = @max(scale, @abs(twin_number));
            }
        }
        const epsilon_at_scale: f32 = epsilon * scale;
        for (device_group, twin_group) |device_number, twin_number| {
            const gap: f32 = gapInUnits(device_number, twin_number, epsilon_at_scale);
            largest_gap = @max(largest_gap, gap);
        }
    }
    return largest_gap;
}

/// THE STEP'S ARRAYS - every array the step program writes - and the bar each is held to when the device is compared
/// with the twin. The twin matches robot.zig to the bit; the device differs where its arithmetic rounds differently in
/// the last bit - a GPU's division and square root are allowed a few units in the last place, and a GPU may fuse a
/// multiply and an add into a single rounding - and the difference is measured against the size of each quantity
/// (`largestGapEpsilons`): a vector, a motion or an inertia as a whole, the mass matrix, its factor and the
/// acceleration world by world. The largest gaps over Geno's 64 worlds after one step, in epsilons:
///
///                                              lavapipe   RTX 5070   bar
///     poses, the floor's contacts, the frame,  8.3        16.0       256    a few roundings each; the bar is about
///     the mass matrix
///                                                                           3e-5 of a quantity's size - room for a
///                                                                           phone's GPU, while a wrong kernel misses
///                                                                           by thousands
///     the velocities and the forces            22.7       25.1       256    the same, a few roundings deeper
///     the factor, its pivots, the solve        239        230        1024   a factorisation carries the matrix's
///                                                                           conditioning: an input error of a few
///                                                                           epsilons can grow by up to its condition
///                                                                           number
///     the velocity update                      67.4       115        1024   a second factorisation, of M + dt D
///     the advance                              0.5        1.0        1024   each coordinate moves by dt x its rate,
///                                                                           and carries dt x the rate's error
pub const step_array_bars = [_]StepArrayBar{
    .{ .name = "body_positions", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "body_orientations", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "body_centres_of_mass", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "joint_anchors", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "joint_axes", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "geom_positions", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "geom_orientations", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "floor_slot_positions", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "floor_slot_distances", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "floor_slot_first_tangents", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "floor_slot_second_tangents", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "site_positions", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "site_orientations", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "subtree_centres_of_mass", .numbers_sharing_scale = 4, .bar_epsilons = 256 },
    .{ .name = "dof_axes", .numbers_sharing_scale = 8, .bar_epsilons = 256 },
    .{ .name = "body_inertias", .numbers_sharing_scale = 16, .bar_epsilons = 256 },
    .{ .name = "mass_matrix", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "composite_inertias", .numbers_sharing_scale = 16, .bar_epsilons = 256 },
    .{ .name = "body_velocities", .numbers_sharing_scale = 8, .bar_epsilons = 256 },
    .{ .name = "dof_axis_rates", .numbers_sharing_scale = 8, .bar_epsilons = 256 },
    .{ .name = "body_bias_accelerations", .numbers_sharing_scale = 8, .bar_epsilons = 256 },
    .{ .name = "subtree_bias_forces", .numbers_sharing_scale = 8, .bar_epsilons = 256 },
    .{ .name = "bias_joint_forces", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "passive_joint_forces", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "actuator_lengths", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "actuator_velocities", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "activation_rates", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "actuator_forces", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "actuator_joint_forces", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "smooth_joint_forces", .numbers_sharing_scale = 0, .bar_epsilons = 256 },
    .{ .name = "mass_factor", .numbers_sharing_scale = 0, .bar_epsilons = 1024 },
    .{ .name = "mass_factor_inverse_diagonal", .numbers_sharing_scale = 0, .bar_epsilons = 1024 },
    .{ .name = "smooth_joint_accelerations", .numbers_sharing_scale = 0, .bar_epsilons = 1024 },
    .{ .name = "joint_accelerations", .numbers_sharing_scale = 0, .bar_epsilons = 1024 },
    .{
        .name = "velocity_changes",
        .numbers_sharing_scale = 0,
        .bar_epsilons = 1024,
        .written = .when_damped,
    },
    .{
        .name = "damped_mass_factor",
        .numbers_sharing_scale = 0,
        .bar_epsilons = 1024,
        .written = .when_damped,
    },
    .{
        .name = "damped_mass_factor_inverse_diagonal",
        .numbers_sharing_scale = 0,
        .bar_epsilons = 1024,
        .written = .when_damped,
    },
    .{ .name = "joint_velocities", .numbers_sharing_scale = 0, .bar_epsilons = 1024 },
    .{ .name = "activations", .numbers_sharing_scale = 0, .bar_epsilons = 1024 },
    .{ .name = "joint_positions", .numbers_sharing_scale = 0, .bar_epsilons = 1024 },
};

/// The numbers an arena holds, from its declaration in `robotgpu.Buffers`.
fn arenaLength(comptime arena: robotgpu.Arena) usize {
    return @typeInfo(@FieldType(robotgpu.Buffers, @tagName(arena))).array.len;
}

/// A device whose workgroup memory cannot hold Newton's working set (`robotgpu.newton_workgroup_bytes`), refused
/// before any pipeline is made, when `kernels` holds `newton_solve` - rather than a pipeline failing later, which on
/// the web is reported only asynchronously.
fn refuseSmallWorkgroupMemory(
    device: wgpu.DeviceHandle,
    kernels: []const Pipe.KernelWgsl,
) error{WorkgroupMemoryTooSmall}!void {
    const holds_newton: bool = for (kernels) |kernel| {
        if (eql(u8, kernel.name, "newton_solve")) {
            break true;
        }
    } else false;
    if (!holds_newton) {
        return;
    }
    const granted: u32 = wgpu.workgroupStorageLimit(device);
    if (granted < robotgpu.newton_workgroup_bytes) {
        std.log.err("robotgpu: the device grants {d} bytes of workgroup memory; Newton needs {d}", .{
            granted,
            robotgpu.newton_workgroup_bytes,
        });
        return error.WorkgroupMemoryTooSmall;
    }
}

/// Each world's moment as a learner's books take it (`robotgpu.recordMomentOf`): whether its next record starts a
/// stretch, its step in its episode, whether it is after the loss and whether the decision before it failed, and the
/// reference frame and clip it tracks - from a
/// simulator's world integers, read whole, as its last decision left them. The worlds from `first_world` on, one a
/// moment. With planners, `plan_decision` is the decision of the plans the worlds are at - the decisions since the
/// replan - and a world's record is LABELLED where it follows its plan there (`robotgpu.followsPlanAt`), by its
/// `plan_following`, and BEGINS ITS PLAN where that is the replan's own decision; without planners (null), no record
/// is either.
pub fn recordMomentsFrom(
    counters: robotgpu.WorldIntegersLayout,
    first_world: u32,
    integers: []const u32,
    plan_decision: ?u32,
    out_moments: []robot.RecordMoment,
) void {
    for (out_moments, 0..) |*moment, moment_index| {
        const world: u32 = first_world + @as(u32, @intCast(moment_index));
        const flags_at: u32 = counters.episode_flags.at(world, 0);
        const episode_steps_at: u32 = counters.episode_steps.at(world, 0);
        const aftermath_steps_left_at: u32 = counters.aftermath_steps_left.at(world, 0);
        const flags: u32 = integers[flags_at];
        const episode_steps: u32 = integers[episode_steps_at];
        const aftermath_steps_left: u32 = integers[aftermath_steps_left_at];
        const is_replan_decision: bool = plan_decision == 0;
        const labelled: bool = if (plan_decision != null) labelled: {
            const following: u32 = integers[counters.plan_following.at(world, 0)];
            break :labelled robotgpu.followsPlanAt(following, is_replan_decision);
        } else false;
        moment.* = robotgpu.recordMomentOf(flags, episode_steps, aftermath_steps_left);
        moment.labelled = labelled;
        moment.begins_plan = labelled and is_replan_decision;
        // The frame and clip the next record tracks, as the decision's resets left them: a policy's start is drawn
        // only where a horizon of its clip follows (`robot_track.Replay.Books.sampleStart`).
        moment.frame = integers[counters.world_frame.at(world, 0)];
        moment.clip = @intCast(integers[counters.world_clip.at(world, 0)]);
    }
}

/// WHAT A TRAINER's DECISIONS ON A DEVICE REPORT BESIDE ITS COUNTS, summed over the decisions counted
/// (`countTrainerDecisions`): the pushes given and their speeds' sum, the returns to the reference and their lengths
/// in decisions, and the watched pushes ended - kept, returned or failed - with those the worlds came back from
/// (`robot.PushBrake`).
pub const DeviceEvents = struct {
    pushes: u64 = 0,
    push_speed_sum: f64 = 0,
    returns: u64 = 0,
    return_decisions: u64 = 0,
    watched_pushes_settled: u64 = 0,
    watched_pushes_came_back: u64 = 0,
};

/// THE DECISION A READ OF THE WORLDS' FLAGS REPORTS, as its pushes were drawn: the number its draws were made at, the
/// run's draw seed, the speeds' range - its two ends and how far it was open - and the share of it whose pushes are
/// watched. The host makes each pushed world's speed draw again (`robot.drawUniform`, `robot.pushSpeed`): what the
/// world was pushed with, without reading it back.
pub const CountedDecision = struct {
    number: u32,
    draw_seed: u32,
    push_speed_min: f32,
    push_speed_max: f32,
    push_top_share: f32,
    push_watched_share: f32,

    /// The decision numbered `number`, with the pushes' settings as the simulator's uniform holds them.
    pub fn of(
        number: u32,
        options: robotgpu.StepOptions,
        push_top_share: f32,
    ) CountedDecision {
        const counted: CountedDecision = .{
            .number = number,
            .draw_seed = options.draw_seed,
            .push_speed_min = options.push_speed_min,
            .push_speed_max = options.push_speed_max,
            .push_top_share = push_top_share,
            .push_watched_share = options.push_watched_share,
        };
        return counted;
    }
};

/// EACH WORLD's DECISION IN A TRAINER's COUNTS (`Resident.countDecision`), from the world's flags as the decision
/// left them - `lost`, `in_aftermath` - and the clip it was on DURING the decision, `clips_during`: a restart at
/// the decision's end has already put the world on its next clip, so the clip is read before the decision runs.
/// Acted without exploration, the decisions are the policy being judged, and counted apart. The decision's pushes
/// and returns join `events` (`DeviceEvents`), from the same flags, and each watched push that ended is told to the
/// trainer's fleet, whose top the brake holds (`Fleet.noteWatchedPush`). `counted` is the decision the flags are
/// of: a pushed world's speed is drawn again at its number, and a watched push whose draw falls outside the watched
/// share stops the program - the flags were then counted under another decision's number. A world whose record of
/// the decision was labelled in `counted_moments` - a planner whose action was its plan's (`recordMomentsFrom`) - is
/// counted again in the teacher's own counts (`Resident.countPlannerDecision`).
pub fn countTrainerDecisions(
    comptime M: type,
    trainer: *z.robot_track_resident.Resident(M),
    counters: robotgpu.WorldIntegersLayout,
    first_world: u32,
    integers: []const u32,
    clips_during: []const u32,
    counted_moments: []const robot.RecordMoment,
    judged: bool,
    counted: CountedDecision,
    events: *DeviceEvents,
) void {
    for (clips_during, counted_moments, 0..) |clip, moment, character_index| {
        const world: u32 = first_world + @as(u32, @intCast(character_index));
        const flags_at: u32 = counters.episode_flags.at(world, 0);
        const flags: u32 = integers[flags_at];
        const lost: bool = flags & robotgpu.episodeFlagBit(.lost) != 0;
        const in_aftermath: bool = flags & robotgpu.episodeFlagBit(.in_aftermath) != 0;
        trainer.countDecision(clip, lost, in_aftermath, judged);
        // The teacher's own: a decision whose action was its plan's - its record labelled. A planner acting from
        // the policy, between its replans or after a plan that did not teach, counts among everyone alone.
        if (moment.labelled) {
            trainer.countPlannerDecision(lost, in_aftermath, judged);
        }
        const pushed: bool = flags & robotgpu.episodeFlagBit(.pushed) != 0;
        if (pushed) {
            const speed_draw: f32 = robot.drawUniform(counted.draw_seed, world, counted.number, .push_speed, 0);
            // THE HOST's DRAW IS THE DEVICE's. A world just pushed that is now watched was given a push in the
            // watched share of the range (`robot.drawPush`), so the draw made again here - at the number this read
            // is counted under - falls there too. Both sides compute it exactly: the hash is integer arithmetic,
            // its 24 bits are exact in a float, and the share's bound is one correctly rounded subtraction. A draw
            // below the bound was therefore made at another decision's number.
            const now_watched: bool = integers[counters.watched_push_left.at(world, 0)] > 0;
            const watched_from: f32 = 1.0 - counted.push_watched_share;
            const draw_is_the_pushs: bool = !now_watched or speed_draw >= watched_from;
            assertf(draw_is_the_pushs, @src(), "world {d}'s watched push, counted at decision {d}: a draw of {d}", .{
                world,
                counted.number,
                speed_draw,
            });
            const speed: f32 = robot.pushSpeed(
                counted.push_speed_min,
                counted.push_speed_max,
                counted.push_top_share,
                speed_draw,
            );
            events.pushes += 1;
            events.push_speed_sum += speed;
        }
        const returned: bool = flags & robotgpu.episodeFlagBit(.returned) != 0;
        if (returned) {
            events.returns += 1;
            events.return_decisions += integers[counters.return_lengths.at(world, 0)];
        }
        const watched_push_settled: bool = flags & robotgpu.episodeFlagBit(.watched_push_settled) != 0;
        if (watched_push_settled) {
            const came_back: bool = flags & robotgpu.episodeFlagBit(.watched_push_came_back) != 0;
            events.watched_pushes_settled += 1;
            events.watched_pushes_came_back += @intFromBool(came_back);
            trainer.fleet.noteWatchedPush(came_back);
        }
    }
}

/// A PLAN's ACTION AT DECISION `decision`, on the host - the line `robotgpu.follow_plans` draws on the device: the
/// knots spread evenly over `horizon` decisions, the action at d on the straight line between the two knots around
/// position d (K - 1) / H, held at the last knot past the horizon. `knots` is the plan, knot after knot, each the whole
/// action (`action_count` numbers).
pub fn planActionAt(
    knots: []const f32,
    knot_count: u32,
    action_count: u32,
    horizon: f32,
    decision: f32,
    out_action: []f32,
) void {
    assertf(knot_count >= 2, @src(), "planActionAt: a plan of {d} knots - a plan is a line", .{knot_count});
    const last_knot: f32 = float(knot_count - 1);
    const knot_position: f32 = decision * last_knot / horizon;
    const clamped_position: f32 = clamp(knot_position, 0, last_knot);
    const knot_at_or_before: u32 = @trunc(clamped_position);
    const lower_knot: u32 = @min(knot_at_or_before, knot_count - 2);
    const share_of_upper: f32 = clamped_position - float(lower_knot);
    for (out_action, 0..) |*action, number| {
        const at_lower: f32 = knots[lower_knot * action_count + number];
        const at_upper: f32 = knots[(lower_knot + 1) * action_count + number];
        action.* = at_lower + share_of_upper * (at_upper - at_lower);
    }
}

/// THE WARM START: the previous plan moved `shift` decisions on - a replan comes `shift` decisions after the plan it
/// replaces, so what that plan meant for then is where the new one starts. Each new knot takes the previous plan's
/// action at its own time plus the shift, the last knot's held past the previous horizon.
///
///     previous    k0 -------- k1 -------- k2                       K = 3, H = 8, shift 4
///     decision    0     2     4     6     8    10    12
///     warm start              k0 -------- k1 -------- k2 (held at the previous k2)
pub fn shiftedPlan(
    previous: []const f32,
    knot_count: u32,
    action_count: u32,
    horizon: f32,
    shift: f32,
    out_knots: []f32,
) void {
    const knot_spacing: f32 = horizon / float(knot_count - 1);
    var knot: u32 = 0;
    while (knot < knot_count) : (knot += 1) {
        const knot_time: f32 = float(knot) * knot_spacing;
        const time_in_previous: f32 = knot_time + shift;
        const knot_action: []f32 = out_knots[knot * action_count ..][0..action_count];
        planActionAt(previous, knot_count, action_count, horizon, time_in_previous, knot_action);
    }
}

/// How a replan draws its candidates: a run's setting, defined with the task's others (`robot.PlanDrawing`).
pub const PlanDrawing = robot.PlanDrawing;

/// A CANDIDATE DRAWN ABOUT THE WARM START: `out_plan` is `warm_start` (a plan: knot after knot, each the whole action
/// of `action_count` numbers) plus a normal draw at every knot and number. The knots are joined by straight lines, so
/// noise drawn independently at each knot is already a smooth path between them. An action's numbers are in units of
/// `action_scale` radians (the servo's scale): the drawing's radians are divided by it. The offsets are the first
/// `offset_count` numbers of an action, each kept within the reach; the limbs' stiffnesses follow them.
pub fn drawPlanAbout(
    random: Random,
    warm_start: []const f32,
    action_count: u32,
    offset_count: u32,
    action_scale: f32,
    drawing: PlanDrawing,
    out_plan: []f32,
) void {
    const offset_noise: f32 = drawing.offset_noise_radians / action_scale;
    const offset_reach: f32 = drawing.offset_reach_radians / action_scale;
    for (out_plan, warm_start, 0..) |*number, warm_number, at| {
        const number_in_action: usize = at % action_count;
        const is_offset: bool = number_in_action < offset_count;
        const noise_scale: f32 = if (is_offset) offset_noise else drawing.stiffness_noise;
        const drawn: f32 = warm_number + noise_scale * random.floatNorm(f32);
        number.* = if (is_offset) clamp(drawn, -offset_reach, offset_reach) else drawn;
    }
}

/// A MODEL PLAN AS A PHYSICS PLAN's KNOTS (the funnel, `Planning.seeds`): the model planner's chosen plan for a
/// character - `model_plan`, its corrections step by step [step][action], each step `spans[step]` decisions long - as
/// the knots of a physics plan around the policy, `knot_count` knots over `horizon` decisions from the replan. The
/// model plan was decided one decision before the replan, so the physics plan's decision t is the model plan's t + 1;
/// a knot takes the correction of the model step that covers its decision, the last step's past the model plan's end:
///
///     model plan     steps of 1, 1, 4, 4 decisions: c0 c1 c2 c2 c2 c2 c3 c3 c3 c3        (decisions 0 .. 9)
///     replan         one decision later; knots at decisions 0, 4, 8 of 8  ->  model decisions 1, 5, 9  ->  c1 c2 c3
pub fn modelPlanAsKnots(
    model_plan: []const f32,
    spans: []const u32,
    action_count: u32,
    knot_count: u32,
    horizon: u32,
    out_knots: []f32,
) void {
    const step_count: usize = spans.len;
    assertf(model_plan.len == step_count * action_count, @src(), "a model plan of {d} numbers for {d} steps", .{
        model_plan.len,
        step_count,
    });
    const knot_spacing: f32 = float(horizon) / float(knot_count - 1);
    var knot: u32 = 0;
    while (knot < knot_count) : (knot += 1) {
        // The knot's decision, one decision on in the model plan's time.
        const knot_decision: u32 = @trunc(float(knot) * knot_spacing + 0.5);
        const model_decision: u32 = knot_decision + 1;
        // The model step covering it: the last whose start is at or before it.
        var covering_step: usize = 0;
        var step_start: u32 = 0;
        for (spans, 0..) |span, step| {
            if (step_start > model_decision) {
                break;
            }
            covering_step = step;
            step_start += span;
        }
        const correction: []const f32 = model_plan[covering_step * action_count ..][0..action_count];
        @memcpy(out_knots[knot * action_count ..][0..action_count], correction);
    }
}

/// THE CHARACTERS IN MOST TROUBLE: the indices of the `out_chosen.len` largest of `troubles`, in increasing order - of
/// equal troubles the earlier first, and a trouble that is not a number (a world whose physics failed) behind every
/// other. One pass a choice over every trouble: a few planners among a thousand characters is a few thousand
/// comparisons, once a replan.
///
///     troubles   0.1  0.9  0.4  0.9  0.2        two chosen
///     chosen     1, 3                            the two at 0.9
pub fn mostInTrouble(troubles: []const f32, out_chosen: []u32) void {
    assertf(out_chosen.len <= troubles.len, @src(), "{d} chosen of {d}", .{ out_chosen.len, troubles.len });
    for (out_chosen, 0..) |*chosen, choice| {
        var best_index: ?u32 = null;
        var best_trouble: f32 = -inf(f32);
        for (troubles, 0..) |trouble, index_usize| {
            const index: u32 = @intCast(index_usize);
            const already_chosen: bool = indexOfScalar(u32, out_chosen[0..choice], index) != null;
            if (already_chosen) {
                continue;
            }
            // Not a number ranks behind -inf: taken only when nothing else is left.
            const usable: f32 = if (isNan(trouble)) -inf(f32) else trouble;
            const beats: bool = best_index == null or usable > best_trouble;
            if (beats) {
                best_index = index;
                best_trouble = usable;
            }
        }
        chosen.* = best_index.?;
    }
    sortSlice(u32, out_chosen, {}, std.sort.asc(u32));
}

/// WHERE THE TOP SHARE BEGINS in `held` numbers sorted from the lowest up: the index of the lowest of the top `share`
/// of them - at least one of them, all of them at a share of 1. Ten at 0.4: the top four, from index 6.
pub fn topShareStart(held: usize, share: f32) usize {
    assertf(held > 0 and share > 0 and share <= 1, @src(), "the top {d} of {d}", .{ share, held });
    const below_share: f32 = (1.0 - share) * float(held);
    const start: usize = @trunc(below_share);
    return @min(start, held - 1);
}

/// THE BEST OF A PLANNER's CANDIDATES: the index, in its block of scores, of the highest - the first of them on a
/// tie, so the warm start (the block's first) is kept when no drawn candidate beats it. A score that is not a number
/// - a candidate whose physics failed - is never the best.
pub fn bestInBlock(block_scores: []const f32) usize {
    var best_index: usize = 0;
    var best_score: f32 = -inf(f32);
    for (block_scores, 0..) |score, index| {
        const is_number: bool = !isNan(score);
        const beats_the_best: bool = is_number and score > best_score;
        if (beats_the_best) {
            best_index = index;
            best_score = score;
        }
    }
    return best_index;
}

/// How a trainer's planners plan - their candidates, their replan interval, how often a plan is followed whole, the
/// drawing: a run's settings, defined with the task's others (`robot.PlanningOptions`).
pub const PlanningOptions = robot.PlanningOptions;

/// THE PLANNERS AND THEIR PLANS, kept on the host between replans (`Sim.replan`). Each planner is a character's world;
/// its candidates are a block of the batch's first worlds, `candidates_per_planner` of them, planner after planner -
/// every planner after them all:
///
///     world     0  1  2  3 | 4  5  6  7 | 8  9  10 11 12 13 14 15        2 planners of 4 candidates
///               candidates of planner 9 | of planner 11 | characters (planners 9 and 11 among them)
///
/// A plan is the simulator's plan shape (`robotgpu.Counts.plan_knot_count` knots over `plan_horizon` decisions) of
/// the action's numbers - the whole action, or an offset around the policy's (`form`). The buffers are the struct's
/// own, allocated by `init` from the `gpa` it is given and freed by `deinit`.
///
/// THE PLANNERS MAY CHANGE (`replacePlanners`): the candidates' worlds are a block for each of the planners `init` is
/// given, and fewer may plan - the first `planner_count` of `planner_worlds`, each with the block of its place. A
/// replan runs their blocks alone; the blocks after them wait (`candidateCount`, `candidateCapacity`).
pub const Planning = struct {
    /// The planners, in their blocks' order: the first `planner_count` plan (`planners`); the room is one a block.
    planner_worlds: []u32,
    planner_count: u32,
    /// Each planner's plan, planner after planner.
    plans: []f32,
    /// What the plans' numbers are (`robot.PlanForm`): whole actions from `init`, offsets around the policy once
    /// `planAroundPolicy` has made them so. The simulator is told at each replan (`Sim.setPlanForm`).
    form: robot.PlanForm,
    /// THE FUNNEL's SEEDS, for the next replan around the policy: a plan a planner, in the planners' order, and
    /// whether each has one - the model planner's chosen plan for that character (`modelPlanAsKnots`). A seeded
    /// planner's candidates are its warm start, the policy itself (a plan of zeros, every planner's around the
    /// policy), its seed, then the drawn: the physics refines what the model screened. Set by the caller before
    /// `Sim.beginReplan`, which consumes them.
    seeds: []f32,
    seeded: []bool,
    /// WHICH PLANS TEACH (`judgePlans`): each planner's, from the last replan on; and the window of the last plans'
    /// advantages over their baseline - its numbers, how many it holds, where the next goes - with room to sort them
    /// for the threshold.
    teaches: []bool,
    plan_advantages: []f32,
    advantages: []f32,
    advantage_count: u32,
    advantage_next: u32,
    advantages_sorted: []f32,
    /// THE TEACHER's RUNNING TOTALS, for the log (a trainer's `RoundTotals`): the plans judged against their baseline,
    /// those that taught, and their advantages' sum - since the planning began.
    judged_plans: u64 = 0,
    teaching_plans: u64 = 0,
    advantage_sum: f64 = 0,
    /// A REPLAN's WORK: every candidate's knots, laid out as the device holds a world's (a block of `knot_stride`
    /// numbers, the plan padded to four), candidate after candidate - so one write gives them to the first worlds;
    /// every candidate's score, read back; and the copy table, each world's source or null.
    candidate_knots: []f32,
    candidate_scores: []f32,
    copy_sources: []?u32,
    /// The plan's shape: `knot_count` knots of `action_count` numbers - `plan_numbers` in all - over `horizon`
    /// decisions; and a world's block of knots on the device.
    knot_count: u32,
    action_count: u32,
    plan_numbers: u32,
    horizon: u32,
    knot_stride: u32,
    /// The task's action: its first `offset_count` numbers the joints' offsets, in units of `action_scale` radians.
    offset_count: u32,
    action_scale: f32,
    options: PlanningOptions,

    /// The planning of a simulator of `counts` and `layout` - its worlds, its action, its plans' shape (two knots at
    /// least) - for the planners `planner_worlds`, whose action's first `offset_count` numbers are offsets in units of
    /// `action_scale` radians.
    pub fn init(
        gpa: Allocator,
        counts: robotgpu.Counts,
        layout: robotgpu.Layout,
        planner_worlds: []const u32,
        offset_count: u32,
        action_scale: f32,
        options: PlanningOptions,
    ) !Planning {
        const planner_count: usize = planner_worlds.len;
        const candidates_per_planner: u32 = options.candidates_per_planner;
        const candidate_count: u32 = @intCast(planner_count * candidates_per_planner);
        const world_count: u32 = counts.world_count;
        const knot_count: u32 = counts.plan_knot_count;
        const horizon: u32 = counts.plan_horizon;
        assertf(knot_count >= 2 and horizon >= 1, @src(), "a plan of {d} knots over {d} decisions: a plan is a line", .{
            knot_count,
            horizon,
        });
        const action_count: u32 = counts.action_count;
        const plan_numbers: u32 = knot_count * action_count;
        const knot_stride: u32 = layout.world_f.plan_knots.stride;
        // The candidates are the batch's first worlds: every planner after them.
        for (planner_worlds) |planner_world| {
            const after_the_candidates: bool = planner_world >= candidate_count and planner_world < world_count;
            assertf(after_the_candidates, @src(), "planner {d}: candidates take the first {d} of {d} worlds", .{
                planner_world,
                candidate_count,
                world_count,
            });
        }
        const owned_worlds: []u32 = try gpa.dupe(u32, planner_worlds);
        errdefer gpa.free(owned_worlds);
        const plans: []f32 = try gpa.alloc(f32, planner_count * plan_numbers);
        errdefer gpa.free(plans);
        @memset(plans, 0);
        const seeds: []f32 = try gpa.alloc(f32, planner_count * plan_numbers);
        errdefer gpa.free(seeds);
        @memset(seeds, 0);
        const seeded: []bool = try gpa.alloc(bool, planner_count);
        errdefer gpa.free(seeded);
        @memset(seeded, false);
        const teaches: []bool = try gpa.alloc(bool, planner_count);
        errdefer gpa.free(teaches);
        @memset(teaches, false);
        const plan_advantages: []f32 = try gpa.alloc(f32, planner_count);
        errdefer gpa.free(plan_advantages);
        @memset(plan_advantages, 0);
        assertf(options.teach_window > 0, @src(), "a teaching window of no plans", .{});
        const advantages: []f32 = try gpa.alloc(f32, options.teach_window);
        errdefer gpa.free(advantages);
        const advantages_sorted: []f32 = try gpa.alloc(f32, options.teach_window);
        errdefer gpa.free(advantages_sorted);
        // The padding of every candidate's block stays zero, as the device's arena holds it.
        const candidate_knots: []f32 = try gpa.alloc(f32, candidate_count * knot_stride);
        errdefer gpa.free(candidate_knots);
        @memset(candidate_knots, 0);
        const candidate_scores: []f32 = try gpa.alloc(f32, candidate_count);
        errdefer gpa.free(candidate_scores);
        const copy_sources: []?u32 = try gpa.alloc(?u32, world_count);
        errdefer gpa.free(copy_sources);
        // The copy table: each planner's block of candidates its copies, planner after planner.
        @memset(copy_sources, null);
        for (planner_worlds, 0..) |planner_world, planner_index| {
            const first_candidate: usize = planner_index * candidates_per_planner;
            @memset(copy_sources[first_candidate..][0..candidates_per_planner], planner_world);
        }
        return .{
            .planner_worlds = owned_worlds,
            .plans = plans,
            .candidate_knots = candidate_knots,
            .candidate_scores = candidate_scores,
            .copy_sources = copy_sources,
            .knot_count = knot_count,
            .action_count = action_count,
            .plan_numbers = plan_numbers,
            .horizon = horizon,
            .knot_stride = knot_stride,
            .offset_count = offset_count,
            .action_scale = action_scale,
            .options = options,
            .form = .whole_actions,
            .planner_count = @intCast(planner_count),
            .seeds = seeds,
            .seeded = seeded,
            .teaches = teaches,
            .plan_advantages = plan_advantages,
            .advantages = advantages,
            .advantage_count = 0,
            .advantage_next = 0,
            .advantages_sorted = advantages_sorted,
        };
    }

    /// THE PLANS MADE OFFSETS AROUND THE POLICY, from the next replan on (`robot.PlanForm.offsets_around_policy`):
    /// every plan zero - the policy itself - for a whole action's numbers read as an offset would be a plan no search
    /// chose. The first replan around the policy then warm-starts from the policy and draws its candidates about it.
    /// Once: the plans do not go back to whole actions.
    pub fn planAroundPolicy(planning: *Planning) void {
        assertf(planning.form == .whole_actions, @src(), "the plans are offsets around the policy already", .{});
        @memset(planning.plans, 0);
        planning.form = .offsets_around_policy;
        // The window's advantages were over the servo: those over the policy are another measure, begun afresh.
        planning.advantage_count = 0;
        planning.advantage_next = 0;
    }

    pub fn deinit(planning: Planning, gpa: Allocator) void {
        gpa.free(planning.planner_worlds);
        gpa.free(planning.plans);
        gpa.free(planning.seeds);
        gpa.free(planning.seeded);
        gpa.free(planning.teaches);
        gpa.free(planning.plan_advantages);
        gpa.free(planning.advantages);
        gpa.free(planning.advantages_sorted);
        gpa.free(planning.candidate_knots);
        gpa.free(planning.candidate_scores);
        gpa.free(planning.copy_sources);
    }

    /// Where in its block a planner's BASELINE is (`robot.PlanningOptions.baseline_candidate`): right after its warm
    /// start, a plan of zeros - the policy itself around the policy, the servo as whole actions. Every lookahead runs
    /// it, so a plan's advantage over it is measured in the same physics (`judgePlans`).
    pub const baseline_candidate: usize = 1;

    /// Whether a lookahead has its baseline among its candidates: asked for (`robot.PlanningOptions`), in a block
    /// of two at least.
    pub fn runsBaselineCandidate(planning: Planning) bool {
        const has_room: bool = planning.options.candidates_per_planner > baseline_candidate;
        return has_room and planning.options.baseline_candidate;
    }

    /// WHICH NEW PLANS TEACH (`robot.PlanningOptions.teach_share`), after a replan's choice - `teaches`, a planner
    /// each. Each plan's ADVANTAGE - its score less its baseline's (`baseline_candidate`): the policy's own candidate
    /// around the policy, the servo's as whole actions, the same physics from the same state - goes into the window
    /// of the last `teach_window`; then a plan teaches when it beats its baseline (an advantage above 0) and its
    /// advantage is at least the threshold, the lowest of the window's top share. A score that is not a number
    /// teaches nothing and is not kept. Around the policy a plan that teaches teaches the flow (teacher 2); as whole
    /// actions it is followed, and its records labelled (`Sim.endReplan`) - every plan that beats the servo, the
    /// share 1. Without a baseline every plan teaches, its stretch judged by how it ended alone
    /// (robot_track_resident's `FlowExamples`).
    ///
    ///     window (sorted)  -0.2  0.0  0.1  0.3  0.4  0.6  0.9  1.2  1.5  2.0        teach_share 0.4
    ///     threshold        the lowest of the top 4: 0.9 - a plan teaches at 0.9 or more
    pub fn judgePlans(planning: *Planning) void {
        const planner_count: usize = planning.planner_count;
        const teaches: []bool = planning.teaches[0..planner_count];
        if (!planning.runsBaselineCandidate()) {
            @memset(teaches, true);
            return;
        }
        // 1  Each plan's advantage, and the finite ones into the window.
        const plan_advantages: []f32 = planning.plan_advantages[0..planner_count];
        const window_size: u32 = @intCast(planning.advantages.len);
        const candidates_per_planner: u32 = planning.options.candidates_per_planner;
        for (plan_advantages, 0..) |*plan_advantage, planner_index| {
            const first_candidate: usize = planning.firstCandidateOf(planner_index);
            const block_scores: []const f32 = planning.candidate_scores[first_candidate..][0..candidates_per_planner];
            const winner_score: f32 = block_scores[bestInBlock(block_scores)];
            const baseline_score: f32 = block_scores[baseline_candidate];
            plan_advantage.* = winner_score - baseline_score;
            if (!isFinite(plan_advantage.*)) {
                continue;
            }
            planning.judged_plans += 1;
            planning.advantage_sum += plan_advantage.*;
            planning.advantages[planning.advantage_next] = plan_advantage.*;
            planning.advantage_next = (planning.advantage_next + 1) % window_size;
            planning.advantage_count = @min(planning.advantage_count + 1, window_size);
        }
        // 2  The threshold: the window sorted, the lowest of its top share.
        const held: usize = planning.advantage_count;
        if (held == 0) {
            @memset(teaches, false);
            return;
        }
        const sorted: []f32 = planning.advantages_sorted[0..held];
        @memcpy(sorted, planning.advantages[0..held]);
        sortSlice(f32, sorted, {}, std.sort.asc(f32));
        // As whole actions every plan that beats the servo teaches: a label needs no ranking, only to be no worse
        // than the servo. The share ranks the flow's examples, around the policy.
        const share: f32 = if (planning.form == .whole_actions) 1.0 else planning.options.teach_share;
        const threshold: f32 = sorted[topShareStart(held, share)];
        // 3  A plan teaches when it beats its baseline and is in the top share.
        for (teaches, plan_advantages) |*plan_teaches, plan_advantage| {
            const beats_baseline: bool = isFinite(plan_advantage) and plan_advantage > 0;
            plan_teaches.* = beats_baseline and plan_advantage >= threshold;
            planning.teaching_plans += @intFromBool(plan_teaches.*);
        }
    }

    /// Whether the planner in world `world` has a plan that teaches the flow now (`judgePlans`): false for a world
    /// that is no planner.
    pub fn planTeaches(planning: Planning, world: u32) bool {
        for (planning.planners(), planning.teaches[0..planning.planner_count]) |planner_world, plan_teaches| {
            if (planner_world == world) {
                return plan_teaches;
            }
        }
        return false;
    }

    /// The planners now: the first `planner_count` of `planner_worlds`, each with the block of its place.
    pub fn planners(planning: Planning) []u32 {
        return planning.planner_worlds[0..planning.planner_count];
    }

    /// How many candidates a replan runs: the planners' blocks, the batch's first worlds.
    pub fn candidateCount(planning: Planning) u32 {
        return planning.planner_count * planning.options.candidates_per_planner;
    }

    /// How many worlds are the candidates', a block for each planner `init` was given: the batch's first, whether a
    /// replan runs them or not - the characters come after them all.
    pub fn candidateCapacity(planning: Planning) u32 {
        const blocks: u32 = @intCast(planning.planner_worlds.len);
        return blocks * planning.options.candidates_per_planner;
    }

    /// THE PLANNERS REPLACED by `new_planners` (characters' worlds, at most a block each), from the next replan on.
    /// A planner that stays keeps its plan, moved to its new place; a new one starts from the policy itself - a plan
    /// of zero offsets, so the plans must be around the policy (`planAroundPolicy`). The copy table follows: each
    /// planner's block of candidates its copies, the blocks after them none. The worlds that planned and no longer do
    /// are written to `out_dropped`, their count returned: their following is the caller's to end
    /// (`Sim.setPlanFollowing`, `.none`). `scratch` is the room of every plan (`plans.len` numbers).
    pub fn replacePlanners(
        planning: *Planning,
        new_planners: []const u32,
        scratch: []f32,
        out_dropped: []u32,
    ) u32 {
        const around_policy: bool = planning.form == .offsets_around_policy;
        assertf(around_policy, @src(), "a new planner starts from the policy: plans around it", .{});
        const room: usize = planning.planner_worlds.len;
        assertf(new_planners.len >= 1 and new_planners.len <= room, @src(), "{d} planners in {d} blocks", .{
            new_planners.len,
            room,
        });
        const scratch_is_every_plan: bool = scratch.len == planning.plans.len;
        assertf(scratch_is_every_plan, @src(), "scratch of {d} for {d}", .{ scratch.len, planning.plans.len });
        const first_character: u32 = planning.candidateCapacity();
        for (new_planners) |planner_world| {
            assertf(planner_world >= first_character, @src(), "planner {d}: candidates take the first {d}", .{
                planner_world,
                first_character,
            });
        }
        const plan_numbers: usize = planning.plan_numbers;
        const old_planners: []const u32 = planning.planners();
        // The new plans, place by place: a staying planner's own, moved; zero for a new one.
        @memset(scratch, 0);
        for (new_planners, 0..) |planner_world, new_place| {
            const old_place: ?usize = indexOfScalar(u32, old_planners, planner_world);
            if (old_place) |place| {
                @memcpy(scratch[new_place * plan_numbers ..][0..plan_numbers], planning.planOf(place));
            }
        }
        // The worlds that planned and are not among the new.
        var dropped_count: u32 = 0;
        for (old_planners) |planner_world| {
            const stays: bool = indexOfScalar(u32, new_planners, planner_world) != null;
            if (stays) {
                continue;
            }
            out_dropped[dropped_count] = planner_world;
            dropped_count += 1;
        }
        @memcpy(planning.plans, scratch);
        @memcpy(planning.planner_worlds[0..new_planners.len], new_planners);
        planning.planner_count = @intCast(new_planners.len);
        // The copy table: each planner's block its copies, the rest none.
        @memset(planning.copy_sources, null);
        const candidates_per_planner: u32 = planning.options.candidates_per_planner;
        for (new_planners, 0..) |planner_world, place| {
            const first_candidate: usize = place * candidates_per_planner;
            @memset(planning.copy_sources[first_candidate..][0..candidates_per_planner], planner_world);
        }
        return dropped_count;
    }

    /// The first of planner `planner_index`'s candidates: its warm start.
    pub fn firstCandidateOf(planning: Planning, planner_index: usize) usize {
        return planner_index * planning.options.candidates_per_planner;
    }

    /// Planner `planner_index`'s plan, its knots.
    pub fn planOf(planning: Planning, planner_index: usize) []f32 {
        return planning.plans[planner_index * planning.plan_numbers ..][0..planning.plan_numbers];
    }

    /// Planner `planner_index`'s seed for the next replan (`seeds`).
    pub fn seedOf(planning: Planning, planner_index: usize) []f32 {
        return planning.seeds[planner_index * planning.plan_numbers ..][0..planning.plan_numbers];
    }

    /// Candidate `candidate`'s plan, its knots - the front of its block (`candidate_knots`).
    pub fn candidateKnots(planning: Planning, candidate: usize) []f32 {
        return planning.candidate_knots[candidate * planning.knot_stride ..][0..planning.plan_numbers];
    }
};

/// HOW A TRAINER's DECISIONS ON THE DEVICE EXPLORE (`Sim.actTrainerOnDevice`): SuperTrack's exploration - the spread of
/// the noise added to every choice - and, for a learner with a flow actor, the scale of the flow's drifting noise
/// (`Resident.flowNoiseAt`). Both come from the acting's one noise scale as the CPU's `act` takes it (`ofScale`); 0 is
/// the policy alone, judged.
pub const ActingNoise = struct {
    exploration_spread: f32,
    flow_scale: f32,

    /// The noise of an acting at `noise_scale` (1 while training) for a learner of exploration `sigma`.
    pub fn ofScale(noise_scale: f32, sigma: f32) ActingNoise {
        const noise: ActingNoise = .{ .exploration_spread = noise_scale * sigma, .flow_scale = noise_scale };
        return noise;
    }
};

/// A TRAINER's PLANNERS, for its loop on the device (`Sim.actTrainerOnDevice`): the planning - its planners, plans
/// and replan interval - and the random stream its replans draw their candidates and their following from.
pub const TrainerPlanners = struct {
    planning: *Planning,
    random: Random,
};

/// A RUN's CLIPS AS A DEVICE TAKES THEM: for every clip of a fleet, in the fleet's order, the three tables a tracking
/// simulator is made with (`robotgpu.ClipPoses`) and its curriculum's bins as the fleet cuts them. One row a frame:
///
///     poses               the model's coordinates - the clip's pose after its root's leading numbers
///     reference_features  the reference's half of the observation (`Fleet.clipReferenceFeatures`)
///     reference_bodies    the reference's bodies, for the judgement (`Fleet.clipReferenceBodies`)
///
/// Each table holds every clip's rows, clip after clip; `clips` views each clip's part of the three. Made by the
/// fleet's own functions, so a device's references are the CPU fleet's to the bit. A clip's bins are the fleet's
/// (`bins_start`, `binFrames`): a device draws a new episode's start within its clip's bins (`robotgpu.begin_reset`),
/// as the fleet does. Memory: the tables and the views are allocated from `gpa` by `init` and freed by `deinit`; the
/// views are valid while the tables are.
pub const RunTables = struct {
    poses: []f32,
    reference_features: []f32,
    reference_bodies: []f32,
    clips: []robotgpu.ClipPoses,

    pub fn init(gpa: Allocator, fleet: *track.Fleet) !RunTables {
        const model: *const robot.Model = fleet.m;
        const coordinate_count: usize = model.coordinate_count;
        const feature_row: usize = track.localSize(model.body_count);
        const body_row: usize = model.body_count * robot.reference_body_numbers;
        var frame_total: usize = 0;
        for (fleet.clips) |clip| {
            frame_total += clip.frame_count;
        }
        const poses: []f32 = try gpa.alloc(f32, frame_total * coordinate_count);
        errdefer gpa.free(poses);
        const reference_features: []f32 = try gpa.alloc(f32, frame_total * feature_row);
        errdefer gpa.free(reference_features);
        const reference_bodies: []f32 = try gpa.alloc(f32, frame_total * body_row);
        errdefer gpa.free(reference_bodies);
        const clips: []robotgpu.ClipPoses = try gpa.alloc(robotgpu.ClipPoses, fleet.clips.len);
        errdefer gpa.free(clips);
        // The fleet's functions fill the reference tables on scratch that lives for this call alone.
        var scratch_data: robot.Data = try .init(gpa, model);
        defer scratch_data.deinit();
        var scratch_state: track.State = try .init(gpa, model.body_count);
        defer scratch_state.deinit(gpa);
        const has_curriculum: bool = fleet.bins_start.len > 0;
        var first_frame: usize = 0;
        for (fleet.clips, clips, 0..) |clip, *clip_poses, clip_index| {
            const frame_count: usize = clip.frame_count;
            // The model's coordinates follow the clip's root numbers, which the model does not hold.
            const root_numbers: usize = clip.nq - coordinate_count;
            const poses_first: usize = first_frame * coordinate_count;
            const clip_poses_rows: []f32 = poses[poses_first..][0 .. frame_count * coordinate_count];
            for (0..frame_count) |frame| {
                const pose_row: []f32 = clip_poses_rows[frame * coordinate_count ..][0..coordinate_count];
                @memcpy(pose_row, clip.pose(frame)[root_numbers..]);
            }
            const features_first: usize = first_frame * feature_row;
            const clip_features: []f32 = reference_features[features_first..][0 .. frame_count * feature_row];
            fleet.clipReferenceFeatures(clip, &scratch_data, &scratch_state, clip_features);
            const bodies_first: usize = first_frame * body_row;
            const clip_bodies: []f32 = reference_bodies[bodies_first..][0 .. frame_count * body_row];
            fleet.clipReferenceBodies(clip, &scratch_data, &scratch_state, clip_bodies);
            const bin_count: usize = if (has_curriculum)
                fleet.bins_start[clip_index + 1] - fleet.bins_start[clip_index]
            else
                0;
            const bin_frames: usize = if (has_curriculum) track.binFrames(clip, fleet.options.curriculum) else 0;
            clip_poses.* = .{
                .poses = clip_poses_rows,
                .frame_count = @intCast(frame_count),
                .frame_time = clip.frame_time,
                .curriculum_bins = @intCast(bin_count),
                .bin_frames = @intCast(bin_frames),
                .reference_features = clip_features,
                .reference_bodies = clip_bodies,
            };
            first_frame += frame_count;
        }
        return .{
            .poses = poses,
            .reference_features = reference_features,
            .reference_bodies = reference_bodies,
            .clips = clips,
        };
    }

    pub fn deinit(tables: RunTables, gpa: Allocator) void {
        gpa.free(tables.poses);
        gpa.free(tables.reference_features);
        gpa.free(tables.reference_bodies);
        gpa.free(tables.clips);
    }
};

/// ONE MODEL'S WORLDS ON A PIPE: the pipe, the model's counts and the layout of every array (this file's head).
pub const Sim = struct {
    pipe: Pipe,
    counts: robotgpu.Counts,
    layout: robotgpu.Layout,
    /// Whether the model has damping, so the step writes the damped velocity update's arrays.
    has_dof_damping: bool,
    /// The host's clock over a training round's phases (`robot.PhaseClock`), where a trainer accounts for its time:
    /// the simulator tells it each phase it enters and each wait for the device (`enterPhase`, `noteWait`). Null:
    /// nobody is counting. The trainer's, which outlives the simulator.
    phase_clock: ?*robot.PhaseClock = null,

    /// The worlds on a device: `kernels` as the app embeds them - SPIR-V natively, WGSL in a browser - `world_count`
    /// copies of `model`, every one in the model's reference pose until a caller sets their states.
    pub fn initGpu(
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        kernels: []const Pipe.KernelWgsl,
        model: *const robot.Model,
        nworld: u32,
    ) !Sim {
        try robotgpu.refuseUnsimulatedFeatures(model);
        try refuseSmallWorkgroupMemory(device, kernels);
        var pipe: Pipe = try .initGpu(gpa, device, queue, kernels);
        errdefer pipe.deinit();
        return initOnPipe(gpa, pipe, model, nworld, &.{});
    }

    /// `initGpu`, ITS PIPELINES MADE IN THE BACKGROUND (`Pipe.initGpuInBackground`): a browser compiles the kernels
    /// off the page's thread while the page draws. The Sim is returned at once; nothing may be submitted until
    /// `sim.pipe.pipelineProgress()` is complete, which a page asks once a frame. Natively the pipelines are compiled
    /// in the call, and the first ask finds them ready.
    pub fn initGpuInBackground(
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        kernels: []const Pipe.KernelWgsl,
        model: *const robot.Model,
        nworld: u32,
    ) !Sim {
        try robotgpu.refuseUnsimulatedFeatures(model);
        try refuseSmallWorkgroupMemory(device, kernels);
        var pipe: Pipe = try .initGpuInBackground(gpa, device, queue, kernels);
        errdefer pipe.deinit();
        return initOnPipe(gpa, pipe, model, nworld, &.{});
    }

    /// The worlds on a device, with a TRACKING TASK's clips (`robotgpu.ClipPoses`): each world follows one of them,
    /// the clip and its frame set by `setWorldClip`, and the decision's kernels (`reference_targets`) form the servo's
    /// targets from it and the world's action.
    pub fn initGpuTracking(
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        kernels: []const Pipe.KernelWgsl,
        model: *const robot.Model,
        nworld: u32,
        clips: []const robotgpu.ClipPoses,
    ) !Sim {
        robotgpu.requireNoHullsWhenJudged(model, clips);
        try robotgpu.refuseUnsimulatedFeatures(model);
        try refuseSmallWorkgroupMemory(device, kernels);
        var pipe: Pipe = try .initGpu(gpa, device, queue, kernels);
        errdefer pipe.deinit();
        return initOnPipe(gpa, pipe, model, nworld, clips);
    }

    /// The worlds on the CPU twin: the same kernels, run as a loop over their invocations. ONE TWIN AT A TIME: every
    /// twin works in the module's own arrays (a CPU module's globals stand where a GPU's buffers would), so a second
    /// twin overwrites the first - which is also why each new twin clears what the last one left.
    pub fn initTwin(gpa: Allocator, model: *const robot.Model, nworld: u32) !Sim {
        return initTwinTracking(gpa, model, nworld, &.{});
    }

    /// The worlds on the CPU twin, with a tracking task's clips - `initGpuTracking`'s twin.
    pub fn initTwinTracking(
        gpa: Allocator,
        model: *const robot.Model,
        nworld: u32,
        clips: []const robotgpu.ClipPoses,
    ) !Sim {
        try robotgpu.refuseUnsimulatedFeatures(model);
        const pipe: Pipe = .initCpu();
        const sim: Sim = try initOnPipe(gpa, pipe, model, nworld, clips);
        // A new GPU buffer is zeros - WebGPU promises it, and the Vulkan backend fills it so - but the twin's arenas
        // are the module's static arrays, which hold whatever the last twin left: another model's state, at offsets
        // that mean nothing to this one. Cleared, the twin starts where the device does, so a world nobody gave a
        // value - its controls, its applied forces - holds zero on both.
        clearTwinWorldArena(.world_f, sim);
        clearTwinWorldArena(.world_u, sim);
        clearTwinWorldArena(.efc_f, sim);
        // And the host's window: the last twin's curriculum bins.
        clearTwinWorldArena(.io, sim);
        // The clearing took every world's first discount power with it: set again, as on a device.
        var twin: Sim = sim;
        twin.setFirstEpisodeDiscounts();
        return twin;
    }

    /// The twin's arena `arena` zeroed as far as this simulation's layout reaches - the end of its last array, every
    /// world's block - rather than the whole static array, which a desktop build sizes for thousands of worlds.
    fn clearTwinWorldArena(comptime arena: robotgpu.Arena, sim: Sim) void {
        const used_end: u32 = sim.worldArenaEnd(arena);
        const twin_arena: []robotgpu.ArenaElement(arena) = &@field(robotgpu.g.B, @tagName(arena));
        @memset(twin_arena[0..used_end], 0);
    }

    /// HOW FAR THIS SIMULATION's ARENA `arena` REACHES: the end of its last array - every world's block counted for a
    /// per-world array, the one copy for a shared one. Everything the simulation holds in that arena lies below it -
    /// what a caller reads or uploads to take, or to give, every world's state at once.
    pub fn worldArenaEnd(sim: *const Sim, comptime arena: robotgpu.Arena) u32 {
        return robotgpu.arenaEnd(sim.layout, sim.counts, arena);
    }

    /// The model and the task's clips (none, for a simulator without a task) counted, laid out, packed and uploaded
    /// onto `pipe`. The images are the host's only for the upload: allocated from `gpa` and freed before this returns,
    /// the arenas holding the model from then on.
    fn initOnPipe(
        gpa: Allocator,
        pipe: Pipe,
        model: *const robot.Model,
        nworld: u32,
        clips: []const robotgpu.ClipPoses,
    ) !Sim {
        const counts: robotgpu.Counts = robotgpu.countsWithClips(robotgpu.countsOf(model, nworld), clips);
        const layout: robotgpu.Layout = try robotgpu.layoutFor(counts, .{});
        const model_u_image: []u32 = try gpa.alloc(u32, arenaLength(.model_u));
        defer gpa.free(model_u_image);
        const model_f_image: []f32 = try gpa.alloc(f32, arenaLength(.model_f));
        defer gpa.free(model_f_image);
        robotgpu.pack(model, layout, model_u_image, model_f_image);
        robotgpu.packClips(clips, counts, layout, model_u_image, model_f_image);
        var sim: Sim = .{
            .pipe = pipe,
            .counts = counts,
            .layout = layout,
            .has_dof_damping = model.has_dof_damping,
        };
        sim.pipe.upload(.model_u, model_u_image);
        sim.pipe.upload(.model_f, model_f_image);
        const options: robotgpu.StepOptions = .of(model);
        sim.pipe.params = .{ .counts = counts, .layout = layout, .options = options };
        sim.setFirstEpisodeDiscounts();
        return sim;
    }

    /// Every world's first episode begins with nothing discounted yet: its discount's power is one, as a start sets
    /// it (`begin_reset`). A world a caller places by hand, never started by a reset, then earns its curriculum's
    /// return as a started one does - a power left at the arena's zero would leave every such return at zero.
    fn setFirstEpisodeDiscounts(sim: *Sim) void {
        const powers: @FieldType(robotgpu.WorldStateLayout, "episode_discount_powers") =
            sim.layout.world_f.episode_discount_powers;
        const one = [1]f32{1};
        var world: u32 = 0;
        while (world < sim.counts.world_count) : (world += 1) {
            sim.pipe.uploadAt(.world_f, powers.at(world, 0), &one);
        }
    }

    pub fn deinit(sim: *Sim) void {
        sim.pipe.deinit();
    }

    /// ONE STEP SUBMITTED: the step program as one batch (`submitDispatches`). Returns at once; the GPU works on.
    pub fn submitStep(sim: *Sim) void {
        sim.submitDispatches(&robotgpu.step_program);
    }

    /// DISPATCHES SUBMITTED as one batch, each after the one before - the step program, a part of it, the constraint
    /// program - a dispatch with no invocations for this model left out. Returns at once; the GPU works on.
    pub fn submitDispatches(sim: *Sim, comptime dispatches: []const robotgpu.Dispatch) void {
        sim.pipe.beginBatch(sim.pipe.params);
        sim.runDispatches(dispatches);
        sim.pipe.endBatch();
    }

    /// ONE DECISION SUBMITTED as one batch: for each of its `physics_steps` steps, the tracking task's dispatches
    /// before the step (the filter, the servo's targets), the step program, and those after it (each world's frame
    /// advanced) - the order robot_track's `Fleet.step` takes a decision of `decide_every` physics steps. The actions
    /// are the world's, uploaded before. Returns at once; the GPU works on.
    pub fn submitDecision(sim: *Sim, physics_steps: u32) void {
        sim.pipe.beginBatch(sim.pipe.params);
        sim.runDispatches(&robotgpu.decision_start_program);
        var physics_step: u32 = 0;
        while (physics_step < physics_steps) : (physics_step += 1) {
            sim.runDispatches(&robotgpu.before_step_program);
            sim.runDispatches(&robotgpu.step_program);
            sim.runDispatches(&robotgpu.after_step_program);
        }
        sim.pipe.endBatch();
    }

    /// A DECISION's END SUBMITTED, once a decision, after its last physics step - the only way to it, so the order
    /// holds: each world's observation (`robotgpu.observe_program`), which brings the bodies' poses and velocities
    /// forward, then its judgement (`robotgpu.judge_program`), which reads them. Asserts the clips' reference tables
    /// exist: without them the judgement's kernels judge nothing, and no episode would ever end. Returns at once.
    pub fn submitDecisionEnd(sim: *Sim) void {
        const tables_given: bool = sim.counts.reference_feature_frames > 0;
        assertf(tables_given, @src(), "submitDecisionEnd: the clips were given no reference tables", .{});
        sim.pipe.beginBatch(sim.pipe.params);
        sim.runDispatches(&robotgpu.observe_program);
        sim.runDispatches(&robotgpu.judge_program);
        sim.pipe.endBatch();
    }

    /// The policy's normaliser (`feature_means`, `feature_spreads`): one mean and one spread per feature, uploaded
    /// whenever the learner's normaliser changes.
    pub fn setFeatureNormalizer(
        sim: *Sim,
        means: []const f32,
        spreads: []const f32,
    ) void {
        const feature_count: usize = robot.localSize(sim.counts.body_count);
        const one_per_feature: bool = means.len == feature_count and spreads.len == feature_count;
        assertf(one_per_feature, @src(), "{d} means and {d} spreads for {d} features", .{
            means.len,
            spreads.len,
            feature_count,
        });
        sim.pipe.uploadAt(.model_f, sim.layout.model_f.feature_means.at(0), means);
        sim.pipe.uploadAt(.model_f, sim.layout.model_f.feature_spreads.at(0), spreads);
    }

    /// A PHASE OF A TRAINING ROUND ENTERED (`robot.RoundPhase`), for the round's time: the simulator's dispatches
    /// from here on are timed under it, where its pipe is timed (`Compute.setPhase`), and the host's clock, where a
    /// trainer attached one (`phase_clock`), counts the host's time under it.
    pub fn enterPhase(sim: *Sim, phase: robot.RoundPhase) void {
        sim.pipe.setPhase(@backingInt(phase));
        if (sim.phase_clock) |clock| {
            clock.enter(wgpu.nowMs(), phase);
        }
    }

    /// A WAIT FOR THE DEVICE, begun at `wait_began_ms` on the host's clock and over now, counted in the phase the
    /// host is in (`robot.PhaseClock.addWait`) - the spins on readbacks, which are where a round's host waits.
    pub fn noteWait(sim: *Sim, wait_began_ms: f64) void {
        if (sim.phase_clock) |clock| {
            clock.addWait(wgpu.nowMs() - wait_began_ms);
        }
    }

    /// A PHASE OF THE TRAINER's ROUND ENTERED BY BOTH ITS PIPES: the simulator's (`enterPhase`, with the host's
    /// clock) and the trainer's kit's - the policy acts on the kit's pipe within the simulator's decision, and its
    /// dispatches are that phase's too.
    fn enterTrainerPhase(
        sim: *Sim,
        comptime M: type,
        trainer: *z.robot_track_resident.Resident(M),
        phase: robot.RoundPhase,
    ) void {
        sim.enterPhase(phase);
        trainer.kit.pipe.setPhase(@backingInt(phase));
    }

    /// ACTING ON THE DEVICE, AS ONE CALL - one decision for every world without leaving the GPU: the simulator writes
    /// each world's policy inputs (`robotgpu.policy_inputs_program`); the learning kit beside it on the same device
    /// runs the policy on them (`LatentKit.actWithSimulator`: the inputs and each world's previous action copied in,
    /// the raw actions copied out into the choices); then the simulator makes the choices the decision's actions
    /// (`giveActions`: the exploration at `clock`, the action filter). Nothing is read back. It lives with the
    /// simulator's host because here the simulator and the kit's engine are both named modules; the twin's own
    /// version is the kit's tests' `actOnTwin`. `M` is the kit's network module (zn_mlp).
    pub fn actWithKit(
        sim: *Sim,
        comptime M: type,
        kit: z.robot_latent_kit.LatentKit(M),
        acting: z.robot_latent_kit.LatentKit(M).PolicyRows,
        first_world: u32,
        clock: robotgpu.DecisionClock,
    ) void {
        sim.chooseWithKit(M, kit, acting, first_world);
        sim.pipe.params.options.flow_corrections = .disabled;
        sim.giveActions(clock);
    }

    /// THE FLOW's CORRECTIONS OF THE CHOICES, after the policy has chosen (`chooseWithKit`), for a learner with a flow
    /// actor (`flow`; null: none, and the decision takes none): the kit's correction over the acting rows
    /// (`LatentKit.correctOnRows`) - the model planner's characters', where it plans (`model`), its plans' first
    /// corrections instead (`TrackingPlanner.decideForRows`) - copied whole into the simulator's `flow_corrections`
    /// from `first_world` on, and the decision told it has them - the giving adds each to its world's choice
    /// (`robotgpu.add_flow_corrections`).
    pub fn correctWithFlow(
        sim: *Sim,
        comptime M: type,
        kit: z.robot_latent_kit.LatentKit(M),
        acting: z.robot_latent_kit.LatentKit(M).PolicyRows,
        first_world: u32,
        flow: ?z.robot_latent_kit.LatentKit(M).FlowActing,
        model: ?z.robot_latent_kit.TrackingPlanner(M).RowsDecision,
    ) void {
        const flow_now: z.robot_latent_kit.LatentKit(M).FlowActing = flow orelse {
            sim.pipe.params.options.flow_corrections = .disabled;
            return;
        };
        // The flow's correction and the model planner's decision as ONE recording, one submission: hundreds of
        // dispatches a decision, each with its own parameters, the copy out after them.
        kit.pipe.beginRecording();
        kit.correctOnRows(acting, flow_now.rows, flow_now.noise);
        // The model planner's characters: its plans' first corrections in the flow's place.
        if (model) |decision| {
            decision.decideForRows(kit, acting, flow_now.rows);
        }
        kit.pipe.submitRecording();
        const corrections_array: @FieldType(robotgpu.WorldStateLayout, "flow_corrections") =
            sim.layout.world_f.flow_corrections;
        assertf(corrections_array.stride == acting.raw_stride, @src(), "corrections {d} apart, the rows {d}", .{
            corrections_array.stride,
            acting.raw_stride,
        });
        const float_bytes: u32 = @sizeOf(f32);
        const correction_bytes: u32 = acting.rows * acting.raw_stride * float_bytes;
        const from: u32 = flow_now.rows.corrections_at * float_bytes;
        const to: u32 = corrections_array.at(first_world, 0) * float_bytes;
        const kit_acts: z.DeviceField = kit.pipe.deviceField(.acts);
        z.copyFieldBetween(kit_acts, from, sim.pipe.deviceField(.world_f), to, correction_bytes);
        sim.pipe.params.options.flow_corrections = .enabled;
    }

    /// THE POLICY's CHOICE, ON THE DEVICE - `actWithKit` before the action is given: each world's policy inputs
    /// (`robotgpu.policy_inputs_program`), the kit's policy on the rows of the worlds from `first_world` on, and its
    /// raw actions in each world's choices (`chosen_actions`). The batch's world count says how many worlds: as many
    /// as the acting rows hold.
    pub fn chooseWithKit(
        sim: *Sim,
        comptime M: type,
        kit: z.robot_latent_kit.LatentKit(M),
        acting: z.robot_latent_kit.LatentKit(M).PolicyRows,
        first_world: u32,
    ) void {
        // The policy's inputs from the state as it is now (the program observes first): one submission.
        sim.submitDispatches(&robotgpu.policy_inputs_program);
        const arrays: robotgpu.WorldStateLayout = sim.layout.world_f;
        // The kit's rows are the worlds from `first_world` on: a block of them, copied whole each way.
        const inputs_at: u32 = arrays.policy_inputs.at(first_world, 0);
        const given_at: u32 = arrays.actions.at(first_world, 0);
        const chosen_at: u32 = arrays.chosen_actions.at(first_world, 0);
        kit.actWithSimulator(acting, sim.pipe.deviceField(.world_f), inputs_at, given_at, chosen_at);
    }

    /// A DECISION's ACTING WITH THE PLANNERS' PLANS, at the plans' decision `plan_decision` (the decisions since the
    /// replan; null without planners) and in their form (`robot.PlanForm`, as `setPlanForm` told the simulator) - the
    /// policy choosing first (`chooseWithKit`), its flow's corrections beside its choices with a flow actor
    /// (`correctWithFlow`):
    ///
    ///     no plans                the action given (`giveActions`): the flow's correction, the exploration, the
    ///                             action filter
    ///     whole actions           the action given, then the planners that follow their plans take their plans'
    ///                             actions over it (`followPlans`)
    ///     around the policy       the planners that follow their plans add their plans' offsets to the policy's
    ///                             choice, then the action is given - the flow's correction and the exploration for
    ///                             every other world, the action filter for all
    pub fn actFollowingPlans(
        sim: *Sim,
        comptime M: type,
        kit: z.robot_latent_kit.LatentKit(M),
        acting: z.robot_latent_kit.LatentKit(M).PolicyRows,
        first_world: u32,
        clock: robotgpu.DecisionClock,
        plan_decision: ?u32,
        flow: ?z.robot_latent_kit.LatentKit(M).FlowActing,
        model: ?z.robot_latent_kit.TrackingPlanner(M).RowsDecision,
    ) void {
        sim.chooseWithKit(M, kit, acting, first_world);
        sim.correctWithFlow(M, kit, acting, first_world, flow, model);
        const plan_decision_now: u32 = plan_decision orelse {
            sim.giveActions(clock);
            return;
        };
        const around_policy: bool = sim.pipe.params.options.plan_form == .offsets_around_policy;
        if (!around_policy) {
            sim.giveActions(clock);
            sim.followPlans(plan_decision_now);
            return;
        }
        // The plans' decision stands through the giving: the flow's correction and the exploration read it to leave
        // the followers alone.
        sim.pipe.params.options.plan_decision = @floatFromInt(plan_decision_now);
        sim.runDispatches(&robotgpu.follow_plans_program);
        sim.giveActions(clock);
    }

    /// WHAT THE PLANS' NUMBERS ARE, for the dispatches after (`robot.PlanForm`): whole actions, or offsets around the
    /// policy's choice - the planning's own form (`Planning.form`), told at each replan.
    pub fn setPlanForm(sim: *Sim, form: robot.PlanForm) void {
        sim.pipe.params.options.plan_form = form;
    }

    /// Whether the policy's inputs hold the root target in their slots (`robotgpu.policy_inputs`), or zeros: a
    /// learner's `Options.root_target`.
    pub fn setRootTarget(sim: *Sim, root_target: bool) void {
        sim.pipe.params.options.setRootTarget(root_target);
    }

    /// A TRAINER's DECISIONS ON THE DEVICE - `decisions` of them for every world, the trainer's policy acting and
    /// its learner's data kept, without the CPU simulating anything. The trainer must have accepted device acting
    /// for this simulator's worlds (`Resident.acceptDeviceActing`). Each decision:
    ///
    ///     1  each world's moment into the trainer's books, from the counters the last decision left (read back)
    ///     2  acting as one call (`actWithKit`) on the trainer's rows, at the decision's clock
    ///     3  each world's record (`robotgpu.record_program`): the state the action was taken from, the action
    ///     4  the records into the trainer's ring, by one copy on the GPU, at the index the books give them
    ///     5  the decision's physics, its judgement, its pushes and new episodes (`stepDecision`)
    ///
    /// The moments are read first because a record's place in a stretch is decided by the decision before it: a
    /// world pushed or restarted there begins a new stretch here. The trainer's normaliser is given to the simulator
    /// once, at the start: the policy reads its inputs normalised as the trainer trains on them. The decisions are
    /// numbered from `first_decision_number`, the clock of every draw - exploration, pushes, starts - and the pushes'
    /// range of speeds is as far open as the trainer's fleet says (`Fleet.pushTopShare`). The pushes, the returns and
    /// the watched pushes' ends the decisions' flags report are counted into `events`, the last told to the fleet.
    ///
    /// WITH PLANNERS (`planners` not null), two steps join the decision - the teacher's loop:
    ///
    ///     0   first, at every decision whose number is a multiple of the replan interval: a replan (`replan`), from
    ///         the state the planners are about to act from - their new plans, and how each follows its own. By the
    ///         number, not by the call: decisions split over calls replan on the same cadence, and a run begun
    ///         between two replans follows no plan until its first (a world's `plan_following` starts at `none`,
    ///         and a new episode clears it)
    ///     2b  with acting, the planners that follow their plans at this decision given their plans at the
    ///         decisions since the replan (`actFollowingPlans`) - the plan's action over the policy's, or, from the
    ///         training's second phase, the plan's offset added to the policy's choice - so the physics takes it and
    ///         the record keeps it: every planner at the replan's own decision, those that drew to at every one
    ///
    /// A trainer that records its candidates (`acceptCandidateRecording`) keeps every replan's lookahead, decision by
    /// decision, in its candidates' ring (`stepCandidatesAheadRecorded`), and marks each lookahead's favoured once
    /// the replan has read its scores (`CandidateRecording.complete`).
    ///
    /// THE CANDIDATES ARE LEFT OUT OF EVERY DECISION's OWN PROGRAMS: those run over the trainer's characters alone,
    /// the worlds from its first on (`Counts.first_world`), every dispatch sized to them. Between two replans a
    /// candidate's state is read by nothing - the next replan copies its planner over it - so stepping it would be
    /// work thrown away: 512 candidates beside 1,024 characters are a third of the worlds. A replan runs over every
    /// world.
    ///
    /// And step 1 LABELS the records: a planner's record is labelled where it follows its plan at this decision
    /// (`robotgpu.followsPlanAt`), by the following its counters hold - read after the replan, so it is the very
    /// following step 2b acts on. The books keep the label beside the record (`robot.RecordMoment.labelled`).
    ///
    /// The candidates are the worlds before the trainer's first: the lookahead steps them alone, and the trainer's
    /// characters see only the planners' new actions - a world that is no planner, its record and its books, are
    /// those of the loop without planners.
    pub fn actTrainerOnDevice(
        sim: *Sim,
        comptime M: type,
        gpa: Allocator,
        trainer: *z.robot_track_resident.Resident(M),
        decisions: u32,
        first_decision_number: u32,
        physics_steps: u32,
        noise: ActingNoise,
        planners: ?TrainerPlanners,
        events: *DeviceEvents,
    ) !void {
        assertf(trainer.device_acting != null, @src(), "the trainer has not accepted device acting", .{});
        const exploration_spread: f32 = noise.exploration_spread;
        const device_acting: *z.robot_track_resident.Resident(M).DeviceActing = &trainer.device_acting.?;
        // The trainer's characters: the worlds from its first on, after any candidates.
        const first_world: u32 = device_acting.first_world;
        const world_count: u32 = @intCast(device_acting.books.envs);
        const worlds_reached: u32 = first_world + world_count;
        assertf(worlds_reached <= sim.counts.world_count, @src(), "characters to world {d} of {d}", .{
            worlds_reached,
            sim.counts.world_count,
        });
        sim.setFeatureNormalizer(trainer.norm.mean, trainer.norm.spread);
        // The policy's inputs hold the root target in their slots, or zeros, as the learner's option says.
        sim.setRootTarget(trainer.options.root_target);
        // Every world's integers as read back, and the moments made of them: scratch for this call alone.
        const world_integer_count: u32 = sim.worldArenaEnd(.world_u);
        const world_integers: []u32 = try gpa.alloc(u32, world_integer_count);
        defer gpa.free(world_integers);
        const moments: []robot.RecordMoment = try gpa.alloc(robot.RecordMoment, world_count);
        defer gpa.free(moments);
        // The characters that followed a plan around the policy at a decision: teacher 2's examples.
        const followers: []u32 = try gpa.alloc(u32, world_count);
        defer gpa.free(followers);
        // The model planner's characters, chosen at a replan, and their clips and frames at a decision.
        const model_states: usize = trainer.slot_owners.len;
        const model_characters: []u32 = try gpa.alloc(u32, model_states);
        defer gpa.free(model_characters);
        const model_clips: []u32 = try gpa.alloc(u32, model_states);
        defer gpa.free(model_clips);
        const model_frames: []u32 = try gpa.alloc(u32, model_states);
        defer gpa.free(model_frames);
        // The model planner's last plans, read at a replan for the funnel: every state's, [state][step][action].
        const model_plan_floats: usize = if (trainer.planner) |planner| planner.mailboxPlanFloats() else 0;
        const model_plan_numbers: []f32 = try gpa.alloc(f32, model_plan_floats);
        defer gpa.free(model_plan_numbers);
        const records_array: @FieldType(robotgpu.WorldStateLayout, "records") = sim.layout.world_f.records;
        const simulator_numbers: z.DeviceField = sim.pipe.deviceField(.world_f);
        // The clip each world is on during a decision, read before it runs, for the trainer's counts.
        const clips_during: []u32 = try gpa.alloc(u32, world_count);
        defer gpa.free(clips_during);
        const counters: robotgpu.WorldIntegersLayout = sim.layout.world_u;
        const judged: bool = exploration_spread == 0;
        // How far the pushes' range of speeds has opened, at the training hours the trainer's fleet was told
        // (`robot.PushTop`): 1 throughout for a fleet whose pushes have no line.
        const push_top_share: f32 = trainer.fleet.pushTopShare();
        const uniform_options: robotgpu.StepOptions = sim.pipe.params.options;
        // THE DECISIONS' WORLDS: the trainer's characters, from its first on (`Counts.first_world`). The candidates in
        // front of them are stepped by the replans' lookaheads alone: between two replans their state is read by
        // nothing - the next replan copies its planner over it - so a decision leaves them out. Every world again
        // after the call, and for each replan within it.
        defer sim.pipe.params.counts.first_world = 0;
        var decision: u32 = 0;
        while (decision < decisions) : (decision += 1) {
            const decision_number: u32 = first_decision_number + decision;
            // The plans' clock: the decisions since the last replan, 0 at a replan's own decision - none without
            // planners.
            const decisions_since_replan: ?u32 = if (planners) |planners_now|
                decision_number % planners_now.planning.options.replan_interval
            else
                null;
            // 0  The replan, when one is due: from the state the planners are about to act from - before the
            //    counters are read, so the read sees each planner's following as step 2b will act on it. A trainer
            //    that records its candidates runs the lookahead itself, between the replan's halves.
            if (decisions_since_replan == 0) {
                sim.enterTrainerPhase(M, trainer, .replans);
                sim.pipe.params.counts.first_world = 0;
                const planners_now: TrainerPlanners = planners.?;
                const planning: *Planning = planners_now.planning;
                // The plans' form: around the policy from the second phase on - every plan zero at the switch, the
                // policy itself - and the simulator told at every replan.
                const form_now: robot.PlanForm = planFormNow(M, trainer, planning.options);
                if (form_now != planning.form) {
                    planning.planAroundPolicy();
                }
                sim.setPlanForm(planning.form);
                // Around the policy, the planners chosen again by trouble when the run asks it.
                const chooses_by_trouble: bool = planning.form == .offsets_around_policy and
                    planning.options.trouble_planners > 0;
                if (chooses_by_trouble) {
                    try sim.choosePlannersByTrouble(gpa, planning, first_world, world_count);
                }
                // Around the policy, when the learner plans through its world model: the funnel's seeds from the model
                // planner's last plans, then its characters for the decisions to come - the physics' planners, and
                // the characters in most trouble after them.
                const model_plans: bool = planning.form == .offsets_around_policy and trainer.planner != null;
                if (model_plans) {
                    if (device_acting.model_characters_chosen) {
                        try trainer.readModelPlans(gpa, model_plan_numbers);
                        const spans: []const u32 = trainer.planner.?.scorer.spans;
                        seedFromModelPlans(planning, first_world, trainer.slot_owners, model_plan_numbers, spans);
                    }
                    try sim.chooseModelCharacters(gpa, planning, first_world, world_count, model_characters);
                    trainer.chooseModelCharacters(model_characters);
                }
                try sim.beginReplan(gpa, planning, planners_now.random);
                if (trainer.candidate_recording == null) {
                    const plans_begin: u32 = 0;
                    sim.stepTrainerCandidates(M, trainer, planning, plans_begin, planning.horizon, physics_steps);
                } else {
                    sim.stepCandidatesAheadRecorded(M, trainer, planning, physics_steps);
                }
                try sim.endReplan(gpa, planning, planners_now.random);
                if (trainer.candidate_recording) |*recording| {
                    recording.complete(planning.candidate_scores, planning.planner_count);
                }
            }
            sim.pipe.params.counts.first_world = first_world;
            // 1  The moments, from the counters the last decision left, each planner's record labelled by its
            //    following. Every world records once a decision, so every world's next record has the same index:
            //    the first world's count of records so far. The host waits here for the decision before.
            sim.enterTrainerPhase(M, trainer, .books);
            var counters_read: Pipe.RangeRequest(.world_u) =
                try sim.pipe.requestRange(gpa, .world_u, 0, world_integer_count);
            const counters_wait_began_ms: f64 = wgpu.nowMs();
            while (!counters_read.collect(world_integers)) {
                std.atomic.spinLoopHint();
            }
            sim.noteWait(counters_wait_began_ms);
            // The last decision of THIS call in the trainer's counts - not one of an earlier call, which counted it.
            if (decision > 0) {
                const counted: CountedDecision = .of(decision_number - 1, uniform_options, push_top_share);
                // `moments` still holds that decision's, labelled where a planner acted from its plan.
                countTrainerDecisions(
                    M,
                    trainer,
                    counters,
                    first_world,
                    world_integers,
                    clips_during,
                    moments,
                    judged,
                    counted,
                    events,
                );
            }
            for (clips_during, 0..) |*clip, world_index| {
                const world: u32 = first_world + @as(u32, @intCast(world_index));
                clip.* = world_integers[counters.world_clip.at(world, 0)];
            }
            recordMomentsFrom(sim.layout.world_u, first_world, world_integers, decisions_since_replan, moments);
            const record_index: u64 = device_acting.books.written[0];
            trainer.appendBooksStep(moments);
            // 2  Acting, at the decision's clock.
            sim.enterTrainerPhase(M, trainer, .acting);
            const clock: robotgpu.DecisionClock = .{
                .number = decision_number,
                .push_top_share = push_top_share,
                .exploration_spread = exploration_spread,
            };
            // 2b  With it: the flow's correction of the choices, for a learner with a flow actor; the model planner's
            //     decision for its characters, where it plans - their clips and frames as the counters just read hold
            //     them; and the planners that follow their plans: the plan's action over the policy's, or its offset
            //     added to the policy's choice in the flow's place (`actFollowingPlans`).
            var model: ?z.robot_latent_kit.TrackingPlanner(M).RowsDecision = null;
            if (device_acting.model_characters_chosen) {
                for (trainer.slot_owners, model_clips, model_frames) |owner, *clip, *frame| {
                    const world: u32 = first_world + @as(u32, @intCast(owner.?));
                    clip.* = world_integers[counters.world_clip.at(world, 0)];
                    frame.* = world_integers[counters.world_frame.at(world, 0)];
                }
                model = trainer.modelPlanningAt(decision_number, model_clips, model_frames);
            }
            const flow: ?z.robot_latent_kit.LatentKit(M).FlowActing = if (device_acting.flow) |flow_rows| .{
                .rows = flow_rows,
                .noise = trainer.flowNoiseAt(decision_number, noise.flow_scale),
            } else null;
            // The characters act through the flow's base (`Resident.baseKit`): the policy the flow corrects and the
            // plans offset, its live weights or their slow average.
            sim.actFollowingPlans(
                M,
                trainer.baseKit(),
                device_acting.rows,
                first_world,
                clock,
                decisions_since_replan,
                flow,
                model,
            );
            // 2c  Teacher 2's examples: every planner that followed its plan at this decision - the records labelled -
            //     its condition and its whole choice into the flow's ring, from the plans' numbers in their form: the
            //     offsets around the policy, or the actions given where the plans are whole actions.
            //     Only the followers whose plans teach (`Planning.judgePlans`): around the policy, those that beat it
            //     by the most.
            if (device_acting.flow_examples != null) {
                var follower_count: usize = 0;
                for (moments, 0..) |moment, env| {
                    if (!moment.labelled) {
                        continue;
                    }
                    const world: u32 = first_world + @as(u32, @intCast(env));
                    const plan_teaches: bool = if (planners) |planners_now|
                        planners_now.planning.planTeaches(world)
                    else
                        true;
                    if (!plan_teaches) {
                        continue;
                    }
                    followers[follower_count] = @intCast(env);
                    follower_count += 1;
                }
                const form: robot.PlanForm = sim.pipe.params.options.plan_form;
                const plan_numbers_from: u32 = switch (form) {
                    .offsets_around_policy => sim.layout.world_f.plan_offsets.at(first_world, 0),
                    .whole_actions => sim.layout.world_f.actions.at(first_world, 0),
                };
                const following: []const u32 = followers[0..follower_count];
                trainer.keepFlowExamples(simulator_numbers, plan_numbers_from, form, record_index, following);
            }
            // 3  Each world's record: the state its action was taken from, the action, the frame, the root's pose.
            sim.runDispatches(&robotgpu.record_program);
            // 4  The records into the trainer's ring, by one copy on the GPU.
            const records_at: u32 = records_array.at(first_world, 0);
            const record_stride: u32 = records_array.stride;
            const ring_field: z.DeviceField = trainer.data.pipe.deviceField(.ring);
            const ring: *z.robot_latent_kit.RecordRing = &trainer.data.ring;
            ring.appendFromSimulator(ring_field, record_index, simulator_numbers, records_at, record_stride);
            // 5  The decision's physics and what follows it.
            sim.stepDecision(physics_steps, clock);
        }
        // The call's last decision in the trainer's counts, from the counters it left.
        if (decisions > 0) {
            sim.enterTrainerPhase(M, trainer, .books);
            var last_counters_read: Pipe.RangeRequest(.world_u) =
                try sim.pipe.requestRange(gpa, .world_u, 0, world_integer_count);
            const last_wait_began_ms: f64 = wgpu.nowMs();
            while (!last_counters_read.collect(world_integers)) {
                std.atomic.spinLoopHint();
            }
            sim.noteWait(last_wait_began_ms);
            const last_decision_number: u32 = first_decision_number + decisions - 1;
            const last_counted: CountedDecision = .of(last_decision_number, uniform_options, push_top_share);
            countTrainerDecisions(
                M,
                trainer,
                counters,
                first_world,
                world_integers,
                clips_during,
                moments,
                judged,
                last_counted,
                events,
            );
        }
        sim.enterTrainerPhase(M, trainer, .other);
    }

    /// THE DECISION's ACTION (`robotgpu.give_program`), after the policy's choice: the exploration, at the clock of
    /// the decision about to be stepped (`robotgpu.DecisionClock`), then the action filter into the actions.
    pub fn giveActions(sim: *Sim, clock: robotgpu.DecisionClock) void {
        clock.applyTo(&sim.pipe.params.options);
        sim.submitDispatches(&robotgpu.give_program);
    }

    /// THE RESETS (`robotgpu.reset_program`), after a decision's end, at the decision's clock
    /// (`robotgpu.DecisionClock`): the decision's pushes, the curriculum's round, then every world whose episode
    /// ended begins another.
    /// Then the observation program again, so a reset world's next action reads its new episode's state.
    pub fn runResets(sim: *Sim, clock: robotgpu.DecisionClock) void {
        clock.applyTo(&sim.pipe.params.options);
        sim.pipe.beginBatch(sim.pipe.params);
        sim.runDispatches(&robotgpu.reset_program);
        sim.runDispatches(&robotgpu.observe_program);
        sim.pipe.endBatch();
    }

    /// A PROGRAM RUN OVER THE CANDIDATES ALONE - the batch's first `candidate_count` worlds - the batch's world count
    /// lowered to theirs for it and restored after, as `stepCandidatesAhead` lowers it for a lookahead.
    fn runOverCandidates(
        sim: *Sim,
        candidate_count: u32,
        comptime dispatches: []const robotgpu.Dispatch,
    ) void {
        const all_worlds_params: @TypeOf(sim.pipe.params) = sim.pipe.params;
        defer sim.pipe.params = all_worlds_params;
        sim.pipe.params.counts.world_count = candidate_count;
        sim.pipe.params.counts.first_world = 0;
        sim.runDispatches(dispatches);
    }

    /// CANDIDATES RUN AHEAD OF THEIR PLANNERS: `decisions` decisions of the batch's first `candidate_count` worlds
    /// alone - the candidates (`robotgpu.isCandidate`) - each following its plan from the plan's decision
    /// `first_plan_decision` on, while every world after them holds exactly as it is. The batch's world count is
    /// lowered to the candidates' for the lookahead and restored after it: every dispatch is sized to it and every
    /// kernel keeps to it, so no other world is touched. A world's step reads its own state alone, so a candidate run
    /// ahead this way ends exactly where it would in the same decisions of every world. Each decision is one
    /// submission (`submitLookaheadDecision`).
    pub fn stepCandidatesAhead(
        sim: *Sim,
        candidate_count: u32,
        first_plan_decision: u32,
        decisions: u32,
        physics_steps: u32,
    ) void {
        const plans_are_whole: bool = sim.pipe.params.options.plan_form == .whole_actions;
        assertf(plans_are_whole, @src(), "a lookahead around the policy acts: stepCandidatesAroundPolicy", .{});
        const all_worlds_params: @TypeOf(sim.pipe.params) = sim.pipe.params;
        const world_count: u32 = all_worlds_params.counts.world_count;
        assertf(candidate_count <= world_count, @src(), "{d} candidates of {d} worlds", .{
            candidate_count,
            world_count,
        });
        defer sim.pipe.params = all_worlds_params;
        sim.pipe.params.counts.world_count = candidate_count;
        sim.pipe.params.counts.first_world = 0;
        var decision: u32 = 0;
        while (decision < decisions) : (decision += 1) {
            const plan_decision: u32 = first_plan_decision + decision;
            sim.pipe.params.options.plan_decision = @floatFromInt(plan_decision);
            sim.submitLookaheadDecision(physics_steps);
        }
    }

    /// CANDIDATES RUN AHEAD AROUND THE POLICY (`robot.PlanForm.offsets_around_policy`): as `stepCandidatesAhead`,
    /// but at each decision the policy chooses for every candidate first - on the kit's rows for them,
    /// `candidate_rows`, one a candidate (`chooseWithKit`) - and the decision then adds each candidate's plan's offset
    /// to its choice and gives it through the action filter, unexplored (`submitLookaheadDecision`). A candidate's
    /// plan of zeros is the policy's own lookahead from its planner's state.
    pub fn stepCandidatesAroundPolicy(
        sim: *Sim,
        comptime M: type,
        kit: z.robot_latent_kit.LatentKit(M),
        candidate_rows: z.robot_latent_kit.LatentKit(M).PolicyRows,
        candidate_count: u32,
        first_plan_decision: u32,
        decisions: u32,
        physics_steps: u32,
    ) void {
        const around_policy: bool = sim.pipe.params.options.plan_form == .offsets_around_policy;
        assertf(around_policy, @src(), "a lookahead of whole-action plans: stepCandidatesAhead", .{});
        assertf(candidate_rows.rows == candidate_count, @src(), "rows for {d} candidates, {d} run ahead", .{
            candidate_rows.rows,
            candidate_count,
        });
        const all_worlds_params: @TypeOf(sim.pipe.params) = sim.pipe.params;
        defer sim.pipe.params = all_worlds_params;
        sim.pipe.params.counts.world_count = candidate_count;
        sim.pipe.params.counts.first_world = 0;
        // A candidate explores by its plan alone, which takes the flow's place.
        sim.pipe.params.options.exploration_spread = 0;
        sim.pipe.params.options.flow_corrections = .disabled;
        const candidates_first: u32 = 0;
        var decision: u32 = 0;
        while (decision < decisions) : (decision += 1) {
            const plan_decision: u32 = first_plan_decision + decision;
            sim.pipe.params.options.plan_decision = @floatFromInt(plan_decision);
            sim.chooseWithKit(M, kit, candidate_rows, candidates_first);
            sim.submitLookaheadDecision(physics_steps);
        }
    }

    /// ONE LOOKAHEAD DECISION SUBMITTED as one batch, over the batch's worlds as the parameters stand: the worlds that
    /// follow their plans given their plans at the plan's decision (`robotgpu.follow_plans`) - whole actions over
    /// what they had, or offsets added to the policy's choice and then given (`robotgpu.give_program`: the action
    /// filter; no exploration for a follower); each world's record - the state the action is taken from, and the
    /// action (`robotgpu.record_rows`); the decision's physics, as `submitDecision` steps it; its end - the
    /// observation, then the judgement - as `submitDecisionEnd`; and each candidate's score
    /// (`robotgpu.score_candidates`). None of an episode's programs: a candidate is no episode of its own - nothing
    /// restarts or pushes it - so a lookahead takes no clock. Returns at once; the GPU works on.
    fn submitLookaheadDecision(sim: *Sim, physics_steps: u32) void {
        const tables_given: bool = sim.counts.reference_feature_frames > 0;
        assertf(tables_given, @src(), "a lookahead's judgement needs the clips' reference tables", .{});
        const around_policy: bool = sim.pipe.params.options.plan_form == .offsets_around_policy;
        sim.pipe.beginBatch(sim.pipe.params);
        sim.runDispatches(&robotgpu.follow_plans_program);
        if (around_policy) {
            sim.runDispatches(&robotgpu.give_program);
        }
        sim.runDispatches(&robotgpu.record_program);
        sim.runDispatches(&robotgpu.decision_start_program);
        var physics_step: u32 = 0;
        while (physics_step < physics_steps) : (physics_step += 1) {
            sim.runDispatches(&robotgpu.before_step_program);
            sim.runDispatches(&robotgpu.step_program);
            sim.runDispatches(&robotgpu.after_step_program);
        }
        sim.runDispatches(&robotgpu.observe_program);
        sim.runDispatches(&robotgpu.judge_program);
        sim.runDispatches(&robotgpu.score_candidates_program);
        sim.pipe.endBatch();
    }

    /// THE WORLDS THAT FOLLOW THEIR PLANS AT A DECISION (`robotgpu.follow_plans`), over the batch: each given its
    /// plan's action at the plan's decision `plan_decision` - for a planner, the decisions since its replan, its
    /// `robotgpu.PlanFollowing` deciding whether it follows. Called by a trainer after the policy's action is given
    /// (`actWithKit`) and before the decision's record, so the plan's action is the one the physics takes and the
    /// learner keeps; the worlds that do not follow keep the policy's action. The candidates take their plans' actions
    /// too - what they reach before the next replan's copy is discarded.
    pub fn followPlans(sim: *Sim, plan_decision: u32) void {
        const options_before: robotgpu.StepOptions = sim.pipe.params.options;
        defer sim.pipe.params.options = options_before;
        sim.pipe.params.options.plan_decision = @floatFromInt(plan_decision);
        sim.runDispatches(&robotgpu.follow_plans_program);
    }

    /// EVERY PLANNER's PLAN SET TO ITS CURRENT ACTION, held at every knot: a plan to start from where a planner has
    /// none. The actions are read back from the simulator.
    pub fn startPlansFromActions(sim: *Sim, gpa: Allocator, planning: *Planning) !void {
        const actions_array: @FieldType(robotgpu.WorldStateLayout, "actions") = sim.layout.world_f.actions;
        const action: []f32 = try gpa.alloc(f32, planning.action_count);
        defer gpa.free(action);
        for (planning.planners(), 0..) |planner_world, planner_index| {
            var action_read: Pipe.RangeRequest(.world_f) =
                try sim.pipe.requestRange(gpa, .world_f, actions_array.at(planner_world, 0), planning.action_count);
            while (!action_read.collect(action)) {
                std.atomic.spinLoopHint();
            }
            const plan: []f32 = planning.planOf(planner_index);
            var knot: u32 = 0;
            while (knot < planning.knot_count) : (knot += 1) {
                @memcpy(plan[knot * planning.action_count ..][0..planning.action_count], action);
            }
        }
    }

    /// THE PLANNERS CHOSEN BY TROUBLE (`robot.PlanningOptions.trouble_planners`), before a replan: of the characters -
    /// `character_count` worlds from `first_character` - the `trouble_planners` whose trouble is greatest become the
    /// planners (`Planning.replacePlanners`). A character's trouble is its loss fraction at the last decision's end
    /// projected along its rise from the decision before (`robot.lossFraction`, `robot.projectedHazard`), over
    /// `trouble_lookahead_decisions`: read back here, so the host waits for the decision before. The worlds that
    /// planned and no longer do follow no plan from here on. Memory: scratch from `gpa`, freed before the return.
    pub fn choosePlannersByTrouble(
        sim: *Sim,
        gpa: Allocator,
        planning: *Planning,
        first_character: u32,
        character_count: u32,
    ) !void {
        const options: PlanningOptions = planning.options;
        const chosen_count: u32 = options.trouble_planners;
        assertf(chosen_count >= 1 and chosen_count <= character_count, @src(), "{d} planners of {d} characters", .{
            chosen_count,
            character_count,
        });
        const troubles: []f32 = try gpa.alloc(f32, character_count);
        defer gpa.free(troubles);
        try sim.readTroubles(gpa, first_character, options.trouble_lookahead_decisions, troubles);
        const chosen: []u32 = try gpa.alloc(u32, chosen_count);
        defer gpa.free(chosen);
        mostInTrouble(troubles, chosen);
        for (chosen) |*character| {
            character.* += first_character;
        }
        const scratch: []f32 = try gpa.alloc(f32, planning.plans.len);
        defer gpa.free(scratch);
        const dropped: []u32 = try gpa.alloc(u32, planning.planner_worlds.len);
        defer gpa.free(dropped);
        const dropped_count: u32 = planning.replacePlanners(chosen, scratch, dropped);
        for (dropped[0..dropped_count]) |dropped_world| {
            sim.setPlanFollowing(dropped_world, .none);
        }
    }

    /// THE CHARACTERS' TROUBLE NOW, one a character of `out_troubles.len` from `first_character`: each one's loss
    /// fraction at the last decision's end projected along its rise from the decision before over
    /// `lookahead_decisions` (`robot.lossFraction`, `robot.projectedHazard`), read back - the host waits for the
    /// decision before. Memory: scratch from `gpa`, freed before the return.
    fn readTroubles(
        sim: *Sim,
        gpa: Allocator,
        first_character: u32,
        lookahead_decisions: f32,
        out_troubles: []f32,
    ) !void {
        const arrays: robotgpu.WorldStateLayout = sim.layout.world_f;
        const now: []f32 = try gpa.alloc(f32, out_troubles.len);
        defer gpa.free(now);
        const before: []f32 = try gpa.alloc(f32, out_troubles.len);
        defer gpa.free(before);
        try sim.readSingles(gpa, arrays.loss_fraction, first_character, now);
        try sim.readSingles(gpa, arrays.previous_loss_fraction, first_character, before);
        for (out_troubles, now, before) |*trouble, fraction, previous_fraction| {
            trouble.* = robot.projectedHazard(fraction, previous_fraction, lookahead_decisions);
        }
    }

    /// THE MODEL PLANNER's CHARACTERS AT A REPLAN, as acting rows (`Resident.chooseModelCharacters`): the physics'
    /// planners first - the model plans for them too, and its plans seed their next replan (the funnel) - then, of the
    /// other characters - `character_count` worlds from `first_character` - those in most trouble, `out_characters`
    /// filled. Memory: scratch from `gpa`, freed before the return.
    pub fn chooseModelCharacters(
        sim: *Sim,
        gpa: Allocator,
        planning: *const Planning,
        first_character: u32,
        character_count: u32,
        out_characters: []u32,
    ) !void {
        const physics_planners: []const u32 = planning.planners();
        assertf(physics_planners.len <= out_characters.len, @src(), "{d} planner states for {d} physics' planners", .{
            out_characters.len,
            physics_planners.len,
        });
        for (out_characters[0..physics_planners.len], physics_planners) |*character, planner_world| {
            character.* = planner_world - first_character;
        }
        const others: []u32 = out_characters[physics_planners.len..];
        if (others.len == 0) {
            return;
        }
        const troubles: []f32 = try gpa.alloc(f32, character_count);
        defer gpa.free(troubles);
        try sim.readTroubles(gpa, first_character, planning.options.trouble_lookahead_decisions, troubles);
        // The physics' planners are taken already: below every other character.
        for (physics_planners) |planner_world| {
            troubles[planner_world - first_character] = -inf(f32);
        }
        mostInTrouble(troubles, others);
    }

    /// THE FUNNEL's SEEDS FOR A REPLAN (`Planning.seeds`): for every physics' planner that was one of the model
    /// planner's states at its last decision (`model_owners`, as acting rows), that state's chosen plan
    /// (`model_plans`, [state][step][action]) as the planner's knots (`modelPlanAsKnots`, the model plan's steps
    /// `spans`); a planner the model did not plan for keeps no seed.
    pub fn seedFromModelPlans(
        planning: *Planning,
        first_character: u32,
        model_owners: []const ?usize,
        model_plans: []const f32,
        spans: []const u32,
    ) void {
        const plan_floats: usize = spans.len * planning.action_count;
        for (planning.planners(), 0..) |planner_world, planner_index| {
            const character: usize = planner_world - first_character;
            const state: ?usize = for (model_owners, 0..) |owner, state_index| {
                const owns_it: bool = if (owner) |held| held == character else false;
                if (owns_it) {
                    break state_index;
                }
            } else null;
            const model_state: usize = state orelse {
                planning.seeded[planner_index] = false;
                continue;
            };
            const model_plan: []const f32 = model_plans[model_state * plan_floats ..][0..plan_floats];
            const seed: []f32 = planning.seedOf(planner_index);
            modelPlanAsKnots(model_plan, spans, planning.action_count, planning.knot_count, planning.horizon, seed);
            planning.seeded[planner_index] = true;
        }
    }

    /// One number a world of `count` worlds from `first_world` - a single-number array's (`array`) - read back into
    /// `out_numbers`. The host waits for the device.
    fn readSingles(
        sim: *Sim,
        gpa: Allocator,
        array: robotgpu.WorldArray(.world_f, .single),
        first_world: u32,
        out_numbers: []f32,
    ) !void {
        const count: u32 = @intCast(out_numbers.len);
        const block_floats: u32 = array.stride * count;
        const blocks: []f32 = try gpa.alloc(f32, block_floats);
        defer gpa.free(blocks);
        var numbers_read: Pipe.RangeRequest(.world_f) =
            try sim.pipe.requestRange(gpa, .world_f, array.at(first_world, 0), block_floats);
        const wait_began_ms: f64 = wgpu.nowMs();
        while (!numbers_read.collect(blocks)) {
            std.atomic.spinLoopHint();
        }
        sim.noteWait(wait_began_ms);
        for (out_numbers, 0..) |*number, world| {
            number.* = blocks[world * array.stride];
        }
    }

    /// A REPLAN's FIRST HALF (`replan`): the candidates copied, their knots given, their scores begun - ready for the
    /// lookahead.
    pub fn beginReplan(
        sim: *Sim,
        gpa: Allocator,
        planning: *Planning,
        random: Random,
    ) !void {
        const candidates_per_planner: u32 = planning.options.candidates_per_planner;
        const horizon: f32 = float(planning.horizon);
        const shift: f32 = float(planning.options.replan_interval);
        // 1  The candidates.
        try sim.copyWorlds(gpa, planning.copy_sources);
        // 2  Their knots, planner by planner, then every candidate's in one write: the warm start; around the policy,
        //    the policy itself (a plan of zeros); a seeded planner's seed - the model planner's plan, the funnel -
        //    and the rest drawn.
        for (planning.planners(), 0..) |_, planner_index| {
            const first_candidate: usize = planning.firstCandidateOf(planner_index);
            const warm_start: []f32 = planning.candidateKnots(first_candidate);
            const plan: []const f32 = planning.planOf(planner_index);
            shiftedPlan(plan, planning.knot_count, planning.action_count, horizon, shift, warm_start);
            const end_candidate: usize = first_candidate + candidates_per_planner;
            var candidate: usize = first_candidate + 1;
            // The baseline - a plan of zeros: the policy itself around the policy, the servo as whole actions -
            // beside the warm start, always: the lookahead measures what it alone does, in the same physics
            // (`judgePlans`); then a seeded planner's seed.
            if (planning.runsBaselineCandidate()) {
                const at_baseline_place: bool = candidate == first_candidate + Planning.baseline_candidate;
                assertf(at_baseline_place, @src(), "the baseline's candidate after the warm start", .{});
                @memset(planning.candidateKnots(candidate), 0);
                candidate += 1;
            }
            const takes_seed: bool = planning.seeded[planner_index] and planning.form == .offsets_around_policy;
            if (takes_seed and candidate < end_candidate) {
                @memcpy(planning.candidateKnots(candidate), planning.seedOf(planner_index));
                candidate += 1;
            }
            planning.seeded[planner_index] = false;
            while (candidate < end_candidate) : (candidate += 1) {
                drawPlanAbout(
                    random,
                    warm_start,
                    planning.action_count,
                    planning.offset_count,
                    planning.action_scale,
                    planning.options.drawing,
                    planning.candidateKnots(candidate),
                );
            }
        }
        const first_world: u32 = 0;
        sim.uploadWorldBlocks("plan_knots", first_world, planning.candidate_knots);
        // 3  The lookahead's scores begun.
        sim.beginCandidateScores(planning.candidateCount());
    }

    /// A REPLAN's SECOND HALF (`replan`), after the lookahead: each planner's best candidate its new plan, given to the
    /// planner with how it will follow it.
    pub fn endReplan(
        sim: *Sim,
        gpa: Allocator,
        planning: *Planning,
        random: Random,
    ) !void {
        const candidates_per_planner: u32 = planning.options.candidates_per_planner;
        // 4  The choice.
        try sim.readCandidateScores(gpa, planning.candidate_scores);
        for (planning.planners(), 0..) |_, planner_index| {
            const first_candidate: usize = planning.firstCandidateOf(planner_index);
            const block_scores: []const f32 = planning.candidate_scores[first_candidate..][0..candidates_per_planner];
            const best_candidate: usize = first_candidate + bestInBlock(block_scores);
            @memcpy(planning.planOf(planner_index), planning.candidateKnots(best_candidate));
        }
        // 4b Which of the new plans teach: those that beat their baseline by the most.
        planning.judgePlans();
        // 5  The new plans on the device, each in its planner's own knots, and how each planner follows its plan
        //    until the next replan: at every decision at the following share, else at this decision alone
        //    (`robotgpu.PlanFollowing`) - and as whole actions, a plan that does not teach not at all: its records
        //    would label actions no better than the servo's. Drawn for every planner after every candidate's
        //    knots, so for a given seed the share changes nothing in the lookahead.
        const follows_teaching_plans_alone: bool = planning.form == .whole_actions;
        for (planning.planners(), planning.teaches[0..planning.planner_count], 0..) |planner_world, teaches, index| {
            const new_plan: []const f32 = planning.planOf(index);
            sim.uploadWorldArray("plan_knots", planner_world, new_plan);
            const uniform_draw: f32 = random.float(f32);
            const follows_every_decision: bool = uniform_draw < planning.options.plan_following_share;
            const follows_at_all: bool = teaches or !follows_teaching_plans_alone;
            const following: robotgpu.PlanFollowing = if (!follows_at_all)
                .none
            else if (follows_every_decision)
                .every_decision
            else
                .first_decision;
            sim.setPlanFollowing(planner_world, following);
        }
    }

    /// A REPLAN's LOOKAHEAD, RECORDED (`replan`'s step 3, between `beginReplan` and `endReplan`):
    ///
    ///     the start      the candidates observed where their copies stand, so the first record is of the state the
    ///                    lookahead starts from - not whatever observation the planner held when it was copied
    ///     each decision  the candidates following their plans as `stepTrainerCandidates` steps them - whole
    ///                    actions, or offsets around the trainer's policy - every candidate's record packed before
    ///                    the decision's physics; then the records copied into the trainer's candidates' ring, at the
    ///                    lookahead's step for the decision (`appendCandidateStep`)
    ///     the end        the candidates' states after the lookahead, packed where they stand: the lookahead's last
    ///                    records, whose state and frame a window reads and whose action none does
    ///
    /// A copy into the ring is queued after the decision that packed its records, and before the next packs over them.
    pub fn stepCandidatesAheadRecorded(
        sim: *Sim,
        comptime M: type,
        trainer: *z.robot_track_resident.Resident(M),
        planning: *const Planning,
        physics_steps: u32,
    ) void {
        const candidate_count: u32 = planning.candidateCount();
        const recording: z.robot_track_resident.CandidateRecording = trainer.candidate_recording.?;
        // The ring holds a block for every planner the planning has room for; the lookahead runs its planners'.
        const candidate_capacity: u32 = planning.candidateCapacity();
        assertf(recording.ring.envs == candidate_capacity, @src(), "a ring of {d} candidates for {d}", .{
            recording.ring.envs,
            candidate_capacity,
        });
        const block_size: u32 = planning.options.candidates_per_planner;
        assertf(recording.candidates_per_planner == block_size, @src(), "blocks of {d} candidates, recorded as {d}", .{
            block_size,
            recording.candidates_per_planner,
        });
        assertf(recording.lookahead_records == planning.horizon + 1, @src(), "a lookahead of {d} decisions in {d}", .{
            planning.horizon,
            recording.lookahead_records,
        });
        // The candidates' record blocks: the batch's first worlds', side by side from the first.
        const records: @FieldType(robotgpu.WorldStateLayout, "records") = sim.layout.world_f.records;
        const simulator_numbers: z.DeviceField = sim.pipe.deviceField(.world_f);
        const records_at: u32 = records.at(0, 0);
        // The start.
        sim.runOverCandidates(candidate_count, &robotgpu.observe_program);
        // Each decision, then its records.
        const one_decision: u32 = 1;
        var plan_decision: u32 = 0;
        while (plan_decision < planning.horizon) : (plan_decision += 1) {
            sim.stepTrainerCandidates(M, trainer, planning, plan_decision, one_decision, physics_steps);
            trainer.appendCandidateStep(simulator_numbers, records_at, records.stride, plan_decision);
        }
        // The end.
        sim.runOverCandidates(candidate_count, &robotgpu.record_program);
        trainer.appendCandidateStep(simulator_numbers, records_at, records.stride, planning.horizon);
    }

    /// A TRAINER's CANDIDATES RUN AHEAD, `decisions` decisions from the plans' decision `first_plan_decision`, in the
    /// plans' form: whole actions (`stepCandidatesAhead`), or offsets around the trainer's policy, which chooses for
    /// every candidate on the rows the trainer keeps for them (`stepCandidatesAroundPolicy`,
    /// `Resident.acceptCandidateActing`).
    pub fn stepTrainerCandidates(
        sim: *Sim,
        comptime M: type,
        trainer: *z.robot_track_resident.Resident(M),
        planning: *const Planning,
        first_plan_decision: u32,
        decisions: u32,
        physics_steps: u32,
    ) void {
        const candidate_count: u32 = planning.candidateCount();
        switch (planning.form) {
            .whole_actions => sim.stepCandidatesAhead(candidate_count, first_plan_decision, decisions, physics_steps),
            .offsets_around_policy => {
                const candidate_rows: ?z.robot_latent_kit.LatentKit(M).PolicyRows =
                    trainer.device_acting.?.candidate_rows;
                assertf(candidate_rows != null, @src(), "plans around the policy need its candidates' rows", .{});
                // The rows of the candidates the lookahead runs: the first of the rows kept for every block.
                var rows_run: z.robot_latent_kit.LatentKit(M).PolicyRows = candidate_rows.?;
                assertf(candidate_count <= rows_run.rows, @src(), "{d} candidates, rows for {d}", .{
                    candidate_count,
                    rows_run.rows,
                });
                rows_run.rows = candidate_count;
                // The candidates' policy is the flow's base, the one their plans are offsets around.
                sim.stepCandidatesAroundPolicy(
                    M,
                    trainer.baseKit(),
                    rows_run,
                    candidate_count,
                    first_plan_decision,
                    decisions,
                    physics_steps,
                );
            },
        }
    }

    /// THE FORM A TRAINER's PLANS TAKE NOW (`robot.PlanForm`): whole actions while the policy is no anchor - in the
    /// training's first phase, and in a run without phases - and from the second phase on the planning's own
    /// (`PlanningOptions.phase_two_form`).
    fn planFormNow(
        comptime M: type,
        trainer: *const z.robot_track_resident.Resident(M),
        options: PlanningOptions,
    ) robot.PlanForm {
        const in_phase_two: bool = trainer.options.phases.enabled and !trainer.inPhaseOne();
        return if (in_phase_two) options.phase_two_form else .whole_actions;
    }

    /// A REPLAN, for every planner at once - the teacher's round:
    ///
    ///     1  the candidates: each planner's block of the batch's first worlds made copies of it (`copyWorlds`)
    ///     2  their knots: each planner's warm start - its plan moved on by the replan interval (`shiftedPlan`) - its
    ///        first candidate; its baseline, a plan of zeros - the policy itself around the policy, the servo as
    ///        whole actions - its second (`Planning.baseline_candidate`); a seeded planner's seed - the model
    ///        planner's plan, the funnel - after them; the others drawn about the warm start (`drawPlanAbout`);
    ///        every candidate's given in one write
    ///     3  the lookahead: the scores begun, then the horizon's decisions, the candidates alone, each following
    ///        its plan, scored as each decision ends (`stepCandidatesAhead`; a trainer's, around its policy too,
    ///        `stepTrainerCandidates`)
    ///     4  the choice: the scores read back, each planner's best candidate (`bestInBlock`), its knots the
    ///        planner's new plan - and which of the new plans teach (`Planning.judgePlans`)
    ///     5  the new plans given to the planners' own knots, and each planner's draw: whether it follows its plan
    ///        at every decision until the next replan, or at this one alone (`PlanningOptions.plan_following_share`);
    ///        as whole actions, a plan that does not teach followed by no one
    ///
    /// The planners themselves are not stepped: the lookahead steps the candidates alone, and step 5 writes only the
    /// planners' knots and following. Steps 1 to 3's start are `beginReplan`, steps 4 and 5 `endReplan`: a trainer
    /// that records its candidates' lookaheads runs the lookahead between them itself.
    pub fn replan(
        sim: *Sim,
        gpa: Allocator,
        planning: *Planning,
        random: Random,
        physics_steps: u32,
    ) !void {
        try sim.beginReplan(gpa, planning, random);
        const plans_begin: u32 = 0;
        sim.stepCandidatesAhead(planning.candidateCount(), plans_begin, planning.horizon, physics_steps);
        try sim.endReplan(gpa, planning, random);
    }

    /// How world `world` follows its plan from now on (`robotgpu.PlanFollowing`, `robotgpu.follow_plans`): its
    /// `plan_following`.
    pub fn setPlanFollowing(
        sim: *Sim,
        world: u32,
        following: robotgpu.PlanFollowing,
    ) void {
        assertf(world < sim.counts.world_count, @src(), "setPlanFollowing: world {d} of {d}", .{
            world,
            sim.counts.world_count,
        });
        const following_array: @FieldType(robotgpu.WorldIntegersLayout, "plan_following") =
            sim.layout.world_u.plan_following;
        const following_value: u32 = @backingInt(following);
        const following_at: usize = following_array.at(world, 0);
        sim.pipe.uploadAt(.world_u, following_at, &.{following_value});
    }

    /// A LOOKAHEAD's SCORES BEGUN (`robotgpu.begin_candidate_scores`), before its first decision: every candidate
    /// of the first `candidate_count` worlds at a score of zero, not yet lost. Apart from `stepCandidatesAhead`, so a
    /// lookahead may be stepped in parts and scored as one.
    pub fn beginCandidateScores(sim: *Sim, candidate_count: u32) void {
        sim.runOverCandidates(candidate_count, &robotgpu.begin_candidate_scores_program);
    }

    /// The first `out_scores.len` worlds' scores (`robotgpu.candidate_scores`), read back: one number a candidate.
    pub fn readCandidateScores(sim: *Sim, gpa: Allocator, out_scores: []f32) !void {
        const first_world: u32 = 0;
        try sim.readSingles(gpa, sim.layout.world_f.candidate_scores, first_world, out_scores);
    }

    /// ONE WHOLE DECISION, as the CPU fleet's `step` is one and the twin's `CpuTwin.stepDecision`: its physics steps
    /// (`submitDecision`), its end - the observation, then the judgement (`submitDecisionEnd`) - then its pushes, the
    /// curriculum's round and its new episodes at the decision's clock, and the observation once more (`runResets`).
    /// The actions are the worlds', given before (`uploadWorldArray`, or `actWithKit`). ONE SUBMISSION: the three
    /// parts are one recording (`Compute.beginRecording`), every dispatch with its own copy of the parameters - the
    /// clock's among them, which the resets change - so the device runs the decision from its first physics step to
    /// its last reset without the host between. Returns at once; the GPU works on. The three parts are three phases
    /// of a round's time (`enterPhase`): the physics, the judgement, the resets.
    pub fn stepDecision(
        sim: *Sim,
        physics_steps: u32,
        clock: robotgpu.DecisionClock,
    ) void {
        sim.pipe.beginRecording();
        sim.enterPhase(.physics);
        sim.submitDecision(physics_steps);
        sim.enterPhase(.judgement);
        sim.submitDecisionEnd();
        sim.enterPhase(.resets);
        sim.runResets(clock);
        sim.pipe.submitRecording();
    }

    /// The head body the judgement measures, or none (robot_track's `Fleet.head`), for the decisions after.
    pub fn setHeadBody(sim: *Sim, head: ?usize) void {
        sim.pipe.params.options.setHeadBody(head);
    }

    /// THE TRACKING TASK's SETTINGS for every world, all of them (`robotgpu.TrackingSettings`), for the decisions
    /// after: the uniform's, then the judgement's weights uploaded into the model's table.
    pub fn setTracking(
        sim: *Sim,
        gpa: Allocator,
        settings: robotgpu.TrackingSettings,
    ) !void {
        // A curriculum needs bins: without them the starts would fall back to uniform while the fleet's follow it.
        if (settings.curriculum == .enabled and sim.counts.curriculum_bin_total == 0) {
            return error.CurriculumWithoutBins;
        }
        try robotgpu.applyTrackingSettings(settings, &sim.pipe.params.options);
        sim.setJudgementWeights(settings.judgement);
        // The boxes' numbers, a scratch of this call's own (`gpa`), uploaded and freed.
        const box_numbers: []f32 = try gpa.alloc(f32, 12 * sim.counts.joint_count);
        defer gpa.free(box_numbers);
        robotgpu.rotationBoxNumbers(settings.rotation_boxes, box_numbers);
        sim.pipe.uploadAt(.model_f, sim.layout.model_f.ball_boxes.at(0), box_numbers);
    }

    /// The episode's rules (`robotgpu.EpisodeOptions`), for the decisions after.
    pub fn setEpisodeRules(sim: *Sim, rules: robotgpu.EpisodeOptions) void {
        sim.pipe.params.options.setEpisodeRules(rules);
    }

    /// The judgement's weights - the tracker's reward weights and SuperMimic's scales - uploaded into the model's
    /// table (`robotgpu.judgementNumbers`), for the decisions after.
    pub fn setJudgementWeights(sim: *Sim, weights: robotgpu.JudgementWeights) void {
        var numbers: [robotgpu.judgement_number_count]f32 = undefined;
        robotgpu.judgementNumbers(weights, &numbers);
        sim.pipe.uploadAt(.model_f, sim.layout.model_f.judgement_weights.at(0), &numbers);
    }

    /// Each of `dispatches` added to the batch begun, in order - a dispatch with no invocations for this model left
    /// out.
    fn runDispatches(sim: *Sim, comptime dispatches: []const robotgpu.Dispatch) void {
        // Sized to the batch's worlds, which a lookahead lowers to its candidates' (`stepCandidatesAhead`): the
        // candidates are the batch's first worlds, so their dispatches launch no invocation for any other world.
        const batch_counts: robotgpu.Counts = sim.pipe.params.counts;
        inline for (dispatches) |dispatch| {
            const invocation_count: u32 = robotgpu.invocationCount(dispatch.invocations, batch_counts);
            // A model with none of the elements a dispatch runs over - no sites, say - has no work for it.
            if (invocation_count > 0) {
                sim.pipe.run(dispatch.kernel, invocation_count);
            }
        }
    }

    /// World `world`'s numbers of the per-world array `array_name` (a float array of `world_f`) set to `values`, from
    /// its first item, for the steps submitted after - what a test or a page gives each world its own way.
    pub fn uploadWorldArray(
        sim: *Sim,
        comptime array_name: [:0]const u8,
        world: u32,
        values: []const f32,
    ) void {
        const array: @FieldType(robotgpu.WorldStateLayout, array_name) = @field(sim.layout.world_f, array_name);
        // A world's block from its first number - fewer numbers fill its front - never past it into the next world's.
        assertf(values.len <= array.stride, @src(), "uploadWorldArray: {d} numbers into {s}'s block of {d}", .{
            values.len,
            array_name,
            array.stride,
        });
        const first_element: usize = array.offset + world * array.stride;
        sim.pipe.uploadAt(.world_f, first_element, values);
    }

    /// WORLDS MADE COPIES OF OTHERS (`robotgpu.copy_program`): world `w` takes world `sources[w]`'s whole state, and a
    /// world whose entry is null keeps its own. One entry a world. A source must not itself be a copy in the same
    /// call - every copy reads its source while others are written - and a world is never its own source. The table
    /// goes to the device in one write (an image of `copy_source`, allocated from `gpa` for this call alone).
    pub fn copyWorlds(sim: *Sim, gpa: Allocator, sources: []const ?u32) !void {
        const world_count: u32 = sim.counts.world_count;
        assertf(sources.len == world_count, @src(), "copyWorlds: {d} entries for {d} worlds", .{
            sources.len,
            world_count,
        });
        const table: @FieldType(robotgpu.WorldIntegersLayout, "copy_source") = sim.layout.world_u.copy_source;
        const table_image: []u32 = try gpa.alloc(u32, world_count * table.stride);
        defer gpa.free(table_image);
        @memset(table_image, robotgpu.no_copy_source);
        for (sources, 0..) |maybe_source, world_index| {
            const world: u32 = @intCast(world_index);
            const source: u32 = maybe_source orelse continue;
            assertf(source < world_count and source != world, @src(), "copyWorlds: world {d} from {d}", .{
                world,
                source,
            });
            assertf(sources[source] == null, @src(), "copyWorlds: world {d} is both a source and a copy", .{source});
            table_image[world * table.stride] = robotgpu.copySourceEntry(source);
        }
        sim.pipe.uploadAt(.world_u, table.offset, table_image);
        // Every world's entry is read: a copy may land anywhere in the batch.
        const params_before: @TypeOf(sim.pipe.params) = sim.pipe.params;
        defer sim.pipe.params = params_before;
        sim.pipe.params.counts.first_world = 0;
        sim.runDispatches(&robotgpu.copy_program);
    }

    /// Consecutive worlds' blocks of the per-world array `array_name` (a float array of `world_f`) set to `blocks`,
    /// from world `first_world`'s on, in one write: `blocks` is whole blocks of the array's stride, world after world,
    /// as the arena holds them - padding and all.
    pub fn uploadWorldBlocks(
        sim: *Sim,
        comptime array_name: [:0]const u8,
        first_world: u32,
        blocks: []const f32,
    ) void {
        const array: @FieldType(robotgpu.WorldStateLayout, array_name) = @field(sim.layout.world_f, array_name);
        const whole_blocks: bool = blocks.len % array.stride == 0;
        const block_count: usize = blocks.len / array.stride;
        const within_the_worlds: bool = first_world + block_count <= sim.counts.world_count;
        assertf(whole_blocks and within_the_worlds, @src(), "uploadWorldBlocks: {d} numbers of {s} from world {d}", .{
            blocks.len,
            array_name,
            first_world,
        });
        sim.pipe.uploadAt(.world_f, array.at(first_world, 0), blocks);
    }

    /// THE CURRICULUM's BINS GIVEN TO THE DEVICE, as `fleet` holds them: every bin's return, softmax share and
    /// long-run weight, and each clip's mixture as running sums (`Fleet.startBinRunningSums`) - four uploads into the
    /// host's window (`robotgpu.HostWindowLayout`). ONCE, before a run's first decision, or after a caller changes
    /// the fleet's bins by hand: from then on the device folds its own episodes into the bins and refreshes them
    /// itself, a kernel each decision (`robotgpu.curriculum_round`), and the host neither reads nor writes them.
    /// The running sums are this call's scratch, from `gpa`, freed before it returns.
    pub fn uploadStartBins(sim: *Sim, gpa: Allocator, fleet: *const track.Fleet) !void {
        // A fleet without a curriculum has no bins: nothing to give.
        if (fleet.bins_start.len == 0) {
            return;
        }
        const clip_count: usize = fleet.clips.len;
        const same_clips: bool = clip_count == sim.counts.clip_count;
        assertf(same_clips, @src(), "uploadStartBins: a fleet of {d} clips for a simulator of {d}", .{
            clip_count,
            sim.counts.clip_count,
        });
        const bin_total: usize = fleet.bins_start[clip_count];
        const same_bins: bool = bin_total == sim.counts.curriculum_bin_total;
        assertf(same_bins, @src(), "uploadStartBins: a fleet of {d} bins for a simulator of {d}", .{
            bin_total,
            sim.counts.curriculum_bin_total,
        });
        const running_sums: []f32 = try gpa.alloc(f32, bin_total);
        defer gpa.free(running_sums);
        fleet.startBinRunningSums(running_sums);
        const bins: robotgpu.HostWindowLayout = sim.layout.io;
        sim.pipe.uploadAt(.io, bins.bin_returns.at(0), fleet.bin_returns);
        sim.pipe.uploadAt(.io, bins.bin_softmax.at(0), fleet.bin_softmax);
        sim.pipe.uploadAt(.io, bins.bin_history_weights.at(0), fleet.bin_history_weights);
        sim.pipe.uploadAt(.io, bins.bin_running_sums.at(0), running_sums);
    }

    /// A RUN's FIRST EPISODES: every world from `first_world` on marked as having finished an episode, then started by
    /// the device's own resets (`robotgpu.new_episodes_program`) at `clock` - its clip and start frame drawn as any
    /// reset draws them, from the curriculum's bins as they were given (`uploadStartBins`) - and observed, so the
    /// first action reads the start's state. The worlds before `first_world` are a planner's candidates, which are
    /// no episodes of their own. Nothing is folded into the curriculum: no episode has ended. The flags are this
    /// call's scratch, from `gpa`.
    pub fn startEveryWorld(
        sim: *Sim,
        gpa: Allocator,
        first_world: u32,
        clock: robotgpu.DecisionClock,
    ) !void {
        const world_count: u32 = sim.counts.world_count;
        assertf(first_world < world_count, @src(), "startEveryWorld: from world {d} of {d}", .{
            first_world,
            world_count,
        });
        // Each started world's flags word, the finished bit alone - one block, the padding of each world's stride
        // zero, as the arena holds it.
        const flags_array: @FieldType(robotgpu.WorldIntegersLayout, "episode_flags") = sim.layout.world_u.episode_flags;
        const started_worlds: u32 = world_count - first_world;
        const flag_words: []u32 = try gpa.alloc(u32, started_worlds * flags_array.stride);
        defer gpa.free(flag_words);
        @memset(flag_words, 0);
        const finished_bit: u32 = robotgpu.episodeFlagBit(.finished);
        var started: u32 = 0;
        while (started < started_worlds) : (started += 1) {
            flag_words[started * flags_array.stride] = finished_bit;
        }
        sim.pipe.uploadAt(.world_u, flags_array.at(first_world, 0), flag_words);
        clock.applyTo(&sim.pipe.params.options);
        sim.pipe.beginBatch(sim.pipe.params);
        sim.runDispatches(&robotgpu.new_episodes_program);
        sim.runDispatches(&robotgpu.observe_program);
        sim.pipe.endBatch();
    }

    /// The tracking task's clip `clip` world `world` follows from now on, and the frame of it the world is at - the
    /// frame its servo aims past (`reference_targets`), which each physics step then advances (`advance_frames`).
    pub fn setWorldClip(sim: *Sim, world: u32, clip: u32, frame: u32) void {
        assertf(clip < sim.counts.clip_count, @src(), "setWorldClip: clip {d} of {d}", .{
            clip,
            sim.counts.clip_count,
        });
        assertf(world < sim.counts.world_count, @src(), "setWorldClip: world {d} of {d}", .{
            world,
            sim.counts.world_count,
        });
        const integers: robotgpu.WorldIntegersLayout = sim.layout.world_u;
        const clip_at: usize = integers.world_clip.offset + world * integers.world_clip.stride;
        const frame_at: usize = integers.world_frame.offset + world * integers.world_frame.stride;
        sim.pipe.uploadAt(.world_u, clip_at, &.{clip});
        sim.pipe.uploadAt(.world_u, frame_at, &.{frame});
    }

    /// Whether each limb's servo is at the stiffness its world's action gives it, for the steps submitted after.
    pub fn setLimbStiffness(sim: *Sim, limb_stiffness: robotgpu.Switch) void {
        sim.pipe.params.options.setLimbStiffness(limb_stiffness);
    }

    /// THE FILTER's SHARES (robot_track's `action_filter` and `stiffnessFilter`): how far each world's applied action
    /// moves toward its policy's before each physics step, for the decisions submitted after - the joints' offsets by
    /// the first, the limbs' stiffnesses by the second; 1 is no filter.
    pub fn setActionFilter(sim: *Sim, offsets_factor: f32, stiffness_factor: f32) void {
        sim.pipe.params.options.setActionFilter(offsets_factor, stiffness_factor);
    }

    /// How far one unit of a world's action reaches, in radians (robot_track's `action_scale`), for the decisions
    /// submitted after.
    pub fn setActionScale(sim: *Sim, scale: f32) void {
        sim.pipe.params.options.setActionScale(scale);
    }

    /// THE FLOOR every world stands on, for the steps submitted after: a plane facing up at the height of
    /// `ground.plane.point`, with its friction and margin (`robot.Floor`) - the floor of robot.zig's
    /// `pushFloorContacts`, its contacts made on the device by `floor_contacts`. The device's floor is horizontal: a
    /// plane facing any other way is refused.
    pub fn setFloor(sim: *Sim, ground: robot.Floor) error{FloorNotHorizontal}!void {
        try sim.pipe.params.options.setFloor(ground);
    }

    /// THE SERVO every world is driven by, for the steps submitted after: robot.zig's law (`robot.servoTorques`) with
    /// `law`'s spring and bound, toward rest or toward motion (`mode`) - its targets each world's `servo_targets` and,
    /// toward motion, `servo_target_velocities` (`uploadWorldArray`); its torques the worlds' applied forces. The
    /// tracking task's root assist is the CPU tracker's alone: the device has none.
    pub fn setServo(sim: *Sim, law: robot.ServoLaw, mode: robotgpu.ServoMode) void {
        sim.pipe.params.options.setServo(law, mode);
    }

    /// World `world`'s position coordinates set to `coordinates` (`coordinate_count` of them) - its joints' angles and
    /// distances, a free body's position and quaternion - for the steps submitted after. A world posed anew, rather
    /// than stepped there, should also forget its warm start (`forgetWarmStart`), as robot.zig's `Data` does.
    pub fn uploadWorldPositions(sim: *Sim, world: u32, coordinates: []const f32) void {
        sim.uploadWorldArray("joint_positions", world, coordinates);
    }

    /// World `world`'s warm start forgotten, for the steps submitted after - its next solve starting from its free
    /// acceleration, as a new world's does (robot.zig's `Data.forgetWarmStart`). For a world posed anew: the last
    /// pose's answer is no candidate for a different one.
    pub fn forgetWarmStart(sim: *Sim, world: u32) void {
        const zeros: [robotgpu.max_newton_dofs]f32 = @splat(0);
        sim.uploadWorldArray("warmstart_accelerations", world, zeros[0..sim.counts.dof_count]);
    }

    /// How many words `requestOverflow` brings back - the length its destination must have.
    pub fn overflowWordCount(sim: *const Sim) u32 {
        return sim.layout.world_u.overflow.stride * sim.counts.world_count;
    }

    /// EVERY WORLD'S OVERFLOW WORD, requested after the steps submitted so far: collected later into
    /// `overflowWordCount` words (`RangeRequest`), then read world by world (`overflowOf`). A word's bits name the
    /// capacities that world ran past in the step; zero is a step that fitted.
    pub fn requestOverflow(sim: *Sim, gpa: Allocator) Allocator.Error!Pipe.RangeRequest(.world_u) {
        const first_word: u32 = sim.layout.world_u.overflow.offset;
        const word_count: u32 = sim.overflowWordCount();
        return sim.pipe.requestRange(gpa, .world_u, first_word, word_count);
    }

    /// World `world`'s overflow word, from the words a collected `requestOverflow` brought back.
    pub fn overflowOf(sim: *const Sim, collected: []const u32, world: u32) u32 {
        const stride: u32 = sim.layout.world_u.overflow.stride;
        return collected[world * stride];
    }
};

/// A FLOOR `depth` above the lowest point of `model` posed at `coordinates`, so its lowest geoms stand that far into
/// it - found with robot.zig, under a floor high above everything, where each contact's distance is how far its geom's
/// lowest point lies below that floor. For the checks that compare a step on the floor, device against twin.
pub fn floorUnderLowestPoint(
    gpa: Allocator,
    model: *const robot.Model,
    coordinates: []const f32,
    depth: f32,
) !robot.Floor {
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    @memcpy(data.joint_positions, coordinates);
    robot.kinematics(model, &data);
    const probe_height: f32 = 10.0;
    const up: robot.Vec = .{ 0, 0, 1, 0 };
    const probe: robot.Floor = .{ .plane = .{ .point = .{ 0, 0, probe_height, 0 }, .normal = up } };
    try robot.pushFloorContacts(model, &data, probe);
    var lowest_distance: f32 = 0;
    for (data.contacts[0..data.contact_count]) |contact| {
        lowest_distance = @min(lowest_distance, contact.distance);
    }
    const floor_height: f32 = probe_height + lowest_distance + depth;
    const ground: robot.Floor = .{ .plane = .{ .point = .{ 0, 0, floor_height, 0 }, .normal = up } };
    return ground;
}

/// How many of `twin`'s rows, over every world, are of `kind` - read from the twin's own arrays, this process's memory
/// - so a check can say how many of the rows it compared were, say, the floor's contacts'.
pub fn countRowsOfKind(twin: *const Sim, kind: robot.ConstraintKind) u32 {
    const kinds: robotgpu.WorldArray(.world_u, .constraint_rows) = twin.layout.world_u.constraint_row_kind;
    const kind_number: u32 = @backingInt(kind);
    var rows_of_kind: u32 = 0;
    var world: u32 = 0;
    while (world < twin.counts.world_count) : (world += 1) {
        const row_count: u32 = twin.layout.world_u.constraint_row_count.load(world, 0);
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            rows_of_kind += @intFromBool(kinds.load(world, row) == kind_number);
        }
    }
    return rows_of_kind;
}

/// THE CONSTRAINT CHECK'S SCENE, one world of it: every limited joint at one of five places along its range - past
/// the lower end, inside its margin, free, inside the upper margin, past the upper end - chosen by world and joint, so
/// that the worlds between them meet every case, and every dof moving at a rate set by world and dof. `coordinates`
/// holds the model's coordinates, `rates` its dofs.
pub fn poseAroundLimits(
    model: *const robot.Model,
    world: u32,
    coordinates: []f32,
    rates: []f32,
) void {
    @memcpy(coordinates, model.reference_joint_positions);
    for (model.joint_range, 0..) |range_or_none, joint| {
        const range: [2]f32 = range_or_none orelse continue;
        const margin: f32 = model.joint_limit_margin[joint];
        const places: [5]f32 = .{
            range[0] - 0.02,
            range[0] + 0.5 * margin,
            0.5 * (range[0] + range[1]),
            range[1] - 0.5 * margin,
            range[1] + 0.03,
        };
        const place_index: usize = (world + joint) % places.len;
        coordinates[model.joint_first_coordinate[joint]] = places[place_index];
    }
    for (rates, 0..) |*rate, index| {
        const dof_factor: f32 = @floatFromInt(index % 7 + 1);
        const world_factor: f32 = @floatFromInt(world % 4 + 1);
        rate.* = 0.05 * dof_factor * world_factor;
    }
}

/// One array of the constraint program's, and how far the device may be from the twin in it (`largestGapEpsilons`).
pub const ConstraintArrayBar = struct {
    arena: robotgpu.Arena,
    name: [:0]const u8,
    layout: Shape,
    bar_epsilons: f32,

    /// How the array's numbers sit in a world's block: one a row, a row of dofs, a row of Jacobian slots - each
    /// compared only for the world's rows - or one a dof, compared whole.
    pub const Shape = enum { a_number_a_row, a_row_of_dofs, a_row_of_slots, a_number_a_dof };
};

/// The constraint program's arrays and their bars, from the gaps measured on lavapipe - the humanoid on its limits and
/// its floor - with room for other GPUs' rounding: the rows' violations and velocities a few epsilons; their Jacobians
/// a limit's +1 or -1 exactly and a contact's from its geometry (each dof's motion carried to the point: 2 measured),
/// so 16; what passes through a solve with the mass matrix's factor - M^-1 J^T, the rows' inertias, their
/// regularisers - the step's solve's bar. A ROW's TARGET ACCELERATION is built from none of those: it is
/// `-damping * velocity - stiffness * impedance * violation`, so the rounding of its two inputs arrives multiplied -
/// by about 105 and 2,600 with the default softness - and its bar is what the velocity's and the violation's bars
/// become through it: 105 x 16 + 2,600 x 4, about 12,200 (336 measured on lavapipe, 1,300 on an RTX 5070; a test of
/// vk-host-test holds the bar to that sum). Newton's answer on top. Of
/// that answer, the joint forces and accelerations (J^T f: 44 and 84 measured) keep the solve's bar, while each row's
/// own force is held to a wider one (11,399 measured): a contact's four pyramid edges can trade force among themselves
/// for nearly the same push on the robot, so how a contact's force splits across them is only weakly determined -
/// unique by the rows' softness, but barely - and two engines agreeing on the push can differ more on the split.
pub const constraint_array_bars = [_]ConstraintArrayBar{
    .{ .arena = .efc_f, .name = "constraint_violation", .layout = .a_number_a_row, .bar_epsilons = 4 },
    .{ .arena = .efc_f, .name = "constraint_jacobian_values", .layout = .a_row_of_slots, .bar_epsilons = 16 },
    .{
        .arena = .efc_f,
        .name = "constraint_inverse_inertia_jacobian",
        .layout = .a_row_of_dofs,
        .bar_epsilons = 1024,
    },
    .{ .arena = .efc_f, .name = "constraint_inertia", .layout = .a_number_a_row, .bar_epsilons = 1024 },
    .{ .arena = .efc_f, .name = "constraint_velocity", .layout = .a_number_a_row, .bar_epsilons = 16 },
    .{ .arena = .efc_f, .name = "constraint_regularizer", .layout = .a_number_a_row, .bar_epsilons = 1024 },
    .{ .arena = .efc_f, .name = "constraint_target_acceleration", .layout = .a_number_a_row, .bar_epsilons = 16384 },
    .{ .arena = .efc_f, .name = "constraint_force", .layout = .a_number_a_row, .bar_epsilons = 32768 },
    .{ .arena = .world_f, .name = "joint_accelerations", .layout = .a_number_a_dof, .bar_epsilons = 4096 },
    .{ .arena = .world_f, .name = "constraint_joint_forces", .layout = .a_number_a_dof, .bar_epsilons = 4096 },
};

/// What a comparison of the constraint program found (`ConstraintComparison`): each array's largest gap, whether the
/// rows' integers agree, how much was solved, and in how many worlds Newton's rounds differ - its stops are thresholds,
/// which rounding could cross a round sooner or later on some device, so the rounds are reported, not required equal.
pub const ConstraintVerdict = struct {
    gaps_epsilons: [constraint_array_bars.len]f32 = @splat(0),
    integers_agree: bool = true,
    rows_compared: u32 = 0,
    device_rounds: u32 = 0,
    twin_rounds: u32 = 0,
    worlds_rounds_differ: u32 = 0,
    largest_rounds_difference: u32 = 0,

    /// The array whose gap is the largest share of its own bar - an index into `constraint_array_bars`.
    pub fn worstArray(verdict: ConstraintVerdict) usize {
        var worst: usize = 0;
        var worst_share: f32 = 0;
        for (constraint_array_bars, verdict.gaps_epsilons, 0..) |array_bar, gap, index| {
            const share: f32 = gap / array_bar.bar_epsilons;
            if (share > worst_share) {
                worst_share = share;
                worst = index;
            }
        }
        return worst;
    }

    /// Whether the integers agree and every array came within its bar.
    pub fn agrees(verdict: ConstraintVerdict) bool {
        if (!verdict.integers_agree) {
            return false;
        }
        for (constraint_array_bars, verdict.gaps_epsilons) |array_bar, gap| {
            if (gap > array_bar.bar_epsilons) {
                return false;
            }
        }
        return true;
    }
};

/// THE CONSTRAINT PROGRAM, DEVICE AGAINST TWIN: its arrays requested from two Sims - one on a device, one on the CPU
/// twin - after a step submitted on both (`Sim.submitStep`, the constraint program inside it), collected as each copy
/// arrives, and compared. It never waits, so a page collects once a frame and a test collects in a loop - as
/// `StepComparison`:
///
///     the integers    each world's row count, each row's candidate, its Jacobian's dofs and their count - exactly;
///                     Newton's rounds, counted
///     the numbers     each row's quantities for the world's rows only, the dof arrays whole - each against its bar
pub const ConstraintComparison = struct {
    const IntegerWidth = enum { one_a_row, slots_a_row, one_a_world };
    const IntegerArray = struct { name: [:0]const u8, width: IntegerWidth };
    const integer_arrays = [_]IntegerArray{
        .{ .name = "constraint_row_source", .width = .one_a_row },
        .{ .name = "constraint_jacobian_nonzero_count", .width = .one_a_row },
        .{ .name = "constraint_jacobian_dofs", .width = .slots_a_row },
        .{ .name = "newton_iterations", .width = .one_a_world },
    };
    const float_count: usize = constraint_array_bars.len;

    /// A request for floats from either arena the constraint program writes them to.
    const FloatRequest = union(enum) {
        efc_f: Pipe.RangeRequest(.efc_f),
        world_f: Pipe.RangeRequest(.world_f),

        fn collect(float_request: *FloatRequest, numbers: []f32) bool {
            return switch (float_request.*) {
                .efc_f => |*pending| pending.collect(numbers),
                .world_f => |*pending| pending.collect(numbers),
            };
        }
        fn discard(float_request: *FloatRequest) void {
            switch (float_request.*) {
                .efc_f => |*pending| pending.discard(),
                .world_f => |*pending| pending.discard(),
            }
        }
    };

    world_count: u32,
    dof_count: u32,
    row_nonzero_capacity: u32,
    count_stride: u32 = 0,
    device_counts_request: ?Pipe.RangeRequest(.world_u) = null,
    twin_counts_request: ?Pipe.RangeRequest(.world_u) = null,
    device_counts: []u32 = &.{},
    twin_counts: []u32 = &.{},
    integer_strides: [integer_arrays.len]u32 = @splat(0),
    device_integer_requests: [integer_arrays.len]?Pipe.RangeRequest(.world_u) = @splat(null),
    twin_integer_requests: [integer_arrays.len]?Pipe.RangeRequest(.world_u) = @splat(null),
    device_integers: [integer_arrays.len][]u32 = @splat(&.{}),
    twin_integers: [integer_arrays.len][]u32 = @splat(&.{}),
    float_strides: [float_count]u32 = @splat(0),
    device_float_requests: [float_count]?FloatRequest = @splat(null),
    twin_float_requests: [float_count]?FloatRequest = @splat(null),
    device_floats: [float_count][]f32 = @splat(&.{}),
    twin_floats: [float_count][]f32 = @splat(&.{}),
    compared: bool = false,
    verdict: ConstraintVerdict = .{},

    /// Floats of `arena`, `count` of them from `offset`, requested from `sim`.
    fn requestFloats(
        gpa: Allocator,
        sim: *Sim,
        comptime arena: robotgpu.Arena,
        offset: u32,
        count: u32,
    ) Allocator.Error!FloatRequest {
        return switch (arena) {
            .efc_f => .{ .efc_f = try sim.pipe.requestRange(gpa, .efc_f, offset, count) },
            .world_f => .{ .world_f = try sim.pipe.requestRange(gpa, .world_f, offset, count) },
            else => @compileError("the constraint check compares the floats of efc_f and world_f"),
        };
    }

    /// Every array requested from `device_sim` and `twin_sim`, its buffers allocated from `gpa` and owned by the
    /// comparison until `deinit`.
    pub fn request(
        gpa: Allocator,
        device_sim: *Sim,
        twin_sim: *Sim,
    ) Allocator.Error!ConstraintComparison {
        const world_count: u32 = device_sim.counts.world_count;
        var comparison: ConstraintComparison = .{
            .world_count = world_count,
            .dof_count = device_sim.counts.dof_count,
            .row_nonzero_capacity = device_sim.counts.row_nonzero_capacity,
        };
        errdefer comparison.deinit(gpa);
        const counts_array: @FieldType(robotgpu.WorldIntegersLayout, "constraint_row_count") =
            device_sim.layout.world_u.constraint_row_count;
        const counts_length: u32 = counts_array.stride * world_count;
        comparison.count_stride = counts_array.stride;
        comparison.device_counts = try gpa.alloc(u32, counts_length);
        comparison.twin_counts = try gpa.alloc(u32, counts_length);
        comparison.device_counts_request =
            try device_sim.pipe.requestRange(gpa, .world_u, counts_array.offset, counts_length);
        comparison.twin_counts_request =
            try twin_sim.pipe.requestRange(gpa, .world_u, counts_array.offset, counts_length);
        inline for (integer_arrays, 0..) |integer_array, index| {
            const array: @FieldType(robotgpu.WorldIntegersLayout, integer_array.name) =
                @field(device_sim.layout.world_u, integer_array.name);
            const number_count: u32 = array.stride * world_count;
            comparison.integer_strides[index] = array.stride;
            comparison.device_integers[index] = try gpa.alloc(u32, number_count);
            comparison.twin_integers[index] = try gpa.alloc(u32, number_count);
            comparison.device_integer_requests[index] =
                try device_sim.pipe.requestRange(gpa, .world_u, array.offset, number_count);
            comparison.twin_integer_requests[index] =
                try twin_sim.pipe.requestRange(gpa, .world_u, array.offset, number_count);
        }
        inline for (constraint_array_bars, 0..) |array_bar, index| {
            const ArenaLayout: type = @FieldType(robotgpu.Layout, @tagName(array_bar.arena));
            const arena_layout: ArenaLayout = @field(device_sim.layout, @tagName(array_bar.arena));
            const array: @FieldType(ArenaLayout, array_bar.name) = @field(arena_layout, array_bar.name);
            const number_count: u32 = array.stride * world_count;
            comparison.float_strides[index] = array.stride;
            comparison.device_floats[index] = try gpa.alloc(f32, number_count);
            comparison.twin_floats[index] = try gpa.alloc(f32, number_count);
            comparison.device_float_requests[index] =
                try requestFloats(gpa, device_sim, array_bar.arena, array.offset, number_count);
            comparison.twin_float_requests[index] =
                try requestFloats(gpa, twin_sim, array_bar.arena, array.offset, number_count);
        }
        return comparison;
    }

    /// Requests still pending given up; the buffers freed.
    pub fn deinit(comparison: *ConstraintComparison, gpa: Allocator) void {
        if (comparison.device_counts_request) |*pending| {
            pending.discard();
        }
        if (comparison.twin_counts_request) |*pending| {
            pending.discard();
        }
        for (&comparison.device_integer_requests, &comparison.twin_integer_requests) |*device_request, *twin_request| {
            if (device_request.*) |*pending| {
                pending.discard();
            }
            if (twin_request.*) |*pending| {
                pending.discard();
            }
        }
        for (&comparison.device_float_requests, &comparison.twin_float_requests) |*device_request, *twin_request| {
            if (device_request.*) |*pending| {
                pending.discard();
            }
            if (twin_request.*) |*pending| {
                pending.discard();
            }
        }
        gpa.free(comparison.device_counts);
        gpa.free(comparison.twin_counts);
        for (comparison.device_integers, comparison.twin_integers) |device_integers, twin_integers| {
            gpa.free(device_integers);
            gpa.free(twin_integers);
        }
        for (comparison.device_floats, comparison.twin_floats) |device_floats, twin_floats| {
            gpa.free(device_floats);
            gpa.free(twin_floats);
        }
    }

    /// Whatever has arrived, collected; true once everything has and the arrays have been compared (`verdict`). Every
    /// request is collected on every call, so one still on its way keeps none of the others waiting.
    pub fn collect(comparison: *ConstraintComparison) bool {
        if (comparison.compared) {
            return true;
        }
        var all_arrived: bool = true;
        if (comparison.device_counts_request) |*pending| {
            if (pending.collect(comparison.device_counts)) {
                comparison.device_counts_request = null;
            }
        }
        if (comparison.twin_counts_request) |*pending| {
            if (pending.collect(comparison.twin_counts)) {
                comparison.twin_counts_request = null;
            }
        }
        all_arrived = comparison.device_counts_request == null and comparison.twin_counts_request == null;
        for (
            &comparison.device_integer_requests,
            &comparison.twin_integer_requests,
            comparison.device_integers,
            comparison.twin_integers,
        ) |*device_request, *twin_request, device_integers, twin_integers| {
            if (device_request.*) |*pending| {
                if (pending.collect(device_integers)) {
                    device_request.* = null;
                }
            }
            if (twin_request.*) |*pending| {
                if (pending.collect(twin_integers)) {
                    twin_request.* = null;
                }
            }
            all_arrived = all_arrived and device_request.* == null and twin_request.* == null;
        }
        for (
            &comparison.device_float_requests,
            &comparison.twin_float_requests,
            comparison.device_floats,
            comparison.twin_floats,
        ) |*device_request, *twin_request, device_floats, twin_floats| {
            if (device_request.*) |*pending| {
                if (pending.collect(device_floats)) {
                    device_request.* = null;
                }
            }
            if (twin_request.*) |*pending| {
                if (pending.collect(twin_floats)) {
                    twin_request.* = null;
                }
            }
            all_arrived = all_arrived and device_request.* == null and twin_request.* == null;
        }
        if (!all_arrived) {
            return false;
        }
        comparison.compare();
        comparison.compared = true;
        return true;
    }

    /// The integers exactly, world by world, for the twin's rows; then each array's numbers against its bar.
    fn compare(comparison: *ConstraintComparison) void {
        const verdict: *ConstraintVerdict = &comparison.verdict;
        var world: u32 = 0;
        while (world < comparison.world_count) : (world += 1) {
            const count_at: usize = world * comparison.count_stride;
            const device_rows: u32 = comparison.device_counts[count_at];
            const twin_rows: u32 = comparison.twin_counts[count_at];
            verdict.integers_agree = verdict.integers_agree and device_rows == twin_rows;
            verdict.rows_compared += twin_rows;
            for (integer_arrays, 0..) |integer_array, index| {
                const numbers_per_row: u32 = switch (integer_array.width) {
                    .one_a_row => 1,
                    .slots_a_row => comparison.row_nonzero_capacity,
                    .one_a_world => 0,
                };
                const block_start: usize = world * comparison.integer_strides[index];
                const device_block: []const u32 = comparison.device_integers[index][block_start..];
                const twin_block: []const u32 = comparison.twin_integers[index][block_start..];
                if (integer_array.width == .one_a_world) {
                    const device_rounds: u32 = device_block[0];
                    const twin_rounds: u32 = twin_block[0];
                    verdict.device_rounds += device_rounds;
                    verdict.twin_rounds += twin_rounds;
                    verdict.worlds_rounds_differ += @intFromBool(device_rounds != twin_rounds);
                    const rounds_difference: u32 = @max(device_rounds, twin_rounds) - @min(device_rounds, twin_rounds);
                    verdict.largest_rounds_difference = @max(verdict.largest_rounds_difference, rounds_difference);
                    continue;
                }
                const compared: u32 = twin_rows * numbers_per_row;
                const integers_equal: bool = eql(u32, device_block[0..compared], twin_block[0..compared]);
                verdict.integers_agree = verdict.integers_agree and integers_equal;
            }
            for (constraint_array_bars, 0..) |array_bar, index| {
                const numbers_per_row: u32 = switch (array_bar.layout) {
                    .a_number_a_row => 1,
                    .a_row_of_dofs, .a_number_a_dof => comparison.dof_count,
                    .a_row_of_slots => comparison.row_nonzero_capacity,
                };
                const block_start: usize = world * comparison.float_strides[index];
                const device_block: []const f32 = comparison.device_floats[index][block_start..];
                const twin_block: []const f32 = comparison.twin_floats[index][block_start..];
                if (array_bar.layout == .a_number_a_dof) {
                    const gap: f32 =
                        largestGapEpsilons(device_block[0..numbers_per_row], twin_block[0..numbers_per_row], 0);
                    verdict.gaps_epsilons[index] = @max(verdict.gaps_epsilons[index], gap);
                    continue;
                }
                var row: u32 = 0;
                while (row < twin_rows) : (row += 1) {
                    const row_start: usize = row * numbers_per_row;
                    const device_row: []const f32 = device_block[row_start..][0..numbers_per_row];
                    const twin_row: []const f32 = twin_block[row_start..][0..numbers_per_row];
                    const gap: f32 = largestGapEpsilons(device_row, twin_row, 0);
                    verdict.gaps_epsilons[index] = @max(verdict.gaps_epsilons[index], gap);
                }
            }
        }
    }
};

/// What a comparison of the step found (`StepComparison`): every array's largest gap, in
/// `step_array_bars`' order (zero for an array the model has none of), and the array whose gap is the largest
/// share of its own bar - that gap, and that bar.
pub const StepVerdict = struct {
    gaps_epsilons: [step_array_bars.len]f32 = @splat(0),
    worst_array: []const u8 = "",
    worst_gap_epsilons: f32 = 0,
    worst_bar_epsilons: f32 = 1,

    /// Whether every array came within its bar.
    pub fn agrees(verdict: StepVerdict) bool {
        return verdict.worst_gap_epsilons <= verdict.worst_bar_epsilons;
    }
};

/// THE STEP, DEVICE AGAINST TWIN: every array of `step_array_bars` requested from two Sims - one on a
/// device, one on the CPU twin - after the steps submitted so far, collected as each copy arrives, and compared. It
/// never waits, so a page collects once a frame and a test collects in a loop:
///
///     request    both Sims: every array the model has (Geno has no sites), each into buffers of its own
///     collect    whatever has arrived; once everything has, the arrays compared world by world - each quantity
///                against its own size (`largestGapEpsilons`), each array against its own bar - and true from then on
///     verdict    what the comparison found, kept by value once collected
pub const StepComparison = struct {
    const array_count: usize = step_array_bars.len;

    world_count: u32,
    /// Each array's block length a world, from the layout - zero for an array the model has none of.
    strides: [array_count]u32 = @splat(0),
    device_requests: [array_count]?Pipe.RangeRequest(.world_f) = @splat(null),
    twin_requests: [array_count]?Pipe.RangeRequest(.world_f) = @splat(null),
    device_numbers: [array_count][]f32 = @splat(&.{}),
    twin_numbers: [array_count][]f32 = @splat(&.{}),
    compared: bool = false,
    verdict: StepVerdict = .{},

    /// Every array requested from `device_sim` and `twin_sim`, its buffers allocated from `gpa` and owned by the
    /// comparison until `deinit`.
    pub fn request(
        gpa: Allocator,
        device_sim: *Sim,
        twin_sim: *Sim,
    ) Allocator.Error!StepComparison {
        var comparison: StepComparison = .{ .world_count = device_sim.counts.world_count };
        errdefer comparison.deinit(gpa);
        const state: robotgpu.WorldStateLayout = device_sim.layout.world_f;
        inline for (step_array_bars, 0..) |array_bar, index| {
            // An array the step leaves unwritten for this model is not compared: no request, its stride left zero.
            const written: bool = switch (array_bar.written) {
                .always => true,
                .when_damped => device_sim.has_dof_damping,
            };
            if (written) {
                const array: @FieldType(robotgpu.WorldStateLayout, array_bar.name) = @field(state, array_bar.name);
                const number_count: u32 = array.stride * comparison.world_count;
                comparison.strides[index] = array.stride;
                if (number_count > 0) {
                    comparison.device_numbers[index] = try gpa.alloc(f32, number_count);
                    comparison.twin_numbers[index] = try gpa.alloc(f32, number_count);
                    comparison.device_requests[index] =
                        try device_sim.pipe.requestRange(gpa, .world_f, array.offset, number_count);
                    comparison.twin_requests[index] =
                        try twin_sim.pipe.requestRange(gpa, .world_f, array.offset, number_count);
                }
            }
        }
        return comparison;
    }

    /// Requests still pending given up; the buffers freed.
    pub fn deinit(comparison: *StepComparison, gpa: Allocator) void {
        for (&comparison.device_requests, &comparison.twin_requests) |*device_request, *twin_request| {
            if (device_request.*) |*pending| {
                pending.discard();
            }
            if (twin_request.*) |*pending| {
                pending.discard();
            }
        }
        for (comparison.device_numbers, comparison.twin_numbers) |device_numbers, twin_numbers| {
            gpa.free(device_numbers);
            gpa.free(twin_numbers);
        }
    }

    /// Whatever has arrived, collected; true once everything has and the arrays have been compared (`verdict`).
    pub fn collect(comparison: *StepComparison) bool {
        if (comparison.compared) {
            return true;
        }
        // Every request is collected on every call - one still on its way does not keep the others waiting - so this
        // visits them all rather than stopping at the first that has not arrived.
        var all_arrived: bool = true;
        for (
            &comparison.device_requests,
            &comparison.twin_requests,
            comparison.device_numbers,
            comparison.twin_numbers,
        ) |*device_request, *twin_request, device_numbers, twin_numbers| {
            if (device_request.*) |*pending| {
                if (pending.collect(device_numbers)) {
                    device_request.* = null;
                }
            }
            if (twin_request.*) |*pending| {
                if (pending.collect(twin_numbers)) {
                    twin_request.* = null;
                }
            }
            all_arrived = all_arrived and device_request.* == null and twin_request.* == null;
        }
        if (!all_arrived) {
            return false;
        }
        comparison.compare();
        comparison.compared = true;
        return true;
    }

    /// Every array, a world's block at a time - so a scale a whole block shares (the mass matrix) is that world's.
    fn compare(comparison: *StepComparison) void {
        for (step_array_bars, 0..) |array_bar, index| {
            const stride: u32 = comparison.strides[index];
            var world: u32 = 0;
            while (stride > 0 and world < comparison.world_count) : (world += 1) {
                const block_start: usize = world * stride;
                const device_block: []const f32 = comparison.device_numbers[index][block_start..][0..stride];
                const twin_block: []const f32 = comparison.twin_numbers[index][block_start..][0..stride];
                const sharing: u32 = array_bar.numbers_sharing_scale;
                const gap: f32 = largestGapEpsilons(device_block, twin_block, sharing);
                const verdict: *StepVerdict = &comparison.verdict;
                verdict.gaps_epsilons[index] = @max(verdict.gaps_epsilons[index], gap);
                const share_of_bar: f32 = gap / array_bar.bar_epsilons;
                const worst_share: f32 = verdict.worst_gap_epsilons / verdict.worst_bar_epsilons;
                if (share_of_bar > worst_share) {
                    verdict.worst_array = array_bar.name;
                    verdict.worst_gap_epsilons = gap;
                    verdict.worst_bar_epsilons = array_bar.bar_epsilons;
                }
            }
        }
    }
};
