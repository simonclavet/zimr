//! lint:alias zimrphysics2d
//! zimrphysics2d.zig - a single-file, single-threaded 2D rigid-body engine.
//!
//! This is a faithful port of Box2D v3.1 (Erin Catto's data-oriented C rewrite, the
//! "TGS Soft" solver) to Zig, in the style of `zimrphysics.zig` (our Jolt port):
//! a flat phase pipeline, ECS-backed storage via `entities.zig`, no globals, no
//! vtables, no OOP. We reproduce Box2D's *algorithm* term-for-term, including its
//! single-threaded performance architecture (graph coloring + a 4-wide SIMD contact
//! solver), while replacing its task scheduler and cache machinery with the simpler
//! storage model that fits zimr.
//!
//! -- What is faithful (the physics) --------------------------------------------
//!   * The TGS-Soft substepping solver: soft contacts, bias/relax passes, speculative
//!     contacts, restitution, warm starting, stored impulses.
//!   * All five collision shapes: circle, capsule, segment, polygon, chain segment.
//!   * All seven joints: distance, motor, prismatic, revolute, weld, wheel, filter.
//!   * GJK distance, time-of-impact, continuous collision (bullets + fast bodies).
//!   * Sensors, contact/sensor/hit/joint events, per-shape surface materials.
//!
//! -- What is faithful (the single-threaded performance architecture) -------------
//!   * Constraint-graph coloring: contacts and joints are partitioned into colors in
//!     which no dynamic body appears twice, then solved color by color.
//!   * A 4-wide SIMD contact solver (`@Vector(4, f32)`, lowering to wasm128 in the
//!     browser and SSE on the host) over the colored blocks; the overflow color is
//!     solved scalar. The wide path is a bit-identical transcription of the scalar one.
//!   * Ordered, shrinking tree casts (ray and box) and a periodic median-split rebuild
//!     of the broad-phase trees to recover query quality.
//!
//! -- What is adapted (the engineering) - see the deviations ledger below ---------
//!   1.  Single-threaded only. No task scheduler, no atomics. Box2D's parallelism is
//!       replaced by serial iteration over the same colored constraint blocks, so the
//!       result matches Box2D's output for a single worker.
//!   2.  No solver sets / persistent islands / island splitting. Bodies live in an
//!       `Entities(Body)` pool with parallel side-tables and an `active` list;
//!       sleeping uses a per-step union-find over the contact+joint graph (the same
//!       approach as `zimrphysics.zig`), which gives identical sleeping behavior.
//!   3.  Single precision only. Box2D's optional double-precision / large-world mode
//!       (its `b2Pos` / `b2WorldTransform` distinction) is dropped; everything is
//!       `Vec2` / `Transform2`. World-origin shifting is not supported.
//!   4.  Length units are fixed to meters (no `b2SetLengthUnitsPerMeter`); the tunables
//!       in `Settings` are Box2D's meter-based defaults.
//!   5.  No recording/replay and no world snapshot.
//!   6.  Friction/restitution live on the SHAPE (`SurfaceMaterial`), per Box2D v3.
//!       This differs from `zimrphysics.zig`, which stores them per body.
//!   7.  The broad-phase rebuild uses Box2D's median-split heuristic (its default,
//!       `B2_TREE_HEURISTIC == 0`) as a periodic full rebuild rather than the
//!       continuous incremental rebuild; queries and physics are unaffected by it.
//!
//! Every ported kernel carries a parity tag of the form `// box2d: <symbol> <file>`
//! so the Zig and C can be diffed side by side. Cryptic Box2D solver variable names
//! (`mA`, `iA`, `rn1`, ...) are expanded to explicit ones (`inv_mass_a`, ...).
//!
//! The engine compiles clean under Zig 0.17 and is continuously runtime-validated
//! against a regression suite spanning stacking, every joint type, restitution,
//! queries, CCD, sensors, the character mover, and the SIMD solve path.

const std = @import("std");
const zm = @import("zm");
const assertUnreachable = zm.assertUnreachable;
const float = zm.float;
const entities = @import("entities.zig");
const physics_common = @import("physics_common.zig");
const profiler = @import("profiler.zig");
const FrameArena = @import("frame_arena.zig").FrameArena;
/// Ceiling for the per-step scratch arena (reset at the top of every step).
/// Generous headroom over one step; trips FrameArena if the reset is dropped.
const step_arena_ceiling: usize = 256 * 1024 * 1024;
/// Re-export the profiler instance this engine records into, so tools and host harnesses can read
/// the same zone store (the in-app HUD reads it via the zimr module's re-export).
pub const profiler_mod = profiler;

const Allocator = std.mem.Allocator;
const assert = zm.assert;

// -- zm bindings (bare names inside this file, per the zimr convention) ----------
// Existing zm primitives:
pub const Vec2 = zm.Vec2;
const splat2 = zm.splat2;
const dot2 = zm.dot2;
const cross2 = zm.cross2;
const length2 = zm.length2;
const lengthSq2 = zm.lengthSq2;
const distance2 = zm.distance2;
const pi = zm.pi;
const sqrt2 = zm.sqrt2;
const clamp = zm.clamp;
const floatMax = zm.floatMax;
const floatEps = zm.floatEps;
const maxInt = zm.maxInt;
// zm additions from the Z-physics2d block:
pub const Rot2 = zm.Rot2;
pub const Transform2 = zm.Transform2;
pub const Mat22 = zm.Mat22;
pub const Aabb2 = zm.Aabb2;
pub const Sweep2 = zm.Sweep2;
const expect = std.testing.expect;
const crossVS2 = zm.crossVS2;
const crossSV2 = zm.crossSV2;
const leftPerp2 = zm.leftPerp2;
const rightPerp2 = zm.rightPerp2;
const mulAdd2 = zm.mulAdd2;
const mulSub2 = zm.mulSub2;
const normalizeOrZero2 = zm.normalizeOrZero2;
const getLengthAndNormalize2 = zm.getLengthAndNormalize2;
const mulRot2 = zm.mulRot2;
const invMulRot2 = zm.invMulRot2;
const rotateVec2 = zm.rotateVec2;
const invRotateVec2 = zm.invRotateVec2;
const integrateRot2 = zm.integrateRot2;
const transformPoint2 = zm.transformPoint2;
const invTransformPoint2 = zm.invTransformPoint2;
const invMulTransforms2 = zm.invMulTransforms2;
const mulMV22 = zm.mulMV22;
const inverse22 = zm.inverse22;
const solve22 = zm.solve22;
const unwindAngle = zm.unwindAngle;
const sweepTransform2 = zm.sweepTransform2;

// ================================================================================
// Geometric constants
//
// These are fixed geometric tolerances, not user tunables - Box2D defines them as
// compile-time constants (`#define`). They are comptime `pub const`s here (immutable,
// not mutable global state), and the runtime `Settings` below mirrors the ones the
// solver reads so a world can still be retuned without touching these.
// box2d: constants.h
// ================================================================================

/// Maximum vertices in a convex polygon (and in a GJK shape proxy).
/// box2d: B2_MAX_POLYGON_VERTICES  collision.h:25
pub const max_polygon_vertices: usize = 8;

/// A small length used as a collision and hull-welding tolerance (meters).
/// box2d: B2_LINEAR_SLOP  constants.h:34
pub const linear_slop: f32 = 0.005;

/// How far shapes are allowed to overlap before a hard correction; also the range
/// over which speculative contacts are generated. 4 * linear_slop.
/// box2d: B2_SPECULATIVE_DISTANCE  constants.h:53
pub const speculative_distance: f32 = 4.0 * linear_slop;

/// The broad-phase AABB enlargement, so a body can move a little before its proxy
/// must be re-inserted into the tree. (meters)
/// box2d: B2_AABB_MARGIN  constants.h:65
pub const aabb_margin: f32 = 0.1;

/// A shape's broad-phase fat margin is adaptive: a fraction of the shape's own extent,
/// capped at a hard maximum (meters). Static shapes instead use `speculative_distance`.
/// box2d: B2_AABB_MARGIN_FRACTION / B2_MAX_AABB_MARGIN  constants.h:67
pub const aabb_margin_fraction: f32 = 0.125;
pub const max_aabb_margin: f32 = 0.05;

/// The broad-phase query mask that matches every category. box2d: B2_DEFAULT_MASK_BITS
pub const default_mask_bits: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// A very large length used as an initial "infinity" for extent searches.
/// box2d: B2_HUGE  constants.h:14
pub const huge_length: f32 = 100000.0 * linear_slop;

/// The maximum rotation a body may integrate in a single sub-step, to keep the
/// small-angle rotation integrator valid. (radians)
/// box2d: B2_MAX_ROTATION  constants.h:48
pub const max_rotation: f32 = 0.25 * pi;

// ================================================================================
// Settings - per-world runtime tunables (no globals; passed by value where needed)
// box2d: b2WorldDef (types.h:83) + the derived world fields (physics_world.c)
// ================================================================================

pub const Settings = struct {
    /// Number of solver sub-steps per `step()`. More sub-steps = stiffer, costlier.
    /// box2d: b2World_Step subStepCount (default 4)
    sub_step_count: u32 = 4,

    /// Uniform acceleration applied to every dynamic body (m/s^2).
    gravity: Vec2 = .{ 0.0, -10.0 },

    /// Relative approach speed (m/s) above which a collision bounces. Below this the
    /// restitution is suppressed, preventing endless micro-jitter at rest.
    /// box2d: b2WorldDef.restitutionThreshold
    restitution_threshold: f32 = 1.0,

    /// Relative approach speed (m/s) above which a contact reports a hit event.
    /// box2d: b2WorldDef.hitEventThreshold
    hit_event_threshold: f32 = 1.0,

    /// Contact stiffness, as an oscillation frequency in Hz. The effective frequency
    /// is clamped to 1/4 of the sub-step rate inside `step()`.
    /// box2d: b2WorldDef.contactHertz
    contact_hertz: f32 = 30.0,

    /// Contact damping ratio (dimensionless). ~10 is heavily over-damped, which is
    /// what we want for stable stacking.
    /// box2d: b2WorldDef.contactDampingRatio
    contact_damping_ratio: f32 = 10.0,

    /// Maximum speed (m/s) at which overlap is pushed out, so deep penetration does
    /// not launch bodies. box2d: b2WorldDef.contactSpeed / maxContactPushSpeed
    contact_push_speed: f32 = 3.0,

    /// Maximum translational speed (m/s) a body may reach, clamped during position
    /// integration. Box2D's default is 400 m/s ("faster than the speed of sound") - high
    /// enough never to throttle ordinary motion, low enough to bound a single step.
    /// box2d: b2WorldDef.maximumLinearSpeed
    max_linear_speed: f32 = 400.0,

    /// Speed (m/s and rad*extent/s) below which a body is considered "slow" and starts
    /// accumulating sleep time. box2d: b2BodyDef.sleepThreshold (per body; this is the
    /// world default applied at body creation).
    sleep_threshold: f32 = 0.05,

    /// Time (s) a whole island must stay slow before it is put to sleep.
    /// box2d: B2_TIME_TO_SLEEP  constants.h:71
    time_to_sleep: f32 = 0.5,

    /// Master toggles.
    enable_sleep: bool = true,
    enable_continuous: bool = true,
    enable_warm_starting: bool = true,
    enable_speculative: bool = true,

    /// Geometric tolerances the solver reads (mirrors the comptime constants so a
    /// world stays self-contained; defaults match the constants above).
    linear_slop: f32 = linear_slop,
    speculative_distance: f32 = speculative_distance,
    max_rotation: f32 = max_rotation,
};

// ================================================================================
// Softness - the soft-constraint coefficients used by the TGS-Soft solver
// box2d: b2Softness + b2MakeSoft  solver.h:218
// ================================================================================

/// The three coefficients of a soft constraint, precomputed once per step from a
/// target frequency, damping ratio, and sub-step length:
///   * `bias_rate`     scales the position error into a corrective velocity,
///   * `mass_scale`    scales the effective mass of the velocity solve,
///   * `impulse_scale` bleeds off accumulated impulse so the constraint stays soft.
pub const Softness = struct {
    bias_rate: f32 = 0,
    mass_scale: f32 = 0,
    impulse_scale: f32 = 0,

    /// A perfectly rigid (un-softened) constraint: full mass, no bias, no bleed.
    pub const rigid: Softness = .{ .bias_rate = 0.0, .mass_scale = 1.0, .impulse_scale = 0.0 };
};

/// Derive the soft-constraint coefficients for the given oscillation frequency
/// (`hertz`), damping ratio (`zeta`), and sub-step duration (`h`). A frequency of
/// zero means "no constraint", which yields all-zero coefficients.
/// box2d: b2MakeSoft  solver.h:218
pub fn makeSoft(hertz: f32, zeta: f32, h: f32) Softness {
    if (hertz == 0.0) {
        return .{ .bias_rate = 0.0, .mass_scale = 0.0, .impulse_scale = 0.0 };
    }
    const omega: f32 = 2.0 * pi * hertz;
    const a1: f32 = 2.0 * zeta + h * omega;
    const a2: f32 = h * omega * a1;
    const a3: f32 = 1.0 / (1.0 + a2);
    return .{
        .bias_rate = omega / a1,
        .mass_scale = a2 * a3,
        .impulse_scale = a3,
    };
}

// ================================================================================
// Shape geometry - the five primitive shapes and their tagged union
//
// Field names track Box2D so the data layout can be diffed against the C; the cryptic
// names appear only in the solver, where we expand them. box2d: collision.h
// ================================================================================

/// A solid disc: a center and a radius.
/// box2d: b2Circle  collision.h
pub const Circle = struct {
    center: Vec2,
    radius: f32,
};

/// A "stadium" / line segment swept by a radius - two cap centers and a radius.
/// box2d: b2Capsule  collision.h
pub const Capsule = struct {
    center1: Vec2,
    center2: Vec2,
    radius: f32,
};

/// A zero-thickness line segment. Collides on both sides (one-sided collision is the
/// job of `ChainSegment`). box2d: b2Segment  collision.h
pub const Segment = struct {
    point1: Vec2,
    point2: Vec2,
};

/// A convex polygon with up to `max_polygon_vertices` vertices, given in CCW order,
/// with precomputed outward edge normals and centroid, plus an optional rounding
/// radius. box2d: b2Polygon  collision.h
pub const Polygon = struct {
    vertices: [max_polygon_vertices]Vec2,
    normals: [max_polygon_vertices]Vec2,
    centroid: Vec2,
    radius: f32,
    count: u32,
};

/// One segment of a collision chain, carrying its neighbor "ghost" vertices so the
/// solver can do one-sided collision and skip the interior of the chain.
/// box2d: b2ChainSegment  collision.h
pub const ChainSegment = struct {
    ghost1: Vec2,
    segment: Segment,
    ghost2: Vec2,
    /// Index of the owning chain (for grouping); `null_index` if standalone.
    chain_id: u32,
};

/// The shape-kind tag. Ordered exactly as Box2D's `b2ShapeType` so the collide
/// dispatch can rely on `type_a <= type_b` to reach only the lower triangle.
/// box2d: b2ShapeType  types.h
pub const ShapeKind = enum(u8) {
    circle = 0,
    capsule = 1,
    segment = 2,
    polygon = 3,
    chain_segment = 4,
};

/// One shape's geometry, as a tagged union over the five primitives.
pub const Geometry = union(ShapeKind) {
    circle: Circle,
    capsule: Capsule,
    segment: Segment,
    polygon: Polygon,
    chain_segment: ChainSegment,
};

/// The mass properties of a shape (or a whole body): total mass, the center of mass
/// in local coordinates, and the rotational inertia about that center of mass.
/// box2d: b2MassData  collision.h
pub const MassData = struct {
    mass: f32,
    center: Vec2,
    rotational_inertia: f32,
};

/// A shape's extent relative to a reference point (the body center of mass):
///   * `min_extent` is the smallest distance from the COM to any support plane - it
///     gates continuous collision (a body cannot be allowed to move more than half
///     of this in a step without sweeping).
///   * `max_extent` is the farthest any part of the shape reaches from the COM - it
///     scales angular velocity into a linear speed for the sleep test.
/// box2d: b2ShapeExtent  shape.h
pub const ShapeExtent = struct {
    min_extent: f32,
    max_extent: f32,
};

/// Collision filtering for a shape. Two shapes collide only if their category/mask bits
/// cross both ways (`a.category & b.mask` and `b.category & a.mask` are both nonzero),
/// unless they share a nonzero `group`, which forces the outcome: a positive group always
/// collides, a negative group never does, regardless of the bits.
/// box2d: b2Filter  types.h
pub const Filter = struct {
    category: u64 = 1, // which categories this shape belongs to
    mask: u64 = 0xFFFF_FFFF_FFFF_FFFF, // which categories this shape collides with
    group: i32 = 0, // override: >0 always collide, <0 never, within the same group
};

/// The physical surface properties of a shape. When two shapes touch, the contact mixes
/// these pairwise (friction via the geometric mean, restitution via the max, by default).
/// box2d: b2SurfaceMaterial  types.h
pub const SurfaceMaterial = struct {
    friction: f32 = 0.6,
    restitution: f32 = 0.0,
    rolling_resistance: f32 = 0.0, // resists rolling; scaled by shape radius at the contact
    tangent_speed: f32 = 0.0, // conveyor-belt surface speed along the contact tangent
    user_material_id: u64 = 0, // application tag, passed to the mixing callbacks
};

// ================================================================================
// Convex hull builder (quickhull)
// box2d: b2ComputeHull / b2RecurseHull  hull.c:87 / hull.c:13
// ================================================================================

/// A convex hull: up to `max_polygon_vertices` points in CCW order. An empty hull
/// (`count == 0`) signals that the input was degenerate.
/// box2d: b2Hull  collision.h
pub const Hull = struct {
    points: [max_polygon_vertices]Vec2,
    count: u32,
};

/// Recursively build the hull of the points to the right of the directed edge
/// `p1 -> p2`. Returns the chain of hull points strictly between `p1` and `p2`
/// (excluding the endpoints themselves). The candidate set `points` is the set of
/// points already known to be on the right side.
/// box2d: b2RecurseHull  hull.c:13
fn recurseHull(p1: Vec2, p2: Vec2, points: []const Vec2) Hull {
    var hull: Hull = .{ .points = undefined, .count = 0 };
    if (points.len == 0) {
        return hull;
    }

    // Unit edge vector from p1 to p2. The signed distance of a point off this edge is
    // cross((point - p1), edge); it is POSITIVE for points to the right of the directed
    // edge, which is the side this call is responsible for.
    const edge: Vec2 = normalizeOrZero2(p2 - p1);

    // Collect the points to the right of the edge, and find the farthest one.
    var right_points: [max_polygon_vertices]Vec2 = undefined;
    var right_count: usize = 0;

    var best_index: usize = 0;
    var best_signed_distance: f32 = cross2(points[best_index] - p1, edge);
    if (best_signed_distance > 0.0) {
        right_points[right_count] = points[best_index];
        right_count += 1;
    }

    var i: usize = 1;
    while (i < points.len) : (i += 1) {
        // SIGNED, and the sign is what the `> 0.0` test below reads: `edge` is a unit vector,
        // so the 2D cross product gives the perpendicular distance from the p1->p2 line with a
        // positive value meaning 'to the right of it'. A plain `distance` would both shadow
        // `zm.distance2` and make `distance > 0.0` read as a tautology.
        const signed_distance: f32 = cross2(points[i] - p1, edge);
        if (signed_distance > best_signed_distance) {
            best_index = i;
            best_signed_distance = signed_distance;
        }
        if (signed_distance > 0.0) {
            right_points[right_count] = points[i];
            right_count += 1;
        }
    }

    // No point is meaningfully off the edge - this edge is already a hull edge.
    if (best_signed_distance < 2.0 * linear_slop) {
        return hull;
    }

    const best_point: Vec2 = points[best_index];

    // Recurse on the two sub-edges that meet at the farthest point.
    const hull1: Hull = recurseHull(p1, best_point, right_points[0..right_count]);
    const hull2: Hull = recurseHull(best_point, p2, right_points[0..right_count]);

    // Stitch: [hull1 points] ++ best_point ++ [hull2 points].
    var k: usize = 0;
    while (k < hull1.count) : (k += 1) {
        hull.points[hull.count] = hull1.points[k];
        hull.count += 1;
    }
    hull.points[hull.count] = best_point;
    hull.count += 1;
    k = 0;
    while (k < hull2.count) : (k += 1) {
        hull.points[hull.count] = hull2.points[k];
        hull.count += 1;
    }

    assert(hull.count < max_polygon_vertices, @src());
    return hull;
}

/// Compute the convex hull of up to `max_polygon_vertices` input points. Welds
/// near-duplicate points and drops collinear ones (both at `linear_slop`). Returns an
/// empty hull (`count == 0`) on degenerate input (fewer than 3 distinct points, or
/// everything collinear).
/// box2d: b2ComputeHull  hull.c:87
pub fn computeHull(input: []const Vec2) Hull {
    var hull: Hull = .{ .points = undefined, .count = 0 };

    if (input.len < 3 or input.len > max_polygon_vertices) {
        return hull; // caller passed bad data
    }
    const count: usize = @min(input.len, max_polygon_vertices);

    // Aggressively weld near-duplicate points, and accumulate a bounding box. The
    // first point always survives. Welding tolerance is (4 * slop)^2.
    var aabb: Aabb2 = .{
        .lower = .{ floatMax(f32), floatMax(f32) },
        .upper = .{ -floatMax(f32), -floatMax(f32) },
    };
    var welded: [max_polygon_vertices]Vec2 = undefined;
    var n: usize = 0;
    const tol_sq: f32 = 16.0 * linear_slop * linear_slop;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        aabb.lower = @min(aabb.lower, input[i]);
        aabb.upper = @max(aabb.upper, input[i]);

        const vi: Vec2 = input[i];
        var unique: bool = true;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (lengthSq2(vi - input[j]) < tol_sq) {
                unique = false;
                break;
            }
        }
        if (unique) {
            welded[n] = vi;
            n += 1;
        }
    }

    if (n < 3) {
        return hull; // all points coincident - check your data / scale
    }

    // Seed the hull with two extreme points: the point farthest from the box center,
    // then the point farthest from that one. Each is removed from the working set by
    // swapping in the last element.
    const box_center: Vec2 = aabb.center();
    var f1: usize = 0;
    var d1: f32 = lengthSq2(box_center - welded[f1]);
    i = 1;
    while (i < n) : (i += 1) {
        const d: f32 = lengthSq2(box_center - welded[i]);
        if (d > d1) {
            f1 = i;
            d1 = d;
        }
    }
    const p1: Vec2 = welded[f1];
    welded[f1] = welded[n - 1];
    n -= 1;

    var f2: usize = 0;
    var d2: f32 = lengthSq2(p1 - welded[f2]);
    i = 1;
    while (i < n) : (i += 1) {
        const d: f32 = lengthSq2(p1 - welded[i]);
        if (d > d2) {
            f2 = i;
            d2 = d;
        }
    }
    const p2: Vec2 = welded[f2];
    welded[f2] = welded[n - 1];
    n -= 1;

    // Partition the remaining points into those right and left of the line p1->p2.
    var right_points: [max_polygon_vertices - 2]Vec2 = undefined;
    var right_count: usize = 0;
    var left_points: [max_polygon_vertices - 2]Vec2 = undefined;
    var left_count: usize = 0;
    const edge: Vec2 = normalizeOrZero2(p2 - p1);

    i = 0;
    while (i < n) : (i += 1) {
        const d: f32 = cross2(welded[i] - p1, edge);
        if (d >= 2.0 * linear_slop) {
            right_points[right_count] = welded[i];
            right_count += 1;
        } else if (d <= -2.0 * linear_slop) {
            left_points[left_count] = welded[i];
            left_count += 1;
        }
    }

    // Build the upper (right) and lower (left) chains.
    const hull1: Hull = recurseHull(p1, p2, right_points[0..right_count]);
    const hull2: Hull = recurseHull(p2, p1, left_points[0..left_count]);

    if (hull1.count == 0 and hull2.count == 0) {
        return hull; // everything collinear
    }

    // Stitch the full loop, preserving CCW winding: p1, upper chain, p2, lower chain.
    hull.points[hull.count] = p1;
    hull.count += 1;
    var k: usize = 0;
    while (k < hull1.count) : (k += 1) {
        hull.points[hull.count] = hull1.points[k];
        hull.count += 1;
    }
    hull.points[hull.count] = p2;
    hull.count += 1;
    k = 0;
    while (k < hull2.count) : (k += 1) {
        hull.points[hull.count] = hull2.points[k];
        hull.count += 1;
    }
    assert(hull.count <= max_polygon_vertices, @src());

    // Remove collinear triples by deleting the middle point, repeatedly, until none
    // remain or the hull would drop below a triangle.
    var searching: bool = true;
    while (searching and hull.count > 2) {
        searching = false;
        var idx: usize = 0;
        while (idx < hull.count) : (idx += 1) {
            const ia: usize = idx;
            const ib: usize = (idx + 1) % hull.count;
            const ic: usize = (idx + 2) % hull.count;
            const s1: Vec2 = hull.points[ia];
            const s2: Vec2 = hull.points[ib];
            const s3: Vec2 = hull.points[ic];
            const r: Vec2 = normalizeOrZero2(s3 - s1);
            // `r` is a UNIT vector, so the 2D cross product is the perpendicular distance of s2
            // from the line s1->s3. Named `perp_distance` rather than `distance` because the bare
            // name shadows `zm.distance2`, and because it is the distance to a LINE, not a point.
            const perp_distance: f32 = cross2(s2 - s1, r);
            if (perp_distance <= 2.0 * linear_slop) {
                // s2 is collinear: shift the tail down over it.
                var j: usize = ib;
                while (j < hull.count - 1) : (j += 1) {
                    hull.points[j] = hull.points[j + 1];
                }
                hull.count -= 1;
                searching = true;
                break;
            }
        }
    }

    if (hull.count < 3) {
        hull.count = 0; // degenerate (should not happen after the checks above)
    }
    return hull;
}

// ================================================================================
// Polygon / shape constructors
// box2d: geometry.c
// ================================================================================

/// Area-weighted centroid of a CCW polygon given by `vertices` (a slice of length
/// `count`). Uses the first vertex as a triangle-fan origin to reduce round-off.
/// box2d: b2ComputePolygonCentroid  geometry.c
fn computePolygonCentroid(vertices: []const Vec2) Vec2 {
    var center: Vec2 = .{ 0.0, 0.0 };
    var area: f32 = 0.0;
    const origin: Vec2 = vertices[0];
    const inv3: f32 = 1.0 / 3.0;

    var i: usize = 1;
    while (i + 1 < vertices.len) : (i += 1) {
        const e1: Vec2 = vertices[i] - origin;
        const e2: Vec2 = vertices[i + 1] - origin;
        const tri_area: f32 = 0.5 * cross2(e1, e2);
        center = mulAdd2(center, tri_area * inv3, e1 + e2);
        area += tri_area;
    }

    assert(area > floatEps(f32), @src());
    const inv_area: f32 = 1.0 / area;
    center = center * splat2(inv_area);
    return origin + center;
}

/// Build a convex polygon from a hull with an optional rounding `radius`. Computes
/// outward edge normals (the right perpendicular of each CCW edge) and the centroid.
/// Falls back to a unit square if the hull is degenerate.
/// box2d: b2MakePolygon  geometry.c:57
pub fn makePolygon(hull: Hull, radius: f32) Polygon {
    if (hull.count < 3) {
        return makeSquare(0.5);
    }

    var shape: Polygon = undefined;
    shape.count = hull.count;
    shape.radius = radius;

    var i: usize = 0;
    while (i < shape.count) : (i += 1) {
        shape.vertices[i] = hull.points[i];
    }

    // Outward normal of edge (v[i] -> v[i+1]) is its right perpendicular, normalized.
    // box2d builds this as b2Normalize(b2CrossVS(edge, 1)) == rightPerp2(edge).
    i = 0;
    while (i < shape.count) : (i += 1) {
        const i_next: usize = if (i + 1 < shape.count) i + 1 else 0;
        const edge: Vec2 = shape.vertices[i_next] - shape.vertices[i];
        assert(dot2(edge, edge) > floatEps(f32) * floatEps(f32), @src());
        shape.normals[i] = normalizeOrZero2(rightPerp2(edge));
    }

    shape.centroid = computePolygonCentroid(shape.vertices[0..shape.count]);
    return shape;
}

/// Build a convex polygon from a hull, transformed by `position` + `rotation`.
/// box2d: b2MakeOffsetPolygon  geometry.c:92
pub fn makeOffsetPolygon(hull: Hull, position: Vec2, rotation: Rot2) Polygon {
    return makeOffsetRoundedPolygon(hull, position, rotation, 0.0);
}

/// Build a (optionally rounded) convex polygon from a hull, transformed by
/// `position` + `rotation`.
/// box2d: b2MakeOffsetRoundedPolygon  geometry.c:97
pub fn makeOffsetRoundedPolygon(
    hull: Hull,
    position: Vec2,
    rotation: Rot2,
    radius: f32,
) Polygon {
    if (hull.count < 3) {
        return makeSquare(0.5);
    }
    const xf: Transform2 = .{ .p = position, .q = rotation };

    var shape: Polygon = undefined;
    shape.count = hull.count;
    shape.radius = radius;

    var i: usize = 0;
    while (i < shape.count) : (i += 1) {
        shape.vertices[i] = transformPoint2(xf, hull.points[i]);
    }
    i = 0;
    while (i < shape.count) : (i += 1) {
        const i_next: usize = if (i + 1 < shape.count) i + 1 else 0;
        const edge: Vec2 = shape.vertices[i_next] - shape.vertices[i];
        assert(dot2(edge, edge) > floatEps(f32) * floatEps(f32), @src());
        shape.normals[i] = normalizeOrZero2(rightPerp2(edge));
    }
    shape.centroid = computePolygonCentroid(shape.vertices[0..shape.count]);
    return shape;
}

/// An axis-aligned square centered at the origin with the given half-width.
/// box2d: b2MakeSquare  geometry.c:134
pub fn makeSquare(half_width: f32) Polygon {
    return makeBox(half_width, half_width);
}

/// An axis-aligned box centered at the origin, given its half-extents. Vertices are
/// wound CCW starting at the bottom-left; normals are the axis directions.
/// box2d: b2MakeBox  geometry.c:139
pub fn makeBox(half_width: f32, half_height: f32) Polygon {
    assert(half_width > 0.0 and half_height > 0.0, @src());
    var shape: Polygon = undefined;
    shape.count = 4;
    shape.vertices[0] = .{ -half_width, -half_height };
    shape.vertices[1] = .{ half_width, -half_height };
    shape.vertices[2] = .{ half_width, half_height };
    shape.vertices[3] = .{ -half_width, half_height };
    shape.normals[0] = .{ 0.0, -1.0 };
    shape.normals[1] = .{ 1.0, 0.0 };
    shape.normals[2] = .{ 0.0, 1.0 };
    shape.normals[3] = .{ -1.0, 0.0 };
    shape.radius = 0.0;
    shape.centroid = .{ 0.0, 0.0 };
    return shape;
}

/// An axis-aligned box with a rounding radius.
/// box2d: b2MakeRoundedBox  geometry.c:159
pub fn makeRoundedBox(half_width: f32, half_height: f32, radius: f32) Polygon {
    assert(radius >= 0.0, @src());
    var shape: Polygon = makeBox(half_width, half_height);
    shape.radius = radius;
    return shape;
}

/// A box centered at `center` and rotated by `rotation`.
/// box2d: b2MakeOffsetBox  geometry.c:167
pub fn makeOffsetBox(
    half_width: f32,
    half_height: f32,
    center: Vec2,
    rotation: Rot2,
) Polygon {
    const xf: Transform2 = .{ .p = center, .q = rotation };
    var shape: Polygon = undefined;
    shape.count = 4;
    shape.vertices[0] = transformPoint2(xf, .{ -half_width, -half_height });
    shape.vertices[1] = transformPoint2(xf, .{ half_width, -half_height });
    shape.vertices[2] = transformPoint2(xf, .{ half_width, half_height });
    shape.vertices[3] = transformPoint2(xf, .{ -half_width, half_height });
    shape.normals[0] = rotateVec2(xf.q, .{ 0.0, -1.0 });
    shape.normals[1] = rotateVec2(xf.q, .{ 1.0, 0.0 });
    shape.normals[2] = rotateVec2(xf.q, .{ 0.0, 1.0 });
    shape.normals[3] = rotateVec2(xf.q, .{ -1.0, 0.0 });
    shape.radius = 0.0;
    shape.centroid = xf.p;
    return shape;
}

/// A rounded box centered at `center`, rotated by `rotation`.
/// box2d: b2MakeOffsetRoundedBox  geometry.c:186
pub fn makeOffsetRoundedBox(
    half_width: f32,
    half_height: f32,
    center: Vec2,
    rotation: Rot2,
    radius: f32,
) Polygon {
    assert(radius >= 0.0, @src());
    var shape: Polygon = makeOffsetBox(half_width, half_height, center, rotation);
    shape.radius = radius;
    return shape;
}

/// Return a copy of `polygon` with every vertex, normal, and the centroid mapped
/// through `transform`.
/// box2d: b2TransformPolygon  geometry.c:206
pub fn transformPolygon(transform: Transform2, polygon: Polygon) Polygon {
    var p: Polygon = polygon;
    var i: usize = 0;
    while (i < p.count) : (i += 1) {
        p.vertices[i] = transformPoint2(transform, p.vertices[i]);
        p.normals[i] = rotateVec2(transform.q, p.normals[i]);
    }
    p.centroid = transformPoint2(transform, p.centroid);
    return p;
}

// ================================================================================
// Mass properties
// box2d: geometry.c:221-400
// ================================================================================

/// Mass, centroid, and rotational inertia of a solid disc.
/// box2d: b2ComputeCircleMass  geometry.c:221
pub fn computeCircleMass(shape: Circle, density: f32) MassData {
    const rr: f32 = shape.radius * shape.radius;
    const mass: f32 = density * pi * rr;
    return .{
        .mass = mass,
        .center = shape.center,
        // Inertia of a disc about its center: (1/2) m r^2.
        .rotational_inertia = mass * 0.5 * rr,
    };
}

/// Mass, centroid, and rotational inertia of a capsule (a rectangle capped by two
/// half-discs). The inertia is assembled from the box part plus two offset
/// half-discs via the parallel-axis theorem (derivation in the Box2D source).
/// box2d: b2ComputeCapsuleMass  geometry.c:235
pub fn computeCapsuleMass(shape: Capsule, density: f32) MassData {
    const radius: f32 = shape.radius;
    const rr: f32 = radius * radius;
    const p1: Vec2 = shape.center1;
    const p2: Vec2 = shape.center2;
    const len: f32 = length2(p2 - p1);
    const ll: f32 = len * len;

    const circle_mass: f32 = density * (pi * radius * radius);
    const box_mass: f32 = density * (2.0 * radius * len);

    const mass: f32 = circle_mass + box_mass;
    const center: Vec2 = (p1 + p2) * splat2(0.5);

    // half-disc centroid distance from the flat edge: 4r / (3 pi).
    const lc: f32 = 4.0 * radius / (3.0 * pi);
    // half the len of the rectangular part.
    const h: f32 = 0.5 * len;

    const circle_inertia: f32 = circle_mass * (0.5 * rr + h * h + 2.0 * h * lc);
    const box_inertia: f32 = box_mass * (4.0 * rr + ll) / 12.0;

    return .{
        .mass = mass,
        .center = center,
        .rotational_inertia = circle_inertia + box_inertia,
    };
}

/// Mass, centroid, and rotational inertia of a convex polygon, integrated over its
/// triangle fan. Degenerate counts fall back to a circle (1 vertex) or capsule
/// (2 vertices). A rounding radius is approximated by pushing the vertices outward.
/// box2d: b2ComputePolygonMass  geometry.c:274
pub fn computePolygonMass(shape: Polygon, density: f32) MassData {
    assert(shape.count > 0, @src());

    if (shape.count == 1) {
        return computeCircleMass(.{ .center = shape.vertices[0], .radius = shape.radius }, density);
    }
    if (shape.count == 2) {
        return computeCapsuleMass(.{
            .center1 = shape.vertices[0],
            .center2 = shape.vertices[1],
            .radius = shape.radius,
        }, density);
    }

    // Effective vertices: for a rounded polygon, approximate the mass by pushing each
    // vertex outward along the average of its two adjacent normals.
    var vertices: [max_polygon_vertices]Vec2 = undefined;
    const count: usize = shape.count;
    const radius: f32 = shape.radius;

    if (radius > 0.0) {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const j: usize = if (i == 0) count - 1 else i - 1;
            const n1: Vec2 = shape.normals[j];
            const n2: Vec2 = shape.normals[i];
            const mid: Vec2 = normalizeOrZero2(n1 + n2);
            vertices[i] = mulAdd2(shape.vertices[i], sqrt2 * radius, mid);
        }
    } else {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            vertices[i] = shape.vertices[i];
        }
    }

    var center: Vec2 = .{ 0.0, 0.0 };
    var area: f32 = 0.0;
    var rotational_inertia: f32 = 0.0;
    const origin: Vec2 = vertices[0]; // fan origin, reduces round-off
    const inv3: f32 = 1.0 / 3.0;

    var i: usize = 1;
    while (i + 1 < count) : (i += 1) {
        const e1: Vec2 = vertices[i] - origin;
        const e2: Vec2 = vertices[i + 1] - origin;
        const d: f32 = cross2(e1, e2); // 2 * triangle area

        const tri_area: f32 = 0.5 * d;
        area += tri_area;
        center = mulAdd2(center, tri_area * inv3, e1 + e2);

        const ex1: f32 = e1[0];
        const ey1: f32 = e1[1];
        const ex2: f32 = e2[0];
        const ey2: f32 = e2[1];
        const intx2: f32 = ex1 * ex1 + ex2 * ex1 + ex2 * ex2;
        const inty2: f32 = ey1 * ey1 + ey2 * ey1 + ey2 * ey2;
        rotational_inertia += (0.25 * inv3 * d) * (intx2 + inty2);
    }

    assert(area > floatEps(f32), @src());
    const inv_area: f32 = 1.0 / area;
    center = center * splat2(inv_area);

    const mass: f32 = density * area;
    // Inertia is computed about `origin`; shift it to the center of mass.
    var inertia: f32 = density * rotational_inertia;
    inertia -= mass * dot2(center, center);
    assert(inertia >= 0.0, @src());

    return .{
        .mass = mass,
        .center = origin + center,
        .rotational_inertia = inertia,
    };
}

/// Mass of any shape. Segments and chain segments are massless (they only exist on
/// static geometry). box2d: b2ComputeShapeMass  shape.c
pub fn computeShapeMass(geom: Geometry, density: f32) MassData {
    return switch (geom) {
        .circle => |c| computeCircleMass(c, density),
        .capsule => |c| computeCapsuleMass(c, density),
        .polygon => |p| computePolygonMass(p, density),
        .segment, .chain_segment => .{ .mass = 0.0, .center = .{ 0.0, 0.0 }, .rotational_inertia = 0.0 },
    };
}

// ================================================================================
// Axis-aligned bounding boxes
//
// Box2D builds these in double precision for its large-world mode then narrows; we
// are single precision (deviation #5), so this is a plain min/max with the radius and
// any extra margin folded in. box2d: geometry.c:407-506
// ================================================================================

/// AABB of a circle, grown by `extra` on every side.
fn circleFatAabb(shape: Circle, xf: Transform2, extra: f32) Aabb2 {
    const c: Vec2 = transformPoint2(xf, shape.center);
    const r: f32 = shape.radius + extra;
    const rv: Vec2 = .{ r, r };
    return .{ .lower = c - rv, .upper = c + rv };
}

/// AABB of a capsule, grown by `extra` on every side.
fn capsuleFatAabb(shape: Capsule, xf: Transform2, extra: f32) Aabb2 {
    const v1: Vec2 = transformPoint2(xf, shape.center1);
    const v2: Vec2 = transformPoint2(xf, shape.center2);
    const r: f32 = shape.radius + extra;
    const rv: Vec2 = .{ r, r };
    return .{ .lower = @min(v1, v2) - rv, .upper = @max(v1, v2) + rv };
}

/// AABB of a polygon (including its rounding radius), grown by `extra`.
fn polygonFatAabb(shape: Polygon, xf: Transform2, extra: f32) Aabb2 {
    assert(shape.count > 0, @src());
    var lower: Vec2 = transformPoint2(xf, shape.vertices[0]);
    var upper: Vec2 = lower;
    var i: usize = 1;
    while (i < shape.count) : (i += 1) {
        const v: Vec2 = transformPoint2(xf, shape.vertices[i]);
        lower = @min(lower, v);
        upper = @max(upper, v);
    }
    const r: f32 = shape.radius + extra;
    const rv: Vec2 = .{ r, r };
    return .{ .lower = lower - rv, .upper = upper + rv };
}

/// AABB of a segment, grown by `extra`.
fn segmentFatAabb(shape: Segment, xf: Transform2, extra: f32) Aabb2 {
    const v1: Vec2 = transformPoint2(xf, shape.point1);
    const v2: Vec2 = transformPoint2(xf, shape.point2);
    const ev: Vec2 = .{ extra, extra };
    return .{ .lower = @min(v1, v2) - ev, .upper = @max(v1, v2) + ev };
}

/// The tight world-space AABB of a shape at transform `xf`.
/// box2d: b2ComputeShapeAABB  shape.c (via the per-type b2Compute*AABB)
pub fn computeShapeAabb(geom: Geometry, xf: Transform2) Aabb2 {
    return computeFatShapeAabb(geom, xf, 0.0);
}

/// The world-space AABB of a shape at transform `xf`, grown by `extra` on all sides.
/// box2d: b2ComputeFatShapeAABB  geometry.c:485
pub fn computeFatShapeAabb(geom: Geometry, xf: Transform2, extra: f32) Aabb2 {
    return switch (geom) {
        .circle => |c| circleFatAabb(c, xf, extra),
        .capsule => |c| capsuleFatAabb(c, xf, extra),
        .polygon => |p| polygonFatAabb(p, xf, extra),
        .segment => |s| segmentFatAabb(s, xf, extra),
        .chain_segment => |cs| segmentFatAabb(cs.segment, xf, extra),
    };
}

// ================================================================================
// Shape extents and radius
// box2d: b2ComputeShapeExtent (shape.c), b2GetShapeRadius (shape.c)
// ================================================================================

/// The min/max extent of a shape relative to `local_center` (the body COM). See
/// `ShapeExtent` for what each is used for.
/// box2d: b2ComputeShapeExtent  shape.c
pub fn computeShapeExtent(geom: Geometry, local_center: Vec2) ShapeExtent {
    switch (geom) {
        .circle => |c| {
            const radius: f32 = c.radius;
            return .{
                .min_extent = radius,
                .max_extent = length2(c.center - local_center) + radius,
            };
        },
        .capsule => |c| {
            const radius: f32 = c.radius;
            const c1: Vec2 = c.center1 - local_center;
            const c2: Vec2 = c.center2 - local_center;
            const max_d: f32 = @sqrt(@max(lengthSq2(c1), lengthSq2(c2)));
            return .{ .min_extent = radius, .max_extent = max_d + radius };
        },
        .polygon => |p| {
            var min_extent: f32 = huge_length;
            var max_extent_sq: f32 = 0.0;
            var i: usize = 0;
            while (i < p.count) : (i += 1) {
                const v: Vec2 = p.vertices[i];
                const plane_offset: f32 = dot2(p.normals[i], v - p.centroid);
                min_extent = @min(min_extent, plane_offset);
                max_extent_sq = @max(max_extent_sq, lengthSq2(v - local_center));
            }
            return .{
                .min_extent = min_extent + p.radius,
                .max_extent = @sqrt(max_extent_sq) + p.radius,
            };
        },
        .segment => |s| {
            const c1: Vec2 = s.point1 - local_center;
            const c2: Vec2 = s.point2 - local_center;
            return .{ .min_extent = 0.0, .max_extent = @sqrt(@max(lengthSq2(c1), lengthSq2(c2))) };
        },
        .chain_segment => |cs| {
            const c1: Vec2 = cs.segment.point1 - local_center;
            const c2: Vec2 = cs.segment.point2 - local_center;
            return .{ .min_extent = 0.0, .max_extent = @sqrt(@max(lengthSq2(c1), lengthSq2(c2))) };
        },
    }
}

/// The rounding radius of a shape (0 for segments, which are infinitely thin).
/// box2d: b2GetShapeRadius  shape.c
pub fn shapeRadius(geom: Geometry) f32 {
    return switch (geom) {
        .circle => |c| c.radius,
        .capsule => |c| c.radius,
        .polygon => |p| p.radius,
        .segment, .chain_segment => 0.0,
    };
}

/// The geometric centroid of a shape in its own local frame (used as the CCD reference
/// point and the base for the adaptive AABB margin). box2d: b2GetShapeCentroid  shape.c
pub fn getShapeCentroid(geom: Geometry) Vec2 {
    return switch (geom) {
        .circle => |c| c.center,
        .capsule => |c| (c.center1 + c.center2) * splat2(0.5),
        .polygon => |p| p.centroid,
        .segment => |s| (s.point1 + s.point2) * splat2(0.5),
        .chain_segment => |cs| (cs.segment.point1 + cs.segment.point2) * splat2(0.5),
    };
}

/// The adaptive broad-phase margin for a shape: a fraction of its own size, capped. A
/// larger shape tolerates a larger margin before its proxy must be re-fit, which cuts
/// tree churn for big slow movers. box2d: b2ComputeShapeMargin  shape.c:75
pub fn computeShapeMargin(geom: Geometry) f32 {
    const extent: f32 = switch (geom) {
        .circle => |c| c.radius,
        .capsule => |c| 0.5 * length2(c.center2 - c.center1) + c.radius,
        .polygon => |p| blk: {
            var max_sq: f32 = 0.0;
            var i: usize = 0;
            while (i < p.count) : (i += 1) {
                max_sq = @max(max_sq, lengthSq2(p.vertices[i] - p.centroid));
            }
            break :blk @sqrt(max_sq);
        },
        .segment => |s| 0.5 * length2(s.point2 - s.point1),
        .chain_segment => |cs| 0.5 * length2(cs.segment.point2 - cs.segment.point1),
    };
    return @min(max_aabb_margin, aabb_margin_fraction * extent);
}

// ================================================================================
// Distance / GJK
//
// GJK computes the distance (and closest points) between two convex shape proxies.
// Everything runs in shape A's frame: proxy B is transformed into A once up front,
// and the iteration walks the Minkowski difference looking for the simplex closest
// to the origin. box2d: distance.c:33-606
//
// Deviation: Box2D's debug `simplexes`/`simplexCapacity` capture (used only by the
// sample app to draw the GJK steps) is dropped.
// ================================================================================

/// A convex shape reduced to its support points (vertices) plus a rounding radius -
/// the only thing GJK and TOI need from a shape.
/// box2d: b2ShapeProxy  collision.h
pub const ShapeProxy = struct {
    points: [max_polygon_vertices]Vec2,
    count: u32,
    radius: f32,
};

/// Inputs to a distance query: two proxies, the relative pose of B in A's frame, and
/// whether to subtract the shapes' radii from the result.
/// box2d: b2DistanceInput  collision.h
pub const DistanceInput = struct {
    proxy_a: ShapeProxy,
    proxy_b: ShapeProxy,
    transform: Transform2, // pose of B in A's frame
    use_radii: bool,
};

/// Outputs of a distance query, all in shape A's frame.
/// box2d: b2DistanceOutput  collision.h
pub const DistanceOutput = struct {
    point_a: Vec2, // closest point on A
    point_b: Vec2, // closest point on B
    normal: Vec2, // unit normal from A to B (invalid when distance is zero)
    distance: f32, // zero when the shapes overlap
    iterations: u32,
};

/// A small persistent cache of the last simplex's vertex indices, so a repeated query
/// between the same pair of shapes warm-starts GJK. `count == 0` means "cold".
/// box2d: b2SimplexCache  collision.h
pub const SimplexCache = struct {
    count: u16,
    index_a: [3]u8,
    index_b: [3]u8,

    pub const empty: SimplexCache = .{ .count = 0, .index_a = .{ 0, 0, 0 }, .index_b = .{ 0, 0, 0 } };
};

/// One vertex of the GJK simplex: the support point on each proxy (`wa`, `wb`), their
/// Minkowski difference `w = wa - wb`, the barycentric weight `a`, and the source
/// vertex indices.
///
/// IMPORTANT: `w = wa - wb` here - this matches the Box2D *code* (the struct comment
/// in the C claims `wb - wa`, but the implementation computes `wa - wb`, and the whole
/// simplex solver is built around that sign).
/// box2d: b2SimplexVertex  distance.c
const SimplexVertex = struct {
    wa: Vec2,
    wb: Vec2,
    w: Vec2,
    a: f32,
    index_a: u32,
    index_b: u32,
};

/// The GJK simplex: one, two, or three vertices bounding the region of the Minkowski
/// difference closest to the origin. box2d: b2Simplex  distance.c
const Simplex = struct {
    v1: SimplexVertex,
    v2: SimplexVertex,
    v3: SimplexVertex,
    count: u32,
};

/// A pointer to the i-th simplex vertex (Box2D indexes a pointer array; we switch).
fn simplexVertex(s: *Simplex, i: usize) *SimplexVertex {
    return switch (i) {
        0 => &s.v1,
        1 => &s.v2,
        2 => &s.v3,
        else => unreachable,
    };
}

/// Closest points between two line segments [p1,q1] and [p2,q2], with the
/// barycentric fractions and the squared distance. Handles degenerate (point-like)
/// segments. box2d: b2SegmentDistance  distance.c:33
pub fn segmentDistance(
    p1: Vec2,
    q1: Vec2,
    p2: Vec2,
    q2: Vec2,
) SegmentDistanceResult {
    var result: SegmentDistanceResult = undefined;

    const d1: Vec2 = q1 - p1;
    const d2: Vec2 = q2 - p2;
    const r: Vec2 = p1 - p2;
    const dd1: f32 = dot2(d1, d1); // squared length of segment 1
    const dd2: f32 = dot2(d2, d2); // squared length of segment 2
    const rd1: f32 = dot2(r, d1);
    const rd2: f32 = dot2(r, d2);

    const eps_sq: f32 = floatEps(f32) * floatEps(f32);

    if (dd1 < eps_sq or dd2 < eps_sq) {
        // One or both segments are degenerate points.
        if (dd1 >= eps_sq) {
            result.fraction1 = clamp(-rd1 / dd1, 0.0, 1.0);
            result.fraction2 = 0.0;
        } else if (dd2 >= eps_sq) {
            result.fraction1 = 0.0;
            result.fraction2 = clamp(rd2 / dd2, 0.0, 1.0);
        } else {
            result.fraction1 = 0.0;
            result.fraction2 = 0.0;
        }
    } else {
        // General case: solve the 2x2 system for the closest fractions.
        const d12: f32 = dot2(d1, d2);
        const denominator: f32 = dd1 * dd2 - d12 * d12;

        var f1: f32 = 0.0;
        if (denominator != 0.0) {
            // segments not parallel
            f1 = clamp((d12 * rd2 - rd1 * dd2) / denominator, 0.0, 1.0);
        }

        // Closest fraction on segment 2 to the point p1 + f1 * d1.
        var f2: f32 = (d12 * f1 + rd2) / dd2;

        // If f2 clamps, recompute f1 against the clamped point.
        if (f2 < 0.0) {
            f2 = 0.0;
            f1 = clamp(-rd1 / dd1, 0.0, 1.0);
        } else if (f2 > 1.0) {
            f2 = 1.0;
            f1 = clamp((d12 - rd1) / dd1, 0.0, 1.0);
        }

        result.fraction1 = f1;
        result.fraction2 = f2;
    }

    result.closest1 = mulAdd2(p1, result.fraction1, d1);
    result.closest2 = mulAdd2(p2, result.fraction2, d2);
    result.distance_squared = lengthSq2(result.closest1 - result.closest2);
    return result;
}

/// The result of `segmentDistance`. box2d: b2SegmentDistanceResult  collision.h
pub const SegmentDistanceResult = struct {
    closest1: Vec2,
    closest2: Vec2,
    fraction1: f32,
    fraction2: f32,
    distance_squared: f32,
};

/// Build a shape proxy from up to `max_polygon_vertices` local points and a radius.
/// box2d: b2MakeProxy  distance.c:108
pub fn makeProxy(points: []const Vec2, radius: f32) ShapeProxy {
    const count: usize = @min(points.len, max_polygon_vertices);
    var proxy: ShapeProxy = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        proxy.points[i] = points[i];
    }
    proxy.count = @intCast(count);
    proxy.radius = radius;
    return proxy;
}

/// Build a shape proxy whose points are transformed by `position` + `rotation`.
/// box2d: b2MakeOffsetProxy  distance.c:121
pub fn makeOffsetProxy(
    points: []const Vec2,
    radius: f32,
    position: Vec2,
    rotation: Rot2,
) ShapeProxy {
    const count: usize = @min(points.len, max_polygon_vertices);
    const xf: Transform2 = .{ .p = position, .q = rotation };
    var proxy: ShapeProxy = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        proxy.points[i] = transformPoint2(xf, points[i]);
    }
    proxy.count = @intCast(count);
    proxy.radius = radius;
    return proxy;
}

/// Barycentric blend of two points.  box2d: b2Weight2  distance.c:138
inline fn weight2(a1: f32, w1: Vec2, a2: f32, w2: Vec2) Vec2 {
    return w1 * splat2(a1) + w2 * splat2(a2);
}

/// Barycentric blend of three points.  box2d: b2Weight3  distance.c:143
inline fn weight3(
    a1: f32,
    w1: Vec2,
    a2: f32,
    w2: Vec2,
    a3: f32,
    w3: Vec2,
) Vec2 {
    return w1 * splat2(a1) + w2 * splat2(a2) + w3 * splat2(a3);
}

/// Index of the proxy vertex farthest along `direction` (the support function).
/// box2d: b2FindSupport  distance.c:148
fn findSupport(proxy: *const ShapeProxy, direction: Vec2) u32 {
    var best_index: u32 = 0;
    var best_value: f32 = dot2(proxy.points[0], direction);
    var i: usize = 1;
    while (i < proxy.count) : (i += 1) {
        const value: f32 = dot2(proxy.points[i], direction);
        if (value > best_value) {
            best_index = @intCast(i);
            best_value = value;
        }
    }
    return best_index;
}

/// Rebuild a simplex from a warm-start cache. Falls back to a single vertex if the
/// cache is empty. box2d: b2MakeSimplexFromCache  distance.c:168
fn makeSimplexFromCache(
    cache: SimplexCache,
    proxy_a: *const ShapeProxy,
    proxy_b: *const ShapeProxy,
) Simplex {
    assert(cache.count <= 3, @src());
    var s: Simplex = undefined;
    s.count = cache.count;

    var i: usize = 0;
    while (i < s.count) : (i += 1) {
        const v: *SimplexVertex = simplexVertex(&s, i);
        v.index_a = cache.index_a[i];
        v.index_b = cache.index_b[i];
        v.wa = proxy_a.points[v.index_a];
        v.wb = proxy_b.points[v.index_b];
        v.w = v.wa - v.wb;
        v.a = -1.0; // weight is invalid until a solve fills it in
    }

    // An empty/invalid cache seeds the first vertex from index 0 of each proxy.
    if (s.count == 0) {
        const v: *SimplexVertex = simplexVertex(&s, 0);
        v.index_a = 0;
        v.index_b = 0;
        v.wa = proxy_a.points[0];
        v.wb = proxy_b.points[0];
        v.w = v.wa - v.wb;
        v.a = 1.0;
        s.count = 1;
    }
    return s;
}

/// Snapshot a simplex's vertex indices into a warm-start cache.
/// box2d: b2MakeSimplexCache  distance.c:206
fn makeSimplexCache(s: *const Simplex) SimplexCache {
    var cache: SimplexCache = .{ .count = @intCast(s.count), .index_a = undefined, .index_b = undefined };
    var i: usize = 0;
    while (i < s.count) : (i += 1) {
        // const-correct vertex access without a mutable pointer helper:
        const v: SimplexVertex = switch (i) {
            0 => s.v1,
            1 => s.v2,
            2 => s.v3,
            else => unreachable,
        };
        cache.index_a[i] = @intCast(v.index_a);
        cache.index_b[i] = @intCast(v.index_b);
    }
    return cache;
}

/// The closest points on each proxy, blended from the simplex's barycentric weights.
const WitnessPoints = struct { a: Vec2, b: Vec2 };

/// Compute the witness (closest) points from the final simplex.
/// box2d: b2ComputeWitnessPoints  distance.c:220
fn computeWitnessPoints(s: *const Simplex) WitnessPoints {
    return switch (s.count) {
        1 => .{ .a = s.v1.wa, .b = s.v1.wb },
        2 => .{
            .a = weight2(s.v1.a, s.v1.wa, s.v2.a, s.v2.wa),
            .b = weight2(s.v1.a, s.v1.wb, s.v2.a, s.v2.wb),
        },
        // For a 3-simplex the origin is inside, so both witnesses collapse to the
        // same point (Box2D uses the A blend for both).
        3 => blk: {
            const a: Vec2 = weight3(s.v1.a, s.v1.wa, s.v2.a, s.v2.wa, s.v3.a, s.v3.wa);
            break :blk .{ .a = a, .b = a };
        },
        else => unreachable,
    };
}

/// Reduce a 2-vertex simplex to the feature closest to the origin and return the
/// search direction toward the origin. box2d: b2SolveSimplex2  distance.c:274
/// Reduce a 2-vertex simplex (a line segment in the Minkowski difference) to the feature
/// closest to the origin: either an endpoint (count -> 1) or the segment itself (count 2,
/// with barycentric weights stored in `.a`). Returns the direction from that feature toward
/// the origin. The `dAB_n` values are Box2D's barycentric numerators. box2d: b2SolveSimplex2
fn solveSimplex2(s: *Simplex) Vec2 {
    const w1: Vec2 = s.v1.w;
    const w2: Vec2 = s.v2.w;
    const e12: Vec2 = w2 - w1;

    // Closest is vertex w1?
    const d12_2: f32 = -dot2(w1, e12);
    if (d12_2 <= 0.0) {
        s.v1.a = 1.0;
        s.count = 1;
        return -w1;
    }

    // Closest is vertex w2?
    const d12_1: f32 = dot2(w2, e12);
    if (d12_1 <= 0.0) {
        s.v2.a = 1.0;
        s.count = 1;
        s.v1 = s.v2;
        return -w2;
    }

    // Closest is on the edge w1-w2.
    const inv_d12: f32 = 1.0 / (d12_1 + d12_2);
    s.v1.a = d12_1 * inv_d12;
    s.v2.a = d12_2 * inv_d12;
    s.count = 2;
    return crossSV2(cross2(w1 + w2, e12), e12);
}

/// Reduce a 3-vertex simplex to the feature closest to the origin and return the
/// search direction; a zero return means the origin is inside the triangle (overlap).
/// box2d: b2SolveSimplex3  distance.c:309
/// Reduce a 3-vertex simplex (a triangle in the Minkowski difference) to the feature
/// closest to the origin by testing the seven Voronoi regions in order: the three vertices,
/// the three edges, and the interior. Sets the surviving vertices' barycentric weights and
/// `s.count`, and returns the direction toward the origin - or zero when the origin lies
/// inside the triangle, which means the shapes overlap. The `dXY_n` / `d123_n` values are
/// Box2D's edge and triangle barycentric numerators. box2d: b2SolveSimplex3
fn solveSimplex3(s: *Simplex) Vec2 {
    const w1: Vec2 = s.v1.w;
    const w2: Vec2 = s.v2.w;
    const w3: Vec2 = s.v3.w;

    // Edge barycentric numerators for the three edges.
    const e12: Vec2 = w2 - w1;
    const w1e12: f32 = dot2(w1, e12);
    const w2e12: f32 = dot2(w2, e12);
    const d12_1: f32 = w2e12;
    const d12_2: f32 = -w1e12;

    const e13: Vec2 = w3 - w1;
    const w1e13: f32 = dot2(w1, e13);
    const w3e13: f32 = dot2(w3, e13);
    const d13_1: f32 = w3e13;
    const d13_2: f32 = -w1e13;

    const e23: Vec2 = w3 - w2;
    const w2e23: f32 = dot2(w2, e23);
    const w3e23: f32 = dot2(w3, e23);
    const d23_1: f32 = w3e23;
    const d23_2: f32 = -w2e23;

    // Triangle barycentric numerators (signed-area weighted).
    const n123: f32 = cross2(e12, e13);
    const d123_1: f32 = n123 * cross2(w2, w3);
    const d123_2: f32 = n123 * cross2(w3, w1);
    const d123_3: f32 = n123 * cross2(w1, w2);

    // Vertex w1 region.
    if (d12_2 <= 0.0 and d13_2 <= 0.0) {
        s.v1.a = 1.0;
        s.count = 1;
        return -w1;
    }
    // Edge w1-w2 region.
    if (d12_1 > 0.0 and d12_2 > 0.0 and d123_3 <= 0.0) {
        const inv_d12: f32 = 1.0 / (d12_1 + d12_2);
        s.v1.a = d12_1 * inv_d12;
        s.v2.a = d12_2 * inv_d12;
        s.count = 2;
        return crossSV2(cross2(w1 + w2, e12), e12);
    }
    // Edge w1-w3 region.
    if (d13_1 > 0.0 and d13_2 > 0.0 and d123_2 <= 0.0) {
        const inv_d13: f32 = 1.0 / (d13_1 + d13_2);
        s.v1.a = d13_1 * inv_d13;
        s.v3.a = d13_2 * inv_d13;
        s.count = 2;
        s.v2 = s.v3;
        return crossSV2(cross2(w1 + w3, e13), e13);
    }
    // Vertex w2 region.
    if (d12_1 <= 0.0 and d23_2 <= 0.0) {
        s.v2.a = 1.0;
        s.count = 1;
        s.v1 = s.v2;
        return -w2;
    }
    // Vertex w3 region.
    if (d13_1 <= 0.0 and d23_1 <= 0.0) {
        s.v3.a = 1.0;
        s.count = 1;
        s.v1 = s.v3;
        return -w3;
    }
    // Edge w2-w3 region.
    if (d23_1 > 0.0 and d23_2 > 0.0 and d123_1 <= 0.0) {
        const inv_d23: f32 = 1.0 / (d23_1 + d23_2);
        s.v2.a = d23_1 * inv_d23;
        s.v3.a = d23_2 * inv_d23;
        s.count = 2;
        s.v1 = s.v3;
        return crossSV2(cross2(w2 + w3, e23), e23);
    }

    // Interior: the origin is inside the triangle (overlap).
    const inv_d123: f32 = 1.0 / (d123_1 + d123_2 + d123_3);
    s.v1.a = d123_1 * inv_d123;
    s.v2.a = d123_2 * inv_d123;
    s.v3.a = d123_3 * inv_d123;
    s.count = 3;
    return .{ 0.0, 0.0 };
}

/// GJK distance between two convex proxies.
///
/// GJK works on the Minkowski difference A (-) B: the shapes overlap iff that set contains
/// the origin. Each iteration keeps a simplex (1-3 points of the difference), reduces it to
/// the feature closest to the origin, and adds the support point farthest toward the
/// origin. A full triangle enclosing the origin means overlap; a repeated support point
/// means we've found the closest features. `cache` is read for a warm start and overwritten
/// with the resulting simplex for the next call (pass `SimplexCache.empty` for a cold
/// query). All outputs are in shape A's frame. box2d: b2ShapeDistance  distance.c:424
pub fn shapeDistance(input: *const DistanceInput, cache: *SimplexCache) DistanceOutput {
    assert(input.proxy_a.count > 0 and input.proxy_b.count > 0, @src());

    var output: DistanceOutput = .{
        .point_a = .{ 0, 0 },
        .point_b = .{ 0, 0 },
        .normal = .{ 0, 0 },
        .distance = 0.0,
        .iterations = 0,
    };

    const proxy_a: *const ShapeProxy = &input.proxy_a;

    // Pull proxy B into A's frame once, so the loop is transform-free.
    var local_proxy_b: ShapeProxy = undefined;
    local_proxy_b.count = input.proxy_b.count;
    local_proxy_b.radius = input.proxy_b.radius;
    {
        var i: usize = 0;
        while (i < local_proxy_b.count) : (i += 1) {
            local_proxy_b.points[i] = transformPoint2(input.transform, input.proxy_b.points[i]);
        }
    }

    var simplex: Simplex = makeSimplexFromCache(cache.*, proxy_a, &local_proxy_b);

    var non_unit_normal: Vec2 = .{ 0, 0 };

    // Remember the previous simplex's source indices to detect a stalled search.
    var save_a: [3]u32 = .{ 0, 0, 0 };
    var save_b: [3]u32 = .{ 0, 0, 0 };

    const max_iterations: u32 = 20;
    var iteration: u32 = 0;
    while (iteration < max_iterations) {
        // Snapshot the current simplex so we can detect a duplicate support point.
        const save_count: usize = simplex.count;
        {
            var i: usize = 0;
            while (i < save_count) : (i += 1) {
                const v: *SimplexVertex = simplexVertex(&simplex, i);
                save_a[i] = v.index_a;
                save_b[i] = v.index_b;
            }
        }

        // Reduce the simplex toward the origin; `search_direction` points from the closest
        // feature toward the origin (the direction to probe for the next support point).
        var search_direction: Vec2 = .{ 0, 0 };
        switch (simplex.count) {
            1 => search_direction = -simplex.v1.w,
            2 => search_direction = solveSimplex2(&simplex),
            3 => search_direction = solveSimplex3(&simplex),
            else => unreachable,
        }

        // A full triangle means the origin is enclosed: the shapes overlap.
        if (simplex.count == 3) {
            const witness: WitnessPoints = computeWitnessPoints(&simplex);
            output.point_a = witness.a;
            output.point_b = witness.b;
            return output;
        }

        // A vanishing search direction also signals overlap (origin on an edge/face).
        if (dot2(search_direction, search_direction) < floatEps(f32) * floatEps(f32)) {
            const witness: WitnessPoints = computeWitnessPoints(&simplex);
            output.point_a = witness.a;
            output.point_b = witness.b;
            return output;
        }

        non_unit_normal = search_direction;

        // New support vertex: support(A, dir) - support(B, -dir), the difference point
        // farthest toward the origin along the search direction.
        const vertex: *SimplexVertex = simplexVertex(&simplex, simplex.count);
        vertex.index_a = findSupport(proxy_a, search_direction);
        vertex.wa = proxy_a.points[vertex.index_a];
        vertex.index_b = findSupport(&local_proxy_b, -search_direction);
        vertex.wb = local_proxy_b.points[vertex.index_b];
        vertex.w = vertex.wa - vertex.wb;

        iteration += 1;

        // Terminate if the support point repeats (we cannot make further progress).
        var duplicate: bool = false;
        {
            var i: usize = 0;
            while (i < save_count) : (i += 1) {
                if (vertex.index_a == save_a[i] and vertex.index_b == save_b[i]) {
                    duplicate = true;
                    break;
                }
            }
        }
        if (duplicate) {
            break;
        }

        simplex.count += 1;
    }

    // Finalize in frame A.
    const normal: Vec2 = normalizeOrZero2(non_unit_normal);
    const witness: WitnessPoints = computeWitnessPoints(&simplex);
    output.normal = normal;
    output.distance = distance2(witness.a, witness.b);
    output.point_a = witness.a;
    output.point_b = witness.b;
    output.iterations = iteration;

    cache.* = makeSimplexCache(&simplex);

    // Optionally back the closest points off by each radius (smooth perimeter points).
    if (input.use_radii) {
        const radius_a: f32 = input.proxy_a.radius;
        const radius_b: f32 = input.proxy_b.radius;
        output.distance = @max(0.0, output.distance - radius_a - radius_b);
        output.point_a = mulAdd2(output.point_a, radius_a, normal);
        output.point_b = mulSub2(output.point_b, radius_b, normal);
    }

    return output;
}

// ================================================================================
// Shape cast (conservative advancement)
//
// Slides shape B by `translation_b` (in A's frame) until it first touches shape A,
// returning the hit fraction, point, and normal. Used by scene shape-casts and as a
// building block elsewhere. box2d: b2ShapeCast  distance.c:609
// ================================================================================

/// The result of a ray or shape cast: where and when it hit, if at all.
/// box2d: b2CastOutput  collision.h
pub const CastOutput = struct {
    normal: Vec2,
    point: Vec2,
    fraction: f32,
    iterations: u32,
    hit: bool,

    pub const miss: CastOutput = .{
        .normal = .{ 0, 0 },
        .point = .{ 0, 0 },
        .fraction = 0.0,
        .iterations = 0,
        .hit = false,
    };
};

/// Inputs to a proxy-vs-proxy shape cast.
/// box2d: b2ShapeCastPairInput  collision.h
pub const ShapeCastPairInput = struct {
    proxy_a: ShapeProxy,
    proxy_b: ShapeProxy,
    transform: Transform2, // pose of B in A's frame at the start of the cast
    translation_b: Vec2, // motion of B in A's frame
    max_fraction: f32, // usually 1.0
    can_encroach: bool, // allow already-touching rounded shapes to slide a little closer
};

/// Cast shape B along `translation_b` against shape A. Returns where B first comes
/// within the combined radius of A. box2d: b2ShapeCast  distance.c:609
pub fn shapeCast(input: *const ShapeCastPairInput) CastOutput {
    const total_radius: f32 = input.proxy_a.radius + input.proxy_b.radius;
    var target: f32 = @max(linear_slop, total_radius - linear_slop);
    const tolerance: f32 = 0.25 * linear_slop;
    assert(target > tolerance, @src());

    var cache: SimplexCache = SimplexCache.empty;
    var fraction: f32 = 0.0;

    var distance_input: DistanceInput = .{
        .proxy_a = input.proxy_a,
        .proxy_b = input.proxy_b,
        .transform = input.transform, // advanced in-place below
        .use_radii = false,
    };

    const delta: Vec2 = input.translation_b;
    var output: CastOutput = CastOutput.miss;

    var iteration: u32 = 0;
    const max_iterations: u32 = 20;
    while (iteration < max_iterations) : (iteration += 1) {
        output.iterations += 1;
        const dist: DistanceOutput = shapeDistance(&distance_input, &cache);

        if (dist.distance < target + tolerance) {
            if (iteration == 0) {
                if (input.can_encroach and dist.distance > 2.0 * linear_slop) {
                    // Already-touching rounded shapes: aim a hair closer rather than
                    // reporting an immediate hit.
                    target = dist.distance - linear_slop;
                } else {
                    // Initial overlap - report a hit at fraction 0 with a midpoint.
                    output.hit = true;
                    const surface_a: Vec2 = mulAdd2(dist.point_a, input.proxy_a.radius, dist.normal);
                    const surface_b: Vec2 = mulAdd2(dist.point_b, -input.proxy_b.radius, dist.normal);
                    output.point = (surface_a + surface_b) * splat2(0.5);
                    return output;
                }
            } else {
                // A clean hit partway along the translation.
                output.fraction = fraction;
                output.point = mulAdd2(dist.point_a, input.proxy_a.radius, dist.normal);
                output.normal = dist.normal;
                output.hit = true;
                return output;
            }
        }

        // Are the shapes actually approaching along the contact normal?
        const denominator: f32 = dot2(delta, dist.normal);
        if (denominator >= 0.0) {
            return output; // miss - moving apart
        }

        // Conservative advancement: step the fraction so we just reach `target`.
        fraction += (target - dist.distance) / denominator;
        if (fraction >= input.max_fraction) {
            return output; // miss - would pass the end of the translation
        }
        distance_input.transform.p = mulAdd2(input.transform.p, fraction, delta);
    }

    return output; // ran out of iterations - treat as a miss
}

// ================================================================================
// Time of impact (continuous collision)
//
// Finds the earliest sweep fraction at which two moving convex shapes first touch,
// via the local separating-axis method: an outer loop re-derives a separating axis
// from a GJK distance query, an inner loop pushes the deepest point forward, and a
// 1D root finder (false-position + bisection) lands the impact time.
// box2d: b2TimeOfImpact  distance.c:1143
// ================================================================================

/// The outcome class of a time-of-impact query.
/// box2d: b2TOIState  collision.h
pub const TOIState = enum {
    unknown,
    failed, // root finder gave up; `fraction` is a best-effort estimate
    overlapped, // already overlapping at the start
    hit, // touched within the sweep
    separated, // never touched over the whole sweep
};

/// Inputs to a time-of-impact query: two proxies and their motion sweeps.
/// box2d: b2TOIInput  collision.h
pub const TOIInput = struct {
    proxy_a: ShapeProxy,
    proxy_b: ShapeProxy,
    sweep_a: Sweep2,
    sweep_b: Sweep2,
    max_fraction: f32, // sweep interval is [0, max_fraction]
};

/// The outcome of a time-of-impact query, in world space.
/// box2d: b2TOIOutput  collision.h
pub const TOIOutput = struct {
    state: TOIState,
    point: Vec2,
    normal: Vec2,
    fraction: f32,
};

/// How the separating axis is anchored: between two vertices, or on a face of A/B.
/// box2d: b2SeparationType  distance.c:931
const SeparationType = enum { points, face_a, face_b };

/// A separating axis that persists across the TOI inner/root loops.
/// box2d: b2SeparationFunction  distance.c:938
/// A separating axis frozen from the GJK simplex at the start of a TOI interval. The root
/// finder evaluates the separation along this axis as the sweep advances. There are three
/// kinds, matching which feature the simplex closed on: `points` (vertex-vertex, the axis is
/// the line between them), `face_a` (the axis is an edge normal on A), and `face_b` (an edge
/// normal on B). box2d: b2SeparationFunction  distance.c:940
const SeparationFunction = struct {
    proxy_a: *const ShapeProxy,
    proxy_b: *const ShapeProxy,
    sweep_a: Sweep2,
    sweep_b: Sweep2,
    local_point: Vec2, // the face midpoint (face types); unused for the points type
    axis: Vec2, // the separating axis, oriented so growing separation is positive
    kind: SeparationType,
};

/// Build the separating axis from the current GJK simplex cache at sweep time `t1`.
/// box2d: b2MakeSeparationFunction  distance.c:948
fn makeSeparationFunction(
    cache: SimplexCache,
    proxy_a: *const ShapeProxy,
    sweep_a: Sweep2,
    proxy_b: *const ShapeProxy,
    sweep_b: Sweep2,
    t1: f32,
) SeparationFunction {
    var sep_fn: SeparationFunction = undefined;
    sep_fn.proxy_a = proxy_a;
    sep_fn.proxy_b = proxy_b;
    sep_fn.sweep_a = sweep_a;
    sep_fn.sweep_b = sweep_b;
    const count: usize = cache.count;
    assert(0 < count and count < 3, @src());

    const xf_a: Transform2 = sweepTransform2(sweep_a, t1);
    const xf_b: Transform2 = sweepTransform2(sweep_b, t1);

    if (count == 1) {
        // Vertex-vertex: the axis is the line between the two witness points.
        sep_fn.kind = .points;
        const local_a: Vec2 = proxy_a.points[cache.index_a[0]];
        const local_b: Vec2 = proxy_b.points[cache.index_b[0]];
        const point_a: Vec2 = transformPoint2(xf_a, local_a);
        const point_b: Vec2 = transformPoint2(xf_b, local_b);
        sep_fn.axis = normalizeOrZero2(point_b - point_a);
        sep_fn.local_point = .{ 0, 0 };
        return sep_fn;
    }

    if (cache.index_a[0] == cache.index_a[1]) {
        // Face on B (two B vertices, one A vertex): axis is the B edge normal.
        sep_fn.kind = .face_b;
        const local_b1: Vec2 = proxy_b.points[cache.index_b[0]];
        const local_b2: Vec2 = proxy_b.points[cache.index_b[1]];
        sep_fn.axis = normalizeOrZero2(crossVS2(local_b2 - local_b1, 1.0));
        const normal: Vec2 = rotateVec2(xf_b.q, sep_fn.axis);
        sep_fn.local_point = (local_b1 + local_b2) * splat2(0.5);
        const point_b: Vec2 = transformPoint2(xf_b, sep_fn.local_point);

        const local_a: Vec2 = proxy_a.points[cache.index_a[0]];
        const point_a: Vec2 = transformPoint2(xf_a, local_a);

        // Orient the axis so positive separation points away from A.
        if (dot2(point_a - point_b, normal) < 0.0) {
            sep_fn.axis = -sep_fn.axis;
        }
        return sep_fn;
    }

    // Face on A (two A vertices): axis is the A edge normal.
    sep_fn.kind = .face_a;
    const local_a1: Vec2 = proxy_a.points[cache.index_a[0]];
    const local_a2: Vec2 = proxy_a.points[cache.index_a[1]];
    sep_fn.axis = normalizeOrZero2(crossVS2(local_a2 - local_a1, 1.0));
    const normal: Vec2 = rotateVec2(xf_a.q, sep_fn.axis);
    sep_fn.local_point = (local_a1 + local_a2) * splat2(0.5);
    const point_a: Vec2 = transformPoint2(xf_a, sep_fn.local_point);

    const local_b: Vec2 = proxy_b.points[cache.index_b[0]];
    const point_b: Vec2 = transformPoint2(xf_b, local_b);

    if (dot2(point_b - point_a, normal) < 0.0) {
        sep_fn.axis = -sep_fn.axis;
    }
    return sep_fn;
}

/// The minimum separation along the axis at sweep time `t`, plus the witness vertex
/// indices that achieve it. A face type returns -1 for its own (face-side) index,
/// which `evaluateSeparation` never dereferences.
/// box2d: b2FindMinSeparation  distance.c:1024
const MinSeparation = struct { separation: f32, index_a: i32, index_b: i32 };

fn findMinSeparation(sep_fn: *const SeparationFunction, t: f32) MinSeparation {
    const xf_a: Transform2 = sweepTransform2(sep_fn.sweep_a, t);
    const xf_b: Transform2 = sweepTransform2(sep_fn.sweep_b, t);

    switch (sep_fn.kind) {
        .points => {
            const axis_a: Vec2 = invRotateVec2(xf_a.q, sep_fn.axis);
            const axis_b: Vec2 = invRotateVec2(xf_b.q, -sep_fn.axis);
            const index_a: u32 = findSupport(sep_fn.proxy_a, axis_a);
            const index_b: u32 = findSupport(sep_fn.proxy_b, axis_b);
            const point_a: Vec2 = transformPoint2(xf_a, sep_fn.proxy_a.points[index_a]);
            const point_b: Vec2 = transformPoint2(xf_b, sep_fn.proxy_b.points[index_b]);
            const sep: f32 = dot2(point_b - point_a, sep_fn.axis);
            return .{ .separation = sep, .index_a = @intCast(index_a), .index_b = @intCast(index_b) };
        },
        .face_a => {
            const normal: Vec2 = rotateVec2(xf_a.q, sep_fn.axis);
            const point_a: Vec2 = transformPoint2(xf_a, sep_fn.local_point);
            const axis_b: Vec2 = invRotateVec2(xf_b.q, -normal);
            const index_b: u32 = findSupport(sep_fn.proxy_b, axis_b);
            const point_b: Vec2 = transformPoint2(xf_b, sep_fn.proxy_b.points[index_b]);
            const sep: f32 = dot2(point_b - point_a, normal);
            return .{ .separation = sep, .index_a = -1, .index_b = @intCast(index_b) };
        },
        .face_b => {
            const normal: Vec2 = rotateVec2(xf_b.q, sep_fn.axis);
            const point_b: Vec2 = transformPoint2(xf_b, sep_fn.local_point);
            const axis_a: Vec2 = invRotateVec2(xf_a.q, -normal);
            const index_a: u32 = findSupport(sep_fn.proxy_a, axis_a);
            const point_a: Vec2 = transformPoint2(xf_a, sep_fn.proxy_a.points[index_a]);
            const sep: f32 = dot2(point_a - point_b, normal);
            return .{ .separation = sep, .index_a = @intCast(index_a), .index_b = -1 };
        },
    }
}

/// The separation along the axis at sweep time `t` for fixed witness indices (used by
/// the root finder, which holds the indices constant while it bisects `t`).
/// box2d: b2EvaluateSeparation  distance.c:1092
fn evaluateSeparation(
    sep_fn: *const SeparationFunction,
    index_a: i32,
    index_b: i32,
    t: f32,
) f32 {
    const xf_a: Transform2 = sweepTransform2(sep_fn.sweep_a, t);
    const xf_b: Transform2 = sweepTransform2(sep_fn.sweep_b, t);

    switch (sep_fn.kind) {
        .points => {
            const point_a: Vec2 = transformPoint2(xf_a, sep_fn.proxy_a.points[@intCast(index_a)]);
            const point_b: Vec2 = transformPoint2(xf_b, sep_fn.proxy_b.points[@intCast(index_b)]);
            return dot2(point_b - point_a, sep_fn.axis);
        },
        .face_a => {
            const normal: Vec2 = rotateVec2(xf_a.q, sep_fn.axis);
            const point_a: Vec2 = transformPoint2(xf_a, sep_fn.local_point);
            const point_b: Vec2 = transformPoint2(xf_b, sep_fn.proxy_b.points[@intCast(index_b)]);
            return dot2(point_b - point_a, normal);
        },
        .face_b => {
            const normal: Vec2 = rotateVec2(xf_b.q, sep_fn.axis);
            const point_b: Vec2 = transformPoint2(xf_b, sep_fn.local_point);
            const point_a: Vec2 = transformPoint2(xf_a, sep_fn.proxy_a.points[@intCast(index_a)]);
            return dot2(point_a - point_b, normal);
        },
    }
}

/// Earliest sweep fraction at which the two moving shapes touch (within their combined
/// radius). box2d: b2TimeOfImpact  distance.c:1143
pub fn timeOfImpact(input: *const TOIInput) TOIOutput {
    var output: TOIOutput = .{
        .state = .unknown,
        .point = .{ 0, 0 },
        .normal = .{ 0, 0 },
        .fraction = input.max_fraction,
    };

    const sweep_a: Sweep2 = input.sweep_a;
    const sweep_b: Sweep2 = input.sweep_b;
    const proxy_a: *const ShapeProxy = &input.proxy_a;
    const proxy_b: *const ShapeProxy = &input.proxy_b;

    const t_max: f32 = input.max_fraction;
    const total_radius: f32 = proxy_a.radius + proxy_b.radius;
    const target: f32 = @max(linear_slop, total_radius - linear_slop);
    const tolerance: f32 = 0.25 * linear_slop;
    assert(target > tolerance, @src());

    var t1: f32 = 0.0;
    const max_distance_iterations: u32 = 20;
    var distance_iterations: u32 = 0;

    var cache: SimplexCache = SimplexCache.empty;
    var distance_input: DistanceInput = .{
        .proxy_a = input.proxy_a,
        .proxy_b = input.proxy_b,
        .transform = Transform2.identity, // set each outer iteration
        .use_radii = false,
    };

    // Outer loop: re-derive a separating axis until no progress is possible.
    outer: while (true) {
        const xf_a: Transform2 = sweepTransform2(sweep_a, t1);
        const xf_b: Transform2 = sweepTransform2(sweep_b, t1);
        distance_input.transform = invMulTransforms2(xf_a, xf_b);
        const dist: DistanceOutput = shapeDistance(&distance_input, &cache);

        // Project the frame-A witness data back to world for the eventual hit report.
        const world_normal: Vec2 = rotateVec2(xf_a.q, dist.normal);
        const world_point_a: Vec2 = transformPoint2(xf_a, dist.point_a);
        const world_point_b: Vec2 = transformPoint2(xf_a, dist.point_b);

        distance_iterations += 1;

        // Already overlapping: continuous collision cannot help.
        if (dist.distance <= 0.0) {
            output.state = .overlapped;
            output.fraction = 0.0;
            break :outer;
        }

        // Close enough at the current time: a hit at t1.
        if (dist.distance <= target + tolerance) {
            output.state = .hit;
            const surface_a: Vec2 = mulAdd2(world_point_a, proxy_a.radius, world_normal);
            const surface_b: Vec2 = mulAdd2(world_point_b, -proxy_b.radius, world_normal);
            output.point = (surface_a + surface_b) * splat2(0.5);
            output.normal = world_normal;
            output.fraction = t1;
            break :outer;
        }

        const separation_fn: SeparationFunction =
            makeSeparationFunction(cache, proxy_a, sweep_a, proxy_b, sweep_b, t1);

        // Inner loop: push the deepest point forward along the axis.
        var done: bool = false;
        var t2: f32 = t_max;
        var push_back_iterations: u32 = 0;
        inner: while (true) {
            // Deepest separation at the far end of the current interval.
            const ms2: MinSeparation = findMinSeparation(&separation_fn, t2);
            var s2: f32 = ms2.separation;
            const index_a: i32 = ms2.index_a;
            const index_b: i32 = ms2.index_b;

            // Fully separated at t2 - the shapes never touch within the sweep.
            if (s2 > target + tolerance) {
                output.state = .separated;
                output.fraction = t_max;
                done = true;
                break :inner;
            }
            // Within tolerance at t2 - advance the outer time to t2 and re-derive.
            if (s2 > target - tolerance) {
                t1 = t2;
                break :inner;
            }

            // Separation of the same witness points at the near end t1.
            var s1: f32 = evaluateSeparation(&separation_fn, index_a, index_b, t1);

            // Initial overlap of the witness points: root finder ran out of room.
            if (s1 < target - tolerance) {
                output.state = .failed;
                output.fraction = t1;
                done = true;
                break :inner;
            }
            // Touching at t1 - t1 is the impact time.
            if (s1 <= target + tolerance) {
                output.state = .hit;
                const pa: Vec2 = mulAdd2(world_point_a, proxy_a.radius, world_normal);
                const pb: Vec2 = mulAdd2(world_point_b, -proxy_b.radius, world_normal);
                output.point = (pa + pb) * splat2(0.5);
                output.normal = world_normal;
                output.fraction = t1;
                done = true;
                break :inner;
            }

            // 1D root find of separation(t) == target on [t1, t2], mixing
            // false-position (fast) with bisection (guaranteed progress).
            var root_iteration: u32 = 0;
            var a1: f32 = t1;
            var a2: f32 = t2;
            while (true) {
                var t: f32 = undefined;
                if ((root_iteration & 1) != 0) {
                    t = a1 + (target - s1) * (a2 - a1) / (s2 - s1);
                } else {
                    t = 0.5 * (a1 + a2);
                }
                root_iteration += 1;

                const s: f32 = evaluateSeparation(&separation_fn, index_a, index_b, t);

                if (@abs(s - target) < tolerance) {
                    t2 = t; // tentative new t1
                    break;
                }
                // Keep bracketing the root.
                if (s > target) {
                    a1 = t;
                    s1 = s;
                } else {
                    a2 = t;
                    s2 = s;
                }
                if (root_iteration == 50) {
                    break;
                }
            }

            push_back_iterations += 1;
            if (push_back_iterations == max_polygon_vertices) {
                break :inner;
            }
        }

        if (done) {
            break :outer;
        }

        if (distance_iterations == max_distance_iterations) {
            // Root finder stuck - report a best-effort hit (semi-victory).
            output.state = .failed;
            const pa: Vec2 = mulAdd2(world_point_a, proxy_a.radius, world_normal);
            const pb: Vec2 = mulAdd2(world_point_b, -proxy_b.radius, world_normal);
            output.point = (pa + pb) * splat2(0.5);
            output.normal = world_normal;
            output.fraction = t1;
            break :outer;
        }
    }

    return output;
}

// ================================================================================
// Manifold generation
//
// A collide function takes two shapes and the relative pose of B in A's frame, and
// returns a LOCAL manifold (in shape A's frame): a contact normal plus up to two
// contact points carrying a separation and a stable feature id. `updateContact`
// (section 14) later marshals this into the persistent, COM-relative `Manifold` the solver
// consumes. box2d: manifold.c
// ================================================================================

/// One contact point of a freshly generated local manifold, in shape A's frame.
/// box2d: b2LocalManifoldPoint  collision.h:602
pub const LocalManifoldPoint = struct {
    point: Vec2,
    separation: f32, // negative if penetrating
    id: u16, // stable feature id, used to match impulses across steps
};

/// A freshly generated contact manifold in shape A's frame (collide-function output).
/// box2d: b2LocalManifold  collision.h
pub const LocalManifold = struct {
    normal: Vec2, // unit, points from A to B
    points: [2]LocalManifoldPoint,
    count: u32,

    pub const empty: LocalManifold = .{
        .normal = .{ 0, 0 },
        .points = .{
            .{ .point = .{ 0, 0 }, .separation = 0, .id = 0 },
            .{ .point = .{ 0, 0 }, .separation = 0, .id = 0 },
        },
        .count = 0,
    };
};

/// One contact point of the persistent manifold the solver works on. Anchors are
/// relative to each body's center of mass in world orientation; impulses persist
/// across steps for warm starting. box2d: b2ManifoldPoint  collision.h
pub const ManifoldPoint = struct {
    anchor_a: Vec2, // contact point relative to body A's COM (world frame)
    anchor_b: Vec2, // contact point relative to body B's COM (world frame)
    separation: f32, // negative if penetrating
    base_separation: f32, // separation with the anchor offset removed (recycling)
    normal_impulse: f32,
    tangent_impulse: f32,
    total_normal_impulse: f32, // accumulated across sub-steps + restitution
    normal_velocity: f32, // pre-solve relative normal velocity (for hit events)
    id: u16,
    persisted: bool, // did this point exist last step?
};

/// The persistent contact manifold the solver consumes (post-marshal).
/// box2d: b2Manifold  collision.h
pub const Manifold = struct {
    normal: Vec2, // unit, world space, points from A to B
    rolling_impulse: f32,
    points: [2]ManifoldPoint,
    count: u32,

    pub const empty: Manifold = std.mem.zeroes(Manifold);
};

/// Pack two feature indices into a stable 16-bit contact-point id (high byte = A's
/// feature, low byte = B's). box2d: B2_MAKE_ID  manifold.c
inline fn makeId(a: u32, b: u32) u16 {
    const hi: u16 = @as(u8, @truncate(a));
    const lo: u16 = @as(u8, @truncate(b));
    return (hi << 8) | lo;
}

/// Linear interpolation between two points: `a` at t=0, `b` at t=1.
inline fn lerp2(a: Vec2, b: Vec2, t: f32) Vec2 {
    return a + (b - a) * splat2(t);
}

/// Build a 2-vertex "capsule polygon" so the polygon clipper can handle capsules and
/// segments uniformly. box2d: b2MakeCapsule  manifold.c
fn makeCapsulePolygon(p1: Vec2, p2: Vec2, radius: f32) Polygon {
    var shape: Polygon = undefined;
    shape.vertices[0] = p1;
    shape.vertices[1] = p2;
    shape.centroid = lerp2(p1, p2, 0.5);
    const d: Vec2 = p2 - p1;
    assert(lengthSq2(d) > floatEps(f32), @src());
    const axis: Vec2 = normalizeOrZero2(d);
    const normal: Vec2 = rightPerp2(axis);
    shape.normals[0] = normal;
    shape.normals[1] = -normal;
    shape.count = 2;
    shape.radius = radius;
    return shape;
}

/// Circle vs circle.  box2d: b2CollideCircles  manifold.c:36
pub fn collideCircles(circle_a: Circle, circle_b: Circle, xf: Transform2) LocalManifold {
    var manifold: LocalManifold = LocalManifold.empty;

    const center_a: Vec2 = circle_a.center;
    const center_b: Vec2 = transformPoint2(xf, circle_b.center); // into A's frame

    var dist: f32 = undefined;
    const normal: Vec2 = getLengthAndNormalize2(&dist, center_b - center_a);

    const radius_a: f32 = circle_a.radius;
    const radius_b: f32 = circle_b.radius;
    const separation: f32 = dist - radius_a - radius_b;
    if (separation > speculative_distance) {
        return manifold;
    }

    // Contact point is the midpoint of the two surface points along the normal.
    const surface_a: Vec2 = mulAdd2(center_a, radius_a, normal);
    const surface_b: Vec2 = mulAdd2(center_b, -radius_b, normal);

    manifold.normal = normal;
    manifold.points[0] = .{ .point = lerp2(surface_a, surface_b, 0.5), .separation = separation, .id = 0 };
    manifold.count = 1;
    return manifold;
}

/// Capsule vs circle.  box2d: b2CollideCapsuleAndCircle  manifold.c:68
pub fn collideCapsuleAndCircle(
    capsule_a: Capsule,
    circle_b: Circle,
    xf: Transform2,
) LocalManifold {
    var manifold: LocalManifold = LocalManifold.empty;

    const circle_center: Vec2 = transformPoint2(xf, circle_b.center); // into A's frame
    const seg_a: Vec2 = capsule_a.center1;
    const seg_b: Vec2 = capsule_a.center2;
    const edge: Vec2 = seg_b - seg_a;

    // Closest point on the capsule's core segment to the circle center.
    var closest: Vec2 = undefined;
    const reach_from_a: f32 = dot2(circle_center - seg_a, edge);
    const reach_from_b: f32 = dot2(seg_b - circle_center, edge);
    if (reach_from_a < 0.0) {
        closest = seg_a; // before seg_a
    } else if (reach_from_b < 0.0) {
        closest = seg_b; // past seg_b
    } else {
        const t: f32 = reach_from_a / dot2(edge, edge); // interior parameter in [0, 1]
        closest = mulAdd2(seg_a, t, edge);
    }

    var dist: f32 = undefined;
    const normal: Vec2 = getLengthAndNormalize2(&dist, circle_center - closest);

    const radius_a: f32 = capsule_a.radius;
    const radius_b: f32 = circle_b.radius;
    const separation: f32 = dist - radius_a - radius_b;
    if (separation > speculative_distance) {
        return manifold;
    }

    const surface_a: Vec2 = mulAdd2(closest, radius_a, normal);
    const surface_b: Vec2 = mulAdd2(circle_center, -radius_b, normal);

    manifold.normal = normal;
    manifold.points[0] = .{ .point = lerp2(surface_a, surface_b, 0.5), .separation = separation, .id = 0 };
    manifold.count = 1;
    return manifold;
}

/// Polygon vs circle.  box2d: b2CollidePolygonAndCircle  manifold.c:127
pub fn collidePolygonAndCircle(
    polygon_a: Polygon,
    circle_b: Circle,
    xf: Transform2,
) LocalManifold {
    var manifold: LocalManifold = LocalManifold.empty;
    const eps: f32 = floatEps(f32);

    const center: Vec2 = transformPoint2(xf, circle_b.center);
    const radius_a: f32 = polygon_a.radius;
    const radius_b: f32 = circle_b.radius;
    const radius: f32 = radius_a + radius_b;

    // Find the polygon edge of maximum separation from the circle center.
    var normal_index: usize = 0;
    var separation: f32 = -floatMax(f32);
    const vertex_count: usize = polygon_a.count;
    var i: usize = 0;
    while (i < vertex_count) : (i += 1) {
        const s: f32 = dot2(polygon_a.normals[i], center - polygon_a.vertices[i]);
        if (s > separation) {
            separation = s;
            normal_index = i;
        }
    }
    if (separation > radius + speculative_distance) {
        return manifold;
    }

    // The reference edge's two vertices.
    const vi1: usize = normal_index;
    const vi2: usize = if (vi1 + 1 < vertex_count) vi1 + 1 else 0;
    const v1: Vec2 = polygon_a.vertices[vi1];
    const v2: Vec2 = polygon_a.vertices[vi2];

    // Where does the center fall relative to the edge?
    const du1: f32 = dot2(center - v1, v2 - v1);
    const du2: f32 = dot2(center - v2, v1 - v2);

    if (du1 < 0.0 and separation > eps) {
        // Closest to vertex v1 (and outside the polygon).
        const normal: Vec2 = normalizeOrZero2(center - v1);
        const sep: f32 = dot2(center - v1, normal);
        if (sep > radius + speculative_distance) {
            return manifold;
        }
        const surface_a: Vec2 = mulAdd2(v1, radius_a, normal);
        const surface_b: Vec2 = mulSub2(center, radius_b, normal);
        manifold.normal = normal;
        manifold.points[0] = .{
            .point = lerp2(surface_a, surface_b, 0.5),
            .separation = dot2(surface_b - surface_a, normal),
            .id = 0,
        };
        manifold.count = 1;
    } else if (du2 < 0.0 and separation > eps) {
        // Closest to vertex v2 (and outside the polygon).
        const normal: Vec2 = normalizeOrZero2(center - v2);
        const sep: f32 = dot2(center - v2, normal);
        if (sep > radius + speculative_distance) {
            return manifold;
        }
        const surface_a: Vec2 = mulAdd2(v2, radius_a, normal);
        const surface_b: Vec2 = mulSub2(center, radius_b, normal);
        manifold.normal = normal;
        manifold.points[0] = .{
            .point = lerp2(surface_a, surface_b, 0.5),
            .separation = dot2(surface_b - surface_a, normal),
            .id = 0,
        };
        manifold.count = 1;
    } else {
        // Center projects onto the edge interior (may be inside the polygon).
        const normal: Vec2 = polygon_a.normals[normal_index];
        manifold.normal = normal;
        // Project the center onto the edge for cA; deepest circle point for cB.
        const surface_a: Vec2 = mulAdd2(center, radius_a - dot2(center - v1, normal), normal);
        const surface_b: Vec2 = mulSub2(center, radius_b, normal);
        manifold.points[0] = .{
            .point = lerp2(surface_a, surface_b, 0.5),
            .separation = separation - radius,
            .id = 0,
        };
        manifold.count = 1;
    }
    return manifold;
}

/// Capsule vs capsule. Follows Ericson 5.1.9 (closest points of two segments) with
/// extra clipping logic to recover a two-point manifold for stable stacking.
/// box2d: b2CollideCapsules  manifold.c:237
pub fn collideCapsules(
    capsule_a: Capsule,
    capsule_b: Capsule,
    xf: Transform2,
) LocalManifold {
    // Work relative to capsule A's first endpoint to reduce round-off.
    const origin: Vec2 = capsule_a.center1;
    const xfs: Transform2 = .{ .p = xf.p - origin, .q = xf.q };

    const p1: Vec2 = .{ 0, 0 };
    const q1: Vec2 = capsule_a.center2 - origin;
    const p2: Vec2 = transformPoint2(xfs, capsule_b.center1);
    const q2: Vec2 = transformPoint2(xfs, capsule_b.center2);

    const d1: Vec2 = q1 - p1; // segment A direction
    const d2: Vec2 = q2 - p2; // segment B direction
    const dd1: f32 = dot2(d1, d1);
    const dd2: f32 = dot2(d2, d2);
    const eps_sq: f32 = floatEps(f32) * floatEps(f32);
    assert(dd1 > eps_sq and dd2 > eps_sq, @src());

    const r: Vec2 = p1 - p2;
    const rd1: f32 = dot2(r, d1);
    const rd2: f32 = dot2(r, d2);
    const d12: f32 = dot2(d1, d2);
    const denom: f32 = dd1 * dd2 - d12 * d12;

    // Closest fraction on segment A.
    var f1: f32 = 0.0;
    if (denom != 0.0) {
        f1 = clamp((d12 * rd2 - rd1 * dd2) / denom, 0.0, 1.0);
    }
    // Closest fraction on segment B to A's point; re-clamp A if B clamps.
    var f2: f32 = (d12 * f1 + rd2) / dd2;
    if (f2 < 0.0) {
        f2 = 0.0;
        f1 = clamp(-rd1 / dd1, 0.0, 1.0);
    } else if (f2 > 1.0) {
        f2 = 1.0;
        f1 = clamp((d12 - rd1) / dd1, 0.0, 1.0);
    }

    const closest1: Vec2 = mulAdd2(p1, f1, d1);
    const closest2: Vec2 = mulAdd2(p2, f2, d2);
    const distance_squared: f32 = lengthSq2(closest1 - closest2);

    var manifold: LocalManifold = LocalManifold.empty;
    const radius_a: f32 = capsule_a.radius;
    const radius_b: f32 = capsule_b.radius;
    const radius: f32 = radius_a + radius_b;
    const max_distance: f32 = radius + speculative_distance;
    if (distance_squared > max_distance * max_distance) {
        return manifold;
    }
    const dist: f32 = @sqrt(distance_squared);

    var length1: f32 = undefined;
    var length2_: f32 = undefined;
    const unit1: Vec2 = getLengthAndNormalize2(&length1, d1);
    const unit2: Vec2 = getLengthAndNormalize2(&length2_, d2);

    // Does B project entirely outside A's segment span (and vice versa)?
    const fp2: f32 = dot2(p2 - p1, unit1);
    const fq2: f32 = dot2(q2 - p1, unit1);
    const outside_a: bool = (fp2 <= 0.0 and fq2 <= 0.0) or (fp2 >= length1 and fq2 >= length1);

    const fp1: f32 = dot2(p1 - p2, unit2);
    const fq1: f32 = dot2(q1 - p2, unit2);
    const outside_b: bool = (fp1 <= 0.0 and fq1 <= 0.0) or (fp1 >= length2_ and fq1 >= length2_);

    if (outside_a == false and outside_b == false) {
        // Both segments overlap in projection: try a two-point (edge) manifold via SAT.
        var normal_a: Vec2 = leftPerp2(unit1);
        var separation_a: f32 = undefined;
        {
            const ss1: f32 = dot2(p2 - p1, normal_a);
            const ss2: f32 = dot2(q2 - p1, normal_a);
            const s_pos: f32 = @min(ss1, ss2);
            const s_neg: f32 = @min(-ss1, -ss2);
            if (s_pos > s_neg) {
                separation_a = s_pos;
            } else {
                separation_a = s_neg;
                normal_a = -normal_a;
            }
        }

        var normal_b: Vec2 = leftPerp2(unit2);
        var separation_b: f32 = undefined;
        {
            const ss1: f32 = dot2(p1 - p2, normal_b);
            const ss2: f32 = dot2(q1 - p2, normal_b);
            const s_pos: f32 = @min(ss1, ss2);
            const s_neg: f32 = @min(-ss1, -ss2);
            if (s_pos > s_neg) {
                separation_b = s_pos;
            } else {
                separation_b = s_neg;
                normal_b = -normal_b;
            }
        }

        // Pick a reference edge, slightly biased toward A to avoid feature flip-flop.
        if (separation_a + 0.1 * linear_slop >= separation_b) {
            manifold.normal = normal_a;
            var cp: Vec2 = p2;
            var cq: Vec2 = q2;
            // Clip B's segment to A's span [0, length1] along unit1.
            if (fp2 < 0.0 and fq2 > 0.0) {
                cp = lerp2(p2, q2, (0.0 - fp2) / (fq2 - fp2));
            } else if (fq2 < 0.0 and fp2 > 0.0) {
                cq = lerp2(q2, p2, (0.0 - fq2) / (fp2 - fq2));
            }
            if (fp2 > length1 and fq2 < length1) {
                cp = lerp2(p2, q2, (fp2 - length1) / (fp2 - fq2));
            } else if (fq2 > length1 and fp2 < length1) {
                cq = lerp2(q2, p2, (fq2 - length1) / (fq2 - fp2));
            }
            const sp: f32 = dot2(cp - p1, normal_a);
            const sq: f32 = dot2(cq - p1, normal_a);
            if (sp <= dist + linear_slop or sq <= dist + linear_slop) {
                manifold.points[0] = .{
                    .point = mulAdd2(cp, 0.5 * (radius_a - radius_b - sp), normal_a),
                    .separation = sp - radius,
                    .id = makeId(0, 0),
                };
                manifold.points[1] = .{
                    .point = mulAdd2(cq, 0.5 * (radius_a - radius_b - sq), normal_a),
                    .separation = sq - radius,
                    .id = makeId(0, 1),
                };
                manifold.count = 2;
            }
        } else {
            manifold.normal = -normal_b; // normal always points A -> B
            var cp: Vec2 = p1;
            var cq: Vec2 = q1;
            // Clip A's segment to B's span [0, length2] along unit2.
            if (fp1 < 0.0 and fq1 > 0.0) {
                cp = lerp2(p1, q1, (0.0 - fp1) / (fq1 - fp1));
            } else if (fq1 < 0.0 and fp1 > 0.0) {
                cq = lerp2(q1, p1, (0.0 - fq1) / (fp1 - fq1));
            }
            if (fp1 > length2_ and fq1 < length2_) {
                cp = lerp2(p1, q1, (fp1 - length2_) / (fp1 - fq1));
            } else if (fq1 > length2_ and fp1 < length2_) {
                cq = lerp2(q1, p1, (fq1 - length2_) / (fq1 - fp1));
            }
            const sp: f32 = dot2(cp - p2, normal_b);
            const sq: f32 = dot2(cq - p2, normal_b);
            if (sp <= dist + linear_slop or sq <= dist + linear_slop) {
                manifold.points[0] = .{
                    .point = mulAdd2(cp, 0.5 * (radius_b - radius_a - sp), normal_b),
                    .separation = sp - radius,
                    .id = makeId(0, 0),
                };
                manifold.points[1] = .{
                    .point = mulAdd2(cq, 0.5 * (radius_b - radius_a - sq), normal_b),
                    .separation = sq - radius,
                    .id = makeId(1, 0),
                };
                manifold.count = 2;
            }
        }
    }

    if (manifold.count == 0) {
        // Fall back to a single closest-point contact.
        var normal: Vec2 = closest2 - closest1;
        if (dot2(normal, normal) > eps_sq) {
            normal = normalizeOrZero2(normal);
        } else {
            normal = leftPerp2(unit1);
        }
        const c1: Vec2 = mulAdd2(closest1, radius_a, normal);
        const c2: Vec2 = mulAdd2(closest2, -radius_b, normal);
        const ia: u32 = if (f1 == 0.0) 0 else 1;
        const ib: u32 = if (f2 == 0.0) 0 else 1;
        manifold.normal = normal;
        manifold.points[0] = .{
            .point = lerp2(c1, c2, 0.5),
            .separation = dist - radius,
            .id = makeId(ia, ib),
        };
        manifold.count = 1;
    }

    // Undo the origin shift so points are in frame A.
    var i: usize = 0;
    while (i < manifold.count) : (i += 1) {
        manifold.points[i].point = manifold.points[i].point + origin;
    }
    return manifold;
}

/// Segment vs capsule (a segment is a zero-radius capsule on side A).
/// box2d: b2CollideSegmentAndCapsule  manifold.c:498
pub fn collideSegmentAndCapsule(
    segment_a: Segment,
    capsule_b: Capsule,
    xf: Transform2,
) LocalManifold {
    const capsule_a: Capsule = .{ .center1 = segment_a.point1, .center2 = segment_a.point2, .radius = 0.0 };
    return collideCapsules(capsule_a, capsule_b, xf);
}

/// Max separation of poly2 from poly1's edges, plus the owning edge of poly1 (SAT).
/// box2d: b2FindMaxSeparation  manifold.c:646
const MaxSeparation = struct { separation: f32, edge: u32 };

/// The deepest of the separating-axis tests: for each of `poly`'s edge normals, find how
/// far `other` penetrates along it (its most-negative projection), and return the edge
/// whose penetration is the *least* negative. A positive result means the polygons are
/// apart along that axis (a true separating axis); the most positive is the shallowest
/// overlap and the best reference edge. box2d: b2FindMaxSeparation  manifold.c:603
fn findMaxSeparation(poly: *const Polygon, other: *const Polygon) MaxSeparation {
    var best_index: u32 = 0;
    var max_separation: f32 = -floatMax(f32);

    var i: usize = 0;
    while (i < poly.count) : (i += 1) {
        const normal: Vec2 = poly.normals[i];
        const vertex: Vec2 = poly.vertices[i];
        // The most-negative projection of `other`'s vertices onto this edge's normal is how
        // far `other` reaches behind `poly`'s edge (its deepest point along the axis).
        var deepest: f32 = floatMax(f32);
        var j: usize = 0;
        while (j < other.count) : (j += 1) {
            const projection: f32 = dot2(normal, other.vertices[j] - vertex);
            if (projection < deepest) {
                deepest = projection;
            }
        }
        if (deepest > max_separation) {
            max_separation = deepest;
            best_index = @intCast(i);
        }
    }
    return .{ .separation = max_separation, .edge = best_index };
}

/// Clip the incident edge against the reference edge to produce up to two contact
/// points. `flip` swaps which polygon is the reference (so the caller can always
/// choose A's deepest edge as reference when separations tie toward A).
/// box2d: b2ClipPolygons  manifold.c:511
/// Clip the incident polygon's edge against the reference polygon's edge to produce up to
/// two contact points. This is the second half of SAT: the separating-axis search has
/// already chosen which edge is the reference (it owns the contact normal) and which is the
/// incident edge on the other shape. We project the incident edge onto the reference edge's
/// tangent, clip it to the reference edge's span, then measure each clipped point's
/// separation along the normal. `flip` records that the reference edge belongs to B, so the
/// emitted normal and point ids are swapped to keep the manifold A->B.
/// box2d: b2ClipPolygons  manifold.c:631
fn clipPolygons(
    poly_a: *const Polygon,
    poly_b: *const Polygon,
    edge_a: u32,
    edge_b: u32,
    flip: bool,
) LocalManifold {
    var manifold: LocalManifold = LocalManifold.empty;

    // Name the reference (owns the normal) and incident polygons and the two vertex
    // indices of each one's contact edge. The "+1 or wrap" picks the edge's far vertex.
    var reference: *const Polygon = undefined;
    var incident: *const Polygon = undefined;
    var ref_i0: usize = undefined;
    var ref_i1: usize = undefined;
    var inc_i0: usize = undefined;
    var inc_i1: usize = undefined;

    if (flip) {
        reference = poly_b;
        incident = poly_a;
        ref_i0 = edge_b;
        ref_i1 = if (edge_b + 1 < poly_b.count) edge_b + 1 else 0;
        inc_i0 = edge_a;
        inc_i1 = if (edge_a + 1 < poly_a.count) edge_a + 1 else 0;
    } else {
        reference = poly_a;
        incident = poly_b;
        ref_i0 = edge_a;
        ref_i1 = if (edge_a + 1 < poly_a.count) edge_a + 1 else 0;
        inc_i0 = edge_b;
        inc_i1 = if (edge_b + 1 < poly_b.count) edge_b + 1 else 0;
    }

    const normal: Vec2 = reference.normals[ref_i0];
    const ref_v0: Vec2 = reference.vertices[ref_i0];
    const ref_v1: Vec2 = reference.vertices[ref_i1];
    const inc_v0: Vec2 = incident.vertices[inc_i0];
    const inc_v1: Vec2 = incident.vertices[inc_i1];

    // Tangent runs along the reference edge; project everything onto it, measured from
    // ref_v0. The incident edge runs opposite the tangent because of CCW winding, so its
    // first vertex projects to the high end and its second to the low end.
    const tangent: Vec2 = crossSV2(1.0, normal);
    const ref_lo: f32 = 0.0;
    const ref_hi: f32 = dot2(ref_v1 - ref_v0, tangent);
    const inc_hi: f32 = dot2(inc_v0 - ref_v0, tangent);
    const inc_lo: f32 = dot2(inc_v1 - ref_v0, tangent);

    // No overlap of the two edges' tangential spans -> no contact.
    if (inc_hi < ref_lo or ref_hi < inc_lo) {
        return manifold;
    }

    // Clip the incident edge to the reference edge's [ref_lo, ref_hi] span. Where a clip is
    // needed, interpolate along the incident edge; otherwise keep the original endpoint.
    const eps: f32 = floatEps(f32);
    const inc_span: f32 = inc_hi - inc_lo;
    var clip_lo: Vec2 = undefined;
    if (inc_lo < ref_lo and inc_span > eps) {
        clip_lo = lerp2(inc_v1, inc_v0, (ref_lo - inc_lo) / inc_span);
    } else {
        clip_lo = inc_v1;
    }
    var clip_hi: Vec2 = undefined;
    if (inc_hi > ref_hi and inc_span > eps) {
        clip_hi = lerp2(inc_v1, inc_v0, (ref_hi - inc_lo) / inc_span);
    } else {
        clip_hi = inc_v0;
    }

    const separation_lo: f32 = dot2(clip_lo - ref_v0, normal);
    const separation_hi: f32 = dot2(clip_hi - ref_v0, normal);

    const radius_ref: f32 = reference.radius;
    const radius_inc: f32 = incident.radius;

    // Move each clipped point to the contact midline between the two (possibly rounded)
    // surfaces, then record the gap (separation minus the combined radius).
    clip_lo = mulAdd2(clip_lo, 0.5 * (radius_ref - radius_inc - separation_lo), normal);
    clip_hi = mulAdd2(clip_hi, 0.5 * (radius_ref - radius_inc - separation_hi), normal);
    const radius: f32 = radius_ref + radius_inc;

    if (flip == false) {
        manifold.normal = normal;
        manifold.points[0] = .{
            .point = clip_lo,
            .separation = separation_lo - radius,
            .id = makeId(@intCast(ref_i0), @intCast(inc_i1)),
        };
        manifold.points[1] = .{
            .point = clip_hi,
            .separation = separation_hi - radius,
            .id = makeId(@intCast(ref_i1), @intCast(inc_i0)),
        };
        manifold.count = 2;
    } else {
        manifold.normal = -normal; // normal must point A -> B
        manifold.points[0] = .{
            .point = clip_hi,
            .separation = separation_hi - radius,
            .id = makeId(@intCast(inc_i0), @intCast(ref_i1)),
        };
        manifold.points[1] = .{
            .point = clip_lo,
            .separation = separation_lo - radius,
            .id = makeId(@intCast(inc_i1), @intCast(ref_i0)),
        };
        manifold.count = 2;
    }
    return manifold;
}

/// Polygon vs polygon. SAT picks the reference edge; if the edges are disjoint the
/// closest features are found and (when it is a clean vertex-vertex case) a single
/// point is emitted, otherwise the edges are clipped to two points.
/// box2d: b2CollidePolygons  manifold.c:702
pub fn collidePolygons(
    polygon_a: Polygon,
    polygon_b: Polygon,
    xf: Transform2,
) LocalManifold {
    const origin: Vec2 = polygon_a.vertices[0];
    const xfs: Transform2 = .{ .p = xf.p - origin, .q = xf.q };

    // Localize both polygons to A's first vertex to reduce round-off.
    var local_a: Polygon = undefined;
    local_a.count = polygon_a.count;
    local_a.radius = polygon_a.radius;
    local_a.vertices[0] = .{ 0, 0 };
    local_a.normals[0] = polygon_a.normals[0];
    {
        var i: usize = 1;
        while (i < local_a.count) : (i += 1) {
            local_a.vertices[i] = polygon_a.vertices[i] - origin;
            local_a.normals[i] = polygon_a.normals[i];
        }
    }

    var local_b: Polygon = undefined;
    local_b.count = polygon_b.count;
    local_b.radius = polygon_b.radius;
    {
        var i: usize = 0;
        while (i < local_b.count) : (i += 1) {
            local_b.vertices[i] = transformPoint2(xfs, polygon_b.vertices[i]);
            local_b.normals[i] = rotateVec2(xfs.q, polygon_b.normals[i]);
        }
    }

    const sep_a: MaxSeparation = findMaxSeparation(&local_a, &local_b);
    const sep_b: MaxSeparation = findMaxSeparation(&local_b, &local_a);
    var edge_a: u32 = sep_a.edge;
    var edge_b: u32 = sep_b.edge;
    const separation_a: f32 = sep_a.separation;
    const separation_b: f32 = sep_b.separation;

    const radius: f32 = local_a.radius + local_b.radius;

    if (separation_a > speculative_distance + radius or separation_b > speculative_distance + radius) {
        return LocalManifold.empty;
    }

    // Choose the reference edge (deepest separation), then its incident edge on the
    // other polygon (the edge whose normal is most anti-parallel to the reference).
    var flip: bool = undefined;
    if (separation_a >= separation_b) {
        flip = false;
        const search_direction: Vec2 = local_a.normals[edge_a];
        var min_dot: f32 = floatMax(f32);
        edge_b = 0;
        var i: usize = 0;
        while (i < local_b.count) : (i += 1) {
            const d: f32 = dot2(search_direction, local_b.normals[i]);
            if (d < min_dot) {
                min_dot = d;
                edge_b = @intCast(i);
            }
        }
    } else {
        flip = true;
        const search_direction: Vec2 = local_b.normals[edge_b];
        var min_dot: f32 = floatMax(f32);
        edge_a = 0;
        var i: usize = 0;
        while (i < local_a.count) : (i += 1) {
            const d: f32 = dot2(search_direction, local_a.normals[i]);
            if (d < min_dot) {
                min_dot = d;
                edge_a = @intCast(i);
            }
        }
    }

    var manifold: LocalManifold = LocalManifold.empty;

    // Slop guard so vertex-vertex normals can be safely normalized.
    if (separation_a > 0.1 * linear_slop or separation_b > 0.1 * linear_slop) {
        // Edges are (nearly) disjoint: find the closest points of the two contact edges.
        const a_i0: usize = edge_a;
        const a_i1: usize = if (edge_a + 1 < local_a.count) edge_a + 1 else 0;
        const b_i0: usize = edge_b;
        const b_i1: usize = if (edge_b + 1 < local_b.count) edge_b + 1 else 0;
        const a_v0: Vec2 = local_a.vertices[a_i0];
        const a_v1: Vec2 = local_a.vertices[a_i1];
        const b_v0: Vec2 = local_b.vertices[b_i0];
        const b_v1: Vec2 = local_b.vertices[b_i1];

        const result: SegmentDistanceResult = segmentDistance(a_v0, a_v1, b_v0, b_v1);
        const dist: f32 = @sqrt(result.distance_squared);
        const separation: f32 = dist - radius;
        if (separation > speculative_distance) {
            return manifold; // vertex-vertex case can land here
        }

        manifold = clipPolygons(&local_a, &local_b, edge_a, edge_b, flip);
        var min_separation: f32 = floatMax(f32);
        {
            var i: usize = 0;
            while (i < manifold.count) : (i += 1) {
                min_separation = @min(min_separation, manifold.points[i].separation);
            }
        }

        // If the true closest-feature pair is a vertex-vertex case (both edge fractions sit
        // exactly at an endpoint) and is meaningfully shallower than the clipped result,
        // replace the manifold with that single point and a properly oriented normal.
        const a_at_endpoint: bool = result.fraction1 == 0.0 or result.fraction1 == 1.0;
        const b_at_endpoint: bool = result.fraction2 == 0.0 or result.fraction2 == 1.0;
        if (separation + 0.1 * linear_slop < min_separation and a_at_endpoint and b_at_endpoint) {
            const closest_a: Vec2 = if (result.fraction1 == 0.0) a_v0 else a_v1;
            const closest_b: Vec2 = if (result.fraction2 == 0.0) b_v0 else b_v1;
            const id_a: usize = if (result.fraction1 == 0.0) a_i0 else a_i1;
            const id_b: usize = if (result.fraction2 == 0.0) b_i0 else b_i1;

            const inv_distance: f32 = 1.0 / dist;
            const normal: Vec2 = (closest_b - closest_a) * splat2(inv_distance);
            // Pull each surface point in by its radius, then take the midpoint.
            const surface_a: Vec2 = mulAdd2(closest_a, local_a.radius, normal);
            const surface_b: Vec2 = mulAdd2(closest_b, -local_b.radius, normal);
            manifold.normal = normal;
            manifold.points[0] = .{
                .point = lerp2(surface_a, surface_b, 0.5),
                .separation = dist - radius,
                .id = makeId(@intCast(id_a), @intCast(id_b)),
            };
            manifold.count = 1;
        }
    } else {
        // Polygons overlap: clip directly.
        manifold = clipPolygons(&local_a, &local_b, edge_a, edge_b, flip);
    }

    // Undo the origin shift so points are in frame A.
    var i: usize = 0;
    while (i < manifold.count) : (i += 1) {
        manifold.points[i].point = manifold.points[i].point + origin;
    }
    return manifold;
}

/// Polygon vs capsule (treat the capsule as a 2-vertex rounded polygon).
/// box2d: b2CollidePolygonAndCapsule  manifold.c:504
pub fn collidePolygonAndCapsule(
    polygon_a: Polygon,
    capsule_b: Capsule,
    xf: Transform2,
) LocalManifold {
    const poly_b: Polygon = makeCapsulePolygon(capsule_b.center1, capsule_b.center2, capsule_b.radius);
    return collidePolygons(polygon_a, poly_b, xf);
}

/// Segment vs circle (a segment is a zero-radius capsule on side A).
/// box2d: b2CollideSegmentAndCircle  manifold.c:1030
pub fn collideSegmentAndCircle(
    segment_a: Segment,
    circle_b: Circle,
    xf: Transform2,
) LocalManifold {
    const capsule_a: Capsule = .{ .center1 = segment_a.point1, .center2 = segment_a.point2, .radius = 0.0 };
    return collideCapsuleAndCircle(capsule_a, circle_b, xf);
}

/// Segment vs polygon (treat the segment as a 2-vertex zero-radius polygon on A).
/// box2d: b2CollideSegmentAndPolygon  manifold.c:1036
pub fn collideSegmentAndPolygon(
    segment_a: Segment,
    polygon_b: Polygon,
    xf: Transform2,
) LocalManifold {
    const polygon_a: Polygon = makeCapsulePolygon(segment_a.point1, segment_a.point2, 0.0);
    return collidePolygons(polygon_a, polygon_b, xf);
}

// -- Chain-segment collisions (one-sided, with ghost-vertex smoothing) -----------
//
// A chain segment is one edge of a static collision chain. It collides on one side
// only and uses its neighbor "ghost" vertices to suppress phantom collisions at the
// internal vertices of the chain (the Gauss-map test below). See
// https://box2d.org/posts/2020/06/ghost-collisions/

/// How a candidate contact normal relates to a chain vertex's Gauss map.
const NormalType = enum {
    skip, // non-smooth direction at a convex vertex - ignore this contact
    admit, // smooth direction - use this contact
    snap, // concave region - snap to the segment's own normal
};

/// The smoothing context for one chain segment: its own edge direction and the
/// neighbor edge normals + convexity flags. box2d: b2ChainSegmentParams  manifold.c
const ChainSegmentParams = struct {
    edge1: Vec2,
    normal0: Vec2,
    normal2: Vec2,
    convex1: bool,
    convex2: bool,
};

/// Classify a contact normal against the chain vertex Gauss map.
/// box2d: b2ClassifyNormal  manifold.c:1226
fn classifyNormal(params: ChainSegmentParams, normal: Vec2) NormalType {
    const sin_tol: f32 = 0.01;
    if (dot2(normal, params.edge1) <= 0.0) {
        // Normal points toward the segment tail (the ghost1 side).
        if (params.convex1) {
            if (cross2(normal, params.normal0) > sin_tol) {
                return .skip;
            }
            return .admit;
        }
        return .snap;
    } else {
        // Normal points toward the segment head (the ghost2 side).
        if (params.convex2) {
            if (cross2(params.normal2, normal) > sin_tol) {
                return .skip;
            }
            return .admit;
        }
        return .snap;
    }
}

/// Chain segment vs circle (one-sided). box2d: b2CollideChainSegmentAndCircle  manifold.c:1042
pub fn collideChainSegmentAndCircle(
    segment_a: ChainSegment,
    circle_b: Circle,
    xf: Transform2,
) LocalManifold {
    var manifold: LocalManifold = LocalManifold.empty;

    const pb: Vec2 = transformPoint2(xf, circle_b.center);
    const p1: Vec2 = segment_a.segment.point1;
    const p2: Vec2 = segment_a.segment.point2;
    const e: Vec2 = p2 - p1;

    // The segment's collision side is to the right of its direction.
    const offset: f32 = dot2(rightPerp2(e), pb - p1);
    if (offset < 0.0) {
        return manifold; // approaching from the non-colliding side
    }

    const u: f32 = dot2(e, p2 - pb);
    const v: f32 = dot2(e, pb - p1);

    var pa: Vec2 = undefined;
    if (v <= 0.0) {
        // Before point1: only collide if outside the previous edge's Voronoi region.
        const prev_edge: Vec2 = p1 - segment_a.ghost1;
        if (dot2(prev_edge, pb - p1) <= 0.0) {
            return manifold;
        }
        pa = p1;
    } else if (u <= 0.0) {
        // Past point2: only collide if outside the next edge's Voronoi region.
        const next_edge: Vec2 = segment_a.ghost2 - p2;
        if (dot2(next_edge, pb - p2) > 0.0) {
            return manifold;
        }
        pa = p2;
    } else {
        const ee: f32 = dot2(e, e);
        pa = p1 * splat2(u) + p2 * splat2(v);
        pa = if (ee > 0.0) pa * splat2(1.0 / ee) else p1;
    }

    var dist: f32 = undefined;
    const normal: Vec2 = getLengthAndNormalize2(&dist, pb - pa);

    const radius: f32 = circle_b.radius;
    const separation: f32 = dist - radius;
    if (separation > speculative_distance) {
        return manifold;
    }

    const ca: Vec2 = pa;
    const cb: Vec2 = mulAdd2(pb, -radius, normal);

    manifold.normal = normal;
    manifold.points[0] = .{ .point = lerp2(ca, cb, 0.5), .separation = separation, .id = 0 };
    manifold.count = 1;
    return manifold;
}

/// Clip segment [b1,b2] against the reference segment [a1,a2] along the reference
/// `normal`, producing exactly two contact points (or none if disjoint). Used by the
/// chain-segment-vs-polygon path. box2d: b2ClipSegments  manifold.c:1131
fn clipSegments(
    a1: Vec2,
    a2: Vec2,
    b1: Vec2,
    b2: Vec2,
    normal: Vec2,
    ra: f32,
    rb: f32,
    id1: u16,
    id2: u16,
) LocalManifold {
    var manifold: LocalManifold = LocalManifold.empty;

    const tangent: Vec2 = leftPerp2(normal);

    const lower1: f32 = 0.0;
    const upper1: f32 = dot2(a2 - a1, tangent);
    // Incident edge runs opposite the tangent due to CCW winding.
    const upper2: f32 = dot2(b1 - a1, tangent);
    const lower2: f32 = dot2(b2 - a1, tangent);

    if (upper2 < lower1 or upper1 < lower2) {
        return manifold; // no overlap
    }

    const eps: f32 = floatEps(f32);
    var v_lower: Vec2 = undefined;
    if (lower2 < lower1 and upper2 - lower2 > eps) {
        v_lower = lerp2(b2, b1, (lower1 - lower2) / (upper2 - lower2));
    } else {
        v_lower = b2;
    }
    var v_upper: Vec2 = undefined;
    if (upper2 > upper1 and upper2 - lower2 > eps) {
        v_upper = lerp2(b2, b1, (upper1 - lower2) / (upper2 - lower2));
    } else {
        v_upper = b1;
    }

    const separation_lower: f32 = dot2(v_lower - a1, normal);
    const separation_upper: f32 = dot2(v_upper - a1, normal);

    v_lower = mulAdd2(v_lower, 0.5 * (ra - rb - separation_lower), normal);
    v_upper = mulAdd2(v_upper, 0.5 * (ra - rb - separation_upper), normal);

    const radius: f32 = ra + rb;
    manifold.normal = normal;
    manifold.points[0] = .{ .point = v_lower, .separation = separation_lower - radius, .id = id1 };
    manifold.points[1] = .{ .point = v_upper, .separation = separation_upper - radius, .id = id2 };
    manifold.count = 2;
    return manifold;
}

/// Chain segment vs polygon (one-sided, with ghost smoothing). The most intricate
/// collide: it runs GJK to find the closest features, classifies the resulting normal
/// against the chain Gauss map to reject phantom internal-vertex contacts, and finally
/// clips to a face manifold. box2d: b2CollideChainSegmentAndPolygon  manifold.c:1266
pub fn collideChainSegmentAndPolygon(
    segment_a: ChainSegment,
    polygon_b: Polygon,
    xf: Transform2,
    cache: *SimplexCache,
) LocalManifold {
    var manifold: LocalManifold = LocalManifold.empty;

    const centroid_b: Vec2 = transformPoint2(xf, polygon_b.centroid);
    const radius_b: f32 = polygon_b.radius;

    const p1: Vec2 = segment_a.segment.point1;
    const p2: Vec2 = segment_a.segment.point2;
    const edge1: Vec2 = normalizeOrZero2(p2 - p1);

    const convex_tol: f32 = 0.01;
    const edge0: Vec2 = normalizeOrZero2(p1 - segment_a.ghost1);
    const edge2: Vec2 = normalizeOrZero2(segment_a.ghost2 - p2);
    const params: ChainSegmentParams = .{
        .edge1 = edge1,
        .normal0 = rightPerp2(edge0),
        .normal2 = rightPerp2(edge2),
        .convex1 = cross2(edge0, edge1) >= convex_tol,
        .convex2 = cross2(edge1, edge2) >= convex_tol,
    };

    // The segment's collision normal points to the right of its direction.
    const normal1: Vec2 = rightPerp2(edge1);
    const behind1: bool = dot2(normal1, centroid_b - p1) < 0.0;
    var behind0: bool = true;
    var behind2: bool = true;
    if (params.convex1) {
        behind0 = dot2(params.normal0, centroid_b - p1) < 0.0;
    }
    if (params.convex2) {
        behind2 = dot2(params.normal2, centroid_b - p2) < 0.0;
    }

    if (behind1 and behind0 and behind2) {
        return manifold; // polygon is entirely on the non-colliding side
    }

    // Bring polygon B into the segment's (frame A) coordinates.
    const count: usize = polygon_b.count;
    var vertices: [max_polygon_vertices]Vec2 = undefined;
    var normals: [max_polygon_vertices]Vec2 = undefined;
    {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            vertices[i] = transformPoint2(xf, polygon_b.vertices[i]);
            normals[i] = rotateVec2(xf.q, polygon_b.normals[i]);
        }
    }

    // GJK between the segment and the (full) polygon to find the closest features.
    const seg_points: [2]Vec2 = .{ p1, p2 };
    var input: DistanceInput = .{
        .proxy_a = makeProxy(seg_points[0..2], 0.0),
        .proxy_b = makeProxy(vertices[0..count], 0.0),
        .transform = Transform2.identity,
        .use_radii = false,
    };
    const output: DistanceOutput = shapeDistance(&input, cache);
    if (output.distance > radius_b + speculative_distance) {
        return manifold;
    }

    // Snap concave neighbor normals to the segment normal.
    const n0: Vec2 = if (params.convex1) params.normal0 else normal1;
    const n2: Vec2 = if (params.convex2) params.normal2 else normal1;

    var incident_index: i32 = -1; // polygon vertex index, or -1
    var incident_normal: i32 = -1; // polygon normal index, or -1

    if (behind1 == false and output.distance > 0.1 * linear_slop) {
        // The closest features may be vertex-vertex or vertex-edge even where there
        // should be face contact, so classify carefully.
        if (cache.count == 1) {
            // vertex-vertex
            const pa: Vec2 = output.point_a;
            const pb: Vec2 = output.point_b;
            const normal: Vec2 = normalizeOrZero2(pb - pa);
            const kind: NormalType = classifyNormal(params, normal);
            if (kind == .skip) {
                return manifold;
            }
            if (kind == .admit) {
                manifold.normal = normal;
                manifold.points[0] = .{
                    .point = pa,
                    .separation = output.distance - radius_b,
                    .id = makeId(cache.index_a[0], cache.index_b[0]),
                };
                manifold.count = 1;
                return manifold;
            }
            // .snap: fall through using this polygon vertex as the incident one.
            incident_index = @intCast(cache.index_b[0]);
        } else {
            // vertex-edge
            assert(cache.count == 2, @src());
            const ia1: u32 = cache.index_a[0];
            const ia2: u32 = cache.index_a[1];
            var ib1: usize = cache.index_b[0];
            var ib2: usize = cache.index_b[1];

            if (ia1 == ia2) {
                // One point on the segment, two on the polygon: pick the polygon
                // normal most aligned with the closest-point direction.
                assert(ib1 != ib2, @src());
                var normal_b: Vec2 = output.point_a - output.point_b;
                const dot_1: f32 = dot2(normal_b, normals[ib1]);
                const dot_2: f32 = dot2(normal_b, normals[ib2]);
                const ib: usize = if (dot_1 > dot_2) ib1 else ib2;
                normal_b = normals[ib];

                const kind: NormalType = classifyNormal(params, -normal_b);
                if (kind == .skip) {
                    return manifold;
                }
                if (kind == .admit) {
                    // Clip the polygon edge owning this normal against the segment.
                    ib1 = ib;
                    ib2 = if (ib < count - 1) ib + 1 else 0;
                    const bv1: Vec2 = vertices[ib1];
                    const bv2: Vec2 = vertices[ib2];
                    const d1: f32 = dot2(normal_b, p1 - bv1);
                    const d2: f32 = dot2(normal_b, p2 - bv1);
                    if (d1 < d2) {
                        if (dot2(n0, normal_b) < dot2(normal1, normal_b)) {
                            return manifold;
                        }
                    } else {
                        if (dot2(n2, normal_b) < dot2(normal1, normal_b)) {
                            return manifold;
                        }
                    }
                    manifold = clipSegments(
                        bv1,
                        bv2,
                        p1,
                        p2,
                        normal_b,
                        radius_b,
                        0.0,
                        makeId(@intCast(ib1), 1),
                        makeId(@intCast(ib2), 0),
                    );
                    if (manifold.count == 2) {
                        manifold.normal = -normal_b;
                    }
                    return manifold;
                }
                // .snap
                incident_normal = @intCast(ib);
            } else {
                // Two points on the segment, one on the polygon: pick the deeper one.
                const d1: f32 = dot2(normal1, vertices[ib1] - p1);
                const d2: f32 = dot2(normal1, vertices[ib2] - p2);
                incident_index = if (d1 < d2) @intCast(ib1) else @intCast(ib2);
            }
        }
    } else {
        // SAT path. First, the segment's own edge normal separation.
        var edge_separation: f32 = floatMax(f32);
        {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const s: f32 = dot2(normal1, vertices[i] - p1);
                if (s < edge_separation) {
                    edge_separation = s;
                    incident_index = @intCast(i);
                }
            }
        }
        // Convex neighbors may own a larger edge separation (then no segment-face).
        if (params.convex1) {
            var s0: f32 = floatMax(f32);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const s: f32 = dot2(params.normal0, vertices[i] - p1);
                if (s < s0) {
                    s0 = s;
                }
            }
            if (s0 > edge_separation) {
                edge_separation = s0;
                incident_index = -1;
            }
        }
        if (params.convex2) {
            var s2: f32 = floatMax(f32);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const s: f32 = dot2(params.normal2, vertices[i] - p2);
                if (s < s2) {
                    s2 = s;
                }
            }
            if (s2 > edge_separation) {
                edge_separation = s2;
                incident_index = -1;
            }
        }

        // Then the polygon's admissible face normals.
        var polygon_separation: f32 = -floatMax(f32);
        var reference_index: i32 = -1;
        {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const n: Vec2 = normals[i];
                if (classifyNormal(params, -n) != .admit) {
                    continue;
                }
                const p: Vec2 = vertices[i];
                const s: f32 = @min(dot2(n, p2 - p), dot2(n, p1 - p));
                if (s > polygon_separation) {
                    polygon_separation = s;
                    reference_index = @intCast(i);
                }
            }
        }

        if (polygon_separation > edge_separation) {
            // Polygon face is the reference: clip the segment against it.
            const ia1: usize = @intCast(reference_index);
            const ia2: usize = if (ia1 < count - 1) ia1 + 1 else 0;
            const a1: Vec2 = vertices[ia1];
            const a2: Vec2 = vertices[ia2];
            const n: Vec2 = normals[ia1];
            const d1: f32 = dot2(n, p1 - a1);
            const d2: f32 = dot2(n, p2 - a1);
            if (d1 < d2) {
                if (dot2(n0, n) < dot2(normal1, n)) {
                    return manifold;
                }
            } else {
                if (dot2(n2, n) < dot2(normal1, n)) {
                    return manifold;
                }
            }
            manifold = clipSegments(
                a1,
                a2,
                p1,
                p2,
                normals[ia1],
                radius_b,
                0.0,
                makeId(@intCast(ia1), 1),
                makeId(@intCast(ia2), 0),
            );
            if (manifold.count == 2) {
                manifold.normal = -normals[ia1];
            }
            return manifold;
        }

        if (incident_index == -1) {
            return manifold; // a neighboring segment owns the separating axis
        }
        // else fall through to the segment-normal face below
    }

    assert(incident_normal != -1 or incident_index != -1, @src());

    // Segment normal is the reference: find the incident polygon edge and clip.
    var ib1: usize = undefined;
    var ib2: usize = undefined;
    var bv1: Vec2 = undefined;
    var bv2: Vec2 = undefined;

    if (incident_normal != -1) {
        ib1 = @intCast(incident_normal);
        ib2 = if (ib1 < count - 1) ib1 + 1 else 0;
        bv1 = vertices[ib1];
        bv2 = vertices[ib2];
    } else {
        const cur_n: usize = @intCast(incident_index);
        const prev_n: usize = if (cur_n > 0) cur_n - 1 else count - 1;
        const d1: f32 = dot2(normal1, normals[prev_n]);
        const d2: f32 = dot2(normal1, normals[cur_n]);
        if (d1 < d2) {
            ib1 = prev_n;
            ib2 = cur_n;
        } else {
            ib1 = cur_n;
            ib2 = if (cur_n < count - 1) cur_n + 1 else 0;
        }
        bv1 = vertices[ib1];
        bv2 = vertices[ib2];
    }

    manifold = clipSegments(
        p1,
        p2,
        bv1,
        bv2,
        normal1,
        0.0,
        radius_b,
        makeId(0, @intCast(ib2)),
        makeId(1, @intCast(ib1)),
    );
    return manifold;
}

/// Chain segment vs capsule (treat the capsule as a 2-vertex rounded polygon).
/// box2d: b2CollideChainSegmentAndCapsule  manifold.c:1124
pub fn collideChainSegmentAndCapsule(
    segment_a: ChainSegment,
    capsule_b: Capsule,
    xf: Transform2,
    cache: *SimplexCache,
) LocalManifold {
    const poly_b: Polygon = makeCapsulePolygon(capsule_b.center1, capsule_b.center2, capsule_b.radius);
    return collideChainSegmentAndPolygon(segment_a, poly_b, xf, cache);
}

// -- Collide dispatch ------------------------------------------------------------
//
// Box2D registers each collide function for an ordered shape-type pair (the more
// complex shape first), with a "primary"/flip bit. Contact creation (section 14) swaps the
// two shapes so the stored pair always matches a primary registration; therefore this
// dispatch only ever sees the 12 registered orderings, and all other combinations are
// unreachable. box2d: s_registers + b2GetManifoldFcn  contact.c:173-203

/// Generate the local manifold for an already-correctly-ordered pair of shapes. `xf`
/// is the pose of B in A's frame; `cache` persists the GJK simplex (only the
/// chain-segment paths use it). box2d: the s_registers dispatch in b2UpdateContact
pub fn collideShapes(
    geom_a: *const Geometry,
    geom_b: *const Geometry,
    xf: Transform2,
    cache: *SimplexCache,
) LocalManifold {
    return switch (geom_a.*) {
        .circle => |ca| switch (geom_b.*) {
            .circle => |cb| collideCircles(ca, cb, xf),
            else => unreachable,
        },
        .capsule => |cap_a| switch (geom_b.*) {
            .circle => |cb| collideCapsuleAndCircle(cap_a, cb, xf),
            .capsule => |cap_b| collideCapsules(cap_a, cap_b, xf),
            else => unreachable,
        },
        .segment => |sa| switch (geom_b.*) {
            .circle => |cb| collideSegmentAndCircle(sa, cb, xf),
            .capsule => |cap_b| collideSegmentAndCapsule(sa, cap_b, xf),
            .polygon => |pb| collideSegmentAndPolygon(sa, pb, xf),
            else => unreachable,
        },
        .polygon => |pa| switch (geom_b.*) {
            .circle => |cb| collidePolygonAndCircle(pa, cb, xf),
            .capsule => |cap_b| collidePolygonAndCapsule(pa, cap_b, xf),
            .polygon => |pb| collidePolygons(pa, pb, xf),
            else => unreachable,
        },
        .chain_segment => |cs| switch (geom_b.*) {
            .circle => |cb| collideChainSegmentAndCircle(cs, cb, xf),
            .capsule => |cap_b| collideChainSegmentAndCapsule(cs, cap_b, xf, cache),
            .polygon => |pb| collideChainSegmentAndPolygon(cs, pb, xf, cache),
            else => unreachable,
        },
    };
}

// ================================================================================
// Bodies - the ECS primary component plus indexed side-tables
//
// Box2D splits a body across three cache-tiered structs (b2Body / b2BodySim /
// b2BodyState). We collapse those into the zimr shape: `Body` is the authoritative
// resting state stored in `Entities(Body)`; `Motion` is a side-table (velocity +
// solver mass + applied force) indexed by the stable BodyIndex; `BodyState` is the
// per-step solver scratch (TGS position deltas). Static bodies are recognized by
// `type == .static` and read an identity state with zero inverse mass.
// box2d: body.h (b2Body:67, b2BodyState:147, b2BodySim:168)
// ================================================================================

/// Sentinel for "no index" in the u32 intrusive lists (shape/contact/joint chains).
pub const null_index: u32 = 0xFFFF_FFFF;

/// A stable index into the parallel body arrays (`bodies`/`motion`/`state`). Index 0 is
/// the null/static sentinel, so constraints can reference "no body" or a static anchor
/// without a branch. Box2D uses bare ints; naming the type documents intent at use-sites.
pub const BodyIndex = u32;

/// A stable index into the world's shape storage. box2d: shape ids are bare ints too.
pub const ShapeIndex = u32;

/// A body's dynamics class. box2d: b2BodyType  types.h
pub const MotionType = physics_common.MotionType;

/// How carefully a body's motion is integrated against tunnelling. `discrete` does a single
/// integration per step (cheap, the default); `linear_cast` adds sub-step continuous
/// collision so a fast body can't pass through thin geometry (Box2D's "bullet"). Named to
/// match the 3D engine's MotionQuality. box2d: the per-body isBullet flag.
pub const MotionQuality = physics_common.MotionQuality;

/// Which degrees of freedom a body may move in. Default is all three free; the locks are
/// expressed positively (a `false` field freezes that axis) and grouped into one value with
/// named presets, mirroring the 3D engine's `AllowedDofs`. The solver enforces a frozen axis
/// as a hard constraint during position integration.
pub const AllowedDofs = packed struct {
    translation_x: bool = true,
    translation_y: bool = true,
    rotation_z: bool = true,

    /// All three free (the default).
    pub const all: AllowedDofs = .{};
    /// Translate freely but never rotate (e.g. an upright character).
    pub const no_rotation: AllowedDofs = .{ .rotation_z = false };
};

/// Persistent per-body flags (locks, behavior toggles, transient solver markers).
/// box2d: the b2Body / b2BodySim flag bits  body.h:17-55
pub const BodyFlags = packed struct(u32) {
    lock_linear_x: bool = false, // freeze world-x translation
    lock_linear_y: bool = false, // freeze world-y translation
    lock_angular_z: bool = false, // freeze rotation
    is_bullet: bool = false, // use sub-step CCD against all bodies
    allow_fast_rotation: bool = false, // skip the angular-speed clamp
    enable_sleep: bool = true, // may this body ever sleep?
    // Transient, set during the step and read in finalize:
    is_fast: bool = false, // moved far enough this step to need CCD
    is_speed_capped: bool = false, // velocity was clamped during integration
    had_time_of_impact: bool = false, // CCD advanced this body this step
    is_disabled: bool = false, // removed from simulation (no proxies, contacts, or solve)
    _pad: u22 = 0,
};

/// Solver-scratch flags carried on `BodyState`, gating velocity write-back and the
/// per-axis motion locks during integration. box2d: b2BodyState flags  body.h
pub const StateFlags = packed struct(u32) {
    dynamic: bool = false, // only dynamic bodies receive constraint impulses
    lock_x: bool = false,
    lock_y: bool = false,
    lock_w: bool = false,
    allow_fast_rotation: bool = false,
    is_speed_capped: bool = false, // velocity hit the per-step clamp
    _pad: u26 = 0,
};

/// The ECS primary component: a body's authoritative resting state (pose, mass,
/// extents, sleep accounting, and the heads of its intrusive shape/contact/joint
/// lists). Merges b2Body's metadata with b2BodySim's pose/extent fields.
pub const Body = struct {
    transform: Transform2, // body-origin pose in world; b2BodySim.transform
    center: Vec2, // world center of mass; b2BodySim.center
    center0: Vec2, // COM at step start, for CCD; b2BodySim.center0
    rot0: Rot2, // rotation at step start, for CCD; b2BodySim.rotation0
    local_center: Vec2, // COM in the body-origin frame; b2BodySim.localCenter
    min_extent: f32, // smallest support-plane distance to COM (CCD gate)
    max_extent: f32, // farthest reach from COM (sleep + CCD scaling)
    mass: f32, // total mass; b2Body.mass
    inertia: f32, // rotational inertia about the COM; b2Body.inertia
    sleep_threshold: f32, // slow-speed cutoff for sleep timing; b2Body.sleepThreshold
    sleep_time: f32, // time spent slow so far; b2Body.sleepTime
    motion_type: MotionType,
    flags: BodyFlags,
    asleep: bool, // not currently in the active list
    head_shape: u32, // first shape in this body's list (null_index = none)
    shape_count: u16,
    head_contact: u32, // first contact edge key (contactId<<1 | edge), null_index = none
    contact_count: u16,
    head_joint: u32, // first joint edge key, null_index = none
    joint_count: u16,
    user_data: u64,
};

/// Side-table indexed by BodyIndex: velocity, solver-inverse mass, damping, and the
/// per-step accumulated force/torque. Zeroed for static bodies.
pub const Motion = struct {
    linear_velocity: Vec2, // b2BodyState.linearVelocity
    angular_velocity: f32, // b2BodyState.angularVelocity
    inverse_mass: f32, // 0 for static/kinematic; b2BodySim.invMass
    inverse_inertia: f32, // 0 for static/kinematic/fixed-rotation; b2BodySim.invInertia
    linear_damping: f32, // b2BodySim.linearDamping
    angular_damping: f32, // b2BodySim.angularDamping
    gravity_scale: f32, // per-body gravity multiplier; b2BodySim.gravityScale
    force: Vec2, // accumulated applied force; reset each step
    torque: f32, // accumulated applied torque; reset each step

    pub const zero: Motion = .{
        .linear_velocity = .{ 0, 0 },
        .angular_velocity = 0,
        .inverse_mass = 0,
        .inverse_inertia = 0,
        .linear_damping = 0,
        .angular_damping = 0,
        .gravity_scale = 1,
        .force = .{ 0, 0 },
        .torque = 0,
    };
};

/// Per-step solver scratch indexed by BodyIndex: the TGS position deltas accumulated
/// over the sub-steps, plus the write-back gating flags. Reset in finalize.
/// box2d: b2BodyState.deltaPosition / deltaRotation / flags
pub const BodyState = struct {
    delta_position: Vec2, // COM translation accumulated this step
    delta_rotation: Rot2, // rotation accumulated this step
    flags: StateFlags,

    /// The state a static (or absent) body presents to the solver: no motion, no
    /// constraint response.
    pub const identity: BodyState = .{
        .delta_position = .{ 0, 0 },
        .delta_rotation = Rot2.identity,
        .flags = .{},
    };
};

// ================================================================================
// Dynamic AABB tree (the broad-phase spatial index)
//
// A self-balancing tree of fattened AABBs. Leaves hold shape proxies; internal nodes
// hold the union of their children. Insertion picks a sibling by the surface-area
// heuristic (in 2D the cost metric is PERIMETER) and rebalances with tree rotations.
// box2d: dynamic_tree.c
//
// A periodic full rebuild (`rebuild`/`buildTree`/`partitionMid`, Box2D's default
// median-split heuristic) restores tree quality when incremental insertion degrades it.
// It is driven by `World.tree_rebuild_interval` and provably leaves queries unchanged.
// ================================================================================

/// Sentinel for "no node" inside the tree (Box2D uses -1 here).
const node_null: i32 = -1;

/// Tree node state bits. box2d: b2TreeNodeFlags  collision.h:674
const NodeFlags = packed struct(u16) {
    allocated: bool = false,
    enlarged: bool = false, // AABB grew this step; broad phase must re-test it
    leaf: bool = false,
    _pad: u13 = 0,
};

/// One node of the dynamic tree. Children/user-data and parent/free-next are stored
/// as plain separate fields (Box2D unions them to save 16 bytes; we keep them
/// explicit for clarity). For a leaf, `child1`/`child2` are `node_null` and
/// `user_data` holds the proxy payload (the broad-phase key). For a free node,
/// `parent` holds the next free index.
/// One node of the broad-phase dynamic tree. Public so tools/visualizers can walk the tree.
pub const TreeNode = struct {
    aabb: Aabb2,
    category_bits: u64,
    child1: i32,
    child2: i32,
    user_data: u64,
    parent: i32, // parent, or next-free-index when on the free list
    height: u16,
    flags: NodeFlags,
};

/// A leaf-visit callback for tree queries: return false to stop the query early.
/// box2d: b2TreeQueryCallbackFcn
pub const TreeQueryCallback = *const fn (proxy_id: i32, user_data: u64, ctx: *anyopaque) bool;

/// Grow `a` to contain `b`, reporting whether it changed. box2d: b2EnlargeAABB  aabb.h:21
fn enlargeAabb(a: *Aabb2, b: Aabb2) bool {
    var changed: bool = false;
    if (b.lower[0] < a.lower[0]) {
        a.lower[0] = b.lower[0];
        changed = true;
    }
    if (b.lower[1] < a.lower[1]) {
        a.lower[1] = b.lower[1];
        changed = true;
    }
    if (a.upper[0] < b.upper[0]) {
        a.upper[0] = b.upper[0];
        changed = true;
    }
    if (a.upper[1] < b.upper[1]) {
        a.upper[1] = b.upper[1];
        changed = true;
    }
    return changed;
}

/// Quality metrics for the dynamic tree, for diagnostics. `area_ratio` is the sum of internal-node
/// perimeters over the root perimeter (box2d's b2DynamicTree_GetAreaRatio): at a fixed leaf count it
/// climbing means the hierarchy is bloating - internal AABBs overlap more, so queries visit far more
/// nodes and the broad phase slows even though nothing is allocated. `height` is the root depth.
pub const TreeStats = struct {
    height: u16,
    leaves: i32,
    nodes: i32,
    area_ratio: f32,
};

pub const DynamicTree = struct {
    nodes: std.ArrayListUnmanaged(TreeNode) = .empty,
    root: i32 = node_null,
    free_list: i32 = node_null, // head of the free-node singly-linked list
    proxy_count: i32 = 0, // number of leaves
    refit_order: std.ArrayListUnmanaged(i32) = .empty, // reused pre-order internal-node list for refitTight

    pub fn deinit(self: *DynamicTree, gpa: Allocator) void {
        self.nodes.deinit(gpa);
        self.refit_order.deinit(gpa);
        self.* = .{};
    }

    inline fn at(self: *DynamicTree, i: i32) *TreeNode {
        return &self.nodes.items[@intCast(i)];
    }
    inline fn isLeaf(node: *const TreeNode) bool {
        return node.flags.leaf;
    }

    /// Tree quality metrics (height, leaf/node counts, area ratio). O(node count); call only for
    /// diagnostics, not in the hot path. box2d: b2DynamicTree_GetHeight / GetAreaRatio.
    pub fn stats(self: *const DynamicTree) TreeStats {
        if (self.root == node_null) {
            return .{ .height = 0, .leaves = 0, .nodes = 0, .area_ratio = 0 };
        }
        const root_node: TreeNode = self.nodes.items[@intCast(self.root)];
        const root_perim: f32 = root_node.aabb.perimeter();
        var total: f32 = 0;
        var live: i32 = 0;
        for (self.nodes.items, 0..) |node, i| {
            if (node.flags.allocated == false) {
                continue;
            }
            live += 1;
            if (node.flags.leaf or @as(i32, @intCast(i)) == self.root) {
                continue;
            }
            total += node.aabb.perimeter();
        }
        return .{
            .height = root_node.height,
            .leaves = self.proxy_count,
            .nodes = live,
            .area_ratio = if (root_perim > 0) total / root_perim else 0,
        };
    }

    /// Pop a node off the free list, or append a fresh one. Returns its index. The
    /// returned node's fields are reset to a clean allocated state.
    fn allocateNode(self: *DynamicTree, gpa: Allocator) !i32 {
        var index: i32 = undefined;
        if (self.free_list != node_null) {
            index = self.free_list;
            self.free_list = self.nodes.items[@intCast(index)].parent;
        } else {
            index = @intCast(self.nodes.items.len);
            try self.nodes.append(gpa, undefined);
        }
        const node: *TreeNode = self.at(index);
        node.* = .{
            .aabb = .{ .lower = .{ 0, 0 }, .upper = .{ 0, 0 } },
            .category_bits = 1,
            .child1 = node_null,
            .child2 = node_null,
            .user_data = 0,
            .parent = node_null,
            .height = 0,
            .flags = .{ .allocated = true },
        };
        return index;
    }

    /// Return a node to the free list.
    fn freeNode(self: *DynamicTree, index: i32) void {
        const node: *TreeNode = self.at(index);
        node.parent = self.free_list; // reuse parent as the free-list link
        node.flags = .{}; // clear allocated/leaf/enlarged
        self.free_list = index;
    }

    /// Greedy surface-area-heuristic sibling search for inserting `box_d`. Descends a
    /// single best-cost path from the root. box2d: b2FindBestSibling  dynamic_tree.c:164
    fn findBestSibling(self: *DynamicTree, box_d: Aabb2) i32 {
        const nodes: []TreeNode = self.nodes.items;
        const center_d: Vec2 = box_d.center();
        const area_d: f32 = box_d.perimeter();

        const root_index: i32 = self.root;
        const root_box: Aabb2 = nodes[@intCast(root_index)].aabb;

        var area_base: f32 = root_box.perimeter();
        var direct_cost: f32 = Aabb2.combine(root_box, box_d).perimeter();
        var inherited_cost: f32 = 0.0;

        var best_sibling: i32 = root_index;
        var best_cost: f32 = direct_cost;

        var index: i32 = root_index;
        while (nodes[@intCast(index)].height > 0) {
            const child1: i32 = nodes[@intCast(index)].child1;
            const child2: i32 = nodes[@intCast(index)].child2;

            // Cost of making a new parent for this node and the leaf.
            const cost: f32 = direct_cost + inherited_cost;
            if (cost < best_cost) {
                best_sibling = index;
                best_cost = cost;
            }

            inherited_cost += direct_cost - area_base;

            const leaf1: bool = nodes[@intCast(child1)].height == 0;
            const leaf2: bool = nodes[@intCast(child2)].height == 0;

            var lower_cost1: f32 = floatMax(f32);
            const box1: Aabb2 = nodes[@intCast(child1)].aabb;
            const direct_cost1: f32 = Aabb2.combine(box1, box_d).perimeter();
            var area1: f32 = 0.0;
            if (leaf1) {
                const cost1: f32 = direct_cost1 + inherited_cost;
                if (cost1 < best_cost) {
                    best_sibling = child1;
                    best_cost = cost1;
                }
            } else {
                area1 = box1.perimeter();
                lower_cost1 = inherited_cost + direct_cost1 + @min(area_d - area1, 0.0);
            }

            var lower_cost2: f32 = floatMax(f32);
            const box2: Aabb2 = nodes[@intCast(child2)].aabb;
            const direct_cost2: f32 = Aabb2.combine(box2, box_d).perimeter();
            var area2: f32 = 0.0;
            if (leaf2) {
                const cost2: f32 = direct_cost2 + inherited_cost;
                if (cost2 < best_cost) {
                    best_sibling = child2;
                    best_cost = cost2;
                }
            } else {
                area2 = box2.perimeter();
                lower_cost2 = inherited_cost + direct_cost2 + @min(area_d - area2, 0.0);
            }

            if (leaf1 and leaf2) {
                break;
            }

            // Can either descent still beat the best cost found so far?
            if (best_cost <= lower_cost1 and best_cost <= lower_cost2) {
                break;
            }

            if (lower_cost1 == lower_cost2 and leaf1 == false) {
                // Tie between two internal children that both contain D: break it by
                // center distance.
                const d1: Vec2 = box1.center() - center_d;
                const d2: Vec2 = box2.center() - center_d;
                lower_cost1 = lengthSq2(d1);
                lower_cost2 = lengthSq2(d2);
            }

            if (lower_cost1 < lower_cost2 and leaf1 == false) {
                index = child1;
                area_base = area1;
                direct_cost = direct_cost1;
            } else {
                index = child2;
                area_base = area2;
                direct_cost = direct_cost2;
            }
        }
        return best_sibling;
    }

    /// Rebalance the subtree rooted at `ia` with a single rotation if it lowers the
    /// surface-area cost. box2d: b2RotateNodes  dynamic_tree.c:315
    fn rotateNodes(self: *DynamicTree, ia: i32) void {
        const nodes: []TreeNode = self.nodes.items;
        const a: *TreeNode = &nodes[@intCast(ia)];
        if (a.height < 2) {
            return;
        }

        const ib: i32 = a.child1;
        const ic: i32 = a.child2;
        const b: *TreeNode = &nodes[@intCast(ib)];
        const c: *TreeNode = &nodes[@intCast(ic)];

        if (b.height == 0) {
            // B is a leaf, C is internal: consider swapping B with one of C's children.
            const if_: i32 = c.child1;
            const ig: i32 = c.child2;
            const f: *TreeNode = &nodes[@intCast(if_)];
            const g: *TreeNode = &nodes[@intCast(ig)];

            const cost_base: f32 = c.aabb.perimeter();
            const aabb_bg: Aabb2 = Aabb2.combine(b.aabb, g.aabb);
            const cost_bf: f32 = aabb_bg.perimeter();
            const aabb_bf: Aabb2 = Aabb2.combine(b.aabb, f.aabb);
            const cost_bg: f32 = aabb_bf.perimeter();

            if (cost_base < cost_bf and cost_base < cost_bg) {
                return;
            }

            if (cost_bf < cost_bg) {
                // Swap B and F.
                a.child1 = if_;
                c.child1 = ib;
                b.parent = ic;
                f.parent = ia;
                c.aabb = aabb_bg;
                c.height = 1 + @max(b.height, g.height);
                a.height = 1 + @max(c.height, f.height);
                c.category_bits = b.category_bits | g.category_bits;
                a.category_bits = c.category_bits | f.category_bits;
                c.flags.enlarged = c.flags.enlarged or b.flags.enlarged or g.flags.enlarged;
                a.flags.enlarged = a.flags.enlarged or c.flags.enlarged or f.flags.enlarged;
            } else {
                // Swap B and G.
                a.child1 = ig;
                c.child2 = ib;
                b.parent = ic;
                g.parent = ia;
                c.aabb = aabb_bf;
                c.height = 1 + @max(b.height, f.height);
                a.height = 1 + @max(c.height, g.height);
                c.category_bits = b.category_bits | f.category_bits;
                a.category_bits = c.category_bits | g.category_bits;
                c.flags.enlarged = c.flags.enlarged or b.flags.enlarged or f.flags.enlarged;
                a.flags.enlarged = a.flags.enlarged or c.flags.enlarged or g.flags.enlarged;
            }
        } else if (c.height == 0) {
            // C is a leaf, B is internal.
            const id: i32 = b.child1;
            const ie: i32 = b.child2;
            const d: *TreeNode = &nodes[@intCast(id)];
            const e: *TreeNode = &nodes[@intCast(ie)];

            const cost_base: f32 = b.aabb.perimeter();
            const aabb_ce: Aabb2 = Aabb2.combine(c.aabb, e.aabb);
            const cost_cd: f32 = aabb_ce.perimeter();
            const aabb_cd: Aabb2 = Aabb2.combine(c.aabb, d.aabb);
            const cost_ce: f32 = aabb_cd.perimeter();

            if (cost_base < cost_cd and cost_base < cost_ce) {
                return;
            }

            if (cost_cd < cost_ce) {
                // Swap C and D.
                a.child2 = id;
                b.child1 = ic;
                c.parent = ib;
                d.parent = ia;
                b.aabb = aabb_ce;
                b.height = 1 + @max(c.height, e.height);
                a.height = 1 + @max(b.height, d.height);
                b.category_bits = c.category_bits | e.category_bits;
                a.category_bits = b.category_bits | d.category_bits;
                b.flags.enlarged = b.flags.enlarged or c.flags.enlarged or e.flags.enlarged;
                a.flags.enlarged = a.flags.enlarged or b.flags.enlarged or d.flags.enlarged;
            } else {
                // Swap C and E.
                a.child2 = ie;
                b.child2 = ic;
                c.parent = ib;
                e.parent = ia;
                b.aabb = aabb_cd;
                b.height = 1 + @max(c.height, d.height);
                a.height = 1 + @max(b.height, e.height);
                b.category_bits = c.category_bits | d.category_bits;
                a.category_bits = b.category_bits | e.category_bits;
                b.flags.enlarged = b.flags.enlarged or c.flags.enlarged or d.flags.enlarged;
                a.flags.enlarged = a.flags.enlarged or b.flags.enlarged or e.flags.enlarged;
            }
        } else {
            // Both children internal: pick the best of four possible swaps.
            const id: i32 = b.child1;
            const ie: i32 = b.child2;
            const if_: i32 = c.child1;
            const ig: i32 = c.child2;
            const d: *TreeNode = &nodes[@intCast(id)];
            const e: *TreeNode = &nodes[@intCast(ie)];
            const f: *TreeNode = &nodes[@intCast(if_)];
            const g: *TreeNode = &nodes[@intCast(ig)];

            const area_b: f32 = b.aabb.perimeter();
            const area_c: f32 = c.aabb.perimeter();
            const cost_base: f32 = area_b + area_c;
            var best: u8 = 0; // 0 none, 1 BF, 2 BG, 3 CD, 4 CE
            var best_cost: f32 = cost_base;

            const aabb_bg: Aabb2 = Aabb2.combine(b.aabb, g.aabb);
            const cost_bf: f32 = area_b + aabb_bg.perimeter();
            if (cost_bf < best_cost) {
                best = 1;
                best_cost = cost_bf;
            }
            const aabb_bf: Aabb2 = Aabb2.combine(b.aabb, f.aabb);
            const cost_bg: f32 = area_b + aabb_bf.perimeter();
            if (cost_bg < best_cost) {
                best = 2;
                best_cost = cost_bg;
            }
            const aabb_ce: Aabb2 = Aabb2.combine(c.aabb, e.aabb);
            const cost_cd: f32 = area_c + aabb_ce.perimeter();
            if (cost_cd < best_cost) {
                best = 3;
                best_cost = cost_cd;
            }
            const aabb_cd: Aabb2 = Aabb2.combine(c.aabb, d.aabb);
            const cost_ce: f32 = area_c + aabb_cd.perimeter();
            if (cost_ce < best_cost) {
                best = 4;
            }

            switch (best) {
                0 => {},
                1 => { // swap B and F
                    a.child1 = if_;
                    c.child1 = ib;
                    b.parent = ic;
                    f.parent = ia;
                    c.aabb = aabb_bg;
                    c.height = 1 + @max(b.height, g.height);
                    a.height = 1 + @max(c.height, f.height);
                    c.category_bits = b.category_bits | g.category_bits;
                    a.category_bits = c.category_bits | f.category_bits;
                    c.flags.enlarged = c.flags.enlarged or b.flags.enlarged or g.flags.enlarged;
                    a.flags.enlarged = a.flags.enlarged or c.flags.enlarged or f.flags.enlarged;
                },
                2 => { // swap B and G
                    a.child1 = ig;
                    c.child2 = ib;
                    b.parent = ic;
                    g.parent = ia;
                    c.aabb = aabb_bf;
                    c.height = 1 + @max(b.height, f.height);
                    a.height = 1 + @max(c.height, g.height);
                    c.category_bits = b.category_bits | f.category_bits;
                    a.category_bits = c.category_bits | g.category_bits;
                    c.flags.enlarged = c.flags.enlarged or b.flags.enlarged or f.flags.enlarged;
                    a.flags.enlarged = a.flags.enlarged or c.flags.enlarged or g.flags.enlarged;
                },
                3 => { // swap C and D
                    a.child2 = id;
                    b.child1 = ic;
                    c.parent = ib;
                    d.parent = ia;
                    b.aabb = aabb_ce;
                    b.height = 1 + @max(c.height, e.height);
                    a.height = 1 + @max(b.height, d.height);
                    b.category_bits = c.category_bits | e.category_bits;
                    a.category_bits = b.category_bits | d.category_bits;
                    b.flags.enlarged = b.flags.enlarged or c.flags.enlarged or e.flags.enlarged;
                    a.flags.enlarged = a.flags.enlarged or b.flags.enlarged or d.flags.enlarged;
                },
                4 => { // swap C and E
                    a.child2 = ie;
                    b.child2 = ic;
                    c.parent = ib;
                    e.parent = ia;
                    b.aabb = aabb_cd;
                    b.height = 1 + @max(c.height, d.height);
                    a.height = 1 + @max(b.height, e.height);
                    b.category_bits = c.category_bits | d.category_bits;
                    a.category_bits = b.category_bits | e.category_bits;
                    b.flags.enlarged = b.flags.enlarged or c.flags.enlarged or d.flags.enlarged;
                    a.flags.enlarged = a.flags.enlarged or b.flags.enlarged or e.flags.enlarged;
                },
                else => unreachable,
            }
        }
    }

    /// Insert an already-initialized leaf node into the tree, optionally rebalancing.
    /// box2d: b2InsertLeaf  dynamic_tree.c:602
    fn insertLeaf(
        self: *DynamicTree,
        gpa: Allocator,
        leaf: i32,
        should_rotate: bool,
    ) !void {
        if (self.root == node_null) {
            self.root = leaf;
            self.at(leaf).parent = node_null;
            return;
        }

        const leaf_aabb: Aabb2 = self.at(leaf).aabb;
        const sibling: i32 = self.findBestSibling(leaf_aabb);
        const old_parent: i32 = self.at(sibling).parent;

        // Allocate the new parent first - this may move the backing array, so we only
        // take node references AFTER the allocation.
        const new_parent: i32 = try self.allocateNode(gpa);
        const nodes: []TreeNode = self.nodes.items;
        {
            const np: *TreeNode = &nodes[@intCast(new_parent)];
            np.parent = old_parent;
            np.user_data = maxInt(u64);
            np.aabb = Aabb2.combine(leaf_aabb, nodes[@intCast(sibling)].aabb);
            np.category_bits =
                nodes[@intCast(leaf)].category_bits | nodes[@intCast(sibling)].category_bits;
            np.height = nodes[@intCast(sibling)].height + 1;
            np.child1 = sibling;
            np.child2 = leaf;
            np.flags = .{ .allocated = true };
        }
        nodes[@intCast(sibling)].parent = new_parent;
        nodes[@intCast(leaf)].parent = new_parent;

        // Reconnect the grandparent (or promote the new parent to root).
        if (old_parent != node_null) {
            if (nodes[@intCast(old_parent)].child1 == sibling) {
                nodes[@intCast(old_parent)].child1 = new_parent;
            } else {
                nodes[@intCast(old_parent)].child2 = new_parent;
            }
        } else {
            self.root = new_parent;
        }

        // Walk back up fixing AABBs, heights, category bits, and rebalancing.
        var index: i32 = self.at(leaf).parent;
        while (index != node_null) {
            const child1: i32 = self.at(index).child1;
            const child2: i32 = self.at(index).child2;
            const node: *TreeNode = self.at(index);
            node.aabb = Aabb2.combine(self.at(child1).aabb, self.at(child2).aabb);
            node.category_bits = self.at(child1).category_bits | self.at(child2).category_bits;
            node.height = 1 + @max(self.at(child1).height, self.at(child2).height);
            node.flags.enlarged =
                node.flags.enlarged or self.at(child1).flags.enlarged or self.at(child2).flags.enlarged;
            if (should_rotate) {
                self.rotateNodes(index);
            }
            index = self.at(index).parent;
        }
    }

    /// Remove a leaf, collapsing its parent and fixing ancestor bounds.
    /// box2d: b2RemoveLeaf  dynamic_tree.c:675
    fn removeLeaf(self: *DynamicTree, leaf: i32) void {
        if (leaf == self.root) {
            self.root = node_null;
            return;
        }

        const parent: i32 = self.at(leaf).parent;
        const grand_parent: i32 = self.at(parent).parent;
        const sibling: i32 = if (self.at(parent).child1 == leaf)
            self.at(parent).child2
        else
            self.at(parent).child1;

        if (grand_parent != node_null) {
            // Splice the sibling up into the grandparent and free the parent.
            if (self.at(grand_parent).child1 == parent) {
                self.at(grand_parent).child1 = sibling;
            } else {
                self.at(grand_parent).child2 = sibling;
            }
            self.at(sibling).parent = grand_parent;
            self.freeNode(parent);

            // Fix ancestor bounds up to the root.
            var index: i32 = grand_parent;
            while (index != node_null) {
                const child1: i32 = self.at(index).child1;
                const child2: i32 = self.at(index).child2;
                const node: *TreeNode = self.at(index);
                node.aabb = Aabb2.combine(self.at(child1).aabb, self.at(child2).aabb);
                node.category_bits = self.at(child1).category_bits | self.at(child2).category_bits;
                node.height = 1 + @max(self.at(child1).height, self.at(child2).height);
                index = self.at(index).parent;
            }
        } else {
            // Parent was the root; sibling becomes the new root.
            self.root = sibling;
            self.at(sibling).parent = node_null;
            self.freeNode(parent);
        }
    }

    /// Insert a new shape proxy (a leaf) with the given fat AABB. Returns the proxy id.
    /// box2d: b2DynamicTree_CreateProxy  dynamic_tree.c:744
    pub fn createProxy(
        self: *DynamicTree,
        gpa: Allocator,
        aabb: Aabb2,
        category_bits: u64,
        user_data: u64,
    ) !i32 {
        const proxy_id: i32 = try self.allocateNode(gpa);
        const node: *TreeNode = self.at(proxy_id);
        node.aabb = aabb;
        node.user_data = user_data;
        node.category_bits = category_bits;
        node.height = 0;
        node.flags = .{ .allocated = true, .leaf = true };
        try self.insertLeaf(gpa, proxy_id, true);
        self.proxy_count += 1;
        return proxy_id;
    }

    /// Remove a shape proxy. box2d: b2DynamicTree_DestroyProxy  dynamic_tree.c:765
    pub fn destroyProxy(self: *DynamicTree, proxy_id: i32) void {
        self.removeLeaf(proxy_id);
        self.freeNode(proxy_id);
        self.proxy_count -= 1;
    }

    /// Reinsert a proxy at a new AABB (remove + insert, no rebalance on insert).
    /// box2d: b2DynamicTree_MoveProxy  dynamic_tree.c:782
    pub fn moveProxy(
        self: *DynamicTree,
        gpa: Allocator,
        proxy_id: i32,
        aabb: Aabb2,
    ) !void {
        self.removeLeaf(proxy_id);
        self.at(proxy_id).aabb = aabb;
        // Rotate on re-insert so the tree stays balanced as proxies move. Without this, a scene
        // where every proxy moves each step (e.g. a churning pile) degrades the tree to ~4-5x its
        // ideal height and query traversal cost climbs with it. Measured on the 1936-body washer:
        // tree height ~50 -> ~15, broad-phase query node-visits ~219k -> ~121k per step. box2d keeps
        // quality via a continuous incremental rebuild; the per-move rotation does it here without a
        // periodic full-rebuild spike (that path still exists via `tree_rebuild_interval`).
        try self.insertLeaf(gpa, proxy_id, true);
    }

    /// Grow a proxy's AABB in place, propagating the enlargement up the ancestors and
    /// marking them so the broad phase re-tests them. The new AABB must not be
    /// contained in the old one (the caller ensures a real growth).
    /// box2d: b2DynamicTree_EnlargeProxy  dynamic_tree.c:798
    pub fn enlargeProxy(self: *DynamicTree, proxy_id: i32, aabb: Aabb2) void {
        self.at(proxy_id).aabb = aabb;

        var parent: i32 = self.at(proxy_id).parent;
        // Phase 1: grow ancestors until one already contains the new box.
        while (parent != node_null) {
            const changed: bool = enlargeAabb(&self.at(parent).aabb, aabb);
            self.at(parent).flags.enlarged = true;
            parent = self.at(parent).parent;
            if (changed == false) {
                break;
            }
        }
        // Phase 2: just mark remaining ancestors enlarged (until one already is).
        while (parent != node_null) {
            if (self.at(parent).flags.enlarged) {
                break;
            }
            self.at(parent).flags.enlarged = true;
            parent = self.at(parent).parent;
        }
    }

    /// Visit every leaf whose fat AABB overlaps `aabb` and whose category passes
    /// `mask_bits`. The callback returns false to stop early.
    /// box2d: b2DynamicTree_Query  dynamic_tree.c:1085
    pub fn query(
        self: *DynamicTree,
        aabb: Aabb2,
        mask_bits: u64,
        callback: TreeQueryCallback,
        ctx: *anyopaque,
    ) void {
        if (self.nodes.items.len == 0 or self.root == node_null) {
            return;
        }

        var stack: [1024]i32 = undefined;
        var count: usize = 0;
        stack[count] = self.root;
        count += 1;

        while (count > 0) {
            count -= 1;
            const node_id: i32 = stack[count];
            const node: *const TreeNode = &self.nodes.items[@intCast(node_id)];

            if (Aabb2.overlaps(node.aabb, aabb) and (node.category_bits & mask_bits) != 0) {
                if (isLeaf(node)) {
                    const proceed: bool = callback(node_id, node.user_data, ctx);
                    if (proceed == false) {
                        return;
                    }
                } else if (count + 2 <= stack.len) {
                    stack[count] = node.child1;
                    count += 1;
                    stack[count] = node.child2;
                    count += 1;
                }
            }
        }
    }

    pub fn proxyAabb(self: *DynamicTree, proxy_id: i32) Aabb2 {
        return self.at(proxy_id).aabb;
    }
    pub fn proxyUserData(self: *DynamicTree, proxy_id: i32) u64 {
        return self.at(proxy_id).user_data;
    }

    /// Rebuild the tree from scratch from its current leaves, producing a better-balanced,
    /// tighter hierarchy than incremental insertion leaves behind. Internal nodes are freed
    /// and rebuilt; leaves keep their proxies. box2d: b2DynamicTree_Rebuild (full build)
    /// Re-tighten every internal node's AABB from its children, bottom-up, without touching the
    /// tree structure. `enlargeProxy` only ever *grows* ancestor AABBs (it never shrinks them when a
    /// leaf moves away), so over the steps between structural rebuilds the internal bounds bloat and
    /// queries visit more falsely-overlapping nodes. This O(n) pass - far cheaper than a structural
    /// rebuild - recomputes each internal AABB as the tight union of its children, so the tree stays
    /// query-tight every step even when every leaf is moving (where a structural rebuild can't help).
    /// Internal nodes are gathered in pre-order, then processed in reverse so each node's children are
    /// already tightened when it is combined.
    fn refitTight(self: *DynamicTree, gpa: Allocator) !void {
        if (self.root == node_null) {
            return;
        }
        if (isLeaf(self.at(self.root))) {
            return; // a single leaf has no internal nodes
        }
        self.refit_order.clearRetainingCapacity();
        var stack: [1024]i32 = undefined;
        var sc: usize = 0;
        stack[0] = self.root;
        sc = 1;
        while (sc > 0) {
            sc -= 1;
            const idx: i32 = stack[sc];
            const node: *TreeNode = self.at(idx);
            if (isLeaf(node)) {
                continue;
            }
            try self.refit_order.append(gpa, idx);
            // Balanced tree: DFS frontier is bounded by height, well under the stack cap.
            if (sc < stack.len) {
                stack[sc] = node.child1;
                sc += 1;
            }
            if (sc < stack.len) {
                stack[sc] = node.child2;
                sc += 1;
            }
        }
        var i: usize = self.refit_order.items.len;
        while (i > 0) {
            i -= 1;
            const node: *TreeNode = self.at(self.refit_order.items[i]);
            const c1: *const TreeNode = self.at(node.child1);
            const c2: *const TreeNode = self.at(node.child2);
            node.aabb = Aabb2.combine(c1.aabb, c2.aabb);
            node.category_bits = c1.category_bits | c2.category_bits;
            node.height = 1 + @max(c1.height, c2.height);
        }
    }

    fn rebuild(self: *DynamicTree, gpa: Allocator) !void {
        const proxy_count: i32 = self.proxy_count;
        if (proxy_count <= 1) {
            return; // 0 or 1 leaf is already optimal
        }
        const n: usize = @intCast(proxy_count);
        const indices: []i32 = try gpa.alloc(i32, n);
        defer gpa.free(indices);
        const centers: []Vec2 = try gpa.alloc(Vec2, n);
        defer gpa.free(centers);

        // Collect every leaf, freeing internal nodes as they are passed.
        var leaf_count: usize = 0;
        var stack: [1024]i32 = undefined;
        var sc: usize = 0;
        var node_index: i32 = self.root;
        while (true) {
            const node: *TreeNode = self.at(node_index);
            if (isLeaf(node)) {
                indices[leaf_count] = node_index;
                centers[leaf_count] = Aabb2.center(node.aabb);
                leaf_count += 1;
                node.parent = node_null;
            } else {
                const doomed: i32 = node_index;
                const c1: i32 = node.child1;
                const c2: i32 = node.child2;
                node_index = c1;
                if (sc < stack.len) {
                    stack[sc] = c2;
                    sc += 1;
                }
                self.freeNode(doomed);
                continue;
            }
            if (sc == 0) {
                break;
            }
            sc -= 1;
            node_index = stack[sc];
        }
        self.root = try self.buildTree(gpa, indices, centers, leaf_count);
    }

    /// Top-down build of a balanced tree over the collected leaves, splitting each range at
    /// the median of the longest axis. Internal nodes are taken from the freed pool. The
    /// leaf nodes already exist; only their parent links are set. box2d: b2BuildTree
    fn buildTree(
        self: *DynamicTree,
        gpa: Allocator,
        indices: []i32,
        centers: []Vec2,
        leaf_count: usize,
    ) !i32 {
        if (leaf_count == 1) {
            self.at(indices[0]).parent = node_null;
            return indices[0];
        }
        var stack: [1024]RebuildItem = undefined;
        var top: usize = 0;
        stack[0] = .{
            .node_index = try self.allocateNode(gpa),
            .child_count = -1,
            .start = 0,
            .end = leaf_count,
            .split = partitionMid(indices, centers, leaf_count),
        };
        while (true) {
            const item: *RebuildItem = &stack[top];
            item.child_count += 1;
            if (item.child_count == 2) {
                if (top == 0) {
                    break;
                }
                const parent_item: *RebuildItem = &stack[top - 1];
                const parent_node: *TreeNode = self.at(parent_item.node_index);
                if (parent_item.child_count == 0) {
                    parent_node.child1 = item.node_index;
                } else {
                    parent_node.child2 = item.node_index;
                }
                const node: *TreeNode = self.at(item.node_index);
                node.parent = parent_item.node_index;
                const child1: *TreeNode = self.at(node.child1);
                const child2: *TreeNode = self.at(node.child2);
                node.aabb = Aabb2.combine(child1.aabb, child2.aabb);
                node.height = 1 + @max(child1.height, child2.height);
                node.category_bits = child1.category_bits | child2.category_bits;
                top -= 1;
            } else {
                var start: usize = undefined;
                var end: usize = undefined;
                if (item.child_count == 0) {
                    start = item.start;
                    end = item.split;
                } else {
                    start = item.split;
                    end = item.end;
                }
                const count: usize = end - start;
                if (count == 1) {
                    const child_index: i32 = indices[start];
                    const node: *TreeNode = self.at(item.node_index);
                    if (item.child_count == 0) {
                        node.child1 = child_index;
                    } else {
                        node.child2 = child_index;
                    }
                    self.at(child_index).parent = item.node_index;
                } else {
                    top += 1;
                    const inner: usize = partitionMid(indices[start..end], centers[start..end], count);
                    stack[top] = .{
                        .node_index = try self.allocateNode(gpa),
                        .child_count = -1,
                        .start = start,
                        .end = end,
                        .split = start + inner,
                    };
                }
            }
        }
        const root_node: *TreeNode = self.at(stack[0].node_index);
        const child1: *TreeNode = self.at(root_node.child1);
        const child2: *TreeNode = self.at(root_node.child2);
        root_node.aabb = Aabb2.combine(child1.aabb, child2.aabb);
        root_node.height = 1 + @max(child1.height, child2.height);
        root_node.category_bits = child1.category_bits | child2.category_bits;
        return stack[0].node_index;
    }
};

/// One frame of the explicit-stack tree build: the internal node being built, which child
/// is in progress, and the leaf range it covers (split at `split`). box2d: b2RebuildItem
const RebuildItem = struct {
    node_index: i32,
    child_count: i32, // -1 before either child, 0/1 while building child1/child2, 2 when done
    start: usize,
    end: usize,
    split: usize,
};

/// Partition a leaf range about the median of its longest axis, swapping indices and
/// centers in tandem. Returns the split offset within the range. box2d: b2PartitionMid
fn partitionMid(indices: []i32, centers: []Vec2, count: usize) usize {
    if (count <= 2) {
        return count / 2;
    }
    var lower: Vec2 = centers[0];
    var upper: Vec2 = centers[0];
    var k: usize = 1;
    while (k < count) : (k += 1) {
        lower = @min(lower, centers[k]);
        upper = @max(upper, centers[k]);
    }
    const d: Vec2 = upper - lower;
    var left: usize = 0;
    var right: usize = count;
    if (d[0] > d[1]) {
        const pivot: f32 = 0.5 * (lower[0] + upper[0]);
        while (left < right) {
            while (left < right and centers[left][0] < pivot) {
                left += 1;
            }
            while (left < right and centers[right - 1][0] >= pivot) {
                right -= 1;
            }
            if (left < right) {
                std.mem.swap(i32, &indices[left], &indices[right - 1]);
                std.mem.swap(Vec2, &centers[left], &centers[right - 1]);
                left += 1;
                right -= 1;
            }
        }
    } else {
        const pivot: f32 = 0.5 * (lower[1] + upper[1]);
        while (left < right) {
            while (left < right and centers[left][1] < pivot) {
                left += 1;
            }
            while (left < right and centers[right - 1][1] >= pivot) {
                right -= 1;
            }
            if (left < right) {
                std.mem.swap(i32, &indices[left], &indices[right - 1]);
                std.mem.swap(Vec2, &centers[left], &centers[right - 1]);
                left += 1;
                right -= 1;
            }
        }
    }
    if (left > 0 and left < count) {
        return left;
    }
    return count / 2;
}

// ================================================================================
// Broad phase
//
// Three dynamic trees, one per body type (static / kinematic / dynamic), plus a move
// buffer of proxies that changed this step and a hash set of the shape pairs that
// already have a contact. Proxies are addressed by a packed "proxy key" = (treeId <<
// 2) | bodyType. The actual pair-finding (`updateBroadPhasePairs`) lives with the
// World in section 21, because it must read shapes/bodies and create contacts.
// box2d: broad_phase.c / broad_phase.h
// ================================================================================

/// Pack a tree-local proxy id and a body type into a broad-phase key.
/// box2d: B2_PROXY_KEY  broad_phase.h:20
inline fn makeProxyKey(id: i32, body_type: MotionType) u32 {
    return (@as(u32, @intCast(id)) << 2) | @backingInt(body_type);
}
inline fn proxyKeyId(key: u32) i32 {
    return @intCast(key >> 2);
}
inline fn proxyKeyType(key: u32) MotionType {
    return @fromBackingInt(@intCast(key & 3));
}

/// Order-independent 64-bit key for a pair of shapes (used to dedup contacts).
/// box2d: B2_SHAPE_PAIR_KEY  table.h:9
inline fn shapePairKey(shape_a: u32, shape_b: u32) u64 {
    const lo: u32 = @min(shape_a, shape_b);
    const hi: u32 = @max(shape_a, shape_b);
    return (@as(u64, lo) << 32) | @as(u64, hi);
}

/// Whether two shape kinds can ever produce a contact. Two infinitely thin shapes
/// (segment / chain segment) never collide with each other; everything else does.
/// box2d: b2CanCollide (the s_registers gaps)  shape.c
pub fn canCollide(a: ShapeKind, b: ShapeKind) bool {
    const thin_a: bool = a == .segment or a == .chain_segment;
    const thin_b: bool = b == .segment or b == .chain_segment;
    return !(thin_a and thin_b);
}

/// The category/mask/group collision filter test. Bodies in the same nonzero group
/// always collide (positive group) or never collide (negative group); otherwise the
/// category/mask bits must mutually pass. box2d: b2ShouldShapesCollide  shape.c
pub fn shouldShapesCollide(a: Filter, b: Filter) bool {
    if (a.group == b.group and a.group != 0) {
        return a.group > 0;
    }
    return (a.mask & b.category) != 0 and (a.category & b.mask) != 0;
}

/// A flat open-addressing hash set of shape-pair keys, used by the broad phase to dedup contacts.
/// It is probed once per broad-phase candidate (`contains`) plus once per contact create/destroy
/// (`put`/`remove`) - in a dense pile, tens of thousands of lookups per step, making it the hottest
/// structure in the broad phase. A single contiguous key array with linear probing and
/// backward-shift deletion keeps every probe in cache and skips the metadata side-table + Wyhash of
/// the general-purpose hash map; the keys are uniform so a multiply-shift hash suffices. Empty slots
/// hold `empty_key`, which is unreachable as a real pair key (`(lo<<32)|hi` is always < 2^63).
/// box2d uses an equivalent open-addressing set (b2HashSet, table.c).
const PairSet = struct {
    keys: []u64 = &.{}, // power-of-two table (or empty); empty slots == empty_key
    count: u32 = 0,

    const empty_key: u64 = maxInt(u64);

    fn deinit(self: *PairSet, gpa: Allocator) void {
        if (self.keys.len > 0) {
            gpa.free(self.keys);
        }
        self.* = .{};
    }

    /// Fibonacci hash: multiply by 2^64/phi and take the top log2(len) bits.
    inline fn slotFor(self: *const PairSet, key: u64) u32 {
        const bits: u6 = @intCast(@ctz(@as(u64, self.keys.len)));
        return @intCast((key *% 0x9E3779B97F4A7C15) >> @intCast(64 - @as(u32, bits)));
    }

    fn contains(self: *const PairSet, key: u64) bool {
        if (self.keys.len == 0) {
            return false;
        }
        const mask: u32 = @intCast(self.keys.len - 1);
        var i: u32 = self.slotFor(key);
        while (true) {
            const k: u64 = self.keys[i];
            if (k == key) {
                return true;
            }
            if (k == empty_key) {
                return false;
            }
            i = (i + 1) & mask;
        }
    }

    /// Insert assuming spare capacity; returns true if newly added.
    fn insertNoGrow(self: *PairSet, key: u64) bool {
        const mask: u32 = @intCast(self.keys.len - 1);
        var i: u32 = self.slotFor(key);
        while (true) {
            const k: u64 = self.keys[i];
            if (k == key) {
                return false;
            }
            if (k == empty_key) {
                self.keys[i] = key;
                return true;
            }
            i = (i + 1) & mask;
        }
    }

    fn put(self: *PairSet, gpa: Allocator, key: u64) Allocator.Error!void {
        // Grow at 0.75 load (and from empty) so probe runs stay short and a free slot always exists.
        if (self.keys.len == 0 or (self.count + 1) * 4 >= @as(u32, @intCast(self.keys.len)) * 3) {
            try self.grow(gpa, @max(16, @as(u32, @intCast(self.keys.len)) * 2));
        }
        if (self.insertNoGrow(key)) {
            self.count += 1;
        }
    }

    fn grow(self: *PairSet, gpa: Allocator, new_len: u32) Allocator.Error!void {
        const old: []u64 = self.keys;
        const keys: []u64 = try gpa.alloc(u64, new_len);
        @memset(keys, empty_key);
        self.keys = keys;
        for (old) |k| {
            if (k != empty_key) {
                _ = self.insertNoGrow(k);
            }
        }
        if (old.len > 0) {
            gpa.free(old);
        }
    }

    /// True if `x` lies in the cyclic interval (lo, hi] modulo the table size.
    inline fn inCyclicRange(x: u32, lo: u32, hi: u32) bool {
        if (lo <= hi) {
            return x > lo and x <= hi;
        }
        return x > lo or x <= hi;
    }

    /// Remove a key via backward-shift deletion: no tombstones, so a high-churn set (the broad
    /// phase creates/destroys hundreds of contacts per step) keeps tight probe runs indefinitely.
    fn remove(self: *PairSet, key: u64) void {
        if (self.keys.len == 0) {
            return;
        }
        const mask: u32 = @intCast(self.keys.len - 1);
        var i: u32 = self.slotFor(key);
        while (true) {
            const k: u64 = self.keys[i];
            if (k == empty_key) {
                return; // not present
            }
            if (k == key) {
                break;
            }
            i = (i + 1) & mask;
        }
        // Walk forward, pulling any entry that probed past the hole back into it.
        var j: u32 = i;
        while (true) {
            j = (j + 1) & mask;
            const kj: u64 = self.keys[j];
            if (kj == empty_key) {
                break;
            }
            const home: u32 = self.slotFor(kj);
            if (!inCyclicRange(home, i, j)) {
                self.keys[i] = kj;
                i = j;
            }
        }
        self.keys[i] = empty_key;
        self.count -= 1;
    }
};

pub const BroadPhase = struct {
    /// Indexed by @intFromEnum(MotionType): static, kinematic, dynamic.
    trees: [3]DynamicTree = .{ .{}, .{}, .{} },
    /// Per-proxy "moved this step" flags, one list per tree (indexed by tree proxy id).
    moved: [3]std.ArrayListUnmanaged(bool) = .{ .empty, .empty, .empty },
    /// Proxy keys queued for pair-finding this step (a sentinel slot can be cleared).
    move_array: std.ArrayListUnmanaged(u32) = .empty,
    /// The set of shape pairs that currently have a contact (dedup for pair-finding).
    pair_set: PairSet = .{},

    pub fn deinit(self: *BroadPhase, gpa: Allocator) void {
        for (&self.trees) |*tree| {
            tree.deinit(gpa);
        }
        for (&self.moved) |*m| {
            m.deinit(gpa);
        }
        self.move_array.deinit(gpa);
        self.pair_set.deinit(gpa);
        self.* = .{};
    }

    /// Mark a proxy as moved and queue it for pair-finding (idempotent per step).
    /// box2d: b2BufferMove  broad_phase.h:70
    fn bufferMove(self: *BroadPhase, gpa: Allocator, key: u32) !void {
        const tree_index: usize = @backingInt(proxyKeyType(key));
        const proxy_id: usize = @intCast(proxyKeyId(key));
        var moved: *std.ArrayListUnmanaged(bool) = &self.moved[tree_index];
        while (moved.items.len <= proxy_id) {
            try moved.append(gpa, false);
        }
        if (moved.items[proxy_id] == false) {
            moved.items[proxy_id] = true;
            try self.move_array.append(gpa, key);
        }
    }

    /// Remove a proxy from the move buffer (e.g. when it is destroyed).
    /// box2d: b2UnBufferMove  broad_phase.c
    fn unBufferMove(self: *BroadPhase, key: u32) void {
        const tree_index: usize = @backingInt(proxyKeyType(key));
        const proxy_id: usize = @intCast(proxyKeyId(key));
        var moved: *std.ArrayListUnmanaged(bool) = &self.moved[tree_index];
        if (proxy_id < moved.items.len and moved.items[proxy_id]) {
            moved.items[proxy_id] = false;
            // Linear search + swap-remove from the move array.
            var i: usize = 0;
            while (i < self.move_array.items.len) : (i += 1) {
                if (self.move_array.items[i] == key) {
                    _ = self.move_array.swapRemove(i);
                    break;
                }
            }
        }
    }

    /// Create a broad-phase proxy for a shape and return its key. Non-static proxies
    /// (or any proxy when `force_pair_creation` is set) are queued for pair-finding.
    /// box2d: b2BroadPhase_CreateProxy  broad_phase.c:104
    pub fn createProxy(
        self: *BroadPhase,
        gpa: Allocator,
        body_type: MotionType,
        aabb: Aabb2,
        category_bits: u64,
        shape_index: u32,
        force_pair_creation: bool,
    ) !u32 {
        const tree_index: usize = @backingInt(body_type);
        const proxy_id: i32 =
            try self.trees[tree_index].createProxy(gpa, aabb, category_bits, shape_index);
        const key: u32 = makeProxyKey(proxy_id, body_type);
        if (body_type != .static or force_pair_creation) {
            try self.bufferMove(gpa, key);
        }
        return key;
    }

    /// Destroy a proxy. box2d: b2BroadPhase_DestroyProxy  broad_phase.c:117
    pub fn destroyProxy(self: *BroadPhase, key: u32) void {
        self.unBufferMove(key);
        const tree_index: usize = @backingInt(proxyKeyType(key));
        self.trees[tree_index].destroyProxy(proxyKeyId(key));
    }

    /// Move a proxy to a new AABB and queue it. box2d: b2BroadPhase_MoveProxy  broad_phase.c:128
    pub fn moveProxy(
        self: *BroadPhase,
        gpa: Allocator,
        key: u32,
        aabb: Aabb2,
    ) !void {
        const tree_index: usize = @backingInt(proxyKeyType(key));
        try self.trees[tree_index].moveProxy(gpa, proxyKeyId(key), aabb);
        try self.bufferMove(gpa, key);
    }

    /// Enlarge a (non-static) proxy's AABB and queue it.
    /// box2d: b2BroadPhase_EnlargeProxy  broad_phase.c:137
    pub fn enlargeProxy(
        self: *BroadPhase,
        gpa: Allocator,
        key: u32,
        aabb: Aabb2,
    ) !void {
        const tree_index: usize = @backingInt(proxyKeyType(key));
        assert(tree_index != @backingInt(MotionType.static), @src());
        self.trees[tree_index].enlargeProxy(proxyKeyId(key), aabb);
        try self.bufferMove(gpa, key);
    }

    /// The shape index stored in a proxy's user data.
    /// box2d: b2BroadPhase_GetShapeIndex  broad_phase.c:543
    pub fn shapeIndexOf(self: *BroadPhase, key: u32) u32 {
        const tree_index: usize = @backingInt(proxyKeyType(key));
        return @intCast(self.trees[tree_index].proxyUserData(proxyKeyId(key)));
    }

    /// Do two proxies' fat AABBs overlap? box2d: b2BroadPhase_TestOverlap  broad_phase.c
    pub fn testOverlap(self: *BroadPhase, key_a: u32, key_b: u32) bool {
        const tree_a: usize = @backingInt(proxyKeyType(key_a));
        const tree_b: usize = @backingInt(proxyKeyType(key_b));
        const box_a: Aabb2 = self.trees[tree_a].proxyAabb(proxyKeyId(key_a));
        const box_b: Aabb2 = self.trees[tree_b].proxyAabb(proxyKeyId(key_b));
        return Aabb2.overlaps(box_a, box_b);
    }
};

// ================================================================================
// Contacts - persistent narrow-phase state
//
// A `Contact` couples two shapes that are (or may soon be) touching. It owns the
// persistent manifold whose stored impulses and feature ids warm-start the solver
// across steps, the GJK simplex cache for chain-segment pairs, the mixed surface
// material, and the intrusive edges that thread it onto both bodies' contact lists.
// `updateContact` regenerates the manifold each step and matches impulses by id.
// box2d: contact.c / contact.h (we merge b2Contact + b2ContactSim, having dropped
// the solver-set / constraint-graph machinery). Contact creation/destruction needs
// the World and lives in section 21.
// ================================================================================

/// Persistent + per-step contact flags. box2d: b2ContactFlags  contact.h:9
pub const ContactFlags = packed struct(u32) {
    touching: bool = false, // authoritative touching state (drives islands + events)
    enable_contact_events: bool = false, // either shape opted into begin/end events
    enable_pre_solve: bool = false, // either shape opted into pre-solve callbacks
    sim_touching: bool = false, // touching as of the last updateContact
    started_touching: bool = false, // went not-touching -> touching this step
    stopped_touching: bool = false, // went touching -> not-touching this step
    sim_enable_hit_event: bool = false, // this contact may emit a hit event this step
    _pad: u25 = 0,
};

/// One end of a contact's intrusive doubly-linked list on a body. The "key" packs a
/// contact id and which edge (low bit): key = contactId << 1 | edgeIndex.
/// box2d: b2ContactEdge  contact.h
const ContactEdge = struct {
    prev_key: u32 = null_index,
    next_key: u32 = null_index,
};

/// A persistent contact between two shapes. The shapes are stored already ordered so
/// the pair matches a primary collide registration (the more complex shape is A); the
/// contact's id is its index in `world.contacts`.
pub const Contact = struct {
    shape_a: u32, // shape index (the reference/"primary" shape)
    shape_b: u32, // shape index
    body_a: BodyIndex,
    body_b: BodyIndex,
    manifold: Manifold,
    cache: SimplexCache, // GJK warm-start for chain-segment pairs
    friction: f32,
    restitution: f32,
    rolling_resistance: f32,
    tangent_speed: f32,
    flags: ContactFlags,
    edge_a: ContactEdge, // links into body_a's contact list
    edge_b: ContactEdge, // links into body_b's contact list
    local_index: u32 = null_index, // position in world.contact_ids (dense live list)
};

/// Default friction mixing: the geometric mean. box2d: b2DefaultFrictionCallback  types.c
pub fn defaultMixFriction(
    friction_a: f32,
    id_a: u64,
    friction_b: f32,
    id_b: u64,
) f32 {
    _ = id_a;
    _ = id_b;
    return @sqrt(friction_a * friction_b);
}

/// Default restitution mixing: the larger of the two. box2d: b2DefaultRestitutionCallback  types.c
pub fn defaultMixRestitution(
    restitution_a: f32,
    id_a: u64,
    restitution_b: f32,
    id_b: u64,
) f32 {
    _ = id_a;
    _ = id_b;
    return @max(restitution_a, restitution_b);
}

pub const FrictionMixFn = *const fn (f32, u64, f32, u64) f32;
pub const RestitutionMixFn = *const fn (f32, u64, f32, u64) f32;
/// Pre-solve veto: return false to disable a contact for this step. box2d: b2PreSolveFcn
pub const PreSolveFn = *const fn (
    shape_a: u32,
    shape_b: u32,
    point: Vec2,
    normal: Vec2,
    ctx: ?*anyopaque,
) bool;

/// Custom collision filter: return false to prevent two shapes from colliding, beyond the
/// category/mask rules. Consulted once at pair creation, only for pairs where at least one shape
/// opted in via `enable_custom_filtering`. box2d: b2CustomFilterFcn
pub const CustomFilterFn = *const fn (
    shape_a: u32,
    shape_b: u32,
    ctx: ?*anyopaque,
) bool;

/// Tunable hooks for the narrow phase (mixing callbacks, speculative toggle, a custom collision
/// filter, and an optional pre-solve veto). Held by the World and passed into `updateContact`.
pub const NarrowPhaseConfig = struct {
    enable_speculative: bool = true,
    friction_fn: FrictionMixFn = defaultMixFriction,
    restitution_fn: RestitutionMixFn = defaultMixRestitution,
    pre_solve_fn: ?PreSolveFn = null,
    pre_solve_ctx: ?*anyopaque = null,
    custom_filter_fn: ?CustomFilterFn = null,
    custom_filter_ctx: ?*anyopaque = null,
};

/// Regenerate a contact's manifold from the two shapes' current world transforms,
/// marshal it to center-of-mass-relative world anchors, and warm-start the new points
/// from the previous step's stored impulses (matched by feature id). Returns whether
/// the shapes are touching. The `center_offset` of a body is (worldCOM - origin) =
/// rotateVec2(transform.q, localCenter); the caller supplies it.
/// box2d: b2UpdateContact  contact.c:519
pub fn updateContact(
    contact: *Contact,
    shape_a: *const Shape,
    transform_a: Transform2,
    center_offset_a: Vec2,
    shape_b: *const Shape,
    transform_b: Transform2,
    center_offset_b: Vec2,
    config: NarrowPhaseConfig,
) bool {
    // Keep a (mutable) copy of the old manifold so we can match + consume its impulses.
    var old: Manifold = contact.manifold;

    // Run the narrow phase in frame A, then rotate/translate into world. Differencing
    // the origins (originDelta) keeps precision far from the world origin.
    const relative: Transform2 = invMulTransforms2(transform_a, transform_b);
    const local: LocalManifold = collideShapes(&shape_a.geom, &shape_b.geom, relative, &contact.cache);

    contact.manifold = Manifold.empty;
    contact.manifold.normal = rotateVec2(transform_a.q, local.normal);
    contact.manifold.count = local.count;

    const origin_delta: Vec2 = transform_a.p - transform_b.p;
    {
        var i: usize = 0;
        while (i < local.count) : (i += 1) {
            var mp: *ManifoldPoint = &contact.manifold.points[i];
            mp.anchor_a = rotateVec2(transform_a.q, local.points[i].point);
            mp.anchor_b = mp.anchor_a + origin_delta;
            mp.separation = local.points[i].separation;
            mp.id = local.points[i].id;
        }
    }

    // Surface material mixing (re-evaluated each step so live edits take effect).
    contact.friction = config.friction_fn(
        shape_a.material.friction,
        shape_a.material.user_material_id,
        shape_b.material.friction,
        shape_b.material.user_material_id,
    );
    contact.restitution = config.restitution_fn(
        shape_a.material.restitution,
        shape_a.material.user_material_id,
        shape_b.material.restitution,
        shape_b.material.user_material_id,
    );
    if (shape_a.material.rolling_resistance > 0.0 or shape_b.material.rolling_resistance > 0.0) {
        const radius_a: f32 = shapeRadius(shape_a.geom);
        const radius_b: f32 = shapeRadius(shape_b.geom);
        const max_radius: f32 = @max(radius_a, radius_b);
        const max_rr: f32 = @max(shape_a.material.rolling_resistance, shape_b.material.rolling_resistance);
        contact.rolling_resistance = max_rr * max_radius;
    } else {
        contact.rolling_resistance = 0.0;
    }
    contact.tangent_speed = shape_a.material.tangent_speed + shape_b.material.tangent_speed;

    var point_count: u32 = contact.manifold.count;
    var touching: bool = point_count > 0;

    // Optional pre-solve veto at the deepest point (anchors are still origin-relative).
    if (touching and config.pre_solve_fn != null and contact.flags.enable_pre_solve) {
        var best_separation: f32 = contact.manifold.points[0].separation;
        var best_point: Vec2 = transform_a.p + contact.manifold.points[0].anchor_a;
        var i: usize = 1;
        while (i < point_count) : (i += 1) {
            const sep: f32 = contact.manifold.points[i].separation;
            if (sep < best_separation) {
                best_separation = sep;
                best_point = transform_a.p + contact.manifold.points[i].anchor_a;
            }
        }
        touching = config.pre_solve_fn.?(
            contact.shape_a,
            contact.shape_b,
            best_point,
            contact.manifold.normal,
            config.pre_solve_ctx,
        );
        if (touching == false) {
            point_count = 0;
            contact.manifold.count = 0;
        }
    }

    // Test-only: with speculative contacts disabled, drop a far second point.
    if (config.enable_speculative == false and point_count == 2) {
        if (contact.manifold.points[0].separation > 1.5 * linear_slop) {
            contact.manifold.points[0] = contact.manifold.points[1];
            contact.manifold.count = 1;
        } else if (contact.manifold.points[1].separation > 1.5 * linear_slop) {
            contact.manifold.count = 1;
        }
        point_count = contact.manifold.count;
    }

    contact.flags.sim_enable_hit_event =
        touching and (shape_a.enable_hit_events or shape_b.enable_hit_events);

    if (point_count > 0) {
        contact.manifold.rolling_impulse = old.rolling_impulse;
    }

    // Shift anchors to center-of-mass relative and warm-start by matching feature ids.
    {
        var i: usize = 0;
        while (i < point_count) : (i += 1) {
            var mp2: *ManifoldPoint = &contact.manifold.points[i];
            mp2.anchor_a = mp2.anchor_a - center_offset_a;
            mp2.anchor_b = mp2.anchor_b - center_offset_b;
            mp2.normal_impulse = 0.0;
            mp2.tangent_impulse = 0.0;
            mp2.total_normal_impulse = 0.0;
            mp2.normal_velocity = 0.0;
            mp2.persisted = false;

            const id2: u16 = mp2.id;
            var j: usize = 0;
            while (j < old.count) : (j += 1) {
                var mp1: *ManifoldPoint = &old.points[j];
                if (mp1.id == id2) {
                    mp2.normal_impulse = mp1.normal_impulse;
                    mp2.tangent_impulse = mp1.tangent_impulse;
                    mp2.persisted = true;
                    // Consume the old point so it cannot match a second new point.
                    mp1.normal_impulse = 0.0;
                    mp1.tangent_impulse = 0.0;
                    break;
                }
            }
        }
    }

    contact.flags.sim_touching = touching;
    return touching;
}

// ================================================================================
// Contact constraint solver - the heart (TGS-Soft, scalar / single-threaded)
//
// This is a direct port of Box2D's scalar "_Overflow" contact kernels, which ARE its
// single-threaded solver (the graph-coloring split only exists to run colors on
// separate threads). The solver works on flat constraint arrays plus the body
// side-tables: velocity lives in `Motion`, the TGS position deltas live in
// `BodyState`, and every velocity write-back is gated on `BodyState.flags.dynamic`
// so kinematic bodies keep their user-driven velocity and static bodies are inert.
//
// Anchor/separation contract (do not "simplify"): contact anchors are FIXED at prepare
// (COM-relative, world orientation) and are NOT re-rotated per sub-step; the current
// separation is recomputed each sub-step from the accumulated body deltas. Friction
// and rolling resistance are solved ONLY in the relax pass (useBias == false).
// box2d: contact_solver.c (Prepare:24, WarmStart:162, Solve:239, Restitution:410,
// Store:516) and the integration kernels in solver.c:66-160.
// ================================================================================

/// One solved contact point. Mirrors b2ContactConstraintPoint with explicit names.
const ContactConstraintPoint = struct {
    anchor_a: Vec2, // fixed, COM-relative (body A), world orientation
    anchor_b: Vec2, // fixed, COM-relative (body B), world orientation
    base_separation: f32, // separation minus the anchor offset along the normal
    relative_velocity: f32, // pre-solve normal velocity (for restitution)
    normal_impulse: f32,
    tangent_impulse: f32,
    total_normal_impulse: f32, // accumulated across sub-steps (+ restitution)
    normal_mass: f32, // effective mass along the normal
    tangent_mass: f32, // effective mass along the tangent
};

/// One solved contact. Mirrors b2ContactConstraint; references bodies by stable index.
const ContactConstraint = struct {
    body_a: BodyIndex,
    body_b: BodyIndex,
    points: [2]ContactConstraintPoint,
    normal: Vec2,
    inv_mass_a: f32,
    inv_mass_b: f32,
    inv_inertia_a: f32,
    inv_inertia_b: f32,
    friction: f32,
    restitution: f32,
    tangent_speed: f32,
    rolling_resistance: f32,
    rolling_mass: f32,
    rolling_impulse: f32,
    softness: Softness,
    count: u32,
    contact_id: u32, // index into world.contacts, for storing impulses back
};

/// Write a body's solved velocity back to its Motion, but only for dynamic bodies
/// (kinematic/static velocities are user-owned / zero). box2d: the `b2_dynamicFlag` gate.
inline fn writeBackVelocity(
    state: []const BodyState,
    motion: []Motion,
    index: BodyIndex,
    v: Vec2,
    w: f32,
) void {
    if (state[index].flags.dynamic) {
        motion[index].linear_velocity = v;
        motion[index].angular_velocity = w;
    }
}

/// Build the contact constraints for this step's touching contacts. Reads the
/// start-of-step velocities (from Motion) to capture the restitution reference, and
/// fixes the COM-relative anchors and effective masses that the sub-step loop reuses.
/// box2d: b2PrepareContacts_Overflow  contact_solver.c:24
fn prepareContacts(
    constraints: []ContactConstraint,
    touching_ids: []const u32,
    contacts: []const Contact,
    bodies: []const Body,
    motion: []const Motion,
    contact_softness: Softness,
    static_softness: Softness,
    enable_warm_starting: bool,
) void {
    // Either pass last step's impulses through (warm start) or start the solve cold.
    const warm_scale: f32 = if (enable_warm_starting) 1.0 else 0.0;

    for (touching_ids, 0..) |contact_id, constraint_index| {
        const contact: *const Contact = &contacts[contact_id];
        const manifold: *const Manifold = &contact.manifold;
        const point_count: u32 = manifold.count;
        assert(0 < point_count and point_count <= 2, @src());

        var constraint: *ContactConstraint = &constraints[constraint_index];
        constraint.body_a = contact.body_a;
        constraint.body_b = contact.body_b;
        constraint.contact_id = contact_id;
        constraint.normal = manifold.normal;
        constraint.friction = contact.friction;
        constraint.restitution = contact.restitution;
        constraint.rolling_resistance = contact.rolling_resistance;
        constraint.rolling_impulse = warm_scale * manifold.rolling_impulse;
        constraint.tangent_speed = contact.tangent_speed;
        constraint.count = point_count;

        // Stiffer softness when either body is immovable in the solve - i.e. not in the
        // awake set. box2d keys this on a null body-state index; the equivalent here is a
        // static body or a sleeping one (a sleeping neighbour is normally woken before
        // prepare, but this stays correct if one slips through). Kinematic bodies are awake
        // participants, so they use the regular contact softness.
        const a_immovable: bool = bodies[contact.body_a].motion_type == .static or bodies[contact.body_a].asleep;
        const b_immovable: bool = bodies[contact.body_b].motion_type == .static or bodies[contact.body_b].asleep;
        constraint.softness = if (a_immovable or b_immovable) static_softness else contact_softness;

        const motion_a: Motion = motion[contact.body_a];
        const motion_b: Motion = motion[contact.body_b];
        const inv_mass_a: f32 = motion_a.inverse_mass;
        const inv_mass_b: f32 = motion_b.inverse_mass;
        const inv_inertia_a: f32 = motion_a.inverse_inertia;
        const inv_inertia_b: f32 = motion_b.inverse_inertia;
        constraint.inv_mass_a = inv_mass_a;
        constraint.inv_mass_b = inv_mass_b;
        constraint.inv_inertia_a = inv_inertia_a;
        constraint.inv_inertia_b = inv_inertia_b;

        // Rolling resistance acts on the combined inverse rotational inertia.
        const inv_rolling_inertia: f32 = inv_inertia_a + inv_inertia_b;
        constraint.rolling_mass = if (inv_rolling_inertia > 0.0) 1.0 / inv_rolling_inertia else 0.0;

        const normal: Vec2 = constraint.normal;
        const tangent: Vec2 = rightPerp2(normal);

        const vel_a: Vec2 = motion_a.linear_velocity;
        const ang_vel_a: f32 = motion_a.angular_velocity;
        const vel_b: Vec2 = motion_b.linear_velocity;
        const ang_vel_b: f32 = motion_b.angular_velocity;

        var point_index: u32 = 0;
        while (point_index < point_count) : (point_index += 1) {
            const manifold_point: ManifoldPoint = manifold.points[point_index];
            var point: *ContactConstraintPoint = &constraint.points[point_index];
            point.normal_impulse = warm_scale * manifold_point.normal_impulse;
            point.tangent_impulse = warm_scale * manifold_point.tangent_impulse;
            point.total_normal_impulse = 0.0;

            const anchor_a: Vec2 = manifold_point.anchor_a;
            const anchor_b: Vec2 = manifold_point.anchor_b;
            point.anchor_a = anchor_a;
            point.anchor_b = anchor_b;
            // Separation with the anchor offset removed, so the sub-step can re-add the
            // current (rotated) offset cheaply. box2d folds the anchor delta out here too.
            point.base_separation = manifold_point.separation - dot2(anchor_b - anchor_a, normal);

            // Effective mass along the normal: 1 / (Jacobian * inverse-mass * Jacobian^T).
            const lever_normal_a: f32 = cross2(anchor_a, normal);
            const lever_normal_b: f32 = cross2(anchor_b, normal);
            const k_normal: f32 = inv_mass_a + inv_mass_b +
                inv_inertia_a * lever_normal_a * lever_normal_a +
                inv_inertia_b * lever_normal_b * lever_normal_b;
            point.normal_mass = if (k_normal > 0.0) 1.0 / k_normal else 0.0;

            // Effective mass along the tangent (friction direction).
            const lever_tangent_a: f32 = cross2(anchor_a, tangent);
            const lever_tangent_b: f32 = cross2(anchor_b, tangent);
            const k_tangent: f32 = inv_mass_a + inv_mass_b +
                inv_inertia_a * lever_tangent_a * lever_tangent_a +
                inv_inertia_b * lever_tangent_b * lever_tangent_b;
            point.tangent_mass = if (k_tangent > 0.0) 1.0 / k_tangent else 0.0;

            // Approach speed at the contact, kept as the restitution reference for later.
            const point_vel_a: Vec2 = vel_a + crossSV2(ang_vel_a, anchor_a);
            const point_vel_b: Vec2 = vel_b + crossSV2(ang_vel_b, anchor_b);
            point.relative_velocity = dot2(normal, point_vel_b - point_vel_a);
        }
    }
}

/// Re-apply the stored impulses at the start of each sub-step using the fixed anchors.
/// This "warm start" seeds the solve with last sub-step's solution so it converges in
/// far fewer iterations. box2d: b2WarmStartContacts_Overflow  contact_solver.c:162
fn warmStartContacts(
    constraints: []ContactConstraint,
    state: []const BodyState,
    motion: []Motion,
) void {
    for (constraints) |*constraint| {
        const inv_mass_a: f32 = constraint.inv_mass_a;
        const inv_inertia_a: f32 = constraint.inv_inertia_a;
        const inv_mass_b: f32 = constraint.inv_mass_b;
        const inv_inertia_b: f32 = constraint.inv_inertia_b;

        const normal: Vec2 = constraint.normal;
        const tangent: Vec2 = rightPerp2(normal);

        var vel_a: Vec2 = motion[constraint.body_a].linear_velocity;
        var ang_vel_a: f32 = motion[constraint.body_a].angular_velocity;
        var vel_b: Vec2 = motion[constraint.body_b].linear_velocity;
        var ang_vel_b: f32 = motion[constraint.body_b].angular_velocity;

        var point_index: u32 = 0;
        while (point_index < constraint.count) : (point_index += 1) {
            const point: *ContactConstraintPoint = &constraint.points[point_index];
            const anchor_a: Vec2 = point.anchor_a;
            const anchor_b: Vec2 = point.anchor_b;
            // Combined normal + tangent impulse applied as an equal/opposite pair.
            const impulse_vector: Vec2 =
                normal * splat2(point.normal_impulse) + tangent * splat2(point.tangent_impulse);
            point.total_normal_impulse += point.normal_impulse;
            ang_vel_a -= inv_inertia_a * cross2(anchor_a, impulse_vector);
            vel_a = mulSub2(vel_a, inv_mass_a, impulse_vector);
            ang_vel_b += inv_inertia_b * cross2(anchor_b, impulse_vector);
            vel_b = mulAdd2(vel_b, inv_mass_b, impulse_vector);
        }
        // Carry the rolling-resistance impulse through as well.
        ang_vel_a -= inv_inertia_a * constraint.rolling_impulse;
        ang_vel_b += inv_inertia_b * constraint.rolling_impulse;

        writeBackVelocity(state, motion, constraint.body_a, vel_a, ang_vel_a);
        writeBackVelocity(state, motion, constraint.body_b, vel_b, ang_vel_b);
    }
}

/// Solve every contact for one sub-step.
///
/// This is the heart of the TGS-Soft solver. It runs twice per sub-step: a *biased* pass
/// that pushes overlapping shapes apart with a soft (spring-like) bias, and a *relax* pass
/// that removes the energy that bias would otherwise inject. Friction and rolling resistance
/// run only in the relax pass. The non-penetration impulse is accumulated and clamped to be
/// non-negative (contacts can push, never pull), and the separation is recomputed each call
/// from the bodies' accumulated position/rotation deltas, with the anchors held fixed.
/// box2d: b2SolveContacts_Overflow  contact_solver.c:239
fn solveContacts(
    constraints: []ContactConstraint,
    state: []const BodyState,
    motion: []Motion,
    inv_h: f32,
    contact_push_speed: f32,
    use_bias: bool,
) void {
    for (constraints) |*constraint| {
        const inv_mass_a: f32 = constraint.inv_mass_a;
        const inv_inertia_a: f32 = constraint.inv_inertia_a;
        const inv_mass_b: f32 = constraint.inv_mass_b;
        const inv_inertia_b: f32 = constraint.inv_inertia_b;

        const state_a: BodyState = state[constraint.body_a];
        const state_b: BodyState = state[constraint.body_b];
        var vel_a: Vec2 = motion[constraint.body_a].linear_velocity;
        var ang_vel_a: f32 = motion[constraint.body_a].angular_velocity;
        var vel_b: Vec2 = motion[constraint.body_b].linear_velocity;
        var ang_vel_b: f32 = motion[constraint.body_b].angular_velocity;

        // How far body B's center has drifted relative to body A's since the step began.
        const relative_drift: Vec2 = state_b.delta_position - state_a.delta_position;
        const normal: Vec2 = constraint.normal;
        const tangent: Vec2 = rightPerp2(normal); // friction direction
        const softness: Softness = constraint.softness;

        // Sum of the (clamped) normal impulses at both points; caps rolling resistance.
        var total_normal_impulse: f32 = 0.0;

        // -- Non-penetration (runs in both the biased and relax passes) --------------
        var point_index: u32 = 0;
        while (point_index < constraint.count) : (point_index += 1) {
            const point: *ContactConstraintPoint = &constraint.points[point_index];
            const anchor_a: Vec2 = point.anchor_a;
            const anchor_b: Vec2 = point.anchor_b;

            // Current separation: take the fixed anchors, rotate them by each body's
            // accumulated delta-rotation, and project the total relative motion onto the
            // normal. base_separation already folded in the start-of-step anchor offset.
            const rotated_anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, anchor_a);
            const rotated_anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, anchor_b);
            const separation_delta: Vec2 = relative_drift + (rotated_anchor_b - rotated_anchor_a);
            const separation: f32 = point.base_separation + dot2(separation_delta, normal);

            // Choose the target normal speed and the soft-constraint scaling. A positive
            // separation is a speculative (not-yet-touching) contact: aim to close the gap
            // by exactly `separation` over the sub-step but never to pull the shapes
            // together. A negative separation is real overlap: in the biased pass apply the
            // soft push (clamped to the max push speed), in the relax pass apply none.
            var velocity_bias: f32 = 0.0;
            var mass_scale: f32 = 1.0;
            var impulse_scale: f32 = 0.0;
            if (separation > 0.0) {
                velocity_bias = separation * inv_h;
            } else if (use_bias) {
                const soft_push: f32 = softness.mass_scale * softness.bias_rate * separation;
                velocity_bias = @max(soft_push, -contact_push_speed);
                mass_scale = softness.mass_scale;
                impulse_scale = softness.impulse_scale;
            }

            // Relative normal speed at the contact point (B approaching A is negative).
            const point_vel_a: Vec2 = vel_a + crossSV2(ang_vel_a, anchor_a);
            const point_vel_b: Vec2 = vel_b + crossSV2(ang_vel_b, anchor_b);
            const normal_speed: f32 = dot2(point_vel_b - point_vel_a, normal);

            // Soft impulse: drive the normal speed to -velocity_bias, scaled by the
            // softness, minus the impulse-scale leak that keeps the soft spring stable.
            const target: f32 = mass_scale * normal_speed + velocity_bias;
            const raw_impulse: f32 = -point.normal_mass * target - impulse_scale * point.normal_impulse;
            const clamped_impulse: f32 = @max(point.normal_impulse + raw_impulse, 0.0);
            const applied_impulse: f32 = clamped_impulse - point.normal_impulse;
            point.normal_impulse = clamped_impulse;
            point.total_normal_impulse += applied_impulse;
            total_normal_impulse += clamped_impulse;

            const impulse_vector: Vec2 = normal * splat2(applied_impulse);
            vel_a = mulSub2(vel_a, inv_mass_a, impulse_vector);
            ang_vel_a -= inv_inertia_a * cross2(anchor_a, impulse_vector);
            vel_b = mulAdd2(vel_b, inv_mass_b, impulse_vector);
            ang_vel_b += inv_inertia_b * cross2(anchor_b, impulse_vector);
        }

        // -- Friction + rolling resistance (relax pass only) -------------------------
        if (use_bias == false) {
            point_index = 0;
            while (point_index < constraint.count) : (point_index += 1) {
                const point: *ContactConstraintPoint = &constraint.points[point_index];
                const anchor_a: Vec2 = point.anchor_a;
                const anchor_b: Vec2 = point.anchor_b;

                // Tangential sliding speed, less any conveyor-belt surface speed.
                const point_vel_b: Vec2 = vel_b + crossSV2(ang_vel_b, anchor_b);
                const point_vel_a: Vec2 = vel_a + crossSV2(ang_vel_a, anchor_a);
                const slip_speed: f32 = dot2(point_vel_b - point_vel_a, tangent) - constraint.tangent_speed;

                // Coulomb friction: oppose the slide, but cap the accumulated tangent
                // impulse at friction * normal_impulse (the friction cone).
                const raw_impulse: f32 = point.tangent_mass * (-slip_speed);
                const max_friction: f32 = constraint.friction * point.normal_impulse;
                const clamped_impulse: f32 =
                    clamp(point.tangent_impulse + raw_impulse, -max_friction, max_friction);
                const applied_impulse: f32 = clamped_impulse - point.tangent_impulse;
                point.tangent_impulse = clamped_impulse;

                const impulse_vector: Vec2 = tangent * splat2(applied_impulse);
                vel_a = mulSub2(vel_a, inv_mass_a, impulse_vector);
                ang_vel_a -= inv_inertia_a * cross2(anchor_a, impulse_vector);
                vel_b = mulAdd2(vel_b, inv_mass_b, impulse_vector);
                ang_vel_b += inv_inertia_b * cross2(anchor_b, impulse_vector);
            }

            // Rolling resistance opposes the relative spin, capped by rolling_resistance
            // times the accumulated normal impulse (a torsional analogue of friction).
            const old_rolling_impulse: f32 = constraint.rolling_impulse;
            const rolling_target: f32 = -constraint.rolling_mass * (ang_vel_b - ang_vel_a);
            const max_rolling: f32 = constraint.rolling_resistance * total_normal_impulse;
            constraint.rolling_impulse =
                clamp(old_rolling_impulse + rolling_target, -max_rolling, max_rolling);
            const applied_rolling: f32 = constraint.rolling_impulse - old_rolling_impulse;
            ang_vel_a -= inv_inertia_a * applied_rolling;
            ang_vel_b += inv_inertia_b * applied_rolling;
        }

        writeBackVelocity(state, motion, constraint.body_a, vel_a, ang_vel_a);
        writeBackVelocity(state, motion, constraint.body_b, vel_b, ang_vel_b);
    }
}

/// Apply restitution (bounce) once, after the sub-step loop. For each point that was
/// approaching fast enough and actually developed a normal impulse, add just enough extra
/// normal impulse to reflect the approach speed scaled by the restitution coefficient.
/// Points that were merely speculative (no impulse) or barely touching are skipped so
/// resting stacks don't jitter. box2d: b2ApplyRestitution_Overflow  contact_solver.c:410
fn applyRestitution(
    constraints: []ContactConstraint,
    state: []const BodyState,
    motion: []Motion,
    threshold: f32,
) void {
    for (constraints) |*constraint| {
        const restitution: f32 = constraint.restitution;
        if (restitution == 0.0) {
            continue;
        }

        const inv_mass_a: f32 = constraint.inv_mass_a;
        const inv_inertia_a: f32 = constraint.inv_inertia_a;
        const inv_mass_b: f32 = constraint.inv_mass_b;
        const inv_inertia_b: f32 = constraint.inv_inertia_b;

        var vel_a: Vec2 = motion[constraint.body_a].linear_velocity;
        var ang_vel_a: f32 = motion[constraint.body_a].angular_velocity;
        var vel_b: Vec2 = motion[constraint.body_b].linear_velocity;
        var ang_vel_b: f32 = motion[constraint.body_b].angular_velocity;

        const normal: Vec2 = constraint.normal;

        var point_index: u32 = 0;
        while (point_index < constraint.count) : (point_index += 1) {
            const point: *ContactConstraintPoint = &constraint.points[point_index];
            // relative_velocity is the (negative) approach speed captured in prepare.
            const approaching_too_slowly: bool = point.relative_velocity > -threshold;
            const never_touched: bool = point.total_normal_impulse == 0.0;
            if (approaching_too_slowly or never_touched) {
                continue;
            }

            const anchor_a: Vec2 = point.anchor_a;
            const anchor_b: Vec2 = point.anchor_b;
            const point_vel_b: Vec2 = vel_b + crossSV2(ang_vel_b, anchor_b);
            const point_vel_a: Vec2 = vel_a + crossSV2(ang_vel_a, anchor_a);
            const normal_speed: f32 = dot2(point_vel_b - point_vel_a, normal);

            // Target post-bounce speed is -restitution * approach_speed.
            const target: f32 = normal_speed + restitution * point.relative_velocity;
            const raw_impulse: f32 = -point.normal_mass * target;
            const clamped_impulse: f32 = @max(point.normal_impulse + raw_impulse, 0.0);
            const applied_impulse: f32 = clamped_impulse - point.normal_impulse;
            point.normal_impulse = clamped_impulse;
            point.total_normal_impulse += applied_impulse;

            const impulse_vector: Vec2 = normal * splat2(applied_impulse);
            vel_a = mulSub2(vel_a, inv_mass_a, impulse_vector);
            ang_vel_a -= inv_inertia_a * cross2(anchor_a, impulse_vector);
            vel_b = mulAdd2(vel_b, inv_mass_b, impulse_vector);
            ang_vel_b += inv_inertia_b * cross2(anchor_b, impulse_vector);
        }

        writeBackVelocity(state, motion, constraint.body_a, vel_a, ang_vel_a);
        writeBackVelocity(state, motion, constraint.body_b, vel_b, ang_vel_b);
    }
}

/// Copy the solved impulses back into each contact's persistent manifold so the next
/// step can warm-start from them. box2d: b2StoreImpulses_Overflow  contact_solver.c:516
fn storeImpulses(constraints: []const ContactConstraint, contacts: []Contact) void {
    for (constraints) |*constraint| {
        var manifold: *Manifold = &contacts[constraint.contact_id].manifold;
        var point_index: u32 = 0;
        while (point_index < constraint.count) : (point_index += 1) {
            const point: ContactConstraintPoint = constraint.points[point_index];
            manifold.points[point_index].normal_impulse = point.normal_impulse;
            manifold.points[point_index].tangent_impulse = point.tangent_impulse;
            manifold.points[point_index].total_normal_impulse = point.total_normal_impulse;
            manifold.points[point_index].normal_velocity = point.relative_velocity;
        }
        manifold.rolling_impulse = constraint.rolling_impulse;
    }
}

// -- Body integration kernels (driven by the sub-step loop) ----------------------

/// Integrate velocities for one sub-step: apply gravity and the accumulated force/torque,
/// then apply implicit (Pade) damping. Implicit damping multiplies the velocity by
/// 1/(1 + h*c) rather than (1 - h*c), which stays stable for any damping coefficient c.
/// box2d: b2IntegrateVelocitiesTask  solver.c:66
fn integrateVelocities(
    active: []const BodyIndex,
    motion: []Motion,
    gravity: Vec2,
    h: f32,
) void {
    for (active) |index| {
        var body_motion: *Motion = &motion[index];
        const linear_damping_factor: f32 = 1.0 / (1.0 + h * body_motion.linear_damping);
        const angular_damping_factor: f32 = 1.0 / (1.0 + h * body_motion.angular_damping);
        // Kinematic bodies have inverse_mass 0, so gravity must not act on them.
        const gravity_scale: f32 = if (body_motion.inverse_mass > 0.0) body_motion.gravity_scale else 0.0;

        // dv = h*(F/m + gravity_scale*g); torque term is h*(tau/I).
        const linear_delta: Vec2 = body_motion.force * splat2(h * body_motion.inverse_mass) +
            gravity * splat2(h * gravity_scale);
        const angular_delta: f32 = h * body_motion.inverse_inertia * body_motion.torque;

        body_motion.linear_velocity =
            mulAdd2(linear_delta, linear_damping_factor, body_motion.linear_velocity);
        body_motion.angular_velocity = angular_delta + angular_damping_factor * body_motion.angular_velocity;
    }
}

/// Integrate the (already-solved) velocities into this step's accumulated position and
/// rotation deltas, applying the per-axis motion locks and the speed clamps that keep the
/// small-angle rotation integrator valid. box2d: b2IntegratePositionsTask  solver.c:114
fn integratePositions(
    active: []const BodyIndex,
    motion: []Motion,
    state: []BodyState,
    h: f32,
    max_linear_speed: f32,
    inv_dt: f32,
) void {
    const max_angular_speed: f32 = max_rotation * inv_dt;
    const max_linear_speed_sq: f32 = max_linear_speed * max_linear_speed;
    const max_angular_speed_sq: f32 = max_angular_speed * max_angular_speed;

    for (active) |index| {
        var body_motion: *Motion = &motion[index];
        var body_state: *BodyState = &state[index];
        var velocity: Vec2 = body_motion.linear_velocity;
        var angular_velocity: f32 = body_motion.angular_velocity;

        // Motion locks behave like a final hard constraint on each axis.
        if (body_state.flags.lock_x) {
            velocity[0] = 0.0;
        }
        if (body_state.flags.lock_y) {
            velocity[1] = 0.0;
        }
        if (body_state.flags.lock_w) {
            angular_velocity = 0.0;
        }

        // Clamp runaway speeds so a single sub-step can't move a body more than the
        // solver and the small-angle rotation update can cope with.
        if (dot2(velocity, velocity) > max_linear_speed_sq) {
            velocity = velocity * splat2(max_linear_speed / length2(velocity));
            body_state.flags.is_speed_capped = true;
        }
        const spins_too_fast: bool = angular_velocity * angular_velocity > max_angular_speed_sq;
        if (spins_too_fast and body_state.flags.allow_fast_rotation == false) {
            angular_velocity *= max_angular_speed / @abs(angular_velocity);
            body_state.flags.is_speed_capped = true;
        }

        body_motion.linear_velocity = velocity;
        body_motion.angular_velocity = angular_velocity;
        body_state.delta_position = mulAdd2(body_state.delta_position, h, velocity);
        body_state.delta_rotation = integrateRot2(body_state.delta_rotation, h * angular_velocity);
    }
}

// ================================================================================
// Joints - the articulated-constraint family
//
// Each joint constrains two bodies through a pair of LOCAL frames (one per body).
// At prepare the frames are baked into world orientation relative to each body's
// center of mass; then - unlike contacts, whose anchors stay fixed - joint anchors
// are RE-ROTATED by the per-substep body delta rotations so the constraint tracks the
// bodies as they turn. The same TGS-Soft machinery applies: a biased pass that pushes
// out position error softly, and relax passes (use_bias == false) that only kill
// velocity. Static bodies present the identity BodyState + zero inverse mass, so no
// null-index special-casing is needed; velocity write-back is gated on the dynamic flag.
//
// All seven joint kinds live in this section: revolute, distance, weld, motor,
// prismatic, wheel, and the collision-filter joint (which only disables collision
// between its two bodies). The per-joint solve order follows Box2D's canonical
// sequence: spring -> motor -> limit -> equality constraint.
//
// Shared solver vocabulary used throughout (the same in every joint):
//   c           the constraint value - the current position/angle error to remove.
//   c_dot       its time derivative - the relative velocity in constraint space.
//   bias        c scaled by the soft-constraint bias_rate (only in the biased pass);
//               for one-sided limits a positive c instead biases speculatively at inv_h.
//   mass_scale  / impulse_scale  the soft-constraint gains from `makeSoft`; together they
//               turn a hard constraint into a damped spring (see Softness).
//   axial_arm / perp_arm   moment arms: cross(anchor, axis) for an axis-aligned constraint,
//               i.e. how much a unit impulse along the axis changes each body's spin.
//   The applied impulse is always accumulated, then clamped (to a motor/limit/friction
//               bound), and only the delta is applied - the standard sequential-impulse form.
// box2d: joint.c + {revolute,distance,weld,motor,prismatic,wheel}_joint.c
// ================================================================================

/// The seven joint kinds. box2d: b2JointType  types.h:567
pub const JointType = enum(u8) {
    distance,
    filter, // disables collision between two bodies without constraining them
    motor,
    prismatic,
    pulley,
    revolute,
    weld,
    wheel,
};

/// One end of a joint's intrusive list on a body (key = jointId << 1 | edgeIndex).
/// box2d: b2JointEdge  joint.h
const JointEdge = struct {
    prev_key: u32 = null_index,
    next_key: u32 = null_index,
};

/// A pin joint: holds two anchor points coincident, with an optional angular spring,
/// motor, and angle limits. box2d: b2RevoluteJoint  joint.h
const RevoluteJoint = struct {
    // Configuration.
    hertz: f32 = 0,
    damping_ratio: f32 = 0,
    target_angle: f32 = 0,
    max_motor_torque: f32 = 0,
    motor_speed: f32 = 0,
    lower_angle: f32 = 0,
    upper_angle: f32 = 0,
    enable_spring: bool = false,
    enable_motor: bool = false,
    enable_limit: bool = false,
    // Accumulated impulses (warm-started across steps).
    linear_impulse: Vec2 = .{ 0, 0 },
    spring_impulse: f32 = 0,
    motor_impulse: f32 = 0,
    lower_impulse: f32 = 0,
    upper_impulse: f32 = 0,
    // Prepared each step.
    frame_a: Transform2 = Transform2.identity,
    frame_b: Transform2 = Transform2.identity,
    delta_center: Vec2 = .{ 0, 0 }, // worldCenterB - worldCenterA at prepare
    axial_mass: f32 = 0,
    spring_softness: Softness = .{},
};

/// A spring/rod between two anchor points: rigid by default, or a soft spring with
/// optional length limits and a linear motor. box2d: b2DistanceJoint  joint.h
const DistanceJoint = struct {
    length: f32 = 0,
    min_length: f32 = 0,
    max_length: f32 = 0,
    hertz: f32 = 0,
    damping_ratio: f32 = 0,
    lower_spring_force: f32 = -floatMax(f32),
    upper_spring_force: f32 = floatMax(f32),
    max_motor_force: f32 = 0,
    motor_speed: f32 = 0,
    enable_spring: bool = false,
    enable_limit: bool = false,
    enable_motor: bool = false,
    impulse: f32 = 0,
    lower_impulse: f32 = 0,
    upper_impulse: f32 = 0,
    motor_impulse: f32 = 0,
    anchor_a: Vec2 = .{ 0, 0 }, // COM-relative, world orientation (prepared)
    anchor_b: Vec2 = .{ 0, 0 },
    delta_center: Vec2 = .{ 0, 0 },
    axial_mass: f32 = 0,
    spring_softness: Softness = .{},
};

/// A rigid lock between two frames: holds both relative position and relative angle,
/// each optionally softened by its own spring. box2d: b2WeldJoint  joint.h
const WeldJoint = struct {
    linear_hertz: f32 = 0,
    linear_damping_ratio: f32 = 0,
    angular_hertz: f32 = 0,
    angular_damping_ratio: f32 = 0,
    linear_impulse: Vec2 = .{ 0, 0 },
    angular_impulse: f32 = 0,
    frame_a: Transform2 = Transform2.identity,
    frame_b: Transform2 = Transform2.identity,
    delta_center: Vec2 = .{ 0, 0 },
    axial_mass: f32 = 0,
    linear_spring: Softness = .{},
    angular_spring: Softness = .{},
};

/// A direct velocity drive between two bodies (used to push a body toward a target
/// pose/velocity), with optional soft springs. Unlike the others it has no bias pass:
/// it is a pure soft/velocity actuator. box2d: b2MotorJoint  joint.h
const MotorJoint = struct {
    linear_velocity: Vec2 = .{ 0, 0 }, // target relative linear velocity
    angular_velocity: f32 = 0, // target relative angular velocity
    max_velocity_force: f32 = 0,
    max_velocity_torque: f32 = 0,
    linear_hertz: f32 = 0,
    linear_damping_ratio: f32 = 0,
    max_spring_force: f32 = 0,
    angular_hertz: f32 = 0,
    angular_damping_ratio: f32 = 0,
    max_spring_torque: f32 = 0,
    linear_velocity_impulse: Vec2 = .{ 0, 0 },
    angular_velocity_impulse: f32 = 0,
    linear_spring_impulse: Vec2 = .{ 0, 0 },
    angular_spring_impulse: f32 = 0,
    frame_a: Transform2 = Transform2.identity,
    frame_b: Transform2 = Transform2.identity,
    delta_center: Vec2 = .{ 0, 0 },
    linear_mass: Mat22 = Mat22.zero, // inverse of the linear 2x2 effective mass
    angular_mass: f32 = 0,
    linear_spring: Softness = .{},
    angular_spring: Softness = .{},
};

/// A sliding joint: B may translate along an axis fixed in A and is otherwise locked,
/// with an optional spring, motor, and translation limits along that axis.
/// box2d: b2PrismaticJoint  joint.h
const PrismaticJoint = struct {
    hertz: f32 = 0,
    damping_ratio: f32 = 0,
    target_translation: f32 = 0,
    max_motor_force: f32 = 0,
    motor_speed: f32 = 0,
    lower_translation: f32 = 0,
    upper_translation: f32 = 0,
    enable_spring: bool = false,
    enable_limit: bool = false,
    enable_motor: bool = false,
    impulse: Vec2 = .{ 0, 0 }, // (perpendicular, angle) block impulse
    spring_impulse: f32 = 0,
    motor_impulse: f32 = 0,
    lower_impulse: f32 = 0,
    upper_impulse: f32 = 0,
    frame_a: Transform2 = Transform2.identity,
    frame_b: Transform2 = Transform2.identity,
    delta_center: Vec2 = .{ 0, 0 },
    spring_softness: Softness = .{},
};

/// A wheel/suspension joint: B may translate along an axis in A (sprung) and rotate
/// freely about the anchor, kept on the axis line by a perpendicular constraint, with
/// an optional angular motor and translation limits. box2d: b2WheelJoint  joint.h
const WheelJoint = struct {
    hertz: f32 = 0,
    damping_ratio: f32 = 0,
    max_motor_torque: f32 = 0,
    motor_speed: f32 = 0,
    lower_translation: f32 = 0,
    upper_translation: f32 = 0,
    enable_spring: bool = false,
    enable_motor: bool = false,
    enable_limit: bool = false,
    perp_impulse: f32 = 0,
    motor_impulse: f32 = 0,
    spring_impulse: f32 = 0,
    lower_impulse: f32 = 0,
    upper_impulse: f32 = 0,
    frame_a: Transform2 = Transform2.identity,
    frame_b: Transform2 = Transform2.identity,
    delta_center: Vec2 = .{ 0, 0 },
    perp_mass: f32 = 0,
    motor_mass: f32 = 0,
    axial_mass: f32 = 0,
    spring_softness: Softness = .{},
};

/// A pulley: two bodies are linked by an inextensible rope that runs over two fixed ground
/// anchors, so `lengthA + ratio*lengthB` stays constant - raising one side lowers the other.
/// The rest lengths and the constant are captured lazily on the first solver prepare from the
/// bodies' initial anchor positions. box2d v2: b2PulleyJoint (dropped in box2d v3, reintroduced).
const PulleyJoint = struct {
    // Configuration.
    ground_anchor_a: Vec2 = .{ 0, 0 }, // world-space fixed anchor for side A
    ground_anchor_b: Vec2 = .{ 0, 0 },
    ratio: f32 = 1,
    constant: f32 = -1, // length_a + ratio*length_b; <0 means "not yet captured"
    // Prepared.
    anchor_a: Vec2 = .{ 0, 0 }, // body anchor relative to COM, world orientation (rA)
    anchor_b: Vec2 = .{ 0, 0 },
    s_a0: Vec2 = .{ 0, 0 }, // (anchorA_world - ground_anchor_a) at prepare time
    s_b0: Vec2 = .{ 0, 0 },
    u_a: Vec2 = .{ 0, 0 }, // prepared unit rope direction A
    u_b: Vec2 = .{ 0, 0 },
    mass: f32 = 0, // effective axial mass
    impulse: f32 = 0,
};

/// The per-type solver payload, tagged by joint kind. box2d: the union in b2JointSim.
pub const JointData = union(JointType) {
    distance: DistanceJoint,
    filter: void,
    motor: MotorJoint,
    prismatic: PrismaticJoint,
    pulley: PulleyJoint,
    revolute: RevoluteJoint,
    weld: WeldJoint,
    wheel: WheelJoint,
};

/// A joint between two bodies. Merges Box2D's b2Joint (metadata + edges) and
/// b2JointSim (solver data) since we dropped the solver-set machinery. The joint id
/// is its index in `world.joints`.
pub const Joint = struct {
    body_a: BodyIndex,
    body_b: BodyIndex,
    local_frame_a: Transform2, // joint frame in body A's local space
    local_frame_b: Transform2, // joint frame in body B's local space
    inv_mass_a: f32 = 0, // copied from Motion at prepare
    inv_mass_b: f32 = 0,
    inv_inertia_a: f32 = 0,
    inv_inertia_b: f32 = 0,
    constraint_hertz: f32 = 60, // stiffness of the rigid (non-spring) parts
    constraint_damping_ratio: f32 = 2,
    constraint_softness: Softness = .{},
    force_threshold: f32 = floatMax(f32), // for joint-event reporting
    torque_threshold: f32 = floatMax(f32),
    collide_connected: bool = false,
    edge_a: JointEdge = .{},
    edge_b: JointEdge = .{},
    user_data: u64 = 0,
    local_index: u32 = null_index, // position in world.joint_ids (dense live list)
    data: JointData,
};

/// The world frames and center delta a joint needs at prepare, plus the side effect of
/// copying the two bodies' inverse masses onto the joint. The frame is the joint's
/// local frame expressed in world orientation, anchored at the body's center of mass:
/// frame.p = rot(bodyRotation, localFrame.p - localCenter). Consolidates the identical
/// preamble Box2D repeats in every per-type prepare.
const PreparedFrames = struct {
    frame_a: Transform2,
    frame_b: Transform2,
    delta_center: Vec2,
};

fn computeJointFrames(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
) PreparedFrames {
    const body_a: *const Body = &bodies[joint.body_a];
    const body_b: *const Body = &bodies[joint.body_b];
    joint.inv_mass_a = motion[joint.body_a].inverse_mass;
    joint.inv_mass_b = motion[joint.body_b].inverse_mass;
    joint.inv_inertia_a = motion[joint.body_a].inverse_inertia;
    joint.inv_inertia_b = motion[joint.body_b].inverse_inertia;

    const frame_a: Transform2 = .{
        .q = mulRot2(body_a.transform.q, joint.local_frame_a.q),
        .p = rotateVec2(body_a.transform.q, joint.local_frame_a.p - body_a.local_center),
    };
    const frame_b: Transform2 = .{
        .q = mulRot2(body_b.transform.q, joint.local_frame_b.q),
        .p = rotateVec2(body_b.transform.q, joint.local_frame_b.p - body_b.local_center),
    };
    return .{ .frame_a = frame_a, .frame_b = frame_b, .delta_center = body_b.center - body_a.center };
}

/// The 2x2 effective-mass matrix for a point-to-point (linear) velocity constraint
/// with anchors `ra`/`rb`. Shared by the revolute point constraint and the weld linear
/// constraint. box2d: the inline K assembly in revolute_joint.c:474 / weld_joint.c
fn pointToPointMatrix(
    inv_mass_a: f32,
    inv_mass_b: f32,
    inv_inertia_a: f32,
    inv_inertia_b: f32,
    ra: Vec2,
    rb: Vec2,
) Mat22 {
    const m_sum: f32 = inv_mass_a + inv_mass_b;
    const k11: f32 = m_sum + ra[1] * ra[1] * inv_inertia_a + rb[1] * rb[1] * inv_inertia_b;
    const k12: f32 = -ra[1] * ra[0] * inv_inertia_a - rb[1] * rb[0] * inv_inertia_b;
    const k22: f32 = m_sum + ra[0] * ra[0] * inv_inertia_a + rb[0] * rb[0] * inv_inertia_b;
    return .{ .cx = .{ k11, k12 }, .cy = .{ k12, k22 } };
}

// -- Dispatch --------------------------------------------------------------------

/// Set up a joint's per-step constraint state. box2d: b2PrepareJoint  joint.c:1301
pub fn prepareJoint(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
    h: f32,
    inv_h: f32,
    enable_warm_starting: bool,
) void {
    const hertz: f32 = @min(joint.constraint_hertz, 0.25 * inv_h);
    joint.constraint_softness = makeSoft(hertz, joint.constraint_damping_ratio, h);
    switch (joint.data) {
        .distance => prepareDistanceJoint(joint, bodies, motion, h, enable_warm_starting),
        .motor => prepareMotorJoint(joint, bodies, motion, h, enable_warm_starting),
        .prismatic => preparePrismaticJoint(joint, bodies, motion, h, enable_warm_starting),
        .pulley => preparePulleyJoint(joint, bodies, motion, enable_warm_starting),
        .revolute => prepareRevoluteJoint(joint, bodies, motion, h, enable_warm_starting),
        .weld => prepareWeldJoint(joint, bodies, motion, h, enable_warm_starting),
        .wheel => prepareWheelJoint(joint, bodies, motion, h, enable_warm_starting),
        .filter => {},
    }
}

/// Re-apply each joint's stored impulses at the start of a sub-step.
/// box2d: b2WarmStartJoint  joint.c:1341
pub fn warmStartJoint(joint: *Joint, state: []const BodyState, motion: []Motion) void {
    switch (joint.data) {
        .distance => warmStartDistanceJoint(joint, state, motion),
        .motor => warmStartMotorJoint(joint, state, motion),
        .prismatic => warmStartPrismaticJoint(joint, state, motion),
        .pulley => warmStartPulleyJoint(joint, state, motion),
        .revolute => warmStartRevoluteJoint(joint, state, motion),
        .weld => warmStartWeldJoint(joint, state, motion),
        .wheel => warmStartWheelJoint(joint, state, motion),
        .filter => {},
    }
}

/// Solve a joint for one sub-step. box2d: b2SolveJoint  joint.c:1377
pub fn solveJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
    h: f32,
    inv_h: f32,
    use_bias: bool,
) void {
    switch (joint.data) {
        .distance => solveDistanceJoint(joint, state, motion, h, inv_h, use_bias),
        .motor => solveMotorJoint(joint, state, motion, h),
        .prismatic => solvePrismaticJoint(joint, state, motion, h, inv_h, use_bias),
        .pulley => solvePulleyJoint(joint, state, motion, use_bias),
        .revolute => solveRevoluteJoint(joint, state, motion, h, inv_h, use_bias),
        .weld => solveWeldJoint(joint, state, motion, use_bias),
        .wheel => solveWheelJoint(joint, state, motion, h, inv_h, use_bias),
        .filter => {},
    }
}

// -- Revolute joint --------------------------------------------------------------

fn prepareRevoluteJoint(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
    h: f32,
    enable_warm_starting: bool,
) void {
    const frames: PreparedFrames = computeJointFrames(joint, bodies, motion);
    const revolute: *RevoluteJoint = &joint.data.revolute;
    revolute.frame_a = frames.frame_a;
    revolute.frame_b = frames.frame_b;
    revolute.delta_center = frames.delta_center;

    const k: f32 = joint.inv_inertia_a + joint.inv_inertia_b;
    revolute.axial_mass = if (k > 0.0) 1.0 / k else 0.0;
    revolute.spring_softness = makeSoft(revolute.hertz, revolute.damping_ratio, h);

    if (enable_warm_starting == false) {
        revolute.linear_impulse = .{ 0, 0 };
        revolute.spring_impulse = 0;
        revolute.motor_impulse = 0;
        revolute.lower_impulse = 0;
        revolute.upper_impulse = 0;
    }
}

fn warmStartRevoluteJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const revolute: *const RevoluteJoint = &joint.data.revolute;

    const anchor_a: Vec2 = rotateVec2(state[joint.body_a].delta_rotation, revolute.frame_a.p);
    const anchor_b: Vec2 = rotateVec2(state[joint.body_b].delta_rotation, revolute.frame_b.p);
    const axial_impulse: f32 =
        revolute.spring_impulse + revolute.motor_impulse + revolute.lower_impulse - revolute.upper_impulse;

    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;

    vel_a = mulSub2(vel_a, inv_mass_a, revolute.linear_impulse);
    ang_vel_a -= inv_inertia_a * (cross2(anchor_a, revolute.linear_impulse) + axial_impulse);
    vel_b = mulAdd2(vel_b, inv_mass_b, revolute.linear_impulse);
    ang_vel_b += inv_inertia_b * (cross2(anchor_b, revolute.linear_impulse) + axial_impulse);

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

fn solveRevoluteJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
    h: f32,
    inv_h: f32,
    use_bias: bool,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const revolute: *RevoluteJoint = &joint.data.revolute;

    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];
    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;

    // The joint frames in world orientation, advanced by this sub-step's delta rotations.
    // The relative rotation between them is what the angular spring/motor/limit act on.
    const world_q_a: Rot2 = mulRot2(state_a.delta_rotation, revolute.frame_a.q);
    const world_q_b: Rot2 = mulRot2(state_b.delta_rotation, revolute.frame_b.q);
    const relative_q: Rot2 = invMulRot2(world_q_a, world_q_b);
    const fixed_rotation: bool = (inv_inertia_a + inv_inertia_b == 0.0);

    // Angular spring drives the relative angle toward the target angle.
    if (revolute.enable_spring and fixed_rotation == false) {
        const joint_angle: f32 = relative_q.angle();
        const angle_error: f32 = unwindAngle(joint_angle - revolute.target_angle);
        const bias: f32 = revolute.spring_softness.bias_rate * angle_error;
        const mass_scale: f32 = revolute.spring_softness.mass_scale;
        const impulse_scale: f32 = revolute.spring_softness.impulse_scale;
        const c_dot: f32 = ang_vel_b - ang_vel_a;
        const impulse: f32 =
            -mass_scale * revolute.axial_mass * (c_dot + bias) - impulse_scale * revolute.spring_impulse;
        revolute.spring_impulse += impulse;
        ang_vel_a -= inv_inertia_a * impulse;
        ang_vel_b += inv_inertia_b * impulse;
    }

    // Angular motor drives the relative angular velocity toward the motor speed.
    if (revolute.enable_motor and fixed_rotation == false) {
        const c_dot: f32 = ang_vel_b - ang_vel_a - revolute.motor_speed;
        var impulse: f32 = -revolute.axial_mass * c_dot;
        const old_impulse: f32 = revolute.motor_impulse;
        const max_impulse: f32 = h * revolute.max_motor_torque;
        revolute.motor_impulse = clamp(revolute.motor_impulse + impulse, -max_impulse, max_impulse);
        impulse = revolute.motor_impulse - old_impulse;
        ang_vel_a -= inv_inertia_a * impulse;
        ang_vel_b += inv_inertia_b * impulse;
    }

    // Angle limits (one-sided constraints with speculation).
    if (revolute.enable_limit and fixed_rotation == false) {
        const joint_angle: f32 = relative_q.angle();

        // Lower limit: keep jointAngle >= lowerAngle.
        {
            const limit_error: f32 = joint_angle - revolute.lower_angle;
            var bias: f32 = 0.0;
            var mass_scale: f32 = 1.0;
            var impulse_scale: f32 = 0.0;
            if (limit_error > 0.0) {
                bias = limit_error * inv_h; // speculative
            } else if (use_bias) {
                bias = joint.constraint_softness.bias_rate * limit_error;
                mass_scale = joint.constraint_softness.mass_scale;
                impulse_scale = joint.constraint_softness.impulse_scale;
            }
            const c_dot: f32 = ang_vel_b - ang_vel_a;
            const old_impulse: f32 = revolute.lower_impulse;
            var impulse: f32 =
                -mass_scale * revolute.axial_mass * (c_dot + bias) - impulse_scale * old_impulse;
            revolute.lower_impulse = @max(old_impulse + impulse, 0.0);
            impulse = revolute.lower_impulse - old_impulse;
            ang_vel_a -= inv_inertia_a * impulse;
            ang_vel_b += inv_inertia_b * impulse;
        }

        // Upper limit: signs flipped so C stays positive when satisfied.
        {
            const limit_error: f32 = revolute.upper_angle - joint_angle;
            var bias: f32 = 0.0;
            var mass_scale: f32 = 1.0;
            var impulse_scale: f32 = 0.0;
            if (limit_error > 0.0) {
                bias = limit_error * inv_h;
            } else if (use_bias) {
                bias = joint.constraint_softness.bias_rate * limit_error;
                mass_scale = joint.constraint_softness.mass_scale;
                impulse_scale = joint.constraint_softness.impulse_scale;
            }
            const c_dot: f32 = ang_vel_a - ang_vel_b; // flipped
            const old_impulse: f32 = revolute.upper_impulse;
            var impulse: f32 =
                -mass_scale * revolute.axial_mass * (c_dot + bias) - impulse_scale * old_impulse;
            revolute.upper_impulse = @max(old_impulse + impulse, 0.0);
            impulse = revolute.upper_impulse - old_impulse;
            ang_vel_a += inv_inertia_a * impulse; // flipped
            ang_vel_b -= inv_inertia_b * impulse;
        }
    }

    // Point-to-point: hold the two anchors coincident (this is the actual pin). Solved as
    // a 2D linear constraint via the point-to-point effective-mass matrix.
    {
        const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, revolute.frame_a.p);
        const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, revolute.frame_b.p);
        const point_vel_a: Vec2 = vel_a + crossSV2(ang_vel_a, anchor_a);
        const point_vel_b: Vec2 = vel_b + crossSV2(ang_vel_b, anchor_b);
        const constraint_velocity: Vec2 = point_vel_b - point_vel_a;

        // In the biased pass, push the anchors back together softly; relax passes don't.
        var bias: Vec2 = .{ 0, 0 };
        var mass_scale: f32 = 1.0;
        var impulse_scale: f32 = 0.0;
        if (use_bias) {
            const relative_drift: Vec2 = state_b.delta_position - state_a.delta_position;
            const separation: Vec2 = relative_drift + (anchor_b - anchor_a) + revolute.delta_center;
            bias = separation * splat2(joint.constraint_softness.bias_rate);
            mass_scale = joint.constraint_softness.mass_scale;
            impulse_scale = joint.constraint_softness.impulse_scale;
        }

        const effective_mass: Mat22 =
            pointToPointMatrix(inv_mass_a, inv_mass_b, inv_inertia_a, inv_inertia_b, anchor_a, anchor_b);
        const unscaled_impulse: Vec2 = solve22(effective_mass, constraint_velocity + bias);
        const impulse: Vec2 = .{
            -mass_scale * unscaled_impulse[0] - impulse_scale * revolute.linear_impulse[0],
            -mass_scale * unscaled_impulse[1] - impulse_scale * revolute.linear_impulse[1],
        };
        revolute.linear_impulse = revolute.linear_impulse + impulse;

        vel_a = mulSub2(vel_a, inv_mass_a, impulse);
        ang_vel_a -= inv_inertia_a * cross2(anchor_a, impulse);
        vel_b = mulAdd2(vel_b, inv_mass_b, impulse);
        ang_vel_b += inv_inertia_b * cross2(anchor_b, impulse);
    }

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

// -- Distance joint --------------------------------------------------------------

fn prepareDistanceJoint(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
    h: f32,
    enable_warm_starting: bool,
) void {
    const frames: PreparedFrames = computeJointFrames(joint, bodies, motion);
    const dist: *DistanceJoint = &joint.data.distance;
    dist.anchor_a = frames.frame_a.p;
    dist.anchor_b = frames.frame_b.p;
    dist.delta_center = frames.delta_center;

    const separation: Vec2 = (dist.anchor_b - dist.anchor_a) + dist.delta_center;
    const axis: Vec2 = normalizeOrZero2(separation);
    const cr_a: f32 = cross2(dist.anchor_a, axis);
    const cr_b: f32 = cross2(dist.anchor_b, axis);
    const k: f32 = joint.inv_mass_a + joint.inv_mass_b +
        joint.inv_inertia_a * cr_a * cr_a + joint.inv_inertia_b * cr_b * cr_b;
    dist.axial_mass = if (k > 0.0) 1.0 / k else 0.0;
    dist.spring_softness = makeSoft(dist.hertz, dist.damping_ratio, h);

    if (enable_warm_starting == false) {
        dist.impulse = 0;
        dist.lower_impulse = 0;
        dist.upper_impulse = 0;
        dist.motor_impulse = 0;
    }
}

fn warmStartDistanceJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const dist: *const DistanceJoint = &joint.data.distance;

    const anchor_a: Vec2 = rotateVec2(state[joint.body_a].delta_rotation, dist.anchor_a);
    const anchor_b: Vec2 = rotateVec2(state[joint.body_b].delta_rotation, dist.anchor_b);
    const ds: Vec2 =
        (state[joint.body_b].delta_position - state[joint.body_a].delta_position) + (anchor_b - anchor_a);
    const separation: Vec2 = dist.delta_center + ds;
    const axis: Vec2 = normalizeOrZero2(separation);

    const axial_impulse: f32 =
        dist.impulse + dist.lower_impulse - dist.upper_impulse + dist.motor_impulse;
    const p: Vec2 = axis * splat2(axial_impulse);

    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;
    vel_a = mulSub2(vel_a, inv_mass_a, p);
    ang_vel_a -= inv_inertia_a * cross2(anchor_a, p);
    vel_b = mulAdd2(vel_b, inv_mass_b, p);
    ang_vel_b += inv_inertia_b * cross2(anchor_b, p);

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

/// Solve the distance joint: a single constraint along the line between the two anchors.
/// It can act as a rigid rod (hold `length` exactly), a soft spring toward `length`, and/or
/// a one-sided limit on [min_length, max_length], plus an optional axial motor. Spring and
/// limit can coexist; the rigid equality is used only when the spring is off.
fn solveDistanceJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
    h: f32,
    inv_h: f32,
    use_bias: bool,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const dist: *DistanceJoint = &joint.data.distance;

    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];
    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;

    const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, dist.anchor_a);
    const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, dist.anchor_b);
    const ds: Vec2 = (state_b.delta_position - state_a.delta_position) + (anchor_b - anchor_a);
    const separation: Vec2 = dist.delta_center + ds;
    const len: f32 = length2(separation);
    const axis: Vec2 = normalizeOrZero2(separation);

    // Soft when the spring is on and the limits don't pin the len to a point.
    const length_not_pinned: bool =
        dist.min_length < dist.max_length or dist.enable_limit == false;
    if (dist.enable_spring and length_not_pinned) {
        if (dist.hertz > 0.0) {
            const vr: Vec2 = (vel_b - vel_a) + (crossSV2(ang_vel_b, anchor_b) - crossSV2(ang_vel_a, anchor_a));
            const c_dot: f32 = dot2(axis, vr);
            const c: f32 = len - dist.length;
            const bias: f32 = dist.spring_softness.bias_rate * c;
            const m: f32 = dist.spring_softness.mass_scale * dist.axial_mass;
            const old_impulse: f32 = dist.impulse;
            var impulse: f32 = -m * (c_dot + bias) - dist.spring_softness.impulse_scale * old_impulse;
            dist.impulse = clamp(
                dist.impulse + impulse,
                dist.lower_spring_force * h,
                dist.upper_spring_force * h,
            );
            impulse = dist.impulse - old_impulse;
            const p: Vec2 = axis * splat2(impulse);
            vel_a = mulSub2(vel_a, inv_mass_a, p);
            ang_vel_a -= inv_inertia_a * cross2(anchor_a, p);
            vel_b = mulAdd2(vel_b, inv_mass_b, p);
            ang_vel_b += inv_inertia_b * cross2(anchor_b, p);
        }

        if (dist.enable_motor) {
            const vr: Vec2 = (vel_b - vel_a) + (crossSV2(ang_vel_b, anchor_b) - crossSV2(ang_vel_a, anchor_a));
            const c_dot: f32 = dot2(axis, vr);
            var impulse: f32 = dist.axial_mass * (dist.motor_speed - c_dot);
            const old_impulse: f32 = dist.motor_impulse;
            const max_impulse: f32 = h * dist.max_motor_force;
            dist.motor_impulse = clamp(dist.motor_impulse + impulse, -max_impulse, max_impulse);
            impulse = dist.motor_impulse - old_impulse;
            const p: Vec2 = axis * splat2(impulse);
            vel_a = mulSub2(vel_a, inv_mass_a, p);
            ang_vel_a -= inv_inertia_a * cross2(anchor_a, p);
            vel_b = mulAdd2(vel_b, inv_mass_b, p);
            ang_vel_b += inv_inertia_b * cross2(anchor_b, p);
        }

        if (dist.enable_limit) {
            // Lower len limit: keep len >= minLength.
            {
                const vr: Vec2 = (vel_b - vel_a) + (crossSV2(ang_vel_b, anchor_b) - crossSV2(ang_vel_a, anchor_a));
                const c_dot: f32 = dot2(axis, vr);
                const c: f32 = len - dist.min_length;
                var bias: f32 = 0.0;
                var mass_scale: f32 = 1.0;
                var impulse_scale: f32 = 0.0;
                if (c > 0.0) {
                    bias = c * inv_h; // speculative
                } else if (use_bias) {
                    bias = joint.constraint_softness.bias_rate * c;
                    mass_scale = joint.constraint_softness.mass_scale;
                    impulse_scale = joint.constraint_softness.impulse_scale;
                }
                var impulse: f32 =
                    -mass_scale * dist.axial_mass * (c_dot + bias) - impulse_scale * dist.lower_impulse;
                const new_impulse: f32 = @max(0.0, dist.lower_impulse + impulse);
                impulse = new_impulse - dist.lower_impulse;
                dist.lower_impulse = new_impulse;
                const p: Vec2 = axis * splat2(impulse);
                vel_a = mulSub2(vel_a, inv_mass_a, p);
                ang_vel_a -= inv_inertia_a * cross2(anchor_a, p);
                vel_b = mulAdd2(vel_b, inv_mass_b, p);
                ang_vel_b += inv_inertia_b * cross2(anchor_b, p);
            }

            // Upper len limit: keep len <= maxLength (impulse along -axis).
            {
                const vr: Vec2 = (vel_a - vel_b) + (crossSV2(ang_vel_a, anchor_a) - crossSV2(ang_vel_b, anchor_b));
                const c_dot: f32 = dot2(axis, vr);
                const c: f32 = dist.max_length - len;
                var bias: f32 = 0.0;
                var mass_scale: f32 = 1.0;
                var impulse_scale: f32 = 0.0;
                if (c > 0.0) {
                    bias = c * inv_h;
                } else if (use_bias) {
                    bias = joint.constraint_softness.bias_rate * c;
                    mass_scale = joint.constraint_softness.mass_scale;
                    impulse_scale = joint.constraint_softness.impulse_scale;
                }
                var impulse: f32 =
                    -mass_scale * dist.axial_mass * (c_dot + bias) - impulse_scale * dist.upper_impulse;
                const new_impulse: f32 = @max(0.0, dist.upper_impulse + impulse);
                impulse = new_impulse - dist.upper_impulse;
                dist.upper_impulse = new_impulse;
                const p: Vec2 = axis * splat2(-impulse);
                vel_a = mulSub2(vel_a, inv_mass_a, p);
                ang_vel_a -= inv_inertia_a * cross2(anchor_a, p);
                vel_b = mulAdd2(vel_b, inv_mass_b, p);
                ang_vel_b += inv_inertia_b * cross2(anchor_b, p);
            }
        }
    } else {
        // Rigid rod at the rest len.
        const vr: Vec2 = (vel_b - vel_a) + (crossSV2(ang_vel_b, anchor_b) - crossSV2(ang_vel_a, anchor_a));
        const c_dot: f32 = dot2(axis, vr);
        const c: f32 = len - dist.length;
        var bias: f32 = 0.0;
        var mass_scale: f32 = 1.0;
        var impulse_scale: f32 = 0.0;
        if (use_bias) {
            bias = joint.constraint_softness.bias_rate * c;
            mass_scale = joint.constraint_softness.mass_scale;
            impulse_scale = joint.constraint_softness.impulse_scale;
        }
        const impulse: f32 =
            -mass_scale * dist.axial_mass * (c_dot + bias) - impulse_scale * dist.impulse;
        dist.impulse += impulse;
        const p: Vec2 = axis * splat2(impulse);
        vel_a = mulSub2(vel_a, inv_mass_a, p);
        ang_vel_a -= inv_inertia_a * cross2(anchor_a, p);
        vel_b = mulAdd2(vel_b, inv_mass_b, p);
        ang_vel_b += inv_inertia_b * cross2(anchor_b, p);
    }

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

// -- Pulley joint ----------------------------------------------------------------

fn preparePulleyJoint(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
    enable_warm_starting: bool,
) void {
    const frames: PreparedFrames = computeJointFrames(joint, bodies, motion);
    const pul: *PulleyJoint = &joint.data.pulley;
    pul.anchor_a = frames.frame_a.p;
    pul.anchor_b = frames.frame_b.p;

    const com_a: Vec2 = bodies[joint.body_a].center;
    const com_b: Vec2 = bodies[joint.body_b].center;
    pul.s_a0 = (com_a + pul.anchor_a) - pul.ground_anchor_a;
    pul.s_b0 = (com_b + pul.anchor_b) - pul.ground_anchor_b;
    pul.u_a = normalizeOrZero2(pul.s_a0);
    pul.u_b = normalizeOrZero2(pul.s_b0);

    // Lazily capture the constant rope length from the initial configuration.
    if (pul.constant < 0.0) {
        pul.constant = length2(pul.s_a0) + pul.ratio * length2(pul.s_b0);
    }

    const cr_a: f32 = cross2(pul.anchor_a, pul.u_a);
    const cr_b: f32 = cross2(pul.anchor_b, pul.u_b);
    const m_a: f32 = joint.inv_mass_a + joint.inv_inertia_a * cr_a * cr_a;
    const m_b: f32 = joint.inv_mass_b + joint.inv_inertia_b * cr_b * cr_b;
    const k: f32 = m_a + pul.ratio * pul.ratio * m_b;
    pul.mass = if (k > 0.0) 1.0 / k else 0.0;

    if (enable_warm_starting == false) {
        pul.impulse = 0;
    }
}

fn warmStartPulleyJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
) void {
    const pul: *const PulleyJoint = &joint.data.pulley;
    const anchor_a: Vec2 = rotateVec2(state[joint.body_a].delta_rotation, pul.anchor_a);
    const anchor_b: Vec2 = rotateVec2(state[joint.body_b].delta_rotation, pul.anchor_b);
    const p_a: Vec2 = pul.u_a * splat2(-pul.impulse);
    const p_b: Vec2 = pul.u_b * splat2(-pul.ratio * pul.impulse);

    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;
    vel_a = mulAdd2(vel_a, joint.inv_mass_a, p_a);
    ang_vel_a += joint.inv_inertia_a * cross2(anchor_a, p_a);
    vel_b = mulAdd2(vel_b, joint.inv_mass_b, p_b);
    ang_vel_b += joint.inv_inertia_b * cross2(anchor_b, p_b);
    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

/// Solve the pulley: a single equality constraint coupling the two rope segments,
/// C = constant - lengthA - ratio*lengthB = 0. Each ground anchor is a fixed world point,
/// so the current segment is the anchor's moved position minus that fixed point.
fn solvePulleyJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
    use_bias: bool,
) void {
    const pul: *PulleyJoint = &joint.data.pulley;
    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];
    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;

    const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, pul.anchor_a);
    const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, pul.anchor_b);
    const s_a: Vec2 = pul.s_a0 + state_a.delta_position + (anchor_a - pul.anchor_a);
    const s_b: Vec2 = pul.s_b0 + state_b.delta_position + (anchor_b - pul.anchor_b);
    const len_a: f32 = length2(s_a);
    const len_b: f32 = length2(s_b);
    const u_a: Vec2 = normalizeOrZero2(s_a);
    const u_b: Vec2 = normalizeOrZero2(s_b);

    const c: f32 = pul.constant - len_a - pul.ratio * len_b;
    var bias: f32 = 0.0;
    var mass_scale: f32 = 1.0;
    var impulse_scale: f32 = 0.0;
    if (use_bias) {
        bias = joint.constraint_softness.bias_rate * c;
        mass_scale = joint.constraint_softness.mass_scale;
        impulse_scale = joint.constraint_softness.impulse_scale;
    }

    const vp_a: Vec2 = vel_a + crossSV2(ang_vel_a, anchor_a);
    const vp_b: Vec2 = vel_b + crossSV2(ang_vel_b, anchor_b);
    const c_dot: f32 = -dot2(u_a, vp_a) - pul.ratio * dot2(u_b, vp_b);

    const impulse: f32 = -mass_scale * pul.mass * (c_dot + bias) - impulse_scale * pul.impulse;
    pul.impulse += impulse;

    const p_a: Vec2 = u_a * splat2(-impulse);
    const p_b: Vec2 = u_b * splat2(-pul.ratio * impulse);
    vel_a = mulAdd2(vel_a, joint.inv_mass_a, p_a);
    ang_vel_a += joint.inv_inertia_a * cross2(anchor_a, p_a);
    vel_b = mulAdd2(vel_b, joint.inv_mass_b, p_b);
    ang_vel_b += joint.inv_inertia_b * cross2(anchor_b, p_b);

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

// -- Weld joint ------------------------------------------------------------------

fn prepareWeldJoint(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
    h: f32,
    enable_warm_starting: bool,
) void {
    const frames: PreparedFrames = computeJointFrames(joint, bodies, motion);
    const weld: *WeldJoint = &joint.data.weld;
    weld.frame_a = frames.frame_a;
    weld.frame_b = frames.frame_b;
    weld.delta_center = frames.delta_center;

    const ka: f32 = joint.inv_inertia_a + joint.inv_inertia_b;
    weld.axial_mass = if (ka > 0.0) 1.0 / ka else 0.0;

    // A zero spring hertz means "use the rigid constraint softness".
    weld.linear_spring = if (weld.linear_hertz == 0.0)
        joint.constraint_softness
    else
        makeSoft(weld.linear_hertz, weld.linear_damping_ratio, h);
    weld.angular_spring = if (weld.angular_hertz == 0.0)
        joint.constraint_softness
    else
        makeSoft(weld.angular_hertz, weld.angular_damping_ratio, h);

    if (enable_warm_starting == false) {
        weld.linear_impulse = .{ 0, 0 };
        weld.angular_impulse = 0;
    }
}

fn warmStartWeldJoint(joint: *Joint, state: []const BodyState, motion: []Motion) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const weld: *const WeldJoint = &joint.data.weld;

    const anchor_a: Vec2 = rotateVec2(state[joint.body_a].delta_rotation, weld.frame_a.p);
    const anchor_b: Vec2 = rotateVec2(state[joint.body_b].delta_rotation, weld.frame_b.p);

    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;
    vel_a = mulSub2(vel_a, inv_mass_a, weld.linear_impulse);
    ang_vel_a -= inv_inertia_a * (cross2(anchor_a, weld.linear_impulse) + weld.angular_impulse);
    vel_b = mulAdd2(vel_b, inv_mass_b, weld.linear_impulse);
    ang_vel_b += inv_inertia_b * (cross2(anchor_b, weld.linear_impulse) + weld.angular_impulse);

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

fn solveWeldJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
    use_bias: bool,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const weld: *WeldJoint = &joint.data.weld;

    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];
    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;

    // Angular constraint (scalar).
    {
        const qa: Rot2 = mulRot2(state_a.delta_rotation, weld.frame_a.q);
        const qb: Rot2 = mulRot2(state_b.delta_rotation, weld.frame_b.q);
        const relative_q: Rot2 = invMulRot2(qa, qb);
        const joint_angle: f32 = relative_q.angle();

        var bias: f32 = 0.0;
        var mass_scale: f32 = 1.0;
        var impulse_scale: f32 = 0.0;
        if (use_bias or weld.angular_hertz > 0.0) {
            bias = weld.angular_spring.bias_rate * joint_angle;
            mass_scale = weld.angular_spring.mass_scale;
            impulse_scale = weld.angular_spring.impulse_scale;
        }
        const c_dot: f32 = ang_vel_b - ang_vel_a;
        const impulse: f32 =
            -mass_scale * weld.axial_mass * (c_dot + bias) - impulse_scale * weld.angular_impulse;
        weld.angular_impulse += impulse;
        ang_vel_a -= inv_inertia_a * impulse;
        ang_vel_b += inv_inertia_b * impulse;
    }

    // Linear constraint (2x2).
    {
        const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, weld.frame_a.p);
        const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, weld.frame_b.p);

        var bias: Vec2 = .{ 0, 0 };
        var mass_scale: f32 = 1.0;
        var impulse_scale: f32 = 0.0;
        if (use_bias or weld.linear_hertz > 0.0) {
            const c: Vec2 = (state_b.delta_position - state_a.delta_position) +
                (anchor_b - anchor_a) + weld.delta_center;
            bias = c * splat2(weld.linear_spring.bias_rate);
            mass_scale = weld.linear_spring.mass_scale;
            impulse_scale = weld.linear_spring.impulse_scale;
        }
        const c_dot: Vec2 = (vel_b + crossSV2(ang_vel_b, anchor_b)) - (vel_a + crossSV2(ang_vel_a, anchor_a));
        const k: Mat22 =
            pointToPointMatrix(inv_mass_a, inv_mass_b, inv_inertia_a, inv_inertia_b, anchor_a, anchor_b);
        const b: Vec2 = solve22(k, c_dot + bias);
        const impulse: Vec2 = .{
            -mass_scale * b[0] - impulse_scale * weld.linear_impulse[0],
            -mass_scale * b[1] - impulse_scale * weld.linear_impulse[1],
        };
        weld.linear_impulse = weld.linear_impulse + impulse;

        vel_a = mulSub2(vel_a, inv_mass_a, impulse);
        ang_vel_a -= inv_inertia_a * cross2(anchor_a, impulse);
        vel_b = mulAdd2(vel_b, inv_mass_b, impulse);
        ang_vel_b += inv_inertia_b * cross2(anchor_b, impulse);
    }

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

// -- Motor joint -----------------------------------------------------------------
//
// A pure actuator: it has no biased (position-correcting) pass. It drives the relative
// motion of the two bodies toward target velocities (capped by max force/torque) and
// optionally applies soft springs toward the target pose.

fn prepareMotorJoint(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
    h: f32,
    enable_warm_starting: bool,
) void {
    const frames: PreparedFrames = computeJointFrames(joint, bodies, motion);
    const motor: *MotorJoint = &joint.data.motor;
    motor.frame_a = frames.frame_a;
    motor.frame_b = frames.frame_b;
    motor.delta_center = frames.delta_center;

    motor.linear_spring = makeSoft(motor.linear_hertz, motor.linear_damping_ratio, h);
    motor.angular_spring = makeSoft(motor.angular_hertz, motor.angular_damping_ratio, h);

    const k_linear: Mat22 = pointToPointMatrix(
        joint.inv_mass_a,
        joint.inv_mass_b,
        joint.inv_inertia_a,
        joint.inv_inertia_b,
        motor.frame_a.p,
        motor.frame_b.p,
    );
    motor.linear_mass = inverse22(k_linear);

    const k_angular: f32 = joint.inv_inertia_a + joint.inv_inertia_b;
    motor.angular_mass = if (k_angular > 0.0) 1.0 / k_angular else 0.0;

    if (enable_warm_starting == false) {
        motor.linear_velocity_impulse = .{ 0, 0 };
        motor.angular_velocity_impulse = 0;
        motor.linear_spring_impulse = .{ 0, 0 };
        motor.angular_spring_impulse = 0;
    }
}

fn warmStartMotorJoint(joint: *Joint, state: []const BodyState, motion: []Motion) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const motor: *const MotorJoint = &joint.data.motor;

    const anchor_a: Vec2 = rotateVec2(state[joint.body_a].delta_rotation, motor.frame_a.p);
    const anchor_b: Vec2 = rotateVec2(state[joint.body_b].delta_rotation, motor.frame_b.p);
    const linear_impulse: Vec2 = motor.linear_velocity_impulse + motor.linear_spring_impulse;
    const angular_impulse: f32 = motor.angular_velocity_impulse + motor.angular_spring_impulse;

    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;
    vel_a = mulSub2(vel_a, inv_mass_a, linear_impulse);
    ang_vel_a -= inv_inertia_a * (cross2(anchor_a, linear_impulse) + angular_impulse);
    vel_b = mulAdd2(vel_b, inv_mass_b, linear_impulse);
    ang_vel_b += inv_inertia_b * (cross2(anchor_b, linear_impulse) + angular_impulse);

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

fn solveMotorJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
    h: f32,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const motor: *MotorJoint = &joint.data.motor;

    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];
    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;

    // Angular spring toward the target relative angle.
    if (motor.max_spring_torque > 0.0 and motor.angular_hertz > 0.0) {
        const qa: Rot2 = mulRot2(state_a.delta_rotation, motor.frame_a.q);
        const qb: Rot2 = mulRot2(state_b.delta_rotation, motor.frame_b.q);
        const relative_q: Rot2 = invMulRot2(qa, qb);
        const angle_error: f32 = relative_q.angle();
        const bias: f32 = motor.angular_spring.bias_rate * angle_error;
        const c_dot: f32 = ang_vel_b - ang_vel_a;
        const max_impulse: f32 = h * motor.max_spring_torque;
        const old_impulse: f32 = motor.angular_spring_impulse;
        var impulse: f32 = -motor.angular_spring.mass_scale * motor.angular_mass * (c_dot + bias) -
            motor.angular_spring.impulse_scale * old_impulse;
        motor.angular_spring_impulse = clamp(old_impulse + impulse, -max_impulse, max_impulse);
        impulse = motor.angular_spring_impulse - old_impulse;
        ang_vel_a -= inv_inertia_a * impulse;
        ang_vel_b += inv_inertia_b * impulse;
    }

    // Angular velocity drive toward the target relative angular velocity.
    if (motor.max_velocity_torque > 0.0) {
        const c_dot: f32 = ang_vel_b - ang_vel_a - motor.angular_velocity;
        var impulse: f32 = -motor.angular_mass * c_dot;
        const max_impulse: f32 = h * motor.max_velocity_torque;
        const old_impulse: f32 = motor.angular_velocity_impulse;
        motor.angular_velocity_impulse = clamp(old_impulse + impulse, -max_impulse, max_impulse);
        impulse = motor.angular_velocity_impulse - old_impulse;
        ang_vel_a -= inv_inertia_a * impulse;
        ang_vel_b += inv_inertia_b * impulse;
    }

    const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, motor.frame_a.p);
    const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, motor.frame_b.p);

    // Linear spring toward the target relative position.
    if (motor.max_spring_force > 0.0 and motor.linear_hertz > 0.0) {
        const c: Vec2 =
            (state_b.delta_position - state_a.delta_position) + (anchor_b - anchor_a) + motor.delta_center;
        const bias: Vec2 = c * splat2(motor.linear_spring.bias_rate);
        var c_dot: Vec2 = (vel_b + crossSV2(ang_vel_b, anchor_b)) - (vel_a + crossSV2(ang_vel_a, anchor_a));
        c_dot = c_dot + bias;

        // The effective mass shifts with the anchors, so refresh it here.
        const k_linear: Mat22 = pointToPointMatrix(
            inv_mass_a,
            inv_mass_b,
            inv_inertia_a,
            inv_inertia_b,
            anchor_a,
            anchor_b,
        );
        motor.linear_mass = inverse22(k_linear);
        const b: Vec2 = mulMV22(motor.linear_mass, c_dot);

        const old_impulse: Vec2 = motor.linear_spring_impulse;
        const delta: Vec2 = .{
            -motor.linear_spring.mass_scale * b[0] - motor.linear_spring.impulse_scale * old_impulse[0],
            -motor.linear_spring.mass_scale * b[1] - motor.linear_spring.impulse_scale * old_impulse[1],
        };
        const max_impulse: f32 = h * motor.max_spring_force;
        motor.linear_spring_impulse = motor.linear_spring_impulse + delta;
        if (lengthSq2(motor.linear_spring_impulse) > max_impulse * max_impulse) {
            motor.linear_spring_impulse =
                normalizeOrZero2(motor.linear_spring_impulse) * splat2(max_impulse);
        }
        const impulse: Vec2 = motor.linear_spring_impulse - old_impulse;
        vel_a = mulSub2(vel_a, inv_mass_a, impulse);
        ang_vel_a -= inv_inertia_a * cross2(anchor_a, impulse);
        vel_b = mulAdd2(vel_b, inv_mass_b, impulse);
        ang_vel_b += inv_inertia_b * cross2(anchor_b, impulse);
    }

    // Linear velocity drive toward the target relative linear velocity.
    if (motor.max_velocity_force > 0.0) {
        var c_dot: Vec2 = (vel_b + crossSV2(ang_vel_b, anchor_b)) - (vel_a + crossSV2(ang_vel_a, anchor_a));
        c_dot = c_dot - motor.linear_velocity;
        const b: Vec2 = mulMV22(motor.linear_mass, c_dot);
        const delta: Vec2 = .{ -b[0], -b[1] };

        const old_impulse: Vec2 = motor.linear_velocity_impulse;
        const max_impulse: f32 = h * motor.max_velocity_force;
        motor.linear_velocity_impulse = motor.linear_velocity_impulse + delta;
        if (lengthSq2(motor.linear_velocity_impulse) > max_impulse * max_impulse) {
            motor.linear_velocity_impulse =
                normalizeOrZero2(motor.linear_velocity_impulse) * splat2(max_impulse);
        }
        const impulse: Vec2 = motor.linear_velocity_impulse - old_impulse;
        vel_a = mulSub2(vel_a, inv_mass_a, impulse);
        ang_vel_a -= inv_inertia_a * cross2(anchor_a, impulse);
        vel_b = mulAdd2(vel_b, inv_mass_b, impulse);
        ang_vel_b += inv_inertia_b * cross2(anchor_b, impulse);
    }

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

// -- Prismatic joint -------------------------------------------------------------
//
// B slides along an axis fixed in A. The free axial direction carries an optional
// spring / motor / limits; the two locked directions (perpendicular translation and
// relative rotation) are enforced by a 2x2 block. `axial_arm_*` and `perp_arm_*` are
// the moment arms of the axial and perpendicular forces about each body's center.

fn preparePrismaticJoint(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
    h: f32,
    enable_warm_starting: bool,
) void {
    const frames: PreparedFrames = computeJointFrames(joint, bodies, motion);
    const prismatic: *PrismaticJoint = &joint.data.prismatic;
    prismatic.frame_a = frames.frame_a;
    prismatic.frame_b = frames.frame_b;
    prismatic.delta_center = frames.delta_center;
    prismatic.spring_softness = makeSoft(prismatic.hertz, prismatic.damping_ratio, h);

    if (enable_warm_starting == false) {
        prismatic.impulse = .{ 0, 0 };
        prismatic.spring_impulse = 0;
        prismatic.motor_impulse = 0;
        prismatic.lower_impulse = 0;
        prismatic.upper_impulse = 0;
    }
}

fn warmStartPrismaticJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const prismatic: *const PrismaticJoint = &joint.data.prismatic;
    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];

    const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, prismatic.frame_a.p);
    const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, prismatic.frame_b.p);
    const separation: Vec2 =
        (state_b.delta_position - state_a.delta_position) + prismatic.delta_center + (anchor_b - anchor_a);
    var axis_a: Vec2 = rotateVec2(prismatic.frame_a.q, .{ 1.0, 0.0 });
    axis_a = rotateVec2(state_a.delta_rotation, axis_a);

    const axial_arm_a: f32 = cross2(anchor_a + separation, axis_a);
    const axial_arm_b: f32 = cross2(anchor_b, axis_a);
    const axial_impulse: f32 = prismatic.spring_impulse + prismatic.motor_impulse +
        prismatic.lower_impulse - prismatic.upper_impulse;

    const perp_a: Vec2 = leftPerp2(axis_a);
    const perp_arm_a: f32 = cross2(anchor_a + separation, perp_a);
    const perp_arm_b: f32 = cross2(anchor_b, perp_a);
    const perp_impulse: f32 = prismatic.impulse[0];
    const angle_impulse: f32 = prismatic.impulse[1];

    const p: Vec2 = axis_a * splat2(axial_impulse) + perp_a * splat2(perp_impulse);
    const angular_a: f32 = axial_impulse * axial_arm_a + perp_impulse * perp_arm_a + angle_impulse;
    const angular_b: f32 = axial_impulse * axial_arm_b + perp_impulse * perp_arm_b + angle_impulse;

    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;
    vel_a = mulSub2(vel_a, inv_mass_a, p);
    ang_vel_a -= inv_inertia_a * angular_a;
    vel_b = mulAdd2(vel_b, inv_mass_b, p);
    ang_vel_b += inv_inertia_b * angular_b;

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

/// Solve the prismatic joint (a slider): the two bodies may translate along one shared axis
/// but not perpendicular to it and not rotate relative to each other. A 2x2 block constraint
/// removes the perpendicular translation and the relative rotation together; an optional
/// spring, motor, and limits act along the free axis.
fn solvePrismaticJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
    h: f32,
    inv_h: f32,
    use_bias: bool,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const prismatic: *PrismaticJoint = &joint.data.prismatic;

    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];
    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;

    const qa: Rot2 = mulRot2(state_a.delta_rotation, prismatic.frame_a.q);
    const qb: Rot2 = mulRot2(state_b.delta_rotation, prismatic.frame_b.q);
    const relative_q: Rot2 = invMulRot2(qa, qb);

    const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, prismatic.frame_a.p);
    const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, prismatic.frame_b.p);
    const separation: Vec2 =
        (state_b.delta_position - state_a.delta_position) + prismatic.delta_center + (anchor_b - anchor_a);
    var axis_a: Vec2 = rotateVec2(prismatic.frame_a.q, .{ 1.0, 0.0 });
    axis_a = rotateVec2(state_a.delta_rotation, axis_a);
    const translation: f32 = dot2(axis_a, separation);

    const axial_arm_a: f32 = cross2(anchor_a + separation, axis_a);
    const axial_arm_b: f32 = cross2(anchor_b, axis_a);
    const k_axial: f32 = inv_mass_a + inv_mass_b +
        inv_inertia_a * axial_arm_a * axial_arm_a + inv_inertia_b * axial_arm_b * axial_arm_b;
    const axial_mass: f32 = if (k_axial > 0.0) 1.0 / k_axial else 0.0;
    const softness: Softness = joint.constraint_softness;

    // Axial spring (a real spring, applied in both passes).
    if (prismatic.enable_spring) {
        const c: f32 = translation - prismatic.target_translation;
        const bias: f32 = prismatic.spring_softness.bias_rate * c;
        const c_dot: f32 = dot2(axis_a, vel_b - vel_a) + axial_arm_b * ang_vel_b - axial_arm_a * ang_vel_a;
        const delta: f32 = -prismatic.spring_softness.mass_scale * axial_mass * (c_dot + bias) -
            prismatic.spring_softness.impulse_scale * prismatic.spring_impulse;
        prismatic.spring_impulse += delta;
        const p: Vec2 = axis_a * splat2(delta);
        vel_a = mulSub2(vel_a, inv_mass_a, p);
        ang_vel_a -= inv_inertia_a * (delta * axial_arm_a);
        vel_b = mulAdd2(vel_b, inv_mass_b, p);
        ang_vel_b += inv_inertia_b * (delta * axial_arm_b);
    }

    // Axial motor.
    if (prismatic.enable_motor) {
        const c_dot: f32 = dot2(axis_a, vel_b - vel_a) + axial_arm_b * ang_vel_b - axial_arm_a * ang_vel_a;
        var delta: f32 = axial_mass * (prismatic.motor_speed - c_dot);
        const old_impulse: f32 = prismatic.motor_impulse;
        const max_impulse: f32 = h * prismatic.max_motor_force;
        prismatic.motor_impulse = clamp(prismatic.motor_impulse + delta, -max_impulse, max_impulse);
        delta = prismatic.motor_impulse - old_impulse;
        const p: Vec2 = axis_a * splat2(delta);
        vel_a = mulSub2(vel_a, inv_mass_a, p);
        ang_vel_a -= inv_inertia_a * (delta * axial_arm_a);
        vel_b = mulAdd2(vel_b, inv_mass_b, p);
        ang_vel_b += inv_inertia_b * (delta * axial_arm_b);
    }

    // Translation limits (with speculation, bounded to keep them well-conditioned).
    if (prismatic.enable_limit) {
        const safe_distance: f32 = 1.0; // length units per meter (we work in meters)
        const limit_band: f32 = 0.25 * (prismatic.upper_translation - prismatic.lower_translation);

        // Lower: keep translation >= lowerTranslation.
        {
            const c: f32 = translation - prismatic.lower_translation;
            if (c < limit_band) {
                var bias: f32 = 0.0;
                var mass_scale: f32 = 1.0;
                var impulse_scale: f32 = 0.0;
                if (c > 0.0) {
                    bias = @min(c, safe_distance) * inv_h;
                } else if (use_bias) {
                    bias = softness.bias_rate * c;
                    mass_scale = softness.mass_scale;
                    impulse_scale = softness.impulse_scale;
                }
                const old_impulse: f32 = prismatic.lower_impulse;
                const c_dot: f32 = dot2(axis_a, vel_b - vel_a) + axial_arm_b * ang_vel_b - axial_arm_a * ang_vel_a;
                var delta: f32 = -axial_mass * mass_scale * (c_dot + bias) - impulse_scale * old_impulse;
                prismatic.lower_impulse = @max(old_impulse + delta, 0.0);
                delta = prismatic.lower_impulse - old_impulse;
                const p: Vec2 = axis_a * splat2(delta);
                vel_a = mulSub2(vel_a, inv_mass_a, p);
                ang_vel_a -= inv_inertia_a * (delta * axial_arm_a);
                vel_b = mulAdd2(vel_b, inv_mass_b, p);
                ang_vel_b += inv_inertia_b * (delta * axial_arm_b);
            } else {
                prismatic.lower_impulse = 0;
            }
        }

        // Upper: keep translation <= upperTranslation (signs flipped).
        {
            const c: f32 = prismatic.upper_translation - translation;
            if (c < limit_band) {
                var bias: f32 = 0.0;
                var mass_scale: f32 = 1.0;
                var impulse_scale: f32 = 0.0;
                if (c > 0.0) {
                    bias = @min(c, safe_distance) * inv_h;
                } else if (use_bias) {
                    bias = softness.bias_rate * c;
                    mass_scale = softness.mass_scale;
                    impulse_scale = softness.impulse_scale;
                }
                const old_impulse: f32 = prismatic.upper_impulse;
                const c_dot: f32 = dot2(axis_a, vel_a - vel_b) + axial_arm_a * ang_vel_a - axial_arm_b * ang_vel_b;
                var delta: f32 = -axial_mass * mass_scale * (c_dot + bias) - impulse_scale * old_impulse;
                prismatic.upper_impulse = @max(old_impulse + delta, 0.0);
                delta = prismatic.upper_impulse - old_impulse;
                const p: Vec2 = axis_a * splat2(delta);
                vel_a = mulAdd2(vel_a, inv_mass_a, p);
                ang_vel_a += inv_inertia_a * (delta * axial_arm_a);
                vel_b = mulSub2(vel_b, inv_mass_b, p);
                ang_vel_b -= inv_inertia_b * (delta * axial_arm_b);
            } else {
                prismatic.upper_impulse = 0;
            }
        }
    }

    // The locked directions: perpendicular translation + relative rotation (2x2 block).
    {
        const perp_a: Vec2 = leftPerp2(axis_a);
        const perp_arm_a: f32 = cross2(separation + anchor_a, perp_a);
        const perp_arm_b: f32 = cross2(anchor_b, perp_a);

        const c_dot: Vec2 = .{
            dot2(perp_a, vel_b - vel_a) + perp_arm_b * ang_vel_b - perp_arm_a * ang_vel_a,
            ang_vel_b - ang_vel_a,
        };

        var bias: Vec2 = .{ 0, 0 };
        var mass_scale: f32 = 1.0;
        var impulse_scale: f32 = 0.0;
        if (use_bias) {
            const c: Vec2 = .{ dot2(perp_a, separation), relative_q.angle() };
            bias = c * splat2(softness.bias_rate);
            mass_scale = softness.mass_scale;
            impulse_scale = softness.impulse_scale;
        }

        const k11: f32 = inv_mass_a + inv_mass_b +
            inv_inertia_a * perp_arm_a * perp_arm_a + inv_inertia_b * perp_arm_b * perp_arm_b;
        const k12: f32 = inv_inertia_a * perp_arm_a + inv_inertia_b * perp_arm_b;
        var k22: f32 = inv_inertia_a + inv_inertia_b;
        if (k22 == 0.0) {
            k22 = 1.0; // both bodies have fixed rotation
        }
        const k_block: Mat22 = .{ .cx = .{ k11, k12 }, .cy = .{ k12, k22 } };

        const b: Vec2 = solve22(k_block, c_dot + bias);
        const delta: Vec2 = .{
            -mass_scale * b[0] - impulse_scale * prismatic.impulse[0],
            -mass_scale * b[1] - impulse_scale * prismatic.impulse[1],
        };
        prismatic.impulse = prismatic.impulse + delta;

        const p: Vec2 = perp_a * splat2(delta[0]);
        const angular_a: f32 = delta[0] * perp_arm_a + delta[1];
        const angular_b: f32 = delta[0] * perp_arm_b + delta[1];
        vel_a = mulSub2(vel_a, inv_mass_a, p);
        ang_vel_a -= inv_inertia_a * angular_a;
        vel_b = mulAdd2(vel_b, inv_mass_b, p);
        ang_vel_b += inv_inertia_b * angular_b;
    }

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

// -- Wheel joint -----------------------------------------------------------------
//
// A sprung slider that also lets B spin freely: a perpendicular constraint keeps the
// anchor on the axis line, an optional spring acts along the axis, an optional motor
// drives the relative spin, and optional limits bound the axial travel.

fn prepareWheelJoint(
    joint: *Joint,
    bodies: []const Body,
    motion: []const Motion,
    h: f32,
    enable_warm_starting: bool,
) void {
    const frames: PreparedFrames = computeJointFrames(joint, bodies, motion);
    const wheel: *WheelJoint = &joint.data.wheel;
    wheel.frame_a = frames.frame_a;
    wheel.frame_b = frames.frame_b;
    wheel.delta_center = frames.delta_center;

    const anchor_a: Vec2 = wheel.frame_a.p;
    const anchor_b: Vec2 = wheel.frame_b.p;
    const separation: Vec2 = wheel.delta_center + (anchor_b - anchor_a);
    const axis_a: Vec2 = rotateVec2(wheel.frame_a.q, .{ 1.0, 0.0 });
    const perp_a: Vec2 = leftPerp2(axis_a);

    const perp_arm_a: f32 = cross2(separation + anchor_a, perp_a);
    const perp_arm_b: f32 = cross2(anchor_b, perp_a);
    const k_perp: f32 =
        joint.inv_mass_a + joint.inv_mass_b +
        joint.inv_inertia_a * perp_arm_a * perp_arm_a + joint.inv_inertia_b * perp_arm_b * perp_arm_b;
    wheel.perp_mass = if (k_perp > 0.0) 1.0 / k_perp else 0.0;

    const axial_arm_a: f32 = cross2(separation + anchor_a, axis_a);
    const axial_arm_b: f32 = cross2(anchor_b, axis_a);
    const k_axial: f32 =
        joint.inv_mass_a + joint.inv_mass_b +
        joint.inv_inertia_a * axial_arm_a * axial_arm_a + joint.inv_inertia_b * axial_arm_b * axial_arm_b;
    wheel.axial_mass = if (k_axial > 0.0) 1.0 / k_axial else 0.0;
    wheel.spring_softness = makeSoft(wheel.hertz, wheel.damping_ratio, h);

    const k_motor: f32 = joint.inv_inertia_a + joint.inv_inertia_b;
    wheel.motor_mass = if (k_motor > 0.0) 1.0 / k_motor else 0.0;

    if (enable_warm_starting == false) {
        wheel.perp_impulse = 0;
        wheel.spring_impulse = 0;
        wheel.motor_impulse = 0;
        wheel.lower_impulse = 0;
        wheel.upper_impulse = 0;
    }
}

fn warmStartWheelJoint(joint: *Joint, state: []const BodyState, motion: []Motion) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const wheel: *const WheelJoint = &joint.data.wheel;
    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];

    const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, wheel.frame_a.p);
    const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, wheel.frame_b.p);
    const separation: Vec2 =
        (state_b.delta_position - state_a.delta_position) + wheel.delta_center + (anchor_b - anchor_a);
    var axis_a: Vec2 = rotateVec2(wheel.frame_a.q, .{ 1.0, 0.0 });
    axis_a = rotateVec2(state_a.delta_rotation, axis_a);
    const perp_a: Vec2 = leftPerp2(axis_a);

    const axial_arm_a: f32 = cross2(separation + anchor_a, axis_a);
    const axial_arm_b: f32 = cross2(anchor_b, axis_a);
    const perp_arm_a: f32 = cross2(separation + anchor_a, perp_a);
    const perp_arm_b: f32 = cross2(anchor_b, perp_a);
    const axial_impulse: f32 = wheel.spring_impulse + wheel.lower_impulse - wheel.upper_impulse;

    const p: Vec2 = axis_a * splat2(axial_impulse) + perp_a * splat2(wheel.perp_impulse);
    const angular_a: f32 = axial_impulse * axial_arm_a + wheel.perp_impulse * perp_arm_a + wheel.motor_impulse;
    const angular_b: f32 = axial_impulse * axial_arm_b + wheel.perp_impulse * perp_arm_b + wheel.motor_impulse;

    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;
    vel_a = mulSub2(vel_a, inv_mass_a, p);
    ang_vel_a -= inv_inertia_a * angular_a;
    vel_b = mulAdd2(vel_b, inv_mass_b, p);
    ang_vel_b += inv_inertia_b * angular_b;

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

/// Solve the wheel joint (a suspension): like a prismatic slider but the relative rotation
/// is left free, so body B can spin (the wheel) while a perpendicular constraint keeps its
/// anchor on the axis line. An optional spring acts along the axis (the suspension travel), a
/// motor drives the spin, and limits bound the axial travel.
fn solveWheelJoint(
    joint: *Joint,
    state: []const BodyState,
    motion: []Motion,
    h: f32,
    inv_h: f32,
    use_bias: bool,
) void {
    const inv_mass_a: f32 = joint.inv_mass_a;
    const inv_mass_b: f32 = joint.inv_mass_b;
    const inv_inertia_a: f32 = joint.inv_inertia_a;
    const inv_inertia_b: f32 = joint.inv_inertia_b;
    const wheel: *WheelJoint = &joint.data.wheel;

    const state_a: BodyState = state[joint.body_a];
    const state_b: BodyState = state[joint.body_b];
    var vel_a: Vec2 = motion[joint.body_a].linear_velocity;
    var ang_vel_a: f32 = motion[joint.body_a].angular_velocity;
    var vel_b: Vec2 = motion[joint.body_b].linear_velocity;
    var ang_vel_b: f32 = motion[joint.body_b].angular_velocity;

    const fixed_rotation: bool = (inv_inertia_a + inv_inertia_b == 0.0);

    const anchor_a: Vec2 = rotateVec2(state_a.delta_rotation, wheel.frame_a.p);
    const anchor_b: Vec2 = rotateVec2(state_b.delta_rotation, wheel.frame_b.p);
    const separation: Vec2 =
        (state_b.delta_position - state_a.delta_position) + wheel.delta_center + (anchor_b - anchor_a);
    var axis_a: Vec2 = rotateVec2(wheel.frame_a.q, .{ 1.0, 0.0 });
    axis_a = rotateVec2(state_a.delta_rotation, axis_a);
    const translation: f32 = dot2(axis_a, separation);

    const axial_arm_a: f32 = cross2(separation + anchor_a, axis_a);
    const axial_arm_b: f32 = cross2(anchor_b, axis_a);

    // Angular motor drives the relative spin.
    if (wheel.enable_motor and fixed_rotation == false) {
        const c_dot: f32 = ang_vel_b - ang_vel_a - wheel.motor_speed;
        var impulse: f32 = -wheel.motor_mass * c_dot;
        const old_impulse: f32 = wheel.motor_impulse;
        const max_impulse: f32 = h * wheel.max_motor_torque;
        wheel.motor_impulse = clamp(wheel.motor_impulse + impulse, -max_impulse, max_impulse);
        impulse = wheel.motor_impulse - old_impulse;
        ang_vel_a -= inv_inertia_a * impulse;
        ang_vel_b += inv_inertia_b * impulse;
    }

    // Axial spring (a real spring, applied in both passes).
    if (wheel.enable_spring) {
        const c: f32 = translation;
        const bias: f32 = wheel.spring_softness.bias_rate * c;
        const c_dot: f32 = dot2(axis_a, vel_b - vel_a) + axial_arm_b * ang_vel_b - axial_arm_a * ang_vel_a;
        const impulse: f32 = -wheel.spring_softness.mass_scale * wheel.axial_mass * (c_dot + bias) -
            wheel.spring_softness.impulse_scale * wheel.spring_impulse;
        wheel.spring_impulse += impulse;
        const p: Vec2 = axis_a * splat2(impulse);
        vel_a = mulSub2(vel_a, inv_mass_a, p);
        ang_vel_a -= inv_inertia_a * (impulse * axial_arm_a);
        vel_b = mulAdd2(vel_b, inv_mass_b, p);
        ang_vel_b += inv_inertia_b * (impulse * axial_arm_b);
    }

    // Axial translation limits.
    if (wheel.enable_limit) {
        // Lower: keep translation >= lowerTranslation.
        {
            const c: f32 = translation - wheel.lower_translation;
            var bias: f32 = 0.0;
            var mass_scale: f32 = 1.0;
            var impulse_scale: f32 = 0.0;
            if (c > 0.0) {
                bias = c * inv_h;
            } else if (use_bias) {
                bias = joint.constraint_softness.bias_rate * c;
                mass_scale = joint.constraint_softness.mass_scale;
                impulse_scale = joint.constraint_softness.impulse_scale;
            }
            const c_dot: f32 = dot2(axis_a, vel_b - vel_a) + axial_arm_b * ang_vel_b - axial_arm_a * ang_vel_a;
            var impulse: f32 =
                -mass_scale * wheel.axial_mass * (c_dot + bias) - impulse_scale * wheel.lower_impulse;
            const old_impulse: f32 = wheel.lower_impulse;
            wheel.lower_impulse = @max(old_impulse + impulse, 0.0);
            impulse = wheel.lower_impulse - old_impulse;
            const p: Vec2 = axis_a * splat2(impulse);
            vel_a = mulSub2(vel_a, inv_mass_a, p);
            ang_vel_a -= inv_inertia_a * (impulse * axial_arm_a);
            vel_b = mulAdd2(vel_b, inv_mass_b, p);
            ang_vel_b += inv_inertia_b * (impulse * axial_arm_b);
        }

        // Upper: keep translation <= upperTranslation (signs flipped).
        {
            const c: f32 = wheel.upper_translation - translation;
            var bias: f32 = 0.0;
            var mass_scale: f32 = 1.0;
            var impulse_scale: f32 = 0.0;
            if (c > 0.0) {
                bias = c * inv_h;
            } else if (use_bias) {
                bias = joint.constraint_softness.bias_rate * c;
                mass_scale = joint.constraint_softness.mass_scale;
                impulse_scale = joint.constraint_softness.impulse_scale;
            }
            const c_dot: f32 = dot2(axis_a, vel_a - vel_b) + axial_arm_a * ang_vel_a - axial_arm_b * ang_vel_b;
            var impulse: f32 =
                -mass_scale * wheel.axial_mass * (c_dot + bias) - impulse_scale * wheel.upper_impulse;
            const old_impulse: f32 = wheel.upper_impulse;
            wheel.upper_impulse = @max(old_impulse + impulse, 0.0);
            impulse = wheel.upper_impulse - old_impulse;
            const p: Vec2 = axis_a * splat2(impulse);
            vel_a = mulAdd2(vel_a, inv_mass_a, p);
            ang_vel_a += inv_inertia_a * (impulse * axial_arm_a);
            vel_b = mulSub2(vel_b, inv_mass_b, p);
            ang_vel_b -= inv_inertia_b * (impulse * axial_arm_b);
        }
    }

    // Point-to-line: keep the anchor on the axis (perpendicular constraint).
    {
        const perp_a: Vec2 = leftPerp2(axis_a);
        var bias: f32 = 0.0;
        var mass_scale: f32 = 1.0;
        var impulse_scale: f32 = 0.0;
        if (use_bias) {
            const c: f32 = dot2(perp_a, separation);
            bias = joint.constraint_softness.bias_rate * c;
            mass_scale = joint.constraint_softness.mass_scale;
            impulse_scale = joint.constraint_softness.impulse_scale;
        }
        const perp_arm_a: f32 = cross2(separation + anchor_a, perp_a);
        const perp_arm_b: f32 = cross2(anchor_b, perp_a);
        const c_dot: f32 = dot2(perp_a, vel_b - vel_a) + perp_arm_b * ang_vel_b - perp_arm_a * ang_vel_a;
        const impulse: f32 =
            -mass_scale * wheel.perp_mass * (c_dot + bias) - impulse_scale * wheel.perp_impulse;
        wheel.perp_impulse += impulse;
        const p: Vec2 = perp_a * splat2(impulse);
        vel_a = mulSub2(vel_a, inv_mass_a, p);
        ang_vel_a -= inv_inertia_a * (impulse * perp_arm_a);
        vel_b = mulAdd2(vel_b, inv_mass_b, p);
        ang_vel_b += inv_inertia_b * (impulse * perp_arm_b);
    }

    writeBackVelocity(state, motion, joint.body_a, vel_a, ang_vel_a);
    writeBackVelocity(state, motion, joint.body_b, vel_b, ang_vel_b);
}

// ================================================================================
// Islands & sleeping
//
// Box2D maintains *persistent* islands (graph-coloured constraint groups that survive
// across steps). We take the simpler route: a per-step union-find over the dynamic
// contact/joint graph, used only to decide sleeping coherently. Two dynamic bodies
// joined by a touching contact or a joint share an island; an island may sleep only
// when every one of its dynamic members has been "slow" long enough and all permit
// sleeping. Static and kinematic bodies are never merged - a static floor must not
// chain every body resting on it into one giant island, and kinematic bodies never
// sleep. The parent array is indexed by BodyIndex and rebuilt every step.
// box2d (in spirit): island.c + the sleep accounting in solver.c:594
// ================================================================================

/// Reset the union-find so every body is its own root. Call once per step before
/// unioning the touching contacts and joints.
fn dsuReset(parent: []u32) void {
    for (parent, 0..) |*p, i| {
        p.* = @intCast(i);
    }
}

/// Find the representative root of `i`, compressing the path on the way out so repeated
/// queries are near-constant time. box2d-style helper (mirrors zimrphysics.zig).
fn dsuFind(parent: []u32, i: u32) u32 {
    var root: u32 = i;
    while (parent[root] != root) {
        root = parent[root];
    }
    var cur: u32 = i;
    while (parent[cur] != root) {
        const next: u32 = parent[cur];
        parent[cur] = root;
        cur = next;
    }
    return root;
}

/// Merge the islands containing `a` and `b`, attaching the higher-indexed root under the
/// lower one (a stable, deterministic tie-break).
fn dsuUnion(parent: []u32, a: u32, b: u32) void {
    const ra: u32 = dsuFind(parent, a);
    const rb: u32 = dsuFind(parent, b);
    if (ra != rb) {
        parent[@max(ra, rb)] = @min(ra, rb);
    }
}

/// The conservative speed used for the sleep test: the linear speed plus the rim speed
/// from rotation (so a fast-spinning body never sleeps), combined with the speed implied
/// by this step's position correction (TGS can move a body even at low velocity). The
/// position term is weighted down because it matters less than true motion for sleep.
/// box2d: the maxVelocity/sleepVelocity block in solver.c:598
fn sleepVelocity(
    v: Vec2,
    w: f32,
    max_extent: f32,
    delta_position: Vec2,
    delta_rotation: Rot2,
    inv_dt: f32,
) f32 {
    const max_velocity: f32 = length2(v) + @abs(w) * max_extent;
    const max_delta_position: f32 = length2(delta_position) + @abs(delta_rotation.sine) * max_extent;
    const position_sleep_factor: f32 = 0.5;
    return @max(max_velocity, position_sleep_factor * inv_dt * max_delta_position);
}

/// Given a union-find already populated with the dynamic contact/joint edges, decide
/// which active bodies fall asleep. An island sleeps only if *every* dynamic member is
/// eligible (dynamic, sleeping permitted, and `sleep_time >= time_to_sleep`); a single
/// ineligible member keeps the whole island awake. `island_can_sleep` is body-indexed
/// scratch (only root slots are used). Kinematic bodies are never eligible, so their
/// singleton islands stay awake.
fn aggregateAndMarkSleep(
    active: []const BodyIndex,
    bodies: []const Body,
    parent: []u32,
    island_can_sleep: []bool,
    time_to_sleep: f32,
    out_sleep: []bool,
) void {
    // Pass 1: every island seen is provisionally sleepable.
    for (active) |b| {
        island_can_sleep[dsuFind(parent, b)] = true;
    }
    // Pass 2: veto any island that contains an ineligible body.
    for (active) |b| {
        const body: *const Body = &bodies[b];
        const eligible: bool =
            body.motion_type == .dynamic and body.flags.enable_sleep and body.sleep_time >= time_to_sleep;
        if (eligible == false) {
            island_can_sleep[dsuFind(parent, b)] = false;
        }
    }
    // Pass 3: a body sleeps iff its island survived the veto.
    for (active) |b| {
        out_sleep[b] = island_can_sleep[dsuFind(parent, b)];
    }
}

// ================================================================================
// Continuous collision (CCD) - pure helpers
//
// Most of CCD is World-coupled (it sweeps a fast body's shapes against the broad-phase
// trees and clamps the body to its earliest time of impact), so the driver lives with
// the World in a later section. The geometry-only pieces live here: building the sweep
// a body traced this step, and the gate that decides whether a body moved far enough to
// need the sweep at all. The time-of-impact solver itself is already in the distance
// section. box2d: solver.c b2SolveContinuous + the b2_isFast gate at solver.c:639
// ================================================================================

/// The sweep a body traced over this step, re-centered on `base` (the body's start COM)
/// so the time-of-impact math stays in good float precision near the origin.
/// box2d: b2MakeRelativeSweep
fn makeRelativeSweep(body: *const Body, base: Vec2) Sweep2 {
    return .{
        .local_center = body.local_center,
        .c1 = body.center0 - base,
        .c2 = body.center - base,
        .q1 = body.rot0,
        .q2 = body.transform.q,
    };
}

/// The fraction of a body's core extent used as the fallback TOI radius when a sweep
/// reports an immediate (t == 0) impact. box2d: B2_CORE_FRACTION  solver.c:180
pub const core_fraction: f32 = 0.25;

// ================================================================================
// Sensors - data model
//
// Sensors never produce solver contacts; they are resolved in a separate overlap pass
// that runs after the step (querying the broad phase for each sensor shape and diffing
// this step's overlap set against last step's to emit begin/end touch events). That
// pass is World-coupled and lives with the World. Here we define only the storage.
// A `Visitor` carries the overlapping shape plus the generation it was seen at, so a
// destroyed-and-recycled shape slot can't be mistaken for a still-present visitor.
// box2d: b2Sensor / b2Visitor  sensor.h
// ================================================================================

/// One shape currently (or previously) overlapping a sensor.
const Visitor = struct {
    shape: ShapeIndex,
    generation: u16,
};

/// A sensor shape and its overlap sets. `overlaps[current]` is built fresh during the
/// overlap pass; `overlaps[current ^ 1]` holds last pass's set so the two can be diffed
/// (sorted by shape index) into begin/end events. `current` flips each pass.
const Sensor = struct {
    shape: ShapeIndex,
    overlaps: [2]std.ArrayListUnmanaged(Visitor) = .{ .empty, .empty },
    current: u1 = 0,

    fn deinit(self: *Sensor, gpa: Allocator) void {
        self.overlaps[0].deinit(gpa);
        self.overlaps[1].deinit(gpa);
    }
};

// ================================================================================
// Events
//
// The world records what happened during a step so the application can react after it
// returns. Events reference shapes by their stable shape index and contacts by id (we
// keep the integer handles rather than Box2D's opaque {index, world, generation} ids,
// since this is a single-world embedding). "Begin", "hit", "move", and "sensor-begin"
// events are single-buffered: cleared at the start of a step, filled during it, read
// after. "End" events are double-buffered and swapped each step, because a contact can
// end not only during the narrow phase but also when a body or shape is destroyed
// between steps - the extra buffer keeps those until the next read without being wiped.
// box2d: the b2*Event structs in types.h + the world event buffers
// ================================================================================

pub const ContactBeginTouchEvent = struct {
    shape_a: ShapeIndex,
    shape_b: ShapeIndex,
    contact_id: u32,
};

pub const ContactEndTouchEvent = struct {
    shape_a: ShapeIndex,
    shape_b: ShapeIndex,
    contact_id: u32,
};

/// Reported when two shapes collide hard enough (approach speed over the hit-event
/// threshold). `point` and `normal` are in world space; `approach_speed` is the
/// closing speed along the normal at the moment of impact.
pub const ContactHitEvent = struct {
    shape_a: ShapeIndex,
    shape_b: ShapeIndex,
    contact_id: u32,
    point: Vec2,
    normal: Vec2,
    approach_speed: f32,
};

pub const SensorBeginTouchEvent = struct {
    sensor_shape: ShapeIndex,
    visitor_shape: ShapeIndex,
};

pub const SensorEndTouchEvent = struct {
    sensor_shape: ShapeIndex,
    visitor_shape: ShapeIndex,
};

/// Emitted once per moved body each step, so the application can sync transforms without
/// polling every body. `fell_asleep` flags the bodies that went to sleep this step.
pub const BodyMoveEvent = struct {
    transform: Transform2,
    body: BodyIndex,
    user_data: u64,
    fell_asleep: bool,
};

/// Emitted once per step for each joint whose reaction force or torque met or exceeded
/// its configured threshold during the solve. Lets the application react to (or break)
/// overstressed joints. box2d: b2JointEvent
pub const JointEvent = struct {
    joint: u32, // joint id (index into world.joints)
    user_data: u64,
};

/// The world's per-step event accumulators. Single-buffered streams are cleared at the
/// start of each step; the two end-touch streams are double-buffered and swapped so that
/// end events generated by inter-step destruction survive until the next read.
pub const EventBuffers = struct {
    contact_begin: std.ArrayListUnmanaged(ContactBeginTouchEvent) = .empty,
    contact_hit: std.ArrayListUnmanaged(ContactHitEvent) = .empty,
    sensor_begin: std.ArrayListUnmanaged(SensorBeginTouchEvent) = .empty,
    body_move: std.ArrayListUnmanaged(BodyMoveEvent) = .empty,
    joint_events: std.ArrayListUnmanaged(JointEvent) = .empty,
    contact_end: [2]std.ArrayListUnmanaged(ContactEndTouchEvent) = .{ .empty, .empty },
    sensor_end: [2]std.ArrayListUnmanaged(SensorEndTouchEvent) = .{ .empty, .empty },
    end_current: u1 = 0,

    fn deinit(self: *EventBuffers, gpa: Allocator) void {
        self.contact_begin.deinit(gpa);
        self.contact_hit.deinit(gpa);
        self.sensor_begin.deinit(gpa);
        self.body_move.deinit(gpa);
        self.joint_events.deinit(gpa);
        self.contact_end[0].deinit(gpa);
        self.contact_end[1].deinit(gpa);
        self.sensor_end[0].deinit(gpa);
        self.sensor_end[1].deinit(gpa);
    }

    /// Start a fresh step: clear the single-buffered streams and swap the end-touch
    /// double buffers so the new current buffer starts empty while the previous one
    /// (now readable as "last step's end events") is retained until its next turn.
    fn beginStep(self: *EventBuffers) void {
        self.contact_begin.clearRetainingCapacity();
        self.contact_hit.clearRetainingCapacity();
        self.sensor_begin.clearRetainingCapacity();
        self.body_move.clearRetainingCapacity();
        self.joint_events.clearRetainingCapacity();
    }

    /// Swap the double-buffered end-event lists at the close of a step: events written
    /// this step (into `end[end_current]`) become readable as `end[end_current ^ 1]`,
    /// and the freshly current buffer is cleared to receive next step's (and any
    /// between-step) end events. box2d flips endEventArrayIndex at the end of the step.
    fn endStep(self: *EventBuffers) void {
        self.end_current ^= 1;
        self.contact_end[self.end_current].clearRetainingCapacity();
        self.sensor_end[self.end_current].clearRetainingCapacity();
    }

    /// The end-touch buffer currently being written to (during the step and during
    /// inter-step destruction).
    fn contactEnd(self: *EventBuffers) *std.ArrayListUnmanaged(ContactEndTouchEvent) {
        return &self.contact_end[self.end_current];
    }

    fn sensorEnd(self: *EventBuffers) *std.ArrayListUnmanaged(SensorEndTouchEvent) {
        return &self.sensor_end[self.end_current];
    }
};

// ================================================================================
// World - the container and its lifecycle
//
// The World owns every body, shape, contact, joint, and sensor, plus the broad phase,
// the per-step solver side-tables, and the event buffers. Bodies and the other entity
// kinds live in stable-index pools (entities.zig): a body's pool slot index *is* its
// BodyIndex, so the solver can address bodies, motion, and state through plain parallel
// arrays. `motion` and `state` are side-tables sized to the body capacity and indexed by
// BodyIndex; static and sleeping bodies simply keep zero velocity / identity state, so
// constraints can reference them without a null branch.
// box2d: b2World + the body/shape/contact/joint lifecycle across {body,shape,contact,joint}.c
// ================================================================================

/// One shape instance in the world: its geometry, the body it rides on, surface/filter
/// properties, the cached broad-phase bounds and proxy, and its link in the owning
/// body's intrusive shape list. The shape's pool slot index is its ShapeIndex.
/// box2d: b2Shape  shape.h
pub const Shape = struct {
    geom: Geometry,
    body: BodyIndex,
    material: SurfaceMaterial = .{},
    filter: Filter = .{},
    density: f32 = 1.0,
    aabb: Aabb2 = .{ .lower = .{ 0, 0 }, .upper = .{ 0, 0 } }, // tight world AABB
    fat_aabb: Aabb2 = .{ .lower = .{ 0, 0 }, .upper = .{ 0, 0 } }, // enlarged AABB stored in the tree
    local_centroid: Vec2 = .{ 0, 0 }, // centroid in the body-origin frame (for CCD)
    aabb_margin: f32 = 0, // adaptive broad-phase margin, computed at creation
    proxy_key: u32 = null_index, // broad-phase proxy key ((proxyId << 2) | bodyType)
    next_shape: u32 = null_index, // next shape in the owning body's list
    prev_shape: u32 = null_index, // previous shape (doubly-linked, for O(1) removal)
    sensor_index: u32 = null_index, // index into world.sensors, or null_index if solid
    enable_contact_events: bool = true,
    enable_sensor_events: bool = true,
    enable_pre_solve: bool = false,
    enable_custom_filtering: bool = false,
    enable_hit_events: bool = false,
    user_data: u64 = 0,
};

/// Stable-index pools. A pool slot index doubles as the entity's stable id, which the
/// intrusive edge lists (contacts/joints) and the broad-phase proxies refer to.
pub const Bodies = entities.Entities(Body);
pub const Shapes = entities.Entities(Shape);
pub const Joints = entities.Entities(Joint);

pub const BodyHandle = entities.Handle(Body);
pub const ShapeHandle = entities.Handle(Shape);
pub const JointHandle = entities.Handle(Joint);

/// A plain growable pool of contacts with a manual free list - no generational handles and no
/// parallel ECS archetype. Contacts are referenced only by integer id (never by a handle held
/// across frames; the public API takes and returns a `u32` contact_id) and carry no secondary
/// components, so the ECS machinery the other pools use was pure overhead on the hot
/// create/destroy path that dominates dense-pile broad-phase churn. This mirrors box2d's
/// b2IdPool + contact array: `alloc` pops a freed id or bumps `next_index`; `free` pushes the id
/// back. alloc/free are now an array write plus a free-list push/pop, not an archetype reserve.
/// box2d: b2IdPool (id_pool.c) + b2ContactArray.
const ContactPool = struct {
    /// Backing store; `data[id]` is live for every allocated, unfreed id. Freed slots keep stale
    /// bytes that are never read until the id is handed back out by `alloc`.
    data: []Contact,
    /// Ids returned by `free`, available for reuse (box2d: b2IdPool.freeArray). Its capacity is
    /// held >= `data.len`, so `free` never allocates - you cannot free more ids than slots exist.
    free_list: std.ArrayListUnmanaged(u32) = .empty,
    /// High-water mark: the next never-before-used id (box2d: b2IdPool.nextIndex).
    next_index: u32 = 0,

    fn init(gpa: Allocator, capacity: u32) Allocator.Error!ContactPool {
        const data: []Contact = try gpa.alloc(Contact, capacity);
        errdefer gpa.free(data);
        var free_list: std.ArrayListUnmanaged(u32) = .empty;
        try free_list.ensureTotalCapacity(gpa, capacity);
        return .{ .data = data, .free_list = free_list };
    }

    fn deinit(self: *ContactPool, gpa: Allocator) void {
        gpa.free(self.data);
        self.free_list.deinit(gpa);
        self.* = undefined;
    }

    /// Ensure the backing store (and the free-list capacity shadowing it) holds at least
    /// `min_capacity` slots. box2d grows its contact array the same way on demand.
    fn grow(
        self: *ContactPool,
        gpa: Allocator,
        min_capacity: u32,
    ) Allocator.Error!void {
        if (min_capacity <= self.data.len) {
            return;
        }
        self.data = try gpa.realloc(self.data, min_capacity);
        try self.free_list.ensureTotalCapacity(gpa, min_capacity);
    }

    /// Reserve a slot, store `value`, and return its id - reusing a freed id when one exists,
    /// otherwise bumping `next_index` and growing (amortised doubling) past capacity.
    /// box2d: b2AllocId + the contact-array grow in b2CreateContact.
    fn alloc(
        self: *ContactPool,
        gpa: Allocator,
        value: Contact,
    ) Allocator.Error!u32 {
        if (self.free_list.pop()) |id| {
            self.data[id] = value;
            return id;
        }
        const id: u32 = self.next_index;
        const cur_cap: u32 = @intCast(self.data.len);
        if (id >= cur_cap) {
            try self.grow(gpa, @max(cur_cap *| 2, id + 1));
        }
        self.next_index += 1;
        self.data[id] = value;
        return id;
    }

    /// Return an id to the free list for reuse. Never allocates (free-list capacity is kept >= the
    /// slot count). box2d: b2FreeId.
    fn free(self: *ContactPool, id: u32) void {
        self.free_list.appendAssumeCapacity(id);
    }

    /// Number of live contacts (allocated ids not currently freed). box2d: b2GetIdCount.
    pub fn count(self: *const ContactPool) u32 {
        return self.next_index - @as(u32, @intCast(self.free_list.items.len));
    }
};

// -- Constraint graph coloring ---------------------------------------------------
//
// To let the solver process constraints in wide (SIMD) batches, contacts and joints are
// partitioned into "colors" such that within one color no two constraints touch the same
// dynamic body. Constraints in a color can then be solved independently - four at a time in
// @Vector lanes - because each writes a distinct body's velocity. Static and kinematic
// bodies are never written, so they may appear any number of times in a color and get no
// usage bit. Constraints that cannot fit any color land in the overflow color, solved
// scalar. This is the per-step batch form of box2d's persistent constraint graph.
// box2d: constraint_graph.{h,c}
const graph_color_count: u32 = 24; // box2d B2_GRAPH_COLOR_COUNT
const graph_overflow_index: u32 = graph_color_count - 1; // last color is the overflow bucket
const graph_dynamic_color_count: u32 = graph_color_count - 4; // dynamic-dynamic try these first

/// Per-step coloring scratch: a body-usage bitset per color plus the color boundaries of
/// the (color-sorted) contact and joint arrays. The bitsets are sized to body capacity and
/// cleared at the start of each coloring pass. box2d: b2ConstraintGraph
const ConstraintGraph = struct {
    body_bits: []u64, // graph_color_count * words_per_color, indexed [color][body word]
    words_per_color: u32,
    contact_color_begin: [graph_color_count + 1]u32 = std.mem.zeroes([graph_color_count + 1]u32),
    joint_color_begin: [graph_color_count + 1]u32 = std.mem.zeroes([graph_color_count + 1]u32),

    fn clearBits(self: *ConstraintGraph) void {
        @memset(self.body_bits, 0);
    }
    fn getBit(self: *const ConstraintGraph, color: u32, body: BodyIndex) bool {
        const word: usize = color * self.words_per_color + (body >> 6);
        return (self.body_bits[word] & (@as(u64, 1) << @intCast(body & 63))) != 0;
    }
    fn setBit(self: *ConstraintGraph, color: u32, body: BodyIndex) void {
        const word: usize = color * self.words_per_color + (body >> 6);
        self.body_bits[word] |= (@as(u64, 1) << @intCast(body & 63));
    }
    /// Greedily assign a color to a constraint between two bodies, marking the dynamic
    /// endpoints used in that color. box2d: the color search in b2AddContactToGraph
    fn assign(
        self: *ConstraintGraph,
        body_a: BodyIndex,
        body_b: BodyIndex,
        type_a: MotionType,
        type_b: MotionType,
    ) u32 {
        if (type_a == .dynamic and type_b == .dynamic) {
            var c: u32 = 0;
            while (c < graph_dynamic_color_count) : (c += 1) {
                if (self.getBit(c, body_a) or self.getBit(c, body_b)) {
                    continue;
                }
                self.setBit(c, body_a);
                self.setBit(c, body_b);
                return c;
            }
        } else if (type_a == .dynamic) {
            var c: u32 = graph_overflow_index - 1;
            while (c >= 1) : (c -= 1) {
                if (self.getBit(c, body_a)) {
                    continue;
                }
                self.setBit(c, body_a);
                return c;
            }
        } else if (type_b == .dynamic) {
            var c: u32 = graph_overflow_index - 1;
            while (c >= 1) : (c -= 1) {
                if (self.getBit(c, body_b)) {
                    continue;
                }
                self.setBit(c, body_b);
                return c;
            }
        }
        return graph_overflow_index;
    }
};

/// Reallocate a body-indexed side table to `new_len`, preserving existing entries and filling the
/// new tail with `fill` (the value `World.init` seeds for that table). Used by `World.growBodies`.
fn regrowFill(
    comptime T: type,
    gpa: Allocator,
    old: []T,
    new_len: u32,
    fill: T,
) Allocator.Error![]T {
    const new_slice: []T = try gpa.alloc(T, new_len);
    @memcpy(new_slice[0..old.len], old);
    for (new_slice[old.len..]) |*e| {
        e.* = fill;
    }
    gpa.free(old);
    return new_slice;
}

/// Like `regrowFill` but for per-step scratch tables (`island_*`, `body_sleep`) that `World.init`
/// leaves uninitialised - the new tail is left undefined, matching init, since these are written
/// before they are read each step.
fn regrowScratch(
    comptime T: type,
    gpa: Allocator,
    old: []T,
    new_len: u32,
) Allocator.Error![]T {
    const new_slice: []T = try gpa.alloc(T, new_len);
    @memcpy(new_slice[0..old.len], old);
    gpa.free(old);
    return new_slice;
}

pub const World = struct {
    bodies: Bodies,
    motion: []Motion, // velocity + solver inverse mass + applied force, by BodyIndex
    state: []BodyState, // per-step TGS deltas + flags, by BodyIndex (identity when at rest)
    shapes: Shapes,
    contacts: ContactPool,
    joints: Joints,
    contact_ids: std.ArrayListUnmanaged(u32) = .empty, // dense list of live contact ids
    joint_ids: std.ArrayListUnmanaged(u32) = .empty, // dense list of live joint ids
    sensors: std.ArrayListUnmanaged(Sensor) = .empty,

    /// Awake movable bodies (dynamic and kinematic). The solver and integration walk
    /// this list; everything else is left untouched until something wakes it.
    active: std.ArrayListUnmanaged(BodyIndex) = .empty,

    broadphase: BroadPhase = .{},

    // Per-step island/sleep scratch, all indexed by BodyIndex (only relevant slots used).
    island_parent: []u32, // union-find over the dynamic contact/joint graph
    island_can_sleep: []bool, // per-root: every member passed the sleep test
    body_sleep: []bool, // per-body: this body falls asleep this step

    settings: Settings = .{},
    narrow_phase: NarrowPhaseConfig = .{},
    events: EventBuffers = .{},

    allocator: Allocator,
    capacity: u32,
    /// Inverse sub-step duration from the most recent step, cached so impulse-derived
    /// reaction forces (motor torque, constraint force) can be reported between steps.
    inv_h: f32 = 0,
    /// Inverse full-step duration from the most recent step, cached for debug-draw of
    /// contact forces (which average accumulated impulse over the whole step).
    inv_dt: f32 = 0,
    /// Monotonic id handed to each chain so its segments can be grouped and destroyed
    /// together. box2d: b2World.chainIdPool
    next_chain_id: u32 = 0,
    /// Per-step constraint-graph coloring scratch (bitsets + color boundaries).
    graph: ConstraintGraph,
    /// Solve non-overflow contact colors with the wide (SIMD) kernels. Toggleable so the
    /// scalar path can be exercised for differential testing; on by default.
    enable_simd: bool = true,
    /// Rebuild the dynamic broad-phase tree every this many steps to recover query quality
    /// lost to incremental insertion (0 disables the automatic rebuild). box2d rebuilds
    /// continuously in small increments; here it is a periodic full rebuild. Default 8: refit
    /// enlarges proxies in place (cheap) and lets internal bounds loosen, so a periodic rebuild
    /// is what keeps query traversal tight.
    tree_rebuild_interval: u32 = 8,
    /// Steps taken so far, used to schedule the periodic tree rebuild.
    step_count: u64 = 0,
    /// Per-step scratch arena. Every transient solver buffer (the touching-contact list,
    /// the contact-constraint array, the graph-coloring scratch) is allocated here and
    /// reclaimed wholesale by a single `reset(.retain_capacity)` at the top of each step.
    /// After the first few steps the arena has grown to the peak working-set size and no
    /// further allocation reaches the backing allocator - which is what keeps step cost flat
    /// as the contact count climbs on the wasm allocator, where per-step alloc/free of
    /// contact-sized arrays was previously the dominant cost.
    step_arena: FrameArena,

    /// Create a world sized for up to `capacity` bodies (and, here, the same number of
    /// shapes, contacts, and joints). Side-tables are allocated up front and never grow,
    /// matching the fixed-capacity discipline of the entity pools.
    pub fn init(gpa: Allocator, capacity: u32) !World {
        var bodies: Bodies = try .init(gpa, .{ .capacity = capacity });
        errdefer bodies.deinit(gpa);
        var shapes: Shapes = try .init(gpa, .{ .capacity = capacity });
        errdefer shapes.deinit(gpa);
        // Contacts are NOT one-per-body: a dense 2D pile produces several contacts per body (a
        // hexagonal pack is ~3x, and speculative fat-AABB pairs push it higher), so a contact pool
        // sized to the body count overflows mid-step in dense scenes like Benchmark|Capacity - and
        // because the pool is fixed, the overflowing spawn errors and aborts the whole step, freezing
        // the world. box2d grows contact storage on demand; with fixed pools we provision generous
        // headroom up front instead. Six contacts per body covers a maximally dense pack at full
        // body capacity with margin. (224 B each, so even at large capacities this stays modest.)
        const contact_capacity: u32 = capacity *| 6;
        var contacts: ContactPool = try .init(gpa, contact_capacity);
        errdefer contacts.deinit(gpa);
        var joints: Joints = try .init(gpa, .{ .capacity = capacity });
        errdefer joints.deinit(gpa);

        const motion: []Motion = try gpa.alloc(Motion, capacity);
        errdefer gpa.free(motion);
        for (motion) |*m| {
            m.* = Motion.zero;
        }

        const state: []BodyState = try gpa.alloc(BodyState, capacity);
        errdefer gpa.free(state);
        for (state) |*s| {
            s.* = BodyState.identity;
        }

        const island_parent: []u32 = try gpa.alloc(u32, capacity);
        errdefer gpa.free(island_parent);
        const island_can_sleep: []bool = try gpa.alloc(bool, capacity);
        errdefer gpa.free(island_can_sleep);
        const body_sleep: []bool = try gpa.alloc(bool, capacity);
        errdefer gpa.free(body_sleep);

        // Reserve the active list up front so waking a body (which may happen from
        // void contexts like destroyBody) never needs to allocate.
        var active: std.ArrayListUnmanaged(BodyIndex) = .empty;
        try active.ensureTotalCapacity(gpa, capacity);
        errdefer active.deinit(gpa);

        // Constraint-graph coloring bitsets: one body-usage word array per color.
        const words_per_color: u32 = (capacity + 63) / 64;
        const body_bits: []u64 = try gpa.alloc(u64, graph_color_count * words_per_color);
        errdefer gpa.free(body_bits);

        return .{
            .active = active,
            .bodies = bodies,
            .motion = motion,
            .state = state,
            .shapes = shapes,
            .contacts = contacts,
            .joints = joints,
            .island_parent = island_parent,
            .island_can_sleep = island_can_sleep,
            .body_sleep = body_sleep,
            .graph = .{ .body_bits = body_bits, .words_per_color = words_per_color },
            .allocator = gpa,
            .capacity = capacity,
            .step_arena = FrameArena.init(gpa, step_arena_ceiling, "physics2d.step"),
        };
    }

    /// Free everything the world owns. After this the world is invalid.
    /// Grow the shape pool. Shapes carry no World-side parallel arrays and the broad-phase tree is
    /// already a dynamic ArrayList, so this is just the pool (and its ECS handle table).
    pub fn growShapes(world: *World, min_capacity: u32) Allocator.Error!void {
        const old: u32 = @intCast(world.shapes.data.len);
        if (min_capacity <= old) {
            return;
        }
        try world.shapes.grow(world.allocator, @max(old *| 2, min_capacity));
    }

    /// Grow the contact pool. `contact_ids` is a dense ArrayList that grows itself; constraint
    /// scratch is per-step arena. So this is just the pool.
    pub fn growContacts(world: *World, min_capacity: u32) Allocator.Error!void {
        const old: u32 = @intCast(world.contacts.data.len);
        if (min_capacity <= old) {
            return;
        }
        try world.contacts.grow(world.allocator, @max(old *| 2, min_capacity));
    }

    /// Grow the joint pool. `joint_ids` grows itself.
    pub fn growJoints(world: *World, min_capacity: u32) Allocator.Error!void {
        const old: u32 = @intCast(world.joints.data.len);
        if (min_capacity <= old) {
            return;
        }
        try world.joints.grow(world.allocator, @max(old *| 2, min_capacity));
    }

    /// Grow the body pool AND every body-indexed side table in lockstep. `motion`/`state` get their
    /// init defaults for the new entries; `island_*`/`body_sleep` are per-step scratch (written
    /// before read) so they are left uninitialised like at init; `body_bits` is per-step scratch
    /// (cleared each step) so it is only resized and `words_per_color` updated. The body pool and its
    /// ECS handle table grow in lockstep via `bodies.grow`.
    pub fn growBodies(world: *World, min_capacity: u32) Allocator.Error!void {
        const gpa: Allocator = world.allocator;
        const old_cap: u32 = @intCast(world.bodies.data.len);
        if (min_capacity <= old_cap) {
            return;
        }
        const new_cap: u32 = @max(old_cap *| 2, min_capacity);

        try world.bodies.grow(gpa, new_cap);

        world.motion = try regrowFill(Motion, gpa, world.motion, new_cap, Motion.zero);
        world.state = try regrowFill(BodyState, gpa, world.state, new_cap, BodyState.identity);
        world.island_parent = try regrowScratch(u32, gpa, world.island_parent, new_cap);
        world.island_can_sleep = try regrowScratch(bool, gpa, world.island_can_sleep, new_cap);
        world.body_sleep = try regrowScratch(bool, gpa, world.body_sleep, new_cap);
        try world.active.ensureTotalCapacity(gpa, new_cap);

        const new_wpc: u32 = (new_cap + 63) / 64;
        const new_bits: []u64 = try gpa.alloc(u64, graph_color_count * new_wpc);
        gpa.free(world.graph.body_bits);
        world.graph.body_bits = new_bits;
        world.graph.words_per_color = new_wpc;

        world.capacity = new_cap;
    }

    pub fn deinit(world: *World, gpa: Allocator) void {
        for (world.sensors.items) |*sensor| {
            sensor.deinit(gpa);
        }
        world.sensors.deinit(gpa);
        world.active.deinit(gpa);
        world.contact_ids.deinit(gpa);
        world.joint_ids.deinit(gpa);
        world.broadphase.deinit(gpa);
        world.events.deinit(gpa);
        world.bodies.deinit(gpa);
        world.shapes.deinit(gpa);
        world.contacts.deinit(gpa);
        world.joints.deinit(gpa);
        gpa.free(world.motion);
        gpa.free(world.state);
        gpa.free(world.island_parent);
        gpa.free(world.island_can_sleep);
        gpa.free(world.body_sleep);
        gpa.free(world.graph.body_bits);
        world.step_arena.deinit();
    }
};

// -- Body & shape lifecycle ------------------------------------------------------

/// Expand an AABB outward by a uniform margin.
fn expandAabb(aabb: Aabb2, margin: f32) Aabb2 {
    const m: Vec2 = splat2(margin);
    return .{ .lower = aabb.lower - m, .upper = aabb.upper + m };
}

/// Recompute a body's mass, center of mass, rotational inertia, and extents from its
/// shapes. Static and kinematic bodies have no solver mass (only extents, and only
/// kinematic needs them). For a dynamic body: the COM is the mass-weighted average of
/// the shapes' centroids; the inertia about that COM is each shape's own inertia plus a
/// parallel-axis term; and because the COM may shift, the linear velocity is corrected
/// so the velocity *at the old COM* is preserved. Shapes are visited twice rather than
/// caching per-shape mass in a scratch array (box2d stack-allocs it); the result is
/// identical. box2d: b2UpdateBodyMassData  body.c:526
pub fn updateBodyMassData(world: *World, body_index: BodyIndex) void {
    const body: *Body = &world.bodies.data[body_index];
    const motion: *Motion = &world.motion[body_index];

    body.mass = 0;
    body.inertia = 0;
    motion.inverse_mass = 0;
    motion.inverse_inertia = 0;
    body.local_center = .{ 0, 0 };
    body.min_extent = huge_length;
    body.max_extent = 0;

    // Static/kinematic: no solver mass. COM is the body origin; only kinematic bodies
    // need extents (for their CCD against dynamic bodies).
    if (body.motion_type != .dynamic) {
        body.center = body.transform.p;
        body.center0 = body.center;
        if (body.motion_type == .kinematic) {
            var sid: u32 = body.head_shape;
            while (sid != null_index) {
                const s: *const Shape = &world.shapes.data[sid];
                const extent: ShapeExtent = computeShapeExtent(s.geom, .{ 0, 0 });
                body.min_extent = @min(body.min_extent, extent.min_extent);
                body.max_extent = @max(body.max_extent, extent.max_extent);
                sid = s.next_shape;
            }
        }
        return;
    }

    // Dynamic: accumulate total mass and the mass-weighted centroid.
    var local_center: Vec2 = .{ 0, 0 };
    var sid: u32 = body.head_shape;
    while (sid != null_index) {
        const s: *const Shape = &world.shapes.data[sid];
        if (s.density > 0.0) {
            const md: MassData = computeShapeMass(s.geom, s.density);
            body.mass += md.mass;
            local_center = mulAdd2(local_center, md.mass, md.center);
        }
        sid = s.next_shape;
    }
    if (body.mass > 0.0) {
        motion.inverse_mass = 1.0 / body.mass;
        local_center = local_center * splat2(motion.inverse_mass);
    }

    // Inertia about the COM: each shape's own inertia plus mass * distance^2 to the COM.
    sid = body.head_shape;
    while (sid != null_index) {
        const s: *const Shape = &world.shapes.data[sid];
        if (s.density > 0.0) {
            const md: MassData = computeShapeMass(s.geom, s.density);
            const offset: Vec2 = local_center - md.center;
            body.inertia += md.rotational_inertia + md.mass * dot2(offset, offset);
        }
        sid = s.next_shape;
    }
    // The rotation lock is enforced in integratePositions, not by zeroing inertia here.
    if (body.inertia > 0.0) {
        motion.inverse_inertia = 1.0 / body.inertia;
    } else {
        body.inertia = 0;
        motion.inverse_inertia = 0;
    }

    // Shift the world COM to the new local center, and correct linear velocity so the
    // velocity of the point that *was* the COM is unchanged by the recentering.
    const old_center: Vec2 = body.center;
    body.local_center = local_center;
    body.center = transformPoint2(body.transform, local_center);
    body.center0 = body.center;
    const delta_linear: Vec2 = crossSV2(motion.angular_velocity, body.center - old_center);
    motion.linear_velocity = motion.linear_velocity + delta_linear;

    // Extents are measured from the COM.
    sid = body.head_shape;
    while (sid != null_index) {
        const s: *const Shape = &world.shapes.data[sid];
        const extent: ShapeExtent = computeShapeExtent(s.geom, local_center);
        body.min_extent = @min(body.min_extent, extent.min_extent);
        body.max_extent = @max(body.max_extent, extent.max_extent);
        sid = s.next_shape;
    }
}

/// Parameters for creating a body. box2d: b2BodyDef  types.h
pub const BodyDef = struct {
    motion_type: MotionType = .static,
    position: Vec2 = .{ 0, 0 },
    rotation: Rot2 = Rot2.identity,
    linear_velocity: Vec2 = .{ 0, 0 },
    angular_velocity: f32 = 0,
    linear_damping: f32 = 0,
    angular_damping: f32 = 0,
    gravity_scale: f32 = 1,
    sleep_threshold: f32 = 0.05, // m/s; box2d default
    enable_sleep: bool = true,
    is_awake: bool = true,
    motion_quality: MotionQuality = .discrete,
    allowed_dofs: AllowedDofs = .{},
    allow_fast_rotation: bool = false,
    user_data: u64 = 0,
};

/// Create a body and register it in the world. A movable, awake body joins the active
/// list; a static or initially-sleeping body does not. Mass is left at zero until shapes
/// are added (each `createShape` recomputes it). box2d: b2CreateBody  body.c
pub fn createBody(world: *World, def: BodyDef) !BodyHandle {
    const transform: Transform2 = .{ .p = def.position, .q = def.rotation };
    const is_active: bool = def.motion_type != .static and def.is_awake;

    var flags: BodyFlags = .{};
    flags.enable_sleep = def.enable_sleep;
    flags.is_bullet = def.motion_quality == .linear_cast;
    flags.lock_linear_x = def.allowed_dofs.translation_x == false;
    flags.lock_linear_y = def.allowed_dofs.translation_y == false;
    flags.lock_angular_z = def.allowed_dofs.rotation_z == false;
    flags.allow_fast_rotation = def.allow_fast_rotation;

    const body: Body = .{
        .transform = transform,
        .center = transform.p,
        .center0 = transform.p,
        .rot0 = transform.q,
        .local_center = .{ 0, 0 },
        .min_extent = huge_length,
        .max_extent = 0,
        .mass = 0,
        .inertia = 0,
        .sleep_threshold = def.sleep_threshold,
        .sleep_time = 0,
        .motion_type = def.motion_type,
        .flags = flags,
        .asleep = def.motion_type != .static and def.is_awake == false,
        .head_shape = null_index,
        .shape_count = 0,
        .head_contact = null_index,
        .contact_count = 0,
        .head_joint = null_index,
        .joint_count = 0,
        .user_data = def.user_data,
    };
    const handle: BodyHandle = world.bodies.spawn(world.allocator, body) catch |err| blk: {
        // Pool full: grow (amortised doubling) and retry, so the world behaves like a
        // growable container rather than a fixed cap. A non-capacity error (true OOM) still
        // propagates. growBodies.grow lifts the pool + its ECS handle table (and, for bodies, every
        // body-indexed side table) in lockstep.
        if (err != error.PoolExhausted) {
            return err;
        }
        try world.growBodies(@intCast(world.bodies.data.len + 1));
        break :blk try world.bodies.spawn(world.allocator, body);
    };
    const index: BodyIndex = handle.index();

    const at_rest: bool = def.motion_type == .static;
    world.motion[index] = .{
        .linear_velocity = if (at_rest) .{ 0, 0 } else def.linear_velocity,
        .angular_velocity = if (at_rest) 0 else def.angular_velocity,
        .inverse_mass = 0,
        .inverse_inertia = 0,
        .linear_damping = def.linear_damping,
        .angular_damping = def.angular_damping,
        .gravity_scale = def.gravity_scale,
        .force = .{ 0, 0 },
        .torque = 0,
    };

    var sflags: StateFlags = .{};
    sflags.dynamic = def.motion_type == .dynamic;
    sflags.lock_x = def.allowed_dofs.translation_x == false;
    sflags.lock_y = def.allowed_dofs.translation_y == false;
    sflags.lock_w = def.allowed_dofs.rotation_z == false;
    sflags.allow_fast_rotation = def.allow_fast_rotation;
    world.state[index] = .{ .delta_position = .{ 0, 0 }, .delta_rotation = Rot2.identity, .flags = sflags };

    if (is_active) {
        world.active.appendAssumeCapacity(index);
    }
    return handle;
}

/// Parameters for creating a shape on a body. box2d: b2ShapeDef  types.h
pub const ShapeDef = struct {
    geom: Geometry,
    material: SurfaceMaterial = .{},
    filter: Filter = .{},
    density: f32 = 1.0,
    is_sensor: bool = false,
    enable_contact_events: bool = true,
    enable_sensor_events: bool = true,
    enable_pre_solve: bool = false,
    enable_custom_filtering: bool = false,
    enable_hit_events: bool = false,
    invoke_contact_creation: bool = true, // force a broad-phase pair even against statics
    update_body_mass: bool = true, // recompute the body's mass when this shape is added (clear for compounds)
    user_data: u64 = 0,
};

/// Attach a shape to a body: build its bounds, register a broad-phase proxy, splice it
/// into the body's shape list, register it as a sensor if requested, and recompute the
/// body's mass. box2d: b2CreateShape  shape.c:209
pub fn createShape(world: *World, body_handle: BodyHandle, def: ShapeDef) !ShapeHandle {
    const body_index: BodyIndex = body_handle.index();
    const body_type: MotionType = world.bodies.data[body_index].motion_type;
    const transform: Transform2 = world.bodies.data[body_index].transform;

    const initial: Shape = .{
        .geom = def.geom,
        .body = body_index,
        .material = def.material,
        .filter = def.filter,
        .density = def.density,
        .local_centroid = getShapeCentroid(def.geom),
        .aabb_margin = computeShapeMargin(def.geom),
        .enable_contact_events = def.enable_contact_events,
        .enable_sensor_events = def.enable_sensor_events,
        .enable_pre_solve = def.enable_pre_solve,
        .enable_custom_filtering = def.enable_custom_filtering,
        .enable_hit_events = def.enable_hit_events,
        .user_data = def.user_data,
    };
    const handle: ShapeHandle = world.shapes.spawn(world.allocator, initial) catch |err| blk: {
        // Pool full: grow (amortised doubling) and retry, so the world behaves like a
        // growable container rather than a fixed cap. A non-capacity error (true OOM) still
        // propagates. growShapes.grow lifts the pool + its ECS handle table (and, for bodies, every
        // body-indexed side table) in lockstep.
        if (err != error.PoolExhausted) {
            return err;
        }
        try world.growShapes(@intCast(world.shapes.data.len + 1));
        break :blk try world.shapes.spawn(world.allocator, initial);
    };
    errdefer _ = handle.destroy(&world.shapes);
    const shape_index: ShapeIndex = handle.index();
    const s: *Shape = &world.shapes.data[shape_index];

    // Bounds and broad-phase proxy. Static shapes use the speculative distance as margin.
    const margin: f32 = if (body_type == .static) speculative_distance else s.aabb_margin;
    s.aabb = computeFatShapeAabb(def.geom, transform, speculative_distance);
    s.fat_aabb = expandAabb(s.aabb, margin);
    s.proxy_key = try world.broadphase.createProxy(
        world.allocator,
        body_type,
        s.fat_aabb,
        def.filter.category,
        shape_index,
        def.invoke_contact_creation or def.is_sensor,
    );
    errdefer world.broadphase.destroyProxy(s.proxy_key);

    if (def.is_sensor) {
        s.sensor_index = @intCast(world.sensors.items.len);
        try world.sensors.append(world.allocator, .{ .shape = shape_index });
    }

    // Splice into the body's doubly-linked shape list (infallible from here on).
    const body: *Body = &world.bodies.data[body_index];
    if (body.head_shape != null_index) {
        world.shapes.data[body.head_shape].prev_shape = shape_index;
    }
    s.next_shape = body.head_shape;
    s.prev_shape = null_index;
    body.head_shape = shape_index;
    body.shape_count += 1;

    if (def.update_body_mass) {
        updateBodyMassData(world, body_index);
    }
    return handle;
}

/// Detach and free a shape: destroy its broad-phase proxy, unlink it from its body's
/// shape list, deregister it as a sensor (swap-removing from `world.sensors` and fixing
/// the moved sensor's back-reference), then recompute the body's mass. Contacts that
/// referenced this shape are torn down by the contact lifecycle (added next).
/// box2d: b2DestroyShape  shape.c
pub fn destroyShape(world: *World, shape_handle: ShapeHandle) void {
    const shape_index: ShapeIndex = shape_handle.index();
    const s: *Shape = &world.shapes.data[shape_index];
    const body_index: BodyIndex = s.body;

    if (s.proxy_key != null_index) {
        world.broadphase.destroyProxy(s.proxy_key);
        s.proxy_key = null_index;
    }

    const body: *Body = &world.bodies.data[body_index];
    if (s.prev_shape != null_index) {
        world.shapes.data[s.prev_shape].next_shape = s.next_shape;
    } else {
        body.head_shape = s.next_shape;
    }
    if (s.next_shape != null_index) {
        world.shapes.data[s.next_shape].prev_shape = s.prev_shape;
    }
    body.shape_count -= 1;

    if (s.sensor_index != null_index) {
        const removed: usize = s.sensor_index;
        world.sensors.items[removed].deinit(world.allocator);
        _ = world.sensors.swapRemove(removed);
        if (removed < world.sensors.items.len) {
            const moved_shape: u32 = world.sensors.items[removed].shape;
            world.shapes.data[moved_shape].sensor_index = @intCast(removed);
        }
    }

    _ = shape_handle.destroy(&world.shapes);
    updateBodyMassData(world, body_index);
}

/// Replace a live shape's geometry in place, recomputing its bounds, broad-phase proxy, and the
/// owning body's mass. The proxy keeps its id (so existing contacts survive) and the queued move
/// re-runs pair creation against the new bounds. box2d unifies b2Shape_SetCircle / SetCapsule /
/// SetSegment / SetPolygon; this is the single geometry setter behind them.
pub fn setShapeGeometry(
    world: *World,
    shape_handle: ShapeHandle,
    geom: Geometry,
) !void {
    const shape_index: ShapeIndex = shape_handle.index();
    const s: *Shape = &world.shapes.data[shape_index];
    const body: *const Body = &world.bodies.data[s.body];

    s.geom = geom;
    s.local_centroid = getShapeCentroid(geom);
    s.aabb_margin = computeShapeMargin(geom);

    const margin: f32 = if (body.motion_type == .static) speculative_distance else s.aabb_margin;
    s.aabb = computeFatShapeAabb(geom, body.transform, speculative_distance);
    s.fat_aabb = expandAabb(s.aabb, margin);
    if (s.proxy_key != null_index) {
        try world.broadphase.moveProxy(world.allocator, s.proxy_key, s.fat_aabb);
    }

    updateBodyMassData(world, s.body);
}

/// The first shape attached to a body, as a handle (these samples give each body one shape).
/// box2d: b2Body_GetShapes (first element).
pub fn getFirstShape(world: *const World, body: BodyHandle) ShapeHandle {
    const shape_id: u32 = world.bodies.data[body.index()].head_shape;
    return ShapeHandle.pack(@intCast(shape_id), world.shapes.cycle[shape_id]);
}

/// Recompute a body's mass, center of mass, and rotational inertia from its current shapes. Pair with
/// `ShapeDef.update_body_mass = false` when attaching many shapes to a compound body so the (linear)
/// mass solve runs once at the end instead of after every shape. box2d: b2Body_ApplyMassFromShapes
pub fn applyMassFromShapes(world: *World, body: BodyHandle) void {
    updateBodyMassData(world, body.index());
}

/// Install a custom collision filter, consulted at pair creation for any pair where a shape has
/// `enable_custom_filtering` set. Return false from the callback to keep that pair from colliding.
/// Pass null to clear. box2d: b2World_SetCustomFilterCallback
pub fn setCustomFilterCallback(
    world: *World,
    filter_fn: ?CustomFilterFn,
    ctx: ?*anyopaque,
) void {
    world.narrow_phase.custom_filter_fn = filter_fn;
    world.narrow_phase.custom_filter_ctx = ctx;
}

/// Install a pre-solve veto, consulted each step for contacts where a shape has `enable_pre_solve`
/// set. Return false from the callback to disable that contact for the step (e.g. one-way platforms).
/// Pass null to clear. box2d: b2World_SetPreSolveCallback
pub fn setPreSolveCallback(
    world: *World,
    presolve_fn: ?PreSolveFn,
    ctx: ?*anyopaque,
) void {
    world.narrow_phase.pre_solve_fn = presolve_fn;
    world.narrow_phase.pre_solve_ctx = ctx;
}

// -- Contact lifecycle & broad-phase pair finding --------------------------------
//
// New overlaps found by the broad phase become contacts; contacts whose proxies stop
// overlapping (or whose shapes/bodies are destroyed) are torn down. A contact stores
// the more-complex shape as A so the narrow-phase dispatch (collideShapes) hits a
// registered ordering. Each contact threads into both bodies' intrusive contact lists
// (keyed by contactId<<1 | edgeIndex) and is tracked in a dense `contact_ids` list for
// O(1) iteration and removal. box2d: contact.c + broad_phase.c

/// The narrow-phase dispatch is registered for one ordering of each colliding shape-type
/// pair (the "primary" ordering, more-complex shape first). This rank puts shapes in that
/// order: chainSegment > segment > polygon > capsule > circle. box2d: the s_registers table.
fn primaryRank(kind: ShapeKind) u8 {
    return switch (kind) {
        .circle => 0,
        .capsule => 1,
        .polygon => 2,
        .segment => 3,
        .chain_segment => 4,
    };
}

/// Whether two bodies are allowed to collide: never if both are non-dynamic, and never
/// if a joint connects them with collision disabled. box2d: b2ShouldBodiesCollide  body.c
fn shouldBodiesCollide(world: *const World, body_a: BodyIndex, body_b: BodyIndex) bool {
    if (world.bodies.data[body_a].motion_type != .dynamic and world.bodies.data[body_b].motion_type != .dynamic) {
        return false;
    }
    var key: u32 = world.bodies.data[body_a].head_joint;
    while (key != null_index) {
        const joint_id: u32 = key >> 1;
        const edge_index: u32 = key & 1;
        const joint: *const Joint = &world.joints.data[joint_id];
        const other: BodyIndex = if (edge_index == 0) joint.body_b else joint.body_a;
        if (other == body_b and joint.collide_connected == false) {
            return false;
        }
        key = if (edge_index == 0) joint.edge_a.next_key else joint.edge_b.next_key;
    }
    return true;
}

/// Set the `prev_key` of the contact edge identified by `key` (contactId<<1 | edgeIndex).
fn setContactEdgePrev(world: *World, key: u32, prev: u32) void {
    const contact_id: u32 = key >> 1;
    if (key & 1 == 0) {
        world.contacts.data[contact_id].edge_a.prev_key = prev;
    } else {
        world.contacts.data[contact_id].edge_b.prev_key = prev;
    }
}

/// Set the `next_key` of the contact edge identified by `key`.
fn setContactEdgeNext(world: *World, key: u32, next: u32) void {
    const contact_id: u32 = key >> 1;
    if (key & 1 == 0) {
        world.contacts.data[contact_id].edge_a.next_key = next;
    } else {
        world.contacts.data[contact_id].edge_b.next_key = next;
    }
}

/// Splice one edge of a contact out of its body's contact list.
fn unlinkContactEdge(
    world: *World,
    body_index: BodyIndex,
    edge: *const ContactEdge,
) void {
    if (edge.prev_key != null_index) {
        setContactEdgeNext(world, edge.prev_key, edge.next_key);
    } else {
        world.bodies.data[body_index].head_contact = edge.next_key;
    }
    if (edge.next_key != null_index) {
        setContactEdgePrev(world, edge.next_key, edge.prev_key);
    }
    world.bodies.data[body_index].contact_count -= 1;
}

/// Create a contact between two overlapping (non-sensor, collidable) shapes. The shapes
/// are reordered so the higher primary-rank shape is A. The contact starts non-touching;
/// the narrow phase decides touching and emits the begin event. box2d: b2CreateContact
fn createContact(
    world: *World,
    shape_index_a: ShapeIndex,
    shape_index_b: ShapeIndex,
) !void {
    const rank_a: u8 = primaryRank(std.meta.activeTag(world.shapes.data[shape_index_a].geom));
    const rank_b: u8 = primaryRank(std.meta.activeTag(world.shapes.data[shape_index_b].geom));
    const shape_a: ShapeIndex = if (rank_b > rank_a) shape_index_b else shape_index_a;
    const shape_b: ShapeIndex = if (rank_b > rank_a) shape_index_a else shape_index_b;

    const sa: *const Shape = &world.shapes.data[shape_a];
    const sb: *const Shape = &world.shapes.data[shape_b];
    const body_a: BodyIndex = sa.body;
    const body_b: BodyIndex = sb.body;
    const cfg: NarrowPhaseConfig = world.narrow_phase;

    var flags: ContactFlags = .{};
    if (sa.enable_contact_events or sb.enable_contact_events) {
        flags.enable_contact_events = true;
    }
    if (sa.enable_pre_solve or sb.enable_pre_solve) {
        flags.enable_pre_solve = true;
    }
    if (sa.enable_hit_events or sb.enable_hit_events) {
        flags.sim_enable_hit_event = true;
    }

    const contact: Contact = .{
        .shape_a = shape_a,
        .shape_b = shape_b,
        .body_a = body_a,
        .body_b = body_b,
        .manifold = Manifold.empty,
        .cache = SimplexCache.empty,
        .friction = cfg.friction_fn(
            sa.material.friction,
            sa.material.user_material_id,
            sb.material.friction,
            sb.material.user_material_id,
        ),
        .restitution = cfg.restitution_fn(
            sa.material.restitution,
            sa.material.user_material_id,
            sb.material.restitution,
            sb.material.user_material_id,
        ),
        .rolling_resistance = 0,
        .tangent_speed = 0,
        .flags = flags,
        .edge_a = .{},
        .edge_b = .{},
        .local_index = null_index,
    };
    // alloc reuses a freed id or bumps the high-water mark, growing the backing store itself, so
    // the world behaves like a growable container with no fixed cap. box2d: b2AllocId.
    const contact_id: u32 = try world.contacts.alloc(world.allocator, contact);
    const c: *Contact = &world.contacts.data[contact_id];

    // Track in the dense live list.
    c.local_index = @intCast(world.contact_ids.items.len);
    try world.contact_ids.append(world.allocator, contact_id);

    // Prepend edge A to body A's contact list.
    const key_a: u32 = (contact_id << 1) | 0;
    c.edge_a.prev_key = null_index;
    c.edge_a.next_key = world.bodies.data[body_a].head_contact;
    if (world.bodies.data[body_a].head_contact != null_index) {
        setContactEdgePrev(world, world.bodies.data[body_a].head_contact, key_a);
    }
    world.bodies.data[body_a].head_contact = key_a;
    world.bodies.data[body_a].contact_count += 1;

    // Prepend edge B to body B's contact list.
    const key_b: u32 = (contact_id << 1) | 1;
    c.edge_b.prev_key = null_index;
    c.edge_b.next_key = world.bodies.data[body_b].head_contact;
    if (world.bodies.data[body_b].head_contact != null_index) {
        setContactEdgePrev(world, world.bodies.data[body_b].head_contact, key_b);
    }
    world.bodies.data[body_b].head_contact = key_b;
    world.bodies.data[body_b].contact_count += 1;

    try world.broadphase.pair_set.put(world.allocator, shapePairKey(shape_a, shape_b));
}

/// Tear down a contact: drop it from the pair set, emit an end-touch event if it was
/// touching, unlink both edges, remove it from the dense list, and free its slot.
/// box2d: b2DestroyContact
fn destroyContact(world: *World, contact_id: u32) void {
    const c: *Contact = &world.contacts.data[contact_id];
    const shape_a: u32 = c.shape_a;
    const shape_b: u32 = c.shape_b;
    const body_a: BodyIndex = c.body_a;
    const body_b: BodyIndex = c.body_b;

    world.broadphase.pair_set.remove(shapePairKey(shape_a, shape_b));

    if (c.flags.touching and c.flags.enable_contact_events) {
        world.events.contactEnd().append(world.allocator, .{
            .shape_a = shape_a,
            .shape_b = shape_b,
            .contact_id = contact_id,
        }) catch assertUnreachable(@src(), "OOM", .{});
    }

    unlinkContactEdge(world, body_a, &c.edge_a);
    unlinkContactEdge(world, body_b, &c.edge_b);

    // Swap-remove from the dense list, fixing the moved contact's back-reference.
    const removed: u32 = c.local_index;
    _ = world.contact_ids.swapRemove(removed);
    if (removed < world.contact_ids.items.len) {
        world.contacts.data[world.contact_ids.items[removed]].local_index = removed;
    }

    world.contacts.free(contact_id);
}

/// Context threaded through the broad-phase pair query for one moved proxy.
const PairQueryContext = struct {
    world: *World,
    query_key: u32, // the moved proxy's key
    query_shape: ShapeIndex, // the moved proxy's shape index
    query_tree_type: MotionType, // which tree is currently being queried
    pairs: *std.ArrayListUnmanaged([2]ShapeIndex),
    oom: bool = false,
};

/// Whether a proxy in tree `tree_type` with id `proxy_id` is itself queued for a move.
fn proxyIsMoved(bp: *const BroadPhase, tree_type: MotionType, proxy_id: i32) bool {
    const t: usize = @backingInt(tree_type);
    const id: usize = @intCast(proxy_id);
    return id < bp.moved[t].items.len and bp.moved[t].items[id];
}

/// Broad-phase overlap callback: filters out self/duplicate/sensor/filtered pairs and
/// collects the survivors as ordered shape-index pairs for contact creation. The dedup
/// rules ensure each pair is produced exactly once even when both proxies moved.
/// box2d: b2PairQueryCallback  broad_phase.c
fn pairQueryCallback(proxy_id: i32, user_data: u64, ctx_ptr: *anyopaque) bool {
    const ctx: *PairQueryContext = @ptrCast(@alignCast(ctx_ptr));
    const world: *World = ctx.world;
    const bp: *BroadPhase = &world.broadphase;
    const proxy_key: u32 = makeProxyKey(proxy_id, ctx.query_tree_type);
    if (proxy_key == ctx.query_key) {
        return true; // same proxy
    }

    // Avoid producing a pair twice: when the other proxy also moved, let exactly one of
    // the two queries produce it (the one with the higher key for dynamic-dynamic; the
    // dynamic side for kinematic-dynamic).
    const query_type: MotionType = proxyKeyType(ctx.query_key);
    if (query_type == .dynamic) {
        if (ctx.query_tree_type == .dynamic and proxy_key < ctx.query_key and
            proxyIsMoved(bp, ctx.query_tree_type, proxy_id))
        {
            return true;
        }
    } else if (proxyIsMoved(bp, ctx.query_tree_type, proxy_id)) {
        return true;
    }

    const other_shape: ShapeIndex = @intCast(user_data);
    if (bp.pair_set.contains(shapePairKey(other_shape, ctx.query_shape))) {
        return true;
    }

    // Order by proxy key (lower key is A) for a deterministic pair; createContact will
    // re-order by shape-type registration.
    const shape_a: ShapeIndex = if (proxy_key < ctx.query_key) other_shape else ctx.query_shape;
    const shape_b: ShapeIndex = if (proxy_key < ctx.query_key) ctx.query_shape else other_shape;

    const sa: *const Shape = &world.shapes.data[shape_a];
    const sb: *const Shape = &world.shapes.data[shape_b];
    if (sa.body == sb.body) {
        return true;
    }
    if (sa.sensor_index != null_index or sb.sensor_index != null_index) {
        return true;
    }
    if (shouldShapesCollide(sa.filter, sb.filter) == false) {
        return true;
    }
    // Custom collision filter (consulted once at pair creation, only when a shape opted in).
    if ((sa.enable_custom_filtering or sb.enable_custom_filtering) and
        world.narrow_phase.custom_filter_fn != null)
    {
        const allow: bool = world.narrow_phase.custom_filter_fn.?(
            shape_a,
            shape_b,
            world.narrow_phase.custom_filter_ctx,
        );
        if (allow == false) {
            return true;
        }
    }
    if (canCollide(std.meta.activeTag(sa.geom), std.meta.activeTag(sb.geom)) == false) {
        return true;
    }
    if (shouldBodiesCollide(world, sa.body, sb.body) == false) {
        return true;
    }

    ctx.pairs.append(world.allocator, .{ shape_a, shape_b }) catch {
        ctx.oom = true;
    };
    return true;
}

/// Find new overlapping shape pairs among the proxies that moved this step and create
/// contacts for them. A dynamic proxy is tested against the kinematic, static, and
/// dynamic trees; a kinematic proxy only against the dynamic tree (nothing else can
/// collide with it). box2d: b2UpdateBroadPhasePairs  broad_phase.c
/// Find new contact pairs for proxies that moved this step. Each moved proxy's fat AABB is
/// queried against the trees for overlaps; a dynamic proxy checks all three trees (it can
/// touch static, kinematic, or dynamic bodies), while a moved static/kinematic proxy only
/// checks the dynamic tree (static never collides with static). New overlaps become contacts;
/// the move list and its bits are then cleared. box2d: b2UpdateBroadPhasePairs  broad_phase.c
fn updateBroadPhasePairs(world: *World) !void {
    const bp: *BroadPhase = &world.broadphase;
    if (bp.move_array.items.len == 0) {
        return;
    }

    var pairs: std.ArrayListUnmanaged([2]ShapeIndex) = .empty;
    defer pairs.deinit(world.allocator);

    var ctx: PairQueryContext = .{
        .world = world,
        .query_key = 0,
        .query_shape = 0,
        .query_tree_type = .dynamic,
        .pairs = &pairs,
    };

    {
        const zq: profiler.Zone = profiler.zoneNamed(@src(), "p2d.bp.query");
        defer zq.end();
        for (bp.move_array.items) |query_key| {
            if (query_key == null_index) {
                continue;
            }
            const query_type: MotionType = proxyKeyType(query_key);
            const query_id: i32 = proxyKeyId(query_key);
            const base: usize = @backingInt(query_type);
            const fat: Aabb2 = bp.trees[base].proxyAabb(query_id);
            ctx.query_key = query_key;
            ctx.query_shape = @intCast(bp.trees[base].proxyUserData(query_id));

            if (query_type == .dynamic) {
                ctx.query_tree_type = .kinematic;
                bp.trees[@backingInt(MotionType.kinematic)]
                    .query(fat, default_mask_bits, pairQueryCallback, &ctx);
                ctx.query_tree_type = .static;
                bp.trees[@backingInt(MotionType.static)]
                    .query(fat, default_mask_bits, pairQueryCallback, &ctx);
            }
            ctx.query_tree_type = .dynamic;
            bp.trees[@backingInt(MotionType.dynamic)].query(fat, default_mask_bits, pairQueryCallback, &ctx);
        }
    }

    if (ctx.oom) {
        return error.OutOfMemory;
    }
    {
        const zc: profiler.Zone = profiler.zoneNamed(@src(), "p2d.bp.newcontacts");
        defer zc.end();
        for (pairs.items) |pair| {
            try createContact(world, pair[0], pair[1]);
        }
    }

    // Clear the moved bits and the move list for next step.
    for (bp.move_array.items) |key| {
        if (key == null_index) {
            continue;
        }
        const t: usize = @backingInt(proxyKeyType(key));
        const id: usize = @intCast(proxyKeyId(key));
        if (id < bp.moved[t].items.len) {
            bp.moved[t].items[id] = false;
        }
    }
    bp.move_array.clearRetainingCapacity();
}

// -- Joint lifecycle, waking, and body destruction -------------------------------

/// Wake a sleeping movable body: clear its sleep timer and return it to the active list.
/// Static bodies and already-awake bodies are left alone. The active list is reserved to
/// capacity at init, so this never needs to allocate.
fn wakeBody(world: *World, body_index: BodyIndex) void {
    const body: *Body = &world.bodies.data[body_index];
    if (body.motion_type == .static or body.asleep == false or body.flags.is_disabled) {
        return;
    }
    body.asleep = false;
    body.sleep_time = 0;
    world.active.appendAssumeCapacity(body_index);
}

/// Wake both bodies a joint connects (a static endpoint is a no-op inside `wakeBody`). The motor-speed
/// setters call this so a motor command takes effect even when the driven body had slept at rest -
/// otherwise the new speed sits unread until something else happens to wake the body.
fn wakeJointBodies(world: *World, joint: JointHandle) void {
    const j: *const Joint = &world.joints.data[joint.index()];
    wakeBody(world, j.body_a);
    wakeBody(world, j.body_b);
}

/// Remove a body from the active list (linear search + swap-remove). No-op if absent.
fn removeFromActive(world: *World, body_index: BodyIndex) void {
    for (world.active.items, 0..) |b, i| {
        if (b == body_index) {
            _ = world.active.swapRemove(i);
            return;
        }
    }
}

/// Set the `prev_key` of the joint edge identified by `key` (jointId<<1 | edgeIndex).
fn setJointEdgePrev(world: *World, key: u32, prev: u32) void {
    const joint_id: u32 = key >> 1;
    if (key & 1 == 0) {
        world.joints.data[joint_id].edge_a.prev_key = prev;
    } else {
        world.joints.data[joint_id].edge_b.prev_key = prev;
    }
}

/// Set the `next_key` of the joint edge identified by `key`.
fn setJointEdgeNext(world: *World, key: u32, next: u32) void {
    const joint_id: u32 = key >> 1;
    if (key & 1 == 0) {
        world.joints.data[joint_id].edge_a.next_key = next;
    } else {
        world.joints.data[joint_id].edge_b.next_key = next;
    }
}

/// Splice one edge of a joint out of its body's joint list.
fn unlinkJointEdge(world: *World, body_index: BodyIndex, edge: *const JointEdge) void {
    if (edge.prev_key != null_index) {
        setJointEdgeNext(world, edge.prev_key, edge.next_key);
    } else {
        world.bodies.data[body_index].head_joint = edge.next_key;
    }
    if (edge.next_key != null_index) {
        setJointEdgePrev(world, edge.next_key, edge.prev_key);
    }
    world.bodies.data[body_index].joint_count -= 1;
}

/// Parameters for creating a joint. The `data` field selects the joint kind and carries
/// its type-specific configuration. box2d: the per-type b2*JointDef, unified here.
pub const JointDef = struct {
    body_a: BodyHandle,
    body_b: BodyHandle,
    local_frame_a: Transform2 = Transform2.identity,
    local_frame_b: Transform2 = Transform2.identity,
    constraint_hertz: f32 = 60,
    constraint_damping_ratio: f32 = 2,
    force_threshold: f32 = floatMax(f32),
    torque_threshold: f32 = floatMax(f32),
    collide_connected: bool = false,
    user_data: u64 = 0,
    data: JointData,
};

/// Create a joint between two bodies, thread it into both bodies' joint lists, and wake
/// them. box2d: b2CreateJoint  joint.c:191
pub fn createJoint(world: *World, def: JointDef) !JointHandle {
    const body_a: BodyIndex = def.body_a.index();
    const body_b: BodyIndex = def.body_b.index();

    const joint: Joint = .{
        .body_a = body_a,
        .body_b = body_b,
        .local_frame_a = def.local_frame_a,
        .local_frame_b = def.local_frame_b,
        .constraint_hertz = def.constraint_hertz,
        .constraint_damping_ratio = def.constraint_damping_ratio,
        .force_threshold = def.force_threshold,
        .torque_threshold = def.torque_threshold,
        .collide_connected = def.collide_connected,
        .edge_a = .{},
        .edge_b = .{},
        .user_data = def.user_data,
        .local_index = null_index,
        .data = def.data,
    };
    const handle: JointHandle = world.joints.spawn(world.allocator, joint) catch |err| blk: {
        // Pool full: grow (amortised doubling) and retry, so the world behaves like a
        // growable container rather than a fixed cap. A non-capacity error (true OOM) still
        // propagates. growJoints.grow lifts the pool + its ECS handle table (and, for bodies, every
        // body-indexed side table) in lockstep.
        if (err != error.PoolExhausted) {
            return err;
        }
        try world.growJoints(@intCast(world.joints.data.len + 1));
        break :blk try world.joints.spawn(world.allocator, joint);
    };
    const joint_id: u32 = handle.index();
    const j: *Joint = &world.joints.data[joint_id];

    j.local_index = @intCast(world.joint_ids.items.len);
    try world.joint_ids.append(world.allocator, joint_id);

    // Prepend edge A to body A's joint list.
    const key_a: u32 = (joint_id << 1) | 0;
    j.edge_a.prev_key = null_index;
    j.edge_a.next_key = world.bodies.data[body_a].head_joint;
    if (world.bodies.data[body_a].head_joint != null_index) {
        setJointEdgePrev(world, world.bodies.data[body_a].head_joint, key_a);
    }
    world.bodies.data[body_a].head_joint = key_a;
    world.bodies.data[body_a].joint_count += 1;

    // Prepend edge B to body B's joint list.
    const key_b: u32 = (joint_id << 1) | 1;
    j.edge_b.prev_key = null_index;
    j.edge_b.next_key = world.bodies.data[body_b].head_joint;
    if (world.bodies.data[body_b].head_joint != null_index) {
        setJointEdgePrev(world, world.bodies.data[body_b].head_joint, key_b);
    }
    world.bodies.data[body_b].head_joint = key_b;
    world.bodies.data[body_b].joint_count += 1;

    wakeBody(world, body_a);
    wakeBody(world, body_b);
    return handle;
}

/// Tear down a joint: unlink both edges, remove it from the dense list, and free its
/// slot. box2d: b2DestroyJointInternal  joint.c:633
fn destroyJointInternal(world: *World, joint_id: u32) void {
    const j: *Joint = &world.joints.data[joint_id];
    const body_a: BodyIndex = j.body_a;
    const body_b: BodyIndex = j.body_b;

    unlinkJointEdge(world, body_a, &j.edge_a);
    unlinkJointEdge(world, body_b, &j.edge_b);

    const removed: u32 = j.local_index;
    _ = world.joint_ids.swapRemove(removed);
    if (removed < world.joint_ids.items.len) {
        world.joints.data[world.joint_ids.items[removed]].local_index = removed;
    }

    const handle: JointHandle = JointHandle.pack(@intCast(joint_id), world.joints.cycle[joint_id]);
    _ = handle.destroy(&world.joints);
}

/// Destroy a joint by its public handle, waking both connected bodies so the simulation
/// re-settles around the removed constraint. box2d: b2DestroyJoint  joint.c
pub fn destroyJoint(world: *World, joint: JointHandle) void {
    const joint_id: u32 = joint.index();
    const j: *const Joint = &world.joints.data[joint_id];
    wakeBody(world, j.body_a);
    wakeBody(world, j.body_b);
    destroyJointInternal(world, joint_id);
}

/// Destroy a body and everything attached to it: its joints and contacts (waking the
/// bodies on the far side so the simulation re-settles), then its shapes and broad-phase
/// proxies, then the body itself. box2d: b2DestroyBody  body.c:345
pub fn destroyBody(world: *World, body_handle: BodyHandle) void {
    const body_index: BodyIndex = body_handle.index();

    // Joints first (each wakes its other body).
    var joint_key: u32 = world.bodies.data[body_index].head_joint;
    while (joint_key != null_index) {
        const joint_id: u32 = joint_key >> 1;
        const edge_index: u32 = joint_key & 1;
        const joint: *const Joint = &world.joints.data[joint_id];
        joint_key = if (edge_index == 0) joint.edge_a.next_key else joint.edge_b.next_key;
        const other: BodyIndex = if (edge_index == 0) joint.body_b else joint.body_a;
        wakeBody(world, other);
        destroyJointInternal(world, joint_id);
    }

    // Then contacts (each wakes its other body).
    var contact_key: u32 = world.bodies.data[body_index].head_contact;
    while (contact_key != null_index) {
        const contact_id: u32 = contact_key >> 1;
        const edge_index: u32 = contact_key & 1;
        const contact: *const Contact = &world.contacts.data[contact_id];
        contact_key = if (edge_index == 0) contact.edge_a.next_key else contact.edge_b.next_key;
        const other: BodyIndex = if (edge_index == 0) contact.body_b else contact.body_a;
        wakeBody(world, other);
        destroyContact(world, contact_id);
    }

    // Then shapes (capture the next link before each shape is freed).
    var shape_id: u32 = world.bodies.data[body_index].head_shape;
    while (shape_id != null_index) {
        const next: u32 = world.shapes.data[shape_id].next_shape;
        const shape_handle: ShapeHandle = ShapeHandle.pack(@intCast(shape_id), world.shapes.cycle[shape_id]);
        destroyShape(world, shape_handle);
        shape_id = next;
    }

    removeFromActive(world, body_index);
    _ = body_handle.destroy(&world.bodies);
}

// -- Continuous collision (CCD) --------------------------------------------------
//
// A body that moves far enough in one step to tunnel through a thin obstacle is flagged
// "fast" during finalize. For each fast body, solveContinuous sweeps its shapes against
// the static tree (and, for bullets, the kinematic and dynamic trees), finds the earliest
// time of impact, and rewinds the body's pose to that instant so the next step resolves
// the contact normally. The sweep is re-centered on the body's start-of-step center so the
// TOI math stays in single-precision range. AABB refit and proxy updates are handled
// afterwards by the uniform finalize pass, so this routine only adjusts the pose.
// box2d: b2SolveContinuous + b2ContinuousQueryCallback  solver.c

/// Build a local-space distance proxy (support points + radius) for a shape's geometry.
/// box2d: b2MakeShapeDistanceProxy  shape.c
fn makeShapeDistanceProxy(geom: Geometry) ShapeProxy {
    return switch (geom) {
        .circle => |c| makeProxy(&[_]Vec2{c.center}, c.radius),
        .capsule => |cap| makeProxy(&[_]Vec2{ cap.center1, cap.center2 }, cap.radius),
        .segment => |s| makeProxy(&[_]Vec2{ s.point1, s.point2 }, 0),
        .polygon => |p| makeProxy(p.vertices[0..p.count], p.radius),
        .chain_segment => |cs| makeProxy(&[_]Vec2{ cs.segment.point1, cs.segment.point2 }, 0),
    };
}

/// State threaded through the CCD sweep for one fast body, accumulating the earliest hit.
const ContinuousContext = struct {
    world: *World,
    sweep: Sweep2, // the fast body's start->end sweep, relative to `base`
    base: Vec2, // recentering origin (the fast body's start-of-step center)
    fast_body: BodyIndex,
    fast_shape: ShapeIndex, // the fast body's shape currently being swept
    centroid1: Vec2, // fast shape centroid at the start of the step (base frame)
    centroid2: Vec2, // fast shape centroid at the end of the step (base frame)
    fraction: f32, // earliest time of impact found so far, in [0, 1]
};

/// Sweep callback: for each candidate obstacle, run a time-of-impact query and keep the
/// earliest solid hit. Sensors and bullets are skipped (sensors are handled by the sensor
/// pass; two bullets never CCD against each other). box2d: b2ContinuousQueryCallback
fn continuousQueryCallback(proxy_id: i32, user_data: u64, ctx_ptr: *anyopaque) bool {
    _ = proxy_id;
    const ctx: *ContinuousContext = @ptrCast(@alignCast(ctx_ptr));
    const world: *World = ctx.world;
    const shape_id: ShapeIndex = @intCast(user_data);
    if (shape_id == ctx.fast_shape) {
        return true; // same shape
    }

    const fast_shape: *const Shape = &world.shapes.data[ctx.fast_shape];
    const shape: *const Shape = &world.shapes.data[shape_id];
    if (shape.body == fast_shape.body) {
        return true; // same body
    }
    if (shape.sensor_index != null_index) {
        return true; // sensors handled separately
    }
    if (shouldShapesCollide(fast_shape.filter, shape.filter) == false) {
        return true;
    }
    if (world.bodies.data[shape.body].flags.is_bullet) {
        return true; // skip other bullets
    }
    if (shouldBodiesCollide(world, fast_shape.body, shape.body) == false) {
        return true;
    }

    // Early out when a chain segment is nearly parallel to the sweep and the body only
    // grazes it (minimal clipping): such hits do not cause tunneling.
    if (std.meta.activeTag(shape.geom) == .chain_segment) {
        const cs: ChainSegment = shape.geom.chain_segment;
        const body_xf: Transform2 = world.bodies.data[shape.body].transform;
        const rel: Transform2 = .{ .q = body_xf.q, .p = body_xf.p - ctx.base };
        const p1: Vec2 = transformPoint2(rel, cs.segment.point1);
        const p2: Vec2 = transformPoint2(rel, cs.segment.point2);
        const edge: Vec2 = p2 - p1;
        const len: f32 = length2(edge);
        if (len > linear_slop) {
            const unit: Vec2 = edge * splat2(1.0 / len);
            const separation1: f32 = cross2(ctx.centroid1 - p1, unit);
            const separation2: f32 = cross2(ctx.centroid2 - p1, unit);
            const core_distance: f32 = core_fraction * world.bodies.data[ctx.fast_body].min_extent;
            const grazing: bool = separation1 - separation2 < core_distance and separation2 > core_distance;
            if (separation1 < 0.0 or grazing) {
                return true;
            }
        }
    }

    var input: TOIInput = .{
        .proxy_a = makeShapeDistanceProxy(shape.geom),
        .proxy_b = makeShapeDistanceProxy(fast_shape.geom),
        .sweep_a = makeRelativeSweep(&world.bodies.data[shape.body], ctx.base),
        .sweep_b = ctx.sweep,
        .max_fraction = ctx.fraction,
    };
    var output: TOIOutput = timeOfImpact(&input);

    var hit_fraction: f32 = ctx.fraction;
    var did_hit: bool = false;
    if (output.fraction > 0.0 and output.fraction < ctx.fraction) {
        hit_fraction = output.fraction;
        did_hit = true;
    } else if (output.fraction == 0.0) {
        // A zero fraction means the shapes already touch at the start; fall back to the
        // TOI of a small core circle around the fast shape's centroid to get a usable hit.
        const centroid: Vec2 = getShapeCentroid(fast_shape.geom);
        const extent: ShapeExtent = computeShapeExtent(fast_shape.geom, centroid);
        const radius: f32 = core_fraction * extent.min_extent;
        input.proxy_b = makeProxy(&[_]Vec2{centroid}, radius);
        output = timeOfImpact(&input);
        if (output.fraction > 0.0 and output.fraction < ctx.fraction) {
            hit_fraction = output.fraction;
            did_hit = true;
        }
    }

    if (did_hit) {
        world.bodies.data[ctx.fast_body].flags.had_time_of_impact = true;
        ctx.fraction = hit_fraction;
    }
    return true;
}

/// Find the earliest time of impact for a fast body across all its shapes and, if one is
/// found before the end of the step, rewind the body's pose to that instant.
/// box2d: b2SolveContinuous  solver.c:384
fn solveContinuous(world: *World, body_index: BodyIndex) void {
    const fast_body: *Body = &world.bodies.data[body_index];
    const base: Vec2 = fast_body.center0;
    const sweep: Sweep2 = makeRelativeSweep(fast_body, base);
    const xf1: Transform2 = sweepTransform2(sweep, 0.0);
    const xf2: Transform2 = sweepTransform2(sweep, 1.0);
    const is_bullet: bool = fast_body.flags.is_bullet;
    const bp: *BroadPhase = &world.broadphase;

    var ctx: ContinuousContext = .{
        .world = world,
        .sweep = sweep,
        .base = base,
        .fast_body = body_index,
        .fast_shape = null_index,
        .centroid1 = .{ 0, 0 },
        .centroid2 = .{ 0, 0 },
        .fraction = 1.0,
    };

    var shape_id: u32 = fast_body.head_shape;
    while (shape_id != null_index) {
        const shape: *const Shape = &world.shapes.data[shape_id];
        ctx.fast_shape = shape_id;
        ctx.centroid1 = transformPoint2(xf1, shape.local_centroid);
        ctx.centroid2 = transformPoint2(xf2, shape.local_centroid);
        shape_id = shape.next_shape;
        if (shape.sensor_index != null_index) {
            continue; // no CCD for sensors
        }

        // The region the shape sweeps through this step: start AABB unioned with the AABB
        // at the end pose (computed in world space; xf2 is in the base frame).
        const box1: Aabb2 = shape.aabb;
        const world_xf2: Transform2 = .{ .q = xf2.q, .p = xf2.p + base };
        const box2: Aabb2 = computeShapeAabb(shape.geom, world_xf2);
        const swept: Aabb2 = Aabb2.combine(box1, box2);

        bp.trees[@backingInt(MotionType.static)]
            .query(swept, default_mask_bits, continuousQueryCallback, &ctx);
        if (is_bullet) {
            bp.trees[@backingInt(MotionType.kinematic)]
                .query(swept, default_mask_bits, continuousQueryCallback, &ctx);
            bp.trees[@backingInt(MotionType.dynamic)]
                .query(swept, default_mask_bits, continuousQueryCallback, &ctx);
        }
    }

    if (ctx.fraction < 1.0) {
        // Rewind to the time of impact (sweepTransform2 gives the base-frame pose; lift the
        // position and center back to world by adding base).
        const advanced: Transform2 = sweepTransform2(sweep, ctx.fraction);
        const center_rel: Vec2 = mulAdd2(sweep.c1 * splat2(1.0 - ctx.fraction), ctx.fraction, sweep.c2);
        fast_body.transform = .{ .q = advanced.q, .p = advanced.p + base };
        fast_body.center = center_rel + base;
        fast_body.rot0 = advanced.q;
        fast_body.center0 = fast_body.center;
    }
}

// -- Sensor overlap detection ----------------------------------------------------
//
// Sensors report begin/end touch events without generating a physical response. Each
// sensor keeps two overlap sets: the set built this pass and the set from the previous
// pass. Both are kept sorted by visitor shape index so a linear merge finds exactly the
// shapes that started or stopped overlapping. A visitor's pool cycle is stored alongside
// its index so that a shape destroyed and replaced in the same slot reads as an end of the
// old shape followed by a begin of the new one. box2d: sensor.c

/// State threaded through one sensor's tree queries while collecting its current overlaps.
const SensorQueryContext = struct {
    world: *World,
    sensor: *Sensor,
    sensor_shape_id: ShapeIndex,
    oom: bool = false,
};

/// Overlap callback: filter the candidate, run an exact distance query, and record it in
/// the sensor's current overlap set when the shapes actually touch. box2d: b2SensorQueryCallback
fn sensorQueryCallback(proxy_id: i32, user_data: u64, ctx_ptr: *anyopaque) bool {
    _ = proxy_id;
    const ctx: *SensorQueryContext = @ptrCast(@alignCast(ctx_ptr));
    const world: *World = ctx.world;
    const shape_id: ShapeIndex = @intCast(user_data);
    if (shape_id == ctx.sensor_shape_id) {
        return true; // a sensor never senses itself
    }

    const sensor_shape: *const Shape = &world.shapes.data[ctx.sensor_shape_id];
    const other: *const Shape = &world.shapes.data[shape_id];
    if (other.enable_sensor_events == false) {
        return true;
    }
    if (other.body == sensor_shape.body) {
        return true; // never sense the same body
    }
    if (shouldShapesCollide(sensor_shape.filter, other.filter) == false) {
        return true;
    }

    const sensor_xf: Transform2 = world.bodies.data[sensor_shape.body].transform;
    const other_xf: Transform2 = world.bodies.data[other.body].transform;
    var input: DistanceInput = .{
        .proxy_a = makeShapeDistanceProxy(sensor_shape.geom),
        .proxy_b = makeShapeDistanceProxy(other.geom),
        .transform = invMulTransforms2(sensor_xf, other_xf), // other in the sensor's frame
        .use_radii = true,
    };
    var cache: SimplexCache = SimplexCache.empty;
    const output: DistanceOutput = shapeDistance(&input, &cache);
    if (output.distance >= 10.0 * floatEps(f32)) {
        return true; // not touching
    }

    const cur: u1 = ctx.sensor.current;
    ctx.sensor.overlaps[cur].append(world.allocator, .{
        .shape = shape_id,
        .generation = @intCast(world.shapes.cycle[shape_id]),
    }) catch {
        ctx.oom = true;
    };
    return true;
}

/// Order visitors by shape index so two overlap sets can be merge-diffed.
fn visitorLessThan(_: void, a: Visitor, b: Visitor) bool {
    return a.shape < b.shape;
}

/// Recompute every sensor's overlap set and emit begin/end events for the changes since
/// the previous pass. box2d: b2SensorTask + b2OverlapSensors  sensor.c
fn overlapSensors(world: *World) !void {
    if (world.sensors.items.len == 0) {
        return;
    }
    const bp: *BroadPhase = &world.broadphase;

    for (world.sensors.items) |*sensor| {
        const sensor_shape_id: ShapeIndex = sensor.shape;
        const sensor_shape: *const Shape = &world.shapes.data[sensor_shape_id];

        // Flip to a fresh current buffer; the old current becomes the previous set.
        sensor.current ^= 1;
        const cur: u1 = sensor.current;
        const prev: u1 = cur ^ 1;
        sensor.overlaps[cur].clearRetainingCapacity();

        // A disabled sensor collects nothing, so the diff below emits an end for every
        // overlap it previously had.
        if (sensor_shape.enable_sensor_events) {
            var qctx: SensorQueryContext = .{
                .world = world,
                .sensor = sensor,
                .sensor_shape_id = sensor_shape_id,
            };
            const bounds: Aabb2 = sensor_shape.aabb;
            const mask: u64 = sensor_shape.filter.mask;
            bp.trees[0].query(bounds, mask, sensorQueryCallback, &qctx);
            bp.trees[1].query(bounds, mask, sensorQueryCallback, &qctx);
            bp.trees[2].query(bounds, mask, sensorQueryCallback, &qctx);
            if (qctx.oom) {
                return error.OutOfMemory;
            }
        }

        // Sort the current set and drop any duplicate shape indices.
        std.mem.sort(Visitor, sensor.overlaps[cur].items, {}, visitorLessThan);
        {
            const items: []Visitor = sensor.overlaps[cur].items;
            var unique: usize = 0;
            for (items) |v| {
                if (unique == 0 or items[unique - 1].shape != v.shape) {
                    items[unique] = v;
                    unique += 1;
                }
            }
            sensor.overlaps[cur].shrinkRetainingCapacity(unique);
        }

        // Merge the previous and current sorted sets. A shape only in the previous set
        // ended; a shape only in the current set began; a shape in both with a newer
        // generation ended (old) then began (new).
        const refs1: []const Visitor = sensor.overlaps[prev].items;
        const refs2: []const Visitor = sensor.overlaps[cur].items;
        var k1: usize = 0;
        var k2: usize = 0;
        while (k1 < refs1.len and k2 < refs2.len) {
            const r1: Visitor = refs1[k1];
            const r2: Visitor = refs2[k2];
            if (r1.shape == r2.shape) {
                if (r1.generation < r2.generation) {
                    emitSensorEnd(world, sensor_shape_id, r1.shape);
                    k1 += 1;
                } else if (r1.generation > r2.generation) {
                    emitSensorBegin(world, sensor_shape_id, r2.shape);
                    k2 += 1;
                } else {
                    k1 += 1;
                    k2 += 1;
                }
            } else if (r1.shape < r2.shape) {
                emitSensorEnd(world, sensor_shape_id, r1.shape);
                k1 += 1;
            } else {
                emitSensorBegin(world, sensor_shape_id, r2.shape);
                k2 += 1;
            }
        }
        while (k1 < refs1.len) : (k1 += 1) {
            emitSensorEnd(world, sensor_shape_id, refs1[k1].shape);
        }
        while (k2 < refs2.len) : (k2 += 1) {
            emitSensorBegin(world, sensor_shape_id, refs2[k2].shape);
        }
    }
}

/// Queue a sensor begin-touch event (best effort; dropped on allocation failure).
fn emitSensorBegin(
    world: *World,
    sensor_shape: ShapeIndex,
    visitor_shape: ShapeIndex,
) void {
    world.events.sensor_begin.append(world.allocator, .{
        .sensor_shape = sensor_shape,
        .visitor_shape = visitor_shape,
    }) catch assertUnreachable(@src(), "OOM", .{});
}

/// Queue a sensor end-touch event into the double-buffered end-event list.
fn emitSensorEnd(
    world: *World,
    sensor_shape: ShapeIndex,
    visitor_shape: ShapeIndex,
) void {
    world.events.sensorEnd().append(world.allocator, .{
        .sensor_shape = sensor_shape,
        .visitor_shape = visitor_shape,
    }) catch assertUnreachable(@src(), "OOM", .{});
}

// -- The step --------------------------------------------------------------------
// One simulation step runs a flat, single-threaded version of Box2D's TGS-Soft solve:
// find new contacts, run the narrow phase, wake islands touched by awake bodies, prepare
// constraints, run the sub-stepped solver loop, finalize poses, resolve continuous
// collisions, refit broad-phase bounds, put settled islands to sleep, and update sensors.
// box2d: b2World_Step + b2Collide + b2Solve  physics_world.c / solver.c

/// A movable body that is currently awake (and therefore in the active list).
fn bodyActive(world: *const World, body_index: BodyIndex) bool {
    const body: *const Body = &world.bodies.data[body_index];
    return body.motion_type != .static and body.asleep == false and body.flags.is_disabled == false;
}

/// Partition the prepared contacts and joints into graph colors and reorder each array so
/// that every color occupies a contiguous range (recorded in world.graph.*_color_begin).
/// Within a color no two constraints share a dynamic body, which is what lets the solver
/// process a color four-wide. Joints and contacts share the per-color body bitsets, so a
/// body used by a joint in some color blocks a contact from that color too.
/// box2d: the coloring half of b2AddJointToGraph / b2AddContactToGraph, batched per step.
fn colorConstraintGraph(
    world: *World,
    constraints: []ContactConstraint,
    active_joints: []u32,
) !void {
    // All four scratch arrays below live only for this call; take them from the step arena.
    const gpa: Allocator = world.step_arena.allocator();
    const graph: *ConstraintGraph = &world.graph;
    graph.clearBits();

    // Joints first; they tend to persist and claim the high one-sided colors.
    {
        const n: usize = active_joints.len;
        const joint_color: []u8 = try gpa.alloc(u8, n);
        var counts: [graph_color_count]u32 = std.mem.zeroes([graph_color_count]u32);
        for (active_joints, 0..) |joint_id, i| {
            const j: *const Joint = &world.joints.data[joint_id];
            const color: u32 = graph.assign(
                j.body_a,
                j.body_b,
                world.bodies.data[j.body_a].motion_type,
                world.bodies.data[j.body_b].motion_type,
            );
            joint_color[i] = @intCast(color);
            counts[color] += 1;
        }
        var begin: [graph_color_count + 1]u32 = std.mem.zeroes([graph_color_count + 1]u32);
        var acc: u32 = 0;
        for (0..graph_color_count) |c| {
            begin[c] = acc;
            acc += counts[c];
        }
        begin[graph_color_count] = acc;
        const temp: []u32 = try gpa.alloc(u32, n);
        var pos: [graph_color_count + 1]u32 = begin;
        for (active_joints, 0..) |joint_id, i| {
            const c: usize = joint_color[i];
            temp[pos[c]] = joint_id;
            pos[c] += 1;
        }
        @memcpy(active_joints, temp);
        graph.joint_color_begin = begin;
    }

    // Contacts next, reusing the body bitsets the joints already marked.
    {
        const n: usize = constraints.len;
        const contact_color: []u8 = try gpa.alloc(u8, n);
        var counts: [graph_color_count]u32 = std.mem.zeroes([graph_color_count]u32);
        for (constraints, 0..) |*con, i| {
            const color: u32 = graph.assign(
                con.body_a,
                con.body_b,
                world.bodies.data[con.body_a].motion_type,
                world.bodies.data[con.body_b].motion_type,
            );
            contact_color[i] = @intCast(color);
            counts[color] += 1;
        }
        var begin: [graph_color_count + 1]u32 = std.mem.zeroes([graph_color_count + 1]u32);
        var acc: u32 = 0;
        for (0..graph_color_count) |c| {
            begin[c] = acc;
            acc += counts[c];
        }
        begin[graph_color_count] = acc;
        const temp: []ContactConstraint = try gpa.alloc(ContactConstraint, n);
        var pos: [graph_color_count + 1]u32 = begin;
        for (constraints, 0..) |con, i| {
            const c: usize = contact_color[i];
            temp[pos[c]] = con;
            pos[c] += 1;
        }
        @memcpy(constraints, temp);
        graph.contact_color_begin = begin;
    }
}

/// Queue a joint event for every active joint whose final-substep reaction force or torque
/// reached its threshold. box2d checks the threshold inside each bias sub-step and flags the
/// joint in a bitset; single-threaded here, we evaluate the settled reaction once after the
/// solve, which captures the steady-state stress a breakable joint cares about. The reaction
/// magnitudes match b2GetJointReaction exactly: getConstraintForce/Torque already fold in
/// inv_h and the per-type impulse combinations. box2d: the joint-event pass in b2SolverStage_Restitution
fn emitJointEvents(world: *World, active_joints: []const u32) void {
    const float_max: f32 = floatMax(f32);
    for (active_joints) |joint_id| {
        const j: *const Joint = &world.joints.data[joint_id];
        if (j.force_threshold == float_max and j.torque_threshold == float_max) {
            continue;
        }
        const handle: JointHandle = JointHandle.pack(@intCast(joint_id), world.joints.cycle[joint_id]);
        const force: f32 = length2(getConstraintForce(world, handle));
        const torque: f32 = @abs(getConstraintTorque(world, handle));
        if (force >= j.force_threshold or torque >= j.torque_threshold) {
            world.events.joint_events.append(world.allocator, .{
                .joint = joint_id,
                .user_data = j.user_data,
            }) catch assertUnreachable(@src(), "OOM", .{});
        }
    }
}

/// Narrow phase: recompute each live contact's manifold, emit begin/end touch events on
/// transitions, and destroy contacts whose fattened bounds no longer overlap.
/// box2d: b2Collide + b2CollideTask  physics_world.c
/// Regenerate every contact's manifold from current geometry, fire begin/end-touch events
/// on transitions, and destroy contacts whose fat AABBs no longer overlap. Runs once per
/// step before the solve. box2d: b2Collide  physics_world.c (narrow phase)
fn narrowPhase(world: *World) !void {
    // `disjoint` is consumed at the end of this call, so it lives in the step arena.
    const scratch: Allocator = world.step_arena.allocator();
    var disjoint: std.ArrayListUnmanaged(u32) = .empty;

    for (world.contact_ids.items) |contact_id| {
        const contact: *Contact = &world.contacts.data[contact_id];
        const shape_a: *const Shape = &world.shapes.data[contact.shape_a];
        const shape_b: *const Shape = &world.shapes.data[contact.shape_b];
        const was_touching: bool = contact.flags.sim_touching;

        // Cheap reject: if the fattened AABBs no longer overlap, the contact is dead.
        if (Aabb2.overlaps(shape_a.fat_aabb, shape_b.fat_aabb) == false) {
            contact.flags.sim_touching = false;
            try disjoint.append(scratch, contact_id);
            continue;
        }

        const xf_a: Transform2 = world.bodies.data[contact.body_a].transform;
        const xf_b: Transform2 = world.bodies.data[contact.body_b].transform;
        const offset_a: Vec2 = rotateVec2(xf_a.q, world.bodies.data[contact.body_a].local_center);
        const offset_b: Vec2 = rotateVec2(xf_b.q, world.bodies.data[contact.body_b].local_center);
        const touching: bool = updateContact(
            contact,
            shape_a,
            xf_a,
            offset_a,
            shape_b,
            xf_b,
            offset_b,
            world.narrow_phase,
        );

        if (touching and was_touching == false) {
            contact.flags.touching = true;
            if (contact.flags.enable_contact_events) {
                world.events.contact_begin.append(world.allocator, .{
                    .shape_a = contact.shape_a,
                    .shape_b = contact.shape_b,
                    .contact_id = contact_id,
                }) catch assertUnreachable(@src(), "OOM", .{});
            }
        } else if (touching == false and was_touching) {
            contact.flags.touching = false;
            if (contact.flags.enable_contact_events) {
                world.events.contactEnd().append(world.allocator, .{
                    .shape_a = contact.shape_a,
                    .shape_b = contact.shape_b,
                    .contact_id = contact_id,
                }) catch assertUnreachable(@src(), "OOM", .{});
            }
        }
    }

    for (disjoint.items) |contact_id| {
        destroyContact(world, contact_id);
    }
}

/// Flood-wake any sleeping dynamic body reachable from an awake body through a touching
/// contact or a joint. Newly woken bodies are appended to the active list and processed
/// in turn, so a whole resting island wakes when anything disturbs it. box2d wakes islands
/// during the collide/island-merge phase.
fn wakeIslandsTouchingActive(world: *World) void {
    var i: usize = 0;
    while (i < world.active.items.len) : (i += 1) {
        const body_index: BodyIndex = world.active.items[i];

        var contact_key: u32 = world.bodies.data[body_index].head_contact;
        while (contact_key != null_index) {
            const c: *const Contact = &world.contacts.data[contact_key >> 1];
            const edge: u32 = contact_key & 1;
            contact_key = if (edge == 0) c.edge_a.next_key else c.edge_b.next_key;
            if (c.flags.touching == false) {
                continue;
            }
            const other: BodyIndex = if (edge == 0) c.body_b else c.body_a;
            if (world.bodies.data[other].motion_type == .dynamic and world.bodies.data[other].asleep) {
                wakeBody(world, other);
            }
        }

        var joint_key: u32 = world.bodies.data[body_index].head_joint;
        while (joint_key != null_index) {
            const j: *const Joint = &world.joints.data[joint_key >> 1];
            const edge: u32 = joint_key & 1;
            joint_key = if (edge == 0) j.edge_a.next_key else j.edge_b.next_key;
            const other: BodyIndex = if (edge == 0) j.body_b else j.body_a;
            if (world.bodies.data[other].motion_type == .dynamic and world.bodies.data[other].asleep) {
                wakeBody(world, other);
            }
        }
    }
}

/// Finalize each awake body: fold the solver's accumulated position/rotation deltas into
/// its pose, measure its settling velocity into the sleep timer, reset applied forces, and
/// decide whether it moved fast enough to need a continuous sweep. Bodies that are not fast
/// advance their start-of-step pose here; fast bodies keep theirs for the CCD sweep, and
/// move events are emitted later (after CCD) so they carry the final pose and sleep state.
/// box2d: b2FinalizeBodiesTask  solver.c:550
fn finalizeBodies(world: *World, dt: f32, inv_dt: f32) void {
    const enable_sleep: bool = world.settings.enable_sleep;
    const enable_continuous: bool = world.settings.enable_continuous;

    for (world.active.items) |body_index| {
        const body: *Body = &world.bodies.data[body_index];
        const m: *Motion = &world.motion[body_index];
        const st: *BodyState = &world.state[body_index];
        const v: Vec2 = m.linear_velocity;
        const w: f32 = m.angular_velocity;

        body.center = body.center + st.delta_position;
        body.transform.q = mulRot2(st.delta_rotation, body.transform.q).normalize();

        const settling: f32 = sleepVelocity(
            v,
            w,
            body.max_extent,
            st.delta_position,
            st.delta_rotation,
            inv_dt,
        );
        const max_velocity: f32 = length2(v) + @abs(w) * body.max_extent;
        const max_delta: f32 = length2(st.delta_position) + @abs(st.delta_rotation.sine) * body.max_extent;

        st.delta_position = .{ 0, 0 };
        st.delta_rotation = Rot2.identity;
        body.transform.p = body.center - rotateVec2(body.transform.q, body.local_center);

        m.force = .{ 0, 0 };
        m.torque = 0;
        body.flags.is_fast = false;
        body.flags.had_time_of_impact = false;

        const sleepy: bool = enable_sleep and body.flags.enable_sleep and settling <= body.sleep_threshold;
        if (sleepy == false) {
            body.sleep_time = 0;
            const max_motion: f32 = @max(max_delta, max_velocity * dt);
            if (body.motion_type == .dynamic and enable_continuous and max_motion > 0.5 * body.min_extent) {
                body.flags.is_fast = true; // CCD will advance center0/rot0
            } else {
                body.center0 = body.center;
                body.rot0 = body.transform.q;
            }
        } else {
            body.center0 = body.center;
            body.rot0 = body.transform.q;
            body.sleep_time += dt;
        }
    }
}

/// Recompute the broad-phase bounds of every awake body at its final pose and re-insert
/// any proxy that grew beyond its fattened box (which also queues it for next step's pair
/// finding). box2d folds this into the tail of b2FinalizeBodiesTask.
fn refitActiveBodyAabbs(world: *World) !void {
    for (world.active.items) |body_index| {
        const body: *const Body = &world.bodies.data[body_index];
        var shape_id: u32 = body.head_shape;
        while (shape_id != null_index) {
            const shape: *Shape = &world.shapes.data[shape_id];
            const aabb: Aabb2 = computeFatShapeAabb(shape.geom, body.transform, speculative_distance);
            shape.aabb = aabb;
            if (Aabb2.contains(shape.fat_aabb, aabb) == false) {
                shape.fat_aabb = expandAabb(aabb, shape.aabb_margin);
                // Enlarge the proxy's AABB in place (grow the leaf + mark ancestors) rather than a
                // full remove+reinsert: O(height) pointer-free work vs findBestSibling + rotations.
                // This loosens internal node bounds over time, which the periodic tree rebuild
                // (tree_rebuild_interval) reclaims. box2d: b2BroadPhase_EnlargeProxy + incremental
                // rebuild.
                try world.broadphase.enlargeProxy(world.allocator, shape.proxy_key, shape.fat_aabb);
            }
            shape_id = shape.next_shape;
        }
    }
}

/// Build islands from the touching contacts and joints connecting dynamic bodies, decide
/// which islands have fully settled, emit a move event for every awake body, then put the
/// settled bodies to sleep and compact the active list. box2d: island sleep + b2SplitIsland
/// Group dynamic bodies into islands (connected through touching contacts and joints) using
/// the per-step union-find, mark every body of an island for sleep once the whole island has
/// been below the sleep thresholds for `time_to_sleep`, emit move events, then remove the
/// sleepers from the active list. An island sleeps together so a resting stack doesn't have
/// one box twitch awake. box2d: the island sleep pass of b2World_Step (simplified)
fn sleepIslands(world: *World) void {
    const gpa: Allocator = world.allocator;

    // A body can only sleep once its own sleep_time has reached time_to_sleep, and that resets to 0
    // the instant it moves faster than the sleep threshold. In a perpetually-stirred scene (e.g. the
    // washer drum) no body is ever eligible, so rebuilding islands over every touching contact each
    // step is pure waste. Scan first (O(active)) and skip the whole union-find + aggregate
    // (O(contacts)) whenever nothing can possibly sleep.
    var any_eligible: bool = false;
    if (world.settings.enable_sleep) {
        const tts: f32 = world.settings.time_to_sleep;
        for (world.active.items) |body_index| {
            const body: *const Body = &world.bodies.data[body_index];
            if (body.motion_type == .dynamic and body.flags.enable_sleep and body.sleep_time >= tts) {
                any_eligible = true;
                break;
            }
        }
    }

    if (world.settings.enable_sleep and any_eligible) {
        // Build the islands: union every pair of dynamic bodies sharing a touching contact
        // or a joint. Static/kinematic bodies are never unioned (they don't sleep and
        // shouldn't tie two otherwise-separate islands together).
        dsuReset(world.island_parent);
        for (world.contact_ids.items) |contact_id| {
            const contact: *const Contact = &world.contacts.data[contact_id];
            if (contact.flags.touching == false) {
                continue;
            }
            if (world.bodies.data[contact.body_a].motion_type == .dynamic and
                world.bodies.data[contact.body_b].motion_type == .dynamic)
            {
                dsuUnion(world.island_parent, contact.body_a, contact.body_b);
            }
        }
        for (world.joint_ids.items) |joint_id| {
            const joint: *const Joint = &world.joints.data[joint_id];
            if (world.bodies.data[joint.body_a].motion_type == .dynamic and
                world.bodies.data[joint.body_b].motion_type == .dynamic)
            {
                dsuUnion(world.island_parent, joint.body_a, joint.body_b);
            }
        }
        aggregateAndMarkSleep(
            world.active.items,
            world.bodies.data,
            world.island_parent,
            world.island_can_sleep,
            world.settings.time_to_sleep,
            world.body_sleep,
        );
    } else {
        for (world.active.items) |body_index| {
            world.body_sleep[body_index] = false;
        }
    }

    for (world.active.items) |body_index| {
        const body: *const Body = &world.bodies.data[body_index];
        world.events.body_move.append(gpa, .{
            .transform = body.transform,
            .body = body_index,
            .user_data = body.user_data,
            .fell_asleep = world.body_sleep[body_index],
        }) catch assertUnreachable(@src(), "OOM", .{});
    }

    var i: usize = 0;
    while (i < world.active.items.len) {
        const body_index: BodyIndex = world.active.items[i];
        if (world.body_sleep[body_index]) {
            world.bodies.data[body_index].asleep = true;
            world.motion[body_index].linear_velocity = .{ 0, 0 };
            world.motion[body_index].angular_velocity = 0;
            _ = world.active.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Advance the simulation by `dt` seconds using `sub_step_count` solver sub-steps.
///
/// The pipeline, in order:
///   1. Update the broad phase: re-insert moved proxies and find/destroy contact pairs.
///   2. Narrow phase: regenerate each touching contact's manifold from current geometry.
///   3. Wake any sleeping islands that an awake body now touches.
///   4. Prepare: snapshot the start-of-step pose, build contact constraints and joints,
///      and color the constraint graph so the SIMD solver can batch them.
///   5. The TGS-Soft sub-step loop (see the loop comment), repeated `sub_step_count` times.
///   6. Apply restitution, store impulses for next step's warm start, emit joint events.
///   7. Finalize body poses from the accumulated deltas, run continuous collision for fast
///      bodies, refit broad-phase AABBs, put quiet islands to sleep, optionally rebuild the
///      tree, and run sensor overlap.
/// box2d: b2World_Step  physics_world.c:828
pub fn step(world: *World, dt: f32) !void {
    const sub_step_count: u32 = world.settings.sub_step_count;
    const gpa: Allocator = world.allocator;
    // Reclaim last step's scratch; retain the backing so steady-state steps never re-allocate.
    _ = world.step_arena.reset(.retain_capacity);
    const zstep: profiler.Zone = profiler.zoneNamed(@src(), "p2d.step");
    defer zstep.end();
    world.events.beginStep();

    {
        const zbp: profiler.Zone = profiler.zoneNamed(@src(), "p2d.broadphase");
        defer zbp.end();
        try updateBroadPhasePairs(world);
    }

    // h is the sub-step timestep; inv_h and inv_dt are reused throughout the solve. A
    // dt of 0 (a paused step) leaves them zero so nothing integrates.
    const substep_count: u32 = @max(1, sub_step_count);
    var inv_dt: f32 = 0;
    var h: f32 = 0;
    var inv_h: f32 = 0;
    if (dt > 0.0) {
        inv_dt = 1.0 / dt;
        h = dt / float(substep_count);
        inv_h = float(substep_count) * inv_dt;
    }
    world.inv_h = inv_h;
    world.inv_dt = inv_dt;

    // Contact stiffness softens for large steps; static contacts are twice as stiff.
    const contact_hertz: f32 = @min(world.settings.contact_hertz, 0.125 * inv_h);
    const damping: f32 = world.settings.contact_damping_ratio;
    const contact_softness: Softness = makeSoft(contact_hertz, damping, h);
    const static_softness: Softness = makeSoft(2.0 * contact_hertz, damping, h);

    {
        const znp: profiler.Zone = profiler.zoneNamed(@src(), "p2d.narrowphase");
        defer znp.end();
        try narrowPhase(world);
    }

    if (dt > 0.0) {
        const zprep: profiler.Zone = profiler.zoneNamed(@src(), "p2d.prepare");
        wakeIslandsTouchingActive(world);

        // Prepare: reset per-step solver state and snapshot the start-of-step pose.
        for (world.active.items) |body_index| {
            const body_state: *BodyState = &world.state[body_index];
            body_state.delta_position = .{ 0, 0 };
            body_state.delta_rotation = Rot2.identity;
            body_state.flags.is_speed_capped = false;
            const body: *Body = &world.bodies.data[body_index];
            body.center0 = body.center;
            body.rot0 = body.transform.q;
        }

        // Collect the touching contacts that involve an awake body and build constraints.
        // These live for the rest of the step only, so they come from the step arena.
        const scratch: Allocator = world.step_arena.allocator();
        var touching_ids: std.ArrayListUnmanaged(u32) = .empty;
        for (world.contact_ids.items) |contact_id| {
            const contact: *const Contact = &world.contacts.data[contact_id];
            if (contact.flags.touching == false) {
                continue;
            }
            if (bodyActive(world, contact.body_a) or bodyActive(world, contact.body_b)) {
                try touching_ids.append(scratch, contact_id);
            }
        }
        const constraints: []ContactConstraint = try scratch.alloc(ContactConstraint, touching_ids.items.len);
        prepareContacts(
            constraints,
            touching_ids.items,
            world.contacts.data,
            world.bodies.data,
            world.motion,
            contact_softness,
            static_softness,
            world.settings.enable_warm_starting,
        );

        // Collect the joints that involve an awake body and prepare them.
        var active_joints: std.ArrayListUnmanaged(u32) = .empty;
        for (world.joint_ids.items) |joint_id| {
            const joint: *const Joint = &world.joints.data[joint_id];
            const enabled: bool = world.bodies.data[joint.body_a].flags.is_disabled == false and
                world.bodies.data[joint.body_b].flags.is_disabled == false;
            if (enabled and (bodyActive(world, joint.body_a) or bodyActive(world, joint.body_b))) {
                try active_joints.append(scratch, joint_id);
                prepareJoint(
                    &world.joints.data[joint_id],
                    world.bodies.data,
                    world.motion,
                    h,
                    inv_h,
                    world.settings.enable_warm_starting,
                );
            }
        }

        // Partition contacts and joints into graph colors (contiguous per color), so the
        // solver can later process each color in wide batches. For now this only reorders
        // the constraint arrays; the color boundaries are recorded for the SIMD solver.
        try colorConstraintGraph(world, constraints, active_joints.items);

        // The overflow color (constraints that did not fit any wide color) is solved scalar;
        // the rest are packed into wide blocks of four. With SIMD disabled everything stays
        // scalar so the two paths can be compared.
        const use_simd: bool = world.enable_simd;
        const overflow_begin: u32 = world.graph.contact_color_begin[graph_overflow_index];
        const overflow_constraints: []ContactConstraint =
            if (use_simd) constraints[overflow_begin..] else constraints[0..0];
        const scalar_constraints: []ContactConstraint = if (use_simd) constraints[0..0] else constraints;
        var wide_blocks: std.ArrayListUnmanaged(WideConstraint) = .empty;
        if (use_simd) {
            try buildWideBlocks(world, constraints, &wide_blocks);
        }

        // TGS-Soft sub-step loop. Each sub-step integrates velocities, warm-starts every
        // constraint, then runs two solve passes: a BIASED pass (use_bias = true) that also
        // pushes out position error softly, an integrate-positions step, and a RELAX pass
        // (use_bias = false) that removes the velocity the bias injected. Joints, wide
        // contact blocks, scalar contacts, and the overflow color are all solved each pass.
        const push: f32 = world.settings.contact_push_speed;
        zprep.end();
        const zsolve: profiler.Zone = profiler.zoneNamed(@src(), "p2d.solve");
        const max_linear: f32 = world.settings.max_linear_speed;
        var substep: u32 = 0;
        while (substep < substep_count) : (substep += 1) {
            integrateVelocities(world.active.items, world.motion, world.settings.gravity, h);
            for (active_joints.items) |joint_id| {
                warmStartJoint(&world.joints.data[joint_id], world.state, world.motion);
            }
            warmStartWide(wide_blocks.items, world.state, world.motion);
            warmStartContacts(scalar_constraints, world.state, world.motion);
            warmStartContacts(overflow_constraints, world.state, world.motion);
            for (active_joints.items) |joint_id| {
                solveJoint(&world.joints.data[joint_id], world.state, world.motion, h, inv_h, true);
            }
            solveWide(wide_blocks.items, world.state, world.motion, inv_h, push, true);
            solveContacts(scalar_constraints, world.state, world.motion, inv_h, push, true);
            solveContacts(overflow_constraints, world.state, world.motion, inv_h, push, true);
            integratePositions(world.active.items, world.motion, world.state, h, max_linear, inv_dt);
            for (active_joints.items) |joint_id| {
                solveJoint(&world.joints.data[joint_id], world.state, world.motion, h, inv_h, false);
            }
            solveWide(wide_blocks.items, world.state, world.motion, inv_h, push, false);
            solveContacts(scalar_constraints, world.state, world.motion, inv_h, push, false);
            solveContacts(overflow_constraints, world.state, world.motion, inv_h, push, false);
        }
        zsolve.end();

        const zfin: profiler.Zone = profiler.zoneNamed(@src(), "p2d.finalize");
        const threshold: f32 = world.settings.restitution_threshold;
        applyRestitutionWide(wide_blocks.items, world.state, world.motion, threshold);
        applyRestitution(scalar_constraints, world.state, world.motion, threshold);
        applyRestitution(overflow_constraints, world.state, world.motion, threshold);
        unpackWideImpulses(wide_blocks.items, constraints);
        storeImpulses(constraints, world.contacts.data);
        emitJointEvents(world, active_joints.items);

        finalizeBodies(world, dt, inv_dt);

        if (world.settings.enable_continuous) {
            for (world.active.items) |body_index| {
                if (world.bodies.data[body_index].flags.is_fast) {
                    solveContinuous(world, body_index);
                }
            }
        }
        zfin.end();

        {
            const zrefit: profiler.Zone = profiler.zoneNamed(@src(), "p2d.refit");
            defer zrefit.end();
            try refitActiveBodyAabbs(world);
            // Re-tighten the dynamic tree's internal AABBs (cheap O(n)) to undo the bloat that
            // enlargeProxy leaves behind, keeping queries tight between structural rebuilds.
            try world.broadphase.trees[@backingInt(MotionType.dynamic)].refitTight(gpa);
        }
        {
            const zsleep: profiler.Zone = profiler.zoneNamed(@src(), "p2d.sleep");
            defer zsleep.end();
            sleepIslands(world);
        }
    }

    // Periodically rebuild the dynamic tree to recover query quality.
    world.step_count += 1;
    if (world.tree_rebuild_interval > 0 and world.step_count % world.tree_rebuild_interval == 0) {
        try world.broadphase.trees[@backingInt(MotionType.dynamic)].rebuild(gpa);
    }

    {
        const zsens: profiler.Zone = profiler.zoneNamed(@src(), "p2d.sensors");
        defer zsens.end();
        try overlapSensors(world);
    }
    world.events.endStep();
}

/// Rebuild all three broad-phase trees from scratch. Useful after bulk insertion (e.g. a
/// level load fills the static tree) to give balanced, tight hierarchies for fast queries.
pub fn rebuildBroadphase(world: *World) !void {
    var t: usize = 0;
    while (t < 3) : (t += 1) {
        try world.broadphase.trees[t].rebuild(world.allocator);
    }
}

// -- Scene queries: ray casts and AABB overlap -----------------------------------
//
// Queries run against the three broad-phase trees: a ray or box is tested against proxy
// bounds, then refined per shape. Ray casts return the closest hit; the AABB overlap
// reports every shape whose fattened bounds intersect the query box (a coarse test the
// caller can refine). box2d: geometry.c ray casts + dynamic_tree.c + physics_world.c

/// A ray as an origin plus a translation; the swept interval is [0, max_fraction].
/// box2d: b2RayCastInput  collision.h
pub const RayCastInput = struct {
    origin: Vec2,
    translation: Vec2,
    max_fraction: f32,
};

/// Filter for queries. A shape is considered iff the category/mask bits pass both ways.
/// box2d: b2QueryFilter  collision.h
pub const QueryFilter = struct {
    category: u64 = 1,
    mask: u64 = 0xFFFF_FFFF_FFFF_FFFF,
    /// Skip this body entirely - e.g. so a ray fired from a body doesn't hit itself.
    /// Named/typed to mirror the 3D engine's `QueryFilter.exclude`.
    exclude: ?BodyHandle = null,
    /// Also report sensor shapes. Queries usually want sensors; the solver never does.
    include_sensors: bool = true,
};

/// The symmetric category/mask test used by queries. box2d: b2ShouldQueryCollide
/// Whether a query should report this shape: it must not be the excluded body, sensors are
/// skipped unless requested, and the category/mask must intersect both ways.
fn shouldQueryCollide(shape: *const Shape, query: QueryFilter) bool {
    if (query.include_sensors == false and shape.sensor_index != null_index) {
        return false;
    }
    if (query.exclude) |excluded| {
        if (shape.body == excluded.index()) {
            return false;
        }
    }
    const shape_filter: Filter = shape.filter;
    return (shape_filter.category & query.mask) != 0 and (query.category & shape_filter.mask) != 0;
}

/// Ray vs circle, in the circle's local frame. box2d: b2RayCastCircle  geometry.c:557
fn rayCastCircle(shape: Circle, input: *const RayCastInput) CastOutput {
    const center: Vec2 = shape.center;
    var output: CastOutput = CastOutput.miss;

    const s: Vec2 = input.origin - center;
    const radius: f32 = shape.radius;
    const rr: f32 = radius * radius;

    var len: f32 = 0;
    const d: Vec2 = getLengthAndNormalize2(&len, input.translation);
    if (len == 0.0) {
        if (lengthSq2(s) < rr) {
            output.point = input.origin;
            output.hit = true;
        }
        return output;
    }

    // Closest point on the ray line to the circle center: solve dot(s + t*d, d) = 0.
    const t: f32 = -dot2(s, d);
    const closest: Vec2 = mulAdd2(s, t, d);
    const cc: f32 = dot2(closest, closest);
    if (cc > rr) {
        return output;
    }

    const half_chord: f32 = @sqrt(rr - cc);
    const fraction: f32 = t - half_chord;
    if (fraction < 0.0 or input.max_fraction * len < fraction) {
        if (lengthSq2(s) < rr) {
            output.point = input.origin;
            output.hit = true;
        }
        return output;
    }

    const hit_point: Vec2 = mulAdd2(s, fraction, d);
    output.fraction = fraction / len;
    output.normal = normalizeOrZero2(hit_point);
    output.point = mulAdd2(center, shape.radius, output.normal);
    output.hit = true;
    return output;
}

/// Ray vs capsule, in the capsule's local frame. box2d: b2RayCastCapsule  geometry.c:633
fn rayCastCapsule(shape: Capsule, input: *const RayCastInput) CastOutput {
    var output: CastOutput = CastOutput.miss;

    const v1: Vec2 = shape.center1;
    const v2: Vec2 = shape.center2;
    const edge: Vec2 = v2 - v1;

    var capsule_length: f32 = 0;
    const axis: Vec2 = getLengthAndNormalize2(&capsule_length, edge);
    if (capsule_length < floatEps(f32)) {
        const circle: Circle = .{ .center = v1, .radius = shape.radius };
        return rayCastCircle(circle, input);
    }

    const p1: Vec2 = input.origin;
    const d: Vec2 = input.translation;
    const q: Vec2 = p1 - v1;
    const qa: f32 = dot2(q, axis);
    const qp: Vec2 = mulAdd2(q, -qa, axis);
    const radius: f32 = shape.radius;

    // Does the ray start within the infinite-length capsule?
    if (dot2(qp, qp) < radius * radius) {
        if (qa < 0.0) {
            const circle: Circle = .{ .center = v1, .radius = shape.radius };
            return rayCastCircle(circle, input);
        }
        if (qa > capsule_length) {
            const circle: Circle = .{ .center = v2, .radius = shape.radius };
            return rayCastCircle(circle, input);
        }
        output.point = input.origin;
        output.hit = true;
        return output;
    }

    // Perpendicular to the capsule axis, pointing right.
    var normal: Vec2 = .{ axis[1], -axis[0] };
    var ray_length: f32 = 0;
    const u: Vec2 = getLengthAndNormalize2(&ray_length, d);

    const den: f32 = -axis[0] * u[1] + u[0] * axis[1];
    if (-floatEps(f32) < den and den < floatEps(f32)) {
        return output; // ray parallel to and outside the capsule
    }

    const b1: Vec2 = mulSub2(q, radius, normal);
    const b2: Vec2 = mulAdd2(q, radius, normal);
    const inv_den: f32 = 1.0 / den;
    const s21: f32 = (axis[0] * b1[1] - b1[0] * axis[1]) * inv_den;
    const s22: f32 = (axis[0] * b2[1] - b2[0] * axis[1]) * inv_den;

    var s2: f32 = undefined;
    var b: Vec2 = undefined;
    if (s21 < s22) {
        s2 = s21;
        b = b1;
    } else {
        s2 = s22;
        b = b2;
        normal = -normal;
    }
    if (s2 < 0.0 or input.max_fraction * ray_length < s2) {
        return output;
    }

    const s1: f32 = (-b[0] * u[1] + u[0] * b[1]) * inv_den;
    if (s1 < 0.0) {
        const circle: Circle = .{ .center = v1, .radius = shape.radius };
        return rayCastCircle(circle, input);
    } else if (capsule_length < s1) {
        const circle: Circle = .{ .center = v2, .radius = shape.radius };
        return rayCastCircle(circle, input);
    }
    output.fraction = s2 / ray_length;
    const on_axis: Vec2 = v1 + (v2 - v1) * splat2(s1 / capsule_length);
    output.point = on_axis + normal * splat2(shape.radius);
    output.normal = normal;
    output.hit = true;
    return output;
}

/// Ray vs line segment, in the segment's local frame. When `one_sided`, hits coming from
/// the left (back) face are ignored (used for chain segments). box2d: b2RayCastSegment
fn rayCastSegment(
    shape: Segment,
    input: *const RayCastInput,
    one_sided: bool,
) CastOutput {
    var output: CastOutput = CastOutput.miss;

    if (one_sided) {
        const offset: f32 = cross2(input.origin - shape.point1, shape.point2 - shape.point1);
        if (offset < 0.0) {
            return output;
        }
    }

    const p1: Vec2 = input.origin;
    const d: Vec2 = input.translation;
    const v1: Vec2 = shape.point1;
    const v2: Vec2 = shape.point2;
    const edge: Vec2 = v2 - v1;

    var len: f32 = 0;
    const edge_unit: Vec2 = getLengthAndNormalize2(&len, edge);
    if (len == 0.0) {
        return output;
    }

    var normal: Vec2 = rightPerp2(edge_unit);
    const numerator: f32 = dot2(normal, v1 - p1);
    const denominator: f32 = dot2(normal, d);
    if (denominator == 0.0) {
        return output; // parallel
    }

    const t: f32 = numerator / denominator;
    if (t < 0.0 or input.max_fraction < t) {
        return output;
    }

    const p: Vec2 = mulAdd2(p1, t, d);
    const s: f32 = dot2(p - v1, edge_unit);
    if (s < 0.0 or len < s) {
        return output;
    }

    if (numerator > 0.0) {
        normal = -normal;
    }

    output.fraction = t;
    output.point = p;
    output.normal = normal;
    output.hit = true;
    return output;
}

/// Ray vs polygon, in the polygon's local frame. Sharp polygons use slab clipping;
/// rounded polygons fall back to a shape cast. box2d: b2RayCastPolygon  geometry.c:850
fn rayCastPolygon(shape: Polygon, input: *const RayCastInput) CastOutput {
    if (shape.radius == 0.0) {
        // Shift the math to the first vertex in case the polygon is far from the origin.
        const base: Vec2 = shape.vertices[0];
        const p1: Vec2 = input.origin - base;
        const d: Vec2 = input.translation;
        var lower: f32 = 0.0;
        var upper: f32 = input.max_fraction;
        var index: i32 = -1;
        var output: CastOutput = CastOutput.miss;

        const count: usize = shape.count;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const vertex: Vec2 = shape.vertices[i] - base;
            const numerator: f32 = dot2(shape.normals[i], vertex - p1);
            const denominator: f32 = dot2(shape.normals[i], d);
            if (denominator == 0.0) {
                if (numerator < 0.0) {
                    return output;
                }
            } else {
                if (denominator < 0.0 and numerator < lower * denominator) {
                    lower = numerator / denominator;
                    index = @intCast(i);
                } else if (denominator > 0.0 and numerator < upper * denominator) {
                    upper = numerator / denominator;
                }
            }
            if (upper < lower) {
                return output;
            }
        }

        if (index >= 0) {
            output.fraction = lower;
            output.normal = shape.normals[@intCast(index)];
            output.point = mulAdd2(input.origin, lower, d);
            output.hit = true;
        } else {
            output.point = input.origin;
            output.hit = true;
        }
        return output;
    }

    const cast_input: ShapeCastPairInput = .{
        .proxy_a = makeProxy(shape.vertices[0..shape.count], shape.radius),
        .proxy_b = makeProxy(&[_]Vec2{input.origin}, 0),
        .transform = Transform2.identity,
        .translation_b = input.translation,
        .max_fraction = input.max_fraction,
        .can_encroach = false,
    };
    return shapeCast(&cast_input);
}

/// Ray vs a shape's geometry at a world transform. The ray is taken into the shape's local
/// frame, dispatched, and the hit point/normal lifted back to world. box2d: b2RayCastShape
pub fn rayCastShape(
    input: *const RayCastInput,
    geom: Geometry,
    transform: Transform2,
) CastOutput {
    const local: RayCastInput = .{
        .origin = invTransformPoint2(transform, input.origin),
        .translation = invRotateVec2(transform.q, input.translation),
        .max_fraction = input.max_fraction,
    };
    var output: CastOutput = switch (geom) {
        .circle => |c| rayCastCircle(c, &local),
        .capsule => |cap| rayCastCapsule(cap, &local),
        .polygon => |p| rayCastPolygon(p, &local),
        .segment => |seg| rayCastSegment(seg, &local, false),
        .chain_segment => |cs| rayCastSegment(cs.segment, &local, true),
    };
    output.point = transformPoint2(transform, output.point);
    output.normal = rotateVec2(transform.q, output.normal);
    return output;
}

/// Callback for a tree ray cast: returns the new clip fraction (0 to stop the cast, a
/// value in (0, maxFraction] to shrink it, or maxFraction to leave it unchanged).
pub const TreeRayCastCallback =
    *const fn (input: *const RayCastInput, proxy_id: i32, user_data: u64, ctx: *anyopaque) f32;

/// Walk a tree along a ray, visiting leaves whose bounds the ray could cross and shrinking
/// the search interval as the callback reports closer hits. box2d: b2DynamicTree_RayCast
fn rayCastTree(
    tree: *DynamicTree,
    input: *const RayCastInput,
    mask_bits: u64,
    callback: TreeRayCastCallback,
    ctx: *anyopaque,
) void {
    if (tree.root == node_null) {
        return;
    }

    const p1: Vec2 = input.origin;
    const d: Vec2 = input.translation;
    const r: Vec2 = normalizeOrZero2(d);
    const perp: Vec2 = crossSV2(1.0, r); // perpendicular to the ray
    const abs_perp: Vec2 = @abs(perp);

    var max_fraction: f32 = input.max_fraction;
    var p2: Vec2 = mulAdd2(p1, max_fraction, d);
    var segment_aabb: Aabb2 = .{ .lower = @min(p1, p2), .upper = @max(p1, p2) };

    var stack: [1024]i32 = undefined;
    var count: usize = 0;
    stack[count] = tree.root;
    count += 1;
    var sub_input: RayCastInput = input.*;

    while (count > 0) {
        count -= 1;
        const node_id: i32 = stack[count];
        if (node_id == node_null) {
            continue;
        }
        const node: *TreeNode = tree.at(node_id);
        if ((node.category_bits & mask_bits) == 0 or Aabb2.overlaps(node.aabb, segment_aabb) == false) {
            continue;
        }

        // Separating-axis test of the ray against the node box (Gino, p80).
        const center: Vec2 = Aabb2.center(node.aabb);
        const half: Vec2 = Aabb2.extents(node.aabb);
        const term1: f32 = @abs(dot2(perp, p1 - center));
        const term2: f32 = dot2(abs_perp, half);
        if (term2 < term1) {
            continue;
        }

        if (DynamicTree.isLeaf(node)) {
            sub_input.max_fraction = max_fraction;
            const value: f32 = callback(&sub_input, node_id, node.user_data, ctx);
            if (value == 0.0) {
                return; // caller terminated the cast
            }
            if (value > 0.0 and value <= max_fraction) {
                max_fraction = value;
                p2 = mulAdd2(p1, max_fraction, d);
                segment_aabb = .{ .lower = @min(p1, p2), .upper = @max(p1, p2) };
            }
        } else if (count + 2 <= stack.len) {
            // Visit the nearer child first by pushing it last.
            const c1: Vec2 = Aabb2.center(tree.at(node.child1).aabb);
            const c2: Vec2 = Aabb2.center(tree.at(node.child2).aabb);
            if (lengthSq2(c1 - p1) < lengthSq2(c2 - p1)) {
                stack[count] = node.child2;
                count += 1;
                stack[count] = node.child1;
                count += 1;
            } else {
                stack[count] = node.child1;
                count += 1;
                stack[count] = node.child2;
                count += 1;
            }
        }
    }
}

/// A swept axis-aligned box: the box at fraction 0, translated to box+translation at
/// fraction max_fraction. box2d: b2BoxCastInput
pub const BoxCastInput = struct {
    box: Aabb2,
    translation: Vec2,
    max_fraction: f32,
};
/// Callback for a tree box cast: like the ray callback, returns the new clip fraction
/// (0 to stop, a value in (0, maxFraction] to shrink the sweep, or maxFraction to leave it).
pub const TreeBoxCastCallback =
    *const fn (input: *const BoxCastInput, proxy_id: i32, user_data: u64, ctx: *anyopaque) f32;
/// Walk a tree along a swept box, visiting only leaves the box could cross and shrinking the
/// sweep as the callback reports closer hits. The separating-axis test inflates each node's
/// half-extents by the cast box's half-extents (Minkowski sum), turning the swept-box test
/// into a swept-point test. box2d: b2DynamicTree_BoxCast  dynamic_tree.c
fn boxCastTree(
    tree: *DynamicTree,
    input: *const BoxCastInput,
    mask_bits: u64,
    callback: TreeBoxCastCallback,
    ctx: *anyopaque,
) void {
    if (tree.root == node_null) {
        return;
    }
    const p1: Vec2 = Aabb2.center(input.box);
    const extension: Vec2 = Aabb2.extents(input.box);
    const r: Vec2 = input.translation;
    const v: Vec2 = crossSV2(1.0, r); // perpendicular to the sweep direction
    const abs_v: Vec2 = @abs(v);
    var max_fraction: f32 = input.max_fraction;
    var t: Vec2 = input.translation * splat2(max_fraction);
    var total_aabb: Aabb2 = .{
        .lower = @min(input.box.lower, input.box.lower + t),
        .upper = @max(input.box.upper, input.box.upper + t),
    };
    var stack: [1024]i32 = undefined;
    var count: usize = 0;
    stack[count] = tree.root;
    count += 1;
    var sub_input: BoxCastInput = input.*;
    while (count > 0) {
        count -= 1;
        const node_id: i32 = stack[count];
        if (node_id == node_null) {
            continue;
        }
        const node: *TreeNode = tree.at(node_id);
        if ((node.category_bits & mask_bits) == 0 or Aabb2.overlaps(node.aabb, total_aabb) == false) {
            continue;
        }
        // Separating-axis test of the swept box against the node box (node half-extents
        // inflated by the cast box's half-extents).
        const c: Vec2 = Aabb2.center(node.aabb);
        const h: Vec2 = Aabb2.extents(node.aabb) + extension;
        const term1: f32 = @abs(dot2(v, p1 - c));
        const term2: f32 = dot2(abs_v, h);
        if (term2 < term1) {
            continue;
        }
        if (DynamicTree.isLeaf(node)) {
            sub_input.max_fraction = max_fraction;
            const value: f32 = callback(&sub_input, node_id, node.user_data, ctx);
            if (value == 0.0) {
                return; // caller terminated the cast
            }
            if (value > 0.0 and value < max_fraction) {
                max_fraction = value;
                t = input.translation * splat2(max_fraction);
                total_aabb = .{
                    .lower = @min(input.box.lower, input.box.lower + t),
                    .upper = @max(input.box.upper, input.box.upper + t),
                };
            }
        } else if (count + 2 <= stack.len) {
            // Visit the nearer child first by pushing it last.
            const c1: Vec2 = Aabb2.center(tree.at(node.child1).aabb);
            const c2: Vec2 = Aabb2.center(tree.at(node.child2).aabb);
            if (lengthSq2(c1 - p1) < lengthSq2(c2 - p1)) {
                stack[count] = node.child2;
                count += 1;
                stack[count] = node.child1;
                count += 1;
            } else {
                stack[count] = node.child1;
                count += 1;
                stack[count] = node.child2;
                count += 1;
            }
        }
    }
}

/// The result of a closest-hit ray cast.
/// The closest shape a ray hit. The query returns `?RayResult`, so a miss is `null` and a
/// hit always has valid fields - there is no separate "did it hit" flag to check.
pub const RayResult = struct {
    fraction: f32 = 0,
    point: Vec2 = .{ 0, 0 },
    normal: Vec2 = .{ 0, 0 },
    shape: ShapeIndex = null_index,
};

const RayCastContext = struct {
    world: *World,
    filter: QueryFilter,
    hit: bool = false,
    result: RayResult = .{},
};

fn rayCastClosestCallback(
    input: *const RayCastInput,
    proxy_id: i32,
    user_data: u64,
    ctx_ptr: *anyopaque,
) f32 {
    _ = proxy_id;
    const ctx: *RayCastContext = @ptrCast(@alignCast(ctx_ptr));
    const world: *World = ctx.world;
    const shape_id: ShapeIndex = @intCast(user_data);
    const shape: *const Shape = &world.shapes.data[shape_id];
    if (shouldQueryCollide(shape, ctx.filter) == false) {
        return input.max_fraction;
    }

    const xf: Transform2 = world.bodies.data[shape.body].transform;
    const output: CastOutput = rayCastShape(input, shape.geom, xf);
    if (output.hit) {
        ctx.hit = true;
        ctx.result = .{
            .fraction = output.fraction,
            .point = output.point,
            .normal = output.normal,
            .shape = shape_id,
        };
        return output.fraction; // shrink the ray to this hit
    }
    return input.max_fraction;
}

/// Cast a ray from `origin` along `translation` and return the closest shape it hits.
/// box2d: b2World_CastRayClosest  physics_world.c
pub fn castRayClosest(
    world: *World,
    origin: Vec2,
    translation: Vec2,
    filter: QueryFilter,
) ?RayResult {
    const input: RayCastInput = .{ .origin = origin, .translation = translation, .max_fraction = 1.0 };
    var ctx: RayCastContext = .{ .world = world, .filter = filter };
    const bp: *BroadPhase = &world.broadphase;
    rayCastTree(&bp.trees[0], &input, filter.mask, rayCastClosestCallback, &ctx);
    rayCastTree(&bp.trees[1], &input, filter.mask, rayCastClosestCallback, &ctx);
    rayCastTree(&bp.trees[2], &input, filter.mask, rayCastClosestCallback, &ctx);
    return if (ctx.hit) ctx.result else null;
}

/// Callback for an AABB overlap query: return false to stop the query early.
pub const OverlapCallback = *const fn (shape: ShapeIndex, ctx: *anyopaque) bool;

const OverlapAabbContext = struct {
    world: *World,
    filter: QueryFilter,
    callback: OverlapCallback,
    user_ctx: *anyopaque,
    stop: bool = false,
};

fn overlapAabbCallback(proxy_id: i32, user_data: u64, ctx_ptr: *anyopaque) bool {
    _ = proxy_id;
    const ctx: *OverlapAabbContext = @ptrCast(@alignCast(ctx_ptr));
    const shape_id: ShapeIndex = @intCast(user_data);
    if (shouldQueryCollide(&ctx.world.shapes.data[shape_id], ctx.filter) == false) {
        return true;
    }
    const proceed: bool = ctx.callback(shape_id, ctx.user_ctx);
    if (proceed == false) {
        ctx.stop = true;
    }
    return proceed;
}

/// Report every shape whose fattened bounds overlap `aabb`. This is a broad-phase test:
/// the reported shapes are candidates that the caller may refine. box2d: b2World_OverlapAABB
pub fn overlapAabb(
    world: *World,
    aabb: Aabb2,
    filter: QueryFilter,
    callback: OverlapCallback,
    user_ctx: *anyopaque,
) void {
    var ctx: OverlapAabbContext = .{
        .world = world,
        .filter = filter,
        .callback = callback,
        .user_ctx = user_ctx,
    };
    const bp: *BroadPhase = &world.broadphase;
    bp.trees[0].query(aabb, filter.mask, overlapAabbCallback, &ctx);
    if (ctx.stop) {
        return;
    }
    bp.trees[1].query(aabb, filter.mask, overlapAabbCallback, &ctx);
    if (ctx.stop) {
        return;
    }
    bp.trees[2].query(aabb, filter.mask, overlapAabbCallback, &ctx);
}

// -- Public API: body, world, and event accessors --------------------------------
//
// Application-facing entry points. Bodies are referenced by handle; force/impulse calls
// wake the target (unless told otherwise) and only take effect on awake dynamic bodies,
// matching Box2D. Read-only queries reach through the handle without waking.
// box2d: body.c (b2Body_*) + physics_world.c (b2World_*)

/// Clamp a linear velocity to the world maximum, used after applying an impulse.
/// box2d: b2LimitVelocity  body.c:26
fn limitLinearVelocity(v: Vec2, max_linear_speed: f32) Vec2 {
    const v2: f32 = lengthSq2(v);
    if (v2 > max_linear_speed * max_linear_speed) {
        return v * splat2(max_linear_speed / @sqrt(v2));
    }
    return v;
}

/// Put a movable body to sleep immediately: clear its velocity and drop it from the
/// active list. A body resting against awake bodies will simply be re-woken next step.
fn sleepBody(world: *World, body_index: BodyIndex) void {
    const body: *Body = &world.bodies.data[body_index];
    if (body.motion_type == .static or body.asleep) {
        return;
    }
    body.asleep = true;
    body.sleep_time = 0;
    world.motion[body_index].linear_velocity = .{ 0, 0 };
    world.motion[body_index].angular_velocity = 0;
    removeFromActive(world, body_index);
}

/// Apply a world-space force at a world point (accumulated, integrated next sub-steps).
/// box2d: b2Body_ApplyForce
pub fn applyForce(
    world: *World,
    body: BodyHandle,
    force: Vec2,
    point: Vec2,
    wake: bool,
) void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    if (b.motion_type != .dynamic) {
        return;
    }
    if (wake and b.asleep) {
        wakeBody(world, i);
    }
    if (b.asleep) {
        return;
    }
    const m: *Motion = &world.motion[i];
    m.force = m.force + force;
    m.torque += cross2(point - b.center, force);
}

/// Apply a world-space force at the center of mass (no torque). box2d: b2Body_ApplyForceToCenter
pub fn applyForceToCenter(
    world: *World,
    body: BodyHandle,
    force: Vec2,
    wake: bool,
) void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    if (b.motion_type != .dynamic) {
        return;
    }
    if (wake and b.asleep) {
        wakeBody(world, i);
    }
    if (b.asleep) {
        return;
    }
    world.motion[i].force = world.motion[i].force + force;
}

/// Apply a torque (accumulated). box2d: b2Body_ApplyTorque
pub fn applyTorque(
    world: *World,
    body: BodyHandle,
    torque: f32,
    wake: bool,
) void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    if (b.motion_type != .dynamic) {
        return;
    }
    if (wake and b.asleep) {
        wakeBody(world, i);
    }
    if (b.asleep) {
        return;
    }
    world.motion[i].torque += torque;
}

/// Apply an instantaneous world-space impulse at a world point. box2d: b2Body_ApplyLinearImpulse
pub fn applyLinearImpulse(
    world: *World,
    body: BodyHandle,
    impulse: Vec2,
    point: Vec2,
    wake: bool,
) void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    if (b.motion_type != .dynamic) {
        return;
    }
    if (wake and b.asleep) {
        wakeBody(world, i);
    }
    if (b.asleep) {
        return;
    }
    const m: *Motion = &world.motion[i];
    m.linear_velocity = mulAdd2(m.linear_velocity, m.inverse_mass, impulse);
    m.angular_velocity += m.inverse_inertia * cross2(point - b.center, impulse);
    m.linear_velocity = limitLinearVelocity(m.linear_velocity, world.settings.max_linear_speed);
}

/// Apply an instantaneous impulse at the center of mass. box2d: b2Body_ApplyLinearImpulseToCenter
pub fn applyLinearImpulseToCenter(
    world: *World,
    body: BodyHandle,
    impulse: Vec2,
    wake: bool,
) void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    if (b.motion_type != .dynamic) {
        return;
    }
    if (wake and b.asleep) {
        wakeBody(world, i);
    }
    if (b.asleep) {
        return;
    }
    const m: *Motion = &world.motion[i];
    m.linear_velocity = mulAdd2(m.linear_velocity, m.inverse_mass, impulse);
    m.linear_velocity = limitLinearVelocity(m.linear_velocity, world.settings.max_linear_speed);
}

/// Apply an instantaneous angular impulse. box2d: b2Body_ApplyAngularImpulse
pub fn applyAngularImpulse(
    world: *World,
    body: BodyHandle,
    impulse: f32,
    wake: bool,
) void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    if (b.motion_type != .dynamic) {
        return;
    }
    if (wake and b.asleep) {
        wakeBody(world, i);
    }
    if (b.asleep) {
        return;
    }
    world.motion[i].angular_velocity += world.motion[i].inverse_inertia * impulse;
}

pub fn getLinearVelocity(world: *const World, body: BodyHandle) Vec2 {
    return world.motion[body.index()].linear_velocity;
}

pub fn getAngularVelocity(world: *const World, body: BodyHandle) f32 {
    return world.motion[body.index()].angular_velocity;
}

pub fn setLinearVelocity(world: *World, body: BodyHandle, velocity: Vec2) void {
    const i: BodyIndex = body.index();
    if (world.bodies.data[i].motion_type == .static) {
        return;
    }
    if (lengthSq2(velocity) > 0.0) {
        wakeBody(world, i);
    }
    world.motion[i].linear_velocity = velocity;
}

pub fn setAngularVelocity(world: *World, body: BodyHandle, velocity: f32) void {
    const i: BodyIndex = body.index();
    if (world.bodies.data[i].motion_type == .static) {
        return;
    }
    if (velocity != 0.0) {
        wakeBody(world, i);
    }
    world.motion[i].angular_velocity = velocity;
}

pub fn getPosition(world: *const World, body: BodyHandle) Vec2 {
    return world.bodies.data[body.index()].transform.p;
}

pub fn getRotation(world: *const World, body: BodyHandle) Rot2 {
    return world.bodies.data[body.index()].transform.q;
}

pub fn getTransform(world: *const World, body: BodyHandle) Transform2 {
    return world.bodies.data[body.index()].transform;
}

pub fn getWorldCenterOfMass(world: *const World, body: BodyHandle) Vec2 {
    return world.bodies.data[body.index()].center;
}

pub fn getLocalCenterOfMass(world: *const World, body: BodyHandle) Vec2 {
    return world.bodies.data[body.index()].local_center;
}

pub fn getMass(world: *const World, body: BodyHandle) f32 {
    return world.bodies.data[body.index()].mass;
}

pub fn getRotationalInertia(world: *const World, body: BodyHandle) f32 {
    return world.bodies.data[body.index()].inertia;
}

/// World point for a point given in the body's local frame. box2d: b2Body_GetWorldPoint
pub fn getWorldPoint(world: *const World, body: BodyHandle, local_point: Vec2) Vec2 {
    return transformPoint2(world.bodies.data[body.index()].transform, local_point);
}

/// Local-frame point for a world point. box2d: b2Body_GetLocalPoint
pub fn getLocalPoint(world: *const World, body: BodyHandle, world_point: Vec2) Vec2 {
    return invTransformPoint2(world.bodies.data[body.index()].transform, world_point);
}

/// World direction for a body-local direction. box2d: b2Body_GetWorldVector
pub fn getWorldVector(world: *const World, body: BodyHandle, local_vector: Vec2) Vec2 {
    return rotateVec2(world.bodies.data[body.index()].transform.q, local_vector);
}

/// Body-local direction for a world direction. box2d: b2Body_GetLocalVector
pub fn getLocalVector(world: *const World, body: BodyHandle, world_vector: Vec2) Vec2 {
    return invRotateVec2(world.bodies.data[body.index()].transform.q, world_vector);
}

pub fn getBodyType(world: *const World, body: BodyHandle) MotionType {
    return world.bodies.data[body.index()].motion_type;
}

pub fn getBodyUserData(world: *const World, body: BodyHandle) u64 {
    return world.bodies.data[body.index()].user_data;
}

pub fn setBodyUserData(world: *World, body: BodyHandle, user_data: u64) void {
    world.bodies.data[body.index()].user_data = user_data;
}

pub fn isAwake(world: *const World, body: BodyHandle) bool {
    const b: *const Body = &world.bodies.data[body.index()];
    return b.motion_type != .static and b.asleep == false;
}

/// Wake or sleep a body. box2d: b2Body_SetAwake
pub fn setAwake(world: *World, body: BodyHandle, awake: bool) void {
    const i: BodyIndex = body.index();
    if (awake) {
        wakeBody(world, i);
    } else {
        sleepBody(world, i);
    }
}

pub fn getMotionQuality(world: *const World, body: BodyHandle) MotionQuality {
    return if (world.bodies.data[body.index()].flags.is_bullet) .linear_cast else .discrete;
}

pub fn setMotionQuality(world: *World, body: BodyHandle, quality: MotionQuality) void {
    world.bodies.data[body.index()].flags.is_bullet = quality == .linear_cast;
}

/// Set world gravity. Sleeping bodies keep resting until something wakes them, as in Box2D.
pub fn setGravity(world: *World, gravity: Vec2) void {
    world.settings.gravity = gravity;
}

pub fn getGravity(world: *const World) Vec2 {
    return world.settings.gravity;
}

/// Contact events produced by the most recent step.
pub const ContactEvents = struct {
    begin: []const ContactBeginTouchEvent,
    end: []const ContactEndTouchEvent,
    hit: []const ContactHitEvent,
};

/// Sensor begin/end events produced by the most recent step.
pub const SensorEvents = struct {
    begin: []const SensorBeginTouchEvent,
    end: []const SensorEndTouchEvent,
};

/// Read the contact events from the most recent step. The end events live in the buffer
/// that was written this step (the one not currently being filled). box2d: b2World_GetContactEvents
pub fn getContactEvents(world: *const World) ContactEvents {
    return .{
        .begin = world.events.contact_begin.items,
        .end = world.events.contact_end[world.events.end_current ^ 1].items,
        .hit = world.events.contact_hit.items,
    };
}

/// Read the sensor events from the most recent step. box2d: b2World_GetSensorEvents
pub fn getSensorEvents(world: *const World) SensorEvents {
    return .{
        .begin = world.events.sensor_begin.items,
        .end = world.events.sensor_end[world.events.end_current ^ 1].items,
    };
}

/// One point of a contact's live manifold, in world space.
pub const ContactPointData = struct {
    point: Vec2, // world-space contact point
    normal_impulse: f32, // normal impulse accumulated across the last step's sub-steps
};

/// Live data for a contact: the world-space normal (A->B) and up to two manifold points. Pair with a
/// contact_id from a begin-touch event, or iterate liveContactId. box2d: b2ContactData / b2Contact_GetData
pub const ContactData = struct {
    shape_a: ShapeIndex,
    shape_b: ShapeIndex,
    normal: Vec2,
    point_count: u32,
    points: [2]ContactPointData,
};

/// Number of live contacts (the dense list the solver maintains). Iterate with liveContactId +
/// getContactData; filter to touching pairs with isContactTouching.
pub fn liveContactCount(world: *const World) u32 {
    return @intCast(world.contact_ids.items.len);
}

/// The contact_id of the i-th live contact (i < liveContactCount).
pub fn liveContactId(world: *const World, i: u32) u32 {
    return world.contact_ids.items[i];
}

/// Whether a contact is actually touching (vs. merely a speculative/broad-phase pair).
pub fn isContactTouching(world: *const World, contact_id: u32) bool {
    return world.contacts.data[contact_id].flags.touching;
}

/// The current manifold of a contact, with points lifted into world space (body A's center of mass
/// plus each point's anchor, matching b2Body_GetWorldCenter + anchorA). box2d: b2Contact_GetData
pub fn getContactData(world: *const World, contact_id: u32) ContactData {
    const c: *const Contact = &world.contacts.data[contact_id];
    const com_a: Vec2 = world.bodies.data[c.body_a].center;
    var out: ContactData = .{
        .shape_a = c.shape_a,
        .shape_b = c.shape_b,
        .normal = c.manifold.normal,
        .point_count = c.manifold.count,
        .points = .{
            .{ .point = .{ 0, 0 }, .normal_impulse = 0 },
            .{ .point = .{ 0, 0 }, .normal_impulse = 0 },
        },
    };
    var i: u32 = 0;
    while (i < c.manifold.count) : (i += 1) {
        out.points[i] = .{
            .point = com_a + c.manifold.points[i].anchor_a,
            .normal_impulse = c.manifold.points[i].total_normal_impulse,
        };
    }
    return out;
}

/// Read the body move events from the most recent step. box2d: b2World_GetBodyEvents
pub fn getBodyEvents(world: *const World) []const BodyMoveEvent {
    return world.events.body_move.items;
}
/// Read the joint events (threshold exceedances) from the most recent step.
/// box2d: b2World_GetJointEvents
pub fn getJointEvents(world: *const World) []const JointEvent {
    return world.events.joint_events.items;
}

// -- Public API: world snapshot / restore ----------------------------------------
//
// An in-memory checkpoint of the world's body / shape / joint state, and a restore that
// writes it back into the SAME live world. This is NOT box2d's full b2World_Snapshot byte
// image: every entity pool here is backed by a parallel ECS archetype registry kept in
// lockstep with the pool, and that registry is not cheaply byte-copyable, so the contacts
// pool (the only one whose allocation set changes mid-step) cannot just be memcpy'd back.
//
// Instead the checkpoint captures the persistent per-entity DATA - body transforms + sleep
// state, shape geometry/AABBs, joint warm-start impulses, and the motion (velocity) and
// solver-delta side tables. Restore writes that data back (pool ALLOCATION state and the ECS
// registry are left untouched, so the lockstep invariant holds), then rebuilds the derived
// collision state: every live contact is destroyed through the normal ecs-safe path, each
// body's stale contact links are cleared, every shape's broad-phase proxy is re-synced to its
// restored position, and movable bodies are woken so the next step re-finds contacts from the
// restored geometry. The body / shape / joint *set* is assumed unchanged between capture and
// restore (true for the snapshot demo). Because contacts are re-found rather than restored,
// one step of warm-start is lost: this reproduces the captured geometry exactly but is a state
// checkpoint, not a bit-identical continuation. box2d: b2World_Snapshot / b2World_Restore.

fn dupSlice(
    comptime T: type,
    gpa: Allocator,
    src: []const T,
) ![]T {
    const out: []T = try gpa.alloc(T, src.len);
    @memcpy(out, src);
    return out;
}

pub const WorldSnapshot = struct {
    bodies: []Body,
    shapes: []Shape,
    joints: []Joint,
    motion: []Motion,
    state: []BodyState,
    step_count: u64,
    next_chain_id: u32,
    inv_h: f32,
    inv_dt: f32,

    pub fn deinit(self: *WorldSnapshot, gpa: Allocator) void {
        gpa.free(self.bodies);
        gpa.free(self.shapes);
        gpa.free(self.joints);
        gpa.free(self.motion);
        gpa.free(self.state);
    }
};

/// Capture the world's per-entity state into an owned checkpoint. The caller owns the result
/// and must `deinit` it. box2d: b2World_Snapshot.
pub fn snapshot(world: *const World, gpa: Allocator) !WorldSnapshot {
    return .{
        .bodies = try dupSlice(Body, gpa, world.bodies.data),
        .shapes = try dupSlice(Shape, gpa, world.shapes.data),
        .joints = try dupSlice(Joint, gpa, world.joints.data),
        .motion = try dupSlice(Motion, gpa, world.motion),
        .state = try dupSlice(BodyState, gpa, world.state),
        .step_count = world.step_count,
        .next_chain_id = world.next_chain_id,
        .inv_h = world.inv_h,
        .inv_dt = world.inv_dt,
    };
}

/// Build a per-slot "is this slot free" mask for a pool, so callers can walk only the live
/// slots of `data[1..watermark]`.
fn poolFreedMask(
    comptime Pool: type,
    gpa: Allocator,
    pool: *const Pool,
) ![]bool {
    const freed: []bool = try gpa.alloc(bool, pool.data.len);
    @memset(freed, false);
    var n: u32 = 0;
    while (n < pool.free_count) : (n += 1) {
        freed[pool.free_list[n]] = true;
    }
    return freed;
}

/// Restore the world to a captured checkpoint (same world + capacity). box2d: b2World_Restore.
pub fn restore(
    world: *World,
    gpa: Allocator,
    snap: *const WorldSnapshot,
) !void {
    // 1. Tear down every live contact through the normal path (clears the pair set, unlinks
    //    the contact graph on the *current* bodies, frees each contact pool+ecs slot in
    //    lockstep). Iterate a copy: destroyContact swap-removes from contact_ids.
    const live_contacts: []u32 = try dupSlice(u32, gpa, world.contact_ids.items);
    defer gpa.free(live_contacts);
    for (live_contacts) |cid| {
        destroyContact(world, cid);
    }

    // 2. Write captured per-entity data back. Only DATA is copied; pool allocation state and
    //    the ECS registry are untouched, preserving the lockstep invariant.
    @memcpy(world.bodies.data, snap.bodies);
    @memcpy(world.shapes.data, snap.shapes);
    @memcpy(world.joints.data, snap.joints);
    @memcpy(world.motion, snap.motion);
    @memcpy(world.state, snap.state);

    // 3. Rebuild body-side derived state: drop the stale contact links carried in by the body
    //    data copy, wake every movable body, and rebuild the active list.
    const body_freed: []bool = try poolFreedMask(Bodies, gpa, &world.bodies);
    defer gpa.free(body_freed);
    world.active.clearRetainingCapacity();
    var i: u32 = 1;
    while (i < world.bodies.watermark) : (i += 1) {
        if (body_freed[i]) {
            continue;
        }
        const b: *Body = &world.bodies.data[i];
        b.head_contact = null_index;
        b.contact_count = 0;
        if (b.motion_type != .static and b.flags.is_disabled == false) {
            b.asleep = false;
            b.sleep_time = 0;
            world.active.appendAssumeCapacity(i);
        }
    }

    // 4. Re-sync each live shape's broad-phase proxy to its restored position (recompute the
    //    fat AABB and move the proxy, which also queues it for pair-finding so the next step
    //    re-creates the contacts torn down in step 1).
    const shape_freed: []bool = try poolFreedMask(Shapes, gpa, &world.shapes);
    defer gpa.free(shape_freed);
    var si: u32 = 1;
    while (si < world.shapes.watermark) : (si += 1) {
        if (shape_freed[si]) {
            continue;
        }
        const s: *Shape = &world.shapes.data[si];
        const b: *const Body = &world.bodies.data[s.body];
        const aabb: Aabb2 = computeFatShapeAabb(s.geom, b.transform, speculative_distance);
        s.aabb = aabb;
        s.fat_aabb = expandAabb(aabb, s.aabb_margin);
        if (s.proxy_key != null_index) {
            try world.broadphase.moveProxy(world.allocator, s.proxy_key, s.fat_aabb);
        }
    }

    // 5. Restore the cached step counters.
    world.step_count = snap.step_count;
    world.next_chain_id = snap.next_chain_id;
    world.inv_h = snap.inv_h;
    world.inv_dt = snap.inv_dt;
}

fn snapshotPositionHash(world: *const World) u64 {
    var h: std.hash.Wyhash = std.hash.Wyhash.init(0);
    var i: u32 = 1;
    while (i < world.bodies.watermark) : (i += 1) {
        const t: Transform2 = world.bodies.data[i].transform;
        h.update(std.mem.asBytes(&t.p));
        h.update(std.mem.asBytes(&t.q));
        h.update(std.mem.asBytes(&world.motion[i].linear_velocity));
    }
    return h.final();
}

test "world snapshot/restore reproduces the captured geometry" {
    const gpa: Allocator = std.heap.page_allocator;
    var world: World = try World.init(gpa, 64);
    defer world.deinit(gpa);
    world.settings.gravity = .{ 0, -10 };

    const ground: BodyHandle = try createBody(&world, .{ .motion_type = .static, .position = .{ 0, 0 } });
    _ = try createShape(&world, ground, .{ .geom = .{ .polygon = makeBox(10, 0.5) } });
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const fi: f32 = float(i);
        const b: BodyHandle = try createBody(&world, .{
            .motion_type = .dynamic,
            .position = .{ -2 + fi * 0.8, 3 + fi * 0.6 },
        });
        _ = try createShape(&world, b, .{ .geom = .{ .polygon = makeBox(0.4, 0.4) }, .density = 1 });
    }

    const dt: f32 = 1.0 / 60.0;
    var s: u32 = 0;
    while (s < 40) : (s += 1) {
        try step(&world, dt);
    }

    var snap: WorldSnapshot = try snapshot(&world, gpa);
    defer snap.deinit(gpa);
    const snap_hash: u64 = snapshotPositionHash(&world);

    var k: u32 = 0;
    while (k < 30) : (k += 1) {
        try step(&world, dt);
    }
    const diverged_hash: u64 = snapshotPositionHash(&world);

    try restore(&world, gpa, &snap);
    const restored_hash: u64 = snapshotPositionHash(&world);

    // Restore reproduces the captured transforms + velocities exactly.
    try expect(restored_hash == snap_hash);
    // The free run actually progressed, so restore genuinely moved the world back.
    try expect(diverged_hash != snap_hash);

    // The restored world is consistent enough to keep stepping without blowing up.
    try step(&world, dt);
    const px: f32 = world.bodies.data[ground.index()].transform.p[0];
    try expect(px == px and px > -1.0e9 and px < 1.0e9);
}

test "world snapshot/restore reproduces a jointed world" {
    // The SnapShot demo scene is falling hinges (revolute-jointed links), so exercise the
    // joint-bearing restore path directly: a swinging chain of boxes pinned to the ground.
    const gpa: Allocator = std.heap.page_allocator;
    var world: World = try World.init(gpa, 64);
    defer world.deinit(gpa);
    world.settings.gravity = .{ 0, -10 };

    const ground: BodyHandle = try createBody(&world, .{ .motion_type = .static, .position = .{ 0, 6 } });
    var prev: BodyHandle = ground;
    var anchor: Vec2 = .{ 0, 6 };
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const fi: f32 = float(i);
        const link: BodyHandle = try createBody(&world, .{
            .motion_type = .dynamic,
            .position = .{ 0.6 + fi * 1.0, 6 },
        });
        _ = try createShape(&world, link, .{ .geom = .{ .polygon = makeBox(0.5, 0.125) }, .density = 1 });
        _ = try createRevoluteJoint(&world, .{
            .base = .{
                .body_a = prev,
                .body_b = link,
                .local_frame_a = .{ .p = getLocalPoint(&world, prev, anchor), .q = Rot2.identity },
                .local_frame_b = .{ .p = getLocalPoint(&world, link, anchor), .q = Rot2.identity },
            },
        });
        prev = link;
        anchor = .{ anchor[0] + 1.0, 6 };
    }

    const dt: f32 = 1.0 / 60.0;
    var s: u32 = 0;
    while (s < 40) : (s += 1) {
        try step(&world, dt);
    }

    var snap: WorldSnapshot = try snapshot(&world, gpa);
    defer snap.deinit(gpa);
    const snap_hash: u64 = snapshotPositionHash(&world);

    var k: u32 = 0;
    while (k < 30) : (k += 1) {
        try step(&world, dt);
    }
    const diverged_hash: u64 = snapshotPositionHash(&world);

    try restore(&world, gpa, &snap);
    const restored_hash: u64 = snapshotPositionHash(&world);

    try expect(restored_hash == snap_hash);
    try expect(diverged_hash != snap_hash);

    // Keep stepping past the restore: the jointed world stays finite (no NaN / blow-up).
    var n: u32 = 0;
    while (n < 10) : (n += 1) {
        try step(&world, dt);
    }
    const tip: f32 = world.bodies.data[prev.index()].transform.p[1];
    try expect(tip == tip and tip > -1.0e6 and tip < 1.0e6);
}

// -- Public API: per-type joint constructors -------------------------------------
//
// Sugar over createJoint: each takes the common base plus that joint's configuration,
// packs the JointData variant (applying Box2D's construction-time clamps), and creates
// the joint. box2d: b2Create<Type>Joint  joint.c

/// Fields common to every joint, mirroring Box2D's b2JointDef base. The two local frames
/// place the joint relative to each body's origin; defaults pin them at the body origins.
pub const JointBaseDef = struct {
    body_a: BodyHandle,
    body_b: BodyHandle,
    local_frame_a: Transform2 = Transform2.identity,
    local_frame_b: Transform2 = Transform2.identity,
    constraint_hertz: f32 = 60,
    constraint_damping_ratio: f32 = 2,
    force_threshold: f32 = floatMax(f32),
    torque_threshold: f32 = floatMax(f32),
    collide_connected: bool = false,
    user_data: u64 = 0,
};

fn createJointFromBase(world: *World, base: JointBaseDef, data: JointData) !JointHandle {
    return createJoint(world, .{
        .body_a = base.body_a,
        .body_b = base.body_b,
        .local_frame_a = base.local_frame_a,
        .local_frame_b = base.local_frame_b,
        .constraint_hertz = base.constraint_hertz,
        .constraint_damping_ratio = base.constraint_damping_ratio,
        .force_threshold = base.force_threshold,
        .torque_threshold = base.torque_threshold,
        .collide_connected = base.collide_connected,
        .user_data = base.user_data,
        .data = data,
    });
}

/// A pin joint: the two anchor frames are held coincident. Optional angular spring (toward
/// target_angle), motor, and angle limits. box2d: b2CreateRevoluteJoint
pub const RevoluteJointDef = struct {
    base: JointBaseDef,
    enable_spring: bool = false,
    hertz: f32 = 0,
    damping_ratio: f32 = 0,
    target_angle: f32 = 0,
    enable_motor: bool = false,
    motor_speed: f32 = 0,
    max_motor_torque: f32 = 0,
    enable_limit: bool = false,
    lower_angle: f32 = 0,
    upper_angle: f32 = 0,
};

pub fn createRevoluteJoint(world: *World, def: RevoluteJointDef) !JointHandle {
    assert(def.lower_angle <= def.upper_angle, @src());
    return createJointFromBase(world, def.base, .{ .revolute = .{
        .enable_spring = def.enable_spring,
        .hertz = def.hertz,
        .damping_ratio = def.damping_ratio,
        .target_angle = clamp(def.target_angle, -pi, pi),
        .enable_motor = def.enable_motor,
        .motor_speed = def.motor_speed,
        .max_motor_torque = def.max_motor_torque,
        .enable_limit = def.enable_limit,
        .lower_angle = def.lower_angle,
        .upper_angle = def.upper_angle,
    } });
}

/// A linear spring/limit/motor along the line between the two anchors. box2d: b2CreateDistanceJoint
pub const DistanceJointDef = struct {
    base: JointBaseDef,
    length: f32 = 1,
    enable_spring: bool = false,
    hertz: f32 = 0,
    damping_ratio: f32 = 0,
    // Spring force is clamped to this range; default unbounded so an enabled spring is not
    // silently pinned to zero force. box2d: b2DefaultDistanceJointDef (+/-FLT_MAX)
    lower_spring_force: f32 = -floatMax(f32),
    upper_spring_force: f32 = floatMax(f32),
    enable_limit: bool = false,
    min_length: f32 = 0,
    // box2d defaults the upper limit to B2_HUGE (huge but finite), not infinity.
    max_length: f32 = huge_length,
    enable_motor: bool = false,
    motor_speed: f32 = 0,
    max_motor_force: f32 = 0,
};

pub fn createDistanceJoint(world: *World, def: DistanceJointDef) !JointHandle {
    assert(def.length > 0.0, @src());
    assert(def.lower_spring_force <= def.upper_spring_force, @src());
    return createJointFromBase(world, def.base, .{ .distance = .{
        .length = @max(def.length, linear_slop),
        .hertz = def.hertz,
        .damping_ratio = def.damping_ratio,
        .min_length = @max(def.min_length, linear_slop),
        .max_length = @max(def.min_length, def.max_length),
        .max_motor_force = def.max_motor_force,
        .motor_speed = def.motor_speed,
        .enable_spring = def.enable_spring,
        .lower_spring_force = def.lower_spring_force,
        .upper_spring_force = def.upper_spring_force,
        .enable_limit = def.enable_limit,
        .enable_motor = def.enable_motor,
    } });
}

/// A sliding joint along frame A's x-axis, with optional spring, limit, and motor.
/// box2d: b2CreatePrismaticJoint
pub const PrismaticJointDef = struct {
    base: JointBaseDef,
    enable_spring: bool = false,
    hertz: f32 = 0,
    damping_ratio: f32 = 0,
    target_translation: f32 = 0,
    enable_motor: bool = false,
    motor_speed: f32 = 0,
    max_motor_force: f32 = 0,
    enable_limit: bool = false,
    lower_translation: f32 = 0,
    upper_translation: f32 = 0,
};

pub fn createPrismaticJoint(world: *World, def: PrismaticJointDef) !JointHandle {
    assert(def.lower_translation <= def.upper_translation, @src());
    return createJointFromBase(world, def.base, .{ .prismatic = .{
        .hertz = def.hertz,
        .damping_ratio = def.damping_ratio,
        .target_translation = def.target_translation,
        .lower_translation = def.lower_translation,
        .upper_translation = def.upper_translation,
        .max_motor_force = def.max_motor_force,
        .motor_speed = def.motor_speed,
        .enable_spring = def.enable_spring,
        .enable_limit = def.enable_limit,
        .enable_motor = def.enable_motor,
    } });
}

/// A wheel/suspension joint: a perpendicular spring along frame A's y-axis plus a motor
/// about the axle and translation limits along the axis. box2d: b2CreateWheelJoint
pub const WheelJointDef = struct {
    base: JointBaseDef,
    // The suspension spring is on by default, matching b2DefaultWheelJointDef - a wheel
    // joint left at defaults behaves as a sprung suspension, not a rigid slider.
    enable_spring: bool = true,
    hertz: f32 = 1.0,
    damping_ratio: f32 = 0.7,
    enable_motor: bool = false,
    motor_speed: f32 = 0,
    max_motor_torque: f32 = 0,
    enable_limit: bool = false,
    lower_translation: f32 = 0,
    upper_translation: f32 = 0,
};

pub fn createWheelJoint(world: *World, def: WheelJointDef) !JointHandle {
    assert(def.lower_translation <= def.upper_translation, @src());
    return createJointFromBase(world, def.base, .{ .wheel = .{
        .hertz = def.hertz,
        .damping_ratio = def.damping_ratio,
        .max_motor_torque = def.max_motor_torque,
        .motor_speed = def.motor_speed,
        .lower_translation = def.lower_translation,
        .upper_translation = def.upper_translation,
        .enable_spring = def.enable_spring,
        .enable_motor = def.enable_motor,
        .enable_limit = def.enable_limit,
    } });
}

/// A pulley joint: two bodies hang from an inextensible rope over two fixed world-space ground
/// anchors. The rest lengths and the conserved total (lengthA + ratio*lengthB) are captured from
/// the bodies' initial anchor positions, so pulling one side down raises the other.
/// box2d v2: b2CreatePulleyJoint (this joint type was removed in box2d v3).
pub const PulleyJointDef = struct {
    base: JointBaseDef,
    ground_anchor_a: Vec2,
    ground_anchor_b: Vec2,
    ratio: f32 = 1,
};

pub fn createPulleyJoint(world: *World, def: PulleyJointDef) !JointHandle {
    assert(def.ratio > 0.0, @src());
    return createJointFromBase(world, def.base, .{ .pulley = .{
        .ground_anchor_a = def.ground_anchor_a,
        .ground_anchor_b = def.ground_anchor_b,
        .ratio = def.ratio,
    } });
}

/// A rigid (or softly sprung) weld holding the two frames coincident in both position and
/// angle. Zero hertz means a hard constraint. box2d: b2CreateWeldJoint
pub const WeldJointDef = struct {
    base: JointBaseDef,
    linear_hertz: f32 = 0,
    linear_damping_ratio: f32 = 0,
    angular_hertz: f32 = 0,
    angular_damping_ratio: f32 = 0,
};

pub fn createWeldJoint(world: *World, def: WeldJointDef) !JointHandle {
    return createJointFromBase(world, def.base, .{ .weld = .{
        .linear_hertz = def.linear_hertz,
        .linear_damping_ratio = def.linear_damping_ratio,
        .angular_hertz = def.angular_hertz,
        .angular_damping_ratio = def.angular_damping_ratio,
    } });
}

/// Drives the relative transform of the two bodies toward target velocities, capped by
/// max force/torque, with optional springs. Used for character/vehicle control.
/// box2d: b2CreateMotorJoint
pub const MotorJointDef = struct {
    base: JointBaseDef,
    linear_velocity: Vec2 = .{ 0, 0 },
    max_velocity_force: f32 = 0,
    angular_velocity: f32 = 0,
    max_velocity_torque: f32 = 0,
    linear_hertz: f32 = 0,
    linear_damping_ratio: f32 = 0,
    max_spring_force: f32 = 0,
    angular_hertz: f32 = 0,
    angular_damping_ratio: f32 = 0,
    max_spring_torque: f32 = 0,
};

pub fn createMotorJoint(world: *World, def: MotorJointDef) !JointHandle {
    return createJointFromBase(world, def.base, .{ .motor = .{
        .linear_velocity = def.linear_velocity,
        .max_velocity_force = def.max_velocity_force,
        .angular_velocity = def.angular_velocity,
        .max_velocity_torque = def.max_velocity_torque,
        .linear_hertz = def.linear_hertz,
        .linear_damping_ratio = def.linear_damping_ratio,
        .max_spring_force = def.max_spring_force,
        .angular_hertz = def.angular_hertz,
        .angular_damping_ratio = def.angular_damping_ratio,
        .max_spring_torque = def.max_spring_torque,
    } });
}

/// A non-constraining joint that just disables collision between two bodies.
/// box2d: b2CreateFilterJoint
pub fn createFilterJoint(world: *World, base: JointBaseDef) !JointHandle {
    return createJointFromBase(world, base, .filter);
}

// -- Public API: shape getters and setters ---------------------------------------
//
// Material and filter live on the shape; changing the filter or the body's set of shapes
// can invalidate existing contacts, so those paths destroy affected contacts and re-queue
// the broad-phase proxy. box2d: shape.c (b2Shape_*)

/// Destroy every contact touching this shape (waking both bodies) and re-queue its proxy
/// so the broad phase re-evaluates pairs next step. A category-bit change forces a proxy
/// rebuild because the tree sorts on category. box2d: b2ResetProxy  shape.c
fn resetShapeProxy(world: *World, shape_index: ShapeIndex, destroy_proxy: bool) !void {
    const s: *Shape = &world.shapes.data[shape_index];
    const body_index: BodyIndex = s.body;
    const body: *Body = &world.bodies.data[body_index];

    var contact_key: u32 = body.head_contact;
    while (contact_key != null_index) {
        const contact_id: u32 = contact_key >> 1;
        const edge_index: u32 = contact_key & 1;
        const c: *const Contact = &world.contacts.data[contact_id];
        contact_key = if (edge_index == 0) c.edge_a.next_key else c.edge_b.next_key;
        if (c.shape_a == shape_index or c.shape_b == shape_index) {
            wakeBody(world, c.body_a);
            wakeBody(world, c.body_b);
            destroyContact(world, contact_id);
        }
    }

    const margin: f32 = if (body.motion_type == .static) speculative_distance else s.aabb_margin;
    s.aabb = computeFatShapeAabb(s.geom, body.transform, speculative_distance);
    s.fat_aabb = expandAabb(s.aabb, margin);

    if (s.proxy_key != null_index) {
        if (destroy_proxy) {
            world.broadphase.destroyProxy(s.proxy_key);
            s.proxy_key = try world.broadphase.createProxy(
                world.allocator,
                body.motion_type,
                s.fat_aabb,
                s.filter.category,
                shape_index,
                true,
            );
        } else {
            try world.broadphase.moveProxy(world.allocator, s.proxy_key, s.fat_aabb);
        }
    }
}

pub fn getShapeBody(world: *const World, shape: ShapeHandle) BodyHandle {
    const body_index: BodyIndex = world.shapes.data[shape.index()].body;
    return BodyHandle.pack(@intCast(body_index), world.bodies.cycle[body_index]);
}

pub fn getShapeAabb(world: *const World, shape: ShapeHandle) Aabb2 {
    return world.shapes.data[shape.index()].aabb;
}

pub fn getDensity(world: *const World, shape: ShapeHandle) f32 {
    return world.shapes.data[shape.index()].density;
}

/// Set a shape's density. With `update_mass` set, the owning body's mass, center, and
/// inertia are recomputed from all its shapes. box2d: b2Shape_SetDensity
pub fn setDensity(
    world: *World,
    shape: ShapeHandle,
    density: f32,
    update_mass: bool,
) void {
    const i: ShapeIndex = shape.index();
    const s: *Shape = &world.shapes.data[i];
    if (density == s.density) {
        return;
    }
    s.density = density;
    if (update_mass) {
        updateBodyMassData(world, s.body);
    }
}

pub fn getFriction(world: *const World, shape: ShapeHandle) f32 {
    return world.shapes.data[shape.index()].material.friction;
}

pub fn setFriction(world: *World, shape: ShapeHandle, friction: f32) void {
    world.shapes.data[shape.index()].material.friction = friction;
}

pub fn getRestitution(world: *const World, shape: ShapeHandle) f32 {
    return world.shapes.data[shape.index()].material.restitution;
}

pub fn setRestitution(world: *World, shape: ShapeHandle, restitution: f32) void {
    world.shapes.data[shape.index()].material.restitution = restitution;
}

pub fn getFilter(world: *const World, shape: ShapeHandle) Filter {
    return world.shapes.data[shape.index()].filter;
}

/// Change a shape's collision filter. Existing contacts that no longer pass are destroyed
/// and the broad phase re-finds pairs next step. box2d: b2Shape_SetFilter
pub fn setFilter(world: *World, shape: ShapeHandle, filter: Filter) !void {
    const i: ShapeIndex = shape.index();
    const s: *Shape = &world.shapes.data[i];
    if (filter.category == s.filter.category and filter.mask == s.filter.mask and
        filter.group == s.filter.group)
    {
        return;
    }
    const destroy_proxy: bool = filter.category != s.filter.category;
    s.filter = filter;
    try resetShapeProxy(world, i, destroy_proxy);
}

pub fn getShapeUserData(world: *const World, shape: ShapeHandle) u64 {
    return world.shapes.data[shape.index()].user_data;
}

pub fn setShapeUserData(world: *World, shape: ShapeHandle, user_data: u64) void {
    world.shapes.data[shape.index()].user_data = user_data;
}

pub fn isSensor(world: *const World, shape: ShapeHandle) bool {
    return world.shapes.data[shape.index()].sensor_index != null_index;
}

pub fn enableContactEvents(world: *World, shape: ShapeHandle, flag: bool) void {
    world.shapes.data[shape.index()].enable_contact_events = flag;
}

pub fn enableHitEvents(world: *World, shape: ShapeHandle, flag: bool) void {
    world.shapes.data[shape.index()].enable_hit_events = flag;
}

// -- Public API: joint accessors and runtime tuning ------------------------------
//
// Generic accessors work on any joint; the per-type setters tune motors, springs, and
// limits while the simulation runs. Following Box2D, toggling a feature zeroes its
// accumulated impulse (so it restarts cleanly) and setters do not auto-wake - call
// wakeJoint if a sleeping pair should react immediately. box2d: *_joint.c (b2*Joint_*)

pub fn getJointType(world: *const World, joint: JointHandle) JointType {
    return std.meta.activeTag(world.joints.data[joint.index()].data);
}

pub fn getJointUserData(world: *const World, joint: JointHandle) u64 {
    return world.joints.data[joint.index()].user_data;
}

pub fn setJointUserData(world: *World, joint: JointHandle, user_data: u64) void {
    world.joints.data[joint.index()].user_data = user_data;
}

pub fn getJointCollideConnected(world: *const World, joint: JointHandle) bool {
    return world.joints.data[joint.index()].collide_connected;
}

pub fn getJointBodyA(world: *const World, joint: JointHandle) BodyHandle {
    const bi: BodyIndex = world.joints.data[joint.index()].body_a;
    return BodyHandle.pack(@intCast(bi), world.bodies.cycle[bi]);
}

pub fn getJointBodyB(world: *const World, joint: JointHandle) BodyHandle {
    const bi: BodyIndex = world.joints.data[joint.index()].body_b;
    return BodyHandle.pack(@intCast(bi), world.bodies.cycle[bi]);
}

/// Wake both bodies a joint connects, so a parameter change takes effect immediately.
pub fn wakeJoint(world: *World, joint: JointHandle) void {
    const j: *const Joint = &world.joints.data[joint.index()];
    wakeBody(world, j.body_a);
    wakeBody(world, j.body_b);
}

// - Revolute -

/// Current relative angle of the two joint frames (radians). box2d: b2RevoluteJoint_GetAngle
pub fn revoluteGetAngle(world: *const World, joint: JointHandle) f32 {
    const j: *const Joint = &world.joints.data[joint.index()];
    const qa: Rot2 = mulRot2(world.bodies.data[j.body_a].transform.q, j.local_frame_a.q);
    const qb: Rot2 = mulRot2(world.bodies.data[j.body_b].transform.q, j.local_frame_b.q);
    return invMulRot2(qa, qb).angle();
}

pub fn revoluteEnableSpring(world: *World, joint: JointHandle, enable: bool) void {
    const rev: *RevoluteJoint = &world.joints.data[joint.index()].data.revolute;
    if (enable != rev.enable_spring) {
        rev.enable_spring = enable;
        rev.spring_impulse = 0;
    }
}

pub fn revoluteIsSpringEnabled(world: *const World, joint: JointHandle) bool {
    return world.joints.data[joint.index()].data.revolute.enable_spring;
}

pub fn revoluteSetSpringHertz(world: *World, joint: JointHandle, hertz: f32) void {
    world.joints.data[joint.index()].data.revolute.hertz = hertz;
}

pub fn revoluteGetSpringHertz(world: *const World, joint: JointHandle) f32 {
    return world.joints.data[joint.index()].data.revolute.hertz;
}

pub fn revoluteSetSpringDampingRatio(world: *World, joint: JointHandle, ratio: f32) void {
    world.joints.data[joint.index()].data.revolute.damping_ratio = ratio;
}

pub fn revoluteSetTargetAngle(world: *World, joint: JointHandle, angle_rad: f32) void {
    world.joints.data[joint.index()].data.revolute.target_angle = clamp(angle_rad, -pi, pi);
}

pub fn revoluteEnableMotor(world: *World, joint: JointHandle, enable: bool) void {
    const rev: *RevoluteJoint = &world.joints.data[joint.index()].data.revolute;
    if (enable != rev.enable_motor) {
        rev.enable_motor = enable;
        rev.motor_impulse = 0;
    }
}

pub fn revoluteIsMotorEnabled(world: *const World, joint: JointHandle) bool {
    return world.joints.data[joint.index()].data.revolute.enable_motor;
}

pub fn revoluteSetMotorSpeed(world: *World, joint: JointHandle, speed: f32) void {
    world.joints.data[joint.index()].data.revolute.motor_speed = speed;
    wakeJointBodies(world, joint);
}

pub fn revoluteGetMotorSpeed(world: *const World, joint: JointHandle) f32 {
    return world.joints.data[joint.index()].data.revolute.motor_speed;
}

pub fn revoluteSetMaxMotorTorque(world: *World, joint: JointHandle, torque: f32) void {
    world.joints.data[joint.index()].data.revolute.max_motor_torque = torque;
}

/// Reaction torque the motor applied last step (N*m). box2d: b2RevoluteJoint_GetMotorTorque
pub fn revoluteGetMotorTorque(world: *const World, joint: JointHandle) f32 {
    return world.inv_h * world.joints.data[joint.index()].data.revolute.motor_impulse;
}

pub fn revoluteEnableLimit(world: *World, joint: JointHandle, enable: bool) void {
    const rev: *RevoluteJoint = &world.joints.data[joint.index()].data.revolute;
    if (enable != rev.enable_limit) {
        rev.enable_limit = enable;
        rev.lower_impulse = 0;
        rev.upper_impulse = 0;
    }
}

pub fn revoluteIsLimitEnabled(world: *const World, joint: JointHandle) bool {
    return world.joints.data[joint.index()].data.revolute.enable_limit;
}

pub fn revoluteSetLimits(
    world: *World,
    joint: JointHandle,
    lower: f32,
    upper: f32,
) void {
    assert(lower <= upper, @src());
    const rev: *RevoluteJoint = &world.joints.data[joint.index()].data.revolute;
    if (lower != rev.lower_angle or upper != rev.upper_angle) {
        rev.lower_angle = @min(lower, upper);
        rev.upper_angle = @max(lower, upper);
        rev.lower_impulse = 0;
        rev.upper_impulse = 0;
    }
}

pub fn revoluteGetLowerLimit(world: *const World, joint: JointHandle) f32 {
    return world.joints.data[joint.index()].data.revolute.lower_angle;
}

pub fn revoluteGetUpperLimit(world: *const World, joint: JointHandle) f32 {
    return world.joints.data[joint.index()].data.revolute.upper_angle;
}

/// Reaction force this joint applied to body B last step (N), in world space. Useful for
/// breakable joints. box2d: b2Joint_GetConstraintForce dispatch
pub fn getConstraintForce(world: *const World, joint: JointHandle) Vec2 {
    const j: *const Joint = &world.joints.data[joint.index()];
    const inv_h: f32 = world.inv_h;
    switch (j.data) {
        .revolute => |rev| return rev.linear_impulse * splat2(inv_h),
        .weld => |weld| return weld.linear_impulse * splat2(inv_h),
        .motor => |m| return (m.linear_velocity_impulse + m.linear_spring_impulse) * splat2(inv_h),
        .filter => return .{ 0, 0 },
        .pulley => |pl| return pl.u_b * splat2(-pl.ratio * pl.impulse * inv_h),
        .distance => |d| {
            const pa: Vec2 = transformPoint2(world.bodies.data[j.body_a].transform, j.local_frame_a.p);
            const pb: Vec2 = transformPoint2(world.bodies.data[j.body_b].transform, j.local_frame_b.p);
            const axis: Vec2 = normalizeOrZero2(pb - pa);
            const force: f32 = (d.impulse + d.lower_impulse - d.upper_impulse + d.motor_impulse) * inv_h;
            return axis * splat2(force);
        },
        .prismatic => |pr| {
            const axis_local: Vec2 = rotateVec2(j.local_frame_a.q, .{ 1, 0 });
            const axis: Vec2 = rotateVec2(world.bodies.data[j.body_a].transform.q, axis_local);
            const perp: Vec2 = leftPerp2(axis);
            const perp_force: f32 = inv_h * pr.impulse[0];
            const axial_force: f32 = inv_h * (pr.motor_impulse + pr.lower_impulse - pr.upper_impulse);
            return perp * splat2(perp_force) + axis * splat2(axial_force);
        },
        .wheel => |wh| {
            const axis_local: Vec2 = rotateVec2(j.local_frame_a.q, .{ 1, 0 });
            const axis: Vec2 = rotateVec2(world.bodies.data[j.body_a].transform.q, axis_local);
            const perp: Vec2 = leftPerp2(axis);
            const perp_force: f32 = inv_h * wh.perp_impulse;
            const axial_force: f32 = inv_h * (wh.spring_impulse + wh.lower_impulse - wh.upper_impulse);
            return perp * splat2(perp_force) + axis * splat2(axial_force);
        },
    }
}

/// Reaction torque this joint applied last step (N*m). box2d: b2Joint_GetConstraintTorque dispatch
pub fn getConstraintTorque(world: *const World, joint: JointHandle) f32 {
    const j: *const Joint = &world.joints.data[joint.index()];
    const inv_h: f32 = world.inv_h;
    return switch (j.data) {
        .revolute => |rev| inv_h * (rev.motor_impulse + rev.lower_impulse - rev.upper_impulse),
        .prismatic => |pr| inv_h * pr.impulse[1],
        .wheel => |wh| inv_h * wh.motor_impulse,
        .weld => |weld| inv_h * weld.angular_impulse,
        .motor => |m| inv_h * (m.angular_velocity_impulse + m.angular_spring_impulse),
        .distance, .filter, .pulley => 0,
    };
}

// - Prismatic -

/// Current translation along the joint axis (m). box2d: b2PrismaticJoint_GetTranslation
pub fn prismaticGetTranslation(world: *const World, joint: JointHandle) f32 {
    const j: *const Joint = &world.joints.data[joint.index()];
    const axis_local: Vec2 = rotateVec2(j.local_frame_a.q, .{ 1, 0 });
    const axis: Vec2 = rotateVec2(world.bodies.data[j.body_a].transform.q, axis_local);
    const pa: Vec2 = transformPoint2(world.bodies.data[j.body_a].transform, j.local_frame_a.p);
    const pb: Vec2 = transformPoint2(world.bodies.data[j.body_b].transform, j.local_frame_b.p);
    return dot2(pb - pa, axis);
}

pub fn prismaticEnableSpring(world: *World, joint: JointHandle, enable: bool) void {
    const pr: *PrismaticJoint = &world.joints.data[joint.index()].data.prismatic;
    if (enable != pr.enable_spring) {
        pr.enable_spring = enable;
        pr.spring_impulse = 0;
    }
}

pub fn prismaticSetSpringHertz(world: *World, joint: JointHandle, hertz: f32) void {
    world.joints.data[joint.index()].data.prismatic.hertz = hertz;
}

pub fn prismaticSetSpringDampingRatio(
    world: *World,
    joint: JointHandle,
    ratio: f32,
) void {
    world.joints.data[joint.index()].data.prismatic.damping_ratio = ratio;
}

pub fn prismaticEnableMotor(world: *World, joint: JointHandle, enable: bool) void {
    const pr: *PrismaticJoint = &world.joints.data[joint.index()].data.prismatic;
    if (enable != pr.enable_motor) {
        pr.enable_motor = enable;
        pr.motor_impulse = 0;
    }
}

pub fn prismaticSetMotorSpeed(world: *World, joint: JointHandle, speed: f32) void {
    world.joints.data[joint.index()].data.prismatic.motor_speed = speed;
    wakeJointBodies(world, joint);
}

pub fn prismaticSetMaxMotorForce(world: *World, joint: JointHandle, force: f32) void {
    world.joints.data[joint.index()].data.prismatic.max_motor_force = force;
}

pub fn prismaticGetMotorForce(world: *const World, joint: JointHandle) f32 {
    return world.inv_h * world.joints.data[joint.index()].data.prismatic.motor_impulse;
}

pub fn prismaticEnableLimit(world: *World, joint: JointHandle, enable: bool) void {
    const pr: *PrismaticJoint = &world.joints.data[joint.index()].data.prismatic;
    if (enable != pr.enable_limit) {
        pr.enable_limit = enable;
        pr.lower_impulse = 0;
        pr.upper_impulse = 0;
    }
}

pub fn prismaticSetLimits(
    world: *World,
    joint: JointHandle,
    lower: f32,
    upper: f32,
) void {
    assert(lower <= upper, @src());
    const pr: *PrismaticJoint = &world.joints.data[joint.index()].data.prismatic;
    if (lower != pr.lower_translation or upper != pr.upper_translation) {
        pr.lower_translation = @min(lower, upper);
        pr.upper_translation = @max(lower, upper);
        pr.lower_impulse = 0;
        pr.upper_impulse = 0;
    }
}

// - Distance -

/// Set the rest length the spring pulls toward (clamped to >= slop). box2d: b2DistanceJoint_SetLength
pub fn distanceSetLength(world: *World, joint: JointHandle, length: f32) void {
    const d: *DistanceJoint = &world.joints.data[joint.index()].data.distance;
    d.length = clamp(length, linear_slop, floatMax(f32));
    d.impulse = 0;
    d.lower_impulse = 0;
    d.upper_impulse = 0;
}

pub fn distanceGetLength(world: *const World, joint: JointHandle) f32 {
    return world.joints.data[joint.index()].data.distance.length;
}

/// Current world distance between the two anchors. box2d: b2DistanceJoint_GetCurrentLength
pub fn distanceGetCurrentLength(world: *const World, joint: JointHandle) f32 {
    const j: *const Joint = &world.joints.data[joint.index()];
    const pa: Vec2 = transformPoint2(world.bodies.data[j.body_a].transform, j.local_frame_a.p);
    const pb: Vec2 = transformPoint2(world.bodies.data[j.body_b].transform, j.local_frame_b.p);
    return length2(pb - pa);
}

pub fn distanceEnableSpring(world: *World, joint: JointHandle, enable: bool) void {
    world.joints.data[joint.index()].data.distance.enable_spring = enable;
}

pub fn distanceSetSpringHertz(world: *World, joint: JointHandle, hertz: f32) void {
    world.joints.data[joint.index()].data.distance.hertz = hertz;
}

pub fn distanceSetSpringDampingRatio(world: *World, joint: JointHandle, ratio: f32) void {
    world.joints.data[joint.index()].data.distance.damping_ratio = ratio;
}

pub fn distanceEnableLimit(world: *World, joint: JointHandle, enable: bool) void {
    const d: *DistanceJoint = &world.joints.data[joint.index()].data.distance;
    if (enable != d.enable_limit) {
        d.enable_limit = enable;
        d.lower_impulse = 0;
        d.upper_impulse = 0;
    }
}

/// Set the limit range the joint length is clamped to. box2d: b2DistanceJoint_SetLengthRange
pub fn distanceSetLengthRange(
    world: *World,
    joint: JointHandle,
    min_length: f32,
    max_length: f32,
) void {
    const d: *DistanceJoint = &world.joints.data[joint.index()].data.distance;
    d.min_length = @max(min_length, linear_slop);
    d.max_length = @max(d.min_length, max_length);
    d.impulse = 0;
    d.lower_impulse = 0;
    d.upper_impulse = 0;
}

pub fn distanceEnableMotor(world: *World, joint: JointHandle, enable: bool) void {
    const d: *DistanceJoint = &world.joints.data[joint.index()].data.distance;
    if (enable != d.enable_motor) {
        d.enable_motor = enable;
        d.motor_impulse = 0;
    }
}

pub fn distanceSetMotorSpeed(world: *World, joint: JointHandle, speed: f32) void {
    world.joints.data[joint.index()].data.distance.motor_speed = speed;
    wakeJointBodies(world, joint);
}

pub fn distanceSetMaxMotorForce(world: *World, joint: JointHandle, force: f32) void {
    world.joints.data[joint.index()].data.distance.max_motor_force = force;
}

pub fn distanceGetMotorForce(world: *const World, joint: JointHandle) f32 {
    return world.inv_h * world.joints.data[joint.index()].data.distance.motor_impulse;
}

// - Wheel -

pub fn wheelEnableSpring(world: *World, joint: JointHandle, enable: bool) void {
    const wh: *WheelJoint = &world.joints.data[joint.index()].data.wheel;
    if (enable != wh.enable_spring) {
        wh.enable_spring = enable;
        wh.spring_impulse = 0;
    }
}

pub fn wheelSetSpringHertz(world: *World, joint: JointHandle, hertz: f32) void {
    world.joints.data[joint.index()].data.wheel.hertz = hertz;
}

pub fn wheelSetSpringDampingRatio(world: *World, joint: JointHandle, ratio: f32) void {
    world.joints.data[joint.index()].data.wheel.damping_ratio = ratio;
}

pub fn wheelEnableMotor(world: *World, joint: JointHandle, enable: bool) void {
    const wh: *WheelJoint = &world.joints.data[joint.index()].data.wheel;
    if (enable != wh.enable_motor) {
        wh.enable_motor = enable;
        wh.motor_impulse = 0;
    }
}

pub fn wheelSetMotorSpeed(world: *World, joint: JointHandle, speed: f32) void {
    world.joints.data[joint.index()].data.wheel.motor_speed = speed;
    wakeJointBodies(world, joint);
}

pub fn wheelSetMaxMotorTorque(world: *World, joint: JointHandle, torque: f32) void {
    world.joints.data[joint.index()].data.wheel.max_motor_torque = torque;
}

pub fn wheelGetMotorTorque(world: *const World, joint: JointHandle) f32 {
    return world.inv_h * world.joints.data[joint.index()].data.wheel.motor_impulse;
}

pub fn wheelEnableLimit(world: *World, joint: JointHandle, enable: bool) void {
    const wh: *WheelJoint = &world.joints.data[joint.index()].data.wheel;
    if (enable != wh.enable_limit) {
        wh.enable_limit = enable;
        wh.lower_impulse = 0;
        wh.upper_impulse = 0;
    }
}

pub fn wheelSetLimits(
    world: *World,
    joint: JointHandle,
    lower: f32,
    upper: f32,
) void {
    assert(lower <= upper, @src());
    const wh: *WheelJoint = &world.joints.data[joint.index()].data.wheel;
    if (lower != wh.lower_translation or upper != wh.upper_translation) {
        wh.lower_translation = @min(lower, upper);
        wh.upper_translation = @max(lower, upper);
        wh.lower_impulse = 0;
        wh.upper_impulse = 0;
    }
}

// - Weld -

pub fn weldSetLinearHertz(world: *World, joint: JointHandle, hertz: f32) void {
    world.joints.data[joint.index()].data.weld.linear_hertz = hertz;
}

pub fn weldSetLinearDampingRatio(world: *World, joint: JointHandle, ratio: f32) void {
    world.joints.data[joint.index()].data.weld.linear_damping_ratio = ratio;
}

pub fn weldSetAngularHertz(world: *World, joint: JointHandle, hertz: f32) void {
    world.joints.data[joint.index()].data.weld.angular_hertz = hertz;
}

pub fn weldSetAngularDampingRatio(world: *World, joint: JointHandle, ratio: f32) void {
    world.joints.data[joint.index()].data.weld.angular_damping_ratio = ratio;
}

// - Motor -

pub fn motorSetLinearVelocity(world: *World, joint: JointHandle, velocity: Vec2) void {
    world.joints.data[joint.index()].data.motor.linear_velocity = velocity;
}

pub fn motorSetAngularVelocity(world: *World, joint: JointHandle, velocity: f32) void {
    world.joints.data[joint.index()].data.motor.angular_velocity = velocity;
}

pub fn motorSetMaxVelocityForce(world: *World, joint: JointHandle, force: f32) void {
    world.joints.data[joint.index()].data.motor.max_velocity_force = force;
}

pub fn motorSetMaxVelocityTorque(world: *World, joint: JointHandle, torque: f32) void {
    world.joints.data[joint.index()].data.motor.max_velocity_torque = torque;
}

// -- Public API: body transform and type changes ---------------------------------

/// Teleport a body to a new pose. Recomputes the world center of mass and the CCD sweep
/// start, then refits each shape's AABB, moving the broad-phase proxy only when the tight
/// box escapes the stored fat box. This does not change velocity. box2d: b2Body_SetTransform
pub fn setTransform(
    world: *World,
    body: BodyHandle,
    position: Vec2,
    rotation: Rot2,
) !void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    b.transform.p = position;
    b.transform.q = rotation;
    b.center = transformPoint2(b.transform, b.local_center);
    b.rot0 = b.transform.q;
    b.center0 = b.center;

    var shape_index: u32 = b.head_shape;
    while (shape_index != null_index) {
        const s: *Shape = &world.shapes.data[shape_index];
        const aabb: Aabb2 = computeFatShapeAabb(s.geom, b.transform, speculative_distance);
        s.aabb = aabb;
        if (s.fat_aabb.contains(aabb) == false) {
            s.fat_aabb = expandAabb(aabb, s.aabb_margin);
            if (s.proxy_key != null_index) {
                try world.broadphase.moveProxy(world.allocator, s.proxy_key, s.fat_aabb);
            }
        }
        shape_index = s.next_shape;
    }
}

/// Change a body's type at runtime. Destroys its contacts (they are re-found next step),
/// migrates every shape proxy into the broad-phase tree for the new type, fixes active-list
/// membership and the dynamic solver flag, and recomputes mass. Neighbours are woken so the
/// scene re-settles. box2d: b2Body_SetType (adapted: no solver sets, per-type trees here)
pub fn setBodyType(world: *World, body: BodyHandle, new_type: MotionType) !void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    const old_type: MotionType = b.motion_type;
    if (old_type == new_type) {
        return;
    }

    // Destroy existing contacts; wake the body on the far side of each so it re-settles.
    var contact_key: u32 = b.head_contact;
    while (contact_key != null_index) {
        const contact_id: u32 = contact_key >> 1;
        const edge_index: u32 = contact_key & 1;
        const c: *const Contact = &world.contacts.data[contact_id];
        contact_key = if (edge_index == 0) c.edge_a.next_key else c.edge_b.next_key;
        wakeBody(world, if (edge_index == 0) c.body_b else c.body_a);
        destroyContact(world, contact_id);
    }

    // Wake both ends of every attached joint; the joint solve depends on the body's type.
    var joint_key: u32 = b.head_joint;
    while (joint_key != null_index) {
        const joint_id: u32 = joint_key >> 1;
        const edge_index: u32 = joint_key & 1;
        const j: *const Joint = &world.joints.data[joint_id];
        joint_key = if (edge_index == 0) j.edge_a.next_key else j.edge_b.next_key;
        wakeBody(world, j.body_a);
        wakeBody(world, j.body_b);
    }

    // Active-list membership differs by type, so leave it before retyping.
    if (old_type != .static and b.asleep == false) {
        removeFromActive(world, i);
    }

    b.motion_type = new_type;
    b.sleep_time = 0;
    b.asleep = false;
    world.state[i].flags.dynamic = (new_type == .dynamic);

    if (new_type == .static) {
        world.motion[i].linear_velocity = .{ 0, 0 };
        world.motion[i].angular_velocity = 0;
    } else {
        // A movable body becomes an awake participant.
        world.active.appendAssumeCapacity(i);
    }

    // Move every shape proxy into the tree for the new type (force pair re-creation).
    var shape_index: u32 = b.head_shape;
    while (shape_index != null_index) {
        const s: *Shape = &world.shapes.data[shape_index];
        const aabb: Aabb2 = computeFatShapeAabb(s.geom, b.transform, speculative_distance);
        s.aabb = aabb;
        const margin: f32 = if (new_type == .static) speculative_distance else s.aabb_margin;
        s.fat_aabb = expandAabb(aabb, margin);
        if (s.proxy_key != null_index) {
            world.broadphase.destroyProxy(s.proxy_key);
        }
        s.proxy_key = try world.broadphase.createProxy(
            world.allocator,
            new_type,
            s.fat_aabb,
            s.filter.category,
            shape_index,
            true,
        );
        shape_index = s.next_shape;
    }

    updateBodyMassData(world, i);
}

// -- Public API: shape overlap and shape-cast scene queries ----------------------
//
// These refine broad-phase AABB candidates with the exact GJK distance / shape-cast
// kernels. As in Box2D, `origin` re-centers the query; pass the proxy points relative to
// it (use {0,0} to work directly in world space). box2d: physics_world.c

/// Inputs to casting a proxy through the world. box2d: b2ShapeCastInput  collision.h
pub const ShapeCastInput = struct {
    proxy: ShapeProxy,
    translation: Vec2,
    max_fraction: f32 = 1.0,
    can_encroach: bool = false,
};

/// Cast the query proxy against a single shape at `transform`, returning the first
/// touch. The proxy is moved into the shape's local frame, cast, then the hit is mapped
/// back. Mirrors the ray-cast frame contract. box2d: b2ShapeCastShape  shape.c
fn shapeCastShape(
    input: *const ShapeCastInput,
    geom: Geometry,
    transform: Transform2,
) CastOutput {
    if (input.proxy.count == 0) {
        return CastOutput.miss;
    }

    var local: ShapeProxy = input.proxy;
    var i: u32 = 0;
    while (i < local.count) : (i += 1) {
        local.points[i] = invTransformPoint2(transform, input.proxy.points[i]);
    }
    const local_translation: Vec2 = invRotateVec2(transform.q, input.translation);

    // A chain segment is one-sided: a cast that begins behind the wall does not hit.
    if (std.meta.activeTag(geom) == .chain_segment) {
        var centroid: Vec2 = local.points[0];
        var k: u32 = 1;
        while (k < local.count) : (k += 1) centroid = centroid + local.points[k];
        centroid = centroid * splat2(1.0 / float(local.count));
        const seg: Segment = geom.chain_segment.segment;
        const edge: Vec2 = seg.point2 - seg.point1;
        const r: Vec2 = centroid - seg.point1;
        if (cross2(r, edge) < 0.0) {
            return CastOutput.miss;
        }
    }

    const pair: ShapeCastPairInput = .{
        .proxy_a = makeShapeDistanceProxy(geom),
        .proxy_b = local,
        .transform = Transform2.identity,
        .translation_b = local_translation,
        .max_fraction = input.max_fraction,
        .can_encroach = input.can_encroach,
    };
    var output: CastOutput = shapeCast(&pair);
    output.point = transformPoint2(transform, output.point);
    output.normal = rotateVec2(transform.q, output.normal);
    return output;
}

/// World-space AABB enclosing a proxy whose points are given relative to `origin`.
fn proxyWorldAabb(proxy: ShapeProxy, origin: Vec2) Aabb2 {
    var lower: Vec2 = proxy.points[0];
    var upper: Vec2 = proxy.points[0];
    var i: u32 = 1;
    while (i < proxy.count) : (i += 1) {
        lower = @min(lower, proxy.points[i]);
        upper = @max(upper, proxy.points[i]);
    }
    const r: Vec2 = splat2(proxy.radius);
    return .{ .lower = lower - r + origin, .upper = upper + r + origin };
}

const OverlapShapeContext = struct {
    world: *World,
    filter: QueryFilter,
    proxy: ShapeProxy,
    origin: Vec2,
    callback: OverlapCallback,
    user_ctx: *anyopaque,
    stop: bool = false,
};

fn overlapShapeCallback(proxy_id: i32, user_data: u64, ctx_ptr: *anyopaque) bool {
    _ = proxy_id;
    const ctx: *OverlapShapeContext = @ptrCast(@alignCast(ctx_ptr));
    const shape_id: ShapeIndex = @intCast(user_data);
    const shape: *const Shape = &ctx.world.shapes.data[shape_id];
    if (shouldQueryCollide(shape, ctx.filter) == false) {
        return true;
    }

    const body_xf: Transform2 = ctx.world.bodies.data[shape.body].transform;
    const input: DistanceInput = .{
        .proxy_a = ctx.proxy,
        .proxy_b = makeShapeDistanceProxy(shape.geom),
        .transform = .{ .p = body_xf.p - ctx.origin, .q = body_xf.q },
        .use_radii = true,
    };
    var cache: SimplexCache = SimplexCache.empty;
    const output: DistanceOutput = shapeDistance(&input, &cache);
    if (output.distance > 0.1 * linear_slop) {
        return true; // AABB candidate, not a real overlap
    }

    const proceed: bool = ctx.callback(shape_id, ctx.user_ctx);
    if (proceed == false) {
        ctx.stop = true;
    }
    return proceed;
}

/// Report every shape that actually overlaps the query proxy (refined past the broad
/// phase with a GJK distance test). box2d: b2World_OverlapShape
pub fn overlapShape(
    world: *World,
    origin: Vec2,
    proxy: ShapeProxy,
    filter: QueryFilter,
    callback: OverlapCallback,
    user_ctx: *anyopaque,
) void {
    var ctx: OverlapShapeContext = .{
        .world = world,
        .filter = filter,
        .proxy = proxy,
        .origin = origin,
        .callback = callback,
        .user_ctx = user_ctx,
    };
    const aabb: Aabb2 = proxyWorldAabb(proxy, origin);
    const bp: *BroadPhase = &world.broadphase;
    bp.trees[0].query(aabb, filter.mask, overlapShapeCallback, &ctx);
    if (ctx.stop) {
        return;
    }
    bp.trees[1].query(aabb, filter.mask, overlapShapeCallback, &ctx);
    if (ctx.stop) {
        return;
    }
    bp.trees[2].query(aabb, filter.mask, overlapShapeCallback, &ctx);
}

/// Result of casting a proxy through the world: the nearest shape it would first touch. The
/// query returns `?CastResult`, so a miss is `null` and a hit always has valid fields.
pub const CastResult = struct {
    shape: ShapeIndex = null_index,
    point: Vec2 = .{ 0, 0 },
    normal: Vec2 = .{ 0, 0 },
    fraction: f32 = 0,
};

const CastShapeContext = struct {
    world: *World,
    filter: QueryFilter,
    input: ShapeCastInput,
    origin: Vec2,
    hit: bool = false,
    result: CastResult = .{},
};

fn castShapeClosestCallback(
    input: *const BoxCastInput,
    proxy_id: i32,
    user_data: u64,
    ctx_ptr: *anyopaque,
) f32 {
    _ = proxy_id;
    const ctx: *CastShapeContext = @ptrCast(@alignCast(ctx_ptr));
    const shape_id: ShapeIndex = @intCast(user_data);
    const shape: *const Shape = &ctx.world.shapes.data[shape_id];
    if (shouldQueryCollide(shape, ctx.filter) == false) {
        return input.max_fraction;
    }

    const body_xf: Transform2 = ctx.world.bodies.data[shape.body].transform;
    const rel_xf: Transform2 = .{ .p = body_xf.p - ctx.origin, .q = body_xf.q };
    // Only look nearer than the cast's current clip fraction.
    var local_input: ShapeCastInput = ctx.input;
    local_input.max_fraction = input.max_fraction;
    const output: CastOutput = shapeCastShape(&local_input, shape.geom, rel_xf);
    if (output.hit and (ctx.hit == false or output.fraction < ctx.result.fraction)) {
        ctx.hit = true;
        ctx.result = .{
            .shape = shape_id,
            .point = output.point + ctx.origin,
            .normal = output.normal,
            .fraction = output.fraction,
        };
        return output.fraction; // shrink the sweep so farther nodes are pruned
    }
    return input.max_fraction;
}

/// Cast the query proxy along `translation` and return the nearest shape it first hits,
/// using an ordered, shrinking box cast through each broad-phase tree (the best hit so far
/// caps the search). box2d: b2World_CastShape (closest variant)
pub fn castShapeClosest(
    world: *World,
    origin: Vec2,
    proxy: ShapeProxy,
    translation: Vec2,
    filter: QueryFilter,
) ?CastResult {
    var ctx: CastShapeContext = .{
        .world = world,
        .filter = filter,
        .input = .{ .proxy = proxy, .translation = translation, .max_fraction = 1.0 },
        .origin = origin,
    };
    var input: BoxCastInput = .{
        .box = proxyWorldAabb(proxy, origin),
        .translation = translation,
        .max_fraction = 1.0,
    };
    const bp: *BroadPhase = &world.broadphase;
    var t: usize = 0;
    while (t < 3) : (t += 1) {
        boxCastTree(&bp.trees[t], &input, filter.mask, castShapeClosestCallback, &ctx);
        // carry the clip across trees
        if (ctx.hit) {
            input.max_fraction = ctx.result.fraction;
        }
    }
    return if (ctx.hit) ctx.result else null;
}

// -- Public API: chain shapes (one-sided segment runs) ---------------------------
//
// A chain is a run of one-sided segments sharing ghost vertices with their neighbours,
// so a body sliding along it never catches on the internal joints. Points are in the
// body's local frame. Chain segments are unsuited to mass, so chains belong on static or
// kinematic bodies. box2d: b2CreateChain  shape.c

/// Definition of a chain of connected one-sided segments. For a loop, `points` are the n
/// loop vertices (n segments). For an open chain, the first and last points act purely as
/// ghost anchors, so n points yield n - 3 collidable segments (n must be >= 4).
///
/// Winding matters: each segment is solid only on the right-hand side of its travel
/// direction (p1 -> p2). Wind a containing loop counter-clockwise so its solid faces point
/// inward; for open ground, order the points so the walkable side is on the right (e.g. a
/// valley things rest in is wound right-to-left).
pub const ChainDef = struct {
    points: []const Vec2,
    is_loop: bool = false,
    material: SurfaceMaterial = .{},
    filter: Filter = .{},
    enable_sensor_events: bool = false,
    user_data: u64 = 0,
};

/// Build a chain on `body`, returning its chain id (used to destroy it as a unit).
/// box2d: b2CreateChain
pub fn createChain(world: *World, body: BodyHandle, def: ChainDef) !u32 {
    const n: usize = def.points.len;
    assert(n >= 4, @src());
    const chain_id: u32 = world.next_chain_id;
    world.next_chain_id += 1;

    if (def.is_loop) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const cs: ChainSegment = .{
                .ghost1 = def.points[(i + n - 1) % n],
                .segment = .{ .point1 = def.points[i], .point2 = def.points[(i + 1) % n] },
                .ghost2 = def.points[(i + 2) % n],
                .chain_id = chain_id,
            };
            _ = try createChainSegmentShape(world, body, cs, def);
        }
    } else {
        // Open chain: segments span points[1] .. points[n-2]; the ends are ghosts only.
        var i: usize = 0;
        while (i + 3 < n) : (i += 1) {
            const cs: ChainSegment = .{
                .ghost1 = def.points[i],
                .segment = .{ .point1 = def.points[i + 1], .point2 = def.points[i + 2] },
                .ghost2 = def.points[i + 3],
                .chain_id = chain_id,
            };
            _ = try createChainSegmentShape(world, body, cs, def);
        }
    }
    return chain_id;
}

fn createChainSegmentShape(
    world: *World,
    body: BodyHandle,
    cs: ChainSegment,
    def: ChainDef,
) !ShapeHandle {
    return createShape(world, body, .{
        .geom = .{ .chain_segment = cs },
        .material = def.material,
        .filter = def.filter,
        .enable_contact_events = false,
        .enable_sensor_events = def.enable_sensor_events,
        .enable_hit_events = false,
        .user_data = def.user_data,
    });
}

/// Destroy every segment of a chain on `body`. box2d: b2DestroyChain
pub fn destroyChain(world: *World, body: BodyHandle, chain_id: u32) void {
    const body_index: BodyIndex = body.index();
    var shape_index: u32 = world.bodies.data[body_index].head_shape;
    while (shape_index != null_index) {
        const s: *const Shape = &world.shapes.data[shape_index];
        const next: u32 = s.next_shape;
        if (std.meta.activeTag(s.geom) == .chain_segment and s.geom.chain_segment.chain_id == chain_id) {
            destroyShape(world, ShapeHandle.pack(@intCast(shape_index), world.shapes.cycle[shape_index]));
        }
        shape_index = next;
    }
}

// -- Public API: disable/enable bodies and radial explosions ---------------------

/// Remove a body from simulation without destroying it: tear down its contacts (waking
/// neighbours), drop its broad-phase proxies, and take it out of the active set. Its
/// shapes and joints are retained so enableBody can restore it. box2d: b2Body_Disable
pub fn disableBody(world: *World, body: BodyHandle) void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    if (b.flags.is_disabled) {
        return;
    }

    var contact_key: u32 = b.head_contact;
    while (contact_key != null_index) {
        const contact_id: u32 = contact_key >> 1;
        const edge_index: u32 = contact_key & 1;
        const c: *const Contact = &world.contacts.data[contact_id];
        contact_key = if (edge_index == 0) c.edge_a.next_key else c.edge_b.next_key;
        wakeBody(world, if (edge_index == 0) c.body_b else c.body_a);
        destroyContact(world, contact_id);
    }

    var shape_index: u32 = b.head_shape;
    while (shape_index != null_index) {
        const s: *Shape = &world.shapes.data[shape_index];
        if (s.proxy_key != null_index) {
            world.broadphase.destroyProxy(s.proxy_key);
            s.proxy_key = null_index;
        }
        shape_index = s.next_shape;
    }

    if (b.motion_type != .static and b.asleep == false) {
        removeFromActive(world, i);
    }
    b.flags.is_disabled = true;
    b.asleep = true;
}

/// Restore a disabled body: rebuild its proxies (forcing pair re-creation) and, if movable,
/// return it to the active set awake. box2d: b2Body_Enable
pub fn enableBody(world: *World, body: BodyHandle) !void {
    const i: BodyIndex = body.index();
    const b: *Body = &world.bodies.data[i];
    if (b.flags.is_disabled == false) {
        return;
    }
    b.flags.is_disabled = false;

    var shape_index: u32 = b.head_shape;
    while (shape_index != null_index) {
        const s: *Shape = &world.shapes.data[shape_index];
        const margin: f32 = if (b.motion_type == .static) speculative_distance else s.aabb_margin;
        s.aabb = computeFatShapeAabb(s.geom, b.transform, speculative_distance);
        s.fat_aabb = expandAabb(s.aabb, margin);
        s.proxy_key = try world.broadphase.createProxy(
            world.allocator,
            b.motion_type,
            s.fat_aabb,
            s.filter.category,
            shape_index,
            true,
        );
        shape_index = s.next_shape;
    }

    if (b.motion_type != .static) {
        b.asleep = false;
        b.sleep_time = 0;
        world.active.appendAssumeCapacity(i);
    }
}

/// The width of a shape projected onto `line` (in the shape's local frame), used to scale
/// an explosion impulse by the exposed cross-section. box2d: b2GetShapeProjectedPerimeter
fn shapeProjectedPerimeter(geom: Geometry, line: Vec2) f32 {
    return switch (geom) {
        .circle => |c| 2.0 * c.radius,
        .capsule => |c| @abs(dot2(c.center2 - c.center1, line)) + 2.0 * c.radius,
        .polygon => |p| blk: {
            var lower: f32 = dot2(p.vertices[0], line);
            var upper: f32 = lower;
            var i: u32 = 1;
            while (i < p.count) : (i += 1) {
                const value: f32 = dot2(p.vertices[i], line);
                lower = @min(lower, value);
                upper = @max(upper, value);
            }
            break :blk (upper - lower) + 2.0 * p.radius;
        },
        .segment => |s| @abs(dot2(s.point2 - s.point1, line)),
        .chain_segment => |cs| @abs(dot2(cs.segment.point2 - cs.segment.point1, line)),
    };
}

/// A radial explosion: pushes dynamic bodies away from `position`. Each shape within
/// `radius` gets an outward impulse proportional to its exposed perimeter and
/// `impulse_per_length`, tapering to zero linearly across the `falloff` band beyond the
/// radius. box2d: b2ExplosionDef
pub const ExplosionDef = struct {
    mask: u64 = 0xFFFF_FFFF_FFFF_FFFF,
    position: Vec2,
    radius: f32,
    falloff: f32 = 0,
    impulse_per_length: f32,
};

const ExplosionContext = struct {
    world: *World,
    def: ExplosionDef,
};

fn explosionCallback(proxy_id: i32, user_data: u64, ctx_ptr: *anyopaque) bool {
    _ = proxy_id;
    const ctx: *ExplosionContext = @ptrCast(@alignCast(ctx_ptr));
    const world: *World = ctx.world;
    const shape_id: ShapeIndex = @intCast(user_data);
    const shape: *const Shape = &world.shapes.data[shape_id];
    const body_index: BodyIndex = shape.body;
    if (world.bodies.data[body_index].motion_type != .dynamic) {
        return true;
    }

    const xf: Transform2 = world.bodies.data[body_index].transform;
    const local_position: Vec2 = invTransformPoint2(xf, ctx.def.position);
    var point_proxy: ShapeProxy = undefined;
    point_proxy.points[0] = local_position;
    point_proxy.count = 1;
    point_proxy.radius = 0;
    const input: DistanceInput = .{
        .proxy_a = makeShapeDistanceProxy(shape.geom),
        .proxy_b = point_proxy,
        .transform = Transform2.identity,
        .use_radii = true,
    };
    var cache: SimplexCache = SimplexCache.empty;
    const output: DistanceOutput = shapeDistance(&input, &cache);
    if (output.distance > ctx.def.radius + ctx.def.falloff) {
        return true;
    }

    wakeBody(world, body_index);
    if (bodyActive(world, body_index) == false) {
        return true; // could not wake (disabled)
    }

    var closest: Vec2 = output.point_a;
    if (output.distance == 0.0) {
        closest = getShapeCentroid(shape.geom);
    }
    var direction: Vec2 = closest - local_position;
    const eps: f32 = floatEps(f32);
    if (lengthSq2(direction) > 100.0 * eps * eps) {
        direction = normalizeOrZero2(direction);
    } else {
        direction = .{ 1, 0 };
    }
    const local_line: Vec2 = leftPerp2(direction);
    const perimeter: f32 = shapeProjectedPerimeter(shape.geom, local_line);
    var scale: f32 = 1.0;
    if (output.distance > ctx.def.radius and ctx.def.falloff > 0.0) {
        const t: f32 = (ctx.def.radius + ctx.def.falloff - output.distance) / ctx.def.falloff;
        scale = clamp(t, 0.0, 1.0);
    }
    const magnitude: f32 = ctx.def.impulse_per_length * perimeter * scale;
    const impulse: Vec2 = rotateVec2(xf.q, direction) * splat2(magnitude);

    const m: *Motion = &world.motion[body_index];
    m.linear_velocity = mulAdd2(m.linear_velocity, m.inverse_mass, impulse);
    const r: Vec2 = rotateVec2(xf.q, closest - world.bodies.data[body_index].local_center);
    m.angular_velocity += m.inverse_inertia * cross2(r, impulse);
    return true;
}

/// Apply a radial explosion to all dynamic shapes near the blast. box2d: b2World_Explode
pub fn explode(world: *World, def: ExplosionDef) void {
    const reach: Vec2 = splat2(def.radius + def.falloff);
    const aabb: Aabb2 = .{ .lower = def.position - reach, .upper = def.position + reach };
    var ctx: ExplosionContext = .{ .world = world, .def = def };
    // Explosions only affect dynamic bodies.
    world.broadphase.trees[@backingInt(MotionType.dynamic)].query(aabb, def.mask, explosionCallback, &ctx);
}

// -- Public API: debug draw ------------------------------------------------------
//
// A renderer-agnostic debug visualization, faithful to box2d's b2DebugDraw: the caller
// fills in whichever drawing callbacks it wants (each pushes a primitive into the caller's
// own renderer, e.g. zimr's ui.DrawList), sets the feature flags, and calls `draw`, which
// walks the world invoking them. Colors are 24-bit RGB (0xRRGGBB) matching b2HexColor.
// Every callback is optional; an absent one simply skips that primitive.
// box2d: b2DebugDraw + b2World_Draw  physics_world.c
/// A 24-bit RGB color, 0xRRGGBB. box2d: b2HexColor
pub const HexColor = u32;
/// The subset of box2d's named colors this debug draw uses, with identical hex values.
pub const colors = struct {
    pub const black: HexColor = 0x000000;
    pub const blue: HexColor = 0x0000FF;
    pub const royal_blue: HexColor = 0x4169E1;
    pub const green: HexColor = 0x008000;
    pub const light_green: HexColor = 0x90EE90;
    pub const pale_green: HexColor = 0x98FB98;
    pub const red: HexColor = 0xFF0000;
    pub const gold: HexColor = 0xFFD700;
    pub const violet: HexColor = 0xEE82EE;
    pub const magenta: HexColor = 0xFF00FF;
    pub const yellow: HexColor = 0xFFFF00;
    pub const yellow_green: HexColor = 0x9ACD32;
    pub const lime: HexColor = 0x00FF00;
    pub const turquoise: HexColor = 0x40E0D0;
    pub const pink: HexColor = 0xFFC0CB;
    pub const wheat: HexColor = 0xF5DEB3;
    pub const gray: HexColor = 0x808080;
    pub const dim_gray: HexColor = 0x696969;
    pub const light_gray: HexColor = 0xD3D3D3;
    pub const slate_gray: HexColor = 0x708090;
    pub const white: HexColor = 0xFFFFFF;
    pub const white_smoke: HexColor = 0xF5F5F5;
    pub const gainsboro: HexColor = 0xDCDCDC;
    pub const salmon: HexColor = 0xFA8072;
    pub const plum: HexColor = 0xDDA0DD;
    pub const dark_orange: HexColor = 0xFF8C00;
    pub const dark_cyan: HexColor = 0x008B8B;
};
/// The drawing callbacks, as named types so the struct fields stay readable. Each pushes
/// one primitive into the caller's renderer; `ctx` is the DebugDraw.context passthrough.
pub const DrawPolygonFn = *const fn (
    transform: Transform2,
    vertices: []const Vec2,
    color: HexColor,
    ctx: *anyopaque,
) void;
pub const DrawSolidPolygonFn = *const fn (
    transform: Transform2,
    vertices: []const Vec2,
    radius: f32,
    color: HexColor,
    ctx: *anyopaque,
) void;
pub const DrawCircleFn = *const fn (center: Vec2, radius: f32, color: HexColor, ctx: *anyopaque) void;
pub const DrawSolidCircleFn = *const fn (
    transform: Transform2,
    center: Vec2,
    radius: f32,
    color: HexColor,
    ctx: *anyopaque,
) void;
pub const DrawSolidCapsuleFn = *const fn (
    p1: Vec2,
    p2: Vec2,
    radius: f32,
    color: HexColor,
    ctx: *anyopaque,
) void;
pub const DrawLineFn = *const fn (p1: Vec2, p2: Vec2, color: HexColor, ctx: *anyopaque) void;
pub const DrawTransformFn = *const fn (transform: Transform2, ctx: *anyopaque) void;
pub const DrawPointFn = *const fn (p: Vec2, size: f32, color: HexColor, ctx: *anyopaque) void;
pub const DrawStringFn = *const fn (p: Vec2, s: []const u8, color: HexColor, ctx: *anyopaque) void;
pub const DrawAabbFn = *const fn (aabb: Aabb2, color: HexColor, ctx: *anyopaque) void;
/// The drawing interface and feature flags. Fill in the callbacks you support; the rest
/// are skipped. `context` is forwarded to every callback. box2d: b2DebugDraw
pub const DebugDraw = struct {
    draw_polygon: ?DrawPolygonFn = null, // closed CCW outline in a frame
    draw_solid_polygon: ?DrawSolidPolygonFn = null, // filled CCW (optionally rounded) in a frame
    draw_circle: ?DrawCircleFn = null, // outline at a world center
    draw_solid_circle: ?DrawSolidCircleFn = null, // filled; center in a frame
    draw_solid_capsule: ?DrawSolidCapsuleFn = null, // filled, between world endpoints
    draw_line: ?DrawLineFn = null, // world-space segment
    draw_transform: ?DrawTransformFn = null, // a body/joint frame (draw your own axis cross)
    draw_point: ?DrawPointFn = null, // point marker (size in pixels)
    draw_string: ?DrawStringFn = null, // text label at a world position
    draw_aabb: ?DrawAabbFn = null, // axis-aligned box outline
    /// Only shapes whose proxy overlaps these bounds are visited.
    drawing_bounds: Aabb2 = .{ .lower = .{ -1.0e9, -1.0e9 }, .upper = .{ 1.0e9, 1.0e9 } },
    force_scale: f32 = 0.001, // metres of arrow per newton, for contact-force lines
    joint_scale: f32 = 1.0, // global scale for joint decorations
    draw_shapes: bool = true,
    draw_chain_normals: bool = false,
    draw_joints: bool = false,
    draw_joint_extras: bool = false,
    draw_bounds: bool = false,
    draw_mass: bool = false,
    draw_contacts: bool = false,
    draw_anchor_a: bool = false, // draw contact anchor A rather than B
    draw_contact_normals: bool = false,
    draw_contact_forces: bool = false,
    context: *anyopaque = undefined,
};
/// Compose a body transform with a joint's local frame to get that frame in world space.
/// box2d: b2OffsetWorldTransform (mul of the two transforms)
fn offsetTransform(xf: Transform2, local: Transform2) Transform2 {
    return .{ .q = mulRot2(xf.q, local.q), .p = transformPoint2(xf, local.p) };
}
/// Pick a shape's debug color from its body's state, mirroring box2d's cascade.
/// box2d: the color ladder in DrawQueryCallback
fn debugShapeColor(world: *const World, shape: *const Shape) HexColor {
    const body: *const Body = &world.bodies.data[shape.body];
    if (body.motion_type == .dynamic and body.mass == 0.0) {
        return colors.red;
    }
    if (body.flags.is_disabled) {
        return colors.slate_gray;
    }
    if (shape.sensor_index != null_index) {
        return colors.wheat;
    }
    if (body.flags.had_time_of_impact) {
        return colors.lime;
    }
    if (body.flags.is_bullet and body.asleep == false) {
        return colors.turquoise;
    }
    if (world.state[shape.body].flags.is_speed_capped) {
        return colors.yellow;
    }
    if (body.flags.is_fast) {
        return colors.salmon;
    }
    if (body.motion_type == .static) {
        return colors.pale_green;
    }
    if (body.motion_type == .kinematic) {
        return colors.royal_blue;
    }
    if (body.asleep == false) {
        return colors.pink;
    }
    return colors.gray;
}
/// Emit one shape's geometry through the callbacks. box2d: b2DrawShape
fn drawShapeGeom(
    dd: *const DebugDraw,
    geom: Geometry,
    xf: Transform2,
    color: HexColor,
) void {
    switch (geom) {
        .circle => |c| {
            if (dd.draw_solid_circle) |f| {
                f(xf, c.center, c.radius, color, dd.context);
            }
        },
        .capsule => |c| {
            const p1: Vec2 = transformPoint2(xf, c.center1);
            const p2: Vec2 = transformPoint2(xf, c.center2);
            if (dd.draw_solid_capsule) |f| {
                f(p1, p2, c.radius, color, dd.context);
            }
        },
        .polygon => |p| {
            if (dd.draw_solid_polygon) |f| {
                f(xf, p.vertices[0..p.count], p.radius, color, dd.context);
            }
        },
        .segment => |s| {
            const p1: Vec2 = transformPoint2(xf, s.point1);
            const p2: Vec2 = transformPoint2(xf, s.point2);
            if (dd.draw_line) |f| {
                f(p1, p2, color, dd.context);
            }
        },
        .chain_segment => |cs| {
            const p1: Vec2 = transformPoint2(xf, cs.segment.point1);
            const p2: Vec2 = transformPoint2(xf, cs.segment.point2);
            if (dd.draw_line) |f| {
                f(p1, p2, color, dd.context);
            }
            if (dd.draw_point) |f| {
                f(p2, 4.0, color, dd.context);
            }
            if (dd.draw_chain_normals) {
                const mid: Vec2 = (p1 + p2) * splat2(0.5);
                const e: Vec2 = normalizeOrZero2(p2 - p1);
                const nrm: Vec2 = rightPerp2(e);
                if (dd.draw_line) |f| {
                    f(mid, mulAdd2(mid, 0.2, nrm), colors.pale_green, dd.context);
                }
            }
        },
    }
}
/// Visualize one joint by type. box2d: b2DrawJoint + the per-type b2Draw*Joint helpers
fn drawJoint(world: *World, dd: *const DebugDraw, joint_id: u32) void {
    const j: *const Joint = &world.joints.data[joint_id];
    if (world.bodies.data[j.body_a].flags.is_disabled or
        world.bodies.data[j.body_b].flags.is_disabled)
    {
        return;
    }
    const xf_a: Transform2 = world.bodies.data[j.body_a].transform;
    const xf_b: Transform2 = world.bodies.data[j.body_b].transform;
    const pa: Vec2 = transformPoint2(xf_a, j.local_frame_a.p);
    const pb: Vec2 = transformPoint2(xf_b, j.local_frame_b.p);
    const scale: f32 = @max(0.0001, dd.joint_scale);
    switch (j.data) {
        .distance => |d| drawDistanceJoint(dd, j, d, xf_a, xf_b),
        .revolute => |r| drawRevoluteJoint(dd, j, r, xf_a, xf_b, scale),
        .prismatic => |p| drawPrismaticJoint(dd, j, p, xf_a, xf_b, scale),
        .wheel => |w| drawWheelJoint(dd, j, w, xf_a, xf_b, scale),
        .weld => drawWeldJoint(dd, j, xf_a, xf_b, scale),
        .motor => {
            if (dd.draw_point) |f| {
                f(pa, 8.0, colors.yellow_green, dd.context);
            }
            if (dd.draw_point) |f| {
                f(pb, 8.0, colors.plum, dd.context);
            }
            if (dd.draw_line) |f| {
                f(pa, pb, colors.light_gray, dd.context);
            }
        },
        .filter => {
            if (dd.draw_line) |f| {
                f(pa, pb, colors.gold, dd.context);
            }
        },
        .pulley => |pl| {
            if (dd.draw_line) |f| {
                f(pl.ground_anchor_a, pa, colors.light_gray, dd.context);
                f(pl.ground_anchor_b, pb, colors.light_gray, dd.context);
                f(pl.ground_anchor_a, pl.ground_anchor_b, colors.gold, dd.context);
            }
            if (dd.draw_point) |f| {
                f(pl.ground_anchor_a, 6.0, colors.plum, dd.context);
                f(pl.ground_anchor_b, 6.0, colors.plum, dd.context);
            }
        },
    }
    if (dd.draw_joint_extras) {
        const handle: JointHandle = JointHandle.pack(@intCast(joint_id), world.joints.cycle[joint_id]);
        const force: Vec2 = getConstraintForce(world, handle);
        const mid: Vec2 = (pa + pb) * splat2(0.5);
        if (dd.draw_line) |f| {
            f(mid, mulAdd2(mid, dd.force_scale, force), colors.gold, dd.context);
        }
    }
}
fn drawDistanceJoint(
    dd: *const DebugDraw,
    j: *const Joint,
    d: DistanceJoint,
    xf_a: Transform2,
    xf_b: Transform2,
) void {
    const pa: Vec2 = transformPoint2(xf_a, j.local_frame_a.p);
    const pb: Vec2 = transformPoint2(xf_b, j.local_frame_b.p);
    const axis: Vec2 = normalizeOrZero2(pb - pa);
    if (d.min_length < d.max_length and d.enable_limit) {
        const p_min: Vec2 = mulAdd2(pa, d.min_length, axis);
        const p_max: Vec2 = mulAdd2(pa, d.max_length, axis);
        const offset: Vec2 = rightPerp2(axis) * splat2(0.05);
        if (d.min_length > linear_slop) {
            if (dd.draw_line) |f| {
                f(p_min - offset, p_min + offset, colors.light_green, dd.context);
            }
        }
        if (d.max_length < huge_length) {
            if (dd.draw_line) |f| {
                f(p_max - offset, p_max + offset, colors.red, dd.context);
            }
        }
        if (d.min_length > linear_slop and d.max_length < huge_length) {
            if (dd.draw_line) |f| {
                f(p_min, p_max, colors.gray, dd.context);
            }
        }
    }
    if (dd.draw_line) |f| {
        f(pa, pb, colors.white, dd.context);
    }
    if (dd.draw_point) |f| {
        f(pa, 4.0, colors.white, dd.context);
    }
    if (dd.draw_point) |f| {
        f(pb, 4.0, colors.white, dd.context);
    }
    if (d.hertz > 0.0 and d.enable_spring) {
        const p_rest: Vec2 = mulAdd2(pa, d.length, axis);
        if (dd.draw_point) |f| {
            f(p_rest, 4.0, colors.blue, dd.context);
        }
    }
}
fn drawRevoluteJoint(
    dd: *const DebugDraw,
    j: *const Joint,
    r: RevoluteJoint,
    xf_a: Transform2,
    xf_b: Transform2,
    scale: f32,
) void {
    const frame_a: Transform2 = offsetTransform(xf_a, j.local_frame_a);
    const frame_b: Transform2 = offsetTransform(xf_b, j.local_frame_b);
    const radius: f32 = 0.25 * scale;
    if (dd.draw_circle) |f| {
        f(frame_b.p, radius, colors.gray, dd.context);
    }
    const rx: Vec2 = .{ radius, 0 };
    if (dd.draw_line) |f| {
        const ra: Vec2 = rotateVec2(frame_a.q, rx);
        f(frame_a.p, frame_a.p + ra, colors.gray, dd.context);
        const rb: Vec2 = rotateVec2(frame_b.q, rx);
        f(frame_b.p, frame_b.p + rb, colors.blue, dd.context);
    }
    if (r.enable_limit) {
        const rot_lo: Rot2 = mulRot2(frame_a.q, Rot2.fromAngle(r.lower_angle));
        const rot_hi: Rot2 = mulRot2(frame_a.q, Rot2.fromAngle(r.upper_angle));
        if (dd.draw_line) |f| {
            f(frame_b.p, frame_b.p + rotateVec2(rot_lo, rx), colors.green, dd.context);
            f(frame_b.p, frame_b.p + rotateVec2(rot_hi, rx), colors.red, dd.context);
        }
    }
    if (r.enable_spring) {
        const q: Rot2 = mulRot2(frame_a.q, Rot2.fromAngle(r.target_angle));
        if (dd.draw_line) |f| {
            f(frame_b.p, frame_b.p + rotateVec2(q, rx), colors.violet, dd.context);
        }
    }
    if (dd.draw_line) |f| {
        f(xf_a.p, frame_a.p, colors.gold, dd.context);
        f(frame_a.p, frame_b.p, colors.gold, dd.context);
        f(xf_b.p, frame_b.p, colors.gold, dd.context);
    }
}
fn drawPrismaticJoint(
    dd: *const DebugDraw,
    j: *const Joint,
    p: PrismaticJoint,
    xf_a: Transform2,
    xf_b: Transform2,
    scale: f32,
) void {
    const frame_a: Transform2 = offsetTransform(xf_a, j.local_frame_a);
    const frame_b: Transform2 = offsetTransform(xf_b, j.local_frame_b);
    const axis: Vec2 = rotateVec2(frame_a.q, .{ 1, 0 });
    if (dd.draw_line) |f| {
        f(frame_a.p, frame_b.p, colors.dim_gray, dd.context);
    }
    if (p.enable_limit) {
        const b: f32 = 0.25 * scale;
        const lower: Vec2 = mulAdd2(frame_a.p, p.lower_translation, axis);
        const upper: Vec2 = mulAdd2(frame_a.p, p.upper_translation, axis);
        const perp: Vec2 = leftPerp2(axis);
        if (dd.draw_line) |f| {
            f(lower, upper, colors.gray, dd.context);
            f(mulAdd2(lower, -b, perp), mulAdd2(lower, b, perp), colors.green, dd.context);
            f(mulAdd2(upper, -b, perp), mulAdd2(upper, b, perp), colors.red, dd.context);
        }
    } else {
        if (dd.draw_line) |f| {
            f(frame_a.p - axis, frame_a.p + axis, colors.gray, dd.context);
        }
    }
    if (p.enable_spring) {
        const pt: Vec2 = mulAdd2(frame_a.p, p.target_translation, axis);
        if (dd.draw_point) |f| {
            f(pt, 8.0, colors.violet, dd.context);
        }
    }
    if (dd.draw_point) |f| {
        f(frame_a.p, 5.0, colors.gray, dd.context);
    }
    if (dd.draw_point) |f| {
        f(frame_b.p, 5.0, colors.blue, dd.context);
    }
}
fn drawWheelJoint(
    dd: *const DebugDraw,
    j: *const Joint,
    w: WheelJoint,
    xf_a: Transform2,
    xf_b: Transform2,
    scale: f32,
) void {
    const frame_a: Transform2 = offsetTransform(xf_a, j.local_frame_a);
    const frame_b: Transform2 = offsetTransform(xf_b, j.local_frame_b);
    const axis: Vec2 = rotateVec2(frame_a.q, .{ 1, 0 });
    if (dd.draw_line) |f| {
        f(frame_a.p, frame_b.p, colors.blue, dd.context);
    }
    if (w.enable_limit) {
        const lower: Vec2 = mulAdd2(frame_a.p, w.lower_translation, axis);
        const upper: Vec2 = mulAdd2(frame_a.p, w.upper_translation, axis);
        const perp: Vec2 = leftPerp2(axis);
        const b: f32 = 0.1 * scale;
        if (dd.draw_line) |f| {
            f(lower, upper, colors.gray, dd.context);
            f(mulAdd2(lower, -b, perp), mulAdd2(lower, b, perp), colors.green, dd.context);
            f(mulAdd2(upper, -b, perp), mulAdd2(upper, b, perp), colors.red, dd.context);
        }
    } else {
        if (dd.draw_line) |f| {
            f(frame_a.p - axis, frame_a.p + axis, colors.gray, dd.context);
        }
    }
    if (dd.draw_point) |f| {
        f(frame_a.p, 5.0, colors.gray, dd.context);
    }
    if (dd.draw_point) |f| {
        f(frame_b.p, 5.0, colors.dim_gray, dd.context);
    }
}
fn drawWeldJoint(
    dd: *const DebugDraw,
    j: *const Joint,
    xf_a: Transform2,
    xf_b: Transform2,
    scale: f32,
) void {
    const frame_a: Transform2 = offsetTransform(xf_a, j.local_frame_a);
    const frame_b: Transform2 = offsetTransform(xf_b, j.local_frame_b);
    const box: Polygon = makeBox(0.25 * scale, 0.125 * scale);
    if (dd.draw_polygon) |f| {
        f(frame_a, box.vertices[0..box.count], colors.dark_orange, dd.context);
        f(frame_b, box.vertices[0..box.count], colors.dark_cyan, dd.context);
    }
}
/// Walk the world and emit debug primitives. Shapes (and the bodies they belong to) are
/// found by querying the broad-phase trees against `drawing_bounds`, then joints, contacts,
/// and mass markers are drawn for the bodies in view. box2d: b2World_Draw
pub fn draw(world: *World, dd: *const DebugDraw) !void {
    const gpa: Allocator = world.allocator;
    const seen: []bool = try gpa.alloc(bool, world.capacity);
    defer gpa.free(seen);
    @memset(seen, false);
    var ctx: DrawContext = .{ .world = world, .dd = dd, .seen = seen };
    // Shapes + bounds, marking each in-view body. Always run so the body set is populated
    // even when only joints/contacts/mass are requested.
    var t: usize = 0;
    while (t < 3) : (t += 1) {
        world.broadphase.trees[t].query(dd.drawing_bounds, default_mask_bits, drawShapeCallback, &ctx);
    }
    if (dd.draw_joints) {
        for (world.joint_ids.items) |joint_id| {
            const j: *const Joint = &world.joints.data[joint_id];
            if (seen[j.body_a] or seen[j.body_b]) {
                drawJoint(world, dd, joint_id);
            }
        }
    }
    if (dd.draw_contacts or dd.draw_contact_normals or dd.draw_contact_forces) {
        for (world.contact_ids.items) |contact_id| {
            const c: *const Contact = &world.contacts.data[contact_id];
            if (c.flags.touching == false) {
                continue;
            }
            if (seen[c.body_a] == false and seen[c.body_b] == false) {
                continue;
            }
            drawContact(world, dd, c);
        }
    }
    if (dd.draw_mass) {
        var i: u32 = 0;
        while (i < world.capacity) : (i += 1) {
            if (seen[i] == false) {
                continue;
            }
            const b: *const Body = &world.bodies.data[i];
            if (b.motion_type != .dynamic) {
                continue;
            }
            if (dd.draw_line) |f| {
                f(b.center0, b.center, colors.white_smoke, dd.context);
            }
            if (dd.draw_transform) |f| {
                f(.{ .q = b.transform.q, .p = b.center }, dd.context);
            }
        }
    }
}
const DrawContext = struct {
    world: *World,
    dd: *const DebugDraw,
    seen: []bool,
};
fn drawShapeCallback(proxy_id: i32, user_data: u64, ctx_ptr: *anyopaque) bool {
    _ = proxy_id;
    const ctx: *DrawContext = @ptrCast(@alignCast(ctx_ptr));
    const world: *World = ctx.world;
    const dd: *const DebugDraw = ctx.dd;
    const shape_id: ShapeIndex = @intCast(user_data);
    const shape: *const Shape = &world.shapes.data[shape_id];
    ctx.seen[shape.body] = true;
    if (dd.draw_shapes) {
        const xf: Transform2 = world.bodies.data[shape.body].transform;
        drawShapeGeom(dd, shape.geom, xf, debugShapeColor(world, shape));
    }
    if (dd.draw_bounds) {
        if (dd.draw_aabb) |f| {
            f(shape.fat_aabb, colors.gold, dd.context);
        }
    }
    return true;
}
/// Draw a touching contact's manifold points, normals, and force arrows. box2d: the contact
/// block of b2World_Draw
fn drawContact(world: *World, dd: *const DebugDraw, c: *const Contact) void {
    const normal: Vec2 = c.manifold.normal;
    const center_a: Vec2 = world.bodies.data[c.body_a].center;
    const center_b: Vec2 = world.bodies.data[c.body_b].center;
    const axis_scale: f32 = 0.3;
    var k: u32 = 0;
    while (k < c.manifold.count) : (k += 1) {
        const mp: *const ManifoldPoint = &c.manifold.points[k];
        const p: Vec2 = if (dd.draw_anchor_a) center_a + mp.anchor_a else center_b + mp.anchor_b;
        if (dd.draw_contacts) {
            if (mp.separation > linear_slop) {
                if (dd.draw_point) |f| {
                    f(p, 5.0, colors.gainsboro, dd.context);
                }
            } else if (mp.persisted == false) {
                if (dd.draw_point) |f| {
                    f(p, 10.0, colors.green, dd.context);
                }
            } else {
                if (dd.draw_point) |f| {
                    f(p, 5.0, colors.blue, dd.context);
                }
            }
        }
        if (dd.draw_contact_normals) {
            if (dd.draw_line) |f| {
                f(p, mulAdd2(p, axis_scale, normal), colors.dim_gray, dd.context);
            }
        } else if (dd.draw_contact_forces) {
            const force: f32 = 0.5 * mp.total_normal_impulse * world.inv_dt;
            const tip: Vec2 = mulAdd2(p, dd.force_scale * force, normal);
            if (dd.draw_line) |f| {
                f(p, tip, colors.magenta, dd.context);
            }
        }
    }
}

// -- Public API: kinematic character mover ---------------------------------------
//
// A capsule "mover" (character controller) is not a body; it is collided against the world
// on demand. The typical loop: castMover to find how far the mover can travel before a
// hit, then collideMover to gather the contact planes around the mover's position, then
// solvePlanes to resolve depenetration / sliding, and clipVector to project the velocity
// onto the surviving planes. All geometry is expressed relative to the mover `origin`, so
// the math stays in single-precision range far from the world origin. box2d: mover.c + the
// b2World_CastMover / b2World_CollideMover pair in physics_world.c
/// An oriented plane: points on the surface satisfy dot(normal, p) == offset.
/// box2d: b2Plane  math_functions.h
pub const Plane = struct {
    normal: Vec2 = .{ 0, 0 },
    offset: f32 = 0,
};
/// Signed distance of a point from a plane (positive on the normal's side).
/// box2d: b2PlaneSeparation
fn planeSeparation(plane: Plane, point: Vec2) f32 {
    return dot2(plane.normal, point) - plane.offset;
}
/// One collision result from collideMover: the plane between the mover and a shape, plus
/// the contact point. `hit` false means ignore it. box2d: b2PlaneResult
pub const PlaneResult = struct {
    plane: Plane = .{},
    /// Contact point on the shape. As in box2d, this is left in the shape's local frame
    /// (only the plane normal is rotated into the query frame).
    point: Vec2 = .{ 0, 0 },
    hit: bool = false,
};
/// A plane fed to solvePlanes. `push_limit` caps how far this plane may push the mover
/// (floatMax = perfectly rigid; smaller = soft). `push` is filled in by the solver.
/// box2d: b2CollisionPlane
pub const CollisionPlane = struct {
    plane: Plane,
    push_limit: f32 = floatMax(f32),
    push: f32 = 0,
    clip_velocity: bool = true,
};
/// Result of solvePlanes: the resolved mover translation and the iteration count used.
/// box2d: b2PlaneSolverResult
pub const PlaneSolverResult = struct {
    translation: Vec2 = .{ 0, 0 },
    iteration_count: u32 = 0,
};
/// Resolve a mover position satisfying the given planes, starting from `target_delta` (the
/// desired movement from the position the planes were generated at). A relaxation solver
/// accumulates a clamped push per plane until the total correction falls below the slop.
/// box2d: b2SolvePlanes  mover.c
pub fn solvePlanes(target_delta: Vec2, planes: []CollisionPlane) PlaneSolverResult {
    for (planes) |*plane| {
        plane.push = 0.0;
    }
    var delta: Vec2 = target_delta;
    const tolerance: f32 = linear_slop;
    var iteration: u32 = 0;
    while (iteration < 20) : (iteration += 1) {
        var total_push: f32 = 0.0;
        for (planes) |*plane| {
            const separation: f32 = planeSeparation(plane.plane, delta) + linear_slop;
            var push: f32 = -separation;
            const accumulated: f32 = plane.push;
            plane.push = clamp(plane.push + push, 0.0, plane.push_limit);
            push = plane.push - accumulated;
            delta = mulAdd2(delta, push, plane.plane.normal);
            total_push += @abs(push);
        }
        if (total_push < tolerance) {
            break;
        }
    }
    return .{ .translation = delta, .iteration_count = iteration };
}
/// Project a velocity onto the planes that pushed the mover, removing the components that
/// drive into them (so the mover slides along surfaces). Planes with no push or with
/// clip_velocity off are skipped. box2d: b2ClipVector  mover.c
pub fn clipVector(vector: Vec2, planes: []const CollisionPlane) Vec2 {
    var v: Vec2 = vector;
    for (planes) |plane| {
        if (plane.push == 0.0 or plane.clip_velocity == false) {
            continue;
        }
        v = mulSub2(v, @min(0.0, dot2(v, plane.plane.normal)), plane.plane.normal);
    }
    return v;
}
/// Whether a vector is unit length within box2d's tolerance. box2d: b2IsNormalized
fn isNormalized2(v: Vec2) bool {
    return @abs(1.0 - lengthSq2(v)) < 100.0 * floatEps(f32);
}
/// Distance/plane between a capsule mover (in shape-local frame) and a shape's core proxy.
/// `shape_radius` is added to the mover radius to form the contact threshold (the proxy
/// itself is built without radius and the GJK runs core-to-core). box2d: b2CollideMoverAnd*
fn moverPlane(proxy_a: ShapeProxy, mover: Capsule, shape_radius: f32) PlaneResult {
    const input: DistanceInput = .{
        .proxy_a = proxy_a,
        .proxy_b = makeProxy(&[_]Vec2{ mover.center1, mover.center2 }, mover.radius),
        .transform = Transform2.identity,
        .use_radii = false,
    };
    var cache: SimplexCache = SimplexCache.empty;
    const out: DistanceOutput = shapeDistance(&input, &cache);
    const total_radius: f32 = mover.radius + shape_radius;
    if (out.distance <= total_radius) {
        return .{
            .plane = .{ .normal = out.normal, .offset = total_radius - out.distance },
            .point = out.point_a,
            .hit = true,
        };
    }
    return .{};
}
/// Collide the mover capsule against one shape at `transform` (the shape's body transform
/// expressed relative to the mover origin). Returns the contact plane with its normal
/// rotated into the query frame. box2d: b2CollideMover  shape.c
fn collideMoverShape(mover: Capsule, geom: Geometry, transform: Transform2) PlaneResult {
    const local: Capsule = .{
        .center1 = invTransformPoint2(transform, mover.center1),
        .center2 = invTransformPoint2(transform, mover.center2),
        .radius = mover.radius,
    };
    var proxy_a: ShapeProxy = undefined;
    var shape_radius: f32 = 0;
    switch (geom) {
        .circle => |c| {
            proxy_a = makeProxy(&[_]Vec2{c.center}, 0);
            shape_radius = c.radius;
        },
        .capsule => |c| {
            proxy_a = makeProxy(&[_]Vec2{ c.center1, c.center2 }, 0);
            shape_radius = c.radius;
        },
        .polygon => |p| {
            proxy_a = makeProxy(p.vertices[0..p.count], 0);
            shape_radius = p.radius;
        },
        .segment => |s| {
            proxy_a = makeProxy(&[_]Vec2{ s.point1, s.point2 }, 0);
        },
        .chain_segment => |cs| {
            proxy_a = makeProxy(&[_]Vec2{ cs.segment.point1, cs.segment.point2 }, 0);
        },
    }
    var result: PlaneResult = moverPlane(proxy_a, local, shape_radius);
    if (result.hit) {
        result.plane.normal = rotateVec2(transform.q, result.plane.normal);
    }
    return result;
}
/// User callback receiving each mover collision plane. Return false to stop the query.
/// box2d: b2PlaneResultFcn
pub const PlaneResultFcn = *const fn (shape: ShapeIndex, result: *const PlaneResult, ctx: *anyopaque) bool;
const MoverCollideContext = struct {
    world: *World,
    origin: Vec2,
    mover: Capsule,
    filter: QueryFilter,
    fcn: PlaneResultFcn,
    user_ctx: *anyopaque,
    stop: bool = false,
};
fn moverCollideCallback(proxy_id: i32, user_data: u64, ctx_ptr: *anyopaque) bool {
    _ = proxy_id;
    const ctx: *MoverCollideContext = @ptrCast(@alignCast(ctx_ptr));
    const world: *World = ctx.world;
    const shape_id: ShapeIndex = @intCast(user_data);
    const shape: *const Shape = &world.shapes.data[shape_id];
    if (shouldQueryCollide(shape, ctx.filter) == false) {
        return true;
    }
    const body_xf: Transform2 = world.bodies.data[shape.body].transform;
    const rel: Transform2 = .{ .q = body_xf.q, .p = body_xf.p - ctx.origin };
    const result: PlaneResult = collideMoverShape(ctx.mover, shape.geom, rel);
    if (result.hit and isNormalized2(result.plane.normal)) {
        const proceed: bool = ctx.fcn(shape_id, &result, ctx.user_ctx);
        if (proceed == false) {
            ctx.stop = true;
        }
        return proceed;
    }
    return true;
}
/// Gather the collision planes around a capsule mover at `origin`, invoking `fcn` for each
/// shape it overlaps. Feed the collected planes to solvePlanes. box2d: b2World_CollideMover
pub fn collideMover(
    world: *World,
    origin: Vec2,
    mover: Capsule,
    filter: QueryFilter,
    fcn: PlaneResultFcn,
    user_ctx: *anyopaque,
) void {
    const r: Vec2 = splat2(mover.radius);
    const lo: Vec2 = @min(mover.center1, mover.center2) - r;
    const hi: Vec2 = @max(mover.center1, mover.center2) + r;
    const aabb: Aabb2 = .{ .lower = lo + origin, .upper = hi + origin };
    var ctx: MoverCollideContext = .{
        .world = world,
        .origin = origin,
        .mover = mover,
        .filter = filter,
        .fcn = fcn,
        .user_ctx = user_ctx,
    };
    const bp: *BroadPhase = &world.broadphase;
    var t: usize = 0;
    while (t < 3) : (t += 1) {
        bp.trees[t].query(aabb, filter.mask, moverCollideCallback, &ctx);
        if (ctx.stop) {
            return;
        }
    }
}
const MoverCastContext = struct {
    world: *World,
    filter: QueryFilter,
    origin: Vec2,
    input: ShapeCastInput,
    fraction: f32,
};
fn moverCastCallback(
    input: *const BoxCastInput,
    proxy_id: i32,
    user_data: u64,
    ctx_ptr: *anyopaque,
) f32 {
    _ = proxy_id;
    const ctx: *MoverCastContext = @ptrCast(@alignCast(ctx_ptr));
    const world: *World = ctx.world;
    const shape_id: ShapeIndex = @intCast(user_data);
    const shape: *const Shape = &world.shapes.data[shape_id];
    if (shouldQueryCollide(shape, ctx.filter) == false) {
        return input.max_fraction;
    }
    var local_input: ShapeCastInput = ctx.input;
    local_input.max_fraction = input.max_fraction; // never look past the current clip
    const body_xf: Transform2 = world.bodies.data[shape.body].transform;
    const rel: Transform2 = .{ .q = body_xf.q, .p = body_xf.p - ctx.origin };
    const output: CastOutput = shapeCastShape(&local_input, shape.geom, rel);
    // A zero fraction means the mover already overlaps at the start; ignore it so the
    // mover is not trapped by initial penetration (canEncroach handles the overlap).
    if (output.hit and output.fraction > 0.0 and output.fraction < ctx.fraction) {
        ctx.fraction = output.fraction;
        return output.fraction; // shrink the sweep
    }
    return input.max_fraction;
}
/// Cast a capsule mover from `origin` along `translation`, returning the fraction in [0, 1]
/// of the translation it can travel before the first hit (1 = no hit), using an ordered,
/// shrinking box cast through each broad-phase tree. box2d: b2World_CastMover
pub fn castMover(
    world: *World,
    origin: Vec2,
    mover: Capsule,
    translation: Vec2,
    filter: QueryFilter,
) f32 {
    const proxy: ShapeProxy = makeProxy(&[_]Vec2{ mover.center1, mover.center2 }, mover.radius);
    var ctx: MoverCastContext = .{
        .world = world,
        .filter = filter,
        .origin = origin,
        .input = .{ .proxy = proxy, .translation = translation, .max_fraction = 1.0, .can_encroach = true },
        .fraction = 1.0,
    };
    const r: Vec2 = splat2(mover.radius);
    const lo: Vec2 = @min(mover.center1, mover.center2) - r + origin;
    const hi: Vec2 = @max(mover.center1, mover.center2) + r + origin;
    var input: BoxCastInput = .{
        .box = .{ .lower = lo, .upper = hi },
        .translation = translation,
        .max_fraction = 1.0,
    };
    const bp: *BroadPhase = &world.broadphase;
    var t: usize = 0;
    while (t < 3) : (t += 1) {
        boxCastTree(&bp.trees[t], &input, filter.mask, moverCastCallback, &ctx);
        if (ctx.fraction == 0.0) {
            break;
        }
        input.max_fraction = ctx.fraction; // carry the clip across trees
    }
    return ctx.fraction;
}

// -- Wide (SIMD) contact solver --------------------------------------------------
//
// Each non-overflow graph color is solved four contacts at a time using @Vector(4, f32)
// lanes (which the backend lowers to wasm128 / SSE). Because the coloring guarantees no
// dynamic body appears twice in a color, the four contacts in a block touch eight distinct
// dynamic bodies, so scattering the solved velocities back never races. Inactive lanes (a
// color whose count is not a multiple of four) and one-point manifolds carry zeroed masses,
// so they compute zero impulse and contribute nothing. This is a lane-parallel transcription
// of the scalar contact kernels above; the overflow color stays scalar.
// box2d: the SIMD half of contact_solver.c (b2*ContactsTask)
const simd_width: u32 = 4;
const FloatW = @Vector(simd_width, f32);
const MaskW = @Vector(simd_width, bool);
/// A 2D vector with each component spread across the SIMD lanes.
const Vec2W = struct { x: FloatW, y: FloatW };

inline fn splatW(s: f32) FloatW {
    return @splat(s);
}
inline fn dotW(ax: FloatW, ay: FloatW, bx: FloatW, by: FloatW) FloatW {
    return ax * bx + ay * by;
}
/// Scalar cross product per lane: cross(a, b) = a.x*b.y - a.y*b.x.
inline fn crossW(ax: FloatW, ay: FloatW, bx: FloatW, by: FloatW) FloatW {
    return ax * by - ay * bx;
}

/// One block of up to four contacts in struct-of-arrays form. box2d: b2ContactConstraintWide
const WideConstraint = struct {
    index_a: [simd_width]u32, // body indices for gather/scatter (slot 0 for padding)
    index_b: [simd_width]u32,
    source: [simd_width]u32, // scalar-constraint index per lane (null_index if padding)
    inv_mass_a: FloatW,
    inv_mass_b: FloatW,
    inv_inertia_a: FloatW,
    inv_inertia_b: FloatW,
    normal: Vec2W,
    friction: FloatW,
    tangent_speed: FloatW,
    rolling_resistance: FloatW,
    rolling_mass: FloatW,
    rolling_impulse: FloatW,
    bias_rate: FloatW,
    mass_scale: FloatW,
    impulse_scale: FloatW,
    // Two manifold points (point 2 zeroed for one-point manifolds).
    anchor_a1: Vec2W,
    anchor_b1: Vec2W,
    base_sep1: FloatW,
    normal_mass1: FloatW,
    tangent_mass1: FloatW,
    normal_impulse1: FloatW,
    tangent_impulse1: FloatW,
    total_normal_impulse1: FloatW,
    rel_vel1: FloatW,
    anchor_a2: Vec2W,
    anchor_b2: Vec2W,
    base_sep2: FloatW,
    normal_mass2: FloatW,
    tangent_mass2: FloatW,
    normal_impulse2: FloatW,
    tangent_impulse2: FloatW,
    total_normal_impulse2: FloatW,
    rel_vel2: FloatW,
    restitution: FloatW,
};

/// Gathered per-lane body velocity and the position deltas the solve reads.
const BodyStateW = struct {
    vx: FloatW,
    vy: FloatW,
    w: FloatW,
    dpx: FloatW,
    dpy: FloatW,
    dqc: FloatW,
    dqs: FloatW,
};

inline fn gatherBodies(
    motion: []const Motion,
    state: []const BodyState,
    indices: [simd_width]u32,
) BodyStateW {
    var r: BodyStateW = undefined;
    inline for (0..simd_width) |l| {
        const i: u32 = indices[l];
        const m: Motion = motion[i];
        const s: BodyState = state[i];
        r.vx[l] = m.linear_velocity[0];
        r.vy[l] = m.linear_velocity[1];
        r.w[l] = m.angular_velocity;
        r.dpx[l] = s.delta_position[0];
        r.dpy[l] = s.delta_position[1];
        r.dqc[l] = s.delta_rotation.cosine;
        r.dqs[l] = s.delta_rotation.sine;
    }
    return r;
}

/// Write solved velocities back, per lane, only for dynamic bodies (matching
/// writeBackVelocity). Static/kinematic/padding lanes are skipped, so duplicate static
/// bodies across lanes are harmless.
inline fn scatterBodies(
    state: []const BodyState,
    motion: []Motion,
    indices: [simd_width]u32,
    vx: FloatW,
    vy: FloatW,
    w: FloatW,
) void {
    inline for (0..simd_width) |l| {
        const i: u32 = indices[l];
        if (state[i].flags.dynamic) {
            motion[i].linear_velocity = .{ vx[l], vy[l] };
            motion[i].angular_velocity = w[l];
        }
    }
}

/// Pack the non-overflow color ranges of the (color-sorted) scalar constraints into wide
/// blocks of four. Padding lanes and absent second points are left zeroed.
fn buildWideBlocks(
    world: *World,
    constraints: []const ContactConstraint,
    blocks: *std.ArrayListUnmanaged(WideConstraint),
) !void {
    // Wide blocks are step-scoped scratch: allocate from the per-step arena.
    const gpa: Allocator = world.step_arena.allocator();
    const graph: *const ConstraintGraph = &world.graph;
    var color: u32 = 0;
    while (color < graph_overflow_index) : (color += 1) {
        const begin: u32 = graph.contact_color_begin[color];
        const end: u32 = graph.contact_color_begin[color + 1];
        var base: u32 = begin;
        while (base < end) : (base += simd_width) {
            const lanes: u32 = @min(simd_width, end - base);
            var wc: WideConstraint = std.mem.zeroes(WideConstraint);
            wc.source = .{ null_index, null_index, null_index, null_index };
            inline for (0..simd_width) |l| {
                if (l < lanes) {
                    const idx: usize = @as(usize, base) + l;
                    const con: *const ContactConstraint = &constraints[idx];
                    wc.index_a[l] = con.body_a;
                    wc.index_b[l] = con.body_b;
                    wc.source[l] = @intCast(idx);
                    wc.inv_mass_a[l] = con.inv_mass_a;
                    wc.inv_mass_b[l] = con.inv_mass_b;
                    wc.inv_inertia_a[l] = con.inv_inertia_a;
                    wc.inv_inertia_b[l] = con.inv_inertia_b;
                    wc.normal.x[l] = con.normal[0];
                    wc.normal.y[l] = con.normal[1];
                    wc.friction[l] = con.friction;
                    wc.tangent_speed[l] = con.tangent_speed;
                    wc.rolling_resistance[l] = con.rolling_resistance;
                    wc.rolling_mass[l] = con.rolling_mass;
                    wc.rolling_impulse[l] = con.rolling_impulse;
                    wc.bias_rate[l] = con.softness.bias_rate;
                    wc.mass_scale[l] = con.softness.mass_scale;
                    wc.impulse_scale[l] = con.softness.impulse_scale;
                    wc.restitution[l] = con.restitution;
                    const p1: ContactConstraintPoint = con.points[0];
                    wc.anchor_a1.x[l] = p1.anchor_a[0];
                    wc.anchor_a1.y[l] = p1.anchor_a[1];
                    wc.anchor_b1.x[l] = p1.anchor_b[0];
                    wc.anchor_b1.y[l] = p1.anchor_b[1];
                    wc.base_sep1[l] = p1.base_separation;
                    wc.normal_mass1[l] = p1.normal_mass;
                    wc.tangent_mass1[l] = p1.tangent_mass;
                    wc.normal_impulse1[l] = p1.normal_impulse;
                    wc.tangent_impulse1[l] = p1.tangent_impulse;
                    wc.total_normal_impulse1[l] = p1.total_normal_impulse;
                    wc.rel_vel1[l] = p1.relative_velocity;
                    if (con.count == 2) {
                        const p2: ContactConstraintPoint = con.points[1];
                        wc.anchor_a2.x[l] = p2.anchor_a[0];
                        wc.anchor_a2.y[l] = p2.anchor_a[1];
                        wc.anchor_b2.x[l] = p2.anchor_b[0];
                        wc.anchor_b2.y[l] = p2.anchor_b[1];
                        wc.base_sep2[l] = p2.base_separation;
                        wc.normal_mass2[l] = p2.normal_mass;
                        wc.tangent_mass2[l] = p2.tangent_mass;
                        wc.normal_impulse2[l] = p2.normal_impulse;
                        wc.tangent_impulse2[l] = p2.tangent_impulse;
                        wc.total_normal_impulse2[l] = p2.total_normal_impulse;
                        wc.rel_vel2[l] = p2.relative_velocity;
                    }
                }
            }
            try blocks.append(gpa, wc);
        }
    }
}

/// Re-apply stored impulses each sub-step, four contacts wide. box2d: b2WarmStartContactsTask
fn warmStartWide(
    blocks: []WideConstraint,
    state: []const BodyState,
    motion: []Motion,
) void {
    for (blocks) |*wc| {
        var a: BodyStateW = gatherBodies(motion, state, wc.index_a);
        var b: BodyStateW = gatherBodies(motion, state, wc.index_b);
        const nx: FloatW = wc.normal.x;
        const ny: FloatW = wc.normal.y;
        const tx: FloatW = ny; // tangent = rightPerp(normal) = (ny, -nx)
        const ty: FloatW = -nx;

        // Point 1.
        {
            const px: FloatW = nx * wc.normal_impulse1 + tx * wc.tangent_impulse1;
            const py: FloatW = ny * wc.normal_impulse1 + ty * wc.tangent_impulse1;
            wc.total_normal_impulse1 += wc.normal_impulse1;
            a.w -= wc.inv_inertia_a * crossW(wc.anchor_a1.x, wc.anchor_a1.y, px, py);
            a.vx -= wc.inv_mass_a * px;
            a.vy -= wc.inv_mass_a * py;
            b.w += wc.inv_inertia_b * crossW(wc.anchor_b1.x, wc.anchor_b1.y, px, py);
            b.vx += wc.inv_mass_b * px;
            b.vy += wc.inv_mass_b * py;
        }
        // Point 2 (zeroed for one-point manifolds -> contributes nothing).
        {
            const px: FloatW = nx * wc.normal_impulse2 + tx * wc.tangent_impulse2;
            const py: FloatW = ny * wc.normal_impulse2 + ty * wc.tangent_impulse2;
            wc.total_normal_impulse2 += wc.normal_impulse2;
            a.w -= wc.inv_inertia_a * crossW(wc.anchor_a2.x, wc.anchor_a2.y, px, py);
            a.vx -= wc.inv_mass_a * px;
            a.vy -= wc.inv_mass_a * py;
            b.w += wc.inv_inertia_b * crossW(wc.anchor_b2.x, wc.anchor_b2.y, px, py);
            b.vx += wc.inv_mass_b * px;
            b.vy += wc.inv_mass_b * py;
        }
        a.w -= wc.inv_inertia_a * wc.rolling_impulse;
        b.w += wc.inv_inertia_b * wc.rolling_impulse;

        scatterBodies(state, motion, wc.index_a, a.vx, a.vy, a.w);
        scatterBodies(state, motion, wc.index_b, b.vx, b.vy, b.w);
    }
}

/// Solve one sub-step, four contacts wide. This is `solveContacts` transcribed into SIMD
/// lanes: read it first for the commentary and the physics - every step here is the same,
/// just done for four contacts at once. The `x`/`y` suffixes are the two components of a
/// vector spread across lanes (struct-of-arrays); `block` is the four-contact block.
/// Non-penetration runs in both passes; friction and rolling resistance only in the relax
/// pass. box2d: b2SolveContactsTask
fn solveWide(
    blocks: []WideConstraint,
    state: []const BodyState,
    motion: []Motion,
    inv_h: f32,
    contact_push_speed: f32,
    use_bias: bool,
) void {
    const inv_hW: FloatW = splatW(inv_h);
    const neg_pushW: FloatW = splatW(-contact_push_speed);
    const zeroW: FloatW = splatW(0.0);
    const oneW: FloatW = splatW(1.0);
    for (blocks) |*block| {
        var a: BodyStateW = gatherBodies(motion, state, block.index_a);
        var b: BodyStateW = gatherBodies(motion, state, block.index_b);
        const nx: FloatW = block.normal.x;
        const ny: FloatW = block.normal.y;
        const tx: FloatW = ny;
        const ty: FloatW = -nx;
        const dpx: FloatW = b.dpx - a.dpx;
        const dpy: FloatW = b.dpy - a.dpy;

        var total1: FloatW = zeroW;
        var total2: FloatW = zeroW;

        // Non-penetration, point 1.
        {
            const rax: FloatW = block.anchor_a1.x;
            const ray: FloatW = block.anchor_a1.y;
            const rbx: FloatW = block.anchor_b1.x;
            const rby: FloatW = block.anchor_b1.y;
            // Rotate anchors by the bodies' accumulated delta-rotations.
            const rotbx: FloatW = b.dqc * rbx - b.dqs * rby;
            const rotby: FloatW = b.dqs * rbx + b.dqc * rby;
            const rotax: FloatW = a.dqc * rax - a.dqs * ray;
            const rotay: FloatW = a.dqs * rax + a.dqc * ray;
            const dsx: FloatW = dpx + (rotbx - rotax);
            const dsy: FloatW = dpy + (rotby - rotay);
            const separation: FloatW = block.base_sep1 + dotW(dsx, dsy, nx, ny);

            const mask_s: MaskW = separation > zeroW;
            var velocity_bias: FloatW = undefined;
            var mass_scale: FloatW = undefined;
            var impulse_scale: FloatW = undefined;
            if (use_bias) {
                const soft: FloatW = @max(block.mass_scale * block.bias_rate * separation, neg_pushW);
                velocity_bias = @select(f32, mask_s, separation * inv_hW, soft);
                mass_scale = @select(f32, mask_s, oneW, block.mass_scale);
                impulse_scale = @select(f32, mask_s, zeroW, block.impulse_scale);
            } else {
                velocity_bias = @select(f32, mask_s, separation * inv_hW, zeroW);
                mass_scale = oneW;
                impulse_scale = zeroW;
            }

            const vrx: FloatW = (b.vx - block.anchor_b1.y * b.w) - (a.vx - block.anchor_a1.y * a.w);
            const vry: FloatW = (b.vy + block.anchor_b1.x * b.w) - (a.vy + block.anchor_a1.x * a.w);
            const normal_speed: FloatW = dotW(vrx, vry, nx, ny);

            var impulse: FloatW =
                -block.normal_mass1 * (mass_scale * normal_speed + velocity_bias) -
                impulse_scale * block.normal_impulse1;
            const new_impulse: FloatW = @max(block.normal_impulse1 + impulse, zeroW);
            impulse = new_impulse - block.normal_impulse1;
            block.normal_impulse1 = new_impulse;
            block.total_normal_impulse1 += impulse;
            total1 = new_impulse;

            const px: FloatW = nx * impulse;
            const py: FloatW = ny * impulse;
            a.vx -= block.inv_mass_a * px;
            a.vy -= block.inv_mass_a * py;
            a.w -= block.inv_inertia_a * crossW(rax, ray, px, py);
            b.vx += block.inv_mass_b * px;
            b.vy += block.inv_mass_b * py;
            b.w += block.inv_inertia_b * crossW(rbx, rby, px, py);
        }
        // Non-penetration, point 2.
        {
            const rax: FloatW = block.anchor_a2.x;
            const ray: FloatW = block.anchor_a2.y;
            const rbx: FloatW = block.anchor_b2.x;
            const rby: FloatW = block.anchor_b2.y;
            const rotbx: FloatW = b.dqc * rbx - b.dqs * rby;
            const rotby: FloatW = b.dqs * rbx + b.dqc * rby;
            const rotax: FloatW = a.dqc * rax - a.dqs * ray;
            const rotay: FloatW = a.dqs * rax + a.dqc * ray;
            const dsx: FloatW = dpx + (rotbx - rotax);
            const dsy: FloatW = dpy + (rotby - rotay);
            const separation: FloatW = block.base_sep2 + dotW(dsx, dsy, nx, ny);

            const mask_s: MaskW = separation > zeroW;
            var velocity_bias: FloatW = undefined;
            var mass_scale: FloatW = undefined;
            var impulse_scale: FloatW = undefined;
            if (use_bias) {
                const soft: FloatW = @max(block.mass_scale * block.bias_rate * separation, neg_pushW);
                velocity_bias = @select(f32, mask_s, separation * inv_hW, soft);
                mass_scale = @select(f32, mask_s, oneW, block.mass_scale);
                impulse_scale = @select(f32, mask_s, zeroW, block.impulse_scale);
            } else {
                velocity_bias = @select(f32, mask_s, separation * inv_hW, zeroW);
                mass_scale = oneW;
                impulse_scale = zeroW;
            }

            const vrx: FloatW = (b.vx - rby * b.w) - (a.vx - ray * a.w);
            const vry: FloatW = (b.vy + rbx * b.w) - (a.vy + rax * a.w);
            const normal_speed: FloatW = dotW(vrx, vry, nx, ny);

            var impulse: FloatW =
                -block.normal_mass2 * (mass_scale * normal_speed + velocity_bias) -
                impulse_scale * block.normal_impulse2;
            const new_impulse: FloatW = @max(block.normal_impulse2 + impulse, zeroW);
            impulse = new_impulse - block.normal_impulse2;
            block.normal_impulse2 = new_impulse;
            block.total_normal_impulse2 += impulse;
            total2 = new_impulse;

            const px: FloatW = nx * impulse;
            const py: FloatW = ny * impulse;
            a.vx -= block.inv_mass_a * px;
            a.vy -= block.inv_mass_a * py;
            a.w -= block.inv_inertia_a * crossW(rax, ray, px, py);
            b.vx += block.inv_mass_b * px;
            b.vy += block.inv_mass_b * py;
            b.w += block.inv_inertia_b * crossW(rbx, rby, px, py);
        }

        if (use_bias == false) {
            // Friction, point 1.
            {
                const rax: FloatW = block.anchor_a1.x;
                const ray: FloatW = block.anchor_a1.y;
                const rbx: FloatW = block.anchor_b1.x;
                const rby: FloatW = block.anchor_b1.y;
                const vrx: FloatW = (b.vx - rby * b.w) - (a.vx - ray * a.w);
                const vry: FloatW = (b.vy + rbx * b.w) - (a.vy + rax * a.w);
                const vt: FloatW = dotW(vrx, vry, tx, ty) - block.tangent_speed;
                var impulse: FloatW = block.tangent_mass1 * (-vt);
                const max_friction: FloatW = block.friction * block.normal_impulse1;
                const clamped: FloatW = @min(block.tangent_impulse1 + impulse, max_friction);
                const new_impulse: FloatW = @max(clamped, -max_friction);
                impulse = new_impulse - block.tangent_impulse1;
                block.tangent_impulse1 = new_impulse;
                const px: FloatW = tx * impulse;
                const py: FloatW = ty * impulse;
                a.vx -= block.inv_mass_a * px;
                a.vy -= block.inv_mass_a * py;
                a.w -= block.inv_inertia_a * crossW(rax, ray, px, py);
                b.vx += block.inv_mass_b * px;
                b.vy += block.inv_mass_b * py;
                b.w += block.inv_inertia_b * crossW(rbx, rby, px, py);
            }
            // Friction, point 2.
            {
                const rax: FloatW = block.anchor_a2.x;
                const ray: FloatW = block.anchor_a2.y;
                const rbx: FloatW = block.anchor_b2.x;
                const rby: FloatW = block.anchor_b2.y;
                const vrx: FloatW = (b.vx - rby * b.w) - (a.vx - ray * a.w);
                const vry: FloatW = (b.vy + rbx * b.w) - (a.vy + rax * a.w);
                const vt: FloatW = dotW(vrx, vry, tx, ty) - block.tangent_speed;
                var impulse: FloatW = block.tangent_mass2 * (-vt);
                const max_friction: FloatW = block.friction * block.normal_impulse2;
                const clamped: FloatW = @min(block.tangent_impulse2 + impulse, max_friction);
                const new_impulse: FloatW = @max(clamped, -max_friction);
                impulse = new_impulse - block.tangent_impulse2;
                block.tangent_impulse2 = new_impulse;
                const px: FloatW = tx * impulse;
                const py: FloatW = ty * impulse;
                a.vx -= block.inv_mass_a * px;
                a.vy -= block.inv_mass_a * py;
                a.w -= block.inv_inertia_a * crossW(rax, ray, px, py);
                b.vx += block.inv_mass_b * px;
                b.vy += block.inv_mass_b * py;
                b.w += block.inv_inertia_b * crossW(rbx, rby, px, py);
            }
            // Rolling resistance, capped by the accumulated normal impulse.
            const total_normal: FloatW = total1 + total2;
            var delta_lambda: FloatW = -block.rolling_mass * (b.w - a.w);
            const lambda: FloatW = block.rolling_impulse;
            const max_lambda: FloatW = block.rolling_resistance * total_normal;
            // Symmetric cap at +/- max_lambda. `clamp` applies the LOWER bound first where the old
            // `@max(@min(v, hi), lo)` applied the upper first; the two agree only while lo <= hi, so
            // this substitution rests on `max_lambda >= 0`. It holds: `rolling_resistance` is a
            // non-negative material property times a radius, and both accumulated normal impulses
            // are `@max(..., zeroW)` at the point they are stored.
            block.rolling_impulse = clamp(lambda + delta_lambda, -max_lambda, max_lambda);
            delta_lambda = block.rolling_impulse - lambda;
            a.w -= block.inv_inertia_a * delta_lambda;
            b.w += block.inv_inertia_b * delta_lambda;
        }

        scatterBodies(state, motion, block.index_a, a.vx, a.vy, a.w);
        scatterBodies(state, motion, block.index_b, b.vx, b.vy, b.w);
    }
}

/// Apply restitution once after the sub-step loop, four contacts wide. Lanes whose approach
/// was too slow or that never developed a normal impulse are masked out. box2d:
/// b2ApplyRestitutionTask
fn applyRestitutionWide(
    blocks: []WideConstraint,
    state: []const BodyState,
    motion: []Motion,
    threshold: f32,
) void {
    const zeroW: FloatW = splatW(0.0);
    const neg_thresholdW: FloatW = splatW(-threshold);
    for (blocks) |*wc| {
        // Skip blocks with no restitution in any lane (cheap early out preserves the scalar
        // "restitution == 0 -> continue" behaviour without per-lane harm otherwise).
        const any_restitution: bool = @reduce(.Or, wc.restitution > zeroW);
        if (any_restitution == false) {
            continue;
        }

        var a: BodyStateW = gatherBodies(motion, state, wc.index_a);
        var b: BodyStateW = gatherBodies(motion, state, wc.index_b);
        const nx: FloatW = wc.normal.x;
        const ny: FloatW = wc.normal.y;

        // Point 1.
        {
            const rax: FloatW = wc.anchor_a1.x;
            const ray: FloatW = wc.anchor_a1.y;
            const rbx: FloatW = wc.anchor_b1.x;
            const rby: FloatW = wc.anchor_b1.y;
            const vrx: FloatW = (b.vx - rby * b.w) - (a.vx - ray * a.w);
            const vry: FloatW = (b.vy + rbx * b.w) - (a.vy + rax * a.w);
            const vn: FloatW = dotW(vrx, vry, nx, ny);
            const raw: FloatW = -wc.normal_mass1 * (vn + wc.restitution * wc.rel_vel1);
            const new_impulse: FloatW = @max(wc.normal_impulse1 + raw, zeroW);
            var impulse: FloatW = new_impulse - wc.normal_impulse1;
            // Mask: only where approach was fast enough and a normal impulse exists.
            const active: MaskW = (wc.rel_vel1 < neg_thresholdW) & (wc.total_normal_impulse1 != zeroW) &
                (wc.restitution > zeroW);
            impulse = @select(f32, active, impulse, zeroW);
            wc.normal_impulse1 = @select(f32, active, new_impulse, wc.normal_impulse1);
            wc.total_normal_impulse1 += impulse;
            const px: FloatW = nx * impulse;
            const py: FloatW = ny * impulse;
            a.vx -= wc.inv_mass_a * px;
            a.vy -= wc.inv_mass_a * py;
            a.w -= wc.inv_inertia_a * crossW(rax, ray, px, py);
            b.vx += wc.inv_mass_b * px;
            b.vy += wc.inv_mass_b * py;
            b.w += wc.inv_inertia_b * crossW(rbx, rby, px, py);
        }
        // Point 2.
        {
            const rax: FloatW = wc.anchor_a2.x;
            const ray: FloatW = wc.anchor_a2.y;
            const rbx: FloatW = wc.anchor_b2.x;
            const rby: FloatW = wc.anchor_b2.y;
            const vrx: FloatW = (b.vx - rby * b.w) - (a.vx - ray * a.w);
            const vry: FloatW = (b.vy + rbx * b.w) - (a.vy + rax * a.w);
            const vn: FloatW = dotW(vrx, vry, nx, ny);
            const raw: FloatW = -wc.normal_mass2 * (vn + wc.restitution * wc.rel_vel2);
            const new_impulse: FloatW = @max(wc.normal_impulse2 + raw, zeroW);
            var impulse: FloatW = new_impulse - wc.normal_impulse2;
            const active: MaskW = (wc.rel_vel2 < neg_thresholdW) & (wc.total_normal_impulse2 != zeroW) &
                (wc.restitution > zeroW);
            impulse = @select(f32, active, impulse, zeroW);
            wc.normal_impulse2 = @select(f32, active, new_impulse, wc.normal_impulse2);
            wc.total_normal_impulse2 += impulse;
            const px: FloatW = nx * impulse;
            const py: FloatW = ny * impulse;
            a.vx -= wc.inv_mass_a * px;
            a.vy -= wc.inv_mass_a * py;
            a.w -= wc.inv_inertia_a * crossW(rax, ray, px, py);
            b.vx += wc.inv_mass_b * px;
            b.vy += wc.inv_mass_b * py;
            b.w += wc.inv_inertia_b * crossW(rbx, rby, px, py);
        }

        scatterBodies(state, motion, wc.index_a, a.vx, a.vy, a.w);
        scatterBodies(state, motion, wc.index_b, b.vx, b.vy, b.w);
    }
}

/// Write the wide blocks' solved impulses back into the scalar constraints so that
/// storeImpulses can persist them on the manifolds for next-step warm starting.
fn unpackWideImpulses(blocks: []const WideConstraint, constraints: []ContactConstraint) void {
    for (blocks) |*wc| {
        inline for (0..simd_width) |l| {
            const src: u32 = wc.source[l];
            if (src != null_index) {
                var con: *ContactConstraint = &constraints[src];
                con.points[0].normal_impulse = wc.normal_impulse1[l];
                con.points[0].tangent_impulse = wc.tangent_impulse1[l];
                con.points[0].total_normal_impulse = wc.total_normal_impulse1[l];
                if (con.count == 2) {
                    con.points[1].normal_impulse = wc.normal_impulse2[l];
                    con.points[1].tangent_impulse = wc.tangent_impulse2[l];
                    con.points[1].total_normal_impulse = wc.total_normal_impulse2[l];
                }
                con.rolling_impulse = wc.rolling_impulse[l];
            }
        }
    }
}

test "pulley joint conserves rope length and transfers load" {
    var world: World = try World.init(std.testing.allocator, 64);
    defer world.deinit(std.testing.allocator);
    world.settings.gravity = .{ 0, -10 };

    // Two boxes hang below two fixed ground anchors; B is much heavier than A.
    const ga: Vec2 = .{ -2, 30 };
    const gb: Vec2 = .{ 2, 30 };
    const a: BodyHandle = try createBody(&world, .{ .motion_type = .dynamic, .position = .{ -2, 5 } });
    _ = try createShape(&world, a, .{ .geom = .{ .polygon = makeBox(0.5, 0.5) }, .density = 1 });
    const b: BodyHandle = try createBody(&world, .{ .motion_type = .dynamic, .position = .{ 2, 5 } });
    _ = try createShape(&world, b, .{ .geom = .{ .polygon = makeBox(0.5, 0.5) }, .density = 6 });
    const ratio: f32 = 1.0;
    _ = try createPulleyJoint(&world, .{
        .base = .{ .body_a = a, .body_b = b },
        .ground_anchor_a = ga,
        .ground_anchor_b = gb,
        .ratio = ratio,
    });

    const segLen = struct {
        fn f(w: *const World, h: BodyHandle, g: Vec2) f32 {
            const p: Vec2 = getPosition(w, h);
            return length2(.{ p[0] - g[0], p[1] - g[1] });
        }
    }.f;
    const c0: f32 = segLen(&world, a, ga) + ratio * segLen(&world, b, gb);
    const ay0: f32 = getPosition(&world, a)[1];
    const by0: f32 = getPosition(&world, b)[1];

    // Release from rest: the heavier side B accelerates down and hauls A up. The frictionless
    // pulley is undamped so it then oscillates, hence we check the trajectory extremes rather
    // than the final pose. Throughout, the rope total must stay constant to tight tolerance.
    var min_by: f32 = by0;
    var max_ay: f32 = ay0;
    var max_sum_err: f32 = 0;
    var i: usize = 0;
    while (i < 90) : (i += 1) {
        try step(&world, 1.0 / 60.0);
        min_by = @min(min_by, getPosition(&world, b)[1]);
        max_ay = @max(max_ay, getPosition(&world, a)[1]);
        const sum: f32 = segLen(&world, a, ga) + ratio * segLen(&world, b, gb);
        max_sum_err = @max(max_sum_err, @abs(sum - c0));
    }

    // The rope is inextensible: lengthA + ratio*lengthB is conserved every step.
    try expect(max_sum_err < 0.05);
    // Load transferred: the heavy side fell and the light side was hauled up.
    try expect(min_by < by0 - 3.0);
    try expect(max_ay > ay0 + 3.0);
}

test "setShapeGeometry swaps geometry, refreshing mass and broad-phase proxy" {
    var world: World = try World.init(std.testing.allocator, 64);
    defer world.deinit(std.testing.allocator);
    world.settings.gravity = .{ 0, -10 };

    const ground: BodyHandle = try createBody(&world, .{ .motion_type = .static, .position = .{ 0, 0 } });
    _ = try createShape(&world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -10, 0 }, .point2 = .{ 10, 0 } } },
    });

    const body: BodyHandle = try createBody(&world, .{ .motion_type = .dynamic, .position = .{ 0, 5 } });
    const sh: ShapeHandle = try createShape(&world, body, .{
        .geom = .{ .circle = .{ .center = .{ 0, 0 }, .radius = 0.25 } },
        .density = 1,
    });
    const m_small: f32 = getMass(&world, body);

    // Grow the shape in place: mass is recomputed from the new (much larger) geometry.
    try setShapeGeometry(&world, sh, .{ .polygon = makeBox(1.0, 1.0) });
    const m_big: f32 = getMass(&world, body);
    try expect(m_big > m_small * 3.0);

    // The body still simulates after the swap - its moved proxy regenerates a contact, so it falls
    // and lands on the segment, settling near y~1 (the 1x1 box's half-height).
    var i: usize = 0;
    while (i < 240) : (i += 1) {
        try step(&world, 1.0 / 60.0);
    }
    const y: f32 = getPosition(&world, body)[1];
    try expect(y > 0.5);
    try expect(y < 1.5);
}

test "custom filter callback vetoes collision between opted-in shapes" {
    const Veto = struct {
        fn reject(a: u32, b: u32, ctx: ?*anyopaque) bool {
            _ = a;
            _ = b;
            _ = ctx;
            return false; // veto every pair this is consulted for
        }
    };
    var world: World = try World.init(std.testing.allocator, 64);
    defer world.deinit(std.testing.allocator);
    world.settings.gravity = .{ 0, -10 };
    setCustomFilterCallback(&world, Veto.reject, null);

    const ground: BodyHandle = try createBody(&world, .{ .motion_type = .static, .position = .{ 0, 0 } });
    _ = try createShape(&world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -10, 0 }, .point2 = .{ 10, 0 } } },
    });

    // The box opts into custom filtering; the callback vetoes its only pair (with the ground), so no
    // contact is ever created and it falls straight through.
    const faller: BodyHandle = try createBody(&world, .{ .motion_type = .dynamic, .position = .{ 0, 3 } });
    _ = try createShape(&world, faller, .{
        .geom = .{ .polygon = makeBox(0.5, 0.5) },
        .density = 1,
        .enable_custom_filtering = true,
    });

    var i: usize = 0;
    while (i < 120) : (i += 1) {
        try step(&world, 1.0 / 60.0);
    }
    try expect(getPosition(&world, faller)[1] < -2.0);
}

test "pre-solve one-way platform passes a rising body and catches a falling one" {
    const OneWay = struct {
        const plat_tag: u64 = 1;
        const body_tag: u64 = 2;
        fn presolve(
            a: u32,
            b: u32,
            p: Vec2,
            n: Vec2,
            ctx: ?*anyopaque,
        ) bool {
            _ = p;
            const w: *World = @ptrCast(@alignCast(ctx.?));
            const ua: u64 = w.shapes.data[a].user_data;
            const ub: u64 = w.shapes.data[b].user_data;
            var sign: f32 = 0;
            if (ua == plat_tag and ub == body_tag) {
                sign = 1.0;
            } else if (ub == plat_tag and ua == body_tag) {
                sign = -1.0;
            } else {
                return true;
            }
            return sign * n[1] > 0.95;
        }
    };
    var world: World = try World.init(std.testing.allocator, 64);
    defer world.deinit(std.testing.allocator);
    world.settings.gravity = .{ 0, -10 };
    setPreSolveCallback(&world, OneWay.presolve, &world);

    const plat: BodyHandle = try createBody(&world, .{ .motion_type = .static, .position = .{ 0, 5 } });
    _ = try createShape(&world, plat, .{
        .geom = .{ .polygon = makeBox(3.0, 0.25) },
        .enable_pre_solve = true,
        .user_data = OneWay.plat_tag,
    });

    // Launched up from below: it passes through the platform instead of bouncing off the underside.
    const mover: BodyHandle = try createBody(&world, .{
        .motion_type = .dynamic,
        .position = .{ 0, 2 },
        .linear_velocity = .{ 0, 20 },
    });
    _ = try createShape(&world, mover, .{
        .geom = .{ .polygon = makeBox(0.4, 0.4) },
        .enable_pre_solve = true,
        .user_data = OneWay.body_tag,
    });

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try step(&world, 1.0 / 60.0);
    }
    try expect(getPosition(&world, mover)[1] > 5.3); // climbed above the platform top

    // Falling back, it now lands ON the platform (normal points up) and settles just above its top.
    while (i < 300) : (i += 1) {
        try step(&world, 1.0 / 60.0);
    }
    const yf: f32 = getPosition(&world, mover)[1];
    try expect(yf > 5.3);
    try expect(yf < 6.2);
}

test "deferred mass defers the mass solve to applyMassFromShapes" {
    var world: World = try World.init(std.testing.allocator, 64);
    defer world.deinit(std.testing.allocator);

    const centers = [_]Vec2{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };

    // Compound body assembled with the mass solve deferred on every shape.
    const body: BodyHandle = try createBody(&world, .{ .motion_type = .dynamic, .position = .{ 0, 0 } });
    for (centers) |cen| {
        _ = try createShape(&world, body, .{
            .geom = .{ .polygon = makeOffsetBox(0.5, 0.5, cen, Rot2.identity) },
            .density = 1,
            .update_body_mass = false,
        });
    }
    try expect(getMass(&world, body) < 0.001); // not yet recomputed

    applyMassFromShapes(&world, body);
    const m: f32 = getMass(&world, body);
    try expect(m > 3.9 and m < 4.1); // four unit-area boxes at density 1

    // The same compound built with the default (per-shape) update yields the same mass.
    const body2: BodyHandle = try createBody(&world, .{ .motion_type = .dynamic, .position = .{ 10, 0 } });
    for (centers) |cen| {
        _ = try createShape(&world, body2, .{
            .geom = .{ .polygon = makeOffsetBox(0.5, 0.5, cen, Rot2.identity) },
            .density = 1,
        });
    }
    try expect(@abs(getMass(&world, body2) - m) < 0.001);
}

test "getContactData reports a live touching contact's manifold" {
    var world: World = try World.init(std.testing.allocator, 64);
    defer world.deinit(std.testing.allocator);
    world.settings.gravity = .{ 0, -10 };

    const ground: BodyHandle = try createBody(&world, .{ .motion_type = .static, .position = .{ 0, 0 } });
    _ = try createShape(&world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -10, 0 }, .point2 = .{ 10, 0 } } },
    });
    const ball: BodyHandle = try createBody(&world, .{
        .motion_type = .dynamic,
        .position = .{ 0, 1 },
        .enable_sleep = false,
    });
    _ = try createShape(&world, ball, .{
        .geom = .{ .circle = .{ .center = .{ 0, 0 }, .radius = 0.5 } },
        .density = 1,
    });

    var i: usize = 0;
    while (i < 120) : (i += 1) {
        try step(&world, 1.0 / 60.0);
    }

    var found: bool = false;
    var ci: u32 = 0;
    while (ci < liveContactCount(&world)) : (ci += 1) {
        const cid: u32 = liveContactId(&world, ci);
        if (isContactTouching(&world, cid) == false) {
            continue;
        }
        const data: ContactData = getContactData(&world, cid);
        try expect(data.point_count >= 1);
        try expect(@abs(data.points[0].point[1]) < 0.2); // contact near the ground line y~0
        try expect(@abs(data.normal[1]) > 0.9); // vertical normal on flat ground
        try expect(data.points[0].normal_impulse > 0.0); // supporting the ball's weight
        found = true;
    }
    try expect(found);
}

test "PairSet matches a reference set under heavy random churn" {
    const gpa: Allocator = std.heap.page_allocator;
    var set: PairSet = .{};
    defer set.deinit(gpa);
    var ref: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer ref.deinit(gpa);
    var live: std.ArrayListUnmanaged(u64) = .empty;
    defer live.deinit(gpa);

    var rng: u64 = 0xC0FFEE123;
    var op: u32 = 0;
    while (op < 300000) : (op += 1) {
        rng = rng *% 6364136223846793005 +% 1442695040888963407;
        const roll: u32 = @truncate(rng >> 40);
        if (roll % 100 < 55 or live.items.len == 0) {
            // Small key space forces collisions, reuse, and long probe runs.
            const a: u32 = @as(u32, @truncate(rng >> 17)) % 500;
            const b: u32 = @as(u32, @truncate(rng >> 33)) % 500;
            if (a == b) {
                continue;
            }
            const key: u64 = shapePairKey(a, b);
            const had: bool = ref.contains(key);
            try set.put(gpa, key);
            if (!had) {
                try ref.put(gpa, key, {});
                try live.append(gpa, key);
            }
            try expect(set.contains(key));
        } else {
            const idx: usize = @as(usize, @truncate(rng >> 20)) % live.items.len;
            const key: u64 = live.swapRemove(idx);
            set.remove(key);
            _ = ref.remove(key);
            try expect(!set.contains(key));
        }
        if (op % 2000 == 0) {
            try expect(set.count == @as(u32, @intCast(ref.count())));
        }
    }
    try expect(set.count == @as(u32, @intCast(ref.count())));
    var it: std.AutoHashMapUnmanaged(u64, void).KeyIterator = ref.keyIterator();
    while (it.next()) |k| {
        try expect(set.contains(k.*));
    }
}

test "settled bodies fall asleep (covers the island sleep-eligible path)" {
    const gpa: Allocator = std.heap.page_allocator;
    var world: World = try World.init(gpa, 64);
    defer world.deinit(gpa);
    world.settings.gravity = .{ 0, -10 };

    const ground: BodyHandle = try createBody(&world, .{ .motion_type = .static, .position = .{ 0, 0 } });
    _ = try createShape(&world, ground, .{ .geom = .{ .segment = .{ .point1 = .{ -10, 0 }, .point2 = .{ 10, 0 } } } });

    var b: [3]BodyHandle = undefined;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const fi: f32 = float(i);
        b[i] = try createBody(&world, .{ .motion_type = .dynamic, .position = .{ -3 + fi * 3, 0.5 } });
        _ = try createShape(&world, b[i], .{ .geom = .{ .polygon = makeBox(0.5, 0.5) }, .density = 1 });
    }

    const dt: f32 = 1.0 / 60.0;
    var s: u32 = 0;
    while (s < 300) : (s += 1) {
        try step(&world, dt);
    }

    var asleep_count: u32 = 0;
    i = 0;
    while (i < 3) : (i += 1) {
        if (world.bodies.data[b[i].index()].asleep) {
            asleep_count += 1;
        }
    }
    try expect(asleep_count == 3); // all settled -> the eligible union-find + aggregate path ran
}
