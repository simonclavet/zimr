//! cartpole_duel - one cartpole, a planner and three learners: MPC planning on the CPU in front,
//! and behind it PPO, SAC or SuperTrack LEARNING to hold the same cartpole - their cartpoles
//! stepped on the CPU, their networks trained on the GPU.
//!
//! ── ★ WHAT THIS DEMONSTRATES ──
//!
//! The same robot.zig cartpole model throughout - identical dynamics, so comparisons are exact:
//!
//!   * FRONT: `mpc_cartpole`'s model predictive control, holding the pole from the first frame
//!     because it plans with the model itself (its ghost trajectory is the plan);
//!   * BEHIND, on a switch: a learner that knows nothing about the model -
//!       PPO         on-policy: rollouts, GAE, clipped minibatches (`robot_gym.GpuPpoOn`);
//!       SAC         off-policy: a replay, twin critics, a tuned temperature (`robot_gym.GpuSacOn`);
//!       SuperTrack  NO reward and no critic: a world model learned by supervision and a policy
//!                   trained through it, with pushes to the pole (`robot_supertrack`, fused);
//!     each on its own GPU pipe through `zn_mlp`'s kernels, each update ONE recorded submission
//!     (`compute_host`'s recording), only the weights coming back.
//!
//! ── ★★ THE FRAME IS BUDGETED ON BOTH PROCESSORS ──
//!
//! The CPU's share (the learner's collection, MPC's planning) is steered on the measured frame
//! time, AIMD, so the two converge to fair shares; a GPU batch goes out only once the last one is
//! back (the readback's mirrored generation), so at most one is in flight. Collection is double
//! buffered where it matters (PPO): the next rollout is gathered with the weights the CPU has
//! while the GPU trains on the last - harmless, because the clipped ratio uses the log-
//! probabilities of the policy that actually acted.
//!
//! The drawn learner cartpole is copy 0 of sixteen; the panel's survival is the mean length of
//! the last twenty episodes (500 physics steps, 5 s, is the cap).

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const mpc = z.robot_mpc;
const ui = z.ui;
const profiler = z.profiler;

const vec = zm.vec;
const Camera3D = zm.Camera3D;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;
const rotationZ = zm.rotationZ;
const clamp = zm.clamp;
const Color = zm.Color;
const vec2 = zm.vec2;
const pi = zm.pi;
const gym = z.robot_gym;
const zn = @import("zn");
const zn_mlp = @import("zn_mlp");
const Learner = gym.GpuPpoOn(zn_mlp);
const SacLearner = gym.GpuSacOn(zn_mlp);
const st_mod = z.robot_supertrack;
const StKit = st_mod.SuperTrackKitOn(zn_mlp);

/// Which learner holds the pole behind MPC's: PPO (on-policy, rollouts), SAC (off-policy,
/// replay) or SuperTrack (NO reward: a world model learned by supervision, a policy through it) -
/// all updating on the GPU through `zn_mlp`, each on its own pipe.
const LearnerKind = enum { ppo, sac, supertrack };

/// ── SuperTrack's side ──
/// It acts every 2 physics steps (the action held), so its step is 0.02 s - the proven
/// configuration's - and its 32-step window 0.64 s. A push to the pole every 40 of its steps,
/// as in `robot_supertrack`'s test; episodes capped at 250 of its steps (500 physics steps).
const st_frame_skip: u32 = 2;
const st_push_every: u32 = 40;
const st_push_size: f32 = 0.4;
const st_cap: u32 = 250;

/// ── SAC's side (the panel shows what an update costs on this device) ──
/// Random actions for the first transitions, as `SacAgent`.
const sac_warmup: usize = 1000;
const sac_capacity: usize = 50_000;
/// A replay row: obs (4), action (1), reward, next obs (4), done.
const sac_width: usize = 2 * 4 + 1 + 2;
/// Updates per GPU batch, steered like PPO's minibatches.
const sac_batch_max: usize = 8;
const isFinite = zm.isFinite;
const float = zm.float;

/// PPO's side: sixteen cartpoles on the CPU, their learner's update on the GPU.
const n_envs: usize = 16;
/// Steps per cartpole per rollout (a policy step is a physics step, 100 Hz).
const ppo_horizon: usize = 64;
const samples: usize = n_envs * ppo_horizon;
const epochs: usize = 4;
const minibatch_rows: usize = 256;
const minibatches: usize = samples / minibatch_rows;
/// The hold task: a fall is the pole past 12 degrees or the cart near the rail's end.
const fail_angle: f32 = 0.21;
const fail_cart: f32 = 2.2;
const episode_cap: u32 = 500;
/// ── ★★★ THE FRAME IS BUDGETED ON BOTH PROCESSORS ──
///
/// A learner that issues GPU work faster than the device completes it floods the queue - and on
/// a phone the GPU is shared with the compositor, so a flooded queue stalls the whole device, not
/// just the page. So:
///   * CPU: the learner's collection budget is steered on the measured frame time (AIMD), within
///     [cpu_budget_min_ms, cpu_budget_max_ms];
///   * GPU: a new batch of minibatches is dispatched only once the last one is BACK -
///     `readGeneration().mirrored` has reached the `submitted` recorded after it - so at most one
///     batch is ever in flight, and its size (minibatches) is steered like the CPU budget.
const frame_target_ms: f32 = 1000.0 / 60.0;
const cpu_budget_min_ms: f32 = 0.25;
const cpu_budget_max_ms: f32 = 8.0;
const gpu_batches_max: usize = 4;
const survival_window: usize = 20;
const ppo_col: Color = .{ .r = 219, .g = 107, .b = 158, .a = 255 };
/// Where PPO's copy 0 is drawn: behind MPC's cartpole.
const ppo_depth: f32 = -0.7;

/// One rollout: every step of every cartpole, env-major (cartpole e's steps are rows
/// e * ppo_horizon ..), as GAE wants them.
const Rollout = struct {
    obs: [samples * 4]f32,
    act: [samples]f32,
    logp: [samples]f32,
    reward: [samples]f32,
    value: [samples]f32,
    next_value: [samples]f32,
    terminal: [samples]bool,
    truncated: [samples]bool,
};

fn pipelineEntries(comptime M: type) [M.kernels.len]z.Compute(M).KernelWgsl {
    var table: [M.kernels.len]z.Compute(M).KernelWgsl = undefined;
    inline for (M.kernels, 0..) |name, i| {
        table[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

const sim_timestep: f32 = 1.0 / 100.0;
const rail_limit: f32 = 2.4;

/// ── ★★★ 2.5 s OF LOOKAHEAD, AND IT HAS TO BE THIS LONG ──
///
/// The first version used 60 knots — 0.6 s — chosen because a cold solve at that length is
/// 2.9 ms and fits comfortably in a frame. It balances beautifully and **cannot swing up at
/// all**: measured, the pole wandered from 3.0 rad to 58 rad over ten seconds while the cost
/// climbed through 1e6. A pump takes more than a second, so a planner that can only see 0.6 s
/// ahead never finds one — it is not a tuning problem, the solution is outside the horizon.
///
/// At 250 knots the same loop swings up and balances: theta 3.0 → 4.09 (pumping) → 1.73 →
/// 0.003 upright by frame 180, then the cart drifts back to centre and the cost falls to 0.07.
///
/// ★ AND THE COLD SOLVE NO LONGER HAS TO FIT IN A FRAME, which is the point of the budget
/// loop below. It is spread across however many frames it takes, with the robot held still and
/// the ghost trajectory sharpening while you watch.
const horizon: u32 = 250;

/// How much planning to do before letting the robot move.
///
/// ★ A cold swing-up needs ~142 iterations to converge fully, but the plan is coherent — pumping
/// in the right direction, respecting the rail — well before that. Sixty is enough to act on, and
/// the receding horizon polishes the rest while it runs: at 4 iterations a frame, a quarter of a
/// second, instead of an open-ended wait for convergence.
const warmup_iterations: u32 = 60;

const bg: Color = .{ .r = 18, .g = 20, .b = 28, .a = 255 };
const rail_col: Color = .{ .r = 64, .g = 69, .b = 84, .a = 255 };
const cart_col: Color = .{ .r = 107, .g = 158, .b = 219, .a = 255 };
const pole_col: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const ghost_col: Color = .{ .r = 89, .g = 204, .b = 153, .a = 255 };
const limit_col: Color = .{ .r = 204, .g = 89, .b = 89, .a = 255 };

/// ★ THE MOTOR CANNOT LIFT THE POLE, and that is the point of the demo. Force 6 N on ~1.1 kg
/// gives the cart a ≈ 5.45 m/s², so the largest torque it can put on the pole is m·a·l = 0.164
/// N·m. Gravity at horizontal asks for m·g·l = 0.294 N·m. There is no way up except to swing.
const Cartpole = rbt.Spec(.{
    .bodies = &.{
        .{
            .name = "cart",
            .joints = &.{.{
                .name = "slide",
                .kind = .slide,
                .axis = vec(1, 0, 0),
                .range = .{ -rail_limit, rail_limit },
            }},
            .geoms = &.{.{
                .shape = .{ .box = .{ .half_extent = vec(0.1, 0.05, 0.05) } },
                .mass = 1.0,
            }},
        },
        .{
            .name = "pole",
            .parent = "cart",
            .joints = &.{.{ .name = "hinge", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.02 } },
                .pos = vec(0, 0.3, 0),
                .mass = 0.1,
            }},
        },
    },
    .actuators = &.{.{
        .name = "push",
        .on = .{ .joint = .{ .name = "slide", .gear = 6 } },
        .ctrl_range = .{ -1, 1 },
    }},
    .options = .{
        .timestep = sim_timestep,
        .max_contacts = 4,
        .gravity = vec(0, -9.81, 0),
    },
});

const cart_slide: usize = 0;
const pole_hinge: usize = 1;

const State = struct {
    gpa: Allocator,
    model: rbt.Model,
    data: rbt.Data,
    plan: mpc.Plan,
    reference: []f32,
    applied: []f32,

    /// Iterations to spend this frame. Adapted to what the device actually manages.
    budget: f32,
    /// True until the plan is good enough to act on; while set, the loop plans without
    /// stepping. See `warmup_iterations`.
    warming: bool,
    running: bool,
    last_iterations: u32,
    last_cost: f32,
    /// Iterations spent on the CURRENT plan since the last reset, and the cost the plan
    /// started at — the two numbers that make "still planning" mean something.
    plan_iterations: u32,
    first_cost: f32,
    /// A short history of the cost, for the progress plot.
    cost_history: [96]f32,
    cost_history_len: usize,
    accumulator: f32,
    /// Rolling frame time in milliseconds — what the budget controller is protecting.
    frame_ms: f32,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]zm.Mat,
    // ── PPO ──
    pipe: z.Compute(zn_mlp),
    learner: Learner,
    envs: [n_envs]rbt.Data,
    env_steps: [n_envs]u32,
    /// Double-buffered: one fills while the other's minibatches go to the GPU.
    rollouts: [2]Rollout,
    fill: usize,
    tick: usize,
    training: ?usize,
    train_epoch: usize,
    train_batch: usize,
    order: [samples]u32,
    rollout_buffer: zn.RolloutBuffer,
    advantages: []f64,
    returns: []f64,
    rng: std.Random.DefaultPrng,
    survival: [survival_window]u32,
    survival_len: usize,
    survival_at: usize,
    iterations: usize,
    total_samples: usize,
    window_time: f32,
    window_samples: usize,
    samples_per_second: f32,
    synced: u32,
    /// The steered budgets: the learner's CPU milliseconds a frame, and PPO's minibatches a GPU batch.
    learner_budget_ms: f32,
    gpu_batches: usize,
    /// The generation the last GPU batch will be mirrored at: new work waits for it.
    gpu_wait: u64,
    /// Whether the batch that `gpu_wait` names has had its weights taken yet.
    gpu_taken: bool,
    /// Frames in the last second the GPU was still busy (a batch not yet back).
    gpu_busy_frames: u32,
    busy_window: u32,
    // ── SAC, and the switch ──
    kind: LearnerKind,
    sac_pipe: z.Compute(zn_mlp),
    sac: SacLearner,
    replay: zn.ReplayBuffer(f32),
    sac_rows: []f32,
    sac_next_noise: []f32,
    sac_actor_noise: []f32,
    sac_row: []f32,
    sac_updates: usize,
    sac_updates_window: usize,
    sac_updates_per_second: f32,
    sac_batch: usize,
    sac_wait: u64,
    sac_taken: bool,
    sac_issued_ms: f64,
    /// Encoding and submitting one update's ~60 dispatches, on the CPU (EMA, ms).
    sac_submit_ms: f32,
    /// A batch's dispatch to its weights coming back (EMA, ms): an upper bound on GPU time.
    sac_round_trip_ms: f32,
    // ── MPC's share of the frame, steered like the learners' (see planWithinFrame) ──
    mpc_budget_ms: f32,
    ms_per_iteration: f32,
    // ── SuperTrack ──
    st_host: *st_mod.SuperTrack,
    st_pipe: z.Compute(zn_mlp),
    st_kit: StKit,
    st_steps: [n_envs]u32,
    st_segments: [n_envs]u32,
    st_next_segment: u32,
    st_iterations: usize,
    st_wait: u64,
    st_taken: bool,
    st_issued_ms: f64,
    st_submit_ms: f32,
    st_round_trip_ms: f32,
};

const state_weight = [_]f32{ 0.5, 10.0, 0.1, 0.5 };
const control_weight = [_]f32{0.001};
const terminal_weight = [_]f32{ 5.0, 200.0, 5.0, 20.0 };

fn costOf(s: *const State) mpc.Cost {
    return .{
        .state = &state_weight,
        .control = &control_weight,
        .terminal = &terminal_weight,
        .reference = s.reference,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.model = try Cartpole.build(gpa);
    s.data = try rbt.Data.init(gpa, &s.model);
    s.plan = try mpc.Plan.init(gpa, &s.model, horizon);
    s.plan.readLimits(&s.model);
    s.reference = try gpa.alloc(f32, (horizon + 1) * s.plan.nstate);
    @memset(s.reference, 0); // upright, centred, at rest
    s.applied = try gpa.alloc(f32, s.model.nu);
    @memset(s.applied, 0);

    s.budget = 2;
    s.warming = true;
    s.running = true;
    s.last_iterations = 0;
    s.last_cost = 0;
    s.plan_iterations = 0;
    s.first_cost = 0;
    s.cost_history = @splat(0);
    s.cost_history_len = 0;
    s.accumulator = 0;
    s.frame_ms = 16.7;

    reset(s, 0.15);

    s.cam = z.OrbitCamera.init(vec(0, 0.35, 0), 2.4);
    s.pipe = try z.Compute(zn_mlp).initGpu(gpa, f.gpu.device, f.gpu.queue, &pipelineEntries(zn_mlp));
    s.learner = try Learner.init(gpa, &s.pipe, 4, 1, .{ .rows = minibatch_rows });
    s.rng = .init(20260919);
    for (&s.envs, 0..) |*d, e| {
        d.* = try rbt.Data.init(gpa, &s.model);
        resetEnv(s, e);
    }
    s.fill = 0;
    s.tick = 0;
    s.training = null;
    s.train_epoch = 0;
    s.train_batch = 0;
    for (&s.order, 0..) |*o, i| {
        o.* = @intCast(i);
    }
    s.rollout_buffer = try zn.RolloutBuffer.init(gpa, samples);
    s.advantages = try gpa.alloc(f64, samples);
    s.returns = try gpa.alloc(f64, samples);
    s.survival = @splat(0);
    s.survival_len = 0;
    s.survival_at = 0;
    s.iterations = 0;
    s.total_samples = 0;
    s.window_time = 0;
    s.window_samples = 0;
    s.samples_per_second = 0;
    s.synced = 0;
    s.learner_budget_ms = 1.0;
    s.gpu_batches = 1;
    s.gpu_wait = 0;
    s.gpu_taken = true;
    s.gpu_busy_frames = 0;
    s.busy_window = 0;
    s.kind = .ppo;
    s.sac_pipe = try z.Compute(zn_mlp).initGpu(gpa, f.gpu.device, f.gpu.queue, &pipelineEntries(zn_mlp));
    s.sac = try SacLearner.initFresh(gpa, &s.sac_pipe, 4, 1, .{});
    s.sac.readbackActorOnly();
    s.replay = try zn.ReplayBuffer(f32).init(gpa, sac_capacity, sac_width);
    const sac_rows_len: usize = s.sac.options.batch * sac_width;
    s.sac_rows = try gpa.alloc(f32, sac_rows_len);
    s.sac_next_noise = try gpa.alloc(f32, s.sac.options.batch);
    s.sac_actor_noise = try gpa.alloc(f32, s.sac.options.batch);
    s.sac_row = try gpa.alloc(f32, sac_width);
    s.sac_updates = 0;
    s.sac_updates_window = 0;
    s.sac_updates_per_second = 0;
    s.sac_batch = 1;
    s.sac_wait = 0;
    s.sac_taken = true;
    s.sac_issued_ms = 0;
    s.sac_submit_ms = 0;
    s.sac_round_trip_ms = 0;
    s.mpc_budget_ms = 2.0;
    s.ms_per_iteration = 0.5;
    // The host (buffer, sampling, acting) is SuperTrack's CPU object; the KIT trains, fused.
    // Actions are the actuator's control in [-1, 1] (so the force limit is 1).
    s.st_host = try st_mod.SuperTrack.init(gpa, .{ .dt = 0.02, .max_force = 1.0, .envs = n_envs, .capacity = 32_000 });
    s.st_pipe = try z.Compute(zn_mlp).initGpu(gpa, f.gpu.device, f.gpu.queue, &pipelineEntries(zn_mlp));
    s.st_kit = try StKit.initFrom(gpa, &s.st_pipe, s.st_host);
    // Only the policy comes back (it is first in params).
    s.st_pipe.element_count = s.st_kit.pol_count;
    s.st_steps = @splat(0);
    for (&s.st_segments, 0..) |*seg, e| {
        seg.* = @intCast(e);
    }
    s.st_next_segment = n_envs;
    s.st_iterations = 0;
    s.st_wait = 0;
    s.st_taken = true;
    s.st_issued_ms = 0;
    s.st_submit_ms = 0;
    s.st_round_trip_ms = 0;

    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 12, 2);
    s.transform = .{identity()};
}

fn deinit(gpa: Allocator, s: *State) void {
    // ★ THE MESHES TOO. The smoke runner's `managed` check compares live bytes across a full
    // init/deinit cycle and caught these missing — a leak that never shows up in a browser,
    // because the tab is torn down before anyone notices, and shows up immediately in the
    // launcher where examples are created and destroyed as you switch between them.
    gpa.free(s.returns);
    gpa.free(s.advantages);
    s.rollout_buffer.deinit(gpa);
    for (&s.envs) |*d| {
        d.deinit();
    }
    s.st_kit.deinit();
    s.st_pipe.deinit();
    s.st_host.deinit();
    gpa.free(s.sac_row);
    gpa.free(s.sac_actor_noise);
    gpa.free(s.sac_next_noise);
    gpa.free(s.sac_rows);
    // zimrnum's ReplayBuffer is one slice from `init`'s allocator, and has no deinit of its own.
    gpa.free(s.replay.data);
    s.sac.deinit(gpa);
    s.sac_pipe.deinit();
    s.learner.deinit(gpa);
    s.pipe.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    gpa.free(s.applied);
    gpa.free(s.reference);
    s.plan.deinit();
    s.data.deinit();
    s.model.deinit();
}

/// Put the pole at `angle` (0 upright, π hanging) and throw away the plan.
fn reset(s: *State, angle: f32) void {
    s.data.reset(&s.model);
    s.data.pos[pole_hinge] = angle;
    rbt.forward(&s.model, &s.data);
    @memset(s.plan.ctrl, 0);
    @memset(s.plan.feedback, 0);
    @memset(s.plan.feedforward, 0);
    s.warming = true;
    s.accumulator = 0;
    s.plan_iterations = 0;
    s.first_cost = 0;
    s.cost_history_len = 0;
}

/// ── ★★★ THE BUDGET LOOP: PLAN A LITTLE, ALWAYS RETURN ──
///
/// `mpc.optimize` with `iterations = n` does at most n improvement passes and returns. That is
/// the hook this whole demo hangs on: the planner is re-entrant across frames because its unit
/// of work is one iteration, and a frame simply stops asking.
///
/// ── ★★ THE BUDGET IS DRIVEN BY THE FRAME TIME, NOT BY A STOPWATCH ──
///
/// A page has no wall clock of its own to time the planner with (`bridge.zig` imports none), and
/// needs none.
///
/// ★ `f.time.delta_time` measures the thing actually worth protecting — whether frames are
/// landing on time — rather than a proxy for it. Planning time is only one contributor; a device
/// struggling with the renderer needs the planner to back off just as much, and a stopwatch
/// around `optimize` cannot see that.
///
/// The target is 1/60 s. Overshooting costs a visible stutter, so back off fast; undershooting
/// only wastes headroom, so grow slowly. A symmetric controller oscillates here, because the
/// frame time it measures is the frame time it is changing.
fn planWithinFrame(s: *State, delta_time: f32) void {
    const target: f32 = 1.0 / 60.0;

    // ── ★★★ PROFILING IS SUSPENDED ACROSS THE PLANNER, AND IT HAS TO BE ──
    //
    // `robot.step` is instrumented, which is right for a frame that steps a robot a few times.
    // One planning frame here steps it **tens of thousands** of times — 250 knots x 6
    // finite-difference columns x up to 40 iterations — and every zone takes two timestamps,
    // which on wasm are two JS boundary crossings.
    //
    // Measured: at horizon 60 the smoke runner already saw 12 225 clock calls per frame. At
    // 250 it **exhausted Node's JS heap and the gate died** — and a browser would have been
    // paying the same crossings, tens of milliseconds a frame, for a profile nobody can read
    // (a flame graph of 60 000 identical `robot.step` zones is not a diagnostic).
    //
    // ★ THIS IS NOT PROFILER-BASHING. The instrument is priced for the workload it was built
    // for. A planner is a different workload, and the right move is to tell the instrument so.
    // Everything outside this call — rendering, UI, the physics the robot actually runs — is
    // still profiled normally.
    const was_frozen: bool = profiler.isFrozen();
    profiler.freeze();
    const iterations: u32 = @trunc(clamp(s.budget, 1.0, 40.0));
    const plan_start: f64 = z.wgpu.nowMs();
    const result: mpc.Result = mpc.optimize(&s.model, &s.data, &s.plan, costOf(s), .{
        .iterations = iterations,
    });
    if (result.iterations > 0) {
        const spent: f32 = @floatCast((z.wgpu.nowMs() - plan_start) / float(result.iterations));
        s.ms_per_iteration += (spent - s.ms_per_iteration) * 0.1;
    }
    if (!was_frozen) {
        profiler.unfreeze();
    }
    s.last_iterations = result.iterations;
    s.last_cost = result.cost;
    s.plan_iterations += result.iterations;
    if (s.first_cost == 0) {
        s.first_cost = result.initial_cost;
    }

    // ── ★★★ "GOOD ENOUGH TO ACT ON" IS NOT "CONVERGED", AND WAITING FOR THE LATTER IS A BUG ──
    //
    // This used to hold the robot still until `result.converged`, which on a phone — 4
    // iterations a frame, a cold plan starting from a 2.5 s free-fall rollout — meant staring
    // at a motionless cartpole under the word "planning" with no way to tell whether it was
    // making progress or wedged. That is a worse failure than a wrong answer, because the user
    // cannot distinguish it from a hang.
    //
    // ★ AND CONVERGENCE IS THE WRONG BAR ANYWAY. MPC re-solves every single tick; the plan
    // does not need to be optimal before the first step, it needs to be SANE. A budget of
    // iterations buys that, and everything after it is bought while the robot is already
    // moving, which is what the receding horizon is for.
    if (s.plan_iterations >= warmup_iterations or result.converged) {
        s.warming = false;
    }

    // Cost history, so "still planning" comes with evidence that it is working.
    if (s.cost_history_len < s.cost_history.len) {
        s.cost_history[s.cost_history_len] = result.cost;
        s.cost_history_len += 1;
    } else {
        std.mem.copyForwards(f32, s.cost_history[0 .. s.cost_history.len - 1], s.cost_history[1..]);
        s.cost_history[s.cost_history.len - 1] = result.cost;
    }

    // A slow average, so one hitch — a texture upload, a GC pause — does not swing the budget.
    s.frame_ms += (delta_time * 1000.0 - s.frame_ms) * 0.1;
    // ── ★ A FAIR SHARE OF THE FRAME ──
    // This rule was "add iterations only below 0.7 of the frame target" - which, on a display
    // locked to vsync, never happens once a learner fills the headroom: on Simon's phone MPC sat
    // at 1 iteration a frame. Now MPC's budget is MILLISECONDS, steered by the learners' own
    // AIMD (+0.1 ms on time, x0.7 when late), and turned into iterations with the measured cost
    // of one. Two AIMD flows with the same increase and decrease converge to EQUAL shares - the
    // classic TCP result - so neither can starve the other.
    const frame_ms: f32 = delta_time * 1000.0;
    if (frame_ms > frame_target_ms * 1.25) {
        s.mpc_budget_ms = @max(cpu_budget_min_ms, s.mpc_budget_ms * 0.7);
    } else if (frame_ms < frame_target_ms * 1.1) {
        s.mpc_budget_ms = @min(cpu_budget_max_ms, s.mpc_budget_ms + 0.1);
    }
    s.budget = clamp(s.mpc_budget_ms / @max(s.ms_per_iteration, 0.01), 1.0, 40.0);
    _ = target;
}

/// A PPO cartpole back to upright, with a small random tilt.
fn resetEnv(s: *State, e: usize) void {
    const d: *rbt.Data = &s.envs[e];
    d.reset(&s.model);
    d.pos[pole_hinge] = 0.1 * (2.0 * s.rng.random().float(f32) - 1.0);
    rbt.forward(&s.model, d);
    s.env_steps[e] = 0;
}

fn observe(d: *const rbt.Data) [4]f32 {
    return .{ d.pos[cart_slide], d.pos[pole_hinge], d.vel[cart_slide], d.vel[pole_hinge] };
}

fn recordSurvival(s: *State, steps: u32) void {
    s.survival[s.survival_at] = steps;
    s.survival_at = (s.survival_at + 1) % survival_window;
    s.survival_len = @min(s.survival_len + 1, survival_window);
}

/// One lockstep tick: every PPO cartpole acts on the CPU's weights and steps once.
fn collectTick(s: *State) void {
    const r: *Rollout = &s.rollouts[s.fill];
    for (0..n_envs) |e| {
        const row: usize = e * ppo_horizon + s.tick;
        const d: *rbt.Data = &s.envs[e];
        const obs: [4]f32 = observe(d);
        @memcpy(r.obs[row * 4 ..][0..4], &obs);
        var action: [1]f32 = undefined;
        r.logp[row] = s.learner.act(&obs, &action, s.rng.random());
        r.act[row] = action[0];
        r.value[row] = s.learner.value(&obs);
        d.ctrl[0] = clamp(action[0], -1.0, 1.0);
        rbt.step(&s.model, d);
        s.env_steps[e] += 1;
        const angle: f32 = d.pos[pole_hinge];
        const failed: bool = !isFinite(angle) or @abs(angle) > fail_angle or @abs(d.pos[cart_slide]) > fail_cart;
        const capped: bool = !failed and s.env_steps[e] >= episode_cap;
        r.reward[row] = if (failed) 0.0 else 1.0;
        r.terminal[row] = failed;
        r.truncated[row] = capped or (!failed and s.tick == ppo_horizon - 1);
        const next: [4]f32 = observe(d);
        r.next_value[row] = if (failed) 0.0 else s.learner.value(&next);
        if (failed or capped) {
            recordSurvival(s, s.env_steps[e]);
            resetEnv(s, e);
        }
    }
    s.tick += 1;
    s.total_samples += n_envs;
    s.window_samples += n_envs;
}

/// A full rollout: GAE, normalised advantages, and it becomes the one being trained.
fn finishRollout(s: *State) !void {
    const r: *const Rollout = &s.rollouts[s.fill];
    s.rollout_buffer.len = 0;
    for (0..samples) |row| {
        const row_done: bool = r.terminal[row];
        try s.rollout_buffer.record(
            r.reward[row],
            r.value[row],
            r.next_value[row],
            row_done,
            r.truncated[row],
            r.logp[row],
        );
    }
    try zn.gae(s.rollout_buffer.steps[0..samples], 0.99, 0.95, s.advantages, s.returns);
    try zn.normalizeAdvantages(f64, s.advantages, 1.0e-8);
    s.training = s.fill;
    s.train_epoch = 0;
    s.train_batch = 0;
    s.fill = 1 - s.fill;
    s.tick = 0;
    s.iterations += 1;
}

/// One minibatch staged and dispatched to the GPU (it runs there asynchronously).
fn trainSlice(s: *State) void {
    const which: usize = s.training orelse return;
    const r: *const Rollout = &s.rollouts[which];
    if (s.train_batch == 0) {
        s.rng.random().shuffle(u32, &s.order);
    }
    const block: Learner.Staged = s.learner.stage();
    const start: usize = s.train_batch * minibatch_rows;
    for (0..minibatch_rows) |i| {
        const src: usize = s.order[start + i];
        @memcpy(block.obs[i * 4 ..][0..4], r.obs[src * 4 ..][0..4]);
        block.act[i] = r.act[src];
        block.old[i] = r.logp[src];
        block.adv[i] = @floatCast(s.advantages[src]);
        block.ret[i] = @floatCast(s.returns[src]);
    }
    s.learner.trainMinibatch();
    s.train_batch += 1;
    if (s.train_batch == minibatches) {
        s.train_batch = 0;
        s.train_epoch += 1;
        if (s.train_epoch == epochs) {
            s.training = null;
        }
    }
}

/// PPO's share of the frame, budgeted on both processors (see `frame_target_ms`).
fn runPpo(s: *State, delta_time: f32) void {
    // ── Steer the budgets on the measured frame time: back off fast, creep up slowly. ──
    const frame_ms: f32 = delta_time * 1000.0;
    const on_time: bool = frame_ms < frame_target_ms * 1.1;
    if (frame_ms > frame_target_ms * 1.25) {
        s.learner_budget_ms = @max(cpu_budget_min_ms, s.learner_budget_ms * 0.7);
        s.gpu_batches = @max(1, s.gpu_batches / 2);
    } else if (on_time) {
        s.learner_budget_ms = @min(cpu_budget_max_ms, s.learner_budget_ms + 0.1);
    }

    // ── GPU: new work only once the last batch is BACK (finished and mirrored). ──
    //
    // ★★ POLL THE READBACK EVERY FRAME, FIRST. `readLatest` (inside `syncWeights`) both lands a
    // finished copy AND encodes the next one, and the mirrored generation only advances in it.
    // Calling it only once the GPU looked idle deadlocked: after the first batch nothing encoded
    // a copy, so `mirrored` never reached `gpu_wait` and training stopped for good. The stub GPU
    // reports 0/0 generations, so the smoke run could not see it. Taking the mirror every frame
    // is harmless: it only ever moves forward.
    _ = s.learner.syncWeights();
    const generation: z.Compute(zn_mlp).Generation = s.pipe.readGeneration();
    const gpu_idle: bool = generation.mirrored >= s.gpu_wait;
    if (gpu_idle) {
        if (!s.gpu_taken) {
            // The batch is back: the weights just taken are the ones it produced.
            s.synced += 1;
            s.gpu_taken = true;
        }
        if (s.training != null) {
            var issued: usize = 0;
            while (issued < s.gpu_batches and s.training != null) : (issued += 1) {
                trainSlice(s);
            }
            s.gpu_wait = s.pipe.readGeneration().submitted;
            s.gpu_taken = false;
            if (on_time) {
                s.gpu_batches = @min(gpu_batches_max, s.gpu_batches + 1);
            }
        }
    } else {
        s.busy_window += 1;
    }

    // ── CPU: collect within the budget; wait when the next rollout is full and the last is
    // still training. ──
    // ★ AT LEAST ONE TICK A FRAME, then the budget: learning always progresses, even when the
    // frame's budget is spent (a tick is ~0.1 ms). The smoke runner's clock advances 16 ms a
    // CALL, so a budget-first loop exited before collecting anything - neither learner ever
    // trained headlessly, and the training paths went unexercised there.
    const start: f64 = z.wgpu.nowMs();
    var first: bool = true;
    while (first or z.wgpu.nowMs() - start < s.learner_budget_ms) {
        first = false;
        if (s.tick < ppo_horizon) {
            collectTick(s);
        } else if (s.training == null) {
            finishRollout(s) catch |err| {
                zm.assertUnreachable(@src(), "finishing a rollout failed: {t}", .{err});
            };
        } else {
            break;
        }
    }
    s.window_time += delta_time;
    if (s.window_time >= 1.0) {
        s.samples_per_second = float(s.window_samples) / s.window_time;
        s.gpu_busy_frames = s.busy_window;
        s.window_time = 0;
        s.window_samples = 0;
        s.busy_window = 0;
    }
}

/// Swap the learner: the cartpoles restart and the survival record clears; each learner keeps
/// its own weights on its own pipe.
fn switchLearner(s: *State) void {
    s.kind = switch (s.kind) {
        .ppo => .sac,
        .sac => .supertrack,
        .supertrack => .ppo,
    };
    for (0..n_envs) |e| {
        resetEnv(s, e);
        s.st_steps[e] = 0;
        s.st_segments[e] = s.st_next_segment;
        s.st_next_segment += 1;
    }
    s.survival_len = 0;
    s.survival_at = 0;
    s.tick = 0;
}

/// One lockstep tick for SAC: every cartpole acts (randomly until the warm-up is past), steps,
/// and its transition goes into the replay. `done` is a FALL, never the cap: a capped episode
/// is truncated, and its value bootstraps.
fn sacTick(s: *State) void {
    const random: std.Random = s.rng.random();
    for (0..n_envs) |e| {
        const d: *rbt.Data = &s.envs[e];
        const obs: [4]f32 = observe(d);
        var action: [1]f32 = undefined;
        if (s.replay.len < sac_warmup) {
            action[0] = 2.0 * random.float(f32) - 1.0;
        } else {
            s.sac.act(&obs, &action, random, false);
        }
        d.ctrl[0] = action[0];
        rbt.step(&s.model, d);
        s.env_steps[e] += 1;
        const angle: f32 = d.pos[pole_hinge];
        const failed: bool = !isFinite(angle) or @abs(angle) > fail_angle or @abs(d.pos[cart_slide]) > fail_cart;
        const capped: bool = !failed and s.env_steps[e] >= episode_cap;
        const next: [4]f32 = observe(d);
        const row: []f32 = s.sac_row;
        @memcpy(row[0..4], &obs);
        row[4] = action[0];
        row[5] = if (failed) 0.0 else 1.0;
        @memcpy(row[6..10], &next);
        row[10] = if (failed) 1.0 else 0.0;
        if (isFinite(angle)) {
            s.replay.push(row) catch |err| {
                zm.assertUnreachable(@src(), "the replay refused a row: {t}", .{err});
            };
        }
        if (failed or capped) {
            recordSurvival(s, s.env_steps[e]);
            resetEnv(s, e);
        }
    }
    s.total_samples += n_envs;
    s.window_samples += n_envs;
}

/// One SAC update: a replayed batch and fresh noise, dispatched to the GPU.
fn sacUpdate(s: *State) void {
    const random: std.Random = s.rng.random();
    const draw: zn.Rng = .init(@truncate(s.sac_updates *% 2654435761));
    for (0..s.sac.options.batch) |i| {
        s.replay.sample(draw, @intCast(i), s.sac_rows[i * sac_width ..][0..sac_width]) catch |err| {
            zm.assertUnreachable(@src(), "replay sample failed: {t}", .{err});
        };
    }
    for (s.sac_next_noise) |*v| {
        v.* = random.floatNorm(f32);
    }
    for (s.sac_actor_noise) |*v| {
        v.* = random.floatNorm(f32);
    }
    s.sac.updateWith(s.sac_rows, s.sac_next_noise, s.sac_actor_noise);
    s.sac_updates += 1;
    s.sac_updates_window += 1;
}

/// SAC's share of the frame, budgeted exactly as PPO's: the CPU collects within the steered
/// budget; a batch of updates goes to the GPU only once the last one is back.
fn runSac(s: *State, delta_time: f32) void {
    const frame_ms: f32 = delta_time * 1000.0;
    const on_time: bool = frame_ms < frame_target_ms * 1.1;
    if (frame_ms > frame_target_ms * 1.25) {
        s.learner_budget_ms = @max(cpu_budget_min_ms, s.learner_budget_ms * 0.7);
        s.sac_batch = @max(1, s.sac_batch / 2);
    } else if (on_time) {
        s.learner_budget_ms = @min(cpu_budget_max_ms, s.learner_budget_ms + 0.1);
    }
    // Poll first: the readback only advances inside it (see runPpo).
    _ = s.sac.syncActor();
    const generation: z.Compute(zn_mlp).Generation = s.sac_pipe.readGeneration();
    if (generation.mirrored >= s.sac_wait) {
        if (!s.sac_taken) {
            const trip: f32 = @floatCast(z.wgpu.nowMs() - s.sac_issued_ms);
            s.sac_round_trip_ms += (trip - s.sac_round_trip_ms) * 0.2;
            s.synced += 1;
            s.sac_taken = true;
        }
        if (s.replay.len >= @max(sac_warmup, s.sac.options.batch)) {
            const issued: f64 = z.wgpu.nowMs();
            for (0..s.sac_batch) |_| {
                sacUpdate(s);
            }
            const per_update: f32 = @floatCast((z.wgpu.nowMs() - issued) / float(s.sac_batch));
            s.sac_submit_ms += (per_update - s.sac_submit_ms) * 0.2;
            s.sac_wait = s.sac_pipe.readGeneration().submitted;
            s.sac_taken = false;
            s.sac_issued_ms = issued;
            if (on_time) {
                s.sac_batch = @min(sac_batch_max, s.sac_batch + 1);
            }
        }
    } else {
        s.busy_window += 1;
    }
    // At least one tick a frame, then the budget (see runPpo).
    const start: f64 = z.wgpu.nowMs();
    sacTick(s);
    while (z.wgpu.nowMs() - start < s.learner_budget_ms) {
        sacTick(s);
    }
    s.window_time += delta_time;
    if (s.window_time >= 1.0) {
        s.samples_per_second = float(s.window_samples) / s.window_time;
        s.sac_updates_per_second = float(s.sac_updates_window) / s.window_time;
        s.gpu_busy_frames = s.busy_window;
        s.window_time = 0;
        s.window_samples = 0;
        s.sac_updates_window = 0;
        s.busy_window = 0;
    }
}

/// One SuperTrack step for every cartpole: act (the CPU's copy of the policy, with its noise),
/// hold the action for `st_frame_skip` physics steps, remember the transition in that cartpole's
/// ring. A push starts a new segment (the world model never sees across one), as do resets.
fn stTick(s: *State) void {
    const random: std.Random = s.rng.random();
    for (0..n_envs) |e| {
        const d: *rbt.Data = &s.envs[e];
        if (s.st_steps[e] > 0 and s.st_steps[e] % st_push_every == 0) {
            d.vel[pole_hinge] += st_push_size * (2.0 * random.float(f32) - 1.0);
            s.st_segments[e] = s.st_next_segment;
            s.st_next_segment += 1;
        }
        const state: st_mod.State4 = observe(d);
        const action: f32 = s.st_host.act(state, true);
        s.st_host.remember(e, state, action, s.st_segments[e]);
        d.ctrl[0] = action;
        var failed: bool = false;
        for (0..st_frame_skip) |_| {
            rbt.step(&s.model, d);
            const angle: f32 = d.pos[pole_hinge];
            failed = failed or !isFinite(angle) or @abs(angle) > fail_angle or @abs(d.pos[cart_slide]) > fail_cart;
        }
        s.st_steps[e] += 1;
        if (failed or s.st_steps[e] >= st_cap) {
            recordSurvival(s, s.st_steps[e] * st_frame_skip);
            resetEnv(s, e);
            s.st_steps[e] = 0;
            s.st_segments[e] = s.st_next_segment;
            s.st_next_segment += 1;
        }
    }
    s.total_samples += n_envs;
    s.window_samples += n_envs;
}

/// SuperTrack's share of the frame, budgeted as the others: the CPU collects within the steered
/// budget (at least one tick); a training iteration - the world step and the policy step, FUSED,
/// 8 dispatches in two submissions - goes to the GPU only once the last is back.
fn runSuperTrack(s: *State, delta_time: f32) void {
    const frame_ms: f32 = delta_time * 1000.0;
    if (frame_ms > frame_target_ms * 1.25) {
        s.learner_budget_ms = @max(cpu_budget_min_ms, s.learner_budget_ms * 0.7);
    } else if (frame_ms < frame_target_ms * 1.1) {
        s.learner_budget_ms = @min(cpu_budget_max_ms, s.learner_budget_ms + 0.1);
    }
    // Poll first: the readback only advances inside it; its weights become the acting policy.
    if (s.st_kit.readParams()) |weights| {
        s.st_host.loadPolicy(weights, s.st_kit.pol);
    }
    const generation: z.Compute(zn_mlp).Generation = s.st_pipe.readGeneration();
    if (generation.mirrored >= s.st_wait) {
        if (!s.st_taken) {
            const trip: f32 = @floatCast(z.wgpu.nowMs() - s.st_issued_ms);
            s.st_round_trip_ms += (trip - s.st_round_trip_ms) * 0.2;
            s.synced += 1;
            s.st_taken = true;
        }
        if (s.st_host.sampleWorldBatch() and s.st_host.samplePolicyBatch()) {
            const issued: f64 = z.wgpu.nowMs();
            s.st_kit.trainWorldFused(s.st_host.stage_states, s.st_host.stage_forces);
            s.st_kit.trainPolicyFused(s.st_host.stage_starts, s.st_host.stage_noise);
            const spent: f32 = @floatCast(z.wgpu.nowMs() - issued);
            s.st_submit_ms += (spent - s.st_submit_ms) * 0.2;
            s.st_wait = s.st_pipe.readGeneration().submitted;
            s.st_taken = false;
            s.st_issued_ms = issued;
            s.st_iterations += 1;
        }
    } else {
        s.busy_window += 1;
    }
    const start: f64 = z.wgpu.nowMs();
    stTick(s);
    while (z.wgpu.nowMs() - start < s.learner_budget_ms) {
        stTick(s);
    }
    s.window_time += delta_time;
    if (s.window_time >= 1.0) {
        s.samples_per_second = float(s.window_samples) / s.window_time;
        s.gpu_busy_frames = s.busy_window;
        s.window_time = 0;
        s.window_samples = 0;
        s.busy_window = 0;
    }
}

fn meanSurvival(s: *const State) f32 {
    if (s.survival_len == 0) {
        return 0;
    }
    var sum: u32 = 0;
    for (s.survival[0..s.survival_len]) |v| {
        sum += v;
    }
    return float(sum) / float(s.survival_len);
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    // 1. PLAN — bounded, every frame, whether or not the physics advances.
    planWithinFrame(s, f.time.delta_time);
    switch (s.kind) {
        .ppo => runPpo(s, f.time.delta_time),
        .sac => runSac(s, f.time.delta_time),
        .supertrack => runSuperTrack(s, f.time.delta_time),
    }

    // 2. ACT — the simulation runs on its own clock, not the display's.
    //
    // ★ WHILE `warming`, THE ROBOT DOES NOT MOVE. A cold plan is nonsense for its first few
    // iterations, and applying it would flail the cart around for a quarter of a second before
    // the optimiser found anything. Holding still until the first solve converges makes the
    // ghost trajectory readable and the start honest: you are watching it think, then act.
    if (s.running and !s.warming) {
        s.accumulator += @min(f.time.delta_time, 0.1);
        while (s.accumulator >= sim_timestep) : (s.accumulator -= sim_timestep) {
            // ★ `feedbackControl` RATHER THAN `plan.ctrl[0]`, and the difference is the whole
            // reason MPC survives a slow solver. The plan in hand was linearised about a state
            // the robot has since left — up to two sim steps ago, because physics runs at 100 Hz
            // and planning at the display rate. `K₀·δx` is the backward pass's own answer to
            // being somewhere else.
            mpc.feedbackControl(&s.model, &s.data, &s.plan, s.applied);
            @memcpy(s.data.ctrl, s.applied);
            rbt.step(&s.model, &s.data);
            // ★★ SHIFT AFTER STEPPING, NOT BEFORE. The plan is indexed from "now"; once the
            // robot has advanced a tick, knot 1 is the new now. Shifting before the step
            // applies knot 1's control to knot 0's state — off by one, every tick, compounding.
            mpc.shift(&s.plan);
        }
    }

    z.clearViewport(f, bg);
    const aspect: f32 = f.window.widthf() / @max(1.0, f.window.heightf());
    // ★ FRAME THE RAIL, NOT THE CART. The plan spans the full 4.8 m of track and the ghost
    // trajectory is the thing worth seeing; a distance tuned to the robot alone crops it.
    s.cam.distance = clamp(5.2 / @max(0.35, aspect), 4.0, 11.0);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.2, .max_distance = 9.0 });
    z.beginMode3D(gl, cam);
    drawScene(s, gl);
    drawPpo(s, gl);
    z.endMode3D(gl);
}

fn drawScene(s: *State, gl: *z.WgpuGl) void {
    // The rail and its limits.
    s.transform[0] = mulMat(translation(0, -0.06, 0), scaling(2 * rail_limit, 0.01, 0.06));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, rail_col);
    inline for (.{ -rail_limit, rail_limit }) |edge| {
        s.transform[0] = mulMat(translation(edge, 0.0, 0), scaling(0.02, 0.12, 0.08));
        z.drawMeshInstanced(gl, &s.cube, &s.transform, limit_col);
    }

    // ── ★ THE PLAN, DRAWN AS GHOSTS. This is the demo's actual subject: the optimiser's
    // intention, one faint pole per planned knot, sharpening as it converges. Every fourth
    // knot, because sixty overlapping poles is a smear rather than a trajectory.
    const ns: u32 = s.plan.nstate;
    var knot: usize = 0;
    while (knot <= s.plan.horizon) : (knot += 4) {
        const px: f32 = s.plan.states[knot * ns + cart_slide];
        const pa: f32 = s.plan.states[knot * ns + pole_hinge];
        drawPole(s, gl, px, pa, 0.02, ghost_col);
    }

    // The robot itself, on top.
    const x: f32 = s.data.pos[cart_slide];
    const angle: f32 = s.data.pos[pole_hinge];
    s.transform[0] = mulMat(translation(x, 0, 0), scaling(0.2, 0.1, 0.1));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, cart_col);
    drawPole(s, gl, x, angle, 0.035, pole_col);
}

/// One pole, drawn from its pivot rather than centred on it — the cylinder mesh spans [0, h]
/// along Y, so rotating about the cart's origin puts the pivot where the hinge is.
fn drawPole(
    s: *State,
    gl: *z.WgpuGl,
    x: f32,
    angle: f32,
    thickness: f32,
    colour: Color,
) void {
    drawPoleAt(s, gl, x, 0, angle, thickness, colour);
}

fn drawPoleAt(
    s: *State,
    gl: *z.WgpuGl,
    x: f32,
    depth: f32,
    angle: f32,
    thickness: f32,
    colour: Color,
) void {
    s.transform[0] = mulMat(
        mulMat(translation(x, 0, depth), rotationZ(angle)),
        scaling(thickness, 0.6, thickness),
    );
    z.drawMeshInstanced(gl, &s.cylinder, &s.transform, colour);
}

/// PPO's copy 0, on its own rail behind MPC's.
fn drawPpo(s: *State, gl: *z.WgpuGl) void {
    s.transform[0] = mulMat(translation(0, -0.06, ppo_depth), scaling(2 * rail_limit, 0.01, 0.06));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, rail_col);
    const d: *const rbt.Data = &s.envs[0];
    const x: f32 = d.pos[cart_slide];
    s.transform[0] = mulMat(translation(x, 0, ppo_depth), scaling(0.2, 0.1, 0.1));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ppo_col);
    drawPoleAt(s, gl, x, ppo_depth, d.pos[pole_hinge], 0.035, pole_col);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(440.0, viewport_w * 0.34);
    const font_size: f32 = u.scaleToViewport(panel_w, if (narrow) 30.0 else 22.0);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, @min(520.0, viewport_h * 0.72) }, .{});
    if (u.window("cartpole: PPO (GPU) vs MPC (CPU)", .{})) |window| {
        defer window.close();

        switch (s.kind) {
            .ppo => {
                u.text("PPO - behind, pink: learning", .{});
                u.text("  iteration {d}   samples {d}", .{ s.iterations, s.total_samples });
                u.text("  {d:.0} samples/s, 16 cartpoles on the CPU", .{s.samples_per_second});
                u.text("  survival, last 20: {d:.0} of 500 steps", .{meanSurvival(s)});
                if (s.training) |_| {
                    u.text("  GPU: epoch {d} of {d}, minibatch {d}", .{ s.train_epoch + 1, epochs, s.train_batch + 1 });
                } else {
                    u.text("  GPU: waiting for a full rollout", .{});
                }
                u.text("  budget: CPU {d:.1} ms, GPU {d} minibatches a batch", .{ s.learner_budget_ms, s.gpu_batches });
            },
            .supertrack => {
                u.text("SuperTrack - behind, pink: NO reward, no critic", .{});
                u.text("  iterations {d}, steps {d}", .{ s.st_iterations, s.total_samples });
                u.text("  survival, last 20: {d:.0} of 500 steps (pushed)", .{meanSurvival(s)});
                u.text("  an iteration: {d:.2} ms to submit (8 dispatches)", .{s.st_submit_ms});
                u.text("  round trip {d:.1} ms", .{s.st_round_trip_ms});
                u.text("  budget: CPU {d:.1} ms", .{s.learner_budget_ms});
            },
            .sac => {
                u.text("SAC - behind, pink: learning", .{});
                u.text("  updates {d} ({d:.0}/s), steps {d}", .{
                    s.sac_updates,
                    s.sac_updates_per_second,
                    s.total_samples,
                });
                u.text("  survival, last 20: {d:.0} of 500 steps", .{meanSurvival(s)});
                u.text("  an update: {d:.2} ms to submit (CPU)", .{s.sac_submit_ms});
                u.text("  a batch of {d}: {d:.1} ms round trip", .{ s.sac_batch, s.sac_round_trip_ms });
                u.text("  budget: CPU {d:.1} ms", .{s.learner_budget_ms});
            },
        }
        u.text("  weights back from the GPU {d} times", .{s.synced});
        u.text("  GPU still busy {d} frames in the last second", .{s.gpu_busy_frames});
        const next_label: []const u8 = switch (s.kind) {
            .ppo => "switch the learner to SAC",
            .sac => "switch the learner to SuperTrack",
            .supertrack => "switch the learner to PPO",
        };
        if (u.button(next_label, .{})) {
            switchLearner(s);
        }
        u.separator();
        u.text("MPC - in front: planning", .{});

        const angle: f32 = s.data.pos[pole_hinge];
        u.text("pole {d:>7.3} rad   cart {d:>6.2} m", .{ angle, s.data.pos[cart_slide] });
        u.text("motor {d:>6.2}  (limit +-1)", .{s.applied[0]});
        u.separator();

        // ★ THE BUDGET IS SHOWN, NOT SET. It is what the device turned out to afford — a
        // number worth seeing precisely because a phone and a desktop differ by more than 10x,
        // and because it is the reason the frame rate holds.
        u.text("frame {d:.1} ms ({d:.0} fps), planning {d:.0} iters/frame", .{
            s.frame_ms,
            1000.0 / @max(s.frame_ms, 1.0),
            s.budget,
        });
        u.text("MPC's share {d:.1} ms ({d:.2} ms an iteration)", .{ s.mpc_budget_ms, s.ms_per_iteration });

        // ── ★ PROGRESS, NOT A SPINNER. "planning..." with nothing moving is
        // indistinguishable from a hang; a count against a target and a falling cost are not.
        if (s.warming) {
            u.text("warming up {d}/{d} iterations", .{ s.plan_iterations, warmup_iterations });
            const done: f32 = @floatFromInt(s.plan_iterations);
            const target: f32 = @floatFromInt(warmup_iterations);
            u.progressBar(done / target, vec2(panel_w - font_size * 2.0, font_size), "");
        } else {
            u.text("planning live, {d} iters on this plan", .{s.plan_iterations});
        }
        u.text("cost {d:.1}  (started {d:.1})", .{ s.last_cost, s.first_cost });

        // ★ THE COST CURVE IS THE EVIDENCE. A number that is falling tells you to wait; a
        // number that has flattened tells you it is done and the rest is the robot's problem.
        if (s.cost_history_len > 2) {
            var top: f32 = 0;
            for (s.cost_history[0..s.cost_history_len]) |c| {
                top = @max(top, c);
            }
            u.plotLines("", s.cost_history[0..s.cost_history_len], .{
                .min = 0,
                .max = @max(top, 1.0),
                .width = panel_w - font_size * 2.0,
                .height = font_size * 3.5,
                .overlay = "plan cost",
            });
        }
        u.separator();

        // ★ AND `run` IS AN OVERRIDE, NOT A SUGGESTION. Ticking it while still warming starts
        // the robot on whatever plan exists — which is the honest thing to offer someone who
        // would rather watch it fail than watch it wait.
        if (u.checkbox("run (skips the warm-up)", &s.running)) {
            if (s.running) {
                s.warming = false;
            }
        }
        if (u.button("swing up (start hanging)", .{})) {
            reset(s, pi - 0.15);
        }
        if (u.button("balance (start upright)", .{})) {
            reset(s, 0.15);
        }
        if (u.button("shove the pole", .{})) {
            // A disturbance the plan did not see coming, which is what the feedback gain is
            // for. Big enough to be alarming, small enough to be recoverable.
            s.data.vel[pole_hinge] += 3.5;
        }
    }
    return captured;
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - cartpole: PPO on the GPU vs MPC on the CPU",
            .width = 900,
            .height = 660,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
