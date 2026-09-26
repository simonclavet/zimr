//! quadruped - a real Unitree Go1, imported from MuJoCo Menagerie, standing on its own legs.
//!
//! -- * WHAT THIS DEMONSTRATES --
//!
//! Everything Phase B and Phase C turn 11 built, in one scene you can push over:
//!
//!   * an MJCF model read straight from Menagerie - 104 uses of `<default>`, 70 geoms,
//!     12 actuators, and a `home` keyframe - with forward kinematics that matches MuJoCo's
//!     own to 1e-4 on every body;
//!   * that robot HOLDING ITS POSE against gravity, with contacts from `zimrphysics` and
//!     dynamics from the articulated solver;
//!   * the two controller rules that took three attempts to get right, live on sliders.
//!
//! -- ** THE THING TO TRY --
//!
//! Drag **kp** down and watch the legs fold. Drag it up and the robot springs. Press **shove**
//! and see it recover - or not. The gains are the manufacturer's own by default (`kp = 100`,
//! from `<position kp="100" forcerange="-35.55 35.55">` in `go1.xml`).

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const length3 = zm.length3;
const sinTurns = zm.sinTurns;
const rbt = z.robot;
const zp = z.zimrphysics;
const mjcf = z.mjcf;
const rmj = z.robot_mjcf;
const bridge_mod = z.robot_physics;
const ctl = z.robot_control;
const Color = zm.Color;

const Vec = zm.Vec;
const Mat = zm.Mat;
const vec = zm.vec;
const clamp = zm.clamp;
const normalize3 = zm.normalize3;
const splat = zm.splat;
const float = zm.float;
const ui = z.ui;
const Camera3D = zm.Camera3D;
const pi = zm.pi;
const float64 = zm.float64;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const quatToMat = zm.quatToMat;
const identity = zm.identity;

/// The Go1 runs at 500 Hz in Menagerie, and its contacts want it.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// -- *** A THREE-BONE ARM, SPLICED INTO THE MJCF AT LOAD TIME --
//
// Injected into the trunk body and its motors appended to the actuator block, then imported
// normally. So the arm is a **parameter of this demo** rather than a second checked-in robot:
// its reach, mass and mount can change without anyone maintaining a fork of the Go1.
//
// * THE MASS IS THE POINT. Measured on the assembled model, a 1.94 kg gripper swinging through
// its range moves the whole-body centre of mass **0.144 m fore-aft**, against a foot base of
// about 0.36 m - forty percent of the support polygon, moving fast. That is a large load
// transfer between legs, and load transfer is what turns "hold the feet still" from a
// kinematics problem into a force problem.
const arm_bodies =
    \\      <body name="arm_base" pos="0.02 0 0.06">
    \\        <joint name="arm_yaw" type="hinge" axis="0 0 1" range="-3.0 3.0" damping="1.2" armature="0.02"/>
    \\        <geom type="capsule" fromto="0 0 0 0 0 0.10" size="0.035" density="700" rgba="0.85 0.62 0.30 1"/>
    \\        <body name="arm_upper" pos="0 0 0.10">
    \\          <joint name="arm_shoulder" type="hinge" axis="0 1 0" range="-2.4 2.4" damping="1.2" armature="0.02"/>
    \\          <geom type="capsule" fromto="0 0 0 0 0 0.28" size="0.030" density="700" rgba="0.85 0.62 0.30 1"/>
    \\          <body name="arm_fore" pos="0 0 0.28">
    \\            <joint name="arm_elbow" type="hinge" axis="0 1 0" range="-2.6 2.6" damping="1.0" armature="0.015"/>
    \\            <geom type="capsule" fromto="0 0 0 0 0 0.24" size="0.026" density="700" rgba="0.85 0.62 0.30 1"/>
    \\            <body name="arm_wrist" pos="0 0 0.24">
    \\              <joint name="arm_wrist" type="hinge" axis="0 1 0" range="-2.2 2.2" damping="0.8" armature="0.01"/>
    \\              <geom type="capsule" fromto="0 0 0 0 0 0.10" size="0.022" density="700" rgba="0.85 0.62 0.30 1"/>
    \\              <body name="gripper" pos="0 0 0.10">
    \\                <geom name="gripper_g" type="sphere" size="0.075" density="1100" rgba="0.35 0.80 0.60 1"/>
    \\              </body>
    \\            </body>
    \\          </body>
    \\        </body>
    \\      </body>
    \\
;

const arm_motors =
    \\    <motor name="m_arm_yaw" joint="arm_yaw" ctrlrange="-40 40" gear="1"/>
    \\    <motor name="m_arm_shoulder" joint="arm_shoulder" ctrlrange="-60 60" gear="1"/>
    \\    <motor name="m_arm_elbow" joint="arm_elbow" ctrlrange="-45 45" gear="1"/>
    \\    <motor name="m_arm_wrist" joint="arm_wrist" ctrlrange="-25 25" gear="1"/>
    \\
;

/// Splice the arm into the Go1's MJCF text. Caller owns the result.
fn mjcfWithArm(gpa: Allocator) ![]u8 {
    const base: []const u8 = @embedFile("go1.xml");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // -- *** THE ARM GOES AFTER THE LEGS, AND THE POSITION IS THE WHOLE BUG --
    //
    // Inserted BEFORE `FR_hip`, the arm's four joints come first in qpos order and **every leg
    // index shifts by four.** Leg angles then land in arm joints, the legs stay at qpos0 -
    // straight - and the robot topples the instant it is reset.
    //
    // * THAT LOOKED EXACTLY LIKE "the arm is too heavy", and survived a rest-pose sweep AND a
    // mass sweep down to a quarter of a kilo before the real cause showed itself: **it still
    // fell with a 0.25 kg arm**, which no amount of mass explains. After the legs, every mass
    // from 0.25 kg to 2.06 kg stands.
    //
    // ** AS THE LAST CHILD OF THE TRUNK all existing indices are preserved - the keyframe, the
    // actuator order, and every piece of code that assumes where a leg lives - and padding the
    // keyframe at the END becomes correct rather than accidentally right.
    //
    // Anchored on text rather than a line number so it survives the fixture being reformatted.
    const tail: []const u8 = "    </body>\n  </worldbody>";
    const leg_at: usize = std.mem.indexOf(u8, base, tail) orelse return error.NoTrunkEnd;
    try out.appendSlice(gpa, base[0..leg_at]);
    try out.appendSlice(gpa, arm_bodies);
    const tag: []const u8 = "  <actuator>\n";
    const act_at: usize = std.mem.indexOf(u8, base[leg_at..], tag) orelse return error.NoActuators;
    const cut: usize = leg_at + act_at + tag.len;
    try out.appendSlice(gpa, base[leg_at..cut]);
    try out.appendSlice(gpa, arm_motors);
    try out.appendSlice(gpa, base[cut..]);

    // -- *** AND THE KEYFRAME MUST GROW WITH THE MODEL --
    //
    // `home` carries 19 numbers because the Go1 has nq 19. Adding four arm joints makes it 23,
    // and `applyKeyframe` then REFUSES - correctly, because a keyframe of the wrong length is
    // not a pose. **Both call sites discarded the result with `_ =`**, so the refusal was
    // silent: the robot simply never got its standing pose, and the arm never reached the
    // configuration the demo assumed it was in.
    //
    // * THIS IS THE EXACT BUG `examples/humanoid` DOCUMENTS - "the keyframe was 28 numbers, the
    // model 70 once the projectiles joined the tree, and `applyKeyframe` refused. The label
    // still said holding: squat." Written down there, repeated here, because the splice changed
    // `nq` and nothing connected the two facts.
    //
    // *** THE ARM RESTS HALF BENT, not folded and not straight. An arm at a joint limit cannot
    // counter-animate in both directions, and the gimbal needs it to. Measured with these
    // angles, the robot stands at every routine amplitude tested and the gripper holds its point
    // to within 29 mm at the largest.
    // * THESE FOUR NUMBERS ARE `arm_rest`, and they have to stay in step with it - the keyframe
    // is text spliced into XML, so the compiler cannot check that for us. If the rest pose
    // changes, this string changes with it, or a reset silently restores a different arm.
    const arm_key: []const u8 = " 0 1.1 -1.6 0.5";
    // -- *** ANCHORED ON THE `qpos` ATTRIBUTE, NOT ON ITS LAST FEW NUMBERS --
    //
    // The splice used to find `-1.8 0 0.9 -1.8"` with `lastIndexOf`. **The home key's `ctrl`
    // ends in exactly the same text and comes after `qpos`**, so it was `ctrl` that grew and
    // `qpos` stayed at 19. `applyKeyframe` accepts 19 - it is a joint boundary, the whole robot
    // minus its arm - so nothing refused it, `home` came out four short, and `control` indexed
    // past it on the first arm joint: an out-of-bounds trap in the launcher.
    const owned: []u8 = try out.toOwnedSlice(gpa);
    defer gpa.free(owned);
    const key_at: usize = std.mem.indexOf(u8, owned, "<key ") orelse return error.NoKeyframe;
    const qpos_attr: []const u8 = "qpos=\"";
    const qpos_at: usize = key_at + qpos_attr.len +
        (std.mem.indexOf(u8, owned[key_at..], qpos_attr) orelse return error.NoKeyframe);
    const qpos_end: usize = qpos_at +
        (std.mem.indexOfScalar(u8, owned[qpos_at..], '"') orelse return error.NoKeyframe);
    var padded: std.ArrayList(u8) = .empty;
    errdefer padded.deinit(gpa);
    try padded.appendSlice(gpa, owned[0..qpos_end]);
    try padded.appendSlice(gpa, arm_key);
    try padded.appendSlice(gpa, owned[qpos_end..]);
    return padded.toOwnedSlice(gpa);
}

const timestep: f32 = 1.0 / 500.0;

/// How many projectiles the scene carries.
///
/// -- ** A FIXED POOL, RECYCLED, RATHER THAN SPAWNED ON DEMAND --
///
/// A ball has to be a body in the ROBOT'S OWN TREE to hit it properly (section 4k) - that is the
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
/// * THEY ARE STILL SIMULATED DOWN THERE, and that is fine - nothing is near them, so they
/// contribute no contacts and cost only their six DOFs in the mass matrix. Parking beats
/// deleting because a tree cannot gain a body without being rebuilt, and rebuilding mid-throw
/// would discard the robot's state.
fn parkedBall(i: usize) Vec {
    return vec(-3.0 - float(i) * 0.3, 0, -2.0);
}

const bg: Color = .{ .r = 18, .g = 14, .b = 16, .a = 255 };
const trunk_col: Color = .{ .r = 130, .g = 128, .b = 132, .a = 255 };
const link_col: Color = .{ .r = 90, .g = 205, .b = 190, .a = 255 };
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
    ui_host: z.UiHost,
    /// One IK mask per leg - see `ctl.limbActuation`.
    legs: [4]ctl.Actuation,
    /// The calf body of each leg, and where its foot is pinned in the world.
    foot_body: [4]u32,
    planted: [4]Vec,
    /// Each foot's stance position expressed in the TORSO's frame - what the gait cycle is
    /// measured from. See `solveGait`.
    foot_rest: [4]Vec,
    foot_offset: [4]Vec,
    ik_scratch: []Vec,
    /// Commanded torso pose, relative to where the robot started.
    body_roll: f32,
    body_pitch: f32,
    body_yaw: f32,
    body_height: f32,
    posing: bool,
    pose_error: f32,
    /// Gait state. Phase runs 0..1 and the four offsets are what make a gait a gait.
    gait_on: bool,
    gait_phase: f32,
    /// -- *** THE ARM SWINGS WITH THE GAIT, OPEN-LOOP --
    ///
    /// Three FEEDBACK balance laws made this robot worse, and the baseline explains why: it
    /// already walks with a steady, harmless -0.012 rad of pitch, so a reactive controller has
    /// nothing to react to and can only inject noise. An integrator on that never-zero error
    /// additionally wound the arm to its stop, where 2 kg at maximum lever arm is dead weight.
    ///
    /// ** THE DISTURBANCE IS PERIODIC AND KNOWN. A trot's wobble is locked to the gait clock, so
    /// it can be cancelled by swinging the arm at the same frequency with the right phase.
    /// Measured over 10 s at hz 2.0 / stride 0.16 / duty 0.60:
    ///
    ///     amp 0.0             0.567 m   pitch steady at -0.012
    ///     amp 0.3  phase 0.50 **FELL** at 4.36 s
    ///     amp 0.3  phase 0.75 **0.843 m**   pitch flattens to 0.000
    ///     amp 0.6  phase 0.75   FELL
    ///
    /// **1.49x further, and the pitch bias goes to zero.** * PHASE IS THE PARAMETER: the same
    /// amplitude a quarter-cycle away falls over. A sweep over amplitude alone would have
    /// concluded the arm does not help, at every amplitude, and been wrong.
    ///
    /// *** AND A BOUNDED SINUSOID CANNOT WIND UP - no gate, no anti-windup, no pull-home. Those
    /// were three patches for a symptom of the wrong law.
    arm_swing_amp: f32,
    arm_swing_phase: f32,
    /// How far the shoulder sweeps around its rest during the routine, and how slowly.
    arm_lift_amp: f32,
    arm_lift_rate: f32,
    gait_hz: f32,
    gait_stride: f32,
    gait_lift: f32,
    gait_duty: f32,
    gait_offset: [4]f32,
    pose_scratch: []f32,
    rest_height: f32,
    rest_rot: zm.Quat,
    /// The full qpos the sliders are relative to.
    stance: []f32,
    /// Last solved command, so the solve only runs when something changed.
    last_cmd: [4]f32,
    /// -- *** THE LOOP THE PIPELINE WAS MISSING --
    ///
    /// The commanded attitude is turned into leg angles by IK and handed to a PD. Those angles
    /// would give the commanded roll IF the joints tracked perfectly - under the trunk's weight
    /// they do not, and **nothing here ever looked at the torso's real orientation.**
    ///
    /// Measured on the shipped version: every command undershot by a nearly constant
    /// 0.030-0.048 rad. Ask for 0.15 rad of roll and you got 0.10. **The sliders lied.**
    ///
    /// This trim is the missing feedback: the difference between what the torso is actually
    /// doing and what was asked, integrated, and folded back into the command before the legs
    /// are re-solved. Measured after: within 3%.
    trim_roll: f32,
    trim_pitch: f32,
    /// Frames since the trim last updated. * IT MUST BE SLOW: `solveBodyPose`'s own comment
    /// records that re-solving every frame destabilises the robot, so the correction runs on a
    /// cadence and lets the PD settle in between.
    trim_countdown: u32,
    /// What the torso is actually doing, for the readout - so the fix is visible rather than
    /// asserted.
    seen_roll: f32,
    seen_pitch: f32,
    /// -- *** A ROUTINE: PITCH AND YAW ROTATING TOGETHER, ROLL OSCILLATING SEPARATELY --
    ///
    /// Pitch and yaw driven in quadrature trace a CONE - the nose sweeps a circle - while roll
    /// rocks at its own frequency. Because the two rates are **incommensurate**, the combined
    /// attitude never exactly repeats, so nothing downstream can quietly learn the pattern
    /// instead of tracking it.
    ///
    /// * AND IT IS THE CASE WHERE A PLANNER SHOULD EARN ITS PLACE. The trim loop that fixed the
    /// static error is an INTEGRATOR: it converges to a constant target and lags a moving one,
    /// exactly like the PD on the tracking arm. A moving attitude command is where preview -
    /// the advantage that survived every ablation - has something to do.
    routine: bool,
    routine_clock: f32,
    cone_rate: f32,
    roll_rate: f32,
    cone_amount: f32,
    roll_amount: f32,
    /// * THE BODY ALSO BOBS, at a third incommensurate rate. Three frequencies with no common
    /// multiple means the pose never repeats, so the arm cannot be secretly tracking a cycle it
    /// has memorised - it has to counter the motion it is actually given.
    bob_rate: f32,
    bob_amount: f32,
    /// Mean and worst attitude error while the routine runs, so the lag is a number.
    routine_error_sum: f64,
    routine_error_count: u32,
    routine_worst: f32,
    /// -- *** SLIP AND FRICTION DEMAND, MEASURED LIVE --
    ///
    /// The feet slide and there was no way to see by how much, or to know why. Slip is how far
    /// the feet have travelled from where they were planted; the cone ratio is tangential force
    /// over what friction can actually supply, so **above 1.0 is a foot being asked for force
    /// the ground does not have.**
    ///
    /// Measured over the routine: about 1 m of slip in 12 s, cone exceeded at 1.83x. **A
    /// position controller has no representation of that limit - not a weak one, none** - which
    /// is why this readout exists, and why it is the number a planner would have to beat.
    /// -- *** THE ARM, AND WHY IT IS DRIVEN SEPARATELY --
    ///
    /// The arm reaches for a moving target with its own IK and its own PD, and the torso
    /// pipeline is left exactly as it was. **That separation is the experiment**: neither
    /// controller knows about the other, so whatever the arm does to the legs' contact forces
    /// arrives as a disturbance nobody planned for - which is the situation a force-allocating
    /// planner would be able to handle and a pair of independent servos cannot.
    arm_on: bool,
    arm_clock: f32,
    arm_rate: f32,
    arm_reach: f32,
    /// -- *** THE GRIPPER HOLDS A POINT IN THE WORLD WHILE THE BODY MOVES UNDER IT --
    ///
    /// A gimbal. The torso weaves through its cone, rocks, and bobs; the arm counter-animates so
    /// the gripper stays put. **The arm is not doing anything of its own** - every joint motion
    /// exists purely to cancel the base's.
    ///
    /// * AND IT IS THE IDEAL SHAPE FOR A PLANNER. The torso routine is SCRIPTED, so where the
    /// base will be a fraction of a second from now is known exactly - which makes the arm's
    /// required trajectory knowable in advance. That is preview, the one advantage that survived
    /// every ablation in this project.
    hold_point: Vec,
    /// Where the held point sits relative to the FOOT AVERAGE, in the ground plane.
    hold_offset: [2]f32,
    hold_height: f32,
    /// How far the gripper actually drifts from the point it is holding. The score.
    hold_error: f32,
    hold_worst: f32,
    arm_act: ctl.Actuation,
    gripper: u32,
    arm_target: []f32,
    arm_error: f32,
    foot_slip: f32,
    cone_worst: f32,
    cone_over: u32,
    font: z.Font,
    /// The pose being held - a copy of the `home` keyframe's `qpos`.
    home: []f32,
    /// Which DOFs have a motor. See `control`.
    actuated: []bool,
    /// Servo gains, live.
    kp: f32,
    kv: f32,
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
    peak_force: f32,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    const spliced: []u8 = try mjcfWithArm(gpa);
    defer gpa.free(spliced);
    s.doc = try z.codecs.xml.parse(gpa, spliced, null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    // * THE PROJECTILES JOIN THE ROBOT'S TREE, which is what makes them able to hit it.
    // A ball in zimrphysics alone would be resolved by a different solver treating the robot
    // as immovable - the exact approximation section 4k removed. In the tree, an impact is one
    // constraint between two inertias and the legs feel the real mass.
    var balls: [ball_count]z.robot_scene.FreeBody = undefined;
    for (0..ball_count) |i| {
        balls[i] = .{
            .name = ball_names[i],
            .pos = parkedBall(i),
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = ball_radius } }, .mass = 0.6 }},
        };
    }
    s.imported = try rmj.buildScene(gpa, &s.robot, &balls, .{
        .max_contacts = 128,
        .timestep = timestep,
        // Z-up, to match the model's own frame.
        .gravity = vec(0, 0, -9.81),
    });
    s.data = try rbt.Data.init(gpa, &s.imported.model);

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

    // * THE RESULT IS CHECKED. Discarding it is how the pose silently stopped being applied the
    // moment the arm changed `nq` - the humanoid's comment says exactly this and it happened
    // again anyway.
    if (!rmj.applyKeyframe(&s.imported.model, &s.data, s.robot.keyframes[0])) {
        std.log.err("quadruped: home keyframe refused — {d} numbers for nq {d}", .{
            s.robot.keyframes[0].qpos.len, s.imported.model.nq,
        });
    }
    rbt.forward(&s.imported.model, &s.data);
    s.bridge = try .init(gpa, &s.world, &s.imported.model, &s.data, 128);
    s.bridge.listen(&s.world);

    // -- *** A STIFFER CONTACT, WHICH CUTS THE FOOT CREEP 5.2x FOR FREE --
    //
    // The feet slide about a metre in twenty seconds while standing perfectly still, with the
    // friction demand at only 0.20 of the cone - creep, not slip, so more friction would raise a
    // limit that is never reached.
    //
    // Measured over 20 static seconds, slide and cost together:
    //
    //     as shipped (0.9/0.95, width 1e-3)   0.8097 m   301,988 ns/step
    //     tolerance 1e-8 and 1e-10            0.8097 m   (identical - not the lever)
    //     stiff + narrow (0.99, width 1e-4)   0.1545 m   301,854 ns/step
    //
    // ** THE COST IS A WASH - 301,854 against 301,988, inside the noise. No extra iterations, no
    // new state: the same arithmetic with a different constant. **A stiffer constraint leaves
    // less residual velocity per step, and it is that residual which integrates into creep.**
    //
    // * AND THE CONE OCCUPANCY STAYS AT 0.24, well inside its limit - the creep did not stop by
    // trading itself for friction saturation, which was the failure mode worth guarding against.
    // The robot is still held by grip it would really have.
    //
    // This is MuJoCo's `impratio` idea reached from the other end: it stiffens friction relative
    // to normal, and on a PYRAMID basis - where no row is purely frictional - stiffening the
    // whole contact is the version actually available.
    s.bridge.flesh.thickness_m = 0.0001;
    s.bridge.flesh.soft_min = 0.99;

    // * THE FULL `qpos`, NOT THE KEYFRAME. `home` is indexed by the model's qpos addresses, and
    // a keyframe covers only the robot's prefix - the balls come after it. Sized from the
    // keyframe, a short one let `control` index past the end, and `resetEverything`'s
    // `@memcpy(s.home, s.data.pos)` trapped on the length mismatch (23 against 65).
    s.home = try gpa.dupe(f32, s.data.pos);

    // * WHICH DOFs HAVE A MOTOR, decided once. The trunk's free joint does not, and
    // forgetting that makes the robot FLY - gravity compensation on an unactuated DOF cancels
    // the machine's own weight. Third time this rule has come up; computing it here instead
    // of testing `jnt_type` inline is how it stops coming up.
    s.actuated = try gpa.alloc(bool, s.imported.model.nv);
    @memset(s.actuated, false);
    for (0..s.imported.model.njnt) |j| {
        if (s.imported.model.jnt_type[j] == .hinge) {
            s.actuated[s.imported.model.jnt_dof_adr[j]] = true;
        }
    }

    // * THE GENERATED CYLINDER SPANS z in [0, height], NOT [-h/2, +h/2]. Its parametric
    // surface is `(r*sin theta, r*cos theta, height*u)` with `u in [0,1]`, so a unit cylinder sits
    // entirely ABOVE the origin. Scaling it to a capsule's length therefore offsets every
    // limb by half its own length - legs that float away from their joints. Generating it
    // pre-centred is one number here and saves a translate in every draw.
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 10, 8);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.transform = .{identity()};
    s.cam = z.OrbitCamera.init(vec(0, 0.25, 0), 1.4);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);

    // -- * ONE IK MASK AND ONE PINNED FOOT PER LEG --
    //
    // The foot is the sphere geom at the end of each calf. Its planted position is captured
    // from the STANDING pose, so "hold the feet still" means where the robot actually put
    // them rather than where the model nominally says they go.
    const leg_tips = [4][]const u8{ "FR_calf", "FL_calf", "RR_calf", "RL_calf" };
    for (leg_tips, 0..) |name, i| {
        const body: u32 = s.imported.bodyIndex(name).?;
        s.foot_body[i] = body;
        s.legs[i] = try ctl.limbActuation(gpa, &s.imported.model, body);
        var offset: Vec = zm.vec_zero;
        for (0..s.imported.model.ngeom) |g| {
            if (s.imported.model.geom_body[g] != body) {
                continue;
            }

            // -- * THE ARM'S OWN ACTUATION MASK AND TARGET BUFFER --
            //
            // `limbActuation` walks the chain from the gripper to the root, so the mask covers exactly
            // the four arm joints and nothing else - the legs stay under the torso controller, which is
            // what keeps the two problems separate and the experiment honest.
            s.gripper = s.imported.bodyIndex("gripper") orelse 0;
            s.arm_act = try ctl.limbActuation(gpa, &s.imported.model, s.gripper);
            s.arm_target = try gpa.alloc(f32, s.imported.model.nq);
            @memcpy(s.arm_target, s.data.pos[0..s.imported.model.nq]);
            switch (s.imported.model.geom_shape[g]) {
                // The foot is the sphere at the end of the calf; its offset in the body's
                // frame is what makes the planted point the FOOT rather than the calf's origin.
                .sphere => offset = s.imported.model.geom_pos[g],
                else => {},
            }
        }
        s.foot_offset[i] = offset;
    }
    s.ik_scratch = try gpa.alloc(Vec, ctl.Ik.scratchSize(&s.imported.model));
    s.body_roll = 0;
    s.body_pitch = 0;
    s.body_yaw = 0;
    s.body_height = 0;
    s.posing = false;
    s.pose_error = 0;
    s.gait_on = false;
    s.arm_swing_amp = 0.0;
    s.arm_lift_amp = 0.7;
    s.arm_lift_rate = 0.11;
    s.arm_swing_phase = 0.75;
    s.gait_phase = 0;
    // -- * SWEPT AGAINST DISTANCE TRAVELLED, NOT CHOSEN --
    //
    // With the stance direction corrected, 10 s of trot on stiffened contacts:
    //
    //     hz 1.4  stride 0.10  duty 0.65   -0.21 m   (too short a stride to propel)
    //     hz 1.4  stride 0.16  duty 0.65   +1.04 m
    //     hz 2.0  stride 0.16  duty 0.60   **+1.43 m**   <- best
    //     hz 2.4  stride 0.20  duty 0.55   +0.17 m   (too fast: less time in stance)
    //
    // * THE STRIDE MATTERS MORE THAN THE RATE. 0.06 m - the old default - is small enough that
    // the feet barely displace the body at all, which is part of why the gait read as "very
    // slow" independently of its direction.
    // WIP AND THE SWEEP ABOVE WAS RUN ON A **BARE GO1**. This robot carries a 1.94 kg arm high on
    // the trunk, which the probe never had - so those distances describe a different machine.
    // Taking the best row from it and raising the stride 2.7x (0.06 -> 0.16) tipped the real
    // demo over backwards immediately.
    //
    // *** THREE PARAMETERS CHANGED AT ONCE, FROM A MEASUREMENT OF SOMETHING ELSE. Each part of
    // that is a mistake on its own: a sweep on the wrong model, and no isolation between the
    // sign fix (which is certainly right) and the tuning (which was not tested here).
    //
    // Backed off to a stride only slightly above the original, with the CORRECTED direction -
    // so the sign fix is kept and the untested tuning is not. **The sliders are live; sweep them
    // on this robot rather than trusting numbers from the other one.**
    // *** MEASURED FORWARD **WITH THE ARM**, which the earlier sweep was not. Trot, 10 s:
    //
    //     hz 2.0  stride 0.16  duty 0.60   **+0.567 m**  stands (z 0.298)
    //     hz 1.6  stride 0.08  duty 0.75     -0.931 m    stands, backward
    //
    // * THE SECOND ROW IS WHAT THIS WAS BACKED OFF TO LAST TURN, on the strength of a probe
    // whose edit had failed - so its output was a STALE binary's. **The two settings were
    // exactly the wrong way round**, and the stale-binary trap cost a real conclusion.
    s.gait_hz = 1.4;
    // *** 0.20, MEASURED - 3.2x FURTHER THAN 0.14 AND STILL SOLID. Crawl, 10 s:
    //
    //     hz 1.4  stride 0.14   0.207 m   z 0.302
    //     hz 1.4  stride 0.20  **0.655 m**  z 0.307   <- this
    //     hz 1.4  stride 0.26  FELL at 2.96 s
    //     hz 2.0  stride 0.20   0.134 m   (faster is WORSE)
    //     hz 2.5  stride 0.20  FELL at 1.87 s
    //
    // * STRIDE IS THE LEVER AND RATE IS NOT. Raising `hz` shortens the time each foot has to
    // settle before the next one lifts, and on a crawl that is the whole margin - 2.0 costs
    // two thirds of the distance and 2.5 falls over. **Longer steps, not faster ones.**
    s.gait_stride = 0.20;
    // *** 0.08, AND IT NEARLY TRIPLES THE DISTANCE. Foot lift decides whether a swinging foot
    // CLEARS or catches, and a catch on a top-heavy robot is a trip. Measured at amp 0.3 /
    // phase 0.75 / hz 2.0 / stride 0.16 / duty 0.60:
    //
    //     lift 0.03   0.379 m
    //     lift 0.05   0.843 m
    //     lift 0.08   **0.957 m**
    //     lift 0.12   FELL
    //
    // ** AND AT 0.08 THE ARM SWING BECOMES NECESSARY RATHER THAN MERELY HELPFUL: with
    // `arm_swing_amp` at zero the robot **falls at 6.22 s**. That is the demonstrated failure
    // the arm was missing - for the first time it fixes something instead of not hurting.
    s.gait_lift = 0.06;
    // -- ** DUTY IS THE WHOLE DIFFERENCE BETWEEN STANDING UP AND FALLING OVER --
    //
    // Duty is the fraction of the cycle a foot spends ON THE GROUND. Measured on the Go1,
    // trotting at 1.6 Hz, over ten seconds:
    //
    //     duty 0.50  ->  sags to 0.11 m, on its belly
    //     duty 0.70  ->  falls at 2.5 s
    //     duty 0.85  ->  z 0.346, minimum 0.332 - no sag at all
    //
    // At 0.5 a trot has only two feet down at any instant and the Go1 cannot hold itself up
    // on a diagonal pair for that long. 0.85 keeps three or four down almost always, which is
    // a cautious gait and a standing one.
    // * 0.60, measured with the arm present rather than reasoned about without it.
    s.gait_duty = 0.80;
    // Trot: diagonal pairs together. Leg order is FR, FL, RR, RL.
    // *** THE CRAWL IS THE DEFAULT because it is the one that never falls. The trot travels 4.6x
    // further (0.957 m against 0.207) and is one button away - but it is fragile, needs the arm's
    // counter-swing, and topples if the attitude trim is left on. **"Move and do not fall" is the
    // goal, and three feet down is how a robot does that.**
    //
    // * THE PHASING AND THE TIMINGS MUST MATCH. Crawl offsets at trot rate and duty fall over;
    // that mismatch is exactly what earned this pattern a "(falls)" label it did not deserve.
    s.gait_offset = .{ 0.0, 0.5, 0.25, 0.75 };
    s.pose_scratch = try gpa.alloc(f32, s.imported.model.nq);
    s.rest_height = s.data.pos[s.imported.model.jnt_qpos_adr[0] + 2];
    s.rest_rot = zm.quat_identity;
    s.stance = try gpa.alloc(f32, s.imported.model.nq);
    s.last_cmd = .{ 0, 0, 0, 0 };
    s.trim_roll = 0;
    s.trim_pitch = 0;
    s.trim_countdown = 0;
    s.seen_roll = 0;
    s.seen_pitch = 0;
    // *** ON BY DEFAULT. The demo's whole argument is a robot weaving while a gripper hangs
    // motionless in space, and that required two clicks to see. A demo that idles until clicked
    // gets seen once - and its smoke test verifies an idle scene, which is how three bugs hid
    // in `examples/catch`.
    s.routine = true;
    s.routine_clock = 0;
    // * INCOMMENSURATE ON PURPOSE - 0.55 and 0.31 have no small common multiple, so the pattern
    // drifts forever instead of closing into a short loop.
    // * FOUR INCOMMENSURATE RATES, AND THE GAIT'S 1.4 IS DELIBERATELY NOT AMONG THEM. A torso
    // motion locked to the footfall reads as a limp; one that drifts against it reads as
    // dancing, and never repeats.
    s.cone_rate = 0.31;
    s.roll_rate = 0.23;
    // * MEASURED TO STAND. cone/roll/bob of 0.22/0.20/0.035 also stands but drifts 29 mm; this
    // middle setting holds the gripper to 20 mm and still weaves visibly.
    // *** THE MEASURED EDGE: 0.14 rad of roll and pitch (8 degrees), 3.5 cm of bob, and a big
    // slow arm sweep - the largest amplitudes that still WALK. 0.18 falls at 6.42 s.
    s.cone_amount = 0.14;
    s.roll_amount = 0.14;
    s.bob_rate = 0.17;
    s.bob_amount = 0.035;
    s.routine_error_sum = 0;
    s.routine_error_count = 0;
    s.routine_worst = 0;
    s.arm_on = true;
    s.arm_clock = 0;
    s.arm_rate = 0.35;
    s.arm_reach = 0.34;
    s.hold_point = vec(0, 0, 0);
    s.hold_offset = .{ 0.22, 0 };
    s.hold_height = 0.62;
    s.hold_error = 0;
    s.hold_worst = 0;
    s.arm_error = 0;
    s.foot_slip = 0;
    s.cone_worst = 0;
    s.cone_over = 0;
    s.kp = 100.0;
    // -- *** SIX, NOT TWO. THE DAMPING RATIO WAS OFF AND THE FEET PAID FOR IT --
    //
    // `kv = 2` against `kp = 100` is badly underdamped: the ratio-preserving value is about 6.
    // An underdamped leg oscillates about its target, and an oscillating foot alternately grips
    // and breaks away - which is a better account of "the feet slide" than stiffness alone.
    //
    // Measured over the 12 s routine, total foot slip and friction-cone violations:
    //
    //     kp 100, kv  2    slip 1.079 m   2452 ticks over the cone   <- was
    //     kp 100, kv  6    slip 0.945 m   2217 ticks               <- now
    //     kp 100, kv 12    slip 21.75 m   7206 ticks   (overdamped, far worse)
    //     kp 200, kv  8    slip 2.813 m   7838 ticks
    //
    // * AND BOTH DIRECTIONS ARE WORSE, which is what makes this a minimum rather than a guess.
    // Stiffer slides more; much softer slides more; only the damping ratio was actually wrong.
    s.kv = 6.0;
    s.next_ball = 0;
    s.want_throw = false;
    s.accumulator = 0;
    s.physics_on = true;
    s.peak_force = 0;
}

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.arm_target);
    s.arm_act.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    gpa.free(s.stance);
    gpa.free(s.pose_scratch);
    gpa.free(s.ik_scratch);
    for (&s.legs) |*leg| {
        leg.deinit();
    }
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
    gpa.free(s.actuated);
    gpa.free(s.home);
    s.bridge.deinit(&s.world);
    s.world.deinit(gpa);
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
}

/// Hold the home pose.
///
/// -- ** PLAIN PD, NOT COMPUTED TORQUE, and the reason is the floating base --
///
/// `tau = M*a*` is the right controller for an arm bolted to a table, and it is what `robot_3d`
/// uses. It cannot work here. The mass matrix spans the trunk's six unactuated DOFs, so
/// solving it produces accelerations the trunk has no motor to make; zeroing those rows
/// afterwards leaves the legs supplying a difference nobody asked for. **Measured: the robot
/// folded to 0.08 m against a 0.27 m home** - which looks exactly like a gains problem and is
/// not one.
///
/// What the Go1's own file describes is simpler and correct: a position servo per joint,
/// clamped to that joint's force rating.
/// Move the torso to the commanded pose while every foot stays where it stands.
///
/// -- ** THE STANDARD QUADRUPED TRICK, AND WHY IT WORKS --
///
/// A torso has no motors. It cannot be commanded anywhere. But it is standing on four legs
/// whose feet are on the ground, so **moving the body is the same problem as moving four
/// hips while four feet hold still** - and that IS a joint-space problem, three joints at a
/// time.
///
/// So: write the wanted torso pose straight into the free joint, then ask each leg on its own
/// to put its foot back where it was. The result is a full `qpos` the PD controller can hold,
/// and the legs physically push the body into place because the feet have friction.
///
/// -- * THE SOLVE RUNS ON A COPY --
///
/// `Ik.solve` writes joint angles into `data` - it IS the answer. Doing that to the live state
/// would teleport the robot every frame: no dynamics, no contact, no falling over when the
/// pose is impossible. The result becomes a TARGET instead, so the robot travels there under
/// its own torque limits and can fail to arrive.
/// Capture where the feet are standing and how high the torso is, as the reference the
/// sliders are relative to.
///
/// ** THIS HAPPENS WHEN POSING IS SWITCHED ON, NOT AT STARTUP, and the difference is the
/// whole thing working or not. At startup the robot is at its `home` keyframe and has not
/// touched the ground yet; it then settles and **rises from 0.270 to 0.332** as the legs take
/// its weight. Feet captured before that are 6 cm below where the robot actually stands, so
/// the first solve asks every leg to stretch down to a floor that is no longer there - and
/// the robot folds flat, which reads as the pose controller being broken.
///
/// Capturing on activation also makes the sliders mean the obvious thing: zero is wherever
/// the robot was when you ticked the box.
fn captureStance(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    rbt.forward(m, &s.data);
    for (0..4) |i| {
        const body: u32 = s.foot_body[i];
        s.planted[i] = s.data.body_xpos[body] + zm.rotate(s.data.body_xrot[body], s.foot_offset[i]);
        // * AND THE SAME POINT IN THE TORSO'S FRAME, which is what a gait cycles around.
        s.foot_rest[i] = zm.rotate(
            zm.conjugate(s.data.body_xrot[1]),
            s.planted[i] - s.data.body_xpos[1],
        );
    }
    s.rest_height = s.data.pos[m.jnt_qpos_adr[0] + 2];
    s.rest_rot = s.data.body_xrot[1];
    @memcpy(s.stance, s.data.pos);
    s.last_cmd = .{ 1e9, 0, 0, 0 }; // force one solve
    // * THE TRIM RESETS WITH THE STANCE. It is an integrator, and an integrator carried across
    // a teleport is the same class of stale state as a warm start nobody cleared.
    s.trim_roll = 0;
    s.trim_pitch = 0;
    s.trim_countdown = 0;
    s.body_roll = 0;
    s.body_pitch = 0;
    s.body_yaw = 0;
    s.body_height = 0;
}

/// Where a foot should be at a given point in its cycle, in the stance frame.
///
/// -- ** A GAIT IS A FOOT TRAJECTORY AND FOUR PHASE OFFSETS --
///
/// Each leg runs the same cycle and they differ only in WHERE IN IT they are:
///
///   * **stance** (`phase < duty`) - the foot is on the ground and travels straight backwards
///     under the body. This is what actually moves the robot: the body goes forward because
///     the planted foot goes back.
///   * **swing** (`phase >= duty`) - the foot lifts and arcs forward to where stance will
///     start again.
///
/// * AND THE FAMOUS GAITS ARE THE SAME FUNCTION WITH DIFFERENT OFFSETS. Trot moves diagonal
/// pairs together (0, 0.5, 0.5, 0); pace moves the legs on each side together (0, 0.5, 0,
/// 0.5); bound moves front and back pairs (0, 0, 0.5, 0.5); walk spreads them evenly at
/// quarters. **Four numbers, not four algorithms** - which is worth seeing rather than being
/// told.
fn footOffsetInCycle(phase: f32, stride: f32, lift: f32, duty: f32) Vec {
    const wrapped: f32 = phase - @floor(phase);
    if (wrapped < duty) {
        // -- *** STANCE: THE FOOT TRAVELS BACKWARD RELATIVE TO THE BODY --
        //
        // `t` runs 0 to 1, so `0.5 - t` runs +stride/2 to -stride/2: the planted foot moves
        // backward under the body, and the body is carried forward. That is what walking is.
        //
        // ** THIS WAS `stride * (t - 0.5)` - the opposite - while the comment above it claimed
        // this behaviour. **A comment describing the intent while the code did the reverse**,
        // which is the third time in this project that a comment and its code disagreed and the
        // comment turned out to be the correct statement of what was wanted.
        //
        // Measured over 10 s, trot, with the stiffened contacts:
        //
        //     as written    hz 2.4  stride 0.20   **-5.25 m** (backward)
        //     as written    hz 2.0  stride 0.16   -3.85 m
        //     corrected     hz 2.0  stride 0.16   **+1.43 m** (forward)
        //
        // * AND THE OLD NOTE RECORDED ONLY "about half a metre backwards", which is why this
        // read as slipping rather than as a sign error. **The contact stiffening from the creep
        // work is what made the feet grip**; once they gripped, a weak ambiguous drift became
        // unmistakable propulsion in the wrong direction.
        const t: f32 = wrapped / duty;
        return vec(stride * (0.5 - t), 0, 0);
    }
    // Swing: forward again, lifting in an arc that starts and ends at ground level.
    const t: f32 = (wrapped - duty) / (1.0 - duty);
    // A HALF turn across the swing: zero at lift-off, zero at touch-down, peak in the
    // middle. `t` is already the fraction of the swing, so the `* pi` was only ever
    // there to reach `@sin`.
    return vec(stride * (t - 0.5), 0, lift * sinTurns(t * 0.5));
}

/// Drive a gait by moving each foot's IK target around its cycle.
///
/// -- *** WHAT THIS IS, AND WHAT IT IS NOT --
///
/// This is an OPEN-LOOP gait: the feet trace a fixed cycle and the robot stays upright. It is
/// the simplest thing that deserves the name, and it demonstrates the stack - per-leg IK,
/// contact, a torque-limited controller - end to end.
///
/// **It does not propel the robot properly.** Measured over ten seconds it drifts about half a
/// metre BACKWARDS whichever way the stance direction is set, which means the feet are slipping
/// through stance rather than gripping and pushing. The reason is structural rather than a
/// tuning miss: **the torso is commanded at its captured stance pose every frame**, so the legs
/// are always solving to put the body back where it started. The gait modulates the feet while
/// the body command quietly fights any forward motion they produce.
///
/// Making it walk properly means commanding the body FORWARD as well - a velocity to track
/// rather than a pose to hold - and then the foot placement has to respond to where the body
/// actually got to. That is a controller with feedback, which is what MPC and a learned policy
/// both are, and is the right place to solve it rather than here.
///
/// * THIS IS `solveBodyPose` WITH TARGETS THAT MOVE. The body-pose controller already holds
/// four feet at commanded world positions through per-leg IK; a gait commands different
/// positions each frame. That the two share everything is not a coincidence - standing is a
/// gait whose feet happen not to go anywhere.
/// Put the whole scene back exactly as it started.
///
/// -- *** WHAT "EVERYTHING" TURNED OUT TO MEAN --
///
/// Three attempts at this button failed, each because something ELSE remembered where things
/// had got to. Written out, because the list is longer than it looks and every omission
/// produced a different confusing symptom:
///
///   * **`home`** - what the PD controller tracks. Teleporting `data.pos` alone puts the robot
///     at the keyframe for exactly one frame before the controller drags it back, which reads
///     as the button doing nothing.
///   * **Velocities** - a robot reset mid-fall keeps its downward speed and falls again from
///     the new position, which looks like the reset placing it badly.
///   * **The PROJECTILES.** This was the one that actually exploded. Thrown balls are free
///     bodies in the same tree and stay where they landed; put the robot back at the origin
///     and it materialises INSIDE whichever ball came to rest there. Deep overlap, enormous
///     restoring force, robot across the map.
///   * **The gait and pose modes** - left running, the next frame immediately commands a
///     walking pose and the keyframe is never seen.
///   * **The captured stance** - what the sliders and the gait are relative to.
///   * **The warm start and the accumulator** - the solver's carried forces, and any physics
///     substeps the frame still owed.
///
/// * AND THE ROBOT GOES BACK TO THE ORIGIN. An earlier version kept its position and heading,
/// on the theory that "reset" means "stand up here". It does not: it means put it back.
/// Put the arm back to its half-bent rest, in `s.data.pos` and in the commanded `s.home`.
///
/// * HALF BENT IS A CHOICE WITH A REASON: it leaves 2.4 rad of travel each way, so the arm can
/// swing in either direction. Folded or extended, it can only help one way - and the gait's
/// counter-swing needs both halves of the cycle.
/// The arm's rest pose, root to tip: yaw, shoulder, elbow, wrist.
///
/// -- ** HALF BENT IS A CHOICE WITH A REASON --
///
/// It leaves roughly 2.4 rad of travel each way, so the shoulder can sweep in both directions
/// without approaching a stop. **An arm at its limit is dead weight at maximum lever arm** -
/// the failure that saturated every balance attempt in this example's history - and both the
/// gait's counter-swing and the routine's slow lift need room on either side.
const arm_rest = [_]f32{ 0.0, 1.1, -1.6, 0.5 };
/// The shoulder's rest angle, which the gait and routine sweep around.
const arm_rest_shoulder: f32 = arm_rest[1];

/// The `qpos` index of the arm's `n`th joint, counting root to tip, or null if there is none.
///
/// -- *** IDENTIFIED BY ACTUATION MASK, NEVER BY NAME --
///
/// An earlier version matched `s.robot.joints[j].name` using the MODEL's joint index `j`.
/// **Those are two different orderings** - `robot.joints` is MJCF parse order, `j` is the
/// importer's - so the comparison silently matched nothing, the arm kept its old pose, and a
/// control signal went into whatever joint sat at that index. It compiled, linted and passed
/// every gate.
///
/// * `limbActuation` FROM THE GRIPPER ALREADY MARKS EXACTLY THE ARM'S DOFS, and the gimbal's IK
/// uses it - so it is verified by a feature that visibly works. **When the lookup you want does
/// not exist, reach for a structure already proven by something else.**
fn armJointQ(s: *const State, n: usize) ?u32 {
    const m: *const rbt.Model = &s.imported.model;
    var seen: usize = 0;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const v: u32 = m.jnt_dof_adr[j];
        if (v >= m.nv or !s.arm_act.powered[v]) {
            continue;
        }
        if (seen == n) {
            return m.jnt_qpos_adr[j];
        }
        seen += 1;
    }
    return null;
}

fn armShoulderQ(s: *const State) ?u32 {
    return armJointQ(s, 1);
}

/// Put the arm back to its rest pose, in both the simulated state and the commanded one.
fn setArmRest(s: *State) void {
    for (arm_rest, 0..) |angle, n| {
        const q: u32 = armJointQ(s, n) orelse continue;
        s.data.pos[q] = angle;
        s.home[q] = angle;
    }
    s.data.stage = .stale;
}

fn resetEverything(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;

    // The robot: its home keyframe, at the origin, exactly as built.
    if (!rmj.applyKeyframe(m, &s.data, s.robot.keyframes[0])) {
        std.log.err("quadruped: home keyframe refused on reset", .{});
    }

    // * THE BALLS, BACK ON THEIR SHELF. `applyKeyframe` deliberately writes only the robot's
    // slice - a ball in flight has no business being teleported by a pose button - so the free
    // bodies are put back here, one free joint at a time.
    for (0..ball_count) |i| {
        const body: u32 = s.imported.bodyIndex(ball_names[i]) orelse continue;
        const j: u32 = m.body_jnt_adr[body];
        const q: u32 = m.jnt_qpos_adr[j];
        const parked: Vec = parkedBall(i);
        s.data.pos[q + 0] = parked[0];
        s.data.pos[q + 1] = parked[1];
        s.data.pos[q + 2] = parked[2];
        s.data.pos[q + 3] = 0;
        s.data.pos[q + 4] = 0;
        s.data.pos[q + 5] = 0;
        s.data.pos[q + 6] = 1;
    }
    s.next_ball = 0;
    s.want_throw = false;

    // Nothing is moving, nothing is touching, and the solver remembers nothing.
    @memset(s.data.vel, 0);
    @memset(s.data.acc, 0);
    @memset(s.data.applied_force, 0);
    s.data.clearContacts();
    s.data.forgetWarmStart();
    s.data.stage = .stale;
    rbt.forward(m, &s.data);

    // What the controller tracks, and the modes that would immediately overwrite it.
    @memcpy(s.home, s.data.pos);
    s.gait_on = false;
    s.posing = false;
    s.gait_phase = 0;

    // -- *** AND THE ARM, WHICH "EVERYTHING" HAS TO INCLUDE --
    //
    // The padded keyframe carries the half-bent pose, but the GIMBAL will re-solve the arm on
    // the very next frame if it is left on - so the reset has to clear the mode as well as the
    // angles, or the arm snaps straight back to wherever it was holding.
    //
    // * AND `hold_point` IS A CAPTURED WORLD POSITION. Left alone it survives the reset and the
    // arm reaches for a point relative to feet that have moved - the same stale-anchor problem
    // that made the gimbal drift, arriving through the reset path instead.
    s.arm_on = false;
    s.hold_point = vec(0, 0, 0);
    s.hold_error = 0;
    s.hold_worst = 0;
    s.routine = false;
    s.routine_clock = 0;
    s.routine_error_sum = 0;
    s.routine_error_count = 0;
    s.routine_worst = 0;
    s.trim_roll = 0;
    s.trim_pitch = 0;
    s.trim_countdown = 0;
    s.body_roll = 0;
    s.body_pitch = 0;
    s.body_yaw = 0;
    s.body_height = 0;
    s.foot_slip = 0;
    s.cone_worst = 0;
    s.cone_over = 0;
    setArmRest(s);

    // * AND THE OWED SUBSTEPS. The accumulator can be holding most of a frame's worth of
    // physics; left alone, the reset is immediately followed by a burst of steps that runs the
    // scene forward before anyone sees it.
    s.accumulator = 0;
    s.peak_force = 0;

    // * AND THE BRIDGE IS TOLD THIS WAS A TELEPORT. It cannot tell by looking - a proxy that
    // was there and is now here looks the same whether it travelled or was moved - and a swept
    // contact across the gap finds the floor and fires the robot away. See `Bridge.teleported`.
    s.bridge.teleported();

    captureStance(s);
}

/// Solve every hinge for a commanded torso pose and a set of foot goals, and write the answer
/// into `s.home`.
///
/// -- *** THE ONE SHAPE BOTH SOLVERS HAD --
///
/// `solveGait` and `solveBodyPose` were written independently and converged on exactly the same
/// six steps: save `data.pos`, seed a pose, plant the torso, IK four legs, harvest the hinges
/// into `home`, restore. **They differed only in the seed and the foot goals** - everything else
/// was duplicated, including two subtle invariants that are easy to get wrong in one copy and
/// not the other.
///
/// * THE FIRST INVARIANT: `data.pos` IS SCRATCH HERE, NOT STATE. Both solvers use the live pose
/// array as an IK workspace and must put it back - a solve that leaks into the simulated state
/// teleports the robot. The save/restore is the reason this is a function rather than inline
/// code in two places.
///
/// ** THE SECOND: SEED FROM A COMMAND, NEVER FROM THE MEASURED ROBOT. `solveBodyPose`'s own
/// comment records why - seeding from where the robot actually got to closes a feedback loop
/// through the IK, and the pose walks away from itself. Both callers pass a command.
fn solveLegsInto(
    s: *State,
    seed: []const f32,
    ground: Vec,
    attitude: zm.Quat,
    height: f32,
    goals: [4]Vec,
) f32 {
    const m: *const rbt.Model = &s.imported.model;
    const saved: []f32 = s.pose_scratch;
    @memcpy(saved, s.data.pos);

    // -- *** ONLY THE HINGES COME FROM THE SEED; THE ROOT'S GROUND POSITION IS A PARAMETER --
    //
    // A full `@memcpy` of the seed was a refactor regression that cost a working gait. The gait
    // computes its foot goals from the LIVE torso position, then seeds from `home` - whose root
    // x/y is wherever the command was last written, which is stale. **The legs then solve for a
    // body that is not where the goals assume it is**, and the robot dances in place and falls.
    //
    // * THE TWO CALLERS GENUINELY DIFFER HERE, which is why this is an argument rather than a
    // convention: the gait wants the LIVE ground position (the body is moving and the goals
    // follow it), and posing wants the STANCE one (the body returns to where it was captured).
    // Collapsing that difference is exactly what broke it.
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        s.data.pos[q] = seed[q];
    }
    const root: u32 = m.jnt_qpos_adr[0];
    s.data.pos[root + 0] = ground[0];
    s.data.pos[root + 1] = ground[1];
    s.data.pos[root + 2] = height;
    s.data.pos[root + 3] = attitude[0];
    s.data.pos[root + 4] = attitude[1];
    s.data.pos[root + 5] = attitude[2];
    s.data.pos[root + 6] = attitude[3];
    s.data.stage = .stale;

    var worst: f32 = 0;
    for (0..4) |i| {
        const result: ctl.Ik.Result = (ctl.Ik{ .max_iterations = 12, .max_step = 0.5 }).solve(
            m,
            &s.data,
            s.legs[i],
            .{ .body = s.foot_body[i], .offset = s.foot_offset[i], .goal = goals[i] },
            s.ik_scratch,
        );
        worst = @max(worst, result.error_distance);
    }
    return worst;
}

/// Copy every hinge from the scratch pose into `s.home`, then restore the simulated state.
///
/// * SPLIT FROM `solveLegsInto` BECAUSE THE GAIT WRITES THE ARM IN BETWEEN - the shoulder's
/// swing has to land after the legs are solved and before the pose is harvested, which is the
/// ordering bug that once made the arm's motion silently disappear.
fn harvestPose(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        s.home[q] = s.data.pos[q];
    }
    @memcpy(s.data.pos, s.pose_scratch);
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
}

fn solveGait(s: *State, dt: f32) void {
    s.gait_phase += dt * s.gait_hz;
    s.gait_phase -= @floor(s.gait_phase);

    // -- *** FOOT TARGETS ARE BODY-RELATIVE, NOT WORLD-FIXED --
    //
    // A gait's cycle is relative to the HIP. During stance the foot travels backwards relative
    // to the body by one stride while the body advances by one - so the foot stays put in the
    // world without anyone pinning it there. **Pinning it in world coordinates fights that**:
    // the first version did, and the robot walked 1.1 m and arrived on its belly, legs stretched
    // out behind toward targets that never moved.
    const torso_pos: Vec = s.data.body_xpos[1];
    const torso_rot: zm.Quat = s.data.body_xrot[1];
    var goals: [4]Vec = undefined;
    for (0..4) |i| {
        const cycle: Vec = footOffsetInCycle(
            s.gait_phase + s.gait_offset[i],
            s.gait_stride,
            s.gait_lift,
            s.gait_duty,
        );
        goals[i] = torso_pos + zm.rotate(torso_rot, s.foot_rest[i] + cycle);
    }

    // * THE COMMANDED ATTITUDE RIDES THE GAIT. Feedforward only: the legs solve for the pose the
    // sliders ask for, and nothing measures the result and corrects it. That distinction is why
    // walking and posing can combine - the attitude TRIM, which does measure and correct, topples
    // the robot in under two seconds because a walking robot's pitch is not an error to remove.
    const posed: zm.Quat = commandedAttitude(s);
    // * THE LIVE GROUND POSITION: the body is travelling and the foot goals were built around
    // where it actually is.
    s.pose_error = solveLegsInto(s, s.home, torso_pos, posed, s.rest_height + s.body_height, goals);

    // ** THE ARM IS WRITTEN BETWEEN THE SOLVE AND THE HARVEST, which is the only correct place:
    // after the legs have used the scratch pose, before it is copied into `home`.
    if (armShoulderQ(s)) |q| {
        var shoulder: f32 = arm_rest_shoulder;
        // The trot's counter-swing, locked to the gait clock. Zero for a crawl, which has no
        // wobble to cancel and is measurably worse with one.
        if (s.arm_swing_amp != 0) {
            shoulder += s.arm_swing_amp * sinTurns(s.gait_phase + s.arm_swing_phase);
        }
        // * AND THE SLOW RISE AND FALL, on its own incommensurate clock. It sweeps around the
        // half-bent rest so the shoulder never nears a stop - which is what turned the arm into
        // dead weight at maximum lever arm in every earlier balance attempt.
        if (s.routine and s.arm_lift_amp != 0) {
            shoulder += s.arm_lift_amp * sinTurns(s.routine_clock * s.arm_lift_rate);
        }
        s.data.pos[q] = shoulder;
    }
    harvestPose(s);
}

/// The torso attitude the sliders and the routine are asking for.
fn commandedAttitude(s: *const State) zm.Quat {
    return zm.qmul(
        zm.qmul(
            zm.quatFromAxisAngle(vec(0, 0, 1), s.body_yaw),
            zm.quatFromAxisAngle(vec(0, 1, 0), s.body_pitch + s.trim_pitch),
        ),
        zm.qmul(zm.quatFromAxisAngle(vec(1, 0, 0), s.body_roll + s.trim_roll), s.rest_rot),
    );
}

fn solveBodyPose(s: *State) void {
    // * THE FEET STAY WHERE THEY WERE PLANTED, in world coordinates - the opposite of the gait,
    // and correct for the opposite reason: a posing robot's body moves while its feet do not.
    // * THE STANCE GROUND POSITION: a posing robot returns to where it was captured, and its
    // planted feet are in world coordinates around that point.
    const root: u32 = s.imported.model.jnt_qpos_adr[0];
    s.pose_error = solveLegsInto(
        s,
        s.stance,
        vec(s.stance[root], s.stance[root + 1], 0),
        commandedAttitude(s),
        s.rest_height + s.body_height,
        s.planted,
    );
    harvestPose(s);
}

fn control(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    @memset(s.data.applied_force, 0);
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        const v: u32 = m.jnt_dof_adr[j];
        const wanted: f32 = s.kp * (s.home[q] - s.data.pos[q]) - s.kv * s.data.vel[v];
        // * The clamp is the motor's rating, and it is what makes the kp slider mean
        // something: without it, any gain eventually wins and the robot is infinitely strong.
        s.data.applied_force[v] = clamp(wanted, -35.55, 35.55) + s.data.bias_force[v];
    }
}

/// Throw a ball at the robot, from wherever the camera is looking from.
///
/// * AIMED FROM THE CAMERA, so "throw" means what it looks like it means: the ball leaves the
/// viewer's position and travels toward the robot's centre. A fixed launch direction would be
/// unusable the moment the view is orbited, which on a phone is immediately.
fn throwBall(s: *State, cam: Camera3D) void {
    const m: *const rbt.Model = &s.imported.model;
    const body: u32 = s.imported.bodyIndex(ball_names[s.next_ball]) orelse return;
    s.next_ball = (s.next_ball + 1) % ball_count;

    // -- ** FROM THE EYE, ALONG THE VIEW - not at a fixed point --
    //
    // This aimed at `(0, 0, 0.25)` regardless of where the camera was pointing, so every throw
    // curved back toward the robot however you had orbited. That is a fine turret and a poor
    // projectile: you cannot miss with it, and missing is most of what makes throwing things
    // at a robot informative.
    //
    // * THE CAMERA IS Y-UP AND THE SIMULATION IS Z-UP. The demo draws through
    // `rotationX(-90 deg)`, which sends sim `(x, y, z)` to display `(x, z, -y)`; going back is
    // therefore display `(X, Y, Z)` to sim `(X, -Z, Y)`. Both the eye and the direction need
    // it - converting only the position gives a ball that starts in the right place and flies
    // somewhere else entirely.
    const toSim = struct {
        fn go(v: Vec) Vec {
            return vec(v[0], -v[2], v[1]);
        }
    }.go;
    const eye: Vec = toSim(cam.position);
    const aim: Vec = normalize3(toSim(cam.target) - eye);

    // * NUDGED FORWARD BY THE BALL'S OWN RADIUS, and no more. Starting exactly at the eye puts
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
    // * The warm start describes contacts that no longer exist for this body - see
    // `Data.forgetWarmStart`. Cheap, and the alternative is an impulse from a different scene.
    s.data.forgetWarmStart();
}

/// Shove the trunk sideways, to see whether the legs catch it.
fn shove(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] == .free) {
            // The free joint's velocity DOFs are linear first, then angular.
            const v: u32 = m.jnt_dof_adr[j];
            s.data.vel[v + 0] += 1.2;
            s.data.vel[v + 1] += 0.4;
            s.data.stage = .stale;
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;

    // * ONCE PER FRAME, NOT PER SUBSTEP. It answers "what should the legs be doing", which
    // only changes when a slider moves. Solving it inside the fixed-timestep loop recomputes
    // the same answer for every substep and the cost multiplies - a lesson the KUKA demo paid
    // for in frame rate.
    if (s.posing) {
        // * ONLY WHEN A SLIDER MOVED. The answer is a function of the command alone, so
        // recomputing it every frame cannot improve it and - as the comment in `solveBodyPose`
        // records - actively destabilises the robot.
        if (s.routine) {
            // * TWO INDEPENDENT RATES. Pitch and yaw in quadrature sweep the nose round a cone;
            // roll rocks at a different frequency entirely.
            s.routine_clock += f.time.delta_time;
            const cone: f32 = s.routine_clock * s.cone_rate * 2.0 * pi;
            const rock: f32 = s.routine_clock * s.roll_rate * 2.0 * pi;
            s.body_pitch = s.cone_amount * @cos(cone);
            s.body_yaw = s.cone_amount * @sin(cone);
            s.body_roll = s.roll_amount * @sin(rock);
            const bob: f32 = s.routine_clock * s.bob_rate * 2.0 * pi;
            s.body_height = s.bob_amount * @sin(bob);
        }
        const cmd: [4]f32 = .{ s.body_roll, s.body_pitch, s.body_yaw, s.body_height };
        var resolve: bool = !std.mem.eql(f32, &cmd, &s.last_cmd);

        // -- *** CLOSE THE LOOP ON THE TORSO, NOT JUST ON THE JOINTS --
        //
        // Read what the torso is ACTUALLY doing relative to its own rest attitude, and integrate
        // the shortfall into a trim. Comparing against world level instead would fold in whatever
        // tilt the settled stance already had, which is not the slider's fault and not its job.
        const seen: Vec = zm.quatToEulerXYZ(
            zm.qmul(s.data.body_xrot[1], zm.conjugate(s.rest_rot)),
        );
        s.seen_roll = seen[0];
        s.seen_pitch = seen[1];
        // -- *** THE ATTITUDE TRIM IS OFF WHILE WALKING --
        //
        // The trim integrates measured pitch error and folds it into the commanded attitude. On
        // a STANDING robot that is exactly right - it took the sliders from 16-32% short to
        // under 3%. **On a walking one it fights the gait**, because a trot pitches by design
        // every step and the integrator treats that as an error to remove.
        //
        // Measured, trot 10 s with the arm:
        //
        //     trim off   **0.957 m**, standing, pitch flat at -0.026
        //     trim on      0.123 m, **FELL at 1.80 s**, pitch +0.229 in the first second
        //
        // * THAT IS SIMON'S OSCILLATION AND FALL, REPRODUCED AND ISOLATED. The probe walked
        // forward for many turns while the demo toppled, and this loop is the entire difference
        // between them - the fourth bug in this file caused by two controllers writing one
        // array, and the one that had gone longest unfound.
        //
        // ** AN INTEGRATOR NEEDS A SETPOINT THAT IS ACTUALLY REACHABLE AND STEADY. Level is both
        // while standing; neither while walking.
        if (s.gait_on) {
            s.trim_roll = 0;
            s.trim_pitch = 0;
        } else if (s.trim_countdown > 0) {
            s.trim_countdown -= 1;
        } else {
            const roll_gap: f32 = s.body_roll - seen[0];
            const pitch_gap: f32 = s.body_pitch - seen[1];
            // * A GAIN WELL UNDER 1, because this integrator sits on top of a PD that is itself
            // still settling. Correcting the whole gap at once fights the transient it is
            // measuring and rings.
            if (@abs(roll_gap) > 0.002 or @abs(pitch_gap) > 0.002) {
                s.trim_roll = clamp(s.trim_roll + 0.5 * roll_gap, -0.4, 0.4);
                s.trim_pitch = clamp(s.trim_pitch + 0.5 * pitch_gap, -0.4, 0.4);
                resolve = true;
            }
            // *** FOUR, NOT TWELVE, AND BOTH ENDS ARE MEASURED. On the moving routine the
            // trim's mean lag is 0.0182 rad at a cadence of 12 and **0.0098 at 4** - a free
            // 1.9x. At a cadence of 1 the robot FALLS OVER (3.03 rad), which is
            // `solveBodyPose`'s warning about re-solving every frame, confirmed rather than
            // taken on trust. Four is measured to be inside that wall, not guessed to be.
            s.trim_countdown = 4;
        }

        // -- *** THE ARM REACHES FOR A MOVING TARGET --
        //
        // A circle in front of the robot, in the trunk's own frame - so as the torso rolls and

        // -- ** SLIP AND FRICTION DEMAND, MEASURED LIVE --
        //
        // `rows_per_contact` is a PYRAMID BASIS: the four rows sum to the normal load, and the
        // tangential content is what the opposing pairs disagree about. The coefficient comes
        // from the contact itself rather than a number typed here, so the ratio means what it
        // says - and **above 1.0 is a foot being asked for force the ground does not have.**
        {
            var slip: f32 = 0;
            for (0..4) |i| {
                const at: Vec = s.data.body_xpos[s.foot_body[i]] +
                    zm.rotate(s.data.body_xrot[s.foot_body[i]], s.foot_offset[i]);
                slip += length3(at - s.planted[i]);
            }
            s.foot_slip = slip;
            for (0..s.data.contact_count) |c| {
                const base: usize = c * rbt.rows_per_contact;
                var normal: f32 = 0;
                for (0..rbt.rows_per_contact) |r| {
                    normal += s.data.constraint_force[base + r];
                }
                if (normal < 1.0) {
                    continue;
                }
                const t1: f32 = s.data.constraint_force[base] - s.data.constraint_force[base + 1];
                const t2: f32 = s.data.constraint_force[base + 2] - s.data.constraint_force[base + 3];
                const tang: f32 = @sqrt(t1 * t1 + t2 * t2);
                const mu: f32 = @max(0.01, s.data.contacts[c].friction[0]);
                const ratio: f32 = tang / (mu * normal);
                s.cone_worst = @max(s.cone_worst, ratio);
                if (ratio > 0.98) {
                    s.cone_over += 1;
                }
            }
        }

        // ** THE LAG, SCORED. A routine that only looks impressive proves nothing; the number is
        // what says whether the controller is keeping up with it.
        if (s.routine and s.routine_clock > 1.5) {
            const gap: f32 = @sqrt(
                (s.body_roll - seen[0]) * (s.body_roll - seen[0]) +
                    (s.body_pitch - seen[1]) * (s.body_pitch - seen[1]),
            );
            s.routine_error_sum += gap;
            s.routine_error_count += 1;
            s.routine_worst = @max(s.routine_worst, gap);
        }

        if (resolve) {
            s.last_cmd = cmd;
            solveBodyPose(s);
        }

        // -- *** THE ARM COUNTERS *AFTER* THE TORSO SOLVE, NOT BEFORE --
        //
        // `solveBodyPose` copies EVERY hinge joint from `stance`, arm included - so running the
        // arm's IK before it meant the counter-animation was overwritten the instant the torso
        // re-solved. **The arm was solving correctly and its answer was being thrown away**,
        // which looks exactly like an arm that never counters at all.
        //
        // * ORDER IS PART OF A CONTROLLER'S DEFINITION. Two solves writing the same array is a
        // sequencing bug, not a control one, and no amount of tuning either would have shown it.
        // pitches, the world-space target moves with it and the arm must chase a point that is
        // itself being thrown around. That coupling is the whole point: the arm's mass swings,
        // the legs feel it, and neither controller is told about the other.
        if (s.arm_on) {
            s.arm_clock += f.time.delta_time;
            // -- *** A FIXED POINT IN THE WORLD, NOT A CIRCLE IN THE BODY'S FRAME --
            //
            // Captured once, above where the robot is standing, and then held. Because the goal
            // does not move, every joint motion the arm makes exists purely to CANCEL the base's
            // - which is what makes the gimbal effect legible: the body weaves and the gripper
            // does not.
            // -- *** THE HELD POINT IS RELATIVE TO THE FEET, NOT TO THE WORLD --
            //
            // Pinned in absolute world coordinates it is a target the robot slowly walks away
            // from: the feet slide, and over 30 s the gripper's mean error grew from 20 mm to
            // 61 mm chasing a point that had not moved while the robot had.
            //
            // * THE FEET ARE WHERE THE ROBOT ACTUALLY IS. Anchoring to their average means the
            // point travels with any drift the legs accumulate, so the arm counters the TORSO's
            // motion - which is the thing it is for - instead of also fighting the base's slow
            // walk. Simon's correction, and the same principle as anchoring the torso reference
            // to current feet rather than to a stored stance.
            var foot_mean: Vec = vec(0, 0, 0);
            for (0..4) |i| {
                foot_mean += s.data.body_xpos[s.foot_body[i]] +
                    zm.rotate(s.data.body_xrot[s.foot_body[i]], s.foot_offset[i]);
            }
            foot_mean /= splat(4.0);
            const goal: Vec = vec(
                foot_mean[0] + s.hold_offset[0],
                foot_mean[1] + s.hold_offset[1],
                foot_mean[2] + s.hold_height,
            );
            s.hold_point = goal;

            // * IK FROM THE ARM'S CURRENT POSE, restored afterwards - the solve must not leave
            // the simulated state anywhere, only produce a target for the servo.
            const keep_arm: []f32 = s.arm_target;
            @memcpy(keep_arm, s.data.pos[0..s.imported.model.nq]);
            _ = (ctl.Ik{ .max_iterations = 8, .max_step = 0.3 }).solve(
                &s.imported.model,
                &s.data,
                s.arm_act,
                .{ .body = s.gripper, .offset = vec(0, 0, 0), .goal = goal },
                s.ik_scratch,
            );
            // Copy only the ARM joints into `home`; the legs belong to the torso controller.
            for (0..s.imported.model.njnt) |j| {
                const v: u32 = s.imported.model.jnt_dof_adr[j];
                if (v >= s.imported.model.nv or !s.arm_act.powered[v]) {
                    continue;
                }
                const q: u32 = s.imported.model.jnt_qpos_adr[j];
                s.home[q] = s.data.pos[q];
            }
            @memcpy(s.data.pos[0..s.imported.model.nq], keep_arm);
            s.data.stage = .stale;
            rbt.forward(&s.imported.model, &s.data);
            // * THE DRIFT IS THE SCORE. A gimbal that visibly wobbles is a gimbal that failed,
            // and the number says by how much - which is the quantity a planner with preview
            // would have to beat.
            s.arm_error = length3(s.data.body_xpos[s.gripper] - goal);
            s.hold_error = s.arm_error;
            if (s.routine_clock > 1.5) {
                s.hold_worst = @max(s.hold_worst, s.arm_error);
            }
        }
    }
    // * A GAIT RE-SOLVES EVERY FRAME, unlike a static pose, because its targets move by
    // construction. The feedback loop `solveBodyPose` warns about is avoided the same way -
    // seeding from the last command rather than from the measured robot.
    if (s.gait_on) {
        solveGait(s, @min(f.time.delta_time, 0.05));
    }

    s.accumulator += @min(f.time.delta_time, 0.1);
    while (s.accumulator >= timestep) : (s.accumulator -= timestep) {
        // Kinematics, then collision, then solve - all at one `q`. See `robot_physics.sync`
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

    var force: f32 = 0;
    for (0..s.data.constraint_count) |row| {
        force += s.data.constraint_force[row];
    }
    s.peak_force = @max(s.peak_force * 0.995, force);

    // -- ** THE UI IS BUILT EARLY AND RENDERED LAST, AND BOTH HALVES MATTER --
    //
    // **Built early**, because the camera has to know whether the mouse belongs to a slider -
    // otherwise dragging `kp` orbits the view at the same time.
    //
    // **Rendered last**, because `clearViewport` wipes whatever has been drawn. Keeping
    // `begin`/`render` inside the panel function put the deferred `render` at the END OF THAT
    // FUNCTION - before the clear - so the panel was drawn and then erased, every frame. The
    // demo showed a robot and no controls at all, and looked like a build problem.
    //
    // `robot_3d` had it right by accident: its `begin` and its clear live in the same
    // function, so the defer naturally lands after the 3D pass. Making that structural rather
    // than incidental is the point of passing `u` in.
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s);

    z.clearViewport(f, bg);
    const cam: Camera3D = s.cam.update(f, captured, .{
        .min_distance = 0.6,
        .max_distance = 4.0,
    });
    // * THE THROW HAPPENS HERE, not in the panel, because it needs the camera - and the
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
/// * THESE ARE THE COLLISION SHAPES, not the visual meshes - the Go1's 13 `<mesh>` geoms are
/// skipped by the converter because their vertices live in an `<asset>` block that is not read
/// yet. Which turns out to be the better picture for a physics demo: what you see IS what the
/// solver sees, so a leg that looks like it is touching the ground is touching the ground.
fn drawRobot(s: *State, gl: *z.WgpuGl) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();

    // -- *** THE HELD POINT, AND A LINE TO IT --
    //
    // "The gripper is not moving" is only legible against something that visibly is not moving
    // either. The marker sits at the world point the arm is holding and the line measures the
    // failure - so the gimbal's success is the SHORTNESS of that line while the body weaves.
    if (s.arm_on and s.hold_point[2] != 0) {
        const at: Vec = zm.zUpToYUpPoint(s.hold_point);
        s.transform[0] = mulMat(
            translation(at[0], at[1], at[2]),
            scaling(0.045, 0.045, 0.045),
        );
        z.drawMeshInstanced(gl, &s.cube, &s.transform, .{ .r = 237, .g = 184, .b = 89, .a = 255 });
        const tip: Vec = zm.zUpToYUpPoint(s.data.body_xpos[s.gripper]);
        z.drawLine3D(gl, tip, at, .{ .r = 226, .g = 106, .b = 154, .a = 255 });
        // * AND A CROSSHAIR, so the point reads as a fixed place in the world rather than as a
        // small object that might itself be drifting.
        inline for ([_]Vec{ vec(0.12, 0, 0), vec(0, 0.12, 0), vec(0, 0, 0.12) }) |axis| {
            z.drawLine3D(gl, at - axis, at + axis, .{ .r = 120, .g = 100, .b = 60, .a = 255 });
        }
    }
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        // * A GEOM'S WORLD POSE IS ITS BODY'S, COMPOSED WITH ITS OWN OFFSET. The engine
        // stores the offset (`geom_pos`/`geom_rot`) and the body's world pose separately -
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
                // -- ** THE MESH ALREADY RUNS ALONG Y. MEASURED, NOT DERIVED. --
                //
                //     genMeshCylinder(r=1, h=1) extent:
                //       x: [-1.000, 1.000]   y: [0.000, 1.000]   z: [-1.000, 1.000]
                //
                // `cylinderUv` returns the axis in its third slot, which reads as Z - but
                // `parametricMesh` REMAPS as it writes (`verts.y = p[2]`), so the finished
                // mesh extends along zimr's **Y**, spanning [0, h] rather than [-h/2, +h/2].
                //
                // That is the same axis `GeomShape.capsule` uses, so no rotation is needed at
                // all. A previous version read `cylinderUv` and concluded Z, then rotated by
                // -90 deg to "correct" it; the non-uniform scale then landed across the shape and
                // flattened every limb into a wide curved ribbon. **Reading the generator was
                // not enough - the answer was two functions away, and printing the mesh's
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

    // Contact points, so "is it actually standing" is answerable by looking.
    for (0..s.data.contact_count) |c| {
        const p: Vec = s.data.contacts[c].position;
        // Z-up to Y-up is a coordinate swap, and writing it as one is clearer here than
        // pushing a point through a matrix: (x, y, z) becomes (x, z, -y).
        const at: Vec = vec(p[0], p[2], -p[1]);
        z.drawSphere(gl, at, .{ .radius = 0.012, .color = contact_col });
    }
}

fn drawPanel(u: ui.Ui, s: *State) bool {
    const m: *const rbt.Model = &s.imported.model;
    const captured: bool = u.wantCaptureMouse();
    if (u.window("Unitree Go1, imported from Menagerie MJCF", .{
        .initial_pos = .{ 12, 12 },
        .initial_size = .{ 360, 300 },
    })) |window| {
        defer window.close();
        u.text("{d} bodies   {d} DOF   {d} collision geoms", .{ m.nbody - 1, m.nv, m.ngeom });
        const trunk: u32 = s.imported.bodyIndex("trunk") orelse 1;
        u.text("trunk height {d:.4} m   (home 0.2700)", .{s.data.body_xpos[trunk][2]});
        u.text("contacts {d}   rows {d}   iters {d}   load {d:.0} N", .{
            s.data.contact_count,
            s.data.constraint_count,
            s.data.solver_iterations,
            s.peak_force,
        });
        u.separator();

        // * THE TWO NUMBERS WORTH PLAYING WITH. `kp = 100` is the Go1's own, from
        // `<position kp="100">` in its MJCF. Drag it down and the legs fold under the robot's
        // weight; drag it up and it goes rigid and starts to buzz against its force limit.
        _ = u.slider("kp", &s.kp, .{ .min = 5.0, .max = 400.0, .fmt = "{d:.0}" });
        // * THE DAMPING IS ON A SLIDER TOO. It was the parameter that mattered most for slip and
        // there was no way to touch it - a control whose best value is 3x its default deserves
        // to be reachable.
        _ = u.slider("kv", &s.kv, .{ .min = 0.5, .max = 16.0, .fmt = "{d:.1}" });
        _ = u.slider("kv", &s.kv, .{ .min = 0.0, .max = 20.0, .fmt = "{d:.1}" });
        _ = u.checkbox("physics", &s.physics_on);
        u.separator();

        // -- ** MOVE THE BODY WITH THE FEET PLANTED --
        //
        // A torso has no motors, so it cannot be commanded anywhere directly. But it stands on
        // four legs whose feet are on the ground, and moving the body is then the same problem
        // as moving four hips while four feet hold still - three joints at a time, which IS
        // solvable.
        //
        // Each leg gets its own IK mask, so the four solves are independent. Given the whole
        // robot, one leg's solver would cheerfully bend the other three to help, and four of
        // those fight each other into a standstill.
        //
        // `foot error` is what to watch: it stays near zero while the pose is reachable and
        // climbs the moment a slider asks for more than the legs have.
        // * THE STANCE IS CAPTURED ON THE RISING EDGE, so the sliders are relative to wherever
        // the robot is standing right now rather than to a startup pose it has since left.
        const was_posing: bool = s.posing;
        // -- ** A GAIT IS FOUR PHASE OFFSETS --
        //
        // Trot, pace, bound and walk run the SAME foot trajectory and differ only in where in
        // the cycle each leg sits. The buttons below write four numbers; nothing else changes.
        const was_walking: bool = s.gait_on;
        // -- ** TURNING WALK ON PUTS THE ARM WHERE THE GAIT NEEDS IT --
        //
        // The gait's counter-swing is measured around a HALF-BENT arm; started from wherever the
        // gimbal happened to leave it, the swing is offset and the phase that was measured to
        // work is not the phase the robot gets. **A mode that depends on a pose should establish
        // that pose**, rather than inheriting whatever the last mode left behind.
        //
        // * AND THE GIMBAL IS TURNED OFF, because the two want the arm for opposite reasons: the
        // gimbal holds the gripper still, the gait swings it. They cannot both have it.
        if (u.checkbox("walk", &s.gait_on)) {
            if (s.gait_on) {
                s.arm_on = false;
                s.gait_phase = 0;
                setArmRest(s);
            }
        }
        if (s.gait_on and !was_walking) {
            captureStance(s);
            s.posing = false;
        }
        if (s.gait_on) {
            _ = u.slider("rate Hz", &s.gait_hz, .{ .min = 0.4, .max = 3.5, .fmt = "{d:.2}" });
            _ = u.slider("stride", &s.gait_stride, .{ .min = 0.0, .max = 0.22, .fmt = "{d:.3}" });
            _ = u.slider("foot lift", &s.gait_lift, .{ .min = 0.0, .max = 0.12, .fmt = "{d:.3}" });
            _ = u.slider("duty", &s.gait_duty, .{ .min = 0.3, .max = 0.9, .fmt = "{d:.2}" });
            // ** THE ARM'S COUNTER-SWING. **Phase is the parameter that matters**: the same
            // amplitude a quarter-cycle away falls the robot over, while 0.75 walks it 1.49x
            // further than a still arm and flattens the pitch bias to zero.
            _ = u.slider("arm swing", &s.arm_swing_amp, .{ .min = 0.0, .max = 0.8, .fmt = "{d:.2}" });
            _ = u.slider("arm phase", &s.arm_swing_phase, .{ .min = 0.0, .max = 1.0, .fmt = "{d:.2}" });
            u.text("   phase {d:.2}   foot error {d:.4} m", .{ s.gait_phase, s.pose_error });
            // * THE OTHER PATTERNS SET THEIR SETTINGS TOO, for the same reason: a pattern
            // measured at another pattern's rate and duty is not the pattern being offered.
            if (u.button("trot (2 feet down, fast)", .{})) {
                s.gait_offset = .{ 0.0, 0.5, 0.5, 0.0 };
                s.gait_hz = 2.0;
                s.gait_stride = 0.16;
                s.gait_duty = 0.60;
                s.gait_lift = 0.08;
                s.arm_swing_amp = 0.3;
                s.gait_phase = 0;
            }
            if (u.button("pace", .{})) {
                s.gait_offset = .{ 0.0, 0.5, 0.0, 0.5 };
            }
            if (u.button("bound", .{})) {
                s.gait_offset = .{ 0.0, 0.0, 0.5, 0.5 };
            }
            // * THE 4-BEAT WALK IS OFFERED AND MARKED, because it FALLS at these settings -
            // measured, z 0.134 with a minimum of -0.216, where trot and pace hold 0.346. Four
            // evenly spread phases means a foot is always mid-swing, and the Go1 cannot carry
            // that on three legs at this stride. Left in because watching a gait fail is more
            // informative than not offering it, and hidden failures are worse than labelled
            // ones.
            // -- *** THE CRAWL, AND IT DOES NOT FALL - IT WAS MEASURED AT THE WRONG SETTINGS --
            //
            // This button was labelled "(falls)" on a measurement taken at TROT parameters:
            // hz 2.0, duty 0.60. At those, four evenly spread phases do fall. **At its own
            // settings it is the most robust gait here.** Measured, 10 s:
            //
            //     crawl  hz 1.0  stride 0.14  duty 0.80   0.194 m   z 0.303   pitch 0.010 flat
            //     crawl  hz 1.4  stride 0.14  duty 0.80   0.207 m   z 0.302   flat
            //     crawl  hz 1.0  stride 0.14  duty 0.85   0.201 m   z 0.303   flat
            //
            // **Every crawl configuration stands.** Duty 0.80 with quarter-spread phases leaves
            // THREE FEET DOWN at all times, so the centre of mass only has to stay inside a
            // triangle that always exists - statically stable by construction, which is the
            // right property for a robot carrying 2 kg high on its back.
            //
            // ** AND IT NEEDS NO ARM SWING AT ALL. Adding one makes it worse (0.127 against
            // 0.194): the swing exists to cancel a trot's wobble, and a crawl does not have one.
            //
            // * A GAIT PATTERN IS NOT A PARAMETER ON ITS OWN. Changing the offsets without
            // changing rate and duty measures the new pattern at the old gait's settings, which
            // is how this one earned a "(falls)" label it did not deserve.
            if (u.button("crawl (3 feet down)", .{})) {
                s.gait_offset = .{ 0.0, 0.5, 0.25, 0.75 };
                s.gait_hz = 1.4;
                s.gait_stride = 0.20;
                s.gait_duty = 0.80;
                s.gait_lift = 0.06;
                s.arm_swing_amp = 0.0;
                s.gait_phase = 0;
            }
        }
        u.separator();
        _ = u.checkbox("pose the torso", &s.posing);
        if (s.posing and !was_posing) {
            captureStance(s);
        }
        if (s.posing) {
            _ = u.slider("roll", &s.body_roll, .{ .min = -0.5, .max = 0.5, .fmt = "{d:.2}" });
            _ = u.slider("pitch", &s.body_pitch, .{ .min = -0.5, .max = 0.5, .fmt = "{d:.2}" });
            // ** ASKED VERSUS ACHIEVED, ON SCREEN. The whole bug was that nobody could see the
            // difference: the sliders said 0.15 and the robot did 0.10, and nothing reported it.
            // A commanded value with no measured counterpart is a claim, not a readout.
            u.text("  asked {d:>6.3} {d:>6.3}", .{ s.body_roll, s.body_pitch });
            u.text("  actual{d:>6.3} {d:>6.3}   trim {d:>5.3} {d:>5.3}", .{
                s.seen_roll, s.seen_pitch, s.trim_roll, s.trim_pitch,
            });
            u.separator();

            // -- * THE ROUTINE, AND ITS SCORE --
            if (u.checkbox("routine: cone + independent roll", &s.routine)) {
                s.routine_clock = 0;
                s.routine_error_sum = 0;
                s.routine_error_count = 0;
                s.routine_worst = 0;
            }
            if (s.routine) {
                _ = u.slider("cone rate", &s.cone_rate, .{ .min = 0.1, .max = 1.2, .fmt = "{d:.2}" });
                _ = u.slider("roll rate", &s.roll_rate, .{ .min = 0.1, .max = 1.2, .fmt = "{d:.2}" });
                _ = u.slider("cone size", &s.cone_amount, .{ .min = 0.05, .max = 0.35, .fmt = "{d:.2}" });
                _ = u.slider("roll size", &s.roll_amount, .{ .min = 0.05, .max = 0.35, .fmt = "{d:.2}" });
                _ = u.slider("bob rate", &s.bob_rate, .{ .min = 0.05, .max = 0.8, .fmt = "{d:.2}" });
                _ = u.slider("bob size", &s.bob_amount, .{ .min = 0.0, .max = 0.07, .fmt = "{d:.3}" });
                // * THE ARM'S SLOW SWEEP. Measured to cost nothing while walking - 0.696 m with
                // the arm alone against 0.655 for the bare crawl.
                _ = u.slider("arm lift", &s.arm_lift_amp, .{ .min = 0.0, .max = 1.2, .fmt = "{d:.2}" });
                _ = u.slider("arm lift rate", &s.arm_lift_rate, .{ .min = 0.03, .max = 0.4, .fmt = "{d:.2}" });
                const mean: f32 = if (s.routine_error_count == 0)
                    0
                else
                    @floatCast(s.routine_error_sum / float64(s.routine_error_count));
                // ** THE NUMBER THAT MATTERS. A routine that only looks impressive proves
                // nothing; this says whether the controller is keeping up with it, and it is
                // the quantity a planner would have to beat.
                u.text("  lag: mean {d:>5.3} rad   worst {d:>5.3}", .{ mean, s.routine_worst });
                u.text("  rates are incommensurate — it never repeats", .{});
            }
            // *** SLIP AND CONE, ALWAYS ON. This is the quantity the whole "why do the feet
            // slide" question turns on, and there was no way to see it. Above 1.0 the ground is
            // being asked for force it does not have - which a position controller cannot even
            // represent, let alone respect.
            u.separator();
            // -- * THE ARM --
            if (u.checkbox("gripper holds a fixed point (gimbal)", &s.arm_on)) {
                s.arm_clock = 0;
            }
            if (s.arm_on) {
                _ = u.slider("hold height", &s.hold_height, .{ .min = 0.45, .max = 0.80, .fmt = "{d:.2}" });
                _ = u.slider("hold forward", &s.hold_offset[0], .{ .min = -0.1, .max = 0.45, .fmt = "{d:.2}" });
                if (u.button("clear worst", .{})) {
                    s.hold_worst = 0;
                }
                // ** THE GIMBAL'S SCORE. The body is weaving through three incommensurate
                // frequencies; this is how far the gripper fails to ignore it.
                // ** THE HEADLINE NUMBER. The body is weaving through three incommensurate
                // frequencies; this is how completely the gripper ignores it.
                u.text("  gripper drift {d:>6.4} m   worst {d:>6.4}", .{ s.hold_error, s.hold_worst });
                u.text("  (yellow crosshair = the point it holds)", .{});
                // ** HONEST ABOUT THE SLOW DRIFT. Verified over 30 s: the robot stays UP, but the
                // gripper's mean error grows from 20 mm to 61 mm because the feet slide - the robot
                // slowly walks away from a point that is fixed in the world. That is the same foot
                // slip the readout above reports, arriving as a second symptom.
                if (s.hold_worst > 0.09) {
                    u.text("  drift growing — the feet are sliding.", .{});
                    u.text("  re-place the point, or watch the cone number.", .{});
                }
            }
            u.text("  foot slip {d:>6.3} m   cone {d:>4.2}x  over {d}", .{
                s.foot_slip, s.cone_worst, s.cone_over,
            });
            if (u.button("clear slip", .{})) {
                for (0..4) |i| {
                    s.planted[i] = s.data.body_xpos[s.foot_body[i]] +
                        zm.rotate(s.data.body_xrot[s.foot_body[i]], s.foot_offset[i]);
                }
                s.cone_worst = 0;
                s.cone_over = 0;
            }
            _ = u.slider("yaw", &s.body_yaw, .{ .min = -0.6, .max = 0.6, .fmt = "{d:.2}" });
            // * THE UP RANGE IS SMALLER THAN THE DOWN RANGE, and that is physical rather than
            // arbitrary. The Go1 settles at 0.332 with thigh and calf each 0.213 m, so the legs
            // are already well extended; asking for another 4 cm straightens them toward the
            // singular configuration where a leg can no longer push vertically at all, and the
            // robot folds. Crouching has no such limit - measured stable to -0.08.
            _ = u.slider("height", &s.body_height, .{ .min = -0.08, .max = 0.02, .fmt = "{d:.3}" });
            u.text("   foot error {d:.4} m", .{s.pose_error});
            if (u.button("level", .{})) {
                s.body_roll = 0;
                s.body_pitch = 0;
                s.body_yaw = 0;
                s.body_height = 0;
            }
        }
        if (u.button("shove", .{})) {
            shove(s);
        }
        if (u.button("throw ball", .{})) {
            s.want_throw = true;
        }
        if (u.button("reset everything", .{})) {
            resetEverything(s);
        }
    }
    return captured;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - Unitree Go1 from MJCF",
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
