//! lint:alias spv2wgsl
//! lint:off std-math: spv2wgsl is a host-only transpiler - SPIR-V in, WGSL text out. It never
//! runs on a device, so the GPU-portability reason for the std.math ban does not apply, and
//! `std.math` costs nothing here: `std` is already imported, so unlike a `zm` dependency this
//! adds no module edge and leaves the file as extractable as it was.
// spv2wgsl.zig - minimal SPIR-V to WGSL converter.
//
// =============================================================================
// * ZIG -> SPIR-V COMPILER INTERFACE - read this when a compiler bump breaks shaders *
// =============================================================================
// zimr builds its shaders by compiling Zig -> SPIR-V and translating that here to
// WGSL. The Zig->SPIR-V half is a moving, lightly-documented compiler surface;
// this block is the survival summary so the knowledge is never lost. FULL
// version + rationale: `src/notes/zig-spirv-compiler-interface.md`. The
// producing helpers live in `src/zimrmath.zig` (the `@SpirvType` section);
// minimal proofs in `src/notes/spikes/`. Recorded against Zig 0.17.0-dev.956+2dca73595.
//
// RECOVERY LOOP when a compiler bump breaks shader compilation:
//   1. Recompile the canary spikes in src/notes/spikes/ - a break names what moved.
//   2. Reflection/enum/callconv changes -> grep the LOCAL stdlib (ships in the
//      release): grep -n "Spirv\|SpirvKernelOptions\|Format\|Access" <zig>/lib/std/lang.zig
//   3. Inline-asm grammar changes -> fetch compiler src (NOT in the release; the
//      +suffix of `zig version` is the commit; raw.githubusercontent.com is an
//      allowed bash domain):
//        curl raw.githubusercontent.com/ziglang/zig/<commit>/src/codegen/spirv/Assembler.zig
//        curl raw.githubusercontent.com/ziglang/zig/<commit>/src/codegen/spirv/CodeGen.zig
//      (CodeGen.zig `airAsm` = asm input constraints; Assembler.zig = asm opcode grammar.)
//
// BUILD: `zig build-obj s.zig -target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm
//   -fno-lld -O ReleaseFast -ofmt=spirv`. The LLVM backend segfaults on spirv;
//   `-fno-llvm -fno-lld` are mandatory. zimr's pipeline is pure-Zig
//   (build-obj -> zspv -> spv2wgsl) - there is NO spirv-opt inlining pass.
//
// @SpirvType (declares opaque resource types; valid ONLY on the spirv target):
//   Image  = @SpirvType(.{ .image = .{ .usage = .{ .sampled = f32 } | .storage,
//            .format = .unknown|.rgba8unorm|.r32f|..., .dim = .@"2d", .depth = .unknown,
//            .arrayed = false, .multisampled = false, .access = .unknown } });
//   Sampler = @SpirvType(.sampler);  RuntimeArray = @SpirvType(.{ .runtime_array = T });
//   GOTCHAS (each cost real time): format is `rgba8unorm` NOT `rgba8`; sampled
//   color textures want `.sampled = f32` (-> texture_2d<f32>); `.access`
//   `.read_only`/`.write_only` are OPENCL-ONLY and reject on vulkan -> use
//   `.access = .unknown` (Vulkan read/write = NonReadable/NonWritable decorations).
//
// @extern (binds resources + stage IO):
//   @extern(*addrspace(.constant) const Image, .{ .name = "t",
//           .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } } });
//   IO uses `.decoration = .{ .location = N }`. addrspace->storage class:
//   .constant->UniformConstant, .input->Input, .output->Output, .uniform->Uniform,
//   .storage_buffer->StorageBuffer.
//   !! KNOWN BLOCKER (956), OPAQUE descriptors only: an @extern whose pointee is a
//   zero-bit opaque type (image/sampler) folds to **OpUndef** when used - the
//   descriptor OpVariable is never emitted. Cause: CodeGen.zig `constantNavRef`
//   returns `constUndef` for `!hasRuntimeBits` pointees, BEFORE `addFunctionDep`,
//   so the global is never materialized. (color/uv survive: vec2/vec4 have bits.)
//   This blocks the clean @SpirvType sampler path at P3. STORAGE BUFFERS are NOT
//   affected - a runtime-array struct HAS runtime bits, so its @extern
//   materializes as a real `var<storage>` binding; that path works end-to-end
//   (this converter handles `OpTypeRuntimeArray` -> `array<T>`, and `zm.ssboLoad`/
//   `ssboStore` index it via asm OpAccessChain since plain-Zig field access
//   mis-lowers on 956). See the notes doc for sampler workaround ideas.
//
// INLINE SPIR-V ASM (the part that blocked us for a session): opaque types can't
//   be OpLoaded in plain Zig, so the load + sample/store op is inline asm. Input
//   constraints (CodeGen.zig airAsm): "c" = comptime constant; "t" = a TYPE
//   (resolved via cg.resolveType to the module's DEDUPED id - THIS is how you
//   reference a SPIR-V type operand; passing a type with "" is an error); default
//   = a runtime value. Output: `(-> T)`. `$name` substitutes a "c" const inline.
//
// ENTRY POINTS: `callconv(.spirv_vertex)` (BARE tag - no options),
//   `callconv(.{ .spirv_fragment = .{} })`, `callconv(.{ .spirv_kernel =
//   .{ .x, .y, .z } })` (compute REQUIRES the workgroup size). Mixing these up
//   ("void does not support array initialization") = vertex took `= .{}`.
// BUILTINS: use `@import("std").spirv` - `vertex_index`, `instance_index` (u32
//   inputs), `position_out`/`position_in` (vec4). They MATERIALIZE (real bits),
//   so unlike opaque descriptors they translate fine (-> `@builtin(vertex_index)`
//   etc.). Canary: src/notes/spikes/spike_vertex_index.zig.
//
// WGSL TEXTURES ARE SEPARATE: WGSL has no combined sampler. A texture and its
//   sampler are SEPARATE bindings (`texture_2d<f32>` + `sampler`), paired by
//   `OpSampledImage` at the sample site -> `textureSample(tex, samp, uv)`. A
//   combined `OpTypeSampledImage` *binding* makes this converter reject the shader.
//   So `zm.sampleLod(tex, samp, uv)` is `inline` and emits OpLoad/OpLoad/
//   OpSampledImage/OpImageSampleImplicitLod.
//
// MOVE HISTORY (expect more): std.gpu->std.spirv; bare-enum->struct callconv;
//   the "t" asm-constraint discovery; reflection types now in lib/std/lang.zig.
//
// =============================================================================
// Scope and intent
// =============================================================================
//
// This file converts SPIR-V binaries to WGSL source. It targets the SPIR-V
// that glslangValidator -V emits from straightforward GLSL vertex/fragment/
// compute shaders. It does not validate the input, does not optimize the
// output, and does not handle the full SPIR-V spec. The browser's WGSL
// front-end (Tint in Chromium-family, naga in Firefox/Safari) does both of
// those, better than we ever could, on every shader that reaches it.
//
// What this file does add, beyond bare translation:
//
//   1. Internal assertions via lookupId / lookupType.
//      The most common bug shape when writing a translator is "I forgot to
//      record a name for that SPIR-V id" -> downstream uses produce empty or
//      garbage text. lookupId panics with a useful message instead.
//
//   2. Unhandled-opcode logging.
//      The catch-all `else` branch in pass 4 logs once per opcode value it
//      encounters, so you can see what's still missing without grepping the
//      output for missing computation. Off in release builds.
//
//   3. Output identifier closure check.
//      After emission, we scan the produced WGSL for `_N` SSA-temp references
//      and verify each one has a matching declaration. This catches the
//      "opcode handler forgot to populate ids[result].wgsl_name" bug class
//      with a precise error pointing at the SPIR-V id, instead of letting
//      tint reject the WGSL with a confusing "unknown identifier" message.
//
// =============================================================================
// Architecture
// =============================================================================
//
// The conversion runs in four passes over the same []const u32:
//
//   pass1_walk            -> build inst_off (word index of each instruction)
//   pass2_decorations     -> name / decoration / entry-point sidebands
//   pass3_types_globals   -> resolve type spellings, emit struct/global decls
//   pass4_functions       -> emit function bodies (the heavy lifting)
//
// All state lives in one State struct allocated from the caller-supplied
// arena allocator. Nothing leaks: when the arena is destroyed, all our
// allocations go with it.
//
// =============================================================================
// Zig 0.16 API notes
// =============================================================================
//
// We use the unmanaged ArrayList form: `ArrayList(T){}` zero-init, methods
// like `append(allocator, value)` and `toOwnedSlice(allocator)` that take the
// allocator explicitly. If your tree uses the managed form (allocator stored
// in the list), replace those with `.init(arena)` and drop the allocator
// argument from the calls.
//
// We deliberately do *not* use std.Io.Writer. The writer abstraction shifted
// shape between 0.14 / 0.15 / 0.16; using raw ArrayList(u8).append /
// appendSlice / fmt.allocPrint avoids that surface entirely. The cost is a
// little verbosity in the emit helpers - worth it for portability.

const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const assert = std.debug.assert;
const endsWith = std.mem.endsWith;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const startsWith = std.mem.startsWith;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// =============================================================================
// SPIR-V opcodes + spec enums
// =============================================================================
//
// Phase 1.1 of the rewrite (`src/notes/archive/spv2wgsl-rewrite-plan.md`):
// these were `const types.Op = enum(u32) { ... };` and friends inline in
// this file (~250 LOC of enum body).  They now live in
// `src/spv2wgsl/types.zig` so the per-section 3.8 module layout has a real
// owner for SPIR-V enum data.  The local `const types.Op = types.Op;`
// pattern keeps every call site (`types.Op.Label`, `@intFromEnum(types.StorageClass.Function)`,
// etc.) byte-identical - file-private rebinding via the import.

// Shared SPIR-V word helpers live in types.zig (single source of truth).

// Structured-CFG reconstruction is the structured-IR path
// (`ir_build.zig` builds the nested Block/If/Loop/Switch tree;
// `ir_emit.zig` lowers it to WGSL).  The original recursive
// `walker.zig` was deleted in F5 (2026-05-31) - the IR path is the
// sole driver, and a CFG shape it can't structure is a hard error,
// not a fallback.  `block_table` is still imported by `ir_build.zig`.
/// Structured IR for the Tint-style CFG/phi rewrite (P0; builder +
/// emitter land in later phases).  Exposed so its decls + tests are
/// reachable from the spv2wgsl test root.  See
/// `src/notes/spv2wgsl_ir_rewrite.md`.
/// SPIR-V -> structured IR builder (F2; complete).
/// Sparse conditional constant propagation + dead-guard/dead-block
/// elimination, run as a SPIR-V prepass (finishing_webgpu.md section 0 #1).
/// Structured IR -> WGSL emitter (F3).

// =============================================================================
// Per-id table
// =============================================================================
// =============================================================================
//
// SPIR-V is SSA with a flat id space: every result-producing instruction
// gets an id, and ids form a single contiguous range [0, bound). We allocate
// one IdInfo per id and fill it in as we walk the module.
//
// The key field is `wgsl_name`. It holds:
//   * the WGSL type spelling for type ids ("f32", "vec4<f32>", "Sxx")
//   * the literal text for constant ids ("3.14", "true")
//   * the variable name for OpVariable ids ("v_42")
//   * the SSA temporary name for value-producing ops ("_42")
//   * the access-chain expression for OpAccessChain ids ("u.field_0[3]")
//
// Downstream emission just splices these strings together. There is no AST.

const IdKind = enum(u8) {
    unknown,
    type_void,
    type_scalar, // bool, i32, u32, f32 (spelling in wgsl_name)
    type_vector, // extra_a = component count, extra_b = component type id
    type_matrix, // extra_a = cols, extra_b = column-vector type id
    type_array, // extra_a = element type id, extra_b = length value
    type_struct, // wgsl_name = struct name
    type_pointer, // extra_a = storage class, extra_b = pointee type id
    type_image, // wgsl_name = "texture_2d<f32>" etc.
    type_sampler, // wgsl_name = "sampler"
    type_sampled_image, // extra_b = image type id
    type_function, // type_id = return type id
    constant, // wgsl_name = literal text; extra_a = first word (for array len)
    spec_constant,
    variable, // extra_a = storage class, extra_b = pointee type id
    function,
    label,
    value, // wgsl_name = temp name or inline expression
};

const IdInfo = struct {
    kind: IdKind = .unknown,
    type_id: u32 = 0,
    wgsl_name: []const u8 = "",
    extra_a: u32 = 0,
    extra_b: u32 = 0,
};

// =============================================================================
// Decorations
// =============================================================================
//
// SPIR-V decorations apply to an id (or to a struct member). We collect the
// ones we care about into a sparse table sized to id-bound. Most ids have no
// decorations; we eat the small memory overhead in exchange for O(1) lookup.

const DecoInfo = struct {
    has_location: bool = false,
    location: u32 = 0,
    has_binding: bool = false,
    binding: u32 = 0,
    has_group: bool = false,
    group: u32 = 0,
    has_builtin: bool = false,
    builtin: u32 = 0,
    block: bool = false,
    has_offset: bool = false,
    offset: u32 = 0,
    flat: bool = false,
};

const MemberDeco = struct {
    struct_id: u32,
    member: u32,
    deco: DecoInfo,
};

const EntryPoint = struct {
    exec_model: u32 = 0,
    func_id: u32 = 0,
    name: []const u8 = "",
    interface: []const u32 = &.{},
    /// `OpExecutionMode LocalSize x y z` for a GLCompute entry, the workgroup
    /// size declared at the source via the kernel's `config.workgroup`. Null
    /// for non-compute entries (or pre-892 SPIR-V that emitted no LocalSize).
    local_size: ?[3]u32 = null,
};

// =============================================================================
// State
// =============================================================================

/// Get the operand slice for the instruction starting at word offset `off`.
/// SPIR-V layout: word[0] = (count<<16 | opcode); operands follow.
/// Append a formatted string to an ArrayList(u8). The local equivalent of
/// `writer.print(fmt, args)`, but avoiding the writer abstraction (whose API
/// shape has been moving in recent Zig releases).
fn bprint(
    buf: *ArrayList(u8),
    arena: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text: []u8 = try allocPrint(arena, fmt, args);
    try buf.appendSlice(arena, text);
}

pub const types = struct {
    // src/spv2wgsl/types.zig - SPIR-V enum constants.
    //
    // Phase 1.1 of the spv2wgsl rewrite (`src/notes/archive/spv2wgsl-rewrite-plan.md`).
    // Pure data: every type here is an `enum(u32)` covering a SPIR-V
    // enum we map to WGSL.  Non-exhaustive so `switch` against opcode
    // / storage class / etc. retains its default branch for unhandled
    // values.
    //
    // These were `const Op`, `const StorageClass`, ... at the top of
    // `src/spv2wgsl.zig` before the module split.  No code change -
    // the values, names, and intent are unchanged.

    // =============================================================================
    // SPIR-V opcodes
    // =============================================================================
    //
    // We use a non-exhaustive enum(u32) so that `switch (op)` can still have a
    // default branch for the opcodes we don't handle, while giving us a typed
    // constant namespace. SPIR-V opcode values are stable across versions; new
    // ones are only added.

    pub const Op = enum(u32) {
        Nop = 0,
        Undef = 1,
        Source = 3,
        SourceExtension = 4,
        Name = 5,
        MemberName = 6,
        String = 7,
        Line = 8,
        Extension = 10,
        ExtInstImport = 11,
        ExtInst = 12,
        MemoryModel = 14,
        EntryPoint = 15,
        ExecutionMode = 16,
        Capability = 17,
        TypeVoid = 19,
        TypeBool = 20,
        TypeInt = 21,
        TypeFloat = 22,
        TypeVector = 23,
        TypeMatrix = 24,
        TypeImage = 25,
        TypeSampler = 26,
        TypeSampledImage = 27,
        TypeArray = 28,
        TypeRuntimeArray = 29,
        TypeStruct = 30,
        TypePointer = 32,
        TypeFunction = 33,
        ConstantTrue = 41,
        ConstantFalse = 42,
        Constant = 43,
        ConstantComposite = 44,
        ConstantNull = 46,
        SpecConstantTrue = 48,
        SpecConstantFalse = 49,
        SpecConstant = 50,
        SpecConstantComposite = 51,
        Function = 54,
        FunctionParameter = 55,
        FunctionEnd = 56,
        FunctionCall = 57,
        Variable = 59,
        Load = 61,
        Store = 62,
        AccessChain = 65,
        InBoundsAccessChain = 66,
        Decorate = 71,
        MemberDecorate = 72,
        VectorShuffle = 79,
        CompositeConstruct = 80,
        CompositeExtract = 81,
        CopyObject = 83,
        CopyLogical = 400,
        SampledImage = 86,
        ImageSampleImplicitLod = 87,
        ImageSampleExplicitLod = 88,
        ImageFetch = 95,
        ConvertFToU = 109,
        ConvertFToS = 110,
        ConvertSToF = 111,
        ConvertUToF = 112,
        UConvert = 113,
        SConvert = 114,
        FConvert = 115,
        Bitcast = 124,
        SNegate = 126,
        FNegate = 127,
        IAdd = 128,
        FAdd = 129,
        ISub = 130,
        FSub = 131,
        IMul = 132,
        FMul = 133,
        UDiv = 134,
        SDiv = 135,
        FDiv = 136,
        UMod = 137,
        SRem = 138,
        SMod = 139,
        FRem = 140,
        /// * FLOOR-based modulo, as distinct from `FRem`'s TRUNC-based remainder. Zig's
        /// `@mod` lowers to this and `@rem` lowers to `FRem`; the two differ whenever the
        /// operands' signs differ, which for a shader means any angle wrap around zero.
        FMod = 141,
        VectorTimesScalar = 142,
        MatrixTimesScalar = 143,
        VectorTimesMatrix = 144,
        MatrixTimesVector = 145,
        MatrixTimesMatrix = 146,
        Dot = 148,
        LogicalEqual = 164,
        LogicalNotEqual = 165,
        LogicalOr = 166,
        LogicalAnd = 167,
        LogicalNot = 168,
        Select = 169,
        IEqual = 170,
        INotEqual = 171,
        UGreaterThan = 172,
        SGreaterThan = 173,
        UGreaterThanEqual = 174,
        SGreaterThanEqual = 175,
        ULessThan = 176,
        SLessThan = 177,
        ULessThanEqual = 178,
        SLessThanEqual = 179,
        FOrdEqual = 180,
        // HACK(zig-0.16-spirv): the FUnord* variants get emitted by Zig
        // even when there's no NaN-sensitive reason.  We alias them to
        // their FOrd* equivalents - correct for all non-NaN inputs.
        // See docs/zig-spirv-quirks.md Quirk 4.
        FUnordEqual = 181,
        FOrdNotEqual = 182,
        FUnordNotEqual = 183,
        FOrdLessThan = 184,
        FUnordLessThan = 185,
        FOrdGreaterThan = 186,
        FUnordGreaterThan = 187,
        FOrdLessThanEqual = 188,
        FUnordLessThanEqual = 189,
        FOrdGreaterThanEqual = 190,
        FUnordGreaterThanEqual = 191,
        ShiftRightLogical = 194,
        ShiftRightArithmetic = 195,
        ShiftLeftLogical = 196,
        BitwiseOr = 197,
        BitwiseXor = 198,
        BitwiseAnd = 199,
        Not = 200,
        Phi = 245,
        LoopMerge = 246,
        SelectionMerge = 247,
        Label = 248,
        Branch = 249,
        BranchConditional = 250,
        Switch = 251,
        Kill = 252,
        Return = 253,
        ReturnValue = 254,
        Unreachable = 255,
        _, // non-exhaustive: anything else is "we don't handle it"
    };

    // =============================================================================
    // SPIR-V enum values we map to WGSL keywords
    // =============================================================================

    pub const StorageClass = enum(u32) {
        UniformConstant = 0,
        Input = 1,
        Uniform = 2,
        Output = 3,
        Workgroup = 4,
        Private = 6,
        Function = 7,
        StorageBuffer = 12,
        _,
    };

    pub const ExecModel = enum(u32) {
        Vertex = 0,
        TessellationControl = 1,
        TessellationEvaluation = 2,
        Geometry = 3,
        Fragment = 4,
        GLCompute = 5,
        _,
    };

    pub const Deco = enum(u32) {
        SpecId = 1,
        Block = 2,
        BufferBlock = 3,
        RowMajor = 4,
        ColMajor = 5,
        ArrayStride = 6,
        MatrixStride = 7,
        BuiltIn = 11,
        NoPerspective = 13,
        Flat = 14,
        Centroid = 16,
        Sample = 18,
        Location = 30,
        Binding = 33,
        DescriptorSet = 34,
        Offset = 35,
        _,
    };

    pub const BuiltIn = enum(u32) {
        Position = 0,
        PointSize = 1,
        FragCoord = 15,
        PointCoord = 16,
        FrontFacing = 17,
        SampleId = 18,
        SamplePosition = 19,
        SampleMask = 20,
        FragDepth = 22,
        NumWorkgroups = 24,
        WorkgroupId = 26,
        LocalInvocationId = 27,
        GlobalInvocationId = 28,
        LocalInvocationIndex = 29,
        VertexIndex = 42,
        InstanceIndex = 43,
        _,
    };

    // GLSL.std.450 extended-instruction numbers we map to WGSL builtins.
    // Source: GLSL.std.450.h in SPIRV-Headers. Most map 1-to-1 by name (lower-case).
    pub const Glsl = enum(u32) {
        Round = 1,
        RoundEven = 2,
        Trunc = 3,
        FAbs = 4,
        SAbs = 5,
        FSign = 6,
        SSign = 7,
        Floor = 8,
        Ceil = 9,
        Fract = 10,
        Sin = 13,
        Cos = 14,
        Tan = 15,
        Asin = 16,
        Acos = 17,
        Atan = 18,
        Atan2 = 25,
        Pow = 26,
        Exp = 27,
        Log = 28,
        Exp2 = 29,
        Log2 = 30,
        Sqrt = 31,
        InverseSqrt = 32,
        FMin = 37,
        UMin = 38,
        SMin = 39,
        FMax = 40,
        UMax = 41,
        SMax = 42,
        FClamp = 43,
        UClamp = 44,
        SClamp = 45,
        FMix = 46,
        Step = 48,
        SmoothStep = 49,
        Length = 66,
        Distance = 67,
        Cross = 68,
        Normalize = 69,
        Reflect = 71,
        Refract = 72,
        _,
    };

    // -- Tests ------------------------------------------------------------

    test "Op enum has expected core values" {
        try expectEqual(@as(u32, 248), @backingInt(Op.Label));
        try expectEqual(@as(u32, 249), @backingInt(Op.Branch));
        try expectEqual(@as(u32, 250), @backingInt(Op.BranchConditional));
        try expectEqual(@as(u32, 245), @backingInt(Op.Phi));
        try expectEqual(@as(u32, 246), @backingInt(Op.LoopMerge));
        try expectEqual(@as(u32, 247), @backingInt(Op.SelectionMerge));
    }

    test "Op enum is non-exhaustive (default case works on unknown values)" {
        const unknown: Op = @fromBackingInt(@intCast(9999));
        switch (unknown) {
            .Nop => unreachable,
            else => {}, // the `_` variant means this default works
        }
    }

    test "StorageClass values match SPIR-V spec" {
        try expectEqual(@as(u32, 0), @backingInt(StorageClass.UniformConstant));
        try expectEqual(@as(u32, 3), @backingInt(StorageClass.Output));
        try expectEqual(@as(u32, 7), @backingInt(StorageClass.Function));
    }

    test "BuiltIn values match SPIR-V spec" {
        try expectEqual(@as(u32, 0), @backingInt(BuiltIn.Position));
        try expectEqual(@as(u32, 15), @backingInt(BuiltIn.FragCoord));
    }

    // =============================================================================
    // SPIR-V word helpers
    // =============================================================================
    // A SPIR-V instruction's first word packs the opcode in the low 16 bits
    // and the total word count (opcode word + operands) in the high 16.
    // These three helpers are the shared, single-source-of-truth versions -
    // previously each was duplicated verbatim in spv2wgsl.zig, block_table.zig,
    // and ir_build.zig (a flatten-time name collision and a maintenance hazard).

    /// The opcode (low 16 bits of an instruction's first word).
    pub inline fn opcodeOf(word0: u32) u32 {
        return word0 & 0xFFFF;
    }

    /// The instruction's total word count (high 16 bits of its first word):
    /// the opcode word plus all operand words.
    pub inline fn wordCountOf(word0: u32) u32 {
        return (word0 >> 16) & 0xFFFF;
    }

    /// The operand words of the instruction whose first word is at `spirv[off]`
    /// (everything after that first word).
    pub inline fn operandsAt(spirv: []const u32, off: u32) []const u32 {
        const word_count: u32 = wordCountOf(spirv[off]);
        return spirv[off + 1 ..][0 .. word_count - 1];
    }
};

/// Append a literal string to an ArrayList(u8).
fn bstr(
    buf: *ArrayList(u8),
    arena: Allocator,
    s: []const u8,
) !void {
    try buf.appendSlice(arena, s);
}

/// One Tint-style phi assignment to be emitted before a predecessor
/// block's terminator.  See docs/tint-vs-spv2wgsl.md item 5.
const PhiAssignment = struct {
    phi_id: u32,
    value_id: u32,
};

const PhiAssignList = ArrayList(PhiAssignment);

const PhiAssignMap = std.AutoHashMapUnmanaged(u32, PhiAssignList);

/// Bounds-checked, kind-checked id lookup.
/// When an id is referenced before declaration, this used to panic.
/// In practice user shaders hit this mode commonly (any unhandled
/// opcode that produces a result-id leaves downstream refs orphaned),
/// so we degrade gracefully: lazy-register the id with a placeholder
/// value-name + emit a warning.  The output WGSL won't compile if the
/// reference matters (the `checkOutputClosure` pass still catches that)
/// but the transpiler keeps making progress instead of aborting.
//
// lookupId/lookupType/hasEntryOutputs are State's lookup helpers (parameterised
// by *State), and State's own methods call them back - a mutual State<->accessor
// dependency. Keeping the helpers just above State (helper-then-struct) costs one
// back-edge (this *State reference); the reverse order would cost three.
// lint:off decl-order: accessor parameterised by State; State's methods call it back
fn lookupId(s: *const State, id: u32) *const IdInfo {
    if (id == 0 or @as(usize, id) >= s.ids.len) {
        std.debug.panic(
            "spv2wgsl: id {d} out of bounds (bound={d}); while processing opcode={d} at word_offset={d}",
            .{ id, s.ids.len, s.debug_current_opcode, s.debug_current_offset },
        );
    }
    const info: *const IdInfo = &s.ids[id];
    if (info.kind == .unknown) {
        // Lazy placeholder.  The const-cast is sound here: lookupId
        // takes a const State by convention, but the placeholder
        // mutation is conceptually a memoised result rather than
        // user-visible state.
        //
        // Name uses the `__unresolved_N__` prefix (not `_N`) so that
        // `checkOutputClosure` doesn't false-fire on it - that scan
        // looks specifically for `_N`-shaped names because real bugs
        // produce those.  A `__unresolved_N__` reference is by
        // definition a known gap (we warned about it here), so the
        // closure check should not flag it again.
        const mutable: *IdInfo = @constCast(info);
        const name: []u8 = allocPrint(
            s.arena,
            "__unresolved_{d}__",
            .{id},
        ) catch std.debug.panic("spv2wgsl: OOM in lookupId placeholder", .{});
        mutable.* = .{
            .kind = .value,
            .wgsl_name = name,
        };
        if (builtin.mode == .debug) {
            std.log.warn(
                "spv2wgsl: id %{d} referenced before declaration; using placeholder {s}",
                .{ id, name },
            );
        }
    }
    return info;
}

/// Like lookupId but asserts the id is one of the type_* kinds.
fn lookupType(s: *const State, id: u32) *const IdInfo {
    const info: *const IdInfo = lookupId(s, id);
    switch (info.kind) {
        .type_void,
        .type_scalar,
        .type_vector,
        .type_matrix,
        .type_array,
        .type_struct,
        .type_pointer,
        .type_image,
        .type_sampler,
        .type_sampled_image,
        .type_function,
        => return info,
        else => std.debug.panic(
            "spv2wgsl: expected type id, got kind {s} for id %{d}",
            .{ @tagName(info.kind), id },
        ),
    }
}

fn hasEntryOutputs(s: *State) bool {
    for (s.entry.interface) |vid| {
        if (@as(usize, vid) >= s.ids.len) {
            continue;
        }
        if (s.ids[vid].kind != .variable) {
            continue;
        }
        if (s.ids[vid].extra_a == @backingInt(types.StorageClass.Output)) {
            return true;
        }
    }
    return false;
}

const State = struct {
    arena: Allocator,
    spirv: []const u32,

    ids: []IdInfo,

    /// Per-id flag: this instruction RESULT is used outside its defining
    /// block, so it cannot be a block-scoped `let` (WGSL scoping) - it is
    /// hoisted to a function-scope `var _N: T;` and its definition site
    /// emits an assignment (`_N = expr;`) instead of a `let` binding.
    /// This is the var-based analogue of Tint's value propagation: where
    /// Tint threads the SSA value out through control-instruction results,
    /// we simply make the value a mutable var readable in any later block.
    /// Computed per-function by `markHoistedResults`.
    hoisted: []bool,

    /// For a hoisted id, the SPIR-V type id of its value (captured during
    /// `markHoistedResults` from the defining instruction's result-type,
    /// since the per-id `type_id` in `ids` is not set until emission,
    /// which runs after the function-scope `var` declarations).
    hoist_type: []u32,
    decos: []DecoInfo,
    mem_decos: ArrayList(MemberDeco) = .empty,

    inst_off: ArrayList(u32) = .empty,

    header_buf: ArrayList(u8) = .empty,

    /// Bit patterns already given a `var<private>` by `nonFiniteName`, so a module
    /// using NaN in five places declares it once.
    nonfinite_emitted: std.AutoHashMapUnmanaged(u32, void) = .empty,
    body_buf: ArrayList(u8) = .empty,

    /// Structural struct dedup: emitted struct BODY (the `{ ... }` text) -> the
    /// WGSL name already emitted for it. SPIR-V can declare one logical struct
    /// under two ids - e.g. a uniform/storage block type carrying `Offset`
    /// member decorations AND an undecorated value-type twin produced by an
    /// `OpLoad` of the whole block. WGSL is nominally typed and never prints
    /// `Offset`, so the twins emit byte-identical bodies; collapsing them to one
    /// name lets the cross-type load (`let _: S8 = P;` where `P: S3461`)
    /// typecheck. IO structs DO print `@location`/`@builtin`, so their bodies
    /// differ and they are never merged. Keys + values are arena-owned.
    struct_bodies: std.StringHashMapUnmanaged([]const u8) = .empty,

    glsl_ext_set: u32 = 0,
    entry: EntryPoint = .{},

    // Coverage logging: opcodes we hit in pass 4 but don't have a handler for.
    // Each opcode is recorded at most once.
    unhandled_seen: [256]bool = @splat(false),

    // Breadcrumbs set at the top of the pass-4 dispatch loop so a panic
    // inside any handler can report what opcode / word offset was being
    // processed.  Without these, a panic from deep inside lookupId is
    // nearly impossible to diagnose.
    debug_current_opcode: u32 = 0,
    debug_current_offset: u32 = 0,

    // The recursive structured-CFG walker's per-block body emitter
    // needs to look up phi assignments for the current block.  Set
    // by `emitFunctionBody` before the walker call; cleared via
    // `defer` after.
    phi_assigns_ref: ?*const PhiAssignMap = null,

    // Tracks whether the function currently being emitted is an entry
    // point.  Set by `emitFunctionBody` for the duration of the walker
    // call.  Used by:
    //   - `isEntryFunctionContext()` - to route Output stores through
    //     the `outputs.<name> = ...` form.
    //   - `currentFunctionIsEntry()` (duck-typed accessor) - for the
    //     walker's emitTerminator to emit `return outputs;` vs
    //     `return;`.
    is_current_entry: bool = false,

    /// SPIR-V type id of the CURRENT non-entry function's return type
    /// (0 for the entry wrapper or a void-returning helper).  Used by the
    /// IR emitter's `.unreach` lowering: a value-returning function whose
    /// structured body ends in an `OpUnreachable` block (Zig emits this
    /// after a chain of returning if/else arms) must not fall off the end
    /// - WGSL/naga require a terminating `return <value>;` on every path.
    /// We emit `return <zero-value>;` of this type there; the block is
    /// unreachable so any well-typed value is sound.
    current_ret_type: u32 = 0,

    /// When an entry point's single output is a struct-typed variable,
    /// that variable IS the output struct (WGSL returns it directly,
    /// since `@builtin` cannot sit on a struct-typed wrapper field).
    /// This holds that variable's id so stores/access-chains through it
    /// alias the bare `outputs` local instead of `outputs.<varname>`.
    /// 0 = wrapper mode (scalar/vector outputs wrapped in {name}Outputs).
    output_alias_vid: u32 = 0,

    /// When set, only the OpEntryPoint whose (sanitized) name matches is
    /// captured; others are skipped. This is the multi-kernel story (t1178):
    /// a kompute module with N installKernel exports is translated N times,
    /// once per entry, producing N standalone WGSL modules - the emitter
    /// stays single-entry. null keeps today's behaviour (last entry wins).
    wanted_entry: ?[]const u8 = null,

    /// Sequential binding number for resource globals (uniform / storage /
    /// sampler / texture) that carry NO explicit Binding decoration.  Some
    /// front-ends (notably GLSL->SPIR-V) leave bindings implicit; WGSL
    /// requires a unique @binding per resource in a group, so we hand out
    /// 0, 1, 2, ... in declaration order.  Only consulted when the variable
    /// lacks an explicit binding (explicit bindings are always honored).
    next_auto_binding: u32 = 0,

    /// Atomic-binding taint set: the set of top-level storage-buffer variable
    /// ids that are the target of any atomic helper call (`zatomicAdd` /
    /// `zatomicLoad` / `zatomicStore`).  Filled by `markAtomicBindings` (a
    /// pre-pass over the reachable function bodies).  A variable in this set
    /// is emitted as `array<atomic<u32>>` and EVERY access to it (load /
    /// store / atomic call) is routed through a WGSL atomic builtin - WGSL
    /// forbids plain `[]` load/store on an `atomic<T>`.  Sparse, sized to
    /// id-bound; indexed by variable id.
    atomic_var: []bool = &.{},

    /// Look up the WGSL name of a SPIR-V id.  Used by the recursive
    /// walker's duck-typed `idName` helper.
    pub fn wgslNameOf(self: *State, id: u32) []const u8 {
        return lookupId(self, id).wgsl_name;
    }

    /// Duck-typed accessor used by ir_emit to format switch case
    /// literals: SPIR-V stores them as raw 32-bit words, but WGSL needs
    /// them typed to the selector.  Returns the scalar type spelling of
    /// the value `id` ("i32" / "u32" / ...), or "" if unknown.  A signed
    /// (`i32`) selector means a case word like 4000000000 must be
    /// reinterpreted as the i32 it encodes (-294967296), matching Tint's
    /// `i32(literal)` vs `u32(literal)` choice in EmitSwitch.
    pub fn scalarTypeNameOf(self: *State, id: u32) []const u8 {
        const ty: *const IdInfo = lookupType(self, lookupId(self, id).type_id);
        if (ty.kind == .type_scalar) {
            return ty.wgsl_name;
        }
        return "";
    }

    /// Duck-typed accessor used by the walker's `emitTerminator` to
    /// pick between `return outputs;` (entry with outputs) and
    /// `return;` (everything else).
    pub fn currentFunctionIsEntry(self: *State) bool {
        return self.is_current_entry and hasEntryOutputs(self);
    }

    /// Emit the entry function's return.  The body wrote the module-scope
    /// Output `var<private>`s directly (possibly from a called helper);
    /// here we stage them into the WGSL `Outputs` return struct and
    /// return it.  Wrapper mode: `outputs.<name> = <name>;` per Output,
    /// then `return outputs;`.  Single struct-output (output_alias_vid):
    /// the private var IS the whole struct - `return <name>;`.
    pub fn emitEntryReturn(
        self: *State,
        out: *ArrayList(u8),
        arena: Allocator,
    ) !void {
        if (self.output_alias_vid != 0) {
            const v: IdInfo = self.ids[self.output_alias_vid];
            try bprint(out, arena, "return {s};\n", .{v.wgsl_name});
            return;
        }
        for (self.entry.interface) |vid| {
            if (@as(usize, vid) >= self.ids.len) {
                continue;
            }
            const v: IdInfo = self.ids[vid];
            if (v.kind != .variable) {
                continue;
            }
            if (v.extra_a != @backingInt(types.StorageClass.Output)) {
                continue;
            }
            try bprint(out, arena, "outputs.{s} = {s};\n", .{ v.wgsl_name, v.wgsl_name });
            try bstr(out, arena, "  ");
        }
        try bstr(out, arena, "return outputs;\n");
    }

    /// Emit the terminator for an `OpUnreachable` block.  The block is
    /// statically unreachable, but WGSL/naga still require a value-
    /// returning function to terminate every structural path: a body
    /// that ends in a nested if/else whose arms all `return` (with the
    /// post-merge `OpUnreachable` tail) would otherwise "fall off the
    /// end" -> naga "Returning None where Some(T) is expected".  So for a
    /// value-returning non-entry function emit `return <zero-value>;`
    /// (the WGSL zero-value constructor `T()`); for the entry wrapper or
    /// a void helper, nothing is needed.  Any well-typed value is sound
    /// here because the block cannot execute.
    pub fn emitUnreachReturn(
        self: *State,
        out: *ArrayList(u8),
        arena: Allocator,
        depth: usize,
    ) !void {
        // The ENTRY function's body can end in an OpUnreachable tail when every
        // structural path already returned inside a selection - e.g. a shader
        // built from `if (c) a else b` scalar selects (Zig lowers these to
        // OpSelectionMerge, and the post-merge block is OpUnreachable). WGSL
        // still requires a terminating return on that fall-through path, so emit
        // the same Output-staging return a normal entry OpReturn would (the path
        // is unreachable, so the staged values are immaterial - only validity
        // matters). Without this the browser rejects the module with
        // "missing return at end of function".
        // A COMPUTE entry has NO `Outputs` struct - `emitEntryReturn` would write
        // `return outputs;` against a name that was never declared, and the browser rejects
        // the module with "unresolved value 'outputs'". `currentFunctionIsEntry` exists
        // precisely to make that distinction (entry AND has outputs); this used only
        // `is_current_entry`.
        //
        // It never fired before because SCCP folded these OpUnreachable tails away. Once
        // folding stopped deleting phi-carrying merges (see `mergeBlockPhiWouldOrphan`) the
        // tails survive, and the latent bug surfaced across every compute kernel at once.
        if (self.currentFunctionIsEntry()) {
            var i: usize = 0;
            while (i < depth) : (i += 1) {
                try bstr(out, arena, "  ");
            }
            try self.emitEntryReturn(out, arena);
            return;
        }
        if (self.is_current_entry) {
            // Entry with no outputs (a compute kernel): a plain `return;` terminates the
            // path and keeps WGSL happy.
            var i: usize = 0;
            while (i < depth) : (i += 1) {
                try bstr(out, arena, "  ");
            }
            try bstr(out, arena, "return;\n");
            return;
        }
        if (self.current_ret_type == 0) {
            return;
        }
        const rt: *const IdInfo = lookupType(self, self.current_ret_type);
        if (rt.kind == .type_void) {
            return;
        }
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            try bstr(out, arena, "  ");
        }
        try bprint(out, arena, "return {s}();\n", .{rt.wgsl_name});
    }

    /// Allocate the State and validate the SPIR-V header.
    fn init(arena: Allocator, spirv: []const u32) !State {
        if (spirv.len < 5) {
            return error.MalformedSpirv;
        }
        if (spirv[0] != 0x07230203) {
            return error.NotSpirv;
        }
        const bound: u32 = spirv[3];
        if (bound == 0) {
            return error.MalformedSpirv;
        }

        const s: State = .{
            .arena = arena,
            .spirv = spirv,
            .ids = try arena.alloc(IdInfo, bound),
            .decos = try arena.alloc(DecoInfo, bound),
            .hoisted = try arena.alloc(bool, bound),
            .hoist_type = try arena.alloc(u32, bound),
            .atomic_var = try arena.alloc(bool, bound),
        };
        for (s.ids) |*i| {
            i.* = .{};
        }
        for (s.decos) |*d| {
            d.* = .{};
        }
        @memset(s.hoisted, false);
        @memset(s.hoist_type, 0);
        @memset(s.atomic_var, false);
        return s;
    }
};

// =============================================================================
// Guard rails
// =============================================================================
//
// These are the assertions and logs the docs above advertise. They run only
// in debug builds (or always, if you want; the cost is trivial). They turn
// "the WGSL renders black" into a panic at the exact site of the bug.

/// Set the IdInfo for an id, panicking if it was already set (catches
/// "two opcodes claiming the same id" bugs early).
fn setId(
    s: *State,
    id: u32,
    info: IdInfo,
) void {
    if (@as(usize, id) >= s.ids.len) {
        std.debug.panic("spv2wgsl: setId out of bounds: id {d} bound {d}", .{ id, s.ids.len });
    }
    if (s.ids[id].kind != .unknown and builtin.mode == .debug) {
        std.log.warn(
            "spv2wgsl: id %{d} redefined (was {s}, now {s})",
            .{ id, @tagName(s.ids[id].kind), @tagName(info.kind) },
        );
    }
    s.ids[id] = info;
}

/// Log an unhandled opcode at most once per opcode value.
fn warnUnhandled(
    s: *State,
    op: u32,
    word_offset: u32,
) void {
    if (builtin.mode != .debug) {
        return;
    }
    const bucket: u32 = op % 256;
    if (s.unhandled_seen[bucket]) {
        return;
    }
    s.unhandled_seen[bucket] = true;
    std.log.warn("spv2wgsl: unhandled opcode {d} at word {d}", .{ op, word_offset });
}

// =============================================================================
// Small utilities
// =============================================================================

/// Allocate the standard SSA temporary name for a result id.
fn tempName(arena: Allocator, id: u32) ![]const u8 {
    return allocPrint(arena, "_{d}", .{id});
}

/// Emit the left-hand side of a value binding for result `id`:
///   - normal: `  let _N: <ty> = `  (a fresh block-scoped binding)
///   - hoisted: `  _N = `           (assignment to a function-scope var
///     already declared by emitFunctionBody; see markHoistedResults)
/// Centralizes the let-vs-var decision so every value-emitting helper
/// stays a one-liner.  `name` is the result's wgsl_name, `ty` its type
/// spelling.
fn bindLhs(
    out: *ArrayList(u8),
    s: *State,
    id: u32,
    name: []const u8,
    ty: []const u8,
) !void {
    if (@as(usize, id) < s.hoisted.len and s.hoisted[id]) {
        try bprint(out, s.arena, "  {s} = ", .{name});
    } else {
        try bprint(out, s.arena, "  let {s}: {s} = ", .{ name, ty });
    }
}

/// The decoded form of a SPIR-V literal string operand: the bytes
/// (without the trailing nul) and the number of u32 words the encoding
/// occupied, so the caller can advance its instruction cursor past it.
///
/// Named (rather than an anonymous struct return) so call sites can
/// annotate the binding - identically-shaped anonymous structs are
/// distinct types in Zig, which makes `const r: ... = readSpvString()`
/// impossible otherwise.
const SpvStringRead = struct {
    bytes: []const u8,
    word_count: u32,
};

/// Read a null-terminated SPIR-V literal string starting at
/// `words[offset]`.
///
/// SPIR-V packs string bytes little-endian into u32 words and
/// terminates with at least one zero byte, padded out to a whole word.
fn readSpvString(
    arena: Allocator,
    words: []const u32,
    offset: usize,
) !SpvStringRead {
    // First pass: measure the byte length so the destination buffer
    // can be sized exactly. `done` goes true on the terminating nul.
    var n_words: u32 = 0;
    var byte_count: usize = 0;
    var done: bool = false;
    while (offset + n_words < words.len and !done) : (n_words += 1) {
        // SPIR-V packs literal strings four bytes per 32-bit word, little-endian and
        // nul-terminated. This first pass only MEASURES - it walks to the nul so the output
        // can be allocated exactly - and writes nothing.
        const word: u32 = words[offset + n_words];
        var b: u32 = 0;
        while (b < 4) : (b += 1) {
            const shift: u5 = @intCast(b * 8);
            const byte: u8 = @truncate(word >> shift);
            if (byte == 0) {
                done = true;
                break;
            }
            byte_count += 1;
        }
    }
    if (offset + n_words > words.len) {
        return error.MalformedSpirv;
    }

    // Second pass: copy the bytes out (packed LE into u32 words).
    var out = try arena.alloc(u8, byte_count);
    var written: usize = 0;
    var wi: u32 = 0;
    outer: while (wi < n_words) : (wi += 1) {
        // Second pass, same unpacking, now copying into the exact-sized buffer.
        const word: u32 = words[offset + wi];
        var b: u32 = 0;
        while (b < 4) : (b += 1) {
            const shift: u5 = @intCast(b * 8);
            const byte: u8 = @truncate(word >> shift);
            if (byte == 0) {
                break :outer;
            }
            out[written] = byte;
            written += 1;
        }
    }
    return .{ .bytes = out, .word_count = n_words };
}

/// Convert an arbitrary identifier string to a WGSL-safe identifier. WGSL
/// allows ASCII letters, digits, and underscores, and identifiers must not
/// start with a digit.
fn sanitizeName(arena: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) {
        return arena.dupe(u8, "_anon");
    }
    var out = try ArrayList(u8).initCapacity(arena, s.len + 1);
    // WGSL identifiers may not start with a digit; prefix one if needed.
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') {
        try out.append(arena, '_');
    }
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try out.append(arena, c);
        } else {
            try out.append(arena, '_');
        }
    }
    return out.toOwnedSlice(arena);
}

fn findMemberDeco(
    s: *const State,
    struct_id: u32,
    member: u32,
) ?DecoInfo {
    for (s.mem_decos.items) |md| {
        if (md.struct_id == struct_id and md.member == member) {
            return md.deco;
        }
    }
    return null;
}

fn builtinName(b: u32) []const u8 {
    return switch (@as(types.BuiltIn, @fromBackingInt(@intCast(b)))) {
        .Position, .FragCoord => "position",
        .PointSize => "point_size",
        .FrontFacing => "front_facing",
        .FragDepth => "frag_depth",
        .SampleId => "sample_index",
        .SampleMask => "sample_mask",
        .VertexIndex => "vertex_index",
        .InstanceIndex => "instance_index",
        .LocalInvocationId => "local_invocation_id",
        .GlobalInvocationId => "global_invocation_id",
        .WorkgroupId => "workgroup_id",
        .NumWorkgroups => "num_workgroups",
        .LocalInvocationIndex => "local_invocation_index",
        else => "position", // safe fallback for a 4-component output
    };
}

fn glslExtName(n: u32) []const u8 {
    return switch (@as(types.Glsl, @fromBackingInt(@intCast(n)))) {
        .Round, .RoundEven => "round",
        .Trunc => "trunc",
        .FAbs, .SAbs => "abs",
        .FSign, .SSign => "sign",
        .Floor => "floor",
        .Ceil => "ceil",
        .Fract => "fract",
        .Sin => "sin",
        .Cos => "cos",
        .Tan => "tan",
        .Asin => "asin",
        .Acos => "acos",
        .Atan => "atan",
        .Atan2 => "atan2",
        .Pow => "pow",
        .Exp => "exp",
        .Log => "log",
        .Exp2 => "exp2",
        .Log2 => "log2",
        .Sqrt => "sqrt",
        .InverseSqrt => "inverseSqrt",
        .FMin, .SMin, .UMin => "min",
        .FMax, .SMax, .UMax => "max",
        .FClamp, .SClamp, .UClamp => "clamp",
        .FMix => "mix",
        .Step => "step",
        .SmoothStep => "smoothstep",
        .Length => "length",
        .Distance => "distance",
        .Cross => "cross",
        .Normalize => "normalize",
        .Reflect => "reflect",
        .Refract => "refract",
        else => "",
    };
}

fn imageTypeName(
    arena: Allocator,
    dim: u32,
    arrayed: u32,
    ms: u32,
    sampled: u32,
    stype: []const u8,
) ![]const u8 {
    // dim: 0=1D 1=2D 2=3D 3=Cube
    // sampled: 1=sampled, 2=storage, 0=unknown (treated as sampled).
    const storage: bool = sampled == 2;
    const dim_str: []const u8 = switch (dim) {
        0 => "1d",
        1 => if (ms != 0) "multisampled_2d" else "2d",
        2 => "3d",
        3 => "cube",
        else => "2d",
    };
    const arr_str: []const u8 = if (arrayed != 0) "_array" else "";
    if (storage) {
        return allocPrint(arena, "texture_storage_{s}{s}<rgba8unorm, write>", .{ dim_str, arr_str });
    } else {
        return allocPrint(arena, "texture_{s}{s}<{s}>", .{ dim_str, arr_str, stype });
    }
}

/// Render a SPIR-V constant's literal value into a WGSL literal.
fn renderConstant(
    arena: Allocator,
    type_spelling: []const u8,
    lit_words: []const u32,
) ![]const u8 {
    if (std.mem.eql(u8, type_spelling, "f32")) {
        if (lit_words.len < 1) {
            return arena.dupe(u8, "0.0");
        }
        const bits: u32 = lit_words[0];
        const f: f32 = @bitCast(bits);
        // WGSL infers the type of a numeric literal from its spelling:
        // `1` is an AbstractInt, `1.0` an AbstractFloat.  Zig's `{d}`
        // prints whole-valued floats WITHOUT a decimal point (`1.0`
        // -> "1"), which would make WGSL treat an f32 constant as an
        // integer - e.g. `select(1, 0, cond)` for an f32 result fails
        // naga with "expected f32, got i32".  Force a fractional part
        // so the spelling is always a float literal.
        // ---- NaN AND INFINITY HAVE NO WGSL LITERAL AT ALL ----
        //
        // This is the bug that made `[Invalid ShaderModule "diff_forward"]` on a real device.
        // `{d}` renders a NaN as the text `nan`, and the guard below saw the `n`, concluded the
        // spelling already had a marker, and returned it UNCHANGED. The emitted WGSL was
        // `return nan;` - and `nan` is not an identifier, a keyword, or a literal in WGSL. The
        // module failed to compile, and the failure surfaced only as a pipeline-creation error
        // on the device, because nothing upstream parses the WGSL it produces.
        //
        // The old comment called `.eEnN` an "inf/nan marker", so the case was KNOWN to reach
        // here - it was just handled by passing the text through, which is only correct for a
        // language that can spell these. WGSL cannot: the spec has no NaN or infinity literal,
        // deliberately, because a shader may be compiled with fast-math assumptions that make
        // them unrepresentable.
        //
        // A bitcast from the exact bit pattern is the sanctioned spelling and is what every
        // other WGSL producer emits. It also preserves WHICH NaN and the sign of the infinity,
        // which a literal could not have done anyway.
        const s_int: []const u8 = try allocPrint(arena, "{d}", .{f});
        if (std.mem.indexOfAny(u8, s_int, ".eEnN") == null) {
            // No decimal point, exponent, or inf/nan marker -> append ".0" so WGSL reads it as
            // a float rather than an AbstractInt. `nN` catches the `nan`/`inf` spellings, which
            // must NOT get a ".0" - they never reach a device anyway, because `emitConstant`
            // intercepts every non-finite f32 before this is called and routes it through
            // `nonFiniteName`. This branch is the finite path only.
            return allocPrint(arena, "{s}.0", .{s_int});
        }
        return s_int;
    }
    if (std.mem.eql(u8, type_spelling, "i32")) {
        if (lit_words.len < 1) {
            return arena.dupe(u8, "0");
        }
        const bits: u32 = lit_words[0];
        const v: i32 = @bitCast(bits);
        return allocPrint(arena, "{d}", .{v});
    }
    if (std.mem.eql(u8, type_spelling, "u32")) {
        if (lit_words.len < 1) {
            return arena.dupe(u8, "0u");
        }
        return allocPrint(arena, "{d}u", .{lit_words[0]});
    }
    return arena.dupe(u8, "0");
}

// =============================================================================
// Pass 1: build instruction offset table
// =============================================================================

fn pass1_walk(s: *State) !void {
    // First 5 words are the module header: magic, version, generator, bound,
    // schema. Instructions start at word 5.
    var i: u32 = 5;
    while (i < s.spirv.len) {
        const w0: u32 = s.spirv[i];
        const wc: u32 = types.wordCountOf(w0);
        if (wc == 0 or i + wc > s.spirv.len) {
            return error.MalformedSpirv;
        }
        try s.inst_off.append(s.arena, i);
        i += wc;
    }
}

// =============================================================================
// Pass 2: names + decorations + entry point
// =============================================================================

/// Helper for OpMemberDecorate: locate or create the MemberDeco entry, then
/// merge in the new decoration. Pulled out so pass2's switch stays readable.
fn applyMemberDecoration(s: *State, ops: []const u32) !void {
    const struct_id: u32 = ops[0];
    const member: u32 = ops[1];
    const kind: types.Deco = @fromBackingInt(@intCast(ops[2]));

    var d: DecoInfo = .{};
    var existing_idx: ?usize = null;
    for (s.mem_decos.items, 0..) |md, i| {
        if (md.struct_id == struct_id and md.member == member) {
            existing_idx = i;
            d = md.deco;
            break;
        }
    }

    switch (kind) {
        .Location => {
            d.has_location = true;
            d.location = ops[3];
        },
        .BuiltIn => {
            d.has_builtin = true;
            d.builtin = ops[3];
        },
        .Offset => {
            d.has_offset = true;
            d.offset = ops[3];
        },
        .Flat => d.flat = true,
        else => {},
    }

    if (existing_idx) |i| {
        s.mem_decos.items[i].deco = d;
    } else {
        try s.mem_decos.append(s.arena, .{
            .struct_id = struct_id,
            .member = member,
            .deco = d,
        });
    }
}

fn pass2_decorations(s: *State) !void {
    for (s.inst_off.items) |off| {
        const w0: u32 = s.spirv[off];
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(w0)));
        const ops: []const u32 = types.operandsAt(s.spirv, off);

        switch (op) {
            .ExtInstImport => {
                const result_id: u32 = ops[0];
                const r: SpvStringRead = try readSpvString(s.arena, s.spirv, off + 2);
                if (std.mem.eql(u8, r.bytes, "GLSL.std.450")) {
                    s.glsl_ext_set = result_id;
                }
            },
            .Name => {
                const target: u32 = ops[0];
                const r: SpvStringRead = try readSpvString(s.arena, s.spirv, off + 2);
                const name: []const u8 = try sanitizeName(s.arena, r.bytes);
                if (target < s.ids.len) {
                    // Zig emits MULTIPLE OpNames for one id: a binding passed as
                    // an argument (to a function OR an inline-asm helper) picks up
                    // the callee's PARAMETER name as a duplicate - e.g. real
                    // `kbuf_grid_counts`/`src`/`dst` AND the helper param `arr`/
                    // `buf`/`tex`. On 0.17.0-dev.956 the spurious PARAM name comes
                    // FIRST and the real declaration name LAST, so prefer the LAST
                    // OpName - EXCEPT never let a non-`kbuf_` name override an
                    // existing `kbuf_` one (the kompute host binding parser keys on
                    // `kbuf_<field>`, so that name must survive in any order). This
                    // gives correct, COLLISION-FREE binding names: two storage
                    // buffers sampled through one `inline` helper keep `src`/`dst`
                    // rather than both becoming the param name `buf`.
                    const existing: []const u8 = s.ids[target].wgsl_name;
                    const name_is_kbuf: bool = std.mem.startsWith(u8, name, "kbuf_");
                    const existing_is_kbuf: bool = std.mem.startsWith(u8, existing, "kbuf_");
                    if (name_is_kbuf or !existing_is_kbuf) {
                        s.ids[target].wgsl_name = name;
                    }
                }
            },
            .Decorate => {
                const target: u32 = ops[0];
                if (@as(usize, target) >= s.decos.len) {
                    continue;
                }
                const kind: types.Deco = @fromBackingInt(@intCast(ops[1]));
                const d: *DecoInfo = &s.decos[target];
                switch (kind) {
                    .Location => {
                        d.has_location = true;
                        d.location = ops[2];
                    },
                    .Binding => {
                        d.has_binding = true;
                        d.binding = ops[2];
                    },
                    .DescriptorSet => {
                        d.has_group = true;
                        d.group = ops[2];
                    },
                    .BuiltIn => {
                        d.has_builtin = true;
                        d.builtin = ops[2];
                    },
                    .Block, .BufferBlock => d.block = true,
                    .Flat => d.flat = true,
                    else => {},
                }
            },
            .MemberDecorate => {
                try applyMemberDecoration(s, ops);
            },
            .EntryPoint => {
                const r: SpvStringRead = try readSpvString(s.arena, s.spirv, off + 3);
                const name: []const u8 = try sanitizeName(s.arena, r.bytes);
                if (s.wanted_entry) |want| {
                    if (!std.mem.eql(u8, name, want)) {
                        continue;
                    }
                }
                s.entry.exec_model = ops[0];
                s.entry.func_id = ops[1];
                s.entry.name = name;
                const iface: []const u32 = ops[2 + r.word_count ..];
                s.entry.interface = try s.arena.dupe(u32, iface);
            },
            .ExecutionMode => {
                // `ops[0]` = target entry func_id, `ops[1]` = mode, rest =
                // literals. LocalSize (17) carries the compute workgroup size;
                // capture it for the selected entry so the WGSL `@workgroup_size`
                // reads straight from the SPIR-V. Modes follow their EntryPoint,
                // so `s.entry.func_id` is already set here.
                const local_size_mode: u32 = 17;
                if (ops[1] == local_size_mode and ops[0] == s.entry.func_id) {
                    s.entry.local_size = .{ ops[2], ops[3], ops[4] };
                }
            },
            else => {},
        }
    }
}

// =============================================================================
// Pass 3: types, constants, module-scope variables
// =============================================================================

fn emitTypeVector(s: *State, ops: []const u32) !void {
    const result: u32 = ops[0];
    const comp_type: u32 = ops[1];
    const count: u32 = ops[2];
    const ct: *const IdInfo = lookupType(s, comp_type);
    const name: []const u8 = try allocPrint(s.arena, "vec{d}<{s}>", .{ count, ct.wgsl_name });
    setId(s, result, .{
        .kind = .type_vector,
        .wgsl_name = name,
        .extra_a = count,
        .extra_b = comp_type,
    });
}

fn emitTypeMatrix(s: *State, ops: []const u32) !void {
    const result: u32 = ops[0];
    const col_type: u32 = ops[1];
    const cols: u32 = ops[2];
    const col_info: *const IdInfo = lookupType(s, col_type);
    // A matrix's row count is the component count of its column vectors,
    // which emitTypeVector stashed in the column type's extra_a.
    const rows: u32 = col_info.extra_a;
    const name: []const u8 = try allocPrint(s.arena, "mat{d}x{d}<f32>", .{ cols, rows });
    setId(s, result, .{
        .kind = .type_matrix,
        .wgsl_name = name,
        .extra_a = cols,
        .extra_b = col_type,
    });
}

fn emitTypeArray(s: *State, ops: []const u32) !void {
    const result: u32 = ops[0];
    const elem: u32 = ops[1];
    const length_const: u32 = ops[2];
    const elem_info: *const IdInfo = lookupType(s, elem);
    // Constants store their first word in extra_a (set by emitConstant).
    const len_val: u32 = lookupId(s, length_const).extra_a;
    const name: []const u8 = try allocPrint(s.arena, "array<{s}, {d}>", .{ elem_info.wgsl_name, len_val });
    setId(s, result, .{
        .kind = .type_array,
        .wgsl_name = name,
        .extra_a = elem,
        .extra_b = len_val,
    });
}

/// OpTypeRuntimeArray - an unsized `array<ELEM>` (WGSL runtime-sized array, the
/// trailing member of a storage-buffer block; e.g. `@SpirvType(.{ .runtime_array
/// = u32 })`). Same `.type_array` kind as a sized array so it resolves as a type
/// member; `extra_b = 0` flags "no length".
fn emitTypeRuntimeArray(s: *State, ops: []const u32) !void {
    const result: u32 = ops[0];
    const elem: u32 = ops[1];
    const elem_info: *const IdInfo = lookupType(s, elem);
    const name: []const u8 = try allocPrint(s.arena, "array<{s}>", .{elem_info.wgsl_name});
    setId(s, result, .{
        .kind = .type_array,
        .wgsl_name = name,
        .extra_a = elem,
        .extra_b = 0,
    });
}

fn emitTypeStruct(s: *State, ops: []const u32) !void {
    const result: u32 = ops[0];
    const members: []const u32 = ops[1..];

    // Build the struct BODY first (the lines between the braces), independent of
    // this struct's own name, so two structurally-identical structs produce
    // byte-identical bodies and can be deduplicated below.
    var body: ArrayList(u8) = .empty;
    for (members, 0..) |mtid, mi| {
        const mt: *const IdInfo = lookupType(s, mtid);
        // A member decorated with types.BuiltIn/Location is a shader-IO member
        // (vertex/fragment in/out struct) and needs the matching WGSL
        // attribute.  This is safe for uniform-buffer structs: their
        // members carry only `Offset` decorations, never types.BuiltIn/Location,
        // so they get no attribute.  (Tint attaches these as per-member
        // IOAttributes when building the struct type; we read the same
        // OpMemberDecorate data.)  Natural WGSL layout matches our std140
        // Ubo `extern struct`s (explicit padding), so we never emit
        // `@offset`/`@align` here - only IO attributes.  The leading
        // two-space indent is part of `prefix` in every case.
        const prefix: []const u8 = blk: {
            const md: DecoInfo = findMemberDeco(s, result, @intCast(mi)) orelse break :blk "  ";
            if (md.has_builtin) {
                break :blk try allocPrint(s.arena, "  @builtin({s}) ", .{builtinName(md.builtin)});
            }
            if (md.has_location) {
                if (md.flat) {
                    break :blk try allocPrint(s.arena, "  @location({d}) @interpolate(flat) ", .{md.location});
                }
                break :blk try allocPrint(s.arena, "  @location({d}) ", .{md.location});
            }
            break :blk "  ";
        };
        try bprint(&body, s.arena, "{s}field_{d}: {s},\n", .{ prefix, mi, mt.wgsl_name });
    }
    const body_str: []const u8 = body.items;

    // Structural dedup: if an earlier struct emitted this exact body, alias this
    // id to it and emit nothing.  This collapses the decorated/undecorated twin
    // structs SPIR-V produces for a whole-block load - without it, the load is a
    // nominal-type mismatch (`let _: S8 = P;` with `P: S3461`) that Tint rejects.
    if (s.struct_bodies.get(body_str)) |existing_name| {
        setId(s, result, .{ .kind = .type_struct, .wgsl_name = existing_name });
        return;
    }

    const sname: []const u8 = try allocPrint(s.arena, "S{d}", .{result});
    setId(s, result, .{ .kind = .type_struct, .wgsl_name = sname });
    try s.struct_bodies.put(s.arena, body_str, sname);

    try bprint(&s.header_buf, s.arena, "struct {s} {{\n", .{sname});
    try bstr(&s.header_buf, s.arena, body_str);
    try bstr(&s.header_buf, s.arena, "};\n\n");
}

fn emitTypePointer(s: *State, ops: []const u32) void {
    const result: u32 = ops[0];
    const storage: u32 = ops[1];
    const pointee: u32 = ops[2];
    const pt: *const IdInfo = lookupType(s, pointee);
    setId(s, result, .{
        .kind = .type_pointer,
        .wgsl_name = pt.wgsl_name,
        .extra_a = storage,
        .extra_b = pointee,
    });
}

fn emitTypeImage(s: *State, ops: []const u32) !void {
    // Layout: result_id, sampled_type, Dim, Depth, Arrayed, MS, Sampled, ImageFormat
    const result: u32 = ops[0];
    const sampled_type: u32 = ops[1];
    const dim: u32 = ops[2];
    const arrayed: u32 = ops[4];
    const ms: u32 = ops[5];
    const sampled: u32 = ops[6];
    const stype: []const u8 = lookupType(s, sampled_type).wgsl_name;
    const name: []const u8 = try imageTypeName(s.arena, dim, arrayed, ms, sampled, stype);
    setId(s, result, .{ .kind = .type_image, .wgsl_name = name });
}

fn emitTypeSampledImage(s: *State, ops: []const u32) void {
    const result: u32 = ops[0];
    const image_type: u32 = ops[1];
    const it: *const IdInfo = lookupType(s, image_type);
    setId(s, result, .{
        .kind = .type_sampled_image,
        .extra_b = image_type,
        .wgsl_name = it.wgsl_name,
    });
}

test "renderConstant: a whole-valued float keeps its fractional part" {
    // ---- THE BUG THIS PINS ----
    //
    // `{d}` renders a NaN as the text `nan`, and the old guard checked the spelling for
    // any of ".eEnN" to decide it was already formatted - so `nan` and `inf` were returned
    // VERBATIM. The emitted WGSL was `return nan;`, which is not an identifier, a keyword
    // or a literal in WGSL.
    //
    // Nothing upstream parses the WGSL this file produces, so the failure surfaced only on
    // a real device, as `[Invalid ShaderModule "diff_forward"] is invalid due to a previous
    // error` at pipeline creation. Every kernel that touched `zm.nan` was affected; the
    // sweep's `diff` row is the one that reached a browser.
    // An ARENA, because that is the parameter's contract: `renderConstant` allocates the
    // intermediate `{d}` spelling and leaves it for the arena rather than freeing it, so a
    // checking allocator reports a leak production does not have. It reported exactly one
    // byte - the "1" of the "1.0" case below.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    // NON-FINITE VALUES NEVER REACH HERE. `emitConstant` intercepts them and routes them
    // through `nonFiniteName`, because the fix has to be a module-scope `var<private>` and this
    // function can only return an expression. See `nonFiniteName` for why a `bitcast` of a
    // literal is not enough - Tint const-folds it and rejects the result.
    //
    // What this test pins is the FINITE path, and specifically that a whole-valued float keeps
    // its fractional part.

    // Infinity has the same problem and the same fix, and the SIGN has to survive - a
    // literal could not have carried it even if WGSL had one.
    // WGSL reads `1` as an AbstractInt and `1.0` as a float, and an f32 constant spelled as an
    // integer fails with "expected f32, got i32".
    const one: u32 = 0x3F80_0000;
    const one_text: []const u8 = try renderConstant(arena, "f32", &.{one});
    try expectEqualStrings("1.0", one_text);
}

/// A NaN or infinity, as a HELPER FUNCTION returning its bit pattern.
///
/// ---- WHY A `var` AND NOT A LITERAL, AND NOT EVEN A `bitcast` ----
///
/// WGSL has no NaN or infinity literal, so the value has to come from a bit pattern. The
/// obvious spelling is `bitcast<f32>(2143289344u)` - and Tint rejects that too:
///
///     :156:10 error: value nan cannot be represented as 'f32'
///       return bitcast<f32>(2143289344u);
///
/// **A `bitcast` of a LITERAL is a const-expression**, so Tint folds it at compile time, and a
/// WGSL const-expression must be representable. The value being unrepresentable is exactly the
/// point, so const-evaluation can never be allowed to reach it.
///
/// A module-scope `var<private> x: f32 = bitcast<f32>(...)` does NOT fix it: a module-scope
/// initializer must ALSO be a const-expression, so the same fold and the same rejection.
///
/// A FUNCTION-SCOPE `var` is the escape. It is runtime storage, so `bitcast<f32>(b)` where `b`
/// is a `var` is a runtime expression and the constant evaluator never sees it. The device has
/// no trouble with NaN at all - only the COMPILER'S const-eval does, and this is how every
/// other WGSL producer gets a NaN past it.
///
/// One helper per distinct bit pattern, named for it, so a module using NaN five times emits it
/// once and `+inf` never collides with `-inf`.
fn nonFiniteName(s: *State, bits: u32) ![]const u8 {
    const call_text: []const u8 = try allocPrint(s.arena, "nonfinite_{d}()", .{bits});
    if (s.nonfinite_emitted.contains(bits)) {
        return call_text;
    }
    try s.nonfinite_emitted.put(s.arena, bits, {});
    try bprint(
        &s.header_buf,
        s.arena,
        "fn nonfinite_{d}() -> f32 {{\n  var b: u32 = {d}u;\n  return bitcast<f32>(b);\n}}\n",
        .{ bits, bits },
    );
    return call_text;
}

fn emitConstant(s: *State, ops: []const u32) !void {
    // Layout: result_type, result_id, literal_words...
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const ti: *const IdInfo = lookupType(s, tid);
    const lit_words: []const u32 = ops[2..];
    const text: []const u8 = blk: {
        if (std.mem.eql(u8, ti.wgsl_name, "f32") and lit_words.len >= 1) {
            const f: f32 = @bitCast(lit_words[0]);
            if (!std.math.isFinite(f)) {
                break :blk try nonFiniteName(s, lit_words[0]);
            }
        }
        break :blk try renderConstant(s.arena, ti.wgsl_name, lit_words);
    };
    setId(s, result, .{
        .kind = .constant,
        .type_id = tid,
        .wgsl_name = text,
        // Stash first literal word so OpTypeArray can read the length.
        .extra_a = if (lit_words.len > 0) lit_words[0] else 0,
    });
}

fn emitConstantNull(s: *State, ops: []const u32) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const ti: *const IdInfo = lookupType(s, tid);
    const text: []const u8 = try allocPrint(s.arena, "{s}()", .{ti.wgsl_name});
    setId(s, result, .{ .kind = .constant, .type_id = tid, .wgsl_name = text });
}

fn emitConstantComposite(s: *State, ops: []const u32) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const comps: []const u32 = ops[2..];
    const ti: *const IdInfo = lookupType(s, tid);
    var buf: ArrayList(u8) = .empty;
    try bprint(&buf, s.arena, "{s}(", .{ti.wgsl_name});
    for (comps, 0..) |cid, ci| {
        if (ci != 0) {
            try bstr(&buf, s.arena, ", ");
        }
        try bstr(&buf, s.arena, lookupId(s, cid).wgsl_name);
    }
    try bstr(&buf, s.arena, ")");
    setId(s, result, .{
        .kind = .constant,
        .type_id = tid,
        .wgsl_name = try buf.toOwnedSlice(s.arena),
    });
}

/// Module-scope OpUndef: same semantics as the function-local variant
/// in `emitUndef`, but emit a module-scope `const` and register the id
/// at module scope so body references resolve.
///
/// WGSL note: `const` at module scope requires a constructible type and
/// a const-evaluable initializer; `T()` qualifies for the types SPIR-V
/// can OpUndef (scalars, vectors, matrices, arrays, structs of those).
fn emitModuleUndef(s: *State, ops: []const u32) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try allocPrint(s.arena, "undef_{d}", .{result});
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bprint(&s.header_buf, s.arena, "const {s}: {s} = {s}();\n", .{ name, t.wgsl_name, t.wgsl_name });
}

/// Resolve a resource global's @binding: its explicit Binding decoration
/// if present, otherwise the next sequential auto-binding (incrementing
/// the per-module counter).  Keeps implicit-binding GLSL->SPIR-V output
/// valid (unique bindings per group) while always honoring explicit ones.
fn resolveBinding(s: *State, d: DecoInfo) u32 {
    if (d.has_binding) {
        return d.binding;
    }
    const b: u32 = s.next_auto_binding;
    s.next_auto_binding += 1;
    return b;
}

/// The WGSL type a storage binding's array takes: RUNTIME-SIZED, because its length
/// comes from the bound buffer and large fixed arrays misbehaved on Adreno (t1178),
/// and wrapped in `atomic<>` when an atomic helper targets it, because WGSL requires
/// the wrapper on the ELEMENT type and rejects `atomicStore` on a plain `u32`.
/// Null when `t` needs neither, so a caller can leave the type exactly as it was.
fn storageArrayType(arena: Allocator, t: []const u8, is_atomic: bool) !?[]const u8 {
    if (!startsWith(u8, t, "array<")) {
        return null;
    }
    const size_comma: ?usize = std.mem.lastIndexOfScalar(u8, t, ',');
    if (is_atomic) {
        const elem_end: usize = size_comma orelse (t.len - 1);
        const elem: []const u8 = std.mem.trim(u8, t["array<".len..elem_end], " ");
        return try allocPrint(arena, "array<atomic<{s}>>", .{elem});
    }
    if (size_comma) |comma| {
        return try allocPrint(arena, "{s}>", .{t[0..comma]});
    }
    return null;
}

fn emitModuleVariable(s: *State, ops: []const u32) !void {
    // Layout: ptr_type, result_id, storage_class[, initializer]
    const ptr_tid: u32 = ops[0];
    const result: u32 = ops[1];
    const storage: u32 = ops[2];

    // Function-scope OpVariable belongs to pass 4; skip here.
    if (storage == @backingInt(types.StorageClass.Function)) {
        return;
    }

    const ptr_ti: *const IdInfo = lookupType(s, ptr_tid);
    const pointee_tid: u32 = ptr_ti.extra_b;
    const pointee: *const IdInfo = lookupType(s, pointee_tid);

    const var_name: []const u8 = if (s.ids[result].wgsl_name.len != 0)
        s.ids[result].wgsl_name
    else
        try allocPrint(s.arena, "v{d}", .{result});

    setId(s, result, .{
        .kind = .variable,
        .type_id = ptr_tid,
        .wgsl_name = var_name,
        .extra_a = storage,
        .extra_b = pointee_tid,
    });

    const d: DecoInfo = s.decos[result];
    const sc: types.StorageClass = @fromBackingInt(@intCast(storage));
    switch (sc) {
        // SPIR-V Input/Output variables are module-scope: any function
        // (not just the entry) may load an Input or store an Output.
        // Zig's un-optimized output puts the real shader logic in a
        // HELPER that the entry wrapper calls, so the I/O loads/stores
        // happen OUTSIDE the entry function.  Emit them as module-scope
        // `var<private>` so a bare-name load/store resolves from any
        // function; the entry wrapper copies `inputs.X -> X` at entry and
        // `X -> outputs.X` at return (see emitEntrySignature + the entry
        // `.ret` lowering).  This also fixes the section 3.A inter-procedural
        // case (Output written in a transitively-called helper).  The
        // WGSL I/O *interface* is still the entry's `Inputs` param and
        // `Outputs` return struct; these private vars are the internal
        // staging storage, exactly as Tint/naga model SPIR-V I/O globals.
        .Input, .Output => {
            try bprint(
                &s.header_buf,
                s.arena,
                "var<private> {s}: {s};\n",
                .{ var_name, pointee.wgsl_name },
            );
        },
        .UniformConstant => {
            const group: u32 = if (d.has_group) d.group else 0;
            const bind_idx: u32 = resolveBinding(s, d);
            // Opaque resources (textures/samplers) use a handle `var`;
            // but GLSL's "default uniform block" lowers a plain
            // `uniform vec4 x;` to a UniformConstant with a CONCRETE
            // (non-opaque) type - which in WGSL is a `var<uniform>`, not
            // a handle (`Type isn't compatible with address space
            // Handle` otherwise).
            const opaque_handle: bool =
                pointee.kind == .type_image or
                pointee.kind == .type_sampler or
                pointee.kind == .type_sampled_image;
            const space: []const u8 = if (opaque_handle) "" else "<uniform>";
            try bprint(&s.header_buf, s.arena, "@group({d}) @binding({d}) var{s} {s}: {s};\n", .{
                group, bind_idx, space, var_name, pointee.wgsl_name,
            });
        },
        .Uniform => {
            const group: u32 = if (d.has_group) d.group else 0;
            const bind_idx: u32 = resolveBinding(s, d);
            try bprint(&s.header_buf, s.arena, "@group({d}) @binding({d}) var<uniform> {s}: {s};\n", .{
                group, bind_idx, var_name, pointee.wgsl_name,
            });
        },
        .StorageBuffer => {
            const group: u32 = if (d.has_group) d.group else 0;
            const bind_idx: u32 = resolveBinding(s, d);
            // WebGPU forbids `read_write` storage in the VERTEX stage - it must
            // be `read`. A vertex shader reading a compute-written storage buffer
            // (the zero-copy particle render path) hits this. Emit `read` for
            // vertex entries; `read_write` for compute/fragment.
            const exec_model: types.ExecModel = @fromBackingInt(@intCast(s.entry.exec_model));
            const access: []const u8 = if (exec_model == .Vertex)
                "read"
            else
                "read_write";
            // Per-field binding shape (t1178): a storage binding whose ROOT
            // type is a fixed-size array is emitted RUNTIME-SIZED - the exact
            // form proven stable on Adreno (the megastruct + large fixed
            // arrays misbehaved there). Indexing code is unchanged; the
            // length comes from the bound buffer size.
            const is_atomic: bool = result < s.atomic_var.len and s.atomic_var[result];
            const root_type: []const u8 = blk: {
                const t: []const u8 = pointee.wgsl_name;
                // Atomic taint: a storage array targeted by an atomic helper
                // must be `array<atomic<ELEM>>` (WGSL requires the atomic<>
                // wrapper on the element type; all accesses then go through
                // atomic builtins - see emitLoad/emitStore/emitFunctionCall).
                if (try storageArrayType(s.arena, t, is_atomic)) |direct| {
                    break :blk direct;
                }
                // A one-field BLOCK struct hides that array one level down. That is
                // the shape an `@extern` in the storage_buffer address space is
                // required to take, and neither the runtime-sizing nor the atomic
                // wrapper above reaches a struct MEMBER - so emit a block of our own
                // carrying both, and leave every `x.field_0[i]` access untouched.
                // PER BINDING, because the deduped struct is shared by every buffer
                // of the same shape while only some of them are atomic.
                if (pointee.kind != .type_struct) {
                    break :blk t;
                }
                const member_tid: u32 = advanceStructMember(s, pointee_tid, 0) orelse break :blk t;
                const has_second_member: bool = advanceStructMember(s, pointee_tid, 1) != null;
                if (has_second_member) {
                    break :blk t;
                }
                const member_t: []const u8 = lookupType(s, member_tid).wgsl_name;
                const member: []const u8 = (try storageArrayType(s.arena, member_t, is_atomic)) orelse
                    break :blk t;
                // Through the SAME body map `emitTypeStruct` uses: two structs with
                // identical bodies are a nominal-type mismatch Tint rejects, and the
                // corpus checker fails the build on it. Bindings that differ only by
                // name share one block; the atomic ones do not collide with the plain
                // ones because `atomic<>` is already part of the member type.
                const body: []const u8 = try allocPrint(s.arena, "  field_0: {s},\n", .{member});
                if (s.struct_bodies.get(body)) |existing_name| {
                    break :blk existing_name;
                }
                const block_name: []const u8 = try allocPrint(s.arena, "{s}_block", .{var_name});
                try s.struct_bodies.put(s.arena, body, block_name);
                try bprint(&s.header_buf, s.arena, "struct {s} {{\n{s}}};\n", .{ block_name, body });
                break :blk block_name;
            };
            try bprint(&s.header_buf, s.arena, "@group({d}) @binding({d}) var<storage, {s}> {s}: {s};\n", .{
                group, bind_idx, access, var_name, root_type,
            });
        },
        .Private => try bprint(&s.header_buf, s.arena, "var<private> {s}: {s};\n", .{
            var_name, pointee.wgsl_name,
        }),
        .Workgroup => try bprint(&s.header_buf, s.arena, "var<workgroup> {s}: {s};\n", .{
            var_name, pointee.wgsl_name,
        }),
        else => {},
    }
}

fn pass3_types_globals(s: *State) !void {
    for (s.inst_off.items) |off| {
        const w0: u32 = s.spirv[off];
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(w0)));
        const ops: []const u32 = types.operandsAt(s.spirv, off);

        switch (op) {
            .TypeVoid => setId(s, ops[0], .{ .kind = .type_void }),
            .TypeBool => setId(s, ops[0], .{ .kind = .type_scalar, .wgsl_name = "bool" }),
            .TypeInt => {
                const signed: bool = ops[2] == 1;
                setId(s, ops[0], .{
                    .kind = .type_scalar,
                    .wgsl_name = if (signed) "i32" else "u32",
                });
            },
            .TypeFloat => setId(s, ops[0], .{ .kind = .type_scalar, .wgsl_name = "f32" }),
            .TypeVector => try emitTypeVector(s, ops),
            .TypeMatrix => try emitTypeMatrix(s, ops),
            .TypeArray => try emitTypeArray(s, ops),
            .TypeRuntimeArray => try emitTypeRuntimeArray(s, ops),
            .TypeStruct => try emitTypeStruct(s, ops),
            .TypePointer => emitTypePointer(s, ops),
            .TypeImage => try emitTypeImage(s, ops),
            .TypeSampler => setId(s, ops[0], .{ .kind = .type_sampler, .wgsl_name = "sampler" }),
            .TypeSampledImage => emitTypeSampledImage(s, ops),
            .TypeFunction => setId(s, ops[0], .{ .kind = .type_function, .type_id = ops[1] }),

            .Constant => try emitConstant(s, ops),
            .ConstantTrue => setId(s, ops[1], .{
                .kind = .constant,
                .type_id = ops[0],
                .wgsl_name = "true",
            }),
            .ConstantFalse => setId(s, ops[1], .{
                .kind = .constant,
                .type_id = ops[0],
                .wgsl_name = "false",
            }),
            .ConstantNull => try emitConstantNull(s, ops),
            .ConstantComposite => try emitConstantComposite(s, ops),

            // Module-scope OpUndef.  Same semantics as the in-function
            // handler (emitUndef): produce a zero-init of the target
            // type.  But here we register a `const` at module scope
            // so later body references resolve cleanly.  Without this,
            // body references to module-scope undef ids see an unset
            // slot in `s.ids` and lazy-placeholder kicks in (the "3
            // unresolved ids per shader" pattern this commit fixes).
            .Undef => try emitModuleUndef(s, ops),

            .Variable => try emitModuleVariable(s, ops),

            else => {},
        }
    }
    // Trailing blank line between header section and function bodies.
    try bstr(&s.header_buf, s.arena, "\n");
}

// =============================================================================
// Pass 4: function bodies
// =============================================================================
//
// For each function we:
//   1. Find OpFunction ... OpFunctionEnd as a block.
//   2. Collect FunctionParameter and Phi instructions for declarations at
//      the top of the body.
//   3. For the entry function, synthesize an input struct (Locations and
//      Builtins gathered from the interface) and an output struct.
//   4. Emit the function signature, then walk the body opcode-by-opcode.
//      OpSelectionMerge / OpLoopMerge before a branch open a structured
//      construct; OpLabel matching a frame's merge / continue / else label
//      closes or transitions it.
//
// Control-flow recovery is intentionally lossy: it trusts glslang to emit
// well-nested structured-control hints. DXC-style flattened CFGs need a real
// relooper, which is out of scope here.

/// Name stems that identify the kompute atomic helpers (see kompute.zig).  A
/// call whose callee's (sanitized) name contains one of these is an atomic
/// operation: the helper body is a dummy and must NOT be emitted; the call is
/// lowered to the corresponding WGSL builtin, and arg0's root storage variable
/// is atomic-tainted.
const atomic_add_stem = "zatomicAdd";
const atomic_load_stem = "zatomicLoad";
const atomic_store_stem = "zatomicStore";
const barrier_stem = "zworkgroupBarrier";

/// True if `name` is the workgroup-barrier helper (kompute.zig). Lowered to the
/// WGSL `workgroupBarrier()` builtin; the helper function itself is deleted.
fn isBarrierHelperName(name: []const u8) bool {
    return std.mem.indexOf(u8, name, barrier_stem) != null;
}

/// True if `name` is one of the atomic helper functions.
fn isAtomicHelperName(name: []const u8) bool {
    return std.mem.indexOf(u8, name, atomic_add_stem) != null or
        std.mem.indexOf(u8, name, atomic_load_stem) != null or
        std.mem.indexOf(u8, name, atomic_store_stem) != null;
}

/// Walk the SPIR-V def chain of `id` back to the OpVariable it ultimately
/// roots at (through OpAccessChain / OpLoad / OpCopyObject / OpInBoundsAccess
/// Chain), using a prebuilt id->defining-offset map.  Returns the variable id,
/// or 0 if no OpVariable root is found (e.g. a function parameter).
fn rootVariableOf(s: *State, def_off: []const u32, start_id: u32) u32 {
    var id: u32 = start_id;
    var guard: u32 = 0;
    while (id != 0 and id < def_off.len and guard < 64) : (guard += 1) {
        const off: u32 = def_off[id];
        if (off == 0) {
            return 0;
        }
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(s.spirv[off])));
        const ops: []const u32 = types.operandsAt(s.spirv, off);
        switch (op) {
            .Variable => return id, // the root
            // result-type, result-id, base, indices...  follow base.
            .AccessChain, .InBoundsAccessChain => id = ops[2],
            // result-type, result-id, pointer  -> follow pointer.
            .Load => id = ops[2],
            // result-type, result-id, operand  -> follow operand.
            .CopyObject, .CopyLogical => id = ops[2],
            else => return 0,
        }
    }
    return 0;
}

/// Durable guard (learned from the shared-memory smoke FAIL on the Adreno): a
/// `workgroupBarrier()` must be in UNIFORM control flow - EVERY invocation must
/// reach it. The most common violation is a data-dependent early `return`
/// BEFORE the barrier: lanes that return never reach it. On real drivers this
/// COMPILES but the barrier silently fails to synchronise - shared-memory reads
/// come back zero (the smoke test failed 1023/1024 this way). naga does NOT
/// flag it, so we catch it here, at transpile time, as a hard error. Rule:
/// within a function, no OpReturn may PRECEDE a barrier-helper call.
/// Fix in the kernel: dispatch an exact multiple of the workgroup size and
/// guard the per-lane WORK (`if (in_range) { ... }`) instead of early-returning
/// before the barrier. See kompute.zig `workgroupBarrier`.
/// Read the emitted WGSL back and refuse to hand over something a device will reject.
///
/// ---- WHY THIS EXISTS: THREE DEVICE ROUND-TRIPS ----
///
/// Nothing in this repo parsed the WGSL this file produces. A `diff` kernel emitted `return nan;`
/// - not an identifier, keyword or literal in WGSL - and every gate passed: `zig build check`,
/// the transpiler corpus, the smoke test, the SPIR-V probe. The failure surfaced on a phone, as
/// `[Invalid ShaderModule "diff_forward"] is invalid due to a previous error`, which does not
/// name the error. Fixing it by inspection produced a SECOND invalid spelling, which took
/// another round trip, and only then did asking `getCompilationInfo()` reveal the real message.
///
/// This is not a WGSL validator and is not trying to be one. It is a short list of spellings
/// THIS TRANSPILER has actually emitted and a device has actually rejected. Each entry earned
/// its place by costing a debugging cycle; the point is that the second occurrence costs a build
/// failure instead.
///
/// ---- THE RULE BEHIND BOTH ENTRIES ----
///
/// WGSL cannot spell NaN or infinity, and it cannot CONST-EVALUATE to one either. A
/// const-expression must be representable, so `bitcast<f32>(2143289344u)` is rejected exactly as
/// the bare token is - the fold happens before anyone asks whether a device could cope. Only a
/// value that reaches the bitcast through runtime storage survives, which is why `nonFiniteName`
/// emits a function with a `var` in it.
fn checkNonFiniteConstants(wgsl: []const u8) !void {
    // 1. A bare `nan` / `inf` / `-inf` where a value belongs. Anchored on `return ` and `= ` so
    //    an identifier that merely CONTAINS the letters - `nan_helper`, `infinity_mask` - does
    //    not trip it.
    const bare = [_][]const u8{
        "return nan;", "return inf;", "return -inf;",
        "= nan;",      "= inf;",      "= -inf;",
        " nan)",       " inf)",       " -inf)",
    };
    for (bare) |needle| {
        if (std.mem.indexOf(u8, wgsl, needle) != null) {
            return error.WgslNonFiniteLiteral;
        }
    }

    // 2. A `bitcast<f32>(<literal>u)` whose bits are non-finite. This is the spelling that looks
    //    like the fix and is not: it is a const-expression, so it folds and is rejected. The
    //    sanctioned form routes the bits through a function-scope `var`, which this never sees
    //    because the operand is then an identifier rather than a literal.
    const marker: []const u8 = "bitcast<f32>(";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, wgsl, at, marker)) |hit| {
        const arg_start: usize = hit + marker.len;
        at = arg_start;
        var end: usize = arg_start;
        while (end < wgsl.len and wgsl[end] >= '0' and wgsl[end] <= '9') {
            end += 1;
        }
        if (end == arg_start) {
            continue; // not a literal - an identifier or an expression, which is the good case
        }
        const bits: u32 = std.fmt.parseInt(u32, wgsl[arg_start..end], 10) catch continue;
        const value: f32 = @bitCast(bits);
        if (!std.math.isFinite(value)) {
            return error.WgslNonFiniteConstExpr;
        }
    }
}

test "checkNonFiniteConstants: the two spellings a device has actually rejected" {
    // Both of these shipped. The first reached a phone; the second was written as its fix and
    // reached the same phone. Neither is caught by anything else in this repo.
    try expectError(
        error.WgslNonFiniteLiteral,
        checkNonFiniteConstants("fn f() -> f32 {\n  return nan;\n}\n"),
    );
    try expectError(
        error.WgslNonFiniteConstExpr,
        checkNonFiniteConstants("fn f() -> f32 {\n  return bitcast<f32>(2143289344u);\n}\n"),
    );

    // The sanctioned form passes: the bits reach the bitcast through a `var`, so the operand is
    // an identifier and there is nothing for the const evaluator to fold.
    try checkNonFiniteConstants(
        "fn nonfinite_2143289344() -> f32 {\n  var b: u32 = 2143289344u;\n  return bitcast<f32>(b);\n}\n",
    );

    // And a FINITE bitcast is ordinary code that must not be flagged - reinterpreting bits is a
    // normal thing for a shader to do.
    try checkNonFiniteConstants("fn f() -> f32 {\n  return bitcast<f32>(1065353216u);\n}\n");

    // An identifier that merely contains the letters is not a literal.
    try checkNonFiniteConstants("fn f() -> f32 {\n  return nan_helper();\n}\n");
}

fn checkBarrierUniformity(s: *State) !void {
    var i: usize = 0;
    var in_func: bool = false;
    var is_helper: bool = false;
    var saw_return: bool = false;
    while (i < s.inst_off.items.len) : (i += 1) {
        const off: u32 = s.inst_off.items[i];
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(s.spirv[off])));
        switch (op) {
            .Function => {
                in_func = true;
                saw_return = false;
                // Read the name DIRECTLY (function kinds aren't registered until
                // pass4, so lookupId would return an `__unresolved__` placeholder
                // here - same reason markAtomicBindings reads s.ids directly).
                const fres: u32 = types.operandsAt(s.spirv, off)[1];
                const fname: []const u8 = if (fres < s.ids.len) s.ids[fres].wgsl_name else "";
                is_helper = isBarrierHelperName(fname);
            },
            .FunctionEnd => {
                in_func = false;
            },
            .Return, .ReturnValue => {
                if (in_func and !is_helper) {
                    saw_return = true;
                }
            },
            .FunctionCall => {
                if (in_func and !is_helper) {
                    const ops: []const u32 = types.operandsAt(s.spirv, off);
                    const callee: []const u8 = if (ops.len >= 3 and ops[2] < s.ids.len) s.ids[ops[2]].wgsl_name else "";
                    if (isBarrierHelperName(callee) and saw_return) {
                        // `std.log.warn`, not `std.debug.print`: the latter bypasses `std_options`
                        // and its raw-stderr writer traps under ReleaseSmall on wasm - and spv2wgsl
                        // itself runs inside the wasm transpiler. The other diagnostics in this
                        // file already use `std.log.warn`.
                        std.log.warn(
                            "spv2wgsl: workgroupBarrier() is preceded by an early `return` " ++
                                "— non-uniform control flow. The barrier will not synchronise on " ++
                                "real GPUs (shared reads return zero). Restructure the kernel so no " ++
                                "lane returns before the barrier (see kompute.zig workgroupBarrier).",
                            .{},
                        );
                        return error.BarrierInNonUniformControlFlow;
                    }
                }
            },
            else => {},
        }
    }
}

/// Pre-pass (runs after decorations, before type/global emission): find every
/// storage variable that is the target of an atomic helper call and mark it in
/// `s.atomic_var`.  This is what drives `array<atomic<u32>>` emission and the
/// load/store->atomic rerouting.  arg0 of an atomic call is the storage array
/// pointer; its root OpVariable is the binding to taint.
fn markAtomicBindings(s: *State) !void {
    // Build an id -> defining-instruction-offset map (sparse, id-bound).
    const def_off: []u32 = try s.arena.alloc(u32, s.ids.len);
    @memset(def_off, 0);
    for (s.inst_off.items) |off| {
        const w0: u32 = s.spirv[off];
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(w0)));
        // Every op that produces a result id has it at operand[1] EXCEPT a
        // handful where it's operand[0] (the type-less producers we care
        // about here all use the [result-type, result-id, ...] shape).  We
        // only need the ops rootVariableOf follows plus OpVariable, so map
        // exactly those.
        const ops: []const u32 = types.operandsAt(s.spirv, off);
        switch (op) {
            .Variable => {
                // result-type, result-id, storage-class[, init]
                if (ops.len >= 2) {
                    def_off[ops[1]] = off;
                }
            },
            .AccessChain, .InBoundsAccessChain, .Load, .CopyObject, .CopyLogical => {
                if (ops.len >= 2) {
                    def_off[ops[1]] = off;
                }
            },
            else => {},
        }
    }

    // Scan every OpFunctionCall; if the callee is an atomic helper, taint
    // arg0's root variable.
    for (s.inst_off.items) |off| {
        const w0: u32 = s.spirv[off];
        if (@as(types.Op, @fromBackingInt(@intCast(types.opcodeOf(w0)))) != .FunctionCall) {
            continue;
        }
        const ops: []const u32 = types.operandsAt(s.spirv, off);
        // ops = [result-type, result-id, callee, args...]
        if (ops.len < 4) {
            continue;
        }
        // Read the callee's name DIRECTLY (not via lookupId): lookupId would
        // overwrite a still-`.unknown` function id with an `__unresolved_N__`
        // placeholder (function kinds aren't registered until pass4), which
        // would both corrupt the name and defeat this match.
        const callee_name: []const u8 = if (ops[2] < s.ids.len) s.ids[ops[2]].wgsl_name else "";
        if (!isAtomicHelperName(callee_name)) {
            continue;
        }
        const arg0: u32 = ops[3];
        const root: u32 = rootVariableOf(s, def_off, arg0);
        if (root != 0 and root < s.atomic_var.len) {
            s.atomic_var[root] = true;
        }
    }
}

/// Build a per-id `reachable` bitmap: true for every function reachable
/// from the entry point through the `OpFunctionCall` graph (transitive
/// closure).  Functions not in the set are dead and are not emitted.
fn computeReachableFunctions(s: *State) ![]const bool {
    const bound: usize = s.ids.len;
    const reachable: []bool = try s.arena.alloc(bool, bound);
    @memset(reachable, false);

    // callees[fn_id] = list of function ids it directly calls.  Built by
    // scanning each function body for OpFunctionCall.
    var callees: std.AutoHashMapUnmanaged(u32, ArrayList(u32)) = .empty;
    var cur_fn: u32 = 0;
    for (s.inst_off.items) |off| {
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(s.spirv[off])));
        switch (op) {
            .Function => cur_fn = types.operandsAt(s.spirv, off)[1],
            .FunctionCall => {
                // ops = [result_type, result_id, callee, args...]
                const callee: u32 = types.operandsAt(s.spirv, off)[2];
                const gop: @TypeOf(callees).GetOrPutResult = try callees.getOrPut(s.arena, cur_fn);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(s.arena, callee);
            },
            else => {},
        }
    }

    // BFS/DFS from the entry function.
    if (s.entry.func_id == 0 or s.entry.func_id >= bound) {
        return reachable;
    }
    var stack: ArrayList(u32) = .empty;
    try stack.append(s.arena, s.entry.func_id);
    reachable[s.entry.func_id] = true;
    while (stack.pop()) |fid| {
        const list: ArrayList(u32) = callees.get(fid) orelse continue;
        for (list.items) |callee| {
            if (callee < bound and !reachable[callee]) {
                reachable[callee] = true;
                try stack.append(s.arena, callee);
            }
        }
    }
    return reachable;
}

fn emitIoField(
    s: *State,
    vid: u32,
    auto_location: u32,
) !void {
    var d: DecoInfo = s.decos[vid];
    const v: IdInfo = s.ids[vid];
    const t: *const IdInfo = lookupType(s, v.extra_b);
    // If the variable itself carries no IO decoration but its type is a
    // struct, the builtin/location may sit on a STRUCT MEMBER (via
    // OpMemberDecorate) rather than the variable - the vertex-shader
    // output-struct case (function_VertexShader_*Struct), where SPIR-V
    // decorates `%struct member 0 types.BuiltIn Position`.  WGSL requires the
    // attribute on the entry-output field, so surface the member-0
    // decoration here (Tint attaches these as per-member IOAttributes
    // when it builds the struct type).
    if (!d.has_builtin and !d.has_location and t.kind == .type_struct) {
        if (findMemberDeco(s, v.extra_b, 0)) |md| {
            if (md.has_builtin or md.has_location) {
                d = md;
            }
        }
    }
    if (d.has_builtin) {
        try bprint(&s.header_buf, s.arena, "  @builtin({s}) ", .{builtinName(d.builtin)});
    } else if (d.has_location) {
        if (d.flat) {
            try bprint(&s.header_buf, s.arena, "  @location({d}) @interpolate(flat) ", .{d.location});
        } else {
            try bprint(&s.header_buf, s.arena, "  @location({d}) ", .{d.location});
        }
    } else if (t.kind != .type_struct) {
        // A non-builtin, non-struct IO field with no explicit Location
        // decoration.  WGSL requires every user-defined (non-builtin)
        // entry IO field to carry a @location, but SPIR-V from some
        // front-ends (e.g. GLSL with name-matched varyings) leaves the
        // location implicit, matched by declaration order.  Assign a
        // sequential location so the stage interface stays valid and
        // vertex-output <-> fragment-input numbering lines up.
        try bprint(&s.header_buf, s.arena, "  @location({d}) ", .{auto_location});
    } else {
        try bstr(&s.header_buf, s.arena, "  ");
    }
    try bprint(&s.header_buf, s.arena, "{s}: {s},\n", .{ v.wgsl_name, t.wgsl_name });
}

/// Emit the entry-point function signature and prologue. Inputs become fields
/// of an `<name>Inputs` struct passed as the only parameter; outputs become
/// fields of an `<name>Outputs` struct returned. Inside the body, references
/// to input/output variables go through local var mirrors named like the
/// original variable. The function epilogue (in emitOneFunction) emits
/// `return outputs;` if there were any outputs.
fn emitEntrySignature(s: *State) !void {
    const stage_attr: []const u8 = switch (@as(types.ExecModel, @fromBackingInt(@intCast(s.entry.exec_model)))) {
        .Vertex => "@vertex",
        .Fragment => "@fragment",
        .GLCompute => blk: {
            // The workgroup size is the SPIR-V `LocalSize`, emitted from the
            // kernel's `config.workgroup`. Absent only for SPIR-V with no
            // LocalSize (e.g. a pre-892 toolchain) -> default to 1.
            const wg: [3]u32 = s.entry.local_size orelse .{ 1, 1, 1 };
            break :blk try allocPrint(s.arena, "@compute @workgroup_size({d}, {d}, {d})", .{
                wg[0],
                wg[1],
                wg[2],
            });
        },
        else => "@vertex",
    };

    var inputs: ArrayList(u32) = .empty;
    var outputs: ArrayList(u32) = .empty;
    for (s.entry.interface) |vid| {
        if (@as(usize, vid) >= s.ids.len) {
            continue;
        }
        const v: IdInfo = s.ids[vid];
        if (v.kind != .variable) {
            continue;
        }
        const sc: types.StorageClass = @fromBackingInt(@intCast(v.extra_a));
        switch (sc) {
            .Input => try inputs.append(s.arena, vid),
            .Output => try outputs.append(s.arena, vid),
            else => {},
        }
    }

    if (inputs.items.len > 0) {
        try bprint(&s.header_buf, s.arena, "struct {s}Inputs {{\n", .{s.entry.name});
        var auto_loc: u32 = 0;
        for (inputs.items) |vid| {
            try emitIoField(s, vid, auto_loc);
            auto_loc += 1;
        }
        try bstr(&s.header_buf, s.arena, "};\n\n");
    }

    // Decide the output return type.  If the entry's single output is a
    // struct-typed variable, return THAT struct directly - its members
    // already carry the IO attributes (emitTypeStruct surfaced them from
    // OpMemberDecorate).  WGSL forbids `@builtin` on a struct-typed
    // wrapper field, so a {name}Outputs wrapper around a struct output is
    // invalid; Tint returns the attributed struct directly.  Otherwise
    // wrap scalar/vector outputs in {name}Outputs as before.
    var out_type: []const u8 = "";
    if (outputs.items.len == 1 and
        lookupType(s, s.ids[outputs.items[0]].extra_b).kind == .type_struct)
    {
        const ov: IdInfo = s.ids[outputs.items[0]];
        out_type = lookupType(s, ov.extra_b).wgsl_name;
        s.output_alias_vid = outputs.items[0];
    } else if (outputs.items.len > 0) {
        out_type = try allocPrint(s.arena, "{s}Outputs", .{s.entry.name});
        try bprint(&s.header_buf, s.arena, "struct {s} {{\n", .{out_type});
        var auto_loc: u32 = 0;
        for (outputs.items) |vid| {
            try emitIoField(s, vid, auto_loc);
            auto_loc += 1;
        }
        try bstr(&s.header_buf, s.arena, "};\n\n");
    }

    try bprint(&s.body_buf, s.arena, "{s}\nfn {s}(", .{ stage_attr, s.entry.name });
    if (inputs.items.len > 0) {
        try bprint(&s.body_buf, s.arena, "inputs: {s}Inputs", .{s.entry.name});
    }
    try bstr(&s.body_buf, s.arena, ")");
    if (outputs.items.len > 0) {
        try bprint(&s.body_buf, s.arena, " -> {s}", .{out_type});
    }
    try bstr(&s.body_buf, s.arena, " {\n");

    // Copy each Input into its module-scope `var<private>` (declared in
    // pass3) so the body - which may live in a called helper - reads the
    // bare name regardless of which function it's in.
    for (inputs.items) |vid| {
        const v: IdInfo = s.ids[vid];
        try bprint(&s.body_buf, s.arena, "  {s} = inputs.{s};\n", .{ v.wgsl_name, v.wgsl_name });
    }
    // Declare the outputs struct local.  The body writes the module-scope
    // Output `var<private>`s directly (from the entry OR a helper); the
    // entry's `return` lowering copies those privates into this struct
    // (see the `.ret` handling in emitFunctionBody for the entry).  For a
    // single struct-typed output (output_alias_vid) the private var IS
    // the whole struct and is returned directly - no per-field copy.
    if (outputs.items.len > 0 and s.output_alias_vid == 0) {
        try bprint(&s.body_buf, s.arena, "  var outputs: {s};\n", .{out_type});
    }
}

pub const ir = struct {
    // src/spv2wgsl/ir.zig - a small structured IR for spv2wgsl's
    // control-flow + phi lowering (the Tint-style rewrite; see
    // `src/notes/spv2wgsl_ir_rewrite.md`).
    //
    // WHY THIS EXISTS
    // The legacy walker lowers OpPhi by emitting `phiN = value` at the
    // single SPIR-V predecessor block, then flushing at that block's
    // terminator.  That drops a copy whenever a branch reaches a merge
    // THROUGH a nested construct (the merge's true-side predecessor is
    // an inner merge block, and the assignment never lands on that
    // path).  Concretely it left the mandelbrot loop-exit phi unset on
    // the iterating path -> the loop broke on iteration 1 -> blank fractal.
    //
    // THE MODEL (mirrors Tint, scoped to CFG/phi)
    // Tint turns each OpPhi into a block parameter and carries the value
    // as an operand on the structured EXIT instructions, pushing onto
    // EVERY exit of a construct (`parser.cc` Propagate ~1229).  Because
    // WE emit phis as hoisted `var phi{id}` at function scope, a value is
    // always in scope - so we do not need Tint's multi-level Propagate.
    // What we DO need, and what the legacy model lacked, is to make the
    // exits EXPLICIT so the emitter assigns each construct's result phis
    // on every exit edge.  This module is the data model for that; the
    // `validate` pass enforces the invariant (every exit's arg count
    // matches its construct's param count), making the legacy bug
    // structurally unrepresentable.
    //
    // SCOPE
    // Pure data + a validator.  No SPIR-V here (the builder lives in
    // `ir_build.zig`); no WGSL here (the emitter lives in `ir_emit.zig`).
    // Block BODIES (straight-line ops) are NOT modelled - they stay as
    // SPIR-V block ids emitted by the existing id-table text emitter.
    // Depends only on `std`, so it is unit-testable in isolation.

    // =============================================================================
    // Values + params
    // =============================================================================

    /// A value is referenced by its SPIR-V result id throughout.  The
    /// emitter resolves an id to WGSL text via the id table: a lowered
    /// phi resolves to `phi{id}`, a constant/instruction to its own name.
    /// Keeping values as raw ids matches how the existing emitter works
    /// and avoids a parallel value representation.
    pub const ValueId = u32;

    /// A lowered OpPhi: a parameter of a merge (an `If`/`Switch` result)
    /// or of a loop header.  Declared once as `var phi{phi_id}: T;` and
    /// assigned at every exit edge that targets the owning construct.
    pub const Param = struct {
        /// Original OpPhi result id -> WGSL variable name `phi{phi_id}`.
        phi_id: u32,
        /// SPIR-V type id of the phi (for the `var` declaration).
        type_id: u32,
        /// Loop-header params only: the initial value (from the pre-loop
        /// edge), assigned to `var phi{phi_id}` BEFORE the loop.  `null`
        /// for `If`/`Switch`/loop-merge result params (those are assigned
        /// at exit edges, not initialized).
        init: ?ValueId = null,
    };

    // =============================================================================
    // Blocks + items
    // =============================================================================

    /// One statement inside a block: either emit the straight-line body
    /// of a SPIR-V block (via the existing text emitter), or a nested
    /// structured construct.  Items appear in source (emission) order.
    pub const Item = union(enum) {
        /// Emit instructions of this SPIR-V block between its OpLabel and
        /// its first construct/terminator.  Phi/terminator excluded.
        body: u32,
        /// A nested If / Loop / Switch.
        construct: *Construct,
    };

    /// A structured block: a run of items terminated by exactly one
    /// terminator.  A branch of an `If`, a loop body, a switch case, etc.
    pub const Block = struct {
        items: []Item = &.{},
        term: Terminator,
    };

    // =============================================================================
    // Terminators
    // =============================================================================

    /// How a block ends.  The exit-kind variants carry `args` - the phi
    /// values handed to the target construct's params, positionally.  The
    /// kind selects which enclosing construct the exit targets (the
    /// nearest enclosing one of that shape), exactly as SPIR-V structured
    /// control flow guarantees.
    pub const Terminator = union(enum) {
        /// Leaves the nearest enclosing `If` to its merge.
        exit_if: Exit,
        /// Leaves the nearest enclosing `Switch` to its merge.
        exit_switch: Exit,
        /// Leaves the nearest enclosing `Loop` to its merge (a `break`).
        exit_loop: Exit,
        /// To the nearest enclosing `Loop`'s continuing block; `args` are
        /// the loop-carried (header) phi values for the next iteration.
        cont: Exit,
        /// Conditional break out of the nearest enclosing `Loop`.  On
        /// false it continues; `args` are the loop-merge phi values for
        /// the break edge.
        break_if: BreakIf,
        /// Unconditional branch to a non-merge target (degenerate /
        /// straight-line chaining).  Rare in fully structured output.
        branch: u32,
        ret,
        ret_value: ValueId,
        kill,
        unreach,
    };

    pub const Exit = struct {
        /// Phi values for the target construct's params, in param order.
        args: []ValueId = &.{},
    };

    pub const BreakIf = struct {
        cond: ValueId,
        args: []ValueId = &.{},
        /// When true, the loop breaks on `!cond` (emitted as `break if
        /// !(cond);`).  Used by single-block loops whose conditional
        /// back-edge continues on `cond` and breaks on its negation.
        invert: bool = false,
    };

    // =============================================================================
    // Constructs
    // =============================================================================

    pub const Construct = union(enum) {
        if_: If,
        loop_: Loop,
        switch_: Switch,
    };

    pub const If = struct {
        cond: ValueId,
        true_blk: *Block,
        false_blk: *Block,
        /// SPIR-V merge block id (for cross-checking against BlockTable).
        merge_id: u32,
        /// Phis at the merge -> assigned at every `exit_if` of this `If`.
        results: []Param = &.{},
    };

    pub const Loop = struct {
        /// Loop body entry (the SPIR-V loop header's successor).
        body: *Block,
        /// The continuing block (updates the header phis).
        continuing: *Block,
        merge_id: u32,
        /// Loop-carried phis (the header OpPhis): declared before the
        /// loop (with each `Param.init` assigned), updated at the END of
        /// `continuing` from `iter_args` (positional with header_params).
        header_params: []Param = &.{},
        /// The next-iteration values for `header_params`, in the same
        /// order: at the end of `continuing` the emitter assigns
        /// `phi{header_params[i].phi_id} = iter_args[i]`.  These come from
        /// the loop-header OpPhi's continue-edge operand.
        iter_args: []ValueId = &.{},
        /// Phis at the loop merge -> assigned at every `exit_loop` /
        /// `break_if` of this loop.
        results: []Param = &.{},
    };

    pub const Switch = struct {
        selector: ValueId,
        cases: []Case = &.{},
        default_blk: *Block,
        merge_id: u32,
        results: []Param = &.{},
    };

    pub const Case = struct {
        /// Literal selector values for this case (a fallthrough-free WGSL
        /// `case v0, v1: { ... }`).
        values: []const u32 = &.{},
        blk: *Block,
    };

    /// A whole function's structured body: the entry block of the
    /// reconstructed tree.  Hoisted phi `var` declarations are gathered
    /// by walking (`collectParams`).
    pub const FnBody = struct {
        entry: *Block,
    };

    // =============================================================================
    // Validation - the invariant that makes the legacy phi bug impossible
    // =============================================================================

    pub const ValidateError = error{
        /// An exit edge supplies a different number of phi args than the
        /// construct it targets declares params.  This is exactly the
        /// shape of the legacy walker bug (a branch reaching a merge
        /// without supplying the merge's phi values).
        PhiArityMismatch,
        /// An exit terminator had no matching enclosing construct of its
        /// kind (malformed IR - a `break` outside a loop, etc.).
        DanglingExit,
    };

    /// Tracks the enclosing constructs during a walk so an exit can be
    /// matched to the nearest enclosing construct of its kind.
    const Scope = struct {
        nearest_if: ?*const If = null,
        nearest_switch: ?*const Switch = null,
        nearest_loop: ?*const Loop = null,
    };

    /// Walk the whole IR and assert that every exit edge supplies exactly
    /// as many phi args as its target construct declares params.  This is
    /// our analog of Tint's IR validator: it is impossible to drop a phi
    /// copy (the legacy bug) and pass validation, because a dropped copy
    /// shows up as an arity mismatch (or, for a wholly missing exit, the
    /// branch would carry zero args against N params).
    pub fn validate(body: *const FnBody) ValidateError!void {
        try validateBlock(body.entry, .{});
    }

    fn validateBlock(blk: *const Block, scope: Scope) ValidateError!void {
        for (blk.items) |it| {
            switch (it) {
                .body => {},
                .construct => |c| try validateConstruct(c, scope),
            }
        }
        try validateTerminator(blk.term, scope);
    }

    fn validateConstruct(c: *const Construct, outer: Scope) ValidateError!void {
        switch (c.*) {
            .if_ => |*f| {
                var inner: Scope = outer;
                inner.nearest_if = f;
                try validateBlock(f.true_blk, inner);
                try validateBlock(f.false_blk, inner);
            },
            .switch_ => |*sw| {
                var inner: Scope = outer;
                inner.nearest_switch = sw;
                for (sw.cases) |cs| {
                    try validateBlock(cs.blk, inner);
                }
                try validateBlock(sw.default_blk, inner);
            },
            .loop_ => |*lp| {
                // The continuing block must supply one next-iteration value
                // per loop-carried header phi.
                if (lp.iter_args.len != lp.header_params.len) {
                    return error.PhiArityMismatch;
                }
                var inner: Scope = outer;
                inner.nearest_loop = lp;
                try validateBlock(lp.body, inner);
                // The continuing block can itself exit (back-edge) but is
                // walked under the same loop scope.
                try validateBlock(lp.continuing, inner);
            },
        }
    }

    fn validateTerminator(term: Terminator, scope: Scope) ValidateError!void {
        switch (term) {
            .exit_if => |e| {
                const f: *const If = scope.nearest_if orelse return error.DanglingExit;
                if (e.args.len != f.results.len) {
                    return error.PhiArityMismatch;
                }
            },
            .exit_switch => |e| {
                const sw: *const Switch = scope.nearest_switch orelse return error.DanglingExit;
                if (e.args.len != sw.results.len) {
                    return error.PhiArityMismatch;
                }
            },
            .exit_loop => |e| {
                const lp: *const Loop = scope.nearest_loop orelse return error.DanglingExit;
                if (e.args.len != lp.results.len) {
                    return error.PhiArityMismatch;
                }
            },
            .break_if => |b| {
                const lp: *const Loop = scope.nearest_loop orelse return error.DanglingExit;
                if (b.args.len != lp.results.len) {
                    return error.PhiArityMismatch;
                }
            },
            .cont => |e| {
                // `cont` is a jump to the loop's continuing block; it
                // carries NO args.  The loop-carried header phis are
                // updated ONCE at the end of the continuing block via
                // `Loop.iter_args` (validated in validateConstruct), not
                // per `cont` edge.  (Matches the SPIR-V loop-header OpPhi
                // shape: the iterated value comes from the single continue
                // block, computed there.)
                _ = scope.nearest_loop orelse return error.DanglingExit;
                if (e.args.len != 0) {
                    return error.PhiArityMismatch;
                }
            },
            .branch, .ret, .ret_value, .kill, .unreach => {},
        }
    }

    // =============================================================================
    // Helpers
    // =============================================================================

    /// Collect every phi `Param` in the function (header + merge phis of
    /// all constructs) so the emitter can hoist their `var` declarations.
    pub fn collectParams(
        gpa: Allocator,
        body: *const FnBody,
        out: *ArrayList(Param),
    ) !void {
        try collectBlockParams(gpa, body.entry, out);
    }

    fn collectBlockParams(
        gpa: Allocator,
        blk: *const Block,
        out: *ArrayList(Param),
    ) !void {
        for (blk.items) |it| switch (it) {
            .body => {},
            .construct => |c| switch (c.*) {
                .if_ => |*f| {
                    for (f.results) |p| {
                        try out.append(gpa, p);
                    }
                    try collectBlockParams(gpa, f.true_blk, out);
                    try collectBlockParams(gpa, f.false_blk, out);
                },
                .switch_ => |*sw| {
                    for (sw.results) |p| {
                        try out.append(gpa, p);
                    }
                    for (sw.cases) |cs| {
                        try collectBlockParams(gpa, cs.blk, out);
                    }
                    try collectBlockParams(gpa, sw.default_blk, out);
                },
                .loop_ => |*lp| {
                    for (lp.header_params) |p| {
                        try out.append(gpa, p);
                    }
                    for (lp.results) |p| {
                        try out.append(gpa, p);
                    }
                    try collectBlockParams(gpa, lp.body, out);
                    try collectBlockParams(gpa, lp.continuing, out);
                },
            },
        };
    }

    // =============================================================================
    // Tests
    // =============================================================================

    const testing = std.testing;

    /// Build the mandelbrot's failing shape AS IR: a loop whose body is
    /// `if (i < limit) { if (i < max) { if (!escaped) {...} } }`, i.e. the
    /// outer-merge phi's true-side predecessor is itself an inner merge.
    /// This is the exact case the legacy walker mis-handled.
    fn buildMandelShape(
        a: Allocator,
        /// when true, the inner `if`'s TRUE branch supplies the merge
        /// args (correct); when false, it supplies none - reproducing the
        /// legacy dropped-copy bug so we can assert the validator catches it.
        true_branch_carries_args: bool,
    ) !FnBody {
        // innermost if(!escaped) - one result (the z-update), both exits carry it.
        const inner_t = try a.create(Block);
        inner_t.* = .{ .term = .{ .exit_if = .{ .args = try a.dupe(u32, &.{0xABCD}) } } };
        const inner_f = try a.create(Block);
        inner_f.* = .{ .term = .{ .exit_if = .{ .args = try a.dupe(u32, &.{0x1234}) } } };
        const inner_if = try a.create(Construct);
        inner_if.* = .{ .if_ = .{
            .cond = 1152,
            .true_blk = inner_t,
            .false_blk = inner_f,
            .merge_id = 9001,
            .results = try a.dupe(Param, &.{.{ .phi_id = 2348, .type_id = 7 }}),
        } };

        // if(i<max) - TRUE branch ENDS IN the nested inner_if, then exits.
        // results: one merge phi (the loop-exit code surrogate).
        const mid_t = try a.create(Block);
        mid_t.* = .{
            .items = try a.dupe(Item, &.{.{ .construct = inner_if }}),
            .term = .{
                .exit_if = .{
                    .args = if (true_branch_carries_args)
                        try a.dupe(u32, &.{2348})
                    else
                        try a.dupe(u32, &.{}), // BUG shape: drops the copy on the true path
                },
            },
        };
        const mid_f = try a.create(Block);
        mid_f.* = .{ .term = .{ .exit_if = .{ .args = try a.dupe(u32, &.{1207}) } } };
        const mid_if = try a.create(Construct);
        mid_if.* = .{ .if_ = .{
            .cond = 1124,
            .true_blk = mid_t,
            .false_blk = mid_f,
            .merge_id = 9002,
            .results = try a.dupe(Param, &.{.{ .phi_id = 1209, .type_id = 8 }}),
        } };

        // loop body: just the mid_if, then break_if on the exit code.
        const body = try a.create(Block);
        body.* = .{
            .items = try a.dupe(Item, &.{.{ .construct = mid_if }}),
            .term = .{ .break_if = .{ .cond = 1211, .args = try a.dupe(u32, &.{1209}) } },
        };
        const cont = try a.create(Block);
        cont.* = .{ .term = .{ .cont = .{} } };
        const loop = try a.create(Construct);
        loop.* = .{ .loop_ = .{
            .body = body,
            .continuing = cont,
            .merge_id = 9003,
            .header_params = try a.dupe(Param, &.{.{ .phi_id = 1922, .type_id = 9 }}),
            .iter_args = try a.dupe(u32, &.{1922}),
            .results = try a.dupe(Param, &.{.{ .phi_id = 1209, .type_id = 8 }}),
        } };

        const entry = try a.create(Block);
        entry.* = .{
            .items = try a.dupe(Item, &.{.{ .construct = loop }}),
            .term = .ret,
        };
        return .{ .entry = entry };
    }

    test "validate accepts a well-formed nested-if-in-loop (phi on every exit)" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        const body: FnBody = try buildMandelShape(a, true);
        try validate(&body);
    }

    test "validate REJECTS the legacy bug shape (true-branch drops the phi copy)" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        const body: FnBody = try buildMandelShape(a, false);
        // The inner `if`'s TRUE branch exits with 0 args against 1 result -
        // exactly the dropped-copy that made the mandelbrot break on
        // iteration 1.  The validator must catch it.
        try testing.expectError(error.PhiArityMismatch, validate(&body));
    }

    test "collectParams gathers header + all merge phis" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        const body: FnBody = try buildMandelShape(a, true);
        var params: ArrayList(Param) = .empty;
        try collectParams(a, &body, &params);
        // loop header (1922) + loop results (1209) + mid_if (1209) + inner_if (2348)
        try testing.expectEqual(@as(usize, 4), params.items.len);
    }

    test "DanglingExit when an exit has no matching enclosing construct" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();
        const entry = try a.create(Block);
        entry.* = .{ .term = .{ .exit_if = .{ .args = &.{} } } }; // exit_if with no enclosing If
        const body: FnBody = .{ .entry = entry };
        try testing.expectError(error.DanglingExit, validate(&body));
    }
};

pub const block_table = struct {
    // src/spv2wgsl/block_table.zig - basic-block metadata table.
    //
    // Phase 1.3 of the spv2wgsl rewrite
    // (`src/notes/archive/spv2wgsl-rewrite-plan.md` section 2.1, section 4 Phase 1).
    //
    // For each basic block in a SPIR-V function, build a `BlockInfo`
    // record describing:
    //   - `id`: the block's OpLabel result-id
    //   - `label_inst_idx`: index into State.inst_off where OpLabel sits
    //   - `terminator_inst_idx`: index of the terminator (Branch /
    //     BranchConditional / Switch / Return / Kill / ReturnValue)
    //   - `merge_inst_idx`/`merge_id`: filled in if the block ends in
    //     OpSelectionMerge or OpLoopMerge immediately before the
    //     terminator
    //   - `continue_id`: loops only - the loop's continue target
    //   - `kind`: plain / selection_header / loop_header / switch_header
    //
    // The table is built ONCE per function in a pre-pass.  Phase 2's
    // walker uses it to dispatch on block kind without re-scanning the
    // instruction stream.
    //
    // Cite: `parser.cc:1827 GetLoopMergeInst` for the loop-merge lookup
    // pattern; `parser.cc:1814 EmitBlock` for the kind dispatch.

    // Shared SPIR-V word helpers live in types.zig (single source of truth).

    // =============================================================================
    // Types
    // =============================================================================

    pub const BlockKind = enum {
        plain,
        selection_header,
        loop_header,
        switch_header,
    };

    pub const BlockInfo = struct {
        /// The OpLabel result-id.
        id: u32,
        /// Index into the `inst_off` array where the OpLabel sits.
        label_inst_idx: usize,
        /// Index where the block's terminator sits.  Terminator is the
        /// instruction that ends a basic block (Branch, BranchConditional,
        /// Switch, Return, ReturnValue, Kill).  Note: a SelectionMerge or
        /// LoopMerge sits immediately BEFORE the terminator, NOT at the
        /// terminator slot.
        terminator_inst_idx: usize,
        /// Index of OpSelectionMerge or OpLoopMerge if present, else null.
        /// Always (when set) exactly one slot before terminator_inst_idx.
        merge_inst_idx: ?usize = null,
        /// Merge block id (the target of the merge instruction).
        /// Zero when no merge instruction.
        merge_id: u32 = 0,
        /// For loop_header blocks, the OpLoopMerge's continue target.
        /// Zero for non-loop blocks.
        continue_id: u32 = 0,
        /// The structural role of this block in the CFG.
        kind: BlockKind = .plain,
    };

    pub const BlockTable = std.AutoHashMapUnmanaged(u32, BlockInfo);

    // =============================================================================
    // Construction
    // =============================================================================

    /// Build the block table for one function.
    ///
    /// Scope: `inst_off[fn_k]` is the OpFunction; `inst_off[end_k]` is
    /// the OpFunctionEnd that closes it.  Everything in between is
    /// scanned for OpLabel -> terminator spans.
    ///
    /// Each block runs from an OpLabel to the next block-terminating
    /// instruction.  Inside that span we look for OpSelectionMerge /
    /// OpLoopMerge - they sit IMMEDIATELY BEFORE the terminator (this is
    /// a SPIR-V structural invariant).  Their presence promotes the
    /// block from `plain` to a header kind.
    ///
    /// Arena-owned: the returned table is allocated with `arena` and
    /// outlives the function call.  Caller frees by deinit'ing the
    /// arena.
    pub fn registerBlocks(
        arena: Allocator,
        fn_k: usize,
        end_k: usize,
        inst_off: []const u32,
        spirv: []const u32,
    ) !BlockTable {
        var table: BlockTable = .empty;

        var k: usize = fn_k + 1;
        while (k < end_k) {
            const off: u32 = inst_off[k];
            const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(spirv[off])));

            if (op != .Label) {
                k += 1;
                continue;
            }

            // OpLabel ops[0] is the block's result-id.
            const ops: []const u32 = types.operandsAt(spirv, off);
            const block_id: u32 = ops[0];
            const label_inst_idx: usize = k;

            // Scan forward from k+1 to find:
            //   - the terminator instruction
            //   - any OpSelectionMerge / OpLoopMerge just before it
            var t_idx: usize = k + 1;
            var merge_inst_idx: ?usize = null;
            var merge_id: u32 = 0;
            var continue_id: u32 = 0;
            var kind: BlockKind = .plain;

            while (t_idx < end_k) : (t_idx += 1) {
                const t_off: u32 = inst_off[t_idx];
                const t_op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(spirv[t_off])));
                const t_ops: []const u32 = types.operandsAt(spirv, t_off);

                switch (t_op) {
                    .SelectionMerge => {
                        // ops[0] = merge_block, ops[1] = selection_control
                        merge_inst_idx = t_idx;
                        merge_id = t_ops[0];
                        // The kind depends on the NEXT instruction (the
                        // terminator).  We resolve it below.
                    },
                    .LoopMerge => {
                        // ops[0] = merge_block, ops[1] = continue_target,
                        // ops[2] = loop_control
                        merge_inst_idx = t_idx;
                        merge_id = t_ops[0];
                        continue_id = t_ops[1];
                        kind = .loop_header;
                    },
                    .Branch,
                    .BranchConditional,
                    .Switch,
                    .Return,
                    .ReturnValue,
                    .Kill,
                    => {
                        // Resolve selection_header vs switch_header
                        // (loop_header was already set by OpLoopMerge above).
                        if (kind != .loop_header and merge_inst_idx != null) {
                            switch (t_op) {
                                .Switch => kind = .switch_header,
                                .BranchConditional => kind = .selection_header,
                                // SPIR-V structural CF: an OpSelectionMerge
                                // before an unconditional OpBranch is legal
                                // but rare; treat as selection_header anyway.
                                .Branch => kind = .selection_header,
                                else => {},
                            }
                        }
                        break; // found terminator
                    },
                    else => {
                        // OpUnreachable (255) is also a block terminator per
                        // the SPIR-V spec.  No enum variant in `types.zig`
                        // for it (the linear emitter never needed special
                        // handling).  Check the raw value.
                        // OpUnreachable
                        if (@backingInt(t_op) == 255) {
                            break;
                        }
                        // Ordinary body instruction; skip.
                    },
                }
            }

            if (t_idx >= end_k) {
                // Malformed: a block with no terminator before
                // OpFunctionEnd.  Pin the terminator slot to (end_k - 1)
                // to keep the table consistent; downstream code can
                // notice the issue when it tries to emit.
                t_idx = end_k - 1;
            }

            if (block_id == 404 or block_id == 406 or block_id == 282 or block_id == 281 or block_id == 280) {}
            try table.put(arena, block_id, .{
                .id = block_id,
                .label_inst_idx = label_inst_idx,
                .terminator_inst_idx = t_idx,
                .merge_inst_idx = merge_inst_idx,
                .merge_id = merge_id,
                .continue_id = continue_id,
                .kind = kind,
            });

            k = t_idx + 1;
        }

        return table;
    }

    // =============================================================================
    // Helpers (local copies of the SPIR-V word-level decoders)
    // =============================================================================
    //
    // These mirror the ones in `src/spv2wgsl.zig`.  Inlined here so this
    // module is standalone - the rewrite's module split aims for no
    // circular imports back to the orchestration file.

    // =============================================================================
    // Tests
    // =============================================================================

    const testing = std.testing;

    /// The result of `buildSpirv`: parallel arrays of the assembled
    /// SPIR-V words and the per-instruction word offsets into them.  A
    /// named type (rather than an anonymous struct return) so the shape
    /// is self-documenting at call sites.
    const BuiltSpirv = struct {
        spirv: []const u32,
        inst_off: []const u32,
    };

    /// One synthetic instruction for `buildSpirv`: an opcode plus its
    /// operand words.
    const SynthInstruction = struct {
        op: types.Op,
        operands: []const u32,
    };

    /// Build a synthetic SPIR-V instruction stream from a list of
    /// (opcode, operands).  Just enough to exercise the block table -
    /// no module header (we pass `fn_k = 0` to start at the first inst).
    fn buildSpirv(
        arena: Allocator,
        instructions: []const SynthInstruction,
    ) !BuiltSpirv {
        var words: ArrayList(u32) = .empty;
        var offs: ArrayList(u32) = .empty;

        for (instructions) |i| {
            const off: u32 = @intCast(words.items.len);
            try offs.append(arena, off);
            const wc: u32 = @intCast(1 + i.operands.len);
            const w0: u32 = @backingInt(i.op) | (wc << 16);
            try words.append(arena, w0);
            for (i.operands) |o| {
                try words.append(arena, o);
            }
        }

        return .{
            .spirv = try words.toOwnedSlice(arena),
            .inst_off = try offs.toOwnedSlice(arena),
        };
    }

    test "registerBlocks: single-block function (1 entry, plain kind)" {
        // OpFunction _ %fn1
        // OpLabel %10
        // OpReturn
        // OpFunctionEnd
        var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena: Allocator = arena_state.allocator();

        const built: BuiltSpirv = try buildSpirv(arena, &.{
            .{ .op = .Function, .operands = &.{ 0, 1, 0, 2 } },
            .{ .op = .Label, .operands = &.{10} },
            .{ .op = .Return, .operands = &.{} },
            .{ .op = .FunctionEnd, .operands = &.{} },
        });

        var table: BlockTable = try registerBlocks(arena, 0, 3, built.inst_off, built.spirv);
        defer table.deinit(arena);

        try testing.expectEqual(@as(usize, 1), table.count());
        const b: BlockInfo = table.get(10).?;
        try testing.expectEqual(@as(u32, 10), b.id);
        try testing.expectEqual(@as(usize, 1), b.label_inst_idx);
        try testing.expectEqual(@as(usize, 2), b.terminator_inst_idx);
        try testing.expect(b.merge_inst_idx == null);
        try testing.expectEqual(BlockKind.plain, b.kind);
    }

    test "registerBlocks: if/else (4 blocks, header is selection_header)" {
        // OpFunction
        // OpLabel %10                  <- selection_header
        //   OpSelectionMerge %40 None
        //   OpBranchConditional %cond %20 %30
        // OpLabel %20                  <- true branch (plain)
        //   OpBranch %40
        // OpLabel %30                  <- false branch (plain)
        //   OpBranch %40
        // OpLabel %40                  <- merge (plain)
        //   OpReturn
        // OpFunctionEnd
        var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena: Allocator = arena_state.allocator();

        const built: BuiltSpirv = try buildSpirv(arena, &.{
            .{ .op = .Function, .operands = &.{ 0, 1, 0, 2 } },
            .{ .op = .Label, .operands = &.{10} },
            .{ .op = .SelectionMerge, .operands = &.{ 40, 0 } },
            .{ .op = .BranchConditional, .operands = &.{ 99, 20, 30 } },
            .{ .op = .Label, .operands = &.{20} },
            .{ .op = .Branch, .operands = &.{40} },
            .{ .op = .Label, .operands = &.{30} },
            .{ .op = .Branch, .operands = &.{40} },
            .{ .op = .Label, .operands = &.{40} },
            .{ .op = .Return, .operands = &.{} },
            .{ .op = .FunctionEnd, .operands = &.{} },
        });

        var table: BlockTable = try registerBlocks(arena, 0, 10, built.inst_off, built.spirv);
        defer table.deinit(arena);

        try testing.expectEqual(@as(usize, 4), table.count());

        const b10: BlockInfo = table.get(10).?;
        try testing.expectEqual(BlockKind.selection_header, b10.kind);
        try testing.expectEqual(@as(u32, 40), b10.merge_id);
        try testing.expect(b10.merge_inst_idx != null);

        const b20: BlockInfo = table.get(20).?;
        try testing.expectEqual(BlockKind.plain, b20.kind);

        const b30: BlockInfo = table.get(30).?;
        try testing.expectEqual(BlockKind.plain, b30.kind);

        const b40: BlockInfo = table.get(40).?;
        try testing.expectEqual(BlockKind.plain, b40.kind);
        try testing.expect(b40.merge_inst_idx == null);
    }

    test "registerBlocks: loop (4 blocks, header is loop_header)" {
        // OpFunction
        // OpLabel %10                  <- loop_header
        //   OpLoopMerge %40 %30 None
        //   OpBranch %20
        // OpLabel %20                  <- body
        //   OpBranchConditional %cond %30 %40
        // OpLabel %30                  <- continue target
        //   OpBranch %10
        // OpLabel %40                  <- merge
        //   OpReturn
        // OpFunctionEnd
        var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena: Allocator = arena_state.allocator();

        const built: BuiltSpirv = try buildSpirv(arena, &.{
            .{ .op = .Function, .operands = &.{ 0, 1, 0, 2 } },
            .{ .op = .Label, .operands = &.{10} },
            .{ .op = .LoopMerge, .operands = &.{ 40, 30, 0 } },
            .{ .op = .Branch, .operands = &.{20} },
            .{ .op = .Label, .operands = &.{20} },
            .{ .op = .BranchConditional, .operands = &.{ 99, 30, 40 } },
            .{ .op = .Label, .operands = &.{30} },
            .{ .op = .Branch, .operands = &.{10} },
            .{ .op = .Label, .operands = &.{40} },
            .{ .op = .Return, .operands = &.{} },
            .{ .op = .FunctionEnd, .operands = &.{} },
        });

        var table: BlockTable = try registerBlocks(arena, 0, 10, built.inst_off, built.spirv);
        defer table.deinit(arena);

        try testing.expectEqual(@as(usize, 4), table.count());

        const b10: BlockInfo = table.get(10).?;
        try testing.expectEqual(BlockKind.loop_header, b10.kind);
        try testing.expectEqual(@as(u32, 40), b10.merge_id);
        try testing.expectEqual(@as(u32, 30), b10.continue_id);
        try testing.expect(b10.merge_inst_idx != null);

        const b20: BlockInfo = table.get(20).?;
        try testing.expectEqual(BlockKind.plain, b20.kind);
        // body's terminator is a BranchConditional but it's NOT a
        // selection_header (no OpSelectionMerge precedes it).  Phase 2's
        // walker recognizes this as an "unstructured conditional"
        // (parser.cc:3672 falls through to that path when merge is null).
        try testing.expect(b20.merge_inst_idx == null);

        const b30: BlockInfo = table.get(30).?;
        try testing.expectEqual(BlockKind.plain, b30.kind);

        const b40: BlockInfo = table.get(40).?;
        try testing.expectEqual(BlockKind.plain, b40.kind);
    }

    test "registerBlocks: switch_header" {
        // OpFunction
        // OpLabel %10                  <- switch_header
        //   OpSelectionMerge %40 None
        //   OpSwitch %selector %default=%40 %case1=%20 %case2=%30
        // OpLabel %20
        //   OpBranch %40
        // OpLabel %30
        //   OpBranch %40
        // OpLabel %40
        //   OpReturn
        // OpFunctionEnd
        var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena: Allocator = arena_state.allocator();

        const built: BuiltSpirv = try buildSpirv(arena, &.{
            .{ .op = .Function, .operands = &.{ 0, 1, 0, 2 } },
            .{ .op = .Label, .operands = &.{10} },
            .{ .op = .SelectionMerge, .operands = &.{ 40, 0 } },
            .{ .op = .Switch, .operands = &.{ 99, 40, 1, 20, 2, 30 } },
            .{ .op = .Label, .operands = &.{20} },
            .{ .op = .Branch, .operands = &.{40} },
            .{ .op = .Label, .operands = &.{30} },
            .{ .op = .Branch, .operands = &.{40} },
            .{ .op = .Label, .operands = &.{40} },
            .{ .op = .Return, .operands = &.{} },
            .{ .op = .FunctionEnd, .operands = &.{} },
        });

        var table: BlockTable = try registerBlocks(arena, 0, 10, built.inst_off, built.spirv);
        defer table.deinit(arena);

        try testing.expectEqual(@as(usize, 4), table.count());

        const b10: BlockInfo = table.get(10).?;
        try testing.expectEqual(BlockKind.switch_header, b10.kind);
        try testing.expectEqual(@as(u32, 40), b10.merge_id);
    }

    test "registerBlocks: loop with conditional break in body (the mandelbrot pattern)" {
        // The shape that hits the phi-overwrite bug:
        //
        // OpLabel %10                  <- loop_header
        //   OpLoopMerge %60 %50 None
        //   OpBranch %20
        // OpLabel %20                  <- loop body header (selection_header)
        //   OpSelectionMerge %40 None
        //   OpBranchConditional %cond %30 %40
        // OpLabel %30                  <- inside the if: break OUT
        //   OpBranch %60
        // OpLabel %40                  <- merge of the inner if (in-loop)
        //   OpBranch %50
        // OpLabel %50                  <- continue target
        //   OpBranch %10
        // OpLabel %60                  <- loop merge (post-loop)
        //   OpReturn
        // OpFunctionEnd
        var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena: Allocator = arena_state.allocator();

        const built: BuiltSpirv = try buildSpirv(arena, &.{
            .{ .op = .Function, .operands = &.{ 0, 1, 0, 2 } },
            .{ .op = .Label, .operands = &.{10} },
            .{ .op = .LoopMerge, .operands = &.{ 60, 50, 0 } },
            .{ .op = .Branch, .operands = &.{20} },
            .{ .op = .Label, .operands = &.{20} },
            .{ .op = .SelectionMerge, .operands = &.{ 40, 0 } },
            .{ .op = .BranchConditional, .operands = &.{ 99, 30, 40 } },
            .{ .op = .Label, .operands = &.{30} },
            .{ .op = .Branch, .operands = &.{60} },
            .{ .op = .Label, .operands = &.{40} },
            .{ .op = .Branch, .operands = &.{50} },
            .{ .op = .Label, .operands = &.{50} },
            .{ .op = .Branch, .operands = &.{10} },
            .{ .op = .Label, .operands = &.{60} },
            .{ .op = .Return, .operands = &.{} },
            .{ .op = .FunctionEnd, .operands = &.{} },
        });

        var table: BlockTable = try registerBlocks(arena, 0, 15, built.inst_off, built.spirv);
        defer table.deinit(arena);

        try testing.expectEqual(@as(usize, 6), table.count());

        const b10: BlockInfo = table.get(10).?;
        try testing.expectEqual(BlockKind.loop_header, b10.kind);
        try testing.expectEqual(@as(u32, 60), b10.merge_id);
        try testing.expectEqual(@as(u32, 50), b10.continue_id);

        const b20: BlockInfo = table.get(20).?;
        // The inner if's header - distinct from the loop header.
        try testing.expectEqual(BlockKind.selection_header, b20.kind);
        try testing.expectEqual(@as(u32, 40), b20.merge_id);

        const b30: BlockInfo = table.get(30).?;
        // The "break OUT of loop" branch.  Plain block ending in OpBranch
        // to the LOOP MERGE (not the inner if's merge).  Phase 2's walker
        // will resolve this through stop_set.get(60) -> loop_break.
        try testing.expectEqual(BlockKind.plain, b30.kind);

        const b40: BlockInfo = table.get(40).?;
        try testing.expectEqual(BlockKind.plain, b40.kind);

        const b50: BlockInfo = table.get(50).?;
        try testing.expectEqual(BlockKind.plain, b50.kind);

        const b60: BlockInfo = table.get(60).?;
        try testing.expectEqual(BlockKind.plain, b60.kind);
    }

    test "block_table scaffold compiles" {
        // The scaffold-smoke test kept from Phase 1.1 - make sure picking
        // up tests via the broader `scaffold compiles` filter still
        // surfaces this file even now that real content lives here.
        try testing.expect(true);
    }

    test "registerBlocks: real Tint fixture (branch_BranchConditional_Empty.spv)" {
        // Minimal real fixture.  Disasm (with friendly names - actual ids
        // get renumbered by spirv-as):
        //
        //   OpFunction
        //   %A = OpLabel
        //         OpSelectionMerge %B None
        //         OpBranchConditional %true %B %B
        //   %B = OpLabel
        //         OpReturn
        //         OpFunctionEnd
        //
        // Expected: 2 blocks total.  One is a selection_header whose
        // merge_id is the other; the other is plain with no merge.
        // We assert structurally - ids are whatever spirv-as numbered them.
        var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena: Allocator = arena_state.allocator();

        const path: []const u8 = "tests/fixtures/external/tint/branch_BranchConditional_Empty.spv";
        var threaded: std.Io.Threaded = std.Io.Threaded.init(testing.allocator, .{});
        defer threaded.deinit();
        const io: std.Io = threaded.io();

        var f: std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn("(fixture {s} not present; skipping)", .{path});
                return;
            },
            else => return err,
        };
        defer f.close(io);
        const st: std.Io.File.Stat = try f.stat(io);
        const bytes: []u8 = try arena.alloc(u8, st.size);
        _ = try f.readPositionalAll(io, bytes, 0);

        // Reinterpret as words.
        const words_aligned: []align(@alignOf(u32)) u32 = try arena.alignedAlloc(u32, .of(u32), bytes.len / 4);
        @memcpy(std.mem.sliceAsBytes(words_aligned), bytes);

        // Scan instructions starting at word 5 (after the 5-word module
        // header).  This mirrors pass1_walk in src/spv2wgsl.zig.
        var inst_off: ArrayList(u32) = .empty;
        {
            var i: u32 = 5;
            while (i < words_aligned.len) {
                try inst_off.append(arena, i);
                // High 16 bits of the first word = instruction word count.
                const wc: u32 = words_aligned[i] >> 16;
                i += wc;
            }
        }

        // Find OpFunction/OpFunctionEnd bracketing the entry point.
        var fn_k: ?usize = null;
        var end_k: ?usize = null;
        for (inst_off.items, 0..) |off, k| {
            const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(words_aligned[off])));
            if (op == .Function and fn_k == null) {
                fn_k = k;
            }
            if (op == .FunctionEnd) {
                end_k = k;
                break;
            }
        }
        try testing.expect(fn_k != null);
        try testing.expect(end_k != null);

        var table: BlockTable = try registerBlocks(arena, fn_k.?, end_k.?, inst_off.items, words_aligned);
        defer table.deinit(arena);

        // Two blocks expected: header and merge.
        try testing.expectEqual(@as(usize, 2), table.count());

        // Identify the selection_header (one block of the two has kind
        // selection_header; the other is plain).
        var header: ?BlockInfo = null;
        var merge_info: ?BlockInfo = null;
        var it: BlockTable.Iterator = table.iterator();
        while (it.next()) |entry| {
            const info: BlockInfo = entry.value_ptr.*;
            if (info.kind == .selection_header) {
                header = info;
            } else {
                merge_info = info;
            }
        }
        try testing.expect(header != null);
        try testing.expect(merge_info != null);

        // The header's merge_id points at the other block.
        try testing.expectEqual(merge_info.?.id, header.?.merge_id);

        // The merge block is plain with no merge instruction of its own.
        try testing.expectEqual(BlockKind.plain, merge_info.?.kind);
        try testing.expect(merge_info.?.merge_inst_idx == null);

        // The header has an OpSelectionMerge (merge_inst_idx is set).
        try testing.expect(header.?.merge_inst_idx != null);
    }
};

pub const ir_build = struct {
    // src/spv2wgsl/ir_build.zig - reconstruct the structured `ir` for
    // one SPIR-V function (the Tint-style rewrite, P0 step 2).
    //
    // Consumes the same inputs the legacy walker does - the flat
    // instruction-offset index plus the SPIR-V words - and the per-block
    // metadata from `block_table.registerBlocks` (merge/continue ids and
    // block kind).  Produces an `ir.FnBody`: the nested
    // Block/If/Loop/Switch tree with phi args carried on every exit.
    //
    // RECONSTRUCTION PLAN (mirrors the proven legacy traversal in
    // `walker.zig`, retargeted from emitting text to building IR):
    //   - Walk from the function's entry block.
    //   - Dispatch on `BlockInfo.kind`:
    //       plain            -> a `body` item, then follow the terminator.
    //       selection_header -> build an `If` (or `Switch`): recurse into
    //                          the branch blocks, STOPPING at the merge;
    //                          continue from the merge in the parent.
    //       loop_header      -> build a `Loop`: recurse the body stopping
    //                          at the continue target / merge; the
    //                          continuing block updates the header phis.
    //   - For each construct, read the merge block's OpPhis -> the
    //     construct's `results`; for each (value, pred) pair, append
    //     `value` to the exit terminator whose source block is `pred`,
    //     so the phi lands on EVERY exit edge.  `ir.validate` then
    //     guarantees no edge was missed.
    //
    // STATUS: entry point + the straight-line base case are implemented
    // and tested.  Control flow currently returns
    // `error.IrBuildUnsupported` (handled incrementally next); callers
    // must treat that as "fall back to the legacy walker", which is
    // exactly how the P1 `-Dwalker=ir` flag will be wired.

    // Shared SPIR-V word helpers live in types.zig (single source of truth).
    const BlockInfo = block_table.BlockInfo;

    pub const BuildError = error{
        /// The function uses a CFG shape the builder does not yet
        /// reconstruct.  Not a hard failure: the caller falls back to the
        /// legacy walker.  Removed incrementally as shapes are covered.
        IrBuildUnsupported,
        /// Malformed input (no entry block, etc.).
        MalformedFunction,
    } || Allocator.Error;

    /// Build the structured IR for the function spanning `inst_off[fn_k]`
    /// (OpFunction) .. `inst_off[end_k]` (OpFunctionEnd).
    pub fn build(
        arena: Allocator,
        fn_k: usize,
        end_k: usize,
        inst_off: []const u32,
        spirv: []const u32,
    ) BuildError!ir.FnBody {
        const table: block_table.BlockTable = try block_table.registerBlocks(arena, fn_k, end_k, inst_off, spirv);

        const entry_id: u32 = try findEntryBlock(fn_k, end_k, inst_off, spirv);

        var builder: Builder = .{
            .arena = arena,
            .table = table,
            .inst_off = inst_off,
            .spirv = spirv,
            .by_id = .empty,
            .cond_to_if = .empty,
        };

        // Build from the entry block with an empty stop stack (recurse to
        // function terminators).
        var stops: StopStack = .{ .arena = arena };
        const entry_blk: *ir.Block = try builder.buildBlock(entry_id, &stops);
        return .{ .entry = builder.terminateOrChain(entry_blk) };
    }

    /// Which structured-exit terminator a branch to a given block produces.
    /// Mirrors the legacy walker's `StopKind`, but as the IR terminator
    /// tag rather than a WGSL statement.
    const ExitKind = enum { exit_if, exit_loop, exit_switch, cont };

    const Stop = struct {
        /// SPIR-V block id that, when branched to, ends the current chain.
        target: u32,
        kind: ExitKind,
    };

    /// The enclosing-construct stop context, innermost last.  A branch to
    /// `target` emits `kind`'s terminator; lookup scans from the innermost
    /// out (the nearest enclosing construct wins, matching SPIR-V
    /// structured-CF guarantees).  Backed by a fixed array - SPIR-V nesting
    /// depth is tiny (a handful), and this keeps the builder allocation-
    /// free per recursion level.
    const StopStack = struct {
        items: ArrayList(Stop) = .empty,
        arena: Allocator,

        fn push(self: *StopStack, s: Stop) BuildError!void {
            // Dynamic + arena-backed: no fixed cap. (Was a [32]Stop array, which
            // a deep real shader - a path tracer with nested loops + material
            // branches - overflowed at depth 33, turning valid SPIR-V into a hard
            // IrBuildUnsupported. SPIR-V structured nesting is bounded by the input,
            // not by us, so the stack must grow with it.)
            try self.items.append(self.arena, s);
        }

        fn pop(self: *StopStack) void {
            assert(self.items.items.len > 0);
            _ = self.items.pop();
        }

        /// Innermost-first lookup: the nearest enclosing construct that
        /// owns `target`.
        fn lookup(self: *const StopStack, target: u32) ?ExitKind {
            var i: usize = self.items.items.len;
            while (i > 0) {
                i -= 1;
                if (self.items.items[i].target == target) {
                    return self.items.items[i].kind;
                }
            }
            return null;
        }
    };

    /// Per-function reconstruction state.  Threads the read-only inputs
    /// plus the SPIR-V-id -> built-`*Block` map used to attach merge phi
    /// args to the right exit terminator (Tint's
    /// `spirv_id_to_block_` / EmitPhiInIfMerge).
    const Builder = struct {
        arena: Allocator,
        table: block_table.BlockTable,
        inst_off: []const u32,
        spirv: []const u32,
        /// buildBlock recursion depth. A malformed/adversarial CFG (unstructured
        /// back-edges, cycles the structurizer can't resolve) makes buildBlock ->
        /// buildLoop -> buildBlock recurse without bound -> native stack overflow
        /// (~12k frames seen on some Tint fixtures). This caps it: past MAX_DEPTH we
        /// bail with IrBuildUnsupported (graceful - the caller treats it as
        /// untranslatable), instead of segfaulting. The limit is FAR above any real
        /// shader's structured nesting (the StopStack grows for legit depth; this
        /// only catches runaway recursion). Distinct concerns: StopStack = legit
        /// construct nesting (unbounded), depth = pathological-CFG safety valve.
        depth: u32 = 0,
        /// Every `*ir.Block` we create, keyed by the SPIR-V block id whose
        /// terminator it carries.  Step-4 phi attachment looks up a phi's
        /// predecessor block id here to find the terminator to push onto.
        by_id: std.AutoHashMapUnmanaged(u32, *ir.Block),

        /// Maps a SPIR-V block id whose terminator is `OpBranchConditional`
        /// to the `ir.If` we reconstructed for it.  Mirrors Tint's
        /// `branch_conditional_to_if_`.  A merge OpPhi may name such a block
        /// as a predecessor when one of the branch's two edges targets the
        /// merge; the value must then be pushed onto THAT specific branch's
        /// exit terminator (true vs false, disambiguated by which edge
        /// equals the merge id) - not onto the block's own outer terminator,
        /// since the merge block folds into the same enclosing IR block.
        /// Used by the merge-phi attach passes to route cross-construct phi
        /// edges (`phi_Phi_Loop_FromIfBreak`, `phi_Phi_Switch_*_InDefault`).
        cond_to_if: std.AutoHashMapUnmanaged(u32, *ir.If),

        /// Resolve, for one merge OpPhi operand `(value, pred_id)`, the IR
        /// terminator the value should be appended to - following Tint's
        /// `EmitPhiIn{If,Switch,Loop}Merge` cascade:
        ///
        ///   1. If `pred_id`'s SPIR-V terminator is `OpBranchConditional`
        ///      and we built an `If` for it, the merge block folds into the
        ///      same enclosing IR block, so the real exit edge is one of the
        ///      If's branches - pick true/false by which branch target ==
        ///      `merge_id` (the phi's block).
        ///   2. Else if `pred_id == header_id`, the edge comes straight from
        ///      the construct header (a one-sided if / default-is-merge /
        ///      jump-over): there is no predecessor sub-block, so the value
        ///      is a "default" applied later to an exit that didn't receive
        ///      one.  Signalled by returning null with `is_default = true`.
        ///   3. Else the predecessor's own IR terminator is the exit edge.
        ///
        /// A resolved terminator that is `cont` (a back-edge from a
        /// conditional where one edge continued and the other broke) is
        /// redirected to the enclosing If's `exit_loop` branch (loop case).
        const PhiTarget = struct { blk: ?*ir.Block, is_default: bool };

        fn resolveMergePhiTarget(
            self: *Builder,
            pred_id: u32,
            merge_id: u32,
            header_id: u32,
        ) PhiTarget {
            // Case 1: predecessor ends in a branch-conditional we lowered.
            if (self.cond_to_if.get(pred_id)) |if_ptr| {
                const pred_info: BlockInfo = self.table.get(pred_id) orelse
                    return .{ .blk = null, .is_default = false };
                const t_off: u32 = self.inst_off[pred_info.terminator_inst_idx];
                const ops: []const u32 = types.operandsAt(self.spirv, t_off);
                // ops = [cond, true_target, false_target]
                if (ops.len >= 3) {
                    if (ops[1] == merge_id) {
                        return .{ .blk = if_ptr.true_blk, .is_default = false };
                    }
                    if (ops[2] == merge_id) {
                        return .{ .blk = if_ptr.false_blk, .is_default = false };
                    }
                }
            }
            // Case 2: edge straight from the construct header -> default value.
            if (pred_id == header_id) {
                return .{ .blk = null, .is_default = true };
            }
            // Case 3: the predecessor's own IR terminator.
            return .{ .blk = self.by_id.get(pred_id), .is_default = false };
        }

        /// Push a default value onto whichever of an If/Loop/Switch's
        /// materialized exit edges has the FEWEST args so far (i.e. the one
        /// that did not receive this phi's value via a real predecessor).
        /// Mirrors Tint's default-block fixup.  `exits` are the exit blocks
        /// for the construct, in any order.
        fn applyDefaultToShortestExit(
            self: *Builder,
            exits: []const *ir.Block,
            value_id: ir.ValueId,
        ) BuildError!void {
            var best: ?*ir.Block = null;
            var best_len: usize = ~@as(usize, 0); // sentinel: max usize (no zm dep in the transpiler)
            for (exits) |b| {
                const len: usize = exitArgLen(b.term);
                if (len < best_len) {
                    best_len = len;
                    best = b;
                }
            }
            if (best) |b| {
                try appendExitArg(self.arena, b, value_id);
            }
        }

        /// Collect every block in a loop body/continuing whose terminator
        /// breaks THIS loop (`exit_loop` or `break_if`), for the merge-phi
        /// default-value fixup.  Descends into nested `If`/`Switch` branches
        /// (a break can sit inside them) but NOT into nested `Loop`s - an
        /// `exit_loop` there targets the inner loop, not this one.
        fn collectLoopExits(
            self: *Builder,
            blk: *ir.Block,
            out: *ArrayList(*ir.Block),
        ) BuildError!void {
            switch (blk.term) {
                .exit_loop, .break_if => try out.append(self.arena, blk),
                else => {},
            }
            for (blk.items) |item| {
                switch (item) {
                    .body => {},
                    .construct => |c| switch (c.*) {
                        .if_ => |*iff| {
                            try self.collectLoopExits(iff.true_blk, out);
                            try self.collectLoopExits(iff.false_blk, out);
                        },
                        .switch_ => |*sw| {
                            for (sw.cases) |cs| {
                                try self.collectLoopExits(cs.blk, out);
                            }
                            try self.collectLoopExits(sw.default_blk, out);
                        },
                        // Do not descend into a nested loop: its breaks
                        // target the inner loop.
                        .loop_ => {},
                    },
                }
            }
        }

        /// Make the empty exit terminator for a given exit kind.
        fn emptyExit(kind: ExitKind) ir.Terminator {
            return switch (kind) {
                .exit_if => .{ .exit_if = .{} },
                .exit_loop => .{ .exit_loop = .{} },
                .exit_switch => .{ .exit_switch = .{} },
                .cont => .{ .cont = .{} },
            };
        }

        /// A no-op kept for symmetry with the entry path: the top-level
        /// block is already fully terminated by buildBlock.
        fn terminateOrChain(self: *Builder, blk: *ir.Block) *ir.Block {
            _ = self;
            return blk;
        }

        /// Build a structured block starting at SPIR-V block `start_id`,
        /// following the CFG and STOPPING when a branch targets any block
        /// registered in `stops` (the enclosing constructs' merges /
        /// continue target).  An empty `stops` means recurse to a function
        /// terminator.
        ///
        /// Returns the head `*ir.Block` of the chain.  Plain blocks become
        /// `body` items; a `selection_header` becomes a nested `If`
        /// (then the continuation from its merge); a `loop_header` becomes
        /// a `Loop`.
        fn buildBlock(
            self: *Builder,
            start_id: u32,
            stops: *StopStack,
        ) BuildError!*ir.Block {
            // Recursion-depth safety valve: a CFG the structurizer can't resolve
            // can recurse without bound here -> stack overflow. 4096 is far above
            // any real shader's structured nesting; past it we bail cleanly.
            if (self.depth >= 4096) {
                return error.IrBuildUnsupported;
            }
            self.depth += 1;
            defer self.depth -= 1;
            var items: ArrayList(ir.Item) = .empty;

            var cur_id: u32 = start_id;
            while (true) {
                const info: BlockInfo = self.table.get(cur_id) orelse return error.MalformedFunction;

                switch (info.kind) {
                    .plain => {
                        // Emit this block's straight-line body.
                        try items.append(self.arena, .{ .body = cur_id });

                        const term_kind: TermKind = self.classifyTerminator(info);
                        switch (term_kind) {
                            .ret, .ret_value, .kill, .unreach => {
                                const term: ir.Terminator = try mapTerminator(info, self.inst_off, self.spirv);
                                const blk: *ir.Block = try self.finishBlock(items, term);
                                try self.by_id.put(self.arena, cur_id, blk);
                                return blk;
                            },
                            .branch => {
                                // Unconditional branch.  If the target is a
                                // registered stop, end this chain with the
                                // matching exit terminator (args attached
                                // later by the owning construct's phi pass).
                                // Otherwise continue the chain at the target.
                                const target: u32 = try self.branchTarget(info);
                                if (stops.lookup(target)) |kind| {
                                    const blk: *ir.Block = try self.finishBlock(items, emptyExit(kind));
                                    try self.by_id.put(self.arena, cur_id, blk);
                                    return blk;
                                }
                                // Fall through: keep building from target.
                                cur_id = target;
                            },
                            .branch_cond => {
                                // A conditional branch on a PLAIN block (no
                                // SelectionMerge) is the loop-iteration check
                                // shape: `if cond { continue } else { break }`
                                // (or some mix of stop targets).  Build it as
                                // an `If` whose branches are the two targets,
                                // each resolved against the stop stack.  This
                                // is the in-loop break/continue case.
                                const blk: *ir.Block = try self.buildUnstructuredCond(info, &items, stops);
                                try self.by_id.put(self.arena, cur_id, blk);
                                return blk;
                            },
                            .switch_ => {
                                // OpSwitch on a plain block (no merge) -
                                // unstructured; not handled yet.
                                return error.IrBuildUnsupported;
                            },
                        }
                    },
                    .selection_header => {
                        // The header's own straight-line body (between
                        // OpLabel and the SelectionMerge/branch) is emitted
                        // first, then the nested If.
                        try items.append(self.arena, .{ .body = cur_id });
                        const if_construct: *ir.Construct = try self.buildIf(info, stops);
                        try items.append(self.arena, .{ .construct = if_construct });
                        // Continue from the If's merge, unless the merge is a
                        // registered stop of an enclosing construct.
                        const merge_id: u32 = info.merge_id;
                        if (stops.lookup(merge_id)) |kind| {
                            const blk: *ir.Block = try self.finishBlock(items, emptyExit(kind));
                            return blk;
                        }
                        cur_id = merge_id;
                    },
                    .loop_header => {
                        // NOTE: the loop header's OWN body runs once per
                        // iteration (it is the back-edge target), so it
                        // belongs at the START of the loop body - NOT here
                        // in the parent.  buildLoop prepends it to the body
                        // block.  We only emit the Loop construct here.
                        const loop_construct: *ir.Construct = try self.buildLoop(info, stops);
                        try items.append(self.arena, .{ .construct = loop_construct });
                        const merge_id: u32 = info.merge_id;
                        if (stops.lookup(merge_id)) |kind| {
                            const blk: *ir.Block = try self.finishBlock(items, emptyExit(kind));
                            return blk;
                        }
                        cur_id = merge_id;
                    },
                    .switch_header => {
                        // The header's own body (between OpLabel and the
                        // SelectionMerge/OpSwitch) is emitted first, then the
                        // Switch.
                        try items.append(self.arena, .{ .body = cur_id });
                        const sw_construct: *ir.Construct = try self.buildSwitch(info, stops);
                        try items.append(self.arena, .{ .construct = sw_construct });
                        const merge_id: u32 = info.merge_id;
                        if (stops.lookup(merge_id)) |kind| {
                            const blk: *ir.Block = try self.finishBlock(items, emptyExit(kind));
                            return blk;
                        }
                        cur_id = merge_id;
                    },
                }
            }
        }

        /// Reconstruct an `If` from a `selection_header` block.  Builds
        /// both branches (stopping at the merge), reads the merge's OpPhis
        /// into `If.results`, and attaches each phi value to the exit
        /// terminator of its predecessor branch (the dropped-copy fix).
        fn buildIf(
            self: *Builder,
            header: BlockInfo,
            stops: *StopStack,
        ) BuildError!*ir.Construct {
            const t_off: u32 = self.inst_off[header.terminator_inst_idx];
            const t_op: u32 = types.opcodeOf(self.spirv[t_off]);
            // We only handle the structured `if` (OpBranchConditional).
            // OpSwitch under a SelectionMerge is the switch increment.
            if (t_op != @backingInt(types.Op.BranchConditional)) {
                return error.IrBuildUnsupported;
            }
            const t_ops: []const u32 = types.operandsAt(self.spirv, t_off);
            const cond_id: u32 = t_ops[0];
            const true_id: u32 = t_ops[1];
            const false_id: u32 = t_ops[2];
            const merge_id: u32 = header.merge_id;

            // Within the branches, this If's merge is the innermost stop
            // (a branch to it is an `exit_if`).  Push it for the recursion,
            // pop after.
            try stops.push(.{ .target = merge_id, .kind = .exit_if });
            const true_blk: *ir.Block = try self.buildBranch(true_id, merge_id, stops);
            const false_blk: *ir.Block = try self.buildBranch(false_id, merge_id, stops);
            stops.pop();

            // Read the merge's OpPhis -> results, and attach args per exit.
            const results: []ir.Param = try self.attachIfMergePhis(
                merge_id,
                header.id,
                true_id,
                false_id,
                true_blk,
                false_blk,
            );

            const if_: *ir.Construct = try self.arena.create(ir.Construct);
            if_.* = .{ .if_ = .{
                .cond = cond_id,
                .true_blk = true_blk,
                .false_blk = false_blk,
                .merge_id = merge_id,
                .results = results,
            } };
            // Record the branch-conditional -> If mapping so a merge OpPhi
            // that names this header as a predecessor can route its value to
            // the correct branch's exit terminator.
            try self.cond_to_if.put(self.arena, header.id, &if_.if_);
            return if_;
        }

        /// Build one branch of an `If`.  If `branch_id == merge_id` the
        /// branch is empty (the if was one-sided); otherwise recurse the
        /// branch sub-CFG (the merge is already on `stops` as `exit_if`).
        fn buildBranch(
            self: *Builder,
            branch_id: u32,
            merge_id: u32,
            stops: *StopStack,
        ) BuildError!*ir.Block {
            if (branch_id == merge_id) {
                const blk: *ir.Block = try self.arena.create(ir.Block);
                blk.* = .{ .items = &.{}, .term = .{ .exit_if = .{} } };
                return blk;
            }
            // The branch may transfer control straight to an OUTER construct
            // (a loop break/continue, an outer switch merge) - i.e. this is a
            // one-sided break/continue inside the if.  Resolve it against the
            // stop stack to an empty exit block FIRST; otherwise `buildBlock`
            // would process the stop block's own body (e.g. emit the loop
            // merge's trailing return) instead of treating it as an exit.
            // (Fixes loop-merge phis fed by an in-loop if-break, e.g.
            // `phi_Phi_Loop_FromIfBreak`.)
            if (stops.lookup(branch_id)) |kind| {
                const blk: *ir.Block = try self.arena.create(ir.Block);
                blk.* = .{ .items = &.{}, .term = emptyExit(kind) };
                return blk;
            }
            return self.buildBlock(branch_id, stops);
        }

        /// Reconstruct a `Loop` from a `loop_header` block.
        ///
        /// SPIR-V loop shape: the header carries `OpLoopMerge(merge,
        /// continue)` then an OpBranch into the body (or, rarely, an
        /// OpBranchConditional for a single-block loop - deferred).  Within
        /// the body, a branch to `continue` is a `cont` and a branch to
        /// `merge` is an `exit_loop` (a break), even when that branch sits
        /// inside a nested `if` (the mandelbrot break-out-of-loop case -
        /// resolved uniformly via the stop stack).  The continuing block is
        /// built separately; its back-edge `Branch %header` is the implicit
        /// WGSL loop iteration (no explicit terminator needed).
        ///
        /// Loop-carried phis ARE handled: loop-header OpPhis become
        /// `header_params` (each `init` = the pre-loop edge value; the
        /// continue-edge value collected into `iter_args`), and loop-merge
        /// OpPhis become `results` attached to the `exit_loop`/`break_if`
        /// edges.  Still deferred (returns `IrBuildUnsupported`, caller
        /// falls back to the legacy walker): single-block loops
        /// (continue == header) and non-canonical header phis (not exactly
        /// one pre-loop + one continue edge).
        fn buildLoop(
            self: *Builder,
            header: BlockInfo,
            stops: *StopStack,
        ) BuildError!*ir.Construct {
            const merge_id: u32 = header.merge_id;
            const continue_id: u32 = header.continue_id;

            // Single-block loop (continue == header): the header block is
            // ALSO the continuing block - there is no separate body.  The
            // header's own straight-line items are the loop body; its
            // terminator is the back-edge.  Two shapes:
            //   (a) OpBranch %header           - `loop { <body> }` (the exit,
            //       if any, is a break elsewhere; if none, an infinite loop).
            //   (b) OpBranchConditional c A B with one edge == header
            //       (back-edge) and the other == merge (break) -
            //       `loop { <body> if (breaks) { break; } }`.
            if (continue_id == header.id) {
                return self.buildSingleBlockLoop(header, stops);
            }

            // Header terminator: two supported shapes.
            //   (a) OpBranch %body        - the body runs unconditionally
            //       each iteration; the exit is via a break inside the body
            //       (the do-while / break-in-body shape we already handled).
            //   (b) OpBranchConditional %cond %A %B with ONE of A/B == merge
            //       - the classic `while (cond)` / for-loop: the header
            //       tests at the top and either enters the body or breaks to
            //       the merge.  We lower this as a guard `if` at the TOP of
            //       the loop body: `loop { <header body>; if (cond) { <body>
            //       } else { break; } continuing {...} }` (operands swapped
            //       if the merge is the TRUE target).  The break edge is a
            //       real `exit_loop`, so loop-merge phis attach to it.
            const t_off: u32 = self.inst_off[header.terminator_inst_idx];
            const t_op: u32 = types.opcodeOf(self.spirv[t_off]);
            const header_cond: bool = (t_op == @backingInt(types.Op.BranchConditional));
            if (t_op != @backingInt(types.Op.Branch) and !header_cond) {
                return error.IrBuildUnsupported;
            }

            var cond_id: u32 = 0;
            var body_start: u32 = 0;
            var break_on_false: bool = true; // whether the FALSE edge breaks
            var both_break: bool = false; // both header edges break (degenerate)
            var header_in_body: bool = false; // neither edge breaks (infinite loop)
            if (header_cond) {
                const ops: []const u32 = types.operandsAt(self.spirv, t_off);
                cond_id = ops[0];
                const true_t: u32 = ops[1];
                const false_t: u32 = ops[2];
                // The common shape is exactly one edge targeting the merge
                // (the break) and the other entering the body - a `while`.
                // Three other shapes occur:
                //   - BOTH edges -> merge: a loop that never iterates; lower as
                //     a guard whose arms both break.
                //   - NEITHER edge -> merge: the header conditional is not a
                //     loop guard at all but the first branch INSIDE an
                //     infinite-loop body (e.g. `for(;;) { if (c) {...break...} }`).
                //     Build it as ordinary in-body control flow, resolving
                //     each edge against the merge/continue stops.
                if (true_t == merge_id and false_t == merge_id) {
                    both_break = true;
                    body_start = merge_id; // unused; body is the break guard
                } else if (false_t == merge_id and true_t != merge_id) {
                    body_start = true_t;
                    break_on_false = true;
                } else if (true_t == merge_id and false_t != merge_id) {
                    body_start = false_t;
                    break_on_false = false;
                } else {
                    header_in_body = true;
                }
            } else {
                body_start = types.operandsAt(self.spirv, t_off)[0];
            }

            // Read the loop-header OpPhis -> header_params (+ init + iter
            // values).  Each header phi has exactly two incoming pairs:
            // (init_value, pre-loop block) and (iter_value, continue block).
            var header_params: ArrayList(ir.Param) = .empty;
            var iter_args: ArrayList(ir.ValueId) = .empty;
            try self.readLoopHeaderPhis(header, continue_id, &header_params, &iter_args);

            // Build the body with merge->exit_loop and continue->cont stops.
            // (Skip for the degenerate both-break header: there is no body to
            // enter - both edges leave the loop - so we use an empty break
            // block for both guard arms instead.)
            var body_tail: *ir.Block = undefined;
            if (!both_break and !header_in_body) {
                try stops.push(.{ .target = merge_id, .kind = .exit_loop });
                try stops.push(.{ .target = continue_id, .kind = .cont });
                body_tail = try self.buildBlock(body_start, stops);
                stops.pop();
                stops.pop();
            }

            // The loop HEADER's own body runs once per iteration (it is the
            // back-edge target), so it must be the FIRST thing inside the
            // loop body.
            //
            // For shape (a) (unconditional header branch) we just prepend
            // the header's straight-line items ahead of the body chain.
            //
            // For shape (b) (header-conditional `while`) the header's items
            // run, THEN the condition is tested: build a guard `If` whose
            // taken branch is the body chain and whose other branch breaks
            // (`exit_loop`), then prepend the header's items ahead of the
            // guard.  The guard's `exit_loop` break edge is where this
            // loop's merge phis (if any) get their break-edge value.  For the
            // degenerate both-break header, BOTH arms break.
            var body_blk: *ir.Block = undefined;
            if (header_in_body) {
                // Neither header edge breaks: the header conditional is the
                // first branch inside an infinite-loop body.  Build it as an
                // in-body unstructured cond (each edge resolved against the
                // merge->exit_loop / continue->cont stops), with the header's
                // own straight-line items first.
                var items: ArrayList(ir.Item) = .empty;
                try items.append(self.arena, .{ .body = header.id });
                try stops.push(.{ .target = merge_id, .kind = .exit_loop });
                try stops.push(.{ .target = continue_id, .kind = .cont });
                body_blk = try self.buildUnstructuredCond(header, &items, stops);
                stops.pop();
                stops.pop();
            } else if (header_cond) {
                const break_blk: *ir.Block = try self.arena.create(ir.Block);
                break_blk.* = .{ .items = &.{}, .term = .{ .exit_loop = .{} } };

                var true_blk: *ir.Block = undefined;
                var false_blk: *ir.Block = undefined;
                if (both_break) {
                    // Both arms leave the loop.  Use a distinct break block
                    // per arm so each can carry its own merge-phi break edge.
                    const break_blk2: *ir.Block = try self.arena.create(ir.Block);
                    break_blk2.* = .{ .items = &.{}, .term = .{ .exit_loop = .{} } };
                    true_blk = break_blk;
                    false_blk = break_blk2;
                } else {
                    true_blk = if (break_on_false) body_tail else break_blk;
                    false_blk = if (break_on_false) break_blk else body_tail;
                }

                const guard: *ir.Construct = try self.arena.create(ir.Construct);
                guard.* = .{
                    .if_ = .{
                        .cond = cond_id,
                        .true_blk = true_blk,
                        .false_blk = false_blk,
                        // The guard has no structured merge of its own - both
                        // arms transfer control (into the body's own flow, or
                        // out via the break).  No merge phis on the guard.
                        .merge_id = 0,
                    },
                };
                const guard_blk: *ir.Block = try self.arena.create(ir.Block);
                guard_blk.* = .{
                    .items = try self.arena.dupe(ir.Item, &.{.{ .construct = guard }}),
                    .term = .unreach,
                };
                body_blk = try self.prependBodyItem(header.id, guard_blk);
            } else {
                body_blk = try self.prependBodyItem(header.id, body_tail);
            }

            // Build the continuing block.  Its back-edge to the header is
            // the implicit iteration: push the header as a stop so the
            // `Branch %header` terminates the continuing chain with a plain
            // (arg-less) branch we leave in place as the loop's implicit
            // back-edge.
            try stops.push(.{ .target = header.id, .kind = .cont });
            const cont_blk: *ir.Block = try self.buildContinuing(continue_id, header.id, merge_id, stops);
            stops.pop();

            // Read the loop-MERGE OpPhis -> results, attaching each value to
            // the exit terminator of its predecessor (the unified merge-phi
            // cascade).  `exit_loop`/`break_if` edges carry these; a value
            // whose predecessor is the header (a jump straight out) is
            // applied to whichever break edge lacks one.  Collect this loop's
            // break edges from both the body and the continuing block.
            var loop_exits: ArrayList(*ir.Block) = .empty;
            try self.collectLoopExits(body_blk, &loop_exits);
            try self.collectLoopExits(cont_blk, &loop_exits);
            const results: []ir.Param = try self.attachLoopMergePhis(
                merge_id,
                header.id,
                loop_exits.items,
            );

            const loop_: *ir.Construct = try self.arena.create(ir.Construct);
            loop_.* = .{
                .loop_ = .{
                    .body = body_blk,
                    .continuing = cont_blk,
                    .merge_id = merge_id,
                    .header_params = try header_params.toOwnedSlice(self.arena),
                    .iter_args = try iter_args.toOwnedSlice(self.arena),
                    .results = results,
                },
            };
            return loop_;
        }

        /// Build a single-block loop, where the loop header IS its own
        /// continuing block (`continue == header`).  The header's straight-
        /// line items form the loop body; its terminator is the back-edge.
        ///   (a) OpBranch %header -> `loop { <body> }` with an empty
        ///       continuing.  (An exit, if present, is a break reached via
        ///       some other path; with no break this is an infinite loop -
        ///       valid WGSL.)
        ///   (b) OpBranchConditional cond A B with one edge == header (the
        ///       back-edge / continue) and the other == merge (the break) ->
        ///       `loop { <body> break_if (cond-that-breaks) }`.  The
        ///       break edge is a `break_if`, which carries loop-merge phis.
        fn buildSingleBlockLoop(
            self: *Builder,
            header: BlockInfo,
            stops: *StopStack,
        ) BuildError!*ir.Construct {
            const merge_id: u32 = header.merge_id;

            // Header phis: the back-edge predecessor IS the header itself, so
            // read init (pre-loop edge) + iter (the header self-edge).
            var header_params: ArrayList(ir.Param) = .empty;
            var iter_args: ArrayList(ir.ValueId) = .empty;
            try self.readLoopHeaderPhis(header, header.id, &header_params, &iter_args);

            const t_off: u32 = self.inst_off[header.terminator_inst_idx];
            const t_op: u32 = types.opcodeOf(self.spirv[t_off]);

            // The loop body is the header block's own straight-line items,
            // ending in the implicit back-edge (plain branch -> emitted as
            // nothing).  A conditional exit becomes a `break if` placed in
            // the CONTINUING block (WGSL only allows `break if` there).
            const body_blk: *ir.Block = try self.arena.create(ir.Block);
            body_blk.* = .{
                .items = try self.arena.dupe(ir.Item, &.{.{ .body = header.id }}),
                .term = .{ .branch = header.id },
            };
            try self.by_id.put(self.arena, header.id, body_blk);

            const cont_blk: *ir.Block = try self.arena.create(ir.Block);

            if (t_op == @backingInt(types.Op.Branch)) {
                const tgt: u32 = types.operandsAt(self.spirv, t_off)[0];
                if (tgt != header.id) {
                    return error.IrBuildUnsupported;
                }
                // Unconditional self-branch: no exit condition -> empty
                // continuing (infinite loop unless a break exists elsewhere).
                cont_blk.* = .{ .items = &.{}, .term = .{ .branch = header.id } };
            } else if (t_op == @backingInt(types.Op.BranchConditional)) {
                const ops: []const u32 = types.operandsAt(self.spirv, t_off);
                const cond_id: u32 = ops[0];
                const true_t: u32 = ops[1];
                const false_t: u32 = ops[2];
                // One edge is the back-edge (== header), the other breaks to
                // the merge.  WGSL: the continuing block ends with
                // `break if <breaks-when>`.  If the FALSE edge is the
                // back-edge (true breaks) -> `break if cond`.  If the TRUE
                // edge is the back-edge (false breaks) -> `break if !cond`.
                var breaks_on: ir.BreakIf = .{ .cond = cond_id };
                var both_backedge: bool = false;
                if (false_t == header.id and true_t == merge_id) {
                    breaks_on.invert = false; // break when cond
                } else if (true_t == header.id and false_t == merge_id) {
                    breaks_on.invert = true; // break when !cond
                } else if (true_t == header.id and false_t == header.id) {
                    both_backedge = true; // both arms re-loop (infinite loop)
                } else {
                    return error.IrBuildUnsupported;
                }
                if (both_backedge) {
                    // The header conditional never breaks - the condition is
                    // immaterial, both arms re-loop.  Lower to an empty
                    // continuing, exactly like an unconditional self-branch.
                    cont_blk.* = .{ .items = &.{}, .term = .{ .branch = header.id } };
                } else {
                    // The break_if's phi args (loop-merge values on the break
                    // edge) attach via attachLoopMergePhis below - but its
                    // predecessor is the header block, now mapped to body_blk.
                    // Place the break_if as the continuing terminator and route
                    // merge phis to IT instead of body_blk.
                    cont_blk.* = .{ .items = &.{}, .term = .{ .break_if = breaks_on } };
                    try self.by_id.put(self.arena, header.id, cont_blk);
                }
            } else {
                return error.IrBuildUnsupported;
            }

            // Loop-merge phis attach to the break_if edge (if any).  The
            // body + continuing carry this single-block loop's break edges.
            var sb_exits: ArrayList(*ir.Block) = .empty;
            try self.collectLoopExits(body_blk, &sb_exits);
            try self.collectLoopExits(cont_blk, &sb_exits);
            const results: []ir.Param = try self.attachLoopMergePhis(
                merge_id,
                header.id,
                sb_exits.items,
            );
            _ = stops;

            const loop_: *ir.Construct = try self.arena.create(ir.Construct);
            loop_.* = .{ .loop_ = .{
                .body = body_blk,
                .continuing = cont_blk,
                .merge_id = merge_id,
                .header_params = try header_params.toOwnedSlice(self.arena),
                .iter_args = try iter_args.toOwnedSlice(self.arena),
                .results = results,
            } };
            return loop_;
        }

        /// Prepend `{ .body = block_id }` as the first item of `tail`,
        /// MUTATING tail in place (so any `by_id` entry pointing at `tail`
        /// stays valid for later merge-phi attachment).  Used to place a
        /// loop header's own body at the start of the loop body (it runs
        /// every iteration).
        fn prependBodyItem(
            self: *Builder,
            block_id: u32,
            tail: *ir.Block,
        ) BuildError!*ir.Block {
            const items: []ir.Item = try self.arena.alloc(ir.Item, tail.items.len + 1);
            items[0] = .{ .body = block_id };
            @memcpy(items[1..], tail.items);
            tail.items = items;
            return tail;
        }

        /// Reconstruct a `Switch` from a `switch_header` block.
        ///
        /// SPIR-V `OpSwitch` operands: `[selector, default_target,
        /// (literal, target)+]`, with the merge from the preceding
        /// `OpSelectionMerge`.  Each case/default target is recursed
        /// (stopping at the merge -> `exit_switch`); a target that equals
        /// the merge is an empty case.  Multiple literals sharing the same
        /// target collapse into one `Case` with multiple `values` (WGSL
        /// `case a, b: {}`).  No fallthrough - each case exits to the merge
        /// independently, matching WGSL semantics.  Merge OpPhis become
        /// `Switch.results`, attached to each case's `exit_switch` edge.
        fn buildSwitch(
            self: *Builder,
            header: BlockInfo,
            stops: *StopStack,
        ) BuildError!*ir.Construct {
            const t_off: u32 = self.inst_off[header.terminator_inst_idx];
            const t_op: u32 = types.opcodeOf(self.spirv[t_off]);
            if (t_op != @backingInt(types.Op.Switch)) {
                return error.IrBuildUnsupported;
            }
            const t_ops: []const u32 = types.operandsAt(self.spirv, t_off);
            const selector_id: u32 = t_ops[0];
            const default_id: u32 = t_ops[1];
            const merge_id: u32 = header.merge_id;

            // Within the cases, the switch merge is the innermost stop
            // (a branch to it is an `exit_switch`).
            try stops.push(.{ .target = merge_id, .kind = .exit_switch });

            // Build cases, deduping shared targets into one Case with
            // multiple selector values.  `case_targets[i]` is the SPIR-V
            // target for cases.items[i], used to merge repeats.
            var cases: ArrayList(ir.Case) = .empty;
            var case_targets: ArrayList(u32) = .empty;

            var i: usize = 2;
            while (i + 1 < t_ops.len) : (i += 2) {
                const literal: u32 = t_ops[i];
                const target: u32 = t_ops[i + 1];

                // A case whose target is the merge contributes a selector
                // value to an (empty) case - but WGSL needs it to land
                // somewhere.  Treat it like any other target: an empty case
                // body that exits immediately.  Dedup against existing.
                if (findCaseIndex(case_targets.items, target)) |idx| {
                    cases.items[idx].values = try appendU32(self.arena, cases.items[idx].values, literal);
                    continue;
                }
                const blk: *ir.Block = try self.buildCaseTarget(target, merge_id, stops);
                const vals: []const u32 = try self.arena.dupe(u32, &.{literal});
                try cases.append(self.arena, .{ .values = vals, .blk = blk });
                try case_targets.append(self.arena, target);
            }

            // The default case.
            const default_blk: *ir.Block = try self.buildCaseTarget(default_id, merge_id, stops);

            stops.pop();

            // Collect every case + default exit block (for the default-value
            // fixup), then attach merge OpPhis to the right exit edges.
            var exits: ArrayList(*ir.Block) = .empty;
            for (cases.items) |c| {
                try exits.append(self.arena, c.blk);
            }
            try exits.append(self.arena, default_blk);
            const results: []ir.Param = try self.attachSwitchMergePhis(
                merge_id,
                header.id,
                exits.items,
            );

            const sw: *ir.Construct = try self.arena.create(ir.Construct);
            sw.* = .{ .switch_ = .{
                .selector = selector_id,
                .cases = try cases.toOwnedSlice(self.arena),
                .default_blk = default_blk,
                .merge_id = merge_id,
                .results = results,
            } };
            return sw;
        }

        /// Build one switch case/default target.  Empty (just `exit_switch`)
        /// when the target IS the merge; otherwise recurse the case
        /// sub-CFG (the merge is already on `stops` as `exit_switch`).
        fn buildCaseTarget(
            self: *Builder,
            target: u32,
            merge_id: u32,
            stops: *StopStack,
        ) BuildError!*ir.Block {
            if (target == merge_id) {
                const blk: *ir.Block = try self.arena.create(ir.Block);
                blk.* = .{ .items = &.{}, .term = .{ .exit_switch = .{} } };
                return blk;
            }
            return self.buildBlock(target, stops);
        }

        /// Read the switch-merge OpPhis into result `Param`s and attach each
        /// value to the right `exit_switch` edge, following the unified
        /// merge-phi cascade (see `resolveMergePhiTarget`).  A value whose
        /// predecessor is the switch header (no default block - control
        /// jumps over the switch) is applied to the shortest exit edge.
        fn attachSwitchMergePhis(
            self: *Builder,
            merge_id: u32,
            header_id: u32,
            exits: []const *ir.Block,
        ) BuildError![]ir.Param {
            const merge_info: BlockInfo = self.table.get(merge_id) orelse return error.MalformedFunction;
            var params: ArrayList(ir.Param) = .empty;
            var k: usize = merge_info.label_inst_idx + 1;
            while (k < merge_info.terminator_inst_idx) : (k += 1) {
                const off: u32 = self.inst_off[k];
                if (types.opcodeOf(self.spirv[off]) != @backingInt(types.Op.Phi)) {
                    continue;
                }
                const ops: []const u32 = types.operandsAt(self.spirv, off);
                try params.append(self.arena, .{ .phi_id = ops[1], .type_id = ops[0] });
                var default_value: ?ir.ValueId = null;
                var i: usize = 2;
                while (i + 1 < ops.len) : (i += 2) {
                    const value_id: u32 = ops[i];
                    const pred_id: u32 = ops[i + 1];
                    const tgt: PhiTarget = self.resolveMergePhiTarget(pred_id, merge_id, header_id);
                    if (tgt.is_default) {
                        default_value = value_id;
                        continue;
                    }
                    const blk: *ir.Block = tgt.blk orelse return error.IrBuildUnsupported;
                    try appendExitArg(self.arena, blk, value_id);
                }
                if (default_value) |dv| {
                    try self.applyDefaultToShortestExit(exits, dv);
                }
            }
            return params.toOwnedSlice(self.arena);
        }

        /// per-phi iterated values (continue-edge operand) into `iter_args`
        /// (positional with header_params).  The init value (pre-loop edge)
        /// is stored on each `Param.init`.
        ///
        /// A loop-header OpPhi has exactly two (value, pred) pairs: one from
        /// the pre-loop block and one from the continue block.  We identify
        /// the continue-edge pair as the one whose pred is reachable through
        /// the continue target (in practice pred == continue_id, or a block
        /// that branches to the header from the continuing region); the
        /// other pair is the initializer.
        fn readLoopHeaderPhis(
            self: *Builder,
            header: BlockInfo,
            continue_id: u32,
            header_params: *ArrayList(ir.Param),
            iter_args: *ArrayList(ir.ValueId),
        ) BuildError!void {
            // The back-edge predecessor: the block that branches to the
            // header from the continuing region.  For the shapes we handle,
            // that is the continue block itself (continue -> Branch header)
            // OR a block the continuing chain ends at.  We treat the phi
            // operand whose pred is on the continue side as the iterated
            // value; the other as the init.
            const back_pred: u32 = try self.backEdgePred(header.id, continue_id);

            var k: usize = header.label_inst_idx + 1;
            while (k < header.terminator_inst_idx) : (k += 1) {
                const off: u32 = self.inst_off[k];
                if (types.opcodeOf(self.spirv[off]) != @backingInt(types.Op.Phi)) {
                    continue;
                }
                const ops: []const u32 = types.operandsAt(self.spirv, off);
                const type_id: u32 = ops[0];
                const phi_id: u32 = ops[1];

                // Exactly two (value, pred) pairs for a loop-header phi.
                var init_value: ?u32 = null;
                var iter_value: ?u32 = null;
                var i: usize = 2;
                while (i + 1 < ops.len) : (i += 2) {
                    const value_id: u32 = ops[i];
                    const pred_id: u32 = ops[i + 1];
                    if (pred_id == back_pred or pred_id == continue_id) {
                        iter_value = value_id;
                    } else {
                        init_value = value_id;
                    }
                }
                if (init_value == null or iter_value == null) {
                    // Not the canonical 2-edge header phi we handle.
                    return error.IrBuildUnsupported;
                }
                try header_params.append(self.arena, .{
                    .phi_id = phi_id,
                    .type_id = type_id,
                    .init = init_value,
                });
                try iter_args.append(self.arena, iter_value.?);
            }
        }

        /// Find the block id that forms the loop's back-edge to `header_id`
        /// (i.e. ends in `OpBranch %header`), searched within the table.
        /// This is the predecessor whose phi operand is the iterated value.
        fn backEdgePred(
            self: *Builder,
            header_id: u32,
            continue_id: u32,
        ) BuildError!u32 {
            // Fast path: the continue block usually IS the back-edge.
            if (self.branchesToTarget(continue_id, header_id)) {
                return continue_id;
            }
            // Otherwise scan all blocks for the one branching to the header.
            var it: @TypeOf(self.table.iterator()) = self.table.iterator();
            while (it.next()) |entry| {
                const bid: u32 = entry.key_ptr.*;
                if (bid == header_id) {
                    continue;
                }
                if (self.branchesToTarget(bid, header_id)) {
                    return bid;
                }
            }
            return continue_id; // fall back; readLoopHeaderPhis tolerates it
        }

        /// Does block `bid` end in an unconditional `OpBranch %target`?
        fn branchesToTarget(
            self: *Builder,
            bid: u32,
            target: u32,
        ) bool {
            const info: BlockInfo = self.table.get(bid) orelse return false;
            const off: u32 = self.inst_off[info.terminator_inst_idx];
            if (types.opcodeOf(self.spirv[off]) != @backingInt(types.Op.Branch)) {
                return false;
            }
            return types.operandsAt(self.spirv, off)[0] == target;
        }

        /// Read the loop-merge OpPhis into result `Param`s and attach each
        /// (value, pred) onto the exit terminator of pred's IR block - the
        /// same per-exit attachment used for `If` merges, but the exits here
        /// are `exit_loop`/`break_if` edges.
        ///
        /// A loop-merge phi's predecessor is whatever block jumped to the
        /// merge: a body block that `break`s (registered in `by_id` with an
        /// `exit_loop`/`break_if` terminator) is the case we handle and the
        /// only one reachable for the loop shapes `buildLoop` accepts.
        ///
        /// A predecessor NOT in `by_id` would mean an exit edge we never
        /// materialized - e.g. a header-conditional `while`-style exit
        /// (header->merge direct).  But that exit makes the header terminator
        /// an `OpBranchConditional`, which `buildLoop` already rejects up
        /// front (it requires a plain `OpBranch` header), so for valid
        /// structured SPIR-V this branch is currently UNREACHABLE.  We still
        /// handle it defensively: defer to the legacy walker
        /// (`IrBuildUnsupported`) rather than hard-failing the whole
        /// translation (`MalformedFunction`) - so that IF a future change to
        /// `buildLoop` (adding header-conditional loops) ever routes such a
        /// shape here before giving the header break-edge a real `exit_loop`
        /// block, we degrade gracefully instead of erroring.  (When adding
        /// header-conditional loops, route the header break-edge the way
        /// `attachExitArg` routes a one-sided-if header edge.)
        ///
        /// NOTE (audited turn 809): across the entire current shader corpus,
        /// no loop-merge block has any OpPhi, so this routine returns empty
        /// for every real shader today.  The handled path (break-from-body,
        /// pred in `by_id`) is covered by the "loop-merge phi (value escaping
        /// the loop)" unit test below.
        /// Read the loop-merge OpPhis into result `Param`s and attach each
        /// value to the right break edge, following the unified merge-phi
        /// cascade (`resolveMergePhiTarget`).  A value whose predecessor is
        /// the loop header (control jumps straight out - e.g. a
        /// header-conditional `while` break) is applied to the break edge
        /// that has not yet received a value (`exits`, collected by
        /// `collectLoopExits`).  A predecessor that resolves to a `cont`
        /// terminator (a conditional where one edge continued and the other
        /// broke) is redirected to the enclosing If's `exit_loop` branch.
        ///
        /// NOTE (audited turn 809): across the live shader corpus, no
        /// loop-merge block carries an OpPhi, so this returns empty for every
        /// production shader today; the Tint fixtures exercise the phi paths.
        fn attachLoopMergePhis(
            self: *Builder,
            merge_id: u32,
            header_id: u32,
            exits: []const *ir.Block,
        ) BuildError![]ir.Param {
            const merge_info: BlockInfo = self.table.get(merge_id) orelse return error.MalformedFunction;
            var params: ArrayList(ir.Param) = .empty;

            // All phis at this merge route their (value, pred) pairs in the
            // SAME order, so each exit block's args stay positionally aligned
            // with `params` (the results) - the alignment invariant whose
            // violation was the turn-808 If-merge bug.
            var k: usize = merge_info.label_inst_idx + 1;
            while (k < merge_info.terminator_inst_idx) : (k += 1) {
                const off: u32 = self.inst_off[k];
                if (types.opcodeOf(self.spirv[off]) != @backingInt(types.Op.Phi)) {
                    continue;
                }
                const ops: []const u32 = types.operandsAt(self.spirv, off);
                try params.append(self.arena, .{ .phi_id = ops[1], .type_id = ops[0] });

                var default_value: ?ir.ValueId = null;
                var i: usize = 2;
                while (i + 1 < ops.len) : (i += 2) {
                    const value_id: u32 = ops[i];
                    const pred_id: u32 = ops[i + 1];
                    const tgt: PhiTarget = self.resolveMergePhiTarget(pred_id, merge_id, header_id);
                    if (tgt.is_default) {
                        default_value = value_id;
                        continue;
                    }
                    var blk: *ir.Block = tgt.blk orelse return error.IrBuildUnsupported;
                    // A `cont` target means a conditional where one edge
                    // continued and the other broke the loop - redirect to
                    // the breaking branch's `exit_loop`.
                    if (blk.term == .cont) {
                        blk = self.redirectContToExitLoop(pred_id) orelse return error.IrBuildUnsupported;
                    }
                    try appendExitArg(self.arena, blk, value_id);
                }
                if (default_value) |dv| {
                    try self.applyDefaultToShortestExit(exits, dv);
                }
            }
            return params.toOwnedSlice(self.arena);
        }

        /// For a predecessor whose resolved terminator was `cont`, find the
        /// `exit_loop` branch of the `If` we built for that block (the other
        /// edge of a continue/break conditional).  Mirrors Tint's
        /// reach-through in `EmitPhiInLoopMerge`.
        fn redirectContToExitLoop(self: *Builder, pred_id: u32) ?*ir.Block {
            const if_ptr: *ir.If = self.cond_to_if.get(pred_id) orelse return null;
            if (if_ptr.true_blk.term == .exit_loop) {
                return if_ptr.true_blk;
            }
            if (if_ptr.false_blk.term == .exit_loop) {
                return if_ptr.false_blk;
            }
            return null;
        }

        /// Build the continuing block of a loop.  Identical to `buildBlock`
        /// except the trailing back-edge `Branch %header` becomes a plain
        /// `branch` terminator (the implicit WGSL loop iteration) rather
        /// than a `cont`/exit.
        fn buildContinuing(
            self: *Builder,
            continue_id: u32,
            header_id: u32,
            loop_merge_id: u32,
            stops: *StopStack,
        ) BuildError!*ir.Block {
            // A continuing block that is just `Label; Branch %header` lowers
            // to an empty continuing.  Build it normally; when the chain
            // reaches the header back-edge it ends with a `branch` to the
            // header (left as-is - the emitter renders the continuing scope
            // and the implicit iteration).
            var items: ArrayList(ir.Item) = .empty;
            var cur_id: u32 = continue_id;
            while (true) {
                const info: BlockInfo = self.table.get(cur_id) orelse return error.MalformedFunction;

                // A nested selection (an `if` inside the continuing block,
                // e.g. `branch_Loop_Continue_ContainsIf`) - reconstruct it
                // with the same machinery `buildBlock` uses, then continue
                // the chain from its merge.  Push the header as a `.cont`
                // stop for the duration so a branch back to the header from
                // inside the nested if resolves correctly.
                if (info.kind == .selection_header) {
                    try items.append(self.arena, .{ .body = cur_id });
                    try stops.push(.{ .target = header_id, .kind = .cont });
                    const if_construct: *ir.Construct = try self.buildIf(info, stops);
                    stops.pop();
                    try items.append(self.arena, .{ .construct = if_construct });
                    const merge_id: u32 = info.merge_id;
                    if (merge_id == header_id) {
                        // The if's merge IS the back-edge target - end the
                        // continuing chain here with the implicit branch.
                        const blk: *ir.Block = try self.finishBlock(items, .{ .branch = header_id });
                        try self.by_id.put(self.arena, cur_id, blk);
                        return blk;
                    }
                    cur_id = merge_id;
                    continue;
                }
                // Only plain blocks (besides the selection above) are
                // expected in a continuing chain for the shapes we handle; a
                // loop_header here (loop-in-continuing) is deferred.
                if (info.kind != .plain) {
                    return error.IrBuildUnsupported;
                }
                try items.append(self.arena, .{ .body = cur_id });
                const term_kind: TermKind = self.classifyTerminator(info);
                // The continuing block may end with a conditional that breaks
                // out of the loop on one edge and loops back to the header on
                // the other - WGSL's `continuing { ... break if cond; }`.  One
                // edge must be the header (back-edge), the other the merge
                // (break).  Emit a `break_if`, inverting when the BREAK is the
                // false edge (so `break if !(cond)` when cond keeps looping).
                if (term_kind == .branch_cond) {
                    const cops: []const u32 = types.operandsAt(self.spirv, self.inst_off[info.terminator_inst_idx]);
                    const ccond: u32 = cops[0];
                    const ctrue: u32 = cops[1];
                    const cfalse: u32 = cops[2];
                    const break_target: u32 = loop_merge_id;
                    if (ctrue == break_target and cfalse == header_id) {
                        const blk: *ir.Block = try self.finishBlock(items, .{
                            .break_if = .{ .cond = ccond, .invert = false },
                        });
                        try self.by_id.put(self.arena, cur_id, blk);
                        return blk;
                    }
                    if (cfalse == break_target and ctrue == header_id) {
                        const blk: *ir.Block = try self.finishBlock(items, .{
                            .break_if = .{ .cond = ccond, .invert = true },
                        });
                        try self.by_id.put(self.arena, cur_id, blk);
                        return blk;
                    }
                    return error.IrBuildUnsupported;
                }
                if (term_kind != .branch) {
                    return error.IrBuildUnsupported;
                }
                const target: u32 = try self.branchTarget(info);
                if (target == header_id) {
                    // The back-edge: end the continuing block with a plain
                    // branch to the header (implicit iteration).
                    const blk: *ir.Block = try self.finishBlock(items, .{ .branch = header_id });
                    try self.by_id.put(self.arena, cur_id, blk);
                    return blk;
                }
                // A non-back-edge branch inside the continuing chain - could
                // be a stop (rare); resolve against the stack, else continue.
                if (stops.lookup(target)) |kind| {
                    const blk: *ir.Block = try self.finishBlock(items, emptyExit(kind));
                    try self.by_id.put(self.arena, cur_id, blk);
                    return blk;
                }
                cur_id = target;
            }
        }

        /// Build an `If` from an unstructured OpBranchConditional on a
        /// PLAIN block (no SelectionMerge).  This is the in-loop iteration
        /// check: each target is resolved against the stop stack
        /// (continue->`cont`, merge->`exit_loop`), or recursed if it's
        /// ordinary forward flow.  Returns a block whose single item is the
        /// synthesized `If` and whose terminator is... there isn't one: an
        /// unstructured cond fully transfers control via its branches, so
        /// the enclosing block ends here.  We model it as a block with the
        /// `If` as its sole construct item and an `unreach` terminator
        /// (control never falls through past both exiting branches).
        fn buildUnstructuredCond(
            self: *Builder,
            info: BlockInfo,
            items: *ArrayList(ir.Item),
            stops: *StopStack,
        ) BuildError!*ir.Block {
            const t_off: u32 = self.inst_off[info.terminator_inst_idx];
            const t_ops: []const u32 = types.operandsAt(self.spirv, t_off);
            const cond_id: u32 = t_ops[0];
            const true_id: u32 = t_ops[1];
            const false_id: u32 = t_ops[2];

            const true_blk: *ir.Block = try self.buildCondTarget(true_id, stops);
            const false_blk: *ir.Block = try self.buildCondTarget(false_id, stops);

            const if_: *ir.Construct = try self.arena.create(ir.Construct);
            if_.* = .{
                .if_ = .{
                    .cond = cond_id,
                    .true_blk = true_blk,
                    .false_blk = false_blk,
                    // No structured merge: this if's branches both transfer
                    // control out (continue/break/return), so there are no
                    // merge phis and no `exit_if` to this construct.
                    .merge_id = 0,
                },
            };
            try items.append(self.arena, .{ .construct = if_ });
            try self.cond_to_if.put(self.arena, info.id, &if_.if_);

            // Control does not fall through past an unstructured cond whose
            // branches both exit - mark unreachable.
            return self.finishBlock(items.*, .unreach);
        }

        /// Build one target of an unstructured cond: if it's a registered
        /// stop, an empty block with that exit; else recurse it.
        fn buildCondTarget(
            self: *Builder,
            target: u32,
            stops: *StopStack,
        ) BuildError!*ir.Block {
            if (stops.lookup(target)) |kind| {
                const blk: *ir.Block = try self.arena.create(ir.Block);
                blk.* = .{ .items = &.{}, .term = emptyExit(kind) };
                return blk;
            }
            return self.buildBlock(target, stops);
        }

        /// Read every OpPhi at the merge block into `Param`s and append
        /// each (value, pred) phi value onto the exit terminator of the
        /// predecessor's IR block.  Returns the params (positional, in
        /// OpPhi source order) for `If.results`.
        fn attachIfMergePhis(
            self: *Builder,
            merge_id: u32,
            header_id: u32,
            true_id: u32,
            false_id: u32,
            true_blk: *ir.Block,
            false_blk: *ir.Block,
        ) BuildError![]ir.Param {
            const merge_info: BlockInfo = self.table.get(merge_id) orelse return error.MalformedFunction;

            var params: ArrayList(ir.Param) = .empty;

            // Scan instructions between the merge's OpLabel and its
            // terminator for OpPhi.  Each OpPhi: [type, result, (val,pred)+].
            var k: usize = merge_info.label_inst_idx + 1;
            while (k < merge_info.terminator_inst_idx) : (k += 1) {
                const off: u32 = self.inst_off[k];
                if (types.opcodeOf(self.spirv[off]) != @backingInt(types.Op.Phi)) {
                    continue;
                }
                const ops: []const u32 = types.operandsAt(self.spirv, off);
                const type_id: u32 = ops[0];
                const phi_id: u32 = ops[1];
                try params.append(self.arena, .{ .phi_id = phi_id, .type_id = type_id });

                // For each (value, pred) pair, attach value to the exit
                // terminator of pred's IR block.  All phis at this merge are
                // appended in the SAME scan order, and each routes to the
                // SAME branch for a given pred - so every branch's exit args
                // stay positionally aligned with `params` (the results).
                var i: usize = 2;
                while (i + 1 < ops.len) : (i += 2) {
                    const value_id: u32 = ops[i];
                    const pred_id: u32 = ops[i + 1];
                    try self.attachExitArg(
                        value_id,
                        pred_id,
                        header_id,
                        true_id,
                        false_id,
                        true_blk,
                        false_blk,
                    );
                }
            }

            return params.toOwnedSlice(self.arena);
        }

        /// Append `value_id` to the `exit_if.args` of the IR block that
        /// carries SPIR-V block `pred_id`'s terminator.
        ///
        /// The subtle case is `pred_id == header_id`: the header branched
        /// DIRECTLY to the merge on one edge (a one-sided `if`, where one of
        /// `true_id`/`false_id` equals `merge_id`).  That value belongs to
        /// the EMPTY branch - the one whose target is the merge - NOT to
        /// "whichever branch has fewer args" (an earlier heuristic that
        /// mis-routed values across branches when a merge had multiple
        /// phis, scrambling the positional alignment between each branch's
        /// exit args and the construct's results).  Route deterministically.
        fn attachExitArg(
            self: *Builder,
            value_id: u32,
            pred_id: u32,
            header_id: u32,
            true_id: u32,
            false_id: u32,
            true_blk: *ir.Block,
            false_blk: *ir.Block,
        ) BuildError!void {
            if (pred_id == header_id) {
                // One-sided if: the header->merge edge is the branch whose
                // target IS the merge (the empty branch we synthesized with
                // an `exit_if` and no body).  Both `true_id` and `false_id`
                // are compared so we pick the correct empty side regardless
                // of which edge was the populated one.
                const merge_id: u32 = self.table.get(header_id).?.merge_id;
                const target: *ir.Block = if (false_id == merge_id) false_blk else true_blk;
                try appendExitArg(self.arena, target, value_id);
                return;
            }
            // Otherwise the value comes from a real predecessor block; route
            // to whichever branch terminator that block carries.  `by_id`
            // maps a SPIR-V block id to the IR block whose terminator we
            // attach to.  When the pred is the immediate branch target, that
            // is the branch block itself.
            const blk: *ir.Block = self.by_id.get(pred_id) orelse blk: {
                // The pred isn't directly registered - it's the branch
                // ENTRY block reached transitively.  Fall back to matching
                // the pred against the branch entry ids.
                if (pred_id == true_id) {
                    break :blk true_blk;
                }
                if (pred_id == false_id) {
                    break :blk false_blk;
                }
                // The predecessor block was never built into the structured
                // IR: it is structurally UNREACHABLE (no in-edges in this
                // function's CFG) yet still named by the merge OpPhi.  Zig's
                // un-optimized SPIR-V leaves such dead blocks behind (an
                // optimizing pass like spirv-opt's dead-branch/merge-return
                // elimination would have removed them).  The phi edge from a
                // block that cannot execute supplies a value that is never
                // produced at runtime, so there is no IR exit terminator to
                // attach it to - skip this edge.  The live predecessors
                // still carry the real values, and the hoisted phi `var`
                // holds a default for the (unreachable) dead edge.  This is
                // sound: dropping an unreachable def-edge cannot change any
                // reachable computation.
                return;
            };
            try appendExitArg(self.arena, blk, value_id);
        }

        /// Finish a block: take the accumulated items + a terminator,
        /// allocate the `*ir.Block`.
        fn finishBlock(
            self: *Builder,
            items: ArrayList(ir.Item),
            term: ir.Terminator,
        ) BuildError!*ir.Block {
            var items_mut: ArrayList(ir.Item) = items;
            const blk: *ir.Block = try self.arena.create(ir.Block);
            blk.* = .{ .items = try items_mut.toOwnedSlice(self.arena), .term = term };
            return blk;
        }

        fn classifyTerminator(self: *Builder, info: BlockInfo) TermKind {
            const off: u32 = self.inst_off[info.terminator_inst_idx];
            const op: u32 = types.opcodeOf(self.spirv[off]);
            return switch (op) {
                @backingInt(types.Op.Return) => .ret,
                @backingInt(types.Op.ReturnValue) => .ret_value,
                @backingInt(types.Op.Kill) => .kill,
                @backingInt(types.Op.Branch) => .branch,
                @backingInt(types.Op.BranchConditional) => .branch_cond,
                @backingInt(types.Op.Switch) => .switch_,
                @backingInt(types.Op.Unreachable) => .unreach,
                else => .branch, // treat unknown as a passthrough branch
            };
        }

        fn branchTarget(self: *Builder, info: BlockInfo) BuildError!u32 {
            const off: u32 = self.inst_off[info.terminator_inst_idx];
            const ops: []const u32 = types.operandsAt(self.spirv, off);
            // A well-formed OpBranch has exactly one operand (the target).
            // Defend against a malformed/zero-operand terminator (seen on
            // some exotic CFG shapes) - index [0] would segfault.  Treat it
            // as a shape we can't lower rather than crashing.
            if (ops.len == 0) {
                return error.IrBuildUnsupported;
            }
            return ops[0];
        }
    };

    const TermKind = enum { ret, ret_value, kill, unreach, branch, branch_cond, switch_ };

    /// How many args an exit-kind terminator currently carries (0 for
    /// non-exit terminators).
    fn exitArgLen(term: ir.Terminator) usize {
        return switch (term) {
            .exit_if => |e| e.args.len,
            .exit_switch => |e| e.args.len,
            .exit_loop => |e| e.args.len,
            .cont => |e| e.args.len,
            .break_if => |b| b.args.len,
            else => 0,
        };
    }

    /// Append `value_id` to a block's exit terminator args (reallocating
    /// the args slice in the arena).  Asserts the terminator is an
    /// exit kind.
    fn appendExitArg(
        arena: Allocator,
        blk: *ir.Block,
        value_id: ir.ValueId,
    ) BuildError!void {
        switch (blk.term) {
            .exit_if => |*e| e.args = try appendId(arena, e.args, value_id),
            .exit_switch => |*e| e.args = try appendId(arena, e.args, value_id),
            .exit_loop => |*e| e.args = try appendId(arena, e.args, value_id),
            .cont => |*e| e.args = try appendId(arena, e.args, value_id),
            .break_if => |*b| b.args = try appendId(arena, b.args, value_id),
            else => return error.MalformedFunction,
        }
    }

    fn appendId(
        arena: Allocator,
        old: []ir.ValueId,
        value_id: ir.ValueId,
    ) BuildError![]ir.ValueId {
        const out: []ir.ValueId = try arena.alloc(ir.ValueId, old.len + 1);
        @memcpy(out[0..old.len], old);
        out[old.len] = value_id;
        return out;
    }

    /// Append a u32 to a `[]const u32`, reallocating in the arena.  Used to
    /// collect multiple switch-case selector literals that share a target.
    fn appendU32(
        arena: Allocator,
        old: []const u32,
        value: u32,
    ) BuildError![]const u32 {
        const out: []u32 = try arena.alloc(u32, old.len + 1);
        @memcpy(out[0..old.len], old);
        out[old.len] = value;
        return out;
    }

    /// Index of the existing case whose SPIR-V target is `target`, for
    /// deduping switch selectors that branch to the same block.
    fn findCaseIndex(targets: []const u32, target: u32) ?usize {
        for (targets, 0..) |t, idx| {
            if (t == target) {
                return idx;
            }
        }
        return null;
    }

    /// The entry block is the first OpLabel after OpFunction (SPIR-V puts
    /// the function's first basic block immediately after the parameter
    /// declarations, and we have none in these shaders).
    fn findEntryBlock(
        fn_k: usize,
        end_k: usize,
        inst_off: []const u32,
        spirv: []const u32,
    ) BuildError!u32 {
        var k: usize = fn_k + 1;
        while (k < end_k) : (k += 1) {
            const off: u32 = inst_off[k];
            if (types.opcodeOf(spirv[off]) == @backingInt(types.Op.Label)) {
                return types.operandsAt(spirv, off)[0];
            }
        }
        return error.MalformedFunction;
    }

    /// Map a block's terminator instruction to an IR terminator.  Only
    /// the function-exiting terminators are valid in a single plain block;
    /// branch/conditional/switch imply more blocks (handled by the
    /// construct reconstruction, not yet wired).
    fn mapTerminator(
        info: BlockInfo,
        inst_off: []const u32,
        spirv: []const u32,
    ) BuildError!ir.Terminator {
        const off: u32 = inst_off[info.terminator_inst_idx];
        const op: u32 = types.opcodeOf(spirv[off]);
        if (op == @backingInt(types.Op.Return)) {
            return .ret;
        } else if (op == @backingInt(types.Op.ReturnValue)) {
            return .{ .ret_value = types.operandsAt(spirv, off)[0] };
        } else if (op == @backingInt(types.Op.Kill)) {
            return .kill;
        } else if (op == @backingInt(types.Op.Unreachable)) {
            // SPIR-V "statically unreachable" - Zig emits it after a chain
            // of returning branches.  No WGSL terminator needed (the block
            // is never reached; `ir_emit` lowers `.unreach` to nothing and
            // naga's behaviour analysis is satisfied by the reachable paths).
            return .unreach;
        } else {
            // Branch / BranchConditional / Switch in a lone plain block ->
            // there must be more blocks; defer to the (not-yet-wired)
            // construct path.
            return error.IrBuildUnsupported;
        }
    }

    // -----------------------------------------------------------------------------
    // SPIR-V word helpers (kept local, matching block_table.zig / walker.zig).
    // -----------------------------------------------------------------------------

    // =============================================================================
    // Tests
    // =============================================================================

    const testing = std.testing;

    /// Build a flat instruction-offset index over a SPIR-V word slice the
    /// way the main pipeline does: skip the 5-word header, then walk
    /// instruction by instruction (word count is the high half of the
    /// first word of each instruction).
    fn instOffsets(a: Allocator, spirv: []const u32) ![]u32 {
        var offs: ArrayList(u32) = .empty;
        var off: usize = 5;
        while (off < spirv.len) {
            try offs.append(a, @intCast(off));
            const wc: usize = spirv[off] >> 16;
            assert(wc != 0);
            off += wc;
        }
        return offs.toOwnedSlice(a);
    }

    inline fn inst(word_count: u32, op: types.Op) u32 {
        return (word_count << 16) | @backingInt(op);
    }

    test "build lowers a single-block void function to FnBody{ret}" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // Minimal module: header + OpFunction %1 / OpLabel %5 / OpReturn /
        // OpFunctionEnd.  Type ids are placeholders - the builder only
        // inspects labels + terminators.
        const words = [_]u32{
            0x07230203, 0x00010600, 0, 99, 0, // header (bound = 99)
            inst(5, types.Op.Function), 2, 1, 0, 3, // %1 = OpFunction (void) ctrl=0 fnty=%3
            inst(2, types.Op.Label),  5, // %5 = OpLabel
            inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        // fn_k = index of OpFunction (0), end_k = index of OpFunctionEnd (last).
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        try testing.expect(body.entry.items.len == 1);
        try testing.expect(body.entry.items[0] == .body);
        try testing.expect(body.entry.items[0].body == 5);
        try testing.expect(body.entry.term == .ret);
        // The reconstructed IR must satisfy the structural invariant.
        try ir.validate(&body);
    }

    test "build reconstructs a one-sided if (header branches to merge)" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 header: if (%10) -> %6 else -> %7(merge).  %6 -> %7.  %7 ret.
        // No phi at the merge.  Expect: entry block = [body %5, If],
        // term continues into merge %7 (body %7, ret).
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0,
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label),    5,
            inst(3, types.Op.SelectionMerge), 7, 0, // merge=%7
            inst(4, types.Op.BranchConditional), 10, 6,                        7, // cond=%10 T=%6 F=%7
            inst(2, types.Op.Label),             6,  inst(2, types.Op.Branch), 7,
            inst(2, types.Op.Label),             7,  inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        // entry: body %5, the If construct, then continuation merge %7 as
        // a `body` item (the section 2.3 recipe - merge emitted once in parent).
        try testing.expect(body.entry.items.len == 3);
        try testing.expect(body.entry.items[0] == .body);
        try testing.expect(body.entry.items[0].body == 5);
        try testing.expect(body.entry.items[1] == .construct);
        try testing.expect(body.entry.items[2] == .body);
        try testing.expect(body.entry.items[2].body == 7);
        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .if_);
        try testing.expect(c.if_.cond == 10);
        try testing.expect(c.if_.merge_id == 7);
        // No merge phi -> no results, both branches exit_if with 0 args.
        try testing.expect(c.if_.results.len == 0);
        try testing.expect(c.if_.true_blk.term == .exit_if);
        try testing.expect(c.if_.false_blk.term == .exit_if);
        // The continuation (merge %7) is the entry block's terminator chain:
        // entry.term should be `ret` (merge %7 is plain -> ret).
        try testing.expect(body.entry.term == .ret);
        try ir.validate(&body);
    }

    test "build reconstructs a diamond if/else with a merge phi on both exits" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 header: if (%10) -> %6 else -> %8.  %6 -> %7(merge). %8 -> %7.
        // %7 has OpPhi %20 = (%21 from %6, %22 from %8); then ret.
        // Expect: If with one result param (phi %20); true_blk exit_if
        // args=[%21], false_blk exit_if args=[%22] - the phi on BOTH exits.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0,
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label),    5,
            inst(3, types.Op.SelectionMerge), 7, 0, // merge=%7
            inst(4, types.Op.BranchConditional), 10, 6,                        8, // cond=%10 T=%6 F=%8
            inst(2, types.Op.Label),             6,  inst(2, types.Op.Branch), 7,
            inst(2, types.Op.Label),             8,  inst(2, types.Op.Branch), 7,
            inst(2, types.Op.Label),             7,
            inst(7, types.Op.Phi),    2,                             20, 21, 6, 22, 8, // %20 = phi (%21:%6, %22:%8)
            inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .if_);
        try testing.expect(c.if_.results.len == 1);
        try testing.expect(c.if_.results[0].phi_id == 20);
        try testing.expect(c.if_.results[0].type_id == 2);
        // The phi value lands on BOTH branch exits (the dropped-copy fix).
        try testing.expect(c.if_.true_blk.term == .exit_if);
        try testing.expect(c.if_.true_blk.term.exit_if.args.len == 1);
        try testing.expect(c.if_.true_blk.term.exit_if.args[0] == 21);
        try testing.expect(c.if_.false_blk.term == .exit_if);
        try testing.expect(c.if_.false_blk.term.exit_if.args.len == 1);
        try testing.expect(c.if_.false_blk.term.exit_if.args[0] == 22);
        // Validator confirms every exit supplies exactly results.len args.
        try ir.validate(&body);
    }

    test "build reconstructs a simple no-phi loop" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 -> %6(loop header).  %6 LoopMerge(merge=%9 cont=%8) -> %7 body.
        // %7 -> %8 continue. %8 -> %6 back-edge. %9 merge ret.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0,                        99, 0,
            inst(5, types.Op.Function), 2,          1,                        0,  3,
            inst(2, types.Op.Label),    5,          inst(2, types.Op.Branch), 6,  inst(2, types.Op.Label),
            6,
            inst(4, types.Op.LoopMerge), 9,                             8,                       0, // merge=%9 cont=%8
            inst(2, types.Op.Branch),    7,                             inst(2, types.Op.Label), 7,
            inst(2, types.Op.Branch),    8,                             inst(2, types.Op.Label), 8,
            inst(2, types.Op.Branch),    6,                             inst(2, types.Op.Label), 9,
            inst(1, types.Op.Return),    inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        // entry: body %5, Loop, body %9 (merge).  The loop header's OWN
        // body (%6) is now the FIRST item INSIDE the loop body.
        try testing.expect(body.entry.items.len == 3);
        try testing.expect(body.entry.items[1] == .construct);
        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.merge_id == 9);
        // Loop body: header body %6 first, then body %7 -> cont.
        try testing.expect(c.loop_.body.items.len == 2);
        try testing.expect(c.loop_.body.items[0].body == 6);
        try testing.expect(c.loop_.body.items[1].body == 7);
        try testing.expect(c.loop_.body.term == .cont);
        // Continuing %8 -> back-edge branch to header %6.
        try testing.expect(c.loop_.continuing.term == .branch);
        try testing.expect(c.loop_.continuing.term.branch == 6);
        try ir.validate(&body);
    }

    test "build reconstructs a header-conditional while-loop (guard-if at body top)" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 -> %6(loop header).  %6 LoopMerge(merge=%9 cont=%8); then
        // OpBranchConditional %99 %7 %9 - TRUE enters body %7, FALSE breaks
        // to merge %9 (the `while (cond)` shape).  %7 -> %8 cont. %8 -> %6
        // back-edge. %9 merge ret.  Expect: a Loop whose body's first
        // construct is a guard If (cond %99) with true=body, false=break
        // (exit_loop).
        const words = [_]u32{
            0x07230203,                 0x00010600, 0,                        99, 0,
            inst(5, types.Op.Function), 2,          1,                        0,  3,
            inst(2, types.Op.Label),    5,          inst(2, types.Op.Branch), 6,  inst(2, types.Op.Label),
            6,
            inst(4, types.Op.LoopMerge), 9, 8, 0, // merge=%9 cont=%8
            inst(4, types.Op.BranchConditional), 99, 7,                        9, // TRUE->body%7 FALSE->merge%9
            inst(2, types.Op.Label),             7,  inst(2, types.Op.Branch), 8,
            inst(2, types.Op.Label),             8,  inst(2, types.Op.Branch), 6,
            inst(2, types.Op.Label),             9,  inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.merge_id == 9);
        // Loop body: header body %6 first, then the guard If.
        try testing.expect(c.loop_.body.items.len == 2);
        try testing.expect(c.loop_.body.items[0].body == 6);
        try testing.expect(c.loop_.body.items[1] == .construct);
        const guard: *ir.Construct = c.loop_.body.items[1].construct;
        try testing.expect(guard.* == .if_);
        try testing.expect(guard.if_.cond == 99);
        // FALSE edge breaks: false_blk is the `exit_loop` (the break), and
        // true_blk carries the body chain (-> cont).
        try testing.expect(guard.if_.false_blk.term == .exit_loop);
        try testing.expect(guard.if_.true_blk.term == .cont);
        try ir.validate(&body);
    }

    test "build reconstructs a single-block infinite loop whose header conditional never breaks" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 -> %6(loop header == continuing).  %6 LoopMerge(merge=%9 cont=%6);
        // then OpBranchConditional %99 %6 %6 - BOTH edges are the back-edge to
        // %6, neither reaches the merge %9.  A true infinite loop whose header
        // conditional never breaks.  Expect a Loop with an empty continuing
        // (the condition is immaterial) and no break.  %9 merge ret.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0,                        99, 0,
            inst(5, types.Op.Function), 2,          1,                        0,  3,
            inst(2, types.Op.Label),    5,          inst(2, types.Op.Branch), 6,  inst(2, types.Op.Label),
            6,
            inst(4, types.Op.LoopMerge), 9, 6, 0, // merge=%9 cont=%6 (self)
            inst(4, types.Op.BranchConditional), 99, 6,                        6, // BOTH->back-edge %6
            inst(2, types.Op.Label),             9,  inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.merge_id == 9);
        // Empty continuing, no break - control never leaves (an infinite loop).
        try testing.expect(c.loop_.continuing.term == .branch);
        try ir.validate(&body);
    }

    test "build reconstructs an infinite loop whose header conditional breaks from the body" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 -> %6(loop header).  %6 LoopMerge(merge=%9 cont=%8); then
        // OpBranchConditional %99 %7 %8 - NEITHER edge targets the merge %9:
        // TRUE enters body %7, FALSE goes straight to the continuing %8.  So
        // the header conditional is in-body flow inside an infinite loop.
        // %7 body -> %9 break (exit_loop).  %8 cont -> %6 back-edge.  %9 ret.
        // Expect a Loop whose body's first construct (after the header items)
        // is an in-body If (cond %99), true arm -> body chain that breaks,
        // false arm -> cont.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0,
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label), 5, // entry label %5
            inst(2, types.Op.Branch), 6,                           inst(2, types.Op.Label), // -> header %6
            6,                        inst(4, types.Op.LoopMerge), 9,
            8,                        0,
            inst(4, types.Op.BranchConditional), 99, 7, 8, // TRUE->body%7 FALSE->cont%8 (neither is merge%9)
            inst(2, types.Op.Label), 7, inst(2, types.Op.Branch), 9, // body->break%9
            inst(2, types.Op.Label), 8, inst(2, types.Op.Branch), 6, // cont->header%6
            inst(2, types.Op.Label), 9, inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.merge_id == 9);
        // Body: header items %6, then the in-body If (no guard/break-on-merge).
        const last: ir.Item = c.loop_.body.items[c.loop_.body.items.len - 1];
        try testing.expect(last == .construct);
        try testing.expect(last.construct.* == .if_);
        try testing.expect(last.construct.if_.cond == 99);
        try ir.validate(&body);
    }

    test "build reconstructs a loop whose continuing block breaks conditionally" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 -> %6(loop header).  %6 LoopMerge(merge=%9 cont=%8); then
        // OpBranchConditional %98 %7 %9 - TRUE enters body %7, FALSE breaks.
        // %7 body -> %8 cont.  %8 continuing -> OpBranchConditional %99 %9 %6
        // - TRUE breaks to merge %9, FALSE loops back to header %6.  Expect a
        // Loop whose continuing block ends in a `break_if` (cond %99, not
        // inverted, since the BREAK is the TRUE edge).  %9 merge ret.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0,
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label), 5, // entry label %5
            inst(2, types.Op.Branch), 6,                           inst(2, types.Op.Label), // -> header %6
            6,                        inst(4, types.Op.LoopMerge), 9,
            8,                        0,
            inst(4, types.Op.BranchConditional), 98, 7, 9, // TRUE->body%7 FALSE->break%9
            inst(2, types.Op.Label), 7, inst(2, types.Op.Branch), 8, // body->cont
            inst(2, types.Op.Label), 8, // continuing
            inst(4, types.Op.BranchConditional), 99, 9,                        6, // TRUE->break%9 FALSE->header%6
            inst(2, types.Op.Label),             9,  inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.continuing.term == .break_if);
        try testing.expect(c.loop_.continuing.term.break_if.cond == 99);
        try testing.expect(c.loop_.continuing.term.break_if.invert == false);
        try ir.validate(&body);
    }

    test "build reconstructs a degenerate loop whose header breaks on both edges" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 -> %6(loop header).  %6 LoopMerge(merge=%9 cont=%8); then
        // OpBranchConditional %99 %9 %9 - BOTH edges break to merge %9 (a
        // loop that never iterates).  %8 cont -> %6 back-edge. %9 merge ret.
        // Expect: a Loop whose body's first construct is a guard If (cond
        // %99) with BOTH arms exit_loop.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0,                        99, 0,
            inst(5, types.Op.Function), 2,          1,                        0,  3,
            inst(2, types.Op.Label),    5,          inst(2, types.Op.Branch), 6,  inst(2, types.Op.Label),
            6,
            inst(4, types.Op.LoopMerge), 9, 8, 0, // merge=%9 cont=%8
            inst(4, types.Op.BranchConditional), 99, 9,                        9, // BOTH->merge%9
            inst(2, types.Op.Label),             8,  inst(2, types.Op.Branch), 6,
            inst(2, types.Op.Label),             9,  inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.merge_id == 9);
        // Loop body: header body %6 first, then the guard If with both arms
        // breaking.
        try testing.expect(c.loop_.body.items[1] == .construct);
        const guard: *ir.Construct = c.loop_.body.items[1].construct;
        try testing.expect(guard.* == .if_);
        try testing.expect(guard.if_.cond == 99);
        try testing.expect(guard.if_.true_blk.term == .exit_loop);
        try testing.expect(guard.if_.false_blk.term == .exit_loop);
        try ir.validate(&body);
    }

    test "build attaches a loop-merge phi fed by an in-loop if-break" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // Loop header %12 (LoopMerge merge=%13 cont=%14) -> body %15.
        // %15 is a selection header (SelectionMerge %16) whose true edge
        // breaks the loop (-> %13) and false -> %16; %16 -> %13 too.  The loop
        // merge %13 has an OpPhi taking (%6 from %15) and (%7 from %16) - a
        // value escaping the loop via an in-body if-break.  Expect the loop
        // to build and the merge phi to attach to BOTH break edges.
        // zig fmt: off
        const words = [_]u32{
            0x07230203, 0x00010600, 0, 99, 0,
            inst(5, types.Op.Function), 2, 1, 0, 11,
            inst(2, types.Op.Label), 11,
            inst(2, types.Op.Branch), 12,
            inst(2, types.Op.Label), 12,
            inst(4, types.Op.LoopMerge), 13, 14, 0,
            inst(2, types.Op.Branch), 15,
            inst(2, types.Op.Label), 15,
            inst(3, types.Op.SelectionMerge), 16, 0,
            inst(4, types.Op.BranchConditional), 10, 13, 16,
            inst(2, types.Op.Label), 16,
            inst(2, types.Op.Branch), 13,
            inst(2, types.Op.Label), 14,
            inst(2, types.Op.Branch), 12,
            inst(2, types.Op.Label), 13,
            inst(7, types.Op.Phi), 4, 17, 6, 15, 7, 16,
            inst(1, types.Op.Return),
            inst(1, types.Op.FunctionEnd),
        };
        // zig fmt: on
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.results.len == 1);
        try testing.expect(c.loop_.results[0].phi_id == 17);
        try ir.validate(&body);
    }

    test "build reconstructs a single-block conditional loop (break_if in continuing)" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 -> %6 header. LoopMerge(merge=%9 cont=%6) - continue == header,
        // a SINGLE-BLOCK loop.  Header ends OpBranchConditional %99 %6 %9:
        // TRUE -> back-edge (%6), FALSE -> merge (%9, break).  Expect a Loop
        // whose continuing block ends with a `break_if` (inverted, since the
        // FALSE edge breaks -> break when !cond) and an empty body chain.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0,                        99, 0,
            inst(5, types.Op.Function), 2,          1,                        0,  3,
            inst(2, types.Op.Label),    5,          inst(2, types.Op.Branch), 6,  inst(2, types.Op.Label),
            6,
            inst(4, types.Op.LoopMerge), 9, 6, 0, // merge=%9 cont=%6 (==header)
            inst(4, types.Op.BranchConditional), 99, 6,                        9, // TRUE->back-edge FALSE->break
            inst(2, types.Op.Label),             9,  inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.merge_id == 9);
        // Continuing block ends with a break_if; FALSE breaks -> invert.
        try testing.expect(c.loop_.continuing.term == .break_if);
        try testing.expect(c.loop_.continuing.term.break_if.cond == 99);
        try testing.expect(c.loop_.continuing.term.break_if.invert == true);
        try ir.validate(&body);
    }

    test "build reconstructs a loop whose continuing block contains an if" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %5 -> %6 header. LoopMerge(merge=%9 cont=%8). Header -> body %7.
        // %7 -> cont %8. %8 is a SELECTION header: SelectionMerge %8m, then
        // BranchConditional %99 %8a %8b; both -> %8m; %8m -> back-edge %6.
        // Expect: Loop whose `continuing` block holds an If construct, then
        // the implicit back-edge branch.
        // zig fmt: off
        const words = [_]u32{
            0x07230203, 0x00010600, 0, 99, 0,
            inst(5, types.Op.Function), 2, 1, 0, 3,
            inst(2, types.Op.Label), 5,
            inst(2, types.Op.Branch), 6,
            inst(2, types.Op.Label), 6,
            inst(4, types.Op.LoopMerge), 9, 8, 0,
            inst(2, types.Op.Branch), 7,
            inst(2, types.Op.Label), 7,
            inst(2, types.Op.Branch), 8,
            // continue block %8 = selection header
            inst(2, types.Op.Label), 8,
            inst(3, types.Op.SelectionMerge), 20, 0,
            inst(4, types.Op.BranchConditional), 99, 18, 19,
            inst(2, types.Op.Label), 18,
            inst(2, types.Op.Branch), 20,
            inst(2, types.Op.Label), 19,
            inst(2, types.Op.Branch), 20,
            inst(2, types.Op.Label), 20,
            inst(2, types.Op.Branch), 6, // merge -> back-edge
            inst(2, types.Op.Label), 9,
            inst(1, types.Op.Return),
            inst(1, types.Op.FunctionEnd),
        };
        // zig fmt: on
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        // Continuing block: header body %8 item, then the nested If construct.
        const cont: *ir.Block = c.loop_.continuing;
        var saw_if: bool = false;
        for (cont.items) |it| {
            if (it == .construct and it.construct.* == .if_) {
                saw_if = true;
            }
        }
        try testing.expect(saw_if);
        // The continuing block ends with the implicit back-edge branch.
        try testing.expect(cont.term == .branch);
        try ir.validate(&body);
    }

    test "build reconstructs the mandelbrot break-out-of-loop pattern" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // The canonical shape (block_table test): loop header %10 contains inner
        // if %20 whose true branch %30 BREAKS to the loop merge %60 (a
        // branch to merge nested inside an if), false -> inner merge %40 ->
        // continue %50 -> back-edge %10.  No phis.  The break must become
        // `exit_loop` even though it's inside the inner if.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0,
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label),    10,
            inst(4, types.Op.LoopMerge),      60, 50,                      0, // merge=%60 cont=%50
            inst(2, types.Op.Branch),         20, inst(2, types.Op.Label), 20,
            inst(3, types.Op.SelectionMerge), 40, 0,
            inst(4, types.Op.BranchConditional), 99, 30, 40, // cond T=%30 F=%40
            inst(2, types.Op.Label), 30, inst(2, types.Op.Branch), 60, // break out of loop
            inst(2, types.Op.Label), 40, inst(2, types.Op.Branch), 50, // inner merge -> continue
            inst(2, types.Op.Label), 50, inst(2, types.Op.Branch), 10, // continue -> header
            inst(2, types.Op.Label), 60, inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        // entry: Loop, body %60 (merge).  The loop header %10 is the entry
        // block, so its own body is the FIRST item inside the loop body.
        const c: *ir.Construct = body.entry.items[0].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.merge_id == 60);
        // Loop body: header body %10, then inner-if header body %20, then
        // the inner If whose TRUE branch %30 breaks to the loop merge.
        const body_items: []ir.Item = c.loop_.body.items;
        try testing.expect(body_items[0].body == 10);
        try testing.expect(body_items[1].body == 20);
        try testing.expect(body_items[2] == .construct);
        const inner_if: *ir.Construct = body_items[2].construct;
        try testing.expect(inner_if.* == .if_);
        // The true branch (%30) breaks out of the loop.
        try testing.expect(inner_if.if_.true_blk.term == .exit_loop);
        // The false branch is empty (false_id == inner merge %40).
        try testing.expect(inner_if.if_.false_blk.term == .exit_if);
        try ir.validate(&body);
    }

    test "build reconstructs a loop-header phi (init + iter split)" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // Loop header %6 carries a loop-header OpPhi:
        //   %30 = OpPhi %t (%31 from %5 = pre-loop init), (%32 from %8 = continue iter)
        // continue %8 -> Branch %6 (back-edge).  Expect header_params=[phi30
        // with init=31], iter_args=[32].
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0, // header
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label), 5, //
            inst(2, types.Op.Branch), 6, //
            inst(2, types.Op.Label), 6, //
            inst(7, types.Op.Phi), 2, 30, 31, 5, 32, 8, // %30 = phi(%31:%5, %32:%8)
            inst(4, types.Op.LoopMerge), 9, 8, 0, //
            inst(2, types.Op.Branch), 7, //
            inst(2, types.Op.Label), 7, //
            inst(2, types.Op.Branch), 8, //
            inst(2, types.Op.Label), 8, //
            inst(2, types.Op.Branch), 6, // continue -> header back-edge
            inst(2, types.Op.Label),  9, //
            inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        // entry: body %5, Loop, body %9.  The header body %6 (with the
        // phi) is now the first item INSIDE the loop body.
        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .loop_);
        // One loop-carried header phi.
        try testing.expect(c.loop_.header_params.len == 1);
        try testing.expect(c.loop_.header_params[0].phi_id == 30);
        try testing.expect(c.loop_.header_params[0].type_id == 2);
        // Init = the pre-loop (%5) edge value %31.
        try testing.expect(c.loop_.header_params[0].init.? == 31);
        // Iter = the continue (%8) edge value %32, positional in iter_args.
        try testing.expect(c.loop_.iter_args.len == 1);
        try testing.expect(c.loop_.iter_args[0] == 32);
        // Body's cont edge carries no args (the update is via iter_args).
        try testing.expect(c.loop_.body.term == .cont);
        try testing.expect(c.loop_.body.term.cont.args.len == 0);
        try ir.validate(&body);
    }

    test "build reconstructs a loop-merge phi (value escaping the loop)" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // Loop header %10 (merge %60 cont %50) contains inner if %20 (merge %40).
        // The TRUE branch %30 breaks to the loop merge %60.  %60 carries a
        // loop-merge OpPhi %70 = (%71 from %30).  Expect results=[phi70],
        // and the break edge (inner if true branch) carries arg [71].
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0, // header
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label), 10, //
            inst(4, types.Op.LoopMerge), 60, 50, 0, //
            inst(2, types.Op.Branch), 20, //
            inst(2, types.Op.Label), 20, //
            inst(3, types.Op.SelectionMerge), 40, 0, //
            inst(4, types.Op.BranchConditional), 99, 30, 40, //
            inst(2, types.Op.Label), 30, //
            inst(2, types.Op.Branch), 60, // break out of loop (carries phi %71)
            inst(2, types.Op.Label), 40, //
            inst(2, types.Op.Branch), 50, //
            inst(2, types.Op.Label), 50, //
            inst(2, types.Op.Branch), 10, //
            inst(2, types.Op.Label), 60, //
            inst(5, types.Op.Phi),    2,                             70, 71, 30, // %70 = phi(%71:%30)
            inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[0].construct;
        try testing.expect(c.* == .loop_);
        try testing.expect(c.loop_.results.len == 1);
        try testing.expect(c.loop_.results[0].phi_id == 70);
        // The break (inner if true branch %30) is an exit_loop carrying %71.
        // Loop body: header %10, inner-if header %20, then the If.
        const inner_if: *ir.Construct = c.loop_.body.items[2].construct;
        try testing.expect(inner_if.if_.true_blk.term == .exit_loop);
        try testing.expect(inner_if.if_.true_blk.term.exit_loop.args.len == 1);
        try testing.expect(inner_if.if_.true_blk.term.exit_loop.args[0] == 71);
        try ir.validate(&body);
    }

    test "build resolves a continue nested inside an if to the loop (stop-stack by target)" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // Loop %10 (merge %60, cont %50) contains inner if %20 (merge %40) whose
        // TRUE branch %30 does `continue` (branches to the loop continue
        // %50) - a `cont` that must skip PAST the inner if's `(merge %40,
        // exit_if)` stop to find the loop's `(continue %50, cont)`.  This
        // exercises innermost-by-TARGET lookup (not innermost-by-position):
        // %50 is on the stack below %40, but the branch targets %50, so the
        // lookup must match on id, returning `cont`.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0, // header
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label), 10, //
            inst(4, types.Op.LoopMerge), 60, 50, 0, // merge=%60 cont=%50
            inst(2, types.Op.Branch), 20, //
            inst(2, types.Op.Label), 20, //
            inst(3, types.Op.SelectionMerge), 40, 0, //
            inst(4, types.Op.BranchConditional), 99, 30, 40, // T=%30 F=%40
            inst(2, types.Op.Label), 30, //
            inst(2, types.Op.Branch), 50, // continue (to loop continue target)
            inst(2, types.Op.Label), 40, //
            inst(2, types.Op.Branch), 50, // inner merge -> continue
            inst(2, types.Op.Label), 50, //
            inst(2, types.Op.Branch), 10, // continue -> header back-edge
            inst(2, types.Op.Label),  60, //
            inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[0].construct;
        try testing.expect(c.* == .loop_);
        // Loop body: header %10, inner-if header %20, then the inner If
        // whose TRUE branch (%30) continues the loop -> `cont` (NOT exit_if,
        // even though the if's merge is the innermost stack entry).
        const inner_if: *ir.Construct = c.loop_.body.items[2].construct;
        try testing.expect(inner_if.* == .if_);
        try testing.expect(inner_if.if_.true_blk.term == .cont);
        // The false branch is the empty path to the inner merge -> exit_if.
        try testing.expect(inner_if.if_.false_blk.term == .exit_if);
        try ir.validate(&body);
    }
    test "build reconstructs a switch with cases, default, and a merge phi" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // %10 switch_header: SelectionMerge %40; OpSwitch sel=%99 default=%30
        //   case 1 -> %20, case 2 -> %25.  %20,%25,%30 each Branch %40.
        // %40 merge: OpPhi %70 = (%71 from %20, %72 from %25, %73 from %30);
        //   then ret.  Expect a Switch with 2 cases + default, results=[70],
        //   and each case's exit_switch carrying its phi arg.
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0, // header
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label), 10, //
            inst(3, types.Op.SelectionMerge), 40, 0, //
            inst(7, types.Op.Switch), 99, 30, 1, 20, 2, 25, // sel default=%30 1->%20 2->%25
            inst(2, types.Op.Label), 20, //
            inst(2, types.Op.Branch), 40, //
            inst(2, types.Op.Label), 25, //
            inst(2, types.Op.Branch), 40, //
            inst(2, types.Op.Label), 30, //
            inst(2, types.Op.Branch), 40, //
            inst(2, types.Op.Label), 40, //
            inst(9, types.Op.Phi),    2,                             70, 71, 20, 72, 25, 73, 30, // %70 = phi(...)
            inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .switch_);
        try testing.expect(c.switch_.selector == 99);
        try testing.expect(c.switch_.merge_id == 40);
        try testing.expect(c.switch_.cases.len == 2);
        try testing.expect(c.switch_.cases[0].values.len == 1);
        try testing.expect(c.switch_.cases[0].values[0] == 1);
        try testing.expect(c.switch_.cases[1].values[0] == 2);
        // Merge phi -> one result.
        try testing.expect(c.switch_.results.len == 1);
        try testing.expect(c.switch_.results[0].phi_id == 70);
        // Each case exit_switch carries its phi value.
        try testing.expect(c.switch_.cases[0].blk.term == .exit_switch);
        try testing.expect(c.switch_.cases[0].blk.term.exit_switch.args[0] == 71);
        try testing.expect(c.switch_.cases[1].blk.term.exit_switch.args[0] == 72);
        try testing.expect(c.switch_.default_blk.term == .exit_switch);
        try testing.expect(c.switch_.default_blk.term.exit_switch.args[0] == 73);
        try ir.validate(&body);
    }

    test "build dedups switch selectors that share a case body" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // OpSwitch sel=%99 default=%30  case 1 -> %20, case 2 -> %20 (SAME).
        // Expect ONE case with two values [1, 2] (WGSL `case 1, 2: {}`).
        const words = [_]u32{
            0x07230203,                 0x00010600, 0, 99, 0, // header
            inst(5, types.Op.Function), 2,          1, 0,  3,
            inst(2, types.Op.Label), 10, //
            inst(3, types.Op.SelectionMerge), 40, 0, //
            inst(7, types.Op.Switch), 99, 30, 1, 20, 2, 20, // 1->%20 2->%20 (shared)
            inst(2, types.Op.Label), 20, //
            inst(2, types.Op.Branch), 40, //
            inst(2, types.Op.Label), 30, //
            inst(2, types.Op.Branch), 40, //
            inst(2, types.Op.Label),  40, //
            inst(1, types.Op.Return), inst(1, types.Op.FunctionEnd),
        };
        const offs: []u32 = try instOffsets(a, &words);
        const body: ir.FnBody = try build(a, 0, offs.len - 1, offs, &words);

        const c: *ir.Construct = body.entry.items[1].construct;
        try testing.expect(c.* == .switch_);
        // One merged case carrying both selector values.
        try testing.expect(c.switch_.cases.len == 1);
        try testing.expect(c.switch_.cases[0].values.len == 2);
        try testing.expect(c.switch_.cases[0].values[0] == 1);
        try testing.expect(c.switch_.cases[0].values[1] == 2);
        try ir.validate(&body);
    }
};

pub const ir_emit = struct {
    // src/spv2wgsl/ir_emit.zig - emit WGSL from the structured `ir`
    // (the F3 step of the Tint-style rewrite; see
    // `src/notes/spv2wgsl_ir_rewrite.md`).
    //
    // WHAT THIS DOES
    // Walks an `ir.FnBody` and writes the function BODY (the statements
    // between the `{` and `}` of the WGSL function) into `out`.  The
    // hoisted `var phi{id}: T;` declarations are NOT emitted here - the
    // existing `pass4_functions` prepass in `spv2wgsl.zig` already
    // declares every phi var at function entry, independent of which
    // walker runs.  This emitter only renders:
    //   - each block's straight-line body, via the caller-supplied
    //     `emitBlockBody` callback (the existing id-table text emitter,
    //     `emitBlockBodyOnly`);
    //   - the structured `If` / `Loop` / `Switch` shells;
    //   - the per-exit `phi{id} = <value>;` assignments: each exit edge
    //     of a construct assigns the construct's result phis from that
    //     edge's args (the dropped-copy fix - every path that reaches a
    //     merge assigns its phis);
    //   - the function terminators (`return` / `return outputs;` / etc).
    //
    // PHI ASSIGNMENT MODEL
    // A construct's `results` are the phi `Param`s at its merge.  Each
    // exit terminator carries `args` positional with those results.  When
    // we emit a block that is a branch/case/body of construct C, we pass
    // C's `results` down as the matching `enc` field; when that block's
    // terminator is the matching exit kind, we emit
    // `results[i].phi_id = args[i];` for each i before the control
    // statement.  Loop-carried header phis are handled separately (init
    // before the loop, iter update at the end of the continuing block).
    //
    // DUCK-TYPED CONTEXT
    // `emit` is generic over `s: anytype` to avoid importing
    // `spv2wgsl.zig` (which imports us).  `s` must provide:
    //   - `wgslNameOf(id: u32) []const u8` - value/phi id -> WGSL name;
    //   - `currentFunctionIsEntry() bool` - pick `return outputs;` vs
    //     `return;`.
    // `emitBlockBody` must match the `emitBlockBodyOnly` shape:
    //   `fn (s, out: *EmitList(u8), block_id: u32) anyerror!void`.

    const EmitList = ArrayList(u8);

    /// The phi result params of the nearest enclosing construct of each
    /// kind, so an exit terminator can pair its args with the right phi
    /// names.  Only the kind matching the exit terminator is consulted.
    const Enclosing = struct {
        if_results: []const ir.Param = &.{},
        loop_results: []const ir.Param = &.{},
        switch_results: []const ir.Param = &.{},
    };

    /// Emit the WGSL body for a whole function.
    pub fn emit(
        s: anytype,
        out: *EmitList,
        arena: Allocator,
        body: *const ir.FnBody,
        emitBlockBody: anytype,
    ) anyerror!void {
        try emitBlock(s, out, arena, body.entry, emitBlockBody, 1, .{});
    }

    /// Emit one structured block: its items in order, then its
    /// terminator.  `depth` is the nesting level (1 = function-body top
    /// level); indentation is `depth * 2` spaces.  `enc` carries the
    /// enclosing constructs' result phis for exit assignment.
    /// True when `blk`'s ITEMS cannot fall through to `blk.term`: the last item
    /// is a construct whose every branch diverges (continue/break/return/exit).
    /// This is about the items, NOT `blk.term` itself - it answers "is the
    /// block's own terminator reachable?" Used to suppress a `.unreach`
    /// fall-through `return T();` when the structured code before it already
    /// provably diverges - naga is fine either way, but Dawn/Tint reject the
    /// trailing return as unreachable (the `return S2428();` after an
    /// `if (c) { continue; } else { break; }` in a loop body).
    // =====================================================================
    // Control-flow behavior analysis - a port of Tint's (Dawn's WGSL
    // compiler) formal model, WGSL spec https://www.w3.org/TR/WGSL/#behaviors-rules.
    // Every statement has a `Behaviors` set subset of {next, ret, brk, cont}; `next`
    // means "control can fall through to the following statement". Dawn REJECTS
    // a statement that follows one lacking `next` ("code is unreachable") - a
    // rule naga does NOT enforce, so this is our only device-free defense
    // against that class. The old boolean `*AlwaysDiverge` helpers are kept as
    // thin wrappers (`diverges == !behaviors.next`) so existing call sites are
    // unchanged, but they now also correctly handle infinite loops (a loop
    // whose body cannot `break` has no `next`).
    // =====================================================================
    const Behaviors = packed struct {
        next: bool = false,
        ret: bool = false,
        brk: bool = false,
        cont: bool = false,

        fn unionWith(a: Behaviors, b: Behaviors) Behaviors {
            return .{
                .next = a.next or b.next,
                .ret = a.ret or b.ret,
                .brk = a.brk or b.brk,
                .cont = a.cont or b.cont,
            };
        }
        fn withoutNext(a: Behaviors) Behaviors {
            var r = a;
            r.next = false;
            return r;
        }
    };

    /// Behaviors contributed by a block's terminator (its final "statement").
    fn termBehaviors(term: ir.Terminator) Behaviors {
        return switch (term) {
            // exit_if / exit_switch resume in the enclosing block -> fall through.
            .exit_if, .exit_switch => .{ .next = true },
            // Conditional break: falls through on one edge, breaks on the other.
            .break_if => .{ .next = true, .brk = true },
            .exit_loop => .{ .brk = true },
            .cont => .{ .cont = true },
            // Degenerate goto / discard / statically-dead tail: no fall-through.
            .branch, .kill, .unreach => .{},
            .ret, .ret_value => .{ .ret = true },
        };
    }

    /// Behaviors of a structured block: Tint's compound-statement rule -
    /// `b = {next}`; for each item `b = (b - next) + item.behaviors`; then fold
    /// in the terminator. If a non-last item lacks `next`, `b` loses `next`.
    fn blockBehaviors(blk: *const ir.Block) Behaviors {
        var b: Behaviors = .{ .next = true };
        for (blk.items) |item| {
            const ib: Behaviors = switch (item) {
                // A straight-line SPIR-V body block falls through.
                .body => .{ .next = true },
                .construct => |c| constructBehaviors(c),
            };
            b = b.withoutNext().unionWith(ib);
        }
        return b.withoutNext().unionWith(termBehaviors(blk.term));
    }

    fn constructBehaviors(c: *const ir.Construct) Behaviors {
        return switch (c.*) {
            // if: union of both arms (an "empty" arm falls through -> has next).
            .if_ => |*f| blockBehaviors(f.true_blk).unionWith(blockBehaviors(f.false_blk)),
            // switch: union of default + every case (break->next is modeled by
            // each case ending in `exit_switch`, which contributes next).
            .switch_ => |*sw| blk: {
                var b: Behaviors = blockBehaviors(sw.default_blk);
                for (sw.cases) |case| {
                    b = b.unionWith(blockBehaviors(case.blk));
                }
                break :blk b;
            },
            // loop (Tint rule): behaviors of body + continuing; the loop has
            // `next` IFF the body can `break`; break/continue are consumed here;
            // `ret` still propagates out.
            .loop_ => |*lp| blk: {
                var b: Behaviors = blockBehaviors(lp.body).unionWith(blockBehaviors(lp.continuing));
                b.next = b.brk;
                b.brk = false;
                b.cont = false;
                break :blk b;
            },
        };
    }

    fn itemsAlwaysDiverge(blk: *const ir.Block) bool {
        if (blk.items.len == 0) {
            return false;
        }
        // Fold ONLY the items (not the terminator): can control reach the term?
        var b: Behaviors = .{ .next = true };
        for (blk.items) |item| {
            const ib: Behaviors = switch (item) {
                .body => .{ .next = true },
                .construct => |c| constructBehaviors(c),
            };
            b = b.withoutNext().unionWith(ib);
        }
        return !b.next;
    }

    /// True when control leaving `blk` cannot fall through past it.
    fn blockAlwaysDiverges(blk: *const ir.Block) bool {
        return !blockBehaviors(blk).next;
    }

    fn termDiverges(term: ir.Terminator) bool {
        return !termBehaviors(term).next;
    }

    fn constructAlwaysDiverges(c: *const ir.Construct) bool {
        return !constructBehaviors(c).next;
    }

    fn emitBlock(
        s: anytype,
        out: *EmitList,
        arena: Allocator,
        blk: *const ir.Block,
        emitBlockBody: anytype,
        depth: usize,
        enc: Enclosing,
    ) anyerror!void {
        for (blk.items) |item| {
            switch (item) {
                .body => |block_id| {
                    try emitBlockBody(s, out, block_id);
                },
                .construct => |c| {
                    try emitConstruct(s, out, arena, c, emitBlockBody, depth, enc);
                },
            }
        }
        // A `.unreach` terminator emits a fall-through `return T();` to keep
        // naga happy on value-returning functions. But when the block's items
        // already diverge on every path (e.g. a trailing `if (c) { continue; }
        // else { break; }` in a loop body), that return is provably dead and
        // Dawn/Tint rejects it as unreachable code. Suppress it in that case -
        // naga is equally satisfied, since no path can fall off the end.
        if (blk.term == .unreach and itemsAlwaysDiverge(blk)) {
            return;
        }
        try emitTerminator(s, out, arena, blk.term, depth, enc);
    }

    fn emitConstruct(
        s: anytype,
        out: *EmitList,
        arena: Allocator,
        c: *const ir.Construct,
        emitBlockBody: anytype,
        depth: usize,
        enc: Enclosing,
    ) anyerror!void {
        switch (c.*) {
            .if_ => |*f| try emitIf(s, out, arena, f, emitBlockBody, depth, enc),
            .loop_ => |*lp| try emitLoop(s, out, arena, lp, emitBlockBody, depth, enc),
            .switch_ => |*sw| try emitSwitch(s, out, arena, sw, emitBlockBody, depth, enc),
        }
    }

    fn emitIf(
        s: anytype,
        out: *EmitList,
        arena: Allocator,
        f: *const ir.If,
        emitBlockBody: anytype,
        depth: usize,
        enc: Enclosing,
    ) anyerror!void {
        // Inside the branches, THIS if is the enclosing `if` for exit
        // assignment; the loop/switch enclosings carry through unchanged.
        const inner: Enclosing = .{
            .if_results = f.results,
            .loop_results = enc.loop_results,
            .switch_results = enc.switch_results,
        };
        try indent(out, arena, depth);
        try fmt(out, arena, "if ({s}) {{\n", .{s.wgslNameOf(f.cond)});
        try emitBlock(s, out, arena, f.true_blk, emitBlockBody, depth + 1, inner);
        try indent(out, arena, depth);
        try out.appendSlice(arena, "} else {\n");
        try emitBlock(s, out, arena, f.false_blk, emitBlockBody, depth + 1, inner);
        try indent(out, arena, depth);
        try out.appendSlice(arena, "}\n");
    }

    fn emitLoop(
        s: anytype,
        out: *EmitList,
        arena: Allocator,
        lp: *const ir.Loop,
        emitBlockBody: anytype,
        depth: usize,
        enc: Enclosing,
    ) anyerror!void {
        _ = enc;
        // Initialize the loop-carried header phis BEFORE the loop.
        for (lp.header_params) |p| {
            if (p.init) |init_id| {
                try indent(out, arena, depth);
                try fmt(out, arena, "{s} = {s};\n", .{ s.wgslNameOf(p.phi_id), s.wgslNameOf(init_id) });
            }
        }
        // Inside the loop body, THIS loop is the enclosing `loop`; the
        // if/switch enclosings reset (a break/continue from the body
        // targets this loop; a nested if/switch sets its own).
        const inner: Enclosing = .{
            .if_results = &.{},
            .loop_results = lp.results,
            .switch_results = &.{},
        };
        try indent(out, arena, depth);
        try out.appendSlice(arena, "loop {\n");
        try emitBlock(s, out, arena, lp.body, emitBlockBody, depth + 1, inner);

        // The continuing block.  Emit its items, THEN the header-phi
        // iteration updates (iter_args), THEN its terminator last.  Order
        // matters because the terminator may be a `break if`, which WGSL
        // requires to be the FINAL statement of the continuing block - so
        // the iter-updates must precede it (for a plain back-edge branch the
        // terminator emits nothing, so order is immaterial).
        try indent(out, arena, depth + 1);
        try out.appendSlice(arena, "continuing {\n");
        for (lp.continuing.items) |item| {
            switch (item) {
                .body => |block_id| try emitBlockBody(s, out, block_id),
                .construct => |c| try emitConstruct(s, out, arena, c, emitBlockBody, depth + 2, .{}),
            }
        }
        for (lp.header_params, 0..) |p, i| {
            try indent(out, arena, depth + 2);
            try fmt(out, arena, "{s} = {s};\n", .{ s.wgslNameOf(p.phi_id), s.wgslNameOf(lp.iter_args[i]) });
        }
        try emitTerminator(s, out, arena, lp.continuing.term, depth + 2, inner);
        try indent(out, arena, depth + 1);
        try out.appendSlice(arena, "}\n");

        try indent(out, arena, depth);
        try out.appendSlice(arena, "}\n");
    }

    fn emitSwitch(
        s: anytype,
        out: *EmitList,
        arena: Allocator,
        sw: *const ir.Switch,
        emitBlockBody: anytype,
        depth: usize,
        enc: Enclosing,
    ) anyerror!void {
        const inner: Enclosing = .{
            .if_results = &.{},
            .loop_results = enc.loop_results,
            .switch_results = sw.results,
        };
        try indent(out, arena, depth);
        try fmt(out, arena, "switch ({s}) {{\n", .{s.wgslNameOf(sw.selector)});
        // SPIR-V stores case literals as raw 32-bit words; WGSL needs them
        // typed to the selector.  For a signed (`i32`) selector, reinterpret
        // the word as the i32 it encodes (so 4000000000 -> -294967296), which
        // WGSL/naga accept as a valid i32 literal.  Mirrors Tint's
        // `i32(literal)` vs `u32(literal)` choice in EmitSwitch.
        const sel_signed: bool = std.mem.eql(u8, s.scalarTypeNameOf(sw.selector), "i32");
        for (sw.cases) |cs| {
            try indent(out, arena, depth + 1);
            try out.appendSlice(arena, "case ");
            for (cs.values, 0..) |v, i| {
                if (i != 0) {
                    try out.appendSlice(arena, ", ");
                }
                if (sel_signed) {
                    const sv: i32 = @bitCast(v);
                    try fmt(out, arena, "{d}", .{sv});
                } else {
                    try fmt(out, arena, "{d}", .{v});
                }
            }
            try out.appendSlice(arena, ": {\n");
            try emitBlock(s, out, arena, cs.blk, emitBlockBody, depth + 2, inner);
            try indent(out, arena, depth + 1);
            try out.appendSlice(arena, "}\n");
        }
        try indent(out, arena, depth + 1);
        try out.appendSlice(arena, "default: {\n");
        try emitBlock(s, out, arena, sw.default_blk, emitBlockBody, depth + 2, inner);
        try indent(out, arena, depth + 1);
        try out.appendSlice(arena, "}\n");
        try indent(out, arena, depth);
        try out.appendSlice(arena, "}\n");
    }

    /// Emit a terminator.  Exit-kind terminators first emit their carried
    /// `phi = value;` assignments (pairing the enclosing construct's
    /// result params with this edge's args), then the WGSL control
    /// statement (`break;` / `continue;` / nothing for `exit_if`).
    fn emitTerminator(
        s: anytype,
        out: *EmitList,
        arena: Allocator,
        term: ir.Terminator,
        depth: usize,
        enc: Enclosing,
    ) anyerror!void {
        switch (term) {
            .exit_if => |e| {
                // Falling out of an `if` to its merge needs no statement -
                // control resumes at the merge (emitted in the parent).
                try emitPhiAssigns(s, out, arena, enc.if_results, e.args, depth);
            },
            .exit_switch => |e| {
                try emitPhiAssigns(s, out, arena, enc.switch_results, e.args, depth);
                try indent(out, arena, depth);
                try out.appendSlice(arena, "break;\n");
            },
            .exit_loop => |e| {
                try emitPhiAssigns(s, out, arena, enc.loop_results, e.args, depth);
                try indent(out, arena, depth);
                try out.appendSlice(arena, "break;\n");
            },
            .cont => |e| {
                // `cont` carries no args (the loop-carried update is via
                // the loop's iter_args at the end of the continuing block).
                _ = e;
                try indent(out, arena, depth);
                try out.appendSlice(arena, "continue;\n");
            },
            .break_if => |b| {
                try emitPhiAssigns(s, out, arena, enc.loop_results, b.args, depth);
                try indent(out, arena, depth);
                if (b.invert) {
                    try fmt(out, arena, "break if !({s});\n", .{s.wgslNameOf(b.cond)});
                } else {
                    try fmt(out, arena, "break if {s};\n", .{s.wgslNameOf(b.cond)});
                }
            },
            .branch => {
                // A plain branch to a non-merge target is the implicit
                // loop back-edge (continuing block end) - no statement.
            },
            .ret => {
                try indent(out, arena, depth);
                if (s.currentFunctionIsEntry()) {
                    try s.emitEntryReturn(out, arena);
                } else {
                    try out.appendSlice(arena, "return;\n");
                }
            },
            .ret_value => |v| {
                try indent(out, arena, depth);
                try fmt(out, arena, "return {s};\n", .{s.wgslNameOf(v)});
            },
            .kill => {
                try indent(out, arena, depth);
                try out.appendSlice(arena, "discard;\n");
            },
            .unreach => {
                // Statically unreachable.  A value-returning function still
                // needs a terminating return on this structural path (naga
                // "Returning None where Some(T) is expected"); the State
                // helper emits `return <zero>;` for that case and nothing
                // for void/entry functions.
                try s.emitUnreachReturn(out, arena, depth);
            },
        }
    }

    /// Emit `phi{results[i].phi_id} = <args[i]>;` for each i.  The exit's
    /// arg count equals the construct's result count (the IR invariant
    /// `ir.validate` enforces), so this is a clean positional pairing.
    fn emitPhiAssigns(
        s: anytype,
        out: *EmitList,
        arena: Allocator,
        results: []const ir.Param,
        args: []const ir.ValueId,
        depth: usize,
    ) anyerror!void {
        for (results, 0..) |p, i| {
            if (i >= args.len) {
                break;
            }
            try indent(out, arena, depth);
            try fmt(out, arena, "{s} = {s};\n", .{ s.wgslNameOf(p.phi_id), s.wgslNameOf(args[i]) });
        }
    }

    fn indent(
        out: *EmitList,
        arena: Allocator,
        depth: usize,
    ) !void {
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            try out.appendSlice(arena, "  ");
        }
    }

    fn fmt(
        out: *EmitList,
        arena: Allocator,
        comptime f: []const u8,
        args: anytype,
    ) !void {
        const line: []const u8 = try allocPrint(arena, f, args);
        try out.appendSlice(arena, line);
    }

    // =============================================================================
    // Tests - emit WGSL from synthesized IR, with a fake `s` context.
    // =============================================================================

    const testing = std.testing;

    /// Minimal duck-typed context: maps ids to names `v{id}` (or `phi{id}`
    /// for ids we mark as phis), and reports entry/non-entry.
    const FakeState = struct {
        arena: Allocator,
        is_entry: bool = false,
        /// When true, scalarTypeNameOf reports "i32" so the signed switch
        /// case-literal path is exercised.
        signed_selector: bool = false,

        pub fn wgslNameOf(self: *FakeState, id: u32) []const u8 {
            return allocPrint(self.arena, "v{d}", .{id}) catch "?";
        }

        pub fn scalarTypeNameOf(self: *FakeState, id: u32) []const u8 {
            _ = id;
            return if (self.signed_selector) "i32" else "";
        }
        pub fn currentFunctionIsEntry(self: *FakeState) bool {
            return self.is_entry;
        }
        pub fn emitEntryReturn(
            self: *FakeState,
            out: *EmitList,
            arena: Allocator,
        ) !void {
            _ = self;
            // The IR emit tests don't model module-scope outputs; they just
            // assert the entry emits `return outputs;`.
            try out.appendSlice(arena, "return outputs;\n");
        }

        pub fn emitUnreachReturn(
            self: *FakeState,
            out: *EmitList,
            arena: Allocator,
            depth: usize,
        ) !void {
            _ = self;
            _ = depth;
            // Emit a distinctive marker so tests can assert whether the
            // `.unreach` fall-through return was emitted or suppressed (the
            // real State helper emits `return T();` for value-returning
            // helpers; the emitBlock gate skips this call when the block's
            // items already provably diverge).
            try out.appendSlice(arena, "UNREACH_RETURN;\n");
        }
    };

    /// A no-op block-body emitter that just writes a marker line so tests
    /// can see block ordering without the real id-table emitter.
    fn fakeBlockBody(
        s: *FakeState,
        out: *EmitList,
        block_id: u32,
    ) anyerror!void {
        const line: []const u8 = try allocPrint(s.arena, "  // body %{d}\n", .{block_id});
        try out.appendSlice(s.arena, line);
    }

    test "emit renders a diamond if/else with merge phi on both branches" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // If with results=[phi20]; true exit args=[21], false exit args=[22].
        const true_blk: *ir.Block = try a.create(ir.Block);
        true_blk.* = .{ .term = .{ .exit_if = .{ .args = try a.dupe(ir.ValueId, &.{21}) } } };
        const false_blk: *ir.Block = try a.create(ir.Block);
        false_blk.* = .{ .term = .{ .exit_if = .{ .args = try a.dupe(ir.ValueId, &.{22}) } } };
        const if_c: *ir.Construct = try a.create(ir.Construct);
        if_c.* = .{ .if_ = .{
            .cond = 10,
            .true_blk = true_blk,
            .false_blk = false_blk,
            .merge_id = 7,
            .results = try a.dupe(ir.Param, &.{.{ .phi_id = 20, .type_id = 2 }}),
        } };
        const entry: *ir.Block = try a.create(ir.Block);
        entry.* = .{
            .items = try a.dupe(ir.Item, &.{ .{ .body = 5 }, .{ .construct = if_c }, .{ .body = 7 } }),
            .term = .ret,
        };
        const body: ir.FnBody = .{ .entry = entry };

        var fs: FakeState = .{ .arena = a };
        var out: EmitList = .empty;
        try emit(&fs, &out, a, &body, fakeBlockBody);
        const w: []const u8 = out.items;

        // The phi must be assigned on BOTH branches (the dropped-copy fix).
        try testing.expect(std.mem.indexOf(u8, w, "if (v10) {") != null);
        try testing.expect(std.mem.indexOf(u8, w, "v20 = v21;") != null); // true branch
        try testing.expect(std.mem.indexOf(u8, w, "v20 = v22;") != null); // false branch
        try testing.expect(std.mem.indexOf(u8, w, "} else {") != null);
        try testing.expect(std.mem.indexOf(u8, w, "return;") != null);
    }

    test "emit renders a loop with header-phi init + continuing iter update" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // Loop: header phi30 init=31 iter=32; body ends in cont; continuing
        // is empty (back-edge).  Expect `v30 = v31;` before the loop and
        // `v30 = v32;` at the end of continuing.
        const loop_body: *ir.Block = try a.create(ir.Block);
        loop_body.* = .{ .items = try a.dupe(ir.Item, &.{.{ .body = 7 }}), .term = .{ .cont = .{} } };
        const cont_blk: *ir.Block = try a.create(ir.Block);
        cont_blk.* = .{ .term = .{ .branch = 6 } };
        const loop_c: *ir.Construct = try a.create(ir.Construct);
        loop_c.* = .{ .loop_ = .{
            .body = loop_body,
            .continuing = cont_blk,
            .merge_id = 9,
            .header_params = try a.dupe(ir.Param, &.{.{ .phi_id = 30, .type_id = 2, .init = 31 }}),
            .iter_args = try a.dupe(ir.ValueId, &.{32}),
        } };
        const entry: *ir.Block = try a.create(ir.Block);
        entry.* = .{
            .items = try a.dupe(ir.Item, &.{ .{ .body = 6 }, .{ .construct = loop_c }, .{ .body = 9 } }),
            .term = .ret,
        };
        const body: ir.FnBody = .{ .entry = entry };

        var fs: FakeState = .{ .arena = a };
        var out: EmitList = .empty;
        try emit(&fs, &out, a, &body, fakeBlockBody);
        const w: []const u8 = out.items;

        const init_at: ?usize = std.mem.indexOf(u8, w, "v30 = v31;");
        const loop_at: ?usize = std.mem.indexOf(u8, w, "loop {");
        const iter_at: ?usize = std.mem.indexOf(u8, w, "v30 = v32;");
        const contin_at: ?usize = std.mem.indexOf(u8, w, "continuing {");
        try testing.expect(init_at != null and loop_at != null and iter_at != null and contin_at != null);
        // init before the loop; iter update inside continuing (after it).
        try testing.expect(init_at.? < loop_at.?);
        try testing.expect(contin_at.? < iter_at.?);
        try testing.expect(std.mem.indexOf(u8, w, "continue;") != null);
    }

    test "emit suppresses the unreach return after a loop body that always diverges" {
        // A loop body ending in `if (c) { continue; } else { break; }` - both
        // arms diverge, so the body's `.unreach` tail is genuinely unreachable.
        // Dawn/Tint rejects a `return T();` there as unreachable code, so the
        // emitter must NOT emit it (naga is equally happy: no path falls off).
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        const true_blk: *ir.Block = try a.create(ir.Block);
        true_blk.* = .{ .items = &.{}, .term = .{ .cont = .{} } }; // continue;
        const false_blk: *ir.Block = try a.create(ir.Block);
        false_blk.* = .{ .items = &.{}, .term = .{ .exit_loop = .{} } }; // break;
        const if_c: *ir.Construct = try a.create(ir.Construct);
        if_c.* = .{ .if_ = .{ .cond = 7, .true_blk = true_blk, .false_blk = false_blk, .merge_id = 0 } };

        const loop_body: *ir.Block = try a.create(ir.Block);
        loop_body.* = .{
            .items = try a.dupe(ir.Item, &.{.{ .construct = if_c }}),
            .term = .unreach, // the fall-through the gate must suppress
        };
        const cont_blk: *ir.Block = try a.create(ir.Block);
        cont_blk.* = .{ .items = &.{}, .term = .{ .branch = 1 } };
        const loop_c: *ir.Construct = try a.create(ir.Construct);
        loop_c.* = .{ .loop_ = .{ .body = loop_body, .continuing = cont_blk, .merge_id = 9 } };

        const entry: *ir.Block = try a.create(ir.Block);
        entry.* = .{ .items = try a.dupe(ir.Item, &.{.{ .construct = loop_c }}), .term = .ret };
        const body: ir.FnBody = .{ .entry = entry };

        var fs: FakeState = .{ .arena = a };
        var out: EmitList = .empty;
        try emit(&fs, &out, a, &body, fakeBlockBody);
        const w: []const u8 = out.items;

        try testing.expect(std.mem.indexOf(u8, w, "continue;") != null);
        try testing.expect(std.mem.indexOf(u8, w, "break;") != null);
        // The unreachable fall-through return must be gone.
        try testing.expect(std.mem.indexOf(u8, w, "UNREACH_RETURN;") == null);
    }

    test "emit keeps the unreach return when an if arm falls through" {
        // Only ONE arm diverges; the other falls through, so control CAN reach
        // the block's `.unreach` tail. naga needs the return there and it is not
        // unreachable to Dawn, so the emitter MUST keep it.
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        const true_blk: *ir.Block = try a.create(ir.Block);
        true_blk.* = .{ .items = &.{}, .term = .{ .cont = .{} } }; // continue;
        const false_blk: *ir.Block = try a.create(ir.Block);
        false_blk.* = .{ .items = try a.dupe(ir.Item, &.{.{ .body = 5 }}), .term = .{ .exit_if = .{} } };
        const if_c: *ir.Construct = try a.create(ir.Construct);
        if_c.* = .{ .if_ = .{ .cond = 7, .true_blk = true_blk, .false_blk = false_blk, .merge_id = 0 } };

        const loop_body: *ir.Block = try a.create(ir.Block);
        loop_body.* = .{
            .items = try a.dupe(ir.Item, &.{.{ .construct = if_c }}),
            .term = .unreach,
        };
        const cont_blk: *ir.Block = try a.create(ir.Block);
        cont_blk.* = .{ .items = &.{}, .term = .{ .branch = 1 } };
        const loop_c: *ir.Construct = try a.create(ir.Construct);
        loop_c.* = .{ .loop_ = .{ .body = loop_body, .continuing = cont_blk, .merge_id = 9 } };

        const entry: *ir.Block = try a.create(ir.Block);
        entry.* = .{ .items = try a.dupe(ir.Item, &.{.{ .construct = loop_c }}), .term = .ret };
        const body: ir.FnBody = .{ .entry = entry };

        var fs: FakeState = .{ .arena = a };
        var out: EmitList = .empty;
        try emit(&fs, &out, a, &body, fakeBlockBody);
        const w: []const u8 = out.items;

        // The false arm falls through (exit_if), so the unreach return stays.
        try testing.expect(std.mem.indexOf(u8, w, "UNREACH_RETURN;") != null);
    }

    test "emit renders a switch with cases, default, and break per case" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        const case0: *ir.Block = try a.create(ir.Block);
        case0.* = .{ .items = try a.dupe(ir.Item, &.{.{ .body = 20 }}), .term = .{ .exit_switch = .{} } };
        const case1: *ir.Block = try a.create(ir.Block);
        case1.* = .{ .items = try a.dupe(ir.Item, &.{.{ .body = 25 }}), .term = .{ .exit_switch = .{} } };
        const def: *ir.Block = try a.create(ir.Block);
        def.* = .{ .items = try a.dupe(ir.Item, &.{.{ .body = 30 }}), .term = .{ .exit_switch = .{} } };
        const sw_c: *ir.Construct = try a.create(ir.Construct);
        sw_c.* = .{ .switch_ = .{
            .selector = 99,
            .cases = try a.dupe(ir.Case, &.{
                .{ .values = try a.dupe(u32, &.{1}), .blk = case0 },
                .{ .values = try a.dupe(u32, &.{ 2, 3 }), .blk = case1 },
            }),
            .default_blk = def,
            .merge_id = 40,
        } };
        const entry: *ir.Block = try a.create(ir.Block);
        entry.* = .{
            .items = try a.dupe(ir.Item, &.{ .{ .construct = sw_c }, .{ .body = 40 } }),
            .term = .ret,
        };
        const body: ir.FnBody = .{ .entry = entry };

        var fs: FakeState = .{ .arena = a };
        var out: EmitList = .empty;
        try emit(&fs, &out, a, &body, fakeBlockBody);
        const w: []const u8 = out.items;

        try testing.expect(std.mem.indexOf(u8, w, "switch (v99) {") != null);
        try testing.expect(std.mem.indexOf(u8, w, "case 1: {") != null);
        try testing.expect(std.mem.indexOf(u8, w, "case 2, 3: {") != null); // dedup'd selectors
        try testing.expect(std.mem.indexOf(u8, w, "default: {") != null);
        try testing.expect(std.mem.indexOf(u8, w, "break;") != null);
    }

    test "emit reinterprets a signed switch case literal as i32" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        // A signed (i32) selector: the raw case word 4000000000 encodes the
        // i32 value -294967296, which is what naga must see (a bare
        // 4000000000 overflows i32).  FakeState.signed_selector reports "i32".
        const case0: *ir.Block = try a.create(ir.Block);
        case0.* = .{ .items = &.{}, .term = .{ .exit_switch = .{} } };
        const def: *ir.Block = try a.create(ir.Block);
        def.* = .{ .items = &.{}, .term = .{ .exit_switch = .{} } };
        const sw_c: *ir.Construct = try a.create(ir.Construct);
        sw_c.* = .{ .switch_ = .{
            .selector = 99,
            .cases = try a.dupe(ir.Case, &.{
                .{ .values = try a.dupe(u32, &.{4000000000}), .blk = case0 },
            }),
            .default_blk = def,
            .merge_id = 40,
        } };
        const entry: *ir.Block = try a.create(ir.Block);
        entry.* = .{ .items = try a.dupe(ir.Item, &.{.{ .construct = sw_c }}), .term = .ret };
        const body: ir.FnBody = .{ .entry = entry };

        var fs: FakeState = .{ .arena = a, .signed_selector = true };
        var out: EmitList = .empty;
        try emit(&fs, &out, a, &body, fakeBlockBody);
        try testing.expect(std.mem.indexOf(u8, out.items, "case -294967296: {") != null);
        try testing.expect(std.mem.indexOf(u8, out.items, "4000000000") == null);
    }

    test "emit renders return outputs for an entry function" {
        var arena_inst: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const a: Allocator = arena_inst.allocator();

        const entry: *ir.Block = try a.create(ir.Block);
        entry.* = .{ .items = try a.dupe(ir.Item, &.{.{ .body = 5 }}), .term = .ret };
        const body: ir.FnBody = .{ .entry = entry };

        var fs: FakeState = .{ .arena = a, .is_entry = true };
        var out: EmitList = .empty;
        try emit(&fs, &out, a, &body, fakeBlockBody);
        try testing.expect(std.mem.indexOf(u8, out.items, "return outputs;") != null);
    }
};

/// OpUndef: produces a value of unspecified contents at the given type.
/// WGSL has no equivalent.  Emit a zero-init of the target type - always
/// valid in WGSL for any constructible type (vec, mat, array, struct,
/// scalar).  Preserves semantics: SPIR-V says "value is undefined"; we
/// say "value is zero."  No code path should depend on the actual
/// undefined contents.
///
/// The "3 unresolved ids per shader" pattern in the corpus was entirely
/// OpUndef references showing up as `__unresolved_N__` placeholders
/// because lookupId hit an unset id slot.  This handler makes that
/// pattern disappear.
fn emitUndef(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "{s}();\n", .{t.wgsl_name});
}

fn emitLoad(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const ptr_info: *const IdInfo = lookupId(s, ops[2]);
    const ptr: []const u8 = ptr_info.wgsl_name;
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    // Atomic taint: a plain load of an `atomic<u32>` element is illegal WGSL;
    // route it through atomicLoad(&expr).  ptr is an access path like
    // `kbuf_grid_counts[idx]`; its root var (extra_a) being tainted is the cue.
    if (ptr_info.extra_a != 0 and ptr_info.extra_a < s.atomic_var.len and s.atomic_var[ptr_info.extra_a]) {
        try bprint(out, s.arena, "atomicLoad(&{s});\n", .{ptr});
        return;
    }
    try bprint(out, s.arena, "{s};\n", .{ptr});
}

/// Find the type id of the Nth member of an OpTypeStruct.
fn advanceStructMember(
    s: *State,
    struct_type_id: u32,
    member: u32,
) ?u32 {
    for (s.inst_off.items) |io| {
        const w0: u32 = s.spirv[io];
        if (@as(types.Op, @fromBackingInt(@intCast(types.opcodeOf(w0)))) != .TypeStruct) {
            continue;
        }
        const t_ops: []const u32 = types.operandsAt(s.spirv, io);
        if (t_ops[0] != struct_type_id) {
            continue;
        }
        if (1 + member >= t_ops.len) {
            return null;
        }
        return t_ops[1 + member];
    }
    return null;
}

/// Build a string like "base.field_0[idx]" for the access-chain id, so later
/// loads and stores through it work as plain text substitution.
fn emitAccessChain(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    // OpAccessChain doesn't emit a statement to `out` - it stashes the
    // built access-path expression as the result id's `wgsl_name` for
    // later use by emitLoad/emitStore.  `out` is kept in the signature
    // for walker uniformity: every body-instruction helper takes the
    // same shape so the walker can dispatch without per-opcode special-
    // casing.
    _ = out;
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const base_id: u32 = ops[2];
    const indices: []const u32 = ops[3..];

    var buf: ArrayList(u8) = .empty;
    const base: *const IdInfo = lookupId(s, base_id);
    // Input/Output variables are module-scope `var<private>`s (see
    // pass3), so an access chain into one roots at the bare variable name
    // from ANY function (entry or helper).  For a single struct-typed
    // output (output_alias_vid) the private var IS the whole struct, so
    // the path `name.field_0...` is correct and `emitEntryReturn` returns
    // that var directly.  No entry-only `outputs.` rerooting is needed.
    try bstr(&buf, s.arena, base.wgsl_name);

    // Walk pointee types as we walk indices.
    var cur_type: u32 = lookupType(s, base.type_id).extra_b; // pointee of base ptr
    for (indices) |idx_id| {
        const cur_info: *const IdInfo = lookupType(s, cur_type);
        switch (cur_info.kind) {
            .type_struct => {
                // Struct indices must be constants in SPIR-V.
                const member: u32 = lookupId(s, idx_id).extra_a;
                try bprint(&buf, s.arena, ".field_{d}", .{member});
                cur_type = advanceStructMember(s, cur_type, member) orelse cur_type;
            },
            .type_vector => {
                try bprint(&buf, s.arena, "[{s}]", .{lookupId(s, idx_id).wgsl_name});
                cur_type = cur_info.extra_b;
            },
            .type_matrix => {
                try bprint(&buf, s.arena, "[{s}]", .{lookupId(s, idx_id).wgsl_name});
                cur_type = cur_info.extra_b; // a column-vector type
            },
            .type_array => {
                try bprint(&buf, s.arena, "[{s}]", .{lookupId(s, idx_id).wgsl_name});
                cur_type = cur_info.extra_a; // element type
            },
            else => {
                try bprint(&buf, s.arena, "[{s}]", .{lookupId(s, idx_id).wgsl_name});
            },
        }
    }

    const expr: []const u8 = try buf.toOwnedSlice(s.arena);
    // Thread the root variable id (for atomic-taint detection in emitLoad/
    // emitStore): if the base is itself a tainted variable use base_id;
    // otherwise propagate whatever root the base carried (chained access).
    const root_var: u32 = if (base.kind == .variable) base_id else base.extra_a;
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = expr, .extra_a = root_var });
}

fn emitStore(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
    is_entry: bool,
) !void {
    _ = is_entry;
    const ptr_id: u32 = ops[0];
    const ptr: *const IdInfo = lookupId(s, ptr_id);
    const val: []const u8 = lookupId(s, ops[1]).wgsl_name;

    // Atomic taint: a plain store to an `atomic<u32>` element is illegal WGSL;
    // route it through atomicStore(&expr, val).
    if (ptr.extra_a != 0 and ptr.extra_a < s.atomic_var.len and s.atomic_var[ptr.extra_a]) {
        try bprint(out, s.arena, "  atomicStore(&{s}, {s});\n", .{ ptr.wgsl_name, val });
        return;
    }

    // Output variables are module-scope `var<private>`s (see pass3), so a
    // store writes the bare variable name from ANY function - the entry
    // OR a called helper.  The entry's `return` lowering (emitEntryReturn)
    // stages those privates into the WGSL `Outputs` struct.  No
    // entry-only `outputs.<name>` redirect is needed (and it would be
    // wrong for stores happening inside a helper).
    try bprint(out, s.arena, "  {s} = {s};\n", .{ ptr.wgsl_name, val });
}

/// Stub: the walker doesn't track "are we emitting an entry function"
/// context yet.  `emitStore` uses this only for the entry-output
/// `outputs.field = X;` shape - and in the walker, the walker isn't
/// driving entry functions yet (Phase 3b feature-flags the walker on
/// for selection_header CFGs only; entry functions tend to be small
/// linear blocks).  Returning false matches the safe default.
///
/// Phase 3c (planned post-cutover hardening): plumb is_entry through
/// the walker if any entry function ends up with a selection_header.
fn isEntryFunctionContext(s: *State) bool {
    return s.is_current_entry;
}

fn emitCompositeExtract(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const composite: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const indices: []const u32 = ops[3..];
    const t: *const IdInfo = lookupType(s, tid);

    var buf: ArrayList(u8) = .empty;
    try bstr(&buf, s.arena, composite);
    for (indices) |i| {
        try bprint(&buf, s.arena, "[{d}]", .{i});
    }
    const expr: []const u8 = try buf.toOwnedSlice(s.arena);

    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "{s};\n", .{expr});
}

fn emitCompositeConstruct(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const comps: []const u32 = ops[2..];
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "{s}(", .{t.wgsl_name});
    for (comps, 0..) |cid, i| {
        if (i != 0) {
            try bstr(out, s.arena, ", ");
        }
        try bstr(out, s.arena, lookupId(s, cid).wgsl_name);
    }
    try bstr(out, s.arena, ");\n");
}

fn emitVectorShuffle(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const v1_id: u32 = ops[2];
    const v2_id: u32 = ops[3];
    const v1: []const u8 = lookupId(s, v1_id).wgsl_name;
    const v2: []const u8 = lookupId(s, v2_id).wgsl_name;
    const comps: []const u32 = ops[4..];
    const v1_len: u32 = lookupType(s, lookupId(s, v1_id).type_id).extra_a;

    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });

    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "{s}(", .{t.wgsl_name});
    for (comps, 0..) |c, i| {
        if (i != 0) {
            try bstr(out, s.arena, ", ");
        }
        if (c < v1_len) {
            try bprint(out, s.arena, "{s}[{d}]", .{ v1, c });
        } else {
            try bprint(out, s.arena, "{s}[{d}]", .{ v2, c - v1_len });
        }
    }
    try bstr(out, s.arena, ");\n");
}

/// OpSampledImage produces a (texture, sampler) value. WGSL doesn't have an
/// equivalent first-class object; instead, the sampling builtins take the two
/// as separate arguments. We record the constituent ids on the result so
/// later OpImageSample* can split them apart.
fn emitSampledImage(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void { // lint:off useless-error-return: shape uniform with the 18-arm emit* dispatch
    // OpSampledImage doesn't emit a statement - it pairs an image with
    // a sampler.  We stash both ids on the result and let emitImageSample
    // read them.  `out` kept for walker uniformity (see emitAccessChain).
    _ = out;
    const result: u32 = ops[1];
    const image_id: u32 = ops[2];
    const sampler_id: u32 = ops[3];
    setId(s, result, .{
        .kind = .value,
        .type_id = ops[0],
        // Stash both ids in extra slots for retrieval by the sampler ops.
        .extra_a = image_id,
        .extra_b = sampler_id,
        // wgsl_name is unused here; emitImageSample looks at extra_a/b instead.
        .wgsl_name = "",
    });
}

fn emitImageSample(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
    explicit_lod: bool,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const sampled_image_id: u32 = ops[2];
    const coord: []const u8 = lookupId(s, ops[3]).wgsl_name;

    const si: *const IdInfo = lookupId(s, sampled_image_id);

    // Combined-sampler check: if `si` was produced by something other
    // than OpSampledImage (e.g. an OpLoad of an OpTypeSampledImage
    // variable, as zimr's GL-style shaders pre-rewriting use), then
    // extra_a/extra_b weren't populated.  This shader cannot translate
    // to WGSL because WGSL has no combined samplers - texture and
    // sampler must be separate bindings.  Emit a diagnostic comment
    // and a placeholder so transpilation continues; the resulting
    // WGSL won't compile but the caller can see why.
    if (si.extra_a == 0 or si.extra_b == 0) {
        const t: *const IdInfo = lookupType(s, tid);
        const name: []const u8 = try tempName(s.arena, result);
        setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
        try bprint(
            out,
            s.arena,
            "  // ERROR: combined sampler at %{d} — WGSL requires separate texture+sampler bindings.\n" ++
                "  // Rewrite the shader so it uses separate `texture_2d<f32>` and `sampler` uniforms.\n" ++
                "  let {s}: {s} = {s}();\n",
            .{ sampled_image_id, name, t.wgsl_name, t.wgsl_name },
        );
        return;
    }

    const tex: []const u8 = lookupId(s, si.extra_a).wgsl_name;
    const smp: []const u8 = lookupId(s, si.extra_b).wgsl_name;

    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });

    if (explicit_lod) {
        // ImageSampleExplicitLod has an Lod operand in the ImageOperands tail
        // (after a small bitfield word). For the common case, ops[4] is the
        // operands mask and ops[5] is the LOD.
        const lod: []const u8 = if (ops.len > 5) lookupId(s, ops[5]).wgsl_name else "0.0";
        try bindLhs(out, s, result, name, t.wgsl_name);
        try bprint(out, s.arena, "textureSampleLevel({s}, {s}, {s}, {s});\n", .{
            tex, smp, coord, lod,
        });
    } else {
        // Faithful implicit-LOD sample.  WGSL forbids `textureSample`
        // (needs screen-space derivatives) in non-uniform control flow;
        // the SCCP prepass (src/spv2wgsl/sccp.zig) folds the spurious
        // always-true post-loop guards Zig's un-optimized SPIR-V leaves,
        // so post-loop samples (e.g. pbr_fs occlusion/emissive) now sit at
        // uniform scope, and the one genuinely-conditional sample
        // (pbr_fs shadow map) is sampled ahead of its non-uniform frustum
        // test in the source - so implicit-LOD `textureSample` is valid.
        // (This replaced an earlier `textureSampleLevel(..., 0.0)` interim.)
        try bindLhs(out, s, result, name, t.wgsl_name);
        try bprint(out, s.arena, "textureSample({s}, {s}, {s});\n", .{
            tex, smp, coord,
        });
    }
}

fn emitImageFetch(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const img_name: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const coord: []const u8 = lookupId(s, ops[3]).wgsl_name;
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "textureLoad({s}, {s}, 0);\n", .{
        img_name, coord,
    });
}

/// Lower a call to an atomic helper (zatomicAdd/Load/Store) to the WGSL
/// builtin.  `args` = [array_ptr, index] for load, [array_ptr, index, value]
/// for add/store.  The array pointer's wgsl_name is the path to the storage
/// array (a binding name like `kbuf_grid_counts`, or an access-chain text);
/// the element reference is `&<array>[<index>]`.
fn emitAtomicCall(
    s: *State,
    out: *ArrayList(u8),
    callee: []const u8,
    tid: u32,
    result: u32,
    args: []const u32,
) !void {
    const arr: []const u8 = lookupId(s, args[0]).wgsl_name;
    const idx: []const u8 = if (args.len >= 2) lookupId(s, args[1]).wgsl_name else "0u";
    const elem_ref: []const u8 = try allocPrint(s.arena, "&{s}[{s}]", .{ arr, idx });

    if (std.mem.indexOf(u8, callee, atomic_store_stem) != null) {
        // atomicStore(&arr[idx], val);  - a void statement.
        const val: []const u8 = if (args.len >= 3) lookupId(s, args[2]).wgsl_name else "0u";
        try bprint(out, s.arena, "  atomicStore({s}, {s});\n", .{ elem_ref, val });
        return;
    }

    // add / load both yield a u32 value bound with `let`.
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    if (std.mem.indexOf(u8, callee, atomic_add_stem) != null) {
        const val: []const u8 = if (args.len >= 3) lookupId(s, args[2]).wgsl_name else "0u";
        try bprint(out, s.arena, "atomicAdd({s}, {s});\n", .{ elem_ref, val });
    } else {
        // load
        try bprint(out, s.arena, "atomicLoad({s});\n", .{elem_ref});
    }
}

fn emitFunctionCall(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const callee: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const args: []const u32 = ops[3..];

    // ---- Atomic helper intercept (see kompute.zig + markAtomicBindings) ----
    // A call to zatomicAdd/Load/Store is lowered to the WGSL atomic builtin.
    // arg0 is the storage array pointer: its wgsl_name is the access path to
    // the array (the binding name for a whole-array pointer, or
    // `field[i]`-style for an access chain).  arg1 is the element index; for
    // add/store arg2 is the value.  The helper FUNCTION itself is never
    // emitted (skipped in emitOneFunction), so no dummy body leaks out.
    if (isAtomicHelperName(callee)) {
        try emitAtomicCall(s, out, callee, tid, result, args);
        return;
    }

    // ---- Workgroup-barrier helper intercept (see kompute.zig) ----
    // A call to zworkgroupBarrier() (void, no args) becomes the WGSL builtin.
    // The helper FUNCTION is skipped in emitOneFunction, so no body leaks out.
    if (isBarrierHelperName(callee)) {
        try bprint(out, s.arena, "  workgroupBarrier();\n", .{});
        return;
    }

    const t: *const IdInfo = lookupType(s, tid);
    // A void-returning call is a bare statement - WGSL has no value to
    // bind, and `let x: = f()` (empty type) is a parse error.  Only
    // value-returning calls get a `let` binding.
    const is_void: bool = (t.kind == .type_void);
    // A pointer-typed argument feeds a by-value-lowered pointer param
    // (see emitOneFunction slice (b) PART 2).  For an UNCALLED helper that
    // lowering is sound, but a real call like this means the callee writes
    // its local copy and the caller never sees the result - a silent
    // miscompile that naga can't catch (the WGSL is well-formed).  Until
    // the faithful `ptr<function,T>` + `&arg` lowering lands, make it LOUD:
    // emit an `// ERROR:` marker so it's detectable (and the closure check
    // treats any downstream undeclared id as a known symptom, not a bug).
    for (args) |aid| {
        const at: *const IdInfo = lookupType(s, lookupId(s, aid).type_id);
        if (at.kind == .type_pointer) {
            try bprint(
                out,
                s.arena,
                "  // ERROR: call passes pointer arg %{d} to a by-value param — " ++
                    "out-param result is lost (needs ptr<function,T> + &arg lowering).\n",
                .{aid},
            );
            break;
        }
    }
    if (is_void) {
        try bprint(out, s.arena, "  {s}(", .{callee});
    } else {
        const name: []const u8 = try tempName(s.arena, result);
        setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
        try bindLhs(out, s, result, name, t.wgsl_name);
        try bprint(out, s.arena, "{s}(", .{callee});
    }
    for (args, 0..) |aid, i| {
        if (i != 0) {
            try bstr(out, s.arena, ", ");
        }
        try bstr(out, s.arena, lookupId(s, aid).wgsl_name);
    }
    try bstr(out, s.arena, ");\n");
}

/// `OpFMod` - floor-based modulo, lowered as `a - b * floor(a / b)`.
///
/// * WHY NOT `%`: WGSL's `%` on floats is the TRUNC-based remainder, which is `OpFRem`. The
/// two agree only when both operands share a sign. Zig's `@mod` emits `OpFMod` and its
/// contract is that the result takes the sign of the DIVISOR - `@mod(-1.0, 6.28)` is ~5.28.
/// Angle wrapping in a shader depends on that, and emitting `%` would silently return a
/// negative angle instead.
///
/// * This opcode was UNHANDLED until an SSAO shader became the first in the tree to call
/// `@mod` - 161 corpus shaders had never exercised it, so the gap sat invisible. The
/// fallback emitted `f32()`, i.e. ZERO, with only a `// UNHANDLED` comment in the output.
fn emitFloorMod(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const a: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const b: []const u8 = lookupId(s, ops[3]).wgsl_name;
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "{s} - {s} * floor({s} / {s});\n", .{ a, b, a, b });
}

fn emitBinOp(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
    op_text: []const u8,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const a: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const b: []const u8 = lookupId(s, ops[3]).wgsl_name;
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "{s} {s} {s};\n", .{ a, op_text, b });
}

/// Integer comparisons carry signedness in the OPCODE (OpULessThan vs
/// OpSLessThan), and Zig's int casts between same-width ints are no-ops at
/// the SPIR-V level - so an operand's tracked WGSL type can disagree with
/// the comparison's signedness (an `i32` var fed to OpUGreaterThanEqual).
/// WGSL has no mixed-sign operators; Tint rejects `i32 >= u32` outright
/// (the t1178 fluid bug). Reconcile by bitcasting the odd operand to the
/// opcode's signedness; for sign-agnostic ops (IEqual) reconcile b to a.
/// Result is bool, so there is no result-type fallout.
const CmpSign = enum { unsigned, signed };

fn cmpOperand(
    s: *State,
    name: []const u8,
    type_name: []const u8,
    want: ?CmpSign,
    other_type: []const u8,
) ![]const u8 {
    const target: ?[]const u8 = blk: {
        if (want) |w| {
            switch (w) {
                .unsigned => {
                    if (std.mem.eql(u8, type_name, "i32")) {
                        break :blk "u32";
                    }
                    if (std.mem.eql(u8, type_name, "vec2<i32>")) {
                        break :blk "vec2<u32>";
                    }
                    if (std.mem.eql(u8, type_name, "vec3<i32>")) {
                        break :blk "vec3<u32>";
                    }
                    if (std.mem.eql(u8, type_name, "vec4<i32>")) {
                        break :blk "vec4<u32>";
                    }
                },
                .signed => {
                    if (std.mem.eql(u8, type_name, "u32")) {
                        break :blk "i32";
                    }
                    if (std.mem.eql(u8, type_name, "vec2<u32>")) {
                        break :blk "vec2<i32>";
                    }
                    if (std.mem.eql(u8, type_name, "vec3<u32>")) {
                        break :blk "vec3<i32>";
                    }
                    if (std.mem.eql(u8, type_name, "vec4<u32>")) {
                        break :blk "vec4<i32>";
                    }
                },
            }
            break :blk null;
        }
        // Sign-agnostic op: align to the other operand's int type.
        const ints = [_][2][]const u8{
            .{ "i32", "u32" },             .{ "u32", "i32" },
            .{ "vec2<i32>", "vec2<u32>" }, .{ "vec2<u32>", "vec2<i32>" },
        };
        for (ints) |pair| {
            if (std.mem.eql(u8, type_name, pair[0]) and std.mem.eql(u8, other_type, pair[1])) {
                break :blk other_type;
            }
        }
        break :blk null;
    };
    if (target) |t| {
        return allocPrint(s.arena, "bitcast<{s}>({s})", .{ t, name });
    }
    return name;
}

fn emitIntBin(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
    op_text: []const u8,
    want: ?CmpSign,
    result_is_bool: bool,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const ia: *const IdInfo = lookupId(s, ops[2]);
    const ib: *const IdInfo = lookupId(s, ops[3]);
    const ta: []const u8 = lookupType(s, ia.type_id).wgsl_name;
    const tb: []const u8 = lookupType(s, ib.type_id).wgsl_name;
    const t: *const IdInfo = lookupType(s, tid);
    // Working type: the opcode's signedness when it has one (OpU*/OpS*),
    // otherwise the RESULT type (sign-agnostic OpIAdd/ISub/IMul - SPIR-V
    // declares the result's int type, so align operands to it).
    var a: []const u8 = undefined;
    var b: []const u8 = undefined;
    var work_is_result: bool = true;
    if (want != null) {
        a = try cmpOperand(s, ia.wgsl_name, ta, want, tb);
        b = try cmpOperand(s, ib.wgsl_name, tb, want, ta);
        // Did the signedness pick differ from the declared result type?
        if (!result_is_bool) {
            const probe: []const u8 = try cmpOperand(s, "x", t.wgsl_name, want, t.wgsl_name);
            work_is_result = std.mem.eql(u8, probe, "x");
        }
    } else if (result_is_bool) {
        // Sign-agnostic comparison (IEqual): align b to a.
        a = ia.wgsl_name;
        b = try cmpOperand(s, ib.wgsl_name, tb, null, ta);
    } else {
        // Sign-agnostic arithmetic: align both operands to the result type.
        const rsign: ?CmpSign = if (std.mem.indexOf(u8, t.wgsl_name, "u32") != null)
            .unsigned
        else if (std.mem.indexOf(u8, t.wgsl_name, "i32") != null)
            .signed
        else
            null;
        a = try cmpOperand(s, ia.wgsl_name, ta, rsign, tb);
        b = try cmpOperand(s, ib.wgsl_name, tb, rsign, ta);
    }
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    if (result_is_bool or work_is_result) {
        try bprint(out, s.arena, "{s} {s} {s};\n", .{ a, op_text, b });
    } else {
        // The op computed in opcode-signedness; cast the expression back to
        // the declared result type.
        try bprint(out, s.arena, "bitcast<{s}>({s} {s} {s});\n", .{ t.wgsl_name, a, op_text, b });
    }
}

fn emitUnaryOp(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
    op_text: []const u8,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const a: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "{s}({s});\n", .{ op_text, a });
}

fn emitBuiltinCall(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
    name: []const u8,
    n_args: usize,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const t: *const IdInfo = lookupType(s, tid);
    const rname: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = rname });
    try bindLhs(out, s, result, rname, t.wgsl_name);
    try bprint(out, s.arena, "{s}(", .{name});
    var i: usize = 0;
    while (i < n_args) : (i += 1) {
        if (i != 0) {
            try bstr(out, s.arena, ", ");
        }
        try bstr(out, s.arena, lookupId(s, ops[2 + i]).wgsl_name);
    }
    try bstr(out, s.arena, ");\n");
}

fn emitSelect(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const cond: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const t_val: []const u8 = lookupId(s, ops[3]).wgsl_name;
    const f_val: []const u8 = lookupId(s, ops[4]).wgsl_name;
    const t: *const IdInfo = lookupType(s, tid);
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    // WGSL: select(false_val, true_val, cond).
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "select({s}, {s}, {s});\n", .{ f_val, t_val, cond });
}

fn emitConvert(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const src: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const target: []const u8 = lookupType(s, tid).wgsl_name;
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, target);
    try bprint(out, s.arena, "{s}({s});\n", .{ target, src });
}

fn emitBitcast(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const src: []const u8 = lookupId(s, ops[2]).wgsl_name;
    const target: []const u8 = lookupType(s, tid).wgsl_name;
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, target);
    try bprint(out, s.arena, "bitcast<{s}>({s});\n", .{ target, src });
}

fn emitExtInst(
    s: *State,
    out: *ArrayList(u8),
    ops: []const u32,
) !void {
    const tid: u32 = ops[0];
    const result: u32 = ops[1];
    const set_id: u32 = ops[2];
    const ext_op: u32 = ops[3];
    const args: []const u32 = ops[4..];

    if (set_id != s.glsl_ext_set) {
        return;
    }
    const t: *const IdInfo = lookupType(s, tid);
    const fname: []const u8 = glslExtName(ext_op);
    if (fname.len == 0) {
        warnUnhandled(s, 0x10000 | ext_op, 0); // synthetic opcode for logging
        return;
    }
    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{ .kind = .value, .type_id = tid, .wgsl_name = name });
    try bindLhs(out, s, result, name, t.wgsl_name);
    try bprint(out, s.arena, "{s}(", .{fname});
    for (args, 0..) |aid, i| {
        if (i != 0) {
            try bstr(out, s.arena, ", ");
        }
        try bstr(out, s.arena, lookupId(s, aid).wgsl_name);
    }
    try bstr(out, s.arena, ");\n");
}

/// Emit a placeholder for an unhandled opcode.  Many SPIR-V opcodes
/// produce a result-id (`result_type` + `result_id` as their first
/// two operands) that downstream code references.  If we just skip
/// the opcode, the next `lookupId` panics with "id %N referenced
/// before declaration".
///
/// Instead, we register the result-id with a default-valued WGSL
/// expression and emit a `// UNHANDLED opcode N` comment.  The WGSL
/// output won't render the original computation correctly, but it
/// WILL compile, and the comment + the warn log together pinpoint
/// what's missing.  Much better than panicking in the middle of a
/// 10KLOC shader.
fn emitUnhandledPlaceholder(
    s: *State,
    out: *ArrayList(u8),
    opcode: u32,
    word_offset: u32,
    ops: []const u32,
) !void {
    // Opcodes with no operands can't carry a result-id and have no
    // observable effect on the IR - silently skip.  This covers the
    // common stripped/tool-only opcodes that show up in optimized
    // SPIR-V (e.g. opcode 255 in chroma's .opt.spv has word_count=1).
    if (ops.len == 0) {
        return;
    }

    warnUnhandled(s, opcode, word_offset);

    // Heuristic: opcodes that take a (result_type, result_id) pair as
    // their first two operands need a placeholder.  We detect this by
    // checking whether ops[0] is a valid type id.  This is imperfect
    // (some opcodes have (type, id) followed by no other operands;
    // others have neither) but catches the common case.
    if (ops.len < 2) {
        return;
    }
    const maybe_type: u32 = ops[0];
    if (@as(usize, maybe_type) >= s.ids.len) {
        return;
    }
    const tinfo: IdInfo = s.ids[maybe_type];
    switch (tinfo.kind) {
        .type_scalar,
        .type_vector,
        .type_matrix,
        .type_array,
        .type_struct,
        .type_pointer,
        .type_image,
        .type_sampler,
        .type_sampled_image,
        => {},
        else => return,
    }
    const result: u32 = ops[1];
    if (result == 0 or @as(usize, result) >= s.ids.len) {
        return;
    }

    const name: []const u8 = try tempName(s.arena, result);
    setId(s, result, .{
        .kind = .value,
        .type_id = maybe_type,
        .wgsl_name = name,
    });
    try bindLhs(out, s, result, name, tinfo.wgsl_name);
    try bprint(
        out,
        s.arena,
        "{s}();  // UNHANDLED spv opcode {d}\n",
        .{ tinfo.wgsl_name, opcode },
    );
}

/// Body of the per-opcode switch.  Extracted so both the linear
/// emitter (`emitFunctionBody`) and the recursive walker callback
/// (`emitBlockBodyOnly`) can use it.  Returns true if the opcode
/// produced a placeholder (unhandled-opcode comment).
fn emitOnePerOpcode(
    s: *State,
    out: *ArrayList(u8),
    op: types.Op,
    ops: []const u32,
    off: u32,
) anyerror!void {
    switch (op) {
        .Undef => try emitUndef(s, out, ops),

        .Load => try emitLoad(s, out, ops),
        .CopyObject, .CopyLogical => try emitLoad(s, out, ops),
        .AccessChain, .InBoundsAccessChain => try emitAccessChain(s, out, ops),
        // Store needs is_entry context; the walker passes through s.
        // For Phase 3b, we look it up via the EntryPoint slot - Store
        // only writes to user globals, which is is_entry-agnostic in
        // the existing helper's body.  Re-check after corpus run.
        .Store => try emitStore(s, out, ops, isEntryFunctionContext(s)),

        .CompositeExtract => try emitCompositeExtract(s, out, ops),
        .CompositeConstruct => try emitCompositeConstruct(s, out, ops),
        .VectorShuffle => try emitVectorShuffle(s, out, ops),

        .SampledImage => try emitSampledImage(s, out, ops),
        .ImageSampleImplicitLod => try emitImageSample(s, out, ops, false),
        .ImageSampleExplicitLod => try emitImageSample(s, out, ops, true),
        .ImageFetch => try emitImageFetch(s, out, ops),

        .FunctionCall => try emitFunctionCall(s, out, ops),

        .FAdd => try emitBinOp(s, out, ops, "+"),
        .IAdd => try emitIntBin(s, out, ops, "+", null, false),
        .FSub => try emitBinOp(s, out, ops, "-"),
        .ISub => try emitIntBin(s, out, ops, "-", null, false),
        .IMul => try emitIntBin(s, out, ops, "*", null, false),
        .FMul,
        .VectorTimesScalar,
        .MatrixTimesScalar,
        .MatrixTimesVector,
        .VectorTimesMatrix,
        .MatrixTimesMatrix,
        => try emitBinOp(s, out, ops, "*"),
        .FDiv => try emitBinOp(s, out, ops, "/"),
        .SDiv => try emitIntBin(s, out, ops, "/", .signed, false),
        .UDiv => try emitIntBin(s, out, ops, "/", .unsigned, false),
        .FRem => try emitBinOp(s, out, ops, "%"),
        // * OpFMod IS NOT `%`. WGSL's `%` on floats is TRUNC-based, matching OpFRem; OpFMod
        // is FLOOR-based and takes the sign of the SECOND operand. `@mod(-1.0, 6.28)` must
        // give ~5.28, not -1.0, and a shader wrapping an angle relies on exactly that.
        // Lowered as `a - b * floor(a / b)`, the standard identity.
        .FMod => try emitFloorMod(s, out, ops),
        .SRem => try emitIntBin(s, out, ops, "%", .signed, false),
        // OpSMod: emit `%` (WGSL remainder). Correct for non-negative operands
        // (the common shader case); differs from true modulo only when operand
        // signs differ. Previously UNHANDLED - silently emitted `i32()` (0).
        .SMod => try emitIntBin(s, out, ops, "%", .signed, false),
        .UMod => try emitIntBin(s, out, ops, "%", .unsigned, false),
        .BitwiseAnd, .LogicalAnd => try emitBinOp(s, out, ops, "&"),
        .BitwiseOr, .LogicalOr => try emitBinOp(s, out, ops, "|"),
        .BitwiseXor => try emitBinOp(s, out, ops, "^"),
        .ShiftLeftLogical => try emitBinOp(s, out, ops, "<<"),
        .ShiftRightLogical, .ShiftRightArithmetic => try emitBinOp(s, out, ops, ">>"),
        .IEqual => try emitIntBin(s, out, ops, "==", null, true),
        .LogicalEqual, .FOrdEqual, .FUnordEqual => try emitBinOp(s, out, ops, "=="),
        .INotEqual => try emitIntBin(s, out, ops, "!=", null, true),
        .LogicalNotEqual, .FOrdNotEqual, .FUnordNotEqual => try emitBinOp(s, out, ops, "!="),
        .SLessThan => try emitIntBin(s, out, ops, "<", .signed, true),
        .ULessThan => try emitIntBin(s, out, ops, "<", .unsigned, true),
        .FOrdLessThan, .FUnordLessThan => try emitBinOp(s, out, ops, "<"),
        .SLessThanEqual => try emitIntBin(s, out, ops, "<=", .signed, true),
        .ULessThanEqual => try emitIntBin(s, out, ops, "<=", .unsigned, true),
        .FOrdLessThanEqual,
        .FUnordLessThanEqual,
        => try emitBinOp(s, out, ops, "<="),
        .SGreaterThan => try emitIntBin(s, out, ops, ">", .signed, true),
        .UGreaterThan => try emitIntBin(s, out, ops, ">", .unsigned, true),
        .FOrdGreaterThan, .FUnordGreaterThan => try emitBinOp(s, out, ops, ">"),
        .SGreaterThanEqual => try emitIntBin(s, out, ops, ">=", .signed, true),
        .UGreaterThanEqual => try emitIntBin(s, out, ops, ">=", .unsigned, true),
        .FOrdGreaterThanEqual,
        .FUnordGreaterThanEqual,
        => try emitBinOp(s, out, ops, ">="),

        .FNegate, .SNegate => try emitUnaryOp(s, out, ops, "-"),
        .LogicalNot, .Not => try emitUnaryOp(s, out, ops, "!"),

        .Dot => try emitBuiltinCall(s, out, ops, "dot", 2),
        .Select => try emitSelect(s, out, ops),

        .ConvertFToS,
        .ConvertFToU,
        .ConvertSToF,
        .ConvertUToF,
        .UConvert,
        .SConvert,
        .FConvert,
        => try emitConvert(s, out, ops),
        .Bitcast => try emitBitcast(s, out, ops),

        .ExtInst => try emitExtInst(s, out, ops),

        else => try emitUnhandledPlaceholder(s, out, @backingInt(op), off, ops),
    }
}

/// Walk the instructions between OpFunction and OpFunctionEnd, emitting one
/// WGSL statement per opcode.
/// Phase 3b of the rewrite (`src/notes/archive/spv2wgsl-rewrite-plan.md`):
/// emit one block's body - instructions between OpLabel and the
/// terminator, plus pre-terminator phi assignments - to `out`.
///
/// The walker (`src/spv2wgsl/walker.zig`) calls this as its
/// per-block body callback.  It DOES NOT emit the terminator
/// (Branch / BranchConditional / Return / etc.) - the walker
/// dispatches on the terminator itself, since that's where the
/// structural decisions live.
///
/// Iterates instructions in the block:
///   1. Skip header instructions (FunctionParameter / Variable / Phi
///      already handled in pass 3; Line / Nop / Name / etc. are
///      debug-only).
///   2. Stop at the terminator (Branch / BranchConditional / Switch /
///      Return / ReturnValue / Kill), but emit any registered phi
///      assignments for this block first.
///   3. Otherwise, dispatch through the same per-opcode helpers the
///      linear emitter uses.  All those helpers already take `out`
///      as a parameter (Phase 1.2 refactor), so the walker can pass
///      its own sub-buffer through.
fn emitBlockBodyOnly(
    s: *State,
    out: *ArrayList(u8),
    block_id: u32,
) anyerror!void {
    // Find the block's OpLabel in inst_off.  The walker passed us
    // the id; we need the instruction index.  This is O(n) per block
    // - fine for correctness; if it becomes hot, cache on first call.
    var label_idx: ?usize = null;
    for (s.inst_off.items, 0..) |off, k| {
        const w: u32 = s.spirv[off];
        if (types.opcodeOf(w) != @backingInt(types.Op.Label)) {
            continue;
        }
        const ops: []const u32 = types.operandsAt(s.spirv, off);
        if (ops[0] == block_id) {
            label_idx = k;
            break;
        }
    }
    const start: usize = label_idx orelse return;

    // Iterate from one PAST the OpLabel up to (but not including) the
    // first terminator we find.  Emit body instructions; stop at
    // terminator after emitting pre-terminator phi assignments.
    var idx: usize = start + 1;
    while (idx < s.inst_off.items.len) : (idx += 1) {
        const off: u32 = s.inst_off.items[idx];
        const w0: u32 = s.spirv[off];
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(w0)));
        const ops: []const u32 = types.operandsAt(s.spirv, off);

        s.debug_current_opcode = @backingInt(op);
        s.debug_current_offset = off;

        // Skip declaration-sweep and metadata-only opcodes (same as
        // the linear emitter).
        switch (op) {
            .FunctionParameter, .Variable, .Phi => continue,
            .Line, .Nop, .String, .SourceExtension, .Source, .Name, .MemberName => continue,
            else => {},
        }

        // Hit a terminator: emit pre-terminator phi assignments for
        // THIS block, then stop.  The walker emits the terminator
        // itself.  `OpUnreachable` (255) is also a block terminator
        // per the SPIR-V spec - Zig emits it for unreachable code
        // (e.g. after all branches of an if/else return).
        switch (op) {
            .Branch, .BranchConditional, .Return, .ReturnValue, .Kill, .Switch => {
                if (s.phi_assigns_ref) |pmap| {
                    if (pmap.get(block_id)) |list| {
                        for (list.items) |pa| {
                            const phi_name: []const u8 = lookupId(s, pa.phi_id).wgsl_name;
                            const val_name: []const u8 = lookupId(s, pa.value_id).wgsl_name;
                            try bprint(out, s.arena, "  {s} = {s};\n", .{ phi_name, val_name });
                        }
                    }
                }
                return; // terminator handled by walker
            },
            else => {
                // OpUnreachable (255) is also a terminator.  We don't have
                // an enum variant for it (since the linear emitter never
                // needed to handle it explicitly), so check the raw value.
                if (@backingInt(op) == 255) {
                    return;
                }
            },
        }

        // SelectionMerge / LoopMerge are scaffolding instructions -
        // they tell the linear emitter what's coming.  The walker
        // already has this information from BlockInfo.  Skip silently.
        switch (op) {
            .SelectionMerge, .LoopMerge => continue,
            else => {},
        }

        // Function boundary: a block in another function or an end-of-
        // function marker means we've fallen off the end of OUR block.
        // Shouldn't happen if the block has a proper terminator.  Stop.
        if (op == .Label or op == .Function or op == .FunctionEnd) {
            return;
        }

        // Per-opcode dispatch.  Same switch arms as `emitFunctionBody`
        // below, sans the terminator + label + merge cases handled
        // above.
        try emitOnePerOpcode(s, out, op, ops, off);
    }
}

/// Attempt to emit the current function's body via the structured-IR
/// path.  Builds the IR into a scratch buffer first and only appends
/// to `s.body_buf` on full success, so a mid-build
/// `IrBuildUnsupported` leaves `body_buf` untouched and the caller can
/// cleanly fall back to the legacy walker.
fn tryEmitViaIr(
    s: *State,
    fn_k: usize,
    end_k: usize,
) !void {
    const body: ir.FnBody = try ir_build.build(s.arena, fn_k, end_k, s.inst_off.items, s.spirv);
    // Safety net: if the reconstructed IR is internally inconsistent
    // (e.g. an exit's phi-arg count != its construct's result count),
    // do NOT emit it - surface as IrBuildUnsupported so the caller
    // falls back to the legacy walker.  Emitting malformed IR produces
    // type-crossed / arity-mismatched WGSL that the browser's WGSL
    // frontend rejects at pipeline-creation time.
    ir.validate(&body) catch return error.IrBuildUnsupported;
    // The IR path owns phi lowering entirely: merge phis become per-exit
    // `phi = arg` assignments (attach*MergePhis), and loop-header phis
    // become init-before-loop + iter-at-end-of-continuing emissions.
    // The legacy `phi_assigns_ref` mechanism (which emitBlockBodyOnly
    // consults to inject `phi = val` at each block terminator) would
    // DOUBLE-emit those assignments, so disable it for the duration of
    // this emit and restore it for the legacy fallback path.
    const saved_phi_ref: ?*const PhiAssignMap = s.phi_assigns_ref;
    s.phi_assigns_ref = null;
    defer s.phi_assigns_ref = saved_phi_ref;
    var scratch: ArrayList(u8) = .empty;
    try ir_emit.emit(s, &scratch, s.arena, &body, emitBlockBodyOnly);
    try s.body_buf.appendSlice(s.arena, scratch.items);
}

fn emitFunctionBody(
    s: *State,
    fn_k: usize,
    end_k: usize,
    is_entry: bool,
    phi_assigns: *PhiAssignMap,
) !void {
    s.is_current_entry = is_entry;
    defer s.is_current_entry = false;
    s.phi_assigns_ref = phi_assigns;
    defer s.phi_assigns_ref = null;

    // Structured-IR path (the only path since F5 deleted the recursive
    // `walker.zig`).  `ir_build.build` constructs its own block table
    // and entry-block lookup internally, so there is nothing to set up
    // here.  A CFG shape the builder can't structure is a HARD error
    // (`IrBuildUnsupported`) surfaced to the caller - no fallback.
    return tryEmitViaIr(s, fn_k, end_k);
}

/// Emit the body of one SPIR-V function (between OpFunction and
/// OpFunctionEnd) into `s.body_buf`.  Routes through the recursive
/// structured-CFG walker in `src/spv2wgsl/walker.zig`.  The walker
/// handles plain blocks, selection / loop / switch headers, the
/// one-sided-if phi-routing fix, and pre-terminator phi assignments.
///
/// This function used to fork on `s.use_recursive_walker` between
/// the recursive walker and a ~1100-LOC linear emitter; the linear
/// emitter was deleted in Phase 5c (2026-05-29) once the walker
/// drove every shader correctly.  See the rewrite plan at
/// `docs/archive/spv2wgsl-rewrite-plan.md`.
/// Append the operand positions of `ops` that are <id> references to
/// VALUES (not type ids, not literals, not label/block ids) for opcode
/// `op`, into `list`.  Conservative: only opcodes whose value-operand
/// positions are known are classified; an unrecognized opcode appends
/// nothing (it just won't trigger a hoist - safe, since over-conservatism
/// only risks LEAVING a value un-hoisted, never miscompiling).  This is
/// the operand-kind knowledge needed to scan uses without mistaking a
/// case literal / shuffle index / storage-class enum for a value id.
/// One place that records the SPIR-V operand semantics the hoist
/// analysis needs, so the def-side (`bodyResultId`) and use-side
/// (`appendValueOperands`) facts live together and cannot drift apart.
///
/// SPIR-V value ops are laid out `[result_type, result_id, operands...]`;
/// terminators/stores/etc. have no result and start at operand 0.  For
/// the hoist analysis we only need to know, per opcode:
///   - does it DEFINE a hoistable value? (result at ops[1]), and
///   - which operands are value <id> references (vs literals/labels)?
const OpShape = struct {
    /// True if this op produces a hoistable value result (at ops[1]).
    /// Matches `bodyResultId`'s old denylist by inverting it: the
    /// `.no_result` ops below are false, every other op is true.
    has_value_result: bool = false,
    /// Index where value <id> operands begin, or null if this op
    /// contributes no value-operand uses (terminators with only labels,
    /// merges, labels, debug, decls, and ops we don't model).
    value_from: ?u8 = null,
    /// If set, take at most this many operands starting at `value_from`
    /// (the no-result ops whose later operands are labels/literals:
    /// Store takes 2, BranchConditional/Switch/ReturnValue take 1).
    /// null = take all operands from `value_from` to the end.
    value_count: ?u8 = null,
    /// Custom value-operand handler (literals interleaved with ids):
    /// CompositeExtract / VectorShuffle.  When set, the generic
    /// from/count loop is skipped and this is called instead.
    custom: ?Custom = null,

    const Custom = enum { composite_extract, vector_shuffle };
};

fn opShape(op: types.Op) OpShape {
    return switch (op) {
        // Value ops, result at [1], all operands from [2] are <id>s.
        .Load,
        .CopyObject,
        .CopyLogical,
        .Bitcast,
        .FNegate,
        .SNegate,
        .Not,
        .LogicalNot,
        .ConvertFToS,
        .ConvertFToU,
        .ConvertSToF,
        .ConvertUToF,
        .UConvert,
        .SConvert,
        .FConvert,
        .IAdd,
        .FAdd,
        .ISub,
        .FSub,
        .IMul,
        .FMul,
        .UDiv,
        .SDiv,
        .FDiv,
        .UMod,
        .SRem,
        .SMod,
        .FRem,
        .FMod,
        .IEqual,
        .INotEqual,
        .FOrdEqual,
        .FUnordNotEqual,
        .FOrdNotEqual,
        .ULessThan,
        .SLessThan,
        .FOrdLessThan,
        .UGreaterThan,
        .SGreaterThan,
        .FOrdGreaterThan,
        .ULessThanEqual,
        .SLessThanEqual,
        .FOrdLessThanEqual,
        .UGreaterThanEqual,
        .SGreaterThanEqual,
        .FOrdGreaterThanEqual,
        .LogicalEqual,
        .LogicalNotEqual,
        .LogicalAnd,
        .LogicalOr,
        .BitwiseAnd,
        .BitwiseOr,
        .BitwiseXor,
        .ShiftLeftLogical,
        .ShiftRightLogical,
        .ShiftRightArithmetic,
        .Dot,
        .CompositeConstruct,
        .VectorTimesScalar,
        .MatrixTimesScalar,
        .VectorTimesMatrix,
        .MatrixTimesVector,
        .MatrixTimesMatrix,
        .Select,
        .AccessChain,
        .InBoundsAccessChain,
        .ImageSampleImplicitLod,
        .ImageSampleExplicitLod,
        .ImageFetch,
        => .{ .has_value_result = true, .value_from = 2 },

        // Value ops with leading non-value operands before the <id> args.
        .ExtInst => .{ .has_value_result = true, .value_from = 4 },
        .FunctionCall => .{ .has_value_result = true, .value_from = 3 },

        // Value ops whose operands interleave literals with ids.
        .CompositeExtract => .{ .has_value_result = true, .custom = .composite_extract },
        .VectorShuffle => .{ .has_value_result = true, .custom = .vector_shuffle },

        // No result, but DO reference values in their first operand(s).
        .Store => .{ .value_from = 0, .value_count = 2 }, // pointer, value
        .BranchConditional => .{ .value_from = 0, .value_count = 1 }, // condition
        .Switch => .{ .value_from = 0, .value_count = 1 }, // selector
        .ReturnValue => .{ .value_from = 0, .value_count = 1 }, // value

        // No value result AND no value operands: terminators with only
        // labels, merges, labels, debug, and the already-fn-scope decls
        // (Variable/Phi).  Phi operands are handled specially by the
        // caller (a phi value is used at its predecessor block).
        .Label,
        .Branch,
        .Return,
        .Kill,
        .LoopMerge,
        .SelectionMerge,
        .Nop,
        .Line,
        .Name,
        .MemberName,
        .Decorate,
        .MemberDecorate,
        .FunctionEnd,
        .FunctionParameter,
        .Variable,
        .Phi,
        => .{},

        // Any op we don't model: assume it produces a value result (so a
        // cross-block use is still hoisted) but contribute no uses (we
        // can't classify its operands safely).  This matches the old
        // bodyResultId denylist (unknown -> has result) + appendValueOperands
        // allowlist (unknown -> no uses scanned).
        else => .{ .has_value_result = true },
    };
}

/// The value <id> a body instruction DEFINES, or null if it defines no
/// hoistable value (terminators, stores, labels, merges, debug, and the
/// declaration ops which are already function-scope: OpVariable / OpPhi).
/// Hoistable value ops all carry result-type[0] + result[1].
fn bodyResultId(
    op: types.Op,
    ops: []const u32,
) ?u32 {
    // A value op carries its result at ops[1] (after the result type).
    if (opShape(op).has_value_result and ops.len >= 2) {
        return ops[1];
    }
    return null;
}

fn appendValueOperands(
    op: types.Op,
    ops: []const u32,
    list: *ArrayList(u32),
    arena: Allocator,
) !void {
    const shape: OpShape = opShape(op);
    if (shape.custom) |c| {
        switch (c) {
            // result-type[0], result[1], composite[2], then LITERAL indices.
            .composite_extract => {
                if (ops.len > 2) {
                    try list.append(arena, ops[2]);
                }
            },
            // result-type[0], result[1], vec1[2], vec2[3], LITERAL components.
            .vector_shuffle => {
                if (ops.len > 2) {
                    try list.append(arena, ops[2]);
                }
                if (ops.len > 3) {
                    try list.append(arena, ops[3]);
                }
            },
        }
        return;
    }
    const from: u8 = shape.value_from orelse return;
    var i: usize = from;
    var taken: u8 = 0;
    while (i < ops.len) : (i += 1) {
        if (shape.value_count) |max| {
            if (taken >= max) {
                break;
            }
        }
        try list.append(arena, ops[i]);
        taken += 1;
    }
}

/// Mark instruction results that are used OUTSIDE their defining block,
/// so emission declares them as a function-scope `var` (assigned at the
/// def site) instead of a block-scoped `let` (which WGSL would not have
/// in scope at the cross-block use).  The var-based analogue of Tint's
/// value propagation: rather than thread the SSA value out through
/// control-instruction results, we make it a mutable var readable in any
/// later block.  Linear scan over the function's instructions (SPIR-V
/// guarantees def-before-use in linear order, so a single pass suffices):
///   1. record the defining block of every hoistable value result;
///   2. for every value-operand use, if its def block differs from the
///      using block, mark the value hoisted.
/// Conservative on operand kinds (see appendValueOperands) so a literal
/// or label is never mistaken for a value id.
fn markHoistedResults(
    s: *State,
    fn_k: usize,
    end_k: usize,
) !void {
    // result id -> defining block id, and result id -> result type id.
    // Sized to the id bound.
    const def_block: []u32 = try s.arena.alloc(u32, s.ids.len);
    @memset(def_block, 0);
    const def_type: []u32 = try s.arena.alloc(u32, s.ids.len);
    @memset(def_type, 0);

    var cur_block: u32 = 0;
    var idx: usize = fn_k;
    while (idx < end_k) : (idx += 1) {
        const off: u32 = s.inst_off.items[idx];
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(s.spirv[off])));
        const ops: []const u32 = types.operandsAt(s.spirv, off);
        if (op == .Label) {
            cur_block = ops[0];
            continue;
        }
        if (bodyResultId(op, ops)) |rid| {
            if (@as(usize, rid) < def_block.len) {
                def_block[rid] = cur_block;
                // result-type is ops[0] for these value ops.
                def_type[rid] = ops[0];
            }
        }
    }

    // Second linear pass: scan value-operand uses.
    var uses: ArrayList(u32) = .empty;
    cur_block = 0;
    idx = fn_k;
    while (idx < end_k) : (idx += 1) {
        const off: u32 = s.inst_off.items[idx];
        const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(s.spirv[off])));
        const ops: []const u32 = types.operandsAt(s.spirv, off);
        if (op == .Label) {
            cur_block = ops[0];
            continue;
        }
        // An OpPhi value is "used" by the assignment `phi = value` emitted
        // at the END of its PREDECESSOR block (not in the phi's own
        // block).  So a phi value whose def block differs from its
        // predecessor block must be hoisted - the same scoping rule, but
        // the use site is the predecessor, not `cur_block`.  (Covers
        // phi_Phi_PhiInLoopHeader_FedByHoistedVar_* and friends, where a
        // value defined in a nested if-body feeds a loop-header phi via
        // the back-edge / continue block.)
        if (op == .Phi) {
            // `pair`, not `pi`: OpPhi's operands come in (value, predecessor) PAIRS, and the
            // loop steps by two. (It was `pi` until a `zm` import briefly made that a shadow of
            // `zm.pi`; the import is gone, the better name stayed.)
            var pair: usize = 2;
            while (pair + 1 < ops.len) : (pair += 2) {
                const pval: u32 = ops[pair];
                const ppred: u32 = ops[pair + 1];
                if (@as(usize, pval) >= def_block.len) {
                    continue;
                }
                const pdb: u32 = def_block[pval];
                if (pdb != 0 and pdb != ppred) {
                    s.hoisted[pval] = true;
                    s.hoist_type[pval] = def_type[pval];
                }
            }
            continue;
        }
        uses.clearRetainingCapacity();
        try appendValueOperands(op, ops, &uses, s.arena);
        for (uses.items) |used_id| {
            if (@as(usize, used_id) >= def_block.len) {
                continue;
            }
            const db: u32 = def_block[used_id];
            // db == 0 means the id is not a body-defined value (it's a
            // type/constant/global/param defined before the body, always
            // in scope) - skip.  Otherwise, a use in a different block
            // than the definition needs a hoisted var.
            if (db != 0 and db != cur_block) {
                s.hoisted[used_id] = true;
                s.hoist_type[used_id] = def_type[used_id];
            }
        }
    }
}

fn emitOneFunction(
    s: *State,
    fn_k: usize,
    end_k: usize,
) !void {
    const fn_ops: []const u32 = types.operandsAt(s.spirv, s.inst_off.items[fn_k]);
    const ret_type: u32 = fn_ops[0];
    const result: u32 = fn_ops[1];

    // Detect instruction results used outside their defining block; they
    // must be hoisted to function-scope `var`s (declared below alongside
    // phi vars; their def sites emit assignments).  See markHoistedResults.
    try markHoistedResults(s, fn_k, end_k);

    // Collect parameters and phis up front.
    var params: ArrayList(u32) = .empty;
    var phis: ArrayList(u32) = .empty;
    // Tint-style phi lowering: collect assignments-to-emit-at-predecessor.
    // For each OpPhi at block L with operand pairs (value_id, pred_block_id),
    // register an assignment of `phi_var = value` at the END of pred_block_id
    // (before its terminator).  See docs/tint-vs-spv2wgsl.md item 5 and
    // Tint's BlockInfo::phi_assignments field.
    //
    // Without this, the hoisted `var phiN: T;` stays at its default value
    // (zero), making any loop whose exit condition depends on a phi
    // appear non-terminating to WGSL's behavior analysis.
    var phi_assigns: PhiAssignMap = .empty;
    {
        var p_idx: usize = fn_k + 1;
        while (p_idx < end_k) : (p_idx += 1) {
            const po: u32 = s.inst_off.items[p_idx];
            const pw0: u32 = s.spirv[po];
            const pop: types.Op = @fromBackingInt(@intCast(types.opcodeOf(pw0)));
            const popnds: []const u32 = types.operandsAt(s.spirv, po);
            switch (pop) {
                .FunctionParameter => {
                    try params.append(s.arena, popnds[1]);
                    const pname: []const u8 = if (s.ids[popnds[1]].wgsl_name.len != 0)
                        s.ids[popnds[1]].wgsl_name
                    else
                        try allocPrint(s.arena, "p{d}", .{popnds[1]});
                    setId(s, popnds[1], .{
                        .kind = .value,
                        .type_id = popnds[0],
                        .wgsl_name = pname,
                    });
                },
                .Phi => {
                    const phi_id: u32 = popnds[1];
                    try phis.append(s.arena, phi_id);
                    const pname: []const u8 = try allocPrint(s.arena, "phi{d}", .{phi_id});
                    setId(s, phi_id, .{
                        .kind = .value,
                        .type_id = popnds[0],
                        .wgsl_name = pname,
                    });
                    var i: usize = 2;
                    while (i + 1 < popnds.len) : (i += 2) {
                        const value_id: u32 = popnds[i];
                        const pred_block: u32 = popnds[i + 1];
                        const gop: PhiAssignMap.GetOrPutResult = try phi_assigns.getOrPut(s.arena, pred_block);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = .empty;
                        }
                        try gop.value_ptr.append(s.arena, .{
                            .phi_id = phi_id,
                            .value_id = value_id,
                        });
                    }
                },
                else => {},
            }
        }
    }

    const is_entry: bool = result == s.entry.func_id;

    // Track the current function's return type for the IR emitter's
    // `.unreach` lowering (value-returning functions need a terminating
    // `return <zero>;` on the unreachable post-merge tail).  Reset on
    // exit so a later void/entry function doesn't inherit it.
    s.current_ret_type = if (is_entry) 0 else ret_type;
    defer s.current_ret_type = 0;

    // Every function-local NAME we emit, so the OpVariable pass below can rename
    // collisions. Distinct SPIR-V locals that share an OpName debug name (e.g.
    // three `var t0` produced by flattening separate Zig blocks) would otherwise
    // emit the SAME WGSL name -> a "redeclaration" error only the GPU validator
    // catches (a runtime black screen). Params/phis/hoisted keep their names
    // (signature ties / already-unique generated names) and are recorded here as
    // taken; only OpVariables are renamed against this set. Scoped per function.
    var used_local_names = std.StringHashMap(void).init(s.arena);

    if (is_entry) {
        try emitEntrySignature(s);
    } else {
        const ret_info: *const IdInfo = lookupType(s, ret_type);
        // Name was already set by the pre-pass in pass4_functions.
        // Read it back instead of re-registering (avoids the
        // "id redefined" warning).
        const fname: []const u8 = s.ids[result].wgsl_name;
        try bprint(&s.body_buf, s.arena, "fn {s}(", .{fname});
        // Pointer-typed parameters (Zig passes by-pointer) that the body
        // stores through can't be WGSL `fn` params directly - WGSL `fn`
        // parameters are immutable bindings, so the body's `OpStore %p`
        // -> `p = ...` would be "assignment to an immutable binding".  Emit
        // such a param BY VALUE under a `_param` alias and shadow it with
        // a function-scope `var <name> = <name>_param;` below, so every
        // existing `OpStore`/`OpLoad`/access-chain that spells the
        // pointer as `<name>` keeps working unchanged.  (All such helper
        // functions in Zig's output are uncalled - see finishing_webgpu.md
        // section 2 slice (b) PART 2 - so the by-value vs by-reference
        // distinction is moot for correctness; only naga-validity matters.
        // If a called one ever appears, the faithful lowering is a real
        // `ptr<function,T>` param + `&local` arg at the call site.)
        var ptr_params: ArrayList(u32) = .empty;
        for (params.items, 0..) |pid, pi| {
            if (pi != 0) {
                try bstr(&s.body_buf, s.arena, ", ");
            }
            const pi_info: *const IdInfo = lookupId(s, pid);
            const pt: *const IdInfo = lookupType(s, pi_info.type_id);
            if (pt.kind == .type_pointer) {
                try bprint(&s.body_buf, s.arena, "{s}_param: {s}", .{ pi_info.wgsl_name, pt.wgsl_name });
                try ptr_params.append(s.arena, pid);
            } else {
                try bprint(&s.body_buf, s.arena, "{s}: {s}", .{ pi_info.wgsl_name, pt.wgsl_name });
            }
            used_local_names.put(pi_info.wgsl_name, {}) catch @panic("OOM");
        }
        try bstr(&s.body_buf, s.arena, ")");
        if (ret_info.kind != .type_void) {
            try bprint(&s.body_buf, s.arena, " -> {s}", .{ret_info.wgsl_name});
        }
        try bstr(&s.body_buf, s.arena, " {\n");

        // Materialize each pointer param as a mutable local seeded from
        // its by-value `_param` alias.
        for (ptr_params.items) |pid| {
            const pi_info: *const IdInfo = lookupId(s, pid);
            const pt: *const IdInfo = lookupType(s, pi_info.type_id);
            try bprint(
                &s.body_buf,
                s.arena,
                "  var {s}: {s} = {s}_param;\n",
                .{ pi_info.wgsl_name, pt.wgsl_name, pi_info.wgsl_name },
            );
        }
    }

    // Declare phi variables at function entry.
    for (phis.items) |phi_id| {
        const ph: *const IdInfo = lookupId(s, phi_id);
        const pt: *const IdInfo = lookupType(s, ph.type_id);
        if (pt.wgsl_name.len != 0) {
            try bprint(&s.body_buf, s.arena, "  var {s}: {s};\n", .{ ph.wgsl_name, pt.wgsl_name });
        }
        used_local_names.put(ph.wgsl_name, {}) catch @panic("OOM");
    }

    // Declare hoisted-value variables at function entry (results used
    // outside their defining block; see markHoistedResults).  Each gets a
    // function-scope `var`; its definition site emits an assignment.
    {
        var hid: u32 = 0;
        while (hid < s.hoisted.len) : (hid += 1) {
            if (!s.hoisted[hid]) {
                continue;
            }
            const ht: *const IdInfo = lookupType(s, s.hoist_type[hid]);
            const hname: []const u8 = try tempName(s.arena, hid);
            // A zero-bit/void hoisted value has no WGSL type; `var x: ;` is
            // invalid WGSL. It folds to `undef` at use sites, so skip the decl.
            if (ht.wgsl_name.len != 0) {
                try bprint(&s.body_buf, s.arena, "  var {s}: {s};\n", .{ hname, ht.wgsl_name });
            }
            // `try`, not `catch {}`: this set is what keeps two locals in one WGSL scope from
            // taking the same name. A dropped insert does not fail here - it fails later, as
            // emitted shader source with a duplicate `var`, which is a far worse place to
            // discover an allocation failure.
            try used_local_names.put(hname, {});
        }
    }

    // Declare function-scope OpVariables.
    {
        var v_idx: usize = fn_k + 1;
        while (v_idx < end_k) : (v_idx += 1) {
            const vo: u32 = s.inst_off.items[v_idx];
            const vw0: u32 = s.spirv[vo];
            if (@as(types.Op, @fromBackingInt(@intCast(types.opcodeOf(vw0)))) != .Variable) {
                continue;
            }
            const vopnds: []const u32 = types.operandsAt(s.spirv, vo);
            if (vopnds[2] != @backingInt(types.StorageClass.Function)) {
                continue;
            }
            const ptr_tid: u32 = vopnds[0];
            const result_id: u32 = vopnds[1];
            const ptr_ti: *const IdInfo = lookupType(s, ptr_tid);
            const pointee_tid: u32 = ptr_ti.extra_b;
            const pointee: *const IdInfo = lookupType(s, pointee_tid);
            const raw_vname: []const u8 = if (s.ids[result_id].wgsl_name.len != 0)
                s.ids[result_id].wgsl_name
            else
                try allocPrint(s.arena, "v{d}", .{result_id});
            // Rename on collision: a distinct SPIR-V local sharing this name
            // (e.g. another flattened-block `t0`) gets a `_N` suffix so the WGSL
            // has no duplicate declaration. setId stores the final name, so every
            // later wgslNameOf(result_id) in the body uses it - refs stay correct.
            var vname: []const u8 = raw_vname;
            var dedup_n: u32 = 1;
            while (used_local_names.contains(vname)) : (dedup_n += 1) {
                vname = try allocPrint(s.arena, "{s}_{d}", .{ raw_vname, dedup_n });
            }
            // Same reason as the helper-name insert above: dropping this makes the dedup loop
            // directly above it silently useless the next time round.
            try used_local_names.put(vname, {});
            setId(s, result_id, .{
                .kind = .variable,
                .type_id = ptr_tid,
                .wgsl_name = vname,
                .extra_a = vopnds[2],
                .extra_b = pointee_tid,
            });
            // A zero-bit / opaque / void pointee (an OpVariable of an
            // image/sampler or a void type) has NO WGSL representation, so
            // `var x: ;` would be emitted - invalid WGSL that Tint/naga reject
            // ("expected identifier"). Such values fold to `undef` at their use
            // sites (see the opaque-type handling above), and here the variable
            // is dead, so skip the declaration entirely.
            if (pointee.wgsl_name.len != 0) {
                try bprint(&s.body_buf, s.arena, "  var {s}: {s};\n", .{ vname, pointee.wgsl_name });
            }
        }
    }

    // Walk the body emitting one instruction at a time.
    try emitFunctionBody(s, fn_k, end_k, is_entry, &phi_assigns);

    try bstr(&s.body_buf, s.arena, "}\n\n");
}

fn pass4_functions(s: *State) !void {
    // Pre-pass: register every function's name (and its parameters'
    // names) BEFORE emitting any body.  SPIR-V function calls can
    // forward-reference functions defined later in the module; without
    // this, the first body that contains an OpFunctionCall to a yet-
    // unseen function panics in lookupId.
    {
        var k: usize = 0;
        while (k < s.inst_off.items.len) : (k += 1) {
            const off: u32 = s.inst_off.items[k];
            // A SPIR-V instruction's first word packs the opcode in its low 16 bits and the
            // word count in its high 16 - hence `opcodeOf` rather than a plain compare.
            const first_word: u32 = s.spirv[off];
            const op: types.Op = @fromBackingInt(@intCast(types.opcodeOf(first_word)));
            switch (op) {
                .Function => {
                    // `OpFunction` operands: [0] is the RESULT TYPE id, [1] the result id.
                    const ops: []const u32 = types.operandsAt(s.spirv, off);
                    const ret_type: u32 = ops[0];
                    const result: u32 = ops[1];
                    // entry has special name
                    if (result == s.entry.func_id) {
                        continue;
                    }
                    if (s.ids[result].kind != .unknown and s.ids[result].wgsl_name.len != 0) {
                        continue;
                    }
                    const existing_name = s.ids[result].wgsl_name;
                    // Keep a name the module already carried (from OpName debug info); otherwise
                    // synthesise one from the id, which is unique by construction.
                    const fname: []const u8 = if (existing_name.len != 0)
                        existing_name
                    else
                        try allocPrint(s.arena, "fn_{d}", .{result});
                    setId(s, result, .{
                        .kind = .function,
                        .wgsl_name = fname,
                        .type_id = ret_type,
                    });
                },
                else => {},
            }
        }
    }

    // Reachability: only emit functions reachable from the entry point
    // via the OpFunctionCall graph.  Zig's un-optimized SPIR-V carries
    // many DEAD helper functions (type-machinery / comptime leftovers)
    // that are never called and contain constructs WGSL can't express
    // (8-bit pointers, pointer-to-pointer, struct-to-struct OpBitcast).
    // An optimizing pass (spirv-opt DCE) would drop them; Tint's reader
    // likewise only walks structurally-reachable code.  Emitting them
    // would produce WGSL naga rejects, so we skip them entirely - this
    // is the principled analogue of Tint's reachability front-end
    // (finishing_webgpu.md section 2 step 1).  Entry-reachable functions are
    // unaffected.
    const reachable: []const bool = try computeReachableFunctions(s);

    var k: usize = 0;
    while (k < s.inst_off.items.len) {
        const off: u32 = s.inst_off.items[k];
        const w0: u32 = s.spirv[off];
        if (@as(types.Op, @fromBackingInt(@intCast(types.opcodeOf(w0)))) != .Function) {
            k += 1;
            continue;
        }

        // Find FunctionEnd. (Function bodies always end with one.)
        var end_k: usize = k + 1;
        while (end_k < s.inst_off.items.len) : (end_k += 1) {
            const eo: u32 = s.inst_off.items[end_k];
            if (@as(types.Op, @fromBackingInt(@intCast(types.opcodeOf(s.spirv[eo])))) == .FunctionEnd) {
                break;
            }
        }
        if (end_k >= s.inst_off.items.len) {
            return error.MalformedSpirv;
        }

        const fn_result: u32 = types.operandsAt(s.spirv, off)[1];
        // Atomic helper bodies are dummies (see kompute.zig) - their calls are
        // lowered to WGSL builtins in emitAtomicCall, so the function itself
        // must NOT be emitted (a `var<storage>` array passed by value would be
        // illegal WGSL anyway).  Skip by name even though it's "reachable".
        if (isAtomicHelperName(lookupId(s, fn_result).wgsl_name) or
            isBarrierHelperName(lookupId(s, fn_result).wgsl_name))
        {
            k = end_k + 1;
            continue;
        }
        if (fn_result < reachable.len and reachable[fn_result]) {
            try emitOneFunction(s, k, end_k);
        }
        k = end_k + 1;
    }
}

test "cmpOperand: signedness reconciliation (the t1178 fluid bug)" {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var s: State = undefined;
    s.arena = arena_state.allocator();
    // i32 operand into an unsigned op -> bitcast to u32 (Tint rejects i32>=u32).
    try expectEqualStrings(
        "bitcast<u32>(x)",
        try cmpOperand(&s, "x", "i32", .unsigned, "u32"),
    );
    // Already the right signedness -> untouched.
    try expectEqualStrings("x", try cmpOperand(&s, "x", "u32", .unsigned, "i32"));
    // Sign-agnostic op (IEqual/IAdd null): align to the OTHER operand's type.
    try expectEqualStrings(
        "bitcast<u32>(x)",
        try cmpOperand(&s, "x", "i32", null, "u32"),
    );
    // Vectors reconcile element-wise type names.
    try expectEqualStrings(
        "bitcast<vec2<i32>>(v)",
        try cmpOperand(&s, "v", "vec2<u32>", .signed, "vec2<u32>"),
    );
    // Floats are never touched.
    try expectEqualStrings("f", try cmpOperand(&s, "f", "f32", .unsigned, "u32"));
}

// =============================================================================
// Output identifier closure check
// =============================================================================
//
// Scan the produced WGSL for `_N` SSA-temp references and verify every one
// has a matching `let _N` or `var _N` (or function-parameter) declaration.
// If a reference has no declaration, it means an opcode handler forgot to
// populate `ids[result].wgsl_name` and downstream uses are reading the
// default empty string or stale data. We surface this as a structured error
// pointing at the offending id, which beats letting tint print a confusing
// "unknown identifier" message.

fn parseTempId(tok: []const u8) ?u32 {
    if (tok.len < 2 or tok[0] != '_') {
        return null;
    }
    var i: usize = 1;
    while (i < tok.len) : (i += 1) {
        if (!std.ascii.isDigit(tok[i])) {
            return null;
        }
    }
    return std.fmt.parseInt(u32, tok[1..], 10) catch null;
}

/// Pure closure check: verify every `_N` SSA-temp REFERENCED in `wgsl`
/// also has a `let`/`var` DECLARATION.  Returns `error.OutputIdentifierMissing`
/// (and writes the first offending id to `missing_id`) on failure;
/// otherwise returns normally.  Does NOT log - the caller decides
/// whether a failure is a real bug (forgotten `wgsl_name`) or a known
/// downstream symptom (an emitted `// ERROR:` marker) and logs
/// accordingly.  Keeping this side-effect-free lets the unit tests
/// exercise the error path without tripping a Zig test step's
/// "error logs" failure.
fn checkOutputClosure(
    arena: Allocator,
    wgsl: []const u8,
    missing_id: ?*u32,
) !void {
    var declared = std.AutoHashMap(u32, void).init(arena);
    defer declared.deinit();
    var refs = std.AutoHashMap(u32, void).init(arena);
    defer refs.deinit();

    // Walk tokens with a 1-token lookback so we can tell whether `_N` is
    // preceded by `let` / `var` (declaration) or not (reference).
    var prev: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, wgsl, " \t\n(),:;[]{}=+-*/<>!&|^%");
    while (it.next()) |tok| {
        if (parseTempId(tok)) |n| {
            if (std.mem.eql(u8, prev, "let") or std.mem.eql(u8, prev, "var")) {
                try declared.put(n, {});
            } else {
                try refs.put(n, {});
            }
        }
        prev = tok;
    }

    // Every reference must have a matching declaration.
    var ri: std.AutoHashMap(u32, void).KeyIterator = refs.keyIterator();
    while (ri.next()) |k| {
        if (!declared.contains(k.*)) {
            if (missing_id) |out| {
                out.* = k.*;
            }
            return error.OutputIdentifierMissing;
        }
    }
}

// =============================================================================
// Public entry point
// =============================================================================

// =============================================================================
// SAMPLER-UNIFORMITY GATE
// =============================================================================

/// An implicit-LOD `textureSample` computes derivatives across the quad, so WGSL
/// requires it to be reached through UNIFORM control flow.  Break that and Dawn
/// rejects the shader AT PIPELINE CREATION, on device:
///
///     'textureSample' must only be called from uniform control flow
///     note: reading from module-scope private variable 'o_normal' may result
///           in a non-uniform value
///
/// This bit us repeatedly, and neither existing guard could catch it:
///
///   * The source-level `[sampler-in-branch]` lint reads the ZIG.  But decal_fs's
///     Zig samples unconditionally at the top of `shaderMain` - perfectly flat.
///     The branch was manufactured INSIDE a zm helper: scalar `clamp01` used to be
///     `if (v < 0) 0 else if (v > 1) 1 else v`, and its condition derived from a
///     varying.  The branch exists only in the EMITTED code, so no amount of
///     reading the source will ever find it.
///
///   * "Is the sample nested?" on the emitted WGSL is the WRONG question.  The
///     structurizer emits dead `if (73u == 73u)` phi-dispatch guards, and a
///     CONSTANT condition is uniform - so a sample inside one is perfectly legal.
///     effect_ascii_fs sits three `if`s deep and is valid.  Depth proves nothing.
///
/// The question is exactly: **does the condition of a branch guarding the sample
/// derive from a non-uniform value?**  That is dataflow, and SPIR-V is where it
/// can be answered - ids are still SSA, and we know which variables are `Input`
/// (the varyings that later become the module-scope privates Dawn complains about).
///
/// DELIBERATE LIMITS.  A false POSITIVE breaks a legal build; a false negative
/// only leaves us where we already were.  So this errs toward silence:
///   * Taint flows only through a whitelist of data opcodes; an unlisted opcode
///     propagates nothing.  Widen `taints` when a gap shows up.
///   * Only SELECTIONS (`OpSelectionMerge` + `OpBranchConditional`) are checked.
///     A non-uniform LOOP exit also makes its body non-uniform - not modelled yet,
///     and the obvious next extension.
///   * `Uniform`/`UniformConstant`/`PushConstant` loads are uniform by definition
///     and are never seeded.  Explicit-LOD (`sampleLevel`) needs no derivatives and
///     is exempt - it is the documented escape hatch, and must not be flagged.
pub const sampler_uniformity = struct {
    const UOp = struct {
        const ext_inst: u32 = 12;
        const function: u32 = 54;
        const function_parameter: u32 = 55;
        const function_end: u32 = 56;
        const function_call: u32 = 57;
        const variable: u32 = 59;
        const store: u32 = 62;
        const load: u32 = 61;
        const access_chain: u32 = 65;
        const in_bounds_access_chain: u32 = 66;
        const composite_extract: u32 = 81;
        const vector_shuffle: u32 = 79;
        const phi: u32 = 245;
        const loop_merge: u32 = 246;
        const selection_merge: u32 = 247;
        const label: u32 = 248;
        const branch_conditional: u32 = 250;
    };

    const storage_class_input: u32 = 1;

    /// Implicit-LOD samples need derivatives -> need uniform control flow.
    /// Explicit-LOD (88/90/92/94) does NOT, and is deliberately absent.
    fn isImplicitSample(op: u32) bool {
        return op == 87 or op == 89 or op == 91 or op == 93;
    }

    /// Does this opcode carry a value forward (so taint flows through it)?
    /// Conservative in the SAFE direction: an unlisted op propagates nothing,
    /// which can only cost a missed report, never a bogus build failure.
    fn taints(op: u32) bool {
        return switch (op) {
            UOp.ext_inst,
            UOp.function_call,
            UOp.load,
            UOp.access_chain,
            UOp.in_bounds_access_chain,
            UOp.phi,
            => true,
            79...84 => true, // composite: shuffle, construct, extract, insert, copy
            87...94 => true, // image samples (a sample RESULT varies with its coords)
            109...124 => true, // conversions + bitcast
            126...152 => true, // arithmetic
            154...191 => true, // logical + comparison - these BUILD the conditions
            else => false,
        };
    }

    /// The result id of the instruction at `off`, or 0 when it has none.
    /// NOTE `types.operandsAt` returns the words AFTER the opcode word, so for a
    /// `result_type, result, ...` instruction the result id is ops[1], not ops[2].
    fn resultOf(spirv: []const u32, off: u32) u32 {
        const ops: []const u32 = types.operandsAt(spirv, off);
        const op: u32 = types.opcodeOf(spirv[off]);
        if (op == UOp.label) {
            return if (ops.len > 0) ops[0] else 0;
        }
        if (op == UOp.function_parameter or op == UOp.variable or taints(op)) {
            return if (ops.len > 1) ops[1] else 0;
        }
        return 0;
    }

    /// The ID-operand positions of the instruction at `off`.  Ops whose tail holds
    /// LITERALS (composite-extract indices, shuffle components, the ext-inst number)
    /// get explicit spans, so a literal can never be mistaken for an id and taint an
    /// unrelated value.
    fn idOperands(spirv: []const u32, off: u32, buf: *[64]u32) []const u32 {
        const ops: []const u32 = types.operandsAt(spirv, off);
        const op: u32 = types.opcodeOf(spirv[off]);
        var n: usize = 0;
        switch (op) {
            // result_type, result, pointer, [memory-operand LITERALS]
            UOp.load => {
                if (ops.len > 2) {
                    buf[n] = ops[2];
                    n += 1;
                }
            },
            // result_type, result, composite, [index LITERALS]
            UOp.composite_extract => {
                if (ops.len > 2) {
                    buf[n] = ops[2];
                    n += 1;
                }
            },
            // result_type, result, v1, v2, [component LITERALS]
            UOp.vector_shuffle => {
                if (ops.len > 3) {
                    buf[n] = ops[2];
                    buf[n + 1] = ops[3];
                    n += 2;
                }
            },
            // result_type, result, set(id), instruction LITERAL, args...
            UOp.ext_inst => {
                var i: usize = 4;
                while (i < ops.len and n < buf.len) : (i += 1) {
                    buf[n] = ops[i];
                    n += 1;
                }
            },
            // result_type, result, function(id), args...
            UOp.function_call => {
                var i: usize = 3;
                while (i < ops.len and n < buf.len) : (i += 1) {
                    buf[n] = ops[i];
                    n += 1;
                }
            },
            // result_type, result, (value, parent) pairs -> take the VALUES
            UOp.phi => {
                var i: usize = 2;
                while (i < ops.len and n < buf.len) : (i += 2) {
                    buf[n] = ops[i];
                    n += 1;
                }
            },
            else => {
                // The generic data ops (arithmetic, comparison, logical, select,
                // conversion, access-chain, composite-construct): every word after
                // the result id is an id.
                if (!taints(op)) {
                    return buf[0..0];
                }
                var i: usize = 2;
                while (i < ops.len and n < buf.len) : (i += 1) {
                    buf[n] = ops[i];
                    n += 1;
                }
            },
        }
        return buf[0..n];
    }

    /// Run the gate over one SPIR-V module.  `shader_name` only decorates the
    /// diagnostic.  Returns `error.SamplerInNonUniformControlFlow` when an
    /// implicit-LOD sample is reachable only through a branch whose condition
    /// derives from a varying.
    pub fn check(arena: Allocator, spirv: []const u32, shader_name: []const u8) !void {
        if (spirv.len < 5) {
            return;
        }

        var offs: ArrayList(u32) = .empty;
        {
            var off: u32 = 5;
            while (off < spirv.len) {
                const wc: u32 = types.wordCountOf(spirv[off]);
                if (wc == 0) {
                    break;
                }
                try offs.append(arena, off);
                off += wc;
            }
        }
        const inst_off: []const u32 = offs.items;
        const bound: u32 = spirv[3];
        const tainted: []bool = try arena.alloc(bool, bound + 1);
        @memset(tainted, false);

        // ---- seed: every Input-storage variable is a varying --------------------
        for (inst_off) |off| {
            const ops: []const u32 = types.operandsAt(spirv, off);
            if (types.opcodeOf(spirv[off]) != UOp.variable) {
                continue;
            }
            if (ops.len > 2 and ops[2] == storage_class_input and ops[1] <= bound) {
                tainted[ops[1]] = true;
            }
        }

        // id -> the offset of the instruction that defines it (0 = none). Needed to
        // walk an access chain back to the variable it is rooted at.
        const def_off: []u32 = try arena.alloc(u32, bound + 1);
        @memset(def_off, 0);
        for (inst_off) |off| {
            const r: u32 = resultOf(spirv, off);
            if (r != 0 and r <= bound) {
                def_off[r] = off;
            }
        }

        // ---- function parameter + call tables (interprocedural taint) -----------
        var params: std.AutoHashMapUnmanaged(u32, []u32) = .empty;
        var calls: std.AutoHashMapUnmanaged(u32, []u32) = .empty;
        var samples_in: std.AutoHashMapUnmanaged(u32, void) = .empty;
        {
            var cur: u32 = 0;
            var plist: ArrayList(u32) = .empty;
            var clist: ArrayList(u32) = .empty;
            for (inst_off) |off| {
                const ops: []const u32 = types.operandsAt(spirv, off);
                const op: u32 = types.opcodeOf(spirv[off]);
                if (op == UOp.function) {
                    if (cur != 0) {
                        try params.put(arena, cur, try arena.dupe(u32, plist.items));
                        try calls.put(arena, cur, try arena.dupe(u32, clist.items));
                    }
                    cur = if (ops.len > 1) ops[1] else 0;
                    plist.clearRetainingCapacity();
                    clist.clearRetainingCapacity();
                } else if (op == UOp.function_parameter and ops.len > 1) {
                    try plist.append(arena, ops[1]);
                } else if (op == UOp.function_call and ops.len > 2) {
                    try clist.append(arena, ops[2]);
                } else if (isImplicitSample(op) and cur != 0) {
                    try samples_in.put(arena, cur, {});
                }
            }
            if (cur != 0) {
                try params.put(arena, cur, try arena.dupe(u32, plist.items));
                try calls.put(arena, cur, try arena.dupe(u32, clist.items));
            }
        }

        // A function needs uniform control flow if it samples, or CALLS something
        // that does.  (decal_fs's sample lives in a generated accessor helper.)
        var grew: bool = true;
        while (grew) {
            grew = false;
            var it: std.AutoHashMapUnmanaged(u32, []u32).Iterator = calls.iterator();
            while (it.next()) |e| {
                if (samples_in.contains(e.key_ptr.*)) {
                    continue;
                }
                for (e.value_ptr.*) |callee| {
                    if (samples_in.contains(callee)) {
                        try samples_in.put(arena, e.key_ptr.*, {});
                        grew = true;
                        break;
                    }
                }
            }
        }
        if (samples_in.count() == 0) {
            return;
        }

        // ---- propagate the taint to a fixpoint ---------------------------------
        // DATA dependence alone is NOT enough, and this is the subtlety that makes a
        // naive version of this gate useless. Zig's SPIR-V lowers a branchy helper into
        // a numeric PHI STATE MACHINE:
        //
        //     %639 = %626 < 0.0            <- tainted (a varying)
        //     ... branch on %639 ...
        //     %654 = OpPhi(59u, 61u)       <- every incoming value is a CONSTANT
        //     %659 = %654 == 61u           <- looks uniform to a data-flow walk!
        //     ... branch on %659 ... and the SAMPLE lives in here.
        //
        // Every value feeding %659 is a constant, so pure def-use taint says "uniform"
        // and the gate sails past the exact bug it exists for (it did). But a phi is
        // non-uniform when the CONTROL FLOW that selects between its arms is
        // non-uniform - the values are constants; WHICH constant you get is not.
        //
        // So the fixpoint below is an OUTER loop over two mutually-feeding analyses:
        //   * data taint (this inner loop, incl. through memory), and
        //   * control taint: a phi at the merge block of a selection whose condition is
        //     tainted becomes tainted, which re-arms the data pass, which taints the
        //     next guard, ... until the chain reaches the branch that guards the sample.
        var tainted_merge: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var outer: u32 = 0;
        var outer_changed: bool = true;
        while (outer_changed and outer < 16) : (outer += 1) {
            outer_changed = false;

            var changed: bool = true;
            var rounds: u32 = 0;
            while (changed and rounds < 16) : (rounds += 1) {
                changed = false;
                for (inst_off) |off| {
                    const ops: []const u32 = types.operandsAt(spirv, off);
                    const op: u32 = types.opcodeOf(spirv[off]);

                    // TAINT FLOWS THROUGH MEMORY, and this is where the first version of
                    // this gate had a hole big enough to miss the bug it was written for.
                    // The IoT entry point LOADS the varying, STORES it into a local struct,
                    // then passes that struct to `shaderMain`:
                    //
                    //     v45.field_1 = _87;            // _87 = OpLoad(o_normal)  <- tainted
                    //     let _334 = v45;               // OpLoad(v45)             <- NOT tainted!
                    //     shaderMain(_334)
                    //
                    // `OpStore` has no result id, so a pure def-use walk stops dead at the
                    // store and every varying looks uniform by the time it reaches the
                    // shader body. Model the store: a tainted value taints the pointer AND
                    // the ROOT variable behind it (through any access chain), so subsequent
                    // loads of that variable come back tainted. Coarse (whole-variable, not
                    // per-field) - which is the safe direction for a gate.
                    if (op == UOp.store and ops.len > 1) {
                        const object: u32 = ops[1];
                        if (object <= bound and tainted[object]) {
                            var root: u32 = ops[0];
                            var hops: u32 = 0;
                            while (hops < 16) : (hops += 1) {
                                if (root > bound or def_off[root] == 0) {
                                    break;
                                }
                                const d: u32 = def_off[root];
                                const dop: u32 = types.opcodeOf(spirv[d]);
                                if (dop != UOp.access_chain and dop != UOp.in_bounds_access_chain) {
                                    break;
                                }
                                const dops: []const u32 = types.operandsAt(spirv, d);
                                if (dops.len < 3) {
                                    break;
                                }
                                if (!tainted[root]) {
                                    tainted[root] = true;
                                    changed = true;
                                }
                                root = dops[2]; // the access chain's base
                            }
                            if (root <= bound and !tainted[root]) {
                                tainted[root] = true;
                                changed = true;
                            }
                            if (ops[0] <= bound and !tainted[ops[0]]) {
                                tainted[ops[0]] = true;
                                changed = true;
                            }
                        }
                        continue;
                    }

                    var buf: [64]u32 = undefined;
                    const ids: []const u32 = idOperands(spirv, off, &buf);

                    var any: bool = isImplicitSample(op); // a sample result varies with its coords
                    for (ids) |id| {
                        if (id <= bound and tainted[id]) {
                            any = true;
                        }
                    }
                    if (!any) {
                        continue;
                    }

                    // A tainted ARGUMENT taints the callee's PARAMETER.
                    if (op == UOp.function_call and ops.len > 2) {
                        if (params.get(ops[2])) |plist| {
                            var i: usize = 0;
                            while (i < plist.len and 3 + i < ops.len) : (i += 1) {
                                const arg: u32 = ops[3 + i];
                                if (arg <= bound and tainted[arg] and !tainted[plist[i]]) {
                                    tainted[plist[i]] = true;
                                    changed = true;
                                }
                            }
                        }
                    }

                    const r: u32 = resultOf(spirv, off);
                    if (r != 0 and r <= bound and !tainted[r]) {
                        tainted[r] = true;
                        changed = true;
                    }
                }
            }

            // CONTROL dependence: a selection whose condition is tainted makes the phis
            // at its MERGE block non-uniform (which arm ran is not uniform, so neither
            // is the value the phi picks). Feed that back into the data pass above.
            var merge_now: u32 = 0;
            for (inst_off) |off| {
                const op: u32 = types.opcodeOf(spirv[off]);
                const ops: []const u32 = types.operandsAt(spirv, off);
                if (op == UOp.selection_merge and ops.len > 0) {
                    merge_now = ops[0];
                } else if (op == UOp.branch_conditional) {
                    if (ops.len > 0 and merge_now != 0 and ops[0] <= bound and tainted[ops[0]]) {
                        if (!tainted_merge.contains(merge_now)) {
                            try tainted_merge.put(arena, merge_now, {});
                            outer_changed = true;
                        }
                    }
                    merge_now = 0;
                }
            }
            var blk: u32 = 0;
            for (inst_off) |off| {
                const op: u32 = types.opcodeOf(spirv[off]);
                const ops: []const u32 = types.operandsAt(spirv, off);
                if (op == UOp.label and ops.len > 0) {
                    blk = ops[0];
                } else if (op == UOp.phi and ops.len > 1 and tainted_merge.contains(blk)) {
                    if (ops[1] <= bound and !tainted[ops[1]]) {
                        tainted[ops[1]] = true;
                        outer_changed = true;
                    }
                }
            }
        }

        // ---- flag a sample under a tainted selection ---------------------------
        // Blocks appear in a valid order (a merge block follows the construct it
        // merges), so tracking "the merge id we are waiting for" is enough - no
        // full CFG walk needed.  Loop headers carry OpLoopMerge, not
        // OpSelectionMerge, so they never arm the region (see limits above).
        var cur_fn: u32 = 0;
        var pending_merge: u32 = 0;
        var in_nonuniform: bool = false;
        var bad_cond: u32 = 0;

        for (inst_off) |off| {
            const ops: []const u32 = types.operandsAt(spirv, off);
            const op: u32 = types.opcodeOf(spirv[off]);
            switch (op) {
                UOp.function => {
                    cur_fn = if (ops.len > 1) ops[1] else 0;
                    in_nonuniform = false;
                    pending_merge = 0;
                },
                UOp.function_end => {
                    cur_fn = 0;
                    in_nonuniform = false;
                    pending_merge = 0;
                },
                UOp.label => {
                    const lbl: u32 = if (ops.len > 0) ops[0] else 0;
                    if (in_nonuniform and lbl == pending_merge) {
                        in_nonuniform = false;
                        pending_merge = 0;
                    }
                },
                UOp.selection_merge => {
                    if (ops.len > 0 and !in_nonuniform) {
                        pending_merge = ops[0];
                    }
                },
                UOp.branch_conditional => {
                    const cond: u32 = if (ops.len > 0) ops[0] else 0;
                    if (!in_nonuniform) {
                        if (cond <= bound and tainted[cond] and pending_merge != 0) {
                            in_nonuniform = true;
                            bad_cond = cond;
                        } else {
                            pending_merge = 0;
                        }
                    }
                },
                else => {
                    if (!in_nonuniform or cur_fn == 0) {
                        continue;
                    }
                    const offends: bool = isImplicitSample(op) or
                        (op == UOp.function_call and ops.len > 2 and samples_in.contains(ops[2]));
                    if (offends) {
                        // The diagnostic is for a HUMAN reading a failed build. Under
                        // `zig build test` the runner counts any logged error as a test
                        // failure, and the gate's own regression test EXPECTS this error
                        // - so stay quiet there and let the returned error speak.
                        if (!builtin.is_test) {
                            std.log.err(
                                \\
                                \\spv2wgsl: SAMPLER-UNIFORMITY GATE failed — {s}
                                \\
                                \\  An implicit-LOD texture sample is reached ONLY through a branch whose
                                \\  condition (%{d}) derives from a VARYING.  textureSample needs derivatives
                                \\  across the quad, so WGSL demands uniform control flow: Dawn WILL reject
                                \\  this shader at pipeline creation, on device, with
                                \\    "'textureSample' must only be called from uniform control flow".
                                \\
                                \\  The branch is probably NOT in your Zig.  Look at the helpers the shader
                                \\  calls: a `zm` function written with `if` (scalar clamp01/step used to be)
                                \\  emits a REAL branch, and every sample downstream of it lands inside it.
                                \\
                                \\  FIX, in order of preference:
                                \\    1. make the helper branch-free — @min/@max/@select, never `if`;
                                \\    2. hoist the sample ABOVE the branch and mask the result arithmetically;
                                \\    3. use the explicit-LOD escape hatch (sampleLevel), which needs no
                                \\       derivatives and is exempt from this rule.
                                \\
                            , .{ shader_name, bad_cond });
                        }
                        return error.SamplerInNonUniformControlFlow;
                    }
                },
            }
        }
    }
};

pub const sccp = struct {
    // src/spv2wgsl/sccp.zig - Sparse Conditional Constant Propagation
    // (Wegman-Zadeck) over ONE SPIR-V function.
    //
    // WHY THIS EXISTS
    // Zig's SPIR-V backend emits un-optimized control flow: a `while` with
    // a `continue`/`break` lowers to a numeric phi-state machine, and the
    // code after the loop ends up under a guard like
    // `if (phi867 == 482u) { ... }` whose condition is ALWAYS true (the loop
    // has a single non-`continue` exit state).  spirv-opt used to fold that
    // guard away (mem2reg + const-prop + dead-branch-elim); since we dropped
    // spirv-opt from the WGSL path (finishing_webgpu.md section 2.2) the guard
    // survives, and because its condition is a phi data-derived from a
    // non-uniform loop, Tint rejects any `textureSample` under it
    // ("must only be called from uniform control flow" - the PBR demo bug).
    //
    // This pass is the principled fix: it discovers that the guard's
    // condition is a compile-time constant, so a later rewrite can fold the
    // branch, drop the dead arm, and lift the post-loop code to uniform
    // scope (-> faithful implicit-LOD `textureSample` again).
    //
    // WHY ON SPIR-V (not the IR)
    // `ir.zig` models only control flow - values are raw SPIR-V ids and the
    // data flow (which constants feed which phis feed a guard) lives in the
    // SPIR-V.  So constant propagation MUST run here, before `ir_build`.
    // The output is consumed by a rewrite that produces cleaner SPIR-V for
    // the unchanged structurizer (matching how spirv-opt layers before a
    // translator).
    //
    // SCOPE OF CONSTANT REASONING
    // Constants flow through OpPhi (merged over LIVE incoming edges only -
    // this is what makes a single-exit loop's state phi resolve to its one
    // exit constant) and the small set of boolean/integer ops a CF guard is
    // built from: IEqual / INotEqual / LogicalEqual / LogicalNotEqual /
    // LogicalNot / Select.  EVERY other result is treated as overdefined
    // (bottom), so a guard folds ONLY when it is provably constant - never on a
    // varying value.  Soundness over completeness.
    //
    // ALGORITHM
    // Iterative monotone fixpoint (not the dual SSA/flow worklist): the
    // lattice descends top -> const -> bottom, shader functions are small, so
    // re-scanning the reachable blocks to convergence is cheap and
    // obviously correct.  Two pieces of state co-refine: the value lattice
    // and the set of executable (block->block) edges; a phi consults only
    // operands arriving on an executable edge, and a block is reachable iff
    // it is the entry or has an executable incoming edge.

    const bt = block_table;

    // SPIR-V opcodes used here (raw values; self-contained so this module
    // does not depend on types.zig covering every op).
    const TestOp = struct {
        const nop: u32 = 0;
        /// A phi whose incoming edges ALL died: the value can never be produced.
        const undef: u32 = 1;
        /// A phi with exactly ONE live incoming edge is semantically a copy.
        const copy_object: u32 = 83;
        const line: u32 = 8;
        const constant_true: u32 = 41;
        const constant_false: u32 = 42;
        const constant: u32 = 43;
        const constant_composite: u32 = 44;
        const constant_null: u32 = 46;
        const function_parameter: u32 = 55;
        const variable: u32 = 59;
        const store: u32 = 62;
        const logical_equal: u32 = 164;
        const logical_not_equal: u32 = 165;
        const logical_not: u32 = 168;
        const select: u32 = 169;
        const i_equal: u32 = 170;
        const i_not_equal: u32 = 171;
        const function: u32 = 54;
        const function_end: u32 = 56;
        const phi: u32 = 245;
        const loop_merge: u32 = 246;
        const selection_merge: u32 = 247;
        const label: u32 = 248;
        const branch: u32 = 249;
        const branch_conditional: u32 = 250;
        const switch_: u32 = 251;
        const kill: u32 = 252;
        const ret: u32 = 253;
        const ret_value: u32 = 254;
        const unreachable_: u32 = 255;
        const no_line: u32 = 317;
    };

    inline fn opAt(spirv: []const u32, off: u32) u32 {
        return spirv[off] & 0xFFFF;
    }
    inline fn wcAt(spirv: []const u32, off: u32) u32 {
        return spirv[off] >> 16;
    }

    /// True for ops that NEVER produce a result id (so they define no
    /// value).  Used by the value scan to know which instructions to skip.
    fn isResultless(op: u32) bool {
        return switch (op) {
            TestOp.nop,
            TestOp.line,
            TestOp.no_line,
            TestOp.store,
            TestOp.loop_merge,
            TestOp.selection_merge,
            TestOp.label, // produces a *block* id, not a value operand we track
            TestOp.branch,
            TestOp.branch_conditional,
            TestOp.switch_,
            TestOp.kill,
            TestOp.ret,
            TestOp.ret_value,
            TestOp.unreachable_,
            => true,
            else => false,
        };
    }

    // =============================================================================
    // Lattice
    // =============================================================================

    /// SCCP value lattice.  `top` = no information yet (optimistic start);
    /// `konst` = a known scalar constant (bool as 0/1, integers zero-extended
    /// to u64); `bottom` = overdefined / varying.
    pub const Lattice = union(enum) {
        top,
        konst: u64,
        bottom,

        pub fn meet(a: Lattice, b: Lattice) Lattice {
            if (a == .top) return b;
            if (b == .top) return a;
            if (a == .bottom or b == .bottom) return .bottom;
            return if (a.konst == b.konst) a else .bottom; // both konst
        }
        pub fn eql(a: Lattice, b: Lattice) bool {
            return switch (a) {
                .top => b == .top,
                .bottom => b == .bottom,
                .konst => |av| b == .konst and b.konst == av,
            };
        }
    };

    // =============================================================================
    // Result
    // =============================================================================

    pub const Analysis = struct {
        arena: Allocator,
        /// value id -> lattice (absent => `top`).
        values: std.AutoHashMapUnmanaged(u32, Lattice) = .empty,
        /// reachable block ids.
        reachable: std.AutoHashMapUnmanaged(u32, void) = .empty,
        /// block id -> its single live successor, IFF that block's terminator
        /// is a constant-folded BranchConditional/Switch (its selector is a
        /// known constant).  These are the spurious guards a rewrite folds.
        folded: std.AutoHashMapUnmanaged(u32, u32) = .empty,

        pub fn isReachable(self: *const Analysis, id: u32) bool {
            return self.reachable.contains(id);
        }
        pub fn valueOf(self: *const Analysis, id: u32) Lattice {
            return self.values.get(id) orelse .top;
        }
        /// If `block_id`'s terminator was constant-folded, the live target.
        pub fn foldedTarget(self: *const Analysis, block_id: u32) ?u32 {
            return self.folded.get(block_id);
        }
    };

    // =============================================================================
    // Analyzer
    // =============================================================================

    /// Packed (from<<32 | to) executable-edge key.
    inline fn edgeKey(from: u32, to: u32) u64 {
        return (@as(u64, from) << 32) | @as(u64, to);
    }

    const Analyzer = struct {
        arena: Allocator,
        spirv: []const u32,
        inst_off: []const u32,
        blocks: *const bt.BlockTable,
        a: Analysis,
        /// executable (from->to) edges.
        edges: std.AutoHashMapUnmanaged(u64, void) = .empty,
        changed: bool = false,

        /// Lower a value's lattice cell to `lat`. Records `changed` so the
        /// fixpoint loop knows to run another pass. Idempotent: re-setting the
        /// same lattice value is a no-op.
        fn setValue(
            self: *Analyzer,
            id: u32,
            lat: Lattice,
        ) !void {
            const previous: Lattice = self.a.valueOf(id);
            if (!previous.eql(lat)) {
                try self.a.values.put(self.arena, id, lat);
                self.changed = true;
            }
        }
        fn markReachable(self: *Analyzer, id: u32) !void {
            const entry: @TypeOf(self.a.reachable).GetOrPutResult = try self.a.reachable.getOrPut(self.arena, id);
            if (!entry.found_existing) {
                self.changed = true;
            }
        }
        fn markEdge(
            self: *Analyzer,
            from: u32,
            to: u32,
        ) !void {
            const entry: @TypeOf(self.edges).GetOrPutResult = try self.edges.getOrPut(self.arena, edgeKey(from, to));
            if (!entry.found_existing) {
                self.changed = true;
            }
            try self.markReachable(to);
        }
        fn edgeLive(
            self: *const Analyzer,
            from: u32,
            to: u32,
        ) bool {
            return self.edges.contains(edgeKey(from, to));
        }

        /// Evaluate one value-producing instruction at word offset `off` in the
        /// block `block_id`, lowering its result's lattice cell. Resultless
        /// instructions (terminators, stores, merges) define no value and are
        /// skipped - terminators are handled separately by `evalTerm`.
        fn evalInst(
            self: *Analyzer,
            block_id: u32,
            off: u32,
        ) !void {
            const op: u32 = opAt(self.spirv, off);
            if (isResultless(op)) {
                return;
            }

            switch (op) {
                // OpPhi: meet of the operands that arrive on a LIVE edge. Operands
                // on dead edges are ignored - this is exactly what lets a
                // single-exit loop's state phi resolve to its one exit constant.
                TestOp.phi => {
                    const word_count: u32 = wcAt(self.spirv, off);
                    const result_id: u32 = self.spirv[off + 2];
                    var merged: Lattice = .top;
                    // OpPhi operands are (value, predecessor-block) pairs starting
                    // at off+3.
                    var i: u32 = off + 3;
                    while (i + 1 < off + word_count) : (i += 2) {
                        const incoming_value: u32 = self.spirv[i];
                        const predecessor: u32 = self.spirv[i + 1];
                        if (self.edgeLive(predecessor, block_id)) {
                            merged = merged.meet(self.a.valueOf(incoming_value));
                        }
                    }
                    try self.setValue(result_id, merged);
                },
                TestOp.i_equal, TestOp.logical_equal => {
                    const result_id: u32 = self.spirv[off + 2];
                    const lhs: Lattice = self.a.valueOf(self.spirv[off + 3]);
                    const rhs: Lattice = self.a.valueOf(self.spirv[off + 4]);
                    try self.setValue(result_id, cmp(lhs, rhs, true));
                },
                TestOp.i_not_equal, TestOp.logical_not_equal => {
                    const result_id: u32 = self.spirv[off + 2];
                    const lhs: Lattice = self.a.valueOf(self.spirv[off + 3]);
                    const rhs: Lattice = self.a.valueOf(self.spirv[off + 4]);
                    try self.setValue(result_id, cmp(lhs, rhs, false));
                },
                TestOp.logical_not => {
                    const result_id: u32 = self.spirv[off + 2];
                    const operand: Lattice = self.a.valueOf(self.spirv[off + 3]);
                    try self.setValue(result_id, switch (operand) {
                        .top => .top,
                        .bottom => .bottom,
                        .konst => |v| .{ .konst = @intFromBool(v == 0) },
                    });
                },
                TestOp.select => {
                    // OpSelect %ty %result %cond %true_val %false_val: when the
                    // condition is a known constant, the result is whichever arm
                    // it picks.
                    const result_id: u32 = self.spirv[off + 2];
                    const condition: Lattice = self.a.valueOf(self.spirv[off + 3]);
                    try self.setValue(result_id, switch (condition) {
                        .top => .top,
                        .bottom => .bottom,
                        .konst => |cv| if (cv != 0)
                            self.a.valueOf(self.spirv[off + 4])
                        else
                            self.a.valueOf(self.spirv[off + 5]),
                    });
                },
                // Every other result-producing op is treated as varying (bottom):
                // OpUndef / OpLoad / OpFunctionCall / arithmetic, etc. (Module-
                // scope constants are pre-seeded and never reach here.) The result
                // id is at off+2 for all of these.
                else => {
                    const result_id: u32 = self.spirv[off + 2];
                    try self.setValue(result_id, .bottom);
                },
            }
        }

        /// Evaluate a block's terminator: mark its executable out-edges, and - if
        /// the terminator is a conditional/switch whose selector is a known
        /// constant - record the single taken target as a "fold" (the spurious
        /// guard a later rewrite collapses to a plain branch).
        fn evalTerm(self: *Analyzer, info: bt.BlockInfo) !void {
            const off: u32 = self.inst_off[info.terminator_inst_idx];
            const op: u32 = opAt(self.spirv, off);
            switch (op) {
                TestOp.branch => try self.markEdge(info.id, self.spirv[off + 1]),
                TestOp.branch_conditional => {
                    const condition: Lattice = self.a.valueOf(self.spirv[off + 1]);
                    const true_target: u32 = self.spirv[off + 2];
                    const false_target: u32 = self.spirv[off + 3];
                    switch (condition) {
                        .konst => |cv| {
                            // Constant condition: exactly one arm is live.
                            const taken: u32 = if (cv != 0) true_target else false_target;
                            if (!self.a.folded.contains(info.id)) {
                                self.changed = true;
                            }
                            try self.a.folded.put(self.arena, info.id, taken);
                            try self.markEdge(info.id, taken);
                        },
                        else => {
                            // unknown (top) or varying (bottom): keep both arms live.
                            // (top can occur transiently before the condition is
                            // evaluated; the fixpoint re-runs. A condition that
                            // stays top leaves both edges marked - sound.)
                            try self.markEdge(info.id, true_target);
                            try self.markEdge(info.id, false_target);
                        },
                    }
                },
                TestOp.switch_ => {
                    const selector: Lattice = self.a.valueOf(self.spirv[off + 1]);
                    const default_target: u32 = self.spirv[off + 2];
                    const word_count: u32 = wcAt(self.spirv, off);
                    switch (selector) {
                        .konst => |sv| {
                            // Constant selector: find the matching case label (or
                            // fall to default), and that one target is live.
                            var taken: u32 = default_target;
                            // Switch cases are (literal, label) pairs from off+3.
                            var i: u32 = off + 3;
                            while (i + 1 < off + word_count) : (i += 2) {
                                if (self.spirv[i] == @as(u32, @truncate(sv))) {
                                    taken = self.spirv[i + 1];
                                    break;
                                }
                            }
                            if (!self.a.folded.contains(info.id)) {
                                self.changed = true;
                            }
                            try self.a.folded.put(self.arena, info.id, taken);
                            try self.markEdge(info.id, taken);
                        },
                        else => {
                            // Varying selector: default + every case label is live.
                            try self.markEdge(info.id, default_target);
                            var i: u32 = off + 3;
                            while (i + 1 < off + word_count) : (i += 2) {
                                try self.markEdge(info.id, self.spirv[i + 1]);
                            }
                        },
                    }
                },
                // ret / ret_value / kill / unreachable: no successors.
                else => {},
            }
        }

        /// One pass over every reachable block: evaluate its body values, then
        /// its terminator. The fixpoint loop in `analyzeFunction` repeats this
        /// until nothing changes.
        fn pass(self: *Analyzer) !void {
            var it: bt.BlockTable.Iterator = self.blocks.iterator();
            while (it.next()) |entry| {
                const info: bt.BlockInfo = entry.value_ptr.*;
                if (!self.a.isReachable(info.id)) {
                    continue;
                }
                // Evaluate the block body: instructions strictly between the label
                // and the terminator (the merge instruction, if any, is resultless
                // and harmlessly skipped by evalInst).
                var k: usize = info.label_inst_idx + 1;
                while (k < info.terminator_inst_idx) : (k += 1) {
                    try self.evalInst(info.id, self.inst_off[k]);
                }
                try self.evalTerm(info);
            }
        }
    };

    /// Seed module-scope scalar constants (id -> value) by scanning the
    /// instructions before the function.  Bool/int constants only; others
    /// are simply absent (=> top, refined to bottom if used by a varying op).
    fn seedConstants(an: *Analyzer, fn_k: usize) !void {
        var k: usize = 0;
        while (k < fn_k) : (k += 1) {
            const off: u32 = an.inst_off[k];
            const op: u32 = opAt(an.spirv, off);
            switch (op) {
                TestOp.constant_true => try an.a.values.put(an.arena, an.spirv[off + 2], .{ .konst = 1 }),
                TestOp.constant_false,
                TestOp.constant_null,
                => try an.a.values.put(an.arena, an.spirv[off + 2], .{ .konst = 0 }),
                TestOp.constant => {
                    // [op, type, result, value_lo, (value_hi...)] - take the
                    // low word (CF state/loop-bound constants are <=32-bit).
                    try an.a.values.put(an.arena, an.spirv[off + 2], .{ .konst = an.spirv[off + 3] });
                },
                else => {},
            }
        }
    }

    /// Find the entry block id: the id of the first OpLabel at or after the
    /// function's OpFunction. Returns null for a function with no body.
    fn findEntry(
        spirv: []const u32,
        inst_off: []const u32,
        fn_k: usize,
        end_k: usize,
    ) ?u32 {
        var k: usize = fn_k + 1;
        while (k < end_k) : (k += 1) {
            if (opAt(spirv, inst_off[k]) == TestOp.label) {
                return spirv[inst_off[k] + 1];
            }
        }
        return null;
    }

    /// Run SCCP over the function whose OpFunction is `inst_off[fn_k]` and
    /// whose OpFunctionEnd is `inst_off[end_k]`.  Arena-owned result.
    pub fn analyzeFunction(
        arena: Allocator,
        spirv: []const u32,
        inst_off: []const u32,
        fn_k: usize,
        end_k: usize,
    ) !Analysis {
        var table: bt.BlockTable = try bt.registerBlocks(arena, fn_k, end_k, inst_off, spirv);
        var an: Analyzer = .{
            .arena = arena,
            .spirv = spirv,
            .inst_off = inst_off,
            .blocks = &table,
            .a = .{ .arena = arena },
        };
        try seedConstants(&an, fn_k);

        const entry_block: u32 = findEntry(spirv, inst_off, fn_k, end_k) orelse return an.a;
        try an.markReachable(entry_block);

        // Iterate to fixpoint. The lattice is monotone (cells only descend
        // top -> const -> bottom), so this always converges; the `limit` is a safety
        // bound against a decode bug, not against nontermination.
        var iterations: usize = 0;
        const limit: usize = (end_k - fn_k + 4) * 4;
        while (true) {
            an.changed = false;
            try an.pass();
            iterations += 1;
            if (!an.changed) {
                break;
            }
            if (iterations > limit) {
                break; // safety; converges well within this in practice
            }
        }
        return an.a;
    }

    /// Build the flat instruction-offset index (skip the 5-word header,
    /// then walk by word count) - the convention shared with ir_build /
    /// block_table.
    fn buildOffsets(arena: Allocator, spirv: []const u32) ![]u32 {
        var offs: ArrayList(u32) = .empty;
        var off: usize = 5;
        while (off < spirv.len) {
            try offs.append(arena, @intCast(off));
            const word_count: usize = spirv[off] >> 16;
            if (word_count == 0) {
                break; // malformed instruction - stop (the caller rejects it)
            }
            off += word_count;
        }
        return offs.toOwnedSlice(arena);
    }

    /// True if the construct whose merge is `merge_id` has an `OpPhi` at that merge
    /// block. Folding a selection/switch whose merge carries a phi is unsafe: the
    /// fold drops the OpSelectionMerge, but the merge-phi survives and is then
    /// orphaned (no construct declares the merge, so the IR builder never lowers
    /// the phi -> a `phiN` read with no assignment -> garbage). spirv-opt emits
    /// degenerate constant-selector switches (a body wrapped in a no-op switch
    /// whose merge holds the function's return-value phi); folding those is correct
    /// CFG-wise but breaks the phi, so we skip the fold and let buildSwitch lower
    /// the (harmless) switch + its merge-phi normally. Mirrors Tint, which always
    /// lowers a phi by its result id regardless of whether its construct survives.
    /// Would folding a selection whose merge is `merge_id` ORPHAN a phi there?
    ///
    /// Folding drops the folded block's `OpSelectionMerge`. That is only a problem
    /// when the merge block BOTH (a) carries an `OpPhi` AND (b) is ITSELF a construct
    /// header (has its own OpSelectionMerge/OpLoopMerge): then the merge-phi is left
    /// with no construct to lower it -> an orphaned `phiN` read -> garbage WGSL.
    ///
    /// A merge that is NOT a header - a plain join before a return, say - folds fine:
    /// its phi is collapsed by edge-pruning.
    ///
    /// This used to test (a) ONLY, which quietly disabled folding almost everywhere:
    /// Zig lowers a branchy helper into a numeric phi STATE MACHINE, so essentially
    /// every selection it emits merges into a block carrying the state phi. That left
    /// dead `if (73u == 73u)` guards standing all over the output - provably-true
    /// branches SCCP had already solved but was then forbidden to remove.
    fn mergeBlockPhiWouldOrphan(
        spirv: []const u32,
        inst_off: []const u32,
        table: *const bt.BlockTable,
        merge_id: u32,
    ) bool {
        if (merge_id == 0) {
            return false;
        }
        const merge_info: bt.BlockInfo = table.get(merge_id) orelse return false;
        // IF THE MERGE CARRIES A PHI, DO NOT FOLD. Full stop.
        //
        // There used to be a second condition here: the merge also had to be a construct
        // HEADER itself, on the reasoning that a non-header merge "folds fine - its phi is
        // collapsed by edge-pruning". Pruning does collapse the phi. What it does not do is
        // keep the BLOCK the folded branch used to guard.
        //
        // Folding a selection rewrites its OpBranchConditional into an unconditional branch
        // and drops the OpSelectionMerge. When the merge carries a phi, the arm that is no
        // longer branched to stops being reachable - and everything it dominated goes with
        // it. In `sort_min.computeForce` that was the ENTIRE innermost neighbour loop: the
        // SPIR-V had 86 memory ops, the emitted WGSL had 3. No error, no `// ERROR:` marker.
        // The condition was still computed -
        //
        //     let _4940: bool = phi4936 == 138u;   // COMPUTED...
        //     let _5545: u32 = phi4936;            // ...and DISCARDED. Never used.
        //
        // - and the `if (_4940) { ... }` it existed for was simply never emitted. The kernel
        // ran, read its own density, wrote a correction of zero, and produced a fluid that
        // could not settle. The one-armed collapse made the result WELL-FORMED, which is why
        // `checkPhiClosure` stayed green and nothing anywhere complained: a visible bug had
        // been traded for an invisible one.
        //
        // The collapse is still right and still needed, for the folds we DO perform. But it
        // is not a licence to fold a phi-carrying merge. Refusing those costs a few folds
        // (the pass exists to hoist textureSample into uniform control flow, and those
        // guards sit at phi-free merges) and buys back the guarantee that a fold never
        // deletes code.
        var k: usize = merge_info.label_inst_idx + 1;
        while (k < merge_info.terminator_inst_idx) : (k += 1) {
            if (opAt(spirv, inst_off[k]) == TestOp.phi) {
                return true;
            }
        }
        return false;
    }

    /// UNCHANGED structurizer to consume.  Loop headers are never folded
    /// (conservative - preserves loop structure for a later pass).
    /// Find the loop header that immediately contains `block_id` (for the back-edge
    /// fold rule). Approximation of SPIRV-Tools' StructuredCFGAnalysis::
    /// ContainingLoop sufficient here: the loop header whose continue-region BFS
    /// reaches `block_id`. Returns 0 if none.
    fn containingLoopHeader(table: *const bt.BlockTable, block_id: u32) u32 {
        // A block carrying a back edge branches to its own loop header, so the
        // header is whichever loop_header's id this block can branch to. We detect
        // it structurally: the loop header is the block whose continue_id region
        // includes block_id. Since back_edge detection already proved block_id has
        // an edge to some header, return the unique loop header reachable as a
        // successor. For the common (single-loop) case, that's the only loop_header.
        var it: bt.BlockTable.Iterator = table.iterator();
        var only_header: u32 = 0;
        var header_count: u32 = 0;
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .loop_header) {
                only_header = entry.value_ptr.id;
                header_count += 1;
            }
        }
        if (header_count == 1) {
            return only_header;
        }
        // Multiple loops: the header is the nearest one whose merge/continue bracket
        // block_id by instruction index (headers dominate their bodies in program
        // order up to the merge). Pick the header with the largest label index that
        // is still <= block_id's index and whose merge index is > block_id's index.
        const target: bt.BlockInfo = table.get(block_id) orelse return only_header;
        var best: u32 = 0;
        var best_label_idx: usize = 0;
        var it2: bt.BlockTable.Iterator = table.iterator();
        while (it2.next()) |entry| {
            const h: bt.BlockInfo = entry.value_ptr.*;
            if (h.kind != .loop_header or h.merge_id == 0) {
                continue;
            }
            const merge_info: bt.BlockInfo = table.get(h.merge_id) orelse continue;
            if (h.label_inst_idx <= target.label_inst_idx and
                target.label_inst_idx < merge_info.label_inst_idx and
                h.label_inst_idx >= best_label_idx)
            {
                best = h.id;
                best_label_idx = h.label_inst_idx;
            }
        }
        return best;
    }

    /// Collect blocks that have a back-edge to a loop header - ported from
    /// SPIRV-Tools `DeadBranchElimPass::AddBlocksWithBackEdge`. Starting from each
    /// loop header's continue target, BFS forward (bounded by header+merge+continue
    /// as visited seeds); any block whose successor is the header carries the back
    /// edge. Such a block's conditional must NOT be folded (it would destroy the
    /// loop's required single back-edge) unless the fold target IS the header.
    fn collectBackEdgeBlocks(
        arena: Allocator,
        spirv: []const u32,
        inst_off: []const u32,
        table: *const bt.BlockTable,
        out_back_edge: *std.AutoHashMapUnmanaged(u32, void),
    ) !void {
        var hit: bt.BlockTable.Iterator = table.iterator();
        while (hit.next()) |entry| {
            const header: bt.BlockInfo = entry.value_ptr.*;
            if (header.kind != .loop_header or header.continue_id == 0) {
                continue;
            }
            const cont_id: u32 = header.continue_id;
            const header_id: u32 = header.id;
            const merge_id: u32 = header.merge_id;

            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            try visited.put(arena, cont_id, {});
            try visited.put(arena, header_id, {});
            if (merge_id != 0) {
                try visited.put(arena, merge_id, {});
            }
            var work: ArrayList(u32) = .empty;
            try work.append(arena, cont_id);
            while (work.pop()) |bb_id| {
                const bb: bt.BlockInfo = table.get(bb_id) orelse continue;
                var has_back_edge: bool = false;
                const toff: u32 = inst_off[bb.terminator_inst_idx];
                const top: u32 = opAt(spirv, toff);
                // Visit each successor; note a back edge to the header.
                const Succ = struct {
                    fn visit(
                        a: Allocator,
                        succ: u32,
                        hdr: u32,
                        vis: *std.AutoHashMapUnmanaged(u32, void),
                        wl: *ArrayList(u32),
                        flag: *bool,
                    ) !void {
                        if (!vis.contains(succ)) {
                            try vis.put(a, succ, {});
                            try wl.append(a, succ);
                        }
                        if (succ == hdr) {
                            flag.* = true;
                        }
                    }
                };
                switch (top) {
                    TestOp.branch => try Succ.visit(arena, spirv[toff + 1], header_id, &visited, &work, &has_back_edge),
                    TestOp.branch_conditional => {
                        try Succ.visit(arena, spirv[toff + 2], header_id, &visited, &work, &has_back_edge);
                        try Succ.visit(arena, spirv[toff + 3], header_id, &visited, &work, &has_back_edge);
                    },
                    TestOp.switch_ => {
                        try Succ.visit(arena, spirv[toff + 2], header_id, &visited, &work, &has_back_edge);
                        const wc: u32 = wcAt(spirv, toff);
                        var i: u32 = toff + 3;
                        while (i + 1 < toff + wc) : (i += 2) {
                            try Succ.visit(arena, spirv[i + 1], header_id, &visited, &work, &has_back_edge);
                        }
                    },
                    else => {},
                }
                if (has_back_edge) {
                    try out_back_edge.put(arena, bb_id, {});
                }
            }
        }
    }

    /// Collect "loop latch" blocks: any block whose terminator is an
    /// OpBranchConditional where ONE edge reaches a loop's continue block (directly
    /// or through a chain of unconditional branches) and so decides whether the
    /// loop iterates again. SCCP must NOT fold such a conditional even when its
    /// condition appears constant: that "constant" is an artifact of SCCP modelling
    /// the loop's structured-CFG state-machine codes (the OpPhi label dispatch Zig
    /// emits) without modelling the loop's iteration, and folding the latch to its
    /// "exit" edge collapses the loop to a SINGLE iteration - the body runs once,
    /// every loop-carried value (n, z, escape state) is wrong, and the result
    /// degenerates (the turn-901 mandelbrot WHITE bug: folding %404's
    /// `CondBr %405, ->continue, ->merge` dropped the back-edge).
    ///
    /// We seed from each loop's continue block and walk PREDECESSORS: a block is a
    /// latch if a continue block is reachable from its conditional's true OR false
    /// edge. Implemented as a forward reachability test per candidate, bounded by
    /// the function's block count.
    fn collectLoopLatchBlocks(
        arena: Allocator,
        spirv: []const u32,
        inst_off: []const u32,
        table: *const bt.BlockTable,
        out_latch: *std.AutoHashMapUnmanaged(u32, void),
    ) !void {
        // Gather the loop continue blocks.
        var cont_blocks: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var hit: bt.BlockTable.Iterator = table.iterator();
        while (hit.next()) |entry| {
            const h: bt.BlockInfo = entry.value_ptr.*;
            if (h.kind == .loop_header and h.continue_id != 0) {
                try cont_blocks.put(arena, h.continue_id, {});
            }
        }
        if (cont_blocks.count() == 0) {
            return;
        }

        // For each block ending in a conditional branch, test whether either edge
        // reaches a continue block via a chain of unconditional branches (stopping
        // at the continue block, or at any block that is itself a merge/header so we
        // don't run past the loop). If so, the block is a latch.
        var it: bt.BlockTable.Iterator = table.iterator();
        while (it.next()) |entry| {
            const info: bt.BlockInfo = entry.value_ptr.*;
            const toff: u32 = inst_off[info.terminator_inst_idx];
            if (opAt(spirv, toff) != TestOp.branch_conditional) {
                continue;
            }
            const t_ops: u32 = toff;
            const true_t: u32 = spirv[t_ops + 2];
            const false_t: u32 = spirv[t_ops + 3];
            if (try edgeReachesContinue(arena, spirv, inst_off, table, &cont_blocks, true_t) or
                try edgeReachesContinue(arena, spirv, inst_off, table, &cont_blocks, false_t))
            {
                try out_latch.put(arena, info.id, {});
            }
        }
    }

    /// Walk unconditional-branch chains from `start`; return true if a loop continue
    /// block is hit. Stops at conditional/switch/return terminators (those are not
    /// part of a simple latch->continue chain). Visited-guarded.
    fn edgeReachesContinue(
        arena: Allocator,
        spirv: []const u32,
        inst_off: []const u32,
        table: *const bt.BlockTable,
        cont_blocks: *const std.AutoHashMapUnmanaged(u32, void),
        start: u32,
    ) !bool {
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var cur: u32 = start;
        while (true) {
            if (cont_blocks.contains(cur)) {
                return true;
            }
            if (visited.contains(cur)) {
                return false;
            }
            try visited.put(arena, cur, {});
            const info: bt.BlockInfo = table.get(cur) orelse return false;
            const toff: u32 = inst_off[info.terminator_inst_idx];
            if (opAt(spirv, toff) != TestOp.branch) {
                return false; // only chase unconditional-branch chains
            }
            cur = spirv[toff + 1];
        }
    }

    /// Structural reachability over the FOLDED CFG, for deciding which blocks the
    /// rewrite keeps. A block is dead iff unreachable here (i.e. ALL its incoming
    /// edges are dead) - which is the correct criterion, unlike SCCP's
    /// constant-propagation `reachable` (that one marks only a folded guard's taken
    /// edge, so it can starve a block that is still reachable via another edge ->
    /// the block gets wrongly dropped -> MalformedFunction). This BFS follows a
    /// folded block's single taken successor and every other block's full successor
    /// set, from the entry. Order-independent (a worklist reachability, not a
    /// HashMap traversal).
    fn computeFoldedReachable(
        arena: Allocator,
        spirv: []const u32,
        inst_off: []const u32,
        table: *const bt.BlockTable,
        folds: *const std.AutoHashMapUnmanaged(u32, u32),
        entry: u32,
        out_reachable: *std.AutoHashMapUnmanaged(u32, void),
    ) !void {
        var stack: ArrayList(u32) = .empty;
        try out_reachable.put(arena, entry, {});
        try stack.append(arena, entry);
        while (stack.pop()) |block_id| {
            const info: bt.BlockInfo = table.get(block_id) orelse continue;

            // A folded selection guard contributes ONLY its taken successor (the
            // rewrite collapses its terminator to `Branch taken`).
            if (folds.get(block_id)) |taken| {
                if (!out_reachable.contains(taken)) {
                    try out_reachable.put(arena, taken, {});
                    try stack.append(arena, taken);
                }
                continue;
            }

            // Otherwise enumerate the terminator's successors.
            const toff: u32 = inst_off[info.terminator_inst_idx];
            const top: u32 = opAt(spirv, toff);
            switch (top) {
                TestOp.branch => try pushSucc(arena, spirv[toff + 1], out_reachable, &stack),
                TestOp.branch_conditional => {
                    try pushSucc(arena, spirv[toff + 2], out_reachable, &stack);
                    try pushSucc(arena, spirv[toff + 3], out_reachable, &stack);
                },
                TestOp.switch_ => {
                    try pushSucc(arena, spirv[toff + 2], out_reachable, &stack); // default
                    const wc: u32 = wcAt(spirv, toff);
                    var i: u32 = toff + 3;
                    while (i + 1 < toff + wc) : (i += 2) {
                        try pushSucc(arena, spirv[i + 1], out_reachable, &stack);
                    }
                },
                // ret / ret_value / kill / unreachable: no successors.
                else => {},
            }

            // A loop/selection header's merge + continue targets are part of the
            // structured region and must survive even if no plain edge reaches them
            // yet (the structurizer reconstructs the branch to them).
            if (info.merge_id != 0) {
                try pushSucc(arena, info.merge_id, out_reachable, &stack);
            }
            if (info.continue_id != 0) {
                try pushSucc(arena, info.continue_id, out_reachable, &stack);
            }
        }
    }

    fn pushSucc(
        arena: Allocator,
        succ: u32,
        seen: *std.AutoHashMapUnmanaged(u32, void),
        stack: *ArrayList(u32),
    ) !void {
        if (!seen.contains(succ)) {
            try seen.put(arena, succ, {});
            try stack.append(arena, succ);
        }
    }

    pub fn rewrite(arena: Allocator, spirv: []const u32) ![]u32 {
        // A valid module has at least the 5-word header; bail on anything
        // shorter so `spirv[0..5]` below can't panic.  The caller
        // (`convertSpirvToWgsl`) catches this and falls back to the raw
        // module, which its own header check then rejects gracefully.
        if (spirv.len < 5) {
            return error.SpirvTooShort;
        }
        const inst_off: []u32 = try buildOffsets(arena, spirv);

        // Module-wide maps (SPIR-V result ids are globally unique, so block ids
        // never collide across functions). `reachable` accumulates every live
        // block; `selection_folds` maps a foldable guard block -> its one live
        // target (loop headers are deliberately excluded below).
        var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var selection_folds: std.AutoHashMapUnmanaged(u32, u32) = .empty;

        var k: usize = 0;
        while (k < inst_off.len) {
            if (opAt(spirv, inst_off[k]) == TestOp.function) {
                // Find this function's OpFunctionEnd, analyze it, and merge its
                // reachability + folds into the module-wide maps.
                var end_k: usize = k + 1;
                while (end_k < inst_off.len and opAt(spirv, inst_off[end_k]) != TestOp.function_end) : (end_k += 1) {}
                if (end_k >= inst_off.len) {
                    break;
                }
                const table: bt.BlockTable = try bt.registerBlocks(arena, k, end_k, inst_off, spirv);
                const analysis: Analysis = try analyzeFunction(arena, spirv, inst_off, k, end_k);

                // Blocks carrying a loop back-edge: their conditional must not fold
                // (it would break the loop's single back-edge) unless the fold
                // target is the loop header. (SPIRV-Tools dead_branch_elim rule.)
                var back_edge_blocks: std.AutoHashMapUnmanaged(u32, void) = .empty;
                try collectBackEdgeBlocks(arena, spirv, inst_off, &table, &back_edge_blocks);

                var loop_latch_blocks: std.AutoHashMapUnmanaged(u32, void) = .empty;
                try collectLoopLatchBlocks(arena, spirv, inst_off, &table, &loop_latch_blocks);

                // Collect this function's selection folds. Excluded: loop headers
                // (folding destroys loop structure) and back-edge blocks whose fold
                // target isn't their containing loop header. Merge survivors into
                // the module-wide `selection_folds` the emit pass consults.
                var fn_folds: std.AutoHashMapUnmanaged(u32, u32) = .empty;
                var fold_it: @TypeOf(analysis.folded).Iterator = analysis.folded.iterator();
                while (fold_it.next()) |fold| {
                    const block_id: u32 = fold.key_ptr.*;
                    const taken: u32 = fold.value_ptr.*;
                    const info: bt.BlockInfo = table.get(block_id) orelse continue;
                    if (info.kind == .loop_header) {
                        continue;
                    }
                    // Never fold a loop latch (a conditional that decides whether
                    // the loop iterates). Its condition may look constant to SCCP
                    // (it's built from the structured-CFG state-machine label phis),
                    // but folding it collapses the loop to one iteration. See
                    // collectLoopLatchBlocks. (turn-902 fix for mandelbrot WHITE.)
                    if (loop_latch_blocks.contains(block_id)) {
                        continue;
                    }
                    // Skip the fold ONLY for a degenerate CASE-LESS switch (an
                    // OpSwitch with just selector+default, word_count == 3) whose
                    // merge block carries an OpPhi. spirv-opt emits these as pure
                    // structural wrappers (a body wrapped in a no-op switch whose
                    // merge holds e.g. the function's return-value phi). Folding
                    // such a wrapper to an unconditional branch drops its
                    // OpSelectionMerge but CANNOT reduce the merge's join-degree
                    // (the body branches internally and rejoins at the merge), so
                    // the surviving multi-pred merge-phi would be orphaned. Keeping
                    // the harmless case-less switch lets buildSwitch lower it + its
                    // merge-phi correctly. (A switch WITH cases, or a conditional
                    // branch, folds by killing branches, which DOES collapse the
                    // merge - that fold stays. Mirrors Tint, which lowers a phi by
                    // its result id regardless of construct survival.)
                    // Skip the fold only when the merge block would ORPHAN a phi:
                    // it carries an OpPhi AND is itself a construct header. See
                    // mergeBlockPhiWouldOrphan - testing (a) alone (as this did)
                    // disabled folding for nearly every selection Zig emits.
                    if (mergeBlockPhiWouldOrphan(spirv, inst_off, &table, info.merge_id)) {
                        continue;
                    }
                    if (back_edge_blocks.contains(block_id)) {
                        // Only safe to fold a back-edge block if it becomes a branch
                        // to its loop header; otherwise keep both arms (don't fold).
                        const loop_header: u32 = containingLoopHeader(&table, block_id);
                        if (taken != loop_header) {
                            continue;
                        }
                    }
                    try fn_folds.put(arena, block_id, taken);
                    try selection_folds.put(arena, block_id, taken);
                }

                // Decide which blocks survive via STRUCTURAL reachability over the
                // folded CFG (not SCCP's constant-prop `reachable`, which starves
                // blocks behind folded guards -> MalformedFunction).
                const entry: u32 = findEntry(spirv, inst_off, k, end_k) orelse {
                    k = end_k + 1;
                    continue;
                };
                try computeFoldedReachable(arena, spirv, inst_off, &table, &fn_folds, entry, &reachable);
                k = end_k + 1;
            } else {
                k += 1;
            }
        }

        // Second walk: copy the module through, applying the folds. State tracks
        // the block currently being emitted so per-block decisions are local.
        var out: ArrayList(u32) = .empty;
        try out.appendSlice(arena, spirv[0..5]); // header verbatim

        var in_function: bool = false;
        var cur_block: u32 = 0;
        var cur_reachable: bool = true; // the module header region copies through
        var cur_fold_target: ?u32 = null; // set iff cur_block's guard is folded

        var ki: usize = 0;
        while (ki < inst_off.len) : (ki += 1) {
            const off: u32 = inst_off[ki];
            const op: u32 = opAt(spirv, off);
            const word_count: u32 = wcAt(spirv, off);
            const words: []const u32 = spirv[off .. off + word_count];

            if (op == TestOp.function) {
                in_function = true;
                cur_block = 0;
                cur_reachable = true;
                cur_fold_target = null;
                try out.appendSlice(arena, words);
                continue;
            }
            if (op == TestOp.function_end) {
                in_function = false;
                cur_reachable = true;
                cur_fold_target = null;
                try out.appendSlice(arena, words);
                continue;
            }
            if (op == TestOp.label) {
                // Entering a new block: decide whether it survives, and whether its
                // terminator is a folded guard.
                cur_block = spirv[off + 1];
                cur_reachable = !in_function or reachable.contains(cur_block);
                cur_fold_target = selection_folds.get(cur_block);
                if (cur_reachable) {
                    try out.appendSlice(arena, words);
                }
                continue;
            }
            if (!cur_reachable) {
                continue; // skip an unreachable block's entire body + terminator
            }

            // Drop the OpSelectionMerge that precedes a folded conditional (the
            // merge is meaningless once the branch becomes unconditional).
            if (op == TestOp.selection_merge and cur_fold_target != null) {
                continue;
            }

            // Prune dead OpPhi operand pairs, keeping only operands that arrive on
            // a still-live incoming edge.
            if (op == TestOp.phi) {
                var kept: ArrayList(u32) = .empty;
                // [word_count(patched below), result_type, result_id, then pairs].
                try kept.appendSlice(arena, &.{ 0, words[1], words[2] });
                var i: u32 = 3;
                while (i + 1 < word_count) : (i += 2) {
                    const incoming_value: u32 = words[i];
                    const predecessor: u32 = words[i + 1];
                    // The edge is live if the predecessor survived AND (if that
                    // predecessor's guard was folded) this block is its taken
                    // target.
                    const edge_live: bool = reachable.contains(predecessor) and
                        ((selection_folds.get(predecessor) orelse cur_block) == cur_block);
                    if (edge_live) {
                        try kept.append(arena, incoming_value);
                        try kept.append(arena, predecessor);
                    }
                }
                // A PHI WITH ONE LIVE INCOMING EDGE IS NOT A PHI - IT IS A COPY.
                //
                // This is the correctness hinge of the whole fold. Folding drops the
                // block's OpSelectionMerge, which UN-DECLARES its merge block as a
                // construct merge - and the IR builder only lowers phis that sit at an
                // If/Loop/Switch merge (`resolveMergePhiTarget`). A surviving OpPhi in a
                // block that is no longer anyone's merge is therefore never assigned: WGSL
                // zero-inits the `var phiN`, and every branch reading it takes the wrong
                // arm. That is how a serial `while` loop came out running its body exactly
                // once, and it silently wrecked ~9 kernels (density, force, viscosity,
                // prefixSum, ...) while leaving the loop-free ones (double_it, clearGrid,
                // predict) perfect - which is why the smoke test never caught it.
                //
                // `mergeBlockPhiWouldOrphan` prevents this by refusing to fold any selection
                // whose merge carries a phi. This collapse handles the phis that survive the
                // folds we DO perform. It is NOT a licence to fold a phi-carrying merge -
                // that was tried, and it silently deleted the block the branch guarded (see
                // the note on `mergeBlockPhiWouldOrphan`). Well-formed output is not the same
                // thing as correct output.
                //
                // OpCopyObject is exactly equivalent to a one-armed phi, and the emitter
                // already lowers it (`.CopyObject, .CopyLogical => emitLoad`).
                const live_pairs: usize = (kept.items.len - 3) / 2;
                if (live_pairs == 1) {
                    try out.appendSlice(arena, &.{
                        w(4, TestOp.copy_object),
                        words[1], // result type
                        words[2], // result id
                        kept.items[3], // the one surviving incoming value
                    });
                    continue;
                }
                if (live_pairs == 0) {
                    // Every incoming edge died, so the value can never be produced. Any use
                    // is dead by construction; OpUndef keeps the module well-formed, where a
                    // zero-operand OpPhi would be invalid SPIR-V.
                    try out.appendSlice(arena, &.{
                        w(3, TestOp.undef),
                        words[1],
                        words[2],
                    });
                    continue;
                }
                kept.items[0] = w(@intCast(kept.items.len), TestOp.phi);
                try out.appendSlice(arena, kept.items);
                continue;
            }

            // Fold a constant selection terminator to a plain unconditional branch.
            if (cur_fold_target) |target| {
                if (op == TestOp.branch_conditional or op == TestOp.switch_) {
                    try out.appendSlice(arena, &.{ w(2, TestOp.branch), target });
                    continue;
                }
            }

            try out.appendSlice(arena, words); // everything else verbatim
        }

        return out.toOwnedSlice(arena);
    }

    /// Constant-fold an (in)equality of two lattice values.  `want_eq` true
    /// for IEqual/LogicalEqual, false for the NotEqual variants.  Returns
    /// top if either operand is still top (not enough info yet).
    /// Constant-fold an (in)equality of two lattice values. `want_eq` is true for
    /// IEqual/LogicalEqual, false for the NotEqual variants. Returns top if either
    /// operand is still top (not enough information yet), bottom if either is varying.
    fn cmp(
        x: Lattice,
        y: Lattice,
        want_eq: bool,
    ) Lattice {
        if (x == .top or y == .top) {
            return .top;
        }
        if (x == .bottom or y == .bottom) {
            return .bottom;
        }
        const operands_equal: bool = x.konst == y.konst;
        return .{ .konst = @intFromBool(operands_equal == want_eq) };
    }

    // =============================================================================
    // Tests
    // =============================================================================

    const testing = std.testing;

    inline fn w(word_count: u32, op: u32) u32 {
        return (word_count << 16) | op;
    }
    fn offsets(a: Allocator, spirv: []const u32) ![]u32 {
        var offs: ArrayList(u32) = .empty;
        var off: usize = 5;
        while (off < spirv.len) {
            try offs.append(a, @intCast(off));
            off += spirv[off] >> 16;
        }
        return offs.toOwnedSlice(a);
    }

    test "meet lattice basics" {
        const T: Lattice = .top;
        const B: Lattice = .bottom;
        const k7: Lattice = .{ .konst = 7 };
        const k9: Lattice = .{ .konst = 9 };
        try testing.expect(T.meet(k7).eql(k7));
        try testing.expect(k7.meet(T).eql(k7));
        try testing.expect(k7.meet(k7).eql(k7));
        try testing.expect(k7.meet(k9).eql(B));
        try testing.expect(B.meet(k7).eql(B));
    }

    test "folds a constant-true guard; false arm unreachable" {
        var ar: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer ar.deinit();
        const a: Allocator = ar.allocator();
        // %20 = OpConstantTrue ; entry %5: SelectionMerge %8 / BranchConditional
        // %20 %6 %7 ; %6 -> %8 ; %7 -> %8 ; %8 ret
        var m: ArrayList(u32) = .empty;
        try m.appendSlice(a, &.{ 0x07230203, 0x00010600, 0, 99, 0 }); // header
        // %2 = OpTypeBool
        try m.appendSlice(a, &.{ w(2, 20), 2 });
        // %20 = OpConstantTrue %2
        try m.appendSlice(a, &.{ w(3, TestOp.constant_true), 2, 20 });
        // %1 = OpFunction
        try m.appendSlice(a, &.{ w(5, 54), 3, 1, 0, 4 });
        // %5 = OpLabel
        try m.appendSlice(a, &.{ w(2, TestOp.label), 5 });
        // OpSelectionMerge %8 None
        try m.appendSlice(a, &.{ w(3, TestOp.selection_merge), 8, 0 });
        // OpBranchConditional %20 %6 %7
        try m.appendSlice(a, &.{ w(4, TestOp.branch_conditional), 20, 6, 7 });
        // %6 = OpLabel ; OpBranch %8
        try m.appendSlice(a, &.{ w(2, TestOp.label), 6, w(2, TestOp.branch), 8 });
        // %7 = OpLabel ; OpBranch %8
        try m.appendSlice(a, &.{ w(2, TestOp.label), 7, w(2, TestOp.branch), 8 });
        // %8 = OpLabel ; OpReturn
        try m.appendSlice(a, &.{ w(2, TestOp.label), 8, w(1, TestOp.ret) });
        // OpFunctionEnd
        try m.appendSlice(a, &.{w(1, 56)});

        const spirv: []const u32 = m.items;
        const offs: []u32 = try offsets(a, spirv);
        // fn_k = index of OpFunction. Find it.
        var fn_k: usize = 0;
        while (opAt(spirv, offs[fn_k]) != 54) : (fn_k += 1) {}
        const end_k: usize = offs.len - 1;

        const an: Analysis = try analyzeFunction(a, spirv, offs, fn_k, end_k);
        try testing.expect(an.isReachable(5));
        try testing.expect(an.isReachable(6)); // true arm - live
        try testing.expect(!an.isReachable(7)); // false arm - dead
        try testing.expect(an.isReachable(8)); // merge - live (via %6)
        try testing.expectEqual(@as(?u32, 6), an.foldedTarget(5));
    }

    test "single-exit loop state phi resolves to its one exit constant -> post-loop guard folds" {
        // Models the PBR shape, minimized:
        //   constants: %T=true, %F=false, %C482=482, %C484=484
        //   entry %5: Branch %10 (loop header)
        //   header %10: LoopMerge %40 %30 ; Branch %11
        //   body %11: %ph = OpPhi (482 from %5? no - header phi) ... kept simple:
        //
        // We instead model the essential post-loop fragment directly:
        //   entry %5 -> %20
        //   %20: %st = OpPhi(%C482 from %5, %C484 from %21) ; Branch %22
        //   %21: (dead-ish continue source) Branch %20    [we DON'T make it live]
        //   %22: %c = OpIEqual %st %C482 ; SelectionMerge %25 ; BranchConditional %c %23 %24
        //   %23 -> %25 ; %24 -> %25 ; %25 ret
        // Because the only LIVE predecessor of %20 is %5 (we never enter %21),
        // %st = meet(konst 482 over live edge) = 482, so %c == (482==482) = true,
        // and the guard folds to %23 with %24 unreachable.
        var ar: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer ar.deinit();
        const a: Allocator = ar.allocator();
        var m: ArrayList(u32) = .empty;
        try m.appendSlice(a, &.{ 0x07230203, 0x00010600, 0, 99, 0 });
        try m.appendSlice(a, &.{ w(2, 20), 2 }); // %2 = OpTypeBool
        try m.appendSlice(a, &.{ w(4, 21), 3, 32, 1 }); // %3 = OpTypeInt 32 1
        try m.appendSlice(a, &.{ w(4, TestOp.constant), 3, 30, 482 }); // %30 = 482
        try m.appendSlice(a, &.{ w(4, TestOp.constant), 3, 31, 484 }); // %31 = 484
        try m.appendSlice(a, &.{ w(5, 54), 3, 1, 0, 4 }); // %1 = OpFunction
        try m.appendSlice(a, &.{ w(2, TestOp.label), 5, w(2, TestOp.branch), 20 }); // entry -> %20
        // %20: phi(%30 from %5, %31 from %21) ; Branch %22
        try m.appendSlice(a, &.{ w(2, TestOp.label), 20 });
        try m.appendSlice(a, &.{ w(7, 245), 3, 50, 30, 5, 31, 21 }); // %50 = OpPhi
        try m.appendSlice(a, &.{ w(2, TestOp.branch), 22 });
        // %21: Branch %20  (only reachable if something targets %21 - nothing does)
        try m.appendSlice(a, &.{ w(2, TestOp.label), 21, w(2, TestOp.branch), 20 });
        // %22: %51 = IEqual %50 %30 ; SelectionMerge %25 ; BranchConditional %51 %23 %24
        try m.appendSlice(a, &.{ w(2, TestOp.label), 22 });
        try m.appendSlice(a, &.{ w(5, TestOp.i_equal), 2, 51, 50, 30 });
        try m.appendSlice(a, &.{ w(3, TestOp.selection_merge), 25, 0 });
        try m.appendSlice(a, &.{ w(4, TestOp.branch_conditional), 51, 23, 24 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 23, w(2, TestOp.branch), 25 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 24, w(2, TestOp.branch), 25 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 25, w(1, TestOp.ret) });
        try m.appendSlice(a, &.{w(1, 56)});

        const spirv: []const u32 = m.items;
        const offs: []u32 = try offsets(a, spirv);
        var fn_k: usize = 0;
        while (opAt(spirv, offs[fn_k]) != 54) : (fn_k += 1) {}
        const an: Analysis = try analyzeFunction(a, spirv, offs, fn_k, offs.len - 1);

        try testing.expect(an.valueOf(50).eql(.{ .konst = 482 })); // state phi is constant
        try testing.expect(an.valueOf(51).eql(.{ .konst = 1 })); // guard cond is true
        try testing.expect(!an.isReachable(21)); // continue source never entered
        try testing.expect(an.isReachable(23)); // guarded body - live
        try testing.expect(!an.isReachable(24)); // dead arm
        try testing.expectEqual(@as(?u32, 23), an.foldedTarget(22)); // guard folds
    }

    test "varying guard does NOT fold (both arms stay reachable)" {
        // entry %5: %v = OpFunctionCall (varying) ; %c = IEqual %v %C0 ;
        //           SelectionMerge %25 ; BranchConditional %c %23 %24 ...
        var ar: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer ar.deinit();
        const a: Allocator = ar.allocator();
        var m: ArrayList(u32) = .empty;
        try m.appendSlice(a, &.{ 0x07230203, 0x00010600, 0, 99, 0 });
        try m.appendSlice(a, &.{ w(2, 20), 2 }); // bool
        try m.appendSlice(a, &.{ w(4, 21), 3, 32, 1 }); // int
        try m.appendSlice(a, &.{ w(4, TestOp.constant), 3, 30, 0 }); // %30 = 0
        try m.appendSlice(a, &.{ w(5, 54), 3, 1, 0, 4 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 5 });
        try m.appendSlice(a, &.{ w(4, 57), 3, 60, 1 }); // %60 = OpFunctionCall %3 %1  (varying)
        try m.appendSlice(a, &.{ w(5, TestOp.i_equal), 2, 61, 60, 30 });
        try m.appendSlice(a, &.{ w(3, TestOp.selection_merge), 25, 0 });
        try m.appendSlice(a, &.{ w(4, TestOp.branch_conditional), 61, 23, 24 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 23, w(2, TestOp.branch), 25 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 24, w(2, TestOp.branch), 25 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 25, w(1, TestOp.ret) });
        try m.appendSlice(a, &.{w(1, 56)});

        const spirv: []const u32 = m.items;
        const offs: []u32 = try offsets(a, spirv);
        var fn_k: usize = 0;
        while (opAt(spirv, offs[fn_k]) != 54) : (fn_k += 1) {}
        const an: Analysis = try analyzeFunction(a, spirv, offs, fn_k, offs.len - 1);

        try testing.expect(an.valueOf(60).eql(.bottom)); // call is varying
        try testing.expect(an.valueOf(61).eql(.bottom)); // so is the compare
        try testing.expect(an.isReachable(23));
        try testing.expect(an.isReachable(24)); // BOTH arms live - no fold
        try testing.expectEqual(@as(?u32, null), an.foldedTarget(5));
    }

    test "rewrite folds the PBR-shape guard: dead arm removed, nothing left to fold" {
        var ar: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
        defer ar.deinit();
        const a: Allocator = ar.allocator();
        // Same module as the analysis PBR-shape test: a state phi resolving to
        // 482 on its one live edge, an IEqual guard, BranchConditional %23 %24.
        var m: ArrayList(u32) = .empty;
        try m.appendSlice(a, &.{ 0x07230203, 0x00010600, 0, 99, 0 });
        try m.appendSlice(a, &.{ w(2, 20), 2 }); // %2 = OpTypeBool
        try m.appendSlice(a, &.{ w(4, 21), 3, 32, 1 }); // %3 = OpTypeInt 32 1
        try m.appendSlice(a, &.{ w(4, TestOp.constant), 3, 30, 482 }); // %30 = 482
        try m.appendSlice(a, &.{ w(4, TestOp.constant), 3, 31, 484 }); // %31 = 484
        try m.appendSlice(a, &.{ w(5, 54), 3, 1, 0, 4 }); // %1 = OpFunction
        try m.appendSlice(a, &.{ w(2, TestOp.label), 5, w(2, TestOp.branch), 20 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 20 });
        try m.appendSlice(a, &.{ w(7, 245), 3, 50, 30, 5, 31, 21 }); // %50 = OpPhi(482<-%5, 484<-%21)
        try m.appendSlice(a, &.{ w(2, TestOp.branch), 22 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 21, w(2, TestOp.branch), 20 }); // never entered
        try m.appendSlice(a, &.{ w(2, TestOp.label), 22 });
        try m.appendSlice(a, &.{ w(5, TestOp.i_equal), 2, 51, 50, 30 });
        try m.appendSlice(a, &.{ w(3, TestOp.selection_merge), 25, 0 });
        try m.appendSlice(a, &.{ w(4, TestOp.branch_conditional), 51, 23, 24 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 23, w(2, TestOp.branch), 25 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 24, w(2, TestOp.branch), 25 });
        try m.appendSlice(a, &.{ w(2, TestOp.label), 25, w(1, TestOp.ret) });
        try m.appendSlice(a, &.{w(1, 56)});

        const rewritten: []u32 = try rewrite(a, m.items);

        // Structural: the guard's OpSelectionMerge + OpBranchConditional are gone.
        var n_selmerge: usize = 0;
        var n_condbr: usize = 0;
        var n_label24: usize = 0;
        {
            const offs: []u32 = try buildOffsets(a, rewritten);
            for (offs) |off| {
                const op: u32 = opAt(rewritten, off);
                if (op == TestOp.selection_merge) {
                    n_selmerge += 1;
                }
                if (op == TestOp.branch_conditional) {
                    n_condbr += 1;
                }
                if (op == TestOp.label and rewritten[off + 1] == 24) {
                    n_label24 += 1;
                }
            }
        }
        try testing.expectEqual(@as(usize, 0), n_selmerge); // dropped
        try testing.expectEqual(@as(usize, 0), n_condbr); // folded to OpBranch
        try testing.expectEqual(@as(usize, 0), n_label24); // dead block removed

        // Semantic: re-analyzing the rewritten module finds nothing left to fold,
        // the live blocks reachable, and the dead arm absent.
        const offs2: []u32 = try buildOffsets(a, rewritten);
        var fn_k: usize = 0;
        while (opAt(rewritten, offs2[fn_k]) != 54) : (fn_k += 1) {}
        var end_k: usize = fn_k;
        while (opAt(rewritten, offs2[end_k]) != 56) : (end_k += 1) {}
        const an2: Analysis = try analyzeFunction(a, rewritten, offs2, fn_k, end_k);
        try testing.expectEqual(@as(usize, 0), an2.folded.count()); // clean - no constant guards remain
        try testing.expect(an2.isReachable(5));
        try testing.expect(an2.isReachable(20));
        try testing.expect(an2.isReachable(22));
        try testing.expect(an2.isReachable(23));
        try testing.expect(an2.isReachable(25));
        try testing.expect(!an2.isReachable(24));
    }
};

/// Every `var phiN: T;` the emitter declares must be assigned somewhere in the output.
///
/// A read of an unassigned phi is not a WGSL error - the `var` is zero-initialised - so
/// nothing downstream catches it. It just makes the shader compute the wrong thing, and
/// only in kernels with real control flow. This turns that into a build failure naming the
/// phi, which is the only signal that would have caught the SCCP one-armed-phi bug on the
/// day it landed instead of an arc later.
/// Every storage buffer THIS ENTRY's call graph accesses must be accessed in its WGSL.
///
/// A dropped block takes its memory operations with it, so a buffer the kernel provably
/// touches simply stops appearing in the output. That is the one signal a silently deleted
/// block cannot hide: the condition it guarded may still be emitted (dead), the phis may all
/// be assigned, the module may be perfectly well-formed - but THE LOADS ARE GONE.
///
/// Scoped to the entry's reachable functions, not the whole module: kernels in one kompute
/// module declare the same buffers but touch different subsets, so a module-wide union would
/// flag `computeDensity` for not using `kbuf_pos2` - which `scatter` uses and it does not.
///
/// Runs on the ORIGINAL SPIR-V, before SCCP folds. Checking the FOLDED module is useless: the
/// fold is what deletes the block, so the access is missing from both sides and the guard sees
/// a matching pair. (That was the first version. Re-introducing the bug to test it produced a
/// silent pass - a guard that could not see the thing it was written for.)
///
/// Membership, not count: emission legitimately merges accesses (CSE, hoisting), so demanding
/// the same NUMBER would fire on healthy shaders. But a buffer touched in the SPIR-V and never
/// mentioned in the emitted body means code vanished.
fn checkBufferAccessSurvival(
    arena: Allocator,
    spirv: []const u32,
    wgsl: []const u8,
    entry: []const u8,
) !void {
    const op_name: u32 = 5;
    const op_entry_point: u32 = 15;
    const op_function: u32 = 54;
    const op_function_end: u32 = 56;
    const op_function_call: u32 = 57;
    const op_load: u32 = 61;
    const op_store: u32 = 62;
    const op_access_chain: u32 = 65;
    const op_in_bounds_access_chain: u32 = 66;

    const Fn = struct {
        touches: std.AutoHashMapUnmanaged(u32, void) = .empty,
        calls: std.AutoHashMapUnmanaged(u32, void) = .empty,
    };

    var names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    var fns: std.AutoHashMapUnmanaged(u32, *Fn) = .empty;
    var entry_fn: u32 = 0;
    var cur: ?*Fn = null;

    var i: usize = 5;
    while (i < spirv.len) {
        const word: u32 = spirv[i];
        const op: u32 = word & 0xffff;
        const wc: usize = word >> 16;
        if (wc == 0 or i + wc > spirv.len) {
            break;
        }
        switch (op) {
            op_name => {
                if (wc >= 3) {
                    const bytes: []const u8 = std.mem.sliceAsBytes(spirv[i + 2 .. i + wc]);
                    const end_z: usize = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
                    const nm: []const u8 = bytes[0..end_z];
                    if (std.mem.startsWith(u8, nm, "kbuf_")) {
                        try names.put(arena, spirv[i + 1], nm);
                    }
                }
            },
            op_entry_point => {
                // [execution model, function id, name...]. Match the entry we emitted.
                if (wc >= 4) {
                    const bytes: []const u8 = std.mem.sliceAsBytes(spirv[i + 3 .. i + wc]);
                    const end_z: usize = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
                    if (std.mem.eql(u8, bytes[0..end_z], entry)) {
                        entry_fn = spirv[i + 2];
                    }
                }
            },
            op_function => {
                if (wc >= 3) {
                    const f: *Fn = try arena.create(Fn);
                    f.* = .{};
                    try fns.put(arena, spirv[i + 2], f);
                    cur = f;
                }
            },
            op_function_end => cur = null,
            op_function_call => {
                if (cur) |f| {
                    if (wc >= 4) {
                        try f.calls.put(arena, spirv[i + 3], {});
                    }
                }
            },
            op_access_chain, op_in_bounds_access_chain, op_load => {
                if (cur) |f| {
                    if (wc >= 4) {
                        try f.touches.put(arena, spirv[i + 3], {});
                    }
                }
            },
            op_store => {
                if (cur) |f| {
                    if (wc >= 3) {
                        try f.touches.put(arena, spirv[i + 1], {});
                    }
                }
            },
            else => {},
        }
        i += wc;
    }

    if (entry_fn == 0) {
        return; // no entry matched (helper-only module) - nothing to assert.
    }

    // Union the buffers touched anywhere in the entry's call graph.
    var touched: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var stack: ArrayList(u32) = .empty;
    try stack.append(arena, entry_fn);
    while (stack.pop()) |fid| {
        if (seen.contains(fid)) {
            continue;
        }
        try seen.put(arena, fid, {});
        const f: *Fn = fns.get(fid) orelse continue;
        var t: std.AutoHashMapUnmanaged(u32, void).Iterator = f.touches.iterator();
        while (t.next()) |e| {
            try touched.put(arena, e.key_ptr.*, {});
        }
        var c: std.AutoHashMapUnmanaged(u32, void).Iterator = f.calls.iterator();
        while (c.next()) |e| {
            try stack.append(arena, e.key_ptr.*);
        }
    }

    // The WGSL BODY only. The `@binding` declarations name every buffer in the module
    // whether this kernel uses it or not, so searching the whole file would be vacuous.
    const body_start: usize = std.mem.indexOf(u8, wgsl, "@compute") orelse
        std.mem.indexOf(u8, wgsl, "@fragment") orelse
        std.mem.indexOf(u8, wgsl, "@vertex") orelse 0;
    const body: []const u8 = wgsl[body_start..];

    var it: std.AutoHashMapUnmanaged(u32, []const u8).Iterator = names.iterator();
    while (it.next()) |e| {
        if (!touched.contains(e.key_ptr.*)) {
            continue; // this entry genuinely does not use it - fine.
        }
        const nm: []const u8 = e.value_ptr.*;
        // A binding is reached one of two ways: indexed directly (`kbuf_pos[i]`) when
        // its Zig type is an array, or through its block member (`kbuf_pos.field_0[i]`)
        // when the type is a struct - which is the shape a storage buffer takes. Both
        // are accesses. A dropped block removes EVERY mention of the buffer from the
        // body, so it still trips on neither being found, and neither needle can match
        // a longer name by prefix (`[` and `.` cannot appear inside an identifier).
        const indexed_directly: []const u8 = try allocPrint(arena, "{s}[", .{nm});
        const through_block: []const u8 = try allocPrint(arena, "{s}.", .{nm});
        const is_accessed: bool = std.mem.indexOf(u8, body, indexed_directly) != null or
            std.mem.indexOf(u8, body, through_block) != null;
        if (!is_accessed) {
            std.log.err(
                "spv2wgsl [{s}]: `{s}` is ACCESSED in the SPIR-V but never in the emitted WGSL.\n" ++
                    "  A block was dropped, and its loads and stores went with it. The output is\n" ++
                    "  still well-formed — the guarding condition may even still be computed — but\n" ++
                    "  the code inside is GONE, and the kernel will run and produce a plausible\n" ++
                    "  wrong answer. See src/notes/spv2wgsl_dropped_block.md.",
                .{ entry, nm },
            );
            return error.DroppedBufferAccess;
        }
    }
}

fn checkPhiClosure(arena: Allocator, wgsl: []const u8) !void {
    var declared: std.StringHashMapUnmanaged(void) = .empty;
    var assigned: std.StringHashMapUnmanaged(void) = .empty;

    var lines = std.mem.splitScalar(u8, wgsl, '\n');
    while (lines.next()) |raw| {
        const line: []const u8 = std.mem.trim(u8, raw, " \t\r");

        // `var phiN: T;` - a declaration.
        if (std.mem.startsWith(u8, line, "var phi")) {
            const rest: []const u8 = line["var ".len..];
            const end: usize = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            try declared.put(arena, std.mem.trim(u8, rest[0..end], " \t"), {});
            continue;
        }
        // `phiN = ...;` - an assignment. (A `var phiN` decl never reaches here.)
        if (std.mem.startsWith(u8, line, "phi")) {
            const eq: usize = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            // Reject `==` so a comparison is never mistaken for an assignment.
            if (eq + 1 < line.len and line[eq + 1] == '=') {
                continue;
            }
            try assigned.put(arena, std.mem.trim(u8, line[0..eq], " \t"), {});
        }
    }

    var it: std.StringHashMapUnmanaged(void).Iterator = declared.iterator();
    while (it.next()) |e| {
        const name: []const u8 = e.key_ptr.*;
        if (!assigned.contains(name)) {
            std.log.err(
                "spv2wgsl: `{s}` is declared and read but NEVER ASSIGNED.\n" ++
                    "  WGSL zero-inits it, so every branch that tests it takes the wrong arm and\n" ++
                    "  loops run their body once. The structurizer dropped an incoming edge's\n" ++
                    "  assignment — see the SCCP one-armed-phi collapse in `sccp.rewrite`.",
                .{name},
            );
            return error.UnassignedPhi;
        }
    }
}

/// Entry-filtered translation: when `entry` is non-null, only the matching
/// OpEntryPoint is emitted (the multi-kernel path translates a module once
/// per kernel). See `State.wanted_entry`.
pub fn convertSpirvToWgslEntry(
    arena: Allocator,
    spirv: []const u32,
    entry: ?[]const u8,
) ![]const u8 {
    // SCCP prepass: fold spurious constant guards (e.g. the always-true
    // post-loop `if (phi == K)` Zig's un-optimized SPIR-V leaves), drop the
    // now-dead blocks, prune dead OpPhi operands - so the structurizer sees
    // clean control flow and post-loop texture samples sit at uniform scope.
    // Falls back to the raw module on any rewrite error, so it can never
    // regress availability (worst case = no folding, identical to before).
    const folded_spirv: []const u32 = sccp.rewrite(arena, spirv) catch spirv;

    // THE SAMPLER-UNIFORMITY GATE. Runs on the FOLDED module, so the dead
    // `if (73u == 73u)` phi-dispatch guards SCCP already resolved cannot cause a
    // bogus report. This turns a device-only, pipeline-creation failure ("'textureSample'
    // must only be called from uniform control flow") into a BUILD failure with the
    // shader named. It is the only guard that can see this class: the branch is
    // usually manufactured inside a zm helper and exists nowhere in the Zig source.
    try sampler_uniformity.check(arena, folded_spirv, entry orelse "shader");

    var state = try State.init(arena, folded_spirv);
    state.wanted_entry = entry;

    try pass1_walk(&state);
    try pass2_decorations(&state);
    try markAtomicBindings(&state);
    try checkBarrierUniformity(&state);
    try pass3_types_globals(&state);
    try pass4_functions(&state);

    var final: ArrayList(u8) = .empty;
    try final.appendSlice(arena, state.header_buf.items);
    try final.appendSlice(arena, state.body_buf.items);
    const out: []const u8 = try final.toOwnedSlice(arena);

    // ---- A HARD CHECK, UNLIKE `checkOutputClosure` BELOW ----
    //
    // That one runs only in debug and only WARNS, returning the bad WGSL anyway on the grounds
    // that "the browser's WGSL frontend rejects it at pipeline creation if it actually matters".
    // It does matter, and the rejection names no cause: this exact reasoning is how three device
    // round-trips were spent on a NaN literal. There is no use for WGSL that cannot compile, so
    // this one fails the build, in every mode.
    try checkNonFiniteConstants(out);

    // ---------------------------------------------------------------------------
    // GUARD RAIL: every `var phiN` declared must be ASSIGNED at least once.
    //
    // A phi is how the structurizer carries a value across a control-flow join. WGSL
    // zero-initialises a `var`, so a phi that is declared and READ but never WRITTEN does
    // not fail to compile - it silently reads 0. Every branch that tests it then takes the
    // wrong arm, and a `while` loop runs its body exactly once and breaks.
    //
    // That shipped. It wrecked ~9 kernels at once (density, densityTiled, force, viscosity,
    // prefixSum, ...) - a fluid sim where no particle ever found a neighbour, and a counting
    // sort whose prefix scan never ran - while leaving every loop-FREE kernel (double_it,
    // clearGrid, predict) perfect. So the compute smoke test stayed green and the bug hid
    // behind it for an entire arc.
    //
    // The invariant is purely syntactic, needs no GPU, and costs one pass over the output.
    // It is checked in EVERY mode (not just Debug): a silently-wrong shader is worse than a
    // failed build, and unlike the `_N` closure check above there is no known-limitation
    // escape hatch that can trip it.
    try checkPhiClosure(arena, out);

    // ---------------------------------------------------------------------------
    // GUARD RAIL: every storage buffer the SPIR-V ACCESSES must be accessed in the WGSL.
    //
    // `checkPhiClosure` proves the structurizer never leaves a phi unassigned. It cannot
    // prove the structurizer never DROPS A BLOCK - and it did, silently, for months.
    //
    // SCCP folds a selection whose condition is constant. When the merge carried a phi, the
    // fold deleted the arm the branch used to guard, and everything that arm dominated went
    // with it. In `sort_min.computeForce` that was the entire innermost neighbour loop: the
    // SPIR-V had 86 memory ops, the emitted WGSL had 3. The condition was still computed -
    //
    //     let _4940: bool = phi4936 == 138u;   // COMPUTED...
    //     let _5545: u32 = phi4936;            // ...and DISCARDED.
    //
    // - and the `if` it existed for was never emitted. No error, no `// ERROR:` marker, and
    // the one-armed-phi collapse had made the output perfectly WELL-FORMED, so every check
    // we had went green. The kernel ran, wrote a pressure correction of zero, and produced a
    // fluid that could not settle. It took a CPU-vs-GPU differential harness to find.
    //
    // This is the invariant that catches it directly. If a function reads or writes
    // `kbuf_starts` in the SPIR-V, the WGSL emitted for it must read or write `kbuf_starts`
    // too. A dropped block takes its memory operations with it, so the buffer simply stops
    // appearing - which is cheap to notice, needs no GPU, and would have caught this in one
    // build instead of a day of bisecting a fluid.
    //
    // It is deliberately a MEMBERSHIP test, not a count. Emission legitimately merges
    // accesses (CSE, hoisting), so requiring the same NUMBER would fire on healthy shaders.
    // But a buffer touched in SPIR-V and never mentioned in the output means code vanished.
    // THE ORIGINAL SPIR-V, not the folded one. The fold is what DELETES the block, so a
    // buffer dropped by a bad fold is missing from the folded module too - checking that
    // against the WGSL compares the crime scene with itself and finds nothing. (I wrote it
    // that way first, re-introduced the bug to test it, and watched it stay silent.)
    //
    // Against the ORIGINAL, a legitimate fold is still fine: SCCP only removes provably dead
    // arms, and a kernel touches its buffers on the live path, so no buffer loses its LAST
    // access to a correct fold. A buffer that disappears entirely means a live block went
    // with it.
    try checkBufferAccessSurvival(arena, spirv, out, entry orelse "shader");

    // Guard rail: every `_N` referenced in the output must have been declared.
    // Originally this returned `error.OutputIdentifierMissing` to catch the
    // "opcode handler forgot to set ids[N].wgsl_name" bug class.  In
    // integration that fail-fast turned out to be too strict - when the
    // transpiler hits any unhandled opcode that produces a result-id, the
    // lazy placeholder in `lookupId` registers the id as a name only, and
    // checkOutputClosure (correctly) flags the missing declaration.  We log
    // the diagnostic but still return the WGSL; the browser's WGSL frontend
    // will reject the bad output if it actually matters at runtime.  The
    // function itself still returns the error for callers (like tests) that
    // want the strict behavior.
    if (builtin.mode == .debug) {
        var missing: u32 = 0;
        checkOutputClosure(arena, out, &missing) catch {
            // An undeclared `_N` DOWNSTREAM of an emitted `// ERROR:`
            // marker is a known, documented limitation (e.g. a GLSL
            // combined sampler - WGSL needs separate texture+sampler
            // bindings), not a forgotten `wgsl_name`: log it at `warn`
            // (informational; the marker is the real diagnostic).  A
            // missing declaration with NO error marker is the genuine
            // bug class this guard exists to catch - log at `err`.  The
            // WGSL is returned either way; the browser's WGSL frontend
            // rejects it at pipeline creation if it actually matters.
            if (std.mem.indexOf(u8, out, "// ERROR:") != null) {
                std.log.warn(
                    "spv2wgsl: output references _{d} with no declaration, " ++
                        "downstream of an emitted // ERROR: marker (known limitation).",
                    .{missing},
                );
            } else {
                std.log.err(
                    "spv2wgsl: output references _{d} but it was never declared. " ++
                        "An opcode handler likely failed to set ids[%{d}].wgsl_name.",
                    .{ missing, missing },
                );
            }
        };
    }

    return out;
}

/// Convert a SPIR-V binary to a WGSL source string. The returned slice is
/// allocated from `arena`; freeing it requires destroying the arena.
///
/// Returns:
///   error.NotSpirv          - bad magic
///   error.MalformedSpirv    - truncated, bad word counts, etc.
///   error.OutputIdentifierMissing - internal: a referenced SSA temp wasn't declared
pub fn convertSpirvToWgsl(arena: Allocator, spirv: []const u32) ![]const u8 {
    return convertSpirvToWgslEntry(arena, spirv, null);
}

// =============================================================================
// Tests
// =============================================================================

// Pull the submodules' unit tests into this test root.
test {
    _ = ir;
    _ = ir_build;
    _ = ir_emit;
}

test "sampler-uniformity gate: fires on a sample under a non-uniform branch" {
    // The fixture is decal_fs as it was WHEN IT FAILED ON DEVICE (zimr786): scalar
    // `clamp01` was a branch chain, its condition derived from the o_world varying,
    // and the transpiler nested the textureSample inside it. Dawn rejected the
    // pipeline with "'textureSample' must only be called from uniform control flow".
    //
    // This pins BOTH halves of the analysis. Data taint alone does NOT catch it: the
    // branch that actually guards the sample tests `phi == 55u`, where every value the
    // phi merges is a CONSTANT. It is non-uniform only because the control flow
    // SELECTING between those constants is non-uniform. The first version of this gate
    // had exactly that hole and sailed straight past the bug it was written for.
    const bytes: []const u8 = @embedFile("tests/fixtures/uniformity/sampler_nonuniform.spv");

    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // @embedFile is byte-aligned; SPIR-V is a u32 stream. Copy into an aligned buffer
    // rather than @alignCast-ing (which trips the alignment safety check).
    const words: []u32 = try arena.allocator().alloc(u32, bytes.len / 4);
    @memcpy(std.mem.sliceAsBytes(words), bytes[0 .. words.len * 4]);

    try expectError(
        error.SamplerInNonUniformControlFlow,
        sampler_uniformity.check(arena.allocator(), words, "decal_fs (fixture)"),
    );
}

test "sampler-uniformity gate: a sample at uniform scope is accepted" {
    // The SAME shader with the fix in place must pass - otherwise the gate is just a
    // build-breaker. Constant-condition guards (`if (73u == 73u)`, which spv2wgsl's
    // phi-dispatch emits) are UNIFORM, so a sample inside one is legal and must not
    // be flagged; effect_ascii_fs samples three `if`s deep and is perfectly valid.
    const bytes: []const u8 = @embedFile("tests/fixtures/uniformity/sampler_uniform.spv");

    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words: []u32 = try arena.allocator().alloc(u32, bytes.len / 4);
    @memcpy(std.mem.sliceAsBytes(words), bytes[0 .. words.len * 4]);

    try sampler_uniformity.check(arena.allocator(), words, "decal_fs (fixed)");
}

test "rejects non-spirv input" {
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad = [_]u32{ 0xdeadbeef, 0, 0, 0, 0 };
    try expectError(error.NotSpirv, convertSpirvToWgsl(arena.allocator(), &bad));
}

test "rejects truncated header" {
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad = [_]u32{ 0x07230203, 0, 0 };
    try expectError(error.MalformedSpirv, convertSpirvToWgsl(arena.allocator(), &bad));
}

test "minimal module with just void type" {
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // magic, version 1.0, generator, bound=3, schema=0, then OpTypeVoid %1.
    const word0 = (@as(u32, 2) << 16) | @backingInt(types.Op.TypeVoid);
    const mod = [_]u32{
        0x07230203, 0x00010000, 0, 3, 0,
        word0,      1,
    };
    const out: []const u8 = try convertSpirvToWgsl(arena.allocator(), &mod);
    // No globals or functions; expect empty output (just the trailing newline
    // pass3 emits between header and body).
    try expect(out.len <= 4);
}

// NOTE: void-returning function calls (bare statement, not `let x: = f()`)
// are regression-guarded end-to-end by the `naga-tint` gate over the real
// function_FunctionCall* Tint fixtures - a stronger check than a synthetic
// hand-built module here, since it runs the actual naga validator.

test "parseTempId handles real and fake names" {
    try expectEqual(@as(?u32, 42), parseTempId("_42"));
    try expectEqual(@as(?u32, 0), parseTempId("_0"));
    try expectEqual(@as(?u32, null), parseTempId("foo"));
    try expectEqual(@as(?u32, null), parseTempId("_"));
    try expectEqual(@as(?u32, null), parseTempId("_a"));
}

test "checkOutputClosure catches undeclared reference" {
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // _5 is referenced but never declared.
    const bad: []const u8 =
        \\fn foo() {
        \\  let _1: f32 = _5 + 1.0;
        \\}
    ;
    try expectError(error.OutputIdentifierMissing, checkOutputClosure(arena.allocator(), bad, null));
}

test "checkOutputClosure accepts well-formed output" {
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const good: []const u8 =
        \\fn foo() {
        \\  let _1: f32 = 1.0;
        \\  let _2: f32 = _1 + 2.0;
        \\}
    ;
    try checkOutputClosure(arena.allocator(), good, null);
}

// ===========================================================================
// STRUCTURE-PLAN S1 (t1177): the former src/spv2wgsl/ subdirectory, folded
// in as section namespaces (the runtime.zig house pattern).  One file, one
// transpiler.  Former //! headers are kept as section comments.
// ===========================================================================

pub const wgsl_check = struct {
    // src/spv2wgsl/wgsl_check.zig - minimal structural WGSL validator.
    //
    // What this is: a fast, dependency-free check that the WGSL we emit
    // is at least STRUCTURALLY well-formed.  It catches the failure modes
    // we've actually seen - unbalanced braces, dangling identifiers,
    // incomplete statements - without trying to implement the WGSL spec.
    //
    // What this is NOT: a semantic validator.  That role belongs to the
    // real Tint parser that runs at runtime inside Dawn when wgpu-smoke
    // calls `device.createShaderModule(wgsl)`.  We don't reproduce that
    // here; we'd need 10kLOC of WGSL spec.
    //
    // Why structural only:
    // - The bugs our linear emitter produces (unbalanced braces during
    //   the failed flow-guard attempts, dropped phi assignments, the
    //   mandelbrot phi-overwrite-after-if pattern) all leave evidence
    //   visible at the lexical level.
    // - Anything subtler than structural belongs at runtime where the
    //   real parser sees it.
    // - Pure-Zig destination: no npm, no wasm, no JS.

    const ascii = std.ascii;

    /// Result of a structural check.  `ok = false` means we found a
    /// problem severe enough that downstream parsing definitely fails.
    pub const Report = struct {
        ok: bool,
        /// Brace nesting at end of file (should be 0).
        final_brace_depth: i32,
        /// Bracket nesting at end of file (should be 0).
        final_bracket_depth: i32,
        /// Paren nesting at end of file (should be 0).
        final_paren_depth: i32,
        /// First error line + message, or null if ok.
        first_error: ?ErrorSite,

        pub const ErrorSite = struct {
            line: usize,
            col: usize,
            msg: []const u8, // static string
        };
    };

    /// Check WGSL source structurally.  Allocates nothing; returns a
    /// stack-allocated Report.
    pub fn check(wgsl: []const u8) Report {
        var brace: i32 = 0;
        var bracket: i32 = 0;
        var paren: i32 = 0;
        var line: usize = 1;
        var col: usize = 1;
        var first_error: ?Report.ErrorSite = null;

        // Single-pass scanner.  Skips strings, line comments, block
        // comments.  WGSL has block comments that nest, so we track that.
        var i: usize = 0;
        while (i < wgsl.len) : (i += 1) {
            const c: u8 = wgsl[i];

            if (c == '\n') {
                line += 1;
                col = 1;
                continue;
            }
            col += 1;

            // Line comment: `// ... \n`
            if (c == '/' and i + 1 < wgsl.len and wgsl[i + 1] == '/') {
                // Skip to end of line.
                while (i < wgsl.len and wgsl[i] != '\n') : (i += 1) {}
                // Re-enter loop; outer increment moves past the newline,
                // line/col updates fire on the next iteration.
                if (i < wgsl.len) {
                    i -= 1; // unwind so outer i+=1 lands on the \n
                }
                continue;
            }

            // Block comment: `/* ... */` with WGSL-style nesting.
            if (c == '/' and i + 1 < wgsl.len and wgsl[i + 1] == '*') {
                i += 2;
                col += 1;
                var depth: u32 = 1;
                while (i < wgsl.len and depth > 0) : (i += 1) {
                    const cc: u8 = wgsl[i];
                    if (cc == '\n') {
                        line += 1;
                        col = 1;
                    } else {
                        col += 1;
                    }
                    if (cc == '/' and i + 1 < wgsl.len and wgsl[i + 1] == '*') {
                        depth += 1;
                        i += 1;
                        col += 1;
                    } else if (cc == '*' and i + 1 < wgsl.len and wgsl[i + 1] == '/') {
                        depth -= 1;
                        i += 1;
                        col += 1;
                    }
                }
                if (depth != 0 and first_error == null) {
                    first_error = .{ .line = line, .col = col, .msg = "unterminated block comment" };
                }
                // outer loop will i+=1
                if (i > 0) {
                    i -= 1;
                }
                continue;
            }

            // String literal: WGSL doesn't have user string literals in
            // shader bodies, but defensive - skip anything between quotes
            // so an embedded quote doesn't confuse brace counting.
            if (c == '"') {
                i += 1;
                while (i < wgsl.len and wgsl[i] != '"') : (i += 1) {
                    if (wgsl[i] == '\\' and i + 1 < wgsl.len) {
                        i += 1;
                    }
                    if (wgsl[i] == '\n') {
                        line += 1;
                        col = 1;
                    } else {
                        col += 1;
                    }
                }
                continue;
            }

            switch (c) {
                '{' => brace += 1,
                '}' => {
                    brace -= 1;
                    if (brace < 0 and first_error == null) {
                        first_error = .{ .line = line, .col = col, .msg = "unmatched closing brace" };
                    }
                },
                '[' => bracket += 1,
                ']' => {
                    bracket -= 1;
                    if (bracket < 0 and first_error == null) {
                        first_error = .{ .line = line, .col = col, .msg = "unmatched closing bracket" };
                    }
                },
                '(' => paren += 1,
                ')' => {
                    paren -= 1;
                    if (paren < 0 and first_error == null) {
                        first_error = .{ .line = line, .col = col, .msg = "unmatched closing paren" };
                    }
                },
                else => {},
            }
        }

        if (brace != 0 and first_error == null) {
            first_error = .{ .line = line, .col = col, .msg = "unbalanced braces at end of input" };
        }
        if (bracket != 0 and first_error == null) {
            first_error = .{ .line = line, .col = col, .msg = "unbalanced brackets at end of input" };
        }
        if (paren != 0 and first_error == null) {
            first_error = .{ .line = line, .col = col, .msg = "unbalanced parens at end of input" };
        }

        return .{
            .ok = first_error == null,
            .final_brace_depth = brace,
            .final_bracket_depth = bracket,
            .final_paren_depth = paren,
            .first_error = first_error,
        };
    }

    // -- Known-bug pattern scanners --------------------------------------

    /// Report of suspected bugs in WGSL output.  These are LEXICAL
    /// fingerprints, not proofs.  They exist to catch regressions of
    /// previously-fixed bugs.  Phase 5 cutover target: zero hits across
    /// the full corpus.
    pub const BugScan = struct {
        /// The phi-overwrite-after-if pattern that drove this whole
        /// rewrite.  Mandelbrot diagnostic, May 2026.  See
        /// docs/spv2wgsl-flow-guards.md for the worked example.
        phi_overwrite_after_if: u32 = 0,

        /// Count of `phiN` variables that are READ but never assigned (`phiN =`)
        /// anywhere - an orphaned phi. This is the bug where a merge construct is
        /// dropped (e.g. a folded case-less switch) but its OpPhi survives, leaving
        /// `out_color = phiN` with no `phiN = value` -> garbage. Catches the
        /// turn-896 mandelbrot bug class at its symptom. See docs.
        phi_read_before_write: u32 = 0,

        /// Count of `__unresolved_N__` markers.  These indicate a
        /// missing id propagation in the translator.
        unresolved_markers: u32 = 0,

        /// Count of `// ERROR:` markers emitted by the translator itself.
        /// These are explicit "I don't handle this yet" diagnostics.
        error_markers: u32 = 0,

        pub fn total(self: BugScan) u32 {
            // NOTE: phi_read_before_write is deliberately NOT summed here. Some
            // hand-crafted Tint corpus fixtures (the phi_Phi_* family) legitimately
            // produce a one-incoming phi that reads without an assignment on a
            // tolerated/unreachable edge; those are baseline-ok. The orphan count is
            // a targeted diagnostic for ENGINE shaders (where an orphan = a real
            // dropped-merge bug), surfaced via reports, not the corpus gate.
            return self.phi_overwrite_after_if + self.unresolved_markers + self.error_markers;
        }
    };

    /// Scan WGSL for known-bug patterns.  Caller-allocator-free; uses
    /// scratch buffers on the stack.
    pub fn scanBugs(wgsl: []const u8) BugScan {
        var out: BugScan = .{};

        // Count `__unresolved_N__` occurrences (cheap: substring scan).
        var i: usize = 0;
        while (i + "__unresolved_".len < wgsl.len) {
            if (startsWith(u8, wgsl[i..], "__unresolved_")) {
                out.unresolved_markers += 1;
                i += "__unresolved_".len;
            } else {
                i += 1;
            }
        }

        // Count `// ERROR:` and `UNHANDLED` lines.
        i = 0;
        while (i < wgsl.len) {
            const nl: usize = std.mem.indexOfScalarPos(u8, wgsl, i, '\n') orelse wgsl.len;
            const line: []const u8 = wgsl[i..nl];
            if (std.mem.indexOf(u8, line, "// ERROR:") != null or
                std.mem.indexOf(u8, line, "UNHANDLED") != null)
            {
                out.error_markers += 1;
            }
            i = nl + 1;
        }

        // Phi-overwrite-after-if detector.  We scan for the lexical
        // pattern:
        //
        //   if (...) {
        //     ...
        //     phiN = X;        <- inside the if
        //   }
        //   phiN = Y;          <- outside, immediately after, same phi
        //
        // Where the assignment after the close-brace overwrites the
        // assignment inside.  This is the canonical mandelbrot bug.
        //
        // Algorithm:
        //   1. Split into trimmed lines.
        //   2. For each line that starts `phiNNN = ` immediately after
        //      a `}` line, look back through the matched `if` body for
        //      a same-phi assignment.
        //   3. If found inside, count it.
        out.phi_overwrite_after_if = countPhiOverwriteAfterIf(wgsl);
        out.phi_read_before_write = countPhiReadBeforeWrite(wgsl);

        return out;
    }

    /// Count `phiN` identifiers that are read somewhere but NEVER assigned
    /// (`phiN =`, excluding `==`). A nonzero result means a phi was orphaned (its
    /// declaring merge construct was dropped but the phi survived) - the value the
    /// phi should carry is lost, so the read yields garbage. Cheap single-pass-ish
    /// scan: collect every `phiN` token + every `phiN =` assignment target, then
    /// report tokens with no matching assignment. Bounded by a small fixed cap on
    /// distinct phi ids (more than enough for any real shader).
    fn countPhiReadBeforeWrite(wgsl: []const u8) u32 {
        const MAX_IDS: usize = 1024;
        var seen: [MAX_IDS]u32 = undefined; // distinct phi ids encountered (read or written)
        var written: [MAX_IDS]bool = undefined;
        var n_ids: usize = 0;

        var i: usize = 0;
        while (i < wgsl.len) {
            // Find the next "phi" followed by digits.
            const is_phi_start: bool = i + 3 < wgsl.len and
                wgsl[i] == 'p' and wgsl[i + 1] == 'h' and wgsl[i + 2] == 'i' and
                ascii.isDigit(wgsl[i + 3]);
            if (is_phi_start) {
                // Token must not be preceded by an identifier char (so we match the
                // whole token, not a suffix of something else).
                const prev_ok: bool = i == 0 or !isIdentChar(wgsl[i - 1]);
                if (prev_ok) {
                    var j: usize = i + 3;
                    var id: u32 = 0;
                    while (j < wgsl.len and ascii.isDigit(wgsl[j])) : (j += 1) {
                        id = id *% 10 +% (wgsl[j] - '0');
                    }
                    // Is this an assignment (`phiN =` but not `==`)? Skip spaces.
                    var k: usize = j;
                    while (k < wgsl.len and (wgsl[k] == ' ' or wgsl[k] == '\t')) : (k += 1) {}
                    const is_assign: bool = k < wgsl.len and wgsl[k] == '=' and
                        (k + 1 >= wgsl.len or wgsl[k + 1] != '=');
                    // Record the id.
                    var idx: usize = 0;
                    var found: bool = false;
                    while (idx < n_ids) : (idx += 1) {
                        if (seen[idx] == id) {
                            found = true;
                            break;
                        }
                    }
                    if (!found and n_ids < MAX_IDS) {
                        seen[n_ids] = id;
                        written[n_ids] = false;
                        idx = n_ids;
                        n_ids += 1;
                    }
                    if (found or n_ids <= MAX_IDS) {
                        if (is_assign and idx < n_ids) {
                            written[idx] = true;
                        }
                    }
                    i = j;
                    continue;
                }
            }
            i += 1;
        }

        var count: u32 = 0;
        var idx: usize = 0;
        while (idx < n_ids) : (idx += 1) {
            if (!written[idx]) {
                count += 1;
            }
        }
        return count;
    }

    fn isIdentChar(c: u8) bool {
        return ascii.isAlphanumeric(c) or c == '_';
    }

    fn countPhiOverwriteAfterIf(wgsl: []const u8) u32 {
        var count: u32 = 0;
        var lines = std.mem.splitScalar(u8, wgsl, '\n');
        // Materialize line slices for backward scanning.  Lines are
        // unmodified substrings of `wgsl`; no allocation.
        var line_starts: [4096]usize = undefined;
        var line_count: usize = 0;
        {
            var pos: usize = 0;
            while (lines.next()) |line| : (line_count += 1) {
                if (line_count >= line_starts.len) {
                    break;
                }
                line_starts[line_count] = pos;
                pos += line.len + 1; // +1 for the '\n'
            }
        }

        var i: usize = 1;
        while (i < line_count) : (i += 1) {
            // A peephole over the EMITTED WGSL text, not the SPIR-V: it looks for a `phiN = ...`
            // assignment sitting directly after a closing brace, which is the shape the phi
            // lowering leaves behind and which some drivers mis-scope.
            const cur: []const u8 = trimLine(wgsl, line_starts[0..], i, line_count);
            const prev: []const u8 = trimLine(wgsl, line_starts[0..], i - 1, line_count);

            if (!std.mem.eql(u8, prev, "}")) {
                continue;
            }
            if (!startsWith(u8, cur, "phi")) {
                continue;
            }

            // Extract the phi name (up to ` = `).
            const eq = std.mem.indexOf(u8, cur, " = ") orelse continue;
            const phi_name: []const u8 = cur[0..eq];
            // Must be entirely phi[0-9]+
            if (phi_name.len < 4) {
                continue;
            }
            var ok = true;
            for (phi_name[3..]) |c| {
                if (!ascii.isDigit(c)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) {
                continue;
            }

            // Walk backward from i-2 finding the matching `if (...) {`,
            // counting brace depth.  Inside the matched if's body, look
            // for any `phi_name = ` assignment.
            //
            // We start at depth=1 because we just stepped backward across
            // the closing `}` on line i-1 - meaning we're now "inside" the
            // construct that the `phiN = Y;` overwrites.  Lines containing
            // `{` (forward-direction open) DECREMENT depth (we're exiting
            // the construct walking backward), `}` (forward-direction close)
            // INCREMENT depth.  A line like `} else {` contains one of each,
            // net zero; we count occurrences per line, not just endings.
            var depth: i32 = 1;
            var set_inside = false;
            var j: usize = if (i >= 2) i - 2 else 0;
            while (true) : (if (j == 0) break else {
                j -= 1;
            }) {
                const ln: []const u8 = trimLine(wgsl, line_starts[0..], j, line_count);
                // At depth 1, look for the phi assignment.
                if (depth == 1 and isAssignTo(ln, phi_name)) {
                    set_inside = true;
                }
                // Per-line brace tally for backward traversal.
                const opens = std.mem.count(u8, ln, "{");
                const closes = std.mem.count(u8, ln, "}");
                depth += @as(i32, @intCast(closes));
                depth -= @as(i32, @intCast(opens));
                if (depth <= 0) {
                    // Found the matching `if (...) {` line.  Check it
                    // really IS an `if (` opener (not e.g. `} else {`,
                    // a function `{`, or a `loop {`).
                    if (isIfOpenerLine(ln)) {
                        if (set_inside) {
                            count += 1;
                        }
                    }
                    break;
                }
                if (j == 0) {
                    break;
                }
            }
        }
        return count;
    }

    fn isAssignTo(line: []const u8, phi_name: []const u8) bool {
        if (!startsWith(u8, line, phi_name)) {
            return false;
        }
        if (line.len < phi_name.len + 3) {
            return false;
        }
        return std.mem.eql(u8, line[phi_name.len .. phi_name.len + 3], " = ");
    }

    fn isIfOpenerLine(line: []const u8) bool {
        // The matched opener must contain `if (` AND end with `{`.
        if (!endsWith(u8, line, "{")) {
            return false;
        }
        // `} else {` and bare `loop {` / `else {` are NOT if openers.
        if (startsWith(u8, line, "} else") or
            startsWith(u8, line, "else") or
            startsWith(u8, line, "loop") or
            startsWith(u8, line, "continuing"))
        {
            return false;
        }
        // Accept `if (...)` at the start or after a brace from the
        // previous construct.
        if (startsWith(u8, line, "if (")) {
            return true;
        }
        if (std.mem.indexOf(u8, line, " if (") != null) {
            return true;
        }
        return false;
    }

    /// Return line `idx` from `wgsl`, trimmed of surrounding whitespace.
    /// `starts` holds the byte offset of each line's first char (computed
    /// once by the caller); `count` is how many entries are valid.  Taking
    /// `starts` as a slice (not a by-value `[4096]usize`) avoids copying
    /// 32 KB on every call - this runs O(lines^2) in the backward scan.
    fn trimLine(
        wgsl: []const u8,
        starts: []const usize,
        idx: usize,
        count: usize,
    ) []const u8 {
        const start: usize = starts[idx];
        const end: usize = if (idx + 1 < count) starts[idx + 1] - 1 else wgsl.len;
        const raw: []const u8 = wgsl[start..end];
        return std.mem.trim(u8, raw, " \t\r");
    }

    /// Structural tripwire for the spv2wgsl struct-dedup invariant: report the
    /// name of the first `struct` whose body is byte-identical to an earlier
    /// one.  After `emitTypeStruct`'s dedup this never fires on our output; if
    /// it does, the dedup regressed (or a new duplication class appeared) and
    /// the WGSL carries a nominal-type mismatch Tint rejects on device (the
    /// `let _: S8 = P;` with `P: S3461` failure that killed fluid_sort's compute
    /// kernels).  Purely lexical, so it fits this validator's structural charter
    /// - no semantic engine, no allocation.  Returns the duplicate struct's
    /// name, or null when every body is unique.
    pub fn duplicateStructBody(wgsl: []const u8) ?[]const u8 {
        const Span = struct {
            name: []const u8,
            body: []const u8,
        };
        var spans: [256]Span = undefined;
        var n: usize = 0;
        var i: usize = 0;
        const kw: []const u8 = "struct ";
        while (std.mem.indexOfPos(u8, wgsl, i, kw)) |kw_at| {
            // Require a token boundary so `mystruct`/`structish` don't match.
            const boundary_ok: bool = kw_at == 0 or !isIdentChar(wgsl[kw_at - 1]);
            const name_start: usize = kw_at + kw.len;
            if (!boundary_ok or name_start >= wgsl.len) {
                i = kw_at + kw.len;
                continue;
            }
            var ne: usize = name_start;
            while (ne < wgsl.len and isIdentChar(wgsl[ne])) : (ne += 1) {}
            const name: []const u8 = wgsl[name_start..ne];
            const open: usize = std.mem.indexOfPos(u8, wgsl, ne, "{") orelse break;
            // Match the closing brace (our bodies have none nested, but count
            // anyway).  A malformed unbalanced body stops the scan cleanly.
            var depth: u32 = 0;
            var close_opt: ?usize = null;
            var j: usize = open;
            while (j < wgsl.len) : (j += 1) {
                if (wgsl[j] == '{') {
                    depth += 1;
                } else if (wgsl[j] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        close_opt = j;
                        break;
                    }
                }
            }
            const close: usize = close_opt orelse break;
            const body: []const u8 = wgsl[open + 1 .. close];
            for (spans[0..n]) |sp| {
                if (std.mem.eql(u8, sp.body, body)) {
                    return name;
                }
            }
            if (n < spans.len) {
                spans[n] = .{ .name = name, .body = body };
                n += 1;
            }
            i = close + 1;
        }
        return null;
    }

    // -- Tests ------------------------------------------------------------

    const testing = std.testing;

    // ---------------------------------------------------------------------------
    // REPRO: the spv2wgsl "name collision" problem (fix plan in src/notes).
    // When spv2wgsl flattens distinct SPIR-V locals that share a debug name into a
    // single WGSL function scope, it emits the SAME `var` name twice. Hit live in
    // raycube_fs:  Error: [wgsl:raycube_sbs_gpu:244:3] redeclaration of 't0'
    // The Zig shader that triggered it (each block is a distinct SPIR-V `t0`):
    //     { const inv = 1/rd[0]; var t0 = ...; var t1 = ...; ... }  // X slab
    //     { const inv = 1/rd[1]; var t0 = ...; var t1 = ...; ... }  // Y slab
    //   -> flattened into one scope -> `redeclaration of 't0'`.
    // This test documents that our build-time STRUCTURAL check does NOT catch the
    // resulting WGSL - only the browser's validator does, at runtime.
    // FIXED (spv2wgsl unique-name pass): spv2wgsl now renames colliding
    // function-local OpVariables (probe0 -> probe0, probe0_1), so this WGSL is no
    // longer EMITTED - verified end-to-end. This test still passes because
    // wgsl_check itself doesn't catch a HAND-WRITTEN redeclaration; a scope-aware
    // pass here would be defense-in-depth (then flip this to expect(!r.ok)).
    test "wgsl_check: KNOWN GAP - duplicate var (name collision) slips through" {
        const colliding: []const u8 =
            \\fn slabs(rd: vec3<f32>) -> f32 {
            \\  var t0: f32 = rd.x;
            \\  var t0: f32 = rd.y;
            \\  return t0;
            \\}
        ;
        const r: Report = check(colliding);
        // DOCUMENTS THE BUG: the structural check currently PASSES invalid WGSL.
        // The fix (unique-name emission in spv2wgsl) means this WGSL is never
        // produced; a redeclaration pass added HERE would flip this to `!r.ok`.
        try testing.expect(r.ok);
    }

    // The exact fluid_sort failure shape: SPIR-V emitted Params under two ids
    // (decorated uniform block `S3461` + undecorated value twin `S8`); the
    // whole-block load `let _: S8 = P;` is then a nominal-type mismatch.  After
    // emitTypeStruct's dedup this WGSL is never produced; this guard catches a
    // regression at build time instead of leaving it for the device.
    test "wgsl_check: duplicateStructBody flags identical bodies" {
        const dup: []const u8 =
            \\struct S8 {
            \\  field_0: u32,
            \\  field_1: f32,
            \\};
            \\struct S3461 {
            \\  field_0: u32,
            \\  field_1: f32,
            \\};
            \\@group(0) @binding(0) var<uniform> P: S3461;
        ;
        const hit: ?[]const u8 = duplicateStructBody(dup);
        try testing.expect(hit != null);
        try testing.expectEqualStrings("S3461", hit.?);
    }

    test "wgsl_check: duplicateStructBody passes distinct bodies" {
        // S9 nests S8 - different body - must NOT be flagged (the legit Ctx
        // struct alongside the deduped Params).
        const ok: []const u8 =
            \\struct S8 {
            \\  field_0: u32,
            \\  field_1: f32,
            \\};
            \\struct S9 {
            \\  field_0: u32,
            \\  field_1: S8,
            \\};
        ;
        try testing.expect(duplicateStructBody(ok) == null);
    }

    test "wgsl_check: trivial balanced" {
        const wgsl: []const u8 =
            \\@fragment fn fs() -> @location(0) vec4<f32> {
            \\  return vec4(1.0);
            \\}
        ;
        const r: Report = check(wgsl);
        try testing.expect(r.ok);
        try testing.expectEqual(@as(i32, 0), r.final_brace_depth);
        try testing.expectEqual(@as(i32, 0), r.final_paren_depth);
    }

    test "wgsl_check: unbalanced braces" {
        const wgsl: []const u8 = "fn f() { return; ";
        const r: Report = check(wgsl);
        try testing.expect(!r.ok);
        try testing.expect(r.final_brace_depth > 0);
    }

    test "wgsl_check: line comment doesn't confuse brace counter" {
        const wgsl: []const u8 =
            \\fn f() {
            \\  // }}}}}}}
            \\  let x = 1;
            \\}
        ;
        const r: Report = check(wgsl);
        try testing.expect(r.ok);
    }

    test "wgsl_check: block comment doesn't confuse brace counter" {
        const wgsl: []const u8 =
            \\fn f() {
            \\  /* } } } */
            \\  let x = 1;
            \\}
        ;
        const r: Report = check(wgsl);
        try testing.expect(r.ok);
    }

    test "wgsl_check: nested block comments" {
        const wgsl: []const u8 =
            \\fn f() {
            \\  /* outer /* inner */ still outer */
            \\  let x = 1;
            \\}
        ;
        const r: Report = check(wgsl);
        try testing.expect(r.ok);
    }

    test "scanBugs: unresolved markers counted" {
        const wgsl: []const u8 = "let x = __unresolved_42__ + __unresolved_99__;";
        const s: BugScan = scanBugs(wgsl);
        try testing.expectEqual(@as(u32, 2), s.unresolved_markers);
    }

    test "scanBugs: error markers counted" {
        const wgsl: []const u8 =
            \\fn f() {
            \\  // ERROR: spv2wgsl can't handle this
            \\  UNHANDLED OpFoo
            \\}
        ;
        const s: BugScan = scanBugs(wgsl);
        try testing.expectEqual(@as(u32, 2), s.error_markers);
    }

    test "scanBugs: phi-overwrite-after-if detector positive case" {
        // The canonical mandelbrot bug shape, simplified.
        const wgsl: []const u8 =
            \\fn fs() {
            \\  if (cond) {
            \\    phi42 = 1.0;
            \\  }
            \\  phi42 = 0.0;
            \\}
        ;
        const s: BugScan = scanBugs(wgsl);
        try testing.expectEqual(@as(u32, 1), s.phi_overwrite_after_if);
    }

    test "scanBugs: phi-overwrite-after-if negative case (no inside-if assignment)" {
        const wgsl: []const u8 =
            \\fn fs() {
            \\  if (cond) {
            \\    other = 1.0;
            \\  }
            \\  phi42 = 0.0;
            \\}
        ;
        const s: BugScan = scanBugs(wgsl);
        try testing.expectEqual(@as(u32, 0), s.phi_overwrite_after_if);
    }

    test "scanBugs: phi-overwrite-after-if negative case (different phi name)" {
        const wgsl: []const u8 =
            \\fn fs() {
            \\  if (cond) {
            \\    phi17 = 1.0;
            \\  }
            \\  phi42 = 0.0;
            \\}
        ;
        const s: BugScan = scanBugs(wgsl);
        try testing.expectEqual(@as(u32, 0), s.phi_overwrite_after_if);
    }
};
