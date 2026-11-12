//! robotgpu_tests.zig - the tests of robotgpu.zig, a test-fast root importing it by path. Every test takes its counts
//! from three real robots (`Fixtures`), and packing is checked through the accessors the kernels use, on the CPU
//! twin's own arenas.

const std = @import("std");
const robot = @import("robot");
const zm = @import("zm");
/// The MJCF importer, as a module: its own tests stay in its own roots.
const robot_import = @import("robot_import");
const robotgpu = @import("robotgpu.zig");
const kuka = @import("tests/fixtures/robot/kuka_iiwa.zig");

const Allocator = std.mem.Allocator;
const Wyhash = std.hash.Wyhash;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const sliceAsBytes = std.mem.sliceAsBytes;
const sortSlice = std.mem.sort;
const vec = zm.vec;
const Vec = zm.Vec;
const float = zm.float;

const humanoid_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
const geno_xml: []const u8 = @embedFile("tests/fixtures/robot/geno.xml");
const go1_xml: []const u8 = @embedFile("tests/fixtures/robot/go1/go1.xml");

/// THE SIMPLE MODELS, each isolating one mechanism of the step: a single pendulum (one hinge), a double pendulum (a
/// hinge whose axis the first one's motion carries), a free body (a box with a free joint, an asymmetric inertia
/// tumbling under gravity - the quaternion turned by its angular velocity), and a ball chain (three ball joints).
const single_pendulum_xml =
    \\<mujoco><worldbody>
    \\  <body pos="0 0 1">
    \\    <joint type="hinge" axis="0 1 0"/>
    \\    <geom type="sphere" size=".1" pos="0 0 -.5"/>
    \\  </body>
    \\</worldbody></mujoco>
;
const double_pendulum_xml =
    \\<mujoco><worldbody>
    \\  <body pos="0 0 2">
    \\    <joint type="hinge" axis="0 1 0"/>
    \\    <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".05"/>
    \\    <body pos="0 0 -.5">
    \\      <joint type="hinge" axis="1 0 0"/>
    \\      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".05"/>
    \\    </body>
    \\  </body>
    \\</worldbody></mujoco>
;
const free_body_xml =
    \\<mujoco><worldbody>
    \\  <body pos="0 0 1">
    \\    <joint type="free"/>
    \\    <geom type="box" size=".1 .2 .3"/>
    \\  </body>
    \\</worldbody></mujoco>
;
const ball_chain_xml =
    \\<mujoco><worldbody>
    \\  <body pos="0 0 2">
    \\    <joint type="ball"/>
    \\    <geom type="capsule" fromto="0 0 0 .3 0 -.3" size=".05"/>
    \\    <body pos=".3 0 -.3">
    \\      <joint type="ball"/>
    \\      <geom type="capsule" fromto="0 0 0 0 .3 -.3" size=".05"/>
    \\      <body pos="0 .3 -.3">
    \\        <joint type="ball"/>
    \\        <geom type="box" size=".05 .1 .15"/>
    \\      </body>
    \\    </body>
    \\  </body>
    \\</worldbody></mujoco>
;

/// A robot from an MJCF fixture, through the importer the robot family uses.
fn modelFromMjcf(gpa: Allocator, source: []const u8) !robot_import.Imported {
    const options: robot.Options = .{
        .max_contacts = 128,
        .timestep = 1.0 / 500.0,
        .gravity = vec(0, 0, -9.81),
    };
    return robot_import.importSource(gpa, source, options);
}

/// THE TWIN, RUN DIRECTLY (`robotgpu.CpuTwin`): a model's worlds in the twin's own arenas, each kernel called once per
/// invocation, in order.
const Twin = robotgpu.CpuTwin;

/// THE THREE ROBOTS every test takes its counts from, each built from its own file: the KUKA iiwa (its spec, seven
/// hinges on one chain), a MuJoCo humanoid and Geno (their MJCF, through the importer).
const Fixtures = struct {
    kuka: robot.Model,
    humanoid: robot_import.Imported,
    geno: robot_import.Imported,

    fn load(gpa: Allocator) !Fixtures {
        var kuka_model: robot.Model = try kuka.Model.build(gpa);
        errdefer kuka_model.deinit();
        var humanoid: robot_import.Imported = try modelFromMjcf(gpa, humanoid_xml);
        errdefer humanoid.deinit();
        const geno: robot_import.Imported = try modelFromMjcf(gpa, geno_xml);
        const fixtures: Fixtures = .{ .kuka = kuka_model, .humanoid = humanoid, .geno = geno };
        return fixtures;
    }

    fn deinit(fixtures: *Fixtures) void {
        fixtures.kuka.deinit();
        fixtures.humanoid.deinit();
        fixtures.geno.deinit();
    }

    /// The three models, the KUKA first.
    fn models(fixtures: *const Fixtures) [3]*const robot.Model {
        const all: [3]*const robot.Model = .{ &fixtures.kuka, &fixtures.humanoid.model, &fixtures.geno.model };
        return all;
    }
};

/// One array's numbers in its arena, from `start` up to `end`, for the overlap checks.
const Span = struct {
    start: u64,
    end: u64,

    fn before(_: void, left: Span, right: Span) bool {
        return left.start < right.start;
    }
};

/// Every span 4-float aligned, inside `capacity`, and clear of the others.
fn expectSpansFit(spans: []Span, capacity: u64) !void {
    for (spans) |span| {
        try expect(span.start % 4 == 0);
        try expect(span.end <= capacity);
    }
    sortSlice(Span, spans, {}, Span.before);
    for (spans[0 .. spans.len - 1], spans[1..]) |earlier, later| {
        try expect(earlier.end <= later.start);
    }
}

/// ONE ARENA'S LAYOUT: every array's stride a multiple of four holding its live numbers, and every array's blocks -
/// one per world for a per-world array, one for a model table - aligned, inside the arena's `capacity` and clear of
/// the other arrays' blocks.
fn expectArenaLayout(
    comptime ArenaLayout: type,
    arena_layout: ArenaLayout,
    nworld: u32,
    capacity: u64,
) !void {
    const array_names: []const [:0]const u8 = @typeInfo(ArenaLayout).@"struct".field_names;
    var spans: [array_names.len]Span = undefined;
    inline for (array_names, 0..) |array_name, index| {
        const ArrayType: type = @FieldType(ArenaLayout, array_name);
        const array: ArrayType = @field(arena_layout, array_name);
        try expect(array.stride % 4 == 0);
        try expect(array.stride >= array.count);
        const copies: u64 = if (ArrayType.per_world) nworld else 1;
        const end: u64 = @as(u64, array.offset) + @as(u64, array.stride) * copies;
        spans[index] = .{ .start = array.offset, .end = end };
    }
    try expectSpansFit(&spans, capacity);
}

test "robotgpu: every array is aligned, inside its arena and clear of the others" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    const capacities: robotgpu.Capacities = .{};
    for (fixtures.models()) |model| {
        const counts: robotgpu.Counts = robotgpu.countsOf(model, 64);
        const layout: robotgpu.Layout = try robotgpu.layoutFor(counts, capacities);
        try expectArenaLayout(robotgpu.WorldStateLayout, layout.world_f, counts.world_count, capacities.world_f);
        try expectArenaLayout(robotgpu.WorldIntegersLayout, layout.world_u, counts.world_count, capacities.world_u);
        try expectArenaLayout(robotgpu.ModelTablesLayout, layout.model_u, counts.world_count, capacities.model_u);
        try expectArenaLayout(robotgpu.ModelConstantsLayout, layout.model_f, counts.world_count, capacities.model_f);
    }
}

test "robotgpu: an arena too small for its arrays is refused by the arena's name" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    const geno: robotgpu.Counts = robotgpu.countsOf(&fixtures.geno.model, 64);
    try expectError(robotgpu.LayoutError.WorldStateTooSmall, robotgpu.layoutFor(geno, .{ .world_f = 1000 }));
    try expectError(robotgpu.LayoutError.WorldIntegersTooSmall, robotgpu.layoutFor(geno, .{ .world_u = 10 }));
    // Geno has no limited joint, so no limit rows: the KUKA, whose seven joints all have ranges, fills `efc_f`.
    const kuka_counts: robotgpu.Counts = robotgpu.countsOf(&fixtures.kuka, 64);
    try expectError(robotgpu.LayoutError.ConstraintRowsTooSmall, robotgpu.layoutFor(kuka_counts, .{ .efc_f = 10 }));
    try expectError(robotgpu.LayoutError.ModelTablesTooSmall, robotgpu.layoutFor(geno, .{ .model_u = 10 }));
    try expectError(robotgpu.LayoutError.ModelConstantsTooSmall, robotgpu.layoutFor(geno, .{ .model_f = 10 }));
}

test "robotgpu: the actuators are packed as robot.zig has them, each dof's actuators in actuator order" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    const models = [_]*const robot.Model{ &fixtures.kuka, &fixtures.humanoid.model, &fixtures.geno.model };
    var actuators_seen: u32 = 0;
    for (models) |model| {
        const twin: Twin = try .init(model, 4);
        const tables: robotgpu.ModelTablesLayout = twin.layout.model_u;
        const constants: robotgpu.ModelConstantsLayout = twin.layout.model_f;
        var actuator: u32 = 0;
        while (actuator < model.actuator_count) : (actuator += 1) {
            try expectEqual(model.actuator_target[actuator], tables.actuator_target.load(actuator));
            try expectEqual(model.actuator_activation_index[actuator], tables.actuator_activation_index.load(actuator));
            const dynamics: robot.Activation = model.actuator_activation_dynamics[actuator];
            const dynamics_number: u32 = @backingInt(robotgpu.activationDynamicsOf(dynamics));
            try expectEqual(dynamics_number, tables.actuator_dynamics.load(actuator));
            try expectEqual(model.actuator_gain[actuator], constants.actuator_gain.load(actuator));
            const control_limited: u32 = @intFromBool(model.actuator_control_range[actuator] != null);
            try expectEqual(control_limited, tables.actuator_control_limited.load(actuator));
            actuators_seen += 1;
        }
        // Every joint actuator listed exactly once, under its dof, in actuator order.
        var listed: u32 = 0;
        var dof: u32 = 0;
        while (dof < model.dof_count) : (dof += 1) {
            const first: u32 = tables.dof_first_actuator.load(dof);
            const count: u32 = tables.dof_actuator_count.load(dof);
            try expectEqual(listed, first);
            var previous: ?u32 = null;
            var entry: u32 = first;
            while (entry < first + count) : (entry += 1) {
                const listed_actuator: u32 = tables.dof_actuators.load(entry);
                try expectEqual(dof, model.actuator_dof[listed_actuator]);
                if (previous) |earlier| {
                    try expect(earlier < listed_actuator);
                }
                previous = listed_actuator;
            }
            listed += count;
        }
    }
    // The fixtures between them have actuators, or this test would pass on nothing.
    try expect(actuators_seen > 0);
}

test "robotgpu: the limited joints are packed in joint order, two candidate ends each, a row for each end" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    const models = [_]*const robot.Model{ &fixtures.kuka, &fixtures.humanoid.model, &fixtures.geno.model };
    var limited_joints_seen: u32 = 0;
    for (models) |model| {
        const twin: Twin = try .init(model, 4);
        const tables: robotgpu.ModelTablesLayout = twin.layout.model_u;
        // Every joint with a range listed once, in joint order, and no other joint: candidate c is then the lower end
        // (c even) or the upper end (c odd) of the joint listed at c / 2, robot.zig's own order for its limit rows.
        var listed_count: u32 = 0;
        for (model.joint_range, 0..) |range, joint| {
            if (range == null) {
                continue;
            }
            const joint_index: u32 = @intCast(joint);
            try expectEqual(joint_index, tables.limited_joints.load(listed_count));
            listed_count += 1;
        }
        try expectEqual(listed_count, twin.counts.limited_joint_count);
        try expectEqual(2 * listed_count, twin.counts.limit_candidate_count);
        // The device's rows hold both ends of every limited joint - every limit row a world can need.
        // A row for each candidate end, and four for each floor slot - a contact's friction pyramid.
        try expectEqual(2 * listed_count + 4 * twin.counts.floor_slot_count, twin.counts.constraint_capacity);
        limited_joints_seen += listed_count;
    }
    // The fixtures between them have limited joints, or this test would pass on nothing.
    try expect(limited_joints_seen > 0);
}

/// THE LIMIT TESTS' POSE of world `world`, into `joint_positions_out` (one number per coordinate): the reference pose,
/// then every limited joint placed at one of five places along its range - chosen by world and joint, so that across
/// five worlds every joint visits every place, and every kind of candidate occurs at both ends:
///
///     past the lower end         a lower row, its violation below minus the margin
///     inside the lower margin    a lower row, its violation between minus the margin and zero
///     free, mid-range            no row
///     inside the upper margin    an upper row
///     past the upper end         an upper row, past the end
fn limitTestPose(model: *const robot.Model, world: u32, joint_positions_out: []f32) void {
    @memcpy(joint_positions_out, model.reference_joint_positions);
    for (model.joint_range, 0..) |range_or_none, joint| {
        const range: [2]f32 = range_or_none orelse continue;
        const lower_end: f32 = range[0];
        const upper_end: f32 = range[1];
        const margin: f32 = model.joint_limit_margin[joint];
        const places = [_]f32{
            lower_end - 0.02,
            lower_end + 0.5 * margin,
            0.5 * (lower_end + upper_end),
            upper_end - 0.5 * margin,
            upper_end + 0.03,
        };
        const place_index: usize = (world + joint) % places.len;
        const coordinate: u32 = model.joint_first_coordinate[joint];
        joint_positions_out[coordinate] = places[place_index];
    }
}

test "robotgpu: the limit rows on the twin are robot.zig's, bit for bit - which ends, in what order, how far inside" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    // The KUKA's seven joints all have ranges. A margin on each, so an end inside its margin but not yet passed occurs
    // too - with a margin of zero, an end becomes a row only once the joint is past it.
    const model: *robot.Model = &fixtures.kuka;
    for (model.joint_range, model.joint_limit_margin) |range, *margin| {
        if (range != null) {
            margin.* = 0.05;
        }
    }
    const world_count: u32 = 5;
    const twin: Twin = try .init(model, world_count);
    const pose: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(pose);
    const positions: robotgpu.WorldArray(.world_f, .coordinates) = twin.layout.world_f.joint_positions;
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        limitTestPose(model, world, pose);
        for (pose, 0..) |joint_position, coordinate| {
            positions.store(world, @intCast(coordinate), joint_position);
        }
    }
    Twin.run("limit_candidates", world_count * twin.counts.limit_candidate_count);
    Twin.run("constraint_rows", world_count);
    // robot.zig, posed as each world is, makes its rows; the twin's must be the same rows in the same order.
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    var lower_rows: u32 = 0;
    var upper_rows: u32 = 0;
    world = 0;
    while (world < world_count) : (world += 1) {
        limitTestPose(model, world, data.joint_positions);
        robot.kinematics(model, &data);
        robot.makeConstraints(model, &data);
        const row_count: u32 = twin.layout.world_u.constraint_row_count.load(world, 0);
        try expectEqual(data.constraint_count, row_count);
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            const candidate: u32 = twin.layout.world_u.constraint_row_source.load(world, row);
            const joint: u32 = twin.layout.model_u.limited_joints.load(candidate / 2);
            const is_upper_end: bool = candidate % 2 == 1;
            try expectEqual(robot.ConstraintKind.limit, data.constraint_kind[row]);
            try expectEqual(joint, data.constraint_source[row]);
            // The row's sparse Jacobian, spread out over every dof, equal to robot.zig's dense row: +1 or -1 at the
            // joint's dof, zero everywhere else.
            const nonzero_count: u32 = twin.layout.world_u.constraint_jacobian_nonzero_count.load(world, row);
            const first_slot: u32 = row * twin.counts.row_nonzero_capacity;
            const nonzero_dof: u32 = twin.layout.world_u.constraint_jacobian_dofs.load(world, first_slot);
            const nonzero_value: f32 = twin.layout.efc_f.constraint_jacobian_values.load(world, first_slot);
            try expectEqual(@as(u32, 1), nonzero_count);
            var dof: u32 = 0;
            while (dof < model.dof_count) : (dof += 1) {
                const twin_entry: f32 = if (dof == nonzero_dof) nonzero_value else 0.0;
                try expectEqual(data.constraint_jacobian[row * model.dof_count + dof], twin_entry);
            }
            const expected_entry: f32 = if (is_upper_end) -1.0 else 1.0;
            try expectEqual(expected_entry, nonzero_value);
            // How far inside its margin, to the bit.
            const twin_violation: f32 = twin.layout.efc_f.constraint_violation.load(world, row);
            try expectEqual(data.constraint_violation[row], twin_violation);
            if (is_upper_end) {
                upper_rows += 1;
            } else {
                lower_rows += 1;
            }
        }
    }
    // Rows at both ends, or the test would pass on half of what it checks.
    try expect(lower_rows > 0 and upper_rows > 0);
}

test "robotgpu: a model with what the device does not simulate is refused by name" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    // Geno - geoms that a floor's contacts reach, no equality - is simulated, his constraints on or off.
    try robotgpu.refuseUnsimulatedFeatures(&fixtures.geno.model);
    var without_constraints: robot.Model = fixtures.geno.model;
    without_constraints.opt.disable_constraints = true;
    try robotgpu.refuseUnsimulatedFeatures(&without_constraints);
    // A copy wider than Newton's working set - the check reads only the count - is refused, constraints or not.
    var too_wide: robot.Model = without_constraints;
    too_wide.dof_count = robotgpu.max_newton_dofs + 1;
    try expectError(robotgpu.ModelError.TooManyDofs, robotgpu.refuseUnsimulatedFeatures(&too_wide));
    // A copy of seventy boxes on one body: 280 floor slots, 1,120 rows a world could need - more than Newton holds.
    const box_count: usize = 70;
    var boxes: [box_count]robot.GeomShape = undefined;
    var box_bodies: [box_count]u32 = undefined;
    for (&boxes, &box_bodies) |*shape, *body| {
        shape.* = .{ .box = .{ .half_extent = vec(0.1, 0.1, 0.1) } };
        body.* = 1;
    }
    var too_many_rows: robot.Model = fixtures.geno.model;
    too_many_rows.geom_shape = &boxes;
    too_many_rows.geom_body = &box_bodies;
    too_many_rows.geom_count = box_count;
    try expectError(robotgpu.ModelError.TooManyRows, robotgpu.refuseUnsimulatedFeatures(&too_many_rows));
    // A copy given a tendon - the check reads only the count - is refused before anything is made, constraints or not.
    var with_a_tendon: robot.Model = without_constraints;
    with_a_tendon.tendon_count = 1;
    const refused: robotgpu.ModelError!void = robotgpu.refuseUnsimulatedFeatures(&with_a_tendon);
    try expectError(robotgpu.ModelError.TendonsNotSimulated, refused);
}

test "robotgpu: world-major indexing - a world's items together, the worlds one after another" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    const geno: robotgpu.Counts = robotgpu.countsOf(&fixtures.geno.model, 64);
    const layout: robotgpu.Layout = try robotgpu.layoutFor(geno, .{});
    // xpos: Geno's 25 bodies, a vector of four floats each - a stride of 100.
    const xpos: robotgpu.WorldArray(.world_f, .body_vectors) = layout.world_f.body_positions;
    try expectEqual(@as(u32, 25), geno.body_count);
    try expectEqual(@as(u32, 100), xpos.stride);
    const third_body_of_second_world: u32 = xpos.at(1, 2);
    try expectEqual(xpos.offset + 100 + 2 * 4, third_body_of_second_world);
}

test "robotgpu: the accessors read and write an array's own arena, at its own place" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    const geno: robotgpu.Counts = robotgpu.countsOf(&fixtures.geno.model, 64);
    const layout: robotgpu.Layout = try robotgpu.layoutFor(geno, .{});
    // The CPU twin's arenas are the module's static arrays - what its kernels index.
    const twin: *robotgpu.Buffers = &robotgpu.g.B;
    @memset(&twin.world_f, 0);
    @memset(&twin.world_u, 0);
    // A vector, body 7 of world 3: world 3's block, then body 7's four floats.
    const xpos: robotgpu.WorldArray(.world_f, .body_vectors) = layout.world_f.body_positions;
    const position: Vec = vec(0.25, -1.5, 2.0);
    xpos.storeVec(3, 7, position);
    const body_7_of_world_3: u32 = xpos.offset + 3 * xpos.stride + 7 * 4;
    const stored: Vec = twin.world_f[body_7_of_world_3..][0..4].*;
    try expect(@reduce(.And, stored == position));
    try expect(@reduce(.And, xpos.loadVec(3, 7) == position));
    // Its neighbours untouched: body 6 of world 3, and body 7 of worlds 2 and 4.
    const untouched: Vec = @splat(0);
    try expect(@reduce(.And, xpos.loadVec(3, 6) == untouched));
    try expect(@reduce(.And, xpos.loadVec(2, 7) == untouched));
    try expect(@reduce(.And, xpos.loadVec(4, 7) == untouched));
    // A word, world 5's overflow word, in world_u.
    const overflow: robotgpu.WorldArray(.world_u, .single) = layout.world_u.overflow;
    overflow.store(5, 0, 0xbad);
    try expectEqual(@as(u32, 0xbad), twin.world_u[overflow.offset + 5 * overflow.stride]);
    try expectEqual(@as(u32, 0xbad), overflow.load(5, 0));
    try expectEqual(@as(u32, 0), overflow.load(4, 0));
}

/// The tables `pack` copies from robot.zig's model, each equal to the model's table of the same name, and each
/// joint's type packed as robot.zig's tag - MuJoCo's numbering.
fn expectPackedTables(model: *const robot.Model, tables: robotgpu.ModelTablesLayout) !void {
    const model_u: []const u32 = &robotgpu.g.B.model_u;
    const copied_table_names = [_][:0]const u8{
        "body_parent",
        "body_subtree_count",
        "body_root",
        "body_first_joint",
        "body_joint_count",
        "body_first_dof",
        "body_dof_count",
        "joint_body",
        "joint_first_coordinate",
        "joint_first_dof",
        "dof_parent",
        "dof_body",
        "dof_joint",
        "mass_row_entry_count",
        "mass_row_start",
        "mass_entry_column",
        "geom_body",
        "site_body",
    };
    inline for (copied_table_names) |table_name| {
        const Table: type = @FieldType(robotgpu.ModelTablesLayout, table_name);
        const table: Table = @field(tables, table_name);
        const model_table: []const u32 = @field(model, table_name);
        try expect(eql(u32, table.within(model_u), model_table));
    }
    for (model.joint_type, 0..) |joint_type, joint| {
        try expectEqual(@as(u32, @backingInt(joint_type)), tables.joint_type.load(@intCast(joint)));
    }
}

/// Every packed constant equal to the model's own, read back through the kernels' accessors: the vector tables lane by
/// lane, the scalar tables and the inertias field by field, the ranges with their limited flags, the limits' softness
/// and impedance, and each geom's type - MuJoCo's numbers, written out here - and size.
fn expectPackedConstants(model: *const robot.Model, layout: robotgpu.Layout) !void {
    const constants: robotgpu.ModelConstantsLayout = layout.model_f;
    const tables: robotgpu.ModelTablesLayout = layout.model_u;
    const model_f: []const f32 = &robotgpu.g.B.model_f;
    const vector_table_names = [_][:0]const u8{
        "body_rest_position",
        "body_rest_rotation",
        "body_centre_of_mass_offset",
        "joint_local_axis",
        "joint_local_anchor",
        "geom_local_position",
        "geom_local_rotation",
        "site_local_position",
        "site_local_rotation",
    };
    inline for (vector_table_names) |table_name| {
        const Table: type = @FieldType(robotgpu.ModelConstantsLayout, table_name);
        const table: Table = @field(constants, table_name);
        const model_vectors: []const Vec = @field(model, table_name);
        for (model_vectors, 0..) |model_vector, item| {
            const packed_vector: Vec = table.loadVec(@intCast(item));
            try expect(@reduce(.And, packed_vector == model_vector));
        }
    }
    const scalar_table_names = [_][:0]const u8{
        "reference_joint_positions",
        "body_mass",
        "body_subtree_mass",
        "joint_limit_margin",
        "joint_damping",
        "joint_stiffness",
        "joint_reference_position",
        "dof_armature",
        "geom_friction",
    };
    inline for (scalar_table_names) |table_name| {
        const Table: type = @FieldType(robotgpu.ModelConstantsLayout, table_name);
        const table: Table = @field(constants, table_name);
        const model_scalars: []const f32 = @field(model, table_name);
        for (model_scalars, 0..) |model_scalar, item| {
            try expectEqual(model_scalar, table.load(@intCast(item)));
        }
    }
    for (model.body_local_inertia, 0..) |inertia, body| {
        const packed_inertia: robot.Inertia = constants.body_local_inertia.loadInertia(@intCast(body));
        try expect(@reduce(.And, packed_inertia.diag == inertia.diag));
        try expect(@reduce(.And, packed_inertia.off == inertia.off));
        try expect(@reduce(.And, packed_inertia.h == inertia.h));
        try expectEqual(inertia.mass, packed_inertia.mass);
    }
    const ranges: []const ?[2]f32 = model.joint_range;
    for (ranges, model.joint_limit_softness, model.joint_limit_impedance, 0..) |range, softness, impedance, joint| {
        const joint_index: u32 = @intCast(joint);
        const limited: bool = tables.jnt_limited.load(joint_index) == 1;
        try expectEqual(range != null, limited);
        const expected_range: [2]f32 = range orelse .{ 0, 0 };
        const packed_range: []const f32 = model_f[constants.joint_range.at(joint_index)..][0..2];
        try expect(eql(f32, packed_range, &expected_range));
        const expected_softness: [2]f32 = .{ softness.time_const_s, softness.damp_ratio };
        const packed_softness: []const f32 = model_f[constants.joint_limit_softness.at(joint_index)..][0..2];
        try expect(eql(f32, packed_softness, &expected_softness));
        const expected_impedance: [5]f32 = .{
            impedance.min,
            impedance.max,
            impedance.width,
            impedance.midpoint,
            impedance.power,
        };
        const packed_impedance: []const f32 = model_f[constants.joint_limit_impedance.at(joint_index)..][0..5];
        try expect(eql(f32, packed_impedance, &expected_impedance));
    }
    for (model.geom_shape, 0..) |shape, geom| {
        const geom_index: u32 = @intCast(geom);
        // MuJoCo's numbers for its geom types (`mjtGeom`), written out rather than read from `robotgpu.GeomType`.
        const mujoco_type: u32 = switch (shape) {
            .sphere => 2,
            .capsule => 3,
            .cylinder => 5,
            .box => 6,
            .hull => 7,
        };
        try expectEqual(mujoco_type, tables.geom_type.load(geom_index));
        const expected_size: Vec = switch (shape) {
            .sphere => |sphere| .{ sphere.radius, 0, 0, 0 },
            .box => |box| .{ box.half_extent[0], box.half_extent[1], box.half_extent[2], 0 },
            .capsule => |capsule| .{ capsule.radius, capsule.half_height, 0, 0 },
            .cylinder => |cylinder| .{ cylinder.radius, cylinder.half_height, 0, 0 },
            .hull => @splat(0),
        };
        try expect(@reduce(.And, constants.geom_size.loadVec(geom_index) == expected_size));
    }
}

/// Every body's dof chain and mask, checked by a second route: up `dof_parent` from the body's last dof, which reaches
/// the same dofs, in reverse, as the body walk `pack` made - and the mask holds those dofs' bits and no others.
fn expectPackedChains(model: *const robot.Model, tables: robotgpu.ModelTablesLayout) !void {
    const words_per_mask: u32 = robotgpu.maskWords(model.dof_count);
    var body: u32 = 1;
    while (body < model.body_count) : (body += 1) {
        const chain_start: u32 = tables.body_chain_start.load(body);
        const chain_length: u32 = tables.body_chain_length.load(body);
        // The body's last dof: its own last, or else its nearest ancestor's with any.
        var last_dof: u32 = robot.no_dof;
        var ancestor: u32 = body;
        while (ancestor != 0 and last_dof == robot.no_dof) {
            if (model.body_dof_count[ancestor] > 0) {
                last_dof = model.body_first_dof[ancestor] + model.body_dof_count[ancestor] - 1;
            }
            ancestor = model.body_parent[ancestor];
        }
        var position: u32 = chain_length;
        var dof: u32 = last_dof;
        while (dof != robot.no_dof) {
            try expect(position > 0);
            position -= 1;
            try expectEqual(dof, tables.chain_dofs.load(chain_start + position));
            const mask_word: u32 = tables.body_ancestor_mask.load(body * words_per_mask + dof / 32);
            const dof_bit: u32 = @as(u32, 1) << @intCast(dof % 32);
            try expect(mask_word & dof_bit != 0);
            dof = model.dof_parent[dof];
        }
        try expectEqual(@as(u32, 0), position);
        var mask_bits: u32 = 0;
        var word: u32 = 0;
        while (word < words_per_mask) : (word += 1) {
            mask_bits += @popCount(tables.body_ancestor_mask.load(body * words_per_mask + word));
        }
        try expectEqual(chain_length, mask_bits);
    }
}

/// The branches: each starts at a body on the world and steps from parent to child; and the leaves, found a second
/// way - bodies that are nobody's parent - end the branches one each, in body order (MJW's).
fn expectPackedBranches(
    model: *const robot.Model,
    counts: robotgpu.Counts,
    tables: robotgpu.ModelTablesLayout,
) !void {
    var branch: u32 = 0;
    while (branch < counts.branch_count) : (branch += 1) {
        const start: u32 = tables.body_branch_start.load(branch);
        const end: u32 = tables.body_branch_start.load(branch + 1);
        try expect(start < end);
        try expectEqual(@as(u32, 0), model.body_parent[tables.body_branches.load(start)]);
        var entry: u32 = start + 1;
        while (entry < end) : (entry += 1) {
            const parent: u32 = tables.body_branches.load(entry - 1);
            const child: u32 = tables.body_branches.load(entry);
            try expectEqual(parent, model.body_parent[child]);
        }
    }
    var next_branch: u32 = 0;
    var candidate: u32 = 1;
    while (candidate < model.body_count) : (candidate += 1) {
        const has_child: bool = for (model.body_parent[1..]) |parent| {
            if (parent == candidate) {
                break true;
            }
        } else false;
        if (!has_child) {
            try expect(next_branch < counts.branch_count);
            const branch_end: u32 = tables.body_branch_start.load(next_branch + 1);
            try expectEqual(candidate, tables.body_branches.load(branch_end - 1));
            next_branch += 1;
        }
    }
    try expectEqual(counts.branch_count, next_branch);
    try expectEqual(counts.branch_body_count, tables.body_branch_start.load(counts.branch_count));
}

/// Pack `model` into the CPU twin's model arenas, and check every table against the model's own, read back through
/// the accessors the kernels use, and the chains and branches against a second derivation.
fn expectPacked(model: *const robot.Model) !void {
    const counts: robotgpu.Counts = robotgpu.countsOf(model, 4);
    const layout: robotgpu.Layout = try robotgpu.layoutFor(counts, .{});
    const twin: *robotgpu.Buffers = &robotgpu.g.B;
    robotgpu.pack(model, layout, &twin.model_u, &twin.model_f);
    try expectPackedTables(model, layout.model_u);
    try expectPackedConstants(model, layout);
    try expectPackedChains(model, layout.model_u);
    try expectPackedBranches(model, counts, layout.model_u);
}

test "robotgpu: the KUKA, packed and read back through the accessors, is the model's own" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    try expectPacked(&fixtures.kuka);
}

test "robotgpu: the humanoid, packed and read back through the accessors, is the model's own" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    try expectPacked(&fixtures.humanoid.model);
}

test "robotgpu: Geno, packed and read back through the accessors, is the model's own" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    try expectPacked(&fixtures.geno.model);
}

/// THE R1 GATE - TEMPORARY, the check of the Nov 1 tidy of robot.zig's `kinematics`, removed once it has run:
/// robot.zig's state after 200 steps, hashed. The expected values are the ones recorded on Oct 31, when `moveByJoint`
/// was extracted under the same gate: the same steps and the same hash, so equal values mean not one bit moved.
fn fingerprintOf200Steps(gpa: Allocator, source: []const u8) !u64 {
    var imported: robot_import.Imported = try modelFromMjcf(gpa, source);
    defer imported.deinit();
    var data: robot.Data = try .init(gpa, &imported.model);
    defer data.deinit();
    for (0..200) |_| {
        robot.step(&imported.model, &data);
    }
    var hasher: Wyhash = .init(0);
    hasher.update(sliceAsBytes(data.joint_positions));
    hasher.update(sliceAsBytes(data.joint_velocities));
    hasher.update(sliceAsBytes(data.body_positions));
    hasher.update(sliceAsBytes(data.body_orientations));
    return hasher.final();
}

test "R1 gate: robot.zig's 200-step fingerprints are unchanged" {
    const humanoid_fingerprint: u64 = try fingerprintOf200Steps(testing_allocator, humanoid_xml);
    const geno_fingerprint: u64 = try fingerprintOf200Steps(testing_allocator, geno_xml);
    try expectEqual(@as(u64, 0x2acacc17d2834891), humanoid_fingerprint);
    try expectEqual(@as(u64, 0xb51c1eb44de302bf), geno_fingerprint);
}

test "robotgpu: the twin, run directly - clear_overflow clears every world's word and writes nothing else" {
    const gpa: Allocator = testing_allocator;
    var geno: robot_import.Imported = try modelFromMjcf(gpa, geno_xml);
    defer geno.deinit();
    const twin: Twin = try .init(&geno.model, 64);
    const poison: u32 = 0xdead_beef;
    @memset(&robotgpu.g.B.world_u, poison);
    Twin.run("clear_overflow", twin.counts.world_count);
    var world: u32 = 0;
    while (world < twin.counts.world_count) : (world += 1) {
        try expectEqual(@as(u32, 0), twin.layout.world_u.overflow.load(world, 0));
    }
    // Every other word of the arena still the poison: the kernel wrote one word a world and no more.
    var cleared_words: u32 = 0;
    for (robotgpu.g.B.world_u) |word| {
        cleared_words += @intFromBool(word != poison);
    }
    try expectEqual(twin.counts.world_count, cleared_words);
}

/// One coordinate of world `world`'s test pose: the reference pose moved by an amount that differs per coordinate and
/// per world, so every world is posed differently and every joint turned.
fn testCoordinate(model: *const robot.Model, world: u32, coordinate: u32) f32 {
    const turn: f32 = 0.05 * float(coordinate % 7 + 1) * float(world + 1);
    return model.reference_joint_positions[coordinate] + turn;
}

/// Every world of the twin posed in its own way (`testCoordinate`).
fn poseTwinWorlds(model: *const robot.Model, twin: Twin, world_count: u32) void {
    const positions: robotgpu.WorldArray(.world_f, .coordinates) = twin.layout.world_f.joint_positions;
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        var coordinate: u32 = 0;
        while (coordinate < model.coordinate_count) : (coordinate += 1) {
            positions.store(world, coordinate, testCoordinate(model, world, coordinate));
        }
    }
}

/// robot.zig's `data` posed as the twin's world `world` is.
fn poseLikeTwinWorld(model: *const robot.Model, data: *robot.Data, world: u32) void {
    var coordinate: u32 = 0;
    while (coordinate < model.coordinate_count) : (coordinate += 1) {
        data.joint_positions[coordinate] = testCoordinate(model, world, coordinate);
    }
}

/// Kinematics on the twin against robot.zig's own, world by world: the same pose given to both, every body's position,
/// orientation and centre of mass, and every joint's anchor and axis, compared bit for bit.
fn expectTwinKinematics(gpa: Allocator, model: *const robot.Model) !void {
    const world_count: u32 = 4;
    const twin: Twin = try .init(model, world_count);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    poseTwinWorlds(model, twin, world_count);
    Twin.run("kinematics_branch", world_count * twin.counts.branch_count);
    Twin.run("geom_poses", world_count * twin.counts.geom_count);
    Twin.run("site_poses", world_count * twin.counts.site_count);
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        poseLikeTwinWorld(model, &data, world);
        robot.kinematics(model, &data);
        var body: u32 = 0;
        while (body < model.body_count) : (body += 1) {
            try expect(@reduce(.And, state.body_positions.loadVec(world, body) == data.body_positions[body]));
            try expect(@reduce(.And, state.body_orientations.loadVec(world, body) == data.body_orientations[body]));
            const twin_centre: Vec = state.body_centres_of_mass.loadVec(world, body);
            const robot_centre: Vec = data.body_centres_of_mass[body];
            try expect(@reduce(.And, twin_centre == robot_centre));
        }
        var joint: u32 = 0;
        while (joint < model.joint_count) : (joint += 1) {
            try expect(@reduce(.And, state.joint_anchors.loadVec(world, joint) == data.joint_anchors[joint]));
            try expect(@reduce(.And, state.joint_axes.loadVec(world, joint) == data.joint_axes[joint]));
        }
        // Geoms, against their body's pose composed on the CPU with the same function; sites, against robot.zig's.
        var geom: u32 = 0;
        while (geom < model.geom_count) : (geom += 1) {
            const geom_body: u32 = model.geom_body[geom];
            const body_pose: robot.Pose = .{
                .pos = data.body_positions[geom_body],
                .rot = data.body_orientations[geom_body],
            };
            const offset_from_body: robot.Pose = .{
                .pos = model.geom_local_position[geom],
                .rot = model.geom_local_rotation[geom],
            };
            const placed: robot.Pose = body_pose.compose(offset_from_body);
            try expect(@reduce(.And, state.geom_positions.loadVec(world, geom) == placed.pos));
            try expect(@reduce(.And, state.geom_orientations.loadVec(world, geom) == placed.rot));
        }
        var site: u32 = 0;
        while (site < model.site_count) : (site += 1) {
            try expect(@reduce(.And, state.site_positions.loadVec(world, site) == data.site_positions[site]));
            try expect(@reduce(.And, state.site_orientations.loadVec(world, site) == data.site_orientations[site]));
        }
    }
}

test "robotgpu: kinematics on the twin poses every body, geom and site as robot.zig does, bit for bit" {
    const gpa: Allocator = testing_allocator;
    var kuka_model: robot.Model = try kuka.Model.build(gpa);
    defer kuka_model.deinit();
    try expectTwinKinematics(gpa, &kuka_model);
    var humanoid: robot_import.Imported = try modelFromMjcf(gpa, humanoid_xml);
    defer humanoid.deinit();
    try expectTwinKinematics(gpa, &humanoid.model);
    var geno: robot_import.Imported = try modelFromMjcf(gpa, geno_xml);
    defer geno.deinit();
    try expectTwinKinematics(gpa, &geno.model);
}

/// Actuator `actuator`'s control in world `world`, for actuation's check: it changes sign and size with the actuator
/// and grows with the world - and is large enough, for some, that a control range clamps it.
fn testControl(world: u32, actuator: u32) f32 {
    const world_factor: f32 = @floatFromInt(world % 5 + 1);
    const actuator_factor: f32 = @floatFromInt(@as(i32, @intCast(actuator % 7)) - 3);
    return 0.4 * actuator_factor * world_factor;
}

/// Activation `index`'s value in world `world`, for actuation's check.
fn testActivation(world: u32, index: u32) f32 {
    const world_factor: f32 = @floatFromInt(world % 3 + 1);
    const activation_factor: f32 = @floatFromInt(index % 4 + 1);
    return 0.1 * activation_factor * world_factor;
}

/// Dof `dof`'s joint velocity in world `world`, for the velocity pass's check: an amount that cycles with the dof and
/// grows with the world.
fn testRate(world: u32, dof: u32) f32 {
    const dof_factor: f32 = @floatFromInt(dof % 7 + 1);
    const world_factor: f32 = @floatFromInt(world % 4 + 1);
    return 0.05 * dof_factor * world_factor;
}

/// The index of the step program's dispatch of `kernel_name`, found at compile time: a kernel renamed or removed is a
/// compile error here, not a test that silently runs too little.
fn dispatchIndex(comptime kernel_name: []const u8) usize {
    for (robotgpu.step_program, 0..) |dispatch, index| {
        if (eql(u8, dispatch.kernel, kernel_name)) {
            return index;
        }
    }
    @compileError("the step program has no dispatch of `" ++ kernel_name ++ "`");
}

/// The step program on the twin up to and including the dispatch of `last_kernel` - through `factor_mass_matrix`,
/// everything a constraint row's projection reads but the rows themselves; through `solve_smooth_acceleration`, the
/// free acceleration Newton starts from too.
fn runTwinStepThrough(twin: Twin, comptime last_kernel: []const u8) void {
    const last_dispatch: usize = comptime dispatchIndex(last_kernel);
    inline for (robotgpu.step_program[0 .. last_dispatch + 1]) |dispatch| {
        Twin.run(dispatch.kernel, robotgpu.invocationCount(dispatch.invocations, twin.counts));
    }
}

/// The constraint program on the twin, every dispatch in its order.
fn runTwinConstraintProgram(twin: Twin) void {
    inline for (robotgpu.constraint_program) |dispatch| {
        Twin.run(dispatch.kernel, robotgpu.invocationCount(dispatch.invocations, twin.counts));
    }
}

test "robotgpu: limit rows projected on the twin as robot.zig projects them, bit for bit - at either inertia" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    // The KUKA with a margin on every limited joint, posed around its limits (`limitTestPose`) and moving - every dof
    // given a velocity, so each row's velocity and its damping term are not zero.
    const model: *robot.Model = &fixtures.kuka;
    for (model.joint_range, model.joint_limit_margin) |range, *margin| {
        if (range != null) {
            margin.* = 0.05;
        }
    }
    // Three joints made to take the projection's other branches. Joint 0: a time constant shorter than two steps, so
    // the floor of two steps decides. Joint 1: an impedance curve wide enough (0.2) for the rows' violations, 0.025 to
    // 0.07, to fall inside it, on both sides of its midpoint - at the default width of 0.001 every row would sit at
    // the curve's maximum. Joint 2: a linear curve, power 1, robot.zig's separate branch for it.
    model.joint_limit_softness[0].time_const_s = 0.25 * model.opt.timestep;
    model.joint_limit_impedance[1].width = 0.2;
    model.joint_limit_impedance[1].midpoint = 0.3;
    model.joint_limit_impedance[1].power = 3.0;
    model.joint_limit_impedance[2].width = 0.2;
    model.joint_limit_impedance[2].power = 1.0;
    // Both inertias: MuJoCo's default - the reference pose's, the rows kernel setting it, no solve - and the exact one,
    // MuJoCo's DIAGEXACT. Each pass on a twin of its own, which starts from cleared arrays.
    for ([_]robot.ConstraintInertia{ .exact, .reference_pose }) |inertia| {
        model.opt.constraint_inertia = inertia;
        const world_count: u32 = 5;
        const twin: Twin = try .init(model, world_count);
        const state: robotgpu.WorldStateLayout = twin.layout.world_f;
        const rows: robotgpu.ConstraintRowsLayout = twin.layout.efc_f;
        const pose: []f32 = try gpa.alloc(f32, model.coordinate_count);
        defer gpa.free(pose);
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            limitTestPose(model, world, pose);
            for (pose, 0..) |joint_position, coordinate| {
                state.joint_positions.store(world, @intCast(coordinate), joint_position);
            }
            var dof: u32 = 0;
            while (dof < model.dof_count) : (dof += 1) {
                state.joint_velocities.store(world, dof, testRate(world, dof));
            }
        }
        runTwinStepThrough(twin, "factor_mass_matrix");
        runTwinConstraintProgram(twin);
        // robot.zig, given the same pose and velocities, factors its mass matrix, makes its rows and projects them.
        var data: robot.Data = try .init(gpa, model);
        defer data.deinit();
        var rows_compared: u32 = 0;
        world = 0;
        while (world < world_count) : (world += 1) {
            limitTestPose(model, world, data.joint_positions);
            var dof: u32 = 0;
            while (dof < model.dof_count) : (dof += 1) {
                data.joint_velocities[dof] = testRate(world, dof);
            }
            robot.kinematics(model, &data);
            robot.comPos(model, &data);
            robot.crb(model, &data);
            robot.factorM(model, &data);
            robot.makeConstraints(model, &data);
            robot.projectConstraints(model, &data);
            const row_count: u32 = twin.layout.world_u.constraint_row_count.load(world, 0);
            try expectEqual(data.constraint_count, row_count);
            var row: u32 = 0;
            while (row < row_count) : (row += 1) {
                // M^-1 J^T, every dof of it - made only for the exact inertia: under the reference pose's the device
                // solves nothing.
                if (inertia == .exact) {
                    const solution_first: u32 = row * model.dof_count;
                    dof = 0;
                    while (dof < model.dof_count) : (dof += 1) {
                        const robot_entry: f32 = data.constraint_inv_inertia_jacobian[solution_first + dof];
                        const entry_index: u32 = solution_first + dof;
                        const twin_entry: f32 = rows.constraint_inverse_inertia_jacobian.load(world, entry_index);
                        try expectEqual(robot_entry, twin_entry);
                    }
                }
                try expectEqual(data.constraint_inertia[row], rows.constraint_inertia.load(world, row));
                try expectEqual(data.constraint_velocity[row], rows.constraint_velocity.load(world, row));
                try expectEqual(data.constraint_regularizer[row], rows.constraint_regularizer.load(world, row));
                try expectEqual(data.constraint_target_acc[row], rows.constraint_target_acceleration.load(world, row));
                rows_compared += 1;
            }
        }
        try expect(rows_compared > 0);
    }
}

/// Dof `dof`'s applied force in world `world`, for the smooth forces' and the solve's check: an amount that cycles with
/// the dof and grows with the world.
fn testForce(world: u32, dof: u32) f32 {
    const dof_factor: f32 = @floatFromInt(dof % 5 + 1);
    const world_factor: f32 = @floatFromInt(world + 1);
    return 0.05 * dof_factor * world_factor;
}

/// robot.zig's `data` given the twin's world `world`'s state and inputs: its positions, velocities, controls,
/// activations and applied forces - the test values every check uses.
fn giveRobotWorldInputs(model: *const robot.Model, data: *robot.Data, world: u32) void {
    poseLikeTwinWorld(model, data, world);
    for (data.joint_velocities, 0..) |*rate, dof| {
        rate.* = testRate(world, @intCast(dof));
    }
    for (data.controls, 0..) |*control, actuator| {
        control.* = testControl(world, @intCast(actuator));
    }
    for (data.activations, 0..) |*activation, index| {
        activation.* = testActivation(world, @intCast(index));
    }
    for (data.applied_joint_forces, 0..) |*applied_force, dof| {
        applied_force.* = testForce(world, @intCast(dof));
    }
}

/// The twin's worlds given their state and inputs - every world its own positions (`poseTwinWorlds`), velocities,
/// controls, activations and applied forces, as `giveRobotWorldInputs` gives them to robot.zig.
fn giveTwinWorldsInputs(model: *const robot.Model, twin: Twin, world_count: u32) void {
    poseTwinWorlds(model, twin, world_count);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        var dof: u32 = 0;
        while (dof < model.dof_count) : (dof += 1) {
            state.joint_velocities.store(world, dof, testRate(world, dof));
            state.applied_joint_forces.store(world, dof, testForce(world, dof));
        }
        var actuator: u32 = 0;
        while (actuator < model.actuator_count) : (actuator += 1) {
            state.controls.store(world, actuator, testControl(world, actuator));
        }
        var activation: u32 = 0;
        while (activation < model.activation_count) : (activation += 1) {
            state.activations.store(world, activation, testActivation(world, activation));
        }
    }
}

/// How much a Newton check solved: the rows over every world, and the rounds.
const NewtonSeen = struct {
    rows: u32,
    rounds: u32,
};

/// Newton on the twin against robot.zig's whole forward pass, for `model`: its worlds moving under controls, applied
/// forces and gravity, posed around their limits with a margin on every one, solved by Newton - every world's
/// accelerations and joint forces, every row's force and the rounds, to the bit. Returns the rows and rounds seen.
fn expectTwinNewton(gpa: Allocator, model: *robot.Model) !NewtonSeen {
    // Newton chosen before robot.zig's Data is built, which sizes Newton's working set.
    for (model.joint_range, model.joint_limit_margin) |range, *margin| {
        if (range != null) {
            margin.* = 0.05;
        }
    }
    model.opt.solver.algorithm = .newton;
    // The device's Newton starts cold, from the free acceleration (its warm start comes with the constraint step).
    model.opt.warm_start = false;
    const world_count: u32 = 5;
    const twin: Twin = try .init(model, world_count);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    giveTwinWorldsInputs(model, twin, world_count);
    const pose: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(pose);
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        limitTestPose(model, world, pose);
        for (pose, 0..) |joint_position, coordinate| {
            state.joint_positions.store(world, @intCast(coordinate), joint_position);
        }
    }
    runTwinStepThrough(twin, "solve_smooth_acceleration");
    runTwinConstraintProgram(twin);
    // robot.zig's whole forward pass, given the same inputs: its rows, their projection, the free acceleration and
    // Newton's answer.
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    var rows_seen: u32 = 0;
    var rounds_seen: u32 = 0;
    world = 0;
    while (world < world_count) : (world += 1) {
        giveRobotWorldInputs(model, &data, world);
        limitTestPose(model, world, data.joint_positions);
        robot.forward(model, &data);
        var dof: u32 = 0;
        while (dof < model.dof_count) : (dof += 1) {
            try expectEqual(data.joint_accelerations[dof], state.joint_accelerations.load(world, dof));
            try expectEqual(data.constraint_joint_forces[dof], state.constraint_joint_forces.load(world, dof));
        }
        const row_count: u32 = twin.layout.world_u.constraint_row_count.load(world, 0);
        try expectEqual(data.constraint_count, row_count);
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            try expectEqual(data.constraint_force[row], twin.layout.efc_f.constraint_force.load(world, row));
        }
        const twin_rounds: u32 = twin.layout.world_u.newton_iterations.load(world, 0);
        try expectEqual(data.solver_iterations, twin_rounds);
        const twin_evaluations: u32 = twin.layout.world_u.newton_line_evaluations.load(world, 0);
        try expectEqual(data.solver_line_evaluations, twin_evaluations);
        rows_seen += row_count;
        rounds_seen += twin_rounds;
    }
    const seen: NewtonSeen = .{ .rows = rows_seen, .rounds = rounds_seen };
    return seen;
}

test "robotgpu: Newton on the twin is robot.zig's, bit for bit - accelerations, row forces, joint forces, rounds" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    // The KUKA (seven ranged hinges) and MuJoCo's humanoid (27 dofs, many of its hinges ranged).
    const models = [_]*robot.Model{ &fixtures.kuka, &fixtures.humanoid.model };
    for (models) |model| {
        const seen: NewtonSeen = try expectTwinNewton(gpa, model);
        // Rows were solved, over more than one round a world, or the test would pass on a solver that never ran.
        try expect(seen.rows > 0 and seen.rounds > 5);
    }
}

/// robot.zig's `data` taken through a step's forward dynamics as the twin's world `world` is: posed, given the
/// world's velocities, controls, activations and applied forces, and every stage up to the smooth acceleration
/// computed. Each stage's results stay in `data` - no later stage writes an earlier one's - so the twin's can be
/// compared with them afterwards, in any order.
fn robotThroughForwardDynamics(
    model: *const robot.Model,
    data: *robot.Data,
    world: u32,
) void {
    giveRobotWorldInputs(model, data, world);
    robot.kinematics(model, data);
    robot.comPos(model, data);
    robot.crb(model, data);
    robot.factorM(model, data);
    robot.comVel(model, data);
    robot.biasForce(model, data);
    robot.passive(model, data);
    robot.actuation(model, data, model.opt.timestep);
    robot.forwardDynamics(model, data);
}

/// Whether two vectors' three components are equal to the bit - the fourth, which no contact uses, aside.
fn sameThreeComponents(expected: Vec, actual: Vec) bool {
    return expected[0] == actual[0] and expected[1] == actual[1] and expected[2] == actual[2];
}

/// How many floor contacts a comparison compared, and how many of them a cylinder's.
const FloorContactsCompared = struct {
    contacts: u32 = 0,
    of_cylinders: u32 = 0,
};

/// THE FLOOR'S CONTACTS ON THE TWIN AGAINST robot.zig's: four worlds of `model` given their inputs, the floor at the
/// first world's root height - so the legs and much else reach under it - the twin's step up to the geoms' poses and
/// its floor kernel, and robot.zig's `pushFloorContacts` on each world: every filled slot, in slot order, the next
/// contact robot.zig pushed - its position, distance and frame equal to the bit - and no contact left over. Returns
/// how many contacts were compared, and how many of them a cylinder's.
fn expectTwinFloorContacts(gpa: Allocator, simulated: *const robot.Model) !FloorContactsCompared {
    const model: *const robot.Model = simulated;
    const world_count: u32 = 4;
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    giveRobotWorldInputs(model, &data, 0);
    robot.kinematics(model, &data);
    const root_body: u32 = 1;
    const floor_height: f32 = data.body_positions[root_body][2];
    const ground: robot.Floor = .{
        .plane = .{ .point = vec(0, 0, floor_height), .normal = vec(0, 0, 1) },
        .friction = 1.0,
    };
    const twin: Twin = try .init(model, world_count);
    robotgpu.g.P.options.floor_contacts = .enabled;
    robotgpu.g.P.options.floor_height = floor_height;
    robotgpu.g.P.options.floor_friction = ground.friction;
    robotgpu.g.P.options.floor_margin = ground.margin;
    giveTwinWorldsInputs(model, twin, world_count);
    runTwinStepThrough(twin, "geom_poses");
    Twin.run("floor_contacts", world_count * twin.counts.geom_count);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    const filled: robotgpu.WorldArray(.world_u, .floor_slots) = twin.layout.world_u.floor_slot_filled;
    const tables: robotgpu.ModelTablesLayout = twin.layout.model_u;
    var compared: FloorContactsCompared = .{};
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        giveRobotWorldInputs(model, &data, world);
        robot.kinematics(model, &data);
        data.clearContacts();
        try robot.pushFloorContacts(model, &data, ground);
        var pushed: u32 = 0;
        var slot: u32 = 0;
        while (slot < twin.counts.floor_slot_count) : (slot += 1) {
            if (filled.load(world, slot) == 0) {
                continue;
            }
            try expect(pushed < data.contact_count);
            const contact: robot.Contact = data.contacts[pushed];
            pushed += 1;
            try expect(sameThreeComponents(contact.position, state.floor_slot_positions.loadVec(world, slot)));
            try expectEqual(contact.distance, state.floor_slot_distances.load(world, slot));
            try expect(sameThreeComponents(contact.tangent[0], state.floor_slot_first_tangents.loadVec(world, slot)));
            try expect(sameThreeComponents(contact.tangent[1], state.floor_slot_second_tangents.loadVec(world, slot)));
            const geom: u32 = tables.floor_slot_geom.load(slot);
            if (model.geom_shape[geom] == .cylinder) {
                compared.of_cylinders += 1;
            }
        }
        try expectEqual(data.contact_count, pushed);
        compared.contacts += pushed;
    }
    return compared;
}

/// A CLIP FOR THE TESTS: `frame_count` frames of `model`'s coordinates, its reference pose carried along a fixed
/// velocity a little further each frame - valid poses (unit quaternions), each frame different. Owned by the caller.
fn testClipPoses(gpa: Allocator, model: *const robot.Model, frame_count: u32) ![]f32 {
    const coordinate_count: usize = model.coordinate_count;
    const poses: []f32 = try gpa.alloc(f32, frame_count * coordinate_count);
    errdefer gpa.free(poses);
    const velocity: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(velocity);
    for (velocity, 0..) |*rate, dof| {
        const dof_factor: f32 = @floatFromInt(@as(i32, @intCast(dof % 7)) - 3);
        rate.* = 0.3 * dof_factor;
    }
    for (0..frame_count) |frame| {
        const pose: []f32 = poses[frame * coordinate_count ..][0..coordinate_count];
        @memcpy(pose, model.reference_joint_positions);
        const elapsed: f32 = 0.1 * float(frame);
        robot.integratePos(model, pose, velocity, elapsed);
    }
    return poses;
}

/// THE TWIN's SERVO TARGETS FROM THE REFERENCE AGAINST robot_track's: four worlds of `model` following one clip, each
/// at its own frame - the last at the clip's last frame, where the aim is held - with its own action; the twin's
/// `reference_targets`, and robot.zig's `applyAction` then `clampHinges` on each world's aimed pose and action, as
/// `Fleet.driveOnce` forms its targets. Every coordinate equal to the bit. Returns how many coordinates the clamp
/// changed, so a test can see the clamp's path was taken.
fn expectTwinReferenceTargets(gpa: Allocator, model: *const robot.Model) !u32 {
    const world_count: u32 = 4;
    const frame_count: u32 = 5;
    const poses: []f32 = try testClipPoses(gpa, model, frame_count);
    defer gpa.free(poses);
    const clips = [_]robotgpu.ClipPoses{.{ .poses = poses, .frame_count = frame_count, .frame_time = 0.1 }};
    const twin: Twin = try .initTracking(model, world_count, &clips);
    // Large enough to carry many hinges past their ranges.
    const scale: f32 = 2.0;
    robotgpu.g.P.options.action_scale = scale;
    const coordinate_count: usize = model.coordinate_count;
    const action_count: usize = robot.actionSize(model);
    const actions: []f32 = try gpa.alloc(f32, world_count * action_count);
    defer gpa.free(actions);
    const integers: robotgpu.WorldIntegersLayout = twin.layout.world_u;
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        const frame: u32 = if (world == world_count - 1) frame_count - 1 else world;
        integers.world_clip.store(world, 0, 0);
        integers.world_frame.store(world, 0, frame);
        const world_actions: []f32 = actions[world * action_count ..][0..action_count];
        for (world_actions, 0..) |*action, index| {
            // In [-1, 1], as a squashed policy's, different in every world and number.
            const phase: f32 = 1.7 * float(index + 1) + float(world);
            action.* = @sin(phase);
            state.actions.store(world, @intCast(index), action.*);
        }
    }
    // The filter at its default, 1 - no filter: each world's applied action becomes its action exactly.
    Twin.run("filter_actions", world_count * twin.counts.action_count);
    Twin.run("reference_targets", world_count * twin.counts.joint_count);
    const scratch: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(scratch);
    const unclamped: []f32 = try gpa.alloc(f32, coordinate_count);
    defer gpa.free(unclamped);
    const targets: []f32 = try gpa.alloc(f32, coordinate_count);
    defer gpa.free(targets);
    var clamped_coordinates: u32 = 0;
    world = 0;
    while (world < world_count) : (world += 1) {
        const frame: u32 = integers.world_frame.load(world, 0);
        const aimed_frame: usize = @min(frame + 1, frame_count - 1);
        const reference: []const f32 = poses[aimed_frame * coordinate_count ..][0..coordinate_count];
        const world_actions: []const f32 = actions[world * action_count ..][0..action_count];
        robot.applyAction(model, reference, world_actions, scale, scratch, unclamped);
        @memcpy(targets, unclamped);
        robot.clampHinges(model, targets);
        for (targets, unclamped, 0..) |target, before_clamp, coordinate| {
            try expectEqual(target, state.servo_targets.load(world, @intCast(coordinate)));
            if (target != before_clamp) {
                clamped_coordinates += 1;
            }
        }
    }
    return clamped_coordinates;
}

test "robotgpu: the twin's servo targets from the reference are robot.zig's, bit for bit - Geno and the humanoid" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    // Geno's balls turned by their actions; the humanoid's hinges, many carried past their ranges and clamped.
    _ = try expectTwinReferenceTargets(gpa, &fixtures.geno.model);
    const humanoid_clamped: u32 = try expectTwinReferenceTargets(gpa, &fixtures.humanoid.model);
    try expect(humanoid_clamped > 0);
}

test "robotgpu: the twin's lowest points are robot.zig's, bit for bit - Geno and the humanoid" {
    // Four posed worlds of each model; the observation program on the twin (its kinematics) and the judgement program
    // (each body's lowest point), and robot.zig's `bodyLowestPoints` after `forward` on each world: every body's
    // height equal to the bit.
    // The KUKA's links are hulls, whose points the device does not pack - as its floor contacts take no hulls - so it
    // is left out: on the device a hull has no lowest point.
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const models = [_]*const robot.Model{ &fixtures.geno.model, &fixtures.humanoid.model };
    for (models) |model| {
        const world_count: u32 = 4;
        const twin: Twin = try .init(model, world_count);
        giveTwinWorldsInputs(model, twin, world_count);
        twin.runProgram(&robotgpu.observe_program);
        twin.runProgram(&robotgpu.judge_program);
        var data: robot.Data = try .init(gpa, model);
        defer data.deinit();
        const heights: []f32 = try gpa.alloc(f32, model.body_count);
        defer gpa.free(heights);
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            giveRobotWorldInputs(model, &data, world);
            robot.forward(model, &data);
            robot.bodyLowestPoints(model, &data, heights);
            for (heights, 0..) |height, body| {
                try expectEqual(height, twin.layout.world_f.body_lowest_points.load(world, @intCast(body)));
            }
        }
    }
}

test "robotgpu: the limbs from the tree - Geno six, the humanoid's, the KUKA one; the free root's dofs none" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const Expected = struct { model: *const robot.Model, limb_count: u32, dofs_in_limbs: []const u32 };
    const cases = [_]Expected{
        // Geno, in the order his model's dofs come: the spine (Spine to Spine3), the neck with the head, the right
        // arm, the left arm, the right leg, the left leg.
        .{ .model = &fixtures.geno.model, .limb_count = 6, .dofs_in_limbs = &.{ 12, 9, 12, 12, 12, 12 } },
        .{ .model = &fixtures.kuka, .limb_count = 1, .dofs_in_limbs = &.{7} },
    };
    for (cases) |case| {
        const model: *const robot.Model = case.model;
        const limb_of_dof: []u32 = try gpa.alloc(u32, model.dof_count);
        defer gpa.free(limb_of_dof);
        const limb_starting_at: []u32 = try gpa.alloc(u32, model.body_count);
        defer gpa.free(limb_starting_at);
        const limb_count: u32 = robot.dofLimbs(model, limb_of_dof, limb_starting_at);
        try expectEqual(case.limb_count, limb_count);
        for (case.dofs_in_limbs, 0..) |dofs_wanted, limb| {
            var dofs_found: u32 = 0;
            for (limb_of_dof) |dof_limb| {
                if (dof_limb == limb) {
                    dofs_found += 1;
                }
            }
            try expectEqual(dofs_wanted, dofs_found);
        }
        // The free root's dofs belong to no limb.
        for (limb_of_dof[0..robot.rootDofCount(model)]) |dof_limb| {
            try expectEqual(robot.no_limb, dof_limb);
        }
    }
    // The humanoid: every dof below its free root in some limb.
    const humanoid: *const robot.Model = &fixtures.humanoid.model;
    const humanoid_limbs: []u32 = try gpa.alloc(u32, humanoid.dof_count);
    defer gpa.free(humanoid_limbs);
    const humanoid_starts: []u32 = try gpa.alloc(u32, humanoid.body_count);
    defer gpa.free(humanoid_starts);
    const humanoid_limb_count: u32 = robot.dofLimbs(humanoid, humanoid_limbs, humanoid_starts);
    try expect(humanoid_limb_count >= 4);
    for (humanoid_limbs[robot.rootDofCount(humanoid)..]) |dof_limb| {
        try expect(dof_limb < humanoid_limb_count);
    }
}

test "robotgpu: a limb's stiffness of zero is the servo without it, to the bit; s spans a factor of 3 in stiffness" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const model: *const robot.Model = &fixtures.geno.model;
    // The spring's frequency: exactly the law's at 0; its square - the stiffness - three times as large at 1 as at -1.
    const tuned: f32 = 20.0;
    try expectEqual(tuned, robot.limbSpringFrequency(tuned, 0.0));
    const stiffest: f32 = robot.limbSpringFrequency(tuned, 1.0);
    const softest: f32 = robot.limbSpringFrequency(tuned, -1.0);
    try expectApproxEqAbs(@as(f32, 3.0), (stiffest * stiffest) / (softest * softest), 1.0e-5);
    // Geno's servo with every limb at zero against the servo with no limbs: the same torques, to the bit.
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    @memcpy(data.joint_positions, model.reference_joint_positions);
    for (data.joint_velocities, 0..) |*rate, dof| {
        rate.* = 0.1 * float(dof % 5);
    }
    robot.forward(model, &data);
    const targets: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(targets);
    @memcpy(targets, model.reference_joint_positions);
    const offsets: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(offsets);
    for (offsets, 0..) |*offset, dof| {
        offset.* = if (dof < robot.rootDofCount(model)) 0 else 0.05 * float(@as(i32, @intCast(dof % 7)) - 3);
    }
    robot.integratePos(model, targets, offsets, 1.0);
    const limb_of_dof: []u32 = try gpa.alloc(u32, model.dof_count);
    defer gpa.free(limb_of_dof);
    const limb_starting_at: []u32 = try gpa.alloc(u32, model.body_count);
    defer gpa.free(limb_starting_at);
    const limb_count: u32 = robot.dofLimbs(model, limb_of_dof, limb_starting_at);
    const relaxed: []f32 = try gpa.alloc(f32, limb_count);
    defer gpa.free(relaxed);
    @memset(relaxed, 0);
    const scratches: [5][]f32 = .{
        try gpa.alloc(f32, model.dof_count),
        try gpa.alloc(f32, model.dof_count),
        try gpa.alloc(f32, model.dof_count * model.dof_count),
        try gpa.alloc(f32, model.dof_count),
        try gpa.alloc(f32, model.dof_count),
    };
    defer for (scratches) |scratch| gpa.free(scratch);
    const without_limbs: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(without_limbs);
    const law: robot.ServoLaw = .{ .frequency = tuned, .damping = 1.0, .max_acceleration = 3000.0 };
    const dt: f32 = model.opt.timestep;
    robot.servoTorques(
        model,
        &data,
        targets,
        null,
        law,
        null,
        dt,
        scratches[0],
        scratches[1],
        scratches[2],
        scratches[3],
        without_limbs,
    );
    const at_zero: robot.LimbStiffness = .{ .limb_of_dof = limb_of_dof, .stiffness = relaxed };
    robot.servoTorques(
        model,
        &data,
        targets,
        null,
        law,
        at_zero,
        dt,
        scratches[0],
        scratches[1],
        scratches[2],
        scratches[3],
        scratches[4],
    );
    try expectEqualSlices(f32, without_limbs, scratches[4]);
}

test "robotgpu: the twin's action filter is robot.zig's, bit for bit - three physics steps at 0.5, from rest" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const model: *const robot.Model = &fixtures.geno.model;
    const frame_count: u32 = 2;
    const poses: []f32 = try testClipPoses(gpa, model, frame_count);
    defer gpa.free(poses);
    const clips = [_]robotgpu.ClipPoses{.{ .poses = poses, .frame_count = frame_count, .frame_time = 0.1 }};
    const world_count: u32 = 3;
    const twin: Twin = try .initTracking(model, world_count, &clips);
    const factor: f32 = 0.5;
    robotgpu.g.P.options.action_filter = factor;
    const action_count: usize = robot.actionSize(model);
    const asked: []f32 = try gpa.alloc(f32, world_count * action_count);
    defer gpa.free(asked);
    const applied: []f32 = try gpa.alloc(f32, world_count * action_count);
    defer gpa.free(applied);
    @memset(applied, 0);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    for (asked, 0..) |*action, number| {
        const phase: f32 = 0.9 * float(number + 1);
        action.* = @sin(phase);
        const world: u32 = @intCast(number / action_count);
        state.actions.store(world, @intCast(number % action_count), action.*);
    }
    const physics_steps: u32 = 3;
    var physics_step: u32 = 0;
    while (physics_step < physics_steps) : (physics_step += 1) {
        Twin.run("filter_actions", world_count * twin.counts.action_count);
        robot.filterAction(factor, asked, applied);
    }
    for (applied, 0..) |expected, number| {
        const world: u32 = @intCast(number / action_count);
        try expectEqual(expected, state.applied_actions.load(world, @intCast(number % action_count)));
    }
    // From rest, three halvings: seven eighths of the way.
    try expectApproxEqAbs(0.875 * asked[0], applied[0], 1.0e-6);
}

test "robotgpu: each world's frame advanced a frame by the twin's clock" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const model: *const robot.Model = &fixtures.geno.model;
    const frame_count: u32 = 3;
    const poses: []f32 = try testClipPoses(gpa, model, frame_count);
    defer gpa.free(poses);
    const clips = [_]robotgpu.ClipPoses{.{ .poses = poses, .frame_count = frame_count, .frame_time = 0.1 }};
    const world_count: u32 = 3;
    const twin: Twin = try .initTracking(model, world_count, &clips);
    const integers: robotgpu.WorldIntegersLayout = twin.layout.world_u;
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        integers.world_frame.store(world, 0, 10 * world);
    }
    Twin.run("advance_frames", world_count);
    world = 0;
    while (world < world_count) : (world += 1) {
        try expectEqual(10 * world + 1, integers.world_frame.load(world, 0));
    }
}

test "robotgpu: the floor's contacts on the twin are robot.zig's, bit for bit - Geno, the humanoid and the Go1" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    // The Go1 for its cylinders: its hip guards, at its trunk's height, cut the floor there.
    var go1: robot_import.Imported = try modelFromMjcf(gpa, go1_xml);
    defer go1.deinit();
    const models = [_]*const robot.Model{ &fixtures.geno.model, &fixtures.humanoid.model, &go1.model };
    for (models) |model| {
        const compared: FloorContactsCompared = try expectTwinFloorContacts(gpa, model);
        // Contacts were made and compared - or the test would pass on a floor that touched nothing.
        try expect(compared.contacts > 0);
    }
    const go1_compared: FloorContactsCompared = try expectTwinFloorContacts(gpa, &go1.model);
    try expect(go1_compared.of_cylinders > 0);
}

/// THE TWIN's SERVO AGAINST robot.zig's: four worlds of `model` given their inputs, each its own target - the reference
/// pose moved a little, otherwise in each world - and, toward motion, its own target velocities; the twin's step run up
/// to its servo's torques, and robot.zig's `servoTorques` on each world after `forward` (its mass matrix and bias
/// forces at the world's state). Every torque equal to the bit, a free root's six zero on both. With `limb_stiffness`
/// on, each world's limbs at their own stiffness - after the joints' numbers in its applied action, and given to
/// robot.zig's servo as a `LimbStiffness`.
fn expectTwinServo(
    gpa: Allocator,
    model: *const robot.Model,
    mode: robotgpu.ServoMode,
    limb_stiffness: robotgpu.Switch,
) !void {
    const world_count: u32 = 4;
    const law: robot.ServoLaw = .{ .frequency = 20.0, .damping = 1.0, .max_acceleration = 3000.0 };
    const twin: Twin = try .init(model, world_count);
    robotgpu.g.P.options.setServo(law, mode);
    robotgpu.g.P.options.setLimbStiffness(limb_stiffness);
    giveTwinWorldsInputs(model, twin, world_count);
    // Each world's limbs at their own stiffness, in [-1, 1], after the joints' numbers in its applied action.
    const joint_numbers: u32 = twin.counts.action_count - twin.counts.limb_count;
    const stiffness: []f32 = try gpa.alloc(f32, world_count * model.limb_count);
    defer gpa.free(stiffness);
    for (stiffness, 0..) |*limb_stiffness_number, number| {
        const phase: f32 = 1.3 * float(number + 1);
        limb_stiffness_number.* = @sin(phase);
        const world: u32 = @intCast(number / model.limb_count);
        const limb: u32 = @intCast(number % model.limb_count);
        twin.layout.world_f.applied_actions.store(world, joint_numbers + limb, limb_stiffness_number.*);
    }
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    const targets: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(targets);
    const target_velocities: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(target_velocities);
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    const dof_count: usize = model.dof_count;
    const accel_scratch: []f32 = try gpa.alloc(f32, dof_count);
    defer gpa.free(accel_scratch);
    const scratch: []f32 = try gpa.alloc(f32, dof_count);
    defer gpa.free(scratch);
    const dense: []f32 = try gpa.alloc(f32, dof_count * dof_count);
    defer gpa.free(dense);
    const full: []f32 = try gpa.alloc(f32, dof_count);
    defer gpa.free(full);
    const torques: []f32 = try gpa.alloc(f32, dof_count);
    defer gpa.free(torques);
    // Each world's target and target velocities, the same numbers given to both engines.
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        const world_factor: f32 = @floatFromInt(world + 1);
        for (targets, model.reference_joint_positions, 0..) |*target, reference, coordinate| {
            const coordinate_factor: f32 = @floatFromInt(@as(i32, @intCast(coordinate % 5)) - 2);
            target.* = reference + 0.05 * coordinate_factor * world_factor;
            state.servo_targets.store(world, @intCast(coordinate), target.*);
        }
        for (target_velocities, 0..) |*target_velocity, dof| {
            const dof_factor: f32 = @floatFromInt(@as(i32, @intCast(dof % 3)) - 1);
            target_velocity.* = 0.1 * dof_factor * world_factor;
            state.servo_target_velocities.store(world, @intCast(dof), target_velocity.*);
        }
    }
    runTwinStepThrough(twin, "servo_torques");
    world = 0;
    while (world < world_count) : (world += 1) {
        const world_factor: f32 = @floatFromInt(world + 1);
        for (targets, model.reference_joint_positions, 0..) |*target, reference, coordinate| {
            const coordinate_factor: f32 = @floatFromInt(@as(i32, @intCast(coordinate % 5)) - 2);
            target.* = reference + 0.05 * coordinate_factor * world_factor;
        }
        for (target_velocities, 0..) |*target_velocity, dof| {
            const dof_factor: f32 = @floatFromInt(@as(i32, @intCast(dof % 3)) - 1);
            target_velocity.* = 0.1 * dof_factor * world_factor;
        }
        giveRobotWorldInputs(model, &data, world);
        robot.forward(model, &data);
        const moving: ?[]const f32 = if (mode == .toward_motion) target_velocities else null;
        const dt: f32 = model.opt.timestep;
        const world_limbs: robot.LimbStiffness = .{
            .limb_of_dof = model.dof_limb,
            .stiffness = stiffness[world * model.limb_count ..][0..model.limb_count],
        };
        const limbs: ?robot.LimbStiffness = if (limb_stiffness == .enabled) world_limbs else null;
        robot.servoTorques(model, &data, targets, moving, law, limbs, dt, accel_scratch, scratch, dense, full, torques);
        for (torques, 0..) |robot_torque, dof| {
            try expectEqual(robot_torque, state.applied_joint_forces.load(world, @intCast(dof)));
        }
    }
}

test "robotgpu: the twin's servo is robot.zig's, bit for bit - Geno, humanoid and KUKA, rest and motion, limbs too" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const models = [_]*const robot.Model{ &fixtures.geno.model, &fixtures.humanoid.model, &fixtures.kuka };
    for (models) |model| {
        for ([_]robotgpu.ServoMode{ .toward_rest, .toward_motion }) |mode| {
            // The law's one frequency, and each limb at its own stiffness.
            try expectTwinServo(gpa, model, mode, .disabled);
            try expectTwinServo(gpa, model, mode, .enabled);
        }
    }
}

/// What a stepped comparison exercised: the rows the twin's last step made and the rounds Newton took for them, summed
/// over the worlds - so a test can require that the constraints were met, not merely that nothing differed.
const ConstrainedStepsSeen = struct {
    rows: u32 = 0,
    rounds: u32 = 0,
};

/// THE TWIN STEPPED ONTO ITS LIMITS AGAINST robot.zig, STEP AFTER STEP: four worlds of `model`, each given its inputs
/// and posed around its joint limits (`limitTestPose`), a 0.05 margin on every ranged joint, the constraints on - the
/// contacts off, as the device makes no contact row yet, and Newton cold or warm (`warm_start`, MuJoCo's warm start:
/// each step's answer the next one's candidate start) - stepped `step_count` times by the whole step program on the
/// twin and by robot.zig's own `step`: every coordinate and velocity equal to the bit at the end. The rows, their
/// projection and Newton's answer are in every step, so any difference in any of them, at any step, would grow and
/// show.
fn expectTwinStepsOnLimits(
    gpa: Allocator,
    simulated: *const robot.Model,
    step_count: u32,
    warm_start: bool,
) !ConstrainedStepsSeen {
    var model: robot.Model = simulated.*;
    for (model.joint_range, model.joint_limit_margin) |range, *margin| {
        if (range != null) {
            margin.* = 0.05;
        }
    }
    model.opt.disable_constraints = false;
    model.opt.max_contacts = 0;
    model.opt.solver.algorithm = .newton;
    model.opt.warm_start = warm_start;
    const world_count: u32 = 4;
    const twin: Twin = try .init(&model, world_count);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    giveTwinWorldsInputs(&model, twin, world_count);
    const pose: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(pose);
    var posed_world: u32 = 0;
    while (posed_world < world_count) : (posed_world += 1) {
        limitTestPose(&model, posed_world, pose);
        for (pose, 0..) |coordinate_value, coordinate| {
            state.joint_positions.store(posed_world, @intCast(coordinate), coordinate_value);
        }
    }
    var twin_step: u32 = 0;
    while (twin_step < step_count) : (twin_step += 1) {
        inline for (robotgpu.step_program) |dispatch| {
            Twin.run(dispatch.kernel, robotgpu.invocationCount(dispatch.invocations, twin.counts));
        }
    }
    var seen: ConstrainedStepsSeen = .{};
    var data: robot.Data = try .init(gpa, &model);
    defer data.deinit();
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        giveRobotWorldInputs(&model, &data, world);
        limitTestPose(&model, world, data.joint_positions);
        // Each world from no warm start, as each of the twin's begins: one `Data` serves every world here, and would
        // hand the next world the last one's answer.
        data.forgetWarmStart();
        var robot_step: u32 = 0;
        while (robot_step < step_count) : (robot_step += 1) {
            robot.step(&model, &data);
        }
        for (data.joint_positions, 0..) |robot_position, coordinate| {
            try expectEqual(robot_position, state.joint_positions.load(world, @intCast(coordinate)));
        }
        for (data.joint_velocities, 0..) |robot_velocity, dof| {
            try expectEqual(robot_velocity, state.joint_velocities.load(world, @intCast(dof)));
        }
        // The last step's rows and rounds, the same on both - then counted.
        const twin_rows: u32 = twin.layout.world_u.constraint_row_count.load(world, 0);
        const twin_rounds: u32 = twin.layout.world_u.newton_iterations.load(world, 0);
        try expectEqual(data.constraint_count, twin_rows);
        try expectEqual(data.solver_iterations, twin_rounds);
        seen.rows += twin_rows;
        seen.rounds += twin_rounds;
    }
    return seen;
}

/// THE TWIN STEPPED ON THE FLOOR AGAINST robot.zig, STEP AFTER STEP: four worlds of `model` given their inputs, a
/// floor a centimetre above the first world's lowest point - so the robot stands in it from the first step - the
/// constraints on or off (`constraints`: off, robot.zig makes no row, its floor's included) and Newton cold or warm
/// (`warm_start`), stepped `step_count` times: the twin by the whole step
/// program with its floor, robot.zig by posing its bodies, pushing its floor's contacts (`pushFloorContacts`) and
/// stepping. Every coordinate and velocity equal to the bit at the end, and the last step's rows and rounds; returns
/// robot.zig's rows and rounds over every step of every world. The contacts' rows, their projection and Newton's
/// answer with them are in the steps, so a difference in any would grow and show.
fn expectTwinStepsOnFloor(
    gpa: Allocator,
    simulated: *const robot.Model,
    step_count: u32,
    warm_start: bool,
    constraints: robotgpu.Switch,
) !ConstrainedStepsSeen {
    var model: robot.Model = simulated.*;
    model.opt.disable_constraints = constraints == .disabled;
    model.opt.solver.algorithm = .newton;
    model.opt.warm_start = warm_start;
    const world_count: u32 = 4;
    var data: robot.Data = try .init(gpa, &model);
    defer data.deinit();
    // The floor: a centimetre above world 0's lowest point, found under a floor high above everything - where every
    // geom's contact distance is how far its lowest point lies below that floor.
    giveRobotWorldInputs(&model, &data, 0);
    robot.kinematics(&model, &data);
    const probe_height: f32 = 10.0;
    const probe: robot.Floor = .{ .plane = .{ .point = vec(0, 0, probe_height), .normal = vec(0, 0, 1) } };
    data.clearContacts();
    try robot.pushFloorContacts(&model, &data, probe);
    var lowest_distance: f32 = 0;
    for (data.contacts[0..data.contact_count]) |contact| {
        lowest_distance = @min(lowest_distance, contact.distance);
    }
    const floor_height: f32 = probe_height + lowest_distance + 0.01;
    const ground: robot.Floor = .{
        .plane = .{ .point = vec(0, 0, floor_height), .normal = vec(0, 0, 1) },
        .friction = 1.0,
    };
    data.clearContacts();
    const twin: Twin = try .init(&model, world_count);
    robotgpu.g.P.options.floor_contacts = .enabled;
    robotgpu.g.P.options.floor_height = floor_height;
    robotgpu.g.P.options.floor_friction = ground.friction;
    robotgpu.g.P.options.floor_margin = ground.margin;
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    giveTwinWorldsInputs(&model, twin, world_count);
    var twin_step: u32 = 0;
    while (twin_step < step_count) : (twin_step += 1) {
        inline for (robotgpu.step_program) |dispatch| {
            Twin.run(dispatch.kernel, robotgpu.invocationCount(dispatch.invocations, twin.counts));
        }
    }
    var seen: ConstrainedStepsSeen = .{};
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        giveRobotWorldInputs(&model, &data, world);
        // Each world from no warm start, as each of the twin's begins.
        data.forgetWarmStart();
        var robot_step: u32 = 0;
        while (robot_step < step_count) : (robot_step += 1) {
            // The bodies posed where the step begins - the twin's step poses them first too - then the floor's
            // contacts, then the step.
            robot.kinematics(&model, &data);
            data.clearContacts();
            try robot.pushFloorContacts(&model, &data, ground);
            robot.step(&model, &data);
            seen.rows += data.constraint_count;
            seen.rounds += data.solver_iterations;
        }
        for (data.joint_positions, 0..) |robot_position, coordinate| {
            try expectEqual(robot_position, state.joint_positions.load(world, @intCast(coordinate)));
        }
        for (data.joint_velocities, 0..) |robot_velocity, dof| {
            try expectEqual(robot_velocity, state.joint_velocities.load(world, @intCast(dof)));
        }
        // The last step's rows and rounds, the same on both.
        const twin_rows: u32 = twin.layout.world_u.constraint_row_count.load(world, 0);
        const twin_rounds: u32 = twin.layout.world_u.newton_iterations.load(world, 0);
        try expectEqual(data.constraint_count, twin_rows);
        try expectEqual(data.solver_iterations, twin_rounds);
    }
    return seen;
}

test "robotgpu: the twin's step on the floor is robot.zig's, step after step - Geno and the humanoid, warm and cold" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const models = [_]*const robot.Model{ &fixtures.geno.model, &fixtures.humanoid.model };
    for (models) |model| {
        for ([_]bool{ false, true }) |warm_start| {
            const seen: ConstrainedStepsSeen = try expectTwinStepsOnFloor(gpa, model, 10, warm_start, .enabled);
            // Contact rows were made and solved along the way, over rounds of Newton's - on robot.zig, step by step;
            // the twin's trajectory equal to its own says it solved the same.
            try expect(seen.rows > 0 and seen.rounds > 0);
        }
        // The model's constraints disabled: a floor makes no row, on either.
        const unconstrained: ConstrainedStepsSeen = try expectTwinStepsOnFloor(gpa, model, 10, true, .disabled);
        try expectEqual(@as(u32, 0), unconstrained.rows);
    }
}

test "robotgpu: the twin's constrained step is robot.zig's, step after step - the KUKA and humanoid at limits" {
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const models = [_]*robot.Model{ &fixtures.kuka, &fixtures.humanoid.model };
    for (models) |model| {
        for ([_]bool{ false, true }) |warm_start| {
            const seen: ConstrainedStepsSeen = try expectTwinStepsOnLimits(gpa, model, 20, warm_start);
            // Rows were solved at the last step, over rounds of Newton's - or the test would pass on a step without
            // them.
            try expect(seen.rows > 0 and seen.rounds > 0);
        }
    }
}

/// THE TWIN STEPPED AGAINST robot.zig, STEP AFTER STEP: four worlds of `model`, each with its own state and inputs,
/// stepped `step_count` times by the whole step program (`robotgpu.step_program`, the list the device runs), and each
/// world stepped as many times by robot.zig's own `step` - the model's constraints disabled on both, as the device
/// does not simulate them - every coordinate, velocity and activation equal to the bit at the end. Any difference
/// in any kernel, at any step, would grow and show.
fn expectTwinSteps(gpa: Allocator, simulated: *const robot.Model, step_count: u32) !void {
    var model: robot.Model = simulated.*;
    model.opt.disable_constraints = true;
    const world_count: u32 = 4;
    const twin: Twin = try .init(&model, world_count);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    giveTwinWorldsInputs(&model, twin, world_count);
    var twin_step: u32 = 0;
    while (twin_step < step_count) : (twin_step += 1) {
        inline for (robotgpu.step_program) |dispatch| {
            Twin.run(dispatch.kernel, robotgpu.invocationCount(dispatch.invocations, twin.counts));
        }
    }
    var data: robot.Data = try .init(gpa, &model);
    defer data.deinit();
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        giveRobotWorldInputs(&model, &data, world);
        var robot_step: u32 = 0;
        while (robot_step < step_count) : (robot_step += 1) {
            robot.step(&model, &data);
        }
        for (data.joint_positions, 0..) |robot_position, coordinate| {
            try expectEqual(robot_position, state.joint_positions.load(world, @intCast(coordinate)));
        }
        for (data.joint_velocities, 0..) |robot_velocity, dof| {
            try expectEqual(robot_velocity, state.joint_velocities.load(world, @intCast(dof)));
        }
        for (data.activations, 0..) |robot_activation, index| {
            try expectEqual(robot_activation, state.activations.load(world, @intCast(index)));
        }
    }
}

/// The centre-of-mass stage on the twin against robot.zig's `comPos`, world by world: the same pose given to both,
/// every subtree's centre of mass, every body's inertia in its frame and every dof's motion axis, compared bit for bit.
fn expectTwinComPos(gpa: Allocator, simulated: *const robot.Model) !void {
    // The smooth dynamics, stage by stage: the model's constraints disabled, so the step's constraint program makes no
    // row and the step's acceleration is the free one, as robot.zig's stages below compute it.
    var model_value: robot.Model = simulated.*;
    model_value.opt.disable_constraints = true;
    const model: *const robot.Model = &model_value;
    const world_count: u32 = 4;
    const twin: Twin = try .init(model, world_count);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    poseTwinWorlds(model, twin, world_count);
    Twin.run("kinematics_branch", world_count * twin.counts.branch_count);
    Twin.run("subtree_centres_of_mass", world_count);
    Twin.run("body_inertias", world_count * twin.counts.body_count);
    Twin.run("dof_axes", world_count * twin.counts.dof_count);
    Twin.run("composite_inertias", world_count);
    Twin.run("mass_matrix_rows", world_count * twin.counts.dof_count);
    Twin.run("factor_mass_matrix", world_count);
    // Each world's joint velocities, then the velocity pass.
    var rate_world: u32 = 0;
    while (rate_world < world_count) : (rate_world += 1) {
        var rate_dof: u32 = 0;
        while (rate_dof < model.dof_count) : (rate_dof += 1) {
            state.joint_velocities.store(rate_world, rate_dof, testRate(rate_world, rate_dof));
        }
    }
    Twin.run("body_velocities_branch", world_count * twin.counts.branch_count);
    Twin.run("bias_accelerations_branch", world_count * twin.counts.branch_count);
    Twin.run("body_bias_forces", world_count * twin.counts.body_count);
    Twin.run("subtree_bias_forces", world_count);
    Twin.run("bias_joint_forces", world_count * twin.counts.dof_count);
    Twin.run("passive_joint_forces", world_count * twin.counts.dof_count);
    // Each world's controls and activations, then actuation.
    var control_world: u32 = 0;
    while (control_world < world_count) : (control_world += 1) {
        var actuator: u32 = 0;
        while (actuator < model.actuator_count) : (actuator += 1) {
            state.controls.store(control_world, actuator, testControl(control_world, actuator));
        }
        var activation: u32 = 0;
        while (activation < model.activation_count) : (activation += 1) {
            state.activations.store(control_world, activation, testActivation(control_world, activation));
        }
    }
    Twin.run("actuator_forces", world_count * twin.counts.actuator_count);
    Twin.run("actuator_joint_forces", world_count * twin.counts.dof_count);
    // Each world's applied forces, then the smooth forces and the smooth acceleration.
    var force_world: u32 = 0;
    while (force_world < world_count) : (force_world += 1) {
        var force_dof: u32 = 0;
        while (force_dof < model.dof_count) : (force_dof += 1) {
            state.applied_joint_forces.store(force_world, force_dof, testForce(force_world, force_dof));
        }
    }
    Twin.run("smooth_joint_forces", world_count * twin.counts.dof_count);
    Twin.run("solve_smooth_acceleration", world_count);
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        robotThroughForwardDynamics(model, &data, world);
        // Every actuator's length, velocity and force, every activation's rate, every dof's actuator force (robot.zig's
        // `actuation`).
        for (data.actuator_lengths, data.actuator_velocities, data.actuator_forces, 0..) |
            robot_length,
            robot_velocity,
            robot_force,
            actuator,
        | {
            const actuator_index: u32 = @intCast(actuator);
            try expectEqual(robot_length, state.actuator_lengths.load(world, actuator_index));
            try expectEqual(robot_velocity, state.actuator_velocities.load(world, actuator_index));
            try expectEqual(robot_force, state.actuator_forces.load(world, actuator_index));
        }
        for (data.activation_rates, 0..) |robot_rate, index| {
            try expectEqual(robot_rate, state.activation_rates.load(world, @intCast(index)));
        }
        for (data.actuator_joint_forces, 0..) |robot_joint_force, dof| {
            try expectEqual(robot_joint_force, state.actuator_joint_forces.load(world, @intCast(dof)));
        }
        // Every dof's smooth force, in robot.zig's order, and the smooth acceleration (robot.zig's `forwardDynamics`).
        var dof_index: u32 = 0;
        while (dof_index < model.dof_count) : (dof_index += 1) {
            const applied_force: f32 = data.applied_joint_forces[dof_index];
            const actuator_force: f32 = data.actuator_joint_forces[dof_index];
            const passive_force: f32 = data.passive_joint_forces[dof_index];
            const bias_force: f32 = data.bias_joint_forces[dof_index];
            const robot_smooth_force: f32 = applied_force + actuator_force + passive_force - bias_force;
            try expectEqual(robot_smooth_force, state.smooth_joint_forces.load(world, dof_index));
        }
        for (data.joint_accelerations, 0..) |robot_acceleration, dof| {
            try expectEqual(robot_acceleration, state.smooth_joint_accelerations.load(world, @intCast(dof)));
        }
        // Every dof's passive force (robot.zig's `passive`).
        for (data.passive_joint_forces, 0..) |robot_passive, dof| {
            try expectEqual(robot_passive, state.passive_joint_forces.load(world, @intCast(dof)));
        }
        // Every body's acceleration, every subtree's force, every dof's bias force (robot.zig's `rne`).
        var force_body: u32 = 0;
        while (force_body < model.body_count) : (force_body += 1) {
            const twin_acceleration: robot.Motion = state.body_bias_accelerations.loadMotion(world, force_body);
            const robot_acceleration: robot.Motion = data.body_bias_accelerations[force_body];
            try expect(@reduce(.And, twin_acceleration.ang == robot_acceleration.ang));
            try expect(@reduce(.And, twin_acceleration.lin == robot_acceleration.lin));
            const twin_force: robot.Force = state.subtree_bias_forces.loadForce(world, force_body);
            const robot_force: robot.Force = data.subtree_bias_forces[force_body];
            try expect(@reduce(.And, twin_force.ang == robot_force.ang));
            try expect(@reduce(.And, twin_force.lin == robot_force.lin));
        }
        for (data.bias_joint_forces, 0..) |robot_bias, dof| {
            try expectEqual(robot_bias, state.bias_joint_forces.load(world, @intCast(dof)));
        }
        // Every body's velocity and every dof's axis rate (robot.zig's `comVel`).
        var velocity_body: u32 = 0;
        while (velocity_body < model.body_count) : (velocity_body += 1) {
            const twin_velocity: robot.Motion = state.body_velocities.loadMotion(world, velocity_body);
            const robot_velocity: robot.Motion = data.body_velocities[velocity_body];
            try expect(@reduce(.And, twin_velocity.ang == robot_velocity.ang));
            try expect(@reduce(.And, twin_velocity.lin == robot_velocity.lin));
        }
        var rate_dof: u32 = 0;
        while (rate_dof < model.dof_count) : (rate_dof += 1) {
            const twin_axis_rate: robot.Motion = state.dof_axis_rates.loadMotion(world, rate_dof);
            const robot_axis_rate: robot.Motion = data.dof_axis_rates[rate_dof];
            try expect(@reduce(.And, twin_axis_rate.ang == robot_axis_rate.ang));
            try expect(@reduce(.And, twin_axis_rate.lin == robot_axis_rate.lin));
        }
        // The factor, its inverse pivots, and the smooth acceleration (robot.zig's `factorM` and `solveM`).
        for (data.mass_factor, 0..) |robot_factor, entry| {
            try expectEqual(robot_factor, state.mass_factor.load(world, @intCast(entry)));
        }
        for (data.mass_factor_inverse_diagonal, 0..) |robot_inverse_pivot, dof| {
            try expectEqual(robot_inverse_pivot, state.mass_factor_inverse_diagonal.load(world, @intCast(dof)));
        }
        var body: u32 = 0;
        while (body < model.body_count) : (body += 1) {
            const twin_centre: Vec = state.subtree_centres_of_mass.loadVec(world, body);
            const robot_centre: Vec = data.subtree_centres_of_mass[body];
            try expect(@reduce(.And, twin_centre == robot_centre));
            const twin_inertia: robot.Inertia = state.body_inertias.loadInertia(world, body);
            const robot_inertia: robot.Inertia = data.body_inertias[body];
            try expect(@reduce(.And, twin_inertia.diag == robot_inertia.diag));
            try expect(@reduce(.And, twin_inertia.off == robot_inertia.off));
            try expect(@reduce(.And, twin_inertia.h == robot_inertia.h));
            try expectEqual(robot_inertia.mass, twin_inertia.mass);
        }
        // The composite inertias and the mass matrix's stored entries (robot.zig's `crb`).
        body = 0;
        while (body < model.body_count) : (body += 1) {
            const twin_composite: robot.Inertia = state.composite_inertias.loadInertia(world, body);
            const robot_composite: robot.Inertia = data.composite_inertias[body];
            try expect(@reduce(.And, twin_composite.diag == robot_composite.diag));
            try expect(@reduce(.And, twin_composite.off == robot_composite.off));
            try expect(@reduce(.And, twin_composite.h == robot_composite.h));
            try expectEqual(robot_composite.mass, twin_composite.mass);
        }
        for (data.mass_matrix, 0..) |robot_entry, entry_index| {
            try expectEqual(robot_entry, state.mass_matrix.load(world, @intCast(entry_index)));
        }
        var dof: u32 = 0;
        while (dof < model.dof_count) : (dof += 1) {
            const twin_axis: robot.Motion = state.dof_axes.loadMotion(world, dof);
            try expect(@reduce(.And, twin_axis.ang == data.dof_axes[dof].ang));
            try expect(@reduce(.And, twin_axis.lin == data.dof_axes[dof].lin));
        }
    }
    // The constraint program, as the step runs it - no row, so Newton keeps each world's free acceleration - then the
    // velocity update and the advance, compared last, once every earlier stage has been.
    inline for (robotgpu.constraint_program) |dispatch| {
        Twin.run(dispatch.kernel, robotgpu.invocationCount(dispatch.invocations, twin.counts));
    }
    Twin.run("damped_velocity_changes", world_count);
    Twin.run("next_velocities", world_count * twin.counts.dof_count);
    Twin.run("next_activations", world_count * twin.counts.activation_count);
    Twin.run("bound_velocities", world_count * twin.counts.dof_count);
    Twin.run("next_positions", world_count * twin.counts.joint_count);
    var velocity_world: u32 = 0;
    while (velocity_world < world_count) : (velocity_world += 1) {
        robotThroughForwardDynamics(model, &data, velocity_world);
        robot.advanceEuler(model, &data, model.opt.timestep);
        if (model.has_dof_damping) {
            for (data.implicit_rhs, 0..) |robot_change, dof| {
                try expectEqual(robot_change, state.velocity_changes.load(velocity_world, @intCast(dof)));
            }
            // M's own factor, untouched on the twin - robot.zig refactors M to restore it.
            for (data.mass_factor, 0..) |robot_factor, entry| {
                try expectEqual(robot_factor, state.mass_factor.load(velocity_world, @intCast(entry)));
            }
        }
        for (data.joint_velocities, 0..) |robot_velocity, dof| {
            try expectEqual(robot_velocity, state.joint_velocities.load(velocity_world, @intCast(dof)));
        }
        // The rest of the advance (robot.zig's `advanceEuler`): the activations and every coordinate.
        for (data.activations, 0..) |robot_activation, index| {
            try expectEqual(robot_activation, state.activations.load(velocity_world, @intCast(index)));
        }
        for (data.joint_positions, 0..) |robot_position, coordinate| {
            try expectEqual(robot_position, state.joint_positions.load(velocity_world, @intCast(coordinate)));
        }
    }
}

test "robotgpu: on the twin, the dynamics after kinematics match robot.zig, bit for bit" {
    const gpa: Allocator = testing_allocator;
    var kuka_model: robot.Model = try kuka.Model.build(gpa);
    defer kuka_model.deinit();
    try expectTwinComPos(gpa, &kuka_model);
    // The same arm without damping - every fixture has damping, so this is what takes the velocity update's explicit
    // path, `velocity + dt * acceleration`. A shallow copy: only the damping and its flag change.
    const no_damping: []f32 = try gpa.alloc(f32, kuka_model.joint_count);
    defer gpa.free(no_damping);
    @memset(no_damping, 0);
    var undamped_kuka: robot.Model = kuka_model;
    undamped_kuka.joint_damping = no_damping;
    undamped_kuka.has_dof_damping = false;
    try expectTwinComPos(gpa, &undamped_kuka);
    var humanoid: robot_import.Imported = try modelFromMjcf(gpa, humanoid_xml);
    defer humanoid.deinit();
    try expectTwinComPos(gpa, &humanoid.model);
    var geno: robot_import.Imported = try modelFromMjcf(gpa, geno_xml);
    defer geno.deinit();
    try expectTwinComPos(gpa, &geno.model);
}

test "robotgpu: the twin steps as robot.zig does, every world to the bit after twenty steps" {
    const gpa: Allocator = testing_allocator;
    const step_count: u32 = 20;
    // The simple models, one mechanism each.
    const simple_models = [_][]const u8{ single_pendulum_xml, double_pendulum_xml, free_body_xml, ball_chain_xml };
    for (simple_models) |source| {
        var simple: robot_import.Imported = try modelFromMjcf(gpa, source);
        defer simple.deinit();
        try expectTwinSteps(gpa, &simple.model, step_count);
    }
    var kuka_model: robot.Model = try kuka.Model.build(gpa);
    defer kuka_model.deinit();
    try expectTwinSteps(gpa, &kuka_model, step_count);
    // The same arm without damping: the velocity update's explicit path, step after step.
    const no_damping: []f32 = try gpa.alloc(f32, kuka_model.joint_count);
    defer gpa.free(no_damping);
    @memset(no_damping, 0);
    var undamped_kuka: robot.Model = kuka_model;
    undamped_kuka.joint_damping = no_damping;
    undamped_kuka.has_dof_damping = false;
    try expectTwinSteps(gpa, &undamped_kuka, step_count);
    var humanoid: robot_import.Imported = try modelFromMjcf(gpa, humanoid_xml);
    defer humanoid.deinit();
    try expectTwinSteps(gpa, &humanoid.model, step_count);
    var geno: robot_import.Imported = try modelFromMjcf(gpa, geno_xml);
    defer geno.deinit();
    try expectTwinSteps(gpa, &geno.model, step_count);
}

test "Newton's warm start: the humanoid stepping into its limits - each state's answer the same either way" {
    // Each state solved twice, from the free acceleration and from the last step's, then stepped on the warm answer:
    // the same lowest point either way, to f32's convergence. (`forward` keeps no warm start - only `step` does - so
    // the cold solve leaves the warm one's start alone.) NOT fewer rounds: here the warm start costs them - 181 against
    // 166, measured Nov 3 - for the reason under `solveNewton`'s THE START; the Go1's test is where it saves them.
    const gpa: Allocator = testing_allocator;
    var fixtures: Fixtures = try .load(gpa);
    defer fixtures.deinit();
    const model: *robot.Model = &fixtures.humanoid.model;
    for (model.joint_range, model.joint_limit_margin) |range, *margin| {
        if (range != null) {
            margin.* = 0.05;
        }
    }
    model.opt.solver.algorithm = .newton;
    var data: robot.Data = try .init(gpa, model);
    defer data.deinit();
    giveRobotWorldInputs(model, &data, 0);
    limitTestPose(model, 0, data.joint_positions);
    const cold_answer: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(cold_answer);
    var cold_rounds: u32 = 0;
    var warm_rounds: u32 = 0;
    var largest_gap: f32 = 0;
    var steps_with_rows: u32 = 0;
    for (0..100) |_| {
        model.opt.warm_start = false;
        robot.forward(model, &data);
        @memcpy(cold_answer, data.joint_accelerations);
        cold_rounds += data.solver_iterations;
        model.opt.warm_start = true;
        robot.step(model, &data);
        warm_rounds += data.solver_iterations;
        steps_with_rows += @intFromBool(data.constraint_count > 0);
        var largest: f32 = 0;
        var gap: f32 = 0;
        for (cold_answer, data.warmstart_accelerations) |cold, warm| {
            largest = @max(largest, @abs(cold));
            gap = @max(gap, @abs(warm - cold));
        }
        largest_gap = @max(largest_gap, gap / @max(largest, 1.0));
    }
    // The run had rows to solve, both starts were solved, and the answers agree.
    try expect(steps_with_rows > 50);
    try expect(cold_rounds > 0 and warm_rounds > 0);
    try expect(largest_gap < 1.0e-4);
}
