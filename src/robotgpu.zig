//! robotgpu.zig - THE ROBOT SIMULATOR ON THE GPU: many worlds of one robot.zig model, stepped together by compute
//! kernels in MuJoCo Warp's shapes, each kernel with a CPU twin that runs the same Zig.
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
//! An arena holds many ARRAYS - `qpos`, `xpos`, `cinert`... - one after another. Where each begins, and how far apart
//! its worlds lie, is the LAYOUT, computed on the host once per model (`layoutFor`) and handed to every kernel inside
//! `Params`. The layout is one struct per arena, and each array's TYPE says which arena it lives in and what one item
//! of it is - `WorldArray(.world_f, .body_vectors)` is a vector per body, in every world:
//!
//!     params.layout.world_f.xpos.loadVec(world, body)     a body's position, read from world_f
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
//!     xpos (25 bodies, a vector of four floats each: 100 floats a world)
//!
//!     offset ->  [ world 0: body 0, body 1, ... body 24 ][ world 1: body 0 ... ][ world 2 ... ] ...
//!                 <---------- stride = 100 ----------->
//!
//!     body b of world w   at   offset + w * stride + 4 * b                         (`WorldArray.at`)
//!
//! Invocations that handle consecutive items of one world read consecutive addresses, and a kernel that runs one
//! invocation per world and item - MuJoCo Warp's commonest shape - reads each world's block as a run.

const std = @import("std");
const k = @import("kompute");
const zm = @import("zm");
const Vec = zm.Vec;
const robot = @import("robot");
const sizes = @import("robotgpu_sizes");

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
fn ArenaElement(comptime arena: Arena) type {
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

/// The model's sizes and the number of worlds - what every layout is computed from.
pub const Counts = extern struct {
    nworld: u32,
    nbody: u32,
    njnt: u32,
    nq: u32,
    nv: u32,
    ngeom: u32,
    nu: u32,
    na: u32,
    /// The mass matrix's stored entries: its lower triangle along each dof's chain of ancestors.
    nmass: u32,
    /// The dofs of every body's chain, all chains together (`pack`).
    nchain: u32,
    nsite: u32,
    /// The kinematic tree's BRANCHES - one per leaf body - and the bodies of all their chains together (`pack`).
    nbranch: u32,
    nbranch_bodies: u32,
    // Padding to a whole 16-byte row - scalars, since a uniform aligns every array element to 16 bytes.
    _padding_0: u32 = 0,
    _padding_1: u32 = 0,
    _padding_2: u32 = 0,
};

/// The 32-bit words of one body's dof mask: a bit per dof.
pub fn maskWords(dof_count: u32) u32 {
    return (dof_count + 31) / 32;
}

/// WHAT ONE COPY OF AN ARRAY IS MADE OF - the world's block of a per-world array, or a model table's whole: ITEMS, one
/// per position coordinate, dof, actuator, activation, body, joint, geom or site (or per word of the bodies' dof masks,
/// per entry of the mass matrix, of the dof chains, of the branches), and each item a WIDTH of numbers - one; a vector
/// of four (three and padding); a motion or a force of eight (angular, then linear); a frame of twelve (a 3 x 3
/// rotation, its rows padded); an inertia of sixteen (`diag`, `off`, `h`, then the mass and three of padding); or a
/// joint's two or five (a range, a limit's softness, its impedance).
pub const Elements = enum {
    single,
    coordinates,
    dofs,
    dof_motions,
    actuators,
    activations,
    bodies,
    body_vectors,
    body_motions,
    body_frames,
    body_inertias,
    joints,
    joint_vectors,
    joint_pairs,
    joint_impedances,
    geoms,
    geom_vectors,
    geom_frames,
    sites,
    site_vectors,
    mass_entries,
    chain_entries,
    ancestor_words,
    branch_bodies,
    branches_and_end,

    /// How many items one copy holds, for a model of `counts`.
    fn items(elements: Elements, counts: Counts) u32 {
        return switch (elements) {
            .single => 1,
            .coordinates => counts.nq,
            .dofs, .dof_motions => counts.nv,
            .actuators => counts.nu,
            .activations => counts.na,
            .bodies, .body_vectors, .body_motions, .body_frames, .body_inertias => counts.nbody,
            .joints, .joint_vectors, .joint_pairs, .joint_impedances => counts.njnt,
            .geoms, .geom_vectors, .geom_frames => counts.ngeom,
            .sites, .site_vectors => counts.nsite,
            .mass_entries => counts.nmass,
            .chain_entries => counts.nchain,
            .ancestor_words => counts.nbody * maskWords(counts.nv),
            .branch_bodies => counts.nbranch_bodies,
            .branches_and_end => counts.nbranch + 1,
        };
    }

    /// The numbers in one item.
    fn width(elements: Elements) u32 {
        return switch (elements) {
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
            => 1,
            .joint_pairs => 2,
            .body_vectors, .joint_vectors, .geom_vectors, .site_vectors => 4,
            .joint_impedances => 5,
            .dof_motions, .body_motions => 8,
            .body_frames, .geom_frames => 12,
            .body_inertias => 16,
        };
    }

    /// The numbers one copy holds: its items times their width.
    fn count(elements: Elements, counts: Counts) u32 {
        return elements.items(counts) * elements.width();
    }
};

/// Refuse, at compile time, an accessor named `accessor` that moves items of `numbers_per_item` numbers on an array
/// whose items are another width - a vector read of a table of scalars, a scalar read of a table of vectors.
fn requireItemWidth(
    comptime elements: Elements,
    comptime numbers_per_item: u32,
    comptime accessor: []const u8,
) void {
    const widths_match: bool = elements.width() == numbers_per_item;
    if (!widths_match) {
        @compileError(std.fmt.comptimePrint("{s}: an item of `{s}` is {d} numbers, not {d}", .{
            accessor,
            @tagName(elements),
            elements.width(),
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
pub fn WorldArray(comptime arena: Arena, comptime elements: Elements) type {
    return extern struct {
        offset: u32 = 0,
        stride: u32 = 0,
        count: u32 = 0,
        _padding: u32 = 0,

        const Array = @This();
        const Element: type = ArenaElement(arena);

        /// The arena the array lives in, and what one item of it is.
        pub const home: Arena = arena;
        pub const kind: Elements = elements;
        /// One copy per world (`placeArrays`).
        pub const per_world: bool = true;

        /// The arena index of item `item` of world `world` - the item's first number, world-major (this file's head).
        pub fn at(array: Array, world: u32, item: u32) u32 {
            const numbers_per_item: u32 = comptime kind.width();
            return array.offset + world * array.stride + item * numbers_per_item;
        }

        /// Item `item` of world `world`, one number.
        pub fn load(array: Array, world: u32, item: u32) Element {
            comptime requireItemWidth(kind, 1, "load");
            return loadNumber(arena, array.at(world, item));
        }

        /// Item `item` of world `world` set to `value`, one number.
        pub fn store(array: Array, world: u32, item: u32, value: Element) void {
            comptime requireItemWidth(kind, 1, "store");
            storeNumber(arena, array.at(world, item), value);
        }

        /// Item `item` of world `world`, a vector of four floats - a position, a quaternion.
        pub fn loadVec(array: Array, world: u32, item: u32) Vec {
            comptime requireFloats(arena, "loadVec");
            comptime requireItemWidth(kind, 4, "loadVec");
            return loadVector(arena, array.at(world, item));
        }

        /// Item `item` of world `world` set to `vector`, four floats.
        pub fn storeVec(array: Array, world: u32, item: u32, vector: Vec) void {
            comptime requireFloats(arena, "storeVec");
            comptime requireItemWidth(kind, 4, "storeVec");
            storeVector(arena, array.at(world, item), vector);
        }
    };
}

/// WHERE ONE MODEL TABLE LIVES: in arena `arena`, a single copy shared by every world, made of `elements` - the same
/// sixteen bytes as a per-world array (`WorldArray`), its stride the copy's padded length. Besides the kernels'
/// accessors, three for the host, which packs the model into an IMAGE of the arena - a host array laid out as the
/// arena is (`pack`) - and reads one back (the tests).
pub fn ModelTable(comptime arena: Arena, comptime elements: Elements) type {
    return extern struct {
        offset: u32 = 0,
        stride: u32 = 0,
        count: u32 = 0,
        _padding: u32 = 0,

        const Table = @This();
        const Element: type = ArenaElement(arena);

        /// The arena the table lives in, and what one item of it is.
        pub const home: Arena = arena;
        pub const kind: Elements = elements;
        /// One copy, shared by every world (`placeArrays`).
        pub const per_world: bool = false;

        /// The arena index of item `item` - its first number.
        pub fn at(table: Table, item: u32) u32 {
            const numbers_per_item: u32 = comptime kind.width();
            return table.offset + item * numbers_per_item;
        }

        /// Item `item`, one number.
        pub fn load(table: Table, item: u32) Element {
            comptime requireItemWidth(kind, 1, "load");
            return loadNumber(arena, table.at(item));
        }

        /// Item `item`, a vector of four floats.
        pub fn loadVec(table: Table, item: u32) Vec {
            comptime requireFloats(arena, "loadVec");
            comptime requireItemWidth(kind, 4, "loadVec");
            return loadVector(arena, table.at(item));
        }

        /// Item `item` as robot.zig's spatial inertia: `diag`, `off` and `h`, a vector each, then the mass.
        pub fn loadInertia(table: Table, item: u32) robot.Inertia {
            comptime requireFloats(arena, "loadInertia");
            comptime requireItemWidth(kind, 16, "loadInertia");
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
            comptime requireItemWidth(kind, 1, "fill");
            @memcpy(image[table.offset..][0..table.count], values);
        }

        /// HOST SIDE: a table of vectors written into its place in `image`, four floats each.
        pub fn fillVectors(table: Table, image: []f32, vectors: []const Vec) void {
            comptime requireFloats(arena, "fillVectors");
            comptime requireItemWidth(kind, 4, "fillVectors");
            for (vectors, 0..) |vector, item| {
                const first: u32 = table.at(@intCast(item));
                image[first..][0..4].* = vector;
            }
        }
    };
}

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
/// arrays carry MuJoCo Warp's `Data` names as their own. Where the form differs: the spatial inertias (`cinert`,
/// `crb`) are robot.zig's - `diag`, `off`, `h` and the mass, as the model's `body_inertia` is - where MuJoCo keeps ten
/// numbers.
pub const WorldStateLayout = extern struct {
    qpos: WorldArray(.world_f, .coordinates) = .{},
    qvel: WorldArray(.world_f, .dofs) = .{},
    qacc: WorldArray(.world_f, .dofs) = .{},
    qacc_smooth: WorldArray(.world_f, .dofs) = .{},
    qfrc_applied: WorldArray(.world_f, .dofs) = .{},
    qfrc_bias: WorldArray(.world_f, .dofs) = .{},
    qfrc_passive: WorldArray(.world_f, .dofs) = .{},
    qfrc_actuator: WorldArray(.world_f, .dofs) = .{},
    qfrc_smooth: WorldArray(.world_f, .dofs) = .{},
    ctrl: WorldArray(.world_f, .actuators) = .{},
    act: WorldArray(.world_f, .activations) = .{},
    xpos: WorldArray(.world_f, .body_vectors) = .{},
    xquat: WorldArray(.world_f, .body_vectors) = .{},
    xmat: WorldArray(.world_f, .body_frames) = .{},
    xipos: WorldArray(.world_f, .body_vectors) = .{},
    ximat: WorldArray(.world_f, .body_frames) = .{},
    subtree_com: WorldArray(.world_f, .body_vectors) = .{},
    cinert: WorldArray(.world_f, .body_inertias) = .{},
    crb: WorldArray(.world_f, .body_inertias) = .{},
    cvel: WorldArray(.world_f, .body_motions) = .{},
    cacc: WorldArray(.world_f, .body_motions) = .{},
    cfrc_int: WorldArray(.world_f, .body_motions) = .{},
    cdof: WorldArray(.world_f, .dof_motions) = .{},
    cdof_dot: WorldArray(.world_f, .dof_motions) = .{},
    geom_xpos: WorldArray(.world_f, .geom_vectors) = .{},
    geom_xmat: WorldArray(.world_f, .geom_frames) = .{},
    qM: WorldArray(.world_f, .mass_entries) = .{},
    qLD: WorldArray(.world_f, .mass_entries) = .{},
    qLDiagInv: WorldArray(.world_f, .dofs) = .{},
};

/// THE PER-WORLD INTEGERS OF `world_u`.
pub const WorldIntegersLayout = extern struct {
    /// Each world's OVERFLOW word: a bit for each fixed capacity the world ran past in a step (more contacts or
    /// constraint rows than its slots), so the host learns of it instead of the results going quietly wrong; cleared
    /// at the start of every step (`clear_overflow`).
    overflow: WorldArray(.world_u, .single) = .{},
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
    body_jnt_adr: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_jntnum`.
    body_jnt_num: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_dofadr`.
    body_dof_adr: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `body_dofnum`.
    body_dof_num: ModelTable(.model_u, .bodies) = .{},
    /// MJW: `jnt_type`.
    jnt_type: ModelTable(.model_u, .joints) = .{},
    /// MJW: `jnt_bodyid`.
    jnt_body: ModelTable(.model_u, .joints) = .{},
    /// MJW: `jnt_qposadr`.
    jnt_qpos_adr: ModelTable(.model_u, .joints) = .{},
    /// MJW: `jnt_dofadr`.
    jnt_dof_adr: ModelTable(.model_u, .joints) = .{},
    /// MJW: `dof_parentid`.
    dof_parent: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `dof_bodyid`.
    dof_body: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `dof_jntid`.
    dof_jnt: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `M_rownnz`.
    mass_row_nonzeros: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `M_rowadr`.
    mass_row_start: ModelTable(.model_u, .dofs) = .{},
    /// MJW: `M_colind`.
    mass_col_index: ModelTable(.model_u, .mass_entries) = .{},
    /// Where each body's dof chain begins in `chain_dofs` (robotgpu's own).
    body_chain_start: ModelTable(.model_u, .bodies) = .{},
    /// How many dofs each body's chain holds (robotgpu's own).
    body_chain_length: ModelTable(.model_u, .bodies) = .{},
    /// Every body's chain of dofs, root first, all chains together (robotgpu's own).
    chain_dofs: ModelTable(.model_u, .chain_entries) = .{},
    /// Each body's chain as bits, `maskWords(nv)` words a body. MJW keeps the same as `body_isdofancestor`, a number
    /// per body and dof.
    body_ancestor_mask: ModelTable(.model_u, .ancestor_words) = .{},
    /// MJW: `jnt_limited`.
    jnt_limited: ModelTable(.model_u, .joints) = .{},
    /// MJW: `geom_type`.
    geom_type: ModelTable(.model_u, .geoms) = .{},
    /// MJW: `geom_bodyid`.
    geom_body: ModelTable(.model_u, .geoms) = .{},
    /// MJW: `site_bodyid`.
    site_body: ModelTable(.model_u, .sites) = .{},
    /// MJW: `body_branches`.
    body_branches: ModelTable(.model_u, .branch_bodies) = .{},
    /// MJW: `body_branch_start`.
    body_branch_start: ModelTable(.model_u, .branches_and_end) = .{},
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
/// moments with their frame (`body_inertia`, `body_iquat`, `body_ipos`) and forms the spatial inertia in `com_pos`;
/// DAMPING is per joint (`jnt_damping`), MuJoCo's per dof (`dof_damping`), the same numbers for the hinges and
/// slides a tracked robot has; FRICTION is one coefficient, MuJoCo's three (slide, spin, roll) arriving with the
/// collision fields.
pub const ModelConstantsLayout = extern struct {
    /// MJW: `body_pos`.
    body_pos: ModelTable(.model_f, .body_vectors) = .{},
    /// MJW: `body_quat`.
    body_rot: ModelTable(.model_f, .body_vectors) = .{},
    /// MJW: `body_ipos`.
    body_ipos: ModelTable(.model_f, .body_vectors) = .{},
    /// robot.zig's spatial inertia about the body's frame (this struct's doc says why MJW differs).
    body_inertia: ModelTable(.model_f, .body_inertias) = .{},
    /// MJW: `body_mass`.
    body_mass: ModelTable(.model_f, .bodies) = .{},
    /// MJW: `body_subtreemass`.
    body_subtree_mass: ModelTable(.model_f, .bodies) = .{},
    /// MJW: `jnt_axis`.
    jnt_axis: ModelTable(.model_f, .joint_vectors) = .{},
    /// MJW: `jnt_pos`.
    jnt_pos: ModelTable(.model_f, .joint_vectors) = .{},
    /// MJW: `jnt_range`.
    jnt_range: ModelTable(.model_f, .joint_pairs) = .{},
    /// MJW: `jnt_solref`.
    jnt_limit_softness: ModelTable(.model_f, .joint_pairs) = .{},
    /// MJW: `jnt_solimp`.
    jnt_limit_impedance: ModelTable(.model_f, .joint_impedances) = .{},
    /// MJW: `jnt_margin`.
    jnt_limit_margin: ModelTable(.model_f, .joints) = .{},
    /// MJW: `dof_damping` (per dof there, per joint here).
    jnt_damping: ModelTable(.model_f, .joints) = .{},
    /// MJW: `jnt_stiffness`.
    jnt_stiffness: ModelTable(.model_f, .joints) = .{},
    /// MJW: `qpos_spring`.
    jnt_ref: ModelTable(.model_f, .joints) = .{},
    /// MJW: `dof_armature`.
    dof_armature: ModelTable(.model_f, .dofs) = .{},
    /// MJW: `geom_pos`.
    geom_pos: ModelTable(.model_f, .geom_vectors) = .{},
    /// MJW: `geom_quat`.
    geom_rot: ModelTable(.model_f, .geom_vectors) = .{},
    /// MJW: `geom_size`.
    geom_size: ModelTable(.model_f, .geom_vectors) = .{},
    /// MJW: `geom_friction` (one coefficient here, three there).
    geom_friction: ModelTable(.model_f, .geoms) = .{},
    /// MJW: `site_pos`.
    site_pos: ModelTable(.model_f, .site_vectors) = .{},
    /// MJW: `site_quat`.
    site_rot: ModelTable(.model_f, .site_vectors) = .{},
};

/// THE LAYOUT: where every array the kernels read and write lives, one struct per arena, each field named after its
/// arena - `placeArrays` finds an arena's layout by that name.
pub const Layout = extern struct {
    world_f: WorldStateLayout = .{},
    world_u: WorldIntegersLayout = .{},
    model_u: ModelTablesLayout = .{},
    model_f: ModelConstantsLayout = .{},
};

/// What every kernel reads: the counts and the layout, in the uniform.
pub const Params = extern struct {
    counts: Counts,
    layout: Layout,
};

/// Refuse, at compile time, an ARRAY anywhere inside a uniform's struct: a uniform buffer's layout rules align every
/// array element to 16 bytes, so `[3]u32` at offset 52 is invalid there even though Zig lays it out packed - the
/// SPIR-V validator rejects the module. Scalars and nested structs of whole 16-byte rows are what a uniform holds.
fn requireNoArraysInUniform(comptime Struct: type) void {
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
    model_u: u32 = sizes.model_u,
    model_f: u32 = sizes.model_f,
};

/// A layout that does not fit its arena, by the arena's name.
pub const LayoutError = error{
    /// `world_f`: the per-world state of this many worlds of this model needs more floats than the arena holds.
    WorldStateTooSmall,
    /// `world_u`: the per-world integers of this many worlds need more words than the arena holds.
    WorldIntegersTooSmall,
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
        const numbers: u32 = ArrayType.kind.count(counts);
        const stride: u32 = padToVector(numbers);
        const copies: u32 = if (ArrayType.per_world) counts.nworld else 1;
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

// -- THE KERNELS --

const params = g.uniform();

/// CLEAR EVERY WORLD'S OVERFLOW WORD, one invocation per world - the first kernel of every step, so the bits the host
/// reads afterwards are that step's alone.
pub fn clear_overflow(invocation: u32) void {
    const world: u32 = invocation;
    if (world >= params.counts.nworld) {
        return;
    }
    const no_capacity_exceeded: u32 = 0;
    params.layout.world_u.overflow.store(world, 0, no_capacity_exceeded);
}

/// The entries, each its own compute entry point in the SPIR-V.
pub const kernels = [_][:0]const u8{
    "clear_overflow",
};

comptime {
    for (kernels) |name| {
        k.installKernelLean(@This(), name);
    }
}

/// The dofs of `body`'s chain - its own and every ancestor's - by walking up its parents.
fn chainLength(model: *const robot.Model, body: u32) u32 {
    var dofs_on_chain: u32 = 0;
    var ancestor: u32 = body;
    while (ancestor != 0) {
        dofs_on_chain += model.body_dof_num[ancestor];
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

/// A model's counts at `nworld` worlds, read from the model itself - `nchain` summed over its bodies' chains, and the
/// branches over its leaves.
pub fn countsOf(model: *const robot.Model, nworld: u32) Counts {
    var chain_entries: u32 = 0;
    var branch_count: u32 = 0;
    var branch_bodies: u32 = 0;
    var body: u32 = 0;
    while (body < model.nbody) : (body += 1) {
        chain_entries += chainLength(model, body);
        if (isLeaf(model, body)) {
            branch_count += 1;
            branch_bodies += bodyDepth(model, body);
        }
    }
    const counts: Counts = .{
        .nworld = nworld,
        .nbody = model.nbody,
        .njnt = model.njnt,
        .nq = model.nq,
        .nv = model.nv,
        .ngeom = model.ngeom,
        .nu = model.nu,
        .na = model.na,
        .nmass = model.mass_nonzero_count,
        .nchain = chain_entries,
        .nsite = model.nsite,
        .nbranch = branch_count,
        .nbranch_bodies = branch_bodies,
    };
    return counts;
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
    tables.body_jnt_adr.fill(model_u, model.body_jnt_adr);
    tables.body_jnt_num.fill(model_u, model.body_jnt_num);
    tables.body_dof_adr.fill(model_u, model.body_dof_adr);
    tables.body_dof_num.fill(model_u, model.body_dof_num);
    for (model.jnt_type, 0..) |joint_type, joint| {
        model_u[tables.jnt_type.at(@intCast(joint))] = @backingInt(joint_type);
    }
    tables.jnt_body.fill(model_u, model.jnt_body);
    tables.jnt_qpos_adr.fill(model_u, model.jnt_qpos_adr);
    tables.jnt_dof_adr.fill(model_u, model.jnt_dof_adr);
    tables.dof_parent.fill(model_u, model.dof_parent);
    tables.dof_body.fill(model_u, model.dof_body);
    tables.dof_jnt.fill(model_u, model.dof_jnt);
    tables.mass_row_nonzeros.fill(model_u, model.mass_row_nonzeros);
    tables.mass_row_start.fill(model_u, model.mass_row_start);
    tables.mass_col_index.fill(model_u, model.mass_col_index);
    // The chains: each body's ancestors from the root down, then the body, each contributing its dofs in order. The
    // masks start as zeros (`pack` zeroes the image) and gain a bit per chain dof.
    const words_per_mask: u32 = maskWords(model.nv);
    var next_chain_entry: u32 = 0;
    var body: u32 = 0;
    while (body < model.nbody) : (body += 1) {
        const chain_entries: u32 = chainLength(model, body);
        model_u[tables.body_chain_start.at(body)] = next_chain_entry;
        model_u[tables.body_chain_length.at(body)] = chain_entries;
        // Walk up from the body, filling the chain from its end, so the root's dofs land first.
        var chain_fill_end: u32 = next_chain_entry + chain_entries;
        var ancestor: u32 = body;
        while (ancestor != 0) {
            const dof_count: u32 = model.body_dof_num[ancestor];
            const first_dof: u32 = model.body_dof_adr[ancestor];
            chain_fill_end -= dof_count;
            var dof_offset: u32 = 0;
            while (dof_offset < dof_count) : (dof_offset += 1) {
                const dof: u32 = first_dof + dof_offset;
                model_u[tables.chain_dofs.at(chain_fill_end + dof_offset)] = dof;
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
    while (leaf < model.nbody) : (leaf += 1) {
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
    constants.body_pos.fillVectors(model_f, model.body_pos);
    constants.body_rot.fillVectors(model_f, model.body_rot);
    constants.body_ipos.fillVectors(model_f, model.body_ipos);
    for (model.body_inertia, 0..) |inertia, body| {
        const first: u32 = constants.body_inertia.at(@intCast(body));
        model_f[first..][0..4].* = inertia.diag;
        model_f[first + 4 ..][0..4].* = inertia.off;
        model_f[first + 8 ..][0..4].* = inertia.h;
        model_f[first + 12 ..][0..4].* = .{ inertia.mass, 0, 0, 0 };
    }
    constants.body_mass.fill(model_f, model.body_mass);
    constants.body_subtree_mass.fill(model_f, model.body_subtree_mass);
    constants.jnt_axis.fillVectors(model_f, model.jnt_axis);
    constants.jnt_pos.fillVectors(model_f, model.jnt_pos);
    for (model.jnt_range, 0..) |range, joint| {
        const joint_index: u32 = @intCast(joint);
        const limited: bool = range != null;
        const bounds: [2]f32 = range orelse .{ 0, 0 };
        model_f[constants.jnt_range.at(joint_index)..][0..2].* = bounds;
        model_u[tables.jnt_limited.at(joint_index)] = @intFromBool(limited);
    }
    for (model.jnt_limit_softness, model.jnt_limit_impedance, 0..) |softness, impedance, joint| {
        const joint_index: u32 = @intCast(joint);
        const softness_at: u32 = constants.jnt_limit_softness.at(joint_index);
        model_f[softness_at..][0..2].* = .{ softness.time_const_s, softness.damp_ratio };
        const impedance_at: u32 = constants.jnt_limit_impedance.at(joint_index);
        model_f[impedance_at..][0..5].* = .{
            impedance.min,
            impedance.max,
            impedance.width,
            impedance.midpoint,
            impedance.power,
        };
    }
    constants.jnt_limit_margin.fill(model_f, model.jnt_limit_margin);
    constants.jnt_damping.fill(model_f, model.jnt_damping);
    constants.jnt_stiffness.fill(model_f, model.jnt_stiffness);
    constants.jnt_ref.fill(model_f, model.jnt_ref);
    constants.dof_armature.fill(model_f, model.dof_armature);
    constants.geom_pos.fillVectors(model_f, model.geom_pos);
    constants.geom_rot.fillVectors(model_f, model.geom_rot);
    for (model.geom_shape, 0..) |shape, geom| {
        const geom_index: u32 = @intCast(geom);
        model_f[constants.geom_size.at(geom_index)..][0..4].* = geomSize(shape);
        model_u[tables.geom_type.at(geom_index)] = @backingInt(geomType(shape));
    }
    constants.geom_friction.fill(model_f, model.geom_friction);
    tables.geom_body.fill(model_u, model.geom_body);
    constants.site_pos.fillVectors(model_f, model.site_pos);
    constants.site_rot.fillVectors(model_f, model.site_rot);
    tables.site_body.fill(model_u, model.site_body);
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
}
