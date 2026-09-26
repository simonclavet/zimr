//! robot_urdf.zig - load a URDF into a live `robot.Model`.
//!
//! The runtime half of section 4i-quater's split:
//!
//!   * **codegen** (`urdf.emitZig` + `zig build urdf-import`) for robots the program is
//!     WRITTEN AGAINST - comptime validation and generated name enums;
//!   * **this file** for robots the program is HANDED - a file chosen at startup, dropped in
//!     by a user, or picked from a menu.
//!
//! Neither is a rewrite of the other. Both consume `urdf.Robot`, the single semantic
//! representation, and both end at `robot.buildFromSpec` - there is exactly ONE piece of
//! code that knows how to turn a description into index tables, which is what keeps the two
//! paths from drifting.
//!
//! A separate file, like `robot_physics.zig`, so `robot.zig` depends only on zimrmath and a
//! headless rollout does not drag an XML parser along.
//!
//! -- WHAT YOU GIVE UP BY LOADING AT RUNTIME --
//!
//! The generated name enums, so `model.jointIndex("shoulder")`-style lookups replace
//! `Kuka.Joint.shoulder`. And `Spec()`'s compile errors become ordinary errors, which is not
//! really a loss - a robot arriving at startup cannot be checked before the program is
//! built, so an error is the only honest answer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const rbt = @import("robot.zig");
const urdf = @import("urdf.zig");

const zm = @import("zm");
const allocPrint = std.fmt.allocPrint;
const float = zm.float;
const Vec = zm.Vec;
const splat = zm.splat;

pub const Error = error{
    /// A `<mimic>` with a nonzero offset. A fixed tendon is linear, not affine - the same
    /// refusal the emitter makes, for the same reason.
    MimicOffsetUnsupported,
} || rbt.BuildError;

/// Rotor inertia the importer supplies, since URDF describes the mechanism and not the
/// gearbox. Matches the emitter's default so both paths produce the same model.
pub const default_armature: f32 = 0.01;

/// Build a live model from a parsed URDF.
///
/// The returned `Model` owns its memory and is freed with `deinit`, exactly as one built
/// from a comptime spec. The `ModelSpec` assembled here is scratch: `buildFromSpec` copies
/// everything it needs into the model's own arena, so the spec can be freed on return.
pub fn buildModel(
    gpa: Allocator,
    robot: *const urdf.Robot,
    options: rbt.Options,
) Error!rbt.Model {
    // Scratch for the spec. Freed before returning - the model does not alias it.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a: Allocator = scratch.allocator();

    var bodies: []rbt.BodySpec = try a.alloc(rbt.BodySpec, robot.bodies.len);
    var tendons: std.ArrayListUnmanaged(rbt.TendonSpec) = .empty;

    for (robot.bodies, 0..) |body, i| {
        // A URDF `fixed` joint arrives as no joint at all, so an empty slice is the whole
        // representation of a weld - zero degrees of freedom, structurally.
        var joints: []rbt.JointSpec = &.{};
        if (body.joint) |joint| {
            joints = try a.alloc(rbt.JointSpec, 1);
            joints[0] = .{
                .name = joint.name,
                .kind = switch (joint.kind) {
                    .hinge, .continuous => .hinge,
                    .slide => .slide,
                    .free => .free,
                    .fixed => unreachable, // `urdf.zig` never produces a joint for these
                },
                .axis = joint.axis,
                .range = joint.limit,
                .damping = joint.damping,
                .armature = default_armature,
            };

            // A mimic is a fixed tendon: `q_follower = multiplier * q_driver` rearranges to
            // coefficients `(1, -multiplier)` summing to zero.
            if (joint.mimic) |mimic| {
                if (mimic.offset != 0.0) {
                    return Error.MimicOffsetUnsupported;
                }
                const pair: []rbt.TendonJoint = try a.alloc(rbt.TendonJoint, 2);
                pair[0] = .{ .name = joint.name, .coefficient = 1 };
                pair[1] = .{ .name = mimic.joint, .coefficient = -mimic.multiplier };
                try tendons.append(a, .{
                    .name = try allocPrint(a, "{s}_mimic", .{joint.name}),
                    .joints = pair,
                });
            }
        }

        // Mesh geoms are skipped - the same omission the emitter makes, and the caller can
        // count them with `urdf.meshCount` to report it.
        var geoms: std.ArrayListUnmanaged(rbt.GeomSpec) = .empty;
        for (body.geoms) |geom| {
            const shape: rbt.GeomShape = switch (geom.shape) {
                .box => |half| .{ .box = .{ .half_extent = half } },
                .cylinder => |c| .{ .cylinder = .{ .half_height = c.half_height, .radius = c.radius } },
                .sphere => |radius| .{ .sphere = .{ .radius = radius } },
                // A mesh that was resolved by `urdf.resolveMeshes` arrives as a hull; one
                // that was not is skipped, exactly as the emitter skips it.
                .hull => |points| .{ .hull = .{
                    .points = points,
                    .bounds_half_extent = boundsHalfExtent(points),
                } },
                .mesh => continue,
            };
            try geoms.append(a, .{
                .shape = shape,
                .pos = geom.pos,
                .rot = geom.rot,
                // Mass comes from the <inertial> when there is one; a geom that also
                // contributed would make the body several times too heavy.
                .mass = if (body.inertial != null) 0 else null,
            });
        }

        bodies[i] = .{
            .name = body.name,
            .parent = if (body.parent) |parent| robot.bodies[parent].name else null,
            .pos = body.pos,
            .rot = body.rot,
            .joints = joints,
            .geoms = try geoms.toOwnedSlice(a),
            .inertial = if (body.inertial) |inertial| .{
                .mass = inertial.mass,
                .pos = inertial.pos,
                .full_inertia = inertial.full_inertia,
            } else null,
        };
    }

    return rbt.buildRuntime(gpa, .{
        .bodies = bodies,
        .tendons = try tendons.toOwnedSlice(a),
        .options = options,
    });
}

/// Half the extent of a point cloud's axis-aligned bounding box.
///
/// The hull's mass properties come from this box rather than its true volume - an
/// overestimate, which is the safe direction, and moot for any URDF that states
/// `<inertial>`. See the note on `robot.GeomShape.hull`.
fn boundsHalfExtent(points: []const Vec) Vec {
    var lo: Vec = points[0];
    var hi: Vec = points[0];
    for (points) |p| {
        lo = @min(lo, p);
        hi = @max(hi, p);
    }
    return (hi - lo) * splat(0.5);
}

// =============================================================================
// Tests
// =============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "runtime load: the KUKA loaded at runtime matches the generated one" {
    // ** THE PROPERTY THAT MAKES TWO PATHS SAFE.
    //
    // Codegen and runtime loading are two backends on one semantic layer, and the whole
    // argument for keeping both is that they cannot disagree. This asserts it: the SAME
    // URDF, built both ways, must produce models that are identical where it counts -
    // same DOF count, same masses, same inertias, same tree, and the same acceleration
    // from the same state.
    //
    // Without this the two paths would drift the moment one gained a field the other
    // missed, and the drift would show up as a robot that behaves differently depending on
    // how it was loaded, which is close to undebuggable.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/kuka_iiwa.urdf");

    var robot: urdf.Robot = try urdf.parse(gpa, source, null);
    defer robot.deinit();
    var loaded: rbt.Model = try buildModel(gpa, &robot, .{});
    defer loaded.deinit();

    const generated = @import("tests/fixtures/robot/kuka_iiwa.zig");
    var built: rbt.Model = try generated.Model.build(gpa);
    defer built.deinit();

    try expectEqual(built.nv, loaded.nv);
    try expectEqual(built.nq, loaded.nq);
    try expectEqual(built.nbody, loaded.nbody);
    try expectEqual(built.njnt, loaded.njnt);

    for (0..built.nbody) |bi| {
        try expectEqual(built.body_parent[bi], loaded.body_parent[bi]);
        try expectApproxEqAbs(built.body_mass[bi], loaded.body_mass[bi], 1.0e-5);
        inline for (0..3) |k| {
            try expectApproxEqAbs(built.body_pos[bi][k], loaded.body_pos[bi][k], 1.0e-5);
            try expectApproxEqAbs(built.body_ipos[bi][k], loaded.body_ipos[bi][k], 1.0e-5);
            try expectApproxEqAbs(
                built.body_inertia[bi].diag[k],
                loaded.body_inertia[bi].diag[k],
                1.0e-6,
            );
        }
    }

    // And the dynamics agree, which is the check that would catch a difference in something
    // the field-by-field comparison above does not reach.
    var da: rbt.Data = try rbt.Data.init(gpa, &built);
    defer da.deinit();
    var db: rbt.Data = try rbt.Data.init(gpa, &loaded);
    defer db.deinit();
    for (0..built.nv) |i| {
        const angle: f32 = 0.3 + 0.1 * float(i);
        da.pos[i] = angle;
        db.pos[i] = angle;
    }
    rbt.forward(&built, &da);
    rbt.forward(&loaded, &db);
    for (0..built.nv) |i| {
        try expectApproxEqAbs(da.acc[i], db.acc[i], 1.0e-3);
    }
}

test "runtime load: a loaded model simulates like any other" {
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/kuka_iiwa.urdf");
    var robot: urdf.Robot = try urdf.parse(gpa, source, null);
    defer robot.deinit();
    var model: rbt.Model = try buildModel(gpa, &robot, .{ .timestep = 1.0 / 240.0 });
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    try expectEqual(@as(u32, 7), model.nv);
    // Mesh collision geometry is skipped by both paths, so a URDF whose every collision
    // shape is a mesh loads with none - and the caller is expected to say so.
    try expectEqual(@as(u32, 0), model.ngeom);
    try expect(urdf.meshCount(&robot) > 0);

    data.pos[1] = 0.6;
    data.pos[3] = -0.9;
    for (0..1200) |_| {
        rbt.step(&model, &data);
    }
    rbt.forward(&model, &data);
    for (0..model.nv) |i| {
        try expect(data.vel[i] == data.vel[i]); // no NaN
        try expect(@abs(data.vel[i]) < 1.0e3); // and bounded
    }
}

// ============================================================================
// Tests that run robot.zig against the generated KUKA model.
// ============================================================================
//
// They live here rather than beside the code they test because the fixture is generated as an
// `rbt.ModelSpec` literal: it imports robot.zig, so robot.zig importing it back was a cycle - the
// last one the `import-cycle` lint rule allowed. This file already depends on both. The cost is
// that `zig build zn-robot` no longer runs them; `zn-robot_urdf` and `test-fast` do.

test "warm start: a bad warm start is thrown away, not fought" {
    // * THE GUARD MUJOCO HAS AND MY FIRST VERSION DID NOT.
    //
    // PGS minimises `cost(f) = 1/2f^T(A+R)f - f^T(aref - a_free)` subject to `f >= 0`, and
    // `cost(0) = 0` identically. A warm force with POSITIVE cost is therefore worse than no
    // warm start at all, and the solver would spend its iterations undoing it.
    //
    // -- WHY THIS ASSERTS THE FLAG AND NOT AN ITERATION COUNT --
    //
    // Measured on the KUKA against five limits: a poisoned warm start takes 29 iterations
    // with the guard and 43 without; a large velocity kick takes 1 with and 2 without. The
    // guard is worth having. But pinning "29" would break on any legitimate solver change,
    // so the test asserts the MECHANISM fired instead.
    //
    // A single-row model would not do: with one row PGS reaches the exact answer in one
    // iteration whatever it starts from, so a bad start costs nothing and the guard looks
    // pointless. It takes a coupled set to show the difference - which is itself worth
    // knowing about testing solvers.
    const gpa: Allocator = std.testing.allocator;
    const kuka = @import("tests/fixtures/robot/kuka_iiwa.zig");
    var m: rbt.Model = try kuka.Model.build(gpa);
    defer m.deinit();
    for (0..m.njnt) |ji| {
        m.jnt_range[ji] = .{ -0.05, 0.05 };
    }
    var d: rbt.Data = try rbt.Data.init(gpa, &m);
    defer d.deinit();

    // Settle against the limits so a healthy warm start exists on several coupled rows.
    for (0..m.nv) |i| {
        d.pos[i] = 0.3;
    }
    for (0..600) |_| {
        rbt.step(&m, &d);
    }
    try expect(d.constraint_count > 1);
    try expect(!d.warm_start_rejected); // a settled solve's own answer is a good start

    // Poison it: forces a thousand times too large, on keys the matcher will happily find.
    for (0..d.warm_count) |w| {
        d.warm_force[w] *= 1000.0;
    }
    rbt.step(&m, &d);
    try expect(d.warm_start_rejected);

    // And it recovers: still resting against the limits, not launched.
    rbt.forward(&m, &d);
    for (0..m.nv) |i| {
        try expect(d.pos[i] == d.pos[i]); // no NaN
        try expect(@abs(d.vel[i]) < 50.0);
    }
}

test "import: the generated KUKA model builds and simulates" {
    // ** THE WHOLE IMPORT PATH, END TO END, AS A COMPILE-TIME FACT.
    //
    // This file was produced by `zig build urdf-import` from a real URDF that somebody else
    // wrote. Merely IMPORTING it runs `Spec()` over the result - so every validation rule
    // in this engine is applied to the importer's output at compile time, and a convention
    // regression becomes a build failure naming the body rather than a wrong number nobody
    // notices.
    //
    // That is the payoff for section 4i-ter's decision to generate source rather than build a
    // model at runtime: the type system checks the importer's homework.
    const kuka = @import("tests/fixtures/robot/kuka_iiwa.zig");
    const gpa: Allocator = std.testing.allocator;
    var m: rbt.Model = try kuka.Model.build(gpa);
    defer m.deinit();
    var d: rbt.Data = try rbt.Data.init(gpa, &m);
    defer d.deinit();

    // A seven-axis arm: 8 bodies (world + 8 links means nbody 9), 7 hinges, 7 DOFs.
    try expectEqual(@as(u32, 7), m.nv);
    try expectEqual(@as(u32, 7), m.nq);
    try expectEqual(@as(u32, 9), m.nbody);

    // * Eight collision hulls, one per link, from the URDF's `<collision><mesh>` elements.
    // This assertion used to read `ngeom == 0` - the meshes were skipped, and the model
    // could be simulated but could not touch anything.
    try expectEqual(@as(u32, 8), m.ngeom);

    // And the mass still comes from `<inertial>`, NOT from those hulls - the geoms carry
    // `mass = 0` precisely so a link is not counted twice. The total below is the check
    // that would catch it: geom-derived mass would make this arm several times too heavy.
    var total_mass: f32 = 0;
    for (1..m.nbody) |bi| {
        total_mass += m.body_mass[bi];
    }
    // A real iiwa weighs about 24 kg; the URDF's inertials should land near that.
    try expect(total_mass > 10.0);
    try expect(total_mass < 60.0);

    // * And it SIMULATES. The mass matrix must be positive definite and well conditioned -
    // the property that a mis-transcribed inertia, a lost armature or a wrong frame would
    // each break in a different way.
    d.pos[1] = 0.6;
    d.pos[3] = -0.9;
    rbt.forward(&m, &d);
    try expect(rbt.conditionEstimate(&m, &d) < 1.0e7);
    for (0..m.nv) |i| {
        try expect(d.acc[i] == d.acc[i]); // no NaN anywhere
    }

    // Gravity acts along -Y after the Z-up conversion, so an arm posed off-vertical must
    // accelerate. If the conversion were skipped the arm would lie in the X-Y plane with
    // gravity along its own axis and barely move.
    var gravity_response: f32 = 0;
    for (0..m.nv) |i| {
        gravity_response += @abs(d.acc[i]);
    }
    try expect(gravity_response > 0.5);

    // Ten seconds of swinging without diverging: the integrator, the conditioning and the
    // inertias all have to be right together for this to hold.
    for (0..2400) |_| {
        rbt.step(&m, &d);
    }
    rbt.forward(&m, &d);
    for (0..m.nv) |i| {
        try expect(@abs(d.vel[i]) < 1.0e3);
    }
}

test "*** applied_force persists across step, and a ctrl-driven controller inherits it" {
    // -- THE REGRESSION THIS PINS --
    //
    // `applied_force` is persistent and `step` adds it to whatever the actuators produce. A
    // controller that drives `ctrl` and never writes here therefore inherits the last writer's
    // torques - silently, and for as long as it runs.
    //
    // * THIS IS NOT A BUG IN `step`; it is a contract that was undocumented. The test exists so
    // the contract has a witness: if someone later makes `step` clear the array, this fails and
    // they find out that steady external forces (wind, a tether) depended on persistence. If
    // someone relies on it NOT persisting, the doc comment above now says otherwise.
    const gpa: Allocator = std.testing.allocator;
    var model: rbt.Model = try rbt.buildRuntime(gpa, @import("tests/fixtures/robot/kuka_iiwa.zig").spec);
    defer model.deinit();
    var d: rbt.Data = try rbt.Data.init(gpa, &model);
    defer d.deinit();
    @memcpy(d.pos, model.qpos0);
    @memset(d.vel, 0);
    rbt.forward(&model, &d);

    // One writer leaves a torque behind, exactly as a servo's last tick would.
    const dof: u32 = model.jnt_dof_adr[0];
    d.applied_force[dof] = 25.0;
    rbt.step(&model, &d);

    // * IT IS STILL THERE. That is the whole finding, in one assertion.
    try expectApproxEqAbs(@as(f32, 25.0), d.applied_force[dof], 1.0e-6);

    // And it keeps acting: a second step with nobody writing anything still accelerates the
    // joint in the same direction.
    const before: f32 = d.vel[dof];
    rbt.step(&model, &d);
    try expect(d.vel[dof] > before);

    // Clearing it is the caller's job, and it works.
    @memset(d.applied_force, 0);
    @memset(d.vel, 0);
    const settled: f32 = d.vel[dof];
    rbt.step(&model, &d);
    try expectApproxEqAbs(settled, d.vel[dof], 1.0e-3);
}
