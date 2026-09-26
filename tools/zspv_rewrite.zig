//! tools/zspv_rewrite.zig - Phase 2 of the SPIR-V binary tooling.
//!
//! Replaces the comptime `shader_post.rewriteSamplers` GLSL surgery
//! with semantic SPIR-V transformations.  Input: a Module from
//! `zspv.read` that has placeholder samplers declared as
//! `extern const X_sampler2d: u32 addrspace(.constant)` and uses
//! the `noinline zsample2d(handle, uv) Vec4` helper from
//! `shadermath.zig`.  Output: a Module with real `OpTypeSampledImage`
//! samplers and `OpImageSampleImplicitLod` operations, ready for
//! full `spirv-opt -O` optimization.
//!
//! See `src/notes/claude.md` for plan pointers.
//!
//! ---- Pipeline overview ----
//!
//! Before this rewriter runs (raw output from `zig build-obj`):
//!   - `OpName %varid "texture0_sampler2d"`
//!   - `OpVariable %ptr_uniform_uint %varid UniformConstant`
//!   - `%h = OpLoad %uint %varid`
//!   - `%uv = ...`  (loaded from a vec2 input or computed)
//!   - `%result = OpFunctionCall %v4f %zsample2d_func %h %uv`
//!   - `%zsample2d_func = OpFunction %v4f None ...`
//!     ... body of zsample2d ...
//!     `OpFunctionEnd`
//!
//! After this rewriter runs:
//!   - `OpName %varid "texture0"`  (suffix stripped)
//!   - `OpVariable %ptr_uniform_sampled_image %varid UniformConstant`
//!   - `%h = OpLoad %sampled_image %varid`  (type changed)
//!   - `%result = OpImageSampleImplicitLod %v4f %h %uv`  (call replaced)
//!   - (zsample2d function definition removed entirely)
//!
//! New module-scope instructions inserted:
//!   - `%float_t = OpTypeFloat 32`  (reused if already present)
//!   - `%image_2d_t = OpTypeImage %float_t 2D 0 0 0 1 Unknown`
//!   - `%sampled_image_t = OpTypeSampledImage %image_2d_t`
//!   - `%ptr_uc_sampled_image_t = OpTypePointer UniformConstant %sampled_image_t`
//!
//! All inserted before the first OpFunction (so they're in the
//! module-scope section per SPIR-V spec ordering).
//!
//! ---- Why semantic SPIR-V instead of textual GLSL ----
//!
//! The previous approach (`shader_post.rewriteSamplers`) operated on
//! spirv-cross's GLSL output by pattern-matching.  That worked but:
//!   - Required preserving the `zsample2d` helper as an anchor,
//!     blocking spirv-opt's inlining pass and a 35% size reduction
//!   - Was fragile to spirv-cross output format changes
//!   - Had to textually strip the Int8 extension that Zig's bool-as-u8
//!     dragged in via conditionals
//!
//! Operating on SPIR-V binary directly fixes all three: full -O can
//! run because samplers are real samplers post-rewrite (nothing to
//! preserve), SPIR-V binary format is stable, and -O's
//! `--trim-capabilities` pass can strip Int8 when there's no longer
//! conditional code depending on it.

const std = @import("std");
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const endsWith = std.mem.endsWith;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Allocator = std.mem.Allocator;
const zspv = @import("zspv.zig");

// ---- SPIR-V opcode constants ----------------------------------------
// Only the ones this rewriter actually inspects or emits.  Numerical
// codes are from the SPIR-V spec (Universal Binary Format, section 3.42).

pub const Op = struct {
    pub const op_name: u16 = 5;
    pub const op_entry_point: u16 = 15;
    pub const op_type_void: u16 = 19;
    pub const op_type_float: u16 = 22;
    pub const op_type_vector: u16 = 23;
    pub const op_type_image: u16 = 25;
    pub const op_type_sampler: u16 = 26;
    pub const op_type_sampled_image: u16 = 27;
    pub const op_type_pointer: u16 = 32;
    pub const op_type_function: u16 = 33;
    pub const op_function: u16 = 54;
    pub const op_function_end: u16 = 56;
    pub const op_function_call: u16 = 57;
    pub const op_variable: u16 = 59;
    pub const op_load: u16 = 61;
    pub const op_sampled_image: u16 = 86;
    pub const op_image_sample_implicit_lod: u16 = 87;
    pub const op_image_sample_explicit_lod: u16 = 88;
    pub const op_decorate: u16 = 71;
};

/// SPIR-V decoration kinds (section 3.20).  Only the ones we read or emit.
pub const Decoration = struct {
    pub const binding: u32 = 33;
    pub const descriptor_set: u32 = 34;
};

/// SPIR-V storage class constants (section 3.7).
pub const StorageClass = struct {
    pub const uniform_constant: u32 = 0;
};

/// SPIR-V "dim" constants for OpTypeImage (section 3.8).
pub const Dim = struct {
    pub const dim_2d: u32 = 1;
};

/// SPIR-V image-format constants (section 3.11).  `Unknown` means the
/// shader doesn't know the storage format ahead of time, which is
/// fine for sampled images we read via texture() - the actual
/// format is set on the GL side via the texture object.
pub const ImageFormat = struct {
    pub const unknown: u32 = 0;
};

// ---- Discovery ------------------------------------------------------

/// A sampler we found and need to rewrite.
pub const SamplerEntry = struct {
    /// The ID of the OpVariable that's the placeholder uint uniform.
    var_id: u32,
    /// The variable's spirv-source name (e.g. "texture0_sampler2d").
    name_full: []const u8,
    /// Name with the `_sampler2d` suffix stripped (e.g. "texture0").
    /// Used to update OpName so the final GLSL has clean uniform names.
    name_stripped: []const u8,
    /// Index in `mod.instructions` where the OpName for this sampler
    /// lives.  Used so we can rewrite the name in-place.
    name_instr_idx: usize,
    /// Index of the OpVariable instruction.  We'll rewrite its type
    /// operand in-place.
    var_instr_idx: usize,
    /// Existing OpDecorate DescriptorSet value for this sampler, if
    /// the SPIR-V binary already carries one.  Today the Zig SPIR-V
    /// backend emits these when codegen calls `zm.binding(...)` on
    /// the sampler - see `tools/gen_shader_externs.zig`.  When
    /// present, `rewriteSamplersWgsl` honors it instead of assigning
    /// from `sampler_group`.  When null, the rewriter falls back to
    /// the `sampler_group` parameter for backwards compat.
    existing_set: ?u32 = null,
    /// Existing OpDecorate Binding value, if any.  When present,
    /// becomes the texture's binding; the paired synthesized
    /// sampler gets `existing_binding + samplers.len` (same offset
    /// scheme as the counter-based path).
    existing_binding: ?u32 = null,
};

/// Discovery report - what the analyzer found in a module.  If
/// `samplers.len == 0` and `zsample2d_func_id == 0`, this module
/// has no S1.4.5b convention usage and the rewriter can short-circuit.
pub const Discovery = struct {
    samplers: []SamplerEntry,
    /// ID of the zsample2d function (the noinline helper from
    /// shadermath).  0 if not found.
    zsample2d_func_id: u32,
    /// Index of the OpFunction that defines zsample2d, so we know
    /// where to start skipping during the rewrite.
    zsample2d_func_instr_idx: usize,
    /// Index just past the OpFunctionEnd of zsample2d.
    zsample2d_end_instr_idx: usize,
    /// Same trio for the EXPLICIT-LOD helper `zsample2d_level`. 0 if absent.
    zsample2d_level_func_id: u32,
    zsample2d_level_func_instr_idx: usize,
    zsample2d_level_end_instr_idx: usize,
};

/// SPIR-V string operands are packed: each u32 word holds 4 bytes
/// (little-endian within the word), the string is null-terminated,
/// and the final word is zero-padded.  Unpack and return as []const u8
/// (without the trailing nul).  Allocates from `alloc`.
fn unpackString(
    alloc: Allocator,
    words: []const u32,
) ![]const u8 {
    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (words) |w| {
        const b0: u8 = @intCast(w & 0xFF);
        const b1: u8 = @intCast((w >> 8) & 0xFF);
        const b2: u8 = @intCast((w >> 16) & 0xFF);
        const b3: u8 = @intCast((w >> 24) & 0xFF);
        if (b0 == 0) {
            break;
        }
        try buf.append(alloc, b0);
        if (b1 == 0) {
            break;
        }
        try buf.append(alloc, b1);
        if (b2 == 0) {
            break;
        }
        try buf.append(alloc, b2);
        if (b3 == 0) {
            break;
        }
        try buf.append(alloc, b3);
    }
    return try buf.toOwnedSlice(alloc);
}

/// Walk the module's instruction list and identify everything the
/// rewrite needs to touch: placeholder sampler variables (named with
/// the `_sampler2d` suffix per S1.4.5b convention) and the zsample2d
/// helper function.
pub fn discover(alloc: Allocator, mod: zspv.Module) !Discovery {
    // First pass: build name -> id map and find zsample2d's function ID.
    // OpName's operand layout is [target_id, name_word1, name_word2, ...].
    // We're looking for two name shapes:
    //   - Variable names ending in "_sampler2d"
    //   - The function name ending in "zsample2d" (spirv-cross prepends
    //     the source-file stem, so the full name is e.g.
    //     "shadermath.zsample2d" - we match on the suffix).

    var samplers: ArrayList(SamplerEntry) = .empty;
    defer samplers.deinit(alloc);

    // Provisional: map var_id -> its declaration index, so when we
    // find the OpVariable later (or earlier) in the stream we can
    // confirm the type and capture the variable's instruction index.
    var var_idx_by_id: std.AutoHashMap(u32, usize) = .init(alloc);
    defer var_idx_by_id.deinit();

    // Names we want to keep for the variables we identify.  Keyed
    // by var_id; populated during the OpName pass; consumed during
    // the OpVariable pass.
    const NameRecord = struct {
        full: []const u8,
        stripped: []const u8,
        name_instr_idx: usize,
    };
    var sampler_names_by_id: std.AutoHashMap(u32, NameRecord) = .init(alloc);
    defer sampler_names_by_id.deinit();

    var zsample2d_func_id: u32 = 0;
    var zsample2d_level_func_id: u32 = 0;

    // Pass 1: scan all OpName instructions, classify by name suffix.
    for (mod.instructions, 0..) |instr, idx| {
        if (instr.opcode != Op.op_name) {
            continue;
        }
        if (instr.operands.len < 2) {
            continue;
        }
        const target_id: u32 = instr.operands[0];
        const name: []const u8 = try unpackString(alloc, instr.operands[1..]);

        if (endsWith(u8, name, "_sampler2d")) {
            const stripped: []const u8 = name[0 .. name.len - "_sampler2d".len];
            try sampler_names_by_id.put(target_id, .{
                .full = name,
                .stripped = stripped,
                .name_instr_idx = idx,
            });
        } else if (endsWith(u8, name, "zsample2d_level")) {
            zsample2d_level_func_id = target_id;
        } else if (endsWith(u8, name, "zsample2d")) {
            zsample2d_func_id = target_id;
            // Don't free `name` - we don't keep it, but the arena will.
        } else {
            // Free names we won't keep (only matters if alloc isn't
            // an arena; for the arena case this is a no-op).
            alloc.free(name);
        }
    }

    // Pass 2: scan OpVariable instructions, pair them with names.
    // SPIR-V layout: OpVariable result_type result_id storage_class.
    for (mod.instructions, 0..) |instr, idx| {
        if (instr.opcode != Op.op_variable) {
            continue;
        }
        if (instr.operands.len < 3) {
            continue;
        }
        const var_id: u32 = instr.operands[1];
        try var_idx_by_id.put(var_id, idx);

        if (sampler_names_by_id.get(var_id)) |name_rec| {
            try samplers.append(alloc, .{
                .var_id = var_id,
                .name_full = name_rec.full,
                .name_stripped = name_rec.stripped,
                .name_instr_idx = name_rec.name_instr_idx,
                .var_instr_idx = idx,
            });
        }
    }

    // Pass 2b: capture existing DescriptorSet + Binding decorations
    // for the samplers we just identified.  When codegen emits
    // `zm_binding(&texture0_sampler2d, 1, 0)` the resulting SPIR-V
    // has matching OpDecorate calls already - we want the rewriter
    // to HONOR them, not strip and replace.  This pass populates
    // `existing_set` / `existing_binding` on each SamplerEntry; the
    // rewrite phase prefers them when present, falls back to its
    // counter assignment otherwise.
    //
    // OpDecorate opcode = 71.  Operand layout: [target_id, decoration,
    // arg0, ...].  DescriptorSet decoration value = 34, Binding = 33.
    for (mod.instructions) |instr| {
        if (instr.opcode != Op.op_decorate) {
            continue;
        }
        if (instr.operands.len < 3) {
            continue;
        }
        const target_id: u32 = instr.operands[0];
        const decoration: u32 = instr.operands[1];
        const value: u32 = instr.operands[2];

        // Linear search - sampler count per shader is small (1-4),
        // not worth a hash map.
        for (samplers.items) |*s| {
            if (s.var_id != target_id) {
                continue;
            }
            switch (decoration) {
                Decoration.descriptor_set => s.existing_set = value,
                Decoration.binding => s.existing_binding = value,
                else => {},
            }
        }
    }

    // Pass 3: find the start + end of zsample2d's function definition.
    // OpFunction's result_id (operand[1]) matches our zsample2d_func_id.
    // OpFunctionEnd is at the next OpFunctionEnd after that point.
    var func_start: usize = 0;
    var func_end: usize = 0;
    if (zsample2d_func_id != 0) {
        var i: usize = 0;
        while (i < mod.instructions.len) : (i += 1) {
            const instr: zspv.Instruction = mod.instructions[i];
            if (instr.opcode == Op.op_function and
                instr.operands.len >= 2 and
                instr.operands[1] == zsample2d_func_id)
            {
                func_start = i;
                // Walk forward to the matching OpFunctionEnd
                var j: usize = i + 1;
                while (j < mod.instructions.len) : (j += 1) {
                    if (mod.instructions[j].opcode == Op.op_function_end) {
                        func_end = j;
                        break;
                    }
                }
                break;
            }
        }
    }

    // Same span-find for the explicit-LOD helper.
    var level_start: usize = 0;
    var level_end: usize = 0;
    if (zsample2d_level_func_id != 0) {
        var i: usize = 0;
        while (i < mod.instructions.len) : (i += 1) {
            const instr: zspv.Instruction = mod.instructions[i];
            if (instr.opcode == Op.op_function and instr.operands.len >= 2 and
                instr.operands[1] == zsample2d_level_func_id)
            {
                level_start = i;
                var j: usize = i + 1;
                while (j < mod.instructions.len) : (j += 1) {
                    if (mod.instructions[j].opcode == Op.op_function_end) {
                        level_end = j;
                        break;
                    }
                }
                break;
            }
        }
    }

    return Discovery{
        .samplers = try samplers.toOwnedSlice(alloc),
        .zsample2d_func_id = zsample2d_func_id,
        .zsample2d_func_instr_idx = func_start,
        .zsample2d_end_instr_idx = func_end,
        .zsample2d_level_func_id = zsample2d_level_func_id,
        .zsample2d_level_func_instr_idx = level_start,
        .zsample2d_level_end_instr_idx = level_end,
    };
}

// ---- Type synthesis -------------------------------------------------

/// IDs of the synthesized sampler-related types.  Allocated by
/// `synthesizeTypes` from the next-available ID space (bumping the
/// module's bound).  All four are needed to declare a sampler2D
/// variable + load + sample.
pub const SamplerTypes = struct {
    /// %float = OpTypeFloat 32.  Either reused from the existing
    /// module if already declared, or freshly allocated.
    float_id: u32,
    /// %image_2d = OpTypeImage %float 2D 0 0 0 1 Unknown
    image_2d_id: u32,
    /// %sampled_image = OpTypeSampledImage %image_2d
    sampled_image_id: u32,
    /// %ptr_uc_sampled_image = OpTypePointer UniformConstant %sampled_image
    ptr_sampled_image_id: u32,
    /// Instructions to insert into the module (in order).  Only the
    /// ones not already present - if %float existed, we reuse its
    /// ID and don't emit a new OpTypeFloat.  All four other
    /// instructions are always new (they're sampler-specific).
    new_instructions: []zspv.Instruction,
};

/// Walk the module and find an existing OpTypeFloat 32 along with
/// its index in the instruction list.  Returns `(id, instr_idx)`,
/// or `(0, 0)` if not found.
/// A reference to an existing `OpTypeFloat 32` instruction in a module:
/// its result id and its position in the instruction list.  Named (not
/// an anonymous tuple) per the anon-return rule.
const Float32Ref = struct { id: u32, idx: usize };

fn findExistingFloat32(mod: zspv.Module) Float32Ref {
    for (mod.instructions, 0..) |instr, idx| {
        if (instr.opcode != Op.op_type_float) {
            continue;
        }
        if (instr.operands.len < 2) {
            continue;
        }
        if (instr.operands[1] == 32) {
            return .{ .id = instr.operands[0], .idx = idx };
        }
    }
    return .{ .id = 0, .idx = 0 };
}

/// Allocate the sampler type IDs from the module's ID space and
/// build the new instructions to declare them.  Bumps `next_id`
/// for each new ID needed (caller writes the final value back
/// to `mod.header[2]` after all transformations).
///
/// `first_sampler_idx` is the earliest sampler OpVariable index;
/// it's used to decide whether we can reuse an existing OpTypeFloat
/// (only safe if the existing float's declaration precedes that
/// index, so when our new types are inserted just before the first
/// sampler, the float they reference is already in scope).
pub fn synthesizeTypes(
    alloc: Allocator,
    mod: zspv.Module,
    next_id: *u32,
    first_sampler_idx: usize,
) !SamplerTypes {
    var new_instrs: ArrayList(zspv.Instruction) = .empty;
    defer new_instrs.deinit(alloc);

    // Try to reuse an existing OpTypeFloat 32 - only if its
    // declaration precedes our insertion point (just before the
    // first sampler OpVariable).  If the existing float comes later,
    // we'd violate the forward-reference rule; allocate a fresh
    // one instead and let `spirv-opt --remove-duplicates` (or the
    // build pipeline's post-opt validation skip) sort it out.
    const existing: Float32Ref = findExistingFloat32(mod);
    var float_id: u32 = 0;
    if (existing.id != 0 and existing.idx < first_sampler_idx) {
        float_id = existing.id;
    } else {
        float_id = next_id.*;
        next_id.* += 1;
        const operands: []u32 = try alloc.alloc(u32, 2);
        operands[0] = float_id;
        operands[1] = 32;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_float,
            .operands = operands,
        });
    }

    // OpTypeImage result_id sampled_type dim depth arrayed ms sampled image_format
    // For texture2D: sampled_type=float, dim=2D, depth=0 (not depth),
    // arrayed=0, ms=0 (not multisampled), sampled=1 (sampled image,
    // not storage image), image_format=Unknown.
    const image_2d_id: u32 = next_id.*;
    next_id.* += 1;
    {
        const operands: []u32 = try alloc.alloc(u32, 8);
        operands[0] = image_2d_id;
        operands[1] = float_id;
        operands[2] = Dim.dim_2d;
        operands[3] = 0; // depth
        operands[4] = 0; // arrayed
        operands[5] = 0; // ms
        operands[6] = 1; // sampled
        operands[7] = ImageFormat.unknown;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_image,
            .operands = operands,
        });
    }

    // OpTypeSampledImage result_id image_type
    const sampled_image_id: u32 = next_id.*;
    next_id.* += 1;
    {
        const operands: []u32 = try alloc.alloc(u32, 2);
        operands[0] = sampled_image_id;
        operands[1] = image_2d_id;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_sampled_image,
            .operands = operands,
        });
    }

    // OpTypePointer result_id storage_class type
    const ptr_sampled_image_id: u32 = next_id.*;
    next_id.* += 1;
    {
        const operands: []u32 = try alloc.alloc(u32, 3);
        operands[0] = ptr_sampled_image_id;
        operands[1] = StorageClass.uniform_constant;
        operands[2] = sampled_image_id;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_pointer,
            .operands = operands,
        });
    }

    return SamplerTypes{
        .float_id = float_id,
        .image_2d_id = image_2d_id,
        .sampled_image_id = sampled_image_id,
        .ptr_sampled_image_id = ptr_sampled_image_id,
        .new_instructions = try new_instrs.toOwnedSlice(alloc),
    };
}

// ---- Full rewrite ---------------------------------------------------

/// Rewrite a module in-place to convert placeholder samplers + the
/// `zsample2d` helper into real `OpTypeSampledImage` variables and
/// `OpImageSampleImplicitLod` operations.  Mutates `mod`.  If the
/// module has no S1.4.5b-shape samplers, this is a no-op.
///
/// `alloc` is used for all new instruction/operand allocations.
/// The original instructions' operand slices are NOT freed (caller
/// is responsible - typically with an arena that gets reset).
pub fn rewriteSamplers(alloc: Allocator, mod: *zspv.Module) !void {
    const disc: Discovery = try discover(alloc, mod.*);
    if (disc.samplers.len == 0 and disc.zsample2d_func_id == 0 and disc.zsample2d_level_func_id == 0) {
        return; // nothing to do
    }

    // Synthesize sampler types, allocating new IDs from the bound.
    // First find the earliest sampler OpVariable so synthesizeTypes
    // knows whether it can safely reuse an existing OpTypeFloat
    // (only safe if the float's declaration precedes our insertion
    // point - see synthesizeTypes' doc).
    var first_sampler_idx: usize = mod.instructions.len;
    for (disc.samplers) |s| {
        if (s.var_instr_idx < first_sampler_idx) {
            first_sampler_idx = s.var_instr_idx;
        }
    }

    var next_id: u32 = mod.header[2];
    const types: SamplerTypes = try synthesizeTypes(alloc, mod.*, &next_id, first_sampler_idx);

    // Build a lookup: for each sampler OpVariable's old type (a
    // ptr-to-uint), we know we want to replace it with our new
    // ptr-to-sampled_image type.  Same target type for every sampler,
    // so this is just a constant.
    const new_var_type: u32 = types.ptr_sampled_image_id;

    // Build a set of sampler variable IDs for fast lookup during
    // the load-rewrite pass.
    var sampler_var_id_set: std.AutoHashMap(u32, void) = .init(alloc);
    defer sampler_var_id_set.deinit();
    for (disc.samplers) |s| {
        try sampler_var_id_set.put(s.var_id, {});
    }

    // Build the new instruction list.  Strategy: walk the original
    // list, emit modified or replacement instructions, and inject
    // the new type declarations at the right point (just before the
    // first OpFunction).
    var new_instrs: ArrayList(zspv.Instruction) = .empty;
    defer new_instrs.deinit(alloc);

    // Pre-build a list of "indexes to skip OpName/OpDecorate at"
    // for IDs we're removing.  Currently just zsample2d_func_id;
    // could expand if we ever remove other named entities.

    var types_inserted: bool = false;
    var i: usize = 0;
    while (i < mod.instructions.len) : (i += 1) {
        const instr: zspv.Instruction = mod.instructions[i];

        // Skip the entire zsample2d function body: from its
        // OpFunction through OpFunctionEnd, inclusive.
        if (disc.zsample2d_func_id != 0 and
            i >= disc.zsample2d_func_instr_idx and
            i <= disc.zsample2d_end_instr_idx)
        {
            continue;
        }
        if (disc.zsample2d_level_func_id != 0 and
            i >= disc.zsample2d_level_func_instr_idx and
            i <= disc.zsample2d_level_end_instr_idx)
        {
            continue;
        }

        // Skip debug + annotation instructions that reference the
        // removed zsample2d function ID.  If we leave them, spirv-val
        // complains: "forward referenced IDs have not been defined".
        // The function is gone, so any OpName/OpDecorate naming or
        // decorating it must go too.  Same idea would apply to
        // OpMemberName/OpMemberDecorate, but those target struct
        // member IDs not function IDs.
        if (disc.zsample2d_func_id != 0 and
            instr.opcode == Op.op_name and
            instr.operands.len >= 1 and
            instr.operands[0] == disc.zsample2d_func_id)
        {
            continue;
        }
        if (disc.zsample2d_level_func_id != 0 and
            instr.opcode == Op.op_name and
            instr.operands.len >= 1 and
            instr.operands[0] == disc.zsample2d_level_func_id)
        {
            continue;
        }
        const op_decorate: u16 = 71;
        if (disc.zsample2d_func_id != 0 and
            instr.opcode == op_decorate and
            instr.operands.len >= 1 and
            instr.operands[0] == disc.zsample2d_func_id)
        {
            continue;
        }
        if (disc.zsample2d_level_func_id != 0 and
            instr.opcode == op_decorate and
            instr.operands.len >= 1 and
            instr.operands[0] == disc.zsample2d_level_func_id)
        {
            continue;
        }

        // Inject new types just before the earliest sampler OpVariable.
        // This puts the new type chain in section 6 (the mixed
        // type/constant/global-variable section), at a point where
        // every existing instruction we depend on has been declared
        // (none - we always allocate fresh) and every sampler
        // OpVariable we'll rewrite hasn't been emitted yet.
        if (!types_inserted and i == first_sampler_idx) {
            try new_instrs.appendSlice(alloc, types.new_instructions);
            types_inserted = true;
        }

        // OpVariable for one of our placeholder samplers: change
        // its result_type operand from ptr-to-uint to ptr-to-sampled_image.
        // Operands: [result_type, result_id, storage_class].
        if (instr.opcode == Op.op_variable and
            instr.operands.len >= 3 and
            sampler_var_id_set.contains(instr.operands[1]))
        {
            const new_operands: []u32 = try alloc.alloc(u32, instr.operands.len);
            new_operands[0] = new_var_type;
            new_operands[1] = instr.operands[1];
            new_operands[2] = instr.operands[2];
            // Storage class stays UniformConstant; any extra operands
            // (rare - initializer) we copy through.
            var k: usize = 3;
            while (k < instr.operands.len) : (k += 1) {
                new_operands[k] = instr.operands[k];
            }
            try new_instrs.append(alloc, .{
                .opcode = Op.op_variable,
                .operands = new_operands,
            });
            continue;
        }

        // OpLoad reading from one of our sampler variables: change
        // result_type from uint to sampled_image.
        // Operands: [result_type, result_id, pointer, optional memory_operands].
        if (instr.opcode == Op.op_load and
            instr.operands.len >= 3 and
            sampler_var_id_set.contains(instr.operands[2]))
        {
            const new_operands: []u32 = try alloc.alloc(u32, instr.operands.len);
            new_operands[0] = types.sampled_image_id;
            var k: usize = 1;
            while (k < instr.operands.len) : (k += 1) {
                new_operands[k] = instr.operands[k];
            }
            try new_instrs.append(alloc, .{
                .opcode = Op.op_load,
                .operands = new_operands,
            });
            continue;
        }

        // OpFunctionCall to zsample2d: rewrite to OpImageSampleImplicitLod.
        // Original operands: [result_type, result_id, func_id, handle, uv]
        // New operands:      [result_type, result_id, handle, uv]
        // The handle (originally a uint loaded from the placeholder)
        // is now a SampledImage (because we rewrote the OpLoad above
        // to load SampledImage instead of uint).
        if (instr.opcode == Op.op_function_call and
            instr.operands.len >= 5 and
            disc.zsample2d_func_id != 0 and
            instr.operands[2] == disc.zsample2d_func_id)
        {
            const new_operands: []u32 = try alloc.alloc(u32, 4);
            new_operands[0] = instr.operands[0]; // result_type (vec4)
            new_operands[1] = instr.operands[1]; // result_id
            new_operands[2] = instr.operands[3]; // sampled_image (was "handle")
            new_operands[3] = instr.operands[4]; // uv (unchanged)
            try new_instrs.append(alloc, .{
                .opcode = Op.op_image_sample_implicit_lod,
                .operands = new_operands,
            });
            continue;
        }

        // OpFunctionCall to zsample2d_level: rewrite to OpImageSampleExplicitLod.
        // Original operands: [result_type, result_id, func_id, handle, uv, lod]
        // New operands: [result_type, result_id, sampled_image, uv, Lod-mask, lod].
        // The `handle` was already turned into a SampledImage by the shared
        // OpLoad rewrite (same placeholder sampler var). The Lod image operand
        // (mask 0x2) picks explicit LOD, which needs no derivatives and is thus
        // legal in a vertex shader.
        if (instr.opcode == Op.op_function_call and
            instr.operands.len >= 6 and
            disc.zsample2d_level_func_id != 0 and
            instr.operands[2] == disc.zsample2d_level_func_id)
        {
            const new_operands: []u32 = try alloc.alloc(u32, 6);
            new_operands[0] = instr.operands[0]; // result_type (vec4)
            new_operands[1] = instr.operands[1]; // result_id
            new_operands[2] = instr.operands[3]; // sampled_image (was "handle")
            new_operands[3] = instr.operands[4]; // uv (unchanged)
            new_operands[4] = 0x2; // ImageOperands mask: Lod
            new_operands[5] = instr.operands[5]; // lod value id
            try new_instrs.append(alloc, .{
                .opcode = Op.op_image_sample_explicit_lod,
                .operands = new_operands,
            });
            continue;
        }

        // OpName for a sampler: rewrite to the stripped name.
        // Operands: [target_id, name_word1, name_word2, ...].
        // Repack the stripped name into u32 words.
        if (instr.opcode == Op.op_name and
            instr.operands.len >= 1 and
            sampler_var_id_set.contains(instr.operands[0]))
        {
            // Find the matching sampler entry to get the stripped name.
            var stripped: []const u8 = "";
            for (disc.samplers) |s| {
                if (s.var_id == instr.operands[0]) {
                    stripped = s.name_stripped;
                    break;
                }
            }
            // Pack the stripped name into u32 words (4 chars per word,
            // null-terminated, zero-padded to word boundary).
            const word_count: usize = (stripped.len / 4) + 1;
            const new_operands: []u32 = try alloc.alloc(u32, 1 + word_count);
            new_operands[0] = instr.operands[0]; // target_id
            var w_idx: usize = 0;
            while (w_idx < word_count) : (w_idx += 1) {
                var word: u32 = 0;
                var b_idx: usize = 0;
                while (b_idx < 4) : (b_idx += 1) {
                    const char_idx: usize = w_idx * 4 + b_idx;
                    if (char_idx < stripped.len) {
                        word |= @as(u32, stripped[char_idx]) << @as(u5, @intCast(b_idx * 8));
                    }
                    // Trailing zero bytes give the null-terminator + padding.
                }
                new_operands[1 + w_idx] = word;
            }
            try new_instrs.append(alloc, .{
                .opcode = Op.op_name,
                .operands = new_operands,
            });
            continue;
        }

        // Default: keep the instruction as-is.
        try new_instrs.append(alloc, instr);
    }

    // If we never saw an OpFunction (shouldn't happen for a real
    // shader but defend against it), append types at the end.
    if (!types_inserted) {
        try new_instrs.appendSlice(alloc, types.new_instructions);
    }

    mod.instructions = try new_instrs.toOwnedSlice(alloc);
    mod.header[2] = next_id;
}

// ====================================================================
// WGSL-shape rewrite (the destination shape; GL/spirv-cross path above
// is the deprecated form retained during transition)
// ====================================================================
//
// Once Phase F of the wgpu migration ships (GL deletion), the
// `rewriteSamplers` above goes away and only `rewriteSamplersWgsl`
// remains.  Until then, the GLSL pipeline calls the combined-sampler
// rewrite and the wgpu pipeline calls the split-sampler rewrite, so
// both shipping artifacts come from the same Zig source via different
// post-processing.
//
// Shape difference: where the combined version produces
//
//   %img      = OpTypeImage %f32 2D 0 0 0 1 Unknown
//   %sampImg  = OpTypeSampledImage %img
//   %var      = OpVariable %ptrSampImg %varId UniformConstant
//   %load     = OpLoad %sampImg %var
//   %result   = OpImageSampleImplicitLod %v4f %load %uv
//
// the split (WGSL) version produces
//
//   %img      = OpTypeImage %f32 2D 0 0 0 1 Unknown
//   %samp     = OpTypeSampler                       (* new *)
//   %sampImg  = OpTypeSampledImage %img             (* still needed for combine result *)
//   %imgVar   = OpVariable %ptrImg  %imgVarId  UniformConstant
//   %sampVar  = OpVariable %ptrSamp %sampVarId UniformConstant       (* new *)
//   %imgLoad  = OpLoad %img  %imgVar
//   %sampLoad = OpLoad %samp %sampVar                                (* new *)
//   %combined = OpSampledImage %sampImg %imgLoad %sampLoad           (* new *)
//   %result   = OpImageSampleImplicitLod %v4f %combined %uv
//
// Bindings: the texture keeps the placeholder's original Binding N;
// the synthesized sampler gets Binding N+1 in the same descriptor set.
// (Engine-side bind-group layout must match - see
// `src/renderer_2d.zig` for the convention.)

/// IDs of synthesized sampler-related types for the WGSL path.
/// Same float/image/sampled_image as the GLSL path, plus a separate
/// `sampler_t` and the two distinct pointer types for image-variable
/// and sampler-variable.
pub const SamplerTypesWgsl = struct {
    float_id: u32,
    image_2d_id: u32,
    sampler_id: u32,
    sampled_image_id: u32,
    ptr_image_id: u32,
    ptr_sampler_id: u32,
    new_instructions: []zspv.Instruction,
};

/// Allocate IDs and build module-scope type declarations for the
/// WGSL-shape rewrite.  Parallel to `synthesizeTypes` but emits the
/// extra `OpTypeSampler` + a second `OpTypePointer` for the sampler
/// variable.
pub fn synthesizeTypesWgsl(
    alloc: Allocator,
    mod: zspv.Module,
    next_id: *u32,
    first_sampler_idx: usize,
) !SamplerTypesWgsl {
    var new_instrs: ArrayList(zspv.Instruction) = .empty;
    defer new_instrs.deinit(alloc);

    // Reuse-or-allocate float32 - same logic as the GLSL path.
    const existing: Float32Ref = findExistingFloat32(mod);
    var float_id: u32 = 0;
    if (existing.id != 0 and existing.idx < first_sampler_idx) {
        float_id = existing.id;
    } else {
        float_id = next_id.*;
        next_id.* += 1;
        const operands: []u32 = try alloc.alloc(u32, 2);
        operands[0] = float_id;
        operands[1] = 32;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_float,
            .operands = operands,
        });
    }

    // OpTypeImage - texture half (no sampler attached).
    const image_2d_id: u32 = next_id.*;
    next_id.* += 1;
    {
        const operands: []u32 = try alloc.alloc(u32, 8);
        operands[0] = image_2d_id;
        operands[1] = float_id;
        operands[2] = Dim.dim_2d;
        operands[3] = 0;
        operands[4] = 0;
        operands[5] = 0;
        operands[6] = 1;
        operands[7] = ImageFormat.unknown;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_image,
            .operands = operands,
        });
    }

    // OpTypeSampler - the standalone sampler type.  Single operand:
    // result_id.  WGSL maps this directly to `sampler` (or
    // `sampler_comparison` for the future shadow-map case).
    const sampler_id: u32 = next_id.*;
    next_id.* += 1;
    {
        const operands: []u32 = try alloc.alloc(u32, 1);
        operands[0] = sampler_id;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_sampler,
            .operands = operands,
        });
    }

    // OpTypeSampledImage - still needed as the result type of the
    // OpSampledImage instruction that combines image+sampler at each
    // sample site.  Not used as a variable type in the WGSL path.
    const sampled_image_id: u32 = next_id.*;
    next_id.* += 1;
    {
        const operands: []u32 = try alloc.alloc(u32, 2);
        operands[0] = sampled_image_id;
        operands[1] = image_2d_id;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_sampled_image,
            .operands = operands,
        });
    }

    // OpTypePointer UniformConstant Image
    const ptr_image_id: u32 = next_id.*;
    next_id.* += 1;
    {
        const operands: []u32 = try alloc.alloc(u32, 3);
        operands[0] = ptr_image_id;
        operands[1] = StorageClass.uniform_constant;
        operands[2] = image_2d_id;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_pointer,
            .operands = operands,
        });
    }

    // OpTypePointer UniformConstant Sampler
    const ptr_sampler_id: u32 = next_id.*;
    next_id.* += 1;
    {
        const operands: []u32 = try alloc.alloc(u32, 3);
        operands[0] = ptr_sampler_id;
        operands[1] = StorageClass.uniform_constant;
        operands[2] = sampler_id;
        try new_instrs.append(alloc, .{
            .opcode = Op.op_type_pointer,
            .operands = operands,
        });
    }

    return SamplerTypesWgsl{
        .float_id = float_id,
        .image_2d_id = image_2d_id,
        .sampler_id = sampler_id,
        .sampled_image_id = sampled_image_id,
        .ptr_image_id = ptr_image_id,
        .ptr_sampler_id = ptr_sampler_id,
        .new_instructions = try new_instrs.toOwnedSlice(alloc),
    };
}

/// Pack a Zig string into SPIR-V's wire format (u32 words, little-
/// endian within each, null-terminated, zero-padded to word boundary).
/// Caller owns the returned slice.
fn packString(alloc: Allocator, s: []const u8) ![]u32 {
    const word_count: usize = (s.len / 4) + 1;
    const words: []u32 = try alloc.alloc(u32, word_count);
    var w: usize = 0;
    while (w < word_count) : (w += 1) {
        var word: u32 = 0;
        var b: usize = 0;
        while (b < 4) : (b += 1) {
            const idx: usize = w * 4 + b;
            if (idx < s.len) {
                word |= @as(u32, s[idx]) << @as(u5, @intCast(b * 8));
            }
        }
        words[w] = word;
    }
    return words;
}

/// Per-placeholder bookkeeping built by the WGSL rewriter.  Each
/// placeholder `X_sampler2d` becomes:
///   - texture variable (id = original var_id, type changes to ptr_image)
///   - sampler variable (fresh id, type ptr_sampler)
/// We track both so the load-rewrite + sample-rewrite passes can find
/// the right sibling.
const WgslPair = struct {
    original_var_id: u32,
    new_sampler_var_id: u32,
    /// The DescriptorSet (== WGSL @group) that BOTH the texture and
    /// the synthesized sampler will live in.  Resolved at assignment
    /// time: prefers `SamplerEntry.existing_set` (codegen-emitted via
    /// `zm.binding`) when present; falls back to the caller's
    /// `sampler_group` parameter otherwise.
    resolved_set: u32,
    original_binding: u32,
    new_sampler_binding: u32,
    name_stripped: []const u8,
};

/// Rewrite a module in place, producing the WGSL-shape SPIR-V
/// (separate texture + sampler bindings with `OpSampledImage`
/// combine sites).  See header comment above `SamplerTypesWgsl` for
/// the before/after shape diagram.
///
/// `sampler_group` is the WGSL `@group(N)` (== SPIR-V DescriptorSet)
/// for the synthesized texture+sampler variables.  Default 0 in
/// callers; pass 1 (or higher) when the resulting WGSL is to be
/// linked into a pipeline alongside a VS UBO at group 0 binding 0,
/// since WebGPU rejects a bind-group entry that has different types
/// for different stages at the same (group, binding) - the engine
/// shapes shader is the canonical example.
pub fn rewriteSamplersWgsl(
    alloc: Allocator,
    mod: *zspv.Module,
    sampler_group: u32,
) !void {
    const disc: Discovery = try discover(alloc, mod.*);
    if (disc.samplers.len == 0 and disc.zsample2d_func_id == 0 and disc.zsample2d_level_func_id == 0) {
        return; // nothing to do
    }

    var first_sampler_idx: usize = mod.instructions.len;
    for (disc.samplers) |s| {
        if (s.var_instr_idx < first_sampler_idx) {
            first_sampler_idx = s.var_instr_idx;
        }
    }

    var next_id: u32 = mod.header[2];
    const types: SamplerTypesWgsl = try synthesizeTypesWgsl(alloc, mod.*, &next_id, first_sampler_idx);

    // Allocate the per-placeholder bookkeeping: one fresh sampler-var
    // id per discovered placeholder, plus binding assignment.
    //
    // Zig's SPIR-V backend doesn't emit explicit `OpDecorate Binding`
    // for placeholder samplers - bindings get auto-assigned downstream
    // (by spirv-cross for the GL path, or default to 0 in our spv2wgsl).
    // For the WGSL path we need DISTINCT bindings for each texture and
    // its paired sampler, so we ALWAYS emit explicit Binding decorations
    // for both, finding free slots within the descriptor set.
    //
    // Convention: assign textures bindings 0, 1, 2... and samplers
    // bindings starting at `max_existing_binding + 1`.  This keeps
    // texture bindings stable across shaders with N textures (predictable
    // for the host-side bind-group layout) and puts samplers in a
    // distinct range so the engine can build a bind-group layout from
    // either the iface schema alone or the WGSL alone and agree.
    //
    // For zimr's engine the typical shader has 1-2 textures and 1
    // sampler per texture, so we'll end up with e.g. texture0@binding(0),
    // sampler0@binding(1) - exactly the layout `src/renderer_2d.zig`
    // expects on the host side.
    // The two paths can be mixed within a single shader (some samplers
    // declared, some not), since the per-pair `resolved_set` lives on
    // each WgslPair.  The synthesized sampler half always sits in the
    // same group as its texture, at an offset binding.  That offset is
    // `samplers.len` when ALL pairs go through (b); when path (a) is
    // mixed in, we use a per-group counter to find free slots.
    var pairs: std.AutoHashMap(u32, WgslPair) = .init(alloc);
    defer pairs.deinit();

    var fallback_tex_binding: u32 = 0;
    var fallback_samp_binding: u32 = @intCast(disc.samplers.len);

    for (disc.samplers) |s| {
        const new_sampler_var_id: u32 = next_id;
        next_id += 1;

        const resolved_set: u32 = s.existing_set orelse sampler_group;
        const tex_binding: u32 = blk: {
            if (s.existing_binding) |b| {
                break :blk b;
            }
            const fb: u32 = fallback_tex_binding;
            fallback_tex_binding += 1;
            break :blk fb;
        };
        // Sampler binding.  ROBUSTNESS / single source of truth: when the
        // texture binding came from the schema (codegen emitted `zm.binding`),
        // place the sampler at `texture_binding + 1` - the SAME convention the
        // host uses when it expands a `.sampler_2d` ResolvedField into a
        // texture at @binding(N) + a sampler at @binding(N+1)
        // (`shader_runtime.zig`). Both sides now derive the sampler slot
        // from the one texture binding, so the emitted WGSL and the host
        // bind-group layout can never disagree. (The schema's binding solver
        // already spaces pinned textures 2 apart - e.g. scene@1, bloom@3 - so
        // scene_samp@2 and bloom_samp@4 don't collide.)
        //
        // The fallback branch (no existing binding - the legacy GLSL->SPIR-V
        // path with implicit bindings) keeps the old "after all textures"
        // counter, since there is no host schema to agree with there.
        const samp_binding: u32 = blk: {
            if (s.existing_binding != null) {
                break :blk tex_binding + 1;
            }
            const fb: u32 = fallback_samp_binding;
            fallback_samp_binding += 1;
            break :blk fb;
        };

        try pairs.put(s.var_id, .{
            .original_var_id = s.var_id,
            .new_sampler_var_id = new_sampler_var_id,
            .resolved_set = resolved_set,
            .original_binding = tex_binding,
            .new_sampler_binding = samp_binding,
            .name_stripped = s.name_stripped,
        });
    }

    // Map from "this image-OpLoad result-id" -> "the sampler-OpLoad
    // result-id we synthesized right after it".  Used so each
    // OpFunctionCall zsample2d(h, uv) can find the matching sampler
    // load for its OpSampledImage combine.
    var image_load_to_sampler_load: std.AutoHashMap(u32, u32) = .init(alloc);
    defer image_load_to_sampler_load.deinit();

    var new_instrs: ArrayList(zspv.Instruction) = .empty;
    defer new_instrs.deinit(alloc);

    var types_inserted: bool = false;
    var i: usize = 0;
    while (i < mod.instructions.len) : (i += 1) {
        const instr: zspv.Instruction = mod.instructions[i];

        // Skip zsample2d function body.
        if (disc.zsample2d_func_id != 0 and
            i >= disc.zsample2d_func_instr_idx and
            i <= disc.zsample2d_end_instr_idx)
        {
            continue;
        }
        if (disc.zsample2d_level_func_id != 0 and
            i >= disc.zsample2d_level_func_instr_idx and
            i <= disc.zsample2d_level_end_instr_idx)
        {
            continue;
        }

        // Skip OpName/OpDecorate that target the removed zsample2d
        // function id (same hygiene as the combined-sampler rewrite).
        if (disc.zsample2d_func_id != 0 and
            instr.opcode == Op.op_name and
            instr.operands.len >= 1 and
            instr.operands[0] == disc.zsample2d_func_id)
        {
            continue;
        }
        if (disc.zsample2d_func_id != 0 and
            instr.opcode == Op.op_decorate and
            instr.operands.len >= 1 and
            instr.operands[0] == disc.zsample2d_func_id)
        {
            continue;
        }
        if (disc.zsample2d_level_func_id != 0 and
            instr.opcode == Op.op_name and
            instr.operands.len >= 1 and
            instr.operands[0] == disc.zsample2d_level_func_id)
        {
            continue;
        }
        if (disc.zsample2d_level_func_id != 0 and
            instr.opcode == Op.op_decorate and
            instr.operands.len >= 1 and
            instr.operands[0] == disc.zsample2d_level_func_id)
        {
            continue;
        }

        // Inject the new type declarations + explicit Binding
        // decorations just before the first sampler OpVariable.
        //
        // The decorations conceptually belong in SPIR-V's section 6
        // (annotations) and the types in section 7, but spirv-opt
        // happily reorganizes both - and we'll run spirv-opt with
        // --skip-validation right after this anyway.  Placing them
        // here keeps the rewriter's transformation localized and
        // avoids a second pass over the instruction list.
        if (!types_inserted and i == first_sampler_idx) {
            // Emit explicit OpDecorate Binding AND DescriptorSet for
            // each pair.  The texture's decorations are skipped when
            // the SPIR-V binary already carried them (codegen emitted
            // `zm.binding` for this sampler) - we mustn't emit
            // duplicates.  The synthesized sampler half is ALWAYS new
            // (the rewriter created its variable id this run), so its
            // decorations always come from us.
            var pair_it_for_decs: @TypeOf(pairs).ValueIterator = pairs.valueIterator();
            while (pair_it_for_decs.next()) |pair| {
                // Was the texture's binding+set discovered from
                // existing decorations?  If yes, those OpDecorate
                // ROBUSTNESS: the rewriter is now the SINGLE AUTHORITY on
                // every paired texture/sampler binding. We ALWAYS emit fresh
                // Binding + DescriptorSet decorations for the texture from the
                // computed `pair`, and the copy loop below STRIPS any existing
                // Binding/DescriptorSet the source carried on this var (see the
                // `pairs.get(...)` skip there). Previously we tried to "leave
                // existing texture decorations alone" - but downstream passes
                // (spirv-opt) could drop the original Binding, leaving the
                // texture with only a DescriptorSet and no Binding, so
                // spv2wgsl auto-assigned binding 0 and collided with a UBO at
                // binding 0 (the bloom post-process passes hit exactly this).
                // Emitting unconditionally + stripping the source copy makes
                // the binding come from ONE place and can't be lost.
                const tex_bind: []u32 = try alloc.alloc(u32, 3);
                tex_bind[0] = pair.original_var_id;
                tex_bind[1] = Decoration.binding;
                tex_bind[2] = pair.original_binding;
                try new_instrs.append(alloc, .{
                    .opcode = Op.op_decorate,
                    .operands = tex_bind,
                });
                const tex_set: []u32 = try alloc.alloc(u32, 3);
                tex_set[0] = pair.original_var_id;
                tex_set[1] = Decoration.descriptor_set;
                tex_set[2] = pair.resolved_set;
                try new_instrs.append(alloc, .{
                    .opcode = Op.op_decorate,
                    .operands = tex_set,
                });

                // Synthesized sampler half: always fresh, always emitted.
                const samp_bind: []u32 = try alloc.alloc(u32, 3);
                samp_bind[0] = pair.new_sampler_var_id;
                samp_bind[1] = Decoration.binding;
                samp_bind[2] = pair.new_sampler_binding;
                try new_instrs.append(alloc, .{
                    .opcode = Op.op_decorate,
                    .operands = samp_bind,
                });
                const samp_set: []u32 = try alloc.alloc(u32, 3);
                samp_set[0] = pair.new_sampler_var_id;
                samp_set[1] = Decoration.descriptor_set;
                samp_set[2] = pair.resolved_set;
                try new_instrs.append(alloc, .{
                    .opcode = Op.op_decorate,
                    .operands = samp_set,
                });
            }

            try new_instrs.appendSlice(alloc, types.new_instructions);
            types_inserted = true;
        }

        // OpVariable for a placeholder sampler: rewrite to use
        // ptr_image_t (texture half) AND emit a paired OpVariable for
        // the sampler half right after.
        if (instr.opcode == Op.op_variable and
            instr.operands.len >= 3 and
            pairs.get(instr.operands[1]) != null)
        {
            const pair: WgslPair = pairs.get(instr.operands[1]).?;

            // Texture variable: original id, retyped to ptr_image.
            const tex_operands: []u32 = try alloc.alloc(u32, instr.operands.len);
            tex_operands[0] = types.ptr_image_id;
            tex_operands[1] = instr.operands[1];
            tex_operands[2] = instr.operands[2];
            var k: usize = 3;
            while (k < instr.operands.len) : (k += 1) {
                tex_operands[k] = instr.operands[k];
            }
            try new_instrs.append(alloc, .{
                .opcode = Op.op_variable,
                .operands = tex_operands,
            });

            // Paired sampler variable: fresh id, ptr_sampler.
            const samp_operands: []u32 = try alloc.alloc(u32, 3);
            samp_operands[0] = types.ptr_sampler_id;
            samp_operands[1] = pair.new_sampler_var_id;
            samp_operands[2] = StorageClass.uniform_constant;
            try new_instrs.append(alloc, .{
                .opcode = Op.op_variable,
                .operands = samp_operands,
            });
            continue;
        }

        // OpLoad reading from a placeholder sampler variable: rewrite
        // to load image_t (was uint), AND emit a paired OpLoad of the
        // sampler variable right after.  Record the (image_load_id ->
        // sampler_load_id) pair so the sample-site rewrite can find
        // them.
        if (instr.opcode == Op.op_load and
            instr.operands.len >= 3 and
            pairs.get(instr.operands[2]) != null)
        {
            const pair: WgslPair = pairs.get(instr.operands[2]).?;

            // Image load - original result_id, retyped to image_t.
            const img_load_operands: []u32 = try alloc.alloc(u32, instr.operands.len);
            img_load_operands[0] = types.image_2d_id;
            var k: usize = 1;
            while (k < instr.operands.len) : (k += 1) {
                img_load_operands[k] = instr.operands[k];
            }
            try new_instrs.append(alloc, .{
                .opcode = Op.op_load,
                .operands = img_load_operands,
            });
            const image_load_result_id: u32 = instr.operands[1];

            // Sampler load - fresh id, ptr_sampler -> sampler_t.
            const sampler_load_result_id: u32 = next_id;
            next_id += 1;
            const samp_load_operands: []u32 = try alloc.alloc(u32, 3);
            samp_load_operands[0] = types.sampler_id;
            samp_load_operands[1] = sampler_load_result_id;
            samp_load_operands[2] = pair.new_sampler_var_id;
            try new_instrs.append(alloc, .{
                .opcode = Op.op_load,
                .operands = samp_load_operands,
            });

            try image_load_to_sampler_load.put(image_load_result_id, sampler_load_result_id);
            continue;
        }

        // OpFunctionCall to zsample2d(handle, uv): the "handle" used
        // to be the image-load result_id.  Now we need to:
        //   1. Emit OpSampledImage(image_load, sampler_load) to combine
        //      back into a SampledImage temporary.
        //   2. Emit OpImageSampleImplicitLod(combined, uv).
        // Original ops: [result_type, result_id, func_id, handle, uv]
        if (instr.opcode == Op.op_function_call and
            instr.operands.len >= 5 and
            disc.zsample2d_func_id != 0 and
            instr.operands[2] == disc.zsample2d_func_id)
        {
            const image_load_id: u32 = instr.operands[3];
            const uv_id: u32 = instr.operands[4];
            const sampler_load_id: u32 = image_load_to_sampler_load.get(image_load_id) orelse {
                // Defensive: the image load went through a phi or
                // some other indirection we didn't trace.  Leave the
                // call alone (will produce a warning downstream); a
                // future revision can chase the indirection.
                try new_instrs.append(alloc, instr);
                continue;
            };

            // OpSampledImage temporary.
            const combined_id: u32 = next_id;
            next_id += 1;
            const sampled_operands: []u32 = try alloc.alloc(u32, 4);
            sampled_operands[0] = types.sampled_image_id;
            sampled_operands[1] = combined_id;
            sampled_operands[2] = image_load_id;
            sampled_operands[3] = sampler_load_id;
            try new_instrs.append(alloc, .{
                .opcode = Op.op_sampled_image,
                .operands = sampled_operands,
            });

            // OpImageSampleImplicitLod on the combined image.
            const sample_operands: []u32 = try alloc.alloc(u32, 4);
            sample_operands[0] = instr.operands[0]; // result_type (v4f)
            sample_operands[1] = instr.operands[1]; // result_id (caller's expected)
            sample_operands[2] = combined_id;
            sample_operands[3] = uv_id;
            try new_instrs.append(alloc, .{
                .opcode = Op.op_image_sample_implicit_lod,
                .operands = sample_operands,
            });
            continue;
        }

        // OpFunctionCall to zsample2d_level: same texture+sampler pairing and
        // OpSampledImage combine, but emit OpImageSampleExplicitLod with the Lod
        // operand (mask 0x2) - derivative-free, so legal in a vertex shader.
        // Original ops: [result_type, result_id, func_id, handle, uv, lod]
        if (instr.opcode == Op.op_function_call and
            instr.operands.len >= 6 and
            disc.zsample2d_level_func_id != 0 and
            instr.operands[2] == disc.zsample2d_level_func_id)
        {
            const image_load_id: u32 = instr.operands[3];
            const uv_id: u32 = instr.operands[4];
            const lod_id: u32 = instr.operands[5];
            const sampler_load_id: u32 = image_load_to_sampler_load.get(image_load_id) orelse {
                try new_instrs.append(alloc, instr);
                continue;
            };
            const combined_id: u32 = next_id;
            next_id += 1;
            const sampled_operands: []u32 = try alloc.alloc(u32, 4);
            sampled_operands[0] = types.sampled_image_id;
            sampled_operands[1] = combined_id;
            sampled_operands[2] = image_load_id;
            sampled_operands[3] = sampler_load_id;
            try new_instrs.append(alloc, .{
                .opcode = Op.op_sampled_image,
                .operands = sampled_operands,
            });
            const sample_operands: []u32 = try alloc.alloc(u32, 6);
            sample_operands[0] = instr.operands[0]; // result_type (v4f)
            sample_operands[1] = instr.operands[1]; // result_id
            sample_operands[2] = combined_id;
            sample_operands[3] = uv_id;
            sample_operands[4] = 0x2; // ImageOperands: Lod
            sample_operands[5] = lod_id;
            try new_instrs.append(alloc, .{
                .opcode = Op.op_image_sample_explicit_lod,
                .operands = sample_operands,
            });
            continue;
        }

        // OpName for a placeholder sampler variable: rename to the
        // stripped form (X_sampler2d -> X) AND emit a paired OpName
        // for the new sampler variable (X -> X_sampler).
        if (instr.opcode == Op.op_name and
            instr.operands.len >= 1 and
            pairs.get(instr.operands[0]) != null)
        {
            const pair: WgslPair = pairs.get(instr.operands[0]).?;

            // Texture variable name: stripped form.
            const tex_name_words: []u32 = try packString(alloc, pair.name_stripped);
            const tex_name_operands: []u32 = try alloc.alloc(u32, 1 + tex_name_words.len);
            tex_name_operands[0] = pair.original_var_id;
            for (tex_name_words, 0..) |w, j| {
                tex_name_operands[1 + j] = w;
            }
            try new_instrs.append(alloc, .{
                .opcode = Op.op_name,
                .operands = tex_name_operands,
            });

            // Sampler variable name: stripped + "_sampler".
            const sampler_name: []u8 = try allocPrint(
                alloc,
                "{s}_sampler",
                .{pair.name_stripped},
            );
            const samp_name_words: []u32 = try packString(alloc, sampler_name);
            const samp_name_operands: []u32 = try alloc.alloc(u32, 1 + samp_name_words.len);
            samp_name_operands[0] = pair.new_sampler_var_id;
            for (samp_name_words, 0..) |w, j| {
                samp_name_operands[1 + j] = w;
            }
            try new_instrs.append(alloc, .{
                .opcode = Op.op_name,
                .operands = samp_name_operands,
            });
            continue;
        }

        // Drop existing OpDecorate Binding for placeholder textures -
        // we emitted explicit ones unconditionally above with the
        // canonical (texture 0..N, samplers N..2N) layout.  Keeping
        // the original would create a duplicate decoration (spirv-opt
        // would dedupe, but spec-wise it's incorrect).
        if (instr.opcode == Op.op_decorate and
            instr.operands.len >= 3 and
            instr.operands[1] == Decoration.binding and
            pairs.get(instr.operands[0]) != null)
        {
            continue;
        }

        // OpDecorate DescriptorSet for a placeholder sampler: keep
        // it if the codegen-emitted decoration matches what we want,
        // drop it if the rewriter chose a different set.
        //
        // The schema-driven path emits OpDecorate calls from
        // `zm.binding(...)`, captured into `SamplerEntry.existing_set`;
        // those calls are ALREADY in the instruction stream.  When we
        // reach them in this rewrite pass, we want to keep them
        // verbatim - they're the canonical value.
        //
        // The legacy fallback path (no codegen-emitted decoration)
        // generates fresh OpDecorate calls in the types-injection
        // block above and would conflict with stale Zig-emitted ones.
        // But since Zig's SPIR-V backend doesn't emit DescriptorSet
        // for placeholder samplers in the legacy path, this branch
        // is effectively a no-op for those - keep the instruction.
        //
        // Net effect: keep all OpDecorate DescriptorSet for samplers
        // we saw; the rewriter never injects a duplicate (the emission
        // block above skips emission when `has_existing_texture_decs`
        // is true).
        //
        // The same applies to OpDecorate Binding - keep it if it
        // was already in the source; the emission block above skips
        // re-emission for explicitly-bound textures.

        // ROBUSTNESS: strip any Binding/DescriptorSet the source carried on a
        // paired texture var - the emission block above now re-emits BOTH
        // fresh from the pair, so keeping the originals would duplicate (and,
        // worse, a downstream pass could drop the original Binding while
        // keeping DescriptorSet, leaving spv2wgsl to auto-assign binding 0 and
        // collide with a UBO - the bloom post-pass bug). One authority for
        // these decorations: the pair.
        if (instr.opcode == Op.op_decorate and
            instr.operands.len >= 2 and
            (instr.operands[1] == Decoration.binding or
                instr.operands[1] == Decoration.descriptor_set) and
            pairs.get(instr.operands[0]) != null)
        {
            continue;
        }

        // Default: keep the instruction as-is.
        try new_instrs.append(alloc, instr);
    }

    if (!types_inserted) {
        try new_instrs.appendSlice(alloc, types.new_instructions);
    }

    // SPIR-V 1.4+ requires every entry-point-visible interface
    // variable (UniformConstant, Input, Output) to be listed in
    // OpEntryPoint's interface IDs.  We just added new sampler
    // variables that the entry point's body references (via the
    // new sampler OpLoads) - they need to appear in the interface
    // list or spirv-val rejects with "interface variable not listed."
    //
    // OpEntryPoint operand layout:
    //   [0] execution_model (Vertex / Fragment / GLCompute / ...)
    //   [1] entry_point_function_id
    //   [2..k] name string (packed words, nul-terminated)
    //   [k..] interface variable ids (zero or more)
    //
    // We don't know k a priori (string length varies), so we append
    // the new ids to the END of the operand list - which is the
    // interface section, regardless of where the string ends.  Order
    // among interface ids doesn't matter to the validator.
    var collected_new_var_ids: ArrayList(u32) = .empty;
    defer collected_new_var_ids.deinit(alloc);
    var pair_it: std.AutoHashMap(u32, WgslPair).ValueIterator = pairs.valueIterator();
    while (pair_it.next()) |pair| {
        try collected_new_var_ids.append(alloc, pair.new_sampler_var_id);
    }

    if (collected_new_var_ids.items.len > 0) {
        var j: usize = 0;
        while (j < new_instrs.items.len) : (j += 1) {
            const instr: zspv.Instruction = new_instrs.items[j];
            if (instr.opcode != Op.op_entry_point) {
                continue;
            }

            const old_len: usize = instr.operands.len;
            const extra: usize = collected_new_var_ids.items.len;
            const expanded: []u32 = try alloc.alloc(u32, old_len + extra);
            for (instr.operands, 0..) |op, idx| {
                expanded[idx] = op;
            }
            for (collected_new_var_ids.items, 0..) |sid, idx| {
                expanded[old_len + idx] = sid;
            }
            new_instrs.items[j] = .{
                .opcode = Op.op_entry_point,
                .operands = expanded,
            };
        }
    }

    mod.instructions = try new_instrs.toOwnedSlice(alloc);
    mod.header[2] = next_id;
}

// ---- Tests ----------------------------------------------------------

test "discover: returns empty Discovery for a module with no samplers" {
    const arena_alloc: Allocator = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(arena_alloc);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    // Minimal module: header + OpNop.
    const mod: zspv.Module = .{
        .header = .{ 0x00010500, 0, 1, 0 },
        .instructions = &.{},
    };
    const disc: Discovery = try discover(arena, mod);
    try expectEqual(@as(usize, 0), disc.samplers.len);
    try expectEqual(@as(u32, 0), disc.zsample2d_func_id);
}

test "unpackString: roundtrips packed SPIR-V strings" {
    const arena_alloc: Allocator = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(arena_alloc);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    // "ABC\0" packed little-endian into one u32: 0x00434241
    const words = [_]u32{0x00434241};
    const s: []const u8 = try unpackString(arena, &words);
    try expectEqualStrings("ABC", s);

    // "ABCDE\0\0\0" packed into two words: [0x44434241, 0x00000045]
    const words2 = [_]u32{ 0x44434241, 0x00000045 };
    const s2: []const u8 = try unpackString(arena, &words2);
    try expectEqualStrings("ABCDE", s2);
}
