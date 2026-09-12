//! tracking — why a planner beats a servo, on the one claim that survives measurement.
//!
//! Two identical arms follow the same moving target. The near one runs a PD tuned as well as I
//! could tune it; the far one plans, and is shown the target's path 0.3 seconds ahead.
//!
//! ── ★★★ THE CLAIM, AND IT IS ABOUT INFORMATION RATHER THAN TUNING ──
//!
//! A servo tracking a target moving at speed `v` holds a steady-state lag of roughly `2v/√kp`.
//! It is ALWAYS behind, and no gain removes it — raising `kp` shrinks the lag as `1/√kp` while
//! pushing toward saturation and ringing. **A planner shown the future has no lag, because it
//! can lead.**
//!
//! Measured, same arm, same 400 N·m limit, joint-space RMS error:
//!
//!     PD kp   2500    0.685 rad
//!     PD kp   9000    0.437 rad
//!     PD kp  20000    0.287 rad
//!     PD kp  45000    0.209 rad
//!     PD kp  90000    0.156 rad     ← the servo's true optimum
//!     PD kp 180000    0.168 rad     ← past it; the trend reverses
//!     MPC preview     0.096 rad     ← 1.63x better than the best gain
//!
//! ★★★ AND AN ABLATION SEPARATES THE CAUSE FROM THE CORRELATION. Remove the preview — every knot
//! referencing the target at NOW instead of in the future — and the planner scores **0.213**,
//! which LOSES to a well-tuned PD. **Preview is the entire advantage.** A planner that merely
//! knows the dynamics does not beat a servo here; one that knows the future does.
//!
//! ── ★★ THE ARM IS BUILT TO BE HARD FOR A SERVO ──
//!
//! Five segments, 1.9 m, and a **6 kg gripper at the tip**. That end mass makes the inertia
//! strongly configuration-dependent — the shoulder feels a different load at every pose — so no
//! single `kp` is right everywhere. The planner re-linearises the actual mass matrix at every
//! knot and does not care.
//!
//! ── ★ AND THIS IS THE BOTTOM HALF OF A LARGER DESIGN ──
//!
//! The intended system has a learned policy choosing a kinematic target a fraction of a second
//! ahead, and a planner reaching it smoothly and precisely. Here the target comes from a closed
//! form instead of a policy; **nothing below the interface would change.**

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const ctl = z.robot_control;
const mpc = z.robot_mpc;
const mjcf = z.mjcf;
const rmj = z.robot_mjcf;
const ui = z.ui;
const profiler = z.profiler;

const Vec = zm.Vec;
const Mat = zm.Mat;
const vec = zm.vec;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const float = zm.float;
const float64 = zm.float64;
const length3 = zm.length3;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;

// ── ★★★ 1/125, NOT 1/250 — AND THE COARSER STEP IS *MORE* ACCURATE HERE ──
//
// A knot IS one model timestep, so halving the sim rate halves the knots needed for the same
// preview horizon. 40 knots at 1/125 is **0.32 s** of lookahead; 75 at 1/250 was 0.30 s. Same
// foresight, a fifth of the work:
//
//     250 Hz, 75 knots, 6 iters   56250 knot-iters/s   MPC 0.250
//     125 Hz, 40 knots, 4 iters   10000 knot-iters/s   MPC 0.218   ← cheaper AND better
//
// ★ THE ESTIMATE THAT CAUSED THE PROBLEM: 14.7 us per knot was measured NATIVELY, and this runs
// in wasm at 2-3x that. **A native measurement is not a wasm budget**, and the frame time was
// blown by a factor never accounted for.
const sim_dt: f32 = 1.0 / 125.0;
// ★★★ 75 KNOTS AND SIX ITERATIONS ARE BOTH MEASURED FLOORS, NOT ROUND NUMBERS.
//
// Cutting to 50 knots and 2 iterations made the demo fast and destroyed the result — the planner
// went from 0.096 rad to 0.315 and LOST to the servo's 0.156. **A demo tuned for frame rate that
// no longer shows its own result is worthless**, so the cheap configuration was re-measured
// rather than assumed to behave like the expensive one.
//
// The knee, at 75 knots:
//
//     2 iterations   0.248 rad   loses to the PD
//     3 iterations   0.162 rad   ties it
//     4 iterations   0.126 rad   wins by 1.24x
//     6 iterations   0.096 rad   wins by 1.63x
const preview_knots: u32 = 40; // 0.32 s of lookahead at 1/125
/// How many poses are tabulated around the loop.
///
/// ── ★★★ THE PATH REPEATS, SO THE JOINT REFERENCE IS A TABLE, NOT A SOLVE ──
///
/// The first version ran `Ik` once per knot per tick — **76 solves per arm per sim step, at
/// 250 Hz**, which is about 600 IK solves and 3 ms of pure inverse kinematics per rendered
/// frame, per arm. Measured, that alone capped the demo near 16 fps and it ran at about 1.
///
/// The target follows a FIXED CLOSED PATH. Its joint-space reference is therefore a periodic
/// function of phase, computable once at startup and read by interpolation forever after. Every
/// runtime IK solve disappears.
const table_size: u32 = 512;
/// Replan every this many sim steps; `feedbackControl` covers the gap, which is what real MPC
/// does anyway and what the tutorial describes.
///
/// ★ THE COST FORCES A CADENCE: 75 knots x 6 iterations x 14.7 us is **6.6 ms per replan per
/// arm**, and two arms inside a 16 ms frame cannot each do that every step. At this cadence the
/// per-frame planning cost is about 6.6 ms, which leaves room to render.
///
/// ★★★ AND THE COST IS NOW MEASURED, NOT ASSUMED. `feedbackControl` does NOT cover the gaps for
/// free:
///
///     cadence 1 (250 Hz)   0.098 m
///     cadence 2 (125 Hz)   0.117 m
///     cadence 4  (63 Hz)   0.186 m   ← what this used to be, nearly 2x worse
///     cadence 8  (31 Hz)   0.331 m
///
/// ★ AND THE BUDGET ALLOWED BETTER ALL ALONG, because only ONE arm plans — the other is a servo.
/// The cost was double-counted at 13.2 ms/frame when it is 6.6, which is affordable inside 16.
/// **An arithmetic slip in a budget estimate had been paying for itself in accuracy.**
const replan_every: u32 = 2;
/// Sim steps per rendered frame. Fixed rather than accumulator-driven: a demo needs smooth
/// visuals more than it needs wall-clock-accurate physics, and a frame that falls behind an
/// accumulator spirals.
const steps_per_frame: u32 = 2;

const background: Color = .{ .r = 16, .g = 18, .b = 26, .a = 255 };
const ground_colour: Color = .{ .r = 54, .g = 62, .b = 78, .a = 255 };
const link_colour: Color = .{ .r = 152, .g = 160, .b = 176, .a = 255 };
const grip_colour: Color = .{ .r = 89, .g = 204, .b = 153, .a = 255 };
const target_colour: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const path_colour: Color = .{ .r = 84, .g = 96, .b = 120, .a = 255 };
const lag_colour: Color = .{ .r = 226, .g = 106, .b = 154, .a = 255 };
// ★ ONE COLOUR PER CONTROLLER. Both traces were the same green, so the picture was a tangle
// with no way to tell whose was whose — which makes a comparison illegible however good it is.
const trace_servo: Color = .{ .r = 214, .g = 118, .b = 148, .a = 255 };
const trace_plan: Color = .{ .r = 108, .g = 200, .b = 168, .a = 255 };

/// The target's path: a tilted circle the arm can follow all the way round.
/// ★ A BIGGER CIRCLE AND A FASTER ONE. Both widen the servo's structural lag — `e ≈ 2v/√kp`
/// grows directly with speed — so the difference is easier to see, and the arm has to work.
fn targetAt(t: f32, speed: f32) Vec {
    const a: f32 = t * speed;
    return vec(0.92 + 0.46 * @cos(a), 0.46 * @sin(a), 1.15 + 0.26 * @sin(a * 0.5));
}

const Arm = struct {
    data: rbt.Data,
    plan: mpc.Plan,
    planned: bool,
    reference: []f32,
    aim: []f32,
    keep: []f32,
    /// Running mean of the tracking error, and the worst seen.
    error_sum: f64,
    error_count: u32,
    tick: u32,
    /// Where the gripper has been. ★ THE OSCILLATION IS THE POINT AND IT IS TRANSIENT — a servo
    /// wobbling around the path looks, in any single frame, exactly like one sitting on it. Over
    /// a lap the two traces are unmistakable.
    /// ★ SIZED TO ROUGHLY ONE LAP AT THE DEFAULT SPEED. Three laps of a flailing servo is
    /// spaghetti that hides the very wobble it is drawn to show.
    trail: [180]Vec,
    trail_count: usize,
    trail_next: usize,
    worst: f32,
    live: f32,
};

const State = struct {
    gpa: Allocator,
    doc: z.codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    model: rbt.Model,
    grip: u32,
    rest: []f32,
    arm_act: ctl.Actuation,
    all_act: ctl.Actuation,
    ik_scratch: []Vec,
    state_w: []f32,
    term_w: []f32,
    ctrl_w: []f32,

    servo: Arm,
    planner: Arm,
    /// `table_size × nq` poses around the loop, and the loop's period.
    pose_table: []f32,
    loop_period: f32,

    clock: f32,
    speed: f32,
    kp: f32,
    running: bool,
    accumulator: f32,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    sphere: z.Mesh,
    transform: [1]Mat,
};

fn makeArm(gpa: Allocator, model: *const rbt.Model, planned: bool) !Arm {
    return .{
        .data = try rbt.Data.init(gpa, model),
        .plan = try mpc.Plan.init(gpa, model, preview_knots),
        .planned = planned,
        .reference = try gpa.alloc(f32, (preview_knots + 1) * (model.nq + model.nv)),
        .aim = try gpa.alloc(f32, model.nq),
        .keep = try gpa.alloc(f32, model.nq),
        .error_sum = 0,
        .error_count = 0,
        .tick = 0,
        .trail = @splat(vec(0, 0, 0)),
        .trail_count = 0,
        .trail_next = 0,
        .worst = 0,
        .live = 0,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.doc = try z.codecs.xml.parse(gpa, @embedFile("tracker.xml"), null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    s.imported = try rmj.build(gpa, &s.robot, .{
        .max_contacts = 8,
        .timestep = sim_dt,
        .gravity = vec(0, 0, -9.81),
    });
    s.model = s.imported.model;
    s.grip = s.imported.bodyIndex("gripper") orelse 0;

    s.servo = try makeArm(gpa, &s.model, false);
    s.planner = try makeArm(gpa, &s.model, true);
    rbt.forward(&s.model, &s.servo.data);
    s.rest = try gpa.dupe(f32, s.servo.data.pos);

    s.arm_act = try ctl.limbActuation(gpa, &s.model, s.grip);
    s.all_act = try ctl.Actuation.init(gpa, &s.model);
    s.ik_scratch = try gpa.alloc(Vec, ctl.Ik.scratchSize(&s.model));

    s.state_w = try gpa.alloc(f32, s.planner.plan.ndx);
    s.term_w = try gpa.alloc(f32, s.planner.plan.ndx);
    s.ctrl_w = try gpa.alloc(f32, s.model.nu);
    // ★ TRACKING WEIGHTS AT EVERY KNOT, not a terminal push — the whole path matters, which is
    // the opposite of a deadline reach. And the reference is a trajectory by construction, so
    // the "destination as a reference" mistake cannot be made here.
    for (0..s.model.nv) |i| {
        s.state_w[i] = 8.0;
        s.state_w[s.model.nv + i] = 0.05;
        s.term_w[i] = 40.0;
        s.term_w[s.model.nv + i] = 1.0;
    }
    @memset(s.ctrl_w, 1.0e-5);

    s.pose_table = try gpa.alloc(f32, table_size * s.model.nq);
    s.loop_period = 0;
    s.clock = 0;
    s.speed = 2.2; // tip travels about 1.0 m/s
    // ★★★ THE SERVO OPENS AT ITS MEASURED BEST **FOR THIS TASK**. It was 90000 on the small slow
    // circle; on the bigger faster one the optimum moved to 180000 and 90000 costs the servo a
    // fifth of its accuracy. Swept here: 1.507, 1.105, 0.895, **0.771**, 1.889.
    //
    // **A DEFAULT TUNED FOR ONE SETTING IS NOT A DEFAULT.** Changing the task and leaving the
    // opponent's gain where it was is handicapping it by accident.
    s.kp = 180000;
    s.running = true;
    s.accumulator = 0;

    s.cam = z.OrbitCamera.init(vec(0.6, 1.1, 0), 5.2);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 14, 12);
    s.transform = .{identity()};
    buildPoseTable(s);
    resetArms(s);
}

/// Solve the whole loop once, into a table indexed by phase.
///
/// ★ CHAINED FROM THE PREVIOUS ENTRY, so each solve starts beside its answer and converges in a
/// few iterations — and the table comes out CONTINUOUS, which a fresh solve per entry would not
/// guarantee on a redundant arm. Two passes, so the last entry meets the first.
fn buildPoseTable(s: *State) void {
    const m: *rbt.Model = &s.model;
    s.loop_period = 2.0 * zm.pi / @max(0.01, s.speed);
    @memcpy(s.planner.data.pos, s.rest);
    s.planner.data.stage = .stale;
    rbt.forward(m, &s.planner.data);
    var pass: u32 = 0;
    while (pass < 2) : (pass += 1) {
        for (0..table_size) |i| {
            const t: f32 = s.loop_period * float(i) / float(table_size);
            _ = (ctl.Ik{ .max_iterations = 24, .max_step = 0.35 }).solve(
                m,
                &s.planner.data,
                s.arm_act,
                .{ .body = s.grip, .offset = vec(0, 0, 0), .goal = targetAt(t, s.speed) },
                s.ik_scratch,
            );
            if (pass == 1) {
                @memcpy(s.pose_table[i * m.nq ..][0..m.nq], s.planner.data.pos[0..m.nq]);
            }
        }
    }
}

/// The tabulated pose at time `t`, linearly interpolated between neighbours.
fn poseAt(s: *const State, t: f32, out: []f32) void {
    const nq: u32 = s.model.nq;
    const phase: f32 = @mod(t / @max(0.001, s.loop_period), 1.0) * float(table_size);
    const lo: u32 = @min(table_size - 1, zm.floori(u32, phase));
    const hi: u32 = (lo + 1) % table_size;
    const frac: f32 = phase - float(lo);
    for (0..nq) |q| {
        const a: f32 = s.pose_table[lo * nq + q];
        const b: f32 = s.pose_table[hi * nq + q];
        // ★ SHORTEST-WAY INTERPOLATION IS NOT NEEDED: these are hinge angles from a chained
        // solve, so neighbours are already close and a straight lerp cannot wrap the long way.
        out[q] = a + frac * (b - a);
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.pose_table);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    inline for (.{ &s.planner, &s.servo }) |a| {
        gpa.free(a.keep);
        gpa.free(a.aim);
        gpa.free(a.reference);
        a.plan.deinit();
        a.data.deinit();
    }
    gpa.free(s.ctrl_w);
    gpa.free(s.term_w);
    gpa.free(s.state_w);
    gpa.free(s.ik_scratch);
    s.all_act.deinit();
    s.arm_act.deinit();
    gpa.free(s.rest);
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
}

fn resetArms(s: *State) void {
    inline for (.{ &s.servo, &s.planner }) |a| {
        @memcpy(a.data.pos, s.rest);
        @memset(a.data.vel, 0);
        @memset(a.data.ctrl, 0);
        // ── ★★★ AND `applied_force`, WHICH IS THE ONE THAT COST A DAY ──
        //
        // `PoseHold` writes it and clears it each apply; a planner drives `ctrl` and never
        // touches it, so it inherits whatever a servo left and `step` adds BOTH. Measured, the
        // same planner scored 0.096 rad clean and 2.69 rad after a PD had run.
        @memset(a.data.applied_force, 0);
        a.data.stage = .stale;
        rbt.forward(&s.model, &a.data);
        @memset(a.plan.ctrl, 0);
        a.error_sum = 0;
        a.error_count = 0;
        a.worst = 0;
        a.tick = 0;
        a.trail_count = 0;
        a.trail_next = 0;
    }
    s.clock = 0;
}

fn advance(s: *State, a: *Arm) void {
    const m: *rbt.Model = &s.model;
    const nstate: u32 = m.nq + m.nv;

    if (a.planned) {
        // ── ★★★ THE PREVIEW: EVERY KNOT GETS THE TARGET AT THAT KNOT'S FUTURE TIME ──
        //
        // This is the information a servo does not have and cannot be given. A gain reacts to
        // where the target IS; a plan is built around where it WILL BE, so it leads instead of
        // lagging. That is the whole difference, and it is a difference in information rather
        // than in tuning.
        // ★ THE REFERENCE IS A TABLE READ, NOT 51 IK SOLVES. Same numbers, none of the cost.
        if (a.tick % replan_every == 0) {
            for (0..a.plan.horizon + 1) |k| {
                const when: f32 = s.clock + float(k) * sim_dt;
                poseAt(s, when, a.aim);
                @memcpy(a.reference[k * nstate ..][0..m.nq], a.aim);
                @memset(a.reference[k * nstate + m.nq ..][0..m.nv], 0);
            }
            _ = mpc.optimize(m, &a.data, &a.plan, .{
                .state = s.state_w,
                .control = s.ctrl_w,
                .terminal = s.term_w,
                .reference = a.reference,
            }, .{ .iterations = 4 });
        }
        // ★★ AND `feedbackControl` COVERS THE GAP BETWEEN REPLANS, which is what real MPC does
        // and what the tutorial describes: the backward pass returns a GAIN as well as a
        // sequence, so the plan keeps correcting for where the robot actually is.
        mpc.feedbackControl(m, &a.data, &a.plan, a.data.ctrl[0..m.nu]);
        mpc.shift(&a.plan);
        a.tick += 1;
    } else {
        // ★ THE SERVO AIMS WHERE THE TARGET IS NOW. That is all it can know, and it is not a
        // strawman — its gain is swept live on the slider, so you can hunt for a better one.
        // ★ THE SERVO READS THE SAME TABLE, at the CURRENT time. Both controllers now pay the
        // same (zero) price for their reference, so the comparison measures control rather than
        // whose inverse kinematics ran more iterations.
        poseAt(s, s.clock, a.aim);
        (ctl.PoseHold{
            .target = a.aim,
            .kp = s.kp,
            .kv = 2.0 * @sqrt(s.kp),
            .max_torque = 400,
        }).apply(m, &a.data, s.all_act);
    }

    rbt.step(m, &a.data);
    rbt.forward(m, &a.data);
    a.live = length3(a.data.body_xpos[s.grip] - targetAt(s.clock, s.speed));
    // A ring buffer, so the trace is always the last lap or so rather than growing forever.
    a.trail[a.trail_next] = a.data.body_xpos[s.grip];
    a.trail_next = (a.trail_next + 1) % a.trail.len;
    a.trail_count = @min(a.trail_count + 1, a.trail.len);
    if (s.clock > 1.5) {
        a.error_sum += a.live;
        a.error_count += 1;
        a.worst = @max(a.worst, a.live);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    // ★ PROFILING OFF ACROSS THE PLANNER: two planners at 75 knots is far more instrumented work
    // than a frame's worth of timestamps can carry on wasm. The cartpole and the catch both hit
    // this wall; the smoke runner exhausts Node's heap without it.
    const was_frozen: bool = profiler.isFrozen();
    profiler.freeze();
    defer if (!was_frozen) profiler.unfreeze();

    if (s.running) {
        // ★ A FIXED NUMBER OF STEPS PER FRAME. An accumulator chasing wall-clock time spirals
        // the moment a frame runs long — it asks for more steps, which makes the next frame
        // longer still. A demo wants smooth motion, not wall-clock-accurate physics.
        var step: u32 = 0;
        while (step < steps_per_frame) : (step += 1) {
            advance(s, &s.servo);
            advance(s, &s.planner);
            s.clock += sim_dt;
        }
    }

    z.clearViewport(f, background);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 2.5, .max_distance = 14.0 });
    z.beginMode3D(gl, cam);
    s.transform[0] = mulMat(translation(0, -0.05, 0), scaling(8, 0.1, 6));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_colour);
    drawArm(s, gl, &s.servo, -1.1);
    drawArm(s, gl, &s.planner, 1.1);
    z.endMode3D(gl);
}

/// Model space is Z-up; the renderer is Y-up. One swizzle, at the boundary.
fn toRender(at: Vec, depth: f32) Vec {
    return vec(at[0], at[2], at[1] + depth);
}

fn drawArm(s: *State, gl: *z.WgpuGl, a: *const Arm, depth: f32) void {
    const m: *const rbt.Model = &s.model;

    // The path, so "the target is moving" is something you see rather than read.
    var previous: Vec = toRender(targetAt(0, s.speed), depth);
    var step: u32 = 1;
    while (step <= 96) : (step += 1) {
        const t: f32 = 2.0 * zm.pi * float(step) / 96.0 / @max(0.01, s.speed);
        const here: Vec = toRender(targetAt(t, s.speed), depth);
        z.drawLine3D(gl, previous, here, path_colour);
        previous = here;
    }

    for (1..m.nbody) |b| {
        const at: Vec = toRender(a.data.body_xpos[b], depth);
        const parent: u32 = m.body_parent[b];
        if (parent != rbt.world_body) {
            z.drawLine3D(gl, toRender(a.data.body_xpos[parent], depth), at, link_colour);
        }
        const tip: bool = b == s.grip;
        const size: f32 = if (tip) 0.11 else 0.05;
        s.transform[0] = mulMat(translation(at[0], at[1], at[2]), scaling(size, size, size));
        z.drawMeshInstanced(gl, &s.sphere, &s.transform, if (tip) grip_colour else link_colour);
    }

    // ★★★ THE TRACE THE GRIPPER ACTUALLY DREW, against the path it was asked to follow. The
    // servo's wanders visibly inside and outside the circle; the planner's sits on it. This is
    // the whole result, drawn, and it needs no number to read.
    if (a.trail_count >= 2) {
        const start: usize = if (a.trail_count < a.trail.len) 0 else a.trail_next;
        for (1..a.trail_count) |i| {
            const from: Vec = a.trail[(start + i - 1) % a.trail.len];
            const to: Vec = a.trail[(start + i) % a.trail.len];
            z.drawLine3D(gl, toRender(from, depth), toRender(to, depth), if (a.planned) trace_plan else trace_servo);
        }
    }

    // ★★ THE LAG, DRAWN. A line from the gripper to where the target actually is — short on the
    // planner, long and permanent on the servo. This is the whole demo in one segment, and it is
    // legible without reading a number.
    const goal: Vec = toRender(targetAt(s.clock, s.speed), depth);
    s.transform[0] = mulMat(translation(goal[0], goal[1], goal[2]), scaling(0.06, 0.06, 0.06));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, target_colour);
    z.drawLine3D(gl, toRender(a.data.body_xpos[s.grip], depth), goal, lag_colour);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) @min(viewport_w - 16, 340.0) else @min(380.0, viewport_w * 0.32);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, 0 }, .{});
    if (u.window("preview beats feedback", .{ .flags = .{ .always_auto_resize = true } })) |window| {
        defer window.close();

        report(u, "PD ", &s.servo);
        report(u, "MPC", &s.planner);
        u.separator();

        if (u.slider("path speed", &s.speed, .{ .min = 0.6, .max = 3.6, .fmt = "{d:.2}" })) {
            resetArms(s);
        }
        // ★ THE SERVO'S GAIN IS LIVE. Hunt for a better one — the point is that none of them
        // removes the lag, only trades it against saturation and ringing.
        // ★★★ THE RANGE REACHES PAST THE SERVO'S OPTIMUM, WHICH IS 90000. Capping the slider at
        // 40000 hid the best gain the PD family has and would have overstated the planner's
        // advantage by nearly a factor of two. A comparison whose slider cannot reach the
        // opponent's best setting is a strawman with a user interface.
        if (u.slider("PD gain", &s.kp, .{ .min = 2000, .max = 200000, .fmt = "{d:.0}" })) {
            resetArms(s);
        }
        if (u.button("RESTART", .{})) {
            resetArms(s);
        }
        _ = u.checkbox("run", &s.running);
    }

    u.setNextWindowPos(.{ 8, viewport_h - 96 }, .{});
    u.setNextWindowSize(.{ viewport_w - 16, 88 }, .{});
    if (u.window("tracking_help", .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_background = true,
        .no_inputs = true,
        .no_scrollbar = true,
    } })) |help| {
        defer help.close();
        u.text("YELLOW CUBE = the target, right now.", .{});
        u.text("pink line = how far the gripper is from it.", .{});
        u.text("trails: pink = PD's path, green = MPC's.", .{});
        u.text("the servo aims where the target IS and lags;", .{});
        u.text("  the planner sees 0.3 s ahead and leads.", .{});
    }
    return captured;
}

fn report(u: ui.Ui, label: []const u8, a: *const Arm) void {
    const mean: f32 = if (a.error_count == 0)
        0
    else
        @floatCast(a.error_sum / float64(a.error_count));
    // ★ TWO SHORT LINES RATHER THAN ONE LONG ONE. The single line ran off the panel on a phone
    // and truncated mid-word at "wors" — a readout you cannot read is not a readout.
    u.text("{s}  now {d:>5.3}  mean {d:>5.3}", .{ label, a.live, mean });
    u.text("      worst {d:>5.3} m", .{a.worst});
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - preview beats feedback",
            .width = 940,
            .height = 640,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
