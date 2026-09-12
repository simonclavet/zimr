//! scenes.zig — the robot demo's scene table.
//!
//! Same shape as `examples/zimrphysics2d_demo/scenes.zig`: one table, one row per scene,
//! and the host knows nothing about any individual scene. Adding a scene is adding a row.
//!
//! Every scene is PLANAR — hinges about Z, so the machine swings in the screen plane and
//! the host can draw it in 2D with no camera. That is not a limitation of the engine (it
//! is fully 3D); it is what makes the demo readable on a phone.
//!
//! A scene owns a `robot.Model` and a `robot.Data`. It may install a `control` hook, which
//! runs once per frame BEFORE the physics — the same position in the pipeline a real
//! controller occupies, between "everything derived from state is known" and "no force has
//! been committed yet".

const std = @import("std");
const Allocator = std.mem.Allocator;

const zm = @import("zm");
const rbt = @import("zimr").robot;
const bufPrint = std.fmt.bufPrint;

const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const vec = zm.vec;
const pi = zm.pi;
const dot3 = zm.dot3;
const splat = zm.splat;

/// What a scene's control hook can see. Deliberately small: a target the user is dragging,
/// and the clock. A scene that needs more probably wants to be a different demo.
pub const Input = struct {
    /// Where the user is pointing, in world metres. Only meaningful while `pointing`.
    target: Vec2,
    pointing: bool,
    /// Seconds since this scene was (re)started.
    elapsed: f32,
};

/// A live scene: the model, its state, and scratch the control hook may use.
pub const Live = struct {
    model: rbt.Model,
    data: rbt.Data,
    /// Jacobian scratch, sized to the model. Allocated once so a control hook running at
    /// 240 Hz never touches an allocator.
    jac_p: []Vec,
    jac_r: []Vec,
    elapsed: f32,

    pub fn deinit(self: *Live, gpa: Allocator) void {
        gpa.free(self.jac_p);
        gpa.free(self.jac_r);
        self.data.deinit();
        self.model.deinit();
    }
};

pub const Scene = struct {
    category: []const u8,
    name: []const u8,
    /// One line under the title, explaining what to look at.
    blurb: []const u8,
    build: *const fn (gpa: Allocator) anyerror!Live,
    /// Optional per-frame hook, run before the physics.
    control: ?*const fn (live: *Live, in: Input) void = null,
    /// Which body/offset the tip marker and trail follow. Null draws no trail.
    tip: ?struct { body: u32, local: Vec } = null,
    /// Optional live readout, drawn under the blurb. Lets a scene surface the numbers it is
    /// actually about — an IMU's reading, a tendon's length — rather than leaving the
    /// interesting quantity invisible inside `Data`.
    readout: ?*const fn (live: *const Live, buf: []u8) []const u8 = null,
    /// Farthest the mechanism can reach from the origin, in metres. The host scales the
    /// view to fit it, so a three-link chain and a two-link arm both fill the screen
    /// instead of one being tiny and the other running off the bottom.
    reach: f32,
};

// ============================================================================
// Model builders. Each returns a fresh Live; the host owns exactly one at a time.
// ============================================================================

/// A chain of `n` identical links hanging along −Y, hinged about Z. Covers the whole
/// Basics category: one link is a pendulum, two is chaos, three is more chaos.
fn Chain(comptime n: usize, comptime armature: f32) type {
    return struct {
        const half: f32 = 0.22;
        const spec = blk: {
            var bodies: [n]rbt.BodySpec = undefined;
            for (&bodies, 0..) |*b, i| {
                b.* = .{
                    .name = std.fmt.comptimePrint("link{d}", .{i}),
                    .parent = if (i == 0) null else std.fmt.comptimePrint("link{d}", .{i - 1}),
                    .pos = if (i == 0) vec(0, 0, 0) else vec(0, -2.0 * half, 0),
                    .joints = &.{.{
                        .name = std.fmt.comptimePrint("j{d}", .{i}),
                        .kind = .hinge,
                        .axis = vec(0, 0, 1),
                        .armature = armature,
                    }},
                    .geoms = &.{.{
                        .shape = .{ .capsule = .{ .half_height = half, .radius = 0.035 } },
                        .pos = vec(0, -half, 0),
                    }},
                };
            }
            const frozen = bodies;
            break :blk rbt.ModelSpec{ .bodies = &frozen, .options = .{ .timestep = 1.0 / 240.0 } };
        };
        const Model = rbt.Spec(spec);

        fn build(gpa: Allocator) anyerror!Live {
            var live: Live = .{
                .model = try Model.build(gpa),
                .data = undefined,
                .jac_p = try gpa.alloc(Vec, Model.nv),
                .jac_r = try gpa.alloc(Vec, Model.nv),
                .elapsed = 0,
            };
            live.data = try rbt.Data.init(gpa, &live.model);
            // Start off vertical, or nothing interesting happens.
            live.data.pos[0] = 2.3;
            if (Model.nv > 1) {
                live.data.pos[1] = -1.5;
            }
            return live;
        }
    };
}

/// A two-link arm with a site at its tip.
///
/// TWO models, not one, and the difference matters: an arm with motors is a different
/// machine from an arm without. A position servo is ALWAYS acting — leave its control at
/// zero and it drives the joint to zero with all its gain, which silently overrules any
/// other controller you layer on top. So the Kinematics scenes get an unactuated arm and
/// drive it with joint forces, and the Actuators scenes get the servos.
fn ArmSpec(comptime actuated: bool) rbt.ModelSpec {
    const servos: []const rbt.ActuatorSpec = if (actuated) &.{
        .{
            .name = "shoulder_servo",
            .on = .{ .joint = .{ .name = "shoulder" } },
            .kind = .{ .position = .{ .kp = 24, .kv = 2.4 } },
            .ctrl_range = .{ -pi, pi },
        },
        .{
            .name = "elbow_servo",
            .on = .{ .joint = .{ .name = "elbow" } },
            .kind = .{ .position = .{ .kp = 14, .kv = 1.4 } },
            .ctrl_range = .{ -pi, pi },
        },
    } else &.{};

    return .{
        .bodies = &.{
            .{
                .name = "upper",
                .joints = &.{.{
                    .name = "shoulder",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .armature = 0.002,
                    .damping = 0.02,
                }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = Arm.upper, .radius = 0.045 } },
                    .pos = vec(0, -Arm.upper, 0),
                }},
            },
            .{
                .name = "lower",
                .parent = "upper",
                .pos = vec(0, -2.0 * Arm.upper, 0),
                .joints = &.{.{
                    .name = "elbow",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .armature = 0.002,
                    .damping = 0.02,
                }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = Arm.lower, .radius = 0.035 } },
                    .pos = vec(0, -Arm.lower, 0),
                }},
                .sites = &.{.{ .name = "tip", .pos = vec(0, -2.0 * Arm.lower, 0) }},
            },
        },
        .actuators = servos,
        .options = .{ .timestep = 1.0 / 240.0 },
    };
}

const Arm = struct {
    const upper: f32 = 0.26;
    const lower: f32 = 0.22;
    const reach: f32 = 2.0 * upper + 2.0 * lower;
    const tip_local: Vec = vec(0, -2.0 * lower, 0);
    const tip_body: u32 = 2;

    const Free = rbt.Spec(ArmSpec(false));
    const Servo = rbt.Spec(ArmSpec(true));

    fn make(comptime M: type, gpa: Allocator) anyerror!Live {
        var live: Live = .{
            .model = try M.build(gpa),
            .data = undefined,
            .jac_p = try gpa.alloc(Vec, M.nv),
            .jac_r = try gpa.alloc(Vec, M.nv),
            .elapsed = 0,
        };
        live.data = try rbt.Data.init(gpa, &live.model);
        live.data.pos[0] = 0.6;
        live.data.pos[1] = -1.0;
        return live;
    }

    fn buildFree(gpa: Allocator) anyerror!Live {
        return make(Free, gpa);
    }

    fn buildServo(gpa: Allocator) anyerror!Live {
        return make(Servo, gpa);
    }
};

/// A two-link arm whose joints have travel LIMITS, so the soft constraint solver is what
/// stops it rather than the geometry running out.
///
/// The ranges deliberately stop short of the arm's gravity equilibrium, so gravity presses
/// steadily into a limit instead of the arm settling somewhere the constraint never
/// engages. `soft` widens the impedance ramp and lengthens the time constant, which is
/// visible as the arm sinking further past its stop and easing into it rather than
/// catching — the same model, one parameter apart.
fn LimitedArm(comptime soft: bool) type {
    return struct {
        const softness: rbt.Softness = if (soft)
            .{ .time_const_s = 0.15, .damp_ratio = 1.0 }
        else
            .{ .time_const_s = 0.02, .damp_ratio = 1.0 };
        const impedance: rbt.Impedance = if (soft)
            .{ .min = 0.5, .max = 0.8, .width = 0.25, .midpoint = 0.5, .power = 2 }
        else
            .{};

        const Model = rbt.Spec(.{
            .bodies = &.{
                .{
                    .name = "upper",
                    .joints = &.{.{
                        .name = "shoulder",
                        .kind = .hinge,
                        .axis = vec(0, 0, 1),
                        .armature = 0.002,
                        .damping = 0.05,
                        .range = .{ 0.5, 2.3 },
                        .limit_softness = softness,
                        .limit_impedance = impedance,
                    }},
                    .geoms = &.{.{
                        .shape = .{ .capsule = .{ .half_height = Arm.upper, .radius = 0.045 } },
                        .pos = vec(0, -Arm.upper, 0),
                    }},
                },
                .{
                    .name = "lower",
                    .parent = "upper",
                    .pos = vec(0, -2.0 * Arm.upper, 0),
                    .joints = &.{.{
                        .name = "elbow",
                        .kind = .hinge,
                        .axis = vec(0, 0, 1),
                        .armature = 0.002,
                        .damping = 0.05,
                        .range = .{ -2.2, -0.4 },
                        .limit_softness = softness,
                        .limit_impedance = impedance,
                    }},
                    .geoms = &.{.{
                        .shape = .{ .capsule = .{ .half_height = Arm.lower, .radius = 0.035 } },
                        .pos = vec(0, -Arm.lower, 0),
                    }},
                    .sites = &.{.{ .name = "tip", .pos = vec(0, -2.0 * Arm.lower, 0) }},
                },
            },
            .options = .{ .timestep = 1.0 / 240.0 },
        });

        fn build(gpa: Allocator) anyerror!Live {
            var live: Live = .{
                .model = try Model.build(gpa),
                .data = undefined,
                .jac_p = try gpa.alloc(Vec, Model.nv),
                .jac_r = try gpa.alloc(Vec, Model.nv),
                .elapsed = 0,
            };
            live.data = try rbt.Data.init(gpa, &live.model);
            live.data.pos[0] = 2.0;
            live.data.pos[1] = -1.6;
            return live;
        }
    };
}

const LimitStiff = LimitedArm(false);
const LimitSoft = LimitedArm(true);

/// A pendulum wearing an inertial measurement unit at its tip.
///
/// The instrument is the point of the scene. An accelerometer does not measure coordinate
/// acceleration — it measures PROPER acceleration, the force per unit mass its case applies
/// to the proof mass. So one at rest reads 9.81 upward and one in free fall reads zero,
/// which is exactly backwards from the intuition most people start with.
const Imu = struct {
    const half: f32 = 0.3;
    const Model = rbt.Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0.002,
                .damping = 0.01,
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = half, .radius = 0.04 } },
                .pos = vec(0, -half, 0),
            }},
            .sites = &.{.{ .name = "imu", .pos = vec(0, -2.0 * half, 0) }},
        }},
        .sensors = &.{
            .{ .name = "acc", .kind = .accelerometer, .target = "imu" },
            .{ .name = "gyro", .kind = .gyro, .target = "imu" },
            .{ .name = "vel", .kind = .velocimeter, .target = "imu" },
        },
        .options = .{ .timestep = 1.0 / 240.0 },
    });

    const tip_local: Vec = vec(0, -2.0 * half, 0);
    const reach: f32 = 2.0 * half;

    fn build(gpa: Allocator) anyerror!Live {
        var live: Live = .{
            .model = try Model.build(gpa),
            .data = undefined,
            .jac_p = try gpa.alloc(Vec, Model.nv),
            .jac_r = try gpa.alloc(Vec, Model.nv),
            .elapsed = 0,
        };
        live.data = try rbt.Data.init(gpa, &live.model);
        live.data.pos[0] = 2.4; // well up, so it swings hard through the bottom
        return live;
    }

    /// The instrument's own reading, in its own frame — which is what makes it an
    /// instrument rather than a derived quantity.
    fn readout(live: *const Live, buf: []u8) []const u8 {
        const sensor: []const f32 = live.data.sensor_data;
        const magnitude: f32 = @sqrt(sensor[0] * sensor[0] + sensor[1] * sensor[1] + sensor[2] * sensor[2]);
        return bufPrint(
            buf,
            "accel |a| {d:.2} m/s2   gyro {d:.2} rad/s   speed {d:.2} m/s",
            .{ magnitude, sensor[5], @abs(sensor[7]) },
        ) catch "";
    }
};

// ============================================================================
// Control hooks.
// ============================================================================

/// Free fall: nothing to control. Present so the table reads uniformly.
fn noControl(_: *Live, _: Input) void {}

/// No controller, but dragging pushes the tip — so you can drive the arm into its limits
/// and feel the constraint push back rather than watching it settle.
fn dragOnly(live: *Live, in: Input) void {
    if (!in.pointing) {
        return;
    }
    const m: *const rbt.Model = &live.model;
    const d: *rbt.Data = &live.data;
    const tip: Vec = d.site_xpos[0];
    const pull: Vec = (vec(in.target[0], in.target[1], 0) - tip) * splat(25.0);
    rbt.applyForceAtPoint(m, d, Arm.tip_body, tip, pull, vec(0, 0, 0), live.jac_p, live.jac_r, d.applied_force);
}

/// Cancel gravity exactly. `bias_force` IS the force needed to hold still, so applying it
/// leaves the arm weightless — it stays wherever you leave it, in any pose.
///
/// This is the cheapest genuinely useful thing an engine like this does, and it needs no
/// tuning, no gains and no target: it is inverse dynamics evaluated at zero acceleration.
fn gravityCompensation(live: *Live, in: Input) void {
    const m: *const rbt.Model = &live.model;
    const d: *rbt.Data = &live.data;
    @memcpy(d.applied_force, d.bias_force);
    if (!in.pointing) {
        return;
    }
    // Drag applies a real force AT THE TIP, mapped into joint torques by the Jacobian
    // transpose. With gravity cancelled and almost no damping the arm keeps whatever motion
    // you give it, which is what "weightless" should look and feel like.
    const tip: Vec = d.site_xpos[0];
    const pull: Vec = (vec(in.target[0], in.target[1], 0) - tip) * splat(12.0);
    rbt.applyForceAtPoint(m, d, Arm.tip_body, tip, pull, vec(0, 0, 0), live.jac_p, live.jac_r, d.applied_force);
}

/// Jacobian-transpose reach: pull the tip toward the target.
///
/// The whole algorithm is `τ = Jᵀ·(target − tip)`. It works because the transpose converts
/// a task-space pull into the joint torques that produce it — no matrix inverse, no
/// iteration, and it degrades gracefully at singularities instead of blowing up the way an
/// inverse-Jacobian method does.
fn reachToTarget(live: *Live, in: Input) void {
    const m: *const rbt.Model = &live.model;
    const d: *rbt.Data = &live.data;
    // Gravity compensation first, so the arm is weightless and the reach is the only force
    // acting. Without it you would be watching a tug-of-war rather than a controller.
    @memcpy(d.applied_force, d.bias_force);
    if (!in.pointing) {
        return;
    }

    const tip: Vec = d.site_xpos[0];
    const target: Vec = vec(in.target[0], in.target[1], 0);
    const err: Vec = target - tip;
    const gain: f32 = 40.0;

    rbt.jacSite(m, d, @as(u32, 0), live.jac_p, null);
    for (0..m.nv) |i| {
        d.applied_force[i] += gain * dot3(live.jac_p[i], err);
        // A little joint damping, or the arm rings: the transpose controller has no notion
        // of velocity and will happily oscillate forever around its target.
        d.applied_force[i] -= 1.2 * d.vel[i];
    }
}

/// Drive both servos with a slow sweep, so the position actuators are visibly commanded
/// rather than merely holding.
fn servoSweep(live: *Live, in: Input) void {
    const s: f32 = @sin(in.elapsed * 0.9);
    const c: f32 = @cos(in.elapsed * 0.6);
    live.data.ctrl[0] = 0.9 * s;
    live.data.ctrl[1] = -1.1 * c;
}

/// Hold a fixed pose against gravity using ONLY the servos — no gravity compensation. The
/// steady-state droop is the point: a finite-gain servo settles where its restoring torque
/// balances the load, and that error is a real property of proportional control.
fn servoHold(live: *Live, _: Input) void {
    live.data.ctrl[0] = 1.2;
    live.data.ctrl[1] = -0.8;
}

// ============================================================================
// The table.
// ============================================================================

const Pendulum1 = Chain(1, 0.0);
const Pendulum2 = Chain(2, 0.0);
const Pendulum3 = Chain(3, 0.0);

pub const all = [_]Scene{
    .{
        .category = "Basics",
        .name = "single pendulum",
        .blurb = "one number describes this machine",
        .build = Pendulum1.build,
        .tip = .{ .body = 1, .local = vec(0, -2.0 * Pendulum1.half, 0) },
        .reach = 2.0 * Pendulum1.half,
    },
    .{
        .category = "Basics",
        .name = "double pendulum",
        .blurb = "two numbers - and chaos",
        .build = Pendulum2.build,
        .tip = .{ .body = 2, .local = vec(0, -2.0 * Pendulum2.half, 0) },
        .reach = 4.0 * Pendulum2.half,
    },
    .{
        .category = "Basics",
        .name = "triple pendulum",
        .blurb = "deeper chains exercise the sparsity",
        .build = Pendulum3.build,
        .tip = .{ .body = 3, .local = vec(0, -2.0 * Pendulum3.half, 0) },
        .reach = 6.0 * Pendulum3.half,
    },
    .{
        .category = "Kinematics",
        .name = "weightless arm",
        .blurb = "gravity cancelled - drag to bat it around, it keeps going",
        .build = Arm.buildFree,
        .control = gravityCompensation,
        .tip = .{ .body = Arm.tip_body, .local = Arm.tip_local },
        .reach = Arm.reach,
    },
    .{
        .category = "Kinematics",
        .name = "reach to target",
        .blurb = "drag: the tip follows via the Jacobian transpose",
        .build = Arm.buildFree,
        .control = reachToTarget,
        .tip = .{ .body = Arm.tip_body, .local = Arm.tip_local },
        .reach = Arm.reach,
    },
    .{
        .category = "Actuators",
        .name = "position servos, swept",
        .blurb = "two PD servos tracking a moving command",
        .build = Arm.buildServo,
        .control = servoSweep,
        .tip = .{ .body = Arm.tip_body, .local = Arm.tip_local },
        .reach = Arm.reach,
    },
    .{
        .category = "Actuators",
        .name = "servo droop",
        .blurb = "no gravity compensation - it settles below its target, on purpose",
        .build = Arm.buildServo,
        .control = servoHold,
        .tip = .{ .body = Arm.tip_body, .local = Arm.tip_local },
        .reach = Arm.reach,
    },
    .{
        .category = "Limits",
        .name = "joint limits",
        .blurb = "drag: the stops are soft constraints, not geometry",
        .build = LimitStiff.build,
        .control = dragOnly,
        .tip = .{ .body = Arm.tip_body, .local = Arm.tip_local },
        .reach = Arm.reach,
    },
    .{
        .category = "Limits",
        .name = "soft limits",
        .blurb = "same arm, wider impedance ramp - it eases in instead of catching",
        .build = LimitSoft.build,
        .control = dragOnly,
        .tip = .{ .body = Arm.tip_body, .local = Arm.tip_local },
        .reach = Arm.reach,
    },
    .{
        .category = "Sensors",
        .name = "IMU readout",
        .blurb = "an accelerometer reads 9.81 at rest and ~0 in free fall - watch it swing",
        .build = Imu.build,
        .control = noControl,
        .readout = Imu.readout,
        .tip = .{ .body = 1, .local = Imu.tip_local },
        .reach = Imu.reach,
    },
    .{
        .category = "Actuators",
        .name = "free fall",
        .blurb = "no motors at all - the same arm, uncontrolled",
        .build = Arm.buildFree,
        .control = noControl,
        .tip = .{ .body = Arm.tip_body, .local = Arm.tip_local },
        .reach = Arm.reach,
    },
};
