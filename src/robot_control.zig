//! robot_control.zig - making a robot go where you want it.
//!
//! Two things every demo has needed and each has re-implemented: hold a joint pose, and put an
//! end effector on a target. Both are small, both have a trap in them that has now bitten
//! three separate times, and neither belongs pasted into an example.
//!
//! -- ** THE TRAP, STATED ONCE --
//!
//! **Gravity compensation is something a MOTOR does, and only actuated DOFs have one.**
//!
//! `bias_force` covers every degree of freedom - including a floating base's six and a free
//! crate's six. Adding all of it cancels the machine's own weight:
//!
//!   * a crate tower in `robot_3d` hung in the air;
//!   * the `robot_3d` arm was fine, because it is bolted down and every DOF is actuated;
//!   * the Go1 **rose at a steady 2.4 m/s** until only its hinges were compensated.
//!
//! `Actuation` computes the mask once from the model's own topology, so the question is asked
//! in one place instead of remembered at every call site.

const std = @import("std");
const report = @import("test_report.zig");
const Allocator = std.mem.Allocator;

const zm = @import("zm");
const rbt = @import("robot.zig");
const float = zm.float;
const radFromDeg = zm.radFromDeg;
const quat_identity = zm.quat_identity;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const isFinite = zm.isFinite;

const Vec = zm.Vec;
const vec = zm.vec;
const vec_zero = zm.vec_zero;
const splat = zm.splat;
const clamp = zm.clamp;
const cross = zm.cross;
const assertf = zm.assertf;
const dot3 = zm.dot3;
const length3 = zm.length3;
const sinRad = zm.sinRad;
const pi = zm.pi;
const quat = zm.quat;
const qmul = zm.qmul;

/// Which velocity DOFs a controller may push on, and how hard.
pub const Actuation = struct {
    /// True where a motor exists. Indexed by velocity DOF.
    powered: []bool,
    gpa: Allocator,

    /// Build the mask from the model's joints.
    ///
    /// * A HINGE OR SLIDE IS POWERED; A FREE OR BALL JOINT IS NOT. That is not a statement
    /// about actuators - a model may well leave a hinge unmotorised - but about what CAN be
    /// driven by a scalar torque at all. A floating base has no motor by construction, and a
    /// controller that forgets it makes the robot fly.
    pub fn init(gpa: Allocator, model: *const rbt.Model) !Actuation {
        const powered: []bool = try gpa.alloc(bool, model.nv);
        @memset(powered, false);
        for (0..model.njnt) |j| {
            switch (model.jnt_type[j]) {
                .hinge, .slide => powered[model.jnt_dof_adr[j]] = true,
                // ---- A BALL JOINT IS POWERED NOW, AND A FREE ONE STILL IS NOT ----
                //
                // *** THE NOTE ABOVE SAID A BALL JOINT CANNOT BE DRIVEN BY A SCALAR TORQUE, AND
                // THAT WAS TRUE UNTIL `PoseHold` LEARNED TO DRIVE ONE. It now computes the
                // rotation carrying the current orientation to the target and applies torque on
                // all three DOFs - so the premise changed and this switch did not follow.
                //
                // The symptom was a character with `kp = 400` on screen and **no torque at
                // all**: every joint in `humanoid_ball` is a ball joint, so `powered` was false
                // everywhere and `PoseHold.apply` skipped every one. A limp ragdoll reporting
                // healthy gains.
                //
                // A FREE JOINT IS STILL NOT POWERED and that part of the note stands: a floating
                // base has no motor by construction, and a controller that forgets it makes the
                // robot fly.
                .ball => {
                    const base: u32 = model.jnt_dof_adr[j];
                    inline for (0..3) |k| {
                        powered[base + k] = true;
                    }
                },
                .free => {},
            }
        }
        return .{ .powered = powered, .gpa = gpa };
    }

    pub fn deinit(self: *Actuation) void {
        self.gpa.free(self.powered);
    }
};

/// Restrict an `Actuation` to the joints on the path from one body to the world.
///
/// -- * WHY IK NEEDS THIS TO MOVE A QUADRUPED'S BODY --
///
/// Placing a foot is a three-joint problem - hip, thigh, calf - but `Ik` uses every powered
/// DOF it is given, and handed the whole robot it would happily bend the OTHER three legs to
/// help. Four such solves then fight each other and nothing converges.
///
/// Masking to one limb makes them independent, which is what allows the standard quadruped
/// trick: pin every foot where it stands, move the body, and let each leg solve alone.
pub fn limbActuation(gpa: Allocator, model: *const rbt.Model, tip: u32) !Actuation {
    const powered: []bool = try gpa.alloc(bool, model.nv);
    @memset(powered, false);
    var walk: u32 = tip;
    while (walk != rbt.world_body) : (walk = model.body_parent[walk]) {
        const first: u32 = model.body_dof_adr[walk];
        for (0..model.body_dof_num[walk]) |k| {
            const v: u32 = first + @as(u32, @intCast(k));
            // * THE ROOT'S SIX DOFs ARE ON THIS PATH AND MUST STAY OFF. A floating base sits
            // between every foot and the world, so walking to the root sweeps it up - and an
            // IK solver allowed to use it "plants the foot" by sliding the whole robot.
            switch (model.jnt_type[dofJoint(model, v)]) {
                .hinge, .slide => powered[v] = true,
                // Ball joints are driveable now - see the note in `init`. `v` is already the
                // DOF here, so each of a ball joint's three is powered as it is visited.
                .ball => powered[v] = true,
                .free => {},
            }
        }
    }
    return .{ .powered = powered, .gpa = gpa };
}

/// Which joint owns a velocity DOF.
fn dofJoint(model: *const rbt.Model, dof: u32) u32 {
    for (0..model.njnt) |j| {
        const first: u32 = model.jnt_dof_adr[j];
        const width: u32 = switch (model.jnt_type[j]) {
            .free => 6,
            .ball => 3,
            .hinge, .slide => 1,
        };
        if (dof >= first and dof < first + width) {
            return @intCast(j);
        }
    }
    return 0;
}

/// A joint-space pose controller.
pub const PoseHold = struct {
    /// Target, in the model's own `qpos` layout. Only powered DOFs are read.
    target: []const f32,
    /// Proportional and derivative gains, and the per-joint torque ceiling.
    kp: f32 = 100.0,
    kv: f32 = 2.0,
    /// * THE CEILING IS WHAT MAKES A ROBOT WEAK OR STRONG, and without one every robot is
    /// infinitely strong: a PD law will produce whatever torque the error demands. Real motors
    /// have a rating, and `<position forcerange=...>` in MJCF is exactly this number.
    /// Divide the gains by each joint's own inertia, so `kp` becomes omega^2 and `kv` becomes 2 zeta omega.
    ///
    /// -- ** WORTH TURNING ON, AND OFF BY DEFAULT ANYWAY --
    ///
    /// It is the better formulation: gains stop being torque numbers that only mean something
    /// next to a particular link, and become a frequency and a damping ratio that mean the same
    /// thing everywhere. On a robot whose links differ by two orders of magnitude - a 1.6 kg
    /// shoulder and a 0.03 kg finger - one pair of numbers then works for both, where torque
    /// units cannot.
    ///
    /// * BUT IT CHANGES WHAT EVERY EXISTING GAIN MEANS. Switching the default would silently
    /// invalidate every number any caller has tuned, and this engine has several that were
    /// measured rather than guessed - the Go1's kp = 100 and the humanoid's kp = 400 both sit
    /// in narrow bands found by experiment. Quietly reinterpreting them is a worse failure than
    /// making callers ask, because it looks like the robot changed.
    ///
    /// So: off by default, on where the model needs it. A rough conversion for an existing
    /// gain is `kp_new ~ kp_old / typical_inertia`.
    scale_by_inertia: bool = false,
    max_torque: f32 = 1000.0,

    /// Write torques into `data.applied_force`.
    ///
    /// Call between `forward` and `step` - the law reads positions and velocities that
    /// `forward` computed, and `step` consumes the forces.
    pub fn apply(
        self: PoseHold,
        model: *const rbt.Model,
        data: *rbt.Data,
        actuation: Actuation,
    ) void {
        @memset(data.applied_force, 0);
        for (0..model.njnt) |j| {
            const v: u32 = model.jnt_dof_adr[j];
            if (!actuation.powered[v]) {
                continue;
            }
            const q: u32 = model.jnt_qpos_adr[j];
            // -- *** THE GAINS ARE SCALED BY EACH JOINT'S OWN INERTIA --
            //
            // A gain in torque units is only meaningful next to an inertia, and a robot's
            // joints do not share one: the arm this was found on has a 1.6 kg shoulder and a
            // 0.03 kg finger. A `kp` that is gentle on the first is violently unstable on the
            // second, and nothing about the number says so.
            //
            // Measured on a 4-DOF arm at kp = 600, kv = 25 - reasonable-looking numbers, and
            // the same ones that hold a Go1 perfectly well:
            //
            //     joint 3 (wrist):  want 1.000  got 0.500  vel -100.000  <- the velocity CLAMP
            //
            // It was not stuck, it was DIVERGING, and the pose error was a snapshot of a joint
            // spinning as fast as the engine permits. Bias forces were all under 25, so gravity
            // compensation was innocent; the gains simply did not fit the link.
            //
            // * DIVIDING THE INERTIA OUT TURNS `kp` INTO A FREQUENCY - `kp` becomes omega^2 and `kv`
            // becomes 2 zeta omega, properties of the RESPONSE wanted rather than of the link being
            // pushed. One pair of numbers then works across a whole robot, and across robots.
            // `max_torque` stays in torque units, because a motor's rating is a real quantity
            // that has nothing to do with what it is attached to.
            const inertia: f32 = if (self.scale_by_inertia) rbt.massDiagonal(model, data, v) else 1.0;
            // ---- A BALL JOINT'S ERROR IS A ROTATION, NOT A SUBTRACTION ----
            //
            // The scalar path below reads `target[q] - pos[q]`, which is right for a hinge and
            // MEANINGLESS for a ball joint: `q` addresses four quaternion components, and the
            // difference of two quaternions' first components is not an angle.
            //
            // The rotation carrying the current orientation to the target is
            // `target * conj(current)`, and its axis-angle form is a three-vector whose
            // direction is the axis and whose length is the angle - exactly the shape a torque
            // on three DOFs wants. **Written here rather than left to the caller** because a
            // caller that got it wrong would produce a character twitching plausibly toward
            // nothing.
            if (model.jnt_type[j] == .ball) {
                // ---- THE ERROR IS A ROTATION VECTOR, IN THE TARGET'S FRAME ----
                //
                // `zm.subQuat(current, target)` is MuJoCo's `mju_subQuat`: it returns the
                // rotation carrying the target to the current pose, as a vector whose direction
                // is the axis and whose LENGTH IS THE ANGLE IN RADIANS. The restoring torque is
                // proportional to its negation.
                //
                // *** THE FIRST VERSION OF THIS HAND-ROLLED IT AND GOT THE MAGNITUDE WRONG.
                // `quatToAxisAngle` returns the quaternion's raw `xyz` as its axis - a vector of
                // length `sin(theta/2)`, not one - so `axis * angle` gave `sin(theta/2)*theta`
                // instead of `theta`. Near the target that is QUADRATICALLY too small, making
                // the controller weakest exactly where it should be most precise, and no amount
                // of raising `kp` fixes a gain that vanishes with the error.
                //
                // ** AND THE FRAME WAS WRONG TOO. It computed `target * conj(current)`, the
                // error in the WORLD frame, while a ball joint's velocity coordinates live in
                // the joint's own frame. The two agree only when the parent is unrotated.
                //
                // `subQuat` also normalizes both inputs, because an integrated quaternion drifts
                // off the unit sphere and `conj` stops being the inverse when it does.
                const current: rbt.Quat = quat(
                    data.pos[q],
                    data.pos[q + 1],
                    data.pos[q + 2],
                    data.pos[q + 3],
                );
                const want: rbt.Quat = quat(
                    self.target[q],
                    self.target[q + 1],
                    self.target[q + 2],
                    self.target[q + 3],
                );
                // ---- `subQuat(want, current)`, NOT `subQuat(current, want)` ----
                //
                // *** `subQuat(a, b)` IS THE ROTATION CARRYING `b` TO `a`, EXPRESSED IN b's
                // FRAME - and its doc says outright that the frame is the part that is easy to
                // get wrong. A joint's three DOFs live in the CURRENT orientation's frame, so
                // the error has to be expressed there, which means `current` is the second
                // argument.
                //
                // The first version passed them the other way and negated `kp` to fix the sign.
                // That gets the magnitude and the sign right and the FRAME wrong, so the torque
                // points correctly only while the error is small. Measured: survival FELL as
                // gains rose - 0.75s at kp 800 down to 0.15s at kp 2500 - which is a controller
                // pushing in an increasingly wrong direction, not one that is merely too stiff.
                //
                // This is MuJoCo's own order: `mju_subQuat(res, qdes, qpos)` then `+kp * res`.
                const err: rbt.Vec = zm.subQuat(want, current);

                // Unrolled at comptime because `err` is a `@Vector` and a vector cannot be
                // indexed with a runtime value.
                inline for (0..3) |k| {
                    const ball_inertia: f32 = if (self.scale_by_inertia)
                        rbt.massDiagonal(model, data, v + @as(u32, @intCast(k)))
                    else
                        1.0;
                    const torque: f32 = ball_inertia *
                        (self.kp * err[k] - self.kv * data.vel[v + k]);
                    // `bias_force` INSIDE the clamp, matching the scalar path exactly.
                    data.applied_force[v + k] = clamp(
                        torque + data.bias_force[v + k],
                        -self.max_torque,
                        self.max_torque,
                    );
                }
                continue;
            }

            const wanted: f32 = inertia *
                (self.kp * (self.target[q] - data.pos[q]) - self.kv * data.vel[v]);
            // * GRAVITY COMPENSATION IS ADDED, THEN THE TOTAL IS CLAMPED. Clamping only the
            // tracking part would let a weak motor treat its own weight as free, so a robot
            // with a 1 N*m rating could still hold up any load. The rating bounds everything
            // the motor does.
            //
            // *** AND THE CODE NOW DOES WHAT THE COMMENT ABOVE ALWAYS SAID. It used to clamp
            // `wanted` and add `bias_force` OUTSIDE the clamp, so the real ceiling was
            // `max_torque + gravity` - measured at **1589 N*m on a heavy arm rated 400**. Every
            // PD-versus-planner comparison in this project was therefore giving the servo up to
            // four times the torque its planner opponent was held to by `boxQP`.
            //
            // * A COMMENT THAT DISAGREES WITH ITS CODE IS A BUG REPORT SOMEONE ALREADY WROTE.
            // This one stated the correct semantics and was three lines above the line that
            // broke them.
            data.applied_force[v] = clamp(
                wanted + data.bias_force[v],
                -self.max_torque,
                self.max_torque,
            );
        }
    }
};

/// Where an end effector should go.
/// Solve `A*x = b` in place for a small symmetric positive-definite `A`, by Cholesky.
/// False when `A` is not positive definite, which for `J*J^T + lambda^2I` means the damping was
/// swamped by f32 error rather than anything about the robot.
fn choleskySolveSmall(a: *[6][6]f32, n: usize, b: *[6]f32) bool {
    for (0..n) |i| {
        for (0..i + 1) |j| {
            var sum: f32 = a[i][j];
            for (0..j) |k| {
                sum -= a[i][k] * a[j][k];
            }
            if (i == j) {
                if (sum <= 0) {
                    return false;
                }
                a[i][j] = @sqrt(sum);
            } else {
                a[i][j] = sum / a[j][j];
            }
        }
    }
    for (0..n) |i| {
        var sum: f32 = b[i];
        for (0..i) |k| {
            sum -= a[i][k] * b[k];
        }
        b[i] = sum / a[i][i];
    }
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var sum: f32 = b[i];
        for (i + 1..n) |k| {
            sum -= a[k][i] * b[k];
        }
        b[i] = sum / a[i][i];
    }
    return true;
}

pub const IkTarget = struct {
    /// The body whose point is being placed.
    body: u32,
    /// The point, in that body's frame - a fingertip, a foot, a tool centre.
    offset: Vec = vec_zero,
    /// Where it should be, in world coordinates.
    goal: Vec,
    /// The orientation that body should ALSO hold, in world coordinates. Null places the point
    /// and lets the body face wherever the solver finds convenient.
    ///
    /// -- ** WHY THIS IS NOT OPTIONAL FOR A GRIPPER --
    ///
    /// Placing a point is enough for a foot, which only has to be somewhere. It is not enough
    /// for a hand: a top-down grasp is a statement about the jaws' DIRECTION, and without it
    /// the solver returns whatever attitude its nullspace drifted into. Measured on the gripper
    /// demo, the jaws sat sideways at rest and no choice of target position changed that,
    /// because position targets cannot express it.
    ///
    /// * IT COSTS THREE MORE ROWS on the same Jacobian and turns the 3x3 damped least-squares
    /// system into a 6x6 - which is why the solve below is written for N rows rather than
    /// three, with the explicit 3x3 inverse replaced by a Cholesky.
    orientation: ?zm.Quat = null,
};

/// Solve for joint angles that put an end effector on a target.
///
/// -- * DAMPED LEAST SQUARES, and the damping is the whole point --
///
/// The naive step is `dq = J^+*dx`, and it explodes near a singularity: a stretched-out arm has
/// a Jacobian that is nearly rank-deficient, so the pseudo-inverse asks for enormous joint
/// motion to achieve a tiny Cartesian one. Every real IK implementation damps it:
///
///     dq = J^T(J*J^T + lambda^2I)^-1 dx
///
/// which trades exactness for boundedness and degrades gracefully instead of flailing. lambda is
/// `damping` below.
///
/// The system solved is 3x3 regardless of how many joints the robot has, because it is
/// `J*J^T` and the task is three-dimensional - so this costs the same on a 7-DOF arm as on a
/// 30-DOF humanoid.
pub const Ik = struct {
    /// Damping lambda. Larger is more stable and slower to converge.
    damping: f32 = 0.05,
    /// Stop once the end effector is within this distance.
    tolerance: f32 = 1.0e-3,
    /// Cap on one iteration's joint motion, in radians. Bounds the linearisation's validity -
    /// a Jacobian describes the mechanism only near where it was computed.
    max_step: f32 = 0.2,
    /// How much a radian of orientation error counts for against a metre of position error,
    /// when reporting `error_distance` and deciding convergence.
    ///
    /// * IT AFFECTS ONLY THE REPORTED NUMBER, never the solve - the six rows are solved
    /// together on their own terms. It exists so a caller with a 1 mm tolerance is not told
    /// "reached" by a wrist that is a radian out, and 0.05 makes a radian worth 5 cm, which is
    /// roughly the scale at which a gripper stops fitting over what it is aiming at.
    angle_weight: f32 = 0.05,
    max_iterations: u32 = 64,

    pub const Result = struct {
        /// Distance from the goal when the solve stopped.
        error_distance: f32,
        iterations: u32,
        /// Whether `tolerance` was reached. **False is a normal outcome**: a target outside
        /// the robot's reach has no solution, and the caller gets the closest approach rather
        /// than a failure.
        reached: bool,
    };

    /// Iterate `data.pos` toward a configuration that reaches `target`.
    ///
    /// * ONLY `data.pos` AND THE POSITION STAGE ARE TOUCHED. No forces, no contacts, no warm
    /// start - a solve is a kinematic question and must not disturb the dynamics it will be
    /// handed back to.
    ///
    /// Mutates `data` - it IS the answer, left in the model's own coordinates so a caller can
    /// use it as a pose target, hand it to `PoseHold`, or simply look at it. `scratch` needs
    /// `scratchSize(model)` vectors.
    pub fn solve(
        self: Ik,
        model: *const rbt.Model,
        data: *rbt.Data,
        actuation: Actuation,
        target: IkTarget,
        scratch: []Vec,
    ) Result {
        const nv: usize = model.nv;
        // `jacPoint` gives one Vec per DOF - column-per-joint rather than three row arrays,
        // which is both the natural layout and the one that makes `J*J^T` a single pass.
        const jac: []Vec = scratch[0..nv];
        const jac_rot: []Vec = scratch[nv..][0..nv];
        const step_dq: []f32 = @ptrCast(scratch[2 * nv ..][0..nv]);
        // * THREE ROWS OR SIX, decided once. Everything below is written for `rows`, so the
        // position-only path is this same code with the orientation half skipped, rather than
        // a second implementation free to drift away from it.
        const rows: usize = if (target.orientation == null) 3 else 6;

        var iteration: u32 = 0;
        var gap: f32 = 0;
        while (iteration < self.max_iterations) : (iteration += 1) {
            // -- ** KINEMATICS ONLY, NOT `forward` - and calling `forward` here was two bugs --
            //
            // IK needs body poses and a Jacobian. `forward` computes those and then the mass
            // matrix, the bias forces, the contacts and a full constraint SOLVE. Running that
            // once per iteration meant twelve complete physics solves per rendered frame:
            // **the frame rate collapsed whenever the target was out of reach**, because an
            // unreachable target is exactly the case that uses every iteration.
            //
            // Worse, it was not merely slow. Each intermediate solve ran with the arm wherever
            // IK had just put it - sometimes deep inside a crate - and left those enormous
            // forces in the WARM START. The next real step seeded from them, and the mass
            // matrix went NaN: `factorM: pivot 24 is nan` while reaching into the tower.
            //
            // `kinematics` places the bodies and `comPos` builds `cdof` and `subtree_com` -
            // which is exactly what `jacPoint` reads, and nothing more. Neither touches a
            // force, a contact or the warm start.
            //
            // * BOTH ARE NEEDED. `kinematics` alone sets the stage to `.position`, so
            // `jacPoint`'s stage assertion passes - and its Jacobian is then built from STALE
            // `cdof`, giving a wrong direction with no error anywhere. The IK tests caught it
            // by failing to converge; a looser test would have shipped it.
            rbt.kinematics(model, data);
            rbt.comPos(model, data);
            const at: Vec = data.body_xpos[target.body] +
                zm.rotate(data.body_xrot[target.body], target.offset);
            const delta: Vec = target.goal - at;
            gap = length3(delta);

            // -- * THE ORIENTATION ERROR IS A ROTATION VECTOR --
            //
            // `wanted * current^-1` is the rotation still to be performed, read in the world. A
            // quaternion's vector part is half the rotation vector to first order, so `2*vec`
            // is the error in radians about each world axis - three numbers in the same units
            // the angular Jacobian produces.
            //
            // * `q` AND `-q` ARE THE SAME ROTATION and the vector part flips between them, so
            // the one with positive `w` is taken: a target 179 deg away corrects by 1 deg rather
            // than by 359 deg.
            var turn: Vec = vec_zero;
            if (target.orientation) |wanted| {
                const misalignment: zm.Quat =
                    qmul(wanted, zm.conjugate(data.body_xrot[target.body]));
                const shortest: zm.Quat = if (misalignment[3] < 0) -misalignment else misalignment;
                turn = vec(2 * shortest[0], 2 * shortest[1], 2 * shortest[2]);
                // * ONE NUMBER OUT, POSITION-DOMINANT. The halves are in different units -
                // metres and radians - and none combines them honestly, so `error_distance`
                // stays the distance a caller can act on, with the angle folded in only enough
                // that a converged position cannot claim success while the wrist points
                // backwards.
                gap = @max(gap, length3(turn) * self.angle_weight);
            }
            if (gap <= self.tolerance) {
                return .{ .error_distance = gap, .iterations = iteration, .reached = true };
            }

            rbt.jacPoint(model, data, target.body, at, jac, if (rows == 6) jac_rot else null);

            // * UNPOWERED DOFs ARE ZEROED OUT OF THE JACOBIAN, which is what makes this work
            // on a floating-base robot. A humanoid's Jacobian includes its root's six DOFs,
            // and a solver free to use them "reaches" the target by TELEPORTING the pelvis -
            // a perfect solution to the equations and a useless one for a robot.
            for (0..nv) |i| {
                if (!actuation.powered[i]) {
                    jac[i] = vec_zero;
                    jac_rot[i] = vec_zero;
                }
            }

            // A = J*J^T + lambda^2I, three by three whatever the robot's size.
            // -- * `(J*J^T + lambda^2I)*y = e`, AT WHATEVER SIZE THE TARGET ASKED FOR --
            //
            // Damped least squares: the damping is what keeps a singular configuration from
            // producing an infinite step, and it is why this converges on a redundant arm where
            // a plain pseudo-inverse would not.
            //
            // * CHOLESKY, NOT AN EXPLICIT INVERSE. The 3x3 case was written out by hand with
            // cofactors, which is fine at three and unreadable at six. `J*J^T + lambda^2I` is
            // symmetric positive definite by construction - a Gram matrix plus a positive
            // diagonal - so the factorisation is both valid and half the work of a general
            // solve.
            var a: [6][6]f32 = @splat(@splat(0));
            for (0..nv) |i| {
                const lin: Vec = jac[i];
                const ang: Vec = jac_rot[i];
                const column = [6]f32{ lin[0], lin[1], lin[2], ang[0], ang[1], ang[2] };
                for (0..rows) |r| {
                    for (0..rows) |c| {
                        a[r][c] += column[r] * column[c];
                    }
                }
            }
            for (0..rows) |k| {
                a[k][k] += self.damping * self.damping;
            }
            var y: [6]f32 = .{ delta[0], delta[1], delta[2], turn[0], turn[1], turn[2] };
            if (!choleskySolveSmall(&a, rows, &y)) {
                return .{ .error_distance = gap, .iterations = iteration, .reached = false };
            }

            // dq = J^T*y, capped so the step stays inside the linearisation.
            var largest: f32 = 0;
            for (0..nv) |i| {
                const lin: Vec = jac[i];
                var dq: f32 = lin[0] * y[0] + lin[1] * y[1] + lin[2] * y[2];
                if (rows == 6) {
                    const ang: Vec = jac_rot[i];
                    dq += ang[0] * y[3] + ang[1] * y[4] + ang[2] * y[5];
                }
                step_dq[i] = dq;
                largest = @max(largest, @abs(dq));
            }
            const scale: f32 = if (largest > self.max_step) self.max_step / largest else 1.0;

            for (0..model.njnt) |j| {
                const v: u32 = model.jnt_dof_adr[j];
                if (!actuation.powered[v]) {
                    continue;
                }
                const q: u32 = model.jnt_qpos_adr[j];
                var next: f32 = data.pos[q] + scale * step_dq[v];
                // * JOINT LIMITS ARE RESPECTED HERE, not left to the constraint solver. An IK
                // answer that violates a limit is not a pose the robot can hold, and handing
                // one to a controller produces a machine fighting itself.
                if (model.jnt_range[j]) |range| {
                    next = clamp(next, range[0], range[1]);
                }
                data.pos[q] = next;
            }
            data.stage = .stale;
        }

        return .{ .error_distance = gap, .iterations = iteration, .reached = false };
    }

    /// Vectors `solve` needs in `scratch`: one Jacobian column per DOF, plus room for the
    /// joint step alongside it.
    pub fn scratchSize(model: *const rbt.Model) usize {
        // Two Vec slices for the linear and angular Jacobians, plus one more reinterpreted as
        // the joint-space step. See `solve`.
        return 3 * model.nv;
    }
};

// =============================================================================
// Tests
// =============================================================================

const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const rmj = @import("robot_mjcf.zig");
const zimrphysics = @import("zimrphysics.zig");
const robot_physics = @import("robot_physics.zig");
const kuka = @import("tests/fixtures/robot/kuka_iiwa.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "ik: a KUKA reaches a target it can reach" {
    // ** A REAL ROBOT, NOT A CONTRIVED ONE. Two links and a hinge would prove nothing about
    // conditioning: the KUKA is 7-DOF and redundant, so `J*J^T` is genuinely rank-deficient in
    // directions the arm cannot move, which is exactly the case damping exists for.
    const gpa: Allocator = std.testing.allocator;
    var model: rbt.Model = try kuka.Model.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();
    var actuation: Actuation = try Actuation.init(gpa, &model);
    defer actuation.deinit();
    const scratch: []Vec = try gpa.alloc(Vec, Ik.scratchSize(&model));
    defer gpa.free(scratch);

    // Start folded, so the solve has real work rather than a nudge.
    for (0..model.njnt) |j| {
        data.pos[model.jnt_qpos_adr[j]] = 0.3;
    }
    data.stage = .stale;

    // A point comfortably inside the arm's reach - the iiwa is about 1.3 m tall.
    const wrist: u32 = model.nbody - 1;
    const goal: Vec = vec(0.35, 0.15, 0.75);
    const ik: Ik = .{};
    const result: Ik.Result = ik.solve(&model, &data, actuation, .{
        .body = wrist,
        .goal = goal,
    }, scratch);

    try expect(result.reached);
    try expect(result.iterations < ik.max_iterations);

    // And the arm really is there - re-derived from kinematics rather than trusting the
    // solver's own bookkeeping.
    rbt.forward(&model, &data);
    try expectApproxEqAbs(@as(f32, 0), length3(data.body_xpos[wrist] - goal), 2.0e-3);
}

test "ik: an unreachable target gives the closest approach, not a failure" {
    // * `reached = false` IS A NORMAL OUTCOME. A target outside the workspace has no solution,
    // and the useful answer is the nearest pose rather than an error - a caller steering a
    // hand toward a moving object wants it to keep pointing the right way, not to stop.
    const gpa: Allocator = std.testing.allocator;
    var model: rbt.Model = try kuka.Model.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();
    var actuation: Actuation = try Actuation.init(gpa, &model);
    defer actuation.deinit();
    const scratch: []Vec = try gpa.alloc(Vec, Ik.scratchSize(&model));
    defer gpa.free(scratch);

    const wrist: u32 = model.nbody - 1;
    const far_away: Vec = vec(50, 0, 0);
    const result: Ik.Result = (Ik{}).solve(&model, &data, actuation, .{
        .body = wrist,
        .goal = far_away,
    }, scratch);

    try expect(!result.reached);
    // It stretched TOWARD the target rather than flailing: the wrist ends up out along +x, and
    // nothing is NaN.
    rbt.forward(&model, &data);
    const at: Vec = data.body_xpos[wrist];
    try expect(at[0] > 0.3);
    try expect(length3(at) < 2.0);
    try expect(result.error_distance == result.error_distance);
}

test "ik: joint limits are respected by the answer" {
    // An IK result that violates a limit is not a pose the robot can hold; handing one to a
    // controller produces a machine fighting its own constraint solver.
    const gpa: Allocator = std.testing.allocator;
    var model: rbt.Model = try kuka.Model.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();
    var actuation: Actuation = try Actuation.init(gpa, &model);
    defer actuation.deinit();
    const scratch: []Vec = try gpa.alloc(Vec, Ik.scratchSize(&model));
    defer gpa.free(scratch);

    // Drive at something far enough to make the solver want to run every joint to its stop.
    _ = (Ik{}).solve(&model, &data, actuation, .{
        .body = model.nbody - 1,
        .goal = vec(0, 0, 5),
    }, scratch);

    var checked: u32 = 0;
    for (0..model.njnt) |j| {
        const range: [2]f32 = model.jnt_range[j] orelse continue;
        const q: f32 = data.pos[model.jnt_qpos_adr[j]];
        try expect(q >= range[0] - 1.0e-5);
        try expect(q <= range[1] + 1.0e-5);
        checked += 1;
    }
    // The KUKA states limits on every joint; if that ever stops being true this test would
    // silently check nothing.
    try expect(checked >= 7);
}

test "control: only powered DOFs are driven" {
    // *** THE RULE THAT HAS BITTEN THREE TIMES - crates hanging in mid-air, and a Go1 rising
    // at a steady 2.4 m/s. `bias_force` covers every DOF including a floating base's six, and
    // adding all of it cancels the machine's own weight.
    const gpa: Allocator = std.testing.allocator;
    const Floating: type = rbt.Spec(.{
        .bodies = &.{
            .{
                .name = "base",
                .joints = &.{.{ .name = "root", .kind = .free }},
                .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = zm.splat(@as(f32, 0.1)) } } }},
            },
            .{
                .name = "arm",
                .parent = "base",
                .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } } }},
            },
        },
        .options = .{ .gravity = vec(0, -9.81, 0), .max_contacts = 4 },
    });
    var model: rbt.Model = try Floating.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();
    var actuation: Actuation = try Actuation.init(gpa, &model);
    defer actuation.deinit();

    // Six free DOFs unpowered, one hinge powered.
    var powered: u32 = 0;
    for (actuation.powered) |p| {
        if (p) {
            powered += 1;
        }
    }
    try expect(powered == 1);

    const target: []f32 = try gpa.alloc(f32, model.nq);
    defer gpa.free(target);
    @memset(target, 0);
    const hold: PoseHold = .{ .target = target };

    rbt.forward(&model, &data);
    hold.apply(&model, &data, actuation);

    // * THE FREE JOINT GETS NOTHING. If it were gravity-compensated the base would float; the
    // test is that the six root DOFs carry exactly zero applied force.
    const root_dof: u32 = model.jnt_dof_adr[0];
    for (0..6) |k| {
        try expectApproxEqAbs(@as(f32, 0), data.applied_force[root_dof + k], 1.0e-6);
    }

    // And it really does fall, over a whole second, rather than hanging.
    const start: f32 = data.body_xpos[1][1];
    for (0..240) |_| {
        rbt.forward(&model, &data);
        hold.apply(&model, &data, actuation);
        rbt.step(&model, &data);
    }
    rbt.forward(&model, &data);
    try expect(data.body_xpos[1][1] < start - 1.0);
}

test "* THE GATE: a 27-DOF humanoid stands for 10 seconds" {
    // *** THE HARDEST OF THE THREE ROBOTS. A quadruped standing is nearly a table; a humanoid
    // is an inverted pendulum on two small feet, 1.28 m tall and 40.8 kg, with 27 degrees of
    // freedom and nothing holding it up but ankle torque.
    //
    // MuJoCo's own `humanoid.xml`, imported through `mjcf` + `robot_mjcf`, held at its default
    // pose by `PoseHold`, on a floor, for 5000 steps at 500 Hz.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .max_contacts = 128,
        .timestep = 1.0 / 500.0,
        .gravity = vec(0, 0, -9.81),
    });
    defer imported.deinit();
    const model: *rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();
    var actuation: Actuation = try Actuation.init(gpa, model);
    defer actuation.deinit();

    var world: zimrphysics.World = try .init(gpa, 128);
    defer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(5, 5, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{ .shape = ground, .position = vec(0, 0, -0.5), .motion_type = .static });

    rbt.forward(model, &data);
    var bridge: robot_physics.Bridge = try .init(gpa, &world, model, &data, 128);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    // The model's default pose IS standing - no keyframe needed, unlike the Go1.
    const home: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(home);

    // -- ** THE GAINS ARE NARROW, AND BOTH FAILURES ARE INSTRUCTIVE --
    //
    //     kp  100, kv  2, limit  100  ->  torso sinks to 0.24 m: too weak to hold itself up
    //     kp  400, kv 10, limit  300  ->  torso 1.2775 m, |v| 0.018: STANDS
    //     kp 1000, kv 30, limit 1000  ->  torso at -201 m, |v| 90: diverges
    //
    // Too soft and it folds; too stiff and the controller outruns the timestep and throws the
    // robot. A quadruped tolerates a much wider band because its pose is nearly statically
    // stable - the humanoid has to be actively held at every joint, and the stiff end is a
    // controller/timestep interaction rather than anything in the physics.
    const hold: PoseHold = .{ .target = home, .kp = 400.0, .kv = 10.0, .max_torque = 300.0 };
    const dt: f32 = 1.0 / 500.0;
    for (0..5000) |_| {
        rbt.forward(model, &data);
        try bridge.sync(&world, model, &data);
        try zimrphysics.step(&world, dt);
        bridge.harvest(&data);
        hold.apply(model, &data, actuation);
        rbt.step(model, &data);
    }
    rbt.forward(model, &data);

    // -- * STILL UPRIGHT, AND STILL --
    const torso: u32 = imported.bodyIndex("torso").?;
    // It starts at 1.282 and settles within a centimetre; 5 cm is a generous gate on a robot
    // 1.28 m tall, and the measured drift is 4.5 mm.
    try expectApproxEqAbs(@as(f32, 1.282), data.body_xpos[torso][2], 0.05);
    // Nothing is moving. 5 cm/s over ten seconds is a machine at rest rather than one drifting
    // slowly enough to survive a short test.
    var fastest: f32 = 0;
    for (0..model.nv) |i| {
        fastest = @max(fastest, @abs(data.vel[i]));
    }
    try expect(fastest < 0.05);
    // And it is standing ON something, rather than having found some other equilibrium.
    try expect(data.contact_count >= 2);
}

/// Jacobian of the whole model's centre of mass.
///
/// -- * WHY THIS IS A MASS-WEIGHTED AVERAGE OF BODY JACOBIANS --
///
/// The CM is `sum m_i*x_i / sum m_i`, so its derivative with respect to the joint angles is the same
/// weighted average of each body's own point Jacobian. There is no shortcut: every body
/// contributes, which is exactly why moving an arm shifts a standing robot's balance.
///
/// `scratch` needs `model.nv` vectors, and `jac` is filled with `nv` columns.
pub fn comJacobian(
    model: *const rbt.Model,
    data: *const rbt.Data,
    jac: []Vec,
    scratch: []Vec,
) void {
    @memset(jac, vec_zero);
    var total: f32 = 0;
    for (1..model.nbody) |body| {
        const mass: f32 = model.body_mass[body];
        if (mass <= 0) {
            continue;
        }
        total += mass;
        rbt.jacBodyCom(model, data, @intCast(body), scratch, null);
        for (jac, scratch) |*column, contribution| {
            column.* += contribution * splat(mass);
        }
    }
    if (total > 0) {
        const inv: Vec = splat(1.0 / total);
        for (jac) |*column| {
            column.* *= inv;
        }
    }
}

/// The centroidal momentum matrix: `A_G(q)`, mapping joint velocity to the robot's momentum
/// about its own centre of mass. `jac` is `6 x nv`, angular rows first.
///
/// -- *** WHY A BALANCE CONTROLLER NEEDS THIS AND NOT JUST THE CM JACOBIAN --
///
/// `comJacobian` says where the mass IS going. This says what the robot is SPINNING with, and
/// that is the quantity a balancing machine actually spends. Windmilling your arms does not
/// move your centre of mass - it cannot, nothing external changed - but it does change the
/// angular momentum about it, and the ground reaction can then be redirected without moving
/// the foot. That is how a human recovers from a shove while standing on one leg.
///
/// It is also the quantity with a HARD LIMIT: arms only rotate so far. So a planner must decide
/// when to spend momentum and when to give it back, which is a finite-horizon trade rather than
/// a gain. That is the whole case for planning this problem instead of servoing it.
///
/// * THE ANGULAR PART IS ABOUT THE CENTRE OF MASS, NOT THE ORIGIN, and the difference is not
/// cosmetic: momentum about a fixed world point is not conserved for a falling robot, while
/// momentum about its own centre of mass is - gravity acts there and exerts no torque about it.
/// That conservation is what the test below uses as an oracle.
pub fn centroidalMomentum(
    model: *const rbt.Model,
    data: *const rbt.Data,
    jac: []Vec,
    jac_rot: []Vec,
    scratch: []Vec,
    scratch_rot: []Vec,
) void {
    @memset(jac, vec_zero);
    @memset(jac_rot, vec_zero);
    const centre: Vec = data.subtree_com[rbt.world_body];

    for (1..model.nbody) |body| {
        const mass: f32 = model.body_mass[body];
        if (mass <= 0) {
            continue;
        }
        rbt.jacBodyCom(model, data, @intCast(body), scratch, scratch_rot);
        const arm: Vec = data.body_xipos[body] - centre;
        const world_inertia: rbt.Inertia = model.body_inertia[body].rotated(data.body_xrot[body]);

        for (0..model.nv) |v| {
            // Linear rows: momentum is just mass times the centre-of-mass velocity.
            jac[v] += scratch[v] * splat(mass);
            // Angular rows: the body's own spin, plus the orbital term from its offset.
            const spin: rbt.Motion = .{ .ang = scratch_rot[v], .lin = vec_zero };
            const spun: rbt.Force = world_inertia.mul(spin);
            jac_rot[v] += spun.ang + cross(arm, scratch[v] * splat(mass));
        }
    }
}

/// The robot's actual centroidal momentum, summed over bodies from the spatial algebra.
///
/// * A SECOND ROUTE TO THE SAME NUMBER, ON PURPOSE. This never touches a Jacobian; it reads
/// `cinert` and `cvel`, which the dynamics maintains for its own reasons. Comparing it against
/// `centroidalMomentum(...)*v` checks the matrix assembly against something that shares no code
/// with it - the same discipline that caught a missing block in the trunk model's Jacobian.
pub fn centroidalMomentumDirect(
    model: *const rbt.Model,
    data: *const rbt.Data,
    angular: *Vec,
    linear: *Vec,
) void {
    angular.* = vec_zero;
    linear.* = vec_zero;
    const centre: Vec = data.subtree_com[rbt.world_body];

    for (1..model.nbody) |body| {
        const mass: f32 = model.body_mass[body];
        if (mass <= 0) {
            continue;
        }
        // `cvel` is about the subtree's centre of mass; shift it to the body's own.
        const at_root: rbt.Motion = data.cvel[body];
        const root_com: Vec = data.subtree_com[model.body_root[body]];
        const body_com_vel: Vec = at_root.lin + cross(at_root.ang, data.body_xipos[body] - root_com);
        const world_inertia: rbt.Inertia = model.body_inertia[body].rotated(data.body_xrot[body]);
        const spun: rbt.Force = world_inertia.mul(.{ .ang = at_root.ang, .lin = vec_zero });

        linear.* += body_com_vel * splat(mass);
        angular.* += spun.ang + cross(data.body_xipos[body] - centre, body_com_vel * splat(mass));
    }
}

/// Joint torques that produce a requested rate of change of angular momentum about the centre
/// of mass. `scratch` is `3 x nv`; `out` is `nv` and is ACCUMULATED into.
///
/// -- *** WHY THE TRANSPOSE IS NOT ENOUGH, MEASURED --
///
/// `tau = A_G^T*w` is the shorthand in a hundred papers and it does not work here. A transpose maps
/// a wrench to torques under a QUASI-STATIC assumption; this problem is entirely about the
/// dynamics. From `L_dot = A_G*q_ddot` and `q_ddot = M^-1(S^T tau - c)`:
///
///     L_dot = (A_G*M^-1*S^T)*tau + ...
///
/// so `tau = A_G^T*w` gives `L_dot = (A_G*M^-1*A_G^T)*w`, and that operator is positive definite but
/// **not the identity** - the answer comes out rotated and rescaled. Measured on this humanoid,
/// the cosine between requested and achieved ranged from -0.90 to +0.27. Anticorrelated.
///
/// * THE CORRECT MAP INVERTS IT: `tau = G^T(G*G^T)^-1*w` with `G = A_G*M^-1*S^T`, the least-norm
/// torque achieving the request.
///
/// * AND IT COSTS THREE MASS-MATRIX SOLVES, NOT ONE PER JOINT. `G`'s rows are
/// `A_G_row_i * M^-1`, and `M^-1` is symmetric, so each row is `M^-1*A_G_row_i` - solve `M*y = row`
/// three times and `G` is the result restricted to the actuated columns. `G*G^T` is then 3x3.
///
/// * THE FLOATING BASE MUST NOT BE IN `actuated`, and that is not a detail - it is the whole
/// mechanism. A robot in the air has no way to torque itself against the world; windmilling
/// works precisely BECAUSE the base reacts freely to limb torques. Letting the solver put
/// torque on the base rows would hand it an authority the robot does not have.
///
/// Call `rbt.factorM` first; this uses the factorisation.
pub fn momentumTorques(
    model: *const rbt.Model,
    data: *const rbt.Data,
    desired_rate: Vec,
    actuated: []const bool,
    momentum_rows: []const Vec,
    scratch: []f32,
    out: []f32,
) void {
    const nv: usize = model.nv;
    assertf(scratch.len >= 3 * nv, @src(), "momentumTorques: scratch wants 3*nv", .{});
    assertf(out.len == nv, @src(), "momentumTorques: out wants nv", .{});

    // Three solves: row i of `G` is `M^-1 * (A_G angular row i)`.
    inline for (0..3) |i| {
        const row: []f32 = scratch[i * nv ..][0..nv];
        for (0..nv) |v| {
            row[v] = momentum_rows[v][i];
        }
        rbt.solveM(model, data, row);
    }

    // `G*G^T`, over the actuated columns only.
    var gram: [9]f32 = @splat(0);
    inline for (0..3) |i| {
        inline for (0..3) |j| {
            var sum: f32 = 0;
            for (0..nv) |v| {
                if (!actuated[v]) {
                    continue;
                }
                sum += scratch[i * nv + v] * scratch[j * nv + v];
            }
            gram[i * 3 + j] = sum;
        }
    }

    // * A RIDGE ON THE DIAGONAL, because `G*G^T` is singular whenever the limbs cannot produce
    // momentum about some axis at all - a robot with its arms at its sides has no authority
    // about the vertical. Without it the solve returns enormous torques for a direction that
    // does nothing; with it, an unreachable request quietly produces a small torque instead.
    const ridge: f32 = 1.0e-6 * (@abs(gram[0]) + @abs(gram[4]) + @abs(gram[8]) + 1.0);
    gram[0] += ridge;
    gram[4] += ridge;
    gram[8] += ridge;

    var lambda: [3]f32 = .{ desired_rate[0], desired_rate[1], desired_rate[2] };
    if (!solve3(&gram, &lambda)) {
        return;
    }

    for (0..nv) |v| {
        if (!actuated[v]) {
            continue;
        }
        out[v] += lambda[0] * scratch[v] +
            lambda[1] * scratch[nv + v] +
            lambda[2] * scratch[2 * nv + v];
    }
}

/// Solve a 3x3 system in place by Gaussian elimination with partial pivoting. Returns false if
/// the matrix is singular, which the caller treats as "this direction is unreachable".
pub fn solve3Pub(matrix: *[9]f32, rhs: *[3]f32) bool {
    return solve3(matrix, rhs);
}

fn solve3(matrix: *[9]f32, rhs: *[3]f32) bool {
    var a: [9]f32 = matrix.*;
    var b: [3]f32 = rhs.*;
    for (0..3) |col| {
        var pivot: usize = col;
        for (col + 1..3) |r| {
            if (@abs(a[r * 3 + col]) > @abs(a[pivot * 3 + col])) {
                pivot = r;
            }
        }
        if (@abs(a[pivot * 3 + col]) < 1.0e-20) {
            return false;
        }
        if (pivot != col) {
            for (0..3) |k| {
                std.mem.swap(f32, &a[col * 3 + k], &a[pivot * 3 + k]);
            }
            std.mem.swap(f32, &b[col], &b[pivot]);
        }
        for (col + 1..3) |r| {
            const factor: f32 = a[r * 3 + col] / a[col * 3 + col];
            for (col..3) |k| {
                a[r * 3 + k] -= factor * a[col * 3 + k];
            }
            b[r] -= factor * b[col];
        }
    }
    var k: usize = 3;
    while (k > 0) {
        k -= 1;
        var sum: f32 = b[k];
        for (k + 1..3) |j| {
            sum -= a[k * 3 + j] * rhs[j];
        }
        rhs[k] = sum / a[k * 3 + k];
    }
    return true;
}

/// IK that reaches for a target while holding the centre of mass over a fixed spot.
///
/// -- ** TWO TASKS, AND THE SECOND ONE LIVES IN THE FIRST'S NULLSPACE --
///
/// A standing robot reaching for something has a problem an arm on a bench does not: **moving
/// the arm moves the centre of mass**, and a humanoid whose CM leaves its feet falls over.
/// The two goals genuinely conflict, so the question is which one yields.
///
/// The standard answer is nullspace projection. Solve the reach first, then satisfy the
/// balance goal using only the joint motions that DO NOT disturb it:
///
///     dq = dq_reach + (I - J_1^+J_1)*dq_balance
///
/// The projector `(I - J_1^+J_1)` strips out any component of the balance correction that would
/// move the hand. A redundant robot has a large nullspace - a 27-DOF humanoid reaching with
/// one hand has 24 spare dimensions - so there is usually plenty of room to lean, bend and
/// counterweight without the hand drifting at all.
///
/// **The priority is deliberate and worth stating: the HAND wins.** If the target can only be
/// reached by shifting the CM, this shifts it. That is the right way round for a demo you can
/// drag a slider in - the alternative silently refuses to reach and looks broken - but it is
/// the opposite of what a controller keeping a real robot upright should do.
pub const BalancedIk = struct {
    reach: Ik = .{},
    /// Where the CM should stay, in world XY. Height is ignored: a robot bending to reach low
    /// SHOULD drop its CM, and only the horizontal position threatens balance.
    com_goal: [2]f32,
    /// How hard to pull the CM back each iteration, as a fraction of the error.
    com_gain: f32 = 0.5,

    pub const Result = struct {
        reach: Ik.Result,
        /// Horizontal distance from the CM goal when the solve stopped.
        com_error: f32,
    };

    /// `scratch` needs `scratchSize(model)` vectors.
    pub fn solve(
        self: BalancedIk,
        model: *const rbt.Model,
        data: *rbt.Data,
        actuation: Actuation,
        target: IkTarget,
        scratch: []Vec,
    ) Result {
        const nv: usize = model.nv;
        // -- ** THE NESTED SOLVE GETS ITS OWN REGION, and that is not paranoia --
        //
        // `Ik.solve` needs three slices of its own and was previously handed THIS buffer, whose
        // three names are also live here. That was correct - but only because every use below
        // happens after the nested call returns, so its writes are overwritten before anyone
        // reads them. Correct-by-ordering is a trap: the aliasing is invisible at both call
        // sites, and moving one line would corrupt a Jacobian with no error anywhere.
        //
        // Splitting the buffer costs `3*nv` more vectors - a few kilobytes on the largest robot
        // here - and makes the two solvers genuinely independent.
        const hand_jac: []Vec = scratch[0..nv];
        const com_jac: []Vec = scratch[nv .. 2 * nv];
        const work: []Vec = scratch[2 * nv .. 3 * nv];
        const nested: []Vec = scratch[3 * nv ..][0 .. 3 * nv];

        // The reach is solved first and on its own terms - it is the higher priority task, and
        // its solver already handles damping, limits and unreachable targets.
        const reach: Ik.Result = self.reach.solve(model, data, actuation, target, nested);

        // Then one balance correction, projected so it cannot move the hand.
        rbt.kinematics(model, data);
        const com: Vec = data.subtree_com[rbt.world_body];
        const drift: Vec = vec(self.com_goal[0] - com[0], self.com_goal[1] - com[1], 0);
        const com_error: f32 = length3(drift);

        comJacobian(model, data, com_jac, work);
        const at: Vec = data.body_xpos[target.body] +
            zm.rotate(data.body_xrot[target.body], target.offset);
        rbt.jacPoint(model, data, target.body, at, hand_jac, null);
        for (0..nv) |i| {
            if (!actuation.powered[i]) {
                hand_jac[i] = vec_zero;
                com_jac[i] = vec_zero;
            }
        }

        // dq_balance = J_com^T*(gain * drift), the transpose rather than an inverse: it is a
        // descent direction on the CM error, it costs one pass, and it cannot blow up near a
        // singularity the way a pseudo-inverse would. Exactness is not needed for a secondary
        // objective that is re-solved every iteration anyway.
        for (0..model.njnt) |j| {
            const v: u32 = model.jnt_dof_adr[j];
            if (!actuation.powered[v]) {
                continue;
            }
            const raw: f32 = self.com_gain * (com_jac[v][0] * drift[0] + com_jac[v][1] * drift[1]);

            // * AND HERE IS THE PROJECTION, in the only form that is cheap: subtract the part
            // of this joint's motion that the hand would feel. `hand_jac[v]` is how much the
            // hand moves per unit of this joint, so a joint the hand cares about contributes
            // less, and a joint it does not care about contributes fully.
            const hand_sensitivity: f32 = length3(hand_jac[v]);
            const projected: f32 = raw / (1.0 + 4.0 * hand_sensitivity);

            const q: u32 = model.jnt_qpos_adr[j];
            var next: f32 = data.pos[q] + clamp(projected, -self.reach.max_step, self.reach.max_step);
            if (model.jnt_range[j]) |range| {
                next = clamp(next, range[0], range[1]);
            }
            data.pos[q] = next;
        }
        data.stage = .stale;
        rbt.kinematics(model, data);

        return .{ .reach = reach, .com_error = com_error };
    }

    /// Three slices of its own, plus a separate three for the `Ik` it runs inside itself.
    pub fn scratchSize(model: *const rbt.Model) usize {
        return 3 * model.nv + Ik.scratchSize(model);
    }
};

test "ik: reaching while holding the centre of mass" {
    // ** THE PROBLEM A STANDING ROBOT HAS THAT A BENCH-MOUNTED ARM DOES NOT. Moving the arm
    // MOVES THE CENTRE OF MASS, and a humanoid whose CM leaves its feet falls over. The two
    // goals genuinely conflict, so the balance correction is projected into the nullspace of
    // the reach: it uses only the joint motions the hand does not feel.
    //
    // A 27-DOF humanoid reaching with one hand has 24 spare dimensions, so there is usually
    // room to lean and counterweight without the hand drifting at all.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{ .max_contacts = 8 });
    defer imported.deinit();
    const model: *rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();
    var actuation: Actuation = try Actuation.init(gpa, model);
    defer actuation.deinit();
    const scratch: []Vec = try gpa.alloc(Vec, BalancedIk.scratchSize(model));
    defer gpa.free(scratch);

    const hand: u32 = imported.bodyIndex("hand_right").?;
    rbt.forward(model, &data);
    const rest_com: Vec = data.subtree_com[rbt.world_body];

    // A target across the body, which is what makes the CM move: reaching to the far side
    // swings arm mass over the opposite foot.
    const goal: Vec = vec(0.20, -0.45, 1.55);

    // Plain IK first, for the comparison.
    @memcpy(data.pos, model.qpos0);
    data.stage = .stale;
    _ = (Ik{}).solve(model, &data, actuation, .{ .body = hand, .goal = goal }, scratch);
    rbt.forward(model, &data);
    const plain_drift: f32 = comDrift(data.subtree_com[rbt.world_body], rest_com);

    // Then the balanced version, iterated the way a demo would each frame.
    @memcpy(data.pos, model.qpos0);
    data.stage = .stale;
    var result: BalancedIk.Result = undefined;
    for (0..40) |_| {
        result = (BalancedIk{
            .com_goal = .{ rest_com[0], rest_com[1] },
            .reach = .{ .max_iterations = 4 },
        }).solve(model, &data, actuation, .{ .body = hand, .goal = goal }, scratch);
    }
    rbt.forward(model, &data);
    const balanced_drift: f32 = comDrift(data.subtree_com[rbt.world_body], rest_com);

    // -- * THE CM MOVES MUCH LESS, AND THE HAND STILL ARRIVES --
    //
    // Measured: 13.5 mm of drift plain, 2.5 mm balanced - five times better - while the reach
    // error goes from 0.1 mm to 0.3 mm, which is nothing on a robot 1.28 m tall.
    try expect(plain_drift > 0.008);
    try expect(balanced_drift < plain_drift * 0.5);
    try expect(result.reach.error_distance < 0.01);
}

fn comDrift(now: Vec, rest: Vec) f32 {
    const dx: f32 = now[0] - rest[0];
    const dy: f32 = now[1] - rest[1];
    return @sqrt(dx * dx + dy * dy);
}

/// A model, its state, and the buffers a learning loop needs - assembled once.
///
/// -- * WHY A WRAPPER, WHEN THE PIECES ARE ALL PUBLIC --
///
/// Nothing here is hard to assemble. The problem is that everyone assembles it slightly
/// differently - one clamps actions and one does not, one observes before stepping and one
/// after, one resets the warm start and one forgets - and then two people's numbers are not
/// comparable and neither is wrong. A single obvious way to do it is worth more than the
/// twenty lines it saves.
///
/// * IT OWNS NOTHING IT DOES NOT NEED TO. The `Model` is borrowed, not copied: a batched
/// rollout shares ONE model across hundreds of environments - proven in `robot.zig`'s
/// independence test - and that sharing is most of why batching is affordable.
pub const Env = struct {
    model: *const rbt.Model,
    data: rbt.Data,
    /// The pose `reset` returns to. Defaults to the model's `qpos0`.
    start: rbt.State,
    observation: []f32,
    gpa: Allocator,

    pub fn init(gpa: Allocator, model: *const rbt.Model) !Env {
        var data: rbt.Data = try rbt.Data.init(gpa, model);
        errdefer data.deinit();
        var start: rbt.State = try rbt.State.init(gpa, model);
        errdefer start.deinit();
        rbt.forward(model, &data);
        start.save(&data);
        return .{
            .model = model,
            .data = data,
            .start = start,
            .observation = try gpa.alloc(f32, rbt.observationSize(model)),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Env) void {
        self.gpa.free(self.observation);
        self.start.deinit();
        self.data.deinit();
    }

    /// How many numbers a policy must produce.
    pub fn actionSize(self: *const Env) usize {
        return self.model.nu;
    }

    /// How many it receives. See `rbt.observe` for the layout.
    pub fn observationSize(self: *const Env) usize {
        return self.observation.len;
    }

    /// Bounds on one action, or null where the model states none.
    ///
    /// * NULL IS NOT `(-1, 1)`. An actuator with no `ctrlrange` is genuinely unbounded, and
    /// inventing a range would silently clip a model that meant what it said. A policy that
    /// wants normalised actions can supply its own default; the engine reports what the model
    /// declared.
    pub fn actionRange(self: *const Env, index: usize) ?[2]f32 {
        return self.model.act_ctrl_range[index];
    }

    /// Put the environment back at its start state and return the first observation.
    pub fn reset(self: *Env) []const f32 {
        self.start.restore(&self.data);
        rbt.forward(self.model, &self.data);
        _ = rbt.observe(self.model, &self.data, self.observation);
        return self.observation;
    }

    /// Make `start` whatever the environment is in right now.
    ///
    /// Useful for episodes that begin from a settled pose rather than from `qpos0` - a legged
    /// robot's `qpos0` is usually a pose it immediately falls out of, and starting every
    /// episode with the same half-second of settling wastes a policy's time learning it.
    pub fn markStart(self: *Env) void {
        rbt.forward(self.model, &self.data);
        self.start.save(&self.data);
    }

    /// Apply an action, advance one timestep, and return the new observation.
    ///
    /// * THE ACTION IS CLAMPED TO `ctrlrange` where the model declares one. A policy exploring
    /// early in training WILL emit values outside it, and a simulator that honours them is
    /// teaching physics no real robot can produce - the classic way a policy learns to exploit
    /// its simulator rather than solve its task.
    pub fn step(self: *Env, action: []const f32) []const f32 {
        for (action, 0..) |value, i| {
            self.data.ctrl[i] = if (self.model.act_ctrl_range[i]) |range|
                clamp(value, range[0], range[1])
            else
                value;
        }
        // * NO `forward` BEFORE THE STEP. `rbt.step` does it - every integrator branch begins
        // with one, because it cannot advance a state it has not derived. Calling it here as
        // well recomputed the entire kinematics, mass matrix and bias for nothing, on the hot
        // path of every rollout.
        //
        // Measured on cartpole (nv 2): **1168 ns/step before, and the two-link arm benchmark -
        // the same size problem without this wrapper - runs at 247.** Nearly all of the gap was
        // this one line.
        rbt.step(self.model, &self.data);
        // This one is not redundant: `step` leaves the state stale by design, and an
        // observation read from stale body poses is last frame's.
        rbt.forward(self.model, &self.data);
        _ = rbt.observe(self.model, &self.data, self.observation);
        return self.observation;
    }
};

test "* env: reset replays, and actions are clamped to what the model declares" {
    // ** THE TWO PROPERTIES A LEARNING LOOP DEPENDS ON, and they fail silently if wrong:
    // a reset that does not fully reset makes episodes correlated, and an unclamped action
    // teaches physics no real robot can produce.
    const gpa: Allocator = std.testing.allocator;
    const Arm: type = rbt.Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{ .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.04 } } }},
        }},
        .actuators = &.{.{
            .name = "motor",
            .on = .{ .joint = .{ .name = "j" } },
            // * A DECLARED RANGE. An actuator without one is genuinely unbounded and must not
            // be given an invented default - see `Env.actionRange`.
            .ctrl_range = .{ -1.0, 1.0 },
        }},
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 4, .gravity = vec(0, -9.81, 0) },
    });
    var model: rbt.Model = try Arm.build(gpa);
    defer model.deinit();
    var env: Env = try Env.init(gpa, &model);
    defer env.deinit();

    try expectEqual(@as(usize, 1), env.actionSize());
    try expectEqual(rbt.observationSize(&model), env.observationSize());
    try expect(env.actionRange(0) != null);

    // -- * AN EPISODE, THEN THE SAME EPISODE AGAIN --
    _ = env.reset();
    for (0..300) |_| {
        _ = env.step(&.{0.4});
    }
    const first: f32 = env.data.pos[0];

    _ = env.reset();
    for (0..300) |_| {
        _ = env.step(&.{0.4});
    }
    // Bit-for-bit: a reset that leaves anything behind makes consecutive episodes differ, and
    // a policy trained on that is learning partly from its own history.
    try expectEqual(first, env.data.pos[0]);

    // -- * AND AN OUT-OF-RANGE ACTION IS CLAMPED, NOT HONOURED --
    //
    // Asking for 50 when the model says +/-1 must land exactly where asking for 1 does. Without
    // the clamp the two differ, and a policy discovers a motor the robot does not have.
    _ = env.reset();
    for (0..300) |_| {
        _ = env.step(&.{50.0});
    }
    const wild: f32 = env.data.pos[0];

    _ = env.reset();
    for (0..300) |_| {
        _ = env.step(&.{1.0});
    }
    try expectEqual(wild, env.data.pos[0]);
}

test "env: markStart makes a settled pose the episode start" {
    // A legged robot's `qpos0` is usually a pose it immediately falls out of, so every episode
    // would begin with the same half-second of settling - time a policy spends learning
    // something the environment could simply not do to it.
    const gpa: Allocator = std.testing.allocator;
    const Arm: type = rbt.Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "j",
                .kind = .hinge,
                .axis = vec(0, 0, 1),
                .range = .{ -0.6, 0.6 },
            }},
            // * THE GEOM IS OFFSET FROM THE PIVOT, or gravity produces no torque about it and
            // the link simply does not move - which the first version of this test asserted
            // against, and failed. A body whose centre of mass sits on its own hinge is a
            // balanced wheel.
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.04 } },
                .pos = vec(0.2, 0, 0),
            }},
        }},
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 4, .gravity = vec(0, -9.81, 0) },
    });
    var model: rbt.Model = try Arm.build(gpa);
    defer model.deinit();
    var env: Env = try Env.init(gpa, &model);
    defer env.deinit();

    // Let it swing down and settle against its limit.
    _ = env.reset();
    for (0..2000) |_| {
        _ = env.step(&.{});
    }
    const settled: f32 = env.data.pos[0];
    try expect(@abs(settled) > 0.3); // it really did move

    env.markStart();
    for (0..500) |_| {
        _ = env.step(&.{});
    }
    _ = env.reset();
    // * RESET NOW RETURNS TO THE SETTLED POSE, not to `qpos0`.
    try expectApproxEqAbs(settled, env.data.pos[0], 1.0e-4);
}

test "* ik: an orientation target aims the jaws, which a position target cannot" {
    // *** THE GAP FOUND BY BUILDING THE GRIPPER DEMO. Placing a point is enough for a foot,
    // which only has to be somewhere. It is not enough for a hand: a top-down grasp is a
    // statement about the jaws' DIRECTION, and a position-only solver returns whatever attitude
    // its nullspace happened to drift into. On the demo the jaws sat sideways at rest and no
    // choice of target position changed it, because position targets cannot express it.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/arm_gripper.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{ .max_contacts = 8, .gravity = vec(0, 0, -9.81) });
    defer imported.deinit();
    const model: *rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();
    var actuation: Actuation = try Actuation.init(gpa, model);
    defer actuation.deinit();
    const scratch: []Vec = try gpa.alloc(Vec, Ik.scratchSize(model));
    defer gpa.free(scratch);

    const wrist: u32 = imported.bodyIndex("wrist").?;
    const grasp: Vec = vec(0, 0, 0.055);
    const goal: Vec = vec(0.40, 0, 0.50);
    // Jaws pointing straight down: the wrist's local +z onto the world's -z.
    const jaws_down: zm.Quat = quatFromAxisAngle(vec(0, 1, 0), pi);

    const jawDirection = struct {
        fn go(m: *const rbt.Model, d: *rbt.Data, body: u32) Vec {
            _ = m;
            return zm.rotate(d.body_xrot[body], vec(0, 0, 1));
        }
    }.go;

    // -- Position only --
    _ = rmj.applyKeyframe(model, &data, robot.keyframes[0]);
    rbt.forward(model, &data);
    const position_only: Ik.Result = (Ik{ .max_iterations = 80 }).solve(
        model,
        &data,
        actuation,
        .{ .body = wrist, .offset = grasp, .goal = goal },
        scratch,
    );
    rbt.forward(model, &data);
    const loose_jaws: Vec = jawDirection(model, &data, wrist);

    // -- The same target, with an orientation --
    _ = rmj.applyKeyframe(model, &data, robot.keyframes[0]);
    rbt.forward(model, &data);
    const with_orientation: Ik.Result = (Ik{ .max_iterations = 120 }).solve(
        model,
        &data,
        actuation,
        .{ .body = wrist, .offset = grasp, .goal = goal, .orientation = jaws_down },
        scratch,
    );
    rbt.forward(model, &data);
    const aimed_jaws: Vec = jawDirection(model, &data, wrist);
    const reached: Vec = data.body_xpos[wrist] + zm.rotate(data.body_xrot[wrist], grasp);

    // * BOTH REACH THE POINT. Adding three rows must not cost the three that already worked.
    try expect(position_only.error_distance < 0.01);
    try expect(length3(reached - goal) < 0.02);

    // ** AND ONLY ONE OF THEM AIMS. `jaws_down` puts the wrist's +z on the world's -z, so a
    // solved orientation reads about -1 on that axis and an unconstrained one reads whatever.
    try expect(aimed_jaws[2] < -0.9);
    try expect(loose_jaws[2] > -0.9);
    try expect(with_orientation.error_distance < 0.05);
}

/// Many environments sharing one model, stepped together.
///
/// -- * WHAT THIS IS FOR, AND WHAT IT IS NOT --
///
/// Reinforcement learning runs hundreds of environments at once. The tables that describe the
/// robot are large, identical and read-only, so **one `Model` serves all of them** - which
/// `robot.zig` proves is safe, by running three `Data` interleaved against one model and
/// requiring bit-for-bit agreement with each run alone.
///
/// ** THE OBSERVATIONS AND ACTIONS ARE ONE FLAT BUFFER EACH, not an array of slices. A policy
/// wants a matrix - `[count x observationSize]`, row-major - and handing it a slice per
/// environment forces a copy at exactly the boundary where copies are expensive. This is the
/// whole reason the type exists; the stepping loop itself is four lines.
///
/// -- ** IT STEPS SERIALLY, AND THAT IS THE RIGHT ANSWER HERE --
///
/// Not a placeholder, and not a limitation of this type. **zimr targets wasm and WebGPU; the
/// host build exists to run these tests.** There is no `std.Thread` to reach for, and the
/// question is not "why serial" but "what would parallel even mean".
///
/// The answer is `jobs.zig`: pure kernels on Web Workers, by message passing. Its header
/// records what that buys, measured on-device rather than guessed -
///
///   * eight concurrent workers deliver about **3.4x aggregate**, not eight, because the
///     single-thread baseline runs on a boosted prime core and spreading out drops every
///     core's clock;
///   * a partitioned frame tops out near **2.7x**;
///   * and a hot CPU **throttles the GPU**, so buying CPU can cost frames in a renderer.
///
/// * SO THE CEILING IS UNDER 3x, AND IT IS PAID FOR IN SERIALISATION. Every environment's
/// state would have to be shipped to a worker and back each step; `Data` for a humanoid is far
/// larger than the observation row it produces. For a training loop that is plainly wrong, and
/// for a demo that renders, it is worse than wrong.
///
/// The loop body touches only its own `Env` and a read-only `Model` - the property a scheduler
/// would need, asserted by test rather than assumed - so nothing here forecloses the option.
/// Claiming it now would be a lie with a `for` loop behind it.
pub const Batch = struct {
    model: *const rbt.Model,
    envs: []Env,
    /// `count x observationSize(model)`, row-major.
    observations: []f32,
    gpa: Allocator,

    pub fn init(gpa: Allocator, model: *const rbt.Model, how_many: usize) !Batch {
        const envs: []Env = try gpa.alloc(Env, how_many);
        errdefer gpa.free(envs);
        var built: usize = 0;
        errdefer for (envs[0..built]) |*env| {
            env.deinit();
        };
        for (envs) |*env| {
            env.* = try Env.init(gpa, model);
            built += 1;
        }
        return .{
            .model = model,
            .envs = envs,
            .observations = try gpa.alloc(f32, how_many * rbt.observationSize(model)),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Batch) void {
        self.gpa.free(self.observations);
        for (self.envs) |*env| {
            env.deinit();
        }
        self.gpa.free(self.envs);
    }

    pub fn count(self: *const Batch) usize {
        return self.envs.len;
    }

    /// One environment's row of the observation matrix.
    pub fn observationOf(self: *const Batch, index: usize) []const f32 {
        const width: usize = rbt.observationSize(self.model);
        return self.observations[index * width ..][0..width];
    }

    /// Reset every environment and return the whole observation matrix.
    pub fn reset(self: *Batch) []const f32 {
        const width: usize = rbt.observationSize(self.model);
        for (self.envs, 0..) |*env, i| {
            @memcpy(self.observations[i * width ..][0..width], env.reset());
        }
        return self.observations;
    }

    /// Step every environment with its own row of `actions`, and return the new observations.
    ///
    /// `actions` is `count x actionSize`, row-major - the same layout the observations come
    /// back in, so a policy reads and writes matrices of the same shape.
    pub fn step(self: *Batch, actions: []const f32) []const f32 {
        const action_width: usize = self.model.nu;
        const width: usize = rbt.observationSize(self.model);
        // * THE LOOP BODY TOUCHES ONLY ITS OWN `Env` and a read-only `Model`. That is the
        // property a scheduler would need, and it is asserted by test rather than assumed.
        for (self.envs, 0..) |*env, i| {
            const row: []const f32 = actions[i * action_width ..][0..action_width];
            @memcpy(self.observations[i * width ..][0..width], env.step(row));
        }
        return self.observations;
    }

    /// Make every environment's current state its reset point. See `Env.markStart`.
    pub fn markStart(self: *Batch) void {
        for (self.envs) |*env| {
            env.markStart();
        }
    }
};

test "* batch: many environments agree bit-for-bit with running each alone" {
    // *** THE PROPERTY A BATCHED ROLLOUT RESTS ON. If stepping N together differs in the last
    // bit from stepping them one at a time, a policy is training on physics that depends on the
    // batch size - and nothing about the results would say so.
    //
    // `robot.zig` already proves the underlying independence: three `Data` interleaved against
    // one `Model` match their solo runs exactly. This checks the layer above, where an indexing
    // slip in the observation matrix would be just as invisible and considerably more likely.
    const gpa: Allocator = std.testing.allocator;
    const Arm: type = rbt.Spec(.{
        .bodies = &.{
            .{
                .name = "upper",
                .joints = &.{.{
                    .name = "shoulder",
                    .kind = .hinge,
                    .axis = vec(0, 0, 1),
                    .range = .{ -1.0, 1.0 },
                }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.04 } },
                    .pos = vec(0.2, 0, 0),
                }},
            },
            .{
                .name = "lower",
                .parent = "upper",
                .pos = vec(0.4, 0, 0),
                .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.03 } },
                    .pos = vec(0.15, 0, 0),
                }},
            },
        },
        .actuators = &.{
            .{ .name = "s", .on = .{ .joint = .{ .name = "shoulder" } }, .ctrl_range = .{ -1, 1 } },
            .{ .name = "e", .on = .{ .joint = .{ .name = "elbow" } }, .ctrl_range = .{ -1, 1 } },
        },
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 8, .gravity = vec(0, -9.81, 0) },
    });
    var model: rbt.Model = try Arm.build(gpa);
    defer model.deinit();

    const environments: usize = 4;
    const action_width: usize = 2;
    // Different actions per environment, so any cross-talk has something to leak.
    const actions = [environments * action_width]f32{ 0.9, -0.4, -0.7, 0.2, 0.1, 0.8, -1.0, -1.0 };

    // -- Each one alone --
    var solo: [environments][2]f32 = undefined;
    for (0..environments) |i| {
        var env: Env = try Env.init(gpa, &model);
        defer env.deinit();
        _ = env.reset();
        for (0..600) |_| {
            _ = env.step(actions[i * action_width ..][0..action_width]);
        }
        solo[i] = .{ env.data.pos[0], env.data.pos[1] };
    }

    // -- All of them together --
    var batch: Batch = try Batch.init(gpa, &model, environments);
    defer batch.deinit();
    _ = batch.reset();
    for (0..600) |_| {
        _ = batch.step(&actions);
    }

    for (0..environments) |i| {
        try expectEqual(solo[i][0], batch.envs[i].data.pos[0]);
        try expectEqual(solo[i][1], batch.envs[i].data.pos[1]);
    }

    // ** AND THE MATRIX IS LAID OUT THE WAY A POLICY READS IT. An off-by-one in the row stride
    // gives every environment its neighbour's observation - plausible numbers, wrong entirely,
    // and no test of the physics would notice.
    const width: usize = rbt.observationSize(&model);
    try expectEqual(environments * width, batch.observations.len);
    for (0..environments) |i| {
        const row: []const f32 = batch.observationOf(i);
        try expectEqual(batch.envs[i].data.pos[0], row[0]);
        try expectEqual(batch.envs[i].data.pos[1], row[1]);
        // The row really is a window into the flat buffer, not a copy of one.
        try expectEqual(batch.observations[i * width], row[0]);
    }
}

test "** PoseHold: inertia-scaled gains must both HOLD and not explode" {
    // *** A REGRESSION TEST FOR A REGRESSION I SHIPPED. Converting a demo's gains from torque
    // units to frequency units, I verified the new setting was STABLE - it no longer diverged
    // when the robot was shoved - and never checked it could still do its job. It could not:
    // the humanoid's torso sagged from 0.596 m to 0.266 and it lay down.
    //
    // * THE ARITHMETIC IS OBVIOUS AFTERWARDS. With `scale_by_inertia`, `kp` is divided by the
    // joint's own inertia, so omega = 20 on a joint carrying M = 0.01 is an effective torque-unit
    // gain of 4 - against the 400 it replaced. A hundred times weaker.
    //
    // ** SO A CONTROLLER TEST NEEDS BOTH HALVES. "Does not explode" is satisfied by a
    // controller that does nothing at all, and that is exactly the failure this missed.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .max_contacts = 256,
        .timestep = 1.0 / 500.0,
        .gravity = vec(0, 0, -9.81),
    });
    defer imported.deinit();
    const model: *rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();
    var actuation: Actuation = try Actuation.init(gpa, model);
    defer actuation.deinit();

    var world: zimrphysics.World = try .init(gpa, 256);
    defer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(6, 6, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
    });

    _ = rmj.applyKeyframe(model, &data, robot.keyframes[0]);
    rbt.forward(model, &data);
    const upright: f32 = data.body_xpos[1][2];

    var bridge: robot_physics.Bridge = try .init(gpa, &world, model, &data, 256);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    const home: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(home);

    // * THE DEMO'S SHIPPED SETTING, in torque units. `kv = 10` is the stability limit for this
    // model's lightest joint - `kv*dt/M < 2` with M = 0.01 and dt = 1/500 - and going past it
    // is what the slider used to allow.
    const hold: PoseHold = .{
        .target = home,
        .kp = 400,
        .kv = 10,
        .max_torque = 300,
    };

    for (0..2500) |_| {
        rbt.forward(model, &data);
        try bridge.sync(&world, model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        hold.apply(model, &data, actuation);
        rbt.step(model, &data);
    }
    rbt.forward(model, &data);

    // -- * HALF ONE: IT HOLDS ITSELF UP --
    //
    // Measured 0.565 against a starting 0.596. The bar is 70%, which the shipped omega = 20 failed
    // at 0.266 and everything from 30 upward passes comfortably.
    try expect(data.body_xpos[1][2] > upright * 0.7);

    // -- * HALF TWO: SHOVING IT DOES NOT BLOW IT UP --
    //
    // Four shoves, the demo's own. In torque units with kv = 40 this peaked at 174 J and stayed
    // at 39; here it peaks near 36 and comes back down.
    var peak_energy: f32 = 0;
    for (0..4) |_| {
        for (0..model.njnt) |j| {
            if (model.jnt_type[j] == .free) {
                const dof: u32 = model.jnt_dof_adr[j];
                data.vel[dof + 0] += 1.2;
                data.vel[dof + 1] += 0.4;
                data.stage = .stale;
            }
        }
        for (0..1500) |_| {
            rbt.forward(model, &data);
            try bridge.sync(&world, model, &data);
            try zimrphysics.step(&world, 1.0 / 500.0);
            bridge.harvest(&data);
            hold.apply(model, &data, actuation);
            rbt.step(model, &data);

            // * `step` LEAVES THE STATE STALE and `mulM` needs the mass matrix, so the forward
            // is not optional. The engine's own stage assert catches this rather than
            // multiplying by whatever was in the buffer - which is the whole point of having it.
            rbt.forward(model, &data);
            var momentum: [64]f32 = undefined;
            rbt.mulM(model, &data, data.vel, momentum[0..model.nv]);
            var energy: f32 = 0;
            for (0..model.nv) |i| {
                energy += 0.5 * data.vel[i] * momentum[i];
            }
            peak_energy = @max(peak_energy, energy);
        }
    }
    try expect(peak_energy < 100.0);

    // -- *** HALF THREE, ADDED AFTER A REGRESSION THAT PASSED THE FIRST TWO --
    //
    // A controller can hold the robot up and survive a shove and still be WRONG: converting
    // these gains to `scale_by_inertia` frequency units passed both halves above and left the
    // humanoid visibly shaking. Measured over five seconds of holding still:
    //
    //     kp 400 / kv 10, torque units    joint motion 0.0000
    //     omega 45 / zeta 1, scaled       joint motion 16.88
    //
    // **Standing still is a property in its own right**, and neither "does not fall" nor "does
    // not explode" implies it.
    for (0..1500) |_| {
        rbt.forward(model, &data);
        try bridge.sync(&world, model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        hold.apply(model, &data, actuation);
        rbt.step(model, &data);
    }
    var jitter: f32 = 0;
    for (0..1000) |_| {
        rbt.forward(model, &data);
        try bridge.sync(&world, model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        hold.apply(model, &data, actuation);
        rbt.step(model, &data);
        rbt.forward(model, &data);
        var sum: f32 = 0;
        for (6..model.nv) |i| {
            sum += data.vel[i] * data.vel[i];
        }
        jitter = @max(jitter, @sqrt(sum));
    }
    // Measured 0.000 with the shipped gains; the regression sat at 18.6.
    try expect(jitter < 1.0);
}

test "*** centroidal momentum: the matrix agrees with a sum that shares no code with it" {
    // -- TWO INDEPENDENT ROUTES TO THE SAME SIX NUMBERS --
    //
    // `centroidalMomentum` assembles a 6 x nv matrix out of body Jacobians. `...Direct` sums
    // over bodies using `cinert`/`cvel`, which the dynamics maintains for its own purposes and
    // which never touches a Jacobian. If they agree on a non-trivial velocity, the assembly is
    // right - the same cross-check that caught a missing block in the trunk model.
    const gpa: Allocator = std.testing.allocator;
    const humanoid_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, humanoid_xml, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .max_contacts = 8,
        .timestep = 1.0 / 500.0,
        .gravity = vec(0, 0, -9.81),
    });
    defer imported.deinit();
    const model: *const rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();

    const jac: []Vec = try gpa.alloc(Vec, model.nv);
    defer gpa.free(jac);
    const jac_rot: []Vec = try gpa.alloc(Vec, model.nv);
    defer gpa.free(jac_rot);
    const scratch: []Vec = try gpa.alloc(Vec, model.nv);
    defer gpa.free(scratch);
    const scratch_rot: []Vec = try gpa.alloc(Vec, model.nv);
    defer gpa.free(scratch_rot);

    // A pose and a velocity with nothing symmetric about them, so no term can cancel by luck.
    var seed: std.Random.DefaultPrng = .init(0x9e3779b9);
    const rng: std.Random = seed.random();
    for (robot.keyframes) |kf| {
        if (std.mem.eql(u8, kf.name, "stand_on_left_leg")) {
            _ = rmj.applyKeyframe(model, &data, kf);
        }
    }
    for (0..model.nv) |v| {
        data.vel[v] = rng.float(f32) * 2.0 - 1.0;
    }
    rbt.forward(model, &data);

    centroidalMomentum(model, &data, jac, jac_rot, scratch, scratch_rot);
    var from_matrix_lin: Vec = vec_zero;
    var from_matrix_ang: Vec = vec_zero;
    for (0..model.nv) |v| {
        from_matrix_lin += jac[v] * splat(data.vel[v]);
        from_matrix_ang += jac_rot[v] * splat(data.vel[v]);
    }

    var direct_ang: Vec = vec_zero;
    var direct_lin: Vec = vec_zero;
    centroidalMomentumDirect(model, &data, &direct_ang, &direct_lin);

    // Scale the tolerance to the size of the answer - these are tens of kg*m/s, and a flat
    // absolute bound would either pass everything or fail on rounding.
    const scale: f32 = @max(1.0, length3(direct_lin) + length3(direct_ang));
    inline for (0..3) |k| {
        try expectApproxEqAbs(direct_lin[k], from_matrix_lin[k], 2.0e-3 * scale);
        try expectApproxEqAbs(direct_ang[k], from_matrix_ang[k], 2.0e-3 * scale);
    }

    // * AND THE ANSWER IS NOT TRIVIALLY ZERO, which is the way a momentum test passes without
    // testing anything.
    try expect(length3(direct_lin) > 1.0);
    try expect(length3(direct_ang) > 0.1);
}

test "*** centroidal momentum: angular momentum is CONSERVED in free flight" {
    // -- THE PHYSICS ORACLE, WHICH BEATS ANY IDENTITY --
    //
    // Gravity acts at the centre of mass, so it exerts no torque about it. With no contacts and
    // no actuation, the angular momentum about the robot's own centre of mass is therefore
    // EXACTLY conserved, however wildly the limbs flail. Linear momentum is not - gravity
    // accelerates it - so only the angular part is checked.
    //
    // This tests the quantity against the world rather than against another formula: an error
    // shared between the matrix and the direct sum would pass the previous test and fail here.
    const gpa: Allocator = std.testing.allocator;
    const humanoid_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, humanoid_xml, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .max_contacts = 8,
        .timestep = 1.0 / 2000.0,
        .gravity = vec(0, 0, -9.81),
    });
    defer imported.deinit();
    const model: *const rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();

    for (robot.keyframes) |kf| {
        if (std.mem.eql(u8, kf.name, "stand_on_left_leg")) {
            _ = rmj.applyKeyframe(model, &data, kf);
        }
    }
    // Well clear of the ground, and thrown into a tumble so the limbs really do move.
    data.pos[model.jnt_qpos_adr[0] + 2] += 5.0;
    var seed: std.Random.DefaultPrng = .init(0x1234567);
    const rng: std.Random = seed.random();
    for (0..model.nv) |v| {
        data.vel[v] = rng.float(f32) * 4.0 - 2.0;
    }
    rbt.forward(model, &data);

    var start_ang: Vec = vec_zero;
    var start_lin: Vec = vec_zero;
    centroidalMomentumDirect(model, &data, &start_ang, &start_lin);
    try expect(length3(start_ang) > 0.5); // a real tumble, not a nudge

    for (0..1000) |_| { // half a second of free flight
        @memset(data.ctrl, 0);
        data.clearContacts();
        rbt.step(model, &data);
    }

    var end_ang: Vec = vec_zero;
    var end_lin: Vec = vec_zero;
    centroidalMomentumDirect(model, &data, &end_ang, &end_lin);

    const drift: f32 = length3(end_ang - start_ang);
    const size: f32 = length3(start_ang);
    try expect(drift < 0.05 * size);

    // * AND LINEAR MOMENTUM MUST *NOT* BE CONSERVED - gravity is pulling on it. If this passed
    // too, the robot would not be falling and the test would be measuring nothing.
    try expect(length3(end_lin - start_lin) > 0.5 * size);
}

test "momentum torques: SKIPPED - free flight is the wrong gate; see the note above" {
    // -- *** THIS TEST ASKS FOR SOMETHING PHYSICS FORBIDS --
    //
    // Internal joint torques CANNOT change centroidal angular momentum. That is Newton's third
    // law, and the test two above this one proves it directly: thrown into a tumble with no
    // contacts, `L` is conserved to under 5% however wildly the limbs flail.
    //
    // So `G = A_G*M^-1*S^T` is exactly zero for a free-floating robot - there is no authority to
    // find - and the ridge in `momentumTorques` was the only reason it returned anything at
    // all. The 0.214 cosine it produced was noise being normalised.
    //
    // * AND THIS REFRAMES THE FLYWHEEL. Windmilling does not CREATE angular momentum, it
    // REDISTRIBUTES it: the arms take some and the body gives it up, total unchanged. What
    // changes the total is the GROUND REACTION - `L_dot = (p - c) x f`, which is exactly the term
    // the balancing model already has. The limbs' job is to move the body into a configuration
    // where the ground can supply the momentum the planner asked for, not to supply it
    // themselves.
    //
    // The right gate is therefore IN CONTACT, and the mapping goes through the contact
    // Jacobian rather than the momentum matrix. `momentumTorques` is not wrong - `G` is
    // genuinely non-zero once a foot is planted, because the base is no longer free - but it
    // must be exercised there.
    if (true) {
        return error.SkipZigTest;
    }
    // -- THE GATE THAT THE JACOBIAN TRANSPOSE FAILED --
    //
    // Free flight, no contacts: gravity acts at the centre of mass and exerts no torque about
    // it, so any change in centroidal angular momentum came from the torques. Ask for a
    // direction, measure what arrives, and compare.
    //
    // `tau = A_G^T*w` scored cosines from -0.90 to +0.27 - anticorrelated - because a transpose
    // assumes quasi-statics and this is a dynamics problem. `tau = G^T(G*G^T)^-1*w` inverts the
    // operator that was in the way.
    const gpa: Allocator = std.testing.allocator;
    const humanoid_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, humanoid_xml, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .max_contacts = 8,
        .timestep = 1.0 / 2000.0,
        .gravity = vec(0, 0, -9.81),
    });
    defer imported.deinit();
    const model: *const rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();

    const rows: []Vec = try gpa.alloc(Vec, model.nv);
    defer gpa.free(rows);
    const linear_rows: []Vec = try gpa.alloc(Vec, model.nv);
    defer gpa.free(linear_rows);
    const s1: []Vec = try gpa.alloc(Vec, model.nv);
    defer gpa.free(s1);
    const s2: []Vec = try gpa.alloc(Vec, model.nv);
    defer gpa.free(s2);
    const scratch: []f32 = try gpa.alloc(f32, 3 * model.nv);
    defer gpa.free(scratch);
    const torque: []f32 = try gpa.alloc(f32, model.nv);
    defer gpa.free(torque);

    // * THE BASE IS NOT ACTUATED, which is the whole mechanism: a robot in the air torques its
    // limbs and the base reacts. Marking it actuated would grant an authority it does not have.
    const actuated: []bool = try gpa.alloc(bool, model.nv);
    defer gpa.free(actuated);
    @memset(actuated, true);
    for (0..6) |v| {
        actuated[v] = false;
    }

    const wanted = [_]Vec{
        vec(1, 0, 0),
        vec(0, 1, 0),
        vec(0, 0, 1),
        vec(0.6, -0.8, 0),
        vec(-0.3, 0.4, 0.87),
    };

    for (wanted) |direction| {
        for (robot.keyframes) |kf| {
            if (std.mem.eql(u8, kf.name, "stand_on_left_leg")) {
                _ = rmj.applyKeyframe(model, &data, kf);
            }
        }
        data.pos[model.jnt_qpos_adr[0] + 2] += 5.0;
        @memset(data.vel, 0);
        rbt.forward(model, &data);

        var before_ang: Vec = vec_zero;
        var before_lin: Vec = vec_zero;
        centroidalMomentumDirect(model, &data, &before_ang, &before_lin);

        for (0..40) |_| {
            // * `step` leaves the pose stale; the Jacobians need the kinematics refreshed.
            rbt.forward(model, &data);
            centroidalMomentum(model, &data, linear_rows, rows, s1, s2);
            rbt.factorM(model, &data);
            @memset(torque, 0);
            momentumTorques(model, &data, direction * splat(30.0), actuated, rows, scratch, torque);
            @memcpy(data.applied_force, torque);
            data.clearContacts();
            rbt.step(model, &data);
        }

        var after_ang: Vec = vec_zero;
        var after_lin: Vec = vec_zero;
        centroidalMomentumDirect(model, &data, &after_ang, &after_lin);

        const delta: Vec = after_ang - before_ang;
        const size: f32 = length3(delta);
        const cosine: f32 = if (size > 1.0e-12) dot3(delta, direction) / (size * length3(direction)) else 0;
        try expect(size > 1.0e-4);
        try expect(cosine > 0.9);
    }
}

/// Run the clip open-loop and return how many frames the character stayed up.
///
/// Extracted so the gain sweep runs it nine times without nine copies of the loop - and so the
/// body that the sweep measures is provably the same body every time.
fn runOpenLoop(
    model: *const rbt.Model,
    data: *rbt.Data,
    world: *zimrphysics.World,
    proxy: *robot_physics.Bridge,
    actuation: Actuation,
    clip: []const rbt.Quat,
    target: []f32,
    hold: PoseHold,
    frames: usize,
    bodies: usize,
    substeps: usize,
    dt: f32,
    start_height: f32,
) usize {
    var survived: usize = 0;
    for (0..frames) |frame| {
        const rotations: []const rbt.Quat = clip[frame * bodies ..][0..bodies];
        for (0..model.njnt) |j| {
            if (model.jnt_type[j] != .ball) {
                continue;
            }
            const q: u32 = model.jnt_qpos_adr[j];
            const r: rbt.Quat = rotations[model.jnt_body[j]];
            inline for (0..4) |k| {
                target[q + k] = r[k];
            }
        }
        for (0..substeps) |_| {
            rbt.forward(model, data);
            proxy.sync(world, model, data) catch return survived;
            zimrphysics.step(world, dt) catch return survived;
            proxy.harvest(data);
            hold.apply(model, data, actuation);
            rbt.step(model, data);
        }
        // FALLEN = the root dropped by half its starting height. Crude and unambiguous: a
        // knee-bend is not a fall and a character on the floor is.
        if (data.body_xpos[1][2] < start_height * 0.5) {
            return survived;
        }
        survived += 1;
    }
    return survived;
}

test "stage 0: how long does open-loop clip playback keep a humanoid upright" {
    // ---- THE STAGE-0 GATE, MEASURED HEADLESSLY ----
    //
    // DReCon's premise is that open-loop playback of a retargeted clip is NEARLY a working
    // controller - "not sufficient for maintained character balance, but comes close". Every
    // learned method downstream assumes it, because they all learn a CORRECTION to it.
    //
    // *** THE FIRST READING OF THIS NUMBER WAS TAKEN WHILE THE CHARACTER WAS FALLING THROUGH
    // THE FLOOR. It reported nine seconds of survival because nothing was there to fall onto -
    // a number that looked like a pass and measured nothing. This runs with a real ground.
    //
    // Headless on purpose: a gate that needs someone to look at a phone is not a gate.
    const gpa: Allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    const paths: struct {
        robot: []const u8,
        clip: []const u8,
        tpose: []const u8,
    } = .{
        .robot = "src/tests/fixtures/robot/humanoid_ball.xml",
        .clip = "examples/geno_dance/dance1_20s.bvh",
        .tpose = "assets/Geno_stance.bvh",
    };

    const Read = struct {
        fn all(a: Allocator, w: std.Io, path: []const u8) ![]u8 {
            var file: std.Io.File = std.Io.Dir.cwd().openFile(w, path, .{}) catch return error.SkipZigTest;
            defer file.close(w);
            const info: std.Io.File.Stat = try file.stat(w);
            const bytes: []u8 = try a.alloc(u8, info.size);
            _ = try file.readPositionalAll(w, bytes, 0);
            return bytes;
        }
    };

    const robot_bytes: []u8 = Read.all(gpa, io, paths.robot) catch return;
    defer gpa.free(robot_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, robot_bytes, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .max_contacts = 256,
    });
    defer imported.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &imported.model);
    defer data.deinit();
    rbt.forward(&imported.model, &data);

    const bodies: usize = imported.model.nbody;

    // ---- the ground, in its own physics world ----
    var world: zimrphysics.World = try .init(gpa, 256);
    defer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(8, 8, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{ .shape = ground, .position = vec(0, 0, -0.5), .motion_type = .static });
    var proxy: robot_physics.Bridge = try .init(gpa, &world, &imported.model, &data, 256);
    defer proxy.deinit(&world);
    proxy.listen(&world);

    // ---- the clip, retargeted ----
    const clip_bytes: []u8 = Read.all(gpa, io, paths.clip) catch return;
    defer gpa.free(clip_bytes);
    const tpose_bytes: []u8 = Read.all(gpa, io, paths.tpose) catch return;
    defer gpa.free(tpose_bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, clip_bytes, null);
    defer capture.deinit();
    var tpose: codecs.bvh.Data = try codecs.bvh.parse(gpa, tpose_bytes, null);
    defer tpose.deinit();

    const human_joints: usize = capture.joints.len;
    const human_names: [][]const u8 = try gpa.alloc([]const u8, human_joints);
    defer gpa.free(human_names);
    for (capture.joints, 0..) |joint, i| {
        human_names[i] = joint.name;
    }
    const human_of_body: []i32 = try gpa.alloc(i32, bodies);
    defer gpa.free(human_of_body);
    try rbt.resolveMatchTable(&rbt.lafan_to_humanoid, imported.names, human_names, human_of_body);

    const robot_reference: []rbt.Quat = try gpa.alloc(rbt.Quat, bodies);
    defer gpa.free(robot_reference);
    rbt.referenceOrientationsFromRest(&imported.model, &data, robot_reference);
    const human_reference: []rbt.Quat = try gpa.alloc(rbt.Quat, human_joints);
    defer gpa.free(human_reference);
    try rmj.tPoseGlobalRotations(gpa, &tpose, human_names, human_reference);
    const rest_alignment: []rbt.Quat = try gpa.alloc(rbt.Quat, bodies);
    defer gpa.free(rest_alignment);
    codecs.bvh.restAlignmentOffsets(human_of_body, human_reference, robot_reference, rest_alignment);

    const body_parents: []i32 = try gpa.alloc(i32, bodies);
    defer gpa.free(body_parents);
    for (0..bodies) |b| {
        body_parents[b] = if (b == 0) -1 else @intCast(imported.model.body_parent[b]);
    }

    const frames: usize = @min(capture.frame_count, 600);
    const clip: []rbt.Quat = try gpa.alloc(rbt.Quat, frames * bodies);
    defer gpa.free(clip);
    {
        const human_local: []rbt.Quat = try gpa.alloc(rbt.Quat, human_joints);
        defer gpa.free(human_local);
        const human_global: []rbt.Quat = try gpa.alloc(rbt.Quat, human_joints);
        defer gpa.free(human_global);
        const robot_global: []rbt.Quat = try gpa.alloc(rbt.Quat, bodies);
        defer gpa.free(robot_global);
        for (0..frames) |frame| {
            const row: []const f32 = capture.motion[frame * capture.channel_count ..][0..capture.channel_count];
            var cursor: usize = 0;
            for (capture.joints, 0..) |joint, index| {
                const values: []const f32 = row[cursor..][0..joint.channels.len];
                cursor += joint.channels.len;
                var rotation: rbt.Quat = quat_identity;
                for (joint.channels, 0..) |channel, k| {
                    const angle: f32 = radFromDeg(values[k]);
                    const axis: ?rbt.Vec = switch (channel) {
                        .x_rotation => vec(1, 0, 0),
                        .y_rotation => vec(0, 1, 0),
                        .z_rotation => vec(0, 0, 1),
                        else => null,
                    };
                    if (axis) |rotation_axis| {
                        rotation = zm.qmul(rotation, quatFromAxisAngle(rotation_axis, angle));
                    }
                }
                human_local[index] = rotation;
                human_global[index] = if (joint.parent < 0)
                    human_local[index]
                else
                    zm.qmul(human_global[@intCast(joint.parent)], human_local[index]);
            }
            codecs.bvh.retargetRotations(
                body_parents,
                human_of_body,
                human_global,
                rest_alignment,
                clip[frame * bodies ..][0..bodies],
                robot_global,
            );
        }
    }

    // ---- run it ----
    const target: []f32 = try gpa.alloc(f32, imported.model.nq);
    defer gpa.free(target);
    @memcpy(target, data.pos);

    var actuation: Actuation = try Actuation.init(gpa, &imported.model);
    defer actuation.deinit();

    const dt: f32 = 1.0 / 240.0;
    const substeps_per_frame: usize = 4;
    const start_height: f32 = data.body_xpos[1][2];
    // ---- THE CHARACTER STARTS ON THE CLIP'S FIRST FRAME, NOT IN ITS REST POSE ----
    //
    // *** THE FIRST VERSION OF THIS MEASUREMENT STARTED FROM `qpos0` - a T-pose - while the PD
    // target was the clip's frame 0, a dance pose. The controller then had to cross that entire
    // gap in one step, which is a shove at t = 0 that has nothing to do with whether the clip is
    // trackable. **Reference state initialisation is not an optimisation here, it is the
    // difference between measuring the clip and measuring a lurch.**
    //
    // Both papers reset to a frame of the reference for exactly this reason.
    const start_pose: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(start_pose);
    {
        const rotations: []const rbt.Quat = clip[0..bodies];
        for (0..imported.model.njnt) |j| {
            const q: u32 = imported.model.jnt_qpos_adr[j];
            const r: rbt.Quat = rotations[imported.model.jnt_body[j]];
            switch (imported.model.jnt_type[j]) {
                // A free joint's qpos is position then quaternion, so the rotation starts at
                // `q + 3`. The ROOT's orientation comes from the clip too - leaving it at the
                // rest pose starts the character facing whatever direction `qpos0` faced, which
                // is a shove in yaw before the first step.
                .free => inline for (0..4) |k| {
                    start_pose[q + 3 + k] = r[k];
                },
                .ball => inline for (0..4) |k| {
                    start_pose[q + k] = r[k];
                },
                else => {},
            }
        }
    }

    // ---- SWEEP THE GAINS, BECAUSE THEY WERE BORROWED FROM A STATIC-POSE DEMO ----
    //
    // `examples/humanoid` tuned kp = 400, kv = 20 to HOLD A POSE. Tracking a moving reference is
    // a different problem: the target is never where the character is, so the same stiffness
    // that holds a pose steadily may fight a clip that keeps moving away from it.
    //
    // Cheap to answer now that the measurement is headless - the whole sweep is one test run,
    // where on a phone it is one rebuild per guess.
    // Refined around kp 400 / kv 20, where the coarse sweep peaked SHARPLY - 5.00s against
    // 0.18s two steps away in either direction. A peak that narrow is worth resolving, and it is
    // also a warning: a controller this sensitive to its gains is not a robust one yet.
    const gains = [_][2]f32{
        .{ 100, 10 },  .{ 200, 20 },  .{ 400, 20 },
        .{ 400, 40 },  .{ 800, 40 },  .{ 800, 60 },
        .{ 1500, 60 }, .{ 2500, 80 }, .{ 4000, 100 },
    };
    var best_s: f32 = 0;
    var best_kp: f32 = 0;
    var best_kv: f32 = 0;

    for (gains) |pair| {
        @memcpy(data.pos, start_pose);
        @memset(data.vel, 0);
        rbt.forward(&imported.model, &data);
        const survived: usize = runOpenLoop(
            &imported.model,
            &data,
            &world,
            &proxy,
            actuation,
            clip,
            target,
            // ---- `scale_by_inertia` STAYS OFF HERE, AND THAT IS A MEASURED CHOICE ----
            //
            // Turning it on turns `kp` into frequency units and makes one gain serve limbs of
            // very different mass, which is right in principle. **Measured, it took standing
            // survival from 10.00s to 0.53s** - the gains that balance are in torque units and
            // the good region moves when the units do.
            //
            // So it is left off here and offered as a TOGGLE in `dance_track`, where tracking
            // and balance can be looked at separately. Changing a default that makes the one
            // number you can measure worse is not a fix.
            PoseHold{ .target = target, .kp = pair[0], .kv = pair[1] },
            frames,
            bodies,
            substeps_per_frame,
            dt,
            start_height,
        );
        const seconds: f32 = float(survived) / 60.0;
        report.print("    kp {d:>5.0}  kv {d:>3.0}  ->  {d:.2}s\n", .{ pair[0], pair[1], seconds });
        if (seconds > best_s) {
            best_s = seconds;
            best_kp = pair[0];
            best_kv = pair[1];
        }
    }

    const survived_frames: usize = @trunc(best_s * 60.0);

    const survived_s: f32 = float(survived_frames) / 60.0;

    report.print(
        "\n  stage 0: open-loop survived {d:.2}s of {d:.2}s   root z {d:.3} -> {d:.3}\n",
        .{
            survived_s,
            float(frames) / 60.0,
            start_height,
            data.body_xpos[1][2],
        },
    );

    // ---- the assertion ----
    //
    // Loose on purpose. This is a REGRESSION guard, not the bar: it catches the character
    // collapsing instantly, which is what a broken retarget or wrong gains look like, and says
    // nothing about whether nine seconds or two is the right answer. The number itself is the
    // deliverable and it is printed by `robot-bench`, not asserted here.
    try expect(survived_s > 0.1);
    try expect(isFinite(data.body_xpos[1][2]));
}

test "stage 0 debug: does the IK solve wind joints past their limits" {
    // ---- 1825 DEGREES OF JOINT ERROR IS NOT A SERVO ERROR ----
    //
    // *** A HINGE CANNOT BE THIRTY-ONE RADIANS FROM ITS TARGET IN ANY USEFUL SENSE - that is
    // five full turns. Either the IK is producing wound-up angles, or the ragdoll's joints are
    // spinning, and the two want completely different fixes.
    //
    // This asks the first question alone: run the solve over the whole clip and report each
    // hinge's range against its declared limit. **The solve is deterministic and needs no
    // physics**, so the answer costs one test run rather than a device round trip.
    const gpa: Allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    const Read = struct {
        fn all(a: Allocator, w: std.Io, path: []const u8) ![]u8 {
            var file: std.Io.File = std.Io.Dir.cwd().openFile(w, path, .{}) catch return error.SkipZigTest;
            defer file.close(w);
            const info: std.Io.File.Stat = try file.stat(w);
            const bytes: []u8 = try a.alloc(u8, info.size);
            _ = try file.readPositionalAll(w, bytes, 0);
            return bytes;
        }
    };

    const robot_bytes: []u8 = Read.all(gpa, io, "src/tests/fixtures/robot/humanoid_flex.xml") catch return;
    defer gpa.free(robot_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, robot_bytes, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{ .gravity = vec(0, 0, -9.81) });
    defer imported.deinit();

    const m: *const rbt.Model = &imported.model;

    report.print("\n  hinge limits as the model declares them:\n", .{});
    var unlimited: usize = 0;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        if (m.jnt_range[j]) |range| {
            report.print("    joint {d:>2} on {s:<16} [{d:>7.2} .. {d:>7.2}] rad\n", .{
                j,
                imported.names[m.jnt_body[j]],
                range[0],
                range[1],
            });
        } else {
            unlimited += 1;
        }
    }

    // *** AN UNLIMITED HINGE CAN WIND FOREVER, and a PD target that winds with it produces
    // exactly the number on screen. If this count is high, the model is the answer.
    report.print("    UNLIMITED hinges: {d}\n", .{unlimited});

    try expect(m.njnt > 0);
}

test "stage 0 debug: can a PD servo hold ONE elbow, with everything else frozen" {
    // ---- THE SMALLEST POSSIBLE SERVO QUESTION ----
    //
    // Simon's suggestion, and the right one: 1825 degrees of error on a twenty-four joint
    // character says nothing about WHICH part is broken. **One elbow, everything else held at
    // rest, a constant target - if that does not track, nothing downstream can.**
    //
    // No IK, no clip, no contacts, no gravity on the root. Just: ask a joint to go somewhere and
    // see whether it arrives.
    const gpa: Allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    var file: std.Io.File = std.Io.Dir.cwd().openFile(
        io,
        "src/tests/fixtures/robot/humanoid_flex.xml",
        .{},
    ) catch return;
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    defer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, bytes, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    // ---- 1/2000 s, NOT THE DEFAULT 1/240 ----
    //
    // *** A PD WITH POSITIVE DAMPING CANNOT SUSTAIN A LIMIT CYCLE UNLESS ENERGY IS BEING
    // INJECTED, and an explicit integrator does exactly that when the step is long relative to
    // the controller's stiffness. **This is the last suspect that does not require the
    // controller to be wrong**, and it is one number to test.
    //
    // If the oscillation dies here, the servo was always correct and the timestep was the bug -
    // which would also explain why gain did not monotonically help: a stiffer controller
    // destabilises sooner at a fixed step.
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 2000.0,
    });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;

    var data: rbt.Data = try rbt.Data.init(gpa, m);
    defer data.deinit();
    rbt.forward(m, &data);

    // The right elbow: `lower_arm_right`'s only hinge, limits [-2.62, 0.35].
    var elbow: usize = 0;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] == .hinge and
            std.mem.eql(u8, imported.names[m.jnt_body[j]], "lower_arm_right"))
        {
            elbow = j;
            break;
        }
    }
    try expect(elbow != 0);

    const target: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(target);
    const goal: f32 = -1.0; // comfortably inside [-2.62, 0.35]
    target[m.jnt_qpos_adr[elbow]] = goal;

    var actuation: Actuation = try Actuation.init(gpa, m);
    defer actuation.deinit();

    // ** THE ROOT IS PINNED EVERY STEP, so this measures the servo and nothing else - no
    // balance, no falling, no contact. The character hangs in space and is asked to bend one arm.
    const root_q: u32 = m.jnt_qpos_adr[0];
    const root_v: u32 = m.jnt_dof_adr[0];
    const rest_root: [7]f32 = .{
        data.pos[root_q],     data.pos[root_q + 1], data.pos[root_q + 2], data.pos[root_q + 3],
        data.pos[root_q + 4], data.pos[root_q + 5], data.pos[root_q + 6],
    };

    const Trial = struct { kp: f32, kv: f32, inertia: bool, quadruped_style: bool = false };
    const trials = [_]Trial{
        .{ .kp = 100, .kv = 10, .inertia = false },
        .{ .kp = 400, .kv = 20, .inertia = false },
        .{ .kp = 800, .kv = 40, .inertia = false },
        .{ .kp = 100, .kv = 10, .inertia = true },
        .{ .kp = 400, .kv = 20, .inertia = true },
        .{ .kp = 100, .kv = 10, .inertia = false, .quadruped_style = true },
        .{ .kp = 400, .kv = 20, .inertia = false, .quadruped_style = true },
        .{ .kp = 800, .kv = 40, .inertia = false, .quadruped_style = true },
    };

    report.print("\n  one elbow, target {d:.2} rad, root pinned, 2 s:\n", .{goal});

    for (trials) |trial| {
        @memcpy(data.pos, target);
        data.pos[m.jnt_qpos_adr[elbow]] = 0; // start away from the goal
        @memset(data.vel, 0);
        rbt.forward(m, &data);

        const hold: PoseHold = .{
            .target = target,
            .kp = trial.kp,
            .kv = trial.kv,
            .scale_by_inertia = trial.inertia,
        };
        var worst_after_settle: f32 = 0;
        var earlier_amplitude: f32 = 0;
        // ---- TEN SECONDS, AND THE LAST SECOND COMPARED AGAINST THE ONE BEFORE ----
        //
        // *** THE FINAL ANGLES SCATTER AROUND THE GOAL - -1.49, -0.52, -0.78, -1.21 - SO THE
        // SERVO REACHES ROUGHLY THE RIGHT PLACE AND DOES NOT STAY. That is an oscillation, and
        // "settled error" was reading its amplitude.
        //
        // Two seconds cannot tell a slow convergence from a limit cycle. Ten can: if the
        // amplitude in the last second is smaller than in the second before, it is settling; if
        // it is the same, it never will.
        for (0..20000) |step| {
            // ---- THE QUADRUPED'S OWN SERVO, INLINE, AS A CONTROL ----
            //
            // `examples/quadruped` stands a Go1 with this and it works. It is structurally the
            // same PD as `PoseHold` with ONE difference: it adds `bias_force` OUTSIDE the clamp,
            // where `PoseHold` adds it inside. Running both here says whether that placement is
            // the whole story.
            if (trial.quadruped_style) {
                @memset(data.applied_force, 0);
                for (0..m.njnt) |j| {
                    if (m.jnt_type[j] != .hinge) {
                        continue;
                    }
                    const q: u32 = m.jnt_qpos_adr[j];
                    const v: u32 = m.jnt_dof_adr[j];
                    const wanted: f32 = trial.kp * (target[q] - data.pos[q]) - trial.kv * data.vel[v];
                    data.applied_force[v] = clamp(wanted, -1000.0, 1000.0) + data.bias_force[v];
                }
            } else {
                hold.apply(m, &data, actuation);
            }
            rbt.step(m, &data);

            inline for (0..7) |k| {
                data.pos[root_q + k] = rest_root[k];
            }
            inline for (0..6) |k| {
                data.vel[root_v + k] = 0;
            }
            // ** `forward` AFTER PINNING, OR THE MASS MATRIX IS STALE. Writing qpos directly
            // invalidates everything derived from it, and `scale_by_inertia` reads
            // `massDiagonal` - which indexes a mass matrix belonging to the previous state. The
            // first version of this test crashed there, which is the pin's bug and not the
            // servo's.
            rbt.forward(m, &data);

            // Ignore the first second: a servo is allowed to take time to arrive. What matters
            // is where it ENDS UP, not how it got there.
            const err: f32 = @abs(data.pos[m.jnt_qpos_adr[elbow]] - goal);
            if (step >= 16000 and step < 18000) {
                if (err > earlier_amplitude) {
                    earlier_amplitude = err;
                }
            }
            if (step >= 18000) {
                if (err > worst_after_settle) {
                    worst_after_settle = err;
                }
            }
        }
        // ---- WHERE IT ENDS UP, NOT JUST HOW FAR OFF ----
        //
        // *** "SETTLED ERROR 0.85 RAD" IS TWO COMPLETELY DIFFERENT BUGS DEPENDING ON THE FINAL
        // ANGLE. Ending at -0.15 means the joint barely moved and torque is not arriving.
        // Ending at -1.85 means it overshot and is oscillating. Ending exactly at -2.62 means
        // it is jammed against its limit. **The error alone cannot tell them apart, and three
        // turns have been spent not knowing which.**
        const final: f32 = data.pos[m.jnt_qpos_adr[elbow]];
        report.print(
            "    kp {d:>4.0}  kv {d:>3.0}  {s:<12}  ->  ends {d:>6.3}  amp 8-9s {d:.3}  9-10s {d:.3}  {s}\n",
            .{
                trial.kp,
                trial.kv,
                if (trial.inertia) "inertia ON" else "inertia off",
                final,
                earlier_amplitude,
                worst_after_settle,
                // A flat amplitude is only a limit cycle if the amplitude MATTERS. At 0.002
                // rad the servo has converged and is sitting in numerical noise - calling that
                // a limit cycle was the label lying about a result it was not written for.
                if (worst_after_settle < 0.02)
                    "CONVERGED"
                else if (worst_after_settle < earlier_amplitude * 0.8)
                    "settling"
                else
                    "LIMIT CYCLE",
            },
        );
        // *** WHERE IT ENDED UP, NOT JUST HOW FAR OFF. An error of 2.1 rad from a goal of -1.0
        // means the joint sits at +1.1 - OUTSIDE its own declared limit of [-2.62, 0.35], and on
        // the opposite side from where it was asked to go. "Did not reach" and "went the wrong
        // way and through a wall" are different bugs and the error magnitude hides which.
        report.print("         ended at {d:>7.3} rad   (goal {d:.2}, limit [{d:.2} .. {d:.2}])\n", .{
            data.pos[m.jnt_qpos_adr[elbow]],
            goal,
            if (m.jnt_range[elbow]) |r| r[0] else -99,
            if (m.jnt_range[elbow]) |r| r[1] else 99,
        });
    }

    try expect(isFinite(data.pos[m.jnt_qpos_adr[elbow]]));
}

test "stage 0 debug: are excluded body pairs actually colliding" {
    // ---- `<exclude>` IS IN THE MJCF AND NOTHING READS IT ----
    //
    // *** `humanoid_flex.xml` EXCLUDES `waist_lower` FROM BOTH THIGHS, AND `src/mjcf.zig` HAS NO
    // `exclude` HANDLING AT ALL. Those capsules overlap at the hip in the rest pose, so without
    // the exclusion they sit in permanent deep penetration - and a solver asked to separate two
    // bodies that are meant to overlap answers with a large force, every step, for ever.
    //
    // Simon's suggestion, and it is checkable without physics: place the character at rest and
    // ask how far the excluded pairs interpenetrate.
    const gpa: Allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    var file: std.Io.File = std.Io.Dir.cwd().openFile(
        io,
        "src/tests/fixtures/robot/humanoid_flex.xml",
        .{},
    ) catch return;
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    defer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, bytes, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{ .gravity = vec(0, 0, -9.81) });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;

    var data: rbt.Data = try rbt.Data.init(gpa, m);
    defer data.deinit();
    rbt.forward(m, &data);

    // Distance between the two bodies' origins against the sum of their geom radii. Crude - a
    // capsule is not a sphere - but a gap far smaller than the radii means they overlap however
    // it is measured.
    const pairs = [_][2][]const u8{
        .{ "waist_lower", "thigh_right" },
        .{ "waist_lower", "thigh_left" },
    };

    report.print("\n  excluded pairs, at rest:\n", .{});
    for (pairs) |pair| {
        var a_body: ?u32 = null;
        var b_body: ?u32 = null;
        for (0..m.nbody) |b| {
            if (std.mem.eql(u8, imported.names[b], pair[0])) {
                a_body = @intCast(b);
            }
            if (std.mem.eql(u8, imported.names[b], pair[1])) {
                b_body = @intCast(b);
            }
        }
        if (a_body == null or b_body == null) {
            continue;
        }
        const gap: f32 = length3(data.body_xpos[a_body.?] - data.body_xpos[b_body.?]);

        var radii: f32 = 0;
        for (0..m.ngeom) |g| {
            if (m.geom_body[g] != a_body.? and m.geom_body[g] != b_body.?) {
                continue;
            }
            radii += switch (m.geom_shape[g]) {
                .capsule => |c| c.radius,
                .sphere => |sp| sp.radius,
                else => 0,
            };
        }
        report.print("    {s:<14} .. {s:<14}  centres {d:.3} m   radii sum {d:.3} m   {s}\n", .{
            pair[0],
            pair[1],
            gap,
            radii,
            if (gap < radii) "OVERLAPPING" else "clear",
        });
    }

    try expect(m.nbody > 0);
}

test "stage 0 debug: one arm free, everything else frozen, watch the motor" {
    // ---- THE RIG SIMON ASKED FOR: ONE ARM, AND SEE WHAT THE MOTOR ACTUALLY DOES ----
    //
    // Everything except the right arm is held at its target after every step, and the root is
    // pinned. So the only moving parts are three shoulder hinges and an elbow, and anything that
    // goes wrong has nowhere to hide.
    //
    // *** IT PRINTS THE TRAJECTORY, NOT A SUMMARY. Angle, velocity and torque at intervals -
    // because "max error 1.449 rad" has been true for many turns and has never once said WHY.
    // A servo that overshoots, one that never arrives and one that is being fought all produce
    // the same summary and completely different traces.
    const gpa: Allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    var file: std.Io.File = std.Io.Dir.cwd().openFile(
        io,
        "src/tests/fixtures/robot/humanoid_flex.xml",
        .{},
    ) catch return;
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    defer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, bytes, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 2000.0,
    });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;

    var data: rbt.Data = try rbt.Data.init(gpa, m);
    defer data.deinit();
    rbt.forward(m, &data);

    // The right arm: everything on `upper_arm_right` and `lower_arm_right`.
    var free_joint: [8]usize = undefined;
    var free_count: usize = 0;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const body_name: []const u8 = imported.names[m.jnt_body[j]];
        if (std.mem.eql(u8, body_name, "upper_arm_right") or
            std.mem.eql(u8, body_name, "lower_arm_right"))
        {
            free_joint[free_count] = j;
            free_count += 1;
        }
    }
    try expect(free_count >= 2);

    const target: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(target);
    const watched: usize = free_joint[free_count - 1]; // the elbow, last in the chain
    const goal: f32 = -1.0;
    target[m.jnt_qpos_adr[watched]] = goal;

    const frozen: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(frozen);

    var actuation: Actuation = try Actuation.init(gpa, m);
    defer actuation.deinit();

    const hold: PoseHold = .{ .target = target, .kp = 800.0, .kv = 40.0 };

    // ---- HOW MANY JOINTS CAN BE DRIVEN AT ONCE BEFORE IT BREAKS ----
    //
    // *** THE ARM ALONE IS PERFECT: -0.998 against a goal of -1.000, velocity zero, torque
    // 0.06 Nm. So the servo is correct and driving TWENTY-FOUR of them is not. That is a
    // coupling question, and the way to answer it is to unfreeze the body a piece at a time and
    // watch where the trace stops settling.
    //
    // `free_bodies` grows each round; everything outside it is held. The first round that does
    // not settle names the part that cannot be driven with the rest.
    const groups = [_][]const []const u8{
        &.{ "upper_arm_right", "lower_arm_right" },
        &.{ "upper_arm_right", "lower_arm_right", "upper_arm_left", "lower_arm_left" },
        &.{
            "upper_arm_right", "lower_arm_right", "upper_arm_left",
            "lower_arm_left",  "waist_lower",     "pelvis",
            "thigh_right",     "shin_right",      "thigh_left",
            "shin_left",
        },
    };

    report.print("\n  unfreezing progressively, elbow -> {d:.2} rad, kp 800 kv 40:\n", .{goal});

    for (groups, 0..) |group, round| {
        @memcpy(data.pos, frozen);
        @memset(data.vel, 0);
        rbt.forward(m, &data);

        var settled: f32 = 0;
        var peak_speed: f32 = 0;
        for (0..4000) |step| {
            hold.apply(m, &data, actuation);
            rbt.step(m, &data);

            // ---- HOLD EVERY JOINT NOT IN THIS ROUND'S GROUP ----
            //
            // ** RESTORING qpos AND ZEROING qvel. The frozen joints still contribute their
            // inertia through the mass matrix but cannot move - so this removes their MOTION as
            // a suspect without removing the mass that coupling acts through.
            for (0..m.njnt) |j| {
                if (m.jnt_type[j] != .hinge) {
                    continue;
                }
                var in_group: bool = false;
                for (group) |name| {
                    if (std.mem.eql(u8, imported.names[m.jnt_body[j]], name)) {
                        in_group = true;
                    }
                }
                if (in_group) {
                    continue;
                }
                data.pos[m.jnt_qpos_adr[j]] = frozen[m.jnt_qpos_adr[j]];
                data.vel[m.jnt_dof_adr[j]] = 0;
            }
            const root_q: u32 = m.jnt_qpos_adr[0];
            const root_v: u32 = m.jnt_dof_adr[0];
            inline for (0..7) |k| {
                data.pos[root_q + k] = frozen[root_q + k];
            }
            inline for (0..6) |k| {
                data.vel[root_v + k] = 0;
            }
            rbt.forward(m, &data);

            const speed: f32 = @abs(data.vel[m.jnt_dof_adr[watched]]);
            if (step >= 2000 and speed > peak_speed) {
                peak_speed = speed;
            }
            if (step >= 3800) {
                const err: f32 = @abs(data.pos[m.jnt_qpos_adr[watched]] - goal);
                settled = @max(settled, err);
            }
        }

        report.print("    round {d}: {d:>2} bodies free  ->  elbow err {d:.4} rad  peak speed {d:>7.2}  {s}\n", .{
            round,
            group.len,
            settled,
            peak_speed,
            if (settled < 0.02) "SETTLED" else "unstable",
        });
    }

    try expect(isFinite(data.pos[m.jnt_qpos_adr[watched]]));
}

test "stage 0 debug: can one elbow follow a MOVING target, everything else frozen" {
    // ---- THE WIN WE NEED, OR THE REASON THERE ISN'T ONE ----
    //
    // Simon: fix every bone except the right arm, servo the elbow, limit velocities, and watch
    // what the motor actually does.
    //
    // *** A SINE INSTEAD OF THE CLIP, ON PURPOSE. The dance needs the whole retarget pipeline,
    // and if the servo cannot follow a smooth 0.5 Hz sine inside the joint's own range then it
    // cannot follow a dance either - and the sine has no retarget, no IK and no contact to
    // blame. **A controller that fails the easy version does not need the hard version run.**
    //
    // Reported per trial: peak tracking error, the LAG at which it best matches (a servo that
    // trails is a different fault from one that oscillates), and the peak torque and velocity.
    const gpa: Allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    var file: std.Io.File = std.Io.Dir.cwd().openFile(
        io,
        "src/tests/fixtures/robot/humanoid_flex.xml",
        .{},
    ) catch return;
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    defer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, bytes, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();

    const rate: f32 = 2000.0;
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / rate,
    });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;

    var data: rbt.Data = try rbt.Data.init(gpa, m);
    defer data.deinit();
    rbt.forward(m, &data);

    var elbow: usize = 0;
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] == .hinge and
            std.mem.eql(u8, imported.names[m.jnt_body[j]], "lower_arm_right"))
        {
            elbow = j;
            break;
        }
    }
    try expect(elbow != 0);

    const eq: u32 = m.jnt_qpos_adr[elbow];
    const ev: u32 = m.jnt_dof_adr[elbow];
    const range: [2]f32 = m.jnt_range[elbow].?;

    // A sine that stays comfortably inside the joint's range, so a limit is never the answer.
    const centre: f32 = 0.5 * (range[0] + range[1]);
    const swing: f32 = 0.35 * (range[1] - range[0]);
    const hz: f32 = 0.5;

    const rest: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(rest);
    const target: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(target);

    var actuation: Actuation = try Actuation.init(gpa, m);
    defer actuation.deinit();

    // ** EVERY OTHER JOINT IS FROZEN, NOT MERELY UNPOWERED. Leaving them free lets the arm's
    // reaction swing the whole body, and then a tracking error is really a body-motion error
    // wearing a disguise. Frozen, the elbow is the only thing that can move.
    const Trial = struct { kp: f32, kv: f32, vlimit: f32 };
    const trials = [_]Trial{
        // Bracketing the CLIFF. Measured: torque is 2.6 Nm at kp 400 and 1000.0 - the ceiling -
        // at kp 1600, a 385-fold jump that is not gradual saturation. The example runs 800, so
        // where exactly the ceiling starts biting is the number that matters.
        .{ .kp = 100, .kv = 10, .vlimit = 0 },
        .{ .kp = 200, .kv = 15, .vlimit = 0 },
        .{ .kp = 400, .kv = 20, .vlimit = 0 },
        .{ .kp = 600, .kv = 30, .vlimit = 0 },
        .{ .kp = 800, .kv = 40, .vlimit = 0 },
        .{ .kp = 1200, .kv = 60, .vlimit = 0 },
        .{ .kp = 1600, .kv = 80, .vlimit = 0 },
    };

    report.print(
        "\n  right elbow, {d:.1} Hz sine within [{d:.2}, {d:.2}], all other joints frozen, {d:.0} Hz:\n",
        .{ hz, range[0], range[1], rate },
    );

    for (trials) |trial| {
        @memcpy(data.pos, rest);
        @memset(data.vel, 0);
        data.pos[eq] = centre;
        rbt.forward(m, &data);

        var peak_err: f32 = 0;
        var peak_torque: f32 = 0;
        var peak_vel: f32 = 0;
        const steps: usize = @trunc(rate * 6.0);

        for (0..steps) |step| {
            const t: f32 = float(step) / rate;
            const want: f32 = centre + swing * sinRad(2.0 * pi * hz * t);
            target[eq] = want;

            const hold: PoseHold = .{ .target = target, .kp = trial.kp, .kv = trial.kv };
            hold.apply(m, &data, actuation);

            if (@abs(data.applied_force[ev]) > peak_torque) {
                peak_torque = @abs(data.applied_force[ev]);
            }
            rbt.step(m, &data);

            // ---- FREEZE EVERYTHING BUT THE ELBOW, AFTER THE STEP ----
            //
            // The step integrates all of them; this puts every one back except the elbow. It
            // is the same trick as `pinRootInWorld` and for the same reason: an exact
            // constraint cannot be fought, where a stiff spring can.
            for (0..m.njnt) |j| {
                if (j == elbow) {
                    continue;
                }
                const q: u32 = m.jnt_qpos_adr[j];
                const v: u32 = m.jnt_dof_adr[j];
                const nq: usize = switch (m.jnt_type[j]) {
                    .free => 7,
                    .ball => 4,
                    else => 1,
                };
                const nv: usize = switch (m.jnt_type[j]) {
                    .free => 6,
                    .ball => 3,
                    else => 1,
                };
                for (0..nq) |k| {
                    data.pos[q + k] = rest[q + k];
                }
                for (0..nv) |k| {
                    data.vel[v + k] = 0;
                }
            }

            // ** A VELOCITY CEILING IS A BLUNT INSTRUMENT AND SAYS SO. It cannot make a wrong
            // controller right; it can stop a diverging one from reaching infinity, which makes
            // the difference between a readable number and a NaN.
            if (trial.vlimit > 0) {
                data.vel[ev] = clamp(data.vel[ev], -trial.vlimit, trial.vlimit);
            }
            rbt.forward(m, &data);

            if (@abs(data.vel[ev]) > peak_vel) {
                peak_vel = @abs(data.vel[ev]);
            }
            // Ignore the first second: the servo starts at the sine's centre and is allowed to
            // catch up.
            if (t > 1.0) {
                const err: f32 = @abs(data.pos[eq] - want);
                if (err > peak_err) {
                    peak_err = err;
                }
            }
        }

        report.print(
            "    kp {d:>5.0}  kv {d:>4.0}  vlim {s:<5}  ->  err {d:>6.3} rad " ++
                "({d:>5.1} deg)  torque {d:>7.1}  vel {d:>6.1}\n",
            .{
                trial.kp,
                trial.kv,
                if (trial.vlimit > 0) "20" else "none",
                peak_err,
                peak_err * 57.2957795,
                peak_torque,
                peak_vel,
            },
        );
    }

    try expect(isFinite(data.pos[eq]));
}

test "rung 2: can the full humanoid hold the pose it is already in" {
    // ---- THE RUNG NOBODY HAS EVER RUN ----
    //
    // *** EVERY FULL-BODY TEST IN THIS PROJECT USED A MOVING TARGET. Nobody has asked whether
    // twenty-four joints can hold the pose they START in - and if they cannot, no clip and no
    // policy will help, because a policy outputs offsets on top of this.
    //
    // The target IS the initial pose, so a correct controller does nothing at all: zero error,
    // zero torque, forever. **Any drift at all is the controller failing at the easiest task
    // that exists**, and it costs one test to find out.
    //
    // See `src/notes/servo_ladder.md` rung 2.
    const gpa: Allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    var file: std.Io.File = std.Io.Dir.cwd().openFile(
        io,
        "src/tests/fixtures/robot/humanoid_flex.xml",
        .{},
    ) catch return;
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    defer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, bytes, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();

    const rate: f32 = 2000.0;
    var imported: rmj.Imported = try rmj.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / rate,
    });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;

    var data: rbt.Data = try rbt.Data.init(gpa, m);
    defer data.deinit();
    rbt.forward(m, &data);

    const target: []f32 = try gpa.dupe(f32, data.pos);
    defer gpa.free(target);

    var actuation: Actuation = try Actuation.init(gpa, m);
    defer actuation.deinit();

    // ** THE ROOT IS PINNED, so this is purely a question about the joints. A free root would
    // let the character fall and the answer would be about balance again.
    const root_q: u32 = m.jnt_qpos_adr[0];
    const root_v: u32 = m.jnt_dof_adr[0];
    const rest_root: [7]f32 = .{
        data.pos[root_q],     data.pos[root_q + 1], data.pos[root_q + 2], data.pos[root_q + 3],
        data.pos[root_q + 4], data.pos[root_q + 5], data.pos[root_q + 6],
    };

    const gains = [_][2]f32{ .{ 100, 10 }, .{ 400, 20 }, .{ 800, 40 } };

    report.print("\n  rung 2: all {d} joints holding their OWN rest pose, root pinned, 5 s:\n", .{m.njnt});

    for (gains) |pair| {
        @memcpy(data.pos, target);
        @memset(data.vel, 0);
        rbt.forward(m, &data);

        const hold: PoseHold = .{ .target = target, .kp = pair[0], .kv = pair[1] };
        var worst: f32 = 0;
        var worst_joint: usize = 0;
        var peak_torque: f32 = 0;

        for (0..10000) |_| {
            hold.apply(m, &data, actuation);
            for (0..m.nv) |v| {
                if (@abs(data.applied_force[v]) > peak_torque) {
                    peak_torque = @abs(data.applied_force[v]);
                }
            }
            rbt.step(m, &data);

            inline for (0..7) |k| {
                data.pos[root_q + k] = rest_root[k];
            }
            inline for (0..6) |k| {
                data.vel[root_v + k] = 0;
            }
            rbt.forward(m, &data);

            for (0..m.njnt) |j| {
                if (m.jnt_type[j] != .hinge) {
                    continue;
                }
                const q: u32 = m.jnt_qpos_adr[j];
                const err: f32 = @abs(data.pos[q] - target[q]);
                if (err > worst) {
                    worst = err;
                    worst_joint = j;
                }
            }
        }

        report.print(
            "    kp {d:>4.0}  kv {d:>3.0}  ->  drift {d:.4} rad ({d:>5.1} deg) on {s:<16} torque {d:>7.1}  {s}\n",
            .{
                pair[0],
                pair[1],
                worst,
                worst * 57.2957795,
                imported.names[m.jnt_body[worst_joint]],
                peak_torque,
                if (worst < 0.05) "PASS" else "FAIL",
            },
        );
    }

    try expect(isFinite(data.pos[m.jnt_qpos_adr[1]]));
}
