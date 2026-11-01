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
const expectError = std.testing.expectError;
const sliceAsBytes = std.mem.sliceAsBytes;
const sortSlice = std.mem.sort;
const vec = zm.vec;
const Vec = zm.Vec;

const humanoid_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
const geno_xml: []const u8 = @embedFile("tests/fixtures/robot/geno.xml");

/// A robot from an MJCF fixture, through the importer the robot family uses.
fn modelFromMjcf(gpa: Allocator, source: []const u8) !robot_import.Imported {
    const options: robot.Options = .{
        .max_contacts = 128,
        .timestep = 1.0 / 500.0,
        .gravity = vec(0, 0, -9.81),
    };
    return robot_import.importSource(gpa, source, options);
}

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
        try expectArenaLayout(robotgpu.WorldStateLayout, layout.world_f, counts.nworld, capacities.world_f);
        try expectArenaLayout(robotgpu.WorldIntegersLayout, layout.world_u, counts.nworld, capacities.world_u);
        try expectArenaLayout(robotgpu.ModelTablesLayout, layout.model_u, counts.nworld, capacities.model_u);
        try expectArenaLayout(robotgpu.ModelConstantsLayout, layout.model_f, counts.nworld, capacities.model_f);
    }
}

test "robotgpu: an arena too small for its arrays is refused by the arena's name" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    const geno: robotgpu.Counts = robotgpu.countsOf(&fixtures.geno.model, 64);
    try expectError(robotgpu.LayoutError.WorldStateTooSmall, robotgpu.layoutFor(geno, .{ .world_f = 1000 }));
    try expectError(robotgpu.LayoutError.WorldIntegersTooSmall, robotgpu.layoutFor(geno, .{ .world_u = 10 }));
    try expectError(robotgpu.LayoutError.ModelTablesTooSmall, robotgpu.layoutFor(geno, .{ .model_u = 10 }));
    try expectError(robotgpu.LayoutError.ModelConstantsTooSmall, robotgpu.layoutFor(geno, .{ .model_f = 10 }));
}

test "robotgpu: world-major indexing - a world's items together, the worlds one after another" {
    var fixtures: Fixtures = try .load(testing_allocator);
    defer fixtures.deinit();
    const geno: robotgpu.Counts = robotgpu.countsOf(&fixtures.geno.model, 64);
    const layout: robotgpu.Layout = try robotgpu.layoutFor(geno, .{});
    // xpos: Geno's 25 bodies, a vector of four floats each - a stride of 100.
    const xpos: robotgpu.WorldArray(.world_f, .body_vectors) = layout.world_f.xpos;
    try expectEqual(@as(u32, 25), geno.nbody);
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
    const xpos: robotgpu.WorldArray(.world_f, .body_vectors) = layout.world_f.xpos;
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
        "body_jnt_adr",
        "body_jnt_num",
        "body_dof_adr",
        "body_dof_num",
        "jnt_body",
        "jnt_qpos_adr",
        "jnt_dof_adr",
        "dof_parent",
        "dof_body",
        "dof_jnt",
        "mass_row_nonzeros",
        "mass_row_start",
        "mass_col_index",
        "geom_body",
        "site_body",
    };
    inline for (copied_table_names) |table_name| {
        const Table: type = @FieldType(robotgpu.ModelTablesLayout, table_name);
        const table: Table = @field(tables, table_name);
        const model_table: []const u32 = @field(model, table_name);
        try expect(eql(u32, table.within(model_u), model_table));
    }
    for (model.jnt_type, 0..) |joint_type, joint| {
        try expectEqual(@as(u32, @backingInt(joint_type)), tables.jnt_type.load(@intCast(joint)));
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
        "body_pos",
        "body_rot",
        "body_ipos",
        "jnt_axis",
        "jnt_pos",
        "geom_pos",
        "geom_rot",
        "site_pos",
        "site_rot",
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
        "body_mass",
        "body_subtree_mass",
        "jnt_limit_margin",
        "jnt_damping",
        "jnt_stiffness",
        "jnt_ref",
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
    for (model.body_inertia, 0..) |inertia, body| {
        const packed_inertia: robot.Inertia = constants.body_inertia.loadInertia(@intCast(body));
        try expect(@reduce(.And, packed_inertia.diag == inertia.diag));
        try expect(@reduce(.And, packed_inertia.off == inertia.off));
        try expect(@reduce(.And, packed_inertia.h == inertia.h));
        try expectEqual(inertia.mass, packed_inertia.mass);
    }
    const ranges: []const ?[2]f32 = model.jnt_range;
    for (ranges, model.jnt_limit_softness, model.jnt_limit_impedance, 0..) |range, softness, impedance, joint| {
        const joint_index: u32 = @intCast(joint);
        const limited: bool = tables.jnt_limited.load(joint_index) == 1;
        try expectEqual(range != null, limited);
        const expected_range: [2]f32 = range orelse .{ 0, 0 };
        const packed_range: []const f32 = model_f[constants.jnt_range.at(joint_index)..][0..2];
        try expect(eql(f32, packed_range, &expected_range));
        const expected_softness: [2]f32 = .{ softness.time_const_s, softness.damp_ratio };
        const packed_softness: []const f32 = model_f[constants.jnt_limit_softness.at(joint_index)..][0..2];
        try expect(eql(f32, packed_softness, &expected_softness));
        const expected_impedance: [5]f32 = .{
            impedance.min,
            impedance.max,
            impedance.width,
            impedance.midpoint,
            impedance.power,
        };
        const packed_impedance: []const f32 = model_f[constants.jnt_limit_impedance.at(joint_index)..][0..5];
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
    const words_per_mask: u32 = robotgpu.maskWords(model.nv);
    var body: u32 = 1;
    while (body < model.nbody) : (body += 1) {
        const chain_start: u32 = tables.body_chain_start.load(body);
        const chain_length: u32 = tables.body_chain_length.load(body);
        // The body's last dof: its own last, or else its nearest ancestor's with any.
        var last_dof: u32 = robot.no_dof;
        var ancestor: u32 = body;
        while (ancestor != 0 and last_dof == robot.no_dof) {
            if (model.body_dof_num[ancestor] > 0) {
                last_dof = model.body_dof_adr[ancestor] + model.body_dof_num[ancestor] - 1;
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
    while (branch < counts.nbranch) : (branch += 1) {
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
    while (candidate < model.nbody) : (candidate += 1) {
        var has_child: bool = false;
        var other: u32 = 1;
        while (other < model.nbody) : (other += 1) {
            has_child = has_child or model.body_parent[other] == candidate;
        }
        if (!has_child) {
            try expect(next_branch < counts.nbranch);
            const branch_end: u32 = tables.body_branch_start.load(next_branch + 1);
            try expectEqual(candidate, tables.body_branches.load(branch_end - 1));
            next_branch += 1;
        }
    }
    try expectEqual(counts.nbranch, next_branch);
    try expectEqual(counts.nbranch_bodies, tables.body_branch_start.load(counts.nbranch));
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
    hasher.update(sliceAsBytes(data.pos));
    hasher.update(sliceAsBytes(data.vel));
    hasher.update(sliceAsBytes(data.body_xpos));
    hasher.update(sliceAsBytes(data.body_xrot));
    return hasher.final();
}

test "R1 gate: robot.zig's 200-step fingerprints are unchanged" {
    const humanoid_fingerprint: u64 = try fingerprintOf200Steps(testing_allocator, humanoid_xml);
    const geno_fingerprint: u64 = try fingerprintOf200Steps(testing_allocator, geno_xml);
    try expectEqual(@as(u64, 0x2acacc17d2834891), humanoid_fingerprint);
    try expectEqual(@as(u64, 0xb51c1eb44de302bf), geno_fingerprint);
}
