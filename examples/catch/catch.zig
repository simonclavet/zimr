//! catch - an arm that reaches ahead into empty space, and one that chases.
//!
//! A ball is thrown across the workspace. Both arms must **catch** it: be at the right place, at
//! the right moment, **moving with it**. The near one runs IK plus a PD to the interception; the
//! far one plans.
//!
//! -- *** WATCH THE RELATIVE SPEED, NOT THE DISTANCE --
//!
//! The servo is very good at the obvious metric and useless at the job:
//!
//!     controller    closest gap    relative speed    verdict
//!     IK + PD           5-11 mm       5.0-7.0 m/s    swats every one
//!     MPC              84-178 mm       1.4-2.2 m/s    closing
//!
//! **A PD driven to a fixed pose arrives and STOPS.** The ball is doing 4.7 m/s, so the hand
//! meets it at 5 to 7 m/s of relative speed and knocks it across the room. Position says it
//! caught the ball. It did not.
//!
//! That distinction is why the acceptance test was written down before any code existed -
//! `|relative speed| < 0.5 m/s` - and it is the only reason a controller that looks perfect is
//! correctly scored at zero.
//!
//! -- ** THE ARM IS INVENTED, AND THAT IS THE POINT --
//!
//! Five joints, 1.28 m reach, finite torque. It corresponds to no real robot because the target
//! is a game in which characters are physically simulated robots, not sim2real. A URDF import
//! would have arrived with **no actuators at all** - URDF has no concept of one - and nothing to
//! plan with.
//!
//! -- * HONEST STATUS --
//!
//! Neither controller catches yet by the full criterion. The planner is at 0.08 m and 1.4 m/s
//! against bars of 0.05 and 0.5, and it got there through two library fixes that matter beyond
//! this demo: the control box is now on by default (the plan was asking for 357 N*m against a
//! +/-260 limit and being silently clamped), and `Plan.setHorizon` lets the terminal cost land at
//! the interception rather than 0.88 s past it - which alone was worth 6x in distance.

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
const splat = zm.splat;
const float = zm.float;
const length3 = zm.length3;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;

const gravity: f32 = 9.81;
const sim_dt: f32 = 1.0 / 250.0;
const max_horizon: u32 = 220;

const background: Color = .{ .r = 16, .g = 18, .b = 26, .a = 255 };
const ground_colour: Color = .{ .r = 58, .g = 66, .b = 82, .a = 255 };
const link_colour: Color = .{ .r = 158, .g = 166, .b = 182, .a = 255 };
const hand_colour: Color = .{ .r = 89, .g = 204, .b = 153, .a = 255 };
const ball_colour: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const arc_colour: Color = .{ .r = 90, .g = 100, .b = 124, .a = 255 };
const meet_colour: Color = .{ .r = 226, .g = 106, .b = 154, .a = 255 };
const trail_colour: Color = .{ .r = 96, .g = 132, .b = 186, .a = 255 };

fn ballAt(p0: Vec, v0: Vec, t: f32) Vec {
    return p0 + v0 * splat(t) + vec(0, 0, -0.5 * gravity * t * t);
}
fn ballVel(v0: Vec, t: f32) Vec {
    return v0 + vec(0, 0, -gravity * t);
}

/// One arm and whichever controller drives it.
const Keeper = struct {
    data: rbt.Data,
    plan: mpc.Plan,
    planned: bool,
    /// The pose that meets the ball, and the joint speeds that match its velocity there.
    meet_pose: []f32,
    meet_qvel: []f32,
    meet_time: f32,
    reference: []f32,
    /// Closest approach so far, and the relative speed at that instant.
    best_gap: f32,
    best_relative: f32,
    /// -- *** WHERE THE DECISION WAS RESOLVED, KEPT SO IT CAN BE SHOWN --
    ///
    /// The whole verdict turns on one instant lasting about 30 ms, and a demo that only draws
    /// the live frame throws it away before anyone can look. These hold the hand and the ball at
    /// closest approach so the moment persists after the throw is over.
    best_hand: Vec,
    best_ball: Vec,
    /// Where the hand has been, so reaching AHEAD is visible rather than inferred.
    trail: [180]Vec,
    trail_count: usize,
    caught: u32,
    swatted: u32,
    missed: u32,
};

const State = struct {
    gpa: Allocator,
    doc: z.codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    model: rbt.Model,
    hand: u32,
    rest: []f32,
    arm_act: ctl.Actuation,
    all_act: ctl.Actuation,
    ik_scratch: []Vec,
    state_w: []f32,
    term_w: []f32,
    ctrl_w: []f32,

    servo: Keeper,
    planner: Keeper,

    ball_p0: Vec,
    ball_v0: Vec,
    flight: f32,
    in_flight: bool,
    throw_speed: f32,
    throw_side: f32,
    seed: u32,

    accumulator: f32,
    running: bool,
    /// Seconds since the last throw ended, for the auto-repeat.
    idle: f32,
    /// * SLOW BY DEFAULT. The catch happens in about 30 ms of simulated time; at full speed the
    /// entire argument of the demo is over before the eye has found the ball.
    time_scale: f32,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    sphere: z.Mesh,
    transform: [1]Mat,
};

fn makeKeeper(gpa: Allocator, model: *const rbt.Model, planned: bool) !Keeper {
    const plan: mpc.Plan = try mpc.Plan.init(gpa, model, max_horizon);
    return .{
        .data = try rbt.Data.init(gpa, model),
        .plan = plan,
        .planned = planned,
        .meet_pose = try gpa.alloc(f32, model.nq),
        .meet_qvel = try gpa.alloc(f32, model.nv),
        .meet_time = -1,
        .reference = try gpa.alloc(f32, (max_horizon + 1) * (model.nq + model.nv)),
        .best_gap = 1.0e9,
        .best_relative = 0,
        .best_hand = vec(0, 0, 0),
        .best_ball = vec(0, 0, 0),
        .trail = @splat(vec(0, 0, 0)),
        .trail_count = 0,
        .caught = 0,
        .swatted = 0,
        .missed = 0,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.doc = try z.codecs.xml.parse(gpa, @embedFile("keeper.xml"), null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    s.imported = try rmj.build(gpa, &s.robot, .{
        .max_contacts = 16,
        .timestep = sim_dt,
        .gravity = vec(0, 0, -gravity),
    });
    s.model = s.imported.model;
    s.hand = s.imported.bodyIndex("hand") orelse 0;

    s.servo = try makeKeeper(gpa, &s.model, false);
    s.planner = try makeKeeper(gpa, &s.model, true);
    rbt.forward(&s.model, &s.servo.data);
    s.rest = try gpa.dupe(f32, s.servo.data.pos);

    s.arm_act = try ctl.limbActuation(gpa, &s.model, s.hand);
    s.all_act = try ctl.Actuation.init(gpa, &s.model);
    s.ik_scratch = try gpa.alloc(Vec, ctl.Ik.scratchSize(&s.model));

    s.state_w = try gpa.alloc(f32, s.planner.plan.ndx);
    s.term_w = try gpa.alloc(f32, s.planner.plan.ndx);
    s.ctrl_w = try gpa.alloc(f32, s.model.nu);
    // * POSITION AND VELOCITY BLOCKS SEPARATELY. `ndx` is nv positions THEN nv velocities, and
    // the joint speeds that match 4.7 m/s of hand travel are large - one number for both lets
    // the velocity term swamp everything else in the problem.
    for (0..s.model.nv) |i| {
        s.state_w[i] = 0.5;
        s.state_w[s.model.nv + i] = 0.02;
        s.term_w[i] = 60.0;
        s.term_w[s.model.nv + i] = 4.0;
    }
    @memset(s.ctrl_w, 1.0e-4);

    s.throw_speed = 3.4;
    s.throw_side = 0.0;
    s.seed = 0x2545f491;
    s.in_flight = false;
    s.flight = 0;
    s.accumulator = 0;
    s.running = true;
    s.idle = 0;
    s.time_scale = 0.35;

    s.cam = z.OrbitCamera.init(vec(0, 0.9, 0), 6.5);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 14, 12);
    s.transform = .{identity()};
    // *** THROW ON START, AND THAT IS A GATE AS MUCH AS A COURTESY. The smoke run executes 60
    // frames; with no ball in flight it never entered `optimize` at all, so the reference-length
    // assert that fires in the browser could not fire there. A demo that idles until clicked
    // has an automated check that verifies almost nothing.
    throwBall(s);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    inline for (.{ &s.planner, &s.servo }) |k| {
        gpa.free(k.reference);
        gpa.free(k.meet_qvel);
        gpa.free(k.meet_pose);
        k.plan.deinit();
        k.data.deinit();
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
    inline for (.{ &s.servo, &s.planner }) |k| {
        @memcpy(k.data.pos, s.rest);
        @memset(k.data.vel, 0);
        @memset(k.data.ctrl, 0);
        k.data.stage = .stale;
        rbt.forward(&s.model, &k.data);
        k.best_gap = 1.0e9;
        k.best_relative = 0;
        k.meet_time = -1;
        k.trail_count = 0;
        // * AND THE PLAN, NOT ONLY THE ARM. `optimize` warm-starts from `plan.ctrl`; leaving the
        // last throw's commands there means the first tick of the next one applies them.
        @memset(k.plan.ctrl, 0);
        k.plan.setHorizon(max_horizon);
    }
    s.in_flight = false;
    s.flight = 0;
    s.idle = 0;
}

/// Scan the arc for the LATEST instant the arm can still reach - more time to prepare, and the
/// arm is not committed before it has to be. Reachability judged by `Ik.Result.reached` rather
/// than a threshold invented for the occasion.
fn planInterception(s: *State, k: *Keeper) void {
    const m: *rbt.Model = &s.model;
    var best: f32 = -1;
    var t: f32 = 0.15;
    while (t < 1.4) : (t += 0.03) {
        const at: Vec = ballAt(s.ball_p0, s.ball_v0, t);
        if (at[2] < 0.3) {
            break;
        }
        @memcpy(k.data.pos, s.rest);
        k.data.stage = .stale;
        rbt.forward(m, &k.data);
        const r: ctl.Ik.Result = (ctl.Ik{ .max_iterations = 50 }).solve(
            m,
            &k.data,
            s.arm_act,
            .{ .body = s.hand, .offset = vec(0, 0, 0), .goal = at },
            s.ik_scratch,
        );
        if (r.reached) {
            best = t;
        }
    }
    k.meet_time = best;
    @memcpy(k.data.pos, s.rest);
    k.data.stage = .stale;
    rbt.forward(m, &k.data);
    if (best <= 0) {
        @memcpy(k.meet_pose, s.rest[0..m.nq]);
        @memset(k.meet_qvel, 0);
        return;
    }

    _ = (ctl.Ik{ .max_iterations = 70 }).solve(
        m,
        &k.data,
        s.arm_act,
        .{ .body = s.hand, .offset = vec(0, 0, 0), .goal = ballAt(s.ball_p0, s.ball_v0, best) },
        s.ik_scratch,
    );
    @memcpy(k.meet_pose, k.data.pos[0..m.nq]);

    // Joint velocities that put the hand on the ball's velocity, least-norm through the hand
    // Jacobian. This is what a servo has no way to ask for.
    @memset(k.meet_qvel, 0);
    var jac_buf: [16]Vec = undefined;
    if (m.nv > jac_buf.len) {
        return;
    }
    const jac: []Vec = jac_buf[0..m.nv];
    rbt.jacPoint(m, &k.data, s.hand, k.data.body_xpos[s.hand], jac, null);
    var gram: [9]f32 = @splat(0);
    inline for (0..3) |a| {
        inline for (0..3) |b| {
            var sum: f32 = 0;
            for (0..m.nv) |v| {
                sum += jac[v][a] * jac[v][b];
            }
            gram[a * 3 + b] = sum;
        }
    }
    const ridge: f32 = 1.0e-4 * (@abs(gram[0]) + @abs(gram[4]) + @abs(gram[8]) + 1.0);
    gram[0] += ridge;
    gram[4] += ridge;
    gram[8] += ridge;
    const want: Vec = ballVel(s.ball_v0, best);
    var lambda: [3]f32 = .{ want[0], want[1], want[2] };
    if (ctl.solve3Pub(&gram, &lambda)) {
        for (0..m.nv) |v| {
            k.meet_qvel[v] = lambda[0] * jac[v][0] + lambda[1] * jac[v][1] + lambda[2] * jac[v][2];
        }
    }
    @memcpy(k.data.pos, s.rest);
    k.data.stage = .stale;
    rbt.forward(m, &k.data);
}

fn throwBall(s: *State) void {
    resetArms(s);
    s.seed = s.seed *% 1664525 +% 1013904223;
    const jitter: f32 = float(s.seed >> 12) / 1048576.0 - 0.5;
    s.ball_p0 = vec(-2.6, s.throw_side, 1.0);
    s.ball_v0 = vec(s.throw_speed, -0.35 * s.throw_side + 0.4 * jitter, 3.0 + 0.4 * jitter);
    planInterception(s, &s.servo);
    planInterception(s, &s.planner);
    s.in_flight = true;
}

fn advance(s: *State, k: *Keeper, tick: u32) void {
    const m: *rbt.Model = &s.model;
    if (k.meet_time <= 0) {
        return;
    }

    if (k.planned) {
        if (tick % 5 == 0) {
            // -- *** THE TERMINAL KNOT *IS* THE INTERCEPTION --
            //
            // With a fixed 0.88 s horizon the terminal knot - carrying by far the largest weight,
            // 60 against a running 0.5 - sat AFTER the ball had already hit the floor. The plan
            // was asked with maximum emphasis to be somewhere at a moment that no longer meant
            // anything, and no amount of iteration helped: a 6-to-60 sweep gave 0.4981, 0.4985,
            // 0.4964. Identical.
            //
            // Shrinking the horizon to the time remaining moved that weight onto the catch and
            // was worth **6x in distance and 3x in relative speed**, on its own.
            const nstate: u32 = m.nq + m.nv;
            const left: f32 = @max(0.0, k.meet_time - s.flight);
            const arrive: u32 = @min(max_horizon, zm.floori(u32, left / sim_dt));
            k.plan.setHorizon(@max(2, arrive));

            // * AND THE REFERENCE IS A TRAJECTORY, NOT A DESTINATION. Copied into every knot it
            // asks the arm to be at the target from knot zero, which is the rocket's first wrong
            // question. Smoothstepped from here to there gives every knot somewhere reachable.
            for (0..k.plan.horizon + 1) |step| {
                const along: f32 = if (arrive == 0) 1.0 else @min(
                    1.0,
                    float(step) / float(arrive),
                );
                const blend: f32 = along * along * (3.0 - 2.0 * along);
                for (0..m.nq) |q| {
                    k.reference[step * nstate + q] = k.data.pos[q] +
                        blend * (k.meet_pose[q] - k.data.pos[q]);
                }
                const near_end: bool = arrive > 0 and step + 10 >= arrive;
                for (0..m.nv) |v| {
                    k.reference[step * nstate + m.nq + v] = if (near_end) k.meet_qvel[v] else 0;
                }
            }
            // *** THE REFERENCE MUST BE EXACTLY `(horizon + 1) x nstate`, AND THE HORIZON MOVES.
            //
            // `setHorizon` shrinks the plan in place while the buffer stays allocated for the
            // maximum, so handing over the whole thing describes a longer plan than the one
            // being solved - 2210 entries for a plan wanting 1880. The assert in `optimize` is
            // right to refuse it: a reference and a horizon that disagree is exactly the
            // silent-misalignment class of bug that has cost this project several turns.
            //
            // * AND IT ONLY SURFACED IN THE BROWSER, because the probe runs ReleaseFast where
            // `assertf` is compiled out. The debug wasm build caught it. The probe's numbers
            // still stand - it filled and read the same prefix - but the demo had to be told.
            const wanted: usize = (k.plan.horizon + 1) * nstate;
            _ = mpc.optimize(m, &k.data, &k.plan, .{
                .state = s.state_w,
                .control = s.ctrl_w,
                .terminal = s.term_w,
                .reference = k.reference[0..wanted],
            }, .{ .iterations = 6 });
        }
        @memcpy(k.data.ctrl, k.plan.ctrl[0..m.nu]);
        mpc.shift(&k.plan);
    } else {
        // * THE HONEST BASELINE, AND IT IS NOT A STRAWMAN: it is handed the interception point
        // AND the moment, and servos straight to them. What it cannot express is "be moving when
        // you get there" - a PD driven to a fixed pose arrives and stops.
        (ctl.PoseHold{
            .target = k.meet_pose,
            .kp = 900,
            .kv = 60,
            .max_torque = 260,
        }).apply(m, &k.data, s.all_act);
    }
    rbt.step(m, &k.data);

    const ball: Vec = ballAt(s.ball_p0, s.ball_v0, s.flight);
    const gap: f32 = length3(k.data.body_xpos[s.hand] - ball);
    if (gap < k.best_gap) {
        k.best_gap = gap;
        k.best_relative = length3(k.data.cvel[s.hand].lin - ballVel(s.ball_v0, s.flight));
        k.best_hand = k.data.body_xpos[s.hand];
        k.best_ball = ball;
    }
    if (k.trail_count < k.trail.len) {
        k.trail[k.trail_count] = k.data.body_xpos[s.hand];
        k.trail_count += 1;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    // *** PROFILING OFF ACROSS THE PLANNER. `optimize` at 220 knots with six iterations executes
    // an enormous amount of instrumented code per frame, and each zone costs two timestamps -
    // on wasm, two JS boundary crossings. Measured here: the smoke runner exhausted Node's
    // 2 GB heap before finishing sixty frames. The cartpole hit this exact wall and the fix is
    // the same: the instrument is priced for a frame that does a few things, and a frame that
    // solves a trajectory optimisation is not that.
    const was_frozen: bool = profiler.isFrozen();
    profiler.freeze();
    defer if (!was_frozen) profiler.unfreeze();

    // * AUTO-REPEAT, so the thing loops and can be WATCHED rather than clicked at. A demo whose
    // interesting second requires a button press gets seen once.
    if (s.running and !s.in_flight) {
        s.idle += f.time.delta_time;
        if (s.idle > 1.6) {
            throwBall(s);
        }
    }
    if (s.running and s.in_flight) {
        s.accumulator += @min(f.time.delta_time, 0.1) * s.time_scale;
        var tick: u32 = 0;
        while (s.accumulator >= sim_dt) : (s.accumulator -= sim_dt) {
            advance(s, &s.servo, tick);
            advance(s, &s.planner, tick);
            s.flight += sim_dt;
            tick += 1;
            if (ballAt(s.ball_p0, s.ball_v0, s.flight)[2] < 0.05) {
                score(s, &s.servo);
                score(s, &s.planner);
                s.in_flight = false;
                break;
            }
        }
    }

    z.clearViewport(f, background);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 3.0, .max_distance = 16.0 });
    z.beginMode3D(gl, cam);
    s.transform[0] = mulMat(translation(0, -0.05, 0), scaling(12, 0.1, 8));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_colour);
    drawKeeper(s, gl, &s.servo, -1.3);
    drawKeeper(s, gl, &s.planner, 1.3);
    drawBall(s, gl);
    z.endMode3D(gl);
}

fn score(s: *State, k: *Keeper) void {
    _ = s;
    if (k.best_gap < 0.05 and k.best_relative < 0.5) {
        k.caught += 1;
    } else if (k.best_gap < 0.05) {
        k.swatted += 1;
    } else {
        k.missed += 1;
    }
}

/// Model space is Z-up; the renderer is Y-up. One swizzle, at the boundary.
fn toRender(at: Vec, depth: f32) Vec {
    return vec(at[0], at[2], at[1] + depth);
}

fn drawKeeper(s: *State, gl: *z.WgpuGl, k: *const Keeper, depth: f32) void {
    const m: *const rbt.Model = &s.model;
    for (1..m.nbody) |b| {
        const at: Vec = toRender(k.data.body_xpos[b], depth);
        const parent: u32 = m.body_parent[b];
        if (parent != rbt.world_body) {
            z.drawLine3D(gl, toRender(k.data.body_xpos[parent], depth), at, link_colour);
        }
        const is_hand: bool = b == s.hand;
        const size: f32 = if (is_hand) 0.10 else 0.05;
        s.transform[0] = mulMat(translation(at[0], at[1], at[2]), scaling(size, size, size));
        z.drawMeshInstanced(gl, &s.sphere, &s.transform, if (is_hand) hand_colour else link_colour);
    }
    // * WHERE THIS ARM HAS DECIDED TO MEET THE BALL. Drawn, because the decision happens before
    // the motion does and is otherwise invisible - the arm reaching into empty space and waiting
    // there IS the plan, made visible.
    if (k.meet_time > 0) {
        const meet: Vec = toRender(ballAt(s.ball_p0, s.ball_v0, k.meet_time), depth);
        s.transform[0] = mulMat(translation(meet[0], meet[1], meet[2]), scaling(0.06, 0.06, 0.06));
        z.drawMeshInstanced(gl, &s.cube, &s.transform, meet_colour);
    }

    // ** THE HAND'S PATH. A planner that reaches AHEAD and waits looks identical to one that
    // chases, in any single frame. Over a whole throw the two paths are unmistakable.
    // *** `1..0` IS AN INTEGER UNDERFLOW, NOT AN EMPTY RANGE - and this is the SECOND time this
    // session, after the identical line in `examples/rocket`. It runs fine in release on the
    // host and traps instantly in the debug wasm smoke run, which is exactly what that gate is
    // for. Any `for (1..count)` over a buffer that can be empty needs this guard.
    if (k.trail_count >= 2) {
        for (1..k.trail_count) |i| {
            z.drawLine3D(gl, toRender(k.trail[i - 1], depth), toRender(k.trail[i], depth), trail_colour);
        }
    }

    // -- *** THE VERDICT, HELD --
    //
    // The whole thing turns on one instant of about 30 ms. Drawing only the live frame throws it
    // away before anyone can look at it, which is why this demo read as "did something happen?".
    // The hand and the ball at closest approach stay on screen, with the gap drawn between them
    // and coloured by the outcome: green if it was a catch, pink if the hand was there and
    // moving too fast, grey if it never arrived.
    if (k.best_gap < 1.0e8) {
        const hand_at: Vec = toRender(k.best_hand, depth);
        const ball_at: Vec = toRender(k.best_ball, depth);
        const verdict: Color = if (k.best_gap < 0.05 and k.best_relative < 0.5)
            hand_colour
        else if (k.best_gap < 0.05)
            meet_colour
        else
            arc_colour;
        z.drawLine3D(gl, hand_at, ball_at, verdict);
        s.transform[0] = mulMat(
            translation(ball_at[0], ball_at[1], ball_at[2]),
            scaling(0.05, 0.05, 0.05),
        );
        z.drawMeshInstanced(gl, &s.cube, &s.transform, verdict);
    }
}

fn drawBall(s: *State, gl: *z.WgpuGl) void {
    if (s.flight <= 0) {
        return;
    }
    // The predicted arc, as a ghost - what the planner knows and the eye does not.
    var previous: Vec = toRender(s.ball_p0, 0);
    var t: f32 = 0.05;
    while (t < 1.4) : (t += 0.05) {
        const at: Vec = ballAt(s.ball_p0, s.ball_v0, t);
        if (at[2] < 0.05) {
            break;
        }
        const here: Vec = toRender(at, 0);
        z.drawLine3D(gl, previous, here, arc_colour);
        previous = here;
    }
    inline for ([_]f32{ -1.3, 1.3 }) |depth| {
        // * THE BALL STAYS ON SCREEN AFTER THE THROW. It used to vanish the instant the flight
        // ended, so the scene the viewer was left studying had no ball in it at all.
        const at: Vec = toRender(ballAt(s.ball_p0, s.ball_v0, s.flight), depth);
        s.transform[0] = mulMat(translation(at[0], at[1], at[2]), scaling(0.07, 0.07, 0.07));
        z.drawMeshInstanced(gl, &s.sphere, &s.transform, ball_colour);
    }
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);

    // -- * THE CONTROLS STAY SMALL AND THE PROSE LEAVES THE BOX --
    //
    // On a phone the panel had grown to most of the screen and the robots were a sliver at the
    // bottom - which is backwards for a demo whose entire argument is something you WATCH. The
    // window now holds only what needs a widget; the explanation is drawn as a borderless
    // overlay below, where it costs no interactive area at all.
    const panel_w: f32 = if (narrow) @min(viewport_w - 16, 340.0) else @min(380.0, viewport_w * 0.32);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, 0 }, .{});
    if (u.window("catching, not swatting", .{ .flags = .{ .always_auto_resize = true } })) |window| {
        defer window.close();

        report(u, "IK+PD", &s.servo);
        report(u, "MPC  ", &s.planner);
        u.separator();

        _ = u.slider("speed", &s.throw_speed, .{ .min = 2.6, .max = 4.4, .fmt = "{d:.2}" });
        _ = u.slider("side", &s.throw_side, .{ .min = -1.0, .max = 1.0, .fmt = "{d:.2}" });
        if (u.button("THROW", .{})) {
            throwBall(s);
        }
        _ = u.slider("slowmo", &s.time_scale, .{ .min = 0.08, .max = 1.0, .fmt = "{d:.2}" });
        _ = u.checkbox("run", &s.running);
    }

    // * BORDERLESS, NON-INTERACTIVE, AND OUT OF THE WAY - the recipe `ui.zig` names for an
    // overlay. `no_inputs` matters as much as `no_background`: prose that silently eats taps is
    // worse than prose in a box.
    u.setNextWindowPos(.{ 8, viewport_h - 118 }, .{});
    u.setNextWindowSize(.{ viewport_w - 16, 110 }, .{});
    if (u.window("catch_help", .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_background = true,
        .no_inputs = true,
        .no_scrollbar = true,
    } })) |help| {
        defer help.close();
        u.text("a catch needs the hand MOVING with the ball:", .{});
        u.text("   gap < 5 cm  AND  relative < 0.5 m/s", .{});
        u.text("the line held after each throw is the verdict:", .{});
        u.text("   green caught / pink swatted / grey missed", .{});
        u.text("near arm = IK+PD,  far arm = MPC.  blue = path.", .{});
    }
    return captured;
}

fn report(u: ui.Ui, label: []const u8, k: *const Keeper) void {
    if (k.best_gap > 1.0e8) {
        u.text("{s}  ready", .{label});
        return;
    }
    u.text("{s} {d:>5.3}m {d:>5.2}m/s  {d}/{d}/{d}", .{
        label, k.best_gap, k.best_relative, k.caught, k.swatted, k.missed,
    });
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - catching, not swatting",
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
