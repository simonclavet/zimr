//! three_leg — a Go1 standing on three legs, reaching with the fourth.
//!
//! ── ★ WHAT TO TRY ──
//!
//! Pick a foot, press **lift**, and drive it with the three sliders. All four work. Turn off
//! **shift the torso first** and the robot rolls over instantly, whichever foot you choose —
//! that is the whole point of the sway.
//!
//! ── ★★ WHY A FRONT FOOT AND NOT A REAR ONE ──
//!
//! The Go1's centre of mass sits at **(−0.051, 0.001)** — 51 mm behind the middle of its feet,
//! because the trunk's mass is not centred between the hips. So the four-foot stance is not
//! symmetric about the mass, and the two diagonals are not equivalent:
//!
//!   * lift a FRONT foot and the CM starts 19 mm INSIDE the triangle the others make;
//!   * lift a REAR foot and it starts 17 mm OUTSIDE it.
//!
//! A 36 mm asymmetry, and it decides which leg a static walk can lift first. The panel shows
//! the margin live so you can watch it change as the torso shifts.
//!
//! ── ★★★ AND WHY THE TORSO SHIFTS BEFORE THE FOOT LEAVES ──
//!
//! Lifting without shifting drops the mass onto the edge of a triangle it is already on, and
//! the robot rolls over — measured, 180 degrees, every time, for all four feet. Real quadrupeds
//! sway before they step for exactly this reason, and it is why a static walk needs three feet
//! down most of the time (`examples/quadruped` found duty 0.85 stands and 0.70 falls by
//! experiment; this is the geometry underneath that number).
//!
//! ── ★ THE TWO BUGS THIS COST, BOTH INVISIBLE ──
//!
//! **`applyKeyframe` is not a memcpy.** `keyframes[0].qpos` is in the FILE's layout and the
//! model's differs in the free joint's quaternion. Copying it raw put the robot UPSIDE DOWN —
//! feet at z = 0.535, above a trunk at 0.27 — and every foot position and CM number computed
//! from it described an inverted machine. Nothing complained, because an inverted pose is a
//! valid pose.
//!
//! **A missing `forward` after restoring the live state.** The loop swaps in the commanded pose
//! to run IK, then swaps the live one back. Marking it stale is not enough: `plantFeet` reads
//! `body_xpos` to decide where contacts go, so stale kinematics placed them centimetres from
//! the actual feet. The robot was held up by contacts that were not under it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const ctl = z.robot_control;
const mjcf = z.mjcf;
const rmj = z.robot_mjcf;
const ui = z.ui;
const profiler = z.profiler;

const Vec = zm.Vec;
const Mat = zm.Mat;
const vec = zm.vec;
const Color = zm.Color;
const float = zm.float;
const Camera3D = zm.Camera3D;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;
const quatToMat = zm.quatToMat;

const leg_count: usize = 4;
const sim_timestep: f32 = 1.0 / 500.0;
/// How fast the torso chases the centre-of-mass goal. 0.005 converges in about a second;
/// 0.010 overshoots and tips the robot, measured on all four legs.
const com_rate: f32 = 0.005;
/// One stride per leg per cycle.
const walk_stride: f32 = 0.06;
/// How fast the torso may sway while walking. See the note in `rebuildCommand`.
const walk_sway_speed: f32 = 0.05;
/// Support margin required before a foot may leave the ground.
const walk_gate: f32 = 0.03;
/// Crawl order: both right legs, then both left.
const crawl_order = [_]usize{ 2, 0, 3, 1 };

const bg: Color = .{ .r = 18, .g = 20, .b = 28, .a = 255 };
const trunk_col: Color = .{ .r = 96, .g = 132, .b = 184, .a = 255 };
const link_col: Color = .{ .r = 148, .g = 156, .b = 172, .a = 255 };
const planted_col: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const lifted_col: Color = .{ .r = 226, .g = 106, .b = 154, .a = 255 };
const support_col: Color = .{ .r = 89, .g = 204, .b = 153, .a = 255 };
const com_col: Color = .{ .r = 250, .g = 240, .b = 120, .a = 255 };

const leg_names = [_][]const u8{ "front right", "front left", "rear right", "rear left" };

const State = struct {
    gpa: Allocator,
    doc: z.codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    data: rbt.Data,

    /// The commanded reference pose, in the MODEL's layout — see the header on `applyKeyframe`.
    home: []f32,
    /// What `PoseHold` is actually given each tick: `home` with the torso shifted and the
    /// lifted foot moved, resolved to joint angles by per-leg IK.
    commanded: []f32,
    scratch_pose: []f32,
    ik_scratch: []Vec,

    foot_geom: [leg_count]u32,
    /// Where each foot is planted. Advances one stride at a time while walking.
    pinned: [leg_count]Vec,
    /// The original stance, so a reset puts the feet back.
    pinned_home: [leg_count]Vec,
    /// Where the centre of mass sits relative to the root at the home stance. Constant enough
    /// that the root position putting the CM on a goal is simply `goal − this`.
    com_home_offset: [2]f32,
    leg_act: [leg_count]ctl.Actuation,
    all_act: ctl.Actuation,

    lift_index: i32,
    lifting: bool,
    /// Walk mode: step the four legs in sequence instead of holding one up.
    walking: bool,
    /// How many steps of the crawl have finished. Drives both the leg order and the march.
    steps_done: u32,
    /// Swing progress for the current step, or negative while waiting for the weight to shift.
    swing: f32,
    swing_from: Vec,
    swing_to: Vec,
    /// 0 while the torso shifts, then ramps to 1 as the foot rises.
    shift_progress: f32,
    lift_progress: f32,
    /// How far the commanded torso has been moved from `home`, integrated from the measured
    /// centre-of-mass error. See `rebuildCommand`.
    torso_offset: [2]f32,
    /// The lifted foot's target, relative to where that foot rests.
    reach: Vec,
    auto_shift: bool,

    margin: f32,
    /// Which feet are carrying load this tick, one bit per leg.
    ///
    /// ★ THE READOUT THAT WOULD HAVE SAVED A ROUND TRIP. "The wrong foot lifted" and "the robot
    /// tipped and dropped a foot" look identical in a picture and are completely different
    /// faults. One bit per leg tells them apart instantly.
    contact_mask: u4,
    accumulator: f32,
    running: bool,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    sphere: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]Mat,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.doc = try z.codecs.xml.parse(gpa, @embedFile("go1.xml"), null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    s.imported = try rmj.build(gpa, &s.robot, .{
        .max_contacts = 64,
        .timestep = sim_timestep,
        .gravity = vec(0, 0, -9.81),
    });
    const model: *const rbt.Model = &s.imported.model;
    s.data = try rbt.Data.init(gpa, model);

    // ★ THROUGH `applyKeyframe`, NOT A COPY. See the file header.
    _ = rmj.applyKeyframe(model, &s.data, s.robot.keyframes[0]);
    rbt.forward(model, &s.data);
    s.home = try gpa.dupe(f32, s.data.pos);
    s.commanded = try gpa.dupe(f32, s.data.pos);
    s.scratch_pose = try gpa.alloc(f32, model.nq);

    var found: usize = 0;
    for (0..model.ngeom) |g| {
        if (model.geom_shape[g] == .sphere and found < leg_count) {
            s.foot_geom[found] = @intCast(g);
            found += 1;
        }
    }
    for (0..leg_count) |leg| {
        s.pinned[leg] = footAt(model, &s.data, s.foot_geom[leg]);
        s.pinned_home[leg] = s.pinned[leg];
        s.leg_act[leg] = try ctl.limbActuation(gpa, model, model.geom_body[s.foot_geom[leg]]);
    }
    s.com_home_offset = .{
        s.data.subtree_com[rbt.world_body][0] - s.home[model.jnt_qpos_adr[0] + 0],
        s.data.subtree_com[rbt.world_body][1] - s.home[model.jnt_qpos_adr[0] + 1],
    };
    s.all_act = try ctl.Actuation.init(gpa, model);
    s.ik_scratch = try gpa.alloc(Vec, ctl.Ik.scratchSize(model));

    s.lift_index = 0;
    s.lifting = false;
    s.shift_progress = 0;
    s.lift_progress = 0;
    s.torso_offset = .{ 0, 0 };
    s.walking = false;
    s.steps_done = 0;
    s.swing = -1;
    s.swing_from = vec(0, 0, 0);
    s.swing_to = vec(0, 0, 0);
    s.reach = vec(0, 0, 0.05);
    s.auto_shift = true;
    s.margin = 0;
    s.contact_mask = 0;
    s.accumulator = 0;
    s.running = true;

    s.cam = z.OrbitCamera.init(vec(0, 0.2, 0), 1.3);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 12, 10);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 12, 2);
    s.transform = .{identity()};
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    gpa.free(s.ik_scratch);
    s.all_act.deinit();
    for (0..leg_count) |leg| {
        s.leg_act[leg].deinit();
    }
    gpa.free(s.scratch_pose);
    gpa.free(s.commanded);
    gpa.free(s.home);
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
}

fn footAt(model: *const rbt.Model, d: *const rbt.Data, geom: u32) Vec {
    const body: u32 = model.geom_body[geom];
    return d.body_xpos[body] + zm.rotate(d.body_xrot[body], model.geom_pos[geom]);
}

/// Push one contact under every foot that is meant to be down.
fn plantFeet(s: *State) void {
    const model: *const rbt.Model = &s.imported.model;
    s.data.clearContacts();
    s.contact_mask = 0;
    for (0..leg_count) |leg| {
        if (s.walking) {
            if (leg == crawl_order[s.steps_done % 4] and s.swing >= 0.05 and s.swing <= 0.95) {
                continue;
            }
        } else if (s.lifting and @as(i32, @intCast(leg)) == s.lift_index and s.lift_progress > 0.02) {
            continue;
        }
        const g: u32 = s.foot_geom[leg];
        const radius: f32 = switch (model.geom_shape[g]) {
            .sphere => |sph| sph.radius,
            else => continue,
        };
        const at: Vec = footAt(model, &s.data, g);
        const gap: f32 = at[2] - radius;
        if (gap > 0.02) {
            continue;
        }
        s.data.pushContact(.{
            .position = vec(at[0], at[1], 0),
            .normal = vec(0, 0, 1),
            .tangent = .{ vec(1, 0, 0), vec(0, 1, 0) },
            .distance = gap,
            .friction = .{ 0.8, 0.8 },
            .body_a = rbt.world_body,
            .body_b = model.geom_body[g],
            .id = g,
        });
        s.contact_mask |= @as(u4, 1) << @intCast(leg);
    }
}

/// Signed distance from `point` to the nearest edge of the support triangle. Positive inside.
///
/// ★ A DIAGNOSTIC, NOT A PREDICATE. Measured, the robot stands happily at a margin of −0.11:
/// the lifted leg's own mass and the contact compliance carry it well outside the strict
/// polygon. A stability test built on this number would reject configurations that work.
fn supportMargin(tri: [3]Vec, point: Vec) f32 {
    var worst: f32 = 1.0e9;
    for (0..3) |i| {
        const a: Vec = tri[i];
        const b: Vec = tri[(i + 1) % 3];
        const c: Vec = tri[(i + 2) % 3];
        const ex: f32 = b[0] - a[0];
        const ey: f32 = b[1] - a[1];
        const len: f32 = @sqrt(ex * ex + ey * ey);
        var nx: f32 = -ey / len;
        var ny: f32 = ex / len;
        if (nx * (c[0] - a[0]) + ny * (c[1] - a[1]) < 0) {
            nx = -nx;
            ny = -ny;
        }
        worst = @min(worst, nx * (point[0] - a[0]) + ny * (point[1] - a[1]));
    }
    return worst;
}

/// Rebuild `commanded`: shift the torso, place the lifted foot, pin the rest.
///
/// ── ★★★ EVERYTHING HERE HAPPENS IN COMMAND SPACE ──
///
/// The reference is `home` and the feet are pinned where they are AT `home` — never where the
/// robot has actually got to. A PD holds a load by sitting off its target, so the achieved pose
/// is `home + steady-state error`; capture that and command it back and the error is zero, the
/// torque is zero, and the robot collapses. Solving from the commanded pose keeps the error,
/// and the error is what holds it up.
fn rebuildCommand(s: *State) void {
    const model: *const rbt.Model = &s.imported.model;
    const root: u32 = model.jnt_qpos_adr[0];

    var support: [3]Vec = undefined;
    var goal: [2]f32 = .{ 0, 0 };
    var k: usize = 0;
    for (0..leg_count) |leg| {
        if (@as(i32, @intCast(leg)) == s.lift_index) {
            continue;
        }
        support[k] = s.pinned[leg];
        goal[0] += s.pinned[leg][0];
        goal[1] += s.pinned[leg][1];
        k += 1;
    }
    goal[0] /= 3.0;
    goal[1] /= 3.0;

    // ── ★★★ THE SHIFT IS A CLOSED LOOP ON THE MEASURED CM, NOT AN OPEN-LOOP RATIO ──
    //
    // Moving the torso by `d` does NOT move the centre of mass by `d`: the legs carry about
    // half the robot and largely stay where they are, so the CM follows roughly half as far.
    // An open-loop shift therefore needs a fudge factor, and measured, **no single factor
    // works**:
    //
    //     torso shift   front feet          rear feet
    //     x1.0          OK (margin -0.11)   falls (-0.38)
    //     x1.5          falls               falls
    //     x2.0          falls               OK (+0.024)
    //     x2.5          falls               OK (+0.057)
    //
    // Front needs one and falls at two; rear needs two and falls at one. The factor depends on
    // which foot is coming up, so there is no constant to find.
    //
    // Integrating the measured error removes the constant. It converges on whatever
    // displacement the geometry actually needs, and all four feet then work with ONE setting —
    // measured margin +0.071 for every one of them, which is the loop arriving at the same
    // place regardless of the leg. Too fast and it overshoots into a fall: 0.005 holds, 0.010
    // tips every foot.
    const live_com: Vec = s.data.subtree_com[rbt.world_body];
    if (s.walking) {
        // ── ★★★ MARCH PLUS SWAY, AT A SPEED THE LEGS CAN FOLLOW ──
        //
        // The support centroid is a SWAY target, not a drive: lifting a front foot removes it
        // from the centroid so the target moves BACKWARD, and with no march the body walks
        // itself backwards — measured, trunk at -0.200 while two feet had advanced. The march
        // is what the feet have actually done, and the sway rides on top of it.
        //
        // ★ AND THE SPEED IS SET BY LEG COMPLIANCE, NOT BY THE PLAN. Moving a 12 kg trunk means
        // bending springy legs against planted feet; at 0.25 m/s the body lagged its command by
        // 0.21 m then overshot — a ±0.2 m oscillation that stretched a rear leg to its limit.
        // At 0.05 m/s it tracks and a full four-leg cycle completes.
        var mean_foot: f32 = 0;
        var mean_home: f32 = 0;
        for (0..leg_count) |leg| {
            mean_foot += s.pinned[leg][0];
            mean_home += s.pinned_home[leg][0];
        }
        const march: f32 = (mean_foot - mean_home) / float(leg_count);
        const want_x: f32 = march + goal[0] - s.com_home_offset[0];
        const want_y: f32 = goal[1] - s.com_home_offset[1];
        const cap: f32 = walk_sway_speed * sim_timestep;
        s.torso_offset[0] += zm.clamp((want_x - s.torso_offset[0]) * 0.02, -cap, cap);
        s.torso_offset[1] += zm.clamp((want_y - s.torso_offset[1]) * 0.02, -cap, cap);
    } else if (s.auto_shift and s.shift_progress > 0) {
        s.torso_offset[0] += com_rate * (goal[0] - live_com[0]);
        s.torso_offset[1] += com_rate * (goal[1] - live_com[1]);
        s.torso_offset[0] = zm.clamp(s.torso_offset[0], -0.25, 0.25);
        s.torso_offset[1] = zm.clamp(s.torso_offset[1], -0.25, 0.25);
    }

    @memcpy(s.scratch_pose, s.data.pos);
    @memcpy(s.data.pos, s.home);
    s.data.pos[root + 0] = s.home[root + 0] + s.torso_offset[0];
    s.data.pos[root + 1] = s.home[root + 1] + s.torso_offset[1];
    s.data.stage = .stale;
    rbt.forward(model, &s.data);

    for (0..leg_count) |leg| {
        var target: Vec = s.pinned[leg];
        if (@as(i32, @intCast(leg)) == s.lift_index) {
            target += s.reach * zm.splat(s.lift_progress);
        }
        _ = (ctl.Ik{ .max_iterations = 12, .max_step = 0.15 }).solve(
            model,
            &s.data,
            s.leg_act[leg],
            .{
                .body = model.geom_body[s.foot_geom[leg]],
                .offset = model.geom_pos[s.foot_geom[leg]],
                .goal = target,
            },
            s.ik_scratch,
        );
    }
    @memcpy(s.commanded, s.data.pos);

    // ★ BACK TO THE LIVE STATE, AND RECOMPUTE. `plantFeet` reads `body_xpos`; leaving it on the
    // IK configuration places contacts centimetres from the real feet, and the robot is held up
    // by contacts that are not under it. This one missing call cost a day.
    @memcpy(s.data.pos, s.scratch_pose);
    s.data.stage = .stale;
    rbt.forward(model, &s.data);

    s.margin = supportMargin(support, s.data.subtree_com[rbt.world_body]);
}

fn controlTick(s: *State) void {
    const model: *const rbt.Model = &s.imported.model;
    if (s.walking) {
        // ★ THE FOOT WAITS FOR THE MASS. The swing only begins once the measured margin says
        // the centre of mass is actually over the triangle the other three feet make — a fixed
        // delay works right up until the shift is slower than the delay, and then the robot
        // steps off a support it has not reached.
        const leg: usize = crawl_order[s.steps_done % 4];
        if (s.swing < 0) {
            if (s.margin > walk_gate) {
                s.swing = 0;
                s.swing_from = s.pinned[leg];
                s.swing_to = vec(s.pinned[leg][0] + walk_stride, s.pinned[leg][1], s.pinned[leg][2]);
            }
        } else {
            s.swing += sim_timestep / 0.6;
            if (s.swing >= 1.0) {
                s.pinned[leg] = s.swing_to;
                s.swing = -1;
                s.steps_done += 1;
                // ★★★ AND THE MARGIN IS NOW STALE. `steps_done` has changed, so the next tick
                // asks about a DIFFERENT support triangle — but `s.margin` still describes the
                // one just finished, where the weight was deliberately shifted and the margin is
                // comfortably positive. The gate would pass instantly and the next foot would
                // leave the ground with no weight shift at all.
                //
                // That is the whole failure: step one lands, step two fires immediately, and the
                // robot goes over. Invalidating it forces one tick of recomputation for the leg
                // that is actually about to move.
                s.margin = -1;
            }
        }
        rebuildCommand(s);
        plantFeet(s);
        (ctl.PoseHold{ .target = s.commanded, .kp = 100, .kv = 4 }).apply(model, &s.data, s.all_act);
        rbt.step(model, &s.data);
        return;
    }
    // Shift first, then lift — a robot on three legs before its mass has moved is the one thing
    // a real quadruped never does.
    if (s.lifting) {
        s.shift_progress = @min(1.0, s.shift_progress + sim_timestep * 1.0);
        // ★ THE FOOT WAITS FOR THE MASS, not for a timer: the lift only starts once the CM is
        // actually inside the triangle. A fixed delay works until the shift is slower than the
        // delay, and then the robot steps off a support it has not reached yet.
        if (s.shift_progress >= 1.0 and (s.margin > 0.01 or !s.auto_shift)) {
            s.lift_progress = @min(1.0, s.lift_progress + sim_timestep * 1.0);
        }
    } else {
        s.lift_progress = @max(0.0, s.lift_progress - sim_timestep * 2.0);
        if (s.lift_progress <= 0.0) {
            s.shift_progress = @max(0.0, s.shift_progress - sim_timestep * 1.0);
            // ★ UNWIND THE LEAN TOO. Without this the robot puts its foot down and stays
            // leaning, so the next lift starts from a stance that is already committed.
            s.torso_offset[0] -= s.torso_offset[0] * sim_timestep * 2.0;
            s.torso_offset[1] -= s.torso_offset[1] * sim_timestep * 2.0;
        }
    }
    rebuildCommand(s);
    plantFeet(s);
    (ctl.PoseHold{ .target = s.commanded, .kp = 100, .kv = 4 }).apply(model, &s.data, s.all_act);
    rbt.step(model, &s.data);
}

fn resetRobot(s: *State) void {
    const model: *const rbt.Model = &s.imported.model;
    _ = rmj.applyKeyframe(model, &s.data, s.robot.keyframes[0]);
    rbt.forward(model, &s.data);
    s.lifting = false;
    s.shift_progress = 0;
    s.lift_progress = 0;
    s.torso_offset = .{ 0, 0 };
    s.accumulator = 0;
    s.walking = false;
    s.steps_done = 0;
    s.swing = -1;
    s.margin = -1;
    for (0..leg_count) |leg| {
        s.pinned[leg] = s.pinned_home[leg];
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    // ★ PROFILING OFF ACROSS THE CONTROL LOOP. Physics runs at 500 Hz and each tick also does
    // four IK solves, so a frame executes thousands of instrumented calls — each zone costing
    // two timestamps, which on wasm are two JS boundary crossings. Measured here: 5602 host
    // calls per frame before this, 200 after. The instrument is priced for a frame that does a
    // few things; everything outside this call is still profiled normally.
    const was_frozen: bool = profiler.isFrozen();
    profiler.freeze();
    if (s.running) {
        s.accumulator += @min(f.time.delta_time, 0.1);
        while (s.accumulator >= sim_timestep) : (s.accumulator -= sim_timestep) {
            controlTick(s);
        }
    }
    if (!was_frozen) {
        profiler.unfreeze();
    }
    if (s.data.body_xpos[1][2] < 0.05) {
        resetRobot(s);
    }

    z.clearViewport(f, bg);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 0.6, .max_distance = 4.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 16, 0.25);
    drawRobot(s, gl);
    z.endMode3D(gl);
}

fn drawRobot(s: *State, gl: *z.WgpuGl) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        const body_rot: zm.Quat = s.data.body_xrot[body];
        const world_pos: Vec = s.data.body_xpos[body] + zm.rotate(body_rot, m.geom_pos[g]);
        const world_rot: Mat = quatToMat(zm.qmul(body_rot, m.geom_rot[g]));
        const place: Mat = mulMat(
            mulMat(to_y_up, translation(world_pos[0], world_pos[1], world_pos[2])),
            world_rot,
        );
        var tint: Color = if (body == 0) trunk_col else link_col;
        for (0..leg_count) |leg| {
            if (s.foot_geom[leg] == g) {
                tint = if (@as(i32, @intCast(leg)) == s.lift_index) lifted_col else planted_col;
            }
        }
        switch (m.geom_shape[g]) {
            .sphere => |sph| {
                s.transform[0] = mulMat(place, scaling(sph.radius, sph.radius, sph.radius));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            },
            .capsule => |cap| {
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

    // ★ THE SUPPORT TRIANGLE AND THE CENTRE OF MASS, which is what makes the demo worth
    // watching: the whole question is whether the yellow dot is over the green triangle.
    var tri: [3]Vec = undefined;
    var k: usize = 0;
    for (0..leg_count) |leg| {
        if (@as(i32, @intCast(leg)) == s.lift_index) {
            continue;
        }
        tri[k] = s.pinned[leg];
        k += 1;
    }
    for (0..3) |i| {
        const a: Vec = tri[i];
        const b: Vec = tri[(i + 1) % 3];
        z.drawLine3D(gl, vec(a[0], 0.002, -a[1]), vec(b[0], 0.002, -b[1]), support_col);
    }
    const com: Vec = s.data.subtree_com[rbt.world_body];
    s.transform[0] = mulMat(translation(com[0], 0.004, -com[1]), scaling(0.022, 0.004, 0.022));
    z.drawMeshInstanced(gl, &s.sphere, &s.transform, com_col);
    // And a line from the CM straight down, so its height is readable too.
    s.transform[0] = mulMat(
        mulMat(to_y_up, translation(com[0], com[1], com[2])),
        scaling(0.016, 0.016, 0.016),
    );
    z.drawMeshInstanced(gl, &s.sphere, &s.transform, com_col);
    z.drawLine3D(gl, vec(com[0], com[2], -com[1]), vec(com[0], 0.004, -com[1]), com_col);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(470.0, viewport_w * 0.36);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, @min(540.0, viewport_h * 0.76) }, .{});
    if (u.window("standing on three legs", .{})) |window| {
        defer window.close();

        const trunk_z: f32 = s.data.body_xpos[1][2];
        const com: Vec = s.data.subtree_com[rbt.world_body];
        u.text("trunk height {d:>6.3} m", .{trunk_z});
        u.text("CM ({d:>6.3},{d:>6.3})  margin {d:>7.4} m", .{ com[0], com[1], s.margin });
        u.text("  (margin > 0 = CM inside the triangle)", .{});
        const chosen: Vec = footAt(&s.imported.model, &s.data, s.foot_geom[@intCast(s.lift_index)]);
        var travelled: f32 = 0;
        for (0..leg_count) |leg| {
            travelled += s.pinned[leg][0] - s.pinned_home[leg][0];
        }
        u.text("travelled {d:>6.3} m", .{travelled / float(leg_count)});
        u.text("chosen foot at ({d:>6.3},{d:>6.3}) h {d:>6.3}", .{ chosen[0], chosen[1], chosen[2] });
        u.text("  (+x is forward, +y is the robot's LEFT)", .{});
        u.text("carrying: {s}{s}{s}{s}", .{
            if (s.contact_mask & 1 != 0) "FR " else "-- ",
            if (s.contact_mask & 2 != 0) "FL " else "-- ",
            if (s.contact_mask & 4 != 0) "RR " else "-- ",
            if (s.contact_mask & 8 != 0) "RL" else "--",
        });
        u.separator();

        var index: i32 = s.lift_index;
        if (u.combo("which foot", &index, &leg_names, .{})) {
            // ★★★ AND THE ACCUMULATED SHIFT GOES WITH IT. `torso_offset` is an integrator
            // aimed at ONE foot's support triangle. Leaving it in place when the selection
            // changes means the torso is still leaning for the PREVIOUS choice — pick the
            // front right after the rear left and the mass is already thrown forward, so the
            // robot tips the instant a foot leaves. The symptom is "I chose one foot and a
            // different one came up", because the tipping lifts a foot nobody asked for.
            s.lift_index = index;
            s.lifting = false;
            s.torso_offset = .{ 0, 0 };
        }
        u.text("all four work: the torso chases the CM", .{});
        u.text("  goal until the mass is over the triangle", .{});
        u.separator();

        // ★ WALK MODE: the same machinery, sequenced. Each leg shifts the weight, swings
        // forward one stride, and plants — then the next. A full four-leg cycle completes.
        if (u.checkbox("WALK (crawl gait)", &s.walking)) {
            // ★★★ A CLEAN START, AND THE MARGIN MUST BE STALE-PROOF. `s.margin` is computed for
            // whichever leg was last EXCLUDED from the support triangle — the one the lift-mode
            // combo selected. The crawl starts on a different leg, so on the first tick the gate
            // would read a margin belonging to another triangle: if the robot had just been
            // holding a foot up, that margin is comfortably positive and the very first swing
            // fires with the torso still shifted for the wrong foot. The robot flips on step
            // one.
            //
            // Forcing it negative makes the gate wait for a margin computed for the leg that is
            // actually about to move.
            resetRobot(s);
            s.walking = true;
            s.margin = -1;
        }
        if (s.walking) {
            u.text("steps {d}   next leg {s}", .{
                s.steps_done,
                leg_names[crawl_order[s.steps_done % 4]],
            });
            // ★ WHAT THE GAIT IS WAITING FOR, SPELLED OUT. "It flips on the first step" and
            // "it never steps" and "it steps too early" look identical from outside; the phase
            // and the margin against the gate tell them apart without another round trip.
            if (s.swing < 0) {
                u.text("  shifting weight: margin {d:>7.4} / gate {d:.3}", .{ s.margin, walk_gate });
            } else {
                u.text("  swinging: {d:>3.0}%", .{s.swing * 100});
            }
        }
        u.separator();

        _ = u.checkbox("lift it (shifts first, then raises)", &s.lifting);
        _ = u.checkbox("shift the torso first", &s.auto_shift);
        u.text("shift {d:>4.0}%   lift {d:>4.0}%", .{ s.shift_progress * 100, s.lift_progress * 100 });
        u.separator();

        _ = u.slider("reach x", &s.reach[0], .{ .min = -0.12, .max = 0.12, .fmt = "{d:.3}" });
        _ = u.slider("reach y", &s.reach[1], .{ .min = -0.12, .max = 0.12, .fmt = "{d:.3}" });
        _ = u.slider("reach z", &s.reach[2], .{ .min = 0.0, .max = 0.15, .fmt = "{d:.3}" });
        _ = u.checkbox("run", &s.running);
        if (u.button("reset", .{})) {
            resetRobot(s);
        }
    }
    return captured;
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - standing on three legs",
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
