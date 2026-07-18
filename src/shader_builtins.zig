//! shader_builtins.zig — the SPIR-V shader DSL: stage-IO decorators, opaque
//! texture / sampler / storage types, and the texture-sampling + storage-buffer
//! intrinsics. These emit SPIR-V inline asm (or `@SpirvType` declarations) that
//! only the SPIR-V backend lowers, so they are SHADER-ONLY.
//!
//! They used to live at the tail of `zimrmath.zig` so a shader needed one
//! import — but `zm` is imported by the whole host too, so editing a shader
//! intrinsic invalidated every module's cache and forced a full-project
//! rebuild. Extracted here so touching one only rebuilds shaders. A shader now
//! imports this module for the GPU-interface layer and `zm` for vector math.

const builtin = @import("builtin");
const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const float = zm.float;

// ---- SPIR-V shader decorators ---------------------------------------
//
// `location` / `binding` / `zsample2d` emit SPIR-V inline asm that only the
// SPIR-V backend lowers. On host targets the asm bodies are never analyzed —
// Zig's lazy compilation only reaches them on a SPIR-V build — so they are not
// a host-portability concern. See the module doc above for why they live here
// (split out of zimrmath so host edits don't rebuild the world).

/// Set the SPIR-V `Location` decoration on a stage input/output
/// variable.  Called with comptime-known args; the body emits
/// `OpDecorate %target Location N` and gets stripped during dead-
/// code elimination.
///
/// `n` is the location number (0-based).  For vertex attributes,
/// match the raylib reserved layout: position=0, texcoord=1,
/// normal=2, color=3, tangent=4, texcoord2=5.
pub fn location(comptime ptr: anytype, comptime n: u32) void {
    asm volatile (
        \\OpDecorate %target Location $n
        :
        : [target] "" (ptr),
          [n] "c" (n),
    );
}

/// Set the SPIR-V `DescriptorSet` + `Binding` decorations on a
/// sampler or UBO variable.  Same call-site rule as `location`.
///
/// `set` is the descriptor set number (usually 0 for shader-local
/// resources, 1+ for shared engine resources).  `bind` is the
/// binding number within the set.
pub fn binding(
    comptime ptr: anytype,
    comptime set: u32,
    comptime bind: u32,
) void {
    asm volatile (
        \\OpDecorate %target DescriptorSet $set
        \\OpDecorate %target Binding $bind
        :
        : [target] "" (ptr),
          [set] "c" (set),
          [bind] "c" (bind),
    );
}

/// Sample a 2D texture.  In shader source, looks like:
/// ```zig
/// extern const s_albedo_sampler2d: u32 addrspace(.constant);
/// const c = zm.zsample2d(s_albedo_sampler2d, frag_uv);
/// ```
/// The `tools/zspv_rewrite.zig` post-process rewrites the call site
/// to a real `OpImageSampleImplicitLod` and the helper body becomes
/// `return texture(_s, _uv);` in the emitted GLSL.
///
/// CRITICAL: MUST be `noinline`.  `spirv-opt -O` would inline
/// through DontInline anyway, which is why sampler shaders use a
/// custom limited pass list (see `tools/zspv_rewrite.zig`).  With
/// the limited pass list, `noinline` ensures the function survives
/// dead-strip and `rewriteSamplers` has something to grab onto.
///
/// Body uses a direct `Vec{ ... }` struct literal (NOT `vec4(...)`)
/// so spirv-cross emits the construction inline rather than as a
/// call to a helper function that would survive the limited
/// spirv-opt pass list and pollute the output GLSL.
pub noinline fn zsample2d(handle: u32, uv: Vec2) Vec {
    return Vec{ uv[0], uv[1], float(handle), 0.0 };
}

/// Sample a 2D texture at an EXPLICIT level-of-detail — the vertex-stage-safe
/// twin of `zsample2d`.  In shader source, looks like:
/// ```zig
/// const c = zm.zsample2d_level(s_height_sampler2d, frag_uv, 0.0);
/// ```
/// `tools/zspv_rewrite.zig` rewrites the call site to `OpImageSampleExplicitLod`
/// (with the `lod` as the `Lod` image operand) instead of the implicit form.
/// Unlike `zsample2d`'s implicit LOD, the explicit op needs no derivatives, so
/// it is legal in a VERTEX shader (e.g. sampling a height map to displace a
/// vertex).  Same `noinline` + `Vec{...}` literal constraints as `zsample2d`
/// (the `lod` rides in the w lane purely so the placeholder body uses the arg).
pub noinline fn zsample2d_level(handle: u32, uv: Vec2, lod: f32) Vec {
    return Vec{ uv[0], uv[1], float(handle), lod };
}

// ===========================================================================
// @SpirvType-backed texture sampling (the no-zspv_rewrite path, Zig 0.17+)
// ===========================================================================
//
// Background: the `zsample2d`/`location`/`binding` trio above is the OLD path.
// A shader declares a `u32` handle, samples a placeholder, and the
// `tools/zspv_rewrite.zig` post-process rebuilds the SPIR-V into a real
// OpTypeSampledImage + OpImageSampleImplicitLod (and a custom limited
// spirv-opt pass list keeps the placeholder alive long enough to rewrite).
// That whole machine exists only because the pre-0.17 SPIR-V backend could
// not declare or operate on opaque image types from Zig.
//
// 0.17-dev.956 can. `@SpirvType` declares the image/sampled-image types and
// `@extern(..., .{ .decoration = .{ .descriptor = ... } })` binds them, so the
// helpers below emit the REAL ops directly — no placeholder, no rewrite, and
// the full `spirv-opt -O` can run again. See `src/notes/spikes/` for the
// minimal proofs and `src/notes/zig-spirv-compiler-interface.md` for the
// complete compiler-interface contract + a recovery playbook for when the
// compiler changes (it WILL — every field name and constraint below is a thing
// that has already moved once).
//
// WHY THESE ARE FUNCTIONS, NOT FILE-SCOPE CONSTS: `@SpirvType` is only valid on
// the SPIR-V target, but zimrmath also compiles to host/wasm32. A file-scope
// `const T = @SpirvType(...)` would be analyzed EAGERLY and break every host
// build. Wrapping each type in a `fn ... type` keeps it behind Zig's lazy
// analysis (a `pub fn` is only analyzed when referenced — and only shaders,
// built for SPIR-V, ever reference these). The asm bodies are lazy for the same
// reason `zsample2d`'s is. RULE: never reference any of the four decls below
// from host code or a host `test`, or you force eager SPIR-V analysis on host.

// ⚠ P3 STATUS (956): the SAMPLE OP works — `sampleLod` inlines to native
// `OpSampledImage` + `OpImageSampleImplicitLod`, and spv2wgsl lowers it to
// `textureSample(tex, samp, uv)` with separate `texture_2d<f32>` + `sampler`.
// But the @extern DESCRIPTOR BINDING does NOT yet materialize: an @extern whose
// pointee is a zero-bit opaque type folds to OpUndef (compiler `constantNavRef`
// bails for `!hasRuntimeBits` before registering the global — see the interface
// doc / spv2wgsl.zig header). So these helpers are the correct target shape and
// compile, but are NOT usable end-to-end until that blocker is resolved (compiler
// fix, or an asm-declared-OpVariable workaround). The old `zsample2d`/zspv_rewrite
// path remains the working sampler path meanwhile.

/// The SPIR-V 2D texture type — a SAMPLED `OpTypeImage` (NOT a combined
/// sampled-image). WGSL has no combined sampler: a texture and its sampler are
/// SEPARATE bindings, paired at the sample site by `OpSampledImage`, which
/// spv2wgsl lowers to `textureSample(tex, samp, uv)`. (A combined
/// `OpTypeSampledImage` *binding* makes spv2wgsl reject the shader — "WGSL
/// requires separate texture+sampler bindings".) `.sampled = f32` → the WGSL
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

/// The SPIR-V sampler type — a `sampler` binding in WGSL.
pub fn Sampler() type {
    if (comptime !builtin.target.cpu.arch.isSpirV()) {
        return opaque {};
    }
    return @SpirvType(.sampler);
}

/// The combined sampled-image type, needed ONLY as the result type of the
/// `OpSampledImage` that pairs a texture with a sampler inside `sampleLod`. It
/// is never a binding (WGSL forbids that) — it exists for one instruction.
fn SampledImage2D() type {
    if (comptime !builtin.target.cpu.arch.isSpirV()) {
        return opaque {};
    }
    return @SpirvType(.{ .sampled_image = Texture2D() });
}

/// Pointer to a `Texture2D` binding. UniformConstant storage class
/// (`addrspace(.constant)`) — where every image/sampler descriptor lives.
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
/// `.descriptor` decoration emits the `OpDecorate DescriptorSet/Binding` that
/// the old `zm.binding(&s, set, bind)` did — on a real texture, not a `u32`.
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

/// Sample a 2D texture with a sampler, implicit LOD (FRAGMENT stage only —
/// implicit LOD needs screen-space derivatives). Replaces `zm.zsample2d` and the
/// entire `zspv_rewrite` path.
///
/// `inline` is REQUIRED: the zimr shader pipeline is pure-Zig
/// (build-obj → zspv → spv2wgsl) with NO spirv-opt inlining pass, so the ops
/// must land at the call site referencing the global texture + sampler directly.
/// A non-inline helper would leave a function taking texture/sampler parameters,
/// which does not lower cleanly.
///
/// The asm references SPIR-V *types* via the `"t"` constraint (NOT as value
/// operands — that was the wall the prior spike hit): `"t"` resolves through
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
/// valid in UNIFORM control flow — hence the "sample at shaderMain's top" rule),
/// an explicit LOD needs no derivatives, so this is valid in ANY control flow:
/// inside a helper fn, an `if`, or a loop. Use it to sample outside shaderMain's
/// uniform top. spv2wgsl lowers it to WGSL `textureSampleLevel(tex, samp, uv,
/// lod)`. Trade-off: no automatic mip selection — pass the LOD you want (0.0 is
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
/// `.r32f`, `.rgba32f`, …), taken as `anytype` so this file never has to name
/// the compiler-internal `std.lang.Type.Spirv.Image.Format` enum (one less
/// thing to chase when the compiler moves it). `.access = .unknown` — see the
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
// @SpirvType storage buffers (runtime arrays) — the FIRST end-to-end-working
// @SpirvType resource path on 956. Unlike samplers/images (zero-bit opaque →
// @extern folds to OpUndef, BLOCKED), a storage-buffer struct has runtime bits,
// so its @extern materializes as a real `var<storage>` binding. Access is via
// an asm `OpAccessChain` because plain-Zig `buf.items[i]` mis-lowers on 956
// ("cannot perform pointer cast" on the runtime-array field). spv2wgsl lowers
// the result to `b.field_0[i]` on a `var<storage, read_write>` binding (see the
// `emitTypeRuntimeArray` support added to spv2wgsl.zig).
// ---------------------------------------------------------------------------

/// A storage-buffer block holding a single runtime-sized array of `Elem`
/// (`@SpirvType` runtime array as the trailing struct member — the WGSL/Vulkan
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
