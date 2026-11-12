//! robotgpu_lab - THE SIMULATOR'S CHECKS, IN A PAGE: Geno's worlds stepped on the GPU and on the CPU twin side by side,
//! MuJoCo's humanoid's worlds solved against their joint limits on both - the constraint program, its rows and Newton
//! - and each check shown as agreeing or not. The same page runs on WebGPU in a browser and on Vulkan natively.
//!
//! The checks run as the simulator always does: nothing waits for the GPU. One step is submitted on both Sims, what
//! each check compares is requested from both, and every frame the page collects whatever has arrived:
//!
//!     first frame     both Sims: `world_u` filled with a poison word, every world posed in its own way, a step
//!                     submitted; the overflow words and every pose array requested
//!     later frames    the twin's arrays collected at once; the device's once their copies have finished
//!     then, per check the two compared - every world's overflow word zero on both (the step cleared it); every
//!                     pose within a few epsilons (the device's sine, cosine and square root differ from the CPU's
//!                     in the last bits); the constraint program's rows, their integers exactly, and Newton's answer
//!                     within its bars (`robotgpu_host.ConstraintComparison`)

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const robotgpu = @import("robotgpu");
const robotgpu_host = @import("robotgpu_host");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const Color = zm.Color;
const Sim = robotgpu_host.Sim;
const Pipe = robotgpu_host.Pipe;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
/// The kernels as this build embeds them: WGSL in a browser, SPIR-V natively.
/// The lab's settings.
const Settings = struct {
    /// Worlds in each Sim - Geno's 64 fit the tests' arena sizes.
    world_count: u32 = 64,
    /// The word `world_u` is filled with before the step, so a word the step did not write stands out.
    poison: u32 = 0xdead_beef,
    /// How far a world's pose moves each coordinate from the reference pose, per world and per coordinate class, so
    /// every world is posed differently and every joint turned.
    pose_step: f32 = 0.05,
    /// The constraint check: the margin each ranged joint of the humanoid's is given, and the inertia the rows'
    /// softness is measured against - MuJoCo's default, as Geno is trained with (`robot_geno.physicsOptions`).
    limit_margin: f32 = 0.05,
    constraint_inertia: z.robot.ConstraintInertia = .reference_pose,
};

/// Where the checks stand.
const Phase = enum {
    /// The browser is compiling the device's kernels, in the background; the page draws how far it has come.
    preparing,
    /// The step and the requests are still to be submitted.
    submit,
    /// Submitted; collecting whatever has arrived, once a frame.
    collecting,
    /// Every check collected and compared.
    done,
};

const State = struct {
    /// The allocator `init` was given, kept because the checks' requests need one for the twin's snapshots and a
    /// frame's callback receives none. The state owns everything allocated from it, freed in `deinit`.
    gpa: Allocator,
    settings: Settings,
    font: z.Font,
    geno: z.robot_mjcf.Imported,
    device_sim: Sim,
    twin_sim: Sim,
    /// A whole `world_u` arena of the poison word, uploaded before the step.
    poisoned_world_u: []u32,
    phase: Phase = .preparing,
    /// When the page's code started and when every pipeline was ready, on the host's clock, in milliseconds - in a
    /// browser that clock counts from the page's load.
    started_ms: f64,
    pipelines_ready_ms: ?f64 = null,
    /// The pipelines ready and to make, both device simulators' together, while the browser compiles them.
    pipelines_ready: u32 = 0,
    pipelines_total: u32 = 0,
    /// Whether the constraint check's device simulator has been asked for - made, or refused.
    constraint_sim_asked: bool = false,
    /// The three kernels the browser took longest over, the longest first; an empty name where there is none.
    slowest_kernels: [3]Pipe.PipelineMaking = @splat(.{ .kernel = "", .milliseconds = 0 }),
    /// Frames between the requests and the last copy arriving.
    frames_waited: u32 = 0,
    // The overflow check.
    overflow_device_request: ?Pipe.RangeRequest(.world_u) = null,
    overflow_twin_request: ?Pipe.RangeRequest(.world_u) = null,
    overflow_device_words: []u32,
    overflow_twin_words: []u32,
    overflow_done: bool = false,
    /// What the overflow check found: words not zero on the device, and words where device and twin differ.
    nonzero_device_words: u32 = 0,
    differing_words: u32 = 0,
    // The position stage's check: the comparison while its copies are on their way, then what it found.
    stage_comparison: ?robotgpu_host.StepComparison = null,
    stage_verdict: ?robotgpu_host.StepVerdict = null,
    /// The floor slots holding a contact on the twin after its step - so the page shows that the floor's arrays it
    /// compared held contacts, not empty slots.
    floor_contacts: u32 = 0,
    /// The constraint check's rows that are the floor's contacts', on the twin - so the page shows that they were among
    /// the rows compared.
    contact_rows: u32 = 0,
    // The constraint check: MuJoCo's humanoid, its hinges ranged - Geno's joints are balls, which take no range.
    humanoid: z.robot_mjcf.Imported,
    /// The device's workgroup memory, in bytes - what Newton's working set must fit in.
    workgroup_storage_bytes: u32,
    /// The constraint check's Sims, made once the step checks' requests are made: every twin works in the module's own
    /// arrays (`Sim.initTwin`), and the step checks' twin has snapshotted what they compare by then.
    constraint_device_sim: ?Sim = null,
    constraint_twin_sim: ?Sim = null,
    constraint_comparison: ?robotgpu_host.ConstraintComparison = null,
    constraint_verdict: ?robotgpu_host.ConstraintVerdict = null,
    /// Whether the device was refused for the constraint check: its workgroup memory too small for Newton.
    constraint_refused: bool = false,
};

/// Every kernel of robotgpu's step program with its WGSL, which the build translates and embeds as `<kernel>_wgsl` -
/// walked from the program, so the page dispatches exactly the kernels a step runs, in its order.
fn kernelTable() [robotgpu.step_program.len]Pipe.KernelWgsl {
    var table: [robotgpu.step_program.len]Pipe.KernelWgsl = undefined;
    inline for (robotgpu.step_program, 0..) |dispatch, index| {
        table[index] = .{ .name = dispatch.kernel, .wgsl = @embedFile(dispatch.kernel ++ "_wgsl") };
    }
    return table;
}

/// Every kernel of robotgpu's, the step program's then the constraint program's, with its WGSL - the constraint check
/// runs the step up to the free acceleration, then the rows, their projection and Newton.
fn allKernelTable() [robotgpu.kernels.len]Pipe.KernelWgsl {
    var table: [robotgpu.kernels.len]Pipe.KernelWgsl = undefined;
    inline for (robotgpu.kernels, 0..) |name, index| {
        table[index] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const started_ms: f64 = z.monotonicMilliseconds();
    const settings: Settings = .{};
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, .{});
    errdefer geno.deinit();
    // Stepped without its constraints: this check measures the smooth step against the twin, and the floor it is
    // given is for its contacts' slots alone - with the constraints disabled, no row is made.
    geno.model.opt.disable_constraints = true;
    // Every kernel of the step program, with its WGSL (`kernelTable`).
    const kernels: [robotgpu.step_program.len]Pipe.KernelWgsl = comptime kernelTable();
    // Made in the background: the browser compiles the kernels off the page's thread, and the page says how far it
    // has come until they are ready (`Phase.preparing`).
    const world_count: u32 = settings.world_count;
    var device_sim: Sim = try .initGpuInBackground(gpa, f.gpu.device, f.gpu.queue, &kernels, &geno.model, world_count);
    errdefer device_sim.deinit();
    var twin_sim: Sim = try .initTwin(gpa, &geno.model, settings.world_count);
    errdefer twin_sim.deinit();
    // A floor at the middle world's root height. Each world's root stands `pose_step x 3` above the last's (its z, the
    // free root's third coordinate - `worldPoseCoordinate`), so the worlds below the middle are deep in the floor,
    // every geom touching, the middle world's legs reach under it and the worlds above are clear: filled slots and
    // empty ones, among the step's compared arrays.
    const middle_world: f32 = @floatFromInt(settings.world_count / 2 + 1);
    const floor_height: f32 = geno.model.reference_joint_positions[2] + settings.pose_step * 3.0 * middle_world;
    const ground: z.robot.Floor = .{ .plane = .{ .point = .{ 0, 0, floor_height, 0 }, .normal = .{ 0, 0, 1, 0 } } };
    try device_sim.setFloor(ground);
    try twin_sim.setFloor(ground);
    const world_u_length: usize = @typeInfo(@FieldType(robotgpu.Buffers, "world_u")).array.len;
    const poisoned_world_u: []u32 = try gpa.alloc(u32, world_u_length);
    errdefer gpa.free(poisoned_world_u);
    @memset(poisoned_world_u, settings.poison);
    const word_count: u32 = device_sim.overflowWordCount();
    const overflow_device_words: []u32 = try gpa.alloc(u32, word_count);
    errdefer gpa.free(overflow_device_words);
    const overflow_twin_words: []u32 = try gpa.alloc(u32, word_count);
    errdefer gpa.free(overflow_twin_words);
    var humanoid: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_humanoid_model, .{});
    errdefer humanoid.deinit();
    // No floor is set, so its rows are its joint limits': the step makes them, projects them and solves them.
    humanoid.model.opt.constraint_inertia = settings.constraint_inertia;
    for (humanoid.model.joint_range, humanoid.model.joint_limit_margin) |range, *margin| {
        if (range != null) {
            margin.* = settings.limit_margin;
        }
    }
    s.* = .{
        .gpa = gpa,
        .settings = settings,
        .started_ms = started_ms,
        .font = font,
        .geno = geno,
        .device_sim = device_sim,
        .twin_sim = twin_sim,
        .poisoned_world_u = poisoned_world_u,
        .overflow_device_words = overflow_device_words,
        .overflow_twin_words = overflow_twin_words,
        .humanoid = humanoid,
        .workgroup_storage_bytes = z.wgpu.workgroupStorageLimit(f.gpu.device),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    if (s.overflow_device_request) |*pending| {
        pending.discard();
    }
    if (s.overflow_twin_request) |*pending| {
        pending.discard();
    }
    if (s.stage_comparison) |*pending| {
        pending.deinit(gpa);
    }
    if (s.constraint_comparison) |*pending| {
        pending.deinit(gpa);
    }
    if (s.constraint_twin_sim) |*sim| {
        sim.deinit();
    }
    if (s.constraint_device_sim) |*sim| {
        sim.deinit();
    }
    s.humanoid.deinit();
    gpa.free(s.overflow_twin_words);
    gpa.free(s.overflow_device_words);
    gpa.free(s.poisoned_world_u);
    s.twin_sim.deinit();
    s.device_sim.deinit();
    s.geno.deinit();
}

/// Coordinate `coordinate` of world `world`'s pose: the reference pose moved by an amount that grows with the world
/// and cycles with the coordinate, so no two worlds are posed alike.
fn worldPoseCoordinate(s: *const State, world: u32, coordinate: u32) f32 {
    const world_factor: f32 = @floatFromInt(world + 1);
    const coordinate_factor: f32 = @floatFromInt(coordinate % 7 + 1);
    return s.geno.model.reference_joint_positions[coordinate] + s.settings.pose_step * coordinate_factor * world_factor;
}

/// Dof `dof`'s rate in world `world` - its joint velocity - an amount that cycles with the dof and grows with the
/// world, so every world moves differently.
fn worldRate(s: *const State, world: u32, dof: u32) f32 {
    const world_factor: f32 = @floatFromInt(world % 4 + 1);
    const dof_factor: f32 = @floatFromInt(dof % 7 + 1);
    return s.settings.pose_step * dof_factor * world_factor;
}

/// Actuator `actuator`'s control in world `world` - an amount that changes sign and size with the actuator and grows
/// with the world, so every world drives its actuators differently.
fn worldControl(s: *const State, world: u32, actuator: u32) f32 {
    const world_factor: f32 = @floatFromInt(world % 5 + 1);
    const actuator_factor: f32 = @floatFromInt(@as(i32, @intCast(actuator % 7)) - 3);
    return s.settings.pose_step * actuator_factor * world_factor;
}

/// Dof `dof`'s applied force in world `world` - a force from outside the model, as a world's input - an amount that
/// grows with the world and cycles with the dof, so no two worlds are pushed alike.
fn worldForce(s: *const State, world: u32, dof: u32) f32 {
    const world_factor: f32 = @floatFromInt(world + 1);
    const dof_factor: f32 = @floatFromInt(dof % 5 + 1);
    return s.settings.pose_step * dof_factor * world_factor;
}

/// The floor slots of `twin` holding a contact, over every world - read from the twin's arrays, this process's memory.
fn countFloorContacts(twin: *const Sim) u32 {
    const filled: robotgpu.WorldArray(.world_u, .floor_slots) = twin.layout.world_u.floor_slot_filled;
    var contacts: u32 = 0;
    var world: u32 = 0;
    while (world < twin.counts.world_count) : (world += 1) {
        var slot: u32 = 0;
        while (slot < twin.counts.floor_slot_count) : (slot += 1) {
            contacts += filled.load(world, slot);
        }
    }
    return contacts;
}

/// Both Sims: `world_u` poisoned, every world posed, one step submitted; the overflow words and every pose array
/// requested.
fn submitChecks(s: *State) !void {
    const model: *const z.robot.Model = &s.geno.model;
    const coordinates: []f32 = try s.gpa.alloc(f32, model.coordinate_count);
    defer s.gpa.free(coordinates);
    const forces: []f32 = try s.gpa.alloc(f32, model.dof_count);
    defer s.gpa.free(forces);
    const rates: []f32 = try s.gpa.alloc(f32, model.dof_count);
    defer s.gpa.free(rates);
    const controls: []f32 = try s.gpa.alloc(f32, model.actuator_count);
    defer s.gpa.free(controls);
    const sims = [2]*Sim{ &s.device_sim, &s.twin_sim };
    for (sims) |sim| {
        sim.pipe.upload(.world_u, s.poisoned_world_u);
        var world: u32 = 0;
        while (world < s.settings.world_count) : (world += 1) {
            for (coordinates, 0..) |*coordinate, index| {
                coordinate.* = worldPoseCoordinate(s, world, @intCast(index));
            }
            sim.uploadWorldPositions(world, coordinates);
            for (forces, 0..) |*force, dof| {
                force.* = worldForce(s, world, @intCast(dof));
            }
            sim.uploadWorldArray("applied_joint_forces", world, forces);
            for (rates, 0..) |*rate, dof| {
                rate.* = worldRate(s, world, @intCast(dof));
            }
            sim.uploadWorldArray("joint_velocities", world, rates);
            for (controls, 0..) |*control, actuator| {
                control.* = worldControl(s, world, @intCast(actuator));
            }
            sim.uploadWorldArray("controls", world, controls);
        }
        sim.submitStep();
    }
    s.overflow_device_request = try s.device_sim.requestOverflow(s.gpa);
    s.overflow_twin_request = try s.twin_sim.requestOverflow(s.gpa);
    s.stage_comparison = try robotgpu_host.StepComparison.request(s.gpa, &s.device_sim, &s.twin_sim);
    // Counted now, from the twin's own arrays: the twin has stepped, and the constraint check's twin, which shares
    // them, has not run yet.
    s.floor_contacts = countFloorContacts(&s.twin_sim);
}

/// THE CONSTRAINT CHECK's SIMULATOR ON THE DEVICE, asked for while the step check's kernels are still compiling, so the
/// browser compiles both sets together - or refused, if the device's workgroup memory cannot hold Newton's working
/// set. It runs every kernel of robotgpu's, not the step's alone.
fn makeConstraintDeviceSim(f: *z.Frame, s: *State) !void {
    const model: *const z.robot.Model = &s.humanoid.model;
    const kernels: [robotgpu.kernels.len]Pipe.KernelWgsl = comptime allKernelTable();
    const world_count: u32 = s.settings.world_count;
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;
    s.constraint_device_sim = Sim.initGpuInBackground(s.gpa, device, queue, &kernels, model, world_count) catch |err| {
        if (err == error.WorkgroupMemoryTooSmall) {
            s.constraint_refused = true;
            return;
        }
        return err;
    };
}

/// THE THREE KERNELS THE BROWSER TOOK LONGEST OVER, kept longest first. A kernel both simulators run is compiled once
/// and found again by the second, so each kernel counts at the longer of its two makings.
fn noteSlowestKernels(s: *State) void {
    var makings: [robotgpu.kernels.len]Pipe.PipelineMaking = undefined;
    var making_count: usize = 0;
    if (s.constraint_device_sim) |*constraint_sim| {
        making_count = constraint_sim.pipe.pipelineMakings(&makings);
    }
    var step_makings: [robotgpu.step_program.len]Pipe.PipelineMaking = undefined;
    const step_count: usize = s.device_sim.pipe.pipelineMakings(&step_makings);
    for (step_makings[0..step_count]) |step_making| {
        // The step's kernel among the constraint simulator's, if that simulator was made.
        const twice_made: ?*Pipe.PipelineMaking = for (makings[0..making_count]) |*making| {
            if (eql(u8, making.kernel, step_making.kernel)) {
                break making;
            }
        } else null;
        if (twice_made) |making| {
            making.milliseconds = @max(making.milliseconds, step_making.milliseconds);
        } else {
            makings[making_count] = step_making;
            making_count += 1;
        }
    }
    for (&s.slowest_kernels) |*slowest| {
        // The longest not yet taken; taken, it is struck out.
        var longest: ?usize = null;
        for (makings[0..making_count], 0..) |making, index| {
            const is_longer: bool = if (longest) |so_far| making.milliseconds > makings[so_far].milliseconds else true;
            if (making.milliseconds > 0 and is_longer) {
                longest = index;
            }
        }
        const taken: usize = longest orelse break;
        slowest.* = makings[taken];
        makings[taken].milliseconds = 0;
    }
}

/// The constraint check's twin made beside its device simulator (`makeConstraintDeviceSim`), and both submitted
/// through the constraint program from the humanoid's worlds posed around their limits; every array it compares
/// requested. Nothing, if the device was refused.
fn submitConstraintCheck(s: *State) !void {
    const model: *const z.robot.Model = &s.humanoid.model;
    const world_count: u32 = s.settings.world_count;
    if (s.constraint_refused) {
        return;
    }
    s.constraint_twin_sim = try .initTwin(s.gpa, model, world_count);
    const device_sim: *Sim = &s.constraint_device_sim.?;
    const twin_sim: *Sim = &s.constraint_twin_sim.?;
    const coordinates: []f32 = try s.gpa.alloc(f32, model.coordinate_count);
    defer s.gpa.free(coordinates);
    const rates: []f32 = try s.gpa.alloc(f32, model.dof_count);
    defer s.gpa.free(rates);
    // A floor 2 cm above the lowest point of the first world's pose: its lowest geoms in it, and the other worlds,
    // posed apart, some deeper and some clear - the floor's contacts' rows beside the limits'.
    robotgpu_host.poseAroundLimits(model, 0, coordinates, rates);
    const ground: z.robot.Floor = try robotgpu_host.floorUnderLowestPoint(s.gpa, model, coordinates, 0.02);
    const sims = [2]*Sim{ device_sim, twin_sim };
    for (sims) |sim| {
        try sim.setFloor(ground);
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            robotgpu_host.poseAroundLimits(model, world, coordinates, rates);
            sim.uploadWorldPositions(world, coordinates);
            sim.uploadWorldArray("joint_velocities", world, rates);
        }
        sim.submitStep();
    }
    s.constraint_comparison = try robotgpu_host.ConstraintComparison.request(s.gpa, device_sim, twin_sim);
    // Counted now, from the twin's arrays, which the comparison has requested and nothing has changed since.
    s.contact_rows = robotgpu_host.countRowsOfKind(twin_sim, .contact);
}

/// The constraint program's arrays, collected as they arrive; once all have, the verdict kept and the buffers freed.
fn collectConstraintCheck(s: *State) void {
    const comparison: *robotgpu_host.ConstraintComparison = &(s.constraint_comparison orelse return);
    if (comparison.collect()) {
        s.constraint_verdict = comparison.verdict;
        comparison.deinit(s.gpa);
        s.constraint_comparison = null;
    }
}

/// The overflow words, once both have arrived, compared world by world.
fn collectOverflowCheck(s: *State) void {
    if (s.overflow_twin_request) |*pending| {
        if (pending.collect(s.overflow_twin_words)) {
            s.overflow_twin_request = null;
        }
    }
    if (s.overflow_device_request) |*pending| {
        if (pending.collect(s.overflow_device_words)) {
            s.overflow_device_request = null;
        }
    }
    const both_arrived: bool = s.overflow_twin_request == null and s.overflow_device_request == null;
    if (!both_arrived) {
        return;
    }
    var world: u32 = 0;
    while (world < s.settings.world_count) : (world += 1) {
        const device_word: u32 = s.device_sim.overflowOf(s.overflow_device_words, world);
        const twin_word: u32 = s.twin_sim.overflowOf(s.overflow_twin_words, world);
        s.nonzero_device_words += @intFromBool(device_word != 0);
        s.differing_words += @intFromBool(device_word != twin_word);
    }
    s.overflow_done = true;
}

/// The position stage's arrays, collected as they arrive; once all have, the comparison's verdict kept and its
/// buffers freed.
fn collectStageCheck(s: *State) void {
    const comparison: *robotgpu_host.StepComparison = &(s.stage_comparison orelse return);
    if (comparison.collect()) {
        s.stage_verdict = comparison.verdict;
        comparison.deinit(s.gpa);
        s.stage_comparison = null;
    }
}

fn update(f: *z.Frame, s: *State) void {
    switch (s.phase) {
        .preparing => {
            // The constraint check's device simulator is asked for first, so both sets of kernels compile together.
            if (!s.constraint_sim_asked) {
                s.constraint_sim_asked = true;
                makeConstraintDeviceSim(f, s) catch |err| {
                    std.log.err("robotgpu_lab: the constraint check's simulator failed: {s}", .{@errorName(err)});
                    s.phase = .done;
                    return;
                };
            }
            var progress: Pipe.PipelineProgress = s.device_sim.pipe.pipelineProgress();
            if (s.constraint_device_sim) |*constraint_sim| {
                const constraint_progress: Pipe.PipelineProgress = constraint_sim.pipe.pipelineProgress();
                progress.ready += constraint_progress.ready;
                progress.total += constraint_progress.total;
            }
            s.pipelines_ready = progress.ready;
            s.pipelines_total = progress.total;
            if (progress.isComplete()) {
                s.pipelines_ready_ms = z.monotonicMilliseconds();
                noteSlowestKernels(s);
                s.phase = .submit;
            }
        },
        .submit => {
            submitChecks(s) catch |err| {
                std.log.err("robotgpu_lab: the checks' requests failed: {s}", .{@errorName(err)});
                s.phase = .done;
                return;
            };
            submitConstraintCheck(s) catch |err| {
                std.log.err("robotgpu_lab: the constraint check's requests failed: {s}", .{@errorName(err)});
                s.phase = .done;
                return;
            };
            s.phase = .collecting;
        },
        .collecting => {
            s.frames_waited += 1;
            if (!s.overflow_done) {
                collectOverflowCheck(s);
            }
            collectStageCheck(s);
            collectConstraintCheck(s);
            const constraints_done: bool = s.constraint_verdict != null or s.constraint_refused;
            if (s.overflow_done and s.stage_verdict != null and constraints_done) {
                s.phase = .done;
            }
        },
        .done => {},
    }
    z.clearViewport(f, z.colors.slate_900);
    // Short lines, each a thing to read, so the page fits a phone's narrow screen as well as a desktop's.
    const title_color: Color = z.colors.slate_100;
    const text_color: Color = z.colors.slate_300;
    f.gl.text(.{ 16, 16 }, "robotgpu lab", .{ .size = 22, .color = title_color, .font = &s.font });
    f.gl.textf(.{ 16, 48 }, "Geno, {d} worlds, on the GPU and on the CPU twin", .{
        s.settings.world_count,
    }, .{ .size = 16, .color = text_color, .font = &s.font });
    const frame_word: []const u8 = if (s.frames_waited == 1) "frame" else "frames";
    // The overflow check.
    f.gl.text(.{ 16, 96 }, "Overflow words cleared by a step", .{ .size = 16, .color = title_color, .font = &s.font });
    if (s.overflow_done) {
        const agree: bool = s.nonzero_device_words == 0 and s.differing_words == 0;
        const verdict_color: Color = if (agree) z.colors.emerald_400 else z.colors.red_400;
        if (agree) {
            f.gl.textf(.{ 16, 124 }, "AGREE - all {d} worlds zero on both", .{s.settings.world_count}, .{
                .size = 16,
                .color = verdict_color,
                .font = &s.font,
            });
        } else {
            f.gl.textf(.{ 16, 124 }, "DIFFER - {d} device words not zero,", .{s.nonzero_device_words}, .{
                .size = 16,
                .color = verdict_color,
                .font = &s.font,
            });
            f.gl.textf(.{ 16, 152 }, "{d} unlike the twin's", .{s.differing_words}, .{
                .size = 16,
                .color = verdict_color,
                .font = &s.font,
            });
        }
    } else {
        f.gl.textf(.{ 16, 124 }, "checking ({d} {s})", .{ s.frames_waited, frame_word }, .{
            .size = 16,
            .color = text_color,
            .font = &s.font,
        });
    }
    // The pose check.
    f.gl.text(.{ 16, 200 }, "The step, device against twin", .{
        .size = 16,
        .color = title_color,
        .font = &s.font,
    });
    // Every line short enough for a phone held upright - about 48 characters at this size.
    if (s.stage_verdict) |verdict| {
        const agree: bool = verdict.agrees();
        const verdict_word: []const u8 = if (agree) "AGREE" else "DIFFER";
        const verdict_color: Color = if (agree) z.colors.emerald_400 else z.colors.red_400;
        f.gl.textf(.{ 16, 228 }, "{s} - largest gap {d:.2} epsilons", .{
            verdict_word,
            verdict.worst_gap_epsilons,
        }, .{ .size = 16, .color = verdict_color, .font = &s.font });
        f.gl.textf(.{ 16, 256 }, "in {s}, its bar {d:.0}", .{
            verdict.worst_array,
            verdict.worst_bar_epsilons,
        }, .{ .size = 14, .color = text_color, .font = &s.font });
        f.gl.textf(.{ 16, 280 }, "the floor's {d} contacts among the arrays", .{s.floor_contacts}, .{
            .size = 14,
            .color = text_color,
            .font = &s.font,
        });
    } else {
        f.gl.textf(.{ 16, 228 }, "checking ({d} {s})", .{ s.frames_waited, frame_word }, .{
            .size = 16,
            .color = text_color,
            .font = &s.font,
        });
    }

    // The constraint check.
    f.gl.text(.{ 16, 328 }, "The humanoid's constraints, device against twin", .{
        .size = 16,
        .color = title_color,
        .font = &s.font,
    });
    if (s.constraint_refused) {
        f.gl.textf(.{ 16, 356 }, "REFUSED - {d} bytes of workgroup memory", .{s.workgroup_storage_bytes}, .{
            .size = 16,
            .color = z.colors.red_400,
            .font = &s.font,
        });
    } else if (s.constraint_verdict) |verdict| {
        const agree: bool = verdict.agrees();
        const verdict_word: []const u8 = if (agree) "AGREE" else "DIFFER";
        const verdict_color: Color = if (agree) z.colors.emerald_400 else z.colors.red_400;
        f.gl.textf(.{ 16, 356 }, "{s} - {d} rows, {d} the floor's", .{
            verdict_word,
            verdict.rows_compared,
            s.contact_rows,
        }, .{
            .size = 16,
            .color = verdict_color,
            .font = &s.font,
        });
        // The rows' integers must be the twin's exactly. Newton's rounds may differ - its stops are thresholds - so
        // they are shown, not judged.
        const integers_word: []const u8 = if (verdict.integers_agree)
            "the rows' integers are the twin's"
        else
            "THE ROWS' INTEGERS ARE NOT THE TWIN'S";
        const integers_color: Color = if (verdict.integers_agree) text_color else z.colors.red_400;
        f.gl.text(.{ 16, 384 }, integers_word, .{ .size = 14, .color = integers_color, .font = &s.font });
        f.gl.textf(.{ 16, 406 }, "Newton's rounds {d} on the GPU, {d} on the twin", .{
            verdict.device_rounds,
            verdict.twin_rounds,
        }, .{ .size = 14, .color = text_color, .font = &s.font });
        f.gl.textf(.{ 16, 426 }, "{d} worlds differ, by {d} rounds at most", .{
            verdict.worlds_rounds_differ,
            verdict.largest_rounds_difference,
        }, .{ .size = 14, .color = text_color, .font = &s.font });
        // Every array's gap beside its bar, in epsilons - red past its bar - so one look at the page says which
        // quantity a GPU parts on, and by how much.
        inline for (robotgpu_host.constraint_array_bars, 0..) |array_bar, index| {
            const gap_epsilons: f32 = verdict.gaps_epsilons[index];
            const within_its_bar: bool = gap_epsilons <= array_bar.bar_epsilons;
            const line_color: Color = if (within_its_bar) text_color else z.colors.red_400;
            const row: f32 = @floatFromInt(index);
            const line_y: f32 = 452 + 20 * row;
            f.gl.textf(.{ 16, line_y }, "{d:.1} of {d:.0}  {s}", .{
                gap_epsilons,
                array_bar.bar_epsilons,
                array_bar.name,
            }, .{ .size = 13, .color = line_color, .font = &s.font });
        }
    } else {
        f.gl.textf(.{ 16, 356 }, "checking ({d} {s})", .{ s.frames_waited, frame_word }, .{
            .size = 16,
            .color = text_color,
            .font = &s.font,
        });
    }
    f.gl.textf(.{ 16, 664 }, "workgroup memory {d} bytes, Newton needs {d}", .{
        s.workgroup_storage_bytes,
        robotgpu.newton_workgroup_bytes,
    }, .{ .size = 14, .color = text_color, .font = &s.font });

    if (s.phase == .done) {
        f.gl.textf(.{ 16, 688 }, "every copy arrived after {d} {s}", .{ s.frames_waited, frame_word }, .{
            .size = 14,
            .color = text_color,
            .font = &s.font,
        });
    }
    // The pipelines' making: how many the browser has ready while it compiles them; then how long that took from the
    // page's start, and the three kernels it took longest over.
    if (s.pipelines_ready_ms) |ready_ms| {
        const seconds_from_start: f64 = (ready_ms - s.started_ms) / 1000.0;
        f.gl.textf(.{ 16, 716 }, "{d} pipelines ready {d:.1} s after the page's start", .{
            s.pipelines_total,
            seconds_from_start,
        }, .{ .size = 14, .color = text_color, .font = &s.font });
        for (s.slowest_kernels, 0..) |making, index| {
            const is_named: bool = making.kernel.len > 0;
            if (!is_named) {
                continue;
            }
            const row: f32 = @floatFromInt(index);
            const line_y: f32 = 738 + 20 * row;
            f.gl.textf(.{ 16, line_y }, "{d:.0} ms  {s}", .{ making.milliseconds, making.kernel }, .{
                .size = 13,
                .color = text_color,
                .font = &s.font,
            });
        }
    } else {
        f.gl.textf(.{ 16, 716 }, "preparing the kernels: {d} of {d} pipelines ready", .{
            s.pipelines_ready,
            s.pipelines_total,
        }, .{ .size = 14, .color = title_color, .font = &s.font });
    }
    // In a browser the host's clock counts from the page's load, so the start's own reading is how long the page
    // took to arrive, be compiled and begin.
    if (comptime z.host.is_browser) {
        const seconds_into_load: f64 = s.started_ms / 1000.0;
        f.gl.textf(.{ 16, 804 }, "the page's code started {d:.1} s into its load", .{seconds_into_load}, .{
            .size = 14,
            .color = text_color,
            .font = &s.font,
        });
    }
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - robotgpu lab",
            .width = 640,
            .height = 836,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
