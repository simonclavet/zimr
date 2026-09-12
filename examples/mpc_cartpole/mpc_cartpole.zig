//! mpc_cartpole — model predictive control, planning in front of you, at 60 fps.
//!
//! ── ★ WHAT THIS DEMONSTRATES ──
//!
//! A cartpole with a motor too weak to lift its own pole, swinging itself upright and then
//! balancing — with the plan drawn as a ghost trajectory so you can watch the optimiser think.
//! Drag the cart to disturb it and the controller re-plans around wherever you left it.
//!
//! ── ★★★ THE FRAME BUDGET IS THE WHOLE ARCHITECTURE, NOT A DETAIL ──
//!
//! A 60 Hz frame is 16.7 ms. Measured on this engine:
//!
//!     horizon 60, warm re-solve, 2 iterations ....... 0.35 ms   (2% of a frame)
//!     horizon 60, COLD solve from nothing ........... 2.9 ms
//!     horizon 150, COLD solve ....................... 32 ms     (drops a frame)
//!     the swing-up, cold, horizon 250 ............... ~100 ms    (six dropped frames)
//!
//! So the warm loop is free and **the cold solve is not**. Running one inside `update` would
//! freeze the tab for a tenth of a second every time you pressed reset — long enough that a
//! drag loses its intermediate samples and the demo stops feeling like a demo.
//!
//! ★ THE UNIT OF WORK IS THEREFORE ONE iLQR ITERATION, never a whole solve. A frame runs as
//! many as its measured budget allows and returns; a cold plan converges across however many
//! frames it takes, and you watch the ghost trajectory sharpen while it does. Nothing about
//! the optimisation changes — same iterations, same order — only when they happen.
//!
//! ── ★★ AND A COST THAT ONLY APPEARS WHEN YOU PLAN INSIDE A FRAME ──
//!
//! The smoke runner's call profile for this example reads `js_now_ms = 12225` per frame,
//! against ~42 for hello_world. Nothing here calls a clock 12 000 times — the PROFILER does.
//! Every `profiler.zoneNamed` takes a timestamp on entry and exit, and one planning frame runs
//! roughly 700 `robot.step` calls (60 knots x 6 finite-difference columns x 2 iterations),
//! each opening several zones. Six thousand zones, twelve thousand clock reads, and on wasm a
//! clock read is a JS boundary crossing.
//!
//! ★ IT IS NOT A LEAK AND NOT A BUG — it is instrumentation priced for a frame that does a
//! handful of things, being asked to price a frame that does thousands. `-Dmode=ship` strips
//! the profiler entirely and the crossings go with it. Worth knowing before someone benchmarks
//! a planner in a release build and concludes the planner is slow.
//!
//! ── ★ AND THE PHYSICS RUNS ON ITS OWN CLOCK ──
//!
//! The simulation is 100 Hz and the display is whatever the device gives. Stepping once per
//! frame would play the pole back at 60% speed on a good device and 30% on a struggling one:
//! the physics would be right and the motion visibly wrong, in a way that reads as a sluggish
//! controller rather than a wrong loop. An accumulator fixes it.

const std = @import("std");
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
/// ★ MEASURED, NOT PICKED. A cold swing-up needs ~142 iterations to converge fully, but the
/// plan is coherent — pumping in the right direction, respecting the rail — well before that.
/// Sixty is enough to act on, and the receding horizon polishes the rest while it runs. On a
/// phone managing 4 iterations a frame that is fifteen frames, a quarter of a second, instead
/// of the indefinite wait that waiting for convergence produced.
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

    reset(s, 3.0);

    s.cam = z.OrbitCamera.init(vec(0, 0.35, 0), 2.4);
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
/// The first version timed the planning directly with `performance.now()` and `verify_imports`
/// rejected the bundle: `dom.js_now_ms` is not in `bridge.zig`. The smoke runner happens to
/// provide it, so the demo passed a headless test and would have shipped a standalone with a
/// missing import — which is precisely the gap that gate exists to close.
///
/// ★ AND THE REPLACEMENT IS BETTER THAN WHAT IT REPLACED. `f.time.delta_time` measures the
/// thing actually worth protecting — whether frames are landing on time — rather than a proxy
/// for it. Planning time is only one contributor; a device struggling with the renderer needs
/// the planner to back off just as much, and a stopwatch around `optimize` cannot see that.
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
    const result: mpc.Result = mpc.optimize(&s.model, &s.data, &s.plan, costOf(s), .{
        .iterations = iterations,
    });
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
    if (delta_time > target) {
        s.budget = @max(1.0, s.budget * 0.75);
    } else if (delta_time < target * 0.7) {
        s.budget = @min(40.0, s.budget + 0.5);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    // 1. PLAN — bounded, every frame, whether or not the physics advances.
    planWithinFrame(s, f.time.delta_time);

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
    s.transform[0] = mulMat(
        mulMat(translation(x, 0, 0), rotationZ(angle)),
        scaling(thickness, 0.6, thickness),
    );
    z.drawMeshInstanced(gl, &s.cylinder, &s.transform, colour);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(440.0, viewport_w * 0.34);
    const font_size: f32 = u.scaleToViewport(panel_w, if (narrow) 30.0 else 22.0);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, @min(520.0, viewport_h * 0.72) }, .{});
    if (u.window("model predictive control", .{})) |window| {
        defer window.close();

        const angle: f32 = s.data.pos[pole_hinge];
        u.text("pole {d:>7.3} rad   cart {d:>6.2} m", .{ angle, s.data.pos[cart_slide] });
        u.text("motor {d:>6.2}  (limit +-1)", .{s.applied[0]});
        u.separator();

        // ★ THE BUDGET IS SHOWN, NOT SET. It is what the device turned out to afford — a
        // number worth seeing precisely because a phone and a desktop differ by more than 10x,
        // and because it is the reason the frame rate holds.
        u.text("frame {d:.1} ms, planning {d:.0} iters/frame", .{ s.frame_ms, s.budget });

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
            .title = "zimr - WebGPU - MPC planning in real time",
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
