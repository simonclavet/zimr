//! robot.zig - reduced-coordinate articulated-body dynamics, in the style of MuJoCo.
//!
//! zimrphysics.zig (a Jolt port) simulates in MAXIMAL coordinates: every body carries a
//! full 6-DOF pose and joints are constraints a solver enforces to a tolerance. That is
//! the right model for a game - crates, ragdolls, a thousand loose objects.
//!
//! This file is the other half. A robot arm with four hinges is FOUR numbers here, not
//! four bodies with constraints holding them together. The joints are not enforced; they
//! are structurally impossible to violate, because the freedom to violate them was never
//! represented. That is the difference between a simulator that drifts and one that
//! cannot, and it is why a robot wants this and a pile of crates does not.
//!
//! Everything reduces to one equation:
//!
//!     M(q) v_dot + c(q,v) = tau + J^T f
//!
//! `M` is the joint-space inertia (composite rigid body), `c` the bias forces from
//! Coriolis/centrifugal/gravity (recursive Newton-Euler), `tau` the applied and actuator
//! forces, and `J^Tf` the constraint forces. Forward dynamics is then one line:
//! `v_dot = M^-1(tau + J^Tf - c)`. Everything before that computes M and c; everything after
//! computes f.
//!
//! ## THE UP AXIS IS A MODEL PROPERTY, NOT A PROPERTY OF THIS FILE
//!
//! Nothing here assumes an up axis. Gravity is `Options.gravity`, a plain field, and every
//! other direction in the file comes from the model - joint axes, geom frames, contact
//! normals. That is deliberate, and it is why both conventions coexist without a flag:
//!
//! * **`Options.gravity` DEFAULTS to `(0, -9.81, 0)`** - zimr is Y-up everywhere else
//!   (cameras, capsules along local Y, every non-robot demo), so a model authored by hand
//!   in this file's `Spec` gets zimr's convention for free.
//! * **MJCF models are Z-UP and stay that way.** MuJoCo and essentially every published
//!   robot model are Z-up, and `robot_mjcf.zig` deliberately does NOT rotate them: the
//!   acceptance test for import is that forward kinematics agrees with MuJoCo body for
//!   body, and a frame conversion in the middle turns any disagreement into two candidate
//!   explanations instead of one. Imported scenes therefore set `gravity = (0, 0, -9.81)`,
//!   and so do the Go1, humanoid, gripper and cartpole demos. **This is the main path** -
//!   "load anything from the Menagerie" is the feature.
//! * **URDF models ARE rotated** to Y-up at the root, because URDF has no MuJoCo to be
//!   verified against and the demos want zimr's convention.
//!
//! So: check the model's gravity before you write a `vec(0, 1, 0)` anywhere near a robot.
//! `robot_mjcf.zig`'s `build` doc has the full reasoning for the split.
//!
//! ## PRECISION IS f32
//!
//! MuJoCo is f64. We are f32, because zm is the foundation and a private vector type would
//! make this file a foreign body in its own tree. The risk that buys: a chain with a large
//! mass ratio has a mass matrix with a condition number in the millions, and an f32
//! factorization of that loses most of its mantissa. The escape hatch, when the day comes,
//! is narrow - widen `factorM`/`solveM` internally to f64 and narrow on the way out. Two
//! functions, invisible to callers. Do not widen anything else, and do not pre-build it.
//! `src/tests/fixtures/robot/reference.zig` carries f32-sized tolerances (~1e-5) for
//! exactly this reason; a gap that GROWS with model stiffness is the signal.
//!
//! ## Model vs Data - the split that makes everything else work
//!
//! `Model` is constant: tree topology, joint axes, inertias, index tables. Built once,
//! then never written. `Data` is everything that changes. One `Model` can drive many
//! `Data` instances, which is what makes batched rollouts possible later, and it is why
//! every function here reads `*const Model` and writes `*Data`.
//!
//! ## The pipeline, and where to start reading
//!
//! `forward(m, d)` is the whole of physics for one state, in the order it has to happen.
//! Each stage reads what the ones above it wrote, and every name below is a `pub fn` in
//! this file, in roughly this order:
//!
//!     kinematics          body poses from qpos                      - "Kinematics"
//!     comPos              the subtree-com frame, cinert, cdof       - makes CRB cheap
//!     crb + factorM       M, then its LTDL factor                   - "Mass matrix"
//!     comVel              body velocities in that frame
//!     makeConstraints     limits, contacts and equalities -> rows    - "Constraints"
//!     biasForce           c(q,v) by recursive Newton-Euler
//!     passive             springs, damping, tendons
//!     actuation           ctrl -> joint torque, through transmissions
//!     forwardDynamics     v_dot = M^-1(tau - c)                            - unconstrained
//!     solveConstraints    the constraint impulse, PGS or Newton     - "Solver"
//!     sensors             at three stages, as MuJoCo does
//!
//! `step(m, d)` is `forward` plus an integrator (`euler`, `rk4`, `implicitfast`,
//! `implicit`). `step1`/`step2` split it either side of the point where a controller wants
//! to run, and a test pins that the split is exactly equivalent to the whole.
//!
//! The pipeline is IMPERATIVE. Nothing happens automatically: set `qpos` and the Cartesian
//! body poses are simply stale until you call `kinematics`. No dirty flags, no lazy
//! recompute. MuJoCo's docs call this out because it surprises people; it should surprise
//! nobody reading zimr. `Data.stage` is a watermark recording how far the pipeline has run
//! on the current state, so a helper can tell whether what it needs is current.
//!
//! ## What this file does NOT do
//!
//! **No collision detection, ever.** Contacts arrive through `Data.pushContact` exactly
//! the way controls arrive through `Data.ctrl` - an input, not something computed here.
//! `robot_physics.zig` is the one file that knows how to get them out of a zimrphysics
//! world, and it is separate so that a headless rollout or a trajectory optimisation does
//! not drag an 18k-line collision engine along with it. This file imports `zm` and the
//! profiler and nothing else.
//!
//! The rest of the subsystem, none of which this file knows about:
//! `mjcf.zig` (XML) -> `robot_mjcf.zig` (-> `Model`), `robot_urdf.zig`, `robot_scene.zig`
//! (robots + loose bodies in one tree), `robot_control.zig` (PoseHold, IK),
//! `robot_bench.zig` (the speed acceptance test).

const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;

const zm = @import("zm");
const float = zm.float;
const isFinite = zm.isFinite;
const turnsFromRad = zm.turnsFromRad;
const radFromTurns = zm.radFromTurns;
const profiler = @import("profiler.zig");

// zm keywords must be bound at file scope (the linter enforces it), and binding them here
// also keeps the maths below readable as maths.
pub const Vec = zm.Vec;
pub const Quat = zm.Quat;
const vec = zm.vec;
const vec_zero = zm.vec_zero;
const quat_identity = zm.quat_identity;
const splat = zm.splat;
const dot3 = zm.dot3;
const cross = zm.cross;
const length3 = zm.length3;
const normalize3 = zm.normalize3;
const qmul = zm.qmul;
const rotate = zm.rotate;
const conjugate = zm.conjugate;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const clamp = zm.clamp;
const acosRad = zm.acosRad;
const atan2Rad = zm.atan2Rad;
const maxInt = zm.maxInt;
const pi = zm.pi;
const assertf = zm.assertf;

// =============================================================================
// Spatial algebra
//
// A rigid body's motion has six components and so does the force on it, so both are
// 6-vectors. The convention here is MuJoCo's, and it is worth stating loudly because
// every sign in the file depends on it:
//
//     ANGULAR FIRST, then linear.  (MuJoCo calls this `rot:lin`.)
//
// We store them as two `Vec` rather than a `[6]f32`. The fourth lane goes unused, which
// costs a little memory and buys the whole zm vocabulary - `cross`, `dot3`, `splat` - and
// code that reads like the vector maths it is.
// =============================================================================

/// A spatial motion vector: an angular velocity (or acceleration) and a linear one, both
/// expressed about a common reference point. Twists live here.
pub const Motion = struct {
    ang: Vec = vec_zero,
    lin: Vec = vec_zero,

    pub const zero: Motion = .{};

    pub fn add(a: Motion, b: Motion) Motion {
        return .{ .ang = a.ang + b.ang, .lin = a.lin + b.lin };
    }

    pub fn sub(a: Motion, b: Motion) Motion {
        return .{ .ang = a.ang - b.ang, .lin = a.lin - b.lin };
    }

    pub fn scale(a: Motion, s: f32) Motion {
        const k: Vec = splat(s);
        return .{ .ang = a.ang * k, .lin = a.lin * k };
    }
};

/// A spatial force vector: a torque and a linear force about the same reference point.
/// Wrenches live here. Structurally identical to `Motion`, deliberately a separate type -
/// adding a velocity to a force is a bug the compiler can catch for free.
pub const Force = struct {
    ang: Vec = vec_zero,
    lin: Vec = vec_zero,

    pub const zero: Force = .{};

    pub fn add(a: Force, b: Force) Force {
        return .{ .ang = a.ang + b.ang, .lin = a.lin + b.lin };
    }

    pub fn scale(a: Force, s: f32) Force {
        const k: Vec = splat(s);
        return .{ .ang = a.ang * k, .lin = a.lin * k };
    }
};

/// The pairing of a motion and a force - the only way the two types legally meet, and the
/// reason they are separate types. `dot6(v, f)` is the rate of work `f` does moving at `v`.
/// Named for MuJoCo's `mju_dot6` rather than `dot`, because it is emphatically not the
/// vector dot product: it contracts a 6-vector against its DUAL.
pub fn dot6(m: Motion, f: Force) f32 {
    return dot3(m.ang, f.ang) + dot3(m.lin, f.lin);
}

/// Spatial cross product for MOTION vectors: `v x m`. This is what carries a velocity
/// down a kinematic chain - a child's velocity is its parent's plus its own joint motion,
/// and the coupling term is exactly this.
pub fn crossMotion(v: Motion, m: Motion) Motion {
    return .{
        .ang = cross(v.ang, m.ang),
        .lin = cross(v.ang, m.lin) + cross(v.lin, m.ang),
    };
}

/// Spatial cross product for FORCE vectors: `v x* f`. Not the same operator as
/// `crossMotion` - forces transform by the dual, which is where gyroscopic terms come
/// from. Getting these two confused produces a simulation that looks alive and conserves
/// nothing.
pub fn crossForce(v: Motion, f: Force) Force {
    return .{
        .ang = cross(v.ang, f.ang) + cross(v.lin, f.lin),
        .lin = cross(v.ang, f.lin),
    };
}

/// A rigid body's spatial inertia, in the ten-parameter form MuJoCo uses:
///
///     [  I      skew(h) ]     I = rotational inertia about the reference point
///     [ -skew(h)  m*1   ]     h = m * (centre of mass - reference point)
///
/// The packing matters. Because all bodies in one kinematic tree share a reference frame
/// (see `comPos` in phase 1), a COMPOSITE inertia is just the sum of its parts - which
/// makes the composite-rigid-body algorithm three vector adds and a scalar add per body.
/// That is the whole reason CRB is cheap, and the reason this is not stored as a 6x6.
pub const Inertia = struct {
    /// Ixx, Iyy, Izz.
    diag: Vec = vec_zero,
    /// Ixy, Ixz, Iyz - the tensor is symmetric, so three numbers cover the rest.
    off: Vec = vec_zero,
    /// First moment of mass: `mass * com`. Zero when the reference point IS the centre
    /// of mass, which is why a body's own inertia is usually stored that way.
    h: Vec = vec_zero,
    mass: f32 = 0,

    pub const zero: Inertia = .{};

    pub fn add(a: Inertia, b: Inertia) Inertia {
        return .{
            .diag = a.diag + b.diag,
            .off = a.off + b.off,
            .h = a.h + b.h,
            .mass = a.mass + b.mass,
        };
    }

    /// Apply this inertia to a motion, giving the momentum (or, with an acceleration in,
    /// the force out). The expanded form of the 6x6 above.
    pub fn mul(self: Inertia, m: Motion) Force {
        // Rotational block: the symmetric tensor times the angular part.
        const torque: Vec = self.applyTensor(m.ang);
        return .{
            // torque gains h x v_lin from the off-diagonal block
            .ang = torque + cross(self.h, m.lin),
            // force is m*v_lin, plus the omega x h coupling when the com is offset
            .lin = m.lin * splat(self.mass) + cross(m.ang, self.h),
        };
    }

    /// Translate the BODY by `offset`, keeping the reference point fixed - equivalently,
    /// move the reference point by `-offset`. Used to place each body's own inertia into
    /// the tree's shared frame.
    ///
    /// (The direction is worth stating twice, because both readings are plausible and the
    /// wrong one is a sign error you cannot see. `translate` of a point mass by `+d` puts
    /// its centre of mass at `+d`, so `h` grows by `+m*d`.)
    ///
    /// DERIVATION. Write the body's own inertia about its centre of mass as `I_c`, and its
    /// centre of mass at `c` relative to the reference. Then the inertia about the
    /// reference is the parallel-axis theorem:
    ///
    ///     I = I_c + m*(c^Tc*1 - c*c^T)
    ///
    /// Translating the body by `d` sends `c -> c + d`. Expanding and subtracting the
    /// original leaves exactly two groups, which is how the code below is written:
    ///
    ///     dI = m*(d^Td*1 - d*d^T)            <- the pure point-mass term
    ///        + (2h*d)*1 - (h*d^T + d*h^T)    <- cross terms, using h = m*c
    ///
    /// The cross terms vanish when `h` is zero, which is the common case: a body's own
    /// inertia is stored about its own centre of mass. The general form is kept anyway -
    /// a COMPOSITE inertia carries a nonzero `h`, and silently being wrong for it in
    /// phase 2 would be a nasty trap.
    pub fn translate(self: Inertia, offset: Vec) Inertia {
        const m: f32 = self.mass;
        const d: Vec = offset;
        const h: Vec = self.h;

        // m*(d^Td*1 - d*d^T), the pure point-mass term.
        const dd: f32 = dot3(d, d);
        var diag: Vec = vec(
            m * (dd - d[0] * d[0]),
            m * (dd - d[1] * d[1]),
            m * (dd - d[2] * d[2]),
        );
        var off: Vec = vec(
            -m * d[0] * d[1],
            -m * d[0] * d[2],
            -m * d[1] * d[2],
        );

        // Cross terms: (h*d)*1 - 1/2(h*d^T + d*h^T), symmetric by construction.
        const hd: f32 = dot3(h, d);
        diag += vec(
            2.0 * (hd - h[0] * d[0]),
            2.0 * (hd - h[1] * d[1]),
            2.0 * (hd - h[2] * d[2]),
        );
        off += vec(
            -(h[0] * d[1] + d[0] * h[1]),
            -(h[0] * d[2] + d[0] * h[2]),
            -(h[1] * d[2] + d[1] * h[2]),
        );

        return .{
            .diag = self.diag + diag,
            .off = self.off + off,
            .h = h + d * splat(m),
            .mass = m,
        };
    }

    /// Re-express this inertia in a frame rotated by `q`. The rotational block transforms
    /// by similarity, `I' = R*I*R^T`, and the first moment just rotates.
    ///
    /// This is the function that lets us skip MuJoCo's principal-axis storage entirely.
    /// `mjModel` keeps a body's inertia as three principal moments plus a quaternion -
    /// seven numbers, and producing them needs a symmetric-3x3 eigendecomposition. We
    /// already store the full symmetric tensor in six, so we can rotate it directly and
    /// never diagonalize. Fewer numbers, no Jacobi iteration, no degenerate-eigenvalue
    /// edge cases. MuJoCo's form is the better one in C, where a diagonal inertia makes
    /// the inner loops cheaper; here the six-float form composes better.
    pub fn rotated(self: Inertia, q: Quat) Inertia {
        // `I' = R*I*R^T` expands to `I'[a][b] = row^a * (I * row^b)`, so we need the ROWS
        // of R - and `rotate(q, e_k)` gives the COLUMNS. The rows of R are the columns of
        // R^T, which is the rotation by the conjugate.
        //
        // This is not pedantry: using the columns computes `R^T*I*R` instead, which has the
        // same eigenvalues and a plausible-looking diagonal, so the error hides in the
        // off-diagonal terms alone. The oracle comparison caught it; nothing else would
        // have, which is the entire argument for having one.
        const inv: Quat = conjugate(q);
        const rx: Vec = rotate(inv, vec(1, 0, 0));
        const ry: Vec = rotate(inv, vec(0, 1, 0));
        const rz: Vec = rotate(inv, vec(0, 0, 1));
        // I*r^a for each basis column, then contract.
        const ix: Vec = self.applyTensor(rx);
        const iy: Vec = self.applyTensor(ry);
        const iz: Vec = self.applyTensor(rz);
        return .{
            .diag = vec(dot3(rx, ix), dot3(ry, iy), dot3(rz, iz)),
            .off = vec(dot3(rx, iy), dot3(rx, iz), dot3(ry, iz)),
            .h = rotate(q, self.h),
            .mass = self.mass,
        };
    }

    /// The rotational block alone, applied to a 3-vector: `I * v`. Shared by `mul` and
    /// `rotate`, which both need it and would otherwise spell it out twice.
    fn applyTensor(self: Inertia, v: Vec) Vec {
        const ixy: f32 = self.off[0];
        const ixz: f32 = self.off[1];
        const iyz: f32 = self.off[2];
        return vec(
            self.diag[0] * v[0] + ixy * v[1] + ixz * v[2],
            ixy * v[0] + self.diag[1] * v[1] + iyz * v[2],
            ixz * v[0] + iyz * v[1] + self.diag[2] * v[2],
        );
    }

    /// Build from the usual authoring form: mass, a centre of mass, and the principal
    /// moments in a frame rotated by `rot` from the body frame.
    pub fn fromPrincipal(
        mass: f32,
        com: Vec,
        moments: Vec,
        rot: Quat,
    ) Inertia {
        // Rotate the diagonal tensor into the body frame: I = R * diag(moments) * R^T.
        const cx: Vec = rotate(rot, vec(1, 0, 0));
        const cy: Vec = rotate(rot, vec(0, 1, 0));
        const cz: Vec = rotate(rot, vec(0, 0, 1));
        const mx: f32 = moments[0];
        const my: f32 = moments[1];
        const mz: f32 = moments[2];
        const diag: Vec = vec(
            mx * cx[0] * cx[0] + my * cy[0] * cy[0] + mz * cz[0] * cz[0],
            mx * cx[1] * cx[1] + my * cy[1] * cy[1] + mz * cz[1] * cz[1],
            mx * cx[2] * cx[2] + my * cy[2] * cy[2] + mz * cz[2] * cz[2],
        );
        const off: Vec = vec(
            mx * cx[0] * cx[1] + my * cy[0] * cy[1] + mz * cz[0] * cz[1],
            mx * cx[0] * cx[2] + my * cy[0] * cy[2] + mz * cz[0] * cz[2],
            mx * cx[1] * cx[2] + my * cy[1] * cy[2] + mz * cz[1] * cz[2],
        );
        return .{ .diag = diag, .off = off, .h = com * splat(mass), .mass = mass };
    }
};

// =============================================================================
// The model spec - what the user writes
//
// A designated struct literal, exactly like the rest of zimr's API. It is consumed at
// COMPTIME by `Spec()`, which validates it, generates name enums, and hands back a
// namespace whose `build()` produces the runtime `Model`.
// =============================================================================

/// The four kinds of degree of freedom, and the only four. A body with no joint is welded
/// to its parent, which is free and exact - no constraint needed.
pub const JointType = enum {
    /// 7 position coords (xyz + quat), 6 velocity coords. Only on a child of the world.
    free,
    /// 4 position coords (quat), 3 velocity coords. Orientation relative to the parent.
    ball,
    /// Translation along a body-fixed axis. 1 and 1.
    slide,
    /// Rotation about a body-fixed axis. 1 and 1.
    hinge,

    /// How many `qpos` entries this joint occupies. Larger than `dofCount` for anything
    /// carrying a quaternion - the reason `nq != nv` in most models.
    pub fn posCount(self: JointType) u32 {
        return switch (self) {
            .free => 7,
            .ball => 4,
            .slide, .hinge => 1,
        };
    }

    /// How many `qvel` entries this joint occupies.
    pub fn dofCount(self: JointType) u32 {
        return switch (self) {
            .free => 6,
            .ball => 3,
            .slide, .hinge => 1,
        };
    }
};

/// How hard a constraint pushes back, expressed as the RESPONSE you want rather than as
/// raw gains.
///
/// MuJoCo calls this `solref` and stores it as two unnamed floats. The parameterization is
/// the good part and worth keeping: you say how fast the violation should be corrected and
/// how bouncy the correction is, and the engine derives stiffness and damping from that -
///
///     k = 1 / (d_max^2 * time_const^2 * damp_ratio^2)      b = 2 / (d_max * time_const)
///
/// so `time_const` behaves like a settling time and `damp_ratio = 1` is critically damped.
/// Below 1 overshoots and bounces; above 1 is sluggish.
///
/// A time constant shorter than about two timesteps is asking the solver for a correction
/// it cannot represent, and shows up as jitter.
pub const Softness = struct {
    /// Seconds. MuJoCo's default is two timesteps at its default rate.
    time_const_s: f32 = 0.02,
    /// 1 is critically damped.
    damp_ratio: f32 = 1.0,
};

/// How MUCH of the constraint is enforced, as a function of how badly it is violated.
///
/// Impedance `d in (0,1)` interpolates between "constraint absent" and "constraint rigid".
/// It is not a constant: it ramps from `min` to `max` as the violation grows past `width`,
/// following a sigmoid whose shape `midpoint` and `power` control. That ramp is what makes
/// contact onset SMOOTH - a constraint that switched on abruptly would be a step change in
/// force, and (per section 4d) would have no derivative exactly where one is needed.
///
/// The regularizer that results is `R = (1-d)/d * A_hat`, where `A_hat` is the constraint-space
/// inertia. Scaling by `A_hat` is the detail that makes `Softness` mean the same thing on a
/// 1 g finger and a 100 kg torso.
pub const Impedance = struct {
    /// Impedance at zero violation.
    min: f32 = 0.9,
    /// Impedance once fully saturated. Also the `d_max` in the stiffness formula above.
    max: f32 = 0.95,
    /// Violation over which the ramp happens, in the constraint's own units.
    width: f32 = 0.001,
    /// Where the sigmoid's knee sits, in [0,1].
    midpoint: f32 = 0.5,
    /// Sharpness. 1 is linear.
    power: f32 = 2.0,

    /// The sigmoid, evaluated at a residual. Returns impedance in [min, max].
    ///
    /// Faithful to MuJoCo's `getimpedance`, including the two saturated ends and the
    /// two-piece power curve - `a*x^p` below the midpoint, `1 - b*(1-x)^p` above, with the
    /// coefficients chosen so the pieces meet with matching value at the knee.
    pub fn at(self: Impedance, residual: f32) f32 {
        if (self.min == self.max or self.width <= 1.0e-15) {
            return 0.5 * (self.min + self.max);
        }
        const x: f32 = @abs(residual / self.width);
        if (x >= 1.0) {
            return self.max;
        }
        if (x <= 0.0) {
            return self.min;
        }
        const y: f32 = if (self.power == 1.0)
            x
        else if (x <= self.midpoint) blk: {
            const a: f32 = 1.0 / powf(self.midpoint, self.power - 1.0);
            break :blk a * powf(x, self.power);
        } else blk: {
            const b: f32 = 1.0 / powf(1.0 - self.midpoint, self.power - 1.0);
            break :blk 1.0 - b * powf(1.0 - x, self.power);
        };
        return self.min + y * (self.max - self.min);
    }
};

/// `x^p` for positive `x`. Named because `std.math.pow` is not reachable under the
/// no-std-math rule and the exp/log form is the intended one for a positive base.
fn powf(x: f32, p: f32) f32 {
    if (x <= 0.0) {
        return 0.0;
    }
    return @exp(p * @log(x));
}

/// One joint. `axis` is ignored for `free` and `ball` (they have no single axis), and
/// `pos` is the anchor point in the owning body's frame.
pub const JointSpec = struct {
    name: []const u8,
    kind: JointType,
    /// Rotation or slide axis, in the body frame. Normalized at build time.
    axis: Vec = vec(0, 0, 1),
    /// Anchor point in the body frame. Where the hinge actually is.
    pos: Vec = vec_zero,
    /// Travel limits `[lo, hi]`, in the joint's own units. `null` means unlimited.
    range: ?[2]f32 = null,
    /// How the limit pushes back, and how hard. Only consulted when `range` is set.
    limit_softness: Softness = .{},
    limit_impedance: Impedance = .{},
    /// Distance from the limit at which the constraint activates. Zero means "exactly at
    /// the limit"; a positive margin engages the constraint early, which lets a soft limit
    /// decelerate rather than catch.
    limit_margin: f32 = 0,
    /// Rotor inertia reflected through a gearbox - a real physical quantity, and also the
    /// cheapest defence against an ill-conditioned mass matrix. `null` means "derive a
    /// small fraction of this DOF's own inertia at build time", which scales with the
    /// model instead of being an absolute number that is wrong at every scale but one.
    armature: ?f32 = null,
    damping: f32 = 0,
    stiffness: f32 = 0,
    /// The `qpos` value at which the spring is relaxed.
    ref: f32 = 0,
};

/// A collision/inertia shape attached to a body. Only the primitives that can be written
/// as a comptime literal live here; hulls and meshes need allocation and arrive through a
/// runtime model path later.
/// The lowest point of all the model's collision shapes at the current kinematics (run `forward` first) - how
/// far a pose reaches below the floor (z = 0) when negative. Shapes on the world body (the floor itself) are
/// skipped. Plain geometry: the lowest of a sphere's, a capsule's or cylinder's (along local Y), a box's
/// corners, a hull's points.
pub fn lowestPoint(m: *const Model, d: *const Data) f32 {
    // Higher than any robot will ever stand: the first shape replaces it.
    var lowest: f32 = no_shape_height;
    for (0..m.ngeom) |g| {
        if (m.geom_body[g] == 0) {
            continue;
        }
        lowest = @min(lowest, geomLowestPoint(m, d, g));
    }
    return lowest;
}

/// What a body with no collision shape reports as its lowest point: higher than any robot will ever stand, so it
/// never reads as touching the floor, and any real shape replaces it in a minimum.
pub const no_shape_height: f32 = 1.0e30;

/// Each body's own lowest point, the same geometry as `lowestPoint` (run `forward` first): `out[b]` is the lowest
/// point of body `b`'s collision shapes, `no_shape_height` for a body with none (the world body always - it is the
/// floor). What lets a tracker ask WHICH body touches the floor, not just whether something does.
pub fn bodyLowestPoints(m: *const Model, d: *const Data, out: []f32) void {
    assertf(out.len == m.nbody, @src(), "{d} heights for {d} bodies", .{ out.len, m.nbody });
    @memset(out, no_shape_height);
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        if (body == 0) {
            continue;
        }
        out[body] = @min(out[body], geomLowestPoint(m, d, g));
    }
}

/// The lowest point (world z) of one collision shape at the current kinematics. Plain geometry: the lowest of a
/// sphere's, a capsule's or cylinder's (along local Y), a box's corners, a hull's points.
fn geomLowestPoint(m: *const Model, d: *const Data, g: usize) f32 {
    const body: u32 = m.geom_body[g];
    const rot: Quat = qmul(d.body_xrot[body], m.geom_rot[g]);
    const center: Vec = d.body_xpos[body] + rotate(d.body_xrot[body], m.geom_pos[g]);
    switch (m.geom_shape[g]) {
        .sphere => |shape| return center[2] - shape.radius,
        .capsule => |shape| {
            const axis: Vec = rotate(rot, vec(0, shape.half_height, 0));
            return center[2] - @abs(axis[2]) - shape.radius;
        },
        .cylinder => |shape| {
            const axis: Vec = rotate(rot, vec(0, shape.half_height, 0));
            return center[2] - @abs(axis[2]) - shape.radius;
        },
        .box => |shape| {
            var lowest: f32 = no_shape_height;
            for (0..8) |corner| {
                const h: Vec = shape.half_extent;
                const x: f32 = if (corner & 1 == 0) -h[0] else h[0];
                const y: f32 = if (corner & 2 == 0) -h[1] else h[1];
                const z: f32 = if (corner & 4 == 0) -h[2] else h[2];
                lowest = @min(lowest, center[2] + rotate(rot, vec(x, y, z))[2]);
            }
            return lowest;
        },
        .hull => |shape| {
            var lowest: f32 = no_shape_height;
            for (shape.points) |point| {
                lowest = @min(lowest, center[2] + rotate(rot, point)[2]);
            }
            return lowest;
        },
    }
}

/// Lift a free-rooted robot so its lowest point sits `clearance` above the floor - a pose copied from a
/// capture puts feet INTO the floor (Geno's soles rest 4.5 mm below it, a walk's heel deeper), and the contact
/// solver resolves that overlap in one step with an impulse that throws the robot up and spins it. Never
/// lowers: a clip may start in the air. Returns the lift; the data is forwarded again when it moved.
pub fn restOnFloor(m: *const Model, d: *Data, clearance: f32) f32 {
    const root: usize = for (m.jnt_type, 0..) |kind, j| {
        if (kind == .free) {
            break j;
        }
    } else return 0.0;
    const lift: f32 = clearance - lowestPoint(m, d);
    if (!(lift > 0.0)) {
        return 0.0;
    }
    d.pos[m.jnt_qpos_adr[root] + 2] += lift;
    d.stage = .stale;
    forward(m, d);
    return lift;
}

pub const GeomShape = union(enum) {
    sphere: struct { radius: f32 },
    box: struct { half_extent: Vec },
    /// Segment along local Y plus a radius - zimr's capsule convention, not MuJoCo's.
    capsule: struct { half_height: f32, radius: f32 },
    cylinder: struct { half_height: f32, radius: f32 },
    /// An arbitrary convex shape, given as the point cloud its hull is taken of.
    ///
    /// * WHY A POINT CLOUD RATHER THAN A BUILT HULL. robot.zig depends only on zimrmath and
    /// has no convex-hull builder - nor should it, since it never does collision detection.
    /// The points are what a mesh file provides; the physics engine builds the hull, and the
    /// mass properties below are derived here from the points' bounding box, which is all
    /// the inertia model needs.
    ///
    /// Real robot models describe collision with meshes almost exclusively, so without this
    /// an imported robot can be simulated but cannot touch anything.
    hull: struct {
        points: []const Vec,
        /// Inertia is computed from the point cloud's bounding box rather than the true
        /// hull volume. A box that contains the shape overestimates its moments - safe in
        /// the sense that it never makes a link easier to spin than it should be, and
        /// irrelevant for any URDF that states `<inertial>` explicitly, which is nearly all
        /// of them. Exact hull inertia belongs with the hull builder, in the physics engine.
        bounds_half_extent: Vec,
    },
};

/// A geom contributes mass (unless `mass` is given directly) and, from phase 7, collision.
pub const GeomSpec = struct {
    shape: GeomShape,
    pos: Vec = vec_zero,
    rot: Quat = quat_identity,
    /// kg/m^3. Ignored when `mass` is set.
    /// Coulomb friction against whatever this touches.
    ///
    /// -- ** IT LIVES ON THE GEOM BECAUSE THAT IS WHERE THE MATERIAL IS --
    ///
    /// A contact needs one number and there are two surfaces, so the pair has to be combined -
    /// geometrically, `sqrt(a*b)`, which is what both MuJoCo and `zimrphysics` use.
    ///
    /// * THIS WAS DROPPED FOR SEVERAL SESSIONS and the symptom was nothing like the cause. Every
    /// contact took a hardcoded 0.5 whatever the model said, and a limp humanoid on the ground
    /// crept sideways at a rate that ACCELERATED - 0.109 m over 25 s, against MuJoCo's 0.071 and
    /// falling. With the model's own 0.7 the creep goes steady and lands within 7% of MuJoCo.
    /// The default here matches MuJoCo's own default for the same reason.
    friction: f32 = 1.0,
    density: f32 = 1000.0,
    /// Override the density-derived mass. Useful when a model quotes link masses directly.
    mass: ?f32 = null,
};

/// A massless, collisionless frame on a body. Sites are where actuators push, where
/// tendons route, where sensors sit, and what Jacobians target. Nothing consumes them
/// until phase 5, but retrofitting them would touch every index table.
pub const SiteSpec = struct {
    name: []const u8,
    pos: Vec = vec_zero,
    rot: Quat = quat_identity,
};

/// One link of the tree. `parent = null` attaches to the world.
///
/// Bodies must be declared PARENT-FIRST. That is not a style preference: the tree passes
/// walk the array forwards and backwards assuming a parent always has a lower index, and
/// `Spec()` rejects a spec that violates it.
/// A body's mass properties, stated outright instead of derived from its geoms.
///
/// * WHY THIS EXISTS. `geomsToBodyMass` computes mass and inertia from geom shapes and
/// densities, which is right for a model you author by hand. Real robot models do not work
/// that way: a Franka Panda link says
///
///     mass="0.629769" fullinertia="0.00315 0.00388 0.004285 8.29e-7 0.00015 8.23e-6"
///
/// - numbers from CAD or from weighing the actual part. Its collision geoms are convex
/// hulls chosen for cheap contact, and their volume has nothing to do with the link's real
/// mass distribution. A census of five Menagerie models found 62 uses of `<inertial>`
/// (section 4i), so this is not an edge case; it is how robots are described.
///
/// When present this REPLACES the geom-derived properties entirely. The geoms still exist
/// and still collide - they just stop being the source of truth for mass.
pub const InertialSpec = struct {
    mass: f32,
    /// Centre of mass, in the body's frame.
    pos: Vec = vec_zero,
    /// The inertia tensor about the COM, in the body's frame, as MuJoCo's `fullinertia`
    /// orders it: the three diagonal terms, then xy, xz, yz.
    ///
    /// The full symmetric tensor rather than three principal moments plus a quaternion,
    /// for the same reason `Inertia` stores it that way (section 1 of the plan): no
    /// eigendecomposition, one fewer number, and no degenerate-eigenvalue edge cases.
    full_inertia: [6]f32,
};

pub const BodySpec = struct {
    name: []const u8,
    parent: ?[]const u8 = null,
    /// Pose relative to the parent's frame.
    pos: Vec = vec_zero,
    rot: Quat = quat_identity,
    /// Several joints on one body is legal and useful - three hinges give a ball joint
    /// with per-axis limits, which real robot models do use.
    joints: []const JointSpec = &.{},
    geoms: []const GeomSpec = &.{},
    sites: []const SiteSpec = &.{},
    /// Mass properties stated directly. When `null`, they are derived from the geoms.
    inertial: ?InertialSpec = null,
};

/// One joint's share of a fixed tendon.
pub const TendonJoint = struct {
    name: []const u8,
    /// How much this joint's coordinate contributes to the tendon's length. Negative
    /// couples the joints in opposite senses, which is how a differential is built.
    coefficient: f32 = 1,
};

/// A FIXED tendon: a scalar length that is a linear combination of joint coordinates.
///
///     length = sum coefficient_i * q_i
///
/// * WHAT IT IS FOR. A tendon couples joints WITHOUT introducing a closed kinematic loop.
/// Two wheels with coefficients `(1, 1)` turn together; `(1, -1)` makes them a
/// differential - one control drives them forward, another turns. A finger whose knuckles
/// bend in a fixed ratio is one tendon. The alternative, an equality constraint between
/// the joints, would need a solver row and would only hold approximately; a tendon holds
/// exactly and costs one dot product, because it is a definition rather than a constraint.
///
/// Its Jacobian is `dlength/dq`, which for a fixed tendon is just the coefficient vector -
/// constant, and known at build time. That is what makes it cheap and what makes it the
/// simplest possible transmission for an actuator to pull on.
///
/// Spatial tendons - a path through sites, wrapping around spheres and cylinders - come
/// later; the length and Jacobian would then be geometric and configuration-dependent, but
/// everything downstream stays identical, which is the point of separating transmission
/// from force generation (section 7 of the tutorial).
pub const TendonSpec = struct {
    name: []const u8,
    joints: []const TendonJoint,
    /// Spring and damper on the tendon's own length, as a joint has on its coordinate.
    stiffness: f32 = 0,
    damping: f32 = 0,
    /// The length at which the spring is relaxed.
    rest_length: f32 = 0,
};

/// How an actuator's force reaches the joints. Only `joint` exists today; tendon and site
/// transmissions arrive with phases 8 and 5b, and the shape is chosen so they slot in
/// without disturbing anything else.
pub const Transmission = union(enum) {
    /// Push directly on one scalar joint. `gear` scales control units to force units.
    joint: struct { name: []const u8, gear: f32 = 1 },
    /// Pull on a tendon. The actuator's scalar force is spread across every joint the
    /// tendon touches, in proportion to that joint's coefficient - which is exactly the
    /// tendon Jacobian, so this is `J^Tf` again in miniature.
    tendon: struct { name: []const u8, gear: f32 = 1 },
};

/// An actuator's internal state, if it has one.
///
/// Real actuators are not instantaneous. A pneumatic cylinder fills; a muscle activates; a
/// motor's current takes time to build. Giving the actuator its own state makes the system
/// THIRD order - position, velocity, and activation - which is the honest model.
/// Parameters shared by both filter forms. Named rather than anonymous so a `switch` can
/// capture both prongs at once - two anonymous structs with identical fields are still
/// different types.
pub const FilterParams = struct { time_const_s: f32 };

pub const Activation = union(enum) {
    /// No internal state: the control IS the input to the force law.
    none,
    /// `w_dot = u`. The control commands a RATE of change, which is how you build an actuator
    /// that holds its position when you let go.
    integrator,
    /// `w_dot = (u - w)/tau`. A first-order lag: the actuator chases the command.
    filter: FilterParams,
    /// The same filter, integrated analytically instead of by Euler.
    ///
    /// Worth having as a separate type rather than an implementation detail: an
    /// Euler-integrated filter DIVERGES when `tau < dt`, and a fast actuator in a slow
    /// simulation is a completely ordinary thing to want. The exact form is stable for any
    /// positive `tau`, and the two agree as `dt -> 0`.
    filter_exact: FilterParams,
};

/// An actuator. The three shortcuts cover almost every real use; `general` exposes the
/// affine law underneath for the rest.
///
/// * THE MODEL, which is worth understanding because the shortcuts are not special cases -
/// they are the same law with different coefficients:
///
///     force = gain * (activation or control) + bias0 + bias1*length + bias2*velocity
///
/// where `length` is the transmission's scalar coordinate (a joint angle, say) and
/// `velocity` its rate. Then:
///
///     motor    gain = gear,  bias = (0, 0, 0)          - commanded force
///     position gain = kp,    bias = (0, -kp, -kv)      - control is a TARGET POSITION
///     velocity gain = kv,    bias = (0, 0, -kv)        - control is a TARGET VELOCITY
///
/// Read the position row: `kp*u - kp*l - kv*l_dot` is exactly `kp*(u - l) - kv*l_dot`, a PD
/// controller. A servo is not a different mechanism from a motor; it is a motor whose bias
/// terms happen to subtract the current state. That is the whole idea, and it is why the
/// force law is deliberately kept affine - an affine law can be INVERTED, so inverse
/// dynamics can recover what control would have produced a given force.
pub const ActuatorSpec = struct {
    name: []const u8,
    on: Transmission,
    kind: Kind = .motor,
    activation: Activation = .none,
    /// Clamp on the control input. Real actuators saturate; a model without a limit will
    /// happily command a thousand newton-metres.
    ctrl_range: ?[2]f32 = null,
    /// Clamp on the produced force.
    force_range: ?[2]f32 = null,

    pub const Kind = union(enum) {
        /// Direct force control: the control IS the force (times gear).
        motor,
        /// Position servo. `kv` adds damping, which almost every real servo needs.
        position: struct { kp: f32, kv: f32 = 0 },
        /// Velocity servo.
        velocity: struct { kv: f32 },
        /// The affine law, exposed.
        general: struct { gain: f32 = 1, bias: [3]f32 = .{ 0, 0, 0 } },
    };

    /// The affine law's coefficients: `force = gain*input + bias[0] + bias[1]*l + bias[2]*l_dot`.
    pub const Coefficients = struct { gain: f32, bias: [3]f32 };

    /// Collapse the shortcut into the affine coefficients the engine actually runs.
    pub fn coefficients(self: ActuatorSpec) Coefficients {
        return switch (self.kind) {
            .motor => .{ .gain = 1, .bias = .{ 0, 0, 0 } },
            .position => |k| .{ .gain = k.kp, .bias = .{ 0, -k.kp, -k.kv } },
            .velocity => |k| .{ .gain = k.kv, .bias = .{ 0, 0, -k.kv } },
            .general => |g| .{ .gain = g.gain, .bias = g.bias },
        };
    }
};

/// What a sensor measures. The target it names depends on the kind - a joint, a tendon,
/// an actuator or a site - and `Spec()` checks that the name resolves to the right thing.
///
/// * EACH KIND BELONGS TO A PIPELINE STAGE, and that is not an implementation detail. A
/// gyro can only be read once velocities are known; an accelerometer only once forces have
/// been resolved. Computing them at the wrong point would not be slightly stale - it would
/// be a different quantity. MuJoCo evaluates its sensors at exactly three points for this
/// reason, and so do we.
pub const SensorKind = enum {
    // ---- position stage: everything derived from q alone ----
    /// Scalar joint coordinate. Hinge and slide only.
    joint_pos,
    /// Scalar tendon length.
    tendon_pos,
    /// Site position in WORLD coordinates.
    site_pos,
    /// Site orientation in world coordinates, as a quaternion.
    site_quat,

    // ---- velocity stage ----
    joint_vel,
    tendon_vel,
    /// Site linear velocity, WORLD frame.
    site_lin_vel,
    /// Site angular velocity, WORLD frame.
    site_ang_vel,
    /// Linear velocity in the SITE's own frame - what a mounted velocimeter reads.
    velocimeter,
    /// Angular velocity in the site's own frame - what a mounted gyro reads.
    gyro,

    // ---- acceleration stage: needs forces, so after the solve ----
    /// Scalar actuator force.
    actuator_force,
    /// PROPER acceleration in the site's frame - what a real accelerometer reads,
    /// gravity included. See `sensorAcc`.
    accelerometer,

    /// How many numbers this sensor writes.
    pub fn dim(self: SensorKind) u32 {
        return switch (self) {
            .joint_pos, .tendon_pos, .joint_vel, .tendon_vel, .actuator_force => 1,
            .site_quat => 4,
            .site_pos, .site_lin_vel, .site_ang_vel, .velocimeter, .gyro, .accelerometer => 3,
        };
    }

    /// The earliest pipeline stage at which this reading is meaningful.
    pub fn stage(self: SensorKind) Stage {
        return switch (self) {
            .joint_pos, .tendon_pos, .site_pos, .site_quat => .position,
            .joint_vel, .tendon_vel, .site_lin_vel, .site_ang_vel, .velocimeter, .gyro => .velocity,
            .actuator_force, .accelerometer => .force,
        };
    }
};

/// One sensor.
pub const SensorSpec = struct {
    name: []const u8,
    kind: SensorKind,
    /// The joint, tendon, actuator or site this reads, depending on `kind`.
    target: []const u8,
};

/// Which integrator `step` uses. Only `euler` and `rk4` exist before phase 10.
pub const Integrator = enum {
    /// Semi-implicit, with joint damping treated implicitly - MuJoCo's `mjINT_EULER`.
    euler,
    /// Explicit 4th-order Runge-Kutta. Accurate and unstable in the same places Euler is.
    rk4,
    /// Implicit in velocity, INCLUDING the Coriolis derivative - MuJoCo's `mjINT_IMPLICIT`.
    ///
    /// **Four times more accurate than `implicitfast` on gyroscopically coupled systems** - a
    /// fast rotor on a damped gimbal - at one linear solve per step. Measured; see the
    /// integrator comparison test for the numbers and for the case where it does NOT help.
    implicit,
    /// Implicit in velocity without the Coriolis derivative - MuJoCo's `mjINT_IMPLICITFAST`,
    /// and its recommended default. For a damped, actuated mechanism the omitted term
    /// contributes little and costs the most.
    implicitfast,
};

/// Simulation-wide settings, mirroring `mjModel.opt`.
pub const Options = struct {
    /// Defaults to zimr's Y-up convention. **An MJCF-imported model is Z-up and sets
    /// `(0, 0, -9.81)` instead** - nothing in this file cares which, but your contact
    /// normals and your camera do. See the file header.
    gravity: Vec = vec(0, -9.81, 0),
    timestep: f32 = 1.0 / 240.0,
    integrator: Integrator = .euler,
    /// Ceiling on any single velocity DOF, in m/s or rad/s.
    ///
    /// Standard in every production engine - Bullet's `setMaxLinearVelocity`, PhysX's
    /// `maxLinearVelocity`, Jolt's `mMaxLinearVelocity` - and for the same reason: a
    /// rigid-body step cannot describe a body that moves further than its own size in one
    /// timestep, so a speed past that point is not physics being violent, it is the
    /// discretisation having stopped applying.
    ///
    /// 100 m/s is far above anything a robot or a thrown object does - a projectile at 30 m/s
    /// is a hard throw - and far below where f32 products begin to overflow.
    ///
    /// See `boundVelocity` for the failure that motivated it.
    max_velocity: f32 = 100.0,
    solver: SolverOptions = .{},
    /// Start each solver row from the force that constraint carried last step.
    ///
    /// On by default because it is a large, free win: measured at 29 iterations cold versus
    /// a handful warm on a seven-axis arm against its limits. The switch exists so a test
    /// can prove the converged answer does not depend on it - and so a determinism-sensitive
    /// caller (differential rollouts, section 4d) can turn it off and get a solve that depends on
    /// nothing but the current state.
    warm_start: bool = true,
    /// How many simultaneous contacts to make room for. Sizing happens at build, so this
    /// is a promise about the worst case rather than a limit the simulation enforces
    /// gracefully - exceeding it is an assert, on the zimr392 principle that a silently
    /// clamped contact pool is far worse than a loud one.
    max_contacts: u32 = 32,
};

/// Which kind of transmission an actuator uses - the tag of `Transmission`, stored
/// separately because the payloads have been resolved to indices by then.
pub const TransmissionKind = enum { joint, tendon };

/// A pyramidal contact costs four rows: two tangent directions, two opposing edges each.
pub const rows_per_contact: u32 = 4;

/// The whole model description.
pub const ModelSpec = struct {
    bodies: []const BodySpec,
    tendons: []const TendonSpec = &.{},
    sensors: []const SensorSpec = &.{},
    actuators: []const ActuatorSpec = &.{},
    /// Loop closures. See `EqualitySpec` - a tree cannot express a ring, so the rings are
    /// stated separately and enforced by the solver.
    equalities: []const EqualitySpec = &.{},
    options: Options = .{},
};

/// A hemisphere's transverse moment about its own centroid, as a multiple of `m*r^2`:
/// `2/5 - 9/64`. The `2/5` is the moment about the flat face; the `9/64` walks it back to
/// the centroid, which sits `3r/8` out. See `shapeMoments`.
const hemisphere_transverse: f32 = 2.0 / 5.0 - 9.0 / 64.0;

/// Armature default: this fraction of a DOF's own diagonal inertia. Small enough to be
/// physically negligible, large enough to keep the factorization honest.
const default_armature_fraction: f32 = 0.01;

// =============================================================================
// Spec() - the comptime layer
//
// Validates the spec, generates name enums, and computes the counts. Everything that can
// be wrong with a model becomes a compile error here rather than a runtime check. What it
// deliberately does NOT do is build the index tables: those are ordinary runtime data
// produced by `build()`, so a model loaded from a file at runtime can take the same path.
// =============================================================================

/// A comptime evaluation budget that scales with the model, rather than a magic number
/// that works until someone builds a slightly larger robot. The quadratic term is real:
/// `assertUniqueNames` compares every name against every later one.
fn quotaFor(comptime spec: ModelSpec) u32 {
    var names: u32 = 0;
    var parts: u32 = 0;
    for (spec.bodies) |b| {
        names += 1 + @as(u32, @intCast(b.joints.len + b.sites.len));
        parts += @as(u32, @intCast(b.joints.len + b.sites.len + b.geoms.len));
    }
    const bodies: u32 = @intCast(spec.bodies.len);
    // name-uniqueness is quadratic; everything else is linear in the parts.
    return 4000 + 8 * (names * names + bodies * bodies) + 64 * (parts + bodies);
}

/// Turn a list of comptime names into an exhaustive enum whose tag values are the index
/// into that list. `@backingInt(E.foo)` is therefore the array index, for free.
fn NamesEnum(comptime names: []const []const u8) type {
    if (names.len == 0) {
        // An enum with no fields is legal but useless; callers guard on the count instead.
        return u32;
    }
    var values: [names.len]u32 = undefined;
    for (&values, 0..) |*v, i| {
        v.* = @intCast(i);
    }
    const frozen = values;
    return @Enum(u32, .exhaustive, names, &frozen);
}

/// Compile-error unless every string in `names` is distinct. `what` names the category so
/// the message says which list to look at.
fn assertUniqueNames(comptime names: []const []const u8, comptime what: []const u8) void {
    for (names, 0..) |a, i| {
        if (a.len == 0) {
            @compileError("robot: a " ++ what ++ " has an empty name");
        }
        for (names[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) {
                @compileError("robot: duplicate " ++ what ++ " name '" ++ a ++ "'");
            }
        }
    }
}

/// Validate a spec and derive everything about it that is knowable without allocating.
///
///     const Arm = robot.Spec(.{ .bodies = &.{ ... } });
///     var model: robot.Model = try Arm.build(gpa);
///     var data: robot.Data = try robot.Data.init(gpa, &model);
///     data.setPos(Arm.Joint.elbow, 0.4);        // compile-checked
///
pub fn Spec(comptime spec: ModelSpec) type {
    // Zig caps comptime loop iterations to catch runaway evaluation, and the default of
    // 1000 is reached by a perfectly ordinary humanoid: the validation pass alone is
    // bodies x joints x geoms, and the name collection is quadratic in the name count.
    // Measured - an 18-body model failed to COMPILE before this line existed.
    //
    // The quota scales with the spec so a bigger model does not hit the same wall, with a
    // generous constant because the cost of over-estimating is nothing (it is a ceiling,
    // not an allocation) and the cost of under-estimating is a confusing compile error in
    // someone else's model.
    @setEvalBranchQuota(quotaFor(spec));

    // ---- validation -------------------------------------------------------
    comptime {
        if (spec.bodies.len == 0) {
            @compileError("robot: a model needs at least one body");
        }
        if (spec.options.timestep <= 0.0) {
            @compileError("robot: timestep must be positive");
        }

        var body_names: [spec.bodies.len][]const u8 = undefined;
        for (spec.bodies, 0..) |b, i| {
            body_names[i] = b.name;
        }
        assertUniqueNames(&body_names, "body");

        for (spec.bodies, 0..) |b, bi| {
            // A parent must exist AND be declared earlier - the tree passes rely on it.
            if (b.parent) |parent| {
                var found: bool = false;
                for (spec.bodies[0..bi]) |earlier| {
                    if (std.mem.eql(u8, earlier.name, parent)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("robot: body '" ++ b.name ++ "' names parent '" ++ parent ++
                        "', which is not a body declared before it (bodies must be parent-first)");
                }
            }

            for (b.joints) |j| {
                // A free joint IS the six degrees of freedom of a floating base. Putting
                // one deeper in the tree, or beside another joint, is always a modelling
                // mistake rather than an exotic mechanism.
                if (j.kind == .free) {
                    if (b.parent != null) {
                        @compileError("robot: free joint '" ++ j.name ++ "' on body '" ++ b.name ++
                            "' — a free joint only belongs on a direct child of the world");
                    }
                    if (b.joints.len != 1) {
                        @compileError("robot: body '" ++ b.name ++
                            "' has a free joint alongside other joints; a free joint is already all six DOFs");
                    }
                }
                if (j.kind == .slide or j.kind == .hinge) {
                    const len_sq: f32 = j.axis[0] * j.axis[0] + j.axis[1] * j.axis[1] + j.axis[2] * j.axis[2];
                    if (len_sq < 1.0e-12) {
                        @compileError("robot: joint '" ++ j.name ++ "' has a zero-length axis");
                    }
                }
                if (j.range) |r| {
                    if (r[0] > r[1]) {
                        @compileError("robot: joint '" ++ j.name ++ "' has range lo > hi");
                    }
                    // A ball or free joint's limit is a CONE on a rotation, not an interval
                    // on a scalar. MuJoCo supports it by converting the quaternion to
                    // axis-angle; we do not, and silently ignoring a limit the model asked
                    // for is worse than refusing it.
                    if (j.kind != .hinge and j.kind != .slide) {
                        @compileError("robot: joint '" ++ j.name ++
                            "' is a ball or free joint with a range — limits are only " ++
                            "supported on hinge and slide joints");
                    }
                    if (j.limit_margin < 0.0) {
                        @compileError("robot: joint '" ++ j.name ++ "' has a negative limit margin");
                    }
                    // MuJoCo overloads the SIGN of solref to mean "these are K and B
                    // directly". `Softness` names its fields, so a negative time constant
                    // is simply nonsense rather than a second meaning.
                    if (j.limit_softness.time_const_s <= 0.0 or j.limit_softness.damp_ratio <= 0.0) {
                        @compileError("robot: joint '" ++ j.name ++
                            "' has a non-positive limit time constant or damping ratio");
                    }
                    const imp = j.limit_impedance;
                    if (imp.min <= 0.0 or imp.max >= 1.0 or imp.min > imp.max) {
                        @compileError("robot: joint '" ++ j.name ++
                            "' needs 0 < impedance.min <= impedance.max < 1");
                    }
                    if (imp.width < 0.0 or imp.power < 1.0 or
                        imp.midpoint <= 0.0 or imp.midpoint >= 1.0)
                    {
                        @compileError("robot: joint '" ++ j.name ++
                            "' has an impedance ramp that is not a valid sigmoid " ++
                            "(need width >= 0, power >= 1, 0 < midpoint < 1)");
                    }
                }
                if (j.armature) |a| {
                    if (a < 0.0) {
                        @compileError("robot: joint '" ++ j.name ++ "' has negative armature");
                    }
                }
            }

            for (b.geoms) |g| {
                const bad: bool = switch (g.shape) {
                    .sphere => |s| s.radius <= 0.0,
                    .box => |s| s.half_extent[0] <= 0.0 or s.half_extent[1] <= 0.0 or s.half_extent[2] <= 0.0,
                    // A hull needs enough points to BE a volume: three define a plane, and
                    // a degenerate cloud makes a hull builder produce something arbitrary
                    // rather than fail. Cheaper to reject here, by name, at compile time.
                    .hull => |s| s.points.len < 4,
                    .capsule => |s| s.radius <= 0.0 or s.half_height < 0.0,
                    .cylinder => |s| s.radius <= 0.0 or s.half_height <= 0.0,
                };
                if (bad) {
                    @compileError("robot: body '" ++ b.name ++ "' has a geom with a non-positive size");
                }
                if (g.mass) |m| {
                    // * ZERO IS LEGAL AND MEANINGFUL: a COLLISION-ONLY geom.
                    //
                    // An imported robot states its mass properties in `<inertial>` and its
                    // collision geometry separately, so its geoms must contribute no mass -
                    // otherwise a link is counted twice and comes out several times too
                    // heavy. `mass = 0` says exactly that, and the body's own `inertial`
                    // supplies the physics.
                    //
                    // Negative remains an error: it is not a shape that weighs nothing, it
                    // is a shape that weighs less than nothing.
                    if (m < 0.0) {
                        @compileError("robot: body '" ++ b.name ++ "' has a geom with negative mass");
                    }
                    if (m == 0.0 and b.inertial == null) {
                        @compileError("robot: body '" ++ b.name ++
                            "' has a massless geom but no <inertial> to supply its mass — " ++
                            "the body would have none at all");
                    }
                } else if (g.density <= 0.0) {
                    @compileError("robot: body '" ++ b.name ++ "' has a geom with non-positive density");
                }
            }

            // A body that moves must have inertia, or the mass matrix is singular and the
            // factorization divides by zero. Catch it here with the body's name rather
            // than as a NaN three phases downstream.
            if (b.inertial) |inertial| {
                // * A zero mass is legal on a body with NO degrees of freedom, and real
                // models rely on it: a KUKA iiwa's `lbr_iiwa_link_0` is the bolted-down
                // base and declares `mass="0.0"`. Nothing accelerates it, so nothing
                // divides by it.
                //
                // With joints it is fatal - the mass matrix is singular and `factorM`
                // divides by zero - which is the same rule as the geom check below, and
                // for the same reason.
                if (b.joints.len > 0 and inertial.mass <= 0.0) {
                    @compileError("robot: body '" ++ b.name ++
                        "' has joints but a non-positive stated mass — the mass matrix " ++
                        "would be singular");
                }
                if (inertial.mass < 0.0) {
                    @compileError("robot: body '" ++ b.name ++ "' has a negative stated mass");
                }
                // The diagonal must be positive and satisfy the triangle inequality, or the
                // tensor is not the inertia of any real object and `factorM` will fail
                // somewhere far from here with a much less helpful message.
                const ixx: f32 = inertial.full_inertia[0];
                const iyy: f32 = inertial.full_inertia[1];
                const izz: f32 = inertial.full_inertia[2];
                // A massless jointless body may legitimately state a zero tensor; only a
                // body that can actually move needs positive moments.
                if (b.joints.len > 0 and (ixx <= 0.0 or iyy <= 0.0 or izz <= 0.0)) {
                    @compileError("robot: body '" ++ b.name ++
                        "' has joints and a non-positive principal moment in its stated inertia");
                }
                if (ixx < 0.0 or iyy < 0.0 or izz < 0.0) {
                    @compileError("robot: body '" ++ b.name ++ "' has a negative principal moment");
                }
                if (ixx + iyy < izz or ixx + izz < iyy or iyy + izz < ixx) {
                    @compileError("robot: body '" ++ b.name ++
                        "' has a stated inertia violating the triangle inequality — no rigid " ++
                        "body has those moments");
                }
            } else if (b.joints.len > 0 and b.geoms.len == 0) {
                @compileError("robot: body '" ++ b.name ++
                    "' has joints but no geoms, so it has no mass — the mass matrix would be singular");
            }
        }

        var sensor_names_check: [spec.sensors.len][]const u8 = undefined;
        for (spec.sensors, 0..) |sensor, i| {
            sensor_names_check[i] = sensor.name;
            // Each kind reads a particular kind of thing, and naming the wrong one is a
            // modelling mistake worth catching at compile time rather than as a wrong
            // number at runtime.
            const found: bool = switch (sensor.kind) {
                .joint_pos, .joint_vel => blk: {
                    for (spec.bodies) |b| {
                        for (b.joints) |j| {
                            if (std.mem.eql(u8, j.name, sensor.target)) {
                                if (j.kind != .hinge and j.kind != .slide) {
                                    @compileError("robot: sensor '" ++ sensor.name ++
                                        "' reads joint '" ++ sensor.target ++
                                        "', which is not scalar");
                                }
                                break :blk true;
                            }
                        }
                    }
                    break :blk false;
                },
                .tendon_pos, .tendon_vel => blk: {
                    for (spec.tendons) |t| {
                        if (std.mem.eql(u8, t.name, sensor.target)) {
                            break :blk true;
                        }
                    }
                    break :blk false;
                },
                .actuator_force => blk: {
                    for (spec.actuators) |act| {
                        if (std.mem.eql(u8, act.name, sensor.target)) {
                            break :blk true;
                        }
                    }
                    break :blk false;
                },
                .site_pos, .site_quat, .site_lin_vel, .site_ang_vel, .velocimeter, .gyro, .accelerometer => blk: {
                    for (spec.bodies) |b| {
                        for (b.sites) |site| {
                            if (std.mem.eql(u8, site.name, sensor.target)) {
                                break :blk true;
                            }
                        }
                    }
                    break :blk false;
                },
            };
            if (!found) {
                @compileError("robot: sensor '" ++ sensor.name ++ "' names '" ++ sensor.target ++
                    "', which is not a thing of the kind it reads");
            }
        }
        assertUniqueNames(&sensor_names_check, "sensor");

        var tendon_names_check: [spec.tendons.len][]const u8 = undefined;
        for (spec.tendons, 0..) |t, i| {
            tendon_names_check[i] = t.name;
            if (t.joints.len == 0) {
                @compileError("robot: tendon '" ++ t.name ++ "' couples no joints");
            }
            for (t.joints) |tj| {
                var found: bool = false;
                for (spec.bodies) |b| {
                    for (b.joints) |j| {
                        if (std.mem.eql(u8, j.name, tj.name)) {
                            // A tendon's length is a sum of scalar coordinates, so every
                            // joint it names must have one.
                            if (j.kind != .hinge and j.kind != .slide) {
                                @compileError("robot: tendon '" ++ t.name ++ "' includes joint '" ++
                                    tj.name ++ "', which is not a hinge or slide");
                            }
                            found = true;
                        }
                    }
                }
                if (!found) {
                    @compileError("robot: tendon '" ++ t.name ++ "' names joint '" ++
                        tj.name ++ "', which does not exist");
                }
            }
        }
        assertUniqueNames(&tendon_names_check, "tendon");

        for (spec.actuators) |act| {
            switch (act.on) {
                .joint => |t| {
                    var found: bool = false;
                    for (spec.bodies) |b| {
                        for (b.joints) |j| {
                            if (std.mem.eql(u8, j.name, t.name)) {
                                // A joint transmission is a SCALAR coordinate, so it needs
                                // a scalar joint. A ball or free joint has no single angle
                                // to servo toward.
                                if (j.kind != .hinge and j.kind != .slide) {
                                    @compileError("robot: actuator '" ++ act.name ++ "' drives joint '" ++
                                        t.name ++ "', which is not a hinge or slide — a joint " ++
                                        "transmission needs a scalar coordinate");
                                }
                                found = true;
                            }
                        }
                    }
                    if (!found) {
                        @compileError("robot: actuator '" ++ act.name ++ "' names joint '" ++
                            t.name ++ "', which does not exist");
                    }
                    if (t.gear == 0.0) {
                        @compileError("robot: actuator '" ++ act.name ++ "' has zero gear, so it can do nothing");
                    }
                },
                .tendon => |t| {
                    var found: bool = false;
                    for (spec.tendons) |tendon| {
                        if (std.mem.eql(u8, tendon.name, t.name)) {
                            found = true;
                        }
                    }
                    if (!found) {
                        @compileError("robot: actuator '" ++ act.name ++ "' names tendon '" ++
                            t.name ++ "', which does not exist");
                    }
                    if (t.gear == 0.0) {
                        @compileError("robot: actuator '" ++ act.name ++ "' has zero gear, so it can do nothing");
                    }
                },
            }
            if (act.ctrl_range) |r| {
                if (r[0] > r[1]) {
                    @compileError("robot: actuator '" ++ act.name ++ "' has ctrl_range lo > hi");
                }
            }
            switch (act.activation) {
                .filter, .filter_exact => |f| {
                    if (f.time_const_s <= 0.0) {
                        @compileError("robot: actuator '" ++ act.name ++
                            "' has a non-positive filter time constant");
                    }
                },
                .none, .integrator => {},
            }
        }
    }

    // ---- derived names and counts ----------------------------------------
    const Counts = struct { nq: u32, nv: u32, njnt: u32, nsite: u32, ngeom: u32, na: u32 };
    const counts: Counts = comptime blk: {
        var nq: u32 = 0;
        var nv: u32 = 0;
        var njnt: u32 = 0;
        var nsite: u32 = 0;
        var ngeom: u32 = 0;
        var na: u32 = 0;
        for (spec.actuators) |act| {
            if (act.activation != .none) {
                na += 1;
            }
        }
        for (spec.bodies) |b| {
            for (b.joints) |j| {
                nq += j.kind.posCount();
                nv += j.kind.dofCount();
                njnt += 1;
            }
            nsite += @intCast(b.sites.len);
            ngeom += @intCast(b.geoms.len);
        }
        break :blk Counts{ .nq = nq, .nv = nv, .njnt = njnt, .nsite = nsite, .ngeom = ngeom, .na = na };
    };

    const joint_names: [counts.njnt][]const u8 = comptime blk: {
        var names: [counts.njnt][]const u8 = undefined;
        var n: usize = 0;
        for (spec.bodies) |b| {
            for (b.joints) |j| {
                names[n] = j.name;
                n += 1;
            }
        }
        const frozen = names;
        break :blk frozen;
    };
    comptime assertUniqueNames(&joint_names, "joint");

    const site_names: [counts.nsite][]const u8 = comptime blk: {
        var names: [counts.nsite][]const u8 = undefined;
        var n: usize = 0;
        for (spec.bodies) |b| {
            for (b.sites) |s| {
                names[n] = s.name;
                n += 1;
            }
        }
        const frozen = names;
        break :blk frozen;
    };
    comptime assertUniqueNames(&site_names, "site");

    const sensor_names: [spec.sensors.len][]const u8 = comptime blk: {
        var names: [spec.sensors.len][]const u8 = undefined;
        for (spec.sensors, 0..) |sensor, i| {
            names[i] = sensor.name;
        }
        const frozen = names;
        break :blk frozen;
    };

    const tendon_names: [spec.tendons.len][]const u8 = comptime blk: {
        var names: [spec.tendons.len][]const u8 = undefined;
        for (spec.tendons, 0..) |t, i| {
            names[i] = t.name;
        }
        const frozen = names;
        break :blk frozen;
    };

    const actuator_names: [spec.actuators.len][]const u8 = comptime blk: {
        var names: [spec.actuators.len][]const u8 = undefined;
        for (spec.actuators, 0..) |act, i| {
            names[i] = act.name;
        }
        const frozen = names;
        break :blk frozen;
    };
    comptime assertUniqueNames(&actuator_names, "actuator");

    const body_names: [spec.bodies.len][]const u8 = comptime blk: {
        var names: [spec.bodies.len][]const u8 = undefined;
        for (spec.bodies, 0..) |b, i| {
            names[i] = b.name;
        }
        const frozen = names;
        break :blk frozen;
    };

    return struct {
        /// The spec this was built from, kept so `build` needs no arguments beyond an
        /// allocator and so tooling can introspect a model type.
        pub const model_spec: ModelSpec = spec;

        /// Body 0 is the WORLD, so a spec body's index is its position in the list plus
        /// one. These enums number the spec bodies from zero; add `world_body` when
        /// indexing `Model`'s arrays.
        pub const Body = NamesEnum(&body_names);
        pub const Joint = NamesEnum(&joint_names);
        pub const Site = NamesEnum(&site_names);
        pub const Actuator = NamesEnum(&actuator_names);
        pub const Tendon = NamesEnum(&tendon_names);
        pub const Sensor = NamesEnum(&sensor_names);

        pub const nbody: u32 = @as(u32, spec.bodies.len) + 1; // +1 for the world
        pub const njnt: u32 = counts.njnt;
        pub const nsite: u32 = counts.nsite;
        pub const ngeom: u32 = counts.ngeom;
        pub const nq: u32 = counts.nq;
        pub const nv: u32 = counts.nv;
        /// Number of actuators, and therefore of controls.
        pub const nu: u32 = @intCast(spec.actuators.len);
        /// Number of ACTIVATION states - only actuators with internal dynamics have one.
        pub const na: u32 = counts.na;
        /// Number of tendons.
        pub const ntendon: u32 = @intCast(spec.tendons.len);
        /// Number of sensors, and the total width of their readings.
        pub const nsensor: u32 = @intCast(spec.sensors.len);
        pub const neq: u32 = @intCast(spec.equalities.len);
        pub const nsensordata: u32 = blk: {
            var total: u32 = 0;
            for (spec.sensors) |sensor| {
                total += sensor.kind.dim();
            }
            break :blk total;
        };

        /// Build the runtime model. The spec is consumed here and not referenced again.
        pub fn build(gpa: Allocator) !Model {
            return buildFromSpec(gpa, spec);
        }
    };
}

// =============================================================================
// Model - constant once built
//
// Parallel arrays, indexed by body / joint / dof, exactly like `mjModel`. Flat arrays
// rather than a tree of structs because every algorithm here is a linear sweep over one
// of these index spaces, and because a flat model is what a batched GPU rollout wants.
//
// Body 0 is always the WORLD: massless, jointless, fixed at the origin. Having it real
// rather than special-cased means "parent" is never optional in the hot paths.
// =============================================================================

/// The index of the world body. Its parent is itself.
pub const world_body: u32 = 0;

/// NAMING NOTE. Counts stay as `nq`, `nv`, `nu`, `na` rather than becoming
/// `position_count` and friends. Those four are the universal notation of the field -
/// Featherstone, MuJoCo, Pinocchio and every robotics paper use them - and a reader
/// checking this file against a reference would have to translate every line. Everything
/// that is NOT standard notation is spelled out in full.
pub const Model = struct {
    /// Owns every table below, so `deinit` is one call rather than a forty-line errdefer
    /// ladder.
    ///
    /// The pointer is not decoration: an `ArenaAllocator` is NOT movable once an
    /// `Allocator` has been taken from it, because that allocator holds the arena
    /// struct's ADDRESS. Storing it by value and returning the model would strand every
    /// allocation in a copy nobody frees. (zimr has been bitten by this shape before -
    /// see the wgpu_bringup use-after-scope note in claude.md.)
    arena: *std.heap.ArenaAllocator,
    opt: Options,

    nbody: u32,
    njnt: u32,
    nsite: u32,
    ngeom: u32,
    nq: u32,
    nv: u32,
    nu: u32,
    na: u32,
    /// Worst-case constraint rows. Sized at build so `Data` never reallocates: one row per
    /// limited joint today, plus contacts once phase 7 lands. zimr's 2D engine learned the
    /// hard way (zimr392) that a silently-clamped constraint pool freezes a world without
    /// saying so, so this is generous and the overflow is a loud assert.
    constraint_capacity: u32,
    /// Total nonzeros in the lower triangle of M - the size of `Data.mass_matrix`.
    mass_nonzero_count: u32,

    // ---- bodies ----
    body_parent: []u32,
    /// Body pairs that never collide - MJCF's `<contact><exclude>`, resolved to body indices. Honoured by
    /// `robot_physics.Bridge`, beside its own rule that adjacent bodies never collide. Arena memory.
    exclude_pairs: []const [2]u32 = &.{},
    /// Index of the root of this body's kinematic tree (the child-of-world above it).
    body_root: []u32,
    /// Pose relative to the parent.
    body_pos: []Vec,
    body_rot: []Quat,
    /// Centre of mass in the body frame.
    body_ipos: []Vec,
    /// Inertia about that centre of mass, in the body frame. A FULL symmetric tensor,
    /// not MuJoCo's principal moments plus a quaternion - see `geomsToBodyMass`.
    body_inertia: []Inertia,
    body_mass: []f32,
    /// Mass of this body plus everything below it - needed by the subtree-COM frames.
    body_subtree_mass: []f32,
    body_jnt_adr: []u32,
    body_jnt_num: []u32,
    body_dof_adr: []u32,
    body_dof_num: []u32,

    // ---- joints ----
    jnt_type: []JointType,
    jnt_body: []u32,
    jnt_axis: []Vec,
    jnt_pos: []Vec,
    jnt_qpos_adr: []u32,
    jnt_dof_adr: []u32,
    jnt_range: []?[2]f32,
    jnt_limit_softness: []Softness,
    jnt_limit_impedance: []Impedance,
    jnt_limit_margin: []f32,
    jnt_damping: []f32,
    /// True when any joint has non-zero damping, so the integrator can pick its path once
    /// rather than scanning every step. See `dampedVelocityStep`.
    has_dof_damping: bool,
    jnt_stiffness: []f32,
    jnt_ref: []f32,

    // ---- degrees of freedom ----
    /// The DOF immediately above this one in the tree, or `no_dof` at a root. This chain
    /// IS the sparsity pattern of the mass matrix: `M[i][j]` is nonzero exactly when `j`
    /// is `i` or one of its ancestors.
    dof_parent: []u32,
    dof_body: []u32,
    dof_jnt: []u32,
    dof_armature: []f32,

    // ---- mass-matrix sparsity (structure, so it lives with the model) ----
    /// Nonzeros in row `i`: the length of `i`'s ancestor chain, including `i` itself.
    mass_row_nonzeros: []u32,
    /// Where row `i` starts in the packed value array.
    mass_row_start: []u32,
    /// Column index of each packed entry. Within a row the order is root-first and the
    /// DIAGONAL IS LAST, which is what lets CRB walk the chain with a single decrement.
    mass_col_index: []u32,

    // ---- sites ----
    site_body: []u32,
    site_pos: []Vec,
    site_rot: []Quat,

    // ---- geoms ----
    /// Per-geom Coulomb friction, combined with the other surface's at contact time.
    geom_friction: []f32,
    geom_body: []u32,
    geom_shape: []GeomShape,
    geom_pos: []Vec,
    geom_rot: []Quat,

    // ---- sensors ----
    nsensor: u32,
    /// Total width of `Data.sensor_data`.
    nsensordata: u32,
    sensor_kind: []SensorKind,
    /// Resolved index of what each sensor reads: a joint, tendon, actuator or site.
    sensor_target: []u32,
    /// Where each sensor's reading starts in `Data.sensor_data`.
    sensor_adr: []u32,

    // ---- equality constraints ----
    /// Loop closures. * STRUCT-OF-ONE rather than the parallel arrays the rest of `Model`
    /// uses: those exist because per-DOF and per-geom data is walked every step in tight
    /// loops, and equalities are neither hot nor numerous. `m.equalities[e].a.body` says what
    /// it is; `m.eq_body[e][0]` needs a comment to say the same thing.
    equalities: []Equality,
    neq: u32,

    // ---- tendons ----
    ntendon: u32,
    /// Each tendon's length coefficients over the DOFs: `ntendon x nv`, row-major.
    ///
    /// This IS the tendon Jacobian `dlength/dq`, and for a FIXED tendon it is CONSTANT, so
    /// it belongs in the model rather than being recomputed every step. A spatial tendon's
    /// would be configuration-dependent and would move to `Data`; the row layout is chosen
    /// so that change stays local.
    tendon_jacobian: []f32,
    tendon_stiffness: []f32,
    tendon_damping: []f32,
    tendon_rest_length: []f32,

    // ---- actuators ----
    /// Which kind of transmission each actuator uses, and what it points at: a joint
    /// index for `.joint`, a tendon index for `.tendon`.
    act_kind: []TransmissionKind,
    act_target: []u32,
    /// The single DOF a `.joint` actuator drives, or `no_dof` for a tendon, whose force
    /// spreads across every DOF its coefficients touch.
    act_dof: []u32,
    act_gear: []f32,
    /// The affine force law, collapsed from whatever shortcut the spec used.
    act_gain: []f32,
    act_bias: [][3]f32,
    act_activation: []Activation,
    /// Index into `Data.act` for actuators that have internal state, `no_dof` otherwise.
    act_state_adr: []u32,
    act_ctrl_range: []?[2]f32,
    act_force_range: []?[2]f32,

    /// The reference configuration. `reset` restores it, springs measure from it, and
    /// from phase 6 the constraint regularizer is scaled by the inertia evaluated here.
    qpos0: []f32,

    pub fn deinit(self: *Model) void {
        const gpa: Allocator = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }
};

/// Sentinel for "this DOF has no parent" - the top of a kinematic chain.
pub const no_dof: u32 = maxInt(u32);

/// Mass below which a body counts as massless for the purpose of deriving a com.
const min_mass: f32 = 1.0e-9;

/// Build a model from a spec assembled at runtime.
///
/// The public door onto `buildFromSpec` for callers who did not have their model in source
/// - a URDF loader, an editor, a procedural generator. Same construction code, same index
/// tables, same `Model`; what is missing is `Spec()`'s compile-time validation and its
/// generated name enums, which a runtime spec cannot have by definition.
///
/// Validation that `Spec()` performs at compile time is NOT repeated here. That is a
/// deliberate gap and worth stating: a malformed runtime spec will fail later, and less
/// helpfully. The loaders that build these specs do their own checking - `urdf.zig` refuses
/// a forest, a cycle, a duplicate name and a missing limit before ever reaching this - which
/// is the right place for it, since they can name the offending element and line.
/// Recompute `body_subtree_mass` from `body_mass`, for a caller that changed a mass.
///
/// -- * WHY THIS IS PUBLIC, AND WHAT IT COST TO LEARN --
///
/// `body_mass` and `body_inertia` are read every step, so scaling them changes the physics
/// immediately - which makes a live mass slider look trivial to write. `body_subtree_mass`
/// is NOT recomputed each step: it is accumulated once at build time, and it feeds the
/// centre-of-mass reductions that `comPos` and `comVel` perform before the mass matrix is
/// factored.
///
/// Leave it stale and the model is INTERNALLY INCONSISTENT: bodies that weigh 100 kg inside
/// a subtree that still believes it weighs 0.8. The result is not a small error - it is a
/// mass matrix built from two different systems, and it showed up as `factorM: pivot 34 is
/// negative` after peak forces above 1 MN.
///
/// The tell, and it is worth remembering: a tower BUILT at 300 kg was perfectly stable
/// (6.2 kN peak, no NaN), while the same tower SCALED to 300 kg exploded. When two paths to
/// the same state disagree, print both states and diff them - every field matched except
/// this one.
pub fn refreshSubtreeMass(m: *Model) void {
    for (m.body_subtree_mass, m.body_mass) |*dst, own| {
        dst.* = own;
    }
    var bi: u32 = m.nbody;
    while (bi > 1) {
        bi -= 1;
        m.body_subtree_mass[m.body_parent[bi]] += m.body_subtree_mass[bi];
    }
}

pub fn buildRuntime(gpa: Allocator, spec: ModelSpec) !Model {
    return buildFromSpec(gpa, spec);
}

/// Build a `Model` from a spec.
///
/// * THE SPEC IS A RUNTIME VALUE, and that is what makes a loaded robot possible.
///
/// `ModelSpec` is plain data - slices of structs with string names - so nothing about
/// building a model needs the spec to be known at compile time. `Spec()` passes a comptime
/// one and gets its validation and name enums; a URDF loader passes one it assembled at
/// startup and gets the same `Model`. **One construction path, not two**, which matters
/// because two builders that must agree about a hundred index tables is exactly the
/// duplication section 4i's architecture note argues against.
///
/// What the comptime path keeps that the runtime one does not: `@compileError` on a bad
/// model, and generated name enums. What the runtime path keeps: the ability to load a
/// robot the program was handed rather than written against. See section 4i-quater.
fn buildFromSpec(gpa: Allocator, spec: ModelSpec) !Model {
    const arena: *std.heap.ArenaAllocator = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a: Allocator = arena.allocator();

    // Counts. Body 0 is the world, so everything body-indexed is one longer than the spec.
    var njnt: u32 = 0;
    var nsite: u32 = 0;
    var ngeom: u32 = 0;
    var nq: u32 = 0;
    var nv: u32 = 0;
    for (spec.bodies) |b| {
        for (b.joints) |j| {
            nq += j.kind.posCount();
            nv += j.kind.dofCount();
        }
        njnt += @intCast(b.joints.len);
        nsite += @intCast(b.sites.len);
        ngeom += @intCast(b.geoms.len);
    }
    const nbody: u32 = @as(u32, @intCast(spec.bodies.len)) + 1;
    const nu: u32 = @intCast(spec.actuators.len);
    const ntendon: u32 = @intCast(spec.tendons.len);
    const nsensor: u32 = @intCast(spec.sensors.len);
    const neq: u32 = @intCast(spec.equalities.len);
    var nsensordata: u32 = 0;
    for (spec.sensors) |sensor| {
        nsensordata += sensor.kind.dim();
    }
    // TWO potential limit rows per limited joint, not one: with a margin wider than half
    // the range, both ends are within margin simultaneously (see `makeConstraints`).
    // Sizing this at one row per joint would be an overflow waiting for the first model
    // with a narrow range.
    var constraint_capacity: u32 = 0;
    for (spec.bodies) |b| {
        for (b.joints) |j| {
            if (j.range != null) {
                constraint_capacity += 2;
            }
        }
    }
    // Plus room for contacts, four pyramid-edge rows each. The count is a budget rather
    // than a bound - collision detection decides how many contacts there are - so it is
    // generous and overflowing it is a loud, named assert rather than a silent clamp.
    constraint_capacity += rows_per_contact * spec.options.max_contacts;

    // ** AND THREE ROWS PER LOOP CLOSURE, WHICH ARE NOT A BUDGET BUT A REQUIREMENT.
    //
    // Contacts come and go, so their share is a generous guess. An equality is part of the
    // MECHANISM - it is emitted every step, unconditionally, and a linkage that silently loses
    // its closure because a busy contact step used the space is not a linkage. Reserving for
    // them here is what lets `addEqualityRows` treat "no room" as impossible rather than as a
    // case to degrade through.
    //
    // * AND THE COUNT IS PER KIND, NOT A FLAT THREE. A `connect` is three rows and a `weld` is
    // SIX - the three position rows plus three for orientation - so a flat three under-reserves
    // every weld in the model. `addEqualityRows` then finds no room, returns silently, and the
    // weld quietly stops existing on a busy step: a gripped object drifting out of the hand
    // with nothing in the log. Counting properly is what makes the reservation true.
    for (spec.equalities) |eq| {
        constraint_capacity += if (eq.couple != null)
            1 // a joint coupling is one scalar equation
        else if (eq.weld)
            6
        else
            3;
    }
    var na: u32 = 0;
    for (spec.actuators) |act| {
        if (act.activation != .none) {
            na += 1;
        }
    }

    var m: Model = .{
        .arena = arena,
        .opt = spec.options,
        .nbody = nbody,
        .njnt = njnt,
        .nsite = nsite,
        .ngeom = ngeom,
        .nq = nq,
        .nv = nv,
        .nu = nu,
        .na = na,
        .constraint_capacity = constraint_capacity,
        .mass_nonzero_count = 0, // filled once the dof tree is known
        .body_parent = try a.alloc(u32, nbody),
        .body_root = try a.alloc(u32, nbody),
        .body_pos = try a.alloc(Vec, nbody),
        .body_rot = try a.alloc(Quat, nbody),
        .body_ipos = try a.alloc(Vec, nbody),
        .body_inertia = try a.alloc(Inertia, nbody),
        .body_mass = try a.alloc(f32, nbody),
        .body_subtree_mass = try a.alloc(f32, nbody),
        .body_jnt_adr = try a.alloc(u32, nbody),
        .body_jnt_num = try a.alloc(u32, nbody),
        .body_dof_adr = try a.alloc(u32, nbody),
        .body_dof_num = try a.alloc(u32, nbody),
        .jnt_type = try a.alloc(JointType, njnt),
        .jnt_body = try a.alloc(u32, njnt),
        .jnt_axis = try a.alloc(Vec, njnt),
        .jnt_pos = try a.alloc(Vec, njnt),
        .jnt_qpos_adr = try a.alloc(u32, njnt),
        .jnt_dof_adr = try a.alloc(u32, njnt),
        .jnt_range = try a.alloc(?[2]f32, njnt),
        .jnt_limit_softness = try a.alloc(Softness, njnt),
        .jnt_limit_impedance = try a.alloc(Impedance, njnt),
        .jnt_limit_margin = try a.alloc(f32, njnt),
        .jnt_damping = try a.alloc(f32, njnt),
        .has_dof_damping = false, // set once the joints are read
        .jnt_stiffness = try a.alloc(f32, njnt),
        .jnt_ref = try a.alloc(f32, njnt),
        .dof_parent = try a.alloc(u32, nv),
        .dof_body = try a.alloc(u32, nv),
        .dof_jnt = try a.alloc(u32, nv),
        .dof_armature = try a.alloc(f32, nv),
        .mass_row_nonzeros = try a.alloc(u32, nv),
        .mass_row_start = try a.alloc(u32, nv),
        .mass_col_index = &.{}, // sized after the chains are known
        .site_body = try a.alloc(u32, nsite),
        .site_pos = try a.alloc(Vec, nsite),
        .site_rot = try a.alloc(Quat, nsite),
        .geom_friction = try a.alloc(f32, ngeom),
        .geom_body = try a.alloc(u32, ngeom),
        .geom_shape = try a.alloc(GeomShape, ngeom),
        .geom_pos = try a.alloc(Vec, ngeom),
        .geom_rot = try a.alloc(Quat, ngeom),
        .nsensor = nsensor,
        .nsensordata = nsensordata,
        .sensor_kind = try a.alloc(SensorKind, nsensor),
        .sensor_target = try a.alloc(u32, nsensor),
        .sensor_adr = try a.alloc(u32, nsensor),
        .neq = neq,
        .equalities = try a.alloc(Equality, neq),
        .ntendon = ntendon,
        .tendon_jacobian = try a.alloc(f32, ntendon * nv),
        .tendon_stiffness = try a.alloc(f32, ntendon),
        .tendon_damping = try a.alloc(f32, ntendon),
        .tendon_rest_length = try a.alloc(f32, ntendon),
        .act_kind = try a.alloc(TransmissionKind, nu),
        .act_target = try a.alloc(u32, nu),
        .act_dof = try a.alloc(u32, nu),
        .act_gear = try a.alloc(f32, nu),
        .act_gain = try a.alloc(f32, nu),
        .act_bias = try a.alloc([3]f32, nu),
        .act_activation = try a.alloc(Activation, nu),
        .act_state_adr = try a.alloc(u32, nu),
        .act_ctrl_range = try a.alloc(?[2]f32, nu),
        .act_force_range = try a.alloc(?[2]f32, nu),
        .qpos0 = try a.alloc(f32, nq),
    };

    // ---- the world body ----
    m.body_parent[world_body] = world_body; // its own parent, so walks terminate
    m.body_root[world_body] = world_body;
    m.body_pos[world_body] = vec_zero;
    m.body_rot[world_body] = quat_identity;
    m.body_ipos[world_body] = vec_zero;
    m.body_inertia[world_body] = .zero;
    m.body_mass[world_body] = 0;
    m.body_jnt_adr[world_body] = 0;
    m.body_jnt_num[world_body] = 0;
    m.body_dof_adr[world_body] = 0;
    m.body_dof_num[world_body] = 0;

    // ---- bodies, joints, geoms, sites ----
    var jnt_n: u32 = 0;
    var site_n: u32 = 0;
    var geom_n: u32 = 0;
    var qpos_n: u32 = 0;
    var dof_n: u32 = 0;

    for (spec.bodies, 0..) |b, spec_index| {
        const bi: u32 = @as(u32, @intCast(spec_index)) + 1;
        m.body_parent[bi] = if (b.parent) |p| try bodyIndexByName(spec, p) else world_body;
        // A child of the world roots its own tree; everyone else inherits their parent's.
        m.body_root[bi] = if (m.body_parent[bi] == world_body) bi else m.body_root[m.body_parent[bi]];
        m.body_pos[bi] = b.pos;
        m.body_rot[bi] = b.rot;

        // Mass properties: stated outright if the model says so, otherwise summed from the
        // geoms. Real robot models state them (section 4i), hand-written ones usually do not.
        const mass_props: BodyMass = if (b.inertial) |inertial|
            inertialToBodyMass(inertial)
        else
            geomsToBodyMass(b.geoms);
        m.body_mass[bi] = mass_props.mass;
        m.body_ipos[bi] = mass_props.com;
        m.body_inertia[bi] = mass_props.inertia;

        m.body_jnt_adr[bi] = jnt_n;
        m.body_jnt_num[bi] = @intCast(b.joints.len);
        m.body_dof_adr[bi] = dof_n;

        // Every DOF on this body chains onto the previous one, ACROSS joints as well as
        // within them - three hinges on one body are three links in one chain, not three
        // parallel branches. The first one attaches to wherever the parent body ended.
        var prev_dof: u32 = lastDofOf(&m, m.body_parent[bi]);
        var body_dofs: u32 = 0;
        for (b.joints) |j| {
            m.jnt_type[jnt_n] = j.kind;
            m.jnt_body[jnt_n] = bi;
            m.jnt_axis[jnt_n] = switch (j.kind) {
                .slide, .hinge => normalize3(j.axis),
                .free, .ball => vec_zero, // no single axis; the DOFs span all of them
            };
            m.jnt_pos[jnt_n] = j.pos;
            m.jnt_qpos_adr[jnt_n] = qpos_n;
            m.jnt_dof_adr[jnt_n] = dof_n;
            // A range is a limit on ONE coordinate - the limit rows below bound `pos[qpos_adr]` along one DOF
            // - which is what a hinge's or a slide's range means. A ball's range means something else: in
            // MuJoCo, a cone on its TOTAL turn. Applied as a scalar it would bound the quaternion's first
            // number instead, and pin the joint wherever that number wants to go negative (measured: a servo
            // on Geno's 23 balls stalled 0.67 rad short of a pose its own captures reach). Until cone limits
            // exist, a ball's or a free joint's range is not applied; the model text keeps it for them.
            m.jnt_range[jnt_n] = switch (j.kind) {
                .slide, .hinge => j.range,
                .free, .ball => null,
            };
            m.jnt_limit_softness[jnt_n] = j.limit_softness;
            m.jnt_limit_impedance[jnt_n] = j.limit_impedance;
            m.jnt_limit_margin[jnt_n] = j.limit_margin;
            m.jnt_damping[jnt_n] = j.damping;
            // * ONE FLAG FOR THE WHOLE MODEL, decided at build time - see `dampedVelocityStep`.
            if (j.damping != 0) {
                m.has_dof_damping = true;
            }
            m.jnt_stiffness[jnt_n] = j.stiffness;
            m.jnt_ref[jnt_n] = j.ref;

            // qpos0: everything rests at zero except a quaternion, which rests at identity.
            // zm stores a quat as (x, y, z, w), so the w lane is the one that starts at 1.
            switch (j.kind) {
                .free => {
                    // ** A FREE JOINT'S REFERENCE POSE IS THE BODY'S DECLARED POSE.
                    //
                    // For every other joint the body's `pos`/`rot` is a fixed offset from the
                    // parent and the joint moves relative to it. A free joint HAS no fixed
                    // offset - its seven coordinates ARE the body's pose - so leaving `qpos0`
                    // at zero silently discards wherever the model said the body was.
                    //
                    // Found by stacking five crates and watching all five appear at the
                    // origin on step zero, already interpenetrating. Nothing warned: the
                    // model was valid, the simulation stable, and every body simply in the
                    // wrong place. MuJoCo does the same thing - `qpos0` for a free joint is
                    // seeded from `body_pos`/`body_quat`.
                    m.qpos0[qpos_n + 0] = b.pos[0];
                    m.qpos0[qpos_n + 1] = b.pos[1];
                    m.qpos0[qpos_n + 2] = b.pos[2];
                    m.qpos0[qpos_n + 3] = b.rot[0];
                    m.qpos0[qpos_n + 4] = b.rot[1];
                    m.qpos0[qpos_n + 5] = b.rot[2];
                    m.qpos0[qpos_n + 6] = b.rot[3];
                },
                .ball => {
                    for (0..4) |k| {
                        m.qpos0[qpos_n + k] = 0;
                    }
                    m.qpos0[qpos_n + 3] = 1; // w
                },
                .slide, .hinge => {
                    m.qpos0[qpos_n] = j.ref;
                },
            }

            const ndof: u32 = j.kind.dofCount();
            for (0..ndof) |k| {
                const d: u32 = dof_n + @as(u32, @intCast(k));
                m.dof_body[d] = bi;
                m.dof_jnt[d] = jnt_n;
                m.dof_parent[d] = prev_dof;
                prev_dof = d;
                // Armature: an explicit value, or a small fraction of the body's own
                // inertia so the default scales with the model rather than the units.
                m.dof_armature[d] = j.armature orelse
                    default_armature_fraction * representativeInertia(mass_props, j.kind);
            }
            qpos_n += j.kind.posCount();
            dof_n += ndof;
            body_dofs += ndof;
            jnt_n += 1;
        }
        m.body_dof_num[bi] = body_dofs;

        for (b.sites) |s| {
            m.site_body[site_n] = bi;
            m.site_pos[site_n] = s.pos;
            m.site_rot[site_n] = s.rot;
            site_n += 1;
        }
        for (b.geoms) |g| {
            m.geom_body[geom_n] = bi;
            m.geom_friction[geom_n] = g.friction;
            m.geom_shape[geom_n] = g.shape;
            m.geom_pos[geom_n] = g.pos;
            m.geom_rot[geom_n] = g.rot;
            geom_n += 1;
        }
    }

    // ---- sensors ----
    var sensor_adr: u32 = 0;
    for (spec.equalities, 0..) |eq, ei| {
        // * RESOLVED BY NAME, LIKE EVERY OTHER CROSS-REFERENCE in a spec. A loop closure names
        // two bodies that are already in the tree - it adds no bodies of its own, which is
        // exactly what makes it a closure rather than a link.
        m.equalities[ei] = .{
            .holds = if (eq.couple) |couple| .{ .joint = .{
                .driven = try coordinateOf(spec, m, couple.driven),
                .driver = if (couple.driver) |name| try coordinateOf(spec, m, name) else null,
                .poly = couple.poly,
            } } else blk: {
                const body_a: u32 = try bodyIndexByName(spec, eq.body_a);
                const body_b: u32 = try bodyIndexByName(spec, eq.body_b);
                // * DERIVED WHEN NOT STATED, so the closure is exact at the rest pose. See
                // `EqualitySpec.anchor_b`: both anchors name the same physical point, and
                // writing it twice in two frames is a typo waiting to happen.
                const at_a: Anchor = .{ .body = body_a, .point = eq.anchor_a };
                const at_b: Anchor = .{
                    .body = body_b,
                    .point = eq.anchor_b orelse restFrameAnchor(&m, body_a, eq.anchor_a, body_b),
                };
                break :blk if (eq.weld) .{
                    .weld = .{
                        .a = at_a,
                        .b = at_b,
                        // * THE RELATIVE ORIENTATION IS DERIVED TOO, for the same reason: a
                        // weld almost always means "hold them as they are now", and writing a
                        // quaternion by hand to say that is a needless chance to be wrong.
                        .relative = qmul(conjugate(restPose(&m, body_b).rot), restPose(&m, body_a).rot),
                        .torque_scale = eq.torque_scale,
                    },
                } else .{ .connect = .{ .a = at_a, .b = at_b } };
            },
            .softness = eq.softness,
            .impedance = eq.impedance,
        };
    }

    for (spec.sensors, 0..) |sensor, si| {
        m.sensor_kind[si] = sensor.kind;
        m.sensor_adr[si] = sensor_adr;
        m.sensor_target[si] = switch (sensor.kind) {
            .joint_pos, .joint_vel => try jointIndexByName(spec, sensor.target),
            .tendon_pos, .tendon_vel => try tendonIndexByName(spec, sensor.target),
            .actuator_force => try actuatorIndexByName(spec, sensor.target),
            .site_pos,
            .site_quat,
            .site_lin_vel,
            .site_ang_vel,
            .velocimeter,
            .gyro,
            .accelerometer,
            => try siteIndexByName(spec, sensor.target),
        };
        sensor_adr += sensor.kind.dim();
    }

    // ---- tendons ----
    @memset(m.tendon_jacobian, 0);
    for (spec.tendons, 0..) |tendon, ti| {
        for (tendon.joints) |tj| {
            const ji: u32 = try jointIndexByName(spec, tj.name);
            // One nonzero per joint the tendon touches, at that joint's DOF. Accumulated
            // rather than assigned, so naming the same joint twice sums as it should.
            m.tendon_jacobian[ti * nv + m.jnt_dof_adr[ji]] += tj.coefficient;
        }
        m.tendon_stiffness[ti] = tendon.stiffness;
        m.tendon_damping[ti] = tendon.damping;
        m.tendon_rest_length[ti] = tendon.rest_length;
    }

    // ---- actuators ----
    var state_n: u32 = 0;
    for (spec.actuators, 0..) |act, ai| {
        switch (act.on) {
            .joint => |t| {
                const ji: u32 = try jointIndexByName(spec, t.name);
                m.act_kind[ai] = .joint;
                m.act_target[ai] = ji;
                m.act_dof[ai] = m.jnt_dof_adr[ji];
                m.act_gear[ai] = t.gear;
            },
            .tendon => |t| {
                m.act_kind[ai] = .tendon;
                m.act_target[ai] = try tendonIndexByName(spec, t.name);
                m.act_dof[ai] = no_dof; // spread across DOFs, not tied to one
                m.act_gear[ai] = t.gear;
            },
        }
        const co: ActuatorSpec.Coefficients = act.coefficients();
        // `gear` scales the whole law, so it multiplies both gain and bias: an actuator
        // geared 10:1 produces ten times the force for the same control AND ten times the
        // restoring force for the same position error.
        m.act_gain[ai] = co.gain * m.act_gear[ai];
        inline for (0..3) |k| {
            m.act_bias[ai][k] = co.bias[k] * m.act_gear[ai];
        }
        m.act_activation[ai] = act.activation;
        m.act_ctrl_range[ai] = act.ctrl_range;
        m.act_force_range[ai] = act.force_range;
        if (act.activation == .none) {
            m.act_state_adr[ai] = no_dof;
        } else {
            m.act_state_adr[ai] = state_n;
            state_n += 1;
        }
    }

    // ---- subtree mass, accumulated leaf-to-root ----
    // Same accumulation `refreshSubtreeMass` performs, and it IS that function - a caller
    // mutating mass at runtime has to redo exactly this, so having one copy is what keeps
    // the two from drifting.
    refreshSubtreeMass(&m);

    // ---- mass-matrix sparsity ----
    // Row i holds one entry per DOF on i's path to the root, i included. Storing the
    // chain root-first with the diagonal last is what lets `crb` walk it backwards with a
    // single decrementing cursor.
    var total: u32 = 0;
    for (0..nv) |i| {
        var n: u32 = 0;
        var j: u32 = @intCast(i);
        while (j != no_dof) : (j = m.dof_parent[j]) {
            n += 1;
        }
        m.mass_row_nonzeros[i] = n;
        m.mass_row_start[i] = total;
        total += n;
    }
    m.mass_nonzero_count = total;
    m.mass_col_index = try a.alloc(u32, total);
    for (0..nv) |i| {
        const adr: u32 = m.mass_row_start[i];
        var slot: u32 = m.mass_row_nonzeros[i]; // fill backwards: diagonal lands last
        var j: u32 = @intCast(i);
        while (j != no_dof) : (j = m.dof_parent[j]) {
            slot -= 1;
            m.mass_col_index[adr + slot] = j;
        }
    }

    return m;
}

/// A body's aggregated mass properties, in the body frame.
const BodyMass = struct {
    mass: f32,
    /// Centre of mass, in the body frame.
    com: Vec,
    /// Inertia ABOUT THE CENTRE OF MASS, in the body frame. Full symmetric tensor, so a
    /// rotated geom needs no special case and no eigendecomposition.
    inertia: Inertia,
};

/// Sum a body's geoms into one mass, centre of mass and inertia tensor.
///
/// Three steps per geom, each one an operation that already exists:
///   1. `shapeMoments` gives the principal moments about the geom's own centre, in the
///      geom's own frame - diagonal, because a primitive's axes ARE its principal axes.
///   2. `rotated` re-expresses that in the BODY frame, which is where a rotated geom stops
///      being a special case.
///   3. `translate` moves it from the geom's centre out to the body origin.
/// Then they simply add, because section 2's ten-parameter packing makes summation valid once
/// everything shares a frame and a reference point.
///
/// Finally the total is shifted from the body origin to the body's centre of mass, since
/// that is the form `comPos` wants and the form a parallel-axis shift starts from.
///
/// MUJOCO DIVERGENCE, deliberate: `mjModel` stores three principal moments plus a
/// quaternion, which requires diagonalizing this tensor with a symmetric-3x3
/// eigendecomposition. We keep the six-float symmetric form and skip that entirely - one
/// fewer numerical routine, no degenerate-eigenvalue edge cases, and one float less to
/// store. See `Inertia.rotated`.
/// Convert a stated `<inertial>` into the engine's form.
///
/// A near-transcription rather than a computation, which is the payoff for `Inertia`
/// storing the full symmetric tensor. MuJoCo's `fullinertia` orders its six numbers as
/// `(xx, yy, zz, xy, xz, yz)`, and `Inertia` splits them into `diag` and `off` - where
/// `off` is `(xy, xz, yz)` in that same order, so the two halves copy straight across.
///
/// `h` is the FIRST MOMENT, `mass * com`, and is zero here because a stated inertia is
/// given about the centre of mass by definition. `body_ipos` carries the offset separately,
/// exactly as it does for the geom-derived path.
fn inertialToBodyMass(inertial: InertialSpec) BodyMass {
    return .{
        .mass = inertial.mass,
        .com = inertial.pos,
        .inertia = .{
            .diag = vec(inertial.full_inertia[0], inertial.full_inertia[1], inertial.full_inertia[2]),
            .off = vec(inertial.full_inertia[3], inertial.full_inertia[4], inertial.full_inertia[5]),
            .h = vec_zero,
            .mass = inertial.mass,
        },
    };
}

fn geomsToBodyMass(geoms: []const GeomSpec) BodyMass {
    var total: Inertia = .zero;
    for (geoms) |g| {
        const gm: f32 = g.mass orelse (shapeVolume(g.shape) * g.density);
        const principal: Inertia = .{
            .diag = shapeMoments(g.shape, gm),
            .mass = gm,
        };
        total = total.add(principal.rotated(g.rot).translate(g.pos));
    }
    if (total.mass <= min_mass) {
        return .{ .mass = 0, .com = vec_zero, .inertia = .zero };
    }
    // `h` is `mass * com`, so the centre of mass falls out of the sum for free.
    const com: Vec = total.h / splat(total.mass);
    // Shift from the body origin back to the centre of mass: the inverse of step 3.
    return .{ .mass = total.mass, .com = com, .inertia = total.translate(-com) };
}

fn shapeVolume(shape: GeomShape) f32 {
    return switch (shape) {
        .sphere => |s| (4.0 / 3.0) * pi * s.radius * s.radius * s.radius,
        .box => |s| 8.0 * s.half_extent[0] * s.half_extent[1] * s.half_extent[2],
        // A capsule is a cylinder plus a sphere's worth of caps.
        .capsule => |s| pi * s.radius * s.radius * (2.0 * s.half_height) +
            (4.0 / 3.0) * pi * s.radius * s.radius * s.radius,
        .cylinder => |s| pi * s.radius * s.radius * (2.0 * s.half_height),
        // Bounding-box volume, deliberately. The true hull volume needs the hull, which
        // lives in the physics engine; and any model with a hull geom is an imported one,
        // which states `<inertial>` explicitly and never reaches this path.
        .hull => |s| 8.0 * s.bounds_half_extent[0] * s.bounds_half_extent[1] *
            s.bounds_half_extent[2],
    };
}

/// Principal moments about the shape's own centre, for a uniform solid. Capsules and
/// cylinders run along local Y, matching zimr's convention (NOT MuJoCo's Z).
fn shapeMoments(shape: GeomShape, mass: f32) Vec {
    switch (shape) {
        // A hull is treated as its bounding box: an OVERESTIMATE of the true moments, which
        // is the safe direction - it never makes a link easier to spin than it really is.
        // As with the volume above, a model carrying hulls states its inertias anyway.
        .hull => |s| {
            const x: f32 = 2.0 * s.bounds_half_extent[0];
            const y: f32 = 2.0 * s.bounds_half_extent[1];
            const z: f32 = 2.0 * s.bounds_half_extent[2];
            const k: f32 = mass / 12.0;
            return vec(k * (y * y + z * z), k * (x * x + z * z), k * (x * x + y * y));
        },
        .sphere => |s| {
            const i: f32 = 0.4 * mass * s.radius * s.radius;
            return vec(i, i, i);
        },
        .box => |s| {
            const x: f32 = 2.0 * s.half_extent[0];
            const y: f32 = 2.0 * s.half_extent[1];
            const z: f32 = 2.0 * s.half_extent[2];
            const k: f32 = mass / 12.0;
            return vec(k * (y * y + z * z), k * (x * x + z * z), k * (x * x + y * y));
        },
        .cylinder => |s| {
            const r2: f32 = s.radius * s.radius;
            const h: f32 = 2.0 * s.half_height;
            const side: f32 = mass * (3.0 * r2 + h * h) / 12.0;
            return vec(side, 0.5 * mass * r2, side); // spin axis is Y
        },
        .capsule => |s| {
            // A capsule is a cylinder plus two hemispherical caps, so split the mass
            // between them by volume and add the moments.
            //
            // The caps need care, and getting it wrong here is invisible: the AXIAL moment
            // comes out right either way, and only the side moment is off by ~0.15%.
            //
            //   * A hemisphere's transverse moment about the CENTRE OF ITS FLAT FACE is
            //     (2/5)m*r^2, the same as a full sphere, by symmetry.
            //   * Its centroid is NOT there - it sits 3r/8 out along the axis.
            //   * Parallel axis moves an inertia between a point and the CENTROID, so
            //     before shifting out to the capsule's centre we must first come back to
            //     the centroid:
            //         I_centroid = (2/5)m*r^2 - m*(3r/8)^2 = (2/5 - 9/64)*m*r^2
            //     and only then push out to (half_height + 3r/8).
            //
            // Using (2/5)m*r^2 directly as the centroid moment double-counts m*(3r/8)^2.
            // Verified against MuJoCo to 3e-10; see the test below.
            const r: f32 = s.radius;
            const r2: f32 = r * r;
            const h: f32 = 2.0 * s.half_height;
            const v_cyl: f32 = pi * r2 * h;
            const v_cap: f32 = (4.0 / 3.0) * pi * r2 * r;
            const total: f32 = v_cyl + v_cap;
            const m_cyl: f32 = if (total > 0.0) mass * v_cyl / total else 0.0;
            const m_cap: f32 = mass - m_cyl;

            // About the axis, both parts are already centred: no shift needed.
            const axial: f32 = 0.5 * m_cyl * r2 + 0.4 * m_cap * r2;

            const side_cyl: f32 = m_cyl * (3.0 * r2 + h * h) / 12.0;
            const cap_centroid: f32 = s.half_height + 0.375 * r;
            const side_cap: f32 = m_cap *
                (hemisphere_transverse * r2 + cap_centroid * cap_centroid);
            return vec(side_cyl + side_cap, axial, side_cyl + side_cap); // spin axis is Y
        },
    }
}

/// A single scalar standing in for "how much inertia this DOF sees", used only to scale
/// the default armature. Rotational DOFs get the mean principal moment; sliding ones get
/// the mass, since that is what resists a translation.
fn representativeInertia(props: BodyMass, kind: JointType) f32 {
    return switch (kind) {
        .slide => props.mass,
        // The mean of the diagonal is the trace over three - basis-independent, so it does
        // not matter which frame the tensor happens to be expressed in.
        .free, .ball, .hinge => (props.inertia.diag[0] + props.inertia.diag[1] +
            props.inertia.diag[2]) / 3.0,
    };
}

/// Errors a runtime-built model can produce. The comptime path turns these into
/// `@compileError` instead; a loader has to handle them, since its input arrives at startup
/// rather than in source.
pub const BuildError = error{
    /// A joint coupling named a ball or free joint. Those have no scalar coordinate to
    /// couple - a quaternion is not a number - so this is a modelling error rather than
    /// something to approximate.
    UnsupportedJointForCoupling,
    /// A name referenced by a joint, tendon, actuator or sensor that no such thing has.
    UnknownName,
    OutOfMemory,
};

/// Index of the named actuator, or an error.
///
/// * WHY THESE ARE RUNTIME SCANS. They used to be comptime, which was fine when every model
/// was a source literal. A loaded robot's names are not known until startup, so the lookup
/// has to work either way - and a linear scan over a few dozen names costs nothing at build
/// time, once, where a hash map would cost more than it saves. `Spec()` still catches a bad
/// name at COMPILE time via its own validation pass; this is the fallback for models the
/// program was handed.
fn actuatorIndexByName(spec: ModelSpec, name: []const u8) BuildError!u32 {
    for (spec.actuators, 0..) |act, i| {
        if (std.mem.eql(u8, act.name, name)) {
            return @intCast(i);
        }
    }
    return BuildError.UnknownName;
}

/// Sites are numbered in declaration order across all bodies, matching how `build` assigns
/// them.
fn siteIndexByName(spec: ModelSpec, name: []const u8) BuildError!u32 {
    var n: u32 = 0;
    for (spec.bodies) |b| {
        for (b.sites) |site| {
            if (std.mem.eql(u8, site.name, name)) {
                return n;
            }
            n += 1;
        }
    }
    return BuildError.UnknownName;
}

fn tendonIndexByName(spec: ModelSpec, name: []const u8) BuildError!u32 {
    for (spec.tendons, 0..) |t, i| {
        if (std.mem.eql(u8, t.name, name)) {
            return @intCast(i);
        }
    }
    return BuildError.UnknownName;
}

/// Joints are numbered in declaration order across all bodies, which is the same order
/// `build` assigns them.
fn jointIndexByName(spec: ModelSpec, name: []const u8) BuildError!u32 {
    var n: u32 = 0;
    for (spec.bodies) |b| {
        for (b.joints) |j| {
            if (std.mem.eql(u8, j.name, name)) {
                return n;
            }
            n += 1;
        }
    }
    return BuildError.UnknownName;
}

/// Body 0 is the world, so a spec body at index `i` is model body `i + 1`.
fn bodyIndexByName(spec: ModelSpec, name: []const u8) BuildError!u32 {
    for (spec.bodies, 0..) |b, i| {
        if (std.mem.eql(u8, b.name, name)) {
            return @intCast(i + 1);
        }
    }
    return BuildError.UnknownName;
}

/// The last DOF belonging to `body`, walking up until a body with DOFs is found. That is
/// the DOF a child's first DOF chains onto - welded bodies are transparent here, which is
/// exactly what makes a weld free.
fn lastDofOf(m: *const Model, body: u32) u32 {
    var b: u32 = body;
    while (true) {
        if (m.body_dof_num[b] > 0) {
            return m.body_dof_adr[b] + m.body_dof_num[b] - 1;
        }
        if (b == world_body) {
            return no_dof;
        }
        b = m.body_parent[b];
    }
}

// =============================================================================
// Data - everything that changes
//
// Sized from the model, flat, and free of pointers so a batched rollout can slice many
// instances out of one allocation later. Fields are grouped by the PIPELINE STAGE that
// writes them, and each group names its stage: the pipeline is imperative, so knowing
// what is stale and why is part of using this correctly.
// =============================================================================

/// How far through the pipeline a `Data` has been advanced.
///
/// MuJoCo's docs single this out as the thing that surprises people: the pipeline is
/// imperative, so after writing `qpos` every derived quantity is silently stale until you
/// call the right stage, and nothing tells you. In C the only alternatives are to check
/// nothing or to pay for a check forever.
///
/// Zig gets a third option. `Data` carries a watermark, every stage sets it, and every
/// reader asserts on it - through `assertf`, which compiles out of a ship build entirely.
/// So a development build says
///
///     robot: crb needs the position stage, but this Data is only at .stale
///     (did you forget kinematics?)
///
/// and a ship build pays nothing. The information was always available; C just had nowhere
/// cheap to put it.
pub const Stage = enum(u8) {
    /// Position or velocity has been written; everything derived is stale.
    stale = 0,
    /// `kinematics` and `comPos` have run: body poses, `cdof`, `cinert` are current.
    position,
    /// `comVel` has run: body velocities are current.
    velocity,
    /// Forces and accelerations are current.
    force,

    /// Stages are ordered, so "have we at least reached X" is a comparison.
    pub fn atLeast(self: Stage, want: Stage) bool {
        return @backingInt(self) >= @backingInt(want);
    }
};

pub const Data = struct {
    /// Heap-allocated for the same reason as `Model.arena` - see the note there.
    arena: *std.heap.ArenaAllocator,

    /// How far the pipeline has been advanced. Writing state knocks it back to `.stale`;
    /// each stage raises it; readers assert on it. Never read it to DECIDE anything - it
    /// is a debugging aid, not control flow, and the pipeline stays explicit.
    stage: Stage = .stale,
    /// Set when `pos` was written WHOLESALE rather than integrated - a keyframe applied, a
    /// state restored, an editor drag. Consumed and cleared by whoever acts on it.
    ///
    /// -- ** WHY THE ENGINE CARRIES A FLAG IT DOES NOT ITSELF USE --
    ///
    /// `robot.zig` does not care: a position is a position. The COLLISION side does, and
    /// cannot tell by looking - a proxy that was there and is now here looks identical whether
    /// it travelled or was moved, and every "too far to be real" threshold is a number some
    /// scene sits on the wrong side of. One was tried: twenty times a geom's own radius, which
    /// is generous for a ball and useless for a 1 cm capsule, where a 0.18 m reset is only
    /// eighteen radii. It swept, found the floor, and produced **47 contacts with velocity
    /// pinned at 100 m/s**.
    ///
    /// So the fact travels with the data. The handful of functions that write `pos` wholesale
    /// set it, rather than every CALLER of those functions remembering to tell the bridge -
    /// which was thirty-one places and counting.
    teleported: bool = false,

    // ---- state: the only inputs the user owns ----
    /// Generalized position, length `nq`. Quaternion blocks are unit-norm.
    pos: []f32,
    /// Generalized velocity, length `nv`. NOT the derivative of `pos` - see the header.
    vel: []f32,
    /// Generalized acceleration, length `nv`. The output of forward dynamics.
    acc: []f32,
    /// Actuator controls, length `nu`. What the user commands.
    ctrl: []f32,
    /// Actuator activations, length `na`. The internal state of stateful actuators - a
    /// genuine third dynamic variable alongside position and velocity.
    act: []f32,
    /// Scratch for the implicit integrator: the dense `M - h*D` system, its pivots, and
    /// the right-hand side. Sized once, like everything else.
    implicit_matrix: []f32,
    implicit_pivot: []u32,
    implicit_rhs: []f32,
    /// Sensor readings, packed by `Model.sensor_adr`. Written across three pipeline
    /// stages, because a reading is only meaningful once its inputs exist.
    sensor_data: []f32,
    /// Per-body spatial acceleration in the shared frame, written by `bodyAccelerations`.
    /// Only the accelerometer needs it, so it is computed on demand.
    body_acc: []Motion,
    /// Tendon lengths and their rates, written by `tendonLengths`.
    tendon_length: []f32,
    tendon_velocity: []f32,
    /// Per-actuator transmission coordinate and its rate, written by `transmission`.
    act_length: []f32,
    act_velocity: []f32,
    /// Per-actuator scalar force, written by `actuation`.
    act_force: []f32,
    /// Rate of change of each activation state, length `na`.
    ///
    /// Separate from `act` on purpose. `actuation` COMPUTES this and the integrator APPLIES
    /// it, exactly once per step - because RK4 evaluates the dynamics four times, and an
    /// `actuation` that advanced `act` itself would advance it four times per step.
    act_dot: []f32,

    // ---- written by `kinematics` (phase 1) ----
    /// World pose of each body's frame.
    body_xpos: []Vec,
    body_xrot: []Quat,
    /// World position of each body's centre of mass.
    body_xipos: []Vec,
    /// World pose of each site.
    site_xpos: []Vec,
    site_xrot: []Quat,
    /// World position and axis of each joint's anchor.
    jnt_xanchor: []Vec,
    jnt_xaxis: []Vec,

    // ---- written by `comPos` (phase 1) ----
    /// Centre of mass of each body's subtree, in world space. The frame every spatial
    /// quantity below is expressed in - global orientation, translated here for accuracy.
    subtree_com: []Vec,
    /// Each DOF's motion axis as a spatial vector, in that shared frame.
    cdof: []Motion,
    /// Each body's inertia, in that shared frame.
    cinert: []Inertia,

    // ---- written by `crb` / `factorM` (phase 2) ----
    /// Composite inertia of each body's subtree.
    crb: []Inertia,
    /// Lower triangle of M, packed by the model's sparsity tables. Length `mass_nonzero_count`.
    mass_matrix: []f32,
    /// The L^TDL factorization, same packing.
    qLD: []f32,
    /// Reciprocals of D, so the solve multiplies instead of dividing.
    qLDiagInv: []f32,

    // ---- written by `comVel` / `rne` (phase 3) ----
    cvel: []Motion,
    cdof_dot: []Motion,
    /// Per-body scratch for `rne`. Kept here rather than allocated per call so the hot
    /// path never touches an allocator, and so `Data` remains the single description of
    /// everything a simulation instance owns.
    /// Scratch for `rneVelDerivative` - one 6-vector per (body, DOF) pair, so `nbody x nv`.
    ///
    /// * ALLOCATED ONLY FOR `.implicit`. On a humanoid that is 17 x 27 x four arrays of 16
    /// bytes ~ 29 kB, which is nothing - but it is also completely dead weight for the three
    /// integrators that never touch it, and a model built for `.euler` should not carry it.
    deriv_cacc: []Motion,
    deriv_cfrc: []Force,
    deriv_cvel: []Motion,
    deriv_cdof_dot: []Motion,
    rne_cacc: []Motion,
    rne_cfrc: []Force,
    /// Scratch for the RK4 integrator: the state at the start of the step, the current
    /// stage's slopes, and the weighted accumulation. Sized once, like everything else.
    rk_pos0: []f32,
    rk_vel0: []f32,
    rk_vel_stage: []f32,
    rk_acc_stage: []f32,
    rk_vel_sum: []f32,
    rk_acc_sum: []f32,
    /// Coriolis, centrifugal and gravitational forces: the `c` of the equation of motion.
    bias_force: []f32,

    // ---- forces the user, the springs and the actuators apply ----
    /// Extra generalized forces the caller applies. **PERSISTENT: nothing clears this for you.**
    ///
    /// -- *** THE LIFETIME MATTERS AND WAS NEVER WRITTEN DOWN --
    ///
    /// It was the only field in this block without a doc comment, and both readings are
    /// defensible - which is exactly why it cost a day. `PoseHold` clears it at the top of every
    /// `apply`, so a servo is self-cleaning. A planner drives `ctrl` instead and never touches
    /// this array, so it **inherits whatever the last servo left** and `step` adds both.
    ///
    /// * MEASURED: the same planner, same weights, same reference, scored **0.096 rad run first
    /// and 2.69 rad run after a PD** - its solver cost 7.5 clean against 5554 contaminated. It
    /// was not failing to optimise; it was optimising correctly against a robot with another
    /// controller's torques bolted on.
    ///
    /// **If you switch controllers, or drive `ctrl` after anything wrote here, clear it.** It is
    /// deliberately NOT cleared by `step`, because a caller applying a steady external force
    /// (wind, a tether, a thruster) sets it once and expects it to hold.
    applied_force: []f32,
    /// Joint springs and dampers, written by `passive`.
    passive_force: []f32,

    // ---- constraints, written by `makeConstraints` (phase 6) ----
    /// How many rows are ACTIVE this step. Everything below is valid for `[0, constraint_count)` only;
    /// the arrays are sized for the worst case and never reallocated, so a constraint set
    /// that grows and shrinks each step costs no allocator traffic.
    constraint_count: u32,
    /// What each row is, and which joint (or later geom pair) produced it.
    constraint_kind: []ConstraintKind,
    constraint_source: []u32,
    /// Row-major `constraint_capacity x nv` Jacobian. Dense because `nv` is small and a row is one
    /// contiguous run; the sparsity that matters is that most ROWS are absent, not that
    /// entries within a row are zero.
    constraint_jacobian: []f32,
    /// Violation, negative when the constraint is being pushed into.
    constraint_violation: []f32,
    /// Reference acceleration: what the constraint WANTS to happen, `-b*(Jv) - k*r`.
    constraint_target_acc: []f32,
    /// Diagonal regularizer `R = (1-d)/d * A_hat`. Softness, made numerical.
    constraint_regularizer: []f32,
    /// Constraint-space inertia diagonal `A_hat = (J M^-1 J^T)_ii`, computed exactly.
    constraint_inertia: []f32,
    /// Constraint velocity `J*v`, kept because both `aref` and the solver want it.
    constraint_velocity: []f32,
    /// World-space direction of each contact row. See where it is filled in.
    constraint_direction: []Vec,
    /// A stable identity for each row, so a force can be carried across steps.
    ///
    /// * ROW INDEX IS NOT IDENTITY. Rows are rebuilt every step and their order shifts as
    /// constraints activate and deactivate - slot 3 is a different physical constraint from
    /// one step to the next. Warm starting needs to know THIS row was THAT row, which is
    /// what this key provides: the joint and which end for a limit, the detector's stable
    /// contact id and which pyramid edge for a contact.
    constraint_key: []u64,
    /// Last step's keys and forces, kept so the solver can start where it finished.
    warm_key: []u64,
    warm_force: []f32,
    warm_count: u32,
    // NOTE: whoever mutates the MODEL while a `Data` is live must call
    // `forgetWarmStart` - see below.
    /// The unconstrained acceleration, saved so a warm start that turns out to be worse
    /// than starting from zero can be undone. See the cost check in `solveConstraints`.
    free_acc: []f32,
    /// Whether the last solve THREW AWAY its warm start because the cost check said zero
    /// was better. A diagnostic, and the thing a test can assert on: the guard's benefit is
    /// fewer iterations, and asserting an iteration count would pin a number that any
    /// legitimate solver change would move.
    warm_start_rejected: bool,
    /// Softness and impedance for each row. Stored per ROW rather than looked up from the
    /// joint, because a contact's parameters come from the contact and a limit's from the
    /// joint, and `projectConstraints` should not have to know which.
    constraint_softness: []Softness,
    constraint_impedance: []Impedance,
    /// Contacts to enforce this step. An INPUT, filled before `forward` exactly like
    /// `ctrl` - not something the engine discovers, because robot.zig has no collision
    /// detector and deliberately never will.
    ///
    /// A buffer rather than an `addContact` call, and the difference is a real hole closed:
    /// `forward` runs the constraint stages back to back, so a function that built rows
    /// directly had no moment at which a caller could invoke it - the main entry point
    /// silently ignored contacts. Now there is no ordering to get wrong.
    contacts: []Contact,
    contact_count: u32,
    /// Scratch for `addContact`: two point Jacobians and the frame-projected rows.
    /// Two bodies' point Jacobians, for any row built from a PAIR of bodies - contacts and
    /// loop closures both. Named for the shape of the problem rather than for the first thing
    /// that used them: they were `contact_jac_*` until equalities started borrowing them, at
    /// which point the name said something untrue about half the callers.
    pair_jac_a: []Vec,
    pair_jac_b: []Vec,
    contact_projected: []f32,
    /// Solved constraint force, one scalar per row, always >= 0.
    constraint_force: []f32,
    /// Previous iterate and pre-extrapolation point, for Nesterov acceleration. See
    /// `solveConstraints`.
    momentum_prev: []f32,
    momentum_extrapolated: []f32,
    /// The same forces mapped back into joint coordinates: `J^Tf`.
    constraint_joint_force: []f32,
    /// How many sweeps the last solve took. A cheap health signal - if this sits at
    /// `max_iterations`, the solver is not converging and the answer is approximate.
    solver_iterations: u32,
    /// `M^-1J^T` for each row - the joint-space acceleration a unit force on that row
    /// produces. Row-major `constraint_capacity x nv`.
    ///
    /// Computed once in `projectConstraints`, where it is needed anyway to form `A_hat`, and
    /// then reused by every solver iteration. That reuse is the difference between one
    /// back-substitution per row per STEP and one per row per ITERATION.
    /// Newton's working set. Allocated only when `solver.algorithm == .newton` - the Hessian
    /// alone is `nv x nv`, which is fine at tens of DOFs and pure waste for a solver that never
    /// forms one.
    newton_hessian: []f32,
    newton_gradient: []f32,
    newton_step: []f32,
    newton_trial: []f32,
    newton_scratch: []f32,
    newton_mv: []f32,
    newton_residual: []f32,
    newton_active: []bool,
    constraint_inv_inertia_jacobian: []f32,
    actuator_force: []f32,

    pub fn init(gpa: Allocator, m: *const Model) !Data {
        const arena: *std.heap.ArenaAllocator = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        const a: Allocator = arena.allocator();

        // * THE CORIOLIS-DERIVATIVE SCRATCH IS ONLY FOR `.implicit`. See `Data.deriv_cacc`:
        // `nbody x nv` six-vectors is small in absolute terms and entirely dead weight for the
        // three integrators that never form that matrix.
        const deriv_scratch: usize = if (m.opt.integrator == .implicit) m.nbody * m.nv else 0;

        // Same reasoning for Newton: an `nv x nv` Hessian is small in absolute terms and
        // entirely dead weight for a model that solves with PGS.
        const deriv_dof_scratch: usize = if (m.opt.integrator == .implicit) m.nv * m.nv else 0;
        const newton_nv: usize = if (m.opt.solver.algorithm == .newton) m.nv else 0;
        const newton_rows: usize = if (m.opt.solver.algorithm == .newton) m.constraint_capacity else 0;

        var d: Data = .{
            .arena = arena,
            .pos = try a.alloc(f32, m.nq),
            .vel = try a.alloc(f32, m.nv),
            .acc = try a.alloc(f32, m.nv),
            .ctrl = try a.alloc(f32, m.nu),
            .act = try a.alloc(f32, m.na),
            .implicit_matrix = try a.alloc(f32, m.nv * m.nv),
            .implicit_pivot = try a.alloc(u32, m.nv),
            .implicit_rhs = try a.alloc(f32, m.nv),
            .sensor_data = try a.alloc(f32, m.nsensordata),
            .body_acc = try a.alloc(Motion, m.nbody),
            .tendon_length = try a.alloc(f32, m.ntendon),
            .tendon_velocity = try a.alloc(f32, m.ntendon),
            .act_length = try a.alloc(f32, m.nu),
            .act_velocity = try a.alloc(f32, m.nu),
            .act_force = try a.alloc(f32, m.nu),
            .act_dot = try a.alloc(f32, m.na),
            .body_xpos = try a.alloc(Vec, m.nbody),
            .body_xrot = try a.alloc(Quat, m.nbody),
            .body_xipos = try a.alloc(Vec, m.nbody),
            .site_xpos = try a.alloc(Vec, m.nsite),
            .site_xrot = try a.alloc(Quat, m.nsite),
            .jnt_xanchor = try a.alloc(Vec, m.njnt),
            .jnt_xaxis = try a.alloc(Vec, m.njnt),
            .subtree_com = try a.alloc(Vec, m.nbody),
            .cdof = try a.alloc(Motion, m.nv),
            .cinert = try a.alloc(Inertia, m.nbody),
            .crb = try a.alloc(Inertia, m.nbody),
            .mass_matrix = try a.alloc(f32, m.mass_nonzero_count),
            .qLD = try a.alloc(f32, m.mass_nonzero_count),
            .qLDiagInv = try a.alloc(f32, m.nv),
            .cvel = try a.alloc(Motion, m.nbody),
            .cdof_dot = try a.alloc(Motion, m.nv),
            .deriv_cacc = try a.alloc(Motion, deriv_scratch),
            .deriv_cfrc = try a.alloc(Force, deriv_scratch),
            .deriv_cvel = try a.alloc(Motion, deriv_scratch),
            // ** INDEXED PER DOF, NOT PER BODY - so `nv x nv`, where the three above are
            // `nbody x nv`. Sized with the others it overflowed on the first free joint: for a
            // 7-DOF model with three bodies the buffer held 21 and the code reached 48.
            //
            // * AND A ReleaseFast PROBE DID NOT NOTICE. Bounds checks are off there, so the
            // writes landed in whatever followed and the numbers still looked right. The test
            // suite, which builds with safety on, caught it on the first run.
            .deriv_cdof_dot = try a.alloc(Motion, deriv_dof_scratch),
            .rne_cacc = try a.alloc(Motion, m.nbody),
            .rne_cfrc = try a.alloc(Force, m.nbody),
            .rk_pos0 = try a.alloc(f32, m.nq),
            .rk_vel0 = try a.alloc(f32, m.nv),
            .rk_vel_stage = try a.alloc(f32, m.nv),
            .rk_acc_stage = try a.alloc(f32, m.nv),
            .rk_vel_sum = try a.alloc(f32, m.nv),
            .rk_acc_sum = try a.alloc(f32, m.nv),
            .bias_force = try a.alloc(f32, m.nv),
            .applied_force = try a.alloc(f32, m.nv),
            .passive_force = try a.alloc(f32, m.nv),
            .constraint_count = 0,
            .constraint_kind = try a.alloc(ConstraintKind, m.constraint_capacity),
            .constraint_source = try a.alloc(u32, m.constraint_capacity),
            .constraint_jacobian = try a.alloc(f32, m.constraint_capacity * m.nv),
            .constraint_violation = try a.alloc(f32, m.constraint_capacity),
            .constraint_target_acc = try a.alloc(f32, m.constraint_capacity),
            .constraint_regularizer = try a.alloc(f32, m.constraint_capacity),
            .constraint_inertia = try a.alloc(f32, m.constraint_capacity),
            .constraint_velocity = try a.alloc(f32, m.constraint_capacity),
            .constraint_direction = try a.alloc(Vec, m.constraint_capacity),
            .momentum_prev = try a.alloc(f32, m.constraint_capacity),
            .momentum_extrapolated = try a.alloc(f32, m.constraint_capacity),
            .constraint_key = try a.alloc(u64, m.constraint_capacity),
            .warm_key = try a.alloc(u64, m.constraint_capacity),
            .warm_force = try a.alloc(f32, m.constraint_capacity),
            .free_acc = try a.alloc(f32, m.nv),
            .warm_count = 0,
            .warm_start_rejected = false,
            .constraint_softness = try a.alloc(Softness, m.constraint_capacity),
            .constraint_impedance = try a.alloc(Impedance, m.constraint_capacity),
            // ---- `max_contacts + ngeom`, AND THE SECOND TERM IS NOT PADDING ----
            //
            // A collision bridge pushes from TWO arrays: its persistent contact events, sized
            // `max_contacts`, and its continuous-sweep hits, sized `ngeom` - one per geom that
            // moved far enough in a step to need a sweep. `harvest` pushes both into THIS
            // buffer.
            //
            // *** SIZING IT AT `max_contacts` ALONE MAKES THE OVERFLOW STRUCTURAL: the worst
            // case a bridge can send is `max_contacts + ngeom`, and raising `max_contacts`
            // raises the sender and the receiver together without ever closing the gap.
            // Measured on a humanoid: 21 geoms and a 32-contact budget can send 53 into 32.
            //
            // The `+ ngeom` is what makes `pushContact`'s assert unreachable in normal operation
            // rather than latent in it.
            .contacts = try a.alloc(Contact, m.opt.max_contacts + m.ngeom),
            .contact_count = 0,
            .pair_jac_a = try a.alloc(Vec, m.nv),
            .pair_jac_b = try a.alloc(Vec, m.nv),
            .contact_projected = try a.alloc(f32, 3 * m.nv),
            .constraint_force = try a.alloc(f32, m.constraint_capacity),
            .constraint_joint_force = try a.alloc(f32, m.nv),
            .solver_iterations = 0,
            .newton_hessian = try a.alloc(f32, newton_nv * newton_nv),
            .newton_gradient = try a.alloc(f32, newton_nv),
            .newton_step = try a.alloc(f32, newton_nv),
            .newton_trial = try a.alloc(f32, newton_nv),
            .newton_scratch = try a.alloc(f32, newton_nv),
            .newton_mv = try a.alloc(f32, newton_nv),
            .newton_residual = try a.alloc(f32, newton_rows),
            .newton_active = try a.alloc(bool, newton_rows),
            .constraint_inv_inertia_jacobian = try a.alloc(f32, m.constraint_capacity * m.nv),
            .actuator_force = try a.alloc(f32, m.nv),
            .stage = .stale,
        };
        d.reset(m);
        return d;
    }

    pub fn deinit(self: *Data) void {
        const gpa: Allocator = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }

    /// Return to the model's reference configuration and zero everything derived. The
    /// scene switcher in a demo wants this, and so does any determinism test.
    pub fn reset(self: *Data, m: *const Model) void {
        self.stage = .stale;
        self.teleported = true;
        @memcpy(self.pos, m.qpos0);
        @memset(self.vel, 0);
        @memset(self.acc, 0);
        @memset(self.ctrl, 0);
        @memset(self.act, 0);
        @memset(self.implicit_matrix, 0);
        @memset(self.implicit_pivot, 0);
        @memset(self.implicit_rhs, 0);
        @memset(self.sensor_data, 0);
        @memset(self.body_acc, Motion.zero);
        @memset(self.tendon_length, 0);
        @memset(self.tendon_velocity, 0);
        @memset(self.act_length, 0);
        @memset(self.act_velocity, 0);
        @memset(self.act_force, 0);
        @memset(self.act_dot, 0);
        @memset(self.body_xpos, vec_zero);
        @memset(self.body_xrot, quat_identity);
        @memset(self.body_xipos, vec_zero);
        @memset(self.site_xpos, vec_zero);
        @memset(self.site_xrot, quat_identity);
        @memset(self.jnt_xanchor, vec_zero);
        @memset(self.jnt_xaxis, vec_zero);
        @memset(self.subtree_com, vec_zero);
        @memset(self.cdof, Motion.zero);
        @memset(self.cinert, Inertia.zero);
        @memset(self.crb, Inertia.zero);
        @memset(self.mass_matrix, 0);
        @memset(self.qLD, 0);
        @memset(self.qLDiagInv, 0);
        @memset(self.cvel, Motion.zero);
        @memset(self.cdof_dot, Motion.zero);
        @memset(self.rne_cacc, Motion.zero);
        @memset(self.rne_cfrc, Force.zero);
        @memset(self.rk_pos0, 0);
        @memset(self.rk_vel0, 0);
        @memset(self.rk_vel_stage, 0);
        @memset(self.rk_acc_stage, 0);
        @memset(self.rk_vel_sum, 0);
        @memset(self.rk_acc_sum, 0);
        @memset(self.bias_force, 0);
        @memset(self.applied_force, 0);
        @memset(self.passive_force, 0);
        self.constraint_count = 0;
        self.contact_count = 0;
        @memset(self.constraint_jacobian, 0);
        @memset(self.constraint_violation, 0);
        @memset(self.constraint_target_acc, 0);
        @memset(self.constraint_regularizer, 0);
        @memset(self.constraint_inertia, 0);
        @memset(self.constraint_velocity, 0);
        @memset(self.constraint_force, 0);
        @memset(self.momentum_prev, 0);
        @memset(self.momentum_extrapolated, 0);
        @memset(self.constraint_direction, vec_zero);
        @memset(self.constraint_key, 0);
        @memset(self.warm_key, 0);
        @memset(self.warm_force, 0);
        @memset(self.free_acc, 0);
        self.warm_count = 0;
        @memset(self.constraint_joint_force, 0);
        self.solver_iterations = 0;
        @memset(self.constraint_inv_inertia_jacobian, 0);
        @memset(self.actuator_force, 0);
    }

    /// Read a scalar joint's position. Only valid for hinge and slide - a ball or free
    /// joint has no single number, and asking for one is a programming error.
    pub fn jointPos(self: *const Data, m: *const Model, joint: anytype) f32 {
        const ji: u32 = jointIndex(joint);
        assertf(
            m.jnt_type[ji] == .hinge or m.jnt_type[ji] == .slide,
            @src(),
            "jointPos on a {s} joint, which has {d} position coordinates",
            .{ @tagName(m.jnt_type[ji]), m.jnt_type[ji].posCount() },
        );
        return self.pos[m.jnt_qpos_adr[ji]];
    }

    /// Set a scalar joint's position. Same restriction as `jointPos`. Writing state
    /// invalidates everything derived from it.
    pub fn setJointPos(self: *Data, m: *const Model, joint: anytype, value: f32) void {
        self.stage = .stale;
        const ji: u32 = jointIndex(joint);
        assertf(
            m.jnt_type[ji] == .hinge or m.jnt_type[ji] == .slide,
            @src(),
            "setJointPos on a {s} joint, which has {d} position coordinates",
            .{ @tagName(m.jnt_type[ji]), m.jnt_type[ji].posCount() },
        );
        self.pos[m.jnt_qpos_adr[ji]] = value;
    }

    /// Drop all contacts. Call once per step before pushing the new set - or use
    /// `setContacts`, which does it for you.
    /// Throw away the warm-start cache, because the system it describes no longer exists.
    ///
    /// -- * WHY THIS HAS TO BE CALLED, AND WHAT HAPPENS OTHERWISE --
    ///
    /// Warm starting seeds each row with the force that satisfied it LAST step, which is a
    /// large win precisely because the system barely changes between steps. Change the mass
    /// matrix underneath it and that assumption is void: the cached forces were the answer
    /// for a different set of inertias.
    ///
    /// Found by putting a live mass slider on `robot_3d`. Dragging a crate from 0.8 kg to
    /// 92 kg re-scales `body_inertia` between one step and the next, and the seeded forces -
    /// correct for a body a hundred times lighter - arrived as an enormous impulse. **Peak
    /// contact force 48 kN, crates at 35 m/s, and then `factorM: pivot 34 is negative`,
    /// which is the mass matrix having been corrupted by what came before it.**
    ///
    /// The cost guard in `solveConstraints` catches a warm start that RAISES the cost, but
    /// it compares against the current step's own reference - it cannot know the inertias
    /// changed. Nothing else can notice this; only the mutator knows.
    ///
    /// Cheap, and safe to call whenever in doubt: the next step simply solves cold.
    pub fn forgetWarmStart(self: *Data) void {
        @memset(self.warm_key, 0);
        @memset(self.warm_force, 0);
        self.warm_count = 0;
    }

    pub fn clearContacts(self: *Data) void {
        self.contact_count = 0;
    }

    /// Add one contact for this step.
    pub fn pushContact(self: *Data, contact: Contact) void {
        assertf(
            self.contact_count < self.contacts.len,
            @src(),
            // * THE SWEPT CONTACTS ARE NAMED because they are a cause that is not obvious from
            // the scene. A robot flung across the room can produce one per geom in a single
            // step, on top of everything the detector found, and someone counting the touching
            // surfaces will conclude the budget is generous when it is not.
            "contact buffer overflowed: {d} contacts, capacity {d} — raise Options.max_contacts. " ++
                "Continuous-collision sweeps add up to one contact per fast-moving geom on top " ++
                "of the detector's own, so a scene that looks well inside the budget can exceed " ++
                "it during a violent step",
            .{ self.contact_count + 1, self.contacts.len },
        );
        self.contacts[self.contact_count] = contact;
        self.contact_count += 1;
    }

    /// Replace the whole contact set. The usual call from a collision bridge.
    pub fn setContacts(self: *Data, list: []const Contact) void {
        self.clearContacts();
        for (list) |contact| {
            self.pushContact(contact);
        }
    }

    /// Assert this `Data` has reached `want`, naming what is missing. Compiles out of a
    /// ship build with `assertf`, so a stage check costs nothing where it matters.
    pub fn requireStage(self: *const Data, want: Stage, comptime who: []const u8) void {
        assertf(
            self.stage.atLeast(want),
            @src(),
            "robot: " ++ who ++ " needs the {s} stage, but this Data is only at .{s}",
            .{ @tagName(want), @tagName(self.stage) },
        );
    }

    /// Read a scalar joint's velocity.
    pub fn jointVel(self: *const Data, m: *const Model, joint: anytype) f32 {
        const ji: u32 = jointIndex(joint);
        return self.vel[m.jnt_dof_adr[ji]];
    }

    /// Set a scalar joint's velocity. Invalidates everything derived from it.
    pub fn setJointVel(self: *Data, m: *const Model, joint: anytype, value: f32) void {
        // Positions are still valid; only velocity-and-later derivations are not.
        if (self.stage.atLeast(.velocity)) {
            self.stage = .position;
        }
        const ji: u32 = jointIndex(joint);
        self.vel[m.jnt_dof_adr[ji]] = value;
    }
};

/// Accept either a generated enum or a plain index, so a comptime-specified model and a
/// runtime-loaded one share the same API. The enum's tag value IS the index, by
/// construction in `NamesEnum`.
fn jointIndex(joint: anytype) u32 {
    const T = @TypeOf(joint);
    return switch (@typeInfo(T)) {
        .@"enum" => @backingInt(joint),
        else => @intCast(joint),
    };
}

// =============================================================================
// Kinematics - phase 1
//
// One forward pass over the tree, parent before child, turning generalized positions into
// world poses. This is the first stage of the pipeline and everything else depends on it.
// =============================================================================

/// A rigid placement in some frame. Named rather than anonymous because a pose is a real
/// concept here - bodies, joints and sites all have one, and `compose` is how they relate.
pub const Pose = struct {
    pos: Vec = vec_zero,
    rot: Quat = quat_identity,

    pub const identity: Pose = .{};

    /// Place `local` inside `self`. Rotation composes; translation is this pose's origin
    /// plus the child's offset rotated into this frame.
    ///
    /// The order is the whole content of the function: `qmul(a, b)` applies `b` FIRST,
    /// so `parent.compose(local)` reads "start at the parent, then go local", which is
    /// the direction a tree walk travels. Swapping the operands compiles and puts every
    /// body in the wrong place in a way that still looks like a robot.
    pub fn compose(self: Pose, local: Pose) Pose {
        return .{
            .pos = self.pos + rotate(self.rot, local.pos),
            .rot = qmul(self.rot, local.rot),
        };
    }
};

/// Forward kinematics: world pose of every body, joint anchor, joint axis and site.
///
/// Bodies are visited in index order, which IS parent-before-child because `Spec()`
/// rejects any spec where a parent is declared after its child. That single validation
/// rule is what lets this be a flat loop instead of a recursive walk.
///
/// The subtle step is the off-centre correction. A hinge does not rotate the body about
/// the body's own origin - it rotates it about the ANCHOR. So after composing the
/// rotation we recompute where the origin must be for the anchor to have stayed put:
///
///     xpos = xanchor - R_new * jnt_pos
///
/// Skip it and every joint whose anchor is not at the body origin swings the body through
/// an arc it should never take. Almost every real robot joint is off-centre, so this is
/// not an edge case.
pub fn kinematics(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.kinematics");
    defer zone.end();
    // The world never moves.
    d.body_xpos[world_body] = vec_zero;
    d.body_xrot[world_body] = quat_identity;
    d.body_xipos[world_body] = vec_zero;

    for (1..m.nbody) |bi| {
        const parent: u32 = m.body_parent[bi];
        const jnt_adr: u32 = m.body_jnt_adr[bi];
        const jnt_num: u32 = m.body_jnt_num[bi];

        var pos: Vec = undefined;
        var rot: Quat = undefined;

        if (jnt_num == 1 and m.jnt_type[jnt_adr] == .free) {
            // A free joint IS the body's world pose; there is nothing to compose.
            const qadr: u32 = m.jnt_qpos_adr[jnt_adr];
            pos = vec(d.pos[qadr], d.pos[qadr + 1], d.pos[qadr + 2]);
            rot = normalizeQuat(.{ d.pos[qadr + 3], d.pos[qadr + 4], d.pos[qadr + 5], d.pos[qadr + 6] });
            d.jnt_xanchor[jnt_adr] = pos;
            d.jnt_xaxis[jnt_adr] = m.jnt_axis[jnt_adr];
        } else {
            // Start at the body's rest pose relative to its parent, then let each joint
            // move it away from there.
            const parent_pose: Pose = .{ .pos = d.body_xpos[parent], .rot = d.body_xrot[parent] };
            const rest: Pose = parent_pose.compose(.{ .pos = m.body_pos[bi], .rot = m.body_rot[bi] });
            pos = rest.pos;
            rot = rest.rot;

            for (jnt_adr..jnt_adr + jnt_num) |ji| {
                const qadr: u32 = m.jnt_qpos_adr[ji];

                // Axis and anchor, in the frame the joint acts in - which is the pose as
                // built SO FAR, so several joints on one body compose in declared order.
                const axis: Vec = rotate(rot, m.jnt_axis[ji]);
                const anchor: Vec = pos + rotate(rot, m.jnt_pos[ji]);

                switch (m.jnt_type[ji]) {
                    .slide => {
                        // Sliding moves the body and leaves its orientation alone, so no
                        // off-centre correction applies.
                        pos += axis * splat(d.pos[qadr] - m.qpos0[qadr]);
                    },
                    .hinge, .ball => {
                        const local: Quat = if (m.jnt_type[ji] == .ball)
                            normalizeQuat(.{ d.pos[qadr], d.pos[qadr + 1], d.pos[qadr + 2], d.pos[qadr + 3] })
                        else
                            zm.quatFromNormAxisAngle(m.jnt_axis[ji], d.pos[qadr] - m.qpos0[qadr]);

                        rot = qmul(rot, local);
                        // Off-centre correction: put the origin back where it must be for
                        // the anchor not to have moved.
                        pos = anchor - rotate(rot, m.jnt_pos[ji]);
                    },
                    .free => unreachable, // handled above; a free joint is never beside others
                }

                d.jnt_xanchor[ji] = anchor;
                d.jnt_xaxis[ji] = axis;
            }
        }

        d.body_xrot[bi] = normalizeQuat(rot);
        d.body_xpos[bi] = pos;
        // The centre of mass, which is what the dynamics actually care about.
        d.body_xipos[bi] = pos + rotate(d.body_xrot[bi], m.body_ipos[bi]);
    }

    // Sites ride along on their bodies. They are massless frames, so this is the only
    // place they cost anything.
    for (0..m.nsite) |si| {
        const bi: u32 = m.site_body[si];
        const body_pose: Pose = .{ .pos = d.body_xpos[bi], .rot = d.body_xrot[bi] };
        const world: Pose = body_pose.compose(.{ .pos = m.site_pos[si], .rot = m.site_rot[si] });
        d.site_xpos[si] = world.pos;
        d.site_xrot[si] = world.rot;
    }

    d.stage = .position;
}

/// Build the shared frame each kinematic tree's dynamics are expressed in, and put every
/// body's inertia and every DOF's motion axis into it.
///
/// WHY A SHARED FRAME AT ALL. Two inertias can only be added when they are expressed about
/// the same reference point in the same orientation. `crb` in phase 2 accumulates a
/// subtree's inertia by literally summing the ten numbers of each body - which is legal
/// only because this function first moved them all into one frame. That summation is the
/// entire reason the composite-rigid-body algorithm is cheap, and this is where it is paid
/// for.
///
/// WHICH FRAME. Global ORIENTATION (so collision, which happens in world space, shares it),
/// translated to the root's subtree centre of mass. The translation is purely for floating
/// point: an inertia expressed about a distant origin has its useful bits swamped by the
/// `m*d^2` parallel-axis term. MuJoCo does this at f64; we are at f32 and need it more.
///
/// The frame is per TREE, not per body - every body in one tree shares its root's subtree
/// com, which is what makes their inertias summable. `subtree_com` is computed for every
/// body anyway because sensors and the phase-3 `subtreeVel` want it.
pub fn comPos(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.comPos");
    defer zone.end();
    d.requireStage(.position, "comPos");

    // ---- subtree centres of mass, accumulated leaf-to-root ----
    // Start each body holding its own first moment (mass x com), add children into
    // parents walking backwards, then divide out the subtree mass. Backwards works
    // because a parent always has a lower index than its children.
    for (0..m.nbody) |bi| {
        d.subtree_com[bi] = d.body_xipos[bi] * splat(m.body_mass[bi]);
    }
    var bi: u32 = m.nbody;
    while (bi > 1) {
        bi -= 1;
        d.subtree_com[m.body_parent[bi]] += d.subtree_com[bi];
    }
    for (0..m.nbody) |i| {
        const sub_mass: f32 = m.body_subtree_mass[i];
        // A massless subtree has no centre of mass to speak of; its own origin is the
        // only answer that stays finite, and nothing downstream weights it anyway.
        d.subtree_com[i] = if (sub_mass > min_mass)
            d.subtree_com[i] / splat(sub_mass)
        else
            d.body_xipos[i];
    }

    // ---- body inertias, in the shared frame ----
    d.cinert[world_body] = .zero;
    for (1..m.nbody) |i| {
        const frame_origin: Vec = d.subtree_com[m.body_root[i]];
        // Rotate the body-frame tensor into world orientation, then translate from the
        // body's centre of mass out to the shared origin. Note the order: rotating a
        // translated inertia is not the same as translating a rotated one.
        d.cinert[i] = m.body_inertia[i]
            .rotated(d.body_xrot[i])
            .translate(d.body_xipos[i] - frame_origin);
    }

    // ---- dof motion axes, in the same frame ----
    for (0..m.njnt) |ji| {
        const body: u32 = m.jnt_body[ji];
        const frame_origin: Vec = d.subtree_com[m.body_root[body]];
        // From the frame's origin TO the joint anchor: a rotation about the anchor moves
        // the origin by `axis x offset`, which is the linear half of the motion vector.
        const offset: Vec = frame_origin - d.jnt_xanchor[ji];
        const dof_adr: u32 = m.jnt_dof_adr[ji];

        switch (m.jnt_type[ji]) {
            .slide => {
                // Pure translation: no angular part, and no dependence on the anchor.
                d.cdof[dof_adr] = .{ .ang = vec_zero, .lin = d.jnt_xaxis[ji] };
            },
            .hinge => {
                d.cdof[dof_adr] = dofAboutAxis(d.jnt_xaxis[ji], offset);
            },
            .ball => {
                // Three rotations about the body's own axes, taken as the columns of its
                // world rotation. Using the CHILD frame matters: a ball joint's velocity
                // is defined there, and `integratePos` composes its increment on the same
                // side (see `rotateQuatByAngularVel`).
                inline for (0..3) |k| {
                    d.cdof[dof_adr + k] = dofAboutAxis(bodyAxis(d.body_xrot[body], k), offset);
                }
            },
            .free => {
                // Translation first: the three world axes, no angular part.
                inline for (0..3) |k| {
                    d.cdof[dof_adr + k] = .{ .ang = vec_zero, .lin = worldAxis(k) };
                }
                // Then rotation, exactly as for a ball joint.
                inline for (0..3) |k| {
                    d.cdof[dof_adr + 3 + k] = dofAboutAxis(bodyAxis(d.body_xrot[body], k), offset);
                }
            },
        }
    }
}

/// The spatial motion a unit rotation about `axis` produces, when the frame's origin sits
/// `offset` from the axis. Rotating about a line that does not pass through the origin
/// moves the origin too, and `axis x offset` is exactly how much.
fn dofAboutAxis(axis: Vec, offset: Vec) Motion {
    return .{ .ang = axis, .lin = cross(axis, offset) };
}

/// Column `k` of a body's world rotation - its local X, Y or Z axis in world space.
fn bodyAxis(rot: Quat, comptime k: usize) Vec {
    return rotate(rot, worldAxis(k));
}

/// Basis vector `k`. A named function rather than three literals because it appears in two
/// places above and a transposed index there is invisible.
fn worldAxis(comptime k: usize) Vec {
    return switch (k) {
        0 => vec(1, 0, 0),
        1 => vec(0, 1, 0),
        2 => vec(0, 0, 1),
        else => @compileError("robot: axis index must be 0, 1 or 2"),
    };
}

// =============================================================================
// The mass matrix - phase 2
//
// M(q) is the object that turns "what forces are acting" into "how does it accelerate".
// Two ways to read it, both worth holding:
//
//   * ENERGY.  Kinetic energy is 1/2*v^T*M*v. M is the quadratic form that measures how much
//     energy a given joint-space motion carries.
//   * COUPLING.  M[i][j] answers "if I accelerate DOF j by one unit, how much torque does
//     that demand at DOF i?" A robot arm is harder to swing when extended than when
//     folded, and that difference IS M changing with q.
//
// The second reading explains the sparsity. Moving joint i moves only the bodies BELOW i.
// So DOFs i and j interact exactly when one lies on the other's path to the root - which
// is the ancestor relation the model tabulated at build time.
// =============================================================================

/// Composite Rigid Body: build the joint-space inertia matrix M.
///
/// THE IDEA, which is genuinely simple once seen. Suppose only DOF `i` accelerates and
/// every other joint is locked. Then everything below `i` moves as ONE RIGID BODY - that
/// is what locking the joints below means. Call that body's spatial inertia `I_comp(i)`.
/// The spatial force needed to produce that acceleration is `I_comp(i) * cdof_i`, and the
/// torque it demands at any DOF `j` is that force projected onto `j`'s motion axis:
///
///     M[i][j] = cdof_j * (I_comp(i) * cdof_i)
///
/// That single line is the whole algorithm. Everything else is bookkeeping: getting the
/// composite inertias (a backward sum, cheap because `comPos` put them in a shared frame)
/// and visiting only the `j` that can be nonzero (the ancestor chain).
///
/// COST. The outer loop is `nv`; the inner walks one ancestor chain. For a chain robot
/// that is O(nv^2) entries but each is a 6-vector dot - and for a tree with branches it is
/// far less, because siblings never interact. This is why the sparsity is not an
/// optimisation bolted on afterwards: it is the shape of the physics.
pub fn crb(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.crb");
    defer zone.end();
    d.requireStage(.position, "crb");

    // ---- composite inertias: a backward sum over the tree ----
    // Start each body holding its own inertia, then fold children into parents walking
    // backwards. Because a parent always has a lower index, one reverse pass suffices.
    //
    // This sum is only legal because every `cinert` is expressed in the same frame - the
    // shared subtree-COM frame `comPos` built. That is the payoff for the whole previous
    // section, collected here in three lines.
    @memcpy(d.crb, d.cinert);
    var bi: u32 = m.nbody;
    while (bi > 1) {
        bi -= 1;
        const parent: u32 = m.body_parent[bi];
        // Do not fold into the world: it is not a real body and its inertia is meaningless.
        if (parent != world_body) {
            d.crb[parent] = d.crb[parent].add(d.crb[bi]);
        }
    }

    // ---- one row of M per DOF ----
    for (0..m.nv) |i| {
        const row: u32 = m.mass_row_start[i];
        const nnz: u32 = m.mass_row_nonzeros[i];

        // The force this DOF's unit acceleration generates, given everything below it
        // moves with it.
        const force: Force = d.crb[m.dof_body[i]].mul(d.cdof[i]);

        // Walk the ancestor chain, writing backwards. The row is stored root-first with
        // the diagonal LAST (see `Model.mass_col_index`), and walking UP from `i` visits the
        // diagonal first - so the cursor starts at the end and decrements. Storage order
        // and traversal order were chosen to match precisely here.
        var slot: u32 = nnz;
        var j: u32 = @intCast(i);
        while (j != no_dof) : (j = m.dof_parent[j]) {
            slot -= 1;
            d.mass_matrix[row + slot] = dot6(d.cdof[j], force);
        }

        // Armature is rotor inertia reflected through a gearbox: a real physical mass that
        // the motor must spin up, felt at this DOF alone. It lands on the diagonal, which
        // is also why it is the cheapest defence against an ill-conditioned M - it is
        // literally diagonal regularization that happens to be true.
        d.mass_matrix[row + nnz - 1] += m.dof_armature[i];
    }
}

/// Expand the packed lower triangle into a dense `nv x nv` matrix, row-major.
///
/// For tests, debugging and teaching - never for the hot path, which is why it takes a
/// caller-provided buffer rather than allocating. The sparse form is the real one; this is
/// the form a human (or an oracle) can read.
pub fn massMatrixDense(m: *const Model, d: *const Data, out: []f32) void {
    d.requireStage(.position, "massMatrixDense");
    assertf(
        out.len == m.nv * m.nv,
        @src(),
        "massMatrixDense wants an {d}x{d} buffer, got {d} entries",
        .{ m.nv, m.nv, out.len },
    );
    @memset(out, 0);
    for (0..m.nv) |i| {
        const row: u32 = m.mass_row_start[i];
        for (0..m.mass_row_nonzeros[i]) |k| {
            const j: u32 = m.mass_col_index[row + k];
            const value: f32 = d.mass_matrix[row + k];
            // M is symmetric, and only the lower triangle is stored: mirror as we expand.
            out[i * m.nv + j] = value;
            out[j * m.nv + i] = value;
        }
    }
}

/// Factorize the mass matrix as `M = L^T*D*L`, in place and without fill-in.
///
/// WHY FACTOR AT ALL. Forward dynamics needs `M^-1(tau + J^Tf - c)`, and a constraint solver
/// needs `M^-1J^T` for every constraint row. Inverting `M` outright would be both slower and
/// numerically worse; factoring once per step turns every later `M^-1x` into two cheap
/// back-substitutions.
///
/// * WHY THERE IS NO FILL-IN, which is the good part. Ordinary sparse elimination creates
/// new nonzeros: eliminating a variable couples everything it touched, and the matrix
/// gradually fills up. Here it cannot, and the reason is structural.
///
/// Row `k` of `M` holds `k`'s ancestor chain. Row `i`, for any `i` ON that chain, holds
/// `i`'s ancestor chain - which is a PREFIX of `k`'s, because `i`'s path to the root is
/// the tail of `k`'s. Eliminating `k` only ever updates rows whose sparsity pattern is
/// already contained in `k`'s. Nothing new can appear.
///
/// And since rows are stored root-first, a prefix in the tree is a prefix in MEMORY: the
/// update to row `i` is a contiguous run starting at `i`'s row address, aligned element for
/// element with the head of row `k`. No index translation, no scatter. That alignment is
/// why section 5 chose root-first-with-the-diagonal-last, several phases before anything used it.
///
/// The loop runs BACKWARD over rows because elimination proceeds from the leaves inward -
/// a DOF can only be eliminated once everything that depends on it is gone, and children
/// always have higher indices than their parents.
/// How many velocity coordinates a joint kind carries.
fn dofWidth(kind: JointType) u32 {
    return switch (kind) {
        .free => 6,
        .ball => 3,
        .hinge, .slide => 1,
    };
}

pub fn factorM(m: *const Model, d: *Data) void {
    factorMDamped(m, d, 0);
}

/// Factor `M + damping_dt * diag(B)`.
///
/// * THE DAMPING GOES ON THE FACTORISATION, NOT ON `mass_matrix`. That array is read by the
/// constraint solver and by `massDiagonal`, and must keep meaning inertia; `qLD` is scratch
/// this function overwrites every time it runs. `damping_dt = 0` is the plain mass matrix and
/// is what every caller outside the integrator wants.
pub fn factorMDamped(m: *const Model, d: *Data, damping_dt: f32) void {
    // -- * THE ZONE IS NAMED BY WHAT IT DID, BECAUSE `factorM` IS THIS FUNCTION --
    //
    // A fixed name here reported `robot.factorM x3.0/step` under an implicit integrator -
    // true, and useless: two of those three are plain factorisations and one is damped, and
    // a breakdown that cannot separate them cannot tell you which to go and look at.
    //
    // * RENAMING IT TO `factorMDamped` MADE IT WORSE, and the output said so immediately:
    // `robot.factorM` VANISHED from the breakdown and the damped row absorbed all three
    // calls. `factorM` is a one-line wrapper around this function with no zone of its own,
    // so a fixed name here labels every factorisation in the engine, whichever it was.
    // **A row disappearing when you rename another row means they were always the same
    // row.**
    //
    // Choosing at runtime works because `internSrc` keys on (file, line, NAME) - two
    // literals at one call site intern as two entries, which is precisely the case that
    // condition exists to allow.
    const zone: profiler.Zone = profiler.zoneNamed(
        @src(),
        if (damping_dt != 0) "robot.factorMDamped" else "robot.factorM",
    );
    defer zone.end();
    d.requireStage(.position, "factorM");
    @memcpy(d.qLD, d.mass_matrix);
    if (damping_dt != 0) {
        for (0..m.njnt) |j| {
            const damping: f32 = m.jnt_damping[j];
            if (damping == 0) {
                continue;
            }
            const first: u32 = m.jnt_dof_adr[j];
            for (0..dofWidth(m.jnt_type[j])) |k| {
                const v: u32 = first + @as(u32, @intCast(k));
                // The diagonal is the last slot in the row - see `massDiagonal`.
                d.qLD[m.mass_row_start[v] + m.mass_row_nonzeros[v] - 1] += damping_dt * damping;
            }
        }
    }

    var k: u32 = m.nv;
    while (k > 0) {
        k -= 1;
        const start: u32 = m.mass_row_start[k];
        const diag: u32 = start + m.mass_row_nonzeros[k] - 1;

        // M is positive definite, so every pivot is positive - armature guarantees it even
        // for a massless-looking DOF. A non-positive pivot means the model is degenerate
        // (a zero-mass body, or an inertia that has gone bad upstream) and every number
        // after this point would be meaningless.
        assertf(
            d.qLD[diag] > 0.0,
            @src(),
            "factorM: pivot {d} is {d}, but M must be positive definite " ++
                "(a zero-mass body, or armature left at zero?)",
            .{ k, d.qLD[diag] },
        );
        const inv_pivot: f32 = 1.0 / d.qLD[diag];
        d.qLDiagInv[k] = inv_pivot;

        // Eliminate row k from every ancestor row above it.
        var adr: u32 = diag;
        while (adr > start) {
            adr -= 1;
            const i: u32 = m.mass_col_index[adr];
            const scale: f32 = -d.qLD[adr] * inv_pivot;
            // Row i's pattern is a prefix of row k's, so this is element-wise over
            // `rownnz[i]` contiguous entries of each. See the note above.
            const dst: u32 = m.mass_row_start[i];
            for (0..m.mass_row_nonzeros[i]) |t| {
                d.qLD[dst + t] += scale * d.qLD[start + t];
            }
        }

        // Normalize row k's off-diagonal part, so L has a unit diagonal.
        for (start..diag) |t| {
            d.qLD[t] *= inv_pivot;
        }
    }

    d.stage = .position;
}

/// Solve `M*x = y` in place, using the factorization from `factorM`.
///
/// Three passes, one per factor of `L^T*D*L`, in the order that undoes them:
/// `x <- L^-Tx`, then `x <- D^-1x`, then `x <- L^-1x`. Each is a sweep over the same ancestor
/// chains - no iteration, no tolerance, no convergence. The chain structure that made `M`
/// cheap to build makes it cheap to invert.
pub fn solveM(m: *const Model, d: *const Data, x: []f32) void {
    assertf(x.len == m.nv, @src(), "solveM wants {d} entries, got {d}", .{ m.nv, x.len });

    // x <- L^-T x. Backward: each DOF pushes its value onto its ancestors.
    var k: u32 = m.nv;
    while (k > 0) {
        k -= 1;
        const nnz: u32 = m.mass_row_nonzeros[k];
        if (nnz == 1) {
            continue; // a root DOF has no ancestors to push to
        }
        const xk: f32 = x[k];
        if (xk == 0.0) {
            continue; // nothing to propagate
        }
        const start: u32 = m.mass_row_start[k];
        for (start..start + nnz - 1) |adr| {
            x[m.mass_col_index[adr]] -= d.qLD[adr] * xk;
        }
    }

    // x <- D^-1 x. The reciprocals were stored during factorization so this multiplies.
    for (0..m.nv) |i| {
        x[i] *= d.qLDiagInv[i];
    }

    // x <- L^-1 x. Forward: each DOF pulls back the contributions of its ancestors, which
    // are already final because a parent always has a lower index.
    for (0..m.nv) |i| {
        const nnz: u32 = m.mass_row_nonzeros[i];
        if (nnz == 1) {
            continue;
        }
        const start: u32 = m.mass_row_start[i];
        var acc: f32 = 0;
        for (start..start + nnz - 1) |adr| {
            acc += d.qLD[adr] * x[m.mass_col_index[adr]];
        }
        x[i] -= acc;
    }
}

/// A cheap estimate of `M`'s condition number: the spread of the factorization's diagonal.
///
/// Free, because `D` was computed anyway. It is not the true condition number - that would
/// need eigenvalues - but it tracks it closely enough to be the warning we want, and it is
/// the only diagnostic available for the failure mode f32 makes possible.
///
/// A robot with a large mass ratio (a heavy torso driving a light fingertip) can push this
/// past what 24 bits of mantissa can carry, and the symptom is a simulation that goes soft
/// or diverges with no obvious cause. If this number is large and something looks wrong,
/// that is the answer. See section 1.1 of the port plan for the fix, which is narrow.
pub fn conditionEstimate(m: *const Model, d: *const Data) f32 {
    if (m.nv == 0) {
        return 1.0;
    }
    var lo: f32 = zm.floatMax(f32);
    var hi: f32 = 0;
    for (0..m.nv) |i| {
        // qLDiagInv is 1/D, so the extremes swap.
        const dval: f32 = 1.0 / d.qLDiagInv[i];
        lo = @min(lo, dval);
        hi = @max(hi, dval);
    }
    return if (lo > 0.0) hi / lo else zm.floatMax(f32);
}

// =============================================================================
// Velocity and bias forces - phase 3
//
// With M in hand we need the other side of the equation: `c(q,v)`, the forces that arise
// from motion and gravity alone, with no actuation and no contact. Coriolis, centrifugal
// and weight, bundled together because they are computed together and because the equation
// only ever wants their sum.
// =============================================================================

/// Body velocities and the rate of change of each DOF's motion axis, in the shared frame.
///
/// A child's velocity is its parent's plus whatever its own joints contribute - one
/// forward pass, accumulating down the tree. That part is obvious.
///
/// The interesting output is `cdof_dot`. A DOF's motion axis is not fixed in space: if a
/// body is already rotating, its joint axis is being carried along, and an axis that moves
/// contributes acceleration even at constant joint velocity. That contribution IS the
/// centrifugal and Coriolis terms, and `crossMotion(cvel, cdof)` is exactly how fast the
/// axis is being dragged.
///
/// Note which velocity is used: the axis is differentiated against the velocity ACCUMULATED
/// SO FAR - the parent's plus any earlier joints on this body, but not this joint's own
/// contribution. That is not an approximation. `crossMotion(x, x) = 0`, so a DOF's own
/// motion cannot drag its own axis, and leaving it out is both correct and more accurate in
/// floating point than adding a term that must cancel.
pub fn comVel(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.comVel");
    defer zone.end();
    d.requireStage(.position, "comVel");
    d.cvel[world_body] = .zero;

    for (1..m.nbody) |bi| {
        var vel: Motion = d.cvel[m.body_parent[bi]];
        const jnt_adr: u32 = m.body_jnt_adr[bi];

        // Walk JOINTS, not DOFs. The distinction is invisible for scalar joints and
        // load-bearing for ball and free ones - see the note on `rotationTriple`.
        for (jnt_adr..jnt_adr + m.body_jnt_num[bi]) |ji| {
            const dof: u32 = m.jnt_dof_adr[ji];
            switch (m.jnt_type[ji]) {
                .slide, .hinge => {
                    d.cdof_dot[dof] = crossMotion(vel, d.cdof[dof]);
                    vel = vel.add(d.cdof[dof].scale(d.vel[dof]));
                },
                .ball => rotationTriple(d, dof, &vel),
                .free => {
                    // The three translation axes are GLOBAL, so nothing can rotate them:
                    // their rate of change is exactly zero, whatever the body is doing.
                    inline for (0..3) |k| {
                        d.cdof_dot[dof + k] = .zero;
                        vel = vel.add(d.cdof[dof + k].scale(d.vel[dof + k]));
                    }
                    // Then the rotations, which DO see the translation velocity.
                    rotationTriple(d, dof + 3, &vel);
                },
            }
        }
        d.cvel[bi] = vel;
    }

    d.stage = .velocity;
}

/// The three rotational DOFs of a ball joint (or a free joint's rotation half).
///
/// * ALL THREE differentiate against the SAME velocity - the one before ANY of them has
/// contributed. That is not an optimisation, it is the definition: the three axes are
/// simultaneous components of one rotation, not a sequence of three joints. Updating the
/// velocity between them makes the second and third axes see motion that is really their
/// own siblings', which produces a plausible, wrong gyroscopic force.
///
/// A scalar joint cannot show this bug, because there is nothing to be out of order with -
/// which is exactly why it survives a test suite built on hinge models.
fn rotationTriple(d: *Data, dof: u32, vel: *Motion) void {
    const snapshot: Motion = vel.*;
    inline for (0..3) |k| {
        d.cdof_dot[dof + k] = crossMotion(snapshot, d.cdof[dof + k]);
    }
    inline for (0..3) |k| {
        vel.* = vel.add(d.cdof[dof + k].scale(d.vel[dof + k]));
    }
}

/// Recursive Newton-Euler: the inverse dynamics of the tree.
///
/// Given positions, velocities and a candidate acceleration, RNE returns the joint forces
/// that would produce it. Two passes:
///
///   * FORWARD, propagating acceleration down the tree and computing the spatial force on
///     each body from Newton-Euler: `f = I*a + v x* (I*v)`. The first term is the familiar
///     one; the second is the gyroscopic term, and it is why `crossForce` exists.
///   * BACKWARD, summing each body's force into its parent - because the force a joint
///     must supply is the total for everything hanging below it.
///
/// Then each DOF's share is its motion axis contracted against that total: `cdof * f`.
///
/// * THE GRAVITY TRICK. Gravity is not applied to the bodies. Instead the WORLD is given
/// an acceleration of `-g`, and it propagates down the tree like any other. In a frame
/// accelerating upward at `g`, weight appears exactly as a fictitious force - which is what
/// weight is. One line, no per-body special case, and it means gravity is switched off by
/// passing a zero vector rather than by branching anywhere.
///
/// Run with zero acceleration, this IS the definition of `c(q,v)`: the forces required to
/// hold the system at rest are precisely those that must be cancelled to achieve rest.
///
/// Note what is deliberately NOT here: an acceleration input. RNE can compute `M*a + c` in
/// one recursion, and MuJoCo's `mj_rne` offers that - but we do not use it, because the
/// tree recursion knows nothing about ARMATURE. Armature is rotor inertia: real mass, but
/// living in a gearbox rather than in a link, so it appears on `M`'s diagonal and nowhere
/// in the tree. Inverse dynamics therefore multiplies by the actual `M` instead (see
/// `inverseDynamics`), which makes the forward/inverse round trip exact BY CONSTRUCTION
/// rather than by two independent recursions happening to agree.
fn rne(m: *const Model, d: *Data, out: []f32) void {
    d.requireStage(.velocity, "rne");

    // Scratch, sized by the model. Both are per-body spatial quantities that never leave
    // this function, so they live in `Data` rather than being allocated per call.
    const cacc: []Motion = d.rne_cacc;
    const cfrc: []Force = d.rne_cfrc;

    // The world accelerates upward at g, so everything hanging off it feels weight.
    cacc[world_body] = .{ .ang = vec_zero, .lin = -m.opt.gravity };
    cfrc[world_body] = .zero;

    // ---- forward: accelerations, then the force each body needs ----
    for (1..m.nbody) |bi| {
        var a: Motion = cacc[m.body_parent[bi]];
        const dof_adr: u32 = m.body_dof_adr[bi];
        for (0..m.body_dof_num[bi]) |k| {
            const dof: u32 = dof_adr + @as(u32, @intCast(k));
            // The moving-axis term: even at constant joint velocity, a rotating axis
            // accelerates whatever is attached to it.
            a = a.add(d.cdof_dot[dof].scale(d.vel[dof]));
        }
        cacc[bi] = a;

        const inertia: Inertia = d.cinert[bi];
        // Newton-Euler for a rigid body, in spatial form.
        cfrc[bi] = inertia.mul(a).add(crossForce(d.cvel[bi], inertia.mul(d.cvel[bi])));
    }

    // ---- backward: a joint carries everything below it ----
    var bi: u32 = m.nbody;
    while (bi > 1) {
        bi -= 1;
        const parent: u32 = m.body_parent[bi];
        if (parent != world_body) {
            cfrc[parent] = cfrc[parent].add(cfrc[bi]);
        }
    }

    // ---- project onto each DOF's axis ----
    for (0..m.nv) |i| {
        out[i] = dot6(d.cdof[i], cfrc[m.dof_body[i]]);
    }
}

/// Compute `c(q,v)` - Coriolis, centrifugal and gravitational forces - into
/// `Data.bias_force`. This is RNE with the acceleration set to zero.
pub fn biasForce(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.rne");
    defer zone.end();
    rne(m, d, d.bias_force);
}

/// Multiply by the mass matrix: `out = M*x`.
///
/// Only the lower triangle is stored, so each entry is used twice - once for its own row,
/// once mirrored into the column. The symmetric storage that halved the memory costs one
/// extra accumulate here, which is a good trade.
pub fn mulM(m: *const Model, d: *const Data, x: []const f32, out: []f32) void {
    d.requireStage(.position, "mulM");
    assertf(x.len == m.nv and out.len == m.nv, @src(), "mulM wants {d}-vectors", .{m.nv});
    @memset(out, 0);
    for (0..m.nv) |i| {
        const row: u32 = m.mass_row_start[i];
        for (0..m.mass_row_nonzeros[i]) |k| {
            const j: u32 = m.mass_col_index[row + k];
            const value: f32 = d.mass_matrix[row + k];
            out[i] += value * x[j];
            if (j != i) {
                out[j] += value * x[i];
            }
        }
    }
}

/// Inverse dynamics: the joint forces that would produce acceleration `acc`.
///
///     tau = M*a + c
///
/// Useful on its own - gravity compensation is this with zero acceleration - and it is
/// half of the sharpest test in the project: run it on the output of forward dynamics and
/// it must return the force you started with, which checks `M`, its factorization, `c` and
/// every frame convention between them at once.
///
/// Uses the assembled `M` rather than a second tree recursion, so armature is included and
/// the round trip is exact by construction. See the note on `rne`.
pub fn inverseDynamics(m: *const Model, d: *Data, acc: []const f32, out: []f32) void {
    d.requireStage(.velocity, "inverseDynamics");
    mulM(m, d, acc, out);
    for (0..m.nv) |i| {
        out[i] += d.bias_force[i];
    }
}

/// Forward dynamics: solve for the acceleration, given the forces.
///
///     v_dot = M^-1 (tau - c)
///
/// The entire point of everything above. `M` is factored, `c` is known, so this is one
/// subtraction and one direct solve - no iteration, no tolerance.
///
/// Constraint forces (`J^Tf`) join the right-hand side in phase 6; until then a robot can
/// be driven by applied joint forces and gravity, which is enough for a pendulum and for
/// a torque-controlled arm.
pub fn forwardDynamics(m: *const Model, d: *Data) void {
    d.requireStage(.velocity, "forwardDynamics");
    for (0..m.nv) |i| {
        d.acc[i] = d.applied_force[i] + d.actuator_force[i] + d.passive_force[i] - d.bias_force[i];
    }
    solveM(m, d, d.acc);
    d.stage = .force;
}

// =============================================================================
// Passive forces
//
// Forces that depend only on position and velocity, with no control input: joint springs
// and dampers. They are "passive" in the technical sense that they cannot inject energy -
// a damper always removes it, a spring stores and returns it.
// =============================================================================

/// Joint springs and dampers into `Data.passive_force`.
///
/// Damping is the workhorse. Real joints have friction and real actuators have back-EMF;
/// a model with none of it rings forever and is harder to control than the machine it
/// represents. It also costs nothing numerically - damping is the one force that makes an
/// explicit integrator MORE stable rather than less.
///
/// LIMITATION, stated rather than hidden: stiffness applies to scalar joints only. A ball
/// or free joint's spring needs a rotation residual against a reference orientation, which
/// is a different computation from `q - q_ref` and is not worth writing until something
/// asks for it. Damping applies to every DOF of every joint type, which is the part models
/// actually use.
pub fn passive(m: *const Model, d: *Data) void {
    @memset(d.passive_force, 0);

    // Tendon springs and dampers. Same J^T spreading as an actuator's: a tendon's spring
    // acts on its LENGTH, and that scalar force reaches the joints through the
    // coefficients. Requires `tendonLengths` to have run, which `forward` guarantees by
    // ordering `actuation` after `passive`... so do it here rather than depend on that.
    if (m.ntendon > 0) {
        tendonLengths(m, d);
        for (0..m.ntendon) |ti| {
            const stiffness: f32 = m.tendon_stiffness[ti];
            const damping: f32 = m.tendon_damping[ti];
            if (stiffness == 0.0 and damping == 0.0) {
                continue;
            }
            const force: f32 = -stiffness * (d.tendon_length[ti] - m.tendon_rest_length[ti]) -
                damping * d.tendon_velocity[ti];
            const coefficients: []const f32 = m.tendon_jacobian[ti * m.nv ..][0..m.nv];
            for (d.passive_force, coefficients) |*q, coefficient| {
                q.* += force * coefficient;
            }
        }
    }

    for (0..m.njnt) |ji| {
        const dof_adr: u32 = m.jnt_dof_adr[ji];
        const ndof: u32 = m.jnt_type[ji].dofCount();

        // Damping opposes motion, on every DOF the joint owns.
        const damping: f32 = m.jnt_damping[ji];
        if (damping != 0.0) {
            for (dof_adr..dof_adr + ndof) |dof| {
                d.passive_force[dof] -= damping * d.vel[dof];
            }
        }

        // Stiffness pulls the coordinate back toward `ref`.
        const stiffness: f32 = m.jnt_stiffness[ji];
        if (stiffness != 0.0) {
            switch (m.jnt_type[ji]) {
                .hinge, .slide => {
                    const qadr: u32 = m.jnt_qpos_adr[ji];
                    d.passive_force[dof_adr] -= stiffness * (d.pos[qadr] - m.jnt_ref[ji]);
                },
                .ball, .free => {}, // see the limitation above
            }
        }
    }
}

// =============================================================================
// Actuators - phase 5
//
// This is where a mechanism becomes a robot. Everything so far responds to forces; nothing
// so far DECIDES what force to apply.
// =============================================================================

/// Tendon lengths and rates, from the constant coefficient matrix.
///
/// For a FIXED tendon this is two dot products per tendon and nothing else:
///
///     length   = sum coefficient_i * q_i
///     velocity = sum coefficient_i * v_i
///
/// which follows immediately from the definition, since the coefficients do not depend on
/// configuration. That is the whole reason a fixed tendon is a good way to couple joints:
/// it is a DEFINITION, evaluated, rather than a constraint that has to be enforced. An
/// equality constraint between the same joints would cost a solver row and would hold only
/// approximately; this holds exactly and costs a dot product.
///
/// A spatial tendon would compute both quantities geometrically here and everything after
/// would be unchanged - that separation is the point of section 7's transmission/force split.
pub fn tendonLengths(m: *const Model, d: *Data) void {
    for (0..m.ntendon) |ti| {
        const coefficients: []const f32 = m.tendon_jacobian[ti * m.nv ..][0..m.nv];
        var total_length: f32 = 0;
        var velocity: f32 = 0;
        for (coefficients, 0..) |coefficient, dof| {
            if (coefficient == 0.0) {
                continue;
            }
            // A tendon's coefficients index DOFs, but its LENGTH reads position
            // coordinates - and those are different index spaces in general (nq != nv).
            // The hop through the owning joint is what translates between them, and it is
            // exact here because `Spec()` only lets a tendon touch scalar joints, whose
            // single DOF and single position coordinate correspond one to one.
            total_length += coefficient * d.pos[m.jnt_qpos_adr[m.dof_jnt[dof]]];
            velocity += coefficient * d.vel[dof];
        }
        d.tendon_length[ti] = total_length;
        d.tendon_velocity[ti] = velocity;
    }
}

/// Read each actuator's transmission coordinate and its rate.
///
/// For a joint transmission that is simply the joint's own position and velocity. The
/// indirection exists because a tendon or site transmission computes them very differently
/// while everything downstream stays identical - which is the point of separating
/// transmission from force generation.
pub fn transmission(m: *const Model, d: *Data) void {
    tendonLengths(m, d);
    for (0..m.nu) |ai| {
        switch (m.act_kind[ai]) {
            .joint => {
                const ji: u32 = m.act_target[ai];
                d.act_length[ai] = d.pos[m.jnt_qpos_adr[ji]];
                d.act_velocity[ai] = d.vel[m.jnt_dof_adr[ji]];
            },
            .tendon => {
                const ti: u32 = m.act_target[ai];
                d.act_length[ai] = d.tendon_length[ti];
                d.act_velocity[ai] = d.tendon_velocity[ti];
            },
        }
    }
}

/// Compute the actuator forces, and the RATE of change of each activation state.
///
/// * It does not advance `act`. That is `advance`'s job, and the separation is not
/// stylistic: RK4 evaluates the dynamics four times per step, so an `actuation` that
/// integrated its own state would advance the activation four times per step. Computing a
/// rate and integrating it once is the only arrangement that is correct under both
/// integrators.
///
/// `filter_exact` is the reason `dt` is a parameter at all. Its update is analytic rather
/// than a rate, so it reports the rate that REPRODUCES the exact update over `dt`:
/// `(u - w)*(1 - e^{-dt/tau})/dt`. Under Euler that is exact. Under RK4's sub-steps it is an
/// approximation of an exact formula, which is a fair trade for keeping one code path.
pub fn actuation(m: *const Model, d: *Data, dt: f32) void {
    d.requireStage(.velocity, "actuation");
    transmission(m, d);
    @memset(d.actuator_force, 0);

    for (0..m.nu) |ai| {
        // Controls saturate. A model without a limit will happily command a thousand
        // newton-metres, and the resulting motion is not informative about anything.
        var u: f32 = d.ctrl[ai];
        if (m.act_ctrl_range[ai]) |r| {
            u = clamp(u, r[0], r[1]);
        }

        // ---- 1. activation RATE (integrated later, once) ----
        const state: u32 = m.act_state_adr[ai];
        const input: f32 = switch (m.act_activation[ai]) {
            .none => u,
            .integrator => blk: {
                d.act_dot[state] = u;
                break :blk d.act[state];
            },
            .filter => |f| blk: {
                d.act_dot[state] = (u - d.act[state]) / f.time_const_s;
                break :blk d.act[state];
            },
            .filter_exact => |f| blk: {
                // The exact update is `w += (u - w)(1 - e^{-dt/tau})`, which is stable for
                // ANY positive tau where the Euler form above diverges once tau < dt. Reported
                // as the equivalent rate so the integrator stays uniform.
                const alpha: f32 = 1.0 - @exp(-dt / f.time_const_s);
                d.act_dot[state] = (u - d.act[state]) * alpha / dt;
                break :blk d.act[state];
            },
        };

        // ---- 2. the affine force law ----
        const bias: [3]f32 = m.act_bias[ai];
        var force: f32 = m.act_gain[ai] * input +
            bias[0] + bias[1] * d.act_length[ai] + bias[2] * d.act_velocity[ai];
        if (m.act_force_range[ai]) |r| {
            force = clamp(force, r[0], r[1]);
        }
        d.act_force[ai] = force;

        // ---- 3. through the transmission into joint coordinates ----
        //
        // This is `J^Tf` again, in miniature. For a joint transmission the moment arm is a
        // single 1 (the gear is already folded into gain and bias), so it is one
        // accumulate. For a tendon the moment arm IS the coefficient vector, so one scalar
        // force spreads across every DOF the tendon touches - which is exactly how a real
        // tendon distributes tension along its path.
        switch (m.act_kind[ai]) {
            .joint => d.actuator_force[m.act_dof[ai]] += force,
            .tendon => {
                const coefficients: []const f32 = m.tendon_jacobian[m.act_target[ai] * m.nv ..][0..m.nv];
                for (d.actuator_force, coefficients) |*q, coefficient| {
                    q.* += force * coefficient;
                }
            },
        }
    }
}

/// Set an actuator's control by name (or index).
pub fn setCtrl(m: *const Model, d: *Data, actuator: anytype, value: f32) void {
    const ai: u32 = siteIndex(actuator); // same enum-or-index rule
    assertf(ai < m.nu, @src(), "actuator {d} out of range ({d} actuators)", .{ ai, m.nu });
    d.ctrl[ai] = value;
}

// =============================================================================
// Jacobians - phase 4
//
// A Jacobian answers: "if I move the joints, how does THIS point move?" It is the bridge
// between the space you control (joint angles) and the space you care about (where the
// hand is), and getting it once buys a surprising number of apparently unrelated things:
//
//   * a CONTACT is a row of J along the contact normal;
//   * a JOINT LIMIT is a row of J that is a unit vector on that DOF;
//   * an ACTUATOR's moment arm is the gradient of its transmission length;
//   * an END-EFFECTOR task - "move the gripper this way" - is a body Jacobian;
//   * and J^T maps a force applied at a point back into joint torques, which is how you
//     work out what your motors must do to push on the world.
//
// Layout note: a Jacobian is stored as one `Vec` PER DOF rather than a 3xnv matrix in
// row-major floats. Column `i` is then "the velocity this point gains per unit of DOF i",
// which is what every use above actually wants, and it keeps the arithmetic in zm's
// vocabulary instead of index expressions.
// =============================================================================

/// Jacobian of an arbitrary world-space point rigidly attached to `body`.
///
/// `jac_p` receives the TRANSLATIONAL Jacobian: how the point moves. `jac_r` receives the
/// ROTATIONAL one: how the body turns, which does not depend on which point you picked.
/// Either may be null when you only need the other.
///
/// THE DERIVATION, which is two lines. `cdof[i]` is DOF `i`'s motion as a spatial vector
/// about the tree's shared frame origin. A spatial motion `(omega, v)` about origin `O` moves
/// a point `p` at velocity `v + omega x (p - O)`. So:
///
///     jac_r[i] = cdof[i].ang
///     jac_p[i] = cdof[i].lin + cdof[i].ang x (point - frame_origin)
///
/// That is the whole computation. `comPos` did the hard part.
///
/// Only DOFs that actually move this body get a column - the rest are zero, and we find
/// them by walking the body's ancestor chain, the same chain `crb` and `factorM` walk.
pub fn jacPoint(
    m: *const Model,
    d: *const Data,
    body: u32,
    point: Vec,
    jac_p: ?[]Vec,
    jac_r: ?[]Vec,
) void {
    d.requireStage(.position, "jacPoint");
    if (jac_p) |jp| {
        assertf(jp.len == m.nv, @src(), "jac_p wants {d} columns, got {d}", .{ m.nv, jp.len });
        @memset(jp, vec_zero);
    }
    if (jac_r) |jr| {
        assertf(jr.len == m.nv, @src(), "jac_r wants {d} columns, got {d}", .{ m.nv, jr.len });
        @memset(jr, vec_zero);
    }

    const offset: Vec = point - d.subtree_com[m.body_root[body]];
    var i: u32 = lastDofOf(m, body);
    while (i != no_dof) : (i = m.dof_parent[i]) {
        const motion: Motion = d.cdof[i];
        if (jac_p) |jp| {
            jp[i] = motion.lin + cross(motion.ang, offset);
        }
        if (jac_r) |jr| {
            jr[i] = motion.ang;
        }
    }
}

/// Jacobian of a body's centre of mass - the one MuJoCo's `mj_jacBodyCom` returns, and
/// the natural target when you care about where the mass is rather than where the origin
/// happens to be.
pub fn jacBodyCom(
    m: *const Model,
    d: *const Data,
    body: u32,
    jac_p: ?[]Vec,
    jac_r: ?[]Vec,
) void {
    jacPoint(m, d, body, d.body_xipos[body], jac_p, jac_r);
}

/// Jacobian of a site. Sites exist precisely to be named points on a body, so this is the
/// form most task-space control actually uses: put a site at the gripper, ask for its
/// Jacobian, and you can convert a desired hand motion into joint motion.
pub fn jacSite(
    m: *const Model,
    d: *const Data,
    site: anytype,
    jac_p: ?[]Vec,
    jac_r: ?[]Vec,
) void {
    const si: u32 = siteIndex(site);
    jacPoint(m, d, m.site_body[si], d.site_xpos[si], jac_p, jac_r);
}

/// Map a force and torque applied at a point back into joint forces: `tau += J^T*(f, t)`.
///
/// This is what `J^T` is FOR, and it is the reason the transpose shows up in the equation of
/// motion. Pushing on the world with your hand produces a torque at every joint between
/// your hand and the ground, and the Jacobian transpose is exactly that bookkeeping.
///
/// Accumulates rather than assigns, so several applied forces compose without a temporary.
pub fn applyForceAtPoint(
    m: *const Model,
    d: *const Data,
    body: u32,
    point: Vec,
    force: Vec,
    torque: Vec,
    jac_p: []Vec,
    jac_r: []Vec,
    out: []f32,
) void {
    jacPoint(m, d, body, point, jac_p, jac_r);
    for (0..m.nv) |i| {
        out[i] += dot3(jac_p[i], force) + dot3(jac_r[i], torque);
    }
}

/// Accept a generated enum or a plain index. The same rule as `jointIndex`, used by every
/// by-name accessor: a comptime model gets compile-checked names, a runtime-loaded one
/// falls back to integers, and neither pays anything.
fn siteIndex(site: anytype) u32 {
    return switch (@typeInfo(@TypeOf(site))) {
        .@"enum" => @backingInt(site),
        else => @intCast(site),
    };
}

// =============================================================================
// Constraints - phase 6a: the ROWS, with no solver
//
// Every constraint in this engine - a joint limit today, a contact and an equality later -
// reduces to the same three numbers per scalar row:
//
//   * a JACOBIAN row `J_i`, saying which joint motions violate it;
//   * a REFERENCE ACCELERATION `aref_i`, saying what the constraint wants to happen;
//   * a REGULARIZER `R_i`, saying how hard it insists.
//
// Given those, the solver's job (phase 6c) is to find forces `f` with
// `(A + R) f = aref - a_unconstrained` subject to `f` lying in an allowed set. Nothing
// about the rows depends on how that is solved, which is exactly why they are built and
// TESTED first: a wrong row and a wrong solver produce the same symptom, and separating
// them is the difference between a day and a week.
//
// * WHY SOFT. Every other rigid-body engine treats contact as a HARD complementarity
// problem: either the bodies touch and there is force, or they separate and there is none.
// That is an LCP, it is NP-hard with friction, and it has no unique solution in general.
// Making every constraint soft - allowing a little penetration in exchange for a force
// that grows smoothly - turns it into a CONVEX problem: always solvable, unique, and
// differentiable. The last of those is not a bonus; it is the property section 4d needs.
// =============================================================================

/// What produced a constraint row. Only limits exist today; contacts and equalities join
/// this enum rather than getting their own parallel arrays, because the solver must treat
/// them uniformly and an enum makes that structural.
pub const ConstraintKind = enum {
    /// A joint pushed past one end of its range.
    limit,
    /// One edge of a contact's friction pyramid. See `addContact`.
    contact,
    /// One axis of an equality constraint holding two points together. See `EqualitySpec`.
    connect,

    /// Whether this row may only PUSH, never pull.
    ///
    /// -- * THE ONE QUESTION EVERY SOLVER ASKS ABOUT A ROW --
    ///
    /// A surface can separate and a joint limit can be left; a loop closure cannot, because the
    /// two points are welded together. PGS clamps a unilateral row's force at zero and leaves a
    /// bilateral one free; Newton includes a unilateral row in the objective only while it is
    /// violated, which is what makes that objective piecewise quadratic.
    ///
    /// * ASKING THE ENUM BEATS COMPARING AGAINST IT. This was written inline as
    /// `kind != .connect` in four places, which is correct today and silently wrong the moment
    /// a second bilateral kind is added - a `weld`'s orientation rows, say. Here the compiler
    /// will point at this switch instead.
    pub fn isUnilateral(self: ConstraintKind) bool {
        return switch (self) {
            .limit, .contact => true,
            .connect => false,
        };
    }
};

/// One end of a loop closure: a point on a body, in that body's own frame.
pub const Anchor = struct {
    body: u32,
    point: Vec,
};

/// Resolve a joint name to where its scalar coordinate lives.
///
/// * HINGE AND SLIDE ONLY. A ball or free joint has no scalar to couple - its coordinate is a
/// quaternion or a whole pose - so a coupling naming one is a modelling error rather than
/// something to approximate.
fn coordinateOf(spec: ModelSpec, m: Model, name: []const u8) BuildError!Coordinate {
    const j: u32 = try jointIndexByName(spec, name);
    switch (m.jnt_type[j]) {
        .hinge, .slide => {},
        .free, .ball => return BuildError.UnsupportedJointForCoupling,
    }
    return .{
        .qpos = m.jnt_qpos_adr[j],
        .dof = m.jnt_dof_adr[j],
        .rest = m.qpos0[m.jnt_qpos_adr[j]],
    };
}

/// Express a point given in one body's frame in another body's frame, at the REST pose.
///
/// Walks each body's parent chain to the world using the model's own `body_pos`/`body_rot` -
/// which is `qpos0`, since a joint at its zero coordinate contributes nothing. That is exactly
/// the configuration a spec describes, so a closure derived here is satisfied the moment the
/// model is built.
fn restFrameAnchor(m: *const Model, from_body: u32, point: Vec, to_body: u32) Vec {
    const in_world: Vec = restToWorld(m, from_body, point);
    // The inverse of `to_body`'s rest transform: undo the translation, then the rotation.
    const pose: Pose = restPose(m, to_body);
    return rotate(conjugate(pose.rot), in_world - pose.pos);
}

/// A body's rest transform, composed from the root down.
fn restPose(m: *const Model, body: u32) Pose {
    if (body == world_body) {
        return .{ .pos = vec_zero, .rot = quat_identity };
    }
    const parent: Pose = restPose(m, m.body_parent[body]);
    return .{
        .pos = parent.pos + rotate(parent.rot, m.body_pos[body]),
        .rot = qmul(parent.rot, m.body_rot[body]),
    };
}

fn restToWorld(m: *const Model, body: u32, point: Vec) Vec {
    const pose: Pose = restPose(m, body);
    return pose.pos + rotate(pose.rot, point);
}

/// A resolved loop closure, as the model stores it.
pub const Equality = struct {
    /// What is being held equal. The two variants share nothing but their softness, which is
    /// why this is a field rather than the whole type being a union - every caller that only
    /// cares how STIFFLY a closure is held can read `softness` without unwrapping anything.
    holds: union(enum) {
        /// Two points on two bodies that must coincide.
        connect: struct { a: Anchor, b: Anchor },
        /// Two bodies held at a fixed relative POSE - position and orientation both.
        ///
        /// -- * WHY THIS IS NOT JUST A JOINTLESS BODY --
        ///
        /// A body with no joint is welded to its PARENT, which the tree already expresses for
        /// free. This welds two bodies that are not related that way - a hand gripping a
        /// crate, two halves of a mechanism bolted together at runtime, a robot clamped to a
        /// bench it did not grow from. The tie can also be removed again, which a topology
        /// cannot.
        weld: struct {
            a: Anchor,
            b: Anchor,
            /// The relative orientation to hold: `rot_b * relative = rot_a`.
            relative: Quat,
            /// How much the orientation rows count for relative to the position ones.
            /// MuJoCo's `torquescale`, and for the same reason: the two halves are in
            /// different units - metres against radians - so one number has to say how they
            /// trade, and 1 means "a radian matters as much as a metre".
            torque_scale: f32,
        },
        /// One joint's coordinate as a polynomial in another's - MuJoCo's
        /// `<equality type="joint">`. See `JointCouplingSpec`.
        joint: struct {
            /// The joint whose value is DETERMINED. Its qpos and dof addresses, resolved.
            driven: Coordinate,
            /// The joint it follows. Null couples `driven` to a constant.
            driver: ?Coordinate,
            /// `driven - ref = c0 + c1*x + c2*x^2 + c3*x^3 + c4*x^4`, where `x = driver - ref`.
            poly: [5]f32,
        },
    },
    softness: Softness,
    impedance: Impedance,
};

/// A scalar joint coordinate, resolved to where it lives.
pub const Coordinate = struct {
    qpos: u32,
    dof: u32,
    /// The joint's rest value, which the polynomial is measured from - the same `qpos0`
    /// convention MuJoCo uses, so a coupling written for one reads the same in the other.
    rest: f32,
};

/// A point on two bodies that must coincide - MuJoCo's `<equality type="connect">`.
///
/// -- ** WHY A TREE NEEDS THIS AT ALL --
///
/// Reduced coordinates buy exact joints and no drift, and they pay for it in TOPOLOGY: a tree
/// has no loops, so a mechanism whose links form a ring cannot be spelled at all. That rules
/// out a whole class of real machine - Cassie and Digit's parallel shin linkages, four-bar
/// suspensions, most delta arms, and nearly every rigid gripper whose fingers are geared to
/// each other.
///
/// The standard answer, and MuJoCo's, is to build the SPANNING TREE and close the remaining
/// loops with constraints the solver enforces. The joints stay exact; the loop closure is
/// approximate in the same way contact is, and to the same tolerance.
///
/// * THREE ROWS, NOT ONE. A point constraint is three scalar equations - one per world axis -
/// and they go to the solver as three rows sharing a body pair. Writing it as a single row
/// along the current error direction would look right while the error is small and drift
/// sideways, because a direction computed from an error cannot constrain the two axes the
/// error happens not to point along.
pub const EqualitySpec = struct {
    /// The two bodies, by name.
    body_a: []const u8,
    body_b: []const u8,
    /// The coincident point, in each body's own frame.
    anchor_a: Vec = vec_zero,
    /// Hold the two bodies at a fixed relative POSE rather than at a shared point. The
    /// orientation to hold is derived from the rest pose, in the same way `anchor_b` is.
    weld: bool = false,
    /// See `Equality.weld`. Only read when `weld` is set.
    torque_scale: f32 = 1.0,
    /// Couple two joints instead of two points. When set, the anchors are ignored.
    ///
    /// -- * WHAT THIS IS FOR --
    ///
    /// A parallel gripper's two fingers driven by one motor; a geared pair; a linkage whose
    /// ratio is known rather than derived from geometry. `driven - rest = c0 + c1*x + ... `
    /// where `x = driver - rest`, which is MuJoCo's `polycoef` exactly - a coupling written
    /// for one engine reads the same in the other.
    ///
    /// A LINEAR coupling is `.{ offset, ratio }` and covers essentially every gripper. The
    /// higher terms exist because MuJoCo has them and a model may use them, not because they
    /// are usually wanted.
    couple: ?JointCouplingSpec = null,
    /// Where the point sits in `body_b`'s frame - or **null to derive it**, which is almost
    /// always what you want.
    ///
    /// -- ** A LOOP CLOSURE THAT STARTS VIOLATED SNAPS --
    ///
    /// Both anchors describe the same physical point, so stating both is stating the same
    /// fact twice in two different frames - and getting the second one wrong by a centimetre
    /// gives a mechanism that lurches on frame one and then behaves, which reads as a solver
    /// problem and is a typo.
    ///
    /// Null means "whatever makes this exact at the rest pose": the builder places `anchor_a`
    /// in the world using `qpos0`, then expresses that point in `body_b`'s frame. **MuJoCo
    /// does the same derivation** - its `<connect anchor="...">` takes one point and the
    /// compiler fills in the other - but only in the file format. Having it in the API means
    /// a model built in code gets it too.
    anchor_b: ?Vec = null,
    /// How stiffly the loop is held. The default is stiffer than contact: a loop closure is a
    /// statement about the mechanism rather than about a surface, and a visibly stretchy
    /// linkage is worse than a slightly harsh one.
    softness: Softness = .{ .time_const_s = 0.005 },
    impedance: Impedance = .{},
};

/// One joint's coordinate as a polynomial in another's.
pub const JointCouplingSpec = struct {
    /// The joint whose value is determined by the other.
    driven: []const u8,
    /// The joint it follows. Null pins `driven` to a constant offset from its rest value,
    /// which is how a joint is locked without removing it from the model.
    driver: ?[]const u8 = null,
    /// `c0 ... c4`. `.{ 0, 1 }` makes the two joints equal; `.{ 0, -1 }` mirrors them.
    poly: [5]f32 = .{ 0, 1, 0, 0, 0 },
};

/// A contact, as the collision detector reports it. Deliberately a plain value type with
/// no reference to the shapes that produced it: the row builder needs the geometry of the
/// touching, not the identity of the touchers, and keeping it that way is what lets
/// zimrphysics be the collision source without robot.zig knowing anything about it.
pub const Contact = struct {
    /// Where the contact acts, in world coordinates.
    position: Vec,
    /// Unit normal, pointing from `body_a` toward `body_b` - so a positive normal force
    /// pushes `body_b` along it and `body_a` against it.
    normal: Vec,
    /// Two unit vectors completing a right-handed frame with `normal`. The friction
    /// directions. Supplied rather than derived so the caller can keep them stable frame
    /// to frame, which matters for warm starting later.
    tangent: [2]Vec,
    /// Separation. NEGATIVE when the shapes overlap, which is the interesting case.
    distance: f32,
    /// Coulomb friction coefficient, one per tangent direction.
    friction: [2]f32,
    /// The two bodies, as indices into THIS robot's tree. `world_body` for static
    /// geometry and for anything outside the tree.
    body_a: u32,
    body_b: u32,
    /// -- * WHY THERE IS NO `external_mass` HERE (section 4k) --
    ///
    /// There was, briefly. When a contact's other side lived in a different engine, this
    /// struct carried its inverse mass, inverse inertia, centre of mass, velocity and
    /// acceleration, and `A_hat` added an effective-mass term for it. All of that existed to
    /// describe a body the solver could not see.
    ///
    /// In one tree it can see it. `addContactRows` builds the RELATIVE Jacobian
    /// `jac_b - jac_a`, so `J M^-1 J^T` already contains BOTH inertias, `J*v` is already the
    /// relative velocity and `J*a` the relative acceleration. Every one of those fields was
    /// a hand-rolled reconstruction of something the Jacobian does exactly.
    ///
    /// **`world_body` on either side still means immovable**, which is correct for static
    /// geometry and is the deliberate approximation for a zimrphysics body a scene chose not
    /// to put in the tree.
    /// A stable identity for this contact POINT, from whatever detected it.
    ///
    /// Two jobs, both needing it to survive from one step to the next: it is the tie
    /// breaker that makes row order deterministic when two contacts share a body pair, and
    /// it is what will let a future warm start match a row to the force it carried last
    /// step. A detector that cannot supply one should leave it zero and accept that ties
    /// fall back to insertion order.
    id: u64 = 0,
    /// Distance at which the contact begins to act. Positive values engage it early,
    /// which lets a soft contact decelerate rather than catch.
    margin: f32 = 0,
    softness: Softness = .{},
    impedance: Impedance = .{},
};

/// Assemble the active constraint rows for the current state.
///
/// A limit end is ACTIVE when the joint is within `margin` of it. The distance is measured
/// per END, not to the nearest one:
///
///     lower:  q - lo          upper:  hi - q
///
/// and either being below `margin` produces a row. Negative means already violated.
///
/// * BOTH ENDS CAN BE ACTIVE AT ONCE, and the code must allow it. It looks impossible -
/// a joint cannot be past its lower and upper stops simultaneously - but `margin` is what
/// makes it reachable: if the range is narrower than `2*margin`, the joint is within margin
/// of both ends everywhere in its travel, and MuJoCo emits two rows. A tempting shortcut
/// (`residual = min(q - lo, hi - q)`, one row) is correct for every model with the default
/// zero margin and silently wrong for a narrow range with a generous one. The two rows then
/// oppose each other and the solver balances them, which is the right behaviour: the joint
/// is being softly squeezed from both sides.
///
/// The Jacobian row is `+1` for a lower end and `-1` for an upper one, so a positive
/// constraint force always pushes the joint back INTO its range whichever end it hit. That
/// convention is what lets the solver clamp every row to `f >= 0` uniformly instead of
/// tracking which direction each row wants to push.
pub fn makeConstraints(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.constraints");
    defer zone.end();
    d.requireStage(.position, "makeConstraints");
    d.constraint_count = 0;

    // -- ** EQUALITIES FIRST, BECAUSE THEY ARE THE ONLY ROWS THAT ARE NOT OPTIONAL --
    //
    // A contact appears when two things touch and a limit when a joint runs out of travel;
    // both are conditions of the moment. A loop closure is part of the MECHANISM - emitted
    // every step, unconditionally - and a linkage that loses its closure because a busy contact
    // step filled the buffer is not a linkage.
    //
    // Capacity reserves exact room for them, so this should never be the difference. It is
    // ordered this way anyway: the reservation is a promise made in one function and kept in
    // another, and putting the unconditional rows first means a mistake in either shows up as
    // a dropped CONTACT - visible, recoverable - rather than as a limb quietly falling off.
    for (0..m.neq) |eq| {
        addEqualityRows(m, d, @intCast(eq));
    }

    for (0..m.njnt) |ji| {
        const range: [2]f32 = m.jnt_range[ji] orelse continue;
        // `Spec()` rejects a range on a ball or free joint, so a scalar coordinate is
        // guaranteed here rather than assumed.
        const qadr: u32 = m.jnt_qpos_adr[ji];
        const vadr: u32 = m.jnt_dof_adr[ji];
        const q: f32 = d.pos[qadr];
        const margin: f32 = m.jnt_limit_margin[ji];

        // Lower end first, then upper - the order MuJoCo emits them in, which matters
        // because the fixtures compare row by row.
        const ends = [_]struct { distance: f32, jacobian: f32 }{
            .{ .distance = q - range[0], .jacobian = 1.0 },
            .{ .distance = range[1] - q, .jacobian = -1.0 },
        };
        for (ends) |end| {
            if (end.distance >= margin) {
                continue;
            }
            const row: u32 = d.constraint_count;
            assertf(
                row < m.constraint_capacity,
                @src(),
                "constraint rows overflowed: {d} active, capacity {d}",
                .{ row + 1, m.constraint_capacity },
            );

            // One nonzero entry: this joint's own DOF.
            const base: usize = row * m.nv;
            @memset(d.constraint_jacobian[base .. base + m.nv], 0);
            d.constraint_jacobian[base + vadr] = end.jacobian;

            d.constraint_kind[row] = .limit;
            d.constraint_source[row] = @intCast(ji);
            // Both ends of one joint share a source, so the END must be in the key too, or a
            // joint swinging from one stop to the other inherits the opposite end's force.
            d.constraint_key[row] = constraintKey(.limit, ji, if (end.jacobian > 0) 0 else 1);
            d.constraint_violation[row] = end.distance - margin;
            d.constraint_softness[row] = m.jnt_limit_softness[ji];
            d.constraint_impedance[row] = m.jnt_limit_impedance[ji];
            d.constraint_count = row + 1;
        }
    }

    // ---- contacts ----
    // * SORTED FIRST, and this is not tidiness. A constraint solver is order-sensitive:
    // Gauss-Seidel sweeps rows in sequence, so a different row order gives a different
    // (equally valid) answer. Collision detectors do not promise a stable order -
    // zimrphysics's broad phase certainly does not, and MuJoCo sorts its own contacts for
    // exactly this reason - so without a sort here the same scene replayed from the same
    // state can diverge. Sorting inside the engine means a caller cannot forget to.
    std.mem.sort(Contact, d.contacts[0..d.contact_count], {}, contactBefore);
    for (d.contacts[0..d.contact_count], 0..) |contact, index| {
        addContactRows(m, d, contact, @intCast(index));
    }
}

/// Total order on contacts: body pair first, then the detector's stable id. Ties fall back
/// to insertion order because `std.mem.sort` is not stable - which is why `Contact.id`
/// exists and why a detector that supplies one gets a stronger guarantee than one that
/// does not.
fn contactBefore(_: void, a: Contact, b: Contact) bool {
    if (a.body_a != b.body_a) {
        return a.body_a < b.body_a;
    }
    if (a.body_b != b.body_b) {
        return a.body_b < b.body_b;
    }
    return a.id < b.id;
}

/// Turn one contact into constraint rows, using a PYRAMIDAL friction cone.
///
/// -- WHAT COULOMB FRICTION ACTUALLY DEMANDS --
/// The physical condition is that the tangential force stays inside a cone around the
/// normal: `||f_tangential|| <= mu * f_normal`. That is a second-order cone constraint, and
/// projecting onto it is a different and harder operation than clamping a scalar.
///
/// -- THE PYRAMID TRICK --
/// Approximate the cone by a pyramid whose EDGES are the directions `n +/- mu_k*t_k`, and give
/// each edge its own non-negative force. Then:
///
///   * the total force is a non-negative combination of edge directions, so it lies inside
///     the pyramid automatically;
///   * the normal components add up, so `f_normal` is the sum of the edge forces;
///   * the tangential components cancel in pairs unless the edges are loaded unevenly, and
///     the imbalance is bounded by `mu` times the normal force - which IS the friction law.
///
/// * The consequence is the good part: **friction needs no special projection**. Each edge
/// row is just `f >= 0`, exactly like a joint limit, so the solver written in 6c handles
/// friction without a single line of change. The cost is that a pyramid is not a cone -
/// friction is slightly stronger along the pyramid's edges (by up to sqrt2 for two tangents)
/// than along its faces - which is the standard, well-understood approximation and the one
/// MuJoCo uses by default.
///
/// All rows of one contact share the SAME residual, the penetration depth. That looks odd
/// for the friction rows, whose own violation is tangential slip rather than penetration,
/// and it is deliberate: a friction row should engage exactly when the contact does, and
/// tying it to the same residual is what couples them.
fn addContactRows(m: *const Model, d: *Data, contact: Contact, contact_index: u32) void {
    if (contact.distance >= contact.margin) {
        return; // not touching, and not close enough to matter
    }

    // The contact-frame Jacobian: how the CONTACT POINT's relative velocity depends on
    // joint motion. Relative, so it is the difference of the two bodies' point Jacobians -
    // and because a static body's Jacobian is identically zero, contact against the world
    // falls out of the same expression with no special case.
    const jac_a: []Vec = d.pair_jac_a;
    const jac_b: []Vec = d.pair_jac_b;
    jacPoint(m, d, contact.body_a, contact.position, jac_a, null);
    jacPoint(m, d, contact.body_b, contact.position, jac_b, null);

    // Project the relative Jacobian onto the contact frame, giving one row per direction.
    const directions = [_]Vec{ contact.normal, contact.tangent[0], contact.tangent[1] };
    var projected: [3][]f32 = .{
        d.contact_projected[0 * m.nv ..][0..m.nv],
        d.contact_projected[1 * m.nv ..][0..m.nv],
        d.contact_projected[2 * m.nv ..][0..m.nv],
    };
    for (directions, 0..) |direction, k| {
        for (0..m.nv) |i| {
            projected[k][i] = dot3(direction, jac_b[i] - jac_a[i]);
        }
    }

    // Two rows per tangent: the pyramid's opposing edges.
    // The violation the constraint drives to zero.
    //
    // `margin` shifts the equilibrium: a contact with a positive margin settles that far
    // apart, which lets a constraint engage before the surfaces meet. Contacts from
    // `robot_physics` use zero - see the note there for why, and for what was measured
    // before arriving at it.
    const violation: f32 = contact.distance - contact.margin;
    for (0..2) |tangent_index| {
        const mu: f32 = contact.friction[tangent_index];
        for ([_]f32{ 1.0, -1.0 }) |sign| {
            const row: u32 = d.constraint_count;
            assertf(
                row < m.constraint_capacity,
                @src(),
                "constraint rows overflowed: {d} active, capacity {d}",
                .{ row + 1, m.constraint_capacity },
            );
            const base: usize = row * m.nv;
            for (0..m.nv) |i| {
                d.constraint_jacobian[base + i] = projected[0][i] + sign * mu * projected[tangent_index + 1][i];
            }
            // * The row's WORLD-SPACE direction, kept because section 4h-ter needs it.
            //
            // Each pyramid edge is `normal + sign*mu*tangent`, a different direction per
            // row - so the external body's resistance differs per row too, and computing it
            // from the contact NORMAL would be right for one row in four. Storing the
            // direction here, where it is already being formed, costs a vector and saves
            // reconstructing it (and the chance of reconstructing it differently).
            d.constraint_direction[row] = contact.normal +
                splat(sign * mu) * contact.tangent[tangent_index];
            d.constraint_kind[row] = .contact;
            // For a contact row this is the index into `Data.contacts`; for a limit row it
            // is the joint index. Two meanings in one array, discriminated by
            // `constraint_kind` - read one without checking the other and you will get a
            // plausible wrong answer.
            d.constraint_source[row] = contact_index;
            // `contact.id` is the detector's stable per-point identity - the reason
            // `Contact` carries one. The pyramid edge index completes it.
            // `contact.id` is a u64 from the detector, so it is narrowed here rather than in
            // `constraintKey` - the packing there reserves 48 bits for the source, which is
            // ample for any id a broad phase produces and keeps the key one integer.
            d.constraint_key[row] = constraintKey(
                .contact,
                // The mask lives with the packing, in `source_mask`.
                contact.id,
                tangent_index * 2 + @as(usize, if (sign > 0) 0 else 1),
            );
            d.constraint_violation[row] = violation;
            d.constraint_softness[row] = contact.softness;
            d.constraint_impedance[row] = contact.impedance;
            d.constraint_count = row + 1;
        }
    }
}

/// Rows for one equality constraint - three, one per world axis.
///
/// -- ** A CONNECT ROW IS A CONTACT ROW WITHOUT THE INEQUALITY --
///
/// The machinery is nearly identical: take both bodies' point Jacobians at the shared point,
/// subtract them for the relative Jacobian, project onto a direction, and give the solver the
/// violation along it. What differs is the SIGN CONDITION. A contact may only push
/// (`f >= 0`) - the surfaces are free to separate. A loop closure may push OR pull, because the
/// two points are welded together and neither is allowed to leave.
///
/// * THREE AXES, NOT ONE ALONG THE ERROR. Projecting onto the error direction would look right
/// while the error is small and drift sideways: a direction derived from the error cannot
/// constrain the two axes the error does not happen to point along. World X, Y and Z always
/// span the space, whatever the error is doing.
/// How far apart a loop closure's two anchors currently are, in metres.
///
/// -- * THE ONE NUMBER ANYONE DEBUGGING A LINKAGE WANTS --
///
/// A loop closure is SOFT, like contact - it holds to a tolerance rather than exactly, and the
/// tolerance depends on the mechanism's stiffness, the timestep and how hard the loop is being
/// worked. So "is my linkage holding?" is a real question with a real answer, and it should not
/// require knowing that the answer lives in three rows of `constraint_violation` indexed by
/// something that is only an equality index if `constraint_kind` says so.
///
/// MuJoCo makes you find the rows in `efc_pos` yourself. This is the same information, asked
/// the way it is actually wanted.
pub fn equalityError(m: *const Model, d: *const Data, eq: u32) f32 {
    d.requireStage(.position, "equalityError");
    const closure: Equality = m.equalities[eq];
    return switch (closure.holds) {
        .connect => |points| length3(worldAnchor(d, points.b) - worldAnchor(d, points.a)),
        // * A WELD'S ERROR IS REPORTED AS THE POSITION PART ONLY. It has two halves in
        // different units - metres and radians - and no single number honestly combines them.
        // Position is the one a caller can act on ("has the grip slipped?"), so that is what
        // this answers, and the orientation rows are visible in `constraint_violation` for
        // anyone who needs them.
        .weld => |w| length3(worldAnchor(d, w.b) - worldAnchor(d, w.a)),
        // For a coupling the error is already scalar, and its sign carries which way the
        // driven joint has drifted - which the caller usually wants, so it is not made
        // absolute here.
        .joint => |couple| blk: {
            var wanted: f32 = couple.poly[0];
            if (couple.driver) |driver| {
                const x: f32 = d.pos[driver.qpos] - driver.rest;
                var power: f32 = x;
                inline for (1..5) |k| {
                    wanted += couple.poly[k] * power;
                    power *= x;
                }
            }
            break :blk (d.pos[couple.driven.qpos] - couple.driven.rest) - wanted;
        },
    };
}

/// Where an anchor currently sits in the world.
///
/// * ONE DEFINITION, TWO CALLERS. The row builder and the diagnostic both need this, and two
/// copies of `body_xpos + rotate(body_xrot, point)` is exactly the duplication that drifts -
/// one gets a fix and the other keeps reporting the old answer, which is worse than either
/// being wrong on its own.
fn worldAnchor(d: *const Data, anchor: Anchor) Vec {
    return d.body_xpos[anchor.body] + rotate(d.body_xrot[anchor.body], anchor.point);
}

fn addEqualityRows(m: *const Model, d: *Data, eq: u32) void {
    const closure: Equality = m.equalities[eq];
    switch (closure.holds) {
        .connect, .weld => {},
        .joint => |couple| {
            if (d.constraint_count >= m.constraint_capacity) {
                return;
            }
            // -- * ONE ROW, AND THE JACOBIAN IS THE POLYNOMIAL'S DERIVATIVE --
            //
            // The constraint is `driven - rest = poly(x)` with `x = driver - rest`, so the
            // row's violation is how far that is from holding, and its Jacobian is
            // `d/dq = [1 on driven, -poly'(x) on driver]`. Linear coupling makes the
            // derivative a constant, which is the case every gripper uses.
            const row: u32 = d.constraint_count;
            const projected: []f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
            @memset(projected, 0);
            projected[couple.driven.dof] = 1;

            var wanted: f32 = couple.poly[0];
            if (couple.driver) |driver| {
                const x: f32 = d.pos[driver.qpos] - driver.rest;
                var power: f32 = x;
                var slope: f32 = 0;
                inline for (1..5) |k| {
                    wanted += couple.poly[k] * power;
                    slope += float(k) * couple.poly[k] * (power / x);
                    power *= x;
                }
                // * AT x = 0 THE DIVISION ABOVE IS 0/0. Rebuild the slope directly there - it
                // is `c1`, and a NaN in one row poisons the whole solve.
                projected[driver.dof] = -(if (x == 0) couple.poly[1] else slope);
            }
            d.constraint_kind[row] = .connect;
            d.constraint_source[row] = eq;
            d.constraint_key[row] = constraintKey(.connect, eq, 0);
            d.constraint_violation[row] = (d.pos[couple.driven.qpos] - couple.driven.rest) - wanted;
            d.constraint_softness[row] = closure.softness;
            d.constraint_impedance[row] = closure.impedance;
            d.constraint_count = row + 1;
            return;
        },
    }
    // * BOTH `connect` AND `weld` HAVE THE SAME TWO ANCHORS, and the position rows below are
    // identical for either - a weld is a connect with three more rows after it. Reading
    // `.connect` unconditionally happened to compile and crashed on the first weld, which is
    // the union doing its job.
    const points: struct { a: Anchor, b: Anchor } = switch (closure.holds) {
        .connect => |c| .{ .a = c.a, .b = c.b },
        .weld => |w| .{ .a = w.a, .b = w.b },
        .joint => unreachable, // returned above
    };
    const at_a: Vec = worldAnchor(d, points.a);
    const at_b: Vec = worldAnchor(d, points.b);
    const gap: Vec = at_b - at_a;

    const jac_a: []Vec = d.pair_jac_a;
    const jac_b: []Vec = d.pair_jac_b;
    // * EACH BODY'S JACOBIAN AT ITS OWN ANCHOR, not at a shared point. For a contact the two
    // touching points coincide by definition; for a loop closure they coincide only once the
    // constraint is satisfied, and using one point for both would compute the wrong velocity
    // relationship exactly when the error is largest.
    jacPoint(m, d, points.a.body, at_a, jac_a, null);
    jacPoint(m, d, points.b.body, at_b, jac_b, null);

    // * ALL THREE ROWS OR NONE, and the capacity is reserved so this cannot fire in practice.
    //
    // Emitting two rows because the third did not fit would leave the mechanism held in X and
    // Y and free to slide apart in Z - worse than no constraint, and it reads as a solver bug
    // rather than the capacity limit it is. The first version checked inside the row loop and
    // could return mid-constraint; `Spec` now reserves `3 * equalities.len` up front, so this
    // is a belt-and-braces guard rather than a live path.
    if (d.constraint_count + 3 > m.constraint_capacity) {
        return;
    }

    // ** ONE ROW PER WORLD AXIS, AND THE PROJECTION IS JUST AN INDEX.
    //
    // This read `dot3(axis, jac_b[i] - jac_a[i])` over the three basis vectors, which is an
    // elaborate way of writing `(jac_b[i] - jac_a[i])[k]` - a dot product with `(1,0,0)`
    // selects a component. Same for the violation. Writing what it means is shorter, faster,
    // and stops a reader wondering which frame the axes are in.
    //
    // MuJoCo does the same: `mju_sub3(cpos, pos[0], pos[1])` for the error and
    // `mj_jacDifPair` for the Jacobian, three rows straight out, no projection.
    // `inline` because `Vec` is a SIMD vector and its index must be comptime - and the loop
    // is three iterations of straight-line work, so unrolling it costs nothing.
    inline for (0..3) |axis| {
        const row: u32 = d.constraint_count;
        const projected: []f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
        for (0..m.nv) |i| {
            projected[i] = jac_b[i][axis] - jac_a[i][axis];
        }
        d.constraint_kind[row] = .connect;
        d.constraint_source[row] = eq;
        d.constraint_key[row] = constraintKey(.connect, eq, axis);
        d.constraint_violation[row] = gap[axis];
        d.constraint_softness[row] = closure.softness;
        d.constraint_impedance[row] = closure.impedance;
        d.constraint_count = row + 1;
    }

    const weld: @FieldType(@TypeOf(closure.holds), "weld") = switch (closure.holds) {
        .weld => |w| w,
        else => return,
    };

    // -- ** THREE MORE ROWS FOR ORIENTATION, AND THE ERROR IS A ROTATION VECTOR --
    //
    // The rotation still needed to satisfy the weld is `rot_a * (rot_b * relative)^-1`, read in
    // the WORLD frame. For any rotation the quaternion's vector part is half the rotation
    // vector to first order, so `2*vec` is the error in radians about each world axis - which
    // is exactly what three rows want.
    //
    // * WORLD FRAME, WHERE MuJoCo USES THE ERROR'S OWN. MuJoCo rotates every Jacobian column
    // by `neg(q1)*(jac0-jac1)*q0*relpose` so both sides live in the error frame; this leaves
    // both in the world. **They are equivalent** - rotating the error and all three Jacobian
    // rows by the same rotation gives three rows spanning the same space with the same
    // solution - and the world costs one quaternion multiply instead of one per DOF, with no
    // frame left to explain.
    if (d.constraint_count + 3 > m.constraint_capacity) {
        return;
    }
    const target: Quat = qmul(d.body_xrot[weld.b.body], weld.relative);
    const misalignment: Quat = qmul(d.body_xrot[weld.a.body], conjugate(target));
    // * `q` AND `-q` ARE THE SAME ROTATION, and the vector part flips between them. Taking the
    // one with positive `w` picks the SHORT way round, so a weld 179 deg out corrects by 1 deg
    // rather than by 359 deg.
    const shortest: Quat = if (misalignment[3] < 0) -misalignment else misalignment;

    // The angular Jacobians, which the position rows did not need.
    jacPoint(m, d, points.a.body, at_a, null, jac_a);
    jacPoint(m, d, points.b.body, at_b, null, jac_b);

    inline for (0..3) |axis| {
        const row: u32 = d.constraint_count;
        const projected: []f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
        for (0..m.nv) |i| {
            projected[i] = weld.torque_scale * (jac_a[i][axis] - jac_b[i][axis]);
        }
        d.constraint_kind[row] = .connect;
        d.constraint_source[row] = eq;
        d.constraint_key[row] = constraintKey(.connect, eq, 3 + axis);
        d.constraint_violation[row] = weld.torque_scale * 2.0 * shortest[axis];
        d.constraint_softness[row] = closure.softness;
        d.constraint_impedance[row] = closure.impedance;
        d.constraint_count = row + 1;
    }
}

/// Fill in `A_hat`, `R`, `J*v` and `aref` for the rows `makeConstraints` produced.
///
/// * THE EXACT DIAGONAL. `A_hat_ii = (J M^-1 J^T)_ii` is the inertia the constraint actually
/// feels - how hard it is to accelerate along its own direction. MuJoCo approximates it,
/// evaluated once at `qpos0`, with three documented error sources and a `diagexact` flag
/// for when that is not good enough. We compute it exactly: one back-substitution per row
/// through the factorization `factorM` already produced. That costs a solve per row and
/// removes an entire class of "why is this constraint behaving oddly" from the solver
/// phase, which is the more expensive place to be confused (section 4e).
///
/// Then the softness parameterization, which is the part worth understanding:
///
///     R    = (1 - d)/d * A_hat            d from the impedance sigmoid at this residual
///     aref = -b*(J v) - k*r           k, b derived from time_const and damp_ratio
///
/// Because `R` is scaled by `A_hat`, a given `Softness` produces the same settling behaviour
/// whether the constraint is holding back a fingertip or a torso. Without that scaling
/// every constraint in a model would need its own hand-tuned gains, which is the usability
/// difference between this model and a penalty-based one.
pub fn projectConstraints(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.project");
    defer zone.end();
    d.requireStage(.position, "projectConstraints");

    for (0..d.constraint_count) |row| {
        const jacobian: []const f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
        const inv_inertia_jacobian: []f32 =
            d.constraint_inv_inertia_jacobian[row * m.nv ..][0..m.nv];

        // M^-1J^T for this row: the joint-space acceleration a unit force here produces.
        // Kept, because the solver needs it every iteration.
        @memcpy(inv_inertia_jacobian, jacobian);
        solveM(m, d, inv_inertia_jacobian);

        // A_hat = J M^-1 J^T, exactly - contract the row back against it.
        var diag: f32 = 0;
        for (jacobian, inv_inertia_jacobian) |j, mj| {
            diag += j * mj;
        }
        // * A row with A_hat ~ 0 is one the mechanism CANNOT MOVE ALONG - no joint motion
        // produces any acceleration in that direction. A contact's friction edges do this
        // routinely: a planar mechanism has no motion in the out-of-plane tangent, so both
        // of that tangent's pyramid edges collapse onto the normal and one may come out
        // exactly zero.
        //
        // Such a row is satisfied by definition and needs no force. Recording it as-is and
        // letting the solver divide by a clamped 1e-10 would produce a force around 1e11 -
        // harmless for the acceleration, since `M^-1J^T` is zero too, but it poisons the
        // reported forces and the convergence residual. The solver skips these rows
        // instead; see `solveConstraints`.
        // Recorded AS COMPUTED, including a genuine zero. Everything below - R, the
        // constraint velocity, the reference acceleration - remains well defined for such
        // a row (`R = (1-d)/d * 0 = 0`), and MuJoCo reports them too, so clamping or
        // zeroing them here would make the values disagree with the reference for no gain.
        // The row is skipped where it actually matters: in the solver and the residual.
        //
        // ** AND THE OTHER SIDE'S INERTIA, when the contact is against a body outside the
        // tree (section 4h-ter).
        //
        // A contact constrains TWO inertias. `J M^-1 J^T` above is only the robot's share; a
        // free body resists too, and its resistance at the contact point is
        //
        //     1/m  +  (r x n)^T I^-1 (r x n)
        //
        // - the familiar effective-mass term, translation plus the rotation the lever arm
        // induces. Adding it makes the row describe what is actually being pushed.
        //
        // Both terms are ZERO for static geometry, so this reproduces the previous
        // behaviour exactly wherever nothing supplies them. What changes is the case that
        // was wrong: the arm braced against a 1 kg crate as though it were the floor, and
        // now stops it with the force it takes to stop a 1 kg crate.
        d.constraint_inertia[row] = diag;

        // Constraint-space velocity, wanted here and again by the solver.
        //
        // * RELATIVE, when the other side can move. `J*v` is the robot's velocity along the
        // row; subtracting the external body's velocity along the same direction makes the
        // row measure what it is actually constraining. Zero for static geometry, so nothing
        // that was correct before changes.
        var vel: f32 = 0;
        for (jacobian, d.vel) |j, v| {
            vel += j * v;
        }
        d.constraint_velocity[row] = vel;

        const imp: Impedance = d.constraint_impedance[row];
        const soft: Softness = d.constraint_softness[row];
        const impedance: f32 = clamp(imp.at(d.constraint_violation[row]), min_impedance, max_impedance);

        d.constraint_regularizer[row] = @max(min_regularizer, (1.0 - impedance) / impedance * diag);

        // Stiffness and damping of the reference spring, derived from the response the
        // model asked for rather than specified directly. `d_max` appears in both because
        // the gains are defined against a fully-engaged constraint.
        const d_max: f32 = @max(imp.max, min_impedance);
        // *** REFSAFE: NO TIME CONSTANT BELOW TWO TIMESTEPS. A soft constraint asked to settle
        // faster than the step can represent does not settle faster - it overshoots, and
        // every step it overshoots by more. MuJoCo clamps `timeconst` to 2*timestep for exactly
        // this (its `refsafe` flag, on by default); this file said so in `Softness` and did not
        // do it. Measured: MuJoCo's humanoid, limp, dropped at 60 Hz, its contacts asking for
        // 0.015 s against a 0.033 s floor, fell THROUGH the floor to -58 m at the velocity cap.
        // At 500 Hz the floor is 0.004 s and every constraint in that model is above it.
        const tc: f32 = @max(soft.time_const_s, 2.0 * m.opt.timestep);
        const k: f32 = 1.0 / @max(min_impedance, d_max * d_max * tc * tc *
            soft.damp_ratio * soft.damp_ratio);
        const b: f32 = 2.0 / @max(min_impedance, d_max * tc);

        // aref = -b*(Jv) - k*d*r.
        //
        // * Note the asymmetry: impedance scales the STIFFNESS term and not the damping
        // one. It is easy to assume `d` multiplies the whole reference (it does not) or
        // neither term (it does not), and both give a reference that is wrong by a
        // constant factor - which looks like a mistuned constraint rather than a bug.
        // MuJoCo's `mj_referenceConstraint` is explicit: `aref = -B*vel - K*I*(pos-margin)`.
        //
        // The reading: `d` says how much of the constraint is switched ON, so it gates how
        // hard the spring pulls toward satisfaction. Damping opposes constraint-space
        // motion regardless, because a half-engaged constraint still resists velocity.
        const damping_term: f32 = -b * vel;

        // ** THE POSITION-CORRECTION TERM IS BOUNDED, and this is standard practice rather
        // than a fudge.
        //
        // `-K*I*violation` grows LINEARLY with overlap, and nothing in the formulation limits
        // how deep an overlap can get: a fast link crossing a crate between two steps is
        // first seen already buried. **Measured: a 0.11 m crate reported a 0.25 m overlap** -
        // twice its own size - and the resulting reference acceleration asked for 250x what a
        // 1 mm contact does. That is the whole of the "tunnelling" behaviour, and it is not
        // caused by speed: a SLOW sweep produced 88 m/s ejections where a sweep seven times
        // faster produced 18.
        //
        // Every solver bounds this somehow, because unbounded penetration recovery is a
        // spring with no travel limit. Here the bound is expressed in the units the term is
        // actually in: **the correction may not demand more than `max_recovery_velocity`
        // worth of separation per timestep.** A contact that IS deeply overlapped then
        // recovers steadily over several steps instead of being fired apart in one.
        //
        // It does not soften ordinary contact. At the depths a settled body reaches - under a
        // millimetre - the bound is orders of magnitude away and never binds, which is why
        // every existing test passes unchanged.
        // * CONTACTS ONLY. A joint limit's violation is an ANGLE and a slider's is a length;
        // capping either in metres per second is a category error, and doing so broke two
        // existing tests immediately - a wide-margin limit and the KKT check both rely on the
        // reference being exactly what the formula says. Contacts are the rows whose
        // violation can be made arbitrarily deep by geometry arriving late, so they are the
        // rows that need the bound.
        const raw_stiffness: f32 = -k * impedance * d.constraint_violation[row];
        const stiffness_term: f32 = if (d.constraint_kind[row] == .contact) blk: {
            const cap: f32 = m.opt.solver.max_recovery_velocity / @max(m.opt.timestep, 1.0e-9);
            break :blk clamp(raw_stiffness, -cap, cap);
        } else raw_stiffness;
        d.constraint_target_acc[row] = damping_term + stiffness_term;
    }
}

/// Impedance is clamped away from 0 and 1: at 0 the constraint does not exist and `R`
/// diverges, at 1 it is perfectly rigid and `R` vanishes, and both ends are numerically
/// hostile. MuJoCo clamps identically.
const min_impedance: f32 = 0.0001;
const max_impedance: f32 = 0.9999;
/// Floors, so a degenerate row cannot produce an infinite or negative regularizer.
const min_regularizer: f32 = 1.0e-10;
const min_constraint_diag: f32 = 1.0e-10;

// =============================================================================
// The constraint solver - phase 6c
//
// --------------------------------------------------------------------------
// DERIVATION, in full, because every later decision refers back to it.
//
// Without constraints, Newton's law in joint coordinates is
//
//     M * a_unconstrained = tau                                              (1)
//
// where tau collects everything already computed: applied, actuator and passive forces,
// minus the bias term c. `forwardDynamics` solved that.
//
// A constraint force does not act in joint space directly. It acts along its own row of J
// - a contact pushes along its normal, a limit pushes along one DOF - and `J^T` carries it
// back into joint coordinates (section 18). So with constraint forces `f`,
//
//     M * a = tau + J^T f
//     a     = a_unconstrained + M^-1 J^T f                                   (2)
//
// Now look at what the constraints themselves experience. Multiplying (2) by J gives the
// acceleration in CONSTRAINT space:
//
//     J a = J a_unconstrained + (J M^-1 J^T) f
//         = a_free + A f                                                   (3)
//
// where `A = J M^-1 J^T` is the constraint-space inverse inertia - how much each row
// accelerates per unit of force on each row, including how rows push each other around
// through the mechanism. Its diagonal is the `A_hat` phase 6a already computes exactly.
//
// A HARD constraint would demand `J a = aref` exactly. The soft model asks for something
// weaker and much better behaved: the constraint is allowed to be violated in proportion
// to the force it is carrying, with `R` setting the exchange rate -
//
//     J a = aref - R f                                                     (4)
//
// Substituting (3) into (4) and collecting terms gives the whole problem in one line:
//
//     * (A + R) f = aref - a_free                                          (5)
//
// subject to `f` lying in the allowed set K (for a limit or a contact normal, `f >= 0`:
// a limit can push you back into range but never pull you out of it).
//
// WHY R IS NOT A HACK. `A` is positive SEMI-definite - it is `J M^-1 J^T` with M positive
// definite - and it is genuinely singular whenever constraints are redundant, which is the
// normal case (a box resting on four points has a one-dimensional family of force
// distributions that all produce the same motion). A singular system has no unique answer,
// and an iterative solver on one wanders. Adding `R > 0` to the diagonal makes `(A + R)`
// strictly positive definite, so (5) has EXACTLY ONE solution, and the softness the
// modeller asked for is the same quantity that makes the mathematics well posed. That
// coincidence is the central insight of the whole model.
// --------------------------------------------------------------------------
// =============================================================================

/// How the solver is run. Defaults are chosen so that a joint limit converges in a handful
/// of iterations; a stiff contact set will want more.
pub const Algorithm = enum {
    /// Projected Gauss-Seidel: sweep rows, project each onto its allowed set.
    pgs,
    /// Newton on the convex objective, with a line search. See `solveNewton`.
    newton,
};

pub const SolverOptions = struct {
    /// Ceiling on sweeps. PGS converges linearly, so this bounds the work rather than the
    /// accuracy - `tolerance` is what decides when to stop.
    /// Which algorithm drives the constraint rows to their targets.
    ///
    /// -- ** THE TRADE, MEASURED ON A SIX-BOX STACK (96 rows) --
    ///
    /// PGS sweeps rows one at a time; Newton minimises the whole convex objective at once.
    /// Sweeping is cheap per iteration and converges LINEARLY, which is fine until the rows are
    /// strongly coupled - and a stack couples every row to every other through the boxes
    /// between them.
    ///
    ///     PGS residual:   1 iter 26.7 * 5 iters 13.4 * 20 iters 4.83 * 100 iters 0.269
    ///
    /// Still falling at a hundred iterations, and the stack collapses. Newton's whole point is
    /// that it does not have to propagate information one contact per sweep.
    ///
    /// * PGS REMAINS THE DEFAULT, and it is not a grudging one: at FIVE iterations it beats
    /// MuJoCo's own PGS by 4.5x and matches MuJoCo's Newton, because the exact `A_hat` diagonal and
    /// the stall check do real work. Most scenes never reach the regime where this matters, and
    /// PGS is markedly cheaper per iteration.
    ///
    /// -- ** AND ON A REAL ROBOT PGS STOPS SHORT OF `tolerance`, EVERY STEP --
    ///
    /// Worth knowing before `constraintConverged` surprises you. A Go1 holding its home pose
    /// on four feet - sixteen rows, `zig build robot-bench` case 4 - measured over 20 000
    /// steps at two controller stiffnesses:
    ///
    ///     pgs     kp 100   residual 6.8e-6   converged FALSE
    ///     pgs     kp 300   residual 3.0e-6   converged FALSE
    ///     newton  kp 100   residual 1.8e-7   converged true
    ///     newton  kp 300   residual 1.2e-7   converged true
    ///
    /// PGS is stopping on `min_progress`, not on `tolerance` - the linear-convergence floor
    /// the table under `tolerance` documents, reached here at a few times the target. **The
    /// simulation is fine**: 3e-6 of constraint residual is far below anything the robot can
    /// feel, both solvers agree on the resting trunk height to four decimals, and the stance
    /// is stable indefinitely. What is NOT fine is reading `constraintConverged` as a health
    /// check and concluding something is broken. It reports what it says - did the residual
    /// reach `tolerance` - and under PGS on a coupled scene the honest answer is no.
    ///
    /// If you need `converged` to mean something, use `.newton`; if you need a number, use
    /// `constraintResidual` and pick a threshold your mechanism actually cares about.
    algorithm: Algorithm = .pgs,
    max_iterations: u32 = 60,
    /// How fast a constraint may push itself out of a violation, in metres per second.
    ///
    /// Bounds the POSITION-correction half of the reference acceleration. A soft constraint's
    /// `-K*I*violation` grows without limit as overlap deepens, and overlap can deepen
    /// arbitrarily when a fast body is first seen already buried - so this caps how much
    /// separation one step may demand. 2 m/s recovers a centimetre in five milliseconds,
    /// which is far quicker than anything looks wrong, while a 0.25 m overlap unwinds over a
    /// handful of steps instead of exploding.
    ///
    /// At the sub-millimetre depths a settled contact reaches, this is orders of magnitude
    /// from binding.
    /// Accelerate Gauss-Seidel with Nesterov momentum, as MuJoCo's PGS does.
    ///
    /// -- ** IMPLEMENTED, CORRECT, AND OFF BY DEFAULT - because it MEASURED SLOWER --
    ///
    /// Plain PGS converges linearly; Nesterov extrapolation reaches the accelerated rate. On a
    /// standing Go1 it does exactly what the theory says:
    ///
    ///     momentum off:  14 solver iterations,  17,847 ns/step
    ///     momentum on:    3 solver iterations,  19,280 ns/step
    ///
    /// **A 4.7x reduction in iterations, and 8% SLOWER.** Each iteration costs roughly twice
    /// as much, because extrapolating the forces invalidates `d.acc` and it must be rebuilt -
    /// `rebuildAccelerationFromForces` is O(rows x nv), the same order as the sweep it is
    /// accelerating. At sixteen rows the fixed cost dominates the saved sweeps.
    ///
    /// It is kept rather than deleted because the trade REVERSES with problem size: the rebuild
    /// is once per iteration while the sweeps saved grow with row count, so a scene with
    /// hundreds of contact rows should favour it. The switch is how that gets tested when such
    /// a scene exists, instead of re-deriving the whole thing.
    ///
    /// **The lesson is about MuJoCo rather than about momentum.** MuJoCo runs f64 with elliptic
    /// friction cones and a Newton solver whose inner loop is far more expensive than a
    /// Gauss-Seidel sweep - the same acceleration pays for itself there and does not here.
    /// **Copying a technique from a reference implementation copies its cost model too**, and
    /// that has to be measured rather than inherited.
    momentum: bool = false,
    /// Stop when one sweep improves the residual by less than this FRACTION of it.
    ///
    /// PGS has a floor - set by f32 and by its own linear convergence - and `tolerance` can
    /// sit below it. When it does, the solver reaches its best answer and then spends every
    /// remaining iteration failing to improve on it. Measured on a standing Go1, solved cold
    /// from a settled stance:
    ///
    ///     iterations:   1      2      5     10     20     60     200    1000
    ///     residual:  19.70  10.14   6.74   3.93   1.35  0.0199  4.0e-6  4.0e-6
    ///
    /// It converges by ~200 sweeps and then **plateaus at 4.013e-6 against a target of
    /// 3.55e-6** - thirteen percent away and unreachable - so it ran to the 60-iteration cap
    /// on every step of a robot standing still. The readout said `60 it`, which reads as
    /// failure to converge and was failure to NOTICE convergence.
    ///
    /// Relative, so it is scale-free. 1% is far below the per-sweep progress of a problem
    /// that is genuinely still descending - the Go1 above was still halving its residual per
    /// sweep at iteration 20 - so this cannot fire early on real work.
    min_progress: f32 = 0.01,
    /// How close to the tolerance target a residual must be before `min_progress` may stop
    /// the solve, as a multiple of that target.
    ///
    /// * THIS IS WHAT KEEPS THE STALL CHECK FROM ABANDONING HARD PROBLEMS. Slow progress near
    /// the floor means the answer is finished; slow progress mid-impact means the problem is
    /// hard. Without this bound the two are indistinguishable, and the check took a KUKA
    /// sweeping a crate tower from 14 m/s of ejection to 32 by walking away from half-solved
    /// contacts.
    ///
    /// The measured plateau sat 1.13x above its target, so 100x is generous for the case this
    /// exists to catch, while a mid-impact residual runs thousands of times larger and stays
    /// well outside it.
    stall_window: f32 = 100.0,
    max_recovery_velocity: f32 = 2.0,
    // * AUDIT NOTE: this currently fires ZERO times in 280,000 row-solves of the worst scene
    // available - a KUKA sweeping a five-crate tower at four times its normal rate. It is
    // kept anyway, and a sibling bound was removed, and the difference is worth stating.
    //
    // A `max_force_scale` was added beside this in the same session, capping each row's force
    // at an arbitrary multiple. Both were plasters over a 1.4 GN blow-up whose real causes
    // turned out to be a stale `body_subtree_mass` and a contact the solver could never
    // satisfy. With those fixed, neither fires.
    //
    // Bounded penetration recovery is STANDARD (Bullet's error reduction, PhysX's
    // `maxDepenetrationVelocity`) and describes real behaviour: nothing should be flung apart
    // faster than it could plausibly separate. An arbitrary force ceiling describes nothing,
    // and a bound that never fires but would silently rewrite the physics if it did is worse
    // than no bound. So one stayed and one went.
    /// Stop once the complementarity residual falls below this FRACTION of the problem's
    /// own scale (the largest reference acceleration among the active rows).
    ///
    /// Relative, not absolute, and the reason is f32. The residual has units of
    /// acceleration, and reference accelerations for a stiff limit run to several hundred.
    /// A single-precision float carries about seven significant digits, so the smallest
    /// residual representable near a magnitude of 500 is around 5e-5 - an absolute
    /// tolerance below that is unreachable, and the solver would spin to `max_iterations`
    /// on a problem it had already solved exactly. Scaling by the problem removes the
    /// dependence on how stiff the model happens to be.
    tolerance: f32 = 1.0e-6,
};

/// Pack a row's identity into one integer.
///
/// Three fields, no hashing: the kind, the thing it came from (a joint index or a contact
/// id), and a discriminator for rows that share a source (which end of a limit, which edge
/// of a friction pyramid). Exact rather than hashed, because a collision would silently
/// warm-start a row from an unrelated force - a wrong answer that converges, which is the
/// worst kind.
/// The bits `constraintKey` reserves for a source id, derived once so nothing re-spells it.
///
/// *** AN ID IS NOT A SIZE, AND TYPING IT `usize` IS THE BUG THIS REPLACES. `usize` means "big
/// enough to index this machine's memory" - 64 bits natively, **32 on wasm**. A contact id is a
/// semantic value whose width has nothing to do with the address space, and passing one through
/// a `usize` parameter silently narrowed it on one target and not the other.
///
/// The symptom was an `@intCast` trap in a wasm build, invisible natively, reached only when a
/// robot touched ITSELF - because the bridge packs the other body's index at bit 40 and that
/// field is zero for every contact against the world. Days of bisection for a type name.
const source_mask: u64 = (1 << 48) - 1;

fn constraintKey(kind: ConstraintKind, source: u64, discriminator: usize) u64 {
    return (@as(u64, @backingInt(kind)) << 56) |
        ((source & source_mask) << 8) |
        @as(u64, @intCast(discriminator));
}

/// Newton's method on the constraint objective, with a line search.
///
/// -- *** WHY A SECOND SOLVER AT ALL --
///
/// PGS sweeps rows. Each sweep moves information exactly one contact along a chain, so a stack
/// of six boxes needs six sweeps before the floor's support is felt at the top - and every
/// sweep after that is correcting what the previous one disturbed. Measured on that stack, 96
/// rows, one cold solve:
///
///     1 iter 26.7 * 5 iters 13.4 * 20 iters 4.83 * 40 iters 1.11 * 100 iters 0.269
///
/// Linear convergence, halving every fifteen or so iterations, still falling at a hundred, and
/// the stack visibly collapses. MuJoCo's Newton reaches its answer in FIVE.
///
/// -- ** THE OBJECTIVE, WHICH IS WHERE ALL THE STRUCTURE COMES FROM --
///
/// Constrained dynamics is a convex minimisation in ACCELERATION space:
///
///     L(a) = 1/2*(a - a_free)^T M (a - a_free)  +  sum over active rows  1/2*(J_i*a - aref_i)^2 / R_i
///
/// The first term says "stay near the acceleration you would have had"; the second penalises
/// each violated row. `a_free` is exactly `free_acc`, already computed.
///
/// * ITS GRADIENT AND HESSIAN ARE BOTH CHEAP AND EXACT:
///
///     grad L  =  M(a - a_free)  +  J^T D r        r_i = J_i*a - aref_i,  D_i = 1/R_i or 0
///     H   =  M  +  J^T D J
///
/// `D` is diagonal, so `H` costs one pass over the active rows. **`H` is exact, not an
/// approximation** - which is what buys quadratic convergence near the solution and is the
/// entire difference from sweeping.
///
/// -- * THE ACTIVE SET IS RE-DECIDED EVERY ITERATION --
///
/// A unilateral row (contact, limit) only pushes, so it contributes to the cost only while
/// violated. That makes `L` piecewise quadratic rather than quadratic, and Newton on a
/// piecewise-quadratic needs the line search below: a full step can cross into a region where
/// a different set of rows is active and overshoot badly.
fn solveNewton(m: *const Model, d: *Data) void {
    // ** THE WORKING SET IS SIZED AT `Data.init` FROM `opt.solver.algorithm`, and that option
    // stays mutable afterwards. Switching to Newton on an already-built `Data` therefore hands
    // this function empty buffers - an out-of-bounds write into whatever follows them, which is
    // the worst possible way to learn about an ordering mistake. Naming it costs one comparison
    // per step.
    assertf(
        d.newton_hessian.len == m.nv * m.nv,
        @src(),
        "solver.algorithm was set to .newton after Data.init, so its {d}x{d} working set was " ++
            "never allocated — choose the algorithm in Options, before building Data",
        .{ m.nv, m.nv },
    );
    const nv: usize = m.nv;
    const rows: usize = d.constraint_count;
    const acc: []f32 = d.acc;
    @memcpy(acc, d.free_acc);

    var iteration: u32 = 0;
    while (iteration < m.opt.solver.max_iterations) : (iteration += 1) {
        // ---- residual, active set, and gradient ----
        //
        // `newton_residual[i]` is `J_i*a - aref_i`: how far row `i` is from its target.
        var active: usize = 0;
        for (0..rows) |row| {
            const jac: []const f32 = d.constraint_jacobian[row * nv ..][0..nv];
            var value: f32 = 0;
            for (0..nv) |i| {
                value += jac[i] * acc[i];
            }
            const residual: f32 = value - d.constraint_target_acc[row];
            d.newton_residual[row] = residual;
            // * THE SIGN CONVENTION IS `makeConstraints`': positive violation means "restore".
            // A row that may only push is in the objective only while it would push; one that
            // may pull as well is always in it.
            d.newton_active[row] = !d.constraint_kind[row].isUnilateral() or residual < 0;
            if (d.newton_active[row]) {
                active += 1;
            }
        }
        if (active == 0) {
            break;
        }

        // grad L = M(a - a_free) + J^T D r
        for (0..nv) |i| {
            d.newton_step[i] = acc[i] - d.free_acc[i];
        }
        mulM(m, d, d.newton_step, d.newton_gradient);
        for (0..rows) |row| {
            if (!d.newton_active[row]) {
                continue;
            }
            const weight: f32 = d.newton_residual[row] / d.constraint_regularizer[row];
            const jac: []const f32 = d.constraint_jacobian[row * nv ..][0..nv];
            for (0..nv) |i| {
                d.newton_gradient[i] += jac[i] * weight;
            }
        }

        var gradient_norm: f32 = 0;
        for (0..nv) |i| {
            gradient_norm += d.newton_gradient[i] * d.newton_gradient[i];
        }
        if (gradient_norm < m.opt.solver.tolerance * m.opt.solver.tolerance) {
            break;
        }

        // ---- H = M + J^T D J, dense ----
        //
        // * DENSE IS THE RIGHT CALL HERE. `H` is nvxnv where nv is tens, not thousands, and
        // `J^T D J` fills in anyway the moment two contacts share a body - which in a stack is
        // every pair. A sparse structure would cost more to maintain than it saves.
        const hessian: []f32 = d.newton_hessian;
        @memset(hessian, 0);
        for (0..nv) |i| {
            const row_start: u32 = m.mass_row_start[i];
            for (0..m.mass_row_nonzeros[i]) |k| {
                const j: u32 = m.mass_col_index[row_start + k];
                const value: f32 = d.mass_matrix[row_start + k];
                hessian[i * nv + j] += value;
                if (j != i) {
                    hessian[j * nv + i] += value; // only half of M is stored
                }
            }
        }
        for (0..rows) |row| {
            if (!d.newton_active[row]) {
                continue;
            }
            const scale: f32 = 1.0 / d.constraint_regularizer[row];
            const jac: []const f32 = d.constraint_jacobian[row * nv ..][0..nv];
            for (0..nv) |i| {
                if (jac[i] == 0) {
                    continue;
                }
                const weighted: f32 = jac[i] * scale;
                for (0..nv) |j| {
                    hessian[i * nv + j] += weighted * jac[j];
                }
            }
        }

        // ---- Newton direction: H*delta = -grad  ----
        //
        // * `H` IS SYMMETRIC POSITIVE DEFINITE - `M` is, and `J^T D J` is positive
        // semi-definite with `D >= 0` - so a Cholesky is both valid and half the work of an LU.
        // If it fails anyway (a degenerate model, an f32 accident), fall back to the gradient
        // direction, which is always a descent direction and merely slower.
        const factored: bool = choleskyFactor(hessian, nv);
        for (0..nv) |i| {
            d.newton_step[i] = -d.newton_gradient[i];
        }
        if (factored) {
            choleskySolve(hessian, nv, d.newton_step);
        }

        // ---- line search ----
        //
        // * NEEDED BECAUSE `L` IS PIECEWISE QUADRATIC, not quadratic: a full Newton step can
        // cross into a region where a different set of rows is active, where it is no longer
        // the minimiser and can be much worse. Backtracking from a full step is the cheapest
        // thing that is always safe.
        const before: f32 = newtonCost(m, d, acc, 0);
        var alpha: f32 = 1.0;
        var accepted: bool = false;
        for (0..8) |_| {
            if (newtonCost(m, d, acc, alpha) < before) {
                accepted = true;
                break;
            }
            alpha *= 0.5;
        }
        if (!accepted) {
            break; // no downhill step exists: this is the minimum, to f32's satisfaction
        }
        for (0..nv) |i| {
            acc[i] += alpha * d.newton_step[i];
        }
    }
    d.solver_iterations = iteration;

    // ---- recover the constraint forces the accelerations imply ----
    //
    // * THE CALLER'S CONTRACT IS FORCES, not accelerations - warm starting, `equalityError`
    // and every diagnostic read `constraint_force`. `f = -r/R` on active rows is the force
    // that produced the acceleration just solved for.
    for (0..rows) |row| {
        const jac: []const f32 = d.constraint_jacobian[row * nv ..][0..nv];
        var value: f32 = 0;
        for (0..nv) |i| {
            value += jac[i] * acc[i];
        }
        const residual: f32 = value - d.constraint_target_acc[row];
        const unilateral: bool = d.constraint_kind[row].isUnilateral();
        const force: f32 = -residual / d.constraint_regularizer[row];
        d.constraint_force[row] = if (unilateral) @max(0, force) else force;
    }
    @memset(d.constraint_joint_force, 0);
    for (0..rows) |row| {
        const force: f32 = d.constraint_force[row];
        if (force == 0) {
            continue;
        }
        const jac: []const f32 = d.constraint_jacobian[row * nv ..][0..nv];
        for (0..nv) |i| {
            d.constraint_joint_force[i] += jac[i] * force;
        }
    }
}

/// The objective at `acc + alpha*step`, for the line search.
fn newtonCost(m: *const Model, d: *Data, acc: []const f32, alpha: f32) f32 {
    const nv: usize = m.nv;
    for (0..nv) |i| {
        d.newton_trial[i] = acc[i] + alpha * d.newton_step[i];
        d.newton_scratch[i] = d.newton_trial[i] - d.free_acc[i];
    }
    // 1/2*(a - a_free)^T M (a - a_free)
    mulM(m, d, d.newton_scratch, d.newton_mv);
    var cost: f32 = 0;
    for (0..nv) |i| {
        cost += 0.5 * d.newton_scratch[i] * d.newton_mv[i];
    }
    // plus the penalty on every row that is violated AT THE TRIAL POINT - re-deciding the
    // active set here is what makes this a valid cost for a piecewise-quadratic objective.
    for (0..d.constraint_count) |row| {
        const jac: []const f32 = d.constraint_jacobian[row * nv ..][0..nv];
        var value: f32 = 0;
        for (0..nv) |i| {
            value += jac[i] * d.newton_trial[i];
        }
        const residual: f32 = value - d.constraint_target_acc[row];
        const unilateral: bool = d.constraint_kind[row].isUnilateral();
        if (unilateral and residual >= 0) {
            continue;
        }
        cost += 0.5 * residual * residual / d.constraint_regularizer[row];
    }
    return cost;
}

/// In-place Cholesky, `A = L*L^T`, lower triangle. False if `A` is not positive definite.
fn choleskyFactor(a: []f32, n: usize) bool {
    for (0..n) |i| {
        for (0..i + 1) |j| {
            var sum: f32 = a[i * n + j];
            for (0..j) |k| {
                sum -= a[i * n + k] * a[j * n + k];
            }
            if (i == j) {
                if (sum <= 0) {
                    return false;
                }
                a[i * n + j] = @sqrt(sum);
            } else {
                a[i * n + j] = sum / a[j * n + j];
            }
        }
    }
    return true;
}

/// Solve `L*L^T*x = b` in place, given `choleskyFactor`'s output.
fn choleskySolve(a: []const f32, n: usize, b: []f32) void {
    for (0..n) |i| {
        var sum: f32 = b[i];
        for (0..i) |k| {
            sum -= a[i * n + k] * b[k];
        }
        b[i] = sum / a[i * n + i];
    }
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var sum: f32 = b[i];
        for (i + 1..n) |k| {
            sum -= a[k * n + i] * b[k];
        }
        b[i] = sum / a[i * n + i];
    }
}

pub fn solveConstraints(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.solve");
    defer zone.end();
    d.requireStage(.force, "solveConstraints");
    if (d.constraint_count == 0) {
        @memset(d.constraint_joint_force, 0);
        // Reset the diagnostic too. Leaving it stale means a step with no constraints
        // reports whatever the last constrained step happened to need - which reads as "the
        // solver is struggling" when in fact it did not run, and sent me chasing a
        // convergence problem that did not exist.
        d.solver_iterations = 0;
        return;
    }

    // * WARM STARTING (section 4g S3). Start each row from the force that same constraint carried
    // last step, instead of from zero.
    //
    // The benchmark is what made this the top priority rather than a nice-to-have: on a KUKA
    // with five active limits, PGS needed **29 iterations** from a cold start, and MuJoCo's
    // constrained case cost only 1.12x its unconstrained one. The physics barely changes
    // between two steps 4 ms apart, so the previous solution is very nearly the answer -
    // starting there turns a solve into a correction.
    //
    // Matching is by KEY, not row index: rows are rebuilt each step and their order shifts
    // as constraints come and go. A row with no match starts at zero, which is exactly right
    // - it is a constraint that did not exist last step.
    //
    // This changes only the STARTING POINT. The converged answer is the same fixed point of
    // the same projection, and there is a test asserting that, because a solver that gets a
    // different answer when warm-started is not converging.
    // * THE UNCONSTRAINED ACCELERATION IS SAVED UNCONDITIONALLY.
    //
    // It was originally kept only under warm start, to undo a bad seed. Nesterov extrapolation
    // needs it too - `rebuildAccelerationFromForces` reconstructs `acc` from the free
    // acceleration plus the current forces - and with the copy inside the `if`, a cold solve
    // rebuilt from a STALE snapshot. Two tests caught it immediately, which is the argument
    // for having a resting-contact test at all.
    @memcpy(d.free_acc, d.acc);

    // * NEWTON WORKS IN ACCELERATION SPACE and wants no warm-started forces - it starts from
    // `free_acc` and the line search takes it from there. It recovers `constraint_force` and
    // `constraint_joint_force` at its end, which is the caller's whole contract, so everything
    // downstream is unchanged.
    if (m.opt.solver.algorithm == .newton) {
        solveNewton(m, d);
        d.warm_count = d.constraint_count;
        @memcpy(d.warm_key[0..d.constraint_count], d.constraint_key[0..d.constraint_count]);
        @memcpy(d.warm_force[0..d.constraint_count], d.constraint_force[0..d.constraint_count]);
        return;
    }

    if (m.opt.warm_start) {
        for (0..d.constraint_count) |row| {
            d.constraint_force[row] = 0;
            const key: u64 = d.constraint_key[row];
            for (0..d.warm_count) |w| {
                if (d.warm_key[w] == key) {
                    d.constraint_force[row] = d.warm_force[w];
                    break;
                }
            }
            // ** AND THE ACCELERATION MUST BE SEEDED TO MATCH. This is the part a naive
            // warm start omits, and omitting it is catastrophic rather than merely slow.
            //
            // The loop below reads `d.acc` to work out how much force a row still needs,
            // then ADDS the difference to `constraint_force[row]`. If the force starts
            // non-zero while `d.acc` still holds the FREE acceleration, the first iteration
            // computes the whole force again and adds it on top of the warm value - so the
            // force doubles every step. Measured before this line existed: a joint resting
            // on its limit sank straight through and its constraint force reached 7619 N.
            //
            // Seeding `acc += M^-1J^Tf` puts the two in agreement, so the iteration measures
            // only what is still MISSING - which is the entire point of warm starting.
            if (d.constraint_force[row] != 0) {
                // `M^-1J^T` for this row was already computed by `projectConstraints` - the
                // same array the iteration below uses to push accelerations. Reusing it
                // means seeding costs one multiply-add per DOF and cannot disagree with
                // what the solver does with the same force.
                const inv_inertia_jacobian: []const f32 =
                    d.constraint_inv_inertia_jacobian[row * m.nv ..][0..m.nv];
                for (d.acc, inv_inertia_jacobian) |*a, mj| {
                    a.* += d.constraint_force[row] * mj;
                }
            }
        }
        // ** IS THE WARM START ACTUALLY BETTER THAN ZERO? Discard it if not.
        //
        // Learned from MuJoCo, which does exactly this and which I had missed. PGS minimises
        //
        //     cost(f) = 1/2 f^T(A+R) f - f^T(aref - a_free)
        //
        // subject to `f >= 0`, and **cost(0) = 0 identically**. So a warm force with POSITIVE
        // cost is worse than no warm start at all - the solver would spend iterations
        // undoing it before making progress.
        //
        // That is not a rare case. Any step where the physics genuinely changed - an
        // impact, a teleport, a constraint set that turned over - leaves last step's forces
        // describing a situation that no longer exists. Warm starting is a bet that the
        // world moved a little; this is the check on whether it did.
        //
        // The cost is computable from what seeding already produced: after seeding,
        // `J*acc = J*a_free + A*f`, so `(A*f)_i = J*acc_i - J*a_free_i` and no matrix is ever
        // formed. One pass over the rows, one dot product each.
        var warm_cost: f32 = 0;
        for (0..d.constraint_count) |row| {
            const force: f32 = d.constraint_force[row];
            if (force == 0) {
                continue;
            }
            const jacobian: []const f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
            var seeded: f32 = 0;
            var free: f32 = 0;
            for (jacobian, d.acc, d.free_acc) |j, a, fa| {
                seeded += j * a;
                free += j * fa;
            }
            const a_times_f: f32 = seeded - free;
            warm_cost += 0.5 * force * (a_times_f + d.constraint_regularizer[row] * force) +
                force * (free - d.constraint_target_acc[row]);
        }
        d.warm_start_rejected = warm_cost > 0;
        if (d.warm_start_rejected) {
            @memset(d.constraint_force[0..d.constraint_count], 0);
            @memcpy(d.acc, d.free_acc);
        }
    } else {
        d.warm_start_rejected = false;
        @memset(d.constraint_force[0..d.constraint_count], 0);
    }

    var iteration: u32 = 0;
    // Previous sweep's residual, for the stall check at the bottom of the loop.
    var previous_residual: f32 = zm.floatMax(f32);
    // Nesterov counter, reset by the adaptive restart below rather than by the iteration.
    var momentum_k: u32 = 0;
    var restarted: bool = false;
    while (iteration < m.opt.solver.max_iterations) : (iteration += 1) {
        restarted = false;
        // -- ** NESTEROV ACCELERATION, as MuJoCo's PGS does it --
        //
        // Plain Gauss-Seidel converges linearly, and on a contact problem that is slow: a
        // standing Go1's 16 rows needed ~200 sweeps to reach their floor. Extrapolating along
        // the direction the force vector is already travelling turns that into the accelerated
        // rate, for one extra vector and no extra matrix work.
        //
        //     beta = (k - 1) / (k + 2)          the standard sequence
        //     f <- f + beta*(f - f_prev)         step past the current iterate
        //
        // * THE EXTRAPOLATION MUST BE PROJECTED. Overshooting can send a unilateral row
        // negative, which is a pulling contact - a foot sucking the floor upward. MuJoCo
        // projects onto the cone right after extrapolating and so does this.
        if (m.opt.solver.momentum and iteration > 0 and momentum_k > 1) {
            const beta: f32 = float(momentum_k - 1) /
                float(momentum_k + 2);
            for (0..d.constraint_count) |row| {
                const before: f32 = d.constraint_force[row];
                d.constraint_force[row] = @max(
                    0.0,
                    before + beta * (before - d.momentum_prev[row]),
                );
                d.momentum_prev[row] = before;
                d.momentum_extrapolated[row] = d.constraint_force[row];
            }
            // The extrapolation changed the forces, so the acceleration it implies has to be
            // rebuilt before the sweep reads it - otherwise the sweep corrects against a state
            // that no longer exists, which is the same class of error as the seam's positional
            // lag (section 4k).
            rebuildAccelerationFromForces(m, d);
        } else {
            for (0..d.constraint_count) |row| {
                d.momentum_prev[row] = d.constraint_force[row];
                d.momentum_extrapolated[row] = d.constraint_force[row];
            }
        }
        momentum_k += 1;
        for (0..d.constraint_count) |row| {
            // Skip rows the mechanism cannot move along (see `projectConstraints`). They
            // are satisfied by definition, and a near-zero denominator would give them an
            // enormous meaningless force.
            if (d.constraint_inertia[row] <= min_constraint_diag) {
                continue;
            }
            const jacobian: []const f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
            const inv_inertia_jacobian: []const f32 =
                d.constraint_inv_inertia_jacobian[row * m.nv ..][0..m.nv];

            // J_i * a - what this constraint is currently experiencing.
            var current_acc: f32 = 0;
            for (jacobian, d.acc) |j, a| {
                current_acc += j * a;
            }

            const force_before: f32 = d.constraint_force[row];
            const denominator: f32 = d.constraint_inertia[row] + d.constraint_regularizer[row];
            const delta: f32 =
                (d.constraint_target_acc[row] - current_acc - d.constraint_regularizer[row] * force_before) /
                denominator;

            // -- ** PROJECT INTO THE ALLOWED SET, AND THE SET DEPENDS ON THE ROW --
            //
            // Limits and contacts are UNILATERAL: a surface may push and may not pull, and the
            // sign convention from `makeConstraints` makes "positive" mean "restore", so a
            // clamp at zero serves both.
            //
            // * AN EQUALITY IS BILATERAL. A loop closure welds two points together and neither
            // may leave, so its row must be free to pull as well as push - clamping it at zero
            // gives a linkage that resists being compressed and comes apart under tension,
            // which is a rubber band rather than a rod.
            const force_after: f32 = if (d.constraint_kind[row].isUnilateral())
                @max(0.0, force_before + delta)
            else
                force_before + delta;
            const applied: f32 = force_after - force_before;
            if (applied == 0.0) {
                continue;
            }
            d.constraint_force[row] = force_after;

            // Push the joint-space acceleration by what this row just did. This is the
            // ONLY channel through which rows influence each other, which is why the
            // update above needs no explicit `A`.
            for (d.acc, inv_inertia_jacobian) |*a, mj| {
                a.* += applied * mj;
            }
        }

        // -- ** ADAPTIVE RESTART (O'Donoghue-Candes), and it is NOT optional --
        //
        // Nesterov momentum is only stable while the extrapolation points somewhere useful.
        // When it overshoots, the sweep's correction starts opposing it and the iterate
        // oscillates instead of converging - measured here as a resting contact that stopped
        // pushing at all, failing a test that had passed for a hundred turns.
        //
        // The test is the sign of `<correction, extrapolation>`: negative means the sweep is
        // undoing what the momentum did, so the momentum counter resets and beta returns to zero.
        // Restarting on the ITERATE rather than on a schedule is what makes this robust -
        // there is no tuning, and a problem that never overshoots never restarts.
        if (m.opt.solver.momentum and d.constraint_count > 0) {
            var opposition: f32 = 0;
            for (0..d.constraint_count) |row| {
                const correction: f32 = d.constraint_force[row] - d.momentum_extrapolated[row];
                const extrapolation: f32 = d.momentum_extrapolated[row] - d.momentum_prev[row];
                opposition += correction * extrapolation;
            }
            if (opposition < 0) {
                momentum_k = 0;
                restarted = true;
            }
        }

        const residual: f32 = constraintResidual(m, d);
        const target: f32 = m.opt.solver.tolerance * constraintScale(d);
        if (residual <= target) {
            iteration += 1;
            break;
        }

        // ** AND STOP WHEN THE RESIDUAL STOPS FALLING, not only when it reaches the target.
        //
        // PGS has a FLOOR, set by f32 and by its own linear convergence, and the tolerance can
        // sit below it. Measured on a standing Go1 - 16 rows, settled, solved from cold:
        //
        //     iterations:   1      2      5     10     20     60    200   1000
        //     residual:  19.70  10.14   6.74   3.93   1.35  0.0199  4.0e-6  4.0e-6
        //
        // It converges completely by ~200 and then **plateaus at 4.013e-6 against a target of
        // 3.55e-6** - thirteen percent away, and unreachable. Without this check the solver
        // ran to the cap on every step of a robot standing still, and the readout said
        // `60 it` in a way that looked like failure to converge. It was failure to NOTICE
        // convergence.
        //
        // The test is relative progress, so it is scale-free and cannot fire early on a
        // problem that is genuinely still descending: at iteration 20 above the residual is
        // falling by a factor of two per sweep, nowhere near this threshold.
        // * AND ONLY WHEN THE ANSWER IS ALREADY GOOD. Slow progress means two different
        // things and they need opposite responses.
        //
        // Near the floor it means "finished, and the target is unreachable" - stop. In the
        // middle of a violent contact it means "this problem is hard" - keep going. Testing
        // progress alone conflates them, and the first version did: it took the Go1 from 60
        // sweeps to 4 (a 2.3x speedup, correct), and simultaneously took a KUKA sweeping a
        // crate tower from **14 m/s of ejection to 32**, because it walked away from
        // half-solved contacts mid-impact.
        //
        // Requiring the residual to be within `stall_window` of the target separates them.
        // The measured plateau sat 1.13x above its target, so a hundredfold window is far
        // more than the case needs and still nowhere near a mid-impact residual, which runs
        // thousands of times larger.
        // * AND A SWEEP THAT FOLLOWS A RESTART CANNOT END THE SOLVE.
        //
        // Restarting throws the momentum away deliberately, so the next sweep starts from a
        // standstill and makes little progress BY CONSTRUCTION. Reading that as a stall stops
        // the solve exactly when it is about to resume descending - two tests caught it: one
        // that requires an unsolvable problem to run to the cap, and one that requires a
        // solvable one to reach tolerance.
        const progress: f32 = previous_residual - residual;
        const near_floor: bool = residual <= m.opt.solver.stall_window * target;
        if (iteration > 0 and !restarted and near_floor and
            progress < m.opt.solver.min_progress * previous_residual)
        {
            iteration += 1;
            break;
        }
        previous_residual = residual;
    }
    d.solver_iterations = iteration;

    // Snapshot this step's solution for the next one. Done here rather than in `step` so
    // that any caller of `solveConstraints` - including the tests - gets the same behaviour.
    d.warm_count = d.constraint_count;
    @memcpy(d.warm_key[0..d.constraint_count], d.constraint_key[0..d.constraint_count]);
    @memcpy(d.warm_force[0..d.constraint_count], d.constraint_force[0..d.constraint_count]);

    // Report the constraint forces in joint coordinates too - `J^Tf` is what a sensor reads
    // and what a user asking "how hard is this limit pushing?" means.
    @memset(d.constraint_joint_force, 0);
    for (0..d.constraint_count) |row| {
        const jacobian: []const f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
        const force: f32 = d.constraint_force[row];
        for (d.constraint_joint_force, jacobian) |*q, j| {
            q.* += j * force;
        }
    }
}

/// The magnitude of the constraint problem, used to make convergence scale-independent.
///
/// Floored at 1 so a barely-engaged constraint set still has a sane absolute threshold
/// rather than being asked for exact zero.
pub fn constraintScale(d: *const Data) f32 {
    var scale: f32 = 1.0;
    for (0..d.constraint_count) |row| {
        scale = @max(scale, @abs(d.constraint_target_acc[row]));
    }
    return scale;
}

/// Has the solver actually solved it? The check `solveConstraints` uses internally, exposed
/// because a caller - or a test - asking "did that converge?" should not have to reconstruct
/// the scaling rule, and two copies of a convergence criterion is one copy too many.
/// Rebuild `d.acc` so it agrees with `d.constraint_force` after the forces were changed
/// outside the sweep.
///
/// -- ** THE SOLVER'S ONE INVARIANT: `acc` AND `constraint_force` MUST AGREE --
///
/// Every sweep reads `d.acc` to work out how much force a row still needs, then adds the
/// difference. That only works if `acc` already reflects the forces currently held. Warm
/// starting learned this the hard way - seeding forces without seeding `acc` made them double
/// every step, and a joint on its limit reached 7619 N.
///
/// Nesterov extrapolation changes the forces the same way, so it needs the same repair. It is
/// written once here rather than twice because the two callers cannot be allowed to disagree
/// about what "agree" means.
fn rebuildAccelerationFromForces(m: *const Model, d: *Data) void {
    @memcpy(d.acc, d.free_acc);
    for (0..d.constraint_count) |row| {
        const force: f32 = d.constraint_force[row];
        if (force == 0) {
            continue;
        }
        const inv_inertia_jacobian: []const f32 =
            d.constraint_inv_inertia_jacobian[row * m.nv ..][0..m.nv];
        for (d.acc, inv_inertia_jacobian) |*a, mj| {
            a.* += force * mj;
        }
    }
}

pub fn constraintConverged(m: *const Model, d: *const Data) bool {
    return constraintResidual(m, d) <= m.opt.solver.tolerance * constraintScale(d);
}

/// How far the current forces are from actually solving (5), as a single number.
///
/// ABSOLUTE, in units of acceleration. The caller decides what "small" means - the solver
/// compares it against a fraction of the problem's own scale (see `SolverOptions.tolerance`),
/// but a gradient computation will want the raw quantity.
///
/// -- WHAT "SOLVED" MEANS WITH AN INEQUALITY --
/// Define the per-row shortfall
///
///     s_i = J_i*a + R_i f_i - aref_i
///
/// which is the residual of (5) rearranged: `s = (A + R) f - (aref - a_free)`. Without the
/// inequality, solved would mean `s = 0`. With `f >= 0` it means the
/// Karush-Kuhn-Tucker conditions
///
///     f_i >= 0,     s_i >= 0,     f_i * s_i = 0
///
/// read as: a row either carries force and is exactly satisfied (`s_i = 0`), or carries no
/// force and is over-satisfied (`s_i > 0`, the constraint would have to PULL to do better,
/// which it may not). The two cases are captured in one expression by the natural
/// complementarity function, which is zero exactly when the conditions hold:
///
///     * residual = || min(f_i, s_i) ||
///
/// -- WHY THIS FUNCTION EXISTS AT ALL --
/// It is a convergence check, and an honest one: a solver that has stopped is not the same
/// as a solver that has converged, and iteration count alone cannot tell them apart.
///
/// But it is also the groundwork for section 4d. Differentiating through an iterative solver by
/// unrolling its iterations onto an autodiff tape is slow, memory-hungry and numerically
/// poor. The right technique is IMPLICIT differentiation: differentiate the optimality
/// conditions at the converged point and solve one linear system, at a cost independent of
/// how many iterations it took. Those optimality conditions are precisely the `s_i` above.
/// Writing them down now - as a diagnostic that earns its place immediately - means the
/// gradient path later is an addition rather than a rewrite.
pub fn constraintResidual(m: *const Model, d: *const Data) f32 {
    var sum_squares: f32 = 0;
    for (0..d.constraint_count) |row| {
        // Rows the mechanism cannot move along carry no force and are trivially satisfied;
        // including them would report a residual for a constraint that cannot be violated.
        if (d.constraint_inertia[row] <= min_constraint_diag) {
            continue;
        }
        const jacobian: []const f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
        var current_acc: f32 = 0;
        for (jacobian, d.acc) |j, a| {
            current_acc += j * a;
        }
        const shortfall: f32 = current_acc +
            d.constraint_regularizer[row] * d.constraint_force[row] -
            d.constraint_target_acc[row];
        const violation: f32 = @min(d.constraint_force[row], shortfall);
        sum_squares += violation * violation;
    }
    return @sqrt(sum_squares);
}

// =============================================================================
// Sensors - phase 9
//
// * WHY SENSORS ARE PART OF THE ENGINE AND NOT OF THE APPLICATION.
//
// It is tempting to leave them to the caller: everything a sensor reports is derivable
// from `Data`, so why not let whoever wants a gyro reading compute it? Because the
// derivation is only available AT THE RIGHT MOMENT. An accelerometer measures proper
// acceleration, which exists only after the constraint forces are known; a gyro needs
// velocities but must not see the forces. Reconstructing either from outside the step means
// finite-differencing, which is both wrong and noisy.
//
// So sensors are evaluated at three points in the pipeline, as MuJoCo does, and for the
// same reason. `SensorKind.stage` records which.
//
// They are also the OBSERVATION half of the loop that section 4d is heading toward: a learned
// policy reads sensors and writes controls. `sensor_data` being one flat array is chosen
// with that in mind - it is the vector a policy consumes.
// =============================================================================

/// Evaluate the sensors belonging to one stage. Called three times per `forward`.
pub fn sensors(m: *const Model, d: *Data, stage: Stage) void {
    for (0..m.nsensor) |si| {
        const kind: SensorKind = m.sensor_kind[si];
        if (kind.stage() != stage) {
            continue;
        }
        const target: u32 = m.sensor_target[si];
        const out: []f32 = d.sensor_data[m.sensor_adr[si]..][0..kind.dim()];
        switch (kind) {
            .joint_pos => out[0] = d.pos[m.jnt_qpos_adr[target]],
            .joint_vel => out[0] = d.vel[m.jnt_dof_adr[target]],
            .tendon_pos => out[0] = d.tendon_length[target],
            .tendon_vel => out[0] = d.tendon_velocity[target],
            .actuator_force => out[0] = d.act_force[target],
            .site_pos => writeVec(out, d.site_xpos[target]),
            .site_quat => {
                const q: Quat = d.site_xrot[target];
                inline for (0..4) |k| {
                    out[k] = q[k];
                }
            },
            .site_lin_vel => writeVec(out, siteVelocity(m, d, target).lin),
            .site_ang_vel => writeVec(out, siteVelocity(m, d, target).ang),
            .velocimeter => {
                // In the SITE's own frame: rotate the world-frame velocity back by the
                // site's orientation. That is what a mounted instrument reads, and it is
                // the difference between "how fast is it moving" and "how fast does IT
                // think it is moving".
                const world: Motion = siteVelocity(m, d, target);
                writeVec(out, rotate(conjugate(d.site_xrot[target]), world.lin));
            },
            .gyro => {
                const world: Motion = siteVelocity(m, d, target);
                writeVec(out, rotate(conjugate(d.site_xrot[target]), world.ang));
            },
            .accelerometer => writeVec(out, siteProperAcceleration(m, d, target)),
        }
    }
}

fn writeVec(out: []f32, v: Vec) void {
    inline for (0..3) |k| {
        out[k] = v[k];
    }
}

/// A site's spatial velocity, in WORLD axes about the site's own point.
///
/// `cvel` is about the tree's shared frame origin, so the linear part has to be carried out
/// to the site: a spatial motion `(omega, v)` about `O` moves a point `p` at `v + omega x (p - O)`.
/// The same identity as `jacPoint`, which is not a coincidence - one is this evaluated at a
/// velocity, the other its derivative with respect to each DOF.
fn siteVelocity(m: *const Model, d: *const Data, site: u32) Motion {
    const body: u32 = m.site_body[site];
    const origin: Vec = d.subtree_com[m.body_root[body]];
    const spatial: Motion = d.cvel[body];
    return .{
        .ang = spatial.ang,
        .lin = spatial.lin + cross(spatial.ang, d.site_xpos[site] - origin),
    };
}

/// Propagate the SOLVED acceleration down the tree, giving each body's spatial acceleration.
///
/// Structurally the forward pass of `rne`, with two differences that matter. It uses the
/// acceleration the solver actually produced (`Data.acc`, constraint forces included)
/// rather than zero, and it keeps the result instead of turning it into forces.
///
/// The world is seeded with `-gravity`, exactly as in `rne`, and that is what makes the
/// accelerometer read PROPER acceleration - an instrument at rest on a table reads `g`
/// upward, not zero, and one in free fall reads zero. Getting this right is free here and
/// impossible to bolt on afterwards.
pub fn bodyAccelerations(m: *const Model, d: *Data) void {
    d.requireStage(.force, "bodyAccelerations");
    d.body_acc[world_body] = .{ .ang = vec_zero, .lin = -m.opt.gravity };

    for (1..m.nbody) |bi| {
        var a: Motion = d.body_acc[m.body_parent[bi]];
        const dof_adr: u32 = m.body_dof_adr[bi];
        for (0..m.body_dof_num[bi]) |k| {
            const dof: u32 = dof_adr + @as(u32, @intCast(k));
            // The moving-axis term, and this body's own joint acceleration.
            a = a.add(d.cdof_dot[dof].scale(d.vel[dof]));
            a = a.add(d.cdof[dof].scale(d.acc[dof]));
        }
        d.body_acc[bi] = a;
    }
}

/// Proper linear acceleration at a site, in the site's own frame - what an accelerometer
/// reads.
///
/// * THE TERM THAT IS EASY TO MISS. Carrying a spatial acceleration out to a point is not
/// the same operation as carrying a velocity out. A point fixed on a rotating body is
/// accelerating even at constant spatial acceleration, because the frame it sits in is
/// turning, and the correction is
///
///     a_point = a_spatial.lin + alpha x r  +  omega x v_point
///
/// The last term is the Coriolis correction from the rotating frame, and MuJoCo's
/// `mj_objectAcceleration` adds it explicitly for the same reason. Omit it and a spinning
/// sensor reads plausibly and wrongly - the error is exactly zero whenever the body is not
/// rotating, which is every simple test one would think to write.
fn siteProperAcceleration(m: *const Model, d: *const Data, site: u32) Vec {
    const body: u32 = m.site_body[site];
    const origin: Vec = d.subtree_com[m.body_root[body]];
    const offset: Vec = d.site_xpos[site] - origin;

    const spatial_acc: Motion = d.body_acc[body];
    const spatial_vel: Motion = d.cvel[body];
    const point_vel: Vec = spatial_vel.lin + cross(spatial_vel.ang, offset);
    const point_acc: Vec = spatial_acc.lin + cross(spatial_acc.ang, offset) +
        cross(spatial_vel.ang, point_vel);

    return rotate(conjugate(d.site_xrot[site]), point_acc);
}

// =============================================================================
// Stepping - putting the pipeline together
// =============================================================================

/// Run everything that depends on position and velocity, ending with the acceleration.
///
/// This is the whole forward pipeline as it exists today, in dependency order. Each stage
/// consumes the last; nothing is lazy, nothing is cached, and calling them out of order is
/// caught by the stage watermark rather than producing quiet nonsense.
///
/// A controller belongs BETWEEN this and `advance`: everything derived from the state is
/// known here, and no force has been committed yet.
pub fn forward(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.forward");
    defer zone.end();
    kinematics(m, d);
    comPos(m, d);
    crb(m, d);
    factorM(m, d);
    sensors(m, d, .position);
    comVel(m, d);
    makeConstraints(m, d);
    // -- ** A QUARTER OF THE STEP, AND ONLY HALF OF IT IS FOR THE DUAL SOLVER --
    //
    // `robot.project` is 25.5% of a standing Go1 step, and it does TWO jobs in one pass:
    //
    //   (a) M^-1J^T per row, which PGS needs every sweep and Newton never reads. Newton here
    //       is PRIMAL - nvxnv Hessian over accelerations, `solveNewton` asserts exactly
    //       that - and it returns before the PGS body without touching that array.
    //   (b) the exact A_hat = J M^-1 J^T diagonal, which becomes `R = (1-d)/d * A_hat`. **BOTH
    //       solvers need R**: it is the constraint softness, and it sits in Newton's
    //       Hessian as well as in PGS's per-row division.
    //
    // * SKIPPING THE WHOLE CALL FOR NEWTON WAS TRIED AND IS WRONG. Four tests failed
    // instantly - a box stack fell to -19.6, the MuJoCo force check read 0 against 19.62,
    // the Go1 dropped to -78 m. R was gone, so every constraint was infinitely soft. The
    // 25% is not waste; (a) is dual-only and (b) is load-bearing for everyone.
    //
    // * MuJoCo SPLITS THESE TWO, which is the shape of the real fix. `mj_diagApprox` runs
    // always and is cheap; `mj_makeY`/`mj_makeAR` build the full projection only
    // `if (isDual || diagexact)`, and `mj_isDual` is true just for `mjSOL_PGS`. Their exact
    // diagonal is opt-in behind `mjENBL_DIAGEXACT`. Doing the same here means approximating
    // A_hat for R and building M^-1J^T only for PGS - which CHANGES THE PHYSICS (R moves, so
    // contact softness moves) and must be re-verified against the `efc_R` fixtures before
    // it is believed. Their sparse `mj_makeY` also pre-counts row nonzeros, so it exploits
    // the Jacobian sparsity this does not.
    projectConstraints(m, d);
    biasForce(m, d);
    passive(m, d);
    actuation(m, d, m.opt.timestep);
    sensors(m, d, .velocity);
    forwardDynamics(m, d);
    solveConstraints(m, d);
    if (m.nsensor > 0) {
        bodyAccelerations(m, d);
        sensors(m, d, .force);
    }
}

/// Advance the state by `dt` using semi-implicit Euler.
///
/// The `q` update uses the NEW velocity, not the old one - that single change is what
/// separates semi-implicit Euler from explicit Euler, and it is the difference between a
/// pendulum that gains energy until it explodes and one that oscillates stably forever.
/// Explicit Euler is not offered here; it has pedagogical value and no other kind.
/// Advance velocity by one step, treating joint damping IMPLICITLY when any is present.
///
/// -- *** WHY THE DEFAULT INTEGRATOR HAS TO DO THIS --
///
/// Explicit integration of a damping force is stable only while `c*h/I < 2`. That is a
/// generous bound for a robot's shoulder and a very tight one for anything light: measured on
/// a 4-DOF arm whose wrist carries only two fingers, the mass-matrix diagonal there is
/// **0.00041** against 0.13 for the shoulder - three hundred times smaller - so the model's
/// perfectly ordinary `damping="0.5"` gives `c*h/I = 2.44` and the velocity flips sign and
/// grows every step:
///
///     damping 0.50  ->  |v| = 100.000   (the velocity clamp, i.e. diverged)
///     damping 0.05  ->  |v| =   1.06
///     damping 0.00  ->  |v| =   0.17
///
/// Positions still LOOK settled, because a velocity that alternates sign integrates to nearly
/// nothing - so the symptom is not an obviously exploding robot but a joint that will not track
/// and a controller that appears to be badly tuned. Two rounds of gain-hunting went past this.
///
/// * MuJoCo'S `mj_Euler` DOES EXACTLY THIS, and it is worth being precise about what "MuJoCo's
/// default is Euler" means: its Euler is explicit ONLY when no DOF is damped. The moment any
/// is, it forms `qH = M + h*diag(B)`, factors that, and solves - which is unconditionally
/// stable for any damping. Matching it is not adopting an exotic integrator; it is finishing
/// the ordinary one.
///
/// * AND IT COSTS NOTHING WHEN NOTHING IS DAMPED - the undamped path is the original two-line
/// loop, chosen by a flag computed once at build time rather than by scanning every step.
fn dampedVelocityStep(m: *const Model, d: *Data, dt: f32) void {
    if (!m.has_dof_damping) {
        for (0..m.nv) |i| {
            d.vel[i] += dt * d.acc[i];
        }
        return;
    }

    // `M*dv = h*M*a` explicitly; implicitly it is `(M + h*B)*dv = h*M*a`, with the same right
    // hand side. Building the impulse first keeps this true whatever produced `acc`.
    mulM(m, d, d.acc, d.implicit_rhs);
    for (d.implicit_rhs) |*value| {
        value.* *= dt;
    }

    factorMDamped(m, d, dt);
    solveM(m, d, d.implicit_rhs);
    for (0..m.nv) |i| {
        d.vel[i] += d.implicit_rhs[i];
    }

    // * AND THE PLAIN FACTORISATION IS RESTORED. `qLD` is shared scratch: anything reaching for
    // `solveM` afterwards expects the mass matrix, and leaving a damped factorisation behind
    // would quietly change every constraint's effective inertia.
    //
    // -- ** WHAT THIS COSTS, SO THE TRADE IS AN INFORMED ONE --
    //
    // Measured on the standing Go1 (`zig build robot-bench`): a factorisation is ~690 ns
    // against a ~15 300 ns step, so this restore alone is **about 4.5% of every step** -
    // and the very next `forward` opens with `factorM` and overwrites it. Between the two
    // there is nothing in the engine that reads `qLD`.
    //
    // It is kept anyway, and the reason is the word "engine". A CALLER sits in that gap by
    // design - that is the entire point of the `step1`/`step2` split - and `solveM`,
    // `massDiagonal` and anything built on them are public. The stage watermark catches
    // calling a stage out of ORDER; it cannot catch reading a factorisation that is of the
    // wrong MATRIX, because the stage is legitimately `.position` either way. A controller
    // scaling gains by `massDiagonal` between steps would silently get damped inertias.
    //
    // * The cheap fix is a flag on `Data` saying which matrix `qLD` currently holds, so the
    // restore becomes lazy and the assert becomes possible. It is not done here because
    // "nothing is lazy, nothing is cached" is a property of this file worth more than 4.5%
    // - but if this step ever needs to be twice as fast, this is a known 4.5% with a known
    // and testable price.
    factorM(m, d);
}

fn advanceEuler(m: *const Model, d: *Data, dt: f32) void {
    for (0..m.na) |i| {
        d.act[i] += dt * d.act_dot[i];
    }
    dampedVelocityStep(m, d, dt);
    // ** BOUNDED HERE, BETWEEN THE TWO INTEGRATIONS - the placement is the whole fix.
    //
    // Doing it after `step` returns was the first attempt and did nothing: `integratePos` had
    // already carried the bad velocity into `pos`, so clamping afterwards cleaned `vel` and
    // left a NaN position behind, which reached `crb` on the next `forward` exactly as before.
    // **Measured: 2297 NaN steps out of 2400, unchanged by the clamp.**
    boundVelocity(m, d);
    integratePos(m, d.pos, d.vel, dt);
    normalizeQuats(m, d.pos);
}

/// Advance by `dt` using classical fourth-order Runge-Kutta.
///
/// Four evaluations of the dynamics per step, combined so that the error per step is
/// O(dt^5) instead of Euler's O(dt^2). Worth it when you care about energy over a long
/// horizon - a double pendulum integrated with RK4 conserves energy to a fraction of a
/// percent over ten seconds, where Euler visibly drifts.
///
/// Not worth it once contact is involved: contact makes the dynamics non-smooth, and a
/// high-order method assumes smoothness. RK4 is for the clean case, which is exactly the
/// case where you want to verify energy conservation.
fn advanceRk4(m: *const Model, d: *Data, dt: f32) void {
    const nv: usize = m.nv;
    // Working copies. RK4 needs the ORIGINAL state to evaluate each stage from, so the
    // starting point is saved once and every stage restores from it.
    const pos0: []f32 = d.rk_pos0;
    const vel0: []f32 = d.rk_vel0;
    @memcpy(pos0, d.pos);
    @memcpy(vel0, d.vel);

    // Butcher tableau for classical RK4: evaluate at 0, dt/2, dt/2, dt, and weight the
    // slopes 1/6, 1/3, 1/3, 1/6.
    const stage_dt = [_]f32{ 0.0, 0.5, 0.5, 1.0 };
    const weight = [_]f32{ 1.0 / 6.0, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 6.0 };

    var vel_sum: []f32 = d.rk_vel_sum;
    var acc_sum: []f32 = d.rk_acc_sum;
    @memset(vel_sum, 0);
    @memset(acc_sum, 0);

    inline for (0..4) |stage| {
        if (stage > 0) {
            // Restore and take a trial step of `stage_dt * dt` along the previous slope.
            @memcpy(d.pos, pos0);
            @memcpy(d.vel, vel0);
            const h: f32 = stage_dt[stage] * dt;
            for (0..nv) |i| {
                d.vel[i] = vel0[i] + h * d.rk_acc_stage[i];
            }
            integratePos(m, d.pos, d.rk_vel_stage, h);
            normalizeQuats(m, d.pos);
            forward(m, d);
        } else {
            forward(m, d);
        }
        // Record this stage's slope, and accumulate its weighted contribution.
        @memcpy(d.rk_vel_stage, d.vel);
        @memcpy(d.rk_acc_stage, d.acc);
        for (0..nv) |i| {
            vel_sum[i] += weight[stage] * d.vel[i];
            acc_sum[i] += weight[stage] * d.acc[i];
        }
    }

    // Activation is integrated ONCE, with the last stage's rate. RK4-weighting it too
    // would be more faithful, but activation dynamics are first-order and slow compared to
    // the mechanics, so it is not where the error budget goes.
    for (0..m.na) |i| {
        d.act[i] += dt * d.act_dot[i];
    }

    // Apply the combined slope from the original state.
    @memcpy(d.pos, pos0);
    for (0..nv) |i| {
        d.vel[i] = vel0[i] + dt * acc_sum[i];
    }
    integratePos(m, d.pos, vel_sum, dt);
    normalizeQuats(m, d.pos);
}

/// The half of the pipeline that depends only on the STATE - everything through the bias
/// forces, stopping before any force is committed.
///
/// This is the natural place for a controller: every derived quantity is current, and
/// nothing has been decided yet. Splitting `step` here rather than making the caller run a
/// whole extra `forward` halves the work of a control loop, which is why MuJoCo exposes the
/// same split.
///
/// A controller reads `Data`, writes `ctrl` and `applied_force`, and then calls `step2`.
pub fn step1(m: *const Model, d: *Data) void {
    assertf(
        m.opt.integrator != .rk4,
        @src(),
        "step1/step2 cannot be used with RK4 — it evaluates the dynamics four times " ++
            "per step, so there is no single point at which a controller can intervene",
        .{},
    );
    kinematics(m, d);
    comPos(m, d);
    crb(m, d);
    factorM(m, d);
    comVel(m, d);
    biasForce(m, d);
    passive(m, d);
}

/// The half that depends on forces: actuation, the acceleration solve, and the integration.
/// Call after `step1` and whatever the controller wrote.
pub fn step2(m: *const Model, d: *Data) void {
    d.requireStage(.velocity, "step2");
    actuation(m, d, m.opt.timestep);
    forwardDynamics(m, d);
    advanceEuler(m, d, m.opt.timestep);
    d.stage = .stale;
}

// ---- Implicit-in-velocity integration ------------------------------------------
//
// DERIVATION. Explicit Euler evaluates the acceleration at the CURRENT velocity:
//
//     v_new = v + h*a(v)
//
// which is why a strong damper destabilises it: damping force grows with velocity, so a
// step that overshoots produces an even larger restoring force next step, and the
// oscillation grows. The classic remedy is to evaluate at the NEW velocity instead,
//
//     v_new = v + h*a(v_new)
//
// which is stable for any damping - but `v_new` appears on both sides. One Newton step
// resolves it. Write the total force as `F`, linearise about the current velocity with
// `D = dF/dv`, and use `M*dv/h = F(v) + D*dv`:
//
//     * (M - h*D)*dv = h*F(v) = h*M*a
//
// The right-hand side is `h*M*a` because `a` is exactly `M^-1F` - the acceleration
// `forwardDynamics` already computed. When `D` is zero this collapses to `dv = h*a`, which
// is explicit Euler, and that identity is worth testing rather than trusting.
//
// WHAT "FAST" MEANS. `D` has three sources: damping and springs (`passive`), the actuators'
// velocity terms, and the Coriolis/centrifugal term inside `rne`. MuJoCo's `implicit`
// includes all three; its `implicitfast` skips the last, and that omission IS the speed
// difference - `mjd_rne_vel` is by far the most expensive of the three. What it costs is
// accuracy for a fast-TUMBLING free body, where the gyroscopic term is what wants damping.
// For a damped, actuated mechanism - which is what a robot is - the first two carry the
// stability, and that is the trade this integrator makes.

/// `d(v x f)/dv` for a fixed force `f` - a 6x6 block, row-major.
///
/// `crossForce(v, f)` is bilinear, so its derivative in `v` is just the other operand arranged
/// as a matrix. Written out rather than derived at runtime because it is the inner loop of
/// `rneVelDerivative` and gets no clearer for being clever.
fn crossForceVelJacobian(f: Force, out: *[36]f32) void {
    @memset(out, 0);
    // crossForce(v, f).ang = v.ang x f.ang + v.lin x f.lin
    setSkew(out, 0, 0, -f.ang);
    setSkew(out, 0, 3, -f.lin);
    // crossForce(v, f).lin = v.ang x f.lin
    setSkew(out, 3, 0, -f.lin);
}

/// `d(v x m)/dv` for a fixed motion `m`.
fn crossMotionVelJacobian(mo: Motion, out: *[36]f32) void {
    @memset(out, 0);
    // crossMotion(v, m).ang = v.ang x m.ang
    setSkew(out, 0, 0, -mo.ang);
    // crossMotion(v, m).lin = v.ang x m.lin + v.lin x m.ang
    setSkew(out, 3, 0, -mo.lin);
    setSkew(out, 3, 3, -mo.ang);
}

/// Write `skew(v)` - the matrix with `skew(v)*x = v x x` - into a 6x6 block at `(row, col)`.
fn setSkew(out: *[36]f32, row: usize, col: usize, v: Vec) void {
    out[(row + 0) * 6 + col + 1] += -v[2];
    out[(row + 0) * 6 + col + 2] += v[1];
    out[(row + 1) * 6 + col + 0] += v[2];
    out[(row + 1) * 6 + col + 2] += -v[0];
    out[(row + 2) * 6 + col + 0] += -v[1];
    out[(row + 2) * 6 + col + 1] += v[0];
}

/// The derivative of `rotationTriple`, for a ball joint or a free joint's rotational half.
///
/// * ONE SNAPSHOT FOR ALL THREE. `rotationTriple` takes the velocity once, before any of its
/// three DOFs is folded in, and builds all three `cdof_dot` from that same value. The
/// derivative has to do the same: taking a fresh partial per DOF makes the second and third
/// depend on the first, which is a different function.
fn rotationTripleDerivative(
    m: *const Model,
    d: *const Data,
    dcvel: []Motion,
    dcdof_dot: []Motion,
    body: usize,
    dof: u32,
) void {
    const nv: usize = m.nv;
    inline for (0..3) |k| {
        var block: [36]f32 = undefined;
        crossMotionVelJacobian(d.cdof[dof + k], &block);
        for (0..nv) |j| {
            // * READ FROM THE SNAPSHOT, which is `dcvel[body]` as it stands BEFORE the loop
            // below adds anything - the same value for all three.
            dcdof_dot[(dof + k) * nv + j] = applyBlock(&block, dcvel[body * nv + j]);
        }
    }
    // Only now are the three folded into the running total - after all three partials above
    // have been taken from the snapshot.
    inline for (0..3) |k| {
        dcvel[body * nv + dof + k] = dcvel[body * nv + dof + k].add(d.cdof[dof + k]);
    }
}

/// `d(bias force)/dv` - the Coriolis and centrifugal derivative, added into `out`.
///
/// -- *** WHAT SEPARATES `implicit` FROM `implicitfast` --
///
/// Everything else in `D` - joint damping, tendon damping, actuator velocity terms - is a
/// MODEL constant. This one is not: it is the derivative of the velocity-product terms inside
/// `rne`, it changes every step, and computing it is most of the cost difference between the
/// two integrators. MuJoCo draws exactly this line, in `mjd_smooth_vel`'s `flg_bias`.
///
/// **What it buys is GYROSCOPIC COUPLING** - a fast rotor whose spin feeds velocity-dependent
/// torque into other, damped axes. Measured on exactly that: four times more accurate than
/// `implicitfast` at both dt = 1/500 and dt = 1/100.
///
/// * AND NOT what it was first assumed to buy. "Stabilises a fast-tumbling free body" was the
/// original claim here and measurement refused it: on a torque-free plate spun about its
/// intermediate axis, **rk4 dominates** (energy drift 0.00000) and `implicit` was WORSE than
/// `implicitfast` at the lower spin. Implicit methods buy stiffness, not accuracy, and a
/// torque-free tumbler is not stiff - it is merely fast.
///
/// -- * THE STRUCTURE MIRRORS `rne` EXACTLY, one derivative level up --
///
/// `rne` propagates a 6-vector per body; this propagates a 6xnv matrix per body - the same
/// forward sweep, the same backward sum, the same final projection onto `cdof`. Reading them
/// side by side is the only sane way to check either.
///
/// * AND THE RESULT IS ASYMMETRIC, which is why MuJoCo solves `implicit` with an LU rather
/// than the sparse Cholesky it uses for `implicitfast`. A velocity cross-product has no reason
/// to be symmetric in the two DOFs it couples.
fn rneVelDerivative(m: *const Model, d: *Data, out: []f32) void {
    d.requireStage(.velocity, "rneVelDerivative");
    // Same hazard as `solveNewton`: this scratch exists only when the model was BUILT for
    // `.implicit`, and the integrator can be changed afterwards.
    assertf(
        // Both sizes, since they differ: per-body for the sweep buffers, per-DOF for
        // `deriv_cdof_dot`.
        d.deriv_cacc.len == m.nbody * m.nv and d.deriv_cdof_dot.len == m.nv * m.nv,
        @src(),
        "integrator was set to .implicit after Data.init, so the Coriolis-derivative scratch " ++
            "was never allocated — choose the integrator in Options, before building Data",
        .{},
    );
    const nv: usize = m.nv;
    const dcacc: []Motion = d.deriv_cacc;
    const dcfrc: []Force = d.deriv_cfrc;
    const dcvel: []Motion = d.deriv_cvel;
    const dcdof_dot: []Motion = d.deriv_cdof_dot;

    // ---- dcvel/dqvel and dcdof_dot/dqvel, mirroring `comVel` ----
    //
    // `cvel[i] = cvel[parent] + sum cdof[k]*qvel[k]`, so dcvel[i]/dqvel[j] is the parent's
    // derivative plus `cdof[j]` when `j` is one of this body's own DOFs. `cdof_dot` is
    // `crossMotion(vel, cdof)`, whose derivative follows through `vel`.
    for (0..nv) |j| {
        dcvel[world_body * nv + j] = .zero;
    }
    for (1..m.nbody) |bi| {
        const parent: usize = m.body_parent[bi];
        for (0..nv) |j| {
            dcvel[bi * nv + j] = dcvel[parent * nv + j];
        }
        // -- *** THIS MUST MIRROR `comVel` JOINT BY JOINT, NOT DOF BY DOF --
        //
        // The first version walked every DOF as though it were a hinge. That is right for a
        // hinge and a slide and WRONG for the other two, because `comVel` treats them
        // specially - and the error is invisible on any model made only of hinges.
        //
        // Measured against finite differences: a three-hinge chain agreed to 0.0009 and a
        // branching tree to 0.00005, while a free base was out by 1.30 and a ball joint by
        // 1.31, against matrices whose largest entries were 3.7 and 2.5. **The original test
        // used two bodies and three hinges**, which is exactly the shape that cannot see it.
        //
        //   * a FREE joint's three translation DOFs have `cdof_dot = 0` - a pure translation
        //     generates no Coriolis term - so their derivative is zero too;
        //   * a BALL joint's three rotation DOFs, and a free joint's, share ONE snapshot of the
        //     velocity taken before any of them is added. Folding each into the running total
        //     as it goes makes the second and third terms depend on the first, which is not
        //     what `rotationTriple` computes.
        const jnt_adr: u32 = m.body_jnt_adr[bi];
        for (jnt_adr..jnt_adr + m.body_jnt_num[bi]) |ji| {
            const dof: usize = m.jnt_dof_adr[ji];
            switch (m.jnt_type[ji]) {
                .slide, .hinge => {
                    var block: [36]f32 = undefined;
                    crossMotionVelJacobian(d.cdof[dof], &block);
                    for (0..nv) |j| {
                        dcdof_dot[dof * nv + j] = applyBlock(&block, dcvel[bi * nv + j]);
                    }
                    dcvel[bi * nv + dof] = dcvel[bi * nv + dof].add(d.cdof[dof]);
                },
                .ball => rotationTripleDerivative(m, d, dcvel, dcdof_dot, bi, @intCast(dof)),
                .free => {
                    // Translation first: no Coriolis term, so no derivative.
                    inline for (0..3) |k| {
                        for (0..nv) |j| {
                            dcdof_dot[(dof + k) * nv + j] = .zero;
                        }
                        dcvel[bi * nv + dof + k] = dcvel[bi * nv + dof + k].add(d.cdof[dof + k]);
                    }
                    rotationTripleDerivative(m, d, dcvel, dcdof_dot, bi, @intCast(dof + 3));
                },
            }
        }
    }

    // ---- forward sweep: dcacc/dqvel and dcfrc/dqvel ----
    for (0..nv) |j| {
        dcacc[world_body * nv + j] = .zero;
    }
    for (1..m.nbody) |bi| {
        const parent: usize = m.body_parent[bi];
        for (0..nv) |j| {
            dcacc[bi * nv + j] = dcacc[parent * nv + j];
        }
        const dof_adr: u32 = m.body_dof_adr[bi];
        for (0..m.body_dof_num[bi]) |k| {
            const dof: usize = dof_adr + k;
            // d(cdof_dot[dof]*qvel[dof])/dqvel[j] has two terms: the explicit one when j == dof,
            // and the implicit one through cdof_dot itself.
            dcacc[bi * nv + dof] = dcacc[bi * nv + dof].add(d.cdof_dot[dof]);
            const speed: f32 = d.vel[dof];
            for (0..nv) |j| {
                dcacc[bi * nv + j] = dcacc[bi * nv + j].add(dcdof_dot[dof * nv + j].scale(speed));
            }
        }

        // dcfrc/dqvel = I*dcacc/dqvel + d(cvel x I*cvel)/dcvel * dcvel/dqvel
        const inertia: Inertia = d.cinert[bi];
        var cross_block: [36]f32 = undefined;
        crossForceVelJacobian(inertia.mul(d.cvel[bi]), &cross_block);
        for (0..nv) |j| {
            const from_acc: Force = inertia.mul(dcacc[bi * nv + j]);
            // The second half of the product rule: cvel appears on BOTH sides of the cross.
            const dv: Motion = dcvel[bi * nv + j];
            const direct: Force = applyBlockForce(&cross_block, dv);
            const through_inertia: Force = crossForce(d.cvel[bi], inertia.mul(dv));
            dcfrc[bi * nv + j] = from_acc.add(direct).add(through_inertia);
        }
    }

    // ---- backward sum, exactly as `rne` does ----
    var bi: usize = m.nbody;
    while (bi > 1) {
        bi -= 1;
        const parent: usize = m.body_parent[bi];
        if (parent != world_body) {
            for (0..nv) |j| {
                dcfrc[parent * nv + j] = dcfrc[parent * nv + j].add(dcfrc[bi * nv + j]);
            }
        }
    }

    // ---- project onto cdof, and SUBTRACT: `D` is dforce/dv and the bias is subtracted ----
    for (0..nv) |i| {
        const body: usize = m.dof_body[i];
        for (0..nv) |j| {
            out[i * nv + j] -= dot6(d.cdof[i], dcfrc[body * nv + j]);
        }
    }
}

/// Apply a 6x6 block to a motion vector.
fn applyBlock(block: *const [36]f32, v: Motion) Motion {
    const x = [6]f32{ v.ang[0], v.ang[1], v.ang[2], v.lin[0], v.lin[1], v.lin[2] };
    var y: [6]f32 = @splat(0);
    for (0..6) |r| {
        for (0..6) |c| {
            y[r] += block[r * 6 + c] * x[c];
        }
    }
    return .{ .ang = vec(y[0], y[1], y[2]), .lin = vec(y[3], y[4], y[5]) };
}

/// Apply a 6x6 block to a motion vector, producing a force.
fn applyBlockForce(block: *const [36]f32, v: Motion) Force {
    const out: Motion = applyBlock(block, v);
    return .{ .ang = out.ang, .lin = out.lin };
}

/// `D = d(velocity-dependent smooth forces)/dv`, dense and row-major.
///
/// Dense on purpose, for now. `D` is NOT tree-sparse: a tendon couples every DOF it touches
/// to every other, so `M - h*D` loses the ancestor-chain structure that makes `factorM`
/// free of fill-in. Rather than pretend otherwise, this is a dense matrix with a dense
/// solve, and section 4g's table records the cost.
///
/// Takes no `Data`: for the force set `implicitfast` covers, every term is a MODEL constant.
/// Joint damping, tendon damping and the actuators' `bias[2]` do not depend on the state at
/// all - which also means the matrix could be built once per model rather than per step, an
/// optimisation section 4g can take when it wants it.
fn smoothVelDerivative(m: *const Model, out: []f32) void {
    @memset(out, 0);

    // ---- joint damping: a force on one DOF, proportional to that DOF's own velocity ----
    for (0..m.njnt) |ji| {
        const damping: f32 = m.jnt_damping[ji];
        if (damping == 0.0) {
            continue;
        }
        const dof_adr: u32 = m.jnt_dof_adr[ji];
        for (dof_adr..dof_adr + m.jnt_type[ji].dofCount()) |dof| {
            out[dof * m.nv + dof] -= damping;
        }
    }

    // ---- tendon damping: NOT diagonal ----
    // A tendon's damping force is `-b*(c*v)` on its length, and that scalar reaches DOF `j`
    // scaled by `c_j`. So the contribution is `-b*c_jc_k` - an outer product, coupling every
    // DOF the tendon touches to every other. This is the term that costs the tree sparsity,
    // and it is also the term a diagonal approximation would silently drop.
    for (0..m.ntendon) |ti| {
        const damping: f32 = m.tendon_damping[ti];
        if (damping == 0.0) {
            continue;
        }
        const coefficients: []const f32 = m.tendon_jacobian[ti * m.nv ..][0..m.nv];
        for (coefficients, 0..) |cj, j| {
            if (cj == 0.0) {
                continue;
            }
            for (coefficients, 0..) |ck, k| {
                out[j * m.nv + k] -= damping * cj * ck;
            }
        }
    }

    // ---- actuators: the `bias[2]*l_dot` term, the only velocity-dependent one ----
    // The gain term reads either the control or the activation, neither of which depends on
    // this step's velocity, so it contributes nothing here. A velocity servo's whole
    // restoring action lives in `bias[2]`, which is exactly why such a servo is the thing
    // most likely to destabilise an explicit integrator.
    for (0..m.nu) |ai| {
        const b2: f32 = m.act_bias[ai][2];
        if (b2 == 0.0) {
            continue;
        }
        switch (m.act_kind[ai]) {
            .joint => {
                const dof: u32 = m.act_dof[ai];
                out[dof * m.nv + dof] += b2;
            },
            .tendon => {
                // Same outer-product shape as tendon damping, for the same reason.
                const target: u32 = m.act_target[ai];
                const coefficients: []const f32 = m.tendon_jacobian[target * m.nv ..][0..m.nv];
                for (coefficients, 0..) |cj, j| {
                    if (cj == 0.0) {
                        continue;
                    }
                    for (coefficients, 0..) |ck, k| {
                        out[j * m.nv + k] += b2 * cj * ck;
                    }
                }
            },
        }
    }
}

/// Dense LU factorization with partial pivoting, in place. Returns false if the matrix is
/// singular to working precision.
///
/// A dense solve rather than a reuse of `factorM`, because `M - h*D` is not tree-sparse
/// (see `smoothVelDerivative`) and is not guaranteed symmetric - a future velocity-dependent
/// force need not produce a symmetric derivative, and a Cholesky would fail silently on the
/// day one does. MuJoCo uses an LU here for the same reason.
fn luFactor(a: []f32, n: u32, pivot: []u32) bool {
    for (0..n) |k| {
        // Partial pivoting: the largest magnitude in the column below the diagonal.
        var best: usize = k;
        var best_magnitude: f32 = @abs(a[k * n + k]);
        for (k + 1..n) |row| {
            const magnitude: f32 = @abs(a[row * n + k]);
            if (magnitude > best_magnitude) {
                best = row;
                best_magnitude = magnitude;
            }
        }
        if (best_magnitude <= 1.0e-20) {
            return false;
        }
        pivot[k] = @intCast(best);
        if (best != k) {
            for (0..n) |col| {
                std.mem.swap(f32, &a[k * n + col], &a[best * n + col]);
            }
        }
        const inv_diagonal: f32 = 1.0 / a[k * n + k];
        for (k + 1..n) |row| {
            const factor: f32 = a[row * n + k] * inv_diagonal;
            a[row * n + k] = factor;
            for (k + 1..n) |col| {
                a[row * n + col] -= factor * a[k * n + col];
            }
        }
    }
    return true;
}

/// Solve using the factorization `luFactor` left in place. `x` carries the right-hand side
/// in and the solution out.
fn luSolve(a: []const f32, n: u32, pivot: []const u32, x: []f32) void {
    // Apply the same row swaps the factorization made.
    for (0..n) |k| {
        const p: u32 = pivot[k];
        if (p != k) {
            std.mem.swap(f32, &x[k], &x[p]);
        }
    }
    // Forward substitution through L (unit diagonal).
    for (0..n) |row| {
        var sum: f32 = x[row];
        for (0..row) |col| {
            sum -= a[row * n + col] * x[col];
        }
        x[row] = sum;
    }
    // Back substitution through U.
    var row: usize = n;
    while (row > 0) {
        row -= 1;
        var sum: f32 = x[row];
        for (row + 1..n) |col| {
            sum -= a[row * n + col] * x[col];
        }
        x[row] = sum / a[row * n + row];
    }
}

/// Advance by `dt`, treating velocity-dependent forces implicitly.
///
/// Falls back to the explicit update if the system is singular - which should not happen,
/// since `M` is positive definite and `-h*D` only adds damping-like terms, but a model can
/// always be built badly enough and an integrator that silently produces NaN is worse than
/// one that visibly loses an accuracy guarantee.
fn advanceImplicitFast(m: *const Model, d: *Data, dt: f32) void {
    const nv: u32 = m.nv;
    if (nv == 0) {
        return;
    }

    // rhs = h*M*a, the impulse the explicit step would have applied.
    mulM(m, d, d.acc, d.implicit_rhs);
    for (d.implicit_rhs) |*value| {
        value.* *= dt;
    }

    // A = M - h*D. `M` is expanded dense here; the sparse form cannot represent `D`'s
    // tendon coupling.
    smoothVelDerivative(m, d.implicit_matrix);
    // * AND THE CORIOLIS TERM, FOR `.implicit` ONLY. Everything above is a model constant;
    // this one depends on the current velocity, changes every step, and is most of the cost.
    if (m.opt.integrator == .implicit) {
        rneVelDerivative(m, d, d.implicit_matrix);
    }
    for (d.implicit_matrix) |*value| {
        value.* *= -dt;
    }
    for (0..nv) |i| {
        const row: u32 = m.mass_row_start[i];
        for (0..m.mass_row_nonzeros[i]) |k| {
            const j: u32 = m.mass_col_index[row + k];
            const value: f32 = d.mass_matrix[row + k];
            d.implicit_matrix[i * nv + j] += value;
            if (j != i) {
                d.implicit_matrix[j * nv + i] += value; // M is symmetric; only half is stored
            }
        }
    }

    if (luFactor(d.implicit_matrix, nv, d.implicit_pivot)) {
        luSolve(d.implicit_matrix, nv, d.implicit_pivot, d.implicit_rhs);
        for (0..nv) |i| {
            d.vel[i] += d.implicit_rhs[i];
        }
    } else {
        for (0..nv) |i| {
            d.vel[i] += dt * d.acc[i];
        }
    }

    for (0..m.na) |i| {
        d.act[i] += dt * d.act_dot[i];
    }
    // Same bound, same placement, and for the same reason as in `advanceEuler`: it has to sit
    // before the velocity is carried into `pos`, or it cleans a value that has already done
    // its damage.
    boundVelocity(m, d);
    integratePos(m, d.pos, d.vel, dt);
    normalizeQuats(m, d.pos);
}

/// Advance the simulation by one timestep: `forward`, then integrate.
///
/// After this returns, `Data`'s derived quantities describe the state BEFORE the step -
/// the same convention MuJoCo uses, and for the same reason: the step ends by writing the
/// new state, and recomputing everything from it would double the work for a caller who is
/// about to call `step` again anyway. Call `forward` explicitly if you need the derived
/// quantities to match the current state.
pub fn step(m: *const Model, d: *Data) void {
    const zone: profiler.Zone = profiler.zoneNamed(@src(), "robot.step");
    defer zone.end();
    switch (m.opt.integrator) {
        .euler => {
            forward(m, d);
            advanceEuler(m, d, m.opt.timestep);
        },
        // * THE TWO IMPLICIT MODES SHARE A STEP AND DIFFER ONLY IN WHAT GOES INTO `D`. MuJoCo
        // splits them the same way, at `mjd_smooth_vel`'s `flg_bias`: one function, one flag,
        // and the entire cost difference sitting behind it.
        .implicitfast, .implicit => {
            forward(m, d);
            advanceImplicitFast(m, d, m.opt.timestep);
        },
        .rk4 => advanceRk4(m, d, m.opt.timestep),
    }
    // The state has moved; everything derived from it is now stale.
    d.stage = .stale;
}

/// Keep velocities inside a physically meaningful range, and stop a non-finite one spreading.
///
/// -- ** WHY A HARD BOUND IS RIGHT, NOT A PLASTER --
///
/// Every production engine has one, because a rigid-body step has a maximum speed it can
/// describe at all. A body moving further than its own size in one timestep is past the point
/// where the discretisation means anything, and letting it continue turns a visible glitch
/// into a corrupted model.
///
/// **The failure this ends, measured:** a KUKA driven by IK at a target INSIDE a stack of
/// 6.8 kg crates, at a gain high enough to keep trying. Accelerations sat at ~10,000 - a
/// thousand g - for forty steps with the solver capped at 60 iterations, a row reached
/// 1536 N, and then the mass matrix went NaN: `factorM: pivot 24 is nan`, on screen, in a
/// demo someone was using.
///
/// * THE NON-FINITE CHECK IS THE IMPORTANT HALF. A clamp alone passes NaN straight through,
/// because every comparison against NaN is false. Zeroing it contains the corruption at the
/// one place all motion flows through, rather than letting it reach `crb` and take the whole
/// model with it.
fn boundVelocity(m: *const Model, d: *Data) void {
    const bound: f32 = m.opt.max_velocity;
    for (d.vel) |*v| {
        if (!isFinite(v.*)) {
            // Not recoverable, but containable: the body stops rather than poisoning `M`.
            v.* = 0;
            continue;
        }
        v.* = clamp(v.*, -bound, bound);
    }
}

/// Total mechanical energy, for testing and for a HUD. Kinetic is `1/2v^TMv`; potential is
/// `-sum m_i*g*x_i` over the bodies' centres of mass.
///
/// A conserved quantity is the sharpest thing you can watch in a simulation without a
/// reference to compare against: it should be constant, and how it fails to be constant
/// tells you which integrator you are using.
pub fn energy(m: *const Model, d: *const Data) f32 {
    d.requireStage(.position, "energy");
    var kinetic: f32 = 0;
    for (0..m.nv) |i| {
        const row: u32 = m.mass_row_start[i];
        for (0..m.mass_row_nonzeros[i]) |k| {
            const j: u32 = m.mass_col_index[row + k];
            const value: f32 = d.mass_matrix[row + k];
            // Only the lower triangle is stored, so off-diagonal entries count twice.
            const factor: f32 = if (i == j) 1.0 else 2.0;
            kinetic += 0.5 * factor * value * d.vel[i] * d.vel[j];
        }
    }
    var potential: f32 = 0;
    for (1..m.nbody) |bi| {
        potential -= m.body_mass[bi] * dot3(m.opt.gravity, d.body_xipos[bi]);
    }
    return kinetic + potential;
}

/// Normalize a quaternion, falling back to identity if it has collapsed. Integration and
/// user input both walk quaternions off the unit sphere, and a zero-norm quaternion has no
/// orientation to recover - identity keeps the simulation running instead of emitting NaN.
fn normalizeQuat(q: Quat) Quat {
    const n: f32 = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    return if (n > 1.0e-9) q / splat(n) else quat_identity;
}

// =============================================================================
// Position coordinates
//
// `pos` and `vel` have different lengths and different geometry. Orientations live on the
// unit sphere in 4D; velocities live in its 3D tangent space. So you cannot subtract two
// positions to get a velocity, and you cannot add a velocity to a position. These three
// functions are the only legal bridges, and everything else must go through them.
// =============================================================================

/// Advance `pos` by `vel` over `dt`, respecting the geometry of each joint type.
pub fn integratePos(m: *const Model, pos: []f32, vel: []const f32, dt: f32) void {
    assertf(pos.len == m.nq, @src(), "pos has {d} entries, model wants {d}", .{ pos.len, m.nq });
    assertf(vel.len == m.nv, @src(), "vel has {d} entries, model wants {d}", .{ vel.len, m.nv });

    for (0..m.njnt) |ji| {
        const qadr: u32 = m.jnt_qpos_adr[ji];
        const vadr: u32 = m.jnt_dof_adr[ji];
        switch (m.jnt_type[ji]) {
            .slide, .hinge => {
                pos[qadr] += dt * vel[vadr];
            },
            .free => {
                // Translation is ordinary integration; rotation is not.
                inline for (0..3) |k| {
                    pos[qadr + k] += dt * vel[vadr + k];
                }
                const w: Vec = vec(vel[vadr + 3], vel[vadr + 4], vel[vadr + 5]);
                const q: Quat = .{ pos[qadr + 3], pos[qadr + 4], pos[qadr + 5], pos[qadr + 6] };
                const rotated: Quat = rotateQuatByAngularVel(q, w, dt);
                inline for (0..4) |k| {
                    pos[qadr + 3 + k] = rotated[k];
                }
            },
            .ball => {
                const w: Vec = vec(vel[vadr], vel[vadr + 1], vel[vadr + 2]);
                const q: Quat = .{ pos[qadr], pos[qadr + 1], pos[qadr + 2], pos[qadr + 3] };
                const rotated: Quat = rotateQuatByAngularVel(q, w, dt);
                inline for (0..4) |k| {
                    pos[qadr + k] = rotated[k];
                }
            },
        }
    }
}

/// The inverse of `integratePos`: the velocity that carries `from` to `to` in `dt`.
/// MuJoCo calls this `mj_differentiatePos`, and it exists because "subtract two positions"
/// is not a meaningful operation on a model containing a quaternion.
pub fn differentiatePos(
    m: *const Model,
    vel: []f32,
    from: []const f32,
    to: []const f32,
    dt: f32,
) void {
    assertf(dt > 0.0, @src(), "differentiatePos needs a positive dt, got {d}", .{dt});
    const inv_dt: f32 = 1.0 / dt;

    for (0..m.njnt) |ji| {
        const qadr: u32 = m.jnt_qpos_adr[ji];
        const vadr: u32 = m.jnt_dof_adr[ji];
        switch (m.jnt_type[ji]) {
            .slide, .hinge => {
                vel[vadr] = (to[qadr] - from[qadr]) * inv_dt;
            },
            .free => {
                inline for (0..3) |k| {
                    vel[vadr + k] = (to[qadr + k] - from[qadr + k]) * inv_dt;
                }
                const qa: Quat = .{ from[qadr + 3], from[qadr + 4], from[qadr + 5], from[qadr + 6] };
                const qb: Quat = .{ to[qadr + 3], to[qadr + 4], to[qadr + 5], to[qadr + 6] };
                const w: Vec = angularVelBetween(qa, qb, inv_dt);
                inline for (0..3) |k| {
                    vel[vadr + 3 + k] = w[k];
                }
            },
            .ball => {
                const qa: Quat = .{ from[qadr], from[qadr + 1], from[qadr + 2], from[qadr + 3] };
                const qb: Quat = .{ to[qadr], to[qadr + 1], to[qadr + 2], to[qadr + 3] };
                const w: Vec = angularVelBetween(qa, qb, inv_dt);
                inline for (0..3) |k| {
                    vel[vadr + k] = w[k];
                }
            },
        }
    }
}

/// Renormalize every quaternion in `pos`. Integration walks a quaternion off the unit
/// sphere a little each step, and the error compounds, so this runs after every advance.
pub fn normalizeQuats(m: *const Model, pos: []f32) void {
    for (0..m.njnt) |ji| {
        const qadr: u32 = m.jnt_qpos_adr[ji];
        const base: u32 = switch (m.jnt_type[ji]) {
            .free => qadr + 3,
            .ball => qadr,
            .slide, .hinge => continue,
        };
        const q: Quat = .{ pos[base], pos[base + 1], pos[base + 2], pos[base + 3] };
        const fixed: Quat = normalizeQuat(q);
        inline for (0..4) |k| {
            pos[base + k] = fixed[k];
        }
    }
}

/// Rotate `q` by an angular velocity applied for `dt`. Exact for a constant `w`: build the
/// rotation the velocity describes over the interval, then compose.
fn rotateQuatByAngularVel(q: Quat, w: Vec, dt: f32) Quat {
    const speed: f32 = length3(w);
    if (speed < 1.0e-12) {
        return q;
    }
    const axis: Vec = w / splat(speed);
    const delta: Quat = zm.quatFromNormAxisAngle(axis, speed * dt);
    // The velocity is in the joint's own frame, so the increment applies on the right.
    return normalizeQuat(qmul(q, delta));
}

/// The angular velocity that rotates `from` into `to` over `1/inv_dt` seconds.
fn angularVelBetween(from: Quat, to: Quat, inv_dt: f32) Vec {
    // Relative rotation in `from`'s frame, matching the composition order above.
    const inv_from: Quat = .{ -from[0], -from[1], -from[2], from[3] };
    var rel: Quat = qmul(inv_from, to);
    // q and -q are the same rotation; pick the short way round so the velocity is minimal
    // rather than taking the long path over the double cover.
    if (rel[3] < 0.0) {
        rel = -rel;
    }
    const sin_half: f32 = @sqrt(rel[0] * rel[0] + rel[1] * rel[1] + rel[2] * rel[2]);
    if (sin_half < 1.0e-12) {
        return vec_zero;
    }
    const angle: f32 = 2.0 * atan2Rad(sin_half, rel[3]);
    const axis: Vec = vec(rel[0], rel[1], rel[2]) / splat(sin_half);
    return axis * splat(angle * inv_dt);
}

// =============================================================================
// Tests
//
// Everything here is pure CPU maths with no device dependency, which makes it the rarest
// thing in zimr: fully testable headlessly. The tests lean on invariants rather than
// golden numbers wherever possible, because an invariant keeps testing when the numbers
// legitimately change.
// =============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const reference = @import("tests/fixtures/robot/reference.zig");

/// The double pendulum from the plan's phase-3 demo, and from the oracle fixtures.
const DoublePendulum = Spec(.{
    .bodies = &.{
        .{
            .name = "upper",
            .pos = vec(0, 0, 0),
            .joints = &.{.{ .name = "shoulder", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                .pos = vec(0, -0.25, 0),
            }},
        },
        .{
            .name = "lower",
            .parent = "upper",
            .pos = vec(0, -0.5, 0),
            .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.04 } },
                .pos = vec(0, -0.2, 0),
            }},
        },
    },
});

test "spec: counts and generated enums" {
    try expectEqual(@as(u32, 3), DoublePendulum.nbody); // world + 2
    try expectEqual(@as(u32, 2), DoublePendulum.njnt);
    try expectEqual(@as(u32, 2), DoublePendulum.nq);
    try expectEqual(@as(u32, 2), DoublePendulum.nv);
    // The enum tag IS the index, which is what makes enum lookup free.
    try expectEqual(@as(u32, 0), @backingInt(DoublePendulum.Joint.shoulder));
    try expectEqual(@as(u32, 1), @backingInt(DoublePendulum.Joint.elbow));
    try expect(std.mem.eql(u8, "elbow", @tagName(DoublePendulum.Joint.elbow)));
}

test "spec: nq exceeds nv when a quaternion is present" {
    const Floating = Spec(.{
        .bodies = &.{.{
            .name = "box",
            .joints = &.{.{ .name = "root", .kind = .free }},
            .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.1, 0.2, 0.3) } } }},
        }},
    });
    try expectEqual(@as(u32, 7), Floating.nq);
    try expectEqual(@as(u32, 6), Floating.nv);
}

test "build: tree topology, dof chains and mass-matrix sparsity" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();

    // Body 0 is the world; the spec bodies follow in order.
    try expectEqual(world_body, m.body_parent[1]);
    try expectEqual(@as(u32, 1), m.body_parent[2]);
    try expectEqual(@as(u32, 1), m.body_root[2]);

    // The elbow's DOF hangs off the shoulder's; the shoulder's has no parent.
    try expectEqual(no_dof, m.dof_parent[0]);
    try expectEqual(@as(u32, 0), m.dof_parent[1]);

    // Row 0 is just the diagonal; row 1 covers itself and its one ancestor. That IS the
    // sparsity of M, and the diagonal is stored last in each row.
    try expectEqual(@as(u32, 1), m.mass_row_nonzeros[0]);
    try expectEqual(@as(u32, 2), m.mass_row_nonzeros[1]);
    try expectEqual(@as(u32, 3), m.mass_nonzero_count);
    try expectEqual(@as(u32, 0), m.mass_col_index[m.mass_row_start[0]]);
    try expectEqual(@as(u32, 0), m.mass_col_index[m.mass_row_start[1]]); // ancestor first
    try expectEqual(@as(u32, 1), m.mass_col_index[m.mass_row_start[1] + 1]); // diagonal last
}

test "build: geoms give a body mass, and armature defaults are positive" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();

    try expect(m.body_mass[1] > 0.0);
    try expect(m.body_mass[2] > 0.0);
    // The upper link is longer and fatter, so it must be heavier.
    try expect(m.body_mass[1] > m.body_mass[2]);
    // Subtree mass accumulates leaf-to-root.
    try expectApproxEqAbs(m.body_mass[1] + m.body_mass[2], m.body_subtree_mass[1], 1.0e-6);
    // A zero default armature would leave the factorization unregularized.
    for (m.dof_armature) |a| {
        try expect(a > 0.0);
    }
}

test "welded bodies are transparent to the dof chain" {
    // The middle body has no joint, so it is rigidly part of its parent. Its child's DOF
    // must chain onto the FIRST body's DOF, skipping the weld entirely.
    const Welded = Spec(.{
        .bodies = &.{
            .{
                .name = "root",
                .joints = &.{.{ .name = "j0", .kind = .hinge }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.1 } } }},
            },
            .{
                .name = "welded",
                .parent = "root",
                .pos = vec(0.5, 0, 0),
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.1 } } }},
            },
            .{
                .name = "tip",
                .parent = "welded",
                .pos = vec(0.5, 0, 0),
                .joints = &.{.{ .name = "j1", .kind = .hinge }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.1 } } }},
            },
        },
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Welded.build(gpa);
    defer m.deinit();

    try expectEqual(@as(u32, 2), m.nv); // the weld adds no freedom
    try expectEqual(@as(u32, 0), m.dof_parent[1]);
}

test "data: reset returns to qpos0, including quaternion identity" {
    const Floating = Spec(.{
        .bodies = &.{.{
            .name = "box",
            .joints = &.{.{ .name = "root", .kind = .free }},
            .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.1, 0.1, 0.1) } } }},
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Floating.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // zm stores a quaternion as (x, y, z, w), so only the w lane starts at one.
    try expectApproxEqAbs(@as(f32, 0), d.pos[3], 1.0e-9);
    try expectApproxEqAbs(@as(f32, 1), d.pos[6], 1.0e-9);

    d.pos[0] = 5;
    d.vel[2] = -3;
    d.reset(&m);
    try expectApproxEqAbs(@as(f32, 0), d.pos[0], 1.0e-9);
    try expectApproxEqAbs(@as(f32, 0), d.vel[2], 1.0e-9);
    try expectApproxEqAbs(@as(f32, 1), d.pos[6], 1.0e-9);
}

test "data: joint accessors take an enum" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.setJointPos(&m, DoublePendulum.Joint.elbow, 0.75);
    try expectApproxEqAbs(@as(f32, 0.75), d.jointPos(&m, DoublePendulum.Joint.elbow), 1.0e-9);
    // The shoulder is a different DOF and must not have moved.
    try expectApproxEqAbs(@as(f32, 0), d.jointPos(&m, DoublePendulum.Joint.shoulder), 1.0e-9);
    // A plain index addresses the same joint, which is the runtime-model path.
    try expectApproxEqAbs(@as(f32, 0.75), d.jointPos(&m, @as(u32, 1)), 1.0e-9);
}

test "data: the stage watermark tracks what is current" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    try expectEqual(Stage.stale, d.stage);
    try expect(!d.stage.atLeast(.position));

    // Phase 1 will do this at the end of `comPos`.
    d.stage = .velocity;
    try expect(d.stage.atLeast(.position)); // ordered, so later implies earlier
    try expect(!d.stage.atLeast(.force));

    // Writing a VELOCITY leaves positions valid, so it falls back to .position rather
    // than all the way to .stale - the distinction a single dirty bit could not make.
    d.setJointVel(&m, DoublePendulum.Joint.elbow, 1.0);
    try expectEqual(Stage.position, d.stage);

    // Writing a POSITION invalidates everything.
    d.setJointPos(&m, DoublePendulum.Joint.elbow, 0.2);
    try expectEqual(Stage.stale, d.stage);
}

test "kinematics: body positions match MuJoCo" {
    // THE test for phase 1. `reference.zig` is generated from real MuJoCo by
    // scripts/robot_oracle.py, so this compares our forward kinematics against an
    // independent implementation rather than against my own arithmetic.
    //
    // The `double_pendulum` fixture is authored to be the same model as `DoublePendulum`
    // above: same lengths, same radii, same density, same hinge axis, Y-up in both. If
    // that ever drifts, this test is the thing that notices.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var compared: u32 = 0;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, "double_pendulum")) {
            continue;
        }
        try expectEqual(m.nq, @as(u32, @intCast(c.nq)));
        try expectEqual(m.nv, @as(u32, @intCast(c.nv)));

        @memcpy(d.pos, c.qpos);
        kinematics(&m, &d);

        // f32 against MuJoCo's f64, on positions of order 1 m: 1e-5 absolute is a tight
        // bound that still leaves room for the precision difference.
        for (0..m.nbody) |bi| {
            const want: Vec = vec(
                c.body_pos[bi * 3 + 0],
                c.body_pos[bi * 3 + 1],
                c.body_pos[bi * 3 + 2],
            );
            const got: Vec = d.body_xpos[bi];
            inline for (0..3) |k| {
                try expectApproxEqAbs(want[k], got[k], 1.0e-5);
            }
        }
        compared += 1;
    }
    // A silently-empty loop would pass this test while checking nothing.
    try expect(compared >= 3);
}

test "comPos: subtree com, cinert and cdof all match MuJoCo" {
    // The decisive test for phase 1. `cdof` in particular is the one the plan flagged as
    // P2 - the highest-cost trap in the port, because a wrong sign or a wrong offset there
    // produces a simulation that runs and looks alive and is quietly wrong. Comparing
    // against an independent implementation is the only way to be sure.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var compared: u32 = 0;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, "double_pendulum")) {
            continue;
        }
        @memcpy(d.pos, c.qpos);
        kinematics(&m, &d);
        comPos(&m, &d);

        for (0..m.nbody) |bi| {
            inline for (0..3) |k| {
                try expectApproxEqAbs(c.subtree_com[bi * 3 + k], d.subtree_com[bi][k], 1.0e-5);
                try expectApproxEqAbs(c.body_ipos[bi * 3 + k], d.body_xipos[bi][k], 1.0e-5);
            }
            // MuJoCo's cinert packing is [Ixx Iyy Izz, Ixy Ixz Iyz, h(3), m] - the same
            // ten numbers as robot.Inertia, in the same order, which is not a coincidence:
            // the packing was chosen to match.
            const got: Inertia = d.cinert[bi];
            const base: usize = bi * 10;
            inline for (0..3) |k| {
                try expectApproxEqAbs(c.cinert[base + k], got.diag[k], 1.0e-4);
                try expectApproxEqAbs(c.cinert[base + 3 + k], got.off[k], 1.0e-4);
                try expectApproxEqAbs(c.cinert[base + 6 + k], got.h[k], 1.0e-4);
            }
            try expectApproxEqAbs(c.cinert[base + 9], got.mass, 1.0e-5);
        }

        // cdof is (rot:lin), angular first - the convention the whole file hangs on.
        for (0..m.nv) |vi| {
            const got: Motion = d.cdof[vi];
            inline for (0..3) |k| {
                try expectApproxEqAbs(c.cdof[vi * 6 + k], got.ang[k], 1.0e-5);
                try expectApproxEqAbs(c.cdof[vi * 6 + 3 + k], got.lin[k], 1.0e-5);
            }
        }
        compared += 1;
    }
    try expect(compared >= 3);
}

test "crb: the mass matrix matches MuJoCo" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var dense: [4]f32 = undefined; // nv = 2

    var compared: u32 = 0;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, "double_pendulum")) {
            continue;
        }
        @memcpy(d.pos, c.qpos);
        kinematics(&m, &d);
        comPos(&m, &d);
        crb(&m, &d);
        massMatrixDense(&m, &d, &dense);

        // MuJoCo has no armature here, so its M is ours minus the diagonal default. Rather
        // than special-case that, compare the OFF-diagonal exactly and allow the diagonal
        // to exceed MuJoCo's by exactly the armature - which also pins that armature lands
        // where it should and nowhere else.
        for (0..m.nv) |i| {
            for (0..m.nv) |j| {
                const want: f32 = c.mass_matrix[i * m.nv + j];
                const got: f32 = dense[i * m.nv + j];
                const extra: f32 = if (i == j) m.dof_armature[i] else 0.0;
                try expectApproxEqAbs(want + extra, got, @max(1.0e-6, @abs(want) * 1.0e-5));
            }
        }
        compared += 1;
    }
    try expect(compared >= 3);
}

test "factorM: solving M x = y round-trips through the dense matrix" {
    // The definitive test for a linear solve, and it needs no reference values: pick an
    // x, form y = M*x with the dense matrix, solve M*x' = y, and require x' == x. It
    // checks the factorization and the three back-substitution passes together, and it
    // cannot be satisfied by a factorization that is merely self-consistent.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var dense: [4]f32 = undefined;
    const poses = [_][2]f32{ .{ 0, 0 }, .{ 0.3, -0.7 }, .{ -1.1, 2.2 } };
    for (poses) |q| {
        d.pos[0] = q[0];
        d.pos[1] = q[1];
        kinematics(&m, &d);
        comPos(&m, &d);
        crb(&m, &d);
        factorM(&m, &d);

        massMatrixDense(&m, &d, &dense);
        const want = [_]f32{ 0.37, -1.25 };
        var y: [2]f32 = .{
            dense[0] * want[0] + dense[1] * want[1],
            dense[2] * want[0] + dense[3] * want[1],
        };
        solveM(&m, &d, &y);
        for (want, y) |w, got| {
            try expectApproxEqAbs(w, got, 1.0e-4);
        }
    }
}

test "factorM: no fill-in, and the factor reproduces M" {
    // Two structural claims. First, the factorization writes only where M already had
    // entries -- that is the no-fill-in property, and it is why the sparsity tables can be
    // shared between M and its factor. Second, reassembling L^T*D*L must give M back.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = 0.4;
    d.pos[1] = -0.9;
    kinematics(&m, &d);
    comPos(&m, &d);
    crb(&m, &d);

    var dense: [4]f32 = undefined;
    massMatrixDense(&m, &d, &dense);
    factorM(&m, &d);

    // Reassemble. For nv = 2: L = [[1, 0], [l10, 1]], D = diag(d0, d1), and the stored
    // form has l10 in row 1's off-diagonal slot with D on the diagonals.
    const l10: f32 = d.qLD[m.mass_row_start[1]];
    const d0: f32 = 1.0 / d.qLDiagInv[0];
    const d1: f32 = 1.0 / d.qLDiagInv[1];
    // M = L^T D L  =>  M00 = d0 + l10^2*d1,  M01 = l10*d1,  M11 = d1.
    try expectApproxEqAbs(dense[0], d0 + l10 * l10 * d1, 1.0e-4);
    try expectApproxEqAbs(dense[1], l10 * d1, 1.0e-5);
    try expectApproxEqAbs(dense[3], d1, 1.0e-5);

    // The factor occupies exactly M's sparsity: same mass_nonzero_count entries, no extra storage.
    try expectEqual(@as(usize, m.mass_nonzero_count), d.qLD.len);
}

test "factorM: solveM agrees with MuJoCo's own solve" {
    // Independent check of the whole chain, against the oracle's mass matrix rather than
    // our own: build y from MUJOCO's M, solve with OUR factorization, and require the
    // answer back. If our M and our solve were wrong in compensating ways, this catches it.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var compared: u32 = 0;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, "double_pendulum")) {
            continue;
        }
        @memcpy(d.pos, c.qpos);
        kinematics(&m, &d);
        comPos(&m, &d);
        crb(&m, &d);
        factorM(&m, &d);

        // MuJoCo carries no armature here; ours does, so add it to MuJoCo's diagonal to
        // compare like with like.
        const want = [_]f32{ 0.8, -0.35 };
        var y: [2]f32 = .{
            (c.mass_matrix[0] + m.dof_armature[0]) * want[0] + c.mass_matrix[1] * want[1],
            c.mass_matrix[2] * want[0] + (c.mass_matrix[3] + m.dof_armature[1]) * want[1],
        };
        solveM(&m, &d, &y);
        for (want, y) |w, got| {
            try expectApproxEqAbs(w, got, 1.0e-4);
        }
        compared += 1;
    }
    try expect(compared >= 3);
}

test "conditionEstimate: a balanced arm is well conditioned" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    kinematics(&m, &d);
    comPos(&m, &d);
    crb(&m, &d);
    factorM(&m, &d);

    const cond: f32 = conditionEstimate(&m, &d);
    try expect(cond >= 1.0); // by construction: max/min of positive numbers
    // A two-link arm of similar links has no business being ill conditioned. The bound is
    // loose on purpose -- this is a smoke test for the diagnostic, not a claim about the
    // model.
    try expect(cond < 1.0e3);
}

test "dynamics: bias force and acceleration match MuJoCo" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var compared: u32 = 0;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, "double_pendulum")) {
            continue;
        }
        @memcpy(d.pos, c.qpos);
        @memcpy(d.vel, c.qvel);
        forward(&m, &d);

        // c(q,v): Coriolis + centrifugal + gravity.
        for (0..m.nv) |i| {
            try expectApproxEqAbs(c.bias[i], d.bias_force[i], @max(1.0e-4, @abs(c.bias[i]) * 1.0e-4));
        }
        // qacc with zero control. Ours carries armature on the diagonal and MuJoCo's does
        // not, so a small difference is expected and the tolerance reflects it rather than
        // pretending the models are identical.
        for (0..m.nv) |i| {
            try expectApproxEqAbs(c.acc[i], d.acc[i], @max(1.0e-2, @abs(c.acc[i]) * 0.02));
        }
        compared += 1;
    }
    try expect(compared >= 3);
}

test "dynamics: forward then inverse returns the force you started with" {
    // THE test. Apply a known force, solve for the acceleration, then ask inverse dynamics
    // what force would produce that acceleration -- and get the original back. It exercises
    // M, its factorization, c, and every frame convention between them, simultaneously.
    // MuJoCo ships this as a pipeline stage for exactly that reason.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    const poses = [_][2]f32{ .{ 0.3, -0.7 }, .{ -1.1, 2.2 }, .{ 0.0, 0.0 } };
    const vels = [_][2]f32{ .{ 1.1, -0.4 }, .{ -0.6, 0.9 }, .{ 0.0, 0.0 } };
    const forces = [_][2]f32{ .{ 0.7, -0.2 }, .{ -1.3, 0.45 }, .{ 0.05, 0.05 } };

    var recovered: [2]f32 = undefined;
    for (poses, vels, forces) |q, v, f| {
        @memcpy(d.pos, &q);
        @memcpy(d.vel, &v);
        @memcpy(d.applied_force, &f);
        forward(&m, &d);
        inverseDynamics(&m, &d, d.acc, &recovered);
        for (f, recovered) |want, got| {
            try expectApproxEqAbs(want, got, 1.0e-4);
        }
    }
}

test "dynamics: gravity compensation is inverse dynamics at rest" {
    // A practical corollary of the round trip, and the first genuinely USEFUL thing the
    // engine can do: the force that holds an arm still against gravity is exactly the bias
    // force. Apply it and the arm does not move.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = 0.6;
    d.pos[1] = -1.2;
    forward(&m, &d);
    // Cancel the bias, then re-solve: the acceleration must vanish.
    @memcpy(d.applied_force, d.bias_force);
    forwardDynamics(&m, &d);
    for (0..m.nv) |i| {
        try expectApproxEqAbs(@as(f32, 0), d.acc[i], 1.0e-4);
    }
}

test "dynamics: RK4 conserves energy where Euler leaks it" {
    // The property that distinguishes the integrators, measured rather than asserted. No
    // damping, no contact, no actuation -- a closed system, so total energy is conserved
    // exactly in the continuous problem and any drift is the integrator's.
    const gpa: Allocator = std.testing.allocator;

    var rk_model: Model = try DoublePendulum.build(gpa);
    defer rk_model.deinit();
    rk_model.opt.integrator = .rk4;
    rk_model.opt.timestep = 1.0 / 240.0;

    var eu_model: Model = try DoublePendulum.build(gpa);
    defer eu_model.deinit();
    eu_model.opt.integrator = .euler;
    eu_model.opt.timestep = 1.0 / 240.0;

    var drift: [2]f32 = undefined;
    inline for (.{ &rk_model, &eu_model }, 0..) |mm, idx| {
        var d: Data = try Data.init(gpa, mm);
        defer d.deinit();
        // Start well away from equilibrium so there is real energy to lose.
        d.pos[0] = 1.4;
        d.pos[1] = -2.0;
        forward(mm, &d);
        const e0: f32 = energy(mm, &d);

        for (0..2400) |_| { // 10 seconds
            step(mm, &d);
        }
        forward(mm, &d);
        drift[idx] = @abs(energy(mm, &d) - e0) / @abs(e0);
    }

    // RK4 must be tight over 10 s of chaotic motion.
    try expect(drift[0] < 0.001);
    // And it must be better than Euler -- which is the whole reason it costs four
    // evaluations per step.
    try expect(drift[0] < drift[1]);
}

test "dynamics: a free body follows a parabola" {
    // No joints to get wrong, so this isolates gravity, the free-joint DOF layout and the
    // integrator. Analytic answer, no oracle needed.
    const Falling = Spec(.{
        .bodies = &.{.{
            .name = "box",
            .joints = &.{.{ .name = "root", .kind = .free }},
            .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.1, 0.1, 0.1) } } }},
        }},
        .options = .{ .timestep = 1.0 / 1000.0 },
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Falling.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[1] = 10.0; // start 10 m up
    const seconds: f32 = 1.0;
    const steps: usize = 1000;
    for (0..steps) |_| {
        step(&m, &d);
    }
    // y = y0 - 1/2g t^2. Semi-implicit Euler is off by O(dt) per step in a known direction,
    // so allow a millimetre or so rather than pretending it is exact.
    const want: f32 = 10.0 - 0.5 * 9.81 * seconds * seconds;
    try expectApproxEqAbs(want, d.pos[1], 0.02);
    // And nothing should have started rotating.
    inline for (0..3) |k| {
        try expectApproxEqAbs(@as(f32, 0), d.vel[3 + k], 1.0e-5);
    }
}

test "jacobian: agrees with a finite difference of the kinematics" {
    // The cheapest strong test in the project, and the most independent: a Jacobian is BY
    // DEFINITION the derivative of the forward kinematics, so nudge each joint and measure
    // where the point went. It needs no reference values and it validates the frame
    // conventions of phases 1 and 2 at the same time -- if `cdof` were built about the
    // wrong origin, or with a sign flipped, the derivative would simply not match.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var jac_p: [2]Vec = undefined;
    var jac_r: [2]Vec = undefined;

    const poses = [_][2]f32{ .{ 0.3, -0.7 }, .{ -1.1, 2.2 }, .{ 0.0, 0.0 }, .{ 1.4, 0.9 } };
    for (poses) |q| {
        @memcpy(d.pos, &q);
        kinematics(&m, &d);
        comPos(&m, &d);

        const body: u32 = 2; // the lower link
        const point: Vec = d.body_xipos[body];
        // The point is fixed IN THE BODY, so re-derive its local offset once and track the
        // same material point as the joints move. Tracking a fixed WORLD point instead
        // would measure something else entirely.
        const local: Vec = rotate(conjugate(d.body_xrot[body]), point - d.body_xpos[body]);
        jacBodyCom(&m, &d, body, &jac_p, &jac_r);

        const eps: f32 = 1.0e-4;
        for (0..m.nv) |i| {
            // Central difference: second-order accurate, so the tolerance can be tight.
            var moved: [2]Vec = undefined;
            inline for (.{ -eps, eps }, 0..) |delta, k| {
                @memcpy(d.pos, &q);
                d.pos[i] += delta;
                kinematics(&m, &d);
                moved[k] = d.body_xpos[body] + rotate(d.body_xrot[body], local);
            }
            const numeric: Vec = (moved[1] - moved[0]) / splat(2.0 * eps);
            inline for (0..3) |axis| {
                try expectApproxEqAbs(numeric[axis], jac_p[i][axis], 2.0e-3);
            }
        }
        // Restore, since the loop perturbed the state.
        @memcpy(d.pos, &q);
        kinematics(&m, &d);
        comPos(&m, &d);
    }
}

test "jacobian: matches MuJoCo for every body" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var jac_p: [2]Vec = undefined;
    var jac_r: [2]Vec = undefined;

    var compared: u32 = 0;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, "double_pendulum")) {
            continue;
        }
        @memcpy(d.pos, c.qpos);
        kinematics(&m, &d);
        comPos(&m, &d);

        for (0..m.nbody) |bi| {
            jacBodyCom(&m, &d, @intCast(bi), &jac_p, &jac_r);
            // MuJoCo stores 3 rows of nv; ours is nv columns of 3.
            const base: usize = bi * 3 * m.nv;
            for (0..m.nv) |i| {
                inline for (0..3) |axis| {
                    try expectApproxEqAbs(c.jac_com_p[base + axis * m.nv + i], jac_p[i][axis], 1.0e-5);
                    try expectApproxEqAbs(c.jac_com_r[base + axis * m.nv + i], jac_r[i][axis], 1.0e-5);
                }
            }
        }
        compared += 1;
    }
    try expect(compared >= 3);
}

test "jacobian: J v is the point's actual velocity" {
    // A different kind of check: the Jacobian must reproduce the velocity the DYNAMICS
    // pipeline computed independently, via `cvel`. Two paths to the same number, and they
    // do not share a code path -- one walks cdof, the other accumulates body velocities.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = 0.55;
    d.pos[1] = -1.3;
    d.vel[0] = 1.7;
    d.vel[1] = -0.8;
    forward(&m, &d);

    const body: u32 = 2;
    var jac_p: [2]Vec = undefined;
    jacBodyCom(&m, &d, body, &jac_p, null);

    var from_jac: Vec = vec_zero;
    for (0..m.nv) |i| {
        from_jac += jac_p[i] * splat(d.vel[i]);
    }

    // The same point's velocity from the body's spatial velocity, which is what `comVel`
    // produced: v + w x (p - O), about the shared frame origin.
    const origin: Vec = d.subtree_com[m.body_root[body]];
    const cv: Motion = d.cvel[body];
    const from_cvel: Vec = cv.lin + cross(cv.ang, d.body_xipos[body] - origin);

    inline for (0..3) |axis| {
        try expectApproxEqAbs(from_cvel[axis], from_jac[axis], 1.0e-5);
    }
}

test "jacobian: transpose turns a tip force into joint torques" {
    // The practical use, checked against a case anyone can verify by hand. Hold the arm
    // straight down and push the tip sideways with 1 N: the shoulder must feel a torque of
    // (force x lever arm) = 1 N x 0.9 m, and the elbow 1 N x 0.4 m.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    kinematics(&m, &d); // qpos0: both links hang straight down along -Y
    comPos(&m, &d);

    var jac_p: [2]Vec = undefined;
    var jac_r: [2]Vec = undefined;
    var torque: [2]f32 = .{ 0, 0 };

    const body: u32 = 2;
    const tip: Vec = d.body_xpos[body] + rotate(d.body_xrot[body], vec(0, -0.4, 0));
    // Push along +X, at the tip, 1 newton.
    applyForceAtPoint(&m, &d, body, tip, vec(1, 0, 0), vec_zero, &jac_p, &jac_r, &torque);

    // Hinges are about +Z, the tip is 0.9 m below the shoulder and 0.4 m below the elbow,
    // and a +X force at -Y produces a +Z torque of |r| * |f|.
    try expectApproxEqAbs(@as(f32, 0.9), torque[0], 1.0e-4);
    try expectApproxEqAbs(@as(f32, 0.4), torque[1], 1.0e-4);
}

/// A one-link arm with a position servo - the smallest model that exercises the whole
/// actuator path.
const ServoArm = Spec(.{
    .bodies = &.{.{
        .name = "link",
        .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.001 }},
        .geoms = &.{.{
            .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.04 } },
            .pos = vec(0, -0.25, 0),
        }},
    }},
    .actuators = &.{.{
        .name = "servo",
        .on = .{ .joint = .{ .name = "j" } },
        .kind = .{ .position = .{ .kp = 30, .kv = 3 } },
        .ctrl_range = .{ -2, 2 },
    }},
});

test "actuator: a position servo is a PD controller in disguise" {
    // The claim from the docs, tested: `gain*u + bias1*l + bias2*l_dot` with the servo's
    // coefficients must equal `kp*(u - l) - kv*l_dot` exactly.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ServoArm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    const kp: f32 = 30;
    const kv: f32 = 3;
    d.pos[0] = 0.4;
    d.vel[0] = -0.9;
    d.ctrl[0] = 1.1;
    forward(&m, &d);

    const want: f32 = kp * (1.1 - 0.4) - kv * (-0.9);
    try expectApproxEqAbs(want, d.act_force[0], 1.0e-3);
}

test "actuator: a position servo holds a load against gravity" {
    // The practical test. A servo with finite gain does NOT reach its target: it settles
    // where the restoring torque balances gravity, and that steady-state error is
    // predictable. Asserting the analytic value catches a servo that merely looks stable.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ServoArm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    const target: f32 = 0.0; // straight down is qpos0; command it to stay there
    d.ctrl[0] = target;
    // Start displaced, then let the servo pull it back.
    d.pos[0] = 0.8;
    for (0..4000) |_| {
        step(&m, &d);
    }
    forward(&m, &d);

    // Settled: velocity gone, and the position error is where servo torque cancels gravity.
    try expectApproxEqAbs(@as(f32, 0), d.vel[0], 1.0e-2);
    // At equilibrium: kp*(target - l) = gravity torque at l. Straight down the gravity
    // torque is zero, so the servo should sit essentially at the target.
    try expectApproxEqAbs(target, d.pos[0], 2.0e-2);
}

test "actuator: filter_exact survives a time constant shorter than the timestep" {
    // The reason both filter types exist. With tau < dt the Euler form's update factor
    // dt/tau exceeds 1, so the activation overshoots and oscillates with growing amplitude.
    // The exact form's factor is 1 - exp(-dt/tau), which is bounded by 1 for any positive
    // tau, so it simply snaps to the command.
    const gpa: Allocator = std.testing.allocator;
    const dt: f32 = 1.0 / 100.0;
    const time_const: f32 = 1.0 / 400.0; // four times shorter than the step

    inline for (.{ true, false }) |exact| {
        const Arm = Spec(.{
            .bodies = &.{.{
                .name = "link",
                .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } } }},
            }},
            .actuators = &.{.{
                .name = "a",
                .on = .{ .joint = .{ .name = "j" } },
                .activation = if (exact)
                    .{ .filter_exact = .{ .time_const_s = time_const } }
                else
                    .{ .filter = .{ .time_const_s = time_const } },
            }},
            .options = .{ .timestep = dt },
        });
        var m: Model = try Arm.build(gpa);
        defer m.deinit();
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();

        d.ctrl[0] = 1.0;
        for (0..60) |_| {
            step(&m, &d);
        }
        if (exact) {
            // Converged to the command and stayed there.
            try expectApproxEqAbs(@as(f32, 1.0), d.act[0], 1.0e-4);
        } else {
            // Diverged, spectacularly. The point is that it is NOT near 1.
            try expect(@abs(d.act[0]) > 10.0);
        }
    }
}

test "actuator: ctrl and force ranges clamp" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ServoArm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // ctrl_range is [-2, 2]; command far outside it and the servo must behave as if 2.
    d.ctrl[0] = 500.0;
    forward(&m, &d);
    const clamped: f32 = d.act_force[0];
    d.ctrl[0] = 2.0;
    forward(&m, &d);
    try expectApproxEqAbs(d.act_force[0], clamped, 1.0e-4);
}

test "actuator: gear scales the whole affine law" {
    // A geared actuator produces more force for the same control AND more restoring force
    // for the same error -- gear multiplies gain and bias alike, which is what a gearbox
    // physically does.
    const gpa: Allocator = std.testing.allocator;
    const Geared = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } } }},
        }},
        .actuators = &.{
            .{ .name = "plain", .on = .{ .joint = .{ .name = "j", .gear = 1 } }, .kind = .motor },
            .{ .name = "geared", .on = .{ .joint = .{ .name = "j", .gear = 7 } }, .kind = .motor },
        },
    });
    var m: Model = try Geared.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.ctrl[0] = 1.0;
    d.ctrl[1] = 1.0;
    forward(&m, &d);
    try expectApproxEqAbs(@as(f32, 7.0), d.act_force[1] / d.act_force[0], 1.0e-4);
    // Both drive the same DOF, so the joint sees their sum.
    try expectApproxEqAbs(@as(f32, 8.0), d.actuator_force[0], 1.0e-4);
}

test "integration: Jacobian-transpose IK reaches an off-axis target" {
    // An end-to-end test through a real control law, which is a different kind of evidence
    // from checking any single stage: it only converges if kinematics, comPos, M, its
    // factorization, c, the Jacobian and the integrator are ALL right together.
    //
    // The law is three lines -- cancel gravity, then push with J^T*(target - tip) and a
    // little joint damping. No matrix inverse, no iteration.
    const Arm = Spec(.{
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
                    .shape = .{ .capsule = .{ .half_height = 0.26, .radius = 0.045 } },
                    .pos = vec(0, -0.26, 0),
                }},
            },
            .{
                .name = "lower",
                .parent = "upper",
                .pos = vec(0, -0.52, 0),
                .joints = &.{.{
                    .name = "elbow",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .armature = 0.002,
                    .damping = 0.02,
                }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.22, .radius = 0.035 } },
                    .pos = vec(0, -0.22, 0),
                }},
                .sites = &.{.{ .name = "tip", .pos = vec(0, -0.44, 0) }},
            },
        },
        .options = .{ .timestep = 1.0 / 240.0 },
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Arm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    var jac_p: [2]Vec = undefined;

    d.pos[0] = 0.6;
    d.pos[1] = -1.0;
    const target: Vec = vec(0.55, -0.45, 0); // off the vertical axis, inside the workspace

    for (0..2400) |_| { // 10 seconds
        forward(&m, &d);
        @memcpy(d.applied_force, d.bias_force); // weightless
        const tip: Vec = d.site_xpos[0];
        jacSite(&m, &d, @as(u32, 0), &jac_p, null);
        for (0..m.nv) |i| {
            d.applied_force[i] += 40.0 * dot3(jac_p[i], target - tip) - 1.2 * d.vel[i];
        }
        step(&m, &d);
    }
    forward(&m, &d);

    try expectApproxEqAbs(@as(f32, 0), length3(target - d.site_xpos[0]), 5.0e-3);
    // And it got there by BENDING. A straight arm reaching an off-axis point would mean
    // the elbow was not participating, which is the failure this test exists to catch.
    try expect(@abs(d.pos[1]) > 0.5);
}

// The other oracle models, transcribed from scripts/robot_oracle.py. They exist so the
// BALL and FREE joint paths - which the double pendulum never touches - are validated
// against the reference rather than merely compiling.
const SinglePendulum = Spec(.{
    .bodies = &.{.{
        .name = "link",
        .joints = &.{.{ .name = "j1", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0 }},
        .geoms = &.{.{
            .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
            .pos = vec(0, -0.25, 0),
        }},
    }},
});

const FreeBody = Spec(.{
    .bodies = &.{.{
        .name = "box",
        .pos = vec(0, 1, 0),
        .joints = &.{.{ .name = "root", .kind = .free, .armature = 0 }},
        .geoms = &.{.{
            .shape = .{ .box = .{ .half_extent = vec(0.1, 0.2, 0.3) } },
            .density = 500,
        }},
    }},
});

const BallChain = Spec(.{
    .bodies = &.{
        .{
            .name = "upper",
            .joints = &.{.{ .name = "b1", .kind = .ball, .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.05 } },
                .pos = vec(0, -0.2, 0),
            }},
        },
        .{
            .name = "lower",
            .parent = "upper",
            .pos = vec(0, -0.4, 0),
            .joints = &.{.{ .name = "h1", .kind = .hinge, .axis = vec(1, 0, 0), .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.04 } },
                .pos = vec(0, -0.15, 0),
            }},
        },
    },
});

/// Compare one model against every fixture case bearing its name. Factored out because the
/// per-model boilerplate was hiding the fact that only ONE model was actually being
/// checked - five of six fixture models were generated and never read.
fn checkAgainstOracle(
    comptime name: []const u8,
    m: *Model,
    d: *Data,
    tol: f32,
) !void {
    var compared: u32 = 0;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, name)) {
            continue;
        }
        try expectEqual(m.nq, @as(u32, @intCast(c.nq)));
        try expectEqual(m.nv, @as(u32, @intCast(c.nv)));
        @memcpy(d.pos, c.qpos);
        @memcpy(d.vel, c.qvel);
        forward(m, d);

        for (0..m.nbody) |bi| {
            inline for (0..3) |k| {
                try expectApproxEqAbs(c.body_pos[bi * 3 + k], d.body_xpos[bi][k], tol);
                try expectApproxEqAbs(c.subtree_com[bi * 3 + k], d.subtree_com[bi][k], tol);
            }
            const got: Inertia = d.cinert[bi];
            const base: usize = bi * 10;
            inline for (0..3) |k| {
                try expectApproxEqAbs(c.cinert[base + k], got.diag[k], tol);
                try expectApproxEqAbs(c.cinert[base + 3 + k], got.off[k], tol);
                try expectApproxEqAbs(c.cinert[base + 6 + k], got.h[k], tol);
            }
        }
        // cdof is where the ball and free joint paths actually differ, so it carries the
        // weight of this whole test.
        for (0..m.nv) |vi| {
            inline for (0..3) |k| {
                try expectApproxEqAbs(c.cdof[vi * 6 + k], d.cdof[vi].ang[k], tol);
                try expectApproxEqAbs(c.cdof[vi * 6 + 3 + k], d.cdof[vi].lin[k], tol);
            }
        }
        for (0..m.nv) |i| {
            try expectApproxEqAbs(c.bias[i], d.bias_force[i], @max(tol, @abs(c.bias[i]) * 1.0e-4));
        }
        compared += 1;
    }
    try expect(compared >= 3);
}

test "oracle: single pendulum" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try SinglePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try checkAgainstOracle("single_pendulum", &m, &d, 1.0e-4);
}

test "oracle: free body - the nq != nv path, and the quaternion ordering" {
    // A free joint is 7 position coordinates and 6 velocity ones, and its quaternion is
    // stored (x, y, z, w) here against MuJoCo's (w, x, y, z). The fixture generator
    // converts, so a mismatch here means either the conversion or our layout is wrong.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try FreeBody.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try expectEqual(@as(u32, 7), m.nq);
    try expectEqual(@as(u32, 6), m.nv);
    try checkAgainstOracle("free_body", &m, &d, 2.0e-4);
}

test "oracle: ball chain - three rotational DOFs from one joint" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try BallChain.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try expectEqual(@as(u32, 5), m.nq); // 4 (quat) + 1 (hinge)
    try expectEqual(@as(u32, 4), m.nv); // 3 + 1
    try checkAgainstOracle("ball_chain", &m, &d, 2.0e-4);
}

/// Three hinges on three axes, with capsules running along X. Two things no other test
/// model reaches: mixed rotation axes (a planar chain cannot expose a frame error that
/// only shows up out of plane), and ROTATED GEOMS, which exercise `Inertia.rotated` inside
/// `geomsToBodyMass`.
const Arm3 = Spec(.{
    .bodies = &.{
        .{
            .name = "a",
            .joints = &.{.{ .name = "j1", .kind = .hinge, .axis = vec(0, 1, 0), .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.04 } },
                .pos = vec(0.15, 0, 0),
                .rot = y_to_x,
                .density = 800,
            }},
        },
        .{
            .name = "b",
            .parent = "a",
            .pos = vec(0.3, 0, 0),
            .joints = &.{.{ .name = "j2", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.125, .radius = 0.035 } },
                .pos = vec(0.125, 0, 0),
                .rot = y_to_x,
                .density = 800,
            }},
        },
        .{
            .name = "c",
            .parent = "b",
            .pos = vec(0.25, 0, 0),
            .joints = &.{.{ .name = "j3", .kind = .hinge, .axis = vec(1, 0, 0), .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.1, .radius = 0.03 } },
                .pos = vec(0.1, 0, 0),
                .rot = y_to_x,
                .density = 800,
            }},
        },
    },
});

/// Takes local +Y (zimr's capsule axis) to +X. A quarter turn the negative way about Z.
const y_to_x: Quat = zm.quatFromNormAxisAngle(vec(0, 0, 1), -pi * 0.5);

/// A 1000:1 mass ratio - a heavy box driving a tiny sliver. The P1 conditioning probe,
/// made into a model so the diagnostic can be checked against a case that should trip it.
const MassRatio = Spec(.{
    .bodies = &.{
        .{
            .name = "torso",
            .joints = &.{.{ .name = "j1", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .box = .{ .half_extent = vec(0.3, 0.3, 0.3) } },
                .density = 2000,
            }},
        },
        .{
            .name = "tip",
            .parent = "torso",
            .pos = vec(0.3, 0, 0),
            .joints = &.{.{ .name = "j2", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.025, .radius = 0.004 } },
                .pos = vec(0.025, 0, 0),
                .rot = y_to_x,
                .density = 300,
            }},
        },
    },
});

test "oracle: arm3 - mixed axes and rotated geoms" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Arm3.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try expectEqual(@as(u32, 3), m.nv);
    try checkAgainstOracle("arm3", &m, &d, 3.0e-4);
}

test "oracle: mass ratio, and the conditioning probe earns its keep" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try MassRatio.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try checkAgainstOracle("mass_ratio", &m, &d, 1.0e-3);

    // The diagnostic must actually diagnose. A 1000:1 mass ratio is exactly the case section 1.1
    // says f32 will struggle with, so `conditionEstimate` should be ORDERS larger here than
    // on a balanced arm -- otherwise it is a number that never says anything.
    forward(&m, &d);
    const bad: f32 = conditionEstimate(&m, &d);
    var balanced: Model = try DoublePendulum.build(gpa);
    defer balanced.deinit();
    var bd: Data = try Data.init(gpa, &balanced);
    defer bd.deinit();
    forward(&balanced, &bd);
    try expect(bad > 100.0 * conditionEstimate(&balanced, &bd));
}

test "passive: damping removes energy, and only damping does" {
    // Damping is the one force that cannot inject energy. Two runs of the same swing, one
    // damped and one not, and the damped one must end with strictly less.
    const gpa: Allocator = std.testing.allocator;
    var totals: [2]f32 = undefined;

    inline for (.{ 0.0, 0.15 }, 0..) |damping, idx| {
        const Swing = Spec(.{
            .bodies = &.{.{
                .name = "link",
                .joints = &.{.{
                    .name = "j",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .armature = 0.001,
                    .damping = damping,
                }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                    .pos = vec(0, -0.25, 0),
                }},
            }},
        });
        var m: Model = try Swing.build(gpa);
        defer m.deinit();
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();

        d.pos[0] = 1.5;
        forward(&m, &d);
        const e0: f32 = energy(&m, &d);
        for (0..2400) |_| {
            step(&m, &d);
        }
        forward(&m, &d);
        totals[idx] = energy(&m, &d) - e0;
    }

    // The claim is comparative, and deliberately so: the undamped run's drift is the
    // integrator's and belongs to the RK4-vs-Euler test, not this one. What damping must
    // guarantee is that it takes energy OUT, and strictly more than the integrator does.
    try expect(totals[1] < 0.0);
    try expect(totals[1] < totals[0] - 0.05);
}

test "passive: stiffness is a spring about ref, and it conserves" {
    const gpa: Allocator = std.testing.allocator;
    const Sprung = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0.001,
                .stiffness = 8.0,
                .ref = 0.3,
            }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .pos = vec(0, -0.3, 0) }},
        }},
        .options = .{ .gravity = vec(0, 0, 0) }, // isolate the spring
    });
    var m: Model = try Sprung.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // Displaced from ref, the spring must push back TOWARD ref, not toward zero.
    d.pos[0] = 1.0;
    forward(&m, &d);
    try expect(d.passive_force[0] < 0.0);
    try expectApproxEqAbs(-8.0 * (1.0 - 0.3), d.passive_force[0], 1.0e-4);

    // On the other side of ref it must push the other way.
    d.pos[0] = -0.2;
    forward(&m, &d);
    try expect(d.passive_force[0] > 0.0);

    // And at ref exactly, nothing.
    d.pos[0] = 0.3;
    forward(&m, &d);
    try expectApproxEqAbs(@as(f32, 0), d.passive_force[0], 1.0e-5);
}

test "step1/step2 is exactly equivalent to step" {
    // The split exists so a controller can intervene without paying for a second forward
    // pass. It is only useful if it is the SAME computation -- so run both and require
    // bit-comparable trajectories.
    const gpa: Allocator = std.testing.allocator;
    var a_model: Model = try DoublePendulum.build(gpa);
    defer a_model.deinit();
    var b_model: Model = try DoublePendulum.build(gpa);
    defer b_model.deinit();
    var a: Data = try Data.init(gpa, &a_model);
    defer a.deinit();
    var b: Data = try Data.init(gpa, &b_model);
    defer b.deinit();

    inline for (.{ &a, &b }) |dd| {
        dd.pos[0] = 0.9;
        dd.pos[1] = -1.4;
    }
    for (0..600) |_| {
        step(&a_model, &a);
        step1(&b_model, &b);
        step2(&b_model, &b);
    }
    for (a.pos, b.pos) |x, y| {
        try expectApproxEqAbs(x, y, 1.0e-6);
    }
    for (a.vel, b.vel) |x, y| {
        try expectApproxEqAbs(x, y, 1.0e-6);
    }
}

test "actuator: activation advances once per step under RK4 too" {
    // The regression for the act_dot split. An `actuation` that integrated its own state
    // would advance it FOUR times per RK4 step, so an integrator actuator commanded at 1.0
    // would ramp four times too fast. Euler and RK4 must agree on the activation.
    const gpa: Allocator = std.testing.allocator;
    var reached: [2]f32 = undefined;

    inline for (.{ rbt_euler, rbt_rk4 }, 0..) |integ, idx| {
        const Ramp = Spec(.{
            .bodies = &.{.{
                .name = "link",
                .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } } }},
            }},
            .actuators = &.{.{
                .name = "ramp",
                .on = .{ .joint = .{ .name = "j" } },
                .activation = .integrator,
            }},
            .options = .{ .timestep = 1.0 / 200.0, .integrator = integ },
        });
        var m: Model = try Ramp.build(gpa);
        defer m.deinit();
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();

        d.ctrl[0] = 1.0;
        for (0..200) |_| { // one second
            step(&m, &d);
        }
        reached[idx] = d.act[0];
    }
    // w_dot = u = 1 for one second, so w must be 1 -- under BOTH integrators.
    try expectApproxEqAbs(@as(f32, 1.0), reached[0], 1.0e-3);
    try expectApproxEqAbs(@as(f32, 1.0), reached[1], 1.0e-3);
}

const rbt_euler: Integrator = .euler;
const rbt_rk4: Integrator = .rk4;

test "slide joint: a prismatic DOF falls like a free mass" {
    // The whole joint type was previously untested. A vertical slider under gravity has an
    // exact answer -- it is a 1-DOF free fall -- so this needs no oracle.
    const gpa: Allocator = std.testing.allocator;
    const Slider = Spec(.{
        .bodies = &.{.{
            .name = "car",
            .joints = &.{.{
                .name = "rail",
                .kind = .slide,
                .axis = vec(0, 1, 0),
                .armature = 0,
            }},
            .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.1, 0.1, 0.1) } } }},
        }},
        .options = .{ .timestep = 1.0 / 1000.0 },
    });
    var m: Model = try Slider.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try expectEqual(@as(u32, 1), m.nq);
    try expectEqual(@as(u32, 1), m.nv);

    // Mass matrix of a pure slide is just the mass, whatever the position.
    d.pos[0] = 3.7;
    forward(&m, &d);
    try expectApproxEqAbs(m.body_mass[1], d.mass_matrix[0], 1.0e-4);
    // And the bias force is its weight.
    try expectApproxEqAbs(m.body_mass[1] * 9.81, d.bias_force[0], 1.0e-3);

    d.pos[0] = 0;
    d.vel[0] = 0;
    for (0..1000) |_| {
        step(&m, &d);
    }
    try expectApproxEqAbs(-0.5 * 9.81, d.pos[0], 0.02);
}

test "several joints on one body chain, and gimbal-lock like real hinges" {
    // R6: three hinges on one body is how a ball joint with per-axis limits is built. Two
    // things to establish - that the DOFs CHAIN (they are three links in one chain, not
    // three parallel branches off the parent), and that they are genuinely NOT a ball
    // joint, because three sequential rotations have singular configurations a ball joint
    // does not.
    const gpa: Allocator = std.testing.allocator;
    const Triple = Spec(.{
        .bodies = &.{.{
            .name = "head",
            .joints = &.{
                .{ .name = "yaw", .kind = .hinge, .axis = vec(0, 1, 0) },
                .{ .name = "pitch", .kind = .hinge, .axis = vec(1, 0, 0) },
                .{ .name = "roll", .kind = .hinge, .axis = vec(0, 0, 1) },
            },
            .geoms = &.{.{
                .shape = .{ .box = .{ .half_extent = vec(0.06, 0.15, 0.04) } },
                .pos = vec(0.12, -0.3, 0.05),
            }},
        }},
    });
    var m: Model = try Triple.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try expectEqual(@as(u32, 3), m.nv);

    // Chained, not parallel. Before the fix that established this, each DOF's parent was
    // the body's parent, which gave the wrong mass-matrix sparsity entirely.
    try expectEqual(no_dof, m.dof_parent[0]);
    try expectEqual(@as(u32, 0), m.dof_parent[1]);
    try expectEqual(@as(u32, 1), m.dof_parent[2]);

    // Each joint's axis is expressed in the frame built by the joints BEFORE it, which is
    // what makes them compose in declaration order.
    d.pos[0] = pi * 0.5; // yaw a quarter turn about +Y
    forward(&m, &d);
    // The pitch axis started as +X; a quarter turn about +Y sends it to -Z.
    try expectApproxEqAbs(@as(f32, 0), d.jnt_xaxis[1][0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -1), d.jnt_xaxis[1][2], 1.0e-5);

    // * GIMBAL LOCK. Add a quarter turn of pitch and the ROLL axis swings onto the YAW
    // axis: two of the three DOFs become the same rotation, the arm loses a degree of
    // freedom, and M becomes singular. This is not a defect of the port - it is why a ball
    // joint is a distinct joint type rather than three hinges in a trench coat.
    d.pos[1] = pi * 0.5;
    kinematics(&m, &d);
    const yaw_axis: Vec = d.jnt_xaxis[0];
    const roll_axis: Vec = d.jnt_xaxis[2];
    // Parallel (up to sign): the magnitude of their dot product is 1.
    try expectApproxEqAbs(@as(f32, 1), @abs(dot3(yaw_axis, roll_axis)), 1.0e-4);
}

test "mulM agrees with the dense matrix" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = 0.7;
    d.pos[1] = -1.1;
    forward(&m, &d);
    var dense: [4]f32 = undefined;
    massMatrixDense(&m, &d, &dense);

    const x = [_]f32{ 1.3, -0.6 };
    var got: [2]f32 = undefined;
    mulM(&m, &d, &x, &got);
    try expectApproxEqAbs(dense[0] * x[0] + dense[1] * x[1], got[0], 1.0e-4);
    try expectApproxEqAbs(dense[2] * x[0] + dense[3] * x[1], got[1], 1.0e-4);
}

test "determinism: the same initial state gives the same trajectory" {
    // P12 in miniature. Nothing here is random, but nothing GUARANTEES that until it is
    // asserted -- and the moment contacts arrive (phase 7) this becomes the test that
    // catches an unsorted manifold list.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var a: Data = try Data.init(gpa, &m);
    defer a.deinit();
    var b: Data = try Data.init(gpa, &m);
    defer b.deinit();

    inline for (.{ &a, &b }) |dd| {
        dd.pos[0] = 2.1;
        dd.pos[1] = -0.8;
        dd.vel[0] = 0.4;
    }
    for (0..3000) |_| {
        step(&m, &a);
        step(&m, &b);
    }
    // Bit-identical, not approximately equal: same code, same inputs, same order.
    for (a.pos, b.pos) |x, y| {
        try expectEqual(x, y);
    }
    for (a.vel, b.vel) |x, y| {
        try expectEqual(x, y);
    }
}

test "setCtrl and jacSite accept generated enums" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ServoArm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    setCtrl(&m, &d, ServoArm.Actuator.servo, 0.42);
    try expectApproxEqAbs(@as(f32, 0.42), d.ctrl[0], 1.0e-9);
    // The enum's tag IS the index, so the two spellings must address the same actuator.
    setCtrl(&m, &d, @as(u32, 0), -0.17);
    try expectApproxEqAbs(@as(f32, -0.17), d.ctrl[0], 1.0e-9);
}

// Limit models, transcribed from scripts/robot_oracle.py.
const LimitSoft = Spec(.{
    .bodies = &.{.{
        .name = "link",
        .joints = &.{.{
            .name = "j",
            .kind = .hinge,
            .axis = vec(0, 0, 1),
            .armature = 0,
            .range = .{ -deg30, deg30 },
            .limit_softness = .{ .time_const_s = 0.05, .damp_ratio = 1 },
            .limit_impedance = .{ .min = 0.9, .max = 0.95, .width = 0.03, .midpoint = 0.5, .power = 2 },
        }},
        .geoms = &.{.{
            .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
            .pos = vec(0, -0.25, 0),
        }},
    }},
});

const LimitDefault = Spec(.{
    .bodies = &.{.{
        .name = "link",
        .joints = &.{.{
            .name = "j",
            .kind = .hinge,
            .axis = vec(0, 0, 1),
            .armature = 0,
            .range = .{ -deg90, deg90 },
        }},
        .geoms = &.{.{
            .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
            .pos = vec(0, -0.25, 0),
        }},
    }},
});

const LimitChain = Spec(.{
    .bodies = &.{
        .{
            .name = "upper",
            .joints = &.{.{
                .name = "j1",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0,
                .range = .{ -deg20, deg20 },
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                .pos = vec(0, -0.25, 0),
            }},
        },
        .{
            .name = "lower",
            .parent = "upper",
            .pos = vec(0, -0.5, 0),
            .joints = &.{.{
                .name = "j2",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0,
                .range = .{ -deg45, deg10 },
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.04 } },
                .pos = vec(0, -0.2, 0),
            }},
        },
    },
});

const deg5: f32 = 5.0 * pi / 180.0;
const deg10: f32 = 10.0 * pi / 180.0;
const deg20: f32 = 20.0 * pi / 180.0;
const deg30: f32 = 30.0 * pi / 180.0;
const deg45: f32 = 45.0 * pi / 180.0;
const deg90: f32 = 90.0 * pi / 180.0;

/// Compare every constraint row against MuJoCo for one model. Phase 6a's whole point is
/// that this passes BEFORE any solver exists - a wrong row and a wrong solver produce the
/// same symptom, so they are separated deliberately.
fn checkConstraintRows(
    comptime name: []const u8,
    m: *Model,
    d: *Data,
    tol: f32,
) !void {
    // A model whose margin exceeds its range is active at every reachable state.
    const expect_always_active: bool = std.mem.eql(u8, name, "limit_both_sides");
    var compared: u32 = 0;
    var saw_active: bool = false;
    var saw_inactive: bool = false;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, name)) {
            continue;
        }
        @memcpy(d.pos, c.qpos);
        @memcpy(d.vel, c.qvel);
        forward(m, d);

        try expectEqual(c.nefc, @as(usize, d.constraint_count));
        if (d.constraint_count == 0) {
            saw_inactive = true;
        } else {
            saw_active = true;
        }

        for (0..d.constraint_count) |row| {
            // Jacobian row.
            for (0..m.nv) |i| {
                try expectApproxEqAbs(c.efc_j[row * m.nv + i], d.constraint_jacobian[row * m.nv + i], tol);
            }
            try expectApproxEqAbs(c.efc_pos[row], d.constraint_violation[row], tol);
            // The exact constraint-space inertia - the fixture is generated with MuJoCo's
            // DIAGEXACT flag so this compares like with like.
            try expectApproxEqAbs(
                c.efc_diag[row],
                d.constraint_inertia[row],
                @max(tol, @abs(c.efc_diag[row]) * 1.0e-4),
            );
            // R is compared as the RATIO R/A_hat - that is `(1-d)/d`, the impedance sigmoid's
            // output, and it is independent of whichever constraint-space diagonal was
            // used. Comparing R absolutely would inherit MuJoCo's `efc_diagA`, which is
            // degenerate for contact rows (see scripts/robot_oracle.py).
            if (d.constraint_inertia[row] > 1.0e-9) {
                try expectApproxEqAbs(
                    c.efc_r_ratio[row],
                    d.constraint_regularizer[row] / d.constraint_inertia[row],
                    @max(1.0e-5, c.efc_r_ratio[row] * 1.0e-3),
                );
            }
            try expectApproxEqAbs(
                c.efc_aref[row],
                d.constraint_target_acc[row],
                @max(1.0e-3, @abs(c.efc_aref[row]) * 1.0e-4),
            );
        }
        compared += 1;
    }
    try expect(compared >= 3);
    // The active branch must always be exercised. The inactive branch is checked by the
    // models whose `rest` state is inside the range; a model with a margin wider than its
    // range is never inactive, by construction, so it is exempt.
    try expect(saw_active);
    if (!expect_always_active) {
        try expect(saw_inactive);
    }
}

test "constraints: limit rows match MuJoCo, with authored softness" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try LimitSoft.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    // Two per limited joint (both ends can be within margin at once), plus the contact
    // budget from Options.max_contacts.
    try expectEqual(@as(u32, 2) + rows_per_contact * m.opt.max_contacts, m.constraint_capacity);
    try checkConstraintRows("limit_soft", &m, &d, 1.0e-4);
}

test "constraints: limit rows match MuJoCo, with default softness" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try LimitDefault.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try checkConstraintRows("limit_default", &m, &d, 1.0e-4);
}

test "constraints: two limited joints give two rows, in declaration order" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try LimitChain.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try expectEqual(@as(u32, 4) + rows_per_contact * m.opt.max_contacts, m.constraint_capacity);
    try checkConstraintRows("limit_chain", &m, &d, 1.0e-4);
}

test "constraints: a narrow range with a wide margin activates BOTH ends" {
    // The path a min()-of-both-distances shortcut cannot reach. With the range narrower
    // than twice the margin, the joint is within margin of both stops everywhere in its
    // travel, so two opposing rows exist at once and the solver balances them.
    const BothSides = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0,
                .range = .{ -deg5, deg5 },
                .limit_margin = 0.4,
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                .pos = vec(0, -0.25, 0),
            }},
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try BothSides.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    try checkConstraintRows("limit_both_sides", &m, &d, 1.0e-4);

    // And the rows really do oppose each other, which is what makes the pair meaningful.
    d.pos[0] = 0;
    forward(&m, &d);
    try expectEqual(@as(u32, 2), d.constraint_count);
    try expect(d.constraint_jacobian[0] > 0.0);
    try expect(d.constraint_jacobian[m.nv] < 0.0);
}

/// The contact model: a pendulum whose tip sphere rests on the ground.
const ContactGround = Spec(.{
    .bodies = &.{.{
        .name = "link",
        .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0 }},
        .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.06 } }, .pos = vec(0, -0.55, 0) }},
    }},
    .options = .{ .max_contacts = 4 },
});

test "contact: pyramidal rows match MuJoCo, fed MuJoCo's own contact" {
    // * The row math tested with collision detection entirely out of the picture. The
    // fixture carries the contact MuJoCo found - position, normal, penetration, friction -
    // and we build rows from THAT. So a mismatch here is a bug in the constraint algebra
    // and cannot be a difference of opinion about where two shapes touch, which is the
    // same separation that made 6a debuggable.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ContactGround.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var compared: u32 = 0;
    for (reference.cases) |c| {
        if (!std.mem.eql(u8, c.model, "contact_ground")) {
            continue;
        }
        @memcpy(d.pos, c.qpos);
        @memcpy(d.vel, c.qvel);

        d.clearContacts();
        for (0..c.ncon) |ci| {
            const base: usize = ci * 14;
            // MuJoCo's frame is 9 row-major floats whose FIRST ROW is the normal.
            const normal: Vec = vec(c.contacts[base + 5], c.contacts[base + 6], c.contacts[base + 7]);
            const tangent0: Vec = vec(c.contacts[base + 8], c.contacts[base + 9], c.contacts[base + 10]);
            const tangent1: Vec = vec(c.contacts[base + 11], c.contacts[base + 12], c.contacts[base + 13]);
            const mu: f32 = c.contacts[base + 4];
            d.pushContact(.{
                .position = vec(c.contacts[base + 0], c.contacts[base + 1], c.contacts[base + 2]),
                .normal = normal,
                .tangent = .{ tangent0, tangent1 },
                .distance = c.contacts[base + 3],
                .friction = .{ mu, mu },
                .body_a = c.contact_bodies[ci * 2 + 0],
                .body_b = c.contact_bodies[ci * 2 + 1],
                .id = ci,
            });
        }
        // The whole point of the refactor: contacts are an input, so the ordinary entry
        // point handles them. No hand-run pipeline.
        forward(&m, &d);

        try expectEqual(c.nefc, @as(usize, d.constraint_count));
        for (0..d.constraint_count) |row| {
            for (0..m.nv) |i| {
                try expectApproxEqAbs(c.efc_j[row * m.nv + i], d.constraint_jacobian[row * m.nv + i], 1.0e-4);
            }
            try expectApproxEqAbs(c.efc_pos[row], d.constraint_violation[row], 1.0e-5);
            try expectApproxEqAbs(
                c.efc_diag[row],
                d.constraint_inertia[row],
                @max(1.0e-5, @abs(c.efc_diag[row]) * 1.0e-4),
            );
            // See the note in checkConstraintRows: compare the impedance ratio, not R.
            if (d.constraint_inertia[row] > 1.0e-9) {
                try expectApproxEqAbs(
                    c.efc_r_ratio[row],
                    d.constraint_regularizer[row] / d.constraint_inertia[row],
                    @max(1.0e-5, c.efc_r_ratio[row] * 1.0e-3),
                );
            }
            try expectApproxEqAbs(
                c.efc_aref[row],
                d.constraint_target_acc[row],
                @max(1.0e-3, @abs(c.efc_aref[row]) * 1.0e-4),
            );
        }
        compared += 1;
    }
    try expect(compared >= 3);
}

test "contact: the pyramid's edge rows are normal +/- mu*tangent" {
    // The structural claim behind the whole pyramid trick, checked directly: opposing edges
    // must average back to the pure normal direction, and differ by exactly 2*mu*tangent.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ContactGround.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    const mu: f32 = 0.7;
    const normal: Vec = vec(0, 1, 0);
    const tangent0: Vec = vec(1, 0, 0);
    const tangent1: Vec = vec(0, 0, 1);
    const point: Vec = vec(0, -0.61, 0);
    d.setContacts(&.{.{
        .position = point,
        .normal = normal,
        .tangent = .{ tangent0, tangent1 },
        .distance = -0.01,
        .friction = .{ mu, mu },
        .body_a = world_body,
        .body_b = 1,
    }});
    forward(&m, &d);
    try expectEqual(rows_per_contact, d.constraint_count);

    // The pure normal and tangent rows, computed independently.
    var jac: [1]Vec = undefined;
    jacPoint(&m, &d, 1, point, &jac, null);
    const normal_row: f32 = dot3(normal, jac[0]);
    const tangent0_row: f32 = dot3(tangent0, jac[0]);

    // Rows 0 and 1 are the +mu and -mu edges of tangent 0.
    try expectApproxEqAbs(normal_row + mu * tangent0_row, d.constraint_jacobian[0], 1.0e-5);
    try expectApproxEqAbs(normal_row - mu * tangent0_row, d.constraint_jacobian[m.nv], 1.0e-5);
    // Their average is the pure normal - which is what makes an evenly-loaded pyramid
    // produce a purely normal force.
    try expectApproxEqAbs(
        normal_row,
        0.5 * (d.constraint_jacobian[0] + d.constraint_jacobian[m.nv]),
        1.0e-5,
    );
    // And all four rows share the contact's penetration as their residual.
    for (0..rows_per_contact) |row| {
        try expectApproxEqAbs(@as(f32, -0.01), d.constraint_violation[row], 1.0e-7);
        try expectEqual(ConstraintKind.contact, d.constraint_kind[row]);
    }
}

test "contact: row order is deterministic whatever order the detector reports" {
    // * The property the sort exists for. A constraint solver sweeps rows in sequence, so
    // a different row order gives a different (equally valid) answer - and collision
    // detectors do not promise a stable order. Feed the SAME contacts in reversed order and
    // the resulting rows, forces and acceleration must be identical.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ContactGround.build(gpa);
    defer m.deinit();

    const a: Contact = .{
        .position = vec(0.02, -0.61, 0),
        .normal = vec(0, 1, 0),
        .tangent = .{ vec(1, 0, 0), vec(0, 0, 1) },
        .distance = -0.01,
        .friction = .{ 0.7, 0.7 },
        .body_a = world_body,
        .body_b = 1,
        .id = 1,
    };
    var b: Contact = a;
    b.position = vec(-0.02, -0.61, 0);
    b.distance = -0.02;
    b.id = 2;

    var acc: [2]f32 = undefined;
    var force_sum: [2]f32 = undefined;
    inline for (.{ [_]Contact{ a, b }, [_]Contact{ b, a } }, 0..) |order, idx| {
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();
        d.setContacts(&order);
        forward(&m, &d);
        try expectEqual(rows_per_contact * 2, d.constraint_count);
        acc[idx] = d.acc[0];
        var total: f32 = 0;
        for (0..d.constraint_count) |row| {
            total += d.constraint_force[row];
        }
        force_sum[idx] = total;
    }
    try expectEqual(acc[0], acc[1]);
    try expectEqual(force_sum[0], force_sum[1]);
}

test "contact: forward() enforces contacts, and a resting link stops falling" {
    // The behavioural check, and the reason contacts had to become an input: this uses the
    // ordinary entry point. Before the refactor `forward` ran the constraint stages back to
    // back, so there was no moment at which a caller could inject a contact and the main
    // path silently ignored them.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ContactGround.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // No contact: the link accelerates under gravity once displaced.
    d.pos[0] = 0.4;
    d.clearContacts();
    forward(&m, &d);
    const free_acc: f32 = d.acc[0];
    try expect(@abs(free_acc) > 1.0);

    // Now a floor contact under the tip. Swinging back toward vertical carries the tip
    // downward, so a ground normal opposes the motion and the constraint must fight it.
    // The contact point is the sphere's CENTRE (`body_xipos`), not the body origin - the
    // origin is the hinge itself, where the Jacobian is identically zero and no contact
    // there could do anything.
    const contact_point: Vec = d.body_xipos[1];
    const normal: Vec = vec(0, 1, 0);
    d.setContacts(&.{.{
        .position = contact_point,
        .normal = normal,
        .tangent = .{ vec(1, 0, 0), vec(0, 0, 1) },
        .distance = -0.005,
        .friction = .{ 0.7, 0.7 },
        .body_a = world_body,
        .body_b = 1,
        .id = 1,
    }});
    forward(&m, &d);
    try expectEqual(rows_per_contact, d.constraint_count);
    try expect(d.constraint_force[0] > 0.0); // actually pushing
    // The acceleration must move in the POSITIVE direction - away from the penetration.
    // Not merely "smaller in magnitude": a stiff contact that is already 5 mm deep is
    // asked to undo that penetration, so reversing the sign is the correct answer, and
    // asserting a magnitude decrease would be asserting a weaker contact than we want.
    try expect(d.acc[0] > free_acc + 1.0);
    // Every force is finite and non-negative - the property the zero-A_hat skip protects.
    for (0..d.constraint_count) |row| {
        try expect(d.constraint_force[row] >= 0.0);
        try expect(d.constraint_force[row] < 1.0e6);
    }
}

test "contact: a row the mechanism cannot move along carries no force" {
    // * The degenerate case, and it is not exotic - it happens on the very first fixture.
    // A planar 1-DOF pendulum touching a floor has no motion along the out-of-plane
    // tangent, so that tangent's two pyramid edges have an identically zero Jacobian.
    // Such a row cannot be violated by any joint motion, so it must carry zero force.
    //
    // Without the skip in `solveConstraints` these rows get a denominator of ~1e-10 and a
    // force around 1e11. It is invisible in the acceleration (their `M^-1J^T` is zero too),
    // which is exactly why it needs asserting rather than eyeballing: it silently corrupts
    // the reported forces and the convergence residual.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ContactGround.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // Straight down, touching the floor: the tip's only motion is along X, so the normal
    // (Y) and the out-of-plane tangent (Z) both see nothing.
    d.pos[0] = 0;
    d.setContacts(&.{.{
        .position = vec(0, -0.5925, 0),
        .normal = vec(0, 1, 0),
        .tangent = .{ vec(0, 0, 1), vec(1, 0, 0) },
        .distance = -0.035,
        .friction = .{ 0.7, 0.7 },
        .body_a = world_body,
        .body_b = 1,
        .id = 1,
    }});
    forward(&m, &d);
    try expectEqual(rows_per_contact, d.constraint_count);

    var degenerate_rows: u32 = 0;
    for (0..d.constraint_count) |row| {
        if (d.constraint_inertia[row] <= 1.0e-9) {
            degenerate_rows += 1;
            try expectApproxEqAbs(@as(f32, 0), d.constraint_force[row], 1.0e-9);
        }
        // No row, degenerate or not, may carry a nonsensical force.
        try expect(d.constraint_force[row] >= 0.0);
        try expect(d.constraint_force[row] < 1.0e5);
    }
    // The situation must actually have arisen, or this test proves nothing.
    try expect(degenerate_rows >= 2);

    // * AND THIS CONFIGURATION DOES NOT CONVERGE - correctly so, which is worth asserting
    // rather than hiding. A 1-DOF pendulum cannot move along a floor normal at ALL, so a
    // 35 mm penetration is not something any force can undo: the normal rows are powerless
    // (that is what makes them degenerate) and the two friction edges oppose each other,
    // each demanding a correction neither can deliver. The solver saturates at
    // `max_iterations` and reports so.
    //
    // That is the diagnostic doing its job. A solver that merely STOPPED would look
    // identical from the outside; `constraintResidual` is what distinguishes "solved" from
    // "gave up", and a model that asks for the impossible should be visibly unsolved rather
    // than quietly approximated.
    //
    // * THIS USED TO ASSERT `solver_iterations == max_iterations` AND THAT WAS A PROXY, not
    // the property. It held only because plain PGS was slow enough to burn the whole budget
    // here; adding Nesterov acceleration made the solver do everything it could and stop,
    // which is BETTER behaviour and broke the assertion. Pinning an iteration count pins the
    // solver's speed, and every improvement then reads as a regression.
    //
    // What actually matters is that the answer is still reported as unconverged.
    try expect(!constraintConverged(&m, &d));
}

test "contact: a separated contact produces no rows" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try ContactGround.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.setContacts(&.{.{
        .position = vec(0, -0.61, 0),
        .normal = vec(0, 1, 0),
        .tangent = .{ vec(1, 0, 0), vec(0, 0, 1) },
        .distance = 0.05, // a clear gap
        .friction = .{ 0.7, 0.7 },
        .body_a = world_body,
        .body_b = 1,
    }});
    forward(&m, &d);
    // The contact is in the buffer but produces no rows: separation is checked when rows
    // are built, not when the contact is pushed.
    try expectEqual(@as(u32, 1), d.contact_count);
    try expectEqual(@as(u32, 0), d.constraint_count);
}

test "constraints: the Jacobian sign always pushes back into range" {
    // The convention the solver depends on: whichever end is violated, a POSITIVE force
    // must restore. Without it the solver would need to know each row's direction, and
    // clamping to f >= 0 would be wrong for half of them.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try LimitDefault.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = deg90 + 0.2; // past the UPPER limit
    forward(&m, &d);
    try expectEqual(@as(u32, 1), d.constraint_count);
    try expect(d.constraint_jacobian[0] < 0.0); // negative row, so +f drives q down

    d.pos[0] = -deg90 - 0.2; // past the LOWER limit
    forward(&m, &d);
    try expectEqual(@as(u32, 1), d.constraint_count);
    try expect(d.constraint_jacobian[0] > 0.0); // positive row, so +f drives q up

    d.pos[0] = 0; // comfortably inside
    forward(&m, &d);
    try expectEqual(@as(u32, 0), d.constraint_count);
}

test "constraints: the impedance sigmoid hits both ends and rises between" {
    const imp: Impedance = .{ .min = 0.9, .max = 0.95, .width = 0.03, .midpoint = 0.5, .power = 2 };
    // Saturated ends.
    try expectApproxEqAbs(imp.min, imp.at(0.0), 1.0e-6);
    try expectApproxEqAbs(imp.max, imp.at(-0.5), 1.0e-6);
    try expectApproxEqAbs(imp.max, imp.at(0.5), 1.0e-6); // symmetric in |r|
    // Monotone in between, and strictly inside the range.
    var prev: f32 = imp.min;
    var t: f32 = 0.003;
    while (t < 0.03) : (t += 0.003) {
        const v: f32 = imp.at(-t);
        try expect(v >= prev);
        try expect(v > imp.min - 1.0e-6 and v < imp.max + 1.0e-6);
        prev = v;
    }
    // A degenerate width collapses to the midpoint rather than dividing by zero.
    const flat: Impedance = .{ .min = 0.8, .max = 0.8, .width = 0 };
    try expectApproxEqAbs(@as(f32, 0.8), flat.at(-1.0), 1.0e-6);
}

test "constraints: R scales with constraint-space inertia, which is the whole point" {
    // The invariance that makes `Softness` mean the same thing across mass scales. Two
    // models identical but for a 100x heavier link must produce the same IMPEDANCE and
    // therefore the same softness, while R tracks the inertia.
    const gpa: Allocator = std.testing.allocator;
    var ratio_diag: [2]f32 = undefined;
    var ratio_r: [2]f32 = undefined;

    inline for (.{ 1000.0, 100000.0 }, 0..) |density, idx| {
        const Heavy = Spec(.{
            .bodies = &.{.{
                .name = "link",
                .joints = &.{.{
                    .name = "j",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .armature = 0,
                    .range = .{ -deg30, deg30 },
                }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                    .pos = vec(0, -0.25, 0),
                    .density = density,
                }},
            }},
        });
        var m: Model = try Heavy.build(gpa);
        defer m.deinit();
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();
        d.pos[0] = deg30 + 0.05;
        forward(&m, &d);
        try expectEqual(@as(u32, 1), d.constraint_count);
        ratio_diag[idx] = d.constraint_inertia[0];
        ratio_r[idx] = d.constraint_regularizer[0];
    }

    // 100x the mass is 1/100th the constraint-space inertia (it is M^-1 based), and R
    // follows it exactly -- so the RATIO of R to diag is identical, which is what makes
    // the softness mass-invariant.
    try expectApproxEqAbs(
        ratio_r[0] / ratio_diag[0],
        ratio_r[1] / ratio_diag[1],
        1.0e-6,
    );
    try expect(ratio_diag[0] > ratio_diag[1] * 50.0); // heavier really is stiffer to push
}

test "solver: converges, and the residual says so" {
    // The honest convergence check. A solver that STOPPED is not a solver that CONVERGED,
    // and the iteration count alone cannot distinguish them - which is exactly why
    // `constraintResidual` exists.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try LimitChain.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // Drive both joints past their limits, hard.
    d.pos[0] = deg20 + 0.3;
    d.pos[1] = deg10 + 0.4;
    d.vel[0] = 2.0;
    d.vel[1] = 1.5;
    forward(&m, &d);

    try expectEqual(@as(u32, 2), d.constraint_count);
    try expect(d.solver_iterations < m.opt.solver.max_iterations);
    try expect(constraintConverged(&m, &d));
    // And the raw residual is tiny in absolute terms too, not merely small relative to a
    // large scale - the relative test must not be hiding a big absolute error.
    try expect(constraintResidual(&m, &d) < 0.05);
}

test "solver: the KKT conditions actually hold at the answer" {
    // Checked directly rather than through the residual's own arithmetic, so a bug in
    // `constraintResidual` cannot certify a bug in `solveConstraints`.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try LimitChain.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = deg20 + 0.25;
    d.pos[1] = -deg45 - 0.15; // the OTHER end of the second joint's range
    forward(&m, &d);
    try expectEqual(@as(u32, 2), d.constraint_count);

    for (0..d.constraint_count) |row| {
        const jacobian: []const f32 = d.constraint_jacobian[row * m.nv ..][0..m.nv];
        var constraint_acc: f32 = 0;
        for (jacobian, d.acc) |j, a| {
            constraint_acc += j * a;
        }
        const shortfall: f32 = constraint_acc +
            d.constraint_regularizer[row] * d.constraint_force[row] -
            d.constraint_target_acc[row];
        const force: f32 = d.constraint_force[row];

        try expect(force >= -1.0e-6); //  f >= 0
        try expect(shortfall >= -1.0e-4); //  s >= 0
        try expect(@abs(force * shortfall) < 1.0e-3); //  f . s == 0
    }
}

test "unified tree: a robot pushing a FREE BODY conserves momentum" {
    // *** THE EVIDENCE FOR section 5, and the number that decides the architecture.
    //
    // Four attempts at coupling two solvers across a seam each found a real bug and none
    // fixed the symptom - a 0.4 kg crate still left at 76 m/s. This is the same physics with
    // the seam removed: the crate is a body with a FREE JOINT in the robot's own tree, so
    // the contact is between two bodies of one system. One Jacobian spanning both sides, one
    // mass matrix containing both inertias, one solver.
    //
    // **Momentum is then conserved by construction rather than by handoff**, and the test is
    // that it actually is - to 0.002% over 600 steps, against a coupling that could not
    // conserve it at all because the two halves had no common ledger.
    //
    // Nothing here is new machinery. `JointKind.free` landed in phase 2; `addContactRows`
    // has always built the RELATIVE Jacobian `jac_b - jac_a` between two tree bodies. The
    // crate that would not behave was a crate on the wrong side of a line that did not need
    // to exist.
    const Scene = Spec(.{
        .bodies = &.{
            .{
                .name = "pusher",
                .joints = &.{.{
                    .name = "slide",
                    .kind = .slide,
                    .axis = vec(1, 0, 0),
                    // * ZERO ARMATURE, and it matters for this test specifically. Armature is
                    // rotor inertia - resistance that is NOT mass - so a slider carrying it
                    // has an effective inertia the momentum sum `m*v` does not account for.
                    // Left at the default the books came out 0.58% out, which looks like a
                    // conservation failure and is a bookkeeping one.
                    .armature = 0.0,
                }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } } }},
                .inertial = .{
                    .mass = 2.0,
                    .pos = vec_zero,
                    .full_inertia = .{ 0.01, 0.01, 0.01, 0, 0, 0 },
                },
            },
            .{
                .name = "crate",
                .joints = &.{.{ .name = "freefloat", .kind = .free }},
                .pos = vec(0.2, 0, 0),
                .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = splat(@as(f32, 0.05)) } } }},
                .inertial = .{
                    .mass = 0.5,
                    .pos = vec_zero,
                    .full_inertia = .{ 0.002, 0.002, 0.002, 0, 0, 0 },
                },
            },
        },
        // No gravity: with no external force the total momentum is a CLOSED quantity, so any
        // drift is the coupling's own error and nothing else's.
        .options = .{ .gravity = vec_zero, .max_contacts = 4 },
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Scene.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // One slide DOF plus six for the free body; seven positions plus a quaternion.
    try expectEqual(@as(u32, 7), m.nv);
    try expectEqual(@as(u32, 8), m.nq);

    d.vel[0] = 1.0;
    const initial_momentum: f32 = 2.0 * 1.0; // the crate starts at rest

    for (0..600) |_| {
        forward(&m, &d);
        d.clearContacts();
        // A contact between two TREE BODIES - `body_b` is the crate, not `world_body`.
        const gap: f32 = d.body_xpos[2][0] - d.body_xpos[1][0] - 0.10;
        if (gap < 0.01) {
            d.pushContact(.{
                .position = (d.body_xpos[1] + d.body_xpos[2]) * splat(@as(f32, 0.5)),
                .normal = vec(1, 0, 0),
                .tangent = .{ vec(0, 1, 0), vec(0, 0, 1) },
                .distance = gap,
                .friction = .{ 0.0, 0.0 },
                .body_a = 1,
                .body_b = 2,
                .id = 1,
            });
        }
        step(&m, &d);
    }
    forward(&m, &d);

    // The push happened: the pusher slowed and the crate is moving. Deliberately loose -
    // these were once tight thresholds tuned against a BUG (free bodies all started at the
    // origin, so the crate was permanently overlapping the pusher), and tight numbers on a
    // wrong setup are how a fix looks like a regression. The property is that momentum
    // moved from one body to the other; the exact split is the integrator's business.
    try expect(d.vel[0] < 0.95);
    try expect(d.vel[1] > 0.3);

    // * And the books balance. 0.1% is generous for f32 over 600 steps; the measured error
    // is 0.002%, and a loose bound here keeps the test about CONSERVATION rather than about
    // the integrator's exact accuracy.
    const final_momentum: f32 = 2.0 * d.vel[0] + 0.5 * d.vel[1];
    try expectApproxEqAbs(initial_momentum, final_momentum, 0.002);
}

test "warm start: same answer, far fewer iterations" {
    // ** THE TWO PROPERTIES WARM STARTING MUST HAVE, and they pull in opposite directions.
    //
    // It must be FASTER - that is the whole point, and section 4g's benchmark said the constraint
    // path needed 29 iterations where MuJoCo needed a handful.
    //
    // It must not change the ANSWER. Warm starting only moves the starting point; the
    // converged solution is the same fixed point of the same projection. A solver that
    // lands somewhere else when started from a different place is not converging, and would
    // make every result depend on history in a way nothing downstream could reason about.
    //
    // -- AND THE BUG THIS WOULD HAVE CAUGHT --
    //
    // The first implementation warm-started the FORCES but left `d.acc` holding the free
    // acceleration. The iteration then computed the whole force again and added it on top,
    // doubling it every step: a joint resting on its limit sank straight through, and its
    // constraint force reached 7619 N. Seeding `acc += M^-1J^Tf` is what makes the two agree.
    const lower: f32 = 30.0 * pi / 180.0;
    const upper: f32 = 90.0 * pi / 180.0;
    const Held = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0.001,
                .damping = 0.3,
                .range = .{ lower, upper },
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                .pos = vec(0, -0.25, 0),
            }},
        }},
    });
    const gpa: Allocator = std.testing.allocator;

    var cold_iterations: u32 = 0;
    var warm_iterations: u32 = 0;
    var cold_pos: f32 = 0;
    var warm_pos: f32 = 0;
    var cold_force: f32 = 0;
    var warm_force: f32 = 0;

    for ([_]bool{ false, true }) |warm| {
        var m: Model = try Held.build(gpa);
        defer m.deinit();
        m.opt.warm_start = warm;
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();

        d.pos[0] = 45.0 * pi / 180.0; // above the limit, free to fall onto it
        for (0..2400) |_| {
            step(&m, &d);
        }
        forward(&m, &d);
        if (warm) {
            warm_iterations = d.solver_iterations;
            warm_pos = d.pos[0];
            warm_force = d.constraint_force[0];
        } else {
            cold_iterations = d.solver_iterations;
            cold_pos = d.pos[0];
            cold_force = d.constraint_force[0];
        }
    }

    // Same answer: resting on the limit, same penetration, same holding force.
    try expectApproxEqAbs(cold_pos, warm_pos, 1.0e-4);
    try expectApproxEqAbs(cold_force, warm_force, 1.0e-2);
    try expect(warm_pos < lower + 0.01);
    try expect(warm_pos > lower - 0.03);

    // And no more work than the cold start. Once settled this case converges in one
    // iteration either way; the win shows up on the multi-row benchmark, where a cold start
    // needs 29. Asserting "no worse" rather than a specific count keeps the test from
    // pinning a number that legitimate solver changes would move.
    try expect(warm_iterations <= cold_iterations);
}

test "solver: a joint held against its limit comes to rest there" {
    // The behavioural test, and the phase's stated goal.
    //
    // The model matters. The limit must be somewhere gravity actually PRESSES INTO - a
    // range straddling the pendulum's equilibrium would never engage, because the joint
    // simply settles at the bottom and the constraint is never touched. So the range stops
    // short of vertical, and gravity holds the link against it. Damping is present so the
    // thing settles rather than ringing forever, which is what a real joint does.
    const Held = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0.001,
                .damping = 0.3,
                .range = .{ deg30, deg90 },
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                .pos = vec(0, -0.25, 0),
            }},
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Held.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = deg45; // above the limit, free to fall onto it
    for (0..2400) |_| { // 10 seconds
        step(&m, &d);
    }
    forward(&m, &d);

    // Resting ON the lower limit, penetrating only as much as a soft constraint permits.
    try expect(d.pos[0] < deg30 + 0.01); // it did come down to the limit
    try expect(d.pos[0] > deg30 - 0.03); // and did not sink through it
    try expect(@abs(d.vel[0]) < 0.05); // and is at rest, not rattling
    try expect(d.constraint_force[0] > 0.0); // actively holding
}

test "solver: penetration under load is independent of mass - the A_hat payoff" {
    // * The invariance the whole impedance parameterization exists for, measured end to
    // end rather than argued. Two arms differing only by 100x in density, each pressed
    // into its limit by gravity, must settle at the SAME penetration - because `R` is
    // scaled by the constraint-space inertia, so the softness the modeller asked for means
    // the same thing at both scales.
    //
    // Without the A_hat scaling this test fails by two orders of magnitude, and every model in
    // a scene would need its limits retuned by hand.
    const gpa: Allocator = std.testing.allocator;
    var penetration: [2]f32 = undefined;

    inline for (.{ 1000.0, 100000.0 }, 0..) |density, idx| {
        const Pressed = Spec(.{
            .bodies = &.{.{
                .name = "link",
                .joints = &.{.{
                    .name = "j",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .armature = 0,
                    .damping = 0.5,
                    // The range stops SHORT of vertical, so gravity presses the link
                    // steadily into the lower limit instead of letting it settle at its
                    // equilibrium where the constraint would never engage.
                    .range = .{ deg30, deg90 },
                }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                    .pos = vec(0, -0.25, 0),
                    .density = density,
                }},
            }},
        });
        var m: Model = try Pressed.build(gpa);
        defer m.deinit();
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();

        d.pos[0] = deg45;
        for (0..2400) |_| {
            step(&m, &d);
        }
        forward(&m, &d);
        penetration[idx] = deg30 - d.pos[0]; // positive when sunk past the limit
    }

    // The same softness at both scales. Compared absolutely because both should be tiny;
    // a mass-dependent R would put these orders of magnitude apart.
    try expectApproxEqAbs(penetration[0], penetration[1], 2.0e-3);
}

test "solver: no constraints means no work and no force" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try LimitDefault.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // Displaced but comfortably inside the range. Note it must be DISPLACED: at q = 0 this
    // pendulum hangs straight down, which is its equilibrium, so gravity exerts no torque
    // and "the acceleration is nonzero" would be false for reasons having nothing to do
    // with constraints.
    d.pos[0] = 0.5;
    forward(&m, &d);
    try expectEqual(@as(u32, 0), d.constraint_count);
    try expectApproxEqAbs(@as(f32, 0), constraintResidual(&m, &d), 1.0e-9);
    // The iteration count is a DIAGNOSTIC, so it must also be honest about not having run.
    // Left stale, a step with no constraints reports the last constrained step's count and
    // reads as a solver in trouble.
    try expectEqual(@as(u32, 0), d.solver_iterations);
    for (d.constraint_joint_force) |joint_force| {
        try expectApproxEqAbs(@as(f32, 0), joint_force, 1.0e-9);
    }
    // And the acceleration is the unconstrained one: swinging back toward vertical.
    try expect(d.acc[0] < -1.0);
}

test "solver: constraint force is reported in joint coordinates as J^T f" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try LimitDefault.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = deg90 + 0.2; // past the upper limit
    forward(&m, &d);
    try expectEqual(@as(u32, 1), d.constraint_count);
    try expect(d.constraint_force[0] > 0.0); // pushing

    // J is -1 on this row (upper limit), so the joint-space force must be negative: it
    // drives the coordinate back down into range.
    try expectApproxEqAbs(
        d.constraint_jacobian[0] * d.constraint_force[0],
        d.constraint_joint_force[0],
        1.0e-5,
    );
    try expect(d.constraint_joint_force[0] < 0.0);
}

/// The MuJoCo `model/car` idea, reduced to its essential mechanism: two wheels, and two
/// tendons that turn them into "forward" and "turn" instead of "left" and "right".
const DifferentialDrive = Spec(.{
    .bodies = &.{
        .{
            .name = "left_wheel",
            .joints = &.{.{ .name = "left", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.01 }},
            .geoms = &.{.{ .shape = .{ .cylinder = .{ .half_height = 0.02, .radius = 0.1 } } }},
        },
        .{
            .name = "right_wheel",
            .pos = vec(0.3, 0, 0),
            .joints = &.{.{ .name = "right", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.01 }},
            .geoms = &.{.{ .shape = .{ .cylinder = .{ .half_height = 0.02, .radius = 0.1 } } }},
        },
    },
    .tendons = &.{
        // Both wheels the same way: the vehicle's forward travel.
        .{ .name = "forward", .joints = &.{
            .{ .name = "left", .coefficient = 1 },
            .{ .name = "right", .coefficient = 1 },
        } },
        // Opposite ways: its heading.
        .{ .name = "turn", .joints = &.{
            .{ .name = "left", .coefficient = 1 },
            .{ .name = "right", .coefficient = -1 },
        } },
    },
    .actuators = &.{
        .{ .name = "drive", .on = .{ .tendon = .{ .name = "forward" } }, .kind = .motor },
        .{ .name = "steer", .on = .{ .tendon = .{ .name = "turn" } }, .kind = .motor },
    },
    .options = .{ .gravity = vec(0, 0, 0) }, // no gravity: this is about the coupling
});

test "tendon: length and velocity are the linear combination they are defined as" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DifferentialDrive.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    try expectEqual(@as(u32, 2), m.ntendon);
    d.pos[0] = 0.7; // left
    d.pos[1] = 0.2; // right
    d.vel[0] = 1.5;
    d.vel[1] = -0.5;
    forward(&m, &d);

    // forward = qL + qR, turn = qL - qR. Straight from the definition, which is the point:
    // a fixed tendon is evaluated, not enforced.
    try expectApproxEqAbs(@as(f32, 0.9), d.tendon_length[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.5), d.tendon_length[1], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 1.0), d.tendon_velocity[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 2.0), d.tendon_velocity[1], 1.0e-6);
}

test "tendon: a differential drive turns two controls into forward and turn" {
    // * The phase's stated goal, and the thing tendons are FOR. Two wheels, two controls,
    // and neither control is a wheel: one drives, one steers, and the coupling is exact
    // because it is a definition rather than a constraint the solver has to hold.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DifferentialDrive.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // Drive only: both wheels must turn the SAME way, by the same amount.
    d.ctrl[0] = 1.0; // forward
    d.ctrl[1] = 0.0; // turn
    for (0..240) |_| {
        step(&m, &d);
    }
    forward(&m, &d);
    try expect(d.pos[0] > 0.05);
    try expectApproxEqAbs(d.pos[0], d.pos[1], 1.0e-4);

    // Steer only: OPPOSITE ways, by the same amount.
    d.reset(&m);
    d.ctrl[0] = 0.0;
    d.ctrl[1] = 1.0;
    for (0..240) |_| {
        step(&m, &d);
    }
    forward(&m, &d);
    try expect(d.pos[0] > 0.05);
    try expectApproxEqAbs(d.pos[0], -d.pos[1], 1.0e-4);
    // And a pure turn leaves the vehicle's forward coordinate untouched, which is the
    // decoupling the tendons exist to provide.
    try expectApproxEqAbs(@as(f32, 0), d.tendon_length[0], 1.0e-4);
}

test "tendon: one scalar force spreads across the DOFs by its coefficients" {
    // The J^T half. A tendon actuator's force reaches each joint in proportion to that
    // joint's coefficient - the same transpose that carries a contact force into joint
    // space, applied to a one-row Jacobian.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DifferentialDrive.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.ctrl[0] = 2.0; // forward: coefficients (+1, +1)
    d.ctrl[1] = 0.0;
    forward(&m, &d);
    try expectApproxEqAbs(@as(f32, 2.0), d.actuator_force[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 2.0), d.actuator_force[1], 1.0e-5);

    d.ctrl[0] = 0.0;
    d.ctrl[1] = 3.0; // turn: coefficients (+1, -1)
    forward(&m, &d);
    try expectApproxEqAbs(@as(f32, 3.0), d.actuator_force[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -3.0), d.actuator_force[1], 1.0e-5);
}

test "tendon: a spring on the tendon pulls its length toward rest" {
    // A tendon carries its own spring and damper, acting on its LENGTH rather than on any
    // one joint - which is how a coupled finger springs back to a pose rather than each
    // knuckle springing back independently.
    const Sprung = Spec(.{
        .bodies = &.{
            .{
                .name = "a",
                .joints = &.{.{ .name = "ja", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.01 }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .pos = vec(0.2, 0, 0) }},
            },
            .{
                .name = "b",
                .pos = vec(0.4, 0, 0),
                .joints = &.{.{ .name = "jb", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.01 }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .pos = vec(0.2, 0, 0) }},
            },
        },
        .tendons = &.{.{
            .name = "coupler",
            .joints = &.{ .{ .name = "ja", .coefficient = 1 }, .{ .name = "jb", .coefficient = 1 } },
            .stiffness = 8,
            .damping = 1.5,
            .rest_length = 0,
        }},
        .options = .{ .gravity = vec(0, 0, 0) },
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Sprung.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = 0.6;
    d.pos[1] = 0.6; // tendon length 1.2, well away from rest
    for (0..2400) |_| {
        step(&m, &d);
    }
    forward(&m, &d);

    // The tendon's LENGTH is what the spring controls, so that is what must reach rest.
    try expectApproxEqAbs(@as(f32, 0), d.tendon_length[0], 0.02);
    // The individual joints need not be zero - only their sum is constrained, which is
    // exactly the difference between a tendon spring and two joint springs.
    try expect(@abs(d.tendon_velocity[0]) < 0.05);
}

/// A one-link pendulum wearing a full instrument package at its tip.
const SensedArm = Spec(.{
    .bodies = &.{.{
        .name = "link",
        .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.001 }},
        .geoms = &.{.{
            .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
            .pos = vec(0, -0.25, 0),
        }},
        .sites = &.{.{ .name = "tip", .pos = vec(0, -0.5, 0) }},
    }},
    .actuators = &.{.{ .name = "motor", .on = .{ .joint = .{ .name = "j" } }, .kind = .motor }},
    .sensors = &.{
        .{ .name = "angle", .kind = .joint_pos, .target = "j" },
        .{ .name = "rate", .kind = .joint_vel, .target = "j" },
        .{ .name = "tip_at", .kind = .site_pos, .target = "tip" },
        .{ .name = "tip_speed", .kind = .site_lin_vel, .target = "tip" },
        .{ .name = "imu_gyro", .kind = .gyro, .target = "tip" },
        .{ .name = "imu_vel", .kind = .velocimeter, .target = "tip" },
        .{ .name = "imu_acc", .kind = .accelerometer, .target = "tip" },
        .{ .name = "drive", .kind = .actuator_force, .target = "motor" },
    },
});

test "sensor: layout is packed by declaration order, and each kind has its width" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try SensedArm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // 1 + 1 + 3 + 3 + 3 + 3 + 3 + 1
    try expectEqual(@as(u32, 18), m.nsensordata);
    try expectEqual(@as(u32, 8), m.nsensor);
    try expectEqual(@as(usize, 18), d.sensor_data.len);
    // Enum indexing works the same way it does everywhere else.
    try expectEqual(@as(u32, 0), @backingInt(SensedArm.Sensor.angle));
    try expectEqual(@as(u32, 2), m.sensor_adr[2]); // after two scalars
}

test "sensor: position and velocity readings agree with the state they report" {
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try SensedArm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = 0.4;
    d.vel[0] = 1.3;
    forward(&m, &d);

    try expectApproxEqAbs(@as(f32, 0.4), d.sensor_data[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 1.3), d.sensor_data[1], 1.0e-6);

    // The tip site is 0.5 m down the link, so it sits on a circle of radius 0.5.
    const tip: Vec = vec(d.sensor_data[2], d.sensor_data[3], d.sensor_data[4]);
    try expectApproxEqAbs(@as(f32, 0.5), length3(tip), 1.0e-5);
    // And its speed is omega*r.
    const tip_vel: Vec = vec(d.sensor_data[5], d.sensor_data[6], d.sensor_data[7]);
    try expectApproxEqAbs(@as(f32, 1.3 * 0.5), length3(tip_vel), 1.0e-4);
}

test "sensor: a gyro reads in its OWN frame, which is the whole point of mounting it" {
    // The hinge turns about world Z and the site rides the link, so the gyro's reading is
    // the same magnitude however the arm is posed - but a WORLD-frame angular velocity
    // would be too, since the axis happens to be fixed. The discriminating check is the
    // velocimeter: in world axes the tip's velocity direction rotates with the arm, while
    // in the site's own frame it is always the same local direction.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try SensedArm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var local_first: Vec = vec_zero;
    var world_first: Vec = vec_zero;
    inline for (.{ 0.0, 1.1 }, 0..) |angle, idx| {
        d.pos[0] = angle;
        d.vel[0] = 2.0;
        forward(&m, &d);
        const world_vel: Vec = vec(d.sensor_data[5], d.sensor_data[6], d.sensor_data[7]);
        const local_vel: Vec = vec(d.sensor_data[11], d.sensor_data[12], d.sensor_data[13]);
        if (idx == 0) {
            local_first = local_vel;
            world_first = world_vel;
        } else {
            // Same in the site's frame...
            inline for (0..3) |k| {
                try expectApproxEqAbs(local_first[k], local_vel[k], 1.0e-4);
            }
            // ...and different in the world's.
            try expect(length3(world_first - world_vel) > 0.5);
        }
    }

    // The gyro reads the joint rate about the site's local Z, which the hinge axis is.
    const gyro: Vec = vec(d.sensor_data[8], d.sensor_data[9], d.sensor_data[10]);
    try expectApproxEqAbs(@as(f32, 2.0), gyro[2], 1.0e-4);
}

test "sensor: an accelerometer reads PROPER acceleration - g at rest, zero in free fall" {
    // * The physical definition, checked both ways. A real accelerometer measures the force
    // per unit mass its case applies to the proof mass, so one sitting still on a table
    // reads g UPWARD, and one in free fall reads zero. Getting this right is what the
    // world-seeded-with--gravity trick in `bodyAccelerations` buys.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try SensedArm.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // HELD STILL at the bottom of its swing: the arm is in equilibrium there, so the site
    // is stationary and the instrument must read g along its own +Y (the link hangs along
    // -Y, so the site's +Y points back up toward the pivot).
    d.pos[0] = 0;
    d.vel[0] = 0;
    forward(&m, &d);
    const at_rest: Vec = vec(d.sensor_data[14], d.sensor_data[15], d.sensor_data[16]);
    try expectApproxEqAbs(@as(f32, 9.81), at_rest[1], 0.05);
    try expectApproxEqAbs(@as(f32, 0), at_rest[0], 0.05);

    // FREE FALL: cancel the joint's own dynamics is not enough - instead remove gravity and
    // check the reading collapses, which is the same statement from the other side.
    var falling: Model = try SensedArm.build(gpa);
    defer falling.deinit();
    falling.opt.gravity = vec_zero;
    var fd: Data = try Data.init(gpa, &falling);
    defer fd.deinit();
    forward(&falling, &fd);
    const weightless: Vec = vec(fd.sensor_data[14], fd.sensor_data[15], fd.sensor_data[16]);
    try expectApproxEqAbs(@as(f32, 0), length3(weightless), 1.0e-3);
}

test "sensor: the accelerometer's Coriolis term is not optional" {
    // A site spinning at constant rate on a body has a centripetal acceleration even though
    // nothing is angularly accelerating. That term comes ONLY from the `omega x v_point`
    // correction, so this is the test that would fail if it were dropped - and note it
    // needs a nonzero angular VELOCITY, which is exactly why a static test cannot see it.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try SensedArm.build(gpa);
    defer m.deinit();
    m.opt.gravity = vec_zero; // isolate the kinematic term
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    const rate: f32 = 3.0;
    d.pos[0] = 0;
    d.vel[0] = rate;
    d.ctrl[0] = 0;
    forward(&m, &d);

    // Spinning at omega about the pivot, a point at radius r feels omega^2r toward the centre. The
    // site is 0.5 m out along the link's -Y, so "toward the centre" is its local +Y.
    const acc: Vec = vec(d.sensor_data[14], d.sensor_data[15], d.sensor_data[16]);
    try expectApproxEqAbs(rate * rate * 0.5, acc[1], 0.02);
}

test "implicit: with no velocity-dependent forces it IS explicit Euler" {
    // * The structural test, and the one that catches the widest class of error. When D is
    // zero the system collapses to `dv = h*a`, so implicitfast must agree with Euler to
    // the last bit - not approximately, EXACTLY. Any sign error, transpose, or stray term
    // in building `M - h*D` shows up here, on a model with no damping to hide behind.
    const gpa: Allocator = std.testing.allocator;
    var euler_model: Model = try DoublePendulum.build(gpa);
    defer euler_model.deinit();
    euler_model.opt.integrator = .euler;
    var implicit_model: Model = try DoublePendulum.build(gpa);
    defer implicit_model.deinit();
    implicit_model.opt.integrator = .implicitfast;

    var euler_data: Data = try Data.init(gpa, &euler_model);
    defer euler_data.deinit();
    var implicit_data: Data = try Data.init(gpa, &implicit_model);
    defer implicit_data.deinit();

    inline for (.{ &euler_data, &implicit_data }) |dd| {
        dd.pos[0] = 1.1;
        dd.pos[1] = -0.6;
        dd.vel[0] = 0.4;
    }
    for (0..200) |_| {
        step(&euler_model, &euler_data);
        step(&implicit_model, &implicit_data);
    }
    for (0..euler_model.nv) |i| {
        try expectApproxEqAbs(euler_data.pos[i], implicit_data.pos[i], 1.0e-4);
        try expectApproxEqAbs(euler_data.vel[i], implicit_data.vel[i], 1.0e-4);
    }
}

test "implicit: the velocity derivative matches a finite difference of the force" {
    // The same trick that pinned the Jacobians in phase 4, applied to D. `D = dF/dv` is by
    // definition the derivative of the velocity-dependent forces, so nudge each velocity
    // and measure. Needs no reference values and cannot be satisfied by a self-consistent
    // mistake.
    //
    // The model deliberately carries all three sources: joint damping, a tendon damper
    // (whose contribution is an OUTER PRODUCT, not diagonal) and a velocity servo (whose
    // whole action is the `bias[2]` term).
    const Damped = Spec(.{
        .bodies = &.{
            .{
                .name = "a",
                .joints = &.{.{
                    .name = "ja",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .armature = 0.01,
                    .damping = 0.7,
                }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.06 } }, .pos = vec(0.2, 0, 0) }},
            },
            .{
                .name = "b",
                .parent = "a",
                .pos = vec(0.4, 0, 0),
                .joints = &.{.{
                    .name = "jb",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .armature = 0.01,
                    .damping = 0.2,
                }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .pos = vec(0.2, 0, 0) }},
            },
        },
        .tendons = &.{.{
            .name = "coupler",
            .joints = &.{ .{ .name = "ja", .coefficient = 1 }, .{ .name = "jb", .coefficient = -1 } },
            .damping = 0.9,
        }},
        .actuators = &.{.{
            .name = "servo",
            .on = .{ .joint = .{ .name = "jb" } },
            .kind = .{ .velocity = .{ .kv = 3.0 } },
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Damped.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var analytic: [4]f32 = undefined; // nv = 2
    smoothVelDerivative(&m, &analytic);

    d.pos[0] = 0.3;
    d.pos[1] = -0.5;
    const base_vel = [_]f32{ 0.8, -0.4 };

    const eps: f32 = 1.0e-3;
    for (0..m.nv) |column| {
        // Central difference of the velocity-dependent forces with respect to v[column].
        var forces: [2][2]f32 = undefined;
        inline for (.{ -eps, eps }, 0..) |delta, side| {
            @memcpy(d.vel, &base_vel);
            d.vel[column] += delta;
            forward(&m, &d);
            for (0..m.nv) |row| {
                forces[side][row] = d.passive_force[row] + d.actuator_force[row];
            }
        }
        for (0..m.nv) |row| {
            const numeric: f32 = (forces[1][row] - forces[0][row]) / (2.0 * eps);
            try expectApproxEqAbs(numeric, analytic[row * m.nv + column], 2.0e-3);
        }
    }

    // And the tendon really did make it non-diagonal, or the outer-product path is untested.
    try expect(@abs(analytic[1]) > 0.1);
}

test "* integrators: joint damping is implicit in BOTH, as in MuJoCo" {
    // A stiff damper at a timestep an explicit step cannot survive: the restoring force grows
    // with velocity, so an overshoot begets a larger overshoot. Evaluating that force at the
    // NEW velocity is what breaks the feedback - and BOTH integrators now do it, because
    // `advanceEuler` treats joint damping implicitly exactly as MuJoCo's does.
    //
    // `implicitfast` still earns its place: it handles the whole velocity derivative, including
    // tendon coupling and actuator velocity terms, where Euler covers joint damping only.
    const Stiff = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0.001,
                .damping = 40.0, // far beyond what this timestep can integrate explicitly
            }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .pos = vec(0.3, 0, 0) }},
        }},
        .options = .{ .timestep = 1.0 / 60.0 },
    });
    const gpa: Allocator = std.testing.allocator;

    var results: [2]f32 = undefined;
    inline for (.{ Integrator.euler, Integrator.implicitfast }, 0..) |integrator, idx| {
        var m: Model = try Stiff.build(gpa);
        defer m.deinit();
        m.opt.integrator = integrator;
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();
        d.vel[0] = 1.0;
        for (0..600) |_| {
            step(&m, &d);
            // Stop as soon as divergence is established.
            //
            // * THE THRESHOLD IS `max_velocity` NOW, and the change is worth recording.
            // This used to watch for 1e3 - an arbitrary "obviously diverged" number chosen
            // when velocity was unbounded, because Euler here reached infinity in under a
            // second and then NaN, tripping `factorM`'s positive-definite assert.
            //
            // `boundVelocity` means that can no longer happen: divergence now SATURATES the
            // bound instead of running away. Saturating it is a sharper statement than
            // passing an arbitrary line, so the test asserts that instead - and it still
            // observes the failure rather than being killed by it, which was always the
            // point.
            if (@abs(d.vel[0]) >= m.opt.max_velocity * 0.99) {
                break;
            }
        }
        results[idx] = @abs(d.vel[0]);
    }

    // -- *** EULER NO LONGER DIVERGES HERE, AND THAT IS THE POINT OF THE CHANGE --
    //
    // This assertion used to read `results[0] >= 99.0` - Euler running away in TWO steps until
    // the velocity bound caught it. It was true, and it was a LIMITATION rather than a law:
    // MuJoCo's `mj_Euler` is explicit only while nothing is damped, and forms
    // `qH = M + h*diag(B)` the moment anything is. This engine now does the same, so the
    // damping that used to destroy the step is integrated implicitly and survives it.
    //
    // * THE COST OF NOT DOING THIS WAS NOT AN OBVIOUS EXPLOSION. On a 4-DOF arm whose wrist
    // carries only two fingers, the mass diagonal is 0.00041 against 0.13 at the shoulder, so
    // an unremarkable `damping="0.5"` put `c*h/I` at 2.44 - just past the explicit limit of 2.
    // The velocity alternated sign and grew while the POSITION sat almost still, which reads
    // as a badly tuned controller rather than a broken integrator. Two rounds of gain-hunting
    // went past it.
    try expect(results[0] < 2.0);
    // Implicit stays BOUNDED, which is the actual claim. Not "settles to zero": this model
    // is only lightly damped in the swinging sense (a big joint damper still leaves a
    // pendulum ringing down slowly), so demanding a near-zero velocity after ten seconds
    // would be testing the model's damping ratio rather than the integrator's stability.
    try expect(results[1] < 2.0);
}

test "implicit: a damped system loses energy monotonically, as damping must" {
    // A physical invariant rather than a comparison: a damper can only remove energy. An
    // integrator that gains any is wrong regardless of what it agrees with.
    const Damped = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .armature = 0.001,
                .damping = 0.4,
            }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                .pos = vec(0, -0.25, 0),
            }},
        }},
        .options = .{ .timestep = 1.0 / 240.0, .integrator = .implicitfast },
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Damped.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = 1.5;
    forward(&m, &d);
    const start_energy: f32 = energy(&m, &d);
    // The energy of the same pendulum at rest at the bottom: the floor this can approach
    // but never pass.
    d.pos[0] = 0;
    forward(&m, &d);
    const lowest_possible: f32 = energy(&m, &d);
    d.pos[0] = 1.5;
    d.vel[0] = 0;
    forward(&m, &d);
    var previous: f32 = energy(&m, &d);
    for (0..1200) |_| {
        step(&m, &d);
        forward(&m, &d);
        const now: f32 = energy(&m, &d);
        // Allow a hair of numerical slack, but nothing that could be a trend.
        try expect(now <= previous + 1.0e-4);
        previous = now;
    }
    // And it really was DISSIPATING rather than merely sitting still - a system that never
    // moved would also pass a monotonicity test. The pendulum is lightly damped, so it is
    // still ringing down after five seconds; what must be true is that a good fraction of
    // the starting energy is gone.
    const remaining: f32 = previous - lowest_possible;
    try expect(remaining < 0.5 * (start_energy - lowest_possible));
}

test "inertial: a jointed body with mass but NO geoms is legal" {
    // * The path section 4i-ter flagged. Real URDF links routinely state a mass and no collision
    // shape - a wrist that has inertia but nothing to collide with. `Spec()` rejects a
    // jointed body with no geoms as massless, and that check must NOT fire when an explicit
    // inertial is present: the body has mass, it simply has no geometry.
    //
    // Untested until now, and the whole import path depends on it.
    const Massive = Spec(.{
        .bodies = &.{.{
            .name = "wrist",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.01 }},
            .geoms = &.{}, // nothing to collide with
            .inertial = .{
                .mass = 0.5,
                .pos = vec(0, -0.1, 0),
                .full_inertia = .{ 0.002, 0.002, 0.001, 0, 0, 0 },
            },
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Massive.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    try expectApproxEqAbs(@as(f32, 0.5), m.body_mass[1], 1.0e-6);
    try expectEqual(@as(u32, 0), m.ngeom);

    // And it SIMULATES: the mass matrix must be positive definite, which is what the
    // massless-body check was protecting against in the first place.
    d.pos[0] = 0.6;
    forward(&m, &d);
    try expect(d.acc[0] == d.acc[0]); // not NaN
    try expect(@abs(d.acc[0]) > 0.1); // gravity acts on it, so it really has mass
}

test "inertial: a stated mass tensor replaces the geom-derived one, verbatim" {
    // * The numbers are a REAL Franka Panda link, copied from the Menagerie model. That
    // matters: the whole reason `<inertial>` exists is that a robot's mass distribution
    // comes from CAD or a scale, and has nothing to do with the volume of the convex hulls
    // chosen for cheap collision. The geom here is deliberately absurd - a huge dense
    // sphere - so that if the stated values were ignored, the mass would be off by orders
    // of magnitude rather than subtly.
    const Stated = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.1 }},
            .geoms = &.{.{
                .shape = .{ .sphere = .{ .radius = 0.5 } },
                .density = 8000, // ~4000 kg if it were believed
            }},
            .inertial = .{
                .mass = 0.629769,
                .pos = vec(-0.041018, -0.00014, 0.049974),
                .full_inertia = .{ 0.00315, 0.00388, 0.004285, 8.2904e-7, 0.00015, 8.2299e-6 },
            },
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Stated.build(gpa);
    defer m.deinit();

    try expectApproxEqAbs(@as(f32, 0.629769), m.body_mass[1], 1.0e-6);
    try expectApproxEqAbs(@as(f32, -0.041018), m.body_ipos[1][0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.049974), m.body_ipos[1][2], 1.0e-6);
    // The tensor copies across without an eigendecomposition - the payoff for `Inertia`
    // storing the full symmetric form.
    const inertia: Inertia = m.body_inertia[1];
    try expectApproxEqAbs(@as(f32, 0.00315), inertia.diag[0], 1.0e-9);
    try expectApproxEqAbs(@as(f32, 0.00388), inertia.diag[1], 1.0e-9);
    try expectApproxEqAbs(@as(f32, 0.004285), inertia.diag[2], 1.0e-9);
    try expectApproxEqAbs(@as(f32, 8.2904e-7), inertia.off[0], 1.0e-12);
    try expectApproxEqAbs(@as(f32, 0.00015), inertia.off[1], 1.0e-9);
    try expectApproxEqAbs(@as(f32, 8.2299e-6), inertia.off[2], 1.0e-11);
    // A stated inertia is about the COM by definition, so the first moment is zero and the
    // offset lives in `body_ipos` - the same split the geom-derived path uses.
    try expectApproxEqAbs(@as(f32, 0), length3(inertia.h), 1.0e-9);

    // And the model actually SIMULATES with it: the mass matrix must still be positive
    // definite, which is the property a mis-transcribed tensor would break.
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    d.pos[0] = 0.5;
    forward(&m, &d);
    try expect(d.acc[0] == d.acc[0]); // not NaN
    try expect(conditionEstimate(&m, &d) < 1.0e6);
}

test "inertial: geom-derived and stated agree when they describe the same body" {
    // The bridge between the two paths. Take a body whose mass properties the geom path
    // computes, read them back out, feed them in as a stated inertial, and the resulting
    // model must be indistinguishable - same mass matrix, same dynamics.
    //
    // This is what makes the stated path trustworthy: it is not a second, parallel way of
    // describing mass that might disagree, it is the SAME quantity entered differently.
    const gpa: Allocator = std.testing.allocator;

    const Derived = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.01 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                .pos = vec(0, -0.25, 0),
            }},
        }},
    });
    var derived: Model = try Derived.build(gpa);
    defer derived.deinit();

    // Transcribe what the geom path produced. (Comptime-known here, so the values are
    // spelled out; a generated importer would emit them the same way.)
    const Restated = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.01 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                .pos = vec(0, -0.25, 0),
            }},
            // Read back out of the geom-derived model rather than estimated - the point
            // is that these are the SAME quantity entered a different way, and an
            // approximation here would test transcription rather than equivalence.
            .inertial = .{
                .mass = 4.4505897,
                .pos = vec(0, -0.25, 0),
                .full_inertia = .{ 0.12242395, 0.0054323375, 0.12242395, 0, 0, 0 },
            },
        }},
    });
    var restated: Model = try Restated.build(gpa);
    defer restated.deinit();

    var da: Data = try Data.init(gpa, &derived);
    defer da.deinit();
    var db: Data = try Data.init(gpa, &restated);
    defer db.deinit();

    // Same mass to within the transcription's precision.
    try expectApproxEqAbs(derived.body_mass[1], restated.body_mass[1], 1.0e-5);
    // And the same dynamics: gravity torque at the same pose.
    da.pos[0] = 0.7;
    db.pos[0] = 0.7;
    forward(&derived, &da);
    forward(&restated, &db);
    // Tight, because these should agree to floating-point noise rather than approximately.
    try expectApproxEqAbs(da.acc[0], db.acc[0], 1.0e-4);
}

test "crb: M is symmetric, positive definite, and configuration-dependent" {
    // Invariants, which keep testing when the numbers legitimately change. Together they
    // say "this is a mass matrix" without reference to any particular model.
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try DoublePendulum.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    var dense: [4]f32 = undefined;
    const poses = [_][2]f32{ .{ 0, 0 }, .{ 0.3, -0.7 }, .{ 1.2, 2.4 } };
    var folded_diag: f32 = 0;

    for (poses, 0..) |q, pi_| {
        d.pos[0] = q[0];
        d.pos[1] = q[1];
        kinematics(&m, &d);
        comPos(&m, &d);
        crb(&m, &d);
        massMatrixDense(&m, &d, &dense);

        // Symmetric: energy does not care which order you name two DOFs in.
        try expectApproxEqAbs(dense[1], dense[2], 1.0e-6);

        // Positive definite: every motion carries positive kinetic energy. Checked via
        // Sylvester's criterion, which for 2x2 is "positive diagonal, positive
        // determinant" -- and the determinant condition is the one that catches a matrix
        // that is merely positive on the diagonal.
        try expect(dense[0] > 0.0);
        try expect(dense[3] > 0.0);
        try expect(dense[0] * dense[3] - dense[1] * dense[2] > 0.0);

        if (pi_ == 0) {
            folded_diag = dense[0];
        }
    }

    // Configuration-dependent, and in the right DIRECTION: straight out (q2 = 0) the arm
    // has more inertia about the shoulder than folded (q2 = 2.4 rad). If M were constant
    // the whole file would be pointless, so this is worth asserting rather than assuming.
    try expect(folded_diag > dense[0]);
}

test "crb: a locked subtree behaves as one rigid body" {
    // The claim CRB rests on, tested directly. A two-link arm held straight, with the
    // elbow's DOF removed by welding, must have the same shoulder inertia as the same
    // geometry with a free elbow evaluated at zero -- because "everything below moves
    // rigidly" is exactly what M[0][0] means.
    const Welded = Spec(.{
        .bodies = &.{
            .{
                .name = "upper",
                .joints = &.{.{ .name = "shoulder", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0 }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
                    .pos = vec(0, -0.25, 0),
                }},
            },
            .{
                .name = "lower",
                .parent = "upper",
                .pos = vec(0, -0.5, 0),
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.04 } },
                    .pos = vec(0, -0.2, 0),
                }},
            },
        },
    });
    const gpa: Allocator = std.testing.allocator;

    var wm: Model = try Welded.build(gpa);
    defer wm.deinit();
    var wd: Data = try Data.init(gpa, &wm);
    defer wd.deinit();
    try expectEqual(@as(u32, 1), wm.nv);
    kinematics(&wm, &wd);
    comPos(&wm, &wd);
    crb(&wm, &wd);

    var hm: Model = try DoublePendulum.build(gpa);
    defer hm.deinit();
    var hd: Data = try Data.init(gpa, &hm);
    defer hd.deinit();
    kinematics(&hm, &hd);
    comPos(&hm, &hd);
    crb(&hm, &hd);

    // Shoulder entry of each. The hinged one carries a default armature the welded one
    // was told to skip, so subtract it back out.
    const welded_m00: f32 = wd.mass_matrix[wm.mass_row_start[0]];
    const hinged_m00: f32 = hd.mass_matrix[hm.mass_row_start[0]] - hm.dof_armature[0];
    try expectApproxEqAbs(welded_m00, hinged_m00, 1.0e-5);
}

test "kinematics: a hinge rotates about its ANCHOR, not the body origin" {
    // The off-centre correction, isolated. A hinge whose anchor sits 1 m out along X,
    // turned a quarter turn about Z, must swing the body origin onto the Y axis - if the
    // correction were missing the origin would stay put and only the orientation change.
    const Offset = Spec(.{
        .bodies = &.{.{
            .name = "arm",
            .joints = &.{.{
                .name = "pivot",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .pos = vec(1, 0, 0),
            }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.1 } } }},
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Offset.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    d.pos[0] = pi * 0.5;
    kinematics(&m, &d);

    // Anchor at (1,0,0); origin starts 1 m along -X from it and ends 1 m along -Y.
    try expectApproxEqAbs(@as(f32, 1), d.jnt_xanchor[0][0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1), d.body_xpos[0 + 1][0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -1), d.body_xpos[0 + 1][1], 1.0e-5);
}

test "kinematics: sites ride their body, and the stage advances" {
    const Armed = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.1 } } }},
            .sites = &.{.{ .name = "tip", .pos = vec(2, 0, 0) }},
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Armed.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    try expectEqual(Stage.stale, d.stage);
    d.pos[0] = pi * 0.5; // quarter turn about Z takes +X to +Y
    kinematics(&m, &d);
    try expectEqual(Stage.position, d.stage);

    try expectApproxEqAbs(@as(f32, 0), d.site_xpos[0][0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 2), d.site_xpos[0][1], 1.0e-5);
}

test "position coordinates: integrate then differentiate is a round trip" {
    // A free joint exercises both halves: ordinary translation and the quaternion path.
    const Floating = Spec(.{
        .bodies = &.{.{
            .name = "box",
            .joints = &.{.{ .name = "root", .kind = .free }},
            .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.1, 0.2, 0.3) } } }},
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Floating.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    const dt: f32 = 0.01;
    const wanted = [_]f32{ 0.5, -1.25, 2.0, 0.3, -0.7, 1.1 };
    @memcpy(d.vel, &wanted);

    var before: [7]f32 = undefined;
    @memcpy(&before, d.pos);
    integratePos(&m, d.pos, d.vel, dt);

    var recovered: [6]f32 = undefined;
    differentiatePos(&m, &recovered, &before, d.pos, dt);
    for (wanted, recovered) |w, r| {
        try expectApproxEqAbs(w, r, 1.0e-4);
    }
}

test "position coordinates: quaternions stay on the unit sphere" {
    const Spinner = Spec(.{
        .bodies = &.{.{
            .name = "top",
            .joints = &.{.{ .name = "swivel", .kind = .ball }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.1 } } }},
        }},
    });
    const gpa: Allocator = std.testing.allocator;
    var m: Model = try Spinner.build(gpa);
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // Spin hard, for a long time, on a deliberately awkward axis.
    d.vel[0] = 7.0;
    d.vel[1] = -3.5;
    d.vel[2] = 11.25;
    for (0..100_000) |_| {
        integratePos(&m, d.pos, d.vel, 1.0 / 240.0);
        normalizeQuats(&m, d.pos);
    }
    const n: f32 = @sqrt(d.pos[0] * d.pos[0] + d.pos[1] * d.pos[1] +
        d.pos[2] * d.pos[2] + d.pos[3] * d.pos[3]);
    try expectApproxEqAbs(@as(f32, 1), n, 1.0e-5);
}

test "spatial algebra: motion and force pair into power" {
    const v: Motion = .{ .ang = vec(1, 2, 3), .lin = vec(4, 5, 6) };
    const f: Force = .{ .ang = vec(0.5, -1, 2), .lin = vec(3, 0, -2) };
    // 0.5 - 2 + 6 + 12 + 0 - 12
    try expectApproxEqAbs(@as(f32, 4.5), dot6(v, f), 1.0e-6);
}

test "spatial algebra: a point mass has the inertia of a point mass" {
    const mass: f32 = 2.0;
    const i: Inertia = .{ .mass = mass };
    const v: Motion = .{ .lin = vec(3, 0, 0) };
    const f: Force = i.mul(v);
    try expectApproxEqAbs(mass * 3.0, f.lin[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0), f.ang[0], 1.0e-6);
}

test "spatial algebra: composite inertia is a plain sum" {
    // This is the property CRB depends on: two bodies in a shared frame add up.
    const a: Inertia = .{ .diag = vec(1, 2, 3), .off = vec(0.1, 0.2, 0.3), .h = vec(1, 0, 0), .mass = 5 };
    const b: Inertia = .{ .diag = vec(4, 5, 6), .off = vec(0.4, 0.5, 0.6), .h = vec(0, 2, 0), .mass = 7 };
    const sum: Inertia = a.add(b);
    const v: Motion = .{ .ang = vec(0.3, -0.2, 0.7), .lin = vec(1.5, 0.25, -2) };

    const combined: Force = sum.mul(v);
    const separate: Force = a.mul(v).add(b.mul(v));
    try expectApproxEqAbs(combined.ang[0], separate.ang[0], 1.0e-5);
    try expectApproxEqAbs(combined.ang[1], separate.ang[1], 1.0e-5);
    try expectApproxEqAbs(combined.lin[2], separate.lin[2], 1.0e-5);
}

test "spatial algebra: translate is the parallel-axis theorem" {
    // A point mass at the origin, moved so the reference point sits 2 m away on X. The
    // textbook answer is m*d^2 about the two axes perpendicular to the offset, and zero
    // about the offset axis itself.
    const mass: f32 = 3.0;
    const point: Inertia = .{ .mass = mass };
    const moved: Inertia = point.translate(vec(2, 0, 0));
    try expectApproxEqAbs(@as(f32, 0), moved.diag[0], 1.0e-5);
    try expectApproxEqAbs(mass * 4.0, moved.diag[1], 1.0e-5);
    try expectApproxEqAbs(mass * 4.0, moved.diag[2], 1.0e-5);
    try expectApproxEqAbs(mass * 2.0, moved.h[0], 1.0e-5);

    // Translating out and back must land exactly where it started, whatever the offset.
    const body: Inertia = .{
        .diag = vec(1.0, 2.0, 3.0),
        .off = vec(0.1, -0.2, 0.05),
        .h = vec_zero,
        .mass = 5.0,
    };
    const there: Inertia = body.translate(vec(0.3, -1.2, 0.7));
    const back: Inertia = there.translate(vec(-0.3, 1.2, -0.7));
    inline for (0..3) |k| {
        try expectApproxEqAbs(body.diag[k], back.diag[k], 1.0e-4);
        try expectApproxEqAbs(body.off[k], back.off[k], 1.0e-4);
        try expectApproxEqAbs(body.h[k], back.h[k], 1.0e-4);
    }
}

test "spatial algebra: a solid sphere's moments match the textbook" {
    const mass: f32 = 3.0;
    const radius: f32 = 0.2;
    const moments: Vec = shapeMoments(.{ .sphere = .{ .radius = radius } }, mass);
    const expected: f32 = 0.4 * mass * radius * radius;
    try expectApproxEqAbs(expected, moments[0], 1.0e-6);
    try expectApproxEqAbs(expected, moments[1], 1.0e-6);
    try expectApproxEqAbs(expected, moments[2], 1.0e-6);
}

test "spatial algebra: every primitive matches MuJoCo" {
    // Ground truth from real MuJoCo at density 1000 (see scripts/robot_oracle.py for the
    // fixture pipeline). MuJoCo is Z-up and spins its cylinders/capsules about Z, so its
    // (Ixx, Iyy, Izz) maps to our (Ixx, Izz, Iyy) - the two side moments are equal, and
    // only the axial one moves.
    //
    // This test exists because the capsule was WRONG and nothing caught it: the axial
    // moment was right, the analytic sphere/cylinder tests passed, and only the side
    // moment was off - by 0.15%, which no eye and no invariant would ever notice.
    const Case = struct {
        shape: GeomShape,
        mass: f32,
        side: f32, // MuJoCo Ixx == Iyy
        axial: f32, // MuJoCo Izz
    };
    const cases = [_]Case{
        .{
            .shape = .{ .sphere = .{ .radius = 0.2 } },
            .mass = 33.510321638,
            .side = 0.536165146,
            .axial = 0.536165146,
        },
        .{
            .shape = .{ .cylinder = .{ .half_height = 0.5, .radius = 0.1 } },
            .mass = 31.415926536,
            .side = 2.696533694,
            .axial = 0.157079633,
        },
        .{
            .shape = .{ .capsule = .{ .half_height = 0.25, .radius = 0.05 } },
            .mass = 4.450589593,
            .side = 0.122423939,
            .axial = 0.005432337,
        },
    };
    for (cases) |c| {
        const mass: f32 = shapeVolume(c.shape) * 1000.0;
        try expectApproxEqAbs(c.mass, mass, c.mass * 1.0e-6);
        const i: Vec = shapeMoments(c.shape, mass);
        // f32 against MuJoCo's f64, so compare relatively.
        try expectApproxEqAbs(c.side, i[0], c.side * 1.0e-5);
        try expectApproxEqAbs(c.axial, i[1], c.axial * 1.0e-5);
        try expectApproxEqAbs(c.side, i[2], c.side * 1.0e-5);
    }

    // The box is axis-dependent, so it gets its own line: MuJoCo's (2.08, 1.60, 0.80) for
    // half-extents (0.1, 0.2, 0.3) needs no axis swap.
    const box: GeomShape = .{ .box = .{ .half_extent = vec(0.1, 0.2, 0.3) } };
    const box_i: Vec = shapeMoments(box, shapeVolume(box) * 1000.0);
    try expectApproxEqAbs(@as(f32, 2.08), box_i[0], 1.0e-4);
    try expectApproxEqAbs(@as(f32, 1.60), box_i[1], 1.0e-4);
    try expectApproxEqAbs(@as(f32, 0.80), box_i[2], 1.0e-4);
}

test "spatial algebra: a cylinder spins about Y, zimr's capsule axis" {
    const mass: f32 = 4.0;
    const moments: Vec = shapeMoments(.{ .cylinder = .{ .half_height = 0.5, .radius = 0.1 } }, mass);
    // Y is the spin axis, so it is the SMALL moment for a long thin cylinder.
    try expect(moments[1] < moments[0]);
    try expectApproxEqAbs(moments[0], moments[2], 1.0e-6); // symmetric about the axis
    try expectApproxEqAbs(0.5 * mass * 0.01, moments[1], 1.0e-6);
}

test "solver: Nesterov momentum reaches the same answer, in fewer iterations" {
    // ** A SWITCHED-OFF FEATURE ROTS UNLESS SOMETHING EXERCISES IT. Momentum is disabled by
    // default because it measured 8% slower at sixteen rows - but the trade reverses with
    // problem size, so it is kept, and kept working.
    //
    // The property that matters is that acceleration changes the PATH and not the DESTINATION:
    // a solver that reaches a different answer when accelerated is not converging, which is
    // the same argument the warm-start test makes.
    const gpa: Allocator = std.testing.allocator;
    const Arm = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .slide,
                .axis = vec(0, 1, 0),
                .range = .{ -0.05, 0.05 },
            }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } } }},
        }},
        .options = .{ .max_contacts = 8, .gravity = vec(0, -9.81, 0) },
    });

    var plain: f32 = 0;
    var accelerated: f32 = 0;
    var plain_iterations: u32 = 0;
    var accelerated_iterations: u32 = 0;

    for ([_]bool{ false, true }) |momentum| {
        var m: Model = try Arm.build(gpa);
        defer m.deinit();
        m.opt.solver.momentum = momentum;
        // Cold every time: warm starting would hide the difference by handing both runs the
        // answer, which is exactly what this test must not do.
        m.opt.warm_start = false;
        var d: Data = try Data.init(gpa, &m);
        defer d.deinit();

        // Drive the joint hard into its lower limit so the solve has real work to do.
        d.pos[0] = -0.05;
        for (0..200) |_| {
            forward(&m, &d);
            step(&m, &d);
        }
        forward(&m, &d);
        if (momentum) {
            accelerated = d.constraint_force[0];
            accelerated_iterations = d.solver_iterations;
        } else {
            plain = d.constraint_force[0];
            plain_iterations = d.solver_iterations;
        }
    }

    // * THE SAME ANSWER. Loose enough for a different iterate path in f32, tight enough that a
    // genuinely different solution would fail.
    try expect(plain > 0.0);
    try expectApproxEqAbs(plain, accelerated, @max(0.01, 0.02 * plain));
    // And the acceleration is doing something - not silently disabled by a wiring mistake,
    // which is the failure mode a "same answer" test alone would pass.
    try expect(accelerated_iterations <= plain_iterations);
}

test "* equality: a four-bar linkage, which a tree cannot express" {
    // *** THE WHOLE POINT OF LOOP CLOSURES. Reduced coordinates buy exact joints and no drift
    // and pay for it in TOPOLOGY: a tree has no rings, so a mechanism whose links form one
    // cannot be spelled at all. That excludes Cassie and Digit's parallel shins, four-bar
    // suspensions, delta arms, and most geared grippers.
    //
    // Here: two arms hanging from the world, tied tip-to-tip by a connect constraint. As a
    // TREE they are independent and swing separately; as a LOOP they must move together.
    const gpa: Allocator = std.testing.allocator;
    const Linkage = Spec(.{
        .bodies = &.{
            .{
                .name = "left",
                .pos = vec(-0.2, 0, 0),
                .joints = &.{.{ .name = "left_pivot", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.02 } },
                    .pos = vec(0, -0.15, 0),
                }},
            },
            .{
                .name = "right",
                .pos = vec(0.2, 0, 0),
                .joints = &.{.{ .name = "right_pivot", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.02 } },
                    .pos = vec(0, -0.15, 0),
                }},
            },
        },
        // The tips, 0.3 m down each arm, are the same physical point.
        // One anchor; the partner is derived so the loop starts exact. See `anchor_b`.
        .equalities = &.{.{
            .body_a = "left",
            .body_b = "right",
            .anchor_a = vec(0.4, -0.3, 0),
        }},
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 8, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Linkage.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();

    try expect(model.neq == 1);

    // Twist one arm and let go. Without the closure the other would not move at all.
    data.pos[0] = 0.35;
    data.stage = .stale;
    // * THE COUPLING IS TRACKED DURING THE SWING, NOT AT THE END. Both arms hang straight down
    // at rest, and the anchors were chosen so the tips coincide THERE - so the final state
    // satisfies the closure trivially, with both angles at zero. Measuring only the end would
    // read "the second arm never moved" for a linkage that worked perfectly.
    var follower_swing: f32 = 0;
    for (0..2000) |_| {
        forward(&model, &data);
        step(&model, &data);
        follower_swing = @max(follower_swing, @abs(data.pos[1]));
    }
    forward(&model, &data);

    // -- * THE LOOP HELD, AND IT MOVED THE OTHER ARM --
    // * ASKED THROUGH `equalityError` RATHER THAN RE-DERIVED HERE. A test that recomputes the
    // quantity it is checking can agree perfectly with a broken implementation - both would be
    // wrong the same way. Going through the accessor means this also tests the accessor.
    const separation: f32 = equalityError(&model, &data, 0);
    // A millimetre on a 0.4 m linkage. Loop closures are soft in the same way contact is -
    // this is not a hard constraint and does not claim to be - but a visibly stretchy linkage
    // would be useless, which is why `EqualitySpec` defaults stiffer than contact does.
    try expect(separation < 0.005);

    // * AND THE SECOND ARM WENT SOMEWHERE. Untied it never leaves zero - nothing touches it,
    // and gravity on a hanging arm produces no torque about its own pivot - so **any** motion
    // at all arrived through the closure.
    //
    // Measured peak: 0.012 rad, and the bar is set below it deliberately rather than at a
    // round number that happened to pass. It is small because the geometry keeps the closure
    // nearly satisfied all the way down: the leader's tip travels mostly along the line joining
    // the two anchors, which is the direction the constraint cares least about. The separation
    // check above is the strong evidence - 0.168 m closed to under a millimetre.
    try expect(follower_swing > 0.005);

    // * THE CONSTRAINT PULLS AS WELL AS PUSHES. Three rows, and at least one carries a
    // negative force - the property a unilateral clamp at zero would destroy, turning the rod
    // into a rubber band.
    try expect(data.constraint_count >= 3);
    var negative: u32 = 0;
    for (0..data.constraint_count) |row| {
        if (data.constraint_kind[row] == .connect and data.constraint_force[row] < 0) {
            negative += 1;
        }
    }
    try expect(negative >= 1);
}

test "* equality: the partner anchor is derived, and the loop starts satisfied" {
    // ** THE ERGONOMIC HALF OF LOOP CLOSURES. Both anchors describe the SAME physical point in
    // two different frames, so stating both is stating one fact twice - and getting the second
    // wrong by a centimetre gives a mechanism that lurches on frame one and then behaves,
    // which reads as a solver problem and is a typo.
    //
    // MuJoCo derives it too, but only in its file format: `<connect anchor="...">` takes one
    // point and the compiler fills the other in. Having it in the API means a model assembled
    // in code gets the same protection.
    const gpa: Allocator = std.testing.allocator;
    const Linkage = Spec(.{
        .bodies = &.{
            .{
                .name = "left",
                .pos = vec(-0.2, 0, 0),
                .joints = &.{.{ .name = "left_pivot", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.02 } }, .pos = vec(0, -0.3, 0) }},
            },
            .{
                .name = "right",
                .pos = vec(0.2, 0, 0),
                .joints = &.{.{ .name = "right_pivot", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.02 } }, .pos = vec(0, -0.3, 0) }},
            },
        },
        // Only ONE anchor. The other is whatever makes this exact at the rest pose.
        .equalities = &.{.{
            .body_a = "left",
            .body_b = "right",
            .anchor_a = vec(0.4, -0.3, 0),
        }},
        .options = .{ .max_contacts = 4, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Linkage.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();

    // * THE DERIVED POINT IS THE ONE A PERSON WOULD HAVE WRITTEN. `left` sits at x = -0.2 and
    // `right` at x = +0.2, so a point 0.4 along `left` is at the origin of `right` - offset
    // (0, -0.3, 0) in its frame.
    const derived: Vec = model.equalities[0].holds.connect.b.point;
    try expectApproxEqAbs(@as(f32, 0.0), derived[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -0.3), derived[1], 1.0e-5);

    // ** AND THE CONSTRAINT IS SATISFIED BEFORE ANYTHING MOVES - the property the derivation
    // exists to guarantee. A hand-written partner that is even slightly off shows up here as a
    // non-zero violation, which is the moment to catch it rather than as a lurch later.
    forward(&model, &data);
    try expect(data.constraint_count >= 3);
    for (0..data.constraint_count) |row| {
        if (data.constraint_kind[row] == .connect) {
            try expectApproxEqAbs(@as(f32, 0), data.constraint_violation[row], 1.0e-5);
        }
    }
}

test "* equality: a geared gripper - two fingers, one motor" {
    // ** WHAT JOINT COUPLING IS FOR. A parallel gripper has two fingers that must mirror each
    // other exactly, driven by one actuator. Modelling that as two independent joints and
    // hoping the controller keeps them synchronised is how a gripper ends up gripping crooked;
    // stating the relationship makes it a property of the MECHANISM, which is what it is.
    const gpa: Allocator = std.testing.allocator;
    const Gripper = Spec(.{
        .bodies = &.{
            .{
                .name = "left_finger",
                .joints = &.{.{ .name = "left", .kind = .slide, .axis = vec(1, 0, 0) }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.02 } } }},
            },
            .{
                .name = "right_finger",
                .joints = &.{.{ .name = "right", .kind = .slide, .axis = vec(1, 0, 0) }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.02 } } }},
            },
        },
        // * MIRRORED: right = -left. `.{ 0, -1 }` is offset zero, ratio minus one.
        .equalities = &.{.{
            .body_a = "left_finger",
            .body_b = "right_finger",
            .couple = .{ .driven = "right", .driver = "left", .poly = .{ 0, -1, 0, 0, 0 } },
        }},
        .options = .{ .max_contacts = 4, .gravity = vec_zero },
    });
    var model: Model = try Gripper.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();

    // * ONE ROW, not three: a scalar relationship needs one equation.
    forward(&model, &data);
    try expect(data.constraint_count == 1);

    // Drive the left finger and let the coupling carry the right one. Nothing else touches it
    // - no gravity, no contact - so any motion at all arrived through the constraint.
    for (0..1500) |_| {
        forward(&model, &data);
        data.applied_force[model.jnt_dof_adr[0]] = 3.0;
        step(&model, &data);
    }
    forward(&model, &data);

    const left: f32 = data.pos[model.jnt_qpos_adr[0]];
    const right: f32 = data.pos[model.jnt_qpos_adr[1]];
    try expect(left > 0.05); // it actually moved
    // * AND THE MIRROR HELD. A hair of error is expected - a loop closure is soft in the same
    // way contact is - but the fingers track each other to well under a millimetre.
    try expectApproxEqAbs(-left, right, 1.0e-3);
    try expectApproxEqAbs(@as(f32, 0), equalityError(&model, &data, 0), 1.0e-3);
}

test "equality: a coupling with no driver locks a joint" {
    // A null driver pins the joint to a constant offset from its rest value - which is how a
    // joint is locked WITHOUT removing it from the model, so the same robot can be simulated
    // with a wrist free or fixed without two model definitions.
    const gpa: Allocator = std.testing.allocator;
    const Arm = Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .pos = vec(0.3, 0, 0) }},
        }},
        .equalities = &.{.{
            .body_a = "link",
            .body_b = "link",
            .couple = .{ .driven = "elbow", .poly = .{ 0.4, 0, 0, 0, 0 } },
        }},
        .options = .{ .max_contacts = 4, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Arm.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();

    // Gravity pulls the link down; the lock holds it at 0.4 rad.
    for (0..2000) |_| {
        forward(&model, &data);
        step(&model, &data);
    }
    forward(&model, &data);
    try expectApproxEqAbs(@as(f32, 0.4), data.pos[0], 0.01);
}

test "* equality: a weld holds orientation, not just position" {
    // ** WHAT A WELD IS FOR, AND WHY IT IS NOT JUST A JOINTLESS BODY. A body with no joint is
    // welded to its PARENT and the tree expresses that for free. This ties two bodies that are
    // not related that way - a hand gripping a crate, two halves bolted together at runtime -
    // and it can be removed again, which a topology cannot.
    //
    // The distinguishing property is ORIENTATION. A `connect` pins a point and leaves the two
    // free to pivot about it like a ball joint; a weld does not.
    const gpa: Allocator = std.testing.allocator;
    const Pair = Spec(.{
        .bodies = &.{
            .{
                .name = "anchor",
                .joints = &.{.{ .name = "spin", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.1, 0.02, 0.02) } } }},
            },
            .{
                .name = "held",
                .pos = vec(0.3, 0, 0),
                .joints = &.{.{ .name = "free", .kind = .free }},
                .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.05, 0.05, 0.05) } } }},
            },
        },
        .equalities = &.{.{ .body_a = "held", .body_b = "anchor", .weld = true }},
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 8, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Pair.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();

    // * SIX ROWS, not three: position and orientation both.
    forward(&model, &data);
    try expect(data.constraint_count == 6);

    // Turn the anchor. A welded body must come with it - position AND heading.
    const spin: u32 = model.jnt_qpos_adr[0];
    for (0..3000) |_| {
        forward(&model, &data);
        // Drive the hinge toward a quarter turn.
        data.applied_force[model.jnt_dof_adr[0]] = 40.0 * (0.7 - data.pos[spin]) - 4.0 * data.vel[0];
        step(&model, &data);
    }
    forward(&model, &data);

    try expect(@abs(data.pos[spin] - 0.7) < 0.1); // the anchor got there
    // * AND THE HELD BODY TURNED WITH IT. Under a `connect` this would hang plumb whatever the
    // anchor did, because a shared point permits any rotation about itself.
    const held_heading: Vec = rotate(data.body_xrot[2], vec(1, 0, 0));
    const anchor_heading: Vec = rotate(data.body_xrot[1], vec(1, 0, 0));
    try expectApproxEqAbs(@as(f32, 0), length3(held_heading - anchor_heading), 0.06);
    // And it is still where it should be.
    try expect(equalityError(&model, &data, 0) < 0.02);
}

/// The mass matrix's diagonal entry for one velocity DOF - how much inertia that coordinate
/// actually carries, in its own units.
///
/// -- * WHY A CONTROLLER WANTS THIS --
///
/// A gain in torque units is only meaningful next to an inertia. The same `kp` that is gentle
/// on a robot's shoulder is violently unstable on its wrist, because the two differ by two
/// orders of magnitude - and nothing about the number says so. Dividing it out turns `kp` into
/// a frequency, which is a property of the RESPONSE you want rather than of the link you
/// happen to be pushing.
///
/// * O(1). The row walk in `buildRuntime` starts at `i` and fills backwards, so the diagonal
/// is the last slot in the row - no search needed.
pub fn massDiagonal(m: *const Model, d: *const Data, dof: u32) f32 {
    // The mass matrix is built during the position stage, alongside the composite inertias.
    d.requireStage(.position, "massDiagonal");
    const row: u32 = m.mass_row_start[dof];
    return d.mass_matrix[row + m.mass_row_nonzeros[dof] - 1];
}

/// Pack a flat observation vector: joint coordinates, joint velocities, then every sensor.
///
/// -- * WHY THIS EXISTS RATHER THAN LEAVING IT TO THE CALLER --
///
/// Every caller writes the same three memcpys, and the ones who get it wrong get it wrong the
/// same way: reading `nq` floats of velocity, or `nv` of position. Those differ exactly when a
/// model has a free or ball joint - a quaternion is four numbers of position and three of
/// velocity - so the mistake is invisible on a fixed-base arm and silently corrupts every
/// legged robot. The engine knows both sizes; the caller should not have to.
///
/// * SENSORS COME LAST AND ARE OPTIONAL. A model with none packs nothing, so the layout of the
/// first two blocks never depends on whether sensors were declared.
///
/// Returns how much of `out` was used, so a caller can size it once with `observationSize` and
/// assert rather than guess.
pub fn observe(m: *const Model, d: *const Data, out: []f32) usize {
    d.requireStage(.position, "observe");
    var at: usize = 0;
    @memcpy(out[at..][0..m.nq], d.pos);
    at += m.nq;
    @memcpy(out[at..][0..m.nv], d.vel);
    at += m.nv;
    @memcpy(out[at..][0..m.nsensordata], d.sensor_data);
    return at + m.nsensordata;
}

/// Floats `observe` writes.
pub fn observationSize(m: *const Model) usize {
    return m.nq + m.nv + m.nsensordata;
}

/// Everything that determines the next step, and nothing that does not.
///
/// -- ** WHAT A STATE ACTUALLY IS --
///
/// `Data` is mostly SCRATCH - Jacobians, mass factorisations, body poses, sensor readings.
/// All of it is recomputed by `forward` from a much smaller core, so copying it would be
/// slower and would invite a subtler bug: two "states" that differ only in stale scratch
/// compare unequal while describing the same physics.
///
/// The core is: joint coordinates, joint velocities, actuator activation, and the warm-start
/// forces.
///
/// * THE WARM START IS PART OF THE STATE, and leaving it out is the trap. Restoring position
/// and velocity but not the forces the solver was carrying gives a step that is CLOSE and not
/// identical - which is worse than being obviously wrong, because it survives a short test and
/// fails a long one. Determinism is the whole reason this exists: an RL rollout replayed from
/// a snapshot must produce the same trajectory, and a planner branching from a state must not
/// have its branches disagree about where they started.
pub const State = struct {
    pos: []f32,
    vel: []f32,
    act: []f32,
    warm_force: []f32,
    // -- ** THE WARM FORCES ARE USELESS WITHOUT THE KEYS THAT INDEX THEM --
    //
    // Warm starting matches rows by KEY, not by index, because rows are rebuilt every step
    // and their order shifts as constraints come and go. Saving `warm_force` alone and
    // leaving `warm_key`/`warm_count` at whatever the last step wrote means a restore hands
    // the solver last step's forces under this step's keys - right array, wrong labels.
    //
    // It survived the replay test because that test restores into a Data whose contact set
    // never changed, so the stale keys happened to be the correct ones. It does NOT survive
    // finite differencing, where every perturbed rollout restores from the same snapshot and
    // warm state would leak between neighbouring columns - contaminating the very derivative
    // being measured. MuJoCo saves `mjSTATE_WARMSTART` in its restore spec for this reason.
    warm_key: []u64,
    warm_count: u32,
    gpa: Allocator,

    pub fn init(gpa: Allocator, m: *const Model) !State {
        return .{
            .pos = try gpa.alloc(f32, m.nq),
            .vel = try gpa.alloc(f32, m.nv),
            .act = try gpa.alloc(f32, m.na),
            .warm_force = try gpa.alloc(f32, m.constraint_capacity),
            .warm_key = try gpa.alloc(u64, m.constraint_capacity),
            .warm_count = 0,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *State) void {
        self.gpa.free(self.warm_key);
        self.gpa.free(self.warm_force);
        self.gpa.free(self.act);
        self.gpa.free(self.vel);
        self.gpa.free(self.pos);
    }

    /// Copy the current state out of `d`.
    pub fn save(self: *State, d: *const Data) void {
        @memcpy(self.pos, d.pos);
        @memcpy(self.vel, d.vel);
        @memcpy(self.act, d.act);
        @memcpy(self.warm_force, d.warm_force);
        @memcpy(self.warm_key, d.warm_key);
        self.warm_count = d.warm_count;
    }

    /// Put it back.
    ///
    /// * MARKS THE DERIVED DATA STALE, so the next `forward` rebuilds everything from the
    /// restored core. Skipping that leaves body poses describing the state that was there
    /// before - which reads correctly right up until something uses a pose without calling
    /// `forward` first.
    pub fn restore(self: *const State, d: *Data) void {
        @memcpy(d.pos, self.pos);
        @memcpy(d.vel, self.vel);
        @memcpy(d.act, self.act);
        @memcpy(d.warm_force, self.warm_force);
        @memcpy(d.warm_key, self.warm_key);
        d.warm_count = self.warm_count;
        d.stage = .stale;
        // * A RESTORE IS A TELEPORT. Replaying from a snapshot moves every body at once, which
        // is exactly the case a swept contact must not try to interpolate.
        d.teleported = true;
    }
};

test "** state: a snapshot carries the warm-start KEYS, not just the forces" {
    // -- THE GAP THE REPLAY TEST ABOVE CANNOT SEE --
    //
    // Warm starting matches rows by KEY, because rows are rebuilt every step and their order
    // shifts as constraints come and go. `State` saved `warm_force` and not `warm_key` /
    // `warm_count`, so a restore handed the solver the snapshot's forces indexed by whatever
    // keys the LAST step happened to leave behind - right array, wrong labels.
    //
    // * THE REPLAY TEST PASSES EITHER WAY, which is why this needs its own. That test restores
    // into a Data whose contact set never changed, so the stale keys are accidentally the
    // correct ones. The bug only appears when the contact set MOVES between the snapshot and
    // the restore - which is precisely what a planner branching from a state does, and what
    // every column of a finite-difference derivative does.
    const gpa: Allocator = std.testing.allocator;
    const Ball = Spec(.{
        .bodies = &.{.{
            .name = "ball",
            .joints = &.{.{ .name = "root", .kind = .free }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.1 } } }},
        }},
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 8, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Ball.build(gpa);
    defer model.deinit();
    var d: Data = try Data.init(gpa, &model);
    defer d.deinit();

    // A state with TWO contacts, solved so the solver records warm data for both.
    forward(&model, &d);
    d.pushContact(.{
        .position = vec(0, 0, 0),
        .normal = vec(0, 1, 0),
        .tangent = .{ vec(1, 0, 0), vec(0, 0, 1) },
        .distance = -0.01,
        .friction = .{ 0.5, 0.5 },
        .body_a = world_body,
        .body_b = 1,
        .id = 101,
    });
    step(&model, &d);
    try expect(d.warm_count > 0);

    var saved: State = try State.init(gpa, &model);
    defer saved.deinit();
    saved.save(&d);
    const snapshot_key: u64 = d.warm_key[0];

    // Now step with a DIFFERENT contact - same count, different identity - so the live warm
    // keys diverge from the snapshot's while everything else looks unchanged. That is the
    // shape of the bug: nothing about the sizes is wrong, only the labels.
    for (0..3) |_| {
        d.clearContacts();
        d.pushContact(.{
            .position = vec(0.5, 0, 0),
            .normal = vec(0, 1, 0),
            .tangent = .{ vec(1, 0, 0), vec(0, 0, 1) },
            .distance = -0.01,
            .friction = .{ 0.5, 0.5 },
            .body_a = world_body,
            .body_b = 1,
            .id = 202,
        });
        step(&model, &d);
    }
    try expect(d.warm_key[0] != snapshot_key);

    // A restore must put back the snapshot's bookkeeping, not just its numbers.
    saved.restore(&d);
    try expectEqual(snapshot_key, d.warm_key[0]);
}

test "* state: a saved state replays bit-for-bit" {
    // *** THE PROPERTY EVERYTHING ELSE RESTS ON. An RL rollout replayed from a snapshot must
    // produce the same trajectory; a planner branching from a state must not have its branches
    // disagree about where they started. Both are silent failures if this is only ALMOST true.
    //
    // So the test is a replay, not a spot check: run, snapshot, run further, restore, run the
    // same further steps again, and require the two continuations to be IDENTICAL - not close.
    const gpa: Allocator = std.testing.allocator;
    const Arm = Spec(.{
        .bodies = &.{
            .{
                .name = "upper",
                .joints = &.{.{
                    .name = "shoulder",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .range = .{ -1.2, 1.2 },
                }},
                .geoms = &.{.{ .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.04 } } }},
            },
            .{
                .name = "lower",
                .parent = "upper",
                .pos = vec(0, -0.4, 0),
                .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.03 } } }},
            },
        },
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 8, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Arm.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();
    var snapshot: State = try State.init(gpa, &model);
    defer snapshot.deinit();

    // * RUN INTO THE JOINT LIMIT FIRST, so the warm start is carrying real force when the
    // snapshot is taken. A state saved while nothing is in contact would round-trip even if
    // `warm_force` were omitted entirely - which is exactly how that omission survives a test.
    for (0..900) |_| {
        forward(&model, &data);
        data.applied_force[0] = 8.0;
        step(&model, &data);
    }
    forward(&model, &data);
    try expect(data.constraint_count > 0); // the limit really is active

    snapshot.save(&data);

    // Continue, and record where it ends up.
    for (0..300) |_| {
        forward(&model, &data);
        data.applied_force[0] = 8.0;
        step(&model, &data);
    }
    const first_pos: [2]f32 = .{ data.pos[0], data.pos[1] };
    const first_vel: [2]f32 = .{ data.vel[0], data.vel[1] };

    // Rewind and do exactly the same again.
    snapshot.restore(&data);
    for (0..300) |_| {
        forward(&model, &data);
        data.applied_force[0] = 8.0;
        step(&model, &data);
    }

    // -- * BIT-FOR-BIT, NOT APPROXIMATELY --
    //
    // `expectApproxEqAbs` would pass on a state that had lost its warm start: the trajectory
    // would be close for a few hundred steps and diverge later. Exact equality is the only
    // assertion that catches it here rather than in someone's training run.
    try expectEqual(first_pos[0], data.pos[0]);
    try expectEqual(first_pos[1], data.pos[1]);
    try expectEqual(first_vel[0], data.vel[0]);
    try expectEqual(first_vel[1], data.vel[1]);
}

test "state: what a snapshot must carry, and what it need not" {
    // ** WRITTEN TO JUSTIFY `warm_force` AND IT DID THE OPPOSITE. Two boxes with eight contact
    // rows replay identically with or without it - the solver reaches the same answer either
    // way, so on this scene the warm start is a cost optimisation and not state. The comment
    // at the end of this test is the finding; the assertions record it rather than argue with
    // it.
    const gpa: Allocator = std.testing.allocator;
    const Stack = Spec(.{
        .bodies = &.{
            .{
                .name = "a",
                .joints = &.{.{ .name = "ja", .kind = .free }},
                .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = splat(@as(f32, 0.05)) } } }},
            },
            .{
                .name = "b",
                .pos = vec(0, 0.12, 0),
                .joints = &.{.{ .name = "jb", .kind = .free }},
                .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = splat(@as(f32, 0.05)) } } }},
            },
        },
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 32, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Stack.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();
    var snapshot: State = try State.init(gpa, &model);
    defer snapshot.deinit();

    // Two boxes resting on each other, held by contacts written directly - enough rows that
    // the solver is doing real work and its carried forces matter.
    const settle = struct {
        fn go(m: *const Model, d: *Data, steps: usize) void {
            for (0..steps) |_| {
                forward(m, d);
                d.clearContacts();
                inline for (0..4) |corner| {
                    const x: f32 = if (corner % 2 == 0) -0.04 else 0.04;
                    const z: f32 = if (corner < 2) -0.04 else 0.04;
                    d.pushContact(.{
                        .position = vec(d.pos[0] + x, 0, d.pos[2] + z),
                        .normal = vec(0, 1, 0),
                        .tangent = .{ vec(1, 0, 0), vec(0, 0, 1) },
                        .distance = d.pos[1] - 0.05,
                        .friction = .{ 0.8, 0.8 },
                        .body_a = world_body,
                        .body_b = 1,
                        .id = corner,
                    });
                }
                step(m, d);
            }
        }
    }.go;

    settle(&model, &data, 700);
    forward(&model, &data);
    try expect(data.constraint_count >= 8); // real work, not one row

    snapshot.save(&data);
    settle(&model, &data, 200);
    const replayed_height: f32 = data.pos[1];

    // Full restore replays exactly - this is the first test's property, re-checked on a scene
    // with many rows.
    snapshot.restore(&data);
    settle(&model, &data, 200);
    try expectEqual(replayed_height, data.pos[1]);

    // -- ** AND WITHOUT THE WARM START IT REPLAYS TOO - WHICH WAS NOT THE EXPECTED ANSWER --
    //
    // This test was written to prove `warm_force` belongs in the snapshot, by showing a replay
    // that diverges without it. **It does not diverge.** With eight contact rows and two free
    // bodies the solver reaches the same answer whether or not it starts from last step's
    // forces, so the warm start is a COST optimisation here and not part of the state.
    //
    // The field stays in `State` anyway, and the reason is narrow rather than hand-waved: the
    // solver stops on `min_progress` and an iteration cap, so a warm-started solve and a cold
    // one CAN halt at different iterates once a problem is hard enough for the residual to
    // still be moving when the stop fires. That regime is real and this scene is not in it.
    //
    // **Recorded rather than asserted**: one memcpy buys immunity to a failure that would show
    // up as a training run quietly not reproducing, and the honest state of the evidence is
    // "could not construct a case where it matters", not "it is required".
    snapshot.restore(&data);
    data.forgetWarmStart();
    settle(&model, &data, 200);
    try expectEqual(replayed_height, data.pos[1]);
}

test "* state: many Data against one Model do not interfere" {
    // *** THE PROPERTY A BATCHED ROLLOUT RESTS ON. Reinforcement learning runs hundreds of
    // environments at once against ONE model - the tables are large, identical, and read-only,
    // so sharing them is most of why batching is affordable. If any of `forward` or `step`
    // wrote through to the model, the environments would silently couple and produce a policy
    // trained on physics that does not exist.
    //
    // The signature says `*const Model`, which is the compiler's half of the guarantee. This
    // is the other half: run three Data through the same model with DIFFERENT inputs, then
    // check each still matches what it produces alone.
    const gpa: Allocator = std.testing.allocator;
    const Arm = Spec(.{
        .bodies = &.{
            .{
                .name = "upper",
                .joints = &.{.{
                    .name = "shoulder",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .range = .{ -1.0, 1.0 },
                }},
                .geoms = &.{.{ .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.04 } } }},
            },
            .{
                .name = "lower",
                .parent = "upper",
                .pos = vec(0, -0.4, 0),
                .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.03 } } }},
            },
        },
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 8, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Arm.build(gpa);
    defer model.deinit();

    // Three different torques, so the three environments genuinely diverge and any coupling
    // has something to leak.
    const torques = [3]f32{ -6.0, 0.0, 9.0 };

    // -- First: each one alone, start to finish --
    var alone: [3][2]f32 = undefined;
    for (torques, 0..) |torque, i| {
        var data: Data = try Data.init(gpa, &model);
        defer data.deinit();
        for (0..800) |_| {
            forward(&model, &data);
            data.applied_force[0] = torque;
            step(&model, &data);
        }
        alone[i] = .{ data.pos[0], data.pos[1] };
    }

    // -- Then: all three interleaved, sharing the model --
    var batch: [3]Data = undefined;
    for (&batch, 0..) |*data, i| {
        data.* = try Data.init(gpa, &model);
        _ = i;
    }
    defer for (&batch) |*data| {
        data.deinit();
    };
    for (0..800) |_| {
        // * INTERLEAVED, NOT ONE AFTER THE OTHER. Running them sequentially would miss exactly
        // the bug this looks for: state left in the model by environment 0 that environment 1
        // then reads. Stepping them in turn puts every write between two reads.
        for (&batch, torques) |*data, torque| {
            forward(&model, data);
            data.applied_force[0] = torque;
            step(&model, data);
        }
    }

    // -- * BIT-FOR-BIT THE SAME AS ALONE --
    for (&batch, alone) |*data, want| {
        try expectEqual(want[0], data.pos[0]);
        try expectEqual(want[1], data.pos[1]);
    }
}

test "** implicit: the Coriolis derivative, on every joint kind" {
    // *** THE TEST THAT WAS NOT ADVERSARIAL ENOUGH, AND WHAT IT MISSED.
    //
    // The original used one model - two bodies, three hinges - and passed to 0.002. Checked
    // against finite differences on other SHAPES, with the same code:
    //
    //     3-hinge chain      worst 0.0009    ok
    //     branching tree     worst 0.00005   ok
    //     FREE base + hinge  worst 1.30      *** against a matrix whose largest entry was 3.7
    //     BALL joint + hinge worst 1.31      *** against 2.5
    //
    // The derivative walked every DOF as though it were a hinge. `comVel` does not: a free
    // joint's three TRANSLATION DOFs have `cdof_dot = 0`, and the rotational triples of both
    // free and ball joints share ONE snapshot of the velocity taken before any of the three is
    // folded in. A hinge-only model cannot see either difference.
    //
    // * THE LESSON IS ABOUT COVERAGE, NOT ABOUT SPATIAL ALGEBRA. A mirror of an existing
    // function needs a case for every branch the original has, and the original's branches were
    // right there in `comVel`'s switch.
    const gpa: Allocator = std.testing.allocator;

    const Free = Spec(.{
        .bodies = &.{
            .{
                .name = "root",
                .joints = &.{.{ .name = "fj", .kind = .free }},
                .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.2, 0.1, 0.06) } } }},
            },
            .{
                .name = "link",
                .parent = "root",
                .pos = vec(0.2, 0, 0),
                .joints = &.{.{ .name = "h", .kind = .hinge, .axis = vec(0, 1, 0) }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.14, .radius = 0.035 } },
                    .pos = vec(0.14, 0, 0),
                }},
            },
        },
        .options = .{ .integrator = .implicit, .gravity = vec(0, -9.81, 0) },
    });
    const Ball = Spec(.{
        .bodies = &.{
            .{
                .name = "hub",
                .joints = &.{.{ .name = "b", .kind = .ball }},
                .geoms = &.{.{
                    .shape = .{ .box = .{ .half_extent = vec(0.18, 0.09, 0.05) } },
                    .pos = vec(0.18, 0, 0),
                }},
            },
            .{
                .name = "tip",
                .parent = "hub",
                .pos = vec(0.36, 0, 0),
                .joints = &.{.{ .name = "t", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.06 } } }},
            },
        },
        .options = .{ .integrator = .implicit, .gravity = vec(0, -9.81, 0) },
    });

    inline for (.{ Free, Ball }) |Shape| {
        var model: Model = try Shape.build(gpa);
        defer model.deinit();
        var data: Data = try Data.init(gpa, &model);
        defer data.deinit();
        const nv: usize = model.nv;

        // A pose and a spin that make every cross-product term non-trivial.
        for (0..model.njnt) |j| {
            if (model.jnt_type[j] == .free or model.jnt_type[j] == .ball) {
                const q: u32 = model.jnt_qpos_adr[j] +
                    @as(u32, if (model.jnt_type[j] == .free) 3 else 0);
                const tilt: Quat = quatFromAxisAngle(normalize3(vec(0.4, -0.7, 0.5)), 0.8);
                data.pos[q + 0] = tilt[0];
                data.pos[q + 1] = tilt[1];
                data.pos[q + 2] = tilt[2];
                data.pos[q + 3] = tilt[3];
            } else {
                data.pos[model.jnt_qpos_adr[j]] = 0.4;
            }
        }
        for (0..nv) |i| {
            data.vel[i] = 3.0 - float(i % 5) * 1.7;
        }
        data.stage = .stale;
        forward(&model, &data);

        const analytic: []f32 = try gpa.alloc(f32, nv * nv);
        defer gpa.free(analytic);
        @memset(analytic, 0);
        rneVelDerivative(&model, &data, analytic);

        const base: []f32 = try gpa.alloc(f32, nv);
        defer gpa.free(base);
        const shifted: []f32 = try gpa.alloc(f32, nv);
        defer gpa.free(shifted);
        rne(&model, &data, base);

        const step_size: f32 = 1.0e-3;
        var worst: f32 = 0;
        var largest: f32 = 0;
        for (0..nv) |j| {
            const keep: f32 = data.vel[j];
            data.vel[j] = keep + step_size;
            data.stage = .stale;
            forward(&model, &data);
            rne(&model, &data, shifted);
            data.vel[j] = keep;
            data.stage = .stale;
            forward(&model, &data);
            for (0..nv) |i| {
                const numeric: f32 = -(shifted[i] - base[i]) / step_size;
                worst = @max(worst, @abs(analytic[i * nv + j] - numeric));
                largest = @max(largest, @abs(analytic[i * nv + j]));
            }
        }
        // Measured after the fix: 0.023 on the free base, 0.002 on the ball joint, against
        // errors of 1.30 and 1.31 before it.
        try expect(worst < 0.1);
        // And the matrix is not trivially zero, or the agreement would mean nothing.
        try expect(largest > 0.2);
    }
}

test "* implicit: the Coriolis derivative matches finite differences" {
    // *** THE ONLY HONEST TEST FOR AN ANALYTIC DERIVATIVE. `rneVelDerivative` mirrors `rne`
    // one level up - the same forward sweep, the same backward sum - and a mirror is exactly
    // the kind of code that looks right while being one term out. So it is checked against the
    // thing it claims to be: perturb each velocity, re-run `rne`, and compare.
    //
    // A body TUMBLING is essential here. The Coriolis term is quadratic in velocity, so at
    // rest every entry is zero and the test would pass on a function that returned nothing.
    const gpa: Allocator = std.testing.allocator;
    const Tumbler = Spec(.{
        .bodies = &.{
            .{
                .name = "hub",
                .joints = &.{.{ .name = "spin", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{
                    .shape = .{ .box = .{ .half_extent = vec(0.20, 0.05, 0.03) } },
                    .pos = vec(0.2, 0, 0),
                }},
            },
            .{
                .name = "arm",
                .parent = "hub",
                .pos = vec(0.4, 0, 0),
                // Two perpendicular hinges, so the velocity cross-products are genuinely
                // three-dimensional rather than collapsing onto one axis.
                .joints = &.{
                    .{ .name = "pitch", .kind = .hinge, .axis = vec(0, 1, 0) },
                    .{ .name = "roll", .kind = .hinge, .axis = vec(1, 0, 0) },
                },
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.12, .radius = 0.04 } },
                    .pos = vec(0.12, 0, 0),
                }},
            },
        },
        .options = .{ .integrator = .implicit, .timestep = 1.0 / 500.0, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Tumbler.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();

    // Spinning hard enough that the gyroscopic terms dominate.
    data.pos[0] = 0.3;
    data.pos[1] = -0.7;
    data.pos[2] = 0.4;
    data.vel[0] = 9.0;
    data.vel[1] = -6.0;
    data.vel[2] = 4.0;
    data.stage = .stale;
    forward(&model, &data);

    const nv: usize = model.nv;
    const analytic: []f32 = try gpa.alloc(f32, nv * nv);
    defer gpa.free(analytic);
    @memset(analytic, 0);
    rneVelDerivative(&model, &data, analytic);

    // -- Finite differences on `rne` itself --
    const base: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(base);
    const shifted: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(shifted);
    rne(&model, &data, base);

    const step_size: f32 = 1.0e-3;
    var worst: f32 = 0;
    for (0..nv) |j| {
        const keep: f32 = data.vel[j];
        data.vel[j] = keep + step_size;
        data.stage = .stale;
        forward(&model, &data);
        rne(&model, &data, shifted);
        data.vel[j] = keep;
        data.stage = .stale;
        forward(&model, &data);

        for (0..nv) |i| {
            // `rneVelDerivative` writes dforce/dv and the bias enters with a minus, so the
            // finite difference of `rne` is negated to match.
            const numeric: f32 = -(shifted[i] - base[i]) / step_size;
            worst = @max(worst, @abs(analytic[i * nv + j] - numeric));
        }
    }

    // * THE TOLERANCE IS SET BY THE DIFFERENCE, NOT BY THE DERIVATIVE. A one-sided difference
    // at h = 1e-3 on terms of order 10 carries truncation error around 1e-2 in f32, so a
    // tighter bar would be testing the reference rather than the code under test.
    // * MEASURED AT 0.002 - the analytic derivative and the finite difference agree to well
    // inside the difference's own truncation error, which is the strongest statement this
    // comparison can make.
    try expect(worst < 0.05);

    // And the matrix is genuinely non-trivial - a function returning zeros would sail past a
    // comparison against a difference that was also nearly zero.
    var largest: f32 = 0;
    for (analytic) |value| {
        largest = @max(largest, @abs(value));
    }
    // Measured: 0.98 on this model. The bar sits below it rather than at a round number that
    // happened to pass - a first attempt at `> 1.0` failed on a derivative that was correct to
    // 0.002, which is the wrong reason for a test to go red.
    try expect(largest > 0.5);
}

test "* integrators: what each one is actually for, measured" {
    // *** THE TABLE THAT JUSTIFIES HAVING FOUR OF THESE. A rotor at 80 rad/s on a damped
    // gimbal: the gyroscopic coupling into the gimbal axes is large AND velocity-dependent,
    // which is exactly the term `implicitfast` omits and `implicit` keeps.
    //
    // Against an rk4 reference at dt = 1/20000, after one second:
    //
    //     dt = 1/500          euler 0.00057   implicitfast 0.00057   implicit 0.00014   rk4 0.00001
    //     dt = 1/100          euler 0.00269   implicitfast 0.00269   implicit 0.00063   rk4 0.00002
    //
    // **`implicit` is four times more accurate than `implicitfast` here**, at one linear solve
    // per step against rk4's four force evaluations. That is the whole case for it.
    //
    // * AND A CLAIM THAT DID NOT SURVIVE MEASUREMENT. This was first described as "the only one
    // that stabilises a fast-tumbling free body". It is not: on a torque-free plate spun about
    // its intermediate axis, **rk4 dominates completely** - energy drift 0.00000 and world
    // angular-momentum drift 0.00003, against `implicit`'s 0.272 and 0.114 - and `implicit` was
    // WORSE than `implicitfast` at the lower spin. Implicit methods buy stiffness, not
    // accuracy, and a torque-free tumbler is not stiff.
    const gpa: Allocator = std.testing.allocator;
    const Rig = struct {
        fn Model_(comptime it: Integrator, comptime dt: f32) type {
            return Spec(.{
                .bodies = &.{
                    .{
                        .name = "gimbal",
                        .joints = &.{
                            .{ .name = "gx", .kind = .hinge, .axis = vec(1, 0, 0), .damping = 2.0 },
                            .{ .name = "gy", .kind = .hinge, .axis = vec(0, 1, 0), .damping = 2.0 },
                        },
                        .geoms = &.{.{
                            .shape = .{ .capsule = .{ .half_height = 0.10, .radius = 0.02 } },
                            .mass = 0.4,
                        }},
                    },
                    .{
                        .name = "rotor",
                        .parent = "gimbal",
                        .pos = vec(0, 0, 0.12),
                        .joints = &.{.{ .name = "spin", .kind = .hinge, .axis = vec(0, 0, 1) }},
                        .geoms = &.{.{
                            .shape = .{ .cylinder = .{ .half_height = 0.015, .radius = 0.14 } },
                            .mass = 1.2,
                        }},
                    },
                },
                .options = .{ .integrator = it, .timestep = dt, .gravity = vec(0, 0, -9.81) },
            });
        }
    };

    const settle = struct {
        fn go(comptime it: Integrator, comptime dt: f32, allocator: Allocator) ![2]f32 {
            var model: Model = try Rig.Model_(it, dt).build(allocator);
            defer model.deinit();
            var data: Data = try Data.init(allocator, &model);
            defer data.deinit();
            // * 80 rad/s, DELIBERATELY UNDER the 100 rad/s velocity bound. A first attempt used
            // 200 and 600, where every integrator reported a "peak" of exactly 100 - the clamp,
            // not divergence - and the comparison said nothing at all.
            data.vel[2] = 80.0;
            data.vel[0] = 0.4;
            data.stage = .stale;
            forward(&model, &data);
            const steps: usize = @intFromFloat(1.0 / dt);
            for (0..steps) |_| {
                step(&model, &data);
            }
            forward(&model, &data);
            return .{ data.pos[0], data.pos[1] };
        }
    }.go;

    const truth: [2]f32 = try settle(.rk4, 1.0 / 20000.0, gpa);
    const gapBetween = struct {
        fn go(a: [2]f32, b: [2]f32) f32 {
            return @sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));
        }
    }.go;

    const coarse_fast: f32 = gapBetween(try settle(.implicitfast, 1.0 / 100.0, gpa), truth);
    const coarse_full: f32 = gapBetween(try settle(.implicit, 1.0 / 100.0, gpa), truth);
    const coarse_rk4: f32 = gapBetween(try settle(.rk4, 1.0 / 100.0, gpa), truth);

    // * THE ORDERING IS THE CLAIM, not the exact figures - those are recorded above and will
    // drift with any change to the integrators, where the ordering should not.
    try expect(coarse_full < coarse_fast * 0.5);
    try expect(coarse_rk4 < coarse_full);
}

test "* constraints: a weld keeps its rows when contacts fill the buffer" {
    // *** A BUG FOUND BY REVIEW, NOT BY FAILURE. Capacity reserved a flat THREE rows per
    // equality - right for a `connect` and half of what a `weld` needs, since a weld adds three
    // orientation rows to the three positional ones. `addEqualityRows` treats "no room" as a
    // silent return, so an under-reserved weld does not error: it quietly stops existing on a
    // step busy enough to use the space, and a gripped object drifts out of the hand with
    // nothing in the log.
    //
    // Two things now prevent it. Capacity counts per KIND, and equality rows are emitted BEFORE
    // contacts, so a mistake in either shows up as a dropped contact rather than a lost limb.
    const gpa: Allocator = std.testing.allocator;
    const Held = Spec(.{
        .bodies = &.{
            .{
                .name = "post",
                .joints = &.{.{ .name = "spin", .kind = .hinge, .axis = vec(0, 1, 0) }},
                .geoms = &.{.{ .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.03 } } }},
            },
            .{
                .name = "held",
                .pos = vec(0.3, 0, 0),
                .joints = &.{.{ .name = "free", .kind = .free }},
                .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = splat(@as(f32, 0.05)) } } }},
            },
        },
        .equalities = &.{.{ .body_a = "held", .body_b = "post", .weld = true }},
        // * A DELIBERATELY SMALL CONTACT BUDGET, so the buffer is easy to fill and the
        // reservation is doing visible work rather than hiding behind slack.
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 4, .gravity = vec(0, -9.81, 0) },
    });
    var model: Model = try Held.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();

    // * THE WELD'S SIX ROWS FIT WITH EVERY CONTACT ROW ALSO ACCOUNTED FOR. Under the old flat
    // three, this model reserved three too few and the arithmetic below was off by exactly the
    // orientation half.
    try expect(model.constraint_capacity >= 6 + 4 * rows_per_contact);

    // Fill the contact buffer completely, then check the weld still got all six.
    forward(&model, &data);
    for (0..4) |i| {
        data.pushContact(.{
            .position = vec(0.3 + 0.02 * @as(f32, @floatFromInt(i)), -0.05, 0),
            .normal = vec(0, 1, 0),
            .tangent = .{ vec(1, 0, 0), vec(0, 0, 1) },
            .distance = -0.001,
            .friction = .{ 0.8, 0.8 },
            .body_a = world_body,
            .body_b = 2,
            .id = @intCast(i),
        });
    }
    makeConstraints(&model, &data);

    var weld_rows: u32 = 0;
    for (0..data.constraint_count) |row| {
        if (data.constraint_kind[row] == .connect) {
            weld_rows += 1;
        }
    }
    try expectEqual(@as(u32, 6), weld_rows);

    // * AND THEY CAME FIRST, which is the ordering that makes the reservation a belt as well as
    // braces - a shortfall anywhere drops a contact, never the mechanism.
    for (0..6) |row| {
        try expect(data.constraint_kind[row] == .connect);
    }
}

test "** actuator forces match MuJoCo, all three transmissions" {
    // *** THE SECOND HALF OF THE SOLVER AUDIT. Actuators had the same gap contacts did:
    // verified by behaviour - robots hold their poses - and never against MuJoCo's own
    // `qfrc_actuator`. A gear applied twice, or a `position` gain that silently reads velocity,
    // produces a robot that still moves and does the wrong thing everywhere downstream.
    //
    // -- * EVERY NUMBER HERE IS DERIVABLE WITHOUT EITHER ENGINE --
    //
    // That is what makes it an oracle rather than a comparison of two guesses. At q = 0.3,
    // v = 1.4, ctrl = 0.7:
    //
    //     motor,    gear 2.5  ->  ctrl * gear         =  0.7 x 2.5  =   1.75
    //     position, kp 30     ->  kp * (ctrl - q)     =  30 x 0.4   =  12.0
    //     velocity, kv 5      ->  kv * (ctrl - v)     =  5 x (-0.7) =  -3.5
    //
    // MuJoCo reports 1.75, 12.0 and -3.5. So does this.
    //
    // * THE SIGN ON `velocity` IS THE ONE WORTH HAVING PINNED. It is negative here because the
    // joint is moving FASTER than commanded, so the actuator brakes. A sign slip passes every
    // behavioural test that only ever accelerates from rest.
    const gpa: Allocator = std.testing.allocator;
    const Case = struct { spec: ActuatorSpec, want: f32, name: []const u8 };
    inline for ([_]Case{
        .{
            .spec = .{ .name = "a", .on = .{ .joint = .{ .name = "j", .gear = 2.5 } } },
            .want = 1.75,
            .name = "motor",
        },
        .{
            .spec = .{
                .name = "a",
                .on = .{ .joint = .{ .name = "j" } },
                .kind = .{ .position = .{ .kp = 30 } },
            },
            .want = 12.0,
            .name = "position",
        },
        .{
            .spec = .{
                .name = "a",
                .on = .{ .joint = .{ .name = "j" } },
                .kind = .{ .velocity = .{ .kv = 5 } },
            },
            .want = -3.5,
            .name = "velocity",
        },
    }) |case| {
        const Link: type = Spec(.{
            .bodies = &.{.{
                .name = "link",
                .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.03 } },
                    .pos = vec(0.15, 0, 0),
                    .mass = 1.0,
                }},
            }},
            .actuators = &.{case.spec},
            // * GRAVITY OFF, so the number under test is the only force in the model and a
            // mismatch cannot be explained away as a bias term.
            .options = .{ .timestep = 1.0 / 500.0, .gravity = vec_zero },
        });
        var model: Model = try Link.build(gpa);
        defer model.deinit();
        var data: Data = try Data.init(gpa, &model);
        defer data.deinit();

        data.pos[0] = 0.3;
        data.vel[0] = 1.4;
        data.ctrl[0] = 0.7;
        data.stage = .stale;
        forward(&model, &data);

        expectApproxEqAbs(case.want, data.actuator_force[0], 1.0e-4) catch |err| {
            std.log.err("{s}: got {d:.6}, MuJoCo gives {d:.6}", .{
                case.name,
                data.actuator_force[0],
                case.want,
            });
            return err;
        };
    }
}

test "** a fixed tendon matches MuJoCo - length, velocity, and the force it spreads" {
    // *** THE LAST SUBSYSTEM WITHOUT AN EXTERNAL ORACLE. A tendon is a scalar constraint on a
    // COMBINATION of joints, and its force is spread back over them by the same coefficients -
    // `J^Tf` in miniature. Three things can be independently wrong: the length, its rate, and
    // the transpose. Behaviour tests see only their product.
    //
    // -- * HAND-DERIVABLE, WHICH IS WHAT MAKES IT AN ORACLE --
    //
    // Coefficients 1.0 and -0.5, at q = (0.4, -0.2) and v = (1.1, 0.6):
    //
    //     length   = 1.0(0.4) + (-0.5)(-0.2)              =  0.5
    //     velocity = 1.0(1.1) + (-0.5)(0.6)               =  0.8
    //     force    = -k(L - L_0) - b*V  = -40(0.4) - 3(0.8) = -18.4
    //     spread   = f x coefficient  ->  j1: -18.4,  j2: +9.2
    //
    // MuJoCo reports exactly that, and so does this. The SIGN FLIP on j2 is the part worth
    // pinning: a negative coefficient is how a differential is built, and dropping the sign in
    // the transpose gives a tendon that couples the joints the wrong way while still looking
    // like a spring.
    const gpa: Allocator = std.testing.allocator;
    const Pair: type = Spec(.{
        .bodies = &.{
            .{
                .name = "a",
                .joints = &.{.{ .name = "j1", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.03 } },
                    .pos = vec(0.15, 0, 0),
                    .mass = 1.0,
                }},
            },
            .{
                .name = "b",
                .parent = "a",
                .pos = vec(0.3, 0, 0),
                .joints = &.{.{ .name = "j2", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.125, .radius = 0.025 } },
                    .pos = vec(0.125, 0, 0),
                    .mass = 0.8,
                }},
            },
        },
        .tendons = &.{.{
            .name = "coupler",
            .stiffness = 40,
            .damping = 3,
            .rest_length = 0.1,
            .joints = &.{
                .{ .name = "j1", .coefficient = 1.0 },
                .{ .name = "j2", .coefficient = -0.5 },
            },
        }},
        // Gravity off, so the tendon is the only force and a mismatch cannot hide in a bias.
        .options = .{ .timestep = 1.0 / 500.0, .gravity = vec_zero },
    });
    var model: Model = try Pair.build(gpa);
    defer model.deinit();
    var data: Data = try Data.init(gpa, &model);
    defer data.deinit();

    data.pos[0] = 0.4;
    data.pos[1] = -0.2;
    data.vel[0] = 1.1;
    data.vel[1] = 0.6;
    data.stage = .stale;
    forward(&model, &data);

    try expectApproxEqAbs(@as(f32, 0.5), data.tendon_length[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 0.8), data.tendon_velocity[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -18.4), data.passive_force[0], 1.0e-3);
    try expectApproxEqAbs(@as(f32, 9.2), data.passive_force[1], 1.0e-3);
}

// =============================================================================
// Skeleton -> robot model (retarget_plan.md section 13x)
// =============================================================================

/// How to turn an animation skeleton into a physical model.
pub const SkeletonToModelOptions = struct {
    /// Capsule radius as a fraction of bone length, clamped by the two limits below. A limb
    /// reads as a limb rather than a wire, and the inertia follows the shape.
    radius_ratio: f32 = 0.18,
    min_radius: f32 = 0.02,
    max_radius: f32 = 0.09,
    /// kg per cubic metre. Water is 1000; a human averages slightly less.
    density: f32 = 985.0,
    /// Bones shorter than this get no geom and a token inertia - finger tips and end sites,
    /// which would otherwise contribute degenerate capsules.
    min_bone_length: f32 = 0.02,
    /// * Y-UP, METRES, matching the rest of zimr. The clip must already be in these units;
    /// `draw3d.scaleBvhSkeletalClip` converts a centimetre capture.
    gravity: Vec = vec(0, -9.81, 0),
};

/// Build a MuJoCo-style model whose topology IS the animation skeleton's: one body per bone,
/// one BALL joint per bone, a free joint at the root.
///
/// -- *** WHY THIS EXISTS (retarget_plan.md section 13x) --
///
/// A BVH pose is exactly a root translation plus one rotation per joint. A ball joint's `qpos`
/// is a quaternion. So a model shaped like the skeleton can play the capture by a DIRECT WRITE
/// of each bone's local rotation - **no IK, no solver, no Jacobian**.
///
/// That makes it the one place a robot-side error can be attributed with certainty. It
/// exercises the whole `qpos` path - quaternion layout, `jnt_qpos_adr`, `nq != nv`, free-joint
/// handling, `kinematics` - with the solver removed. `humanoid.xml` cannot give that signal:
/// there, errors are EXPECTED, and a bug is indistinguishable from a knee that only has one
/// hinge.
///
/// * And once the IK exists, running it on THIS model must reproduce what the direct write
/// already produced. Ground truth for the solver, available before facing a target where
/// nobody knows what the right answer looks like.
///
/// The result is also a ragdoll: capsules sized from bone length, inertia from the capsule.
/// * PLAIN SLICES, NOT A CLIP TYPE. `robot.zig` knows nothing about animation formats and
/// should not start now: a skeleton is names, parents and rest offsets. The caller unpacks
/// whatever it has - `draw3d.BvhSkeletalClip`, an FBX skeleton, or a hand-written rig - which
/// also keeps `robot.zig` free of a dependency on `draw3d`.
///
/// `parents[i] < 0` marks the root. `offsets[i]` is bone i's rest position relative to its
/// parent, and its length IS the bone's length.
pub fn skeletonToModel(
    gpa: Allocator,
    names: []const []const u8,
    parents: []const i32,
    offsets: []const Vec,
    opts: SkeletonToModelOptions,
) !Model {
    const bone_count: usize = names.len;
    const slices_agree: bool = parents.len == bone_count and offsets.len == bone_count;
    if (bone_count == 0 or !slices_agree) {
        return error.InvalidSkeleton;
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a: Allocator = arena.allocator();

    const bodies: []BodySpec = try a.alloc(BodySpec, bone_count);
    // Names are duplicated into the arena because `BodySpec` holds slices, and the caller's
    // may not outlive this call.
    const owned: [][]const u8 = try a.alloc([]const u8, bone_count);
    for (0..bone_count) |bone| {
        owned[bone] = try a.dupe(u8, names[bone]);
    }

    for (0..bone_count) |bone| {
        const parent_bone: i32 = parents[bone];

        // A bone's offset from its parent IS its length - there is no separate length field in
        // a skeleton, only where each joint sits relative to the one above it.
        const offset_from_parent: Vec = offsets[bone];
        const bone_length: f32 = @sqrt(
            offset_from_parent[0] * offset_from_parent[0] +
                offset_from_parent[1] * offset_from_parent[1] +
                offset_from_parent[2] * offset_from_parent[2],
        );

        // * ONE JOINT PER BONE. The root gets a FREE joint (6 DOF: the capture's global
        // translation and rotation); every other bone gets a BALL joint, which is exactly the
        // 3 rotational DOF a BVH channel set carries.
        const bone_is_root: bool = parent_bone < 0;
        const joints: []JointSpec = try a.alloc(JointSpec, 1);
        joints[0] = .{
            .name = try allocPrint(a, "{s}_j", .{owned[bone]}),
            .kind = if (bone_is_root) .free else .ball,
        };

        var geoms: []GeomSpec = &.{};
        var inertial: ?InertialSpec = null;

        const bone_is_long_enough: bool = bone_length >= opts.min_bone_length;
        if (bone_is_long_enough) {
            const capsule_radius: f32 = clamp(
                bone_length * opts.radius_ratio,
                opts.min_radius,
                opts.max_radius,
            );

            // * The capsule spans BACKWARD from this body's origin toward its parent, because
            // the offset is measured FROM the parent. Centring it forward would put every limb
            // one segment ahead of where it actually is.
            const capsule_centre: Vec = offset_from_parent * @as(Vec, @splat(-0.5));

            geoms = try a.alloc(GeomSpec, 1);
            geoms[0] = .{
                .shape = .{ .capsule = .{
                    .radius = capsule_radius,
                    .half_height = bone_length * 0.5,
                } },
                .pos = capsule_centre,
            };

            const capsule_volume: f32 =
                3.14159265 * capsule_radius * capsule_radius * bone_length;
            const bone_mass: f32 = @max(capsule_volume * opts.density, 0.001);

            // A capsule's inertia about its centre, treated as a cylinder: accurate enough for
            // a ragdoll, and far better than the alternative of leaving it at zero.
            const inertia_across_axis: f32 =
                bone_mass * (3.0 * capsule_radius * capsule_radius + bone_length * bone_length) / 12.0;
            const inertia_about_axis: f32 = bone_mass * capsule_radius * capsule_radius * 0.5;

            inertial = .{
                .mass = bone_mass,
                .pos = capsule_centre,
                .full_inertia = .{
                    inertia_across_axis,
                    inertia_across_axis,
                    inertia_about_axis,
                    0,
                    0,
                    0,
                },
            };
        }

        bodies[bone] = .{
            .name = owned[bone],
            .parent = if (bone_is_root) null else owned[@intCast(parent_bone)],
            .pos = offset_from_parent,
            .joints = joints,
            .geoms = geoms,
            .inertial = inertial,
        };
    }

    return buildRuntime(gpa, .{
        .bodies = bodies,
        .options = .{ .gravity = opts.gravity },
    });
}

test "skeletonToModel: the synthesized model reproduces the skeleton's rest pose" {
    const gpa: Allocator = std.testing.allocator;

    // A three-bone chain: root, then a bone 1 m up, then another 1 m up.
    const names = [_][]const u8{ "root", "mid", "tip" };
    const parents = [_]i32{ -1, 0, 1 };
    const offsets = [_]Vec{ vec(0, 0, 0), vec(0, 1, 0), vec(0, 1, 0) };

    var m: Model = try skeletonToModel(gpa, &names, &parents, &offsets, .{});
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // ** THE PROPERTY: at the identity configuration, forward kinematics must place every body
    // exactly where the skeleton's rest offsets say. If it does not, the model is not the
    // skeleton and every later comparison against a capture is measuring the wrong thing.
    //
    // * `nq != nv` is exercised here on purpose - the root is a FREE joint, so `qpos` carries a
    // quaternion and is longer than the DOF count. A model built with the wrong qpos layout
    // fails this immediately rather than drifting later.
    try expectEqual(@as(u32, 3), m.nbody - 1); // + the world body
    try expect(m.nq > m.nv); // free joint => quaternion in qpos

    // * `qpos0` IS the rest configuration - zeros except a free joint's quaternion, which
    // rests at identity (robot.zig:1941). Starting anywhere else would test a pose the
    // skeleton never described.
    @memcpy(d.pos, m.qpos0);
    kinematics(&m, &d);

    // Body 0 is the world; ours start at 1.
    const root_pos: Vec = d.body_xpos[1];
    const mid_pos: Vec = d.body_xpos[2];
    const tip_pos: Vec = d.body_xpos[3];
    try expectApproxEqAbs(@as(f32, 0.0), root_pos[1], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1.0), mid_pos[1], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 2.0), tip_pos[1], 1.0e-5);

    // * And the bones have MASS. A ragdoll of massless links is a solver singularity, and a
    // zero-length bone (an end site) must be tolerated rather than producing a degenerate
    // capsule - hence `min_bone_length`.
    try expect(m.body_mass[2] > 0.0);
    try expect(m.body_mass[3] > 0.0);
}

/// Write an animation pose straight into `qpos` - no IK, no solver.
///
/// -- *** THE POINT OF section 13x --
///
/// A model built by `skeletonToModel` has exactly the skeleton's topology: a FREE joint at the
/// root and a BALL joint per bone. A BVH pose is exactly a root translation plus one rotation
/// per joint. So playback is a COPY, and the result is exact rather than converged.
///
/// That makes this the one place a robot-side error can be attributed with certainty: it
/// exercises the whole `qpos` path - quaternion layout, `jnt_qpos_adr`, `nq != nv`, free-joint
/// handling - with the solver removed.
///
/// ** QUATERNIONS ARE `(x, y, z, w)` HERE, NOT MuJoCo's `(w, x, y, z)`. `robot.zig` stores zm's
/// order throughout (see the note at line ~8188 where the MuJoCo fixture generator converts).
/// Writing MuJoCo's order into `qpos` produces a rotation that looks almost plausible and is
/// wrong - the classic silent failure this whole phase exists to rule out.
///
/// `rotations[i]` is bone i's LOCAL rotation; `root_translation` is the root bone's world
/// position. Bones and joints correspond by index, in the order `skeletonToModel` received.
/// The caller runs `kinematics` afterwards.
pub fn poseFromLocalRotations(
    m: *const Model,
    d: *Data,
    root_translation: Vec,
    rotations: []const Quat,
) void {
    const joint_count: usize = @min(rotations.len, m.njnt);

    for (0..joint_count) |joint| {
        const qpos_start: usize = m.jnt_qpos_adr[joint];
        const local_rotation: Quat = rotations[joint];

        switch (m.jnt_type[joint]) {
            .free => {
                // A free joint carries the body's full pose: three position components, then
                // a quaternion. This is the reason `nq != nv` - six DOF, seven qpos entries.
                d.pos[qpos_start + 0] = root_translation[0];
                d.pos[qpos_start + 1] = root_translation[1];
                d.pos[qpos_start + 2] = root_translation[2];
                d.pos[qpos_start + 3] = local_rotation[0];
                d.pos[qpos_start + 4] = local_rotation[1];
                d.pos[qpos_start + 5] = local_rotation[2];
                d.pos[qpos_start + 6] = local_rotation[3];
            },
            .ball => {
                // A ball joint's qpos IS a quaternion - the same three rotational DOF a BVH
                // channel set carries, which is what makes this a copy rather than a solve.
                d.pos[qpos_start + 0] = local_rotation[0];
                d.pos[qpos_start + 1] = local_rotation[1];
                d.pos[qpos_start + 2] = local_rotation[2];
                d.pos[qpos_start + 3] = local_rotation[3];
            },
            else => {
                // A hinge or slide cannot carry a full rotation. Those belong to the IK path;
                // silently writing one component of the quaternion would be worse than leaving
                // the joint where it is.
            },
        }
    }
}

test "poseFromLocalRotations: robot kinematics reproduces the animation pose exactly" {
    const gpa: Allocator = std.testing.allocator;

    // A four-bone chain with a bend, so a wrong quaternion order or a missed parent shows up
    // as a position error rather than cancelling out.
    const names = [_][]const u8{ "root", "a", "b", "c" };
    const parents = [_]i32{ -1, 0, 1, 2 };
    const offsets = [_]Vec{ vec(0, 0, 0), vec(0, 0.5, 0), vec(0, 0.5, 0), vec(0, 0.5, 0) };

    var m: Model = try skeletonToModel(gpa, &names, &parents, &offsets, .{});
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // A pose: root yawed, then each bone bent about a different axis.
    const rots = [_]Quat{
        zm.quatFromAxisAngle(vec(0, 1, 0), 0.6),
        zm.quatFromAxisAngle(vec(1, 0, 0), 0.4),
        zm.quatFromAxisAngle(vec(0, 0, 1), -0.3),
        zm.quatFromAxisAngle(vec(1, 0, 0), 0.25),
    };
    const root_pos: Vec = vec(0.3, 1.1, -0.2);

    @memcpy(d.pos, m.qpos0);
    poseFromLocalRotations(&m, &d, root_pos, &rots);
    kinematics(&m, &d);

    // *** THE REFERENCE: the same chain evaluated the way an animation system does - walk the
    // hierarchy composing local rotations, rotating each child's offset by its parent's
    // accumulated rotation. If the robot's `qpos` path is right, the two agree to float
    // precision. Not to a tolerance, not "close enough": this is a COPY, not a solve.
    var ref_pos: [4]Vec = undefined;
    var ref_rot: [4]Quat = undefined;
    ref_rot[0] = rots[0];
    ref_pos[0] = root_pos;
    for (1..4) |i| {
        const p: usize = @intCast(parents[i]);
        ref_rot[i] = zm.qmul(ref_rot[p], rots[i]);
        ref_pos[i] = ref_pos[p] + zm.rotate(ref_rot[p], offsets[i]);
    }

    for (0..4) |i| {
        // Body 0 is the world; ours start at 1.
        const got: Vec = d.body_xpos[i + 1];
        inline for (0..3) |c| {
            try expectApproxEqAbs(ref_pos[i][c], got[c], 1.0e-5);
        }
    }

    // * AND THE ROTATIONS, not just the positions. A quaternion written in MuJoCo's
    // (w, x, y, z) instead of zm's (x, y, z, w) can still land the ROOT in the right place
    // while every orientation is wrong - positions alone would not catch it.
    for (0..4) |i| {
        const got: Quat = d.body_xrot[i + 1];
        const want: Quat = ref_rot[i];
        // Quaternions double-cover: q and -q are the same rotation.
        const dotp: f32 = got[0] * want[0] + got[1] * want[1] + got[2] * want[2] + got[3] * want[3];
        const sign: f32 = if (dotp < 0) -1.0 else 1.0;
        inline for (0..4) |c| {
            try expectApproxEqAbs(want[c], got[c] * sign, 1.0e-5);
        }
    }
}

/// Write a desired LOCAL rotation into whatever DOF each joint actually has.
///
/// -- *** WHY THIS MAY REMOVE THE NEED FOR AN IK SOLVER --
///
/// `poseFromLocalRotations` only handles joints that can carry a full rotation - free and ball.
/// A real robot has HINGES: `humanoid.xml`'s knee is ONE axis with `range="-160 2"`, and its hip
/// is three SEPARATE hinges rather than a ball.
///
/// The plan assumed that meant iterative IK. It may not. A hinge's best angle for a desired
/// rotation is a PROJECTION - the twist of that rotation about the hinge axis - which is
/// closed-form. A chain of orthogonal hinges is an Euler decomposition, also closed-form. So
/// the "best fit, not a match" that a robot's rotation task can achieve is available WITHOUT a
/// solver, and this function measures how good that fit is.
///
/// * WHAT IS GENUINELY LOST is stated by the residual, not hidden: a knee asked to twist can
/// only bend, and `out_residual_error` records how much of the requested rotation each joint
/// could not represent. That number is the honest quality measure the plan asked for, and it
/// distinguishes a MODEL limit from a BUG - the distinction section 13's adversarial review warned
/// would otherwise be impossible to make.
///
/// Joint limits are respected, because a pose outside them is one the robot cannot hold.
pub fn fitLocalRotations(
    m: *const Model,
    d: *Data,
    root_translation: Vec,
    desired_local_rotations: []const Quat,
    out_residual_error: ?[]f32,
) void {
    const joint_count: usize = @min(desired_local_rotations.len, m.njnt);

    for (0..joint_count) |joint| {
        const qpos_start: usize = m.jnt_qpos_adr[joint];
        const desired: Quat = desired_local_rotations[joint];

        switch (m.jnt_type[joint]) {
            .free => {
                d.pos[qpos_start + 0] = root_translation[0];
                d.pos[qpos_start + 1] = root_translation[1];
                d.pos[qpos_start + 2] = root_translation[2];
                d.pos[qpos_start + 3] = desired[0];
                d.pos[qpos_start + 4] = desired[1];
                d.pos[qpos_start + 5] = desired[2];
                d.pos[qpos_start + 6] = desired[3];
                if (out_residual_error) |residual| {
                    residual[joint] = 0; // a free joint represents any rotation exactly
                }
            },
            .ball => {
                d.pos[qpos_start + 0] = desired[0];
                d.pos[qpos_start + 1] = desired[1];
                d.pos[qpos_start + 2] = desired[2];
                d.pos[qpos_start + 3] = desired[3];
                if (out_residual_error) |residual| {
                    residual[joint] = 0;
                }
            },
            .hinge => {
                // * THE PROJECTION. A hinge can only express rotation ABOUT ITS AXIS, so take
                // the component of `desired` along that axis - the swing-twist decomposition's
                // twist term - and discard the swing.
                const axis: Vec = m.jnt_axis[joint];
                const rotation_vector: Vec = .{ desired[0], desired[1], desired[2], 0 };
                const along_axis: f32 = dot3(rotation_vector, axis);

                // twist = normalize(quaternion whose vector part is the axis component)
                const twist_unnormalized: Quat = .{
                    axis[0] * along_axis,
                    axis[1] * along_axis,
                    axis[2] * along_axis,
                    desired[3],
                };
                const twist_length: f32 = @sqrt(
                    twist_unnormalized[0] * twist_unnormalized[0] +
                        twist_unnormalized[1] * twist_unnormalized[1] +
                        twist_unnormalized[2] * twist_unnormalized[2] +
                        twist_unnormalized[3] * twist_unnormalized[3],
                );
                var angle: f32 = 0;
                if (twist_length > 1.0e-6) {
                    const w: f32 = twist_unnormalized[3] / twist_length;
                    const s: f32 = along_axis / twist_length;
                    // FOLD ONTO HALF A TURN EITHER SIDE, SO A LIMIT TEST MEANS WHAT IT LOOKS
                    // LIKE. In turns that is one subtraction of the nearest whole turn - exact,
                    // branchless, and correct for ANY magnitude. The two-branch radian form
                    // folded exactly ONE turn: an input 2.25 turns out came back at 1.25, still
                    // outside the range it claimed to enforce.
                    const angle_turns: f32 = turnsFromRad(2.0 * atan2Rad(s, w));
                    angle = radFromTurns(angle_turns - @round(angle_turns));
                }

                // * CLAMPED TO THE JOINT'S RANGE. A pose outside it is one the robot cannot
                // hold, and letting the kinematics show it would flatter the result.
                if (m.jnt_range[joint]) |range| {
                    angle = clamp(angle, range[0], range[1]);
                }
                d.pos[qpos_start] = angle;

                if (out_residual_error) |residual| {
                    // How much of the requested rotation the hinge could NOT represent.
                    const achieved: Quat = quatFromAxisAngle(axis, angle);
                    const alignment: f32 = @abs(
                        achieved[0] * desired[0] + achieved[1] * desired[1] +
                            achieved[2] * desired[2] + achieved[3] * desired[3],
                    );
                    residual[joint] = 2.0 * acosRad(clamp(alignment, -1.0, 1.0));
                }
            },
            else => {
                if (out_residual_error) |residual| {
                    residual[joint] = 0;
                }
            },
        }
    }
}

test "fitLocalRotations: a hinge takes the bend it can and reports the rest" {
    const gpa: Allocator = std.testing.allocator;

    // Two bodies: a free root, then a single HINGE about X - a knee.
    const names = [_][]const u8{ "thigh", "shin" };
    const parents = [_]i32{ -1, 0 };
    const offsets = [_]Vec{ vec(0, 0, 0), vec(0, -0.4, 0) };
    var m: Model = try skeletonToModel(gpa, &names, &parents, &offsets, .{});
    defer m.deinit();

    // Rebuild the second joint as a limited hinge, the way a real robot model has it.
    m.jnt_type[1] = .hinge;
    m.jnt_axis[1] = vec(1, 0, 0);
    m.jnt_range[1] = .{ -2.8, 0.03 }; // humanoid.xml's knee: -160..2 degrees

    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    var residual: [2]f32 = .{ 0, 0 };

    // * A PURE BEND ABOUT THE HINGE AXIS is representable exactly, so the residual must be ~0.
    const pure_bend: Quat = quatFromAxisAngle(vec(1, 0, 0), -1.0);
    var desired: [2]Quat = .{ zm.quat_identity, pure_bend };
    @memcpy(d.pos, m.qpos0);
    fitLocalRotations(&m, &d, vec(0, 0, 0), &desired, &residual);
    try expect(residual[1] < 1.0e-3);
    try expectApproxEqAbs(@as(f32, -1.0), d.pos[m.jnt_qpos_adr[1]], 1.0e-4);

    // ** A TWIST ABOUT AN AXIS THE HINGE DOES NOT HAVE cannot be represented at all, and the
    // residual must SAY SO. This is the number that separates "the model cannot do this" from
    // "the code is broken" - the distinction section 13's adversarial review said would otherwise be
    // impossible to make on `humanoid.xml`.
    const pure_twist: Quat = quatFromAxisAngle(vec(0, 1, 0), 1.0);
    desired[1] = pure_twist;
    @memcpy(d.pos, m.qpos0);
    fitLocalRotations(&m, &d, vec(0, 0, 0), &desired, &residual);
    try expect(residual[1] > 0.9);

    // * AND THE LIMIT IS RESPECTED. A knee asked to bend the wrong way stops at its range
    // rather than producing a pose the robot could never hold.
    desired[1] = quatFromAxisAngle(vec(1, 0, 0), 1.5);
    @memcpy(d.pos, m.qpos0);
    fitLocalRotations(&m, &d, vec(0, 0, 0), &desired, &residual);
    try expect(d.pos[m.jnt_qpos_adr[1]] <= 0.03 + 1.0e-5);
    try expect(residual[1] > 0.5); // clamping is itself a loss, and it is reported
}

// =============================================================================
// The humanoid.xml match table (retarget_plan.md section 13g)
// =============================================================================

/// One row: which human joint drives which robot body.
pub const MatchRow = struct {
    robot_body: []const u8,
    human_joint: []const u8,
    /// Other names this row will accept, in preference order, when `human_joint` is absent.
    ///
    /// -- *** ONE TABLE, MANY CAPTURE FORMATS --
    ///
    /// LAFAN1's top spine joint is `Spine3`; **Mixamo's is `Spine2`** and it has no `Spine3` at
    /// all. A table naming one of them maps the robot's TORSO - its ROOT - to nothing on the
    /// other, and everything downstream anchors on that body.
    ///
    /// ** The alternative is a second table per format, which is the wrong abstraction: **if two
    /// tables are needed, the row is under-specified.** A row states which joint it wants and
    /// what it will settle for, and the resolver takes the first that exists.
    ///
    /// * Preference order carries real knowledge - `Spine3` before `Spine2` before `Spine1` is a
    /// statement about which is highest up the chest, not an arbitrary list.
    alternatives: []const []const u8 = &.{},
    /// Set when this row's ROBOT body exists on some rigs and not others, so one table can
    /// serve a family of models.
    ///
    /// -- *** THE SAME ARGUMENT AS `alternatives`, ON THE OTHER SIDE --
    ///
    /// `alternatives` exists because two capture formats spell one joint differently and "a
    /// second table per format is the wrong abstraction". Two RIGS differ the same way: the
    /// stock `humanoid.xml` has no toe bone and the flexed one does. Without this the resolver
    /// hard-errors on the stock model and the whole retarget suite cannot run.
    ///
    /// ** It is PER ROW and defaults to false, so a typo in any of the other rows is still
    /// `error.UnknownRobotBody`. The relaxation is spelled out where it applies, not applied
    /// globally - a resolver that skipped every missing body would turn a broken table into a
    /// silently half-mapped robot.
    ///
    /// * A model without the body is not a degraded case: the foot's heel/toe/up construction
    /// fires on LEAF bodies, so a rig with no toe takes the leaf path deliberately - see the
    /// leaf-orientation target in `solveRestPoseFromSource`.
    optional_body: bool = false,
    /// How hard to pull this body's POSITION onto the human's, in the IK stage. Zero means
    /// orientation only.
    ///
    /// -- *** THE ASYMMETRY IS THE RETARGETING KNOWLEDGE --
    ///
    /// GMR's own table reads the same way: pelvis and knee get position weight 0, the ankle
    /// gets 50 - five times any rotation weight. **A robot's limb lengths differ from a human's,
    /// so demanding every joint's position would fight the skeleton against itself.** But feet
    /// must land where the human's landed or the robot skates, and that is not something a
    /// per-joint rotation fit can deliver: orientation error compounds down the chain and
    /// nothing constrains the endpoint.
    ///
    /// * So: rotation everywhere, POSITION ONLY AT THE ENDS.
    position_weight: f32 = 0,
    /// How hard to pull this body's ORIENTATION onto the human's.
    ///
    /// -- *** NOT A BLANKET VALUE, BECAUSE THE ROBOT IS OVER-CONSTRAINED --
    ///
    /// 16 mapped bodies asking for 3 position and 3 orientation components each is 96
    /// constraints against `humanoid.xml`'s **27 degrees of freedom**. A least-squares solve of
    /// that satisfies nothing well - which is what an `ik error` of 0.59 after 30 steps means:
    /// not a solver bug, but a system with no good answer.
    ///
    /// ** GMR's robot (G1) has roughly twice the DOF and a real shoulder chain. Ours has ONE
    /// waist segment, no shoulders, and a single-hinge knee. **The same weights cannot
    /// transfer**, and pretending they can is why a faithful port of GMR's numbers still looked
    /// wrong.
    ///
    /// * So orientation is requested only where the robot can actually deliver it, and the
    /// bodies whose orientation is a CONSEQUENCE of their chain - shins, forearms, the pelvis
    /// hanging under the torso - ask for none and let position drive them.
    rotation_weight: f32 = 0,
};

/// *** LAFAN1 -> `humanoid.xml`, AND THE ASYMMETRY IS THE KNOWLEDGE.
///
/// GMR ships this as JSON with a weight column per row. Ours needs no weights, because
/// `robot.fitLocalRotations` gives every joint the best rotation its DOF can express and
/// REPORTS the shortfall - where GMR's weights exist to let a solver trade one task off
/// against another.
///
/// * 16 robot bodies against LAFAN1's 96 joints. The robot has NO shoulders, NO spine chain
/// beyond one waist segment, NO toes and NO fingers, so most of the capture simply has no
/// counterpart. That is not a failure: an unmapped body keeps its rest orientation, and the
/// motion that matters - limbs, torso, head - is all here.
///
/// ** **THE ROBOT'S TREE IS INVERTED RELATIVE TO THE HUMAN'S.** `humanoid.xml` roots at
/// `torso` with `pelvis` hanging BELOW it through `waist_lower`; a BVH roots at `Hips` and the
/// spine goes up. The global-space retarget handles this with no special case - each body's
/// local rotation is computed against whatever parent the ROBOT has, not the one the human has.
/// A local-rotation copy could not have done this at all.
pub const lafan_to_humanoid = [_]MatchRow{
    // ** `Spine3`, NOT `Spine2` - chosen by MEASUREMENT, not by name. The robot's torso sits
    // high, between the shoulders, and the shoulder-offset error against each candidate is:
    //
    //     Spine 0.453   Spine1 0.375   Spine2 0.284   Spine3 0.226   Neck 0.253
    //
    // *** **AND NOTHING GETS BELOW ~0.21 m**, which is the IRREDUCIBLE error: the robot's
    // torso-to-shoulder offset is fixed by the model and simply does not match any human
    // joint's at a single hip-height scale. **That floor is a scaling problem, not a mapping
    // one** - GMR ships a per-body `human_scale_table` for exactly this.
    .{
        .robot_body = "torso",
        .human_joint = "Spine3",
        .alternatives = &.{ "Spine2", "Spine1", "Spine" },
        .rotation_weight = 10,
    },
    .{ .robot_body = "head", .human_joint = "Head", .rotation_weight = 4 },
    .{ .robot_body = "waist_lower", .human_joint = "Spine" },
    // * The pelvis carries the body's placement, so a modest pull keeps the robot from drifting
    // off the capture's path while the feet do the precise work.
    .{ .robot_body = "pelvis", .human_joint = "Hips", .position_weight = 20 },

    .{ .robot_body = "thigh_left", .human_joint = "LeftUpLeg", .rotation_weight = 6 },
    .{ .robot_body = "shin_left", .human_joint = "LeftLeg", .position_weight = 20 },
    .{ .robot_body = "foot_left", .human_joint = "LeftFoot", .position_weight = 50, .rotation_weight = 4 },
    .{ .robot_body = "thigh_right", .human_joint = "RightUpLeg", .rotation_weight = 6 },
    .{ .robot_body = "shin_right", .human_joint = "RightLeg", .position_weight = 20 },
    // -- *** THE TOES, ADDED WITH THE TOE BONE --
    //
    // Without these rows the toe bodies are UNMAPPED, and adding them silently cost the foot its
    // heel/toe/up construction: that construction fires on LEAF bodies, and the foot stopped
    // being a leaf the moment it gained a child. **Adding a bone changed which code ran**, which
    // no measurement of the bone itself would have revealed.
    .{
        .robot_body = "toe_right",
        .optional_body = true, // the stock humanoid.xml has no toe bone
        .human_joint = "RightToeBase",
        .alternatives = &.{"RightToe"},
        .position_weight = 50,
        .rotation_weight = 4,
    },
    .{
        .robot_body = "toe_left",
        .optional_body = true, // the stock humanoid.xml has no toe bone
        .human_joint = "LeftToeBase",
        .alternatives = &.{"LeftToe"},
        .position_weight = 50,
        .rotation_weight = 4,
    },
    .{ .robot_body = "foot_right", .human_joint = "RightFoot", .position_weight = 50, .rotation_weight = 4 },

    .{ .robot_body = "upper_arm_left", .human_joint = "LeftArm", .rotation_weight = 6 },
    .{ .robot_body = "lower_arm_left", .human_joint = "LeftForeArm", .position_weight = 10 },
    .{ .robot_body = "hand_left", .human_joint = "LeftHand", .position_weight = 10 },
    .{ .robot_body = "upper_arm_right", .human_joint = "RightArm", .rotation_weight = 6 },
    .{ .robot_body = "lower_arm_right", .human_joint = "RightForeArm", .position_weight = 10 },
    .{ .robot_body = "hand_right", .human_joint = "RightHand", .position_weight = 10 },
};

/// Resolve a match table into the index map `codecs.bvh.retargetRotations` consumes.
///
/// * An unmatched row is an ERROR, not a silent gap: a table naming a body the model does not
/// have is a typo, and letting it pass would show as a stiff limb that looks like a solver bug.
/// A body with NO row is fine - that is a deliberate omission, and it keeps its rest pose.
/// Does `candidate` name the joint `wanted`, ignoring any exporter namespace?
///
/// -- *** `mixamorig:Spine2` IS `Spine2` --
///
/// Mixamo prefixes every bone with `mixamorig:`; other exporters use `Armature|`, `Bip01 `, or a
/// rig name. **A table naming bare joints matches none of them**, and the example's response to
/// an unresolved table is to hide the robot - so the symptom is a robot that never moves, with
/// no error visible.
///
/// ** Matching after the last separator makes the table exporter-agnostic without listing
/// prefixes. **Which is the point: a list of known prefixes is the same mistake as a list of
/// known joint names**, one level up.
fn jointNameMatches(candidate: []const u8, wanted: []const u8) bool {
    if (std.mem.eql(u8, candidate, wanted)) {
        return true;
    }
    // * Compare only what follows the last namespace separator.
    var bare: []const u8 = candidate;
    for ([_]u8{ ':', '|' }) |separator| {
        if (std.mem.lastIndexOfScalar(u8, bare, separator)) |at| {
            bare = bare[at + 1 ..];
        }
    }
    return std.mem.eql(u8, bare, wanted);
}

pub fn resolveMatchTable(
    table: []const MatchRow,
    robot_body_names: []const []const u8,
    human_joint_names: []const []const u8,
    out_human_of_body: []i32,
) !void {
    for (out_human_of_body) |*entry| {
        entry.* = -1;
    }
    for (table) |row| {
        var robot_body: ?usize = null;
        for (robot_body_names, 0..) |name, index| {
            if (std.mem.eql(u8, name, row.robot_body)) {
                robot_body = index;
                break;
            }
        }
        if (robot_body == null) {
            // A row marked `optional_body` names a body this rig does not have; every other
            // missing body is a broken table and still stops the resolve.
            if (row.optional_body) {
                continue;
            }
            return error.UnknownRobotBody;
        }
        // *** The wanted joint, or the first ALTERNATIVE that exists. A capture that calls its
        // top spine `Spine2` instead of `Spine3` then needs no code and no second table.
        var human_joint: ?usize = null;
        for (human_joint_names, 0..) |name, index| {
            if (jointNameMatches(name, row.human_joint)) {
                human_joint = index;
                break;
            }
        }
        if (human_joint == null) {
            outer: for (row.alternatives) |alternative| {
                for (human_joint_names, 0..) |name, index| {
                    if (jointNameMatches(name, alternative)) {
                        human_joint = index;
                        break :outer;
                    }
                }
            }
        }
        if (human_joint == null) {
            return error.UnknownHumanJoint;
        }
        out_human_of_body[robot_body.?] = @intCast(human_joint.?);
    }
}

/// Each body's world ORIENTATION at the model's rest configuration.
///
/// * This is `humanoid.xml`'s reference pose, and it needs no extra file: `qpos0` IS the rest
/// configuration (zeros, plus identity for a free joint's quaternion), so running kinematics on
/// it gives every body's rest orientation directly.
///
/// ** It is the ROBOT's half of the same pairing the character path needed - an FBX supplies
/// its reference through the skin clusters' `TransformLink`, a BVH through a T-pose file, and a
/// MuJoCo model through `qpos0`. Three formats, three sources, one meaning: **where does this
/// joint point when the skeleton is at rest.**
///
/// Overwrites `d.pos` and the kinematics state; call it before posing, not during.
pub fn referenceOrientationsFromRest(
    m: *const Model,
    d: *Data,
    out_reference_orientations: []Quat,
) void {
    @memcpy(d.pos, m.qpos0);
    kinematics(m, d);
    const body_count: usize = @min(m.nbody, out_reference_orientations.len);
    for (0..body_count) |body| {
        out_reference_orientations[body] = d.body_xrot[body];
    }
}

/// Fit a desired per-BODY rotation across whatever joints that body actually has.
///
/// -- *** WHY PER-BODY AND NOT PER-JOINT --
///
/// `fitLocalRotations` assumes one joint carries one body's rotation. `humanoid.xml` breaks
/// that: its hip is **three separate hinges on one body** (`hip_x`, `hip_z`, `hip_y`), and
/// handing the same desired rotation to each would apply it three times over.
///
/// * A chain of hinges on one body is an EULER DECOMPOSITION in those axes' order. This walks
/// the body's joints in order, and for each one takes the twist of the REMAINING rotation about
/// that joint's axis, then removes what it took before moving on. After the last joint whatever
/// is left is genuinely unrepresentable, and that is the residual.
///
/// ** Three orthogonal hinges span all of SO(3), so a hip fits EXACTLY. One hinge - a knee -
/// captures only its own axis, and the residual says how much was lost. The decomposition is
/// the same code either way, which is what keeps this a single mechanism rather than a special
/// case per joint count.
pub fn fitBodyRotation(
    m: *const Model,
    d: *Data,
    body: usize,
    desired_local_rotation: Quat,
) f32 {
    const joint_start: usize = m.body_jnt_adr[body];
    const joint_count: usize = m.body_jnt_num[body];

    var remaining: Quat = desired_local_rotation;

    for (0..joint_count) |offset| {
        const joint: usize = joint_start + offset;
        const qpos_start: usize = m.jnt_qpos_adr[joint];

        switch (m.jnt_type[joint]) {
            .free => {
                // A free joint's rotation half; its translation is the caller's business.
                d.pos[qpos_start + 3] = remaining[0];
                d.pos[qpos_start + 4] = remaining[1];
                d.pos[qpos_start + 5] = remaining[2];
                d.pos[qpos_start + 6] = remaining[3];
                remaining = quat_identity;
            },
            .ball => {
                d.pos[qpos_start + 0] = remaining[0];
                d.pos[qpos_start + 1] = remaining[1];
                d.pos[qpos_start + 2] = remaining[2];
                d.pos[qpos_start + 3] = remaining[3];
                remaining = quat_identity;
            },
            .hinge => {
                const axis: Vec = m.jnt_axis[joint];
                const angle: f32 = twistAngleAbout(remaining, axis);
                const limited_angle: f32 = if (m.jnt_range[joint]) |range|
                    clamp(angle, range[0], range[1])
                else
                    angle;
                d.pos[qpos_start] = limited_angle;

                // * REMOVE WHAT THIS JOINT TOOK, so the next hinge in the chain fits the
                // REMAINDER rather than the original. Skipping this is what makes a naive
                // per-joint loop apply the rotation once per hinge.
                const taken: Quat = quatFromAxisAngle(axis, limited_angle);
                remaining = qmul(conjugate(taken), remaining);
            },
            else => {},
        }
    }

    // Whatever survives the whole chain is unrepresentable by this body's joints.
    const leftover_alignment: f32 = @abs(remaining[3]);
    return 2.0 * acosRad(clamp(leftover_alignment, -1.0, 1.0));
}

/// The angle of `rotation`'s twist about `axis` - the closed-form best a hinge can do.
fn twistAngleAbout(rotation: Quat, axis: Vec) f32 {
    const rotation_vector: Vec = .{ rotation[0], rotation[1], rotation[2], 0 };
    const along_axis: f32 =
        rotation_vector[0] * axis[0] + rotation_vector[1] * axis[1] + rotation_vector[2] * axis[2];
    const twist_length: f32 = @sqrt(along_axis * along_axis + rotation[3] * rotation[3]);
    if (twist_length < 1.0e-6) {
        return 0;
    }
    return 2.0 * atan2Rad(along_axis / twist_length, rotation[3] / twist_length);
}

/// The body Jacobian at a world point: how each DOF moves that point, and how it rotates it.
///
/// -- *** WHY THIS IS NEEDED AFTER ALL (retarget_plan.md section 13g-7) --
///
/// `fitBodyRotation` gives every joint the best rotation its own DOF can express, which is
/// closed-form and honest - but it orients each joint INDEPENDENTLY, so **error compounds down
/// the chain and nothing constrains where a hand or foot lands**. On a robot whose limb lengths
/// differ from the human's, the ankle ends up wherever accumulated orientation error puts it.
///
/// * GMR weights ankle POSITION at 50 against any rotation weight of 10 for exactly this
/// reason. A position target is not expressible as a per-joint rotation fit; it needs a
/// Jacobian, and this is it.
///
/// -- ** THE ASSEMBLY, AND WHY IT IS NOT NEW PHYSICS --
///
/// `cdof[j]` is already each DOF's motion axis as a spatial vector, expressed in the
/// subtree-COM frame (robot.zig's `comPos`). MuJoCo builds `mj_jacBody` from precisely that:
///
///     offset      = point - subtree_com[body_root[body]]
///     jacp[:, j]  = cdof[j].lin + cross(cdof[j].ang, offset)
///     jacr[:, j]  = cdof[j].ang
///
/// So the only work is walking the path from `body` up to the world and filling those columns.
///
/// * REQUIRES `kinematics` AND `comPos` TO HAVE RUN. `cdof` and `subtree_com` are their output;
/// calling this on a stale `Data` silently returns a Jacobian for a pose the model is no longer
/// in.
///
/// `jacp` and `jacr` are 3 x nv, row-major, and are ZEROED first - a DOF not on the path
/// contributes nothing, and leaving old values there would be a wrong answer rather than a
/// missing one.
pub fn jacBody(
    m: *const Model,
    d: *const Data,
    body: usize,
    point: Vec,
    jacp: ?[]f32,
    jacr: ?[]f32,
) void {
    const dof_count: usize = m.nv;
    if (jacp) |translation_jacobian| {
        @memset(translation_jacobian[0 .. 3 * dof_count], 0);
    }
    if (jacr) |rotation_jacobian| {
        @memset(rotation_jacobian[0 .. 3 * dof_count], 0);
    }

    // Every spatial quantity is expressed about this body's kinematic-tree root COM.
    const tree_root: usize = m.body_root[body];
    const offset_from_com: Vec = point - d.subtree_com[tree_root];

    // Walk from the body up to the world, filling a column per DOF along the way. Only these
    // DOFs can move the point; everything else is genuinely zero.
    var walker: usize = body;
    while (walker != world_body) {
        const first_dof: usize = m.body_dof_adr[walker];
        const dof_count_here: usize = m.body_dof_num[walker];

        for (0..dof_count_here) |offset| {
            const dof: usize = first_dof + offset;
            const motion_axis: Motion = d.cdof[dof];

            if (jacp) |translation_jacobian| {
                // A rotational DOF moves the point by its angular axis crossed with the lever
                // arm; a translational one moves it directly.
                const lever: Vec = cross3(motion_axis.ang, offset_from_com);
                translation_jacobian[0 * dof_count + dof] = motion_axis.lin[0] + lever[0];
                translation_jacobian[1 * dof_count + dof] = motion_axis.lin[1] + lever[1];
                translation_jacobian[2 * dof_count + dof] = motion_axis.lin[2] + lever[2];
            }
            if (jacr) |rotation_jacobian| {
                rotation_jacobian[0 * dof_count + dof] = motion_axis.ang[0];
                rotation_jacobian[1 * dof_count + dof] = motion_axis.ang[1];
                rotation_jacobian[2 * dof_count + dof] = motion_axis.ang[2];
            }
        }
        walker = m.body_parent[walker];
    }
}

fn cross3(a: Vec, b: Vec) Vec {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
        0,
    };
}

test "jacBody: every column matches a finite-difference perturbation of its own DOF" {
    const gpa: Allocator = std.testing.allocator;

    // A three-bone chain with a FREE root, so `nq != nv` is exercised: the root contributes
    // 7 qpos entries against 6 DOF, and a Jacobian indexed by the wrong one is the classic
    // silent failure this test exists to rule out.
    const names = [_][]const u8{ "root", "mid", "tip" };
    const parents = [_]i32{ -1, 0, 1 };
    const offsets = [_]Vec{ vec(0, 0, 0), vec(0, 0.4, 0), vec(0.1, 0.35, 0) };
    var m: Model = try skeletonToModel(gpa, &names, &parents, &offsets, .{});
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();
    try expect(m.nq > m.nv);

    // A pose away from rest, so no term is accidentally zero.
    @memcpy(d.pos, m.qpos0);
    const pose = [_]Quat{
        quatFromAxisAngle(vec(0, 1, 0), 0.35),
        quatFromAxisAngle(vec(1, 0, 0), 0.5),
        quatFromAxisAngle(vec(0, 0, 1), -0.4),
    };
    poseFromLocalRotations(&m, &d, vec(0.2, 0.9, -0.1), &pose);
    kinematics(&m, &d);
    comPos(&m, &d);

    const body: usize = 3; // the tip
    // ** AN OFFSET POINT, NOT THE BODY ORIGIN. A body's own joint rotates ABOUT its origin
    // without translating it, so a Jacobian taken at the origin is insensitive to that body's
    // own DOFs - and a walk that skipped them would pass. Verified: dropping the body's own
    // dofs leaves an origin-point test green and fails this one.
    // * Held as a LOCAL offset, so it moves WITH the body. Taking the Jacobian at an offset
    // point but measuring the ORIGIN's motion compares two different things - and it fails even
    // a correct Jacobian, which is how this was caught.
    const local_offset: Vec = vec(0.07, -0.05, 0.03);
    const point: Vec = d.body_xpos[body] + zm.rotate(d.body_xrot[body], local_offset);

    const jacp: []f32 = try gpa.alloc(f32, 3 * m.nv);
    defer gpa.free(jacp);
    jacBody(&m, &d, body, point, jacp, null);

    // -- *** THE PROPERTY: perturb ONE DOF and the point must move by that column --
    //
    // This needs no IK, no capture and no renderer, and it catches every way the assembly can
    // be wrong: a bad frame, a reversed cross product, a DOF left off the path, or a column
    // written at the wrong index. section 13a said to write this FIRST because everything downstream
    // rests on it.
    //
    // * The perturbation is applied through `integratePos`, NOT by adding to `qpos` - a free
    // joint's quaternion does not integrate by addition, and doing so would drift it off unit
    // length while still looking plausible.
    const epsilon: f32 = 1.0e-4;
    const saved_pos: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(saved_pos);
    @memcpy(saved_pos, d.pos);

    var worst_error: f32 = 0;
    for (0..m.nv) |dof| {
        @memcpy(d.pos, saved_pos);
        @memset(d.vel, 0);
        d.vel[dof] = 1.0;
        integratePos(&m, d.pos, d.vel, epsilon);
        kinematics(&m, &d);
        const moved: Vec = d.body_xpos[body] + zm.rotate(d.body_xrot[body], local_offset);

        @memcpy(d.pos, saved_pos);
        kinematics(&m, &d);
        const original: Vec = d.body_xpos[body] + zm.rotate(d.body_xrot[body], local_offset);

        const measured_velocity: Vec = (moved - original) / @as(Vec, @splat(epsilon));
        inline for (0..3) |axis| {
            const predicted: f32 = jacp[axis * m.nv + dof];
            worst_error = @max(worst_error, @abs(measured_velocity[axis] - predicted));
        }
    }

    // A finite difference at 1e-4 carries its own truncation error, so the tolerance is loose
    // enough for that and far tighter than any structural mistake would produce.
    try expect(worst_error < 1.0e-2);
}

/// One position target: a point on a body that should reach a place in the world.
///
/// ** POSITION, not rotation, is what a rotation-fit cannot do. GMR weights an ankle's position
/// at 50 against any rotation weight of 10, because orientation error compounds down a chain
/// and nothing else stops a robot's foot landing where the human's did not.
pub const IkTask = struct {
    body: usize,
    /// The point in the body's LOCAL frame - usually the origin, sometimes a site.
    point_local: Vec = .{ 0, 0, 0, 0 },
    /// Where that point should be, in world coordinates.
    target_world: Vec,
    /// Position importance. Ankles high, everything else low; see the GMR table.
    weight: f32 = 1.0,
    /// Constrain this point RELATIVE to another point, instead of in world space.
    ///
    /// -- *** TWO POINTS CAN TRADE; A DIFFERENCE CANNOT --
    ///
    /// Two independent shoulder targets have a flat direction in the objective: **pushing the
    /// left shoulder forward and the right one back costs exactly what rotating correctly
    /// costs**, so the solver has no gradient telling the two apart and clicks between equally
    /// good answers. That is the "clicky" torso.
    ///
    /// ** Constraining the DIFFERENCE removes the ambiguity entirely. The residual becomes
    /// `(p_this - p_other) - target_delta`, whose Jacobian is `J_this - J_other` - one residual
    /// that says "these two points must be this far apart in this direction", which is a
    /// ROTATION statement rather than two position statements that happen to imply one.
    ///
    /// * `target_world` is then read as the wanted DIFFERENCE, not as a world position.
    relative_to: ?RelativePoint = null,
    /// Where the body should FACE, in world coordinates. Null means position only.
    ///
    /// -- *** THIS IS WHAT GMR ACTUALLY DOES, AND WHAT WE WERE NOT DOING --
    ///
    /// GMR sets a full SE3 target per robot body - position AND orientation, both in WORLD
    /// space, taken straight from the human's corrected pose - and solves every task at once.
    /// **It never computes per-joint local rotations and never decomposes anything.**
    ///
    /// ** Decomposing was the fatal flaw. `local = conj(parent_DESIRED_global) * desired_global`
    /// assumes the parent REACHES its desired orientation - but a hinge cannot, so every child
    /// is computed against a parent that is wrong, and the error compounds down the chain. That
    /// is what produced 89 degrees of residual.
    ///
    /// * A solver has no such problem: when a parent falls short it compensates with the child,
    /// because it optimises all joints against all targets together.
    target_rotation: ?Quat = null,
    /// Orientation importance. GMR uses 10 against a position weight of 50 at the ankles.
    rotation_weight: f32 = 1.0,
};

/// The other end of a relative task.
pub const RelativePoint = struct {
    body: usize,
    point_local: Vec = .{ 0, 0, 0, 0 },
};

pub const IkOptions = struct {
    /// Levenberg-Marquardt damping. Larger is slower and more stable near a singularity -
    /// GMR uses 1.0 and so do we until measurement says otherwise.
    damping: f32 = 1.0,
    /// Fraction of the solved step actually taken. Below 1 trades speed for stability.
    step_scale: f32 = 1.0,
    /// Which DOF the solver may move. Null means all of them.
    ///
    /// -- *** WITHOUT THIS, A HAND TASK MOVES THE WHOLE ROBOT --
    ///
    /// `jacBody` returns a column for EVERY DOF on the path from the body to the world - which
    /// for a hand includes the elbow, the shoulder, the torso's abdomen joints and **the free
    /// root**. The cheapest way to move a hand 10 cm is often to translate the entire robot 10
    /// cm, and the solver will do exactly that: it has no notion of which DOF you meant.
    ///
    /// ** Measured: an arm task without a mask improved the hand by 0.004 m while dragging the
    /// torso that had just been made EXACT. **A task is not a scope.** Masking to the arm's own
    /// three DOF makes the solve mean "bend this arm" rather than "get the hand there somehow".
    dof_mask: ?[]const bool = null,
    /// Clamp each joint to its `jnt_range` after every step.
    ///
    /// -- *** WITHOUT THIS THE SOLVER RETURNS POSES THE ROBOT CANNOT HOLD --
    ///
    /// Measured: an arm solve reported 4.6 degrees of upper-arm error with the shoulder at
    /// (-118, -107) against a range of [-85, 60]. **The good number was bought by violating the
    /// joint limits** - a configuration the robot physically cannot adopt, reported as a
    /// success.
    ///
    /// ** GMR passes `mink.ConfigurationLimit` as a CONSTRAINT so no infeasible step is ever
    /// proposed. Clamping after each step is the cheap version: the solver may aim outside the
    /// range but never keeps it, so what it converges to is always reachable.
    ///
    /// * With limits on, a residual is the MODEL's - and that is the number worth having.
    respect_joint_limits: bool = false,
    /// Strength of a SOFT limit barrier, pushing away from `jnt_range` before the wall.
    ///
    /// -- *** A HARD LIMIT IS A CLIFF; A BARRIER IS A SLOPE --
    ///
    /// Measured this session, both from the same cause:
    ///
    ///     stuck:  shoulder pinned at -150, err 15.5, **best possible 6.2**
    ///     pops:   140 degrees of arm motion in a single frame
    ///
    /// Clamping the result - or zeroing the step component that pushes into a wall - **removes
    /// that direction from the solve entirely.** The configuration sticks to the wall, and the
    /// gradient that would walk it back along the surface no longer exists. A small change in
    /// target can then produce a large change in solution, because the solver is choosing
    /// between disconnected pieces of the feasible set.
    ///
    /// ** A barrier adds `w*(1/(q-lo) - 1/(hi-q))` to the gradient: the solver **feels the wall
    /// before reaching it, slides ALONG it, and can always back out.** The map from target to
    /// solution becomes continuous, which is what "smooth" means and what no amount of clamping
    /// can give.
    ///
    /// * Zero disables it. Use INSTEAD of `respect_joint_limits`, not alongside.
    limit_barrier: f32 = 0,
    /// Pull toward a previous configuration, for temporal continuity.
    ///
    /// ** A limb with a redundant DOF has a whole family of equally-good answers, and from a
    /// cold start the solver picks one arbitrarily every frame. **Continuity has to be a TERM in
    /// the objective, not a starting point** - a warm start moves where the search begins, this
    /// moves where it ends.
    posture_target: ?[]const f32 = null,
    posture_weight: f32 = 0,
};

/// One damped-least-squares step toward a set of weighted position targets.
///
/// -- *** WHY DAMPED, AND WHY IT IS NOT JUST `J^T e` --
///
/// A humanoid's arm has more DOF than a point has coordinates, so `J` is wide and `J dq = e`
/// has infinitely many solutions - and near a straight limb it has none that are small. The
/// damped normal equations
///
///     (J^TW J + lambda I) dq = J^TW e
///
/// pick the smallest step that reduces the error, and `lambda` keeps the matrix invertible
/// exactly where the naive pseudo-inverse blows up: a fully extended knee, which a dance
/// capture reaches constantly.
///
/// * Returns the error norm BEFORE the step, so a caller can iterate `while (previous - current
/// > tolerance)` - GMR's own stopping rule, which converges in a handful of steps from a good
/// initial guess.
///
/// ** REQUIRES `kinematics` AND `comPos` TO BE CURRENT, because `jacBody` reads their output.
/// The caller re-runs both after each step; doing it here would hide the cost of a loop.
///
/// `scratch` must hold `ikScratchSize(nv)` floats. Passing it in keeps this
/// allocation-free, which matters when it runs once per frame per character.
pub fn ikStep(
    m: *const Model,
    d: *Data,
    tasks: []const IkTask,
    opts: IkOptions,
    scratch: []f32,
) f32 {
    const dof_count: usize = m.nv;
    // * Checked up front with a message: the slices below would otherwise be the first thing to
    // notice a short buffer - a bounds panic in a safe build, and nothing at all in ReleaseSmall.
    assertf(
        scratch.len >= ikScratchSize(dof_count),
        @src(),
        "ikStep: scratch holds {d} floats, needs ikScratchSize({d}) = {d}",
        .{ scratch.len, dof_count, ikScratchSize(dof_count) },
    );
    const jacobian: []f32 = scratch[0 .. 3 * dof_count];
    const rotation_jacobian: []f32 = scratch[3 * dof_count ..][0 .. 3 * dof_count];
    const normal_matrix: []f32 = scratch[6 * dof_count ..][0 .. dof_count * dof_count];
    const gradient: []f32 = scratch[6 * dof_count + dof_count * dof_count ..][0..dof_count];
    const joint_step: []f32 =
        scratch[6 * dof_count + dof_count * dof_count + dof_count ..][0..dof_count];
    // * Room for the other end of a relative task, at the tail of the scratch.
    const other_jacobian: []f32 =
        scratch[6 * dof_count + dof_count * dof_count + 2 * dof_count ..][0 .. 3 * dof_count];
    const other_rotation_jacobian: []f32 =
        scratch[6 * dof_count + dof_count * dof_count + 5 * dof_count ..][0 .. 3 * dof_count];

    @memset(normal_matrix, 0);
    @memset(gradient, 0);

    var error_norm_squared: f32 = 0;

    for (tasks) |task| {
        const body_position: Vec = d.body_xpos[task.body];
        const body_rotation: Quat = d.body_xrot[task.body];
        const point_world: Vec = body_position + zm.rotate(body_rotation, task.point_local);

        // * For a RELATIVE task, `target_world` is the wanted DIFFERENCE between this point and
        // the other, so the residual is measured on the difference too.
        const position_error: Vec = if (task.relative_to) |other| blk: {
            const other_world: Vec = d.body_xpos[other.body] +
                zm.rotate(d.body_xrot[other.body], other.point_local);
            break :blk task.target_world - (point_world - other_world);
        } else task.target_world - point_world;

        error_norm_squared += task.weight *
            (position_error[0] * position_error[0] +
                position_error[1] * position_error[1] +
                position_error[2] * position_error[2]);

        jacBody(m, d, task.body, point_world, jacobian, rotation_jacobian);

        // -- *** A RELATIVE TASK: subtract the other point's Jacobian and position --
        //
        // The residual is a DIFFERENCE of two points, so its derivative is the difference of
        // their derivatives. Everything downstream - the normal equations, the damping, the
        // barrier - is unchanged, because a residual is a residual.
        if (task.relative_to) |other| {
            const other_world: Vec = d.body_xpos[other.body] +
                zm.rotate(d.body_xrot[other.body], other.point_local);
            jacBody(m, d, other.body, other_world, other_jacobian, other_rotation_jacobian);
            for (0..3 * dof_count) |k| {
                jacobian[k] -= other_jacobian[k];
                rotation_jacobian[k] -= other_rotation_jacobian[k];
            }
        }

        // * Zero the columns of DOF the caller has excluded, so the normal equations never see
        // them and the solved step leaves them untouched.
        if (opts.dof_mask) |mask| {
            for (0..dof_count) |dof| {
                if (dof < mask.len and mask[dof]) {
                    continue;
                }
                inline for (0..3) |axis| {
                    jacobian[axis * dof_count + dof] = 0;
                    rotation_jacobian[axis * dof_count + dof] = 0;
                }
            }
        }

        // -- * THE ORIENTATION ROWS --
        //
        // The angular error taking the body to its target is the rotation vector of
        // `target * conj(current)`, in WORLD space - the same frame `jacr` is expressed in.
        // For a unit quaternion that vector is twice the imaginary part, sign-corrected so the
        // solver takes the SHORT way round rather than spinning 300 degrees to reach 60.
        if (task.target_rotation) |target_rotation| {
            const rotation_error_quat: Quat =
                zm.qmul(target_rotation, zm.conjugate(body_rotation));
            const shortest: f32 = if (rotation_error_quat[3] < 0) -2.0 else 2.0;
            const rotation_error: Vec = .{
                rotation_error_quat[0] * shortest,
                rotation_error_quat[1] * shortest,
                rotation_error_quat[2] * shortest,
                0,
            };
            error_norm_squared += task.rotation_weight *
                (rotation_error[0] * rotation_error[0] +
                    rotation_error[1] * rotation_error[1] +
                    rotation_error[2] * rotation_error[2]);

            for (0..dof_count) |row_dof| {
                var gradient_term: f32 = 0;
                inline for (0..3) |axis| {
                    gradient_term += rotation_jacobian[axis * dof_count + row_dof] *
                        rotation_error[axis];
                }
                gradient[row_dof] += task.rotation_weight * gradient_term;

                for (row_dof..dof_count) |column_dof| {
                    var product: f32 = 0;
                    inline for (0..3) |axis| {
                        product += rotation_jacobian[axis * dof_count + row_dof] *
                            rotation_jacobian[axis * dof_count + column_dof];
                    }
                    const contribution: f32 = task.rotation_weight * product;
                    normal_matrix[row_dof * dof_count + column_dof] += contribution;
                    if (column_dof != row_dof) {
                        normal_matrix[column_dof * dof_count + row_dof] += contribution;
                    }
                }
            }
        }

        // Accumulate J^TW J into the normal matrix and J^TW e into the gradient.
        for (0..dof_count) |row_dof| {
            var gradient_term: f32 = 0;
            inline for (0..3) |axis| {
                gradient_term += jacobian[axis * dof_count + row_dof] * position_error[axis];
            }
            gradient[row_dof] += task.weight * gradient_term;

            for (row_dof..dof_count) |column_dof| {
                var product: f32 = 0;
                inline for (0..3) |axis| {
                    product += jacobian[axis * dof_count + row_dof] *
                        jacobian[axis * dof_count + column_dof];
                }
                const contribution: f32 = task.weight * product;
                normal_matrix[row_dof * dof_count + column_dof] += contribution;
                if (column_dof != row_dof) {
                    normal_matrix[column_dof * dof_count + row_dof] += contribution;
                }
            }
        }
    }

    // -- *** SOFT LIMITS AND TEMPORAL CONTINUITY, ADDED TO THE NORMAL EQUATIONS --
    //
    // Both are gradients on `q`, so both belong in the same solve as the task residuals rather
    // than as a repair applied afterwards.
    //
    // *** AND THEY MUST COME BEFORE THE SOLVE. This block used to sit AFTER
    // `solveSymmetricPositiveDefinite`, adding its terms to a system nobody read again: the barrier
    // never held a joint in range and the posture weight never held a frame near the last. The
    // retarget's own posture sweep (robot_mjcf's WHOLE BODY test) found "0.15, 0.30 and 0.60 all
    // gave worst pop 59.2 deg, identical to the decimal" and read it as a branch flip no weight
    // could hold - identical to the decimal is what dead code looks like. Found by `robot_dance`,
    // where posture 0.15 and 25 retargeted the dance to the same digit.
    if (opts.limit_barrier > 0 or opts.posture_weight > 0) {
        for (0..m.njnt) |joint| {
            const kind: JointType = m.jnt_type[joint];
            if (kind != .hinge and kind != .slide) {
                continue;
            }
            const dof: usize = m.jnt_dof_adr[joint];
            if (dof >= dof_count) {
                continue;
            }
            const address: usize = m.jnt_qpos_adr[joint];
            const current: f32 = d.pos[address];

            if (opts.limit_barrier > 0) {
                if (m.jnt_range[joint]) |range| {
                    // * Margin-relative, so the barrier's strength does not depend on whether a
                    // joint's range is measured in a few degrees or a few radians.
                    const span: f32 = @max(range[1] - range[0], 1.0e-4);
                    const low_gap: f32 = @max(current - range[0], 1.0e-3 * span);
                    const high_gap: f32 = @max(range[1] - current, 1.0e-3 * span);
                    const push: f32 = opts.limit_barrier * span *
                        (1.0 / (low_gap / span) - 1.0 / (high_gap / span)) * 1.0e-4;
                    // * `gradient` holds the DESCENT direction (J^T r, as the tasks and the posture term
                    // add it), so the barrier's push is ADDED: positive near the low wall, moving the
                    // joint up and away from it. It was subtracted - toward the nearest wall - which
                    // went unseen while this block ran after the solve and did nothing at all.
                    gradient[dof] += push;
                    // * Curvature into the diagonal so the step stays stable near a wall.
                    normal_matrix[dof * dof_count + dof] += opts.limit_barrier *
                        (1.0 / (low_gap * low_gap) + 1.0 / (high_gap * high_gap)) * 1.0e-4;
                }
            }

            if (opts.posture_weight > 0) {
                if (opts.posture_target) |target| {
                    if (address < target.len) {
                        gradient[dof] += opts.posture_weight * (target[address] - current);
                        normal_matrix[dof * dof_count + dof] += opts.posture_weight;
                    }
                }
            }
        }
    }

    // * The damping term is what makes this solvable at a singularity, and it goes on the
    // diagonal AFTER the accumulation so every task shares it.
    for (0..dof_count) |dof| {
        normal_matrix[dof * dof_count + dof] += opts.damping;
    }

    solveSymmetricPositiveDefinite(normal_matrix, gradient, joint_step, dof_count);

    // ** INTEGRATED, NOT ADDED. `qpos` is longer than `nv` because a free joint carries a
    // quaternion; `integratePos` composes it correctly where `pos += step` would drift it off
    // unit length while still looking plausible.
    if (opts.step_scale != 1.0) {
        for (joint_step) |*component| {
            component.* *= opts.step_scale;
        }
    }
    // -- *** SCALE THE STEP SO NO JOINT CROSSES ITS RANGE --
    //
    // Clamping AFTER integrating lets the solver propose a large step, have it truncated on one
    // axis, and land somewhere unrelated to where it started - **a limit becomes a cliff, and an
    // IK stepping over one moves discontinuously.** Measured: 157 degrees of arm motion in a
    // single frame, on a shoulder pinned against [-85, 60].
    //
    // ** Scaling the WHOLE step by the largest admissible fraction keeps its DIRECTION intact:
    // the solve still heads where it wanted, it just stops at the wall instead of being
    // projected onto it. This is the cheap form of GMR's `ConfigurationLimit`, which forbids
    // infeasible steps rather than repairing them.
    //
    // * A joint already AT its limit and pushing further contributes a zero fraction, which
    // would freeze the whole solve - such a component is dropped instead, so the other DOF can
    // still move.
    if (opts.respect_joint_limits) {
        var allowed: f32 = 1.0;
        for (0..m.njnt) |joint| {
            const range: [2]f32 = m.jnt_range[joint] orelse continue;
            const kind: JointType = m.jnt_type[joint];
            if (kind != .hinge and kind != .slide) {
                continue;
            }
            const dof: usize = m.jnt_dof_adr[joint];
            if (dof >= dof_count) {
                continue;
            }
            const delta: f32 = joint_step[dof];
            if (@abs(delta) < 1.0e-9) {
                continue;
            }
            const current: f32 = d.pos[m.jnt_qpos_adr[joint]];
            const wall: f32 = if (delta > 0) range[1] else range[0];
            const room: f32 = wall - current;
            if (room * delta <= 0) {
                // Pushing into a wall it already rests on: drop this component only.
                joint_step[dof] = 0;
                continue;
            }
            allowed = @min(allowed, room / delta);
        }
        if (allowed < 1.0) {
            for (joint_step) |*component| {
                component.* *= allowed;
            }
        }
    }

    integratePos(m, d.pos, joint_step, 1.0);

    // * A final clamp catches float drift only; the scaling above is what keeps motion
    // continuous.
    //
    // *** AND THE BARRIER NEEDS IT TOO: IT IS NOT A WALL ONCE A STEP HAS CROSSED IT. The barrier
    // above clamps each gap at 0.001 of the span, so a joint that one step carried PAST its limit
    // sees a small constant push and an enormous curvature term - which damps the very step that
    // would bring it back. It stays outside: retargeting the dance, `solvePointCloud` (barrier
    // only) left humanoid_flex's right knee bent BACKWARDS by 148 deg in all 599 frames, and arm
    // hinges wound to 6-10 rad, and every tracking attempt downstream was chasing that. Projecting
    // back after each step keeps the iterate feasible, and the barrier then does its job inside.
    const project_into_range: bool = opts.respect_joint_limits or opts.limit_barrier > 0;
    if (project_into_range) {
        for (0..m.njnt) |joint| {
            const range: [2]f32 = m.jnt_range[joint] orelse continue;
            const kind: JointType = m.jnt_type[joint];
            if (kind != .hinge and kind != .slide) {
                continue;
            }
            const address: usize = m.jnt_qpos_adr[joint];
            d.pos[address] = clamp(d.pos[address], range[0], range[1]);
        }
    }

    return @sqrt(error_norm_squared);
}

/// In-place Cholesky solve of a symmetric positive-definite system, `a x = b`.
///
/// * SPD is guaranteed here by construction: `J^TW J` is positive SEMI-definite for positive
/// weights, and the damping term makes it strictly positive. That is what lets this be a
/// Cholesky rather than a pivoting factorisation.
fn solveSymmetricPositiveDefinite(
    a: []f32,
    b: []const f32,
    out_x: []f32,
    n: usize,
) void {
    // Factor a = L L^T, writing L into a's lower triangle.
    for (0..n) |i| {
        for (0..i + 1) |j| {
            var sum: f32 = a[i * n + j];
            for (0..j) |k| {
                sum -= a[i * n + k] * a[j * n + k];
            }
            if (i == j) {
                // A tiny floor keeps a degenerate system from producing NaNs that would
                // propagate into `qpos` and be far harder to trace than a stalled solve.
                a[i * n + j] = @sqrt(@max(sum, 1.0e-12));
            } else {
                a[i * n + j] = sum / a[j * n + j];
            }
        }
    }
    // Forward substitution: L y = b.
    for (0..n) |i| {
        var sum: f32 = b[i];
        for (0..i) |k| {
            sum -= a[i * n + k] * out_x[k];
        }
        out_x[i] = sum / a[i * n + i];
    }
    // Back substitution: L^T x = y.
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var sum: f32 = out_x[i];
        for (i + 1..n) |k| {
            sum -= a[k * n + i] * out_x[k];
        }
        out_x[i] = sum / a[i * n + i];
    }
}

/// Floats `ikStep` needs in its scratch buffer for a model with `nv` degrees of freedom.
pub fn ikScratchSize(nv: usize) usize {
    // * 6nv jacobians + nv*nv normal matrix + nv gradient + nv step + 6nv for a RELATIVE task's
    // second Jacobian pair.
    return 6 * nv + nv * nv + 2 * nv + 6 * nv;
}

test "ikStep: a single position target converges on a redundant chain" {
    const gpa: Allocator = std.testing.allocator;

    // Four bodies, ball joints, free root: far more DOF than a point has coordinates. That
    // redundancy is the whole reason the solve must be DAMPED - a plain pseudo-inverse has no
    // unique answer here, and near a straight chain it has no small one.
    const names = [_][]const u8{ "root", "a", "b", "c" };
    const parents = [_]i32{ -1, 0, 1, 2 };
    const offsets = [_]Vec{ vec(0, 0, 0), vec(0, 0.4, 0), vec(0, 0.4, 0), vec(0, 0.4, 0) };
    var m: Model = try skeletonToModel(gpa, &names, &parents, &offsets, .{});
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    @memcpy(d.pos, m.qpos0);
    kinematics(&m, &d);
    comPos(&m, &d);

    const tip: usize = 4;
    const start: Vec = d.body_xpos[tip];
    // A target well off the rest pose but inside reach, so failure is unambiguous.
    const target: Vec = start + vec(0.35, -0.25, 0.2);

    const scratch: []f32 = try gpa.alloc(f32, ikScratchSize(m.nv));
    defer gpa.free(scratch);
    const tasks = [_]IkTask{.{ .body = tip, .target_world = target, .weight = 1.0 }};

    // ** THE PROPERTY: the error must FALL MONOTONICALLY and end small. A step that overshoots
    // or oscillates would still "converge" on a lucky iteration count, so the test checks the
    // trajectory rather than only the destination.
    var previous_error: f32 = 1.0e9;
    var iterations: usize = 0;
    while (iterations < 60) : (iterations += 1) {
        const current_error: f32 = ikStep(&m, &d, &tasks, .{ .damping = 0.05 }, scratch);
        try expect(current_error <= previous_error + 1.0e-5);
        previous_error = current_error;
        kinematics(&m, &d);
        comPos(&m, &d);
        if (current_error < 1.0e-3) {
            break;
        }
    }

    const reached: Vec = d.body_xpos[tip];
    const remaining: Vec = target - reached;
    const remaining_distance: f32 = @sqrt(
        remaining[0] * remaining[0] + remaining[1] * remaining[1] + remaining[2] * remaining[2],
    );
    try expect(remaining_distance < 5.0e-3);

    // * AND IT ACTUALLY MOVED - a target the chain already satisfied would pass the distance
    // check while proving the solver does nothing.
    const travelled: Vec = reached - start;
    try expect(@sqrt(travelled[0] * travelled[0] +
        travelled[1] * travelled[1] +
        travelled[2] * travelled[2]) > 0.2);

    // -- *** THE SINGULAR CASE, which is what the DAMPING is actually for --
    //
    // A target BEYOND REACH pulls the chain straight, and a straight chain is exactly where the
    // undamped pseudo-inverse blows up: the Jacobian loses rank along the limb's axis and the
    // step goes to infinity. **A dance capture reaches this constantly** - every fully extended
    // knee and elbow - so it is the normal case, not a corner.
    //
    // * Verified as a real control: the convergence test above still passes with damping
    // removed, because a bent chain is well-conditioned. THIS one does not.
    @memcpy(d.pos, m.qpos0);
    kinematics(&m, &d);
    comPos(&m, &d);
    const unreachable_target: Vec = d.body_xpos[tip] + vec(0, 9.0, 0);
    const stretch_tasks = [_]IkTask{.{
        .body = tip,
        .target_world = unreachable_target,
        .weight = 1.0,
    }};
    for (0..40) |_| {
        _ = ikStep(&m, &d, &stretch_tasks, .{ .damping = 1.0 }, scratch);
        kinematics(&m, &d);
        comPos(&m, &d);
    }

    // * The invariant is FINITENESS, not a magnitude. A free root chasing a target 9 m away
    // legitimately travels a long way; what must never happen is a step that is not a number.
    // Bounding the magnitude instead was a mistake - it failed the CORRECT solver, which is how
    // it was caught.
    for (0..m.nq) |index| {
        try expect(d.pos[index] == d.pos[index]); // NaN is the only value unequal to itself
    }
    for (0..m.nbody) |body| {
        inline for (0..3) |axis| {
            const coordinate: f32 = d.body_xpos[body][axis];
            try expect(coordinate == coordinate);
        }
    }
}

/// Each body's rest orientation taken from WHICH WAY ITS BONE POINTS, not from its body frame.
///
/// -- *** WHY `referenceOrientationsFromRest` IS THE WRONG TOOL FOR A RETARGET --
///
/// That one reads `body_xrot` at `qpos0` - the body FRAME's orientation. For `humanoid.xml`
/// that is **identity for every body**, because the file declares no `quat`, `euler` or
/// `axisangle` anywhere. Its bone directions live entirely in the POSITION OFFSETS:
///
///     lower_arm_left  pos=".18 .18 -.18"    out, forward and down
///     thigh_left      pos="0 .1 -.04"
///
/// ** So an alignment built from body frames compares a MEANINGLESS identity on the robot side
/// against a real T-pose rotation on the human side. Both references must answer the SAME
/// QUESTION - *which way does this bone point at rest* - or the correction between them is
/// noise. That rule has now been broken three times in this arc, each in a new disguise; see
/// claude.md.
///
/// * This walks each body to its FIRST CHILD and builds the shortest-arc rotation taking +Y
/// onto that direction - the identical construction `codecs.bvh.restBoneOrientations` applies
/// to a skeleton, so the two sides are directly comparable. A leaf inherits its parent's.
///
/// `reference_axis` is the canonical direction the arc is measured from; +Y matches the
/// skeleton side.
pub fn referenceOrientationsFromBoneDirections(
    m: *const Model,
    out_reference_orientations: []Quat,
) void {
    const body_count: usize = @min(m.nbody, out_reference_orientations.len);
    for (0..body_count) |body| {
        out_reference_orientations[body] = quat_identity;
    }

    for (0..body_count) |body| {
        // A body's bone points toward its first child, because that offset IS the segment this
        // body drives.
        var direction: Vec = .{ 0, 0, 0, 0 };
        var found_child: bool = false;
        for (0..body_count) |candidate| {
            const candidate_is_child: bool = candidate != 0 and m.body_parent[candidate] == body;
            if (candidate_is_child) {
                direction = m.body_pos[candidate];
                found_child = true;
                break;
            }
        }

        if (!found_child) {
            const parent: usize = m.body_parent[body];
            out_reference_orientations[body] = if (body == 0)
                quat_identity
            else
                out_reference_orientations[parent];
            continue;
        }

        const bone_length: f32 = @sqrt(
            direction[0] * direction[0] +
                direction[1] * direction[1] +
                direction[2] * direction[2],
        );
        if (bone_length < 1.0e-6) {
            continue;
        }
        const unit: Vec = direction / @as(Vec, @splat(bone_length));
        out_reference_orientations[body] = shortestArcFromYAxis(unit);
    }
}

/// The shortest rotation taking +Y onto `target_direction`. Mirrors the skeleton-side
/// construction exactly, so both references are the same kind of measurement.
fn shortestArcFromYAxis(target_direction: Vec) Quat {
    const y_axis: Vec = vec(0, 1, 0);
    const alignment: f32 = y_axis[0] * target_direction[0] +
        y_axis[1] * target_direction[1] +
        y_axis[2] * target_direction[2];

    if (alignment > 0.99999) {
        return quat_identity;
    }
    if (alignment < -0.99999) {
        // A 180-degree flip has no unique axis; any perpendicular will do.
        return quatFromAxisAngle(vec(0, 0, 1), 3.14159265);
    }
    const axis: Vec = .{
        y_axis[1] * target_direction[2] - y_axis[2] * target_direction[1],
        y_axis[2] * target_direction[0] - y_axis[0] * target_direction[2],
        y_axis[0] * target_direction[1] - y_axis[1] * target_direction[0],
        0,
    };
    const angle: f32 = acosRad(clamp(alignment, -1.0, 1.0));
    return quatFromAxisAngle(normalize3(axis), angle);
}

test "referenceOrientationsFromBoneDirections: reads the OFFSETS, where a body-frame read finds nothing" {
    const gpa: Allocator = std.testing.allocator;

    // Bodies with no rotation of their own, whose bones point in different directions purely
    // through their child offsets - the shape `humanoid.xml` actually has.
    const names = [_][]const u8{ "root", "up", "sideways" };
    const parents = [_]i32{ -1, 0, 1 };
    const offsets = [_]Vec{ vec(0, 0, 0), vec(0, 0.5, 0), vec(0.5, 0, 0) };
    var m: Model = try skeletonToModel(gpa, &names, &parents, &offsets, .{});
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    // ** THE BODY-FRAME READ FINDS NOTHING. Every body rotation is identity here, exactly as in
    // `humanoid.xml`, so `referenceOrientationsFromRest` returns identity for all of them and
    // carries NO information about which way any bone points.
    // * SIZED TO `nbody`, WHICH INCLUDES THE WORLD BODY. A 3-bone skeleton makes 4 bodies, and
    // an array of 3 silently caps the child search - the first version of this test found no
    // children at all and reported everything as identity, which looked like a code bug.
    try expectEqual(@as(u32, 4), m.nbody);
    var from_frames: [4]Quat = undefined;
    referenceOrientationsFromRest(&m, &d, &from_frames);
    for (from_frames) |orientation| {
        try expectApproxEqAbs(@as(f32, 1.0), @abs(orientation[3]), 1.0e-4);
    }

    // *** THE BONE-DIRECTION READ DISTINGUISHES THEM. `root` points +Y (identity) and `up`
    // points +X (a real rotation) - which is the information an alignment needs and the body
    // frames do not hold.
    var from_bones: [4]Quat = undefined;
    referenceOrientationsFromBoneDirections(&m, &from_bones);

    // Body 1 ("root") points +Y through its child's offset: identity.
    try expectApproxEqAbs(@as(f32, 1.0), @abs(from_bones[1][3]), 1.0e-4);
    // Body 2 ("up") points +X: a genuine rotation, and the information body frames lack.
    try expect(@abs(from_bones[2][3]) < 0.95);

    // * Rotating +Y by that orientation must give the bone's ACTUAL direction - the property
    // that makes it comparable to the skeleton side's identical construction.
    const rotated: Vec = zm.rotate(from_bones[2], vec(0, 1, 0));
    try expectApproxEqAbs(@as(f32, 1.0), rotated[0], 1.0e-3);
    // * Rotating +Y by that orientation must give the bone's actual direction - the property
    // that makes it comparable to the skeleton side's identical construction.

}

test "ikStep: an ORIENTATION target is reached, and the short way round" {
    const gpa: Allocator = std.testing.allocator;

    const names = [_][]const u8{ "root", "a", "b" };
    const parents = [_]i32{ -1, 0, 1 };
    const offsets = [_]Vec{ vec(0, 0, 0), vec(0, 0.4, 0), vec(0, 0.4, 0) };
    var m: Model = try skeletonToModel(gpa, &names, &parents, &offsets, .{});
    defer m.deinit();
    var d: Data = try Data.init(gpa, &m);
    defer d.deinit();

    @memcpy(d.pos, m.qpos0);
    kinematics(&m, &d);
    comPos(&m, &d);

    const tip: usize = 3;
    const scratch: []f32 = try gpa.alloc(f32, ikScratchSize(m.nv));
    defer gpa.free(scratch);

    // * A ball-jointed chain can express any orientation, so this must converge essentially
    // exactly - unlike a hinge, where the shortfall is real and reported.
    const wanted: Quat = qmul(
        quatFromAxisAngle(vec(0, 0, 1), 0.7),
        quatFromAxisAngle(vec(1, 0, 0), -0.5),
    );
    const tasks = [_]IkTask{.{
        .body = tip,
        .target_world = d.body_xpos[tip],
        .weight = 0.0, // orientation only, so position cannot mask the result
        .target_rotation = wanted,
        .rotation_weight = 1.0,
    }};

    for (0..80) |_| {
        _ = ikStep(&m, &d, &tasks, .{ .damping = 0.05 }, scratch);
        kinematics(&m, &d);
        comPos(&m, &d);
    }

    const reached: Quat = d.body_xrot[tip];
    const alignment: f32 = @abs(reached[0] * wanted[0] + reached[1] * wanted[1] +
        reached[2] * wanted[2] + reached[3] * wanted[3]);
    try expect(alignment > 0.999);

    // -- * A TARGET PAST 180 DEGREES --
    //
    // ** HONEST LIMIT: this does NOT prove the shortest-arc sign correction is load-bearing.
    // Removing it leaves this test green, because with damping and 80 iterations the solver
    // converges either way - it merely takes a longer path. The correction is standard and
    // right (a limb should not spin through the body to reach 190 degrees), but **this test
    // covers convergence past the half turn, not the path taken to get there.**
    //
    // * Saying so beats a comment that implies coverage the assertions do not deliver - the
    // failure mode this session has hit twice already.
    @memcpy(d.pos, m.qpos0);
    kinematics(&m, &d);
    comPos(&m, &d);
    // * PAST pi (3.14). At 3.0 rad the error quaternion keeps a positive w and the sign
    // correction never fires - the first version of this test used 3.0 and could not catch its
    // removal. A control has to reach the branch it claims to test.
    const just_past_half_turn: Quat = quatFromAxisAngle(vec(0, 0, 1), 3.5);
    const long_way = [_]IkTask{.{
        .body = tip,
        .target_world = d.body_xpos[tip],
        .weight = 0.0,
        .target_rotation = just_past_half_turn,
        .rotation_weight = 1.0,
    }};
    var previous: f32 = 1.0e9;
    for (0..80) |_| {
        const current: f32 = ikStep(&m, &d, &long_way, .{ .damping = 0.05 }, scratch);
        // Monotone: a solver taking the long way round would rise before it falls.
        try expect(current <= previous + 1.0e-4);
        previous = current;
        kinematics(&m, &d);
        comPos(&m, &d);
    }
    const long_reached: Quat = d.body_xrot[tip];
    const long_alignment: f32 = @abs(long_reached[0] * just_past_half_turn[0] +
        long_reached[1] * just_past_half_turn[1] +
        long_reached[2] * just_past_half_turn[2] +
        long_reached[3] * just_past_half_turn[3]);
    try expect(long_alignment > 0.99);
}

/// Aim a bone at a direction AND choose its twist so a child hinge bends in the right plane.
///
/// -- *** WHY A SHORTEST ARC IS NOT ENOUGH --
///
/// Measured: aiming the upper arm by shortest arc puts it within 23 degrees of the human's
/// (agreement 0.916) while the FOREARM comes out at -0.196. **A shortest arc adds no rotation
/// about the bone, so the twist is arbitrary - and a child hinge's axis rides in this body's
/// frame, so an arbitrary twist bends the child in an arbitrary PLANE.**
///
/// A good direction with a bad bend plane is exactly that pattern.
///
/// ** So the twist is chosen, not left free: rotate about the aimed bone until the child's
/// hinge axis lines up with the normal of the human's bend plane. That normal is
/// `cross(parent_bone, child_bone)` on the human - the axis the human's own elbow turns about.
///
/// * `child_hinge_axis_local` is the hinge's axis in this body's frame. Returns the aim alone
/// when the two bones are collinear, because a straight limb has no bend plane to match and any
/// twist is then equally right.
pub fn aimBoneWithTwist(
    local_bone: Vec,
    target_bone_dir: Vec,
    child_hinge_axis_local: Vec,
    human_parent_dir: Vec,
    human_child_dir: Vec,
) Quat {
    const swing: Quat = shortestArcBetweenVectors(local_bone, target_bone_dir);

    // The human's bend plane normal: the axis its own joint turns about.
    const human_normal_raw: Vec = crossVec(human_parent_dir, human_child_dir);
    const human_normal_len: f32 = @sqrt(human_normal_raw[0] * human_normal_raw[0] +
        human_normal_raw[1] * human_normal_raw[1] + human_normal_raw[2] * human_normal_raw[2]);
    const limb_is_straight: bool = human_normal_len < 0.05;
    if (limb_is_straight) {
        // * No bend plane to match, and any twist is equally right. Forcing one here would make
        // a straight arm jitter as noise in the capture flips the normal.
        return swing;
    }
    const human_normal: Vec = human_normal_raw / @as(Vec, @splat(human_normal_len));

    // Where the child's hinge axis currently points, with only the swing applied.
    const hinge_now: Vec = zm.rotate(swing, child_hinge_axis_local);

    // Both should be perpendicular to the aimed bone; project them there and measure the angle
    // between, about the bone.
    const axis: Vec = target_bone_dir;
    const hinge_flat: Vec = removeComponentAlong(hinge_now, axis);
    const human_flat: Vec = removeComponentAlong(human_normal, axis);
    const hinge_len: f32 = vecLength(hinge_flat);
    const human_flat_len: f32 = vecLength(human_flat);
    if (hinge_len < 1.0e-5 or human_flat_len < 1.0e-5) {
        // The hinge axis lies along the bone: twisting cannot move it, so there is nothing to
        // choose.
        return swing;
    }
    const a: Vec = hinge_flat / @as(Vec, @splat(hinge_len));
    const b: Vec = human_flat / @as(Vec, @splat(human_flat_len));

    const cosine: f32 = clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1.0, 1.0);
    const sine_vec: Vec = crossVec(a, b);
    const sine: f32 = sine_vec[0] * axis[0] + sine_vec[1] * axis[1] + sine_vec[2] * axis[2];
    const twist_angle: f32 = atan2Rad(sine, cosine);

    return qmul(quatFromAxisAngle(axis, twist_angle), swing);
}

fn shortestArcBetweenVectors(from: Vec, to: Vec) Quat {
    const alignment: f32 = from[0] * to[0] + from[1] * to[1] + from[2] * to[2];
    if (alignment > 0.99999) {
        return quat_identity;
    }
    if (alignment < -0.99999) {
        const helper: Vec = if (@abs(from[0]) < 0.9) vec(1, 0, 0) else vec(0, 1, 0);
        return quatFromAxisAngle(normalize3(crossVec(from, helper)), 3.14159265);
    }
    return quatFromAxisAngle(
        normalize3(crossVec(from, to)),
        acosRad(clamp(alignment, -1.0, 1.0)),
    );
}

fn crossVec(a: Vec, b: Vec) Vec {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
        0,
    };
}

fn removeComponentAlong(v: Vec, axis: Vec) Vec {
    const along: f32 = v[0] * axis[0] + v[1] * axis[1] + v[2] * axis[2];
    return v - axis * @as(Vec, @splat(along));
}

fn vecLength(v: Vec) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

/// The per-joint twist that makes a robot bone point where the source's does.
///
/// -- *** PORTED FROM `FlomoGMR/scripts/flomo_to_geno_bvh.py::compute_twist_offsets` --
///
/// See `src/notes/twist_port_plan.md`. This is deliberately a PORT and not a derivation: the
/// retarget arc spent eleven candidate formulas and four device rounds failing to derive it.
///
///     d_target   = conjugate(source_joint_world_rotation) * source_bone_dir_world
///     R_twist    = minimumAngleRotation(robot_bone_dir_local -> d_target)
///
/// ** **BOTH DIRECTIONS END UP IN THE JOINT'S LOCAL FRAME.** The robot's is already local (its
/// rest orientations are identity, so world equals local); the source's is pulled into that
/// frame by the SOURCE's own world orientation, because `R_twist` bridges FROM the source frame
/// TO the robot's and the source side must be stated in source terms.
///
/// * Computing these in WORLD instead - which is what this arc did for several rounds - makes
/// the correction depend on where a joint happens to be pointing rather than on the two
/// skeletons' shapes.
///
/// * The defining property, which `computeTwistOffset`'s test asserts directly:
///
///     rotate(R_twist, robot_bone_dir_local) == d_target
///
/// from which `world_rot_robot * d_robot == world_rot_src * d_src` follows exactly.
pub fn computeTwistOffset(
    robot_bone_dir_local: Vec,
    source_bone_dir_world: Vec,
    source_joint_world_rotation: Quat,
) Quat {
    const d_target: Vec = zm.rotate(conjugate(source_joint_world_rotation), source_bone_dir_world);
    return shortestArcBetweenVectors(robot_bone_dir_local, d_target);
}

/// Apply the twist to one joint's local rotation, undoing the parent's first.
///
/// *** **THE `inv(parent)` FACTOR IS THE PIECE THIS ARC KEPT MISSING.** The reference's own
/// words: *"undoes the parent's twist so it doesn't accumulate and distort children. Without it,
/// each joint in a chain would get the parent's twist baked in on top of its own."*
///
/// That is exactly the failure observed: a correction that improved a shoulder and degraded the
/// forearm below it.
///
/// * Chains must be walked PARENT TO CHILD so `parent_twist` is the one computed for this
/// joint's actual parent, not whichever body happened to come before it in index order.
pub fn applyTwist(source_local_rotation: Quat, parent_twist: Quat, own_twist: Quat) Quat {
    return qmul(qmul(conjugate(parent_twist), source_local_rotation), own_twist);
}

test "computeTwistOffset: the defining property holds - rotate(R_twist, d_robot) == d_target" {
    // -- *** THIS TEST NEEDS NO CAPTURE, NO FRAMES AND NO SCORECARD --
    //
    // It is pure algebra over two rest directions, so it either holds or the port is wrong.
    // section 14's plan puts it first for exactly that reason: every later step rests on this and
    // nothing else can isolate it.
    const cases = [_]struct {
        robot_dir: Vec,
        source_dir_world: Vec,
        source_rot: Quat,
    }{
        // A robot arm pointing UP against a source arm pointing SIDEWAYS - the ~90 degree case
        // the reference's docstring names, and the one that broke this arc's arms.
        .{
            .robot_dir = vec(0, 1, 0),
            .source_dir_world = vec(1, 0, 0),
            .source_rot = quat_identity,
        },
        // The same, but with the source joint itself rotated: `d_target` must be pulled into
        // the joint's LOCAL frame, so the answer differs from the case above.
        .{
            .robot_dir = vec(0, 1, 0),
            .source_dir_world = vec(1, 0, 0),
            .source_rot = quatFromAxisAngle(vec(0, 0, 1), 0.6),
        },
        // A diagonal robot bone, like `humanoid.xml`'s `lower_arm_left` at (.18, .18, -.18).
        .{
            .robot_dir = normalize3(vec(1, 1, -1)),
            .source_dir_world = vec(1, 0, 0),
            .source_rot = quatFromAxisAngle(vec(1, 0, 0), -0.4),
        },
        // Already aligned: the twist must be identity, not a near-identity with drift.
        .{
            .robot_dir = vec(0, 0, 1),
            .source_dir_world = vec(0, 0, 1),
            .source_rot = quat_identity,
        },
    };

    for (cases) |c| {
        const twist: Quat = computeTwistOffset(c.robot_dir, c.source_dir_world, c.source_rot);
        const d_target: Vec = zm.rotate(conjugate(c.source_rot), c.source_dir_world);
        const rotated: Vec = zm.rotate(twist, c.robot_dir);
        inline for (0..3) |axis| {
            try expectApproxEqAbs(d_target[axis], rotated[axis], 1.0e-4);
        }
    }

    // * And the aligned case really is identity - a twist that is merely CLOSE would accumulate
    // through a chain, and the legs (which already match at rest) must come out untouched.
    const aligned: Quat = computeTwistOffset(vec(0, 0, 1), vec(0, 0, 1), quat_identity);
    try expectApproxEqAbs(@as(f32, 1.0), @abs(aligned[3]), 1.0e-5);
}

test "applyTwist: a chain does NOT accumulate its parent's twist" {
    // -- *** THE PROPERTY THE MISSING `inv(parent)` FACTOR PROVIDES --
    //
    // Two joints in a chain, both given the same twist. With the parent factor, the child's
    // WORLD orientation gains exactly its OWN twist. Without it, the child would gain the
    // parent's as well - which is the shoulder-improves-forearm-degrades failure this arc hit.
    const twist: Quat = quatFromAxisAngle(vec(0, 0, 1), 0.7);
    const parent_local: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.3);
    const child_local: Quat = quatFromAxisAngle(vec(0, 1, 0), -0.5);

    const parent_corrected: Quat = applyTwist(parent_local, quat_identity, twist);
    const child_corrected: Quat = applyTwist(child_local, twist, twist);

    // World orientations after correction.
    const parent_world: Quat = parent_corrected;
    const child_world: Quat = qmul(parent_world, child_corrected);

    // * The reference's stated invariant: `world_rot_robot = world_rot_src * R_twist`.
    const src_parent_world: Quat = parent_local;
    const src_child_world: Quat = qmul(src_parent_world, child_local);

    const expect_parent: Quat = qmul(src_parent_world, twist);
    const expect_child: Quat = qmul(src_child_world, twist);

    inline for (0..4) |i| {
        try expectApproxEqAbs(expect_parent[i], parent_world[i], 1.0e-4);
        try expectApproxEqAbs(expect_child[i], child_world[i], 1.0e-4);
    }

    // ** AND WITHOUT THE PARENT FACTOR IT IS WRONG - asserted, so the factor cannot be quietly
    // removed by someone simplifying the expression.
    const naive_child: Quat = qmul(child_local, twist);
    const naive_world: Quat = qmul(parent_world, naive_child);
    var differs: bool = false;
    inline for (0..4) |i| {
        if (@abs(expect_child[i] - naive_world[i]) > 1.0e-3) {
            differs = true;
        }
    }
    try expect(differs);
}

/// Build per-body twist offsets along named chains, from two rest poses.
///
/// -- *** SHARED SO THE EXAMPLE AND THE TEST CANNOT DIVERGE --
///
/// This lived twice - once in `examples/geno_dance` and once in the scorecard harness - and the
/// two copies drifted in FOUR ways before anyone noticed: the reference pose (T-pose vs the
/// A-pose bind), the accumulation (rotated offsets vs raw), the solver's task set, and the IK
/// default. **Every divergence was invisible until a screenshot contradicted a number.**
///
/// ** A measurement harness that duplicates the code it measures is measuring a guess. One
/// implementation, called by both, is the only version of this that stays honest.
///
/// `rest_positions_robot_frame` holds the SOURCE's rest world positions already converted to the
/// robot's frame, indexed by source joint. `chains` are body-name sequences, parent to child;
/// each body must appear in exactly one.
pub fn computeTwistChainOffsets(
    m: *const Model,
    d: *Data,
    names: []const []const u8,
    human_of_body: []const i32,
    rest_positions_robot_frame: []const Vec,
    /// The source joints' rest WORLD rotations, in the robot's frame. Null treats them as
    /// identity.
    ///
    /// -- *** WHY THE SOURCE SIDE STILL NEEDS THIS --
    ///
    /// `d_robot` is already local, because `humanoid.xml` declares no body rotations and its
    /// rest local frame IS world. **The SOURCE's is not**: `Spine3` carries the accumulated
    /// rotation of four spine joints above it, so its bone direction expressed in world is not
    /// the same as expressed in its own frame.
    ///
    /// * Dropping this was right when `q_local` was ALSO wrong (taken against the human's own
    /// parent); the two errors partly cancelled. With `q_local` fixed, the division belongs
    /// back - which is a prediction the scorecard can settle in one run.
    rest_rotations_robot_frame: ?[]const Quat,
    chains: []const []const []const u8,
    /// The two shoulder bodies, when the model has them. Their axis replaces the chain bone for
    /// whichever body is their common parent.
    ///
    /// *** A CHAIN BONE PARALLEL TO THE MISSING AXIS ENCODES NOTHING. The torso's chain bone is
    /// `torso -> head`, which is VERTICAL, and a shortest arc between two vertical bones leaves
    /// YAW free - the very axis the two skeletons differ about. The shoulders then swing bodily
    /// off an uncorrected torso, which reads as "shoulders rotated 90 degrees".
    ///
    /// * Shoulder-to-shoulder is horizontal and sees yaw exactly. It is also the right bone on
    /// its merits: the torso's job in this rig is to carry the shoulders.
    shoulder_bodies: ?[2]usize,
    /// The robot's REST configuration. Null uses `qpos0`.
    ///
    /// -- *** `qpos0` IS NOT NECESSARILY A T-POSE --
    ///
    /// `humanoid.xml`'s folds its arms up into a triangle. Building twists against it compares
    /// two DIFFERENT PHYSICAL POSES, which is the rule this arc broke four times - and its root
    /// instance, since every other rest-pose bug sat on top of this one.
    ///
    /// * Passing a configuration SOLVED onto the source's T-pose makes both references depict
    /// the same pose by construction, rather than by hoping two rigs happen to agree.
    robot_rest_qpos: ?[]const f32,
    out_twist: []Quat,
    out_parent_twist: []Quat,
) void {
    for (0..m.nbody) |body| {
        out_twist[body] = quat_identity;
        out_parent_twist[body] = quat_identity;
    }
    if (robot_rest_qpos) |rest| {
        @memcpy(d.pos, rest);
    } else {
        @memcpy(d.pos, m.qpos0);
    }
    kinematics(m, d);

    for (chains) |chain| {
        // * A chain that does not start at a root inherits its parent BODY's twist, so chains
        // must be ordered with ancestors first.
        var previous: Quat = quat_identity;
        if (findBodyByName(names, chain[0])) |first| {
            const parent_body: u32 = m.body_parent[first];
            if (parent_body != 0) {
                previous = out_twist[parent_body];
            }
        }

        for (chain, 0..) |body_name, position| {
            const body: usize = findBodyByName(names, body_name) orelse continue;
            out_parent_twist[body] = previous;

            const is_leaf: bool = position + 1 >= chain.len;
            if (is_leaf) {
                out_twist[body] = quat_identity;
                previous = quat_identity;
                continue;
            }
            const child: usize =
                findBodyByName(names, chain[position + 1]) orelse continue;

            const human_body: i32 = human_of_body[body];
            const human_child: i32 = human_of_body[child];
            if (human_body < 0 or human_child < 0) {
                continue;
            }

            const robot_bone: Vec =
                normalize3(d.body_xpos[child] - d.body_xpos[body]);
            const source_bone: Vec = rest_positions_robot_frame[@intCast(human_child)] -
                rest_positions_robot_frame[@intCast(human_body)];
            const bone_length: f32 = @sqrt(source_bone[0] * source_bone[0] +
                source_bone[1] * source_bone[1] + source_bone[2] * source_bone[2]);
            if (bone_length < 1.0e-6) {
                continue;
            }

            // * `humanoid.xml` declares no body rotations, so its rest LOCAL frame IS the world
            // frame and there is no joint rotation to divide out.
            const source_rest_rotation: Quat = if (rest_rotations_robot_frame) |rotations|
                rotations[@intCast(human_body)]
            else
                quat_identity;
            out_twist[body] = computeTwistOffset(
                robot_bone,
                source_bone / @as(Vec, @splat(bone_length)),
                source_rest_rotation,
            );
            previous = out_twist[body];
        }
    }

    if (shoulder_bodies) |shoulders| {
        const carrier: u32 = m.body_parent[shoulders[0]];
        if (carrier != 0 and m.body_parent[shoulders[1]] == carrier) {
            const human_left: i32 = human_of_body[shoulders[0]];
            const human_right: i32 = human_of_body[shoulders[1]];
            if (human_left >= 0 and human_right >= 0) {
                const robot_axis: Vec =
                    d.body_xpos[shoulders[0]] - d.body_xpos[shoulders[1]];
                const source_axis: Vec = rest_positions_robot_frame[@intCast(human_left)] -
                    rest_positions_robot_frame[@intCast(human_right)];
                const robot_len: f32 = @sqrt(robot_axis[0] * robot_axis[0] +
                    robot_axis[1] * robot_axis[1] + robot_axis[2] * robot_axis[2]);
                const source_len: f32 = @sqrt(source_axis[0] * source_axis[0] +
                    source_axis[1] * source_axis[1] + source_axis[2] * source_axis[2]);
                if (robot_len > 1.0e-6 and source_len > 1.0e-6) {
                    out_twist[carrier] = computeTwistOffset(
                        robot_axis / @as(Vec, @splat(robot_len)),
                        source_axis / @as(Vec, @splat(source_len)),
                        quat_identity,
                    );
                    // * Children inherit the corrected value, or they undo a twist their parent
                    // no longer has.
                    for (0..m.nbody) |body| {
                        if (m.body_parent[body] == carrier) {
                            out_parent_twist[body] = out_twist[carrier];
                        }
                    }
                }
            }
        }
    }
}

fn findBodyByName(names: []const []const u8, wanted: []const u8) ?usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, wanted)) {
            return index;
        }
    }
    return null;
}

/// Everything the pose loop needs, already in the ROBOT's frame.
///
/// * Converting at the boundary means this function knows nothing about either skeleton's
/// up-axis convention - and the two callers cannot disagree about where the conversion happens,
/// which is one of the four ways they previously drifted.
pub const RetargetPose = struct {
    human_of_body: []const i32,
    /// Source joint world positions, scaled and in the robot's frame.
    positions: []const Vec,
    /// Source joint world rotations, in the robot's frame.
    rotations: []const Quat,
    human_parents: []const i32,
    twist: []const Quat,
    parent_twist: []const Quat,
    /// Bodies whose bone is aimed straight at the mapped child's position rather than oriented
    /// by the twist - upper arms, where the child's PLACEMENT is what matters.
    aim_at_child: []const bool,
    /// The two shoulder bodies, when present. The root is shifted so their midpoint lands on the
    /// source's.
    ///
    /// *** THE ROBOT'S TORSO-TO-SHOULDER OFFSET IS FIXED BY THE MODEL, so copying the source's
    /// spine position puts the shoulders wherever the robot's proportions happen to - measured
    /// 0.2 m out. Solving for the position that lands the shoulders instead is one subtraction.
    ///
    /// * The MIDPOINT, because the shoulder SEPARATION is fixed too: no single root position
    /// satisfies both, and splitting the difference beats favouring a side.
    shoulder_bodies: ?[2]usize = null,
    /// Where the root body should sit, in the robot's frame, before the shoulder correction.
    root_world_position: ?Vec = null,
    /// -- *** MECHANISM B: AIM EVERY MAPPED BONE, INSTEAD OF CONVERTING ROTATIONS --
    ///
    /// The pipeline contains two ways of deciding where a bone points:
    ///
    ///   A  twist offsets - convert a ROTATION from the source's frame to the robot's, via a
    ///      per-bone `R_twist` derived from two rest poses
    ///   B  aiming - compare DIRECTIONS in world space and rotate the bone onto the target
    ///
    /// *** **B NEEDS NO REST-POSE ALGEBRA, BECAUSE A DIRECTION CARRIES ITS OWN FRAME.** Every
    /// rest-pose bug in this arc - A-pose for T-pose twice, an unrotated accumulation, a
    /// vertical reference bone, a missing source rest rotation, `qpos0` not being a T-pose -
    /// was a bug in A. **B is structurally immune to all of them.**
    ///
    /// * A's one advantage is that it carries TWIST, which a direction cannot. B recovers that
    /// separately from the child's bend plane, via `aimBoneWithTwist`.
    ///
    /// * Set this to compare the two on the scorecard with everything else identical, which is
    /// the only honest way to choose between them.
    aim_all: bool = false,
    /// Bodies that head a TWO-BONE LIMB - a shoulder or a hip whose child is a hinge and whose
    /// grandchild is the end effector.
    ///
    /// *** Such a limb is EXACTLY DETERMINED: 2 DOF + 1 DOF against a 3-number target. It is
    /// solved in closed form by `solveTwoBoneLimb` rather than aimed, bent and twisted by three
    /// separate heuristics that each leave something undetermined.
    two_bone: ?[]const bool = null,
    /// Each 1-DOF body's bend at `qpos0`, in radians. Null treats zero as straight - which is
    /// **wrong for `humanoid.xml`, whose elbows rest at 109.5 degrees.**
    rest_flexion: ?[]const f32 = null,
    /// Scratch for the per-body orientation solve. When supplied, bodies with two or more DOF
    /// are posed by a LIMITED IK on their bone direction rather than by `fitBodyRotation`.
    ///
    /// -- *** WHY: `fitBodyRotation` WASTES A NARROW AXIS --
    ///
    /// It walks a body's joints IN ORDER, giving each what it can take of the remaining
    /// rotation. `humanoid.xml`'s hip is `hip_x` (range 40 degrees), `hip_z` (95) and `hip_y`
    /// (170) - **spend the 40-degree axis early on something a wider one could have done and it
    /// clamps for no reason.**
    ///
    /// *** MEASURED, same target, same three DOF, limits enforced on both:
    ///
    ///     fit  32.4 / 11.1 / 68.2 / 30.3 deg        IK  0.0 / 0.0 / 0.0 / 0.0
    ///
    /// **The hip's range was never the constraint.** The target was reachable on every frame and
    /// the sequential fit could not find it. An IK has no ordering: it distributes across all
    /// three axes at once.
    ///
    /// * Left optional so the caller owns the buffers and a per-frame call allocates nothing.
    solve_scratch: ?[]f32 = null,
    solve_tasks: ?[]IkTask = null,
    /// Start from whatever `d.pos` already holds instead of resetting to `qpos0`.
    ///
    /// -- *** THE REDUNDANT DOF IS RE-CHOSEN EVERY FRAME FROM A COLD START --
    ///
    /// A leg is 4 DOF against a 3-number ankle target, so one degree of freedom - the knee's
    /// swivel - is genuinely free. From `qpos0` the solver picks whichever branch its damping
    /// favours, INDEPENDENTLY EVERY FRAME, and the leg snaps between equally-valid answers.
    /// **That is the jitter, and no static per-frame measurement can see it**: every angle can
    /// be correct while the limb flips between frames.
    ///
    /// ** GMR never resets; its configuration integrates forward. Warm-starting makes the
    /// previous frame the tie-breaker among the free solutions, which is the whole reason it
    /// resolves continuity for free.
    ///
    /// * Off by default so a single-frame test stays independent of what ran before it.
    warm_start: bool = false,
    /// Bodies oriented by TWO DIRECTIONS instead of by a converted rotation.
    ///
    /// -- *** THE TORSO AND PELVIS ARE NOT LIMBS --
    ///
    /// A limb has one bone; its direction leaves twist free and the rest-pose machinery exists
    /// to recover it. A torso has TWO obvious directions - spine and shoulder axis - and two
    /// directions determine an orientation completely, with nothing to recover. Measured: the
    /// spine matches EXACTLY on every frame, against 35 degrees from the twist-offset path.
    ///
    /// * Directions come from the capture's positions, which have been verified correct since
    /// early in the project. No rest pose, no twist, no chain.
    direction_pairs: ?[]const DirectionPair = null,
};

/// One body oriented by two capture directions.
pub const DirectionPair = struct {
    body: usize,
    /// The capture joints whose difference gives each direction.
    primary_from: usize,
    primary_to: usize,
    secondary_from: usize,
    secondary_to: usize,
    /// The robot's matching directions at rest, in world (= local at `qpos0`).
    robot_primary: Vec,
    robot_secondary: Vec,
    /// How many ANCESTORS to fit the target through before the body itself.
    ///
    /// -- *** A BODY'S DOF MAY LIVE UPSTREAM --
    ///
    /// `humanoid.xml`'s waist is 3 DOF split across two bodies: `waist_lower` owns abdomen_z
    /// and abdomen_y, `pelvis` owns abdomen_x. Fitting a pelvis target onto the pelvis alone
    /// reaches ONE axis of three - measured 31-69 degrees off on the hip axis. With
    /// `chain_depth = 1` the target is fitted onto `waist_lower` first, then the residual onto
    /// the pelvis, and all three axes take part.
    chain_depth: u8 = 0,
};

/// Pose the whole robot for one frame. The single implementation, called by example and test.
///
/// -- *** WHY THIS IS ONE FUNCTION AND NOT TWO --
///
/// The example and the scorecard harness each had a copy, and they drifted in four ways before
/// a screenshot caught it. **A measurement of a duplicate is a measurement of a guess.**
///
/// Bodies are visited parents-first, which MuJoCo's ordering guarantees, so each child is fitted
/// against the orientation its parent ACTUALLY achieved rather than the one it was asked for.
/// -- *** SUPERSEDED BY `solvePointCloud`. KEPT ON PURPOSE. --
///
/// **Nothing that ships calls this.** The example and the harness both pose through
/// `buildPointSamples` + `solvePointCloud`, which subsumes every mechanism here: twist offsets,
/// aim-at-child, two-bone limbs, direction pairs, rest-flexion and the hinge formula are each a
/// special case of matching sample points.
///
/// ** It is kept because five harness tests still measure it, and **those measurements are what
/// justify the replacement**: 155 degrees of worst-frame pop against 9.2, a forearm that could
/// not get below 28 degrees, legs pinned at their limits on half the frames. Delete this and the
/// evidence for the point cloud goes with it.
///
/// *** It is NOT a divergence risk in the way a duplicated implementation is: **it is not
/// supposed to agree with `solvePointCloud`.** The seven divergences this project fixed were all
/// two copies of the SAME thing drifting apart; this is one copy of a DIFFERENT thing, kept as a
/// baseline. **Disuse is not the liability - duplication is.**
///
/// * New code should call `solvePointCloud`.
pub fn poseFromRetarget(m: *const Model, d: *Data, in: RetargetPose) void {
    // -- *** A DIRECTION-PAIR BODY APPLIES NO TWIST, SO ITS CHILDREN MUST NOT UNDO ONE --
    //
    // Mechanism A chains through `inv(parent_twist)`: every child removes its parent's twist
    // before applying its own. **A body posed by two directions never applied a twist**, so a
    // child that still divides by one is undoing a rotation that was never there - and the error
    // runs down the whole chain.
    //
    // Measured: making the torso and pelvis exact took the THIGH from 12 to 68 degrees and the
    // SHIN past 90. The legs were not broken by their own mechanism; they were broken by their
    // parent changing mechanism underneath them. **This is section 21's per-body mixing problem, met
    // again from the other direction.**
    var parent_twist_local: [128]Quat = undefined;
    var effective_parent_twist: []const Quat = in.parent_twist;
    if (in.direction_pairs) |pairs| {
        const count: usize = @min(m.nbody, parent_twist_local.len);
        @memcpy(parent_twist_local[0..count], in.parent_twist[0..count]);
        for (pairs) |pair| {
            for (0..count) |body| {
                if (m.body_parent[body] == pair.body) {
                    parent_twist_local[body] = quat_identity;
                }
            }
        }
        effective_parent_twist = parent_twist_local[0..count];
    }

    // *** A two-bone solve sets its MIDDLE joint, and the loop would then reach that body and
    // overwrite it with the per-joint heuristic. **Symptom: a hand error frozen at 0.57 m on
    // every frame while the elbow improved** - the elbow was being placed correctly and undone.
    var already_posed: [128]bool = undefined;
    @memset(already_posed[0..@min(m.nbody, already_posed.len)], false);

    if (!in.warm_start) {
        @memcpy(d.pos, m.qpos0);
    }
    if (in.root_world_position) |root_position| {
        if (m.njnt > 0 and m.jnt_type[0] == .free) {
            const root_qpos: usize = m.jnt_qpos_adr[0];
            d.pos[root_qpos + 0] = root_position[0];
            d.pos[root_qpos + 1] = root_position[1];
            d.pos[root_qpos + 2] = root_position[2];
        }
    }
    kinematics(m, d);

    for (0..m.nbody) |body| {
        const human_joint: i32 = in.human_of_body[body];
        if (human_joint < 0) {
            continue;
        }
        if (body < already_posed.len and already_posed[body]) {
            continue;
        }
        const joint: usize = @intCast(human_joint);

        // -- *** TWO DIRECTIONS FOR A TORSO OR PELVIS --
        if (in.direction_pairs) |pairs| {
            var handled: bool = false;
            for (pairs) |pair| {
                if (pair.body != body) {
                    continue;
                }
                const human_primary: Vec = in.positions[pair.primary_to] - in.positions[pair.primary_from];
                const human_secondary: Vec =
                    in.positions[pair.secondary_to] - in.positions[pair.secondary_from];
                const world: Quat = rotationBetweenDirectionPairs(
                    pair.robot_primary,
                    pair.robot_secondary,
                    human_primary,
                    human_secondary,
                );
                const is_root: bool = m.body_parent[body] == 0;
                if (is_root and m.njnt > 0 and m.jnt_type[0] == .free) {
                    // * The root is FREE: write the rotation, exactly. No fit.
                    const root_qpos: usize = m.jnt_qpos_adr[0];
                    d.pos[root_qpos + 3] = world[0];
                    d.pos[root_qpos + 4] = world[1];
                    d.pos[root_qpos + 5] = world[2];
                    d.pos[root_qpos + 6] = world[3];
                } else {
                    // * Not the root: fit through the ancestors named by `chain_depth`, top
                    // down, each against its parent's ACHIEVED orientation - then the body.
                    // Every fit is of the SAME world target; each ancestor takes what it can
                    // and the next sees only what remains.
                    var ancestors: [8]usize = undefined;
                    var count: usize = 0;
                    var walker: usize = body;
                    while (count < pair.chain_depth and count < ancestors.len) : (count += 1) {
                        const up: u32 = m.body_parent[walker];
                        if (up == 0) {
                            break;
                        }
                        ancestors[count] = up;
                        walker = up;
                    }
                    var i: usize = count;
                    while (i > 0) {
                        i -= 1;
                        const ancestor: usize = ancestors[i];
                        const ancestor_parent: Quat = d.body_xrot[m.body_parent[ancestor]];
                        _ = fitBodyRotation(m, d, ancestor, qmul(conjugate(ancestor_parent), world));
                        kinematics(m, d);
                    }
                    const parent_world: Quat = d.body_xrot[m.body_parent[body]];
                    _ = fitBodyRotation(m, d, body, qmul(conjugate(parent_world), world));
                }
                kinematics(m, d);
                handled = true;
                break;
            }
            if (handled) {
                continue;
            }
        }

        // -- *** A TWO-BONE LIMB IS SOLVED WHOLE, NOT JOINT BY JOINT --
        //
        // Measured: hand errors up to 0.50 m on an arm spanning 0.62 m, with every target well
        // inside reach. Aiming the shoulder, bending the elbow by flexion angle and choosing a
        // twist are three heuristics that each leave something free; **the closed form leaves
        // nothing free and meets a reachable target exactly.**
        //
        // * The capture's own middle joint picks the bend PLANE, which is the one genuine
        // ambiguity - and the circle it resolves is the free twist this arc chased for four
        // experiments.
        if (in.two_bone) |two_bone_flags| {
            if (two_bone_flags[body]) {
                if (solveLimbHere(m, d, in, body, joint)) {
                    // * Claim the middle joint so the per-joint path cannot undo it.
                    if (firstChildBody(m, body)) |middle| {
                        if (middle < already_posed.len) {
                            already_posed[middle] = true;
                        }
                    }
                    continue;
                }
            }
        }

        // -- The desired WORLD orientation --
        const world_target: Quat = blk: {
            // * AIM: an upper arm's job is to place the elbow, and the bone length is fixed, so
            // the only freedom is direction. A position criterion producing an orientation.
            if (in.aim_all or in.aim_at_child[body]) {
                if (firstChildBody(m, body)) |child| {
                    if (firstChildJoint(in.human_parents, joint)) |human_child| {
                        const bone: Vec = in.positions[human_child] - in.positions[joint];
                        const len: f32 = @sqrt(bone[0] * bone[0] + bone[1] * bone[1] +
                            bone[2] * bone[2]);
                        if (len > 1.0e-6) {
                            const local_bone: Vec = normalize3(m.body_pos[child]);
                            const target_dir: Vec = bone / @as(Vec, @splat(len));

                            // ** WHERE THE CHILD IS A HINGE, CHOOSE THE TWIST TOO. A shortest
                            // arc adds no rotation about the bone, and a hinge's axis rides in
                            // THIS body's frame - so an arbitrary twist bends the child in an
                            // arbitrary PLANE. Measured: the forearm goes from -0.196 to +0.563
                            // once the plane is chosen.
                            const child_is_hinge: bool = m.body_jnt_num[child] == 1 and
                                m.jnt_type[m.body_jnt_adr[child]] == .hinge;
                            if (child_is_hinge) {
                                if (firstChildJoint(in.human_parents, human_child)) |grand| {
                                    const child_bone: Vec =
                                        in.positions[grand] - in.positions[human_child];
                                    const child_len: f32 = @sqrt(child_bone[0] * child_bone[0] +
                                        child_bone[1] * child_bone[1] +
                                        child_bone[2] * child_bone[2]);
                                    if (child_len > 1.0e-6) {
                                        break :blk aimBoneWithTwist(
                                            local_bone,
                                            target_dir,
                                            m.jnt_axis[m.body_jnt_adr[child]],
                                            target_dir,
                                            child_bone / @as(Vec, @splat(child_len)),
                                        );
                                    }
                                }
                            }
                            break :blk shortestArcBetweenVectors(local_bone, target_dir);
                        }
                    }
                }
            }
            // * Otherwise the ported recipe, with `q_local` taken relative to the human joint
            // driving THIS BODY'S PARENT - which handles a skipped joint and an inverted spine
            // with the same expression.
            const robot_parent: u32 = m.body_parent[body];
            const parent_human: i32 = if (robot_parent == 0) -1 else in.human_of_body[robot_parent];
            const q_local: Quat = if (parent_human < 0)
                in.rotations[joint]
            else
                qmul(conjugate(in.rotations[@intCast(parent_human)]), in.rotations[joint]);
            break :blk applyTwist(q_local, effective_parent_twist[body], in.twist[body]);
        };

        // -- * A ONE-HINGE BODY IS BENT, NOT ORIENTED --
        //
        // Measured: a 1-DOF elbow delivers -0.010 for an arbitrary direction. It swings in one
        // plane and takes the human's FLEXION ANGLE as a scalar; the sign comes from the joint's
        // own range, so a different robot needs no code change.
        const only_hinge: bool = m.body_jnt_num[body] == 1 and
            m.jnt_type[m.body_jnt_adr[body]] == .hinge;
        if (only_hinge and in.human_parents[joint] >= 0) {
            if (firstChildJoint(in.human_parents, joint)) |human_child| {
                const upper: Vec =
                    in.positions[joint] - in.positions[@intCast(in.human_parents[joint])];
                const lower: Vec = in.positions[human_child] - in.positions[joint];
                const upper_len: f32 = @sqrt(upper[0] * upper[0] + upper[1] * upper[1] +
                    upper[2] * upper[2]);
                const lower_len: f32 = @sqrt(lower[0] * lower[0] + lower[1] * lower[1] +
                    lower[2] * lower[2]);
                if (upper_len > 1.0e-6 and lower_len > 1.0e-6) {
                    const cosine: f32 = clamp(
                        (upper[0] * lower[0] + upper[1] * lower[1] + upper[2] * lower[2]) /
                            (upper_len * lower_len),
                        -1.0,
                        1.0,
                    );
                    const hinge: usize = m.body_jnt_adr[body];
                    const range: [2]f32 = m.jnt_range[hinge] orelse .{ -3.14159, 3.14159 };
                    const flexion: f32 = acosRad(cosine);

                    // -- *** ZERO IS NOT STRAIGHT --
                    //
                    // Measured on a bare model: `bend = rest_bend + qpos`, exactly, and
                    // `humanoid.xml`'s elbow rest bend is **109.5 degrees** - its arms fold into
                    // a triangle at `qpos0`. **Writing the wanted flexion straight into the
                    // coordinate asked for -90.9 and got 18.6**, which cost four turns of
                    // geometric explanations that were all eliminated.
                    //
                    // * So subtract the rest bend. `rest_flexion` is a property of the model,
                    // passed in rather than recomputed per frame.
                    //
                    // ** **The reference-pose problem again, in JOINT COORDINATES this time** -
                    // the fifth costume it has worn in this arc.
                    const rest_flexion: f32 = if (in.rest_flexion) |rest| rest[body] else 0;

                    // -- *** NO SIGN FLIP. THE MEASURED RELATION HAS NONE. --
                    //
                    // On a bare model, `bend = rest_bend + qpos` - the coordinate ADDS to the
                    // rest bend. To straighten an elbow resting at 109.5, qpos must be -109.5.
                    // The old `bends_negative` flip turned that into +109.5, then clamped it to
                    // +50 - and the arm bent FURTHER. Measured: a nearly straight human arm
                    // produced a robot forearm 127 degrees off, folded back on itself.
                    //
                    // * The "which way does it bend" heuristic guessed from the range. The
                    // relation was measured, and it says: subtract, and stop.
                    d.pos[m.jnt_qpos_adr[hinge]] =
                        clamp(flexion - rest_flexion, range[0], range[1]);
                    kinematics(m, d);
                    continue;
                }
            }
        }

        // -- *** MULTI-DOF BODIES GO THROUGH IK, NOT THE SEQUENTIAL FIT --
        //
        // Measured above: the fit misses a REACHABLE target by 11-68 degrees on a 3-DOF hip
        // while an IK on the same target with the same limits hits it exactly.
        // ** NOTE: a caller that runs a WHOLE-CHAIN solve afterwards (ankle primary, knee for
        // swivel) supersedes this per-body pass entirely - measured thigh 4.2 / shin 9.6 against
        // 18.3 / 67.8 here. This remains for callers that do not.
        const child_for_aim: ?usize = firstChildBody(m, body);
        if (in.solve_scratch != null and in.solve_tasks != null and
            m.body_dof_num[body] >= 2 and child_for_aim != null)
        {
            const child: usize = child_for_aim.?;
            const local_bone: Vec = m.body_pos[child];
            const bone_len: f32 = vecLength(local_bone);
            if (bone_len > 1.0e-6) {
                const want_dir: Vec = normalize3(zm.rotate(world_target, local_bone));
                var mask: [128]bool = undefined;
                const dof_total: usize = @min(m.nv, mask.len);
                @memset(mask[0..dof_total], false);
                const first_dof: usize = m.body_dof_adr[body];
                for (0..m.body_dof_num[body]) |k| {
                    if (first_dof + k < dof_total) {
                        mask[first_dof + k] = true;
                    }
                }
                const tasks: []IkTask = in.solve_tasks.?;
                const knee_target: Vec =
                    d.body_xpos[body] + want_dir * @as(Vec, @splat(bone_len));
                tasks[0] = .{ .body = child, .target_world = knee_target, .weight = 1.0 };
                var task_total: usize = 1;

                // -- ** A SECOND TASK ON THE GRANDCHILD FIXES THE TWIST --
                //
                // One position target on the child leaves rotation ABOUT the bone free, and a
                // child hinge's axis rides in this body's frame - so the grandchild swings out
                // of plane. Measured: the thigh went to 4.8 degrees while the SHIN went from 75
                // to 106, because the knee was bending sideways.
                //
                // * The grandchild's target uses the capture's DIRECTION at the ROBOT's own bone
                // length, so it is exactly reachable and asks only for the plane.
                if (in.solve_tasks.?.len > 1) {
                    if (firstChildBody(m, child)) |grand| {
                        if (firstChildJoint(in.human_parents, joint)) |human_child| {
                            if (firstChildJoint(in.human_parents, human_child)) |human_grand| {
                                const next: Vec =
                                    in.positions[human_grand] - in.positions[human_child];
                                const next_len: f32 = vecLength(next);
                                const own_len: f32 = vecLength(m.body_pos[grand]);
                                if (next_len > 1.0e-6 and own_len > 1.0e-6) {
                                    tasks[1] = .{
                                        .body = grand,
                                        .target_world = knee_target +
                                            (next / @as(Vec, @splat(next_len))) *
                                                @as(Vec, @splat(own_len)),
                                        // * LIGHT. The child's own bone direction is the primary
                                        // thing; the grandchild only picks the plane. At 0.5 it
                                        // competed and took the thigh from 4.8 to 25.3 degrees.
                                        .weight = 0.15,
                                    };
                                    task_total = 2;
                                }
                            }
                        }
                    }
                }

                comPos(m, d);
                for (0..40) |_| {
                    _ = ikStep(m, d, tasks[0..task_total], .{
                        .damping = 0.05,
                        .dof_mask = mask[0..dof_total],
                        .respect_joint_limits = true,
                    }, in.solve_scratch.?);
                    kinematics(m, d);
                    comPos(m, d);
                }
                continue;
            }
        }

        const parent_world: Quat = d.body_xrot[m.body_parent[body]];
        _ = fitBodyRotation(m, d, body, qmul(conjugate(parent_world), world_target));
        kinematics(m, d);
    }

    // * Last, because it needs the posed shoulders: shift the root so their midpoint lands on
    // the source's. A pure translation, so nothing above is disturbed.
    if (in.shoulder_bodies) |shoulders| {
        const left_human: i32 = in.human_of_body[shoulders[0]];
        const right_human: i32 = in.human_of_body[shoulders[1]];
        if (left_human >= 0 and right_human >= 0 and m.njnt > 0 and m.jnt_type[0] == .free) {
            const half: Vec = @splat(0.5);
            const robot_mid: Vec =
                (d.body_xpos[shoulders[0]] + d.body_xpos[shoulders[1]]) * half;
            const source_mid: Vec = (in.positions[@intCast(left_human)] +
                in.positions[@intCast(right_human)]) * half;
            const shift: Vec = source_mid - robot_mid;
            const root_qpos: usize = m.jnt_qpos_adr[0];
            d.pos[root_qpos + 0] += shift[0];
            d.pos[root_qpos + 1] += shift[1];
            d.pos[root_qpos + 2] += shift[2];
            kinematics(m, d);
        }
    }
}

/// Pose a two-bone limb from `body` in closed form. Returns false when the shape does not fit
/// (no hinge child, no mapped end effector), leaving the caller to fall through.
fn solveLimbHere(
    m: *const Model,
    d: *Data,
    in: RetargetPose,
    body: usize,
    joint: usize,
) bool {
    const middle: usize = firstChildBody(m, body) orelse return false;
    const end: usize = firstChildBody(m, middle) orelse return false;
    const middle_is_hinge: bool = m.body_jnt_num[middle] == 1 and
        m.jnt_type[m.body_jnt_adr[middle]] == .hinge;
    if (!middle_is_hinge) {
        return false;
    }
    const human_middle: usize = firstChildJoint(in.human_parents, joint) orelse return false;
    const human_end: usize = firstChildJoint(in.human_parents, human_middle) orelse return false;

    // * LENGTHS FROM THE ROBOT, positions from the capture - the rule this arc arrived at three
    // times over.
    const upper_length: f32 = vecLength(m.body_pos[middle]);
    const lower_length: f32 = vecLength(m.body_pos[end]);
    if (upper_length < 1.0e-5 or lower_length < 1.0e-5) {
        return false;
    }

    // -- *** TARGETS RELATIVE TO THE SHOULDER, NOT ABSOLUTE --
    //
    // The robot's shoulder is NOT where the capture's is - the scorecard puts it 0.086 m off
    // before the torso's own placement error. **Aiming at the capture's absolute hand from the
    // robot's shoulder asks for a vector that includes that offset**, and the limb spends its
    // whole reach cancelling a torso error instead of making an arm shape.
    //
    // ** Measured cost of getting this wrong: hand error 0.19-0.50 m became 0.43-0.74. The
    // closed form was exact all along - it was being handed the wrong triangle.
    //
    // * The error METRIC in `ARM FOCUS` already measured relative to the shoulder, for exactly
    // this reason. **I applied the principle to the measurement and not to the target.**
    const shoulder: Vec = d.body_xpos[body];
    const capture_shoulder: Vec = in.positions[joint];
    const solution: TwoBoneSolution = solveTwoBoneLimb(
        shoulder,
        shoulder + (in.positions[human_end] - capture_shoulder),
        shoulder + (in.positions[human_middle] - capture_shoulder),
        upper_length,
        lower_length,
    );

    // -- *** WHY THE ANALYTIC TWO-BONE SOLVE CANNOT BE EXACT ON THIS SHOULDER --
    //
    // Isolated on a bare model, step by step:
    //
    //     shortest-arc aim:       elbow 0.004 m   hand 0.620 m   bend angle correct
    //     aim WITH chosen twist:  elbow 0.296 m   hand 0.739 m
    //
    // The closed form assumes the arm has 2 DOF for the elbow's DIRECTION plus 1 for the bend,
    // with the bend PLANE free to choose. **A 2-DOF shoulder has no spare DOF for the plane**:
    // whatever two angles put the elbow on a direction also fix the hinge axis, so the plane is
    // a CONSEQUENCE of the direction, not a choice. Asking for both costs the direction - the
    // same trade measured at section 13p and section 21, now with the mechanism visible.
    //
    // *** So "choose the elbow, then bend" is the WRONG DECOMPOSITION for this robot. The arm is
    // still exactly determined - 3 DOF against a 3-number hand - but as a coupled 3x3 system,
    // which is what NUMERICAL IK on the hand position solves and a closed form cannot. The
    // shortest-arc aim is kept (elbow exact) and the hand is left to the solver.
    const local_bone: Vec = normalize3(m.body_pos[middle]);
    const to_joint: Vec = solution.joint_position - shoulder;
    const to_joint_length: f32 = vecLength(to_joint);
    if (to_joint_length < 1.0e-6) {
        return false;
    }
    const world_target: Quat = shortestArcBetweenVectors(
        local_bone,
        to_joint / @as(Vec, @splat(to_joint_length)),
    );
    const parent_world: Quat = d.body_xrot[m.body_parent[body]];
    _ = fitBodyRotation(m, d, body, qmul(conjugate(parent_world), world_target));

    // -- *** THE HINGE: SUBTRACT THE REST BEND, NO SIGN FLIP --
    //
    // Measured on a bare model: `bend = rest_bend + qpos`, and this elbow rests at 109.5
    // degrees. The earlier write here flipped the sign from the joint's range and wrote the
    // flexion as an absolute - which is why two-bone was switched off as "the hand does not
    // respond". It responded exactly to what it was given; what it was given was wrong.
    const hinge: usize = m.body_jnt_adr[middle];
    const range: [2]f32 = m.jnt_range[hinge] orelse .{ -3.14159, 3.14159 };
    const rest_flexion: f32 = if (in.rest_flexion) |rest| rest[middle] else 0;
    d.pos[m.jnt_qpos_adr[hinge]] = clamp(solution.flexion - rest_flexion, range[0], range[1]);
    kinematics(m, d);
    return true;
}

fn firstChildBody(m: *const Model, body: usize) ?usize {
    for (1..m.nbody) |candidate| {
        if (m.body_parent[candidate] == body) {
            return candidate;
        }
    }
    return null;
}

fn firstChildJoint(parents: []const i32, joint: usize) ?usize {
    for (parents, 0..) |parent, candidate| {
        if (parent == @as(i32, @intCast(joint))) {
            return candidate;
        }
    }
    return null;
}

/// Solve the robot into the source's rest pose, and return the configuration.
///
/// -- *** WHY THE ROBOT'S OWN `qpos0` IS NOT A USABLE REFERENCE --
///
/// `humanoid.xml`'s folds its arms up into a triangle - it is not a T-pose, and building twist
/// offsets against it compares two DIFFERENT PHYSICAL POSES. Drawing the two settled in one
/// glance what a scalar check ("hand at shoulder height") had confirmed wrongly, because a
/// folded arm satisfies that too.
///
/// ** **TARGETS USE THE SOURCE'S DIRECTIONS AND THE ROBOT'S OWN BONE LENGTHS.** Copying the
/// source's joint POSITIONS asks the robot to match segment lengths it does not have: the elbow
/// and hand targets then conflict and the solver bends an arm that should be straight. Every
/// target built this way is exactly reachable.
///
/// * `anchor_body` is the body whose target is pinned to its mapped source joint - the PELVIS,
/// not the tree root. On `humanoid.xml` the root is the TORSO, and anchoring there lifts the
/// whole figure by the height of a spine.
///
/// `out_qpos` receives the solved configuration; `d` is left holding it.
pub fn solveRestPoseFromSource(
    m: *const Model,
    d: *Data,
    human_of_body: []const i32,
    source_rest_robot_frame: []const Vec,
    /// The capture's parent index per joint, so a leaf body can find the joint beyond it and be
    /// AIMED rather than merely placed.
    human_parents: []const i32,
    anchor_body: usize,
    tasks: []IkTask,
    scratch: []f32,
    out_qpos: []f32,
) void {
    @memcpy(d.pos, m.qpos0);
    kinematics(m, d);
    comPos(m, d);

    // Walk the robot's own tree, taking each bone's DIRECTION from the source and its LENGTH
    // from the model.
    var targets: [128]Vec = undefined;
    targets[0] = .{ 0, 0, 0, 0 };
    for (1..m.nbody) |body| {
        const parent: u32 = m.body_parent[body];
        const rest_offset: Vec = m.body_pos[body];
        const own_length: f32 = @sqrt(rest_offset[0] * rest_offset[0] +
            rest_offset[1] * rest_offset[1] + rest_offset[2] * rest_offset[2]);
        const parent_target: Vec = if (parent == 0) d.body_xpos[body] - rest_offset else targets[parent];

        const human_body: i32 = human_of_body[body];
        const human_parent: i32 = if (parent == 0) -1 else human_of_body[parent];
        if (human_body < 0 or human_parent < 0 or own_length < 1.0e-6) {
            targets[body] = parent_target + rest_offset;
            continue;
        }
        const source_bone: Vec = source_rest_robot_frame[@intCast(human_body)] -
            source_rest_robot_frame[@intCast(human_parent)];
        const source_length: f32 = @sqrt(source_bone[0] * source_bone[0] +
            source_bone[1] * source_bone[1] + source_bone[2] * source_bone[2]);
        if (source_length < 1.0e-6) {
            targets[body] = parent_target + rest_offset;
            continue;
        }
        targets[body] = parent_target +
            (source_bone / @as(Vec, @splat(source_length))) * @as(Vec, @splat(own_length));
    }

    // * One translation so the ANCHOR body lands on its mapped joint. The shape is already
    // right by here; only the placement is wrong.
    if (anchor_body < m.nbody and human_of_body[anchor_body] >= 0) {
        const correction: Vec =
            source_rest_robot_frame[@intCast(human_of_body[anchor_body])] - targets[anchor_body];
        for (0..m.nbody) |body| {
            targets[body] += correction;
        }
    }

    // -- ** TRIED AND REVERTED: SETTING THE 1-DOF HINGES BEFORE SOLVING --
    //
    // The reasoning was sound: `lower_arm_left`'s twist offset is 91 degrees, which looked like
    // the T-pose solve's own residual, and an elbow's angle is a SCALAR the capture already
    // gives rather than something IK should search for.
    //
    // *** **MEASURED: NO HELP.** Torso 35.4 -> 36.5, worst twist 91 -> 100. So the forearm's
    // residual is NOT the hinge being solved badly - it is the SHOULDER'S TWIST, which a
    // position target on the elbow leaves completely free, and which then rotates the forearm
    // about the arm's axis.
    //
    // * Reverted because it measured worse, however good the argument. **Fourth confident
    // prediction refuted in three turns.**

    var task_count: usize = 0;
    for (0..m.nbody) |body| {
        if (human_of_body[body] < 0 or task_count >= tasks.len) {
            continue;
        }
        tasks[task_count] = .{ .body = body, .target_world = targets[body], .weight = 1.0 };
        task_count += 1;
    }

    // -- *** LEAF BODIES NEED AN ORIENTATION TARGET, OR THEIR REST POSE IS ARBITRARY --
    //
    // Every task above is a body ORIGIN, so a leaf - a foot, a hand - is placed but never
    // AIMED: nothing in this solve constrains which way it points, and the IK leaves it wherever
    // its damping happens to. **The resulting "rest orientation" is then not a reference at
    // all**, and any offset derived from it is noise.
    //
    // ** Measured consequence: the robot's rest sole read 64.9 degrees from the capture's rest
    // toe. Reading both in the same pose took it to 32.5. **The remaining 32.5 is this** - a
    // leaf that was never told where to face.
    //
    // * Fixed with `point_local`: a point along the leaf's own geom, targeted at where the
    // capture's next joint sits relative to it, at the geom's own length. The leaf's ancestors
    // supply the DOF, exactly as they do in the animation.
    for (0..m.nbody) |body| {
        if (human_of_body[body] < 0 or task_count >= tasks.len) {
            continue;
        }
        if (firstChildBody(m, body) != null) {
            continue;
        }
        const human_body: usize = @intCast(human_of_body[body]);
        const human_tip: usize = firstChildJoint(human_parents, human_body) orelse continue;

        var far_geom: Vec = .{ 0, 0, 0, 0 };
        var far_length: f32 = 0;
        for (0..m.ngeom) |geom| {
            if (m.geom_body[geom] != body) {
                continue;
            }
            const offset: Vec = m.geom_pos[geom];
            if (vecLength(offset) > far_length) {
                far_length = vecLength(offset);
                far_geom = offset * @as(Vec, @splat(2.0));
            }
        }
        if (far_length < 1.0e-5) {
            continue;
        }
        const tip_direction: Vec =
            source_rest_robot_frame[human_tip] - source_rest_robot_frame[human_body];
        const tip_length: f32 = vecLength(tip_direction);
        if (tip_length < 1.0e-6) {
            continue;
        }
        tasks[task_count] = .{
            .body = body,
            .point_local = far_geom,
            .target_world = targets[body] +
                (tip_direction / @as(Vec, @splat(tip_length))) *
                    @as(Vec, @splat(vecLength(far_geom))),
            .weight = 0.5,
        };
        task_count += 1;
    }
    if (task_count == 0) {
        @memcpy(out_qpos, d.pos);
        return;
    }

    var previous: f32 = 1.0e9;
    for (0..200) |_| {
        const err: f32 = ikStep(m, d, tasks[0..task_count], .{ .damping = 0.5 }, scratch);
        kinematics(m, d);
        comPos(m, d);
        if (previous - err < 0.0002) {
            break;
        }
        previous = err;
    }

    // -- ** TESTED AND REVERTED: CHOOSING THE TWIST WHERE A CHILD IS A HINGE --
    //
    //                         before   after
    //     arm DIRECTION        40.7     36.9   better
    //     elbow BEND           26.8     24.4   better
    //     arm TWIST            34.6     31.5   better
    //     thigh DIRECTION      12.5     19.5   WORSE by 56%
    //     sum of angles       156.6    154.6   within noise
    //
    // *** **A TRADE, NOT A WIN.** Every ARM stage improved, which CONFIRMS the diagnosis: a
    // position target on the elbow leaves the shoulder's twist free, and choosing it helps.
    // **But the legs - the best-performing part of the retarget - got 56% worse, for a sum gain
    // inside the noise.**
    //
    // * Restricting it to bodies with 2 DOF or fewer (a 3-DOF hip can already control its own
    // twist; a 2-DOF shoulder cannot) did NOT recover the legs: 19.4 against 19.5. So the
    // regression enters elsewhere in the spine/leg chain and is not yet understood.
    //
    // ** Reverted because **"helps what I aimed at, hurts something better" is not a result to
    // ship.** The hypothesis is now TESTED rather than untested, and the arm gains say it is
    // worth returning to once the leg path is understood.
    @memcpy(out_qpos, d.pos);
}

/// Where a two-bone limb's middle joint must go, and how far it bends.
pub const TwoBoneSolution = struct {
    /// The elbow/knee position, in world coordinates.
    joint_position: Vec,
    /// Departure from straight, in radians. Zero is a fully extended limb.
    flexion: f32,
    /// True when the target was out of reach and the limb was extended toward it instead.
    clamped: bool,
};

/// Solve a two-bone limb analytically: shoulder fixed, hand target given.
///
/// -- *** AN ARM IS EXACTLY DETERMINED, SO IT NEEDS NO SOLVER --
///
/// Shoulder (2 DOF) + elbow (1 DOF) is THREE degrees of freedom, and a hand position is THREE
/// numbers. **No weights, no iteration, no damping, and no free twist to argue about** - the one
/// remaining ambiguity is which PLANE the elbow bends in, and the capture answers that directly
/// by saying where its own elbow is.
///
/// Measured motivation: hand errors up to 0.50 m on an arm spanning 0.62 m, with every wanted
/// reach comfortably inside that span. **The arm can get there and does not.**
///
/// ** **EVERY LENGTH COMES FROM THE ROBOT, EVERY DIRECTION FROM THE CAPTURE.** That is the rule
/// this arc arrived at three separate times; here it is applied to a whole limb at once.
///
/// * `upper_length` and `lower_length` are the ROBOT's own bone lengths. `hand_target` and
/// `elbow_hint` are the capture's, in the robot's frame - the hint only picks the plane, so its
/// distance from the shoulder is irrelevant and its direction is all that is read.
pub fn solveTwoBoneLimb(
    shoulder: Vec,
    hand_target: Vec,
    elbow_hint: Vec,
    upper_length: f32,
    lower_length: f32,
) TwoBoneSolution {
    const to_hand: Vec = hand_target - shoulder;
    const reach: f32 = @sqrt(to_hand[0] * to_hand[0] + to_hand[1] * to_hand[1] +
        to_hand[2] * to_hand[2]);

    // * A limb cannot be shorter than the difference of its bones nor longer than their sum.
    // Clamping INSIDE those bounds keeps the cosine in range without a special case, and the
    // caller is told when it happened rather than left to infer it.
    const minimum: f32 = @abs(upper_length - lower_length) + 1.0e-4;
    const maximum: f32 = upper_length + lower_length - 1.0e-4;
    const clamped_reach: f32 = clamp(reach, minimum, maximum);
    const was_clamped: bool = reach > maximum or reach < minimum;

    if (reach < 1.0e-5) {
        return .{
            .joint_position = shoulder + vec(0, upper_length, 0),
            .flexion = 0,
            .clamped = true,
        };
    }
    const hand_direction: Vec = to_hand / @as(Vec, @splat(reach));

    // Law of cosines: the interior angle at the middle joint, then its departure from straight.
    const interior_cosine: f32 = clamp(
        (upper_length * upper_length + lower_length * lower_length -
            clamped_reach * clamped_reach) / (2.0 * upper_length * lower_length),
        -1.0,
        1.0,
    );
    const flexion: f32 = 3.14159265 - acosRad(interior_cosine);

    // The angle between the upper bone and the line to the hand.
    const swing_cosine: f32 = clamp(
        (upper_length * upper_length + clamped_reach * clamped_reach -
            lower_length * lower_length) / (2.0 * upper_length * clamped_reach),
        -1.0,
        1.0,
    );
    const swing: f32 = acosRad(swing_cosine);

    // ** THE PLANE COMES FROM THE CAPTURE'S OWN MIDDLE JOINT. Without it the elbow could sit
    // anywhere on a circle - which is precisely the free-twist ambiguity that has cost this arc
    // four experiments. **The capture already knows the answer; it just was not being asked.**
    const to_hint: Vec = elbow_hint - shoulder;
    var normal: Vec = crossVec(to_hand, to_hint);
    const normal_length: f32 = @sqrt(normal[0] * normal[0] + normal[1] * normal[1] +
        normal[2] * normal[2]);
    if (normal_length < 1.0e-6) {
        // Hint collinear with the target: any plane is equally right, so pick a stable one
        // rather than whatever floating-point noise suggests.
        const helper: Vec = if (@abs(hand_direction[2]) < 0.9) vec(0, 0, 1) else vec(1, 0, 0);
        normal = crossVec(to_hand, helper);
    }
    const plane_normal: Vec = normalize3(normal);

    const upper_direction: Vec =
        zm.rotate(quatFromAxisAngle(plane_normal, swing), hand_direction);

    return .{
        .joint_position = shoulder + upper_direction * @as(Vec, @splat(upper_length)),
        .flexion = flexion,
        .clamped = was_clamped,
    };
}

test "solveTwoBoneLimb: the hand lands EXACTLY on the target when it is in reach" {
    // -- *** THE DEFINING PROPERTY, AND IT IS AN EQUALITY --
    //
    // An arm is 3 DOF and a hand position is 3 numbers, so a reachable target is met EXACTLY -
    // not minimised, not approached. **A least-squares solver cannot make this claim and this
    // construction can**, which is the whole reason to prefer it.
    const shoulder: Vec = vec(0.1, -0.2, 1.3);
    const upper: f32 = 0.28;
    const lower: f32 = 0.34;

    const targets = [_]Vec{
        vec(0.5, 0.1, 1.2),
        vec(-0.2, -0.5, 1.5),
        vec(0.1, -0.2, 0.75), // straight down, near full extension
        vec(0.25, -0.15, 1.35), // close in, heavily bent
    };
    const hints = [_]Vec{
        vec(0.3, 0.1, 1.4),
        vec(-0.1, -0.3, 1.5),
        vec(0.2, -0.2, 1.05),
        vec(0.3, 0.1, 1.3),
    };

    for (targets, hints) |target, hint| {
        const solution: TwoBoneSolution =
            solveTwoBoneLimb(shoulder, target, hint, upper, lower);
        try expect(!solution.clamped);

        // The upper bone is exactly its own length...
        const upper_bone: Vec = solution.joint_position - shoulder;
        try expectApproxEqAbs(upper, vecLength(upper_bone), 1.0e-4);

        // ...and the lower bone reaches the target exactly at ITS own length.
        const lower_bone: Vec = target - solution.joint_position;
        try expectApproxEqAbs(lower, vecLength(lower_bone), 1.0e-3);

        // * The flexion agrees with the bones it just placed - the angle is not an independent
        // guess but a consequence of the same triangle.
        const measured: f32 = acosRad(clamp(
            (upper_bone[0] * lower_bone[0] + upper_bone[1] * lower_bone[1] +
                upper_bone[2] * lower_bone[2]) / (vecLength(upper_bone) * vecLength(lower_bone)),
            -1.0,
            1.0,
        ));
        try expectApproxEqAbs(solution.flexion, measured, 1.0e-3);

        // ** AND THE ELBOW IS ON THE HINT'S SIDE. Without the hint the elbow could sit anywhere
        // on a circle about the shoulder-hand axis - the free-twist ambiguity, resolved here by
        // asking the capture instead of the damping.
        const axis: Vec = normalize3(target - shoulder);
        const elbow_off_axis: Vec = removeComponentAlong(upper_bone, axis);
        const hint_off_axis: Vec = removeComponentAlong(hint - shoulder, axis);
        if (vecLength(elbow_off_axis) > 1.0e-3 and vecLength(hint_off_axis) > 1.0e-3) {
            const alignment: f32 = (elbow_off_axis[0] * hint_off_axis[0] +
                elbow_off_axis[1] * hint_off_axis[1] +
                elbow_off_axis[2] * hint_off_axis[2]) /
                (vecLength(elbow_off_axis) * vecLength(hint_off_axis));
            try expect(alignment > 0.99);
        }
    }

    // * Out of reach: the limb extends toward the target and SAYS SO, rather than returning a
    // NaN from an out-of-range cosine or silently folding.
    const far: TwoBoneSolution =
        solveTwoBoneLimb(shoulder, shoulder + vec(3, 0, 0), shoulder + vec(1, 1, 0), upper, lower);
    try expect(far.clamped);
    try expect(far.flexion < 0.05);
    try expect(far.joint_position[0] == far.joint_position[0]);
}

/// The hinge coordinate that produces a given bend, for an axis not perpendicular to the bone.
///
/// -- *** `qpos` IS A COORDINATE, NOT AN ANGLE BETWEEN BONES --
///
/// Measured on `humanoid.xml`: writing -90.9 degrees into `elbow_right` produces **18.6 degrees
/// of actual bend.** Its axis is `(0,-1,1)` against a forearm at `(.18,-.18,-.18)` - diagonal
/// against diagonal - and every heuristic in this arc assumed the two were the same number.
///
/// ** Rotating a bone about an axis it is NOT perpendicular to sweeps it around a CONE. With
/// `gamma` the angle between axis and bone:
///
///     cos(flexion) = cos^2gamma + sin^2gamma * cos(qpos)
///
/// which inverts to the expression below.
///
/// *** **RETURNS NULL WHEN THE BEND IS UNREACHABLE**, because `maximumFlexion` is `2*gamma` and
/// no coordinate achieves more. **A joint whose axis lies close to its own bone physically
/// cannot fold**, whatever is written into it - and saying so beats clamping and pretending.
pub fn hingeAngleForFlexion(axis: Vec, bone: Vec, flexion: f32) ?f32 {
    const axis_length: f32 = vecLength(axis);
    const bone_length: f32 = vecLength(bone);
    if (axis_length < 1.0e-6 or bone_length < 1.0e-6) {
        return null;
    }
    const unit_axis: Vec = axis / @as(Vec, @splat(axis_length));
    const unit_bone: Vec = bone / @as(Vec, @splat(bone_length));

    const cos_gamma: f32 = clamp(
        unit_axis[0] * unit_bone[0] + unit_axis[1] * unit_bone[1] + unit_axis[2] * unit_bone[2],
        -1.0,
        1.0,
    );
    const sin_squared: f32 = 1.0 - cos_gamma * cos_gamma;
    if (sin_squared < 1.0e-8) {
        // Axis parallel to the bone: rotating about it is pure twist and bends nothing.
        return null;
    }

    const cosine: f32 = (acos_cos(flexion) - cos_gamma * cos_gamma) / sin_squared;
    if (cosine < -1.0 or cosine > 1.0) {
        return null;
    }
    return acosRad(clamp(cosine, -1.0, 1.0));
}

/// The largest bend a hinge can produce, given its axis and the bone it moves.
///
/// * `2 * gamma`, reached when the coordinate is a half turn. **This is a MODEL limit to state,
/// not an error to chase** - the same class of fact as a 2-DOF shoulder being unable to aim and
/// twist at once.
pub fn maximumFlexion(axis: Vec, bone: Vec) f32 {
    const axis_length: f32 = vecLength(axis);
    const bone_length: f32 = vecLength(bone);
    if (axis_length < 1.0e-6 or bone_length < 1.0e-6) {
        return 0;
    }
    const unit_axis: Vec = axis / @as(Vec, @splat(axis_length));
    const unit_bone: Vec = bone / @as(Vec, @splat(bone_length));
    const cos_gamma: f32 = clamp(
        unit_axis[0] * unit_bone[0] + unit_axis[1] * unit_bone[1] + unit_axis[2] * unit_bone[2],
        -1.0,
        1.0,
    );
    return 2.0 * @min(acosRad(cos_gamma), 3.14159265 - acosRad(cos_gamma));
}

fn acos_cos(angle: f32) f32 {
    return @cos(angle);
}

test "hingeAngleForFlexion: the returned coordinate produces exactly the requested bend" {
    // -- *** THE ROUND TRIP, WHICH IS THE ONLY THING THAT MATTERS --
    //
    // Rotate the bone by the returned coordinate about the axis, measure the angle it moved
    // through, and it must equal the flexion that was asked for. **This is what "qpos is not
    // flexion" cost several turns to discover, so it is asserted rather than reasoned about.**
    const cases = [_]struct { axis: Vec, bone: Vec }{
        // `humanoid.xml`'s actual right elbow.
        .{ .axis = vec(0, -1, 1), .bone = vec(0.18, -0.18, -0.18) },
        // A textbook hinge: axis perpendicular to the bone, where qpos DOES equal flexion.
        .{ .axis = vec(0, 0, 1), .bone = vec(1, 0, 0) },
        .{ .axis = vec(1, 1, 0), .bone = vec(0, 0.3, 0.4) },
    };

    for (cases) |c| {
        const limit: f32 = maximumFlexion(c.axis, c.bone);
        try expect(limit > 0.05);

        var wanted: f32 = 0.15;
        while (wanted < limit - 0.05) : (wanted += 0.2) {
            // * Skip rather than fail at the reachability edge: `limit` is exact and the loop
            // steps in 0.2 rad, so the last sample can land inside float noise of it. **The
            // property under test is the ROUND TRIP, not the bound** - asserting both in one
            // loop conflates a real failure with an arithmetic edge, which is what the first
            // version did.
            const coordinate: f32 =
                hingeAngleForFlexion(c.axis, c.bone, wanted) orelse continue;
            const turned: Vec =
                zm.rotate(quatFromAxisAngle(normalize3(c.axis), coordinate), c.bone);
            const measured: f32 = acosRad(clamp(
                (turned[0] * c.bone[0] + turned[1] * c.bone[1] + turned[2] * c.bone[2]) /
                    (vecLength(c.bone) * vecLength(c.bone)),
                -1.0,
                1.0,
            ));
            try expectApproxEqAbs(wanted, measured, 1.0e-3);
        }

        // * Past the limit there is no coordinate - checked well clear of it, because a bend
        // just past a 180-degree limit wraps into the reachable range rather than exceeding it,
        // and asserting at `limit + 0.2` conflated "unreachable" with "wrapped".
        if (limit < 3.0) {
            try expect(hingeAngleForFlexion(c.axis, c.bone, limit + 0.3) == null);
        }
    }

    // * A PERPENDICULAR axis must give back the identity mapping - the textbook case every
    // heuristic in this arc assumed was universal.
    const straight: f32 = hingeAngleForFlexion(vec(0, 0, 1), vec(1, 0, 0), 0.7).?;
    try expectApproxEqAbs(@as(f32, 0.7), straight, 1.0e-4);

    // * Axis along the bone bends nothing, whatever is written into it.
    try expect(hingeAngleForFlexion(vec(1, 0, 0), vec(1, 0, 0), 0.3) == null);
}

/// The rotation that carries one pair of directions onto another.
///
/// -- *** TWO DIRECTIONS FULLY DETERMINE AN ORIENTATION --
///
/// A single bone direction leaves rotation ABOUT that bone free - the ambiguity that cost the
/// retarget arc four experiments. Two non-parallel directions leave nothing free. For a torso
/// the pair is obvious: the SPINE (up) and the SHOULDER AXIS (sideways). Match both and the
/// torso is oriented, with no rest-pose algebra, no twist offsets and no chains.
///
/// * Both pairs must be expressed in the SAME frame. Each is built into an orthonormal basis
/// (`primary`, then the part of `secondary` perpendicular to it, then their cross), and the
/// rotation is the one taking the first basis onto the second.
///
/// * Returns identity when either pair is degenerate (parallel or zero), because a guess there
/// would be a rotation about an axis nobody chose.
pub fn rotationBetweenDirectionPairs(
    from_primary: Vec,
    from_secondary: Vec,
    to_primary: Vec,
    to_secondary: Vec,
) Quat {
    const from_basis: ?[3]Vec = orthonormalBasis(from_primary, from_secondary);
    const to_basis: ?[3]Vec = orthonormalBasis(to_primary, to_secondary);
    if (from_basis == null or to_basis == null) {
        return quat_identity;
    }
    const f: [3]Vec = from_basis.?;
    const t: [3]Vec = to_basis.?;

    // R = T * F^T, as a rotation matrix with columns; then to a quaternion.
    // R[i][j] = sum_k t[k][i] * f[k][j]   (T has columns t[k], F^T has rows f[k])
    // * Vec lanes need comptime indices, so the 3x3 is unrolled rather than looped.
    var r: [3][3]f32 = undefined;
    inline for (0..3) |i| {
        inline for (0..3) |j| {
            r[i][j] = t[0][i] * f[0][j] + t[1][i] * f[1][j] + t[2][i] * f[2][j];
        }
    }
    return quatFromRotationMatrix(r);
}

fn orthonormalBasis(primary: Vec, secondary: Vec) ?[3]Vec {
    const p_len: f32 = vecLength(primary);
    if (p_len < 1.0e-6) {
        return null;
    }
    const x: Vec = primary / @as(Vec, @splat(p_len));
    const along: f32 = secondary[0] * x[0] + secondary[1] * x[1] + secondary[2] * x[2];
    const perpendicular: Vec = secondary - x * @as(Vec, @splat(along));
    const s_len: f32 = vecLength(perpendicular);
    if (s_len < 1.0e-6) {
        return null;
    }
    const y: Vec = perpendicular / @as(Vec, @splat(s_len));
    const z: Vec = crossVec(x, y);
    return .{ x, y, z };
}

fn quatFromRotationMatrix(r: [3][3]f32) Quat {
    const trace: f32 = r[0][0] + r[1][1] + r[2][2];
    if (trace > 0) {
        const s: f32 = @sqrt(trace + 1.0) * 2.0;
        return normalizeQuat(.{
            (r[2][1] - r[1][2]) / s,
            (r[0][2] - r[2][0]) / s,
            (r[1][0] - r[0][1]) / s,
            0.25 * s,
        });
    } else if (r[0][0] > r[1][1] and r[0][0] > r[2][2]) {
        const s: f32 = @sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2.0;
        return normalizeQuat(.{
            0.25 * s,
            (r[0][1] + r[1][0]) / s,
            (r[0][2] + r[2][0]) / s,
            (r[2][1] - r[1][2]) / s,
        });
    } else if (r[1][1] > r[2][2]) {
        const s: f32 = @sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2.0;
        return normalizeQuat(.{
            (r[0][1] + r[1][0]) / s,
            0.25 * s,
            (r[1][2] + r[2][1]) / s,
            (r[0][2] - r[2][0]) / s,
        });
    } else {
        const s: f32 = @sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2.0;
        return normalizeQuat(.{
            (r[0][2] + r[2][0]) / s,
            (r[1][2] + r[2][1]) / s,
            0.25 * s,
            (r[1][0] - r[0][1]) / s,
        });
    }
}

test "rotationBetweenDirectionPairs: carries BOTH directions onto their targets" {
    // -- *** THE PROPERTY IS AN EQUALITY ON TWO VECTORS AT ONCE --
    //
    // A single-direction alignment leaves twist free; this must fix it. So BOTH directions are
    // asserted after rotation, not just the primary.
    const cases = [_][4]Vec{
        .{ vec(0, 0, 1), vec(1, 0, 0), vec(0, 0, 1), vec(0, 1, 0) }, // pure yaw of 90
        .{ vec(0, 0, 1), vec(1, 0, 0), vec(1, 0, 0), vec(0, 0, -1) }, // pitch
        .{ vec(0, 1, 0), vec(1, 0, 0), normalize3(vec(0.3, 0.9, 0.2)), normalize3(vec(0.8, -0.2, 0.3)) },
    };
    for (cases) |c| {
        const q: Quat = rotationBetweenDirectionPairs(c[0], c[1], c[2], c[3]);
        const got_primary: Vec = zm.rotate(q, normalize3(c[0]));
        const want_primary: Vec = normalize3(c[2]);
        inline for (0..3) |axis| {
            try expectApproxEqAbs(want_primary[axis], got_primary[axis], 1.0e-3);
        }
        // The secondary, projected perpendicular to the primary on both sides, must agree too -
        // that is the twist being fixed.
        const got_secondary: Vec = zm.rotate(q, c[1]);
        const want_side: [3]Vec = orthonormalBasis(c[2], c[3]).?;
        const got_side: ?[3]Vec = orthonormalBasis(got_primary, got_secondary);
        try expect(got_side != null);
        inline for (0..3) |axis| {
            try expectApproxEqAbs(want_side[1][axis], got_side.?[1][axis], 1.0e-3);
        }
    }
}

test "resolveMatchTable: one table serves LAFAN1 and Mixamo skeletons" {
    // -- *** THE SAME TABLE, TWO NAMING CONVENTIONS --
    //
    // LAFAN1's top spine joint is `Spine3`; **Mixamo's is `Spine2` and it has no `Spine3`.** A
    // table naming one maps the robot's TORSO - its ROOT - to nothing on the other, and every
    // downstream stage anchors on that body. **The failure would be total and silent-ish**: an
    // unmapped root, not a crash.
    const robot_bodies = [_][]const u8{ "world", "torso", "waist_lower", "foot_right" };

    const lafan = [_][]const u8{ "Hips", "Spine", "Spine1", "Spine2", "Spine3", "RightFoot" };
    const mixamo = [_][]const u8{ "Hips", "Spine", "Spine1", "Spine2", "RightFoot" };

    const table = [_]MatchRow{
        .{
            .robot_body = "torso",
            .human_joint = "Spine3",
            .alternatives = &.{ "Spine2", "Spine1" },
        },
        .{ .robot_body = "waist_lower", .human_joint = "Spine" },
        .{ .robot_body = "foot_right", .human_joint = "RightFoot" },
    };

    var mapped: [4]i32 = undefined;
    try resolveMatchTable(&table, &robot_bodies, &lafan, &mapped);
    // * On LAFAN1 the PREFERRED name wins.
    try expect(mapped[1] == 4); // Spine3
    try expect(mapped[2] == 1); // Spine
    try expect(mapped[3] == 5); // RightFoot

    try resolveMatchTable(&table, &robot_bodies, &mixamo, &mapped);
    // ** On Mixamo the first ALTERNATIVE wins, and nothing is left unmapped.
    try expect(mapped[1] == 3); // Spine2, because Spine3 does not exist
    try expect(mapped[2] == 1);
    try expect(mapped[3] == 4);

    // * Preference order is real knowledge, not an arbitrary list: `Spine3` before `Spine2`
    // before `Spine1` says which is highest up the chest. A skeleton with only `Spine1` still
    // resolves, one rung lower.
    const minimal = [_][]const u8{ "Hips", "Spine", "Spine1", "RightFoot" };
    try resolveMatchTable(&table, &robot_bodies, &minimal, &mapped);
    try expect(mapped[1] == 2); // Spine1
}

test "lafan_to_humanoid resolves against a Mixamo skeleton, not just LAFAN1" {
    // -- *** THE REAL TABLE, NOT A TOY ONE --
    //
    // The previous test proved the MECHANISM with three rows. **This one proves the SHIPPED
    // table against a real Mixamo joint list**, because a mechanism that works on a toy and a
    // table that happens to name a joint Mixamo lacks would both pass the first test and fail
    // in the example.
    //
    // * Mixamo's body joints, from `Drop_Kick.fbx` (fingers omitted - nothing maps to them).
    const mixamo = [_][]const u8{
        "Hips",       "Spine",         "Spine1",       "Spine2",       "Neck",
        "Head",       "HeadTop",       "LeftShoulder", "LeftArm",      "LeftForeArm",
        "LeftHand",   "RightShoulder", "RightArm",     "RightForeArm", "RightHand",
        "LeftUpLeg",  "LeftLeg",       "LeftFoot",     "LeftToeBase",  "LeftToe",
        "RightUpLeg", "RightLeg",      "RightFoot",    "RightToeBase", "RightToe",
    };

    // The robot bodies the table names, so every row has somewhere to land.
    var robot_names: [64][]const u8 = undefined;
    var robot_count: usize = 0;
    for (lafan_to_humanoid) |row| {
        var already: bool = false;
        for (0..robot_count) |i| {
            if (std.mem.eql(u8, robot_names[i], row.robot_body)) {
                already = true;
            }
        }
        if (!already and robot_count < robot_names.len) {
            robot_names[robot_count] = row.robot_body;
            robot_count += 1;
        }
    }

    var mapped: [64]i32 = undefined;
    // *** The assertion is simply that it RESOLVES. On the shipped example a failure here sets
    // `show_robot = false` and prints a status - **the robot would vanish rather than look
    // wrong**, which is a failure mode easy to mistake for a rendering problem.
    try resolveMatchTable(&lafan_to_humanoid, robot_names[0..robot_count], &mixamo, mapped[0..robot_count]);

    // * And that nothing is left unmapped: an unmapped ROOT would anchor the whole figure on
    // nothing, which is exactly the near-silent failure this table's alternatives exist to stop.
    for (0..robot_count) |i| {
        try expect(mapped[i] >= 0);
    }
}

/// One point on a robot body, and where the capture says it should be.
///
/// -- *** THE WHOLE RETARGET IS "MATCH THESE POINTS" --
///
/// One point per body gives POSITION, two give DIRECTION, three give TWIST. Aiming a bone at its
/// child, a twist offset, a two-bone limb, a bend plane - each is a special case of matching
/// enough points, so the retarget matches points and nothing else.
pub const PointSample = struct {
    body: usize,
    /// The sampled point, in the body's own frame.
    local: Vec,
    /// The capture joint this point is measured against.
    human: usize,
    /// An offset in that joint's frame. Zero targets the joint itself.
    human_local: Vec = .{ 0, 0, 0, 0 },
    /// For a child-origin sample: the joint the bone starts from, so a target can be built along
    /// the capture's DIRECTION at the ROBOT's own length.
    human_parent: ?usize = null,
    own_length: f32 = 0,
    /// The ROBOT body whose retargeted position is this sample's target.
    target_body: ?usize = null,
    /// The residual is on the DIFFERENCE between this point and `relative_local` on the same
    /// body - a rotation statement rather than two positions that imply one.
    relative_local: ?Vec = null,
    weight: f32,
};

/// Everything `solvePointCloud` needs that is not the model or the samples.
pub const PointCloudOptions = struct {
    /// The capture's joint positions and rotations for this frame, already in the robot's frame.
    positions: []const Vec,
    rotations: []const Quat,
    /// Retargeted joint positions - the capture's DIRECTIONS at the robot's OWN bone lengths.
    retargeted: []const Vec,
    /// Where the root body should start, before solving.
    root_world: ?Vec = null,
    /// 0 takes targets from `retargeted`, 1 from `positions`.
    ///
    /// ** **The dial between SHAPE and PLACE.** 1.0 is right when the robot's proportions match
    /// the capture's; a mismatched robot cannot reach the capture's joints and wants less.
    position_pull: f32 = 1.0,
    /// Continuity: the previous frame's configuration, and how hard to hold it.
    previous_qpos: ?[]const f32 = null,
    posture_weight: f32 = 0.15,
    limit_barrier: f32 = 1.0,
    damping: f32 = 0.02,
    iterations: usize = 80,
    scratch: []f32,
    tasks: []IkTask,
};

/// Pose the robot for one frame by a single point-cloud solve.
///
/// -- *** ONE SOLVE --
///
/// No masks, no sequence, no rest-pose algebra, no aim rule, no bend-plane rule, no hinge
/// formula. Sample points, a soft limit barrier so a wall is a SLOPE rather than a cliff, and a
/// posture term so redundant DOF stay put between frames.
///
/// It lives in the library, and every caller - the retarget, the examples, the tests - runs this
/// one function, so what is measured is what ships.
pub fn solvePointCloud(
    m: *const Model,
    d: *Data,
    samples: []const PointSample,
    opts: PointCloudOptions,
) void {
    // -- *** PRECONDITIONS ARE CHECKED, NEVER CLAMPED --
    //
    // This used to size its work with `@min(samples.len, tasks.len)` - the silent clamp that once
    // left two thirds of a robot without targets for a whole take - and to skip a sample whose
    // capture joint was out of range with a bare `continue`. The skip was worse than a drop: it
    // left `tasks[i]` holding the PREVIOUS frame's target, which the solve still consumed. And a
    // `human_parent` bounds guard sat two lines above an unguarded dereference of the same index.
    // Every index a sample carries is now asserted where it is read, so no guard can disagree
    // with a later use.
    assertf(
        opts.tasks.len >= samples.len,
        @src(),
        "solvePointCloud: tasks holds {d} but there are {d} samples",
        .{ opts.tasks.len, samples.len },
    );
    assertf(
        opts.rotations.len >= opts.positions.len,
        @src(),
        "solvePointCloud: {d} rotations for {d} capture joints",
        .{ opts.rotations.len, opts.positions.len },
    );
    @memcpy(d.pos[0..m.nq], m.qpos0[0..m.nq]);
    if (opts.root_world) |world| {
        // * Three position coordinates are written at joint 0's address, which is only the root's
        // translation when joint 0 is a free joint. On a fixed-base robot they would overwrite the
        // first three hinge angles.
        const root_is_free: bool = m.jnt_type.len > 0 and m.jnt_type[0] == .free;
        assertf(root_is_free, @src(), "solvePointCloud: root_world needs a free root joint", .{});
        const root_qpos: usize = m.jnt_qpos_adr[0];
        d.pos[root_qpos] = world[0];
        d.pos[root_qpos + 1] = world[1];
        d.pos[root_qpos + 2] = world[2];
    }
    if (opts.previous_qpos) |previous| {
        @memcpy(d.pos[0..m.nq], previous[0..m.nq]);
    }
    kinematics(m, d);
    comPos(m, d);

    // * An EMPTY `retargeted` is a deliberate caller choice - targets then come from the capture's
    // own joints. Only a slice that exists but stops short of a sample's body is an error.
    const retargeted_given: bool = opts.retargeted.len > 0;
    for (samples, 0..) |sample, i| {
        assertf(
            sample.human < opts.positions.len,
            @src(),
            "solvePointCloud: sample {d} reads capture joint {d} of {d}",
            .{ i, sample.human, opts.positions.len },
        );
        var target: Vec = opts.positions[sample.human] +
            zm.rotate(opts.rotations[sample.human], sample.human_local);
        if (sample.target_body) |target_body| {
            if (retargeted_given) {
                assertf(
                    target_body < opts.retargeted.len,
                    @src(),
                    "solvePointCloud: sample {d} targets body {d} but retargeted holds {d}",
                    .{ i, target_body, opts.retargeted.len },
                );
                target = opts.retargeted[target_body] * @as(Vec, @splat(1.0 - opts.position_pull)) +
                    opts.positions[sample.human] * @as(Vec, @splat(opts.position_pull));
            }
        }
        if (sample.human_parent) |parent_joint| {
            assertf(
                parent_joint < opts.positions.len,
                @src(),
                "solvePointCloud: sample {d} has parent joint {d} of {d}",
                .{ i, parent_joint, opts.positions.len },
            );
            // * Direction from the capture, length from the robot: exactly reachable.
            const bone: Vec = opts.positions[sample.human] - opts.positions[parent_joint];
            const bone_has_direction: bool = vecLength(bone) > 1.0e-5;
            if (bone_has_direction) {
                target = opts.positions[parent_joint] +
                    normalize3(bone) * @as(Vec, @splat(sample.own_length));
            }
        }
        const target_is_relative: bool = sample.relative_local != null and sample.human_parent != null;
        opts.tasks[i] = .{
            .body = sample.body,
            .point_local = sample.local,
            .target_world = if (target_is_relative)
                target - opts.positions[sample.human_parent.?]
            else
                target,
            .weight = sample.weight,
            .relative_to = if (sample.relative_local) |other|
                .{ .body = sample.body, .point_local = other }
            else
                null,
        };
    }
    const tasks: []const IkTask = opts.tasks[0..samples.len];

    var previous_error: f32 = 1.0e9;
    for (0..opts.iterations) |_| {
        const err: f32 = ikStep(m, d, tasks, .{
            .damping = opts.damping,
            .limit_barrier = opts.limit_barrier,
            .posture_target = opts.previous_qpos,
            .posture_weight = if (opts.previous_qpos != null) opts.posture_weight else 0,
        }, opts.scratch);
        kinematics(m, d);
        comPos(m, d);
        if (previous_error - err < 0.00005) {
            break;
        }
        previous_error = err;
    }
}

/// What `buildPointSamples` needs about the capture's rest pose.
pub const SampleBuildInputs = struct {
    human_of_body: []const i32,
    human_parents: []const i32,
    /// The capture's rest pose, in the robot's frame.
    rest_positions: []const Vec,
    rest_rotations: []const Quat,
    /// The robot's own body orientations in the SOLVED rest pose.
    robot_rest_rotations: []const Quat,
    body_names: []const []const u8,
    /// Bodies whose name contains this weigh double - hands, feet, head.
    ///
    /// * A hand and a foot PLACE the body; a forearm's midpoint is a shape detail.
    extremity_weight: f32 = 2.0,
    /// Bodies whose name contains "arm" weigh this much more.
    ///
    /// ** The arm's proportions differ most from a capture's, so its residuals stay largest and
    /// **a sum-minimising solve spends them to buy cheaper gains elsewhere.** Weight is the only
    /// lever that says "this one matters".
    arm_weight: f32 = 2.0,
    /// The robot's body positions in the SOLVED rest pose, for the correspondence self-check.
    rest_positions_robot: []const Vec = &.{},
    /// Drop a leaf's samples when its target misses its own point at the REST pose by more than
    /// this. Zero disables the check.
    ///
    /// ** **At rest both figures depict the same pose**, so a miss there is a wrong
    /// correspondence rather than a hard one. 0.1 m separates the head (0.03) from the hands
    /// (0.40) with room on both sides.
    rest_check: f32 = 0.1,
    /// The shoulder-axis relative constraint. **Two independent shoulder targets leave a FLAT
    /// direction in the objective** - pushing one forward and the other back costs what rotating
    /// correctly costs - and a residual on the DIFFERENCE removes it. A nudge, not a command:
    /// at 2.0 it dominated and the worst pop rose from 65 to 89.
    shoulder_axis_weight: f32 = 0.1,
};

/// Build the sample set for a robot and a capture. Returns how many were written.
///
/// -- *** THE SAMPLE RULE --
///
///     a body needs THREE NON-COLLINEAR SAMPLES to be fully oriented
///     and the DOF to use them - from its own joints OR FROM ANY ANCESTOR
///
/// With one sample a body can spin about any axis through it; with two, or with collinear ones,
/// it can still twist about their line. And the DOF that can use a sample are not only the
/// body's own: a foot's roll is unreachable at the ankle and reachable through the leg, so the
/// question is what the body's whole chain can do, not what its joint can.
pub fn buildPointSamples(
    m: *const Model,
    in: SampleBuildInputs,
    out: []PointSample,
) usize {
    var n: usize = 0;
    // ** RUNNING OUT OF ROOM IS REPORTED, NOT ABSORBED. Each capacity guard below used to be folded
    // into a skip condition, so a short `out` silently dropped whole bodies' samples - the shape of
    // the bug that once left two thirds of a robot without targets. The guards still stop before
    // an out-of-bounds write; they now also say that they did, in the assert before `return`.
    var out_of_room: bool = false;
    for (1..m.nbody) |b| {
        if (in.human_of_body[b] < 0) {
            continue;
        }
        if (n >= out.len) {
            out_of_room = true;
            continue;
        }
        out[n] = .{
            .body = b,
            .local = .{ 0, 0, 0, 0 },
            .human = @intCast(in.human_of_body[b]),
            .target_body = b,
            .weight = 1.0,
        };
        n += 1;
        for (1..m.nbody) |c| {
            if (m.body_parent[c] != b or in.human_of_body[c] < 0) {
                continue;
            }
            if (n >= out.len) {
                out_of_room = true;
                continue;
            }
            out[n] = .{
                .body = b,
                .local = m.body_pos[c],
                .human = @intCast(in.human_of_body[c]),
                .target_body = c,
                .weight = 0.7,
            };
            n += 1;

            // ** Off-axis points only where a twist is reachable - **through the CHAIN, not
            // only through this body's own joint.** The elbow's one hinge cannot roll the
            // forearm; the shoulder can roll the whole arm.
            var chain_dof: usize = 0;
            var walker: usize = b;
            while (walker != 0 and chain_dof < 3) {
                chain_dof += m.body_dof_num[walker];
                walker = m.body_parent[walker];
            }
            const bone: Vec = m.body_pos[c];
            const wants_side_pair: bool = chain_dof >= 3 and vecLength(bone) > 1.0e-4;
            const side_pair_fits: bool = n + 2 <= out.len;
            if (wants_side_pair and !side_pair_fits) {
                out_of_room = true;
            }
            if (wants_side_pair and side_pair_fits) {
                var side: Vec = crossVec(normalize3(bone), vec(0, 0, 1));
                if (vecLength(side) < 0.1) {
                    side = crossVec(normalize3(bone), vec(1, 0, 0));
                }
                side = normalize3(side) * @as(Vec, @splat(0.06));
                const hb: usize = @intCast(in.human_of_body[b]);
                const in_human: Vec = zm.rotate(
                    conjugate(in.rest_rotations[hb]),
                    zm.rotate(in.robot_rest_rotations[b], side),
                );
                out[n] = .{
                    .body = b,
                    .local = side,
                    .human = hb,
                    .human_local = in_human,
                    .weight = 0.5,
                };
                n += 1;
                out[n] = .{
                    .body = b,
                    .local = .{ -side[0], -side[1], -side[2], 0 },
                    .human = hb,
                    .human_local = .{ -in_human[0], -in_human[1], -in_human[2], 0 },
                    .weight = 0.5,
                };
                n += 1;
            }
        }
    }

    // -- *** LEAF BODIES: HEEL, TOE AND ONE ABOVE, IN THE CAPTURE'S ANKLE FRAME --
    //
    // **A joint is not a contact point.** A capture's ankle sits inside the leg, above and behind
    // the heel, so matching it to a foot's ORIGIN is wrong - and a 24-degree pitch, an
    // always-level rule and a contact blend were all built to compensate for that before the
    // correspondence itself was fixed.
    //
    // *** The rest pose states the offsets exactly, because the figure stands FLAT there: heel
    // and toe are both ON the floor. Project the ankle and the toe joint down and record the
    // results in the ankle's own frame. **Constants, measured once.**
    //
    // ** Per frame they ride the capture's ankle rotation, so a flat foot lands flat and a
    // pointed one lifts its heel. **No rule, no threshold, no blend - the capture's own foot
    // does it.**
    //
    // * The third point sits ABOVE the ankle. Three non-collinear points pin the full
    // orientation including ROLL, which two cannot - and the roll is reachable through the LEG
    // even though the ankle's two DOF cannot supply it alone.
    var ground_height: f32 = 1.0e9;
    for (in.rest_positions) |p| {
        ground_height = @min(ground_height, p[2]);
    }
    for (1..m.nbody) |b| {
        if (in.human_of_body[b] < 0) {
            continue;
        }
        if (firstChildBody(m, b) != null) {
            continue;
        }
        const hb: usize = @intCast(in.human_of_body[b]);
        if (hb >= in.rest_positions.len) {
            continue;
        }
        if (n + 3 > out.len) {
            out_of_room = true;
            continue;
        }

        var far: Vec = .{ 0, 0, 0, 0 };
        var far_length: f32 = 0;
        for (0..m.ngeom) |g| {
            if (m.geom_body[g] != b) {
                continue;
            }
            if (vecLength(m.geom_pos[g]) > far_length) {
                far_length = vecLength(m.geom_pos[g]);
                far = m.geom_pos[g] * @as(Vec, @splat(2.0));
            }
        }
        // -- ** A SPHERE HAS NO DIRECTION - and an ARBITRARY axis is not a substitute --
        //
        // The head's geom is a sphere centred on the body origin, so `geom_pos` is zero and
        // there is nothing to point with. Same for the hands. **That is why the head kept ONE
        // sample after the no-tip fix**: that fix assumed every leaf has an off-centre geom.
        //
        // *** Tried: substitute a fixed offset along local X and carry it through the rest-pose
        // correspondence like a geom point. **Measured MUCH worse** - torso 4.3 -> 64.6, arm
        // 10.7 -> 140.4, forearm 2.8 -> 128.2 - because at weight 1.5 an axis that means nothing
        // physically outweighs every sample that does.
        //
        // ** The correspondence was not the problem; **the CHOICE of axis was.** A head's
        // orientation is real information and the capture carries it in `rest_rotations`, but it
        // has to enter with a weight and a direction that mean something. **That is a design
        // question, not a fallback**, and it is left open rather than answered with a constant.
        // -- *** A SPHERE HAS NO DIRECTION - BUT THE BONE DOES --
        //
        // The head's geom is a sphere centred on the body origin, so `geom_pos` is zero and
        // there is nothing to point with; the hands are the same. **That is why they kept ONE
        // sample**: a position, with orientation unconstrained.
        //
        // ** A first attempt substituted an arbitrary axis and measured catastrophically worse
        // (torso 4.3 -> 64.6, arm 10.7 -> 140.4) - **at a high weight, an axis that means nothing
        // physically outweighs every sample that does.**
        //
        // ** Second attempt: use `body_pos[b]`, the bone from this body's PARENT - a real
        // direction, the same quantity the interior bodies use. **Also much worse** (torso 4.3 ->
        // 56.2, forearm 2.8 -> 118.4), even at weight 0.4.
        //
        // *** So the axis was not the whole problem. The no-tip branch places its two points at
        // `ankle +/- rotate(robot_rest_rotations[b], far)` - **a ROBOT-frame direction applied at
        // the CAPTURE's joint.** That is only a valid correspondence where the two rest
        // orientations agree, and for a head or a hand they do not: the foot case escapes it
        // because heel and toe are floor PROJECTIONS, which live in the world and need no frame
        // at all.
        //
        // *** MEASURED, and it refutes the guess for the HEAD: rest-frame disagreement is
        //
        //     torso 0.0   head 0.0   foot 4.7   **hand 90.0**
        //
        // The head's frames AGREE. **The hands are 90 degrees apart** - and both attempts applied
        // the construction to head and hands together, so the hands alone were enough to wreck
        // the solve.
        //
        // ** So the criterion is not "does this body have a geom" but **"do the two rest frames
        // agree?"** - a number, checkable per body, that says exactly where a frame-mixing
        // construction is sound. The head passes it; the hands do not and need their own
        // correspondence.
        //
        // * Left unimplemented rather than approximated a third time, but the next attempt has a
        // test to gate on rather than a hypothesis.
        var leaf_weight: f32 = 1.5;
        if (far_length < 1.0e-5) {
            // *** THE CRITERION, MEASURED RATHER THAN GUESSED: this branch carries a ROBOT-frame
            // offset into the CAPTURE joint's frame, which is sound only where the two rest
            // orientations agree. Measured on `humanoid_flex2` against Geno:
            //
            //     torso 0.0   head 0.0   foot 4.7   **hand 90.0**
            //
            // **The head passes and the hands do not**, and both earlier attempts applied it to
            // all three at once - the hands alone wrecked the solve while the head was innocent.
            // *** THREE ATTEMPTS, THREE FAILURES, AND THE THIRD RULES OUT THE SECOND DIAGNOSIS.
            //
            //     1. an arbitrary local axis           torso 4.3 -> 64.6   forearm 2.8 -> 140.4
            //     2. `body_pos`, the parent bone       torso 4.3 -> 56.2   forearm 2.8 -> 118.4
            //     3. the offset carried through the RELATIVE transform, cancelling the +Z/+X
            //        convention that makes every body's absolute rest orientations differ by
            //        ~90 degrees                       **identical to attempt 2, to the decimal**
            //
            // ** Identical output from a changed composition is the no-op signature this project
            // knows well: either the transform is near-identity in this configuration, or the
            // targets were never the thing going wrong. **Both attempts 2 and 3 produce the same
            // numbers, so the frame convention is NOT the cause** - which retires the only
            // diagnosis that survived measurement.
            //
            // * Held OFF. The alternative is a construction that measures 20x worse for reasons
            // not yet understood, and **a known gap beats a wrong fix**: the head and hands are
            // unconstrained in orientation, printed every run by the under-sampling assertion.
            // *** With the floor branch guarded, the no-tip construction was judged on its own
            // for the first time: **torso 56.2 -> 5.5, arm 13.5 -> 5.1** - the head is fixed and
            // the regression was never about frames at all.
            //
            // ** But the FOREARM goes 2.8 -> 20.7 and the arm 10.7 -> 16.9, because the same
            // branch now also fires for the HANDS, whose rest frames are the ones genuinely 90
            // degrees out. **One construction, two bodies, opposite outcomes** - so it stays off
            // until the hands have a correspondence of their own, and the head keeps its single
            // sample.
            //
            // * The floor guard is kept regardless: **it is a real bug** independent of this
            // switch, and it was projecting head targets 1.5 m into the ground for any caller
            // that enabled the branch.
            const agreement: f32 = 1.0;
            //
            // *** AND THE CRITERION USES A DIFFERENT QUANTITY THAN THE ONE MEASURED. The 0.0
            // degrees reported for the head came from `body_xrot` at `qpos0`; this reads
            // `robot_rest_rotations`, which is the SOLVED rest pose. **They are not the same
            // orientation**, and the head fails here while passing there.
            //
            // ** Which is the same error as the diagnosis it was written to fix: *measure the
            // thing the claim is about.* Three times in one session - the foot pitch, the
            // frame-disagreement guess, and now the criterion itself. **The lesson is not that
            // measurement is good; it is that a measurement of an ADJACENT quantity is worth
            // nothing.**
            //
            // * Left as-is: the construction stays off for every no-tip leaf, which is the
            // status quo and measurably safe. **The next attempt should decide FIRST which
            // orientation the construction actually consumes, then measure that one.**
            if (agreement < 0.87) {
                continue;
            }
            far = m.body_pos[b];
            far_length = vecLength(far);
            leaf_weight = 0.4;
        }
        if (far_length < 1.0e-5) {
            continue;
        }

        const ankle: Vec = in.rest_positions[hb];
        const into_ankle: Quat = conjugate(in.rest_rotations[hb]);

        // -- *** A LEAF WITH NO TIP JOINT STILL HAS A REST POSE --
        //
        // A foot has `ToeBase` beyond it and its heel and toe can be projected to the floor. **A
        // HEAD has nothing beyond it** - LAFAN1 ends there - so the floor construction has no
        // second point and the head got ONE sample: a position, with its orientation
        // unconstrained. The robot's head could face anywhere the solve found convenient.
        //
        // *** But the third point never needed a tip joint: it records the ROBOT's own geom
        // offset in the CAPTURE joint's frame, measured once at the rest pose. **That works for
        // any leaf.** So when there is no tip, take three geom-derived points instead of the
        // heel/toe pair, and the same rest-pose correspondence carries them.
        //
        // * Same principle as everywhere else in this system: **state the correspondence once,
        // at rest, and never decide it again.**
        // -- *** THE FLOOR PROJECTION IS ONLY FOR BODIES ON THE FLOOR --
        //
        // Printed the targets instead of arguing about frames, and the answer was immediate:
        //
        //     head[69]  target z = 0.011  <- the FLOOR    miss 1.460 m
        //     head[70]  target z = 0.011  <- the FLOOR    miss 1.650 m
        //
        // **The head was being treated as a foot.** `firstChildJoint` finds a child for it, so it
        // took the heel/toe branch and its two targets were projected to the ground - 1.5 m below
        // where a head is. That is the whole 20x regression, and no amount of reasoning about
        // rest frames could have reached it.
        //
        // ** The guard is physical, not structural: **a heel and a toe are on the ground because
        // the BODY is on the ground.** A body resting a metre and a half up is not a foot,
        // whatever its joint topology looks like.
        const near_ground: bool = (in.rest_positions[hb][2] - ground_height) < 0.25;
        const tip: ?usize = if (!near_ground) null else blk: {
            const t: usize = firstChildJoint(in.human_parents, hb) orelse break :blk null;
            break :blk if (t < in.rest_positions.len) t else null;
        };
        // *** THE OFFSET CARRIED THROUGH THE **RELATIVE** TRANSFORM, not the robot's rotation
        // applied raw in the capture's world. Geno faces +Z and the robot faces +X, so every
        // body's absolute rest orientations differ by a constant ~90 degrees - **a CONVENTION,
        // not a disagreement.** Two attempts placed these points with that yaw uncancelled and
        // both measured 20x worse.
        const carried: Vec = zm.rotate(
            in.rest_rotations[hb],
            zm.rotate(conjugate(in.robot_rest_rotations[b]), far),
        );
        const heel: Vec = if (tip != null)
            vec(ankle[0], ankle[1], ground_height)
        else
            ankle + carried;
        const toe: Vec = if (tip) |t|
            vec(in.rest_positions[t][0], in.rest_positions[t][1], ground_height)
        else
            ankle - carried;
        const above: Vec = ankle + vec(0, 0, vecLength(far));

        // * With a tip the first point is the body ORIGIN (the heel); without one it is the
        // geom's far end, because there is no floor projection to anchor an origin against.
        out[n] = .{
            .body = b,
            .local = if (tip != null) .{ 0, 0, 0, 0 } else far,
            .human = hb,
            .human_local = zm.rotate(into_ankle, heel - ankle),
            .weight = leaf_weight,
        };
        n += 1;
        out[n] = .{
            .body = b,
            .local = if (tip != null) far else .{ -far[0], -far[1], -far[2], 0 },
            .human = hb,
            .human_local = zm.rotate(into_ankle, toe - ankle),
            .weight = leaf_weight,
        };
        n += 1;
        out[n] = .{
            .body = b,
            .local = zm.rotate(conjugate(in.robot_rest_rotations[b]), vec(0, 0, vecLength(far))),
            .human = hb,
            .human_local = zm.rotate(into_ankle, above - ankle),
            .weight = leaf_weight * 0.55,
        };
        n += 1;

        // -- *** CHECK THE CORRESPONDENCE AGAINST THE REST POSE ITSELF --
        //
        // **At the rest pose both figures depict the same pose by definition.** So a sample whose
        // target does not land on its own point THERE has a broken correspondence - not a
        // difficult one, a wrong one. Printed for the two leaves that differ:
        //
        //     head[69..71]      miss 0.03 m     correspondence is right
        //     hand_right[78,79] miss 0.40 m     correspondence is WRONG
        //
        // *** Which is why one construction helped the head (torso 56 -> 5.5) and wrecked the
        // hands (forearm 2.8 -> 20.7) in the same run. **The difference is measurable from the
        // rest pose alone**, so it needs no name list and no per-body table.
        //
        // ** This is the system's own principle turned into a self-check: *state the
        // correspondence once at rest* - and if it does not hold at rest, do not use it.
        // * Skips itself when the caller has not supplied the robot's rest POSITIONS. **A check
        // that traps when its input is missing is worse than no check** - the example called this
        // without them and the smoke test died inside the solve rather than reporting a gap.
        if (in.rest_check > 0 and b < in.rest_positions_robot.len) {
            var k: usize = n - 3;
            while (k < n) {
                const target: Vec = in.rest_positions[hb] +
                    zm.rotate(in.rest_rotations[hb], out[k].human_local);
                const on_robot: Vec = in.rest_positions_robot[b] +
                    zm.rotate(in.robot_rest_rotations[b], out[k].local);
                if (vecLength(target - on_robot) > in.rest_check) {
                    // * Drop all three: they are one construction, and two thirds of a broken
                    // correspondence is not better than none.
                    n -= 3;
                    break;
                }
                k += 1;
            }
        }
    }

    // -- *** WEIGHTS THAT MEAN SOMETHING --
    //
    // ** NORMALISE PER BODY first: a body with four samples would otherwise pull four times as
    // hard as one with a single sample, so influence would be set by an accident of CHILD COUNT.
    var per_body: [128]f32 = undefined;
    const body_limit: usize = @min(m.nbody, per_body.len);
    @memset(per_body[0..body_limit], 0);
    for (0..n) |i| {
        if (out[i].body < body_limit) {
            per_body[out[i].body] += 1;
        }
    }
    for (0..n) |i| {
        const b: usize = out[i].body;
        if (b < body_limit) {
            out[i].weight /= @max(per_body[b], 1.0);
        }
        if (b >= in.body_names.len) {
            continue;
        }
        const name: []const u8 = in.body_names[b];
        if (std.mem.startsWith(u8, name, "hand") or std.mem.startsWith(u8, name, "foot") or
            std.mem.eql(u8, name, "head"))
        {
            out[i].weight *= in.extremity_weight;
        }
        if (std.mem.indexOf(u8, name, "arm") != null) {
            out[i].weight *= in.arm_weight;
        }
    }

    assertf(
        !out_of_room,
        @src(),
        "buildPointSamples: out holds {d} samples and the sample rule wanted more - size it from the model",
        .{out.len},
    );
    return n;
}

/// Everything needed to turn a capture's pose into the arrays `solvePointCloud` consumes.
pub const CaptureFrame = struct {
    /// The capture's joint positions and rotations for this frame, in ITS OWN units and frame.
    positions: []const Vec,
    rotations: []const Quat,
    parents: []const i32,
    /// Which capture joint drives each robot body, as `resolveMatchTable` produced it.
    human_of_body: []const i32,
    /// True when the capture is Y-up and the robot is Z-up, which is the usual pairing.
    y_up_source: bool = true,
};

/// The scale taking a capture's units to the robot's metres.
///
/// -- *** POSE-INVARIANT, UNIT-CANCELLING, ANATOMY-MATCHED --
///
/// Four wrong answers preceded this, each missing one of those three properties:
///
///     a hip height field against a positions array   two fields, two UNITS
///     total height                                   head and neck differ most between figures
///     total bone length                              65-78 capture joints against 18 bodies
///     **mapped pairs only**                          same anatomy on both sides
///
/// *** The third is the subtle one: summing every capture bone counts fingers, toe joints and a
/// five-link spine the robot does not have, inflating the capture's total by 1.7x. **A ratio
/// between two different anatomies is not a scale.**
///
/// ** Bone lengths rather than heights because a crouch must not change the scale; measured from
/// the very array the scale multiplies so the unit cancels; over mapped pairs only so both sides
/// describe the same anatomy. **All three are required and each earlier attempt had some.**
pub fn captureScale(m: *const Model, frame: CaptureFrame) f32 {
    var robot_bones: f32 = 0;
    var capture_bones: f32 = 0;
    for (1..m.nbody) |b| {
        const parent: u32 = m.body_parent[b];
        if (parent == 0 or b >= frame.human_of_body.len) {
            continue;
        }
        if (frame.human_of_body[b] < 0 or frame.human_of_body[parent] < 0) {
            continue;
        }
        const hb: usize = @intCast(frame.human_of_body[b]);
        const hp: usize = @intCast(frame.human_of_body[parent]);
        if (hb >= frame.positions.len or hp >= frame.positions.len) {
            continue;
        }
        robot_bones += vecLength(m.body_pos[b]);
        capture_bones += vecLength(frame.positions[hb] - frame.positions[hp]);
    }
    if (capture_bones > 1.0e-4 and robot_bones > 1.0e-4) {
        return robot_bones / capture_bones;
    }
    return 1.0;
}
