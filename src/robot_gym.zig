//! robot_gym.zig - the classic humanoid locomotion task, as an environment for `zimrnum`'s RL.
//!
//! MuJoCo's humanoid (`humanoid.xml`, 21 hinges and a free torso) on a real floor through the
//! physics bridge, stepped headlessly. The shape is Gymnasium's Humanoid: reward forward speed,
//! pay for effort, end the episode at a fall. The ACTION is not a torque:
//!
//! *** THE POSE-OFFSET TRICK (DReCon, SuperTrack). The policy outputs one OFFSET per joint, added
//! to a base pose (standing, here) to make a target, and a stable low-level controller tracks that
//! target: `robot_dance.Tracker`'s implicit spring, turned into torques by floating-base inverse
//! dynamics. The policy therefore starts from "hold a pose" rather than "invent every torque",
//! which is the choice of action space Peng and van de Panne found matters most for learning
//! speed (Learning Locomotion Skills Using DeepRL: Does the Choice of Action Space Matter?, 2017).
//! With a reference motion the base pose becomes the reference's frame, and the policy's offsets
//! are exactly DReCon's corrections.
//!
//! -- TIMING --
//! Physics at 60 Hz (`robot.zig`'s refsafe keeps contacts stable there), the policy at 30 Hz:
//! each action is held for two physics steps.
//!
//! -- OBSERVATION (heading-invariant) --
//!   torso height (1), gravity in the torso's frame (3), torso linear velocity in its heading frame
//!   (3), torso angular velocity in its own frame (3), then per hinge: angle, speed, and the
//!   previous action (3 x 21).

const std = @import("std");
const report = @import("test_report.zig");
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const rbt = @import("robot.zig");
const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");
const robot_physics = @import("robot_physics.zig");
const zimrphysics = @import("zimrphysics.zig");
const rmx = @import("robot_maximal.zig");
const dance = @import("robot_dance.zig");

const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const rotate = zm.rotate;
const conjugate = zm.conjugate;
const float = zm.float;
const clamp = zm.clamp;
const atan2Rad = zm.atan2Rad;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const assertf = zm.assertf;
const tanh = zm.tanh;
const pi = zm.pi;
const length3 = zm.length3;
const float64 = zm.float64;

pub const Options = struct {
    /// Physics steps per policy step: 2 makes a 30 Hz policy over 60 Hz physics.
    substeps: u32 = 2,
    physics_hz: f32 = 60.0,
    /// The largest joint offset an action of 1 asks for, in radians.
    action_scale: f32 = 0.5,
    /// The low-level spring's natural frequency: `Tracker` reaches a target in ~1/f.
    spring_hz: f32 = 20.0,
    /// Gymnasium Humanoid's reward shape.
    forward_weight: f32 = 1.25,
    healthy_reward: f32 = 5.0,
    control_weight: f32 = 0.1,
    /// A fall: the torso's origin under this height, in metres (it stands at ~1.28).
    healthy_height: f32 = 0.9,
    /// Episode length in POLICY steps; 500 at 30 Hz is 16.7 s.
    max_steps: u32 = 500,
    /// Uniform noise on the joints' starting angles and speeds, as Gymnasium's reset noise.
    reset_noise: f32 = 0.01,
};

pub const StepResult = struct {
    reward: f32,
    /// The episode ended in a fall.
    terminated: bool,
    /// The episode ran out of time.
    truncated: bool,
};

pub const HumanoidEnv = struct {
    gpa: Allocator,
    options: Options,
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    data: rbt.Data,
    world: zimrphysics.World,
    bridge: robot_physics.Bridge,
    tracker: dance.Tracker,
    /// Joint coordinates of the base pose (standing, feet on the floor), and the current target.
    base: []f32,
    target: []f32,
    previous_action: []f32,
    /// qpos / dof addresses of the actuated hinges, in joint order.
    hinge_qpos: []u32,
    hinge_dof: []u32,
    a_des: []f32,
    torque: []f32,
    full: []f32,
    dense: []f32,
    rng: std.Random.DefaultPrng,
    steps: u32,

    /// Build the environment from MJCF text (a floating humanoid made of hinges). Call `reset`
    /// before the first `step`.
    pub fn init(
        gpa: Allocator,
        xml: []const u8,
        options: Options,
    ) !*HumanoidEnv {
        const env: *HumanoidEnv = try gpa.create(HumanoidEnv);
        errdefer gpa.destroy(env);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        env.* = .{
            .gpa = undefined,
            .options = undefined,
            .doc = undefined,
            .robot = undefined,
            .imported = undefined,
            .data = undefined,
            .world = undefined,
            .bridge = undefined,
            .tracker = undefined,
            .base = undefined,
            .target = undefined,
            .previous_action = undefined,
            .hinge_qpos = undefined,
            .hinge_dof = undefined,
            .a_des = undefined,
            .torque = undefined,
            .full = undefined,
            .dense = undefined,
            .rng = undefined,
            .steps = undefined,
        };
        env.gpa = gpa;
        env.options = options;
        env.doc = try codecs.xml.parse(gpa, xml, null);
        errdefer env.doc.deinit();
        env.robot = try mjcf.readRobot(gpa, &env.doc);
        errdefer env.robot.deinit();
        var model_options: rbt.Options = .{
            .max_contacts = 256,
            .timestep = 1.0 / options.physics_hz,
            .gravity = vec(0, 0, -9.81),
        };
        model_options.solver.algorithm = .newton;
        env.imported = try robot_mjcf.build(gpa, &env.robot, model_options);
        errdefer env.imported.deinit();
        const m: *rbt.Model = &env.imported.model;
        assertf(m.jnt_type[0] == .free and m.jnt_qpos_adr[0] == 0, @src(), "the root must be a free joint 0", .{});
        // Limp: no joint springs, damping or tendon springs - the controller is the only actuator.
        @memset(m.jnt_stiffness, 0.0);
        @memset(m.jnt_damping, 0.0);
        m.has_dof_damping = false;
        @memset(m.tendon_stiffness, 0.0);
        @memset(m.tendon_damping, 0.0);

        env.data = try rbt.Data.init(gpa, m);
        errdefer env.data.deinit();
        env.tracker = try .init(gpa, m.nv);
        errdefer env.tracker.deinit();

        var hinges: usize = 0;
        for (0..m.njnt) |j| {
            if (m.jnt_type[j] == .hinge) {
                hinges += 1;
            }
        }
        env.hinge_qpos = try gpa.alloc(u32, hinges);
        env.hinge_dof = try gpa.alloc(u32, hinges);
        var h: usize = 0;
        for (0..m.njnt) |j| {
            if (m.jnt_type[j] == .hinge) {
                env.hinge_qpos[h] = m.jnt_qpos_adr[j];
                env.hinge_dof[h] = m.jnt_dof_adr[j];
                h += 1;
            }
        }
        env.base = try gpa.dupe(f32, m.qpos0);
        env.target = try gpa.dupe(f32, m.qpos0);
        env.previous_action = try gpa.alloc(f32, hinges);
        env.a_des = try gpa.alloc(f32, m.nv);
        env.torque = try gpa.alloc(f32, m.nv);
        env.full = try gpa.alloc(f32, m.nv);
        env.dense = try gpa.alloc(f32, @as(usize, m.nv) * m.nv);
        // The base pose, its lowest foot point on the floor.
        @memcpy(env.data.pos, env.base);
        env.data.stage = .stale;
        rbt.forward(m, &env.data);
        env.base[2] -= dance.lowestFootPoint(m, &env.data, env.imported.names);

        env.world = try floorWorld(gpa);
        env.bridge = try .init(gpa, &env.world, m, &env.data, 256);
        env.bridge.listen(&env.world);
        env.rng = .init(0);
        env.steps = 0;
        return env;
    }

    pub fn deinit(env: *HumanoidEnv) void {
        const gpa: Allocator = env.gpa;
        env.bridge.deinit(&env.world);
        env.world.deinit(gpa);
        gpa.free(env.dense);
        gpa.free(env.full);
        gpa.free(env.torque);
        gpa.free(env.a_des);
        gpa.free(env.previous_action);
        gpa.free(env.target);
        gpa.free(env.base);
        gpa.free(env.hinge_dof);
        gpa.free(env.hinge_qpos);
        env.tracker.deinit();
        env.data.deinit();
        env.imported.deinit();
        env.robot.deinit();
        env.doc.deinit();
        gpa.destroy(env);
    }

    pub fn actionSize(env: *const HumanoidEnv) usize {
        return env.hinge_qpos.len;
    }

    pub fn observationSize(env: *const HumanoidEnv) usize {
        return 13 + 3 * env.hinge_qpos.len;
    }

    /// Start an episode: the base pose, feet on the floor, a little noise on the joints.
    ///
    /// ** A RESET MUST FORGET EVERYTHING, OR NO TWO LEARNING CURVES CAN BE COMPARED. The first
    /// version kept the physics world and the solver between episodes, and the same seed did not
    /// replay the same episode: contact caches and the solver's warm start carried the previous
    /// episode's forces into this one's first steps. The world and bridge are rebuilt and the
    /// robot's data reset - an episode is a function of its seed and its actions alone.
    pub fn reset(
        env: *HumanoidEnv,
        seed: u64,
        observation: []f32,
    ) !void {
        const m: *const rbt.Model = &env.imported.model;
        env.bridge.deinit(&env.world);
        env.world.deinit(env.gpa);
        env.data.reset(m);
        env.world = try floorWorld(env.gpa);
        env.bridge = try .init(env.gpa, &env.world, m, &env.data, 256);
        env.bridge.listen(&env.world);
        env.rng = .init(seed);
        const random: std.Random = env.rng.random();
        @memcpy(env.data.pos, env.base);
        @memset(env.data.vel, 0.0);
        for (env.hinge_qpos, env.hinge_dof) |q, v| {
            env.data.pos[q] += env.options.reset_noise * (2.0 * random.float(f32) - 1.0);
            env.data.vel[v] = env.options.reset_noise * (2.0 * random.float(f32) - 1.0);
        }
        env.data.stage = .stale;
        rbt.forward(m, &env.data);
        @memcpy(env.target, env.base);
        @memset(env.previous_action, 0.0);
        env.steps = 0;
        env.observe(observation);
    }

    /// One policy step: target = base + scale x clamp(action), held for `substeps` physics steps.
    pub fn step(
        env: *HumanoidEnv,
        action: []const f32,
        observation: []f32,
    ) !StepResult {
        const m: *rbt.Model = &env.imported.model;
        const d: *rbt.Data = &env.data;
        const o: Options = env.options;
        const dt: f32 = 1.0 / o.physics_hz;
        var effort: f32 = 0.0;
        for (action, env.hinge_qpos, 0..) |a, q, h| {
            const clipped: f32 = clamp(a, -1.0, 1.0);
            env.target[q] = env.base[q] + o.action_scale * clipped;
            env.previous_action[h] = clipped;
            effort += clipped * clipped;
        }
        const x_before: f32 = d.pos[0];
        for (0..o.substeps) |_| {
            rbt.forward(m, d);
            try env.bridge.sync(&env.world, m, d);
            try zimrphysics.step(&env.world, dt);
            env.bridge.harvest(d);
            // Hold the target: reference velocity and acceleration zero (all three frames equal).
            env.tracker.accelerations(m, d, .{ env.target, env.target, env.target }, o.spring_hz, dt, env.a_des);
            rbt.biasForce(m, d);
            rmx.floatingBaseTorques(m, d, env.a_des, env.dense, env.full, env.torque);
            @memset(d.applied_force, 0.0);
            for (env.hinge_dof) |v| {
                d.applied_force[v] = env.torque[v];
            }
            rbt.step(m, d);
        }
        rbt.forward(m, d);
        env.steps += 1;
        const elapsed: f32 = float(o.substeps) * dt;
        const forward_speed: f32 = (d.pos[0] - x_before) / elapsed;
        const height: f32 = d.pos[2];
        const terminated: bool = !zm.isFinite(height) or height < o.healthy_height;
        env.observe(observation);
        return .{
            .reward = o.forward_weight * forward_speed + o.healthy_reward - o.control_weight * effort,
            .terminated = terminated,
            .truncated = !terminated and env.steps >= o.max_steps,
        };
    }

    fn observe(env: *const HumanoidEnv, out: []f32) void {
        const d: *const rbt.Data = &env.data;
        assertf(out.len == env.observationSize(), @src(), "observation wants {d}, got {d}", .{
            env.observationSize(),
            out.len,
        });
        const torso: Quat = .{ d.pos[3], d.pos[4], d.pos[5], d.pos[6] };
        const gravity_local: Vec = rotate(conjugate(torso), vec(0, 0, -1));
        // The heading: the torso's forward axis, flattened onto the floor.
        const forward: Vec = rotate(torso, vec(1, 0, 0));
        const heading: Quat = quatFromAxisAngle(vec(0, 0, 1), atan2Rad(forward[1], forward[0]));
        const velocity_heading: Vec = rotate(conjugate(heading), vec(d.vel[0], d.vel[1], d.vel[2]));
        out[0] = d.pos[2];
        inline for (0..3) |k| {
            out[1 + k] = gravity_local[k];
            out[4 + k] = velocity_heading[k];
            out[7 + k] = d.vel[3 + k];
        }
        out[10] = 0;
        out[11] = 0;
        out[12] = 0;
        const n: usize = env.hinge_qpos.len;
        for (env.hinge_qpos, env.hinge_dof, 0..) |q, v, h| {
            out[13 + h] = d.pos[q];
            out[13 + n + h] = d.vel[v];
            out[13 + 2 * n + h] = env.previous_action[h];
        }
    }
};

/// A static floor whose top face is z = 0, and a world that never sleeps.
fn floorWorld(gpa: Allocator) !zimrphysics.World {
    var world: zimrphysics.World = try .init(gpa, 64);
    errdefer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    world.settings.allow_sleeping = false;
    world.settings.penetration_slop = 0.005;
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(200, 200, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
        .friction = 0.9,
    });
    return world;
}

// ============================================================================
// Tests: the environment before any learner - baselines, determinism, cost.
// ============================================================================

const expect = std.testing.expect;
const humanoid_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");

/// A fixed action rule for the baselines.
const Rule = enum { zero, random };

/// How one baseline episode went.
const EpisodeResult = struct {
    steps: u32,
    total: f32,
};

/// Run one episode with a fixed action rule.
fn episode(
    env: *HumanoidEnv,
    seed: u64,
    rule: Rule,
    obs: []f32,
    act: []f32,
) !EpisodeResult {
    try env.reset(seed, obs);
    var rng: std.Random.DefaultPrng = .init(seed +% 1);
    var total: f32 = 0.0;
    var steps: u32 = 0;
    while (true) {
        for (act) |*a| {
            a.* = switch (rule) {
                .zero => 0.0,
                .random => 2.0 * rng.random().float(f32) - 1.0,
            };
        }
        const result: StepResult = try env.step(act, obs);
        total += result.reward;
        steps += 1;
        if (result.terminated or result.truncated) {
            break;
        }
    }
    return .{ .steps = steps, .total = total };
}

test "robot_gym: the humanoid environment - baselines before any learner" {
    // ** WHAT A POLICY HAS TO BEAT, measured before one exists. ZERO actions hold the standing
    // pose - a statue, which falls (servo_ladder section 8.2: ~1.4 s); RANDOM actions flail. Both are the
    // floors a learning curve must rise from. Also: the sizes, and determinism under a seed -
    // two resets with the same seed must give the same episode to the bit, or no learning curve
    // can be compared with another.
    const gpa: Allocator = std.testing.allocator;
    const env: *HumanoidEnv = try .init(gpa, humanoid_xml, .{});
    defer env.deinit();
    const obs: []f32 = try gpa.alloc(f32, env.observationSize());
    defer gpa.free(obs);
    const act: []f32 = try gpa.alloc(f32, env.actionSize());
    defer gpa.free(act);
    try expect(env.actionSize() == 21);

    var total_steps: u32 = 0;
    for ([_]Rule{ .zero, .random }) |rule| {
        var lengths: u32 = 0;
        var returns: f32 = 0.0;
        for (0..5) |e| {
            const result: EpisodeResult = try episode(env, 100 + e, rule, obs, act);
            lengths += result.steps;
            returns += result.total;
        }
        total_steps += lengths;
        report.print("\n  HumanoidEnv, {s} actions, 5 episodes: mean length {d:.1} steps ({d:.2} s), " ++
            "mean return {d:.1}\n", .{
            @tagName(rule), float(lengths) / 5.0, float(lengths) / 5.0 / 30.0, returns / 5.0,
        });
    }
    // Determinism: the same seed, the same episode.
    const first: EpisodeResult = try episode(env, 7, .random, obs, act);
    const second: EpisodeResult = try episode(env, 7, .random, obs, act);
    try expect(first.steps == second.steps and first.total == second.total);
    report.print("  sizes: observation {d}, action {d}; {d} policy steps run; the same seed repeats to the bit\n", .{
        env.observationSize(), env.actionSize(), total_steps + first.steps + second.steps,
    });
}

// ============================================================================
// P1 (rl_track_journal.md): PPO on HumanoidEnv, with zimrnum's own learner.
// ============================================================================

const zn = @import("zn");

/// A dense layer's weights and biases, as graph parameters and as the tensors that hold them.
pub const Layer = struct {
    w: zn.Tensor(f32),
    b: zn.Tensor(f32),
    w_var: zn.Var = undefined,
    b_var: zn.Var = undefined,

    pub fn init(
        arena: Allocator,
        random: std.Random,
        in: usize,
        out: usize,
        gain: f32,
    ) !Layer {
        const w: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ in, out });
        const b: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ 1, out });
        const limit: f32 = gain * @sqrt(6.0 / float(in + out));
        for (w.data) |*x| {
            x.* = limit * (2.0 * random.float(f32) - 1.0);
        }
        @memset(b.data, 0.0);
        return .{ .w = w, .b = b };
    }

    /// x W + 1 b on the graph (the bias through a ones column: `add` needs equal shapes).
    pub fn apply(
        self: *Layer,
        graph: *zn.Graph(f32),
        x: zn.Var,
        ones: zn.Var,
    ) !zn.Var {
        self.w_var = try graph.parameter(self.w);
        self.b_var = try graph.parameter(self.b);
        return graph.add(try graph.matmul(x, self.w_var), try graph.matmul(ones, self.b_var));
    }

    /// The same, for ONE row, in plain loops - collection must not build a graph per step.
    pub fn forward(
        self: *const Layer,
        x: []const f32,
        out: []f32,
        squash: bool,
    ) void {
        const n_out: usize = self.w.shape[1];
        for (0..n_out) |j| {
            var sum: f32 = self.b.data[j];
            for (x, 0..) |xi, i| {
                sum += xi * self.w.data[i * n_out + j];
            }
            out[j] = if (squash) tanh(sum) else sum;
        }
    }
};

/// Running mean and variance of observations (Welford), for normalising them.
const Normalizer = struct {
    count: f64 = 1.0e-4,
    mean: []f64,
    m2: []f64,

    fn update(self: *Normalizer, x: []const f32) void {
        self.count += 1.0;
        for (x, 0..) |xi, i| {
            const delta: f64 = @as(f64, xi) - self.mean[i];
            self.mean[i] += delta / self.count;
            self.m2[i] += delta * (@as(f64, xi) - self.mean[i]);
        }
    }

    fn apply(
        self: *const Normalizer,
        x: []const f32,
        out: []f32,
    ) void {
        for (x, 0..) |xi, i| {
            const variance: f64 = self.m2[i] / self.count;
            const z: f64 = (@as(f64, xi) - self.mean[i]) / @sqrt(variance + 1.0e-8);
            out[i] = @floatCast(clamp(z, -10.0, 10.0));
        }
    }
};

pub const TrainerOptions = struct {
    hidden: usize = 64,
    /// Environment steps per PPO iteration.
    horizon: usize = 2048,
    minibatch: usize = 256,
    epochs: usize = 5,
    /// ** ADAM's rate. `ppoUpdate` steps plain SGD; the trainer runs the minibatch itself and
    /// steps Adam (`updateSlice`), because no single SGD rate suits every parameter of the
    /// policy: a small one does not move it, and a large one drives its mean into the action clamp
    /// within a few iterations - a star pose, every joint at its offset limit.
    learning_rate: f64 = 3.0e-4,
    /// Rewards are scaled by this before they reach the rollout, so value targets stay near
    /// unit size: 5 per step alive makes returns of ~130, and plain SGD on a squared error that
    /// large diverges. The printed returns are unscaled.
    reward_scale: f32 = 0.05,
    /// * Start NEAR THE STATUE: sigma = e^-1.5 = 0.22, times the 0.5 rad action scale. A wider
    /// start flails every joint by tenths of a radian, falls sooner than holding the reference pose
    /// would, and PPO does not climb back from there.
    initial_log_std: f32 = -1.5,
    seed: u64 = 20260919,
};

/// One finished PPO iteration.
pub const TrainerStats = struct {
    iteration: usize = 0,
    samples: usize = 0,
    episodes: u32 = 0,
    mean_length: f32 = 0,
    mean_return: f32 = 0,
};

/// PPO on a `HumanoidEnv`, in slices a frame can afford: `collect` runs environment steps into
/// the rollout, `updateEpoch` runs ONE epoch of the update (call it until it returns true).
/// zimrnum's `ppoUpdate`, `gae` and `RolloutBuffer` underneath; a 64-64 tanh Gaussian policy and
/// value net built on its graph; observations normalised by running statistics.
pub const PpoTrainer = struct {
    arena_state: std.heap.ArenaAllocator,
    gpa: Allocator,
    env: *HumanoidEnv,
    options: TrainerOptions,
    p1: Layer,
    p2: Layer,
    p3: Layer,
    v1: Layer,
    v2: Layer,
    v3: Layer,
    log_std: zn.Tensor(f32),
    graph: zn.Graph(f32),
    model: zn.PpoModel(f32),
    norm: Normalizer,
    raw: []f32,
    normed: []f32,
    a1: []f32,
    a2: []f32,
    mu: []f32,
    act: []f32,
    val: []f32,
    observations: zn.Tensor(f32),
    actions: zn.Tensor(f32),
    advantages: []f64,
    returns: []f64,
    rollout: zn.RolloutBuffer,
    rng: std.Random.DefaultPrng,
    episode_seed: u64,
    episode_length: u32 = 0,
    episode_return: f32 = 0,
    finished: u32 = 0,
    finished_length: u64 = 0,
    finished_return: f64 = 0,
    /// 0 while collecting; the number of update epochs done while updating.
    epoch: usize = 0,
    /// The next minibatch of the current epoch (`updateSlice`).
    minibatch_index: usize = 0,
    /// Adam's first and second moments, one pair per weight tensor, and its step count.
    moments: []zn.Tensor(f32),
    velocities: []zn.Tensor(f32),
    adam_step: usize = 0,
    iteration: usize = 0,
    last: TrainerStats = .{},

    pub fn init(
        gpa: Allocator,
        env: *HumanoidEnv,
        options: TrainerOptions,
    ) !*PpoTrainer {
        const t: *PpoTrainer = try gpa.create(PpoTrainer);
        errdefer gpa.destroy(t);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        t.* = .{
            .arena_state = undefined,
            .gpa = undefined,
            .env = undefined,
            .options = undefined,
            .p1 = undefined,
            .p2 = undefined,
            .p3 = undefined,
            .v1 = undefined,
            .v2 = undefined,
            .v3 = undefined,
            .log_std = undefined,
            .graph = undefined,
            .model = undefined,
            .norm = undefined,
            .raw = undefined,
            .normed = undefined,
            .a1 = undefined,
            .a2 = undefined,
            .mu = undefined,
            .act = undefined,
            .val = undefined,
            .observations = undefined,
            .actions = undefined,
            .advantages = undefined,
            .returns = undefined,
            .rollout = undefined,
            .rng = undefined,
            .episode_seed = undefined,
            .moments = undefined,
            .velocities = undefined,
        };
        t.arena_state = .init(gpa);
        errdefer t.arena_state.deinit();
        const arena: Allocator = t.arena_state.allocator();
        t.gpa = gpa;
        t.env = env;
        t.options = options;
        t.episode_length = 0;
        t.episode_return = 0;
        t.finished = 0;
        t.finished_length = 0;
        t.finished_return = 0;
        t.epoch = 0;
        t.minibatch_index = 0;
        t.iteration = 0;
        t.last = .{};
        assertf(options.horizon % options.minibatch == 0, @src(), "the horizon must be whole minibatches", .{});
        const n_obs: usize = env.observationSize();
        const n_act: usize = env.actionSize();
        const hidden: usize = options.hidden;
        const batch: usize = options.minibatch;
        t.rng = .init(options.seed);
        const random: std.Random = t.rng.random();
        t.p1 = try .init(arena, random, n_obs, hidden, 1.0);
        t.p2 = try .init(arena, random, hidden, hidden, 1.0);
        t.p3 = try .init(arena, random, hidden, n_act, 0.01);
        t.v1 = try .init(arena, random, n_obs, hidden, 1.0);
        t.v2 = try .init(arena, random, hidden, hidden, 1.0);
        t.v3 = try .init(arena, random, hidden, 1, 1.0);
        t.log_std = try zn.Tensor(f32).alloc(arena, &.{ 1, n_act });
        @memset(t.log_std.data, options.initial_log_std);

        // -- The update's graph, built once at minibatch size. --
        t.graph = .init(arena);
        // The graph lives as long as the trainer and runs thousands of passes: its backward
        // temporaries need an allocator that can free (zimrnum's `Graph.scratch`).
        t.graph.useScratchAllocator(gpa);
        const g: *zn.Graph(f32) = &t.graph;
        const obs_leaf: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ batch, n_obs });
        const act_leaf: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ batch, n_act });
        const adv_leaf: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ batch, 1 });
        const old_leaf: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ batch, 1 });
        const ret_leaf: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ batch, 1 });
        const ones_t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ batch, 1 });
        for ([_]zn.Tensor(f32){ obs_leaf, act_leaf, adv_leaf, old_leaf, ret_leaf }) |leaf| {
            @memset(leaf.data, 0.0);
        }
        @memset(ones_t.data, 1.0);
        const obs_var: zn.Var = try g.constant(obs_leaf);
        const act_var: zn.Var = try g.constant(act_leaf);
        const adv_var: zn.Var = try g.constant(adv_leaf);
        const old_var: zn.Var = try g.constant(old_leaf);
        const ret_var: zn.Var = try g.constant(ret_leaf);
        const ones: zn.Var = try g.constant(ones_t);
        const h1: zn.Var = try g.tanh(try t.p1.apply(g, obs_var, ones));
        const h2: zn.Var = try g.tanh(try t.p2.apply(g, h1, ones));
        const mean: zn.Var = try t.p3.apply(g, h2, ones);
        const log_std_var: zn.Var = try g.parameter(t.log_std);
        const log_prob_new: zn.Var = try g.diagGaussianLogProb(mean, log_std_var, act_leaf);
        const clip_loss: zn.Var = try g.ppoClipLoss(log_prob_new, old_leaf.data, adv_leaf.data, 0.2);
        const k1: zn.Var = try g.tanh(try t.v1.apply(g, obs_var, ones));
        const k2: zn.Var = try g.tanh(try t.v2.apply(g, k1, ones));
        const value: zn.Var = try t.v3.apply(g, k2, ones);
        const value_loss: zn.Var = try g.mseLoss(value, ret_var);
        const loss: zn.Var = try g.add(clip_loss, try g.scale(value_loss, 0.5));
        const weights: []zn.Tensor(f32) = try arena.dupe(zn.Tensor(f32), &.{
            t.p1.w, t.p1.b, t.p2.w, t.p2.b, t.p3.w, t.p3.b, t.log_std,
            t.v1.w, t.v1.b, t.v2.w, t.v2.b, t.v3.w, t.v3.b,
        });
        const parameters: []zn.Var = try arena.dupe(zn.Var, &.{
            t.p1.w_var, t.p1.b_var, t.p2.w_var, t.p2.b_var, t.p3.w_var, t.p3.b_var, log_std_var,
            t.v1.w_var, t.v1.b_var, t.v2.w_var, t.v2.b_var, t.v3.w_var, t.v3.b_var,
        });
        t.moments = try arena.alloc(zn.Tensor(f32), weights.len);
        t.velocities = try arena.alloc(zn.Tensor(f32), weights.len);
        for (weights, t.moments, t.velocities) |w, *mo, *ve| {
            mo.* = try zn.Tensor(f32).alloc(arena, w.shape[0..w.rank]);
            ve.* = try zn.Tensor(f32).alloc(arena, w.shape[0..w.rank]);
            @memset(mo.data, 0.0);
            @memset(ve.data, 0.0);
        }
        t.adam_step = 0;
        t.model = .{
            .graph = g,
            .observations = obs_var,
            .actions = act_var,
            .advantages = adv_var,
            .log_prob_old = old_var,
            .returns = ret_var,
            .loss = loss,
            .clip_loss = clip_loss,
            .log_prob_new = log_prob_new,
            .weights = weights,
            .parameters = parameters,
        };

        // -- Collection buffers. --
        t.norm = .{ .mean = try arena.alloc(f64, n_obs), .m2 = try arena.alloc(f64, n_obs) };
        @memset(t.norm.mean, 0.0);
        @memset(t.norm.m2, 0.0);
        t.raw = try arena.alloc(f32, n_obs);
        t.normed = try arena.alloc(f32, n_obs);
        t.a1 = try arena.alloc(f32, hidden);
        t.a2 = try arena.alloc(f32, hidden);
        t.mu = try arena.alloc(f32, n_act);
        t.act = try arena.alloc(f32, n_act);
        t.val = try arena.alloc(f32, 1);
        t.observations = try zn.Tensor(f32).alloc(arena, &.{ options.horizon, n_obs });
        t.actions = try zn.Tensor(f32).alloc(arena, &.{ options.horizon, n_act });
        t.advantages = try arena.alloc(f64, options.horizon);
        t.returns = try arena.alloc(f64, options.horizon);
        t.rollout = try zn.RolloutBuffer.init(arena, options.horizon);
        t.episode_seed = options.seed;
        try env.reset(t.episode_seed, t.raw);
        return t;
    }

    pub fn deinit(t: *PpoTrainer) void {
        t.graph.deinitScratch();
        t.arena_state.deinit();
        t.gpa.destroy(t);
    }

    pub fn rolloutFull(t: *const PpoTrainer) bool {
        return t.rollout.len == t.options.horizon;
    }

    fn valueOf(t: *PpoTrainer, x: []const f32) f32 {
        t.v1.forward(x, t.a1, true);
        t.v2.forward(t.a1, t.a2, true);
        t.v3.forward(t.a2, t.val, false);
        return t.val[0];
    }

    /// Run up to `max_steps` environment steps into the rollout; stops when it is full.
    pub fn collect(t: *PpoTrainer, max_steps: usize) !usize {
        const n_obs: usize = t.raw.len;
        const n_act: usize = t.act.len;
        var ran: usize = 0;
        while (ran < max_steps and !t.rolloutFull()) : (ran += 1) {
            const row: usize = t.rollout.len;
            t.norm.update(t.raw);
            t.norm.apply(t.raw, t.normed);
            @memcpy(t.observations.data[row * n_obs ..][0..n_obs], t.normed);
            t.p1.forward(t.normed, t.a1, true);
            t.p2.forward(t.a1, t.a2, true);
            t.p3.forward(t.a2, t.mu, false);
            var log_prob: f64 = 0.0;
            for (0..n_act) |k| {
                const noise: f32 = t.rng.random().floatNorm(f32);
                t.act[k] = t.mu[k] + @exp(t.log_std.data[k]) * noise;
                log_prob += -0.5 * @as(f64, noise * noise) - @as(f64, t.log_std.data[k]) - 0.5 * @log(2.0 * pi);
            }
            @memcpy(t.actions.data[row * n_act ..][0..n_act], t.act);
            const v_now: f32 = t.valueOf(t.normed);
            const result: StepResult = try t.env.step(t.act, t.raw);
            t.episode_length += 1;
            t.episode_return += result.reward;
            var v_next: f32 = 0.0;
            if (!result.terminated) {
                t.norm.apply(t.raw, t.normed);
                v_next = t.valueOf(t.normed);
            }
            const scaled: f32 = t.options.reward_scale * result.reward;
            try t.rollout.record(scaled, v_now, v_next, result.terminated, result.truncated, log_prob);
            if (result.terminated or result.truncated) {
                t.finished += 1;
                t.finished_length += t.episode_length;
                t.finished_return += t.episode_return;
                t.episode_length = 0;
                t.episode_return = 0.0;
                t.episode_seed += 1;
                try t.env.reset(t.episode_seed, t.raw);
            }
        }
        return ran;
    }

    /// The current policy's MEAN action for a raw observation - no exploration noise: what the
    /// policy has learned, for watching. Uses the trainer's normaliser without updating it.
    pub fn policyMean(
        t: *PpoTrainer,
        observation: []const f32,
        action: []f32,
    ) void {
        t.norm.apply(observation, t.normed);
        t.p1.forward(t.normed, t.a1, true);
        t.p2.forward(t.a1, t.a2, true);
        t.p3.forward(t.a2, action, false);
    }

    /// Shuffle the rollout's rows - observations, actions, advantages, returns and the steps
    /// with their log-probs, together - so consecutive chunks are random minibatches.
    fn shuffleRollout(t: *PpoTrainer) void {
        const n_obs: usize = t.raw.len;
        const n_act: usize = t.act.len;
        const random: std.Random = t.rng.random();
        var i: usize = t.rollout.len;
        while (i > 1) {
            i -= 1;
            const j: usize = random.uintLessThan(usize, i + 1);
            if (i == j) {
                continue;
            }
            for (0..n_obs) |k| {
                std.mem.swap(f32, &t.observations.data[i * n_obs + k], &t.observations.data[j * n_obs + k]);
            }
            for (0..n_act) |k| {
                std.mem.swap(f32, &t.actions.data[i * n_act + k], &t.actions.data[j * n_act + k]);
            }
            std.mem.swap(f64, &t.advantages[i], &t.advantages[j]);
            std.mem.swap(f64, &t.returns[i], &t.returns[j]);
            std.mem.swap(zn.RolloutStep, &t.rollout.steps[i], &t.rollout.steps[j]);
            std.mem.swap(f64, &t.rollout.log_prob[i], &t.rollout.log_prob[j]);
        }
    }

    /// ONE MINIBATCH of the PPO update - the unit a 30 fps frame can afford (a whole epoch is
    /// many frames' worth on a phone). Advantages are computed and normalised over the whole rollout
    /// once, the rows shuffled at the start of every epoch, and `ppoUpdate` handed one
    /// minibatch-sized chunk. Returns true when the whole update is done: the rollout is then
    /// empty for the next iteration and `last` holds its numbers.
    pub fn updateSlice(t: *PpoTrainer) !bool {
        assertf(t.rolloutFull(), @src(), "updateSlice before the rollout is full", .{});
        if (t.epoch == 0 and t.minibatch_index == 0) {
            try zn.gae(t.rollout.steps[0..t.rollout.len], 0.99, 0.95, t.advantages, t.returns);
            try zn.normalizeAdvantages(f64, t.advantages, 1.0e-8);
        }
        if (t.minibatch_index == 0) {
            t.shuffleRollout();
        }
        const size: usize = t.options.minibatch;
        const at: usize = t.minibatch_index * size;
        // ** The minibatch by hand, so it can step ADAM (`ppoUpdate` steps plain SGD): the
        // chunk's rows into the graph's leaves (contiguous after the shuffle), the clip node's
        // copies refreshed, the loss and gradients recomputed, then one Adam step per tensor.
        const n_obs: usize = t.raw.len;
        const n_act: usize = t.act.len;
        const g: *zn.Graph(f32) = &t.graph;
        @memcpy(g.valueOf(t.model.observations).data, t.observations.data[at * n_obs ..][0 .. size * n_obs]);
        @memcpy(g.valueOf(t.model.actions).data, t.actions.data[at * n_act ..][0 .. size * n_act]);
        const adv_leaf: []f32 = g.valueOf(t.model.advantages).data;
        const old_leaf: []f32 = g.valueOf(t.model.log_prob_old).data;
        const ret_leaf: []f32 = g.valueOf(t.model.returns).data;
        for (0..size) |i| {
            adv_leaf[i] = @floatCast(t.advantages[at + i]);
            old_leaf[i] = @floatCast(t.rollout.log_prob[at + i]);
            ret_leaf[i] = @floatCast(t.returns[at + i]);
        }
        try g.setPpoClipInputs(t.model.clip_loss, old_leaf, adv_leaf);
        try g.recompute();
        try g.backward(t.model.loss);
        t.adam_step += 1;
        const hyper: zn.Adam = .{ .rate = t.options.learning_rate };
        for (t.model.weights, t.model.parameters, t.moments, t.velocities) |w, v, mo, ve| {
            try zn.adamStep(f32, w, w, try g.gradOf(v), mo, ve, hyper, t.adam_step);
        }
        t.minibatch_index += 1;
        if (t.minibatch_index * size < t.options.horizon) {
            return false;
        }
        t.minibatch_index = 0;
        t.epoch += 1;
        if (t.epoch < t.options.epochs) {
            return false;
        }
        t.epoch = 0;
        t.iteration += 1;
        const episodes: f32 = float(t.finished);
        const mean_length: f32 = if (t.finished > 0) float(t.finished_length) / episodes else float(t.options.horizon);
        t.last = .{
            .iteration = t.iteration,
            .samples = t.iteration * t.options.horizon,
            .episodes = t.finished,
            .mean_length = mean_length,
            .mean_return = if (t.finished > 0) @floatCast(t.finished_return / float(t.finished)) else 0.0,
        };
        t.finished = 0;
        t.finished_length = 0;
        t.finished_return = 0.0;
        t.rollout.len = 0;
        return true;
    }

    /// One whole epoch of the update (`updateSlice` until the epoch turns). Returns true when
    /// the whole update is done.
    pub fn updateEpoch(t: *PpoTrainer) !bool {
        while (true) {
            if (try t.updateSlice()) {
                return true;
            }
            if (t.minibatch_index == 0) {
                return false;
            }
        }
    }
};

test "robot_gym: P1 - PPO learns to stay up and move on HumanoidEnv" {
    // *** P1 OF rl_track_journal.md: does zimrnum's PPO learn on OUR physics? The number: mean
    // episode length per iteration, against the statue's 37.6 steps (zero actions) and random's
    // 15. `PpoTrainer` with its defaults: the policy starts near the statue.
    const gpa: Allocator = std.testing.allocator;
    const env: *HumanoidEnv = try .init(gpa, humanoid_xml, .{});
    defer env.deinit();
    const trainer: *PpoTrainer = try .init(gpa, env, .{});
    defer trainer.deinit();
    report.print("\n  P1 PPO on HumanoidEnv (statue 37.6 steps, random 15), starting near the statue:\n", .{});
    var capacity_after_warmup: usize = 0;
    for (0..12) |iteration| {
        while (!trainer.rolloutFull()) {
            _ = try trainer.collect(4096);
        }
        while (!try trainer.updateEpoch()) {}
        // ** Memory must stop growing once warm: the graph's backward temporaries leaked ~60 MiB
        // an iteration in the browser before they moved to a per-pass scratch arena.
        if (iteration == 3) {
            capacity_after_warmup = trainer.arena_state.queryCapacity();
        }
        if (iteration == 11) {
            // The leak class this guards against was ~60 MiB an iteration (graph backward's
            // temporaries, now in `Graph.scratch`). A residual of ~0.75 MiB an iteration is
            // still open (rl_track_journal.md); the bound catches the big class returning.
            const grown: usize = trainer.arena_state.queryCapacity() - capacity_after_warmup;
            report.print("    trainer memory grew {d} KiB over iterations 5-12\n", .{grown / 1024});
            try expect(grown < 8 * 1024 * 1024);
        }
        const st: TrainerStats = trainer.last;
        report.print("    iteration {d:>2} ({d:>6} samples): {d:>3} episodes, mean length {d:>6.1}, " ++
            "mean return {d:>7.1}\n", .{ st.iteration, st.samples, st.episodes, st.mean_length, st.mean_return });
    }
    try expect(zm.isFinite(trainer.last.mean_length));
}

test "robot_gym: FOOT SLIP - how far a statue's feet slide while it still stands, by physics rate" {
    // ** ON A PHONE THE FEET LOOKED "VERY SLIDY, ALWAYS SLIPPING BACKWARD". A pose held still
    // should not move its feet at all while it stays up, so any foot travel in the first half
    // second of the statue (zero actions) is slip. Measured at 60, 120 and 240 Hz physics under the
    // same 30 Hz policy: robot.zig's contacts are soft, and refsafe (section 8.9 of servo_ladder) clamps
    // their time constant to two timesteps - 33 ms at 60 Hz - so a friction constraint may CREEP.
    const gpa: Allocator = std.testing.allocator;
    const Rate = struct { hz: f32, substeps: u32 };
    const rates = [_]Rate{ .{ .hz = 60, .substeps = 2 }, .{ .hz = 120, .substeps = 4 }, .{ .hz = 240, .substeps = 8 } };
    report.print("\n  foot slip, the statue (zero actions), first 0.5 s:\n", .{});
    for (rates) |rate| {
        const env: *HumanoidEnv = try .init(gpa, humanoid_xml, .{ .physics_hz = rate.hz, .substeps = rate.substeps });
        defer env.deinit();
        const obs: []f32 = try gpa.alloc(f32, env.observationSize());
        defer gpa.free(obs);
        const act: []f32 = try gpa.alloc(f32, env.actionSize());
        defer gpa.free(act);
        @memset(act, 0.0);
        try env.reset(3, obs);
        const m: *const rbt.Model = &env.imported.model;
        var feet: [4]u32 = undefined;
        var foot_count: usize = 0;
        for (1..m.nbody) |b| {
            if (std.mem.indexOf(u8, env.imported.names[b], "foot") != null and foot_count < feet.len) {
                feet[foot_count] = @intCast(b);
                foot_count += 1;
            }
        }
        var start: [4]Vec = undefined;
        for (feet[0..foot_count], 0..) |b, i| {
            start[i] = env.data.body_xpos[b];
        }
        var worst_slide: f32 = 0.0;
        var steps: u32 = 0;
        var fell_at: u32 = 0;
        for (0..150) |_| {
            const result: StepResult = try env.step(act, obs);
            steps += 1;
            if (steps <= 15) {
                for (feet[0..foot_count], 0..) |b, i| {
                    const now: Vec = env.data.body_xpos[b];
                    const slide: f32 = length3(vec(now[0] - start[i][0], now[1] - start[i][1], 0));
                    worst_slide = @max(worst_slide, slide);
                }
            }
            if (result.terminated or result.truncated) {
                fell_at = steps;
                break;
            }
        }
        report.print("    {d:>3.0} Hz physics ({d} substeps): feet slid up to " ++
            "{d:>6.1} mm in 0.5 s; the statue fell at step {d}\n", .{
            rate.hz, rate.substeps, worst_slide * 1000.0, fell_at,
        });
    }
}

const build_options = @import("build_options");

test "robot_gym: P1 LONG - does PPO learn to stand past the statue, given 300k samples?" {
    // ** THE PHONE RAN ~30k SAMPLES, FLAT AT ~30 STEPS; humanoid PPO usually needs hundreds of
    // thousands. This runs 150 iterations (307k samples) natively and prints the curve every ten.
    // Gated on `-Dslow-tests` (several minutes): zig build zn-robot_gym -Dslow-tests
    // -Dtest-filter="P1 LONG".
    const slow: bool = comptime @hasDecl(build_options, "slow_tests") and build_options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    const env: *HumanoidEnv = try .init(gpa, humanoid_xml, .{});
    defer env.deinit();
    const trainer: *PpoTrainer = try .init(gpa, env, .{});
    defer trainer.deinit();
    report.print("\n  P1 LONG (statue 37.6 steps):\n", .{});
    var best: f32 = 0.0;
    for (0..150) |_| {
        while (!trainer.rolloutFull()) {
            _ = try trainer.collect(4096);
        }
        while (!try trainer.updateEpoch()) {}
        const st: TrainerStats = trainer.last;
        best = @max(best, st.mean_length);
        if (st.iteration % 10 == 0) {
            report.print("    iteration {d:>3} ({d:>7} samples): mean length " ++
                "{d:>6.1}, return {d:>7.1}, best so far {d:.1}\n", .{
                st.iteration, st.samples, st.mean_length, st.mean_return, best,
            });
        }
    }
}

// ============================================================================
// S1 (rl_track_journal.md section 7): SAC, assembled from zimrnum's parts, stepping Adam.
// ============================================================================

pub const SacOptions = struct {
    hidden: usize = 64,
    batch: usize = 128,
    replay_capacity: usize = 100_000,
    /// Adam, for actor, critics and temperature alike.
    learning_rate: f64 = 3.0e-4,
    gamma: f32 = 0.99,
    /// Polyak rate for the target critics.
    tau: f32 = 0.005,
    /// Uniformly random actions before learning starts.
    warmup: usize = 1000,
    seed: u64 = 1,
};

/// The bounds a log-std is squashed into (tanh, then affine): SAC's usual [-5, 2].
const log_std_min: f32 = -5.0;
const log_std_max: f32 = 2.0;

/// An MLP of three dense layers (tanh, tanh, linear) and the Adam state of its tensors.
const Mlp3 = struct {
    l1: Layer,
    l2: Layer,
    l3: Layer,

    fn init(
        arena: Allocator,
        random: std.Random,
        in: usize,
        hidden: usize,
        out: usize,
        last_gain: f32,
    ) !Mlp3 {
        return .{
            .l1 = try .init(arena, random, in, hidden, 1.0),
            .l2 = try .init(arena, random, hidden, hidden, 1.0),
            .l3 = try .init(arena, random, hidden, out, last_gain),
        };
    }

    fn apply(
        self: *Mlp3,
        g: *zn.Graph(f32),
        x: zn.Var,
        ones: zn.Var,
    ) !zn.Var {
        const h1: zn.Var = try g.tanh(try self.l1.apply(g, x, ones));
        const h2: zn.Var = try g.tanh(try self.l2.apply(g, h1, ones));
        return self.l3.apply(g, h2, ones);
    }

    fn forward(
        self: *const Mlp3,
        x: []const f32,
        t1: []f32,
        t2: []f32,
        out: []f32,
    ) void {
        self.l1.forward(x, t1, true);
        self.l2.forward(t1, t2, true);
        self.l3.forward(t2, out, false);
    }

    fn tensors(self: *const Mlp3) [6]zn.Tensor(f32) {
        return .{ self.l1.w, self.l1.b, self.l2.w, self.l2.b, self.l3.w, self.l3.b };
    }

    fn vars(self: *const Mlp3) [6]zn.Var {
        return .{ self.l1.w_var, self.l1.b_var, self.l2.w_var, self.l2.b_var, self.l3.w_var, self.l3.b_var };
    }
};

/// Adam over a list of tensors: a moment and a velocity each, and a step count.
pub const AdamSet = struct {
    moments: []zn.Tensor(f32),
    velocities: []zn.Tensor(f32),
    step: usize = 0,

    pub fn init(arena: Allocator, weights: []const zn.Tensor(f32)) !AdamSet {
        const moments: []zn.Tensor(f32) = try arena.alloc(zn.Tensor(f32), weights.len);
        const velocities: []zn.Tensor(f32) = try arena.alloc(zn.Tensor(f32), weights.len);
        for (weights, moments, velocities) |w, *mo, *ve| {
            mo.* = try zn.Tensor(f32).alloc(arena, w.shape[0..w.rank]);
            ve.* = try zn.Tensor(f32).alloc(arena, w.shape[0..w.rank]);
            @memset(mo.data, 0.0);
            @memset(ve.data, 0.0);
        }
        return .{ .moments = moments, .velocities = velocities };
    }

    pub fn apply(
        self: *AdamSet,
        g: *zn.Graph(f32),
        weights: []const zn.Tensor(f32),
        vars: []const zn.Var,
        rate: f64,
    ) !void {
        self.step += 1;
        const hyper: zn.Adam = .{ .rate = rate };
        for (weights, vars, self.moments, self.velocities) |w, v, mo, ve| {
            try zn.adamStep(f32, w, w, try g.gradOf(v), mo, ve, hyper, self.step);
        }
    }
};

/// Soft Actor-Critic (Haarnoja et al. 2018), assembled from zimrnum's parts: a tanh-squashed
/// Gaussian actor (`squashedReparameterize`), twin critics on `concat(s, a)` with polyak targets,
/// the target y = r + gamma (1 - done)(min Q' - alpha log pi), and a tuned temperature
/// (`zn.Temperature`). Every network steps ADAM: zimrnum's `offPolicyUpdate` steps plain SGD,
/// the trap `ppoUpdate` already sprang (rl_track_journal.md section 6). Env-agnostic: flat observations
/// and actions in [-1, 1].
pub const SacAgent = struct {
    arena_state: std.heap.ArenaAllocator,
    gpa: Allocator,
    options: SacOptions,
    n_obs: usize,
    n_act: usize,
    actor: Mlp3,
    /// The log-std, one learned row [1, n_act] before its tanh bound: zimrnum's
    /// `squashedReparameterize` takes a state-INDEPENDENT log-std (shape [1, dims]) - a common,
    /// workable SAC variant; a per-row log-std is a small library extension for later.
    raw_log_std: zn.Tensor(f32),
    raw_log_std_var: zn.Var = undefined,
    q1: Mlp3,
    q2: Mlp3,
    target1: Mlp3,
    target2: Mlp3,
    critic_graph: zn.Graph(f32),
    critic_obs: zn.Var,
    critic_act: zn.Var,
    critic_y: zn.Var,
    critic_loss: zn.Var,
    /// The critics' parameter handles IN THE CRITIC GRAPH. A `Var` indexes one graph, and a
    /// `Layer` keeps only its last `apply`'s handles - the actor graph re-applies the critics,
    /// so without this capture the critic step read the actor graph's indices (out of bounds).
    critic_vars: [12]zn.Var,
    actor_graph: zn.Graph(f32),
    actor_obs: zn.Var,
    actor_noise: zn.Tensor(f32),
    actor_alpha: zn.Var,
    actor_log_prob: zn.Var,
    actor_loss: zn.Var,
    critic_adam: AdamSet,
    actor_adam: AdamSet,
    temperature: zn.Temperature,
    alpha_moment: f64 = 0,
    alpha_velocity: f64 = 0,
    replay: zn.ReplayBuffer(f32),
    rng: std.Random.DefaultPrng,
    updates: usize = 0,
    // plain-forward scratch
    row: []f32,
    t1: []f32,
    t2: []f32,
    out: []f32,
    qin: []f32,
    q_out: []f32,
    /// A drawn batch (replay rows) and the noise for its next actions: `update` fills them and
    /// hands them to `updateWith`, which a check can call with its own.
    batch_rows: []f32,
    next_noise: []f32,
    /// One action's noise, for `policy`.
    noise_row: []f32,

    pub fn init(
        gpa: Allocator,
        n_obs: usize,
        n_act: usize,
        options: SacOptions,
    ) !*SacAgent {
        const a: *SacAgent = try gpa.create(SacAgent);
        errdefer gpa.destroy(a);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        a.* = .{
            .arena_state = undefined,
            .gpa = undefined,
            .options = undefined,
            .n_obs = undefined,
            .n_act = undefined,
            .actor = undefined,
            .raw_log_std = undefined,
            .q1 = undefined,
            .q2 = undefined,
            .target1 = undefined,
            .target2 = undefined,
            .critic_graph = undefined,
            .critic_obs = undefined,
            .critic_act = undefined,
            .critic_y = undefined,
            .critic_loss = undefined,
            .critic_vars = undefined,
            .actor_graph = undefined,
            .actor_obs = undefined,
            .actor_noise = undefined,
            .actor_alpha = undefined,
            .actor_log_prob = undefined,
            .actor_loss = undefined,
            .critic_adam = undefined,
            .actor_adam = undefined,
            .temperature = undefined,
            .replay = undefined,
            .rng = undefined,
            .row = undefined,
            .t1 = undefined,
            .t2 = undefined,
            .out = undefined,
            .qin = undefined,
            .q_out = undefined,
            .batch_rows = undefined,
            .next_noise = undefined,
            .noise_row = undefined,
        };
        a.arena_state = .init(gpa);
        errdefer a.arena_state.deinit();
        const arena: Allocator = a.arena_state.allocator();
        a.gpa = gpa;
        a.options = options;
        a.n_obs = n_obs;
        a.n_act = n_act;
        a.alpha_moment = 0;
        a.alpha_velocity = 0;
        a.updates = 0;
        a.rng = .init(options.seed);
        const random: std.Random = a.rng.random();
        const h: usize = options.hidden;
        const b: usize = options.batch;
        a.actor = try .init(arena, random, n_obs, h, n_act, 0.01);
        a.raw_log_std = try zeros(arena, &.{ 1, n_act });
        a.q1 = try .init(arena, random, n_obs + n_act, h, 1, 1.0);
        a.q2 = try .init(arena, random, n_obs + n_act, h, 1, 1.0);
        a.target1 = try .init(arena, random, n_obs + n_act, h, 1, 1.0);
        a.target2 = try .init(arena, random, n_obs + n_act, h, 1, 1.0);
        for (a.target1.tensors(), a.q1.tensors()) |t, o| {
            @memcpy(t.data, o.data);
        }
        for (a.target2.tensors(), a.q2.tensors()) |t, o| {
            @memcpy(t.data, o.data);
        }
        // *** -1 PER DIMENSION, the SAC heuristic (target entropy = per_dim x action_dim). This
        // passed +1.0 at first: a target entropy of +1, which a tanh-squashed 1-D action cannot
        // reach (its maximum is the uniform's, log 2 ~ 0.69) - so alpha rose from the first update
        // and ran away, doubling every 2k steps, and the cartpole policy collapsed after 8k.
        a.temperature = try zn.Temperature.forActionDim(n_act, -1.0);

        const ones_t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ b, 1 });
        @memset(ones_t.data, 1.0);
        const mean_row_t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ 1, b });
        @memset(mean_row_t.data, 1.0 / float(b));

        // -- The critic graph: both critics against one target column. --
        a.critic_graph = .init(arena);
        a.critic_graph.useScratchAllocator(gpa);
        const cg: *zn.Graph(f32) = &a.critic_graph;
        a.critic_obs = try cg.constant(try zeros(arena, &.{ b, n_obs }));
        a.critic_act = try cg.constant(try zeros(arena, &.{ b, n_act }));
        a.critic_y = try cg.constant(try zeros(arena, &.{ b, 1 }));
        const c_ones: zn.Var = try cg.constant(ones_t);
        const sa: zn.Var = try cg.concat(a.critic_obs, a.critic_act, 1);
        const v1: zn.Var = try a.q1.apply(cg, sa, c_ones);
        const v2: zn.Var = try a.q2.apply(cg, sa, c_ones);
        a.critic_loss = try cg.add(try cg.mseLoss(v1, a.critic_y), try cg.mseLoss(v2, a.critic_y));
        a.critic_vars = concatVars(a.q1.vars(), a.q2.vars());

        // -- The actor graph: a reparameterised draw through the (shared) critics. --
        a.actor_graph = .init(arena);
        a.actor_graph.useScratchAllocator(gpa);
        const ag: *zn.Graph(f32) = &a.actor_graph;
        a.actor_obs = try ag.constant(try zeros(arena, &.{ b, n_obs }));
        const a_ones: zn.Var = try ag.constant(ones_t);
        const mean: zn.Var = try a.actor.apply(ag, a.actor_obs, a_ones);
        a.raw_log_std_var = try ag.parameter(a.raw_log_std);
        const raw_log_std: zn.Var = a.raw_log_std_var;
        const half_span: f32 = 0.5 * (log_std_max - log_std_min);
        const offset_t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ 1, n_act });
        @memset(offset_t.data, log_std_min + half_span);
        const log_std_span: zn.Var = try ag.scale(try ag.tanh(raw_log_std), half_span);
        const log_std: zn.Var = try ag.add(log_std_span, try ag.constant(offset_t));
        a.actor_noise = try zeros(arena, &.{ b, n_act });
        const draw: zn.SquashedDraw = try ag.squashedReparameterize(mean, log_std, a.actor_noise);
        a.actor_log_prob = draw.log_prob;
        const q_in: zn.Var = try ag.concat(a.actor_obs, draw.action, 1);
        const w1: zn.Var = try a.q1.apply(ag, q_in, a_ones);
        const w2: zn.Var = try a.q2.apply(ag, q_in, a_ones);
        a.actor_alpha = try ag.constant(try zeros(arena, &.{ b, 1 }));
        const per_sample: zn.Var = try ag.sub(try ag.mul(a.actor_alpha, draw.log_prob), try ag.min(w1, w2));
        a.actor_loss = try ag.matmul(try ag.constant(mean_row_t), per_sample);

        a.critic_adam = try .init(arena, &concatTensors(a.q1.tensors(), a.q2.tensors()));
        a.actor_adam = try .init(arena, &(a.actor.tensors() ++ [1]zn.Tensor(f32){a.raw_log_std}));
        a.replay = try zn.ReplayBuffer(f32).init(arena, options.replay_capacity, 2 * n_obs + n_act + 2);
        a.row = try arena.alloc(f32, 2 * n_obs + n_act + 2);
        a.t1 = try arena.alloc(f32, h);
        a.t2 = try arena.alloc(f32, h);
        a.out = try arena.alloc(f32, n_act);
        a.qin = try arena.alloc(f32, n_obs + n_act);
        a.q_out = try arena.alloc(f32, 1);
        a.batch_rows = try arena.alloc(f32, b * (2 * n_obs + n_act + 2));
        a.next_noise = try arena.alloc(f32, b * n_act);
        a.noise_row = try arena.alloc(f32, n_act);
        return a;
    }

    pub fn deinit(a: *SacAgent) void {
        a.critic_graph.deinitScratch();
        a.actor_graph.deinitScratch();
        a.arena_state.deinit();
        a.gpa.destroy(a);
    }

    fn zeros(arena: Allocator, shape: []const usize) !zn.Tensor(f32) {
        const t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, shape);
        @memset(t.data, 0.0);
        return t;
    }

    fn concatTensors(x: [6]zn.Tensor(f32), y: [6]zn.Tensor(f32)) [12]zn.Tensor(f32) {
        return x ++ y;
    }

    /// `policy` with the noise given (one value per action dimension), not drawn.
    fn policyWithNoise(
        a: *SacAgent,
        obs: []const f32,
        action: []f32,
        noise: []const f32,
    ) f32 {
        a.actor.forward(obs, a.t1, a.t2, a.out);
        var log_prob: f32 = 0.0;
        for (0..a.n_act) |k| {
            const half_span: f32 = 0.5 * (log_std_max - log_std_min);
            const ls: f32 = log_std_min + half_span + half_span * tanh(a.raw_log_std.data[k]);
            const u: f32 = a.out[k] + @exp(ls) * noise[k];
            action[k] = tanh(u);
            log_prob += -0.5 * noise[k] * noise[k] - ls - 0.5 * @log(2.0 * pi) - zn.squashCorrection(f32, u);
        }
        return log_prob;
    }

    /// The actor's action for one observation, in [-1, 1], and its log-prob: a draw, or the
    /// mean (`deterministic`) - what the policy has learned, for evaluation.
    fn policy(
        a: *SacAgent,
        obs: []const f32,
        action: []f32,
        deterministic: bool,
    ) f32 {
        // One copy of the actor's forward and log-prob (`policyWithNoise`): the noise is drawn
        // here, one value per dimension in order - the same stream this drew inline before.
        for (a.noise_row) |*x| {
            x.* = if (deterministic) 0.0 else a.rng.random().floatNorm(f32);
        }
        return a.policyWithNoise(obs, action, a.noise_row);
    }

    pub fn act(
        a: *SacAgent,
        obs: []const f32,
        action: []f32,
        deterministic: bool,
    ) void {
        if (!deterministic and a.replay.len < a.options.warmup) {
            for (action) |*x| {
                x.* = 2.0 * a.rng.random().float(f32) - 1.0;
            }
            return;
        }
        _ = a.policy(obs, action, deterministic);
    }

    /// Store one transition. `done` is a TERMINATION (no bootstrap), not a truncation.
    pub fn remember(
        a: *SacAgent,
        obs: []const f32,
        action: []const f32,
        reward: f32,
        next: []const f32,
        done: bool,
    ) !void {
        const n_obs: usize = a.n_obs;
        @memcpy(a.row[0..n_obs], obs);
        @memcpy(a.row[n_obs..][0..a.n_act], action);
        a.row[n_obs + a.n_act] = reward;
        @memcpy(a.row[n_obs + a.n_act + 1 ..][0..n_obs], next);
        a.row[2 * n_obs + a.n_act + 1] = if (done) 1.0 else 0.0;
        try a.replay.push(a.row);
    }

    fn criticMin(
        net1: *const Mlp3,
        net2: *const Mlp3,
        a: *SacAgent,
    ) f32 {
        net1.forward(a.qin, a.t1, a.t2, a.q_out);
        const first: f32 = a.q_out[0];
        net2.forward(a.qin, a.t1, a.t2, a.q_out);
        return @min(first, a.q_out[0]);
    }

    /// One SAC update from a replayed batch, once the warm-up is past.
    pub fn update(a: *SacAgent) !void {
        if (a.replay.len < @max(a.options.warmup, a.options.batch)) {
            return;
        }
        const width: usize = 2 * a.n_obs + a.n_act + 2;
        const sample_rng: zn.Rng = .init(@truncate(a.updates *% 2654435761));
        for (0..a.options.batch) |i| {
            try a.replay.sample(sample_rng, @intCast(i), a.batch_rows[i * width ..][0..width]);
        }
        for (a.next_noise) |*x| {
            x.* = a.rng.random().floatNorm(f32);
        }
        for (a.actor_noise.data) |*x| {
            x.* = a.rng.random().floatNorm(f32);
        }
        try a.updateWith(a.batch_rows, a.next_noise, a.actor_noise.data);
    }

    /// One SAC update from the given batch (replay rows: obs, action, reward, next obs, done)
    /// and noise (next actions', then the actor's; [batch, n_act] each).
    pub fn updateWith(
        a: *SacAgent,
        rows: []const f32,
        next_noise: []const f32,
        actor_noise: []const f32,
    ) !void {
        const b: usize = a.options.batch;
        const width: usize = 2 * a.n_obs + a.n_act + 2;
        const n_obs: usize = a.n_obs;
        const n_act: usize = a.n_act;
        const cg: *zn.Graph(f32) = &a.critic_graph;
        const ag: *zn.Graph(f32) = &a.actor_graph;
        const obs_c: []f32 = cg.valueOf(a.critic_obs).data;
        const act_c: []f32 = cg.valueOf(a.critic_act).data;
        const y: []f32 = cg.valueOf(a.critic_y).data;
        const obs_a: []f32 = ag.valueOf(a.actor_obs).data;
        const alpha: f32 = @floatCast(a.temperature.alpha());
        const next_action: []f32 = a.out[0..n_act];
        for (0..b) |i| {
            const row: []const f32 = rows[i * width ..][0..width];
            const obs: []const f32 = row[0..n_obs];
            const action: []const f32 = row[n_obs..][0..n_act];
            const reward: f32 = row[n_obs + n_act];
            const next: []const f32 = row[n_obs + n_act + 1 ..][0..n_obs];
            const done: f32 = row[2 * n_obs + n_act + 1];
            @memcpy(obs_c[i * n_obs ..][0..n_obs], obs);
            @memcpy(obs_a[i * n_obs ..][0..n_obs], obs);
            @memcpy(act_c[i * n_act ..][0..n_act], action);
            // The target: a' ~ pi(s'), then the pessimistic target critics.
            var action_buf: [64]f32 = undefined;
            const noise: []const f32 = next_noise[i * n_act ..][0..n_act];
            const next_log_prob: f32 = a.policyWithNoise(next, action_buf[0..n_act], noise);
            @memcpy(a.qin[0..n_obs], next);
            @memcpy(a.qin[n_obs..][0..n_act], action_buf[0..n_act]);
            const q_next: f32 = criticMin(&a.target1, &a.target2, a);
            y[i] = reward + a.options.gamma * (1.0 - done) * (q_next - alpha * next_log_prob);
        }
        _ = next_action;
        try cg.recompute();
        try cg.backward(a.critic_loss);
        try a.critic_adam.apply(
            cg,
            &concatTensors(a.q1.tensors(), a.q2.tensors()),
            &a.critic_vars,
            a.options.learning_rate,
        );

        // The actor: fresh noise, the current alpha, gradients through the critics to the action.
        if (actor_noise.ptr != a.actor_noise.data.ptr) {
            @memcpy(a.actor_noise.data, actor_noise);
        }
        @memset(ag.valueOf(a.actor_alpha).data, alpha);
        try ag.recompute();
        try ag.backward(a.actor_loss);
        try a.actor_adam.apply(
            ag,
            &(a.actor.tensors() ++ [1]zn.Tensor(f32){a.raw_log_std}),
            &(a.actor.vars() ++ [1]zn.Var{a.raw_log_std_var}),
            a.options.learning_rate,
        );

        // The temperature, toward its target entropy (Adam on log alpha, by hand: one scalar).
        var mean_log_prob: f64 = 0.0;
        for (ag.valueOf(a.actor_log_prob).data) |lp| {
            mean_log_prob += lp;
        }
        mean_log_prob /= float64(b);
        const grad: f64 = a.temperature.gradient(mean_log_prob);
        a.alpha_moment = 0.9 * a.alpha_moment + 0.1 * grad;
        a.alpha_velocity = 0.999 * a.alpha_velocity + 0.001 * grad * grad;
        const t: f64 = float64(a.updates + 1);
        const m_hat: f64 = a.alpha_moment / (1.0 - @exp(t * @log(0.9)));
        const v_hat: f64 = a.alpha_velocity / (1.0 - @exp(t * @log(0.999)));
        a.temperature.log_alpha -= a.options.learning_rate * m_hat / (@sqrt(v_hat) + 1.0e-8);

        // The targets follow.
        for (a.target1.tensors(), a.q1.tensors()) |target, online| {
            try zn.polyakUpdate(f32, target, online, a.options.tau);
        }
        for (a.target2.tensors(), a.q2.tensors()) |target, online| {
            try zn.polyakUpdate(f32, target, online, a.options.tau);
        }
        a.updates += 1;
    }

    fn concatVars(x: [6]zn.Var, y: [6]zn.Var) [12]zn.Var {
        return x ++ y;
    }
};

test "robot_gym: S1 gate 1 - SAC balances the continuous cartpole" {
    // ** THE FIRST SAC GATE: zimrnum's continuous cartpole, task `.hold`, a force of +-10 N
    // (the discrete cartpole is this at +-10), episodes capped at 500 steps. SAC should hold the
    // pole to the cap within ~10-20k steps; the number printed is the mean episode length per
    // 2,000 steps, and the last episodes played with the policy's MEAN action.
    // Several minutes on the CPU graph (~25 ms an update): gated like P1 LONG.
    const slow: bool = comptime @hasDecl(build_options, "slow_tests") and build_options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    const agent: *SacAgent = try .init(gpa, zn.cartpole_state_dim, zn.cartpole_action_dim, .{});
    defer agent.deinit();
    var obs: [4]f32 = undefined;
    var next_obs: [4]f32 = undefined;
    var action: [1]f32 = undefined;
    var episode_index: u32 = 0;
    var state = zn.cartpoleTaskReset(f32, zn.Rng.init(1), episode_index, .hold);
    try zn.cartpoleObserve(f32, state, &obs);
    var episode_steps: u32 = 0;
    var lengths: u64 = 0;
    var episodes: u32 = 0;
    report.print("\n  S1 gate 1, SAC on the continuous cartpole (cap 500):\n", .{});
    for (1..16001) |t| {
        agent.act(&obs, &action, false);
        const stepped = zn.cartpoleTaskStep(f32, state, 10.0 * action[0], .hold);
        episode_steps += 1;
        const truncated: bool = !stepped.failed and episode_steps >= 500;
        try zn.cartpoleObserve(f32, stepped.state, &next_obs);
        try agent.remember(&obs, &action, stepped.reward, &next_obs, stepped.failed);
        try agent.update();
        state = stepped.state;
        obs = next_obs;
        if (stepped.failed or truncated) {
            lengths += episode_steps;
            episodes += 1;
            episode_steps = 0;
            episode_index += 1;
            state = zn.cartpoleTaskReset(f32, zn.Rng.init(1), episode_index, .hold);
            try zn.cartpoleObserve(f32, state, &obs);
        }
        if (t % 2000 == 0) {
            report.print("    step {d:>5}: {d:>3} episodes, mean length {d:>6.1}, alpha {d:.3}\n", .{
                t, episodes, if (episodes > 0) float(lengths) / float(episodes) else 0.0, agent.temperature.alpha(),
            });
            lengths = 0;
            episodes = 0;
        }
    }
}

// ============================================================================
// G1 (rl_track_journal.md section 7): the GPU layer kit, proven against zimrnum on its CPU twin.
// ============================================================================

const compute_host = @import("compute_host.zig");

// ============================================================================
// PPO with its update on the zn_mlp kit (GPU, or the CPU twin), acting on the CPU.
// ============================================================================

pub const GpuPpoOptions = struct {
    hidden: usize = 32,
    /// Rows per minibatch - the batch the kit's kernels see.
    rows: usize = 256,
    learning_rate: f32 = 3.0e-4,
    clip: f32 = 0.2,
    initial_log_std: f32 = -0.5,
    seed: u64 = 1,
};

/// PPO's learner on the zn_mlp kit: a tanh policy MLP for the mean, one log-std per action
/// dimension, and a tanh value MLP - all in the kit's `params`, contiguous, so ONE Adam dispatch
/// steps them all. The CPU keeps a copy of the weights to ACT with (`act`, `value`), refreshed by
/// `syncWeights` from the readback: on a GPU that arrives a frame late, so collection runs on the
/// last weights it has while the device trains - PPO's clipped ratio, computed against the log-
/// probs of the policy that actually acted, is what makes that lag harmless.
pub fn GpuPpoOn(comptime M: type) type {
    return struct {
        const Self = @This();
        pipe: *compute_host.Compute(M),
        options: GpuPpoOptions,
        n_obs: usize,
        n_act: usize,
        /// params offsets: three policy layers, the log-std row, three value layers.
        p_off: [3]u32,
        log_std_off: u32,
        v_off: [3]u32,
        param_count: u32,
        /// acts offsets for one minibatch: its inputs, then each layer's outputs.
        obs_off: u32,
        act_off: u32,
        old_off: u32,
        ret_off: u32,
        h1_off: u32,
        h2_off: u32,
        mu_off: u32,
        g1_off: u32,
        g2_off: u32,
        val_off: u32,
        /// dacts offsets.
        d_mu: u32,
        d_h2: u32,
        d_h1: u32,
        d_in: u32,
        d_val: u32,
        d_g2: u32,
        d_g1: u32,
        cpu_params: []f32,
        staging: []f32,
        t1: []f32,
        t2: []f32,
        mean: []f32,
        adam_step: u32 = 0,

        pub fn init(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            n_obs: usize,
            n_act: usize,
            options: GpuPpoOptions,
        ) !Self {
            const h: u32 = @intCast(options.hidden);
            const no: u32 = @intCast(n_obs);
            const na: u32 = @intCast(n_act);
            const rows: u32 = @intCast(options.rows);
            var p: Self = undefined;
            p.pipe = pipe;
            p.options = options;
            p.n_obs = n_obs;
            p.n_act = n_act;
            p.adam_step = 0;
            // params: layer = W [in, out] then b [out].
            var at: u32 = 0;
            const layer_sizes = [3][2]u32{ .{ no, h }, .{ h, h }, .{ h, na } };
            for (layer_sizes, 0..) |dims, i| {
                p.p_off[i] = at;
                at += dims[0] * dims[1] + dims[1];
            }
            p.log_std_off = at;
            at += na;
            const value_sizes = [3][2]u32{ .{ no, h }, .{ h, h }, .{ h, 1 } };
            for (value_sizes, 0..) |dims, i| {
                p.v_off[i] = at;
                at += dims[0] * dims[1] + dims[1];
            }
            p.param_count = at;
            // acts: the staged minibatch first (obs, actions, old log-probs + advantages, returns).
            p.obs_off = 0;
            p.act_off = rows * no;
            p.old_off = p.act_off + rows * na;
            p.ret_off = p.old_off + 2 * rows;
            p.h1_off = p.ret_off + rows;
            p.h2_off = p.h1_off + rows * h;
            p.mu_off = p.h2_off + rows * h;
            p.g1_off = p.mu_off + rows * na;
            p.g2_off = p.g1_off + rows * h;
            p.val_off = p.g2_off + rows * h;
            p.d_mu = 0;
            p.d_h2 = rows * na;
            p.d_h1 = p.d_h2 + rows * h;
            p.d_in = p.d_h1 + rows * h;
            p.d_val = p.d_in + rows * no;
            p.d_g2 = p.d_val + rows;
            p.d_g1 = p.d_g2 + rows * h;
            const fits: bool = p.d_g1 + rows * h <= M.config.max and p.val_off + rows <= M.config.max;
            assertf(fits, @src(), "the kit's buffers are too small for this network and batch", .{});

            p.cpu_params = try gpa.alloc(f32, p.param_count);
            p.staging = try gpa.alloc(f32, p.h1_off);
            p.t1 = try gpa.alloc(f32, options.hidden);
            p.t2 = try gpa.alloc(f32, options.hidden);
            p.mean = try gpa.alloc(f32, n_act);
            var rng: std.Random.DefaultPrng = .init(options.seed);
            const random: std.Random = rng.random();
            const gains = [3]f32{ 1.0, 1.0, 0.01 };
            for (layer_sizes, p.p_off, gains) |dims, off, gain| {
                initLayer(p.cpu_params[off..][0 .. dims[0] * dims[1] + dims[1]], dims[0], dims[1], gain, random);
            }
            @memset(p.cpu_params[p.log_std_off..][0..na], options.initial_log_std);
            for (value_sizes, p.v_off) |dims, off| {
                initLayer(p.cpu_params[off..][0 .. dims[0] * dims[1] + dims[1]], dims[0], dims[1], 1.0, random);
            }
            // The readback carries the parameters only: a whole 1 MiB buffer every frame is waste.
            pipe.element_count = p.param_count;
            pipe.upload(.params, p.cpu_params);
            const zeros_buf: []f32 = try gpa.alloc(f32, p.param_count);
            defer gpa.free(zeros_buf);
            @memset(zeros_buf, 0.0);
            pipe.upload(.adam_m, zeros_buf);
            pipe.upload(.adam_v, zeros_buf);
            return p;
        }

        pub fn deinit(p: *Self, gpa: Allocator) void {
            gpa.free(p.cpu_params);
            gpa.free(p.staging);
            gpa.free(p.t1);
            gpa.free(p.t2);
            gpa.free(p.mean);
        }

        fn initLayer(
            out: []f32,
            in: u32,
            width: u32,
            gain: f32,
            random: std.Random,
        ) void {
            const limit: f32 = gain * @sqrt(6.0 / float(in + width));
            for (out[0 .. in * width]) |*w| {
                w.* = limit * (2.0 * random.float(f32) - 1.0);
            }
            @memset(out[in * width ..], 0.0);
        }

        /// Sample an action from the CPU copy of the policy; returns its log-prob.
        pub fn act(
            p: *Self,
            obs: []const f32,
            action: []f32,
            random: std.Random,
        ) f32 {
            kitLayer(p.cpu_params, p.p_off[0], obs, p.t1, true);
            kitLayer(p.cpu_params, p.p_off[1], p.t1, p.t2, true);
            kitLayer(p.cpu_params, p.p_off[2], p.t2, p.mean, false);
            var logp: f32 = 0.0;
            for (0..p.n_act) |j| {
                const log_std: f32 = p.cpu_params[p.log_std_off + j];
                const z: f32 = random.floatNorm(f32);
                action[j] = p.mean[j] + @exp(log_std) * z;
                logp += -0.5 * z * z - log_std - 0.9189385;
            }
            return logp;
        }

        /// The policy's MEAN action - what it does when it is being judged rather than trained.
        pub fn actMean(p: *Self, obs: []const f32, action: []f32) void {
            kitLayer(p.cpu_params, p.p_off[0], obs, p.t1, true);
            kitLayer(p.cpu_params, p.p_off[1], p.t1, p.t2, true);
            kitLayer(p.cpu_params, p.p_off[2], p.t2, p.mean, false);
            @memcpy(action, p.mean[0..p.n_act]);
        }

        /// The policy's MEAN for one observation, on the CPU copy of the weights - no sampling, no random
        /// numbers consumed. Valid until the next call.
        pub fn meanOf(p: *Self, obs: []const f32) []const f32 {
            kitLayer(p.cpu_params, p.p_off[0], obs, p.t1, true);
            kitLayer(p.cpu_params, p.p_off[1], p.t1, p.t2, true);
            kitLayer(p.cpu_params, p.p_off[2], p.t2, p.mean, false);
            return p.mean;
        }

        pub fn value(p: *Self, obs: []const f32) f32 {
            var v: [1]f32 = undefined;
            kitLayer(p.cpu_params, p.v_off[0], obs, p.t1, true);
            kitLayer(p.cpu_params, p.v_off[1], p.t1, p.t2, true);
            kitLayer(p.cpu_params, p.v_off[2], p.t2, &v, false);
            return v[0];
        }

        /// Where a minibatch is written before `trainMinibatch`: slices into the staging block.
        pub const Staged = struct {
            obs: []f32,
            act: []f32,
            old: []f32,
            adv: []f32,
            ret: []f32,
        };

        /// The staging block a minibatch is written into before `trainMinibatch`.
        pub fn stage(p: *Self) Staged {
            const rows: usize = p.options.rows;
            return .{
                .obs = p.staging[p.obs_off..][0 .. rows * p.n_obs],
                .act = p.staging[p.act_off..][0 .. rows * p.n_act],
                .old = p.staging[p.old_off..][0..rows],
                .adv = p.staging[p.old_off + rows ..][0..rows],
                .ret = p.staging[p.ret_off..][0..rows],
            };
        }

        fn dispatch(
            p: *Self,
            comptime kernel: []const u8,
            params_: M.Params,
            n: usize,
        ) void {
            p.pipe.params = params_;
            p.pipe.run(kernel, @intCast(n));
        }

        /// One PPO minibatch step on the kit: the staged block uploaded, policy forward, the PPO
        /// head's gradients, the policy backward chain, value forward, MSE, the value backward chain,
        /// and ONE Adam dispatch over every parameter.
        pub fn trainMinibatch(p: *Self) void {
            const rows: u32 = @intCast(p.options.rows);
            const h: u32 = @intCast(p.options.hidden);
            const no: u32 = @intCast(p.n_obs);
            const na: u32 = @intCast(p.n_act);
            const tanh_act: u32 = @backingInt(M.Act.tanh);
            const lin: u32 = @backingInt(M.Act.linear);
            p.pipe.upload(.acts, p.staging);
            // ONE submission for the whole minibatch (compute_host's recording, section 8 E1).
            p.pipe.beginRecording();
            p.policyForward();
            // The PPO head.
            const head: M.Params = .{
                .rows = rows,
                .out_dim = na,
                .x_off = p.act_off,
                .y_off = p.mu_off,
                .t_off = p.old_off,
                .w_off = p.log_std_off,
                .dy_off = p.d_mu,
                .clip = p.options.clip,
            };
            p.dispatch("ppo_mean_grad", head, rows * na);
            p.dispatch("ppo_logstd_grad", head, na);
            p.policyBackward();
            // Value forward, MSE against the returns, backward.
            p.dispatch("dense_fwd", .{
                .rows = rows,
                .in_dim = no,
                .out_dim = h,
                .act = tanh_act,
                .x_off = p.obs_off,
                .y_off = p.g1_off,
                .w_off = p.v_off[0],
            }, rows * h);
            p.dispatch("dense_fwd", .{
                .rows = rows,
                .in_dim = h,
                .out_dim = h,
                .act = tanh_act,
                .x_off = p.g1_off,
                .y_off = p.g2_off,
                .w_off = p.v_off[1],
            }, rows * h);
            const v3: M.Params = .{
                .rows = rows,
                .in_dim = h,
                .out_dim = 1,
                .act = lin,
                .x_off = p.g2_off,
                .y_off = p.val_off,
                .t_off = p.ret_off,
                .w_off = p.v_off[2],
                .dy_off = p.d_val,
                .dx_off = p.d_g2,
            };
            p.dispatch("dense_fwd", v3, rows);
            p.dispatch("mse_bwd", v3, rows);
            p.dispatch("dense_bwd_w", v3, h + 1);
            p.dispatch("dense_bwd_x", v3, rows * h);
            const v2: M.Params = .{
                .rows = rows,
                .in_dim = h,
                .out_dim = h,
                .act = tanh_act,
                .x_off = p.g1_off,
                .y_off = p.g2_off,
                .w_off = p.v_off[1],
                .dy_off = p.d_g2,
                .dx_off = p.d_g1,
            };
            p.dispatch("act_bwd", v2, rows * h);
            p.dispatch("dense_bwd_w", v2, h * h + h);
            p.dispatch("dense_bwd_x", v2, rows * h);
            const v1: M.Params = .{
                .rows = rows,
                .in_dim = no,
                .out_dim = h,
                .act = tanh_act,
                .x_off = p.obs_off,
                .y_off = p.g1_off,
                .w_off = p.v_off[0],
                .dy_off = p.d_g1,
                .dx_off = p.d_in,
            };
            p.dispatch("act_bwd", v1, rows * h);
            p.dispatch("dense_bwd_w", v1, no * h + h);
            // One Adam step over everything.
            p.adam_step += 1;
            const s: f32 = float(p.adam_step);
            p.dispatch("adam", .{
                .w_off = 0,
                .count = p.param_count,
                .rate = p.options.learning_rate,
                .correction1 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.9)))),
                .correction2 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.999)))),
            }, p.param_count);
            p.pipe.submitRecording();
        }

        /// The policy's forward pass over a staged minibatch: observations at `obs_off` -> the means at
        /// `mu_off`. Shared by PPO's update and the clone's, so the two can never drift apart.
        fn policyForward(p: *Self) void {
            const rows: u32 = @intCast(p.options.rows);
            const h: u32 = @intCast(p.options.hidden);
            const no: u32 = @intCast(p.n_obs);
            const na: u32 = @intCast(p.n_act);
            const tanh_act: u32 = @backingInt(M.Act.tanh);
            const lin: u32 = @backingInt(M.Act.linear);
            // Policy forward.
            p.dispatch("dense_fwd", .{
                .rows = rows,
                .in_dim = no,
                .out_dim = h,
                .act = tanh_act,
                .x_off = p.obs_off,
                .y_off = p.h1_off,
                .w_off = p.p_off[0],
            }, rows * h);
            p.dispatch("dense_fwd", .{
                .rows = rows,
                .in_dim = h,
                .out_dim = h,
                .act = tanh_act,
                .x_off = p.h1_off,
                .y_off = p.h2_off,
                .w_off = p.p_off[1],
            }, rows * h);
            p.dispatch("dense_fwd", .{
                .rows = rows,
                .in_dim = h,
                .out_dim = na,
                .act = lin,
                .x_off = p.h2_off,
                .y_off = p.mu_off,
                .w_off = p.p_off[2],
            }, rows * na);
        }

        /// The policy's backward pass from a gradient on the means (`d_mu`) to every policy weight's
        /// gradient - overwritten, never accumulated. Shared by PPO's update and the clone's.
        fn policyBackward(p: *Self) void {
            const rows: u32 = @intCast(p.options.rows);
            const h: u32 = @intCast(p.options.hidden);
            const no: u32 = @intCast(p.n_obs);
            const na: u32 = @intCast(p.n_act);
            const tanh_act: u32 = @backingInt(M.Act.tanh);
            const lin: u32 = @backingInt(M.Act.linear);
            // Policy backward.
            const l3: M.Params = .{
                .rows = rows,
                .in_dim = h,
                .out_dim = na,
                .act = lin,
                .x_off = p.h2_off,
                .y_off = p.mu_off,
                .w_off = p.p_off[2],
                .dy_off = p.d_mu,
                .dx_off = p.d_h2,
            };
            p.dispatch("dense_bwd_w", l3, h * na + na);
            p.dispatch("dense_bwd_x", l3, rows * h);
            const l2: M.Params = .{
                .rows = rows,
                .in_dim = h,
                .out_dim = h,
                .act = tanh_act,
                .x_off = p.h1_off,
                .y_off = p.h2_off,
                .w_off = p.p_off[1],
                .dy_off = p.d_h2,
                .dx_off = p.d_h1,
            };
            p.dispatch("act_bwd", l2, rows * h);
            p.dispatch("dense_bwd_w", l2, h * h + h);
            p.dispatch("dense_bwd_x", l2, rows * h);
            const l1: M.Params = .{
                .rows = rows,
                .in_dim = no,
                .out_dim = h,
                .act = tanh_act,
                .x_off = p.obs_off,
                .y_off = p.h1_off,
                .w_off = p.p_off[0],
                .dy_off = p.d_h1,
                .dx_off = p.d_in,
            };
            p.dispatch("act_bwd", l1, rows * h);
            p.dispatch("dense_bwd_w", l1, no * h + h);
        }

        /// BEHAVIOUR CLONING (D5 step 3): one supervised step of the POLICY toward a teacher's actions. It's
        /// the policy half of `trainMinibatch` with the PPO head swapped for `mse_bwd` - d_mu = 2 (mu - label)
        /// / (rows x actions), the gradient of the mean square error - and Adam over the policy's layers
        /// ONLY: the log-std row and the value net keep their weights AND their Adam moments. So the network
        /// cloned is the very network PPO then fine-tunes; nothing is copied between two nets. The Adam step
        /// count is shared with PPO's (its bias corrections are ~1 after the first hundred steps anyway).
        /// `observations`: rows x n_obs, normalised exactly as PPO sees them; `labels`: rows x n_act.
        pub fn cloneMinibatch(p: *Self, observations: []const f32, labels: []const f32) void {
            const rows: u32 = @intCast(p.options.rows);
            const no: u32 = @intCast(p.n_obs);
            const na: u32 = @intCast(p.n_act);
            assertf(
                observations.len == rows * no and labels.len == rows * na,
                @src(),
                "clone minibatch: {d} observations, {d} labels; want {d} x {d} and {d} x {d}",
                .{ observations.len, labels.len, rows, no, rows, na },
            );
            @memcpy(p.staging[p.obs_off..][0 .. rows * no], observations);
            @memcpy(p.staging[p.act_off..][0 .. rows * na], labels);
            p.pipe.upload(.acts, p.staging);
            p.pipe.beginRecording();
            p.policyForward();
            p.dispatch("mse_bwd", .{
                .rows = rows,
                .out_dim = na,
                .y_off = p.mu_off,
                .t_off = p.act_off,
                .dy_off = p.d_mu,
            }, rows * na);
            p.policyBackward();
            p.adam_step += 1;
            const s: f32 = @floatFromInt(p.adam_step);
            const count: u32 = p.log_std_off - p.p_off[0];
            p.dispatch("adam", .{
                .w_off = p.p_off[0],
                .count = count,
                .rate = p.options.learning_rate,
                .correction1 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.9)))),
                .correction2 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.999)))),
            }, count);
            p.pipe.submitRecording();
        }

        /// Refresh the CPU copy from the device; false if no readback has arrived yet.
        pub fn syncWeights(p: *Self) bool {
            const latest: []const f32 = p.pipe.readLatest(.params) orelse return false;
            @memcpy(p.cpu_params, latest[0..p.param_count]);
            return true;
        }
    };
}

// ============================================================================
// S2 (rl_track_journal.md section 7): SAC's update on the zn_mlp kit.
// ============================================================================

/// One dense layer on the CPU in the kit's layout (W [in, out] row-major, then b [out]).
fn kitLayer(
    params_: []const f32,
    off: u32,
    x: []const f32,
    out: []f32,
    squash: bool,
) void {
    const in: usize = x.len;
    const width: usize = out.len;
    for (0..width) |o| {
        var acc: f32 = params_[off + in * width + o];
        for (x, 0..) |xi, i| {
            acc += xi * params_[off + i * width + o];
        }
        out[o] = if (squash) tanh(acc) else acc;
    }
}

/// SAC's update on the zn_mlp kit (a GPU, or the kit's CPU twin), step for step
/// `SacAgent.updateWith`: the target pass (actor on s', squash, target critics, `sac_target`),
/// the critic pass (both critics, MSE, backward, Adam), the actor pass through the UPDATED critics
/// (`min_route`, the critics' input gradients, `squash_bwd`, the actor backward), the temperature,
/// one Adam dispatch over actor + log-std + log alpha, and `polyak`. The batch goes up as
/// interleaved [state | action] rows, which the actor reads with a stride and the squash writes
/// into - no concatenation kernel.
pub fn GpuSacOn(comptime M: type) type {
    return struct {
        const Self = @This();

        pipe: *compute_host.Compute(M),
        options: SacOptions,
        n_obs: u32,
        n_act: u32,
        hidden: u32,
        rows: u32,
        width: u32,
        actor: [3]u32,
        raw_log_std: u32,
        log_alpha: u32,
        /// Actor layers, the raw log-std and log alpha, contiguous from actor[0]: one Adam.
        actor_count: u32,
        q1: [3]u32,
        q2: [3]u32,
        /// Both critics, contiguous from q1[0]; the targets mirror them from t1[0].
        critic_count: u32,
        t1: [3]u32,
        t2: [3]u32,
        param_count: u32,
        // acts: the uploaded block first
        sa: u32,
        s2a: u32,
        spi: u32,
        rew: u32,
        eps_next: u32,
        eps_pi: u32,
        upload_len: u32,
        ah1: u32,
        ah2: u32,
        amu: u32,
        au: u32,
        alogp: u32,
        nh1: u32,
        nh2: u32,
        nmu: u32,
        nu: u32,
        nlogp: u32,
        c1h1: u32,
        c1h2: u32,
        cq1: u32,
        c2h1: u32,
        c2h2: u32,
        cq2: u32,
        tq1: u32,
        tq2: u32,
        y: u32,
        // dacts
        dq1: u32,
        dq2: u32,
        d1h2: u32,
        d1h1: u32,
        d2h2: u32,
        d2h1: u32,
        dx1: u32,
        dx2: u32,
        du: u32,
        dah2: u32,
        dah1: u32,
        staging: []f32,
        adam_step: u32 = 0,
        /// The actor's parameters on the CPU, to ACT with - refreshed by `syncActor`.
        cpu_actor: []f32,
        t1_cpu: []f32,
        t2_cpu: []f32,
        mean_cpu: []f32,

        const Bump = struct {
            at: u32 = 0,
            fn take(bump: *Bump, n: u32) u32 {
                const o: u32 = bump.at;
                bump.at += n;
                return o;
            }
        };

        fn layerSize(in: u32, out: u32) u32 {
            return in * out + out;
        }

        pub fn init(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            n_obs: usize,
            n_act: usize,
            options: SacOptions,
        ) !Self {
            var p: Self = undefined;
            p.pipe = pipe;
            p.options = options;
            p.n_obs = @intCast(n_obs);
            p.n_act = @intCast(n_act);
            p.hidden = @intCast(options.hidden);
            p.rows = @intCast(options.batch);
            p.width = p.n_obs + p.n_act;
            p.adam_step = 0;
            const h: u32 = p.hidden;
            const w: u32 = p.width;
            const b: u32 = p.rows;
            const na: u32 = p.n_act;
            var par: Bump = .{};
            p.actor = .{ par.take(layerSize(p.n_obs, h)), par.take(layerSize(h, h)), par.take(layerSize(h, na)) };
            p.raw_log_std = par.take(na);
            p.log_alpha = par.take(1);
            p.actor_count = par.at - p.actor[0];
            p.q1 = .{ par.take(layerSize(w, h)), par.take(layerSize(h, h)), par.take(layerSize(h, 1)) };
            p.q2 = .{ par.take(layerSize(w, h)), par.take(layerSize(h, h)), par.take(layerSize(h, 1)) };
            p.critic_count = par.at - p.q1[0];
            const shift: u32 = par.take(p.critic_count) - p.q1[0];
            p.t1 = .{ p.q1[0] + shift, p.q1[1] + shift, p.q1[2] + shift };
            p.t2 = .{ p.q2[0] + shift, p.q2[1] + shift, p.q2[2] + shift };
            p.param_count = par.at;
            var acts: Bump = .{};
            p.sa = acts.take(b * w);
            p.s2a = acts.take(b * w);
            p.spi = acts.take(b * w);
            p.rew = acts.take(2 * b);
            p.eps_next = acts.take(b * na);
            p.eps_pi = acts.take(b * na);
            p.upload_len = acts.at;
            p.ah1 = acts.take(b * h);
            p.ah2 = acts.take(b * h);
            p.amu = acts.take(b * na);
            p.au = acts.take(b * na);
            p.alogp = acts.take(b);
            p.nh1 = acts.take(b * h);
            p.nh2 = acts.take(b * h);
            p.nmu = acts.take(b * na);
            p.nu = acts.take(b * na);
            p.nlogp = acts.take(b);
            p.c1h1 = acts.take(b * h);
            p.c1h2 = acts.take(b * h);
            p.cq1 = acts.take(b);
            p.c2h1 = acts.take(b * h);
            p.c2h2 = acts.take(b * h);
            p.cq2 = acts.take(b);
            p.tq1 = acts.take(b);
            p.tq2 = acts.take(b);
            p.y = acts.take(b);
            var dact: Bump = .{};
            p.dq1 = dact.take(b);
            p.dq2 = dact.take(b);
            p.d1h2 = dact.take(b * h);
            p.d1h1 = dact.take(b * h);
            p.d2h2 = dact.take(b * h);
            p.d2h1 = dact.take(b * h);
            p.dx1 = dact.take(b * w);
            p.dx2 = dact.take(b * w);
            p.du = dact.take(b * na);
            p.dah2 = dact.take(b * h);
            p.dah1 = dact.take(b * h);
            const fits: bool = acts.at <= M.config.max and dact.at <= M.config.max and par.at <= M.config.max;
            assertf(fits, @src(), "the kit's buffers are too small for this SAC's networks and batch", .{});
            p.staging = try gpa.alloc(f32, p.upload_len);
            p.cpu_actor = try gpa.alloc(f32, p.actor_count);
            p.t1_cpu = try gpa.alloc(f32, p.hidden);
            p.t2_cpu = try gpa.alloc(f32, p.hidden);
            p.mean_cpu = try gpa.alloc(f32, p.n_act);
            pipe.element_count = p.param_count;
            return p;
        }

        /// A fresh learner, initialised exactly as a `SacAgent` would be (it is one's weights).
        pub fn initFresh(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            n_obs: usize,
            n_act: usize,
            options: SacOptions,
        ) !Self {
            const agent: *SacAgent = try .init(gpa, n_obs, n_act, options);
            defer agent.deinit();
            return initFrom(gpa, pipe, agent);
        }

        /// Read back only the actor (it is first in params): what acting needs, and the
        /// readback copies each field's first `element_count` elements.
        pub fn readbackActorOnly(p: *Self) void {
            p.pipe.element_count = p.actor_count;
        }

        /// Refresh the CPU's actor from the latest readback; false if none has landed.
        pub fn syncActor(p: *Self) bool {
            const latest: []const f32 = p.pipe.readLatest(.params) orelse return false;
            if (latest.len < p.actor_count) {
                return false;
            }
            @memcpy(p.cpu_actor, latest[0..p.actor_count]);
            return true;
        }

        /// An action in [-1, 1] from the CPU's actor: a draw, or the mean (`deterministic`).
        pub fn act(
            p: *Self,
            obs: []const f32,
            action: []f32,
            random: std.Random,
            deterministic: bool,
        ) void {
            kitLayer(p.cpu_actor, p.actor[0], obs, p.t1_cpu, true);
            kitLayer(p.cpu_actor, p.actor[1], p.t1_cpu, p.t2_cpu, true);
            kitLayer(p.cpu_actor, p.actor[2], p.t2_cpu, p.mean_cpu, false);
            const half_span: f32 = 0.5 * (log_std_max - log_std_min);
            for (0..p.n_act) |k| {
                const ls: f32 = log_std_min + half_span * (1.0 + tanh(p.cpu_actor[p.raw_log_std + k]));
                const noise: f32 = if (deterministic) 0.0 else random.floatNorm(f32);
                action[k] = tanh(p.mean_cpu[k] + @exp(ls) * noise);
            }
        }

        /// A learner holding `agent`'s exact weights, log-std and log alpha - for checking one
        /// against the other on the same numbers.
        pub fn initFrom(gpa: Allocator, pipe: *compute_host.Compute(M), agent: *const SacAgent) !Self {
            var p: Self = try .init(gpa, pipe, agent.n_obs, agent.n_act, agent.options);
            errdefer p.deinit(gpa);
            const params_: []f32 = try gpa.alloc(f32, p.param_count);
            defer gpa.free(params_);
            @memset(params_, 0.0);
            copyNet(params_, p.actor, &agent.actor);
            @memcpy(params_[p.raw_log_std..][0..p.n_act], agent.raw_log_std.data);
            params_[p.log_alpha] = @floatCast(agent.temperature.log_alpha);
            copyNet(params_, p.q1, &agent.q1);
            copyNet(params_, p.q2, &agent.q2);
            copyNet(params_, p.t1, &agent.target1);
            copyNet(params_, p.t2, &agent.target2);
            pipe.upload(.params, params_);
            @memcpy(p.cpu_actor, params_[0..p.actor_count]);
            @memset(params_, 0.0);
            pipe.upload(.adam_m, params_);
            pipe.upload(.adam_v, params_);
            return p;
        }

        fn copyNet(out: []f32, offsets: [3]u32, net: *const Mlp3) void {
            const layers = [3]*const Layer{ &net.l1, &net.l2, &net.l3 };
            for (layers, offsets) |layer, off| {
                @memcpy(out[off..][0..layer.w.data.len], layer.w.data);
                @memcpy(out[off + layer.w.data.len ..][0..layer.b.data.len], layer.b.data);
            }
        }

        pub fn deinit(p: *Self, gpa: Allocator) void {
            gpa.free(p.staging);
            gpa.free(p.cpu_actor);
            gpa.free(p.t1_cpu);
            gpa.free(p.t2_cpu);
            gpa.free(p.mean_cpu);
        }

        fn run(
            p: *Self,
            comptime kernel: []const u8,
            params_: M.Params,
            n: u32,
        ) void {
            p.pipe.params = params_;
            p.pipe.run(kernel, n);
        }

        fn fwd(
            p: *Self,
            x: u32,
            stride: u32,
            in: u32,
            out: u32,
            activation: M.Act,
            w: u32,
            y: u32,
        ) void {
            p.run("dense_fwd", .{
                .rows = p.rows,
                .in_dim = in,
                .out_dim = out,
                .act = @backingInt(activation),
                .x_off = x,
                .stride = stride,
                .w_off = w,
                .y_off = y,
            }, p.rows * out);
        }

        fn bwdW(
            p: *Self,
            x: u32,
            stride: u32,
            in: u32,
            out: u32,
            w: u32,
            dy: u32,
        ) void {
            p.run("dense_bwd_w", .{
                .rows = p.rows,
                .in_dim = in,
                .out_dim = out,
                .x_off = x,
                .stride = stride,
                .w_off = w,
                .dy_off = dy,
            }, in * out + out);
        }

        fn bwdX(
            p: *Self,
            in: u32,
            out: u32,
            w: u32,
            dy: u32,
            dx: u32,
        ) void {
            p.run("dense_bwd_x", .{
                .rows = p.rows,
                .in_dim = in,
                .out_dim = out,
                .w_off = w,
                .dy_off = dy,
                .dx_off = dx,
            }, p.rows * in);
        }

        /// Through a tanh layer's activation, in place.
        fn tanhBwd(
            p: *Self,
            out: u32,
            y: u32,
            dy: u32,
        ) void {
            p.run("act_bwd", .{
                .rows = p.rows,
                .out_dim = out,
                .act = @backingInt(M.Act.tanh),
                .y_off = y,
                .dy_off = dy,
            }, p.rows * out);
        }

        fn mlpFwd(
            p: *Self,
            net: [3]u32,
            x: u32,
            stride: u32,
            in: u32,
            out: u32,
            h1: u32,
            h2: u32,
            y: u32,
        ) void {
            p.fwd(x, stride, in, p.hidden, .tanh, net[0], h1);
            p.fwd(h1, 0, p.hidden, p.hidden, .tanh, net[1], h2);
            p.fwd(h2, 0, p.hidden, out, .linear, net[2], y);
        }

        /// A critic's weight gradients from dq at its output (its input is `x`, [rows, width]).
        fn criticWeights(
            p: *Self,
            net: [3]u32,
            x: u32,
            h1: u32,
            h2: u32,
            dq: u32,
            dh2: u32,
            dh1: u32,
        ) void {
            p.bwdW(h2, 0, p.hidden, 1, net[2], dq);
            p.bwdX(p.hidden, 1, net[2], dq, dh2);
            p.tanhBwd(p.hidden, h2, dh2);
            p.bwdW(h1, 0, p.hidden, p.hidden, net[1], dh2);
            p.bwdX(p.hidden, p.hidden, net[1], dh2, dh1);
            p.tanhBwd(p.hidden, h1, dh1);
            p.bwdW(x, 0, p.width, p.hidden, net[0], dh1);
        }

        /// A critic's gradient at its INPUT from dq at its output: no weight gradients.
        fn criticInput(
            p: *Self,
            net: [3]u32,
            h1: u32,
            h2: u32,
            dq: u32,
            dh2: u32,
            dh1: u32,
            dx: u32,
        ) void {
            p.bwdX(p.hidden, 1, net[2], dq, dh2);
            p.tanhBwd(p.hidden, h2, dh2);
            p.bwdX(p.hidden, p.hidden, net[1], dh2, dh1);
            p.tanhBwd(p.hidden, h1, dh1);
            p.bwdX(p.width, p.hidden, net[0], dh1, dx);
        }

        fn adam(p: *Self, start: u32, count: u32) void {
            const s: f32 = float(p.adam_step);
            p.run("adam", .{
                .w_off = start,
                .count = count,
                .rate = @floatCast(p.options.learning_rate),
                .correction1 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.9)))),
                .correction2 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.999)))),
            }, count);
        }

        /// One SAC update from `SacAgent.updateWith`'s inputs: replay rows (obs, action,
        /// reward, next obs, done) and the next actions' and the actor's noise.
        pub fn updateWith(
            p: *Self,
            rows: []const f32,
            next_noise: []const f32,
            actor_noise: []const f32,
        ) void {
            const no: usize = p.n_obs;
            const na: usize = p.n_act;
            const w: usize = p.width;
            const b: usize = p.rows;
            const rw: usize = 2 * no + na + 2;
            const st: []f32 = p.staging;
            @memset(st, 0.0);
            for (0..b) |i| {
                const row: []const f32 = rows[i * rw ..][0..rw];
                @memcpy(st[p.sa + i * w ..][0..no], row[0..no]);
                @memcpy(st[p.sa + i * w + no ..][0..na], row[no..][0..na]);
                @memcpy(st[p.s2a + i * w ..][0..no], row[no + na + 1 ..][0..no]);
                @memcpy(st[p.spi + i * w ..][0..no], row[0..no]);
                st[p.rew + i] = row[no + na];
                st[p.rew + b + i] = row[rw - 1];
            }
            @memcpy(st[p.eps_next..][0 .. b * na], next_noise[0 .. b * na]);
            @memcpy(st[p.eps_pi..][0 .. b * na], actor_noise[0 .. b * na]);
            p.pipe.upload(.acts, st);
            // ONE submission for the whole update, ~60 dispatches (compute_host's recording, section 8 E1).
            p.pipe.beginRecording();
            p.adam_step += 1;
            const entropy: f32 = -float(p.n_act);

            // -- The target: a' ~ pi(s') written into s2a's action slot, the target critics. --
            p.mlpFwd(p.actor, p.s2a, p.width, p.n_obs, p.n_act, p.nh1, p.nh2, p.nmu);
            const next_squash: M.Params = .{
                .rows = p.rows,
                .out_dim = p.n_act,
                .y_off = p.nmu,
                .x_off = p.eps_next,
                .w_off = p.raw_log_std,
                .u_off = p.nu,
                .z_off = p.s2a,
                .stride = p.width,
                .col = p.n_obs,
                .l_off = p.nlogp,
            };
            p.run("squash_fwd", next_squash, p.rows * p.n_act);
            p.run("squash_logp", next_squash, p.rows);
            p.mlpFwd(p.t1, p.s2a, 0, p.width, 1, p.c1h1, p.c1h2, p.tq1);
            p.mlpFwd(p.t2, p.s2a, 0, p.width, 1, p.c2h1, p.c2h2, p.tq2);
            p.run("sac_target", .{
                .rows = p.rows,
                .y_off = p.tq1,
                .z_off = p.tq2,
                .l_off = p.nlogp,
                .x_off = p.rew,
                .t_off = p.y,
                .v_off = p.log_alpha,
                .gamma = p.options.gamma,
            }, p.rows);

            // -- The critics: both against y, one Adam over both. --
            p.mlpFwd(p.q1, p.sa, 0, p.width, 1, p.c1h1, p.c1h2, p.cq1);
            p.mlpFwd(p.q2, p.sa, 0, p.width, 1, p.c2h1, p.c2h2, p.cq2);
            p.run("mse_bwd", .{ .rows = p.rows, .out_dim = 1, .y_off = p.cq1, .t_off = p.y, .dy_off = p.dq1 }, p.rows);
            p.run("mse_bwd", .{ .rows = p.rows, .out_dim = 1, .y_off = p.cq2, .t_off = p.y, .dy_off = p.dq2 }, p.rows);
            p.criticWeights(p.q1, p.sa, p.c1h1, p.c1h2, p.dq1, p.d1h2, p.d1h1);
            p.criticWeights(p.q2, p.sa, p.c2h1, p.c2h2, p.dq2, p.d2h2, p.d2h1);
            p.adam(p.q1[0], p.critic_count);

            // -- The actor: a reparameterised draw, through the UPDATED critics. --
            p.mlpFwd(p.actor, p.spi, p.width, p.n_obs, p.n_act, p.ah1, p.ah2, p.amu);
            const squash: M.Params = .{
                .rows = p.rows,
                .out_dim = p.n_act,
                .y_off = p.amu,
                .x_off = p.eps_pi,
                .w_off = p.raw_log_std,
                .u_off = p.au,
                .z_off = p.spi,
                .stride = p.width,
                .col = p.n_obs,
                .l_off = p.alogp,
            };
            p.run("squash_fwd", squash, p.rows * p.n_act);
            p.run("squash_logp", squash, p.rows);
            p.mlpFwd(p.q1, p.spi, 0, p.width, 1, p.c1h1, p.c1h2, p.cq1);
            p.mlpFwd(p.q2, p.spi, 0, p.width, 1, p.c2h1, p.c2h2, p.cq2);
            p.run("min_route", .{
                .rows = p.rows,
                .y_off = p.cq1,
                .z_off = p.cq2,
                .dy_off = p.dq1,
                .dx_off = p.dq2,
            }, p.rows);
            p.criticInput(p.q1, p.c1h1, p.c1h2, p.dq1, p.d1h2, p.d1h1, p.dx1);
            p.criticInput(p.q2, p.c2h1, p.c2h2, p.dq2, p.d2h2, p.d2h1, p.dx2);
            const back: M.Params = .{
                .rows = p.rows,
                .out_dim = p.n_act,
                .u_off = p.au,
                .dx_off = p.dx1,
                .e_off = p.dx2,
                .stride = p.width,
                .col = p.n_obs,
                .dy_off = p.du,
                .x_off = p.eps_pi,
                .w_off = p.raw_log_std,
                .v_off = p.log_alpha,
            };
            p.run("squash_bwd", back, p.rows * p.n_act);
            p.run("squash_logstd_grad", back, p.n_act);
            // The actor's layers, from du = dL/dmean (its last layer is linear).
            p.bwdW(p.ah2, 0, p.hidden, p.n_act, p.actor[2], p.du);
            p.bwdX(p.hidden, p.n_act, p.actor[2], p.du, p.dah2);
            p.tanhBwd(p.hidden, p.ah2, p.dah2);
            p.bwdW(p.ah1, 0, p.hidden, p.hidden, p.actor[1], p.dah2);
            p.bwdX(p.hidden, p.hidden, p.actor[1], p.dah2, p.dah1);
            p.tanhBwd(p.hidden, p.ah1, p.dah1);
            p.bwdW(p.spi, p.width, p.n_obs, p.hidden, p.actor[0], p.dah1);
            // The temperature, then one Adam over actor + log-std + log alpha.
            p.run("alpha_grad", .{
                .rows = p.rows,
                .l_off = p.alogp,
                .v_off = p.log_alpha,
                .target_entropy = entropy,
            }, 1);
            p.adam(p.actor[0], p.actor_count);
            // The targets follow.
            p.run("polyak", .{
                .w_off = p.t1[0],
                .v_off = p.q1[0],
                .count = p.critic_count,
                .tau = p.options.tau,
            }, p.critic_count);
            p.pipe.submitRecording();
        }

        pub fn readParams(p: *Self) ?[]const f32 {
            return p.pipe.readLatest(.params);
        }

        pub const Gaps = struct { actor: f32, log_std: f32, log_alpha: f32, critics: f32, targets: f32 };

        fn netGap(gpu: []const f32, offsets: [3]u32, net: *const Mlp3) f32 {
            var worst: f32 = 0.0;
            const layers = [3]*const Layer{ &net.l1, &net.l2, &net.l3 };
            for (layers, offsets) |layer, off| {
                for (layer.w.data, 0..) |v, i| {
                    worst = @max(worst, @abs(v - gpu[off + i]));
                }
                for (layer.b.data, 0..) |v, i| {
                    worst = @max(worst, @abs(v - gpu[off + layer.w.data.len + i]));
                }
            }
            return worst;
        }

        /// The largest difference, per parameter group, between the kit's params and `agent`'s.
        pub fn gapsTo(p: *const Self, agent: *const SacAgent, gpu: []const f32) Gaps {
            var log_std: f32 = 0.0;
            for (agent.raw_log_std.data, 0..) |v, i| {
                log_std = @max(log_std, @abs(v - gpu[p.raw_log_std + i]));
            }
            const log_alpha_cpu: f32 = @floatCast(agent.temperature.log_alpha);
            return .{
                .actor = netGap(gpu, p.actor, &agent.actor),
                .log_std = log_std,
                .log_alpha = @abs(log_alpha_cpu - gpu[p.log_alpha]),
                .critics = @max(netGap(gpu, p.q1, &agent.q1), netGap(gpu, p.q2, &agent.q2)),
                .targets = @max(netGap(gpu, p.t1, &agent.target1), netGap(gpu, p.t2, &agent.target2)),
            };
        }
    };
}
