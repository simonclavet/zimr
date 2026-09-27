//! shader_builtins.zig - the SPIR-V shader DSL: opaque texture / sampler /
//! storage types, and the texture-sampling + storage-buffer intrinsics. These
//! emit SPIR-V inline asm (or `@SpirvType` declarations) that only the SPIR-V
//! backend lowers, so they are SHADER-ONLY.
//!
//! They used to live at the tail of `zimrmath.zig` so a shader needed one
//! import - but `zm` is imported by the whole host too, so editing a shader
//! intrinsic invalidated every module's cache and forced a full-project
//! rebuild. Extracted here so touching one only rebuilds shaders. A shader now
//! imports this module for the GPU-interface layer and `zm` for vector math.

const builtin = @import("builtin");
const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

// ===========================================================================
// @SpirvType-backed textures, samplers and sampling
// ===========================================================================
//
// `@SpirvType` declares the opaque image / sampler / sampled-image types, and
// `@extern(..., .{ .decoration = .{ .descriptor = ... } })` binds a texture or a
// sampler to its (group, binding). `sampleLod` / `sampleLevel` then emit the
// real `OpSampledImage` + `OpImageSample*` ops, which spv2wgsl lowers to
// `textureSample(tex, samp, uv)` / `textureSampleLevel(...)`. Nothing rewrites
// the SPIR-V after the compiler: what it writes is final.
//
// Declarations are NOT made here - `tools/gen_shader_externs.zig` emits one
// decorated file-scope `@extern` per texture and per sampler from the shader's
// schema. They must stay FILE-SCOPE: calling a function that returns the
// handle at runtime leaves a WGSL function returning a texture type, which WGSL
// forbids.
//
// Why there is no `location(ptr, n)` / `binding(ptr, set, bind)` helper any
// more: they decorated a global through inline asm from inside a function, and
// Zig 0.17.0-dev.2307's rewritten SPIR-V linker drops an annotation whose target
// is defined in a different declaration - silently. The decoration belongs on
// the `@extern` itself; see src/notes/spirv_2307_decorations_plan.md. The
// compiler-interface contract, and a recovery playbook for when the compiler
// moves again, is src/notes/zig-spirv-compiler-interface.md.
//
// WHY THE TYPES ARE FUNCTIONS, NOT FILE-SCOPE CONSTS: `@SpirvType` is only valid
// on the SPIR-V target, but this module also compiles to host/wasm32. A
// file-scope `const T = @SpirvType(...)` would be analyzed EAGERLY and break
// every host build. Wrapping each type in a `fn ... type` keeps it behind Zig's
// lazy analysis (a `pub fn` is only analyzed when referenced - and only shaders,
// built for SPIR-V, ever reference these). The asm bodies are lazy for the same
// reason. RULE: never reference any of these from host code or a host `test`,
// or you force eager SPIR-V analysis on host.

/// The SPIR-V 2D texture type - a SAMPLED `OpTypeImage` (NOT a combined
/// sampled-image). WGSL has no combined sampler: a texture and its sampler are
/// SEPARATE bindings, paired at the sample site by `OpSampledImage`, which
/// spv2wgsl lowers to `textureSample(tex, samp, uv)`. (A combined
/// `OpTypeSampledImage` *binding* makes spv2wgsl reject the shader - "WGSL
/// requires separate texture+sampler bindings".) `.sampled = f32` -> the WGSL
/// type `texture_2d<f32>`. `.format = .unknown` (format is only meaningful for
/// storage images); `.access = .unknown` because Vulkan expresses read/write via
/// NonReadable/NonWritable decorations, not the image-type access qualifier
/// (`.read_only`/`.write_only` are OpenCL-only and reject on `spirv32-vulkan`).
pub fn Texture2D() type {
    if (comptime !builtin.target.cpu.arch.isSpirV()) {
        return opaque {};
    }
    return @SpirvType(.{ .image = .{
        .usage = .{ .sampled = f32 },
        .format = .unknown,
        .dim = .@"2d",
        .depth = .unknown,
        .arrayed = false,
        .multisampled = false,
        .access = .unknown,
    } });
}

/// The SPIR-V sampler type - a `sampler` binding in WGSL.
pub fn Sampler() type {
    if (comptime !builtin.target.cpu.arch.isSpirV()) {
        return opaque {};
    }
    return @SpirvType(.sampler);
}

/// The combined sampled-image type, needed ONLY as the result type of the
/// `OpSampledImage` that pairs a texture with a sampler inside `sampleLod`. It
/// is never a binding (WGSL forbids that) - it exists for one instruction.
fn SampledImage2D() type {
    if (comptime !builtin.target.cpu.arch.isSpirV()) {
        return opaque {};
    }
    return @SpirvType(.{ .sampled_image = Texture2D() });
}

/// Pointer to a `Texture2D` binding. UniformConstant storage class
/// (`addrspace(.constant)`) - where every image/sampler descriptor lives.
pub fn Texture2DPtr() type {
    if (comptime !builtin.target.cpu.arch.isSpirV()) {
        return *const anyopaque;
    }
    return *addrspace(.constant) const Texture2D();
}

/// Pointer to a `Sampler` binding (UniformConstant storage class).
pub fn SamplerPtr() type {
    if (comptime !builtin.target.cpu.arch.isSpirV()) {
        return *const anyopaque;
    }
    return *addrspace(.constant) const Sampler();
}

/// Declare a 2D texture descriptor binding. Pair it with a `sampler(...)`
/// binding and sample the two together with `sampleLod`. The `@extern`
/// `.descriptor` decoration puts the DescriptorSet/Binding on the variable
/// itself. Call it at FILE SCOPE only (see the section header above).
///
/// ```zig
/// const albedo_tex = zm.texture2D("albedo_tex", 0, 1);
/// const albedo_smp = zm.sampler("albedo_smp", 0, 2);
/// const c: zm.Vec = zm.sampleLod(albedo_tex, albedo_smp, frag_uv);
/// ```
pub fn texture2D(
    comptime name: [:0]const u8,
    comptime set: u32,
    comptime bind: u32,
) Texture2DPtr() {
    return @extern(Texture2DPtr(), .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = set, .binding = bind } },
    });
}

/// Declare a sampler descriptor binding (pairs with a `texture2D(...)`).
pub fn sampler(
    comptime name: [:0]const u8,
    comptime set: u32,
    comptime bind: u32,
) SamplerPtr() {
    return @extern(SamplerPtr(), .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = set, .binding = bind } },
    });
}

/// Sample a 2D texture with a sampler, implicit LOD (FRAGMENT stage only -
/// implicit LOD needs screen-space derivatives).
///
/// `inline` is REQUIRED: the zimr shader pipeline is pure-Zig
/// (build-obj -> spv2wgsl) with NO spirv-opt inlining pass, so the ops
/// must land at the call site referencing the global texture + sampler directly.
/// A non-inline helper would leave a function taking texture/sampler parameters,
/// which does not lower cleanly.
///
/// The asm references SPIR-V *types* via the `"t"` constraint (NOT as value
/// operands - that was the wall the prior spike hit): `"t"` resolves through
/// `cg.resolveType` to the module's deduped id, so `%img_ty`/`%smp_ty`/`%si_ty`
/// match the bindings exactly. `OpSampledImage` combines them; the implicit-LOD
/// sample yields `vec4` (`%v4f`).
pub inline fn sampleLod(tex: Texture2DPtr(), samp: SamplerPtr(), uv: Vec2) Vec {
    return asm volatile (
        \\%img = OpLoad %img_ty %tex
        \\%smp = OpLoad %smp_ty %samp
        \\%si  = OpSampledImage %si_ty %img %smp
        \\%res = OpImageSampleImplicitLod %v4f %si %uv
        : [res] "" (-> Vec),
        : [img_ty] "t" (Texture2D()),
          [smp_ty] "t" (Sampler()),
          [si_ty] "t" (SampledImage2D()),
          [v4f] "t" (Vec),
          [tex] "" (tex),
          [samp] "" (samp),
          [uv] "" (uv),
    );
}

/// Sample a 2D texture at an EXPLICIT level-of-detail. Unlike `sampleLod`
/// (implicit LOD, which computes screen-space derivatives and is therefore only
/// valid in UNIFORM control flow - hence the "sample at shaderMain's top" rule),
/// an explicit LOD needs no derivatives, so this is valid in ANY control flow:
/// inside a helper fn, an `if`, or a loop. Use it to sample outside shaderMain's
/// uniform top. spv2wgsl lowers it to WGSL `textureSampleLevel(tex, samp, uv,
/// lod)`. Trade-off: no automatic mip selection - pass the LOD you want (0.0 is
/// the full-resolution mip). Like `sampleLod`, this is `inline` so the sample
/// lands at the call site referencing the global texture + sampler directly.
pub inline fn sampleLevel(
    tex: Texture2DPtr(),
    samp: SamplerPtr(),
    uv: Vec2,
    lod: f32,
) Vec {
    return asm volatile (
        \\%img = OpLoad %img_ty %tex
        \\%smp = OpLoad %smp_ty %samp
        \\%si  = OpSampledImage %si_ty %img %smp
        \\%res = OpImageSampleExplicitLod %v4f %si %uv Lod %lod
        : [res] "" (-> Vec),
        : [img_ty] "t" (Texture2D()),
          [smp_ty] "t" (Sampler()),
          [si_ty] "t" (SampledImage2D()),
          [v4f] "t" (Vec),
          [tex] "" (tex),
          [samp] "" (samp),
          [uv] "" (uv),
          [lod] "" (lod),
    );
}

/// The SPIR-V storage 2D image type (`texture_storage_2d<...>` in WGSL). Unlike
/// the sampled texture, a storage image's `format` is significant and must match
/// the host-side view format. `fmt` is a Format enum literal (`.rgba8unorm`,
/// `.r32f`, `.rgba32f`, ...), taken as `anytype` so this file never has to name
/// the compiler-internal `std.lang.Type.Spirv.Image.Format` enum (one less
/// thing to chase when the compiler moves it). `.access = .unknown` - see the
/// `Texture2D` note on Vulkan access decorations.
pub fn StorageImage2D(comptime fmt: anytype) type {
    return @SpirvType(.{ .image = .{
        .usage = .storage,
        .format = fmt,
        .dim = .@"2d",
        .depth = .unknown,
        .arrayed = false,
        .multisampled = false,
        .access = .unknown,
    } });
}

/// Write a texel to a storage image (COMPUTE/FRAGMENT). New capability unlocked
/// by `@SpirvType` storage images. `ImgT` is a `StorageImage2D(fmt)` type passed
/// explicitly (zimr avoids `@TypeOf`); its id reaches the asm via `"t"` exactly
/// as in `sampleLod`. `OpImageWrite` produces no result. `coord` is integer
/// pixel coordinates; `texel` is the rgba value.
pub fn imageStore(
    comptime ImgT: type,
    img: *addrspace(.constant) const ImgT,
    coord: @Vector(2, i32),
    texel: Vec,
) void {
    asm volatile (
        \\%im = OpLoad %img_ty %img
        \\OpImageWrite %im %coord %texel
        :
        : [img_ty] "t" (ImgT),
          [img] "" (img),
          [coord] "" (coord),
          [texel] "" (texel),
    );
}

// ---------------------------------------------------------------------------
// @SpirvType storage buffers (runtime arrays) - the FIRST end-to-end-working
// @SpirvType resource path on 956. Unlike samplers/images (zero-bit opaque ->
// @extern folds to OpUndef, BLOCKED), a storage-buffer struct has runtime bits,
// so its @extern materializes as a real `var<storage>` binding. Access is via
// an asm `OpAccessChain` because plain-Zig `buf.items[i]` mis-lowers on 956
// ("cannot perform pointer cast" on the runtime-array field). spv2wgsl lowers
// the result to `b.field_0[i]` on a `var<storage, read_write>` binding (see the
// `emitTypeRuntimeArray` support added to spv2wgsl.zig).
// ---------------------------------------------------------------------------

/// A storage-buffer block holding a single runtime-sized array of `Elem`
/// (`@SpirvType` runtime array as the trailing struct member - the WGSL/Vulkan
/// SSBO shape). Declare a binding with `storageBuffer`, access with
/// `ssboLoad`/`ssboStore`.
pub fn StorageBuffer(comptime Elem: type) type {
    return extern struct { items: @SpirvType(.{ .runtime_array = Elem }) };
}

/// Pointer to a `StorageBuffer(Elem)` binding (StorageBuffer storage class).
pub fn StorageBufferPtr(comptime Elem: type) type {
    return *addrspace(.storage_buffer) StorageBuffer(Elem);
}

/// Declare a storage-buffer descriptor binding and return its pointer.
pub fn storageBuffer(
    comptime Elem: type,
    comptime name: [:0]const u8,
    comptime set: u32,
    comptime bind: u32,
) StorageBufferPtr(Elem) {
    return @extern(StorageBufferPtr(Elem), .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = set, .binding = bind } },
    });
}

/// Load `buf.items[i]`. `inline` (no spirv-opt pass) + asm `OpAccessChain`
/// (field 0 = the runtime array, then element `i`) because plain-Zig
/// runtime-array indexing mis-lowers on 956.
pub inline fn ssboLoad(comptime Elem: type, buf: StorageBufferPtr(Elem), i: u32) Elem {
    return asm volatile (
        \\%u32  = OpTypeInt 32 0
        \\%zero = OpConstant %u32 0
        \\%p    = OpAccessChain %elemptr %buf %zero %i
        \\%v    = OpLoad %elemty %p
        : [v] "" (-> Elem),
        : [elemptr] "t" (*addrspace(.storage_buffer) Elem),
          [elemty] "t" (Elem),
          [buf] "" (buf),
          [i] "" (i),
    );
}

/// Store `buf.items[i] = val`. See `ssboLoad` for why this is asm.
pub inline fn ssboStore(
    comptime Elem: type,
    buf: StorageBufferPtr(Elem),
    i: u32,
    val: Elem,
) void {
    asm volatile (
        \\%u32  = OpTypeInt 32 0
        \\%zero = OpConstant %u32 0
        \\%p    = OpAccessChain %elemptr %buf %zero %i
        \\OpStore %p %val
        :
        : [elemptr] "t" (*addrspace(.storage_buffer) Elem),
          [buf] "" (buf),
          [i] "" (i),
          [val] "" (val),
    );
}
