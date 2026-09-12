//! robot_contact — a robot arm that touches the world.
//!
//! The scene phase 7 was written for, and the first one where both engines have to agree
//! about something. An actuated two-link arm sweeps across a table; a crate sits on the
//! table waiting to be hit.
//!
//! ── WHAT IS ACTUALLY HAPPENING, WHICH IS TWO SIMULATIONS AT ONCE ──
//!
//! robot.zig owns the arm. It has no collision detector and never will: contacts arrive as
//! an INPUT, exactly the way controls do.
//!
//! zimrphysics owns the table and the crate, and also holds a KINEMATIC PROXY for each of
//! the arm's geoms — bodies it steers to wherever the arm's own kinematics put them. That
//! is what lets the crate see the arm at all: a body outside the broad phase does not exist
//! as far as the world's solver is concerned.
//!
//! Each step: steer the proxies, step the world, harvest the contacts its listener recorded,
//! hand them to the arm as `robot.Contact` values, step the arm.
//!
//! ── THE APPROXIMATION, IN PLAIN SIGHT ──
//!
//! The two solvers do not negotiate. zimrphysics resolves crate-against-arm treating the arm
//! as immovable; robot.zig resolves the same contact treating the crate as immovable. Both
//! feel it, neither knows the other's answer. That is right when the arm is much heavier
//! than what it touches — a real arm bolted to a bench — and it is why the crate here is
//! light. §4h of the plan works through what it costs and what the fix would be; the short
//! version is that the load the arm feels depends on the ratio of two contact stiffnesses,
//! which is a coupling with no physical meaning.
//!
//! Everything is locked to the XY plane so the whole thing can be drawn honestly in 2D.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;

const z = @import("zimr");
const zm = @import("zm");
const zp = z.zimrphysics;
const rbt = z.robot;
const bridge_mod = z.robot_physics;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const vec = zm.vec;
const vec2 = zm.vec2;
const rotate = zm.rotate;
const float = zm.float;
const pi = zm.pi;
const splat = zm.splat;
const vec_zero = zm.vec_zero;
const quat_identity = zm.quat_identity;
const assertUnreachable = zm.assertUnreachable;
const clamp = zm.clamp;
const acosRad = zm.acosRad;
const atan2Rad = zm.atan2Rad;

const timestep: f32 = 1.0 / 240.0;
const upper_half: f32 = 0.26;
const lower_half: f32 = 0.22;
const table_top: f32 = -0.30;
const crate_half: f32 = 0.055;

const Arm = rbt.Spec(.{
    .bodies = &.{
        .{
            .name = "upper",
            .joints = &.{.{
                .name = "shoulder",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0.004,
                .damping = 0.08,
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = upper_half, .radius = 0.04 } },
                .pos = vec(0, -upper_half, 0),
            }},
        },
        .{
            .name = "lower",
            .parent = "upper",
            .pos = vec(0, -2.0 * upper_half, 0),
            .joints = &.{.{
                .name = "elbow",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0.004,
                .damping = 0.08,
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = lower_half, .radius = 0.035 } },
                .pos = vec(0, -lower_half, 0),
            }},
        },
    },
    .actuators = &.{
        .{
            .name = "shoulder_servo",
            .on = .{ .joint = .{ .name = "shoulder" } },
            .kind = .{ .position = .{ .kp = 60, .kv = 6 } },
            .ctrl_range = .{ -pi, pi },
        },
        .{
            .name = "elbow_servo",
            .on = .{ .joint = .{ .name = "elbow" } },
            .kind = .{ .position = .{ .kp = 30, .kv = 3 } },
            .ctrl_range = .{ -pi, pi },
        },
    },
    .options = .{ .timestep = timestep, .max_contacts = 24 },
});

const bg: Color = .{ .r = 31, .g = 20, .b = 14, .a = 255 };
const panel: Color = .{ .r = 51, .g = 34, .b = 24, .a = 255 };
const arm_col: Color = .{ .r = 79, .g = 179, .b = 165, .a = 255 };
const crate_col: Color = .{ .r = 211, .g = 95, .b = 51, .a = 255 };
const table_col: Color = .{ .r = 120, .g = 92, .b = 70, .a = 255 };
const text_col: Color = .{ .r = 240, .g = 230, .b = 210, .a = 255 };
const dim_col: Color = .{ .r = 168, .g = 150, .b = 132, .a = 255 };
const hit_col: Color = .{ .r = 232, .g = 196, .b = 92, .a = 255 };

/// Scale text and chrome with the viewport — a standalone renders at device resolution, so
/// fixed pixel sizes are unreadable on a phone. See the note in `robot_sidebyside`.
fn uiScale(w: f32, h: f32) f32 {
    return @max(1.0, @min(w, h) / 450.0);
}

/// Closed-form inverse kinematics for this two-link planar arm.
///
/// ★ WHY THIS EXISTS, and it is the fix for a scene that did not work. The first version
/// picked the sweep's joint angles BY GUESSING — interpolate the shoulder from 1.9 to 0.4,
/// the elbow from −1.2 to −0.7, and hope the hand goes somewhere useful. It did not: the
/// arm straightened, drove its own tip into the table, and spent the whole sweep fighting a
/// contact it should never have made. It never reached the crate at all.
///
/// The lesson generalises past this demo. **Joint angles are the wrong space to author a
/// motion in.** What the task is about is where the HAND goes; the angles are whatever
/// achieves that, and a human cannot reliably guess them for even two links. So the path is
/// specified in Cartesian coordinates — sweep the tip along a horizontal line at crate
/// height — and the angles are solved for.
///
/// That is also what a real robot does: a planner works in task space, inverse kinematics
/// turns the path into joint targets, and the servos chase those. Doing it that way here
/// keeps the scene a demonstration of position servos rather than becoming an animation.
///
/// ── THE GEOMETRY ──
/// At `q = 0` a link points along −Y, so rotating by `q` about +Z gives the direction
/// `(sin q, −cos q)` — which is the unit vector at angle `q − π/2` in the usual convention.
/// Writing `a₁ = q₁ − π/2`, the standard two-link solution applies unchanged:
///
///     cos q₂ = (r² − L₁² − L₂²) / (2 L₁ L₂)
///     a₁     = atan2(y, x) − atan2(L₂ sin q₂, L₁ + L₂ cos q₂)
///
/// and `q₁ = a₁ + π/2`. Two solutions exist — elbow up and elbow down — and the sign of
/// `q₂` picks between them; this scene wants elbow-up so the arm reaches over the crate
/// rather than under the table.
const Ik = struct {
    const l1: f32 = 2.0 * upper_half;
    const l2: f32 = 2.0 * lower_half;

    /// Joint angles that put the tip at `target`, or null if it is out of reach.
    fn solve(target: Vec2) ?[2]f32 {
        const x: f32 = target[0];
        const y: f32 = target[1];
        const r_squared: f32 = x * x + y * y;
        const r: f32 = @sqrt(r_squared);
        // Unreachable if beyond the arm's span or inside the hole it cannot fold into.
        if (r > l1 + l2 - 1.0e-3 or r < @abs(l1 - l2) + 1.0e-3) {
            return null;
        }
        const cos_q2: f32 = clamp((r_squared - l1 * l1 - l2 * l2) / (2.0 * l1 * l2), -1.0, 1.0);
        // Negative: elbow up, so the arm arches over the crate.
        const q2: f32 = -acosRad(cos_q2);
        const a1: f32 = atan2Rad(y, x) - atan2Rad(l2 * @sin(q2), l1 + l2 * @cos(q2));
        return .{ a1 + pi * 0.5, q2 };
    }
};

const State = struct {
    gpa: Allocator,
    font: z.Font,
    model: rbt.Model,
    data: rbt.Data,
    world: zp.World,
    bridge: bridge_mod.Bridge,
    crate: zp.BodyHandle,
    accumulator: f32,
    elapsed: f32,
    /// Peak contact force the arm has felt, so a brief tap leaves a trace.
    peak_force: f32,
    sweeping: bool,
    /// Where the tip is being commanded to, drawn so the servos' lag is visible.
    target: Vec2,

    fn placeCrate(self: *State) !void {
        try self.world.setTransform(
            self.gpa,
            self.crate.index(),
            vec(0.33, table_top + crate_half, 0),
            quat_identity,
        );
        try self.world.setLinearVelocity(self.gpa, self.crate, vec_zero);
        try self.world.setAngularVelocity(self.gpa, self.crate, vec_zero);
    }
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .model = try Arm.build(gpa),
        .data = undefined,
        .world = try .init(gpa, 32),
        .bridge = undefined,
        .crate = undefined,
        .accumulator = 0,
        .elapsed = 0,
        .peak_force = 0,
        .sweeping = false,
        .target = vec2(0.62, table_top + crate_half),
    };
    s.data = try rbt.Data.init(gpa, &s.model);
    s.world.gravity = vec(0, -9.81, 0);

    // The table. STATIC, which is what a table is — and which only works because a robot
    // proxy opts into `report_immovable_contacts`. Without that flag zimrphysics drops any
    // pair where neither body can respond, so the arm would pass straight through.
    const table_shape: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(0.6, 0.03, 0.3), .convex_radius = 0.005 },
    });
    _ = try s.world.createBody(.{
        .shape = table_shape,
        .position = vec(0.25, table_top - 0.03, 0),
        .motion_type = .static,
    });

    // The crate. Light, deliberately: the one-way coupling is right when the arm is much
    // heavier than what it pushes, and wrong when it is not.
    const crate_shape: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .box = .{ .half_extent = splat(crate_half), .convex_radius = 0.004 },
    });
    s.crate = try s.world.createBody(.{
        .shape = crate_shape,
        .position = vec(0.33, table_top + crate_half, 0),
        .motion_type = .dynamic,
        .density = 300,
        // Locked to the XY plane so the scene can be drawn in 2D without lying about it.
        .allowed_dofs = zp.AllowedDofs.plane_2d,
    });

    // Start exactly where the sweep begins, so the first frame is not a lunge.
    const start: [2]f32 = Ik.solve(vec2(0.62, table_top + crate_half)) orelse .{ 1.9, -1.2 };
    s.data.setJointPos(&s.model, Arm.Joint.shoulder, start[0]);
    s.data.setJointPos(&s.model, Arm.Joint.elbow, start[1]);
    rbt.forward(&s.model, &s.data);

    // The bridge must be created AFTER the arm's kinematics have run once, or the proxies
    // are all born at the origin and the first step sees a huge spurious sweep.
    s.bridge = try .init(gpa, &s.world, &s.model, &s.data, 32);
    s.bridge.listen(&s.world);
}

fn deinit(gpa: Allocator, s: *State) void {
    s.bridge.deinit(&s.world);
    s.world.deinit(gpa);
    s.data.deinit();
    s.model.deinit();
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const w: f32 = float(f.window.screen_width);
    const h: f32 = float(f.window.screen_height);
    const ui: f32 = uiScale(w, h);

    // ---- the sweep, as a commanded pose rather than a torque ----
    // Two position servos and a target that moves: the arm decides its own torques, which
    // is what makes it a robot rather than an animation.
    // The tip travels a horizontal line at the crate's mid-height, right to left, passing
    // straight through where the crate is sitting. Above the table by enough that the arm
    // never touches it — the only thing it should hit is the crate.
    const sweep_y: f32 = table_top + crate_half;
    const sweep_from: f32 = 0.62;
    const sweep_to: f32 = 0.10;
    const progress: f32 = if (s.sweeping) @min(s.elapsed / 2.5, 1.0) else 0.0;
    const target: Vec2 = vec2(sweep_from + (sweep_to - sweep_from) * progress, sweep_y);
    s.target = target;
    if (Ik.solve(target)) |angles| {
        s.data.ctrl[0] = angles[0];
        s.data.ctrl[1] = angles[1];
    }

    s.accumulator += @min(f.time.delta_time, 0.1);
    while (s.accumulator >= timestep) : (s.accumulator -= timestep) {
        // ★ The seam, in four lines and a fixed order.
        s.bridge.sync(&s.world, &s.model, &s.data) catch |err| {
            assertUnreachable(@src(), "proxy sync failed: {t}", .{err});
        };
        zp.step(&s.world, timestep) catch |err| {
            assertUnreachable(@src(), "world step failed: {t}", .{err});
        };
        s.bridge.harvest(&s.data);
        rbt.step(&s.model, &s.data);
        if (s.sweeping) {
            s.elapsed += timestep;
        }
    }
    rbt.forward(&s.model, &s.data);

    var total_force: f32 = 0;
    for (0..s.data.constraint_count) |row| {
        total_force += s.data.constraint_force[row];
    }
    s.peak_force = @max(s.peak_force, total_force);

    // ---- draw ----
    z.clearViewport(f, bg);
    const scale: f32 = @min(w * 0.62, (h - 210 * ui) * 0.62) / 0.9;
    const origin: Vec2 = vec2(w * 0.34, h * 0.42);
    const toScreen = struct {
        fn go(o: Vec2, sc: f32, p: Vec2) Vec2 {
            return vec2(o[0] + p[0] * sc, o[1] - p[1] * sc);
        }
    }.go;

    // Table.
    gl.line(
        toScreen(origin, scale, vec2(-0.35, table_top)),
        toScreen(origin, scale, vec2(0.85, table_top)),
        .{ .color = table_col, .thickness = 5 * ui },
    );

    // Crate, drawn from its actual pose so a tumble reads as a tumble.
    {
        const body: *const zp.Body = &s.world.bodies.data[s.crate.index()];
        const corners = [_]Vec{
            vec(-crate_half, -crate_half, 0), vec(crate_half, -crate_half, 0),
            vec(crate_half, crate_half, 0),   vec(-crate_half, crate_half, 0),
        };
        var previous: Vec = body.com_pos + rotate(body.rot, corners[3]);
        for (corners) |corner| {
            const p: Vec = body.com_pos + rotate(body.rot, corner);
            gl.line(
                toScreen(origin, scale, vec2(previous[0], previous[1])),
                toScreen(origin, scale, vec2(p[0], p[1])),
                .{ .color = crate_col, .thickness = 4 * ui },
            );
            previous = p;
        }
    }

    // Arm.
    {
        const elbow: Vec = s.data.body_xpos[2];
        const tip: Vec = elbow + rotate(s.data.body_xrot[2], vec(0, -2.0 * lower_half, 0));
        gl.line(
            toScreen(origin, scale, vec2(0, 0)),
            toScreen(origin, scale, vec2(elbow[0], elbow[1])),
            .{ .color = arm_col, .thickness = 10 * ui },
        );
        gl.line(
            toScreen(origin, scale, vec2(elbow[0], elbow[1])),
            toScreen(origin, scale, vec2(tip[0], tip[1])),
            .{ .color = arm_col, .thickness = 8 * ui },
        );
        gl.circle(toScreen(origin, scale, vec2(0, 0)), 7 * ui, .{ .color = dim_col });
        gl.circle(toScreen(origin, scale, vec2(tip[0], tip[1])), 6 * ui, .{ .color = arm_col });
    }

    // Where the tip is COMMANDED to be. The gap between this and the actual tip is the
    // servo's tracking error — which grows exactly when the arm meets the crate, because a
    // finite-gain servo trades position for force.
    gl.circle(
        toScreen(origin, scale, s.target),
        7 * ui,
        .{ .color = dim_col, .outline = 2 * ui },
    );

    // Every contact the arm is currently feeling, at the point it acts.
    for (0..s.data.contact_count) |ci| {
        const c: rbt.Contact = s.data.contacts[ci];
        if (c.distance >= 0) {
            continue;
        }
        gl.circle(
            toScreen(origin, scale, vec2(c.position[0], c.position[1])),
            5 * ui,
            .{ .color = hit_col },
        );
    }

    // ---- readout ----
    gl.text(
        vec2(16 * ui, 30 * ui),
        "an arm that touches the world",
        .{ .size = 20 * ui, .color = text_col, .font = &s.font },
    );
    gl.text(
        vec2(16 * ui, 56 * ui),
        "robot.zig owns the arm - zimrphysics owns the table and crate",
        .{ .size = 12 * ui, .color = dim_col, .font = &s.font },
    );

    var buf: [160]u8 = undefined;
    const line: []const u8 = bufPrint(
        &buf,
        "contacts {d}  rows {d}  solver {d} it  force {d:.1} N  peak {d:.1} N",
        .{ s.data.contact_count, s.data.constraint_count, s.data.solver_iterations, total_force, s.peak_force },
    ) catch "";
    const col: Color = if (s.data.constraint_count > 0) hit_col else dim_col;
    gl.text(vec2(16 * ui, 80 * ui), line, .{ .size = 12 * ui, .color = col, .font = &s.font });

    // ---- controls ----
    const sweep_box: z.Rectangle = .{ .x = 16 * ui, .y = h - 54 * ui, .width = 150 * ui, .height = 42 * ui };
    const reset_box: z.Rectangle = .{ .x = 180 * ui, .y = h - 54 * ui, .width = 150 * ui, .height = 42 * ui };
    gl.rect(sweep_box, .{ .color = panel });
    gl.rect(reset_box, .{ .color = panel });
    gl.text(
        vec2(sweep_box.x + 16 * ui, sweep_box.y + 28 * ui),
        if (s.sweeping) "sweeping" else "sweep",
        .{ .size = 14 * ui, .color = if (s.sweeping) hit_col else text_col, .font = &s.font },
    );
    gl.text(
        vec2(reset_box.x + 16 * ui, reset_box.y + 28 * ui),
        "reset crate",
        .{ .size = 14 * ui, .color = text_col, .font = &s.font },
    );

    if (z.isMouseButtonPressed(f.input, .left)) {
        const p: Vec2 = z.getMousePosition(f.input);
        if (inside(p, sweep_box)) {
            s.sweeping = !s.sweeping;
            if (s.sweeping) {
                s.elapsed = 0;
            }
        } else if (inside(p, reset_box)) {
            s.placeCrate() catch |err| {
                assertUnreachable(@src(), "crate reset failed: {t}", .{err});
            };
            s.peak_force = 0;
            s.sweeping = false;
            s.elapsed = 0;
        }
    }
}

fn inside(p: Vec2, r: z.Rectangle) bool {
    return p[0] >= r.x and p[0] <= r.x + r.width and p[1] >= r.y and p[1] <= r.y + r.height;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - robot contact",
            .width = 760,
            .height = 620,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
