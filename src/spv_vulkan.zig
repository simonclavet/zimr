//! SPIR-V ON VULKAN - reading, checking and legalizing the modules the Zig compiler emits, for the Vulkan host.
//!
//! Every zimr shader is written in Zig and compiled by `zig build-obj -target spirv32-vulkan`. The web build turns
//! that SPIR-V into WGSL (spv2wgsl); the Vulkan host hands the SAME SPIR-V to the driver - after a few adjustments,
//! because the compiler's output does not meet every rule of Vulkan's environment. `legalize` makes them when a
//! module is loaded, each a few instructions wide:
//!
//!   1. A fragment shader that writes `FragDepth` must declare `OpExecutionMode %entry DepthReplacing`. WGSL infers
//!      the mode, so the web needs nothing; Zig cannot express it (`SpirvFragmentOptions` has no such field, and
//!      inline assembly may not set execution modes). `legalize` inserts it.
//!   2. A storage buffer a VERTEX shader reads should be decorated `NonWritable`: without the decoration it counts as
//!      written, and the vertex stage may write storage memory only under the `vertexPipelineStoresAndAtomics`
//!      feature. The Zig compiler decorates const storage pointers itself; zimr's `StorageBufferPtr` is not const, so
//!      `legalize` decorates every vertex-stage storage buffer it can prove is never written. A written one is
//!      refused by name; one whose pointer escapes into a function call is left undecorated, legal because the host
//!      enables the feature wherever the GPU offers it.
//!   3. `ArrayStride` on a POINTER type gives meaning to exactly one instruction, `OpPtrAccessChain`. The compiler
//!      decorates pointer types this way even when no such instruction exists, and validators may refuse the
//!      decoration on a storage class that is not `PhysicalStorageBuffer`. With no `OpPtrAccessChain` in the module
//!      the decoration means nothing, so `legalize` drops it.
//!   4. `OpSource` names the source language, and Zig's value (12) was added to SPIR-V in 2024: validators built
//!      before then reject the whole module over it. It is debug information only, so `legalize` declares `Unknown`.
//!
//! And three refusals, each by name: `Capability Linkage`, which marks a module that is not a complete program (some
//! compiler versions emit it on every module); a vertex shader that writes a storage buffer; and a struct holding a
//! runtime array without `Block`, which Vulkan rejects whether or not anything uses it.
//!
//! The file also REFLECTS an entry point - which globals it uses, where each is bound, what a vertex input looks like
//! - so the host can build descriptor-set layouts and vertex layouts from the SPIR-V itself, and CHECKS a module
//! against the rules zimr knows, so the build can refuse a module before any GPU sees it.
//!
//! ---- HOW A SPIR-V MODULE IS LAID OUT ----
//!
//! A module is an array of 32-bit words: a 5-word header (magic number, version, generator, the id bound, a zero),
//! then instructions. An instruction's first word holds its length in words (high 16 bits) and its opcode (low 16
//! bits); its operands follow. The instructions come in a fixed order of sections:
//!
//!     capabilities, extensions, extended-instruction imports, the memory model,
//!     entry points, execution modes,                                         <- DepthReplacing is inserted here
//!     debug names (OpName, OpMemberName, OpString, OpSource, ...),
//!     annotations (OpDecorate, OpMemberDecorate, ...),                       <- NonWritable is inserted here
//!     types, constants and global variables,
//!     functions.
//!
//! Since SPIR-V 1.4 an entry point lists EVERY global it uses in its interface, not only its inputs and outputs - so
//! the interface IS the reflection: no data-flow analysis is needed to know what a shader binds.
//!
//! Std only, pure, and the same on every platform: the build's gate runs `check` in the Linux sandbox, the Windows
//! host runs `legalize` and `reflect` at load time.

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const builtin = @import("builtin");
const eql = std.mem.eql;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const indexOf = std.mem.indexOf;
const sliceAsBytes = std.mem.sliceAsBytes;
const testing_allocator = std.testing.allocator;

comptime {
    // Literal strings are bytes packed little-endian into words; reading them as the words' bytes in memory is right
    // only on a little-endian host - every zimr target is one.
    if (builtin.cpu.arch.endian() != .little) {
        @compileError("spv_vulkan reads SPIR-V strings as little-endian bytes");
    }
}

pub const magic_number: u32 = 0x07230203;
pub const header_word_count: usize = 5;

pub const Error = error{
    /// The words do not start with SPIR-V's magic number, or are shorter than the header.
    NotSpirv,
    /// An instruction's length is zero or runs past the end of the module.
    Truncated,
    /// `Capability Linkage`: not a complete program, which Vulkan cannot load.
    LinkageCapability,
    /// A vertex shader writes a storage buffer. WebGPU forbids writable storage in the vertex stage, so such a shader
    /// cannot run on the web, and is not one of zimr's.
    VertexStageStorageWrite,
    /// A struct holds a runtime-sized array without `Block`: Vulkan allows a runtime array only as the last member of
    /// a `Block` struct, and rejects any other struct holding one, used or not.
    RuntimeArrayOutsideBlock,
    /// `reflect` was asked for an entry point the module does not have.
    NoSuchEntryPoint,
    OutOfMemory,
};

// ---- The SPIR-V vocabulary this file reads: SPIR-V's own names, non-exhaustive so a switch can default. ----

/// `OpSource`'s language for Zig, added to the SPIR-V registry in 2024: validators built before then reject the value
/// as unknown, and with it the whole module. The source language is debug information only, so `legalize` declares
/// `Unknown` instead - the value every validator accepts.
const source_language_zig: u32 = 12;
const source_language_unknown: u32 = 0;

pub const Op = enum(u16) {
    SourceContinued = 2,
    Source = 3,
    SourceExtension = 4,
    Name = 5,
    MemberName = 6,
    String = 7,
    Extension = 10,
    ExtInstImport = 11,
    MemoryModel = 14,
    EntryPoint = 15,
    ExecutionMode = 16,
    Capability = 17,
    TypeInt = 21,
    TypeFloat = 22,
    TypeVector = 23,
    TypeImage = 25,
    TypeSampler = 26,
    TypeSampledImage = 27,
    TypeArray = 28,
    TypeRuntimeArray = 29,
    TypeStruct = 30,
    TypePointer = 32,
    Function = 54,
    FunctionParameter = 55,
    FunctionCall = 57,
    Variable = 59,
    Store = 62,
    CopyMemory = 63,
    AccessChain = 65,
    InBoundsAccessChain = 66,
    PtrAccessChain = 67,
    InBoundsPtrAccessChain = 70,
    Decorate = 71,
    MemberDecorate = 72,
    DecorationGroup = 73,
    GroupDecorate = 74,
    GroupMemberDecorate = 75,
    CopyObject = 83,
    AtomicStore = 228,
    AtomicExchange = 229,
    AtomicXor = 242,
    LoopMerge = 246,
    SelectionMerge = 247,
    BranchConditional = 250,
    Switch = 251,
    ModuleProcessed = 330,
    ExecutionModeId = 331,
    DecorateId = 332,
    DecorateString = 5632,
    MemberDecorateString = 5633,
    _,
};

pub const Capability = enum(u32) {
    Shader = 1,
    Linkage = 5,
    _,
};

pub const ExecutionModel = enum(u32) {
    Vertex = 0,
    Fragment = 4,
    GLCompute = 5,
    _,
};

pub const ExecutionMode = enum(u32) {
    OriginUpperLeft = 7,
    DepthReplacing = 12,
    LocalSize = 17,
    _,
};

pub const StorageClass = enum(u32) {
    UniformConstant = 0,
    Input = 1,
    Uniform = 2,
    Output = 3,
    Workgroup = 4,
    Private = 6,
    Function = 7,
    PushConstant = 9,
    StorageBuffer = 12,
    PhysicalStorageBuffer = 5349,
    _,
};

pub const Decoration = enum(u32) {
    Block = 2,
    BufferBlock = 3,
    ArrayStride = 6,
    BuiltIn = 11,
    NonWritable = 24,
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
    FrontFacing = 17,
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

/// The functions kompute's kernels call in place of SPIR-V atomics and barriers. `spv2wgsl` replaces each call with
/// WGSL's own atomic or barrier; Vulkan has no such step, so a module that still calls one cannot run natively.
const kompute_helper_names = [_][]const u8{ "zatomicAdd", "zatomicLoad", "zatomicStore", "zworkgroupBarrier" };

// ---- Reading ----

/// One instruction: where it starts in the words, its length, its opcode and its operands.
pub const Instruction = struct {
    start: usize,
    word_count: usize,
    op: Op,
    operands: []const u32,
};

/// Walks a module's instructions in order.
pub const InstructionReader = struct {
    words: []const u32,
    position: usize,

    pub fn init(words: []const u32) Error!InstructionReader {
        if (words.len < header_word_count or words[0] != magic_number) {
            return Error.NotSpirv;
        }
        return .{ .words = words, .position = header_word_count };
    }

    pub fn next(self: *InstructionReader) Error!?Instruction {
        if (self.position >= self.words.len) {
            return null;
        }
        const first_word: u32 = self.words[self.position];
        const word_count: usize = first_word >> 16;
        const opcode: u16 = @truncate(first_word);
        if (word_count == 0 or self.position + word_count > self.words.len) {
            return Error.Truncated;
        }
        const instruction: Instruction = .{
            .start = self.position,
            .word_count = word_count,
            .op = @fromBackingInt(@intCast(opcode)),
            .operands = self.words[self.position + 1 .. self.position + word_count],
        };
        self.position += word_count;
        return instruction;
    }
};

/// A literal string inside an instruction: its text (without the terminating zero) and the words it occupies.
const LiteralString = struct { text: []const u8, word_count: usize };

/// The literal string at the start of `operands`.
fn literalString(operands: []const u32) LiteralString {
    const bytes: []const u8 = sliceAsBytes(operands);
    const text_length: usize = indexOf(u8, bytes, &.{0}) orelse bytes.len;
    // The string and its zero, rounded up to whole words.
    const word_count: usize = (text_length + 1 + 3) / 4;
    return .{ .text = bytes[0..text_length], .word_count = @min(word_count, operands.len) };
}

fn instructionHead(op: Op, word_count: u32) u32 {
    return (word_count << 16) | @backingInt(op);
}

/// What the decorations say about one id.
pub const Decorations = struct {
    descriptor_set: ?u32 = null,
    binding: ?u32 = null,
    location: ?u32 = null,
    builtin: ?BuiltIn = null,
    non_writable: bool = false,
    block: bool = false,
    /// The start of every `ArrayStride` decoration on this id (a pointer type's, for legalization).
    array_stride_start: ?usize = null,
};

/// An entry point as declared: its execution model, id, name, and the interface - every global it uses.
pub const EntryPoint = struct {
    execution_model: ExecutionModel,
    id: u32,
    name: []const u8,
    interface: []const u32,
    has_depth_replacing: bool,
};

/// One indexing pass over a module, kept for the questions `reflect`, `check` and `legalize` ask.
pub const Module = struct {
    words: []const u32,
    capabilities: ArrayList(Capability),
    entry_points: ArrayList(EntryPoint),
    names: AutoHashMapUnmanaged(u32, []const u8),
    decorations: AutoHashMapUnmanaged(u32, Decorations),
    /// Per struct type id: how many of its members carry an `Offset`.
    member_offsets: AutoHashMapUnmanaged(u32, u32),
    /// Per type id: the instruction that declares it.
    types: AutoHashMapUnmanaged(u32, Instruction),
    /// Per global variable id: its pointer type and storage class.
    variables: AutoHashMapUnmanaged(u32, Variable),
    /// Where the execution-mode section ends: a new execution mode goes here.
    execution_modes_end: usize,
    /// Where the annotation section ends: a new decoration goes here.
    annotations_end: usize,
    has_ptr_access_chain: bool,
    /// `OpSource` names the Zig source language (`legalize` declares it `Unknown`).
    declares_zig_source: bool,

    pub const Variable = struct { pointer_type: u32, storage_class: StorageClass };

    pub fn parse(gpa: Allocator, words: []const u32) Error!Module {
        var module: Module = .{
            .words = words,
            .capabilities = .empty,
            .entry_points = .empty,
            .names = .empty,
            .decorations = .empty,
            .member_offsets = .empty,
            .types = .empty,
            .variables = .empty,
            .execution_modes_end = header_word_count,
            .annotations_end = header_word_count,
            .has_ptr_access_chain = false,
            .declares_zig_source = false,
        };
        errdefer module.deinit(gpa);
        var reader: InstructionReader = try .init(words);
        // The first pass records the entry points' execution modes as a list of (entry id, mode) found, applied after.
        var depth_replacing_entries: ArrayList(u32) = .empty;
        defer depth_replacing_entries.deinit(gpa);
        while (try reader.next()) |instruction| {
            try module.index(gpa, instruction, &depth_replacing_entries);
        }
        for (module.entry_points.items) |*entry_point| {
            for (depth_replacing_entries.items) |entry_id| {
                if (entry_id == entry_point.id) {
                    entry_point.has_depth_replacing = true;
                }
            }
        }
        return module;
    }

    fn index(
        self: *Module,
        gpa: Allocator,
        instruction: Instruction,
        depth_replacing_entries: *ArrayList(u32),
    ) Error!void {
        const operands: []const u32 = instruction.operands;
        const instruction_end: usize = instruction.start + instruction.word_count;
        switch (instruction.op) {
            .Capability => {
                if (operands.len >= 1) {
                    try self.capabilities.append(gpa, @fromBackingInt(@intCast(operands[0])));
                }
                self.execution_modes_end = instruction_end;
                self.annotations_end = instruction_end;
            },
            .Extension, .ExtInstImport, .MemoryModel => {
                self.execution_modes_end = instruction_end;
                self.annotations_end = instruction_end;
            },
            .Source => {
                if (operands.len >= 1 and operands[0] == source_language_zig) {
                    self.declares_zig_source = true;
                }
                // A debug instruction: decorations go after it.
                self.annotations_end = instruction_end;
            },
            // The other debug instructions and annotations: a module's sections come in a fixed order, and
            // every decoration `legalize` adds must come after all of these.
            .SourceContinued,
            .SourceExtension,
            .MemberName,
            .String,
            .ModuleProcessed,
            .DecorationGroup,
            .GroupDecorate,
            .GroupMemberDecorate,
            .DecorateId,
            .DecorateString,
            .MemberDecorateString,
            => {
                self.annotations_end = instruction_end;
            },
            .EntryPoint => {
                if (operands.len >= 3) {
                    const name: LiteralString = literalString(operands[2..]);
                    try self.entry_points.append(gpa, .{
                        .execution_model = @fromBackingInt(@intCast(operands[0])),
                        .id = operands[1],
                        .name = name.text,
                        .interface = operands[2 + name.word_count ..],
                        .has_depth_replacing = false,
                    });
                }
                self.execution_modes_end = instruction_end;
                self.annotations_end = instruction_end;
            },
            .ExecutionMode, .ExecutionModeId => {
                const is_depth_replacing: bool = operands.len >= 2 and
                    operands[1] == @backingInt(ExecutionMode.DepthReplacing);
                if (is_depth_replacing) {
                    try depth_replacing_entries.append(gpa, operands[0]);
                }
                self.execution_modes_end = instruction_end;
                self.annotations_end = instruction_end;
            },
            .Name => {
                if (operands.len >= 2) {
                    try self.names.put(gpa, operands[0], literalString(operands[1..]).text);
                }
                self.annotations_end = instruction_end;
            },
            .Decorate => {
                if (operands.len >= 2) {
                    try self.decorate(gpa, operands, instruction.start);
                }
                self.annotations_end = instruction_end;
            },
            .MemberDecorate => {
                const is_offset: bool = operands.len >= 3 and operands[2] == @backingInt(Decoration.Offset);
                if (is_offset) {
                    const entry: AutoHashMapUnmanaged(u32, u32).Entry = try self.member_offsets.getOrPutValue(
                        gpa,
                        operands[0],
                        0,
                    );
                    entry.value_ptr.* += 1;
                }
                self.annotations_end = instruction_end;
            },
            .TypeInt,
            .TypeFloat,
            .TypeVector,
            .TypeImage,
            .TypeSampler,
            .TypeSampledImage,
            .TypeArray,
            .TypeRuntimeArray,
            .TypeStruct,
            .TypePointer,
            => {
                if (operands.len >= 1) {
                    try self.types.put(gpa, operands[0], instruction);
                }
            },
            .Variable => {
                // Global variables only: a function's locals live in the Function storage class.
                const is_global: bool = operands.len >= 3 and operands[2] != @backingInt(StorageClass.Function);
                if (is_global) {
                    try self.variables.put(gpa, operands[1], .{
                        .pointer_type = operands[0],
                        .storage_class = @fromBackingInt(@intCast(operands[2])),
                    });
                }
            },
            // Either form gives a pointer type's `ArrayStride` its meaning.
            .PtrAccessChain, .InBoundsPtrAccessChain => {
                self.has_ptr_access_chain = true;
            },
            else => {},
        }
    }

    fn decorate(
        self: *Module,
        gpa: Allocator,
        operands: []const u32,
        start: usize,
    ) Error!void {
        const target: u32 = operands[0];
        const no_decorations: Decorations = .{};
        const entry: AutoHashMapUnmanaged(u32, Decorations).Entry = try self.decorations.getOrPutValue(
            gpa,
            target,
            no_decorations,
        );
        const decorations: *Decorations = entry.value_ptr;
        const literal: ?u32 = if (operands.len >= 3) operands[2] else null;
        switch (@as(Decoration, @fromBackingInt(@intCast(operands[1])))) {
            .DescriptorSet => decorations.descriptor_set = literal,
            .Binding => decorations.binding = literal,
            .Location => decorations.location = literal,
            .BuiltIn => decorations.builtin = if (literal) |value| @fromBackingInt(@intCast(value)) else null,
            .NonWritable => decorations.non_writable = true,
            .Block, .BufferBlock => decorations.block = true,
            .ArrayStride => decorations.array_stride_start = start,
            else => {},
        }
    }

    pub fn deinit(self: *Module, gpa: Allocator) void {
        self.capabilities.deinit(gpa);
        self.entry_points.deinit(gpa);
        self.names.deinit(gpa);
        self.decorations.deinit(gpa);
        self.member_offsets.deinit(gpa);
        self.types.deinit(gpa);
        self.variables.deinit(gpa);
    }

    fn decorationsOf(self: Module, id: u32) Decorations {
        return self.decorations.get(id) orelse .{};
    }

    fn hasCapability(self: Module, capability: Capability) bool {
        for (self.capabilities.items) |declared| {
            if (declared == capability) {
                return true;
            }
        }
        return false;
    }

    /// The type a pointer type points at, if `pointer_type` is one.
    fn pointee(self: Module, pointer_type: u32) ?u32 {
        const declaration: Instruction = self.types.get(pointer_type) orelse return null;
        if (declaration.op != .TypePointer or declaration.operands.len < 3) {
            return null;
        }
        return declaration.operands[2];
    }

    /// The type with its arrays peeled off: an array of samplers binds as samplers.
    fn elementType(self: Module, type_id: u32) u32 {
        var current: u32 = type_id;
        while (self.types.get(current)) |declaration| {
            const is_array: bool = declaration.op == .TypeArray or declaration.op == .TypeRuntimeArray;
            if (!is_array or declaration.operands.len < 2) {
                break;
            }
            current = declaration.operands[1];
        }
        return current;
    }
};

// ---- Reflection ----

/// What a global binds as, in the descriptor set it lives in.
pub const ResourceKind = enum { none, uniform_buffer, storage_buffer, sampler, sampled_image, storage_image };

/// A vertex input's components: their kind, width in bits, and count.
pub const Component = struct {
    kind: enum { float, signed, unsigned },
    bits: u32,
    count: u32,
};

/// One global an entry point uses.
pub const Global = struct {
    id: u32,
    name: []const u8,
    storage_class: StorageClass,
    resource: ResourceKind,
    descriptor_set: ?u32,
    binding: ?u32,
    location: ?u32,
    builtin: ?BuiltIn,
    non_writable: bool,
    /// For an input or output: its components (null for a built-in struct or an unknown type).
    component: ?Component,
};

/// An entry point and every global it uses. `globals` is owned; `deinit` frees it.
pub const Reflection = struct {
    execution_model: ExecutionModel,
    entry_id: u32,
    globals: []Global,

    pub fn deinit(self: Reflection, gpa: Allocator) void {
        gpa.free(self.globals);
    }
};

fn isBufferBlock(module: Module, type_id: u32) bool {
    // `Decorations.block` covers Block and BufferBlock alike; tell them apart by scanning the annotations.
    var reader: InstructionReader = InstructionReader.init(module.words) catch return false;
    while (reader.next() catch return false) |instruction| {
        const is_buffer_block_decoration: bool = instruction.op == .Decorate and instruction.operands.len >= 2 and
            instruction.operands[0] == type_id and instruction.operands[1] == @backingInt(Decoration.BufferBlock);
        if (is_buffer_block_decoration) {
            return true;
        }
    }
    return false;
}

fn resourceKind(module: Module, storage_class: StorageClass, type_id: u32) ResourceKind {
    switch (storage_class) {
        .Uniform => {
            // An old-style storage buffer is a Uniform struct decorated BufferBlock.
            const is_buffer_block: bool = module.decorationsOf(type_id).block and
                module.decorations.get(type_id) != null and isBufferBlock(module, type_id);
            return if (is_buffer_block) .storage_buffer else .uniform_buffer;
        },
        .StorageBuffer => return .storage_buffer,
        .UniformConstant => {
            const element: u32 = module.elementType(type_id);
            const declaration: Instruction = module.types.get(element) orelse return .none;
            switch (declaration.op) {
                .TypeSampler => return .sampler,
                .TypeImage => {
                    // Operand 6 of OpTypeImage: 1 = used with a sampler, 2 = used without (a storage image).
                    const sampled: u32 = if (declaration.operands.len > 6) declaration.operands[6] else 1;
                    return if (sampled == 2) .storage_image else .sampled_image;
                },
                .TypeSampledImage => return .sampled_image,
                else => return .none,
            }
        },
        else => return .none,
    }
}

fn componentOf(module: Module, type_id: u32) ?Component {
    const declaration: Instruction = module.types.get(type_id) orelse return null;
    switch (declaration.op) {
        .TypeFloat => return .{ .kind = .float, .bits = declaration.operands[1], .count = 1 },
        .TypeInt => {
            const signed: bool = declaration.operands.len > 2 and declaration.operands[2] == 1;
            return .{ .kind = if (signed) .signed else .unsigned, .bits = declaration.operands[1], .count = 1 };
        },
        .TypeVector => {
            const scalar: Component = componentOf(module, declaration.operands[1]) orelse return null;
            return .{ .kind = scalar.kind, .bits = scalar.bits, .count = declaration.operands[2] };
        },
        else => return null,
    }
}

fn describeGlobal(module: Module, global_id: u32, variable: Module.Variable) Global {
    const decorations: Decorations = module.decorationsOf(global_id);
    const pointee_type: ?u32 = module.pointee(variable.pointer_type);
    var resource: ResourceKind = .none;
    var component: ?Component = null;
    if (pointee_type) |type_id| {
        resource = resourceKind(module, variable.storage_class, type_id);
        const is_stage_variable: bool = variable.storage_class == .Input or variable.storage_class == .Output;
        if (is_stage_variable) {
            component = componentOf(module, type_id);
        }
    }
    return .{
        .id = global_id,
        .name = module.names.get(global_id) orelse "",
        .storage_class = variable.storage_class,
        .resource = resource,
        .descriptor_set = decorations.descriptor_set,
        .binding = decorations.binding,
        .location = decorations.location,
        .builtin = decorations.builtin,
        .non_writable = decorations.non_writable,
        .component = component,
    };
}

/// The interface of the entry point named `entry_name`: what the host needs to lay out descriptor sets and vertex
/// inputs for it.
pub fn reflect(
    gpa: Allocator,
    words: []const u32,
    entry_name: []const u8,
) Error!Reflection {
    var module: Module = try .parse(gpa, words);
    defer module.deinit(gpa);
    for (module.entry_points.items) |entry_point| {
        if (eql(u8, entry_point.name, entry_name)) {
            const globals: []Global = try gpa.alloc(Global, entry_point.interface.len);
            var global_count: usize = 0;
            for (entry_point.interface) |global_id| {
                const variable: Module.Variable = module.variables.get(global_id) orelse continue;
                globals[global_count] = describeGlobal(module, global_id, variable);
                global_count += 1;
            }
            return .{
                .execution_model = entry_point.execution_model,
                .entry_id = entry_point.id,
                .globals = try gpa.realloc(globals, global_count),
            };
        }
    }
    return Error.NoSuchEntryPoint;
}

// ---- Checking ----

pub const ViolationKind = enum {
    /// A capability other than `Shader` (Linkage included).
    capability_not_allowed,
    /// A uniform, storage buffer, sampler or image without both `DescriptorSet` and `Binding`.
    resource_without_binding,
    /// A graphics input or output with neither `Location` nor `BuiltIn`.
    stage_variable_without_location,
    /// A `Block` struct with a member that has no `Offset`.
    block_member_without_offset,
    /// A function parameter that is a pointer into storage memory (needs the VariablePointers capability).
    storage_pointer_parameter,
    /// A call to a kompute stand-in for an atomic or a barrier.
    kompute_helper,
    /// A conditional branch with no merge instruction before it that is not a loop's break or continue.
    branch_without_merge,
    /// A fragment shader writes `FragDepth` without `DepthReplacing` (legalize closes it).
    depth_written_without_depth_replacing,
    /// A vertex-stage storage buffer without `NonWritable` (legalize closes it when the buffer is never written).
    vertex_storage_without_non_writable,
    /// `OpSource` declares the Zig source language, which validators from before 2024 reject (legalize declares
    /// `Unknown`).
    zig_source_language,
    /// A struct holding a runtime array without `Block` (legalize refuses the module).
    runtime_array_outside_block,
};

/// One rule a module breaks, and the id it breaks it on (0 when the rule is about the module as a whole).
pub const Violation = struct {
    kind: ViolationKind,
    id: u32,
};

fn pointerClass(module: Module, type_id: u32) ?StorageClass {
    const declaration: Instruction = module.types.get(type_id) orelse return null;
    if (declaration.op != .TypePointer or declaration.operands.len < 2) {
        return null;
    }
    return @fromBackingInt(@intCast(declaration.operands[1]));
}

fn writesFragDepth(module: Module, entry_point: EntryPoint) bool {
    for (entry_point.interface) |global_id| {
        const variable: Module.Variable = module.variables.get(global_id) orelse continue;
        const is_frag_depth: bool = variable.storage_class == .Output and
            module.decorationsOf(global_id).builtin == .FragDepth;
        if (is_frag_depth) {
            return true;
        }
    }
    return false;
}

fn isUndecoratedStorage(module: Module, global_id: u32) bool {
    const variable: Module.Variable = module.variables.get(global_id) orelse return false;
    return variable.storage_class == .StorageBuffer and !module.decorationsOf(global_id).non_writable;
}

fn checkVariable(
    gpa: Allocator,
    module: Module,
    variable_id: u32,
    variable: Module.Variable,
    violations: *ArrayList(Violation),
) Error!void {
    const decorations: Decorations = module.decorationsOf(variable_id);
    switch (variable.storage_class) {
        .UniformConstant, .Uniform, .StorageBuffer => {
            if (decorations.descriptor_set == null or decorations.binding == null) {
                try violations.append(gpa, .{ .kind = .resource_without_binding, .id = variable_id });
            }
        },
        .Input, .Output => {
            // Compute entries have built-in inputs only; a graphics stage variable needs a location or a built-in.
            const pointee_type: ?u32 = module.pointee(variable.pointer_type);
            const has_member_builtins: bool = if (pointee_type) |type_id| module.member_offsets.get(type_id) == null and
                module.decorationsOf(type_id).builtin != null else false;
            const is_placed: bool = decorations.location != null or decorations.builtin != null or has_member_builtins;
            if (!is_placed) {
                try violations.append(gpa, .{ .kind = .stage_variable_without_location, .id = variable_id });
            }
        },
        else => {},
    }
}

fn checkBlockOffsets(
    gpa: Allocator,
    module: Module,
    struct_id: u32,
    violations: *ArrayList(Violation),
) Error!void {
    const declaration: Instruction = module.types.get(struct_id) orelse return;
    if (declaration.op != .TypeStruct) {
        return;
    }
    const member_count: usize = declaration.operands.len - 1;
    const offset_count: u32 = module.member_offsets.get(struct_id) orelse 0;
    if (offset_count < member_count) {
        try violations.append(gpa, .{ .kind = .block_member_without_offset, .id = struct_id });
    }
}

/// Inside functions: storage pointers passed as parameters, and conditional branches without a merge. A merge-less
/// `OpBranchConditional` is structured when it leaves a loop - one of its targets is a loop's merge block or continue
/// target, declared by an `OpLoopMerge` earlier in the function (a loop header precedes its body).
fn checkFunctions(
    gpa: Allocator,
    module: Module,
    violations: *ArrayList(Violation),
) Error!void {
    var loop_exits: AutoHashMapUnmanaged(u32, void) = .empty;
    defer loop_exits.deinit(gpa);
    var previous_op: Op = .Name;
    var reader: InstructionReader = try .init(module.words);
    while (try reader.next()) |instruction| {
        const operands: []const u32 = instruction.operands;
        switch (instruction.op) {
            .Function => loop_exits.clearRetainingCapacity(),
            .FunctionParameter => {
                const pointee_class: ?StorageClass = pointerClass(module, operands[0]);
                const is_storage_pointer: bool = pointee_class != null and
                    (pointee_class.? == .StorageBuffer or pointee_class.? == .Uniform or pointee_class.? == .Workgroup);
                if (is_storage_pointer) {
                    try violations.append(gpa, .{ .kind = .storage_pointer_parameter, .id = operands[1] });
                }
            },
            .LoopMerge => {
                try loop_exits.put(gpa, operands[0], {});
                try loop_exits.put(gpa, operands[1], {});
            },
            .BranchConditional => {
                const has_merge: bool = previous_op == .SelectionMerge or previous_op == .LoopMerge;
                const leaves_loop: bool = loop_exits.contains(operands[1]) or loop_exits.contains(operands[2]);
                if (!has_merge and !leaves_loop) {
                    try violations.append(gpa, .{ .kind = .branch_without_merge, .id = operands[0] });
                }
            },
            .Switch => {
                if (previous_op != .SelectionMerge) {
                    try violations.append(gpa, .{ .kind = .branch_without_merge, .id = operands[0] });
                }
            },
            else => {},
        }
        previous_op = instruction.op;
    }
}

/// What a module does with its global variables' memory, seen through every pointer derived from them (access
/// chains, copies). WRITTEN: a store, a memory copy or an atomic modifies it. ESCAPED: a pointer to it is passed to a
/// function, whose body this analysis does not follow - so whether it is written is unknown.
const StorageUses = struct {
    written: AutoHashMapUnmanaged(u32, void) = .empty,
    escaped: AutoHashMapUnmanaged(u32, void) = .empty,

    fn deinit(uses: *StorageUses, gpa: Allocator) void {
        uses.written.deinit(gpa);
        uses.escaped.deinit(gpa);
    }

    /// Never written and never escaped: provably read-only, so `NonWritable` may be declared.
    fn isProvablyReadOnly(uses: StorageUses, variable_id: u32) bool {
        return !uses.written.contains(variable_id) and !uses.escaped.contains(variable_id);
    }
};

fn storageUses(gpa: Allocator, module: Module) Error!StorageUses {
    // Each derived pointer's root variable, by result id.
    var roots: AutoHashMapUnmanaged(u32, u32) = .empty;
    defer roots.deinit(gpa);
    var uses: StorageUses = .{};
    errdefer uses.deinit(gpa);
    var reader: InstructionReader = try .init(module.words);
    while (try reader.next()) |instruction| {
        const operands: []const u32 = instruction.operands;
        const opcode: u16 = @backingInt(instruction.op);
        switch (instruction.op) {
            .AccessChain, .InBoundsAccessChain, .PtrAccessChain, .CopyObject => {
                if (operands.len >= 3) {
                    const base: u32 = operands[2];
                    try roots.put(gpa, operands[1], roots.get(base) orelse base);
                }
            },
            .Store, .CopyMemory, .AtomicStore => {
                if (operands.len >= 1) {
                    try uses.written.put(gpa, roots.get(operands[0]) orelse operands[0], {});
                }
            },
            .FunctionCall => {
                // Result type, result id, the function, then the arguments.
                if (operands.len > 3) {
                    for (operands[3..]) |argument| {
                        try uses.escaped.put(gpa, roots.get(argument) orelse argument, {});
                    }
                }
            },
            else => {
                // OpAtomicExchange .. OpAtomicXor: result type, result id, then the pointer they modify.
                const is_atomic_write: bool = opcode >= @backingInt(Op.AtomicExchange) and
                    opcode <= @backingInt(Op.AtomicXor);
                if (is_atomic_write and operands.len >= 3) {
                    try uses.written.put(gpa, roots.get(operands[2]) orelse operands[2], {});
                }
            },
        }
    }
    return uses;
}

/// The first struct type that holds a runtime-sized array without the `Block` decoration, or null. Vulkan allows a
/// runtime array only as the last member of a `Block` struct, and rejects any other struct holding one, used or not
/// (VUID-StandaloneSpirv-OpTypeRuntimeArray-04680). (`BufferBlock`, the spelling before SPIR-V 1.3, is not emitted by
/// the compiler.)
fn structWithRuntimeArrayOutsideBlock(module: Module) ?u32 {
    var type_iterator: AutoHashMapUnmanaged(u32, Instruction).Iterator = module.types.iterator();
    while (type_iterator.next()) |entry| {
        const struct_id: u32 = entry.key_ptr.*;
        const declaration: Instruction = entry.value_ptr.*;
        if (declaration.op != .TypeStruct or module.decorationsOf(struct_id).block) {
            continue;
        }
        const member_types: []const u32 = declaration.operands[1..];
        for (member_types) |member_type| {
            const member: Instruction = module.types.get(member_type) orelse continue;
            if (member.op == .TypeRuntimeArray) {
                return struct_id;
            }
        }
    }
    return null;
}

/// The gaps `legalize` closes, reported so a raw module's check says what loading it will change.
fn checkGaps(
    gpa: Allocator,
    module: Module,
    violations: *ArrayList(Violation),
) Error!void {
    var uses: StorageUses = try storageUses(gpa, module);
    defer uses.deinit(gpa);
    if (module.declares_zig_source) {
        try violations.append(gpa, .{ .kind = .zig_source_language, .id = 0 });
    }
    if (structWithRuntimeArrayOutsideBlock(module)) |struct_id| {
        try violations.append(gpa, .{ .kind = .runtime_array_outside_block, .id = struct_id });
    }
    for (module.entry_points.items) |entry_point| {
        if (entry_point.execution_model == .Fragment and !entry_point.has_depth_replacing) {
            if (writesFragDepth(module, entry_point)) {
                try violations.append(gpa, .{ .kind = .depth_written_without_depth_replacing, .id = entry_point.id });
            }
        }
        if (entry_point.execution_model == .Vertex) {
            for (entry_point.interface) |global_id| {
                // Only what `legalize` closes: undecorated, and provably read-only (a written buffer it refuses; an
                // escaped one it leaves to the device's vertex-stores feature).
                if (isUndecoratedStorage(module, global_id) and uses.isProvablyReadOnly(global_id)) {
                    try violations.append(gpa, .{ .kind = .vertex_storage_without_non_writable, .id = global_id });
                }
            }
        }
    }
}

/// Every rule zimr knows that `words` breaks - the native twin of spv2wgsl's build-time refusals, run without a GPU.
/// An empty list is a pass. A module straight from the compiler may still show the gaps `legalize` closes; the gate
/// checks `legalize`'s output.
pub fn check(gpa: Allocator, words: []const u32) Error![]Violation {
    var module: Module = try .parse(gpa, words);
    defer module.deinit(gpa);
    var violations: ArrayList(Violation) = .empty;
    errdefer violations.deinit(gpa);

    for (module.capabilities.items) |capability| {
        if (capability != .Shader) {
            try violations.append(gpa, .{ .kind = .capability_not_allowed, .id = @backingInt(capability) });
        }
    }
    var variable_iterator: AutoHashMapUnmanaged(u32, Module.Variable).Iterator = module.variables.iterator();
    while (variable_iterator.next()) |entry| {
        try checkVariable(gpa, module, entry.key_ptr.*, entry.value_ptr.*, &violations);
    }
    var decoration_iterator: AutoHashMapUnmanaged(u32, Decorations).Iterator = module.decorations.iterator();
    while (decoration_iterator.next()) |entry| {
        if (entry.value_ptr.block) {
            try checkBlockOffsets(gpa, module, entry.key_ptr.*, &violations);
        }
    }
    var name_iterator: AutoHashMapUnmanaged(u32, []const u8).Iterator = module.names.iterator();
    while (name_iterator.next()) |entry| {
        for (kompute_helper_names) |helper_name| {
            if (indexOf(u8, entry.value_ptr.*, helper_name) != null) {
                try violations.append(gpa, .{ .kind = .kompute_helper, .id = entry.key_ptr.* });
            }
        }
    }
    try checkFunctions(gpa, module, &violations);
    try checkGaps(gpa, module, &violations);
    return violations.toOwnedSlice(gpa);
}

// ---- Legalizing ----

/// A copy of `words` that Vulkan accepts: `DepthReplacing` declared where `FragDepth` is written, vertex-stage
/// storage buffers decorated `NonWritable`, pointer-type `ArrayStride`s dropped when nothing uses them, the Zig
/// source language declared `Unknown` - and `Linkage`, or a struct holding a runtime array without `Block`, refused.
/// The copy is owned (free it with `gpa.free`) and 4-byte aligned, as `vkCreateShaderModule` requires (an
/// `@embedFile` is only byte aligned).
/// Legalizing a legal module returns an identical copy.
pub fn legalize(gpa: Allocator, words: []const u32) Error![]u32 {
    var module: Module = try .parse(gpa, words);
    defer module.deinit(gpa);
    if (module.hasCapability(.Linkage)) {
        return Error.LinkageCapability;
    }

    // 1. The execution modes to add: DepthReplacing for every fragment entry that writes FragDepth.
    var new_execution_modes: ArrayList(u32) = .empty;
    defer new_execution_modes.deinit(gpa);
    for (module.entry_points.items) |entry_point| {
        const needs_depth_replacing: bool = entry_point.execution_model == .Fragment and
            !entry_point.has_depth_replacing and writesFragDepth(module, entry_point);
        if (needs_depth_replacing) {
            try new_execution_modes.appendSlice(gpa, &.{
                instructionHead(.ExecutionMode, 3),
                entry_point.id,
                @backingInt(ExecutionMode.DepthReplacing),
            });
        }
    }

    // 2. The decorations to add: NonWritable on every vertex-stage storage buffer that is provably read-only. A
    // written one is refused; one whose pointer escapes into a function call is left undecorated - legal under the
    // device's vertex-stores feature, which the host enables - rather than guessed read-only.
    var new_decorations: ArrayList(u32) = .empty;
    defer new_decorations.deinit(gpa);
    var decorated: AutoHashMapUnmanaged(u32, void) = .empty;
    defer decorated.deinit(gpa);
    var uses: StorageUses = try storageUses(gpa, module);
    defer uses.deinit(gpa);
    for (module.entry_points.items) |entry_point| {
        if (entry_point.execution_model != .Vertex) {
            continue;
        }
        for (entry_point.interface) |global_id| {
            if (!isUndecoratedStorage(module, global_id) or decorated.contains(global_id)) {
                continue;
            }
            if (uses.written.contains(global_id)) {
                return Error.VertexStageStorageWrite;
            }
            if (uses.escaped.contains(global_id)) {
                continue;
            }
            try decorated.put(gpa, global_id, {});
            try new_decorations.appendSlice(gpa, &.{
                instructionHead(.Decorate, 3),
                global_id,
                @backingInt(Decoration.NonWritable),
            });
        }
    }

    // 3. The instructions to drop: ArrayStride on a pointer type, when the module has no OpPtrAccessChain.
    var dropped_starts: AutoHashMapUnmanaged(usize, void) = .empty;
    defer dropped_starts.deinit(gpa);
    if (!module.has_ptr_access_chain) {
        var decoration_iterator: AutoHashMapUnmanaged(u32, Decorations).Iterator = module.decorations.iterator();
        while (decoration_iterator.next()) |entry| {
            const stride_start: usize = entry.value_ptr.array_stride_start orelse continue;
            const declaration: ?Instruction = module.types.get(entry.key_ptr.*);
            const is_pointer: bool = declaration != null and declaration.?.op == .TypePointer;
            if (is_pointer) {
                try dropped_starts.put(gpa, stride_start, {});
            }
        }
    }

    // A struct holding a runtime array without Block cannot be expressed in Vulkan, used or not.
    if (structWithRuntimeArrayOutsideBlock(module) != null) {
        return Error.RuntimeArrayOutsideBlock;
    }

    // 4. The copy: every instruction in order, the new ones at their sections' ends, the dropped ones skipped.
    var legal: ArrayList(u32) = .empty;
    errdefer legal.deinit(gpa);
    const added_word_count: usize = new_execution_modes.items.len + new_decorations.items.len;
    try legal.ensureTotalCapacity(gpa, words.len + added_word_count);
    try legal.appendSlice(gpa, words[0..header_word_count]);
    var reader: InstructionReader = try .init(words);
    while (try reader.next()) |instruction| {
        if (instruction.start == module.execution_modes_end) {
            try legal.appendSlice(gpa, new_execution_modes.items);
        }
        if (instruction.start == module.annotations_end) {
            try legal.appendSlice(gpa, new_decorations.items);
        }
        if (!dropped_starts.contains(instruction.start)) {
            const copy_start: usize = legal.items.len;
            try legal.appendSlice(gpa, words[instruction.start .. instruction.start + instruction.word_count]);
            // OpSource Zig becomes OpSource Unknown, in place: the same length, so every section offset holds.
            const is_zig_source: bool = instruction.op == .Source and instruction.word_count >= 2 and
                legal.items[copy_start + 1] == source_language_zig;
            if (is_zig_source) {
                legal.items[copy_start + 1] = source_language_unknown;
            }
        }
    }
    // A module that ends with its execution modes or annotations (no types, no functions) gets them at the end.
    if (module.execution_modes_end == words.len) {
        try legal.appendSlice(gpa, new_execution_modes.items);
    }
    if (module.annotations_end == words.len) {
        try legal.appendSlice(gpa, new_decorations.items);
    }
    return legal.toOwnedSlice(gpa);
}

// ---- Tests ----

// The two modules the 0.17.0-dev.2307 compiler emits for these shaders (`zig build-obj -target spirv32-vulkan
// -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv`, the build's own flags):
//
//     depth_fs:   out_color (location 0) = red; frag_depth (the name the backend maps to FragDepth) = 0.5
//     storage_vs: position = points.data[0], `points` a CONST storage pointer at set 0, binding 1
const depth_fs_words = [_]u32{
    0x07230203, 0x00010500, 0x00290880, 0x00000055, 0x00000000, 0x00020011, 0x00000001, 0x0003000e,
    0x00000000, 0x00000001, 0x0007000f, 0x00000004, 0x00000001, 0x6e69616d, 0x00000000, 0x0000004d,
    0x0000004c, 0x00030010, 0x00000001, 0x00000007, 0x00060007, 0x00000005, 0x74706564, 0x73665f68,
    0x67697a2e, 0x00000000, 0x00040004, 0x5f67697a, 0x6f727265, 0x003a7372, 0x00030003, 0x0000000c,
    0x00000880, 0x00040005, 0x00000002, 0x64696f76, 0x00000000, 0x00030005, 0x00000006, 0x00323366,
    0x00030005, 0x00000011, 0x00323375, 0x00060005, 0x00000001, 0x74706564, 0x73665f68, 0x69616d2e,
    0x0000006e, 0x00050005, 0x0000004c, 0x5f74756f, 0x6f6c6f63, 0x00000072, 0x00050005, 0x0000004d,
    0x67617266, 0x7065645f, 0x00006874, 0x00040047, 0x0000004c, 0x0000001e, 0x00000000, 0x00040047,
    0x0000004d, 0x0000000b, 0x00000016, 0x00020013, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x0004002b, 0x00000006, 0x00000007, 0x3f800000, 0x00040017, 0x00000009, 0x00000006, 0x00000004,
    0x00040020, 0x0000000a, 0x00000003, 0x00000009, 0x00040020, 0x00000010, 0x00000003, 0x00000006,
    0x00040015, 0x00000011, 0x00000020, 0x00000000, 0x0004002b, 0x00000011, 0x00000012, 0x00000000,
    0x0004002b, 0x00000006, 0x00000016, 0x00000000, 0x0004002b, 0x00000011, 0x00000020, 0x00000001,
    0x0004002b, 0x00000011, 0x0000002e, 0x00000002, 0x0004002b, 0x00000011, 0x0000003c, 0x00000003,
    0x0004002b, 0x00000006, 0x00000041, 0x3f000000, 0x00030001, 0x00000011, 0x0000004a, 0x00030021,
    0x0000004b, 0x00000002, 0x0004003b, 0x0000000a, 0x0000004c, 0x00000003, 0x0004003b, 0x00000010,
    0x0000004d, 0x00000003, 0x00050036, 0x00000002, 0x00000001, 0x00000000, 0x0000004b, 0x000200f8,
    0x00000004, 0x00040008, 0x00000005, 0x00000004, 0x00000005, 0x00050042, 0x00000010, 0x00000013,
    0x0000004c, 0x00000012, 0x0005003e, 0x00000013, 0x00000007, 0x00000002, 0x00000004, 0x00050042,
    0x00000010, 0x00000021, 0x0000004c, 0x00000020, 0x0005003e, 0x00000021, 0x00000016, 0x00000002,
    0x00000004, 0x00050042, 0x00000010, 0x0000002f, 0x0000004c, 0x0000002e, 0x0005003e, 0x0000002f,
    0x00000016, 0x00000002, 0x00000004, 0x00050042, 0x00000010, 0x0000003d, 0x0000004c, 0x0000003c,
    0x0005003e, 0x0000003d, 0x00000007, 0x00000002, 0x00000004, 0x00040008, 0x00000005, 0x00000005,
    0x00000005, 0x0005003e, 0x0000004d, 0x00000041, 0x00000002, 0x00000004, 0x000100fd, 0x000200f8,
    0x00000048, 0x000100ff, 0x00010038,
};

const storage_vs_words = [_]u32{
    0x07230203, 0x00010500, 0x00290880, 0x00000042, 0x00000000, 0x00020011, 0x00000001, 0x0003000e,
    0x00000000, 0x00000001, 0x0007000f, 0x00000000, 0x00000001, 0x6e69616d, 0x00000000, 0x00000035,
    0x00000034, 0x00060007, 0x00000005, 0x726f7473, 0x5f656761, 0x7a2e7376, 0x00006769, 0x00040004,
    0x5f67697a, 0x6f727265, 0x003a7372, 0x00030003, 0x0000000c, 0x00000880, 0x00040005, 0x00000002,
    0x64696f76, 0x00000000, 0x00030005, 0x00000007, 0x00323366, 0x00030005, 0x00000009, 0x00323375,
    0x00050006, 0x00000013, 0x00000000, 0x61746164, 0x00000000, 0x00070005, 0x00000013, 0x726f7473,
    0x5f656761, 0x502e7376, 0x746e696f, 0x00000073, 0x00060005, 0x00000001, 0x726f7473, 0x5f656761,
    0x6d2e7376, 0x006e6961, 0x00050005, 0x00000035, 0x69736f70, 0x6e6f6974, 0x00000000, 0x00040005,
    0x00000034, 0x6e696f70, 0x00007374, 0x00040047, 0x0000000b, 0x00000006, 0x00000010, 0x00050048,
    0x00000006, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x00000035, 0x0000000b, 0x00000000,
    0x00030047, 0x0000003b, 0x00000002, 0x00050048, 0x0000003b, 0x00000000, 0x00000023, 0x00000000,
    0x00040047, 0x00000041, 0x00000006, 0x00000040, 0x00030047, 0x00000034, 0x00000018, 0x00040047,
    0x00000034, 0x00000021, 0x00000001, 0x00040047, 0x00000034, 0x00000022, 0x00000000, 0x00020013,
    0x00000002, 0x00030016, 0x00000007, 0x00000020, 0x00040017, 0x00000008, 0x00000007, 0x00000004,
    0x00040015, 0x00000009, 0x00000020, 0x00000000, 0x0004002b, 0x00000009, 0x0000000a, 0x00000004,
    0x0004001c, 0x0000000b, 0x00000008, 0x0000000a, 0x0003001e, 0x00000006, 0x0000000b, 0x00040020,
    0x0000000c, 0x0000000c, 0x00000006, 0x0004001c, 0x00000012, 0x00000008, 0x0000000a, 0x0003001e,
    0x00000013, 0x00000012, 0x00040020, 0x00000014, 0x0000000c, 0x00000013, 0x00040020, 0x0000001a,
    0x0000000c, 0x0000000b, 0x0004002b, 0x00000009, 0x0000001c, 0x00000000, 0x00040020, 0x00000022,
    0x0000000c, 0x00000008, 0x00040020, 0x00000029, 0x00000003, 0x00000008, 0x00030001, 0x00000009,
    0x00000032, 0x00030021, 0x00000033, 0x00000002, 0x0004003b, 0x00000029, 0x00000035, 0x00000003,
    0x0003001e, 0x0000003b, 0x0000000b, 0x00040020, 0x00000041, 0x0000000c, 0x0000003b, 0x0004003b,
    0x00000041, 0x00000034, 0x0000000c, 0x00050036, 0x00000002, 0x00000001, 0x00000000, 0x00000033,
    0x000200f8, 0x00000004, 0x00040008, 0x00000005, 0x00000005, 0x0000001d, 0x00050042, 0x0000001a,
    0x0000001d, 0x00000034, 0x0000001c, 0x00050042, 0x00000022, 0x00000023, 0x0000001d, 0x0000001c,
    0x0006003d, 0x00000008, 0x00000026, 0x00000023, 0x00000002, 0x00000010, 0x0005003e, 0x00000035,
    0x00000026, 0x00000002, 0x00000010, 0x000100fd, 0x000200f8, 0x00000030, 0x000100ff, 0x00010038,
};

/// Builds SPIR-V by hand for the tests: a header, then instructions, strings packed as SPIR-V packs them.
const Assembler = struct {
    words: ArrayList(u32),

    fn init(gpa: Allocator, bound: u32) Error!Assembler {
        var assembler: Assembler = .{ .words = .empty };
        try assembler.words.appendSlice(gpa, &.{ magic_number, 0x00010500, 0, bound, 0 });
        return assembler;
    }

    fn add(self: *Assembler, gpa: Allocator, op: Op, operands: []const u32) Error!void {
        try self.words.append(gpa, instructionHead(op, @intCast(1 + operands.len)));
        try self.words.appendSlice(gpa, operands);
    }

    /// An instruction whose operands are `before`, a literal string, then `after`.
    fn addWithString(
        self: *Assembler,
        gpa: Allocator,
        op: Op,
        before: []const u32,
        text: []const u8,
        after: []const u32,
    ) Error!void {
        const string_words: usize = (text.len + 1 + 3) / 4;
        const word_count: u32 = @intCast(1 + before.len + string_words + after.len);
        try self.words.append(gpa, instructionHead(op, word_count));
        try self.words.appendSlice(gpa, before);
        const string_start: usize = self.words.items.len;
        try self.words.appendNTimes(gpa, 0, string_words);
        const string_bytes: []u8 = sliceAsBytes(self.words.items[string_start..]);
        @memcpy(string_bytes[0..text.len], text);
        try self.words.appendSlice(gpa, after);
    }

    fn deinit(self: *Assembler, gpa: Allocator) void {
        self.words.deinit(gpa);
    }
};

fn countViolations(violations: []const Violation, kind: ViolationKind) usize {
    var count: usize = 0;
    for (violations) |violation| {
        if (violation.kind == kind) {
            count += 1;
        }
    }
    return count;
}

test "spv_vulkan: the compiler's depth-writing fragment shader gains DepthReplacing, once" {
    const gpa: Allocator = testing_allocator;
    // Straight from the compiler: FragDepth written, no DepthReplacing - the gap.
    const raw_violations: []Violation = try check(gpa, &depth_fs_words);
    defer gpa.free(raw_violations);
    try expectEqual(@as(usize, 1), countViolations(raw_violations, .depth_written_without_depth_replacing));
    // Legalized: the mode is there, the module is otherwise the same plus one 3-word instruction.
    const legal: []u32 = try legalize(gpa, &depth_fs_words);
    defer gpa.free(legal);
    try expectEqual(depth_fs_words.len + 3, legal.len);
    const legal_violations: []Violation = try check(gpa, legal);
    defer gpa.free(legal_violations);
    try expectEqual(@as(usize, 0), legal_violations.len);
    // Legalizing a legal module changes nothing.
    const again: []u32 = try legalize(gpa, legal);
    defer gpa.free(again);
    try expect(eql(u32, legal, again));
}

test "spv_vulkan: the compiler's storage-reading vertex shader: const storage arrives NonWritable" {
    const gpa: Allocator = testing_allocator;
    // This vertex shader's storage pointer is const, so the compiler decorated it NonWritable already; the only
    // change is dropping the unused pointer-type ArrayStride - `OpDecorate %ptr ArrayStride 64`, four words (the
    // head, the target, the decoration, the stride).
    const legal: []u32 = try legalize(gpa, &storage_vs_words);
    defer gpa.free(legal);
    try expectEqual(storage_vs_words.len - 4, legal.len);
    const violations: []Violation = try check(gpa, legal);
    defer gpa.free(violations);
    try expectEqual(@as(usize, 0), violations.len);
    const reflection: Reflection = try reflect(gpa, legal, "main");
    defer reflection.deinit(gpa);
    try expectEqual(ExecutionModel.Vertex, reflection.execution_model);
    var found_storage: bool = false;
    for (reflection.globals) |global| {
        if (global.resource == .storage_buffer) {
            found_storage = true;
            try expectEqual(@as(?u32, 0), global.descriptor_set);
            try expectEqual(@as(?u32, 1), global.binding);
            try expect(global.non_writable);
        }
    }
    try expect(found_storage);
}

/// How the assembled vertex shader uses its storage buffer.
const StorageAccess = enum { read, write, pass_to_function };

/// A vertex shader reading a storage buffer through a NON-const pointer (zimr's `StorageBufferPtr`): no NonWritable.
/// `.write` adds a store through an access chain; `.pass_to_function` passes the buffer to a function instead.
fn assembleVertexStorage(gpa: Allocator, access: StorageAccess) Error![]u32 {
    var assembler: Assembler = try .init(gpa, 40);
    errdefer assembler.deinit(gpa);
    try assembler.add(gpa, .Capability, &.{@backingInt(Capability.Shader)});
    try assembler.add(gpa, .MemoryModel, &.{ 0, 1 });
    // %1 main, interface: %20 (the storage buffer), %21 (the position output).
    try assembler.addWithString(gpa, .EntryPoint, &.{ @backingInt(ExecutionModel.Vertex), 1 }, "main", &.{ 20, 21 });
    try assembler.addWithString(gpa, .Name, &.{20}, "points", &.{});
    try assembler.add(gpa, .Decorate, &.{ 20, @backingInt(Decoration.DescriptorSet), 0 });
    try assembler.add(gpa, .Decorate, &.{ 20, @backingInt(Decoration.Binding), 1 });
    try assembler.add(gpa, .Decorate, &.{ 21, @backingInt(Decoration.BuiltIn), @backingInt(BuiltIn.Position) });
    try assembler.add(gpa, .Decorate, &.{ 11, @backingInt(Decoration.Block) });
    try assembler.add(gpa, .MemberDecorate, &.{ 11, 0, @backingInt(Decoration.Offset), 0 });
    // %10 f32, %12 vec4, %11 struct { vec4 }, %13 pointer StorageBuffer struct, %14 pointer Output vec4.
    try assembler.add(gpa, .TypeFloat, &.{ 10, 32 });
    try assembler.add(gpa, .TypeVector, &.{ 12, 10, 4 });
    try assembler.add(gpa, .TypeStruct, &.{ 11, 12 });
    try assembler.add(gpa, .TypePointer, &.{ 13, @backingInt(StorageClass.StorageBuffer), 11 });
    try assembler.add(gpa, .TypePointer, &.{ 14, @backingInt(StorageClass.Output), 12 });
    try assembler.add(gpa, .TypePointer, &.{ 15, @backingInt(StorageClass.StorageBuffer), 12 });
    try assembler.add(gpa, .Variable, &.{ 13, 20, @backingInt(StorageClass.StorageBuffer) });
    try assembler.add(gpa, .Variable, &.{ 14, 21, @backingInt(StorageClass.Output) });
    switch (access) {
        .read => {},
        .write => {
            // %30 = OpAccessChain %15 %20 %(index); OpStore %30 %(value) - a write into the buffer.
            try assembler.add(gpa, .AccessChain, &.{ 15, 30, 20, 31 });
            try assembler.add(gpa, .Store, &.{ 30, 32 });
        },
        .pass_to_function => {
            // %34 = OpFunctionCall %(void) %(function) %20 - the buffer's pointer escapes into a function.
            try assembler.add(gpa, .FunctionCall, &.{ 33, 34, 35, 20 });
        },
    }
    return assembler.words.toOwnedSlice(gpa);
}

test "spv_vulkan: a vertex shader's read-only storage gains NonWritable; a written one is refused by name" {
    const gpa: Allocator = testing_allocator;
    const read_only: []u32 = try assembleVertexStorage(gpa, .read);
    defer gpa.free(read_only);
    const raw_violations: []Violation = try check(gpa, read_only);
    defer gpa.free(raw_violations);
    try expectEqual(@as(usize, 1), countViolations(raw_violations, .vertex_storage_without_non_writable));
    const legal: []u32 = try legalize(gpa, read_only);
    defer gpa.free(legal);
    try expectEqual(read_only.len + 3, legal.len);
    const reflection: Reflection = try reflect(gpa, legal, "main");
    defer reflection.deinit(gpa);
    for (reflection.globals) |global| {
        if (global.id == 20) {
            try expect(global.non_writable);
            try expectEqualStrings("points", global.name);
        }
    }
    const written: []u32 = try assembleVertexStorage(gpa, .write);
    defer gpa.free(written);
    try expectError(Error.VertexStageStorageWrite, legalize(gpa, written));
}

test "spv_vulkan: Linkage is refused; a missing binding, location or offset is reported" {
    const gpa: Allocator = testing_allocator;
    var assembler: Assembler = try .init(gpa, 40);
    defer assembler.deinit(gpa);
    try assembler.add(gpa, .Capability, &.{@backingInt(Capability.Shader)});
    try assembler.add(gpa, .Capability, &.{@backingInt(Capability.Linkage)});
    try assembler.add(gpa, .MemoryModel, &.{ 0, 1 });
    try assembler.addWithString(gpa, .EntryPoint, &.{ @backingInt(ExecutionModel.Fragment), 1 }, "main", &.{ 20, 21 });
    // %11 a Block struct with two members, only one with an Offset.
    try assembler.add(gpa, .Decorate, &.{ 11, @backingInt(Decoration.Block) });
    try assembler.add(gpa, .MemberDecorate, &.{ 11, 0, @backingInt(Decoration.Offset), 0 });
    try assembler.add(gpa, .TypeFloat, &.{ 10, 32 });
    try assembler.add(gpa, .TypeStruct, &.{ 11, 10, 10 });
    try assembler.add(gpa, .TypePointer, &.{ 13, @backingInt(StorageClass.Uniform), 11 });
    try assembler.add(gpa, .TypePointer, &.{ 14, @backingInt(StorageClass.Input), 10 });
    // %20 a uniform with no DescriptorSet or Binding; %21 an input with no Location.
    try assembler.add(gpa, .Variable, &.{ 13, 20, @backingInt(StorageClass.Uniform) });
    try assembler.add(gpa, .Variable, &.{ 14, 21, @backingInt(StorageClass.Input) });
    const violations: []Violation = try check(gpa, assembler.words.items);
    defer gpa.free(violations);
    try expectEqual(@as(usize, 1), countViolations(violations, .capability_not_allowed));
    try expectEqual(@as(usize, 1), countViolations(violations, .resource_without_binding));
    try expectEqual(@as(usize, 1), countViolations(violations, .stage_variable_without_location));
    try expectEqual(@as(usize, 1), countViolations(violations, .block_member_without_offset));
    try expectError(Error.LinkageCapability, legalize(gpa, assembler.words.items));
}

test "spv_vulkan: storage pointers into functions, kompute helpers and merge-less branches are reported" {
    const gpa: Allocator = testing_allocator;
    var assembler: Assembler = try .init(gpa, 60);
    defer assembler.deinit(gpa);
    try assembler.add(gpa, .Capability, &.{@backingInt(Capability.Shader)});
    try assembler.add(gpa, .MemoryModel, &.{ 0, 1 });
    try assembler.addWithString(gpa, .Name, &.{40}, "kompute.zatomicAdd__anon_7", &.{});
    try assembler.add(gpa, .TypeFloat, &.{ 10, 32 });
    try assembler.add(gpa, .TypePointer, &.{ 13, @backingInt(StorageClass.StorageBuffer), 10 });
    // A function taking a storage pointer.
    try assembler.add(gpa, .Function, &.{ 10, 40, 0, 41 });
    try assembler.add(gpa, .FunctionParameter, &.{ 13, 42 });
    // A loop: its merge %51 and continue %52; a break to %51 needs no merge of its own, a branch to %53 does.
    try assembler.add(gpa, .LoopMerge, &.{ 51, 52, 0 });
    try assembler.add(gpa, .BranchConditional, &.{ 60, 54, 55 });
    try assembler.add(gpa, .BranchConditional, &.{ 61, 51, 55 });
    try assembler.add(gpa, .BranchConditional, &.{ 62, 53, 55 });
    const violations: []Violation = try check(gpa, assembler.words.items);
    defer gpa.free(violations);
    try expectEqual(@as(usize, 1), countViolations(violations, .storage_pointer_parameter));
    try expectEqual(@as(usize, 1), countViolations(violations, .kompute_helper));
    try expectEqual(@as(usize, 1), countViolations(violations, .branch_without_merge));
}

test "spv_vulkan: reflect names every global of the compiler's fragment shader" {
    const gpa: Allocator = testing_allocator;
    const reflection: Reflection = try reflect(gpa, &depth_fs_words, "main");
    defer reflection.deinit(gpa);
    try expectEqual(ExecutionModel.Fragment, reflection.execution_model);
    try expectEqual(@as(usize, 2), reflection.globals.len);
    var found_color: bool = false;
    var found_depth: bool = false;
    for (reflection.globals) |global| {
        if (global.builtin == .FragDepth) {
            found_depth = true;
            try expectEqual(StorageClass.Output, global.storage_class);
        }
        if (global.location) |location| {
            found_color = true;
            try expectEqual(@as(u32, 0), location);
            const component: Component = global.component.?;
            try expectEqual(@as(u32, 4), component.count);
            try expectEqual(@as(u32, 32), component.bits);
        }
    }
    try expect(found_color and found_depth);
    try expectError(Error.NoSuchEntryPoint, reflect(gpa, &depth_fs_words, "not_main"));
}

test "spv_vulkan: words that are not SPIR-V, or end mid-instruction, are refused" {
    const gpa: Allocator = testing_allocator;
    const not_spirv = [_]u32{ 0x12345678, 0, 0, 0, 0 };
    try expectError(Error.NotSpirv, legalize(gpa, &not_spirv));
    const truncated = [_]u32{ magic_number, 0x00010500, 0, 10, 0, instructionHead(.Capability, 4), 1 };
    try expectError(Error.Truncated, legalize(gpa, &truncated));
}

test "spv_vulkan: a storage buffer passed into a function is neither decorated nor refused" {
    const gpa: Allocator = testing_allocator;
    const escaping: []u32 = try assembleVertexStorage(gpa, .pass_to_function);
    defer gpa.free(escaping);
    // Not provably read-only: no NonWritable is added (and no gap is reported, since legalize does not close it).
    const raw_violations: []Violation = try check(gpa, escaping);
    defer gpa.free(raw_violations);
    try expectEqual(@as(usize, 0), countViolations(raw_violations, .vertex_storage_without_non_writable));
    const legal: []u32 = try legalize(gpa, escaping);
    defer gpa.free(legal);
    try expectEqual(escaping.len, legal.len);
    const reflection: Reflection = try reflect(gpa, legal, "main");
    defer reflection.deinit(gpa);
    for (reflection.globals) |global| {
        if (global.id == 20) {
            try expect(!global.non_writable);
        }
    }
}

test "spv_vulkan: the Zig source language is declared Unknown, in place" {
    const gpa: Allocator = testing_allocator;
    // The compiler's own module declares OpSource Zig: check names the gap, legalize closes it.
    const raw_violations: []Violation = try check(gpa, &depth_fs_words);
    defer gpa.free(raw_violations);
    try expectEqual(@as(usize, 1), countViolations(raw_violations, .zig_source_language));
    const legal: []u32 = try legalize(gpa, &depth_fs_words);
    defer gpa.free(legal);
    const legal_violations: []Violation = try check(gpa, legal);
    defer gpa.free(legal_violations);
    try expectEqual(@as(usize, 0), countViolations(legal_violations, .zig_source_language));
    // The rewrite changes one operand and nothing else: the OpSource instruction keeps its length and version.
    var reader: InstructionReader = try .init(legal);
    while (try reader.next()) |instruction| {
        if (instruction.op == .Source) {
            try expectEqual(source_language_unknown, instruction.operands[0]);
            try expectEqual(@as(usize, 3), instruction.word_count);
        }
    }
}

/// A vertex shader's storage buffer `%20`, a Block struct `%43` holding a runtime array `%40` - and a second struct
/// `%41` holding the same array, without Block, with a pointer type `%42` to it and nothing using either.
fn assembleRuntimeArrayOutsideBlock(gpa: Allocator) Error![]u32 {
    var assembler: Assembler = try .init(gpa, 50);
    errdefer assembler.deinit(gpa);
    try assembler.add(gpa, .Capability, &.{@backingInt(Capability.Shader)});
    try assembler.add(gpa, .MemoryModel, &.{ 0, 1 });
    try assembler.addWithString(gpa, .EntryPoint, &.{ @backingInt(ExecutionModel.Vertex), 1 }, "main", &.{20});
    try assembler.add(gpa, .Decorate, &.{ 20, @backingInt(Decoration.DescriptorSet), 0 });
    try assembler.add(gpa, .Decorate, &.{ 20, @backingInt(Decoration.Binding), 0 });
    try assembler.add(gpa, .Decorate, &.{ 43, @backingInt(Decoration.Block) });
    try assembler.add(gpa, .MemberDecorate, &.{ 43, 0, @backingInt(Decoration.Offset), 0 });
    try assembler.add(gpa, .MemberDecorate, &.{ 41, 0, @backingInt(Decoration.Offset), 0 });
    try assembler.add(gpa, .TypeFloat, &.{ 10, 32 });
    try assembler.add(gpa, .TypeRuntimeArray, &.{ 40, 10 });
    try assembler.add(gpa, .TypeStruct, &.{ 41, 40 });
    try assembler.add(gpa, .TypePointer, &.{ 42, @backingInt(StorageClass.StorageBuffer), 41 });
    try assembler.add(gpa, .TypeStruct, &.{ 43, 40 });
    try assembler.add(gpa, .TypePointer, &.{ 44, @backingInt(StorageClass.StorageBuffer), 43 });
    try assembler.add(gpa, .Variable, &.{ 44, 20, @backingInt(StorageClass.StorageBuffer) });
    return assembler.words.toOwnedSlice(gpa);
}

test "spv_vulkan: a struct holding a runtime array without Block is reported and refused, used or not" {
    const gpa: Allocator = testing_allocator;
    const module_words: []u32 = try assembleRuntimeArrayOutsideBlock(gpa);
    defer gpa.free(module_words);
    const violations: []Violation = try check(gpa, module_words);
    defer gpa.free(violations);
    try expectEqual(@as(usize, 1), countViolations(violations, .runtime_array_outside_block));
    try expectError(Error.RuntimeArrayOutsideBlock, legalize(gpa, module_words));
}
