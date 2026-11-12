//! robotgpu.zig - THE ROBOT SIMULATOR ON THE GPU: many worlds of one robot.zig model, stepped together by compute
//! kernels in MuJoCo Warp's shapes, each kernel with a CPU twin that runs the same Zig.
//!
//! -- THE FILE --
//!
//! What happens, in order, and where in this file - each name in capitals is a section's banner, to search for:
//!
//!     on the host, once per model:
//!       count the model and its clips      Counts, countsOf, countsWithClips    COUNTS AND ITEMS
//!       place every array                  Layout, layoutFor                    WHERE AN ARRAY LIVES, THE LAYOUT
//!       pack the model and its clips       pack, packClips                      PACKING A MODEL
//!       upload the images, set Params      (robotgpu_host's Sim)
//!     on the GPU, once a decision - the DECISION PROGRAM (robotgpu_program.zig, `Sim.submitDecision`):
//!       before each physics step           filter_actions, reference_targets    THE TRACKING TASK
//!       each physics step - the STEP PROGRAM, its kernels in the order they run:
//!         the step's start                 clear_overflow                       THE STEP's START
//!         kinematics                       kinematics_branch, geom_poses ...    KINEMATICS
//!         the centre-of-mass frame         subtree_centres_of_mass ...          THE CENTRE-OF-MASS FRAME
//!         the mass matrix                  mass_matrix_rows, factor_mass_matrix THE MASS MATRIX
//!         velocities and bias forces       body_velocities_branch ...           VELOCITIES AND BIAS FORCES
//!         passive and actuator forces      passive_joint_forces ...             PASSIVE AND ACTUATOR FORCES
//!         the servo                        servo_errors, servo_accelerations,   THE SERVO
//!                                          servo_torques
//!         the smooth acceleration          smooth_joint_forces ...              THE SMOOTH ACCELERATION
//!         the floor's contacts             floor_contacts                       CONTACTS
//!         the constraint rows              limit_candidates, constraint_rows,   THE CONSTRAINT ROWS
//!                                          project_constraints
//!         Newton                           newton_solve                         NEWTON
//!         integration                      next_velocities ... next_positions   INTEGRATION
//!       after each physics step            advance_frames                       THE TRACKING TASK
//!     on the GPU, once a decision, after it - the OBSERVATION PROGRAM (`Sim.submitDecisionEnd`): the step's own
//!       kinematics and velocity kernels, then observe_character and observe_reference, into `observations`
//!     then the JUDGEMENT PROGRAM (in `Sim.submitDecisionEnd`): body_lowest_points, judge_tracking, judge_rewards -
//!       each world's tracking error and rewards                  THE TRACKING TASK, THE OBSERVATION AND THE JUDGEMENT
//!     on the CPU, the same kernels as loops - CpuTwin                       DISPATCHING AND THE CPU TWIN
//!
//! Every kernel reads and writes through params.layout.<arena>.<array>.load / .store / .loadVec ..., and calls
//! robot.zig's own functions for the physics, so the twin's numbers are robot.zig's to the bit. The sections run from
//! the vocabulary up - THE ARENAS, COUNTS AND ITEMS, WHERE AN ARRAY LIVES, THE LAYOUT, PACKING A MODEL - to the
//! kernels last.
//!
//! -- THE ARENAS --
//!
//! Every number the simulator keeps lives in one of eight storage buffers, the ARENAS - kompute's limit of eight
//! fields a module, and few enough that every kernel binds the same set:
//!
//!     model_f   model_u      the model, shared by every world: real constants, and topology and index tables
//!     batch_f                per-world model parameters, for worlds that differ (domain randomisation)
//!     world_f   world_u      each world's state and everything derived from it; its integers
//!     efc_f                  each world's constraint rows
//!     scratch                each world's solver workspace
//!     io                     the host's window: what it uploads each step, and the little it reads back
//!
//! An arena holds many ARRAYS - `joint_positions`, `body_positions`, `body_inertias`... - one after another. Where each
//! begins, and how far apart its worlds lie, is the LAYOUT, computed on the host once per model (`layoutFor`) and
//! handed to every kernel inside `Params`. The layout is one struct per arena, and each array's TYPE says which arena
//! it lives in and what one item of it is - `WorldArray(.world_f, .body_vectors)` is a vector per body, in every world:
//!
//!     params.layout.world_f.body_positions.loadVec(world, body)     a body's position, read from world_f
//!     params.layout.model_u.body_parent.load(body)        its parent, read from model_u
//!
//! So an array is read and written in its own arena alone, and an item's width - four floats for a vector, sixteen
//! for an inertia - is known at compile time.
//!
//! -- WORLD-MAJOR ARRAYS --
//!
//! A per-world array keeps each world's items together, the worlds one after another, every world's block padded to a
//! multiple of four floats so a vector never straddles two worlds:
//!
//!     body_positions (25 bodies, a vector of four floats each: 100 floats a world)
//!
//!     offset ->  [ world 0: body 0, body 1, ... body 24 ][ world 1: body 0 ... ][ world 2 ... ] ...
//!                 <---------- stride = 100 ----------->
//!
//!     body b of world w   at   offset + w * stride + 4 * b                         (`WorldArray.at`)
//!
//! Invocations that handle consecutive items of one world read consecutive addresses, and a kernel that runs one
//! invocation per world and item - MuJoCo Warp's commonest shape - reads each world's block as a run.

const std = @import("std");
const eql = std.mem.eql;
const k = @import("kompute");
const zm = @import("zm");
const pi = zm.pi;
const Vec = zm.Vec;
const qmul = zm.qmul;
const rotate = zm.rotate;
const conjugate = zm.conjugate;
const splat = zm.splat;
const dot3 = zm.dot3;
const cross = zm.cross;
const clamp = zm.clamp;
const assertf = zm.assertf;
const isFinite = zm.isFinite;
const vec = zm.vec;
const robot = @import("robot");
const program = @import("robotgpu_program.zig");
const sizes = @import("robotgpu_sizes");

// ==================================================================================================================
// THE ARENAS
// ==================================================================================================================
//
// The eight storage buffers, and the four ways a kernel reaches a number in one: a number or a vector, loaded or
// stored, the arena a compile-time choice.

/// A workgroup of 64, a large dispatch (worlds times elements run past one row of workgroups), and readback by ranges
/// (the arenas run to hundreds of megabytes).
pub const config = k.Config{
    .max = 1 << 24,
    .workgroup = 64,
    .large_dispatch = true,
    .readback = .ranges,
    .staging_bytes = 1 << 20,
};

/// The eight arenas (this file's head), each as long as `robotgpu_sizes` says.
pub const Buffers = extern struct {
    model_f: [sizes.model_f]f32,
    model_u: [sizes.model_u]u32,
    batch_f: [sizes.batch_f]f32,
    world_f: [sizes.world_f]f32,
    world_u: [sizes.world_u]u32,
    efc_f: [sizes.efc_f]f32,
    scratch: [sizes.scratch]f32,
    io: [sizes.io]f32,
};

/// THE MODULE'S BINDINGS (`k.Globals`): every arena a storage buffer of its own on the GPU, and on the CPU twin a
/// static array the same kernels index. The arrays' accessors below read and write through them.
pub const g = k.Globals(@This());

/// The arenas, by name: where every array's type says it lives (`WorldArray`, `ModelTable`).
pub const Arena = std.meta.FieldEnum(Buffers);

/// The kind of number `arena` holds: `f32` or `u32`.
pub fn ArenaElement(comptime arena: Arena) type {
    return std.meta.Elem(@FieldType(Buffers, @tagName(arena)));
}

/// One number of `arena`, at `index`. The arena's binding, `comptime g.bind(arena)`, is a COMPILE-TIME constant, as a
/// binding bound at module scope is - never a pointer passed at run time: a SPIR-V function parameter pointing into a
/// storage buffer needs a capability (VariablePointers) the Vulkan host does not enable. Each arena gets its own copy
/// of the function, and `bind` itself only ever runs at compile time.
fn loadNumber(comptime arena: Arena, index: u32) ArenaElement(arena) {
    return (comptime g.bind(arena))[index];
}

/// One number of `arena` set to `value`, at `index` (the binding a compile-time constant, as in `loadNumber`).
fn storeNumber(comptime arena: Arena, index: u32, value: ArenaElement(arena)) void {
    (comptime g.bind(arena))[index] = value;
}

/// Four floats of `arena` from index `first`, as a vector.
fn loadVector(comptime arena: Arena, first: u32) Vec {
    const loaded: Vec = .{
        loadNumber(arena, first),
        loadNumber(arena, first + 1),
        loadNumber(arena, first + 2),
        loadNumber(arena, first + 3),
    };
    return loaded;
}

/// `vector`'s four floats into `arena` from index `first`.
fn storeVector(comptime arena: Arena, first: u32, vector: Vec) void {
    storeNumber(arena, first, vector[0]);
    storeNumber(arena, first + 1, vector[1]);
    storeNumber(arena, first + 2, vector[2]);
    storeNumber(arena, first + 3, vector[3]);
}

// ==================================================================================================================
// COUNTS AND ITEMS
// ==================================================================================================================
//
// How big a model is, and what one item of an array is - a body's vector, a dof's motion - from which every array's
// length follows.

/// THE MODEL'S SIZES AND THE NUMBER OF WORLDS - what every layout is computed from (`countsOf` reads them from a
/// model). The names are MuJoCo's.
pub const Counts = extern struct {
    /// Worlds simulated together, each a copy of the model with a state of its own.
    world_count: u32,
    /// Bodies, the world body 0 among them.
    body_count: u32,
    /// Joints.
    joint_count: u32,
    /// Position coordinates (`joint_positions`): seven for a free joint, four for a ball, one for a hinge or a slide.
    coordinate_count: u32,
    /// Degrees of freedom (`joint_velocities`): six for a free joint, three for a ball, one for a hinge or a slide.
    dof_count: u32,
    /// Collision geometries.
    geom_count: u32,
    /// Actuators, and the activation states some of them carry.
    actuator_count: u32,
    activation_count: u32,
    /// The mass matrix's stored entries: its lower triangle along each dof's chain of ancestors.
    mass_entry_count: u32,
    /// The dofs of every body's chain, all chains together (`pack`).
    chain_dof_count: u32,
    /// Sites: frames attached to bodies, read by sensors and the tracker.
    site_count: u32,
    /// The kinematic tree's BRANCHES - one per leaf body - and the bodies of all their chains together (`pack`).
    branch_count: u32,
    branch_body_count: u32,
    /// The joints with a range - hinges and slides; a ball or a free joint has none - and their CANDIDATE ENDS, two
    /// each: every limit row a world can have, lower end then upper, in joint order (`limited_joints`).
    limited_joint_count: u32,
    limit_candidate_count: u32,
    /// The floor's contact SLOTS one world has: each moving geom's most contacts with the floor (`robot.floorSlotsOf`),
    /// in geom order - a sphere 1, a capsule 2, a box 4 - each filled or left empty by every step (`floor_contacts`).
    floor_slot_count: u32,
    /// The constraint rows one world can hold: both ends of every limited joint, so a step never needs more. The
    /// device's own budget, not robot.zig's `constraint_capacity`, which also holds four rows for every contact a CPU
    /// world may make - 256 contacts for Geno, some 157,000 floats of dense rows a world, more than a GPU should give
    /// thousands of worlds. Contacts join with a budget of their own (and their Jacobians' few nonzeros stored
    /// sparse); a step that would need more rows than the slots sets the world's overflow bit instead.
    constraint_capacity: u32,
    /// The nonzeros one row's Jacobian can have (`constraint_jacobian_values`): one for a limit, whose row moves only
    /// its own joint.
    row_nonzero_capacity: u32,
    /// THE TRACKING TASK's CLIPS (`packClips`): how many, and their frames together - each frame a run of
    /// `coordinate_count` coordinates; none for a simulator without a task.
    clip_count: u32 = 0,
    clip_frame_total: u32 = 0,
    /// Every clip's curriculum bins together (`ClipPoses.curriculum_bins`), 0 for a run without a curriculum.
    curriculum_bin_total: u32 = 0,
    /// The rest of the bin total's row: the counts stay whole 16-byte rows of the uniform.
    _padding_curriculum_0: u32 = 0,
    _padding_curriculum_1: u32 = 0,
    _padding_curriculum_2: u32 = 0,
    /// The policy's action: a number per dof but the free root's six (`robot.actionSize`), then one per limb - its
    /// stiffness, read where the task's `limb_stiffness` is on.
    action_count: u32 = 0,
    /// The model's limbs (`robot.Model.limb_count`).
    limb_count: u32 = 0,
    /// The character's root body (`robot.rootBody`): the frame its observation is taken in.
    root_body: u32 = 0,
    /// How many clip frames carry the reference's half of the observation (`ClipPoses.reference_features`): every
    /// clip's frames, or none - for a simulator whose worlds are never observed, which then keeps no such table.
    reference_feature_frames: u32 = 0,
};

/// A dof's place in a body's chain when the dof does not move the body (`ModelTablesLayout.body_chain_place`).
pub const no_chain_place: u32 = 0xFFFF_FFFF;

/// The 32-bit words of one body's dof mask: a bit per dof.
pub fn maskWords(dof_count: u32) u32 {
    return (dof_count + 31) / 32;
}

/// THE KIND OF ITEM AN ARRAY HOLDS. Every array is a run of ITEMS - one per body, per dof, per joint - and every item
/// is a few NUMBERS. The kind names both, so an array's length follows from a model's counts. One COPY of an array is a
/// world's block of a per-world array, or the whole of a model table:
///
///     kind               one item per            numbers per item                  for example
///     coordinates        position coordinate     1                                 joint_positions
///     dofs               degree of freedom       1                                 joint_velocities, bias_joint_forces
///     dof_motions        degree of freedom       8   angular, then linear           dof_axes
///     body_vectors       body                    4   x, y, z and padding (or a      body_positions, body_orientations
///                                                    quaternion's four)
///     body_motions       body                    8   angular, then linear           body_velocities
///     body_forces        body                    8   torque, then force             subtree_bias_forces
///     body_inertias      body                    16  diag, off, h, mass, padding    body_inertias, composite_inertias
///     joint_pairs        joint                   2   a range, or a softness         joint_range
///     limited_joints     joint with a range      1                                 limited_joints
///     limit_candidates   end of a limited joint  1                                 limit_candidate_distance
///     constraint_rows    constraint row          1                                 constraint_violation
///     constraint_row_dofs  row and dof           1   row-major: a row's dofs        constraint_inverse_inertia_
///                                                    together                       jacobian
///     constraint_row_nonzeros  row and nonzero   1   row-major: a row's nonzeros    constraint_jacobian_values
///                                                    together
///     actuator_vectors   actuator                4   three numbers, padded          actuator_bias
///     actuator_pairs     actuator                2   a range                        actuator_control_range
///     joint_impedances   joint                   5   min, max, width, midpoint,     joint_limit_impedance
///                                                    power
///     mass_entries       stored entry of M       1                                  mass_matrix, mass_factor
///     clips              clip of the task        1                                  clip_first_frame
///     clip_coordinates   coordinate of a clip    1   frame-major: a frame's         clip_coordinates
///                        frame                       coordinates together
///     actions            number of the action    1                                  actions
///     observations       number of the           1   the character's half, then     observations
///                        observation                 the reference's
///     clip_reference     number of a clip        1   frame-major: a frame's         clip_reference_features
///     _numbers           frame's reference half      half together
///
/// and so on for actuators, activations, geoms, sites, the dof chains, the dof masks and the branches.
/// One half of an observation's numbers for a model of `counts` - robot_track's `local` (`robot.localSize`).
fn localSizeOf(counts: Counts) u32 {
    return @intCast(robot.localSize(counts.body_count));
}

/// How many f32 fields a struct of the judgement's has (`robot.RewardWeights`, `robot.SuperMimicScales`: all of
/// theirs; `robot.Termination`: its limits, not its `grace_steps`) - the numbers it takes in `judgement_weights`.
fn f32FieldCount(comptime Weights: type) u32 {
    const info = @typeInfo(Weights).@"struct";
    var count: u32 = 0;
    inline for (info.field_types) |field_type| {
        if (field_type == f32) {
            count += 1;
        }
    }
    return count;
}

/// How many numbers the judgement's weights take (`judgement_weights`).
pub const judgement_number_count: u32 = f32FieldCount(robot.RewardWeights) + f32FieldCount(robot.SuperMimicScales) +
    f32FieldCount(robot.Termination);

pub const ItemKind = enum {
    single,
    coordinates,
    dofs,
    dof_motions,
    actuators,
    actuator_vectors,
    actuator_pairs,
    activations,
    bodies,
    body_vectors,
    body_motions,
    body_forces,
    body_inertias,
    joints,
    joint_vectors,
    joint_pairs,
    joint_impedances,
    geoms,
    geom_vectors,
    sites,
    site_vectors,
    mass_entries,
    chain_entries,
    ancestor_words,
    branch_bodies,
    branches_and_end,
    limited_joints,
    body_dofs,
    limit_candidates,
    floor_slots,
    floor_slot_vectors,
    constraint_rows,
    constraint_row_dofs,
    constraint_row_nonzeros,
    clips,
    clip_coordinates,
    actions,
    observations,
    clip_reference_numbers,
    clip_reference_body_numbers,
    tracking_error_terms,
    judgement_numbers,
    model_single,
    joint_box_numbers,
    curriculum_bins,
    state_features,

    /// How many items one copy holds, for a model of `counts`.
    fn itemsPerCopy(item_kind: ItemKind, counts: Counts) u32 {
        return switch (item_kind) {
            .single => 1,
            .coordinates => counts.coordinate_count,
            .dofs, .dof_motions => counts.dof_count,
            .actuators, .actuator_vectors, .actuator_pairs => counts.actuator_count,
            .activations => counts.activation_count,
            .bodies, .body_vectors, .body_motions, .body_forces, .body_inertias => counts.body_count,
            .joints, .joint_vectors, .joint_pairs, .joint_impedances => counts.joint_count,
            .geoms, .geom_vectors => counts.geom_count,
            .sites, .site_vectors => counts.site_count,
            .mass_entries => counts.mass_entry_count,
            .chain_entries => counts.chain_dof_count,
            .ancestor_words => counts.body_count * maskWords(counts.dof_count),
            .branch_bodies => counts.branch_body_count,
            .branches_and_end => counts.branch_count + 1,
            .limited_joints => counts.limited_joint_count,
            .body_dofs => counts.body_count * counts.dof_count,
            .limit_candidates => counts.limit_candidate_count,
            .floor_slots, .floor_slot_vectors => counts.floor_slot_count,
            .constraint_rows => counts.constraint_capacity,
            .constraint_row_dofs => counts.constraint_capacity * counts.dof_count,
            .constraint_row_nonzeros => counts.constraint_capacity * counts.row_nonzero_capacity,
            .clips => counts.clip_count,
            .clip_coordinates => counts.clip_frame_total * counts.coordinate_count,
            .actions => counts.action_count,
            // Two halves of robot_track's `local` each: the character's, and the reference's.
            .observations => 2 * localSizeOf(counts),
            .clip_reference_numbers => counts.reference_feature_frames * localSizeOf(counts),
            .clip_reference_body_numbers => counts.reference_feature_frames * counts.body_count *
                @as(u32, @intCast(robot.reference_body_numbers)),
            // The judgement's weights: the tracker's reward's, then SuperMimic's (`writeJudgementWeights`).
            .judgement_numbers => judgement_number_count,
            .model_single => 1,
            // Each joint's rotation box: low, then high, four numbers each (`rotationBoxNumbers`).
            .joint_box_numbers => 12 * counts.joint_count,
            // Every clip's curriculum bins (`curriculum_bin_total`): the mixture's running sums, one each.
            .curriculum_bins => counts.curriculum_bin_total,
            // One feature vector of a body state in its root's frame (`robot.localSize`): the policy's normaliser.
            .state_features => @intCast(robot.localSize(counts.body_count)),
            // The tracking error's terms, one number each (`robot.TrackingError`'s fields, in their order).
            .tracking_error_terms => @intCast(@typeInfo(robot.TrackingError).@"struct".field_names.len),
        };
    }

    /// The numbers in one item.
    fn numbersPerItem(item_kind: ItemKind) u32 {
        return switch (item_kind) {
            .single,
            .coordinates,
            .dofs,
            .actuators,
            .activations,
            .bodies,
            .joints,
            .geoms,
            .sites,
            .mass_entries,
            .chain_entries,
            .ancestor_words,
            .branch_bodies,
            .branches_and_end,
            .body_dofs,
            .limited_joints,
            .limit_candidates,
            .floor_slots,
            .constraint_rows,
            .constraint_row_dofs,
            .constraint_row_nonzeros,
            .clips,
            .clip_coordinates,
            .actions,
            .observations,
            .clip_reference_numbers,
            .clip_reference_body_numbers,
            .tracking_error_terms,
            .judgement_numbers,
            .model_single,
            .joint_box_numbers,
            .curriculum_bins,
            .state_features,
            => 1,
            .joint_pairs, .actuator_pairs => 2,
            .body_vectors, .joint_vectors, .geom_vectors, .site_vectors, .actuator_vectors, .floor_slot_vectors => 4,
            .joint_impedances => 5,
            .dof_motions, .body_motions, .body_forces => 8,
            .body_inertias => 16,
        };
    }

    /// The numbers one copy holds: its items times their width.
    fn numbersPerCopy(item_kind: ItemKind, counts: Counts) u32 {
        return item_kind.itemsPerCopy(counts) * item_kind.numbersPerItem();
    }
};

// ==================================================================================================================
// WHERE AN ARRAY LIVES
// ==================================================================================================================
//
// One array's place in its arena - per world, or one model table - with the accessors the kernels read and write it
// through.

/// Refuse, at compile time, an accessor named `accessor` that moves items of `numbers_per_item` numbers on an array
/// whose items are another width - a vector read of a table of scalars, a scalar read of a table of vectors.
fn requireItemWidth(
    comptime item_kind: ItemKind,
    comptime numbers_per_item: u32,
    comptime accessor: []const u8,
) void {
    const widths_match: bool = item_kind.numbersPerItem() == numbers_per_item;
    if (!widths_match) {
        @compileError(std.fmt.comptimePrint("{s}: an item of `{s}` is {d} numbers, not {d}", .{
            accessor,
            @tagName(item_kind),
            item_kind.numbersPerItem(),
            numbers_per_item,
        }));
    }
}

/// Refuse, at compile time, an accessor named `accessor` that reads floats from an arena of words.
fn requireFloats(comptime arena: Arena, comptime accessor: []const u8) void {
    const holds_floats: bool = ArenaElement(arena) == f32;
    if (!holds_floats) {
        @compileError(accessor ++ ": the `" ++ @tagName(arena) ++ "` arena holds words, not floats");
    }
}

/// WHERE ONE PER-WORLD ARRAY LIVES: in arena `arena`, one copy per world, each copy made of `elements`. Its OFFSET is
/// where world 0's copy begins, its STRIDE the distance from one world's copy to the next (a multiple of four), its
/// COUNT how many of each copy's numbers are live - the rest of the stride is padding. The arena and the kind of item
/// are part of the TYPE: the accessors reach this array's own arena alone, and know an item's width at compile time.
/// Sixteen bytes, so a layout of them sits in a uniform as written.
pub fn WorldArray(comptime arena: Arena, comptime kind_of_item: ItemKind) type {
    return extern struct {
        offset: u32 = 0,
        stride: u32 = 0,
        count: u32 = 0,
        _padding: u32 = 0,

        const Array = @This();
        const Element: type = ArenaElement(arena);

        /// The arena the array lives in, and what one item of it is.
        pub const home: Arena = arena;
        pub const item_kind: ItemKind = kind_of_item;
        /// One copy per world (`placeArrays`).
        pub const per_world: bool = true;

        /// The arena index of item `item` of world `world` - the item's first number, world-major (this file's head).
        pub fn at(array: Array, world: u32, item: u32) u32 {
            const numbers_per_item: u32 = comptime item_kind.numbersPerItem();
            return array.offset + world * array.stride + item * numbers_per_item;
        }

        /// Item `item` of world `world`, one number.
        pub fn load(array: Array, world: u32, item: u32) Element {
            comptime requireItemWidth(item_kind, 1, "load");
            return loadNumber(arena, array.at(world, item));
        }

        /// Item `item` of world `world` set to `value`, one number.
        pub fn store(array: Array, world: u32, item: u32, value: Element) void {
            comptime requireItemWidth(item_kind, 1, "store");
            storeNumber(arena, array.at(world, item), value);
        }

        /// Every item of world `world`, from `values` - one world's block, as a host or a test holds it.
        pub fn storeAll(array: Array, world: u32, values: []const Element) void {
            for (values, 0..) |value, item| {
                array.store(world, @intCast(item), value);
            }
        }

        /// Every item of world `world`, into `out` - one world's block, as a host or a test holds it.
        pub fn loadAll(array: Array, world: u32, out: []Element) void {
            for (out, 0..) |*value, item| {
                value.* = array.load(world, @intCast(item));
            }
        }

        /// Items `first` to `first + 2` of world `world` - three consecutive numbers of an array of single numbers,
        /// such as a free joint's three position coordinates or a ball joint's three rates - as a vector, its fourth
        /// lane zero (as `zm.vec` makes one).
        pub fn loadVector3(array: Array, world: u32, first: u32) Vec {
            comptime requireFloats(arena, "loadVector3");
            comptime requireItemWidth(item_kind, 1, "loadVector3");
            const x: f32 = array.load(world, first);
            const y: f32 = array.load(world, first + 1);
            const z: f32 = array.load(world, first + 2);
            return vec(x, y, z);
        }

        /// Items `first` to `first + 2` of world `world` set to `vector`'s first three lanes.
        pub fn storeVector3(array: Array, world: u32, first: u32, vector: Vec) void {
            comptime requireFloats(arena, "storeVector3");
            comptime requireItemWidth(item_kind, 1, "storeVector3");
            array.store(world, first, vector[0]);
            array.store(world, first + 1, vector[1]);
            array.store(world, first + 2, vector[2]);
        }

        /// Items `first` to `first + 3` of world `world` - four consecutive numbers of an array of single numbers, a
        /// free or a ball joint's quaternion among its coordinates - as a quaternion.
        pub fn loadQuaternion(array: Array, world: u32, first: u32) robot.Quat {
            comptime requireFloats(arena, "loadQuaternion");
            comptime requireItemWidth(item_kind, 1, "loadQuaternion");
            const quaternion: robot.Quat = .{
                array.load(world, first),
                array.load(world, first + 1),
                array.load(world, first + 2),
                array.load(world, first + 3),
            };
            return quaternion;
        }

        /// Items `first` to `first + 3` of world `world` set to `quaternion`.
        pub fn storeQuaternion(
            array: Array,
            world: u32,
            first: u32,
            quaternion: robot.Quat,
        ) void {
            comptime requireFloats(arena, "storeQuaternion");
            comptime requireItemWidth(item_kind, 1, "storeQuaternion");
            inline for (0..4) |component| {
                array.store(world, first + @as(u32, component), quaternion[component]);
            }
        }

        /// Item `item` of world `world`, a vector of four floats - a position, a quaternion.
        pub fn loadVec(array: Array, world: u32, item: u32) Vec {
            comptime requireFloats(arena, "loadVec");
            comptime requireItemWidth(item_kind, 4, "loadVec");
            return loadVector(arena, array.at(world, item));
        }

        /// Item `item` of world `world` set to `vector`, four floats.
        pub fn storeVec(array: Array, world: u32, item: u32, vector: Vec) void {
            comptime requireFloats(arena, "storeVec");
            comptime requireItemWidth(item_kind, 4, "storeVec");
            storeVector(arena, array.at(world, item), vector);
        }

        /// Item `item` of world `world` as robot.zig's spatial inertia: `diag`, `off`, `h`, a vector each, then the
        /// mass.
        pub fn loadInertia(array: Array, world: u32, item: u32) robot.Inertia {
            comptime requireFloats(arena, "loadInertia");
            comptime requireItemWidth(item_kind, 16, "loadInertia");
            const first: u32 = array.at(world, item);
            const inertia: robot.Inertia = .{
                .diag = loadVector(arena, first),
                .off = loadVector(arena, first + 4),
                .h = loadVector(arena, first + 8),
                .mass = loadNumber(arena, first + 12),
            };
            return inertia;
        }

        /// Item `item` of world `world` set to `inertia`: sixteen floats, the mass's row padded with zeros, so the item
        /// holds nothing stale for a reader of whole items.
        pub fn storeInertia(
            array: Array,
            world: u32,
            item: u32,
            inertia: robot.Inertia,
        ) void {
            comptime requireFloats(arena, "storeInertia");
            comptime requireItemWidth(item_kind, 16, "storeInertia");
            const first: u32 = array.at(world, item);
            const mass_row: Vec = .{ inertia.mass, 0, 0, 0 };
            storeVector(arena, first, inertia.diag);
            storeVector(arena, first + 4, inertia.off);
            storeVector(arena, first + 8, inertia.h);
            storeVector(arena, first + 12, mass_row);
        }

        /// Item `item` of world `world` as a spatial motion (or force): angular, then linear, four floats each.
        pub fn loadMotion(array: Array, world: u32, item: u32) robot.Motion {
            comptime requireFloats(arena, "loadMotion");
            comptime requireItemWidth(item_kind, 8, "loadMotion");
            const first: u32 = array.at(world, item);
            const motion: robot.Motion = .{ .ang = loadVector(arena, first), .lin = loadVector(arena, first + 4) };
            return motion;
        }

        /// Item `item` of world `world` set to `motion`, angular then linear.
        pub fn storeMotion(
            array: Array,
            world: u32,
            item: u32,
            motion: robot.Motion,
        ) void {
            comptime requireFloats(arena, "storeMotion");
            comptime requireItemWidth(item_kind, 8, "storeMotion");
            const first: u32 = array.at(world, item);
            storeVector(arena, first, motion.ang);
            storeVector(arena, first + 4, motion.lin);
        }

        /// Item `item` of world `world` as a spatial force: its torque from the first four floats, its force from the
        /// next four.
        pub fn loadForce(array: Array, world: u32, item: u32) robot.Force {
            comptime requireFloats(arena, "loadForce");
            comptime requireItemWidth(item_kind, 8, "loadForce");
            const first: u32 = array.at(world, item);
            const force: robot.Force = .{ .ang = loadVector(arena, first), .lin = loadVector(arena, first + 4) };
            return force;
        }

        /// Item `item` of world `world` set to the spatial force `force`, eight floats.
        pub fn storeForce(array: Array, world: u32, item: u32, force: robot.Force) void {
            comptime requireFloats(arena, "storeForce");
            comptime requireItemWidth(item_kind, 8, "storeForce");
            const first: u32 = array.at(world, item);
            storeVector(arena, first, force.ang);
            storeVector(arena, first + 4, force.lin);
        }
    };
}

/// WHERE ONE MODEL TABLE LIVES: in arena `arena`, a single copy shared by every world, made of `elements` - the same
/// sixteen bytes as a per-world array (`WorldArray`), its stride the copy's padded length. Besides the kernels'
/// accessors, three for the host, which packs the model into an IMAGE of the arena - a host array laid out as the
/// arena is (`pack`) - and reads one back (the tests).
pub fn ModelTable(comptime arena: Arena, comptime kind_of_item: ItemKind) type {
    return extern struct {
        offset: u32 = 0,
        stride: u32 = 0,
        count: u32 = 0,
        _padding: u32 = 0,

        const Table = @This();
        const Element: type = ArenaElement(arena);

        /// The arena the table lives in, and what one item of it is.
        pub const home: Arena = arena;
        pub const item_kind: ItemKind = kind_of_item;
        /// One copy, shared by every world (`placeArrays`).
        pub const per_world: bool = false;

        /// The arena index of item `item` - its first number.
        pub fn at(table: Table, item: u32) u32 {
            const numbers_per_item: u32 = comptime item_kind.numbersPerItem();
            return table.offset + item * numbers_per_item;
        }

        /// Item `item`, one number.
        pub fn load(table: Table, item: u32) Element {
            comptime requireItemWidth(item_kind, 1, "load");
            return loadNumber(arena, table.at(item));
        }

        /// Item `item` as a pair - a range: its two numbers.
        pub fn loadPair(table: Table, item: u32) [2]Element {
            comptime requireItemWidth(item_kind, 2, "loadPair");
            const first: u32 = table.at(item);
            const pair: [2]Element = .{ loadNumber(arena, first), loadNumber(arena, first + 1) };
            return pair;
        }

        /// Item `item`, a vector of four floats.
        pub fn loadVec(table: Table, item: u32) Vec {
            comptime requireFloats(arena, "loadVec");
            comptime requireItemWidth(item_kind, 4, "loadVec");
            return loadVector(arena, table.at(item));
        }

        /// Item `item` as robot.zig's spatial inertia: `diag`, `off` and `h`, a vector each, then the mass.
        pub fn loadInertia(table: Table, item: u32) robot.Inertia {
            comptime requireFloats(arena, "loadInertia");
            comptime requireItemWidth(item_kind, 16, "loadInertia");
            const first: u32 = table.at(item);
            const inertia: robot.Inertia = .{
                .diag = loadVector(arena, first),
                .off = loadVector(arena, first + 4),
                .h = loadVector(arena, first + 8),
                .mass = loadNumber(arena, first + 12),
            };
            return inertia;
        }

        /// HOST SIDE: the table's live numbers within `image`, an image of its arena.
        pub fn within(table: Table, image: []const Element) []const Element {
            return image[table.offset..][0..table.count];
        }

        /// HOST SIDE: a table of one number per item, `values`, written into its place in `image` - as many values as
        /// the table has items, or `@memcpy` refuses.
        pub fn fill(table: Table, image: []Element, values: []const Element) void {
            comptime requireItemWidth(item_kind, 1, "fill");
            @memcpy(image[table.offset..][0..table.count], values);
        }

        /// HOST SIDE: a table of vectors written into its place in `image`, four floats each.
        pub fn fillVectors(table: Table, image: []f32, vectors: []const Vec) void {
            comptime requireFloats(arena, "fillVectors");
            comptime requireItemWidth(item_kind, 4, "fillVectors");
            for (vectors, 0..) |vector, item| {
                const first: u32 = table.at(@intCast(item));
                image[first..][0..4].* = vector;
            }
        }
    };
}

// ==================================================================================================================
// THE LAYOUT
// ==================================================================================================================
//
// Every array of every arena, by name - one struct per arena - and `layoutFor`, which places them for a model's
// counts, on the host, once per model.

pub const WorldStateLayout = extern struct {
    /// MuJoCo's name: `qpos`.
    joint_positions: WorldArray(.world_f, .coordinates) = .{},
    /// MuJoCo's name: `qvel`.
    joint_velocities: WorldArray(.world_f, .dofs) = .{},
    /// MuJoCo's name: `qacc`.
    joint_accelerations: WorldArray(.world_f, .dofs) = .{},
    /// The last step's answer, the warm start Newton may begin from - saved by every step (`newtonStore`), zero at a
    /// world's start, as a new `robot.Data` holds it. MuJoCo's name: `qacc_warmstart`.
    warmstart_accelerations: WorldArray(.world_f, .dofs) = .{},
    /// Each dof's velocity change over the step, for a model with damping: first the right-hand side `dt (M a)`, then -
    /// solved with the damped factor `M + dt D` - the change itself. robot.zig's `implicit_rhs`.
    velocity_changes: WorldArray(.world_f, .dofs) = .{},
    /// The damped matrix `M + dt D`, factored - kept apart from `mass_factor`, so M's own factor stays as it is.
    /// robot.zig refactors M after its damped solve to restore it (`dampedVelocityStep`); separate arrays make that
    /// unnecessary. MJW keeps its integration matrix apart likewise.
    damped_mass_factor: WorldArray(.world_f, .mass_entries) = .{},
    /// The damped factor's inverse pivots.
    damped_mass_factor_inverse_diagonal: WorldArray(.world_f, .dofs) = .{},
    /// MuJoCo's name: `qacc_smooth`.
    smooth_joint_accelerations: WorldArray(.world_f, .dofs) = .{},
    /// MuJoCo's name: `qfrc_applied`.
    applied_joint_forces: WorldArray(.world_f, .dofs) = .{},
    /// THE SERVO's TARGET (`StepOptions.servo`), set by the host each decision: the pose it pulls toward, a coordinate
    /// each, and - toward motion - each dof's velocity at it.
    servo_targets: WorldArray(.world_f, .coordinates) = .{},
    servo_target_velocities: WorldArray(.world_f, .dofs) = .{},
    /// What the servo computes on its way to its torques: each dof's position error toward the target
    /// (`robot.differentiatePos`), then each dof's wanted acceleration - the root's own six, for a free root, solved
    /// last (`servo_torques`).
    servo_errors: WorldArray(.world_f, .dofs) = .{},
    servo_accelerations: WorldArray(.world_f, .dofs) = .{},
    /// MuJoCo's name: `qfrc_bias`.
    bias_joint_forces: WorldArray(.world_f, .dofs) = .{},
    /// MuJoCo's name: `qfrc_passive`.
    passive_joint_forces: WorldArray(.world_f, .dofs) = .{},
    /// MuJoCo's name: `qfrc_actuator`.
    actuator_joint_forces: WorldArray(.world_f, .dofs) = .{},
    /// MuJoCo's name: `qfrc_smooth`.
    smooth_joint_forces: WorldArray(.world_f, .dofs) = .{},
    /// MuJoCo's name: `ctrl`.
    controls: WorldArray(.world_f, .actuators) = .{},
    /// MuJoCo's name: `act`.
    activations: WorldArray(.world_f, .activations) = .{},
    /// Each activation's rate of change, written by actuation and integrated by the advance.
    /// MuJoCo's name: `act_dot`.
    activation_rates: WorldArray(.world_f, .activations) = .{},
    /// Each actuator's force, in the actuator's own terms, before it reaches the joints.
    /// MuJoCo's name: `actuator_force`.
    actuator_forces: WorldArray(.world_f, .actuators) = .{},
    /// Each actuator's length - for a joint actuator, its joint's coordinate. MuJoCo's name: `actuator_length`.
    actuator_lengths: WorldArray(.world_f, .actuators) = .{},
    /// Each actuator's velocity - for a joint actuator, its joint's rate. MuJoCo's name: `actuator_velocity`.
    actuator_velocities: WorldArray(.world_f, .actuators) = .{},
    /// MuJoCo's name: `xpos`.
    body_positions: WorldArray(.world_f, .body_vectors) = .{},
    /// MuJoCo's name: `xquat`.
    body_orientations: WorldArray(.world_f, .body_vectors) = .{},

    /// MuJoCo's name: `xipos`.
    body_centres_of_mass: WorldArray(.world_f, .body_vectors) = .{},

    /// MJW: `joint_anchors` - each joint's anchor in the world, where kinematics found it.
    /// MuJoCo's name: `xanchor`.
    joint_anchors: WorldArray(.world_f, .joint_vectors) = .{},
    /// MJW: `joint_axes` - each joint's axis in the world.
    /// MuJoCo's name: `xaxis`.
    joint_axes: WorldArray(.world_f, .joint_vectors) = .{},
    /// MuJoCo's name: `subtree_com`.
    subtree_centres_of_mass: WorldArray(.world_f, .body_vectors) = .{},
    /// MuJoCo's name: `cinert`.
    body_inertias: WorldArray(.world_f, .body_inertias) = .{},
    /// MuJoCo's name: `crb`.
    composite_inertias: WorldArray(.world_f, .body_inertias) = .{},
    /// MuJoCo's name: `cvel`.
    body_velocities: WorldArray(.world_f, .body_motions) = .{},
    /// MuJoCo's name: `cacc`.
    body_bias_accelerations: WorldArray(.world_f, .body_motions) = .{},
    /// MuJoCo's name: `cfrc_int`.
    subtree_bias_forces: WorldArray(.world_f, .body_forces) = .{},
    /// MuJoCo's name: `cdof`.
    dof_axes: WorldArray(.world_f, .dof_motions) = .{},
    /// MuJoCo's name: `cdof_dot`.
    dof_axis_rates: WorldArray(.world_f, .dof_motions) = .{},
    /// MuJoCo's name: `geom_xpos`.
    geom_positions: WorldArray(.world_f, .geom_vectors) = .{},
    /// Each geom's orientation in the world, a quaternion as robot.zig keeps orientations (MJW: `geom_xmat`).
    /// MuJoCo's name: `geom_xquat`.
    geom_orientations: WorldArray(.world_f, .geom_vectors) = .{},
    /// THE FLOOR'S CONTACTS, one slot each (`Counts.floor_slot_count`): a filled slot's contact - where it is (halfway
    /// between the surfaces), how far apart the surfaces are, and its frame's two tangents (`robot.contactFrame`).
    floor_slot_positions: WorldArray(.world_f, .floor_slot_vectors) = .{},
    floor_slot_distances: WorldArray(.world_f, .floor_slots) = .{},
    floor_slot_first_tangents: WorldArray(.world_f, .floor_slot_vectors) = .{},
    floor_slot_second_tangents: WorldArray(.world_f, .floor_slot_vectors) = .{},
    /// MJW: `site_positions` - each site's position in the world.
    /// MuJoCo's name: `site_xpos`.
    site_positions: WorldArray(.world_f, .site_vectors) = .{},
    /// Each site's orientation in the world, a quaternion (robot.zig's `site_xrot`; MJW: `site_xmat`).
    /// MuJoCo's name: `site_xquat`.
    site_orientations: WorldArray(.world_f, .site_vectors) = .{},

    /// MuJoCo's name: `qM`.
    mass_matrix: WorldArray(.world_f, .mass_entries) = .{},
    /// MuJoCo's name: `qLD`.
    mass_factor: WorldArray(.world_f, .mass_entries) = .{},
    /// MuJoCo's name: `qLDiagInv`.
    mass_factor_inverse_diagonal: WorldArray(.world_f, .dofs) = .{},
    /// The joint forces the constraint rows exert, J^T f - what the solver's forces do to the mechanism. MuJoCo's name:
    /// `qfrc_constraint`.
    constraint_joint_forces: WorldArray(.world_f, .dofs) = .{},
    /// THE TRACKING TASK's ACTION each world was given: a number per dof but the free root's, in [-1, 1] as a squashed
    /// policy gives it.
    actions: WorldArray(.world_f, .actions) = .{},
    /// The action each world's servo is driven by: the filter's state, moved toward `actions` before each physics step
    /// (`filter_actions`), zero at a reset - `reference_targets` scales it and adds it to the reference.
    applied_actions: WorldArray(.world_f, .actions) = .{},
    /// EACH BODY's LOWEST POINT (world z) of its collision shapes (`robot.bodyLowestPoints`), `robot.no_shape_height`
    /// for a body without one and for the world - which body touches the floor, for the judgement's unexpected
    /// contact. Written at a decision's end (`body_lowest_points`).
    body_lowest_points: WorldArray(.world_f, .bodies) = .{},
    /// WHAT EACH WORLD's POLICY SEES (robot_track's `observe`): the character, then the reference it is chasing, each
    /// in the root's frame as robot_track's `local` lays it out - written once a decision by `observe_program`.
    observations: WorldArray(.world_f, .observations) = .{},
    /// THE POLICY's ROW for each world (`policy_inputs`), in the order the policy's first layer reads it: the goal -
    /// the reference one frame ahead - then the state, both in their root's frame and normalised. One block, world
    /// after world, so a single copy hands every world's row to the learning kit.
    policy_inputs: WorldArray(.world_f, .observations) = .{},
    /// EACH WORLD's TRACKING ERROR at a decision's end (`judge_tracking`): `robot.TrackingError`'s terms, in order.
    tracking_errors: WorldArray(.world_f, .tracking_error_terms) = .{},
    /// Each world's tracker reward at a decision's end (`judge_rewards`: `robot.reward` of its tracking error).
    rewards: WorldArray(.world_f, .single) = .{},
    /// Each world's SuperMimic tracking reward at a decision's end (`judge_rewards`: `robot.superMimicTrackingOver`'s
    /// total) - its action rate and joint-limit terms not yet in it.
    super_mimic_tracking: WorldArray(.world_f, .single) = .{},
    /// Whether the termination rule fires on each world's tracking error at a decision's end (`robot.terminated`, 1 or
    /// 0) - before the episode's grace and aftermath weigh it.
    termination_rule: WorldArray(.world_f, .single) = .{},
    /// Each world's previous decision's action, for SuperMimic's action rate - zero at an episode's start.
    previous_actions: WorldArray(.world_f, .actions) = .{},
    /// THE POLICY's CHOICE AT THIS DECISION, explored (`explore_actions`): what the action filter blends into the
    /// action given at the previous decision (`filter_decision`), the blend becoming `actions`.
    chosen_actions: WorldArray(.world_f, .actions) = .{},
    /// EACH WORLD's SUPERMIMIC REWARD at a decision's end, whole: its tracking total and its penalties - the action
    /// rate,
    /// the joints past their limits, the effort's cost - as the CPU fleet's `superMimicReward` sums them.
    super_mimic_rewards: WorldArray(.world_f, .single) = .{},
    /// Each episode's discounted SuperMimic return so far, the discount's power at its next decision, and its rewards'
    /// sum - the fleet's `episode_discounted_returns`, `episode_discount_powers`, `episode_reward_sums`.
    episode_discounted_returns: WorldArray(.world_f, .single) = .{},
    episode_discount_powers: WorldArray(.world_f, .single) = .{},
    episode_reward_sums: WorldArray(.world_f, .single) = .{},
    /// THE SERVO's EFFORT through each world's decision (`robot.EffortSums`, `accumulate_effort`): the energy, and the
    /// torques' squares against the character's weight - zeroed at each decision's start (`zero_effort`).
    effort_energy: WorldArray(.world_f, .single) = .{},
    effort_torque_squares: WorldArray(.world_f, .single) = .{},
};

/// THE PER-WORLD INTEGERS OF `world_u`.
pub const WorldIntegersLayout = extern struct {
    /// Each world's OVERFLOW word: a bit for each fixed capacity the world ran past in a step (more contacts or
    /// constraint rows than its slots), so the host learns of it instead of the results going quietly wrong; cleared
    /// at the start of every step (`clear_overflow`).
    overflow: WorldArray(.world_u, .single) = .{},
    /// Whether each limit candidate is active this step - 1 while its distance is below its joint's margin.
    limit_candidate_active: WorldArray(.world_u, .limit_candidates) = .{},
    /// Whether each floor slot holds a contact this step (1) or is empty (0).
    floor_slot_filled: WorldArray(.world_u, .floor_slots) = .{},
    /// What each row is (`robot.ConstraintKind`, as robot.zig's `constraint_kind`): a joint limit's end, or one edge
    /// of a floor contact's friction pyramid.
    constraint_row_kind: WorldArray(.world_u, .constraint_rows) = .{},
    /// Where each row came from - a limit's candidate, or a contact's floor slot; which of the two, the row's kind
    /// says (`constraint_row_kind`). MuJoCo's `efc_id`.
    constraint_row_source: WorldArray(.world_u, .constraint_rows) = .{},
    /// How many rows the world has this step, never more than the capacity.
    constraint_row_count: WorldArray(.world_u, .single) = .{},
    /// The dof of each of a row's Jacobian slots (`constraint_jacobian_values`), and how many of the row's slots are in
    /// use.
    constraint_jacobian_dofs: WorldArray(.world_u, .constraint_row_nonzeros) = .{},
    constraint_jacobian_nonzero_count: WorldArray(.world_u, .constraint_rows) = .{},
    /// The rounds Newton ran this step (`newton_solve`). robot.zig's name: `solver_iterations`.
    newton_iterations: WorldArray(.world_u, .single) = .{},
    /// The points Newton's line searches evaluated this step, each a pass over the rows. robot.zig's name:
    /// `solver_line_evaluations` (MuJoCo's `neval`, summed).
    newton_line_evaluations: WorldArray(.world_u, .single) = .{},
    /// The tracking task's clip each world follows, and the frame of it the world is at (`Sim.setWorldClip`).
    world_clip: WorldArray(.world_u, .single) = .{},
    world_frame: WorldArray(.world_u, .single) = .{},
    /// THE EPISODE's COUNTERS, per world (`robot.EpisodeCounters`, `judge_episode`): decisions since its start,
    /// decisions left in an aftermath, the return streak, decisions since the loss.
    episode_steps: WorldArray(.world_u, .single) = .{},
    aftermath_steps_left: WorldArray(.world_u, .single) = .{},
    return_streaks: WorldArray(.world_u, .single) = .{},
    steps_since_loss: WorldArray(.world_u, .single) = .{},
    /// The last decision's verdict on each world's episode, a bit per `EpisodeFlag`.
    episode_flags: WorldArray(.world_u, .single) = .{},
    /// EACH WORLD's EPISODE NUMBER, advanced at every start (`begin_reset`): the counter of every draw its start makes
    /// (`robot.drawWord`), as the CPU fleet's `episode_numbers`.
    episode_numbers: WorldArray(.world_u, .single) = .{},
    /// THE CURRICULUM's VIEW OF EACH EPISODE (`judge_rewards`, `begin_reset`): its decisions so far, and the bin it
    /// started in - as the CPU fleet's `episode_decisions` and `start_bins`.
    episode_decisions: WorldArray(.world_u, .single) = .{},
    start_bins: WorldArray(.world_u, .single) = .{},
    /// The last decision's return length (`robot.EpisodeVerdict.return_length`), 0 unless it returned.
    return_lengths: WorldArray(.world_u, .single) = .{},
};

/// THE CONSTRAINT ROWS OF `efc_f`, every world's (MuJoCo's `efc_` arrays): each limit candidate's distance to its end
/// of the range, then the rows the active candidates become - packed from row 0 in candidate order,
/// `constraint_row_count` of them (in `world_u`, with the rows' candidates) - and each row's quantities as robot.zig's
/// `makeConstraints` and `projectConstraints` compute them. Rows past the count hold whatever an earlier step left:
/// nothing reads them.
pub const ConstraintRowsLayout = extern struct {
    /// Each candidate's distance to its end of the joint's range: q - lo for a lower end, hi - q for an upper. The
    /// end becomes a row while the distance is below the joint's margin.
    limit_candidate_distance: WorldArray(.efc_f, .limit_candidates) = .{},
    /// How far each row is inside its margin: the distance minus the margin, negative once the joint has gone past
    /// where the constraint starts to push. MuJoCo's name: `efc_pos` minus `efc_margin`.
    constraint_violation: WorldArray(.efc_f, .constraint_rows) = .{},
    /// Each row's Jacobian J - how the row's distance changes with each dof's velocity - kept SPARSE, as the GPU's
    /// ELLPACK form: every row has `Counts.row_nonzero_capacity` slots, row-major, each a value here and its dof in
    /// `world_u`'s `constraint_jacobian_dofs`, the row's first `constraint_jacobian_nonzero_count` slots in use, in dof
    /// order. Every slot sits at a place the model fixes, so no thread has to reserve room for another's. A limit's row
    /// has one nonzero, at its joint's dof: +1 for a lower end, -1 for an upper. MuJoCo's name: `efc_J`, which it keeps
    /// sparse too for models of more than 60 dofs.
    constraint_jacobian_values: WorldArray(.efc_f, .constraint_row_nonzeros) = .{},
    /// M^-1 J^T for each row, solved with the world's mass-matrix factor: the joint accelerations a unit force along
    /// the row would cause.
    constraint_inverse_inertia_jacobian: WorldArray(.efc_f, .constraint_row_dofs) = .{},
    /// The row's inertia as the constraint sees it (`StepOptions.constraint_inertia`): MuJoCo's default, from the
    /// reference pose's inverse weights, set by the rows kernel; or J M^-1 J^T exactly, MuJoCo's DIAGEXACT, set by the
    /// projection. MuJoCo's name: `efc_diagApprox`.
    constraint_inertia: WorldArray(.efc_f, .constraint_rows) = .{},
    /// How fast each row's distance is changing, J qdot. MuJoCo's name: `efc_vel`.
    constraint_velocity: WorldArray(.efc_f, .constraint_rows) = .{},
    /// The row's softness as the solver uses it, R = (1 - impedance) / impedance x the inertia: the larger R, the
    /// more the row gives. MuJoCo stores its inverse, `efc_D`.
    constraint_regularizer: WorldArray(.efc_f, .constraint_rows) = .{},
    /// The acceleration the row asks for, the spring-damper of its softness: -b x the velocity - k x the impedance x
    /// the violation. MuJoCo's name: `efc_aref`.
    constraint_target_acceleration: WorldArray(.efc_f, .constraint_rows) = .{},
    /// The force the solver found along each row: -r / R for the row's residual r at the answer, held at zero or
    /// above for a row that may only push. MuJoCo's name: `efc_force`.
    constraint_force: WorldArray(.efc_f, .constraint_rows) = .{},
};

/// THE TOPOLOGY AND INDEX TABLES OF `model_u` (`pack` writes them): robot.zig's own tables, then what the GPU derives
/// from them once per model - each body's DOF CHAIN (every dof from the root down to the body, in order: the dofs a
/// body's motion depends on) with its start and length, and the same chain as a mask, one bit per dof; each joint's
/// limited flag, each geom's type (MuJoCo's numbering, `GeomType`) and body, each site's body; and the tree's
/// BRANCHES, as MuJoCo Warp walks the tree for kinematics - one per leaf body, its chain of bodies from the root
/// down, the world excluded, all chains together with where each begins:
///
///     a pelvis (1) with two legs: thigh (2) and shin (3), other thigh (4) and other shin (5)
///     leaves 3 and 5:   body_branches [1 2 3 | 1 4 5]    body_branch_start [0 3 6]
///
/// One invocation per world and branch walks its chain root first, so every body is computed after its parent
/// (MJW's `_kinematics_branch`); a body on several branches is computed by each, to the same value. Each table's doc
/// names its counterpart in MuJoCo Warp's `Model`, so MJW's kernels can be read beside ours.
pub const ModelTablesLayout = extern struct {
    /// MJW: `body_parentid`.
    body_parent: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_subtreenum`.
    body_subtree_count: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_rootid`.
    body_root: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_jntadr`.
    body_first_joint: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_jntnum`.
    body_joint_count: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_dofadr`.
    body_first_dof: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_dofnum`.
    body_dof_count: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `jnt_type`.
    joint_type: ModelTable(.model_u, .joints) = .{},
    /// MJW: `jnt_bodyid`.
    joint_body: ModelTable(.model_u, .joints) = .{},
    /// MJW: `jnt_qposadr`.
    joint_first_coordinate: ModelTable(.model_u, .joints) = .{},
    /// MJW: `jnt_dofadr`.
    joint_first_dof: ModelTable(.model_u, .joints) = .{},
    /// MJW: `dof_parentid`.
    dof_parent: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `dof_bodyid`.
    dof_body: ModelTable(.model_u, .dofs) = .{},
    /// Whether any joint has damping: 1 or 0 - which of the velocity update's two paths a step takes. robot.zig's
    /// `has_dof_damping`.
    has_dof_damping: ModelTable(.model_u, .single) = .{},
    /// Each actuator's joint - a joint transmission's target. MJW: `actuator_trnid`.
    actuator_target: ModelTable(.model_u, .actuators) = .{},
    /// Each actuator's activation, `robot.no_dof` for an actuator without one. MJW: `actuator_actadr`.
    actuator_activation_index: ModelTable(.model_u, .actuators) = .{},
    /// Each actuator's activation dynamics, as `ActivationDynamics` numbers them. MJW: `actuator_dyntype`.
    actuator_dynamics: ModelTable(.model_u, .actuators) = .{},
    /// Whether each actuator's control is clamped to its range: 1 or 0. MJW: `actuator_ctrllimited`.
    actuator_control_limited: ModelTable(.model_u, .actuators) = .{},
    /// Whether each actuator's force is clamped to its range: 1 or 0. MJW: `actuator_forcelimited`.
    actuator_force_limited: ModelTable(.model_u, .actuators) = .{},
    /// THE ACTUATORS DOF BY DOF, the transpose of `actuator_target`: for each dof, the joint actuators acting on it, in
    /// actuator order - so a dof GATHERS their forces, in the order robot.zig adds them, where MJW scatters each force
    /// onto its dof with an atomic add. Each dof's first entry in `dof_actuators`, and how many follow.
    dof_first_actuator: ModelTable(.model_u, .dofs) = .{},
    dof_actuator_count: ModelTable(.model_u, .dofs) = .{},
    /// The actuators, listed dof by dof (`dof_first_actuator`).
    dof_actuators: ModelTable(.model_u, .actuators) = .{},
    /// MJW: `dof_jntid`.
    dof_joint: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `M_rownnz`.
    mass_row_entry_count: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `M_rowadr`.
    mass_row_start: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `M_colind`.
    mass_entry_column: ModelTable(.model_u, .mass_entries) = .{},
    /// Where each body's dof chain begins in `chain_dofs` (robotgpu's own).
    body_chain_start: ModelTable(.model_u, .bodies) = .{},
    /// How many dofs each body's chain holds (robotgpu's own).
    body_chain_length: ModelTable(.model_u, .bodies) = .{},
    /// Every body's chain of dofs, root first, all chains together (robotgpu's own).
    chain_dofs: ModelTable(.model_u, .chain_entries) = .{},
    /// Each body's chain as bits, `maskWords(nv)` words a body. MJW keeps the same as `body_isdofancestor`, a number
    /// per body and dof.
    body_ancestor_mask: ModelTable(.model_u, .ancestor_words) = .{},
    /// Each body's chain as each dof's PLACE in it, a number per body and dof (`no_chain_place` for a dof that does not
    /// move the body) - MJW's `body_isdofancestor` with the place in it. A contact row's nonzeros are its body's chain
    /// in that order, so the row's entry for a dof is read at once (`newtonRowEntry`).
    body_chain_place: ModelTable(.model_u, .body_dofs) = .{},
    /// MJW: `jnt_limited`.
    jnt_limited: ModelTable(.model_u, .joints) = .{},
    /// The joints with a range, in joint order: limit candidate c is the lower end (c even) or the upper end (c odd)
    /// of joint `limited_joints[c / 2]` - the order robot.zig's `makeConstraints` emits its limit rows in.
    limited_joints: ModelTable(.model_u, .limited_joints) = .{},
    /// MJW: `geom_type`.
    geom_type: ModelTable(.model_u, .geoms) = .{},
    /// MJW: `geom_bodyid`.
    geom_body: ModelTable(.model_u, .geoms) = .{},
    /// Each geom's first floor-contact slot (`Counts.floor_slot_count`), and how many it has - none for a geom fixed to
    /// the world, or of a shape the plane functions do not take.
    geom_first_floor_slot: ModelTable(.model_u, .geoms) = .{},
    geom_floor_slot_count: ModelTable(.model_u, .geoms) = .{},
    /// Each floor slot's geom - its body and its friction, for the slot's rows.
    floor_slot_geom: ModelTable(.model_u, .floor_slots) = .{},
    /// MJW: `site_bodyid`.
    site_body: ModelTable(.model_u, .sites) = .{},
    /// MJW: `body_branches`.
    body_branches: ModelTable(.model_u, .branch_bodies) = .{},
    /// MJW: `body_branch_start`.
    body_branch_start: ModelTable(.model_u, .branches_and_end) = .{},
    /// Each dof's limb (`robot.Model.dof_limb`), `robot.no_limb` for the free root's.
    dof_limb: ModelTable(.model_u, .dofs) = .{},
    /// THE TRACKING TASK's CLIPS (`packClips`): each clip's first frame among all the clips' frames, and its frames.
    clip_first_frame: ModelTable(.model_u, .clips) = .{},
    clip_frame_count: ModelTable(.model_u, .clips) = .{},
    /// Each clip's first curriculum bin among all the clips', its bins and each bin's frames (`begin_reset`).
    clip_first_bin: ModelTable(.model_u, .clips) = .{},
    clip_bin_count: ModelTable(.model_u, .clips) = .{},
    clip_bin_frames: ModelTable(.model_u, .clips) = .{},
};

/// THE REAL-VALUED CONSTANTS OF `model_f` (`pack` writes them): every body's, joint's, dof's, geom's and site's own
/// numbers, as robot.zig's `Model` holds them - a vector as four floats, an inertia as sixteen (`diag`, `off`, `h`,
/// then the mass and three of padding), a joint's range as two (zero for an unlimited joint, which `jnt_limited`
/// marks), a limit's softness as two (time constant, damping ratio) and its impedance as five (min, max, width,
/// midpoint, power), a geom's size as four in MuJoCo's convention (a sphere [r], a box [hx hy hz], a capsule and a
/// cylinder [r, half-height]; a convex hull's vertices join with convex collision, its size zero until then).
///
/// Where this differs from MuJoCo Warp, on purpose: a body's INERTIA is robot.zig's ten-number spatial form about the
/// body's frame (`robot.Inertia`), which robot.zig's own functions rotate and translate - MJW keeps the principal
/// moments with their frame (`body_local_inertia`, `body_iquat`, `body_centre_of_mass_offset`) and forms the spatial
/// inertia in `com_pos`; DAMPING is per joint (`joint_damping`), MuJoCo's per dof (`dof_damping`), the same numbers for
/// the hinges and slides a tracked robot has; FRICTION is one coefficient, MuJoCo's three (slide, spin, roll) arriving
/// with the collision fields.
pub const ModelConstantsLayout = extern struct {
    /// MJW: `qpos0` - each position coordinate's value in the reference pose, which a hinge's angle and a slide's
    /// distance are measured from (`robot.moveByJoint`'s `rest_coordinate`).
    reference_joint_positions: ModelTable(.model_f, .coordinates) = .{},
    /// MJW: `body_pos`.
    body_rest_position: ModelTable(.model_f, .body_vectors) = .{},
    /// MJW: `body_quat`.
    body_rest_rotation: ModelTable(.model_f, .body_vectors) = .{},
    /// MJW: `body_ipos`.
    body_centre_of_mass_offset: ModelTable(.model_f, .body_vectors) = .{},
    /// robot.zig's spatial inertia about the body's frame (this struct's doc says why MJW differs).
    body_local_inertia: ModelTable(.model_f, .body_inertias) = .{},
    /// MJW: `body_mass`.
    body_mass: ModelTable(.model_f, .bodies) = .{},
    /// MJW: `body_subtreemass`.
    body_subtree_mass: ModelTable(.model_f, .bodies) = .{},
    /// MJW: `jnt_axis`.
    joint_local_axis: ModelTable(.model_f, .joint_vectors) = .{},
    /// MJW: `jnt_pos`.
    joint_local_anchor: ModelTable(.model_f, .joint_vectors) = .{},
    /// MJW: `jnt_range`.
    joint_range: ModelTable(.model_f, .joint_pairs) = .{},
    /// MJW: `jnt_solref`.
    joint_limit_softness: ModelTable(.model_f, .joint_pairs) = .{},
    /// MJW: `jnt_solimp`.
    joint_limit_impedance: ModelTable(.model_f, .joint_impedances) = .{},
    /// MJW: `jnt_margin`.
    joint_limit_margin: ModelTable(.model_f, .joints) = .{},
    /// MJW: `dof_damping` (per dof there, per joint here).
    joint_damping: ModelTable(.model_f, .joints) = .{},
    /// MJW: `jnt_stiffness`.
    joint_stiffness: ModelTable(.model_f, .joints) = .{},
    /// MJW: `qpos_spring`.
    joint_reference_position: ModelTable(.model_f, .joints) = .{},
    /// MJW: `dof_armature`.
    dof_armature: ModelTable(.model_f, .dofs) = .{},
    /// MJW: `dof_invweight0` - each dof's inverse weight at the reference pose (`robot.Model.dof_inverse_weight`): the
    /// inertia a joint limit's softness is measured against under MuJoCo's default (`robot.ConstraintInertia`).
    dof_inverse_weight: ModelTable(.model_f, .dofs) = .{},
    /// MJW: `body_invweight0`'s first number - each body's inverse weight against a push at the reference pose
    /// (`robot.Model.body_translation_inverse_weight`): a contact's two bodies' weights are its rows' inertia there.
    body_translation_inverse_weight: ModelTable(.model_f, .bodies) = .{},
    /// Each actuator's gain, its gear folded in. MJW: `actuator_gainprm` (its first number).
    actuator_gain: ModelTable(.model_f, .actuators) = .{},
    /// Each actuator's bias - its constant, length and velocity terms, the gear folded in - padded to four.
    /// MJW: `actuator_biasprm` (its first three numbers).
    actuator_bias: ModelTable(.model_f, .actuator_vectors) = .{},
    /// Each actuator's control range, (0, 0) where the control is not clamped. MJW: `actuator_ctrlrange`.
    actuator_control_range: ModelTable(.model_f, .actuator_pairs) = .{},
    /// Each actuator's force range, (0, 0) where the force is not clamped. MJW: `actuator_forcerange`.
    actuator_force_range: ModelTable(.model_f, .actuator_pairs) = .{},
    /// Each actuator's filter time constant, zero for dynamics without one. MJW: `actuator_dynprm` (its first number).
    actuator_time_constant: ModelTable(.model_f, .actuators) = .{},
    /// MJW: `geom_pos`.
    geom_local_position: ModelTable(.model_f, .geom_vectors) = .{},
    /// MJW: `geom_quat`.
    geom_local_rotation: ModelTable(.model_f, .geom_vectors) = .{},
    /// MJW: `geom_size`.
    geom_size: ModelTable(.model_f, .geom_vectors) = .{},
    /// MJW: `geom_friction` (one coefficient here, three there).
    geom_friction: ModelTable(.model_f, .geoms) = .{},
    /// MJW: `site_pos`.
    site_local_position: ModelTable(.model_f, .site_vectors) = .{},
    /// MJW: `site_quat`.
    site_local_rotation: ModelTable(.model_f, .site_vectors) = .{},
    /// Every clip frame's coordinates, frame after frame and clip after clip (`packClips`): the pose
    /// `robot.applyAction` reads.
    clip_coordinates: ModelTable(.model_f, .clip_coordinates) = .{},
    /// Every clip frame's reference half of the observation, frame after frame and clip after clip (`packClips`, from
    /// `ClipPoses.reference_features`): what `observe_reference` copies.
    clip_reference_features: ModelTable(.model_f, .clip_reference_numbers) = .{},
    /// Every clip frame's reference bodies, frame after frame and clip after clip (`packClips`, from
    /// `ClipPoses.reference_bodies`): what the judgement reads as the reference (`ReferenceBodies`).
    clip_reference_bodies: ModelTable(.model_f, .clip_reference_body_numbers) = .{},
    /// THE JUDGEMENT's WEIGHTS: the tracker's reward weights (`robot.RewardWeights`), then SuperMimic's scales
    /// (`robot.SuperMimicScales`), each struct's numbers in its fields' order (`writeJudgementWeights`) - set once,
    /// read every decision, so a model table rather than the uniform.
    judgement_weights: ModelTable(.model_f, .judgement_numbers) = .{},
    /// The character's weight, its mass times gravity's magnitude (`robot.characterWeight`): the effort's torque scale.
    character_weight: ModelTable(.model_f, .model_single) = .{},
    /// EACH BALL's ROTATION BOX (`robot.RotationBox`, the fleet's `rotation_boxes`): low then high, four numbers each,
    /// low's fourth 1 for a boxed ball and 0 for any other joint (`rotationBoxNumbers`, `loadBallBox`).
    ball_boxes: ModelTable(.model_f, .joint_box_numbers) = .{},
    /// The character's mass (`robot.characterMass`): the effort's energy per unit of it.
    character_mass: ModelTable(.model_f, .model_single) = .{},
    /// Each clip's seconds between frames (`ClipPoses.frame_time`), for a reset world's velocities (`reset_pose`).
    clip_frame_time: ModelTable(.model_f, .clips) = .{},
    /// THE CURRICULUM's MIXTURE as running sums, bin after bin within each clip (`robot.startBinMixture`, summed in
    /// order): a start draws a uniform number and takes the first bin whose sum exceeds it. Uploaded by the host each
    /// round, after its folds (`rbt.updateStartBinReturn`) and the round's softmax and history.
    bin_running_sums: ModelTable(.model_f, .curriculum_bins) = .{},
    /// THE POLICY's NORMALISER (`policy_inputs`): each feature's mean and spread, a feature read by the policy as
    /// `(x - mean) / spread` - the learner's `Normalizer`, uploaded by the host whenever it changes.
    feature_means: ModelTable(.model_f, .state_features) = .{},
    feature_spreads: ModelTable(.model_f, .state_features) = .{},
};

/// THE LAYOUT: where every array the kernels read and write lives, one struct per arena, each field named after its
/// arena - `placeArrays` finds an arena's layout by that name.
pub const Layout = extern struct {
    world_f: WorldStateLayout = .{},
    world_u: WorldIntegersLayout = .{},
    efc_f: ConstraintRowsLayout = .{},
    model_u: ModelTablesLayout = .{},
    model_f: ModelConstantsLayout = .{},
};

/// A model option the device reads as on or off (`StepOptions`): robot.zig's, as the tracking settings carry it.
pub const Switch = robot.Switch;

/// THE SERVO's MODE (`StepOptions.servo`), robot.zig's: off, toward rest, or toward motion.
pub const ServoMode = robot.ServoMode;

/// A DECISION's VERDICT ON AN EPISODE, a bit each in `episode_flags` (`robot.EpisodeVerdict`'s booleans).
pub const EpisodeFlag = enum(u5) { lost, returned, in_aftermath, aftermath_begins, finished, ends_at_loss, capped };

/// The bit of `flag` in a world's `episode_flags`.
pub fn episodeFlagBit(flag: EpisodeFlag) u32 {
    return @as(u32, 1) << @backingInt(flag);
}

/// THE EPISODE's RULES as the device takes them (`StepOptions.setEpisodeRules`), robot.zig's: every length in
/// decisions.
pub const EpisodeOptions = robot.EpisodeOptions;

/// No head body: a robot judged without its head's height (`StepOptions.head_body`).
pub const no_head_body: u32 = 0xffff_ffff;

/// HOW A WORLD's CLIP IS CHOSEN at a start (`begin_reset`), robot.zig's: drawn, or the world's own by its index.
pub const ClipAssignment = robot.ClipAssignment;

/// What every kernel reads: the counts and the layout, in the uniform.
/// THE STEP'S OPTIONS, as the model holds them (`robot.Options`): gravity, which the accelerations start from - MJW's
/// `opt.gravity`, read by `_cacc_world` - the timestep the integrator advances by, and the bound on every joint
/// velocity (robot.zig's `max_velocity`) - the constraint solver's iteration limit and tolerance (robot.zig's
/// `opt.solver`), and which inertia each row's softness is measured against (`opt.constraint_inertia`). Gravity is
/// three scalars, not a vector, as an extern struct cannot hold a vector - the floor the worlds stand on, and the servo
/// that drives them. The options fill five 16-byte rows of the uniform.
pub const StepOptions = extern struct {
    gravity_x: f32 = 0,
    gravity_y: f32 = 0,
    gravity_z: f32 = 0,
    timestep: f32 = 0,
    max_velocity: f32 = 0,
    /// The most rounds Newton runs (`newton_solve`), and its tolerance - read in MuJoCo's scaled sense by its stops.
    newton_max_iterations: u32 = 0,
    newton_tolerance: f32 = 0,
    /// Under the reference pose's inertia (MuJoCo's default) the rows kernel sets each row's inertia and the
    /// projection solves nothing; under the exact one the projection solves J M^-1 J^T.
    constraint_inertia: robot.ConstraintInertia = .exact,
    /// Newton's line search: its iterations at most and its tolerance, a fraction of `newton_tolerance`
    /// (`robot.searchLineOver`); the third row of the uniform, padded.
    newton_line_search_iterations: u32 = 0,
    newton_line_search_tolerance: f32 = 0,
    /// Whether the model's constraints are simulated: off when its options disable them (`opt.disable_constraints`,
    /// MuJoCo's `mjDSBL_CONSTRAINT`), and then no world makes a row.
    constraints: Switch = .enabled,
    /// Whether Newton may begin from the last step's answer (`opt.warm_start`, MuJoCo's warm start) - taken unless it
    /// costs more than the free acceleration.
    warm_start: Switch = .enabled,
    /// THE FLOOR, a plane at height `floor_height` facing up: whether the worlds have one (`floor_contacts`), its
    /// friction and the margin within which a geom already has contacts against it (`robot.Floor`). Off unless set:
    /// a model's options hold no floor - whoever steps the worlds gives them one.
    floor_contacts: Switch = .disabled,
    floor_height: f32 = 0,
    floor_friction: f32 = 0,
    floor_margin: f32 = 0,
    /// THE SERVO (`robot.servoTorques`, the tracking task's law), its torques the worlds' applied forces: its mode, its
    /// spring's frequency in Hz and damping ratio, and the bound on the acceleration it asks of a joint
    /// (`robot.ServoLaw`). Off unless set (`Sim.setServo`).
    servo: ServoMode = .off,
    servo_frequency: f32 = 0,
    servo_damping: f32 = 0,
    servo_max_acceleration: f32 = 0,
    /// THE TRACKING TASK, the sixth row of the uniform: how far one unit of a world's action reaches, in radians
    /// (robot_track's `action_scale`, `Sim.setActionScale`), and the filter's share - how far a world's applied action
    /// moves toward its policy's before each physics step (`action_filter`, `Sim.setActionFilter`; 1 is none).
    action_scale: f32 = 0,
    action_filter: f32 = 1,
    /// Whether each limb's servo is at the stiffness its world's action gives it (`robot.limbSpringFrequency`); off,
    /// every dof's spring is at `servo_frequency`.
    limb_stiffness: Switch = .disabled,
    /// The character's head body, whose height the judgement measures (`robot.trackingErrorOver`'s `head`), or
    /// `no_head_body` for a robot judged without one.
    head_body: u32 = no_head_body,
    // ---- the episode's rules (`setEpisodeRules`): lengths in decisions ----
    grace_steps: u32 = 0,
    aftermath_steps: u32 = 0,
    return_steps: u32 = 0,
    max_steps: u32 = 0xffff_ffff,
    aftermath_world_count: u32 = 0,
    decision_physics_steps: u32 = 1,
    /// The run's draw seed (`robot.drawSeed` of the CPU fleet's), for every draw a world's start makes.
    draw_seed: u32 = 0,
    /// How a world's clip is chosen at a start (`ClipAssignment`).
    clip_assignment: ClipAssignment = .random,
    /// Whether a start rests the character on the floor, and how far above it (`rest_on_floor`, the fleet's task's
    /// `rest_on_floor` and `rest_clearance`); a row of the uniform with its padding.
    rest_on_floor: Switch = .disabled,
    rest_clearance: f32 = 0.001,
    _padding_rest_0: u32 = 0,
    _padding_rest_1: u32 = 0,
    /// A start's noise (`perturb_start`, the fleet's `start_noise`): each actuated dof turned by this many radians
    /// times a normal draw, and the root's horizontal velocity kicked by this many metres per second times two more; a
    /// row.
    start_noise_pose: f32 = 0,
    start_noise_velocity: f32 = 0,
    _padding_noise_0: u32 = 0,
    _padding_noise_1: u32 = 0,
    /// THE PUSHES (`push_worlds`, `start_in_trouble`, the fleet's `Pushes`), two rows: a scheduled push every this
    /// many decisions of an episode (0: none), random pushes at this rate per second, their speeds' range, the share of
    /// starts in trouble; then, set each decision by the host, the schedule's share (`Pushes.scheduleShare`), the
    /// decision's number (the counter of its pushes' draws) and its seconds.
    push_every: u32 = 0,
    push_rate_per_second: f32 = 0,
    push_speed_min: f32 = 0,
    push_speed_max: f32 = 0,
    push_start_share: f32 = 0,
    push_schedule_share: f32 = 0,
    decision_number: u32 = 0,
    decision_seconds: f32 = 0,
    /// Whether starts follow SuperMimic's curriculum (`begin_reset`, the accumulators of `judge_rewards`), and the
    /// discount of its episode returns; a row with its padding.
    curriculum: Switch = .disabled,
    curriculum_discount: f32 = 0.99,
    _padding_curriculum_0: u32 = 0,
    _padding_curriculum_1: u32 = 0,
    /// The exploration's spread this decision (`explore_actions`, the decision's clock): the noise scale times sigma; a
    /// row with its padding.
    exploration_spread: f32 = 0,
    _padding_exploration_0: u32 = 0,
    _padding_exploration_1: u32 = 0,
    _padding_exploration_2: u32 = 0,
    /// The limbs' stiffness share of the physics-rate filter (`filter_actions`), as `action_filter` is the joints'
    /// offsets' (`setActionFilter`); a row with its padding.
    stiffness_filter: f32 = 1,
    _padding_stiffness_filter_0: u32 = 0,
    _padding_stiffness_filter_1: u32 = 0,
    _padding_stiffness_filter_2: u32 = 0,
    /// THE ACTION FILTER AT EACH DECISION (`filter_decision`, the trainer's `filter` and `stiffness_filter`): the
    /// joints' offsets' share and the limbs' stiffnesses' share of the new choice; a row with its padding.
    decision_filter: f32 = 1,
    decision_stiffness_filter: f32 = 1,
    _padding_decision_filter_0: u32 = 0,
    _padding_decision_filter_1: u32 = 0,

    /// The options of `model`, as a step reads them.
    pub fn of(model: *const robot.Model) StepOptions {
        const gravity: Vec = model.opt.gravity;
        const options: StepOptions = .{
            .gravity_x = gravity[0],
            .gravity_y = gravity[1],
            .gravity_z = gravity[2],
            .timestep = model.opt.timestep,
            .max_velocity = model.opt.max_velocity,
            .newton_max_iterations = model.opt.solver.max_iterations,
            .newton_tolerance = model.opt.solver.tolerance,
            .constraint_inertia = model.opt.constraint_inertia,
            .newton_line_search_iterations = model.opt.solver.line_search_iterations,
            .newton_line_search_tolerance = model.opt.solver.line_search_tolerance,
            .constraints = if (model.opt.disable_constraints) .disabled else .enabled,
            .warm_start = if (model.opt.warm_start) .enabled else .disabled,
        };
        return options;
    }

    /// Gravity as a vector, the fourth lane zero.
    pub fn gravityVector(options: StepOptions) Vec {
        const gravity: Vec = .{ options.gravity_x, options.gravity_y, options.gravity_z, 0 };
        return gravity;
    }

    /// THE FLOOR every world stands on, for the steps after: a plane facing up at the height of `ground.plane.point`,
    /// with its friction and margin (`robot.Floor`) - the floor of robot.zig's `pushFloorContacts`, its contacts made
    /// by `floor_contacts`. The device's floor is horizontal: a plane facing any other way is refused.
    pub fn setFloor(options: *StepOptions, ground: robot.Floor) error{FloorNotHorizontal}!void {
        const normal: robot.Vec = ground.plane.normal;
        const faces_up: bool = normal[0] == 0 and normal[1] == 0 and normal[2] == 1;
        if (!faces_up) {
            return error.FloorNotHorizontal;
        }
        options.floor_contacts = .enabled;
        options.floor_height = ground.plane.point[2];
        options.floor_friction = ground.friction;
        options.floor_margin = ground.margin;
    }

    /// THE SERVO every world is driven by, for the steps after: robot.zig's law (`robot.servoTorques`) with `law`'s
    /// spring and bound, toward rest or toward motion (`mode`).
    pub fn setServo(options: *StepOptions, law: robot.ServoLaw, mode: ServoMode) void {
        options.servo = mode;
        options.servo_frequency = law.frequency;
        options.servo_damping = law.damping;
        options.servo_max_acceleration = law.max_acceleration;
    }

    /// How far one unit of a world's action reaches, in radians (robot_track's `action_scale`).
    pub fn setActionScale(options: *StepOptions, scale: f32) void {
        options.action_scale = scale;
    }

    /// The filter's shares (robot_track's `action_filter` and `stiffnessFilter`): how far each world's applied action
    /// moves toward its policy's before each physics step - the joints' offsets by the first, the limbs' stiffnesses
    /// by the second; 1 is no filter.
    pub fn setActionFilter(
        options: *StepOptions,
        offsets_factor: f32,
        stiffness_factor: f32,
    ) void {
        options.action_filter = offsets_factor;
        options.stiffness_filter = stiffness_factor;
    }

    /// Whether each limb's servo is at the stiffness its world's action gives it, for the steps after.
    pub fn setLimbStiffness(options: *StepOptions, limb_stiffness: Switch) void {
        options.limb_stiffness = limb_stiffness;
    }

    /// The head body the judgement measures, or none (robot_track's `Fleet.head`).
    pub fn setHeadBody(options: *StepOptions, head: ?usize) void {
        options.head_body = if (head) |body| @intCast(body) else no_head_body;
    }

    /// The episode's rules (`EpisodeOptions`), for the decisions after.
    pub fn setEpisodeRules(options: *StepOptions, rules: EpisodeOptions) void {
        options.grace_steps = rules.grace_steps;
        options.aftermath_steps = rules.aftermath_steps;
        options.return_steps = rules.return_steps;
        options.max_steps = rules.max_steps;
        options.aftermath_world_count = rules.aftermath_world_count;
        options.decision_physics_steps = rules.decision_physics_steps;
    }
};

pub const Params = extern struct {
    counts: Counts,
    layout: Layout,
    options: StepOptions = .{},
};

/// Refuse, at compile time, an ARRAY anywhere inside a uniform's struct: a uniform buffer's layout rules align every
/// array element to 16 bytes, so `[3]u32` at offset 52 is invalid there even though Zig lays it out packed - the
/// SPIR-V validator rejects the module. Scalars and nested structs of whole 16-byte rows are what a uniform holds.
fn requireNoArraysInUniform(comptime Struct: type) void {
    // Every field of the layout's every array visited: more than Zig's default budget.
    @setEvalBranchQuota(100_000);
    for (@typeInfo(Struct).@"struct".field_names) |field_name| {
        const FieldType: type = @FieldType(Struct, field_name);
        switch (@typeInfo(FieldType)) {
            .array => @compileError("uniform field `" ++ field_name ++ "` is an array: use scalar fields"),
            .@"struct" => requireNoArraysInUniform(FieldType),
            else => {},
        }
    }
}

comptime {
    requireNoArraysInUniform(Params);
    // Every array's place is one 16-byte row, so a layout of them is packed as a uniform expects; `Params` is a whole
    // number of rows.
    const arrays_are_rows: bool = @sizeOf(WorldArray(.world_f, .single)) == 16 and
        @sizeOf(ModelTable(.model_u, .single)) == 16;
    if (!arrays_are_rows) {
        @compileError("WorldArray and ModelTable must be 16 bytes");
    }
    if (@sizeOf(Params) % 16 != 0) {
        @compileError("Params must be a whole number of 16-byte rows");
    }
}

/// How many elements each arena may hold: `robotgpu_sizes`' lengths unless a caller - a test - says less.
pub const Capacities = struct {
    world_f: u32 = sizes.world_f,
    world_u: u32 = sizes.world_u,
    efc_f: u32 = sizes.efc_f,
    model_u: u32 = sizes.model_u,
    model_f: u32 = sizes.model_f,
};

/// A layout that does not fit its arena, by the arena's name.
pub const LayoutError = error{
    /// `world_f`: the per-world state of this many worlds of this model needs more floats than the arena holds.
    WorldStateTooSmall,
    /// `world_u`: the per-world integers of this many worlds need more words than the arena holds.
    WorldIntegersTooSmall,
    /// `efc_f`: the constraint rows of this many worlds of this model need more floats than the arena holds.
    ConstraintRowsTooSmall,
    /// `model_u`: this model's topology and index tables need more words than the arena holds.
    ModelTablesTooSmall,
    /// `model_f`: this model's real-valued constants need more floats than the arena holds.
    ModelConstantsTooSmall,
};

/// Four-number alignment: every array's start and every world's block.
fn padToVector(numbers: u32) u32 {
    return (numbers + 3) / 4 * 4;
}

/// Place the arrays of `arena`'s layout one after another from the arena's start, each block padded to four numbers -
/// a per-world array once per world, a model table once - and say whether they fit the arena's `capacity`. The check
/// comes before any offset is narrowed to 32 bits, so nothing is clamped; and each array's type must name `arena` as
/// its home, so an array declared in another arena's layout does not compile.
fn placeArrays(
    comptime arena: Arena,
    out_layout: *Layout,
    counts: Counts,
    capacity: u32,
) bool {
    const ArenaLayout: type = @FieldType(Layout, @tagName(arena));
    const arena_layout: *ArenaLayout = &@field(out_layout, @tagName(arena));
    var next_free: u64 = 0;
    inline for (@typeInfo(ArenaLayout).@"struct".field_names) |array_name| {
        const ArrayType: type = @FieldType(ArenaLayout, array_name);
        const in_its_own_arena: bool = ArrayType.home == arena;
        if (!in_its_own_arena) {
            @compileError("`" ++ array_name ++ "` sits in the layout of " ++ @tagName(arena) ++
                ", but its type lives in " ++ @tagName(ArrayType.home));
        }
        const numbers: u32 = ArrayType.item_kind.numbersPerCopy(counts);
        const stride: u32 = padToVector(numbers);
        const copies: u32 = if (ArrayType.per_world) counts.world_count else 1;
        const end: u64 = next_free + @as(u64, stride) * copies;
        const fits_arena: bool = end <= capacity;
        if (!fits_arena) {
            return false;
        }
        // `next_free` <= `end` <= `capacity`, a u32: the offset fits.
        const placed: ArrayType = .{ .offset = @intCast(next_free), .stride = stride, .count = numbers };
        @field(arena_layout, array_name) = placed;
        next_free = end;
    }
    return true;
}

/// THE LAYOUT FOR A MODEL'S COUNTS: each arena's arrays placed in their declared order (`placeArrays`) - the
/// per-world ones once per world, the model's tables once - every block padded to four numbers, and an arena too small
/// for its arrays refused by name.
pub fn layoutFor(counts: Counts, capacities: Capacities) LayoutError!Layout {
    var layout: Layout = .{};
    const world_state_fits: bool = placeArrays(.world_f, &layout, counts, capacities.world_f);
    if (!world_state_fits) {
        return LayoutError.WorldStateTooSmall;
    }
    const world_integers_fit: bool = placeArrays(.world_u, &layout, counts, capacities.world_u);
    if (!world_integers_fit) {
        return LayoutError.WorldIntegersTooSmall;
    }
    const constraint_rows_fit: bool = placeArrays(.efc_f, &layout, counts, capacities.efc_f);
    if (!constraint_rows_fit) {
        return LayoutError.ConstraintRowsTooSmall;
    }
    const model_tables_fit: bool = placeArrays(.model_u, &layout, counts, capacities.model_u);
    if (!model_tables_fit) {
        return LayoutError.ModelTablesTooSmall;
    }
    const model_constants_fit: bool = placeArrays(.model_f, &layout, counts, capacities.model_f);
    if (!model_constants_fit) {
        return LayoutError.ModelConstantsTooSmall;
    }
    return layout;
}

// ==================================================================================================================
// PACKING A MODEL
// ==================================================================================================================
//
// A robot.zig model turned into the arenas' model images, on the host, once per model: its counts (`countsOf`), its
// topology into `model_u` and its constants into `model_f` (`pack`).

/// A geom's type, MUJOCO'S NUMBERING (`mjtGeom`) - the numbers MuJoCo Warp's collision dispatch reads - packed in
/// `geom_type`. robot.zig's shapes map onto it (`geomType`); a convex hull is MuJoCo's convex mesh.
pub const GeomType = enum(u32) {
    plane = 0,
    height_field = 1,
    sphere = 2,
    capsule = 3,
    ellipsoid = 4,
    cylinder = 5,
    box = 6,
    mesh = 7,
};

/// A robot.zig shape's MuJoCo geom type.
fn geomType(shape: robot.GeomShape) GeomType {
    return switch (shape) {
        .sphere => .sphere,
        .box => .box,
        .capsule => .capsule,
        .cylinder => .cylinder,
        .hull => .mesh,
    };
}

comptime {
    // A joint's type is packed as robot.zig's own tag, which must be MuJoCo's numbering (`mjtJoint`) - the numbers
    // MuJoCo Warp's kernels switch on: free 0, ball 1, slide 2, hinge 3.
    const in_mujoco_order: bool = @backingInt(robot.JointType.free) == 0 and @backingInt(robot.JointType.ball) == 1 and
        @backingInt(robot.JointType.slide) == 2 and @backingInt(robot.JointType.hinge) == 3;
    if (!in_mujoco_order) {
        @compileError("robot.JointType must stay in MuJoCo's order: free, ball, slide, hinge");
    }
}

/// THE PER-WORLD STATE OF `world_f`, in the order `layoutFor` places it: the generalized vectors, then what each body,
/// dof and geom derives (smooth dynamics' arrays - the constraint and contact arrays join with their stages). The
/// arrays carry MuJoCo Warp's `Data` names as their own. Where the form differs: the spatial inertias (`body_inertias`,
/// `composite_inertias`) are robot.zig's - `diag`, `off`, `h` and the mass, as the model's `body_local_inertia` is -
/// where MuJoCo keeps ten numbers. The dofs of `body`'s chain - its own and every ancestor's - by walking up its
/// parents.
fn chainLength(model: *const robot.Model, body: u32) u32 {
    var dofs_on_chain: u32 = 0;
    var ancestor: u32 = body;
    while (ancestor != 0) {
        dofs_on_chain += model.body_dof_count[ancestor];
        ancestor = model.body_parent[ancestor];
    }
    return dofs_on_chain;
}

/// The bodies from the root down to `body`, the world excluded - a branch's length when `body` is a leaf.
fn bodyDepth(model: *const robot.Model, body: u32) u32 {
    var depth: u32 = 0;
    var ancestor: u32 = body;
    while (ancestor != 0) {
        depth += 1;
        ancestor = model.body_parent[ancestor];
    }
    return depth;
}

/// Whether `body` is a LEAF of the tree - no body below it. Bodies are depth-first (robot.zig's `countSubtrees`), so a
/// leaf is a body whose subtree is itself alone.
fn isLeaf(model: *const robot.Model, body: u32) bool {
    return body != 0 and model.body_subtree_count[body] == 1;
}

/// A model's counts at `world_count` worlds, read from the model itself - `chain_dof_count` summed over its bodies'
/// chains, and the branches over its leaves.
pub fn countsOf(model: *const robot.Model, nworld: u32) Counts {
    var chain_entries: u32 = 0;
    var branch_count: u32 = 0;
    var branch_bodies: u32 = 0;
    var limited_joints: u32 = 0;
    for (model.joint_range) |range| {
        limited_joints += @intFromBool(range != null);
    }
    var floor_slots: u32 = 0;
    for (model.geom_shape, model.geom_body) |shape, geom_body| {
        if (geom_body != robot.world_body) {
            floor_slots += robot.floorSlotsOf(shape);
        }
    }
    var longest_chain: u32 = 0;
    var body: u32 = 0;
    while (body < model.body_count) : (body += 1) {
        chain_entries += chainLength(model, body);
        longest_chain = @max(longest_chain, chainLength(model, body));
        if (isLeaf(model, body)) {
            branch_count += 1;
            branch_bodies += bodyDepth(model, body);
        }
    }
    const counts: Counts = .{
        .world_count = nworld,
        .body_count = model.body_count,
        .joint_count = model.joint_count,
        .coordinate_count = model.coordinate_count,
        .dof_count = model.dof_count,
        .geom_count = model.geom_count,
        .actuator_count = model.actuator_count,
        .activation_count = model.activation_count,
        .mass_entry_count = model.mass_entry_count,
        .chain_dof_count = chain_entries,
        .site_count = model.site_count,
        .branch_count = branch_count,
        .branch_body_count = branch_bodies,
        .limited_joint_count = limited_joints,
        .limit_candidate_count = 2 * limited_joints,
        .floor_slot_count = floor_slots,
        // Every limit candidate a row, and four a floor slot - a contact's friction pyramid, MuJoCo's for `condim` 3.
        .constraint_capacity = 2 * limited_joints + 4 * floor_slots,
        // A limit's row has one nonzero, its joint's dof; a contact's, every dof of its body's chain.
        .row_nonzero_capacity = @max(@intFromBool(limited_joints > 0), if (floor_slots > 0) longest_chain else 0),
        // A policy's action reaches every dof but the free root's - a policy cannot push on the world - and then each
        // limb's stiffness.
        .action_count = @as(u32, @intCast(robot.actionSize(model))) + model.limb_count,
        .limb_count = model.limb_count,
        .root_body = robot.rootBody(model),
    };
    return counts;
}

/// AN ACTUATOR'S ACTIVATION DYNAMICS, as `actuator_dynamics` numbers them: robot.zig's `Activation` without its
/// parameters - the time constant has a table of its own (`actuator_time_constant`). `activationDynamicsOf` gives
/// a robot.zig dynamics its number, through a switch the compiler checks is exhaustive.
pub const ActivationDynamics = enum(u32) {
    none = 0,
    integrator = 1,
    filter = 2,
    filter_exact = 3,
};

/// An actuator's dynamics as the device numbers them. The switch is exhaustive, so a kind of dynamics robot.zig gains
/// fails the build here instead of reaching the device unnumbered.
pub fn activationDynamicsOf(activation: robot.Activation) ActivationDynamics {
    return switch (activation) {
        .none => .none,
        .integrator => .integrator,
        .filter => .filter,
        .filter_exact => .filter_exact,
    };
}

/// THE MODEL'S TOPOLOGY, PACKED into `model_u` - an image of the arena - at `tables`' places: robot.zig's own index
/// tables copied, and each body's dof chain derived - the root's dofs first, the body's own last, as the motion of a
/// body is built from its ancestors' outward:
///
///     body 3 (shin), its ancestors 1 (pelvis, a free joint: dofs 0-5) and 2 (thigh, a ball: dofs 6-8):
///     chain [0 1 2 3 4 5 | 6 7 8 | 9]        mask: bits 0 to 9 set
fn packTopology(
    model: *const robot.Model,
    tables: ModelTablesLayout,
    model_u: []u32,
) void {
    tables.body_parent.fill(model_u, model.body_parent);
    tables.body_subtree_count.fill(model_u, model.body_subtree_count);
    tables.body_root.fill(model_u, model.body_root);
    tables.body_first_joint.fill(model_u, model.body_first_joint);
    tables.body_joint_count.fill(model_u, model.body_joint_count);
    tables.body_first_dof.fill(model_u, model.body_first_dof);
    tables.body_dof_count.fill(model_u, model.body_dof_count);
    for (model.joint_type, 0..) |joint_type, joint| {
        model_u[tables.joint_type.at(@intCast(joint))] = @backingInt(joint_type);
    }
    tables.joint_body.fill(model_u, model.joint_body);
    tables.joint_first_coordinate.fill(model_u, model.joint_first_coordinate);
    tables.joint_first_dof.fill(model_u, model.joint_first_dof);
    tables.dof_parent.fill(model_u, model.dof_parent);
    tables.dof_body.fill(model_u, model.dof_body);
    tables.dof_limb.fill(model_u, model.dof_limb);
    model_u[tables.has_dof_damping.at(0)] = @intFromBool(model.has_dof_damping);
    // The actuators: their joints, their activations, their dynamics, and whether they clamp.
    tables.actuator_target.fill(model_u, model.actuator_target);
    tables.actuator_activation_index.fill(model_u, model.actuator_activation_index);
    for (model.actuator_activation_dynamics, model.actuator_control_range, model.actuator_force_range, 0..) |
        dynamics,
        control_range,
        force_range,
        actuator,
    | {
        const actuator_index: u32 = @intCast(actuator);
        const dynamics_number: u32 = @backingInt(activationDynamicsOf(dynamics));
        model_u[tables.actuator_dynamics.at(actuator_index)] = dynamics_number;
        model_u[tables.actuator_control_limited.at(actuator_index)] = @intFromBool(control_range != null);
        model_u[tables.actuator_force_limited.at(actuator_index)] = @intFromBool(force_range != null);
    }
    // The transpose: dof by dof, the joint actuators acting on each, in actuator order.
    var listed: u32 = 0;
    var transposed_dof: u32 = 0;
    while (transposed_dof < model.dof_count) : (transposed_dof += 1) {
        const first_listed: u32 = listed;
        for (model.actuator_kind, model.actuator_dof, 0..) |kind, actuator_dof, actuator| {
            if (kind == .joint and actuator_dof == transposed_dof) {
                model_u[tables.dof_actuators.at(listed)] = @intCast(actuator);
                listed += 1;
            }
        }
        model_u[tables.dof_first_actuator.at(transposed_dof)] = first_listed;
        model_u[tables.dof_actuator_count.at(transposed_dof)] = listed - first_listed;
    }
    tables.dof_joint.fill(model_u, model.dof_joint);
    tables.mass_row_entry_count.fill(model_u, model.mass_row_entry_count);
    tables.mass_row_start.fill(model_u, model.mass_row_start);
    tables.mass_entry_column.fill(model_u, model.mass_entry_column);
    // The chains: each body's ancestors from the root down, then the body, each contributing its dofs in order. The
    // masks start as zeros (`pack` zeroes the image) and gain a bit per chain dof.
    const words_per_mask: u32 = maskWords(model.dof_count);
    var next_chain_entry: u32 = 0;
    var body: u32 = 0;
    while (body < model.body_count) : (body += 1) {
        const chain_entries: u32 = chainLength(model, body);
        model_u[tables.body_chain_start.at(body)] = next_chain_entry;
        model_u[tables.body_chain_length.at(body)] = chain_entries;
        // No dof has a place in the chain until the walk below gives it one.
        var unplaced_dof: u32 = 0;
        while (unplaced_dof < model.dof_count) : (unplaced_dof += 1) {
            model_u[tables.body_chain_place.at(body * model.dof_count + unplaced_dof)] = no_chain_place;
        }
        // Walk up from the body, filling the chain from its end, so the root's dofs land first.
        var chain_fill_end: u32 = next_chain_entry + chain_entries;
        var ancestor: u32 = body;
        while (ancestor != 0) {
            const dof_count: u32 = model.body_dof_count[ancestor];
            const first_dof: u32 = model.body_first_dof[ancestor];
            chain_fill_end -= dof_count;
            var dof_offset: u32 = 0;
            while (dof_offset < dof_count) : (dof_offset += 1) {
                const dof: u32 = first_dof + dof_offset;
                model_u[tables.chain_dofs.at(chain_fill_end + dof_offset)] = dof;
                const place_in_chain: u32 = chain_fill_end - next_chain_entry + dof_offset;
                model_u[tables.body_chain_place.at(body * model.dof_count + dof)] = place_in_chain;
                const mask_word_at: u32 = tables.body_ancestor_mask.at(body * words_per_mask + dof / 32);
                const dof_bit: u32 = @as(u32, 1) << @intCast(dof % 32);
                model_u[mask_word_at] |= dof_bit;
            }
            ancestor = model.body_parent[ancestor];
        }
        next_chain_entry += chain_entries;
    }
    // The branches: each leaf's bodies from the root down, filled from the leaf up, leaves in body order (MJW's).
    var next_branch_entry: u32 = 0;
    var branch_index: u32 = 0;
    var leaf: u32 = 0;
    while (leaf < model.body_count) : (leaf += 1) {
        if (!isLeaf(model, leaf)) {
            continue;
        }
        model_u[tables.body_branch_start.at(branch_index)] = next_branch_entry;
        const depth: u32 = bodyDepth(model, leaf);
        var branch_fill_at: u32 = next_branch_entry + depth;
        var ancestor: u32 = leaf;
        while (ancestor != 0) {
            branch_fill_at -= 1;
            model_u[tables.body_branches.at(branch_fill_at)] = ancestor;
            ancestor = model.body_parent[ancestor];
        }
        next_branch_entry += depth;
        branch_index += 1;
    }
    model_u[tables.body_branch_start.at(branch_index)] = next_branch_entry;
}

/// A geom's size in MuJoCo's convention, four floats: a sphere [r], a box its half-extents, a capsule and a cylinder
/// [r, half-height]; a convex hull none yet (its vertices join with convex collision).
fn geomSize(shape: robot.GeomShape) Vec {
    return switch (shape) {
        .sphere => |sphere| .{ sphere.radius, 0, 0, 0 },
        .box => |box| .{ box.half_extent[0], box.half_extent[1], box.half_extent[2], 0 },
        .capsule => |capsule| .{ capsule.radius, capsule.half_height, 0, 0 },
        .cylinder => |cylinder| .{ cylinder.radius, cylinder.half_height, 0, 0 },
        .hull => .{ 0, 0, 0, 0 },
    };
}

/// THE FLOOR SLOTS, laid out in robot.zig's contact order: `makeConstraints` sorts contacts before making their rows
/// (`contactBefore`: the first body, the second, then the contact's key, geom << 3 | slot) - for the floor, by the
/// geom's body, then the geom, then the slot. Laid out so, the device's rows come in robot.zig's order for any model,
/// whether or not its geoms are numbered in body order. Each moving geom gets its first slot and its count
/// (`robot.floorSlotsOf`), each slot its geom; a geom fixed to the world keeps none - the zeros `pack` starts from -
/// as robot.zig's floor skips it.
fn packFloorSlots(
    model: *const robot.Model,
    tables: ModelTablesLayout,
    model_u: []u32,
) void {
    var next_floor_slot: u32 = 0;
    var body: u32 = 0;
    while (body < model.body_count) : (body += 1) {
        if (body == robot.world_body) {
            continue;
        }
        for (model.geom_shape, model.geom_body, 0..) |shape, geom_body, geom| {
            if (geom_body != body) {
                continue;
            }
            const geom_index: u32 = @intCast(geom);
            const floor_slots: u32 = robot.floorSlotsOf(shape);
            model_u[tables.geom_first_floor_slot.at(geom_index)] = next_floor_slot;
            model_u[tables.geom_floor_slot_count.at(geom_index)] = floor_slots;
            var slot_of_geom: u32 = 0;
            while (slot_of_geom < floor_slots) : (slot_of_geom += 1) {
                model_u[tables.floor_slot_geom.at(next_floor_slot + slot_of_geom)] = geom_index;
            }
            next_floor_slot += floor_slots;
        }
    }
}

/// THE CONSTANTS half of `pack`: every real-valued table of `model_f` (`ModelConstantsLayout` says how each is laid
/// out), and the flags and kinds `model_u` keeps beside them - each joint's limited flag, each geom's type and body,
/// each site's body.
fn packConstants(
    model: *const robot.Model,
    layout: Layout,
    model_u: []u32,
    model_f: []f32,
) void {
    const constants: ModelConstantsLayout = layout.model_f;
    const tables: ModelTablesLayout = layout.model_u;
    constants.reference_joint_positions.fill(model_f, model.reference_joint_positions);
    constants.body_rest_position.fillVectors(model_f, model.body_rest_position);
    constants.body_rest_rotation.fillVectors(model_f, model.body_rest_rotation);
    constants.body_centre_of_mass_offset.fillVectors(model_f, model.body_centre_of_mass_offset);
    for (model.body_local_inertia, 0..) |inertia, body| {
        const first: u32 = constants.body_local_inertia.at(@intCast(body));
        model_f[first..][0..4].* = inertia.diag;
        model_f[first + 4 ..][0..4].* = inertia.off;
        model_f[first + 8 ..][0..4].* = inertia.h;
        model_f[first + 12 ..][0..4].* = .{ inertia.mass, 0, 0, 0 };
    }
    constants.body_mass.fill(model_f, model.body_mass);
    constants.body_subtree_mass.fill(model_f, model.body_subtree_mass);
    constants.joint_local_axis.fillVectors(model_f, model.joint_local_axis);
    constants.joint_local_anchor.fillVectors(model_f, model.joint_local_anchor);
    var limited_joints_packed: u32 = 0;
    for (model.joint_range, 0..) |range, joint| {
        const joint_index: u32 = @intCast(joint);
        const limited: bool = range != null;
        const bounds: [2]f32 = range orelse .{ 0, 0 };
        model_f[constants.joint_range.at(joint_index)..][0..2].* = bounds;
        model_u[tables.jnt_limited.at(joint_index)] = @intFromBool(limited);
        if (limited) {
            model_u[tables.limited_joints.at(limited_joints_packed)] = joint_index;
            limited_joints_packed += 1;
        }
    }
    for (model.joint_limit_softness, model.joint_limit_impedance, 0..) |softness, impedance, joint| {
        const joint_index: u32 = @intCast(joint);
        const softness_at: u32 = constants.joint_limit_softness.at(joint_index);
        model_f[softness_at..][0..2].* = .{ softness.time_const_s, softness.damp_ratio };
        const impedance_at: u32 = constants.joint_limit_impedance.at(joint_index);
        model_f[impedance_at..][0..5].* = .{
            impedance.min,
            impedance.max,
            impedance.width,
            impedance.midpoint,
            impedance.power,
        };
    }
    constants.joint_limit_margin.fill(model_f, model.joint_limit_margin);
    constants.joint_damping.fill(model_f, model.joint_damping);
    constants.joint_stiffness.fill(model_f, model.joint_stiffness);
    constants.joint_reference_position.fill(model_f, model.joint_reference_position);
    constants.actuator_gain.fill(model_f, model.actuator_gain);
    for (model.actuator_bias, model.actuator_activation_dynamics, 0..) |bias, dynamics, actuator| {
        const actuator_index: u32 = @intCast(actuator);
        model_f[constants.actuator_bias.at(actuator_index)..][0..4].* = .{ bias[0], bias[1], bias[2], 0 };
        const time_constant: f32 = switch (dynamics) {
            .none, .integrator => 0,
            .filter, .filter_exact => |filter| filter.time_const_s,
        };
        model_f[constants.actuator_time_constant.at(actuator_index)] = time_constant;
    }
    for (model.actuator_control_range, model.actuator_force_range, 0..) |control_range, force_range, actuator| {
        const actuator_index: u32 = @intCast(actuator);
        const no_range: [2]f32 = .{ 0, 0 };
        model_f[constants.actuator_control_range.at(actuator_index)..][0..2].* = control_range orelse no_range;
        model_f[constants.actuator_force_range.at(actuator_index)..][0..2].* = force_range orelse no_range;
    }
    constants.dof_armature.fill(model_f, model.dof_armature);
    constants.dof_inverse_weight.fill(model_f, model.dof_inverse_weight);
    constants.body_translation_inverse_weight.fill(model_f, model.body_translation_inverse_weight);
    constants.geom_local_position.fillVectors(model_f, model.geom_local_position);
    constants.geom_local_rotation.fillVectors(model_f, model.geom_local_rotation);
    for (model.geom_shape, 0..) |shape, geom| {
        const geom_index: u32 = @intCast(geom);
        model_f[constants.geom_size.at(geom_index)..][0..4].* = geomSize(shape);
        model_u[tables.geom_type.at(geom_index)] = @backingInt(geomType(shape));
    }
    packFloorSlots(model, tables, model_u);
    constants.geom_friction.fill(model_f, model.geom_friction);
    tables.geom_body.fill(model_u, model.geom_body);
    constants.site_local_position.fillVectors(model_f, model.site_local_position);
    constants.site_local_rotation.fillVectors(model_f, model.site_local_rotation);
    tables.site_body.fill(model_u, model.site_body);
}

/// The largest model `newton_solve` holds in workgroup memory (`newton_workgroup_bytes`): the order of its Hessian -
/// Geno has 75 dofs - and its constraint rows. A model beyond either is refused (`ModelError`).
pub const max_newton_dofs: u32 = 76;
pub const max_newton_rows: u32 = 256;

/// What a model may have that the device does not simulate yet - refused by name before anything is packed, so a
/// model never runs on the device with part of its physics silently missing.
pub const ModelError = error{
    /// Tendons: a tendon's length and velocity, its spring and damper, and the actuators that pull on it need kernels
    /// of their own (MJW's `_tendon_velocity`, its tendon passive forces and tendon actuators), which the device does
    /// not have yet. A model with tendons runs on robot.zig.
    TendonsNotSimulated,
    /// Equality constraints need rows the device does not make yet - its joint limits' rows and its floor's contacts'
    /// it does, and solves them in the step. The device's only contacts are its floor's (`Sim.setFloor`), robot.zig's
    /// `pushFloorContacts`: no body touches another. A model whose options disable its constraints
    /// (`opt.disable_constraints`, MuJoCo's `mjDSBL_CONSTRAINT`) steps without any, on robot.zig as on the device.
    ConstraintsNotSimulated,
    /// More dofs than Newton's working set is wide (`max_newton_dofs`): its Hessian and its vectors, in workgroup
    /// memory.
    TooManyDofs,
    /// More rows than Newton's working set holds (`max_newton_rows`), counting the most a world can have
    /// (`Counts.constraint_capacity`: two a limit candidate, four a floor slot) - so no row is ever left out of a
    /// solve.
    TooManyRows,
};

/// The model refused, by name, if it has anything the device does not simulate (`ModelError`) - the first thing a
/// `Sim` does with a model, before a pipe, an arena or an image is made for it.
pub fn refuseUnsimulatedFeatures(model: *const robot.Model) ModelError!void {
    // Each condition returns as soon as it is met, the cheap first: counts and flags, then the rows' capacity, which
    // takes a pass over the model. Joint limits and a floor's contacts the device simulates.
    if (model.tendon_count > 0) {
        return ModelError.TendonsNotSimulated;
    }
    if (model.dof_count > max_newton_dofs) {
        return ModelError.TooManyDofs;
    }
    if (model.opt.disable_constraints) {
        return;
    }
    if (model.equality_count > 0) {
        return ModelError.ConstraintsNotSimulated;
    }
    const one_world: Counts = countsOf(model, 1);
    if (one_world.constraint_capacity > max_newton_rows) {
        return ModelError.TooManyRows;
    }
}

/// THE JUDGEMENT's WEIGHTS, robot.zig's: the tracker's reward weights, SuperMimic's scales and the termination's
/// limits.
pub const JudgementWeights = robot.JudgementWeights;

/// THE JUDGEMENT's WEIGHTS AS NUMBERS, in the table's order: the tracker's reward weights' fields, then SuperMimic's
/// scales', each in its declared order - the one mapping the image (`writeJudgementWeights`), the host's upload
/// (`Sim.setJudgementWeights`) and the device's read (`loadJudgementWeights`) all follow.
pub fn judgementNumbers(weights: JudgementWeights, out: *[judgement_number_count]f32) void {
    inline for (@typeInfo(robot.RewardWeights).@"struct".field_names, 0..) |field_name, index| {
        out[index] = @field(weights.reward_weights, field_name);
    }
    const scales_at: usize = f32FieldCount(robot.RewardWeights);
    inline for (@typeInfo(robot.SuperMimicScales).@"struct".field_names, 0..) |field_name, index| {
        out[scales_at + index] = @field(weights.scales, field_name);
    }
    const termination_at: usize = scales_at + f32FieldCount(robot.SuperMimicScales);
    const termination_info = @typeInfo(robot.Termination).@"struct";
    comptime var limit: usize = 0;
    inline for (termination_info.field_names, termination_info.field_types) |field_name, field_type| {
        if (field_type == f32) {
            out[termination_at + limit] = @field(weights.termination, field_name);
            limit += 1;
        }
    }
}

/// THE JUDGEMENT's WEIGHTS WRITTEN into a model image: the tracker's reward weights, then SuperMimic's scales, each
/// struct's fields in their declared order - the one mapping `loadJudgementWeights` reads back. `pack` writes the
/// defaults; a tracker writes its task's (`CpuTwin.setJudgementWeights`, the host's `Sim`).
pub fn writeJudgementWeights(
    constants: ModelConstantsLayout,
    model_f: []f32,
    weights: JudgementWeights,
) void {
    var numbers: [judgement_number_count]f32 = undefined;
    judgementNumbers(weights, &numbers);
    for (numbers, 0..) |number, index| {
        model_f[constants.judgement_weights.at(@intCast(index))] = number;
    }
}

/// THE MODEL, PACKED for the GPU into images of its two arenas at `layout`'s places - both images zeroed first, so
/// every padding number is zero and a packed model is the same bytes every time - its topology into `model_u`
/// (`packTopology`) and its constants into `model_f` (`packConstants`). Once per model, on the host.
pub fn pack(
    model: *const robot.Model,
    layout: Layout,
    model_u: []u32,
    model_f: []f32,
) void {
    @memset(model_u, 0);
    @memset(model_f, 0);
    packTopology(model, layout.model_u, model_u);
    packConstants(model, layout, model_u, model_f);
    writeJudgementWeights(layout.model_f, model_f, .{});
    model_f[layout.model_f.character_weight.at(0)] = robot.characterWeight(model);
    model_f[layout.model_f.character_mass.at(0)] = robot.characterMass(model);
}

/// ONE CLIP AS THE DEVICE TAKES IT: `frame_count` frames, each the model's `coordinate_count` coordinates in a row -
/// the pose `robot.applyAction` reads (`clip.pose(frame)[root_len..]`), the caller making the rows from its clip.
pub const ClipPoses = struct {
    poses: []const f32,
    frame_count: u32,
    /// The seconds between two frames: a reset world's velocities are its start frame's difference over it.
    /// Required: a forgotten frame time would give every reset world infinite velocities.
    frame_time: f32,
    /// The clip's curriculum bins and each bin's frames (the fleet's `bins_start` and `binFrames`); 0 and 0 for a run
    /// without a curriculum.
    curriculum_bins: u32 = 0,
    bin_frames: u32 = 0,
    /// The reference's half of the observation at each frame (robot_track's `Fleet.clipReferenceFeatures`):
    /// `localSize` numbers a frame, frame after frame - or none, for a simulator whose worlds are never observed,
    /// which leaves that half zero.
    reference_features: []const f32 = &.{},
    /// The reference's bodies at each frame, for the judgement (robot_track's `Fleet.clipReferenceBodies`):
    /// `robot.reference_body_numbers` numbers a body, every body, frame after frame - given with the features, or
    /// neither.
    reference_bodies: []const f32 = &.{},
};

/// `counts` with the clips' sizes: how many, and their frames together.
pub fn countsWithClips(counts: Counts, clips: []const ClipPoses) Counts {
    var frame_total: u32 = 0;
    var clips_with_features: usize = 0;
    for (clips) |clip| {
        frame_total += clip.frame_count;
        if (clip.reference_features.len > 0) {
            clips_with_features += 1;
        }
    }
    // The reference's tables for every clip or for none: one table each, its rows the clips' frames; a clip observed is
    // a clip judged, so its features and its bodies come together.
    for (clips, 0..) |clip, clip_index| {
        const together: bool = (clip.reference_features.len > 0) == (clip.reference_bodies.len > 0);
        assertf(together, @src(), "countsWithClips: clip {d} has its reference's features or bodies, not both", .{
            clip_index,
        });
    }
    const every_or_none: bool = clips_with_features == 0 or clips_with_features == clips.len;
    assertf(every_or_none, @src(), "countsWithClips: {d} of {d} clips carry reference features", .{
        clips_with_features,
        clips.len,
    });
    var with_clips: Counts = counts;
    with_clips.clip_count = @intCast(clips.len);
    with_clips.clip_frame_total = frame_total;
    var bin_total: u32 = 0;
    for (clips) |clip| {
        bin_total += clip.curriculum_bins;
    }
    with_clips.curriculum_bin_total = bin_total;
    with_clips.reference_feature_frames = if (clips_with_features > 0) frame_total else 0;
    return with_clips;
}

/// THE CLIPS PACKED into the model's images: each clip's first frame among all the clips' frames and its frame count
/// (`model_u`), and every frame's coordinates, frame after frame and clip after clip (`model_f`) - at the places
/// `layout` gives them, its counts holding the clips' (`countsWithClips`). Every clip has a frame at least.
pub fn packClips(
    clips: []const ClipPoses,
    counts: Counts,
    layout: Layout,
    model_u: []u32,
    model_f: []f32,
) void {
    const tables: ModelTablesLayout = layout.model_u;
    const constants: ModelConstantsLayout = layout.model_f;
    const coordinate_count: u32 = counts.coordinate_count;
    var first_frame: u32 = 0;
    var first_bin: u32 = 0;
    for (clips, 0..) |clip, clip_index| {
        assertf(clip.frame_count > 0, @src(), "packClips: clip {d} has no frame", .{clip_index});
        const number_count: u32 = clip.frame_count * coordinate_count;
        assertf(clip.poses.len == number_count, @src(), "packClips: clip {d} holds {d} numbers, its frames {d}", .{
            clip_index,
            clip.poses.len,
            number_count,
        });
        const index: u32 = @intCast(clip_index);
        model_u[tables.clip_first_frame.at(index)] = first_frame;
        model_f[layout.model_f.clip_frame_time.at(index)] = clip.frame_time;
        model_u[tables.clip_first_bin.at(index)] = first_bin;
        model_u[tables.clip_bin_count.at(index)] = clip.curriculum_bins;
        model_u[tables.clip_bin_frames.at(index)] = clip.bin_frames;
        first_bin += clip.curriculum_bins;
        model_u[tables.clip_frame_count.at(index)] = clip.frame_count;
        const first_number: u32 = first_frame * coordinate_count;
        for (clip.poses, 0..) |value, number| {
            model_f[constants.clip_coordinates.at(first_number + @as(u32, @intCast(number)))] = value;
        }
        // The reference's half of the observation, where the caller gave it; otherwise it stays zero.
        const row_size: u32 = @intCast(robot.localSize(counts.body_count));
        const feature_count: u32 = clip.frame_count * row_size;
        const has_features: bool = clip.reference_features.len > 0;
        const features_fit: bool = !has_features or clip.reference_features.len == feature_count;
        assertf(features_fit, @src(), "packClips: clip {d}'s {d} features, its frames {d}", .{
            clip_index,
            clip.reference_features.len,
            feature_count,
        });
        const first_feature: u32 = first_frame * row_size;
        for (clip.reference_features, 0..) |value, number| {
            model_f[constants.clip_reference_features.at(first_feature + @as(u32, @intCast(number)))] = value;
        }
        // The reference's bodies beside them, the judgement's reference.
        const body_numbers: u32 = counts.body_count * @as(u32, @intCast(robot.reference_body_numbers));
        const clip_body_numbers: u32 = clip.frame_count * body_numbers;
        const bodies_fit: bool = clip.reference_bodies.len == 0 or clip.reference_bodies.len == clip_body_numbers;
        assertf(bodies_fit, @src(), "packClips: clip {d}'s {d} reference body numbers, its frames {d}", .{
            clip_index,
            clip.reference_bodies.len,
            clip.frame_count * body_numbers,
        });
        const first_body_number: u32 = first_frame * body_numbers;
        for (clip.reference_bodies, 0..) |value, number| {
            model_f[constants.clip_reference_bodies.at(first_body_number + @as(u32, @intCast(number)))] = value;
        }
        first_frame += clip.frame_count;
    }
}

// ==================================================================================================================
// THE KERNELS
// ==================================================================================================================
//
// A step of the simulator is a sequence of KERNELS. A kernel is a function of one integer, its invocation index, and
// the GPU runs it for every index at once. The host dispatches the kernels one after another, in the order of the
// step program (`robotgpu_host.step_program`), each waiting for the one before: what one kernel writes, the next
// reads.
//
// Every kernel serves many worlds at once. The worlds share the model - the tree, the masses, the joint axes, in
// `model_u` and `model_f` - and each keeps its own state in `world_f` and `world_u`, item `i` of world `w` at
// `offset + w * stride + i` (THE LAYOUT above). A kernel is written for ONE world and one piece of it, and the
// invocation index says which. Three shapes cover every kernel so far:
//
//     per world                 one invocation for each world - a pass whose order matters: a sum taken in the
//                               CPU engine's order, a factorisation, whose every step depends on the one before
//     per world and element     one invocation for each body, geom, site or dof of each world - a pass whose
//                               pieces are independent of one another (`worldElementOf`)
//     per world and branch      one invocation for each path from a tree's root to one of its leaves, in each
//                               world - a pass that flows down the tree, every body after its parent
//
// The physics is MuJoCo's smooth dynamics, stage by stage, in the order of the sections below:
//
//     kinematics                  where every body, joint, geom and site is
//     the centre-of-mass frame    each tree's centre of mass; each body's inertia and each dof's axis about it
//     the mass matrix             M, which relates the joints' accelerations to the forces that cause them
//     the factorisation           M = L^T D L, so that every M x = b is solved cheaply
//     velocities                  every body's velocity, and how fast each dof's axis is being dragged
//     the bias forces             the joint forces that hold the robot's motion against gravity and its own motion
//     the passive forces          the joints' own springs and dampers
//     actuation                   each actuator's force from its control, and the joint forces it adds up to
//     the smooth acceleration     M^-1 applied to the forces: how the robot moves when nothing constrains it
//     the velocity update         the joints' velocities carried over the step, a joint's damping taken implicitly
//     the advance                 the activations, the velocities bounded, the positions carried over the step
//
// EVERY KERNEL HAS A CPU TWIN. Compiled for the CPU, the same function runs in a loop over the invocation indices, on
// the same arenas in memory - the reference the device is compared with. And where the CPU engine (robot.zig) has a
// function for a piece of the physics, the kernel calls that very function, so the twin matches robot.zig to the bit.

const params = g.uniform();

/// WHICH WORLD, AND WHICH OF ITS ELEMENTS, an invocation handles - for a kernel run as one invocation per world and
/// element (a body, a geom, a dof, a branch): the invocations count world 0's elements, then world 1's, and so on.
///
///     invocation    0  1  2 | 3  4  5 | 6  7  8 | 9 ...        three elements a world
///     world         0  0  0 | 1  1  1 | 2  2  2 | 3
///     element       0  1  2 | 0  1  2 | 0  1  2 | 0
///
/// `in_range` is false for an invocation past the last world - a dispatch runs whole workgroups, so the last one can
/// overshoot - and for a model with none of the elements. A struct rather than an optional, so it lowers plainly in a
/// shader.
const WorldElement = struct {
    world: u32,
    element: u32,
    in_range: bool,
};

fn worldElementOf(invocation: u32, elements_per_world: u32) WorldElement {
    if (elements_per_world == 0) {
        const nothing: WorldElement = .{ .world = 0, .element = 0, .in_range = false };
        return nothing;
    }
    const world: u32 = invocation / elements_per_world;
    const element: u32 = invocation % elements_per_world;
    const handled: WorldElement = .{
        .world = world,
        .element = element,
        .in_range = world < params.counts.world_count,
    };
    return handled;
}

// -- THE STEP'S FIRST KERNEL --
//
// Each world has an OVERFLOW WORD, a set of bits in which a kernel records that its world needed more room than an
// array offers - more contacts, say, than the contact arrays hold - and that what did not fit was dropped. The host
// reads the words after a step, so it can report which capacity a model outgrows rather than simulate it wrongly in
// silence. The step begins by clearing them.

// ------------------------------------------------------------------------------------------------------------------
// THE STEP's START: each world's overflow word cleared
// ------------------------------------------------------------------------------------------------------------------

/// CLEAR EVERY WORLD'S OVERFLOW WORD, one invocation per world - the first kernel of every step, so the bits the host
/// reads afterwards are that step's alone, not left over from an earlier one.
pub fn clear_overflow(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const no_capacity_exceeded: u32 = 0;
    params.layout.world_u.overflow.store(world, 0, no_capacity_exceeded);
}

// -- KINEMATICS: WHERE EVERYTHING IS --
//
// Kinematics turns the joint coordinates `joint_positions` into poses. Each body sits on its parent: its pose is its
// parent's, moved by the body's fixed offset from its parent (its rest pose), then by each of its joints in turn - a
// hinge turns about its axis, a slide shifts along it, a ball turns by a quaternion, and a free joint places the body
// outright. So poses are found from the root outward, every body after its parent.
//
// On the GPU that order is kept one BRANCH at a time. A branch is a path from a tree's root to one of its leaves; a
// humanoid has one for each limb and one for the head:
//
//     pelvis -> torso -> head
//     pelvis -> torso -> upper arm -> forearm -> hand           and the same for the other arm
//     pelvis -> thigh -> shin -> foot                           and the same for the other leg
//
// One invocation for each world and branch walks its path from the root down, posing each body after its parent. The
// pelvis lies on every branch, so every invocation poses it - the same arithmetic on the same numbers, giving the same
// bits. That repeats a little work near the root, and in exchange no invocation ever waits for another. Then each
// geom and each site, fixed to its body, is placed by composing its body's pose with its own offset, one invocation
// for each.
//
// Read: joint_positions, and the model's tree, offsets and joint axes. Written: body_positions and body_orientations
// (each body's frame), body_centres_of_mass (its centre of mass), joint_anchors and joint_axes (each joint's anchor and
// axis in the world), geom_positions and geom_orientations, site_positions and site_orientations.

/// Joint `joint`'s rotation box from the table (`rotationBoxNumbers`' layout): its low, its high, its center.
fn loadBallBox(boxes: ModelTable(.model_f, .joint_box_numbers), joint: u32) robot.RotationBox {
    const at: u32 = 12 * joint;
    const low: Vec = vec(boxes.load(at), boxes.load(at + 1), boxes.load(at + 2));
    const high: Vec = vec(boxes.load(at + 4), boxes.load(at + 5), boxes.load(at + 6));
    const center: robot.Quat = .{ boxes.load(at + 8), boxes.load(at + 9), boxes.load(at + 10), boxes.load(at + 11) };
    return .{ .center = center, .low = low, .high = high };
}

/// JOINT `joint`'s TYPE - the only way to it: its packed word loaded from `joint_type` and decoded here by the enum's
/// own conversion, so a joint's index can never be decoded as if it were its word, and the numbering lives once, in
/// `robot.JointType` (backed by u32, MuJoCo's order - pinned at compile time above).
fn typeOfJoint(joint: u32) robot.JointType {
    return @fromBackingInt(params.layout.model_u.joint_type.load(joint));
}

/// GEOM `geom`'s TYPE - the only way to it, its packed word loaded from `geom_type` and decoded here, as
/// `typeOfJoint` does for a joint.
fn typeOfGeom(geom: u32) GeomType {
    return @fromBackingInt(@intCast(params.layout.model_u.geom_type.load(geom)));
}

/// A world's joint's coordinates (`robot.JointCoordinates`) from `array` - `joint_positions`, or the servo's targets,
/// laid out alike: as many as the joint's type has, from its first, each type's loads written out.
fn loadJointCoordinates(
    array: WorldArray(.world_f, .coordinates),
    world: u32,
    joint_type: robot.JointType,
    first: u32,
) robot.JointCoordinates {
    return switch (joint_type) {
        .slide, .hinge => .ofSingle(array.load(world, first)),
        .ball => .ofBall(array.loadQuaternion(world, first)),
        .free => .ofFree(array.loadVector3(world, first), array.loadQuaternion(world, first + 3)),
    };
}

/// `coordinates` stored into a world's joint's place in `array` - `joint_positions`, or the servo's targets: as many as
/// the joint's type has, from its first.
fn storeJointCoordinates(
    array: WorldArray(.world_f, .coordinates),
    world: u32,
    joint_type: robot.JointType,
    first: u32,
    coordinates: robot.JointCoordinates,
) void {
    var offset: u32 = 0;
    while (offset < joint_type.posCount()) : (offset += 1) {
        array.store(world, first + offset, coordinates.numbers[offset]);
    }
}

/// A joint's coordinates in row `row` of the clips' frames - every clip's frames in one run, a row each
/// (`clip_coordinates`): as many as the joint's type has, from its first.
fn loadClipCoordinates(
    row: u32,
    joint_type: robot.JointType,
    first: u32,
) robot.JointCoordinates {
    const constants: ModelConstantsLayout = params.layout.model_f;
    const joint_start: u32 = row * params.counts.coordinate_count + first;
    var coordinates: robot.JointCoordinates = .{};
    var offset: u32 = 0;
    while (offset < joint_type.posCount()) : (offset += 1) {
        coordinates.numbers[offset] = constants.clip_coordinates.load(joint_start + offset);
    }
    return coordinates;
}

/// ONE BODY'S POSE in world `world`, as robot.zig's `kinematics` computes it - the same functions on the same values in
/// the same order, so the twin matches robot.zig to the bit. A FREE body's pose is its seven coordinates
/// (`freeJointPose`). Any other body starts at its rest pose relative to its parent, and each of its joints moves it
/// in turn (`moveByJoint`), recording the joint's anchor and axis in the world. Then the orientation is normalised and
/// the centre of mass placed:
///
///     free body       pose = (its position coordinates, its quaternion)
///     jointed body    pose = parent pose . rest pose;   then each joint:  pose = moveByJoint(pose, joint)
///     both            body_orientations[body]     = normalise(pose.rot)
///                     body_positions[body]        = pose.pos
///                     body_centres_of_mass[body]  = pose.pos
///                                     + rotate(body_orientations[body], body_centre_of_mass_offset[body])
///
/// A body whose parent is the world composes with the identity directly - the very values robot.zig reads for body 0 -
/// so no branch reads the world body's pose while another writes it.
fn poseBody(world: u32, body: u32) void {
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const parent: u32 = tables.body_parent.load(body);
    const first_joint: u32 = tables.body_first_joint.load(body);
    const joint_count: u32 = tables.body_joint_count.load(body);
    const is_free_body: bool = joint_count == 1 and typeOfJoint(first_joint) == .free;
    var body_pose: robot.Pose = undefined;
    if (is_free_body) {
        const first_coordinate: u32 = tables.joint_first_coordinate.load(first_joint);
        // A free joint's seven coordinates: its position, then its quaternion.
        const position: Vec = state.joint_positions.loadVector3(world, first_coordinate);
        const orientation: robot.Quat = state.joint_positions.loadQuaternion(world, first_coordinate + 3);
        body_pose = robot.freeJointPose(position, orientation);
        state.joint_anchors.storeVec(world, first_joint, body_pose.pos);
        state.joint_axes.storeVec(world, first_joint, constants.joint_local_axis.loadVec(first_joint));
    } else {
        const world_pose: robot.Pose = .{ .pos = zm.vec_zero, .rot = zm.quat_identity };
        const parent_pose: robot.Pose = if (parent == 0) world_pose else .{
            .pos = state.body_positions.loadVec(world, parent),
            .rot = state.body_orientations.loadVec(world, parent),
        };
        const rest_offset: robot.Pose = .{
            .pos = constants.body_rest_position.loadVec(body),
            .rot = constants.body_rest_rotation.loadVec(body),
        };
        var pose: robot.Pose = parent_pose.compose(rest_offset);
        var joint: u32 = first_joint;
        while (joint < first_joint + joint_count) : (joint += 1) {
            const first_coordinate: u32 = tables.joint_first_coordinate.load(joint);
            const joint_type: robot.JointType = typeOfJoint(joint);
            // As many coordinates as the joint has - never reading past them.
            const coordinates: robot.JointCoordinates =
                loadJointCoordinates(state.joint_positions, world, joint_type, first_coordinate);
            const local_axis: Vec = constants.joint_local_axis.loadVec(joint);
            const local_anchor: Vec = constants.joint_local_anchor.loadVec(joint);
            const rest_coordinate: f32 = constants.reference_joint_positions.load(first_coordinate);
            const motion: robot.JointMotion =
                robot.moveByJoint(pose, joint_type, local_axis, local_anchor, coordinates, rest_coordinate);
            pose = motion.pose;
            state.joint_anchors.storeVec(world, joint, motion.anchor);
            state.joint_axes.storeVec(world, joint, motion.axis);
        }
        body_pose = pose;
    }
    const orientation: Vec = robot.normalizeQuat(body_pose.rot);
    state.body_orientations.storeVec(world, body, orientation);
    state.body_positions.storeVec(world, body, body_pose.pos);
    const centre_of_mass: Vec = body_pose.pos + rotate(orientation, constants.body_centre_of_mass_offset.loadVec(body));
    state.body_centres_of_mass.storeVec(world, body, centre_of_mass);
}

// ------------------------------------------------------------------------------------------------------------------
// KINEMATICS: every body posed down its branch, then every geom and site placed on its body
// ------------------------------------------------------------------------------------------------------------------

/// KINEMATICS: every body's pose in the world, one invocation per world and BRANCH of the tree - MuJoCo Warp's
/// `_kinematics_branch`. An invocation walks its branch from the root down to its leaf, so every body is posed after
/// its parent (`poseBody`); a body on several branches - the pelvis, on both legs - is posed by each, to the same bits.
/// Each world's first branch also writes the world body's pose, the identity, for the stages that read it.
pub fn kinematics_branch(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.branch_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const branch: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    if (branch == 0) {
        state.body_positions.storeVec(world, 0, zm.vec_zero);
        state.body_orientations.storeVec(world, 0, zm.quat_identity);
        state.body_centres_of_mass.storeVec(world, 0, zm.vec_zero);
    }
    const first_entry: u32 = tables.body_branch_start.load(branch);
    const end_entry: u32 = tables.body_branch_start.load(branch + 1);
    var entry: u32 = first_entry;
    while (entry < end_entry) : (entry += 1) {
        const body: u32 = tables.body_branches.load(entry);
        poseBody(world, body);
    }
}

/// GEOM POSES: each geom's pose in the world, one invocation per world and geom - its body's pose, which kinematics
/// has just found, composed with the geom's own offset from its body (`Pose.compose`, as robot.zig places a geom).
pub fn geom_poses(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.geom_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const geom: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const body: u32 = tables.geom_body.load(geom);
    const body_position: Vec = state.body_positions.loadVec(world, body);
    const body_orientation: Vec = state.body_orientations.loadVec(world, body);
    const body_pose: robot.Pose = .{ .pos = body_position, .rot = body_orientation };
    const offset_from_body: robot.Pose = .{
        .pos = constants.geom_local_position.loadVec(geom),
        .rot = constants.geom_local_rotation.loadVec(geom),
    };
    const placed: robot.Pose = body_pose.compose(offset_from_body);
    state.geom_positions.storeVec(world, geom, placed.pos);
    state.geom_orientations.storeVec(world, geom, placed.rot);
}

/// SITE POSES: each site's pose in the world, one invocation per world and site - its body's pose composed with the
/// site's own offset, as robot.zig's `kinematics` places its sites.
pub fn site_poses(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.site_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const site: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const body: u32 = tables.site_body.load(site);
    const body_position: Vec = state.body_positions.loadVec(world, body);
    const body_orientation: Vec = state.body_orientations.loadVec(world, body);
    const body_pose: robot.Pose = .{ .pos = body_position, .rot = body_orientation };
    const offset_from_body: robot.Pose = .{
        .pos = constants.site_local_position.loadVec(site),
        .rot = constants.site_local_rotation.loadVec(site),
    };
    const placed: robot.Pose = body_pose.compose(offset_from_body);
    state.site_positions.storeVec(world, site, placed.pos);
    state.site_orientations.storeVec(world, site, placed.rot);
}

// -- THE CENTRE-OF-MASS FRAME --
//
// The dynamics works with SPATIAL vectors: a velocity is an angular and a linear part together, a force a torque and
// a force together. A spatial vector is expressed about a point, and the choice matters for precision. MuJoCo - and
// robot.zig after it - expresses everything about each tree's centre of mass. The numbers then stay small and evenly
// balanced wherever the robot is; about the world's origin, the linear parts would grow with the robot's distance
// from it, and take precision from everything computed with them. Three quantities are built in this frame:
//
//     subtree_centres_of_mass    each body's subtree's centre of mass; the root's is the frame's origin
//     body_inertias         each body's inertia, turned into the world's axes and moved to the frame's origin
//     dof_axes           each dof's motion axis: how the body would move for a unit rate of that dof alone
//
// The centre of mass is a sum over each subtree, gathered from the leaves inward in robot.zig's order, one invocation
// for each world; the inertias and the axes are independent of one another, one invocation for each body and for each
// dof.

// ------------------------------------------------------------------------------------------------------------------
// THE CENTRE-OF-MASS FRAME: each tree's centre of mass, each body's inertia and each dof's axis in it, the
// composite inertias
// ------------------------------------------------------------------------------------------------------------------

/// EACH SUBTREE'S CENTRE OF MASS, one invocation per world, in robot.zig's own order (its `comPos`): every body's mass
/// times its centre, each body's sum added into its parent's, last body first, then each sum divided by its subtree's
/// mass. MuJoCo Warp sums each subtree over its depth-first range instead - the same total in another association, so
/// different last bits; this order keeps the twin equal to robot.zig to the bit, and a tree of a few dozen bodies is
/// little work for one invocation.
///
///     own:      S[b] = mass[b] * body_centres_of_mass[b]
///     gather:   for b from the last body down to 1:   S[parent[b]] += S[b]
///     divide:   subtree_centres_of_mass[b] = S[b] / subtree_mass[b]
///               (body_centres_of_mass[b] for a massless subtree)
pub fn subtree_centres_of_mass(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const body_count: u32 = params.counts.body_count;
    var body: u32 = 0;
    while (body < body_count) : (body += 1) {
        const centre_of_mass: Vec = state.body_centres_of_mass.loadVec(world, body);
        const weighted_centre: Vec = centre_of_mass * splat(constants.body_mass.load(body));
        state.subtree_centres_of_mass.storeVec(world, body, weighted_centre);
    }
    var reverse_body: u32 = body_count;
    while (reverse_body > 1) {
        reverse_body -= 1;
        const parent: u32 = tables.body_parent.load(reverse_body);
        const parent_sum: Vec = state.subtree_centres_of_mass.loadVec(world, parent);
        const child_sum: Vec = state.subtree_centres_of_mass.loadVec(world, reverse_body);
        const gathered: Vec = parent_sum + child_sum;
        state.subtree_centres_of_mass.storeVec(world, parent, gathered);
    }
    body = 0;
    while (body < body_count) : (body += 1) {
        const subtree_mass: f32 = constants.body_subtree_mass.load(body);
        const centre: Vec = if (subtree_mass > robot.min_mass)
            state.subtree_centres_of_mass.loadVec(world, body) / splat(subtree_mass)
        else
            state.body_centres_of_mass.loadVec(world, body);
        state.subtree_centres_of_mass.storeVec(world, body, centre);
    }
}

/// EACH BODY'S INERTIA IN ITS TREE'S CENTRE-OF-MASS FRAME (`body_inertias`), one invocation per world and body:
/// robot.zig's spatial inertia turned by the body's orientation, then moved from the body's centre to the frame's
/// origin - the centre of mass of the body's whole tree, which makes the composite inertias of the next stage plain
/// sums.
pub fn body_inertias(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.body_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const body: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    if (body == 0) {
        state.body_inertias.storeInertia(world, 0, robot.Inertia.zero);
        return;
    }
    const frame_origin: Vec = state.subtree_centres_of_mass.loadVec(world, tables.body_root.load(body));
    const body_centre: Vec = state.body_centres_of_mass.loadVec(world, body);
    const inertia: robot.Inertia = constants.body_local_inertia.loadInertia(body)
        .rotated(state.body_orientations.loadVec(world, body))
        .translate(body_centre - frame_origin);
    state.body_inertias.storeInertia(world, body, inertia);
}

/// EACH DOF'S MOTION AXIS IN THE CENTRE-OF-MASS FRAME (`dof_axes`), one invocation per world and dof: robot.zig's
/// `dofMotionAxis` for the dof's joint and its index within that joint, the frame's origin taken from the joint's
/// anchor.
pub fn dof_axes(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const joint: u32 = tables.dof_joint.load(dof);
    const body: u32 = tables.joint_body.load(joint);
    const frame_origin: Vec = state.subtree_centres_of_mass.loadVec(world, tables.body_root.load(body));
    const offset: Vec = frame_origin - state.joint_anchors.loadVec(world, joint);
    const index_in_joint: u32 = dof - tables.joint_first_dof.load(joint);
    const joint_type: robot.JointType = typeOfJoint(joint);
    const joint_axis: Vec = state.joint_axes.loadVec(world, joint);
    const body_rotation: Vec = state.body_orientations.loadVec(world, body);
    const motion: robot.Motion = robot.dofMotionAxis(joint_type, index_in_joint, joint_axis, body_rotation, offset);
    state.dof_axes.storeMotion(world, dof, motion);
}

// -- THE MASS MATRIX --
//
// The mass matrix M relates the joints' accelerations to the forces that cause them, `M joint_accelerations = forces`:
// entry M[i][j] is the force dof i must exert when dof j alone accelerates at a unit rate. It is symmetric, and for a
// tree it is sparse - two dofs interact only when one lies on the other's path to the root, so a dof in the left leg
// feels nothing of the right leg's.
//
// The composite rigid body algorithm builds it in two passes. First each body's COMPOSITE inertia, the inertia of its
// whole subtree moving as one rigid body: a sum from the leaves inward, one invocation for each world. Then the
// entries. Dof i accelerating at a unit rate carries its whole subtree with it, which takes the force "composite
// inertia times axis" (`robot.dofUnitForce`); that force, measured along an ancestor j's axis, is M[i][j]
// (`robot.forceAlongDof`). One invocation for each world and dof fills one row:
//
//     row i stores only i's chain:    [ M[i][root] ... M[i][parent of i] | M[i][i] ]        the diagonal last
//
// Read: body_inertias, dof_axes, and the model's armature. Written: composite_inertias (each body's composite inertia),
// mass_matrix (the rows).

/// EACH BODY'S COMPOSITE INERTIA (`composite_inertias`), one invocation per world, in robot.zig's own order (its
/// `crb`): every body's inertia in the frame, each added into its parent's, last body first - so a body's composite
/// inertia is the inertia of its whole subtree, moving as one rigid body. The world body takes none: a tree's root is
/// not attached to it rigidly. In the frame of the tree's centre of mass, these sums are plain additions
/// (`Inertia.add`).
pub fn composite_inertias(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const body_count: u32 = params.counts.body_count;
    var body: u32 = 0;
    while (body < body_count) : (body += 1) {
        state.composite_inertias.storeInertia(world, body, state.body_inertias.loadInertia(world, body));
    }
    var reverse_body: u32 = body_count;
    while (reverse_body > 1) {
        reverse_body -= 1;
        const parent: u32 = tables.body_parent.load(reverse_body);
        if (parent != 0) {
            const parent_composite: robot.Inertia = state.composite_inertias.loadInertia(world, parent);
            const child_composite: robot.Inertia = state.composite_inertias.loadInertia(world, reverse_body);
            const gathered: robot.Inertia = parent_composite.add(child_composite);
            state.composite_inertias.storeInertia(world, parent, gathered);
        }
    }
}

// ------------------------------------------------------------------------------------------------------------------
// THE MASS MATRIX: its rows from the composite inertias, then each world's factorisation
// ------------------------------------------------------------------------------------------------------------------

/// ONE ROW OF THE MASS MATRIX, one invocation per world and dof, as robot.zig's `crb` fills it. Dof i's unit
/// acceleration demands a force of its body's composite inertia (`dofUnitForce`); the entry M[i][j], for each dof j on
/// i's chain of ancestors, is that force along j's axis (`forceAlongDof`). The row is stored sparse - only the chain's
/// entries, the root's first and the diagonal last - and the dof's armature, the rotor inertia a gearbox adds, joins
/// the diagonal:
///
///     slots of row i      [ root's dof ... parent's dof | i ]     walked from i up `dof_parent`, filled from the end
///     diagonal            M[i][i] += armature[i]
pub fn mass_matrix_rows(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const row_start: u32 = tables.mass_row_start.load(dof);
    const row_entries: u32 = tables.mass_row_entry_count.load(dof);
    const body: u32 = tables.dof_body.load(dof);
    const composite: robot.Inertia = state.composite_inertias.loadInertia(world, body);
    const unit_force: robot.Force = robot.dofUnitForce(composite, state.dof_axes.loadMotion(world, dof));
    var slot: u32 = row_entries;
    var ancestor_dof: u32 = dof;
    while (ancestor_dof != robot.no_dof) : (ancestor_dof = tables.dof_parent.load(ancestor_dof)) {
        slot -= 1;
        const entry: f32 = robot.forceAlongDof(state.dof_axes.loadMotion(world, ancestor_dof), unit_force);
        state.mass_matrix.store(world, row_start + slot, entry);
    }
    const diagonal_slot: u32 = row_start + row_entries - 1;
    const diagonal: f32 = state.mass_matrix.load(world, diagonal_slot) + constants.dof_armature.load(dof);
    state.mass_matrix.store(world, diagonal_slot, diagonal);
}

// -- THE FACTORISATION --
//
// A step needs `M^-1 f`, the accelerations a set of forces causes, and so will anything that asks how the robot
// responds to a force. M is never inverted. It is factored once per step, `M = L^T D L` - L lower triangular with
// ones on its diagonal, D diagonal - after which every `M^-1 f` is two triangular sweeps and a division (the smooth
// acceleration, below).
//
// For a tree the factor needs no entries beyond M's own: eliminating a dof updates only its ancestors' rows, whose
// chains are prefixes of its own (`robot.factorLdlInPlace` explains why). So L lives in exactly M's storage,
// `mass_factor`, with the inverse of D in `mass_factor_inverse_diagonal`. Each elimination depends on the ones before
// it, so one invocation factors a whole world, running robot.zig's own function over that world's arrays.
//
// Read: mass_matrix. Written: mass_factor, mass_factor_inverse_diagonal.

/// ONE WORLD'S MASS MATRIX as robot.zig's factorisation and solve read it (`robot.factorLdlInPlace`,
/// `robot.solveLdl`): the model's sparsity from `model_u`, and three per-world arrays named at compile time - the
/// factor (`factor_array`) and its inverse pivots (`inverse_diagonal_array`), both in `world_f`, and the vector solved
/// in place (`solution_array`, in the arena `solution_arena`) - so each use names what it factors and what it solves
/// into (`SmoothAccelerationSolve`, `VelocityChangeSolve`, `ConstraintRowSolve`). Global memory - the first form; a
/// storage in workgroup memory would replace it, the arithmetic untouched, should a profile ask.
fn WorldMassMatrix(
    comptime factor_array: [:0]const u8,
    comptime inverse_diagonal_array: [:0]const u8,
    comptime solution_arena: Arena,
    comptime solution_array: [:0]const u8,
) type {
    return struct {
        const Storage = @This();
        /// The layout of the solution's arena: `WorldStateLayout` for `world_f`, `ConstraintRowsLayout` for `efc_f`.
        const SolutionLayout: type = @FieldType(Layout, @tagName(solution_arena));

        world: u32,
        /// The item of the solution's dof 0 in the world's block of `solution_array`: 0 for an array with one number
        /// per dof, `row x dof_count` for one row of a row-major [row][dof] array (`constraint_row_dofs`).
        solution_first: u32 = 0,

        pub fn rowStart(storage: Storage, dof: u32) u32 {
            _ = storage;
            return params.layout.model_u.mass_row_start.load(dof);
        }
        pub fn rowEntries(storage: Storage, dof: u32) u32 {
            _ = storage;
            return params.layout.model_u.mass_row_entry_count.load(dof);
        }
        pub fn column(storage: Storage, entry: u32) u32 {
            _ = storage;
            return params.layout.model_u.mass_entry_column.load(entry);
        }
        pub fn factor(storage: Storage, entry: u32) f32 {
            return @field(params.layout.world_f, factor_array).load(storage.world, entry);
        }
        pub fn setFactor(storage: Storage, entry: u32, value: f32) void {
            @field(params.layout.world_f, factor_array).store(storage.world, entry, value);
        }
        pub fn inversePivot(storage: Storage, dof: u32) f32 {
            return @field(params.layout.world_f, inverse_diagonal_array).load(storage.world, dof);
        }
        pub fn setInversePivot(storage: Storage, dof: u32, value: f32) void {
            @field(params.layout.world_f, inverse_diagonal_array).store(storage.world, dof, value);
        }
        pub fn solution(storage: Storage, dof: u32) f32 {
            const item: u32 = storage.solution_first + dof;
            const solution_layout: SolutionLayout = @field(params.layout, @tagName(solution_arena));
            return @field(solution_layout, solution_array).load(storage.world, item);
        }
        pub fn setSolution(storage: Storage, dof: u32, value: f32) void {
            const item: u32 = storage.solution_first + dof;
            const solution_layout: SolutionLayout = @field(params.layout, @tagName(solution_arena));
            @field(solution_layout, solution_array).store(storage.world, item, value);
        }
    };
}

/// A world's mass matrix solving into its smooth acceleration (`solve_smooth_acceleration`).
const SmoothAccelerationSolve = WorldMassMatrix(
    "mass_factor",
    "mass_factor_inverse_diagonal",
    .world_f,
    "smooth_joint_accelerations",
);

/// A world's DAMPED matrix, factored apart from M's, solving into its velocity changes (`damped_velocity_changes`).
const VelocityChangeSolve = WorldMassMatrix(
    "damped_mass_factor",
    "damped_mass_factor_inverse_diagonal",
    .world_f,
    "velocity_changes",
);

/// A world's mass matrix solving into one constraint row's M^-1 J^T (`project_constraints`): the row's vector is its
/// run of `constraint_inverse_inertia_jacobian`, so the storage's `solution_first` is `row x dof_count`.
const ConstraintRowSolve = WorldMassMatrix(
    "mass_factor",
    "mass_factor_inverse_diagonal",
    .efc_f,
    "constraint_inverse_inertia_jacobian",
);

/// ONE WORLD'S MASS-MATRIX PRODUCT as robot.zig computes it (`robot.multiplyByMassMatrix`): the sparsity from
/// `model_u`, the stored entries of the world's `mass_matrix`, the acceleration multiplied (`joint_accelerations`) and
/// the product built in the world's `velocity_changes`.
const WorldMassProduct = struct {
    world: u32,

    pub fn rowStart(storage: WorldMassProduct, dof: u32) u32 {
        _ = storage;
        return params.layout.model_u.mass_row_start.load(dof);
    }
    pub fn rowEntries(storage: WorldMassProduct, dof: u32) u32 {
        _ = storage;
        return params.layout.model_u.mass_row_entry_count.load(dof);
    }
    pub fn column(storage: WorldMassProduct, entry: u32) u32 {
        _ = storage;
        return params.layout.model_u.mass_entry_column.load(entry);
    }
    pub fn massEntry(storage: WorldMassProduct, entry: u32) f32 {
        return params.layout.world_f.mass_matrix.load(storage.world, entry);
    }
    pub fn input(storage: WorldMassProduct, dof: u32) f32 {
        return params.layout.world_f.joint_accelerations.load(storage.world, dof);
    }
    pub fn output(storage: WorldMassProduct, dof: u32) f32 {
        return params.layout.world_f.velocity_changes.load(storage.world, dof);
    }
    pub fn setOutput(storage: WorldMassProduct, dof: u32, value: f32) void {
        params.layout.world_f.velocity_changes.store(storage.world, dof, value);
    }
};

/// The mass matrix's stored entry for dofs (`higher`, `lower`), `lower` an ancestor-or-self of `higher` - or zero where
/// the two dofs share no chain.
inline fn massMatrixEntry(world: u32, higher: u32, lower: u32) f32 {
    const tables: ModelTablesLayout = params.layout.model_u;
    const row_start: u32 = tables.mass_row_start.load(higher);
    const row_entries: u32 = tables.mass_row_entry_count.load(higher);
    var entry: u32 = 0;
    while (entry < row_entries) : (entry += 1) {
        if (tables.mass_entry_column.load(row_start + entry) == lower) {
            return params.layout.world_f.mass_matrix.load(world, row_start + entry);
        }
    }
    return 0.0;
}

/// THE MASS MATRIX FACTORED, one invocation per world: the world's M copied into its factor, then factored in place by
/// robot.zig's own `factorLdlInPlace` - the CPU engine's arithmetic in its order, so the twin matches it to the bit.
/// One invocation per world is the first form, the exact one; the storage decides where the factor lives.
pub fn factor_mass_matrix(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const state: WorldStateLayout = params.layout.world_f;
    var entry: u32 = 0;
    while (entry < params.counts.mass_entry_count) : (entry += 1) {
        state.mass_factor.store(world, entry, state.mass_matrix.load(world, entry));
    }
    const storage: SmoothAccelerationSolve = .{ .world = world };
    robot.factorLdlInPlace(storage, params.counts.dof_count);
}

// -- VELOCITIES --
//
// With every dof's axis known, velocities follow from the joint rates `joint_velocities`: a body moves as its parent
// does, plus whatever its own joints add - each dof's axis times its rate. Velocities flow down the tree exactly as
// poses do, so they are found branch by branch, as kinematics finds poses.
//
// The same pass measures how fast each dof's axis is itself moving. An axis is carried along by everything above it:
// a hinge on a spinning body turns with the body, and an axis that turns accelerates whatever it drives even at a
// constant joint rate. That drag of the axes is where the centrifugal and Coriolis forces of a moving robot come from.
//
// Read: dof_axes, joint_velocities. Written: body_velocities (each body's spatial velocity), dof_axis_rates (each dof's
// axis rate).

/// ONE WORLD'S VELOCITY ARRAYS as robot.zig's velocity pass reads them (`robot.velocityThroughJoint`): each dof's
/// motion axis from the world's `dof_axes`, its rate from `joint_velocities`, and the rate of change of its axis into
/// `dof_axis_rates`.
const WorldVelocities = struct {
    world: u32,

    pub fn dofAxis(storage: WorldVelocities, dof: u32) robot.Motion {
        return params.layout.world_f.dof_axes.loadMotion(storage.world, dof);
    }
    pub fn dofRate(storage: WorldVelocities, dof: u32) f32 {
        return params.layout.world_f.joint_velocities.load(storage.world, dof);
    }
    pub fn setDofAxisRate(
        storage: WorldVelocities,
        dof: u32,
        axis_rate: robot.Motion,
    ) void {
        params.layout.world_f.dof_axis_rates.storeMotion(storage.world, dof, axis_rate);
    }
};

// ------------------------------------------------------------------------------------------------------------------
// VELOCITIES AND BIAS FORCES: the bodies' spatial velocities, the bias accelerations, the bias forces gathered
// up the tree into joint forces
// ------------------------------------------------------------------------------------------------------------------

/// EVERY BODY'S VELOCITY, and the rate each dof's motion axis is dragged at, one invocation per world and branch -
/// MuJoCo Warp's `_comvel_branch`, in robot.zig's arithmetic (`comVel`). Velocities accumulate down the tree as poses
/// do, so an invocation walks its branch from the root down to its leaf: a body's velocity is its parent's, carried
/// through each of its joints in turn (`robot.velocityThroughJoint`), and a body on several branches gets the same bits
/// from each. A body whose parent is the world starts from rest directly - the very value robot.zig reads for body 0 -
/// so no branch reads the world body's velocity while another writes it; each world's first branch writes it, zero.
pub fn body_velocities_branch(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.branch_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const branch: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const at_rest: robot.Motion = .zero;
    if (branch == 0) {
        state.body_velocities.storeMotion(world, 0, at_rest);
    }
    const storage: WorldVelocities = .{ .world = world };
    const first_entry: u32 = tables.body_branch_start.load(branch);
    const end_entry: u32 = tables.body_branch_start.load(branch + 1);
    var entry: u32 = first_entry;
    while (entry < end_entry) : (entry += 1) {
        const body: u32 = tables.body_branches.load(entry);
        const parent: u32 = tables.body_parent.load(body);
        var velocity: robot.Motion = if (parent == 0) at_rest else state.body_velocities.loadMotion(world, parent);
        const first_joint: u32 = tables.body_first_joint.load(body);
        const end_joint: u32 = first_joint + tables.body_joint_count.load(body);
        var joint: u32 = first_joint;
        while (joint < end_joint) : (joint += 1) {
            const joint_type: robot.JointType = typeOfJoint(joint);
            const first_dof: u32 = tables.joint_first_dof.load(joint);
            velocity = robot.velocityThroughJoint(storage, joint_type, first_dof, velocity);
        }
        state.body_velocities.storeMotion(world, body, velocity);
    }
}

// -- THE BIAS FORCES --
//
// The bias forces `c(q, v)` are the joint forces a robot needs just to keep its current motion against gravity and
// against that motion itself: weight, and the centrifugal and Coriolis forces of moving bodies. They are found with
// the recursive Newton-Euler algorithm, run with every joint's acceleration set to zero, in four passes:
//
//     forward     each body's acceleration: its parent's, plus each of its dofs' axis rate times the dof's rate - the
//                 drag of the moving axes. Gravity enters here, as an UPWARD acceleration g of the world rather than a
//                 weight on every body: in a frame accelerating upward at g, weight appears by itself, with no body
//                 treated specially.
//     per body    the force the body needs to move so: f = I a + v x* (I v) - its inertia times its acceleration,
//                 plus the gyroscopic force of its own spin.
//     backward    each body's force added into its parent's, from the leaves inward: a joint carries everything below
//                 it.
//     per dof     the force of the dof's subtree, along the dof's axis: the joint force the dof must supply.
//
// The forward pass flows down the tree, branch by branch, as velocities do; each body's force is independent of the
// others'; the backward sum is taken in robot.zig's order, one invocation per world; the projection is one invocation
// per dof.
//
// Read: body_velocities, dof_axis_rates, body_inertias, dof_axes, joint_velocities, and gravity. Written:
// body_bias_accelerations (each body's acceleration), subtree_bias_forces (each body's force, then each subtree's),
// bias_joint_forces.

/// EVERY BODY'S ACCELERATION WITH NO JOINT ACCELERATING, one invocation per world and branch - MuJoCo Warp's
/// `_cacc_branch`, in robot.zig's arithmetic (`rne`). An invocation walks its branch from the root down: a body's
/// acceleration is its parent's, plus each of its dofs' axis rate times the dof's rate, in dof order - even at a
/// constant joint rate, an axis that turns accelerates whatever it drives. A body whose parent is the world starts
/// from the world's acceleration, upward at g, directly - the value robot.zig reads for body 0 - so no branch reads
/// the world body's acceleration while another writes it; each world's first branch writes it.
pub fn bias_accelerations_branch(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.branch_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const branch: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const gravity: Vec = params.options.gravityVector();
    const world_acceleration: robot.Motion = .{ .ang = zm.vec_zero, .lin = -gravity };
    if (branch == 0) {
        state.body_bias_accelerations.storeMotion(world, 0, world_acceleration);
    }
    const first_entry: u32 = tables.body_branch_start.load(branch);
    const end_entry: u32 = tables.body_branch_start.load(branch + 1);
    var entry: u32 = first_entry;
    while (entry < end_entry) : (entry += 1) {
        const body: u32 = tables.body_branches.load(entry);
        const parent: u32 = tables.body_parent.load(body);
        var acceleration: robot.Motion = if (parent == 0)
            world_acceleration
        else
            state.body_bias_accelerations.loadMotion(world, parent);
        const first_dof: u32 = tables.body_first_dof.load(body);
        const end_dof: u32 = first_dof + tables.body_dof_count.load(body);
        var dof: u32 = first_dof;
        while (dof < end_dof) : (dof += 1) {
            const axis_rate: robot.Motion = state.dof_axis_rates.loadMotion(world, dof);
            const joint_rate: f32 = state.joint_velocities.load(world, dof);
            acceleration = acceleration.add(axis_rate.scale(joint_rate));
        }
        state.body_bias_accelerations.storeMotion(world, body, acceleration);
    }
}

/// EACH BODY'S OWN FORCE, one invocation per world and body: Newton-Euler for a rigid body in spatial form,
/// `f = I a + v x* (I v)` (`robot.bodyNewtonEulerForce`) - the force that gives the body its acceleration, plus the
/// gyroscopic and centrifugal force its own motion carries. The world body needs none; its force is zero.
pub fn body_bias_forces(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.body_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const body: u32 = handled.element;
    const state: WorldStateLayout = params.layout.world_f;
    if (body == 0) {
        state.subtree_bias_forces.storeForce(world, 0, .zero);
        return;
    }
    const inertia: robot.Inertia = state.body_inertias.loadInertia(world, body);
    const acceleration: robot.Motion = state.body_bias_accelerations.loadMotion(world, body);
    const velocity: robot.Motion = state.body_velocities.loadMotion(world, body);
    const force: robot.Force = robot.bodyNewtonEulerForce(inertia, acceleration, velocity);
    state.subtree_bias_forces.storeForce(world, body, force);
}

/// EACH SUBTREE'S FORCE, one invocation per world, in robot.zig's order (its `rne`): each body's force added into its
/// parent's, last body first, so a body's force becomes the force its whole subtree needs - the force its joint must
/// transmit. A tree's root adds nothing into the world body, which holds it by no joint.
pub fn subtree_bias_forces(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    var reverse_body: u32 = params.counts.body_count;
    while (reverse_body > 1) {
        reverse_body -= 1;
        const parent: u32 = tables.body_parent.load(reverse_body);
        if (parent != 0) {
            const parent_force: robot.Force = state.subtree_bias_forces.loadForce(world, parent);
            const child_force: robot.Force = state.subtree_bias_forces.loadForce(world, reverse_body);
            state.subtree_bias_forces.storeForce(world, parent, parent_force.add(child_force));
        }
    }
}

/// EACH DOF'S BIAS FORCE, one invocation per world and dof: the force of the subtree the dof carries, measured along
/// the dof's axis (`robot.forceAlongDof`) - the joint force the dof must supply to keep the motion as it is.
pub fn bias_joint_forces(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const body: u32 = tables.dof_body.load(dof);
    const axis: robot.Motion = state.dof_axes.loadMotion(world, dof);
    const subtree_force: robot.Force = state.subtree_bias_forces.loadForce(world, body);
    state.bias_joint_forces.store(world, dof, robot.forceAlongDof(axis, subtree_force));
}

// -- THE PASSIVE FORCES --
//
// A joint can carry its own spring and damper, forces that come from the mechanism rather than from any motor. A
// damper opposes motion: on each of a joint's dofs it pushes back with `damping * rate`. A spring pulls a hinge or a
// slide back toward its reference position, `stiffness * (position - reference)` (the reference pose's value, from the
// model). A ball or a free joint carries no spring in robot.zig. Each dof's passive force is therefore its own: no
// sum crosses dofs, and one invocation per world and dof computes it, in robot.zig's order - the damper's term, then
// the spring's - each only when its coefficient is not zero, as robot.zig does.
//
// Read: joint_velocities, joint_positions, and the model's damping, stiffness and reference positions. Written:
// passive_joint_forces.

// ------------------------------------------------------------------------------------------------------------------
// PASSIVE AND ACTUATOR FORCES: springs, damping, the actuators' forces and their joint forces
// ------------------------------------------------------------------------------------------------------------------

/// EACH DOF'S PASSIVE FORCE, one invocation per world and dof - robot.zig's `passive` for a dof (tendons are refused
/// before packing, `refuseUnsimulatedFeatures`): zero, less its joint's damping times the dof's rate, less - for a
/// hinge or a slide, whose one dof this is - its stiffness times the coordinate's distance from its reference. MJW
/// computes it per joint (`_spring_damper_dof_passive`); per dof keeps robot.zig's order without any dof waiting for
/// another.
pub fn passive_joint_forces(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const joint: u32 = tables.dof_joint.load(dof);
    var passive_force: f32 = 0.0;
    // The damper: on every dof of its joint, against the dof's rate.
    const damping: f32 = constants.joint_damping.load(joint);
    if (damping != 0.0) {
        const rate: f32 = state.joint_velocities.load(world, dof);
        passive_force -= damping * rate;
    }
    // The spring: on a hinge's or a slide's one dof, toward the reference position. The type is read only for a joint
    // that has a spring at all, as robot.zig reads it.
    const stiffness: f32 = constants.joint_stiffness.load(joint);
    if (stiffness != 0.0) {
        const joint_type: robot.JointType = typeOfJoint(joint);
        if (joint_type == .hinge or joint_type == .slide) {
            const first_coordinate: u32 = tables.joint_first_coordinate.load(joint);
            const joint_position: f32 = state.joint_positions.load(world, first_coordinate);
            const spring_reference: f32 = constants.joint_reference_position.load(joint);
            passive_force -= stiffness * (joint_position - spring_reference);
        }
    }
    state.passive_joint_forces.store(world, dof, passive_force);
}

// -- ACTUATION --
//
// An actuator turns a CONTROL - the number a policy or a controller sets each step - into a force on a joint, in
// robot.zig's three steps:
//
//     the control       clamped to the actuator's range, when it has one
//     the activation    an internal state some actuators carry: none (the control drives the force directly), an
//                       integrator (the control sets its rate), or a filter (it chases the control with a time
//                       constant, by Euler or exactly) - its RATE is written here and integrated by the advance, and
//                       the force reads its current value
//     the force         affine in that input and in the actuator's length and velocity, then clamped to its range
//                       when it has one:   gain x input + bias0 + bias1 x length + bias2 x velocity
//
// A joint actuator's length and velocity are its joint's coordinate and rate (the gear is folded into the gain and the
// bias), and its force acts on its joint's one dof. Every actuator is independent of the others - one invocation per
// world and actuator. Then each dof GATHERS the forces of the actuators acting on it, in actuator order
// (`dof_actuators`), where MuJoCo Warp scatters each force onto its dof with an atomic add: the gather's sum is
// robot.zig's, to the bit, and the same on every run.
//
// Read: controls, activations, joint_positions, joint_velocities, and the model's actuator tables. Written:
// actuator_lengths, actuator_velocities, activation_rates, actuator_forces, actuator_joint_forces.

/// EACH ACTUATOR'S FORCE, one invocation per world and actuator - robot.zig's `actuation` for one actuator, after its
/// `transmission` (MJW: `transmission`, `_actuator_velocity`, `_actuator_force`). The length and velocity, the clamped
/// control, the activation's rate and the force are each written for the stages after.
pub fn actuator_forces(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.actuator_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const actuator: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    // The transmission: a joint actuator's actuator_length and actuator_velocity are its joint's coordinate and rate.
    const joint: u32 = tables.actuator_target.load(actuator);
    const first_coordinate: u32 = tables.joint_first_coordinate.load(joint);
    const first_dof: u32 = tables.joint_first_dof.load(joint);
    const actuator_length: f32 = state.joint_positions.load(world, first_coordinate);
    const actuator_velocity: f32 = state.joint_velocities.load(world, first_dof);
    state.actuator_lengths.store(world, actuator, actuator_length);
    state.actuator_velocities.store(world, actuator, actuator_velocity);
    // The control, clamped to its range when it has one.
    const commanded: f32 = state.controls.load(world, actuator);
    const control_limited: bool = tables.actuator_control_limited.load(actuator) != 0;
    const control: f32 = if (control_limited) clamped: {
        const control_range: [2]f32 = constants.actuator_control_range.loadPair(actuator);
        break :clamped clamp(commanded, control_range[0], control_range[1]);
    } else commanded;
    // The activation: its rate written, its current value the force's input - or the control itself, for none.
    const activation_index: u32 = tables.actuator_activation_index.load(actuator);
    const dynamics: ActivationDynamics = @fromBackingInt(@intCast(tables.actuator_dynamics.load(actuator)));
    const input: f32 = switch (dynamics) {
        .none => control,
        .integrator => integrated: {
            state.activation_rates.store(world, activation_index, control);
            break :integrated state.activations.load(world, activation_index);
        },
        .filter => filtered: {
            const activation: f32 = state.activations.load(world, activation_index);
            const time_constant: f32 = constants.actuator_time_constant.load(actuator);
            const rate: f32 = (control - activation) / time_constant;
            state.activation_rates.store(world, activation_index, rate);
            break :filtered activation;
        },
        .filter_exact => filtered_exactly: {
            // The exact update `w += (u - w)(1 - e^(-dt/tau))`, stable for any time constant, reported as the
            // equivalent rate so the advance integrates every activation alike.
            const activation: f32 = state.activations.load(world, activation_index);
            const time_constant: f32 = constants.actuator_time_constant.load(actuator);
            const timestep: f32 = params.options.timestep;
            const alpha: f32 = 1.0 - @exp(-timestep / time_constant);
            const rate: f32 = (control - activation) * alpha / timestep;
            state.activation_rates.store(world, activation_index, rate);
            break :filtered_exactly activation;
        },
    };
    // The force: affine in the input, the length and the velocity, then clamped to its range when it has one.
    const gain: f32 = constants.actuator_gain.load(actuator);
    const bias: Vec = constants.actuator_bias.loadVec(actuator);
    const affine_force: f32 = gain * input + bias[0] + bias[1] * actuator_length + bias[2] * actuator_velocity;
    const force_limited: bool = tables.actuator_force_limited.load(actuator) != 0;
    const force: f32 = if (force_limited) clamped: {
        const force_range: [2]f32 = constants.actuator_force_range.loadPair(actuator);
        break :clamped clamp(affine_force, force_range[0], force_range[1]);
    } else affine_force;
    state.actuator_forces.store(world, actuator, force);
}

/// EACH DOF'S ACTUATOR FORCE, one invocation per world and dof: the forces of the joint actuators acting on the dof,
/// added in actuator order (`dof_actuators`) from zero - robot.zig's `+=` into a cleared array, to the bit, where
/// MJW's `_qfrc_actuator` scatters with an atomic add.
pub fn actuator_joint_forces(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const first_entry: u32 = tables.dof_first_actuator.load(dof);
    const end_entry: u32 = first_entry + tables.dof_actuator_count.load(dof);
    var joint_force: f32 = 0.0;
    var entry: u32 = first_entry;
    while (entry < end_entry) : (entry += 1) {
        const actuator: u32 = tables.dof_actuators.load(entry);
        joint_force += state.actuator_forces.load(world, actuator);
    }
    state.actuator_joint_forces.store(world, dof, joint_force);
}

// -- THE SERVO --
//
// The tracking task's servo (`robot.servoTorques`) pulls each world toward a target pose with an implicit spring at
// every joint, then asks the model for the torques that give those accelerations - inverse dynamics through the mass
// matrix and the bias forces the step has just computed, the free root's own six dofs left to respond. Its torques are
// the world's applied forces, which the smooth forces read next. Three kernels, robot.zig's functions in each:
//
//     servo_errors          per world and joint   each joint's position error toward its target
//                                                 (`robot.jointPositionDifference`, `differentiatePos`'s per joint)
//     servo_accelerations   per world and dof     each dof's wanted acceleration, the spring at the step's end
//                                                 (`robot.stableSpringAccelToward`), bounded - the root's six zero
//     servo_torques         per world             for a free root, its 6 x 6 block solved for its own acceleration
//                                                 (`robot.rootBlockAcceleration`); then M a + the bias forces
//                                                 (`robot.inverseDynamics`), the root's six torques zero
//
// Read: joint_positions, joint_velocities, servo_targets, servo_target_velocities, mass_matrix, bias_joint_forces.
// Written: servo_errors, servo_accelerations, applied_joint_forces.

/// Dof `dof`'s spring frequency in world `world` - `robot.LimbStiffness.dofFrequency` on the device: with the task's
/// limb stiffness on, its limb's at the stiffness the world's applied action gives it (the numbers after the joints',
/// one per limb); otherwise, and for the free root's dofs, the law's own.
fn dofSpringFrequency(world: u32, dof: u32) f32 {
    const options: StepOptions = params.options;
    if (options.limb_stiffness != .enabled) {
        return options.servo_frequency;
    }
    const limb: u32 = params.layout.model_u.dof_limb.load(dof);
    if (limb == robot.no_limb) {
        return options.servo_frequency;
    }
    const joint_numbers: u32 = params.counts.action_count - params.counts.limb_count;
    const stiffness: f32 = params.layout.world_f.applied_actions.load(world, joint_numbers + limb);
    return robot.limbSpringFrequency(options.servo_frequency, stiffness);
}

/// The dofs a free root owns - six, if joint 0 is a free joint - which the servo does not drive (`robot.rootDofCount`).
fn servoRootDofCount() u32 {
    if (params.counts.joint_count == 0) {
        return 0;
    }
    const first_joint_type: robot.JointType = typeOfJoint(0);
    return if (first_joint_type == .free) 6 else 0;
}

/// ONE WORLD'S MASS-MATRIX PRODUCT for the servo's torques (`robot.multiplyByMassMatrix`): the world's `mass_matrix`
/// times its `servo_accelerations`, the product built in its `applied_joint_forces` - robot.zig's `mulM` in its order.
const ServoMassProduct = struct {
    world: u32,

    pub fn rowStart(storage: ServoMassProduct, dof: u32) u32 {
        _ = storage;
        return params.layout.model_u.mass_row_start.load(dof);
    }
    pub fn rowEntries(storage: ServoMassProduct, dof: u32) u32 {
        _ = storage;
        return params.layout.model_u.mass_row_entry_count.load(dof);
    }
    pub fn column(storage: ServoMassProduct, entry: u32) u32 {
        _ = storage;
        return params.layout.model_u.mass_entry_column.load(entry);
    }
    pub fn massEntry(storage: ServoMassProduct, entry: u32) f32 {
        return params.layout.world_f.mass_matrix.load(storage.world, entry);
    }
    pub fn input(storage: ServoMassProduct, dof: u32) f32 {
        return params.layout.world_f.servo_accelerations.load(storage.world, dof);
    }
    pub fn output(storage: ServoMassProduct, dof: u32) f32 {
        return params.layout.world_f.applied_joint_forces.load(storage.world, dof);
    }
    pub fn setOutput(storage: ServoMassProduct, dof: u32, value: f32) void {
        params.layout.world_f.applied_joint_forces.store(storage.world, dof, value);
    }
};

// ------------------------------------------------------------------------------------------------------------------
// THE SERVO: each dof's error toward its target, its spring's acceleration (a stiffness per limb where on), and
// the torques inverse dynamics gives for them
// ------------------------------------------------------------------------------------------------------------------

/// EACH JOINT'S POSITION ERROR TOWARD THE SERVO'S TARGET, one invocation per world and joint - robot.zig's
/// `differentiatePos` for one joint over a step of one (`robot.jointPositionDifference`): the joint's coordinates and
/// its target's, a value per dof - a ball's and a free root's turn a rotation vector.
pub fn servo_errors(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.joint_count);
    if (!handled.in_range) {
        return;
    }
    if (params.options.servo == .off) {
        return;
    }
    const world: u32 = handled.world;
    const joint: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const joint_type: robot.JointType = typeOfJoint(joint);
    const first_coordinate: u32 = tables.joint_first_coordinate.load(joint);
    const first_dof: u32 = tables.joint_first_dof.load(joint);
    const coordinates: robot.JointCoordinates =
        loadJointCoordinates(state.joint_positions, world, joint_type, first_coordinate);
    const target_coordinates: robot.JointCoordinates =
        loadJointCoordinates(state.servo_targets, world, joint_type, first_coordinate);
    // `differentiatePos` over a step of one: its inverse step, 1 / 1, is one.
    const errors: robot.JointVelocity = robot.jointPositionDifference(joint_type, coordinates, target_coordinates, 1.0);
    var dof_offset: u32 = 0;
    while (dof_offset < joint_type.dofCount()) : (dof_offset += 1) {
        state.servo_errors.store(world, first_dof + dof_offset, errors.numbers[dof_offset]);
    }
}

/// EACH DOF'S WANTED ACCELERATION, one invocation per world and dof - the servo's spring at the end of the step
/// (`robot.stableSpringAccelToward`), toward the dof's target velocity when the servo is toward motion and toward rest
/// otherwise, bounded by the servo's largest acceleration; a free root's six dofs zero here, their own acceleration
/// solved by `servo_torques`.
pub fn servo_accelerations(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    if (params.options.servo == .off) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const state: WorldStateLayout = params.layout.world_f;
    if (dof < servoRootDofCount()) {
        state.servo_accelerations.store(world, dof, 0.0);
        return;
    }
    const options: StepOptions = params.options;
    const moving_target: f32 = if (options.servo == .toward_motion)
        state.servo_target_velocities.load(world, dof)
    else
        0.0;
    const want: f32 = robot.stableSpringAccelToward(
        state.servo_errors.load(world, dof),
        state.joint_velocities.load(world, dof),
        moving_target,
        dofSpringFrequency(world, dof),
        options.servo_damping,
        options.timestep,
    );
    const bound: f32 = options.servo_max_acceleration;
    state.servo_accelerations.store(world, dof, clamp(want, -bound, bound));
}

/// A FREE ROOT's 6 x 6 BLOCK SYSTEM in world `world`, as robot.zig's `floatingBaseTorques` builds it: each row r the
/// mass matrix's root entries M[r][c], then its right-hand side -(c_r + M_rj a_j), the bias force less the joints'
/// wanted accelerations through their coupling to the root, taken over the joint dofs in order.
fn rootBlockSystem(world: u32) [6][7]f32 {
    const state: WorldStateLayout = params.layout.world_f;
    const dof_count: u32 = params.counts.dof_count;
    var system: [6][7]f32 = undefined;
    var row: u32 = 0;
    while (row < 6) : (row += 1) {
        var right_hand_side: f32 = -state.bias_joint_forces.load(world, row);
        var joint_dof: u32 = 6;
        while (joint_dof < dof_count) : (joint_dof += 1) {
            // M[r][j] for a joint dof j below the root: its entry in j's row, at the root's column r.
            const coupling: f32 = massMatrixEntry(world, joint_dof, row);
            right_hand_side -= coupling * state.servo_accelerations.load(world, joint_dof);
        }
        var column: u32 = 0;
        while (column < 6) : (column += 1) {
            const higher: u32 = @max(row, column);
            const lower: u32 = @min(row, column);
            system[row][column] = massMatrixEntry(world, higher, lower);
        }
        system[row][6] = right_hand_side;
    }
    return system;
}

/// THE SERVO's TORQUES, one invocation per world - robot.zig's `servoTorques` after its accelerations. For a free root,
/// `floatingBaseTorques`: its 6 x 6 block from the mass matrix's root rows, its right-hand side -(c_r + M_rj a_j) taken
/// over the joints in dof order, solved for the root's own acceleration (`robot.rootBlockAcceleration`). Then
/// `inverseDynamics` on the whole: M a by robot.zig's product into the applied forces, the bias forces added, and a
/// free root's six torques zero - nothing actuates the root.
pub fn servo_torques(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    if (params.options.servo == .off) {
        return;
    }
    const state: WorldStateLayout = params.layout.world_f;
    const dof_count: u32 = params.counts.dof_count;
    const root_dofs: u32 = servoRootDofCount();
    if (root_dofs == 6) {
        const root_acceleration: [6]f32 = robot.rootBlockAcceleration(rootBlockSystem(world));
        var root_dof: u32 = 0;
        while (root_dof < 6) : (root_dof += 1) {
            state.servo_accelerations.store(world, root_dof, root_acceleration[root_dof]);
        }
    }
    const product: ServoMassProduct = .{ .world = world };
    robot.multiplyByMassMatrix(product, dof_count);
    var dof: u32 = 0;
    while (dof < dof_count) : (dof += 1) {
        const torque: f32 = state.applied_joint_forces.load(world, dof) + state.bias_joint_forces.load(world, dof);
        state.applied_joint_forces.store(world, dof, torque);
    }
    dof = 0;
    while (dof < root_dofs) : (dof += 1) {
        state.applied_joint_forces.store(world, dof, 0.0);
    }
}

/// THE SERVO's EFFORT, one invocation per world, each physics step right after its torques - the CPU fleet's
/// `driveOnce` adding its own: every actuated dof's torque at the velocity it acts through (`robot.addDofEffort`, dof
/// after dof), added into the world's sums for its decision.
pub fn accumulate_effort(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const state: WorldStateLayout = params.layout.world_f;
    const weight: f32 = params.layout.model_f.character_weight.load(0);
    const timestep: f32 = params.options.timestep;
    var sums: robot.EffortSums = .{
        .energy = state.effort_energy.load(world, 0),
        .torque_squares = state.effort_torque_squares.load(world, 0),
    };
    var dof: u32 = servoRootDofCount();
    while (dof < params.counts.dof_count) : (dof += 1) {
        const torque: f32 = state.applied_joint_forces.load(world, dof);
        const velocity: f32 = state.joint_velocities.load(world, dof);
        robot.addDofEffort(&sums, torque, velocity, timestep, weight);
    }
    state.effort_energy.store(world, 0, sums.energy);
    state.effort_torque_squares.store(world, 0, sums.torque_squares);
}

/// EACH WORLD's EFFORT ZEROED, one invocation per world, at a decision's start (`decision_start_program`), as the CPU
/// fleet's `step` zeroes its characters'.
pub fn zero_effort(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    params.layout.world_f.effort_energy.store(world, 0, 0.0);
    params.layout.world_f.effort_torque_squares.store(world, 0, 0.0);
}

// -- THE SMOOTH ACCELERATION --
//
// The smooth acceleration is how the robot accelerates under every force except the constraints': gravity, the
// centrifugal and Coriolis forces of its own motion, the springs and damping in its joints, its actuators, and any
// force applied from outside, all summed in `smooth_joint_forces`. Then `smooth_joint_accelerations = M^-1
// smooth_joint_forces`. Contacts and joint limits are what this leaves out; in MuJoCo's formulation the constraint
// forces are found starting from this acceleration.
//
// Two kernels: one invocation per world and dof adds each dof's forces up, in robot.zig's order; one per world then
// solves with the factor.
//
// Read: applied_joint_forces, actuator_joint_forces, passive_joint_forces, bias_joint_forces, mass_factor,
// mass_factor_inverse_diagonal. Written: smooth_joint_forces, smooth_joint_accelerations.

// ------------------------------------------------------------------------------------------------------------------
// THE SMOOTH ACCELERATION: every force but the constraints', and the acceleration it gives through the factored
// mass matrix
// ------------------------------------------------------------------------------------------------------------------

/// EACH DOF'S SMOOTH FORCE, one invocation per world and dof: the applied, actuator and passive forces, less the bias
/// force - summed in robot.zig's order, `((applied + actuator) + passive) - bias` (its `forwardDynamics`). MJW's
/// `_qfrc_smooth` sums `((passive - bias) + actuator) + applied`, which rounds differently in the last bit.
pub fn smooth_joint_forces(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const state: WorldStateLayout = params.layout.world_f;
    const applied_force: f32 = state.applied_joint_forces.load(world, dof);
    const actuator_force: f32 = state.actuator_joint_forces.load(world, dof);
    const passive_force: f32 = state.passive_joint_forces.load(world, dof);
    const bias_force: f32 = state.bias_joint_forces.load(world, dof);
    const smooth_force: f32 = applied_force + actuator_force + passive_force - bias_force;
    state.smooth_joint_forces.store(world, dof, smooth_force);
}

/// THE SMOOTH ACCELERATION, one invocation per world: smooth_joint_accelerations = M^-1 smooth_joint_forces - the
/// acceleration the forces other than the constraints' would cause - the forces copied into the acceleration and solved
/// in place with the factor (`robot.solveLdl`), as robot.zig's `forwardDynamics` solves.
pub fn solve_smooth_acceleration(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const state: WorldStateLayout = params.layout.world_f;
    var dof: u32 = 0;
    while (dof < params.counts.dof_count) : (dof += 1) {
        state.smooth_joint_accelerations.store(world, dof, state.smooth_joint_forces.load(world, dof));
    }
    const storage: SmoothAccelerationSolve = .{ .world = world };
    robot.solveLdl(storage, params.counts.dof_count);
}

// -- CONSTRAINTS: THE ROWS EACH WORLD'S LIMITS MAKE --
//
// A joint with a range has two ENDS, and each end can push back: a constraint ROW, in MuJoCo's language, is one such
// push - one scalar condition the solver will hold, here that the joint stay on the right side of its end. Which rows
// exist changes every step, as joints come near their ends and leave them again, so the rows are found each step in
// two passes, and always in the same order:
//
//     limit_candidates     per world and CANDIDATE - both ends of every limited joint, in joint order, the lower
//                          end first: the distance to the end, and whether it is inside the joint's MARGIN, the
//                          distance at which the end starts to push
//     constraint_rows      per world: the active candidates, packed into rows from row 0 in candidate order
//     project_constraints  per world and row: what the solver needs of each row - its inertia, its velocity, its
//                          softness, the acceleration it asks for
//
// The order is robot.zig's own (`makeConstraints`, lower end then upper, joint by joint) and MuJoCo's, and it never
// depends on which invocation finishes first: every candidate has its fixed slot, and one invocation per world packs
// them. (MuJoCo Warp hands out rows with an atomic counter instead, so its rows come in whatever order its threads
// reach them.) The packing walks a world's candidates one by one, but there are only two per limited joint.
//
// Read: joint_positions, joint_velocities, the mass matrix's factor, the limited joints' range, margin, softness and
// impedance. Written: limit_candidate_distance, limit_candidate_active, constraint_row_kind, constraint_row_source,
// constraint_violation,
// the rows' Jacobians (constraint_jacobian_values, constraint_jacobian_dofs, constraint_jacobian_nonzero_count),
// constraint_row_count, and each row's projection (constraint_inverse_inertia_jacobian, constraint_inertia,
// constraint_velocity, constraint_regularizer, constraint_target_acceleration).

/// One floor slot of `world` written: its contact if there is one - position, distance and frame, the frame from the
/// floor's normal and the contact's tangent hint (`robot.contactFrame`) - or empty, every number zero.
fn storeFloorSlot(
    world: u32,
    slot: u32,
    normal: Vec,
    contact_or_none: ?robot.PlaneContact,
) void {
    const filled: WorldArray(.world_u, .floor_slots) = params.layout.world_u.floor_slot_filled;
    const state: WorldStateLayout = params.layout.world_f;
    // An empty slot is all zeros, so two engines that agree on which slots hold contacts agree on every number.
    const contact: robot.PlaneContact = contact_or_none orelse {
        filled.store(world, slot, 0);
        state.floor_slot_positions.storeVec(world, slot, vec(0, 0, 0));
        state.floor_slot_distances.store(world, slot, 0);
        state.floor_slot_first_tangents.storeVec(world, slot, vec(0, 0, 0));
        state.floor_slot_second_tangents.storeVec(world, slot, vec(0, 0, 0));
        return;
    };
    const tangents: [2]Vec = robot.contactFrame(normal, contact.tangent_hint);
    filled.store(world, slot, 1);
    state.floor_slot_positions.storeVec(world, slot, contact.position);
    state.floor_slot_distances.store(world, slot, contact.distance);
    state.floor_slot_first_tangents.storeVec(world, slot, tangents[0]);
    state.floor_slot_second_tangents.storeVec(world, slot, tangents[1]);
}

// ------------------------------------------------------------------------------------------------------------------
// CONTACTS: each world's geoms against the floor, robot.zig's own collision functions
// ------------------------------------------------------------------------------------------------------------------

/// THE FLOOR'S CONTACTS, one invocation per world and geom - robot.zig's `pushFloorContacts` for one geom: MuJoCo's
/// plane functions, robot.zig's own (`robot.planeSphere`, `planeCapsule`, `planeBox`), on the geom's pose in the
/// world, each of its slots filled with a contact or left empty, in the order robot.zig pushes them. A capsule's axis
/// is its local y, zimr's convention. With no floor nothing is written: what reads the slots reads the switch first.
pub fn floor_contacts(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.geom_count);
    if (!handled.in_range) {
        return;
    }
    if (params.options.floor_contacts == .disabled) {
        return;
    }
    const world: u32 = handled.world;
    const geom: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const slot_count: u32 = tables.geom_floor_slot_count.load(geom);
    if (slot_count == 0) {
        return;
    }
    const first_slot: u32 = tables.geom_first_floor_slot.load(geom);
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const up: Vec = vec(0, 0, 1);
    const plane: robot.Plane = .{ .point = vec(0, 0, params.options.floor_height), .normal = up };
    const margin: f32 = params.options.floor_margin;
    const center: Vec = state.geom_positions.loadVec(world, geom);
    const rotation: Vec = state.geom_orientations.loadVec(world, geom);
    const size: Vec = constants.geom_size.loadVec(geom);
    const geom_type: GeomType = typeOfGeom(geom);
    switch (geom_type) {
        .sphere => {
            const slot: ?robot.PlaneContact = robot.planeSphere(plane, center, size[0], margin);
            storeFloorSlot(world, first_slot, up, slot);
        },
        .capsule => {
            const axis: Vec = rotate(rotation, vec(0, 1, 0));
            const slots: [2]?robot.PlaneContact = robot.planeCapsule(plane, center, axis, size[1], size[0], margin);
            for (slots, 0..) |slot, index| {
                storeFloorSlot(world, first_slot + @as(u32, @intCast(index)), up, slot);
            }
        },
        .box => {
            const half_extent: Vec = vec(size[0], size[1], size[2]);
            const slots: [4]?robot.PlaneContact = robot.planeBox(plane, center, rotation, half_extent, margin);
            for (slots, 0..) |slot, index| {
                storeFloorSlot(world, first_slot + @as(u32, @intCast(index)), up, slot);
            }
        },
        .cylinder => {
            // zimr's cylinder lies along its local y; its local x is taken when its cap lies flat.
            const axis: Vec = rotate(rotation, vec(0, 1, 0));
            const side: Vec = rotate(rotation, vec(1, 0, 0));
            const slots: [4]?robot.PlaneContact =
                robot.planeCylinder(plane, center, axis, side, size[1], size[0], margin);
            for (slots, 0..) |slot, index| {
                storeFloorSlot(world, first_slot + @as(u32, @intCast(index)), up, slot);
            }
        },
        else => {},
    }
}

// ------------------------------------------------------------------------------------------------------------------
// THE CONSTRAINT ROWS: the joint limits and contacts that bind, their rows, and their projection
// ------------------------------------------------------------------------------------------------------------------

/// EACH LIMIT CANDIDATE'S DISTANCE TO ITS END, one invocation per world and candidate. Candidate c is an end of joint
/// `limited_joints[c / 2]` - the lower end when c is even, the upper when it is odd - and its distance is how far the
/// joint is from that end, measured toward the inside of the range:
///
///     lower end    distance = q - lo        positive inside the range, negative once q has passed below lo
///     upper end    distance = hi - q        positive inside the range, negative once q has passed above hi
///
/// The candidate is ACTIVE - it will become a row - while its distance is below the joint's margin: the end begins to
/// push before the joint reaches it when the margin is positive, and only once the joint is past it when the margin
/// is zero. robot.zig computes both in exactly this arithmetic.
pub fn limit_candidates(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.limit_candidate_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const candidate: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const joint: u32 = tables.limited_joints.load(candidate / 2);
    const is_upper_end: bool = candidate % 2 == 1;
    const coordinate: u32 = tables.joint_first_coordinate.load(joint);
    const joint_position: f32 = state.joint_positions.load(world, coordinate);
    const range: [2]f32 = constants.joint_range.loadPair(joint);
    const lower_end: f32 = range[0];
    const upper_end: f32 = range[1];
    const distance_to_end: f32 = if (is_upper_end) upper_end - joint_position else joint_position - lower_end;
    const margin: f32 = constants.joint_limit_margin.load(joint);
    // robot.zig's own test, word for word - an end is skipped when its distance is at or beyond the margin - rather
    // than `distance < margin`: the two agree for every number, but not for NaN, where only this form keeps the row.
    // A joint gone NaN then keeps a NaN row, as on the CPU, instead of silently losing its limit.
    const is_beyond_margin: bool = distance_to_end >= margin;
    // A model whose options disable its constraints makes no row (robot.zig makes none: `makeConstraints` is skipped).
    const constraints_enabled: bool = params.options.constraints == .enabled;
    const is_active: bool = constraints_enabled and !is_beyond_margin;
    params.layout.efc_f.limit_candidate_distance.store(world, candidate, distance_to_end);
    params.layout.world_u.limit_candidate_active.store(world, candidate, @intFromBool(is_active));
}

/// ONE FLOOR CONTACT, as its rows need it: the slot it fills, its body (the geom's - the world is the other, which
/// moves nowhere), its friction (the larger of the geom's and the floor's, MuJoCo's rule), its frame's two tangents,
/// the contact point from the frame origin the dof axes are about (the root's subtree centre of mass, MuJoCo's
/// `cdof` convention), its body's chain of dofs, its violation (the distance less the margin) and, for the reference
/// pose's inertia, the two bodies' translation weights summed.
const FloorContact = struct {
    slot: u32,
    body: u32,
    friction: f32,
    tangents: [2]Vec,
    point_from_origin: Vec,
    chain_start: u32,
    chain_length: u32,
    violation: f32,
    translation_weight: f32,
};

/// World `world`'s contact in floor slot `slot` (`FloorContact`) - none when the slot is empty, or when its contact is
/// at its margin or beyond: not touching, and not close enough to matter (robot.zig's `addContactRows`).
fn floorContactAt(world: u32, slot: u32) ?FloorContact {
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    if (params.layout.world_u.floor_slot_filled.load(world, slot) == 0) {
        return null;
    }
    const margin: f32 = params.options.floor_margin;
    const distance: f32 = state.floor_slot_distances.load(world, slot);
    if (distance >= margin) {
        return null;
    }
    const geom: u32 = tables.floor_slot_geom.load(slot);
    const body: u32 = tables.geom_body.load(geom);
    const root: u32 = tables.body_root.load(body);
    const position: Vec = state.floor_slot_positions.loadVec(world, slot);
    const world_weight: f32 = constants.body_translation_inverse_weight.load(robot.world_body);
    const body_weight: f32 = constants.body_translation_inverse_weight.load(body);
    const contact: FloorContact = .{
        .slot = slot,
        .body = body,
        .friction = @max(constants.geom_friction.load(geom), params.options.floor_friction),
        .tangents = .{
            state.floor_slot_first_tangents.loadVec(world, slot),
            state.floor_slot_second_tangents.loadVec(world, slot),
        },
        .point_from_origin = position - state.subtree_centres_of_mass.loadVec(world, root),
        .chain_start = tables.body_chain_start.load(body),
        .chain_length = tables.body_chain_length.load(body),
        .violation = distance - margin,
        .translation_weight = world_weight + body_weight,
    };
    return contact;
}

/// ONE EDGE OF A CONTACT's FRICTION PYRAMID, as row `row` of `world` (robot.zig's `addContactRows`): pushing along the
/// edge is pushing along the normal while sliding along `tangent` in the direction of `sign`, so its Jacobian is the
/// normal's plus sign x mu x the tangent's. Each is the contact point's motion along that direction per unit of each
/// chain dof's velocity (robot.zig's `jacPoint`: lin + ang x the point from the origin), stored over the chain's dofs
/// in dof order. Under the reference pose's inertia, the row's is the contact's translation weight x (1 + mu^2).
fn storeContactEdgeRow(
    world: u32,
    row: u32,
    contact: FloorContact,
    tangent: Vec,
    sign: f32,
) void {
    const tables: ModelTablesLayout = params.layout.model_u;
    const integers: WorldIntegersLayout = params.layout.world_u;
    const state: WorldStateLayout = params.layout.world_f;
    const rows: ConstraintRowsLayout = params.layout.efc_f;
    const normal: Vec = vec(0, 0, 1);
    const first_nonzero: u32 = row * params.counts.row_nonzero_capacity;
    integers.constraint_row_kind.store(world, row, @backingInt(robot.ConstraintKind.contact));
    integers.constraint_row_source.store(world, row, contact.slot);
    rows.constraint_violation.store(world, row, contact.violation);
    integers.constraint_jacobian_nonzero_count.store(world, row, contact.chain_length);
    var link: u32 = 0;
    while (link < contact.chain_length) : (link += 1) {
        const dof: u32 = tables.chain_dofs.load(contact.chain_start + link);
        const motion: robot.Motion = state.dof_axes.loadMotion(world, dof);
        const point_motion: Vec = motion.lin + cross(motion.ang, contact.point_from_origin);
        const along_normal: f32 = dot3(normal, point_motion);
        const along_tangent: f32 = dot3(tangent, point_motion);
        // robot.zig's expression, in its order: the normal's part, then sign x mu x the tangent's.
        const edge_value: f32 = along_normal + sign * contact.friction * along_tangent;
        integers.constraint_jacobian_dofs.store(world, first_nonzero + link, dof);
        rows.constraint_jacobian_values.store(world, first_nonzero + link, edge_value);
    }
    if (params.options.constraint_inertia == .reference_pose) {
        const cone_factor: f32 = 1.0 + contact.friction * contact.friction;
        rows.constraint_inertia.store(world, row, contact.translation_weight * cone_factor);
    }
}

/// THE FLOOR CONTACTS' ROWS of `world`, packed from row `first_row`: for each contact in slot order (robot.zig's
/// contact order, `packFloorSlots`), four rows - one per edge of its friction pyramid, for each tangent and then each
/// sign. Returns the rows packed so far.
fn packContactRows(world: u32, first_row: u32) u32 {
    var rows_packed: u32 = first_row;
    var slot: u32 = 0;
    while (slot < params.counts.floor_slot_count) : (slot += 1) {
        const contact: FloorContact = floorContactAt(world, slot) orelse continue;
        for (contact.tangents) |tangent| {
            for ([_]f32{ 1.0, -1.0 }) |sign| {
                storeContactEdgeRow(world, rows_packed, contact, tangent, sign);
                rows_packed += 1;
            }
        }
    }
    return rows_packed;
}

/// EACH WORLD'S ROWS, one invocation per world: its active candidates, in candidate order, packed into rows from
/// row 0 - each row recording the candidate it came from, its VIOLATION (the candidate's distance minus its joint's
/// margin: zero where the end starts to push, negative the further inside the margin the joint has gone), its
/// Jacobian's one nonzero and - under the reference pose's inertia, MuJoCo's default - its inertia, the joint's
/// inverse weight at the reference pose (MuJoCo's `efc_diagApprox` for a limit). Then the floor's contacts' rows
/// (`packContactRows`), when the worlds have a floor. The world's row count follows. The device's rows hold every
/// candidate and four rows a floor slot (`Counts.constraint_capacity`), so a world never runs out of them.
pub fn constraint_rows(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const integers: WorldIntegersLayout = params.layout.world_u;
    const rows: ConstraintRowsLayout = params.layout.efc_f;
    var rows_packed: u32 = 0;
    var candidate: u32 = 0;
    while (candidate < params.counts.limit_candidate_count) : (candidate += 1) {
        const is_active: bool = integers.limit_candidate_active.load(world, candidate) != 0;
        if (!is_active) {
            continue;
        }
        const joint: u32 = tables.limited_joints.load(candidate / 2);
        const margin: f32 = constants.joint_limit_margin.load(joint);
        const distance_to_end: f32 = rows.limit_candidate_distance.load(world, candidate);
        const violation: f32 = distance_to_end - margin;
        integers.constraint_row_kind.store(world, rows_packed, @backingInt(robot.ConstraintKind.limit));
        integers.constraint_row_source.store(world, rows_packed, candidate);
        rows.constraint_violation.store(world, rows_packed, violation);
        // The row's Jacobian, one nonzero: the distance grows with the joint's velocity at a lower end and shrinks
        // with it at an upper end.
        const is_upper_end: bool = candidate % 2 == 1;
        const jacobian_entry: f32 = if (is_upper_end) -1.0 else 1.0;
        const first_slot: u32 = rows_packed * params.counts.row_nonzero_capacity;
        const joint_dof: u32 = tables.joint_first_dof.load(joint);
        integers.constraint_jacobian_nonzero_count.store(world, rows_packed, 1);
        integers.constraint_jacobian_dofs.store(world, first_slot, joint_dof);
        rows.constraint_jacobian_values.store(world, first_slot, jacobian_entry);
        if (params.options.constraint_inertia == .reference_pose) {
            rows.constraint_inertia.store(world, rows_packed, constants.dof_inverse_weight.load(joint_dof));
        }
        rows_packed += 1;
    }
    // The floor's rows, when the worlds have a floor and the model's constraints are simulated - robot.zig makes no row
    // of any kind for a model whose options disable its constraints, its floor's contacts included.
    const floor_makes_rows: bool = params.options.floor_contacts == .enabled and params.options.constraints == .enabled;
    if (floor_makes_rows) {
        rows_packed = packContactRows(world, rows_packed);
    }
    integers.constraint_row_count.store(world, 0, rows_packed);
}

/// EACH ROW'S PROJECTION, one invocation per world and row slot - robot.zig's `projectConstraints`, row by row, in its
/// arithmetic: everything the solver needs to know of a row, from the row, the mechanism's inertia and its velocity.
///
///     inertia             how hard the row is to accelerate: under MuJoCo's default, the reference pose's, which
///                         the rows kernel has set - no solve; under the exact inertia (MuJoCo's DIAGEXACT),
///                         J M^-1 J^T at the pose the mechanism has now, J's row solved with the world's mass-matrix
///                         factor into M^-1 J^T, the joint accelerations a unit push along the row would cause
///     velocity            J qdot - how fast the row's distance is changing
///     impedance           the row's impedance curve at its violation (`robot.Impedance.at`): how strongly the row
///                         holds, between the curve's minimum and maximum, kept just inside (0, 1)
///     regulariser         R = (1 - impedance) / impedance x inertia - the row's softness as the solver uses it
///     target              the acceleration a damped spring would give the row: -b x velocity - k x impedance x
///                         violation, its stiffness k and damping b from the softness's time constant (never shorter
///                         than two steps) and damping ratio
///
/// Every row is a joint limit's, so its softness and impedance are its joint's. A row's Jacobian is sparse, and its
/// sums run over its nonzeros alone, in dof order: robot.zig's dense sums add only products of zero besides, which
/// change no sum, so the two agree to the bit.
pub fn project_constraints(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.constraint_capacity);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const row: u32 = handled.element;
    const integers: WorldIntegersLayout = params.layout.world_u;
    const row_count: u32 = integers.constraint_row_count.load(world, 0);
    // A slot past the world's rows this step: nothing to project.
    if (row >= row_count) {
        return;
    }
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const rows: ConstraintRowsLayout = params.layout.efc_f;
    const dof_count: u32 = params.counts.dof_count;
    const first_slot: u32 = row * params.counts.row_nonzero_capacity;
    const nonzero_count: u32 = integers.constraint_jacobian_nonzero_count.load(world, row);
    const uses_reference_inertia: bool = params.options.constraint_inertia == .reference_pose;
    var row_inertia: f32 = 0.0;
    var slot: u32 = 0;
    if (uses_reference_inertia) {
        // MuJoCo's default: the row's inertia from the reference pose, set by the rows kernel - nothing to solve.
        row_inertia = rows.constraint_inertia.load(world, row);
    } else {
        // M^-1 J^T: the row's Jacobian spread out over every dof - zeros, then its nonzeros - and solved in place.
        const solution_first: u32 = row * dof_count;
        var dof: u32 = 0;
        while (dof < dof_count) : (dof += 1) {
            rows.constraint_inverse_inertia_jacobian.store(world, solution_first + dof, 0.0);
        }
        slot = 0;
        while (slot < nonzero_count) : (slot += 1) {
            const nonzero_dof: u32 = integers.constraint_jacobian_dofs.load(world, first_slot + slot);
            const nonzero_value: f32 = rows.constraint_jacobian_values.load(world, first_slot + slot);
            rows.constraint_inverse_inertia_jacobian.store(world, solution_first + nonzero_dof, nonzero_value);
        }
        const solve_storage: ConstraintRowSolve = .{ .world = world, .solution_first = solution_first };
        robot.solveLdl(solve_storage, dof_count);
        // The row's inertia J M^-1 J^T, over the row's nonzeros in dof order.
        slot = 0;
        while (slot < nonzero_count) : (slot += 1) {
            const nonzero_dof: u32 = integers.constraint_jacobian_dofs.load(world, first_slot + slot);
            const nonzero_value: f32 = rows.constraint_jacobian_values.load(world, first_slot + slot);
            const solution_item: u32 = solution_first + nonzero_dof;
            const inverse_inertia_entry: f32 = rows.constraint_inverse_inertia_jacobian.load(world, solution_item);
            row_inertia += nonzero_value * inverse_inertia_entry;
        }
    }
    // The row's velocity J qdot, over its nonzeros in dof order.
    var row_velocity: f32 = 0.0;
    slot = 0;
    while (slot < nonzero_count) : (slot += 1) {
        const nonzero_dof: u32 = integers.constraint_jacobian_dofs.load(world, first_slot + slot);
        const nonzero_value: f32 = rows.constraint_jacobian_values.load(world, first_slot + slot);
        const joint_velocity: f32 = state.joint_velocities.load(world, nonzero_dof);
        row_velocity += nonzero_value * joint_velocity;
    }
    // The row's softness and impedance: a limit's, its joint's; a floor contact's, robot.zig's contact defaults (as
    // `pushFloorContacts` leaves them).
    const kind: robot.ConstraintKind = @fromBackingInt(@intCast(integers.constraint_row_kind.load(world, row)));
    var softness: robot.Softness = .{};
    var impedance_curve: robot.Impedance = .{};
    if (kind == .limit) {
        const candidate: u32 = integers.constraint_row_source.load(world, row);
        const joint: u32 = tables.limited_joints.load(candidate / 2);
        const softness_pair: [2]f32 = constants.joint_limit_softness.loadPair(joint);
        softness = .{ .time_const_s = softness_pair[0], .damp_ratio = softness_pair[1] };
        const impedance_first_number: u32 = constants.joint_limit_impedance.at(joint);
        impedance_curve = .{
            .min = loadNumber(.model_f, impedance_first_number),
            .max = loadNumber(.model_f, impedance_first_number + 1),
            .width = loadNumber(.model_f, impedance_first_number + 2),
            .midpoint = loadNumber(.model_f, impedance_first_number + 3),
            .power = loadNumber(.model_f, impedance_first_number + 4),
        };
    }
    const violation: f32 = rows.constraint_violation.load(world, row);
    // robot.zig's expressions, in its order.
    const impedance: f32 = clamp(impedance_curve.at(violation), robot.min_impedance, robot.max_impedance);
    const softness_ratio: f32 = (1.0 - impedance) / impedance;
    const regularizer: f32 = @max(robot.min_regularizer, softness_ratio * row_inertia);
    const largest_impedance: f32 = @max(impedance_curve.max, robot.min_impedance);
    const timestep: f32 = params.options.timestep;
    const time_constant: f32 = @max(softness.time_const_s, 2.0 * timestep);
    const stiffness_denominator: f32 = largest_impedance * largest_impedance * time_constant * time_constant *
        softness.damp_ratio * softness.damp_ratio;
    const stiffness: f32 = 1.0 / @max(robot.min_impedance, stiffness_denominator);
    const damping: f32 = 2.0 / @max(robot.min_impedance, largest_impedance * time_constant);
    const damping_term: f32 = -damping * row_velocity;
    const stiffness_term: f32 = -stiffness * impedance * violation;
    const target_acceleration: f32 = damping_term + stiffness_term;
    if (!uses_reference_inertia) {
        rows.constraint_inertia.store(world, row, row_inertia);
    }
    rows.constraint_velocity.store(world, row, row_velocity);
    rows.constraint_regularizer.store(world, row, regularizer);
    rows.constraint_target_acceleration.store(world, row, target_acceleration);
}

// -- CONSTRAINTS: THE FORCES THAT SATISFY THE ROWS --
//
// With each row projected, the solver finds the joint accelerations a: those that best satisfy every row as the row's
// softness allows, the mechanism's inertia set against the rows' pushes. robot.zig's Newton - MuJoCo's, as MuJoCo
// Warp runs it - minimises
//
//     L(a) = 1/2 (a - a_free)^T M (a - a_free)  +  sum over the active rows of  1/2 D_i r_i^2,    r = J a - aref
//
// a convex, piecewise quadratic cost (D = 1/R, each row's weight): the first term the price of moving away from the
// free acceleration, the second each row's price for missing what it asks for, a row that may only push counted only
// while it would push (r < 0). From the free acceleration, each round:
//
//     forces       each active row's f = -D r; J^T f, the joint forces the rows apply
//     gradient     g = M (a - a_free) - J^T f
//     Hessian      H = M + J^T D J over the active rows, factored; the step s = -H^-1 g
//     line         along a + alpha s the cost is quadratic piece by piece: its coefficients gathered once (M s, J s),
//                  the lowest point found by MuJoCo's exact line search (`robot.searchLineOver`)
//     advance      a += alpha s, and the two products kept between rounds with it - M (a - a_free) += alpha M s and
//                  r += alpha J s - neither multiplied out again (MuJoCo Warp's `Ma` and `Jaref`)
//
// and the rounds stop on MuJoCo's rules, each scaled by 1 / trace(M): no step, a small improvement, a short gradient,
// a small Newton decrement - or at `newton_max_iterations`, a start already converged taking none.
//
// A WORKGROUP SOLVES ONE WORLD, every round in one dispatch (`newton_solve`). Its invocations work in PHASES
// (`runPhase`), each split among the lanes and closed by a barrier: per row, per dof, per entry of the Hessian, per
// column of its factor - and by the first lane alone where robot.zig's arithmetic is a sum in a fixed order (the mass
// products, the substitutions, the line's coefficients, the measures) or a chain of scalar decisions (the line
// search: robot.zig's own `searchLineOver`, run over the workgroup's rows). Every value keeps robot.zig's operations
// in robot.zig's order, so the twin - which runs the same phases, lane after lane - equals robot.zig to the bit:
//
//     the factor          right-looking, column by column: each entry's subtractions in column order, the running
//                         subtraction of robot.zig's `choleskyFactor`
//     sparse rows         every sum over a row's nonzeros in dof order equals robot.zig's dense sum, which adds only
//                         products of zero besides
//
// Every decision the workgroup takes together - go on or stop - is made by the first lane and read by all through a
// UNIFORM workgroup value (`k.workgroupUniformLoad`), so every loop with barriers inside is in uniform control flow,
// for Vulkan and for WGSL's validators alike. The working set lives in workgroup memory, sized for the largest model it
// is meant for (`max_newton_dofs`, `max_newton_rows`): 31,420 bytes, within the 32 KB a WebGPU adapter commonly grants
// and the 48 KB of a desktop GPU - the Hessian 23 KB of it, the 256 rows 6 KB.
//
// Read: the world's smooth acceleration, mass matrix and rows (Jacobians, regularisers, target accelerations).
// Written: joint_accelerations, constraint_force, constraint_joint_forces, newton_iterations, newton_line_evaluations.

/// Newton's working set, in workgroup memory: the Hessian (factored in place, row-major at the model's own order); the
/// round's dof vectors - the accelerations a, the inertia's gradient M (a - a_free) kept between rounds, the gradient,
/// the step, the mass product M s, the joint forces J^T f, and the start's scratch a - a_free; and each row's residual
/// r = J a - aref (kept between rounds), weight D = 1/R, rate J s along the step, force, and whether it is active and
/// whether it may only push.
const newton_hessian = k.shared(f32, max_newton_dofs * max_newton_dofs, "robotgpu_newton_hessian");
const newton_acceleration = k.shared(f32, max_newton_dofs, "robotgpu_newton_acceleration");
const newton_inertia_gradient = k.shared(f32, max_newton_dofs, "robotgpu_newton_inertia_gradient");
const newton_gradient = k.shared(f32, max_newton_dofs, "robotgpu_newton_gradient");
const newton_step = k.shared(f32, max_newton_dofs, "robotgpu_newton_step");
const newton_mass_product = k.shared(f32, max_newton_dofs, "robotgpu_newton_mass_product");
const newton_joint_forces = k.shared(f32, max_newton_dofs, "robotgpu_newton_joint_forces");
const newton_scratch = k.shared(f32, max_newton_dofs, "robotgpu_newton_scratch");
const newton_residual = k.shared(f32, max_newton_rows, "robotgpu_newton_residual");
const newton_row_weight = k.shared(f32, max_newton_rows, "robotgpu_newton_row_weight");
const newton_row_rate = k.shared(f32, max_newton_rows, "robotgpu_newton_row_rate");
const newton_row_force = k.shared(f32, max_newton_rows, "robotgpu_newton_row_force");
const newton_row_active = k.shared(u32, max_newton_rows, "robotgpu_newton_row_active");
/// WHAT EACH ROW STANDS ON, a word a row: its kind (`robot.ConstraintKind`) in the top three bits, and below them a
/// limit row's one dof or a contact row's body - so the row's entry for any dof is read at once (`newtonRowEntry`), and
/// whether it may only push follows from its kind, as in robot.zig.
const newton_row_subject = k.shared(u32, max_newton_rows, "robotgpu_newton_row_subject");
/// The first lane's scalars, read by the lanes after the phase that wrote them: whether this round's Hessian
/// factored; the stopping rules' scale 1 / trace(M); the derivatives' measures (the gradient's length, the Newton
/// decrement g^T H^-1 g); the line's coefficients (s^T M (a - a_free), 1/2 s^T M s, |s|^2); the line search's step
/// length and improvement; and the points the line searches have evaluated so far.
const newton_factored = k.shared(u32, 1, "robotgpu_newton_factored");
const newton_scale = k.shared(f32, 1, "robotgpu_newton_scale");
const newton_gradient_length = k.shared(f32, 1, "robotgpu_newton_gradient_length");
const newton_decrement = k.shared(f32, 1, "robotgpu_newton_decrement");
const newton_inertia_slope = k.shared(f32, 1, "robotgpu_newton_inertia_slope");
const newton_inertia_half_curvature = k.shared(f32, 1, "robotgpu_newton_inertia_half_curvature");
const newton_step_squared = k.shared(f32, 1, "robotgpu_newton_step_squared");
const newton_alpha = k.shared(f32, 1, "robotgpu_newton_alpha");
const newton_improvement = k.shared(f32, 1, "robotgpu_newton_improvement");
const newton_line_evaluations = k.shared(u32, 1, "robotgpu_newton_line_evaluations");
/// Every decision the workgroup takes together, made by the first lane and read by all (`k.workgroupUniformLoad`).
const newton_decision = k.sharedUniform(u32, 1, "robotgpu_newton_decision");

/// The workgroup memory `newton_solve` declares, in bytes - every array of its working set, summed from the arrays'
/// own types so it cannot fall behind them - which a device must grant before the kernel's pipeline is made
/// (`robotgpu_host.Sim.initGpu`): about 28 KB, within WebGPU's common 32 KB and above its guaranteed 16 KB.
pub const newton_workgroup_bytes: u32 = blk: {
    var total: u32 = 0;
    total += @sizeOf(@TypeOf(newton_hessian.*));
    total += @sizeOf(@TypeOf(newton_acceleration.*));
    total += @sizeOf(@TypeOf(newton_inertia_gradient.*));
    total += @sizeOf(@TypeOf(newton_gradient.*));
    total += @sizeOf(@TypeOf(newton_step.*));
    total += @sizeOf(@TypeOf(newton_mass_product.*));
    total += @sizeOf(@TypeOf(newton_joint_forces.*));
    total += @sizeOf(@TypeOf(newton_scratch.*));
    total += @sizeOf(@TypeOf(newton_residual.*));
    total += @sizeOf(@TypeOf(newton_row_weight.*));
    total += @sizeOf(@TypeOf(newton_row_rate.*));
    total += @sizeOf(@TypeOf(newton_row_force.*));
    total += @sizeOf(@TypeOf(newton_row_active.*));
    total += @sizeOf(@TypeOf(newton_row_subject.*));
    total += @sizeOf(@TypeOf(newton_factored.*));
    total += @sizeOf(@TypeOf(newton_scale.*));
    total += @sizeOf(@TypeOf(newton_gradient_length.*));
    total += @sizeOf(@TypeOf(newton_decrement.*));
    total += @sizeOf(@TypeOf(newton_inertia_slope.*));
    total += @sizeOf(@TypeOf(newton_inertia_half_curvature.*));
    total += @sizeOf(@TypeOf(newton_step_squared.*));
    total += @sizeOf(@TypeOf(newton_alpha.*));
    total += @sizeOf(@TypeOf(newton_improvement.*));
    total += @sizeOf(@TypeOf(newton_line_evaluations.*));
    total += @sizeOf(@TypeOf(newton_decision.*));
    break :blk total;
};

/// The dof vectors of a Newton round, each a workgroup array of `max_newton_dofs`.
const NewtonVector = enum { acceleration, inertia_gradient, gradient, step, mass_product, joint_forces, scratch };

/// Dof `dof` of the Newton vector `vector`.
inline fn loadNewtonVector(comptime vector: NewtonVector, dof: u32) f32 {
    return switch (vector) {
        .acceleration => newton_acceleration[dof],
        .inertia_gradient => newton_inertia_gradient[dof],
        .gradient => newton_gradient[dof],
        .step => newton_step[dof],
        .mass_product => newton_mass_product[dof],
        .joint_forces => newton_joint_forces[dof],
        .scratch => newton_scratch[dof],
    };
}

/// Write dof `dof` of the Newton vector `vector`.
inline fn storeNewtonVector(comptime vector: NewtonVector, dof: u32, value: f32) void {
    switch (vector) {
        .acceleration => newton_acceleration[dof] = value,
        .inertia_gradient => newton_inertia_gradient[dof] = value,
        .gradient => newton_gradient[dof] = value,
        .step => newton_step[dof] = value,
        .mass_product => newton_mass_product[dof] = value,
        .joint_forces => newton_joint_forces[dof] = value,
        .scratch => newton_scratch[dof] = value,
    }
}

/// ONE WORLD'S MASS-MATRIX PRODUCT over Newton's vectors (`robot.multiplyByMassMatrix`): the sparsity from `model_u`,
/// the world's `mass_matrix`, the vector `input_vector` multiplied, the product built in `output_vector` - robot.zig's
/// `mulM` in its order.
fn NewtonMassProduct(comptime input_vector: NewtonVector, comptime output_vector: NewtonVector) type {
    return struct {
        const Storage = @This();

        world: u32,

        pub fn rowStart(storage: Storage, dof: u32) u32 {
            _ = storage;
            return params.layout.model_u.mass_row_start.load(dof);
        }
        pub fn rowEntries(storage: Storage, dof: u32) u32 {
            _ = storage;
            return params.layout.model_u.mass_row_entry_count.load(dof);
        }
        pub fn column(storage: Storage, entry: u32) u32 {
            _ = storage;
            return params.layout.model_u.mass_entry_column.load(entry);
        }
        pub fn massEntry(storage: Storage, entry: u32) f32 {
            return params.layout.world_f.mass_matrix.load(storage.world, entry);
        }
        pub fn input(storage: Storage, dof: u32) f32 {
            _ = storage;
            return loadNewtonVector(input_vector, dof);
        }
        pub fn output(storage: Storage, dof: u32) f32 {
            _ = storage;
            return loadNewtonVector(output_vector, dof);
        }
        pub fn setOutput(storage: Storage, dof: u32, value: f32) void {
            _ = storage;
            storeNewtonVector(output_vector, dof, value);
        }
    };
}

/// Row `row`'s Jacobian entry at dof `dof` in world `world`: the value in the row's slot for that dof, or zero.
inline fn rowJacobianEntry(world: u32, row: u32, dof: u32) f32 {
    const integers: WorldIntegersLayout = params.layout.world_u;
    const first_slot: u32 = row * params.counts.row_nonzero_capacity;
    const nonzero_count: u32 = integers.constraint_jacobian_nonzero_count.load(world, row);
    var slot: u32 = 0;
    while (slot < nonzero_count) : (slot += 1) {
        const slot_dof: u32 = integers.constraint_jacobian_dofs.load(world, first_slot + slot);
        if (slot_dof == dof) {
            return params.layout.efc_f.constraint_jacobian_values.load(world, first_slot + slot);
        }
    }
    return 0.0;
}
/// WHAT A ROW STANDS ON, in one word of workgroup memory (`newton_row_subject`) - so knowing it costs Newton no more
/// memory than the push-only flag it replaced: the row's kind (`robot.ConstraintKind`) in the top bits, and below
/// them a limit row's one dof or a contact row's body.
const RowSubject = struct {
    /// Where the kind begins; the bits below it hold the dof or the body.
    const kind_shift: u32 = 29;

    inline fn pack(kind: robot.ConstraintKind, dof_or_body: u32) u32 {
        const kind_bits: u32 = @as(u32, @backingInt(kind)) << kind_shift;
        return kind_bits | dof_or_body;
    }

    inline fn kindOf(word: u32) robot.ConstraintKind {
        return @fromBackingInt(@intCast(word >> kind_shift));
    }

    /// A limit row's dof, or a contact row's body.
    inline fn dofOrBodyOf(word: u32) u32 {
        const below_kind: u32 = (@as(u32, 1) << kind_shift) - 1;
        return word & below_kind;
    }
};
/// Whether a row may only push - from its kind, as robot.zig decides it (`ConstraintKind.isUnilateral`).
inline fn newtonRowMayOnlyPush(row: u32) bool {
    return RowSubject.kindOf(newton_row_subject[row]).isUnilateral();
}
/// A ROW'S ENTRY FOR A DOF, read at once from what the row stands on (`newton_row_subject`): a limit row's one nonzero
/// at its joint's dof; a contact row's at the dof's place in its body's chain (`body_chain_place`), where its nonzeros
/// lie in that order - zero for a dof the row does not touch. Any other kind, which the device does not make, by the
/// search over its nonzeros (`rowJacobianEntry`).
inline fn newtonRowEntry(world: u32, row: u32, dof: u32) f32 {
    const subject: u32 = newton_row_subject[row];
    const first_slot: u32 = row * params.counts.row_nonzero_capacity;
    const values: WorldArray(.efc_f, .constraint_row_nonzeros) = params.layout.efc_f.constraint_jacobian_values;
    switch (RowSubject.kindOf(subject)) {
        .limit => {
            const limit_dof: u32 = RowSubject.dofOrBodyOf(subject);
            if (dof != limit_dof) {
                return 0.0;
            }
            return values.load(world, first_slot);
        },
        .contact => {
            const body: u32 = RowSubject.dofOrBodyOf(subject);
            const place: u32 = params.layout.model_u.body_chain_place.load(body * params.counts.dof_count + dof);
            if (place == no_chain_place) {
                return 0.0;
            }
            return values.load(world, first_slot + place);
        },
        else => return rowJacobianEntry(world, row, dof),
    }
}

/// THE WORKGROUP'S ROWS as Newton's line search reads them (`robot.requireLineRows`): each row's residual at the step's
/// start, its rate along the step, its weight and whether it may only push - so the first lane runs robot.zig's own
/// `searchLineOver` over them.
const NewtonLineRows = struct {
    pub fn residual(rows: NewtonLineRows, row: u32) f32 {
        _ = rows;
        return newton_residual[row];
    }
    pub fn rate(rows: NewtonLineRows, row: u32) f32 {
        _ = rows;
        return newton_row_rate[row];
    }
    pub fn weight(rows: NewtonLineRows, row: u32) f32 {
        _ = rows;
        return newton_row_weight[row];
    }
    pub fn isUnilateral(rows: NewtonLineRows, row: u32) bool {
        _ = rows;
        return newtonRowMayOnlyPush(row);
    }
};

/// What every phase of `newton_solve` is given: the world, and the round's uniform values - the factor's column, the
/// rounds run.
const NewtonContext = struct {
    world: u32,
    column: u32 = 0,
    iterations: u32 = 0,
};

/// ONE PHASE of a kernel whose workgroup's invocations work together, run for every lane. On the GPU each invocation
/// runs it for its own lane and waits at a barrier for the rest; on the CPU twin the workgroup's first invocation runs
/// it for every lane in turn (the kernel sends its other invocations away) - a barrier's meaning exactly, every lane
/// done before any starts the next phase. So a phase keeps nothing of a lane's from one phase to the next outside
/// workgroup arrays: on the twin, one invocation is every lane.
inline fn runPhase(
    lane: u32,
    comptime phase: fn (NewtonContext, u32) void,
    context: NewtonContext,
) void {
    if (k.is_gpu) {
        phase(context, lane);
        k.workgroupBarrier();
    } else {
        var each_lane: u32 = 0;
        while (each_lane < config.workgroup) : (each_lane += 1) {
            phase(context, each_lane);
        }
    }
}
/// J_row . `vector` in world `world`, over the row's nonzeros in dof order - robot.zig's dense sum, whose other terms
/// are products of zero.
inline fn rowTimesNewtonVector(comptime vector: NewtonVector, world: u32, row: u32) f32 {
    const integers: WorldIntegersLayout = params.layout.world_u;
    const first_slot: u32 = row * params.counts.row_nonzero_capacity;
    const nonzero_count: u32 = integers.constraint_jacobian_nonzero_count.load(world, row);
    var sum: f32 = 0.0;
    var slot: u32 = 0;
    while (slot < nonzero_count) : (slot += 1) {
        const slot_dof: u32 = integers.constraint_jacobian_dofs.load(world, first_slot + slot);
        const slot_value: f32 = params.layout.efc_f.constraint_jacobian_values.load(world, first_slot + slot);
        sum += slot_value * loadNewtonVector(vector, slot_dof);
    }
    return sum;
}
/// The world's rows this step, as Newton holds them. A model whose worlds could hold more rows than Newton's working
/// set is refused (`ModelError.TooManyRows`), so the bound only keeps a wrong count inside the arrays.
inline fn newtonRowCount(world: u32) u32 {
    const row_count: u32 = params.layout.world_u.constraint_row_count.load(world, 0);
    return @min(row_count, max_newton_rows);
}

/// THE START, per row: its weight D = 1/R and what it stands on (`RowSubject`) - from which Newton reads its entries
/// and whether it may only push. Per dof: the accelerations from the free one, which the start's choice keeps or
/// replaces (`newtonChooseStart`).
fn newtonStartRows(context: NewtonContext, lane: u32) void {
    const integers: WorldIntegersLayout = params.layout.world_u;
    const tables: ModelTablesLayout = params.layout.model_u;
    const row_count: u32 = newtonRowCount(context.world);
    var row: u32 = lane;
    while (row < row_count) : (row += config.workgroup) {
        const regularizer: f32 = params.layout.efc_f.constraint_regularizer.load(context.world, row);
        newton_row_weight[row] = 1.0 / regularizer;
        const kind_number: u32 = integers.constraint_row_kind.load(context.world, row);
        const kind: robot.ConstraintKind = @fromBackingInt(@intCast(kind_number));
        const source: u32 = integers.constraint_row_source.load(context.world, row);
        // A limit's row stands on its joint's dof; a contact's on its geom's body.
        const dof_or_body: u32 = switch (kind) {
            .limit => tables.joint_first_dof.load(tables.limited_joints.load(source / 2)),
            .contact => tables.geom_body.load(tables.floor_slot_geom.load(source)),
            else => 0,
        };
        newton_row_subject[row] = RowSubject.pack(kind, dof_or_body);
    }
    var dof: u32 = lane;
    while (dof < params.counts.dof_count) : (dof += config.workgroup) {
        newton_acceleration[dof] = params.layout.world_f.smooth_joint_accelerations.load(context.world, dof);
    }
}
/// The objective at the accelerations in `candidate` - robot.zig's `newtonCostAt`, its arithmetic in its order: the
/// inertia's term, 1/2 (a - a_free)^T M (a - a_free), then 1/2 r^2 / R for each row active at those accelerations, the
/// active set decided there. The first lane's, for choosing Newton's start; it works in the scratch and the mass
/// product, which the start forms again after.
inline fn newtonCostAt(world: u32, comptime candidate: NewtonVector) f32 {
    const dof_count: u32 = params.counts.dof_count;
    var dof: u32 = 0;
    while (dof < dof_count) : (dof += 1) {
        const free_acceleration: f32 = params.layout.world_f.smooth_joint_accelerations.load(world, dof);
        newton_scratch[dof] = loadNewtonVector(candidate, dof) - free_acceleration;
    }
    const product: NewtonMassProduct(.scratch, .mass_product) = .{ .world = world };
    robot.multiplyByMassMatrix(product, dof_count);
    var cost: f32 = 0;
    dof = 0;
    while (dof < dof_count) : (dof += 1) {
        cost += 0.5 * newton_scratch[dof] * newton_mass_product[dof];
    }
    const row_count: u32 = newtonRowCount(world);
    var row: u32 = 0;
    while (row < row_count) : (row += 1) {
        const row_acceleration: f32 = rowTimesNewtonVector(candidate, world, row);
        const target: f32 = params.layout.efc_f.constraint_target_acceleration.load(world, row);
        const residual: f32 = row_acceleration - target;
        const may_only_push: bool = newtonRowMayOnlyPush(row);
        if (may_only_push and residual >= 0) {
            continue;
        }
        const regularizer: f32 = params.layout.efc_f.constraint_regularizer.load(world, row);
        cost += 0.5 * residual * residual / regularizer;
    }
    return cost;
}
/// The first lane: NEWTON's START - the free acceleration, or the last step's answer when the warm start is on and it
/// costs no more (robot.zig's `solveNewton`: the free acceleration's cost first, then the warm start's; MuJoCo's
/// tie-break, the warm start kept unless it costs MORE) - then the start's a - a_free, which the inertia's gradient
/// multiplies. The warm start is held in the step's vector until the derivatives make the step.
fn newtonChooseStart(context: NewtonContext, lane: u32) void {
    if (lane != 0) {
        return;
    }
    const dof_count: u32 = params.counts.dof_count;
    var dof: u32 = 0;
    if (params.options.warm_start == .enabled) {
        while (dof < dof_count) : (dof += 1) {
            newton_step[dof] = params.layout.world_f.warmstart_accelerations.load(context.world, dof);
        }
        const free_cost: f32 = newtonCostAt(context.world, .acceleration);
        const warm_cost: f32 = newtonCostAt(context.world, .step);
        if (warm_cost <= free_cost) {
            dof = 0;
            while (dof < dof_count) : (dof += 1) {
                newton_acceleration[dof] = newton_step[dof];
            }
        }
    }
    dof = 0;
    while (dof < dof_count) : (dof += 1) {
        const free_acceleration: f32 = params.layout.world_f.smooth_joint_accelerations.load(context.world, dof);
        newton_scratch[dof] = newton_acceleration[dof] - free_acceleration;
    }
}
/// The start's kept residuals, r = J a - aref per row.
fn newtonStartResiduals(context: NewtonContext, lane: u32) void {
    const row_count: u32 = newtonRowCount(context.world);
    var row: u32 = lane;
    while (row < row_count) : (row += config.workgroup) {
        const row_acceleration: f32 = rowTimesNewtonVector(.acceleration, context.world, row);
        const target: f32 = params.layout.efc_f.constraint_target_acceleration.load(context.world, row);
        newton_residual[row] = row_acceleration - target;
    }
}
/// The first lane: the start's kept inertia gradient M (a - a_free), by robot.zig's own product; the stopping rules'
/// scale 1 / trace(M), M's diagonal the last stored entry of each row, its armature included; nothing evaluated yet.
fn newtonStartInertia(context: NewtonContext, lane: u32) void {
    if (lane != 0) {
        return;
    }
    const product: NewtonMassProduct(.scratch, .inertia_gradient) = .{ .world = context.world };
    robot.multiplyByMassMatrix(product, params.counts.dof_count);
    const tables: ModelTablesLayout = params.layout.model_u;
    var trace: f32 = 0;
    var dof: u32 = 0;
    while (dof < params.counts.dof_count) : (dof += 1) {
        const diagonal_slot: u32 = tables.mass_row_start.load(dof) + tables.mass_row_entry_count.load(dof) - 1;
        trace += params.layout.world_f.mass_matrix.load(context.world, diagonal_slot);
    }
    newton_scale[0] = 1.0 / @max(1.0e-15, trace);
    newton_line_evaluations[0] = 0;
}
/// Each row active or not - one that may pull always, one that may only push while it would (r < 0) - and its force,
/// -D r when active.
fn newtonRowForces(context: NewtonContext, lane: u32) void {
    const row_count: u32 = newtonRowCount(context.world);
    var row: u32 = lane;
    while (row < row_count) : (row += config.workgroup) {
        const residual: f32 = newton_residual[row];
        const is_active: bool = !newtonRowMayOnlyPush(row) or residual < 0;
        newton_row_active[row] = @intFromBool(is_active);
        const force: f32 = if (is_active) -newton_row_weight[row] * residual else 0;
        newton_row_force[row] = force;
    }
}
/// Per dof: the joint forces J^T f, the rows in row order, and the gradient g = M (a - a_free) - J^T f.
fn newtonGradient(context: NewtonContext, lane: u32) void {
    const row_count: u32 = newtonRowCount(context.world);
    var dof: u32 = lane;
    while (dof < params.counts.dof_count) : (dof += config.workgroup) {
        var joint_force: f32 = 0;
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            const force: f32 = newton_row_force[row];
            if (force == 0) {
                continue;
            }
            const jacobian_entry: f32 = newtonRowEntry(context.world, row, dof);
            if (jacobian_entry != 0.0) {
                joint_force += jacobian_entry * force;
            }
        }
        newton_joint_forces[dof] = joint_force;
        newton_gradient[dof] = newton_inertia_gradient[dof] - joint_force;
    }
}
/// The Hessian H = M + J^T D J, dense, every entry its own: M's entry, then each active row's term in row order -
/// robot.zig's `(J_ri D_r) J_rj`, its products of zero left out.
fn newtonHessian(context: NewtonContext, lane: u32) void {
    const dof_count: u32 = params.counts.dof_count;
    const row_count: u32 = newtonRowCount(context.world);
    const entry_count: u32 = dof_count * dof_count;
    var entry: u32 = lane;
    while (entry < entry_count) : (entry += config.workgroup) {
        const row_dof: u32 = entry / dof_count;
        const column_dof: u32 = entry % dof_count;
        // The lower triangle only: the factorisation and the solves read no other.
        if (column_dof > row_dof) {
            continue;
        }
        const higher: u32 = @max(row_dof, column_dof);
        const lower: u32 = @min(row_dof, column_dof);
        var value: f32 = 0.0 + massMatrixEntry(context.world, higher, lower);
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            if (newton_row_active[row] == 0) {
                continue;
            }
            const row_entry: f32 = newtonRowEntry(context.world, row, row_dof);
            if (row_entry == 0.0) {
                continue;
            }
            const column_entry: f32 = newtonRowEntry(context.world, row, column_dof);
            if (column_entry == 0.0) {
                continue;
            }
            const weighted: f32 = row_entry * newton_row_weight[row];
            value += weighted * column_entry;
        }
        newton_hessian[entry] = value;
    }
}
/// The first lane: the factorisation has not failed yet.
fn newtonFactorStart(context: NewtonContext, lane: u32) void {
    _ = context;
    if (lane != 0) {
        return;
    }
    newton_factored[0] = 1;
}
/// The first lane: the factor's pivot at `context.column`, its entry's subtractions all made by the columns before -
/// its square root, or the factorisation's failure where it is not positive (robot.zig gives up there, keeping
/// nothing of the factor; going on changes nothing that is read).
fn newtonPivot(context: NewtonContext, lane: u32) void {
    if (lane != 0) {
        return;
    }
    const dof_count: u32 = params.counts.dof_count;
    const pivot_at: u32 = context.column * dof_count + context.column;
    const pivot_sum: f32 = newton_hessian[pivot_at];
    if (pivot_sum <= 0) {
        newton_factored[0] = 0;
    }
    newton_hessian[pivot_at] = @sqrt(pivot_sum);
}
/// The factor's column below the pivot, divided by it.
fn newtonScaleColumn(context: NewtonContext, lane: u32) void {
    const dof_count: u32 = params.counts.dof_count;
    const column: u32 = context.column;
    const pivot: f32 = newton_hessian[column * dof_count + column];
    var row_dof: u32 = column + 1 + lane;
    while (row_dof < dof_count) : (row_dof += config.workgroup) {
        const below_pivot_at: u32 = row_dof * dof_count + column;
        newton_hessian[below_pivot_at] = newton_hessian[below_pivot_at] / pivot;
    }
}
/// The trailing update: every entry (i, j), column < j <= i, less L_i,column x L_j,column - the column's subtraction
/// from each entry still to be finished, in column order.
fn newtonUpdateTrailing(context: NewtonContext, lane: u32) void {
    const dof_count: u32 = params.counts.dof_count;
    const column: u32 = context.column;
    const remaining: u32 = dof_count - column - 1;
    const pair_count: u32 = remaining * remaining;
    var pair: u32 = lane;
    while (pair < pair_count) : (pair += config.workgroup) {
        const row_dof: u32 = column + 1 + pair / remaining;
        const column_dof: u32 = column + 1 + pair % remaining;
        if (column_dof > row_dof) {
            continue;
        }
        const row_factor: f32 = newton_hessian[row_dof * dof_count + column];
        const column_factor: f32 = newton_hessian[column_dof * dof_count + column];
        const update_at: u32 = row_dof * dof_count + column_dof;
        newton_hessian[update_at] -= row_factor * column_factor;
    }
}

/// The first lane: the step, s = -g, solved through the factor - robot.zig's `choleskySolve`, forward then backward,
/// in its order - or left as the gradient's descent direction where the factorisation failed; then the measures the
/// stopping rules read, in dof order: the gradient's length, and the Newton decrement -g^T s = g^T H^-1 g.
fn newtonSolve(context: NewtonContext, lane: u32) void {
    _ = context;
    if (lane != 0) {
        return;
    }
    const dof_count: u32 = params.counts.dof_count;
    var dof: u32 = 0;
    while (dof < dof_count) : (dof += 1) {
        newton_step[dof] = -newton_gradient[dof];
    }
    if (newton_factored[0] != 0) {
        var forward: u32 = 0;
        while (forward < dof_count) : (forward += 1) {
            var sum: f32 = newton_step[forward];
            var earlier: u32 = 0;
            while (earlier < forward) : (earlier += 1) {
                sum -= newton_hessian[forward * dof_count + earlier] * newton_step[earlier];
            }
            newton_step[forward] = sum / newton_hessian[forward * dof_count + forward];
        }
        var backward: u32 = dof_count;
        while (backward > 0) {
            backward -= 1;
            var sum: f32 = newton_step[backward];
            var later: u32 = backward + 1;
            while (later < dof_count) : (later += 1) {
                sum -= newton_hessian[later * dof_count + backward] * newton_step[later];
            }
            newton_step[backward] = sum / newton_hessian[backward * dof_count + backward];
        }
    }
    var gradient_squared: f32 = 0;
    var decrement: f32 = 0;
    dof = 0;
    while (dof < dof_count) : (dof += 1) {
        gradient_squared += newton_gradient[dof] * newton_gradient[dof];
        decrement -= newton_gradient[dof] * newton_step[dof];
    }
    newton_gradient_length[0] = @sqrt(gradient_squared);
    newton_decrement[0] = decrement;
}
/// The first lane, at the start: go on unless the start already meets the gradient's rule.
fn newtonDecideStart(context: NewtonContext, lane: u32) void {
    _ = context;
    if (lane != 0) {
        return;
    }
    const tolerance: f32 = params.options.newton_tolerance;
    const is_done: bool = newton_gradient_length[0] * newton_scale[0] < tolerance;
    newton_decision[0] = @intFromBool(!is_done);
}
/// The first lane: the line along the step - M s by robot.zig's product, then in dof order the inertia's slope
/// s^T M (a - a_free) from the kept product, its half curvature 1/2 s^T M s, and |s|^2.
fn newtonLineInertia(context: NewtonContext, lane: u32) void {
    if (lane != 0) {
        return;
    }
    const product: NewtonMassProduct(.step, .mass_product) = .{ .world = context.world };
    robot.multiplyByMassMatrix(product, params.counts.dof_count);
    var inertia_slope: f32 = 0;
    var inertia_half_curvature: f32 = 0;
    var step_squared: f32 = 0;
    var dof: u32 = 0;
    while (dof < params.counts.dof_count) : (dof += 1) {
        inertia_slope += newton_step[dof] * newton_inertia_gradient[dof];
        inertia_half_curvature += 0.5 * newton_step[dof] * newton_mass_product[dof];
        step_squared += newton_step[dof] * newton_step[dof];
    }
    newton_inertia_slope[0] = inertia_slope;
    newton_inertia_half_curvature[0] = inertia_half_curvature;
    newton_step_squared[0] = step_squared;
}
/// Each row's rate along the step, J s.
fn newtonLineRates(context: NewtonContext, lane: u32) void {
    const row_count: u32 = newtonRowCount(context.world);
    var row: u32 = lane;
    while (row < row_count) : (row += config.workgroup) {
        newton_row_rate[row] = rowTimesNewtonVector(.step, context.world, row);
    }
}
/// The first lane: MuJoCo's exact line search, robot.zig's own (`robot.searchLineOver`) over the workgroup's rows - its
/// slope tolerance a fraction of the solve's, scaled by the step's length and by the inertia, never below 1e-6.
fn newtonLineSearch(context: NewtonContext, lane: u32) void {
    if (lane != 0) {
        return;
    }
    const tolerance: f32 = params.options.newton_tolerance;
    const line_tolerance: f32 = tolerance * params.options.newton_line_search_tolerance;
    const slope_tolerance_scaled: f32 = line_tolerance * @sqrt(newton_step_squared[0]) / newton_scale[0];
    const slope_tolerance: f32 = @max(slope_tolerance_scaled, 1.0e-6);
    const rows: NewtonLineRows = .{};
    const found: robot.LineSearchResult = robot.searchLineOver(
        rows,
        newtonRowCount(context.world),
        newton_inertia_slope[0],
        newton_inertia_half_curvature[0],
        slope_tolerance,
        params.options.newton_line_search_iterations,
    );
    newton_alpha[0] = found.alpha;
    newton_improvement[0] = found.improvement;
    newton_line_evaluations[0] += found.points_evaluated;
}
/// The step taken, and the kept products with it: a += alpha s, M (a - a_free) += alpha M s per dof, r += alpha J s per
/// row.
fn newtonAdvance(context: NewtonContext, lane: u32) void {
    const alpha: f32 = newton_alpha[0];
    var dof: u32 = lane;
    while (dof < params.counts.dof_count) : (dof += config.workgroup) {
        newton_acceleration[dof] += alpha * newton_step[dof];
        newton_inertia_gradient[dof] += alpha * newton_mass_product[dof];
    }
    const row_count: u32 = newtonRowCount(context.world);
    var row: u32 = lane;
    while (row < row_count) : (row += config.workgroup) {
        newton_residual[row] += alpha * newton_row_rate[row];
    }
}
/// The first lane, after a round: MuJoCo's stops, each scaled - no step; a small improvement; a short gradient; a
/// small Newton decrement.
fn newtonDecideRound(context: NewtonContext, lane: u32) void {
    _ = context;
    if (lane != 0) {
        return;
    }
    const tolerance: f32 = params.options.newton_tolerance;
    const scale: f32 = newton_scale[0];
    const improvement: f32 = newton_improvement[0];
    const has_no_step: bool = newton_alpha[0] == 0;
    const improved_little: bool = improvement > 0 and improvement * scale < tolerance;
    const gradient_is_small: bool = newton_gradient_length[0] * scale < tolerance;
    const decrement_is_small: bool = 0.5 * newton_decrement[0] * scale < tolerance;
    const is_done: bool = has_no_step or improved_little or gradient_is_small or decrement_is_small;
    newton_decision[0] = @intFromBool(!is_done);
}
/// The answer stored for the world: the accelerations - also the next step's warm start, as robot.zig's `step` saves
/// them - and the joint forces per dof, each row's force, all the last round's; the rounds and line evaluations.
fn newtonStore(context: NewtonContext, lane: u32) void {
    var dof: u32 = lane;
    while (dof < params.counts.dof_count) : (dof += config.workgroup) {
        params.layout.world_f.joint_accelerations.store(context.world, dof, newton_acceleration[dof]);
        params.layout.world_f.warmstart_accelerations.store(context.world, dof, newton_acceleration[dof]);
        params.layout.world_f.constraint_joint_forces.store(context.world, dof, newton_joint_forces[dof]);
    }
    const row_count: u32 = newtonRowCount(context.world);
    var row: u32 = lane;
    while (row < row_count) : (row += config.workgroup) {
        params.layout.efc_f.constraint_force.store(context.world, row, newton_row_force[row]);
    }
    if (lane == 0) {
        params.layout.world_u.newton_iterations.store(context.world, 0, context.iterations);
        params.layout.world_u.newton_line_evaluations.store(context.world, 0, newton_line_evaluations[0]);
    }
}

/// The first lane: whether the world has any row - the workgroup's first decision, read by all.
fn newtonDecideRows(context: NewtonContext, lane: u32) void {
    if (lane != 0) {
        return;
    }
    newton_decision[0] = @intFromBool(newtonRowCount(context.world) > 0);
}
/// A WORLD WITH NO ROWS: robot.zig's answer at once (`solveConstraints` with no rows) - the free acceleration, saved as
/// the next step's warm start too, no joint force, no round, no line evaluated - without the Hessian of a problem that
/// has no constraint in it.
fn newtonStoreFree(context: NewtonContext, lane: u32) void {
    var dof: u32 = lane;
    while (dof < params.counts.dof_count) : (dof += config.workgroup) {
        const free_acceleration: f32 = params.layout.world_f.smooth_joint_accelerations.load(context.world, dof);
        params.layout.world_f.joint_accelerations.store(context.world, dof, free_acceleration);
        params.layout.world_f.warmstart_accelerations.store(context.world, dof, free_acceleration);
        params.layout.world_f.constraint_joint_forces.store(context.world, dof, 0);
    }
    if (lane == 0) {
        params.layout.world_u.newton_iterations.store(context.world, 0, 0);
        params.layout.world_u.newton_line_evaluations.store(context.world, 0, 0);
    }
}

/// One round's derivatives at the current accelerations (robot.zig's `newtonDerivatives`): the rows' forces, the
/// gradient, the Hessian and its factor, the step and its measures.
inline fn newtonDerivatives(lane: u32, context: NewtonContext) void {
    runPhase(lane, newtonRowForces, context);
    runPhase(lane, newtonGradient, context);
    runPhase(lane, newtonHessian, context);
    runPhase(lane, newtonFactorStart, context);
    var column_context: NewtonContext = context;
    var column: u32 = 0;
    while (column < params.counts.dof_count) : (column += 1) {
        column_context.column = column;
        runPhase(lane, newtonPivot, column_context);
        runPhase(lane, newtonScaleColumn, column_context);
        runPhase(lane, newtonUpdateTrailing, column_context);
    }
    runPhase(lane, newtonSolve, context);
}

// ------------------------------------------------------------------------------------------------------------------
// NEWTON: each world's constrained acceleration, MuJoCo's Newton solver with its line search
// ------------------------------------------------------------------------------------------------------------------

/// NEWTON, ONE WORKGROUP PER WORLD, every round in this one dispatch - robot.zig's `solveNewton` from a cold start,
/// phase by phase (the section's comment above).
pub fn newton_solve(invocation: u32) void {
    const workgroup_size: u32 = config.workgroup;
    const world: u32 = invocation / workgroup_size;
    const lane: u32 = invocation % workgroup_size;
    if (!k.is_gpu and lane != 0) {
        return;
    }
    var context: NewtonContext = .{ .world = world };
    runPhase(lane, newtonDecideRows, context);
    // A BRANCH, NOT AN EARLY RETURN: the decision is uniform - every lane reads it through `workgroupUniformLoad` -
    // but a barrier after a `return` is refused by the WGSL translator (`spv2wgsl`), which cannot see that.
    const has_rows: bool = k.workgroupUniformLoad(u32, 1, newton_decision, 0) != 0;
    if (has_rows) {
        runPhase(lane, newtonStartRows, context);
        runPhase(lane, newtonChooseStart, context);
        runPhase(lane, newtonStartResiduals, context);
        runPhase(lane, newtonStartInertia, context);
        newtonDerivatives(lane, context);
        runPhase(lane, newtonDecideStart, context);
        var iteration: u32 = 0;
        while (iteration < params.options.newton_max_iterations) {
            if (k.workgroupUniformLoad(u32, 1, newton_decision, 0) == 0) {
                break;
            }
            runPhase(lane, newtonLineInertia, context);
            runPhase(lane, newtonLineRates, context);
            runPhase(lane, newtonLineSearch, context);
            runPhase(lane, newtonAdvance, context);
            iteration += 1;
            newtonDerivatives(lane, context);
            runPhase(lane, newtonDecideRound, context);
        }
        context.iterations = iteration;
        runPhase(lane, newtonStore, context);
    } else {
        runPhase(lane, newtonStoreFree, context);
    }
}

// -- THE VELOCITY UPDATE --
//
// A step carries each joint's velocity over the timestep, by the acceleration: `velocity += dt * acceleration` (Euler,
// as robot.zig's `dampedVelocityStep`). With no constraint forces, the acceleration is the smooth one, copied into
// `joint_accelerations` first.
//
// A joint's DAMPING makes that explicit update fragile: a damper stiff enough, against a light body, makes `dt *
// acceleration` overshoot and the velocity grow instead of decay. So a model with damping takes the damper implicitly,
// at the END of the step: the velocity change `dv` solves `(M + dt D) dv = dt (M a)`, with D the dampers on the
// diagonal - unconditionally stable, however stiff. In robot.zig's four steps, one invocation per world:
//
//     the right-hand side    dt (M a)          the product (`robot.multiplyByMassMatrix`), then scaled by dt
//     the damped matrix      M + dt D          M copied into a factor of its own, dt x damping added to each damped
//                                              dof's diagonal, joint by joint
//     the factor             L^T D L           `robot.factorLdlInPlace`, the same factorisation as M's
//     the solve              dv                `robot.solveLdl`, in place over the right-hand side
//
// Then each dof adds its change - or `dt * acceleration`, for a model without damping - one invocation per world and
// dof.
//
// The damped factor has arrays of its own, so M's factor stays as it is for anything that solves with M afterwards.
//
// Read: smooth_joint_accelerations, mass_matrix, and the model's damping. Written: joint_accelerations,
// velocity_changes, damped_mass_factor and its inverse diagonal, joint_velocities.

// ------------------------------------------------------------------------------------------------------------------
// INTEGRATION: the velocities, the activations and the positions of the next step
// ------------------------------------------------------------------------------------------------------------------

/// EACH WORLD'S DAMPED VELOCITY CHANGE, one invocation per world - robot.zig's `dampedVelocityStep` for a model with
/// damping, in its four steps (the section's introduction); a model without damping has nothing to do here.
pub fn damped_velocity_changes(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    if (tables.has_dof_damping.load(0) == 0) {
        return;
    }
    const timestep: f32 = params.options.timestep;
    const dof_count: u32 = params.counts.dof_count;
    // The right-hand side: dt (M a).
    const product: WorldMassProduct = .{ .world = world };
    robot.multiplyByMassMatrix(product, dof_count);
    var scaled_dof: u32 = 0;
    while (scaled_dof < dof_count) : (scaled_dof += 1) {
        const scaled: f32 = state.velocity_changes.load(world, scaled_dof) * timestep;
        state.velocity_changes.store(world, scaled_dof, scaled);
    }
    // The damped matrix: M, with dt x damping on each damped joint's dofs' diagonals.
    var entry: u32 = 0;
    while (entry < params.counts.mass_entry_count) : (entry += 1) {
        state.damped_mass_factor.store(world, entry, state.mass_matrix.load(world, entry));
    }
    var joint: u32 = 0;
    while (joint < params.counts.joint_count) : (joint += 1) {
        const damping: f32 = constants.joint_damping.load(joint);
        if (damping == 0) {
            continue;
        }
        const first_dof: u32 = tables.joint_first_dof.load(joint);
        const joint_type: robot.JointType = typeOfJoint(joint);
        const joint_dof_count: u32 = joint_type.dofCount();
        var offset: u32 = 0;
        while (offset < joint_dof_count) : (offset += 1) {
            const damped_dof: u32 = first_dof + offset;
            const row_start: u32 = tables.mass_row_start.load(damped_dof);
            const diagonal: u32 = row_start + tables.mass_row_entry_count.load(damped_dof) - 1;
            const damped: f32 = state.damped_mass_factor.load(world, diagonal) + timestep * damping;
            state.damped_mass_factor.store(world, diagonal, damped);
        }
    }
    // The factor, and the solve in place over the right-hand side.
    const storage: VelocityChangeSolve = .{ .world = world };
    robot.factorLdlInPlace(storage, dof_count);
    robot.solveLdl(storage, dof_count);
}

/// EACH DOF'S NEXT VELOCITY, one invocation per world and dof: its velocity plus the damped change, or - a model
/// without damping - plus `dt * acceleration`, as robot.zig adds them.
pub fn next_velocities(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const velocity: f32 = state.joint_velocities.load(world, dof);
    const has_damping: bool = tables.has_dof_damping.load(0) != 0;
    if (has_damping) {
        // The change solved for the whole world, the damper taken implicitly (`damped_velocity_changes`).
        const change: f32 = state.velocity_changes.load(world, dof);
        state.joint_velocities.store(world, dof, velocity + change);
        return;
    }
    // Without damping, the explicit update.
    const timestep: f32 = params.options.timestep;
    const acceleration: f32 = state.joint_accelerations.load(world, dof);
    state.joint_velocities.store(world, dof, velocity + timestep * acceleration);
}

// -- THE ADVANCE --
//
// The rest of robot.zig's Euler step (`advanceEuler`), each piece independent of the others' elements:
//
//     the activations     each actuator's internal state: activation += dt x its rate (written by actuation)
//     the bound           every joint velocity kept finite and within the model's bound - a velocity that is not a
//                         number becomes zero, any other is clamped - before it can carry a bad value into the
//                         positions
//     the positions       each joint's coordinates carried over the step by its new velocity: a slide or a hinge adds
//                         dt x its rate; a free joint adds to its position, then turns its quaternion by its angular
//                         velocity (`robot.rotateQuatByAngularVel`); a ball joint turns its quaternion; and every
//                         quaternion is normalised again, so rounding never lets it drift from unit length
//
// robot.zig integrates the activations before the velocity update; neither reads the other, so the order changes no
// bit. One invocation per world and activation, per world and dof, and per world and joint.
//
// Read: activation_rates, joint_velocities, and the model's velocity bound. Written: activations, joint_velocities,
// joint_positions.

/// EACH ACTIVATION, one invocation per world and activation: carried over the step by its rate, as robot.zig's
/// `advanceEuler` does (MJW: `_next_activation`).
pub fn next_activations(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.activation_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const activation: u32 = handled.element;
    const state: WorldStateLayout = params.layout.world_f;
    const timestep: f32 = params.options.timestep;
    const value: f32 = state.activations.load(world, activation);
    const rate: f32 = state.activation_rates.load(world, activation);
    state.activations.store(world, activation, value + timestep * rate);
}

/// EACH DOF'S VELOCITY, BOUNDED, one invocation per world and dof - robot.zig's `boundVelocity`: a velocity that is not
/// a finite number becomes zero, any other is clamped to the model's bound.
pub fn bound_velocities(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.dof_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const dof: u32 = handled.element;
    const state: WorldStateLayout = params.layout.world_f;
    const velocity: f32 = state.joint_velocities.load(world, dof);
    if (!isFinite(velocity)) {
        state.joint_velocities.store(world, dof, 0);
        return;
    }
    const bound: f32 = params.options.max_velocity;
    state.joint_velocities.store(world, dof, clamp(velocity, -bound, bound));
}

/// The quaternion at coordinates `first_coordinate`..+4 of world `world` turned by the angular velocity at dofs
/// `first_dof`..+3 over `timestep` (`robot.rotateQuatByAngularVel`), then normalised (`robot.normalizeQuat`) - a free
/// or a ball joint's orientation, carried over the step.
fn turnQuaternion(world: u32, first_coordinate: u32, first_dof: u32, timestep: f32) void {
    const state: WorldStateLayout = params.layout.world_f;
    const angular_velocity: Vec = state.joint_velocities.loadVector3(world, first_dof);
    const quaternion: robot.Quat = state.joint_positions.loadQuaternion(world, first_coordinate);
    const turned: robot.Quat = robot.rotateQuatByAngularVel(quaternion, angular_velocity, timestep);
    const normalised: robot.Quat = robot.normalizeQuat(turned);
    state.joint_positions.storeQuaternion(world, first_coordinate, normalised);
}

/// EACH JOINT'S COORDINATES, one invocation per world and joint - robot.zig's `integratePos` for the joint, then its
/// `normalizeQuats` for the joint's quaternion, which depends on nothing but that quaternion (MJW: `_next_position`).
pub fn next_positions(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.joint_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const joint: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const state: WorldStateLayout = params.layout.world_f;
    const timestep: f32 = params.options.timestep;
    const first_coordinate: u32 = tables.joint_first_coordinate.load(joint);
    const first_dof: u32 = tables.joint_first_dof.load(joint);
    const joint_type: robot.JointType = typeOfJoint(joint);
    switch (joint_type) {
        .slide, .hinge => {
            const position: f32 = state.joint_positions.load(world, first_coordinate);
            const rate: f32 = state.joint_velocities.load(world, first_dof);
            state.joint_positions.store(world, first_coordinate, position + timestep * rate);
        },
        .free => {
            // The position, carried by the linear velocity - each lane rounded as robot.zig rounds each coordinate.
            const position: Vec = state.joint_positions.loadVector3(world, first_coordinate);
            const linear_velocity: Vec = state.joint_velocities.loadVector3(world, first_dof);
            const moved: Vec = position + splat(timestep) * linear_velocity;
            state.joint_positions.storeVector3(world, first_coordinate, moved);
            turnQuaternion(world, first_coordinate + 3, first_dof + 3, timestep);
        },
        .ball => {
            turnQuaternion(world, first_coordinate, first_dof, timestep);
        },
    }
}

/// THE STEP PROGRAM and its vocabulary, from `robotgpu_program.zig` - a file of its own so the build script can read
/// it too (that file says why).
pub const Invocations = program.Invocations;
pub const Dispatch = program.Dispatch;
pub const step_program = program.step_program;
pub const constraint_program = program.constraint_program;
pub const before_step_program = program.before_step_program;
pub const after_step_program = program.after_step_program;
pub const observe_program = program.observe_program;
pub const decision_start_program = program.decision_start_program;
pub const judge_program = program.judge_program;
pub const reset_program = program.reset_program;
pub const policy_inputs_program = program.policy_inputs_program;
pub const give_program = program.give_program;

// ------------------------------------------------------------------------------------------------------------------
// THE TRACKING TASK, THE OBSERVATION AND THE JUDGEMENT - the decision program's kernels around the step, and after it
// filter_actions, reference_targets    before each physics step (before_step_program): the applied action moved
//                                      toward the policy's, and the servo's targets from the clip and the action
// advance_frames                       after each physics step (after_step_program): each world's clip frame
// observe_character, observe_reference once a decision (observe_program, after the step's derived quantities
//                                      are brought forward): each world's observation, the character's half
//                                      and the reference's
// body_lowest_points, judge_tracking,  once a decision, after the observation (judge_program): each body's lowest
// judge_rewards                        point, each world's tracking error and its rewards, by robot.zig's judgement
// ------------------------------------------------------------------------------------------------------------------

/// A vector's three numbers into world `world`'s observation from number `at`.
fn storeObservationVector(world: u32, at: u32, v: Vec) void {
    const observations: WorldArray(.world_f, .observations) = params.layout.world_f.observations;
    observations.store(world, at, v[0]);
    observations.store(world, at + 1, v[1]);
    observations.store(world, at + 2, v[2]);
}

/// THE CHARACTER's HALF OF EACH WORLD's OBSERVATION, one invocation per world, once a decision - robot_track's
/// `local` of `stateOf`, the first half of what `observe` writes. Every body but the world, its features by
/// `robot.localBody` - its position less the root's, its rotation as two axes, its frame origin's velocity
/// (`robot.motionPointVelocity`) and its angular velocity, all turned into the root's frame, and its height - laid
/// out by kind as `local` lays them, then the world's up seen from the root. Reads the derived quantities the
/// observation program brings forward first: the bodies' poses, the subtrees' centres of mass, the bodies' spatial
/// velocities.
pub fn observe_character(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const state: WorldStateLayout = params.layout.world_f;
    const tables: ModelTablesLayout = params.layout.model_u;
    const root: u32 = params.counts.root_body;
    const to_local: robot.Quat = conjugate(state.body_orientations.loadVec(world, root));
    const origin: Vec = state.body_positions.loadVec(world, root);
    // `local`'s layout: every body's position, then every body's rotation, velocity, angular velocity, height; the up.
    const character_bodies: u32 = params.counts.body_count - 1;
    const rotations_at: u32 = 3 * character_bodies;
    const velocities_at: u32 = 9 * character_bodies;
    const angular_at: u32 = 12 * character_bodies;
    const heights_at: u32 = 15 * character_bodies;
    const up_at: u32 = 16 * character_bodies;
    var body: u32 = 1;
    while (body < params.counts.body_count) : (body += 1) {
        const position: Vec = state.body_positions.loadVec(world, body);
        const motion: robot.Motion = state.body_velocities.loadMotion(world, body);
        const subtree_origin: Vec = state.subtree_centres_of_mass.loadVec(world, tables.body_root.load(body));
        const features: robot.LocalBody = robot.localBody(
            to_local,
            origin,
            position,
            state.body_orientations.loadVec(world, body),
            robot.motionPointVelocity(motion, subtree_origin, position),
            motion.ang,
        );
        const index: u32 = body - 1;
        storeObservationVector(world, 3 * index, features.position);
        var axis_number: u32 = 0;
        while (axis_number < 6) : (axis_number += 1) {
            state.observations.store(world, rotations_at + 6 * index + axis_number, features.rotation[axis_number]);
        }
        storeObservationVector(world, velocities_at + 3 * index, features.velocity);
        storeObservationVector(world, angular_at + 3 * index, features.angular);
        state.observations.store(world, heights_at + index, features.height);
    }
    // The world's up, in the root's frame: what tells the policy how the character is tilted.
    storeObservationVector(world, up_at, rotate(to_local, vec(0, 0, 1)));
}

/// THE ROW OF WORLD `world`'s CLIP FRAME among all the clips' frames - its frame held at its clip's last, as
/// `referenceStateInto` holds it: the row every reference table is read at (`observe_reference`, the judgement).
fn referenceFrameRow(world: u32) u32 {
    const tables: ModelTablesLayout = params.layout.model_u;
    const integers: WorldIntegersLayout = params.layout.world_u;
    const clip: u32 = integers.world_clip.load(world, 0);
    const last_frame: u32 = tables.clip_frame_count.load(clip) - 1;
    const frame: u32 = @min(integers.world_frame.load(world, 0), last_frame);
    return tables.clip_first_frame.load(clip) + frame;
}

/// THE REFERENCE's HALF OF EACH WORLD's OBSERVATION, one invocation per world, once a decision - what robot_track's
/// `observe` writes second: the reference's state in the root's frame at the world's frame, its row computed once per
/// clip on the host (`ClipPoses.reference_features`) and copied after the character's half - the frame clamped to the
/// clip's last, as `referenceStateInto` clamps it.
pub fn observe_reference(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    // A simulator given no reference features keeps no table: its worlds' second half stays as it is, zero.
    if (params.counts.reference_feature_frames == 0) {
        return;
    }
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const row: u32 = referenceFrameRow(world);
    const row_size: u32 = @intCast(robot.localSize(params.counts.body_count));
    const first_feature: u32 = row * row_size;
    // The character's half comes first; the reference's follows it.
    const half_at: u32 = row_size;
    var number: u32 = 0;
    while (number < row_size) : (number += 1) {
        const feature: f32 = constants.clip_reference_features.load(first_feature + number);
        state.observations.store(world, half_at + number, feature);
    }
}

/// THE POLICY's INPUTS for one world - SuperTrack's two feature vectors as the learner reads them
/// (`robot_track_resident.supertrackFeaturesInto`): the GOAL, the reference one frame ahead of the world's frame (held
/// at the clip's last frame, as the fleet holds it), read from the clips' precomputed reference features; then the
/// STATE, the observation's first half - the simulated bodies in the root's frame. Each feature becomes
/// `(x - mean) / spread` with the normaliser's tables. Run after the observation program.
pub fn policy_inputs(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    if (params.counts.reference_feature_frames == 0) {
        return;
    }
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const counters: WorldIntegersLayout = params.layout.world_u;
    const tables: ModelTablesLayout = params.layout.model_u;
    const feature_count: u32 = @intCast(robot.localSize(params.counts.body_count));
    const clip: u32 = counters.world_clip.load(world, 0);
    const frame: u32 = counters.world_frame.load(world, 0);
    const last_frame: u32 = tables.clip_frame_count.load(clip) - 1;
    const goal_frame: u32 = @min(frame + 1, last_frame);
    const goal_row: u32 = tables.clip_first_frame.load(clip) + goal_frame;
    const goal_first: u32 = goal_row * feature_count;
    var feature: u32 = 0;
    while (feature < feature_count) : (feature += 1) {
        const mean: f32 = constants.feature_means.load(feature);
        const spread: f32 = constants.feature_spreads.load(feature);
        const goal_raw: f32 = constants.clip_reference_features.load(goal_first + feature);
        state.policy_inputs.store(world, feature, (goal_raw - mean) / spread);
        const state_raw: f32 = state.observations.load(world, feature);
        state.policy_inputs.store(world, feature_count + feature, (state_raw - mean) / spread);
    }
}

/// EACH BODY's LOWEST POINT, one invocation per world and body, at a decision's end - `robot.bodyLowestPoints`: the
/// lowest of its geoms' lowest points, each geom placed on its body as robot.zig places it (`geomLowestPoint`) and
/// measured by robot.zig's own functions for its shape. The world, and a body with no geom, keep
/// `robot.no_shape_height`. (The device takes no hulls, as its floor contacts take none.)
pub fn body_lowest_points(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.body_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const body: u32 = handled.element;
    const state: WorldStateLayout = params.layout.world_f;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    var lowest: f32 = robot.no_shape_height;
    if (body != 0) {
        const body_position: Vec = state.body_positions.loadVec(world, body);
        const body_orientation: Vec = state.body_orientations.loadVec(world, body);
        var geom: u32 = 0;
        while (geom < params.counts.geom_count) : (geom += 1) {
            if (tables.geom_body.load(geom) != body) {
                continue;
            }
            const rotation: Vec = qmul(body_orientation, constants.geom_local_rotation.loadVec(geom));
            const center: Vec = body_position + rotate(body_orientation, constants.geom_local_position.loadVec(geom));
            const size: Vec = constants.geom_size.loadVec(geom);
            const geom_type: GeomType = typeOfGeom(geom);
            const geom_lowest: f32 = switch (geom_type) {
                .sphere => robot.sphereLowestPoint(center, size[0]),
                .capsule, .cylinder => robot.segmentLowestPoint(center, rotation, size[0], size[1]),
                .box => robot.boxLowestPoint(center, rotation, size),
                // robot.zig makes no plane, height field or ellipsoid; a hull - MuJoCo's mesh - has no points packed
                // on the device, which leaves it out, as its floor contacts leave it out.
                .plane, .height_field, .ellipsoid, .mesh => robot.no_shape_height,
            };
            lowest = @min(lowest, geom_lowest);
        }
    }
    state.body_lowest_points.store(world, body, lowest);
}

/// THE BODIES THE JUDGEMENT READS on the device (`robot.trackingErrorOver`'s storage; robot.zig's `BodySlices` on
/// the CPU) - one type for both of its sides, as the judgement takes one, and a field saying which:
///
///     a world's        each body's pose, the velocity of its frame origin (`robot.motionPointVelocity`, as
///                      `stateOf` takes it), its angular velocity and its lowest point - the derived quantities
///                      the decision's end brings forward
///     a reference's    a row of `clip_reference_bodies`, each body `robot.reference_body_numbers` numbers
///                      (position, rotation, velocity, angular velocity, lowest point)
const DeviceBodies = struct {
    source: Source,
    /// The world, for a world's bodies.
    world: u32 = 0,
    /// The row's first number in `clip_reference_bodies`, for a reference's.
    first_number: u32 = 0,

    const Source = enum { world, reference };

    /// One of the reference's five vectors for `body`: 0 position, 1 rotation, 2 velocity, 3 angular, 4 lowest.
    fn referenceVector(bodies: DeviceBodies, body: usize, vector: u32) Vec {
        const per_body: u32 = @intCast(robot.reference_body_numbers);
        const at: u32 = bodies.first_number + @as(u32, @intCast(body)) * per_body + 4 * vector;
        const table: ModelTable(.model_f, .clip_reference_body_numbers) = params.layout.model_f.clip_reference_bodies;
        // All four numbers: a rotation's w is the fourth (`vec` would set it to zero).
        const numbers: Vec = .{ table.load(at), table.load(at + 1), table.load(at + 2), table.load(at + 3) };
        return numbers;
    }

    pub fn count(bodies: DeviceBodies) usize {
        _ = bodies;
        return params.counts.body_count;
    }

    pub fn position(bodies: DeviceBodies, body: usize) Vec {
        if (bodies.source == .reference) {
            return bodies.referenceVector(body, 0);
        }
        return params.layout.world_f.body_positions.loadVec(bodies.world, @intCast(body));
    }

    pub fn rotation(bodies: DeviceBodies, body: usize) robot.Quat {
        if (bodies.source == .reference) {
            return bodies.referenceVector(body, 1);
        }
        return params.layout.world_f.body_orientations.loadVec(bodies.world, @intCast(body));
    }

    pub fn velocity(bodies: DeviceBodies, body: usize) Vec {
        if (bodies.source == .reference) {
            return bodies.referenceVector(body, 2);
        }
        const state: WorldStateLayout = params.layout.world_f;
        const index: u32 = @intCast(body);
        const motion: robot.Motion = state.body_velocities.loadMotion(bodies.world, index);
        const root_of_body: u32 = params.layout.model_u.body_root.load(index);
        const origin: Vec = state.subtree_centres_of_mass.loadVec(bodies.world, root_of_body);
        return robot.motionPointVelocity(motion, origin, bodies.position(body));
    }

    pub fn angular(bodies: DeviceBodies, body: usize) Vec {
        if (bodies.source == .reference) {
            return bodies.referenceVector(body, 3);
        }
        return params.layout.world_f.body_velocities.loadMotion(bodies.world, @intCast(body)).ang;
    }

    pub fn lowest(bodies: DeviceBodies, body: usize) f32 {
        if (bodies.source == .reference) {
            return bodies.referenceVector(body, 4)[0];
        }
        return params.layout.world_f.body_lowest_points.load(bodies.world, @intCast(body));
    }
};

/// EACH WORLD's TRACKING ERROR, one invocation per world, at a decision's end - what the CPU fleet's `step` measures
/// after its physics (`trackingErrorWithHead`): the world against the reference at its clip frame (held at the
/// clip's last), by robot.zig's own `trackingErrorOver` over the device's storages. Its terms into `tracking_errors`.
pub fn judge_tracking(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    // A simulator given no reference tables judges nothing.
    if (params.counts.reference_feature_frames == 0) {
        return;
    }
    const row: u32 = referenceFrameRow(world);
    const frame_numbers: u32 = params.counts.body_count * @as(u32, @intCast(robot.reference_body_numbers));
    const sim: DeviceBodies = .{ .source = .world, .world = world };
    const reference: DeviceBodies = .{ .source = .reference, .first_number = row * frame_numbers };
    const head_body: u32 = params.options.head_body;
    const head: ?usize = if (head_body == no_head_body) null else head_body;
    const root: usize = params.counts.root_body;
    const err: robot.TrackingError = robot.trackingErrorOver(DeviceBodies, sim, reference, root, head);
    const errors: WorldArray(.world_f, .tracking_error_terms) = params.layout.world_f.tracking_errors;
    inline for (@typeInfo(robot.TrackingError).@"struct".field_names, 0..) |field_name, term| {
        errors.store(world, term, @field(err, field_name));
    }
}

/// The judgement's weights as `writeJudgementWeights` wrote them, read on the device.
fn loadJudgementWeights() JudgementWeights {
    const table: ModelTable(.model_f, .judgement_numbers) = params.layout.model_f.judgement_weights;
    var reward_weights: robot.RewardWeights = .{};
    inline for (@typeInfo(robot.RewardWeights).@"struct".field_names, 0..) |field_name, index| {
        @field(reward_weights, field_name) = table.load(@intCast(index));
    }
    const scales_at: u32 = f32FieldCount(robot.RewardWeights);
    var scales: robot.SuperMimicScales = .{};
    inline for (@typeInfo(robot.SuperMimicScales).@"struct".field_names, 0..) |field_name, index| {
        @field(scales, field_name) = table.load(scales_at + @as(u32, @intCast(index)));
    }
    const termination_at: u32 = scales_at + f32FieldCount(robot.SuperMimicScales);
    var termination: robot.Termination = .{};
    const termination_info = @typeInfo(robot.Termination).@"struct";
    comptime var limit: u32 = 0;
    inline for (termination_info.field_names, termination_info.field_types) |field_name, field_type| {
        if (field_type == f32) {
            @field(termination, field_name) = table.load(termination_at + limit);
            limit += 1;
        }
    }
    const weights: JudgementWeights = .{
        .reward_weights = reward_weights,
        .scales = scales,
        .termination = termination,
    };
    return weights;
}

/// THE NUMBERS THAT ARE THE ACTION (the fleet's `actionWidth`): the joints' offsets, then each limb's stiffness only
/// with the task's limb stiffness on. Every world keeps room for the limbs' numbers either way (`counts.action_count`);
/// what acts on the action or judges it - the exploration, the action rate - reads only these, so a number that is not
/// part of the action can neither be explored nor priced.
fn actionWidth() u32 {
    const offset_count: u32 = params.counts.action_count - params.counts.limb_count;
    const limbs_act: bool = params.options.limb_stiffness == .enabled;
    return if (limbs_act) params.counts.action_count else offset_count;
}

/// EACH WORLD's REWARDS, one invocation per world, after its tracking error - what the CPU fleet's `step` earns after
/// its physics: the tracker's reward (`robot.reward` of the tracking error `judge_tracking` stored) and SuperMimic's
/// tracking reward (`robot.superMimicTrackingOver` over the same storages) - their weights from `judgement_weights`.
pub fn judge_rewards(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    if (params.counts.reference_feature_frames == 0) {
        return;
    }
    const state: WorldStateLayout = params.layout.world_f;
    var err: robot.TrackingError = undefined;
    inline for (@typeInfo(robot.TrackingError).@"struct".field_names, 0..) |field_name, term| {
        @field(err, field_name) = state.tracking_errors.load(world, term);
    }
    const judgement_weights: JudgementWeights = loadJudgementWeights();
    state.rewards.store(world, 0, robot.reward(err, judgement_weights.reward_weights));
    // The termination rule's verdict on this error, before the episode's grace and aftermath weigh it.
    const rule_fires: bool = robot.terminated(err, judgement_weights.termination);
    state.termination_rule.store(world, 0, if (rule_fires) 1.0 else 0.0);
    // SuperMimic's, the world against the same reference row the tracking error read.
    const row: u32 = referenceFrameRow(world);
    const frame_numbers: u32 = params.counts.body_count * @as(u32, @intCast(robot.reference_body_numbers));
    const sim: DeviceBodies = .{ .source = .world, .world = world };
    const reference: DeviceBodies = .{ .source = .reference, .first_number = row * frame_numbers };
    const scales: robot.SuperMimicScales = judgement_weights.scales;
    const root: usize = params.counts.root_body;
    const tracking: robot.SuperMimicTracking = robot.superMimicTrackingOver(DeviceBodies, sim, reference, root, scales);
    state.super_mimic_tracking.store(world, 0, tracking.total);
    // SuperMimic's penalties, as the fleet's `superMimicReward` adds them. The action rate: each number's change since
    // the previous decision, squared and summed in order; this decision's action then the previous - over the numbers
    // that are the action (`actionWidth`), as the fleet's action holds them.
    var action_rate: f32 = 0;
    const width: u32 = actionWidth();
    var number: u32 = 0;
    while (number < width) : (number += 1) {
        const now: f32 = state.actions.load(world, number);
        const before: f32 = state.previous_actions.load(world, number);
        action_rate += robot.actionChangeSquared(now, before);
        state.previous_actions.store(world, number, now);
    }
    // The joints past their limits, in joint order: a boxed ball by its box, a ranged hinge or slide by its soft band.
    const joint_tables: ModelTablesLayout = params.layout.model_u;
    const model_constants: ModelConstantsLayout = params.layout.model_f;
    const boxes: ModelTable(.model_f, .joint_box_numbers) = model_constants.ball_boxes;
    var joint_excess: f32 = 0;
    var joint: u32 = 0;
    while (joint < params.counts.joint_count) : (joint += 1) {
        // The joint's type from its packed word (`jointTypeOf` reads the word, not the joint's index).
        const joint_type: robot.JointType = typeOfJoint(joint);
        const first: u32 = joint_tables.joint_first_coordinate.load(joint);
        const positions: WorldArray(.world_f, .coordinates) = state.joint_positions;
        const coordinates: robot.JointCoordinates = loadJointCoordinates(positions, world, joint_type, first);
        if (joint_type == .ball and boxes.load(12 * joint + 3) == 1.0) {
            const box: robot.RotationBox = loadBallBox(boxes, joint);
            joint_excess += robot.ballBoxExcess(coordinates.ballOrientation(), box);
            continue;
        }
        if (joint_tables.jnt_limited.load(joint) == 0) {
            continue;
        }
        const range: [2]f32 = model_constants.joint_range.loadPair(joint);
        joint_excess += robot.jointLimitExcess(coordinates, joint_type, range, scales.soft_limit_share);
    }
    // The effort's cost through the decision (`robot.effortCost`).
    const sums: robot.EffortSums = .{
        .energy = state.effort_energy.load(world, 0),
        .torque_squares = state.effort_torque_squares.load(world, 0),
    };
    const actuated: f32 = @floatFromInt(params.counts.dof_count - servoRootDofCount());
    const physics_steps: f32 = @floatFromInt(params.options.decision_physics_steps);
    const mass: f32 = model_constants.character_mass.load(0);
    const effort_cost: f32 = robot.effortCost(sums, scales, actuated, physics_steps, mass);
    const action_cost: f32 = scales.action_rate_weight * action_rate;
    const penalties: f32 = action_cost + scales.joint_limit_weight * joint_excess + effort_cost;
    const super_mimic_reward: f32 = tracking.total + penalties;
    state.super_mimic_rewards.store(world, 0, super_mimic_reward);
    // The curriculum's episode return: this decision's reward, discounted from the episode's start (the fleet's step).
    if (params.options.curriculum == .enabled) {
        const power: f32 = state.episode_discount_powers.load(world, 0);
        const discounted: f32 = state.episode_discounted_returns.load(world, 0);
        state.episode_discounted_returns.store(world, 0, discounted + power * super_mimic_reward);
        state.episode_discount_powers.store(world, 0, power * params.options.curriculum_discount);
        const reward_sum: f32 = state.episode_reward_sums.load(world, 0);
        state.episode_reward_sums.store(world, 0, reward_sum + super_mimic_reward);
        const decisions: u32 = params.layout.world_u.episode_decisions.load(world, 0);
        params.layout.world_u.episode_decisions.store(world, 0, decisions + 1);
    }
}

/// A START FRAME BY SUPERMIMIC's CURRICULUM - the fleet's `drawStartFrame`, line for line: a bin by one uniform draw
/// against the clip's running sums (the first bin whose sum exceeds it, else the last), then a frame uniform within the
/// bin by another, held inside the frames that leave a decision before the clip's end.
fn curriculumStartFrame(world: u32, episode: u32, clip: u32, last_start: u32) u32 {
    const options: StepOptions = params.options;
    const tables: ModelTablesLayout = params.layout.model_u;
    const first_bin: u32 = tables.clip_first_bin.load(clip);
    const bin_count: u32 = tables.clip_bin_count.load(clip);
    const bin_draw: f32 = robot.drawUniform(options.draw_seed, world, episode, .start_frame, 1);
    const sums: ModelTable(.model_f, .curriculum_bins) = params.layout.model_f.bin_running_sums;
    var bin: u32 = 0;
    const chosen: u32 = while (bin < bin_count) : (bin += 1) {
        if (bin_draw < sums.load(first_bin + bin)) {
            break bin;
        }
    } else bin_count - 1;
    const bin_frames: u32 = tables.clip_bin_frames.load(clip);
    const frame_count: u32 = tables.clip_frame_count.load(clip);
    const bin_first: u32 = chosen * bin_frames;
    const bin_end: u32 = @min(bin_first + bin_frames, frame_count);
    // The bin's frames within the clip, at least one - written out: SPIR-V has no saturating subtraction (`-|`).
    const frames_in_bin: u32 = if (bin_end > bin_first) bin_end - bin_first else 0;
    const bin_width: u32 = @max(frames_in_bin, 1);
    const within: u32 = robot.drawBelow(options.draw_seed, world, episode, .start_frame, 2, bin_width);
    return clamp(bin_first + within, 1, last_start);
}

/// A WORLD WHOSE EPISODE ENDED BEGINS ANOTHER - the CPU fleet's `restart` and its `startEpisodeAt`, up to the pose: its
/// episode number advanced (the counter of every draw its start makes), its clip chosen and its start frame drawn as
/// the fleet draws them, and what a start clears, cleared. The start frame is uniform over the frames that leave a
/// whole decision before the clip's end (the fleet's `lastStartFrame`). Not cleared, as the fleet does not: the steps
/// since a loss. A world still in its episode is left alone.
pub fn begin_reset(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const counters: WorldIntegersLayout = params.layout.world_u;
    const ended: bool = counters.episode_flags.load(world, 0) & episodeFlagBit(.finished) != 0;
    if (!ended) {
        return;
    }
    const options: StepOptions = params.options;
    const episode: u32 = counters.episode_numbers.load(world, 0) +% 1;
    counters.episode_numbers.store(world, 0, episode);
    const clip_count: u32 = params.counts.clip_count;
    const clip: u32 = switch (options.clip_assignment) {
        .random => robot.drawBelow(options.draw_seed, world, episode, .start_clip, 0, clip_count),
        .by_character => world % clip_count,
    };
    const frame_count: u32 = params.layout.model_u.clip_frame_count.load(clip);
    const last_start: u32 = frame_count - 1 - options.decision_physics_steps;
    const tables: ModelTablesLayout = params.layout.model_u;
    const bin_count: u32 = tables.clip_bin_count.load(clip);
    const by_curriculum: bool = options.curriculum == .enabled and bin_count > 0;
    const frame: u32 = if (by_curriculum)
        curriculumStartFrame(world, episode, clip, last_start)
    else
        1 + robot.drawBelow(options.draw_seed, world, episode, .start_frame, 0, last_start);
    counters.world_clip.store(world, 0, clip);
    counters.world_frame.store(world, 0, frame);
    // The curriculum's view of the new episode (`startEpisodeAt`): the bin it starts in, nothing earned yet.
    if (options.curriculum == .enabled and bin_count > 0) {
        const bin_frames: u32 = tables.clip_bin_frames.load(clip);
        const bin_in_clip: u32 = @min(frame / bin_frames, bin_count - 1);
        counters.start_bins.store(world, 0, tables.clip_first_bin.load(clip) + bin_in_clip);
        counters.episode_decisions.store(world, 0, 0);
        const sums: WorldStateLayout = params.layout.world_f;
        sums.episode_discounted_returns.store(world, 0, 0);
        sums.episode_discount_powers.store(world, 0, 1);
        sums.episode_reward_sums.store(world, 0, 0);
    }
    // What a start clears (`startEpisodeAt`): the episode's steps, its aftermath, its return streak, its actions.
    counters.episode_steps.store(world, 0, 0);
    counters.aftermath_steps_left.store(world, 0, 0);
    counters.return_streaks.store(world, 0, 0);
    const arrays: WorldStateLayout = params.layout.world_f;
    var number: u32 = 0;
    while (number < params.counts.action_count) : (number += 1) {
        arrays.previous_actions.store(world, number, 0);
        arrays.applied_actions.store(world, number, 0);
        // The action given at the previous decision, which the action filter blends into: at rest in a new
        // episode, as the trainer forgets an ended episode's action (`forgetEndedEpisodes`).
        arrays.actions.store(world, number, 0);
    }
}

/// A RESET WORLD's POSE - the CPU fleet's `resetToFrame`, one joint per invocation: the joint's coordinates at the
/// world's start frame from its clip, and its velocity the difference from the frame before over the clip's frame time
/// (`robot.jointPositionDifference`, the very function the fleet's `differentiatePos` calls). Its warm start zeroed, as
/// a fresh `Data` has none: Newton's next solve starts from nothing. A world still in its episode is left alone.
pub fn reset_pose(invocation: u32) void {
    const joint_count: u32 = params.counts.joint_count;
    const world: u32 = invocation / joint_count;
    const joint: u32 = invocation % joint_count;
    if (world >= params.counts.world_count) {
        return;
    }
    const counters: WorldIntegersLayout = params.layout.world_u;
    const ended: bool = counters.episode_flags.load(world, 0) & episodeFlagBit(.finished) != 0;
    if (!ended) {
        return;
    }
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const arrays: WorldStateLayout = params.layout.world_f;
    const clip: u32 = counters.world_clip.load(world, 0);
    const frame: u32 = @max(counters.world_frame.load(world, 0), 1);
    const row: u32 = tables.clip_first_frame.load(clip) + frame;
    const joint_type: robot.JointType = typeOfJoint(joint);
    const first: u32 = tables.joint_first_coordinate.load(joint);
    const at_frame: robot.JointCoordinates = loadClipCoordinates(row, joint_type, first);
    const before: robot.JointCoordinates = loadClipCoordinates(row - 1, joint_type, first);
    storeJointCoordinates(arrays.joint_positions, world, joint_type, first, at_frame);
    const inverse_time: f32 = 1.0 / constants.clip_frame_time.load(clip);
    const velocity: robot.JointVelocity = robot.jointPositionDifference(joint_type, before, at_frame, inverse_time);
    const first_dof: u32 = tables.joint_first_dof.load(joint);
    var offset: u32 = 0;
    while (offset < joint_type.dofCount()) : (offset += 1) {
        arrays.joint_velocities.store(world, first_dof + offset, velocity.numbers[offset]);
        arrays.warmstart_accelerations.store(world, first_dof + offset, 0);
    }
}

/// One world's rest on the floor (`rest_on_floor`, `rest_after_noise`): the least of its bodies' lowest points, lifted
/// to the clearance by raising the free root (`robot.restLift`: never down).
fn restWorldOnFloor(world: u32) void {
    const arrays: WorldStateLayout = params.layout.world_f;
    var lowest: f32 = robot.no_shape_height;
    var body: u32 = 1;
    while (body < params.counts.body_count) : (body += 1) {
        lowest = @min(lowest, arrays.body_lowest_points.load(world, body));
    }
    const lift: f32 = robot.restLift(params.options.rest_clearance, lowest);
    if (lift == 0.0) {
        return;
    }
    var joint: u32 = 0;
    const root: u32 = while (joint < params.counts.joint_count) : (joint += 1) {
        if (typeOfJoint(joint) == .free) {
            break joint;
        }
    } else return;
    const height_at: u32 = params.layout.model_u.joint_first_coordinate.load(root) + 2;
    const height: f32 = arrays.joint_positions.load(world, height_at);
    arrays.joint_positions.store(world, height_at, height + lift);
}

/// A RESET WORLD RESTS ON THE FLOOR - the fleet's `restOnFloor`: its lowest point, the least of its bodies' (each the
/// least of its geoms', `body_lowest_points`, so the same minimum as `robot.lowestPoint`, exact in any order), lifted
/// to the clearance by raising the free root (`robot.restLift`: never down). Only when the run rests its starts.
pub fn rest_on_floor(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    if (params.options.rest_on_floor != .enabled) {
        return;
    }
    const counters: WorldIntegersLayout = params.layout.world_u;
    const ended: bool = counters.episode_flags.load(world, 0) & episodeFlagBit(.finished) != 0;
    if (!ended) {
        return;
    }
    restWorldOnFloor(world);
}

/// A RESET WORLD's START NOISE - the fleet's `perturbStart`, one joint per invocation: each actuated dof turned by the
/// noise's pose scale times its normal draw (`robot.drawNormal`, its index the dof's own), applied by
/// `robot.integrateJointPosition` as `integratePos` applies it - the root too, with a turn of nothing, as the fleet's
/// does - and the root's two horizontal velocities kicked at the next two indices. Nothing without noise.
pub fn perturb_start(invocation: u32) void {
    const joint_count: u32 = params.counts.joint_count;
    const world: u32 = invocation / joint_count;
    const joint: u32 = invocation % joint_count;
    if (world >= params.counts.world_count) {
        return;
    }
    const options: StepOptions = params.options;
    const noisy: bool = options.start_noise_pose != 0 or options.start_noise_velocity != 0;
    if (!noisy) {
        return;
    }
    const counters: WorldIntegersLayout = params.layout.world_u;
    const ended: bool = counters.episode_flags.load(world, 0) & episodeFlagBit(.finished) != 0;
    if (!ended) {
        return;
    }
    const tables: ModelTablesLayout = params.layout.model_u;
    const arrays: WorldStateLayout = params.layout.world_f;
    const episode: u32 = counters.episode_numbers.load(world, 0);
    const joint_type: robot.JointType = typeOfJoint(joint);
    const first: u32 = tables.joint_first_coordinate.load(joint);
    const first_dof: u32 = tables.joint_first_dof.load(joint);
    var turn: robot.JointVelocity = .{};
    if (joint_type != .free and options.start_noise_pose > 0) {
        var offset: u32 = 0;
        while (offset < joint_type.dofCount()) : (offset += 1) {
            const normal: f32 = robot.drawNormal(options.draw_seed, world, episode, .start_noise, first_dof + offset);
            turn.numbers[offset] = options.start_noise_pose * normal;
        }
    }
    if (options.start_noise_pose > 0) {
        const positions: WorldArray(.world_f, .coordinates) = arrays.joint_positions;
        const coordinates: robot.JointCoordinates = loadJointCoordinates(positions, world, joint_type, first);
        const moved: robot.JointCoordinates = robot.integrateJointPosition(joint_type, coordinates, turn, 1.0);
        storeJointCoordinates(arrays.joint_positions, world, joint_type, first, moved);
    }
    if (joint_type == .free and options.start_noise_velocity > 0) {
        const kicks_at: u32 = params.counts.dof_count;
        var kick: u32 = 0;
        while (kick < 2) : (kick += 1) {
            const normal: f32 = robot.drawNormal(options.draw_seed, world, episode, .start_noise, kicks_at + kick);
            const velocity: f32 = arrays.joint_velocities.load(world, first_dof + kick);
            arrays.joint_velocities.store(world, first_dof + kick, velocity + options.start_noise_velocity * normal);
        }
    }
}

/// A RESET WORLD RESTS AGAIN AFTER ITS NOISE - `perturbStart`'s own rest, whatever the task says about resting starts:
/// a turned pose can put a foot into the floor. Only when there was noise.
pub fn rest_after_noise(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const options: StepOptions = params.options;
    const noisy: bool = options.start_noise_pose != 0 or options.start_noise_velocity != 0;
    if (!noisy) {
        return;
    }
    const counters: WorldIntegersLayout = params.layout.world_u;
    const ended: bool = counters.episode_flags.load(world, 0) & episodeFlagBit(.finished) != 0;
    if (!ended) {
        return;
    }
    restWorldOnFloor(world);
}

/// A PUSH: the root's horizontal velocity changed by `speed` along `direction_rad` - the fleet's `push`.
fn pushRoot(world: u32, speed: f32, direction_rad: f32) void {
    const velocities: WorldArray(.world_f, .dofs) = params.layout.world_f.joint_velocities;
    const velocity_change_x: f32 = speed * @cos(direction_rad);
    const velocity_change_y: f32 = speed * @sin(direction_rad);
    velocities.store(world, 0, velocities.load(world, 0) + velocity_change_x);
    velocities.store(world, 1, velocities.load(world, 1) + velocity_change_y);
}

/// A DECISION's PUSHES, for every world still in its episode - the fleet's step's: on the schedule (every
/// `push_every` decisions of the episode), or at a random moment, a Poisson process of `push_rate_per_second` made one
/// decision at a time (the chance the rate times the schedule's share times the decision's seconds); the speed uniform
/// in the range the schedule has opened, the direction uniform round the vertical - each draw at the decision's number.
pub fn push_worlds(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const counters: WorldIntegersLayout = params.layout.world_u;
    const ended: bool = counters.episode_flags.load(world, 0) & episodeFlagBit(.finished) != 0;
    if (ended) {
        return;
    }
    const options: StepOptions = params.options;
    const steps: u32 = counters.episode_steps.load(world, 0);
    const scheduled: bool = options.push_every > 0 and steps % options.push_every == 0;
    const decision: u32 = options.decision_number;
    const chance: f32 = options.push_rate_per_second * options.push_schedule_share * options.decision_seconds;
    const chance_draw: f32 = robot.drawUniform(options.draw_seed, world, decision, .push_chance, 0);
    const at_random: bool = options.push_rate_per_second > 0 and chance_draw < chance;
    if (!scheduled and !at_random) {
        return;
    }
    const speed_range: f32 = (options.push_speed_max - options.push_speed_min) * options.push_schedule_share;
    const speed_draw: f32 = robot.drawUniform(options.draw_seed, world, decision, .push_speed, 0);
    const direction_draw: f32 = robot.drawUniform(options.draw_seed, world, decision, .push_direction, 0);
    const speed: f32 = options.push_speed_min + speed_range * speed_draw;
    pushRoot(world, speed, 2.0 * pi * direction_draw);
}

/// A RESET WORLD's START IN TROUBLE - the fleet's `restart`'s: drawn at the episode against the start share times the
/// schedule's share; a push at the schedule's top speed, the direction uniform round the vertical.
pub fn start_in_trouble(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const options: StepOptions = params.options;
    if (options.push_start_share <= 0) {
        return;
    }
    const counters: WorldIntegersLayout = params.layout.world_u;
    const ended: bool = counters.episode_flags.load(world, 0) & episodeFlagBit(.finished) != 0;
    if (!ended) {
        return;
    }
    const episode: u32 = counters.episode_numbers.load(world, 0);
    const share: f32 = options.push_schedule_share;
    const trouble_draw: f32 = robot.drawUniform(options.draw_seed, world, episode, .start_in_trouble, 0);
    if (!(trouble_draw < options.push_start_share * share)) {
        return;
    }
    const top_speed: f32 = options.push_speed_min + (options.push_speed_max - options.push_speed_min) * share;
    const direction_draw: f32 = robot.drawUniform(options.draw_seed, world, episode, .start_push_direction, 0);
    pushRoot(world, top_speed, 2.0 * pi * direction_draw);
}

/// A WORLD's EXPLORATION, after the policy has written its actions: every action plus its noise
/// (`robot.explorationNoise`, at the decision's number). Nothing at a spread of zero - acting without exploring.
pub fn explore_actions(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const options: StepOptions = params.options;
    if (options.exploration_spread == 0) {
        return;
    }
    const chosen_actions: WorldArray(.world_f, .actions) = params.layout.world_f.chosen_actions;
    const width: u32 = actionWidth();
    var action: u32 = 0;
    while (action < width) : (action += 1) {
        const spread: f32 = options.exploration_spread;
        const noise: f32 = robot.explorationNoise(options.draw_seed, world, options.decision_number, action, spread);
        const chosen: f32 = chosen_actions.load(world, action);
        const explored: f32 = chosen + noise;
        chosen_actions.store(world, action, explored);
    }
}

/// THE ACTION FILTER AT EACH DECISION (the trainer's `giveAction`), one world per invocation: the policy's explored
/// choice (`chosen_actions`) - each non-finite number made zero first, never into the physics - blended into the
/// action given at the previous decision (`actions`, at rest after a reset): the joints' offsets at `decision_filter`,
/// the limbs' stiffnesses after them at `decision_stiffness_filter`, each by the CPU's own
/// `robot.filteredActionNumber`. A number at a share of 1 is copied exactly - a blend would turn a negative zero
/// positive. The result is the decision's action, which the physics-rate filter then ramps in (`filter_actions`).
pub fn filter_decision(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const options: StepOptions = params.options;
    const arrays: WorldStateLayout = params.layout.world_f;
    const offset_count: u32 = params.counts.action_count - params.counts.limb_count;
    var number: u32 = 0;
    while (number < params.counts.action_count) : (number += 1) {
        const chosen_raw: f32 = arrays.chosen_actions.load(world, number);
        const usable: bool = isFinite(chosen_raw);
        const chosen: f32 = if (usable) chosen_raw else 0.0;
        const is_offset: bool = number < offset_count;
        const share: f32 = if (is_offset) options.decision_filter else options.decision_stiffness_filter;
        if (share == 1.0) {
            arrays.actions.store(world, number, chosen);
            continue;
        }
        const previous: f32 = arrays.actions.load(world, number);
        const given: f32 = robot.filteredActionNumber(share, chosen, previous);
        arrays.actions.store(world, number, given);
    }
}

/// EACH WORLD's EPISODE JUDGED, one invocation per world, after its rewards - robot.zig's `judgeEpisode`, the CPU
/// fleet's own rule: its counters advanced (a decision more), grace, failure, aftermath, return and end decided from
/// the tracking error `judge_tracking` stored and the termination's limits, the verdict into `episode_flags`.
pub fn judge_episode(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    if (params.counts.reference_feature_frames == 0) {
        return;
    }
    const state: WorldStateLayout = params.layout.world_f;
    const integers: WorldIntegersLayout = params.layout.world_u;
    const options: StepOptions = params.options;
    var err: robot.TrackingError = undefined;
    inline for (@typeInfo(robot.TrackingError).@"struct".field_names, 0..) |field_name, term| {
        @field(err, field_name) = state.tracking_errors.load(world, term);
    }
    const judgement_weights: JudgementWeights = loadJudgementWeights();
    // The step counter advanced before the judgement reads it, as the fleet's `step` advances it.
    var counters: robot.EpisodeCounters = .{
        .steps = integers.episode_steps.load(world, 0) + 1,
        .aftermath_steps_left = integers.aftermath_steps_left.load(world, 0),
        .return_streak = integers.return_streaks.load(world, 0),
        .steps_since_loss = integers.steps_since_loss.load(world, 0),
    };
    const rules: robot.EpisodeRules = .{
        .grace_steps = options.grace_steps,
        .aftermath_steps = options.aftermath_steps,
        .return_steps = options.return_steps,
        .max_steps = options.max_steps,
        .keeps_aftermath = world < options.aftermath_world_count,
    };
    // Over when another decision would run past the clip's last frame.
    const clip: u32 = integers.world_clip.load(world, 0);
    const frame: u32 = integers.world_frame.load(world, 0);
    const clip_over: bool = frame + options.decision_physics_steps >= params.layout.model_u.clip_frame_count.load(clip);
    const limits: robot.Termination = judgement_weights.termination;
    const verdict: robot.EpisodeVerdict = robot.judgeEpisode(&counters, rules, err, limits, clip_over);
    integers.episode_steps.store(world, 0, counters.steps);
    integers.aftermath_steps_left.store(world, 0, counters.aftermath_steps_left);
    integers.return_streaks.store(world, 0, counters.return_streak);
    integers.steps_since_loss.store(world, 0, counters.steps_since_loss);
    var flags: u32 = 0;
    if (verdict.lost) {
        flags |= episodeFlagBit(.lost);
    }
    if (verdict.returned) {
        flags |= episodeFlagBit(.returned);
    }
    if (verdict.in_aftermath) {
        flags |= episodeFlagBit(.in_aftermath);
    }
    if (verdict.aftermath_begins) {
        flags |= episodeFlagBit(.aftermath_begins);
    }
    if (verdict.finished) {
        flags |= episodeFlagBit(.finished);
    }
    if (verdict.ends_at_loss) {
        flags |= episodeFlagBit(.ends_at_loss);
    }
    if (verdict.capped) {
        flags |= episodeFlagBit(.capped);
    }
    integers.episode_flags.store(world, 0, flags);
    integers.return_lengths.store(world, 0, verdict.return_length);
}

/// THE ACTION FILTER, one invocation per world and number of the action, before each physics step: the world's applied
/// action moved toward its policy's by the task's share (`robot.filteredActionNumber`, as robot_track's `driveOnce`
/// filters it) - so a new decision ramps in over its physics steps rather than jumping at its start; 1 is none.
pub fn filter_actions(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.action_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const number: u32 = handled.element;
    const state: WorldStateLayout = params.layout.world_f;
    const asked: f32 = state.actions.load(world, number);
    const applied: f32 = state.applied_actions.load(world, number);
    // The joints' offsets first, then one stiffness per limb (`actionWidth`): each part at its own share.
    const offset_count: u32 = params.counts.action_count - params.counts.limb_count;
    const is_offset: bool = number < offset_count;
    const share: f32 = if (is_offset) params.options.action_filter else params.options.stiffness_filter;
    const filtered: f32 = robot.filteredActionNumber(share, asked, applied);
    state.applied_actions.store(world, number, filtered);
}

/// THE SERVO's TARGETS FROM THE REFERENCE, one invocation per world and joint - the joint's targets as robot_track's
/// `Fleet.driveOnce` forms them each physics step (`robot.applyAction`, then `robot.clampHinges`):
///
///   * the clip's pose at the frame AFTER the world's - the servo aims where the reference is going, as SuperTrack's
///     PD targets do - held at the clip's last frame;
///   * the world's applied action (`filter_actions`) added to it as a DISPLACEMENT IN VELOCITY SPACE: scaled by
///     `action_scale`, the free root's
///     six dofs none - a policy cannot push on the world - and integrated over a step of one
///     (`robot.integrateJointPosition`, which knows a hinge's offset is an angle added and a ball's is exp(a/2)
///     composed on its right, in the child's frame where its dofs live);
///   * a hinge's or a slide's target then held inside its range: a reference is in range, a reference plus an offset
///     need not be, and a target past a limit is a servo pushing against a wall.
pub fn reference_targets(invocation: u32) void {
    const handled: WorldElement = worldElementOf(invocation, params.counts.joint_count);
    if (!handled.in_range) {
        return;
    }
    const world: u32 = handled.world;
    const joint: u32 = handled.element;
    const tables: ModelTablesLayout = params.layout.model_u;
    const constants: ModelConstantsLayout = params.layout.model_f;
    const state: WorldStateLayout = params.layout.world_f;
    const integers: WorldIntegersLayout = params.layout.world_u;
    // The frame the servo aims at: the one after the world's, held at the clip's last.
    const clip: u32 = integers.world_clip.load(world, 0);
    const frame: u32 = integers.world_frame.load(world, 0);
    const last_frame: u32 = tables.clip_frame_count.load(clip) - 1;
    const aimed_frame: u32 = @min(frame + 1, last_frame);
    const joint_type: robot.JointType = typeOfJoint(joint);
    const first_coordinate: u32 = tables.joint_first_coordinate.load(joint);
    const first_dof: u32 = tables.joint_first_dof.load(joint);
    // The aimed frame's row among every clip's frames: its clip's first row, and the frame within the clip.
    const row: u32 = tables.clip_first_frame.load(clip) + aimed_frame;
    const reference: robot.JointCoordinates = loadClipCoordinates(row, joint_type, first_coordinate);
    // The action as a displacement in velocity space: scaled, and none on the free root's dofs.
    const root_dofs: u32 = servoRootDofCount();
    const scale: f32 = params.options.action_scale;
    var displacement: robot.JointVelocity = .{};
    var dof_offset: u32 = 0;
    while (dof_offset < joint_type.dofCount()) : (dof_offset += 1) {
        const dof: u32 = first_dof + dof_offset;
        if (dof >= root_dofs) {
            displacement.numbers[dof_offset] = scale * state.applied_actions.load(world, dof - root_dofs);
        }
    }
    const displaced: robot.JointCoordinates = robot.integrateJointPosition(joint_type, reference, displacement, 1.0);
    // A hinge's or a slide's target inside its range, as `robot.clampHinges` holds it.
    const has_range: bool = tables.jnt_limited.load(joint) != 0;
    const held_in_range: bool = (joint_type == .hinge or joint_type == .slide) and has_range;
    // A ball's target inside its rotation box, as `robot.clampBalls` holds it (`robot.ballTargetInBox`).
    const boxes: ModelTable(.model_f, .joint_box_numbers) = constants.ball_boxes;
    const boxed: bool = joint_type == .ball and boxes.load(12 * joint + 3) == 1.0;
    const target: robot.JointCoordinates = if (held_in_range) blk: {
        const range: [2]f32 = constants.joint_range.loadPair(joint);
        break :blk .ofSingle(clamp(displaced.single(), range[0], range[1]));
    } else if (boxed) blk: {
        const box: robot.RotationBox = loadBallBox(boxes, joint);
        break :blk .ofBall(robot.ballTargetInBox(displaced.ballOrientation(), box));
    } else displaced;
    storeJointCoordinates(state.servo_targets, world, joint_type, first_coordinate, target);
}

/// EACH WORLD's FRAME ADVANCED, one invocation per world, after each physics step: the clock of robot_track's
/// `Fleet.step`, which moves every character's reference on a frame after each of a decision's physics steps.
pub fn advance_frames(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.world_count) {
        return;
    }
    const integers: WorldIntegersLayout = params.layout.world_u;
    const frame: u32 = integers.world_frame.load(world, 0);
    integers.world_frame.store(world, 0, frame + 1);
}

// ------------------------------------------------------------------------------------------------------------------
// DISPATCHING AND THE CPU TWIN
// invocationCount: a dispatch's rule turned into a number; CpuTwin: every kernel run as a loop on the CPU, the
// same Zig, for the bit-for-bit checks; kernels: the entry points, every program's, each once
// ------------------------------------------------------------------------------------------------------------------

/// The number of invocations a dispatch of shape `invocations` runs, for a model of `counts`.
pub fn invocationCount(invocations: Invocations, counts: Counts) u32 {
    return switch (invocations) {
        .per_world => counts.world_count,
        .per_world_and_body => counts.world_count * counts.body_count,
        .per_world_and_branch => counts.world_count * counts.branch_count,
        .per_world_and_geom => counts.world_count * counts.geom_count,
        .per_world_and_site => counts.world_count * counts.site_count,
        .per_world_and_dof => counts.world_count * counts.dof_count,
        .per_world_and_actuator => counts.world_count * counts.actuator_count,
        .per_world_and_activation => counts.world_count * counts.activation_count,
        .per_world_and_joint => counts.world_count * counts.joint_count,
        .per_world_and_action => counts.world_count * counts.action_count,
        .per_world_and_limit_candidate => counts.world_count * counts.limit_candidate_count,
        .per_world_and_constraint_row => counts.world_count * counts.constraint_capacity,
        .per_world_workgroup => counts.world_count * config.workgroup,
    };
}

/// This file's declarations, where the twin finds a kernel by its name (`CpuTwin.run`).
const kernel_namespace = @This();

/// THE ROTATION BOXES AS NUMBERS, the table's layout (`ball_boxes`): per joint its box's low, its high and its center,
/// four numbers each; low's fourth 1 for a boxed ball, 0 (and the rest zero) for any other joint. Into `out`, 12 per
/// joint (`loadBallBox` reads them back).
pub fn rotationBoxNumbers(boxes: []const ?robot.RotationBox, out: []f32) void {
    @memset(out, 0);
    for (boxes, 0..) |maybe_box, joint| {
        const box: robot.RotationBox = maybe_box orelse continue;
        out[12 * joint ..][0..4].* = .{ box.low[0], box.low[1], box.low[2], 1.0 };
        out[12 * joint + 4 ..][0..4].* = .{ box.high[0], box.high[1], box.high[2], 0.0 };
        out[12 * joint + 8 ..][0..4].* = box.center;
    }
}

/// A DECISION's CLOCK, what changes from one decision to the next: its number (the counter of its draws - its pushes'
/// and its exploration's), the share of the push schedule opened by then (`Pushes.scheduleShare`), and the
/// exploration's spread, which training anneals. Every program that draws takes it as an argument (`runResets`,
/// `giveActions`), so no draw is made at a stale number.
pub const DecisionClock = struct {
    number: u32,
    push_schedule_share: f32,
    /// The exploration's spread (`explore_actions`): the noise scale times sigma, which training anneals.
    exploration_spread: f32 = 0,

    /// The clock written into the uniform.
    pub fn applyTo(clock: DecisionClock, options: *StepOptions) void {
        options.decision_number = clock.number;
        options.push_schedule_share = clock.push_schedule_share;
        options.exploration_spread = clock.exploration_spread;
    }
};

/// THE TRACKING TASK's SETTINGS, robot.zig's (`robot.TrackingSettings`): what a CPU fleet's options and task say, as
/// one value (robot_track's `Fleet.trackingSettings`) - mirrored onto the device in ONE call (`CpuTwin.setTracking`,
/// the host's `Sim.setTracking`), so no setting is left at a default nobody chose.
pub const TrackingSettings = robot.TrackingSettings;

/// THE TRACKING SETTINGS THAT LIVE IN THE UNIFORM, written into `options`. The judgement's weights and the rotation
/// boxes are tables of the model: the setters upload them beside this (`setTracking`).
pub fn applyTrackingSettings(settings: TrackingSettings, options: *StepOptions) !void {
    try options.setFloor(settings.floor);
    options.setServo(settings.law, settings.servo_mode);
    options.setActionScale(settings.action_scale);
    options.setActionFilter(settings.action_filter, settings.stiffness_filter);
    options.decision_filter = settings.decision_filter;
    options.decision_stiffness_filter = settings.decision_stiffness_filter;
    options.setLimbStiffness(settings.limb_stiffness);
    options.setHeadBody(settings.head);
    options.setEpisodeRules(settings.episode);
    options.draw_seed = settings.draw_seed;
    options.clip_assignment = settings.clip_assignment;
    options.rest_on_floor = settings.rest_on_floor;
    options.rest_clearance = settings.rest_clearance;
    options.start_noise_pose = settings.start_noise_pose;
    options.start_noise_velocity = settings.start_noise_velocity;
    options.push_every = settings.push_every;
    options.push_rate_per_second = settings.push_rate_per_second;
    options.push_speed_min = settings.push_speed_min;
    options.push_speed_max = settings.push_speed_max;
    options.push_start_share = settings.push_start_share;
    options.decision_seconds = settings.decision_seconds;
    options.curriculum = settings.curriculum;
    options.curriculum_discount = settings.curriculum_discount;
}

/// A JUDGED SIMULATOR TAKES NO HULLS: the device packs no hull's points, so a hull would have no floor contact and no
/// lowest point there - a silent difference from robot.zig's judgement. Refused, the geom named, wherever the clips
/// carry the reference's tables.
pub fn requireNoHullsWhenJudged(model: *const robot.Model, clips: []const ClipPoses) void {
    // Judged only where the clips carry the reference's tables; a simulator that only steps may hold hulls.
    const judged: bool = for (clips) |clip| {
        if (clip.reference_features.len > 0) {
            break true;
        }
    } else false;
    if (!judged) {
        return;
    }
    for (model.geom_shape, 0..) |shape, geom| {
        assertf(shape != .hull, @src(), "robotgpu: geom {d} is a hull, which the device does not take", .{geom});
    }
}

/// The entries, each its own compute entry point in the SPIR-V: every kernel of robotgpu's, the step program's then
/// the constraint program's (`program.kernel_names`).
pub const kernels = program.kernel_names;

/// Whether `kernel_name` is one of the device's kernels - one of `kernels`, the names every program dispatches, which
/// are exactly the entry points a device's module is compiled with.
fn isDeviceKernel(comptime kernel_name: []const u8) bool {
    // Every device kernel's name against `kernel_name`, letter by letter: more than Zig's default comptime budget.
    @setEvalBranchQuota(100_000);
    for (kernels) |device_kernel_name| {
        if (eql(u8, device_kernel_name, kernel_name)) {
            return true;
        }
    }
    return false;
}

/// THE TWIN RUNS ONLY WHAT THE DEVICE HAS: a kernel the twin is asked to dispatch must be one the device compiles -
/// otherwise every check on the twin would pass while a device had no such entry point.
fn requireDeviceKernel(comptime kernel_name: []const u8) void {
    if (!isDeviceKernel(kernel_name)) {
        @compileError("kernel '" ++ kernel_name ++ "' is in no program of robotgpu_program.zig: no device compiles it");
    }
}

// EVERY KERNEL IN A PROGRAM: every public function of this file with a kernel's signature - one invocation index in,
// nothing out, `fn (u32) void` - must be named by some program. A kernel written but dispatched nowhere would never be
// compiled for a device, while the CPU twin, which calls kernels by name, would run it and every check would pass.
comptime {
    // Every declaration, and for each kernel every device kernel's name: far more than the default comptime budget.
    @setEvalBranchQuota(1_000_000);
    // This file seen as a type: `@typeInfo` lists its public declarations by name - kernels, types, constants alike.
    const this_file: type = @This();
    const this_file_as_struct = @typeInfo(this_file).@"struct";
    const declaration_names: []const [:0]const u8 = this_file_as_struct.decl_names;
    const kernel_signature: type = fn (u32) void;
    for (declaration_names) |declaration_name| {
        // The declaration's type, looked up by its name: a kernel's is exactly `kernel_signature`.
        const declaration_type: type = @TypeOf(@field(this_file, declaration_name));
        const is_a_kernel: bool = declaration_type == kernel_signature;
        if (!is_a_kernel) {
            continue;
        }
        if (!isDeviceKernel(declaration_name)) {
            @compileError("kernel '" ++ declaration_name ++ "' is in no program of robotgpu_program.zig: " ++
                "no device compiles it");
        }
    }
}

/// THE TWIN, RUN DIRECTLY: a model's worlds in the CPU twin's own arenas (`g.B`) with their uniform (`g.P`) - packed
/// and set as a `Sim` sets them on a device - and each kernel called once per invocation, in order, as the twin's loop
/// calls it. No device and no engine, so a kernel's parity with robot.zig, or a decision's with the CPU fleet's, checks
/// in seconds; the device then checks against the twin. A tool for tests: it works in the module's own arrays, so one
/// twin at a time.
pub const CpuTwin = struct {
    counts: Counts,
    layout: Layout,

    /// `world_count` worlds of `model` in the twin's arenas, with no task - `initTracking` without clips.
    pub fn init(model: *const robot.Model, world_count: u32) LayoutError!CpuTwin {
        return initTracking(model, world_count, &.{});
    }

    /// `world_count` worlds of `model` in the twin's arenas with a tracking task's `clips`: the worlds' arenas
    /// cleared, then counted, laid out, packed - the clips beside the model - and the uniform set. CLEARED, because
    /// the twin's arenas are the module's own arrays: a twin would otherwise start from whatever the last one left,
    /// its warm start among it, where robot.zig's new `Data` holds zeros.
    /// The judgement's weights for the twin's worlds (`writeJudgementWeights`): the tracker's reward weights and
    /// SuperMimic's scales, as robot_track's `Task` holds them.
    pub fn setJudgementWeights(twin: CpuTwin, weights: JudgementWeights) void {
        writeJudgementWeights(twin.layout.model_f, &g.B.model_f, weights);
    }

    pub fn initTracking(
        model: *const robot.Model,
        world_count: u32,
        clips: []const ClipPoses,
    ) LayoutError!CpuTwin {
        requireNoHullsWhenJudged(model, clips);
        @memset(&g.B.world_f, 0);
        @memset(&g.B.world_u, 0);
        @memset(&g.B.efc_f, 0);
        const counts: Counts = countsWithClips(countsOf(model, world_count), clips);
        const layout: Layout = try layoutFor(counts, .{});
        pack(model, layout, &g.B.model_u, &g.B.model_f);
        packClips(clips, counts, layout, &g.B.model_u, &g.B.model_f);
        // Every world's first episode begins with nothing discounted yet: its discount's power is one, as a start
        // sets it (`begin_reset`); the arrays' zero would leave every return at zero.
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            g.B.world_f[layout.world_f.episode_discount_powers.at(world, 0)] = 1;
        }
        const options: StepOptions = .of(model);
        g.P = .{ .counts = counts, .layout = layout, .options = options };
        const twin: CpuTwin = .{ .counts = counts, .layout = layout };
        return twin;
    }

    /// Kernel `kernel_name`, called for invocations 0 to `invocation_count - 1`, in order.
    pub fn run(comptime kernel_name: []const u8, invocation_count: u32) void {
        // Every kernel has this shape: one invocation's index in, nothing out.
        const kernel: fn (u32) void = @field(kernel_namespace, kernel_name);
        var invocation: u32 = 0;
        while (invocation < invocation_count) : (invocation += 1) {
            kernel(invocation);
        }
    }

    /// Every dispatch of `dispatches`, in order, each over its invocations for the twin's counts.
    pub fn runProgram(twin: CpuTwin, comptime dispatches: []const Dispatch) void {
        inline for (dispatches) |dispatch| {
            comptime requireDeviceKernel(dispatch.kernel);
            run(dispatch.kernel, invocationCount(dispatch.invocations, twin.counts));
        }
    }

    /// ONE DECISION of `physics_steps` steps: for each, the tracking task's dispatches before the step, the step
    /// program, and those after it - as `Sim.submitDecision` submits them to a device, and as robot_track's
    /// `Fleet.step` takes a decision of `decide_every` physics steps.
    /// THE TRACKING TASK's SETTINGS for the twin's worlds, all of them (`TrackingSettings`): the uniform's, then the
    /// judgement's weights in the model's table.
    pub fn setTracking(twin: CpuTwin, settings: TrackingSettings) !void {
        // A curriculum needs bins: without them the starts would fall back to uniform while the fleet's follow it.
        if (settings.curriculum == .enabled and twin.counts.curriculum_bin_total == 0) {
            return error.CurriculumWithoutBins;
        }
        try applyTrackingSettings(settings, &g.P.options);
        twin.setJudgementWeights(settings.judgement);
        const boxes_at: u32 = twin.layout.model_f.ball_boxes.at(0);
        const box_numbers: []f32 = g.B.model_f[boxes_at..][0 .. 12 * twin.counts.joint_count];
        rotationBoxNumbers(settings.rotation_boxes, box_numbers);
    }

    /// A DECISION's END on the twin, as the host's `submitDecisionEnd`: the observation, then the judgement - the
    /// reference tables asserted.
    pub fn runDecisionEnd(twin: CpuTwin) void {
        const tables_given: bool = twin.counts.reference_feature_frames > 0;
        assertf(tables_given, @src(), "runDecisionEnd: the clips were given no reference tables", .{});
        twin.runProgram(&observe_program);
        twin.runProgram(&judge_program);
    }

    /// The policy's normaliser (`feature_means`, `feature_spreads`): one mean and one spread per feature.
    pub fn setFeatureNormalizer(
        twin: CpuTwin,
        means: []const f32,
        spreads: []const f32,
    ) void {
        const feature_count: usize = robot.localSize(twin.counts.body_count);
        const one_per_feature: bool = means.len == feature_count and spreads.len == feature_count;
        assertf(one_per_feature, @src(), "{d} means and {d} spreads for {d} features", .{
            means.len,
            spreads.len,
            feature_count,
        });
        for (means, spreads, 0..) |mean, spread, feature| {
            const index: u32 = @intCast(feature);
            g.B.model_f[twin.layout.model_f.feature_means.at(index)] = mean;
            g.B.model_f[twin.layout.model_f.feature_spreads.at(index)] = spread;
        }
    }

    /// THE DECISION's ACTION on the twin (`give_program`), after the policy's choice: the exploration, at the
    /// decision's clock - the decision about to be stepped, taken here so its draws cannot be made at a stale number
    /// - then the action filter into `actions`.
    pub fn giveActions(twin: CpuTwin, clock: DecisionClock) void {
        clock.applyTo(&g.P.options);
        twin.runProgram(&give_program);
    }

    /// ONE WHOLE DECISION on the twin, as the fleet's `step` is one: the physics steps (`runDecision`), the judgement
    /// (`runDecisionEnd`), then the restarts and the pushes (`runResets`, at `clock`). A world is compared with the
    /// fleet's only between whole decisions - in between, one side may have restarted or pushed and the other not yet.
    pub fn stepDecision(twin: CpuTwin, physics_steps: u32, clock: DecisionClock) void {
        twin.runDecision(physics_steps);
        twin.runDecisionEnd();
        twin.runResets(clock);
    }

    /// THE RESETS on the twin (`reset_program`), after a decision's end: the decision's pushes, then every world whose
    /// episode ended begins another - at the decision's clock (`DecisionClock`), taken here so it cannot be forgotten.
    /// Then the observation program again - its kinematics and its observation - so a reset world's next action reads
    /// its new episode's state, not its old one's last (worlds that did not reset recompute the same).
    pub fn runResets(twin: CpuTwin, clock: DecisionClock) void {
        clock.applyTo(&g.P.options);
        twin.runProgram(&reset_program);
        twin.runProgram(&observe_program);
    }

    pub fn runDecision(twin: CpuTwin, physics_steps: u32) void {
        twin.runProgram(&decision_start_program);
        var physics_step: u32 = 0;
        while (physics_step < physics_steps) : (physics_step += 1) {
            twin.runProgram(&before_step_program);
            twin.runProgram(&step_program);
            twin.runProgram(&after_step_program);
        }
    }
};

comptime {
    for (kernels) |name| {
        k.installKernelLean(@This(), name);
    }
}
