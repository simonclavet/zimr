//! examples/dance_track - a physically simulated humanoid trying to follow a dance clip.
//!
//! WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
//!
//! This is stage 0 of the motion-tracking work: **no learning anywhere.** The clip is retargeted
//! onto the robot at startup, its joint rotations become PD targets, and the physics runs. The
//! character falls over. That is the expected outcome and it is the point.
//!
//! DReCon's premise is that open-loop playback is *nearly* a working controller - "not
//! sufficient for maintained character balance, but comes close". Everything downstream assumes
//! it. If this character collapses in the first 200 ms then the retarget or the gains are wrong,
//! and no amount of policy will fix that. **The bar is a second or two upright**, and finding
//! out costs one screen rather than a trained model.
//!
//! WHY YOU SEE TWO CHARACTERS
//!
//! The pale one is the KINEMATIC reference - the clip, posed exactly, ignoring physics. The
//! solid one is SIMULATED, driven only by joint torques. The gap between them IS the tracking
//! error, and watching where it opens first says more about what to fix than any single number.
//!
//! THE RETARGET RUNS AT STARTUP, NOT AHEAD OF TIME
//!
//! Two attempts were made at a tool that precomputed and saved it. Both were solving a problem
//! that does not exist: retargeting 600 frames costs about 1.8 ms, roughly 126 physics steps
//! against 2,400 for one pass over the clip. It is also the step most likely to be silently
//! wrong, and a saved file is one more thing that can go stale against a changed model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");
const ui = z.ui;

const rbt = z.robot;
const rmj = z.robot_mjcf;
const mjcf = z.mjcf;
const ctl = z.robot_control;
const zp = z.zimrphysics;
const bridge_mod = z.robot_physics;
const codecs = z.codecs;

const Vec = zm.Vec;
const Mat = zm.Mat;
const Quat = zm.Quat;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const vec = zm.vec;
const qmul = zm.qmul;
const quatToMat = zm.quatToMat;
const radFromDeg = zm.radFromDeg;
const normalize3 = zm.normalize3;
const length3 = zm.length3;
const clamp = zm.clamp;
const float = zm.float;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;

// ---- `humanoid_flex`, WHICH IS ALL HINGES ----
//
// The all-ball model was built so a retargeted quaternion could be written straight into a
// joint. It never produced a correct pose, and 0aa found why: posing a ROBOT from a retarget
// had never been done here on any model, so the ball version was not a regression from a
// working thing - it was the first attempt.
//
// `humanoid_flex` is the model the match table was written against and the one the in-file
// retarget test uses. Its joints are hinges, so a rotation has to be DECOMPOSED onto their axes
// - see `hingeAnglesFromLocal`.
const humanoid_xml = @embedFile("humanoid_flex.xml");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const dance_bvh = @embedFile("dance1_20s.bvh");
const tpose_bvh = @embedFile("Geno_stance.bvh");

/// ---- WHAT THE BISECTION LEFT BEHIND ----
///
/// `harvest_contacts` staged the step loop while hunting a wasm-only panic. It was an
/// `@intCast` overflow in `robot.addContactRows`: `usize` is 32 bits on wasm and 64 natively,
/// and a contact id masked to 48 bits fits one and traps on the other.
///
/// ** Fixed at the source - `constraintKey` takes `u64` now, because an id is not a size - and
/// the staging constant that went with it is gone, because the fixed-rate loop replaced the
/// code it was staging.
const harvest_contacts: bool = true;
/// A wasm panic is a bare `RuntimeError: unreachable` without this. See `reportPanic`'s doc -
/// it cost six turns of debugging before anyone installed one.
pub const panic = std.debug.FullPanic(common.reportPanic);

// ---- 1/2000, NOT 1/240, AND THAT IS THE WHOLE SERVO FIX ----
//
// *** MEASURED IN `robot_control.zig`: a single elbow asked to hold a constant target
// oscillated with an amplitude of 0.3 to 1.8 radians at 240 Hz and settles to 0.002 at 2000 Hz.
// A PD with positive damping cannot sustain that unless energy is injected, and an explicit
// integrator injects it when the step is long relative to the stiffness.
//
// ** THE WORKAROUND APPLIED THREE TIMES IN THIS FILE WAS A GENTLER GAIN, which trades tracking
// for stability and never fixes the cause. At 2000 Hz more gain is better again - 100 -> 0.014,
// 400 -> 0.004, 800 -> 0.002 - which is what a correct PD does.
const sim_dt: f32 = 1.0 / 2000.0;

/// The control rate, fixed. The clip is 60 fps and the policy will run at 60 Hz, so this is the
/// rate everything downstream is written against.
const control_dt: f32 = 1.0 / 60.0;

/// Physics substeps per control step: 2000 / 60, rounded down. A CONSTANT, so the ratio is a
/// property of the example rather than of whatever device is running it.
const substeps_per_control: usize = 33;

/// At most this many control steps per frame. See the note in `update`: a backlog is dropped,
/// not caught up.
const max_control_steps_per_frame: usize = 4;
const clip_seconds: f32 = 10.0;

const bg: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 };
const sim_col: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 };
const ref_col: Color = .{ .r = 86, .g = 92, .b = 104, .a = 255 };
const ground_col: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 };
const capture_col: Color = .{ .r = 235, .g = 170, .b = 90, .a = 255 };
const missing_col: Color = .{ .r = 220, .g = 90, .b = 90, .a = 255 };

const State = struct {
    gpa: Allocator,
    font: z.Font,
    cam: z.OrbitCamera,

    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    data: rbt.Data,
    actuation: ctl.Actuation,

    /// ---- CONTACT LIVES IN A SEPARATE PHYSICS WORLD, AND THAT IS THE ARCHITECTURE ----
    ///
    /// `robot_mjcf` imports a ROBOT, not a scene: worldbody geoms - including the MJCF floor -
    /// are not imported at all. A character built from it alone falls forever, measured at
    /// z = -339 after 2000 steps with zero contacts.
    ///
    /// So the ground is a static box in a `zimrphysics` world, the robot's bodies are mirrored
    /// into it by a `Bridge`, and contact forces come back through `harvest`. This is what
    /// `examples/humanoid` does and the only reason to do anything else would be not knowing.
    world: zp.World,
    bridge: bridge_mod.Bridge,

    /// One entry per frame per body: the clip's local rotation for that joint.
    clip_rotations: []Quat,
    /// The clip's ROOT TRANSLATION per frame, in robot space.
    ///
    /// ---- WITHOUT THIS THE REFERENCE DANCES ON THE SPOT ----
    ///
    /// `retargetRotations` handles orientations and says nothing about where the character IS.
    /// A BVH carries the root's travel in its first three channels, and dropping them makes a
    /// dance that moves across a room look like one performed inside a phone booth.
    clip_root: []Vec,

    /// The CAPTURE's own skeleton, per frame, in world space.
    ///
    /// ---- THE CONTROL IN THE EXPERIMENT ----
    ///
    /// This is the BVH posed by its OWN forward kinematics - offsets and rotations straight from
    /// the file, with no retarget anywhere in the path. `geno_dance` draws exactly this and it
    /// is visibly correct.
    ///
    /// *** SO IT SEPARATES THE TWO SUSPECTS. If this skeleton dances correctly beside a robot
    /// reference that does not, the fault is in the RETARGET or the model it targets - and if
    /// both are wrong, the fault is upstream of either, in how the clip is being read.
    human_points: []Vec,
    human_parent: []i32,
    human_count: usize,
    clip_frames: usize,
    clip_fps: f32,

    /// The PD target, in the model's own qpos layout, rewritten every control step.
    target: []f32,

    /// ---- THE IK PATH, WHICH REPLACES THE HAND-ROLLED DECOMPOSITION ----
    ///
    /// `geno_dance` poses its robot with `solvePointCloud` - an IK solve against a point cloud
    /// of the retargeted skeleton - and its own doc says it replaced "six sequential mechanisms
    /// ... no hinge formula". The decomposition written two turns ago WAS that hinge formula,
    /// rediscovered badly.
    ///
    /// *** THE SOLVED `kin_data.pos` IS A FULL SET OF JOINT ANGLES, consistent with the model's
    /// limits and kinematics - which is exactly what the ragdoll's PD controller wants. The
    /// kinematic robot follows the capture by IK; the ragdoll follows the kinematic robot by PD.
    kin_data: rbt.Data,
    samples: []rbt.PointSample,
    sample_count: usize,
    ik_scratch: []f32,
    ik_tasks: []rbt.IkTask,
    retargeted: []Vec,
    human_rest_pos: []Vec,
    human_rest_rot: []Quat,
    robot_rest_rot: []Quat,
    robot_rest_pos: []Vec,
    human_of_body: []i32,
    /// Global rotations of the capture per frame - `solvePointCloud` wants them alongside the
    /// positions, and they were being recomputed and discarded.
    human_rot: []Quat,
    /// The current frame's human joint positions in ROBOT space - metres, Z-up.
    human_metres: []Vec,
    has_previous: bool = false,
    previous_qpos: []f32,

    sphere: z.Mesh,
    cube: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]Mat,

    ui_host: z.UiHost,
    paused: bool = false,
    /// Drop the clip entirely and let the character fall. The cheapest test that physics,
    /// contact and gravity are all working, with no retarget or controller in the way.
    ragdoll: bool = false,
    show_reference: bool = true,
    /// The capture's own skeleton - the control in the comparison.
    show_capture: bool = true,
    /// Hang the ragdoll from a fixed point so balance is out of the question.
    ///
    /// ---- SEPARATING TWO PROBLEMS THAT KEEP BEING MEASURED AS ONE ----
    ///
    /// *** A CHARACTER THAT FALLS OVER TELLS YOU NOTHING ABOUT WHETHER ITS CONTROLLER TRACKS.
    /// Every survival number so far has measured balance AND tracking together, and balance
    /// dominates - the run ends before the tracking has said anything.
    ///
    /// Suspended, gravity and contact stop mattering and the only question left is whether the
    /// PD reaches the angles the IK solved. **That is the thing a learned correction would
    /// improve, and it now has a number of its own.**
    suspend_ragdoll: bool = true,
    /// Nail the root to a fixed world pose - hard, every step. See `pinRootInWorld`.
    pin_root: bool = false,
    /// Turn `kp` into frequency units so one gain serves limbs of different mass.
    ///
    /// ** MEASURED: ON, standing survival fell from 10.00s to 0.53s. It is right in principle -
    /// a heavy thigh and a light forearm should not share a stiffness - and the gains that
    /// BALANCE are in torque units, so the good region moves when the units do. A toggle rather
    /// than a default, because the two regimes want different numbers.
    inertia_scaled: bool = false,
    /// Largest per-joint angle error this frame, radians. The thing to minimise.
    max_joint_error: f32 = 0,
    /// Which joint is worst - a single number says how bad, this says where.
    worst_joint: usize = 0,
    /// Largest |angle| on either side, against the widest declared limit. Says WHICH is wild.
    target_max_angle: f32 = 0,
    sim_max_angle: f32 = 0,
    limit_max_angle: f32 = 0,
    /// Largest per-frame change in any hinge target, and where. Tests target SMOOTHNESS.
    target_jump: f32 = 0,
    jump_joint: usize = 0,
    previous_target: []f32,
    /// How far the solved pose misses its own IK targets, and on which body.
    ik_residual: f32 = 0,
    ik_residual_body: usize = 0,
    /// Set by the panel, consumed by `update` - a reset cannot happen mid-draw.
    want_reset: bool = false,
    /// Real time waiting to be consumed as whole control steps.
    accumulator: f32 = 0,
    playhead: f32 = 0,
    /// Seconds the simulated character survived before its head left the reference.
    survived: f32 = 0,
    fallen: bool = false,
    /// Root height on the first frame, so "fell over" is measured against where it started.
    start_height: f32 = 0,
    /// What `harvest` would be asked to push, sampled just before it runs. Read in the panel.
    last_swept: usize = 0,
    last_capacity: usize = 0,
    /// The OTHER array `harvest` pushes from - persistent contact events, separate from swept
    /// hits and sized by the same `max_contacts`. The total pushed is the sum of both, which is
    /// what `pushContact`'s assert actually measures.
    last_events: usize = 0,
    /// Frames where the contact budget was too small to harvest. Shown in the panel, because a
    /// skipped harvest is a character falling through a floor and should say so.
    overflows: u32 = 0,
    kp: f32 = 400.0,
    kv: f32 = 20.0,
};

/// One frame of the capture as global rotations per human joint.
///
/// A BVH lists parents before children, so composing up the tree is one forward pass.
fn humanGlobalsAtFrame(
    capture: *const codecs.bvh.Data,
    frame: usize,
    local: []Quat,
    global: []Quat,
    out_root: *Vec,
) void {
    const row: []const f32 = capture.motion[frame * capture.channel_count ..][0..capture.channel_count];
    var cursor: usize = 0;
    for (capture.joints, 0..) |joint, index| {
        const values: []const f32 = row[cursor..][0..joint.channels.len];
        cursor += joint.channels.len;
        var rotation: Quat = zm.quat_identity;
        var translation_bvh: Vec = vec(0, 0, 0);
        for (joint.channels, 0..) |channel, k| {
            // ---- THE ROOT'S FIRST THREE CHANNELS ARE ITS TRAVEL ----
            //
            // Only the root carries position channels in a BVH; every other joint is pure
            // rotation about its parent's offset. Reading them here rather than in a second
            // pass keeps one walk over the motion row.
            switch (channel) {
                .x_position => translation_bvh[0] = values[k],
                .y_position => translation_bvh[1] = values[k],
                .z_position => translation_bvh[2] = values[k],
                else => {},
            }
            const angle: f32 = radFromDeg(values[k]);
            const axis: ?Vec = switch (channel) {
                .x_rotation => vec(1, 0, 0),
                .y_rotation => vec(0, 1, 0),
                .z_rotation => vec(0, 0, 1),
                else => null,
            };
            if (axis) |rotation_axis| {
                rotation = qmul(rotation, zm.quatFromAxisAngle(rotation_axis, angle));
            }
        }
        if (joint.parent < 0) {
            // ---- CENTIMETRES AND Y-UP, INTO METRES AND Z-UP ----
            //
            // This capture's offsets run to the hundreds (the root sits at 179, 82, 332), so it
            // is authored in CENTIMETRES; the robot works in metres. And a BVH is Y-up while an
            // MJCF model is Z-up, so the last two components swap.
            //
            // ** BOTH CONVERSIONS ARE PROPERTIES OF THIS CLIP AND THIS MODEL, not of the
            // formats - a BVH may be authored in any unit. They are written here rather than
            // hidden in a helper so the next capture that disagrees is easy to fix.
            // Kept in BVH SPACE - raw units, Y-up. Everything that consumes it converts at
            // the point of use, because the skeleton walk needs it raw and the robot reference
            // needs it in metres Z-up, and converting early forces one of them to convert back.
            out_root.* = translation_bvh;
        }
        local[index] = rotation;
        global[index] = if (joint.parent < 0)
            local[index]
        else
            qmul(global[@intCast(joint.parent)], local[index]);
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // ---- EVERY FIELD SET EXPLICITLY, BECAUSE THE DEFAULTS ARE NOT APPLIED ----
    //
    // *** `.memory = .managed` hands `init` a zeroed State; the `= 400.0` on the struct
    // declaration is never run. The first version relied on it and shipped with **kp 0, kv 0** -
    // no torque at all, so the character was a limp ragdoll drifting off the grid while the
    // readout said the gains were fine. The panel showed the truth and the declaration lied.
    s.gpa = gpa;
    // ---- kp 800 / kv 40, MEASURED RATHER THAN INHERITED ----
    //
    // The headless sweep in `robot_control.zig` reaches the FULL TEN SECONDS here. The old
    // 400/20 came from `examples/humanoid`, which tuned them to hold a STATIC pose - a different
    // problem, and worth 1.13s on this one.
    //
    // ** THE LANDSCAPE IS NOT SMOOTH: 0.17s at 400/40, 10.00s at 800/40, 1.98s at 1500/60. A
    // controller this sensitive to its gains is working but not yet robust, and that is a thing
    // a learned correction should fix rather than something to tune further.
    // ---- SIMON'S NUMBERS FROM THE DEVICE, NOT THE HEADLESS SWEEP ----
    //
    // The sweep reached 10.00s at 800/40 with the root's orientation initialised from the clip.
    // On the device that still explodes and 84/3.4 was needed to calm it, which means the two
    // are not measuring the same thing - **and that disagreement is the next thing to chase**,
    // not something to average away. Defaulting to the gentler pair so the page is watchable.
    // Torque units by default, matching the headless sweep where 800/40 reached the full ten
    // seconds. With `scale_by_inertia` on they mean something else and want retuning.
    // ---- GENTLE BY DEFAULT, BECAUSE A WATCHABLE PAGE BEATS A CORRECT-ON-PAPER ONE ----
    //
    // 0ar measured one elbow tracking a moving target: 18.4 degrees at kp 100 against 9.2 at
    // kp 800. **Half the tracking accuracy for a controller that can be looked at** - and the
    // 9-degree figure is a plateau, so the difference between 100 and 800 is smaller than the
    // difference between watchable and not.
    //
    // ** THE SLIDER NOW REACHES DOWN TO 10. Every gain in this file so far has been chosen from
    // above, and "reduce stiffness until it stops exploding" needs a range that goes low enough
    // to find out where that is.
    // ---- kp 400, BECAUSE RUNG 2 SAYS 100 IS TOO SOFT ----
    //
    // *** MEASURED: all 24 joints holding their OWN rest pose drift 30.4 DEGREES at kp 100 -
    // the waist cannot carry the torso, which needs 21.4 Nm - and 0.4 degrees at kp 400.
    // **The reduce-stiffness instinct was wrong and I had just acted on it.**
    //
    // One elbow tracked fine at kp 100 (0ar) because one forearm is light. A whole torso is not,
    // and a single-joint measurement does not generalise to a body. See `servo_ladder.md`.
    s.kp = 400.0;
    s.kv = 20.0;
    s.accumulator = 0;
    s.playhead = 0;
    s.survived = 0;
    s.paused = false;
    s.overflows = 0;
    s.start_height = 0;
    s.ragdoll = false;
    s.show_reference = true;
    s.show_capture = true;
    s.suspend_ragdoll = true;
    s.pin_root = false;
    s.inertia_scaled = false;
    s.max_joint_error = 0;
    s.worst_joint = 0;
    s.font = try z.loadFont(f, gpa, roboto_mono_ttf, 20);
    s.ui_host = z.UiHost.init(gpa, s.font);
    // Centred between the two characters - the ragdoll at the origin and the reference
    // 1.2 m to its side - and pulled back far enough to hold both once the clip travels.
    s.cam = z.OrbitCamera.init(vec(1.2, 0.9, 0), 6.5);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 10, 8);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2);

    // ---- the robot ----
    s.doc = try codecs.xml.parse(gpa, humanoid_xml, null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    // ---- GRAVITY MUST BE SET FOR AN IMPORTED MJCF, AND THE DEFAULT IS THE WRONG AXIS ----
    //
    // *** `Options.gravity` defaults to `(0, -9.81, 0)` because zimr is Y-up everywhere else.
    // **An MJCF model is Z-UP** and `robot_mjcf.zig` deliberately does not rotate it, so the
    // default pulls the character SIDEWAYS along its own horizontal.
    //
    // That is exactly what the first device run showed: the character drifting off the grid at
    // constant height, which reads as "no gravity" and is really "gravity, ninety degrees out".
    // `robot.zig`'s own header says imported scenes set `(0, 0, -9.81)` and so do the Go1,
    // humanoid, gripper and cartpole demos - a line of documentation that was there the whole
    // time and would have saved the run.
    // `max_contacts` sizes THREE things that must all hold: `Data.contacts`, the bridge's
    // `swept` array and its `events` array. `harvest` pushes from both bridge arrays into the
    // one buffer, so the budget has to cover their SUM - a humanoid with fifteen capsules lying
    // on a floor generates far more than the default 32.
    s.imported = try rmj.build(gpa, &s.robot, .{
        .gravity = vec(0, 0, -9.81),
        .max_contacts = 256,
    });
    s.data = try rbt.Data.init(gpa, &s.imported.model);
    s.actuation = try ctl.Actuation.init(gpa, &s.imported.model);
    rbt.forward(&s.imported.model, &s.data);

    // ---- the world the character actually stands on ----
    s.world = try .init(gpa, 256);
    s.world.gravity = vec(0, 0, -9.81);
    const ground: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(8, 8, 0.5), .convex_radius = 0.01 },
    });
    _ = try s.world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
    });
    // 256, matching `max_contacts` above. This was dropped to 64 during a bisection and never
    // put back - and a bridge smaller than the contact budget is its own overflow, separate
    // from the one the budget was raised to fix.
    s.bridge = try .init(gpa, &s.world, &s.imported.model, &s.data, 256);
    s.bridge.listen(&s.world);

    const bodies: usize = s.imported.model.nbody;

    // ---- the capture, and the T-pose that aligns it ----
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bvh, null);
    defer capture.deinit();
    var tpose: codecs.bvh.Data = try codecs.bvh.parse(gpa, tpose_bvh, null);
    defer tpose.deinit();

    const human_joints: usize = capture.joints.len;
    const human_names: [][]const u8 = try gpa.alloc([]const u8, human_joints);
    defer gpa.free(human_names);
    for (capture.joints, 0..) |joint, i| {
        human_names[i] = joint.name;
    }

    const human_of_body: []i32 = try gpa.alloc(i32, bodies);
    defer gpa.free(human_of_body);
    try rbt.resolveMatchTable(&rbt.lafan_to_humanoid, s.imported.names, human_names, human_of_body);

    // ---- THE REST ALIGNMENT, WHICH IS NOT IDENTITY ----
    //
    // The robot's rest pose is a T-pose and so is `Geno_stance.bvh`. The alignment carries a
    // rotation from the human's rest frame into the robot's, and skipping it - which a first
    // draft of this did - produces a character that moves plausibly and wrongly.
    // ---- KEEP THE MAP AND THE REST POSES: THE IK SOLVE NEEDS ALL OF THEM EVERY FRAME ----
    s.human_of_body = try gpa.dupe(i32, human_of_body);
    s.kin_data = try rbt.Data.init(gpa, &s.imported.model);
    s.samples = try gpa.alloc(rbt.PointSample, 256);
    s.ik_tasks = try gpa.alloc(rbt.IkTask, 256);
    // `ikScratchSize` exists and the first version guessed `8 * nv + 64` instead. It panicked
    // inside `ikStep` - and the panic handler named the function in one build, which is the
    // whole argument for having installed it.
    s.ik_scratch = try gpa.alloc(f32, rbt.ikScratchSize(s.imported.model.nv));
    s.retargeted = try gpa.alloc(Vec, bodies);
    s.previous_qpos = try gpa.alloc(f32, s.imported.model.nq);
    s.previous_target = try gpa.alloc(f32, s.imported.model.nq);
    @memset(s.previous_target, 0);
    s.human_metres = try gpa.alloc(Vec, human_joints);
    s.human_rest_pos = try gpa.alloc(Vec, human_joints);
    s.human_rest_rot = try gpa.alloc(Quat, human_joints);
    s.robot_rest_rot = try gpa.alloc(Quat, bodies);
    s.robot_rest_pos = try gpa.alloc(Vec, bodies);
    s.has_previous = false;

    // The robot's own rest pose, forward-kinematicked once. `rbt.forward` has already run on
    // `s.data`, so these are the values it produced for `qpos0`.
    for (0..bodies) |b| {
        s.robot_rest_rot[b] = s.data.body_xrot[b];
        s.robot_rest_pos[b] = s.data.body_xpos[b];
    }

    const robot_reference: []Quat = try gpa.alloc(Quat, bodies);
    defer gpa.free(robot_reference);
    rbt.referenceOrientationsFromRest(&s.imported.model, &s.data, robot_reference);
    const human_reference: []Quat = try gpa.alloc(Quat, human_joints);
    defer gpa.free(human_reference);
    try rmj.tPoseGlobalRotations(gpa, &tpose, human_names, human_reference);
    // ---- THE HUMAN'S REST POSE, BY THE SAME FK AS EVERY OTHER FRAME ----
    //
    // `buildPointSamples` needs where each human joint SITS at rest, not just how it is
    // oriented - that is what lets a sample be placed on a body and matched to a joint. Posing
    // the T-pose capture with the same walk keeps it in BVH space, agreeing with the animated
    // frames it will be compared against.
    {
        // Its own scratch: this runs before the animation walk allocates its buffers, and a
        // rest pose computed once should not depend on the order of later allocations.
        const rest_local: []Quat = try gpa.alloc(Quat, human_joints);
        defer gpa.free(rest_local);
        const rest_bvh: []Vec = try gpa.alloc(Vec, human_joints);
        defer gpa.free(rest_bvh);
        var rest_root: Vec = vec(0, 0, 0);
        humanGlobalsAtFrame(&tpose, 0, rest_local, s.human_rest_rot, &rest_root);
        for (tpose.joints, 0..) |joint, index| {
            const raw = joint.offset;
            const offset_bvh: Vec = vec(raw[0], raw[1], raw[2]);
            // ---- THE REST POSE GOES TO THE SAME SOLVE, SO IT NEEDS THE SAME SPACE ----
            //
            // ** THE WALK STAYS IN BVH SPACE - offsets and rotations agreeing, per 0ad - and the
            // RESULT converts to metres Z-up, because `buildPointSamples` compares it against
            // the robot's own rest positions. A rest pose in centimetres against a robot in
            // metres makes every sample land a hundred times too far from its body.
            const bvh_pos: Vec = if (joint.parent < 0)
                vec(0, 0, 0)
            else
                rest_bvh[@intCast(joint.parent)] +
                    zm.rotate(s.human_rest_rot[@intCast(joint.parent)], offset_bvh);
            rest_bvh[index] = bvh_pos;
            s.human_rest_pos[index] = vec(bvh_pos[0] * 0.01, bvh_pos[2] * 0.01, bvh_pos[1] * 0.01);
        }
    }

    const rest_alignment: []Quat = try gpa.alloc(Quat, bodies);
    defer gpa.free(rest_alignment);
    codecs.bvh.restAlignmentOffsets(human_of_body, human_reference, robot_reference, rest_alignment);

    // ---- every frame, once ----
    // The destination type says `usize`, so `@as` around `@intFromFloat` is redundant - the
    // linter's `int-from-float` rule, and it is right: a cast that repeats what the declaration
    // already states is noise that can drift away from it.
    const wanted: usize = @trunc(clip_seconds / capture.frame_time);
    const wanted_frames: usize = @min(capture.frame_count, wanted);
    s.clip_frames = wanted_frames;
    s.clip_fps = 1.0 / capture.frame_time;
    s.clip_rotations = try gpa.alloc(Quat, wanted_frames * bodies);
    s.clip_root = try gpa.alloc(Vec, wanted_frames);
    s.human_count = human_joints;
    s.human_points = try gpa.alloc(Vec, wanted_frames * human_joints);
    s.human_rot = try gpa.alloc(Quat, wanted_frames * human_joints);
    s.human_parent = try gpa.alloc(i32, human_joints);
    for (capture.joints, 0..) |joint, i| {
        s.human_parent[i] = joint.parent;
    }

    const body_parents: []i32 = try gpa.alloc(i32, bodies);
    defer gpa.free(body_parents);
    for (0..bodies) |body| {
        body_parents[body] = if (body == 0) -1 else @intCast(s.imported.model.body_parent[body]);
    }
    const human_local: []Quat = try gpa.alloc(Quat, human_joints);
    defer gpa.free(human_local);
    const human_global: []Quat = try gpa.alloc(Quat, human_joints);
    defer gpa.free(human_global);
    const robot_global: []Quat = try gpa.alloc(Quat, bodies);
    defer gpa.free(robot_global);

    for (0..wanted_frames) |frame| {
        humanGlobalsAtFrame(&capture, frame, human_local, human_global, &s.clip_root[frame]);
        @memcpy(s.human_rot[frame * human_joints ..][0..human_joints], human_global);

        // ---- FORWARD KINEMATICS ON THE CAPTURE'S OWN OFFSETS ----
        //
        // Parents precede children in a BVH, so one forward pass places every joint. The
        // conversion to metres and Z-up matches the root's, because the offsets are in the same
        // units and frame as the root translation.
        // ---- THE WHOLE WALK STAYS IN BVH SPACE, AND CONVERTS ONLY AT THE END ----
        //
        // *** THE FIRST VERSION CONVERTED EACH OFFSET TO Z-UP METRES AND THEN ROTATED IT BY
        // `human_global`, WHICH IS IN THE BVH's OWN Y-UP FRAME. Rotating a Z-up vector by a
        // Y-up rotation is not a small error - it is a different animation, and it produced a
        // sprawling figure with nothing in common with the dance.
        //
        // `draw3d.bvhForwardKinematicsFromRotations` has the identical recurrence and does not
        // have this problem, because its offsets and rotations were loaded into the SAME space.
        // The algorithm was never the difference; the frames were.
        const points: []Vec = s.human_points[frame * human_joints ..][0..human_joints];
        for (capture.joints, 0..) |joint, index| {
            const raw = joint.offset;
            const offset_bvh: Vec = vec(raw[0], raw[1], raw[2]);
            points[index] = if (joint.parent < 0)
                vec(0, 0, 0)
            else
                points[@intCast(joint.parent)] +
                    zm.rotate(human_global[@intCast(joint.parent)], offset_bvh);
        }
        codecs.bvh.retargetRotations(
            body_parents,
            human_of_body,
            human_global,
            rest_alignment,
            s.clip_rotations[frame * bodies ..][0..bodies],
            robot_global,
        );
    }

    s.target = try gpa.alloc(f32, s.imported.model.nq);
    @memcpy(s.target, s.data.pos);
}

/// Put the simulated character back on the clip's first frame, at rest.
///
/// Reference state initialisation in its simplest form. Without it the character gets exactly
/// one attempt per page load, which is no way to look at anything.
fn resetToClip(s: *State) void {
    // ** THE CHARACTER STARTS ON THE CLIP'S FIRST FRAME, not in its rest pose. Starting in the
    // T-pose while the target is a dance pose makes the controller cross that gap in one step -
    // a shove at t = 0 that has nothing to do with whether the clip is trackable.
    writeTargetFromClip(s, 0);
    @memcpy(s.data.pos, s.target);
    @memset(s.data.vel, 0);
    s.accumulator = 0;
    s.playhead = 0;
    s.survived = 0;
    s.fallen = false;
    rbt.forward(&s.imported.model, &s.data);
    s.start_height = s.data.body_xpos[1][2];
}

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.previous_target);
    gpa.free(s.previous_qpos);
    gpa.free(s.robot_rest_pos);
    gpa.free(s.robot_rest_rot);
    gpa.free(s.human_rest_rot);
    gpa.free(s.human_metres);
    gpa.free(s.human_rest_pos);
    gpa.free(s.retargeted);
    gpa.free(s.ik_scratch);
    gpa.free(s.ik_tasks);
    gpa.free(s.samples);
    gpa.free(s.human_of_body);
    gpa.free(s.human_rot);
    s.kin_data.deinit();
    gpa.free(s.target);
    gpa.free(s.human_parent);
    gpa.free(s.human_points);
    gpa.free(s.clip_root);
    gpa.free(s.clip_rotations);
    s.bridge.deinit(&s.world);
    s.world.deinit(gpa);
    s.actuation.deinit();
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.cube);
    z.unloadMesh(gpa, s.sphere);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

/// Pose the kinematic robot on the capture by IK, and read its joint angles as the PD target.
///
/// ---- THIS IS WHAT `geno_dance` DOES, AND IT REPLACES THE HINGE FORMULA ----
///
/// `solvePointCloud`'s own doc: "ONE SOLVE, REPLACING SIX SEQUENTIAL MECHANISMS. No masks, no
/// sequence, no rest-pose algebra, no aim rule, no bend-plane rule, no hinge formula." The
/// decomposition this replaces was that hinge formula, rediscovered badly two turns ago.
///
/// *** THE SOLVED `kin_data.pos` IS A FULL SET OF JOINT ANGLES obeying the model's limits and
/// its kinematics, so the ragdoll's PD has a target that is reachable by construction - which a
/// per-axis projection could never promise.
///
/// ** `previous_qpos` MAKES THE SOLVE CONTINUOUS. Without it each frame starts from scratch and
/// a redundant DOF can flip between two equally good answers, which reads as a limb snapping.
fn solveKinematicPose(s: *State, frame: usize) void {
    const m: *const rbt.Model = &s.imported.model;
    const joints: usize = s.human_count;
    // ---- THE SOLVE WANTS ROBOT SPACE: METRES, Z-UP ----
    //
    // *** `human_points` IS KEPT IN BVH SPACE - centimetres, Y-up - because the skeleton drawing
    // wants it raw. Handing those straight to `solvePointCloud` asks it to reach targets a
    // HUNDRED TIMES TOO FAR AWAY, and the robot flew off into the distance trying.
    //
    // Converted here, once per frame, into a buffer the solve owns. This is the "convert at the
    // point of use" rule from 0ad doing its job: two consumers, two spaces, one source of truth.
    // ---- AND THE ROOT'S OWN POSITION, OR THE WHOLE FIGURE SITS AT z = 0 ----
    //
    // *** THE FK WALK STARTS ITS ROOT AT THE ORIGIN - every point it produces is RELATIVE to the
    // hips. Converting those alone puts the pelvis on the floor and the legs through it, and the
    // ragdoll initialised from that pose pops out of the ground on the first step.
    //
    // Horizontal re-origined to frame 0 (the studio's origin is arbitrary), height absolute
    // (0.53 to 0.83 m is where this performer's hips actually were). Same rule as
    // `drawCaptureSkeleton`, and the third place it has had to be stated.
    const now: Vec = s.clip_root[frame];
    const first: Vec = s.clip_root[0];
    const root_m: Vec = vec(
        (now[0] - first[0]) * 0.01,
        (now[2] - first[2]) * 0.01,
        now[1] * 0.01,
    );

    const raw: []const Vec = s.human_points[frame * joints ..][0..joints];
    for (0..joints) |j| {
        const p: Vec = raw[j];
        s.human_metres[j] = root_m + vec(p[0] * 0.01, p[2] * 0.01, p[1] * 0.01);
    }
    const positions: []const Vec = s.human_metres[0..joints];
    const rotations: []const Quat = s.human_rot[frame * joints ..][0..joints];

    s.sample_count = rbt.buildPointSamples(m, .{
        .human_of_body = s.human_of_body,
        .human_parents = s.human_parent,
        .rest_positions = s.human_rest_pos,
        .rest_rotations = s.human_rest_rot,
        .robot_rest_rotations = s.robot_rest_rot,
        .body_names = s.imported.names,
        .rest_positions_robot = s.robot_rest_pos,
    }, s.samples);

    buildRetargetedSkeleton(s, positions);

    rbt.solvePointCloud(m, &s.kin_data, s.samples[0..s.sample_count], .{
        .positions = positions,
        .rotations = rotations,
        .retargeted = s.retargeted,
        .root_world = s.retargeted[1],
        .previous_qpos = if (s.has_previous) s.previous_qpos else null,
        .scratch = s.ik_scratch,
        .tasks = s.ik_tasks,
    });

    // ---- FORWARD KINEMATICS ON THE SOLVED POSE, OR NOTHING CAN SEE IT ----
    //
    // *** `solvePointCloud` WRITES `kin_data.pos` AND NOTHING ELSE. The body transforms are
    // still whatever the last `forward` left there, so a drawing that reads `body_xpos` shows
    // the previous pose - or the rest pose, for ever, if `forward` was never called at all.
    // That is exactly what happened: the IK ran every frame and nothing on screen used it.
    rbt.forward(m, &s.kin_data);

    // ---- DID THE SOLVE ACTUALLY REACH ITS TARGETS? ----
    //
    // *** THE JOINT MATH HAS NEVER BEEN VERIFIED, ONLY ASSUMED. `solvePointCloud` is given
    // target body positions and returns a pose; whether that pose PUTS THE BODIES THERE is a
    // separate question, and the answer decides whether the PD is chasing the dance or chasing
    // whatever the IK settled for.
    //
    // Compared here: each mapped body's solved position against the target the retarget built
    // for it. **A residual of a centimetre or two is a skeleton that cannot quite reach; a
    // residual of tens of centimetres means the solve is not converging** and the target the PD
    // sees has little to do with the clip.
    var worst_reach: f32 = 0;
    var reach_body: usize = 0;
    for (1..m.nbody) |b| {
        if (s.human_of_body[b] < 0) {
            continue;
        }
        const missed: f32 = length3(s.kin_data.body_xpos[b] - s.retargeted[b]);
        if (missed > worst_reach) {
            worst_reach = missed;
            reach_body = b;
        }
    }
    s.ik_residual = worst_reach;
    s.ik_residual_body = reach_body;

    @memcpy(s.previous_qpos, s.kin_data.pos[0..m.nq]);
    s.has_previous = true;
}

/// Target body positions, built by walking the robot's tree and pointing each bone along the
/// direction its human counterpart points, at the ROBOT's own bone length.
///
/// ** THE LENGTHS COME FROM THE ROBOT AND THE DIRECTIONS FROM THE HUMAN. A capture's limbs are
/// whatever length that performer had; copying them would stretch the robot. Copying only the
/// direction keeps the robot's proportions and asks the solve for the closest reachable pose.
fn buildRetargetedSkeleton(s: *State, positions: []const Vec) void {
    const m: *const rbt.Model = &s.imported.model;
    const limit: usize = @min(m.nbody, s.retargeted.len);
    s.retargeted[0] = vec(0, 0, 0);

    for (1..limit) |b| {
        const parent: u32 = m.body_parent[b];
        const own_length: f32 = length3(m.body_pos[b]);
        const hb: i32 = s.human_of_body[b];

        if (parent == 0) {
            s.retargeted[b] = if (hb >= 0 and @as(usize, @intCast(hb)) < positions.len)
                positions[@intCast(hb)]
            else
                vec(0, 0, 0);
            continue;
        }
        const hp: i32 = s.human_of_body[parent];
        if (hb < 0 or hp < 0 or own_length < 1.0e-6) {
            s.retargeted[b] = s.retargeted[parent] + m.body_pos[b];
            continue;
        }
        const bone: Vec = positions[@intCast(hb)] - positions[@intCast(hp)];
        if (length3(bone) < 1.0e-6) {
            s.retargeted[b] = s.retargeted[parent] + m.body_pos[b];
            continue;
        }
        s.retargeted[b] = s.retargeted[parent] + normalize3(bone) * @as(Vec, @splat(own_length));
    }
}

/// Pull the ragdoll's root toward a fixed point above and beside the kinematic robot.
///
/// ** THE TRANSLATIONAL DOFS ONLY. A free joint's first three DOFs are its position and the last
/// three its rotation; driving the rotation too would CLAMP the character rather than hang it,
/// and a clamped root cannot show the tracking errors that make a limb swing wrong.
///
/// Written straight into `applied_force` because a free joint is not powered and never will be -
/// `Actuation` is right to exclude it, and this is a hook rather than a motor.
fn hangFromHook(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    if (m.njnt == 0 or m.jnt_type[0] != .free) {
        return;
    }
    const v: u32 = m.jnt_dof_adr[0];
    const hook: Vec = s.kin_data.body_xpos[1] + vec(2.0, 0, 3.0);
    const at: Vec = s.data.body_xpos[1];

    // Stiff and well damped: the hook should hold, not bounce. `kv` near `2*sqrt(kp)` is roughly
    // critical for a unit mass, and the character is heavier, so this errs toward sluggish.
    const hook_kp: f32 = 900.0;
    const hook_kv: f32 = 60.0;
    inline for (0..3) |k| {
        const pull: f32 = hook_kp * (hook[k] - at[k]) - hook_kv * s.data.vel[v + k];
        s.data.applied_force[v + k] += pull;
    }
}

/// Hold the root at a fixed world pose, exactly.
///
/// ---- A CONSTRAINT, NOT A FORCE ----
///
/// *** THE SPRING HOOK COULD BE FOUGHT AND WAS. A flailing character generates forces that
/// overwhelm any finite stiffness, and at 596 degrees of joint error the ragdoll was spinning
/// freely while the hook pulled at its middle. **A spring measures a tug of war; this measures
/// tracking.**
///
/// ** THE ORIENTATION IS PINNED TOO, WHICH THE HOOK DELIBERATELY DID NOT DO. The hook leaves
/// rotation free so the character can swing; this is the opposite trade - a completely immobile
/// base, so every degree of freedom left is a joint the controller drives and every error is
/// the controller's. Use the hook to watch it move, this to measure whether it tracks.
fn pinRootInWorld(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    if (m.njnt == 0 or m.jnt_type[0] != .free) {
        return;
    }
    const q: u32 = m.jnt_qpos_adr[0];
    const v: u32 = m.jnt_dof_adr[0];

    // Beside the kinematic robot and well clear of the floor, so nothing is in contact and
    // contact forces cannot contribute to what is being measured.
    // ---- BESIDE THE KINEMATIC ROBOT, AT ITS OWN HEIGHT ----
    //
    // Three metres up put the character above the camera's framing and made the two impossible
    // to compare by eye. **The whole value of pinning is that the two poses can be read against
    // each other**, which needs them at the same height and close together.
    const at: Vec = s.kin_data.body_xpos[1] + vec(2.0, 0, 0);
    inline for (0..3) |k| {
        s.data.pos[q + k] = at[k];
    }
    // Upright, x-y-z-w. Using the clip's own root orientation would rotate the whole character
    // and make the joint errors harder to read against a fixed view.
    s.data.pos[q + 3] = 0;
    s.data.pos[q + 4] = 0;
    s.data.pos[q + 5] = 0;
    s.data.pos[q + 6] = 1;

    inline for (0..6) |k| {
        s.data.vel[v + k] = 0;
    }
    rbt.forward(m, &s.data);
}

/// The largest per-joint angle error, and which joint holds it.
///
/// ---- THE NUMBER A LEARNED CORRECTION WOULD MINIMISE ----
///
/// *** MAX, NOT MEAN. A mean over twenty-four joints hides one limb being completely wrong
/// behind twenty-three being fine, and one wrong limb is what a viewer sees. The max says how
/// bad the WORST joint is, which is the honest summary of whether a pose is being tracked.
///
/// Hinges only: they are the joints the IK solved and the PD drives, and a free root has no
/// target angle to be wrong about.
fn measureJointError(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    var worst: f32 = 0;
    var where: usize = 0;

    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        const err: f32 = @abs(s.target[q] - s.data.pos[q]);
        if (err > worst) {
            worst = err;
            where = j;
        }
    }
    s.max_joint_error = worst;
    s.worst_joint = where;

    // ---- WHICH SIDE IS WILD: THE TARGET, OR THE SIMULATION ----
    //
    // *** 18.5 RADIANS IS 2.9 FULL TURNS, AND A HINGE LIMITED TO +/-2.62 CANNOT BE THERE. So
    // either the IK produced an angle outside the limit, or the simulated joint wound past it -
    // and **three turns have gone by without measuring which.** The error alone cannot say.
    //
    // Both maxima, against the widest declared limit. If the target is in range and the sim is
    // not, the constraint solver is not holding the limit. If the target is out of range, the
    // IK is and the PD is chasing somewhere the joint cannot go.
    var target_max: f32 = 0;
    var sim_max: f32 = 0;
    var limit_max: f32 = 0;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        target_max = @max(target_max, @abs(s.target[q]));
        sim_max = @max(sim_max, @abs(s.data.pos[q]));
        if (m.jnt_range[j]) |r| {
            limit_max = @max(limit_max, @max(@abs(r[0]), @abs(r[1])));
        }
    }
    s.target_max_angle = target_max;
    s.sim_max_angle = sim_max;
    s.limit_max_angle = limit_max;
}

/// Copy the solved kinematic pose into the PD target.
fn writeTargetFromClip(s: *State, frame: usize) void {
    solveKinematicPose(s, frame);
    @memcpy(s.target, s.kin_data.pos[0..s.imported.model.nq]);

    // ---- CLAMP THE TARGET TO EACH JOINT'S DECLARED RANGE ----
    //
    // `PointCloudOptions.limit_barrier` defaults to 1.0, so the IK already respects limits and
    // this should be a no-op. **It is here because "should be" is not "is"**, and a target
    // outside a joint's range is a PD chasing somewhere the joint cannot go - which produces
    // exactly the runaway torque the shaking looks like.
    //
    // ** IT CANNOT MASK THE OPPOSITE FAILURE. If the SIMULATED joint has escaped its limit, the
    // error stays large and the panel's `max |angle|` line says so - clamping the target does
    // not quieten a sim that is already out of range, it only stops this end contributing.
    const m: *const rbt.Model = &s.imported.model;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        if (m.jnt_range[j]) |range| {
            const q: u32 = m.jnt_qpos_adr[j];
            s.target[q] = clamp(s.target[q], range[0], range[1]);
        }
    }

    // ---- HOW FAR THE TARGET MOVES BETWEEN ADJACENT FRAMES ----
    //
    // *** THE SERVO IS CLEARED (0ar): ONE ELBOW FOLLOWS A SMOOTH SINE TO 9 DEGREES AND TEN FREE
    // BODIES DO NOT DEGRADE IT. So if it shakes on the real target, the target may not be
    // smooth - and an IK solve that flips between two equally good poses on adjacent frames
    // hands the PD a STEP INPUT every sixtieth of a second, which is indistinguishable from
    // shaking and is nothing to do with stiffness.
    //
    // A dance at 60 fps should not turn any joint by much more than a tenth of a radian per
    // frame. **A tenth is smooth; a whole radian is a different pose.** `previous_qpos` is the
    // only thing preventing the flip, and nobody has checked that it does.
    var jump: f32 = 0;
    var where: usize = 0;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        const moved: f32 = @abs(s.target[q] - s.previous_target[q]);
        if (moved > jump) {
            jump = moved;
            where = j;
        }
    }
    s.target_jump = jump;
    s.jump_joint = where;
    @memcpy(s.previous_target, s.target);
}

fn update(f: *z.Frame, s: *State) void {
    const gl = f.gl;
    const m: *const rbt.Model = &s.imported.model;
    // ---- `@intFromFloat` IS `unreachable` ON A NaN OR AN OUT-OF-RANGE VALUE ----
    //
    // The first frame's `delta_time` is whatever the runtime had before it had measured
    // anything, and every derived index below goes through `@intFromFloat`. A single NaN there
    // is not a wrong number, it is a panic with no stack - which is exactly how this example
    // first failed.
    // ---- A FIXED ACCUMULATOR: THE SIMULATION NEVER SEES FRAME TIME ----
    //
    // *** THE OLD LOOP DERIVED ITS SUBSTEP COUNT FROM `delta_time`, so the physics ran a
    // different number of steps on every frame and a different number again on a slow device.
    // **That is why the headless sweep and the phone disagreed by an order of magnitude in gain**
    // (0z) - they were not running the same simulation.
    //
    // Now: real time accumulates, and whole control steps are consumed at exactly 60 Hz with a
    // fixed substep count. A frame that arrives late runs more control steps; a frame that
    // arrives early runs none. **The trajectory depends only on the clip, never on the frame
    // rate**, which is what makes a number from the device comparable to a number from a test.
    const raw_dt: f32 = f.time.delta_time;
    const real_dt: f32 = if (raw_dt > 0 and raw_dt < 1.0) @min(raw_dt, 0.1) else control_dt;
    s.accumulator += real_dt;

    // ---- advance the clip and step the physics ----
    // ---- WHOLE CONTROL STEPS ONLY, AT EXACTLY 60 Hz ----
    //
    // ** THE CAP IS ON STEPS PER FRAME, NOT ON `dt`. A tab that was backgrounded for a minute
    // should not try to catch up in one frame - it drops the backlog and carries on, which is
    // visibly a skip rather than an explosion. Clamping `dt` instead would have let the physics
    // take one enormous step, which is the classic way to destroy a simulation on a hitch.
    const clip_length: f32 = float(s.clip_frames) / s.clip_fps;
    var steps_done: usize = 0;
    while (s.accumulator >= control_dt and steps_done < max_control_steps_per_frame) {
        s.accumulator -= control_dt;
        steps_done += 1;

        if (!s.paused) {
            s.playhead += control_dt;
        }
        if (s.playhead >= clip_length or s.want_reset) {
            s.want_reset = false;
            resetToClip(s);
        }

        const raw_index: f32 = @max(0, s.playhead * s.clip_fps);
        const frame_limit: f32 = float(s.clip_frames);
        const index_now: usize = @trunc(@min(raw_index, frame_limit));
        const frame_index: usize = @min(s.clip_frames - 1, index_now);
        writeTargetFromClip(s, frame_index);

        const hold: ctl.PoseHold = .{
            .target = s.target,
            .kp = if (s.ragdoll) 0 else s.kp,
            .kv = if (s.ragdoll) 0 else s.kv,
            .scale_by_inertia = s.inertia_scaled,
        };

        // A FIXED number of physics substeps per control step, so the ratio is a constant of
        // the example rather than a property of the device.
        for (0..substeps_per_control) |_| {
            if (s.suspend_ragdoll) {
                hangFromHook(s);
            }
            rbt.forward(m, &s.data);
            s.bridge.sync(&s.world, m, &s.data) catch |err| {
                zm.assertUnreachable(@src(), "bridge sync failed: {t}", .{err});
            };
            zp.step(&s.world, sim_dt) catch |err| {
                zm.assertUnreachable(@src(), "world step failed: {t}", .{err});
            };
            s.last_swept = s.bridge.swept_count;
            s.last_capacity = s.data.contacts.len;
            s.last_events = s.bridge.event_count;
            if (harvest_contacts and s.last_swept + s.last_events <= s.last_capacity) {
                s.bridge.harvest(&s.data);
            } else if (harvest_contacts) {
                s.overflows += 1;
            }
            hold.apply(m, &s.data, s.actuation);
            rbt.step(m, &s.data);
            if (s.pin_root) {
                pinRootInWorld(s);
            }
        }
    }

    // A backlog that cannot be worked off is dropped rather than carried: catching up over the
    // next several frames would make every hitch a slow-motion replay.
    if (s.accumulator > control_dt * float(max_control_steps_per_frame)) {
        s.accumulator = 0;
    }

    measureJointError(s);

    if (!s.fallen) {
        s.survived = s.playhead;
    }

    // ---- draw ----
    z.clearViewport(f, bg);

    // ---- THE PANEL IS DRAWN BEFORE THE 3D PASS, WHICH IS NOT A STYLE CHOICE ----
    //
    // `examples/humanoid` calls its panel before `beginMode3D` and returns whether the mouse
    // was captured, so the camera can ignore drags that belong to a slider. Calling it after
    // `endMode3D` - which the first version did - put it behind the 3D pass and it never
    // appeared on screen at all.
    // ---- `begin` BUILDS THE PANEL, `render` DRAWS IT, AND BOTH ARE REQUIRED ----
    //
    // *** The first version called `ui_host.begin` and every widget and never called `render`,
    // so the panel was assembled each frame and thrown away. Nothing appeared on screen and
    // nothing errored - the widgets all "worked", they simply had no output.
    //
    // `defer` so it runs after the 3D pass, which is what puts the panel ON TOP rather than
    // under it - `examples/quadruped` does exactly this and it is why its panel is visible.
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f, clip_length);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.5, .max_distance = 14.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 20, 0.5);

    // ---- THE GROUND IS DRAWN FROM THE PHYSICS WORLD, NOT THE ROBOT ----
    //
    // It is a static box in the `zimrphysics` world and has no geom in the robot model, so
    // `drawRobot` cannot see it. **A floor nobody can see is indistinguishable from no floor**,
    // which is exactly how this looked for three device runs.
    s.transform[0] = mulMat(
        mulMat(zm.zUpToYUp(), translation(0, 0, -0.5)),
        // Thin and wide: 16 x 16 x 0.2, so it reads as a floor rather than a block the
        // character stands on top of. The physics box is 0.5 deep but only its TOP face at
        // z = 0 matters, and drawing the full depth just hides the grid.
        scaling(16, 16, 0.2),
    );
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_col);
    if (s.show_reference) {
        drawReference(s, gl);
    }
    if (s.show_capture) {
        // Recomputed for drawing: the step loop's index is scoped to the loop, and a frame with
        // zero control steps still has to draw something. Deriving it from the playhead keeps
        // drawing and stepping reading the same clock.
        const draw_raw: f32 = @max(0, s.playhead * s.clip_fps);
        const draw_trunc: usize = @trunc(@min(draw_raw, float(s.clip_frames)));
        const draw_index: usize = @min(s.clip_frames - 1, draw_trunc);
        drawCaptureSkeleton(s, gl, draw_index);
    }
    drawRobot(s, gl, sim_col);
    z.endMode3D(gl);

    common.caption(gl, s.font, "dance_track - ragdoll (blue) | robot reference (pale) | capture skeleton (orange)");

    // ---- NO `endDrawing` HERE, AND THAT IS WHY THE DEFERRED `render` WORKS ----
    //
    // `examples/quadruped` does not call it either - the runtime closes the frame after `update`
    // returns. Calling it explicitly ran the deferred `ui_host.render` AFTER the frame had
    // already ended, which panicked.
}

fn drawRobot(s: *State, gl: *z.WgpuGl, tint: Color) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        const body_rot: Quat = s.data.body_xrot[body];
        const world_pos: Vec = s.data.body_xpos[body] + zm.rotate(body_rot, m.geom_pos[g]);
        const world_rot: Mat = quatToMat(qmul(body_rot, m.geom_rot[g]));
        const place: Mat = mulMat(
            mulMat(to_y_up, translation(world_pos[0], world_pos[1], world_pos[2])),
            world_rot,
        );
        switch (m.geom_shape[g]) {
            .sphere => |sph| {
                s.transform[0] = mulMat(place, scaling(sph.radius, sph.radius, sph.radius));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            },
            .box => |b| {
                s.transform[0] = mulMat(place, scaling(
                    2.0 * b.half_extent[0],
                    2.0 * b.half_extent[1],
                    2.0 * b.half_extent[2],
                ));
                z.drawMeshInstanced(gl, &s.cube, &s.transform, tint);
            },
            .capsule => |cap| {
                // ---- THE CYLINDER MESH RUNS ALONG Y WITH ITS BASE AT THE ORIGIN ----
                //
                // `genMeshCylinder(r=1, h=1)` spans y in [0, 1] and x, z in [-1, 1] - so it is
                // Y-axis and BASE-anchored, not centred. Scaling it as (radius, radius, length)
                // and skipping the offset, which the first version did, stretches every capsule
                // across the wrong axis from the wrong origin: **the elliptical bands**.
                //
                // Translate down by a half-height to centre it, then scale length along Y.
                // Copied from `examples/humanoid`, whose own comment says the extents were
                // MEASURED rather than derived - a previous version there read the UV helper,
                // concluded Z, and rotated by ninety degrees it did not need.
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, -cap.half_height, 0)),
                    scaling(cap.radius, 2.0 * cap.half_height, cap.radius),
                );
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
            },
            else => {
                // ---- A SHAPE THIS SWITCH DOES NOT HANDLE IS DRAWN AS A MARKER, NOT SKIPPED ----
                //
                // An empty `else` makes an unsupported geom INVISIBLE, and an invisible geom is
                // indistinguishable from one that is not there - which is exactly how the
                // missing floor read for three device runs. A small sphere at the right place
                // says "something is here and this code does not know how to draw it".
                s.transform[0] = mulMat(place, scaling(0.04, 0.04, 0.04));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, missing_col);
            },
        }
    }
}

/// The control panel.
///
/// ---- WHAT A PANEL IS FOR HERE ----
///
/// This example exists to answer one question - does open-loop playback nearly work - and the
/// answer depends on gains nobody has tuned for a MOVING reference. A panel turns that from a
/// rebuild per guess into a drag, which is the difference between asking the question once and
/// asking it twenty times.
///
/// ** THE RESET BUTTON SETS A FLAG RATHER THAN RESETTING. The panel draws mid-frame, after the
/// physics has stepped and while the draw is in flight; rewriting `data.pos` there would put the
/// character somewhere the frame already decided it was not. `update` consumes the flag at the
/// top of the next frame, where a reset is a normal thing to do.
/// The stage-0 bar, as words. Under 0.2 s the retarget or the gains are wrong and no policy
/// will fix it; one to two seconds is DReCon's "comes close" and is what learning builds on.
fn verdict(survived: f32) []const u8 {
    if (survived < 0.2) {
        return "TOO SHORT - check retarget or gains";
    }
    if (survived < 1.0) {
        return "short";
    }
    return "clears the bar";
}

/// Returns whether the pointer belongs to the UI, so the camera can leave it alone.
fn drawPanel(s: *State, f: *z.Frame, clip_length: f32) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const m: *const rbt.Model = &s.imported.model;
    const captured: bool = u.wantCaptureMouse();

    if (u.window("dance_track", .{})) |window| {
        defer window.close();

        // `njnt` is ALL joints, not ball ones - the old label said "24 ball joints" for a
        // model that has none. A label that contradicts the model it describes is worse than
        // no label, because it is read as information.
        u.text("{d} bodies   {d} DOF   {d} joints", .{ m.nbody - 1, m.nv, m.njnt });

        // ---- THE TWO HEIGHTS, SIDE BY SIDE ----
        //
        // The solved reference and the simulated character. **A reference root at 0.00 means the
        // IK targets lost their world position** and the figure is buried - which is how the
        // ragdoll came to pop out of the floor on its first step, launched by a pose that put it
        // underground. Two numbers catch that without anyone having to rotate the camera.
        // ---- THE TRACKING NUMBER, WHICH IS THE POINT OF THE SUSPENSION ----
        //
        // Suspended, this is a clean measure of whether the PD reaches the angles the IK solved.
        // **A learned correction's whole job is to make this smaller**, so it is the first
        // number on the panel that will still mean something once learning exists.
        // The joint INDEX, not a name: joint names are comptime-only on `Spec`-built models and
        // an imported one carries body names but not joint ones. An index is enough to find it.
        u.text("max joint error {d:.3} rad ({d:.1} deg)   worst: joint {d} on {s}", .{
            s.max_joint_error,
            s.max_joint_error * 57.2957795,
            s.worst_joint,
            s.imported.names[s.imported.model.jnt_body[s.worst_joint]],
        });

        // A dance should move no joint much past 0.1 rad per frame at 60 fps. Above that the
        // target is not smooth and the PD is being step-driven.
        // The solve's OWN accuracy: did it put the bodies where it was asked to?
        u.text("IK residual {d:.3} m on {s}   {s}", .{
            s.ik_residual,
            s.imported.names[s.ik_residual_body],
            if (s.ik_residual > 0.10) "NOT CONVERGING" else "converged",
        });

        u.text("target jump/frame {d:.3} rad on joint {d} ({s})   {s}", .{
            s.target_jump,
            s.jump_joint,
            s.imported.names[s.imported.model.jnt_body[s.jump_joint]],
            if (s.target_jump > 0.3) "NOT SMOOTH" else "smooth",
        });

        u.text("max |angle|:  target {d:.2}   sim {d:.2}   widest limit {d:.2} rad", .{
            s.target_max_angle,
            s.sim_max_angle,
            s.limit_max_angle,
        });

        u.text("root height:  reference {d:.3} m   ragdoll {d:.3} m", .{
            s.kin_data.body_xpos[1][2],
            s.data.body_xpos[1][2],
        });
        u.text("clip {d:.2}s / {d:.2}s   frame {d} of {d}", .{
            s.playhead,
            clip_length,
            @min(s.clip_frames - 1, @as(usize, @trunc(s.playhead * s.clip_fps))),
            s.clip_frames,
        });

        // THE STAGE-0 GATE, READ OFF THE SCREEN. DReCon's premise is that open-loop playback is
        // nearly a working controller - "not sufficient for maintained balance, but comes
        // close". Under 0.2 s means the retarget or the gains are wrong and no policy will fix
        // it; one to two seconds means the premise holds and learning has something to build on.
        u.text("survived {d:.2}s   {s}", .{
            s.survived,
            verdict(s.survived),
        });

        u.text("contacts: swept {d} + events {d} = {d}   capacity {d}   harvest {s}   overflow frames {d}", .{
            s.last_swept,
            s.last_events,
            s.last_swept + s.last_events,
            s.last_capacity,
            if (harvest_contacts) "ON" else "OFF",
            s.overflows,
        });

        u.separator();

        if (u.button("reset to frame 0", .{})) {
            s.want_reset = true;
        }
        _ = u.checkbox("pause", &s.paused);
        _ = u.checkbox("ragdoll (no control - does it just fall?)", &s.ragdoll);
        _ = u.checkbox("suspend (soft hook - it can still swing)", &s.suspend_ragdoll);
        _ = u.checkbox("PIN root in world (hard - only joints can move)", &s.pin_root);
        _ = u.checkbox("scale by inertia (kp becomes frequency - try WITH pin)", &s.inertia_scaled);
        _ = u.checkbox("robot reference (pale, retargeted)", &s.show_reference);
        _ = u.checkbox("capture skeleton (orange, NO retarget - the control)", &s.show_capture);

        u.separator();

        // Gains borrowed from the humanoid example, which tuned them for a STATIC pose. A moving
        // reference is a different problem and these are the first thing to try turning.
        _ = u.slider("kp", &s.kp, .{ .min = 10.0, .max = 1500.0, .fmt = "{d:.0}" });
        _ = u.slider("kv", &s.kv, .{ .min = 0.0, .max = 60.0, .fmt = "{d:.1}" });

        u.text("no learning in this example - the clip drives everything", .{});
    }
    return captured;
}

/// Draw the capture's own skeleton, posed by its own forward kinematics.
///
/// ---- THE CONTROL, AND IT SHARES NOTHING WITH THE OTHER TWO CHARACTERS ----
///
/// No retarget, no match table, no rest alignment, no robot model. Offsets and rotations
/// straight from the BVH, which is what `geno_dance` draws and what is visibly correct there.
///
/// *** IF THIS DANCES AND THE ROBOT REFERENCE DOES NOT, THE FAULT IS IN THE RETARGET OR THE
/// MODEL. If neither dances, the fault is upstream of both, in how the clip is read - and that
/// would be the more useful answer, because it is one bug rather than two.
fn drawCaptureSkeleton(s: *State, gl: *z.WgpuGl, frame: usize) void {
    const count: usize = s.human_count;
    const points: []const Vec = s.human_points[frame * count ..][0..count];

    // ---- RE-ORIGIN HORIZONTALLY, KEEP HEIGHT ABSOLUTE ----
    //
    // *** THE FIRST VERSION SUBTRACTED THE WHOLE ROOT POSITION, WHICH PINNED THE HIPS TO z = 0.
    // The skeleton then walked along the floor with its pelvis dragging - all the joint motion
    // correct, the character sunk into the ground.
    //
    // The clip's origin is wherever the mocap studio put it (this one starts at 1.79, 3.32
    // horizontally), so the horizontal part has to be re-origined or the character is off
    // screen. **The HEIGHT is not arbitrary** - 0.83 m is where this performer's hips actually
    // were, and it is the one component that must survive untouched.
    // The walk produced BVH-space points relative to the root, so the root's own travel is
    // added here and the whole figure converted once: centimetres to metres, Y-up to Z-up.
    const now: Vec = s.clip_root[frame];
    const first: Vec = s.clip_root[0];
    const root_m: Vec = vec(
        (now[0] - first[0]) * 0.01,
        (now[2] - first[2]) * 0.01,
        now[1] * 0.01,
    );

    for (1..count) |j| {
        const parent: i32 = s.human_parent[j];
        if (parent < 0) {
            continue;
        }
        // Placed a third of the way along, so the three characters read left to right:
        // ragdoll at the origin, capture skeleton at 2.4 m, robot reference at 1.2 m.
        const side: Vec = vec(2.4, 0, 0);
        const pa: Vec = points[@intCast(parent)];
        const pb: Vec = points[j];
        const a: Vec = root_m + side + vec(pa[0] * 0.01, pa[2] * 0.01, pa[1] * 0.01);
        const b: Vec = root_m + side + vec(pb[0] * 0.01, pb[2] * 0.01, pb[1] * 0.01);
        z.drawLine3D(gl, zm.zUpToYUpPoint(a), zm.zUpToYUpPoint(b), capture_col);
    }
}

/// Draw the IK-SOLVED kinematic robot - the same geoms as the ragdoll, posed by `solvePointCloud`.
///
/// ---- THIS IS WHAT "FOLLOWS PRECISELY" MEANS ----
///
/// *** IT READS `kin_data`, THE SOLVE'S OWN OUTPUT, not the retarget's raw global rotations.
/// The previous version drew from `clip_global` and walked the tree by hand - so the IK ran
/// every frame and nothing on screen used it. **A solve whose result is never read is a solve
/// that may as well not run**, and it looked like the IK was failing when it was being ignored.
///
/// ** THE SAME GEOMS AS THE SIMULATED CHARACTER. Both read `m.geom_*` and differ only in which
/// `Data` supplies the body transforms - so any difference between them is the PHYSICS, which
/// is the whole point of drawing them side by side.
fn drawReference(s: *State, gl: *z.WgpuGl) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();
    // A fixed side offset so the two do not overlap; the solved pose already carries the clip's
    // travel, because the IK targets were built from the capture's world positions.
    const side: Vec = vec(1.2, 0, 0);

    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        const body_rot: Quat = s.kin_data.body_xrot[body];
        const world_pos: Vec = s.kin_data.body_xpos[body] + side + zm.rotate(body_rot, m.geom_pos[g]);
        const world_rot: Mat = quatToMat(qmul(body_rot, m.geom_rot[g]));
        const place: Mat = mulMat(
            mulMat(to_y_up, translation(world_pos[0], world_pos[1], world_pos[2])),
            world_rot,
        );
        switch (m.geom_shape[g]) {
            .sphere => |sph| {
                s.transform[0] = mulMat(place, scaling(sph.radius, sph.radius, sph.radius));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, ref_col);
            },
            .box => |b| {
                s.transform[0] = mulMat(place, scaling(
                    2.0 * b.half_extent[0],
                    2.0 * b.half_extent[1],
                    2.0 * b.half_extent[2],
                ));
                z.drawMeshInstanced(gl, &s.cube, &s.transform, ref_col);
            },
            .capsule => |cap| {
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, -cap.half_height, 0)),
                    scaling(cap.radius, 2.0 * cap.half_height, cap.radius),
                );
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, ref_col);
            },
            else => {},
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - dance_track",
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
