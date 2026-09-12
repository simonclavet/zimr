//! lint:alias zimrphysics
//! physics.zig — a single-file, single-threaded rigid-body engine.
//!
//! v2: the contact solver, friction model, restitution bias, and integration are
//! now reconciled to match Jolt's algorithms term for term (see the parity notes
//! at each site). This is a BRAINSTORM to feel out the architecture, not
//! compile-checked code.
//!
//! ----------------------------------------------------------------------------
//! WHAT "BEHAVES IDENTICALLY TO JOLT" MEANS HERE
//! ----------------------------------------------------------------------------
//! We match Jolt *algorithmically*: same constraint model (sequential impulse with
//! soft/speculative contacts), same per-step formulas, same constants, same
//! integration. A scene behaves the same — a stack settles the same way, a ball
//! bounces to the same height, a box slides the same distance.
//!
//! Our solve is also *deterministic*: a fixed-iteration sequential-impulse solver is
//! order dependent, so we give contacts a total order (sorted by body index in
//! findPairs) before solving. This is exactly how Jolt makes ITS result independent
//! of multithreaded contact discovery — Jolt sorts by a body-pair hash key. Same
//! lever, different key.
//!
//! We do NOT reproduce a *specific* Jolt build's exact floating-point trajectory.
//! That would require adopting Jolt's hash-based sort key (an arbitrary order that is
//! no more physically correct than ours) AND Jolt's exact body-ID allocation AND the
//! same FP operation order. The sort key here is deliberately one swappable function
//! (BroadPhase.pairLess) — point it at Jolt's hash and align body IDs and the orders
//! converge, but that buys cross-validation, not better physics. The intended
//! differences from Jolt are exactly: (1) single threaded, (2) more opinionated
//! (fewer toggles; we bake in the defaults Jolt ships with). Everything else is the
//! same physics, and is meant to be verified by conservation/analytic tests (a ball
//! returns to restitution^2 * h; a box on a slope slides iff mu < tan theta; a stack
//! is stable) plus the term-by-term source audit noted throughout.
//!
//! ----------------------------------------------------------------------------
//! DESIGN RULES
//! ----------------------------------------------------------------------------
//!   * Everything in view. try step() is a flat sequence of phases on flat arrays.
//!   * The ECS (Entities(Body)) is where data RESTS between steps; during a step we
//!     work on plain slices indexed by a stable body index.
//!   * Functions take what they need by argument. No globals; tunables live in a
//!     Settings value on the World.
//!   * A function called from one place is inlined there. The pipeline phases live
//!     inside try step() as labelled blocks; the many-times-called kernels (support
//!     mapping, narrow phase, the constraint atoms) are real functions.
//!   * Verbose but clean: short lines, explicitly-typed intermediates, arithmetic
//!     spelled out.
//!
//! Storage at rest:
//!   bodies            : Entities(Body)   // primary Body for EVERY body (the pool)
//!   motion            : []Motion         // flat side-table by body index; static = zeroed
//!   inv_inertia_world : []Mat3           // baked once per step for active bodies
//!   shapes            : ShapeStore       // shared, immutable, referenced by index
//!   active            : []u32            // body indices that are awake and move

const std = @import("std");
const zm = @import("zm");
const turnsFromRad = zm.turnsFromRad;
const radFromTurns = zm.radFromTurns;
const profiler = @import("profiler.zig");
const entities = @import("entities.zig");
const physics_common = @import("physics_common.zig");

// zm bindings (no-qualified-zm: bind once, use bare in bodies).
const Quat = zm.Quat;
const quat = zm.quat;
const Vec = zm.Vec;
const abs = zm.abs;
const acosRad = zm.acosRad;
const asinRad = zm.asinRad;
const atan2Rad = zm.atan2Rad;
const clamp = zm.clamp;
const conjugate = zm.conjugate;
const cross = zm.cross;
const dot3 = zm.dot3;
const dot4 = zm.dot4;
const float = zm.float;
const floatMax = zm.floatMax;
const floori = zm.floori;
const length3 = zm.length3;
const lengthSq3 = zm.lengthSq3;
const maxInt = zm.maxInt;
const normalize3 = zm.normalize3;
const normalize4 = zm.normalize4;
const pi = zm.pi;
const qmul = zm.qmul;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const quatFromEulerXYZ = zm.quatFromEulerXYZ;
const quat_identity = zm.quat_identity;
const radFromDeg = zm.radFromDeg;
const rotate = zm.rotate;
const safeNormalize3 = zm.safeNormalize3;
const splat = zm.splat;
const tanRad = zm.tanRad;
const vec = zm.vec;
const vec_zero = zm.vec_zero;

/// Runtime-indexed lane of a Vec (Zig forbids a runtime index on a @Vector).
inline fn vlane(v: anytype, i: usize) f32 {
    const info = @typeInfo(@TypeOf(v));
    if (info == .vector) {
        return @as([info.vector.len]f32, v)[i];
    }
    return v[i];
}

pub const Aabb = zm.Aabb;

pub const ShapeId = u32;

pub const MotionType = physics_common.MotionType;

/// Discrete bodies integrate straight through (relying on speculative contacts for
/// moderate speeds); LinearCast bodies are swept each step so a fast one cannot
/// tunnel through thin geometry. Jolt's EMotionQuality.
pub const MotionQuality = physics_common.MotionQuality;

pub const Body = struct {
    com_pos: Vec, // centre-of-mass world position (canonical)
    rot: Quat,
    bounds: Aabb, // world AABB

    shape: ShapeId,
    friction: f32,
    restitution: f32,
    motion_type: MotionType,
    motion_quality: MotionQuality,
    is_sensor: bool,
    /// Report this body's contacts to the listener even when NEITHER body can respond.
    ///
    /// The narrow phase normally drops static/static, static/kinematic and
    /// kinematic/kinematic pairs, because no impulse this solver could compute would go
    /// anywhere. That reasoning is about THIS solver. A body whose motion is decided
    /// elsewhere — driven by an external integrator, an animation, another simulation —
    /// still needs to know what it is touching, and the impulse is that owner's business.
    ///
    /// Distinct from `is_sensor`, which also bypasses the gate but additionally suppresses
    /// the collision response against dynamic bodies. This flag changes only what is
    /// REPORTED; a kinematic body with it set still pushes crates exactly as before.
    report_immovable_contacts: bool,
    // Collision filtering. `category` is this body's bits; `mask` is which categories it hits
    // of categories it will touch. Two bodies sharing a nonzero `group_id` never
    // collide (ragdoll bones, parts of one assembly). See bodiesShouldCollide.
    category: u32,
    mask: u32,
    group_id: u32,
    asleep: bool, // deactivated by the sleep system; excluded from the active set
    in_broadphase: bool,
    broadphase_node: u32,

    user_data: u64,
    material: u16, // opaque surface id (footstep sounds, friction lookups, etc.); see World.materialAt
};

const Bodies = entities.Entities(Body);
pub const BodyHandle = entities.Handle(Body);

/// Pack a raw body index into its generation-checked handle. For the few internal builders that
/// work in raw indices but call the public, handle-taking joint constructors.
fn handleOf(world: *const World, idx: BodyIndex) BodyHandle {
    return BodyHandle.pack(@intCast(idx), world.bodies.cycle[idx]);
}

/// A body index == handle.index(). Dense, <= capacity, stable for the body's life.
pub const BodyIndex = u32;

// =============================================================================
// Tunables. A value, not globals. Every default is Jolt's PhysicsSettings default.
// =============================================================================

pub const Settings = struct {
    velocity_steps: u32 = 10, // mNumVelocitySteps
    position_steps: u32 = 2, // mNumPositionSteps

    baumgarte: f32 = 0.2, // mBaumgarte
    penetration_slop: f32 = 0.02, // mPenetrationSlop
    speculative_distance: f32 = 0.02, // mSpeculativeContactDistance
    max_penetration_distance: f32 = 0.2, // mMaxPenetrationDistance (position-solve clamp)
    min_velocity_for_restitution: f32 = 1.0, // mMinVelocityForRestitution

    linear_cast_threshold: f32 = 0.75, // mLinearCastThreshold: CCD when a linear-cast
    //   body moves more than this fraction of its inner radius in one step

    time_before_sleep: f32 = 0.5, // mTimeBeforeSleep
    point_velocity_sleep_threshold: f32 = 0.03, // mPointVelocitySleepThreshold

    allow_sleeping: bool = true, // mAllowSleeping
};

// =============================================================================
// Small math types zm doesn't ship.
// =============================================================================

/// 3x3 matrix as three columns. Used for the world-space inverse inertia tensor
/// (symmetric, so column vs row is irrelevant).
pub const Mat3 = zm.Mat3;

/// Tiny 2x2 matrix for the two-DOF joint parts (hinge rotation lock, slider
/// translation lock). Stored row-major as [[m00, m01], [m10, m11]].
pub const Mat2 = zm.Mat2;

// -----------------------------------------------------------------------------
// Physics math surface — everything this port adds on top of zm, all gathered at
// the top of the file (here and the relocated-helpers section just below the
// inertia helpers) so the eventual lift into zimrmath is a contiguous cut. See
// PLAN_MATH_UNIFICATION.md. Inventory:
//
//   Types:    Mat3 (col:[3]Vec)            — above; world inverse inertia, K matrices
//             Mat2 (scalar m00..m11)       — above; 2-DOF joint blocks (→ [2]Vec2 in zm)
//   Inertia:  applyInvInertia, bakeInvInertiaWorld, mat3Outer
//   Rotation: integrateRotation (quat exp), clampMagnitude, applyGyroscopic
//   Quats:    quatAngleAbout, quatNormalize (guarded normalize4),
//             quatGetAngularVelocity, quatGetSwingTwist (+SwingTwistPair),
//             quatFromBasis (Shepperd; canonical basis→quat, used over matToQuat)
//   Scalars:  signNonZero, signSelect
//   Vectors:  normalizedPerpendicular (Jolt-faithful; the sole perpendicular helper)
//   Geometry: Aabb (+ overlaps/expandedBy/combine), transformAabb,
//             transformAabbInverse, aabbContainsPoint
//   Decomp:   jacobiEigenSymmetric3 + jacobiRotate + mat3ColsToQuat + EigenResult
//   Solve:    gaussJordanSolve (generalize to comptime-N for zm)
//   Domain (NOT general math, stay in physics): SoftConstraint/softConstraint*,
//             CurvePoint/LinearCurve.
//
// Unified onto zm where zm already had the primitive: quaternion 4-dot →
// dot4, normalize-or-fallback → safeNormalize3. (Removed the local quatDot,
// normalizeOr, and the redundant second perpendicular helper.)
//
// Still grouped with the collision code (geometry, but coupled to the ray-test
// family / RayShapeHit, so left there for now): rayVsAabb/Sphere/Box/Capsule,
// boxFace, and the GJK/EPA cores. These are the next candidate batch.
// -----------------------------------------------------------------------------

/// Outer product a·bᵀ as a column-major 3x3 (used to assemble inertia tensors).
fn mat3Outer(a: Vec, b: Vec) Mat3 {
    return .{ .col = .{ a * splat(b[0]), a * splat(b[1]), a * splat(b[2]) } };
}

/// Jolt's Sign: −1 for negative, +1 for zero or positive (so it never returns 0, which matters
/// for the slip-ratio denominator).
fn signNonZero(x: f32) f32 {
    return if (x < 0.0) -1.0 else 1.0;
}

/// Fixed-capacity DFS stack of node indices, shared by every BVH traversal (broad-phase tree and
/// mesh BVH alike). It owns only the stack/push/pop bookkeeping; each walk keeps its own prune test
/// and leaf work inline, since those differ per traversal. `push` is a no-op when full — the depth
/// (256) is far beyond any balanced tree these builders produce, so this never triggers in practice.
const BvhStack = struct {
    items: [256]u32 = undefined,
    sp: usize = 0,

    fn push(self: *BvhStack, idx: u32) void {
        if (self.sp < self.items.len) {
            self.items[self.sp] = idx;
            self.sp += 1;
        }
    }

    fn pop(self: *BvhStack) ?u32 {
        if (self.sp == 0) {
            return null;
        }
        self.sp -= 1;
        return self.items[self.sp];
    }
};

// =============================================================================
// Reused math kernels.
// =============================================================================

/// Per-component reciprocal of the x/y/z lanes (w left at 0). Mainly used to flip a
/// diagonal inertia tensor to its inverse and back, without spelling out three `1/x` terms.
/// Lanes must be non-zero (callers only invert dynamic, positive-inertia diagonals).
fn reciprocal3(v: Vec) Vec {
    return vec(1.0 / v[0], 1.0 / v[1], 1.0 / v[2]);
}

/// Component-wise pick of +s/-s by the sign of dir: the support of an axis box.
fn signSelect(dir: Vec, s: Vec) Vec {
    const use_pos: @Vector(4, bool) = dir >= vec_zero;
    return @select(f32, use_pos, s, -s);
}

/// Jolt's Vec3::GetNormalizedPerpendicular, ported verbatim so our friction tangent
/// basis matches Jolt's exactly (keeps warm-started friction impulses lined up).
fn normalizedPerpendicular(n: Vec) Vec {
    if (n[0] * n[0] > n[1] * n[1]) {
        const len: f32 = @sqrt(n[0] * n[0] + n[2] * n[2]);
        return vec(n[2], 0.0, -n[0]) / splat(len);
    } else {
        const len: f32 = @sqrt(n[1] * n[1] + n[2] * n[2]);
        return vec(0.0, n[2], -n[1]) / splat(len);
    }
}

/// Apply a body's inverse inertia (principal diagonal D + rotation R) to a world
/// vector without forming a matrix: I_world^-1 v = R_q (D .* (R_q^-1 v)).
fn applyInvInertia(
    body_rot: Quat,
    inv_diag: Vec,
    inertia_rot: Quat,
    v: Vec,
) Vec {
    // World inertia-frame rotation R = body_rot * inertia_rot (Jolt's
    // GetInverseInertiaForRotation: inRotation.Multiply3x3(sRotation(mInertiaRotation))).
    // Hamilton qmul applies inertia_rot first, then body_rot.
    const q: Quat = qmul(body_rot, inertia_rot);
    const local_v: Vec = rotate(conjugate(q), v);
    const scaled: Vec = inv_diag * local_v;
    return rotate(q, scaled);
}

/// Bake the world-space inverse inertia 3x3 once per step so the solver iterations
/// are a cheap mat3*vec. (Jolt recomputes lazily via GetInverseInertia; same result.)
fn bakeInvInertiaWorld(body_rot: Quat, inv_diag: Vec, inertia_rot: Quat) Mat3 {
    const ex: Vec = applyInvInertia(body_rot, inv_diag, inertia_rot, vec(1, 0, 0));
    const ey: Vec = applyInvInertia(body_rot, inv_diag, inertia_rot, vec(0, 1, 0));
    const ez: Vec = applyInvInertia(body_rot, inv_diag, inertia_rot, vec(0, 0, 1));
    return .{ .col = .{ ex, ey, ez } };
}

/// Advance orientation by an angular displacement (w*dt) via the quaternion
/// exponential. Matches Jolt's Body::AddRotationStep.
fn integrateRotation(rot: *Quat, angular_displacement: Vec) void {
    const angle: f32 = length3(angular_displacement);
    if (angle > 1.0e-6) {
        const axis: Vec = angular_displacement / splat(angle);
        const dq: Quat = quatFromAxisAngle(axis, angle);
        // The angular displacement is a WORLD-space vector, so the delta rotation must
        // be applied *after* the current orientation: Jolt's `mRotation = dq * mRotation`.
        // qmul is now Hamilton order (qmul(a, b) applies b first), so this is a literal
        // translation of Jolt's expression.
        rot.* = normalize4(qmul(dq, rot.*));
    }
}

/// Clamp a velocity vector to a maximum magnitude (Jolt's ClampLinear/AngularVelocity).
fn clampMagnitude(v: Vec, max: f32) Vec {
    const len_sq: f32 = lengthSq3(v);
    if (len_sq > max * max) {
        return v * splat(max / @sqrt(len_sq));
    }
    return v;
}

/// Gyroscopic (Dzhanibekov) angular-velocity update, ported from Jolt's
/// MotionProperties::ApplyGyroscopicForceInternal. Solving the rotation implicitly in
/// the body's inertia frame keeps a freely-spinning body stable and reproduces the
/// tennis-racket effect. Only used when a body opts in (most don't need it).
fn applyGyroscopic(
    ang_vel: Vec,
    body_rot: Quat,
    inv_diag: Vec,
    inertia_rot: Quat,
    dt: f32,
) Vec {
    // Local inertia = 1 / inverse-inertia, using 1 in any axis whose inverse is 0
    // (a locked axis) so the divide is safe; that axis then contributes nothing.
    const axis_is_locked: @Vector(4, bool) = inv_diag == vec_zero;
    const safe_divisor: Vec = @select(f32, axis_is_locked, splat(1.0), inv_diag);
    const numerator: Vec = @select(f32, axis_is_locked, vec_zero, splat(1.0));
    const local_inertia: Vec = numerator / safe_divisor;

    // Rotate angular velocity into the inertia frame, evolve the angular momentum one
    // step, then rotate back. Renormalising preserves the momentum's magnitude.
    const inertia_to_world: Quat = qmul(body_rot, inertia_rot);
    const local_angular_velocity: Vec = rotate(conjugate(inertia_to_world), ang_vel);
    const local_momentum: Vec = local_inertia * local_angular_velocity;
    const momentum_change: Vec = cross(local_angular_velocity, local_momentum);
    const evolved_momentum: Vec = local_momentum - splat(dt) * momentum_change;

    const evolved_length_sq: f32 = lengthSq3(evolved_momentum);
    const original_length_sq: f32 = lengthSq3(local_momentum);
    const renormalised_momentum: Vec = if (evolved_length_sq > 0.0)
        evolved_momentum * splat(@sqrt(original_length_sq / evolved_length_sq))
    else
        vec_zero;

    return rotate(inertia_to_world, inv_diag * renormalised_momentum);
}

// -----------------------------------------------------------------------------
// Relocated general math & geometry (continued) — moved up here so the whole
// math surface is contiguous and easy to lift into zimrmath. Pure: no Shape/
// Body/World/constraint coupling. See PLAN_MATH_UNIFICATION.md.
//   - Symmetric-3x3 eigensolver (EigenResult, jacobiRotate,
//     jacobiEigenSymmetric3, mat3ColsToQuat)
//   - Quaternion helpers (quatAngleAbout, quatNormalize,
//     quatGetAngularVelocity, SwingTwistPair, quatGetSwingTwist, quatFromBasis)
//   - AABB geometry (transformAabb, transformAabbInverse, aabbContainsPoint)
//   - Dense linear solve (gaussJordanSolve; generalize to comptime-N for zm)
// -----------------------------------------------------------------------------

const EigenResult = struct { values: Vec, rotation: Quat };

/// One Jacobi rotation that zeroes the symmetric off-diagonal entry (p,q), updating
/// the matrix `a` (kept symmetric) and accumulating the rotation into `v` (V := V*J).
fn jacobiRotate(
    a: *[3][3]f32,
    v: *[3][3]f32,
    p: usize,
    q: usize,
) void {
    if (@abs(a[p][q]) < 1.0e-15) {
        return;
    }
    const app: f32 = a[p][p];
    const aqq: f32 = a[q][q];
    const apq: f32 = a[p][q];
    const tau_j: f32 = (aqq - app) / (2.0 * apq);
    const t: f32 = if (tau_j >= 0.0)
        1.0 / (tau_j + @sqrt(1.0 + tau_j * tau_j))
    else
        -1.0 / (-tau_j + @sqrt(1.0 + tau_j * tau_j));
    const c: f32 = 1.0 / @sqrt(1.0 + t * t);
    const s: f32 = t * c;
    const r: usize = 3 - p - q; // the third index

    a[p][p] = c * c * app - 2.0 * s * c * apq + s * s * aqq;
    a[q][q] = s * s * app + 2.0 * s * c * apq + c * c * aqq;
    a[p][q] = 0.0;
    a[q][p] = 0.0;

    const arp: f32 = a[r][p];
    const arq: f32 = a[r][q];
    a[r][p] = c * arp - s * arq;
    a[p][r] = a[r][p];
    a[r][q] = s * arp + c * arq;
    a[q][r] = a[r][q];

    var row: usize = 0;
    while (row < 3) : (row += 1) {
        const vrp: f32 = v[row][p];
        const vrq: f32 = v[row][q];
        v[row][p] = c * vrp - s * vrq;
        v[row][q] = s * vrp + c * vrq;
    }
}

/// Rotation matrix (columns are basis vectors, v[row][col]) to a unit quaternion.
fn mat3ColsToQuat(v: [3][3]f32) Quat {
    const m00: f32 = v[0][0];
    const m11: f32 = v[1][1];
    const m22: f32 = v[2][2];
    const trace: f32 = m00 + m11 + m22;
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    var z: f32 = 0.0;
    var w: f32 = 1.0;
    if (trace > 0.0) {
        const s: f32 = @sqrt(trace + 1.0) * 2.0;
        w = 0.25 * s;
        x = (v[2][1] - v[1][2]) / s;
        y = (v[0][2] - v[2][0]) / s;
        z = (v[1][0] - v[0][1]) / s;
    } else if (m00 > m11 and m00 > m22) {
        const s: f32 = @sqrt(1.0 + m00 - m11 - m22) * 2.0;
        w = (v[2][1] - v[1][2]) / s;
        x = 0.25 * s;
        y = (v[0][1] + v[1][0]) / s;
        z = (v[0][2] + v[2][0]) / s;
    } else if (m11 > m22) {
        const s: f32 = @sqrt(1.0 + m11 - m00 - m22) * 2.0;
        w = (v[0][2] - v[2][0]) / s;
        x = (v[0][1] + v[1][0]) / s;
        y = 0.25 * s;
        z = (v[1][2] + v[2][1]) / s;
    } else {
        const s: f32 = @sqrt(1.0 + m22 - m00 - m11) * 2.0;
        w = (v[1][0] - v[0][1]) / s;
        x = (v[0][2] + v[2][0]) / s;
        y = (v[1][2] + v[2][1]) / s;
        z = 0.25 * s;
    }
    const inv_len: f32 = 1.0 / @sqrt(x * x + y * y + z * z + w * w);
    return .{ x * inv_len, y * inv_len, z * inv_len, w * inv_len };
}

/// Eigen-decomposition of a symmetric 3x3 matrix by cyclic Jacobi sweeps. Returns the
/// eigenvalues and a proper rotation whose columns are the matching eigenvectors.
fn jacobiEigenSymmetric3(m_in: Mat3) EigenResult {
    var a: [3][3]f32 = .{
        .{ m_in.col[0][0], m_in.col[1][0], m_in.col[2][0] },
        .{ m_in.col[0][1], m_in.col[1][1], m_in.col[2][1] },
        .{ m_in.col[0][2], m_in.col[1][2], m_in.col[2][2] },
    };
    var v: [3][3]f32 = .{ .{ 1.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 }, .{ 0.0, 0.0, 1.0 } };

    var sweep: u32 = 0;
    while (sweep < 32) : (sweep += 1) {
        if (@abs(a[0][1]) + @abs(a[0][2]) + @abs(a[1][2]) < 1.0e-12) {
            break;
        }
        jacobiRotate(&a, &v, 0, 1);
        jacobiRotate(&a, &v, 0, 2);
        jacobiRotate(&a, &v, 1, 2);
    }

    // Make V a proper rotation (det +1) so it maps cleanly to a quaternion.
    const det: f32 = v[0][0] * (v[1][1] * v[2][2] - v[1][2] * v[2][1]) -
        v[0][1] * (v[1][0] * v[2][2] - v[1][2] * v[2][0]) +
        v[0][2] * (v[1][0] * v[2][1] - v[1][1] * v[2][0]);
    if (det < 0.0) {
        v[0][0] = -v[0][0];
        v[1][0] = -v[1][0];
        v[2][0] = -v[2][0];
    }
    return .{ .values = vec(a[0][0], a[1][1], a[2][2]), .rotation = mat3ColsToQuat(v) };
}

/// Signed rotation angle of a quaternion about a (unit) axis. Exact when the
/// quaternion's own rotation axis is parallel to `axis` - true for a hinge, whose
/// relative rotation is locked to the hinge axis: theta = 2*atan2(q.xyz . axis, q.w).
fn quatAngleAbout(q: Quat, axis: Vec) f32 {
    const xyz: Vec = vec(q[0], q[1], q[2]);
    return 2.0 * atan2Rad(dot3(xyz, axis), q[3]);
}
/// Normalize a quaternion; returns identity for a zero quaternion.
fn quatNormalize(q: Quat) Quat {
    const len_sq: f32 = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    if (len_sq > 0.0) {
        return q * splat(1.0 / @sqrt(len_sq));
    }
    return quat_identity;
}

/// Angular velocity (rad/s) that, integrated over `dt`, produces the rotation `q`. `q` is
/// assumed normalized; the sign is taken so the angle lands in [0, pi]. Jolt's
/// Quat::GetAngularVelocity (small-angle branch uses sin(x) ~= x).
fn quatGetAngularVelocity(q: Quat, dt: f32) Vec {
    var w_pos: Quat = q;
    if (w_pos[3] < 0.0) {
        w_pos = -w_pos;
    } // ensure w >= 0
    const xyz: Vec = vec(w_pos[0], w_pos[1], w_pos[2]);
    const xyz_len_sq: f32 = w_pos[0] * w_pos[0] + w_pos[1] * w_pos[1] + w_pos[2] * w_pos[2];
    if (xyz_len_sq < 4.0e-4) {
        return xyz * splat(2.0 / dt);
    }
    const angle: f32 = 2.0 * acosRad(clamp(w_pos[3], -1.0, 1.0));
    return xyz * splat(angle / (@sqrt(xyz_len_sq) * dt));
}

const SwingTwistPair = struct { swing: Quat, twist: Quat };

/// Build a Quat from explicit (x, y, z, w) components (result-typed vector literal).
/// Decompose q = q_swing * q_twist where the twist is around the X axis (q_twist.y =
/// q_twist.z = 0) and the swing has q_swing.x = 0. Jolt's Quat::GetSwingTwist.
fn quatGetSwingTwist(q: Quat) SwingTwistPair {
    const x: f32 = q[0];
    const y: f32 = q[1];
    const z: f32 = q[2];
    const w: f32 = q[3];
    const s: f32 = @sqrt(w * w + x * x);
    if (s != 0.0) {
        return .{
            .swing = quat(0.0, (w * y - x * z) / s, (w * z + x * y) / s, s),
            .twist = quat(x / s, 0.0, 0.0, w / s),
        };
    }
    // x and w both zero: a 180 degree rotation around an axis in the YZ plane.
    return .{ .swing = q, .twist = quat_identity };
}

/// Twist component of `q` about an arbitrary `axis` (Jolt's Quat::GetTwist): project the
/// imaginary part onto the axis, keep the scalar part, and renormalize. Identity if degenerate.
fn quatGetTwist(q: Quat, axis: Vec) Quat {
    const xyz: Vec = vec(q[0], q[1], q[2]);
    const d: f32 = dot3(xyz, axis);
    const proj: Vec = axis * splat(d);
    const twist: Quat = .{ proj[0], proj[1], proj[2], q[3] };
    const len2: f32 = twist[0] * twist[0] + twist[1] * twist[1] + twist[2] * twist[2] + twist[3] * twist[3];
    if (len2 != 0.0) {
        return twist / splat(@sqrt(len2));
    }
    return quat_identity;
}

/// Quaternion whose rotation maps the standard axes onto the orthonormal columns
/// (bx, by, bz): rotate(result, X) == bx, etc. Shepperd's method; avoids the
/// row/column-major ambiguity of going through matToQuat.
fn quatFromBasis(bx: Vec, by: Vec, bz: Vec) Quat {
    const m00: f32 = bx[0];
    const m10: f32 = bx[1];
    const m20: f32 = bx[2];
    const m01: f32 = by[0];
    const m11: f32 = by[1];
    const m21: f32 = by[2];
    const m02: f32 = bz[0];
    const m12: f32 = bz[1];
    const m22: f32 = bz[2];
    const trace: f32 = m00 + m11 + m22;
    if (trace > 0.0) {
        const s: f32 = @sqrt(trace + 1.0) * 2.0; // s = 4*w
        return quat((m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s);
    } else if (m00 > m11 and m00 > m22) {
        const s: f32 = @sqrt(1.0 + m00 - m11 - m22) * 2.0; // s = 4*x
        return quat(0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s);
    } else if (m11 > m22) {
        const s: f32 = @sqrt(1.0 + m11 - m00 - m22) * 2.0; // s = 4*y
        return quat((m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s);
    } else {
        const s: f32 = @sqrt(1.0 + m22 - m00 - m11) * 2.0; // s = 4*z
        return quat((m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s);
    }
}
/// Transform a local AABB by a rotation+translation (abs-rotated-extents trick).
fn transformAabb(local: Aabb, translation: Vec, rotation: Quat) Aabb {
    const center_local: Vec = (local.min + local.max) * splat(0.5);
    const extent_local: Vec = (local.max - local.min) * splat(0.5);
    const center_world: Vec = translation + rotate(rotation, center_local);

    const rx: Vec = rotate(rotation, vec(extent_local[0], 0, 0));
    const ry: Vec = rotate(rotation, vec(0, extent_local[1], 0));
    const rz: Vec = rotate(rotation, vec(0, 0, extent_local[2]));
    const extent_world: Vec = abs(rx) + abs(ry) + abs(rz);

    return .{ .min = center_world - extent_world, .max = center_world + extent_world };
}

/// Map a WORLD-space AABB into the local frame posed at (translation, rotation): the
/// inverse of transformAabb. Used to query a mesh's local BVH with a colliding shape's
/// world bounds.
fn transformAabbInverse(world: Aabb, translation: Vec, rotation: Quat) Aabb {
    const shifted: Aabb = .{ .min = world.min - translation, .max = world.max - translation };
    return transformAabb(shifted, vec_zero, conjugate(rotation));
}
fn aabbContainsPoint(box: Aabb, p: Vec) bool {
    return p[0] >= box.min[0] and p[0] <= box.max[0] and
        p[1] >= box.min[1] and p[1] <= box.max[1] and
        p[2] >= box.min[2] and p[2] <= box.max[2];
}
/// Max dimension of the clutch coupling matrix: engine + up to this many − 1 driven wheels.
const clutch_max_n: usize = 16;

/// Solve a*x = b (b a column vector) in place by Gauss-Jordan elimination with full pivoting,
/// writing the solution into b. Faithful to Jolt's GaussianElimination (specialised to one
/// right-hand side). Returns false if the matrix is singular. `n` is the active dimension.
fn gaussJordanSolve(
    a: *[clutch_max_n][clutch_max_n]f32,
    b: *[clutch_max_n]f32,
    n: usize,
) bool {
    var ipiv: [clutch_max_n]i32 = @splat(0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var pivot_row: usize = i;
        var pivot_col: usize = i;
        var largest_element: f32 = 0.0;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (ipiv[j] != 1) {
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    if (ipiv[k] == 0) {
                        const element: f32 = @abs(a[j][k]);
                        if (element >= largest_element) {
                            largest_element = element;
                            pivot_row = j;
                            pivot_col = k;
                        }
                    } else if (ipiv[k] > 1) {
                        return false;
                    }
                }
            }
        }
        ipiv[pivot_col] += 1;
        if (pivot_row != pivot_col) {
            var c: usize = 0;
            while (c < n) : (c += 1) {
                const tmp: f32 = a[pivot_row][c];
                a[pivot_row][c] = a[pivot_col][c];
                a[pivot_col][c] = tmp;
            }
            const tmp_b: f32 = b[pivot_row];
            b[pivot_row] = b[pivot_col];
            b[pivot_col] = tmp_b;
        }
        const diagonal_element: f32 = a[pivot_col][pivot_col];
        if (@abs(diagonal_element) < 1.0e-16) {
            return false;
        }
        var dc: usize = 0;
        while (dc < n) : (dc += 1) a[pivot_col][dc] /= diagonal_element;
        b[pivot_col] /= diagonal_element;
        a[pivot_col][pivot_col] = 1.0;
        var r: usize = 0;
        while (r < n) : (r += 1) {
            if (r != pivot_col) {
                const element: f32 = a[r][pivot_col];
                var kc: usize = 0;
                while (kc < n) : (kc += 1) a[r][kc] -= a[pivot_col][kc] * element;
                b[r] -= b[pivot_col] * element;
                a[r][pivot_col] = 0.0;
            }
        }
    }
    return true;
}

// --- sleep tracking (Jolt's 3-sphere movement test) ---

/// One face of a convex hull: an outward unit normal, the plane offset (n . p for any
/// point on the face), and a CCW loop of vertex indices into the hull's `points`.
pub const HullFace = struct {
    normal: Vec, // outward unit normal (hull-local, COM-centred)
    plane_offset: f32, // n . p for points on this face
    first_vertex: u32, // start index into ConvexHull.face_vertices
    vertex_count: u32, // number of vertices in this face's loop
};

/// A convex hull: vertices and faces in a COM-centred local frame, plus precomputed
/// mass properties (per unit density) so shapeMass only scales by the density. All
/// arrays are owned by the hull and live for the world's lifetime (see ShapeStore).
pub const ConvexHull = struct {
    points: []const Vec, // unique hull vertices (support mapping reads these)
    faces: []const HullFace, // hull faces (supportingFace + clipping read these)
    face_vertices: []const u32, // flattened CCW vertex-index loops for all faces
    bounds: Aabb, // local AABB about the COM
    inner_radius: f32, // largest sphere about the COM that fits inside (CCD threshold)
    volume: f32, // hull volume (mass = volume * density)
    inertia_diagonal: Vec, // principal moments per unit density
    inertia_rotation: Quat, // principal-axis frame
};

/// One leaf of a compound shape: a sub-shape posed in the compound's (COM-centred)
/// local frame. Sub-shapes are leaves (a compound of compounds is not supported); the
/// narrow phase decomposes a compound into these before colliding.
pub const CompoundChild = struct {
    shape: ShapeId, // a leaf shape id in the same ShapeStore
    local_pos: Vec, // child COM position in the compound's COM-centred frame
    local_rot: Quat, // child orientation in the compound frame
};

pub const Compound = struct {
    children: []const CompoundChild, // owned; freed by ShapeStore.deinit
    bounds: Aabb, // local AABB enclosing all children (about the COM)
    inner_radius: f32, // conservative CCD threshold (min over children)
    volume: f32, // total volume (mass = volume * density)
    inertia_diagonal: Vec, // principal moments per unit density
    inertia_rotation: Quat, // principal-axis frame
};

/// One triangle of a mesh: vertex indices, the precomputed outward face normal, and a
/// 3-bit mask of which edges are "active" (a real convex feature, bit e for the edge
/// from vertex e to vertex (e+1)%3). Contacts on inactive edges get their normal
/// snapped to the face normal so a body slides smoothly across internal seams.
pub const MeshTriangle = struct {
    v: [3]u32, // indices into Mesh.vertices (CCW seen from the +normal side)
    normal: Vec, // unit face normal
    active_edges: u8 = 0, // bit e set => edge (v[e] -> v[(e+1)%3]) is active
};

/// A node of the mesh's static bounding-volume hierarchy. A leaf owns a contiguous
/// run of triangles in Mesh.tri_order; an internal node has two children and no
/// triangles (tri_count == 0).
pub const MeshBvhNode = struct {
    bounds: Aabb,
    left: u32, // child node index (internal only)
    right: u32, // child node index (internal only)
    first_tri: u32, // start index into Mesh.tri_order (leaf only)
    tri_count: u32, // triangles in this leaf; 0 marks an internal node
};

/// A triangle mesh: vertices, triangles, and a BVH for broad-phase culling of the
/// triangles against a colliding convex shape. Intended for STATIC level geometry
/// (it has no volume, so dynamic mesh bodies fall back to a unit mass). All arrays
/// are owned by the mesh and freed by ShapeStore.deinit.
pub const Mesh = struct {
    vertices: []const Vec,
    triangles: []const MeshTriangle,
    nodes: []const MeshBvhNode, // node 0 is the root
    tri_order: []const u32, // triangle indices grouped by BVH leaf
    bounds: Aabb, // local AABB of the whole mesh
    // Per-triangle surface id (indexed by triangle index, the low bits of a contact's `sub`).
    // Opaque to the engine — the user maps it to friction/sound/etc. Empty = every triangle 0.
    // Owned and freed by ShapeStore.deinit when non-empty.
    materials: []const u16,
};

/// A regular height grid (terrain). Sample (gx, gz) sits at local position
/// (gx*cell_size, heights[gz*sample_count_x + gx], gz*cell_size); the field's local
/// origin is therefore its (0,0) corner. Each grid cell is two triangles, looked up
/// directly from the colliding shape's bounds (no BVH needed). Static geometry; the
/// height array is owned and freed by ShapeStore.deinit.
pub const HeightField = struct {
    heights: []const f32, // row-major: heights[gz * sample_count_x + gx]
    sample_count_x: u32,
    sample_count_z: u32,
    cell_size: f32, // uniform horizontal spacing in x and z
    bounds: Aabb, // local AABB
    // One byte per cell triangle, indexed (gz * (sample_count_x-1) + gx) * 2 + tri (tri 0 =
    // (a,d,b), tri 1 = (a,c,d)). Bit e set => edge e (verts[e] -> verts[(e+1)%3]) is active,
    // matching fixMeshNormal's convention. Precomputed at build like Mesh.active_edges so
    // contacts on internal seams snap to the face normal instead of catching.
    active_edges: []const u8,
    // Per cell-triangle surface id, indexed the same way as active_edges (the low bits of a
    // contact's `sub`). Opaque to the engine; empty = every triangle 0. Owned, freed by deinit.
    materials: []const u16,
};

/// A child shape rotated and translated within a parent frame (Jolt's RotatedTranslatedShape).
/// Because bodies are positioned by their COM and the wrapped child's COM coincides with this
/// shape's COM, collision only folds the rotation onto the child's pose; the translation is
/// absorbed into the cached COM. Bounds/COM/mass are cached at build (per unit density).
pub const RotatedTranslated = struct {
    child: ShapeId,
    rotation: Quat,
    position: Vec,
    com: Vec,
    bounds: Aabb,
    inner_radius: f32,
    volume: f32,
    inertia_diagonal: Vec,
    inertia_rotation: Quat,
};

/// A child shape whose center of mass is shifted by `offset` (Jolt's OffsetCenterOfMassShape). The
/// geometry is unchanged; only the COM (and the pose at which the child is solved) moves. Inertia is
/// inherited from the child about the child's own COM (Jolt's documented approximation).
pub const OffsetCom = struct {
    child: ShapeId,
    offset: Vec,
    com: Vec,
    bounds: Aabb,
    inner_radius: f32,
    volume: f32,
    inertia_diagonal: Vec,
    inertia_rotation: Quat,
};

/// A shape with no collision geometry and a configurable COM (Jolt's EmptyShape): a placeholder for
/// bodies that only participate through constraints. Returns a harmless unit mass.
pub const EmptyShape = struct {
    com: Vec = vec_zero,
};

/// An (effectively) infinite half-space, the cheap static ground (Jolt's PlaneShape). The solid side
/// is the -normal direction; a convex body is in contact when its deepest point crosses the plane.
/// The plane equation in local space is `dot(normal, x) + distance = 0`. For the broadphase the
/// plane is given finite cached bounds spanning `half_extent` across and below the plane.
pub const PlaneShape = struct {
    normal: Vec, // unit, local
    distance: f32, // signed plane constant: dot(normal, x) + distance = 0
    half_extent: f32, // finite span used for bounds (the plane is treated as a large slab)
    bounds: Aabb, // cached finite local bounds for the broadphase
};

pub const Shape = union(enum) {
    sphere: struct { radius: f32 },
    box: struct { half_extent: Vec, convex_radius: f32 },
    capsule: struct { half_height: f32, radius: f32 }, // segment along local Y + radius
    cylinder: struct { half_height: f32, radius: f32, convex_radius: f32 }, // along local Y
    tapered_capsule: struct { half_height: f32, top_radius: f32, bottom_radius: f32 }, // along local Y
    convex_hull: ConvexHull, // arbitrary convex polyhedron (built from a point cloud)
    compound: Compound, // several posed leaf shapes acting as one rigid body
    triangle: struct { v0: Vec, v1: Vec, v2: Vec }, // transient leaf used by mesh collision
    mesh: Mesh, // static triangle soup with a BVH (level geometry)
    heightfield: HeightField, // static regular height grid (terrain)
    rotated_translated: RotatedTranslated, // child posed within a parent frame (decorator)
    offset_com: OffsetCom, // child with a shifted center of mass (decorator)
    empty: EmptyShape, // no collision; constraint-only placeholder
    plane: PlaneShape, // infinite static half-space (cheap ground)
    // non-convex shapes are decomposed into convex leaves, and decorators resolved to their
    // children, by the narrow phase before any support function runs.
};

fn shapeLocalBounds(shape: *const Shape) Aabb {
    switch (shape.*) {
        .sphere => |s| {
            const r: Vec = splat(s.radius);
            return .{ .min = -r, .max = r };
        },
        .box => |b| return .{ .min = -b.half_extent, .max = b.half_extent },
        .capsule => |c| {
            const ext: Vec = vec(c.radius, c.half_height + c.radius, c.radius);
            return .{ .min = -ext, .max = ext };
        },
        .cylinder => |cyl| {
            const ext: Vec = vec(cyl.radius, cyl.half_height, cyl.radius);
            return .{ .min = -ext, .max = ext };
        },
        .tapered_capsule => |tc| {
            const rmax: f32 = @max(tc.top_radius, tc.bottom_radius);
            return .{
                .min = vec(-rmax, -(tc.half_height + tc.bottom_radius), -rmax),
                .max = vec(rmax, tc.half_height + tc.top_radius, rmax),
            };
        },
        .convex_hull => |h| return h.bounds,
        .compound => |comp| return comp.bounds,
        .triangle => |t| {
            const lo: Vec = @min(t.v0, @min(t.v1, t.v2));
            const hi: Vec = @max(t.v0, @max(t.v1, t.v2));
            return .{ .min = lo, .max = hi };
        },
        .mesh => |m| return m.bounds,
        .heightfield => |hf| return hf.bounds,
        .rotated_translated => |rt| return rt.bounds,
        .offset_com => |oc| return oc.bounds,
        .empty => return .{ .min = vec_zero, .max = vec_zero },
        .plane => |pl| return pl.bounds,
    }
}

/// The three points whose motion is tracked for sleeping: the centre of mass and the
/// COM offset along the two largest local bounding-box axes (so rotation, not just
/// translation, is measured). Matches Jolt's GetSleepTestPoints.
fn sleepTestPoints(com: Vec, rot: Quat, shape: *const Shape) [3]Vec {
    const local: Aabb = shapeLocalBounds(shape);
    const half: Vec = (local.max - local.min) * splat(0.5);

    // Indices of the two largest half-extents.
    var idx0: u32 = 0; // largest
    var idx1: u32 = 1; // second largest
    if (vlane(half, idx1) > vlane(half, idx0)) {
        idx0 = 1;
        idx1 = 0;
    }
    if (half[2] > vlane(half, idx0)) {
        idx1 = idx0;
        idx0 = 2;
    } else if (half[2] > vlane(half, idx1)) {
        idx1 = 2;
    }

    var e0: [3]f32 = .{ 0, 0, 0 };
    var e1: [3]f32 = .{ 0, 0, 0 };
    e0[idx0] = vlane(half, idx0);
    e1[idx1] = vlane(half, idx1);
    const axis0: Vec = vec(e0[0], e0[1], e0[2]);
    const axis1: Vec = vec(e1[0], e1[1], e1[2]);

    return .{
        com,
        com + rotate(rot, axis0),
        com + rotate(rot, axis1),
    };
}

/// One of a body's three sleep-tracking spheres. The sphere grows to enclose every
/// position its tracked point has visited since the timer last reset; if it ever
/// exceeds the movement tolerance the body is judged to be moving. (Jolt's design.)
pub const SleepSphere = struct { center: Vec, radius: f32 };

pub const Motion = struct {
    lin_vel: Vec,
    ang_vel: Vec,

    // I_body^-1 = R diag(inv_inertia_diagonal) R^-1, R = inertia_rotation.
    inv_mass: f32, // 0 for static and kinematic
    inv_inertia_diagonal: Vec,
    inertia_rotation: Quat,

    linear_damping: f32,
    angular_damping: f32,
    gravity_scale: f32,
    max_linear_speed: f32,
    max_angular_speed: f32,
    apply_gyroscopic: bool,

    // allowed_DOFs as world-space velocity masks: 1.0 for a free axis, 0.0 for a locked
    // one. Locked velocity components are zeroed every step before the body integrates,
    // so it never accumulates motion along a locked world axis (used e.g. to pin a body
    // to a plane, or to stop it tipping over). w is unused (velocity w is 0).
    lin_lock: Vec,
    ang_lock: Vec,

    force: Vec, // accumulated; reset in the sleep phase (NOT after gravity — Jolt
    torque: Vec, //   reads it during contact setup for the restitution correction)

    // Sleep tracking: three points (COM + the two largest local bounding-box axes)
    // bound the body's translation and rotation. sleep_timer accumulates while all
    // three stay within tolerance.
    sleep_spheres: [3]SleepSphere,
    sleep_timer: f32,

    pub const zero: Motion = .{
        .lin_vel = vec_zero,
        .ang_vel = vec_zero,
        .inv_mass = 0.0,
        .inv_inertia_diagonal = vec_zero,
        .inertia_rotation = quat_identity,
        .linear_damping = 0.0,
        .angular_damping = 0.0,
        .gravity_scale = 0.0,
        .max_linear_speed = 500.0,
        .max_angular_speed = 0.25 * pi * 60.0,
        .apply_gyroscopic = false,
        .lin_lock = vec(1.0, 1.0, 1.0),
        .ang_lock = vec(1.0, 1.0, 1.0),
        .force = vec_zero,
        .torque = vec_zero,
        .sleep_spheres = .{
            .{ .center = vec_zero, .radius = 0.0 },
            .{ .center = vec_zero, .radius = 0.0 },
            .{ .center = vec_zero, .radius = 0.0 },
        },
        .sleep_timer = 0.0,
    };
};

fn resetSleepSpheres(m: *Motion, points: [3]Vec) void {
    for (&m.sleep_spheres, points) |*s, p| {
        s.* = .{ .center = p, .radius = 0.0 };
    }
    m.sleep_timer = 0.0;
}

/// Grow a sphere minimally to include p (Jolt's Sphere::EncapsulatePoint).
fn encapsulate(s: *SleepSphere, p: Vec) void {
    const d: Vec = p - s.center;
    const dist_sq: f32 = lengthSq3(d);
    if (dist_sq > s.radius * s.radius) {
        const dist: f32 = @sqrt(dist_sq);
        const new_radius: f32 = (s.radius + dist) * 0.5;
        s.center += d * splat((new_radius - s.radius) / dist);
        s.radius = new_radius;
    }
}

// --- union-find over the contact graph (island building) ---

fn dsuFind(parent: []u32, i: u32) u32 {
    var root: u32 = i;
    while (parent[root] != root) {
        root = parent[root];
    }
    // Path compression.
    var cur: u32 = i;
    while (parent[cur] != root) {
        const next: u32 = parent[cur];
        parent[cur] = root;
        cur = next;
    }
    return root;
}

fn dsuUnion(parent: []u32, a: u32, b: u32) void {
    const ra: u32 = dsuFind(parent, a);
    const rb: u32 = dsuFind(parent, b);
    if (ra != rb) {
        parent[@max(ra, rb)] = @min(ra, rb);
    } // attach to the lower index
}

// =============================================================================
// Shapes. One tagged union, one support switch, no vtables. Convex shapes use
// Jolt's "core support point + convex radius" representation.
// =============================================================================

/// Support mapping of the CORE (convex radius excluded). dir need not be unit.
fn supportCore(shape: *const Shape, dir: Vec) Vec {
    switch (shape.*) {
        .sphere => return vec_zero,
        .box => |b| {
            const inset: Vec = b.half_extent - splat(b.convex_radius);
            return signSelect(dir, inset);
        },
        .capsule => |c| {
            const up: f32 = if (dir[1] >= 0.0) c.half_height else -c.half_height;
            return vec(0.0, up, 0.0);
        },
        .cylinder => |cyl| {
            // Core = the cylinder shrunk by its convex radius (GJK adds the rim rounding).
            const hh: f32 = cyl.half_height - cyl.convex_radius;
            const rr: f32 = cyl.radius - cyl.convex_radius;
            const y: f32 = if (dir[1] >= 0.0) hh else -hh;
            const xz_len: f32 = @sqrt(dir[0] * dir[0] + dir[2] * dir[2]);
            if (xz_len > 1.0e-9) {
                const s: f32 = rr / xz_len;
                return vec(dir[0] * s, y, dir[2] * s);
            }
            return vec(0.0, y, 0.0);
        },
        .tapered_capsule => |tc| {
            // Convex hull of two unequal spheres: support = the farther sphere's support
            // (support of a hull of convex sets is the max of their supports). The full
            // radius is included here, so convexRadius is 0.
            const len: f32 = length3(dir);
            const ndir: Vec = if (len > 1.0e-9) dir / splat(len) else vec(0, 1, 0);
            const top: Vec = vec(0, tc.half_height, 0) + ndir * splat(tc.top_radius);
            const bot: Vec = vec(0, -tc.half_height, 0) + ndir * splat(tc.bottom_radius);
            return if (dot3(top, dir) >= dot3(bot, dir)) top else bot;
        },
        .convex_hull => |h| {
            // The support point is simply the vertex farthest along dir; interior
            // vertices never win, so the cloud's hull is handled implicitly.
            var best: Vec = h.points[0];
            var best_dot: f32 = dot3(best, dir);
            for (h.points[1..]) |p| {
                const d: f32 = dot3(p, dir);
                if (d > best_dot) {
                    best_dot = d;
                    best = p;
                }
            }
            return best;
        },
        // A compound has no single support mapping; the narrow phase decomposes it into
        // its leaf children before any support function runs, so this is never reached
        // on the simulation path (scene queries against compounds aren't supported yet).
        .compound => return vec_zero,
        .triangle => |t| {
            // The deepest of the three vertices along dir.
            var best: Vec = t.v0;
            var best_dot: f32 = dot3(t.v0, dir);
            const d1: f32 = dot3(t.v1, dir);
            if (d1 > best_dot) {
                best_dot = d1;
                best = t.v1;
            }
            const d2: f32 = dot3(t.v2, dir);
            if (d2 > best_dot) {
                best_dot = d2;
                best = t.v2;
            }
            return best;
        },
        // A mesh is decomposed into triangle leaves before any support function runs.
        .mesh => return vec_zero,
        .heightfield => return vec_zero,
        // resolved or handled before any support call reaches here
        .rotated_translated, .offset_com, .empty, .plane => unreachable,
    }
}

fn convexRadius(shape: *const Shape) f32 {
    return switch (shape.*) {
        .sphere => |s| s.radius,
        .box => |b| b.convex_radius,
        .capsule => |c| c.radius,
        .cylinder => |cyl| cyl.convex_radius,
        .tapered_capsule => 0.0,
        .convex_hull => 0.0, // hulls are sharp-cornered (no rounding)
        .compound => 0.0,
        .triangle => 0.0,
        .mesh => 0.0,
        .heightfield => 0.0,
        .rotated_translated, .offset_com, .empty, .plane => 0.0,
    };
}

fn shapeCenterOfMass(shape: *const Shape) Vec {
    return switch (shape.*) {
        .rotated_translated => |rt| rt.com,
        .offset_com => |oc| oc.com,
        .empty => |e| e.com,
        else => vec_zero, // symmetric primitives & compound (COM at origin by construction)
    };
}

/// Inner radius: largest sphere centred at the COM that fits inside the shape. Jolt
/// uses this for the CCD linear-cast threshold.
fn shapeInnerRadius(shape: *const Shape) f32 {
    return switch (shape.*) {
        .sphere => |s| s.radius,
        .box => |b| @min(b.half_extent[0], @min(b.half_extent[1], b.half_extent[2])),
        .capsule => |c| c.radius,
        .cylinder => |cyl| @min(cyl.radius, cyl.half_height),
        .tapered_capsule => |tc| @min(tc.top_radius, tc.bottom_radius),
        .convex_hull => |h| h.inner_radius,
        .compound => |comp| comp.inner_radius,
        .triangle => 0.0,
        .mesh => 0.0, // static: sweep conservatively if ever used as a CCD body
        .heightfield => 0.0,
        .rotated_translated => |rt| rt.inner_radius,
        .offset_com => |oc| oc.inner_radius,
        .empty => 0.0,
        .plane => 0.0,
    };
}

pub const MassProperties = struct {
    mass: f32,
    inv_mass: f32,
    inv_inertia_diagonal: Vec, // inverse principal moments
    inertia_rotation: Quat, // identity for the symmetric primitives
};

fn shapeMass(shape: *const Shape, density: f32) MassProperties {
    switch (shape.*) {
        .sphere => |s| {
            const radius: f32 = s.radius;
            const radius_sq: f32 = radius * radius;
            const volume: f32 = (4.0 / 3.0) * pi * radius_sq * radius;
            const mass: f32 = volume * density;
            // Solid sphere: I = 2/5 m r^2 about every axis.
            const inertia: f32 = 0.4 * mass * radius_sq;
            const inverse_inertia: f32 = 1.0 / inertia;
            return .{
                .mass = mass,
                .inv_mass = 1.0 / mass,
                .inv_inertia_diagonal = vec(inverse_inertia, inverse_inertia, inverse_inertia),
                .inertia_rotation = quat_identity,
            };
        },
        .box => |b| {
            const size_x: f32 = 2.0 * b.half_extent[0];
            const size_y: f32 = 2.0 * b.half_extent[1];
            const size_z: f32 = 2.0 * b.half_extent[2];
            const mass: f32 = size_x * size_y * size_z * density;
            // Solid box: I_axis = m/12 * (sum of the squares of the other two sizes).
            const mass_twelfth: f32 = mass / 12.0;
            const inertia_x: f32 = mass_twelfth * (size_y * size_y + size_z * size_z);
            const inertia_y: f32 = mass_twelfth * (size_x * size_x + size_z * size_z);
            const inertia_z: f32 = mass_twelfth * (size_x * size_x + size_y * size_y);
            return .{
                .mass = mass,
                .inv_mass = 1.0 / mass,
                .inv_inertia_diagonal = vec(1.0 / inertia_x, 1.0 / inertia_y, 1.0 / inertia_z),
                .inertia_rotation = quat_identity,
            };
        },
        .capsule => |c| {
            // A capsule is a cylinder (height = 2 * half_height) plus two hemisphere
            // caps that together form one sphere. Combine their masses and inertias.
            const radius: f32 = c.radius;
            const cylinder_height: f32 = 2.0 * c.half_height;
            const radius_sq: f32 = radius * radius;
            const cylinder_mass: f32 = pi * radius_sq * cylinder_height * density;
            const caps_mass: f32 = (4.0 / 3.0) * pi * radius_sq * radius * density;
            const mass: f32 = cylinder_mass + caps_mass;
            // Axis Y runs along the capsule; X and Z are the two perpendicular axes.
            const inertia_along_axis: f32 = 0.5 * cylinder_mass * radius_sq + 0.4 * caps_mass * radius_sq;
            const inertia_perpendicular: f32 =
                cylinder_mass * (3.0 * radius_sq + cylinder_height * cylinder_height) / 12.0 +
                0.4 * caps_mass * radius_sq;
            const inv_inertia_perpendicular: f32 = 1.0 / inertia_perpendicular;
            const inv_inertia_along_axis: f32 = 1.0 / inertia_along_axis;
            const inv_inertia: Vec = vec(
                inv_inertia_perpendicular,
                inv_inertia_along_axis,
                inv_inertia_perpendicular,
            );
            return .{
                .mass = mass,
                .inv_mass = 1.0 / mass,
                .inv_inertia_diagonal = inv_inertia,
                .inertia_rotation = quat_identity,
            };
        },
        .cylinder => |cyl| {
            // Solid cylinder of radius r, height h about its centre.
            const r: f32 = cyl.radius;
            const h: f32 = 2.0 * cyl.half_height;
            const r2: f32 = r * r;
            const mass: f32 = pi * r2 * h * density;
            const inertia_axis: f32 = 0.5 * mass * r2; // about Y (the cylinder axis)
            const inertia_perp: f32 = mass * (3.0 * r2 + h * h) / 12.0; // about X and Z
            return .{
                .mass = mass,
                .inv_mass = 1.0 / mass,
                .inv_inertia_diagonal = vec(1.0 / inertia_perp, 1.0 / inertia_axis, 1.0 / inertia_perp),
                .inertia_rotation = quat_identity,
            };
        },
        .tapered_capsule => |tc| {
            // Collision is exact; inertia is approximated by a capsule of the average
            // radius (the true COM also shifts toward the larger end — folded into this
            // documented approximation). Refine later if a tapered body needs it.
            const r: f32 = 0.5 * (tc.top_radius + tc.bottom_radius);
            const cyl_h: f32 = 2.0 * tc.half_height;
            const r2: f32 = r * r;
            const cyl_mass: f32 = pi * r2 * cyl_h * density;
            const caps_mass: f32 = (4.0 / 3.0) * pi * r2 * r * density;
            const mass: f32 = cyl_mass + caps_mass;
            const inertia_axis: f32 = 0.5 * cyl_mass * r2 + 0.4 * caps_mass * r2;
            const inertia_perp: f32 = cyl_mass * (3.0 * r2 + cyl_h * cyl_h) / 12.0 + 0.4 * caps_mass * r2;
            return .{
                .mass = mass,
                .inv_mass = 1.0 / mass,
                .inv_inertia_diagonal = vec(1.0 / inertia_perp, 1.0 / inertia_axis, 1.0 / inertia_perp),
                .inertia_rotation = quat_identity,
            };
        },
        .convex_hull => |h| {
            // Volume and principal moments were precomputed for unit density at build
            // time; both scale linearly with density.
            const mass: f32 = h.volume * density;
            const ix: f32 = density * h.inertia_diagonal[0];
            const iy: f32 = density * h.inertia_diagonal[1];
            const iz: f32 = density * h.inertia_diagonal[2];
            return .{
                .mass = mass,
                .inv_mass = 1.0 / mass,
                .inv_inertia_diagonal = vec(1.0 / ix, 1.0 / iy, 1.0 / iz),
                .inertia_rotation = h.inertia_rotation,
            };
        },
        .compound => |comp| {
            // The children's combined volume and principal inertia (per unit density)
            // were precomputed at build time; scale by density.
            const mass: f32 = comp.volume * density;
            const ix: f32 = density * comp.inertia_diagonal[0];
            const iy: f32 = density * comp.inertia_diagonal[1];
            const iz: f32 = density * comp.inertia_diagonal[2];
            return .{
                .mass = mass,
                .inv_mass = 1.0 / mass,
                .inv_inertia_diagonal = vec(1.0 / ix, 1.0 / iy, 1.0 / iz),
                .inertia_rotation = comp.inertia_rotation,
            };
        },
        // A triangle and a mesh have no volume; they are not meant to be dynamic
        // bodies (triangles are transient; meshes/heightfields are static geometry).
        // Return a harmless unit mass so a misconfigured dynamic body doesn't divide
        // by zero.
        .triangle, .mesh, .heightfield => return .{
            .mass = 1.0,
            .inv_mass = 1.0,
            .inv_inertia_diagonal = vec(1.0, 1.0, 1.0),
            .inertia_rotation = quat_identity,
        },
        .rotated_translated => |rt| {
            const mass: f32 = rt.volume * density;
            return .{
                .mass = mass,
                .inv_mass = if (mass > 0.0) 1.0 / mass else 0.0,
                .inv_inertia_diagonal = reciprocal3(splat(density) * rt.inertia_diagonal),
                .inertia_rotation = rt.inertia_rotation,
            };
        },
        .offset_com => |oc| {
            const mass: f32 = oc.volume * density;
            return .{
                .mass = mass,
                .inv_mass = if (mass > 0.0) 1.0 / mass else 0.0,
                .inv_inertia_diagonal = reciprocal3(splat(density) * oc.inertia_diagonal),
                .inertia_rotation = oc.inertia_rotation,
            };
        },
        .empty => return .{
            .mass = 1.0,
            .inv_mass = 1.0,
            .inv_inertia_diagonal = vec(1.0, 1.0, 1.0),
            .inertia_rotation = quat_identity,
        },
        // A plane is static infinite geometry; a harmless unit mass keeps a misconfigured
        // dynamic body from dividing by zero.
        .plane => return .{
            .mass = 1.0,
            .inv_mass = 1.0,
            .inv_inertia_diagonal = vec(1.0, 1.0, 1.0),
            .inertia_rotation = quat_identity,
        },
    }
}

pub fn buildConvexHull(gpa: std.mem.Allocator, input_points: []const Vec) !ConvexHull {
    const tol: f32 = 1.0e-4;

    // 1) De-duplicate the input points.
    var pts: std.ArrayListUnmanaged(Vec) = .empty;
    defer pts.deinit(gpa);
    for (input_points) |p| {
        var duplicate: bool = false;
        for (pts.items) |q| {
            if (lengthSq3(p - q) < tol * tol) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            try pts.append(gpa, p);
        }
    }
    if (pts.items.len < 4) {
        return error.DegenerateHull;
    }
    const n_pts: usize = pts.items.len;

    // Interior reference point used to orient face normals outward.
    var centroid: Vec = vec_zero;
    for (pts.items) |p| {
        centroid += p;
    }
    centroid = centroid / splat(@floatFromInt(n_pts));

    // 2) Enumerate distinct hull-face planes: a plane through three points is a face
    //    iff every other point lies on or below it. Dedup by (normal, offset).
    var face_normals: std.ArrayListUnmanaged(Vec) = .empty;
    defer face_normals.deinit(gpa);
    var face_offsets: std.ArrayListUnmanaged(f32) = .empty;
    defer face_offsets.deinit(gpa);

    var i: usize = 0;
    while (i < n_pts) : (i += 1) {
        var j: usize = i + 1;
        while (j < n_pts) : (j += 1) {
            var k: usize = j + 1;
            while (k < n_pts) : (k += 1) {
                var normal: Vec = cross(pts.items[j] - pts.items[i], pts.items[k] - pts.items[i]);
                const len: f32 = length3(normal);
                if (len < 1.0e-8) {
                    continue;
                } // collinear triple
                normal = normal / splat(len);
                var offset: f32 = dot3(normal, pts.items[i]);
                if (dot3(normal, centroid) > offset) { // flip to face outward
                    normal = vec_zero - normal;
                    offset = -offset;
                }
                var is_face: bool = true;
                for (pts.items) |p| {
                    if (dot3(normal, p) > offset + tol) {
                        is_face = false;
                        break;
                    }
                }
                if (!is_face) {
                    continue;
                }
                var seen: bool = false;
                for (face_normals.items, face_offsets.items) |existing_n, existing_o| {
                    if (dot3(existing_n, normal) > 0.999 and @abs(existing_o - offset) < tol) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    try face_normals.append(gpa, normal);
                    try face_offsets.append(gpa, offset);
                }
            }
        }
    }
    if (face_normals.items.len < 4) {
        return error.DegenerateHull;
    }

    // 3) For each face plane, gather the points lying on it and order them CCW about
    //    the normal, building the flattened face-vertex index loops.
    var faces: std.ArrayListUnmanaged(HullFace) = .empty;
    defer faces.deinit(gpa);
    var face_verts: std.ArrayListUnmanaged(u32) = .empty;
    defer face_verts.deinit(gpa);
    var on_plane: std.ArrayListUnmanaged(u32) = .empty;
    defer on_plane.deinit(gpa);
    var angles: std.ArrayListUnmanaged(f32) = .empty;
    defer angles.deinit(gpa);

    for (face_normals.items, face_offsets.items) |normal, offset| {
        on_plane.clearRetainingCapacity();
        for (pts.items, 0..) |p, idx| {
            if (@abs(dot3(normal, p) - offset) < tol) {
                try on_plane.append(gpa, @intCast(idx));
            }
        }
        if (on_plane.items.len < 3) {
            continue;
        }

        const u_axis: Vec = normalizedPerpendicular(normal);
        const v_axis: Vec = cross(normal, u_axis);
        var face_center: Vec = vec_zero;
        for (on_plane.items) |vi| {
            face_center += pts.items[vi];
        }
        face_center = face_center / splat(@floatFromInt(on_plane.items.len));

        angles.clearRetainingCapacity();
        for (on_plane.items) |vi| {
            const rel: Vec = pts.items[vi] - face_center;
            try angles.append(gpa, atan2Rad(dot3(rel, v_axis), dot3(rel, u_axis)));
        }
        // Insertion sort the vertex indices by angle (faces are small).
        var a_idx: usize = 1;
        while (a_idx < on_plane.items.len) : (a_idx += 1) {
            const key_angle: f32 = angles.items[a_idx];
            const key_vertex: u32 = on_plane.items[a_idx];
            var b_idx: isize = @as(isize, @intCast(a_idx)) - 1;
            while (b_idx >= 0 and angles.items[@intCast(b_idx)] > key_angle) : (b_idx -= 1) {
                angles.items[@intCast(b_idx + 1)] = angles.items[@intCast(b_idx)];
                on_plane.items[@intCast(b_idx + 1)] = on_plane.items[@intCast(b_idx)];
            }
            angles.items[@intCast(b_idx + 1)] = key_angle;
            on_plane.items[@intCast(b_idx + 1)] = key_vertex;
        }

        const first: u32 = @intCast(face_verts.items.len);
        for (on_plane.items) |vi| {
            try face_verts.append(gpa, vi);
        }
        try faces.append(gpa, .{
            .normal = normal,
            .plane_offset = offset,
            .first_vertex = first,
            .vertex_count = @intCast(on_plane.items.len),
        });
    }
    if (faces.items.len < 4) {
        return error.DegenerateHull;
    }

    // 4) Volume, centre of mass and inertia (per unit density), summed over the
    //    tetrahedra (origin, triangle) of every triangulated face. The covariance of
    //    a tet with vertices (0,a,b,c) is det * A * C_canon * A^T (A = [a b c]).
    const c_canon: Mat3 = .{ .col = .{
        vec(1.0 / 60.0, 1.0 / 120.0, 1.0 / 120.0),
        vec(1.0 / 120.0, 1.0 / 60.0, 1.0 / 120.0),
        vec(1.0 / 120.0, 1.0 / 120.0, 1.0 / 60.0),
    } };
    var volume: f32 = 0.0;
    var moment: Vec = vec_zero; // first moment about the origin
    var covariance: Mat3 = Mat3.zero; // second moment (x x^T) about the origin
    for (faces.items) |face| {
        const v0: Vec = pts.items[face_verts.items[face.first_vertex]];
        var t: u32 = 1;
        while (t + 1 < face.vertex_count) : (t += 1) {
            const vb: Vec = pts.items[face_verts.items[face.first_vertex + t]];
            const vc: Vec = pts.items[face_verts.items[face.first_vertex + t + 1]];
            const det: f32 = dot3(v0, cross(vb, vc)); // 6 * signed tet volume
            volume += det / 6.0;
            moment += splat(det / 24.0) * (v0 + vb + vc);
            const a_mat: Mat3 = .{ .col = .{ v0, vb, vc } };
            covariance = covariance.add(a_mat.mul(c_canon).mul(a_mat.transpose()).scale(det));
        }
    }
    // Guard winding: if the summed volume is negative the faces wound inward; flip
    // the sign of all (volume-proportional) accumulators together.
    if (volume < 0.0) {
        volume = -volume;
        moment = vec_zero - moment;
        covariance = covariance.scale(-1.0);
    }
    if (volume < 1.0e-9) {
        return error.DegenerateHull;
    }

    const com: Vec = moment / splat(volume);
    // Shift the second moment to the COM, then form the inertia tensor about the COM:
    // C_com = C_origin - V (com com^T);  I = trace(C_com) E - C_com.
    const com_outer: Mat3 = .{ .col = .{
        com * splat(com[0]),
        com * splat(com[1]),
        com * splat(com[2]),
    } };
    const cov_com: Mat3 = covariance.add(com_outer.scale(-volume));
    const trace: f32 = cov_com.col[0][0] + cov_com.col[1][1] + cov_com.col[2][2];
    const inertia: Mat3 = Mat3.diagonal(trace).add(cov_com.scale(-1.0));
    const eigen: EigenResult = jacobiEigenSymmetric3(inertia);

    // 5) Recentre vertices and faces on the COM; compute local bounds and inradius.
    const out_points: []Vec = try gpa.alloc(Vec, n_pts);
    errdefer gpa.free(out_points);
    var box: Aabb = .empty;
    for (pts.items, 0..) |p, idx| {
        const q: Vec = p - com;
        out_points[idx] = q;
        box.encapsulate(q);
    }

    const out_faces: []HullFace = try gpa.alloc(HullFace, faces.items.len);
    errdefer gpa.free(out_faces);
    var inner_radius: f32 = floatMax(f32);
    for (faces.items, 0..) |face, idx| {
        const shifted_offset: f32 = face.plane_offset - dot3(face.normal, com);
        out_faces[idx] = .{
            .normal = face.normal,
            .plane_offset = shifted_offset,
            .first_vertex = face.first_vertex,
            .vertex_count = face.vertex_count,
        };
        if (shifted_offset < inner_radius) {
            inner_radius = shifted_offset;
        } // dist COM->face
    }
    if (inner_radius < 0.0) {
        inner_radius = 0.0;
    }

    const out_face_verts: []u32 = try gpa.alloc(u32, face_verts.items.len);
    errdefer gpa.free(out_face_verts);
    @memcpy(out_face_verts, face_verts.items);

    return .{
        .points = out_points,
        .faces = out_faces,
        .face_vertices = out_face_verts,
        .bounds = box,
        .inner_radius = inner_radius,
        .volume = volume,
        .inertia_diagonal = eigen.values,
        .inertia_rotation = eigen.rotation,
    };
}

/// Undirected mesh edge (sorted vertex indices) and the first triangle seen on it.
const EdgeKey = struct { lo: u32, hi: u32 };

const EdgeRef = struct { tri: u32, far: u32, edge: u8 };

/// Two triangles whose dihedral is within this of flat count the shared edge as an
/// internal seam (inactive); anything sharper that bulges outward is an active edge.
const mesh_active_edge_cos: f32 = 0.999; // ~2.6 degrees

fn other_edge_bit(edge: u8) u8 {
    return switch (edge) {
        0 => 0b001,
        1 => 0b010,
        else => 0b100,
    };
}

const mesh_bvh_leaf: u32 = 4; // triangles per leaf (small => tighter culling)

/// Recursively build a BVH over tri_order[first .. first+count) by midpoint-splitting
/// along the longest axis of the centroid bounds, appending nodes to `nodes` and
/// returning the index of the node just built.
fn buildMeshBvhNode(
    gpa: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(MeshBvhNode),
    tri_order: []u32,
    centroids: []const Vec,
    tri_bounds: []const Aabb,
    first: usize,
    count: usize,
) !u32 {
    const node_index: u32 = @intCast(nodes.items.len);
    try nodes.append(gpa, undefined); // reserve; fields set below (children may realloc)

    var bounds: Aabb = tri_bounds[tri_order[first]];
    var c_min: Vec = centroids[tri_order[first]];
    var c_max: Vec = centroids[tri_order[first]];
    var i: usize = first + 1;
    while (i < first + count) : (i += 1) {
        bounds = bounds.combine(tri_bounds[tri_order[i]]);
        c_min = @min(c_min, centroids[tri_order[i]]);
        c_max = @max(c_max, centroids[tri_order[i]]);
    }

    if (count <= mesh_bvh_leaf) {
        nodes.items[node_index] = .{
            .bounds = bounds,
            .left = 0,
            .right = 0,
            .first_tri = @intCast(first),
            .tri_count = @intCast(count),
        };
        return node_index;
    }

    // Split along the longest centroid-bounds axis at its midpoint.
    const span: Vec = c_max - c_min;
    var axis: usize = 0;
    if (span[1] > vlane(span, axis)) {
        axis = 1;
    }
    if (span[2] > vlane(span, axis)) {
        axis = 2;
    }
    const mid_value: f32 = 0.5 * (vlane(c_min, axis) + vlane(c_max, axis));

    var lo: usize = first;
    var hi: usize = first + count;
    while (lo < hi) {
        if (vlane(centroids[tri_order[lo]], axis) < mid_value) {
            lo += 1;
        } else {
            hi -= 1;
            const tmp: u32 = tri_order[lo];
            tri_order[lo] = tri_order[hi];
            tri_order[hi] = tmp;
        }
    }
    var left_count: usize = lo - first;
    if (left_count == 0 or left_count == count) {
        left_count = count / 2;
    } // degenerate split

    const left_index: u32 = try buildMeshBvhNode(
        gpa,
        nodes,
        tri_order,
        centroids,
        tri_bounds,
        first,
        left_count,
    );
    const right_index: u32 = try buildMeshBvhNode(
        gpa,
        nodes,
        tri_order,
        centroids,
        tri_bounds,
        first + left_count,
        count - left_count,
    );
    nodes.items[node_index] = .{
        .bounds = bounds,
        .left = left_index,
        .right = right_index,
        .first_tri = 0,
        .tri_count = 0,
    };
    return node_index;
}

/// As buildMesh, but tags each triangle with a surface id (opaque to the engine; the user maps
/// it to material properties). `triangle_materials` must have one entry per triangle, or be null
/// for an all-zero (single-surface) mesh. The id array is copied and owned by the mesh.
pub fn buildMeshWithMaterials(
    gpa: std.mem.Allocator,
    vertices_in: []const Vec,
    triangles_in: []const [3]u32,
    triangle_materials: ?[]const u16,
) !Mesh {
    if (triangles_in.len == 0) {
        return error.EmptyMesh;
    }

    const out_vertices: []Vec = try gpa.alloc(Vec, vertices_in.len);
    errdefer gpa.free(out_vertices);
    @memcpy(out_vertices, vertices_in);

    const out_triangles: []MeshTriangle = try gpa.alloc(MeshTriangle, triangles_in.len);
    errdefer gpa.free(out_triangles);
    const centroids: []Vec = try gpa.alloc(Vec, triangles_in.len);
    defer gpa.free(centroids);
    const tri_bounds: []Aabb = try gpa.alloc(Aabb, triangles_in.len);
    defer gpa.free(tri_bounds);

    var mesh_bounds: Aabb = .empty;
    for (triangles_in, 0..) |tri, idx| {
        const a: Vec = vertices_in[tri[0]];
        const b: Vec = vertices_in[tri[1]];
        const c: Vec = vertices_in[tri[2]];
        var normal: Vec = cross(b - a, c - a);
        const len: f32 = length3(normal);
        normal = if (len > 1.0e-12) normal / splat(len) else vec(0, 1, 0);
        out_triangles[idx] = .{ .v = tri, .normal = normal };
        centroids[idx] = (a + b + c) / splat(3.0);
        const lo: Vec = @min(a, @min(b, c));
        const hi: Vec = @max(a, @max(b, c));
        tri_bounds[idx] = .{ .min = lo, .max = hi };
        mesh_bounds.encapsulate(lo);
        mesh_bounds.encapsulate(hi);
    }

    // Active-edge detection: walk every triangle edge, pair it with the neighbour that
    // shares it, and mark the edge active iff the surface bulges outward there (a real
    // feature). Coplanar seams and concave creases stay inactive. Leftover (boundary)
    // edges are active.
    var edge_map: std.AutoHashMapUnmanaged(EdgeKey, EdgeRef) = .empty;
    defer edge_map.deinit(gpa);
    for (out_triangles, 0..) |tri, ti| {
        var e: u8 = 0;
        while (e < 3) : (e += 1) {
            const va: u32 = tri.v[e];
            const vb: u32 = tri.v[(e + 1) % 3];
            const v_far: u32 = tri.v[(e + 2) % 3];
            const key: EdgeKey = .{ .lo = @min(va, vb), .hi = @max(va, vb) };
            const bit: u8 = switch (e) {
                0 => 0b001,
                1 => 0b010,
                else => 0b100,
            };
            if (edge_map.get(key)) |other| {
                // Shared edge. Convex iff this triangle's far vertex lies below the
                // neighbour's plane (and the faces aren't near-coplanar).
                const n_other: Vec = out_triangles[other.tri].normal;
                const edge_point: Vec = out_vertices[va];
                const cos_angle: f32 = dot3(n_other, tri.normal);
                const convex: bool = dot3(n_other, out_vertices[v_far] - edge_point) < 0.0;
                if (convex and cos_angle < mesh_active_edge_cos) {
                    out_triangles[ti].active_edges |= bit;
                    out_triangles[other.tri].active_edges |= other_edge_bit(other.edge);
                }
                _ = edge_map.remove(key);
            } else {
                try edge_map.put(gpa, key, .{ .tri = @intCast(ti), .far = v_far, .edge = e });
            }
        }
    }
    // Whatever remains was seen once: a boundary edge, always active.
    var it: std.AutoHashMapUnmanaged(EdgeKey, EdgeRef).Iterator = edge_map.iterator();
    while (it.next()) |entry| {
        const ref: EdgeRef = entry.value_ptr.*;
        out_triangles[ref.tri].active_edges |= other_edge_bit(ref.edge);
    }

    const out_tri_order: []u32 = try gpa.alloc(u32, triangles_in.len);
    errdefer gpa.free(out_tri_order);
    for (out_tri_order, 0..) |*slot, idx| {
        slot.* = @intCast(idx);
    }

    var nodes: std.ArrayListUnmanaged(MeshBvhNode) = .empty;
    errdefer nodes.deinit(gpa);
    _ = try buildMeshBvhNode(gpa, &nodes, out_tri_order, centroids, tri_bounds, 0, triangles_in.len);
    const out_nodes: []MeshBvhNode = try nodes.toOwnedSlice(gpa);
    errdefer gpa.free(out_nodes);

    var out_materials: []const u16 = &.{};
    if (triangle_materials) |tm| {
        if (tm.len != triangles_in.len) {
            return error.MeshMaterialCountMismatch;
        }
        const m: []u16 = try gpa.alloc(u16, tm.len);
        errdefer gpa.free(m);
        @memcpy(m, tm);
        out_materials = m;
    }

    return .{
        .vertices = out_vertices,
        .triangles = out_triangles,
        .nodes = out_nodes,
        .tri_order = out_tri_order,
        .bounds = mesh_bounds,
        .materials = out_materials,
    };
}

/// Build a mesh from a vertex list and triangle vertex-index triples (CCW front face).
pub fn buildMesh(
    gpa: std.mem.Allocator,
    vertices_in: []const Vec,
    triangles_in: []const [3]u32,
) !Mesh {
    return buildMeshWithMaterials(gpa, vertices_in, triangles_in, null);
}

/// Local-space position of grid sample (gx, gz) straight from the raw arrays (used at build
/// time, before a HeightField value exists).
fn hfRawVertex(
    heights: []const f32,
    sample_count_x: u32,
    cell_size: f32,
    gx: u32,
    gz: u32,
) Vec {
    const h: f32 = heights[gz * sample_count_x + gx];
    return vec(float(gx) * cell_size, h, float(gz) * cell_size);
}

/// The three local-space vertices of cell (cx, cz) triangle `tri`, in winding order matching
/// collideHeightFieldLeaf: tri 0 = (a, d, b), tri 1 = (a, c, d), where a=(cx,cz), b=(cx+1,cz),
/// c=(cx,cz+1), d=(cx+1,cz+1). This winding makes the face normal point up for flat terrain.
fn hfTriVerts(
    heights: []const f32,
    sample_count_x: u32,
    cell_size: f32,
    cx: u32,
    cz: u32,
    tri: u32,
) [3]Vec {
    const a: Vec = hfRawVertex(heights, sample_count_x, cell_size, cx, cz);
    const b: Vec = hfRawVertex(heights, sample_count_x, cell_size, cx + 1, cz);
    const c: Vec = hfRawVertex(heights, sample_count_x, cell_size, cx, cz + 1);
    const d: Vec = hfRawVertex(heights, sample_count_x, cell_size, cx + 1, cz + 1);
    return if (tri == 0) .{ a, d, b } else .{ a, c, d };
}

/// Flat index of cell (cx, cz) triangle `tri` into the per-triangle arrays.
fn hfTriIndex(
    cells_x: u32,
    cx: u32,
    cz: u32,
    tri: u32,
) usize {
    return (@as(usize, cz) * @as(usize, cells_x) + @as(usize, cx)) * 2 + @as(usize, tri);
}

/// Unit normal of triangle (v0, v1, v2), CCW seen from the +normal side. Falls back to +Y
/// for a degenerate (zero-area) triangle.
fn triFaceNormal(v0: Vec, v1: Vec, v2: Vec) Vec {
    const n: Vec = cross(v1 - v0, v2 - v0);
    const len: f32 = length3(n);
    return if (len > 1.0e-12) n / splat(len) else vec(0, 1, 0);
}

/// Identifier of the neighbour triangle sharing edge `e` of cell (cx, cz) triangle `tri`, or
/// null if that edge is on the height-field boundary. Edge e is verts[e] -> verts[(e+1)%3]
/// in the winding from hfTriVerts. The two diagonal edges are shared within the same cell; the
/// four grid edges are shared with the neighbouring cell. (See plan derivation.)
const HfNeighbour = struct { cx: u32, cz: u32, tri: u32 };

fn hfNeighbourTri(
    cells_x: u32,
    cells_z: u32,
    cx: u32,
    cz: u32,
    tri: u32,
    e: u32,
) ?HfNeighbour {
    if (tri == 0) {
        return switch (e) {
            0 => HfNeighbour{ .cx = cx, .cz = cz, .tri = 1 }, // diagonal a-d (same cell)
            1 => if (cx + 1 < cells_x) HfNeighbour{ .cx = cx + 1, .cz = cz, .tri = 1 } else null,
            else => if (cz >= 1) HfNeighbour{ .cx = cx, .cz = cz - 1, .tri = 1 } else null,
        };
    }
    return switch (e) {
        0 => if (cx >= 1) HfNeighbour{ .cx = cx - 1, .cz = cz, .tri = 0 } else null,
        1 => if (cz + 1 < cells_z) HfNeighbour{ .cx = cx, .cz = cz + 1, .tri = 0 } else null,
        else => HfNeighbour{ .cx = cx, .cz = cz, .tri = 0 }, // diagonal d-a (same cell)
    };
}

/// Bit for edge `e` in the fixMeshNormal convention (edge 0 -> 0b001, 1 -> 0b010, 2 -> 0b100).
fn hfEdgeBit(e: u32) u8 {
    return switch (e) {
        0 => 0b001,
        1 => 0b010,
        else => 0b100,
    };
}

/// As buildHeightField, but tags each cell-triangle with a surface id (opaque; the user maps it to
/// material properties). `triangle_materials` has one entry per cell-triangle (2 per cell, indexed
/// as active_edges) or is null for an all-zero field. The id array is copied and owned by the field.
pub fn buildHeightFieldWithMaterials(
    gpa: std.mem.Allocator,
    heights_in: []const f32,
    sample_count_x: u32,
    sample_count_z: u32,
    cell_size: f32,
    triangle_materials: ?[]const u16,
) !HeightField {
    if (sample_count_x < 2 or sample_count_z < 2) {
        return error.HeightFieldTooSmall;
    }
    if (heights_in.len != sample_count_x * sample_count_z) {
        return error.HeightFieldSizeMismatch;
    }

    const out_heights: []f32 = try gpa.alloc(f32, heights_in.len);
    errdefer gpa.free(out_heights);
    @memcpy(out_heights, heights_in);

    var min_h: f32 = heights_in[0];
    var max_h: f32 = heights_in[0];
    for (heights_in) |h| {
        min_h = @min(min_h, h);
        max_h = @max(max_h, h);
    }
    const extent_x: f32 = float(sample_count_x - 1) * cell_size;
    const extent_z: f32 = float(sample_count_z - 1) * cell_size;

    // Active-edge detection, mirroring buildMesh: per cell triangle, mark an edge active iff
    // the surface bulges outward there (convex) and the two faces aren't near-coplanar; edges
    // on the field boundary are always active. Contacts on inactive (internal) seams later get
    // their normal snapped onto the face normal by fixMeshNormal, so a shape sliding across the
    // grid doesn't catch on the cell diagonals or shared edges.
    const cells_x: u32 = sample_count_x - 1;
    const cells_z: u32 = sample_count_z - 1;
    const n_tris: usize = @as(usize, cells_x) * @as(usize, cells_z) * 2;

    const tri_normals: []Vec = try gpa.alloc(Vec, n_tris);
    defer gpa.free(tri_normals);
    {
        var cz: u32 = 0;
        while (cz < cells_z) : (cz += 1) {
            var cx: u32 = 0;
            while (cx < cells_x) : (cx += 1) {
                var tri: u32 = 0;
                while (tri < 2) : (tri += 1) {
                    const v: [3]Vec = hfTriVerts(out_heights, sample_count_x, cell_size, cx, cz, tri);
                    tri_normals[hfTriIndex(cells_x, cx, cz, tri)] = triFaceNormal(v[0], v[1], v[2]);
                }
            }
        }
    }

    const out_active: []u8 = try gpa.alloc(u8, n_tris);
    errdefer gpa.free(out_active);
    {
        var cz: u32 = 0;
        while (cz < cells_z) : (cz += 1) {
            var cx: u32 = 0;
            while (cx < cells_x) : (cx += 1) {
                var tri: u32 = 0;
                while (tri < 2) : (tri += 1) {
                    const v: [3]Vec = hfTriVerts(out_heights, sample_count_x, cell_size, cx, cz, tri);
                    const this_index: usize = hfTriIndex(cells_x, cx, cz, tri);
                    const n_this: Vec = tri_normals[this_index];
                    var mask: u8 = 0;
                    var e: u32 = 0;
                    while (e < 3) : (e += 1) {
                        if (hfNeighbourTri(cells_x, cells_z, cx, cz, tri, e)) |nb| {
                            const n_other: Vec = tri_normals[hfTriIndex(cells_x, nb.cx, nb.cz, nb.tri)];
                            const v_far: Vec = v[(e + 2) % 3];
                            const edge_point: Vec = v[e];
                            const convex: bool = dot3(n_other, v_far - edge_point) < 0.0;
                            const cos_angle: f32 = dot3(n_other, n_this);
                            if (convex and cos_angle < mesh_active_edge_cos) {
                                mask |= hfEdgeBit(e);
                            }
                        } else {
                            mask |= hfEdgeBit(e); // boundary edge: always active
                        }
                    }
                    out_active[this_index] = mask;
                }
            }
        }
    }

    var out_materials: []const u16 = &.{};
    if (triangle_materials) |tm| {
        if (tm.len != n_tris) {
            return error.HeightFieldMaterialCountMismatch;
        }
        const m: []u16 = try gpa.alloc(u16, tm.len);
        errdefer gpa.free(m);
        @memcpy(m, tm);
        out_materials = m;
    }

    return .{
        .heights = out_heights,
        .sample_count_x = sample_count_x,
        .sample_count_z = sample_count_z,
        .cell_size = cell_size,
        .bounds = .{ .min = vec(0, min_h, 0), .max = vec(extent_x, max_h, extent_z) },
        .active_edges = out_active,
        .materials = out_materials,
    };
}

/// Shapes are shared and immutable. A flat append-only store is the simplest pool.
pub const ShapeStore = struct {
    items: std.ArrayListUnmanaged(Shape) = .empty,

    pub fn add(self: *ShapeStore, gpa: std.mem.Allocator, shape: Shape) !ShapeId {
        const id: ShapeId = @intCast(self.items.items.len);
        try self.items.append(gpa, shape);
        return id;
    }

    pub fn get(self: *const ShapeStore, id: ShapeId) *const Shape {
        return &self.items.items[id];
    }

    /// Build a convex hull from a point cloud and store it. The hull's arrays are
    /// owned by the store and freed in deinit.
    pub fn addConvexHull(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        points: []const Vec,
    ) !ShapeId {
        const hull: ConvexHull = try buildConvexHull(gpa, points);
        return self.add(gpa, .{ .convex_hull = hull });
    }

    /// Combine already-stored leaf shapes into a compound and store it. The child
    /// array is owned by the store and freed in deinit.
    pub fn addCompound(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        children: []const CompoundChild,
    ) !ShapeId {
        // buildCompound takes *const ShapeStore (it reads each child via store.get) and so
        // must follow the ShapeStore type, while this ShapeStore method calls buildCompound
        // to assemble the compound - a ShapeStore<->buildCompound cycle; this call is the
        // irreducible forward edge.
        // lint:off decl-order: ShapeStore<->buildCompound cycle (helper reads the store)
        const comp: Compound = try buildCompound(gpa, self, children);
        return self.add(gpa, .{ .compound = comp });
    }

    /// Wrap an existing shape in a rotation + translation (Jolt's RotatedTranslatedShape). The
    /// child's bounds/COM/mass are read once and cached; the child keeps its own store entry.
    pub fn addRotatedTranslated(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        child: ShapeId,
        rotation: Quat,
        position: Vec,
    ) !ShapeId {
        const cs: *const Shape = self.get(child);
        const child_com: Vec = shapeCenterOfMass(cs);
        const child_bounds: Aabb = shapeLocalBounds(cs);
        const cmp: MassProperties = shapeMass(cs, 1.0); // density 1 => mass == volume
        const rt: RotatedTranslated = .{
            .child = child,
            .rotation = rotation,
            .position = position,
            .com = position + rotate(rotation, child_com),
            .bounds = transformAabb(child_bounds, vec_zero, rotation),
            .inner_radius = shapeInnerRadius(cs),
            .volume = cmp.mass,
            .inertia_diagonal = reciprocal3(cmp.inv_inertia_diagonal),
            // principal frame in the RT shape = rotation ∘ child principal (Jolt rotates the
            // child inertia by `rotation`); Hamilton qmul applies child principal first.
            .inertia_rotation = qmul(rotation, cmp.inertia_rotation),
        };
        return self.add(gpa, .{ .rotated_translated = rt });
    }

    /// Wrap an existing shape with a shifted center of mass (Jolt's OffsetCenterOfMassShape).
    pub fn addOffsetCom(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        child: ShapeId,
        offset: Vec,
    ) !ShapeId {
        const cs: *const Shape = self.get(child);
        const child_com: Vec = shapeCenterOfMass(cs);
        const child_bounds: Aabb = shapeLocalBounds(cs);
        const cmp: MassProperties = shapeMass(cs, 1.0);
        const oc: OffsetCom = .{
            .child = child,
            .offset = offset,
            .com = child_com + offset,
            .bounds = .{ .min = child_bounds.min - offset, .max = child_bounds.max - offset },
            .inner_radius = shapeInnerRadius(cs),
            .volume = cmp.mass,
            .inertia_diagonal = reciprocal3(cmp.inv_inertia_diagonal),
            .inertia_rotation = cmp.inertia_rotation,
        };
        return self.add(gpa, .{ .offset_com = oc });
    }

    /// A collision-less placeholder shape with a configurable center of mass (Jolt's EmptyShape).
    pub fn addEmpty(self: *ShapeStore, gpa: std.mem.Allocator, com: Vec) !ShapeId {
        return self.add(gpa, .{ .empty = .{ .com = com } });
    }

    /// An infinite static plane half-space (Jolt's PlaneShape): the plane is `dot(normal, x) +
    /// distance = 0` and the solid side is `-normal`. `half_extent` sizes the finite cached bounds
    /// used by the broadphase (the plane behaves like a large slab of that reach). Intended for
    /// static bodies (cheap ground).
    pub fn addPlane(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        normal: Vec,
        distance: f32,
        half_extent: f32,
    ) !ShapeId {
        const unit_n: Vec = safeNormalize3(normal, vec(0, 1, 0));
        const center: Vec = unit_n * splat(-distance); // closest point on the plane to the origin
        // An orthonormal basis spanning the plane.
        const ref: Vec = if (@abs(unit_n[1]) < 0.99) vec(0, 1, 0) else vec(1, 0, 0);
        const perp1: Vec = safeNormalize3(cross(ref, unit_n), vec(1, 0, 0));
        const perp2: Vec = cross(unit_n, perp1);
        var lo: Vec = center;
        var hi: Vec = center;
        const corner_signs = [_][2]f32{ .{ 1, 1 }, .{ 1, -1 }, .{ -1, -1 }, .{ -1, 1 } };
        for (corner_signs) |sg| {
            const offset_u: Vec = perp1 * splat(sg[0] * half_extent);
            const offset_v: Vec = perp2 * splat(sg[1] * half_extent);
            const corner: Vec = center + offset_u + offset_v;
            const corner_below: Vec = corner - unit_n * splat(half_extent); // into the solid side
            lo = @min(lo, @min(corner, corner_below));
            hi = @max(hi, @max(corner, corner_below));
        }
        const pl: PlaneShape = .{
            .normal = unit_n,
            .distance = distance,
            .half_extent = half_extent,
            .bounds = .{ .min = lo, .max = hi },
        };
        return self.add(gpa, .{ .plane = pl });
    }

    /// Build a triangle mesh (vertices + index triples) and store it. The mesh's arrays
    /// are owned by the store and freed in deinit.
    pub fn addMesh(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        vertices: []const Vec,
        triangles: []const [3]u32,
    ) !ShapeId {
        return self.addMeshWithMaterials(gpa, vertices, triangles, null);
    }

    /// As addMesh, but tags each triangle with an opaque surface id (one per triangle, or null
    /// for a single-surface mesh). Retrieve it at a contact via World.materialAt.
    pub fn addMeshWithMaterials(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        vertices: []const Vec,
        triangles: []const [3]u32,
        triangle_materials: ?[]const u16,
    ) !ShapeId {
        const mesh: Mesh = try buildMeshWithMaterials(gpa, vertices, triangles, triangle_materials);
        return self.add(gpa, .{ .mesh = mesh });
    }

    /// Build a height field (row-major heights, grid dimensions, cell spacing) and
    /// store it. The height array is owned by the store and freed in deinit.
    pub fn addHeightField(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        heights: []const f32,
        sample_count_x: u32,
        sample_count_z: u32,
        cell_size: f32,
    ) !ShapeId {
        return self.addHeightFieldWithMaterials(
            gpa,
            heights,
            sample_count_x,
            sample_count_z,
            cell_size,
            null,
        );
    }

    /// As addHeightField, but tags each cell-triangle with an opaque surface id (one per
    /// cell-triangle, or null for a single-surface field). Retrieve it via World.materialAt.
    pub fn addHeightFieldWithMaterials(
        self: *ShapeStore,
        gpa: std.mem.Allocator,
        heights: []const f32,
        sample_count_x: u32,
        sample_count_z: u32,
        cell_size: f32,
        triangle_materials: ?[]const u16,
    ) !ShapeId {
        const hf: HeightField = try buildHeightFieldWithMaterials(
            gpa,
            heights,
            sample_count_x,
            sample_count_z,
            cell_size,
            triangle_materials,
        );
        return self.add(gpa, .{ .heightfield = hf });
    }

    pub fn deinit(self: *ShapeStore, gpa: std.mem.Allocator) void {
        for (self.items.items) |shape| {
            switch (shape) {
                .convex_hull => |h| {
                    gpa.free(h.points);
                    gpa.free(h.faces);
                    gpa.free(h.face_vertices);
                },
                .compound => |c| gpa.free(c.children),
                .mesh => |m| {
                    gpa.free(m.vertices);
                    gpa.free(m.triangles);
                    gpa.free(m.nodes);
                    gpa.free(m.tri_order);
                    if (m.materials.len > 0) {
                        gpa.free(m.materials);
                    }
                },
                .heightfield => |hf| {
                    gpa.free(hf.heights);
                    gpa.free(hf.active_edges);
                    if (hf.materials.len > 0) {
                        gpa.free(hf.materials);
                    }
                },
                else => {},
            }
        }
        self.items.deinit(gpa);
    }
};

/// Combine several posed leaf shapes into one compound: total volume, centre of mass,
/// and principal inertia (per unit density) via the parallel axis theorem, then
/// recentre the children on the COM. `store` must already hold the child shapes.
pub fn buildCompound(
    gpa: std.mem.Allocator,
    store: *const ShapeStore,
    children_in: []const CompoundChild,
) !Compound {
    if (children_in.len == 0) {
        return error.EmptyCompound;
    }

    // 1) Total volume and centre of mass (each leaf's COM is at its own local origin,
    //    so the child COM in the compound frame is just local_pos).
    var total_volume: f32 = 0.0;
    var weighted_com: Vec = vec_zero;
    for (children_in) |child| {
        const props: MassProperties = shapeMass(store.get(child.shape), 1.0); // unit density: mass = volume
        total_volume += props.mass;
        weighted_com += splat(props.mass) * child.local_pos;
    }
    if (total_volume < 1.0e-9) {
        return error.DegenerateCompound;
    }
    const com: Vec = weighted_com / splat(total_volume);

    // 2) Inertia about the compound COM (per unit density). For each child, rotate its
    //    principal moments into the compound frame, then shift to the compound COM:
    //    I = sum_k I_k (r_k r_k^T)  +  m (|d|^2 E - d d^T),   d = child COM - compound COM.
    var inertia: Mat3 = Mat3.zero;
    for (children_in) |child| {
        const props: MassProperties = shapeMass(store.get(child.shape), 1.0);
        const moment: Vec = reciprocal3(props.inv_inertia_diagonal);
        const q: Quat = qmul(child.local_rot, props.inertia_rotation); // principal axes in compound frame
        const rx: Vec = rotate(q, vec(1, 0, 0));
        const ry: Vec = rotate(q, vec(0, 1, 0));
        const rz: Vec = rotate(q, vec(0, 0, 1));
        var child_inertia: Mat3 = mat3Outer(rx, rx).scale(moment[0])
            .add(mat3Outer(ry, ry).scale(moment[1]))
            .add(mat3Outer(rz, rz).scale(moment[2]));
        const d: Vec = child.local_pos - com;
        const shift: Mat3 = Mat3.diagonal(dot3(d, d)).add(mat3Outer(d, d).scale(-1.0));
        child_inertia = child_inertia.add(shift.scale(props.mass));
        inertia = inertia.add(child_inertia);
    }
    const eigen: EigenResult = jacobiEigenSymmetric3(inertia);

    // 3) Recentre children on the COM; compute the enclosing AABB and a conservative
    //    inner radius (largest sphere about the COM that fits inside SOME child).
    const out_children: []CompoundChild = try gpa.alloc(CompoundChild, children_in.len);
    errdefer gpa.free(out_children);
    var box: Aabb = .empty;
    var inner_radius: f32 = 0.0;
    for (children_in, 0..) |child, idx| {
        const child_shape: *const Shape = store.get(child.shape);
        const new_pos: Vec = child.local_pos - com;
        out_children[idx] = .{ .shape = child.shape, .local_pos = new_pos, .local_rot = child.local_rot };
        const child_bounds: Aabb = transformAabb(shapeLocalBounds(child_shape), new_pos, child.local_rot);
        box.encapsulate(child_bounds.min);
        box.encapsulate(child_bounds.max);
        const candidate: f32 = shapeInnerRadius(child_shape) - length3(new_pos);
        if (candidate > inner_radius) {
            inner_radius = candidate;
        }
    }

    return .{
        .children = out_children,
        .bounds = box,
        .inner_radius = inner_radius,
        .volume = total_volume,
        .inertia_diagonal = eigen.values,
        .inertia_rotation = eigen.rotation,
    };
}

// =============================================================================
// Convex hull builder. Given a point cloud, enumerate the supporting planes (each
// a hull face), merge the coplanar points into CCW polygons, and compute the volume,
// centre of mass and principal inertia (the whole hull is then recentred on its COM
// so support points are COM-relative, matching the primitive shapes). Plane
// enumeration is O(n^4) - meant for the small clouds typical of physics hulls.
// =============================================================================

// =============================================================================
// Mesh builder + BVH. A triangle soup gets per-triangle face normals and a static
// median-split bounding-volume hierarchy, so a colliding convex shape only tests the
// triangles near it. Build once; query with the convex shape's AABB transformed into
// mesh-local space (see collideShapes).
// =============================================================================

/// Append the indices of every mesh triangle whose AABB overlaps `local_aabb` (both in
/// mesh-local space).
fn queryMeshBvh(
    mesh: *const Mesh,
    local_aabb: Aabb,
    out: *std.ArrayListUnmanaged(u32),
    scratch: std.mem.Allocator,
) !void {
    if (mesh.nodes.len == 0) {
        return;
    }
    var stack: BvhStack = .{};
    stack.push(0);
    while (stack.pop()) |ni| {
        const node: MeshBvhNode = mesh.nodes[ni];
        if (!node.bounds.overlaps(local_aabb)) {
            continue;
        }
        if (node.tri_count != 0) {
            var i: u32 = 0;
            while (i < node.tri_count) : (i += 1) {
                try out.append(scratch, mesh.tri_order[node.first_tri + i]);
            }
        } else {
            stack.push(node.left);
            stack.push(node.right);
        }
    }
}

// =============================================================================
// Height field builder. A regular grid of heights; the local vertex of sample
// (gx, gz) is (gx*cell, height, gz*cell). Each cell is two triangles, found directly
// from a colliding shape's bounds (see collideShapes) - no BVH.
// =============================================================================

/// Local-space position of grid sample (gx, gz).
fn hfVertex(hf: *const HeightField, gx: u32, gz: u32) Vec {
    const h: f32 = hf.heights[gz * hf.sample_count_x + gx];
    return vec(float(gx) * hf.cell_size, h, float(gz) * hf.cell_size);
}

pub fn buildHeightField(
    gpa: std.mem.Allocator,
    heights_in: []const f32,
    sample_count_x: u32,
    sample_count_z: u32,
    cell_size: f32,
) !HeightField {
    return buildHeightFieldWithMaterials(gpa, heights_in, sample_count_x, sample_count_z, cell_size, null);
}

// =============================================================================
// Body (primary component) and Motion (moving state).
// =============================================================================

/// Which world-space degrees of freedom a dynamic body may use. Defaults to all six.
/// Locking is enforced by zeroing the corresponding velocity components each step
/// (see Motion.lin_lock / ang_lock), so locked axes never accumulate motion. The
/// solver still computes effective masses with the full inverse inertia, so contacts
/// pushing along a locked axis are slightly less accurate than Jolt's masked solver —
/// fine for the usual uses (2D-plane bodies, no-tip-over capsules).
pub const AllowedDofs = packed struct {
    translation_x: bool = true,
    translation_y: bool = true,
    translation_z: bool = true,
    rotation_x: bool = true,
    rotation_y: bool = true,
    rotation_z: bool = true,

    /// All six free (the default).
    pub const all: AllowedDofs = .{};
    /// Motion confined to the world XY plane (translate X/Y, rotate about Z).
    pub const plane_2d: AllowedDofs = .{ .translation_z = false, .rotation_x = false, .rotation_y = false };
    /// Translate freely but never rotate (e.g. an upright capsule).
    pub const no_rotation: AllowedDofs = .{ .rotation_x = false, .rotation_y = false, .rotation_z = false };

    pub fn linMask(d: AllowedDofs) Vec {
        return vec(
            if (d.translation_x) 1.0 else 0.0,
            if (d.translation_y) 1.0 else 0.0,
            if (d.translation_z) 1.0 else 0.0,
        );
    }
    pub fn angMask(d: AllowedDofs) Vec {
        return vec(
            if (d.rotation_x) 1.0 else 0.0,
            if (d.rotation_y) 1.0 else 0.0,
            if (d.rotation_z) 1.0 else 0.0,
        );
    }
};

// =============================================================================
// Joints / constraints. Each joint is composed from the reusable constraint parts
// above and solved in the same velocity/position sweeps as contacts. The accumulated
// impulses live in the Constraint itself, so warm starting needs no extra cache.
// =============================================================================

pub const ConstraintKind = enum {
    point,
    fixed,
    distance,
    hinge,
    slider,
    swing_twist,
    gear,
    rack_and_pinion,
    pulley,
};

/// How the swing (cone) limit of a swing-twist (ragdoll) joint is shaped. Cone gives an
/// elliptic cone symmetric about the twist axis; Pyramid gives independent min/max limits
/// about the Y (plane) and Z (normal) axes. Jolt's ESwingType.
pub const SwingType = enum { cone, pyramid };

/// How a hinge or slider motor drives its free axis.
pub const MotorMode = enum {
    off, // free (subject only to limits)
    velocity, // drive toward target_velocity
    position, // servo toward target_position with a spring
};

/// Motor for a hinge (angular) or slider (linear). `max_force` bounds the motor
/// impulse to +-max_force*dt each try step (torque for a hinge, force for a slider).
/// Position motors use a critically-tunable spring (frequency in Hz, damping ratio).
pub const MotorSettings = struct {
    mode: MotorMode = .off,
    target_velocity: f32 = 0.0, // rad/s (hinge) or m/s (slider)
    target_position: f32 = 0.0, // rad (hinge angle) or m (slider offset)
    max_force: f32 = 0.0, // 0 disables the motor; otherwise the per-step impulse clamp magnitude
    frequency: f32 = 2.0, // position-motor spring frequency (Hz)
    damping: f32 = 1.0, // position-motor spring damping ratio
};

/// Motor state for the swing-twist (ragdoll) motors. Mirrors Jolt's EMotorState: a motor
/// can drive to a target velocity, to a target orientation (a spring), to both, or be off
/// (in which case it may still apply bounded friction torque).
pub const MotorState = enum { off, velocity, position, position_and_velocity };

fn isPositionMotor(s: MotorState) bool {
    return s == .position or s == .position_and_velocity;
}

/// Settings for one angular motor of a swing-twist joint (Jolt's MotorSettings, angular
/// form). The position drive uses a spring (frequency in Hz, damping ratio); the per-step
/// torque impulse is clamped to [min_torque, max_torque] * dt (usually symmetric).
pub const AngularMotorSettings = struct {
    frequency: f32 = 2.0, // spring frequency (Hz); 0 disables the position drive
    damping: f32 = 1.0, // spring damping ratio
    min_torque: f32 = -floatMax(f32), // N m
    max_torque: f32 = floatMax(f32),
};

/// Per-step engagement + impulse clamp for a 1-DOF limit (hinge angle, slider offset).
const LimitRuntime = struct {
    active: bool = false,
    c: f32 = 0.0, // signed error fed to the position pass
    lo: f32 = 0.0, // velocity-impulse clamp lo/hi
    hi: f32 = 0.0,
};

/// Per-step engagement + impulse clamp for a 1-DOF motor.
const MotorRuntime = struct {
    active: bool = false,
    lo: f32 = 0.0,
    hi: f32 = 0.0,
};

/// 3-DOF point/ball constraint (Jolt's PointConstraintPart): keeps two anchor
/// points coincident. The effective mass is the 3x3
///   K^-1 = ( r1x I1^-1 r1x^T + r2x I2^-1 r2x^T + (m1^-1 + m2^-1) E )^-1
/// where r1x = skew(r1). Inverse inertias are the world-space ones baked per step.
pub const PointPart = struct {
    r1: Vec, // world arm: comA -> anchor
    r2: Vec, // world arm: comB -> anchor
    inv_i1_r1x: Mat3, // I1^-1 * skew(r1)
    inv_i2_r2x: Mat3, // I2^-1 * skew(r2)
    effective_mass: Mat3, // K^-1
    total_lambda: Vec, // accumulated impulse (persists across frames for warm start)
    active: bool,

    pub const inactive: PointPart = .{
        .r1 = vec_zero,
        .r2 = vec_zero,
        .inv_i1_r1x = Mat3.zero,
        .inv_i2_r2x = Mat3.zero,
        .effective_mass = Mat3.zero,
        .total_lambda = vec_zero,
        .active = false,
    };

    pub fn prepare(
        part: *PointPart,
        ma: *const Motion,
        inv_i_a: Mat3,
        r1: Vec,
        mb: *const Motion,
        inv_i_b: Mat3,
        r2: Vec,
    ) void {
        part.r1 = r1;
        part.r2 = r2;
        const r1x: Mat3 = Mat3.skew(r1);
        const r2x: Mat3 = Mat3.skew(r2);
        part.inv_i1_r1x = inv_i_a.mul(r1x);
        part.inv_i2_r2x = inv_i_b.mul(r2x);
        const term_a: Mat3 = r1x.mul(inv_i_a).mul(r1x.transpose());
        const term_b: Mat3 = r2x.mul(inv_i_b).mul(r2x.transpose());
        const inv_eff: Mat3 = term_a.add(term_b).add(Mat3.diagonal(ma.inv_mass + mb.inv_mass));
        if (Mat3.inverse(inv_eff)) |em| {
            part.effective_mass = em;
            part.active = true;
        } else {
            part.effective_mass = Mat3.zero;
            part.active = false;
        }
    }

    pub fn applyImpulse(
        part: *const PointPart,
        ma: *Motion,
        mb: *Motion,
        lambda: Vec,
    ) void {
        ma.lin_vel -= splat(ma.inv_mass) * lambda;
        ma.ang_vel -= part.inv_i1_r1x.mulVec(lambda);
        mb.lin_vel += splat(mb.inv_mass) * lambda;
        mb.ang_vel += part.inv_i2_r2x.mulVec(lambda);
    }

    pub fn warmStart(
        part: *PointPart,
        ma: *Motion,
        mb: *Motion,
        impulse_ratio: f32,
    ) void {
        part.total_lambda *= splat(impulse_ratio);
        part.applyImpulse(ma, mb, part.total_lambda);
    }

    pub fn solveVelocity(part: *PointPart, ma: *Motion, mb: *Motion) void {
        // Relative velocity at the anchor, in Jolt's sign convention.
        const point_vel_a: Vec = ma.lin_vel - cross(part.r1, ma.ang_vel);
        const point_vel_b: Vec = mb.lin_vel - cross(part.r2, mb.ang_vel);
        const rel: Vec = point_vel_a - point_vel_b;
        const lambda: Vec = part.effective_mass.mulVec(rel);
        part.total_lambda += lambda;
        part.applyImpulse(ma, mb, lambda);
    }

    pub fn solvePosition(
        part: *const PointPart,
        body_a: *Body,
        ma: *const Motion,
        body_b: *Body,
        mb: *const Motion,
        baumgarte: f32,
    ) void {
        const separation: Vec = (body_b.com_pos - body_a.com_pos) + part.r2 - part.r1;
        const lambda: Vec = part.effective_mass.mulVec(splat(-baumgarte) * separation);
        body_a.com_pos -= splat(ma.inv_mass) * lambda;
        integrateRotation(&body_a.rot, vec_zero - part.inv_i1_r1x.mulVec(lambda));
        body_b.com_pos += splat(mb.inv_mass) * lambda;
        integrateRotation(&body_b.rot, part.inv_i2_r2x.mulVec(lambda));
    }
};

/// 3-DOF rotation lock (Jolt's RotationEulerConstraintPart): pins the relative
/// orientation of two bodies (used by the fixed/weld joint). Effective mass is
/// (I1^-1 + I2^-1)^-1; the position error is read off the relative quaternion.
pub const RotationLockPart = struct {
    inv_i1: Mat3,
    inv_i2: Mat3,
    effective_mass: Mat3, // (I1^-1 + I2^-1)^-1
    total_lambda: Vec,
    active: bool,

    pub const inactive: RotationLockPart = .{
        .inv_i1 = Mat3.zero,
        .inv_i2 = Mat3.zero,
        .effective_mass = Mat3.zero,
        .total_lambda = vec_zero,
        .active = false,
    };

    pub fn prepare(part: *RotationLockPart, inv_i_a: Mat3, inv_i_b: Mat3) void {
        part.inv_i1 = inv_i_a;
        part.inv_i2 = inv_i_b;
        if (Mat3.inverse(inv_i_a.add(inv_i_b))) |em| {
            part.effective_mass = em;
            part.active = true;
        } else {
            part.effective_mass = Mat3.zero;
            part.active = false;
        }
    }

    pub fn applyImpulse(
        part: *const RotationLockPart,
        ma: *Motion,
        mb: *Motion,
        lambda: Vec,
    ) void {
        ma.ang_vel -= part.inv_i1.mulVec(lambda);
        mb.ang_vel += part.inv_i2.mulVec(lambda);
    }

    pub fn warmStart(
        part: *RotationLockPart,
        ma: *Motion,
        mb: *Motion,
        impulse_ratio: f32,
    ) void {
        part.total_lambda *= splat(impulse_ratio);
        part.applyImpulse(ma, mb, part.total_lambda);
    }

    pub fn solveVelocity(part: *RotationLockPart, ma: *Motion, mb: *Motion) void {
        const rel: Vec = ma.ang_vel - mb.ang_vel;
        const lambda: Vec = part.effective_mass.mulVec(rel);
        part.total_lambda += lambda;
        part.applyImpulse(ma, mb, lambda);
    }

    /// inv_initial is conj(rotB0) * rotA0, captured at creation so the error is zero
    /// at the rest pose. diff = rotB * inv_initial * conj(rotA); error = 2 * diff.xyz.
    pub fn solvePosition(
        part: *const RotationLockPart,
        body_a: *Body,
        body_b: *Body,
        inv_initial: Quat,
        baumgarte: f32,
    ) void {
        var diff: Quat = qmul(conjugate(body_a.rot), qmul(inv_initial, body_b.rot));
        if (diff[3] < 0.0) {
            diff = vec_zero - diff;
        } // ensure w >= 0 (shortest arc)
        const err: Vec = splat(2.0) * vec(diff[0], diff[1], diff[2]);
        const lambda: Vec = part.effective_mass.mulVec(splat(-baumgarte) * err);
        integrateRotation(&body_a.rot, vec_zero - part.inv_i1.mulVec(lambda));
        integrateRotation(&body_b.rot, part.inv_i2.mulVec(lambda));
    }
};

/// 2-DOF angular constraint that locks the two axes perpendicular to a hinge axis,
/// leaving rotation about the hinge free (Jolt's HingeRotationConstraintPart). The
/// constraint is C = [a1.b2, a1.c2] where a1 is the hinge axis on body 1 and (b2, c2)
/// span the plane perpendicular to the hinge axis on body 2; both must stay zero.
pub const HingeRotationPart = struct {
    a1: Vec, // hinge axis on body 1 (world)
    b2: Vec, // perpendicular reference axes on body 2 (world)
    c2: Vec,
    b2xa1: Vec, // b2 x a1   (the two Jacobian rows, shared by both bodies)
    c2xa1: Vec, // c2 x a1
    inv_i1: Mat3,
    inv_i2: Mat3,
    effective_mass: Mat2, // 2x2 K^-1
    total_lambda: [2]f32,
    active: bool,

    pub const inactive: HingeRotationPart = .{
        .a1 = vec_zero,
        .b2 = vec_zero,
        .c2 = vec_zero,
        .b2xa1 = vec_zero,
        .c2xa1 = vec_zero,
        .inv_i1 = Mat3.zero,
        .inv_i2 = Mat3.zero,
        .effective_mass = Mat2.zero,
        .total_lambda = .{ 0.0, 0.0 },
        .active = false,
    };

    pub fn prepare(
        part: *HingeRotationPart,
        inv_i_a: Mat3,
        hinge_axis_a: Vec,
        inv_i_b: Mat3,
        hinge_axis_b: Vec,
    ) void {
        part.a1 = hinge_axis_a;
        var a2: Vec = hinge_axis_b;
        // If the two hinge axes have drifted far apart, reproject a2 so the perpendicular
        // frame stays well-defined (mirrors Jolt's robustness guard).
        const dotv: f32 = dot3(part.a1, a2);
        if (dotv <= 1.0e-3) {
            var perp: Vec = a2 - splat(dotv) * part.a1;
            if (lengthSq3(perp) < 1.0e-6) {
                perp = normalizedPerpendicular(part.a1);
            }
            a2 = normalize3(splat(0.99) * normalize3(perp) + splat(0.01) * part.a1);
        }
        part.b2 = normalizedPerpendicular(a2);
        part.c2 = cross(a2, part.b2);
        part.inv_i1 = inv_i_a;
        part.inv_i2 = inv_i_b;
        part.b2xa1 = cross(part.b2, part.a1);
        part.c2xa1 = cross(part.c2, part.a1);

        // inv_effective_mass[i][j] = (axis_i x a1) . (I1^-1 + I2^-1)(axis_j x a1).
        const summed: Mat3 = inv_i_a.add(inv_i_b);
        const s_b: Vec = summed.mulVec(part.b2xa1);
        const s_c: Vec = summed.mulVec(part.c2xa1);
        const inv_eff: Mat2 = .{
            .m00 = dot3(part.b2xa1, s_b),
            .m01 = dot3(part.b2xa1, s_c),
            .m10 = dot3(part.c2xa1, s_b),
            .m11 = dot3(part.c2xa1, s_c),
        };
        if (Mat2.inverse(inv_eff)) |em| {
            part.effective_mass = em;
            part.active = true;
        } else {
            part.effective_mass = Mat2.zero;
            part.active = false;
        }
    }

    fn applyImpulse(
        part: *const HingeRotationPart,
        ma: *Motion,
        mb: *Motion,
        lambda: [2]f32,
    ) void {
        const impulse: Vec = splat(lambda[0]) * part.b2xa1 + splat(lambda[1]) * part.c2xa1;
        ma.ang_vel -= part.inv_i1.mulVec(impulse);
        mb.ang_vel += part.inv_i2.mulVec(impulse);
    }

    pub fn warmStart(
        part: *HingeRotationPart,
        ma: *Motion,
        mb: *Motion,
        impulse_ratio: f32,
    ) void {
        part.total_lambda = .{ part.total_lambda[0] * impulse_ratio, part.total_lambda[1] * impulse_ratio };
        part.applyImpulse(ma, mb, part.total_lambda);
    }

    pub fn solveVelocity(part: *HingeRotationPart, ma: *Motion, mb: *Motion) void {
        const delta_ang: Vec = ma.ang_vel - mb.ang_vel;
        const jv0: f32 = dot3(part.b2xa1, delta_ang);
        const jv1: f32 = dot3(part.c2xa1, delta_ang);
        const lambda: [2]f32 = part.effective_mass.mulVec(jv0, jv1);
        part.total_lambda = .{ part.total_lambda[0] + lambda[0], part.total_lambda[1] + lambda[1] };
        part.applyImpulse(ma, mb, lambda);
    }

    pub fn solvePosition(
        part: *const HingeRotationPart,
        body_a: *Body,
        body_b: *Body,
        baumgarte: f32,
    ) void {
        const c0: f32 = dot3(part.a1, part.b2);
        const c1: f32 = dot3(part.a1, part.c2);
        if (c0 == 0.0 and c1 == 0.0) {
            return;
        }
        const corr: [2]f32 = part.effective_mass.mulVec(c0, c1);
        const lambda0: f32 = -baumgarte * corr[0];
        const lambda1: f32 = -baumgarte * corr[1];
        const impulse: Vec = splat(lambda0) * part.b2xa1 + splat(lambda1) * part.c2xa1;
        integrateRotation(&body_a.rot, vec_zero - part.inv_i1.mulVec(impulse));
        integrateRotation(&body_b.rot, part.inv_i2.mulVec(impulse));
    }
};

/// 2-DOF linear constraint that locks translation along two axes (n1, n2), leaving
/// translation along their common perpendicular free (Jolt's DualAxisConstraintPart).
/// A slider uses it to allow sliding only along its axis. `r1_plus_u` is the body-1
/// arm extended by the current separation so the locked point tracks correctly.
pub const DualAxisPart = struct {
    r1pu_x_n1: Vec, // (r1+u) x n1
    r1pu_x_n2: Vec, // (r1+u) x n2
    r2_x_n1: Vec, // r2 x n1
    r2_x_n2: Vec, // r2 x n2
    inv_i1_r1pu_x_n1: Vec,
    inv_i1_r1pu_x_n2: Vec,
    inv_i2_r2_x_n1: Vec,
    inv_i2_r2_x_n2: Vec,
    effective_mass: Mat2,
    total_lambda: [2]f32,
    active: bool,

    pub const inactive: DualAxisPart = .{
        .r1pu_x_n1 = vec_zero,
        .r1pu_x_n2 = vec_zero,
        .r2_x_n1 = vec_zero,
        .r2_x_n2 = vec_zero,
        .inv_i1_r1pu_x_n1 = vec_zero,
        .inv_i1_r1pu_x_n2 = vec_zero,
        .inv_i2_r2_x_n1 = vec_zero,
        .inv_i2_r2_x_n2 = vec_zero,
        .effective_mass = Mat2.zero,
        .total_lambda = .{ 0.0, 0.0 },
        .active = false,
    };

    pub fn prepare(
        part: *DualAxisPart,
        ma: *const Motion,
        inv_i_a: Mat3,
        r1_plus_u: Vec,
        mb: *const Motion,
        inv_i_b: Mat3,
        r2: Vec,
        n1: Vec,
        n2: Vec,
    ) void {
        part.r1pu_x_n1 = cross(r1_plus_u, n1);
        part.r1pu_x_n2 = cross(r1_plus_u, n2);
        part.r2_x_n1 = cross(r2, n1);
        part.r2_x_n2 = cross(r2, n2);
        part.inv_i1_r1pu_x_n1 = inv_i_a.mulVec(part.r1pu_x_n1);
        part.inv_i1_r1pu_x_n2 = inv_i_a.mulVec(part.r1pu_x_n2);
        part.inv_i2_r2_x_n1 = inv_i_b.mulVec(part.r2_x_n1);
        part.inv_i2_r2_x_n2 = inv_i_b.mulVec(part.r2_x_n2);

        const inv_mass_sum: f32 = ma.inv_mass + mb.inv_mass;
        const inv_eff: Mat2 = .{
            .m00 = inv_mass_sum +
                dot3(part.r1pu_x_n1, part.inv_i1_r1pu_x_n1) +
                dot3(part.r2_x_n1, part.inv_i2_r2_x_n1),
            .m01 = dot3(part.r1pu_x_n1, part.inv_i1_r1pu_x_n2) +
                dot3(part.r2_x_n1, part.inv_i2_r2_x_n2),
            .m10 = dot3(part.r1pu_x_n2, part.inv_i1_r1pu_x_n1) +
                dot3(part.r2_x_n2, part.inv_i2_r2_x_n1),
            .m11 = inv_mass_sum +
                dot3(part.r1pu_x_n2, part.inv_i1_r1pu_x_n2) +
                dot3(part.r2_x_n2, part.inv_i2_r2_x_n2),
        };
        if (Mat2.inverse(inv_eff)) |em| {
            part.effective_mass = em;
            part.active = true;
        } else {
            part.effective_mass = Mat2.zero;
            part.active = false;
        }
    }

    fn applyImpulse(
        part: *const DualAxisPart,
        ma: *Motion,
        mb: *Motion,
        n1: Vec,
        n2: Vec,
        lambda: [2]f32,
    ) void {
        const impulse: Vec = splat(lambda[0]) * n1 + splat(lambda[1]) * n2;
        ma.lin_vel -= splat(ma.inv_mass) * impulse;
        ma.ang_vel -= splat(lambda[0]) * part.inv_i1_r1pu_x_n1 +
            splat(lambda[1]) * part.inv_i1_r1pu_x_n2;
        mb.lin_vel += splat(mb.inv_mass) * impulse;
        mb.ang_vel += splat(lambda[0]) * part.inv_i2_r2_x_n1 + splat(lambda[1]) * part.inv_i2_r2_x_n2;
    }

    pub fn warmStart(
        part: *DualAxisPart,
        ma: *Motion,
        mb: *Motion,
        n1: Vec,
        n2: Vec,
        impulse_ratio: f32,
    ) void {
        part.total_lambda = .{ part.total_lambda[0] * impulse_ratio, part.total_lambda[1] * impulse_ratio };
        part.applyImpulse(ma, mb, n1, n2, part.total_lambda);
    }

    pub fn solveVelocity(
        part: *DualAxisPart,
        ma: *Motion,
        mb: *Motion,
        n1: Vec,
        n2: Vec,
    ) void {
        const delta_lin: Vec = ma.lin_vel - mb.lin_vel;
        const jv0: f32 = dot3(n1, delta_lin) +
            dot3(part.r1pu_x_n1, ma.ang_vel) -
            dot3(part.r2_x_n1, mb.ang_vel);
        const jv1: f32 = dot3(n2, delta_lin) +
            dot3(part.r1pu_x_n2, ma.ang_vel) -
            dot3(part.r2_x_n2, mb.ang_vel);
        const lambda: [2]f32 = part.effective_mass.mulVec(jv0, jv1);
        part.total_lambda = .{ part.total_lambda[0] + lambda[0], part.total_lambda[1] + lambda[1] };
        part.applyImpulse(ma, mb, n1, n2, lambda);
    }

    /// `u` is the current separation (p2 - p1); the locked errors are u.n1 and u.n2.
    pub fn solvePosition(
        part: *const DualAxisPart,
        body_a: *Body,
        ma: *const Motion,
        body_b: *Body,
        mb: *const Motion,
        u: Vec,
        n1: Vec,
        n2: Vec,
        baumgarte: f32,
    ) void {
        const c0: f32 = dot3(u, n1);
        const c1: f32 = dot3(u, n2);
        if (c0 == 0.0 and c1 == 0.0) {
            return;
        }
        const corr: [2]f32 = part.effective_mass.mulVec(c0, c1);
        const lambda0: f32 = -baumgarte * corr[0];
        const lambda1: f32 = -baumgarte * corr[1];
        const impulse: Vec = splat(lambda0) * n1 + splat(lambda1) * n2;
        body_a.com_pos -= splat(ma.inv_mass) * impulse;
        const ang_delta_a: Vec = splat(lambda0) * part.inv_i1_r1pu_x_n1 +
            splat(lambda1) * part.inv_i1_r1pu_x_n2;
        integrateRotation(&body_a.rot, vec_zero - ang_delta_a);
        body_b.com_pos += splat(mb.inv_mass) * impulse;
        const ang_delta_b: Vec = splat(lambda0) * part.inv_i2_r2_x_n1 +
            splat(lambda1) * part.inv_i2_r2_x_n2;
        integrateRotation(&body_b.rot, ang_delta_b);
    }
};

/// 1-DOF gear coupling between two bodies' rotations about their (world) hinge axes
/// (Jolt's GearConstraintPart). Constraint C = θ1 + r·θ2; velocity form w1·a + r·w2·b = 0,
/// Jacobian J = [a, r·b]. The impulse is applied to both bodies as +λ·(I⁻¹·axis) (Jolt applies
/// no extra ratio in the body-2 step; the ratio lives in the effective mass and the velocity
/// error, matched verbatim).
pub const GearConstraintPart = struct {
    inv_i_a: Vec = vec_zero, // I1⁻¹·a
    inv_i_b: Vec = vec_zero, // I2⁻¹·b
    effective_mass: f32 = 0.0,
    ratio: f32 = 0.0,
    total_lambda: f32 = 0.0,

    pub const inactive: GearConstraintPart = .{};

    pub fn isActive(part: *const GearConstraintPart) bool {
        return part.effective_mass != 0.0;
    }

    pub fn deactivate(part: *GearConstraintPart) void {
        part.effective_mass = 0.0;
        part.total_lambda = 0.0;
    }

    /// inv_i_a_mat/inv_i_b_mat are the bodies' world inverse-inertia tensors; axis_a/axis_b the
    /// world hinge axes (normalized). K⁻¹ = 1/(a·I1⁻¹·a + r²·b·I2⁻¹·b).
    pub fn prepare(
        part: *GearConstraintPart,
        inv_i_a_mat: Mat3,
        axis_a: Vec,
        inv_i_b_mat: Mat3,
        axis_b: Vec,
        ratio: f32,
    ) void {
        part.inv_i_a = inv_i_a_mat.mulVec(axis_a);
        part.inv_i_b = inv_i_b_mat.mulVec(axis_b);
        part.ratio = ratio;
        const inv_eff: f32 = dot3(axis_a, part.inv_i_a) + dot3(axis_b, part.inv_i_b) * ratio * ratio;
        if (inv_eff == 0.0) {
            part.deactivate();
        } else {
            part.effective_mass = 1.0 / inv_eff;
        }
    }

    fn applyVelocityStep(
        part: *const GearConstraintPart,
        ma: *Motion,
        mb: *Motion,
        lambda: f32,
    ) void {
        if (lambda != 0.0) {
            ma.ang_vel += part.inv_i_a * splat(lambda);
            mb.ang_vel += part.inv_i_b * splat(part.ratio * lambda);
        }
    }

    pub fn warmStart(
        part: *GearConstraintPart,
        ma: *Motion,
        mb: *Motion,
        impulse_ratio: f32,
    ) void {
        part.total_lambda *= impulse_ratio;
        part.applyVelocityStep(ma, mb, part.total_lambda);
    }

    pub fn solveVelocity(
        part: *GearConstraintPart,
        ma: *Motion,
        mb: *Motion,
        axis_a: Vec,
        axis_b: Vec,
        ratio: f32,
    ) void {
        const jv: f32 = dot3(axis_a, ma.ang_vel) + ratio * dot3(axis_b, mb.ang_vel);
        const lambda: f32 = -part.effective_mass * jv;
        part.total_lambda += lambda;
        part.applyVelocityStep(ma, mb, lambda);
    }

    /// Drift correction; `c` is the gear angle error. Rotates both dynamic bodies by ±λ·(I⁻¹·axis).
    pub fn solvePosition(
        part: *const GearConstraintPart,
        body_a: *Body,
        body_b: *Body,
        c: f32,
        baumgarte: f32,
    ) void {
        if (c == 0.0) {
            return;
        }
        const lambda: f32 = -part.effective_mass * baumgarte * c;
        if (body_a.motion_type == .dynamic) {
            integrateRotation(&body_a.rot, part.inv_i_a * splat(lambda));
        }
        if (body_b.motion_type == .dynamic) {
            integrateRotation(&body_b.rot, part.inv_i_b * splat(part.ratio * lambda));
        }
    }
};

/// 1-DOF rack-and-pinion coupling (Jolt's RackAndPinionConstraintPart): ties body 1's rotation
/// about its hinge axis to body 2's translation along its slider axis. Velocity form
/// w₁·a − r·b·v₂ = 0, Jacobian J = [a, −r·b]. Impulse adds +λ·(I₁⁻¹·a) to body 1's spin and
/// −λ·(r·invM₂·b) to body 2's linear velocity.
pub const RackAndPinionConstraintPart = struct {
    inv_i_a: Vec = vec_zero, // I1⁻¹·hingeAxis
    ratio_inv_m2_b: Vec = vec_zero, // ratio·invM2·sliderAxis
    effective_mass: f32 = 0.0,
    total_lambda: f32 = 0.0,

    pub const inactive: RackAndPinionConstraintPart = .{};

    pub fn isActive(part: *const RackAndPinionConstraintPart) bool {
        return part.effective_mass != 0.0;
    }

    pub fn deactivate(part: *RackAndPinionConstraintPart) void {
        part.effective_mass = 0.0;
        part.total_lambda = 0.0;
    }

    /// inv_i_a_mat is body 1's world inverse-inertia tensor; inv_m2 body 2's inverse mass;
    /// hinge_axis/slider_axis the world axes. K⁻¹ = 1/(a·I1⁻¹·a + invM2·r²).
    pub fn prepare(
        part: *RackAndPinionConstraintPart,
        inv_i_a_mat: Mat3,
        hinge_axis: Vec,
        inv_m2: f32,
        slider_axis: Vec,
        ratio: f32,
    ) void {
        part.inv_i_a = inv_i_a_mat.mulVec(hinge_axis);
        part.ratio_inv_m2_b = slider_axis * splat(ratio * inv_m2);
        const inv_eff: f32 = dot3(hinge_axis, part.inv_i_a) + inv_m2 * ratio * ratio;
        if (inv_eff == 0.0) {
            part.deactivate();
        } else {
            part.effective_mass = 1.0 / inv_eff;
        }
    }

    fn applyVelocityStep(
        part: *const RackAndPinionConstraintPart,
        ma: *Motion,
        mb: *Motion,
        lambda: f32,
    ) void {
        if (lambda != 0.0) {
            ma.ang_vel += part.inv_i_a * splat(lambda);
            mb.lin_vel -= part.ratio_inv_m2_b * splat(lambda);
        }
    }

    pub fn warmStart(
        part: *RackAndPinionConstraintPart,
        ma: *Motion,
        mb: *Motion,
        impulse_ratio: f32,
    ) void {
        part.total_lambda *= impulse_ratio;
        part.applyVelocityStep(ma, mb, part.total_lambda);
    }

    pub fn solveVelocity(
        part: *RackAndPinionConstraintPart,
        ma: *Motion,
        mb: *Motion,
        hinge_axis: Vec,
        slider_axis: Vec,
        ratio: f32,
    ) void {
        const jv: f32 = ratio * dot3(slider_axis, mb.lin_vel) - dot3(hinge_axis, ma.ang_vel);
        const lambda: f32 = part.effective_mass * jv;
        part.total_lambda += lambda;
        part.applyVelocityStep(ma, mb, lambda);
    }

    /// Drift correction; `c` is the angle error. Rotates body 1 and translates body 2.
    pub fn solvePosition(
        part: *const RackAndPinionConstraintPart,
        body_a: *Body,
        body_b: *Body,
        c: f32,
        baumgarte: f32,
    ) void {
        if (c == 0.0) {
            return;
        }
        const lambda: f32 = -part.effective_mass * baumgarte * c;
        if (body_a.motion_type == .dynamic) {
            integrateRotation(&body_a.rot, part.inv_i_a * splat(lambda));
        }
        if (body_b.motion_type == .dynamic) {
            body_b.com_pos -= part.ratio_inv_m2_b * splat(lambda);
        }
    }
};

/// Couples body 1 moving along world axis n1 to body 2 moving along world axis n2, by a ratio
/// (Jolt's IndependentAxisConstraintPart): C̈ = n1·v1 + (r1×n1)·w1 + r·n2·v2 + r·(r2×n2)·w2.
/// Used by the pulley. The Jacobian geometry (r1×n1, r·r2×n2) is built unconditionally so a
/// kinematic endpoint's motion still enters the velocity error; the inverse mass/inertia terms
/// are zero for non-dynamic bodies, and only dynamic bodies are moved.
pub const IndependentAxisConstraintPart = struct {
    r1xn1: Vec = vec_zero,
    inv_i1_r1xn1: Vec = vec_zero,
    ratio_r2xn2: Vec = vec_zero, // r·(r2×n2)
    inv_i2_ratio_r2xn2: Vec = vec_zero,
    effective_mass: f32 = 0.0,
    total_lambda: f32 = 0.0,

    pub const inactive: IndependentAxisConstraintPart = .{};

    pub fn isActive(part: *const IndependentAxisConstraintPart) bool {
        return part.effective_mass != 0.0;
    }

    pub fn deactivate(part: *IndependentAxisConstraintPart) void {
        part.effective_mass = 0.0;
        part.total_lambda = 0.0;
    }

    pub fn prepare(
        part: *IndependentAxisConstraintPart,
        inv_i1: Mat3,
        inv_m1: f32,
        r1: Vec,
        n1: Vec,
        inv_i2: Mat3,
        inv_m2: f32,
        r2: Vec,
        n2: Vec,
        ratio: f32,
    ) void {
        part.r1xn1 = cross(r1, n1);
        part.inv_i1_r1xn1 = inv_i1.mulVec(part.r1xn1);
        part.ratio_r2xn2 = cross(r2, n2) * splat(ratio);
        part.inv_i2_ratio_r2xn2 = inv_i2.mulVec(part.ratio_r2xn2);
        const inv_eff: f32 = inv_m1 +
            dot3(part.inv_i1_r1xn1, part.r1xn1) +
            ratio * ratio * inv_m2 +
            dot3(part.inv_i2_ratio_r2xn2, part.ratio_r2xn2);
        if (inv_eff == 0.0) {
            part.deactivate();
        } else {
            part.effective_mass = 1.0 / inv_eff;
        }
    }

    fn applyVelocityStep(
        part: *const IndependentAxisConstraintPart,
        ma: *Motion,
        mb: *Motion,
        n1: Vec,
        n2: Vec,
        ratio: f32,
        lambda: f32,
    ) void {
        if (lambda == 0.0) {
            return;
        }
        if (ma.inv_mass != 0.0) {
            ma.lin_vel += n1 * splat(ma.inv_mass * lambda);
            ma.ang_vel += part.inv_i1_r1xn1 * splat(lambda);
        }
        if (mb.inv_mass != 0.0) {
            mb.lin_vel += n2 * splat(ratio * mb.inv_mass * lambda);
            mb.ang_vel += part.inv_i2_ratio_r2xn2 * splat(lambda);
        }
    }

    pub fn warmStart(
        part: *IndependentAxisConstraintPart,
        ma: *Motion,
        mb: *Motion,
        n1: Vec,
        n2: Vec,
        ratio: f32,
        impulse_ratio: f32,
    ) void {
        part.total_lambda *= impulse_ratio;
        part.applyVelocityStep(ma, mb, n1, n2, ratio, part.total_lambda);
    }

    pub fn solveVelocity(
        part: *IndependentAxisConstraintPart,
        ma: *Motion,
        mb: *Motion,
        n1: Vec,
        n2: Vec,
        ratio: f32,
        min_lambda: f32,
        max_lambda: f32,
    ) void {
        const jv: f32 = dot3(n1, ma.lin_vel) + dot3(part.r1xn1, ma.ang_vel) + ratio * dot3(n2, mb.lin_vel) + dot3(
            part.ratio_r2xn2,
            mb.ang_vel,
        );
        const want: f32 = -part.effective_mass * jv;
        const new_lambda: f32 = clamp(part.total_lambda + want, min_lambda, max_lambda);
        const lambda: f32 = new_lambda - part.total_lambda;
        part.total_lambda = new_lambda;
        part.applyVelocityStep(ma, mb, n1, n2, ratio, lambda);
    }

    pub fn solvePosition(
        part: *const IndependentAxisConstraintPart,
        body_a: *Body,
        ma: *const Motion,
        body_b: *Body,
        mb: *const Motion,
        n1: Vec,
        n2: Vec,
        ratio: f32,
        c: f32,
        baumgarte: f32,
    ) void {
        if (c == 0.0) {
            return;
        }
        const lambda: f32 = -part.effective_mass * baumgarte * c;
        if (ma.inv_mass != 0.0) {
            body_a.com_pos += n1 * splat(lambda * ma.inv_mass);
            integrateRotation(&body_a.rot, part.inv_i1_r1xn1 * splat(lambda));
        }
        if (mb.inv_mass != 0.0) {
            body_b.com_pos += n2 * splat(lambda * ratio * mb.inv_mass);
            integrateRotation(&body_b.rot, part.inv_i2_ratio_r2xn2 * splat(lambda));
        }
    }
};

/// Soft-constraint coefficients (Jolt's SpringPart). A soft 1-DOF constraint behaves
/// like a damped spring rather than a rigid stop: the solver still uses an effective
/// mass, but the mass is softened and a bias both pulls toward C = 0 and bleeds the
/// accumulated impulse back out. The velocity solve then reads
///   lambda = effective_mass * (Jv - bias - softness * accumulated_lambda)
/// and the position pass does nothing (a spring corrects entirely through velocity).
///
/// Frequency form (what joints expose): with effective mass m = 1/inv_eff_mass,
///   omega = 2*pi*frequency, stiffness k = m*omega^2, damping_coef = 2*m*zeta*omega.
const SoftConstraint = struct {
    effective_mass: f32,
    bias: f32, // constant part: base_bias + dt*k*softness*C
    softness: f32, // multiplies accumulated impulse; 0 means rigid
};

fn softConstraint(
    dt: f32,
    inv_eff_mass: f32,
    base_bias: f32,
    c: f32,
    frequency: f32,
    damping: f32,
) SoftConstraint {
    if (inv_eff_mass <= 0.0) {
        return .{ .effective_mass = 0.0, .bias = 0.0, .softness = 0.0 };
    }
    if (frequency <= 0.0) {
        // No spring requested: behave as a rigid 1-DOF constraint with a plain bias.
        return .{ .effective_mass = 1.0 / inv_eff_mass, .bias = base_bias, .softness = 0.0 };
    }
    const m: f32 = 1.0 / inv_eff_mass; // effective mass seen along this DOF
    const omega: f32 = 2.0 * pi * frequency;
    const stiffness: f32 = m * omega * omega;
    const damping_coef: f32 = 2.0 * m * damping * omega;
    const softness: f32 = 1.0 / (dt * (damping_coef + dt * stiffness));
    return .{
        .effective_mass = 1.0 / (inv_eff_mass + softness),
        .bias = base_bias + dt * stiffness * softness * c,
        .softness = softness,
    };
}

/// Like softConstraint but with the spring stiffness (k) and damping (c) given directly,
/// rather than derived from a frequency and the part's own effective mass. Jolt's
/// SpringPart::CalculateSpringPropertiesWithStiffnessAndDamping. Used by the vehicle
/// suspension, which computes k and c from a force-point effective mass and the
/// suspension/contact angle.
fn softConstraintSK(
    dt: f32,
    inv_eff_mass: f32,
    base_bias: f32,
    c: f32,
    stiffness: f32,
    damping: f32,
) SoftConstraint {
    if (inv_eff_mass <= 0.0) {
        return .{ .effective_mass = 0.0, .bias = 0.0, .softness = 0.0 };
    }
    if (stiffness <= 0.0 and damping <= 0.0) {
        // No spring: behave as a rigid 1-DOF constraint with a plain bias.
        return .{ .effective_mass = 1.0 / inv_eff_mass, .bias = base_bias, .softness = 0.0 };
    }
    const softness: f32 = 1.0 / (dt * (damping + dt * stiffness));
    return .{
        .effective_mass = 1.0 / (inv_eff_mass + softness),
        .bias = base_bias + dt * stiffness * softness * c,
        .softness = softness,
    };
}

pub const AxisPart = struct {
    r1_cross_axis: Vec, //  r1 x axis
    r2_cross_axis: Vec, //  r2 x axis
    inv_i1_r1_cross_axis: Vec, //  I1^-1 (r1 x axis)
    inv_i2_r2_cross_axis: Vec, //  I2^-1 (r2 x axis)
    effective_mass: f32, //  1 / K (already softened when used as a spring)
    bias: f32, //  constant velocity bias (restitution/speculative/surface, or spring bias)
    softness: f32, //  soft-constraint term; multiplies accumulated impulse in the bias. 0 = rigid.
    total_lambda: f32, //  accumulated impulse (kept across frames for warm start)

    pub const inactive: AxisPart = .{
        .r1_cross_axis = vec_zero,
        .r2_cross_axis = vec_zero,
        .inv_i1_r1_cross_axis = vec_zero,
        .inv_i2_r2_cross_axis = vec_zero,
        .effective_mass = 0.0,
        .bias = 0.0,
        .softness = 0.0,
        .total_lambda = 0.0,
    };

    pub fn isActive(part: *const AxisPart) bool {
        return part.effective_mass != 0.0;
    }

    pub fn deactivate(part: *AxisPart) void {
        part.effective_mass = 0.0;
        part.total_lambda = 0.0;
    }

    /// K = invM1 + invM2 + (r1 x a).I1^-1(r1 x a) + (r2 x a).I2^-1(r2 x a).
    pub fn prepare(
        part: *AxisPart,
        ma: *const Motion,
        inv_i_a: Mat3,
        ra: Vec,
        mb: *const Motion,
        inv_i_b: Mat3,
        rb: Vec,
        axis: Vec,
        bias: f32,
    ) void {
        const ra_x: Vec = cross(ra, axis);
        const rb_x: Vec = cross(rb, axis);
        const inv_i_ra_x: Vec = inv_i_a.mulVec(ra_x);
        const inv_i_rb_x: Vec = inv_i_b.mulVec(rb_x);

        const ang_a: f32 = dot3(ra_x, inv_i_ra_x);
        const ang_b: f32 = dot3(rb_x, inv_i_rb_x);
        const inv_eff_mass: f32 = ma.inv_mass + mb.inv_mass + ang_a + ang_b;

        part.r1_cross_axis = ra_x;
        part.r2_cross_axis = rb_x;
        part.inv_i1_r1_cross_axis = inv_i_ra_x;
        part.inv_i2_r2_cross_axis = inv_i_rb_x;
        part.bias = bias;
        part.softness = 0.0; // rigid
        part.effective_mass = if (inv_eff_mass > 0.0) 1.0 / inv_eff_mass else 0.0;
    }

    /// Same 1-DOF geometry, but driven by a damped spring toward C = 0 (used by a
    /// slider's position motor). `base_bias` is added to the spring bias (pass a
    /// target velocity here as -v_target for a combined position+velocity motor).
    pub fn prepareSpring(
        part: *AxisPart,
        ma: *const Motion,
        inv_i_a: Mat3,
        ra: Vec,
        mb: *const Motion,
        inv_i_b: Mat3,
        rb: Vec,
        axis: Vec,
        base_bias: f32,
        c: f32,
        frequency: f32,
        damping: f32,
        dt: f32,
    ) void {
        const ra_x: Vec = cross(ra, axis);
        const rb_x: Vec = cross(rb, axis);
        part.r1_cross_axis = ra_x;
        part.r2_cross_axis = rb_x;
        part.inv_i1_r1_cross_axis = inv_i_a.mulVec(ra_x);
        part.inv_i2_r2_cross_axis = inv_i_b.mulVec(rb_x);
        const ang_term_a: f32 = dot3(ra_x, part.inv_i1_r1_cross_axis);
        const ang_term_b: f32 = dot3(rb_x, part.inv_i2_r2_cross_axis);
        const inv_eff_mass: f32 = ma.inv_mass + mb.inv_mass + ang_term_a + ang_term_b;
        const soft: SoftConstraint = softConstraint(dt, inv_eff_mass, base_bias, c, frequency, damping);
        part.effective_mass = soft.effective_mass;
        part.bias = soft.bias;
        part.softness = soft.softness;
    }

    /// Spring with the stiffness (k) and damping (c) given directly rather than as a
    /// frequency (Jolt's CalculateConstraintPropertiesWithStiffnessAndDamping). Used by the
    /// vehicle suspension.
    pub fn prepareStiffnessDamping(
        part: *AxisPart,
        ma: *const Motion,
        inv_i_a: Mat3,
        ra: Vec,
        mb: *const Motion,
        inv_i_b: Mat3,
        rb: Vec,
        axis: Vec,
        base_bias: f32,
        c: f32,
        stiffness: f32,
        damping: f32,
        dt: f32,
    ) void {
        const ra_x: Vec = cross(ra, axis);
        const rb_x: Vec = cross(rb, axis);
        part.r1_cross_axis = ra_x;
        part.r2_cross_axis = rb_x;
        part.inv_i1_r1_cross_axis = inv_i_a.mulVec(ra_x);
        part.inv_i2_r2_cross_axis = inv_i_b.mulVec(rb_x);
        const ang_term_a: f32 = dot3(ra_x, part.inv_i1_r1_cross_axis);
        const ang_term_b: f32 = dot3(rb_x, part.inv_i2_r2_cross_axis);
        const inv_eff_mass: f32 = ma.inv_mass + mb.inv_mass + ang_term_a + ang_term_b;
        const soft: SoftConstraint = softConstraintSK(dt, inv_eff_mass, base_bias, c, stiffness, damping);
        part.effective_mass = soft.effective_mass;
        part.bias = soft.bias;
        part.softness = soft.softness;
    }

    pub fn applyImpulse(
        part: *const AxisPart,
        ma: *Motion,
        mb: *Motion,
        axis: Vec,
        lambda: f32,
    ) void {
        ma.lin_vel -= splat(lambda * ma.inv_mass) * axis;
        ma.ang_vel -= splat(lambda) * part.inv_i1_r1_cross_axis;
        mb.lin_vel += splat(lambda * mb.inv_mass) * axis;
        mb.ang_vel += splat(lambda) * part.inv_i2_r2_cross_axis;
    }

    pub fn warmStart(
        part: *AxisPart,
        ma: *Motion,
        mb: *Motion,
        axis: Vec,
        impulse_ratio: f32,
    ) void {
        part.total_lambda *= impulse_ratio;
        part.applyImpulse(ma, mb, axis, part.total_lambda);
    }

    /// The candidate accumulated impulse BEFORE clamping. Split from apply so the
    /// caller can clamp jointly (the coupled friction cone). Jolt's
    /// SolveVelocityConstraintGetTotalLambda.
    pub fn solveGetTotalLambda(
        part: *const AxisPart,
        ma: *const Motion,
        mb: *const Motion,
        axis: Vec,
    ) f32 {
        const rel_lin: Vec = ma.lin_vel - mb.lin_vel;
        const jv_lin: f32 = dot3(axis, rel_lin);
        const jv_ang_a: f32 = dot3(part.r1_cross_axis, ma.ang_vel);
        const jv_ang_b: f32 = dot3(part.r2_cross_axis, mb.ang_vel);
        const jv: f32 = jv_lin + jv_ang_a - jv_ang_b;
        // Effective bias = constant bias + (soft term * accumulated impulse). softness
        // is 0 for rigid constraints, so this is just `jv - bias` in the common case.
        const effective_bias: f32 = part.bias + part.softness * part.total_lambda;
        const lambda: f32 = part.effective_mass * (jv - effective_bias);
        return part.total_lambda + lambda;
    }

    /// Apply an externally-clamped accumulated impulse. Jolt's
    /// SolveVelocityConstraintApplyLambda.
    pub fn solveApplyLambda(
        part: *AxisPart,
        ma: *Motion,
        mb: *Motion,
        axis: Vec,
        total: f32,
    ) void {
        const delta: f32 = total - part.total_lambda;
        part.total_lambda = total;
        part.applyImpulse(ma, mb, axis, delta);
    }

    /// Convenience: one velocity iteration with the accumulated impulse clamped to
    /// [min_lambda, max_lambda] (e.g. [0, inf) for a push-only suspension).
    pub fn solveVelocityClamped(
        part: *AxisPart,
        ma: *Motion,
        mb: *Motion,
        axis: Vec,
        min_lambda: f32,
        max_lambda: f32,
    ) void {
        const total: f32 = clamp(part.solveGetTotalLambda(ma, mb, axis), min_lambda, max_lambda);
        part.solveApplyLambda(ma, mb, axis, total);
    }

    /// Position (Baumgarte) correction. Moves poses, not velocities. c < 0 = penetrating.
    pub fn solvePosition(
        part: *const AxisPart,
        body_a: *Body,
        ma: *const Motion,
        body_b: *Body,
        mb: *const Motion,
        axis: Vec,
        c: f32,
        baumgarte: f32,
    ) void {
        const lambda: f32 = -part.effective_mass * baumgarte * c;
        body_a.com_pos -= splat(lambda * ma.inv_mass) * axis;
        integrateRotation(&body_a.rot, splat(-lambda) * part.inv_i1_r1_cross_axis);
        body_b.com_pos += splat(lambda * mb.inv_mass) * axis;
        integrateRotation(&body_b.rot, splat(lambda) * part.inv_i2_r2_cross_axis);
    }
};

/// 1-DOF angular constraint about a world axis (Jolt's AngleConstraintPart). It is
/// the rotational twin of AxisPart: a hinge uses it for the swing limit (rigid) and
/// for the motor (a velocity bias, or a position spring). Clamping the accumulated
/// impulse to [min_lambda, max_lambda] gives one-sided limits and bounded motor torque.
pub const AngleConstraintPart = struct {
    inv_i1_axis: Vec, // I1^-1 * axis
    inv_i2_axis: Vec, // I2^-1 * axis
    effective_mass: f32,
    bias: f32,
    softness: f32, // 0 = rigid; nonzero for a position-spring motor
    total_lambda: f32,
    active: bool,

    pub const inactive: AngleConstraintPart = .{
        .inv_i1_axis = vec_zero,
        .inv_i2_axis = vec_zero,
        .effective_mass = 0.0,
        .bias = 0.0,
        .softness = 0.0,
        .total_lambda = 0.0,
        .active = false,
    };

    pub fn isActive(part: *const AngleConstraintPart) bool {
        return part.active;
    }

    pub fn deactivate(part: *AngleConstraintPart) void {
        part.active = false;
        part.total_lambda = 0.0;
    }

    fn cacheAxis(
        part: *AngleConstraintPart,
        inv_i_a: Mat3,
        inv_i_b: Mat3,
        axis: Vec,
    ) f32 {
        part.inv_i1_axis = inv_i_a.mulVec(axis);
        part.inv_i2_axis = inv_i_b.mulVec(axis);
        return dot3(axis, part.inv_i1_axis + part.inv_i2_axis); // inverse effective mass
    }

    /// Rigid (hard) form: a plain velocity bias, no spring.
    pub fn prepare(
        part: *AngleConstraintPart,
        inv_i_a: Mat3,
        inv_i_b: Mat3,
        axis: Vec,
        bias: f32,
    ) void {
        const inv_eff_mass: f32 = part.cacheAxis(inv_i_a, inv_i_b, axis);
        part.bias = bias;
        part.softness = 0.0;
        part.effective_mass = if (inv_eff_mass > 0.0) 1.0 / inv_eff_mass else 0.0;
        part.active = inv_eff_mass > 0.0;
    }

    /// Spring form: drive C toward zero with the given frequency/damping (position
    /// motor). `base_bias` adds a velocity target (pass -v_target for position+velocity).
    pub fn prepareSpring(
        part: *AngleConstraintPart,
        inv_i_a: Mat3,
        inv_i_b: Mat3,
        axis: Vec,
        base_bias: f32,
        c: f32,
        frequency: f32,
        damping: f32,
        dt: f32,
    ) void {
        const inv_eff_mass: f32 = part.cacheAxis(inv_i_a, inv_i_b, axis);
        const soft: SoftConstraint = softConstraint(dt, inv_eff_mass, base_bias, c, frequency, damping);
        part.effective_mass = soft.effective_mass;
        part.bias = soft.bias;
        part.softness = soft.softness;
        part.active = inv_eff_mass > 0.0;
    }

    pub fn applyImpulse(
        part: *const AngleConstraintPart,
        ma: *Motion,
        mb: *Motion,
        lambda: f32,
    ) void {
        ma.ang_vel -= splat(lambda) * part.inv_i1_axis;
        mb.ang_vel += splat(lambda) * part.inv_i2_axis;
    }

    pub fn warmStart(
        part: *AngleConstraintPart,
        ma: *Motion,
        mb: *Motion,
        impulse_ratio: f32,
    ) void {
        part.total_lambda *= impulse_ratio;
        part.applyImpulse(ma, mb, part.total_lambda);
    }

    /// One projected-Gauss-Seidel velocity iteration, clamping the accumulated impulse.
    pub fn solveVelocity(
        part: *AngleConstraintPart,
        ma: *Motion,
        mb: *Motion,
        axis: Vec,
        min_lambda: f32,
        max_lambda: f32,
    ) void {
        const jv: f32 = dot3(axis, ma.ang_vel - mb.ang_vel);
        const effective_bias: f32 = part.bias + part.softness * part.total_lambda;
        const lambda: f32 = part.effective_mass * (jv - effective_bias);
        const new_total: f32 = clamp(part.total_lambda + lambda, min_lambda, max_lambda);
        const applied: f32 = new_total - part.total_lambda;
        part.total_lambda = new_total;
        part.applyImpulse(ma, mb, applied);
    }

    /// Position (Baumgarte) correction. Only rigid limits correct here; a spring motor
    /// (softness != 0) does all of its work in the velocity pass.
    pub fn solvePosition(
        part: *const AngleConstraintPart,
        body_a: *Body,
        body_b: *Body,
        axis_inv_i1: Vec,
        axis_inv_i2: Vec,
        c: f32,
        baumgarte: f32,
    ) void {
        if (c == 0.0 or part.softness != 0.0) {
            return;
        }
        const lambda: f32 = -part.effective_mass * baumgarte * c;
        integrateRotation(&body_a.rot, splat(-lambda) * axis_inv_i1);
        integrateRotation(&body_b.rot, splat(lambda) * axis_inv_i2);
    }
};

/// Decide whether a swing/twist value (expressed as sin(angle/2)) is nearer its min or
/// max limit, accounting for the wrap at +/-1 (Jolt's sDistanceToMinShorter).
fn sDistanceToMinShorter(delta_min: f32, delta_max: f32) bool {
    var dmin: f32 = @abs(delta_min);
    if (dmin > 1.0) {
        dmin = 2.0 - dmin;
    }
    var dmax: f32 = @abs(delta_max);
    if (dmax > 1.0) {
        dmax = 2.0 - dmax;
    }
    return dmin < dmax;
}

/// True if (px, py) is inside the axis-aligned ellipse with semi-axes (a, b).
fn ellipseInside(
    a: f32,
    b: f32,
    px: f32,
    py: f32,
) bool {
    const fx: f32 = px / a;
    const fy: f32 = py / b;
    return fx * fx + fy * fy <= 1.0;
}

const EllipsePoint = struct { x: f32, y: f32 };

/// Closest point on the ellipse with semi-axes (a, b) to an outside point (px, py).
/// Newton-Raphson on g(t) = (a px/(t+a^2))^2 + (b py/(t+b^2))^2 - 1 (Jolt's Ellipse).
/// Jolt iterates unbounded; we cap at 32 iterations (it converges in a few) for safety.
fn ellipseClosestPoint(
    a: f32,
    b: f32,
    px: f32,
    py: f32,
) EllipsePoint {
    const a_sq: f32 = a * a;
    const b_sq: f32 = b * b;
    var t: f32 = 0.0;
    var iter: u32 = 0;
    while (iter < 32) : (iter += 1) {
        const t_plus_a_sq: f32 = t + a_sq;
        const t_plus_b_sq: f32 = t + b_sq;
        const fa: f32 = a * px / t_plus_a_sq;
        const fb: f32 = b * py / t_plus_b_sq;
        const gt: f32 = fa * fa + fb * fb - 1.0;
        if (@abs(gt) < 1.0e-6) {
            return .{ .x = a_sq * px / t_plus_a_sq, .y = b_sq * py / t_plus_b_sq };
        }
        const denom_a_cubed: f32 = t_plus_a_sq * t_plus_a_sq * t_plus_a_sq;
        const denom_b_cubed: f32 = t_plus_b_sq * t_plus_b_sq * t_plus_b_sq;
        const gt_accent: f32 = -2.0 * (a_sq * px * px / denom_a_cubed + b_sq * py * py / denom_b_cubed);
        t = t - gt / gt_accent;
    }
    return .{ .x = a_sq * px / (t + a_sq), .y = b_sq * py / (t + b_sq) };
}

/// Swing-twist limit part (Jolt's SwingTwistConstraintPart): decomposes the relative
/// rotation in constraint space into swing (cone/pyramid about Y,Z) and twist (about X),
/// clamps each to its limits, and enforces the clamp with up to three AngleConstraintParts
/// (one per violated axis). The pivot itself is held by a separate PointPart.
pub const SwingTwistPart = struct {
    rotation_flags: u8,
    swing_type: SwingType,
    sin_twist_half_min: f32,
    sin_twist_half_max: f32,
    cos_twist_half_min: f32,
    cos_twist_half_max: f32,
    sin_swing_y_half_min: f32,
    sin_swing_y_half_max: f32,
    sin_swing_z_half_min: f32,
    sin_swing_z_half_max: f32,
    cos_swing_y_half_min: f32,
    cos_swing_y_half_max: f32,
    cos_swing_z_half_min: f32,
    cos_swing_z_half_max: f32,
    swing_y_half_min: f32, // half-angles (radians), used by the pyramid limit
    swing_y_half_max: f32,
    swing_z_half_min: f32,
    swing_z_half_max: f32,
    swing_limit_y_axis: Vec, // world rotation axes for the three limit parts
    swing_limit_z_axis: Vec,
    twist_limit_axis: Vec,
    swing_y: AngleConstraintPart,
    swing_z: AngleConstraintPart,
    twist: AngleConstraintPart,

    // Which axes are locked / free (set by setLimits). u8 bitset.
    const rf_twist_locked: u8 = 1 << 0;
    const rf_swing_y_locked: u8 = 1 << 1;
    const rf_swing_z_locked: u8 = 1 << 2;
    const rf_twist_free: u8 = 1 << 3;
    const rf_swing_y_free: u8 = 1 << 4;
    const rf_swing_z_free: u8 = 1 << 5;
    const rf_swing_yz_free: u8 = rf_swing_y_free | rf_swing_z_free;

    // Which axis was clamped (returned by clampSwingTwist). u32 bitset.
    const ca_twist_min: u32 = 1 << 0;
    const ca_twist_max: u32 = 1 << 1;
    const ca_swing_y_min: u32 = 1 << 2;
    const ca_swing_y_max: u32 = 1 << 3;
    const ca_swing_z_min: u32 = 1 << 4;
    const ca_swing_z_max: u32 = 1 << 5;

    pub const inactive: SwingTwistPart = .{
        .rotation_flags = 0,
        .swing_type = .cone,
        .sin_twist_half_min = 0.0,
        .sin_twist_half_max = 0.0,
        .cos_twist_half_min = 1.0,
        .cos_twist_half_max = 1.0,
        .sin_swing_y_half_min = 0.0,
        .sin_swing_y_half_max = 0.0,
        .sin_swing_z_half_min = 0.0,
        .sin_swing_z_half_max = 0.0,
        .cos_swing_y_half_min = 1.0,
        .cos_swing_y_half_max = 1.0,
        .cos_swing_z_half_min = 1.0,
        .cos_swing_z_half_max = 1.0,
        .swing_y_half_min = 0.0,
        .swing_y_half_max = 0.0,
        .swing_z_half_min = 0.0,
        .swing_z_half_max = 0.0,
        .swing_limit_y_axis = vec_zero,
        .swing_limit_z_axis = vec_zero,
        .twist_limit_axis = vec_zero,
        .swing_y = AngleConstraintPart.inactive,
        .swing_z = AngleConstraintPart.inactive,
        .twist = AngleConstraintPart.inactive,
    };

    /// Set the swing/twist limits. Decides per-axis whether it is locked (range smaller
    /// than ~1 degree), free (range wider than ~359 degrees), or limited, and caches the
    /// sin/cos of the half angles for the runtime clamp. Cheap; called each prepare.
    pub fn deactivate(part: *SwingTwistPart) void {
        part.swing_y.deactivate();
        part.swing_z.deactivate();
        part.twist.deactivate();
    }

    pub fn setLimits(
        part: *SwingTwistPart,
        twist_min: f32,
        twist_max: f32,
        swing_y_min: f32,
        swing_y_max: f32,
        swing_z_min: f32,
        swing_z_max: f32,
    ) void {
        const locked_angle: f32 = radFromDeg(0.5);
        const free_angle: f32 = radFromDeg(179.5);

        part.swing_y_half_min = 0.5 * swing_y_min;
        part.swing_y_half_max = 0.5 * swing_y_max;
        part.swing_z_half_min = 0.5 * swing_z_min;
        part.swing_z_half_max = 0.5 * swing_z_max;

        part.rotation_flags = 0;

        if (twist_min > -locked_angle and twist_max < locked_angle) {
            part.rotation_flags |= rf_twist_locked;
            part.sin_twist_half_min = 0.0;
            part.sin_twist_half_max = 0.0;
            part.cos_twist_half_min = 1.0;
            part.cos_twist_half_max = 1.0;
        } else if (twist_min < -free_angle and twist_max > free_angle) {
            part.rotation_flags |= rf_twist_free;
            part.sin_twist_half_min = -1.0;
            part.sin_twist_half_max = 1.0;
            part.cos_twist_half_min = 0.0;
            part.cos_twist_half_max = 0.0;
        } else {
            part.sin_twist_half_min = @sin(0.5 * twist_min);
            part.sin_twist_half_max = @sin(0.5 * twist_max);
            part.cos_twist_half_min = @cos(0.5 * twist_min);
            part.cos_twist_half_max = @cos(0.5 * twist_max);
        }

        if (swing_y_min > -locked_angle and swing_y_max < locked_angle) {
            part.rotation_flags |= rf_swing_y_locked;
            part.sin_swing_y_half_min = 0.0;
            part.sin_swing_y_half_max = 0.0;
            part.cos_swing_y_half_min = 1.0;
            part.cos_swing_y_half_max = 1.0;
        } else if (swing_y_min < -free_angle and swing_y_max > free_angle) {
            part.rotation_flags |= rf_swing_y_free;
            part.sin_swing_y_half_min = -1.0;
            part.sin_swing_y_half_max = 1.0;
            part.cos_swing_y_half_min = 0.0;
            part.cos_swing_y_half_max = 0.0;
        } else {
            part.sin_swing_y_half_min = @sin(0.5 * swing_y_min);
            part.sin_swing_y_half_max = @sin(0.5 * swing_y_max);
            part.cos_swing_y_half_min = @cos(0.5 * swing_y_min);
            part.cos_swing_y_half_max = @cos(0.5 * swing_y_max);
        }

        if (swing_z_min > -locked_angle and swing_z_max < locked_angle) {
            part.rotation_flags |= rf_swing_z_locked;
            part.sin_swing_z_half_min = 0.0;
            part.sin_swing_z_half_max = 0.0;
            part.cos_swing_z_half_min = 1.0;
            part.cos_swing_z_half_max = 1.0;
        } else if (swing_z_min < -free_angle and swing_z_max > free_angle) {
            part.rotation_flags |= rf_swing_z_free;
            part.sin_swing_z_half_min = -1.0;
            part.sin_swing_z_half_max = 1.0;
            part.cos_swing_z_half_min = 0.0;
            part.cos_swing_z_half_max = 0.0;
        } else {
            part.sin_swing_z_half_min = @sin(0.5 * swing_z_min);
            part.sin_swing_z_half_max = @sin(0.5 * swing_z_max);
            part.cos_swing_z_half_min = @cos(0.5 * swing_z_min);
            part.cos_swing_z_half_max = @cos(0.5 * swing_z_max);
        }
    }

    /// Clamp the swing and twist quaternions (in place) against the limits; returns a
    /// bitset of which axes were clamped. Everything is in constraint space.
    fn clampSwingTwist(part: *const SwingTwistPart, swing: *Quat, twist: *Quat) u32 {
        var clamped_axis: u32 = 0;

        // Ensure w > 0 so the sin(angle/2) comparisons use the shorter arc.
        const negate_swing: bool = swing.*[3] < 0.0;
        if (negate_swing) {
            swing.* = -swing.*;
        }
        const negate_twist: bool = twist.*[3] < 0.0;
        if (negate_twist) {
            twist.* = -twist.*;
        }

        // Clamp twist (rotation around X).
        if ((part.rotation_flags & rf_twist_locked) != 0) {
            if (twist.*[0] != 0.0) {
                clamped_axis |= ca_twist_min | ca_twist_max;
            }
            twist.* = quat_identity;
        } else if ((part.rotation_flags & rf_twist_free) == 0) {
            const delta_min: f32 = part.sin_twist_half_min - twist.*[0];
            const delta_max: f32 = twist.*[0] - part.sin_twist_half_max;
            if (delta_min > 0.0 or delta_max > 0.0) {
                if (sDistanceToMinShorter(delta_min, delta_max)) {
                    twist.* = quat(part.sin_twist_half_min, 0.0, 0.0, part.cos_twist_half_min);
                    clamped_axis |= ca_twist_min;
                } else {
                    twist.* = quat(part.sin_twist_half_max, 0.0, 0.0, part.cos_twist_half_max);
                    clamped_axis |= ca_twist_max;
                }
            }
        }

        // Clamp swing (rotation around Y and Z).
        if ((part.rotation_flags & rf_swing_y_locked) != 0) {
            if ((part.rotation_flags & rf_swing_z_locked) != 0) {
                // No swing DOF.
                if (swing.*[1] != 0.0) {
                    clamped_axis |= ca_swing_y_min | ca_swing_y_max;
                }
                if (swing.*[2] != 0.0) {
                    clamped_axis |= ca_swing_z_min | ca_swing_z_max;
                }
                swing.* = quat_identity;
            } else {
                // Y locked, Z free/limited.
                if (swing.*[1] != 0.0) {
                    clamped_axis |= ca_swing_y_min | ca_swing_y_max;
                }
                const delta_min: f32 = part.sin_swing_z_half_min - swing.*[2];
                const delta_max: f32 = swing.*[2] - part.sin_swing_z_half_max;
                if (delta_min > 0.0 or delta_max > 0.0) {
                    if (sDistanceToMinShorter(delta_min, delta_max)) {
                        swing.* = quat(0.0, 0.0, part.sin_swing_z_half_min, part.cos_swing_z_half_min);
                        clamped_axis |= ca_swing_z_min;
                    } else {
                        swing.* = quat(0.0, 0.0, part.sin_swing_z_half_max, part.cos_swing_z_half_max);
                        clamped_axis |= ca_swing_z_max;
                    }
                } else if ((clamped_axis & ca_swing_y_min) != 0) {
                    const z: f32 = swing.*[2];
                    swing.* = quat(0.0, 0.0, z, @sqrt(1.0 - z * z));
                }
            }
        } else if ((part.rotation_flags & rf_swing_z_locked) != 0) {
            // Z locked, Y free/limited.
            if (swing.*[2] != 0.0) {
                clamped_axis |= ca_swing_z_min | ca_swing_z_max;
            }
            const delta_min: f32 = part.sin_swing_y_half_min - swing.*[1];
            const delta_max: f32 = swing.*[1] - part.sin_swing_y_half_max;
            if (delta_min > 0.0 or delta_max > 0.0) {
                if (sDistanceToMinShorter(delta_min, delta_max)) {
                    swing.* = quat(0.0, part.sin_swing_y_half_min, 0.0, part.cos_swing_y_half_min);
                    clamped_axis |= ca_swing_y_min;
                } else {
                    swing.* = quat(0.0, part.sin_swing_y_half_max, 0.0, part.cos_swing_y_half_max);
                    clamped_axis |= ca_swing_y_max;
                }
            } else if ((clamped_axis & ca_swing_z_min) != 0) {
                const y: f32 = swing.*[1];
                swing.* = quat(0.0, y, 0.0, @sqrt(1.0 - y * y));
            }
        } else {
            // Two swing DOF.
            if (part.swing_type == .cone) {
                const sin_y_max: f32 = part.sin_swing_y_half_max;
                const sin_z_max: f32 = part.sin_swing_z_half_max;
                const swing_y: f32 = swing.*[1];
                const swing_z: f32 = swing.*[2];
                if (!ellipseInside(sin_y_max, sin_z_max, swing_y, swing_z)) {
                    const closest: EllipsePoint = ellipseClosestPoint(sin_y_max, sin_z_max, swing_y, swing_z);
                    const w_sq: f32 = 1.0 - closest.x * closest.x - closest.y * closest.y;
                    swing.* = quat(0.0, closest.x, closest.y, @sqrt(@max(0.0, w_sq)));
                    clamped_axis |= ca_swing_y_min | ca_swing_y_max | ca_swing_z_min | ca_swing_z_max;
                }
            } else {
                // Pyramid: q.y = sin(y/2) cos(z/2), q.z = cos(y/2) sin(z/2), so the half
                // angles are atan2(q.y, q.w) and atan2(q.z, q.w). Clamp each and rebuild.
                const half_y: f32 = atan2Rad(swing.*[1], swing.*[3]);
                const half_z: f32 = atan2Rad(swing.*[2], swing.*[3]);
                const clamped_y: f32 = clamp(half_y, part.swing_y_half_min, part.swing_y_half_max);
                const clamped_z: f32 = clamp(half_z, part.swing_z_half_min, part.swing_z_half_max);
                if (clamped_y != half_y or clamped_z != half_z) {
                    const sy: f32 = @sin(clamped_y);
                    const cy: f32 = @cos(clamped_y);
                    const sz: f32 = @sin(clamped_z);
                    const cz: f32 = @cos(clamped_z);
                    swing.* = quatNormalize(quat(0.0, sy * cz, cy * sz, cy * cz));
                    clamped_axis |= ca_swing_y_min | ca_swing_y_max | ca_swing_z_min | ca_swing_z_max;
                }
            }
        }

        if (negate_swing) {
            swing.* = -swing.*;
        }
        if (negate_twist) {
            twist.* = -twist.*;
        }
        return clamped_axis;
    }

    // -------------------------------------------------------------------------------------
    // FRAME CONVENTION (Jolt-literal, since qmul is Hamilton). The swing-twist part and its two
    //   consumers (the dedicated swing-twist Constraint and the SixDOF joint) build the
    //   constraint frame exactly as Jolt does:
    //     setup     constraint_to_body = qmul(conj(R), c_to_world)       [Jolt: conj(R) * c2w]
    //     dispatch  cb_to_world        = qmul(R, constraint_to_body)     [Jolt: R * c2b]
    //     dispatch  q                  = qmul(conj(cb1), cb2)            [Jolt: conj(cb1) * cb2]
    //     part      twist_to_world     = qmul(constraint_to_world, q_swing)
    //   Do NOT "simplify" these to the reversed order. They used to be built reversed-but-self-
    //   consistently, which silently broke the CONE limit: the cone's velocity limit is ONE-
    //   SIDED [-inf,0], and a conjugate-frame q makes its jv come out the wrong sign, so the
    //   corrective impulse clamped to 0 and the limb sailed through the cone (planar pendulum
    //   reached ~1.53 rad against a 0.35 cone). The LOCKED branches survived the reversed frame
    //   only because their clamp is bidirectional [-inf,+inf] (sign-insensitive) and their
    //   q_swing ~= identity. Flipping the whole frame to Jolt fixes the cone while keeping the
    //   locked path rigid. Verified headless (cone holds ~0.36, twist holds ~0.44, near-locked
    //   stays 0.0000, SixDOF rotation ~0.36 + translation pinned). NOTE: the swing/twist MOTORS
    //   were flipped to the matching Jolt forms (target = q_swing*q_twist, diff = conj(q)*target,
    //   SetTargetOrientationBS = conj(c2b1)*orient*c2b2) but are off by default and not yet
    //   probe-verified, so exercise them with a motor probe before relying on them.
    // -------------------------------------------------------------------------------------

    /// Per-step setup: decompose + clamp the current constraint rotation, then build the
    /// world-space rotation axes and prepare the active AngleConstraintParts. Mirrors
    /// Jolt's SwingTwistConstraintPart::CalculateConstraintProperties.
    pub fn calculateConstraintProperties(
        part: *SwingTwistPart,
        inv_i_a: Mat3,
        inv_i_b: Mat3,
        constraint_rotation: Quat,
        constraint_to_world: Quat,
    ) void {
        const st: SwingTwistPair = quatGetSwingTwist(constraint_rotation);
        const q_swing: Quat = st.swing;
        const q_twist: Quat = st.twist;
        var q_clamped_swing: Quat = q_swing;
        var q_clamped_twist: Quat = q_twist;
        const clamped_axis: u32 = part.clampSwingTwist(&q_clamped_swing, &q_clamped_twist);

        const axis_x: Vec = vec(1.0, 0.0, 0.0);
        const axis_y: Vec = vec(0.0, 1.0, 0.0);
        const axis_z: Vec = vec(0.0, 0.0, 1.0);

        if ((part.rotation_flags & rf_swing_y_locked) != 0) {
            const twist_to_world: Quat = qmul(constraint_to_world, q_swing);
            part.swing_limit_y_axis = rotate(twist_to_world, axis_y);
            part.swing_limit_z_axis = rotate(twist_to_world, axis_z);
            if ((part.rotation_flags & rf_swing_z_locked) != 0) {
                part.swing_y.prepare(inv_i_a, inv_i_b, part.swing_limit_y_axis, 0.0);
                part.swing_z.prepare(inv_i_a, inv_i_b, part.swing_limit_z_axis, 0.0);
            } else {
                part.swing_y.prepare(inv_i_a, inv_i_b, part.swing_limit_y_axis, 0.0);
                if ((clamped_axis & (ca_swing_z_min | ca_swing_z_max)) != 0) {
                    if ((clamped_axis & ca_swing_z_min) != 0) {
                        part.swing_limit_z_axis = -part.swing_limit_z_axis;
                    }
                    part.swing_z.prepare(inv_i_a, inv_i_b, part.swing_limit_z_axis, 0.0);
                } else {
                    part.swing_z = AngleConstraintPart.inactive;
                }
            }
        } else if ((part.rotation_flags & rf_swing_z_locked) != 0) {
            const twist_to_world: Quat = qmul(constraint_to_world, q_swing);
            part.swing_limit_y_axis = rotate(twist_to_world, axis_y);
            part.swing_limit_z_axis = rotate(twist_to_world, axis_z);
            if ((clamped_axis & (ca_swing_y_min | ca_swing_y_max)) != 0) {
                if ((clamped_axis & ca_swing_y_min) != 0) {
                    part.swing_limit_y_axis = -part.swing_limit_y_axis;
                }
                part.swing_y.prepare(inv_i_a, inv_i_b, part.swing_limit_y_axis, 0.0);
            } else {
                part.swing_y = AngleConstraintPart.inactive;
            }
            part.swing_z = AngleConstraintPart.inactive;
        } else if ((part.rotation_flags & rf_swing_yz_free) != rf_swing_yz_free) {
            // Cone: a single limit about the axis from the clamped swing to the current swing.
            if ((clamped_axis & (ca_swing_y_min | ca_swing_y_max | ca_swing_z_min | ca_swing_z_max)) != 0) {
                const current: Vec = rotate(qmul(constraint_to_world, q_swing), axis_x);
                const desired: Vec = rotate(qmul(constraint_to_world, q_clamped_swing), axis_x);
                part.swing_limit_y_axis = cross(desired, current);
                const len: f32 = length3(part.swing_limit_y_axis);
                if (len != 0.0) {
                    part.swing_limit_y_axis = part.swing_limit_y_axis * splat(1.0 / len);
                    part.swing_y.prepare(inv_i_a, inv_i_b, part.swing_limit_y_axis, 0.0);
                } else {
                    part.swing_y = AngleConstraintPart.inactive;
                }
            } else {
                part.swing_y = AngleConstraintPart.inactive;
            }
            part.swing_z = AngleConstraintPart.inactive;
        } else {
            part.swing_y = AngleConstraintPart.inactive;
            part.swing_z = AngleConstraintPart.inactive;
        }

        if ((part.rotation_flags & rf_twist_locked) != 0) {
            part.twist_limit_axis = rotate(qmul(constraint_to_world, q_swing), axis_x);
            part.twist.prepare(inv_i_a, inv_i_b, part.twist_limit_axis, 0.0);
        } else if ((part.rotation_flags & rf_twist_free) == 0) {
            if ((clamped_axis & (ca_twist_min | ca_twist_max)) != 0) {
                part.twist_limit_axis = rotate(qmul(constraint_to_world, q_swing), axis_x);
                if ((clamped_axis & ca_twist_min) != 0) {
                    part.twist_limit_axis = -part.twist_limit_axis;
                }
                part.twist.prepare(inv_i_a, inv_i_b, part.twist_limit_axis, 0.0);
            } else {
                part.twist = AngleConstraintPart.inactive;
            }
        } else {
            part.twist = AngleConstraintPart.inactive;
        }
    }

    pub fn isActive(part: *const SwingTwistPart) bool {
        return part.swing_y.active or part.swing_z.active or part.twist.active;
    }

    pub fn warmStart(
        part: *SwingTwistPart,
        ma: *Motion,
        mb: *Motion,
        impulse_ratio: f32,
    ) void {
        if (part.swing_y.active) {
            part.swing_y.warmStart(ma, mb, impulse_ratio);
        }
        if (part.swing_z.active) {
            part.swing_z.warmStart(ma, mb, impulse_ratio);
        }
        if (part.twist.active) {
            part.twist.warmStart(ma, mb, impulse_ratio);
        }
    }

    /// One velocity iteration over the active limits. A limit whose min==max (a locked
    /// axis) is bilateral [-inf, +inf]; otherwise it is one-sided [-inf, 0] (the rotation
    /// axis was already flipped for a min-limit so the impulse pushes back into range).
    pub fn solveVelocity(part: *SwingTwistPart, ma: *Motion, mb: *Motion) void {
        const big: f32 = floatMax(f32);
        if (part.swing_y.active) {
            const hi: f32 = if (part.sin_swing_y_half_min == part.sin_swing_y_half_max) big else 0.0;
            part.swing_y.solveVelocity(ma, mb, part.swing_limit_y_axis, -big, hi);
        }
        if (part.swing_z.active) {
            const hi: f32 = if (part.sin_swing_z_half_min == part.sin_swing_z_half_max) big else 0.0;
            part.swing_z.solveVelocity(ma, mb, part.swing_limit_z_axis, -big, hi);
        }
        if (part.twist.active) {
            const hi: f32 = if (part.sin_twist_half_min == part.sin_twist_half_max) big else 0.0;
            part.twist.solveVelocity(ma, mb, part.twist_limit_axis, -big, hi);
        }
    }

    /// Position correction: re-decompose and clamp the current constraint rotation; if any
    /// axis is out of range, drive the relative orientation back to the clamped one with a
    /// RotationLockPart (Jolt uses RotationEulerConstraintPart here).
    pub fn solvePosition(
        part: *const SwingTwistPart,
        body_a: *Body,
        body_b: *Body,
        inv_i_a: Mat3,
        inv_i_b: Mat3,
        constraint_rotation: Quat,
        constraint_to_body_a: Quat,
        constraint_to_body_b: Quat,
        baumgarte: f32,
    ) void {
        const st: SwingTwistPair = quatGetSwingTwist(constraint_rotation);
        var q_swing: Quat = st.swing;
        var q_twist: Quat = st.twist;
        const clamped_axis: u32 = part.clampSwingTwist(&q_swing, &q_twist);
        if (clamped_axis != 0) {
            // inv_initial = c_to_b2 * conj(c_to_b1 * q_swing_clamped * q_twist_clamped)
            const target: Quat = qmul(constraint_to_body_a, qmul(q_swing, q_twist));
            const inv_initial: Quat = qmul(constraint_to_body_b, conjugate(target));
            var rot_part: RotationLockPart = RotationLockPart.inactive;
            rot_part.prepare(inv_i_a, inv_i_b);
            if (rot_part.active) {
                rot_part.solvePosition(body_a, body_b, inv_initial, baumgarte);
            }
        }
    }
};

pub const Constraint = struct {
    kind: ConstraintKind,
    body_a: BodyIndex,
    body_b: BodyIndex,
    local_anchor_a: Vec, // anchor in body A's local frame, relative to its COM
    local_anchor_b: Vec, // anchor in body B's local frame, relative to its COM
    enabled: bool = true,

    // .distance limits (min == max gives a rigid rod; min=0 with a max gives a rope).
    min_distance: f32 = 0.0,
    max_distance: f32 = 0.0,

    // .fixed / .slider rotation lock, and .hinge angle reference: conj(rotB0)*rotA0,
    // captured at creation so the rest pose reads as zero error / zero angle.
    inv_initial_rotation: Quat = quat_identity,

    // .hinge axis / .slider slide axis, in each body's local frame.
    local_axis_a: Vec = vec_zero,
    local_axis_b: Vec = vec_zero,
    // .slider: the two axes perpendicular to the slide axis, in body A's local frame.
    local_normal_a: Vec = vec_zero,
    local_normal_b: Vec = vec_zero,

    // .hinge / .slider shared limit + motor configuration.
    has_limits: bool = false,
    limit_min: f32 = 0.0, // radians (hinge) or metres (slider)
    limit_max: f32 = 0.0,
    motor: MotorSettings = .{},

    // --- solver scratch, rebuilt every step in prepareConstraint ---
    point_part: PointPart = PointPart.inactive, // .point, .fixed, .hinge (translation lock)
    rotation_lock: RotationLockPart = RotationLockPart.inactive, // .fixed, .slider (3-axis)
    hinge_rotation: HingeRotationPart = HingeRotationPart.inactive, // .hinge (2-axis)
    dual_axis: DualAxisPart = DualAxisPart.inactive, // .slider (2-axis translation)
    axis_part: AxisPart = AxisPart.inactive, // .distance, .slider limit
    axis_motor: AxisPart = AxisPart.inactive, // .slider motor
    angle_limit: AngleConstraintPart = AngleConstraintPart.inactive, // .hinge limit
    angle_motor: AngleConstraintPart = AngleConstraintPart.inactive, // .hinge motor

    world_axis: Vec = vec_zero, // world hinge/slide axis this try step (for the 1-DOF solves)
    world_n1: Vec = vec_zero, // .slider: world perpendicular axes this try step (for dual-axis solve)
    world_n2: Vec = vec_zero,
    limit_rt: LimitRuntime = .{}, // .hinge / .slider limit engagement
    motor_rt: MotorRuntime = .{}, // .hinge / .slider motor engagement

    // .distance 1-DOF engagement (kept separate from the hinge/slider limit runtime).
    axis_active: bool = false,
    axis_target: f32 = 0.0,
    axis_min_lambda: f32 = 0.0,
    axis_max_lambda: f32 = 0.0,
    axis_sign: f32 = 0.0,
    axis: Vec = vec_zero, // .distance world axis (anchorA -> anchorB)

    // --- .swing_twist (ragdoll cone + twist joint) ---
    swing_type: SwingType = .cone,
    normal_half_cone: f32 = 0.0, // swing limit about the normal (Z) axis, radians
    plane_half_cone: f32 = 0.0, // swing limit about the plane (Y) axis, radians
    twist_min: f32 = 0.0, // twist limit about the twist (X) axis, radians
    twist_max: f32 = 0.0,
    constraint_to_body_a: Quat = quat_identity, // rotation: constraint space -> body A local
    constraint_to_body_b: Quat = quat_identity,
    swing_twist: SwingTwistPart = SwingTwistPart.inactive, // swing/twist limit scratch

    // .swing_twist motors (off by default; configured at build time or via the swingTwist*
    // helpers / Ragdoll.driveToPoseUsingMotors). The twist motor drives motor_part[0]; the
    // swing motor drives motor_part[1] and [2].
    swing_motor: AngularMotorSettings = .{},
    twist_motor: AngularMotorSettings = .{},
    swing_motor_state: MotorState = .off,
    twist_motor_state: MotorState = .off,
    target_angular_velocity: Vec = vec_zero, // in body B's constraint space
    target_orientation: Quat = quat_identity, // in constraint space (clamped to limits)
    max_friction_torque: f32 = 0.0, // bounded friction when a motor is off
    motor_axis: [3]Vec = .{ vec_zero, vec_zero, vec_zero }, // world axes (rebuilt each step)
    motor_part: [3]AngleConstraintPart = @splat(AngleConstraintPart.inactive),
    swing_motor_lo: f32 = 0.0, // per-step swing motor impulse clamp (= torque * dt)
    swing_motor_hi: f32 = 0.0,
    twist_motor_lo: f32 = 0.0,
    twist_motor_hi: f32 = 0.0,

    // .gear: couples two bodies' rotations about their hinge axes. local_axis_a/b hold the two
    // local hinge axes; world_axis / world_axis_b the world axes this step. ratio = teeth2/teeth1
    // (sign sets co/counter-rotation). gear_ref_a/b are optional indices of the two hinge
    // constraints this gear meshes (for position drift correction); -1 = velocity coupling only
    // (Jolt's null-constraint path).
    ratio: f32 = 1.0,
    world_axis_b: Vec = vec_zero,
    gear_ref_a: i32 = -1,
    gear_ref_b: i32 = -1,
    gear_part: GearConstraintPart = GearConstraintPart.inactive,
    // .rack_and_pinion: body_a is the pinion (rotates about local_axis_a), body_b the rack
    // (slides along local_axis_b). Reuses ratio/world_axis/world_axis_b/gear_ref_a (pinion hinge)/
    // gear_ref_b (rack slider).
    rack_pinion_part: RackAndPinionConstraintPart = RackAndPinionConstraintPart.inactive,
    // .pulley: a rope of fixed total length over two fixed world points. local_anchor_a/b are the
    // rope ends on the bodies (COM-local); pulley_fixed_a/b the two fixed pulley points;
    // min_distance/max_distance the min/max rope length; ratio the body-2 segment multiplier;
    // world_axis/world_axis_b the segment normals and axis_min/max_lambda the clamp this step.
    pulley_fixed_a: Vec = vec_zero,
    pulley_fixed_b: Vec = vec_zero,
    indep_axis_part: IndependentAxisConstraintPart = IndependentAxisConstraintPart.inactive,
};

/// A point on a `LinearCurve`.
const CurvePoint = struct { x: f32 = 0.0, y: f32 = 0.0 };

/// A piecewise-linear curve sampled by x (Jolt's LinearCurve), used for the tire friction
/// curves. Points are added in ascending x; getValue clamps to the endpoints outside the range.
const LinearCurve = struct {
    points: [8]CurvePoint = @splat(.{}),
    count: u8 = 0,

    fn addPoint(self: *LinearCurve, x: f32, y: f32) void {
        if (self.count >= self.points.len) {
            return;
        }
        self.points[self.count] = .{ .x = x, .y = y };
        self.count += 1;
    }

    fn getValue(self: *const LinearCurve, x: f32) f32 {
        if (self.count == 0) {
            return 0.0;
        }
        var i: u8 = 0;
        while (i < self.count and self.points[i].x < x) : (i += 1) {}
        if (i == 0) {
            return self.points[0].y;
        }
        if (i == self.count) {
            return self.points[self.count - 1].y;
        }
        const p1: CurvePoint = self.points[i - 1];
        const p2: CurvePoint = self.points[i];
        return p1.y + (x - p1.x) * (p2.y - p1.y) / (p2.x - p1.x);
    }
};

/// Jolt's default longitudinal tire friction curve (x = slip ratio, y = friction coefficient).
fn defaultLongitudinalFrictionCurve() LinearCurve {
    var c: LinearCurve = .{};
    c.addPoint(0.0, 0.0);
    c.addPoint(0.06, 1.2);
    c.addPoint(0.2, 1.0);
    return c;
}

/// Jolt's default lateral tire friction curve (x = slip angle in degrees, y = friction).
fn defaultLateralFrictionCurve() LinearCurve {
    var c: LinearCurve = .{};
    c.addPoint(0.0, 0.0);
    c.addPoint(3.0, 1.2);
    c.addPoint(20.0, 1.0);
    return c;
}

/// Per-wheel configuration. Lengths run along the suspension direction from the attachment
/// (hard) point. Directions are in the body's local space; `position` is relative to the body
/// origin (not the centre of mass). Jolt's WheelSettings.
pub const WheelSettings = struct {
    position: Vec = .{ 0.0, 0.0, 0.0, 0.0 }, // suspension attachment point, body-local (origin-relative)
    suspension_direction: Vec = .{ 0.0, -1.0, 0.0, 0.0 }, // points down, body-local (unit)
    steering_axis: Vec = .{ 0.0, 1.0, 0.0, 0.0 }, // points up, body-local
    wheel_up: Vec = .{ 0.0, 1.0, 0.0, 0.0 }, // wheel up at neutral steer, body-local
    wheel_forward: Vec = .{ 0.0, 0.0, 1.0, 0.0 }, // wheel forward at neutral steer, body-local
    suspension_min_length: f32 = 0.3, // length in the max-raised position (m)
    suspension_max_length: f32 = 0.5, // length in the max-droop position (m)
    suspension_preload_length: f32 = 0.0, // natural spring length = max_length + this
    suspension_frequency: f32 = 1.5, // suspension spring frequency (Hz)
    suspension_damping: f32 = 0.5, // suspension spring damping ratio
    radius: f32 = 0.3, // wheel radius (m)
    width: f32 = 0.1, // wheel width (m)
    inertia: f32 = 0.9, // wheel moment of inertia (kg m^2): 0.5*m*r^2 for a 20kg, 0.3m wheel
    angular_damping: f32 = 0.2, // wheel spin damping: dw/dt = -c*w
    max_steer_angle: f32 = radFromDeg(70.0), // how far this wheel can steer (rad)
    max_brake_torque: f32 = 1500.0, // brake torque this wheel can apply (Nm)
    max_hand_brake_torque: f32 = 4000.0, // hand-brake torque (Nm); usually rear wheels only
    longitudinal_friction: LinearCurve = defaultLongitudinalFrictionCurve(), // slip ratio -> friction
    lateral_friction: LinearCurve = defaultLateralFrictionCurve(), // slip angle (deg) -> friction
    suspension_force_point: Vec = .{ 0.0, 0.0, 0.0, 0.0 }, // where forces apply (if enabled), body-local
    enable_suspension_force_point: bool = false, // else forces apply at the contact point
    // Tracked (tank) vehicles use scalar tire friction instead of the slip curves above
    // (Jolt's WheelSettingsTV); ignored by wheeled/motorcycle vehicles.
    tv_longitudinal_friction: f32 = 4.0,
    tv_lateral_friction: f32 = 2.0,
};

pub const none_body: BodyIndex = 0xFFFF_FFFF;

/// Per-wheel runtime state: the latest ground contact plus the constraint parts solved each
/// step. `contact_body == none_body` means the wheel is in the air. Jolt's Wheel.
pub const Wheel = struct {
    settings: WheelSettings,

    // Contact (filled by collideWheels; valid only when contact_body != none_body).
    contact_body: BodyIndex = none_body,
    contact_position: Vec = .{ 0.0, 0.0, 0.0, 0.0 }, // world-space contact point
    contact_normal: Vec = .{ 0.0, 0.0, 0.0, 0.0 }, // world-space, points away from the ground
    contact_longitudinal: Vec = .{ 0.0, 0.0, 0.0, 0.0 }, // world-space forward along the ground
    contact_lateral: Vec = .{ 0.0, 0.0, 0.0, 0.0 }, // world-space sideways
    contact_point_velocity: Vec = .{ 0.0, 0.0, 0.0, 0.0 }, // world-space velocity of the ground at contact
    suspension_length: f32 = 0.0, // current suspension length (m)
    axle_plane_constant: f32 = 0.0, // n . (origin + length*dir): the axle contact plane
    anti_roll_bar_impulse: f32 = 0.0,

    // Wheel orientation / spin.
    steer_angle: f32 = 0.0, // about the steering axis, + to the left (rad)
    angular_velocity: f32 = 0.0, // spin (rad/s), + drives the vehicle forward
    angle: f32 = 0.0, // current spin angle, [0, 2pi)
    track_index: i32 = -1, // tracked vehicles: which track owns this wheel (filled each step)

    // Tire friction state (recomputed each step in updateWheels / the friction solve).
    longitudinal_slip: f32 = 0.0, // |omega*r - v_long| / |v_long|
    lateral_slip: f32 = 0.0, // slip angle between contact velocity and tire forward (rad)
    combined_longitudinal_friction: f32 = 0.0, // sqrt(tire * terrain), this step
    combined_lateral_friction: f32 = 0.0,
    brake_impulse: f32 = 0.0, // brake impulse budget excluding friction (Ns), this step

    // Constraint parts (rebuilt each step; keep their accumulated impulse for warm start).
    suspension_part: AxisPart = AxisPart.inactive, // up/down along the contact normal (spring)
    suspension_max_up_part: AxisPart = AxisPart.inactive, // hard limit at min suspension length
    longitudinal_part: AxisPart = AxisPart.inactive, // forward/back (traction/brake)
    lateral_part: AxisPart = AxisPart.inactive, // sideways (cornering)

    /// True if the wheel is touching the ground.
    pub fn hasContact(self: *const Wheel) bool {
        return self.contact_body != none_body;
    }

    /// True while the suspension is bottomed out (its hard-limit part is engaged).
    pub fn hasHitHardPoint(self: *const Wheel) bool {
        return self.suspension_max_up_part.isActive();
    }
};

/// How wheels find the ground. Phase 1 implements the ray tester (one ray straight down the
/// suspension). Jolt's VehicleCollisionTester hierarchy; cast-sphere / cast-cylinder follow.
pub const VehicleCollisionTester = union(enum) {
    ray: RayTester,
    cast_sphere: CastSphereTester,
    cast_cylinder: CastCylinderTester,

    pub const RayTester = struct {
        object_mask: u32 = 0xFFFF_FFFF, // category mask of bodies the wheels may hit
        up: Vec = .{ 0.0, 1.0, 0.0, 0.0 }, // world up, for the max-slope rejection
        cos_max_slope_angle: f32 = 0.17364818, // cos(80 deg): steeper hits are treated as walls and ignored
    };

    /// Casts a sphere instead of a ray, so the wheel rides over small bumps/edges rather than
    /// dropping a single point into a crack. Jolt's VehicleCollisionTesterCastSphere.
    pub const CastSphereTester = struct {
        object_mask: u32 = 0xFFFF_FFFF,
        up: Vec = .{ 0.0, 1.0, 0.0, 0.0 },
        cos_max_slope_angle: f32 = 0.17364818, // cos(80 deg)
        radius: f32 = 0.3, // radius of the cast sphere (usually <= the wheel radius)
    };

    /// Casts a cylinder shaped like the wheel (its axis along the wheel's axle), giving the most
    /// accurate contact. Jolt's VehicleCollisionTesterCastCylinder (no slope test — the cylinder
    /// shape itself avoids catching on walls).
    pub const CastCylinderTester = struct {
        object_mask: u32 = 0xFFFF_FFFF,
        convex_radius_fraction: f32 = 0.1, // fraction of @min(halfWidth, radius) used as convex radius
    };
};

/// Default engine torque curve: x = RPM fraction (0 = min, 1 = max), y = fraction of max torque.
fn defaultEngineTorqueCurve() LinearCurve {
    var c: LinearCurve = .{};
    c.addPoint(0.0, 0.8);
    c.addPoint(0.66, 1.0);
    c.addPoint(1.0, 0.8);
    return c;
}

/// Vehicle engine: configuration + runtime RPM (Jolt's VehicleEngineSettings + VehicleEngine
/// folded together). Fill the settings fields; current_rpm is initialised to min_rpm by the
/// vehicle. Torque scales by the normalized curve sampled at the current RPM fraction.
pub const VehicleEngine = struct {
    max_torque: f32 = 500.0, // Nm the engine can deliver
    min_rpm: f32 = 1000.0, // idle / stall floor
    max_rpm: f32 = 6000.0,
    normalized_torque: LinearCurve = defaultEngineTorqueCurve(),
    inertia: f32 = 0.5, // kg m^2
    angular_damping: f32 = 0.2,
    current_rpm: f32 = 1000.0,

    const angular_velocity_to_rpm: f32 = 60.0 / (2.0 * pi);

    fn clampRpm(self: *VehicleEngine) void {
        self.current_rpm = clamp(self.current_rpm, self.min_rpm, self.max_rpm);
    }
    pub fn getCurrentRpm(self: *const VehicleEngine) f32 {
        return self.current_rpm;
    }
    pub fn setCurrentRpm(self: *VehicleEngine, rpm: f32) void {
        self.current_rpm = rpm;
        self.clampRpm();
    }
    fn getAngularVelocity(self: *const VehicleEngine) f32 {
        return self.current_rpm / angular_velocity_to_rpm;
    }
    fn getTorque(self: *const VehicleEngine, acceleration: f32) f32 {
        const rpm_fraction: f32 = self.current_rpm / self.max_rpm;
        return acceleration * self.max_torque * self.normalized_torque.getValue(rpm_fraction);
    }
    fn applyTorque(self: *VehicleEngine, torque: f32, dt: f32) void {
        self.current_rpm += angular_velocity_to_rpm * torque * dt / self.inertia;
        self.clampRpm();
    }
    fn applyDamping(self: *VehicleEngine, dt: f32) void {
        self.current_rpm *= @max(0.0, 1.0 - self.angular_damping * dt);
    }
    fn allowSleep(self: *const VehicleEngine) bool {
        return self.current_rpm <= 1.01 * self.min_rpm;
    }
};

/// How the gearbox shifts.
pub const ETransmissionMode = enum { auto, manual };

/// Vehicle transmission: gearbox configuration + runtime gear/clutch state (Jolt's
/// VehicleTransmissionSettings + VehicleTransmission). Gear ratios are stored inline; index
/// 0 is 1st gear. Reverse ratios are negative. Gear 0 is neutral.
pub const VehicleTransmission = struct {
    mode: ETransmissionMode = .auto,
    gear_ratios: [10]f32 = .{ 2.66, 1.78, 1.3, 1.0, 0.74, 0.0, 0.0, 0.0, 0.0, 0.0 },
    gear_count: u8 = 5,
    reverse_gear_ratios: [4]f32 = .{ -2.90, 0.0, 0.0, 0.0 },
    reverse_gear_count: u8 = 1,
    switch_time: f32 = 0.5, // time to switch gears (s)
    clutch_release_time: f32 = 0.3, // time to go to full clutch friction (s)
    switch_latency: f32 = 0.5, // wait after a switch before another (s)
    shift_up_rpm: f32 = 4000.0,
    shift_down_rpm: f32 = 2000.0,
    clutch_strength: f32 = 10.0, // k m^2 s^-1

    current_gear: i32 = 0, // -1 = reverse, 0 = neutral, 1 = first, ...
    clutch_friction: f32 = 1.0,
    gear_switch_time_left: f32 = 0.0,
    clutch_release_time_left: f32 = 0.0,
    gear_switch_latency_time_left: f32 = 0.0,

    pub fn set(self: *VehicleTransmission, gear: i32, clutch_friction: f32) void {
        self.current_gear = gear;
        self.clutch_friction = clutch_friction;
    }
    fn getClutchFriction(self: *const VehicleTransmission) f32 {
        return self.clutch_friction;
    }
    fn isSwitchingGear(self: *const VehicleTransmission) bool {
        return self.gear_switch_time_left > 0.0;
    }
    /// Engine-to-differential ratio for the current gear (0 in neutral).
    fn getCurrentRatio(self: *const VehicleTransmission) f32 {
        if (self.current_gear < 0) {
            return self.reverse_gear_ratios[@intCast(-self.current_gear - 1)];
        }
        if (self.current_gear == 0) {
            return 0.0;
        }
        return self.gear_ratios[@intCast(self.current_gear - 1)];
    }
    fn allowSleep(self: *const VehicleTransmission) bool {
        return self.gear_switch_time_left <= 0.0 and
            self.clutch_release_time_left <= 0.0 and
            self.gear_switch_latency_time_left <= 0.0;
    }
    /// Auto-shift the gear and ramp the clutch (Jolt's VehicleTransmission::Update). No-op in
    /// manual mode (the driver calls `set`).
    fn update(
        self: *VehicleTransmission,
        dt: f32,
        current_rpm: f32,
        forward_input: f32,
        can_shift_up: bool,
    ) void {
        if (self.mode != .auto) {
            return;
        }
        const old_gear: i32 = self.current_gear;
        if (self.current_gear == 0 or forward_input * float(self.current_gear) < 0.0) {
            // From neutral, or reversing direction: pick first or reverse from the input.
            self.current_gear = if (forward_input > 0.0)
                1
            else if (forward_input < 0.0)
                @as(i32, -1)
            else
                0;
        } else if (self.gear_switch_latency_time_left == 0.0) {
            if (can_shift_up and current_rpm > self.shift_up_rpm) {
                if (self.current_gear < 0) {
                    if (self.current_gear > -@as(i32, self.reverse_gear_count)) {
                        self.current_gear -= 1;
                    }
                } else {
                    if (self.current_gear < @as(i32, self.gear_count)) {
                        self.current_gear += 1;
                    }
                }
            } else if (current_rpm < self.shift_down_rpm) {
                if (self.current_gear < 0) {
                    const max_gear: i32 = if (forward_input != 0.0) -1 else 0;
                    if (self.current_gear < max_gear) {
                        self.current_gear += 1;
                    }
                } else {
                    const min_gear: i32 = if (forward_input != 0.0) 1 else 0;
                    if (self.current_gear > min_gear) {
                        self.current_gear -= 1;
                    }
                }
            }
        }

        if (old_gear != self.current_gear) {
            // Shifted: start the switch countdown and disengage the clutch.
            self.gear_switch_time_left = if (old_gear != 0) self.switch_time else 0.0;
            self.clutch_release_time_left = self.clutch_release_time;
            self.gear_switch_latency_time_left = self.switch_latency;
            self.clutch_friction = 0.0;
        } else if (self.gear_switch_time_left > 0.0) {
            self.gear_switch_time_left = @max(0.0, self.gear_switch_time_left - dt);
            self.clutch_friction = 0.0;
        } else if (self.clutch_release_time_left > 0.0) {
            self.clutch_release_time_left = @max(0.0, self.clutch_release_time_left - dt);
            self.clutch_friction = 1.0 - self.clutch_release_time_left / self.clutch_release_time;
        } else {
            self.clutch_friction = 1.0;
            self.gear_switch_latency_time_left = @max(0.0, self.gear_switch_latency_time_left - dt);
        }
    }
};

/// One differential: which two wheels it drives, the gear-to-wheel ratio, the left/right torque
/// split, the per-differential limited-slip ratio, and the share of engine torque it receives.
/// Jolt's VehicleDifferentialSettings. Wheel indices are into the vehicle's wheel array (−1 = none).
pub const VehicleDifferentialSettings = struct {
    left_wheel: i32 = -1,
    right_wheel: i32 = -1,
    differential_ratio: f32 = 3.42, // gearbox-to-wheel rotation ratio
    left_right_split: f32 = 0.5, // 0 = all left, 0.5 = even, 1 = all right
    limited_slip_ratio: f32 = 1.4, // max/min wheel speed before torque biases to the slow wheel
    engine_torque_ratio: f32 = 1.0, // share of engine torque (sum over differentials should be 1)

    /// Split the engine torque between the two wheels, biasing toward the slower wheel as their
    /// speed ratio approaches limited_slip_ratio (Jolt's CalculateTorqueRatio).
    fn calculateTorqueRatio(
        self: *const VehicleDifferentialSettings,
        left_ang_vel: f32,
        right_ang_vel: f32,
        out_left: *f32,
        out_right: *f32,
    ) void {
        out_left.* = 1.0 - self.left_right_split;
        out_right.* = self.left_right_split;
        if (self.limited_slip_ratio < floatMax(f32)) {
            const omega_l: f32 = @max(1.0e-3, @abs(left_ang_vel));
            const omega_r: f32 = @max(1.0e-3, @abs(right_ang_vel));
            const omega_min: f32 = @min(omega_l, omega_r);
            const omega_max: f32 = @max(omega_l, omega_r);
            const alpha: f32 = @min((omega_max / omega_min - 1.0) / (self.limited_slip_ratio - 1.0), 1.0);
            const one_min_alpha: f32 = 1.0 - alpha;
            if (omega_l < omega_r) {
                out_left.* = out_left.* * one_min_alpha + alpha;
                out_right.* = out_right.* * one_min_alpha;
            } else {
                out_left.* = out_left.* * one_min_alpha;
                out_right.* = out_right.* * one_min_alpha + alpha;
            }
        }
    }
};

/// An anti-roll bar coupling a left and right wheel's suspension: it biases the more-compressed
/// side up and the other down, proportional to their suspension-length difference, reducing body
/// roll. Jolt's VehicleAntiRollBar. The impulse it produces is fed in as the suspension bias.
pub const VehicleAntiRollBar = struct {
    left_wheel: i32 = 0,
    right_wheel: i32 = 1,
    stiffness: f32 = 1000.0, // N/m; 0 disables this bar
};

/// Motorcycle lean controller (Jolt's MotorcycleController, which extends the wheeled vehicle):
/// the bike leans into turns. Holds the lean spring config plus per-step lean state. Attach via
/// `VehicleSettings.lean` to make a wheeled vehicle a motorcycle; also set the chassis
/// `max_pitch_roll_angle` to pi so the anti-topple constraint does not fight the lean.
pub const MotorcycleLean = struct {
    max_lean_angle: f32 = pi / 4.0,
    spring_constant: f32 = 5000.0,
    spring_damping: f32 = 1000.0,
    spring_integration_coefficient: f32 = 0.0,
    spring_integration_coefficient_decay: f32 = 4.0,
    smoothing_factor: f32 = 0.8,
    enable_steering_limit: bool = true,

    // Runtime state.
    target_lean: Vec = .{ 0.0, 1.0, 0.0, 0.0 }, // world-space desired up for the chassis
    integrated_delta_angle: f32 = 0.0,
    applied_impulse: f32 = 0.0, // lean angular impulse applied so far this step
};

/// One tank track (Jolt's VehicleTrack): a group of wheels driven at a common speed by the
/// engine through a differential. `wheels` lists the wheel indices on this track (including
/// `driven_wheel`, the engine-connected one). Two tracks (left, right) make a tank; steering is
/// a speed difference between them. `angular_velocity` is the driven wheel's spin and sets the
/// whole track's speed.
pub const VehicleTrack = struct {
    driven_wheel: u32 = 0, // index into the vehicle's wheels of the engine-connected wheel
    wheels: [12]u32 = @splat(0), // wheel indices on this track (incl. driven_wheel)
    wheel_count: usize = 0,
    inertia: f32 = 10.0, // moment of inertia of the track + its wheels, seen at the driven wheel
    angular_damping: f32 = 0.5, // dw/dt = -c w
    max_brake_torque: f32 = 15000.0,
    differential_ratio: f32 = 6.0, // gearbox : driven-wheel rotation-speed ratio
    angular_velocity: f32 = 0.0, // runtime: driven wheel spin (rad/s)
};

/// Vehicle configuration: chassis orientation, an anti-topple limit, and the wheels. Jolt's
/// VehicleConstraintSettings. (Controller + anti-roll bars arrive in later phases.)
pub const VehicleSettings = struct {
    up: Vec = .{ 0.0, 1.0, 0.0, 0.0 }, // body-local up
    forward: Vec = .{ 0.0, 0.0, 1.0, 0.0 }, // body-local forward
    max_pitch_roll_angle: f32 = pi, // half-angle of the cone limiting topple; pi = off
    wheels: []const WheelSettings,
    engine: VehicleEngine = .{},
    transmission: VehicleTransmission = .{},
    differentials: []const VehicleDifferentialSettings = &.{},
    differential_limited_slip_ratio: f32 = floatMax(f32), // FLT_MAX = open (no inter-diff LSD)
    anti_roll_bars: []const VehicleAntiRollBar = &.{},
    lean: ?MotorcycleLean = null, // non-null turns this into a motorcycle (lean controller)
    tracks: ?[2]VehicleTrack = null, // non-null turns this into a tank (left, right tracks)
};

pub const QueryFilter = struct {
    mask: u32 = 0xFFFF_FFFF, // hit only bodies whose category intersects this
    exclude: BodyIndex = none_body, // skip one body (e.g. the ray's owner)
    include_sensors: bool = true, // queries usually want sensors; the solver never does
};

pub const RayHit = struct {
    body: BodyIndex,
    fraction: f32, // [0,1] fraction of max_distance to the hit (Jolt convention)
    distance: f32, // world-space distance along the ray to the hit
    point: Vec, // world-space hit point
    normal: Vec, // world-space surface normal (points back toward the ray origin)
};

pub const BodyPair = struct { a: BodyIndex, b: BodyIndex };

/// Broad phase: a dynamic AABB tree (the Box2D b2DynamicTree design). A flat node
/// pool with a free list (no per-node allocation), leaves carry a fattened AABB so a
/// body can jiggle without re-inserting, and insertion uses the surface-area
/// heuristic with rotation rebalancing to keep queries shallow.
///
/// Determinism note: findPairs reports every overlapping pair each frame (our
/// contacts are rebuilt per step rather than persisted), then the caller sorts them
/// by body index, so the set AND the order are independent of tree shape.
pub const BroadPhase = struct {
    const NULL_NODE: u32 = maxInt(u32);

    const Node = struct {
        aabb: Aabb, // fattened
        parent: u32,
        child1: u32, // NULL_NODE => this is a leaf; also reused as the free-list link
        child2: u32,
        body: BodyIndex, // valid when leaf
        height: i32, // 0 = leaf, -1 = free, else internal
    };

    nodes: std.ArrayListUnmanaged(Node) = .empty,
    root: u32 = NULL_NODE,
    free_list: u32 = NULL_NODE,
    margin: f32 = 0.1, // fattening (> speculative_distance, so no contact is missed)
    velocity_predict: f32 = 2.0, // fat box extended this many * displacement

    fn isLeaf(n: *const Node) bool {
        return n.child1 == NULL_NODE;
    }

    fn fatten(self: *const BroadPhase, tight: Aabb, displacement: Vec) Aabb {
        var fat: Aabb = tight.expandedBy(self.margin);
        const predicted: Vec = displacement * splat(self.velocity_predict);
        fat.min += @min(vec_zero, predicted);
        fat.max += @max(vec_zero, predicted);
        return fat;
    }

    fn allocNode(self: *BroadPhase, gpa: std.mem.Allocator) !u32 {
        if (self.free_list != NULL_NODE) {
            const idx: u32 = self.free_list;
            self.free_list = self.nodes.items[idx].child1;
            return idx;
        }
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(gpa, undefined);
        return idx;
    }

    fn freeNode(self: *BroadPhase, idx: u32) void {
        self.nodes.items[idx].child1 = self.free_list;
        self.nodes.items[idx].height = -1;
        self.free_list = idx;
    }

    pub fn insert(
        self: *BroadPhase,
        gpa: std.mem.Allocator,
        body: BodyIndex,
        tight: Aabb,
    ) !u32 {
        const leaf: u32 = try self.allocNode(gpa);
        self.nodes.items[leaf] = .{
            .aabb = self.fatten(tight, vec_zero),
            .parent = NULL_NODE,
            .child1 = NULL_NODE,
            .child2 = NULL_NODE,
            .body = body,
            .height = 0,
        };
        try self.insertLeaf(gpa, leaf);
        return leaf;
    }

    pub fn removeProxy(self: *BroadPhase, node: u32) void {
        self.removeLeaf(node);
        self.freeNode(node);
    }

    /// Refit a moved body. Cheap no-op while its tight AABB stays inside the fat one;
    /// otherwise re-insert with a freshly fattened, velocity-extended box.
    pub fn moveProxy(
        self: *BroadPhase,
        gpa: std.mem.Allocator,
        node: u32,
        tight: Aabb,
        displacement: Vec,
    ) !bool {
        if (self.nodes.items[node].aabb.contains(tight)) {
            return false;
        }
        self.removeLeaf(node);
        self.nodes.items[node].aabb = self.fatten(tight, displacement);
        try self.insertLeaf(gpa, node);
        return true;
    }

    fn insertLeaf(self: *BroadPhase, gpa: std.mem.Allocator, leaf: u32) !void {
        if (self.root == NULL_NODE) {
            self.root = leaf;
            self.nodes.items[leaf].parent = NULL_NODE;
            return;
        }

        // Find the best sibling: descend choosing the child whose union with the leaf
        // grows total surface area the least (SAH).
        const leaf_aabb: Aabb = self.nodes.items[leaf].aabb;
        var index: u32 = self.root;
        while (!isLeaf(&self.nodes.items[index])) {
            const child1: u32 = self.nodes.items[index].child1;
            const child2: u32 = self.nodes.items[index].child2;

            const node_area: f32 = self.nodes.items[index].aabb.area();
            const combined_area: f32 = self.nodes.items[index].aabb.combine(leaf_aabb).area();
            const cost: f32 = 2.0 * combined_area; // cost of a new parent here
            const inherit: f32 = 2.0 * (combined_area - node_area); // cost pushed downward

            const cost1: f32 = self.descendCost(child1, leaf_aabb, inherit);
            const cost2: f32 = self.descendCost(child2, leaf_aabb, inherit);

            if (cost < cost1 and cost < cost2) {
                break;
            }
            index = if (cost1 < cost2) child1 else child2;
        }
        const sibling: u32 = index;

        // Create a new parent for the sibling and the leaf.
        const old_parent: u32 = self.nodes.items[sibling].parent;
        const new_parent: u32 = try self.allocNode(gpa);
        self.nodes.items[new_parent] = .{
            .aabb = self.nodes.items[sibling].aabb.combine(leaf_aabb),
            .parent = old_parent,
            .child1 = sibling,
            .child2 = leaf,
            .body = 0,
            .height = self.nodes.items[sibling].height + 1,
        };
        self.nodes.items[sibling].parent = new_parent;
        self.nodes.items[leaf].parent = new_parent;

        if (old_parent != NULL_NODE) {
            if (self.nodes.items[old_parent].child1 == sibling) {
                self.nodes.items[old_parent].child1 = new_parent;
            } else {
                self.nodes.items[old_parent].child2 = new_parent;
            }
        } else {
            self.root = new_parent;
        }

        self.refitAndBalance(self.nodes.items[leaf].parent);
    }

    fn descendCost(
        self: *const BroadPhase,
        child: u32,
        leaf_aabb: Aabb,
        inherit: f32,
    ) f32 {
        const combined: Aabb = self.nodes.items[child].aabb.combine(leaf_aabb);
        if (isLeaf(&self.nodes.items[child])) {
            return combined.area() + inherit;
        }
        const old_area: f32 = self.nodes.items[child].aabb.area();
        return (combined.area() - old_area) + inherit;
    }

    fn removeLeaf(self: *BroadPhase, leaf: u32) void {
        if (leaf == self.root) {
            self.root = NULL_NODE;
            return;
        }
        const parent: u32 = self.nodes.items[leaf].parent;
        const grand_parent: u32 = self.nodes.items[parent].parent;
        const sibling: u32 = if (self.nodes.items[parent].child1 == leaf)
            self.nodes.items[parent].child2
        else
            self.nodes.items[parent].child1;

        if (grand_parent != NULL_NODE) {
            // The sibling takes the parent's slot.
            if (self.nodes.items[grand_parent].child1 == parent) {
                self.nodes.items[grand_parent].child1 = sibling;
            } else {
                self.nodes.items[grand_parent].child2 = sibling;
            }
            self.nodes.items[sibling].parent = grand_parent;
            self.freeNode(parent);
            self.refitAndBalance(grand_parent);
        } else {
            self.root = sibling;
            self.nodes.items[sibling].parent = NULL_NODE;
            self.freeNode(parent);
        }
    }

    /// Walk to the root refreshing heights and AABBs, rebalancing as we go.
    fn refitAndBalance(self: *BroadPhase, start: u32) void {
        var index: u32 = start;
        while (index != NULL_NODE) {
            index = self.balance(index);
            const left_child: u32 = self.nodes.items[index].child1;
            const right_child: u32 = self.nodes.items[index].child2;
            const left_height: i32 = self.nodes.items[left_child].height;
            const right_height: i32 = self.nodes.items[right_child].height;
            self.nodes.items[index].height = 1 + @max(left_height, right_height);
            const left_aabb: Aabb = self.nodes.items[left_child].aabb;
            const right_aabb: Aabb = self.nodes.items[right_child].aabb;
            self.nodes.items[index].aabb = left_aabb.combine(right_aabb);
            index = self.nodes.items[index].parent;
        }
    }

    /// Rotate a node up the tree when its two subtrees differ in height by more than
    /// one (the Box2D AVL-style single rotation), keeping the tree shallow so queries
    /// stay logarithmic. Returns the (possibly new) root of this subtree.
    fn balance(self: *BroadPhase, pivot: u32) u32 {
        const nodes: []Node = self.nodes.items;
        if (isLeaf(&nodes[pivot]) or nodes[pivot].height < 2) {
            return pivot;
        }

        const left_child: u32 = nodes[pivot].child1;
        const right_child: u32 = nodes[pivot].child2;
        const height_difference: i32 = nodes[right_child].height - nodes[left_child].height;

        if (height_difference > 1) {
            // Right subtree is too tall: promote the right child above the pivot.
            const right_left: u32 = nodes[right_child].child1;
            const right_right: u32 = nodes[right_child].child2;
            nodes[right_child].child1 = pivot;
            nodes[right_child].parent = nodes[pivot].parent;
            nodes[pivot].parent = right_child;

            const old_parent: u32 = nodes[right_child].parent;
            if (old_parent != NULL_NODE) {
                if (nodes[old_parent].child1 == pivot) {
                    nodes[old_parent].child1 = right_child;
                } else {
                    nodes[old_parent].child2 = right_child;
                }
            } else {
                self.root = right_child;
            }

            // The taller of the right child's children stays under it; the shorter
            // one moves under the pivot.
            if (nodes[right_left].height > nodes[right_right].height) {
                nodes[right_child].child2 = right_left;
                nodes[pivot].child2 = right_right;
                nodes[right_right].parent = pivot;
                nodes[pivot].aabb = nodes[left_child].aabb.combine(nodes[right_right].aabb);
                nodes[right_child].aabb = nodes[pivot].aabb.combine(nodes[right_left].aabb);
                nodes[pivot].height = 1 + @max(nodes[left_child].height, nodes[right_right].height);
                nodes[right_child].height = 1 + @max(nodes[pivot].height, nodes[right_left].height);
            } else {
                nodes[right_child].child2 = right_right;
                nodes[pivot].child2 = right_left;
                nodes[right_left].parent = pivot;
                nodes[pivot].aabb = nodes[left_child].aabb.combine(nodes[right_left].aabb);
                nodes[right_child].aabb = nodes[pivot].aabb.combine(nodes[right_right].aabb);
                nodes[pivot].height = 1 + @max(nodes[left_child].height, nodes[right_left].height);
                nodes[right_child].height = 1 + @max(nodes[pivot].height, nodes[right_right].height);
            }
            return right_child;
        }

        if (height_difference < -1) {
            // Left subtree is too tall: promote the left child above the pivot.
            const left_left: u32 = nodes[left_child].child1;
            const left_right: u32 = nodes[left_child].child2;
            nodes[left_child].child1 = pivot;
            nodes[left_child].parent = nodes[pivot].parent;
            nodes[pivot].parent = left_child;

            const old_parent: u32 = nodes[left_child].parent;
            if (old_parent != NULL_NODE) {
                if (nodes[old_parent].child1 == pivot) {
                    nodes[old_parent].child1 = left_child;
                } else {
                    nodes[old_parent].child2 = left_child;
                }
            } else {
                self.root = left_child;
            }

            if (nodes[left_left].height > nodes[left_right].height) {
                nodes[left_child].child2 = left_left;
                nodes[pivot].child1 = left_right;
                nodes[left_right].parent = pivot;
                nodes[pivot].aabb = nodes[right_child].aabb.combine(nodes[left_right].aabb);
                nodes[left_child].aabb = nodes[pivot].aabb.combine(nodes[left_left].aabb);
                nodes[pivot].height = 1 + @max(nodes[right_child].height, nodes[left_right].height);
                nodes[left_child].height = 1 + @max(nodes[pivot].height, nodes[left_left].height);
            } else {
                nodes[left_child].child2 = left_right;
                nodes[pivot].child1 = left_left;
                nodes[left_left].parent = pivot;
                nodes[pivot].aabb = nodes[right_child].aabb.combine(nodes[left_left].aabb);
                nodes[left_child].aabb = nodes[pivot].aabb.combine(nodes[left_right].aabb);
                nodes[pivot].height = 1 + @max(nodes[right_child].height, nodes[left_left].height);
                nodes[left_child].height = 1 + @max(nodes[pivot].height, nodes[left_right].height);
            }
            return left_child;
        }

        return pivot;
    }

    /// Emit every overlapping body pair exactly once, as (min, max) by body index.
    /// Each leaf queries the tree and keeps only partners with a greater body index,
    /// so no pair is produced twice. The caller sorts for a deterministic order.
    pub fn findPairs(
        self: *BroadPhase,
        gpa: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(BodyPair),
    ) !void {
        if (self.root == NULL_NODE) {
            return;
        }

        var stack: BvhStack = .{};
        for (self.nodes.items) |leaf| {
            if (leaf.height != 0) {
                continue;
            } // not a live leaf
            const self_body: BodyIndex = leaf.body;
            const query_aabb: Aabb = leaf.aabb;

            stack.sp = 0;
            stack.push(self.root);
            while (stack.pop()) |idx| {
                if (idx == NULL_NODE) {
                    continue;
                }
                const n: *const Node = &self.nodes.items[idx];
                if (!n.aabb.overlaps(query_aabb)) {
                    continue;
                }
                if (isLeaf(n)) {
                    if (n.body > self_body) {
                        try out.append(gpa, .{ .a = self_body, .b = n.body });
                    }
                } else {
                    stack.push(n.child1);
                    stack.push(n.child2);
                }
            }
        }

        std.mem.sort(BodyPair, out.items, {}, pairLess);
    }

    fn pairLess(_: void, lhs: BodyPair, rhs: BodyPair) bool {
        if (lhs.a != rhs.a) {
            return lhs.a < rhs.a;
        }
        return lhs.b < rhs.b;
    }

    /// Collect the bodies whose fat AABB overlaps `aabb` (the swept box of a CCD
    /// caster). Appends body indices to `out`.
    pub fn queryAabb(
        self: *const BroadPhase,
        gpa: std.mem.Allocator,
        aabb: Aabb,
        out: *std.ArrayListUnmanaged(BodyIndex),
    ) !void {
        if (self.root == NULL_NODE) {
            return;
        }
        var stack: BvhStack = .{};
        stack.push(self.root);
        while (stack.pop()) |idx| {
            if (idx == NULL_NODE) {
                continue;
            }
            const n: *const Node = &self.nodes.items[idx];
            if (!n.aabb.overlaps(aabb)) {
                continue;
            }
            if (isLeaf(n)) {
                try out.append(gpa, n.body);
            } else {
                stack.push(n.child1);
                stack.push(n.child2);
            }
        }
    }
};

/// Slab test used to prune broad-phase nodes. `inv_dir` is 1/dir per lane (the
/// w lane is ignored, so its inf/NaN does not matter).
fn rayVsAabb(
    origin: Vec,
    inv_dir: Vec,
    box: Aabb,
    t_max: f32,
) ?f32 {
    const t_lo: Vec = (box.min - origin) * inv_dir;
    const t_hi: Vec = (box.max - origin) * inv_dir;
    const t_near_v: Vec = @min(t_lo, t_hi);
    const t_far_v: Vec = @max(t_lo, t_hi);
    const t_enter: f32 = @max(t_near_v[0], @max(t_near_v[1], t_near_v[2]));
    const t_exit: f32 = @min(t_far_v[0], @min(t_far_v[1], t_far_v[2]));
    if (t_exit < @max(t_enter, 0.0)) {
        return null;
    }
    if (t_enter > t_max) {
        return null;
    }
    return @max(t_enter, 0.0);
}

fn queryAllows(body: *const Body, idx: BodyIndex, filter: QueryFilter) bool {
    if (idx == filter.exclude) {
        return false;
    }
    if (body.is_sensor and !filter.include_sensors) {
        return false;
    }
    return (body.category & filter.mask) != 0;
}

const RayShapeHit = struct { fraction: f32, normal: Vec };

fn rayVsSphere(
    origin: Vec,
    dir: Vec,
    center: Vec,
    radius: f32,
) ?RayShapeHit {
    const to_center: Vec = origin - center;
    const b: f32 = dot3(to_center, dir);
    const c: f32 = dot3(to_center, to_center) - radius * radius;
    if (c > 0.0 and b > 0.0) {
        return null;
    } // origin outside the sphere, pointing away
    const discriminant: f32 = b * b - c; // dir is unit, so a = 1
    if (discriminant < 0.0) {
        return null;
    }
    const root: f32 = -b - @sqrt(discriminant);
    const fraction: f32 = if (root < 0.0) 0.0 else root; // origin inside -> hit at t=0
    const hit_point: Vec = origin + dir * splat(fraction);
    return .{ .fraction = fraction, .normal = normalize3(hit_point - center) };
}

fn rayVsBox(
    origin: Vec,
    dir: Vec,
    center: Vec,
    rot: Quat,
    half_extent: Vec,
) ?RayShapeHit {
    // Work in the box's local frame, then a standard per-axis slab clip that also
    // remembers which face was entered (for the surface normal).
    const inv_rot: Quat = conjugate(rot);
    const local_origin: Vec = rotate(inv_rot, origin - center);
    const local_dir: Vec = rotate(inv_rot, dir);

    var t_min: f32 = 0.0;
    var t_far: f32 = floatMax(f32);
    var hit_axis: u32 = 0;
    var hit_sign: f32 = 1.0;

    for (0..3) |axis| {
        const o: f32 = vlane(local_origin, axis);
        const d: f32 = vlane(local_dir, axis);
        const lo: f32 = -vlane(half_extent, axis);
        const hi: f32 = vlane(half_extent, axis);
        if (@abs(d) < 1.0e-9) {
            if (o < lo or o > hi) {
                return null;
            } // parallel to the slab and outside it
        } else {
            const inv: f32 = 1.0 / d;
            var t_near: f32 = (lo - o) * inv;
            var t_far_axis: f32 = (hi - o) * inv;
            var face_sign: f32 = -1.0; // entering through the -axis face
            if (t_near > t_far_axis) {
                const swap: f32 = t_near;
                t_near = t_far_axis;
                t_far_axis = swap;
                face_sign = 1.0;
            }
            if (t_near > t_min) {
                t_min = t_near;
                hit_axis = @intCast(axis);
                hit_sign = face_sign;
            }
            if (t_far_axis < t_far) {
                t_far = t_far_axis;
            }
            if (t_min > t_far) {
                return null;
            }
        }
    }

    const local_normal: Vec = switch (hit_axis) {
        0 => vec(hit_sign, 0, 0),
        1 => vec(0, hit_sign, 0),
        else => vec(0, 0, hit_sign),
    };
    return .{ .fraction = t_min, .normal = rotate(rot, local_normal) };
}

fn rayVsCapsule(
    origin: Vec,
    dir: Vec,
    center: Vec,
    rot: Quat,
    half_height: f32,
    radius: f32,
) ?RayShapeHit {
    // Local frame (axis = local Y). A capsule is an infinite cylinder clipped to the
    // segment plus a hemisphere at each end; take the nearest valid surface hit.
    const inv_rot: Quat = conjugate(rot);
    const o: Vec = rotate(inv_rot, origin - center);
    const d: Vec = rotate(inv_rot, dir);

    var best_t: f32 = floatMax(f32);
    var best_normal_local: Vec = vec(0, 1, 0);

    // 1) Side: intersect the infinite cylinder about Y using the x,z lanes.
    const a: f32 = d[0] * d[0] + d[2] * d[2];
    if (a > 1.0e-12) {
        const b: f32 = o[0] * d[0] + o[2] * d[2];
        const c: f32 = o[0] * o[0] + o[2] * o[2] - radius * radius;
        const discriminant: f32 = b * b - a * c;
        if (discriminant >= 0.0) {
            const t: f32 = (-b - @sqrt(discriminant)) / a;
            if (t >= 0.0 and t < best_t) {
                const y: f32 = o[1] + t * d[1];
                if (y >= -half_height and y <= half_height) {
                    best_t = t;
                    best_normal_local = normalize3(vec(o[0] + t * d[0], 0, o[2] + t * d[2]));
                }
            }
        }
    }

    // 2) Ends: each cap hemisphere, accepting only the part beyond the segment end.
    const cap_centers = [_]f32{ half_height, -half_height };
    for (cap_centers) |cap_y| {
        const cap_center: Vec = vec(0, cap_y, 0);
        const m: Vec = o - cap_center;
        const b: f32 = dot3(m, d);
        const c: f32 = dot3(m, m) - radius * radius;
        const dd: f32 = dot3(d, d);
        const discriminant: f32 = b * b - dd * c;
        if (discriminant < 0.0) {
            continue;
        }
        const t: f32 = (-b - @sqrt(discriminant)) / dd;
        if (t < 0.0 or t >= best_t) {
            continue;
        }
        const hit_local: Vec = o + d * splat(t);
        const beyond_end: bool = (cap_y > 0.0 and hit_local[1] >= half_height) or
            (cap_y < 0.0 and hit_local[1] <= -half_height);
        if (beyond_end) {
            best_t = t;
            best_normal_local = normalize3(hit_local - cap_center);
        }
    }

    if (best_t == floatMax(f32)) {
        return null;
    }
    return .{ .fraction = best_t, .normal = rotate(rot, best_normal_local) };
}

fn rayVsShape(
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    origin: Vec,
    dir: Vec,
) ?RayShapeHit {
    return switch (shape.*) {
        .sphere => |s| rayVsSphere(origin, dir, pos, s.radius),
        .box => |b| rayVsBox(origin, dir, pos, rot, b.half_extent),
        .capsule => |c| rayVsCapsule(origin, dir, pos, rot, c.half_height, c.radius),
        else => null, // convex hull / compound ray queries not implemented yet
    };
}

/// Like castRayClosest, but for vehicle wheels: returns the closest hit whose surface normal passes the
/// max-slope test (normal . up > cos_max_slope_angle), so a near-vertical wall is skipped and a
/// valid floor behind it still registers. Faithful to Jolt's vehicle ray collector: a failing
/// hit does not update the closest distance, so it never hides a farther valid floor. Sensors are
/// excluded via the filter.
fn castRayVehicleFloor(
    // World is the central simulation hub: it owns a ContactListener whose callbacks
    // reference World back (a true World<->ContactListener cycle), and it is operated on
    // by ~66 free functions (this one included) threaded through the file by feature. No
    // declaration order resolves the listener cycle, and World sits after the subsystem
    // types it aggregates, so these earlier *World users forward-reference it.
    // lint:off decl-order: World<->ContactListener hub cycle (+66 free-fn operators)
    world: *const World,
    origin: Vec,
    direction: Vec,
    max_distance: f32,
    filter: QueryFilter,
    up: Vec,
    cos_max_slope_angle: f32,
) ?RayHit {
    const bp: *const BroadPhase = &world.broadphase;
    if (bp.root == BroadPhase.NULL_NODE) {
        return null;
    }
    const dir_len: f32 = length3(direction);
    if (dir_len < 1.0e-9) {
        return null;
    }
    const dir: Vec = direction / splat(dir_len);
    const inv_dir: Vec = splat(1.0) / dir;

    var closest: f32 = max_distance;
    var result: ?RayHit = null;

    var stack: BvhStack = .{};
    stack.push(bp.root);
    while (stack.pop()) |node_index| {
        if (node_index == BroadPhase.NULL_NODE) {
            continue;
        }
        const node: *const BroadPhase.Node = &bp.nodes.items[node_index];
        const enter: f32 = rayVsAabb(origin, inv_dir, node.aabb, closest) orelse continue;
        if (enter > closest) {
            continue;
        }
        if (BroadPhase.isLeaf(node)) {
            const idx: BodyIndex = node.body;
            const body: *const Body = &world.bodies.data[idx];
            if (!queryAllows(body, idx, filter)) {
                continue;
            }
            const shape: *const Shape = world.shapes.get(body.shape);
            const hit: RayShapeHit = rayVsShape(shape, body.com_pos, body.rot, origin, dir) orelse continue;
            // Accept only a closer hit whose normal is not a wall. Walls do not advance `closest`,
            // so a valid floor behind a wall is still found.
            const closer: bool = hit.fraction >= 0.0 and hit.fraction < closest;
            const not_wall: bool = dot3(hit.normal, up) > cos_max_slope_angle;
            if (closer and not_wall) {
                closest = hit.fraction;
                result = .{
                    .body = idx,
                    .fraction = hit.fraction / max_distance,
                    .distance = hit.fraction,
                    .point = origin + dir * splat(hit.fraction),
                    .normal = hit.normal,
                };
            }
        } else {
            stack.push(node.child1);
            stack.push(node.child2);
        }
    }
    return result;
}

/// Wheel basis vectors in body-local space (not rotated by the wheel's spin).
pub const WheelBasis = struct { forward: Vec, up: Vec, right: Vec };

/// Wheel basis in body-local space for a given steer angle (Jolt's GetWheelLocalBasis):
/// forward / up / right, not rotated by the wheel's spin.
fn vehicleWheelLocalBasis(s: *const WheelSettings, steer_angle: f32) WheelBasis {
    const steer: Quat = quatFromAxisAngle(s.steering_axis, steer_angle);
    const up0: Vec = rotate(steer, s.wheel_up);
    const fwd0: Vec = rotate(steer, s.wheel_forward);
    const right: Vec = normalize3(cross(fwd0, up0));
    const fwd: Vec = normalize3(cross(up0, right));
    return .{ .forward = fwd, .up = up0, .right = right };
}

/// Fill a wheel's contact-derived state once a tester has found a hit: the tire basis
/// (longitudinal/lateral), the axle contact plane, and the cached ground velocity. Shared by all
/// collision testers — only the hit body/point/normal/suspension-length differ between them.
fn setWheelContact(
    world: *const World,
    w: *Wheel,
    s: *const WheelSettings,
    rot: Quat,
    ws_origin: Vec,
    ws_direction: Vec,
    body: BodyIndex,
    point: Vec,
    normal: Vec,
    suspension_length: f32,
) void {
    w.contact_body = body;
    w.contact_position = point;
    w.contact_normal = normal;
    w.suspension_length = suspension_length;
    w.axle_plane_constant = dot3(normal, ws_origin + ws_direction * splat(suspension_length));

    // Longitudinal lies in the contact plane along the wheel forward; lateral is perpendicular.
    const basis: WheelBasis = vehicleWheelLocalBasis(s, w.steer_angle);
    const world_forward: Vec = rotate(rot, basis.forward);
    const world_right: Vec = rotate(rot, basis.right);
    var longitudinal: Vec = cross(normal, world_right);
    if (dot3(longitudinal, world_forward) < 0.0) {
        longitudinal = -longitudinal;
    }
    const llen: f32 = length3(longitudinal);
    longitudinal = if (llen > 1.0e-9) longitudinal / splat(llen) else normalizedPerpendicular(normal);
    w.contact_longitudinal = longitudinal;
    w.contact_lateral = normalize3(cross(longitudinal, normal));

    w.contact_point_velocity = world.getPointVelocity(body, point);
}

const VehicleShapeHit = struct { body: BodyIndex, fraction: f32, normal: Vec, point: Vec };

const ShapeCastContact = struct { fraction: f32, normal: Vec, point: Vec };

/// A Minkowski-difference vertex: w = support_A(dir) - support_B(-dir), with the two
/// witnesses kept so a contact point can be reconstructed by barycentric blend.
const Sup = struct { w: Vec, sa: Vec, sb: Vec };

const GjkResult = union(enum) {
    separated: struct { normal: Vec, pa: Vec, pb: Vec, dist: f32 },
    overlap: struct { simplex: [4]Sup, count: usize },
};

/// Core support point (convex radius EXCLUDED) of one shape, in world space.
fn supportCoreWorld(
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    dir: Vec,
) Vec {
    const local_dir: Vec = rotate(conjugate(rot), dir);
    const local_p: Vec = supportCore(shape, local_dir);
    return pos + rotate(rot, local_p);
}

fn minkSupport(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    dir: Vec,
) Sup {
    const sa: Vec = supportCoreWorld(shape_a, pos_a, rot_a, dir);
    const sb: Vec = supportCoreWorld(shape_b, pos_b, rot_b, -dir);
    return .{ .w = sa - sb, .sa = sa, .sb = sb };
}

const SimplexResult = struct {
    closest: Vec, // closest point of the simplex to the origin
    enclosed: bool, // origin is inside the tetrahedron
    count: usize, // surviving vertex count (simplex compacted to [0..count))
    bary: [4]f32, // weights of the surviving vertices
};

/// Barycentric weights of the closest point on segment AB to the ORIGIN.
fn baryClosestSegment(a: Vec, b: Vec) [2]f32 {
    const ab: Vec = b - a;
    const denom: f32 = dot3(ab, ab);
    const t: f32 = if (denom > 1.0e-12) clamp(-dot3(a, ab) / denom, 0.0, 1.0) else 0.0;
    return .{ 1.0 - t, t };
}

/// Barycentric weights (one per vertex) of the point on triangle ABC closest to the
/// ORIGIN. This is Ericson "Real-Time Collision Detection" 5.1.5 specialised to the
/// query point P = origin, so every "P - vertex" term becomes "-vertex". The routine
/// walks the Voronoi regions of the triangle: first the three vertex regions, then
/// the three edge regions, and finally the face interior.
fn baryClosestTriangle(a: Vec, b: Vec, c: Vec) [3]f32 {
    const edge_ab: Vec = b - a;
    const edge_ac: Vec = c - a;

    const a_to_origin: Vec = -a;
    const ab_dot_ao: f32 = dot3(edge_ab, a_to_origin);
    const ac_dot_ao: f32 = dot3(edge_ac, a_to_origin);
    // Origin is in the Voronoi region behind vertex A.
    if (ab_dot_ao <= 0.0 and ac_dot_ao <= 0.0) {
        return .{ 1.0, 0.0, 0.0 };
    }

    const b_to_origin: Vec = -b;
    const ab_dot_bo: f32 = dot3(edge_ab, b_to_origin);
    const ac_dot_bo: f32 = dot3(edge_ac, b_to_origin);
    // Origin is in the Voronoi region behind vertex B.
    if (ab_dot_bo >= 0.0 and ac_dot_bo <= ab_dot_bo) {
        return .{ 0.0, 1.0, 0.0 };
    }

    // Region of edge AB: the determinant is <= 0 and the origin projects onto the edge.
    const edge_ab_region: f32 = ab_dot_ao * ac_dot_bo - ab_dot_bo * ac_dot_ao;
    if (edge_ab_region <= 0.0 and ab_dot_ao >= 0.0 and ab_dot_bo <= 0.0) {
        const t_ab: f32 = ab_dot_ao / (ab_dot_ao - ab_dot_bo);
        return .{ 1.0 - t_ab, t_ab, 0.0 };
    }

    const c_to_origin: Vec = -c;
    const ab_dot_co: f32 = dot3(edge_ab, c_to_origin);
    const ac_dot_co: f32 = dot3(edge_ac, c_to_origin);
    // Origin is in the Voronoi region behind vertex C.
    if (ac_dot_co >= 0.0 and ab_dot_co <= ac_dot_co) {
        return .{ 0.0, 0.0, 1.0 };
    }

    // Region of edge AC.
    const edge_ac_region: f32 = ab_dot_co * ac_dot_ao - ab_dot_ao * ac_dot_co;
    if (edge_ac_region <= 0.0 and ac_dot_ao >= 0.0 and ac_dot_co <= 0.0) {
        const t_ac: f32 = ac_dot_ao / (ac_dot_ao - ac_dot_co);
        return .{ 1.0 - t_ac, 0.0, t_ac };
    }

    // Region of edge BC.
    const edge_bc_region: f32 = ab_dot_bo * ac_dot_co - ab_dot_co * ac_dot_bo;
    const bc_start: f32 = ac_dot_bo - ab_dot_bo;
    const bc_end: f32 = ab_dot_co - ac_dot_co;
    if (edge_bc_region <= 0.0 and bc_start >= 0.0 and bc_end >= 0.0) {
        const t_bc: f32 = bc_start / (bc_start + bc_end);
        return .{ 0.0, 1.0 - t_bc, t_bc };
    }

    // Interior: the three edge determinants are the unnormalised barycentric weights.
    const region_total: f32 = edge_ab_region + edge_ac_region + edge_bc_region;
    const inv_total: f32 = 1.0 / region_total;
    const bary_b: f32 = edge_ac_region * inv_total;
    const bary_c: f32 = edge_ab_region * inv_total;
    return .{ 1.0 - bary_b - bary_c, bary_b, bary_c };
}

/// Drop zero-weight vertices from a simplex, compacting the survivors to the front.
fn compactSimplex(
    simplex: *[4]Sup,
    weights: [4]f32,
    input_count: usize,
    closest: Vec,
    enclosed: bool,
) SimplexResult {
    var kept_count: usize = 0;
    var kept_weights: [4]f32 = .{ 0, 0, 0, 0 };
    var kept: [4]Sup = undefined;
    var source_index: usize = 0;
    while (source_index < input_count) : (source_index += 1) {
        if (weights[source_index] != 0.0) {
            kept[kept_count] = simplex[source_index];
            kept_weights[kept_count] = weights[source_index];
            kept_count += 1;
        }
    }
    var write_index: usize = 0;
    while (write_index < kept_count) : (write_index += 1) simplex[write_index] = kept[write_index];
    return .{ .closest = closest, .enclosed = enclosed, .count = kept_count, .bary = kept_weights };
}

/// Reduce a 1..4-vertex simplex to the sub-simplex closest to the origin, compacting
/// the surviving vertices to the front of `simplex` and returning their weights and
/// the closest point. The classic GJK "do-simplex" with witness barycentrics.
fn doSimplex(simplex: *[4]Sup, vertex_count: usize) SimplexResult {
    switch (vertex_count) {
        1 => {
            return .{ .closest = simplex[0].w, .enclosed = false, .count = 1, .bary = .{ 1, 0, 0, 0 } };
        },
        2 => {
            const weights: [2]f32 = baryClosestSegment(simplex[0].w, simplex[1].w);
            const closest_point: Vec = simplex[0].w * splat(weights[0]) +
                simplex[1].w * splat(weights[1]);
            if (weights[1] == 0.0) {
                return .{
                    .closest = closest_point,
                    .enclosed = false,
                    .count = 1,
                    .bary = .{ 1, 0, 0, 0 },
                };
            }
            if (weights[0] == 0.0) {
                simplex[0] = simplex[1];
                return .{ .closest = closest_point, .enclosed = false, .count = 1, .bary = .{ 1, 0, 0, 0 } };
            }
            return .{
                .closest = closest_point,
                .enclosed = false,
                .count = 2,
                .bary = .{ weights[0], weights[1], 0, 0 },
            };
        },
        3 => {
            const weights: [3]f32 = baryClosestTriangle(simplex[0].w, simplex[1].w, simplex[2].w);
            const closest_point: Vec =
                simplex[0].w * splat(weights[0]) +
                simplex[1].w * splat(weights[1]) +
                simplex[2].w * splat(weights[2]);
            return compactSimplex(
                simplex,
                .{ weights[0], weights[1], weights[2], 0 },
                3,
                closest_point,
                false,
            );
        },
        4 => {
            // The origin's closest feature lies on whichever tetra face it sits
            // outside of; pick the nearest such face. If the origin is inside all
            // four faces it is enclosed by the simplex, which means the shapes overlap.
            const tetra_faces = [_][3]usize{ .{ 0, 1, 2 }, .{ 0, 1, 3 }, .{ 0, 2, 3 }, .{ 1, 2, 3 } };
            const opposite_vertex = [_]usize{ 3, 2, 1, 0 };

            var any_face_outside: bool = false;
            var best_distance_sq: f32 = floatMax(f32);
            var best_weights: [4]f32 = .{ 0, 0, 0, 0 };
            var best_indices: [3]usize = .{ 0, 1, 2 };

            var face_index: usize = 0;
            while (face_index < 4) : (face_index += 1) {
                const index_a: usize = tetra_faces[face_index][0];
                const index_b: usize = tetra_faces[face_index][1];
                const index_c: usize = tetra_faces[face_index][2];
                const vertex_a: Vec = simplex[index_a].w;
                const vertex_b: Vec = simplex[index_b].w;
                const vertex_c: Vec = simplex[index_c].w;
                const opposite_point: Vec = simplex[opposite_vertex[face_index]].w;

                const face_normal_raw: Vec = cross(vertex_b - vertex_a, vertex_c - vertex_a);
                const points_toward_opposite: f32 = dot3(face_normal_raw, opposite_point - vertex_a);
                const outward_normal: Vec = if (points_toward_opposite > 0.0)
                    -face_normal_raw
                else
                    face_normal_raw;
                // distance of the origin past the face plane; sign follows (origin - a) . outward
                const origin_outside_distance: f32 = dot3(outward_normal, -vertex_a);
                if (origin_outside_distance > 0.0) {
                    any_face_outside = true;
                    const face_weights: [3]f32 = baryClosestTriangle(vertex_a, vertex_b, vertex_c);
                    const candidate_point: Vec =
                        vertex_a * splat(face_weights[0]) +
                        vertex_b * splat(face_weights[1]) +
                        vertex_c * splat(face_weights[2]);
                    const candidate_distance_sq: f32 = lengthSq3(candidate_point);
                    if (candidate_distance_sq < best_distance_sq) {
                        best_distance_sq = candidate_distance_sq;
                        best_weights = .{ face_weights[0], face_weights[1], face_weights[2], 0 };
                        best_indices = .{ index_a, index_b, index_c };
                    }
                }
            }

            if (!any_face_outside) {
                return .{ .closest = vec_zero, .enclosed = true, .count = 4, .bary = .{ 0, 0, 0, 0 } };
            }

            // Compact the simplex down to the winning face's three vertices.
            const kept_vertices: [3]Sup = .{
                simplex[best_indices[0]],
                simplex[best_indices[1]],
                simplex[best_indices[2]],
            };
            simplex[0] = kept_vertices[0];
            simplex[1] = kept_vertices[1];
            simplex[2] = kept_vertices[2];
            const closest_point: Vec =
                kept_vertices[0].w * splat(best_weights[0]) +
                kept_vertices[1].w * splat(best_weights[1]) +
                kept_vertices[2].w * splat(best_weights[2]);
            return compactSimplex(simplex, best_weights, 3, closest_point, false);
        },
        else => unreachable,
    }
}

/// Reconstruct the separated result (witness points on each core + A->B normal) from
/// a reduced simplex. closest = witness_a - witness_b, so normal A->B = normalize(-closest).
fn separatedFromSimplex(simplex: *[4]Sup, result: SimplexResult) GjkResult {
    var witness_a: Vec = vec_zero;
    var witness_b: Vec = vec_zero;
    var vertex_index: usize = 0;
    while (vertex_index < result.count) : (vertex_index += 1) {
        witness_a += simplex[vertex_index].sa * splat(result.bary[vertex_index]);
        witness_b += simplex[vertex_index].sb * splat(result.bary[vertex_index]);
    }
    const difference: Vec = witness_a - witness_b;
    const dist: f32 = length3(difference);
    const normal: Vec = if (dist > 1.0e-9) -difference / splat(dist) else vec(0, 1, 0);
    return .{ .separated = .{ .normal = normal, .pa = witness_a, .pb = witness_b, .dist = dist } };
}

/// GJK distance between the two cores. Returns the closest points (and the A->B
/// normal + core distance) when separated, or the enclosing simplex when the cores
/// overlap (hand off to EPA).
fn gjkCores(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
) GjkResult {
    var simplex: [4]Sup = undefined;
    var vertex_count: usize = 0;

    var search_dir: Vec = pos_b - pos_a; // A -> B
    if (lengthSq3(search_dir) < 1.0e-12) {
        search_dir = vec(1, 0, 0);
    }

    simplex[0] = minkSupport(shape_a, pos_a, rot_a, shape_b, pos_b, rot_b, search_dir);
    vertex_count = 1;
    search_dir = -simplex[0].w;

    var iter: u32 = 0;
    while (iter < 32) : (iter += 1) {
        if (lengthSq3(search_dir) < 1.0e-14) {
            // Origin lies on the simplex: cores just touch -> treat as overlap so EPA
            // (or its degenerate single-point result) supplies a normal.
            return .{ .overlap = .{ .simplex = simplex, .count = vertex_count } };
        }

        const support: Sup = minkSupport(shape_a, pos_a, rot_a, shape_b, pos_b, rot_b, search_dir);

        // No vertex past the origin along the search direction => cores are separated.
        if (dot3(support.w, search_dir) < 0.0) {
            const simplex_result: SimplexResult = doSimplex(&simplex, vertex_count);
            return separatedFromSimplex(&simplex, simplex_result);
        }

        simplex[vertex_count] = support;
        vertex_count += 1;

        const simplex_result: SimplexResult = doSimplex(&simplex, vertex_count);
        if (simplex_result.enclosed) {
            return .{ .overlap = .{ .simplex = simplex, .count = 4 } };
        }
        vertex_count = simplex_result.count;
        search_dir = -simplex_result.closest;
    }

    // Iteration cap: report the best separation we have.
    const simplex_result: SimplexResult = doSimplex(&simplex, vertex_count);
    return separatedFromSimplex(&simplex, simplex_result);
}

const EpaResult = struct { normal: Vec, depth: f32, pa: Vec, pb: Vec };

/// Ensure the polytope has 4 non-degenerate vertices enclosing the origin, by
/// sampling supports along axes orthogonal to whatever the GJK seed gave us.
fn buildInitialTetra(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    verts: *[64]Sup,
    vertex_count: *usize,
) bool {
    const search_dirs = [_]Vec{
        vec(1, 0, 0), vec(-1, 0, 0),
        vec(0, 1, 0), vec(0, -1, 0),
        vec(0, 0, 1), vec(0, 0, -1),
    };
    var dir_index: usize = 0;
    while (vertex_count.* < 4 and dir_index < search_dirs.len) : (dir_index += 1) {
        const candidate: Sup = minkSupport(
            shape_a,
            pos_a,
            rot_a,
            shape_b,
            pos_b,
            rot_b,
            search_dirs[dir_index],
        );
        var is_duplicate: bool = false;
        var existing_index: usize = 0;
        while (existing_index < vertex_count.*) : (existing_index += 1) {
            if (lengthSq3(candidate.w - verts[existing_index].w) < 1.0e-10) {
                is_duplicate = true;
                break;
            }
        }
        if (!is_duplicate) {
            verts[vertex_count.*] = candidate;
            vertex_count.* += 1;
        }
    }
    return vertex_count.* >= 4;
}

const EpaFace = struct { a: usize, b: usize, c: usize, normal: Vec, dist: f32 };

fn makeFace(
    verts: []const Sup,
    index_a: usize,
    index_b: usize,
    index_c: usize,
    centroid: Vec,
) EpaFace {
    const vertex_a: Vec = verts[index_a].w;
    const vertex_b: Vec = verts[index_b].w;
    const vertex_c: Vec = verts[index_c].w;
    var face_normal: Vec = cross(vertex_b - vertex_a, vertex_c - vertex_a);
    const normal_len: f32 = length3(face_normal);
    face_normal = if (normal_len > 1.0e-12) face_normal / splat(normal_len) else vec(0, 1, 0);
    if (dot3(face_normal, vertex_a - centroid) < 0.0) {
        face_normal = -face_normal;
    } // make it point outward
    const plane_distance: f32 = @max(0.0, dot3(face_normal, vertex_a));
    return .{ .a = index_a, .b = index_b, .c = index_c, .normal = face_normal, .dist = plane_distance };
}

fn reconstructEpa(
    verts: []const Sup,
    index_a: usize,
    index_b: usize,
    index_c: usize,
    normal: Vec,
) EpaResult {
    const weights: [3]f32 = baryClosestTriangle(verts[index_a].w, verts[index_b].w, verts[index_c].w);
    const weight_a: Vec = splat(weights[0]);
    const weight_b: Vec = splat(weights[1]);
    const weight_c: Vec = splat(weights[2]);
    // Map the barycentric closest point on the polytope face back to each core's surface.
    const witness_a: Vec = verts[index_a].sa * weight_a +
        verts[index_b].sa * weight_b +
        verts[index_c].sa * weight_c;
    const witness_b: Vec = verts[index_a].sb * weight_a +
        verts[index_b].sb * weight_b +
        verts[index_c].sb * weight_c;
    const penetration_depth: f32 = dot3(witness_a - witness_b, normal); // cores overlap by this along A->B
    return .{ .normal = normal, .depth = penetration_depth, .pa = witness_a, .pb = witness_b };
}

/// Maintain a horizon as a set of edges; an edge seen twice (in opposite directions)
/// is interior and cancels out.
fn addHorizonEdge(
    horizon: *[256][2]usize,
    edge_count: *usize,
    edge_start: usize,
    edge_end: usize,
) void {
    var existing_index: usize = 0;
    while (existing_index < edge_count.*) : (existing_index += 1) {
        if (horizon[existing_index][0] == edge_end and horizon[existing_index][1] == edge_start) {
            horizon[existing_index] = horizon[edge_count.* - 1];
            edge_count.* -= 1;
            return;
        }
    }
    if (edge_count.* < 256) {
        horizon[edge_count.*] = .{ edge_start, edge_end };
        edge_count.* += 1;
    }
}

/// EPA penetration depth on the cores. Expands the GJK simplex into a polytope and
/// grows it toward the closest face until the support stops making progress; that
/// face's normal is the minimum translation direction and its barycentric closest
/// point reconstructs the witnesses. Bounded polytope, bounded iterations.
fn epaCores(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    seed: [4]Sup,
    seed_count: usize,
) ?EpaResult {
    const max_verts: usize = 64;
    const max_faces: usize = 128;

    var verts: [max_verts]Sup = undefined;
    var vertex_count: usize = 0;

    // Seed the polytope with the GJK simplex, then blow it up to a tetrahedron if it
    // came in degenerate (touching cases give 1-3 vertices).
    var seed_index: usize = 0;
    while (seed_index < seed_count) : (seed_index += 1) {
        verts[vertex_count] = seed[seed_index];
        vertex_count += 1;
    }
    if (!buildInitialTetra(shape_a, pos_a, rot_a, shape_b, pos_b, rot_b, &verts, &vertex_count)) {
        return null;
    }

    const Face = EpaFace;
    var faces: [max_faces]Face = undefined;
    var face_count: usize = 0;

    // Seed faces = the 4 tetra faces, each oriented so its normal points away from the
    // centroid (outward), with dist = distance from the origin to the face plane.
    const centroid: Vec = (verts[0].w + verts[1].w + verts[2].w + verts[3].w) * splat(0.25);
    const tetra_faces = [_][3]usize{ .{ 0, 1, 2 }, .{ 0, 1, 3 }, .{ 0, 2, 3 }, .{ 1, 2, 3 } };
    {
        var seed_face: usize = 0;
        while (seed_face < 4) : (seed_face += 1) {
            const live_verts: []const Sup = verts[0..vertex_count];
            const idx0: usize = tetra_faces[seed_face][0];
            const idx1: usize = tetra_faces[seed_face][1];
            const idx2: usize = tetra_faces[seed_face][2];
            faces[face_count] = makeFace(live_verts, idx0, idx1, idx2, centroid);
            face_count += 1;
        }
    }

    var iter: u32 = 0;
    while (iter < 48) : (iter += 1) {
        // Find the face closest to the origin.
        var best_face_index: usize = 0;
        var best_face_dist: f32 = floatMax(f32);
        {
            var face_index: usize = 0;
            while (face_index < face_count) : (face_index += 1) {
                if (faces[face_index].dist < best_face_dist) {
                    best_face_dist = faces[face_index].dist;
                    best_face_index = face_index;
                }
            }
        }

        const best_normal: Vec = faces[best_face_index].normal;
        const support: Sup = minkSupport(shape_a, pos_a, rot_a, shape_b, pos_b, rot_b, best_normal);
        const support_dist: f32 = dot3(support.w, best_normal);

        const converged: bool = support_dist - best_face_dist < 1.0e-4;
        const out_of_room: bool = vertex_count >= max_verts or face_count + 8 >= max_faces;
        if (converged or out_of_room) {
            // Converged: this face is the minimum translation plane.
            const best_face: Face = faces[best_face_index];
            return reconstructEpa(verts[0..vertex_count], best_face.a, best_face.b, best_face.c, best_normal);
        }

        // Remove every face the new point can "see"; collect the horizon edges.
        const new_vertex_index: usize = vertex_count;
        verts[vertex_count] = support;
        vertex_count += 1;

        var horizon_edges: [256][2]usize = undefined;
        var horizon_count: usize = 0;

        var face_index: usize = 0;
        while (face_index < face_count) {
            const face: Face = faces[face_index];
            const is_visible: bool = dot3(face.normal, support.w - verts[face.a].w) > 0.0;
            if (is_visible) {
                addHorizonEdge(&horizon_edges, &horizon_count, face.a, face.b);
                addHorizonEdge(&horizon_edges, &horizon_count, face.b, face.c);
                addHorizonEdge(&horizon_edges, &horizon_count, face.c, face.a);
                faces[face_index] = faces[face_count - 1]; // swap-remove
                face_count -= 1;
            } else {
                face_index += 1;
            }
        }

        // Stitch new faces from each horizon edge to the new vertex.
        var horizon_index: usize = 0;
        while (horizon_index < horizon_count) : (horizon_index += 1) {
            if (face_count >= max_faces) {
                break;
            }
            const live_verts: []const Sup = verts[0..vertex_count];
            const edge_start: usize = horizon_edges[horizon_index][0];
            const edge_end: usize = horizon_edges[horizon_index][1];
            faces[face_count] = makeFace(live_verts, edge_start, edge_end, new_vertex_index, centroid);
            face_count += 1;
        }
    }

    // Iteration cap: return the current closest face.
    var best_face_index: usize = 0;
    var best_face_dist: f32 = floatMax(f32);
    var face_index: usize = 0;
    while (face_index < face_count) : (face_index += 1) {
        if (faces[face_index].dist < best_face_dist) {
            best_face_dist = faces[face_index].dist;
            best_face_index = face_index;
        }
    }
    const closest_face: Face = faces[best_face_index];
    const live_verts: []const Sup = verts[0..vertex_count];
    return reconstructEpa(live_verts, closest_face.a, closest_face.b, closest_face.c, closest_face.normal);
}

/// Like shapeCastCores but also returns the contact normal and point. Conservative advancement on
/// the cores; at the contact it reconstructs the surface contact from the GJK/EPA witnesses
/// (B's witness offset out by B's convex radius) and flips the A->B normal to point toward A.
fn shapeCastCoresContact(
    shape_a: *const Shape,
    start_pos: Vec,
    rot_a: Quat,
    displacement: Vec,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    r1: f32,
    r2: f32,
    tolerance: f32,
) ?ShapeCastContact {
    if (lengthSq3(displacement) < 1.0e-18) {
        return null;
    }
    var t: f32 = 0.0;
    var iter: u32 = 0;
    while (iter < 32) : (iter += 1) {
        const pos_t: Vec = start_pos + displacement * splat(t);
        switch (gjkCores(shape_a, pos_t, rot_a, shape_b, pos_b, rot_b)) {
            .overlap => |ov| {
                // Cores already touch/penetrate: EPA gives the A->B normal and witnesses.
                const epa: EpaResult = epaCores(
                    shape_a,
                    pos_t,
                    rot_a,
                    shape_b,
                    pos_b,
                    rot_b,
                    ov.simplex,
                    ov.count,
                ) orelse return null;
                return .{ .fraction = t, .normal = -epa.normal, .point = epa.pb - epa.normal * splat(r2) };
            },
            .separated => |sep| {
                const real_dist: f32 = sep.dist - r1 - r2;
                if (real_dist < tolerance) {
                    return .{
                        .fraction = t,
                        .normal = -sep.normal,
                        .point = sep.pb - sep.normal * splat(r2),
                    };
                }
                const closing: f32 = dot3(displacement, sep.normal); // normal is A -> B
                if (closing <= 1.0e-9) {
                    return null;
                } // not approaching B
                t += real_dist / closing;
                if (t >= 1.0) {
                    return null;
                } // contact is beyond this step
            },
        }
    }
    return null;
}

/// Sweep `shape` from (`pos`,`rot`) along `direction` for `max_distance` and return the closest
/// hit whose normal passes the max-slope test (pass cos_max_slope_angle <= -2 to accept any
/// normal, as the cylinder tester does). Scratch-free: a fixed-stack broadphase walk (like
/// castRayClosest) plus the allocation-free GJK/EPA cores cast per candidate body.
fn castShapeVehicleFloor(
    world: *const World,
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    direction: Vec,
    max_distance: f32,
    filter: QueryFilter,
    up: Vec,
    cos_max_slope_angle: f32,
) ?VehicleShapeHit {
    const bp: *const BroadPhase = &world.broadphase;
    if (bp.root == BroadPhase.NULL_NODE) {
        return null;
    }
    const dir_len: f32 = length3(direction);
    if (dir_len < 1.0e-9) {
        return null;
    }
    const displacement: Vec = direction * splat(max_distance / dir_len);

    const local_bounds: Aabb = shapeLocalBounds(shape);
    const start_bounds: Aabb = transformAabb(local_bounds, pos, rot);
    const end_bounds: Aabb = .{
        .min = start_bounds.min + displacement,
        .max = start_bounds.max + displacement,
    };
    const swept: Aabb = start_bounds.combine(end_bounds).expandedBy(world.settings.speculative_distance);

    const self_radius: f32 = convexRadius(shape);
    var closest: f32 = 1.0;
    var result: ?VehicleShapeHit = null;

    var stack: BvhStack = .{};
    stack.push(bp.root);
    while (stack.pop()) |node_index| {
        if (node_index == BroadPhase.NULL_NODE) {
            continue;
        }
        const node: *const BroadPhase.Node = &bp.nodes.items[node_index];
        if (!node.aabb.overlaps(swept)) {
            continue;
        }
        if (BroadPhase.isLeaf(node)) {
            const idx: BodyIndex = node.body;
            const body: *const Body = &world.bodies.data[idx];
            if (!queryAllows(body, idx, filter)) {
                continue;
            }
            const other: *const Shape = world.shapes.get(body.shape);
            const contact: ShapeCastContact = shapeCastCoresContact(
                shape,
                pos,
                rot,
                displacement,
                other,
                body.com_pos,
                body.rot,
                self_radius,
                convexRadius(other),
                world.settings.penetration_slop,
            ) orelse continue;
            // Accept the closest hit that is not a wall; a failing hit does not advance `closest`.
            if (contact.fraction < closest and dot3(contact.normal, up) > cos_max_slope_angle) {
                closest = contact.fraction;
                result = .{
                    .body = idx,
                    .fraction = contact.fraction,
                    .normal = contact.normal,
                    .point = contact.point,
                };
            }
        } else {
            stack.push(node.child1);
            stack.push(node.child2);
        }
    }
    return result;
}

/// Per-step scratch describing a differential that has at least one wheel.
const DrivenDifferential = struct {
    diff_index: usize, // into the vehicle's differentials
    angular_velocity: f32, // |average wheel omega * ratio|
    clutch_to_differential_torque_ratio: f32,
    temp_torque_factor: f32,
};

/// Per-step scratch describing a wheel that the engine drives through a differential.
const DrivenWheel = struct {
    wheel_index: usize, // into the vehicle's wheels
    clutch_to_wheel_ratio: f32, // transmission_ratio * differential_ratio
    clutch_to_wheel_torque_ratio: f32, // fraction of engine torque this wheel gets
    estimated_angular_impulse: f32, // external (brake + ground) angular impulse this step
};

/// The point where a wheel's suspension/traction forces apply, expressed relative to each
/// body's centre of mass (Jolt's CalculateSuspensionForcePoint output).
const VehicleForcePoint = struct { r1_plus_u: Vec, r2: Vec };

/// World-space suspension/traction force point for a wheel, relative to each body's COM
/// (Jolt's CalculateSuspensionForcePoint). `com`/`rot`/`shape_com` are the chassis transform
/// pieces; force point is the body-local force point (if enabled) or the contact position.
fn vehicleSuspensionForcePoint(
    world: *const World,
    w: *const Wheel,
    com: Vec,
    rot: Quat,
    shape_com: Vec,
) VehicleForcePoint {
    const s: *const WheelSettings = &w.settings;
    const force_point: Vec = if (s.enable_suspension_force_point)
        com + rotate(rot, s.suspension_force_point - shape_com)
    else
        w.contact_position;
    const contact_com: Vec = world.bodies.data[w.contact_body].com_pos;
    return .{ .r1_plus_u = force_point - com, .r2 = force_point - contact_com };
}

/// A runtime vehicle: the chassis body plus its wheels and the ground-collision tester. Built
/// on the World; the caller owns it (call deinit). Jolt's VehicleConstraint.
pub const Vehicle = struct {
    body: BodyIndex,
    forward: Vec, // body-local forward
    up: Vec, // body-local up
    world_up: Vec, // -gravity, refreshed each collideWheels (for pitch/roll, later)
    cos_max_pitch_roll_angle: f32,
    wheels: []Wheel, // owned
    tester: VehicleCollisionTester,
    allocator: std.mem.Allocator,

    pitch_roll_part: AngleConstraintPart, // anti-topple constraint, chassis vs fixed-to-world
    cos_pitch_roll_angle: f32, // cos of the current pitch/roll angle (set during setup)
    pitch_roll_rotation_axis: Vec, // axis to rotate the chassis back toward upright

    // Driver inputs (set via setDriverInput). Throttle is stored for the Phase 4 powertrain;
    // in Phase 3 the wheels free-roll and brake/steer drive the dynamics.
    forward_input: f32 = 0.0, // throttle/reverse, [-1, 1]
    right_input: f32 = 0.0, // steer, [-1, 1] (+ = right)
    brake_input: f32 = 0.0, // [0, 1]
    hand_brake_input: f32 = 0.0, // [0, 1]

    // Powertrain: engine -> transmission -> differentials -> wheels.
    engine: VehicleEngine = .{},
    transmission: VehicleTransmission = .{},
    differentials: [8]VehicleDifferentialSettings = @splat(.{}),
    differential_count: usize = 0,
    differential_limited_slip_ratio: f32 = floatMax(f32), // across differentials
    previous_delta_time: f32 = 0.0, // for scaling the estimated ground impulse in the clutch solve
    anti_roll_bars: [8]VehicleAntiRollBar = @splat(.{}),
    anti_roll_bar_count: usize = 0,
    lean: ?MotorcycleLean = null, // motorcycle lean controller (null = ordinary wheeled vehicle)
    tracks: ?[2]VehicleTrack = null, // tracked (tank) controller (null = wheeled); replaces differentials
    left_ratio: f32 = 1.0, // tracked steering: left-track speed multiplier (never 0)
    right_ratio: f32 = 1.0, // tracked steering: right-track speed multiplier (never 0)

    /// Build a vehicle for chassis `body` from `settings` (one Wheel per wheel setting). The
    /// caller owns the result; deinit frees the wheels.
    pub fn init(
        gpa: std.mem.Allocator,
        body: BodyIndex,
        settings: VehicleSettings,
        tester: VehicleCollisionTester,
    ) !Vehicle {
        const wheels: []Wheel = try gpa.alloc(Wheel, settings.wheels.len);
        var i: usize = 0;
        while (i < settings.wheels.len) : (i += 1) {
            wheels[i] = .{ .settings = settings.wheels[i] };
        }
        // Copy the differential configuration into the inline array and start the engine at idle.
        var diffs: [8]VehicleDifferentialSettings = @splat(.{});
        const diff_count: usize = @min(settings.differentials.len, diffs.len);
        var di: usize = 0;
        while (di < diff_count) : (di += 1) diffs[di] = settings.differentials[di];
        var bars: [8]VehicleAntiRollBar = @splat(.{});
        const bar_count: usize = @min(settings.anti_roll_bars.len, bars.len);
        var bi: usize = 0;
        while (bi < bar_count) : (bi += 1) bars[bi] = settings.anti_roll_bars[bi];
        var engine: VehicleEngine = settings.engine;
        engine.current_rpm = engine.min_rpm;
        return .{
            .body = body,
            .forward = settings.forward,
            .up = settings.up,
            .world_up = settings.up,
            .cos_max_pitch_roll_angle = @cos(settings.max_pitch_roll_angle),
            .wheels = wheels,
            .tester = tester,
            .allocator = gpa,
            .pitch_roll_part = AngleConstraintPart.inactive,
            .cos_pitch_roll_angle = 1.0,
            .pitch_roll_rotation_axis = .{ 0.0, 1.0, 0.0, 0.0 },
            .engine = engine,
            .transmission = settings.transmission,
            .differentials = diffs,
            .differential_count = diff_count,
            .differential_limited_slip_ratio = settings.differential_limited_slip_ratio,
            .anti_roll_bars = bars,
            .anti_roll_bar_count = bar_count,
            .lean = settings.lean,
            .tracks = settings.tracks,
        };
    }

    pub fn deinit(self: *Vehicle) void {
        self.allocator.free(self.wheels);
    }

    /// Number of wheels.
    pub fn wheelCount(self: *const Vehicle) usize {
        return self.wheels.len;
    }

    /// Collide every wheel against the ground and fill its contact data, suspension length and
    /// tire basis (Jolt's VehicleConstraint::OnStep collision pass). Call once per step before
    /// solving. Also refreshes world_up from gravity.
    pub fn collideWheels(self: *Vehicle, world: *const World) void {
        // World up = -gravity, so pitch/roll is measured against true up.
        const g: Vec = world.gravity;
        const glen: f32 = length3(g);
        if (glen > 1.0e-9) {
            self.world_up = (-g) / splat(glen);
        }

        switch (self.tester) {
            .ray => |tester| self.collideWheelsRay(world, tester),
            .cast_sphere => |tester| self.collideWheelsCastSphere(world, tester),
            .cast_cylinder => |tester| self.collideWheelsCastCylinder(world, tester),
        }
    }

    fn collideWheelsRay(
        self: *Vehicle,
        world: *const World,
        tester: VehicleCollisionTester.RayTester,
    ) void {
        const body: *const Body = &world.bodies.data[self.body];
        const com: Vec = body.com_pos;
        const rot: Quat = body.rot;
        const shape: *const Shape = world.shapes.get(body.shape);
        const shape_com: Vec = shapeCenterOfMass(shape);

        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            const s: *const WheelSettings = &w.settings;

            // Suspension origin (a body-local, origin-relative point) and direction in world space.
            // World position of a body-local point p is com + R*(p - shapeCOM).
            const ws_origin: Vec = com + rotate(rot, s.position - shape_com);
            const ws_direction: Vec = rotate(rot, s.suspension_direction);

            // Reset to "no contact", then cast a ray of length (max suspension + radius) down.
            w.contact_body = none_body;
            w.suspension_length = s.suspension_max_length;

            const ray_length: f32 = s.suspension_max_length + s.radius;
            const filter: QueryFilter = .{
                .mask = tester.object_mask,
                .exclude = self.body,
                .include_sensors = false,
            };
            const maybe_hit: ?RayHit = castRayVehicleFloor(
                world,
                ws_origin,
                ws_direction,
                ray_length,
                filter,
                tester.up,
                tester.cos_max_slope_angle,
            );

            if (maybe_hit) |hit| {
                // castRayVehicleFloor already returned the closest hit that passes the max-slope
                // test, so near-vertical walls are skipped and a valid floor behind them is found.
                // fraction is the hit distance along the unit ray; subtract the wheel radius.
                const suspension_length: f32 = @max(0.0, hit.distance - s.radius);
                setWheelContact(
                    world,
                    w,
                    s,
                    rot,
                    ws_origin,
                    ws_direction,
                    hit.body,
                    hit.point,
                    hit.normal,
                    suspension_length,
                );
            }
        }
    }

    /// Sphere-cast each wheel against the ground (Jolt's VehicleCollisionTesterCastSphere). The
    /// sphere rolls over edges/cracks a ray would fall into. Closest valid (slope-passing) hit.
    fn collideWheelsCastSphere(
        self: *Vehicle,
        world: *const World,
        tester: VehicleCollisionTester.CastSphereTester,
    ) void {
        const body: *const Body = &world.bodies.data[self.body];
        const com: Vec = body.com_pos;
        const rot: Quat = body.rot;
        const shape: *const Shape = world.shapes.get(body.shape);
        const shape_com: Vec = shapeCenterOfMass(shape);
        const sphere: Shape = .{ .sphere = .{ .radius = tester.radius } };

        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            const s: *const WheelSettings = &w.settings;
            const ws_origin: Vec = com + rotate(rot, s.position - shape_com);
            const ws_direction: Vec = rotate(rot, s.suspension_direction);

            w.contact_body = none_body;
            w.suspension_length = s.suspension_max_length;

            // The cast sphere carries its own radius, so the sweep is shortened by (wheel − sphere).
            const cast_length: f32 = s.suspension_max_length + s.radius - tester.radius;
            if (cast_length <= 0.0) {
                continue;
            }
            const filter: QueryFilter = .{
                .mask = tester.object_mask,
                .exclude = self.body,
                .include_sensors = false,
            };
            const maybe_hit: ?VehicleShapeHit = castShapeVehicleFloor(
                world,
                &sphere,
                ws_origin,
                quat_identity,
                ws_direction,
                cast_length,
                filter,
                tester.up,
                tester.cos_max_slope_angle,
            );

            if (maybe_hit) |hit| {
                const raw_length: f32 = cast_length * hit.fraction + tester.radius - s.radius;
                const suspension_length: f32 = @max(0.0, raw_length);
                setWheelContact(
                    world,
                    w,
                    s,
                    rot,
                    ws_origin,
                    ws_direction,
                    hit.body,
                    hit.point,
                    hit.normal,
                    suspension_length,
                );
            }
        }
    }

    /// Cylinder-cast each wheel against the ground (Jolt's VehicleCollisionTesterCastCylinder).
    /// The cylinder is shaped like the wheel and oriented along its axle, giving the most accurate
    /// contact. No slope test — the cylinder shape itself avoids catching on walls.
    fn collideWheelsCastCylinder(
        self: *Vehicle,
        world: *const World,
        tester: VehicleCollisionTester.CastCylinderTester,
    ) void {
        const body: *const Body = &world.bodies.data[self.body];
        const com: Vec = body.com_pos;
        const rot: Quat = body.rot;
        const shape: *const Shape = world.shapes.get(body.shape);
        const shape_com: Vec = shapeCenterOfMass(shape);

        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            const s: *const WheelSettings = &w.settings;
            const ws_origin: Vec = com + rotate(rot, s.position - shape_com);
            const ws_direction: Vec = rotate(rot, s.suspension_direction);

            w.contact_body = none_body;
            w.suspension_length = s.suspension_max_length;

            // A cylinder shaped like the wheel: half-height along its axle = half the wheel width,
            // radius = wheel radius, with a small convex rounding.
            const half_width: f32 = 0.5 * s.width;
            const cyl_convex: f32 = @min(half_width, s.radius) * tester.convex_radius_fraction;
            const cylinder: Shape = .{ .cylinder = .{
                .half_height = half_width,
                .radius = s.radius,
                .convex_radius = cyl_convex,
            } };

            // Orient the cylinder's local Y (its axis) along the wheel's world axle (lateral) and
            // local X along the wheel forward, via a basis -> quaternion conversion.
            const basis: WheelBasis = vehicleWheelLocalBasis(s, w.steer_angle);
            const world_forward: Vec = rotate(rot, basis.forward);
            const world_right: Vec = rotate(rot, basis.right);
            const world_axis_z: Vec = cross(world_forward, world_right);
            const cyl_rot: Quat = quatFromBasis(world_forward, world_right, world_axis_z);

            const cast_length: f32 = s.suspension_max_length;
            if (cast_length <= 0.0) {
                continue;
            }
            const filter: QueryFilter = .{
                .mask = tester.object_mask,
                .exclude = self.body,
                .include_sensors = false,
            };
            // cos_max_slope_angle = -2 accepts any normal (the cylinder needs no slope test).
            const maybe_hit: ?VehicleShapeHit = castShapeVehicleFloor(
                world,
                &cylinder,
                ws_origin,
                cyl_rot,
                ws_direction,
                cast_length,
                filter,
                self.world_up,
                -2.0,
            );

            if (maybe_hit) |hit| {
                const suspension_length: f32 = @max(0.0, cast_length * hit.fraction);
                setWheelContact(
                    world,
                    w,
                    s,
                    rot,
                    ws_origin,
                    ws_direction,
                    hit.body,
                    hit.point,
                    hit.normal,
                    suspension_length,
                );
            }
        }
    }

    /// Per-step pre-solve work for one vehicle, called once at the start of the solver:
    /// steer the wheels, collide them with the ground, update spin/slip/friction, compute the
    /// brake budget, then build the constraint parts. Mirrors Jolt's PreCollide -> wheel
    /// collision -> PostCollide -> SetupVelocityConstraint sequence.
    pub fn prepare(self: *Vehicle, world: *World, dt: f32) void {
        if (self.tracks != null) {
            // Tank: tracks replace steering + differentials; suspension/pitch-roll setup is shared.
            self.trackedPreCollide(dt);
            self.collideWheels(world);
            self.trackedPostCollide(world, dt);
            self.setup(world, dt);
            return;
        }
        self.applySteering();
        if (self.lean != null) {
            self.motorcyclePreCollide(world, dt);
        }
        self.collideWheels(world);
        self.applyAntiRollBars(dt);
        self.updateWheels(world, dt);
        self.updatePowertrain(world, dt);
        self.applyBraking(dt);
        self.setup(world, dt);
    }

    /// Set the driver inputs. Any non-zero input wakes the chassis so it responds immediately.
    /// `forward` is throttle/reverse [-1,1], `right` steer [-1,1], `brake`/`hand_brake` [0,1].
    pub fn setDriverInput(
        self: *Vehicle,
        world: *World,
        forward: f32,
        right: f32,
        brake: f32,
        hand_brake: f32,
    ) !void {
        self.forward_input = forward;
        self.right_input = right;
        self.brake_input = brake;
        self.hand_brake_input = hand_brake;
        if (forward != 0.0 or right != 0.0 or brake != 0.0 or hand_brake != 0.0) {
            try world.wakeBody(world.allocator, self.body);
        }
    }

    /// Compute each anti-roll bar's impulse from the left/right suspension-length difference and
    /// store it on the two wheels as their suspension bias (Jolt's anti-rollbar block in OnStep).
    /// Run after collideWheels (which sets suspension lengths) and before setup builds the springs.
    fn applyAntiRollBars(self: *Vehicle, dt: f32) void {
        var i: usize = 0;
        while (i < self.anti_roll_bar_count) : (i += 1) {
            const bar: *const VehicleAntiRollBar = &self.anti_roll_bars[i];
            if (bar.left_wheel < 0 or bar.right_wheel < 0) {
                continue;
            }
            const li: usize = @intCast(bar.left_wheel);
            const ri: usize = @intCast(bar.right_wheel);
            if (li >= self.wheels.len or ri >= self.wheels.len) {
                continue;
            }
            const lw: *Wheel = &self.wheels[li];
            const rw: *Wheel = &self.wheels[ri];
            if (lw.hasContact() and rw.hasContact()) {
                const impulse: f32 = (rw.suspension_length - lw.suspension_length) * bar.stiffness * dt;
                lw.anti_roll_bar_impulse = -impulse;
                rw.anti_roll_bar_impulse = impulse;
            } else {
                // If either wheel is airborne the bar applies nothing.
                lw.anti_roll_bar_impulse = 0.0;
                rw.anti_roll_bar_impulse = 0.0;
            }
        }
    }

    /// Steer each wheel from the steering input (Jolt's PreCollide). Must run before
    /// collideWheels, since the wheel's ground basis depends on the steer angle.
    fn applySteering(self: *Vehicle) void {
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            w.steer_angle = -self.right_input * w.settings.max_steer_angle;
        }
    }

    /// Distance between the front-most and rear-most wheels along the body forward, at full
    /// suspension extension (Jolt's MotorcycleController::GetWheelBase).
    fn computeWheelBase(self: *const Vehicle) f32 {
        var low: f32 = floatMax(f32);
        var high: f32 = -floatMax(f32);
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const s: *const WheelSettings = &self.wheels[i].settings;
            const force_point: Vec = if (s.enable_suspension_force_point)
                s.suspension_force_point
            else
                s.position + s.suspension_direction * splat(s.suspension_max_length);
            const value: f32 = dot3(force_point, self.forward);
            low = @min(low, value);
            high = @max(high, value);
        }
        return high - low;
    }

    /// Motorcycle pre-collide (Jolt's MotorcycleController::PreCollide after the wheeled base):
    /// choose the target lean from last step's ground impulses, clamp it to the max lean angle,
    /// and limit the steer angle so the requested turn stays within that lean. Runs after
    /// applySteering (which set the base steer) and before collideWheels.
    fn motorcyclePreCollide(self: *Vehicle, world: *const World, dt: f32) void {
        const lean: *MotorcycleLean = &(self.lean.?);
        const body: *const Body = &world.bodies.data[self.body];
        const forward: Vec = rotate(body.rot, self.forward);
        const g: Vec = world.gravity;
        const glen: f32 = length3(g);
        const world_up: Vec = if (glen > 1.0e-9) (-g) / splat(glen) else self.up;

        // Target lean = direction of the total ground impulse on the wheels (from last step).
        var target_lean: Vec = vec_zero;
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *const Wheel = &self.wheels[i];
            if (w.hasContact()) {
                const susp: f32 = w.suspension_part.total_lambda + w.suspension_max_up_part.total_lambda;
                target_lean += w.contact_normal * splat(susp) +
                    w.contact_lateral * splat(w.lateral_part.total_lambda);
            }
        }
        target_lean = safeNormalize3(target_lean, world_up);

        // Smooth, strip the forward component (lean is sideways only), renormalize.
        lean.target_lean = lean.target_lean * splat(lean.smoothing_factor) +
            target_lean * splat(1.0 - lean.smoothing_factor);
        lean.target_lean -= forward * splat(dot3(lean.target_lean, forward));
        lean.target_lean = safeNormalize3(lean.target_lean, world_up);

        // Clamp the lean to the max lean angle, measured from the forward-stripped world up.
        var adjusted_world_up: Vec = world_up - forward * splat(dot3(world_up, forward));
        adjusted_world_up = safeNormalize3(adjusted_world_up, world_up);
        const lean_cross_up: Vec = cross(lean.target_lean, adjusted_world_up);
        const lean_dir_sign: f32 = -signNonZero(dot3(lean_cross_up, forward));
        const lean_cos: f32 = clamp(dot3(lean.target_lean, adjusted_world_up), -1.0, 1.0);
        const w_angle: f32 = lean_dir_sign * acosRad(lean_cos);
        if (@abs(w_angle) > lean.max_lean_angle) {
            const lean_angle: f32 = signNonZero(w_angle) * lean.max_lean_angle;
            const lean_rot: Quat = quatFromAxisAngle(forward, lean_angle);
            lean.target_lean = rotate(lean_rot, adjusted_world_up);
        }

        // Integrate the angle between the current up and the target lean (integral spring term).
        const up: Vec = rotate(body.rot, self.up);
        const lean_cross_up_i: Vec = cross(lean.target_lean, up);
        const lean_dir_sign_i: f32 = -signNonZero(dot3(lean_cross_up_i, forward));
        const lean_cos_i: f32 = clamp(dot3(lean.target_lean, up), -1.0, 1.0);
        const d_angle: f32 = lean_dir_sign_i * acosRad(lean_cos_i);
        lean.integrated_delta_angle += d_angle * dt;

        // Limit the steer angle so the requested turn does not demand more than the max lean.
        if (lean.enable_steering_limit) {
            const max_steer_factor: f32 = self.computeWheelBase() * tanRad(lean.max_lean_angle) * glen;
            const velocity: f32 = dot3(world.motion[self.body].lin_vel, forward);
            const velocity_sq: f32 = velocity * velocity;
            const steer_strength: f32 = @abs(self.right_input);
            const steer_sign: f32 = -signNonZero(self.right_input);
            var k: usize = 0;
            while (k < self.wheels.len) : (k += 1) {
                const w: *Wheel = &self.wheels[k];
                const s: *const WheelSettings = &w.settings;
                if (s.max_steer_angle != 0.0) {
                    const cos_caster_angle: f32 = dot3(s.steering_axis, self.up);
                    var steer_angle: f32 = steer_strength * s.max_steer_angle;
                    if (velocity_sq > 1.0e-6 and cos_caster_angle > 1.0e-6) {
                        const ratio: f32 = max_steer_factor / (velocity_sq * cos_caster_angle);
                        if (ratio < 1.0) {
                            steer_angle = @min(steer_angle, asinRad(ratio));
                        }
                    }
                    w.steer_angle = steer_sign * steer_angle;
                }
            }
        }

        lean.applied_impulse = 0.0;
    }

    /// Apply the lean spring once per velocity sweep, after the tire friction (Jolt's
    /// MotorcycleController lean in SolveLongitudinalAndLateralConstraints): a PD(+I) spring drives
    /// the chassis roll toward target_lean, then a linear impulse cancels the net translation the
    /// lean torque would induce at the contacts. Only when every wheel is loaded; else decay the
    /// integral term.
    fn solveLean(self: *Vehicle, world: *World, dt: f32) void {
        const lean: *MotorcycleLean = &(self.lean.?);

        var all_in_contact: bool = true;
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *const Wheel = &self.wheels[i];
            const susp_total: f32 = w.suspension_part.total_lambda + w.suspension_max_up_part.total_lambda;
            if (!w.hasContact() or susp_total <= 0.0) {
                all_in_contact = false;
                break;
            }
        }

        if (!all_in_contact) {
            lean.integrated_delta_angle *= @max(0.0, 1.0 - lean.spring_integration_coefficient_decay * dt);
            return;
        }

        const body: *const Body = &world.bodies.data[self.body];
        const forward: Vec = rotate(body.rot, self.forward);
        const up: Vec = rotate(body.rot, self.up);
        const chassis_motion: *Motion = &world.motion[self.body];
        const chassis_inv_i: Mat3 = bakeInvInertiaWorld(
            body.rot,
            chassis_motion.inv_inertia_diagonal,
            chassis_motion.inertia_rotation,
        );

        const lean_cross_up: Vec = cross(lean.target_lean, up);
        const lean_dir_sign: f32 = -signNonZero(dot3(lean_cross_up, forward));
        const lean_cos: f32 = clamp(dot3(lean.target_lean, up), -1.0, 1.0);
        const d_angle: f32 = lean_dir_sign * acosRad(lean_cos);
        const ddt_angle: f32 = dot3(chassis_motion.ang_vel, forward);
        const total_impulse: f32 = (lean.spring_constant * d_angle -
            lean.spring_damping * ddt_angle +
            lean.spring_integration_coefficient * lean.integrated_delta_angle) * dt;
        const delta_impulse: f32 = total_impulse - lean.applied_impulse;

        const old_ang_vel: Vec = chassis_motion.ang_vel;
        chassis_motion.ang_vel += chassis_inv_i.mulVec(forward * splat(delta_impulse));
        lean.applied_impulse = total_impulse;

        // Cancel the average linear velocity change the lean torque induces at the contacts.
        const dw: Vec = chassis_motion.ang_vel - old_ang_vel;
        var linear_acceleration: Vec = vec_zero;
        var total_lambda: f32 = 0.0;
        var j: usize = 0;
        while (j < self.wheels.len) : (j += 1) {
            const w: *const Wheel = &self.wheels[j];
            const lambda: f32 = w.suspension_part.total_lambda + w.suspension_max_up_part.total_lambda;
            total_lambda += lambda;
            const r: Vec = w.contact_position - body.com_pos;
            linear_acceleration += cross(dw, r) * splat(lambda);
        }
        if (total_lambda > 0.0 and chassis_motion.inv_mass > 0.0) {
            const denom_mass: f32 = total_lambda * chassis_motion.inv_mass;
            const linear_impulse: Vec = -linear_acceleration / splat(denom_mass);
            chassis_motion.lin_vel += linear_impulse * splat(chassis_motion.inv_mass);
        }
    }

    /// Per-wheel spin integration + slip and combined-friction computation from the fresh
    /// contacts (Jolt's WheelWV::Update). Throttle does not drive the wheels yet (Phase 4); the
    /// wheels free-roll, their spin driven by the longitudinal friction solve.
    fn updateWheels(self: *Vehicle, world: *World, dt: f32) void {
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            const s: *const WheelSettings = &w.settings;

            // Angular damping (Taylor approx of exp(-c*dt)) then integrate the visible spin.
            w.angular_velocity *= @max(0.0, 1.0 - s.angular_damping * dt);
            w.angle = @rem(w.angle + w.angular_velocity * dt, 2.0 * pi);

            if (w.hasContact()) {
                const body_vel: Vec = world.getPointVelocity(self.body, w.contact_position);
                var rel_vel: Vec = body_vel - w.contact_point_velocity;
                // Keep only the in-plane (sliding) part of the relative velocity.
                rel_vel -= splat(dot3(w.contact_normal, rel_vel)) * w.contact_normal;
                const rel_long: f32 = dot3(rel_vel, w.contact_longitudinal);

                // Longitudinal slip ratio (guard the denominator away from zero).
                const denom: f32 = signNonZero(rel_long) * @max(1.0e-3, @abs(rel_long));
                w.longitudinal_slip = @abs((w.angular_velocity * s.radius - rel_long) / denom);
                const long_friction: f32 = s.longitudinal_friction.getValue(w.longitudinal_slip);

                // Lateral slip angle (degrees) between the contact velocity and tire forward.
                const rel_len: f32 = length3(rel_vel);
                w.lateral_slip = if (rel_len < 1.0e-3)
                    0.0
                else
                    acosRad(@min(1.0, @abs(rel_long) / rel_len));
                const lat_friction: f32 = s.lateral_friction.getValue(w.lateral_slip * 180.0 / pi);

                // Combine tire friction with the terrain friction: sqrt(tire * terrain).
                const terrain_friction: f32 = world.bodies.data[w.contact_body].friction;
                w.combined_longitudinal_friction = @sqrt(long_friction * terrain_friction);
                w.combined_lateral_friction = @sqrt(lat_friction * terrain_friction);
            } else {
                w.longitudinal_slip = 0.0;
                w.lateral_slip = 0.0;
                w.combined_longitudinal_friction = 0.0;
                w.combined_lateral_friction = 0.0;
            }
        }
    }

    /// Engine -> transmission -> differential -> wheel torque distribution (the powertrain part
    /// of Jolt's PostCollide). Damp the engine, compute engine torque from throttle, distribute
    /// it across the driven wheels through the clutch as a coupled implicit-Euler solve, write
    /// back the wheel spins and engine RPM, then run the auto-shift gearbox. Runs after
    /// updateWheels and before braking.
    fn updatePowertrain(self: *Vehicle, world: *const World, dt: f32) void {
        _ = world;
        const old_engine_rpm: f32 = self.engine.getCurrentRpm();

        // Throttle magnitude; in auto mode it is scaled by clutch friction so the engine does
        // not rev freely while a shift is in progress.
        var forward_input: f32 = @abs(self.forward_input);
        if (self.transmission.mode == .auto) {
            forward_input *= self.transmission.getClutchFriction();
        }

        self.engine.applyDamping(dt);
        const engine_torque: f32 = self.engine.getTorque(forward_input);

        // Collect driven differentials and their average wheel speed (measured at the clutch).
        var driven_diffs: [8]DrivenDifferential = undefined;
        var num_driven_diffs: usize = 0;
        var diff_omega_min: f32 = floatMax(f32);
        var diff_omega_max: f32 = 0.0;
        var d_i: usize = 0;
        while (d_i < self.differential_count) : (d_i += 1) {
            const d: *const VehicleDifferentialSettings = &self.differentials[d_i];
            var avg_omega: f32 = 0.0;
            var avg_denom: f32 = 0.0;
            if (d.left_wheel >= 0) {
                avg_omega += self.wheels[@intCast(d.left_wheel)].angular_velocity;
                avg_denom += 1.0;
            }
            if (d.right_wheel >= 0) {
                avg_omega += self.wheels[@intCast(d.right_wheel)].angular_velocity;
                avg_denom += 1.0;
            }
            if (avg_denom > 0.0) {
                avg_omega = @abs(avg_omega * d.differential_ratio / avg_denom);
                driven_diffs[num_driven_diffs] = .{
                    .diff_index = d_i,
                    .angular_velocity = avg_omega,
                    .clutch_to_differential_torque_ratio = d.engine_torque_ratio,
                    .temp_torque_factor = 0.0,
                };
                num_driven_diffs += 1;
                diff_omega_min = @min(diff_omega_min, avg_omega);
                diff_omega_max = @max(diff_omega_max, avg_omega);
            }
        }

        // Inter-differential limited slip: bias engine torque toward the slower differential.
        const lsd_enabled: bool = self.differential_limited_slip_ratio < floatMax(f32);
        if (lsd_enabled and diff_omega_max > diff_omega_min) {
            var sum_factor: f32 = 0.0;
            var k: usize = 0;
            while (k < num_driven_diffs) : (k += 1) {
                driven_diffs[k].temp_torque_factor =
                    (diff_omega_max - driven_diffs[k].angular_velocity) / (diff_omega_max - diff_omega_min);
                sum_factor += driven_diffs[k].temp_torque_factor;
            }
            k = 0;
            while (k < num_driven_diffs) : (k += 1) driven_diffs[k].temp_torque_factor /= sum_factor;
            const clamped_min: f32 = @max(1.0e-3, diff_omega_min);
            const clamped_max: f32 = @max(1.0e-3, diff_omega_max);
            const slip_excess: f32 = clamped_max / clamped_min - 1.0;
            const slip_span: f32 = self.differential_limited_slip_ratio - 1.0;
            const alpha: f32 = @min(slip_excess / slip_span, 1.0);
            const one_min_alpha: f32 = 1.0 - alpha;
            k = 0;
            while (k < num_driven_diffs) : (k += 1) {
                driven_diffs[k].clutch_to_differential_torque_ratio =
                    one_min_alpha * driven_diffs[k].clutch_to_differential_torque_ratio +
                    alpha * driven_diffs[k].temp_torque_factor;
            }
        }

        // Collect driven wheels (with their per-wheel torque fraction after the left/right split).
        var driven_wheels: [clutch_max_n - 1]DrivenWheel = undefined;
        var num_driven_wheels: usize = 0;
        const transmission_ratio: f32 = self.transmission.getCurrentRatio();
        var dd_i: usize = 0;
        while (dd_i < num_driven_diffs) : (dd_i += 1) {
            const dd: *const DrivenDifferential = &driven_diffs[dd_i];
            const d: *const VehicleDifferentialSettings = &self.differentials[dd.diff_index];
            const clutch_to_wheel_ratio: f32 = transmission_ratio * d.differential_ratio;
            const has_l: bool = d.left_wheel >= 0;
            const has_r: bool = d.right_wheel >= 0;
            if (has_l and has_r) {
                var ratio_l: f32 = 0.0;
                var ratio_r: f32 = 0.0;
                d.calculateTorqueRatio(
                    self.wheels[@intCast(d.left_wheel)].angular_velocity,
                    self.wheels[@intCast(d.right_wheel)].angular_velocity,
                    &ratio_l,
                    &ratio_r,
                );
                if (num_driven_wheels < driven_wheels.len) {
                    driven_wheels[num_driven_wheels] = .{
                        .wheel_index = @intCast(d.left_wheel),
                        .clutch_to_wheel_ratio = clutch_to_wheel_ratio,
                        .clutch_to_wheel_torque_ratio = dd.clutch_to_differential_torque_ratio * ratio_l,
                        .estimated_angular_impulse = 0.0,
                    };
                    num_driven_wheels += 1;
                }
                if (num_driven_wheels < driven_wheels.len) {
                    driven_wheels[num_driven_wheels] = .{
                        .wheel_index = @intCast(d.right_wheel),
                        .clutch_to_wheel_ratio = clutch_to_wheel_ratio,
                        .clutch_to_wheel_torque_ratio = dd.clutch_to_differential_torque_ratio * ratio_r,
                        .estimated_angular_impulse = 0.0,
                    };
                    num_driven_wheels += 1;
                }
            } else if (has_l) {
                if (num_driven_wheels < driven_wheels.len) {
                    driven_wheels[num_driven_wheels] = .{
                        .wheel_index = @intCast(d.left_wheel),
                        .clutch_to_wheel_ratio = clutch_to_wheel_ratio,
                        .clutch_to_wheel_torque_ratio = dd.clutch_to_differential_torque_ratio,
                        .estimated_angular_impulse = 0.0,
                    };
                    num_driven_wheels += 1;
                }
            } else if (has_r) {
                if (num_driven_wheels < driven_wheels.len) {
                    driven_wheels[num_driven_wheels] = .{
                        .wheel_index = @intCast(d.right_wheel),
                        .clutch_to_wheel_ratio = clutch_to_wheel_ratio,
                        .clutch_to_wheel_torque_ratio = dd.clutch_to_differential_torque_ratio,
                        .estimated_angular_impulse = 0.0,
                    };
                    num_driven_wheels += 1;
                }
            }
        }

        var solved: bool = false;
        if (num_driven_wheels > 0) {
            // Build the (N+1)x(N+1) implicit-Euler system coupling the N driven wheels and the
            // engine through the clutch, then solve for the new angular velocities.
            const n: usize = num_driven_wheels + 1;
            const engine_row: usize = n - 1;
            var a: [clutch_max_n][clutch_max_n]f32 = undefined;
            var b: [clutch_max_n]f32 = undefined;
            const num_wheels_f: f32 = float(num_driven_wheels);
            const w_engine: f32 = self.engine.getAngularVelocity();
            const clutch_strength: f32 = if (transmission_ratio != 0.0)
                self.transmission.getClutchFriction() * self.transmission.clutch_strength
            else
                0.0;
            const dt_div_ie: f32 = dt / self.engine.inertia;
            const impulse_scale: f32 = if (self.previous_delta_time > 0.0)
                dt / self.previous_delta_time
            else
                0.0;

            var wi: usize = 0;
            while (wi < num_driven_wheels) : (wi += 1) {
                const dw: *DrivenWheel = &driven_wheels[wi];
                const w: *Wheel = &self.wheels[dw.wheel_index];
                const wheel_inertia: f32 = w.settings.inertia;
                const s_r: f32 = clutch_strength * dw.clutch_to_wheel_ratio;
                const dt_s_r_f_div_iw: f32 = dt * s_r * dw.clutch_to_wheel_torque_ratio / wheel_inertia;

                var wj: usize = 0;
                while (wj < num_driven_wheels) : (wj += 1) {
                    a[wi][wj] = dt_s_r_f_div_iw * driven_wheels[wj].clutch_to_wheel_ratio / num_wheels_f;
                }
                a[wi][wi] += 1.0;
                a[wi][engine_row] = -dt_s_r_f_div_iw;

                // External angular impulse on the wheel this try step (brake + estimated ground
                // reaction from last frame's longitudinal impulse).
                var dt_tw: f32 = 0.0;
                const brake_torque: f32 = self.brake_input * w.settings.max_brake_torque +
                    self.hand_brake_input * w.settings.max_hand_brake_torque;
                if (brake_torque > 0.0) {
                    const sgn: f32 = if (w.angular_velocity != 0.0)
                        signNonZero(w.angular_velocity)
                    else
                        signNonZero(self.transmission.getCurrentRatio());
                    dt_tw = sgn * dt * brake_torque;
                }
                if (w.hasContact()) {
                    dt_tw += impulse_scale * w.longitudinal_part.total_lambda * w.settings.radius;
                }
                dw.estimated_angular_impulse = dt_tw;
                b[wi] = w.angular_velocity - dt_tw / wheel_inertia;

                a[engine_row][wi] = -dt_div_ie * s_r / num_wheels_f;
            }
            a[engine_row][engine_row] = 1.0 + dt_div_ie * clutch_strength;
            b[engine_row] = w_engine + dt_div_ie * engine_torque;

            if (gaussJordanSolve(&a, &b, n)) {
                var ui: usize = 0;
                while (ui < num_driven_wheels) : (ui += 1) {
                    const dw: *const DrivenWheel = &driven_wheels[ui];
                    const w: *Wheel = &self.wheels[dw.wheel_index];
                    // Undo the estimated external impulse: it is applied for real by the brake /
                    // ground constraints, not by the powertrain solve.
                    w.angular_velocity = b[ui] + dw.estimated_angular_impulse / w.settings.inertia;
                }
                self.engine.setCurrentRpm(b[engine_row] * VehicleEngine.angular_velocity_to_rpm);
                solved = true;
            }
        }

        if (!solved) {
            // No wheels connected to the engine: all engine torque spins up the engine itself.
            self.engine.applyTorque(engine_torque, dt);
        }

        // Allow an upshift only when no driven wheel is slipping and the RPM is still rising.
        var wheels_slipping: bool = false;
        var si: usize = 0;
        while (si < num_driven_wheels) : (si += 1) {
            const dw: *const DrivenWheel = &driven_wheels[si];
            const w: *const Wheel = &self.wheels[dw.wheel_index];
            if (dw.clutch_to_wheel_torque_ratio > 0.0 and (!w.hasContact() or w.longitudinal_slip > 0.1)) {
                wheels_slipping = true;
            }
        }
        const can_shift_up: bool = !wheels_slipping and self.engine.getCurrentRpm() >= old_engine_rpm;

        self.transmission.update(dt, self.engine.getCurrentRpm(), self.forward_input, can_shift_up);
        self.previous_delta_time = dt;
    }

    /// Turn the brake / hand-brake inputs into a per-wheel brake impulse (Jolt's PostCollide
    /// braking). If the brakes can lock the wheel this step, the wheel is stopped and the
    /// remaining torque becomes a ground impulse; otherwise the wheel just slows down.
    fn applyBraking(self: *Vehicle, dt: f32) void {
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            const s: *const WheelSettings = &w.settings;
            const brake_torque: f32 = self.brake_input * s.max_brake_torque +
                self.hand_brake_input * s.max_hand_brake_torque;
            if (brake_torque > 0.0) {
                const brake_torque_to_lock: f32 = @abs(w.angular_velocity) * s.inertia / dt;
                if (brake_torque > brake_torque_to_lock) {
                    w.angular_velocity = 0.0;
                    w.brake_impulse = (brake_torque - brake_torque_to_lock) * dt / s.radius;
                } else {
                    w.angular_velocity -= signNonZero(w.angular_velocity) * brake_torque * dt / s.inertia;
                    w.brake_impulse = 0.0;
                }
            } else {
                w.brake_impulse = 0.0;
            }
        }
    }

    /// Solve the per-wheel longitudinal then lateral friction, each clamped to the friction
    /// circle (max impulse = combined friction * suspension normal impulse). Jolt's
    /// WheeledVehicleController::SolveLongitudinalAndLateralConstraints. Called once per sweep.
    fn solveFriction(self: *Vehicle, world: *World) void {
        const chassis_motion: *Motion = &world.motion[self.body];

        // Longitudinal pass (brake or free-rolling traction).
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            if (!w.hasContact()) {
                continue;
            }
            const s: *const WheelSettings = &w.settings;
            const contact_motion: *Motion = &world.motion[w.contact_body];
            const neg_long: Vec = -w.contact_longitudinal;
            const suspension_lambda: f32 = w.suspension_part.total_lambda +
                w.suspension_max_up_part.total_lambda;
            const max_long: f32 = w.combined_longitudinal_friction * suspension_lambda;

            const rel_vel: Vec = world.getPointVelocity(self.body, w.contact_position) -
                w.contact_point_velocity;
            const rel_long: f32 = dot3(rel_vel, w.contact_longitudinal);

            if (w.brake_impulse != 0.0) {
                // Brake: an impulse opposing motion, limited by tire friction. Wheel is locked,
                // so no rotation update.
                const brake: f32 = @min(w.brake_impulse, max_long);
                var min_imp: f32 = 0.0;
                var max_imp: f32 = 0.0;
                if (rel_long >= 0.0) {
                    min_imp = -brake;
                } else {
                    max_imp = brake;
                }
                w.longitudinal_part.solveVelocityClamped(
                    chassis_motion,
                    contact_motion,
                    neg_long,
                    min_imp,
                    max_imp,
                );
            } else {
                // Free-rolling: drive the longitudinal impulse toward what makes the wheel's
                // surface speed match the ground in one step, clamped by friction, then feed the
                // applied impulse back into the wheel's spin.
                const desired_angular_velocity: f32 = rel_long / s.radius;
                const linear_impulse: f32 = (w.angular_velocity - desired_angular_velocity) *
                    s.inertia / s.radius;
                const prev_lambda: f32 = w.longitudinal_part.total_lambda;
                const clamped: f32 = clamp(prev_lambda + linear_impulse, -max_long, max_long);
                w.longitudinal_part.solveVelocityClamped(
                    chassis_motion,
                    contact_motion,
                    neg_long,
                    clamped,
                    clamped,
                );
                w.angular_velocity -= (w.longitudinal_part.total_lambda - prev_lambda) * s.radius / s.inertia;
            }
        }

        // Lateral pass (cornering grip), after all longitudinal impulses.
        i = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            if (!w.hasContact()) {
                continue;
            }
            const contact_motion: *Motion = &world.motion[w.contact_body];
            const neg_lat: Vec = -w.contact_lateral;
            const suspension_lambda: f32 = w.suspension_part.total_lambda +
                w.suspension_max_up_part.total_lambda;
            const max_lat: f32 = w.combined_lateral_friction * suspension_lambda;
            w.lateral_part.solveVelocityClamped(chassis_motion, contact_motion, neg_lat, -max_lat, max_lat);
        }
    }

    // ---- Tracked (tank) controller (Jolt's TrackedVehicleController) ---------------------
    // A tank shares the suspension, pitch/roll, collision testers and the engine/transmission
    // with the wheeled vehicle, but replaces per-wheel differentials with two tracks driven at a
    // common speed, and steers by a left/right speed difference. Enable via VehicleSettings.tracks.

    /// Set tank driver input. `forward` is throttle/reverse [-1,1]; `left_ratio`/`right_ratio` are
    /// per-track speed multipliers [-1,1] (steering; never 0 — 0 is clamped to 1); `brake` [0,1].
    pub fn setTrackedInput(
        self: *Vehicle,
        world: *World,
        forward: f32,
        left_ratio: f32,
        right_ratio: f32,
        brake: f32,
    ) !void {
        self.forward_input = forward;
        self.left_ratio = if (left_ratio != 0.0) left_ratio else 1.0;
        self.right_ratio = if (right_ratio != 0.0) right_ratio else 1.0;
        self.brake_input = brake;
        if (forward != 0.0 or brake != 0.0 or left_ratio != right_ratio) {
            try world.wakeBody(world.allocator, self.body);
        }
    }

    /// A wheel's spin follows its track: ω = track_ω · driven_wheel_radius / wheel_radius.
    fn calcWheelAngularVelocityFromTrack(self: *Vehicle, w: *Wheel) void {
        if (w.track_index < 0) {
            return;
        }
        const track: *const VehicleTrack = &(self.tracks.?[@intCast(w.track_index)]);
        const driven_radius: f32 = self.wheels[track.driven_wheel].settings.radius;
        w.angular_velocity = track.angular_velocity * driven_radius / w.settings.radius;
    }

    /// Tank pre-collide (Jolt's TrackedVehicleController::PreCollide): tag each wheel with its
    /// track and damp each track's spin (dw/dt = -c w, 1st-order Taylor).
    fn trackedPreCollide(self: *Vehicle, dt: f32) void {
        const tracks: *[2]VehicleTrack = &(self.tracks.?);
        var t: usize = 0;
        while (t < 2) : (t += 1) {
            var k: usize = 0;
            while (k < tracks[t].wheel_count) : (k += 1) {
                self.wheels[tracks[t].wheels[k]].track_index = @intCast(t);
            }
            tracks[t].angular_velocity *= @max(0.0, 1.0 - tracks[t].angular_damping * dt);
        }
    }

    /// Per-wheel update for a tank (Jolt's WheelTV::Update): spin from the track, advance the
    /// angle, reset the brake budget, and set the combined (scalar tire × terrain) friction.
    fn trackedUpdateWheels(self: *Vehicle, world: *const World, dt: f32) void {
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            self.calcWheelAngularVelocityFromTrack(w);
            w.angle = @rem(w.angle + w.angular_velocity * dt, 2.0 * pi);
            w.brake_impulse = 0.0;
            if (w.hasContact()) {
                const terrain: f32 = world.bodies.data[w.contact_body].friction;
                w.combined_longitudinal_friction = @sqrt(w.settings.tv_longitudinal_friction * terrain);
                w.combined_lateral_friction = @sqrt(w.settings.tv_lateral_friction * terrain);
            } else {
                w.combined_longitudinal_friction = 0.0;
                w.combined_lateral_friction = 0.0;
            }
        }
    }

    /// Enforce the steering ratio between the two tracks (Jolt's SyncLeftRightTracks): transfer
    /// spin between them, inertia-weighted, so left_ω/right_ω matches left_ratio/right_ratio.
    fn syncLeftRightTracks(self: *Vehicle) void {
        const tracks: *[2]VehicleTrack = &(self.tracks.?);
        const tl: *VehicleTrack = &tracks[0];
        const tr: *VehicleTrack = &tracks[1];
        const lr: f32 = self.left_ratio;
        const rr: f32 = self.right_ratio;
        if (lr * rr > 0.0) {
            const impulse: f32 = (lr * tr.angular_velocity - rr * tl.angular_velocity) /
                (lr * tr.inertia + rr * tl.inertia);
            tl.angular_velocity += impulse * tl.inertia;
            tr.angular_velocity -= impulse * tr.inertia;
        } else {
            const impulse: f32 = (lr * tr.angular_velocity - rr * tl.angular_velocity) /
                (rr * tl.inertia - lr * tr.inertia);
            tl.angular_velocity += impulse * tl.inertia;
            tr.angular_velocity += impulse * tr.inertia;
        }
    }

    /// Tank powertrain (Jolt's TrackedVehicleController::PostCollide): drive the tracks from the
    /// engine/transmission, sync the steering ratio, apply braking, then push the result back onto
    /// the wheels. Called after collideWheels and before setup.
    fn trackedPostCollide(self: *Vehicle, world: *const World, dt: f32) void {
        self.trackedUpdateWheels(world, dt);
        const tracks: *[2]VehicleTrack = &(self.tracks.?);

        // Engine RPM from the track speeds when in gear + clutched, else free engine.
        var can_engine_apply_torque: bool = false;
        if (self.transmission.current_gear != 0 and self.transmission.getClutchFriction() > 1.0e-3) {
            const transmission_ratio: f32 = self.transmission.getCurrentRatio();
            const forward: bool = transmission_ratio >= 0.0;
            var fastest_wheel_speed: f32 = if (forward) -floatMax(f32) else floatMax(f32);
            var t: usize = 0;
            while (t < 2) : (t += 1) {
                const track: *const VehicleTrack = &tracks[t];
                const track_speed: f32 = track.angular_velocity * track.differential_ratio;
                fastest_wheel_speed = if (forward)
                    @max(fastest_wheel_speed, track_speed)
                else
                    @min(fastest_wheel_speed, track_speed);
                var k: usize = 0;
                while (k < track.wheel_count) : (k += 1) {
                    if (self.wheels[track.wheels[k]].hasContact()) {
                        can_engine_apply_torque = true;
                        break;
                    }
                }
            }
            const speed_finite: bool = fastest_wheel_speed > -floatMax(f32) and
                fastest_wheel_speed < floatMax(f32);
            if (speed_finite) {
                const wheel_rpm: f32 = fastest_wheel_speed *
                    self.transmission.getCurrentRatio() *
                    VehicleEngine.angular_velocity_to_rpm;
                self.engine.setCurrentRpm(wheel_rpm);
            }
        } else {
            self.engine.applyDamping(dt);
            const forward_input: f32 = if (self.transmission.mode == .manual)
                @abs(self.forward_input)
            else
                0.0;
            self.engine.applyTorque(self.engine.getTorque(forward_input), dt);
        }

        // Transmission (only shift up when both tracks roll the same way and can drive).
        const can_shift_up: bool = (self.left_ratio * self.right_ratio > 0.0) and can_engine_apply_torque;
        self.transmission.update(dt, self.engine.getCurrentRpm(), self.forward_input, can_shift_up);

        // Transmission torque → each track's driven wheel (capped by the engine's max spin).
        const transmission_ratio: f32 = self.transmission.getCurrentRatio();
        const clutch_torque: f32 = self.transmission.getClutchFriction() * transmission_ratio;
        const transmission_torque: f32 = clutch_torque * self.engine.getTorque(@abs(self.forward_input));
        if (transmission_torque != 0.0) {
            var t: usize = 0;
            while (t < 2) : (t += 1) {
                const track: *VehicleTrack = &tracks[t];
                const ratio: f32 = if (t == 0) self.left_ratio else self.right_ratio;
                const av_to_rpm: f32 = VehicleEngine.angular_velocity_to_rpm;
                const gear_chain: f32 = transmission_ratio * track.differential_ratio * ratio * av_to_rpm;
                const track_max_av: f32 = self.engine.getCurrentRpm() / gear_chain * 1.001;
                const differential_torque: f32 = track.differential_ratio * ratio * transmission_torque;
                const wrong_dir: bool = track.angular_velocity * track_max_av < 0.0;
                const slower: bool = @abs(track.angular_velocity) < @abs(track_max_av);
                if (wrong_dir or slower) {
                    track.angular_velocity += differential_torque * dt / track.inertia;
                }
            }
        }

        // Keep the steering ratio between the tracks.
        self.syncLeftRightTracks();

        // Braking: slow/lock each track, then spread the residual brake torque over its grounded
        // wheels as a ground brake impulse (Jolt applies the brake to the track spin and the
        // ground in the same pass).
        var bt: usize = 0;
        while (bt < 2) : (bt += 1) {
            const track: *VehicleTrack = &tracks[bt];
            var brake_torque: f32 = self.brake_input * track.max_brake_torque;
            if (brake_torque > 0.0) {
                const brake_to_lock: f32 = @abs(track.angular_velocity) * track.inertia / dt;
                if (brake_torque > brake_to_lock) {
                    track.angular_velocity = 0.0;
                    brake_torque -= brake_to_lock;
                } else {
                    track.angular_velocity -=
                        signNonZero(track.angular_velocity) * brake_torque * dt / track.inertia;
                }
            }
            if (brake_torque > 0.0) {
                var total_radius: f32 = 0.0;
                var k: usize = 0;
                while (k < track.wheel_count) : (k += 1) {
                    const w: *const Wheel = &self.wheels[track.wheels[k]];
                    if (w.hasContact()) {
                        total_radius += w.settings.radius;
                    }
                }
                if (total_radius > 0.0) {
                    // p = torque/radius·dt with torque ∝ radius, so the radius cancels: every
                    // grounded wheel gets the same impulse brake_torque·dt/total_radius (Jolt).
                    const per_impulse: f32 = brake_torque * dt / total_radius;
                    var k2: usize = 0;
                    while (k2 < track.wheel_count) : (k2 += 1) {
                        const w: *Wheel = &self.wheels[track.wheels[k2]];
                        if (w.hasContact()) {
                            w.brake_impulse = per_impulse;
                        }
                    }
                }
            }
        }

        // Push the updated track speeds back onto the wheels.
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            self.calcWheelAngularVelocityFromTrack(&self.wheels[i]);
        }
    }

    /// Tank tire friction (Jolt's TrackedVehicleController::SolveLongitudinalAndLateralConstraints):
    /// like the wheeled solveFriction but the longitudinal impulse is coupled to the track's spin
    /// (not a per-wheel spin), and the steering sync runs after each drive impulse.
    fn trackedSolveFriction(self: *Vehicle, world: *World) void {
        const chassis_motion: *Motion = &world.motion[self.body];
        const tracks: *[2]VehicleTrack = &(self.tracks.?);

        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            if (!w.hasContact() or w.track_index < 0) {
                continue;
            }
            const s: *const WheelSettings = &w.settings;
            const track: *VehicleTrack = &tracks[@intCast(w.track_index)];
            const contact_motion: *Motion = &world.motion[w.contact_body];
            const neg_long: Vec = -w.contact_longitudinal;
            const suspension_lambda: f32 = w.suspension_part.total_lambda +
                w.suspension_max_up_part.total_lambda;
            const max_long: f32 = w.combined_longitudinal_friction * suspension_lambda;

            const rel_vel: Vec = world.getPointVelocity(self.body, w.contact_position) -
                w.contact_point_velocity;
            const rel_long: f32 = dot3(rel_vel, w.contact_longitudinal);

            if (w.brake_impulse != 0.0) {
                const brake: f32 = @min(w.brake_impulse, max_long);
                var min_imp: f32 = 0.0;
                var max_imp: f32 = 0.0;
                if (rel_long >= 0.0) {
                    min_imp = -brake;
                } else {
                    max_imp = brake;
                }
                w.longitudinal_part.solveVelocityClamped(
                    chassis_motion,
                    contact_motion,
                    neg_long,
                    min_imp,
                    max_imp,
                );
            } else {
                // Drive the track-ground slip to zero in one step, clamped by friction, then feed
                // the applied impulse back into the track's spin and re-sync the two tracks.
                const desired_angular_velocity: f32 = rel_long / s.radius;
                const linear_impulse: f32 = (track.angular_velocity - desired_angular_velocity) *
                    track.inertia / s.radius;
                const prev_lambda: f32 = w.longitudinal_part.total_lambda;
                const clamped: f32 = clamp(prev_lambda + linear_impulse, -max_long, max_long);
                w.longitudinal_part.solveVelocityClamped(
                    chassis_motion,
                    contact_motion,
                    neg_long,
                    clamped,
                    clamped,
                );
                track.angular_velocity -=
                    (w.longitudinal_part.total_lambda - prev_lambda) * s.radius / track.inertia;
                self.syncLeftRightTracks();
            }
        }

        // Lateral pass: refresh each wheel's spin from its track, then sideways grip.
        i = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            if (!w.hasContact() or w.track_index < 0) {
                continue;
            }
            self.calcWheelAngularVelocityFromTrack(w);
            const contact_motion: *Motion = &world.motion[w.contact_body];
            const neg_lat: Vec = -w.contact_lateral;
            const suspension_lambda: f32 = w.suspension_part.total_lambda +
                w.suspension_max_up_part.total_lambda;
            const max_lat: f32 = w.combined_lateral_friction * suspension_lambda;
            w.lateral_part.solveVelocityClamped(chassis_motion, contact_motion, neg_lat, -max_lat, max_lat);
        }
    }

    /// Build this step's suspension + pitch/roll constraint parts from the wheel contacts
    /// (Jolt's SetupVelocityConstraint plus the pitch/roll part). Call once after
    /// collideWheels and before warmStart.
    pub fn setup(self: *Vehicle, world: *World, dt: f32) void {
        // A sleeping chassis is frozen this try step (gravity and integration both skip it), so
        // don't build or solve its constraint parts; collideWheels still ran to keep contacts
        // fresh for when it wakes.
        if (world.bodies.data[self.body].asleep) {
            return;
        }
        const body: *const Body = &world.bodies.data[self.body];
        const com: Vec = body.com_pos;
        const rot: Quat = body.rot;
        const shape: *const Shape = world.shapes.get(body.shape);
        const shape_com: Vec = shapeCenterOfMass(shape);

        const chassis_motion: *const Motion = &world.motion[self.body];
        const chassis_inv_mass: f32 = chassis_motion.inv_mass;
        const chassis_inv_i: Mat3 = bakeInvInertiaWorld(
            rot,
            chassis_motion.inv_inertia_diagonal,
            chassis_motion.inertia_rotation,
        );
        // Spring stiffness uses the body's *local* inverse inertia + a fixed force point, so
        // the spring rate does not depend on the contact geometry (Jolt does the same).
        const local_inv_i: Mat3 = bakeInvInertiaWorld(
            quat_identity,
            chassis_motion.inv_inertia_diagonal,
            chassis_motion.inertia_rotation,
        );

        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            if (!w.hasContact()) {
                w.suspension_part = AxisPart.inactive;
                w.suspension_max_up_part = AxisPart.inactive;
                w.longitudinal_part = AxisPart.inactive;
                w.lateral_part = AxisPart.inactive;
                continue;
            }
            const s: *const WheelSettings = &w.settings;
            const neg_contact_normal: Vec = -w.contact_normal;

            const fp: VehicleForcePoint = vehicleSuspensionForcePoint(world, w, com, rot, shape_com);
            const contact_motion: *const Motion = &world.motion[w.contact_body];
            const contact_body: *const Body = &world.bodies.data[w.contact_body];
            const contact_inv_i: Mat3 = if (contact_motion.inv_mass > 0.0)
                bakeInvInertiaWorld(
                    contact_body.rot,
                    contact_motion.inv_inertia_diagonal,
                    contact_motion.inertia_rotation,
                )
            else
                Mat3.zero;

            // Suspension spring (only when the suspension has travel).
            if (s.suspension_max_length > s.suspension_min_length) {
                const force_point_local: Vec = if (s.enable_suspension_force_point)
                    s.suspension_force_point
                else
                    s.position + s.suspension_direction *
                        splat(0.5 * (s.suspension_min_length + s.suspension_max_length));
                const fp_x_neg_up: Vec = cross(force_point_local, -self.up);
                const fp_inv_i: Vec = local_inv_i.mulVec(fp_x_neg_up);
                const eff_mass_spring: f32 = 1.0 / (chassis_inv_mass + dot3(fp_x_neg_up, fp_inv_i));
                const omega: f32 = 2.0 * pi * s.suspension_frequency;
                var stiffness: f32 = eff_mass_spring * omega * omega;
                var damping: f32 = 2.0 * eff_mass_spring * s.suspension_damping * omega;

                // Convert the spring rate along the suspension to the rate along the contact
                // normal: divide by cos(angle), clamped so we never over-stiffen (Jolt clamps
                // 1/cos to [1, 10] via cos in [0.1, 1]).
                const ws_direction: Vec = rotate(rot, s.suspension_direction);
                const cos_angle: f32 = @max(0.1, dot3(ws_direction, neg_contact_normal));
                stiffness /= cos_angle;
                damping /= cos_angle;

                const c: f32 = w.suspension_length - s.suspension_max_length - s.suspension_preload_length;
                w.suspension_part.prepareStiffnessDamping(
                    chassis_motion,
                    chassis_inv_i,
                    fp.r1_plus_u,
                    contact_motion,
                    contact_inv_i,
                    fp.r2,
                    neg_contact_normal,
                    w.anti_roll_bar_impulse,
                    c,
                    stiffness,
                    damping,
                    dt,
                );
            } else {
                w.suspension_part = AxisPart.inactive;
            }

            // Hard upper limit: stop further compression once below the minimum length.
            if (w.suspension_length < s.suspension_min_length) {
                w.suspension_max_up_part.prepare(
                    chassis_motion,
                    chassis_inv_i,
                    fp.r1_plus_u,
                    contact_motion,
                    contact_inv_i,
                    fp.r2,
                    neg_contact_normal,
                    0.0,
                );
            } else {
                w.suspension_max_up_part = AxisPart.inactive;
            }

            // (Longitudinal / lateral tire-friction parts are set up in Phase 3.)
            // Friction and propulsion: rigid 1-DOF parts along the contact's longitudinal and
            // lateral directions; the friction solve clamps their impulses to the friction
            // circle. Jolt seeds the axis as the negated contact direction.
            w.longitudinal_part.prepare(
                chassis_motion,
                chassis_inv_i,
                fp.r1_plus_u,
                contact_motion,
                contact_inv_i,
                fp.r2,
                -w.contact_longitudinal,
                0.0,
            );
            w.lateral_part.prepare(
                chassis_motion,
                chassis_inv_i,
                fp.r1_plus_u,
                contact_motion,
                contact_inv_i,
                fp.r2,
                -w.contact_lateral,
                0.0,
            );
        }

        // Anti-topple pitch/roll part.
        self.calcPitchRoll(rot, chassis_inv_i);
    }

    /// (Re)build the pitch/roll anti-topple part from the current chassis rotation (Jolt's
    /// CalculatePitchRollConstraintProperties). The second body is fixed to the world.
    fn calcPitchRoll(self: *Vehicle, rot: Quat, chassis_inv_i: Mat3) void {
        if (self.cos_max_pitch_roll_angle > -1.0) {
            const vehicle_up: Vec = rotate(rot, self.up);
            self.cos_pitch_roll_angle = dot3(self.world_up, vehicle_up);
            if (self.cos_pitch_roll_angle < self.cos_max_pitch_roll_angle) {
                const axis: Vec = cross(self.world_up, vehicle_up);
                const len: f32 = length3(axis);
                if (len > 0.0) {
                    self.pitch_roll_rotation_axis = axis / splat(len);
                }
                self.pitch_roll_part.prepare(chassis_inv_i, Mat3.zero, self.pitch_roll_rotation_axis, 0.0);
            } else {
                self.pitch_roll_part = AngleConstraintPart.inactive;
            }
        } else {
            self.pitch_roll_part = AngleConstraintPart.inactive;
        }
    }

    /// Re-apply last step's accumulated impulses (Jolt's WarmStartVelocityConstraint). The
    /// longitudinal part is deliberately not warm-started (Phase 3); here only suspension.
    pub fn warmStart(self: *Vehicle, world: *World, ratio: f32) void {
        if (world.bodies.data[self.body].asleep) {
            return;
        }
        var fixed: Motion = Motion.zero;
        const chassis_motion: *Motion = &world.motion[self.body];
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            if (!w.hasContact()) {
                continue;
            }
            const neg_contact_normal: Vec = -w.contact_normal;
            const contact_motion: *Motion = &world.motion[w.contact_body];
            w.suspension_part.warmStart(chassis_motion, contact_motion, neg_contact_normal, ratio);
            w.suspension_max_up_part.warmStart(chassis_motion, contact_motion, neg_contact_normal, ratio);
            // Lateral grip is warm-started; the longitudinal (engine/brake) part is reset each
            // frame (ratio 0) so no stale drive/brake impulse carries over.
            w.longitudinal_part.warmStart(chassis_motion, contact_motion, -w.contact_longitudinal, 0.0);
            w.lateral_part.warmStart(chassis_motion, contact_motion, -w.contact_lateral, ratio);
        }
        self.pitch_roll_part.warmStart(chassis_motion, &fixed, ratio);
    }

    /// One velocity iteration: push-only suspension spring + hard limit, then the pitch/roll
    /// part (Jolt's SolveVelocityConstraint, minus the controller's tire friction = Phase 3).
    pub fn solveVelocity(self: *Vehicle, world: *World, dt: f32) void {
        if (world.bodies.data[self.body].asleep) {
            return;
        }
        var fixed: Motion = Motion.zero;
        const chassis_motion: *Motion = &world.motion[self.body];
        const max_lambda: f32 = floatMax(f32);
        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            if (!w.hasContact()) {
                continue;
            }
            const neg_contact_normal: Vec = -w.contact_normal;
            const contact_motion: *Motion = &world.motion[w.contact_body];
            // The suspension can only push the bodies apart, never pull them together.
            if (w.suspension_part.isActive()) {
                w.suspension_part.solveVelocityClamped(
                    chassis_motion,
                    contact_motion,
                    neg_contact_normal,
                    0.0,
                    max_lambda,
                );
            }
            if (w.suspension_max_up_part.isActive()) {
                w.suspension_max_up_part.solveVelocityClamped(
                    chassis_motion,
                    contact_motion,
                    neg_contact_normal,
                    0.0,
                    max_lambda,
                );
            }
        }
        // Tire friction (longitudinal drive/brake + lateral grip), clamped to the friction
        // circle, between the suspension and the pitch/roll part (Jolt's order).
        if (self.tracks != null) {
            self.trackedSolveFriction(world);
        } else {
            self.solveFriction(world);
            // Motorcycle lean spring, after the friction (Jolt's MotorcycleController order).
            if (self.lean != null) {
                self.solveLean(world, dt);
            }
        }
        if (self.pitch_roll_part.isActive()) {
            self.pitch_roll_part.solveVelocity(
                chassis_motion,
                &fixed,
                self.pitch_roll_rotation_axis,
                0.0,
                max_lambda,
            );
        }
    }

    /// One position iteration: re-check the suspension hard limit now the body has moved and
    /// correct it, then the pitch/roll limit (Jolt's SolvePositionConstraint).
    pub fn solvePosition(self: *Vehicle, world: *World, baumgarte: f32) void {
        if (world.bodies.data[self.body].asleep) {
            return;
        }
        const body: *Body = &world.bodies.data[self.body];
        // Jolt captures the body transform once and reuses it for every wheel this pass.
        const com: Vec = body.com_pos;
        const rot: Quat = body.rot;
        const shape: *const Shape = world.shapes.get(body.shape);
        const shape_com: Vec = shapeCenterOfMass(shape);
        const chassis_motion: *const Motion = &world.motion[self.body];
        const chassis_inv_i: Mat3 = bakeInvInertiaWorld(
            rot,
            chassis_motion.inv_inertia_diagonal,
            chassis_motion.inertia_rotation,
        );

        var i: usize = 0;
        while (i < self.wheels.len) : (i += 1) {
            const w: *Wheel = &self.wheels[i];
            if (!w.hasContact()) {
                continue;
            }
            const s: *const WheelSettings = &w.settings;

            // Axle position at minimum suspension length, vs the contact plane captured at
            // collision time. A negative error means the axle has pushed through the plane.
            const ws_direction: Vec = rotate(rot, s.suspension_direction);
            const ws_position: Vec = com + rotate(rot, s.position - shape_com);
            const min_suspension_pos: Vec = ws_position + ws_direction * splat(s.suspension_min_length);
            const max_up_error: f32 = dot3(w.contact_normal, min_suspension_pos) - w.axle_plane_constant;
            if (max_up_error < 0.0) {
                const neg_contact_normal: Vec = -w.contact_normal;
                const fp: VehicleForcePoint = vehicleSuspensionForcePoint(world, w, com, rot, shape_com);
                const contact_motion: *const Motion = &world.motion[w.contact_body];
                const contact_body: *Body = &world.bodies.data[w.contact_body];
                const contact_inv_i: Mat3 = if (contact_motion.inv_mass > 0.0)
                    bakeInvInertiaWorld(
                        contact_body.rot,
                        contact_motion.inv_inertia_diagonal,
                        contact_motion.inertia_rotation,
                    )
                else
                    Mat3.zero;
                w.suspension_max_up_part.prepare(
                    chassis_motion,
                    chassis_inv_i,
                    fp.r1_plus_u,
                    contact_motion,
                    contact_inv_i,
                    fp.r2,
                    neg_contact_normal,
                    0.0,
                );
                w.suspension_max_up_part.solvePosition(
                    body,
                    chassis_motion,
                    contact_body,
                    contact_motion,
                    neg_contact_normal,
                    max_up_error,
                    baumgarte,
                );
            }
        }

        // Pitch/roll limit (recomputed against the moved body; second body fixed to world, so
        // pass a zero second axis-inertia and alias the chassis body, which is a no-op for it).
        self.calcPitchRoll(rot, chassis_inv_i);
        if (self.pitch_roll_part.isActive()) {
            const c: f32 = self.cos_pitch_roll_angle - self.cos_max_pitch_roll_angle;
            self.pitch_roll_part.solvePosition(
                body,
                body,
                self.pitch_roll_part.inv_i1_axis,
                vec_zero,
                c,
                baumgarte,
            );
        }
    }
};

/// Motor mode for a SixDOF axis (Jolt's EMotorState). Unlike the hinge/slider MotorMode this
/// adds a combined position+velocity mode.
pub const SixDofMotorState = enum { off, velocity, position, position_and_velocity };

/// Fully configurable 6-DOF joint (Jolt's SixDOFConstraint): three translation axes and three
/// rotation axes, each independently free / limited / fixed, each with an optional motor
/// (velocity, position, or both) and optional friction; translation limits can be soft (spring).
/// Axes are indexed 0..2 = translation X/Y/Z, 3..5 = rotation X/Y/Z, in the constraint frame.
/// Stored in World.six_dof and driven by the solver alongside the regular constraints.
pub const SixDofConstraint = struct {
    body_a: BodyIndex,
    body_b: BodyIndex,
    enabled: bool = true,

    // Configuration (constraint space). local_pos_a/b are the pivot in each body's COM-local
    // frame; constraint_to_body_a/b rotate from constraint space to each body's local frame.
    local_pos_a: Vec = vec_zero,
    local_pos_b: Vec = vec_zero,
    constraint_to_body_a: Quat = quat_identity,
    constraint_to_body_b: Quat = quat_identity,

    // Per-axis limits. A fixed axis has min >= max; a free axis has min <= -limit and max >= limit
    // (limit = FLT_MAX for translation, pi for rotation). Otherwise the axis is limited.
    limit_min: [6]f32 = .{ 0, 0, 0, 0, 0, 0 },
    limit_max: [6]f32 = .{ 0, 0, 0, 0, 0, 0 },
    // Soft-limit springs for the three translation axes (frequency 0 = rigid limit).
    limit_freq: [3]f32 = .{ 0, 0, 0 },
    limit_damping: [3]f32 = .{ 0, 0, 0 },

    // Per-axis friction (force for translation, torque for rotation) and motors.
    max_friction: [6]f32 = .{ 0, 0, 0, 0, 0, 0 },
    motor_state: [6]SixDofMotorState = .{ .off, .off, .off, .off, .off, .off },
    motor_freq: [6]f32 = .{ 0, 0, 0, 0, 0, 0 }, // position-motor spring
    motor_damping: [6]f32 = .{ 0, 0, 0, 0, 0, 0 },
    motor_min: [6]f32 = .{ 0, 0, 0, 0, 0, 0 }, // min force/torque limit
    motor_max: [6]f32 = .{ 0, 0, 0, 0, 0, 0 }, // max force/torque limit
    target_velocity: Vec = vec_zero, // translation motor target (constraint space)
    target_angular_velocity: Vec = vec_zero, // rotation motor target
    target_position: Vec = vec_zero, // translation position-motor target
    target_orientation: Quat = quat_identity, // rotation position-motor target
    swing_type: SwingType = .cone,

    // Cached classification (rebuilt by updateFixedFreeAxis / the motor cachers).
    free_axis: u8 = 0,
    fixed_axis: u8 = 0,
    translation_motor_active: bool = false,
    rotation_motor_active: bool = false,
    rotation_position_motor_active: u8 = 0,
    has_spring_limits: bool = false,

    // Runtime (this step).
    translation_axis: [3]Vec = .{ vec_zero, vec_zero, vec_zero },
    rotation_axis: [3]Vec = .{ vec_zero, vec_zero, vec_zero },
    displacement: [3]f32 = .{ 0, 0, 0 },

    // Constraint parts. Translation: 3 axis-limit parts + a point part (when fully locked).
    // Rotation: a swing-twist part + a rotation-lock part (when fully locked). Plus per-axis
    // translation and rotation motor parts.
    translation_part: [3]AxisPart = .{ AxisPart.inactive, AxisPart.inactive, AxisPart.inactive },
    point_part: PointPart = PointPart.inactive,
    swing_twist: SwingTwistPart = SwingTwistPart.inactive,
    rotation_lock: RotationLockPart = RotationLockPart.inactive,
    motor_translation_part: [3]AxisPart = .{ AxisPart.inactive, AxisPart.inactive, AxisPart.inactive },
    motor_rotation_part: [3]AngleConstraintPart = @splat(AngleConstraintPart.inactive),

    fn isFreeAxis(c: *const SixDofConstraint, a: usize) bool {
        return (c.free_axis & (@as(u8, 1) << @as(u3, @intCast(a)))) != 0;
    }
    fn isFixedAxis(c: *const SixDofConstraint, a: usize) bool {
        return (c.fixed_axis & (@as(u8, 1) << @as(u3, @intCast(a)))) != 0;
    }
    fn hasFriction(c: *const SixDofConstraint, a: usize) bool {
        return !c.isFixedAxis(a) and c.max_friction[a] > 0.0;
    }
    fn isTranslationConstrained(c: *const SixDofConstraint) bool {
        return (c.free_axis & 0b111) != 0b111;
    }
    fn isTranslationFullyConstrained(c: *const SixDofConstraint) bool {
        return (c.fixed_axis & 0b111) == 0b111 and !c.has_spring_limits;
    }
    fn isRotationConstrained(c: *const SixDofConstraint) bool {
        return (c.free_axis & 0b111000) != 0b111000;
    }
    fn isRotationFullyConstrained(c: *const SixDofConstraint) bool {
        return (c.fixed_axis & 0b111000) == 0b111000;
    }

    /// Recompute the free/fixed bitmasks from the limits (Jolt's UpdateFixedFreeAxis).
    fn updateFixedFreeAxis(c: *SixDofConstraint) void {
        c.free_axis = 0;
        c.fixed_axis = 0;
        var a: usize = 0;
        while (a < 6) : (a += 1) {
            const limit: f32 = if (a >= 3) pi else floatMax(f32);
            if (c.limit_min[a] >= c.limit_max[a]) {
                c.fixed_axis |= @as(u8, 1) << @as(u3, @intCast(a));
            } else if (c.limit_min[a] <= -limit and c.limit_max[a] >= limit) {
                c.free_axis |= @as(u8, 1) << @as(u3, @intCast(a));
            }
        }
    }

    /// Recompute the cached motor-active flags (Jolt's Cache*MotorActive).
    fn cacheMotorActive(c: *SixDofConstraint) void {
        c.translation_motor_active = c.motor_state[0] != .off or
            c.motor_state[1] != .off or
            c.motor_state[2] != .off or
            c.hasFriction(0) or c.hasFriction(1) or c.hasFriction(2);
        c.rotation_motor_active = c.motor_state[3] != .off or
            c.motor_state[4] != .off or
            c.motor_state[5] != .off or
            c.hasFriction(3) or c.hasFriction(4) or c.hasFriction(5);
        c.rotation_position_motor_active = 0;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const st: SixDofMotorState = c.motor_state[3 + i];
            if (st == .position or st == .position_and_velocity) {
                c.rotation_position_motor_active |= @as(u8, 1) << @as(u3, @intCast(i));
            }
        }
        c.has_spring_limits = c.limit_freq[0] > 0.0 or c.limit_freq[1] > 0.0 or c.limit_freq[2] > 0.0;
    }
};

/// One control point of a Hermite spline path (Jolt's PathConstraintPathHermite::Point): a
/// position, the tangent (derivative) at that point, and an "up" normal used to orient the frame.
pub const HermitePoint = struct {
    position: Vec,
    tangent: Vec,
    normal: Vec,
};

/// Full oriented frame on the path at a fraction.
const PathFrame = struct { position: Vec, tangent: Vec, normal: Vec, binormal: Vec };

/// Position and (un-normalized) tangent of a Hermite segment at parameter t.
const HermitePosTan = struct { position: Vec, tangent: Vec };

/// Cubic Hermite interpolation of a segment (p1, m1) -> (p2, m2) at t in [0,1], returning the
/// position and the derivative (tangent). Jolt's sCalculatePositionAndTangent.
fn hermitePosTan(
    p1: Vec,
    m1: Vec,
    p2: Vec,
    m2: Vec,
    t: f32,
) HermitePosTan {
    const t2: f32 = t * t;
    const t3: f32 = t * t2;
    const h00: f32 = 2.0 * t3 - 3.0 * t2 + 1.0;
    const h10: f32 = t3 - 2.0 * t2 + t;
    const h01: f32 = -2.0 * t3 + 3.0 * t2;
    const h11: f32 = t3 - t2;
    const ddt_h00: f32 = 6.0 * (t2 - t);
    const ddt_h10: f32 = 3.0 * t2 - 4.0 * t + 1.0;
    const ddt_h01: f32 = -ddt_h00;
    const ddt_h11: f32 = 3.0 * t2 - 2.0 * t;
    return .{
        .position = p1 * splat(h00) + m1 * splat(h10) + p2 * splat(h01) + m2 * splat(h11),
        .tangent = p1 * splat(ddt_h00) +
            m1 * splat(ddt_h10) +
            p2 * splat(ddt_h01) +
            m2 * splat(ddt_h11),
    };
}

const HermiteInterval = struct { t_min: f32, t_max: f32 };

/// Bracket the closest point on a segment by 4 bisection steps on d/dt(P.P) = P.tangent (Jolt's
/// sCalculateClosestPointThroughBisection). p1/p2 are the segment endpoints relative to the query
/// point. If t_min == t_max the root was found directly; otherwise [t_min,t_max] brackets it.
fn hermiteBisect(
    p1: Vec,
    m1: Vec,
    p2: Vec,
    m2: Vec,
) HermiteInterval {
    var t_min: f32 = 0.0;
    var t_max: f32 = 1.0;
    const ddt_min: f32 = dot3(p1, m1);
    if (@abs(ddt_min) < 1.0e-6) {
        return .{ .t_min = 0.0, .t_max = 0.0 };
    }
    const ddt_min_negative: bool = ddt_min < 0.0;
    const ddt_max: f32 = dot3(p2, m2);
    if (@abs(ddt_max) < 1.0e-6) {
        return .{ .t_min = 1.0, .t_max = 1.0 };
    }
    const ddt_max_negative: bool = ddt_max < 0.0;
    if (ddt_min_negative == ddt_max_negative) {
        return .{ .t_min = t_min, .t_max = t_max };
    }
    var iteration: usize = 0;
    while (iteration < 4) : (iteration += 1) {
        const t_mid: f32 = 0.5 * (t_min + t_max);
        const pt: HermitePosTan = hermitePosTan(p1, m1, p2, m2, t_mid);
        const ddt_mid: f32 = dot3(pt.position, pt.tangent);
        if (@abs(ddt_mid) < 1.0e-6) {
            return .{ .t_min = t_mid, .t_max = t_mid };
        }
        if ((ddt_mid < 0.0) == ddt_min_negative) {
            t_min = t_mid;
        } else {
            t_max = t_mid;
        }
    }
    return .{ .t_min = t_min, .t_max = t_max };
}

const HermiteNewton = struct { t: f32, dist_sq: f32 };

/// Refine the closest point on a segment by up to 10 Newton-Raphson steps on P.tangent = 0 (Jolt's
/// sCalculateClosestPointThroughNewtonRaphson). Returns the parameter and squared distance.
fn hermiteNewton(
    p1: Vec,
    m1: Vec,
    p2: Vec,
    m2: Vec,
    t_min: f32,
    t_max: f32,
) HermiteNewton {
    const interval: f32 = t_max - t_min;
    var t: f32 = 0.5 * (t_min + t_max);
    var position: Vec = vec_zero;
    var iteration: usize = 0;
    while (iteration < 10) : (iteration += 1) {
        const pt: HermitePosTan = hermitePosTan(p1, m1, p2, m2, t);
        position = pt.position;
        const ddt: f32 = dot3(pt.position, pt.tangent);
        const d2dt_h00: f32 = 12.0 * t - 6.0;
        const d2dt_h10: f32 = 6.0 * t - 4.0;
        const d2dt_h01: f32 = -d2dt_h00;
        const d2dt_h11: f32 = 6.0 * t - 2.0;
        const ddt_tangent: Vec = p1 * splat(d2dt_h00) +
            m1 * splat(d2dt_h10) +
            p2 * splat(d2dt_h01) +
            m2 * splat(d2dt_h11);
        const d2dt: f32 = dot3(pt.tangent, pt.tangent) + dot3(pt.position, ddt_tangent);
        if (d2dt == 0.0) {
            break;
        }
        const delta: f32 = clamp(-ddt / d2dt, -interval, interval);
        if ((t > t_max and delta > 0.0) or (t < t_min and delta < 0.0)) {
            break;
        }
        t += delta;
        if (@abs(delta) < 1.0e-4) {
            break;
        }
    }
    return .{ .t = t, .dist_sq = dot3(position, position) };
}

/// A Hermite-spline path that a PathConstraint follows (Jolt's PathConstraintPathHermite). Owns its
/// control points; the path is expressed in the constraint's path space.
pub const HermitePath = struct {
    points: []HermitePoint,
    looping: bool = false,

    fn maxFraction(self: *const HermitePath) f32 {
        return float(if (self.looping) self.points.len else self.points.len - 1);
    }

    const IndexT = struct { index: usize, t: f32 };

    /// Split a fraction into a segment index and a local parameter t in [0,1] (Jolt's GetIndexAndT),
    /// handling looping wrap-around and non-looping clamping at the ends.
    fn indexAndT(self: *const HermitePath, fraction: f32) IndexT {
        const num_points: i64 = @intCast(self.points.len);
        var index: i64 = @trunc(fraction);
        var t: f32 = fraction - float(index);
        if (self.looping) {
            if (index < 0) {
                index += @divTrunc(-index, num_points) * num_points + num_points;
            }
            index = @mod(index, num_points);
        } else {
            if (index < 0) {
                index = 0;
                t = 0.0;
            } else if (index >= num_points - 1) {
                index = num_points - 2;
                t = 1.0;
            }
        }
        return .{ .index = @intCast(index), .t = t };
    }

    /// Oriented frame on the path at a fraction (Jolt's GetPointOnPath): the interpolated position,
    /// the normalized tangent, and a normal/binormal built from the interpolated up-normal.
    fn pointOnPath(self: *const HermitePath, fraction: f32) PathFrame {
        const it: IndexT = self.indexAndT(fraction);
        const p1: HermitePoint = self.points[it.index];
        const p2: HermitePoint = self.points[(it.index + 1) % self.points.len];
        const pt: HermitePosTan = hermitePosTan(p1.position, p1.tangent, p2.position, p2.tangent, it.t);
        const tangent: Vec = safeNormalize3(pt.tangent, vec(1, 0, 0));
        const normal_lerp: Vec = p1.normal * splat(1.0 - it.t) + p2.normal * splat(it.t);
        const binormal: Vec = safeNormalize3(cross(normal_lerp, tangent), vec(0, 1, 0));
        const normal: Vec = cross(tangent, binormal);
        return .{ .position = pt.position, .tangent = tangent, .normal = normal, .binormal = binormal };
    }

    /// Find the fraction of the closest point to `position` (path space), scanning every segment and
    /// refining with bisection + Newton-Raphson (Jolt's GetClosestPoint). `hint` is unused here (the
    /// full scan is robust); kept for signature parity with Jolt.
    fn closestPoint(self: *const HermitePath, position: Vec, hint: f32) f32 {
        _ = hint;
        const num_points: usize = self.points.len;
        const last_delta: Vec = self.points[num_points - 1].position - position;
        var best_dist_sq: f32 = dot3(last_delta, last_delta);
        var best_t: f32 = float(num_points - 1);
        const max_i: usize = if (self.looping) num_points else num_points - 1;
        var i: usize = 0;
        while (i < max_i) : (i += 1) {
            const p1: HermitePoint = self.points[i];
            const p2: HermitePoint = self.points[(i + 1) % num_points];
            const p1_pos: Vec = p1.position - position;
            const p2_pos: Vec = p2.position - position;
            const dist_sq0: f32 = dot3(p1_pos, p1_pos);
            if (dist_sq0 < best_dist_sq) {
                best_t = float(i);
                best_dist_sq = dist_sq0;
            }
            const iv: HermiteInterval = hermiteBisect(p1_pos, p1.tangent, p2_pos, p2.tangent);
            if (iv.t_min == iv.t_max) {
                const pt: HermitePosTan = hermitePosTan(p1_pos, p1.tangent, p2_pos, p2.tangent, iv.t_min);
                const dist_sq: f32 = dot3(pt.position, pt.position);
                if (dist_sq < best_dist_sq) {
                    best_t = float(i) + iv.t_min;
                    best_dist_sq = dist_sq;
                }
            } else {
                const nr: HermiteNewton = hermiteNewton(
                    p1_pos,
                    p1.tangent,
                    p2_pos,
                    p2.tangent,
                    iv.t_min,
                    iv.t_max,
                );
                if (nr.t >= 0.0 and nr.t <= 1.0 and nr.dist_sq < best_dist_sq) {
                    best_t = float(i) + nr.t;
                    best_dist_sq = nr.dist_sq;
                }
            }
        }
        return best_t;
    }
};

/// How a PathConstraint constrains the orientation of body 2 (Jolt's EPathRotationConstraintType).
pub const PathRotationType = enum {
    free, // rotation is not constrained
    constrain_around_tangent, // only rotation about the path tangent is allowed
    constrain_around_normal, // only rotation about the path normal is allowed
    constrain_around_binormal, // only rotation about the path binormal is allowed
    constrain_to_path, // orientation follows the path frame
    fully_constrained, // orientation is locked to body 1
};

/// Constrains a point on body 2 to slide along a Hermite path defined in body 1's space (Jolt's
/// PathConstraint), with optional end limits, a position motor / friction along the path tangent,
/// and a configurable rotation mode. Stored in World.paths and driven by the solver.
pub const PathConstraint = struct {
    body_a: BodyIndex,
    body_b: BodyIndex,
    enabled: bool = true,

    path: HermitePath,
    // Path frame -> each body's COM-local frame (rotation + origin offset).
    path_to_body_a: Quat = quat_identity,
    path_pos_a: Vec = vec_zero,
    path_to_body_b: Quat = quat_identity,
    path_pos_b: Vec = vec_zero,
    path_fraction: f32 = 0.0,

    max_friction_force: f32 = 0.0,
    motor_state: SixDofMotorState = .off,
    motor_freq: f32 = 0.0,
    motor_damping: f32 = 0.0,
    motor_min: f32 = 0.0, // min force limit
    motor_max: f32 = 0.0, // max force limit
    target_velocity: f32 = 0.0,
    target_path_fraction: f32 = 0.0,
    rotation_type: PathRotationType = .free,

    // Runtime (this step).
    r1: Vec = vec_zero,
    r2: Vec = vec_zero,
    u: Vec = vec_zero,
    path_normal: Vec = vec_zero,
    path_binormal: Vec = vec_zero,
    path_tangent: Vec = vec_zero,
    inv_initial_orientation: Quat = quat_identity,

    // Constraint parts.
    position_part: DualAxisPart = DualAxisPart.inactive, // hold to normal+binormal
    position_limits_part: AxisPart = AxisPart.inactive, // end stops along tangent
    position_motor_part: AxisPart = AxisPart.inactive, // motor / friction along tangent
    hinge_part: HingeRotationPart = HingeRotationPart.inactive, // constrain-around-axis modes
    rotation_part: RotationLockPart = RotationLockPart.inactive, // constrain-to-path / fully

    /// Position error along the path for the position motor (Jolt's CalculateConstraintValue).
    fn constraintValue(c: *const PathConstraint) f32 {
        if (c.path.looping) {
            const max_fraction: f32 = c.path.maxFraction();
            var v: f32 = @rem(c.path_fraction - c.target_path_fraction, max_fraction);
            const half: f32 = 0.5 * max_fraction;
            if (v > half) {
                v -= max_fraction;
            } else if (v < -half) {
                v += max_fraction;
            }
            return v;
        }
        return c.path_fraction - c.target_path_fraction;
    }
};

/// One vertex of a soft body's shared asset (Jolt's SoftBodySharedSettings::Vertex): its initial
/// local position/velocity and inverse mass (0 pins it in place).
pub const SoftVertexDef = struct {
    position: Vec,
    velocity: Vec = vec_zero,
    inv_mass: f32 = 1.0,
};

/// A distance (spring) constraint between two vertices (Jolt's Edge). `rest_length` is filled in by
/// the builder; `compliance` is inverse stiffness (0 = perfectly rigid).
pub const SoftEdge = struct {
    vertex: [2]u32,
    rest_length: f32 = 0.0,
    compliance: f32 = 0.0,
};

/// A dihedral-bend constraint (Jolt's DihedralBend): resists folding along the edge shared by two
/// triangles. `vertex[0..1]` are the shared edge; `vertex[2]`/`vertex[3]` are the opposite corners of
/// the two triangles. `initial_angle` (pi − dihedral angle, signed) is filled in by the builder.
pub const SoftDihedralBend = struct {
    vertex: [4]u32,
    compliance: f32 = 0.0,
    initial_angle: f32 = 0.0,
};

/// A tetrahedral volume-preservation constraint over four vertices (Jolt's Volume).
/// `six_rest_volume` (6× the rest volume) is filled in by the builder.
pub const SoftVolume = struct {
    vertex: [4]u32,
    six_rest_volume: f32 = 0.0,
    compliance: f32 = 0.0,
};

/// A long-range-attachment constraint (Jolt's LRA): caps the distance of a dynamic vertex from an
/// anchor, preventing overstretch (e.g. cloth pulling away from a pinned edge). `vertex[0]` is the
/// anchor (usually pinned), `vertex[1]` the dynamic vertex. `max_distance` defaults to the rest
/// distance if left 0.
pub const SoftLRA = struct {
    vertex: [2]u32,
    max_distance: f32 = 0.0,
};

/// A triangle of the soft body's surface (Jolt's Face). Carried for rendering and for the
/// rigid-vs-soft collision of later stages; the Stage 1 solver does not use it.
pub const SoftFace = struct {
    vertex: [3]u32,
};

/// The immutable, shareable asset describing a soft body's topology and rest state (Jolt's
/// SoftBodySharedSettings). Create it once with createSoftBodyShared; many SoftBody instances may
/// reference the same asset. Owns its arrays (freed with the allocator that built it).
pub const SoftBodyShared = struct {
    vertices: []SoftVertexDef,
    edges: []SoftEdge,
    bends: []SoftDihedralBend,
    volumes: []SoftVolume,
    lra: []SoftLRA,
    faces: []SoftFace,
};

/// Runtime state of one soft-body particle (Jolt's SoftBodyVertex). Positions are relative to the
/// body's center of mass.
const SoftVertex = struct {
    previous_position: Vec,
    position: Vec,
    velocity: Vec,
    inv_mass: f32,

    // Collision state (Stage 2), reset at the start of each update.
    collision_normal: Vec = vec(0, 1, 0), // plane normal, out of the rigid shape
    collision_dist: f32 = 0.0, // plane constant d (normal·x + d = 0), soft-local
    colliding_body: i32 = -1, // index into the per-update colliding-body list (-1 = none)
    largest_penetration: f32 = -3.0e38, // deepest penetration found so far this update
    has_contact: bool = false,
};

/// A soft-body instance in the world (Jolt's SoftBodyMotionProperties). References a shared asset and
/// owns its per-particle runtime state. Driven by softBodyUpdate from World.step.
pub const SoftBody = struct {
    shared: *const SoftBodyShared,
    vertices: []SoftVertex, // owned; positions relative to com_pos
    com_pos: Vec, // world position of the soft body's center of mass

    // Body-level velocities (the particle average), refreshed each step for queries.
    linear_velocity: Vec = vec_zero,
    angular_velocity: Vec = vec_zero,

    // Tuning.
    num_iterations: u32 = 5, // XPBD substeps per World.step
    gravity_scale: f32 = 1.0,
    linear_damping: f32 = 0.05,
    max_linear_speed: f32 = 500.0,
    update_position: bool = true, // keep com_pos tracking the particle centroid

    // Contact properties (Stage 2).
    friction: f32 = 0.2,
    restitution: f32 = 0.0,
    vertex_radius: f32 = 0.0, // collision radius of each particle

    // Internal pressure (Stage 3); > 0 inflates a closed mesh toward a larger enclosed volume.
    pressure: f32 = 0.0,

    local_bounds: Aabb = .{ .min = vec_zero, .max = vec_zero },
    enabled: bool = true,
};

pub const PointKey = struct { a: BodyIndex, b: BodyIndex, sub: u32, feature: u32 };

pub const ManifoldKey = struct { a: BodyIndex, b: BodyIndex, sub: u32 };

pub const CachedFriction = struct { linear: [2]f32, angular: f32 };

/// Remove every entry of an AutoHashMap whose key names body `idx` (in its `a` or `b` field).
/// Two-pass (collect keys, then remove) because removing during iteration is unsafe.
fn purgeCacheMap(
    comptime K: type,
    comptime V: type,
    map: *std.AutoHashMapUnmanaged(K, V),
    gpa: std.mem.Allocator,
    idx: BodyIndex,
) void {
    var to_remove: std.ArrayListUnmanaged(K) = .empty;
    defer to_remove.deinit(gpa);
    var it: std.AutoHashMapUnmanaged(K, V).Iterator = map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.a == idx or entry.key_ptr.b == idx) {
            to_remove.append(gpa, entry.key_ptr.*) catch return; // OOM: leave the rest to expire
        }
    }
    for (to_remove.items) |k| {
        _ = map.remove(k);
    }
}

pub const ManifoldCache = struct {
    normal_now: std.AutoHashMapUnmanaged(PointKey, f32) = .empty,
    normal_prev: std.AutoHashMapUnmanaged(PointKey, f32) = .empty,
    friction_now: std.AutoHashMapUnmanaged(ManifoldKey, CachedFriction) = .empty,
    friction_prev: std.AutoHashMapUnmanaged(ManifoldKey, CachedFriction) = .empty,

    pub fn lookupNormal(self: *const ManifoldCache, key: PointKey) f32 {
        return self.normal_prev.get(key) orelse 0.0;
    }
    pub fn lookupFriction(self: *const ManifoldCache, key: ManifoldKey) CachedFriction {
        return self.friction_prev.get(key) orelse .{ .linear = .{ 0, 0 }, .angular = 0 };
    }
    pub fn storeNormal(
        self: *ManifoldCache,
        gpa: std.mem.Allocator,
        key: PointKey,
        v: f32,
    ) !void {
        try self.normal_now.put(gpa, key, v);
    }
    pub fn storeFriction(
        self: *ManifoldCache,
        gpa: std.mem.Allocator,
        key: ManifoldKey,
        v: CachedFriction,
    ) !void {
        try self.friction_now.put(gpa, key, v);
    }
    pub fn swap(self: *ManifoldCache) void {
        std.mem.swap(@TypeOf(self.normal_now), &self.normal_now, &self.normal_prev);
        std.mem.swap(@TypeOf(self.friction_now), &self.friction_now, &self.friction_prev);
        self.normal_now.clearRetainingCapacity();
        self.friction_now.clearRetainingCapacity();
    }

    /// Drop every warm-start entry that names `idx`, so a removed (and possibly recycled) body
    /// index can't seed a later contact pair with a dead body's cached impulses. Best-effort: if
    /// the temporary key list can't be allocated the stale entries are left to expire on the next
    /// swap (one frame of slightly-off warm start at worst), never wrong memory.
    pub fn removeBody(self: *ManifoldCache, gpa: std.mem.Allocator, idx: BodyIndex) void {
        purgeCacheMap(PointKey, f32, &self.normal_now, gpa, idx);
        purgeCacheMap(PointKey, f32, &self.normal_prev, gpa, idx);
        purgeCacheMap(ManifoldKey, CachedFriction, &self.friction_now, gpa, idx);
        purgeCacheMap(ManifoldKey, CachedFriction, &self.friction_prev, gpa, idx);
    }
};

pub const ManifoldPoint = struct {
    point_on_a: Vec, // world, on A's surface
    point_on_b: Vec, // world, on B's surface
    feature_id: u32, // stable id for warm-start matching across frames
};

pub const Manifold = struct {
    normal: Vec, // world, A -> B
    count: u8,
    points: [4]ManifoldPoint,
};

/// Per-contact tuning a listener's added/persisted callback may modify in place to
/// override the defaults for one sub-shape contact. Friction/restitution null = use the
/// value combined from the two bodies. Ignored on sensor pairs (they have no response).
pub const ContactSettings = struct {
    friction: ?f32 = null, // null = sqrt(friction_a * friction_b)
    restitution: ?f32 = null, // null = @max(restitution_a, restitution_b)
    /// Target relative contact velocity (v_a - v_b) along the surface, world space — a
    /// conveyor belt. `a` is the lower body index; flip the sign if the belt is body `b`.
    /// The friction constraint drives the surface toward this (capped by the friction cone).
    relative_linear_surface_velocity: Vec = vec_zero,
    /// Make THIS contact a sensor: detected (events still fire) but no collision response.
    /// Set it from the callback for one-way platforms (e.g. when the body is moving up).
    is_sensor: bool = false,
};

pub const ContactValidate = enum { accept, reject };

/// Optional contact callbacks invoked during try step(). Set `world.contact_listener`.
/// Every field is optional; `context` is an opaque pointer handed back to each callback
/// (point it at your own event buffer). Callbacks must treat the world as read-only and
/// should only RECORD events to act on after try step() returns — mutating bodies mid-step
/// is unsupported. `sub` identifies the sub-shape pair (mesh-triangle / compound-child,
/// packed as in the warm-start cache); it is 0 for a simple convex-vs-convex pair.
///
/// Sensor bodies (BodyDef.is_sensor) generate added/persisted/removed events but no
/// collision response; without a listener set, sensor overlaps are still discarded.
pub const ContactListener = struct {
    /// Shared signature of the added/persisted callbacks: (context, world, body_a, body_b,
    /// sub_shape_pair, manifold, settings). Both fire mid-step and may edit `settings` in place.
    pub const PairCallback = *const fn (
        ?*anyopaque,
        *const World,
        BodyIndex,
        BodyIndex,
        u32,
        *const Manifold,
        *ContactSettings,
    ) void;

    context: ?*anyopaque = null,
    /// Per body pair, before the manifold is built. Return .reject to drop the pair
    /// entirely (no response and no added/removed events for it this step).
    on_contact_validate: ?*const fn (?*anyopaque, *const World, BodyIndex, BodyIndex) ContactValidate = null,
    /// A sub-shape pair started touching this step. May modify `settings` in place.
    on_contact_added: ?PairCallback = null,
    /// A sub-shape pair that touched last step is still touching. May modify `settings`.
    on_contact_persisted: ?PairCallback = null,
    /// A sub-shape pair that touched last step has separated (fired after the contact is
    /// gone, so no manifold). NOT fired while a still-touching pair is merely asleep.
    on_contact_removed: ?*const fn (?*anyopaque, BodyIndex, BodyIndex, u32) void = null,
};

/// Swap-remove every joint in `list` that names body `idx` (in `body_a` or `body_b`). Iterates
/// back-to-front so each swapRemove only moves an element already visited. Works for any constraint
/// type with `body_a` / `body_b: BodyIndex` (point, six-DOF, path).
fn removeConstraintsReferencing(
    comptime C: type,
    list: *std.ArrayListUnmanaged(C),
    idx: BodyIndex,
) void {
    var i: usize = list.items.len;
    while (i > 0) {
        i -= 1;
        if (list.items[i].body_a == idx or list.items[i].body_b == idx) {
            _ = list.swapRemove(i);
        }
    }
}

pub const World = struct {
    bodies: Bodies,
    motion: []Motion,
    inv_inertia_world: []Mat3,
    // Dynamic mass properties for every body, computed at addBody regardless of motion type
    // and kept so setMotionType can restore them when a body becomes dynamic (mirrors Jolt
    // keeping MotionProperties around). motion[] holds the *active* properties (zeroed for
    // static/kinematic); this holds what the body would have as a dynamic body.
    mass_props: []MassProperties,
    shapes: ShapeStore,
    active: std.ArrayListUnmanaged(BodyIndex),
    constraints: std.ArrayListUnmanaged(Constraint), // joints (persist across frames)
    vehicles: std.ArrayListUnmanaged(*Vehicle), // registered vehicles (not owned; see addVehicle)
    six_dof: std.ArrayListUnmanaged(SixDofConstraint), // 6-DOF joints (persist across frames)
    paths: std.ArrayListUnmanaged(PathConstraint), // path (rail) joints (persist across frames)
    soft_bodies: std.ArrayListUnmanaged(SoftBody), // soft bodies (cloth / volumetric)

    broadphase: BroadPhase,
    cache: ManifoldCache,

    island_parent: []u32, // union-find over bodies (contact graph); rebuilt each step
    island_awake: []bool, // per-root: island contains an awake body (indexed by root)
    island_can_sleep: []bool, // per-root: every awake member passed the sleep test
    allocator: std.mem.Allocator, // persistent (tree, caches); NOT the per-step scratch
    scratch_arena: std.heap.ArenaAllocator, // per-step transient buffers; reset each step()
    settings: Settings,
    gravity: Vec,
    prev_dt: f32,

    // Optional contact-event callbacks (null = no events, zero overhead). The two sets
    // record which sub-shape pairs touched this frame vs last, to derive added/removed.
    // Allocated from `allocator` (persistent across frames); reused each step.
    contact_listener: ?ContactListener = null,
    contacts_prev: std.AutoHashMapUnmanaged(ManifoldKey, void) = .empty,
    contacts_curr: std.AutoHashMapUnmanaged(ManifoldKey, void) = .empty,

    pub fn init(gpa: std.mem.Allocator, capacity: u32) !World {
        var bodies: Bodies = try .init(gpa, .{ .capacity = capacity });
        errdefer bodies.deinit(gpa);

        const motion: []Motion = try gpa.alloc(Motion, capacity);
        errdefer gpa.free(motion);
        for (motion) |*m| {
            m.* = Motion.zero;
        }

        const inv_inertia_world: []Mat3 = try gpa.alloc(Mat3, capacity);
        errdefer gpa.free(inv_inertia_world);
        // Static bodies are never re-baked (they aren't in the active set), so zero the
        // whole array up front: their inverse inertia must read as the zero matrix
        // wherever the solver consults it (contacts and joints alike).
        for (inv_inertia_world) |*m| {
            m.* = Mat3.zero;
        }

        const mass_props: []MassProperties = try gpa.alloc(MassProperties, capacity);
        errdefer gpa.free(mass_props);
        for (mass_props) |*mp| {
            mp.* = .{
                .mass = 0.0,
                .inv_mass = 0.0,
                .inv_inertia_diagonal = vec_zero,
                .inertia_rotation = quat_identity,
            };
        }

        const island_parent: []u32 = try gpa.alloc(u32, capacity);
        errdefer gpa.free(island_parent);

        const island_awake: []bool = try gpa.alloc(bool, capacity);
        errdefer gpa.free(island_awake);

        const island_can_sleep: []bool = try gpa.alloc(bool, capacity);
        errdefer gpa.free(island_can_sleep);

        return .{
            .bodies = bodies,
            .motion = motion,
            .inv_inertia_world = inv_inertia_world,
            .mass_props = mass_props,
            .shapes = .{},
            .active = .empty,
            .constraints = .empty,
            .vehicles = .empty,
            .six_dof = .empty,
            .paths = .empty,
            .soft_bodies = .empty,
            .broadphase = .{},
            .cache = .{},
            .island_parent = island_parent,
            .island_awake = island_awake,
            .island_can_sleep = island_can_sleep,
            .allocator = gpa,
            .scratch_arena = std.heap.ArenaAllocator.init(gpa),
            .settings = .{},
            .gravity = vec(0.0, -9.81, 0.0),
            .prev_dt = 0.0,
        };
    }

    /// Free everything the World owns: the init allocations plus the persistent
    /// lists and caches grown while stepping. After this the World is invalid.
    /// Registered vehicles are NOT owned (see addVehicle) — only the list is
    /// freed. Soft bodies have no per-body deinit, so only their list is freed.
    pub fn deinit(world: *World, gpa: std.mem.Allocator) void {
        world.scratch_arena.deinit();
        world.bodies.deinit(gpa);
        gpa.free(world.motion);
        gpa.free(world.inv_inertia_world);
        gpa.free(world.mass_props);
        gpa.free(world.island_parent);
        gpa.free(world.island_awake);
        gpa.free(world.island_can_sleep);
        world.shapes.deinit(gpa);
        world.active.deinit(gpa);
        world.constraints.deinit(gpa);
        world.vehicles.deinit(gpa);
        world.six_dof.deinit(gpa);
        world.paths.deinit(gpa);
        world.soft_bodies.deinit(gpa);
        world.broadphase.nodes.deinit(gpa);
        world.cache.normal_now.deinit(gpa);
        world.cache.normal_prev.deinit(gpa);
        world.cache.friction_now.deinit(gpa);
        world.cache.friction_prev.deinit(gpa);
        world.contacts_prev.deinit(gpa);
        world.contacts_curr.deinit(gpa);
    }

    pub const BodyDef = struct {
        shape: ShapeId,
        position: Vec, // of the shape origin (not COM)
        rotation: Quat = quat_identity,
        motion_type: MotionType = .dynamic,
        motion_quality: MotionQuality = .discrete,
        density: f32 = 1000.0,
        // Mass overrides (dynamic bodies only). `override_mass` replaces the
        // density-derived mass, scaling the shape's inertia to match (Jolt's
        // calculate-inertia mode); `inertia_multiplier` then scales that inertia.
        override_mass: ?f32 = null,
        inertia_multiplier: f32 = 1.0,
        friction: f32 = 0.5,
        restitution: f32 = 0.0,
        linear_damping: f32 = 0.05,
        angular_damping: f32 = 0.05,
        gravity_scale: f32 = 1.0,
        // Per-body velocity ceilings (were hardcoded in addBody).
        max_linear_speed: f32 = 500.0,
        max_angular_speed: f32 = 0.25 * pi * 60.0,
        apply_gyroscopic: bool = false,
        allowed_dofs: AllowedDofs = .{}, // dynamic bodies only; locks world-space axes
        is_sensor: bool = false,
        /// See `Body.report_immovable_contacts`. Off by default: reporting a pair that can
        /// carry no impulse is wasted work unless someone outside is going to act on it.
        report_immovable_contacts: bool = false,
        category: u32 = 0x0000_0001, // one category bit by default
        mask: u32 = 0xFFFF_FFFF, // collides with everything by default
        group_id: u32 = 0, // 0 = ungrouped (no group exclusion)
        user_data: u64 = 0,
        material: u16 = 0, // opaque surface id; per-triangle ids on meshes/height fields override it
        // Full mass + inertia override (dynamic bodies only). When set it supersedes
        // density / override_mass / inertia_multiplier entirely -- the body uses exactly
        // these mass properties. Used by stabilizeRagdoll to write back redistributed mass
        // and raised inertia; also handy for any caller wanting full inertia control.
        mass_props_override: ?MassProperties = null,
    };

    pub fn createBody(world: *World, def: BodyDef) !BodyHandle {
        const shape_ptr: *const Shape = world.shapes.get(def.shape);

        const com_local: Vec = shapeCenterOfMass(shape_ptr);
        const com_world: Vec = def.position + rotate(def.rotation, com_local);

        const local_bounds: Aabb = shapeLocalBounds(shape_ptr);
        const world_bounds: Aabb = transformAabb(local_bounds, com_world, def.rotation);

        const body: Body = .{
            .com_pos = com_world,
            .rot = def.rotation,
            .bounds = world_bounds,
            .shape = def.shape,
            .friction = def.friction,
            .restitution = def.restitution,
            .motion_type = def.motion_type,
            .motion_quality = def.motion_quality,
            .is_sensor = def.is_sensor,
            .report_immovable_contacts = def.report_immovable_contacts,
            .category = def.category,
            .mask = def.mask,
            .group_id = def.group_id,
            .asleep = false,
            .in_broadphase = false,
            .broadphase_node = 0,
            .user_data = def.user_data,
            .material = def.material,
        };

        const handle: BodyHandle = try world.bodies.spawn(world.allocator, body);
        const idx: BodyIndex = handle.index();

        // Compute the dynamic mass properties (the same way regardless of motion type) and keep
        // them so setMotionType can restore them later. The active motion[] gets these only for
        // dynamic bodies; static/kinematic bodies are infinite-mass while in those states.
        var mp: MassProperties = shapeMass(shape_ptr, def.density);
        if (def.override_mass) |om| {
            // Keep the shape's inertia distribution but scale it to the new mass
            // (inertia scales linearly with mass, so inv_inertia scales by 1/ratio).
            const ratio: f32 = om / mp.mass;
            mp.mass = om;
            mp.inv_mass = 1.0 / om;
            mp.inv_inertia_diagonal = mp.inv_inertia_diagonal / splat(ratio);
        }
        if (def.inertia_multiplier != 1.0) {
            mp.inv_inertia_diagonal = mp.inv_inertia_diagonal / splat(def.inertia_multiplier);
        }
        if (def.mass_props_override) |mpo| {
            mp = mpo;
        } // full override wins over the above
        world.mass_props[idx] = mp;

        if (def.motion_type == .dynamic) {
            world.motion[idx] = .{
                .lin_vel = vec_zero,
                .ang_vel = vec_zero,
                .inv_mass = mp.inv_mass,
                .inv_inertia_diagonal = mp.inv_inertia_diagonal,
                .inertia_rotation = mp.inertia_rotation,
                .linear_damping = def.linear_damping,
                .angular_damping = def.angular_damping,
                .gravity_scale = def.gravity_scale,
                .max_linear_speed = def.max_linear_speed,
                .max_angular_speed = def.max_angular_speed,
                .apply_gyroscopic = def.apply_gyroscopic,
                .lin_lock = def.allowed_dofs.linMask(),
                .ang_lock = def.allowed_dofs.angMask(),
                .force = vec_zero,
                .torque = vec_zero,
                .sleep_spheres = Motion.zero.sleep_spheres,
                .sleep_timer = 0.0,
            };
        } else {
            world.motion[idx] = Motion.zero; // static + kinematic: infinite mass
        }

        if (def.motion_type != .static) {
            // Seed the sleep-test spheres at the body's current points so the first
            // step measures real movement rather than a jump from the origin.
            resetSleepSpheres(&world.motion[idx], sleepTestPoints(com_world, def.rotation, shape_ptr));
        }

        if (def.motion_type != .static) {
            try world.active.append(world.allocator, idx);
        }

        const node: u32 = try world.broadphase.insert(world.allocator, idx, world_bounds);
        world.bodies.data[idx].broadphase_node = node;
        world.bodies.data[idx].in_broadphase = true;

        return handle;
    }

    /// Remove a body and free its slot — the inverse of addBody. Drops the broadphase proxy, takes
    /// the body out of the active set, removes any joints (point / six-DOF / path) that reference
    /// it, purges its warm-start cache and contact-event bookkeeping, then frees the ECS slot
    /// (bumping the generation, so any stale BodyHandle now derefs to null). Returns false if `idx`
    /// is not a live body (never added, or already removed — a cheap double-remove guard).
    ///
    /// Caller-owned preconditions (NOT auto-cleaned): the body must not be a vehicle's chassis or
    /// referenced by a soft body — remove those first. After this returns, the BodyIndex is dead;
    /// do not touch it again (a later addBody may recycle the slot for an unrelated body).
    ///
    /// LOUD WARNING: removing a body auto-removes the joints that reference it (otherwise the solver
    /// would dereference a dead slot — silent corruption). That is a safety-first deviation from
    /// Jolt's "remove the constraints first" contract, and because the joint lists are compacted by
    /// swap-remove it INVALIDATES the `usize` indices returned by createSixDofJoint /
    /// createPathJoint for joints that were moved or removed. Re-query any joint indices you hold
    /// after removing a jointed body.
    pub fn removeBody(world: *World, idx: BodyIndex) bool {
        const body: *Body = &world.bodies.data[idx];
        if (!body.in_broadphase) {
            return false;
        }

        // 1. Broadphase proxy.
        world.broadphase.removeProxy(body.broadphase_node);
        body.in_broadphase = false;

        // 2. Active set (present only for awake, non-static bodies).
        var ai: usize = 0;
        while (ai < world.active.items.len) : (ai += 1) {
            if (world.active.items[ai] == idx) {
                _ = world.active.swapRemove(ai);
                break;
            }
        }

        // 3. Joints that reference the body (back-to-front so swapRemove stays correct).
        removeConstraintsReferencing(Constraint, &world.constraints, idx);
        removeConstraintsReferencing(SixDofConstraint, &world.six_dof, idx);
        removeConstraintsReferencing(PathConstraint, &world.paths, idx);

        // 4. Warm-start cache + contact-event sets, so a recycled index can't inherit dead data.
        world.cache.removeBody(world.allocator, idx);
        purgeCacheMap(ManifoldKey, void, &world.contacts_prev, world.allocator, idx);
        purgeCacheMap(ManifoldKey, void, &world.contacts_curr, world.allocator, idx);

        // 5. Free the ECS slot (bumps the generation -> stale handles deref to null).
        const handle: BodyHandle = BodyHandle.pack(@intCast(idx), world.bodies.cycle[idx]);
        _ = handle.destroy(&world.bodies);
        return true;
    }

    // velocity immediately. Anything that adds energy first wakes a sleeping body.
    // -------------------------------------------------------------------------

    /// Wake a sleeping body: put it back in the active set and reset its sleep test.
    /// No-op for an already-awake body or a static one.
    pub fn wakeBody(world: *World, gpa: std.mem.Allocator, idx: BodyIndex) !void {
        const body: *Body = &world.bodies.data[idx];
        if (body.motion_type == .static or !body.asleep) {
            return;
        }
        body.asleep = false;
        try world.active.append(gpa, idx);
        const shape: *const Shape = world.shapes.get(body.shape);
        resetSleepSpheres(&world.motion[idx], sleepTestPoints(body.com_pos, body.rot, shape));
    }

    pub fn activateBody(world: *World, gpa: std.mem.Allocator, idx: BodyIndex) !void {
        try world.wakeBody(gpa, idx);
    }

    pub fn getLinearVelocity(world: *const World, idx: BodyIndex) Vec {
        return world.motion[idx].lin_vel;
    }
    pub fn getAngularVelocity(world: *const World, idx: BodyIndex) Vec {
        return world.motion[idx].ang_vel;
    }
    pub fn setLinearVelocity(
        world: *World,
        gpa: std.mem.Allocator,
        body: BodyHandle,
        v: Vec,
    ) !void {
        const idx: BodyIndex = body.index();
        try world.wakeBody(gpa, idx);
        world.motion[idx].lin_vel = v * world.motion[idx].lin_lock;
    }
    pub fn setAngularVelocity(
        world: *World,
        gpa: std.mem.Allocator,
        body: BodyHandle,
        v: Vec,
    ) !void {
        const idx: BodyIndex = body.index();
        try world.wakeBody(gpa, idx);
        world.motion[idx].ang_vel = v * world.motion[idx].ang_lock;
    }

    /// Set the velocity so the body reaches `target_position` (shape origin) and
    /// `target_rotation` after `dt`, the way a kinematic body is steered toward a target.
    /// Jolt's BodyInterface::MoveKinematic. Wakes the body. For exact tracking the body
    /// should be kinematic (a dynamic body would also feel gravity/forces/contacts); on a
    /// kinematic body it tracks the target exactly and pushes dynamic bodies it meets. Call
    /// every step with the new target.
    pub fn moveKinematic(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        target_position: Vec,
        target_rotation: Quat,
        dt: f32,
    ) !void {
        const shape: *const Shape = world.shapes.get(world.bodies.data[idx].shape);
        const com_pos: Vec = world.bodies.data[idx].com_pos;
        const rot: Quat = world.bodies.data[idx].rot;
        const new_com: Vec = target_position + rotate(target_rotation, shapeCenterOfMass(shape));
        const delta_pos: Vec = new_com - com_pos;
        const delta_rot: Quat = qmul(conjugate(rot), target_rotation);
        try world.setLinearVelocity(gpa, handleOf(world, idx), delta_pos * splat(1.0 / dt));
        try world.setAngularVelocity(gpa, handleOf(world, idx), quatGetAngularVelocity(delta_rot, dt));
    }

    /// Change a body's motion type at runtime (Jolt's BodyInterface::SetMotionType). Switching
    /// to dynamic restores the mass properties captured at creation; switching to kinematic or
    /// static makes the body infinite-mass (kinematic still integrates its velocity, static does
    /// not). Becoming static deactivates the body (drops it from the active set); otherwise, if
    /// `activate` is set and the body is in the broad phase, it is woken. Velocity is preserved
    /// when becoming kinematic/dynamic and zeroed when becoming static; accumulated force and
    /// torque are always cleared, matching Jolt. Lets a ragdoll flip between kinematic
    /// (animation-driven) and dynamic (physics) at runtime.
    pub fn setMotionType(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        new_type: MotionType,
        activate: bool,
    ) !void {
        const body: *Body = &world.bodies.data[idx];
        if (body.motion_type == new_type) {
            return;
        }

        // Becoming static: remove from the active set and mark asleep (Jolt deactivates first).
        if (new_type == .static) {
            var ai: usize = 0;
            while (ai < world.active.items.len) : (ai += 1) {
                if (world.active.items[ai] == idx) {
                    _ = world.active.swapRemove(ai);
                    break;
                }
            }
            body.asleep = true;
        }

        body.motion_type = new_type;

        const m: *Motion = &world.motion[idx];
        switch (new_type) {
            .static => {
                m.lin_vel = vec_zero;
                m.ang_vel = vec_zero;
                m.inv_mass = 0.0;
                m.inv_inertia_diagonal = vec_zero;
                m.force = vec_zero;
                m.torque = vec_zero;
            },
            .kinematic => {
                // Infinite mass to the solver; keeps its velocity (which drives it).
                m.inv_mass = 0.0;
                m.inv_inertia_diagonal = vec_zero;
                m.force = vec_zero;
                m.torque = vec_zero;
            },
            .dynamic => {
                const mp: MassProperties = world.mass_props[idx];
                m.inv_mass = mp.inv_mass;
                m.inv_inertia_diagonal = mp.inv_inertia_diagonal;
                m.inertia_rotation = mp.inertia_rotation;
                m.force = vec_zero;
                m.torque = vec_zero;
            },
        }

        // Activate (non-static) if requested and the body is in the broad phase.
        if (new_type != .static and activate and body.in_broadphase) {
            try world.wakeBody(gpa, idx);
        }

        // Keep the world-space inverse inertia consistent for between-step queries (the step's
        // Phase 1 re-bakes it for active bodies anyway).
        if (m.inv_mass > 0.0) {
            world.inv_inertia_world[idx] = bakeInvInertiaWorld(
                body.rot,
                m.inv_inertia_diagonal,
                m.inertia_rotation,
            );
        } else {
            world.inv_inertia_world[idx] = Mat3.zero;
        }
    }

    /// The body's current motion type. Jolt's BodyInterface::GetMotionType.
    pub fn getMotionType(world: *const World, idx: BodyIndex) MotionType {
        return world.bodies.data[idx].motion_type;
    }
    /// World-space velocity of the material point currently at `world_point`.
    pub fn getPointVelocity(world: *const World, idx: BodyIndex, world_point: Vec) Vec {
        const body: *const Body = &world.bodies.data[idx];
        const m: *const Motion = &world.motion[idx];
        return m.lin_vel + cross(m.ang_vel, world_point - body.com_pos);
    }

    pub fn addForce(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        force: Vec,
    ) !void {
        try world.wakeBody(gpa, idx);
        world.motion[idx].force += force;
    }
    pub fn addForceAtPosition(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        force: Vec,
        world_pos: Vec,
    ) !void {
        try world.wakeBody(gpa, idx);
        const body: *const Body = &world.bodies.data[idx];
        world.motion[idx].force += force;
        world.motion[idx].torque += cross(world_pos - body.com_pos, force);
    }
    pub fn addTorque(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        torque: Vec,
    ) !void {
        try world.wakeBody(gpa, idx);
        world.motion[idx].torque += torque;
    }

    pub fn addImpulse(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        impulse: Vec,
    ) !void {
        try world.wakeBody(gpa, idx);
        const m: *Motion = &world.motion[idx];
        m.lin_vel += impulse * splat(m.inv_mass);
        m.lin_vel *= m.lin_lock;
    }
    pub fn addImpulseAtPosition(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        impulse: Vec,
        world_pos: Vec,
    ) !void {
        try world.wakeBody(gpa, idx);
        const body: *const Body = &world.bodies.data[idx];
        const m: *Motion = &world.motion[idx];
        m.lin_vel += impulse * splat(m.inv_mass);
        const inv_i: Mat3 = bakeInvInertiaWorld(body.rot, m.inv_inertia_diagonal, m.inertia_rotation);
        m.ang_vel += inv_i.mulVec(cross(world_pos - body.com_pos, impulse));
        m.lin_vel *= m.lin_lock;
        m.ang_vel *= m.ang_lock;
    }
    pub fn addAngularImpulse(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        angular_impulse: Vec,
    ) !void {
        try world.wakeBody(gpa, idx);
        const body: *const Body = &world.bodies.data[idx];
        const m: *Motion = &world.motion[idx];
        const inv_i: Mat3 = bakeInvInertiaWorld(body.rot, m.inv_inertia_diagonal, m.inertia_rotation);
        m.ang_vel += inv_i.mulVec(angular_impulse);
        m.ang_vel *= m.ang_lock;
    }

    /// Teleport a body and refresh its broad-phase proxy. `position` is the shape
    /// origin (matching BodyDef.position); the sleep test is reset so the jump is not
    /// mistaken for motion.
    pub fn setTransform(
        world: *World,
        gpa: std.mem.Allocator,
        idx: BodyIndex,
        position: Vec,
        rotation: Quat,
    ) !void {
        const body: *Body = &world.bodies.data[idx];
        const shape: *const Shape = world.shapes.get(body.shape);
        const com_world: Vec = position + rotate(rotation, shapeCenterOfMass(shape));
        body.com_pos = com_world;
        body.rot = rotation;
        body.bounds = transformAabb(shapeLocalBounds(shape), com_world, rotation);
        if (body.in_broadphase) {
            _ = try world.broadphase.moveProxy(gpa, body.broadphase_node, body.bounds, vec_zero);
        }
        if (body.motion_type != .static) {
            try world.wakeBody(gpa, idx);
            resetSleepSpheres(&world.motion[idx], sleepTestPoints(com_world, rotation, shape));
        }
    }
};

/// `createBody` is exposed as a free function — `zimrphysics.createBody(world, def)` — so the
/// 3D creation surface mirrors the 2D engine (`zimrphysics2d.createBody(world, def)`) and the
/// query/constraint free functions below exactly. `world.createBody(def)` also works.
pub const createBody = World.createBody;

/// Read a body's world position (centre of mass) and orientation. Mirrors the 2D engine's
/// `getPosition`/`getRotation` (there returning Vec2/Rot2); cold read-only accessors taking a
/// BodyHandle. `world.bodies.data[..]` stays the internal hot-path access; these are the API.
pub fn getPosition(world: *const World, body: BodyHandle) Vec {
    return world.bodies.data[body.index()].com_pos;
}

pub fn getRotation(world: *const World, body: BodyHandle) Quat {
    return world.bodies.data[body.index()].rot;
}

/// Ball/point joint: holds `world_anchor` coincident on both bodies, leaving all
/// rotation free. Anchors are captured in each body's local frame at creation.
pub fn createPointJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    world_anchor: Vec,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];
    try world.constraints.append(world.allocator, .{
        .kind = .point,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = rotate(conjugate(body_a.rot), world_anchor - body_a.com_pos),
        .local_anchor_b = rotate(conjugate(body_b.rot), world_anchor - body_b.com_pos),
    });
}

/// Fixed/weld joint: freezes the current relative position and orientation of the
/// two bodies (e.g. for gluing parts together, or a breakable joint).
pub fn createWeldJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];
    try world.constraints.append(world.allocator, .{
        .kind = .fixed,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = vec_zero, // weld point at body A's COM
        .local_anchor_b = rotate(conjugate(body_b.rot), body_a.com_pos - body_b.com_pos),
        .inv_initial_rotation = qmul(body_a.rot, conjugate(body_b.rot)),
    });
}

/// Distance joint: constrains the spacing between two world anchor points to
/// [min_distance, max_distance]. Equal bounds give a rigid rod; min=0 gives a rope.
pub fn createDistanceJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    world_anchor_a: Vec,
    world_anchor_b: Vec,
    min_distance: f32,
    max_distance: f32,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];
    try world.constraints.append(world.allocator, .{
        .kind = .distance,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = rotate(conjugate(body_a.rot), world_anchor_a - body_a.com_pos),
        .local_anchor_b = rotate(conjugate(body_b.rot), world_anchor_b - body_b.com_pos),
        .min_distance = min_distance,
        .max_distance = max_distance,
    });
}

/// Wrap an angle into [-pi, pi] (the shortest signed representation).
fn centerAngleAroundZero(angle: f32) f32 {
    const two_pi: f32 = 2.0 * pi;
    var a: f32 = angle;
    while (a < -pi) {
        a += two_pi;
    }
    while (a > pi) {
        a -= two_pi;
    }
    return a;
}

pub const HingeSpec = struct {
    anchor: Vec, // world-space point on the hinge axis
    axis: Vec, // world-space hinge axis (need not be unit length)
    has_limits: bool = false,
    limit_min: f32 = 0.0, // radians, relative to the creation pose (0)
    limit_max: f32 = 0.0,
    motor: MotorSettings = .{},
};

/// Hinge/revolute joint: bodies share `anchor` and may only rotate about `axis`.
/// Optional angle limits and a motor (velocity or position) act about that axis.
pub fn createRevoluteJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    spec: HingeSpec,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];
    const axis_world: Vec = normalize3(spec.axis);
    try world.constraints.append(world.allocator, .{
        .kind = .hinge,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = rotate(conjugate(body_a.rot), spec.anchor - body_a.com_pos),
        .local_anchor_b = rotate(conjugate(body_b.rot), spec.anchor - body_b.com_pos),
        .local_axis_a = rotate(conjugate(body_a.rot), axis_world),
        .local_axis_b = rotate(conjugate(body_b.rot), axis_world),
        .inv_initial_rotation = qmul(body_a.rot, conjugate(body_b.rot)),
        .has_limits = spec.has_limits,
        .limit_min = spec.limit_min,
        .limit_max = spec.limit_max,
        .motor = spec.motor,
    });
}

pub const SliderSpec = struct {
    anchor: Vec, // world-space reference point (offset is measured relative to this)
    axis: Vec, // world-space slide direction (need not be unit length)
    has_limits: bool = false,
    limit_min: f32 = 0.0, // metres along the axis, relative to the creation pose (0)
    limit_max: f32 = 0.0,
    motor: MotorSettings = .{},
};

/// Slider/prismatic joint: bodies may only translate along `axis` (all rotation and
/// the two perpendicular translations are locked). Optional offset limits and a motor.
pub fn createPrismaticJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    spec: SliderSpec,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];
    const axis_world: Vec = normalize3(spec.axis);
    const n1_world: Vec = normalizedPerpendicular(axis_world);
    const n2_world: Vec = cross(axis_world, n1_world);
    const inv_rot_a: Quat = conjugate(body_a.rot);
    try world.constraints.append(world.allocator, .{
        .kind = .slider,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = rotate(inv_rot_a, spec.anchor - body_a.com_pos),
        .local_anchor_b = rotate(conjugate(body_b.rot), spec.anchor - body_b.com_pos),
        .local_axis_a = rotate(inv_rot_a, axis_world),
        .local_normal_a = rotate(inv_rot_a, n1_world),
        .local_normal_b = rotate(inv_rot_a, n2_world),
        .inv_initial_rotation = qmul(body_a.rot, conjugate(body_b.rot)),
        .has_limits = spec.has_limits,
        .limit_min = spec.limit_min,
        .limit_max = spec.limit_max,
        .motor = spec.motor,
    });
}

pub const SwingTwistSpec = struct {
    anchor: Vec, // world-space pivot the two bodies share
    twist_axis: Vec, // world-space twist axis (a bone's long axis); need not be unit
    plane_axis: Vec, // world-space reference axis perpendicular to twist; re-orthonormalized
    swing_type: SwingType = .cone,
    normal_half_cone: f32 = 0.0, // half swing limit about the normal axis, radians
    plane_half_cone: f32 = 0.0, // half swing limit about the plane axis, radians
    twist_min: f32 = 0.0, // twist limit, radians (should be in [-pi, pi])
    twist_max: f32 = 0.0,
    swing_motor: AngularMotorSettings = .{}, // motor that drives the swing (parts Y, Z)
    twist_motor: AngularMotorSettings = .{}, // motor that drives the twist (about X)
    max_friction_torque: f32 = 0.0, // bounded friction applied when a motor is off
};

/// Swing-twist joint: the humanoid-ragdoll joint. Holds `anchor` coincident on both
/// bodies (like a point joint) and limits the relative rotation to a swing cone (or
/// pyramid) about the twist axis plus a twist range about it. Motors are not wired yet;
/// this is the passive (limited) joint that ragdolls are built from.
pub fn createSwingTwistJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    spec: SwingTwistSpec,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];
    // Build the constraint reference frame in world space: X = twist, Y = plane,
    // Z = normal (= plane x twist), matching Jolt's column layout for c_to_body.
    const twist: Vec = normalize3(spec.twist_axis);
    const plane_raw: Vec = spec.plane_axis - twist * splat(dot3(spec.plane_axis, twist));
    const plane: Vec = normalize3(plane_raw);
    const normal: Vec = cross(plane, twist);
    const c_to_world: Quat = quatFromBasis(twist, normal, plane);
    try world.constraints.append(world.allocator, .{
        .kind = .swing_twist,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = rotate(conjugate(body_a.rot), spec.anchor - body_a.com_pos),
        .local_anchor_b = rotate(conjugate(body_b.rot), spec.anchor - body_b.com_pos),
        .constraint_to_body_a = qmul(conjugate(body_a.rot), c_to_world),
        .constraint_to_body_b = qmul(conjugate(body_b.rot), c_to_world),
        .swing_type = spec.swing_type,
        .normal_half_cone = spec.normal_half_cone,
        .plane_half_cone = spec.plane_half_cone,
        .twist_min = spec.twist_min,
        .twist_max = spec.twist_max,
        .swing_motor = spec.swing_motor,
        .twist_motor = spec.twist_motor,
        .max_friction_torque = spec.max_friction_torque,
    });
}

/// Zero the accumulated (warm-start) impulses on a constraint, dispatching on its kind so
/// every constraint type is handled. Jolt's Constraint::ResetWarmStart. Used after teleporting
/// bodies (e.g. Ragdoll.setPose) so the previous frame's impulses are not re-applied.
fn resetConstraintWarmStart(c: *Constraint) void {
    switch (c.kind) {
        .point => {
            c.point_part.total_lambda = vec_zero;
        },
        .fixed => {
            c.point_part.total_lambda = vec_zero;
            c.rotation_lock.total_lambda = vec_zero;
        },
        .distance => {
            c.axis_part.total_lambda = 0.0;
        },
        .hinge => {
            c.point_part.total_lambda = vec_zero;
            c.hinge_rotation.total_lambda = .{ 0.0, 0.0 };
            c.angle_limit.total_lambda = 0.0;
            c.angle_motor.total_lambda = 0.0;
        },
        .slider => {
            c.rotation_lock.total_lambda = vec_zero;
            c.dual_axis.total_lambda = .{ 0.0, 0.0 };
            c.axis_part.total_lambda = 0.0;
            c.axis_motor.total_lambda = 0.0;
        },
        .swing_twist => {
            c.point_part.total_lambda = vec_zero;
            c.swing_twist.swing_y.total_lambda = 0.0;
            c.swing_twist.swing_z.total_lambda = 0.0;
            c.swing_twist.twist.total_lambda = 0.0;
            c.motor_part[0].total_lambda = 0.0;
            c.motor_part[1].total_lambda = 0.0;
            c.motor_part[2].total_lambda = 0.0;
        },
        .gear => {
            c.gear_part.total_lambda = 0.0;
        },
        .rack_and_pinion => {
            c.rack_pinion_part.total_lambda = 0.0;
        },
        .pulley => {
            c.indep_axis_part.total_lambda = 0.0;
        },
    }
}

/// The mass properties a BodyDef resolves to (the same logic addBody applies): the full
/// override if present, otherwise the shape's density-derived properties scaled by
/// override_mass and inertia_multiplier. Used by stabilizeRagdoll.
fn ragdollPartMassProps(shapes: *const ShapeStore, desc: World.BodyDef) MassProperties {
    if (desc.mass_props_override) |mpo| {
        return mpo;
    }
    var mp: MassProperties = shapeMass(shapes.get(desc.shape), desc.density);
    if (desc.override_mass) |om| {
        const ratio: f32 = om / mp.mass;
        mp.mass = om;
        mp.inv_mass = 1.0 / om;
        mp.inv_inertia_diagonal = mp.inv_inertia_diagonal / splat(ratio);
    }
    if (desc.inertia_multiplier != 1.0) {
        mp.inv_inertia_diagonal = mp.inv_inertia_diagonal / splat(desc.inertia_multiplier);
    }
    return mp;
}

/// One rigid part of a ragdoll: the body for a bone plus the joint that attaches it to
/// its parent bone (null for the root, or any part with no parent joint). Jolt's
/// RagdollSettings::Part (a BodyCreationSettings plus a constraint-to-parent).
pub const RagdollPart = struct {
    body: World.BodyDef,
    to_parent: ?SwingTwistSpec = null,
};

/// One joint in a skeleton. Parents must appear before their children in the joint
/// array, so a single forward pass suffices to build poses. Jolt's Skeleton::Joint.
pub const SkeletonJoint = struct {
    name: []const u8 = "", // optional, for lookup / debugging
    parent: i32 = -1, // index of the parent joint in the array, or -1 for the root
};

/// Bone hierarchy shared by a ragdoll's parts (1-on-1 with RagdollSettings.parts).
pub const Skeleton = struct {
    joints: []const SkeletonJoint,

    /// Index of the joint with the given name, or -1 if there is no such joint.
    pub fn jointIndex(self: *const Skeleton, name: []const u8) i32 {
        var i: usize = 0;
        while (i < self.joints.len) : (i += 1) {
            if (std.mem.eql(u8, self.joints[i].name, name)) {
                return @intCast(i);
            }
        }
        return -1;
    }

    /// True if every joint's parent precedes it (required by the build / pose passes).
    pub fn jointsCorrectlyOrdered(self: *const Skeleton) bool {
        var i: usize = 0;
        while (i < self.joints.len) : (i += 1) {
            if (self.joints[i].parent >= @as(i32, @intCast(i))) {
                return false;
            }
        }
        return true;
    }
};

/// Stabilize a ragdoll's mass distribution before building it, by writing a full
/// mass_props_override onto each dynamic part. Jolt's RagdollSettings::Stabilize, based on
/// Oliver Strunk's "Stop my Constraints from Blowing Up!": (1) clamp each parent->child mass
/// ratio into [0.8, 1.2] and redistribute the chain's total mass accordingly, and (2) raise
/// each parent's inertia toward the sum of its children's (capped at 2x). Static / kinematic
/// parts are left untouched and break the chain (a new chain starts under each). Call on a
/// mutable parts array whose shapes are already registered in `shapes`, before constructing
/// RagdollSettings. Returns an error only if the small temporary allocations fail.
///
/// Deviation from Jolt: the inertia-increase step uses each part's largest principal moment
/// as the scalar representative (Jolt uses the [0] entry of its sorted principal
/// decomposition); the result is rebuilt in this World's principal form (a diagonal plus the
/// existing rotation), so no separate eigen-decomposition is needed.
pub fn stabilizeRagdoll(
    gpa: std.mem.Allocator,
    shapes: *const ShapeStore,
    skeleton: Skeleton,
    parts: []RagdollPart,
) !void {
    const n: usize = parts.len;
    if (n == 0) {
        return;
    }

    const visited: []bool = try gpa.alloc(bool, n);
    defer gpa.free(visited);
    const indices: []i32 = try gpa.alloc(i32, n);
    defer gpa.free(indices);
    const mass_ratios: []f32 = try gpa.alloc(f32, n);
    defer gpa.free(mass_ratios);
    const child_sum: []f32 = try gpa.alloc(f32, n);
    defer gpa.free(child_sum);
    const diag_max: []f32 = try gpa.alloc(f32, n);
    defer gpa.free(diag_max);

    // Initialize: compute and store mass properties for dynamic parts; mark the rest visited
    // (their mass is fixed, and they break a chain).
    var i: usize = 0;
    while (i < n) : (i += 1) {
        child_sum[i] = 0.0;
        if (parts[i].body.motion_type == .dynamic) {
            visited[i] = false;
            parts[i].body.mass_props_override = ragdollPartMassProps(shapes, parts[i].body);
        } else {
            visited[i] = true;
        }
    }

    const min_mass_ratio: f32 = 0.8;
    const max_mass_ratio: f32 = 1.2;
    const max_inertia_increase: f32 = 2.0;

    var first_idx: usize = 0;
    while (first_idx < n) : (first_idx += 1) {
        const fparent: i32 = skeleton.joints[first_idx].parent;
        const parent_visited: bool = (fparent < 0) or visited[@intCast(fparent)];
        if (visited[first_idx] or !parent_visited) {
            continue;
        }

        // Gather this chain (BFS, so parents precede children in `indices`).
        var count: usize = 0;
        visited[first_idx] = true;
        indices[count] = @intCast(first_idx);
        count += 1;
        var next: usize = 0;
        while (next < count) {
            const parent_idx: i32 = indices[next];
            next += 1;
            var child: usize = 0;
            while (child < n) : (child += 1) {
                if (!visited[child] and skeleton.joints[child].parent == parent_idx) {
                    visited[child] = true;
                    indices[count] = @intCast(child);
                    count += 1;
                }
            }
        }
        if (count == 1) {
            continue;
        } // single body: nothing to redistribute

        // (1) Clamp parent/child mass ratios, then rescale to preserve the chain's total mass.
        mass_ratios[@as(usize, @intCast(indices[0]))] = 1.0;
        var total_mass_ratio: f32 = 1.0;
        var k: usize = 1;
        while (k < count) : (k += 1) {
            const child_i: usize = @intCast(indices[k]);
            const parent_i: usize = @intCast(skeleton.joints[child_i].parent);
            const child_mass: f32 = parts[child_i].body.mass_props_override.?.mass;
            const parent_mass: f32 = parts[parent_i].body.mass_props_override.?.mass;
            const ratio: f32 = child_mass / parent_mass;
            const clamped_ratio: f32 = clamp(ratio, min_mass_ratio, max_mass_ratio);
            mass_ratios[child_i] = mass_ratios[parent_i] * clamped_ratio;
            total_mass_ratio += mass_ratios[child_i];
        }
        var total_mass: f32 = 0.0;
        k = 0;
        while (k < count) : (k += 1) {
            total_mass += parts[@as(usize, @intCast(indices[k]))].body.mass_props_override.?.mass;
        }
        const ratio_to_mass: f32 = total_mass / total_mass_ratio;
        k = 0;
        while (k < count) : (k += 1) {
            const idx: usize = @intCast(indices[k]);
            const mp: *MassProperties = &parts[idx].body.mass_props_override.?;
            const old_mass: f32 = mp.mass;
            const new_mass: f32 = mass_ratios[idx] * ratio_to_mass;
            const scale: f32 = new_mass / old_mass;
            mp.mass = new_mass;
            mp.inv_mass = 1.0 / new_mass;
            mp.inv_inertia_diagonal = mp.inv_inertia_diagonal / splat(scale); // inertia *= scale
        }

        // (2) Raise parent inertia toward the (scalar) sum of children's largest moments.
        k = 0;
        while (k < count) : (k += 1) {
            const idx: usize = @intCast(indices[k]);
            const inv: Vec = parts[idx].body.mass_props_override.?.inv_inertia_diagonal;
            const d0: f32 = if (inv[0] > 0.0) 1.0 / inv[0] else 0.0;
            const d1: f32 = if (inv[1] > 0.0) 1.0 / inv[1] else 0.0;
            const d2: f32 = if (inv[2] > 0.0) 1.0 / inv[2] else 0.0;
            diag_max[idx] = @max(d0, @max(d1, d2));
        }
        k = count; // walk backwards so leaves are summed first
        while (k > 1) {
            k -= 1;
            const child_i: usize = @intCast(indices[k]);
            const parent_i: usize = @intCast(skeleton.joints[child_i].parent);
            child_sum[parent_i] += diag_max[child_i] + child_sum[child_i];
        }
        k = 0;
        while (k < count) : (k += 1) {
            const idx: usize = @intCast(indices[k]);
            if (child_sum[idx] != 0.0) {
                const minimum: f32 = @min(max_inertia_increase * diag_max[idx], child_sum[idx]);
                const mp: *MassProperties = &parts[idx].body.mass_props_override.?;
                const inv: Vec = mp.inv_inertia_diagonal;
                const d0: f32 = if (inv[0] > 0.0) 1.0 / inv[0] else 0.0;
                const d1: f32 = if (inv[1] > 0.0) 1.0 / inv[1] else 0.0;
                const d2: f32 = if (inv[2] > 0.0) 1.0 / inv[2] else 0.0;
                const floored: Vec = vec(@max(d0, minimum), @max(d1, minimum), @max(d2, minimum));
                mp.inv_inertia_diagonal = reciprocal3(floored);
            }
        }
    }
}

// =============================================================================
// Ragdoll. A skeleton (bone hierarchy) plus one body and one swing-twist joint per
// bone -- the assembly layer on top of the swing-twist constraint. Build the bodies +
// joints into a World, drive them to a pose, and read the pose back. Mirrors Jolt's
// Skeleton / RagdollSettings / Ragdoll, adapted to this World's COM-centric body API.
// =============================================================================

/// Parameters for a distance additional-constraint (the free createDistanceJoint takes
/// these as separate args; bundled here so it fits the additional-constraint union).
pub const RagdollDistanceSpec = struct {
    anchor_a: Vec, // world-space anchor on body A
    anchor_b: Vec, // world-space anchor on body B
    min_distance: f32,
    max_distance: f32,
};

/// The constraint used by an additional (non-parent-child) ragdoll constraint. Mirrors the
/// fact that Jolt's AdditionalConstraint can be any TwoBodyConstraintSettings: one variant
/// per constraint builder this file provides.
pub const RagdollConstraintSpec = union(enum) {
    point: Vec, // world-space anchor (createPointJoint)
    fixed: void, // weld (createWeldJoint)
    distance: RagdollDistanceSpec,
    hinge: HingeSpec,
    slider: SliderSpec,
    swing_twist: SwingTwistSpec,
};

/// A constraint that connects two ragdoll parts that are not in a parent/child relationship
/// (e.g. closing a loop). Jolt's RagdollSettings::AdditionalConstraint. `part_a` / `part_b`
/// index into RagdollSettings.parts.
pub const RagdollAdditionalConstraint = struct {
    part_a: usize,
    part_b: usize,
    constraint: RagdollConstraintSpec,
};

/// The full description of a ragdoll: a skeleton, one part per joint, and any extra
/// loop-closing constraints. The part at index i is attached, via part.to_parent, to the
/// body at skeleton.joints[i].parent; the additional constraints connect arbitrary part
/// pairs.
pub const RagdollSettings = struct {
    skeleton: Skeleton,
    parts: []const RagdollPart,
    additional: []const RagdollAdditionalConstraint = &.{},
};

/// World-space transform of one bone (origin + rotation): the unit of a ragdoll pose.
/// `position` is the shape origin (matching BodyDef.position), NOT the centre of mass.
pub const BoneTransform = struct {
    position: Vec,
    rotation: Quat = quat_identity,
};

/// Set the swing motor state. Changing it deactivates the motor parts so the next step does
/// not warm-start with a stale impulse. Jolt's SetSwingMotorState.
pub fn swingTwistSetSwingMotorState(c: *Constraint, state: MotorState) void {
    if (c.swing_motor_state != state) {
        c.swing_motor_state = state;
        c.motor_part[0] = AngleConstraintPart.inactive;
        c.motor_part[1] = AngleConstraintPart.inactive;
        c.motor_part[2] = AngleConstraintPart.inactive;
    }
}

/// Set the twist motor state (deactivates the twist motor part on change). Jolt's
/// SetTwistMotorState.
pub fn swingTwistSetTwistMotorState(c: *Constraint, state: MotorState) void {
    if (c.twist_motor_state != state) {
        c.twist_motor_state = state;
        c.motor_part[0] = AngleConstraintPart.inactive;
    }
}

/// Set the motor target angular velocity from a body-B-space value. Jolt's
/// SetTargetAngularVelocityBS (inverse-rotates by constraint_to_body_b).
pub fn swingTwistSetTargetAngularVelocityBS(c: *Constraint, ang_vel_bs: Vec) void {
    c.target_angular_velocity = rotate(conjugate(c.constraint_to_body_b), ang_vel_bs);
}

/// Set the motor target orientation, given in constraint space, clamped to the joint limits
/// so the motor never fights the limit constraints. Jolt's SetTargetOrientationCS.
pub fn swingTwistSetTargetOrientationCS(c: *Constraint, orientation_cs: Quat) void {
    c.swing_twist.swing_type = c.swing_type;
    c.swing_twist.setLimits(
        c.twist_min,
        c.twist_max,
        -c.plane_half_cone,
        c.plane_half_cone,
        -c.normal_half_cone,
        c.normal_half_cone,
    );
    const st: SwingTwistPair = quatGetSwingTwist(orientation_cs);
    var q_swing: Quat = st.swing;
    var q_twist: Quat = st.twist;
    const clamped: u32 = c.swing_twist.clampSwingTwist(&q_swing, &q_twist);
    if (clamped != 0) {
        c.target_orientation = qmul(q_swing, q_twist);
    } else {
        c.target_orientation = orientation_cs;
    }
}

/// Set the motor target orientation from a body-space rotation of B relative to A
/// (R2 = R1 * orientation_bs). Jolt's SetTargetOrientationBS.
pub fn swingTwistSetTargetOrientationBS(c: *Constraint, orientation_bs: Quat) void {
    const target_cs: Quat = qmul(conjugate(c.constraint_to_body_a), qmul(orientation_bs, c.constraint_to_body_b));
    swingTwistSetTargetOrientationCS(c, target_cs);
}

/// A live ragdoll: the bodies (one per part) and joints created in a World. Build it with
/// Ragdoll.instantiate, drive it with setPose, read it back with getPose. Jolt's Ragdoll.
/// The bodies and constraints live in the World; deinit frees only this handle's own
/// memory (this World has no body/constraint removal yet).
pub const Ragdoll = struct {
    body_indices: []BodyIndex, // one per part (owned by this handle)
    parents: []i32, // parent part index per part (-1 for root); owned by this handle
    constraint_of: []i32, // world.constraints index of each part's parent joint, or -1
    first_constraint: usize, // index in world.constraints of this ragdoll's first joint
    constraint_count: usize, // number of joints this ragdoll added (contiguous from first)
    allocator: std.mem.Allocator,

    /// Create all the bodies and joints for `settings` in `world`. Bodies are placed at
    /// their BodyDef transforms (the bind pose); each joint then reads those transforms to
    /// capture its reference frame, so a part's to_parent anchor/axes are world space at the
    /// bind pose. The caller owns the returned handle (call deinit). On error the bodies and
    /// joints already created remain in the World (no removal API), but the handle's own
    /// allocation is released.
    pub fn instantiate(
        world: *World,
        gpa: std.mem.Allocator,
        settings: RagdollSettings,
    ) !Ragdoll {
        const part_count: usize = settings.parts.len;
        const body_indices: []BodyIndex = try gpa.alloc(BodyIndex, part_count);
        errdefer gpa.free(body_indices);
        const parents: []i32 = try gpa.alloc(i32, part_count);
        errdefer gpa.free(parents);
        const constraint_of: []i32 = try gpa.alloc(i32, part_count);
        errdefer gpa.free(constraint_of);

        // (1) One body per part; record the parent index and clear the joint map.
        var i: usize = 0;
        while (i < part_count) : (i += 1) {
            parents[i] = settings.skeleton.joints[i].parent;
            constraint_of[i] = -1;
            body_indices[i] = (try world.createBody(settings.parts[i].body)).index();
        }

        // (2) One joint per non-root part, connecting it to its parent's body.
        const first_constraint: usize = world.constraints.items.len;
        var added: usize = 0;
        i = 0;
        while (i < part_count) : (i += 1) {
            if (settings.parts[i].to_parent) |spec| {
                const parent: i32 = parents[i];
                if (parent >= 0) {
                    const parent_idx: BodyIndex = body_indices[@intCast(parent)];
                    constraint_of[i] = @intCast(world.constraints.items.len);
                    try createSwingTwistJoint(
                        world,
                        handleOf(world, parent_idx),
                        handleOf(world, body_indices[i]),
                        spec,
                    );
                    added += 1;
                }
            }
        }

        // (3) Additional (non-parent-child) constraints, e.g. loop closures. Added after the
        // parent joints so the ragdoll's constraints stay contiguous from first_constraint.
        i = 0;
        while (i < settings.additional.len) : (i += 1) {
            const ac: RagdollAdditionalConstraint = settings.additional[i];
            if (ac.part_a >= part_count or ac.part_b >= part_count) {
                continue;
            }
            const a: BodyHandle = handleOf(world, body_indices[ac.part_a]);
            const b: BodyHandle = handleOf(world, body_indices[ac.part_b]);
            switch (ac.constraint) {
                .point => |anchor| try createPointJoint(world, a, b, anchor),
                .fixed => try createWeldJoint(world, a, b),
                .distance => |d| try createDistanceJoint(
                    world,
                    a,
                    b,
                    d.anchor_a,
                    d.anchor_b,
                    d.min_distance,
                    d.max_distance,
                ),
                .hinge => |h| try createRevoluteJoint(world, a, b, h),
                .slider => |s| try createPrismaticJoint(world, a, b, s),
                .swing_twist => |st| try createSwingTwistJoint(world, a, b, st),
            }
            added += 1;
        }

        return .{
            .body_indices = body_indices,
            .parents = parents,
            .constraint_of = constraint_of,
            .first_constraint = first_constraint,
            .constraint_count = added,
            .allocator = gpa,
        };
    }

    /// Free the handle's own memory. Call once. The bodies and joints stay in the World (a
    /// future World.removeBody / removeConstraint would let this also despawn them).
    pub fn deinit(self: *Ragdoll) void {
        self.allocator.free(self.body_indices);
        self.allocator.free(self.parents);
        self.allocator.free(self.constraint_of);
    }

    /// Teleport every bone body to the matching transform (origin + rotation). Wakes the
    /// bodies (this World's setTransform always wakes; Jolt's SetPose does not activate).
    /// After a large jump, consider resetWarmStart to drop the previous frame's impulses.
    pub fn setPose(
        self: *const Ragdoll,
        world: *World,
        gpa: std.mem.Allocator,
        transforms: []const BoneTransform,
    ) !void {
        const n: usize = @min(self.body_indices.len, transforms.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try world.setTransform(gpa, self.body_indices[i], transforms[i].position, transforms[i].rotation);
        }
    }

    /// Read every bone body's current world transform (origin + rotation) into `out`.
    pub fn getPose(self: *const Ragdoll, world: *const World, out: []BoneTransform) void {
        const n: usize = @min(self.body_indices.len, out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const body: *const Body = &world.bodies.data[self.body_indices[i]];
            const shape: *const Shape = world.shapes.get(body.shape);
            const origin: Vec = body.com_pos - rotate(body.rot, shapeCenterOfMass(shape));
            out[i] = .{ .position = origin, .rotation = body.rot };
        }
    }

    /// Zero the accumulated (warm-start) impulses on this ragdoll's joints. Useful right
    /// after a large setPose jump so stale impulses don't get re-applied. Jolt's
    /// Ragdoll::ResetWarmStart.
    pub fn resetWarmStart(self: *const Ragdoll, world: *World) void {
        var k: usize = 0;
        while (k < self.constraint_count) : (k += 1) {
            resetConstraintWarmStart(&world.constraints.items[self.first_constraint + k]);
        }
    }

    /// Drive the ragdoll toward `pose` by switching each joint's swing and twist motors to a
    /// position drive and pointing them at the pose's local joint rotation. The pose holds
    /// world-space bone transforms; the target for joint i is B-relative-to-A, derived as
    /// conj(pose[parent].rotation) * pose[i].rotation. Jolt's DriveToPoseUsingMotors. The
    /// motor stiffness/damping/torque come from each joint's swing_motor / twist_motor
    /// settings, so set those (e.g. via the part's to_parent spec) before driving.
    pub fn driveToPoseUsingMotors(
        self: *const Ragdoll,
        world: *World,
        pose: []const BoneTransform,
    ) void {
        var i: usize = 0;
        while (i < self.constraint_of.len) : (i += 1) {
            const ci: i32 = self.constraint_of[i];
            const parent: i32 = self.parents[i];
            if (ci >= 0 and parent >= 0) {
                const par_idx: usize = @intCast(parent);
                if (par_idx < pose.len and i < pose.len) {
                    const c: *Constraint = &world.constraints.items[@intCast(ci)];
                    const target_bs: Quat = qmul(pose[i].rotation, conjugate(pose[par_idx].rotation));
                    swingTwistSetSwingMotorState(c, .position);
                    swingTwistSetTwistMotorState(c, .position);
                    swingTwistSetTargetOrientationBS(c, target_bs);
                }
            }
        }
    }

    /// Drive the ragdoll toward `pose` while also matching the angular velocity implied by
    /// the change from `prev_pose` over `dt` (a position-and-velocity drive). Jolt's
    /// DriveToPoseUsingMotors(prev, pose, dt). `dt` must be > 0.
    pub fn driveToPoseUsingMotorsVelocity(
        self: *const Ragdoll,
        world: *World,
        prev_pose: []const BoneTransform,
        pose: []const BoneTransform,
        dt: f32,
    ) void {
        var i: usize = 0;
        while (i < self.constraint_of.len) : (i += 1) {
            const ci: i32 = self.constraint_of[i];
            const parent: i32 = self.parents[i];
            if (ci >= 0 and parent >= 0) {
                const par_idx: usize = @intCast(parent);
                if (par_idx < pose.len and i < pose.len and par_idx < prev_pose.len and i < prev_pose.len) {
                    const c: *Constraint = &world.constraints.items[@intCast(ci)];
                    // Target orientation: B relative to A in the new pose.
                    const cur_local: Quat = qmul(pose[i].rotation, conjugate(pose[par_idx].rotation));
                    const prev_parent_inv: Quat = conjugate(prev_pose[par_idx].rotation);
                    const prev_local: Quat = qmul(prev_pose[i].rotation, prev_parent_inv);
                    // Angular velocity (in body A / local-joint frame) to go prev -> cur in dt,
                    // then re-expressed in body B space, matching Jolt.
                    const delta: Quat = qmul(conjugate(prev_local), cur_local);
                    const ang_vel_a: Vec = quatGetAngularVelocity(delta, dt);
                    const r1: Quat = world.bodies.data[c.body_a].rot;
                    const r2: Quat = world.bodies.data[c.body_b].rot;
                    const body1_to_body2: Quat = qmul(r1, conjugate(r2));
                    const ang_vel_b: Vec = rotate(body1_to_body2, ang_vel_a);
                    swingTwistSetSwingMotorState(c, .position_and_velocity);
                    swingTwistSetTwistMotorState(c, .position_and_velocity);
                    swingTwistSetTargetAngularVelocityBS(c, ang_vel_b);
                    swingTwistSetTargetOrientationBS(c, cur_local);
                }
            }
        }
    }

    /// Drive the ragdoll to `pose` kinematically: each bone body is steered (via
    /// World.moveKinematic) to exactly reach its pose transform after `dt`. Jolt's
    /// DriveToPoseUsingKinematics. For exact tracking the parts should be kinematic
    /// (motion_type = .kinematic) -- then they follow the animation precisely and push any
    /// dynamic bodies they hit, while the joints (two infinite-mass bodies) stay inert. Call
    /// every step with the new pose.
    pub fn driveToPoseUsingKinematics(
        self: *const Ragdoll,
        world: *World,
        gpa: std.mem.Allocator,
        pose: []const BoneTransform,
        dt: f32,
    ) !void {
        const n: usize = @min(self.body_indices.len, pose.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try world.moveKinematic(gpa, self.body_indices[i], pose[i].position, pose[i].rotation, dt);
        }
    }

    /// Set the same linear and angular velocity on every body (e.g. to launch a ragdoll).
    pub fn setLinearAndAngularVelocity(
        self: *const Ragdoll,
        world: *World,
        gpa: std.mem.Allocator,
        linear: Vec,
        angular: Vec,
    ) !void {
        var i: usize = 0;
        while (i < self.body_indices.len) : (i += 1) {
            try world.setLinearVelocity(gpa, handleOf(world, self.body_indices[i]), linear);
            try world.setAngularVelocity(gpa, handleOf(world, self.body_indices[i]), angular);
        }
    }

    /// Add the same world-space impulse at the centre of mass of every body.
    pub fn addImpulse(
        self: *const Ragdoll,
        world: *World,
        gpa: std.mem.Allocator,
        impulse: Vec,
    ) !void {
        var i: usize = 0;
        while (i < self.body_indices.len) : (i += 1) {
            try world.addImpulse(gpa, self.body_indices[i], impulse);
        }
    }

    /// Wake every body in the ragdoll.
    pub fn activate(self: *const Ragdoll, world: *World, gpa: std.mem.Allocator) !void {
        var i: usize = 0;
        while (i < self.body_indices.len) : (i += 1) {
            try world.activateBody(gpa, self.body_indices[i]);
        }
    }

    /// World transform (origin + rotation) of the root bone (part 0).
    pub fn getRootTransform(self: *const Ragdoll, world: *const World) BoneTransform {
        const body: *const Body = &world.bodies.data[self.body_indices[0]];
        const shape: *const Shape = world.shapes.get(body.shape);
        const origin: Vec = body.com_pos - rotate(body.rot, shapeCenterOfMass(shape));
        return .{ .position = origin, .rotation = body.rot };
    }
};

// =============================================================================
// The world.
// =============================================================================

// =============================================================================
// Constraint atoms. AxisPart is Jolt's AxisConstraintPart (1-DOF, linear+angular):
// it backs the contact normal, the two linear friction directions, and (later) the
// joints. AngularPart is Jolt's AngularFrictionConstraintPart (angular-only): it
// backs torsional friction. Statics carry inv_mass 0 and zero cached inertia terms,
// so they absorb impulses with zero motion and no branch on motion type.
// =============================================================================
// it backs the contact normal, the two linear friction directions, and (later) the
// joints. AngularPart is Jolt's AngularFrictionConstraintPart (angular-only): it
// backs torsional friction. Statics carry inv_mass 0 and zero cached inertia terms,
// so they absorb impulses with zero motion and no branch on motion type.
// =============================================================================

/// Angular-only (torsional) friction about the contact normal. Jolt's
/// AngularFrictionConstraintPart.
pub const AngularPart = struct {
    inv_i1_axis: Vec, // I1^-1 axis
    inv_i2_axis: Vec, // I2^-1 axis
    effective_mass: f32,
    total_lambda: f32,

    pub const inactive: AngularPart = .{
        .inv_i1_axis = vec_zero,
        .inv_i2_axis = vec_zero,
        .effective_mass = 0.0,
        .total_lambda = 0.0,
    };

    pub fn isActive(part: *const AngularPart) bool {
        return part.effective_mass != 0.0;
    }

    pub fn prepare(
        part: *AngularPart,
        inv_i_a: Mat3,
        inv_i_b: Mat3,
        axis: Vec,
    ) void {
        const i1a: Vec = inv_i_a.mulVec(axis);
        const i2a: Vec = inv_i_b.mulVec(axis);
        const inv_eff_mass: f32 = dot3(axis, i1a + i2a);
        part.inv_i1_axis = i1a;
        part.inv_i2_axis = i2a;
        part.effective_mass = if (inv_eff_mass != 0.0) 1.0 / inv_eff_mass else 0.0;
    }

    pub fn applyImpulse(
        part: *const AngularPart,
        ma: *Motion,
        mb: *Motion,
        lambda: f32,
    ) void {
        ma.ang_vel -= splat(lambda) * part.inv_i1_axis;
        mb.ang_vel += splat(lambda) * part.inv_i2_axis;
    }

    pub fn warmStart(
        part: *AngularPart,
        ma: *Motion,
        mb: *Motion,
        impulse_ratio: f32,
    ) void {
        part.total_lambda *= impulse_ratio;
        part.applyImpulse(ma, mb, part.total_lambda);
    }

    pub fn solveVelocity(
        part: *AngularPart,
        ma: *Motion,
        mb: *Motion,
        axis: Vec,
        min: f32,
        max: f32,
    ) void {
        const jv: f32 = dot3(axis, ma.ang_vel - mb.ang_vel);
        const lambda: f32 = part.effective_mass * jv;
        const new_total: f32 = clamp(part.total_lambda + lambda, min, max);
        const applied: f32 = new_total - part.total_lambda;
        part.total_lambda = new_total;
        part.applyImpulse(ma, mb, applied);
    }
};

// -----------------------------------------------------------------------------
// Swing-twist helpers (used by the swing-twist / ragdoll joint). These mirror the
// Jolt math: Quat::GetSwingTwist, a matrix-free basis->quaternion, and the closest
// point on an axis-aligned ellipse (the cone swing limit).
// -----------------------------------------------------------------------------

// --- Swing-twist motor control + setup --------------------------------------------------
// The swing-twist joint can run motors that drive body B toward a target orientation and/or
// angular velocity relative to body A (Jolt's SwingTwistConstraint motors). The twist motor
// drives motor_part[0] (about the twist/X axis); the swing motor drives motor_part[1] and
// [2] (the Y/Z axes). Targets live in the joint's constraint space; the *BS helpers accept
// body-space values and convert. These set fields read by prepareSwingTwistMotors each step.

/// Set the motor target angular velocity (in constraint space). Jolt's
/// SetTargetAngularVelocityCS.
pub fn swingTwistSetTargetAngularVelocityCS(c: *Constraint, ang_vel_cs: Vec) void {
    c.target_angular_velocity = ang_vel_cs;
}

/// Build the swing-twist motor constraint parts for this try step (Jolt's motor block in
/// SetupVelocityConstraint). The three motor axes are body B's constraint-space axes in
/// world space; the twist motor uses axis 0, the swing motor uses axes 1 and 2. Also
/// precomputes the per-step torque-impulse clamps consumed by the velocity solve. `q` is the
/// current constraint rotation (body A frame -> body B frame); `cb2_to_world` maps body B's
/// constraint frame to world.
fn prepareSwingTwistMotors(
    c: *Constraint,
    inv_i_a: Mat3,
    inv_i_b: Mat3,
    cb2_to_world: Quat,
    q: Quat,
    dt: f32,
) void {
    if (c.swing_motor_state != .off or c.twist_motor_state != .off or c.max_friction_torque > 0.0) {
        c.motor_axis[0] = rotate(cb2_to_world, vec(1.0, 0.0, 0.0));
        c.motor_axis[1] = rotate(cb2_to_world, vec(0.0, 1.0, 0.0));
        c.motor_axis[2] = rotate(cb2_to_world, vec(0.0, 0.0, 1.0));

        var rotation_error: Vec = vec_zero;
        if (isPositionMotor(c.swing_motor_state) or isPositionMotor(c.twist_motor_state)) {
            const dotv: f32 = dot4(q, c.target_orientation);
            const target: Quat = if (dotv > 0.0) c.target_orientation else -c.target_orientation;
            const diff: Quat = qmul(conjugate(q), target);
            rotation_error = vec(diff[0], diff[1], diff[2]) * splat(-2.0);
        }

        // Swing motor: drives parts 1 and 2.
        switch (c.swing_motor_state) {
            .off => {
                if (c.max_friction_torque > 0.0) {
                    c.motor_part[1].prepare(inv_i_a, inv_i_b, c.motor_axis[1], 0.0);
                    c.motor_part[2].prepare(inv_i_a, inv_i_b, c.motor_axis[2], 0.0);
                } else {
                    c.motor_part[1] = AngleConstraintPart.inactive;
                    c.motor_part[2] = AngleConstraintPart.inactive;
                }
            },
            .velocity => {
                c.motor_part[1].prepare(inv_i_a, inv_i_b, c.motor_axis[1], -c.target_angular_velocity[1]);
                c.motor_part[2].prepare(inv_i_a, inv_i_b, c.motor_axis[2], -c.target_angular_velocity[2]);
            },
            .position => {
                if (c.swing_motor.frequency > 0.0) {
                    c.motor_part[1].prepareSpring(
                        inv_i_a,
                        inv_i_b,
                        c.motor_axis[1],
                        0.0,
                        rotation_error[1],
                        c.swing_motor.frequency,
                        c.swing_motor.damping,
                        dt,
                    );
                    c.motor_part[2].prepareSpring(
                        inv_i_a,
                        inv_i_b,
                        c.motor_axis[2],
                        0.0,
                        rotation_error[2],
                        c.swing_motor.frequency,
                        c.swing_motor.damping,
                        dt,
                    );
                } else {
                    c.motor_part[1] = AngleConstraintPart.inactive;
                    c.motor_part[2] = AngleConstraintPart.inactive;
                }
            },
            .position_and_velocity => {
                if (c.swing_motor.frequency > 0.0 or c.swing_motor.damping > 0.0) {
                    c.motor_part[1].prepareSpring(
                        inv_i_a,
                        inv_i_b,
                        c.motor_axis[1],
                        -c.target_angular_velocity[1],
                        rotation_error[1],
                        c.swing_motor.frequency,
                        c.swing_motor.damping,
                        dt,
                    );
                    c.motor_part[2].prepareSpring(
                        inv_i_a,
                        inv_i_b,
                        c.motor_axis[2],
                        -c.target_angular_velocity[2],
                        rotation_error[2],
                        c.swing_motor.frequency,
                        c.swing_motor.damping,
                        dt,
                    );
                } else {
                    c.motor_part[1] = AngleConstraintPart.inactive;
                    c.motor_part[2] = AngleConstraintPart.inactive;
                }
            },
        }

        // Twist motor: drives part 0.
        switch (c.twist_motor_state) {
            .off => {
                if (c.max_friction_torque > 0.0) {
                    c.motor_part[0].prepare(inv_i_a, inv_i_b, c.motor_axis[0], 0.0);
                } else {
                    c.motor_part[0] = AngleConstraintPart.inactive;
                }
            },
            .velocity => {
                c.motor_part[0].prepare(inv_i_a, inv_i_b, c.motor_axis[0], -c.target_angular_velocity[0]);
            },
            .position => {
                if (c.twist_motor.frequency > 0.0) {
                    c.motor_part[0].prepareSpring(
                        inv_i_a,
                        inv_i_b,
                        c.motor_axis[0],
                        0.0,
                        rotation_error[0],
                        c.twist_motor.frequency,
                        c.twist_motor.damping,
                        dt,
                    );
                } else {
                    c.motor_part[0] = AngleConstraintPart.inactive;
                }
            },
            .position_and_velocity => {
                if (c.twist_motor.frequency > 0.0 or c.twist_motor.damping > 0.0) {
                    c.motor_part[0].prepareSpring(
                        inv_i_a,
                        inv_i_b,
                        c.motor_axis[0],
                        -c.target_angular_velocity[0],
                        rotation_error[0],
                        c.twist_motor.frequency,
                        c.twist_motor.damping,
                        dt,
                    );
                } else {
                    c.motor_part[0] = AngleConstraintPart.inactive;
                }
            },
        }

        // Per-step torque-impulse clamps (= torque * dt) read by the velocity solve. When a
        // motor is off but friction is enabled, the clamp is the symmetric friction torque.
        if (c.twist_motor_state == .off) {
            c.twist_motor_hi = dt * c.max_friction_torque;
            c.twist_motor_lo = -c.twist_motor_hi;
        } else {
            c.twist_motor_lo = dt * c.twist_motor.min_torque;
            c.twist_motor_hi = dt * c.twist_motor.max_torque;
        }
        if (c.swing_motor_state == .off) {
            c.swing_motor_hi = dt * c.max_friction_torque;
            c.swing_motor_lo = -c.swing_motor_hi;
        } else {
            c.swing_motor_lo = dt * c.swing_motor.min_torque;
            c.swing_motor_hi = dt * c.swing_motor.max_torque;
        }
    } else {
        c.motor_part[0] = AngleConstraintPart.inactive;
        c.motor_part[1] = AngleConstraintPart.inactive;
        c.motor_part[2] = AngleConstraintPart.inactive;
    }
}

// =============================================================================
// Narrow phase. One dispatch on the (sorted) shape-tag pair, producing a Manifold.
// Each manifold point carries the contact point on EACH body (Jolt's mPosition1 /
// mPosition2): the midpoint feeds r1/r2, the difference along the normal feeds the
// penetration, and the two points (tracked in local space) drive the position pass.
// =============================================================================

/// Collision-permission test consulted everywhere the simulation would create an
/// interaction (island links, contacts, CCD). Category/mask is the usual "what
/// collides with what"; a shared nonzero group_id excludes a set of bodies from
/// colliding with one another (e.g. a ragdoll's bones, or parts of one assembly).
fn bodiesShouldCollide(a: *const Body, b: *const Body) bool {
    if (a.group_id != 0 and a.group_id == b.group_id) {
        return false;
    }
    return (a.category & b.mask) != 0 and (b.category & a.mask) != 0;
}

/// Sphere (centre `sphere_pos`, radius r) vs box (half-extent he, posed). `flip`
/// means the caller passed the shapes swapped, so the output is relabelled and the
/// normal points along original A -> B.
fn collideSphereBox(
    r: f32,
    sphere_pos: Vec,
    he: Vec,
    box_pos: Vec,
    box_rot: Quat,
    speculative_distance: f32,
    flip: bool,
) ?Manifold {
    const box_rot_inv: Quat = conjugate(box_rot);
    const local_center: Vec = rotate(box_rot_inv, sphere_pos - box_pos);

    const clamped: Vec = clamp(local_center, -he, he);
    const to_center: Vec = local_center - clamped;
    const dist: f32 = length3(to_center);
    const separation: f32 = dist - r;
    if (separation > speculative_distance) {
        return null;
    }

    // ★★ THE POINT ON THE BOX, WHICH FOR AN INTERIOR CENTRE IS NOT `clamped`.
    //
    // `clamp` leaves a point already inside the box exactly where it was, so `point_on_box`
    // came out AT the sphere's own centre and the reported depth was a constant **−radius**
    // however deep it had sunk. Invisible while only spheres used this path — a sphere fully
    // inside a box is rare — and load-bearing the moment `collideCapsuleBox` began asking about
    // segment points that routinely are. Projecting onto the nearest FACE makes the depth true.
    var surface: Vec = clamped;
    var local_normal: Vec = undefined;
    if (dist > 1.0e-6) {
        local_normal = to_center / splat(dist);
    } else {
        const dx: f32 = he[0] - @abs(local_center[0]);
        const dy: f32 = he[1] - @abs(local_center[1]);
        const dz: f32 = he[2] - @abs(local_center[2]);
        if (dx <= dy and dx <= dz) {
            local_normal = vec(std.math.sign(local_center[0]), 0, 0);
            surface[0] = std.math.sign(local_center[0]) * he[0];
        } else if (dy <= dz) {
            local_normal = vec(0, std.math.sign(local_center[1]), 0);
            surface[1] = std.math.sign(local_center[1]) * he[1];
        } else {
            local_normal = vec(0, 0, std.math.sign(local_center[2]));
            surface[2] = std.math.sign(local_center[2]) * he[2];
        }
    }

    const box_to_sphere: Vec = rotate(box_rot, local_normal); // world, box -> sphere
    const point_on_box: Vec = box_pos + rotate(box_rot, surface);
    const point_on_sphere: Vec = sphere_pos - box_to_sphere * splat(r);

    // Output in terms of the ORIGINAL A, B with the normal along A -> B.
    var m: Manifold = .{ .normal = undefined, .count = 1, .points = undefined };
    if (!flip) {
        // A = sphere, B = box. Normal A -> B = sphere -> box = -box_to_sphere.
        m.normal = -box_to_sphere;
        m.points[0] = .{ .point_on_a = point_on_sphere, .point_on_b = point_on_box, .feature_id = 0 };
    } else {
        // A = box, B = sphere. Normal A -> B = box -> sphere = +box_to_sphere.
        m.normal = box_to_sphere;
        m.points[0] = .{ .point_on_a = point_on_box, .point_on_b = point_on_sphere, .feature_id = 0 };
    }
    return m;
}

fn boxAxes(rot: Quat) [3]Vec {
    return .{
        rotate(rot, vec(1, 0, 0)),
        rotate(rot, vec(0, 1, 0)),
        rotate(rot, vec(0, 0, 1)),
    };
}

fn boxProjectedRadius(axes: [3]Vec, he: Vec, axis: Vec) f32 {
    const px: f32 = @abs(dot3(axis, axes[0])) * he[0];
    const py: f32 = @abs(dot3(axis, axes[1])) * he[1];
    const pz: f32 = @abs(dot3(axis, axes[2])) * he[2];
    return px + py + pz;
}

fn supportEdge(
    center: Vec,
    axes: [3]Vec,
    he: Vec,
    edge_axis: u32,
    dir: Vec,
) [2]Vec {
    const i: u32 = edge_axis;
    const j: u32 = (edge_axis + 1) % 3;
    const k: u32 = (edge_axis + 2) % 3;

    const sj: f32 = if (dot3(dir, axes[j]) >= 0.0) 1.0 else -1.0;
    const sk: f32 = if (dot3(dir, axes[k]) >= 0.0) 1.0 else -1.0;

    const corner: Vec = center + axes[j] * splat(sj * vlane(he, j)) + axes[k] * splat(sk * vlane(he, k));
    const half_edge: Vec = axes[i] * splat(vlane(he, i));
    return .{ corner - half_edge, corner + half_edge };
}

fn boxFace(
    center: Vec,
    axes: [3]Vec,
    he: Vec,
    face_axis: u32,
    sign: f32,
) [4]Vec {
    const i: u32 = face_axis;
    const j: u32 = (face_axis + 1) % 3;
    const k: u32 = (face_axis + 2) % 3;

    const outward: Vec = axes[i] * splat(sign);
    const face_center: Vec = center + outward * splat(vlane(he, i));
    const u: Vec = axes[j] * splat(vlane(he, j));
    const v: Vec = axes[k] * splat(vlane(he, k));

    return .{ face_center - u - v, face_center + u - v, face_center + u + v, face_center - u + v };
}

fn clipPolygonToPlane(
    poly: []const Vec,
    plane_normal: Vec,
    offset: f32,
    out: *[8]Vec,
) usize {
    var count: usize = 0;
    var prev: Vec = poly[poly.len - 1];
    var prev_dist: f32 = dot3(plane_normal, prev) - offset;

    for (poly) |curr| {
        const curr_dist: f32 = dot3(plane_normal, curr) - offset;
        const prev_inside: bool = prev_dist <= 0.0;
        const curr_inside: bool = curr_dist <= 0.0;
        if (curr_inside) {
            if (!prev_inside) {
                const t: f32 = prev_dist / (prev_dist - curr_dist);
                out[count] = prev + (curr - prev) * splat(t);
                count += 1;
            }
            out[count] = curr;
            count += 1;
        } else if (prev_inside) {
            const t: f32 = prev_dist / (prev_dist - curr_dist);
            out[count] = prev + (curr - prev) * splat(t);
            count += 1;
        }
        prev = curr;
        prev_dist = curr_dist;
    }
    return count;
}

/// Box vs box. SAT over 15 axes picks the contact normal; a face axis gives a
/// clipped polygon contact, an edge axis a single point. Each output point carries
/// the surface point on each body.
fn collideBoxBox(
    he_a: Vec,
    pos_a: Vec,
    rot_a: Quat,
    he_b: Vec,
    pos_b: Vec,
    rot_b: Quat,
    speculative_distance: f32,
) ?Manifold {
    const axes_a: [3]Vec = boxAxes(rot_a);
    const axes_b: [3]Vec = boxAxes(rot_b);
    const center_delta: Vec = pos_b - pos_a;

    // SAT minimum-translation-vector: among all candidate axes the contact
    // normal is the one of LEAST penetration (smallest positive overlap) — see
    // Jolt's EPAPenetrationDepth ("direction of least penetration"). Track the
    // MINIMUM overlap, not the maximum: a small box on a wide floor overlaps the
    // floor's horizontal extent by ~its width but the vertical axis by only the
    // penetration, and the vertical axis is the real contact normal.
    var best_overlap: f32 = floatMax(f32);
    var best_axis: Vec = vec(0, 1, 0); // A -> B
    var best_kind: enum { face_a, face_b, edge } = .face_a;
    var best_index: u32 = 0;
    const edge_bias: f32 = 1.0e-3; // prefer face axes on ties => stable resting normal

    {
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const axis: Vec = axes_a[i];
            const radius_b: f32 = boxProjectedRadius(axes_b, he_b, axis);
            const center_dist: f32 = dot3(axis, center_delta);
            const overlap: f32 = vlane(he_a, i) + radius_b - @abs(center_dist);
            if (overlap < -speculative_distance) {
                return null;
            }
            if (overlap < best_overlap) {
                best_overlap = overlap;
                best_kind = .face_a;
                best_index = i;
                best_axis = if (center_dist < 0.0) -axis else axis;
            }
        }
    }
    {
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const axis: Vec = axes_b[i];
            const radius_a: f32 = boxProjectedRadius(axes_a, he_a, axis);
            const center_dist: f32 = dot3(axis, center_delta);
            const overlap: f32 = radius_a + vlane(he_b, i) - @abs(center_dist);
            if (overlap < -speculative_distance) {
                return null;
            }
            if (overlap < best_overlap) {
                best_overlap = overlap;
                best_kind = .face_b;
                best_index = i;
                best_axis = if (center_dist < 0.0) -axis else axis;
            }
        }
    }
    {
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            var j: u32 = 0;
            while (j < 3) : (j += 1) {
                const raw: Vec = cross(axes_a[i], axes_b[j]);
                const len: f32 = length3(raw);
                if (len < 1.0e-6) {
                    continue;
                }
                const axis: Vec = raw / splat(len);
                const radius_a: f32 = boxProjectedRadius(axes_a, he_a, axis);
                const radius_b: f32 = boxProjectedRadius(axes_b, he_b, axis);
                const center_dist: f32 = dot3(axis, center_delta);
                const overlap: f32 = radius_a + radius_b - @abs(center_dist);
                if (overlap < -speculative_distance) {
                    return null;
                }
                // Edge axes win only if STRICTLY shallower than the best face by
                // the bias, so a flat resting contact keeps its face normal.
                if (overlap < best_overlap - edge_bias) {
                    best_overlap = overlap;
                    best_kind = .edge;
                    best_index = i * 3 + j;
                    best_axis = if (center_dist < 0.0) -axis else axis;
                }
            }
        }
    }

    const normal: Vec = best_axis;

    // Supporting face on each box for the penetration `normal`. Jolt's
    // CollideConvexVsConvex builds the manifold from each shape's SUPPORTING
    // FACE relative to the penetration axis (GetSupportingFace +
    // ManifoldBetweenTwoFaces) — NOT from the SAT's face/edge classification.
    // For a box GetSupportingFace always returns a 4-vertex face (the axis most
    // parallel to the direction), so a near-flat box-box contact stays a
    // multi-point face manifold even when an edge cross-axis marginally won the
    // SAT under micro-tilt. That micro-tilt edge-flip is exactly what collapsed
    // 4-point manifolds to 1 point and let box stacks sink into themselves; the
    // old `best_kind == .edge => single point` shortcut was an unjustified
    // divergence from Jolt and is now a true edge-edge FALLBACK only.
    var ai: u32 = 0;
    var align_a: f32 = -1.0;
    {
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const d: f32 = @abs(dot3(axes_a[i], normal));
            if (d > align_a) {
                align_a = d;
                ai = i;
            }
        }
    }
    // A's reference face points toward B (~ +normal); B's points toward A (~ -normal).
    const sign_a: f32 = if (dot3(axes_a[ai], normal) >= 0.0) 1.0 else -1.0;
    var bi: u32 = 0;
    var align_b: f32 = -1.0;
    {
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const d: f32 = @abs(dot3(axes_b[i], normal));
            if (d > align_b) {
                align_b = d;
                bi = i;
            }
        }
    }
    const sign_b: f32 = if (dot3(axes_b[bi], normal) >= 0.0) -1.0 else 1.0;

    // --- genuine edge-edge fallback: one point, the closest points of the two
    // extreme edges. Only when NEITHER box presents a face perpendicular to the
    // normal (cos(18°) ~= 0.95) — e.g. a box balanced corner/edge-first. A
    // near-flat resting contact has alignment ~1 and never takes this path. ---
    if (best_kind == .edge and @max(align_a, align_b) < 0.95) {
        const axis_index_a: u32 = best_index / 3;
        const axis_index_b: u32 = best_index % 3;
        const edge_a: [2]Vec = supportEdge(pos_a, axes_a, he_a, axis_index_a, normal);
        const edge_b: [2]Vec = supportEdge(pos_b, axes_b, he_b, axis_index_b, -normal);

        // Closest points between segment A (start->end) and segment B. Classic
        // parametric solve: minimise the squared distance over the two line
        // parameters, then clamp into [0,1] x [0,1].
        const a_start: Vec = edge_a[0];
        const a_end: Vec = edge_a[1];
        const b_start: Vec = edge_b[0];
        const b_end: Vec = edge_b[1];
        const a_dir: Vec = a_end - a_start;
        const b_dir: Vec = b_end - b_start;
        const between: Vec = a_start - b_start;

        const a_len_sq: f32 = dot3(a_dir, a_dir);
        const b_len_sq: f32 = dot3(b_dir, b_dir);
        const b_dir_dot_between: f32 = dot3(b_dir, between);
        const a_dir_dot_between: f32 = dot3(a_dir, between);
        const dir_dot_dir: f32 = dot3(a_dir, b_dir);
        const denominator: f32 = a_len_sq * b_len_sq - dir_dot_dir * dir_dot_dir;

        var param_a: f32 = if (denominator > 1.0e-9)
            clamp(
                (dir_dot_dir * b_dir_dot_between - a_dir_dot_between * b_len_sq) / denominator,
                0.0,
                1.0,
            )
        else
            0.0;
        var param_b: f32 = (dir_dot_dir * param_a + b_dir_dot_between) / b_len_sq;
        if (param_b < 0.0) {
            param_b = 0.0;
            param_a = clamp(-a_dir_dot_between / a_len_sq, 0.0, 1.0);
        } else if (param_b > 1.0) {
            param_b = 1.0;
            param_a = clamp((dir_dot_dir - a_dir_dot_between) / a_len_sq, 0.0, 1.0);
        }

        var m: Manifold = .{ .normal = normal, .count = 1, .points = undefined };
        m.points[0] = .{
            .point_on_a = a_start + a_dir * splat(param_a),
            .point_on_b = b_start + b_dir * splat(param_b),
            .feature_id = 0x10000 | best_index,
        };
        return m;
    }

    // --- face contact: clip the incident face against the reference face. The
    // reference is the box whose face is most perpendicular to the normal
    // (Jolt: the face most antiparallel to the penetration axis). ---
    const ref_is_a: bool = align_a >= align_b;
    var ref_center: Vec = undefined;
    var ref_axes: [3]Vec = undefined;
    var ref_he: Vec = undefined;
    var inc_center: Vec = undefined;
    var inc_axes: [3]Vec = undefined;
    var inc_he: Vec = undefined;
    var ref_normal: Vec = undefined; // outward world normal of the reference face
    var ref_face_axis: u32 = undefined;
    var ref_sign: f32 = undefined;

    if (ref_is_a) {
        ref_center = pos_a;
        ref_axes = axes_a;
        ref_he = he_a;
        inc_center = pos_b;
        inc_axes = axes_b;
        inc_he = he_b;
        ref_face_axis = ai;
        ref_sign = sign_a;
        ref_normal = axes_a[ai] * splat(sign_a);
    } else {
        ref_center = pos_b;
        ref_axes = axes_b;
        ref_he = he_b;
        inc_center = pos_a;
        inc_axes = axes_a;
        inc_he = he_a;
        ref_face_axis = bi;
        ref_sign = sign_b;
        ref_normal = axes_b[bi] * splat(sign_b);
    }

    var inc_face_axis: u32 = 0;
    var inc_sign: f32 = 1.0;
    {
        var most_antiparallel: f32 = floatMax(f32);
        var a: u32 = 0;
        while (a < 3) : (a += 1) {
            const d_pos: f32 = dot3(inc_axes[a], ref_normal);
            if (d_pos < most_antiparallel) {
                most_antiparallel = d_pos;
                inc_face_axis = a;
                inc_sign = 1.0;
            }
            if (-d_pos < most_antiparallel) {
                most_antiparallel = -d_pos;
                inc_face_axis = a;
                inc_sign = -1.0;
            }
        }
    }

    const incident_quad: [4]Vec = boxFace(inc_center, inc_axes, inc_he, inc_face_axis, inc_sign);

    const ref_j: u32 = (ref_face_axis + 1) % 3;
    const ref_k: u32 = (ref_face_axis + 2) % 3;
    const ref_face_offset: Vec = ref_axes[ref_face_axis] * splat(ref_sign * vlane(ref_he, ref_face_axis));
    const ref_face_center: Vec = ref_center + ref_face_offset;

    const side_normals: [4]Vec = .{ ref_axes[ref_j], -ref_axes[ref_j], ref_axes[ref_k], -ref_axes[ref_k] };
    const side_extents: [4]f32 = .{
        vlane(ref_he, ref_j), vlane(ref_he, ref_j),
        vlane(ref_he, ref_k), vlane(ref_he, ref_k),
    };

    var buf_a: [8]Vec = undefined;
    var buf_b: [8]Vec = undefined;
    buf_a[0] = incident_quad[0];
    buf_a[1] = incident_quad[1];
    buf_a[2] = incident_quad[2];
    buf_a[3] = incident_quad[3];

    var src: *[8]Vec = &buf_a;
    var dst: *[8]Vec = &buf_b;
    var n_in: usize = 4;
    {
        var sp: usize = 0;
        while (sp < 4) : (sp += 1) {
            const sn: Vec = side_normals[sp];
            const offset: f32 = dot3(sn, ref_face_center) + side_extents[sp];
            const n_out: usize = clipPolygonToPlane(src[0..n_in], sn, offset, dst);
            const swap: *[8]Vec = src;
            src = dst;
            dst = swap;
            n_in = n_out;
            if (n_in == 0) {
                break;
            }
        }
    }

    var m: Manifold = .{ .normal = normal, .count = 0, .points = undefined };
    {
        var p: usize = 0;
        while (p < n_in and m.count < 4) : (p += 1) {
            const cp: Vec = src[p]; // on the incident face
            const signed_dist: f32 = dot3(ref_normal, cp - ref_face_center);
            if (signed_dist <= speculative_distance) {
                const projected: Vec = cp - ref_normal * splat(signed_dist); // on the reference plane
                const ord: u32 = @intCast(p);
                const ref_bit: u32 = if (ref_is_a) 0 else 1;
                const fid: u32 = (ref_face_axis << 4) | (ref_bit << 8) | ord;

                // point_on_a / point_on_b labelled by which box is the reference.
                if (ref_is_a) {
                    m.points[m.count] = .{ .point_on_a = projected, .point_on_b = cp, .feature_id = fid };
                } else {
                    m.points[m.count] = .{ .point_on_a = cp, .point_on_b = projected, .feature_id = fid };
                }
                m.count += 1;
            }
        }
    }

    if (m.count == 0) {
        return null;
    }
    return m;
    // Coarse spot (flagged): if more than four points survive we keep the first
    // four; Jolt's manifold reduction keeps the four maximising contact area.
}

/// The contact feature of a shape facing `dir` (world, pointing out of the shape):
/// a polygon (box face, up to 4), a segment (capsule side, 2), or a point (sphere,
/// or a capsule end). Points already include the convex radius (they sit on the
/// surface), so the manifold builder works directly in surface space.
const SupportFace = struct { pts: [4]Vec, n: u8 };

fn supportingFace(
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    dir: Vec,
) SupportFace {
    const dir_len: f32 = length3(dir);
    const dir_unit: Vec = if (dir_len > 1.0e-9) dir / splat(dir_len) else vec(0, 1, 0);

    switch (shape.*) {
        .sphere => |s| {
            const support_pt: Vec = pos + dir_unit * splat(s.radius);
            return .{ .pts = .{ support_pt, undefined, undefined, undefined }, .n = 1 };
        },
        .box => |b| {
            // Pick the box face whose outward normal is most aligned with the direction.
            const axes: [3]Vec = boxAxes(rot);
            var best_axis: u32 = 0;
            var best_alignment: f32 = @abs(dot3(dir_unit, axes[0]));
            for (1..3) |candidate_axis| {
                const alignment: f32 = @abs(dot3(dir_unit, axes[candidate_axis]));
                if (alignment > best_alignment) {
                    best_alignment = alignment;
                    best_axis = @intCast(candidate_axis);
                }
            }
            const face_sign: f32 = if (dot3(dir_unit, axes[best_axis]) >= 0.0) 1.0 else -1.0;
            const quad: [4]Vec = boxFace(pos, axes, b.half_extent, best_axis, face_sign);
            return .{ .pts = quad, .n = 4 };
        },
        .capsule => |c| {
            const axis: Vec = rotate(rot, vec(0, 1, 0));
            const dir_along_axis: f32 = dot3(dir_unit, axis);
            if (@abs(dir_along_axis) > 0.999) {
                // End-on: the direction runs along the capsule, so contact is one cap point.
                const cap_offset: f32 = if (dir_along_axis >= 0.0) c.half_height else -c.half_height;
                const cap_center: Vec = pos + axis * splat(cap_offset);
                const support_pt: Vec = cap_center + dir_unit * splat(c.radius);
                return .{ .pts = .{ support_pt, undefined, undefined, undefined }, .n = 1 };
            }
            // Side-on: the contact line is the segment on the cylinder surface, offset
            // from the core segment by the radius in the perpendicular-to-axis direction.
            var perp_dir: Vec = dir_unit - axis * splat(dir_along_axis);
            const perp_len: f32 = length3(perp_dir);
            perp_dir = if (perp_len > 1.0e-6) perp_dir / splat(perp_len) else dir_unit;
            const segment_start: Vec = pos - axis * splat(c.half_height) + perp_dir * splat(c.radius);
            const segment_end: Vec = pos + axis * splat(c.half_height) + perp_dir * splat(c.radius);
            return .{ .pts = .{ segment_start, segment_end, undefined, undefined }, .n = 2 };
        },
        .cylinder => |cyl| {
            const axis: Vec = rotate(rot, vec(0, 1, 0));
            const along: f32 = dot3(dir_unit, axis);
            if (@abs(along) > 0.999) {
                // Flat cap: four rim points (a diamond inscribed in the circle) give a
                // stable resting manifold once clipped against the other face.
                const cap_y: f32 = if (along >= 0.0) cyl.half_height else -cyl.half_height;
                const center: Vec = pos + axis * splat(cap_y);
                const ru: Vec = rotate(rot, vec(1, 0, 0)) * splat(cyl.radius);
                const rw: Vec = rotate(rot, vec(0, 0, 1)) * splat(cyl.radius);
                return .{ .pts = .{ center + ru, center + rw, center - ru, center - rw }, .n = 4 };
            }
            // Side-on: the contact line on the rim, offset perpendicular to the axis.
            var perp: Vec = dir_unit - axis * splat(along);
            const perp_len: f32 = length3(perp);
            perp = if (perp_len > 1.0e-6) perp / splat(perp_len) else rotate(rot, vec(1, 0, 0));
            const offset: Vec = perp * splat(cyl.radius);
            const bottom: Vec = pos - axis * splat(cyl.half_height) + offset;
            const top: Vec = pos + axis * splat(cyl.half_height) + offset;
            return .{ .pts = .{ bottom, top, undefined, undefined }, .n = 2 };
        },
        .tapered_capsule => {
            // Smooth surface, like a sphere: a single deepest support point.
            const local_dir: Vec = rotate(conjugate(rot), dir_unit);
            const sp: Vec = supportCore(shape, local_dir);
            return .{ .pts = .{ pos + rotate(rot, sp), undefined, undefined, undefined }, .n = 1 };
        },
        .convex_hull => |h| {
            // Pick the face whose outward normal is most aligned with the contact
            // direction, and return its vertices (capped at 4 for the clip step).
            const local_dir: Vec = rotate(conjugate(rot), dir_unit);
            var best_face: usize = 0;
            var best_dot: f32 = dot3(h.faces[0].normal, local_dir);
            for (h.faces[1..], 1..) |f, i| {
                const d: f32 = dot3(f.normal, local_dir);
                if (d > best_dot) {
                    best_dot = d;
                    best_face = i;
                }
            }
            const face: HullFace = h.faces[best_face];
            if (face.vertex_count <= 4) {
                var out: SupportFace = .{ .pts = undefined, .n = @intCast(face.vertex_count) };
                var k: u32 = 0;
                while (k < face.vertex_count) : (k += 1) {
                    const vi: u32 = h.face_vertices[face.first_vertex + k];
                    out.pts[k] = pos + rotate(rot, h.points[vi]);
                }
                return out;
            }
            // A face with more than four vertices can't fit the clip buffer; use the
            // single deepest support point (still a valid, if pointier, contact).
            const support_local: Vec = supportCore(shape, local_dir);
            const support_pt: Vec = pos + rotate(rot, support_local);
            return .{ .pts = .{ support_pt, undefined, undefined, undefined }, .n = 1 };
        },
        // Compounds are decomposed into leaf children before supportingFace runs.
        .compound => return .{ .pts = .{ pos, undefined, undefined, undefined }, .n = 1 },
        .triangle => |t| {
            // A triangle has a single (two-sided) face: its three world-space vertices.
            const w0: Vec = pos + rotate(rot, t.v0);
            const w1: Vec = pos + rotate(rot, t.v1);
            const w2: Vec = pos + rotate(rot, t.v2);
            return .{ .pts = .{ w0, w1, w2, undefined }, .n = 3 };
        },
        // A mesh is decomposed into triangle leaves before supportingFace runs.
        .mesh => return .{ .pts = .{ pos, undefined, undefined, undefined }, .n = 1 },
        .heightfield => return .{ .pts = .{ pos, undefined, undefined, undefined }, .n = 1 },
        // resolved or handled before any face query reaches here
        .rotated_translated, .offset_com, .empty, .plane => unreachable,
    }
}

/// Closest point on segment [a,b] to point p.
fn closestOnSegment(a: Vec, b: Vec, p: Vec) Vec {
    const ab: Vec = b - a;
    const denom: f32 = dot3(ab, ab);
    const t: f32 = if (denom > 1.0e-12) clamp(dot3(p - a, ab) / denom, 0.0, 1.0) else 0.0;
    return a + ab * splat(t);
}

fn faceCentroid(face: SupportFace) Vec {
    var sum: Vec = vec_zero;
    var vertex_index: u8 = 0;
    while (vertex_index < face.n) : (vertex_index += 1) sum += face.pts[vertex_index];
    return sum / splat(@floatFromInt(face.n));
}

/// The invariant data needed to turn a clipped incident point into a contact pair:
/// the reference plane (a point + normal), the penetration axis to project along, and
/// which shape owns the reference face. Bundling these keeps the emit call short.
const RefProjection = struct {
    origin: Vec, // any vertex on the reference face plane
    normal: Vec, // reference face normal (unit)
    normal_dot_axis: f32, // reference normal . penetration axis (projection denominator)
    axis: Vec, // penetration axis, A -> B (unit)
    reference_is_a: bool, // true if the reference face belongs to shape A
    speculative: f32, // keep contacts within this distance of touching
};

/// Clip segment [p0,p1] against the half-spaces { x : dot(n_i, x) <= off_i }, keeping
/// the interior sub-segment. Returns the two clipped endpoints, or null if cut away.
fn clipSegmentToHalfspaces(
    p0: Vec,
    p1: Vec,
    normals: []const Vec,
    offsets: []const f32,
) ?[2]Vec {
    var t0: f32 = 0.0;
    var t1: f32 = 1.0;
    const dir: Vec = p1 - p0;
    for (normals, offsets) |n, off| {
        const d0: f32 = dot3(n, p0) - off;
        const d1: f32 = dot3(n, p1) - off;
        if (d0 > 0.0 and d1 > 0.0) {
            return null;
        } // fully outside this plane
        if (d0 <= 0.0 and d1 <= 0.0) {
            continue;
        } // fully inside
        const t: f32 = d0 / (d0 - d1);
        if (d0 > 0.0) {
            t0 = @max(t0, t); // entering
        } else {
            t1 = @min(t1, t); // exiting
        }
    }
    if (t0 > t1) {
        return null;
    }
    return .{ p0 + dir * splat(t0), p1 + dir * splat(t1) };
}

/// Reduce a set of candidate contact points to the <=4 that best preserve the contact
/// area (Jolt's PruneContactPoints): keep the deepest point, the one furthest from it,
/// then the two that maximise the quad area to either side of their line. This keeps a
/// stable, well-spread manifold so stacks don't wobble. Writes count + points into `out`.
fn pruneManifoldPoints(
    candidates: []const ManifoldPoint,
    normal: Vec,
    out: *Manifold,
) void {
    if (candidates.len <= 4) {
        out.count = @intCast(candidates.len);
        var i: usize = 0;
        while (i < candidates.len) : (i += 1) out.points[i] = candidates[i];
        return;
    }

    // 1. Deepest penetration (penetration = (p_a - p_b).normal; larger = deeper).
    var idx0: usize = 0;
    var best_pen: f32 = -floatMax(f32);
    for (candidates, 0..) |c, i| {
        const pen: f32 = dot3(c.point_on_a - c.point_on_b, normal);
        if (pen > best_pen) {
            best_pen = pen;
            idx0 = i;
        }
    }
    const p0: Vec = candidates[idx0].point_on_a;

    // 2. Furthest from p0.
    var idx1: usize = idx0;
    var best_dist: f32 = -1.0;
    for (candidates, 0..) |c, i| {
        const d: f32 = dot3(c.point_on_a - p0, c.point_on_a - p0);
        if (d > best_dist) {
            best_dist = d;
            idx1 = i;
        }
    }
    const edge: Vec = candidates[idx1].point_on_a - p0;

    // 3 & 4. Largest signed area to either side of the p0->p1 line.
    var idx2: usize = idx0;
    var idx3: usize = idx0;
    var max_area: f32 = 0.0;
    var min_area: f32 = 0.0;
    for (candidates, 0..) |c, i| {
        const area: f32 = dot3(cross(edge, c.point_on_a - p0), normal);
        if (area > max_area) {
            max_area = area;
            idx2 = i;
        }
        if (area < min_area) {
            min_area = area;
            idx3 = i;
        }
    }

    // Emit the distinct chosen points (colinear inputs can make the picks coincide).
    const chosen: [4]usize = .{ idx0, idx1, idx2, idx3 };
    var added: [4]usize = undefined;
    out.count = 0;
    for (chosen) |ci| {
        var dup: bool = false;
        var k: u8 = 0;
        while (k < out.count) : (k += 1) {
            if (added[k] == ci) {
                dup = true;
                break;
            }
        }
        if (dup) {
            continue;
        }
        added[out.count] = ci;
        out.points[out.count] = candidates[ci];
        out.count += 1;
    }
}

/// Build a manifold from two supporting faces. `fallback_*` are the GJK/EPA witness
/// points used when the faces don't form a polygon/edge contact (e.g. a sphere).
fn faceManifold(
    normal: Vec,
    fa: SupportFace,
    fb: SupportFace,
    fallback_a: Vec,
    fallback_b: Vec,
    speculative_distance: f32,
) Manifold {
    var m: Manifold = .{ .normal = normal, .count = 0, .points = undefined };

    const append = struct {
        fn add(
            mm: *Manifold,
            a: Vec,
            b: Vec,
            nrm: Vec,
            spec: f32,
            fid: u32,
        ) void {
            if (mm.count >= 4) {
                return;
            }
            if (dot3(a - b, nrm) < -spec) {
                return;
            } // outside the speculative band
            mm.points[mm.count] = .{ .point_on_a = a, .point_on_b = b, .feature_id = fid };
            mm.count += 1;
        }
    }.add;

    // A point feature on either side => a single contact at the witnesses.
    if (fa.n == 1 or fb.n == 1) {
        append(&m, fallback_a, fallback_b, normal, speculative_distance, 0);
        if (m.count == 0) {
            m.points[0] = .{ .point_on_a = fallback_a, .point_on_b = fallback_b, .feature_id = 0 };
            m.count = 1;
        }
        return m;
    }

    // Both segments (capsule vs capsule): contact along the overlap of the two lines.
    if (fa.n == 2 and fb.n == 2) {
        const seg_a_start: Vec = fa.pts[0];
        const seg_a_end: Vec = fa.pts[1];
        const seg_a_dir: Vec = seg_a_end - seg_a_start;
        const seg_a_len_sq: f32 = dot3(seg_a_dir, seg_a_dir);
        if (seg_a_len_sq > 1.0e-12) {
            // Project B's two endpoints onto segment A's parameter line, clamped to it.
            const b_start_raw: f32 = dot3(fb.pts[0] - seg_a_start, seg_a_dir) / seg_a_len_sq;
            const b_end_raw: f32 = dot3(fb.pts[1] - seg_a_start, seg_a_dir) / seg_a_len_sq;
            const b_start_param: f32 = clamp(b_start_raw, 0.0, 1.0);
            const b_end_param: f32 = clamp(b_end_raw, 0.0, 1.0);
            const overlap_lo: f32 = @min(b_start_param, b_end_param);
            const overlap_hi: f32 = @max(b_start_param, b_end_param);
            const point_lo_on_a: Vec = seg_a_start + seg_a_dir * splat(overlap_lo);
            const point_hi_on_a: Vec = seg_a_start + seg_a_dir * splat(overlap_hi);
            const point_lo_on_b: Vec = closestOnSegment(fb.pts[0], fb.pts[1], point_lo_on_a);
            append(&m, point_lo_on_a, point_lo_on_b, normal, speculative_distance, 1);
            if (overlap_hi > overlap_lo + 1.0e-4) {
                const point_hi_on_b: Vec = closestOnSegment(fb.pts[0], fb.pts[1], point_hi_on_a);
                append(&m, point_hi_on_a, point_hi_on_b, normal, speculative_distance, 2);
            }
        }
        if (m.count == 0) {
            m.points[0] = .{ .point_on_a = fallback_a, .point_on_b = fallback_b, .feature_id = 0 };
            m.count = 1;
        }
        return m;
    }

    // Polygon reference (the face with >= 3 vertices); the other is the incident.
    const ref_is_a: bool = fa.n >= fb.n;
    const ref: SupportFace = if (ref_is_a) fa else fb;
    const inc: SupportFace = if (ref_is_a) fb else fa;

    const ref_normal_raw: Vec = cross(ref.pts[1] - ref.pts[0], ref.pts[2] - ref.pts[0]);
    const ref_normal_len: f32 = length3(ref_normal_raw);
    const ref_normal: Vec = if (ref_normal_len > 1.0e-9)
        ref_normal_raw / splat(ref_normal_len)
    else
        normal;
    const ref_centroid: Vec = faceCentroid(ref);

    // Build the reference polygon's edge side-planes as half-spaces, each oriented to
    // point outward (away from the polygon centroid). Clipping the incident feature
    // against these keeps only the part overlapping the reference face.
    var side_plane_normals: [4]Vec = undefined;
    var side_plane_offsets: [4]f32 = undefined;
    var side_plane_count: usize = 0;
    {
        var edge_index: u8 = 0;
        while (edge_index < ref.n) : (edge_index += 1) {
            const edge_start: Vec = ref.pts[edge_index];
            const edge_end: Vec = ref.pts[(edge_index + 1) % ref.n];
            var outward: Vec = cross(edge_end - edge_start, ref_normal);
            const edge_mid: Vec = (edge_start + edge_end) * splat(0.5);
            // orient away from the reference-face centroid
            if (dot3(outward, edge_mid - ref_centroid) < 0.0) {
                outward = -outward;
            }
            const outward_len: f32 = length3(outward);
            if (outward_len < 1.0e-9) {
                continue;
            }
            outward /= splat(outward_len);
            side_plane_normals[side_plane_count] = outward;
            side_plane_offsets[side_plane_count] = dot3(outward, edge_start);
            side_plane_count += 1;
        }
    }

    const ref_dot_axis: f32 = dot3(ref_normal, normal);
    if (@abs(ref_dot_axis) < 1.0e-6) {
        m.points[0] = .{ .point_on_a = fallback_a, .point_on_b = fallback_b, .feature_id = 0 };
        m.count = 1;
        return m;
    }

    // Project a clipped incident point onto the reference plane along the penetration
    // axis, then pair it (reference point, incident point) labelled by which shape is
    // the reference. All the invariant data travels in a small projection context.
    const projection: RefProjection = .{
        .origin = ref.pts[0],
        .normal = ref_normal,
        .normal_dot_axis = ref_dot_axis,
        .axis = normal,
        .reference_is_a = ref_is_a,
        .speculative = speculative_distance,
    };

    // Project a clipped incident point onto the reference plane along the penetration
    // axis and pair (reference point, incident point) by which shape is the reference,
    // collecting candidates so the (possibly >4) clip output can be area-pruned to 4.
    var candidates: [8]ManifoldPoint = undefined;
    var candidate_count: usize = 0;
    const addCand = struct {
        fn run(
            cands: *[8]ManifoldPoint,
            count: *usize,
            proj: RefProjection,
            incident_point: Vec,
            feature_id: u32,
        ) void {
            if (count.* >= 8) {
                return;
            }
            const travel: f32 = dot3(proj.normal, incident_point - proj.origin) / proj.normal_dot_axis;
            const reference_point: Vec = incident_point - proj.axis * splat(travel);
            const point_a: Vec = if (proj.reference_is_a) reference_point else incident_point;
            const point_b: Vec = if (proj.reference_is_a) incident_point else reference_point;
            // outside the speculative band -> no contact this step
            if (dot3(point_a - point_b, proj.axis) < -proj.speculative) {
                return;
            }
            cands[count.*] = .{ .point_on_a = point_a, .point_on_b = point_b, .feature_id = feature_id };
            count.* += 1;
        }
    }.run;

    if (inc.n == 2) {
        // Segment incident (capsule) vs polygon reference (box): parametric clip.
        const incident_start: Vec = inc.pts[0];
        const incident_end: Vec = inc.pts[1];
        const planes_n: []const Vec = side_plane_normals[0..side_plane_count];
        const planes_off: []const f32 = side_plane_offsets[0..side_plane_count];
        if (clipSegmentToHalfspaces(incident_start, incident_end, planes_n, planes_off)) |clipped_segment| {
            addCand(&candidates, &candidate_count, projection, clipped_segment[0], 1);
            addCand(&candidates, &candidate_count, projection, clipped_segment[1], 2);
        }
    } else {
        // Polygon incident vs polygon reference: Sutherland-Hodgman against each side.
        // Ping-pong between two buffers, clipping against one side-plane per pass.
        var clip_buffer_a: [8]Vec = undefined;
        var clip_buffer_b: [8]Vec = undefined;
        var source: *[8]Vec = &clip_buffer_a;
        var target: *[8]Vec = &clip_buffer_b;
        var vertex_count: usize = inc.n;
        {
            var i: u8 = 0;
            while (i < inc.n) : (i += 1) clip_buffer_a[i] = inc.pts[i];
        }
        {
            var plane_index: usize = 0;
            while (plane_index < side_plane_count) : (plane_index += 1) {
                const plane_normal: Vec = side_plane_normals[plane_index];
                const plane_offset: f32 = side_plane_offsets[plane_index];
                const polygon: []const Vec = source[0..vertex_count];
                const clipped_count: usize = clipPolygonToPlane(polygon, plane_normal, plane_offset, target);
                const temp: *[8]Vec = source;
                source = target;
                target = temp;
                vertex_count = clipped_count;
                if (vertex_count == 0) {
                    break;
                }
            }
        }
        var point_index: usize = 0;
        while (point_index < vertex_count) : (point_index += 1) {
            addCand(&candidates, &candidate_count, projection, source[point_index], @intCast(point_index));
        }
    }

    // Reduce the (possibly >4) clipped contacts to the 4 that best preserve the area.
    pruneManifoldPoints(candidates[0..candidate_count], normal, &m);

    if (m.count == 0) {
        m.points[0] = .{ .point_on_a = fallback_a, .point_on_b = fallback_b, .feature_id = 0 };
        m.count = 1;
    }
    return m;
}

/// Closest point between a segment and a solid box, in the box's local frame.
///
/// ── ★★ TERNARY SEARCH, because the distance is CONVEX along the segment ──
///
/// Point-to-box distance is a convex function of the point, so along a segment it is convex in
/// the parameter `t` — and ternary search on a convex function is guaranteed to reach the global
/// minimum. Sixty halvings take the bracket below f32's resolution.
///
/// ★ A FIRST VERSION USED ALTERNATING PROJECTION — clamp into the box, project back onto the
/// segment, repeat — which converges for two convex sets in general and **stalls at a
/// non-optimal fixed point when the segment runs nearly tangent to a face**. Measured against
/// brute force, every failure sat on a box EDGE, off by up to 2 cm. Convexity in one variable
/// is a stronger property than convexity in two sets, and it is the one worth using here.
///
/// ★ AND WHY THE SEGMENT AT ALL, not the two end-caps: a capsule standing against a wall
/// touches on its SHAFT. A previous attempt tested only the end-caps, returned "no contact" for
/// exactly that, and walked the character controller through walls.
/// Where along a segment the closest approach to a box happens, and how far away it is.
const SegmentBoxHit = struct {
    /// Parameter along the segment, 0 at `p0` and 1 at `p1`.
    t: f32,
    on_box: Vec,
    /// Signed: negative when that point is INSIDE the box.
    dist: f32,
};

fn segmentBoxClosest(
    p0: Vec,
    p1: Vec,
    he: Vec,
) SegmentBoxHit {
    const d: Vec = p1 - p0;
    // ★★ SIGNED distance, negative inside. Using the UNSIGNED one made every interior point
    // look identical at zero, so the search could not tell a graze from a deep embed and the
    // code below had to fall back to a whole-capsule MTV — which reported 17 cm of penetration
    // for a capsule barely touching. Signed distance is still convex, so the same search
    // handles both cases and the depth is measured AT the deepest point, which is what a
    // contact's depth means.
    const distanceAt = struct {
        fn go(a: Vec, delta: Vec, extent: Vec, t: f32) f32 {
            const point: Vec = a + delta * splat(t);
            const outside: Vec = point - clamp(point, -extent, extent);
            const away: f32 = length3(outside);
            if (away > 0) {
                return away;
            }
            var deepest: f32 = std.math.floatMax(f32);
            inline for (0..3) |axis| {
                deepest = @min(deepest, extent[axis] - @abs(point[axis]));
            }
            return -deepest;
        }
    }.go;

    var lo: f32 = 0;
    var hi: f32 = 1;
    var iteration: usize = 0;
    while (iteration < 60) : (iteration += 1) {
        const third: f32 = (hi - lo) / 3.0;
        const m1: f32 = lo + third;
        const m2: f32 = hi - third;
        if (distanceAt(p0, d, he, m1) < distanceAt(p0, d, he, m2)) {
            hi = m2;
        } else {
            lo = m1;
        }
    }
    const t: f32 = 0.5 * (lo + hi);
    const on_seg: Vec = p0 + d * splat(t);
    const on_box: Vec = clamp(on_seg, -he, he);
    return .{ .t = t, .on_box = on_box, .dist = distanceAt(p0, d, he, t) };
}

/// Capsule against box, without GJK or EPA.
///
/// ── ★★★ WHY THIS PAIR EARNS ITS OWN ROUTINE ──
///
/// MuJoCo dispatches a closed-form function for every primitive pair and sends only ellipsoids
/// and meshes to an iterative solver. We special-cased four pairs and sent the rest to GJK/EPA
/// — including **capsule against box, which is every foot, shin and forearm contact a humanoid
/// makes with the ground**.
///
/// ★ AND EPA IS WRONG AT DEPTH. Measured, lowering a foot-sized capsule through a 12 m floor:
///
///     lowest point -0.2670   EPA depth -0.2670    exact
///     lowest point -0.2870   EPA depth -8.5449    *** out through the SIDE of the floor
///
/// Past about 27 cm of overlap the nearest face is no longer the one EPA's polytope grew
/// toward. A humanoid landing on its side reaches those depths and gets a sideways shove.
///
/// ── ★★ THE TWO CASES, EACH EXACT ──
///
/// **Separated or shallow:** the closest point between the SEGMENT and the box gives the normal
/// and the distance directly. No iteration over a polytope, and it sees shaft contacts.
///
fn collideCapsuleBox(
    half_height: f32,
    radius: f32,
    capsule_pos: Vec,
    capsule_rot: Quat,
    he: Vec,
    box_pos: Vec,
    box_rot: Quat,
    speculative_distance: f32,
    flip: bool,
) ?Manifold {
    const box_rot_inv: Quat = conjugate(box_rot);
    // ★★ THE CAPSULE'S AXIS IS LOCAL **Y**, which the `Shape` declaration states outright:
    // "segment along local Y + radius". A first version assumed Z — MuJoCo's convention, and
    // the natural guess when porting its `mjc_PlaneCapsule` — and every result was wrong by a
    // rotation. **The randomised harness reported 1678 existence mismatches on the first run,
    // before any of this reached the dispatch.**
    const axis_world: Vec = rotate(capsule_rot, vec(0, 1, 0));
    const centre_local: Vec = rotate(box_rot_inv, capsule_pos - box_pos);
    const axis_local: Vec = rotate(box_rot_inv, axis_world);
    const p0: Vec = centre_local + axis_local * splat(half_height);
    const p1: Vec = centre_local - axis_local * splat(half_height);

    const closest: SegmentBoxHit = segmentBoxClosest(p0, p1, he);
    const axis_local_unit: Vec = axis_local;

    var local_normal: Vec = undefined; // box surface -> capsule axis, local
    var separation: f32 = undefined;
    var on_box_local: Vec = undefined;
    var on_seg_local: Vec = undefined;

    if (closest.dist > 1.0e-6) {
        // Outside: the closest pair is the answer, and it sees shaft contacts.
        on_seg_local = p0 + (p1 - p0) * splat(closest.t);
        on_box_local = closest.on_box;
        local_normal = (on_seg_local - on_box_local) / splat(closest.dist);
        separation = closest.dist - radius;
    } else {
        // ★ INSIDE at the deepest point: a box has three face normals, so the way out is
        // whichever face that point is nearest — exact, and the step EPA has to discover.
        on_seg_local = p0 + (p1 - p0) * splat(closest.t);
        var best_axis: usize = 0;
        var best_sign: f32 = 1;
        var best_gap: f32 = floatMax(f32);
        inline for (0..3) |axis| {
            const gap: f32 = he[axis] - @abs(on_seg_local[axis]);
            if (gap < best_gap) {
                best_gap = gap;
                best_axis = axis;
                best_sign = if (on_seg_local[axis] >= 0) 1 else -1;
            }
        }
        local_normal = vec_zero;
        on_box_local = on_seg_local;
        inline for (0..3) |axis| {
            if (axis == best_axis) {
                local_normal[axis] = best_sign;
                on_box_local[axis] = best_sign * he[axis];
            }
        }
        separation = -best_gap - radius;
    }

    if (separation > speculative_distance) {
        return null;
    }

    const normal_world: Vec = rotate(box_rot, local_normal); // box -> capsule
    // ── ★★★ TWO POINTS WHEN THE CAPSULE LIES ALONG THE FACE ──
    //
    // A single contact under a capsule lets it PIVOT. Wired in with one point, this routine was
    // exact to 89 microns against brute force and the humanoid still collapsed — torso 0.269 m
    // against 1.282 — because a foot resting on one point is a foot on a knife edge.
    //
    // MuJoCo's `mjc_PlaneCapsule` returns two for the same reason: it runs a sphere-plane test
    // at each end of the capsule. Here the second point is only added when the capsule is
    // roughly PARALLEL to the contact face — if it is standing on one end, one point is the
    // honest answer and a second would be invented.
    var m: Manifold = .{ .normal = undefined, .count = 0, .points = undefined };
    const along_face: f32 = 1.0 - @abs(dot3(axis_local_unit, local_normal));

    // Candidate parameters: the closest point always, plus both ends when lying along the face.
    const params: [3]f32 = .{ closest.t, 0, 1 };
    var param_count: usize = 1;
    if (along_face > 0.15) {
        param_count = 3;
    }

    for (0..param_count) |i| {
        const t: f32 = params[i];
        const seg_pt: Vec = p0 + (p1 - p0) * splat(t);
        // Depth of THIS point along the shared normal.
        const face_coord: f32 = dot3(seg_pt, local_normal);
        const face_extent: f32 = dot3(he, @abs(local_normal));
        const point_separation: f32 = face_coord - face_extent - radius;
        if (point_separation > speculative_distance) {
            continue;
        }
        // Skip a duplicate of one already emitted.
        var duplicate: bool = false;
        for (0..m.count) |k| {
            _ = k;
            if (i > 0 and @abs(t - closest.t) < 1.0e-3) {
                duplicate = true;
            }
        }
        if (duplicate) {
            continue;
        }
        const box_pt_local: Vec = seg_pt - local_normal * splat(face_coord - face_extent);
        const world_box: Vec = box_pos + rotate(box_rot, box_pt_local);
        const world_cap: Vec = box_pos + rotate(box_rot, seg_pt) - normal_world * splat(radius);
        if (!flip) {
            m.points[m.count] = .{ .point_on_a = world_cap, .point_on_b = world_box, .feature_id = @intCast(i) };
        } else {
            m.points[m.count] = .{ .point_on_a = world_box, .point_on_b = world_cap, .feature_id = @intCast(i) };
        }
        m.count += 1;
        if (m.count == m.points.len) {
            break;
        }
    }
    if (m.count == 0) {
        return null;
    }
    m.normal = if (!flip) -normal_world else normal_world;
    return m;
}

/// Closest approach between two segments, as parameters along each.
///
/// ── ★★ THE PARALLEL CASE IS THE WHOLE DIFFICULTY ──
///
/// For skew segments the closest pair is a single point on each, found by solving a 2×2 system.
/// When the axes are PARALLEL that system is singular — its determinant is zero — and there is
/// no unique answer: every point of the overlapping span is equally close.
///
/// ★ THAT IS EXACTLY HOW TWO LEGS REST AGAINST EACH OTHER, and it is where GJK gives up. Two
/// coincident capsule axes make a degenerate simplex, and `collideConvexGeneric` measured
/// **9.8 cm of overlap and returned no contact at all** — the legs pass through one another.
///
/// Handled by picking the MIDDLE of the overlapping span, which is stable frame to frame and
/// is what a pair of parallel capsules physically touches along.
/// Closest approach between two segments, as a parameter along each.
const SegmentPair = struct {
    /// Along the first segment, 0 at `p0` and 1 at `p1`.
    s: f32,
    /// Along the second.
    t: f32,
};

fn segmentSegmentClosest(p0: Vec, p1: Vec, q0: Vec, q1: Vec) SegmentPair {
    const d1: Vec = p1 - p0;
    const d2: Vec = q1 - q0;
    const r: Vec = p0 - q0;
    const a: f32 = dot3(d1, d1);
    const e: f32 = dot3(d2, d2);
    const f: f32 = dot3(d2, r);

    // Degenerate segments — a capsule with zero half-height is a sphere.
    if (a <= 1.0e-12 and e <= 1.0e-12) {
        return .{ .s = 0, .t = 0 };
    }
    if (a <= 1.0e-12) {
        return .{ .s = 0, .t = clamp(f / e, 0, 1) };
    }
    const c: f32 = dot3(d1, r);
    if (e <= 1.0e-12) {
        return .{ .s = clamp(-c / a, 0, 1), .t = 0 };
    }

    const b: f32 = dot3(d1, d2);
    const denom: f32 = a * e - b * b;
    var s: f32 = 0;
    if (denom > 1.0e-12) {
        s = clamp((b * f - c * e) / denom, 0, 1);
    } else {
        // ★ PARALLEL. Project each of the other segment's ends onto this one and take the
        // midpoint of the overlap, so the contact sits along the shared span rather than at an
        // arbitrary end — which is what keeps it stable as the legs shift.
        const t0: f32 = clamp(-c / a, 0, 1);
        const t1: f32 = clamp((dot3(d1, q1 - p0)) / a, 0, 1);
        s = (t0 + t1) * 0.5;
    }
    var t: f32 = (b * s + f) / e;
    if (t < 0) {
        t = 0;
        s = clamp(-c / a, 0, 1);
    } else if (t > 1) {
        t = 1;
        s = clamp((b - c) / a, 0, 1);
    }
    return .{ .s = s, .t = t };
}

/// Capsule against capsule, analytically — the second pair a humanoid makes constantly.
///
/// ── ★ WHY THIS PAIR NEEDS ITS OWN ROUTINE ──
///
/// After capsule×ground, capsule×capsule is what a walking robot collides most: thigh against
/// thigh, forearm against torso. It was reaching `collideConvexGeneric`, which **fails exactly
/// where two legs press together**:
///
///     gap  0.010   depth -0.0880   2 points   correct
///     gap  0.000   depth -0.0980   NONE       *** 9.8 cm of overlap, no contact
///     gap -0.010   depth -0.1080   2 points   correct
///
/// At zero gap the axes are coincident, the GJK simplex is degenerate, and nothing comes back.
/// MuJoCo has `mjc_CapsuleCapsule` in its table for the same reason it has every other
/// primitive pair: an iterative solver has no answer for a configuration with no unique one.
///
/// ★ ONCE THE CLOSEST PAIR OF POINTS IS KNOWN THIS IS A SPHERE-SPHERE TEST, which is closed
/// form and cannot fail.
fn collideCapsuleCapsule(
    half_a: f32,
    radius_a: f32,
    pos_a: Vec,
    rot_a: Quat,
    half_b: f32,
    radius_b: f32,
    pos_b: Vec,
    rot_b: Quat,
    speculative_distance: f32,
) ?Manifold {
    // ★★ A CAPSULE'S AXIS IS ITS LOCAL +Y, not +Z — `supportPoint` returns `vec(0, up, 0)`.
    //
    // Written as +Z first, this put both thighs lying ACROSS the body instead of down it, and
    // the two then overlapped by 12 cm in a pose where MuJoCo measures them 6 cm apart. The
    // centres were right, so the robot still LOOKED correct; only the collision axis was
    // turned ninety degrees, which is the kind of error that hides until something starts
    // reporting contacts from it.
    const axis_a: Vec = rotate(rot_a, vec(0, 1, 0)) * splat(half_a);
    const axis_b: Vec = rotate(rot_b, vec(0, 1, 0)) * splat(half_b);
    const p0: Vec = pos_a - axis_a;
    const p1: Vec = pos_a + axis_a;
    const q0: Vec = pos_b - axis_b;
    const q1: Vec = pos_b + axis_b;

    const near: SegmentPair = segmentSegmentClosest(p0, p1, q0, q1);
    const on_a: Vec = p0 + (p1 - p0) * splat(near.s);
    const on_b: Vec = q0 + (q1 - q0) * splat(near.t);

    const delta: Vec = on_b - on_a;
    const dist: f32 = length3(delta);
    const separation: f32 = dist - radius_a - radius_b;
    if (separation > speculative_distance) {
        return null;
    }

    // ★ A FALLBACK DIRECTION FOR COINCIDENT AXES, where `delta` is zero and has no direction to
    // normalise. Any axis perpendicular to the capsules separates them; the cross product gives
    // one, and when even that degenerates the capsules are collinear and any perpendicular does.
    var normal: Vec = if (dist > 1.0e-6) delta / splat(dist) else blk: {
        const cross_axes: Vec = cross(p1 - p0, q1 - q0);
        const cross_len: f32 = length3(cross_axes);
        if (cross_len > 1.0e-6) {
            break :blk cross_axes / splat(cross_len);
        }
        break :blk perpendicularTo(p1 - p0);
    };
    if (dot3(normal, normal) < 0.5) {
        normal = vec(0, 1, 0);
    }

    var m: Manifold = .{ .normal = normal, .count = 1, .points = undefined };
    m.points[0] = .{
        .point_on_a = on_a + normal * splat(radius_a),
        .point_on_b = on_b - normal * splat(radius_b),
        .feature_id = 0,
    };
    return m;
}

/// Any unit vector perpendicular to `v`.
fn perpendicularTo(v: Vec) Vec {
    // Cross with whichever axis `v` is least aligned to, so the result never degenerates.
    const helper: Vec = if (@abs(v[0]) < 0.9) vec(1, 0, 0) else vec(0, 1, 0);
    const out: Vec = cross(v, helper);
    const len: f32 = length3(out);
    return if (len > 1.0e-9) out / splat(len) else vec(0, 1, 0);
}

fn collideConvexGeneric(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    speculative_distance: f32,
) ?Manifold {
    const r1: f32 = convexRadius(shape_a);
    const r2: f32 = convexRadius(shape_b);

    switch (gjkCores(shape_a, pos_a, rot_a, shape_b, pos_b, rot_b)) {
        .separated => |sep| {
            const real_separation: f32 = sep.dist - r1 - r2;
            if (real_separation > speculative_distance) {
                return null;
            }
            const normal: Vec = sep.normal; // A -> B
            const wa: Vec = sep.pa + normal * splat(r1);
            const wb: Vec = sep.pb - normal * splat(r2);
            const fa: SupportFace = supportingFace(shape_a, pos_a, rot_a, normal);
            const fb: SupportFace = supportingFace(shape_b, pos_b, rot_b, -normal);
            return faceManifold(normal, fa, fb, wa, wb, speculative_distance);
        },
        .overlap => |ov| {
            const epa: EpaResult = epaCores(
                shape_a,
                pos_a,
                rot_a,
                shape_b,
                pos_b,
                rot_b,
                ov.simplex,
                ov.count,
            ) orelse return null;
            const normal: Vec = epa.normal; // A -> B
            const wa: Vec = epa.pa + normal * splat(r1);
            const wb: Vec = epa.pb - normal * splat(r2);
            const fa: SupportFace = supportingFace(shape_a, pos_a, rot_a, normal);
            const fb: SupportFace = supportingFace(shape_b, pos_b, rot_b, -normal);
            return faceManifold(normal, fa, fb, wa, wb, speculative_distance);
        },
    }
}

fn collide(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    speculative_distance: f32,
) ?Manifold {
    // --- sphere vs sphere ---
    if (shape_a.* == .sphere and shape_b.* == .sphere) {
        const ra: f32 = shape_a.sphere.radius;
        const rb: f32 = shape_b.sphere.radius;
        const delta: Vec = pos_b - pos_a;
        const dist: f32 = length3(delta);
        const separation: f32 = dist - ra - rb;
        if (separation > speculative_distance) {
            return null;
        }

        const normal: Vec = if (dist > 1.0e-6) delta / splat(dist) else vec(0, 1, 0);
        var m: Manifold = .{ .normal = normal, .count = 1, .points = undefined };
        m.points[0] = .{
            .point_on_a = pos_a + normal * splat(ra),
            .point_on_b = pos_b - normal * splat(rb),
            .feature_id = 0,
        };
        return m;
    }

    // --- sphere vs box / box vs sphere ---
    if (shape_a.* == .sphere and shape_b.* == .box) {
        const sphere_radius: f32 = shape_a.sphere.radius;
        const box_half_extent: Vec = shape_b.box.half_extent;
        return collideSphereBox(
            sphere_radius,
            pos_a,
            box_half_extent,
            pos_b,
            rot_b,
            speculative_distance,
            false,
        );
    }
    if (shape_a.* == .box and shape_b.* == .sphere) {
        const sphere_radius: f32 = shape_b.sphere.radius;
        const box_half_extent: Vec = shape_a.box.half_extent;
        return collideSphereBox(
            sphere_radius,
            pos_b,
            box_half_extent,
            pos_a,
            rot_a,
            speculative_distance,
            true,
        );
    }

    // --- box vs box ---
    if (shape_a.* == .box and shape_b.* == .box) {
        const half_extent_a: Vec = shape_a.box.half_extent;
        const half_extent_b: Vec = shape_b.box.half_extent;
        return collideBoxBox(half_extent_a, pos_a, rot_a, half_extent_b, pos_b, rot_b, speculative_distance);
    }

    // --- everything else: generic convex (GJK/EPA) ---
    // ★★ CAPSULE AGAINST BOX, BOTH ORDERS — the pair a walking robot makes constantly, and the
    // one where EPA returns a depth of 8.5 m once the overlap passes 27 cm. See
    // `collideCapsuleBox`.
    // ★★ CAPSULE AGAINST CAPSULE. Thigh against thigh, forearm against torso — the pair a
    // humanoid makes most after capsule×ground, and the generic path returns NOTHING when the
    // two axes are coincident, which is exactly how legs rest together. See
    // `collideCapsuleCapsule`.
    if (shape_a.* == .capsule and shape_b.* == .capsule) {
        return collideCapsuleCapsule(
            shape_a.capsule.half_height,
            shape_a.capsule.radius,
            pos_a,
            rot_a,
            shape_b.capsule.half_height,
            shape_b.capsule.radius,
            pos_b,
            rot_b,
            speculative_distance,
        );
    }

    if (shape_a.* == .capsule and shape_b.* == .box) {
        return collideCapsuleBox(
            shape_a.capsule.half_height,
            shape_a.capsule.radius,
            pos_a,
            rot_a,
            shape_b.box.half_extent,
            pos_b,
            rot_b,
            speculative_distance,
            false,
        );
    }
    if (shape_a.* == .box and shape_b.* == .capsule) {
        return collideCapsuleBox(
            shape_b.capsule.half_height,
            shape_b.capsule.radius,
            pos_b,
            rot_b,
            shape_a.box.half_extent,
            pos_a,
            rot_a,
            speculative_distance,
            true,
        );
    }

    // ★★ CAPSULE AGAINST BOX, BOTH ORDERS — the pair a walking robot makes constantly, and the
    // one where GJK/EPA reports a depth of 8.5 m once the overlap passes about 27 cm. See
    // `collideCapsuleBox`, and the randomised test at the bottom of this file that checks it
    // against brute-force ground truth rather than against the path it replaces.

    return collideConvexGeneric(shape_a, pos_a, rot_a, shape_b, pos_b, rot_b, speculative_distance);
}

/// One manifold produced by collideShapes, tagged with a sub-shape discriminator so
/// the warm-start cache can tell a compound's sub-contacts apart. `sub` packs the two
/// child indices: (sub_a << 16) | sub_b; it is 0 for a plain leaf-leaf pair.
pub const SubCollision = struct {
    manifold: Manifold,
    sub: u32,
};

fn packSub(sub_a: usize, sub_b: usize) u32 {
    // 16 bits per side. Compound child indices are tiny; mesh triangle indices past
    // 65535 alias here, which only costs an occasional warm-start miss (never wrong).
    return ((@as(u32, @truncate(sub_a)) & 0xFFFF) << 16) | (@as(u32, @truncate(sub_b)) & 0xFFFF);
}

/// Collide two shapes, decomposing any compound into its leaf children, and append a
/// SubCollision per overlapping leaf pair. Leaf-vs-leaf appends at most one (sub = 0),
/// reproducing the single-manifold path exactly. Child pairs are culled by their
/// world AABBs so a compound with N children isn't N full narrow-phase calls.
/// A decorated shape resolved to its leaf child with the pose folded in.
const ResolvedShape = struct { shape: *const Shape, pos: Vec, rot: Quat };

/// Peel any rotated-translated / offset-COM decorators off a shape, folding each into the pose, and
/// return the underlying (non-decorator) shape with its world COM transform. Positioning by COM
/// means a rotated-translated decorator only composes the rotation; an offset-COM decorator shifts
/// the COM by -offset in the current frame.
fn resolveDecorated(
    store: *const ShapeStore,
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
) ResolvedShape {
    var s: *const Shape = shape;
    var p: Vec = pos;
    var r: Quat = rot;
    while (true) {
        switch (s.*) {
            .rotated_translated => |rt| {
                r = qmul(r, rt.rotation);
                s = store.get(rt.child);
            },
            .offset_com => |oc| {
                p = p - rotate(r, oc.offset);
                s = store.get(oc.child);
            },
            else => break,
        }
    }
    return .{ .shape = s, .pos = p, .rot = r };
}

/// Collide an infinite plane half-space against a single convex leaf (Jolt's sCollideConvexVsPlane,
/// extended to a face manifold for resting stability). The convex's supporting face toward the
/// plane is taken; each vertex within the speculative distance becomes a contact, projected onto the
/// plane. `plane_is_a` selects the A->B normal direction (the plane normal points out of the solid).
fn collidePlaneLeaf(
    plane: *const PlaneShape,
    plane_pos: Vec,
    plane_rot: Quat,
    convex: *const Shape,
    convex_pos: Vec,
    convex_rot: Quat,
    plane_is_a: bool,
    speculative_distance: f32,
    out: *std.ArrayListUnmanaged(SubCollision),
    scratch: std.mem.Allocator,
) !void {
    const n: Vec = rotate(plane_rot, plane.normal); // world outward plane normal
    const world_point: Vec = plane_pos + rotate(plane_rot, plane.normal * splat(-plane.distance));
    // face toward the plane
    const face: SupportFace = supportingFace(convex, convex_pos, convex_rot, vec_zero - n);
    var m: Manifold = .{ .normal = if (plane_is_a) n else vec_zero - n, .count = 0, .points = undefined };
    var i: u8 = 0;
    while (i < face.n and m.count < 4) : (i += 1) {
        const fp: Vec = face.pts[i];
        const sd: f32 = dot3(n, fp - world_point); // signed distance of this surface point to the plane
        if (sd <= speculative_distance) {
            const on_plane: Vec = fp - n * splat(sd); // projection onto the plane surface
            const side_bit: u32 = if (plane_is_a) 0 else 1;
            const fid: u32 = @as(u32, @intCast(i)) | (side_bit << 8);
            if (plane_is_a) {
                m.points[m.count] = .{ .point_on_a = on_plane, .point_on_b = fp, .feature_id = fid };
            } else {
                m.points[m.count] = .{ .point_on_a = fp, .point_on_b = on_plane, .feature_id = fid };
            }
            m.count += 1;
        }
    }
    if (m.count == 0) {
        return;
    }
    try out.append(scratch, .{ .manifold = m, .sub = 0 });
}

/// How triangle-based shapes (meshes, height fields) treat collisions on their back side. The
/// front side is the one the CCW face normal points to. `collide_back_faces` is two-sided (the
/// default, matching the rigid-body solver); `ignore_back_faces` drops contacts where the other
/// shape is behind the triangle (one-way platforms, and keeps a character that's slightly under a
/// floor from being shoved the wrong way). Convex/compound shapes have no back face and ignore it.
pub const BackFaceMode = enum { collide_back_faces, ignore_back_faces };

/// Collide a mesh against a single convex leaf: query the mesh BVH with the convex's
/// AABB (transformed into mesh-local space), then collide the convex against each
/// candidate triangle as a transient leaf. `mesh_is_a` says whether the mesh is the A
/// side of the pair (sets the normal sense and which half of `sub` holds the triangle).
/// Distance from a point to a segment.
fn distPointSegment(p: Vec, a: Vec, b: Vec) f32 {
    return length3(p - closestOnSegment(a, b, p));
}

/// Active-edge normal correction. `tri_to_other` is the contact normal oriented from
/// the triangle toward the colliding convex. If the contact sits on an INACTIVE edge
/// (an internal seam), snap that normal to the triangle's face normal so the body
/// slides on instead of catching; a face contact or an active edge is left untouched.
fn fixMeshNormal(
    world_normal: Vec,
    active_edges: u8,
    v0: Vec,
    v1: Vec,
    v2: Vec,
    contact_pt: Vec,
    tri_to_other: Vec,
) Vec {
    const faces_other: bool = dot3(world_normal, tri_to_other) >= 0.0;
    const nf: Vec = if (faces_other) world_normal else vec_zero - world_normal;
    // Already a face contact (normal within ~2.6 deg of the face): nothing to fix.
    if (dot3(tri_to_other, nf) > mesh_active_edge_cos) {
        return tri_to_other;
    }

    // Edge/vertex contact: find the nearest triangle edge to the contact point.
    var best_edge: u8 = 0;
    var best_dist: f32 = distPointSegment(contact_pt, v0, v1);
    const d1: f32 = distPointSegment(contact_pt, v1, v2);
    if (d1 < best_dist) {
        best_dist = d1;
        best_edge = 1;
    }
    const d2: f32 = distPointSegment(contact_pt, v2, v0);
    if (d2 < best_dist) {
        best_dist = d2;
        best_edge = 2;
    }
    const bit: u8 = other_edge_bit(best_edge);
    if ((active_edges & bit) != 0) {
        return tri_to_other;
    } // real feature: keep
    return nf; // inactive seam: snap to the face normal
}

fn collideMeshLeaf(
    mesh: *const Mesh,
    mesh_pos: Vec,
    mesh_rot: Quat,
    other: *const Shape,
    other_pos: Vec,
    other_rot: Quat,
    mesh_is_a: bool,
    speculative_distance: f32,
    back_face_mode: BackFaceMode,
    out: *std.ArrayListUnmanaged(SubCollision),
    scratch: std.mem.Allocator,
) !void {
    const other_local: Aabb = shapeLocalBounds(other);
    const other_world: Aabb = transformAabb(other_local, other_pos, other_rot).expandedBy(
        speculative_distance,
    );
    const query_local: Aabb = transformAabbInverse(other_world, mesh_pos, mesh_rot);

    var tris: std.ArrayListUnmanaged(u32) = .empty;
    defer tris.deinit(scratch);
    try queryMeshBvh(mesh, query_local, &tris, scratch);

    for (tris.items) |ti| {
        const t: MeshTriangle = mesh.triangles[ti];
        // The triangle vertices are baked into world space, so pose the triangle shape
        // at the origin with identity rotation.
        const w0: Vec = mesh_pos + rotate(mesh_rot, mesh.vertices[t.v[0]]);
        const w1: Vec = mesh_pos + rotate(mesh_rot, mesh.vertices[t.v[1]]);
        const w2: Vec = mesh_pos + rotate(mesh_rot, mesh.vertices[t.v[2]]);
        const tri_shape: Shape = .{ .triangle = .{ .v0 = w0, .v1 = w1, .v2 = w2 } };
        const maybe: ?Manifold = if (mesh_is_a)
            collide(
                &tri_shape,
                vec_zero,
                quat_identity,
                other,
                other_pos,
                other_rot,
                speculative_distance,
            )
        else
            collide(
                other,
                other_pos,
                other_rot,
                &tri_shape,
                vec_zero,
                quat_identity,
                speculative_distance,
            );
        if (maybe) |m_in| {
            var m: Manifold = m_in;
            // Snap the normal off any inactive (internal) edge onto the face normal.
            var contact_pt: Vec = vec_zero;
            var pidx: u8 = 0;
            while (pidx < m.count) : (pidx += 1) {
                contact_pt += if (mesh_is_a) m.points[pidx].point_on_a else m.points[pidx].point_on_b;
            }
            contact_pt /= splat(@floatFromInt(m.count));
            const tri_to_other: Vec = if (mesh_is_a) m.normal else vec_zero - m.normal;
            const world_normal: Vec = rotate(mesh_rot, t.normal);
            if (back_face_mode == .ignore_back_faces and dot3(world_normal, tri_to_other) < 0.0) {
                continue; // other shape is behind the front face
            }
            const fixed: Vec = fixMeshNormal(
                world_normal,
                t.active_edges,
                w0,
                w1,
                w2,
                contact_pt,
                tri_to_other,
            );
            m.normal = if (mesh_is_a) fixed else vec_zero - fixed;

            const sub: u32 = if (mesh_is_a) packSub(ti, 0) else packSub(0, ti);
            try out.append(scratch, .{ .manifold = m, .sub = sub });
        }
    }
}

/// Collide a single world-space triangle (already baked) against a convex leaf and, on
/// contact, append a SubCollision with the given `sub`. `field_is_a` says whether the
/// triangle is the A side of the pair (controls the normal sense).
fn collideTriangleLeaf(
    v0: Vec,
    v1: Vec,
    v2: Vec,
    other: *const Shape,
    other_pos: Vec,
    other_rot: Quat,
    field_is_a: bool,
    sub: u32,
    face_normal: Vec, // world-space triangle face normal (CCW front face)
    active_edges: u8, // bit e set => edge e is active; inactive seams snap to face_normal
    speculative_distance: f32,
    back_face_mode: BackFaceMode,
    out: *std.ArrayListUnmanaged(SubCollision),
    scratch: std.mem.Allocator,
) !void {
    const tri_shape: Shape = .{ .triangle = .{ .v0 = v0, .v1 = v1, .v2 = v2 } };
    const maybe: ?Manifold = if (field_is_a)
        collide(&tri_shape, vec_zero, quat_identity, other, other_pos, other_rot, speculative_distance)
    else
        collide(other, other_pos, other_rot, &tri_shape, vec_zero, quat_identity, speculative_distance);
    if (maybe) |m_in| {
        var m: Manifold = m_in;
        // Snap the normal off any inactive (internal) edge onto the face normal (same as
        // collideMeshLeaf): average the manifold points on the triangle side, orient the
        // manifold normal triangle -> other, and let fixMeshNormal decide.
        var contact_pt: Vec = vec_zero;
        var pidx: u8 = 0;
        while (pidx < m.count) : (pidx += 1) {
            contact_pt += if (field_is_a) m.points[pidx].point_on_a else m.points[pidx].point_on_b;
        }
        contact_pt /= splat(@floatFromInt(m.count));
        const tri_to_other: Vec = if (field_is_a) m.normal else vec_zero - m.normal;
        if (back_face_mode == .ignore_back_faces and dot3(face_normal, tri_to_other) < 0.0) {
            return; // other shape is behind the front face
        }
        const fixed: Vec = fixMeshNormal(face_normal, active_edges, v0, v1, v2, contact_pt, tri_to_other);
        m.normal = if (field_is_a) fixed else vec_zero - fixed;
        try out.append(scratch, .{ .manifold = m, .sub = sub });
    }
}

/// Collide a height field against a convex leaf: find the grid cells its AABB covers
/// (in field-local space) and collide the convex against the two triangles of each. Contact
/// normals on internal seams are snapped to the face normal using the precomputed per-triangle
/// active-edge masks (hf.active_edges), so a shape sliding across the grid doesn't catch on the
/// cell diagonals or shared edges (same treatment as collideMeshLeaf).
fn collideHeightFieldLeaf(
    hf: *const HeightField,
    hf_pos: Vec,
    hf_rot: Quat,
    other: *const Shape,
    other_pos: Vec,
    other_rot: Quat,
    hf_is_a: bool,
    speculative_distance: f32,
    back_face_mode: BackFaceMode,
    out: *std.ArrayListUnmanaged(SubCollision),
    scratch: std.mem.Allocator,
) !void {
    const other_local: Aabb = shapeLocalBounds(other);
    const other_world: Aabb = transformAabb(other_local, other_pos, other_rot).expandedBy(
        speculative_distance,
    );
    const ql: Aabb = transformAabbInverse(other_world, hf_pos, hf_rot);

    const inv_cell: f32 = 1.0 / hf.cell_size;
    const max_cx: i64 = @as(i64, hf.sample_count_x) - 2; // last valid cell index
    const max_cz: i64 = @as(i64, hf.sample_count_z) - 2;
    const cx0: i64 = clamp(floori(i64, ql.min[0] * inv_cell), 0, max_cx);
    const cx1: i64 = clamp(floori(i64, ql.max[0] * inv_cell), 0, max_cx);
    const cz0: i64 = clamp(floori(i64, ql.min[2] * inv_cell), 0, max_cz);
    const cz1: i64 = clamp(floori(i64, ql.max[2] * inv_cell), 0, max_cz);
    if (cx1 < cx0 or cz1 < cz0) {
        return;
    }

    const cells_x: usize = hf.sample_count_x - 1;
    var cz: i64 = cz0;
    while (cz <= cz1) : (cz += 1) {
        var cx: i64 = cx0;
        while (cx <= cx1) : (cx += 1) {
            const gx: u32 = @intCast(cx);
            const gz: u32 = @intCast(cz);
            // Four cell corners, baked into world space.
            const a: Vec = hf_pos + rotate(hf_rot, hfVertex(hf, gx, gz));
            const b: Vec = hf_pos + rotate(hf_rot, hfVertex(hf, gx + 1, gz));
            const c: Vec = hf_pos + rotate(hf_rot, hfVertex(hf, gx, gz + 1));
            const d: Vec = hf_pos + rotate(hf_rot, hfVertex(hf, gx + 1, gz + 1));
            // Two triangles per cell, wound so the normal points up for flat terrain.
            const cell_id: usize = @as(usize, @intCast(cz)) * cells_x + @as(usize, @intCast(cx));
            const sub0: u32 = if (hf_is_a) packSub(cell_id * 2 + 0, 0) else packSub(0, cell_id * 2 + 0);
            const sub1: u32 = if (hf_is_a) packSub(cell_id * 2 + 1, 0) else packSub(0, cell_id * 2 + 1);
            // World face normals (CCW per the winding below) and the precomputed active-edge
            // masks, so internal seams between cell triangles snap to the face normal.
            const normal0: Vec = triFaceNormal(a, d, b);
            const normal1: Vec = triFaceNormal(a, c, d);
            const active0: u8 = hf.active_edges[cell_id * 2 + 0];
            const active1: u8 = hf.active_edges[cell_id * 2 + 1];
            try collideTriangleLeaf(
                a,
                d,
                b,
                other,
                other_pos,
                other_rot,
                hf_is_a,
                sub0,
                normal0,
                active0,
                speculative_distance,
                back_face_mode,
                out,
                scratch,
            );
            try collideTriangleLeaf(
                a,
                c,
                d,
                other,
                other_pos,
                other_rot,
                hf_is_a,
                sub1,
                normal1,
                active1,
                speculative_distance,
                back_face_mode,
                out,
                scratch,
            );
        }
    }
}

fn collideShapes(
    store: *const ShapeStore,
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    speculative_distance: f32,
    back_face_mode: BackFaceMode,
    out: *std.ArrayListUnmanaged(SubCollision),
    scratch: std.mem.Allocator,
) !void {
    // Empty shapes never collide.
    if (shape_a.* == .empty or shape_b.* == .empty) {
        return;
    }
    // Decorated shapes (rotated-translated / offset-COM): resolve to their leaf children with the
    // pose folded in, then re-dispatch. The resolved shapes are never decorators, so this recurses
    // at most once.
    const a_decorated: bool = shape_a.* == .rotated_translated or shape_a.* == .offset_com;
    const b_decorated: bool = shape_b.* == .rotated_translated or shape_b.* == .offset_com;
    if (a_decorated or b_decorated) {
        const ra: ResolvedShape = resolveDecorated(store, shape_a, pos_a, rot_a);
        const rb: ResolvedShape = resolveDecorated(store, shape_b, pos_b, rot_b);
        try collideShapes(
            store,
            ra.shape,
            ra.pos,
            ra.rot,
            rb.shape,
            rb.pos,
            rb.rot,
            speculative_distance,
            back_face_mode,
            out,
            scratch,
        );
        return;
    }
    // Plane: an infinite static half-space collides with a single convex leaf via a dedicated
    // routine. Compound-vs-plane (like compound-vs-mesh) is a current gap.
    if (shape_a.* == .plane or shape_b.* == .plane) {
        if (shape_a.* == .plane and shape_b.* == .plane) {
            return;
        } // two planes never collide
        if (shape_a.* == .plane) {
            if (shape_b.* == .compound) {
                return;
            }
            try collidePlaneLeaf(
                &shape_a.plane,
                pos_a,
                rot_a,
                shape_b,
                pos_b,
                rot_b,
                true,
                speculative_distance,
                out,
                scratch,
            );
        } else {
            if (shape_a.* == .compound) {
                return;
            }
            try collidePlaneLeaf(
                &shape_b.plane,
                pos_b,
                rot_b,
                shape_a,
                pos_a,
                rot_a,
                false,
                speculative_distance,
                out,
                scratch,
            );
        }
        return;
    }
    const a_mesh: bool = shape_a.* == .mesh;
    const b_mesh: bool = shape_b.* == .mesh;
    const a_hf: bool = shape_a.* == .heightfield;
    const b_hf: bool = shape_b.* == .heightfield;
    const a_concave: bool = a_mesh or a_hf;
    const b_concave: bool = b_mesh or b_hf;
    if (a_concave or b_concave) {
        // A concave shape (mesh or height field) collides only with a convex leaf this
        // turn: two static concave shapes never collide, and compound-vs-concave comes
        // later. The convex leaf is the non-concave side.
        if (a_concave and b_concave) {
            return;
        }
        if (a_concave) {
            if (shape_b.* == .compound) {
                return;
            }
            if (a_mesh) {
                try collideMeshLeaf(
                    &shape_a.mesh,
                    pos_a,
                    rot_a,
                    shape_b,
                    pos_b,
                    rot_b,
                    true,
                    speculative_distance,
                    back_face_mode,
                    out,
                    scratch,
                );
            } else {
                try collideHeightFieldLeaf(
                    &shape_a.heightfield,
                    pos_a,
                    rot_a,
                    shape_b,
                    pos_b,
                    rot_b,
                    true,
                    speculative_distance,
                    back_face_mode,
                    out,
                    scratch,
                );
            }
        } else {
            if (shape_a.* == .compound) {
                return;
            }
            if (b_mesh) {
                try collideMeshLeaf(
                    &shape_b.mesh,
                    pos_b,
                    rot_b,
                    shape_a,
                    pos_a,
                    rot_a,
                    false,
                    speculative_distance,
                    back_face_mode,
                    out,
                    scratch,
                );
            } else {
                try collideHeightFieldLeaf(
                    &shape_b.heightfield,
                    pos_b,
                    rot_b,
                    shape_a,
                    pos_a,
                    rot_a,
                    false,
                    speculative_distance,
                    back_face_mode,
                    out,
                    scratch,
                );
            }
        }
        return;
    }

    const a_compound: bool = shape_a.* == .compound;
    const b_compound: bool = shape_b.* == .compound;

    if (!a_compound and !b_compound) {
        if (collide(shape_a, pos_a, rot_a, shape_b, pos_b, rot_b, speculative_distance)) |m| {
            try out.append(scratch, .{ .manifold = m, .sub = 0 });
        }
        return;
    }

    if (a_compound and !b_compound) {
        const b_local: Aabb = shapeLocalBounds(shape_b);
        const b_bounds: Aabb = transformAabb(b_local, pos_b, rot_b).expandedBy(speculative_distance);
        for (shape_a.compound.children, 0..) |child, ci| {
            const cs: *const Shape = store.get(child.shape);
            const cpos: Vec = pos_a + rotate(rot_a, child.local_pos);
            const crot: Quat = qmul(rot_a, child.local_rot);
            if (!transformAabb(shapeLocalBounds(cs), cpos, crot).overlaps(b_bounds)) {
                continue;
            }
            if (collide(cs, cpos, crot, shape_b, pos_b, rot_b, speculative_distance)) |m| {
                try out.append(scratch, .{ .manifold = m, .sub = packSub(ci, 0) });
            }
        }
        return;
    }

    if (!a_compound and b_compound) {
        const a_local: Aabb = shapeLocalBounds(shape_a);
        const a_bounds: Aabb = transformAabb(a_local, pos_a, rot_a).expandedBy(speculative_distance);
        for (shape_b.compound.children, 0..) |child, ci| {
            const cs: *const Shape = store.get(child.shape);
            const cpos: Vec = pos_b + rotate(rot_b, child.local_pos);
            const crot: Quat = qmul(rot_b, child.local_rot);
            if (!transformAabb(shapeLocalBounds(cs), cpos, crot).overlaps(a_bounds)) {
                continue;
            }
            if (collide(shape_a, pos_a, rot_a, cs, cpos, crot, speculative_distance)) |m| {
                try out.append(scratch, .{ .manifold = m, .sub = packSub(0, ci) });
            }
        }
        return;
    }

    // Both compound: every (child_a, child_b) pair, AABB-culled.
    for (shape_a.compound.children, 0..) |ca, ai| {
        const csa: *const Shape = store.get(ca.shape);
        const apos: Vec = pos_a + rotate(rot_a, ca.local_pos);
        const arot: Quat = qmul(rot_a, ca.local_rot);
        const csa_local: Aabb = shapeLocalBounds(csa);
        const a_bounds: Aabb = transformAabb(csa_local, apos, arot).expandedBy(speculative_distance);
        for (shape_b.compound.children, 0..) |cb, bi| {
            const csb: *const Shape = store.get(cb.shape);
            const bpos: Vec = pos_b + rotate(rot_b, cb.local_pos);
            const brot: Quat = qmul(rot_b, cb.local_rot);
            if (!transformAabb(shapeLocalBounds(csb), bpos, brot).overlaps(a_bounds)) {
                continue;
            }
            if (collide(csa, apos, arot, csb, bpos, brot, speculative_distance)) |m| {
                try out.append(scratch, .{ .manifold = m, .sub = packSub(ai, bi) });
            }
        }
    }
}

// --- box-box helpers ---

/// Generic convex-convex via the support seam (GJK closest point + EPA depth).
/// SKETCH — next pass. Runs entirely through supportCore(shape, dir) + convexRadius,
/// emitting the same Manifold (two points per contact) as the routines above.
// -----------------------------------------------------------------------------
// Generic convex-convex, ported from Jolt's ConvexShape::sCollideConvexVsConvex:
// run GJK/EPA on the CORES (support minus convex radius), then add the radii back.
// Each core is well-behaved (sphere -> point, box -> inset box, capsule -> segment),
// so the iteration is robust. GJK handles the separated / shallow-touch case (which
// is exact for round shapes); EPA handles deep core overlap. Output is the same
// two-point Manifold; round shapes contact at a single point, which is correct.
// Multi-point manifolds for FLAT-faced cores (hull/cylinder) come from clipping the
// two supporting faces (the same machinery as collideBoxBox) — flagged, next pass.
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Multi-point manifolds for the generic path. GJK/EPA give the normal and one
// witness point; that is exact for a sphere or an end-on capsule, but a side-on
// capsule or a flat hull face touches along a line/area and needs several points or
// it rocks. Following Jolt's ManifoldBetweenTwoFaces: take each shape's supporting
// face along the contact normal, clip them against each other, project the survivors
// back along the normal, and keep those within the speculative band.
// -----------------------------------------------------------------------------

/// Linear shape cast for CCD: sweep shape A from `start_pos` along `displacement`
/// against a stationary shape B and return the fraction in [0,1] of first contact,
/// or null if they don't meet within the step. Conservative advancement on the cores
/// (the standard GJK convex cast): repeatedly take the GJK distance, then advance by
/// the time it takes to close that gap at the current closing speed. Rotation is held
/// fixed over the step, matching Jolt's translation-only linear cast.
fn shapeCastCores(
    shape_a: *const Shape,
    start_pos: Vec,
    rot_a: Quat,
    displacement: Vec,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    r1: f32,
    r2: f32,
    tolerance: f32,
) ?f32 {
    if (lengthSq3(displacement) < 1.0e-18) {
        return null;
    }

    var t: f32 = 0.0;
    var iter: u32 = 0;
    while (iter < 32) : (iter += 1) {
        const pos_t: Vec = start_pos + displacement * splat(t);
        switch (gjkCores(shape_a, pos_t, rot_a, shape_b, pos_b, rot_b)) {
            .overlap => return t, // cores already touch at this t
            .separated => |sep| {
                const real_dist: f32 = sep.dist - r1 - r2;
                if (real_dist < tolerance) {
                    return t;
                } // within contact tolerance
                const closing: f32 = dot3(displacement, sep.normal); // normal is A -> B
                if (closing <= 1.0e-9) {
                    return null;
                } // not approaching B
                t += real_dist / closing;
                if (t >= 1.0) {
                    return null;
                } // contact is beyond this step
            },
        }
    }
    return t; // iteration cap: report the best estimate we have
}

// =============================================================================
// Broad phase: a dynamic AABB tree. SKETCH of the interface; internals next pass.
// =============================================================================

// =============================================================================
// Warm-start cache: last frame's accumulated impulses keyed by body pair + feature.
// Per manifold we cache the friction triple; per point the normal impulse. A plain
// double-buffered hash map (no lock-free machinery — single threaded). SKETCHED.
// =============================================================================

// =============================================================================
// Contacts. Mirrors Jolt's ContactConstraint exactly: the non-penetration normal
// is PER POINT; friction (two linear tangents + one torsional) is PER MANIFOLD,
// applied at the centroid, with a coupled circular cone.
// =============================================================================

pub const ContactPoint = struct {
    local_a: Vec, // contact point on A, in A's local frame (position-solve anchor)
    local_b: Vec, // contact point on B, in B's local frame
    feature_id: u32,
    distance_to_friction_center: f32, // tangent-plane distance to the friction centroid
    normal_part: AxisPart,
};

pub const Contact = struct {
    a: BodyIndex,
    b: BodyIndex,
    sub: u32 = 0, // sub-shape pair discriminator (compounds); 0 for leaf-leaf
    normal: Vec, // A -> B
    tangent1: Vec,
    tangent2: Vec,
    friction: f32,
    friction1: AxisPart, // linear friction along tangent1 (at centroid)
    friction2: AxisPart, // linear friction along tangent2 (at centroid)
    angular_friction: AngularPart, // torsional friction about the normal
    count: u8,
    points: [4]ContactPoint,
};

// =============================================================================
// Scene queries: cast a ray, sweep a shape, test a point, or gather overlaps
// against the world. These reuse the same broad-phase tree and narrow-phase
// kernels the simulation uses, and never mutate the world. The primitives below
// assume `dir` is a unit vector; the public entry points normalise for you.
// =============================================================================

pub const ShapeCastHit = struct {
    body: BodyIndex,
    fraction: f32, // fraction of the sweep [0,1] at first contact
    normal: Vec = vec_zero, // world contact normal toward the cast shape (active-edge fixed)
    point: Vec = vec_zero, // world contact point on the hit body
    sub: u32 = 0, // sub-shape discriminator on the hit body (packSub(0, leaf))
};

fn pointInShape(
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    p: Vec,
) bool {
    switch (shape.*) {
        .sphere => |s| return lengthSq3(p - pos) <= s.radius * s.radius,
        .box => |b| {
            const local: Vec = rotate(conjugate(rot), p - pos);
            return @abs(local[0]) <= b.half_extent[0] and
                @abs(local[1]) <= b.half_extent[1] and
                @abs(local[2]) <= b.half_extent[2];
        },
        .capsule => |c| {
            const axis: Vec = rotate(rot, vec(0, 1, 0));
            const seg_start: Vec = pos - axis * splat(c.half_height);
            const seg_end: Vec = pos + axis * splat(c.half_height);
            const nearest: Vec = closestOnSegment(seg_start, seg_end, p);
            return lengthSq3(p - nearest) <= c.radius * c.radius;
        },
        else => return false, // convex hull / compound point queries not implemented yet
    }
}

/// Cast a ray and return the nearest body hit within `max_distance`, or null.
pub fn castRayClosest(
    world: *const World,
    origin: Vec,
    direction: Vec,
    max_distance: f32,
    filter: QueryFilter,
) ?RayHit {
    const bp: *const BroadPhase = &world.broadphase;
    if (bp.root == BroadPhase.NULL_NODE) {
        return null;
    }
    const dir_len: f32 = length3(direction);
    if (dir_len < 1.0e-9) {
        return null;
    }
    const dir: Vec = direction / splat(dir_len);
    const inv_dir: Vec = splat(1.0) / dir;

    var closest: f32 = max_distance;
    var result: ?RayHit = null;

    var stack: BvhStack = .{};
    stack.push(bp.root);
    while (stack.pop()) |node_index| {
        if (node_index == BroadPhase.NULL_NODE) {
            continue;
        }
        const node: *const BroadPhase.Node = &bp.nodes.items[node_index];
        const enter: f32 = rayVsAabb(origin, inv_dir, node.aabb, closest) orelse continue;
        if (enter > closest) {
            continue;
        }
        if (BroadPhase.isLeaf(node)) {
            const idx: BodyIndex = node.body;
            const body: *const Body = &world.bodies.data[idx];
            if (!queryAllows(body, idx, filter)) {
                continue;
            }
            const shape: *const Shape = world.shapes.get(body.shape);
            const hit: RayShapeHit = rayVsShape(shape, body.com_pos, body.rot, origin, dir) orelse continue;
            if (hit.fraction >= 0.0 and hit.fraction < closest) {
                closest = hit.fraction;
                result = .{
                    .body = idx,
                    .fraction = hit.fraction / max_distance,
                    .distance = hit.fraction,
                    .point = origin + dir * splat(hit.fraction),
                    .normal = hit.normal,
                };
            }
        } else {
            stack.push(node.child1);
            stack.push(node.child2);
        }
    }
    return result;
}

/// Append every body whose fat AABB overlaps `box` and passes the filter.
pub fn overlapAabb(
    world: *const World,
    scratch: std.mem.Allocator,
    box: Aabb,
    out: *std.ArrayListUnmanaged(BodyIndex),
    filter: QueryFilter,
) !void {
    var candidates: std.ArrayListUnmanaged(BodyIndex) = .empty;
    defer candidates.deinit(scratch);
    try world.broadphase.queryAabb(scratch, box, &candidates);
    for (candidates.items) |idx| {
        const body: *const Body = &world.bodies.data[idx];
        if (queryAllows(body, idx, filter)) {
            try out.append(scratch, idx);
        }
    }
}

/// Append every body that actually contains `point` (exact per-shape test).
pub fn overlapPoint(
    world: *const World,
    scratch: std.mem.Allocator,
    point: Vec,
    out: *std.ArrayListUnmanaged(BodyIndex),
    filter: QueryFilter,
) !void {
    const bp: *const BroadPhase = &world.broadphase;
    if (bp.root == BroadPhase.NULL_NODE) {
        return;
    }
    var stack: BvhStack = .{};
    stack.push(bp.root);
    while (stack.pop()) |node_index| {
        if (node_index == BroadPhase.NULL_NODE) {
            continue;
        }
        const node: *const BroadPhase.Node = &bp.nodes.items[node_index];
        if (!aabbContainsPoint(node.aabb, point)) {
            continue;
        }
        if (BroadPhase.isLeaf(node)) {
            const idx: BodyIndex = node.body;
            const body: *const Body = &world.bodies.data[idx];
            if (!queryAllows(body, idx, filter)) {
                continue;
            }
            const shape: *const Shape = world.shapes.get(body.shape);
            if (pointInShape(shape, body.com_pos, body.rot, point)) {
                try out.append(scratch, idx);
            }
        } else {
            stack.push(node.child1);
            stack.push(node.child2);
        }
    }
}

/// Append every body whose shape actually overlaps the given shape at the given pose.
pub fn overlapShape(
    world: *const World,
    scratch: std.mem.Allocator,
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    out: *std.ArrayListUnmanaged(BodyIndex),
    filter: QueryFilter,
) !void {
    const local_bounds: Aabb = shapeLocalBounds(shape);
    const world_bounds: Aabb = transformAabb(local_bounds, pos, rot);
    var candidates: std.ArrayListUnmanaged(BodyIndex) = .empty;
    defer candidates.deinit(scratch);
    try world.broadphase.queryAabb(scratch, world_bounds, &candidates);
    for (candidates.items) |idx| {
        const body: *const Body = &world.bodies.data[idx];
        if (!queryAllows(body, idx, filter)) {
            continue;
        }
        const other: *const Shape = world.shapes.get(body.shape);
        // speculative = 0: only report a real touch or overlap.
        if (collide(shape, pos, rot, other, body.com_pos, body.rot, 0.0) != null) {
            try out.append(scratch, idx);
        }
    }
}

/// First contact of a swept convex `shape_a` against `shape_b` of ANY type, decomposing
/// compounds / meshes / height fields / decorators / planes into convex leaves the same way
/// collideShapes does (the cores cast alone only understands convex shapes). Returns the earliest
/// hit with the contact normal pointing toward the cast shape A — active-edge fixed for mesh and
/// height-field leaves, exactly like the collide path — plus the sub-shape discriminator on B.
/// `shape_a` must be convex. Used by scene shape casts and the character's swept move.
const CastContact = struct {
    fraction: f32,
    normal: Vec, // world-space, points toward the cast shape A
    point: Vec, // world-space contact point on B
    sub: u32, // sub-shape discriminator on B (packSub(0, leaf)); 0 for a plain leaf
};

/// Sweep convex `shape_a` against a triangle mesh: BVH-cull to the triangles the swept AABB
/// covers, cast against each, keep the earliest, and snap the normal off inactive seams.
fn castConvexVsMesh(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    displacement: Vec,
    mesh: *const Mesh,
    mesh_pos: Vec,
    mesh_rot: Quat,
    r1: f32,
    tolerance: f32,
    back_face_mode: BackFaceMode,
    scratch: std.mem.Allocator,
) !?CastContact {
    const a_local: Aabb = shapeLocalBounds(shape_a);
    const start: Aabb = transformAabb(a_local, pos_a, rot_a);
    const end: Aabb = .{ .min = start.min + displacement, .max = start.max + displacement };
    const swept_world: Aabb = start.combine(end).expandedBy(tolerance + r1);
    const query_local: Aabb = transformAabbInverse(swept_world, mesh_pos, mesh_rot);

    var tris: std.ArrayListUnmanaged(u32) = .empty;
    defer tris.deinit(scratch);
    try queryMeshBvh(mesh, query_local, &tris, scratch);

    var best: ?CastContact = null;
    var best_frac: f32 = floatMax(f32);
    for (tris.items) |ti| {
        const t: MeshTriangle = mesh.triangles[ti];
        const w0: Vec = mesh_pos + rotate(mesh_rot, mesh.vertices[t.v[0]]);
        const w1: Vec = mesh_pos + rotate(mesh_rot, mesh.vertices[t.v[1]]);
        const w2: Vec = mesh_pos + rotate(mesh_rot, mesh.vertices[t.v[2]]);
        const tri_shape: Shape = .{ .triangle = .{ .v0 = w0, .v1 = w1, .v2 = w2 } };
        const hit: ShapeCastContact = shapeCastCoresContact(
            shape_a,
            pos_a,
            rot_a,
            displacement,
            &tri_shape,
            vec_zero,
            quat_identity,
            r1,
            0.0,
            tolerance,
        ) orelse continue;
        if (hit.fraction < best_frac) {
            const world_normal: Vec = rotate(mesh_rot, t.normal);
            if (back_face_mode == .ignore_back_faces and dot3(world_normal, hit.normal) < 0.0) {
                continue; // other shape is behind the front face
            }
            best_frac = hit.fraction;
            // hit.normal points toward A, i.e. triangle -> other; fixMeshNormal returns the
            // active-edge-corrected normal in the same (toward-A) orientation.
            const fixed: Vec = fixMeshNormal(world_normal, t.active_edges, w0, w1, w2, hit.point, hit.normal);
            best = .{ .fraction = hit.fraction, .normal = fixed, .point = hit.point, .sub = packSub(0, ti) };
        }
    }
    return best;
}

/// One swept convex-vs-height-field-triangle test, folded out of castConvexVsHeightField to keep
/// the cell loop readable. Updates `best`/`best_frac` in place if this triangle is hit sooner.
fn castConvexVsHfTri(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    displacement: Vec,
    v0: Vec,
    v1: Vec,
    v2: Vec,
    active_edges: u8,
    r1: f32,
    tolerance: f32,
    back_face_mode: BackFaceMode,
    tri_id: usize,
    best: *?CastContact,
    best_frac: *f32,
) void {
    const tri_shape: Shape = .{ .triangle = .{ .v0 = v0, .v1 = v1, .v2 = v2 } };
    const hit: ShapeCastContact = shapeCastCoresContact(
        shape_a,
        pos_a,
        rot_a,
        displacement,
        &tri_shape,
        vec_zero,
        quat_identity,
        r1,
        0.0,
        tolerance,
    ) orelse return;
    if (hit.fraction < best_frac.*) {
        const face_normal: Vec = triFaceNormal(v0, v1, v2);
        if (back_face_mode == .ignore_back_faces and dot3(face_normal, hit.normal) < 0.0) {
            return; // other shape is behind the front face
        }
        best_frac.* = hit.fraction;
        const fixed: Vec = fixMeshNormal(face_normal, active_edges, v0, v1, v2, hit.point, hit.normal);
        best.* = .{
            .fraction = hit.fraction,
            .normal = fixed,
            .point = hit.point,
            .sub = packSub(0, tri_id),
        };
    }
}

/// Sweep convex `shape_a` against a height field: walk the grid cells the swept AABB covers,
/// cast against the two triangles of each, keep the earliest, and snap off inactive seams.
fn castConvexVsHeightField(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    displacement: Vec,
    hf: *const HeightField,
    hf_pos: Vec,
    hf_rot: Quat,
    r1: f32,
    tolerance: f32,
    back_face_mode: BackFaceMode,
) ?CastContact {
    const a_local: Aabb = shapeLocalBounds(shape_a);
    const start: Aabb = transformAabb(a_local, pos_a, rot_a);
    const end: Aabb = .{ .min = start.min + displacement, .max = start.max + displacement };
    const swept_world: Aabb = start.combine(end).expandedBy(tolerance + r1);
    const ql: Aabb = transformAabbInverse(swept_world, hf_pos, hf_rot);

    const inv_cell: f32 = 1.0 / hf.cell_size;
    const max_cx: i64 = @as(i64, hf.sample_count_x) - 2;
    const max_cz: i64 = @as(i64, hf.sample_count_z) - 2;
    const cx0: i64 = clamp(floori(i64, ql.min[0] * inv_cell), 0, max_cx);
    const cx1: i64 = clamp(floori(i64, ql.max[0] * inv_cell), 0, max_cx);
    const cz0: i64 = clamp(floori(i64, ql.min[2] * inv_cell), 0, max_cz);
    const cz1: i64 = clamp(floori(i64, ql.max[2] * inv_cell), 0, max_cz);
    if (cx1 < cx0 or cz1 < cz0) {
        return null;
    }

    const cells_x: usize = hf.sample_count_x - 1;
    var best: ?CastContact = null;
    var best_frac: f32 = floatMax(f32);
    var cz: i64 = cz0;
    while (cz <= cz1) : (cz += 1) {
        var cx: i64 = cx0;
        while (cx <= cx1) : (cx += 1) {
            const gx: u32 = @intCast(cx);
            const gz: u32 = @intCast(cz);
            const a: Vec = hf_pos + rotate(hf_rot, hfVertex(hf, gx, gz));
            const b: Vec = hf_pos + rotate(hf_rot, hfVertex(hf, gx + 1, gz));
            const c: Vec = hf_pos + rotate(hf_rot, hfVertex(hf, gx, gz + 1));
            const d: Vec = hf_pos + rotate(hf_rot, hfVertex(hf, gx + 1, gz + 1));
            const cell_id: usize = @as(usize, @intCast(cz)) * cells_x + @as(usize, @intCast(cx));
            castConvexVsHfTri(
                shape_a,
                pos_a,
                rot_a,
                displacement,
                a,
                d,
                b,
                hf.active_edges[cell_id * 2 + 0],
                r1,
                tolerance,
                back_face_mode,
                cell_id * 2 + 0,
                &best,
                &best_frac,
            );
            castConvexVsHfTri(
                shape_a,
                pos_a,
                rot_a,
                displacement,
                a,
                c,
                d,
                hf.active_edges[cell_id * 2 + 1],
                r1,
                tolerance,
                back_face_mode,
                cell_id * 2 + 1,
                &best,
                &best_frac,
            );
        }
    }
    return best;
}

/// Sweep convex `shape_a` against an infinite plane half-space, analytically: advance the shape's
/// leading surface point (its support toward the plane) until it reaches the plane.
fn castConvexVsPlane(
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    displacement: Vec,
    plane: *const PlaneShape,
    plane_pos: Vec,
    plane_rot: Quat,
    r1: f32,
    tolerance: f32,
) ?CastContact {
    const n: Vec = rotate(plane_rot, plane.normal); // world outward normal
    const plane_point: Vec = plane_pos + rotate(plane_rot, plane.normal * splat(-plane.distance));
    const core: Vec = supportCoreWorld(shape_a, pos_a, rot_a, vec_zero - n);
    const leading: Vec = core - n * splat(r1); // deepest surface point toward the plane
    const d0: f32 = dot3(n, leading - plane_point);
    if (d0 <= tolerance) {
        return .{ .fraction = 0.0, .normal = n, .point = leading - n * splat(d0), .sub = 0 };
    }
    const closing: f32 = -dot3(displacement, n); // >0 when moving toward the plane
    if (closing <= 1.0e-9) {
        return null;
    }
    const frac: f32 = d0 / closing;
    if (frac >= 1.0) {
        return null;
    }
    const contact_point: Vec = leading + displacement * splat(frac);
    const on_plane: Vec = contact_point - n * splat(dot3(n, contact_point - plane_point));
    return .{ .fraction = frac, .normal = n, .point = on_plane, .sub = 0 };
}

fn castConvexVsShape(
    store: *const ShapeStore,
    shape_a: *const Shape,
    pos_a: Vec,
    rot_a: Quat,
    displacement: Vec,
    shape_b: *const Shape,
    pos_b: Vec,
    rot_b: Quat,
    r1: f32,
    tolerance: f32,
    back_face_mode: BackFaceMode,
    scratch: std.mem.Allocator,
) !?CastContact {
    const resolved: ResolvedShape = resolveDecorated(store, shape_b, pos_b, rot_b);
    const sb: *const Shape = resolved.shape;
    const bp: Vec = resolved.pos;
    const br: Quat = resolved.rot;

    switch (sb.*) {
        .empty => return null,
        .compound => |c| {
            var best: ?CastContact = null;
            var best_frac: f32 = floatMax(f32);
            for (c.children, 0..) |child, ci| {
                const cs: *const Shape = store.get(child.shape);
                const cpos: Vec = bp + rotate(br, child.local_pos);
                const crot: Quat = qmul(br, child.local_rot);
                const sub_hit: ?CastContact = try castConvexVsShape(
                    store,
                    shape_a,
                    pos_a,
                    rot_a,
                    displacement,
                    cs,
                    cpos,
                    crot,
                    r1,
                    tolerance,
                    back_face_mode,
                    scratch,
                );
                if (sub_hit) |h| {
                    if (h.fraction < best_frac) {
                        best_frac = h.fraction;
                        best = .{
                            .fraction = h.fraction,
                            .normal = h.normal,
                            .point = h.point,
                            .sub = packSub(0, ci),
                        };
                    }
                }
            }
            return best;
        },
        .mesh => return try castConvexVsMesh(
            shape_a,
            pos_a,
            rot_a,
            displacement,
            &sb.mesh,
            bp,
            br,
            r1,
            tolerance,
            back_face_mode,
            scratch,
        ),
        .heightfield => return castConvexVsHeightField(
            shape_a,
            pos_a,
            rot_a,
            displacement,
            &sb.heightfield,
            bp,
            br,
            r1,
            tolerance,
            back_face_mode,
        ),
        .plane => return castConvexVsPlane(
            shape_a,
            pos_a,
            rot_a,
            displacement,
            &sb.plane,
            bp,
            br,
            r1,
            tolerance,
        ),
        else => {
            const hit: ShapeCastContact = shapeCastCoresContact(
                shape_a,
                pos_a,
                rot_a,
                displacement,
                sb,
                bp,
                br,
                r1,
                convexRadius(sb),
                tolerance,
            ) orelse return null;
            return CastContact{
                .fraction = hit.fraction,
                .normal = hit.normal,
                .point = hit.point,
                .sub = 0,
            };
        },
    }
}

/// Sweep `shape` from `pos` along `direction` for `max_distance` and return the
/// nearest body it would first touch, or null. Reuses the CCD shape cast.
pub fn castShapeClosest(
    world: *const World,
    scratch: std.mem.Allocator,
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    direction: Vec,
    max_distance: f32,
    filter: QueryFilter,
) !?ShapeCastHit {
    const dir_len: f32 = length3(direction);
    if (dir_len < 1.0e-9) {
        return null;
    }
    const displacement: Vec = direction * splat(max_distance / dir_len);

    const local_bounds: Aabb = shapeLocalBounds(shape);
    const start_bounds: Aabb = transformAabb(local_bounds, pos, rot);
    const end_bounds: Aabb = .{
        .min = start_bounds.min + displacement,
        .max = start_bounds.max + displacement,
    };
    const swept: Aabb = start_bounds.combine(end_bounds).expandedBy(world.settings.speculative_distance);

    var candidates: std.ArrayListUnmanaged(BodyIndex) = .empty;
    defer candidates.deinit(scratch);
    try world.broadphase.queryAabb(scratch, swept, &candidates);

    const self_radius: f32 = convexRadius(shape);
    var closest: f32 = 1.0;
    var result: ?ShapeCastHit = null;
    for (candidates.items) |idx| {
        const body: *const Body = &world.bodies.data[idx];
        if (!queryAllows(body, idx, filter)) {
            continue;
        }
        const other: *const Shape = world.shapes.get(body.shape);
        // `shape` (the probe) must be convex; `other` may be any type — castConvexVsShape
        // decomposes compounds / meshes / height fields / planes into convex leaves.
        const hit: CastContact = try castConvexVsShape(
            &world.shapes,
            shape,
            pos,
            rot,
            displacement,
            other,
            body.com_pos,
            body.rot,
            self_radius,
            world.settings.penetration_slop,
            .collide_back_faces,
            scratch,
        ) orelse continue;
        if (hit.fraction < closest) {
            closest = hit.fraction;
            result = .{
                .body = idx,
                .fraction = hit.fraction,
                .normal = hit.normal,
                .point = hit.point,
                .sub = hit.sub,
            };
        }
    }
    return result;
}

/// Opaque surface id at a contact, given the hit body and the contact's sub-shape discriminator
/// (`sub` from a Contact / SubCollision / ShapeCastHit / CharacterContact). For a mesh or height
/// field with per-triangle materials, the triangle index is the low 16 bits of `sub`; otherwise
/// (or out of range, or a single-surface shape) the body's material is returned. The id is opaque
/// to the engine — map it to friction / restitution / footstep sounds in your own table.
pub fn materialAt(world: *const World, body_idx: BodyIndex, sub: u32) u16 {
    const body: *const Body = &world.bodies.data[body_idx];
    // Peel decorators without needing a transform — only the leaf shape type/material matters.
    var s: *const Shape = world.shapes.get(body.shape);
    while (true) {
        switch (s.*) {
            .rotated_translated => |rt| s = world.shapes.get(rt.child),
            .offset_com => |oc| s = world.shapes.get(oc.child),
            else => break,
        }
    }
    const tri: usize = sub & 0xFFFF;
    switch (s.*) {
        .mesh => |m| return if (tri < m.materials.len) m.materials[tri] else body.material,
        .heightfield => |hf| return if (tri < hf.materials.len) hf.materials[tri] else body.material,
        else => return body.material,
    }
}

// =============================================================================
// CharacterVirtual: a kinematic capsule (or any convex/compound) controller that is NOT
// backed by a rigid body. You set its velocity and call try characterUpdate() (or
// characterExtendedUpdate) each frame; it slides through the world with a swept, time-of-
// impact, multi-plane constraint solver and reports a ground state. This is a close port of
// Jolt Physics' CharacterVirtual (Jolt/Physics/Character/CharacterVirtual.cpp): the move
// loop (MoveShape), the constraint solver (DetermineConstraints / SolveConstraints /
// HandleContact), the swept first-contact test (GetFirstContactForSweep), the ground
// classifier (UpdateSupportingContact, incl. the wedged-between-steep-slopes solve), and
// the stair-walk / stick-to-floor maneuvers (WalkStairs / StickToFloor / ExtendedUpdate).
//
// DIVERGENCES FROM JOLT, audited function-by-function against CharacterVirtual.cpp.
// Split by verdict, because the two kinds want opposite treatment: the justified ones
// should be left alone, the open ones are bugs waiting for a symptom.
//
// JUSTIFIED (our engine lacks the underlying feature; leave them):
//   * single collision normal — no separate geometry "surface normal", so back-facing /
//     active-edge / enhanced-internal-edge handling is absent;
//   * the swept padding correction uses Jolt's simple fraction pull-back instead of the
//     GJK face-inflation path (sCorrectFractionForCharacterPadding). Note Jolt itself
//     takes this same fallback whenever the hit face has fewer than 2 vertices;
//   * character-vs-character collision, the inner rigid body, ScaledShape, materials and
//     SaveState/RestoreState are not ported;
//   * a sweep skips a whole body when its earliest hit is an ignored sub-shape rather
//     than probing the next sub (Jolt's collector is per-sub).
// The contact listener DOES support the simulation-affecting hooks (validate,
// added/settings, solve, adjust-body-velocity) plus added/removed events via a key diff.
//
// OPEN — known-unjustified, fix when a symptom appears:
//   * cvGetContactsAtPosition takes no movement direction, so Jolt's
//     mActiveEdgeMovementDirection never reaches active-edge detection. We HAVE that
//     machinery, so this is a real gap rather than an absent feature.
//   * the cast collector never calls cvValidateContact; Jolt validates cast hits as well
//     as collide hits. Ours only consults the ignored list.
//   * Jolt's cast filter is `distance + normal·displacement < -collision_tolerance`. Our
//     cast reports no penetration depth, so distance is 0 and we apply the reduced form.
//
// Regression coverage for the move loop: src/tests/character_walk_test.zig.
//
// active_contacts and the listener key set are owned by the character and allocated from the
// world allocator; call char.deinit(world.allocator) when done.
// =============================================================================

pub const GroundState = enum {
    on_ground, // supported by a surface no steeper than max_slope (incl. wedged between steep slopes)
    on_steep_ground, // touching ground-facing geometry too steep to stand on (slides off)
    not_supported, // touching only walls/ceilings — nothing to stand on
    in_air, // no contacts at all
};

/// Per-contact response knobs the listener can set in its on_contact_added callback.
pub const CharacterContactSettings = struct {
    can_push_character: bool = true, // contact velocity may push the character
    can_receive_impulses: bool = true, // character may push this (dynamic) body
};

/// One world contact against the character. `contact_normal` and `surface_normal` both point
/// from the world toward the character (Jolt keeps them distinct; we only have the collision
/// normal so they are equal here). `distance` <= 0 means an actual overlap, > 0 a predictive
/// gap. `fraction` is the sweep fraction (0 for collide-shape contacts).
pub const CharacterContact = struct {
    contact_normal: Vec,
    surface_normal: Vec,
    position: Vec, // world contact point on the other body
    linear_velocity: Vec, // velocity of the other body at the contact point
    distance: f32,
    fraction: f32 = 0.0,
    body: BodyIndex,
    sub: u32, // sub-shape discriminator (packSub)
    motion_type: MotionType,
    is_sensor: bool,
    user_data: u64,
    material: u16 = 0, // opaque surface id of the contacted shape (per-triangle for meshes)
    had_collision: bool = false, // the character actually collided (not just a predictive contact)
    was_discarded: bool = false, // the validate callback rejected it (or it is a sensor)
    can_push_character: bool = true,
};

/// Optional callbacks, modelled on Jolt's CharacterContactListener. All are nullable; a null
/// listener means default behaviour. Only the simulation-affecting hooks plus add/remove
/// events are provided (no per-character-pair variants, no OnContactPersisted distinction).
pub const CharacterContactListener = struct {
    context: ?*anyopaque = null,
    /// Override the velocity read from a contacted body (e.g. conveyor belts).
    on_adjust_body_velocity: ?*const fn (?*anyopaque, *const World, BodyIndex, *Vec, *Vec) void = null,
    /// Return false to discard a contact entirely (no response, no events).
    on_contact_validate: ?*const fn (
        ?*anyopaque,
        // This listener's callbacks take *CharacterVirtual, while CharacterVirtual
        // holds a *CharacterContactListener (its `listener` field) - a character
        // <-> listener cycle that no declaration order can resolve.
        // lint:off decl-order: CharacterVirtual<->CharacterContactListener cycle
        *const CharacterVirtual,
        *const CharacterContact,
    ) bool = null,
    /// Fill `settings` for a contact the first time it is seen this update.
    on_contact_added: ?*const fn (
        ?*anyopaque,
        *const CharacterVirtual,
        *const CharacterContact,
        *CharacterContactSettings,
    ) void = null,
    /// Modify the post-collision character velocity for one contact (`new_velocity` in/out).
    on_contact_solve: ?*const fn (
        ?*anyopaque,
        *const CharacterVirtual,
        *const CharacterContact,
        Vec,
        *Vec,
    ) void = null,
    /// A contact that collided last update is gone this update.
    on_contact_removed: ?*const fn (?*anyopaque, *const CharacterVirtual, BodyIndex, u32) void = null,
};

const CharContactKey = struct {
    body: BodyIndex,
    sub: u32,
    fn eql(a: CharContactKey, b: CharContactKey) bool {
        return a.body == b.body and a.sub == b.sub;
    }
};

/// Settings the user provides via ExtendedUpdate (Jolt's ExtendedUpdateSettings). Vectors are
/// absolute (so the up axis is baked in); zero a vector to disable that maneuver.
pub const ExtendedUpdateSettings = struct {
    stick_to_floor_step_down: Vec = vec(0.0, -0.5, 0.0),
    walk_stairs_step_up: Vec = vec(0.0, 0.4, 0.0),
    walk_stairs_min_step_forward: f32 = 0.02,
    walk_stairs_step_forward_test: f32 = 0.15,
    walk_stairs_cos_angle_forward_contact: f32 = 0.258819, // cos(75°)
    walk_stairs_step_down_extra: Vec = vec_zero,
};

pub const CharacterVirtual = struct {
    shape: ShapeId, // usually a capsule; any convex (or compound) shape works
    position: Vec, // world position of the shape origin
    rotation: Quat = quat_identity,
    linear_velocity: Vec = vec_zero,

    // Tuning (defaults mirror Jolt's CharacterVirtualSettings).
    up: Vec = vec(0.0, 1.0, 0.0),
    // local-space plane below which contacts can support
    supporting_volume_normal: Vec = vec(0.0, 1.0, 0.0),
    supporting_volume_constant: f32 = -1.0e10, // default: permissive (everything supports)
    max_slope_cos: f32 = 0.642787, // cos(50°): steepest slope you can stand on
    shape_offset: Vec = vec_zero, // offset of the shape from `position`
    predictive_distance: f32 = 0.1, // how far to scan past the shape for predictive contacts
    character_padding: f32 = 0.02, // skin kept between the shape and geometry for robust sweeping
    collision_tolerance: f32 = 1.0e-3, // how far we are willing to penetrate
    penetration_recovery_speed: f32 = 1.0, // 0 = never resolve penetration, 1 = resolve in one update
    min_time_remaining: f32 = 1.0e-4, // early-out: stop when this little time is left
    max_collision_iterations: u32 = 5, // outer collide/solve passes per update
    max_constraint_iterations: u32 = 15, // inner velocity-solve iterations
    max_num_hits: u32 = 256, // contact-collection cap (hit reduction past this)
    hit_reduction_cos_max_angle: f32 = 0.999, // merge same-body contacts within ~2.5°; -1 disables
    mass: f32 = 70.0, // used to push bodies and to load the ground
    max_strength: f32 = 100.0, // max push force (N); 0 disables pushing
    filter: QueryFilter = .{}, // which bodies block the character
    back_face_mode: BackFaceMode = .collide_back_faces, // ignore_back_faces => front-only (one-way)
    listener: ?*const CharacterContactListener = null,

    // Output / persistent state.
    ground_state: GroundState = .in_air,
    ground_normal: Vec = vec(0.0, 1.0, 0.0),
    ground_body: BodyIndex = none_body,
    ground_position: Vec = vec_zero,
    ground_velocity: Vec = vec_zero,
    ground_material: u16 = 0, // opaque surface id of the ground contact (Jolt's GetGroundMaterial)
    last_dt: f32 = 0.0,
    active_contacts: std.ArrayListUnmanaged(CharacterContact) = .empty,
    contact_keys_prev: std.ArrayListUnmanaged(CharContactKey) = .empty,

    pub fn deinit(char: *CharacterVirtual, gpa: std.mem.Allocator) void {
        char.active_contacts.deinit(gpa);
        char.contact_keys_prev.deinit(gpa);
    }

    pub fn isSupported(char: *const CharacterVirtual) bool {
        return char.ground_state == .on_ground or char.ground_state == .on_steep_ground;
    }
};

const cv_no_max_slope_angle: f32 = 0.9999;

/// Jolt CharacterBase::IsSlopeTooSteep. With max_slope_cos near 1 the limit is disabled.
fn cvSlopeTooSteep(char: *const CharacterVirtual, normal: Vec) bool {
    return char.max_slope_cos < cv_no_max_slope_angle and dot3(normal, char.up) < char.max_slope_cos;
}

fn cvNorm(v: Vec, fallback: Vec) Vec {
    const len: f32 = length3(v);
    if (len < 1.0e-12) {
        return fallback;
    }
    return v / splat(len);
}

/// A constraint plane derived from a contact: signedDistance(displacement) = n·d + constant.
const CharConstraint = struct {
    contact: usize, // index into the contacts list this constraint was built from
    linear_velocity: Vec, // contact (+penetration recovery) velocity
    plane_normal: Vec,
    plane_constant: f32,
    is_steep_slope: bool = false,
    projected_velocity: f32 = 0.0,
    toi: f32 = 0.0,
};

fn cvPlaneSignedDistance(normal: Vec, constant: f32, v: Vec) f32 {
    return dot3(normal, v) + constant;
}

/// Shape position passed to collide/cast: the character origin plus its (rotated) shape offset.
fn cvShapePos(char: *const CharacterVirtual, pos: Vec) Vec {
    return pos + rotate(char.rotation, char.shape_offset);
}

/// Velocity of body `bi` (linear, angular), zero for static/kinematic-without-motion, with the
/// optional listener override. Mirrors Jolt's GetAdjustedBodyVelocity.
const CvBodyVel = struct { lin: Vec, ang: Vec };
fn cvAdjustedBodyVelocity(
    world: *const World,
    char: *const CharacterVirtual,
    bi: BodyIndex,
) CvBodyVel {
    var lin: Vec = vec_zero;
    var ang: Vec = vec_zero;
    const body: *const Body = &world.bodies.data[bi];
    if (body.motion_type != .static) {
        const m: *const Motion = &world.motion[bi];
        lin = m.lin_vel;
        ang = m.ang_vel;
    }
    if (char.listener) |l| {
        if (l.on_adjust_body_velocity) |cb| {
            cb(l.context, world, bi, &lin, &ang);
        }
    }
    return .{ .lin = lin, .ang = ang };
}

/// Jolt CalculateCharacterGroundVelocity: the velocity of a (possibly rotating) supporting body
/// evaluated at the character's position, so the character follows platform rotation.
fn cvCharacterGroundVelocity(
    char: *const CharacterVirtual,
    com: Vec,
    lin: Vec,
    ang: Vec,
    dt: f32,
) Vec {
    const ang_len_sq: f32 = lengthSq3(ang);
    if (ang_len_sq < 1.0e-12) {
        return lin;
    }
    const ang_len: f32 = @sqrt(ang_len_sq);
    const rot: Quat = quatFromAxisAngle(ang / splat(ang_len), ang_len * dt);
    const new_position: Vec = com + rotate(rot, char.position - com);
    return lin + (new_position - char.position) / splat(dt);
}

/// Append a hit, or if we are at the hit cap merge near-duplicate same-body contacts
/// (Jolt ContactCollector::AddHit hit reduction).
fn cvAddOrReduceHit(
    char: *const CharacterVirtual,
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(CharacterContact),
    hit: CharacterContact,
) !void {
    if (out.items.len >= char.max_num_hits and char.hit_reduction_cos_max_angle > -1.0) {
        var i: usize = out.items.len;
        while (i > 0) : (i -= 1) {
            const ci: usize = i - 1;
            var j: usize = ci;
            while (j > 0) : (j -= 1) {
                const cj: usize = j - 1;
                const ic: *const CharacterContact = &out.items[ci];
                const jc: *const CharacterContact = &out.items[cj];
                const same_body: bool = ic.body == jc.body and ic.sub == jc.sub;
                const similar: bool =
                    dot3(ic.contact_normal, jc.contact_normal) > char.hit_reduction_cos_max_angle;
                if (same_body and similar) {
                    // Drop the one with the larger (less penetrating) distance.
                    const drop: usize = if (ic.distance > jc.distance) ci else cj;
                    _ = out.swapRemove(drop);
                    break;
                }
            }
            if (out.items.len < char.max_num_hits) {
                break;
            }
        }
    }
    try out.append(gpa, hit);
}

fn cvContactLess(_: void, a: CharacterContact, b: CharacterContact) bool {
    if (a.body != b.body) {
        return a.body < b.body;
    }
    if (a.sub != b.sub) {
        return a.sub < b.sub;
    }
    return a.distance < b.distance;
}

/// Gather every world contact on the character at `pos` into `out` (cleared first), moving in
/// `movement_dir`. Port of GetContactsAtPosition + CheckCollision: collide the character shape
/// against each nearby body, build a CharacterContact per manifold point, run hit reduction
/// past max_num_hits, sort for determinism, then subtract the character padding from distances.
fn cvGetContactsAtPosition(
    world: *const World,
    char: *const CharacterVirtual,
    pos: Vec,
    scratch: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(CharacterContact),
) !void {
    out.clearRetainingCapacity();
    const shape: *const Shape = world.shapes.get(char.shape);
    const shape_pos: Vec = cvShapePos(char, pos);
    const margin: f32 = char.predictive_distance + char.character_padding;
    const query_bounds: Aabb =
        transformAabb(shapeLocalBounds(shape), shape_pos, char.rotation).expandedBy(margin);

    var nearby: std.ArrayListUnmanaged(BodyIndex) = .empty;
    defer nearby.deinit(scratch);
    try world.broadphase.queryAabb(scratch, query_bounds, &nearby);
    var subs: std.ArrayListUnmanaged(SubCollision) = .empty;
    defer subs.deinit(scratch);

    for (nearby.items) |bi| {
        const body: *const Body = &world.bodies.data[bi];
        if (!queryAllows(body, bi, char.filter)) {
            continue;
        }
        const bshape: *const Shape = world.shapes.get(body.shape);
        subs.clearRetainingCapacity();
        try collideShapes(
            &world.shapes,
            shape,
            shape_pos,
            char.rotation,
            bshape,
            body.com_pos,
            body.rot,
            char.predictive_distance + char.character_padding,
            char.back_face_mode,
            &subs,
            scratch,
        );

        const bv: CvBodyVel = cvAdjustedBodyVelocity(world, char, bi);
        for (subs.items) |sc| {
            const m: Manifold = sc.manifold;
            var i: u8 = 0;
            while (i < m.count) : (i += 1) {
                const point: Vec = m.points[i].point_on_b;
                // separation = (pob - poa)·normal: >0 predictive gap, <0 penetrating.
                const separation: f32 = dot3(m.points[i].point_on_b - m.points[i].point_on_a, m.normal);
                // manifold normal is char -> world, so the contact normal toward the character is -normal.
                const contact_normal: Vec = cvNorm(-m.normal, char.up);
                const point_velocity: Vec = bv.lin + cross(bv.ang, point - body.com_pos);
                try cvAddOrReduceHit(char, scratch, out, .{
                    .contact_normal = contact_normal,
                    .surface_normal = contact_normal, // we lack a separate geometry surface normal
                    .position = point,
                    .linear_velocity = point_velocity,
                    .distance = separation,
                    .fraction = 0.0,
                    .body = bi,
                    .sub = sc.sub,
                    .motion_type = body.motion_type,
                    .is_sensor = body.is_sensor,
                    .user_data = body.user_data,
                    .material = materialAt(world, bi, sc.sub),
                });
            }
        }
    }

    // Sort for determinism (broadphase order is not stable), then pull distances back by the
    // padding so the character keeps a small skin off the geometry (Jolt GetContactsAtPosition).
    std.mem.sort(CharacterContact, out.items, {}, cvContactLess);
    for (out.items) |*c| {
        c.distance -= char.character_padding;
    }
}

/// Jolt RemoveConflictingContacts: drop deeply-penetrating same-body contacts with opposing
/// normals (so a thin wall's front and back faces don't pin the character). Discarded contacts
/// go to `ignored` so the sweep skips them too.
fn cvRemoveConflictingContacts(
    char: *const CharacterVirtual,
    scratch: std.mem.Allocator,
    contacts: *std.ArrayListUnmanaged(CharacterContact),
    ignored: *std.ArrayListUnmanaged(CharContactKey),
) !void {
    const min_pen: f32 = 1.25 * char.character_padding;
    var c1: usize = 0;
    while (c1 < contacts.items.len) : (c1 += 1) {
        if (contacts.items[c1].distance > -min_pen) {
            continue;
        }
        var c2: usize = c1 + 1;
        while (c2 < contacts.items.len) : (c2 += 1) {
            const same_body: bool = contacts.items[c1].body == contacts.items[c2].body and
                contacts.items[c1].sub == contacts.items[c2].sub;
            const opposing: bool =
                dot3(contacts.items[c1].contact_normal, contacts.items[c2].contact_normal) < 0.0;
            if (same_body and contacts.items[c2].distance <= -min_pen and opposing) {
                if (contacts.items[c1].distance < contacts.items[c2].distance) {
                    try ignored.append(scratch, .{
                        .body = contacts.items[c2].body,
                        .sub = contacts.items[c2].sub,
                    });
                    _ = contacts.orderedRemove(c2);
                    c2 -= 1;
                } else {
                    try ignored.append(scratch, .{
                        .body = contacts.items[c1].body,
                        .sub = contacts.items[c1].sub,
                    });
                    _ = contacts.orderedRemove(c1);
                    c1 -= 1;
                    break;
                }
            }
        }
    }
}

/// Jolt ValidateContact: ask the listener whether to keep this contact.
fn cvValidateContact(char: *const CharacterVirtual, contact: *const CharacterContact) bool {
    if (char.listener) |l| {
        if (l.on_contact_validate) |cb| {
            return cb(l.context, char, contact);
        }
    }
    return true;
}

/// Jolt ContactAdded (settings half): fetch the per-contact response settings from the listener.
/// The add/remove *events* are fired separately in characterUpdate via a key diff, so this may
/// run more than once per update; it is used only to read can_push_character / can_receive_impulses.
fn cvContactSettings(
    char: *const CharacterVirtual,
    contact: *const CharacterContact,
) CharacterContactSettings {
    var settings: CharacterContactSettings = .{};
    if (char.listener) |l| {
        if (l.on_contact_added) |cb| {
            cb(l.context, char, contact, &settings);
        }
    }
    return settings;
}

/// Jolt DetermineConstraints: one plane per contact, plus a secondary vertical plane for steep
/// slopes so the character cannot ride up them.
fn cvDetermineConstraints(
    char: *const CharacterVirtual,
    scratch: std.mem.Allocator,
    contacts: []CharacterContact,
    dt: f32,
    out: *std.ArrayListUnmanaged(CharConstraint),
) !void {
    var ci: usize = 0;
    while (ci < contacts.len) : (ci += 1) {
        const c: *const CharacterContact = &contacts[ci];
        var contact_velocity: Vec = c.linear_velocity;
        // Penetrating contact: add a velocity that pushes the character out at the desired speed.
        if (c.distance < 0.0) {
            const recover: f32 = c.distance * char.penetration_recovery_speed / dt;
            contact_velocity -= c.contact_normal * splat(recover);
        }
        const primary_index: usize = out.items.len;
        try out.append(scratch, .{
            .contact = ci,
            .linear_velocity = contact_velocity,
            .plane_normal = c.contact_normal,
            .plane_constant = c.distance,
        });

        if (cvSlopeTooSteep(char, c.surface_normal)) {
            const dot: f32 = dot3(c.contact_normal, char.up);
            if (dot > 1.0e-3) {
                out.items[primary_index].is_steep_slope = true;
                const normal: Vec = cvNorm(c.contact_normal - char.up * splat(dot), char.up);
                const proj: f32 = dot3(c.linear_velocity, normal);
                try out.append(scratch, .{
                    .contact = ci,
                    .linear_velocity = normal * splat(proj),
                    .plane_normal = normal,
                    .plane_constant = c.distance / dot3(normal, c.contact_normal),
                });
            }
        }
    }
}

/// Jolt HandleContact: when the character first touches a dynamic body, push it toward the
/// character's contact-point speed with an impulse sized by the body's effective mass at the
/// contact (so off-centre pushes impart spin), clamped by max_strength and with the downward
/// component cancelled. Returns false to discard the constraint (validate failed or sensor).
fn cvHandleContact(
    world: *World,
    char: *const CharacterVirtual,
    gpa: std.mem.Allocator,
    velocity: Vec,
    constraint: *const CharConstraint,
    contacts: []CharacterContact,
    dt: f32,
) !bool {
    const contact: *CharacterContact = &contacts[constraint.contact];

    if (!cvValidateContact(char, contact)) {
        return false;
    }
    contact.had_collision = true;

    const settings: CharacterContactSettings = cvContactSettings(char, contact);
    contact.can_push_character = settings.can_push_character;

    if (contact.is_sensor) {
        return false; // no interaction with sensors beyond the (optional) event
    }
    if (!settings.can_receive_impulses or contact.motion_type != .dynamic) {
        return true;
    }

    const bi: BodyIndex = contact.body;
    const body: *const Body = &world.bodies.data[bi];
    const m: *const Motion = &world.motion[bi];
    if (m.inv_mass <= 0.0) {
        return true;
    }

    const c_damping: f32 = 0.9;
    const c_penetration_resolution: f32 = 0.4;
    const relative_velocity: Vec = velocity - contact.linear_velocity;
    const projected_velocity: f32 = dot3(relative_velocity, contact.contact_normal);
    const delta_velocity: f32 =
        -projected_velocity * c_damping - @min(contact.distance, 0.0) * c_penetration_resolution / dt;
    if (delta_velocity < 0.0) {
        return true; // separating
    }

    // Inverse effective mass of body B at the contact point along the contact normal.
    const inv_i: Mat3 = bakeInvInertiaWorld(body.rot, m.inv_inertia_diagonal, m.inertia_rotation);
    const jacobian: Vec = cross(contact.position - body.com_pos, contact.contact_normal);
    const inv_eff_mass: f32 = dot3(inv_i.mulVec(jacobian), jacobian) + m.inv_mass;

    var impulse: f32 = delta_velocity / inv_eff_mass;
    const max_impulse: f32 = char.max_strength * dt;
    if (impulse > max_impulse) {
        impulse = max_impulse;
    }

    var world_impulse: Vec = contact.contact_normal * splat(-impulse);
    const impulse_dot_up: f32 = dot3(world_impulse, char.up);
    if (impulse_dot_up < 0.0) {
        // cancel downward push (gravity is applied later)
        world_impulse -= char.up * splat(impulse_dot_up);
    }
    try world.addImpulseAtPosition(gpa, bi, world_impulse, contact.position);
    return true;
}

const CvSolveResult = struct { displacement: Vec, time_simulated: f32 };

const CvSortCtx = struct { constraints: []CharConstraint, contacts: []CharacterContact };

fn cvConstraintLess(ctx: CvSortCtx, lhs_idx: usize, rhs_idx: usize) bool {
    const l: *const CharConstraint = &ctx.constraints[lhs_idx];
    const r: *const CharConstraint = &ctx.constraints[rhs_idx];
    if (l.toi <= 0.0 and r.toi <= 0.0) {
        return l.projected_velocity > r.projected_velocity;
    }
    if (l.toi != r.toi) {
        return l.toi < r.toi;
    }
    const lmt: u8 = @backingInt(ctx.contacts[l.contact].motion_type);
    const rmt: u8 = @backingInt(ctx.contacts[r.contact].motion_type);
    return lmt > rmt;
}

/// Jolt SolveConstraints: the time-of-impact, multi-plane velocity solver. Advances the velocity
/// plane-by-plane in order of impact time, cancelling velocity into each plane, handling steep
/// slopes and two-plane creases, and avoiding ping-pong between previously-hit planes.
fn cvSolveConstraints(
    world: *World,
    char: *const CharacterVirtual,
    gpa: std.mem.Allocator,
    in_velocity: Vec,
    dt: f32,
    in_time_remaining: f32,
    constraints: []CharConstraint,
    contacts: []CharacterContact,
    ignored: *std.ArrayListUnmanaged(CharContactKey),
    scratch: std.mem.Allocator,
) !CvSolveResult {
    var time_remaining: f32 = in_time_remaining;
    if (constraints.len == 0) {
        return .{ .displacement = in_velocity * splat(time_remaining), .time_simulated = time_remaining };
    }

    const sorted: []usize = try scratch.alloc(usize, constraints.len);
    defer scratch.free(sorted);
    for (sorted, 0..) |*s, i| {
        s.* = i;
    }

    var velocity: Vec = in_velocity;
    var last_velocity: Vec = in_velocity;
    var displacement: Vec = vec_zero;
    var time_simulated: f32 = 0.0;

    const previous: []usize = try scratch.alloc(usize, char.max_constraint_iterations);
    defer scratch.free(previous);
    var num_previous: usize = 0;

    var iteration: u32 = 0;
    while (iteration < char.max_constraint_iterations) : (iteration += 1) {
        // Time of impact for every constraint given the current velocity.
        for (constraints) |*c| {
            c.projected_velocity = dot3(c.plane_normal, c.linear_velocity - velocity);
            if (c.projected_velocity < 1.0e-6) {
                c.toi = floatMax(f32);
            } else {
                const dist: f32 = cvPlaneSignedDistance(c.plane_normal, c.plane_constant, displacement);
                if (dist - c.projected_velocity * time_remaining > -1.0e-4) {
                    c.toi = floatMax(f32);
                } else {
                    c.toi = @max(0.0, dist / c.projected_velocity);
                }
            }
        }

        const sort_ctx: CvSortCtx = .{ .constraints = constraints, .contacts = contacts };
        std.mem.sort(usize, sorted, sort_ctx, cvConstraintLess);

        // Find the first constraint we will actually collide with.
        var chosen: ?usize = null;
        var reached_goal: bool = false;
        for (sorted) |idx| {
            const c: *CharConstraint = &constraints[idx];
            if (c.toi >= time_remaining) {
                displacement += velocity * splat(time_remaining);
                time_simulated += time_remaining;
                reached_goal = true;
                break;
            }
            if (contacts[c.contact].was_discarded) {
                continue;
            }
            if (!contacts[c.contact].had_collision) {
                const keep: bool = try cvHandleContact(world, char, gpa, velocity, c, contacts, dt);
                if (!keep) {
                    contacts[c.contact].was_discarded = true;
                    try ignored.append(scratch, .{
                        .body = contacts[c.contact].body,
                        .sub = contacts[c.contact].sub,
                    });
                    continue;
                }
            }
            if (!contacts[c.contact].can_push_character) {
                c.linear_velocity = vec_zero;
            }
            chosen = idx;
            break;
        }
        if (reached_goal) {
            return .{ .displacement = displacement, .time_simulated = time_simulated };
        }
        if (chosen == null) {
            displacement += velocity * splat(time_remaining);
            time_simulated += time_remaining;
            return .{ .displacement = displacement, .time_simulated = time_simulated };
        }

        const ci: usize = chosen.?;
        const constraint: *CharConstraint = &constraints[ci];

        // Move to the contact.
        displacement += velocity * splat(constraint.toi);
        time_remaining -= constraint.toi;
        time_simulated += constraint.toi;
        if (time_remaining < char.min_time_remaining) {
            return .{ .displacement = displacement, .time_simulated = time_simulated };
        }
        if (constraint.toi > 1.0e-4) {
            num_previous = 0;
        }

        const plane_normal: Vec = constraint.plane_normal;

        // Steep slope: first cancel velocity towards the slope so we don't briefly slide up it.
        if (constraint.is_steep_slope) {
            const pn_up: f32 = dot3(plane_normal, char.up);
            const vertical_plane_normal: Vec = plane_normal - char.up * splat(pn_up);
            const rel: Vec = velocity - constraint.linear_velocity;
            const into: f32 = @min(0.0, dot3(rel, vertical_plane_normal));
            velocity -= vertical_plane_normal * splat(into / lengthSq3(vertical_plane_normal));
        }

        // Cancel relative velocity in the plane normal direction (slide).
        const relative_velocity: Vec = velocity - constraint.linear_velocity;
        var new_velocity: Vec = velocity - plane_normal * splat(dot3(relative_velocity, plane_normal));

        // Find the previously-hit plane this new direction would violate the most, and cancel
        // ping-pong velocities between the two.
        var highest_penetration: f32 = 0.0;
        var other: ?usize = null;
        var par_idx: usize = 0;
        while (par_idx < num_previous) : (par_idx += 1) {
            const oc_idx: usize = previous[par_idx];
            if (oc_idx == ci) {
                continue;
            }
            const other_normal: Vec = constraints[oc_idx].plane_normal;
            const rel_other: Vec = constraints[oc_idx].linear_velocity - new_velocity;
            const penetration: f32 = dot3(rel_other, other_normal);
            if (penetration > highest_penetration) {
                const dot: f32 = dot3(other_normal, plane_normal);
                if (dot < 0.984 and dot > -0.984) {
                    highest_penetration = penetration;
                    other = oc_idx;
                }
            }
            // Cancel the constraint velocities in each other's plane to stop re-applying them.
            const a: f32 = @min(0.0, dot3(constraints[ci].linear_velocity, other_normal));
            constraints[ci].linear_velocity -= other_normal * splat(a);
            const b: f32 = @min(0.0, dot3(constraints[oc_idx].linear_velocity, plane_normal));
            constraints[oc_idx].linear_velocity -= plane_normal * splat(b);
        }

        // Two-plane crease: slide along the intersection of the two planes.
        if (other) |oc_idx| {
            const other_normal: Vec = constraints[oc_idx].plane_normal;
            const slide_dir: Vec = cvNorm(cross(plane_normal, other_normal), vec_zero);
            const velocity_in_slide_dir: Vec = slide_dir * splat(dot3(new_velocity, slide_dir));
            const cv: Vec = constraints[ci].linear_velocity;
            const perpendicular_velocity: Vec = cv - slide_dir * splat(dot3(cv, slide_dir));
            const ov: Vec = constraints[oc_idx].linear_velocity;
            const other_perpendicular_velocity: Vec = ov - slide_dir * splat(dot3(ov, slide_dir));
            new_velocity = velocity_in_slide_dir + perpendicular_velocity + other_perpendicular_velocity;
        }

        // Let the listener modify the calculated velocity for this contact.
        if (char.listener) |l| {
            if (l.on_contact_solve) |cb| {
                cb(l.context, char, &contacts[constraint.contact], velocity, &new_velocity);
            }
        }

        velocity = new_velocity;

        previous[num_previous] = ci;
        num_previous += 1;

        // Early outs.
        if (constraint.projected_velocity < 1.0e-8 and lengthSq3(velocity) < 1.0e-8) {
            return .{ .displacement = displacement, .time_simulated = time_simulated };
        }
        if (!(lengthSq3(constraint.linear_velocity) < 1.0e-16)) {
            last_velocity = constraint.linear_velocity;
        } else if (dot3(velocity, last_velocity) < 0.0) {
            return .{ .displacement = displacement, .time_simulated = time_simulated };
        }
    }
    return .{ .displacement = displacement, .time_simulated = time_simulated };
}

/// Jolt GetFirstContactForSweep: cast the character shape along `displacement` and return the
/// first contact (skipping `ignored` bodies), with the fraction pulled back by the character
/// padding. Uses our shapeCastCoresContact per candidate body (we omit Jolt's GJK face-inflation
/// padding correction and use its simple fraction pull-back fallback).
/// Sweep the character shape along `displacement` and return the first blocking hit.
///
/// Jolt has TWO functions here and the distinction is load-bearing:
///   * `ValidateMovement`  (MoveShape)              -> ContactCastCollector<true>
///   * `GetFirstContactForSweep` (StickToFloor,
///                                WalkStairs)       -> ContactCastCollector<false>
/// The template parameter is `IgnoreInitialOverlap`. For MOVEMENT it is true, so
/// hits at fraction 0 are discarded: the ground you are already resting on must
/// not clamp a horizontal step to nothing. For the stair/floor probes it is
/// false, because those sweeps EXIST to find the surface you are touching.
///
/// This port had collapsed both into one function with the movement semantics
/// missing, so a character walked normally in the air and froze solid the
/// instant it landed. `ignore_initial_overlap` restores the distinction.
fn cvGetFirstContactForSweep(
    world: *const World,
    char: *const CharacterVirtual,
    scratch: std.mem.Allocator,
    pos: Vec,
    displacement: Vec,
    ignored: []const CharContactKey,
    ignore_initial_overlap: bool,
) !?CharacterContact {
    const disp_len_sq: f32 = lengthSq3(displacement);
    if (disp_len_sq < 1.0e-8) {
        return null;
    }
    const shape: *const Shape = world.shapes.get(char.shape);
    const shape_pos: Vec = cvShapePos(char, pos);
    const self_radius: f32 = convexRadius(shape);

    const local_bounds: Aabb = shapeLocalBounds(shape);
    const start_bounds: Aabb = transformAabb(local_bounds, shape_pos, char.rotation);
    const end_bounds: Aabb = .{
        .min = start_bounds.min + displacement,
        .max = start_bounds.max + displacement,
    };
    const sweep_margin: f32 = char.character_padding + char.collision_tolerance;
    const swept: Aabb = start_bounds.combine(end_bounds).expandedBy(sweep_margin);

    var candidates: std.ArrayListUnmanaged(BodyIndex) = .empty;
    defer candidates.deinit(scratch);
    try world.broadphase.queryAabb(scratch, swept, &candidates);

    var best_fraction: f32 = 1.0;
    var best: ?CharacterContact = null;
    for (candidates.items) |bi| {
        const body: *const Body = &world.bodies.data[bi];
        if (!queryAllows(body, bi, char.filter)) {
            continue;
        }
        if (body.is_sensor) {
            continue; // sweeps never hit sensors (no OnContactAdded path)
        }
        const other: *const Shape = world.shapes.get(body.shape);
        const hit: CastContact = try castConvexVsShape(
            &world.shapes,
            shape,
            shape_pos,
            char.rotation,
            displacement,
            other,
            body.com_pos,
            body.rot,
            self_radius,
            world.settings.penetration_slop,
            char.back_face_mode,
            scratch,
        ) orelse continue;
        // Ignore the specific (body, sub-shape) contacts that conflicting-contact pruning or the
        // validate callback removed (body+sub, matching Jolt). If the earliest hit on a body is
        // an ignored sub we skip the whole body rather than probing the next sub — slightly
        // coarser than Jolt's per-sub collector, documented.
        var skip: bool = false;
        for (ignored) |k| {
            if (k.body == bi and k.sub == hit.sub) {
                skip = true;
                break;
            }
        }
        if (skip) {
            continue;
        }
        // Jolt ContactCastCollector::AddHit, in order.
        // (a) Ignore collisions at fraction 0 when this is a MOVEMENT sweep --
        //     that is the surface we are already standing on.
        if (ignore_initial_overlap and hit.fraction <= 0.0) {
            continue;
        }
        // (b) "Ignore penetrations that we're moving away from": Jolt tests
        //     `penetration_axis · displacement > 0`, and its contact normal is
        //     `-penetration_axis`, so the equivalent test on the normal is
        //     `normal · displacement < 0`. Jolt then also requires the approach
        //     to exceed the collision tolerance
        //     (`distance + normal·displacement < -collision_tolerance`); our cast
        //     does not report a penetration depth, so `distance` is 0 here and
        //     that check reduces to the tolerance-strengthened form below.
        //     Perpendicular contact cannot block, so this must be strict.
        if (dot3(hit.normal, displacement) >= -char.collision_tolerance) {
            continue;
        }
        if (hit.fraction < best_fraction) {
            best_fraction = hit.fraction;
            const bv: CvBodyVel = cvAdjustedBodyVelocity(world, char, bi);
            best = .{
                .contact_normal = hit.normal,
                .surface_normal = hit.normal,
                .position = hit.point,
                .linear_velocity = bv.lin + cross(bv.ang, hit.point - body.com_pos),
                .distance = 0.0,
                .fraction = hit.fraction,
                .body = bi,
                .sub = hit.sub,
                .motion_type = body.motion_type,
                .is_sensor = body.is_sensor,
                .user_data = body.user_data,
                .material = materialAt(world, bi, hit.sub),
            };
        }
    }

    if (best) |*c| {
        // Pull the fraction back so the character + padding stays off the surface.
        const character_padding_fraction: f32 = char.character_padding / @sqrt(disp_len_sq);
        c.fraction = @max(0.0, c.fraction - character_padding_fraction);
        if (c.fraction > 1.0) {
            c.fraction = 1.0;
        }
        return c.*;
    }
    return null;
}

/// Jolt MoveShape: slide the shape through the world. Each collision iteration gathers contacts,
/// removes conflicts, builds constraints, solves for a displacement, then sweeps to clamp that
/// displacement to the first real contact and advances time by the consumed fraction.
fn cvMoveShape(
    world: *World,
    char: *CharacterVirtual,
    gpa: std.mem.Allocator,
    pos: *Vec,
    in_velocity: Vec,
    dt: f32,
    store_active: bool,
    scratch: std.mem.Allocator,
) !void {
    var contacts: std.ArrayListUnmanaged(CharacterContact) = .empty;
    defer contacts.deinit(scratch);
    var ignored: std.ArrayListUnmanaged(CharContactKey) = .empty;
    defer ignored.deinit(scratch);
    var constraints: std.ArrayListUnmanaged(CharConstraint) = .empty;
    defer constraints.deinit(scratch);

    var time_remaining: f32 = dt;
    var iteration: u32 = 0;
    while (iteration < char.max_collision_iterations) : (iteration += 1) {
        if (time_remaining < char.min_time_remaining) {
            break;
        }
        try cvGetContactsAtPosition(world, char, pos.*, scratch, &contacts);

        ignored.clearRetainingCapacity();
        try cvRemoveConflictingContacts(char, scratch, &contacts, &ignored);

        constraints.clearRetainingCapacity();
        try cvDetermineConstraints(char, scratch, contacts.items, dt, &constraints);

        const solve: CvSolveResult = try cvSolveConstraints(
            world,
            char,
            gpa,
            in_velocity,
            dt,
            time_remaining,
            constraints.items,
            contacts.items,
            &ignored,
            scratch,
        );

        if (store_active) {
            char.active_contacts.clearRetainingCapacity();
            try char.active_contacts.appendSlice(gpa, contacts.items);
        }

        var displacement: Vec = solve.displacement;
        var time_simulated: f32 = solve.time_simulated;
        if (try cvGetFirstContactForSweep(world, char, scratch, pos.*, displacement, ignored.items, true)) |cast| {
            displacement *= splat(cast.fraction);
            time_simulated *= cast.fraction;
        }

        pos.* += displacement;
        time_remaining -= time_simulated;

        if (lengthSq3(displacement) < 1.0e-8) {
            break;
        }
    }
}
/// Jolt UpdateSupportingContact: classify what we are standing on from the active contacts.
/// Marks newly-touching contacts, applies the supporting-volume cull, averages the ground
/// normal/velocity, and decides OnGround / OnSteepGround / NotSupported / InAir — including the
/// wedged-between-steep-slopes case (a -up constraint solve that can't move counts as supported).
fn cvUpdateSupportingContact(
    world: *World,
    char: *CharacterVirtual,
    skip_contact_velocity_check: bool,
    scratch: std.mem.Allocator,
) !void {
    // Flag contacts as colliding if close enough and we're not moving away from them.
    for (char.active_contacts.items) |*c| {
        if (c.was_discarded or c.had_collision or c.distance >= char.collision_tolerance) {
            continue;
        }
        const rel_v: Vec = char.linear_velocity - c.linear_velocity;
        const approaching: bool =
            skip_contact_velocity_check or dot3(c.surface_normal, rel_v) <= 1.0e-4;
        if (!approaching) {
            continue;
        }
        if (cvValidateContact(char, c)) {
            c.had_collision = true;
        } else {
            c.was_discarded = true;
        }
    }

    const inv_rot: Quat = conjugate(char.rotation);

    var num_supported: i32 = 0;
    var num_sliding: i32 = 0;
    var num_avg_normal: i32 = 0;
    var avg_normal: Vec = vec_zero;
    var avg_velocity: Vec = vec_zero;
    var supporting_contact: ?usize = null;
    var max_cos_angle: f32 = -floatMax(f32);
    var deepest_contact: ?usize = null;
    var smallest_distance: f32 = floatMax(f32);

    for (char.active_contacts.items, 0..) |c, idx| {
        if (!c.had_collision or c.was_discarded) {
            continue;
        }
        const cos_angle: f32 = dot3(c.surface_normal, char.up);

        if (c.distance < smallest_distance) {
            deepest_contact = idx;
            smallest_distance = c.distance;
        }

        // Supporting-volume cull: contacts in front of the local plane cannot support us.
        const local_point: Vec = rotate(inv_rot, c.position - char.position);
        const sv_dist: f32 = cvPlaneSignedDistance(
            char.supporting_volume_normal,
            char.supporting_volume_constant,
            local_point,
        );
        if (sv_dist > 0.0) {
            continue;
        }

        if (max_cos_angle < cos_angle) {
            supporting_contact = idx;
            max_cos_angle = cos_angle;
        }

        const is_supported: bool =
            char.max_slope_cos > cv_no_max_slope_angle or cos_angle >= char.max_slope_cos;
        if (is_supported) {
            num_supported += 1;
        } else {
            num_sliding += 1;
        }

        if (cos_angle >= 0.08) {
            avg_normal += c.surface_normal;
            num_avg_normal += 1;
            if (c.motion_type != .kinematic or !is_supported) {
                avg_velocity += c.linear_velocity;
            } else {
                const gb: *const Body = &world.bodies.data[c.body];
                const bv: CvBodyVel = cvAdjustedBodyVelocity(world, char, c.body);
                avg_velocity += cvCharacterGroundVelocity(char, gb.com_pos, bv.lin, bv.ang, char.last_dt);
            }
        }
    }

    const best_contact: ?usize = if (supporting_contact != null) supporting_contact else deepest_contact;

    if (num_avg_normal >= 1) {
        const count_f: f32 = float(num_avg_normal);
        char.ground_normal = cvNorm(avg_normal, char.up);
        char.ground_velocity = avg_velocity / splat(count_f);
    } else if (best_contact) |bi| {
        char.ground_normal = char.active_contacts.items[bi].surface_normal;
        char.ground_velocity = char.active_contacts.items[bi].linear_velocity;
    } else {
        char.ground_normal = vec_zero;
        char.ground_velocity = vec_zero;
    }

    if (best_contact) |bi| {
        char.ground_body = char.active_contacts.items[bi].body;
        char.ground_position = char.active_contacts.items[bi].position;
        char.ground_material = char.active_contacts.items[bi].material;
    } else {
        char.ground_body = none_body;
        char.ground_position = vec_zero;
        char.ground_material = 0;
    }

    if (num_supported > 0) {
        char.ground_state = .on_ground;
    } else if (num_sliding > 0) {
        const deep: usize = deepest_contact.?;
        const deep_rel: Vec = char.linear_velocity - char.active_contacts.items[deep].linear_velocity;
        if (dot3(deep_rel, char.up) > 1.0e-4) {
            char.ground_state = .on_steep_ground; // moving up relative to the ground
        } else {
            // We may be wedged between sliding contacts so that we cannot slide off: solve a
            // straight-down move and if it barely moves, treat us as supported.
            var wedge_contacts: std.ArrayListUnmanaged(CharacterContact) = .empty;
            defer wedge_contacts.deinit(scratch);
            try wedge_contacts.appendSlice(scratch, char.active_contacts.items);
            var constraints: std.ArrayListUnmanaged(CharConstraint) = .empty;
            defer constraints.deinit(scratch);
            try cvDetermineConstraints(char, scratch, wedge_contacts.items, char.last_dt, &constraints);
            var ignored: std.ArrayListUnmanaged(CharContactKey) = .empty;
            defer ignored.deinit(scratch);
            const solve: CvSolveResult = try cvSolveConstraints(
                world,
                char,
                world.allocator,
                vec_zero - char.up,
                1.0,
                1.0,
                constraints.items,
                wedge_contacts.items,
                &ignored,
                scratch,
            );
            const min_required: f32 = (0.6 * char.last_dt) * (0.6 * char.last_dt);
            if (solve.time_simulated < 0.001 or lengthSq3(solve.displacement) < min_required) {
                char.ground_state = .on_ground;
            } else {
                char.ground_state = .on_steep_ground;
            }
        }
    } else {
        char.ground_state = if (best_contact != null) .not_supported else .in_air;
    }
}

/// Recompute ground_velocity from the current ground body (used after WalkStairs / StickToFloor).
fn cvUpdateGroundVelocity(world: *World, char: *CharacterVirtual) void {
    if (char.ground_body == none_body) {
        char.ground_velocity = vec_zero;
        return;
    }
    const gb: *const Body = &world.bodies.data[char.ground_body];
    const bv: CvBodyVel = cvAdjustedBodyVelocity(world, char, char.ground_body);
    char.ground_velocity = cvCharacterGroundVelocity(char, gb.com_pos, bv.lin, bv.ang, char.last_dt);
}

/// Jolt MoveToContact: place the character at `pos` and refresh its active contacts, ensuring the
/// given contact is marked as colliding.
fn cvMoveToContact(
    world: *World,
    char: *CharacterVirtual,
    pos: Vec,
    contact: CharacterContact,
    scratch: std.mem.Allocator,
) !void {
    char.position = pos;
    var contacts: std.ArrayListUnmanaged(CharacterContact) = .empty;
    defer contacts.deinit(scratch);
    try cvGetContactsAtPosition(world, char, pos, scratch, &contacts);

    var found: bool = false;
    for (contacts.items) |*c| {
        if (c.body == contact.body and c.sub == contact.sub) {
            c.had_collision = true;
            found = true;
        }
    }
    if (!found) {
        var copy: CharacterContact = contact;
        copy.had_collision = true;
        try contacts.append(scratch, copy);
    }

    char.active_contacts.clearRetainingCapacity();
    try char.active_contacts.appendSlice(world.allocator, contacts.items);
}

/// Fire on_contact_removed for contacts that collided last update but are gone now, and refresh
/// the persistent key set. (on_contact_added doubles as the settings fetch during the solve.)
fn cvFireContactEvents(
    char: *CharacterVirtual,
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
) !void {
    var current: std.ArrayListUnmanaged(CharContactKey) = .empty;
    defer current.deinit(scratch);
    for (char.active_contacts.items) |c| {
        if (!c.had_collision or c.was_discarded) {
            continue;
        }
        var seen: bool = false;
        for (current.items) |k| {
            if (k.body == c.body and k.sub == c.sub) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            try current.append(scratch, .{ .body = c.body, .sub = c.sub });
        }
    }

    if (char.listener) |l| {
        if (l.on_contact_removed) |cb| {
            for (char.contact_keys_prev.items) |pk| {
                var still: bool = false;
                for (current.items) |k| {
                    if (k.body == pk.body and k.sub == pk.sub) {
                        still = true;
                        break;
                    }
                }
                if (!still) {
                    cb(l.context, char, pk.body, pk.sub);
                }
            }
        }
    }

    char.contact_keys_prev.clearRetainingCapacity();
    try char.contact_keys_prev.appendSlice(gpa, current.items);
}

/// The core update shared by characterUpdate and characterExtendedUpdate: slide, classify the
/// ground, and load the ground with the character's weight. Does NOT fire contact events.
fn cvUpdateImpl(
    world: *World,
    char: *CharacterVirtual,
    dt: f32,
    gravity: Vec,
    scratch: std.mem.Allocator,
) !void {
    if (dt <= 0.0) {
        return;
    }
    char.last_dt = dt;

    var pos: Vec = char.position;
    try cvMoveShape(world, char, world.allocator, &pos, char.linear_velocity, dt, true, scratch);
    char.position = pos;

    try cvUpdateSupportingContact(world, char, false, scratch);

    // Add the character's weight as an impulse to the body we're standing on.
    if (char.ground_body != none_body and char.mass > 0.0) {
        const g_len: f32 = length3(gravity);
        if (g_len > 1.0e-9) {
            const ndotg: f32 = dot3(char.ground_normal, gravity);
            if (ndotg < 0.0) {
                const scale: f32 = -(char.mass * ndotg / g_len * dt);
                const world_impulse: Vec = gravity * splat(scale);
                try world.addImpulseAtPosition(
                    world.allocator,
                    char.ground_body,
                    world_impulse,
                    char.ground_position,
                );
            }
        }
    }
}

/// Advance the character by its velocity over `dt` with the full swept collide-and-slide solve,
/// then classify the ground and load it with the character's weight. `gravity` is only used for
/// that ground-loading impulse (the caller manages the character's own gravity in linear_velocity,
/// exactly like Jolt's CharacterVirtual::Update).
pub fn characterUpdate(
    world: *World,
    char: *CharacterVirtual,
    dt: f32,
    gravity: Vec,
    scratch: std.mem.Allocator,
) !void {
    try cvUpdateImpl(world, char, dt, gravity, scratch);
    try cvFireContactEvents(char, world.allocator, scratch);
}

/// Jolt CancelVelocityTowardsSteepSlopes: remove the components of `desired` that push into any
/// steep slope we are currently touching (so we don't creep up them). No-op when on_ground/in_air.
fn cvCancelVelocityTowardsSteepSlopes(char: *const CharacterVirtual, desired: Vec) Vec {
    if (char.ground_state == .on_ground or char.ground_state == .in_air) {
        return desired;
    }
    var result: Vec = desired;
    for (char.active_contacts.items) |c| {
        if (!c.had_collision or c.was_discarded or !cvSlopeTooSteep(char, c.surface_normal)) {
            continue;
        }
        var normal: Vec = c.contact_normal;
        normal -= char.up * splat(dot3(normal, char.up));
        const dotv: f32 = dot3(normal, result);
        if (dotv < 0.0) {
            result -= normal * splat(dotv / lengthSq3(normal));
        }
    }
    return result;
}

/// Jolt CanWalkStairs: we can attempt a stair walk only if supported, moving horizontally, and
/// pushing into a too-steep contact.
fn cvCanWalkStairs(char: *const CharacterVirtual, velocity: Vec) bool {
    if (!char.isSupported()) {
        return false;
    }
    const horizontal: Vec = velocity - char.up * splat(dot3(velocity, char.up));
    if (lengthSq3(horizontal) < 1.0e-12) {
        return false;
    }
    for (char.active_contacts.items) |c| {
        if (c.had_collision and !c.was_discarded and
            dot3(c.surface_normal, horizontal - c.linear_velocity) < 0.0 and
            cvSlopeTooSteep(char, c.surface_normal))
        {
            return true;
        }
    }
    return false;
}

/// Jolt StickToFloor: sweep straight down by `step_down`; if a floor is found, drop to it.
fn cvStickToFloor(
    world: *World,
    char: *CharacterVirtual,
    step_down: Vec,
    scratch: std.mem.Allocator,
) !bool {
    const ignored: [0]CharContactKey = .{};
    const maybe_floor: ?CharacterContact =
        try cvGetFirstContactForSweep(world, char, scratch, char.position, step_down, ignored[0..], false);
    const contact: CharacterContact = maybe_floor orelse return false;
    const new_position: Vec = char.position + step_down * splat(contact.fraction);
    try cvMoveToContact(world, char, new_position, contact, scratch);
    // Reflect the floor we stuck to in the ground state.
    char.ground_body = contact.body;
    char.ground_normal = contact.surface_normal;
    char.ground_position = contact.position;
    char.ground_velocity = contact.linear_velocity;
    char.ground_state = if (cvSlopeTooSteep(char, contact.surface_normal)) .on_steep_ground else .on_ground;
    cvUpdateGroundVelocity(world, char);
    return true;
}

/// Jolt WalkStairs: step up, move forward, drop back down, with the steep-edge second probe.
fn cvWalkStairs(
    world: *World,
    char: *CharacterVirtual,
    dt: f32,
    in_step_up: Vec,
    step_forward: Vec,
    step_forward_test: Vec,
    step_down_extra: Vec,
    scratch: std.mem.Allocator,
) !bool {
    const ignored: [0]CharContactKey = .{};

    // Move up.
    var up: Vec = in_step_up;
    if (try cvGetFirstContactForSweep(world, char, scratch, char.position, up, ignored[0..], false)) |contact| {
        if (contact.fraction < 1.0e-6) {
            return false;
        }
        up *= splat(contact.fraction);
    }
    const up_position: Vec = char.position + up;

    // Collect the steep-slope normals we'd like to walk up (before MoveShape rewrites contacts).
    const character_velocity: Vec = step_forward / splat(dt);
    const cv_up: f32 = dot3(character_velocity, char.up);
    const horizontal_velocity: Vec = character_velocity - char.up * splat(cv_up);
    var steep_normals: std.ArrayListUnmanaged(Vec) = .empty;
    defer steep_normals.deinit(scratch);
    for (char.active_contacts.items) |c| {
        if (c.had_collision and !c.was_discarded and
            dot3(c.surface_normal, horizontal_velocity - c.linear_velocity) < 0.0 and
            cvSlopeTooSteep(char, c.surface_normal))
        {
            try steep_normals.append(scratch, c.surface_normal);
        }
    }
    if (steep_normals.items.len == 0) {
        return false;
    }

    // Horizontal movement.
    var new_position: Vec = up_position;
    try cvMoveShape(world, char, world.allocator, &new_position, character_velocity, dt, false, scratch);
    const horizontal_movement: Vec = new_position - up_position;
    const horizontal_movement_sq: f32 = lengthSq3(horizontal_movement);
    if (horizontal_movement_sq < 1.0e-8) {
        return false;
    }

    // Require progress against a steep slope (else we just slid along it).
    var made_progress: bool = false;
    const max_dot: f32 = -0.05 * length3(step_forward);
    for (steep_normals.items) |normal| {
        if (dot3(normal, horizontal_movement) < max_dot) {
            made_progress = true;
            break;
        }
    }
    if (!made_progress) {
        return false;
    }

    // Move down to the floor.
    var down: Vec = (vec_zero - up) + step_down_extra;
    const maybe_down: ?CharacterContact =
        try cvGetFirstContactForSweep(world, char, scratch, new_position, down, ignored[0..], false);
    var contact: CharacterContact = maybe_down orelse return false;
    var too_steep: bool = cvSlopeTooSteep(char, contact.surface_normal);

    if (too_steep) {
        // Hit the edge of a step (normal reads too steep): probe further forward for a real tread.
        if (lengthSq3(step_forward_test) < 1.0e-12) {
            return false;
        }
        var test_position: Vec = up_position;
        try cvMoveShape(
            world,
            char,
            world.allocator,
            &test_position,
            step_forward_test / splat(dt),
            dt,
            false,
            scratch,
        );
        const test_horizontal_sq: f32 = lengthSq3(test_position - up_position);
        if (test_horizontal_sq <= horizontal_movement_sq + 1.0e-8) {
            return false;
        }
        const maybe_test: ?CharacterContact =
            try cvGetFirstContactForSweep(world, char, scratch, test_position, down, ignored[0..], false);
        const test_contact: CharacterContact = maybe_test orelse return false;
        too_steep = cvSlopeTooSteep(char, test_contact.surface_normal);
        if (too_steep) {
            return false;
        }
    }

    // Drop and commit.
    down *= splat(contact.fraction);
    new_position += down;
    contact.had_collision = true;
    try cvMoveToContact(world, char, new_position, contact, scratch);
    // The contact normal may read too steep at a step edge; the forward probe confirmed a walkable
    // tread, so force OnGround (Jolt does the same).
    char.ground_body = contact.body;
    char.ground_normal = contact.surface_normal;
    char.ground_position = contact.position;
    char.ground_state = .on_ground;
    cvUpdateGroundVelocity(world, char);
    return true;
}

/// Jolt ExtendedUpdate: cancel velocity into steep slopes, do the core update, then stick to the
/// floor over downward steps and walk up stairs that blocked horizontal progress.
pub fn characterExtendedUpdate(
    world: *World,
    char: *CharacterVirtual,
    dt: f32,
    gravity: Vec,
    settings: ExtendedUpdateSettings,
    scratch: std.mem.Allocator,
) !void {
    const desired_velocity: Vec = char.linear_velocity;
    char.linear_velocity = cvCancelVelocityTowardsSteepSlopes(char, desired_velocity);

    const old_position: Vec = char.position;
    var ground_to_air: bool = char.isSupported();

    try cvUpdateImpl(world, char, dt, gravity, scratch);

    if (char.isSupported()) {
        ground_to_air = false;
    }

    // Stick to floor.
    if (ground_to_air and lengthSq3(settings.stick_to_floor_step_down) > 1.0e-12) {
        const up_velocity: f32 = dot3(char.position - old_position, char.up) / dt;
        if (up_velocity <= 1.0e-6) {
            _ = try cvStickToFloor(world, char, settings.stick_to_floor_step_down, scratch);
        }
    }

    // Walk stairs.
    if (lengthSq3(settings.walk_stairs_step_up) > 1.0e-12) {
        var desired_horizontal_step: Vec = desired_velocity * splat(dt);
        desired_horizontal_step -= char.up * splat(dot3(desired_horizontal_step, char.up));
        const desired_len: f32 = length3(desired_horizontal_step);
        if (desired_len > 0.0) {
            var achieved: Vec = char.position - old_position;
            achieved -= char.up * splat(dot3(achieved, char.up));
            const forward_normalized: Vec = desired_horizontal_step / splat(desired_len);
            const along: f32 = @max(0.0, dot3(achieved, forward_normalized));
            const achieved_len: f32 = along; // achieved projected onto the forward direction

            if (achieved_len + 1.0e-4 < desired_len and cvCanWalkStairs(char, desired_velocity)) {
                // Pick the stair direction from the contact most OPPOSING the
                // movement, not from the averaged ground normal. Jolt scans the
                // active contacts for the steepest surface we are pushing into
                // and walks perpendicular to it, "so we can step up stairs if
                // we're moving at a big angle along the stairs" -- approaching a
                // step diagonally, the averaged normal points somewhere between
                // the step and the floor and aims the probe badly. The scan
                // falls back to the movement direction when nothing qualifies,
                // which is the case our averaged-normal version always took.
                var walk_dir: Vec = forward_normalized;
                var max_dot: f32 = settings.walk_stairs_cos_angle_forward_contact;
                for (char.active_contacts.items) |c| {
                    if (!c.had_collision or c.was_discarded) {
                        continue;
                    }
                    // Only contacts we are pushing INTO, and only steep ones.
                    if (dot3(c.surface_normal, desired_velocity - c.linear_velocity) >= 0.0) {
                        continue;
                    }
                    if (!cvSlopeTooSteep(char, c.surface_normal)) {
                        continue;
                    }
                    // Strip the vertical component and negate, so it points the
                    // way we are trying to travel.
                    var test_dir: Vec = char.up * splat(dot3(c.surface_normal, char.up)) - c.surface_normal;
                    const test_len: f32 = length3(test_dir);
                    if (test_len <= 1.0e-6) {
                        continue;
                    }
                    test_dir /= splat(test_len);
                    const d: f32 = dot3(test_dir, forward_normalized);
                    if (d > max_dot) {
                        walk_dir = test_dir;
                        max_dot = d;
                    }
                }

                const fwd_mag: f32 = @max(settings.walk_stairs_min_step_forward, desired_len - achieved_len);
                // Jolt uses the SAME chosen direction for the step and its probe.
                const step_forward: Vec = walk_dir * splat(fwd_mag);
                const step_forward_test: Vec = walk_dir * splat(settings.walk_stairs_step_forward_test);

                _ = try cvWalkStairs(
                    world,
                    char,
                    dt,
                    settings.walk_stairs_step_up,
                    step_forward,
                    step_forward_test,
                    settings.walk_stairs_step_down_extra,
                    scratch,
                );
            }
        }
    }

    try cvFireContactEvents(char, world.allocator, scratch);
}

// =============================================================================
// Character (simple): a real rigid body in the world (usually a capsule) plus ground-state
// detection on top. Unlike CharacterVirtual it is a normal body — the solver does the movement and
// collision response, and you drive it by setting its velocity. After each World.step, call
// characterPostSimulation to refresh the ground state from the surrounding contacts. (Jolt's
// Character / CharacterBase.) Deferred follow-up: SetShape with penetration check, and using the
// supporting volume for anything beyond the not-supported test.
// =============================================================================

/// A body-backed character controller. Create the backing body yourself (addBody with a capsule,
/// kinematic or dynamic), then wrap its index here. The ground_* fields are refreshed by
/// characterPostSimulation.
pub const Character = struct {
    body: BodyIndex, // the backing rigid body

    // Tuning.
    up: Vec = vec(0.0, 1.0, 0.0), // the character's up direction
    max_slope_cos: f32 = 0.642787, // cos(50°): steepest slope you can stand on (<= -2 accepts any)
    // Supporting volume plane in character-local space (Jolt's mSupportingVolume): a ground contact
    // whose position is on the +normal side of this plane is "not supported". The default plane
    // (up, very negative distance) supports everything.
    supporting_volume_normal: Vec = vec(0.0, 1.0, 0.0),
    supporting_volume_distance: f32 = -1.0e10,
    predictive_distance: f32 = 0.02, // gather contacts slightly beyond the shape
    filter: QueryFilter = .{}, // which bodies count as ground

    // Output, refreshed by characterPostSimulation.
    ground_state: GroundState = .in_air,
    ground_normal: Vec = vec(0.0, 1.0, 0.0),
    ground_body: BodyIndex = none_body,
    ground_position: Vec = vec_zero,
    ground_velocity: Vec = vec_zero,
};

/// Refresh the character's ground state after a simulation try step (Jolt's Character::PostSimulation).
/// Collides the character's shape against the surrounding world (excluding itself) and picks the
/// contact whose surface normal is most aligned with `up`; that decides on-ground / steep / not-
/// supported, and supplies the ground normal, body, position, and the ground's velocity at that
/// point. `max_separation_distance` lets contacts just below the feet still count as ground.
pub fn characterPostSimulation(
    world: *World,
    char: *Character,
    max_separation_distance: f32,
    scratch: std.mem.Allocator,
) !void {
    const body: *const Body = &world.bodies.data[char.body];
    const char_pos: Vec = body.com_pos;
    const char_rot: Quat = body.rot;
    const shape: *const Shape = world.shapes.get(body.shape);

    const margin: f32 = max_separation_distance + char.predictive_distance;
    const query_bounds: Aabb = transformAabb(shapeLocalBounds(shape), char_pos, char_rot).expandedBy(margin);

    var nearby: std.ArrayListUnmanaged(BodyIndex) = .empty;
    try world.broadphase.queryAabb(scratch, query_bounds, &nearby);
    var subs: std.ArrayListUnmanaged(SubCollision) = .empty;

    var best_dot: f32 = -2.0;
    var found: bool = false;
    var best_normal: Vec = char.up;
    var best_body: BodyIndex = none_body;
    var best_point: Vec = char_pos;

    for (nearby.items) |bi| {
        if (bi == char.body) {
            continue;
        } // never tread on ourselves
        const other: *const Body = &world.bodies.data[bi];
        if (!queryAllows(other, bi, char.filter)) {
            continue;
        }
        if (other.is_sensor) {
            continue;
        }

        const oshape: *const Shape = world.shapes.get(other.shape);
        subs.clearRetainingCapacity();
        try collideShapes(
            &world.shapes,
            shape,
            char_pos,
            char_rot,
            oshape,
            other.com_pos,
            other.rot,
            max_separation_distance,
            .collide_back_faces,
            &subs,
            scratch,
        );

        for (subs.items) |sc| {
            const m: Manifold = sc.manifold;
            if (m.count == 0) {
                continue;
            }
            // manifold normal is character(A) -> other(B); the surface the character rests against
            // faces -normal toward the character.
            const surface_normal: Vec = vec_zero - m.normal;
            const d: f32 = dot3(surface_normal, char.up);
            if (d > best_dot) {
                // deepest contact point on the other body (the ground)
                var deepest: f32 = -1.0e30;
                var point: Vec = char_pos;
                var k: u8 = 0;
                while (k < m.count) : (k += 1) {
                    const separation: f32 = dot3(
                        m.points[k].point_on_b - m.points[k].point_on_a,
                        m.normal,
                    );
                    const penetration: f32 = -separation;
                    if (penetration > deepest) {
                        deepest = penetration;
                        point = m.points[k].point_on_b;
                    }
                }
                best_dot = d;
                best_normal = surface_normal;
                best_body = bi;
                best_point = point;
                found = true;
            }
        }
    }

    if (!found) {
        char.ground_state = .in_air;
        char.ground_normal = char.up;
        char.ground_body = none_body;
        char.ground_velocity = vec_zero;
        return;
    }

    // Ground position in character-local space, tested against the supporting volume plane.
    const ground_local: Vec = rotate(conjugate(char_rot), best_point - char_pos);
    const sv_signed: f32 = dot3(char.supporting_volume_normal, ground_local) +
        char.supporting_volume_distance;
    if (sv_signed > 0.0) {
        char.ground_state = .not_supported;
    } else if (char.max_slope_cos > -2.0 and dot3(best_normal, char.up) < char.max_slope_cos) {
        char.ground_state = .on_steep_ground;
    } else {
        char.ground_state = .on_ground;
    }
    char.ground_normal = best_normal;
    char.ground_body = best_body;
    char.ground_position = best_point;
    char.ground_velocity = world.getPointVelocity(best_body, best_point);
}

/// Set the character body's horizontal/vertical velocity (waking it). Thin convenience over the
/// body velocity API; you can equally set `world.motion[char.body].lin_vel` yourself.
pub fn characterSetLinearVelocity(
    world: *World,
    gpa: std.mem.Allocator,
    char: *const Character,
    v: Vec,
) !void {
    try world.setLinearVelocity(gpa, handleOf(world, char.body), v);
}

/// Add an impulse to the character body (Jolt's Character::AddImpulse): Δv = impulse · invMass.
pub fn characterAddImpulse(
    world: *World,
    gpa: std.mem.Allocator,
    char: *const Character,
    impulse: Vec,
) !void {
    const m: *Motion = &world.motion[char.body];
    try world.wakeBody(gpa, char.body);
    m.lin_vel = (m.lin_vel + impulse * splat(m.inv_mass)) * m.lin_lock;
}

// =============================================================================
// Constraint solving (used by the step below). prepareConstraint runs once per step
// (and warm-starts); solveConstraintVelocity/Position run once per solver iteration.
// =============================================================================

/// Current signed translation of a slider constraint along its axis (Jolt's
/// SliderConstraint::GetCurrentPosition): the projection of the anchor offset onto the world
/// slide axis. Used by the rack-and-pinion constraint's position correction.
fn sliderCurrentPosition(world: *const World, s: *const Constraint) f32 {
    const ba: *const Body = &world.bodies.data[s.body_a];
    const bb: *const Body = &world.bodies.data[s.body_b];
    const r1: Vec = rotate(ba.rot, s.local_anchor_a);
    const r2: Vec = rotate(bb.rot, s.local_anchor_b);
    const u: Vec = (bb.com_pos + r2) - (ba.com_pos + r1);
    const axis: Vec = rotate(ba.rot, s.local_axis_a);
    return dot3(u, axis);
}

/// Current signed angle of a hinge constraint about its hinge axis (Jolt's
/// HingeConstraint::GetCurrentAngle): the relative rotation, taken into constraint space via the
/// hinge's stored initial rotation, measured about the world hinge axis set during the hinge's
/// own prepare this step. Used by the gear constraint's position correction.
fn hingeCurrentAngle(world: *const World, h: *const Constraint) f32 {
    const ba: *const Body = &world.bodies.data[h.body_a];
    const bb: *const Body = &world.bodies.data[h.body_b];
    const diff: Quat = qmul(conjugate(ba.rot), qmul(h.inv_initial_rotation, bb.rot));
    return quatAngleAbout(diff, h.world_axis);
}

/// Gear joint (Jolt's GearConstraint): meshes two bodies' rotations so that
/// w_a·axis_a + ratio·w_b·axis_b = 0. `local_axis_a`/`local_axis_b` are the rotation axes in each
/// body's local frame; `ratio` = teeth_b/teeth_a (use a negative ratio to counter-rotate).
/// `hinge_ref_a`/`hinge_ref_b` are the indices (in `world.constraints`) of the two hinge joints
/// the gears turn about — used only for slow position-drift correction; pass -1 for both to get
/// pure velocity coupling (Jolt's behaviour when the gear constraints aren't set).
//
// FIXED (2026-06): the velocity part was missing the `ratio` factor when applying the impulse to
// body B (Jolt applies `ratio * lambda * I2^-1 * a2`; we applied `lambda * I2^-1 * a2`). That made
// the velocity coupling inconsistent with its own jv/effective-mass (which DO include ratio), so
// with hinge_refs = -1 the spin didn't transfer at all, and with refs set the (over-worked) drift
// path went unstable. With the ratio factor restored, pure velocity coupling (refs -1) now both
// transfers correctly (|w_b| = |w_a|*r_a/r_b) AND is stable at dt = 1/60 (headless: a motored
// 3-gear chain holds 2.5 / -3.44 / 5.0 rad/s indefinitely). Use refs = -1 for gears.
// STILL OPEN: the optional drift-correction path (refs set) remains unstable when gears spin fast.
// Jolt's position formula (CenterAngleAroundZero(fmod(g1 + ratio*g2, 2pi))) is matched, so the
// suspect is `hingeCurrentAngle`: zimr measures a body-1-frame diff (conj(R1)*invInit*R2) against a
// WORLD axis, whereas Jolt's HingeConstraint::GetCurrentAngle measures a world-frame diff
// (R2*invInit*conj(R1)) about R1*localAxis. Reconcile that frame before enabling the drift path.
pub fn createGearJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    local_axis_a: Vec,
    local_axis_b: Vec,
    ratio: f32,
    hinge_ref_a: i32,
    hinge_ref_b: i32,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    try world.constraints.append(world.allocator, .{
        .kind = .gear,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = vec_zero,
        .local_anchor_b = vec_zero,
        .local_axis_a = safeNormalize3(local_axis_a, vec(1, 0, 0)),
        .local_axis_b = safeNormalize3(local_axis_b, vec(1, 0, 0)),
        .ratio = ratio,
        .gear_ref_a = hinge_ref_a,
        .gear_ref_b = hinge_ref_b,
    });
}

/// Rack-and-pinion joint (Jolt's RackAndPinionConstraint): couples body `a`'s rotation about
/// `local_hinge_axis` to body `b`'s translation along `local_slider_axis`, so the pinion turns as
/// the rack slides. `ratio` = 2π·teeth_rack / (rack_length·teeth_pinion). `pinion_hinge` and
/// `rack_slider` are the indices (in `world.constraints`) of the hinge and slider this couples,
/// used for slow position-drift correction; pass -1 for both to get pure velocity coupling.
pub fn createRackAndPinionJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    local_hinge_axis: Vec,
    local_slider_axis: Vec,
    ratio: f32,
    pinion_hinge: i32,
    rack_slider: i32,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    try world.constraints.append(world.allocator, .{
        .kind = .rack_and_pinion,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = vec_zero,
        .local_anchor_b = vec_zero,
        .local_axis_a = safeNormalize3(local_hinge_axis, vec(1, 0, 0)),
        .local_axis_b = safeNormalize3(local_slider_axis, vec(1, 0, 0)),
        .ratio = ratio,
        .gear_ref_a = pinion_hinge,
        .gear_ref_b = rack_slider,
    });
}

/// Pulley joint (Jolt's PulleyConstraint): a rope of fixed total length running from
/// `world_anchor_a` on body `a`, over the fixed world point `fixed_a`, to `fixed_b`, to
/// `world_anchor_b` on body `b`. The constrained length is |anchor_a − fixed_a| +
/// ratio·|anchor_b − fixed_b|, kept within [min_length, max_length]; pass a negative min/max to
/// default it to the length at creation (Jolt's behaviour). With min == max the rope is rigid.
pub fn createPulleyJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    world_anchor_a: Vec,
    fixed_a: Vec,
    world_anchor_b: Vec,
    fixed_b: Vec,
    ratio: f32,
    min_length: f32,
    max_length: f32,
) !void {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];
    const current_length: f32 = length3(world_anchor_a - fixed_a) +
        ratio * length3(world_anchor_b - fixed_b);
    try world.constraints.append(world.allocator, .{
        .kind = .pulley,
        .body_a = a,
        .body_b = b,
        .local_anchor_a = rotate(conjugate(body_a.rot), world_anchor_a - body_a.com_pos),
        .local_anchor_b = rotate(conjugate(body_b.rot), world_anchor_b - body_b.com_pos),
        .pulley_fixed_a = fixed_a,
        .pulley_fixed_b = fixed_b,
        .ratio = ratio,
        .min_distance = if (min_length < 0.0) current_length else min_length,
        .max_distance = if (max_length < 0.0) current_length else max_length,
    });
}

/// A 6-DOF joint does work this step only if at least one endpoint is an awake dynamic body.
fn sixDofActive(world: *const World, c: *const SixDofConstraint) bool {
    if (!c.enabled) {
        return false;
    }
    const a: *const Body = &world.bodies.data[c.body_a];
    const b: *const Body = &world.bodies.data[c.body_b];
    return (a.motion_type == .dynamic and !a.asleep) or (b.motion_type == .dynamic and !b.asleep);
}

/// Setup + warm-start for a SixDOF joint (Jolt's SetupVelocityConstraint + WarmStart).
fn prepareSixDof(
    world: *World,
    c: *SixDofConstraint,
    warm_ratio: f32,
    dt: f32,
) void {
    const body_a: *const Body = &world.bodies.data[c.body_a];
    const body_b: *const Body = &world.bodies.data[c.body_b];
    const ma: *Motion = &world.motion[c.body_a];
    const mb: *Motion = &world.motion[c.body_b];
    const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
    const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];
    const rotation1: Quat = body_a.rot;
    const rotation2: Quat = body_b.rot;

    const cb1_to_world: Quat = qmul(rotation1, c.constraint_to_body_a);
    c.translation_axis[0] = rotate(cb1_to_world, vec(1, 0, 0));
    c.translation_axis[1] = rotate(cb1_to_world, vec(0, 1, 0));
    c.translation_axis[2] = rotate(cb1_to_world, vec(0, 0, 1));

    // --- Translation ---
    if (c.isTranslationFullyConstrained()) {
        const r1: Vec = rotate(rotation1, c.local_pos_a);
        const r2: Vec = rotate(rotation2, c.local_pos_b);
        c.point_part.prepare(ma, inv_i_a, r1, mb, inv_i_b, r2);
    } else if (c.isTranslationConstrained() or c.translation_motor_active) {
        const p1: Vec = body_a.com_pos + rotate(rotation1, c.local_pos_a);
        const p2: Vec = body_b.com_pos + rotate(rotation2, c.local_pos_b);
        const r1_plus_u: Vec = p2 - body_a.com_pos;
        const r2: Vec = p2 - body_b.com_pos;
        const u: Vec = p2 - p1;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const axis: Vec = c.translation_axis[i];
            const d: f32 = dot3(axis, u);
            c.displacement[i] = d;
            // Limit.
            var constraint_active: bool = false;
            var constraint_value: f32 = 0.0;
            if (c.isFixedAxis(i)) {
                constraint_value = d - c.limit_min[i];
                constraint_active = true;
            } else if (!c.isFreeAxis(i)) {
                if (d <= c.limit_min[i]) {
                    constraint_value = d - c.limit_min[i];
                    constraint_active = true;
                } else if (d >= c.limit_max[i]) {
                    constraint_value = d - c.limit_max[i];
                    constraint_active = true;
                }
            }
            if (constraint_active) {
                // freq 0 => rigid limit (c ignored in the velocity bias, fixed in the position pass).
                c.translation_part[i].prepareSpring(
                    ma,
                    inv_i_a,
                    r1_plus_u,
                    mb,
                    inv_i_b,
                    r2,
                    axis,
                    0.0,
                    constraint_value,
                    c.limit_freq[i],
                    c.limit_damping[i],
                    dt,
                );
            } else {
                c.translation_part[i].deactivate();
            }
            // Motor.
            switch (c.motor_state[i]) {
                .off => {
                    if (c.hasFriction(i)) {
                        c.motor_translation_part[i].prepare(
                            ma,
                            inv_i_a,
                            r1_plus_u,
                            mb,
                            inv_i_b,
                            r2,
                            axis,
                            0.0,
                        );
                    } else {
                        c.motor_translation_part[i].deactivate();
                    }
                },
                .velocity => {
                    c.motor_translation_part[i].prepare(
                        ma,
                        inv_i_a,
                        r1_plus_u,
                        mb,
                        inv_i_b,
                        r2,
                        axis,
                        -vlane(c.target_velocity, i),
                    );
                },
                .position => {
                    if (vlane(c.motor_freq, i) > 0.0) {
                        c.motor_translation_part[i].prepareSpring(
                            ma,
                            inv_i_a,
                            r1_plus_u,
                            mb,
                            inv_i_b,
                            r2,
                            axis,
                            0.0,
                            d - vlane(c.target_position, i),
                            vlane(c.motor_freq, i),
                            vlane(c.motor_damping, i),
                            dt,
                        );
                    } else {
                        c.motor_translation_part[i].deactivate();
                    }
                },
                .position_and_velocity => {
                    if (vlane(c.motor_freq, i) > 0.0 or vlane(c.motor_damping, i) > 0.0) {
                        c.motor_translation_part[i].prepareSpring(
                            ma,
                            inv_i_a,
                            r1_plus_u,
                            mb,
                            inv_i_b,
                            r2,
                            axis,
                            -vlane(c.target_velocity, i),
                            d - vlane(c.target_position, i),
                            vlane(c.motor_freq, i),
                            vlane(c.motor_damping, i),
                            dt,
                        );
                    } else {
                        c.motor_translation_part[i].deactivate();
                    }
                },
            }
        }
    }

    // --- Rotation ---
    if (c.isRotationFullyConstrained()) {
        c.rotation_lock.prepare(inv_i_a, inv_i_b);
    } else if (c.isRotationConstrained() or c.rotation_motor_active) {
        const cb2_to_world: Quat = qmul(rotation2, c.constraint_to_body_b);
        const q: Quat = qmul(conjugate(cb1_to_world), cb2_to_world);
        if (c.isRotationConstrained()) {
            c.swing_twist.swing_type = c.swing_type;
            c.swing_twist.setLimits(
                c.limit_min[3],
                c.limit_max[3],
                c.limit_min[4],
                c.limit_max[4],
                c.limit_min[5],
                c.limit_max[5],
            );
            c.swing_twist.calculateConstraintProperties(inv_i_a, inv_i_b, q, cb1_to_world);
        } else {
            c.swing_twist.deactivate();
        }
        if (c.rotation_motor_active) {
            c.rotation_axis[0] = rotate(cb2_to_world, vec(1, 0, 0));
            c.rotation_axis[1] = rotate(cb2_to_world, vec(0, 1, 0));
            c.rotation_axis[2] = rotate(cb2_to_world, vec(0, 0, 1));
            // Target orientation along the shortest path.
            const target_orientation: Quat = if (dot4(q, c.target_orientation) > 0.0)
                c.target_orientation
            else
                vec_zero - c.target_orientation;
            const diff: Quat = qmul(target_orientation, conjugate(q));
            // Project diff onto the axes that have a position motor (Jolt's switch on the mask).
            var projected_diff: Quat = diff;
            switch (c.rotation_position_motor_active) {
                0b001 => projected_diff = quatGetTwist(diff, vec(1, 0, 0)),
                0b010 => projected_diff = quatGetTwist(diff, vec(0, 1, 0)),
                0b100 => projected_diff = quatGetTwist(diff, vec(0, 0, 1)),
                0b011 => projected_diff = qmul(conjugate(quatGetTwist(diff, vec(0, 0, 1))), diff),
                0b101 => projected_diff = qmul(conjugate(quatGetTwist(diff, vec(0, 1, 0))), diff),
                0b110 => projected_diff = qmul(conjugate(quatGetTwist(diff, vec(1, 0, 0))), diff),
                else => projected_diff = diff, // 0b000 (unused) / 0b111
            }
            // Small-angle rotation error: 2 * imaginary part (negated).
            const rotation_error: Vec = splat(-2.0) * projected_diff;
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                const axis: Vec = c.rotation_axis[i];
                switch (c.motor_state[3 + i]) {
                    .off => {
                        if (c.hasFriction(3 + i)) {
                            c.motor_rotation_part[i].prepare(inv_i_a, inv_i_b, axis, 0.0);
                        } else {
                            c.motor_rotation_part[i].deactivate();
                        }
                    },
                    .velocity => {
                        c.motor_rotation_part[i].prepare(
                            inv_i_a,
                            inv_i_b,
                            axis,
                            -vlane(c.target_angular_velocity, i),
                        );
                    },
                    .position => {
                        if (c.motor_freq[3 + i] > 0.0) {
                            c.motor_rotation_part[i].prepareSpring(
                                inv_i_a,
                                inv_i_b,
                                axis,
                                0.0,
                                vlane(rotation_error, i),
                                c.motor_freq[3 + i],
                                c.motor_damping[3 + i],
                                dt,
                            );
                        } else {
                            c.motor_rotation_part[i].deactivate();
                        }
                    },
                    .position_and_velocity => {
                        if (c.motor_freq[3 + i] > 0.0 or c.motor_damping[3 + i] > 0.0) {
                            c.motor_rotation_part[i].prepareSpring(
                                inv_i_a,
                                inv_i_b,
                                axis,
                                -vlane(c.target_angular_velocity, i),
                                vlane(rotation_error, i),
                                c.motor_freq[3 + i],
                                c.motor_damping[3 + i],
                                dt,
                            );
                        } else {
                            c.motor_rotation_part[i].deactivate();
                        }
                    },
                }
            }
        }
    }

    // --- Warm start (Jolt order: translation motors, rotation motors, rotation, translation) ---
    if (c.translation_motor_active) {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (c.motor_translation_part[i].isActive()) {
                c.motor_translation_part[i].warmStart(ma, mb, c.translation_axis[i], warm_ratio);
            }
        }
    }
    if (c.rotation_motor_active) {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (c.motor_rotation_part[i].isActive()) {
                c.motor_rotation_part[i].warmStart(ma, mb, warm_ratio);
            }
        }
    }
    if (c.isRotationFullyConstrained()) {
        c.rotation_lock.warmStart(ma, mb, warm_ratio);
    } else if (c.isRotationConstrained()) {
        c.swing_twist.warmStart(ma, mb, warm_ratio);
    }
    if (c.isTranslationFullyConstrained()) {
        c.point_part.warmStart(ma, mb, warm_ratio);
    } else if (c.isTranslationConstrained()) {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (c.translation_part[i].isActive()) {
                c.translation_part[i].warmStart(ma, mb, c.translation_axis[i], warm_ratio);
            }
        }
    }
}

/// One velocity iteration for a SixDOF joint (Jolt's SolveVelocityConstraint).
fn solveSixDofVelocity(world: *World, c: *SixDofConstraint, dt: f32) void {
    const ma: *Motion = &world.motion[c.body_a];
    const mb: *Motion = &world.motion[c.body_b];

    // Translation motors.
    if (c.translation_motor_active) {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (!c.motor_translation_part[i].isActive()) {
                continue;
            }
            if (c.motor_state[i] == .off) {
                const max_lambda: f32 = c.max_friction[i] * dt;
                c.motor_translation_part[i].solveVelocityClamped(
                    ma,
                    mb,
                    c.translation_axis[i],
                    -max_lambda,
                    max_lambda,
                );
            } else {
                c.motor_translation_part[i].solveVelocityClamped(
                    ma,
                    mb,
                    c.translation_axis[i],
                    dt * c.motor_min[i],
                    dt * c.motor_max[i],
                );
            }
        }
    }

    // Rotation motors.
    if (c.rotation_motor_active) {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (!c.motor_rotation_part[i].isActive()) {
                continue;
            }
            if (c.motor_state[3 + i] == .off) {
                const max_lambda: f32 = c.max_friction[3 + i] * dt;
                c.motor_rotation_part[i].solveVelocity(ma, mb, c.rotation_axis[i], -max_lambda, max_lambda);
            } else {
                c.motor_rotation_part[i].solveVelocity(
                    ma,
                    mb,
                    c.rotation_axis[i],
                    dt * c.motor_min[3 + i],
                    dt * c.motor_max[3 + i],
                );
            }
        }
    }

    // Rotation constraint.
    if (c.isRotationFullyConstrained()) {
        c.rotation_lock.solveVelocity(ma, mb);
    } else if (c.isRotationConstrained()) {
        c.swing_twist.solveVelocity(ma, mb);
    }

    // Translation constraint.
    if (c.isTranslationFullyConstrained()) {
        c.point_part.solveVelocity(ma, mb);
    } else if (c.isTranslationConstrained()) {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (!c.translation_part[i].isActive()) {
                continue;
            }
            // A limited (not fixed) axis is one-sided depending on which bound it hit.
            var limit_min: f32 = -floatMax(f32);
            var limit_max: f32 = floatMax(f32);
            if (!c.isFixedAxis(i)) {
                if (c.displacement[i] <= c.limit_min[i]) {
                    limit_min = 0.0;
                } else if (c.displacement[i] >= c.limit_max[i]) {
                    limit_max = 0.0;
                }
            }
            c.translation_part[i].solveVelocityClamped(ma, mb, c.translation_axis[i], limit_min, limit_max);
        }
    }
}

/// One position iteration for a SixDOF joint (Jolt's SolvePositionConstraint).
fn solveSixDofPosition(world: *World, c: *SixDofConstraint, baumgarte: f32) void {
    const body_a: *Body = &world.bodies.data[c.body_a];
    const body_b: *Body = &world.bodies.data[c.body_b];
    const ma: *const Motion = &world.motion[c.body_a];
    const mb: *const Motion = &world.motion[c.body_b];
    const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
    const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];

    // Rotation.
    if (c.isRotationFullyConstrained()) {
        // inv_initial = c2 * (c1 * eulerMin)^-1 (Jolt), so the locked rotation targets limit_min.
        const constraint_to_body1: Quat = qmul(
            c.constraint_to_body_a,
            quatFromEulerXYZ(vec(c.limit_min[3], c.limit_min[4], c.limit_min[5])),
        );
        const inv_initial_orientation: Quat = qmul(c.constraint_to_body_b, conjugate(constraint_to_body1));
        c.rotation_lock.prepare(inv_i_a, inv_i_b);
        c.rotation_lock.solvePosition(body_a, body_b, inv_initial_orientation, baumgarte);
    } else if (c.isRotationConstrained()) {
        const cb1: Quat = qmul(body_a.rot, c.constraint_to_body_a);
        const cb2: Quat = qmul(body_b.rot, c.constraint_to_body_b);
        const q: Quat = qmul(conjugate(cb1), cb2);
        c.swing_twist.solvePosition(
            body_a,
            body_b,
            inv_i_a,
            inv_i_b,
            q,
            c.constraint_to_body_a,
            c.constraint_to_body_b,
            baumgarte,
        );
    }

    // Translation.
    if (c.isTranslationFullyConstrained()) {
        const limit_min_vec: Vec = vec(c.limit_min[0], c.limit_min[1], c.limit_min[2]);
        const local_space_position1: Vec = c.local_pos_a + rotate(c.constraint_to_body_a, limit_min_vec);
        const r1: Vec = rotate(body_a.rot, local_space_position1);
        const r2: Vec = rotate(body_b.rot, c.local_pos_b);
        c.point_part.prepare(ma, inv_i_a, r1, mb, inv_i_b, r2);
        c.point_part.solvePosition(body_a, ma, body_b, mb, baumgarte);
    } else if (c.isTranslationConstrained()) {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (c.limit_freq[i] > 0.0) {
                continue;
            } // soft limits are not position-corrected
            const p1: Vec = body_a.com_pos + rotate(body_a.rot, c.local_pos_a);
            const p2: Vec = body_b.com_pos + rotate(body_b.rot, c.local_pos_b);
            const r1_plus_u: Vec = p2 - body_a.com_pos;
            const r2: Vec = p2 - body_b.com_pos;
            const u: Vec = p2 - p1;
            const cb1: Quat = qmul(body_a.rot, c.constraint_to_body_a);
            const axis: Vec = switch (i) {
                0 => rotate(cb1, vec(1, 0, 0)),
                1 => rotate(cb1, vec(0, 1, 0)),
                else => rotate(cb1, vec(0, 0, 1)),
            };
            var err: f32 = 0.0;
            if (c.isFixedAxis(i)) {
                err = dot3(u, axis) - c.limit_min[i];
            } else if (!c.isFreeAxis(i)) {
                const displacement: f32 = dot3(u, axis);
                if (displacement <= c.limit_min[i]) {
                    err = displacement - c.limit_min[i];
                } else if (displacement >= c.limit_max[i]) {
                    err = displacement - c.limit_max[i];
                }
            }
            if (err != 0.0) {
                c.translation_part[i].prepare(ma, inv_i_a, r1_plus_u, mb, inv_i_b, r2, axis, 0.0);
                c.translation_part[i].solvePosition(body_a, ma, body_b, mb, axis, err, baumgarte);
            }
        }
    }
}

/// Add a fully-configurable 6-DOF joint between two bodies. `pivot` is the common world-space
/// joint position; `axis_x`/`axis_y` define the constraint frame (world space; z = x×y). The six
/// limit pairs are translation X/Y/Z (metres) then rotation X/Y/Z (radians); for each axis,
/// min > max = fixed, a full range (±FLT_MAX / ±pi) = free, otherwise limited. Returns the index
/// of the new joint in world.six_dof (for later motor/target updates).
pub fn createSixDofJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    pivot: Vec,
    axis_x: Vec,
    axis_y: Vec,
    limit_min: [6]f32,
    limit_max: [6]f32,
) !usize {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];
    // Constraint frame -> body local frames.
    const ax: Vec = safeNormalize3(axis_x, vec(1, 0, 0));
    const ay: Vec = safeNormalize3(axis_y, vec(0, 1, 0));
    const az: Vec = cross(ax, ay);
    const c_to_world: Quat = quatFromBasis(ax, ay, az);
    var c: SixDofConstraint = .{
        .body_a = a,
        .body_b = b,
        .local_pos_a = rotate(conjugate(body_a.rot), pivot - body_a.com_pos),
        .local_pos_b = rotate(conjugate(body_b.rot), pivot - body_b.com_pos),
        .constraint_to_body_a = qmul(conjugate(body_a.rot), c_to_world),
        .constraint_to_body_b = qmul(conjugate(body_b.rot), c_to_world),
        .limit_min = limit_min,
        .limit_max = limit_max,
    };
    c.updateFixedFreeAxis();
    c.cacheMotorActive();
    try world.six_dof.append(world.allocator, c);
    return world.six_dof.items.len - 1;
}

/// A path joint does work this step only if at least one endpoint is an awake dynamic body.
fn pathConstraintActive(world: *const World, c: *const PathConstraint) bool {
    if (!c.enabled) {
        return false;
    }
    const a: *const Body = &world.bodies.data[c.body_a];
    const b: *const Body = &world.bodies.data[c.body_b];
    return (a.motion_type == .dynamic and !a.asleep) or (b.motion_type == .dynamic and !b.asleep);
}

/// Recompute the closest path point, the world-space frame, the arms, and every active part (Jolt's
/// CalculateConstraintProperties). Called from both the prepare and the position-solve phases.
fn calcPathProperties(world: *World, c: *PathConstraint, dt: f32) void {
    const body_a: *const Body = &world.bodies.data[c.body_a];
    const body_b: *const Body = &world.bodies.data[c.body_b];
    const ma: *const Motion = &world.motion[c.body_a];
    const mb: *const Motion = &world.motion[c.body_b];
    const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
    const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];

    const path_to_world_1_rot: Quat = qmul(c.path_to_body_a, body_a.rot);
    const path_to_world_2_rot: Quat = qmul(c.path_to_body_b, body_b.rot);
    const path_origin_ws: Vec = body_a.com_pos + rotate(body_a.rot, c.path_pos_a);
    const position2_ws: Vec = body_b.com_pos + rotate(body_b.rot, c.path_pos_b);

    const position2_local: Vec = rotate(conjugate(path_to_world_1_rot), position2_ws - path_origin_ws);
    c.path_fraction = c.path.closestPoint(position2_local, c.path_fraction);
    const frame: PathFrame = c.path.pointOnPath(c.path_fraction);
    const path_point_ws: Vec = path_origin_ws + rotate(path_to_world_1_rot, frame.position);

    c.r1 = path_point_ws - body_a.com_pos;
    c.r2 = position2_ws - body_b.com_pos;
    c.u = position2_ws - path_point_ws;
    c.path_normal = rotate(path_to_world_1_rot, frame.normal);
    c.path_binormal = rotate(path_to_world_1_rot, frame.binormal);
    c.path_tangent = rotate(path_to_world_1_rot, frame.tangent);

    c.position_part.prepare(ma, inv_i_a, c.r1 + c.u, mb, inv_i_b, c.r2, c.path_normal, c.path_binormal);

    if (!c.path.looping and (c.path_fraction <= 0.0 or c.path_fraction >= c.path.maxFraction())) {
        c.position_limits_part.prepare(ma, inv_i_a, c.r1 + c.u, mb, inv_i_b, c.r2, c.path_tangent, 0.0);
    } else {
        c.position_limits_part.deactivate();
    }

    switch (c.rotation_type) {
        .free => {},
        .constrain_around_tangent => c.hinge_part.prepare(
            inv_i_a,
            c.path_tangent,
            inv_i_b,
            rotate(path_to_world_2_rot, vec(1, 0, 0)),
        ),
        .constrain_around_normal => c.hinge_part.prepare(
            inv_i_a,
            c.path_normal,
            inv_i_b,
            rotate(path_to_world_2_rot, vec(0, 0, 1)),
        ),
        .constrain_around_binormal => c.hinge_part.prepare(
            inv_i_a,
            c.path_binormal,
            inv_i_b,
            rotate(path_to_world_2_rot, vec(0, 1, 0)),
        ),
        .constrain_to_path => {
            // q_inv = pathToBody2 * (pathToBody1 * basis(tangent, binormal, normal))^-1
            const frame_quat: Quat = quatFromBasis(frame.tangent, frame.binormal, frame.normal);
            const path_a_frame: Quat = qmul(frame_quat, c.path_to_body_a);
            c.inv_initial_orientation = qmul(conjugate(path_a_frame), c.path_to_body_b);
            c.rotation_part.prepare(inv_i_a, inv_i_b);
        },
        .fully_constrained => c.rotation_part.prepare(inv_i_a, inv_i_b),
    }

    // Motor along the tangent.
    switch (c.motor_state) {
        .off => {
            if (c.max_friction_force > 0.0) {
                c.position_motor_part.prepare(
                    ma,
                    inv_i_a,
                    c.r1 + c.u,
                    mb,
                    inv_i_b,
                    c.r2,
                    c.path_tangent,
                    0.0,
                );
            } else {
                c.position_motor_part.deactivate();
            }
        },
        .velocity => c.position_motor_part.prepare(
            ma,
            inv_i_a,
            c.r1 + c.u,
            mb,
            inv_i_b,
            c.r2,
            c.path_tangent,
            -c.target_velocity,
        ),
        .position => {
            if (c.motor_freq > 0.0) {
                c.position_motor_part.prepareSpring(
                    ma,
                    inv_i_a,
                    c.r1 + c.u,
                    mb,
                    inv_i_b,
                    c.r2,
                    c.path_tangent,
                    0.0,
                    c.constraintValue(),
                    c.motor_freq,
                    c.motor_damping,
                    dt,
                );
            } else {
                c.position_motor_part.deactivate();
            }
        },
        .position_and_velocity => {
            if (c.motor_freq > 0.0 or c.motor_damping > 0.0) {
                c.position_motor_part.prepareSpring(
                    ma,
                    inv_i_a,
                    c.r1 + c.u,
                    mb,
                    inv_i_b,
                    c.r2,
                    c.path_tangent,
                    -c.target_velocity,
                    c.constraintValue(),
                    c.motor_freq,
                    c.motor_damping,
                    dt,
                );
            } else {
                c.position_motor_part.deactivate();
            }
        },
    }
}

/// Setup + warm-start for a path joint (Jolt's SetupVelocityConstraint + WarmStart).
fn preparePath(
    world: *World,
    c: *PathConstraint,
    warm_ratio: f32,
    dt: f32,
) void {
    calcPathProperties(world, c, dt);
    const ma: *Motion = &world.motion[c.body_a];
    const mb: *Motion = &world.motion[c.body_b];
    if (c.position_motor_part.isActive()) {
        c.position_motor_part.warmStart(ma, mb, c.path_tangent, warm_ratio);
    }
    c.position_part.warmStart(ma, mb, c.path_normal, c.path_binormal, warm_ratio);
    if (c.position_limits_part.isActive()) {
        c.position_limits_part.warmStart(ma, mb, c.path_tangent, warm_ratio);
    }
    switch (c.rotation_type) {
        .free => {},
        .constrain_around_tangent,
        .constrain_around_normal,
        .constrain_around_binormal,
        => c.hinge_part.warmStart(
            ma,
            mb,
            warm_ratio,
        ),
        .constrain_to_path, .fully_constrained => c.rotation_part.warmStart(ma, mb, warm_ratio),
    }
}

/// One velocity iteration for a path joint (Jolt's SolveVelocityConstraint).
fn solvePathVelocity(world: *World, c: *PathConstraint, dt: f32) void {
    const ma: *Motion = &world.motion[c.body_a];
    const mb: *Motion = &world.motion[c.body_b];

    if (c.position_motor_part.isActive()) {
        if (c.motor_state == .off) {
            const max_lambda: f32 = c.max_friction_force * dt;
            c.position_motor_part.solveVelocityClamped(ma, mb, c.path_tangent, -max_lambda, max_lambda);
        } else {
            c.position_motor_part.solveVelocityClamped(
                ma,
                mb,
                c.path_tangent,
                dt * c.motor_min,
                dt * c.motor_max,
            );
        }
    }

    c.position_part.solveVelocity(ma, mb, c.path_normal, c.path_binormal);

    if (c.position_limits_part.isActive()) {
        // One-sided depending on which end of the path we hit.
        if (c.path_fraction <= 0.0) {
            c.position_limits_part.solveVelocityClamped(ma, mb, c.path_tangent, 0.0, floatMax(f32));
        } else {
            c.position_limits_part.solveVelocityClamped(ma, mb, c.path_tangent, -floatMax(f32), 0.0);
        }
    }

    switch (c.rotation_type) {
        .free => {},
        .constrain_around_tangent,
        .constrain_around_normal,
        .constrain_around_binormal,
        => c.hinge_part.solveVelocity(
            ma,
            mb,
        ),
        .constrain_to_path, .fully_constrained => c.rotation_part.solveVelocity(ma, mb),
    }
}

/// One position iteration for a path joint (Jolt's SolvePositionConstraint): re-derive the path
/// properties from the updated pose, then correct position, end limits, and rotation.
fn solvePathPosition(world: *World, c: *PathConstraint, baumgarte: f32) void {
    calcPathProperties(world, c, 0.0);
    const body_a: *Body = &world.bodies.data[c.body_a];
    const body_b: *Body = &world.bodies.data[c.body_b];
    const ma: *const Motion = &world.motion[c.body_a];
    const mb: *const Motion = &world.motion[c.body_b];

    c.position_part.solvePosition(body_a, ma, body_b, mb, c.u, c.path_normal, c.path_binormal, baumgarte);

    if (c.position_limits_part.isActive()) {
        c.position_limits_part.solvePosition(
            body_a,
            ma,
            body_b,
            mb,
            c.path_tangent,
            dot3(c.u, c.path_tangent),
            baumgarte,
        );
    }

    switch (c.rotation_type) {
        .free => {},
        .constrain_around_tangent,
        .constrain_around_normal,
        .constrain_around_binormal,
        => c.hinge_part.solvePosition(
            body_a,
            body_b,
            baumgarte,
        ),
        .constrain_to_path, .fully_constrained => c.rotation_part.solvePosition(
            body_a,
            body_b,
            c.inv_initial_orientation,
            baumgarte,
        ),
    }
}

/// Add a path joint. `points` are the Hermite control points in world space (they are copied into a
/// new allocation owned by the joint); `looping` closes the path. `world_path_origin` /
/// `world_path_rotation` place the path frame in the world at creation; `initial_fraction` is the
/// starting position along the path; `rotation_type` selects how body 2's orientation is
/// constrained. Returns the joint's index in world.paths (for later motor/target updates).
/// World-space point on a path constraint's curve at normalized t in [0,1] (t*maxFraction),
/// for drawing the rail as a polyline. Body 1 carries the path frame.
pub fn pathWorldPoint(world: *const World, path_index: usize, t: f32) Vec {
    const c: *const PathConstraint = &world.paths.items[path_index];
    const body_a: *const Body = &world.bodies.data[c.body_a];
    const frame: PathFrame = c.path.pointOnPath(t * c.path.maxFraction());
    const path_to_world_rot: Quat = qmul(c.path_to_body_a, body_a.rot);
    const path_origin_ws: Vec = body_a.com_pos + rotate(body_a.rot, c.path_pos_a);
    return path_origin_ws + rotate(path_to_world_rot, frame.position);
}

/// Number of path constraints currently in the world (for the demo overlay).
pub fn pathCount(world: *const World) usize {
    return world.paths.items.len;
}

pub fn createPathJoint(
    world: *World,
    handle_a: BodyHandle,
    handle_b: BodyHandle,
    points: []const HermitePoint,
    looping: bool,
    world_path_origin: Vec,
    world_path_rotation: Quat,
    initial_fraction: f32,
    rotation_type: PathRotationType,
) !usize {
    const a: BodyIndex = handle_a.index();
    const b: BodyIndex = handle_b.index();
    const body_a: *const Body = &world.bodies.data[a];
    const body_b: *const Body = &world.bodies.data[b];

    const owned: []HermitePoint = try world.allocator.alloc(HermitePoint, points.len);
    @memcpy(owned, points);
    const path: HermitePath = .{ .points = owned, .looping = looping };

    // Body 1 carries the path frame.
    const path_to_body_a: Quat = qmul(world_path_rotation, conjugate(body_a.rot));
    const path_pos_a: Vec = rotate(conjugate(body_a.rot), world_path_origin - body_a.com_pos);

    // Body 2's attachment frame is the path frame at the initial fraction.
    const frame: PathFrame = path.pointOnPath(initial_fraction);
    const frame_origin_ws: Vec = world_path_origin + rotate(world_path_rotation, frame.position);
    const frame_rot_ws: Quat = qmul(quatFromBasis(frame.tangent, frame.binormal, frame.normal), world_path_rotation);
    const path_to_body_b: Quat = qmul(frame_rot_ws, conjugate(body_b.rot));
    const path_pos_b: Vec = rotate(conjugate(body_b.rot), frame_origin_ws - body_b.com_pos);

    var c: PathConstraint = .{
        .body_a = a,
        .body_b = b,
        .path = path,
        .path_to_body_a = path_to_body_a,
        .path_pos_a = path_pos_a,
        .path_to_body_b = path_to_body_b,
        .path_pos_b = path_pos_b,
        .path_fraction = initial_fraction,
        .target_path_fraction = initial_fraction,
        .rotation_type = rotation_type,
    };
    if (rotation_type == .fully_constrained) {
        // Rest relative orientation r0^-1 = q2^-1 * q1 (Jolt's sGetInvInitialOrientation).
        c.inv_initial_orientation = qmul(body_a.rot, conjugate(body_b.rot));
    }
    try world.paths.append(world.allocator, c);
    return world.paths.items.len - 1;
}

/// A joint does work this step only if at least one endpoint is an awake dynamic body.
fn constraintActive(world: *const World, c: *const Constraint) bool {
    if (!c.enabled) {
        return false;
    }
    const a: *const Body = &world.bodies.data[c.body_a];
    const b: *const Body = &world.bodies.data[c.body_b];
    const a_live: bool = a.motion_type == .dynamic and !a.asleep;
    const b_live: bool = b.motion_type == .dynamic and !b.asleep;
    return a_live or b_live;
}

fn prepareConstraint(
    world: *World,
    c: *Constraint,
    warm_ratio: f32,
    dt: f32,
) void {
    const body_a: *const Body = &world.bodies.data[c.body_a];
    const body_b: *const Body = &world.bodies.data[c.body_b];
    const ma: *Motion = &world.motion[c.body_a];
    const mb: *Motion = &world.motion[c.body_b];
    const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
    const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];
    const r1: Vec = rotate(body_a.rot, c.local_anchor_a);
    const r2: Vec = rotate(body_b.rot, c.local_anchor_b);

    switch (c.kind) {
        .point => {
            c.point_part.prepare(ma, inv_i_a, r1, mb, inv_i_b, r2);
            if (c.point_part.active) {
                c.point_part.warmStart(ma, mb, warm_ratio);
            }
        },
        .fixed => {
            c.point_part.prepare(ma, inv_i_a, r1, mb, inv_i_b, r2);
            c.rotation_lock.prepare(inv_i_a, inv_i_b);
            if (c.point_part.active) {
                c.point_part.warmStart(ma, mb, warm_ratio);
            }
            if (c.rotation_lock.active) {
                c.rotation_lock.warmStart(ma, mb, warm_ratio);
            }
        },
        .distance => {
            const delta: Vec = (body_b.com_pos + r2) - (body_a.com_pos + r1);
            const dist: f32 = length3(delta);
            const big: f32 = floatMax(f32);
            c.axis_active = false;
            if (dist > 1.0e-6) {
                c.axis = delta * splat(1.0 / dist);
                if (c.min_distance == c.max_distance) {
                    c.axis_active = true;
                    c.axis_min_lambda = -big;
                    c.axis_max_lambda = big;
                    c.axis_target = c.min_distance;
                    c.axis_sign = 0.0;
                } else if (dist < c.min_distance) {
                    c.axis_active = true;
                    c.axis_min_lambda = 0.0;
                    c.axis_max_lambda = big;
                    c.axis_target = c.min_distance;
                    c.axis_sign = -1.0;
                } else if (dist > c.max_distance) {
                    c.axis_active = true;
                    c.axis_min_lambda = -big;
                    c.axis_max_lambda = 0.0;
                    c.axis_target = c.max_distance;
                    c.axis_sign = 1.0;
                }
            }
            if (c.axis_active) {
                // Jolt's DistanceConstraint measures BOTH moment arms from the
                // far anchor p2: body A uses r1+u = (p1−x1)+(p2−p1) = p2−x1, not
                // p1−x1. With off-COM anchors on a stretched link (e.g. a rope at
                // its max limit) the bare-r1 arm gives the wrong effective mass /
                // torque coupling and the constraint fails to hold under load.
                // `delta` here is exactly u = p2 − p1.
                c.axis_part.prepare(ma, inv_i_a, r1 + delta, mb, inv_i_b, r2, c.axis, 0.0);
                if (c.axis_part.isActive()) {
                    c.axis_part.warmStart(ma, mb, c.axis, warm_ratio);
                } else {
                    c.axis_active = false;
                }
            } else {
                c.axis_part.total_lambda = 0.0; // drop stale impulse so it can't warm-start later
            }
        },
        .hinge => {
            // (1) Lock translation at the anchor with the 3-DOF point part.
            c.point_part.prepare(ma, inv_i_a, r1, mb, inv_i_b, r2);
            // (2) Lock the two rotation axes perpendicular to the hinge axis.
            const hinge_axis_a: Vec = rotate(body_a.rot, c.local_axis_a);
            const hinge_axis_b: Vec = rotate(body_b.rot, c.local_axis_b);
            c.hinge_rotation.prepare(inv_i_a, hinge_axis_a, inv_i_b, hinge_axis_b);
            c.world_axis = hinge_axis_a; // a1
            // Current hinge angle theta about a1 (zero at the creation pose).
            const diff: Quat = qmul(conjugate(body_a.rot), qmul(c.inv_initial_rotation, body_b.rot));
            const theta: f32 = quatAngleAbout(diff, c.world_axis);

            // (3) Angle limit (rigid one-sided stop), engaged only at/over a bound.
            c.limit_rt = .{};
            if (c.has_limits and (theta <= c.limit_min or theta >= c.limit_max)) {
                const big: f32 = floatMax(f32);
                const dist_to_min: f32 = centerAngleAroundZero(theta - c.limit_min);
                const dist_to_max: f32 = centerAngleAroundZero(theta - c.limit_max);
                const min_is_closest: bool = @abs(dist_to_min) < @abs(dist_to_max);
                const c_err: f32 = if (min_is_closest) dist_to_min else dist_to_max;
                var lo: f32 = -big;
                var hi: f32 = big;
                if (c.limit_min != c.limit_max) {
                    if (min_is_closest) {
                        lo = 0.0; // at the min stop: impulse may only push the angle up
                    } else {
                        hi = 0.0; // at the max stop: impulse may only push the angle down
                    }
                }
                c.angle_limit.prepare(inv_i_a, inv_i_b, c.world_axis, 0.0);
                c.limit_rt = .{ .active = c.angle_limit.active, .c = c_err, .lo = lo, .hi = hi };
            } else {
                c.angle_limit.total_lambda = 0.0;
            }

            // (4) Motor (velocity or position) about the hinge axis.
            c.motor_rt = .{};
            if (c.motor.mode != .off and c.motor.max_force > 0.0) {
                const clamp_force: f32 = c.motor.max_force * dt;
                switch (c.motor.mode) {
                    .velocity => c.angle_motor.prepare(
                        inv_i_a,
                        inv_i_b,
                        c.world_axis,
                        -c.motor.target_velocity,
                    ),
                    .position => c.angle_motor.prepareSpring(
                        inv_i_a,
                        inv_i_b,
                        c.world_axis,
                        0.0,
                        centerAngleAroundZero(theta - c.motor.target_position),
                        c.motor.frequency,
                        c.motor.damping,
                        dt,
                    ),
                    .off => {},
                }
                c.motor_rt = .{ .active = c.angle_motor.active, .lo = -clamp_force, .hi = clamp_force };
            } else {
                c.angle_motor.total_lambda = 0.0;
            }

            // Warm start in the same order the velocity solve runs.
            if (c.motor_rt.active) {
                c.angle_motor.warmStart(ma, mb, warm_ratio);
            }
            if (c.point_part.active) {
                c.point_part.warmStart(ma, mb, warm_ratio);
            }
            if (c.hinge_rotation.active) {
                c.hinge_rotation.warmStart(ma, mb, warm_ratio);
            }
            if (c.limit_rt.active) {
                c.angle_limit.warmStart(ma, mb, warm_ratio);
            }
        },
        .slider => {
            const u: Vec = (body_b.com_pos + r2) - (body_a.com_pos + r1); // separation
            c.world_n1 = rotate(body_a.rot, c.local_normal_a);
            c.world_n2 = rotate(body_a.rot, c.local_normal_b);
            // (1) Lock translation along the two perpendicular axes.
            c.dual_axis.prepare(ma, inv_i_a, r1 + u, mb, inv_i_b, r2, c.world_n1, c.world_n2);
            // (2) Lock all three rotation axes.
            c.rotation_lock.prepare(inv_i_a, inv_i_b);
            // Slide axis + current offset d along it (zero at the creation pose).
            c.world_axis = rotate(body_a.rot, c.local_axis_a);
            const d: f32 = dot3(u, c.world_axis);

            // (3) Offset limit (rigid one-sided stop).
            c.limit_rt = .{};
            if (c.has_limits and (d <= c.limit_min or d >= c.limit_max)) {
                const big: f32 = floatMax(f32);
                const below_min: bool = d <= c.limit_min;
                const c_err: f32 = d - (if (below_min) c.limit_min else c.limit_max);
                var lo: f32 = -big;
                var hi: f32 = big;
                if (c.limit_min != c.limit_max) {
                    if (below_min) {
                        lo = 0.0;
                    } else {
                        hi = 0.0;
                    }
                }
                c.axis_part.prepare(ma, inv_i_a, r1 + u, mb, inv_i_b, r2, c.world_axis, 0.0);
                c.limit_rt = .{ .active = c.axis_part.isActive(), .c = c_err, .lo = lo, .hi = hi };
            } else {
                c.axis_part.total_lambda = 0.0;
            }

            // (4) Motor (velocity or position) along the slide axis.
            c.motor_rt = .{};
            if (c.motor.mode != .off and c.motor.max_force > 0.0) {
                const clamp_force: f32 = c.motor.max_force * dt;
                switch (c.motor.mode) {
                    .velocity => c.axis_motor.prepare(
                        ma,
                        inv_i_a,
                        r1 + u,
                        mb,
                        inv_i_b,
                        r2,
                        c.world_axis,
                        -c.motor.target_velocity,
                    ),
                    .position => c.axis_motor.prepareSpring(
                        ma,
                        inv_i_a,
                        r1 + u,
                        mb,
                        inv_i_b,
                        r2,
                        c.world_axis,
                        0.0,
                        d - c.motor.target_position,
                        c.motor.frequency,
                        c.motor.damping,
                        dt,
                    ),
                    .off => {},
                }
                c.motor_rt = .{ .active = c.axis_motor.isActive(), .lo = -clamp_force, .hi = clamp_force };
            } else {
                c.axis_motor.total_lambda = 0.0;
            }

            // Warm start in the same order the velocity solve runs.
            if (c.motor_rt.active) {
                c.axis_motor.warmStart(ma, mb, c.world_axis, warm_ratio);
            }
            if (c.dual_axis.active) {
                c.dual_axis.warmStart(ma, mb, c.world_n1, c.world_n2, warm_ratio);
            }
            if (c.rotation_lock.active) {
                c.rotation_lock.warmStart(ma, mb, warm_ratio);
            }
            if (c.limit_rt.active) {
                c.axis_part.warmStart(ma, mb, c.world_axis, warm_ratio);
            }
        },
        .swing_twist => {
            // (1) Pivot: hold the anchor coincident (Jolt's PointConstraintPart).
            c.point_part.prepare(ma, inv_i_a, r1, mb, inv_i_b, r2);
            // (2) Swing/twist limits. setLimits is cheap (a few sincos); recompute it each
            // step rather than cache at creation. Y = plane axis, Z = normal axis.
            c.swing_twist.swing_type = c.swing_type;
            c.swing_twist.setLimits(
                c.twist_min,
                c.twist_max,
                -c.plane_half_cone,
                c.plane_half_cone,
                -c.normal_half_cone,
                c.normal_half_cone,
            );
            const cb1_to_world: Quat = qmul(body_a.rot, c.constraint_to_body_a);
            const cb2_to_world: Quat = qmul(body_b.rot, c.constraint_to_body_b);
            const q: Quat = qmul(conjugate(cb1_to_world), cb2_to_world);
            c.swing_twist.calculateConstraintProperties(inv_i_a, inv_i_b, q, cb1_to_world);
            // (3) Motors (twist drives part 0; swing drives parts 1, 2).
            prepareSwingTwistMotors(c, inv_i_a, inv_i_b, cb2_to_world, q, dt);
            // Warm start in Jolt order: motors, limits, pivot.
            if (c.motor_part[0].active) {
                c.motor_part[0].warmStart(ma, mb, warm_ratio);
            }
            if (c.motor_part[1].active) {
                c.motor_part[1].warmStart(ma, mb, warm_ratio);
            }
            if (c.motor_part[2].active) {
                c.motor_part[2].warmStart(ma, mb, warm_ratio);
            }
            c.swing_twist.warmStart(ma, mb, warm_ratio);
            if (c.point_part.active) {
                c.point_part.warmStart(ma, mb, warm_ratio);
            }
        },
        .gear => {
            const axis_a: Vec = rotate(body_a.rot, c.local_axis_a);
            const axis_b: Vec = rotate(body_b.rot, c.local_axis_b);
            c.world_axis = axis_a;
            c.world_axis_b = axis_b;
            c.gear_part.prepare(inv_i_a, axis_a, inv_i_b, axis_b, c.ratio);
            if (c.gear_part.isActive()) {
                c.gear_part.warmStart(ma, mb, warm_ratio);
            }
        },
        .rack_and_pinion => {
            const axis_a: Vec = rotate(body_a.rot, c.local_axis_a);
            const axis_b: Vec = rotate(body_b.rot, c.local_axis_b);
            c.world_axis = axis_a;
            c.world_axis_b = axis_b;
            c.rack_pinion_part.prepare(inv_i_a, axis_a, mb.inv_mass, axis_b, c.ratio);
            if (c.rack_pinion_part.isActive()) {
                c.rack_pinion_part.warmStart(ma, mb, warm_ratio);
            }
        },
        .pulley => {
            const wp1: Vec = body_a.com_pos + rotate(body_a.rot, c.local_anchor_a);
            const wp2: Vec = body_b.com_pos + rotate(body_b.rot, c.local_anchor_b);
            const d1: Vec = wp1 - c.pulley_fixed_a;
            const d2: Vec = wp2 - c.pulley_fixed_b;
            const len1: f32 = length3(d1);
            const len2: f32 = length3(d2);
            const n1: Vec = if (len1 > 0.0) d1 / splat(len1) else vec_zero;
            const n2: Vec = if (len2 > 0.0) d2 / splat(len2) else vec_zero;
            c.world_axis = n1;
            c.world_axis_b = n2;
            const current_length: f32 = len1 + c.ratio * len2;
            const min_violation: bool = current_length <= c.min_distance;
            const max_violation: bool = current_length >= c.max_distance;
            if (min_violation or max_violation) {
                // Rope is taut: a one-sided pull (too long => may only shorten, too short => lengthen).
                c.axis_min_lambda = if (max_violation) -floatMax(f32) else 0.0;
                c.axis_max_lambda = if (min_violation) floatMax(f32) else 0.0;
                const r1_axis: Vec = wp1 - body_a.com_pos;
                const r2_axis: Vec = wp2 - body_b.com_pos;
                c.indep_axis_part.prepare(
                    inv_i_a,
                    ma.inv_mass,
                    r1_axis,
                    n1,
                    inv_i_b,
                    mb.inv_mass,
                    r2_axis,
                    n2,
                    c.ratio,
                );
                if (c.indep_axis_part.isActive()) {
                    c.indep_axis_part.warmStart(ma, mb, n1, n2, c.ratio, warm_ratio);
                }
            } else {
                c.indep_axis_part.deactivate();
            }
        },
    }
}

fn solveConstraintVelocity(world: *World, c: *Constraint) void {
    const ma: *Motion = &world.motion[c.body_a];
    const mb: *Motion = &world.motion[c.body_b];
    switch (c.kind) {
        .point => {
            if (c.point_part.active) {
                c.point_part.solveVelocity(ma, mb);
            }
        },
        .fixed => {
            if (c.point_part.active) {
                c.point_part.solveVelocity(ma, mb);
            }
            if (c.rotation_lock.active) {
                c.rotation_lock.solveVelocity(ma, mb);
            }
        },
        .distance => {
            if (c.axis_active) {
                const total: f32 = c.axis_part.solveGetTotalLambda(ma, mb, c.axis);
                const clamped: f32 = clamp(total, c.axis_min_lambda, c.axis_max_lambda);
                c.axis_part.solveApplyLambda(ma, mb, c.axis, clamped);
            }
        },
        .hinge => {
            // Order matches Jolt: motor, point (translation), 2-axis rotation, limit.
            if (c.motor_rt.active) {
                c.angle_motor.solveVelocity(ma, mb, c.world_axis, c.motor_rt.lo, c.motor_rt.hi);
            }
            if (c.point_part.active) {
                c.point_part.solveVelocity(ma, mb);
            }
            if (c.hinge_rotation.active) {
                c.hinge_rotation.solveVelocity(ma, mb);
            }
            if (c.limit_rt.active) {
                c.angle_limit.solveVelocity(ma, mb, c.world_axis, c.limit_rt.lo, c.limit_rt.hi);
            }
        },
        .slider => {
            // Order matches Jolt: motor, 2-axis translation, 3-axis rotation, limit.
            if (c.motor_rt.active) {
                const total: f32 = c.axis_motor.solveGetTotalLambda(ma, mb, c.world_axis);
                const clamped: f32 = clamp(total, c.motor_rt.lo, c.motor_rt.hi);
                c.axis_motor.solveApplyLambda(ma, mb, c.world_axis, clamped);
            }
            if (c.dual_axis.active) {
                c.dual_axis.solveVelocity(ma, mb, c.world_n1, c.world_n2);
            }
            if (c.rotation_lock.active) {
                c.rotation_lock.solveVelocity(ma, mb);
            }
            if (c.limit_rt.active) {
                const total: f32 = c.axis_part.solveGetTotalLambda(ma, mb, c.world_axis);
                const clamped: f32 = clamp(total, c.limit_rt.lo, c.limit_rt.hi);
                c.axis_part.solveApplyLambda(ma, mb, c.world_axis, clamped);
            }
        },
        .swing_twist => {
            // Jolt order: motors (twist part 0, then swing parts 1, 2), limits, pivot.
            if (c.motor_part[0].active) {
                c.motor_part[0].solveVelocity(ma, mb, c.motor_axis[0], c.twist_motor_lo, c.twist_motor_hi);
            }
            if (c.motor_part[1].active) {
                c.motor_part[1].solveVelocity(ma, mb, c.motor_axis[1], c.swing_motor_lo, c.swing_motor_hi);
                c.motor_part[2].solveVelocity(ma, mb, c.motor_axis[2], c.swing_motor_lo, c.swing_motor_hi);
            }
            c.swing_twist.solveVelocity(ma, mb);
            if (c.point_part.active) {
                c.point_part.solveVelocity(ma, mb);
            }
        },
        .gear => {
            if (c.gear_part.isActive()) {
                c.gear_part.solveVelocity(ma, mb, c.world_axis, c.world_axis_b, c.ratio);
            }
        },
        .rack_and_pinion => {
            if (c.rack_pinion_part.isActive()) {
                c.rack_pinion_part.solveVelocity(ma, mb, c.world_axis, c.world_axis_b, c.ratio);
            }
        },
        .pulley => {
            if (c.indep_axis_part.isActive()) {
                c.indep_axis_part.solveVelocity(
                    ma,
                    mb,
                    c.world_axis,
                    c.world_axis_b,
                    c.ratio,
                    c.axis_min_lambda,
                    c.axis_max_lambda,
                );
            }
        },
    }
}

fn solveConstraintPosition(world: *World, c: *Constraint, baumgarte: f32) void {
    const body_a: *Body = &world.bodies.data[c.body_a];
    const body_b: *Body = &world.bodies.data[c.body_b];
    const ma: *const Motion = &world.motion[c.body_a];
    const mb: *const Motion = &world.motion[c.body_b];
    switch (c.kind) {
        .point => {
            if (c.point_part.active) {
                c.point_part.solvePosition(body_a, ma, body_b, mb, baumgarte);
            }
        },
        .fixed => {
            if (c.point_part.active) {
                c.point_part.solvePosition(body_a, ma, body_b, mb, baumgarte);
            }
            if (c.rotation_lock.active) {
                c.rotation_lock.solvePosition(body_a, body_b, c.inv_initial_rotation, baumgarte);
            }
        },
        .distance => {
            if (c.axis_active and c.axis_part.isActive()) {
                // Recompute the current length error from the up-to-date pose.
                const r1: Vec = rotate(body_a.rot, c.local_anchor_a);
                const r2: Vec = rotate(body_b.rot, c.local_anchor_b);
                const delta: Vec = (body_b.com_pos + r2) - (body_a.com_pos + r1);
                const dist: f32 = length3(delta);
                if (dist > 1.0e-6) {
                    const err: f32 = dist - c.axis_target;
                    const gated: bool = (c.axis_sign == 0.0) or
                        (c.axis_sign > 0.0 and err > 0.0) or
                        (c.axis_sign < 0.0 and err < 0.0);
                    if (gated) {
                        const axis: Vec = delta * splat(1.0 / dist);
                        // Re-derive the constraint properties (moment arm r1+u,
                        // effective mass) from the CURRENT pose — Jolt calls
                        // CalculateConstraintProperties inside SolvePositionConstraint.
                        // Without it the off-COM moment arm goes stale across the
                        // position sweep, and an off-centre anchor under a heavy
                        // load over-rotates and the link runs away. Re-bake the
                        // world inverse inertia from the current rotation too.
                        const inv_i_a: Mat3 = if (ma.inv_mass > 0.0)
                            bakeInvInertiaWorld(body_a.rot, ma.inv_inertia_diagonal, ma.inertia_rotation)
                        else
                            Mat3.zero;
                        const inv_i_b: Mat3 = if (mb.inv_mass > 0.0)
                            bakeInvInertiaWorld(body_b.rot, mb.inv_inertia_diagonal, mb.inertia_rotation)
                        else
                            Mat3.zero;
                        c.axis_part.prepare(ma, inv_i_a, r1 + delta, mb, inv_i_b, r2, axis, 0.0);
                        c.axis_part.solvePosition(body_a, ma, body_b, mb, axis, err, baumgarte);
                    }
                }
            }
        },
        .hinge => {
            const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
            const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];
            // Translation lock (its separation is read live, so no re-prepare needed).
            if (c.point_part.active) {
                c.point_part.solvePosition(body_a, ma, body_b, mb, baumgarte);
            }
            // 2-axis rotation lock: re-prepare from the updated pose so its error (read
            // from the cached frame) actually shrinks as we iterate, like Jolt.
            const hinge_axis_a: Vec = rotate(body_a.rot, c.local_axis_a);
            const hinge_axis_b: Vec = rotate(body_b.rot, c.local_axis_b);
            c.hinge_rotation.prepare(inv_i_a, hinge_axis_a, inv_i_b, hinge_axis_b);
            if (c.hinge_rotation.active) {
                c.hinge_rotation.solvePosition(body_a, body_b, baumgarte);
            }
            // Angle limit (rigid): recompute the current angle and the nearer-limit error.
            if (c.limit_rt.active) {
                const diff: Quat = qmul(conjugate(body_a.rot), qmul(c.inv_initial_rotation, body_b.rot));
                const theta: f32 = quatAngleAbout(diff, hinge_axis_a);
                var c_err: f32 = 0.0;
                var engaged: bool = false;
                if (c.limit_min == c.limit_max) {
                    c_err = centerAngleAroundZero(theta - c.limit_min);
                    engaged = true;
                } else if (theta <= c.limit_min or theta >= c.limit_max) {
                    const dist_to_min: f32 = centerAngleAroundZero(theta - c.limit_min);
                    const dist_to_max: f32 = centerAngleAroundZero(theta - c.limit_max);
                    c_err = if (@abs(dist_to_min) < @abs(dist_to_max)) dist_to_min else dist_to_max;
                    engaged = true;
                }
                if (engaged) {
                    c.angle_limit.prepare(inv_i_a, inv_i_b, hinge_axis_a, 0.0);
                    c.angle_limit.solvePosition(
                        body_a,
                        body_b,
                        c.angle_limit.inv_i1_axis,
                        c.angle_limit.inv_i2_axis,
                        c_err,
                        baumgarte,
                    );
                }
            }
        },
        .slider => {
            const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
            const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];
            // One pose snapshot drives all three sub-solves (matches Jolt's reuse of u).
            const r1: Vec = rotate(body_a.rot, c.local_anchor_a);
            const r2: Vec = rotate(body_b.rot, c.local_anchor_b);
            const u: Vec = (body_b.com_pos + r2) - (body_a.com_pos + r1);
            const n1: Vec = rotate(body_a.rot, c.local_normal_a);
            const n2: Vec = rotate(body_a.rot, c.local_normal_b);
            const axis: Vec = rotate(body_a.rot, c.local_axis_a);
            // 2-axis translation lock and 3-axis rotation lock (errors read live).
            if (c.dual_axis.active) {
                c.dual_axis.solvePosition(body_a, ma, body_b, mb, u, n1, n2, baumgarte);
            }
            if (c.rotation_lock.active) {
                c.rotation_lock.solvePosition(body_a, body_b, c.inv_initial_rotation, baumgarte);
            }
            // Offset limit (rigid): correct only while the offset is past a bound.
            if (c.limit_rt.active) {
                const d: f32 = dot3(u, axis);
                var c_err: f32 = 0.0;
                var engaged: bool = false;
                if (c.limit_min == c.limit_max) {
                    c_err = d - c.limit_min;
                    engaged = true;
                } else if (d <= c.limit_min) {
                    c_err = d - c.limit_min;
                    engaged = true;
                } else if (d >= c.limit_max) {
                    c_err = d - c.limit_max;
                    engaged = true;
                }
                if (engaged) {
                    c.axis_part.prepare(ma, inv_i_a, r1 + u, mb, inv_i_b, r2, axis, 0.0);
                    c.axis_part.solvePosition(body_a, ma, body_b, mb, axis, c_err, baumgarte);
                }
            }
        },
        .swing_twist => {
            const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
            const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];
            // Rotation limits: recompute the constraint rotation from the current pose.
            const cb1: Quat = qmul(body_a.rot, c.constraint_to_body_a);
            const cb2: Quat = qmul(body_b.rot, c.constraint_to_body_b);
            const q: Quat = qmul(conjugate(cb1), cb2);
            c.swing_twist.solvePosition(
                body_a,
                body_b,
                inv_i_a,
                inv_i_b,
                q,
                c.constraint_to_body_a,
                c.constraint_to_body_b,
                baumgarte,
            );
            // Pivot: re-prepare from the updated pose, then correct (matches Jolt).
            const r1: Vec = rotate(body_a.rot, c.local_anchor_a);
            const r2: Vec = rotate(body_b.rot, c.local_anchor_b);
            c.point_part.prepare(ma, inv_i_a, r1, mb, inv_i_b, r2);
            if (c.point_part.active) {
                c.point_part.solvePosition(body_a, ma, body_b, mb, baumgarte);
            }
        },
        .gear => {
            // Slow drift correction from the two meshed hinges' current angles (Jolt); skipped
            // (velocity coupling only) when the hinge references aren't set — Jolt's null path.
            if (c.gear_ref_a >= 0 and c.gear_ref_b >= 0 and c.gear_part.isActive()) {
                const g1: *const Constraint = &world.constraints.items[@intCast(c.gear_ref_a)];
                const g2: *const Constraint = &world.constraints.items[@intCast(c.gear_ref_b)];
                const gear1rot: f32 = hingeCurrentAngle(world, g1);
                const gear2rot: f32 = hingeCurrentAngle(world, g2);
                const wrapped: f32 = @rem(gear1rot + c.ratio * gear2rot, 2.0 * pi);
                const err: f32 = centerAngleAroundZero(wrapped);
                if (err != 0.0) {
                    const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
                    const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];
                    const axis_a: Vec = rotate(body_a.rot, c.local_axis_a);
                    const axis_b: Vec = rotate(body_b.rot, c.local_axis_b);
                    c.gear_part.prepare(inv_i_a, axis_a, inv_i_b, axis_b, c.ratio);
                    c.gear_part.solvePosition(body_a, body_b, err, baumgarte);
                }
            }
        },
        .rack_and_pinion => {
            // Drift correction from the pinion hinge angle and the rack slider position (Jolt);
            // skipped (velocity coupling only) when the references aren't set.
            if (c.gear_ref_a >= 0 and c.gear_ref_b >= 0 and c.rack_pinion_part.isActive()) {
                const pinion: *const Constraint = &world.constraints.items[@intCast(c.gear_ref_a)];
                const rack: *const Constraint = &world.constraints.items[@intCast(c.gear_ref_b)];
                const rotation: f32 = hingeCurrentAngle(world, pinion);
                const translation: f32 = sliderCurrentPosition(world, rack);
                const wrapped: f32 = @rem(rotation - c.ratio * translation, 2.0 * pi);
                const err: f32 = centerAngleAroundZero(wrapped);
                if (err != 0.0) {
                    const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
                    const axis_a: Vec = rotate(body_a.rot, c.local_axis_a);
                    const axis_b: Vec = rotate(body_b.rot, c.local_axis_b);
                    c.rack_pinion_part.prepare(inv_i_a, axis_a, mb.inv_mass, axis_b, c.ratio);
                    c.rack_pinion_part.solvePosition(body_a, body_b, err, baumgarte);
                }
            }
        },
        .pulley => {
            // Recompute the length from the updated pose; correct only while the rope is taut.
            const wp1: Vec = body_a.com_pos + rotate(body_a.rot, c.local_anchor_a);
            const wp2: Vec = body_b.com_pos + rotate(body_b.rot, c.local_anchor_b);
            const d1: Vec = wp1 - c.pulley_fixed_a;
            const d2: Vec = wp2 - c.pulley_fixed_b;
            const len1: f32 = length3(d1);
            const len2: f32 = length3(d2);
            const n1: Vec = if (len1 > 0.0) d1 / splat(len1) else vec_zero;
            const n2: Vec = if (len2 > 0.0) d2 / splat(len2) else vec_zero;
            const current_length: f32 = len1 + c.ratio * len2;
            var position_error: f32 = 0.0;
            if (current_length < c.min_distance) {
                position_error = current_length - c.min_distance;
            } else if (current_length > c.max_distance) {
                position_error = current_length - c.max_distance;
            }
            if (position_error != 0.0) {
                const inv_i_a: Mat3 = world.inv_inertia_world[c.body_a];
                const inv_i_b: Mat3 = world.inv_inertia_world[c.body_b];
                const r1: Vec = wp1 - body_a.com_pos;
                const r2: Vec = wp2 - body_b.com_pos;
                c.indep_axis_part.prepare(
                    inv_i_a,
                    ma.inv_mass,
                    r1,
                    n1,
                    inv_i_b,
                    mb.inv_mass,
                    r2,
                    n2,
                    c.ratio,
                );
                c.indep_axis_part.solvePosition(
                    body_a,
                    ma,
                    body_b,
                    mb,
                    n1,
                    n2,
                    c.ratio,
                    position_error,
                    baumgarte,
                );
            }
        },
    }
}

// =============================================================================
// THE STEP. The whole pipeline, in Jolt's order, as one function. Each phase is a
// labelled block; the many-times-called kernels above are the only helpers.
// =============================================================================

/// Turn one manifold into a contact constraint and append it. Factored out of Phase 4
/// so a compound's several leaf manifolds (each with its own `sub` discriminator) all
/// run the identical setup; `sub` is 0 for a plain leaf-leaf pair, reproducing the
/// original single-contact path exactly. Reads POST-gravity, PRE-warm-start velocities.
fn setupContactFromManifold(
    world: *World,
    contacts: *std.ArrayListUnmanaged(Contact),
    scratch: std.mem.Allocator,
    a: BodyIndex,
    b: BodyIndex,
    body_a: *const Body,
    body_b: *const Body,
    ma: *const Motion,
    mb: *const Motion,
    manifold: Manifold,
    sub: u32,
    settings: ContactSettings,
    dt: f32,
    s: Settings,
    gravity: Vec,
) !void {
    const inv_i_a: Mat3 = world.inv_inertia_world[a];
    const inv_i_b: Mat3 = world.inv_inertia_world[b];

    const normal: Vec = manifold.normal;
    const tangent1: Vec = normalizedPerpendicular(normal);
    const tangent2: Vec = cross(normal, tangent1);

    // Jolt defaults: friction = sqrt(f1*f2), restitution = @max(r1, r2); either may be
    // overridden per-contact by the listener via ContactSettings.
    const friction: f32 = settings.friction orelse @sqrt(body_a.friction * body_b.friction);
    const restitution: f32 = settings.restitution orelse @max(body_a.restitution, body_b.restitution);

    // Relative acceleration that THIS step's gravity + forces produced, used to cancel
    // the over-applied velocity when computing restitution.
    const grav_accel: Vec = gravity * splat(mb.gravity_scale - ma.gravity_scale);
    const force_accel_a: Vec = ma.force * splat(ma.inv_mass);
    const force_accel_b: Vec = mb.force * splat(mb.inv_mass);
    const relative_acceleration: Vec = grav_accel - force_accel_a + force_accel_b;

    var contact: Contact = .{
        .a = a,
        .b = b,
        .sub = sub,
        .normal = normal,
        .tangent1 = tangent1,
        .tangent2 = tangent2,
        .friction = friction,
        .friction1 = AxisPart.inactive,
        .friction2 = AxisPart.inactive,
        .angular_friction = AngularPart.inactive,
        .count = manifold.count,
        .points = undefined,
    };

    const rot_a_inv: Quat = conjugate(body_a.rot);
    const rot_b_inv: Quat = conjugate(body_b.rot);

    // Friction centroid = average of the per-point midpoints.
    var friction_center: Vec = vec_zero;

    var i: u8 = 0;
    while (i < manifold.count) : (i += 1) {
        const mp: ManifoldPoint = manifold.points[i];
        const midpoint: Vec = (mp.point_on_a + mp.point_on_b) * splat(0.5);
        friction_center += midpoint;

        const ra: Vec = midpoint - body_a.com_pos;
        const rb: Vec = midpoint - body_b.com_pos;

        // penetration > 0 if overlapping (Jolt: (p1 - p2) . normal).
        const penetration: f32 = dot3(mp.point_on_a - mp.point_on_b, normal);

        // Velocity of the contact point, B relative to A.
        const vel_a: Vec = ma.lin_vel + cross(ma.ang_vel, ra);
        const vel_b: Vec = mb.lin_vel + cross(mb.ang_vel, rb);
        const normal_velocity: f32 = dot3(vel_b - vel_a, normal);

        const speculative_bias: f32 = @max(0.0, -penetration / dt);

        var normal_bias: f32 = speculative_bias;
        if (restitution > 0.0 and normal_velocity < -s.min_velocity_for_restitution) {
            if (normal_velocity < -speculative_bias) {
                // Cancel the velocity this step's forces added (towards the normal).
                const force_delta: f32 = @min(0.0, dot3(relative_acceleration, normal) * dt);
                normal_bias = restitution * (normal_velocity - force_delta);
            } else {
                normal_bias = speculative_bias;
            }
        }

        var point: ContactPoint = .{
            .local_a = rotate(rot_a_inv, mp.point_on_a - body_a.com_pos),
            .local_b = rotate(rot_b_inv, mp.point_on_b - body_b.com_pos),
            .feature_id = mp.feature_id,
            .distance_to_friction_center = 0.0, // filled after the centroid is known
            .normal_part = AxisPart.inactive,
        };
        point.normal_part.prepare(ma, inv_i_a, ra, mb, inv_i_b, rb, normal, normal_bias);
        const point_key: PointKey = .{
            .a = @min(a, b),
            .b = @max(a, b),
            .sub = sub,
            .feature = mp.feature_id,
        };
        point.normal_part.total_lambda = world.cache.lookupNormal(point_key);

        contact.points[i] = point;
    }

    friction_center /= splat(@floatFromInt(manifold.count));

    // Per-point tangent-plane distance to the friction centroid (scales the torsional
    // friction cone), then the per-manifold friction parts.
    if (friction > 0.0) {
        i = 0;
        while (i < manifold.count) : (i += 1) {
            const surface_a: Vec = manifold.points[i].point_on_a;
            const surface_b: Vec = manifold.points[i].point_on_b;
            const midpoint: Vec = (surface_a + surface_b) * splat(0.5);
            const delta: Vec = midpoint - friction_center;
            const tangential: Vec = delta - normal * splat(dot3(delta, normal));
            contact.points[i].distance_to_friction_center = length3(tangential);
        }

        const rf_a: Vec = friction_center - body_a.com_pos;
        const rf_b: Vec = friction_center - body_b.com_pos;
        // A non-zero surface velocity (conveyor) becomes the friction constraint's target:
        // the solver drives (v_a - v_b) along each tangent toward it, capped by the cone.
        const surf: Vec = settings.relative_linear_surface_velocity;
        contact.friction1.prepare(ma, inv_i_a, rf_a, mb, inv_i_b, rf_b, tangent1, dot3(tangent1, surf));
        contact.friction2.prepare(ma, inv_i_a, rf_a, mb, inv_i_b, rf_b, tangent2, dot3(tangent2, surf));
        if (manifold.count > 1) {
            contact.angular_friction.prepare(inv_i_a, inv_i_b, normal);
        }

        const friction_key: ManifoldKey = .{ .a = @min(a, b), .b = @max(a, b), .sub = sub };
        const cached: CachedFriction = world.cache.lookupFriction(friction_key);
        contact.friction1.total_lambda = cached.linear[0];
        contact.friction2.total_lambda = cached.linear[1];
        contact.angular_friction.total_lambda = cached.angular;
    }

    try contacts.append(scratch, contact);
}

// =============================================================================
// Soft bodies (Stage 1: the XPBD solver core). A soft body is a cloud of particles connected by
// distance (edge) and tetrahedral-volume constraints, solved with Extended Position-Based Dynamics
// (Jolt's SoftBodySharedSettings + SoftBodyMotionProperties). Each World.step substeps the body
// `num_iterations` times; per substep it integrates gravity, predicts positions, solves every
// constraint once (Gauss-Seidel), then derives velocities from the position change. Pinned vertices
// (inv_mass == 0) act as anchors, so a hanging cloth or rope works with no collision.
//
// Deferred to later stages: collision against the rigid world (DetermineCollidingShapes /
// CollisionPlanes / friction + reaction on rigid bodies), dihedral-bend / skinned / LRA / rod
// constraints, internal pressure, the SoftBodyShape (colliding rigid bodies *against* the soft
// body), and CreateConstraints (auto-generating constraints from a mesh).
// =============================================================================

/// The signed dihedral measure used by the bend constraint: `sign · acos(n1·n2 / |n1||n2|)` where n1,
/// n2 are the two triangle normals about the shared edge x0→x1. Used to seed each constraint's rest
/// angle so the rest configuration is a no-op.
fn softBodyBendAngle(
    x0: Vec,
    x1: Vec,
    x2: Vec,
    x3: Vec,
) f32 {
    const e: Vec = x1 - x0;
    const n1: Vec = cross(x2 - x0, x2 - x1);
    const n2: Vec = cross(x3 - x1, x3 - x0);
    const denom: f32 = @sqrt(lengthSq3(n1) * lengthSq3(n2));
    if (denom < 1.0e-12) {
        return 0.0;
    }
    const d: f32 = clamp(dot3(n1, n2) / denom, -1.0, 1.0);
    const sign: f32 = if (dot3(cross(n2, n1), e) < 0.0) -1.0 else 1.0;
    return sign * acosRad(d);
}

/// Build a shareable soft-body asset, copying the inputs into allocator-owned arrays and computing
/// each edge's rest length and each tetrahedron's rest volume from the initial vertex positions
/// (Jolt's CalculateEdgeLengths / CalculateVolumeConstraintVolumes). `faces` may be empty.
pub fn createSoftBodyShared(
    gpa: std.mem.Allocator,
    vertices: []const SoftVertexDef,
    edges: []const SoftEdge,
    bends: []const SoftDihedralBend,
    volumes: []const SoftVolume,
    lra: []const SoftLRA,
    faces: []const SoftFace,
) !SoftBodyShared {
    const v: []SoftVertexDef = try gpa.alloc(SoftVertexDef, vertices.len);
    @memcpy(v, vertices);
    const e: []SoftEdge = try gpa.alloc(SoftEdge, edges.len);
    @memcpy(e, edges);
    const bn: []SoftDihedralBend = try gpa.alloc(SoftDihedralBend, bends.len);
    @memcpy(bn, bends);
    const vol: []SoftVolume = try gpa.alloc(SoftVolume, volumes.len);
    @memcpy(vol, volumes);
    const lr: []SoftLRA = try gpa.alloc(SoftLRA, lra.len);
    @memcpy(lr, lra);
    const f: []SoftFace = try gpa.alloc(SoftFace, faces.len);
    @memcpy(f, faces);

    for (e) |*edge| {
        const p0: Vec = v[edge.vertex[0]].position;
        const p1: Vec = v[edge.vertex[1]].position;
        edge.rest_length = length3(p1 - p0);
    }
    for (vol) |*tet| {
        const x1: Vec = v[tet.vertex[0]].position;
        const x2: Vec = v[tet.vertex[1]].position;
        const x3: Vec = v[tet.vertex[2]].position;
        const x4: Vec = v[tet.vertex[3]].position;
        tet.six_rest_volume = @abs(dot3(cross(x2 - x1, x3 - x1), x4 - x1));
    }
    for (bn) |*b| {
        // Rest dihedral angle, using the same measure as the solver so c = 0 at rest.
        b.initial_angle = softBodyBendAngle(
            v[b.vertex[0]].position,
            v[b.vertex[1]].position,
            v[b.vertex[2]].position,
            v[b.vertex[3]].position,
        );
    }
    for (lr) |*l| {
        if (l.max_distance <= 0.0) {
            l.max_distance = length3(v[l.vertex[1]].position - v[l.vertex[0]].position);
        }
    }
    return .{ .vertices = v, .edges = e, .bends = bn, .volumes = vol, .lra = lr, .faces = f };
}

/// Convenience builder for a rectangular cloth in the XZ plane (a `cols` x `rows` grid of particles
/// spaced `spacing` apart, the surface lying at y = 0). Adds structural edges (grid lines) and shear
/// edges (cell diagonals); `compliance` sets the stretchiness (0 = rigid). If `pin_top_row` is set,
/// the first row (z = 0) is pinned (inv_mass 0) so the cloth hangs. The caller owns the returned
/// asset's arrays via `gpa`.
pub fn createClothGrid(
    gpa: std.mem.Allocator,
    cols: u32,
    rows: u32,
    spacing: f32,
    compliance: f32,
    pin_top_row: bool,
) !SoftBodyShared {
    var verts: std.ArrayListUnmanaged(SoftVertexDef) = .empty;
    var edges: std.ArrayListUnmanaged(SoftEdge) = .empty;
    var faces: std.ArrayListUnmanaged(SoftFace) = .empty;
    defer verts.deinit(gpa);
    defer edges.deinit(gpa);
    defer faces.deinit(gpa);

    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const pinned: bool = pin_top_row and r == 0;
            try verts.append(gpa, .{
                .position = vec(float(c) * spacing, 0.0, float(r) * spacing),
                .inv_mass = if (pinned) 0.0 else 1.0,
            });
        }
    }
    const idx = struct {
        fn at(col: u32, row: u32, w: u32) u32 {
            return row * w + col;
        }
    };
    r = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            if (c + 1 < cols) {
                try edges.append(
                    gpa,
                    .{ .vertex = .{ idx.at(c, r, cols), idx.at(c + 1, r, cols) }, .compliance = compliance },
                );
            }
            if (r + 1 < rows) {
                try edges.append(
                    gpa,
                    .{ .vertex = .{ idx.at(c, r, cols), idx.at(c, r + 1, cols) }, .compliance = compliance },
                );
            }
            if (c + 1 < cols and r + 1 < rows) {
                // shear diagonals
                try edges.append(
                    gpa,
                    .{
                        .vertex = .{ idx.at(c, r, cols), idx.at(c + 1, r + 1, cols) },
                        .compliance = compliance,
                    },
                );
                try edges.append(
                    gpa,
                    .{
                        .vertex = .{ idx.at(c + 1, r, cols), idx.at(c, r + 1, cols) },
                        .compliance = compliance,
                    },
                );
                // two triangles for the surface
                try faces.append(
                    gpa,
                    .{ .vertex = .{ idx.at(c, r, cols), idx.at(c + 1, r, cols), idx.at(c, r + 1, cols) } },
                );
                try faces.append(
                    gpa,
                    .{
                        .vertex = .{
                            idx.at(c + 1, r, cols),
                            idx.at(c + 1, r + 1, cols),
                            idx.at(c, r + 1, cols),
                        },
                    },
                );
            }
        }
    }
    return createSoftBodyShared(
        gpa,
        verts.items,
        edges.items,
        &[_]SoftDihedralBend{},
        &[_]SoftVolume{},
        &[_]SoftLRA{},
        faces.items,
    );
}

/// How createSoftBodyFromMesh generates bending resistance (Jolt's EBendType).
pub const SoftBendType = enum { none, distance, dihedral };

/// Options for createSoftBodyFromMesh. Uses uniform compliances (Jolt additionally supports per-vertex
/// attributes, omitted here). `angle_tolerance` controls shear-edge detection (default 8 degrees).
pub const SoftMeshOptions = struct {
    edge_compliance: f32 = 0.0,
    shear_compliance: f32 = 0.0,
    bend_compliance: f32 = 0.0,
    bend_type: SoftBendType = .dihedral,
    angle_tolerance: f32 = 0.139626, // 8 degrees in radians
};

/// Build a soft-body asset from a triangle mesh, auto-generating its constraints (Jolt's
/// SoftBodySharedSettings::CreateConstraints). Emits one structural edge per unique mesh edge and,
/// for each interior edge shared by two triangles, either a shear edge (when the two triangles are
/// near-coplanar and the quad's diagonal is near-perpendicular) or a bend constraint (distance or
/// dihedral). This is the practical way to turn a mesh into cloth without listing constraints by
/// hand. Edges touching only pinned vertices are skipped. The caller owns the result via gpa.
pub fn createSoftBodyFromMesh(
    gpa: std.mem.Allocator,
    vertices: []const SoftVertexDef,
    faces: []const SoftFace,
    opts: SoftMeshOptions,
) !SoftBodyShared {
    const EdgeHelper = struct { v: [2]u32, edge_idx: u32 };
    var edges: std.ArrayListUnmanaged(EdgeHelper) = .empty;
    defer edges.deinit(gpa);
    for (faces, 0..) |f, fi| {
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const a: u32 = f.vertex[i];
            const b: u32 = f.vertex[(i + 1) % 3];
            try edges.append(
                gpa,
                .{ .v = .{ @min(a, b), @max(a, b) }, .edge_idx = @as(u32, @intCast(fi)) * 3 + i },
            );
        }
    }
    const lessThan = struct {
        fn lt(_: void, x: EdgeHelper, y: EdgeHelper) bool {
            return x.v[0] < y.v[0] or (x.v[0] == y.v[0] and x.v[1] < y.v[1]);
        }
    }.lt;
    std.mem.sort(EdgeHelper, edges.items, {}, lessThan);

    const addEdge = struct {
        fn add(
            g: std.mem.Allocator,
            verts: []const SoftVertexDef,
            list: *std.ArrayListUnmanaged(SoftEdge),
            a: u32,
            b: u32,
            comp: f32,
        ) !void {
            if (verts[a].inv_mass > 0.0 or verts[b].inv_mass > 0.0) {
                try list.append(g, .{ .vertex = .{ a, b }, .compliance = comp });
            }
        }
    }.add;

    var out_edges: std.ArrayListUnmanaged(SoftEdge) = .empty;
    var out_bends: std.ArrayListUnmanaged(SoftDihedralBend) = .empty;
    defer out_edges.deinit(gpa);
    defer out_bends.deinit(gpa);

    const st: f32 = @sin(opts.angle_tolerance);
    const ct: f32 = @cos(opts.angle_tolerance);
    const sq_sin_tol: f32 = st * st;
    const sq_cos_tol: f32 = ct * ct;

    var i: usize = 0;
    while (i < edges.items.len) : (i += 1) {
        const e0: EdgeHelper = edges.items[i];
        var is_shear: bool = false;
        var j: usize = i + 1;
        while (j < edges.items.len) : (j += 1) {
            const e1: EdgeHelper = edges.items[j];
            if (e0.v[0] == e1.v[0] and e0.v[1] == e1.v[1]) {
                const f0: SoftFace = faces[e0.edge_idx / 3];
                const f1: SoftFace = faces[e1.edge_idx / 3];
                const vopp0: u32 = f0.vertex[(e0.edge_idx + 2) % 3];
                const vopp1: u32 = f1.vertex[(e1.edge_idx + 2) % 3];
                if (vopp0 == vopp1) {
                    continue;
                }
                const n0: Vec = cross(
                    vertices[f0.vertex[2]].position - vertices[f0.vertex[0]].position,
                    vertices[f0.vertex[1]].position - vertices[f0.vertex[0]].position,
                );
                const n1: Vec = cross(
                    vertices[f1.vertex[2]].position - vertices[f1.vertex[0]].position,
                    vertices[f1.vertex[1]].position - vertices[f1.vertex[0]].position,
                );
                const n0_dot_n1: f32 = dot3(n0, n1);
                const n0_dot_n1_sq: f32 = n0_dot_n1 * n0_dot_n1;
                const tol_term: f32 = sq_cos_tol * lengthSq3(n0) * lengthSq3(n1);
                if (n0_dot_n1 > 0.0 and n0_dot_n1_sq > tol_term) {
                    const e0_dir: Vec = vertices[vopp0].position - vertices[e0.v[0]].position;
                    const e1_dir: Vec = vertices[vopp1].position - vertices[e0.v[0]].position;
                    const dotdir: f32 = dot3(e0_dir, e1_dir);
                    if (dotdir * dotdir < sq_sin_tol * lengthSq3(e0_dir) * lengthSq3(e1_dir)) {
                        try addEdge(gpa, vertices, &out_edges, vopp0, vopp1, opts.shear_compliance);
                        is_shear = true;
                    }
                }
                switch (opts.bend_type) {
                    .none => {},
                    .distance => if (!is_shear) try addEdge(
                        gpa,
                        vertices,
                        &out_edges,
                        vopp0,
                        vopp1,
                        opts.bend_compliance,
                    ),
                    .dihedral => if (vertices[vopp0].inv_mass > 0.0 or vertices[vopp1].inv_mass > 0.0)
                        try out_bends.append(
                            gpa,
                            .{
                                .vertex = .{ e0.v[0], e0.v[1], vopp0, vopp1 },
                                .compliance = opts.bend_compliance,
                            },
                        ),
                }
            } else {
                i = j - 1;
                break;
            }
        }
        try addEdge(
            gpa,
            vertices,
            &out_edges,
            e0.v[0],
            e0.v[1],
            if (is_shear) opts.shear_compliance else opts.edge_compliance,
        );
    }

    return createSoftBodyShared(
        gpa,
        vertices,
        out_edges.items,
        out_bends.items,
        &[_]SoftVolume{},
        &[_]SoftLRA{},
        faces,
    );
}

/// Add a soft-body instance referencing `shared`, with its center of mass at `com_pos` and the asset
/// rotated by `rotation` (baked into the particle positions). Returns its index in world.soft_bodies.
pub fn addSoftBody(
    world: *World,
    gpa: std.mem.Allocator,
    shared: *const SoftBodyShared,
    com_pos: Vec,
    rotation: Quat,
) !usize {
    const verts: []SoftVertex = try gpa.alloc(SoftVertex, shared.vertices.len);
    var box: Aabb = .empty;
    for (shared.vertices, 0..) |sv, i| {
        const p: Vec = rotate(rotation, sv.position);
        verts[i] = .{
            .previous_position = p,
            .position = p,
            .velocity = rotate(rotation, sv.velocity),
            .inv_mass = sv.inv_mass,
        };
        box.encapsulate(p);
    }
    const sb: SoftBody = .{
        .shared = shared,
        .vertices = verts,
        .com_pos = com_pos,
        .local_bounds = box,
    };
    try world.soft_bodies.append(gpa, sb);
    return world.soft_bodies.items.len - 1;
}

/// World-space position of soft-body vertex `i` (its COM-relative position plus the body COM).
pub fn softBodyVertexWorld(sb: *const SoftBody, i: usize) Vec {
    return sb.com_pos + sb.vertices[i].position;
}

/// One rigid body the soft body may collide with this update (Jolt's CollidingShape). All vectors
/// are in the soft body's local frame (= world minus the soft body COM; the soft body has identity
/// rotation). Reaction impulses accumulate into linear_velocity / angular_velocity and are written
/// back to the rigid body after the substeps.
const SoftCollidingBody = struct {
    com_pos: Vec, // rigid body COM, in soft-local
    body: BodyIndex,
    motion_type: MotionType,
    inv_mass: f32,
    inv_inertia: Mat3,
    friction: f32,
    restitution: f32,
    soft_inv_mass_scale: f32,
    linear_velocity: Vec,
    angular_velocity: Vec,
    orig_linear_velocity: Vec,
    orig_angular_velocity: Vec,
    update_velocities: bool,
};

/// One leaf shape of a colliding body, posed in soft-local space, referencing its body record.
const SoftLeaf = struct {
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    body_idx: u32,
};

/// Collect the supported leaf shapes of `shape` (posed at pos/rot in soft-local) into `leaves`,
/// resolving decorators and recursing into compounds. Only sphere/box/capsule/plane have a soft-body
/// collision routine this stage; other shapes are skipped. Returns whether any leaf was added.
fn collectSoftLeaves(
    store: *const ShapeStore,
    shape: *const Shape,
    pos: Vec,
    rot: Quat,
    body_idx: u32,
    scratch: std.mem.Allocator,
    leaves: *std.ArrayListUnmanaged(SoftLeaf),
) !bool {
    const r: ResolvedShape = resolveDecorated(store, shape, pos, rot);
    switch (r.shape.*) {
        .sphere, .box, .capsule, .plane, .mesh, .heightfield => {
            try leaves.append(
                scratch,
                .{ .shape = r.shape, .pos = r.pos, .rot = r.rot, .body_idx = body_idx },
            );
            return true;
        },
        .compound => |comp| {
            var any: bool = false;
            for (comp.children) |child| {
                const cs: *const Shape = store.get(child.shape);
                const cpos: Vec = r.pos + rotate(r.rot, child.local_pos);
                const crot: Quat = qmul(r.rot, child.local_rot);
                if (try collectSoftLeaves(store, cs, cpos, crot, body_idx, scratch, leaves)) {
                    any = true;
                }
            }
            return any;
        },
        else => return false, // cylinder / hull / tapered / mesh / heightfield / empty: not yet supported
    }
}

/// Broadphase-query the rigid world around the soft body's predicted bounds and build the
/// colliding-body and leaf-shape lists (Jolt's DetermineCollidingShapes), all in soft-local space.
fn softBodyDetermineCollidingShapes(
    world: *World,
    sb: *const SoftBody,
    dt: f32,
    scratch: std.mem.Allocator,
    bodies: *std.ArrayListUnmanaged(SoftCollidingBody),
    leaves: *std.ArrayListUnmanaged(SoftLeaf),
) !void {
    var box: Aabb = .empty;
    for (sb.vertices) |v| {
        const wp: Vec = sb.com_pos + v.position;
        box.encapsulate(wp);
        box.encapsulate(wp + v.velocity * splat(dt));
    }
    const query_bounds: Aabb = box.expandedBy(sb.vertex_radius + 0.02);

    var nearby: std.ArrayListUnmanaged(BodyIndex) = .empty;
    try world.broadphase.queryAabb(scratch, query_bounds, &nearby);

    for (nearby.items) |bi| {
        const body: *const Body = &world.bodies.data[bi];
        if (body.is_sensor) {
            continue;
        } // soft body passes through sensors
        const m: *const Motion = &world.motion[bi];

        const body_idx: u32 = @intCast(bodies.items.len);
        var cb: SoftCollidingBody = .{
            .com_pos = body.com_pos - sb.com_pos,
            .body = bi,
            .motion_type = body.motion_type,
            .inv_mass = 0.0,
            .inv_inertia = Mat3.zero,
            .friction = @sqrt(sb.friction * body.friction),
            .restitution = @max(sb.restitution, body.restitution),
            .soft_inv_mass_scale = 1.0,
            .linear_velocity = vec_zero,
            .angular_velocity = vec_zero,
            .orig_linear_velocity = vec_zero,
            .orig_angular_velocity = vec_zero,
            .update_velocities = false,
        };
        if (body.motion_type == .dynamic) {
            cb.inv_mass = m.inv_mass;
            cb.inv_inertia = world.inv_inertia_world[bi];
            cb.linear_velocity = m.lin_vel;
            cb.orig_linear_velocity = m.lin_vel;
            cb.angular_velocity = m.ang_vel;
            cb.orig_angular_velocity = m.ang_vel;
        }

        const shape: *const Shape = world.shapes.get(body.shape);
        if (try collectSoftLeaves(&world.shapes, shape, cb.com_pos, body.rot, body_idx, scratch, leaves)) {
            try bodies.append(scratch, cb);
        }
    }
}

/// The nearest collision plane of a rigid leaf to a soft-body vertex, in soft-local space. `normal`
/// points out of the shape; `dist` is the plane constant (normal·x + dist = 0); `penetration` is how
/// far the vertex is inside (positive) or outside (negative). null for unsupported shapes.
const VertexPlane = struct { normal: Vec, dist: f32, penetration: f32 };

/// Result of softBodyClosestPtOnTri: the closest point and a feature bitmask (bit i set => vertex i).
const SoftTriClosest = struct { point: Vec, set: u8 };

/// Closest point on triangle (a,b,c) to p (Ericson, Real-Time Collision Detection), plus a bitmask of
/// which vertices form the closest feature (bit i set => vertex i): 0b001/0b010/0b100 a vertex,
/// 0b011/0b101/0b110 an edge, 0b111 the face interior.
fn softBodyClosestPtOnTri(
    p: Vec,
    a: Vec,
    b: Vec,
    c: Vec,
) SoftTriClosest {
    const ab: Vec = b - a;
    const ac: Vec = c - a;
    const ap: Vec = p - a;
    const d1: f32 = dot3(ab, ap);
    const d2: f32 = dot3(ac, ap);
    if (d1 <= 0.0 and d2 <= 0.0) {
        return .{ .point = a, .set = 0b001 };
    }
    const bp: Vec = p - b;
    const d3: f32 = dot3(ab, bp);
    const d4: f32 = dot3(ac, bp);
    if (d3 >= 0.0 and d4 <= d3) {
        return .{ .point = b, .set = 0b010 };
    }
    const vc: f32 = d1 * d4 - d3 * d2;
    if (vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0) {
        const t: f32 = d1 / (d1 - d3);
        return .{ .point = a + ab * splat(t), .set = 0b011 };
    }
    const cp: Vec = p - c;
    const d5: f32 = dot3(ab, cp);
    const d6: f32 = dot3(ac, cp);
    if (d6 >= 0.0 and d5 <= d6) {
        return .{ .point = c, .set = 0b100 };
    }
    const vb: f32 = d5 * d2 - d1 * d6;
    if (vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0) {
        const t: f32 = d2 / (d2 - d6);
        return .{ .point = a + ac * splat(t), .set = 0b101 };
    }
    const va: f32 = d3 * d6 - d5 * d4;
    if (va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0) {
        const t: f32 = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return .{ .point = b + (c - b) * splat(t), .set = 0b110 };
    }
    const denom: f32 = 1.0 / (va + vb + vc);
    const v: f32 = vb * denom;
    const w: f32 = vc * denom;
    return .{ .point = a + ab * splat(v) + ac * splat(w), .set = 0b111 };
}

/// Squared distance from point p to the axis-aligned box [lo, hi] (0 if inside).
fn softBodySqDistPointAabb(p: Vec, lo: Vec, hi: Vec) f32 {
    const d: Vec = @max(lo - p, vec_zero) + @max(p - hi, vec_zero);
    return dot3(d, d);
}

/// Build the collision plane for the closest triangle to a soft-body vertex (Jolt's
/// CollideSoftBodyVerticesVsTriangles::FinishVertex). All arguments are in soft-local space; `closest`
/// is the closest point on the triangle and `set` its feature bitmask. A face contact (set == 0b111)
/// is a two-sided plane gated by the triangle thickness; an edge/vertex contact is one-sided
/// (front-facing only) with negative penetration so the vertex radius can still produce contact.
fn softBodyTriContact(
    v0: Vec,
    v1: Vec,
    v2: Vec,
    vpos: Vec,
    closest: Vec,
    set: u8,
) ?VertexPlane {
    const tn: Vec = safeNormalize3(cross(v1 - v0, v2 - v0), vec(0, 1, 0));
    if (set == 0b111) {
        const penetration: f32 = dot3(tn, v0 - vpos);
        if (penetration < 0.1) {
            return .{ .normal = tn, .dist = -dot3(tn, v0), .penetration = penetration };
        }
        return null;
    }
    const nd: Vec = vpos - closest;
    if (dot3(nd, tn) <= 0.0) {
        return null;
    } // ignore back-facing edges
    const nl: f32 = length3(nd);
    const n: Vec = if (nl > 0.0) nd * splat(1.0 / nl) else tn;
    return .{ .normal = n, .dist = -dot3(n, closest), .penetration = -nl };
}

/// Deepest collision plane between a soft-body vertex and a triangle mesh leaf (Jolt's
/// MeshShape::CollideSoftBodyVertices): walk the mesh BVH pruning by distance to find the closest
/// triangle to the vertex, then build its contact plane.
fn softBodyCollideVertexVsMesh(
    mesh: *const Mesh,
    leaf_pos: Vec,
    leaf_rot: Quat,
    vpos: Vec,
) ?VertexPlane {
    if (mesh.nodes.len == 0) {
        return null;
    }
    const inv_rot: Quat = conjugate(leaf_rot);
    const local_pos: Vec = rotate(inv_rot, vpos - leaf_pos); // mesh-local query point

    var best_dist_sq: f32 = floatMax(f32);
    var best_v0: Vec = vec_zero;
    var best_v1: Vec = vec_zero;
    var best_v2: Vec = vec_zero;
    var best_closest: Vec = vec_zero;
    var best_set: u8 = 0;
    var found: bool = false;

    var stack: BvhStack = .{};
    stack.push(0);
    while (stack.pop()) |ni| {
        const node: MeshBvhNode = mesh.nodes[ni];
        if (softBodySqDistPointAabb(local_pos, node.bounds.min, node.bounds.max) >= best_dist_sq) {
            continue;
        }
        if (node.tri_count != 0) {
            var i: u32 = 0;
            while (i < node.tri_count) : (i += 1) {
                const tri: MeshTriangle = mesh.triangles[mesh.tri_order[node.first_tri + i]];
                const a: Vec = mesh.vertices[tri.v[0]];
                const b: Vec = mesh.vertices[tri.v[1]];
                const c: Vec = mesh.vertices[tri.v[2]];
                const cpt: SoftTriClosest = softBodyClosestPtOnTri(local_pos, a, b, c);
                const d2: f32 = lengthSq3(cpt.point - local_pos);
                if (d2 < best_dist_sq) {
                    best_dist_sq = d2;
                    best_v0 = a;
                    best_v1 = b;
                    best_v2 = c;
                    best_closest = cpt.point;
                    best_set = cpt.set;
                    found = true;
                }
            }
        } else {
            stack.push(node.left);
            stack.push(node.right);
        }
    }
    if (!found) {
        return null;
    }
    return softBodyTriContact(
        leaf_pos + rotate(leaf_rot, best_v0),
        leaf_pos + rotate(leaf_rot, best_v1),
        leaf_pos + rotate(leaf_rot, best_v2),
        vpos,
        leaf_pos + rotate(leaf_rot, best_closest),
        best_set,
    );
}

/// Deepest collision plane between a soft-body vertex and a height-field leaf (Jolt's
/// HeightFieldShape::CollideSoftBodyVertices): find the closest triangle among the cell under the
/// vertex and its neighbours, then build its contact plane.
fn softBodyCollideVertexVsHeightField(
    hf: *const HeightField,
    leaf_pos: Vec,
    leaf_rot: Quat,
    vpos: Vec,
) ?VertexPlane {
    if (hf.sample_count_x < 2 or hf.sample_count_z < 2) {
        return null;
    }
    const inv_rot: Quat = conjugate(leaf_rot);
    const local_pos: Vec = rotate(inv_rot, vpos - leaf_pos);
    const inv_cell: f32 = 1.0 / hf.cell_size;
    const max_cx: i64 = @as(i64, hf.sample_count_x) - 2;
    const max_cz: i64 = @as(i64, hf.sample_count_z) - 2;
    const ccx: i64 = clamp(floori(i64, local_pos[0] * inv_cell), 0, max_cx);
    const ccz: i64 = clamp(floori(i64, local_pos[2] * inv_cell), 0, max_cz);

    var best_dist_sq: f32 = floatMax(f32);
    var best_v0: Vec = vec_zero;
    var best_v1: Vec = vec_zero;
    var best_v2: Vec = vec_zero;
    var best_closest: Vec = vec_zero;
    var best_set: u8 = 0;
    var found: bool = false;

    var dz: i64 = -1;
    while (dz <= 1) : (dz += 1) {
        const cz: i64 = ccz + dz;
        if (cz < 0 or cz > max_cz) {
            continue;
        }
        var dx: i64 = -1;
        while (dx <= 1) : (dx += 1) {
            const cx: i64 = ccx + dx;
            if (cx < 0 or cx > max_cx) {
                continue;
            }
            const gx: u32 = @intCast(cx);
            const gz: u32 = @intCast(cz);
            const a: Vec = hfVertex(hf, gx, gz);
            const b: Vec = hfVertex(hf, gx + 1, gz);
            const c: Vec = hfVertex(hf, gx, gz + 1);
            const d: Vec = hfVertex(hf, gx + 1, gz + 1);
            // Two triangles per cell, matching collideHeightFieldLeaf's winding: (a, d, b) and (a, c, d).
            const tris: [2][3]Vec = .{ .{ a, d, b }, .{ a, c, d } };
            for (tris) |t| {
                const cpt: SoftTriClosest = softBodyClosestPtOnTri(local_pos, t[0], t[1], t[2]);
                const d2: f32 = lengthSq3(cpt.point - local_pos);
                if (d2 < best_dist_sq) {
                    best_dist_sq = d2;
                    best_v0 = t[0];
                    best_v1 = t[1];
                    best_v2 = t[2];
                    best_closest = cpt.point;
                    best_set = cpt.set;
                    found = true;
                }
            }
        }
    }
    if (!found) {
        return null;
    }
    return softBodyTriContact(
        leaf_pos + rotate(leaf_rot, best_v0),
        leaf_pos + rotate(leaf_rot, best_v1),
        leaf_pos + rotate(leaf_rot, best_v2),
        vpos,
        leaf_pos + rotate(leaf_rot, best_closest),
        best_set,
    );
}

fn softBodyCollideVertexVsLeaf(leaf: SoftLeaf, vpos: Vec) ?VertexPlane {
    switch (leaf.shape.*) {
        .plane => |pl| {
            const n: Vec = rotate(leaf.rot, pl.normal);
            const pt: Vec = leaf.pos + rotate(leaf.rot, pl.normal * splat(-pl.distance));
            const dist: f32 = -dot3(n, pt);
            const penetration: f32 = -(dot3(n, vpos) + dist);
            return .{ .normal = n, .dist = dist, .penetration = penetration };
        },
        .sphere => |s| {
            const center: Vec = leaf.pos;
            const delta: Vec = vpos - center;
            const dlen: f32 = length3(delta);
            const penetration: f32 = s.radius - dlen;
            const normal: Vec = if (dlen > 0.0) delta * splat(1.0 / dlen) else vec(0, 1, 0);
            const point: Vec = center + normal * splat(s.radius);
            return .{ .normal = normal, .dist = -dot3(normal, point), .penetration = penetration };
        },
        .box => |b| {
            const inv_rot: Quat = conjugate(leaf.rot);
            const local_pos: Vec = rotate(inv_rot, vpos - leaf.pos);
            const he: Vec = b.half_extent;
            const clamped: Vec = clamp(local_pos, vec_zero - he, he);
            const inside: bool = local_pos[0] == clamped[0] and
                local_pos[1] == clamped[1] and
                local_pos[2] == clamped[2];
            var normal_local: Vec = undefined;
            var point_local: Vec = undefined;
            var penetration: f32 = undefined;
            if (inside) {
                const delta: Vec = he - @abs(local_pos);
                var index: usize = 0;
                if (delta[1] < vlane(delta, index)) {
                    index = 1;
                }
                if (delta[2] < vlane(delta, index)) {
                    index = 2;
                }
                penetration = vlane(delta, index);
                const axes: [3]Vec = .{ vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1) };
                const sgn: f32 = if (vlane(local_pos, index) >= 0.0) 1.0 else -1.0;
                normal_local = axes[index] * splat(sgn);
                point_local = normal_local * he;
            } else {
                const nrm: Vec = local_pos - clamped;
                const len: f32 = length3(nrm);
                penetration = -len;
                normal_local = if (len > 0.0) nrm * splat(1.0 / len) else vec(0, 1, 0);
                point_local = clamped;
            }
            const n: Vec = rotate(leaf.rot, normal_local);
            const pt: Vec = leaf.pos + rotate(leaf.rot, point_local);
            return .{ .normal = n, .dist = -dot3(n, pt), .penetration = penetration };
        },
        .capsule => |c| {
            const inv_rot: Quat = conjugate(leaf.rot);
            const local_pos: Vec = rotate(inv_rot, vpos - leaf.pos);
            var normal_local: Vec = undefined;
            var point_local: Vec = undefined;
            var penetration: f32 = undefined;
            if (@abs(local_pos[1]) <= c.half_height) {
                var radial: Vec = local_pos;
                radial[1] = 0.0;
                const rl: f32 = length3(radial);
                penetration = c.radius - rl;
                normal_local = if (rl > 0.0) radial * splat(1.0 / rl) else vec(1, 0, 0);
                point_local = normal_local * splat(c.radius);
            } else {
                const cap_y: f32 = if (local_pos[1] > 0.0) c.half_height else -c.half_height;
                const center: Vec = vec(0, cap_y, 0);
                const delta: Vec = local_pos - center;
                const dlen: f32 = length3(delta);
                penetration = c.radius - dlen;
                normal_local = if (dlen > 0.0) delta * splat(1.0 / dlen) else vec(0, 1, 0);
                point_local = center + normal_local * splat(c.radius);
            }
            const n: Vec = rotate(leaf.rot, normal_local);
            const pt: Vec = leaf.pos + rotate(leaf.rot, point_local);
            return .{ .normal = n, .dist = -dot3(n, pt), .penetration = penetration };
        },
        .mesh => |m| return softBodyCollideVertexVsMesh(&m, leaf.pos, leaf.rot, vpos),
        .heightfield => |hf| return softBodyCollideVertexVsHeightField(&hf, leaf.pos, leaf.rot, vpos),
        else => return null,
    }
}

/// For each vertex, find the deepest collision plane over all rigid leaves (Jolt's
/// DetermineCollisionPlanes). Vertices that are outside but within the vertex radius are still
/// recorded (their penetration is negative), so the radius can be applied during the solve.
fn softBodyDetermineCollisionPlanes(sb: *SoftBody, leaves: []const SoftLeaf) void {
    for (sb.vertices) |*v| {
        if (v.inv_mass <= 0.0) {
            continue;
        }
        for (leaves) |leaf| {
            if (softBodyCollideVertexVsLeaf(leaf, v.position)) |vp| {
                if (vp.penetration > v.largest_penetration) {
                    v.largest_penetration = vp.penetration;
                    v.collision_normal = vp.normal;
                    v.collision_dist = vp.dist;
                    v.colliding_body = @intCast(leaf.body_idx);
                }
            }
        }
    }
}

/// Recover each vertex velocity from the position change, then resolve contacts (Jolt's
/// ApplyCollisionConstraintsAndUpdateVelocities): push penetrating vertices out along the collision
/// plane, apply Coulomb friction and restitution, and for dynamic ground accumulate an equal and
/// opposite reaction into the colliding body. Runs once per substep.
fn softBodyApplyCollision(
    sb: *SoftBody,
    bodies: []SoftCollidingBody,
    sub_dt: f32,
    gravity: Vec,
) void {
    const restitution_threshold: f32 = -2.0 * length3(gravity) * sub_dt;
    const inv_sub_dt: f32 = 1.0 / sub_dt;
    const vertex_radius: f32 = sb.vertex_radius;
    for (sb.vertices) |*v| {
        if (v.inv_mass <= 0.0) {
            continue;
        }
        const prev_v: Vec = v.velocity;
        v.velocity = (v.position - v.previous_position) * splat(inv_sub_dt);

        if (v.colliding_body < 0) {
            continue;
        }
        const signed: f32 = dot3(v.collision_normal, v.position) + v.collision_dist;
        const projected_distance: f32 = -signed + vertex_radius;
        if (projected_distance <= 0.0) {
            continue;
        }
        v.has_contact = true;
        const cb: *SoftCollidingBody = &bodies[@intCast(v.colliding_body)];
        const contact_normal: Vec = v.collision_normal;
        v.position = v.position + contact_normal * splat(projected_distance);

        if (cb.motion_type == .dynamic) {
            const r2: Vec = v.position - cb.com_pos;
            const v2: Vec = cb.linear_velocity + cross(cb.angular_velocity, r2);
            const relative_velocity: Vec = v.velocity - v2;
            const v_normal: Vec = contact_normal * splat(dot3(contact_normal, relative_velocity));
            const v_tangential: Vec = relative_velocity - v_normal;
            const v_tangential_length: f32 = length3(v_tangential);
            const vertex_inv_mass: f32 = cb.soft_inv_mass_scale * v.inv_mass;
            const r2_cross_n: Vec = cross(r2, contact_normal);
            const w2: f32 = cb.inv_mass + dot3(r2_cross_n, cb.inv_inertia.mulVec(r2_cross_n));
            const w1_plus_w2: f32 = vertex_inv_mass + w2;
            if (w1_plus_w2 > 0.0) {
                var dv: Vec = if (v_tangential_length > 0.0)
                    v_tangential * splat(@min(cb.friction * projected_distance /
                        (v_tangential_length * sub_dt), 1.0))
                else
                    vec_zero;
                dv = dv + v_normal;
                const prev_v_normal: f32 = dot3(prev_v - v2, contact_normal);
                if (prev_v_normal < restitution_threshold) {
                    dv = dv + contact_normal * splat(cb.restitution * prev_v_normal);
                }
                const p: Vec = dv * splat(1.0 / w1_plus_w2);
                v.velocity = v.velocity - p * splat(vertex_inv_mass);
                cb.linear_velocity = cb.linear_velocity + p * splat(cb.inv_mass);
                cb.angular_velocity = cb.angular_velocity + cb.inv_inertia.mulVec(cross(r2, p));
                cb.update_velocities = true;
            }
        } else if (cb.soft_inv_mass_scale > 0.0) {
            const v_normal: Vec = contact_normal * splat(dot3(contact_normal, v.velocity));
            const v_tangential: Vec = v.velocity - v_normal;
            const v_tangential_length: f32 = length3(v_tangential);
            if (v_tangential_length > 0.0) {
                const friction_scale: f32 = @min(cb.friction * projected_distance /
                    (v_tangential_length * sub_dt), 1.0);
                v.velocity = v.velocity - v_tangential * splat(friction_scale);
            }
            v.velocity = v.velocity - v_normal;
            const prev_v_normal: f32 = dot3(prev_v, contact_normal);
            if (prev_v_normal < restitution_threshold) {
                v.velocity = v.velocity - contact_normal * splat(cb.restitution * prev_v_normal);
            }
        }
    }
}

/// Write the accumulated reaction back to the dynamic rigid bodies the soft body pushed against
/// (Jolt's UpdateRigidBodyVelocities). The soft body has identity rotation, so the local-frame
/// velocity delta is already in world space.
fn softBodyUpdateRigidVelocities(world: *World, bodies: []const SoftCollidingBody) !void {
    for (bodies) |cb| {
        if (!cb.update_velocities) {
            continue;
        }
        const m: *Motion = &world.motion[cb.body];
        m.lin_vel = m.lin_vel + (cb.linear_velocity - cb.orig_linear_velocity);
        m.ang_vel = m.ang_vel + (cb.angular_velocity - cb.orig_angular_velocity);
        try world.wakeBody(world.allocator, cb.body);
    }
}

/// Six times the signed volume enclosed by the surface faces (Jolt's GetVolumeTimesSix), taking the
/// COM (the origin of the COM-relative positions) as the apex of each tetrahedron.
fn softBodyVolumeTimesSix(sb: *const SoftBody) f32 {
    var six_volume: f32 = 0.0;
    for (sb.shared.faces) |face| {
        const x1: Vec = sb.vertices[face.vertex[0]].position;
        const x2: Vec = sb.vertices[face.vertex[1]].position;
        const x3: Vec = sb.vertices[face.vertex[2]].position;
        six_volume += dot3(cross(x1, x2), x3);
    }
    return six_volume;
}

/// Apply internal pressure as a per-substep velocity impulse pushing each face outward along its
/// (area-weighted) normal (Jolt's ApplyPressure). Scaled by 1/volume so the inflation eases off as
/// the closed mesh expands; only acts when the enclosed volume is positive.
fn softBodyApplyPressure(sb: *SoftBody, sub_dt: f32) void {
    if (sb.pressure <= 0.0) {
        return;
    }
    const six_volume: f32 = softBodyVolumeTimesSix(sb);
    if (six_volume <= 0.0) {
        return;
    }
    const coefficient: f32 = sb.pressure * sub_dt / six_volume;
    for (sb.shared.faces) |face| {
        const x1: Vec = sb.vertices[face.vertex[0]].position;
        const x2: Vec = sb.vertices[face.vertex[1]].position;
        const x3: Vec = sb.vertices[face.vertex[2]].position;
        const impulse: Vec = cross(x2 - x1, x3 - x1) * splat(coefficient);
        for (face.vertex) |i| {
            const v: *SoftVertex = &sb.vertices[i];
            v.velocity = v.velocity + impulse * splat(v.inv_mass);
        }
    }
}

/// Finalize after the substeps (Jolt's UpdateSoftBodyState, Stage 1 subset): clamp per-vertex
/// velocity, derive the body-level linear/angular velocity from the particle average, recompute the
/// local bounds, and (if update_position) shift the COM to track the particle centroid.
fn softBodyUpdateState(sb: *SoftBody) void {
    const max_v_sq: f32 = sb.max_linear_speed * sb.max_linear_speed;
    var lin: Vec = vec_zero;
    var ang: Vec = vec_zero;
    var box: Aabb = .empty;
    for (sb.vertices) |*v| {
        const v_sq: f32 = lengthSq3(v.velocity);
        if (v_sq > max_v_sq and v_sq > 0.0) {
            v.velocity = v.velocity * splat(@sqrt(max_v_sq / v_sq));
        }
        lin = lin + v.velocity;
        ang = ang + cross(v.position, v.velocity);
        box.encapsulate(v.position);
    }
    const inv_n: f32 = 1.0 / float(sb.vertices.len);
    sb.linear_velocity = lin * splat(inv_n);
    sb.angular_velocity = ang * splat(inv_n);

    if (sb.update_position) {
        const c: Vec = box.center();
        sb.com_pos = sb.com_pos + c;
        for (sb.vertices) |*v| {
            v.position = v.position - c;
        }
        box = box.translate(vec_zero - c);
    }
    sb.local_bounds = box;
}

/// Advance a soft body by `dt` (Jolt's SoftBodyMotionProperties::CustomUpdate). Gathers nearby rigid
/// bodies and the deepest collision plane per vertex, then runs num_iterations XPBD substeps; each
/// integrates gravity + predicts positions, solves the volume then edge constraints once, and
/// resolves collisions while recovering velocities. Finishes by clamping velocities, deriving the
/// body-level linear/angular velocity, recentering the COM, and writing reactions back to the rigid
/// bodies it pushed against.
pub fn softBodyUpdate(
    world: *World,
    sb: *SoftBody,
    dt: f32,
    scratch: std.mem.Allocator,
) !void {
    if (!sb.enabled or sb.vertices.len == 0 or sb.num_iterations == 0) {
        return;
    }

    const gravity: Vec = world.gravity * splat(sb.gravity_scale);
    const sub_dt: f32 = dt / float(sb.num_iterations);
    if (sub_dt <= 0.0) {
        return;
    }
    const inv_dt_sq: f32 = 1.0 / (sub_dt * sub_dt);
    const damping: f32 = @max(0.0, 1.0 - sb.linear_damping * sub_dt);
    const sub_gravity: Vec = gravity * splat(sub_dt);

    // Reset per-vertex collision state, then gather nearby rigid leaves and find the deepest
    // collision plane per vertex (from the start-of-update positions, once, as Jolt does).
    for (sb.vertices) |*v| {
        v.largest_penetration = -3.0e38;
        v.colliding_body = -1;
        v.has_contact = false;
    }
    var bodies: std.ArrayListUnmanaged(SoftCollidingBody) = .empty;
    var leaves: std.ArrayListUnmanaged(SoftLeaf) = .empty;
    try softBodyDetermineCollidingShapes(world, sb, dt, scratch, &bodies, &leaves);
    softBodyDetermineCollisionPlanes(sb, leaves.items);

    var iteration: u32 = 0;
    while (iteration < sb.num_iterations) : (iteration += 1) {
        // Internal pressure (Jolt's StartNextIteration applies it just before integration).
        softBodyApplyPressure(sb, sub_dt);

        // Integrate positions (apply gravity + damping to velocity, predict position).
        for (sb.vertices) |*v| {
            if (v.inv_mass > 0.0) {
                v.velocity = (v.velocity + sub_gravity) * splat(damping);
            }
            v.previous_position = v.position;
            v.position = v.position + v.velocity * splat(sub_dt);
        }

        // Solve constraints once (Jolt's ProcessGroup order: volume, then edge).
        for (sb.shared.volumes) |tet| {
            const p1: *SoftVertex = &sb.vertices[tet.vertex[0]];
            const p2: *SoftVertex = &sb.vertices[tet.vertex[1]];
            const p3: *SoftVertex = &sb.vertices[tet.vertex[2]];
            const p4: *SoftVertex = &sb.vertices[tet.vertex[3]];
            const x1: Vec = p1.position;
            const x2: Vec = p2.position;
            const x3: Vec = p3.position;
            const x4: Vec = p4.position;
            const x1x2: Vec = x2 - x1;
            const x1x3: Vec = x3 - x1;
            const x1x4: Vec = x4 - x1;
            const c: f32 = @abs(dot3(cross(x1x2, x1x3), x1x4)) - tet.six_rest_volume;
            const d1c: Vec = cross(x4 - x2, x3 - x2);
            const d2c: Vec = cross(x1x3, x1x4);
            const d3c: Vec = cross(x1x4, x1x2);
            const d4c: Vec = cross(x1x2, x1x3);
            const denom: f32 = p1.inv_mass * lengthSq3(d1c) + p2.inv_mass * lengthSq3(d2c) +
                p3.inv_mass * lengthSq3(d3c) +
                p4.inv_mass * lengthSq3(d4c) +
                tet.compliance * inv_dt_sq;
            if (denom < 1.0e-12) {
                continue;
            }
            const minus_lambda: f32 = c / denom;
            p1.position = x1 - d1c * splat(minus_lambda * p1.inv_mass);
            p2.position = x2 - d2c * splat(minus_lambda * p2.inv_mass);
            p3.position = x3 - d3c * splat(minus_lambda * p3.inv_mass);
            p4.position = x4 - d4c * splat(minus_lambda * p4.inv_mass);
        }
        for (sb.shared.bends) |b| {
            const p0: *SoftVertex = &sb.vertices[b.vertex[0]];
            const p1: *SoftVertex = &sb.vertices[b.vertex[1]];
            const p2: *SoftVertex = &sb.vertices[b.vertex[2]];
            const p3: *SoftVertex = &sb.vertices[b.vertex[3]];
            const x0: Vec = p0.position;
            const x1b: Vec = p1.position;
            const x2: Vec = p2.position;
            const x3: Vec = p3.position;
            const edge_vec: Vec = x1b - x0;
            const e_len: f32 = length3(edge_vec);
            if (e_len < 1.0e-6) {
                continue;
            }
            const x1x2: Vec = x2 - x1b;
            const x1x3: Vec = x3 - x1b;
            var n1: Vec = cross(x2 - x0, x1x2);
            var n2: Vec = cross(x1x3, x3 - x0);
            const n1_len_sq: f32 = lengthSq3(n1);
            const n2_len_sq: f32 = lengthSq3(n2);
            const prod: f32 = n1_len_sq * n2_len_sq;
            if (prod < 1.0e-24) {
                continue;
            }
            const sign: f32 = if (dot3(cross(n2, n1), edge_vec) < 0.0) -1.0 else 1.0;
            const dval: f32 = @max(-1.0, @min(1.0, dot3(n1, n2) / @sqrt(prod)));
            // Fold onto half a turn either side. One subtraction of the nearest whole turn,
            // exact and branchless - and unlike the two-branch radian form it is correct however
            // far out `initial_angle` puts the difference, rather than for one turn only.
            const c_turns: f32 = turnsFromRad(sign * acosRad(dval) - b.initial_angle);
            const c: f32 = radFromTurns(c_turns - @round(c_turns));
            n1 = n1 * splat(1.0 / n1_len_sq);
            n2 = n2 * splat(1.0 / n2_len_sq);
            const d0c: Vec = (n1 * splat(dot3(x1x2, edge_vec)) +
                n2 * splat(dot3(x1x3, edge_vec))) * splat(1.0 / e_len);
            const d2c: Vec = n1 * splat(e_len);
            const d3c: Vec = n2 * splat(e_len);
            const d1c: Vec = (vec_zero - d0c) - d2c - d3c;
            const denom: f32 = p0.inv_mass * lengthSq3(d0c) + p1.inv_mass * lengthSq3(d1c) +
                p2.inv_mass * lengthSq3(d2c) + p3.inv_mass * lengthSq3(d3c) + b.compliance * inv_dt_sq;
            if (denom < 1.0e-12) {
                continue;
            }
            const minus_lambda: f32 = c / denom;
            p0.position = x0 - d0c * splat(minus_lambda * p0.inv_mass);
            p1.position = x1b - d1c * splat(minus_lambda * p1.inv_mass);
            p2.position = x2 - d2c * splat(minus_lambda * p2.inv_mass);
            p3.position = x3 - d3c * splat(minus_lambda * p3.inv_mass);
        }
        for (sb.shared.edges) |e| {
            const v0: *SoftVertex = &sb.vertices[e.vertex[0]];
            const v1: *SoftVertex = &sb.vertices[e.vertex[1]];
            const x0: Vec = v0.position;
            const x1e: Vec = v1.position;
            const delta: Vec = x1e - x0;
            const length: f32 = length3(delta);
            const denom: f32 = length * (v0.inv_mass + v1.inv_mass + e.compliance * inv_dt_sq);
            if (denom < 1.0e-12) {
                continue;
            }
            const correction: Vec = delta * splat((length - e.rest_length) / denom);
            v0.position = x0 + correction * splat(v0.inv_mass);
            v1.position = x1e - correction * splat(v1.inv_mass);
        }
        for (sb.shared.lra) |l| {
            const anchor: Vec = sb.vertices[l.vertex[0]].position;
            const vd: *SoftVertex = &sb.vertices[l.vertex[1]];
            const delta: Vec = vd.position - anchor;
            const delta_len_sq: f32 = lengthSq3(delta);
            if (delta_len_sq > l.max_distance * l.max_distance and delta_len_sq > 0.0) {
                vd.position = anchor + delta * splat(l.max_distance / @sqrt(delta_len_sq));
            }
        }

        // Recover velocity from the position change and resolve contacts (push-out, friction,
        // restitution, and an equal-and-opposite reaction on dynamic bodies).
        softBodyApplyCollision(sb, bodies.items, sub_dt, gravity);
    }

    softBodyUpdateState(sb);
    try softBodyUpdateRigidVelocities(world, bodies.items);
}

pub fn step(world: *World, dt: f32) !void {
    if (dt <= 0.0) {
        return;
    }
    // Per-step transient buffers come from a World-owned arena (reset each step), so the public
    // call is `step(world, dt)` like the 2D engine. Reusing the arena across steps mirrors Jolt's
    // persistent TempAllocator; `scratch` stays a plain Allocator below, so the body is unchanged.
    _ = world.scratch_arena.reset(.retain_capacity);
    const scratch: std.mem.Allocator = world.scratch_arena.allocator();
    const zstep: profiler.Zone = profiler.zoneNamed(@src(), "physics.step");
    defer zstep.end();

    const s: Settings = world.settings;
    const gravity: Vec = world.gravity;
    const active: []const BodyIndex = world.active.items;
    const warm_start_ratio: f32 = if (world.prev_dt > 0.0) dt / world.prev_dt else 0.0;

    var contacts: std.ArrayListUnmanaged(Contact) = .empty;

    // -------------------------------------------------------------------------
    // PHASE 1 - bake world-space inverse inertia for active bodies (one mat3 each).
    // -------------------------------------------------------------------------
    {
        for (active) |idx| {
            const body: *const Body = &world.bodies.data[idx];
            const m: *const Motion = &world.motion[idx];
            if (m.inv_mass > 0.0) {
                const inv_diagonal: Vec = m.inv_inertia_diagonal;
                const inertia_rotation: Quat = m.inertia_rotation;
                world.inv_inertia_world[idx] = bakeInvInertiaWorld(body.rot, inv_diagonal, inertia_rotation);
            } else {
                world.inv_inertia_world[idx] = Mat3.zero; // kinematic: no angular response
            }
        }
    }

    // -------------------------------------------------------------------------
    // PHASE 2 - apply gravity, accumulated force/torque, damping; clamp velocity.
    // Matches Jolt's ApplyGyroscopicForceInternal + ApplyForceTorqueAndDragInternal.
    // Forces are NOT reset here (Phase 8 does that) because the contact-setup
    // restitution correction in Phase 4 needs GetAccumulatedForce().
    // -------------------------------------------------------------------------
    {
        for (active) |idx| {
            const m: *Motion = &world.motion[idx];
            if (m.inv_mass == 0.0) {
                continue;
            } // kinematic: velocity is user-driven

            const body: *const Body = &world.bodies.data[idx];
            if (m.apply_gyroscopic) {
                m.ang_vel = applyGyroscopic(
                    m.ang_vel,
                    body.rot,
                    m.inv_inertia_diagonal,
                    m.inertia_rotation,
                    dt,
                );
            }

            const inv_i: Mat3 = world.inv_inertia_world[idx];
            const accel_gravity: Vec = gravity * splat(m.gravity_scale);
            const accel_force: Vec = m.force * splat(m.inv_mass);
            const lin_accel: Vec = accel_gravity + accel_force;
            const ang_accel: Vec = inv_i.mulVec(m.torque);

            m.lin_vel += lin_accel * splat(dt);
            m.ang_vel += ang_accel * splat(dt);

            const lin_decay: f32 = @max(0.0, 1.0 - m.linear_damping * dt);
            const ang_decay: f32 = @max(0.0, 1.0 - m.angular_damping * dt);
            m.lin_vel *= splat(lin_decay);
            m.ang_vel *= splat(ang_decay);

            m.lin_vel = clampMagnitude(m.lin_vel, m.max_linear_speed);
            m.ang_vel = clampMagnitude(m.ang_vel, m.max_angular_speed);
        }
    }

    // -------------------------------------------------------------------------
    // PHASE 3 - refit moved bodies in the broad phase, collect candidate pairs.
    // -------------------------------------------------------------------------
    var pairs: std.ArrayListUnmanaged(BodyPair) = .empty;
    {
        const zp3: profiler.Zone = profiler.zoneNamed(@src(), "broadphase");
        defer zp3.end();
        for (active) |idx| {
            const body: *const Body = &world.bodies.data[idx];
            const displacement: Vec = world.motion[idx].lin_vel * splat(dt);
            _ = try world.broadphase.moveProxy(
                world.allocator,
                body.broadphase_node,
                body.bounds,
                displacement,
            );
        }
        try world.broadphase.findPairs(scratch, &pairs);
    }

    // -------------------------------------------------------------------------
    // PHASE 3.5 - build islands (union-find over the contact graph) and wake any
    // sleeping body that a still-awake body now touches. Static bodies are NOT
    // linked, so two piles resting on the same floor remain separate islands. The
    // sleeping pile's own internal contacts are re-found by the broad phase every
    // step, so one awake touch propagates through the whole island in a single step.
    // -------------------------------------------------------------------------
    const parent: []u32 = world.island_parent;
    const island_awake: []bool = world.island_awake;
    const body_count: u32 = world.bodies.watermark;
    {
        var i: u32 = 0;
        while (i < body_count) : (i += 1) {
            parent[i] = i;
            island_awake[i] = false;
        }

        // Link movable/movable pairs (a static endpoint is left out of the graph).
        // Pairs that can't actually collide are not linked, so filtering keeps their
        // islands (and therefore their sleeping) independent.
        for (pairs.items) |pair| {
            const body_a: *const Body = &world.bodies.data[pair.a];
            const body_b: *const Body = &world.bodies.data[pair.b];
            const a_movable: bool = body_a.motion_type != .static;
            const b_movable: bool = body_b.motion_type != .static;
            if (a_movable and b_movable and bodiesShouldCollide(body_a, body_b)) {
                dsuUnion(parent, pair.a, pair.b);
            }
        }

        // Jointed bodies share an island too, so a constraint keeps both ends awake
        // together (and asleep together).
        for (world.constraints.items) |constraint| {
            if (!constraint.enabled) {
                continue;
            }
            const body_a: *const Body = &world.bodies.data[constraint.body_a];
            const body_b: *const Body = &world.bodies.data[constraint.body_b];
            if (body_a.motion_type != .static and body_b.motion_type != .static) {
                dsuUnion(parent, constraint.body_a, constraint.body_b);
            }
        }

        // An island is awake if any current member is awake (active = not asleep).
        for (active) |idx| {
            island_awake[dsuFind(parent, idx)] = true;
        }

        // Wake sleeping bodies whose island is awake (reached by something moving).
        for (pairs.items) |pair| {
            const pair_bodies = [_]BodyIndex{ pair.a, pair.b };
            for (pair_bodies) |idx| {
                const body: *Body = &world.bodies.data[idx];
                if (body.asleep and island_awake[dsuFind(parent, idx)]) {
                    body.asleep = false;
                    try world.active.append(world.allocator, idx);
                    const shape: *const Shape = world.shapes.get(body.shape);
                    resetSleepSpheres(&world.motion[idx], sleepTestPoints(body.com_pos, body.rot, shape));
                    // Woken mid-step: it missed Phase 1, so bake its world inverse
                    // inertia now (it intentionally skips this step's gravity, exactly
                    // as a body activated during Jolt's collision phase does).
                    const wm: *const Motion = &world.motion[idx];
                    world.inv_inertia_world[idx] = if (wm.inv_mass > 0.0)
                        bakeInvInertiaWorld(body.rot, wm.inv_inertia_diagonal, wm.inertia_rotation)
                    else
                        Mat3.zero;
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // PHASE 4 - narrow phase + contact setup. Builds every contact and computes its
    // properties reading POST-GRAVITY, PRE-WARM-START velocities (so the restitution
    // bias is computed exactly as Jolt's CalculateNonPenetrationConstraintProperties).
    // No velocities are mutated here; warm starting is the separate Phase 4b.
    // -------------------------------------------------------------------------
    {
        const zp4: profiler.Zone = profiler.zoneNamed(@src(), "narrowphase");
        defer zp4.end();
        // Reused across pairs: the leaf manifolds collideShapes produces for a pair.
        var submanifolds: std.ArrayListUnmanaged(SubCollision) = .empty;
        for (pairs.items) |pair| {
            const a: BodyIndex = pair.a;
            const b: BodyIndex = pair.b;
            const body_a: *const Body = &world.bodies.data[a];
            const body_b: *const Body = &world.bodies.data[b];
            const is_sensor_pair: bool = body_a.is_sensor or body_b.is_sensor;
            // Without a listener a sensor overlap has no response and no events to fire,
            // so there is nothing to do for it (matches the previous behaviour exactly).
            if (is_sensor_pair and world.contact_listener == null) {
                continue;
            }
            if (!bodiesShouldCollide(body_a, body_b)) {
                continue;
            }

            const ma: *const Motion = &world.motion[a];
            const mb: *const Motion = &world.motion[b];
            // At least one body must be able to respond (have finite mass). This drops
            // static/static, static/kinematic and kinematic/kinematic pairs that the
            // tree reports but that this solver could carry no impulse across.
            //
            // Two opt-outs. Sensor pairs skip it so an overlap between otherwise-immovable
            // bodies is still reported. And so does `report_immovable_contacts`, for a body
            // whose motion is owned by something outside this engine: the pair carries no
            // impulse HERE, but its owner still has to know about it, and only they can
            // decide what to do. Unlike a sensor, such a body keeps its normal response
            // against dynamic bodies.
            const report_immovable: bool =
                body_a.report_immovable_contacts or body_b.report_immovable_contacts;
            if (!is_sensor_pair and !report_immovable and ma.inv_mass == 0.0 and mb.inv_mass == 0.0) {
                continue;
            }

            // Skip contacts whose island is asleep. A static endpoint isn't in the
            // graph, so test both roots: at least one must belong to an awake island.
            if (!island_awake[dsuFind(parent, a)] and !island_awake[dsuFind(parent, b)]) {
                continue;
            }

            // Contact validation: let the listener veto this pair before any work.
            if (world.contact_listener) |cl| {
                if (cl.on_contact_validate) |validate| {
                    if (validate(cl.context, world, a, b) == .reject) {
                        continue;
                    }
                }
            }

            const shape_a: *const Shape = world.shapes.get(body_a.shape);
            const shape_b: *const Shape = world.shapes.get(body_b.shape);

            // Decompose any compound into leaf manifolds (one entry for a leaf-leaf
            // pair), then build a contact constraint for each.
            submanifolds.clearRetainingCapacity();
            try collideShapes(
                &world.shapes,
                shape_a,
                body_a.com_pos,
                body_a.rot,
                shape_b,
                body_b.com_pos,
                body_b.rot,
                s.speculative_distance,
                .collide_back_faces,
                &submanifolds,
                scratch,
            );
            for (submanifolds.items) |sm| {
                // Per-contact settings the listener may tune; default to the body-combined
                // values. Fire added/persisted and record the pair so contact-removed can
                // be derived after the loop. Sensor pairs do only this (no solver contact).
                var settings: ContactSettings = .{};
                if (world.contact_listener) |cl| {
                    const key: ManifoldKey = .{ .a = a, .b = b, .sub = sm.sub };
                    const touched_before: bool = world.contacts_prev.contains(key);
                    try world.contacts_curr.put(world.allocator, key, {});
                    if (touched_before) {
                        if (cl.on_contact_persisted) |cb| {
                            cb(cl.context, world, a, b, sm.sub, &sm.manifold, &settings);
                        }
                    } else {
                        if (cl.on_contact_added) |cb| {
                            cb(cl.context, world, a, b, sm.sub, &sm.manifold, &settings);
                        }
                    }
                }
                // Solver response, unless this is a sensor pair or the listener turned this
                // one contact into a sensor (e.g. a one-way platform).
                if (!is_sensor_pair and !settings.is_sensor) {
                    try setupContactFromManifold(
                        world,
                        &contacts,
                        scratch,
                        a,
                        b,
                        body_a,
                        body_b,
                        ma,
                        mb,
                        sm.manifold,
                        sm.sub,
                        settings,
                        dt,
                        s,
                        gravity,
                    );
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // PHASE 4a - contact-removed events: any sub-shape pair that touched last frame but
    // not this one has separated. A pair that was skipped only because it is asleep is
    // carried forward (frozen) rather than reported as separated. This frame's set then
    // becomes next frame's baseline. (No-op, and no allocation, without a listener.)
    // -------------------------------------------------------------------------
    if (world.contact_listener) |cl| {
        var it: @TypeOf(world.contacts_prev).Iterator = world.contacts_prev.iterator();
        while (it.next()) |entry| {
            const key: ManifoldKey = entry.key_ptr.*;
            if (world.contacts_curr.contains(key)) {
                continue;
            } // still touching
            if (world.bodies.data[key.a].asleep or world.bodies.data[key.b].asleep) {
                try world.contacts_curr.put(world.allocator, key, {}); // frozen by sleep
                continue;
            }
            if (cl.on_contact_removed) |cb| {
                cb(cl.context, key.a, key.b, key.sub);
            }
        }
        std.mem.swap(@TypeOf(world.contacts_prev), &world.contacts_prev, &world.contacts_curr);
        world.contacts_curr.clearRetainingCapacity();
    }

    // -------------------------------------------------------------------------
    // PHASE 4b - warm start. Re-apply last frame's impulses (scaled by the dt ratio)
    // so the solver starts near the previous solution. Order matches Jolt: friction
    // (linear x2, then angular), then per-point normal.
    // -------------------------------------------------------------------------
    {
        // Vehicles: steer, collide wheels, update spin/slip/brake budget, and build this step's
        // constraint parts (Jolt's PreCollide -> wheel collision -> PostCollide -> Setup).
        for (world.vehicles.items) |v| {
            v.prepare(world, dt);
        }

        for (contacts.items) |*c| {
            const ma: *Motion = &world.motion[c.a];
            const mb: *Motion = &world.motion[c.b];
            if (c.friction1.isActive()) {
                c.friction1.warmStart(ma, mb, c.tangent1, warm_start_ratio);
            }
            if (c.friction2.isActive()) {
                c.friction2.warmStart(ma, mb, c.tangent2, warm_start_ratio);
            }
            if (c.angular_friction.isActive()) {
                c.angular_friction.warmStart(ma, mb, warm_start_ratio);
            }
            var i: u8 = 0;
            while (i < c.count) : (i += 1) {
                c.points[i].normal_part.warmStart(ma, mb, c.normal, warm_start_ratio);
            }
        }

        // Joints: build this step's effective masses and warm-start from the impulses
        // carried in the Constraint itself.
        for (world.constraints.items) |*c| {
            if (constraintActive(world, c)) {
                prepareConstraint(world, c, warm_start_ratio, dt);
            }
        }
        // 6-DOF joints (setup + warm start), alongside the regular constraints.
        for (world.six_dof.items) |*c| {
            if (sixDofActive(world, c)) {
                prepareSixDof(world, c, warm_start_ratio, dt);
            }
        }
        for (world.paths.items) |*c| {
            if (pathConstraintActive(world, c)) {
                preparePath(world, c, warm_start_ratio, dt);
            }
        }

        // Vehicles: warm-start the suspension + pitch/roll parts.
        for (world.vehicles.items) |v| {
            v.warmStart(world, warm_start_ratio);
        }
    }

    // -------------------------------------------------------------------------
    // PHASE 5 - solve velocity constraints. velocity_steps sweeps of projected
    // Gauss-Seidel. Per contact, Jolt's exact order and friction cone:
    //   1. linear friction as a COUPLED circular cone clamped to (mu * sum lambda_n),
    //   2. torsional friction clamped to (mu * sum distance_i * lambda_n),
    //   3. per-point normal clamped to [0, inf).
    // -------------------------------------------------------------------------
    {
        const zp5: profiler.Zone = profiler.zoneNamed(@src(), "solve.velocity");
        defer zp5.end();
        var step_i: u32 = 0;
        while (step_i < s.velocity_steps) : (step_i += 1) {
            for (contacts.items) |*c| {
                const ma: *Motion = &world.motion[c.a];
                const mb: *Motion = &world.motion[c.b];

                const linear_friction_active: bool = c.friction1.isActive() or c.friction2.isActive();
                const angular_friction_active: bool = c.angular_friction.isActive();

                // Friction cone limits from the accumulated normal impulses.
                var max_linear_lambda: f32 = 0.0;
                var max_angular_lambda: f32 = 0.0;
                if (linear_friction_active or angular_friction_active) {
                    var i: u8 = 0;
                    while (i < c.count) : (i += 1) {
                        const ln: f32 = c.points[i].normal_part.total_lambda;
                        max_linear_lambda += ln;
                        max_angular_lambda += c.points[i].distance_to_friction_center * ln;
                    }
                    max_linear_lambda *= c.friction;
                    max_angular_lambda *= c.friction;
                }

                if (linear_friction_active) {
                    var lambda1: f32 = c.friction1.solveGetTotalLambda(ma, mb, c.tangent1);
                    var lambda2: f32 = c.friction2.solveGetTotalLambda(ma, mb, c.tangent2);
                    const total_sq: f32 = lambda1 * lambda1 + lambda2 * lambda2;
                    if (total_sq > max_linear_lambda * max_linear_lambda) {
                        const scale: f32 = max_linear_lambda / @sqrt(total_sq);
                        lambda1 *= scale;
                        lambda2 *= scale;
                    }
                    c.friction1.solveApplyLambda(ma, mb, c.tangent1, lambda1);
                    c.friction2.solveApplyLambda(ma, mb, c.tangent2, lambda2);
                }

                if (angular_friction_active) {
                    c.angular_friction.solveVelocity(
                        ma,
                        mb,
                        c.normal,
                        -max_angular_lambda,
                        max_angular_lambda,
                    );
                }

                var i: u8 = 0;
                while (i < c.count) : (i += 1) {
                    const p: *AxisPart = &c.points[i].normal_part;
                    const total: f32 = @max(p.solveGetTotalLambda(ma, mb, c.normal), 0.0);
                    p.solveApplyLambda(ma, mb, c.normal, total);
                }
            }
            // Joints are solved in the same Gauss-Seidel sweep as the contacts.
            for (world.constraints.items) |*c| {
                if (constraintActive(world, c)) {
                    solveConstraintVelocity(world, c);
                }
            }
            for (world.six_dof.items) |*c| {
                if (sixDofActive(world, c)) {
                    solveSixDofVelocity(world, c, dt);
                }
            }
            for (world.paths.items) |*c| {
                if (pathConstraintActive(world, c)) {
                    solvePathVelocity(world, c, dt);
                }
            }

            // Vehicles: suspension push (and, later, tire friction) + pitch/roll, in the
            // same velocity sweep so the coupling with contacts converges.
            for (world.vehicles.items) |v| v.solveVelocity(world, dt);
        }
    }

    // -------------------------------------------------------------------------
    // PHASE 6 - integrate velocity into position. Jolt's order: clamp (dynamic only),
    // rotation step, then position step. Linear-cast bodies that move more than a
    // fraction of their inner radius are swept against the geometry in their path and
    // stopped at the first time-of-impact, so they cannot tunnel; velocity is left
    // for next step's (speculative) contact to resolve, exactly as Jolt's CCD does.
    // -------------------------------------------------------------------------
    {
        const zp6: profiler.Zone = profiler.zoneNamed(@src(), "integrate");
        defer zp6.end();
        var ccd_candidates: std.ArrayListUnmanaged(BodyIndex) = .empty;

        for (world.active.items) |idx| {
            const body: *Body = &world.bodies.data[idx];
            const m: *Motion = &world.motion[idx];

            if (m.inv_mass > 0.0) {
                m.lin_vel = clampMagnitude(m.lin_vel, m.max_linear_speed);
                m.ang_vel = clampMagnitude(m.ang_vel, m.max_angular_speed);
            }

            // allowed_DOFs: drop any locked world-space velocity components so the body
            // cannot accumulate motion along them (no-op for unconstrained bodies).
            m.lin_vel *= m.lin_lock;
            m.ang_vel *= m.ang_lock;

            integrateRotation(&body.rot, m.ang_vel * splat(dt));

            const delta: Vec = m.lin_vel * splat(dt);
            var move_fraction: f32 = 1.0;

            if (body.motion_quality == .linear_cast and m.inv_mass > 0.0 and !body.is_sensor) {
                const shape: *const Shape = world.shapes.get(body.shape);
                const inner: f32 = shapeInnerRadius(shape);
                const threshold: f32 = s.linear_cast_threshold * inner;
                if (lengthSq3(delta) > threshold * threshold) {
                    // Swept AABB over the whole step, then the bodies in its path.
                    const moved_bounds: Aabb = .{
                        .min = body.bounds.min + delta,
                        .max = body.bounds.max + delta,
                    };
                    const swept: Aabb = body.bounds.combine(moved_bounds).expandedBy(s.speculative_distance);

                    ccd_candidates.clearRetainingCapacity();
                    try world.broadphase.queryAabb(scratch, swept, &ccd_candidates);

                    const r_self: f32 = convexRadius(shape);
                    var toi: f32 = 1.0;
                    for (ccd_candidates.items) |other| {
                        if (other == idx) {
                            continue;
                        }
                        const ob: *const Body = &world.bodies.data[other];
                        if (ob.is_sensor) {
                            continue;
                        }
                        if (!bodiesShouldCollide(body, ob)) {
                            continue;
                        }
                        const os: *const Shape = world.shapes.get(ob.shape);
                        const hit: ?f32 = shapeCastCores(
                            shape,
                            body.com_pos,
                            body.rot,
                            delta,
                            os,
                            ob.com_pos,
                            ob.rot,
                            r_self,
                            convexRadius(os),
                            s.penetration_slop,
                        );
                        if (hit) |h| {
                            toi = @min(toi, h);
                        }
                    }
                    move_fraction = toi;
                }
            }

            body.com_pos += delta * splat(move_fraction);
        }
    }

    // -------------------------------------------------------------------------
    // PHASE 7 - solve position constraints. position_steps sweeps. Per point, Jolt
    // recomputes the separation from the stored local contact points and the CURRENT
    // pose, recomputes the effective mass from the CURRENT inverse inertia, then
    // applies one Baumgarte correction. separation includes slop and is clamped.
    // -------------------------------------------------------------------------
    {
        const zp7: profiler.Zone = profiler.zoneNamed(@src(), "solve.position");
        defer zp7.end();
        var step_i: u32 = 0;
        while (step_i < s.position_steps) : (step_i += 1) {
            for (contacts.items) |*c| {
                const body_a: *Body = &world.bodies.data[c.a];
                const body_b: *Body = &world.bodies.data[c.b];
                const ma: *const Motion = &world.motion[c.a];
                const mb: *const Motion = &world.motion[c.b];

                var i: u8 = 0;
                while (i < c.count) : (i += 1) {
                    const p: *ContactPoint = &c.points[i];

                    const world_a: Vec = body_a.com_pos + rotate(body_a.rot, p.local_a);
                    const world_b: Vec = body_b.com_pos + rotate(body_b.rot, p.local_b);

                    const gap: f32 = dot3(world_b - world_a, c.normal) + s.penetration_slop;
                    const separation: f32 = @max(gap, -s.max_penetration_distance);
                    if (separation < 0.0) {
                        // Recompute inverse inertia from the CURRENT rotation per point,
                        // so a later point sees the rotation an earlier point's
                        // correction produced (Jolt recomputes inside this loop).
                        const inv_i_a: Mat3 = if (ma.inv_mass > 0.0)
                            bakeInvInertiaWorld(body_a.rot, ma.inv_inertia_diagonal, ma.inertia_rotation)
                        else
                            Mat3.zero;
                        const inv_i_b: Mat3 = if (mb.inv_mass > 0.0)
                            bakeInvInertiaWorld(body_b.rot, mb.inv_inertia_diagonal, mb.inertia_rotation)
                        else
                            Mat3.zero;

                        const midpoint: Vec = (world_a + world_b) * splat(0.5);
                        const ra: Vec = midpoint - body_a.com_pos;
                        const rb: Vec = midpoint - body_b.com_pos;
                        p.normal_part.prepare(ma, inv_i_a, ra, mb, inv_i_b, rb, c.normal, 0.0);
                        p.normal_part.solvePosition(
                            body_a,
                            ma,
                            body_b,
                            mb,
                            c.normal,
                            separation,
                            s.baumgarte,
                        );
                    }
                }
            }

            // Joints take their Baumgarte correction in the same position sweep.
            for (world.constraints.items) |*c| {
                if (constraintActive(world, c)) {
                    solveConstraintPosition(world, c, s.baumgarte);
                }
            }
            for (world.six_dof.items) |*c| {
                if (sixDofActive(world, c)) {
                    solveSixDofPosition(world, c, s.baumgarte);
                }
            }
            for (world.paths.items) |*c| {
                if (pathConstraintActive(world, c)) {
                    solvePathPosition(world, c, s.baumgarte);
                }
            }

            // Vehicles: suspension hard-limit + pitch/roll position correction.
            for (world.vehicles.items) |v| v.solvePosition(world, s.baumgarte);
        }
    }

    // -------------------------------------------------------------------------
    // PHASE 8 - refresh bounds, run Jolt's 3-sphere sleep test, deactivate islands
    // that are fully at rest, and reset accumulated forces (force reset lives here to
    // match Jolt's "Check Sleeping" job, after contact setup has consumed it).
    //
    // An island sleeps only if EVERY awake member passed the movement test; we
    // aggregate per union-find root, then remove the sleeping bodies from the active
    // set and zero their velocity. Static bodies are never in `active`, so a pile on
    // the floor sleeps as soon as its own bodies settle.
    // -------------------------------------------------------------------------
    const island_can_sleep: []bool = world.island_can_sleep;
    {
        const max_movement: f32 = s.point_velocity_sleep_threshold * s.time_before_sleep;

        var i: u32 = 0;
        while (i < body_count) : (i += 1) island_can_sleep[i] = true;

        for (world.active.items) |idx| {
            const body: *Body = &world.bodies.data[idx];
            const m: *Motion = &world.motion[idx];

            const shape: *const Shape = world.shapes.get(body.shape);
            body.bounds = transformAabb(shapeLocalBounds(shape), body.com_pos, body.rot);

            // 3-sphere movement test: grow each sphere to enclose the point's new
            // position; if any exceeds the tolerance the body is moving, so reset the
            // spheres and the timer. Otherwise accumulate time toward sleep.
            var can_sleep: bool = s.allow_sleeping;
            const points: [3]Vec = sleepTestPoints(body.com_pos, body.rot, shape);
            var moved_too_far: bool = false;
            for (&m.sleep_spheres, points) |*sph, p| {
                encapsulate(sph, p);
                if (sph.radius > max_movement) {
                    moved_too_far = true;
                }
            }
            if (moved_too_far) {
                resetSleepSpheres(m, points);
                can_sleep = false;
            } else {
                m.sleep_timer += dt;
                if (m.sleep_timer < s.time_before_sleep) {
                    can_sleep = false;
                }
            }

            if (!can_sleep) {
                island_can_sleep[dsuFind(parent, idx)] = false;
            }

            m.force = vec_zero;
            m.torque = vec_zero;
        }

        // Compact the active set, deactivating bodies whose island can sleep.
        var w: usize = 0;
        for (world.active.items) |idx| {
            if (island_can_sleep[dsuFind(parent, idx)]) {
                const body: *Body = &world.bodies.data[idx];
                const m: *Motion = &world.motion[idx];
                body.asleep = true;
                m.lin_vel = vec_zero;
                m.ang_vel = vec_zero;
            } else {
                world.active.items[w] = idx;
                w += 1;
            }
        }
        world.active.shrinkRetainingCapacity(w);
    }

    // -------------------------------------------------------------------------
    // PHASE 9 - persist accumulated impulses for next frame's warm start, swap.
    // -------------------------------------------------------------------------
    {
        for (contacts.items) |*c| {
            const lo: BodyIndex = @min(c.a, c.b);
            const hi: BodyIndex = @max(c.a, c.b);
            try world.cache.storeFriction(world.allocator, .{ .a = lo, .b = hi, .sub = c.sub }, .{
                .linear = .{ c.friction1.total_lambda, c.friction2.total_lambda },
                .angular = c.angular_friction.total_lambda,
            });
            var i: u8 = 0;
            while (i < c.count) : (i += 1) {
                const point_key: PointKey = .{
                    .a = lo,
                    .b = hi,
                    .sub = c.sub,
                    .feature = c.points[i].feature_id,
                };
                const stored_impulse: f32 = c.points[i].normal_part.total_lambda;
                try world.cache.storeNormal(world.allocator, point_key, stored_impulse);
            }
        }
        world.cache.swap();
    }

    for (world.soft_bodies.items) |*sb| {
        try softBodyUpdate(world, sb, dt, scratch);
    }

    world.prev_dt = dt;
}

// =============================================================================
// Parity status vs Jolt:
//   * Matched term-for-term: integration (gyroscopic, force/drag, damping, clamp,
//     quaternion step), force-reset timing, the per-point non-penetration bias
//     (speculative + restitution + force-delta correction), the per-manifold
//     friction model (two linear tangents + torsional, coupled circular cone at the
//     centroid), the solve order, warm starting, the position pass (slop, clamp,
//     per-point recomputed effective mass), and the convex narrow phase (GJK on the
//     cores + EPA for deep overlap + convex radius added back, as in Jolt's
//     sCollideConvexVsConvex). Constants are Jolt's defaults.
//   * Same physics, different storage/order: bodies in an ECS pool, a dynamic AABB
//     broad phase (Box2D-style tree), and islands via a plain union-find over the
//     contact graph with Jolt's 3-sphere sleep test. Single threaded, so the islands
//     bound work and (more importantly) drive sleeping; they do not need Jolt's
//     deterministic island/large-island machinery. Results are physically equivalent
//     to Jolt, not bit-identical to a specific Jolt run (see top note).
//   * Still sketched / next pass: manifold reduction keeps the first four clipped
//     points rather than the four maximising contact area; contact feature ids are
//     synthesised rather than derived from edge indices (warm-start matching degrades
//     as a contact slides); and CCD stops a fast body at its time-of-impact but does
//     not re-solve the contact sub-step within the same frame (the next step's
//     speculative contact does), so a very fast restitutive bounce loses one frame.
//   * Multi-point manifolds now cover the convex path: GJK/EPA give the normal and
//     one witness, then supporting faces are clipped (Jolt's ManifoldBetweenTwoFaces)
//     so a side-on capsule or box-vs-capsule rests on two points and a flat hull face
//     on up to four. CCD (linear cast via GJK conservative advancement) sweeps
//     bodies flagged .linear_cast so they cannot tunnel.
//   * Known cost: findPairs still queries every leaf each try step (contacts are rebuilt,
//     not persisted), so a mostly-sleeping world pays broad-phase cost it could skip.
//     Persistent manifolds + a move buffer (Jolt/Box2D style) is the optimisation.
//   * Intentionally omitted (opinionated): conveyor-belt surface velocities, per-body
//     inverse-inertia scale, soft bodies, the large-island splitter, double precision.
// =============================================================================

// =============================================================================
// Vehicles. A wheeled vehicle is a single rigid body (the chassis); the wheels are NOT
// separate bodies. A Vehicle holds the chassis body + an array of wheels + a ground
// collision tester (+ a controller, later). Each step: collide each wheel against the
// ground, then solve a suspension spring + tire-friction constraint against the chassis
// and the ground body. Mirrors Jolt's Vehicle module (VehicleConstraint / Wheel /
// VehicleCollisionTester / VehicleController). PHASE 1 here: the data model + ray ground
// collision (fills each wheel's contact, suspension length and tire basis); the
// constraint solve, controller and step integration follow in later phases.
// =============================================================================

/// Register a vehicle so the World drives its wheel collision and constraint solve each step
/// (collide + setup + warm-start + solve, slotted into step's solver phases). The World does
/// not take ownership: the caller keeps the Vehicle alive and calls its deinit.
pub fn addVehicle(world: *World, gpa: std.mem.Allocator, v: *Vehicle) !void {
    try world.vehicles.append(gpa, v);
}
