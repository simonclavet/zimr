//! robotgpu_probe.zig - the first kernels of robotgpu: the native features its plan counts on, each checked on the
//! device against the CPU twin before any physics is written on top of it.
//!
//! -- TWO WAYS TO SUM ACROSS INVOCATIONS --
//!
//! A world's solver needs dot products: sums of many numbers, each computed by its own invocation. A GPU offers two
//! ways to add numbers that live in different invocations, and this file tests both.
//!
//! A SUBGROUP is the set of invocations the device runs in lockstep, side by side in one SIMD unit - 8 on lavapipe,
//! 32 on NVIDIA, 32 or 64 on AMD. One instruction adds a value from each of them and hands the sum back to all of
//! them (`k.subgroupAdd`):
//!
//!     invocation      0    1    2    3    4    5    6    7  |  8    9   ...  15  |  16  ...
//!     value           v0   v1   v2   v3   v4   v5   v6   v7 |  v8   v9  ...  v15 |
//!     after the add   v0 + v1 + ... + v7, in all eight       |  v8 + ... + v15    |
//!
//! A WORKGROUP is larger - 64 invocations here - and its invocations share a small, fast memory. They add through it
//! in halvings, with a barrier after each, so that every invocation sees the others' writes before reading them:
//!
//!     start          partial[0..63] = the 64 values
//!     width 32       partial[i] += partial[i + 32]   for i < 32        barrier
//!     width 16       partial[i] += partial[i + 16]   for i < 16        barrier
//!     ...
//!     width 1        partial[0] += partial[1]                          barrier
//!     end            partial[0] is the sum - six halvings for 64 values
//!
//! On the CPU twin, which runs one invocation after another, each sum is a plain loop over the same values, in order.
//! The device adds in an order of its own, so device and twin agree within the rounding a reordering can cause. The
//! device must agree with ITSELF exactly, run after run: the plan's condition (D7) for letting a reduction feed a
//! simulation's state, where an inexact repeat would make every rerun a different trajectory.
//!
//! The twin needs the device's subgroup size (`Params.subgroup_size`, from the host's `ComputeCapabilities`), and
//! takes a subgroup to be consecutive invocations, as devices lay them out in a one-dimensional workgroup - an
//! assumption the device check confirms by matching.
//!
//! -- THE MATHS ROBOT.ZIG USES, ON THE DEVICE --
//!
//! `maths` calls every zimrmath function robot.zig's per-element arithmetic calls - the quaternion product and
//! conjugate, rotating a vector, a rotation from an axis and an angle (the axis unit or not), normalising a vector,
//! its length, the cross and dot products, atan2 and acos - one invocation per row of a table of inputs:
//!
//!     a row's inputs (16 floats)                          a row's results (32 floats)
//!       0  rotation        a unit quaternion (x y z w)      0  qmul(rotation, other)
//!       4  other           any quaternion                   4  conjugate(rotation)
//!       8  vector          x y z, w = 0                     8  rotate(rotation, vector)
//!      12  angle           radians                         12  quatFromNormAxisAngle(normalize3(vector), angle)
//!                                                          16  quatFromAxisAngle(vector, angle)
//!                                                          20  normalize3(vector)
//!                                                          24  cross(vector, other)
//!                                                          28  dot3(vector, other), length3(vector),
//!                                                              atan2Rad(vector.y, vector.x), acosRad(the cosine
//!                                                              between vector and other)
//!
//! The device and the twin run the same Zig. They differ only where zimrmath chooses another formula on the GPU - its
//! sine and cosine are polynomials there, exact library calls on the CPU - and where the device's compiler fuses a
//! multiplication into an addition; the device check measures each function's difference in units of f32's epsilon.
//! Several of these functions assert (`normalize3`, `quatFromAxisAngle`): building this file is also the check that
//! zimrmath's assertions compile for the GPU (`zimrmath.assertfOnGpu`).
//!
//! -- ROBOT.ZIG'S SPATIAL ALGEBRA, ON THE DEVICE --
//!
//! `spatial` calls robot.zig's own functions on six-dimensional quantities - a MOTION (an angular and a linear
//! velocity), a FORCE (a torque and a force), a body's spatial INERTIA (its mass, its first moment `h` = mass x the
//! centre of mass, and the ten-number rotational inertia `diag` and `off`) - the very functions the CPU engine runs,
//! robot.zig imported as a module of this kernel (`ShaderPipeline.KernelModules.robot`):
//!
//!     a row's inputs (48 floats)                      a row's results (56 floats)
//!       0  velocity    a Motion (ang, lin)              0  crossMotion(velocity, motion)      a Motion
//!       8  motion      a Motion                         8  crossForce(velocity, force)        a Force
//!      16  force       a Force                         16  inertia.mul(motion)                a Force
//!      24  inertia     diag, off, h, mass (13)         24  inertia.translate(offset)          an Inertia (13)
//!      40  rotation    a unit quaternion               40  inertia.rotated(rotation)          an Inertia (13)
//!      44  offset      a vector, w = 0                 53  dot6(motion, force)

const k = @import("kompute");
const zm = @import("zm");
const FieldEnum = @import("std").meta.FieldEnum;
/// robot.zig, a module of its own: the kernel's on the GPU (`ShaderPipeline.KernelModules.robot`), the engine's on
/// the CPU twin - one module either way.
const robot = @import("robot");
const Motion = robot.Motion;
const Force = robot.Force;
const Inertia = robot.Inertia;
const Vec = zm.Vec;
const Quat = zm.Quat;
const acosRad = zm.acosRad;
const atan2Rad = zm.atan2Rad;
const clamp = zm.clamp;
const cross = zm.cross;
const dot3 = zm.dot3;
const length3 = zm.length3;
const normalize3 = zm.normalize3;

/// 64 invocations a workgroup: a whole number of subgroups on every device (8 on lavapipe, 32 or 64 elsewhere). A
/// LARGE DISPATCH (`k.Config.large_dispatch`): up to 2^23 invocations, past the 65,535 x 64 one row of workgroups
/// holds - `dispatch_tally` checks the rows. The buffers keep sizes of their own (`table_capacity`).
pub const config = k.Config{
    .max = 1 << 23,
    .workgroup = 64,
    .large_dispatch = true,
    .readback = .ranges,
    // Small on purpose: 1,024 floats a chunk, so the device test's ranges cross chunk boundaries.
    .staging_bytes = 4096,
};

/// The floats each table buffer holds.
pub const table_capacity: u32 = 1 << 16;

pub const Buffers = extern struct {
    /// The numbers to sum, one per invocation.
    values: [table_capacity]f32,
    /// The sums: one per invocation for `subgroup_sum`, one per workgroup for `workgroup_sum`.
    sums: [table_capacity]f32,
    /// The maths probe's table: `rowWidth(MathsInputs)` floats a row in, `rowWidth(MathsResults)` a row out.
    maths_inputs: [table_capacity]f32,
    maths_outputs: [table_capacity]f32,
    /// The spatial probe's table: `rowWidth(SpatialInputs)` floats a row in, `rowWidth(SpatialResults)` a row out.
    spatial_inputs: [table_capacity]f32,
    spatial_outputs: [table_capacity]f32,
    /// `dispatch_tally`'s two counters: how many invocations ran, and the sum of their indices' low sixteen bits.
    dispatch_tally: [2]u32,
    /// `write_pushed`'s regions, each filled with the value its dispatch pushed.
    pushed_words: [table_capacity]u32,
};

/// A ROW OF A PROBE TABLE IS A TYPE: an extern struct of f32 arrays, laid out exactly as its floats lie in the table's
/// buffer - row after row, field after field. The kernel reads and writes each field at its offset from the row's
/// start, and the device check fills and compares through the same declarations: nothing about a row is counted by
/// hand twice. These three give a field's place and size, and a row's, in floats.
pub fn floatOffset(comptime Row: type, comptime field: FieldEnum(Row)) u32 {
    return @offsetOf(Row, @tagName(field)) / @sizeOf(f32);
}

pub fn floatWidth(comptime Row: type, comptime field: FieldEnum(Row)) u32 {
    return @sizeOf(@FieldType(Row, @tagName(field))) / @sizeOf(f32);
}

pub fn rowWidth(comptime Row: type) u32 {
    return @sizeOf(Row) / @sizeOf(f32);
}

/// The maths table's inputs, one row (this file's head draws it). The vector and the second quaternion are never
/// zero: `normalize3` asserts it, and the table is built so.
pub const MathsInputs = extern struct {
    /// A unit quaternion (x y z w).
    rotation: [4]f32,
    /// Any quaternion.
    other: [4]f32,
    /// x y z, w = 0.
    vector: [4]f32,
    /// In radians.
    angle: f32,
    _padding: [3]f32,
};

/// The maths table's results, one row: seven of four floats, then four scalars.
pub const MathsResults = extern struct {
    product: [4]f32,
    conjugated: [4]f32,
    rotated: [4]f32,
    from_unit_axis: [4]f32,
    from_axis: [4]f32,
    normalized: [4]f32,
    crossed: [4]f32,
    dot_product: f32,
    vector_length: f32,
    heading: f32,
    angle_between: f32,
};

/// A Motion or a Force as eight floats: its angular part, then its linear part, each a vector with its w.
pub const PairFloats = extern struct {
    angular: [4]f32,
    linear: [4]f32,
};

/// An Inertia as thirteen floats: `diag`, `off` and `h`, each a vector with its w, then the mass.
pub const InertiaFloats = extern struct {
    diag: [4]f32,
    off: [4]f32,
    h: [4]f32,
    mass: f32,
};

/// The spatial table's inputs, one row (this file's head draws it).
pub const SpatialInputs = extern struct {
    velocity: PairFloats,
    motion: PairFloats,
    force: PairFloats,
    inertia: InertiaFloats,
    _padding: [3]f32,
    /// A unit quaternion.
    rotation: [4]f32,
    /// x y z, w = 0.
    offset: [4]f32,
};

/// The spatial table's results, one row.
pub const SpatialResults = extern struct {
    motion_cross: PairFloats,
    force_cross: PairFloats,
    inertia_times_motion: PairFloats,
    translated: InertiaFloats,
    _padding_after_translated: [3]f32,
    rotated: InertiaFloats,
    power: f32,
    _padding: [2]f32,
};

/// How many values there are; the device's subgroup size, for the twin's partition. Padded to 16 bytes.
pub const Params = extern struct {
    value_count: u32,
    subgroup_size: u32,
    /// The maths probe's rows.
    maths_rows: u32 = 0,
    /// The spatial probe's rows.
    spatial_rows: u32 = 0,
    /// The invocations `dispatch_tally` counts. Padded to 32 bytes.
    tally_count: u32 = 0,
    /// The words of one `write_pushed` region.
    pushed_region_size: u32 = 0,
    /// `cholesky`'s matrices: their order (at most `max_matrix_order`) and how many.
    matrix_order: u32 = 0,
    matrix_count: u32 = 0,
};

pub const g = k.Globals(@This());
const values = g.bind(.values);
const sums = g.bind(.sums);
const maths_inputs = g.bind(.maths_inputs);
const maths_outputs = g.bind(.maths_outputs);
const spatial_inputs = g.bind(.spatial_inputs);
const spatial_outputs = g.bind(.spatial_outputs);
const tally_words = g.bind(.dispatch_tally);
const pushed_words = g.bind(.pushed_words);
/// The push constants, bound once here as `params` is (`g.push()`'s documentation says why).
const pushed = g.push();
const params = g.uniform();

/// One workgroup's partial sums, halved toward the total at each barrier (`workgroup_sum`).
const partial_sums = k.shared(f32, config.workgroup, "robotgpu_probe_partial_sums");

/// SUBGROUP SUM, ONE INVOCATION PER VALUE: sums[i] = the sum of the values of invocation i's subgroup, values past
/// `value_count` counting as 0. Every invocation reaches the add - the guard is on reading and writing, never around
/// the call: a subgroup operation, like a barrier, needs every invocation of the subgroup to take part.
pub fn subgroup_sum(invocation: u32) void {
    const holds_a_value: bool = invocation < params.value_count;
    const own_value: f32 = if (holds_a_value) values[invocation] else 0.0;
    var subgroup_total: f32 = 0.0;
    if (k.is_gpu) {
        subgroup_total = k.subgroupAdd(own_value);
    } else {
        // The twin: the subgroup is `subgroup_size` consecutive invocations, the first at a multiple of the size.
        const subgroup_size: u32 = params.subgroup_size;
        const lane: u32 = invocation % subgroup_size;
        const first_of_subgroup: u32 = invocation - lane;
        var member: u32 = 0;
        while (member < subgroup_size) : (member += 1) {
            const member_invocation: u32 = first_of_subgroup + member;
            const member_holds_a_value: bool = member_invocation < params.value_count;
            if (member_holds_a_value) {
                subgroup_total += values[member_invocation];
            }
        }
    }
    if (holds_a_value) {
        sums[invocation] = subgroup_total;
    }
}

/// WORKGROUP SUM, ONE INVOCATION PER VALUE: sums[w] = the sum of workgroup w's 64 values, values past `value_count`
/// counting as 0, written by its first invocation. On the device the values are halved toward their total through
/// shared memory (this file's head); every invocation reaches every barrier, and only the adds are guarded.
pub fn workgroup_sum(invocation: u32) void {
    const workgroup_size: u32 = config.workgroup;
    const lane: u32 = invocation % workgroup_size;
    const workgroup: u32 = invocation / workgroup_size;
    const holds_a_value: bool = invocation < params.value_count;
    var workgroup_total: f32 = 0.0;
    if (k.is_gpu) {
        partial_sums[lane] = if (holds_a_value) values[invocation] else 0.0;
        k.workgroupBarrier();
        var width: u32 = workgroup_size / 2;
        while (width > 0) : (width /= 2) {
            const adds_this_round: bool = lane < width;
            if (adds_this_round) {
                partial_sums[lane] += partial_sums[lane + width];
            }
            k.workgroupBarrier();
        }
        workgroup_total = partial_sums[0];
    } else if (lane == 0) {
        // The twin: the first invocation adds its workgroup's values in order.
        var member: u32 = 0;
        while (member < workgroup_size) : (member += 1) {
            const member_invocation: u32 = invocation + member;
            const member_holds_a_value: bool = member_invocation < params.value_count;
            if (member_holds_a_value) {
                workgroup_total += values[member_invocation];
            }
        }
    }
    const first_value_of_workgroup: u32 = workgroup * workgroup_size;
    const workgroup_holds_a_value: bool = first_value_of_workgroup < params.value_count;
    if (lane == 0 and workgroup_holds_a_value) {
        sums[workgroup] = workgroup_total;
    }
}

/// The probe's buffers, by name: which one a load or store helper reads or writes (`loadVector`).
const Field = FieldEnum(Buffers);

/// Four floats of the buffer `field` as a vector, from `at`. The buffer is a COMPILE-TIME parameter: the helper is made
/// once per buffer, and each copy reaches its binding as a compile-time constant (`comptime g.bind(field)`, as a
/// binding bound at module scope is) - never as a pointer passed at run time, since a SPIR-V function parameter
/// pointing into a storage buffer needs a capability (VariablePointers) the Vulkan host does not enable.
fn loadVector(comptime field: Field, at: u32) Vec {
    const loaded: Vec = .{
        (comptime g.bind(field))[at],
        (comptime g.bind(field))[at + 1],
        (comptime g.bind(field))[at + 2],
        (comptime g.bind(field))[at + 3],
    };
    return loaded;
}

/// A vector's four lanes into the buffer `field`, from `at` (the binding a compile-time constant, as in `loadVector`).
fn storeVector(comptime field: Field, at: u32, vector: Vec) void {
    (comptime g.bind(field))[at] = vector[0];
    (comptime g.bind(field))[at + 1] = vector[1];
    (comptime g.bind(field))[at + 2] = vector[2];
    (comptime g.bind(field))[at + 3] = vector[3];
}

/// THE MATHS PROBE, ONE INVOCATION PER ROW: every zimrmath function robot.zig's arithmetic calls, on the row's inputs,
/// into the row's results (`MathsInputs`, `MathsResults`; this file's head draws both). No barrier and no subgroup
/// operation, so a row past the table simply returns.
pub fn maths(row: u32) void {
    if (row >= params.maths_rows) {
        return;
    }
    const inputs_at: u32 = row * rowWidth(MathsInputs);
    const results_at: u32 = row * rowWidth(MathsResults);
    const rotation: Quat = loadVector(.maths_inputs, inputs_at + floatOffset(MathsInputs, .rotation));
    const other: Quat = loadVector(.maths_inputs, inputs_at + floatOffset(MathsInputs, .other));
    const vector: Vec = loadVector(.maths_inputs, inputs_at + floatOffset(MathsInputs, .vector));
    const angle_rad: f32 = maths_inputs[inputs_at + floatOffset(MathsInputs, .angle)];
    // The four-float results.
    const unit_vector: Vec = normalize3(vector);
    const product: Quat = zm.qmul(rotation, other);
    const conjugated: Quat = zm.conjugate(rotation);
    const rotated: Vec = zm.rotate(rotation, vector);
    const from_unit_axis: Quat = zm.quatFromNormAxisAngle(unit_vector, angle_rad);
    const from_axis: Quat = zm.quatFromAxisAngle(vector, angle_rad);
    const crossed: Vec = cross(vector, other);
    storeVector(.maths_outputs, results_at + floatOffset(MathsResults, .product), product);
    storeVector(.maths_outputs, results_at + floatOffset(MathsResults, .conjugated), conjugated);
    storeVector(.maths_outputs, results_at + floatOffset(MathsResults, .rotated), rotated);
    storeVector(.maths_outputs, results_at + floatOffset(MathsResults, .from_unit_axis), from_unit_axis);
    storeVector(.maths_outputs, results_at + floatOffset(MathsResults, .from_axis), from_axis);
    storeVector(.maths_outputs, results_at + floatOffset(MathsResults, .normalized), unit_vector);
    storeVector(.maths_outputs, results_at + floatOffset(MathsResults, .crossed), crossed);
    // The scalars: a product, a length, and two angles - the heading of the vector in its xy plane, and the angle
    // between the two directions, acos of their cosine kept in [-1, 1] as robot.zig keeps it before acos.
    const unit_other: Vec = normalize3(other);
    const cosine_between: f32 = clamp(dot3(unit_vector, unit_other), -1.0, 1.0);
    maths_outputs[results_at + floatOffset(MathsResults, .dot_product)] = dot3(vector, other);
    maths_outputs[results_at + floatOffset(MathsResults, .vector_length)] = length3(vector);
    maths_outputs[results_at + floatOffset(MathsResults, .heading)] = atan2Rad(vector[1], vector[0]);
    maths_outputs[results_at + floatOffset(MathsResults, .angle_between)] = acosRad(cosine_between);
}

/// A Motion from the spatial inputs at `at`: its angular part, then its linear part.
fn loadMotion(at: u32) Motion {
    const angular: Vec = loadVector(.spatial_inputs, at + floatOffset(PairFloats, .angular));
    const linear: Vec = loadVector(.spatial_inputs, at + floatOffset(PairFloats, .linear));
    const loaded: Motion = .{ .ang = angular, .lin = linear };
    return loaded;
}

/// A Force from the spatial inputs at `at`, laid out as a Motion is.
fn loadForce(at: u32) Force {
    const angular: Vec = loadVector(.spatial_inputs, at + floatOffset(PairFloats, .angular));
    const linear: Vec = loadVector(.spatial_inputs, at + floatOffset(PairFloats, .linear));
    const loaded: Force = .{ .ang = angular, .lin = linear };
    return loaded;
}

/// An Inertia from the spatial inputs at `at`: diag, off, h, then the mass.
fn loadInertia(at: u32) Inertia {
    const diag: Vec = loadVector(.spatial_inputs, at + floatOffset(InertiaFloats, .diag));
    const off: Vec = loadVector(.spatial_inputs, at + floatOffset(InertiaFloats, .off));
    const h: Vec = loadVector(.spatial_inputs, at + floatOffset(InertiaFloats, .h));
    const mass: f32 = spatial_inputs[at + floatOffset(InertiaFloats, .mass)];
    const loaded: Inertia = .{ .diag = diag, .off = off, .h = h, .mass = mass };
    return loaded;
}

/// A Motion's or a Force's two parts into the spatial results at `at`.
fn storePair(at: u32, angular: Vec, linear: Vec) void {
    storeVector(.spatial_outputs, at + floatOffset(PairFloats, .angular), angular);
    storeVector(.spatial_outputs, at + floatOffset(PairFloats, .linear), linear);
}

/// An Inertia's thirteen floats into the spatial results at `at`.
fn storeInertia(at: u32, inertia: Inertia) void {
    storeVector(.spatial_outputs, at + floatOffset(InertiaFloats, .diag), inertia.diag);
    storeVector(.spatial_outputs, at + floatOffset(InertiaFloats, .off), inertia.off);
    storeVector(.spatial_outputs, at + floatOffset(InertiaFloats, .h), inertia.h);
    spatial_outputs[at + floatOffset(InertiaFloats, .mass)] = inertia.mass;
}

/// THE SPATIAL PROBE, ONE INVOCATION PER ROW: robot.zig's spatial algebra - the two cross products, an inertia
/// times a motion, an inertia moved to a new origin and turned by a rotation, the power of a force on a motion - on
/// the row's inputs, into the row's results (`SpatialInputs`, `SpatialResults`; this file's head draws both).
pub fn spatial(row: u32) void {
    if (row >= params.spatial_rows) {
        return;
    }
    const inputs_at: u32 = row * rowWidth(SpatialInputs);
    const results_at: u32 = row * rowWidth(SpatialResults);
    const velocity: Motion = loadMotion(inputs_at + floatOffset(SpatialInputs, .velocity));
    const motion: Motion = loadMotion(inputs_at + floatOffset(SpatialInputs, .motion));
    const force: Force = loadForce(inputs_at + floatOffset(SpatialInputs, .force));
    const inertia: Inertia = loadInertia(inputs_at + floatOffset(SpatialInputs, .inertia));
    const rotation: Quat = loadVector(.spatial_inputs, inputs_at + floatOffset(SpatialInputs, .rotation));
    const offset: Vec = loadVector(.spatial_inputs, inputs_at + floatOffset(SpatialInputs, .offset));
    const motion_cross: Motion = robot.crossMotion(velocity, motion);
    const force_cross: Force = robot.crossForce(velocity, force);
    const inertia_times_motion: Force = inertia.mul(motion);
    const translated: Inertia = inertia.translate(offset);
    const rotated: Inertia = inertia.rotated(rotation);
    const power: f32 = robot.dot6(motion, force);
    storePair(results_at + floatOffset(SpatialResults, .motion_cross), motion_cross.ang, motion_cross.lin);
    storePair(results_at + floatOffset(SpatialResults, .force_cross), force_cross.ang, force_cross.lin);
    const inertia_times_motion_at: u32 = results_at + floatOffset(SpatialResults, .inertia_times_motion);
    storePair(inertia_times_motion_at, inertia_times_motion.ang, inertia_times_motion.lin);
    storeInertia(results_at + floatOffset(SpatialResults, .translated), translated);
    storeInertia(results_at + floatOffset(SpatialResults, .rotated), rotated);
    spatial_outputs[results_at + floatOffset(SpatialResults, .power)] = power;
}

/// DISPATCH TALLY, ONE INVOCATION PER INDEX: every invocation below `tally_count` adds one to the first counter and its
/// index's low sixteen bits to the second. A dispatch that ran every index exactly once - across all its rows of
/// workgroups (`k.Config.large_dispatch`) - leaves the count and a sum the host can work out for itself.
pub fn dispatch_tally(invocation: u32) void {
    if (invocation >= params.tally_count) {
        return;
    }
    const low_bits: u32 = invocation & 0xffff;
    _ = k.atomicAdd(tally_words, 0, 1);
    _ = k.atomicAdd(tally_words, 1, low_bits);
}

/// The probe's PUSH CONSTANTS: where `write_pushed` writes, and what - set for each dispatch by the host
/// (`compute_host.runPushed`), with no buffer.
pub const PushConstants = extern struct {
    region_start: u32,
    value: u32,
    /// `busy_work`'s rounds for each value.
    iterations: u32 = 0,
    _padding: u32 = 0,
};

/// PUSHED WRITE, ONE INVOCATION PER WORD OF A REGION: the pushed `value` into the `pushed_region_size` words from the
/// pushed `region_start`. Dispatched several times in one batch - one `Params` for all of them - each with its own
/// push, it fills each region with its own value: the per-dispatch parameter push constants carry.
pub fn write_pushed(invocation: u32) void {
    if (invocation >= params.pushed_region_size) {
        return;
    }
    const region_start: u32 = pushed.region_start;
    const value: u32 = pushed.value;
    const at: u32 = region_start + invocation;
    pushed_words[at] = value;
}

/// BUSY WORK, ONE INVOCATION PER VALUE: the pushed number of rounds of arithmetic on the invocation's value - a loop
/// whose length the host chooses for each dispatch, so the same dispatch can do one, four or any number of times the
/// work, which is what a check of the GPU's timings needs. The result goes to `sums`, so the loop cannot be dropped.
pub fn busy_work(invocation: u32) void {
    if (invocation >= params.value_count) {
        return;
    }
    const rounds: u32 = pushed.iterations;
    var state: f32 = values[invocation];
    var round_index: u32 = 0;
    while (round_index < rounds) : (round_index += 1) {
        state = state * 0.999 + 0.5;
    }
    sums[invocation] = state;
}

/// The largest matrix `cholesky` factors: 76 x 76, the size of Geno's Newton Hessian (75 degrees of freedom, and one
/// more), 23 KB of shared memory - inside the 32 KB of the least device.
pub const max_matrix_order: u32 = 76;

/// One workgroup's matrix, factored in place (`cholesky`).
const shared_matrix = k.shared(f32, max_matrix_order * max_matrix_order, "robotgpu_probe_matrix");

/// CHOLESKY, ONE WORKGROUP PER MATRIX: the symmetric positive-definite matrix `values[m]` (row-major, `matrix_order`
/// rows) factored into `L L^T`, L written over the lower triangle of `sums[m]`, the upper triangle left as it was -
/// as robot.zig's `choleskyFactor` leaves it. The shape of robotgpu's solver: one world's Hessian in shared memory,
/// the workgroup's 64 invocations factoring it together, column by column:
///
///     for each column c:
///       1. the pivot      L[c][c] = sqrt(a[c][c])                    one invocation          barrier
///       2. the column     L[i][c] = a[i][c] / L[c][c],  i > c         rows spread over lanes  barrier
///       3. the update     a[i][j] -= L[i][c] * L[j][c], c < j <= i    rows spread over lanes  barrier
///
/// Each a[i][j] loses its products L[i][c] L[j][c] one column at a time, in ascending c - the very order
/// `choleskyFactor` subtracts them in, row by row - so the device and the twin do the same arithmetic, apart from a
/// multiply the GPU's compiler may fuse into the subtraction. The loop bounds are uniform (the order comes from
/// `Params`) and no barrier sits inside a lane-dependent loop, so every invocation reaches every barrier. The twin:
/// the workgroup's first invocation copies the matrix and factors it with robot.zig's own function.
pub fn cholesky(invocation: u32) void {
    const workgroup_size: u32 = config.workgroup;
    const lane: u32 = invocation % workgroup_size;
    const matrix_index: u32 = invocation / workgroup_size;
    // The same for the whole workgroup, so a workgroup past the matrices leaves together - uniform control flow.
    if (matrix_index >= params.matrix_count) {
        return;
    }
    const order: u32 = params.matrix_order;
    const element_count: u32 = order * order;
    const matrix_start: u32 = matrix_index * element_count;
    if (k.is_gpu) {
        var element: u32 = lane;
        while (element < element_count) : (element += workgroup_size) {
            shared_matrix[element] = values[matrix_start + element];
        }
        k.workgroupBarrier();
        var column: u32 = 0;
        while (column < order) : (column += 1) {
            const pivot_at: u32 = column * order + column;
            if (lane == 0) {
                shared_matrix[pivot_at] = @sqrt(shared_matrix[pivot_at]);
            }
            k.workgroupBarrier();
            const pivot: f32 = shared_matrix[pivot_at];
            var column_row: u32 = column + 1 + lane;
            while (column_row < order) : (column_row += workgroup_size) {
                const below_pivot_at: u32 = column_row * order + column;
                shared_matrix[below_pivot_at] = shared_matrix[below_pivot_at] / pivot;
            }
            k.workgroupBarrier();
            var update_row: u32 = column + 1 + lane;
            while (update_row < order) : (update_row += workgroup_size) {
                const row_factor: f32 = shared_matrix[update_row * order + column];
                var update_column: u32 = column + 1;
                while (update_column <= update_row) : (update_column += 1) {
                    const column_factor: f32 = shared_matrix[update_column * order + column];
                    const updated_at: u32 = update_row * order + update_column;
                    shared_matrix[updated_at] = shared_matrix[updated_at] - row_factor * column_factor;
                }
            }
            k.workgroupBarrier();
        }
        element = lane;
        while (element < element_count) : (element += workgroup_size) {
            sums[matrix_start + element] = shared_matrix[element];
        }
    } else if (lane == 0) {
        const factored: []f32 = sums[matrix_start..][0..element_count];
        @memcpy(factored, values[matrix_start..][0..element_count]);
        _ = robot.choleskyFactor(factored, order);
    }
}

/// The entries, each its own compute entry point in the SPIR-V (`installKernelLean`).
pub const kernels = [_][:0]const u8{
    "subgroup_sum",
    "workgroup_sum",
    "maths",
    "spatial",
    "dispatch_tally",
    "write_pushed",
    "busy_work",
    "cholesky",
};

comptime {
    for (kernels) |name| {
        k.installKernelLean(@This(), name);
    }
}
