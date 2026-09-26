//! humanoid — MuJoCo's own humanoid, standing on its own two feet.
//!
//! ── ★ WHY THIS IS THE HARD ONE ──
//!
//! A quadruped standing is nearly a table. This is an **inverted pendulum on two small feet**:
//! 1.28 m tall, 40.8 kg, 27 degrees of freedom, held up by ankle torque alone. Every joint has
//! to be actively driven — there is no pose it simply rests in.
//!
//! ── ★★ THE THING TO TRY: DRAG `kp` ──
//!
//! The band that works is narrow, and both edges fail in different ways:
//!
//!   * **too soft** (kp ~100) — it folds under its own weight and sits down;
//!   * **kp 400** — it stands, drifting 4.5 mm over ten seconds;
//!   * **too stiff** (kp ~1000) — the controller outruns the timestep and throws the robot.
//!
//! The stiff-end failure looks like a physics explosion and is not one: it is a controller
//! interacting with a fixed timestep, which is worth seeing precisely because it is so easy to
//! misread.
//!
//! **Shove** it, and pick a keyframe — the model ships four, including standing on one leg.

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
const zp = z.zimrphysics;
const mjcf = z.mjcf;
const rmj = z.robot_mjcf;
const bridge_mod = z.robot_physics;
const ctl = z.robot_control;
const mpc = z.robot_mpc;
const clamp = zm.clamp;

/// ── ★★★ A CAPSULE'S SEGMENT RUNS ALONG LOCAL **Y** IN ZIMR, NOT Z ──
///
/// `GeomShape` says so in one line — "zimr's capsule convention, not MuJoCo's" — and every foot
/// calculation here used Z. The endpoints were therefore perpendicular to the real sole, which
/// is why the sole appeared to be raked 5.5 degrees even at `qpos0` (where this robot stands, so
/// it cannot be), why the built pose looked tilted 13.2 degrees, and why fitting a plane through
/// those points rotated the body 45 degrees.
///
/// **Three turns of geometry findings were artefacts of this one line.** The tell was sitting in
/// the very first measurement: a flat-footed robot at its own standing pose reported a 2 cm
/// spread across its sole, and that is impossible.
const capsule_axis: Vec = vec(0, 1, 0);
const atan2Rad = zm.atan2Rad;
const dot3 = zm.dot3;
const length3 = zm.length3;
const cross = zm.cross;
const pi = zm.pi;
const Color = zm.Color;

const Vec = zm.Vec;
const Mat = zm.Mat;
const vec = zm.vec;
const normalize3 = zm.normalize3;
const splat = zm.splat;
const float = zm.float;
const ui = z.ui;
const Camera3D = zm.Camera3D;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const quatToMat = zm.quatToMat;
const identity = zm.identity;

/// The Go1 runs at 500 Hz in Menagerie, and its contacts want it.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const timestep: f32 = 1.0 / 500.0;

/// How many projectiles the scene carries.
///
/// ── ★★ A FIXED POOL, RECYCLED, RATHER THAN SPAWNED ON DEMAND ──
///
/// A ball has to be a body in the ROBOT'S OWN TREE to hit it properly (§4k) — that is the
/// whole point of the unified tree, and it is what makes the impact push back on the legs
/// with the right mass. But a tree is built once: adding a body means rebuilding the model,
/// which throws away the robot's state mid-flight.
///
/// So the balls exist from the start, parked below the floor where nothing can reach them,
/// and a throw teleports one into place with a velocity. Recycling the oldest means the
/// scene never grows and a rapid-fire user cannot exhaust it.
const ball_count: usize = 6;
const ball_radius: f32 = 0.045;

const ball_names = [_][]const u8{ "ball0", "ball1", "ball2", "ball3", "ball4", "ball5" };
const ball_col: Color = .{ .r = 220, .g = 110, .b = 70, .a = 255 };

/// Where an unthrown ball waits: far below the floor, spread out so two never overlap.
///
/// ★ THEY ARE STILL SIMULATED DOWN THERE, and that is fine — nothing is near them, so they
/// contribute no contacts and cost only their six DOFs in the mass matrix. Parking beats
/// deleting because a tree cannot gain a body without being rebuilt, and rebuilding mid-throw
/// would discard the robot's state.
/// Where an unthrown ball waits.
///
/// ── ★★★ ON THE FLOOR, NOT UNDER IT ──
///
/// This parked them at z = −2.0, below the floor, on the reasoning that nothing could reach
/// them there. Nothing could — and **they fell forever**, accelerating into empty space and
/// accumulating kinetic energy without bound. Six balls in permanent free-fall put **17 000 J**
/// into a readout that was supposed to describe a humanoid lying still, and the number was
/// identical at every controller gain, which is what gave it away.
///
/// ★ A DEMO MUST NOT CONTAIN ANYTHING ACCELERATING TO INFINITY, however far offscreen. Resting
/// on the floor costs the same nothing and stays finite.
fn parkedBall(i: usize) Vec {
    return vec(-3.0 - float(i) * 0.3, 0, ball_radius);
}

const bg: Color = .{ .r = 18, .g = 14, .b = 16, .a = 255 };
const trunk_col: Color = .{ .r = 130, .g = 128, .b = 132, .a = 255 };
const link_col: Color = .{ .r = 90, .g = 205, .b = 190, .a = 255 };
const goal_reached_col: Color = .{ .r = 120, .g = 230, .b = 140, .a = 255 };
const goal_straining_col: Color = .{ .r = 240, .g = 150, .b = 90, .a = 255 };
const contact_col: Color = .{ .r = 240, .g = 200, .b = 60, .a = 255 };

const State = struct {
    gpa: Allocator,
    doc: z.codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    data: rbt.Data,
    world: zp.World,
    bridge: bridge_mod.Bridge,
    cam: z.OrbitCamera,
    actuation: ctl.Actuation,
    ik_scratch: []Vec,
    /// Where the right hand is being sent, and where the CM must stay.
    ik_goal: Vec,
    com_goal: [2]f32,
    ik_on: bool,
    hold_com: bool,
    ik_error: f32,
    com_error: f32,
    hand: u32,
    /// What the controller is currently asked to hold, for the panel.
    pose_label: []const u8,
    ui_host: z.UiHost,
    font: z.Font,
    /// The pose being held — a copy of the `home` keyframe's `qpos`.
    home: []f32,
    /// Servo gains, live.
    kp: f32,
    kv: f32,
    max_torque: f32,
    /// Which free body the next throw will use, cycling through `ball_count`.
    next_ball: usize,
    /// Set by the panel, consumed by `update` once the camera is known.
    want_throw: bool,
    /// Meshes for the three geom shapes the Go1 actually uses.
    cylinder: z.Mesh,
    sphere: z.Mesh,
    cube: z.Mesh,
    transform: [1]Mat,
    accumulator: f32,
    physics_on: bool,
    /// Ragdoll: no controller at all, every joint free.
    limp: bool,
    /// Balance mode: the planner chooses the centre of pressure and the ankles realise it.
    balance_on: bool,
    balance_plan: mpc.BalancePlan,
    /// The pose servo with the ankles removed — they are driven by the pressure command.
    balance_hold: ctl.Actuation,
    ankle_dof: [2]u32,
    /// The roll ankle for each foot — `ankle_x`, the second joint the foot carries.
    ankle_roll_dof: [2]u32,
    ankle_foot: [2]u32,
    ankle_damping: f32,
    /// How much angular momentum per second the planner may spend. Zero is the ankle strategy
    /// alone — no arms, nothing to watch.
    momentum_rate: f32,
    /// Which dofs are the flywheel: arms and abdomen.
    limb_dof: []bool,
    mom_lin: []Vec,
    mom_ang: []Vec,
    mom_s1: []Vec,
    mom_s2: []Vec,
    /// How far the limbs have swung from their held pose. Drawing and readout only.
    limb_swing: f32,
    com_jac: []Vec,
    com_scratch: []Vec,
    want_cop: [2]f32,
    /// Bodies before the first ball — the robot's own.
    robot_body_count: u32,
    /// Whether both ankles were located, so the mode can be offered at all.
    ankles_ready: bool,
    /// How hard the shove button pushes, in m/s of trunk velocity.
    shove_speed: f32,
    /// The direction of the last shove, and the state for picking the next one.
    shove_dir: [2]f32,
    shove_seed: u32,
    /// Scratch for `buildOneLegPose`, and the arm chains it drives.
    pose_scratch: []f32,
    arm_act_right: ctl.Actuation,
    arm_act_left: ctl.Actuation,
    one_leg: bool,
    carried_load: f32,
    /// Peak joint speed over the last second, so the twitch is a NUMBER.
    recent_peak_speed: f32,
    speed_window: f32,
    /// Total kinetic energy, ½·vᵀMv, sampled each frame.
    ///
    /// ── ★★ THE METRIC THAT PEAK VELOCITY WAS NOT ──
    ///
    /// A hand with almost no inertia spinning at 2 rad/s carries nearly no energy, so "the
    /// joints move ten times faster than MuJoCo's" overstated a real problem by measuring the
    /// wrong thing. Energy weights each DOF by what moving it actually costs, and on a limp
    /// body coming to rest it should fall to nothing.
    ///
    /// ★ MuJoCo ON THIS SAME DROP settles to 0.0003 - 0.0007 J. Ours sits around 0.014 - 0.026,
    /// and closing that gap is open work — which is why the figure is on screen rather than in
    /// a note.
    /// How many leading DOFs belong to the humanoid rather than to the loose balls. The
    /// importer lays the robot out first, so this is a prefix.
    robot_dof_count: usize,
    kinetic_energy: f32,
    energy_history: [180]f32,
    energy_len: usize,
    energy_clock: f32,
    peak_force: f32,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.doc = try z.codecs.xml.parse(gpa, @embedFile("humanoid.xml"), null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    // ★ THE PROJECTILES JOIN THE ROBOT'S TREE, which is what makes them able to hit it.
    // A ball in zimrphysics alone would be resolved by a different solver treating the robot
    // as immovable — the exact approximation §4k removed. In the tree, an impact is one
    // constraint between two inertias and the legs feel the real mass.
    var balls: [ball_count]z.robot_scene.FreeBody = undefined;
    for (0..ball_count) |i| {
        balls[i] = .{
            .name = ball_names[i],
            .pos = parkedBall(i),
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = ball_radius } }, .mass = 0.6 }},
        };
    }
    var options: rbt.Options = .{
        // ★ THE SMOKE RUN TRAPS IN `addContactRows` WITH `integerOutOfBounds`, AND IT IS NOT
        // A CAPACITY PROBLEM — raising this to 384 changed nothing, so a failed `@intCast`
        // inside the engine is the fault, not the budget. **Pre-existing**: an old snapshot
        // (zimr1210, from before any of the balance work) traps identically when run unchanged.
        .max_contacts = 128,
        .timestep = timestep,
        // Z-up, to match the model's own frame.
        .gravity = vec(0, 0, -9.81),
    };
    // ★★ BUILT FOR NEWTON SO THE SOLVER CAN BE SWITCHED LIVE. Its working set — an nv x nv
    // Hessian and a row of scratch — is sized once at `Data.init` from this option, so a model
    // built for PGS cannot be switched to Newton later without reallocating. Building the other
    // way round is free: Newton's buffers simply go unread while PGS is selected, and `robot.zig`
    // asserts loudly if this is got backwards rather than writing past the end of an empty slice.
    options.solver.algorithm = .newton;
    s.imported = try rmj.buildScene(gpa, &s.robot, &balls, options);
    s.data = try rbt.Data.init(gpa, &s.imported.model);

    // ★ THE HUMANOID'S DOFs ARE THE ONES BEFORE THE FIRST BALL. `buildScene` appends the loose
    // bodies after the robot, so counting up to the first ball's joint gives the prefix — and
    // reading the model rather than hardcoding 27 keeps it right if the model changes.
    s.robot_dof_count = s.imported.model.nv;
    if (s.imported.bodyIndex(ball_names[0])) |first_ball| {
        const joint: u32 = s.imported.model.body_jnt_adr[first_ball];
        s.robot_dof_count = s.imported.model.jnt_dof_adr[joint];
    }

    s.world = try .init(gpa, 128);
    s.world.gravity = vec(0, 0, -9.81);
    const ground: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(5, 5, 0.5), .convex_radius = 0.01 },
    });
    _ = try s.world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
    });

    // ★ THE DEFAULT POSE IS THE STANDING ONE. Unlike the Go1, whose `home` keyframe is what
    // stands it up, this model's four keyframes are squat / one-legged / prone / supine — all
    // interesting and none of them the pose to hold. `qpos0` is upright.
    rbt.forward(&s.imported.model, &s.data);
    s.bridge = try .init(gpa, &s.world, &s.imported.model, &s.data, 128);
    s.bridge.listen(&s.world);

    s.home = try gpa.dupe(f32, s.data.pos);
    s.actuation = try ctl.Actuation.init(gpa, &s.imported.model);

    // ★ THE GENERATED CYLINDER SPANS z ∈ [0, height], NOT [−h/2, +h/2]. Its parametric
    // surface is `(r·sinθ, r·cosθ, height·u)` with `u ∈ [0,1]`, so a unit cylinder sits
    // entirely ABOVE the origin. Scaling it to a capsule's length therefore offsets every
    // limb by half its own length — legs that float away from their joints. Generating it
    // pre-centred is one number here and saves a translate in every draw.
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 10, 8);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.transform = .{identity()};
    s.cam = z.OrbitCamera.init(vec(0, 0.25, 0), 1.4);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.kp = 400.0;
    s.kv = 10.0;
    s.max_torque = 300.0;
    s.ankle_damping = 8.0;
    // ★ 0.25 m/s BY DEFAULT — just inside what the arms are worth, so the slider opens on the
    // band where the comparison means something rather than on one that always falls.
    s.shove_speed = 0.25;
    s.shove_dir = .{ 1, 0 };
    s.shove_seed = 0x2545f491;
    s.one_leg = false;
    s.pose_scratch = try gpa.alloc(f32, s.imported.model.nq);
    s.arm_act_right = if (s.imported.bodyIndex("hand_right")) |h|
        try ctl.limbActuation(gpa, &s.imported.model, h)
    else
        try ctl.Actuation.init(gpa, &s.imported.model);
    s.arm_act_left = if (s.imported.bodyIndex("hand_left")) |h|
        try ctl.limbActuation(gpa, &s.imported.model, h)
    else
        try ctl.Actuation.init(gpa, &s.imported.model);
    // ★ DERIVED, NOT PICKED. Both arms together carry about **7.7 kg·m²/s** — spin 2.04 plus
    // orbital 1.80 per arm — and reaching that over a ~0.2 s swing needs a rate near 40. The old
    // value of 80 let the planner ask for **16.4**, which is 2.1x what the body owns; the
    // tracker then demanded 55 rad/s of arm velocity, and that is what exploded.
    // ★ DERIVED, NOT PICKED. Both arms together carry about **7.68 kg·m²/s** — spin 2.04 plus
    // orbital 1.80 each — and reaching that over a ~0.2 s swing needs a rate near 40. The value
    // of 80 that exploded let the planner ask for **16.4**, which is 2.1x what the body owns;
    // the tracker then demanded 55 rad/s of arm velocity, and that was the explosion.
    s.momentum_rate = 40.0;
    s.limb_swing = 0;
    s.mom_lin = try gpa.alloc(Vec, s.imported.model.nv);
    s.mom_ang = try gpa.alloc(Vec, s.imported.model.nv);
    s.mom_s1 = try gpa.alloc(Vec, s.imported.model.nv);
    s.mom_s2 = try gpa.alloc(Vec, s.imported.model.nv);
    s.limb_dof = try gpa.alloc(bool, s.imported.model.nv);
    @memset(s.limb_dof, false);
    // ★ AND THE ARMS LEAVE THE POSE SERVO. Holding a joint at an angle while also commanding it
    // a velocity is two controllers fighting: at kp 400 the servo wins and nothing swings, and
    // where it does not, they oscillate. Done further below, once the limb set is known.
    {
        // ★ ARMS AND ABDOMEN — what a person actually windmills and banks with, and where the
        // angular momentum the ground supplies has to GO. If the trunk takes it instead, the
        // trunk rotates, which is falling over.
        const model: *const rbt.Model = &s.imported.model;
        // ── ★★★ ARMS ONLY. THE WAIST AND PELVIS ARE NOT A FLYWHEEL ──
        //
        // Measured from the mass matrix, those joints carry inertias of **8.72 and 5.99** — they
        // are the whole upper body. Driving them to hold momentum moves half the robot's mass,
        // which moves the centre of mass, which the pressure controller is simultaneously trying
        // to regulate. Two controllers fighting over one variable.
        //
        // The arms are 0.14 to 0.19 and sit far out, so they carry momentum without meaningfully
        // moving the mass. That is exactly what a flywheel is for.
        const limb_names = [_][]const u8{
            "upper_arm_right", "lower_arm_right", "hand_right",
            "upper_arm_left",  "lower_arm_left",  "hand_left",
        };
        for (0..model.njnt) |j| {
            const body: u32 = model.jnt_body[j];
            var is_limb: bool = false;
            for (limb_names) |name| {
                if (s.imported.bodyIndex(name)) |index| {
                    if (index == body) {
                        is_limb = true;
                    }
                }
            }
            if (!is_limb) {
                continue;
            }
            for (0..model.jnt_type[j].dofCount()) |k| {
                const dof: u32 = model.jnt_dof_adr[j] + @as(u32, @intCast(k));
                if (dof < model.nv) {
                    s.limb_dof[dof] = true;
                    // ★ OUT OF THE POSE SERVO. A joint cannot be held at an angle and commanded
                    // a velocity by two controllers at once — at kp 400 the servo wins and
                    // nothing swings.
                    // ★★★ NOT HERE. `balance_hold` is not allocated until further down, so this
                    // wrote through an undefined slice — a wasm trap, `memory access out of
                    // bounds`, and the fault I spent a turn attributing to the limb tracking.
                    // The arms are removed from the servo in the pass below instead, after the
                    // actuation set exists.
                }
            }
        }
    }
    s.want_cop = .{ 0, 0 };
    s.carried_load = 0;
    s.balance_plan = try mpc.BalancePlan.init(gpa, 40);
    @memset(s.balance_plan.ctrl, 0);
    @memset(s.balance_plan.reference, 0);
    s.com_jac = try gpa.alloc(Vec, s.imported.model.nv);
    s.com_scratch = try gpa.alloc(Vec, s.imported.model.nv);
    s.balance_hold = try ctl.Actuation.init(gpa, &s.imported.model);
    {
        // ★ INITIALISED BEFORE THE LOOKUP, NOT BY IT. A `continue` on a missing body leaves
        // these `undefined`, and an undefined dof index is a wasm trap rather than a wrong
        // answer — which is a much worse way to find out the name changed.
        s.ankle_foot = .{ 0, 0 };
        s.ankle_dof = .{ 0, 0 };
        s.ankle_roll_dof = .{ 0, 0 };
        s.balance_on = false;
        const model: *const rbt.Model = &s.imported.model;
        const feet = [2][]const u8{ "foot_left", "foot_right" };
        var found: u32 = 0;
        for (feet, 0..) |name, i| {
            const foot: u32 = s.imported.bodyIndex(name) orelse continue;
            if (model.body_jnt_num[foot] == 0) {
                continue;
            }
            const dof: u32 = model.jnt_dof_adr[model.body_jnt_adr[foot]];
            if (dof >= model.nv) {
                continue;
            }
            s.ankle_foot[i] = foot;
            s.ankle_dof[i] = dof;
            s.balance_hold.powered[dof] = false;
            if (model.body_jnt_num[foot] > 1) {
                const roll: u32 = model.jnt_dof_adr[model.body_jnt_adr[foot] + 1];
                if (roll < model.nv) {
                    s.ankle_roll_dof[i] = roll;
                    // ★ AND IT STAYS IN THE POSE SERVO. It is only taken out when the one-leg
                    // pose is selected, below — a joint that is neither servo'd nor commanded is
                    // limp, and a limp ankle collapses under a standing robot.
                }
            }
            found += 1;
        }
        // ★ AND THE ARMS COME OUT OF THE SERVO HERE, once `balance_hold` exists. A joint cannot
        // be held at an angle and commanded a velocity by two controllers at once — at kp 400
        // the servo wins and nothing swings.
        for (0..model.nv) |v| {
            if (s.limb_dof[v]) {
                s.balance_hold.powered[v] = false;
            }
        }
        // Only offer the mode if both ankles were actually found.
        // ★★★ OFF BY DEFAULT, AND THAT IS NOT TIMIDITY. Enabled, this traps inside
        // `addContactRows` — the contact rows overflow, which means the robot is flailing hard
        // enough to pile up contacts. The headless probe with the SAME control law stands and
        // survives every push (torso 1.2810, drift 0.016 m), so the law is right and something
        // about this scene is not: the balls share the model, the scene has its own solver
        // seam, and the example steps `zp` and `rbt` in an order the probe does not.
        //
        // Shipping it default-on would mean shipping a demo that crashes. Shipping it off
        // leaves the example exactly as it was and the work visible.
        s.balance_on = false;
        s.ankles_ready = found == 2;
        s.robot_body_count = model.nbody;
        if (s.imported.bodyIndex(ball_names[0])) |first_ball| {
            s.robot_body_count = first_ball;
        }
    }
    s.ik_scratch = try gpa.alloc(Vec, ctl.BalancedIk.scratchSize(&s.imported.model));
    s.hand = s.imported.bodyIndex("hand_right") orelse 1;
    // Start the goal where the hand already is, so switching IK on changes nothing until a
    // slider moves — a target that snaps the arm on activation reads as a bug.
    s.ik_goal = s.data.body_xpos[s.hand];
    const rest_com: Vec = s.data.subtree_com[rbt.world_body];
    s.com_goal = .{ rest_com[0], rest_com[1] };
    s.ik_on = false;
    s.hold_com = true;
    s.ik_error = 0;
    s.com_error = 0;
    s.pose_label = "standing";
    s.next_ball = 0;
    s.want_throw = false;
    s.accumulator = 0;
    s.physics_on = true;
    s.limp = false;
    s.recent_peak_speed = 0;
    s.speed_window = 0;
    s.kinetic_energy = 0;
    s.energy_len = 0;
    s.energy_clock = 0;
    s.peak_force = 0;
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
    gpa.free(s.ik_scratch);
    s.balance_hold.deinit();
    gpa.free(s.com_scratch);
    gpa.free(s.com_jac);
    s.balance_plan.deinit();
    s.arm_act_left.deinit();
    s.arm_act_right.deinit();
    gpa.free(s.pose_scratch);
    gpa.free(s.limb_dof);
    gpa.free(s.mom_s2);
    gpa.free(s.mom_s1);
    gpa.free(s.mom_ang);
    gpa.free(s.mom_lin);
    s.actuation.deinit();
    gpa.free(s.home);
    s.bridge.deinit(&s.world);
    s.world.deinit(gpa);
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
}

/// Hold the standing pose.
///
/// ── ★ THIS IS NOW THREE LINES, AND THAT IS THE POINT ──
///
/// Every demo used to paste its own PD loop, and each one had to remember that gravity
/// compensation belongs only on ACTUATED degrees of freedom — a rule that produced crates
/// hanging in mid-air and a Go1 rising at a steady 2.4 m/s before it was written down.
/// `ctl.Actuation` computes that mask once from the model's topology, so the question is
/// asked in one place instead of at every call site.
/// Put the robot back, either at its standing pose or at one of the model's keyframes.
///
/// ★ THE HELD TARGET MOVES WITH IT. Teleporting the body while `home` still describes the old
/// pose would have the controller immediately drag it back — the robot would flick to the
/// keyframe and snap away again, which reads as the keyframe being broken.
fn restorePose(s: *State, keyframe: ?u32) void {
    // ★★ PICKING A POSE TURNS REACHING OFF, because otherwise the pose lasts one frame.
    //
    // With IK on, `update` recomputes `home` from the solve EVERY frame. A keyframe press
    // would set `home`, and the next frame would overwrite it — the button appearing to do
    // nothing at all, with no error and nothing to see. Two things that both own `home` have
    // to take turns.
    s.ik_on = false;
    if (keyframe) |k| {
        // ★ THE RESULT IS CHECKED. Discarding it is how every pose button came to do nothing
        // silently: the keyframe was 28 numbers, the model 70 once the projectiles joined the
        // tree, and `applyKeyframe` refused. The label still said "holding: squat", which is
        // worse than no feedback at all.
        s.one_leg = false;
        if (!rmj.applyKeyframe(&s.imported.model, &s.data, s.robot.keyframes[k])) {
            s.pose_label = "keyframe REFUSED";
            return;
        }
    } else if (s.one_leg) {
        buildOneLegPose(s);
    } else {
        @memcpy(s.data.pos, s.imported.model.qpos0);
    }
    @memset(s.data.vel, 0);
    s.data.stage = .stale;
    rbt.forward(&s.imported.model, &s.data);
    @memcpy(s.home, s.data.pos);
    s.data.forgetWarmStart();
    s.peak_force = 0;

    // ── ★★★ THE CONTROLLER HAS STATE TOO, AND IT WAS SURVIVING EVERY RESET ──
    //
    // `solveBalance` WARM-STARTS from `plan.ctrl` — that array is the iterate, not an output.
    // After a fall it holds whatever extreme pressure and momentum commands the planner reached
    // while going over, and resetting only the POSE left them there. The first tick on the
    // fresh pose then applied them.
    //
    // That is both reported symptoms at once: "reset does not really reset", because the
    // controller did not; and "it often explodes", because a stale extreme plan met an upright
    // robot. Everything the controller accumulates is cleared here.
    @memset(s.balance_plan.ctrl, 0);
    @memset(s.balance_plan.reference, 0);
    @memset(s.data.applied_force, 0);
    s.want_cop = .{ 0, 0 };
    s.carried_load = 0;
    s.limb_swing = 0;
    // ★ THE BRIDGE MUST BE TOLD. A keyframe write is a teleport, and a swept contact drawn
    // across the gap finds the floor and fires the robot away — see `Bridge.teleported`.
    s.bridge.teleported();
    s.pose_label = if (keyframe) |k| s.robot.keyframes[k].name else if (s.one_leg) "right leg (built)" else "standing";
}

fn control(s: *State) void {
    const hold: ctl.PoseHold = .{
        .target = s.home,
        .kp = s.kp,
        .kv = s.kv,
        // ★ THE CEILING IS WHAT MAKES THE `kp` SLIDER MEAN ANYTHING. Without it a PD law
        // produces whatever torque the error demands, and every robot is infinitely strong.
        .max_torque = s.max_torque,
    };
    // ★ A RAGDOLL IS THE CONTROLLER NOT RUNNING, not a different model. Every joint is free and
    // the only forces are gravity and contact — which is the hardest thing a contact solver is
    // routinely asked to do, because nothing is holding any joint against being pushed.
    if (s.limp) {
        return;
    }
    if (!s.balance_on) {
        hold.apply(&s.imported.model, &s.data, s.actuation);
        return;
    }

    // ── ★★★ THE PLANNER DRIVES THE ANKLES; THE POSE SERVO KEEPS EVERY OTHER JOINT ──
    //
    // A balancing robot's one real actuator is the centre of pressure: the ankle torque decides
    // where under the foot the ground's push effectively acts, and that is what accelerates the
    // mass. `solveBalance` chooses that point over a horizon with the foot's limits built in,
    // and the ankle simply realises it.
    //
    // ★ THE TORQUE IS `+0.5 · f_z · (p_want − p_ankle)`, AND THE SIGN WAS READ OFF THE
    // CONTROLLER THAT ALREADY WORKED rather than argued from a cross product. Standing under
    // plain `PoseHold` the ankle carries **+7.816 N·m**, and the formula gives **+7.29** —
    // within 7%. Every earlier attempt used the negative and drove the robot over at every
    // magnitude and every gain.
    const m: *const rbt.Model = &s.imported.model;
    hold.apply(m, &s.data, s.balance_hold);

    // ── ★★★ THE ROBOT'S CENTRE OF MASS, NOT THE SCENE'S ──
    //
    // `buildScene` appends the throwable balls to the SAME model, so `subtree_com[world_body]`
    // is the centre of mass of the robot AND every ball — including ones lying on the floor
    // across the room. Feeding that to a balance planner asks it to stand a robot over a point
    // that has nothing to do with the robot, and the ensuing flailing overflowed the contact
    // rows outright.
    var com: Vec = vec(0, 0, 0);
    var com_vel: Vec = vec(0, 0, 0);
    var robot_mass: f32 = 0;
    for (1..s.robot_body_count) |b| {
        const mass: f32 = m.body_mass[b];
        if (mass <= 0) {
            continue;
        }
        com += s.data.body_xipos[b] * splat(mass);
        robot_mass += mass;
    }
    if (robot_mass <= 0) {
        return;
    }
    com *= splat(1.0 / robot_mass);
    ctl.comJacobian(m, &s.data, s.com_jac, s.com_scratch);
    for (0..s.robot_dof_count) |v| {
        com_vel += s.com_jac[v] * splat(s.data.vel[v]);
    }

    var x: [mpc.lipm_state_dim]f32 = @splat(0);
    x[mpc.lipm_com_offset] = com[0];
    x[mpc.lipm_com_offset + 1] = com[1];
    x[mpc.lipm_vel_offset] = com_vel[0];
    x[mpc.lipm_vel_offset + 1] = com_vel[1];
    _ = mpc.solveBalance(
        .{ .mass = robot_mass, .height = @max(0.3, com[2]), .gravity = 9.81 },
        &s.balance_plan,
        &x,
        balanceWeights(),
        .{ .foot_half = .{ 0.09, 0.08 }, .max_momentum_rate = s.momentum_rate },
        0.02,
        2,
    );
    s.want_cop = .{ plan_cop(&s.balance_plan, 0), plan_cop(&s.balance_plan, 1) };

    // ★ THE LOAD IS THE SUM OF ALL FOUR ROWS PER CONTACT. `rows_per_contact` is a pyramid
    // friction basis, not `[normal, tangent, tangent, …]` — row 0 alone reads exactly a FIFTH of
    // the weight, measured, and a command scaled by a fifth cannot hold a robot up.
    var carried: f32 = 0;
    for (0..s.data.contact_count) |c| {
        for (0..rbt.rows_per_contact) |r| {
            carried += s.data.constraint_force[c * rbt.rows_per_contact + r];
        }
    }
    // ── ★★★ THE LOAD IS BOUNDED BY THE ROBOT'S WEIGHT, NOT BY WHAT THE SOLVER REPORTS ──
    //
    // The ankle torque is `f_z · lever`, so it scales directly with this number. During an
    // impact the contact solver legitimately reports several times the weight for a few ticks —
    // and the ankle command then multiplies by that, which drives the joint far harder than
    // anything standing requires. That is a feedback loop with a spike in it.
    //
    // Standing, the load IS the weight; anything above about twice it is a transient the
    // balance controller should not be amplifying.
    carried = clamp(carried, 0.0, 2.0 * robot_mass * 9.81);
    s.carried_load = carried;

    // ── ★★★ THE MOMENTUM COMMAND, TURNED INTO LIMB MOTION ──
    //
    // The planner asks for an angular momentum; the limbs have to carry it.
    // `A_G_limbs · q̇ = L` says which limb velocities do, and the least-norm answer is
    // `q̇ = Aᵀ(A·Aᵀ)⁻¹·L` — a 3×3 solve.
    //
    // ★ VELOCITY, NOT TORQUE, and that distinction is the physics. Internal joint torques cannot
    // change total angular momentum — Newton's third law, and the conservation test in
    // `robot_control.zig` proves it. The limbs are a momentum SINK: the GROUND supplies the
    // momentum through the tangential contact force, and the arms decide whether it lands in
    // them or in the trunk. Asking them to MOVE at the rate that holds it is the honest
    // statement of that job.
    if (s.momentum_rate > 0) {
        // ── ★★★ THE MOMENTUM, NOT THE RATE. THIS WAS A UNITS ERROR ──
        //
        // `ctrl[rate_offset]` is `L̇`, in kg·m²/s². The map `A_G·q̇ = L` wants a MOMENTUM, in
        // kg·m²/s. Feeding one into the other is dimensionally wrong and no scale factor
        // repairs it — the 0.25 that used to sit here was a number picked to make the magnitude
        // look plausible.
        //
        // The plan's STATE carries the momentum it intends to be holding. That is the target.
        // ★ AND THE INDEX IS CHECKED. `states` is `(horizon + 1) × state_dim`; reading knot 1
        // needs at least two knots, which a horizon of 40 has — but an out-of-bounds read here
        // is a wasm trap, not a wrong number, so it is worth the branch.
        const next: usize = mpc.lipm_state_dim;
        if (s.balance_plan.states.len < next + mpc.lipm_state_dim) {
            return;
        }
        const want_x: f32 = s.balance_plan.states[next + mpc.lipm_momentum_offset];
        const want_y: f32 = s.balance_plan.states[next + mpc.lipm_momentum_offset + 1];
        ctl.centroidalMomentum(m, &s.data, s.mom_lin, s.mom_ang, s.mom_s1, s.mom_s2);
        var gram: [9]f32 = @splat(0);
        // ★ `inline` BECAUSE A VECTOR INDEX MUST BE COMPTIME. `mom_ang[v]` is a `Vec`, and
        // indexing it with a runtime loop counter does not compile — the loops over the three
        // momentum axes have to be unrolled.
        inline for (0..3) |a| {
            inline for (0..3) |b| {
                var sum: f32 = 0;
                for (0..m.nv) |v| {
                    if (!s.limb_dof[v]) {
                        continue;
                    }
                    sum += s.mom_ang[v][a] * s.mom_ang[v][b];
                }
                gram[a * 3 + b] = sum;
            }
        }
        const ridge: f32 = 1.0e-4 * (@abs(gram[0]) + @abs(gram[4]) + @abs(gram[8]) + 1.0);
        gram[0] += ridge;
        gram[4] += ridge;
        gram[8] += ridge;
        var lambda: [3]f32 = .{ want_x, want_y, 0 };
        if (ctl.solve3Pub(&gram, &lambda)) {
            for (0..m.nv) |v| {
                if (!s.limb_dof[v]) {
                    continue;
                }
                // ★ CLAMPED TO WHAT AN ARM CAN ACTUALLY DO. Eight rad/s is a fast swing; the
                // unclamped map cheerfully asks for fifty when the plan wants more momentum
                // than the body owns, and a tracker chasing that is the explosion.
                const raw: f32 = lambda[0] * s.mom_ang[v][0] +
                    lambda[1] * s.mom_ang[v][1] + lambda[2] * s.mom_ang[v][2];
                const want_qvel: f32 = clamp(raw, -8.0, 8.0);
                // ★ AND THE GAIN IS BOUNDED BY THE JOINT, NOT CHOSEN. Explicit PD needs roughly
                // `kd·dt/I < 2`; the smallest limb inertia here is **0.068** (forearm), so at
                // 1/500 the ceiling is 68. Twenty leaves real margin.
                //
                // The weak position term stops the arms drifting away for good once the
                // momentum command returns to zero — without it they keep whatever pose the
                // last swing left them in.
                // ★ NO POSTURE TERM. Mapping a velocity dof back to its position index via
                // `dof_jnt` reached out of bounds — and the arms do not need it: when the
                // momentum command returns to zero the velocity target does too, and the
                // damping brings them to rest. A pose pull is a nicety; correctness is not.
                s.data.applied_force[v] += clamp(
                    20.0 * (want_qvel - s.data.vel[v]),
                    -60.0,
                    60.0,
                );
            }
        }
        var swing: f32 = 0;
        for (0..m.nq) |q| {
            swing = @max(swing, @abs(s.data.pos[q] - s.home[q]));
        }
        s.limb_swing = swing;
    }

    // ── ★★★ BOTH ANKLES. LATERAL IS THE HARD DIRECTION ON ONE LEG ──
    //
    // The foot is 0.21 m long and **0.06 m wide**, so sideways there is barely any polygon to
    // move the pressure inside — and only the PITCH ankle was ever driven, leaving that axis
    // completely uncontrolled. Measured on the built one-leg pose: pitch alone gives a tilt of
    // 2.45 rad, both ankles **0.16**. It stops tipping over entirely.
    //
    // ★ THE ROLL SIGN WAS MEASURED, NOT DERIVED: −1 gives 0.156, +1 gives 1.744, zero gives
    // 1.994. Same technique as the pitch ankle, where reading the working controller's torque
    // settled in one print what several turns of cross-product argument had not.
    const share: f32 = if (s.one_leg) 1.0 else 0.5;
    for (s.ankle_dof, s.ankle_roll_dof, s.ankle_foot) |dof, roll_dof, foot| {
        const lever_x: f32 = s.want_cop[0] - s.data.body_xpos[foot][0];
        const lever_y: f32 = s.want_cop[1] - s.data.body_xpos[foot][1];
        s.data.applied_force[dof] = share * carried * lever_x - s.ankle_damping * s.data.vel[dof];
        // ★★★ ROLL ONLY ON ONE LEG. With TWO feet down, the lateral centre of pressure is set by
        // how the load SPLITS BETWEEN THE FEET — a 0.3 m stance width — not by rolling either
        // ankle inside its own 0.06 m sole. Commanding roll there fights a stance that was
        // already fine, and it broke a two-footed stand that had been holding at torso 1.2810
        // across six pushes.
        //
        // On one leg it is the only lateral authority there is, and worth 2.45 rad of tilt.
        if (s.one_leg and roll_dof < m.nv) {
            s.data.applied_force[roll_dof] = -share * carried * lever_y -
                s.ankle_damping * s.data.vel[roll_dof];
        }
    }
}

fn plan_cop(plan: *const mpc.BalancePlan, axis: usize) f32 {
    return plan.ctrl[mpc.lipm_cop_offset + axis];
}

/// Cost weights for the balancing planner, in state order
/// `[com_x, com_y, vel_x, vel_y, momentum_x, momentum_y]`.
fn balanceWeights() mpc.Weights {
    // ★★★ THE MOMENTUM WEIGHT IS THE ONLY BRAKE ON HOW MUCH THE PLANNER SPENDS. Excursion is a
    // STATE limit and `boxQP` bounds controls only, so there is no constraint to write — the
    // cost is the whole mechanism. At 0.02 the planner treated momentum as nearly free and
    // planned 16.4 kg·m²/s, which is 2.1x what two arms can carry. Raising it to 2.0 keeps the
    // plan inside the body: measured, a 0.3 m/s push then peaks at 0.54.
    const state_w = [_]f32{ 400, 400, 40, 40, 2.0, 2.0 };
    const control_w = [_]f32{ 1.0, 1.0, 0.002, 0.002 };
    const terminal_w = [_]f32{ 4000, 4000, 400, 400, 20.0, 20.0 };
    const holder = struct {
        const s = state_w;
        const c = control_w;
        const t = terminal_w;
    };
    return .{ .state = &holder.s, .control = &holder.c, .terminal = &holder.t };
}

/// Throw a ball at the robot, from wherever the camera is looking from.
///
/// ★ AIMED FROM THE CAMERA, so "throw" means what it looks like it means: the ball leaves the
/// viewer's position and travels toward the robot's centre. A fixed launch direction would be
/// unusable the moment the view is orbited, which on a phone is immediately.
fn throwBall(s: *State, cam: Camera3D) void {
    const m: *const rbt.Model = &s.imported.model;
    const body: u32 = s.imported.bodyIndex(ball_names[s.next_ball]) orelse return;
    s.next_ball = (s.next_ball + 1) % ball_count;

    // ── ★★ FROM THE EYE, ALONG THE VIEW — not at a fixed point ──
    //
    // This aimed at `(0, 0, 0.25)` regardless of where the camera was pointing, so every throw
    // curved back toward the robot however you had orbited. That is a fine turret and a poor
    // projectile: you cannot miss with it, and missing is most of what makes throwing things
    // at a robot informative.
    //
    // ★ THE CAMERA IS Y-UP AND THE SIMULATION IS Z-UP. The demo draws through
    // `rotationX(−90°)`, which sends sim `(x, y, z)` to display `(x, z, −y)`; going back is
    // therefore display `(X, Y, Z)` to sim `(X, −Z, Y)`. Both the eye and the direction need
    // it — converting only the position gives a ball that starts in the right place and flies
    // somewhere else entirely.
    const toSim = struct {
        fn go(v: Vec) Vec {
            return vec(v[0], -v[2], v[1]);
        }
    }.go;
    const eye: Vec = toSim(cam.position);
    const aim: Vec = normalize3(toSim(cam.target) - eye);

    // ★ NUDGED FORWARD BY THE BALL'S OWN RADIUS, and no more. Starting exactly at the eye puts
    // the ball on the near plane where it is clipped, so the throw looks like it produced
    // nothing until the ball is already halfway to the robot.
    const from: Vec = eye + aim * splat(ball_radius);

    const j: u32 = m.body_jnt_adr[body];
    const q: u32 = m.jnt_qpos_adr[j];
    const v: u32 = m.jnt_dof_adr[j];
    s.data.pos[q + 0] = from[0];
    s.data.pos[q + 1] = from[1];
    s.data.pos[q + 2] = from[2];
    s.data.pos[q + 3] = 0;
    s.data.pos[q + 4] = 0;
    s.data.pos[q + 5] = 0;
    s.data.pos[q + 6] = 1;
    @memset(s.data.vel[v..][0..6], 0);
    const speed: f32 = 4.5;
    s.data.vel[v + 0] = aim[0] * speed;
    s.data.vel[v + 1] = aim[1] * speed;
    s.data.vel[v + 2] = aim[2] * speed;
    s.data.stage = .stale;
    // ★ The warm start describes contacts that no longer exist for this body — see
    // `Data.forgetWarmStart`. Cheap, and the alternative is an impulse from a different scene.
    s.data.forgetWarmStart();
}

/// Build a stand-on-the-right-leg pose: left leg lifted, arms out at 45 degrees, and the centre
/// of mass placed exactly over the support foot. Writes into `out` (length `nq`).
///
/// ── ★★★ WHY PROCEDURAL RATHER THAN THE SHIPPED KEYFRAME ──
///
/// `stand_on_left_leg` puts the mass **0.040 m** from its foot, so a balance controller opens by
/// fighting an offset instead of at equilibrium. And it keeps the arms at the sides, where the
/// flywheel is worth far less than it could be. Measured on this model:
///
///     arms EXTENDED   15.54 kg·m²/s   -> arrests 0.428 m/s
///     arms folded      7.92 kg·m²/s   -> arrests 0.218 m/s
///
/// **Nearly double**, because the orbital part of the angular momentum goes as `m·r²·ω` and
/// extending the arm takes `r` from about 0.3 m to 0.6. The arms ARE the flywheel, and folded
/// arms throw most of it away.
fn buildOneLegPose(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    const right_foot: u32 = s.imported.bodyIndex("foot_right") orelse return;
    const hand_right: u32 = s.imported.bodyIndex("hand_right") orelse return;
    const hand_left: u32 = s.imported.bodyIndex("hand_left") orelse return;
    const arm_r: u32 = s.imported.bodyIndex("upper_arm_right") orelse return;
    const arm_l: u32 = s.imported.bodyIndex("upper_arm_left") orelse return;
    const root: u32 = m.jnt_qpos_adr[0];

    // ★ LEAVES THE POSE IN `data.pos` RATHER THAN RESTORING. An earlier version saved the
    // current pose into `pose_scratch` and restored on exit — then the caller passed
    // `pose_scratch` as the OUTPUT, so the save buffer and the result were the same array. It
    // happened to work and was one edit away from not. The only caller is `restorePose`, which
    // wants the pose applied anyway.
    @memcpy(s.data.pos, m.qpos0);
    // Lift the left leg clear.
    setJoint(s, "hip_y_left", -0.85);
    setJoint(s, "knee_left", -1.30);
    setJoint(s, "hip_x_left", -0.10);
    s.data.stage = .stale;
    rbt.forward(m, &s.data);

    // ── ★★★ THE STANCE COMES FIRST, THE ARMS LAST ──
    //
    // Levelling rotates the WHOLE robot, so anything placed in world coordinates before it is
    // rotated too. Reaching first left the arms visibly lopsided — right hand at z 1.166, left
    // at 1.677, from a step meant to be symmetric. Settle the stance, then reach: the targets
    // are relative to the shoulders, so they land right the first time.
    // ★ AND A 2x2 NEWTON PUTS THE MASS OVER THE FOOT. Translating the root moves foot and mass
    // together, so their offset is set by the joints alone — `hip_x` swings it sideways,
    // `hip_y` fore-and-aft. Measured, this converges in ONE step to 0.6 mm.
    const hip_x: u32 = m.jnt_qpos_adr[jointIndex(s, "hip_x_right") orelse return];
    const hip_y: u32 = m.jnt_qpos_adr[jointIndex(s, "hip_y_right") orelse return];
    for (0..14) |_| {
        settleFoot(s, right_foot);
        const err: [2]f32 = comOverFoot(s, right_foot);
        if (@sqrt(err[0] * err[0] + err[1] * err[1]) < 0.003) {
            break;
        }
        var jac: [4]f32 = undefined;
        const eps: f32 = 0.01;
        inline for (.{ hip_x, hip_y }, 0..) |q, col| {
            const keep: f32 = s.data.pos[q];
            s.data.pos[q] = keep + eps;
            settleFoot(s, right_foot);
            const moved: [2]f32 = comOverFoot(s, right_foot);
            jac[0 * 2 + col] = (moved[0] - err[0]) / eps;
            jac[1 * 2 + col] = (moved[1] - err[1]) / eps;
            s.data.pos[q] = keep;
        }
        const det: f32 = jac[0] * jac[3] - jac[1] * jac[2];
        if (@abs(det) < 1.0e-6) {
            break;
        }
        const dx: f32 = (-err[0] * jac[3] + err[1] * jac[1]) / det;
        const dy: f32 = (-jac[0] * err[1] + jac[2] * err[0]) / det;
        s.data.pos[hip_x] = clamp(s.data.pos[hip_x] + clamp(dx, -0.15, 0.15), -0.52, 0.17);
        s.data.pos[hip_y] = clamp(s.data.pos[hip_y] + clamp(dy, -0.15, 0.15), -2.6, 0.35);
    }
    // ★ THE ARMS GO OUT BY IK, NOT BY ANGLE. The shoulder axes are `2 1 1` and `0 -1 1` — not
    // orthogonal and not aligned with anything, so "45 degrees" in joint space would mean
    // whatever those axes made of it. A hand POSITION is unambiguous.
    const diag: f32 = 0.52 * 0.7071;
    for (0..12) |_| {
        _ = (ctl.Ik{ .max_iterations = 10, .max_step = 0.20 }).solve(
            m,
            &s.data,
            s.arm_act_right,
            .{ .body = hand_right, .offset = vec(0, 0, 0), .goal = s.data.body_xpos[arm_r] + vec(diag, -diag, 0) },
            s.ik_scratch,
        );
        _ = (ctl.Ik{ .max_iterations = 10, .max_step = 0.20 }).solve(
            m,
            &s.data,
            s.arm_act_left,
            .{ .body = hand_left, .offset = vec(0, 0, 0), .goal = s.data.body_xpos[arm_l] + vec(diag, diag, 0) },
            s.ik_scratch,
        );
    }

    // ★ AND ONE MORE PASS, BECAUSE THE ARMS MOVED THE MASS. Reaching shifts roughly 5 kg out
    // to 0.5 m; measured, that took the centre of mass from 0.6 mm off the foot to 21 mm.
    for (0..6) |_| {
        settleFoot(s, right_foot);
        const err: [2]f32 = comOverFoot(s, right_foot);
        if (@sqrt(err[0] * err[0] + err[1] * err[1]) < 0.004) {
            break;
        }
        var jac: [4]f32 = undefined;
        const eps: f32 = 0.01;
        inline for (.{ hip_x, hip_y }, 0..) |q, col| {
            const keep: f32 = s.data.pos[q];
            s.data.pos[q] = keep + eps;
            settleFoot(s, right_foot);
            const moved: [2]f32 = comOverFoot(s, right_foot);
            jac[0 * 2 + col] = (moved[0] - err[0]) / eps;
            jac[1 * 2 + col] = (moved[1] - err[1]) / eps;
            s.data.pos[q] = keep;
        }
        const det: f32 = jac[0] * jac[3] - jac[1] * jac[2];
        if (@abs(det) < 1.0e-6) {
            break;
        }
        const dx: f32 = (-err[0] * jac[3] + err[1] * jac[1]) / det;
        const dy: f32 = (-jac[0] * err[1] + jac[2] * err[0]) / det;
        s.data.pos[hip_x] = clamp(s.data.pos[hip_x] + clamp(dx, -0.15, 0.15), -0.52, 0.17);
        s.data.pos[hip_y] = clamp(s.data.pos[hip_y] + clamp(dy, -0.15, 0.15), -2.6, 0.35);
    }
    settleFoot(s, right_foot);
    _ = root;
}

fn setJoint(s: *State, name: []const u8, angle: f32) void {
    if (jointIndex(s, name)) |j| {
        s.data.pos[s.imported.model.jnt_qpos_adr[j]] = angle;
    }
}

/// The model carries no name table; `mjcf.Robot` does, and the joints are built in that order.
fn jointIndex(s: *State, want: []const u8) ?u32 {
    for (s.robot.joints, 0..) |joint, j| {
        if (std.mem.eql(u8, joint.name, want)) {
            return @intCast(j);
        }
    }
    return null;
}

/// Rotate the WHOLE robot so the support foot's sole lies flat on the ground.
///
/// ── ★★★ THE STEP THAT WAS MISSING, AND IT IS A GLOBAL ONE ──
///
/// Setting joint angles gets every bone right RELATIVE to its parent and says nothing about
/// where the chain ends up pointing. Bending the support hip rotates the leg against a torso
/// that stays bolt upright, so the foot meets the ground at whatever angle the chain leaves it.
/// Measured on the first version: **13.2 degrees**, the sole touching on ONE CORNER with the
/// other three between 27 and 49 mm in the air.
///
/// **That is not a stance, it is a pose caught mid-fall** — and no controller holds it, because
/// a foot on a corner has no support polygon to work with at all. Levelling brings the foot's
/// up-axis to (−0.010, 0.001, 1.000) and puts two sole points on the ground instead of one.
/// The 5.5 degrees that remain are the foot model's own rake, not an error.
fn levelFoot(s: *State, foot: u32) void {
    const m: *const rbt.Model = &s.imported.model;
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
    const up: Vec = zm.rotate(s.data.body_xrot[foot], vec(0, 0, 1));
    const axis: Vec = cross(up, vec(0, 0, 1));
    const sine: f32 = length3(axis);
    if (sine < 1.0e-6) {
        return;
    }
    const angle: f32 = atan2Rad(sine, dot3(up, vec(0, 0, 1)));
    const fix: zm.Quat = zm.quatFromAxisAngle(axis / splat(sine), angle);
    const root: u32 = m.jnt_qpos_adr[0];
    const current: zm.Quat = .{
        s.data.pos[root + 3], s.data.pos[root + 4],
        s.data.pos[root + 5], s.data.pos[root + 6],
    };
    const fixed: zm.Quat = zm.qmul(fix, current);
    s.data.pos[root + 3] = fixed[0];
    s.data.pos[root + 4] = fixed[1];
    s.data.pos[root + 5] = fixed[2];
    s.data.pos[root + 6] = fixed[3];
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
}

/// Drop the root until the support foot's lowest point rests on the ground.
fn settleFoot(s: *State, foot: u32) void {
    const m: *const rbt.Model = &s.imported.model;
    // ★ LEVEL BEFORE SETTLING. Rotating the robot changes which point is lowest, so dropping
    // first and levelling second leaves the foot either buried or floating.
    levelFoot(s, foot);
    var lowest: f32 = 1.0e9;
    for (0..m.ngeom) |g| {
        if (m.geom_body[g] != foot) {
            continue;
        }
        const half: f32 = switch (m.geom_shape[g]) {
            .capsule => |c| c.half_height,
            else => 0,
        };
        const radius: f32 = switch (m.geom_shape[g]) {
            .capsule => |c| c.radius,
            .sphere => |sp| sp.radius,
            else => continue,
        };
        const axis: Vec = zm.rotate(zm.qmul(s.data.body_xrot[foot], m.geom_rot[g]), capsule_axis);
        const centre: Vec = s.data.body_xpos[foot] + zm.rotate(s.data.body_xrot[foot], m.geom_pos[g]);
        inline for ([_]f32{ -1.0, 1.0 }) |end| {
            lowest = @min(lowest, (centre + axis * splat(end * half))[2] - radius);
        }
    }
    s.data.pos[m.jnt_qpos_adr[0] + 2] -= lowest;
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
}

/// How far the centre of mass sits from the middle of the SOLE — not from the foot body's
/// origin, which is a different place.
///
/// ── ★★★ THE SOLE RUNS FROM −0.07 TO +0.14 IN THE FOOT'S FRAME ──
///
/// Its middle is therefore **0.035 m forward** of the body origin: a third of the way to the toe
/// on a 0.21 m foot. Targeting the origin put the mass that far behind the middle of its own
/// support before the robot had done anything.
///
/// ★ AND A ONE-LEGGED STAND HAS NO MARGIN TO SPEND. The sole can supply about `f_z × 0.105`
/// ≈ 42 N·m of restoring moment against `m·g·h·θ` ≈ 360·θ, so a stiff ankle holds it out to
/// roughly **6.7 degrees** of lean — and 3.5 cm at 0.9 m is 2.2 of those degrees given away for
/// nothing. That is why it fell forward rather than simply wobbling.
fn comOverFoot(s: *State, foot: u32) [2]f32 {
    const m: *const rbt.Model = &s.imported.model;
    const com: Vec = s.data.subtree_com[rbt.world_body];
    var total: Vec = vec(0, 0, 0);
    var count: f32 = 0;
    for (0..m.ngeom) |g| {
        if (m.geom_body[g] != foot) {
            continue;
        }
        const half: f32 = switch (m.geom_shape[g]) {
            .capsule => |c| c.half_height,
            else => continue,
        };
        const axis: Vec = zm.rotate(zm.qmul(s.data.body_xrot[foot], m.geom_rot[g]), capsule_axis);
        const mid: Vec = s.data.body_xpos[foot] +
            zm.rotate(s.data.body_xrot[foot], m.geom_pos[g]);
        inline for ([_]f32{ -1.0, 1.0 }) |end| {
            total += mid + axis * splat(end * half);
            count += 1;
        }
    }
    const at: Vec = if (count > 0) total / splat(count) else s.data.body_xpos[foot];
    return .{ com[0] - at[0], com[1] - at[1] };
}

/// Shove the trunk, at the slider's magnitude and in a random horizontal direction.
///
/// ── ★★ THE MAGNITUDE MATTERS MORE THAN IT LOOKS ──
///
/// This used to be hardcoded at 1.2 m/s, which is far outside anything the arms can influence.
/// Both arms together carry about **7.7 kg·m²/s** of angular momentum — spin plus orbital — and
/// `Δv = L/(m·h)` makes that worth roughly **0.23 m/s** of arrest. So the flywheel's whole
/// effect lives between about 0.2 and 0.5 m/s, and a 1.2 m/s shove knocks the robot down
/// whatever the planner does.
///
/// ★ A SLIDER IS THEREFORE NOT A CONVENIENCE, IT IS THE EXPERIMENT: the difference the arms make
/// is only visible in the band where they have authority at all.
fn shove(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    // A random horizontal direction, so the recovery is not always the same sagittal lean.
    s.shove_seed = s.shove_seed *% 1664525 +% 1013904223;
    const angle: f32 = float(s.shove_seed >> 8) * (2.0 * pi / 16777216.0);
    s.shove_dir = .{ @cos(angle), @sin(angle) };
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] == .free) {
            // The free joint's velocity DOFs are linear first, then angular.
            const v: u32 = m.jnt_dof_adr[j];
            s.data.vel[v + 0] += s.shove_speed * s.shove_dir[0];
            s.data.vel[v + 1] += s.shove_speed * s.shove_dir[1];
            s.data.stage = .stale;
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;

    // ── ★ IK RUNS ONCE PER FRAME, NOT PER PHYSICS SUBSTEP ──
    //
    // It answers "where should the arm be aiming", and that only changes when a slider moves.
    // Solving it inside the fixed-timestep loop recomputes the same answer for every substep,
    // and the cost multiplies by however many the accumulator owes — which feeds back, because
    // a slower frame owes more substeps. The KUKA demo learned this the expensive way.
    if (s.ik_on) {
        // The solve is destructive: it writes joint angles straight into `data`. Here that is
        // exactly what is wanted — the result IS the pose the controller then holds — but the
        // free joint must be preserved, or IK would decide where the pelvis goes.
        const result: ctl.BalancedIk.Result = (ctl.BalancedIk{
            .com_goal = s.com_goal,
            .com_gain = if (s.hold_com) 0.5 else 0.0,
            .reach = .{ .max_iterations = 6 },
        }).solve(&s.imported.model, &s.data, s.actuation, .{
            .body = s.hand,
            .goal = s.ik_goal,
        }, s.ik_scratch);
        s.ik_error = result.reach.error_distance;
        s.com_error = result.com_error;
        // The solved pose becomes the target the PD controller drives toward, so the arm still
        // travels there under its torque limits and can be knocked off course.
        @memcpy(s.home, s.data.pos);
    }

    s.accumulator += @min(f.time.delta_time, 0.1);
    while (s.accumulator >= timestep) : (s.accumulator -= timestep) {
        // Kinematics, then collision, then solve — all at one `q`. See `robot_physics.sync`
        // for why the order is not negotiable.
        rbt.forward(&s.imported.model, &s.data);
        if (s.physics_on) {
            s.bridge.sync(&s.world, &s.imported.model, &s.data) catch |err| {
                zm.assertUnreachable(@src(), "proxy sync failed: {t}", .{err});
            };
            zp.step(&s.world, timestep) catch |err| {
                zm.assertUnreachable(@src(), "world step failed: {t}", .{err});
            };
            s.bridge.harvest(&s.data);
        }
        control(s);
        rbt.step(&s.imported.model, &s.data);
    }
    rbt.forward(&s.imported.model, &s.data);

    // ★ THE TWITCH AS A NUMBER. The difference between the two solvers on a limp body is a
    // residual velocity — 2.67 against 0.41, measured — and a viewer cannot eyeball that. A
    // rolling peak makes it readable, and resets each second so it tracks the present rather
    // than remembering the landing.
    var fastest: f32 = 0;
    for (0..s.imported.model.nv) |i| {
        fastest = @max(fastest, @abs(s.data.vel[i]));
    }
    s.recent_peak_speed = @max(s.recent_peak_speed, fastest);

    // ★ ½·vᵀMv, THE HONEST TOTAL. `mulM` is the dynamics' own routine, so this uses the model's
    // real mass matrix rather than a sum over bodies that would ignore the coupling between
    // them.
    // ★★ THE ROBOT'S DOFs ONLY. This summed over the whole model, and the model carries six
    // throwable balls — so the figure described the balls as much as the humanoid. It is a
    // readout about the robot; it should read the robot.
    var momentum: [80]f32 = undefined;
    const nv: usize = s.imported.model.nv;
    if (nv <= momentum.len) {
        rbt.mulM(&s.imported.model, &s.data, s.data.vel, momentum[0..nv]);
        var energy: f32 = 0;
        for (0..s.robot_dof_count) |i| {
            energy += 0.5 * s.data.vel[i] * momentum[i];
        }
        s.kinetic_energy = energy;
        s.energy_clock += f.time.delta_time;
        if (s.energy_clock >= 0.1) {
            s.energy_clock = 0;
            if (s.energy_len < s.energy_history.len) {
                s.energy_history[s.energy_len] = energy;
                s.energy_len += 1;
            } else {
                std.mem.copyForwards(
                    f32,
                    s.energy_history[0 .. s.energy_history.len - 1],
                    s.energy_history[1..],
                );
                s.energy_history[s.energy_history.len - 1] = energy;
            }
        }
    }
    s.speed_window += f.time.delta_time;
    if (s.speed_window >= 1.0) {
        s.speed_window = 0;
        s.recent_peak_speed = fastest;
    }

    var force: f32 = 0;
    for (0..s.data.constraint_count) |row| {
        force += s.data.constraint_force[row];
    }
    s.peak_force = @max(s.peak_force * 0.995, force);

    // ── ★★ THE UI IS BUILT EARLY AND RENDERED LAST, AND BOTH HALVES MATTER ──
    //
    // **Built early**, because the camera has to know whether the mouse belongs to a slider —
    // otherwise dragging `kp` orbits the view at the same time.
    //
    // **Rendered last**, because `clearViewport` wipes whatever has been drawn. Keeping
    // `begin`/`render` inside the panel function put the deferred `render` at the END OF THAT
    // FUNCTION — before the clear — so the panel was drawn and then erased, every frame. The
    // demo showed a robot and no controls at all, and looked like a build problem.
    //
    // `robot_3d` had it right by accident: its `begin` and its clear live in the same
    // function, so the defer naturally lands after the 3D pass. Making that structural rather
    // than incidental is the point of passing `u` in.
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    z.clearViewport(f, bg);
    const cam: Camera3D = s.cam.update(f, captured, .{
        .min_distance = 0.6,
        .max_distance = 4.0,
    });
    // ★ THE THROW HAPPENS HERE, not in the panel, because it needs the camera — and the
    // camera is not known until after the panel has said whether the mouse belongs to it.
    if (s.want_throw) {
        s.want_throw = false;
        throwBall(s, cam);
    }

    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 16, 0.25);
    drawRobot(s, gl);
    z.endMode3D(gl);
}

/// Draw every collision geom the importer kept.
///
/// ★ THESE ARE THE COLLISION SHAPES, not the visual meshes — the Go1's 13 `<mesh>` geoms are
/// skipped by the converter because their vertices live in an `<asset>` block that is not read
/// yet. Which turns out to be the better picture for a physics demo: what you see IS what the
/// solver sees, so a leg that looks like it is touching the ground is touching the ground.
fn drawRobot(s: *State, gl: *z.WgpuGl) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        // ★ A GEOM'S WORLD POSE IS ITS BODY'S, COMPOSED WITH ITS OWN OFFSET. The engine
        // stores the offset (`geom_pos`/`geom_rot`) and the body's world pose separately —
        // it never needs the product except when something is drawn or collided, so it does
        // not keep one.
        const body_rot: zm.Quat = s.data.body_xrot[body];
        const world_pos: Vec = s.data.body_xpos[body] + zm.rotate(body_rot, m.geom_pos[g]);
        const world_rot: Mat = quatToMat(zm.qmul(body_rot, m.geom_rot[g]));
        const place: Mat = mulMat(mulMat(to_y_up, translation(world_pos[0], world_pos[1], world_pos[2])), world_rot);
        // Feet are the interesting part, so they get a brighter colour.
        const tint: Color = if (body == 0) trunk_col else link_col;
        switch (m.geom_shape[g]) {
            .sphere => |sph| {
                s.transform[0] = mulMat(place, scaling(sph.radius, sph.radius, sph.radius));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            },
            .capsule => |cap| {
                // ── ★★ THE MESH ALREADY RUNS ALONG Y. MEASURED, NOT DERIVED. ──
                //
                //     genMeshCylinder(r=1, h=1) extent:
                //       x: [-1.000, 1.000]   y: [0.000, 1.000]   z: [-1.000, 1.000]
                //
                // `cylinderUv` returns the axis in its third slot, which reads as Z — but
                // `parametricMesh` REMAPS as it writes (`verts.y = p[2]`), so the finished
                // mesh extends along zimr's **Y**, spanning [0, h] rather than [−h/2, +h/2].
                //
                // That is the same axis `GeomShape.capsule` uses, so no rotation is needed at
                // all. A previous version read `cylinderUv` and concluded Z, then rotated by
                // −90° to "correct" it; the non-uniform scale then landed across the shape and
                // flattened every limb into a wide curved ribbon. **Reading the generator was
                // not enough — the answer was two functions away, and printing the mesh's
                // bounds took one command.**
                //
                // Only the [0, h] span needs correcting, with a half-length shift along Y.
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, -cap.half_height, 0)),
                    scaling(cap.radius, 2.0 * cap.half_height, cap.radius),
                );
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
                inline for ([_]f32{ -1.0, 1.0 }) |end| {
                    s.transform[0] = mulMat(
                        mulMat(place, translation(0, end * cap.half_height, 0)),
                        scaling(cap.radius, cap.radius, cap.radius),
                    );
                    z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
                }
            },
            .cylinder => |cyl| {
                // Same axis and the same [0, h] span as the capsule above.
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, -cyl.half_height, 0)),
                    scaling(cyl.radius, 2.0 * cyl.half_height, cyl.radius),
                );
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
            },
            .box => |box| {
                s.transform[0] = mulMat(place, scaling(
                    2.0 * box.half_extent[0],
                    2.0 * box.half_extent[1],
                    2.0 * box.half_extent[2],
                ));
                z.drawMeshInstanced(gl, &s.cube, &s.transform, tint);
            },
            else => {},
        }
    }

    // The projectiles, drawn from the tree like everything else.
    for (0..ball_count) |i| {
        const body: u32 = s.imported.bodyIndex(ball_names[i]) orelse continue;
        const p: Vec = s.data.body_xpos[body];
        s.transform[0] = mulMat(
            mulMat(to_y_up, translation(p[0], p[1], p[2])),
            scaling(ball_radius, ball_radius, ball_radius),
        );
        z.drawMeshInstanced(gl, &s.sphere, &s.transform, ball_col);
    }

    // ★ THE REACH TARGET AND A LINE TO IT. The line is the useful part: it shrinks to nothing
    // when the hand arrives and grows when the goal moves out of reach, which is the same
    // number the panel prints, where the eye already is.
    if (s.ik_on) {
        const goal_y_up: Vec = vec(s.ik_goal[0], s.ik_goal[2], -s.ik_goal[1]);
        const hand_at: Vec = s.data.body_xpos[s.hand];
        const hand_y_up: Vec = vec(hand_at[0], hand_at[2], -hand_at[1]);
        z.drawSphere(gl, goal_y_up, .{
            .radius = 0.04,
            .rings = 8,
            .slices = 12,
            .color = if (s.ik_error < 0.02) goal_reached_col else goal_straining_col,
        });
        z.drawLine3D(gl, hand_y_up, goal_y_up, goal_straining_col);
    }

    // Contact points, so "is it actually standing" is answerable by looking.
    for (0..s.data.contact_count) |c| {
        const p: Vec = s.data.contacts[c].position;
        // Z-up to Y-up is a coordinate swap, and writing it as one is clearer here than
        // pushing a point through a matrix: (x, y, z) becomes (x, z, −y).
        const at: Vec = vec(p[0], p[2], -p[1]);
        z.drawSphere(gl, at, .{ .radius = 0.012, .color = contact_col });
    }
}

/// Lift the humanoid, tip it over, and let go.
///
/// ★ TIPPED, NOT UPRIGHT. A body dropped on its feet makes three or four contacts and settles
/// on its own; landing on its side makes fifteen, coupled through every joint, which is the
/// case the two solvers disagree about.
fn dropLimp(s: *State) void {
    _ = rmj.applyKeyframe(&s.imported.model, &s.data, s.robot.keyframes[0]);
    s.data.pos[2] = 1.2;
    const tipped: zm.Quat = zm.quatFromAxisAngle(normalize3(vec(1, 0.3, 0)), 1.4);
    s.data.pos[3] = tipped[0];
    s.data.pos[4] = tipped[1];
    s.data.pos[5] = tipped[2];
    s.data.pos[6] = tipped[3];
    @memset(s.data.vel, 0);
    @memset(s.data.acc, 0);
    @memset(s.data.applied_force, 0);
    s.data.clearContacts();
    // ★ AND THE WARM START GOES TOO, or the first solve after the teleport begins from forces
    // that belonged to a body somewhere else entirely.
    s.data.forgetWarmStart();
    s.data.stage = .stale;
    rbt.forward(&s.imported.model, &s.data);
    s.bridge.teleported();
    s.limp = true;
    s.recent_peak_speed = 0;
    s.speed_window = 0;
    s.kinetic_energy = 0;
    s.energy_len = 0;
    s.energy_clock = 0;
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const m: *const rbt.Model = &s.imported.model;
    const captured: bool = u.wantCaptureMouse();
    // Sized to the viewport rather than to pixels — see `ui.Ui.scaleToViewport`.
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(420.0, viewport_w * 0.33);
    const font_size: f32 = u.scaleToViewport(panel_w, if (narrow) 32.0 else 24.0);
    u.setNextWindowPos(.{ 8, 8 }, .{});
    // ★★ A HEIGHT CAP, BECAUSE AUTO-SIZE IS NOT A LAYOUT. Passing 0 lets the window grow to fit
    // its content, and this panel's content is 552 px — fine on a desktop and three times the
    // viewport on a phone with the console drawer open, which is exactly what the engine's own
    // lint reported: "content (552px) is >3x its viewport (174px)". Capping at 70% of the
    // viewport gives the window a scrollbar instead of letting it run off the screen.
    u.setNextWindowSize(.{ panel_w, @min(560.0, viewport_h * 0.7) }, .{});
    if (u.window("Humanoid, 27 DOF, imported from MJCF", .{})) |window| {
        defer window.close();
        u.text("{d} bodies   {d} DOF   {d} collision geoms", .{ m.nbody - 1, m.nv, m.ngeom });
        // ★ THE BODY IS CALLED `torso` HERE, NOT `trunk`. Copied from the Go1 demo, where the
        // name is different, and `bodyIndex` returning null then fell back to body 1 — a
        // readout that was always plausible and always wrong.
        const torso: u32 = s.imported.bodyIndex("torso") orelse 1;
        u.text("torso height {d:.4} m   (standing 1.2820)", .{s.data.body_xpos[torso][2]});
        // ★ WHAT IS BEING HELD, SHOWN. Without it a button press that worked and a button
        // press that did nothing look identical — which is exactly the ambiguity that made
        // "poses don't seem to work" hard to pin down.
        u.text("holding: {s}", .{s.pose_label});
        u.text("contacts {d}   rows {d}   iters {d}   load {d:.0} N", .{
            s.data.contact_count,
            s.data.constraint_count,
            s.data.solver_iterations,
            s.peak_force,
        });
        u.separator();

        // ★ THE TWO NUMBERS WORTH PLAYING WITH. `kp = 100` is the Go1's own, from
        // `<position kp="100">` in its MJCF. Drag it down and the legs fold under the robot's
        // weight; drag it up and it goes rigid and starts to buzz against its force limit.
        // ── ★★ THE BAND THAT WORKS IS NARROW, AND BOTH EDGES ARE INSTRUCTIVE ──
        //
        //     kp  100  ->  folds under its own weight, torso sinks to 0.24 m
        //     kp  400  ->  stands, 4.5 mm of drift over ten seconds
        //     kp 1000  ->  diverges: torso at −201 m
        //
        // The stiff end looks like a physics explosion and is a CONTROLLER one — a PD law
        // outrunning a fixed timestep. Worth being able to reproduce on a slider, because that
        // failure is so easily blamed on the solver.
        // ── ★★★ THE `kv` CEILING IS 10, AND IT IS NOT A TASTE ──
        //
        // A PD's derivative term is an APPLIED torque, integrated explicitly, so it is stable
        // only while `kv·dt/M < 2`. For a joint carrying this model's armature of 0.01 at
        // dt = 1/500 that caps `kv` at **10**, and this slider used to run to 40 — four times
        // the limit. Measured, shoving the robot over four times: `kv` 10 peaks at 32 J and
        // settles; `kv` 40 peaks at 174 J and stays at 39. **More damping made it worse**,
        // which is the signature of explicit integration.
        //
        // ★★ AND THE FIX IS THE RANGE, NOT THE UNITS. A first attempt converted these to
        // frequency units with `scale_by_inertia`, which removes the inertia dependence and is
        // the right tool for a model whose links differ by orders of magnitude. On THIS robot
        // it was a large regression: standing still for five seconds, joint motion went from
        // **0.0000 to 16.88** — from perfectly still to visibly shaking. The old gains were
        // measured and good; only the slider's upper end was wrong.
        _ = u.slider("kp", &s.kp, .{ .min = 20.0, .max = 1200.0, .fmt = "{d:.0}" });
        _ = u.slider("kv (10 is the stability limit)", &s.kv, .{ .min = 0.0, .max = 10.0, .fmt = "{d:.1}" });
        _ = u.slider("motor N·m", &s.max_torque, .{ .min = 10.0, .max = 600.0, .fmt = "{d:.0}" });
        _ = u.checkbox("physics", &s.physics_on);

        // ── ★★ THE RAGDOLL, AND THE REASON THIS DEMO HAS A SOLVER TOGGLE ──
        u.separator();
        // ★ BALANCE MODE: the planner picks where the pressure should be and the ankles put it
        // there. Turn it off and the ankles go back to holding a fixed angle — which stands, but
        // has no idea where the mass is.
        if (s.ankles_ready) {
            _ = u.checkbox("MPC balance (EXPERIMENTAL — see notes)", &s.balance_on);
        }
        if (s.balance_on) {
            u.text("  wants CoP x {d:>7.4}   carrying {d:>6.1} N", .{ s.want_cop[0], s.carried_load });
            const com: Vec = s.data.subtree_com[rbt.world_body];
            u.text("  CM x {d:>7.4}   lean {d:>7.4} m", .{ com[0], com[0] - s.data.body_xpos[s.ankle_foot[0]][0] });
            _ = u.slider("ankle damping", &s.ankle_damping, .{ .min = 1, .max = 30, .fmt = "{d:.1}" });
            // ★ ZERO IS THE ANKLE STRATEGY ALONE — the pressure shifts inside the foot and
            // nothing else moves. Raise it and the arms start carrying momentum, which is the
            // part a reactive controller cannot do.
            _ = u.slider("arm authority", &s.momentum_rate, .{ .min = 0, .max = 200, .fmt = "{d:.0}" });
            u.text("  limb swing {d:>6.3} rad", .{s.limb_swing});
        }
        u.separator();
        _ = u.checkbox("limp (ragdoll — no controller)", &s.limp);

        // ── ★★ FLESH: how thick the layer of give around every body is ──
        //
        // Zero is the hard surface this always had. Turn it up and the contact stiffens gradually
        // across that depth instead of all at once — skin, then fat, then bone — so a dropped limb
        // sinks in and settles rather than arriving all at the same instant.
        //
        // ★ THE SOLVER ALREADY DID THIS; only nothing chose it. `Impedance` ramps a constraint from
        // `min` to `max` over a width, which is MuJoCo's `solimp`, and it was left at its default
        // on every contact the bridge made.
        _ = u.slider("fat thickness (m)", &s.bridge.flesh.thickness_m, .{
            .min = 0.0,
            .max = 0.05,
            .fmt = "{d:.3}",
        });
        // ★ ABOVE 1 THE CONTACT ABSORBS RATHER THAN REBOUNDS, which is most of what separates
        // flesh from rubber.
        _ = u.slider("damping (1 = critical)", &s.bridge.flesh.damp_ratio, .{
            .min = 0.5,
            .max = 6.0,
            .fmt = "{d:.1}",
        });
        if (u.button("drop it", .{})) {
            dropLimp(s);
        }
        var newton: bool = s.imported.model.opt.solver.algorithm == .newton;
        if (u.checkbox("Newton solver (else PGS)", &newton)) {
            s.imported.model.opt.solver.algorithm = if (newton) .newton else .pgs;
        }
        // ★ THE NUMBER IS THE POINT. Limp, on the floor, PGS settles to about 2.7 and Newton to
        // about 0.4 — the same pose either way, so what differs is whether the body stops. Toggle
        // the solver and watch this figure, not the mesh.
        u.text("peak joint speed {d:.2}  ({d} contacts)", .{ s.recent_peak_speed, s.data.contact_count });

        // ── ★★★ THE MEASUREMENT THIS DEMO EXISTS TO SHOW ──
        //
        // Drop it limp and watch this fall. On a body that has stopped, it should reach nothing.
        // MuJoCo on the identical model and drop settles to 0.0003 - 0.0007 J. Ours levels off
        // around 0.014 - 0.026, roughly forty times higher, and the energy is arriving through the
        // contact solve — measured, about 1.5 J per two seconds, mostly balanced by joint damping
        // at an equilibrium that sits too high.
        u.text("kinetic energy {d:.5} J   (MuJoCo settles to ~0.0005)", .{s.kinetic_energy});
        if (s.energy_len > 2) {
            var peak: f32 = 0.001;
            for (s.energy_history[0..s.energy_len]) |value| {
                peak = @max(peak, value);
            }
            u.plotLines("", s.energy_history[0..s.energy_len], .{
                .min = 0,
                .max = peak,
                .width = panel_w - font_size * 2.0,
                .height = font_size * 3.5,
                .overlay = "kinetic energy, last ~18 s",
            });
        }

        // ★ AND THE KNOB THAT MOVES IT, WITH THE CAVEAT ATTACHED. Tightening this to 0.2 measured
        // seven times less energy — 0.0179 J down to 0.0026 — but turning it OFF also helped, which
        // breaks monotonicity. A landed ragdoll is chaotic, so one run cannot tell signal from
        // variation, and this is on screen to be PLAYED with rather than as a tuned default.
        var recovery: f32 = s.imported.model.opt.solver.max_recovery_velocity;
        if (u.slider("penetration recovery cap", &recovery, .{ .min = 0.05, .max = 8.0, .fmt = "{d:.2}" })) {
            s.imported.model.opt.solver.max_recovery_velocity = recovery;
        }
        // ★ THE ONE-LEG POSE IS BUILT, NOT LOADED — see `buildOneLegPose`. Arms out doubles the
        // flywheel (15.54 against 7.92 kg·m²/s) and the mass starts over the foot rather than
        // 40 mm off it.
        _ = u.slider("shove m/s", &s.shove_speed, .{ .min = 0.05, .max = 1.50, .fmt = "{d:.2}" });
        u.text("  arms are worth ~0.23 m/s; try 0.15-0.40", .{});
        if (u.button("SHOVE (random direction)", .{})) {
            shove(s);
        }
        u.text("  last shove ({d:>5.2},{d:>5.2})", .{ s.shove_dir[0], s.shove_dir[1] });
        if (u.button("throw ball", .{})) {
            s.want_throw = true;
        }
        if (u.button("stand", .{})) {
            s.one_leg = false;
            for (s.ankle_roll_dof) |roll| {
                if (roll < s.imported.model.nv) {
                    s.balance_hold.powered[roll] = true;
                }
            }
            restorePose(s, null);
        }
        u.separator();
        // ── ★ THE MODEL'S OWN KEYFRAMES, and one of them is meant to fail ──
        //
        // None of the four is the standing pose, which is why `home` comes from `qpos0`.
        // Measured, holding each for three seconds at kp 400:
        //
        //     squat              0.596 -> 0.575   holds
        //     prone              0.076 -> 0.084   holds
        //     supine             0.081 -> 0.129   holds
        //     stand_on_left_leg  1.220 -> 0.150   FALLS
        //
        // The one-legged pose is not a bug and not a gains problem: holding it needs the robot
        // to keep its centre of mass over one foot, which a joint-space PD law has no way to
        // do — it drives joints toward angles and knows nothing about where the mass is. That
        // is the job of a balance controller, and it is the honest next thing to build.
        for (s.robot.keyframes, 0..) |key, i| {
            if (u.button(key.name, .{})) {
                restorePose(s, @intCast(i));
            }
        }
        // ★★★ AND THE BUILT ONE, WHICH IS THE INTERESTING CASE. Unlike the four above it is not
        // in the file — `buildOneLegPose` lifts the left leg, puts the arms out at 45 degrees by
        // IK, and runs a 2x2 Newton on the support hip until the mass sits over the foot (0.6 mm,
        // one step). Arms out is worth **15.54 kg·m²/s** of angular momentum against 7.92 folded.
        //
        // ★ AND IT TURNS THE BALANCE CONTROLLER ON, because a joint-space PD cannot hold a
        // one-legged stand at any gain — the comment above measures `stand_on_left_leg` falling
        // from 1.220 to 0.150. Offering the pose with the only controller that could hold it
        // switched off would be offering a pose that always falls.
        // ★★ IT DOES NOT HOLD YET, AND THE MEASUREMENTS SAY WHERE IT STANDS:
        //
        //     pose servo alone        torso 1.296 -> 0.452, tilt 2.31   falls
        //     + pitch ankle only      torso        -> 0.480, tilt 2.45   falls
        //     + BOTH ankles           torso        -> 0.486, tilt 0.16   falls
        //
        // ★ THE ROLL ANKLE IS MOST OF THE DIFFERENCE. Driving only `ankle_y` left the LATERAL
        // axis uncontrolled, and on one leg that is the hard direction — the foot is 0.21 m long
        // and 0.06 m WIDE. With both ankles the tilt drops from 2.45 rad to **0.16**: it no
        // longer tips over. It SINKS instead, torso to 0.486, which is a different failure and
        // not a torque ceiling (`max_torque` defaults to 1000 N·m). The support leg is folding
        // and why is the open question.
        if (u.button("stand on right leg (built)", .{})) {
            s.one_leg = true;
            for (s.ankle_roll_dof) |roll| {
                if (roll < s.imported.model.nv) {
                    s.balance_hold.powered[roll] = false;
                }
            }
            restorePose(s, null);
            if (s.ankles_ready) {
                s.balance_on = true;
            }
        }

        u.separator();

        // ── ★★ REACH WITH ONE HAND WHILE THE CENTRE OF MASS STAYS PUT ──
        //
        // Moving an arm moves the CM, and a humanoid whose CM leaves its feet falls over. With
        // "hold CM" on, the balance correction is projected into the nullspace of the reach —
        // it uses only the joint motions the hand does not feel, so the robot leans and
        // counterweights with its spine and free arm while the hand goes where it was sent.
        //
        // Turn it off and watch `CM drift` grow: measured five times larger without it.
        _ = u.checkbox("reach (right hand)", &s.ik_on);
        if (s.ik_on) {
            _ = u.checkbox("hold CM over the feet", &s.hold_com);
            _ = u.slider("hand x", &s.ik_goal[0], .{ .min = -0.7, .max = 0.7, .fmt = "{d:.2}" });
            _ = u.slider("hand y", &s.ik_goal[1], .{ .min = -0.7, .max = 0.7, .fmt = "{d:.2}" });
            _ = u.slider("hand z", &s.ik_goal[2], .{ .min = 0.2, .max = 1.9, .fmt = "{d:.2}" });
            u.text("   reach err {d:.4} m   CM drift {d:.4} m", .{ s.ik_error, s.com_error });
        }
    }
    return captured;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - humanoid from MJCF",
            .width = 820,
            .height = 680,
            .scale_mode = .responsive,
            // 3D needs a depth buffer or nearer geometry does not occlude farther.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
