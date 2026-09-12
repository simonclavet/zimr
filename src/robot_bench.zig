//! robot_bench — how fast is this, actually?
//!
//! §4g states the endgame plainly: **by the time the port is finished, robot.zig must be at
//! least as fast as MuJoCo on an equivalent model, measured, on the same machine.** This is
//! the measurement. It is deliberately the FIRST thing done in that direction, before any
//! optimisation, because §4g's S7 says optimising without a measurement is guessing.
//!
//! ── THE THREE MODELS, CHOSEN BEFORE THE NUMBERS WERE KNOWN ──
//!
//! §4g fixed them in advance so they could not be picked to flatter us, and requires them
//! reported SEPARATELY — a single aggregate would let a win on the smooth dynamics hide a
//! loss on the solver, and the solver is what decides whether the engine is usable.
//!
//!   1. a 2-link arm, no contact       — the tree passes in isolation
//!   2. a 7-DOF KUKA, no contact       — do they scale
//!   3. the same with limits active    — the constraint path
//!
//! ── HOW TO READ IT ──
//!
//! Nanoseconds per `robot.step`, which is what a control loop pays. MuJoCo's equivalent is
//! `mj_step` on the same model, timed by `scripts/robot_bench_mujoco.py` on this machine.
//! Both run single-threaded, from the same initial state, for the same number of steps.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zm = @import("zm");
const rbt = @import("robot.zig");
const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const rmj = @import("robot_mjcf.zig");
const profiler = @import("profiler.zig");
const eql = std.mem.eql;

const go1_xml = @embedFile("tests/fixtures/robot/go1/go1.xml");
const kuka = @import("tests/fixtures/robot/kuka_iiwa.zig");

const vec = zm.vec;

/// A two-link arm, the same one the tests use.
const TwoLink = rbt.Spec(.{
    .bodies = &.{
        .{
            .name = "upper",
            .joints = &.{.{ .name = "shoulder", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.002 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.26, .radius = 0.045 } },
                .pos = vec(0, -0.26, 0),
            }},
        },
        .{
            .name = "lower",
            .parent = "upper",
            .pos = vec(0, -0.52, 0),
            .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.002 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.22, .radius = 0.035 } },
                .pos = vec(0, -0.22, 0),
            }},
        },
    },
    .options = .{ .timestep = 1.0 / 240.0 },
});

/// The KUKA with every joint limited, so the constraint path is exercised. Same mechanism,
/// so the difference from case 2 IS the cost of constraints.
const steps_per_case: usize = 200_000;

/// A monotonic clock, since this pinned std has no `std.time.Timer`.
///
/// The POSIX call directly. Native-only, which is exactly what a benchmark is — there is
/// nothing to measure in a wasm build that does not run the same code on the same silicon.
fn monotonicNanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Hold a pose with a PD servo on every hinge, gravity-compensated.
///
/// ★★ A BENCHMARK MUST MEASURE THE STATE IT CLAIMS TO. Without this the Go1 case ran
/// UNCONTROLLED: over 200 000 steps the robot fell to **z = −743 161 m**, dragged by four
/// contacts pinned where its feet used to be, and the solver spent 60 iterations per step
/// fighting a configuration that no longer described anything. The first reading of that case
/// was 52 415 ns/step, and it was a measurement of nonsense.
///
/// Real use always has a controller, and MuJoCo's `mj_step` computes its actuators inside the
/// timed region too, so including one is also what makes the comparison like-for-like.
const Hold = struct {
    home: []const f32,
    kp: f32,
    kv: f32,
    limit: f32,

    /// Re-derive each foot's contact from where the foot actually is.
    ///
    /// ★★ A REPLAYED CONTACT MUST STILL FOLLOW ITS BODY. Pinning position and depth once and
    /// replaying them unchanged is not "holding the contacts fixed" — it is feeding the solver
    /// a claim that gets less true every step, and it never converges because it is being
    /// asked to satisfy something that no longer describes the geometry.
    ///
    /// A sphere foot on a ground plane needs no broad phase to place: the contact is directly
    /// beneath the foot, and its depth is the foot's height below the plane. That keeps
    /// zimrphysics out of the timed region — the number being measured is the robot's solver —
    /// while leaving the contacts TRUE, which is the part that matters.
    fn refreshFeet(model: *const rbt.Model, data: *rbt.Data) void {
        data.clearContacts();
        for (0..model.ngeom) |g| {
            const radius: f32 = switch (model.geom_shape[g]) {
                .sphere => |sph| sph.radius,
                else => continue,
            };
            const body: u32 = model.geom_body[g];
            const at: zm.Vec = data.body_xpos[body] + zm.rotate(data.body_xrot[body], model.geom_pos[g]);
            const gap: f32 = at[2] - radius;
            if (gap > 0.01) {
                continue; // clear of the floor
            }
            data.pushContact(.{
                .position = vec(at[0], at[1], 0),
                .normal = vec(0, 0, 1),
                .tangent = .{ vec(1, 0, 0), vec(0, 1, 0) },
                .distance = gap,
                .friction = .{ 0.8, 0.8 },
                .body_a = rbt.world_body,
                .body_b = body,
                .id = g,
            });
        }
    }

    fn apply(self: Hold, model: *const rbt.Model, data: *rbt.Data) void {
        refreshFeet(model, data);
        @memset(data.applied_force, 0);
        for (0..model.njnt) |j| {
            if (model.jnt_type[j] != .hinge) {
                continue;
            }
            const q: u32 = model.jnt_qpos_adr[j];
            const v: u32 = model.jnt_dof_adr[j];
            const wanted: f32 = self.kp * (self.home[q] - data.pos[q]) - self.kv * data.vel[v];
            data.applied_force[v] = zm.clamp(wanted, -self.limit, self.limit) + data.bias_force[v];
        }
    }
};

fn benchmark(
    comptime label: []const u8,
    model: *rbt.Model,
    data: *rbt.Data,
    steps: usize,
) void {
    benchmarkHeld(label, model, data, steps, null);
}

fn benchmarkHeld(
    comptime label: []const u8,
    model: *rbt.Model,
    data: *rbt.Data,
    steps: usize,
    hold: ?Hold,
) void {
    // Warm the caches and let any first-call cost fall outside the timed region.
    for (0..1000) |_| {
        if (hold) |h| {
            h.apply(model, data);
        }
        rbt.step(model, data);
    }

    // ★ ITERATION COUNT IS A DISTRIBUTION, NOT A NUMBER. `data.solver_iterations` holds
    // whatever the LAST step happened to need, and on a warm steady-state Go1 that
    // fluctuates between 1 and 15 from step to step — so a single sample reported as
    // "solver N it" is a coin flip, and two runs of the same benchmark print different
    // numbers for identical work. Accumulate instead: the mean says what the solver
    // typically costs, the max says whether anything is ever hard.
    var iter_total: u64 = 0;
    var iter_max: u32 = 0;
    const started: u64 = monotonicNanos();
    for (0..steps) |_| {
        if (hold) |h| {
            h.apply(model, data);
        }
        rbt.step(model, data);
        iter_total += data.solver_iterations;
        iter_max = @max(iter_max, data.solver_iterations);
    }
    const elapsed_ns: u64 = monotonicNanos() - started;
    const per_step: f64 = toF64(elapsed_ns) / toF64(steps);
    const iter_mean: f64 = toF64(iter_total) / toF64(steps);

    // Realtime factor: how many seconds of simulation per second of wall clock. The number
    // a control loop actually cares about.
    const realtime: f64 = @as(f64, model.opt.timestep) / (per_step * 1.0e-9);
    // lint:off debug-print: a native benchmark whose output is the deliverable
    std.debug.print(
        "{s:<28} nv {d:>2}  {d:>8.0} ns/step  {d:>7.0}x rt  nc {d}  solver {d:.1} it mean, {d} max\n",
        .{ label, model.nv, per_step, realtime, data.constraint_count, iter_mean, iter_max },
    );
}

fn toF64(x: anytype) f64 {
    return @floatFromInt(x);
}

/// Break one model's step down by pipeline stage, using the profiler zones that
/// `robot.zig` already carries.
///
/// ── ★★★ WHY THIS EXISTS, AND WHY THE OBVIOUS ALTERNATIVE IS WORTHLESS ──
///
/// The tempting way to break a pipeline down is to call each stage 50 000 times in a
/// loop and sum. Measured that way this model reports a total of **3567 ns against a
/// real step of 12 874**, with `solveConstraints` the cheapest thing in it at 593 ns.
/// Both numbers are artefacts of the method: **a stage called repeatedly on an
/// unchanging state is being re-run on its own output.** `solveConstraints` on an
/// already-solved state converges in zero iterations; `factorM` refactors an unchanged
/// matrix out of warm cache. A loop is all second calls.
///
/// ★ AND THE SECOND OBVIOUS METHOD IS WRONG DIFFERENTLY: full step versus step with the
/// contacts cleared "isolates the constraint path" at a tidy 65% — except clearing them
/// also removes the controller and the foot placement, if those live in the same helper.
/// An A/B that changes two things measures neither.
///
/// The zones are inside a REAL step, in sequence, on a state that keeps evolving, so
/// each one is timed doing the work it actually does. That is the whole point of having
/// instrumented the engine rather than the benchmark.
fn profileStages(
    comptime label: []const u8,
    model: *rbt.Model,
    data: *rbt.Data,
    hold: ?Hold,
) void {
    if (!profiler.enabled) {
        // lint:off debug-print: a native benchmark whose output is the deliverable
        std.debug.print("   (stage breakdown needs the profiler: -Dmode=release, not ship)\n", .{});
        return;
    }
    profiler.setClock(&profilerClockMs);
    profiler.reset();
    // ★ THE FRAME RING HOLDS 256 AND SILENTLY KEEPS THE NEWEST. Asking for 400 frames
    // does not fail — `aggregate` just summarises the 256 it still has, and every
    // "calls per step" figure computed against 400 came out at 0.64 of the truth. The
    // tell was that EVERY row read x0.6, including ones called exactly once per step.
    // A ratio that is identical across unrelated rows is a property of the divisor.
    // Stay inside the ring instead of correcting for it.
    const frames: usize = 200;
    for (0..frames) |_| {
        if (hold) |h| {
            h.apply(model, data);
        }
        rbt.step(model, data);
        profiler.frameMark();
    }

    var stats: [256]profiler.SrcStat = undefined;
    const n: usize = profiler.aggregate(stats[0..]);
    // lint:off debug-print: a native benchmark whose output is the deliverable
    std.debug.print("\n   stage breakdown — {s} (profiler zones, inside real steps)\n", .{label});
    var step_ns: f64 = 0;
    for (stats[0..n]) |st| {
        if (st.count == 0) {
            continue;
        }
        if (eql(u8, profiler.srcOf(st.src).name, "robot.step")) {
            step_ns = st.total_ms * 1.0e6 / toF64(st.count);
        }
    }
    for (stats[0..n]) |st| {
        if (st.count == 0) {
            continue;
        }
        const name: []const u8 = profiler.srcOf(st.src).name;
        const per_call: f64 = st.total_ms * 1.0e6 / toF64(st.count);
        const calls: f64 = toF64(st.count) / toF64(frames);
        // Share of a step, normalised against `robot.step`'s own zone rather than
        // against the wall-clock figure above: same clock, same window, so the two
        // cannot disagree about what a step was.
        const share: f64 = if (step_ns > 0) 100.0 * per_call * calls / step_ns else 0;
        // lint:off debug-print: a native benchmark whose output is the deliverable
        std.debug.print(
            "     {s:<22} {d:>8.0} ns/call  x{d:>4.1}/step  {d:>5.1}%\n",
            .{ name, per_call, calls, share },
        );
    }
    // ★ `robot.step` and `robot.forward` are OUTER zones: their share is ~100% and ~most,
    // and the inner rows sum to less than either. The gap is real work that no zone wraps
    // — integration, the passive and actuation stages, sensors — not measurement error.
    // lint:off debug-print: a native benchmark whose output is the deliverable
    std.debug.print(
        "     (step/forward are OUTER zones; inner rows sum to less, and the gap is\n" ++
            "      unzoned work rather than lost time)\n",
        .{},
    );
}

/// The profiler wants milliseconds as an f64.
fn profilerClockMs() f64 {
    return toF64(monotonicNanos()) * 1.0e-6;
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa: Allocator = debug_allocator.allocator();

    // lint:off debug-print: a native benchmark whose output is the deliverable
    std.debug.print("\n=== robot.zig, {d} steps each, single-threaded ===\n", .{steps_per_case});

    // ---- 1. two links, no contact ----
    {
        var m: rbt.Model = try TwoLink.build(gpa);
        defer m.deinit();
        var d: rbt.Data = try rbt.Data.init(gpa, &m);
        defer d.deinit();
        d.pos[0] = 1.1;
        d.pos[1] = -0.6;
        benchmark("1. two-link arm", &m, &d, steps_per_case);
    }

    // ---- 2. a 7-DOF KUKA, no contact ----
    {
        var m: rbt.Model = try kuka.Model.build(gpa);
        defer m.deinit();
        m.opt.timestep = 1.0 / 240.0;
        var d: rbt.Data = try rbt.Data.init(gpa, &m);
        defer d.deinit();
        d.pos[1] = 0.6;
        d.pos[3] = -0.9;
        benchmark("2. KUKA iiwa, free", &m, &d, steps_per_case);
    }

    // ---- 3. the same, with limits active ----
    //
    // Every joint driven hard against a limit, so the constraint rows are live every step.
    // The difference from case 2 is the whole cost of the constraint path: row assembly,
    // the exact Â, and the solver.
    {
        var m: rbt.Model = try kuka.Model.build(gpa);
        defer m.deinit();
        m.opt.timestep = 1.0 / 240.0;
        // Narrow every joint's range around its current pose so the limits engage.
        for (0..m.njnt) |ji| {
            m.jnt_range[ji] = .{ -0.05, 0.05 };
        }
        var d: rbt.Data = try rbt.Data.init(gpa, &m);
        defer d.deinit();
        for (0..m.nv) |i| {
            d.pos[i] = 0.3; // outside every limit
        }
        rbt.forward(&m, &d);
        benchmark("3. KUKA, all limits active", &m, &d, steps_per_case);
    }

    // lint:off debug-print: a native benchmark whose output is the deliverable
    // ---- 4. a real quadruped, standing, with real contacts ----
    //
    // ★ THE CASE THE OTHER THREE DO NOT COVER. Cases 1–3 are articulated dynamics with at
    // most five limit rows; none of them has a CONTACT. A Go1 holding its home pose runs
    // 30–60 constraint rows against the floor, which is the regime the roadmap's Phase C
    // actually lives in and the one where the solver's cost per row shows up.
    //
    // Contacts are held FIXED for the timed region — harvested once from a settled stance
    // and then replayed — because the point is to measure the robot's solver, not
    // zimrphysics' broad phase. Mixing the two would make the number un-attributable, and
    // MuJoCo's `mj_step` does its own collision detection, so a like-for-like comparison
    // needs the detector excluded from both sides.
    // ── ★ AND THE SAME CASE UNDER BOTH SOLVERS ──
    //
    // PGS and Newton have different asymptotics AND different per-iteration costs, so one
    // number for either says nothing. Newton is O(nv³) for its Cholesky plus O(rows·nv²) to
    // build the Hessian; PGS is O(rows·nv) per sweep. A standing Go1 — nv 18, sixteen rows,
    // barely coupled — is the case PGS should win, and this is where that gets checked rather
    // than assumed. The default does not move until it does.
    inline for (.{ rbt.Algorithm.pgs, rbt.Algorithm.newton }) |algorithm| {
        var doc: codecs.xml.Document = try codecs.xml.parse(gpa, go1_xml, null);
        defer doc.deinit();
        var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
        defer robot.deinit();
        var options: rbt.Options = .{
            .max_contacts = 128,
            .timestep = 1.0 / 500.0,
            .gravity = vec(0, 0, -9.81),
        };
        options.solver.algorithm = algorithm;
        var imported: rmj.Imported = try rmj.build(gpa, &robot, options);
        defer imported.deinit();
        var d: rbt.Data = try rbt.Data.init(gpa, &imported.model);
        defer d.deinit();
        if (!rmj.applyKeyframe(&imported.model, &d, robot.keyframes[0])) {
            // ★ A BENCHMARK MUST NOT RUN ON A POSE IT FAILED TO SET. `applyKeyframe`
            // returns false rather than trapping, and a discarded result here would time a
            // Go1 splayed flat at qpos0 under a label saying "standing".
            return error.KeyframeRejected;
        }
        rbt.forward(&imported.model, &d);
        // The contacts come from `Hold.refreshFeet`, which runs before every step —
        // including the warmup — and derives each foot's position and depth from where the
        // foot geom actually is. Nothing is seeded here on purpose: an initial set would be
        // overwritten before the first timed step, and a second copy of this logic is a
        // second place to get the sphere's centre-vs-body offset wrong.
        const home: []f32 = try gpa.dupe(f32, robot.keyframes[0].qpos);
        defer gpa.free(home);
        // ★ THE CASE VERIFIES ITSELF. Two earlier readings of this benchmark were nonsense
        // because the robot was not doing what the label claimed — first falling to −743 km
        // uncontrolled, then dragged by contacts pinned where its feet had been. A benchmark
        // that does not check its own premise measures whatever it happens to be doing.
        const trunk: u32 = imported.bodyIndex("trunk") orelse 1;
        const hold: Hold = .{
            .home = home,
            // ★★ kp 100 PASSED THE OLD HEIGHT-BOX CHECK WHILE SITTING 18° OFF POSE.
            //
            // A P term produces torque only in proportion to error, so a joint holding a
            // static load MUST sit off its target — that is the controller working, not
            // failing. The question is how far off, and the old check (trunk height in a
            // 0.20–0.35 box, a ±28% window) could not see it. Measured, 20 000 held steps:
            //
            //     kp 100   trunk z 0.3325   worst |q − home| 0.3134 rad (18.0°)
            //     kp 300   trunk z 0.3032   worst |q − home| 0.1024 rad ( 5.9°)
            //
            // Gravity compensation is NOT the driver — bisected: with it 0.3325, without it
            // 0.3330. It is the P gain, and 300 is what makes "holding its home pose"
            // literally true. The extra stiffness costs nothing in the timed region: the
            // solver sees the same sixteen rows either way.
            .kp = 300.0,
            .kv = 2.0,
            .limit = 35.55,
        };
        benchmarkHeld(
            "4. Go1 standing, 4 contacts, " ++ @tagName(algorithm),
            &imported.model,
            &d,
            steps_per_case,
            hold,
        );
        rbt.forward(&imported.model, &d);
        // ★ ASSERT THE PREMISE THE CONTROLLER IS ACTUALLY SERVOING. The PD acts on JOINT
        // ANGLES, so joint error is the direct measurement; trunk height is a downstream
        // consequence that a robot can satisfy while badly out of pose. Both are printed,
        // and the reference height is READ FROM THE KEYFRAME — it used to be the literal
        // string "0.2700" in the format, which would have kept printing after any edit to
        // the model.
        const height: f32 = d.body_xpos[trunk][2];
        const home_height: f32 = home[2];
        var worst_joint_error: f32 = 0;
        for (0..imported.model.njnt) |ji| {
            if (imported.model.jnt_type[ji] != .hinge) {
                continue;
            }
            const qi: u32 = imported.model.jnt_qpos_adr[ji];
            worst_joint_error = @max(worst_joint_error, @abs(d.pos[qi] - home[qi]));
        }
        const holding: bool = worst_joint_error < 0.15;
        // lint:off debug-print: a native benchmark whose output is the deliverable
        std.debug.print(
            "   (trunk z {d:.4} vs home {d:.4}; worst |q-home| {d:.4} rad — holding pose: {any})\n",
            .{ height, home_height, worst_joint_error, holding },
        );
        if (!holding) {
            return error.BenchmarkPremiseViolated;
        }
        // Only for PGS: the breakdown is about where a step goes, and running it twice
        // for two solvers doubles the output to show one differing row.
        profileStages("Go1 standing, " ++ @tagName(algorithm), &imported.model, &d, hold);
    }

    // lint:off debug-print: a native benchmark whose output is the deliverable
    std.debug.print(
        "\ncompare against scripts/robot_bench_mujoco.py on the same machine.\n" ++
            "§4g: parity or better is the goal; report the cases SEPARATELY.\n\n",
        .{},
    );
}
