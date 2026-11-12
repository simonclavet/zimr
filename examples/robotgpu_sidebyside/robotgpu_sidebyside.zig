//! robotgpu_sidebyside - the same robot, servoing the same motion, on two engines at once.
//!
//! LEFT, the CPU: robot.zig. RIGHT, the GPU: robotgpu, one world of the same model, given the same floor and the same
//! servo law (`robot.servoTorques`, run by the device's kernels). Each frame both are given the same target and step
//! once. The GPU's body poses are asked for after its step and drawn when they arrive, a frame or more later; its
//! simulation never waits for them. The two engines compute the same functions, so the two robots move together. They
//! part only as rounding accumulates: the GPU's arithmetic differs from the CPU's in its last bits, and a motion on the
//! edge of falling lets those bits grow.
//!
//! THE SCENES, one at a time - the button in the lower left moves to the next; each is built when shown and released
//! when left, so one GPU world exists at a time:
//!
//!     Geno, the dance     on the CPU the tracking task's own fleet (`robot_track.Fleet`, one character, Geno's
//!                         `tracking_task`: his servo, floor and failure rule); on the GPU the decision program
//!                         (`Sim.submitDecision`), the dance's frames on the device, each world's targets formed
//!                         there from them. The servo alone, no action - so both aim a frame ahead at the same pose,
//!                         hold a few seconds of the dance, fall, and start again together: when the fleet begins a new
//!                         episode, the GPU's world begins it from exactly the fleet's new state.
//!     The Go1, standing   dropped onto the floor and servoed to its home pose (the model's own keyframe), then dropped
//!                         again - the CPU side robot.zig's servo step as `ServoRun` takes it (`CpuServo`).
//!
//! Standard wgpu example contract: a `pub const app: z.AppSpec(State)`.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const codecs = z.codecs;
const rbt = z.robot;
const mjcf = z.mjcf;
const robot_mjcf = z.robot_mjcf;
const dance = z.robot_dance;
const geno = z.robot_geno;
const track = z.robot_track;
const wgpu = z.wgpu;
const robotgpu = @import("robotgpu");
const robotgpu_host = @import("robotgpu_host");

const Allocator = std.mem.Allocator;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Mat = zm.Mat;
const Quat = zm.Quat;
const Rectangle = z.Rectangle;
const vec = zm.vec;
const splat = zm.splat;
const mulMat = zm.mulMat;
const qmul = zm.qmul;
const rotate = zm.rotate;
const quatToMat = zm.quatToMat;
const quatFromTo = zm.quatFromTo;
const translation = zm.translation;
const scaling = zm.scaling;
const length3 = zm.length3;
const assertf = zm.assertf;
const Sim = robotgpu_host.Sim;
const Pipe = robotgpu_host.Pipe;
const PoseArrayRequest = Pipe.RangeRequest(.world_f);

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const bind_bvh = @embedFile("geno_bind.bvh");
const dance_bvh = @embedFile("dance1_20s.bvh");

/// The engine's z-up world turned into the page's y-up one: a quarter turn about x.
const to_y_up: Quat = .{ -0.70710678, 0.0, 0.0, 0.70710678 };

/// The free root's body - Geno's hips, the Go1's trunk - which the camera follows and the two engines are compared at.
const root_body: u32 = 1;

/// How one scene is looked at: how far apart its two robots are drawn, and where the camera looks from.
const SceneLook = struct {
    /// Each robot is drawn this far from where its engine puts it, the CPU's one way and the GPU's the other.
    drawn_apart: Vec,
    camera_distance: f32,
    /// The height the camera looks at, above the floor.
    camera_height: f32,
};

/// One side's colours: its rounded shapes and its flat ones.
const Colours = struct {
    round: Color,
    flat: Color,
};

/// The page's look, layout and motions: the colours, each scene's look, the Go1's servo and drops, the button.
const Settings = struct {
    background: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 },
    ground: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 },
    title: Color = .{ .r = 230, .g = 232, .b = 238, .a = 255 },
    text: Color = .{ .r = 170, .g = 176, .b = 190, .a = 255 },
    /// Each side's colours - its rounded shapes, and its flat ones (boxes: Geno's feet, the Go1's trunk).
    cpu_colours: Colours = .{
        .round = .{ .r = 120, .g = 170, .b = 225, .a = 255 },
        .flat = .{ .r = 150, .g = 190, .b = 140, .a = 255 },
    },
    gpu_colours: Colours = .{
        .round = .{ .r = 235, .g = 150, .b = 90, .a = 255 },
        .flat = .{ .r = 230, .g = 190, .b = 110, .a = 255 },
    },
    /// Across Geno's shoulders; along the Go1's flank, its trunk lying along x.
    geno_look: SceneLook = .{ .drawn_apart = .{ 0.6, 0, 0, 0 }, .camera_distance = 4.2, .camera_height = 0.9 },
    go1_look: SceneLook = .{ .drawn_apart = .{ 0, 0.35, 0, 0 }, .camera_distance = 1.8, .camera_height = 0.25 },
    /// The floor both engines stand their robots on.
    floor_friction: f32 = geno.floor_friction,
    /// The Go1's servo: robot.zig's law at the tracking task's gains.
    go1_law: rbt.ServoLaw = .{ .frequency = 20, .damping = 1, .max_acceleration = 3000 },
    /// How far above its home pose the Go1 is dropped from, and how many frames it is servoed before the next drop.
    go1_drop_height: f32 = 0.1,
    go1_frames_per_drop: usize = 180,
    /// The button that moves to the next scene, in the drawing area's logical pixels, from its lower left corner.
    button_width: f32 = 200,
    button_height: f32 = 44,
    button_margin: f32 = 16,
    button_fill: Color = .{ .r = 48, .g = 54, .b = 68, .a = 255 },
    title_size: f32 = 20,
    text_size: f32 = 16,
};

/// THE SCENES the page shows, in the order the button moves through them.
const SceneKind = enum {
    geno_dance,
    go1_stand,

    /// The scene after this one, the last followed by the first.
    fn next(kind: SceneKind) SceneKind {
        const scene_count: usize = std.enums.values(SceneKind).len;
        const next_index: usize = (@backingInt(kind) + 1) % scene_count;
        return @fromBackingInt(@intCast(next_index));
    }

    fn title(kind: SceneKind) []const u8 {
        return switch (kind) {
            .geno_dance => "Geno servoing the dance",
            .go1_stand => "The Go1 servoing to its home pose",
        };
    }

    fn look(kind: SceneKind, settings: Settings) SceneLook {
        return switch (kind) {
            .geno_dance => settings.geno_look,
            .go1_stand => settings.go1_look,
        };
    }
};

/// A ROBOT SERVOED ON THE CPU by robot.zig's own law, a step as `ServoRun` takes it and the device does: the floor's
/// contacts from the pose at the step's start, the bias forces, the servo's torques applied, the step - then the
/// kinematics and the mass matrix brought forward to the new state, which the next step's servo and the drawing read.
const CpuServo = struct {
    data: rbt.Data,
    /// The servo's scratches - dof_count numbers each, `dense` dof_count squared - and the torques it applies.
    accel_scratch: []f32,
    scratch: []f32,
    dense: []f32,
    full: []f32,
    torques: []f32,

    fn init(gpa: Allocator, model: *const rbt.Model) !CpuServo {
        const dof_count: usize = model.dof_count;
        const servo: CpuServo = .{
            .data = try rbt.Data.init(gpa, model),
            .accel_scratch = try gpa.alloc(f32, dof_count),
            .scratch = try gpa.alloc(f32, dof_count),
            .dense = try gpa.alloc(f32, dof_count * dof_count),
            .full = try gpa.alloc(f32, dof_count),
            .torques = try gpa.alloc(f32, dof_count),
        };
        return servo;
    }

    fn deinit(servo: *CpuServo, gpa: Allocator) void {
        gpa.free(servo.torques);
        gpa.free(servo.full);
        gpa.free(servo.dense);
        gpa.free(servo.scratch);
        gpa.free(servo.accel_scratch);
        servo.data.deinit();
    }

    /// One step toward `target`, at rest there (no target velocity), on `ground`.
    fn step(
        servo: *CpuServo,
        model: *const rbt.Model,
        law: rbt.ServoLaw,
        target: []const f32,
        ground: rbt.Floor,
    ) !void {
        const data: *rbt.Data = &servo.data;
        data.clearContacts();
        try rbt.pushFloorContacts(model, data, ground);
        rbt.biasForce(model, data);
        const dt: f32 = model.opt.timestep;
        rbt.servoTorques(
            model,
            data,
            target,
            null,
            law,
            null,
            dt,
            servo.accel_scratch,
            servo.scratch,
            servo.dense,
            servo.full,
            servo.torques,
        );
        @memcpy(data.applied_joint_forces, servo.torques);
        rbt.step(model, data);
        rbt.forward(model, data);
    }
};

/// GENO's DANCE: the copied clip, and the tracking task's own fleet following it on the CPU - one character, the
/// servo alone.
const GenoDance = struct {
    clip: dance.Clip,
    cpu: *track.Fleet,
    /// The policy's action: none, every number zero - the servo alone, so both engines aim at the reference itself.
    no_action: []f32,
    /// The clip as the device takes it (`robotgpu.ClipPoses`): its frames, each the model's coordinates - the robot
    /// is built from the character, so a frame is exactly its pose. Kept here, beside the clip whose frames it reads.
    device_clips: [1]robotgpu.ClipPoses,
};

/// THE GO1 STANDING: its home pose - the model's first keyframe - and robot.zig's servo holding it on the CPU.
const Go1Stand = struct {
    home: []f32,
    cpu: CpuServo,
};

/// What a scene's CPU side is, and what it servos to.
const Motion = union(SceneKind) {
    geno_dance: GenoDance,
    go1_stand: Go1Stand,
};

/// ONE FRAME's GPU POSES IN FLIGHT: its body positions and orientations, each asked for after the GPU's step and
/// collected on its own when its copy lands (each request collected once, then null), and the CPU's root at that same
/// step - so the two engines are compared at one step, not the GPU's pose a frame late against the CPU's now.
const PoseRequest = struct {
    positions: ?PoseArrayRequest,
    orientations: ?PoseArrayRequest,
    cpu_root: Vec,
};

/// THE GPU's POSES as the page draws them: the request in flight, the copies landing (four floats a body), and the
/// last poses to have arrived - with the CPU's root at their step.
const GpuPoses = struct {
    in_flight: ?PoseRequest = null,
    positions_landing: []f32 = &.{},
    orientations_landing: []f32 = &.{},
    positions: []Vec = &.{},
    orientations: []Quat = &.{},
    /// Whether any poses have arrived yet: until then the GPU's robot is not drawn.
    arrived: bool = false,
    cpu_root_at_their_step: Vec = zm.vec_zero,

    /// Room for `body_count` bodies' poses, none arrived yet.
    fn alloc(gpa: Allocator, body_count: usize) Allocator.Error!GpuPoses {
        const poses: GpuPoses = .{
            .positions_landing = try gpa.alloc(f32, 4 * body_count),
            .orientations_landing = try gpa.alloc(f32, 4 * body_count),
            .positions = try gpa.alloc(Vec, body_count),
            .orientations = try gpa.alloc(Quat, body_count),
        };
        return poses;
    }

    /// The request in flight given up - its poses are of a world begun again since.
    fn dropInFlight(poses: *GpuPoses) void {
        const request: *PoseRequest = if (poses.in_flight) |*in_flight| in_flight else return;
        if (request.positions) |*positions| {
            positions.discard();
        }
        if (request.orientations) |*orientations| {
            orientations.discard();
        }
        poses.in_flight = null;
    }

    fn free(poses: *GpuPoses, gpa: Allocator) void {
        poses.dropInFlight();
        gpa.free(poses.positions_landing);
        gpa.free(poses.orientations_landing);
        gpa.free(poses.positions);
        gpa.free(poses.orientations);
    }
};

/// ONE SCENE: its robot's model, its CPU side and motion, its GPU world - or null where the device refused the model,
/// `gpu_refusal` naming why - and the GPU's poses as they arrive.
const Scene = struct {
    kind: SceneKind,
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    motion: Motion,
    gpu: ?Sim,
    gpu_refusal: []const u8,
    gpu_poses: GpuPoses,
    /// The frames since this run began - Geno's frame of the clip - and how many runs have begun.
    frame: usize,
    runs: u32,
};

const State = struct {
    gpa: Allocator,
    settings: Settings = .{},
    font: z.Font,
    cam: z.OrbitCamera,
    cube: z.Mesh,
    sphere: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]Mat,
    scene: Scene,
};

/// Every kernel of robotgpu's with its WGSL, which the build translates and embeds beside this page as `<kernel>_wgsl`
/// - every program's (`robotgpu.kernels`): the step's, and the decision's around it.
fn kernelTable() [robotgpu.kernels.len]Pipe.KernelWgsl {
    var table: [robotgpu.kernels.len]Pipe.KernelWgsl = undefined;
    inline for (robotgpu.kernels, 0..) |name, index| {
        table[index] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

/// THE GPU's ROBOT: one world of `model`, following `clips` (none for a scene without a clip), on `ground` and driven
/// by the servo `law` - or null where the device refuses the model, the refusal named in `refusal`.
fn makeGpu(
    gpa: Allocator,
    f: *z.Frame,
    model: *const rbt.Model,
    clips: []const robotgpu.ClipPoses,
    ground: rbt.Floor,
    law: rbt.ServoLaw,
    refusal: *[]const u8,
) !?Sim {
    const kernels: [robotgpu.kernels.len]Pipe.KernelWgsl = comptime kernelTable();
    const world_count: u32 = 1;
    const device: wgpu.DeviceHandle = f.gpu.device;
    const queue: wgpu.QueueHandle = f.gpu.queue;
    var gpu: Sim = Sim.initGpuTracking(gpa, device, queue, &kernels, model, world_count, clips) catch |err| {
        refusal.* = @errorName(err);
        return null;
    };
    errdefer gpu.deinit();
    try gpu.setFloor(ground);
    gpu.setServo(law, .toward_rest);
    return gpu;
}

/// Geno's model, clip and fleet, into `scene`. The capture is read first: the model steps at the capture's frame time,
/// so the physics and both servos read one timestep.
fn loadGenoDance(gpa: Allocator, scene: *Scene) !void {
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bvh, null);
    defer capture.deinit();
    scene.doc = try codecs.xml.parse(gpa, z.robot_geno_model, null);
    scene.robot = try mjcf.readRobot(gpa, &scene.doc);
    // Armature 2 on every ball: the servo's strength standing (`robot_geno.standing_armature`).
    for (scene.robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = geno.standing_armature;
        }
    }
    var options: rbt.Options = geno.physicsOptions();
    options.timestep = capture.frame_time;
    scene.imported = try robot_mjcf.build(gpa, &scene.robot, options);
    var bind: geno.Posed = try geno.readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    const clip: dance.Clip = try geno.copyClip(gpa, &scene.imported, bind, capture);
    scene.motion = .{ .geno_dance = .{
        .clip = clip,
        .cpu = undefined,
        .no_action = undefined,
        .device_clips = undefined,
    } };
    const geno_dance: *GenoDance = &scene.motion.geno_dance;
    assertf(clip.nq == scene.imported.model.coordinate_count, @src(), "the dance's {d} coordinates, Geno's {d}", .{
        clip.nq,
        scene.imported.model.coordinate_count,
    });
    geno_dance.device_clips = .{.{
        .poses = geno_dance.clip.targets,
        .frame_count = @intCast(clip.frame_count),
        .frame_time = clip.frame_time,
    }};
    // Geno's task, as training and judging see it; the fleet keeps the clip's place, which the scene holds in place.
    const fleet_options: track.Fleet.Options = .{
        .envs = 1,
        .capacity = 64,
        .task = geno.tracking_task,
        // The task names bodies - the feet the floor may touch, the head it measures.
        .body_names = scene.imported.names,
    };
    geno_dance.cpu = try track.Fleet.init(gpa, &scene.imported.model, &.{&geno_dance.clip}, fleet_options);
    geno_dance.no_action = try gpa.alloc(f32, track.actionSize(&scene.imported.model));
    @memset(geno_dance.no_action, 0);
}

/// The Go1's model, home pose and servo, into `scene` - at the tracking task's physics.
fn loadGo1Stand(gpa: Allocator, scene: *Scene) !void {
    scene.doc = try codecs.xml.parse(gpa, z.robot_go1_model, null);
    scene.robot = try mjcf.readRobot(gpa, &scene.doc);
    scene.imported = try robot_mjcf.build(gpa, &scene.robot, geno.physicsOptions());
    const model: *const rbt.Model = &scene.imported.model;
    var cpu: CpuServo = try .init(gpa, model);
    errdefer cpu.deinit(gpa);
    // The home pose, the model's own: its first keyframe.
    if (scene.robot.keyframes.len == 0 or !robot_mjcf.applyKeyframe(model, &cpu.data, scene.robot.keyframes[0])) {
        return error.NoHomePose;
    }
    const home: []f32 = try gpa.dupe(f32, cpu.data.joint_positions);
    scene.motion = .{ .go1_stand = .{ .home = home, .cpu = cpu } };
}

/// The servo law a scene's GPU side is given: the CPU side's own.
fn lawOf(scene: *const Scene, settings: Settings) rbt.ServoLaw {
    return switch (scene.motion) {
        .geno_dance => |*geno_dance| geno_dance.cpu.options.task.gains.law(),
        .go1_stand => settings.go1_law,
    };
}

/// The CPU side's state: what the CPU's robot is drawn from, and what the GPU's starts from.
fn cpuDataOf(scene: *const Scene) *const rbt.Data {
    return switch (scene.motion) {
        .geno_dance => |*geno_dance| &geno_dance.cpu.data[0],
        .go1_stand => |*go1_stand| &go1_stand.cpu.data,
    };
}

/// The clips a scene's GPU world follows, as the device takes them: Geno's dance (`GenoDance.device_clips`); none for
/// the Go1, whose target the page uploads.
fn clipsOf(scene: *const Scene) []const robotgpu.ClipPoses {
    return switch (scene.motion) {
        .geno_dance => |*geno_dance| &geno_dance.device_clips,
        .go1_stand => &.{},
    };
}

/// How far the CPU's hips are from where the clip has them at its frame - the servo's own tracking error.
fn hipsFromClip(geno_dance: *const GenoDance) f32 {
    const fleet: *const track.Fleet = geno_dance.cpu;
    const frame: usize = @min(fleet.frame[0], geno_dance.clip.frame_count - 1);
    const reference: []const f32 = geno_dance.clip.pose(frame);
    const hips: []const f32 = fleet.data[0].joint_positions;
    // The free root's first three coordinates are its position.
    const apart: Vec = vec(hips[0] - reference[0], hips[1] - reference[1], hips[2] - reference[2]);
    return length3(apart);
}

/// The Go1 at rest `height` above its home pose - its free root raised - and brought forward to that state.
fn dropGo1(model: *const rbt.Model, go1_stand: *Go1Stand, height: f32) void {
    const data: *rbt.Data = &go1_stand.cpu.data;
    data.reset(model);
    data.forgetWarmStart();
    @memcpy(data.joint_positions, go1_stand.home);
    // The free root's coordinates are its position, x y z, then its orientation: the third is its height.
    data.joint_positions[2] += height;
    data.stage = .stale;
    rbt.forward(model, data);
}

/// THE GPU's WORLD BEGUN AGAIN where the CPU's robot now is: its pose and velocity, its warm start forgotten - and,
/// following a clip, its frame and its filter at rest, as the fleet's `startAt` leaves its character.
fn restartGpuFromCpu(scene: *Scene) void {
    const gpu: *Sim = if (scene.gpu) |*device_world| device_world else return;
    const cpu_data: *const rbt.Data = cpuDataOf(scene);
    gpu.uploadWorldPositions(0, cpu_data.joint_positions);
    gpu.uploadWorldArray("joint_velocities", 0, cpu_data.joint_velocities);
    gpu.forgetWarmStart(0);
    switch (scene.motion) {
        .geno_dance => |*geno_dance| {
            gpu.setWorldClip(0, 0, geno_dance.cpu.frame[0]);
            gpu.uploadWorldArray("applied_actions", 0, geno_dance.no_action);
        },
        .go1_stand => {},
    }
}

/// A NEW RUN of the scene, begun by the page: the CPU's robot started - Geno by the fleet at the clip's second frame,
/// the first with a frame before it (`Fleet.startAt`: the frame's pose, the velocity into it from the one before,
/// rested on the floor), the Go1 dropped - and the GPU's from exactly that state.
fn startRun(scene: *Scene, settings: Settings) void {
    scene.frame = 0;
    scene.runs += 1;
    switch (scene.motion) {
        .geno_dance => |*geno_dance| {
            const first_frame_with_a_velocity: usize = 1;
            geno_dance.cpu.startAt(0, 0, first_frame_with_a_velocity);
        },
        .go1_stand => |*go1_stand| dropGo1(&scene.imported.model, go1_stand, settings.go1_drop_height),
    }
    restartGpuFromCpu(scene);
}

/// THE SCENE `kind`, built in place - its model, its CPU side, its GPU world - and its first run begun. In place, since
/// the CPU side keeps hold of the model the scene owns.
fn loadScene(
    gpa: Allocator,
    f: *z.Frame,
    settings: Settings,
    kind: SceneKind,
    scene: *Scene,
) !void {
    scene.* = .{
        .kind = kind,
        .doc = undefined,
        .robot = undefined,
        .imported = undefined,
        .motion = undefined,
        .gpu = null,
        .gpu_refusal = "",
        .gpu_poses = .{},
        .frame = 0,
        .runs = 0,
    };
    switch (kind) {
        .geno_dance => try loadGenoDance(gpa, scene),
        .go1_stand => try loadGo1Stand(gpa, scene),
    }
    const model: *const rbt.Model = &scene.imported.model;
    const ground: rbt.Floor = .{ .friction = settings.floor_friction };
    const law: rbt.ServoLaw = lawOf(scene, settings);
    scene.gpu = try makeGpu(gpa, f, model, clipsOf(scene), ground, law, &scene.gpu_refusal);
    if (scene.gpu) |*gpu| {
        scene.gpu_poses = try GpuPoses.alloc(gpa, model.body_count);
        // Geno's action as the fleet takes it: its scale, and its filter's share.
        switch (scene.motion) {
            .geno_dance => |*geno_dance| {
                gpu.setActionScale(geno_dance.cpu.options.action_scale);
                const cpu_options: track.Fleet.Options = geno_dance.cpu.options;
                gpu.setActionFilter(cpu_options.action_filter, cpu_options.stiffness_filter);
                gpu.uploadWorldArray("actions", 0, geno_dance.no_action);
            },
            .go1_stand => {},
        }
    }
    startRun(scene, settings);
}

fn unloadScene(gpa: Allocator, scene: *Scene) void {
    if (scene.gpu) |*gpu| {
        scene.gpu_poses.free(gpa);
        gpu.deinit();
    }
    switch (scene.motion) {
        .geno_dance => |*geno_dance| {
            geno_dance.cpu.deinit();
            gpa.free(geno_dance.no_action);
            geno_dance.clip.deinit();
        },
        .go1_stand => |*go1_stand| {
            go1_stand.cpu.deinit(gpa);
            gpa.free(go1_stand.home);
        },
    }
    scene.imported.deinit();
    scene.robot.deinit();
    scene.doc.deinit();
}

/// One array's request collected into `destination` if its copy has landed - then null, as a request is collected
/// once. A null request has landed already.
fn collectArray(request: *?PoseArrayRequest, destination: []f32) void {
    const pending: *PoseArrayRequest = if (request.*) |*in_flight| in_flight else return;
    if (pending.collect(destination)) {
        request.* = null;
    }
}

/// THE GPU's POSES, after its step: the request in flight collected - once both its arrays have landed, they become
/// the poses drawn, with the CPU's root at their step - and the next asked for, with the CPU's root at this one. Only
/// one request is in flight at a time: the page draws the latest poses to arrive, however late.
fn collectGpuPoses(gpa: Allocator, scene: *Scene, gpu: *Sim) !void {
    const poses: *GpuPoses = &scene.gpu_poses;
    if (poses.in_flight) |*request| {
        collectArray(&request.positions, poses.positions_landing);
        collectArray(&request.orientations, poses.orientations_landing);
        const both_landed: bool = request.positions == null and request.orientations == null;
        if (!both_landed) {
            return;
        }
        for (poses.positions, poses.orientations, 0..) |*position, *orientation, body| {
            position.* = poses.positions_landing[4 * body ..][0..4].*;
            orientation.* = poses.orientations_landing[4 * body ..][0..4].*;
        }
        poses.cpu_root_at_their_step = request.cpu_root;
        poses.arrived = true;
        poses.in_flight = null;
    }
    const layout: robotgpu.WorldStateLayout = gpu.layout.world_f;
    const number_count: u32 = 4 * gpu.counts.body_count;
    poses.in_flight = .{
        .positions = try gpu.pipe.requestRange(gpa, .world_f, layout.body_positions.offset, number_count),
        .orientations = try gpu.pipe.requestRange(gpa, .world_f, layout.body_orientations.offset, number_count),
        .cpu_root = cpuDataOf(scene).body_positions[root_body],
    };
}

/// GENO's FRAME: the fleet steps its character (the servo alone, aiming a frame ahead), the GPU takes one decision of
/// one physics step (its targets from the clip on the device, its frame advanced there). When the fleet has begun a
/// new episode - its failure rule, or the clip's end - the GPU's world begins it from the fleet's new state, and the
/// poses still in flight, of the run that ended, are dropped.
fn stepGenoDance(gpa: Allocator, scene: *Scene, geno_dance: *GenoDance) !void {
    const fleet: *track.Fleet = geno_dance.cpu;
    _ = fleet.step(geno_dance.no_action);
    scene.frame = fleet.frame[0];
    const began_again: bool = fleet.dones[0];
    if (began_again) {
        scene.runs += 1;
    }
    const gpu: *Sim = if (scene.gpu) |*device_world| device_world else return;
    const physics_steps: u32 = 1;
    gpu.submitDecision(physics_steps);
    if (began_again) {
        restartGpuFromCpu(scene);
        scene.gpu_poses.dropInFlight();
        return;
    }
    try collectGpuPoses(gpa, scene, gpu);
}

/// THE GO1's FRAME: its servo toward its home pose on both engines, the page uploading the target to the GPU; dropped
/// again once it has stood its frames.
fn stepGo1Stand(
    gpa: Allocator,
    settings: Settings,
    scene: *Scene,
    go1_stand: *Go1Stand,
) !void {
    const ground: rbt.Floor = .{ .friction = settings.floor_friction };
    try go1_stand.cpu.step(&scene.imported.model, settings.go1_law, go1_stand.home, ground);
    if (scene.gpu) |*gpu| {
        gpu.uploadWorldArray("servo_targets", 0, go1_stand.home);
        gpu.submitStep();
        try collectGpuPoses(gpa, scene, gpu);
    }
    const next_frame: usize = scene.frame + 1;
    if (next_frame >= settings.go1_frames_per_drop) {
        startRun(scene, settings);
        return;
    }
    scene.frame = next_frame;
}

/// ONE FRAME OF BOTH ENGINES, the scene's own way.
fn stepScene(gpa: Allocator, settings: Settings, scene: *Scene) !void {
    switch (scene.motion) {
        .geno_dance => |*geno_dance| try stepGenoDance(gpa, scene, geno_dance),
        .go1_stand => |*go1_stand| try stepGo1Stand(gpa, settings, scene, go1_stand),
    }
}

/// The camera set for the scene: looking at its root from the scene's distance.
fn aimCamera(s: *State) void {
    const look: SceneLook = s.scene.kind.look(s.settings);
    s.cam = z.OrbitCamera.init(vec(0.0, look.camera_height, 0), look.camera_distance);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
        .cam = undefined,
        .cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0),
        .sphere = try z.genMeshSphere(gpa, 1.0, 10, 8),
        .cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2),
        .transform = .{zm.identity()},
        .scene = undefined,
    };
    try loadScene(gpa, f, s.settings, .geno_dance, &s.scene);
    aimCamera(s);
}

fn deinit(gpa: Allocator, s: *State) void {
    unloadScene(gpa, &s.scene);
}

/// The next scene shown in place of this one.
fn nextScene(s: *State, f: *z.Frame) !void {
    const next_kind: SceneKind = s.scene.kind.next();
    unloadScene(s.gpa, &s.scene);
    try loadScene(s.gpa, f, s.settings, next_kind, &s.scene);
    aimCamera(s);
}

fn toYUp(p: Vec) Vec {
    return rotate(to_y_up, p);
}

fn drawBall(
    s: *State,
    gl: *z.WgpuGl,
    at: Vec,
    radius: f32,
    colour: Color,
) void {
    s.transform[0] = mulMat(translation(at[0], at[1], at[2]), scaling(radius, radius, radius));
    z.drawMeshInstanced(gl, &s.sphere, &s.transform, colour);
}

/// A cylinder between two points: the mesh runs up its own y from 0 to 1.
fn drawCylinder(
    s: *State,
    gl: *z.WgpuGl,
    a: Vec,
    b: Vec,
    radius: f32,
    colour: Color,
) void {
    const along: Vec = b - a;
    const span: f32 = length3(along);
    const upright: Quat = if (span > 1.0e-6) quatFromTo(vec(0, 1, 0), along * splat(1.0 / span)) else zm.qidentity();
    s.transform[0] = mulMat(mulMat(translation(a[0], a[1], a[2]), quatToMat(upright)), scaling(radius, span, radius));
    z.drawMeshInstanced(gl, &s.cylinder, &s.transform, colour);
}

/// A capsule: a cylinder between two points, and a ball on each end.
fn drawCapsule(
    s: *State,
    gl: *z.WgpuGl,
    a: Vec,
    b: Vec,
    radius: f32,
    colour: Color,
) void {
    drawCylinder(s, gl, a, b, radius, colour);
    drawBall(s, gl, a, radius, colour);
    drawBall(s, gl, b, radius, colour);
}

/// Every geom of `model` where `positions` and `orientations` put its body, moved by `offset` - drawn from the model
/// itself, so any robot the engines simulate draws alike. zimr's capsules and cylinders lie along their local y;
/// meshes, which the engines do not collide, are not drawn.
fn drawRobot(
    s: *State,
    gl: *z.WgpuGl,
    model: *const rbt.Model,
    positions: []const Vec,
    orientations: []const Quat,
    offset: Vec,
    colours: Colours,
) void {
    for (0..model.geom_count) |geom| {
        const body: u32 = model.geom_body[geom];
        if (body == rbt.world_body) {
            continue;
        }
        const body_pose: rbt.Pose = .{ .pos = positions[body], .rot = orientations[body] };
        const offset_from_body: rbt.Pose = .{
            .pos = model.geom_local_position[geom],
            .rot = model.geom_local_rotation[geom],
        };
        const placed: rbt.Pose = body_pose.compose(offset_from_body);
        const at: Vec = toYUp(placed.pos + offset);
        const turn: Quat = qmul(to_y_up, placed.rot);
        switch (model.geom_shape[geom]) {
            .capsule => |capsule| {
                const half: Vec = rotate(turn, vec(0, capsule.half_height, 0));
                drawCapsule(s, gl, at - half, at + half, capsule.radius, colours.round);
            },
            .cylinder => |cylinder| {
                const half: Vec = rotate(turn, vec(0, cylinder.half_height, 0));
                drawCylinder(s, gl, at - half, at + half, cylinder.radius, colours.round);
            },
            .sphere => |sphere| drawBall(s, gl, at, sphere.radius, colours.round),
            .box => |box| {
                const size: Vec = splat(2.0) * box.half_extent;
                s.transform[0] = mulMat(
                    mulMat(translation(at[0], at[1], at[2]), quatToMat(turn)),
                    scaling(size[0], size[1], size[2]),
                );
                z.drawMeshInstanced(gl, &s.cube, &s.transform, colours.flat);
            },
            else => {},
        }
    }
}

/// The scene: the floor, the CPU's robot, and the GPU's once its poses have arrived - the camera following the CPU's
/// root, between the two.
fn drawScene(s: *State, f: *z.Frame, pointer_taken: bool) void {
    const settings: Settings = s.settings;
    const scene: *const Scene = &s.scene;
    const look: SceneLook = scene.kind.look(settings);
    const model: *const rbt.Model = &scene.imported.model;
    const cpu_data: *const rbt.Data = cpuDataOf(scene);
    const root: Vec = toYUp(cpu_data.body_positions[root_body]);
    s.cam.target = vec(root[0], look.camera_height, root[2]);
    const cam: Camera3D = s.cam.update(f, pointer_taken, .{ .min_distance = 0.8, .max_distance = 12.0 });
    const gl = f.gl;
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 40, 0.25);
    s.transform[0] = mulMat(translation(0, -0.1, 0), scaling(40, 0.2, 40));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, settings.ground);
    const cpu_offset: Vec = -look.drawn_apart;
    drawRobot(s, gl, model, cpu_data.body_positions, cpu_data.body_orientations, cpu_offset, settings.cpu_colours);
    if (scene.gpu_poses.arrived) {
        const poses: *const GpuPoses = &scene.gpu_poses;
        drawRobot(s, gl, model, poses.positions, poses.orientations, look.drawn_apart, settings.gpu_colours);
    }
    z.endMode3D(gl);
}

/// One line of the page's text at height `y`, in its font - `args` the format's arguments, as `std.fmt` takes them.
fn drawLine(
    f: *z.Frame,
    s: *State,
    y: f32,
    comptime format: []const u8,
    args: anytype,
    size: f32,
    colour: Color,
) void {
    f.gl.textf(.{ 16, y }, format, args, .{ .size = size, .color = colour, .font = &s.font });
}

/// The text: the scene's title, which side is which, where the run is, and how far apart the engines are - the GPU's
/// root against the CPU's at the same step - beside, for Geno, how far the CPU's hips are from the clip's: the servo's
/// own tracking error.
fn drawText(s: *State, f: *z.Frame) void {
    const settings: Settings = s.settings;
    const scene: *const Scene = &s.scene;
    const title_size: f32 = settings.title_size;
    const text_size: f32 = settings.text_size;
    drawLine(f, s, 16, "{s}", .{scene.kind.title()}, title_size, settings.title);
    drawLine(f, s, 44, "left: robot.zig on the CPU", .{}, text_size, settings.cpu_colours.round);
    drawLine(f, s, 68, "right: robotgpu on the GPU", .{}, text_size, settings.gpu_colours.round);
    drawLine(f, s, 96, "frame {d}, run {d}", .{ scene.frame, scene.runs }, text_size, settings.text);
    var y: f32 = 120;
    switch (scene.motion) {
        .geno_dance => |*geno_dance| {
            const cpu_tracking_mm: f32 = 1000.0 * hipsFromClip(geno_dance);
            drawLine(f, s, y, "CPU hips {d:.1} mm from the clip's", .{cpu_tracking_mm}, text_size, settings.text);
            y += 24;
        },
        .go1_stand => {},
    }
    if (scene.gpu == null) {
        drawLine(f, s, y, "GPU refused: {s}", .{scene.gpu_refusal}, text_size, settings.text);
        return;
    }
    if (!scene.gpu_poses.arrived) {
        return;
    }
    const gpu_root: Vec = scene.gpu_poses.positions[root_body];
    const engines_apart_mm: f32 = 1000.0 * length3(gpu_root - scene.gpu_poses.cpu_root_at_their_step);
    drawLine(f, s, y, "GPU root {d:.1} mm from the CPU's", .{engines_apart_mm}, text_size, settings.text);
}

/// The button's place: its size, its margin from the drawing area's lower left corner.
fn buttonRect(settings: Settings, f: *z.Frame) Rectangle {
    const button: Rectangle = .{
        .x = settings.button_margin,
        .y = f.window.heightf() - settings.button_margin - settings.button_height,
        .width = settings.button_width,
        .height = settings.button_height,
    };
    return button;
}

fn contains(rect: Rectangle, point: Vec2) bool {
    const inside_x: bool = point[0] >= rect.x and point[0] <= rect.x + rect.width;
    const inside_y: bool = point[1] >= rect.y and point[1] <= rect.y + rect.height;
    return inside_x and inside_y;
}

fn drawButton(s: *State, f: *z.Frame, button: Rectangle) void {
    const settings: Settings = s.settings;
    f.gl.rect(button, .{ .color = settings.button_fill });
    const label_y: f32 = button.y + 0.5 * (button.height - settings.text_size);
    f.gl.text(.{ button.x + 16, label_y }, "next scene", .{
        .size = settings.text_size,
        .color = settings.title,
        .font = &s.font,
    });
}

fn update(f: *z.Frame, s: *State) void {
    const button: Rectangle = buttonRect(s.settings, f);
    const pointer: Vec2 = z.getMousePosition(f.input);
    const on_button: bool = contains(button, pointer);
    if (on_button and z.isMouseButtonPressed(f.input, .left)) {
        nextScene(s, f) catch |err| std.log.err("robotgpu_sidebyside: next scene failed: {t}", .{err});
    }
    stepScene(s.gpa, s.settings, &s.scene) catch |err| std.log.err("robotgpu_sidebyside: step failed: {t}", .{err});
    z.clearViewport(f, s.settings.background);
    drawScene(s, f, on_button);
    drawText(s, f);
    drawButton(s, f, button);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - robotgpu, side by side",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
