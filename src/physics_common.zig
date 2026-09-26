//! lint:alias physics_common
//! Shared, dimension-independent contract for the two physics engines - `zimrphysics`
//! (3D / Jolt port) and `zimrphysics2d` (2D / Box2D v3 port). Defining the genuinely
//! parallel parts here, and asserting the parallel surface at comptime, is what keeps the
//! two engines feeling like one family rather than re-diverging over time: a developer who
//! learns one can predict the other. See the engine compatibility plan for the full map of
//! what is (and deliberately is not) unified.

/// How a body participates in simulation. Shared verbatim by both engines (Jolt's
/// `EMotionType`, Box2D's `b2BodyType`): `.static` never moves, `.kinematic` is moved by
/// the application and ignores forces, `.dynamic` is fully simulated.
pub const MotionType = enum(u8) { static, kinematic, dynamic };

/// Collision-detection quality. `.discrete` integrates straight through (leaning on
/// speculative contacts for moderate speeds); `.linear_cast` sweeps the body each step so a
/// fast one cannot tunnel through thin geometry. Jolt's `EMotionQuality` / Box2D's bullet flag.
pub const MotionQuality = enum(u8) { discrete, linear_cast };

/// Comptime conformance check. Fails to compile if either engine drops a name the
/// cross-engine contract requires, or lets a shared enum drift from this module. Call it
/// from a site that imports both engines (zimr.zig) so the invariant is enforced on every
/// build, not just by convention.
pub fn assertParallelEngines(comptime E2: type, comptime E3: type) void {
    // Decls that must exist with the same name and a parallel role on both engines. As more
    // of the harmonization plan lands (createBody, BodyHandle, the joint family, step shape),
    // add the newly-parallel names here so they can never silently re-diverge.
    const required: [13][]const u8 = .{
        "World",
        "Settings",
        "MotionType",
        "MotionQuality",
        "createBody",
        "createRevoluteJoint",
        "createPrismaticJoint",
        "createWeldJoint",
        "createDistanceJoint",
        "step",
        "overlapAabb",
        "castRayClosest",
        "castShapeClosest",
    };
    inline for (required) |name| {
        if (!@hasDecl(E2, name)) {
            @compileError("zimrphysics2d is missing the parallel decl '" ++ name ++ "'");
        }
        if (!@hasDecl(E3, name)) {
            @compileError("zimrphysics is missing the parallel decl '" ++ name ++ "'");
        }
    }
    // The shared enums must be exactly this module's types (one source of truth).
    if (E2.MotionType != MotionType or E3.MotionType != MotionType) {
        @compileError("MotionType has diverged from physics_common");
    }
    if (E2.MotionQuality != MotionQuality or E3.MotionQuality != MotionQuality) {
        @compileError("MotionQuality has diverged from physics_common");
    }
}
