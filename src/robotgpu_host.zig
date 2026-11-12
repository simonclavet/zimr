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

const Allocator = std.mem.Allocator;
const wgpu = z.wgpu;

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

/// THE GAP BETWEEN THE DEVICE'S NUMBERS AND THE TWIN'S, in epsilons - each difference measured against the size of the
/// quantity it belongs to, not of the number alone. A vector, a motion or an inertia is judged as a whole: an error
/// that is small beside the inertia's large diagonal is small, even where it falls on a component close to zero. So
/// the numbers go in groups of `numbers_sharing_scale` (zero: the whole of `numbers`, one world's block), and each
/// group's scale is its largest magnitude on the twin, at least 1:
///
///     group            [ 52.1   0.0004   -0.0002   12.3 ]           scale 52.1
///     gap of a number  |device - twin| / (epsilon * scale)          the largest over every group returned
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
        var scale: f32 = 1.0;
        for (twin_numbers[group_start..group_end]) |twin_number| {
            scale = @max(scale, @abs(twin_number));
        }
        const device_group: []const f32 = device_numbers[group_start..group_end];
        const twin_group: []const f32 = twin_numbers[group_start..group_end];
        for (device_group, twin_group) |device_number, twin_number| {
            const gap: f32 = @abs(device_number - twin_number) / (epsilon * scale);
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

/// ONE MODEL'S WORLDS ON A PIPE: the pipe, the model's counts and the layout of every array (this file's head).
pub const Sim = struct {
    pipe: Pipe,
    counts: robotgpu.Counts,
    layout: robotgpu.Layout,
    /// Whether the model has damping, so the step writes the damped velocity update's arrays.
    has_dof_damping: bool,

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
        return sim;
    }

    /// The twin's world arena `arena` zeroed as far as this simulation's layout reaches - the end of its last array,
    /// every world's block - rather than the whole static array, which a desktop build sizes for thousands of worlds.
    fn clearTwinWorldArena(comptime arena: robotgpu.Arena, sim: Sim) void {
        const used_end: u32 = sim.worldArenaEnd(arena);
        const twin_arena: []robotgpu.ArenaElement(arena) = &@field(robotgpu.g.B, @tagName(arena));
        @memset(twin_arena[0..used_end], 0);
    }

    /// HOW FAR THIS SIMULATION's WORLD ARENA `arena` REACHES: the end of its last array, every world's block counted.
    /// Everything every world holds in that arena lies below it - what a caller reads or uploads to take, or to
    /// give, every world's state at once.
    pub fn worldArenaEnd(sim: *const Sim, comptime arena: robotgpu.Arena) u32 {
        const ArenaLayout: type = @FieldType(robotgpu.Layout, @tagName(arena));
        const arena_layout: ArenaLayout = @field(sim.layout, @tagName(arena));
        var used_end: u32 = 0;
        inline for (@typeInfo(ArenaLayout).@"struct".field_names) |array_name| {
            const array: @FieldType(ArenaLayout, array_name) = @field(arena_layout, array_name);
            const array_end: u32 = array.offset + array.stride * sim.counts.world_count;
            used_end = @max(used_end, array_end);
        }
        return used_end;
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
        // Every world's first episode begins with nothing discounted yet: its discount's power is one, as a start sets
        // it (`begin_reset`) - the twin's creation does the same.
        const one = [1]f32{1};
        var world: u32 = 0;
        while (world < nworld) : (world += 1) {
            sim.pipe.uploadAt(.world_f, layout.world_f.episode_discount_powers.at(world, 0), &one);
        }
        return sim;
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
        clock: robotgpu.DecisionClock,
    ) void {
        // The policy's inputs from the state as it is now (the program observes first).
        sim.runDispatches(&robotgpu.policy_inputs_program);
        const arrays: robotgpu.WorldStateLayout = sim.layout.world_f;
        const inputs_at: u32 = arrays.policy_inputs.at(0, 0);
        const given_at: u32 = arrays.actions.at(0, 0);
        const chosen_at: u32 = arrays.chosen_actions.at(0, 0);
        kit.actWithSimulator(acting, sim.pipe.deviceField(.world_f), inputs_at, given_at, chosen_at);
        sim.giveActions(clock);
    }

    /// THE DECISION's ACTION (`robotgpu.give_program`), after the policy's choice: the exploration, at the clock of
    /// the decision about to be stepped (`robotgpu.DecisionClock`), then the action filter into the actions.
    pub fn giveActions(sim: *Sim, clock: robotgpu.DecisionClock) void {
        clock.applyTo(&sim.pipe.params.options);
        sim.runDispatches(&robotgpu.give_program);
    }

    /// THE RESETS (`robotgpu.reset_program`), after a decision's end, at the decision's clock
    /// (`robotgpu.DecisionClock`): the decision's pushes, then every world whose episode ended begins another.
    /// Then the observation program again, so a reset world's next action reads its new episode's state.
    pub fn runResets(sim: *Sim, clock: robotgpu.DecisionClock) void {
        clock.applyTo(&sim.pipe.params.options);
        sim.runDispatches(&robotgpu.reset_program);
        sim.runDispatches(&robotgpu.observe_program);
    }

    /// ONE WHOLE DECISION, as the CPU fleet's `step` is one and the twin's `CpuTwin.stepDecision`: its physics steps
    /// (`submitDecision`), its end - the observation, then the judgement (`submitDecisionEnd`) - then its pushes and
    /// its new episodes at the decision's clock, and the observation once more (`runResets`). The actions are the
    /// worlds', given before (`uploadWorldArray`, or `actWithKit`). Returns at once; the GPU works on.
    pub fn stepDecision(
        sim: *Sim,
        physics_steps: u32,
        clock: robotgpu.DecisionClock,
    ) void {
        sim.submitDecision(physics_steps);
        sim.submitDecisionEnd();
        sim.runResets(clock);
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
        inline for (dispatches) |dispatch| {
            const invocation_count: u32 = robotgpu.invocationCount(dispatch.invocations, sim.counts);
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
/// regularisers - the step's solve's bar, and the target accelerations built from them (336 measured); Newton's answer
/// on top. Of
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
    .{ .arena = .efc_f, .name = "constraint_target_acceleration", .layout = .a_number_a_row, .bar_epsilons = 1024 },
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
