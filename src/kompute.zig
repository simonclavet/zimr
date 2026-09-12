//! kompute — the compute DSL. A kernel file declares `config` + `Buffers` +
//! `Params` + one or more kernel `fn`s; this module generates the boilerplate so
//! the same source runs as a GPU compute dispatch or a CPU loop (see
//! `src/notes/tutorials/gpu-compute-tutorial.md`).
//!
//! A kernel file looks like:
//!
//!     const k = @import("kompute");
//!     pub const config = k.Config{ .max = 1024, .workgroup = 64 };
//!     pub const Buffers = extern struct { data: [config.max]f32 };
//!     pub const Params = extern struct { count: u32, _pad: [3]u32 = .{ 0, 0, 0 } };
//!     pub const g = k.Globals(@This());   // per-field storage on GPU, var on CPU
//!     const b_data = g.bind(.data);         // one alias per Buffers field
//!     pub fn double(c: k.Ctx(@This())) void {
//!         if (c.id >= c.params.count) return;
//!         b_data[c.id] = b_data[c.id] * 2.0;
//!     }
//!     comptime {
//!         k.installKernel(@This(), "double");
//!     }
//!
//! Buffers use explicit `[config.max]T` arrays (the transpiler-proven shape; the
//! `k.Buffer(T)` wrapper from the tutorial is deferred — clean synthesis needs the
//! removed `@Type` builtin, and a pointer-bearing wrapper hits the spv2wgsl
//! let-copy bug). Buffers are reached via the module-level `b` alias, NEVER via a
//! Ctx field (same let-copy bug). Params ride in `Ctx` by value (read-only, safe).
const std = @import("std");
const meta = std.meta;
const builtin = @import("builtin");
const gpu = std.spirv;

/// True when compiling for SPIR-V (the GPU dispatch). False for the native CPU
/// loop. Kernel files comptime-branch on it via the generated helpers below.
pub const is_gpu: bool = builtin.target.cpu.arch.isSpirV();

// ---- Atomics (the parallel-grid primitive) ----
// Zig's SPIR-V backend (0.17.0-dev.704) does NOT implement `@atomicRmw` /
// `@atomicLoad` / `@atomicStore` for the spirv target ("TODO (SPIR-V):
// implement AIR tag atomic_*"), so a kernel cannot use the builtins directly.
// The route around it mirrors `zsample2d` (zimrmath.zig): a `noinline` helper
// with a DUMMY body. On GPU, Zig emits a real `OpFunctionCall` to the helper;
// `spv2wgsl` then INTERCEPTS that call by name (substring `zatomicAdd` /
// `zatomicLoad` / `zatomicStore`), emits the WGSL atomic builtin
// (`atomicAdd(&field[idx], val)` etc.), DELETES the helper, and marks the
// target binding `array<atomic<u32>>`. The dummy body is never executed on GPU.
// On CPU the SAME call lowers to the genuine `@atomicRmw`/`@atomicLoad`/
// `@atomicStore` (the native backend supports them), so the CPU twin is a
// correct oracle. MIGRATION: when Zig's SPIR-V backend lands atomics, swap
// these bodies for the real builtins on GPU too and add an OpAtomic* arm to
// spv2wgsl — the kernel-author API and emitted WGSL are unchanged.
//
// Usage in a kernel (arr is a `g.bind(.field)` storage pointer to `[N]u32`):
//     const slot = k.atomicAdd(arr, cell, 1);   // returns the value BEFORE add
//     const n    = k.atomicLoad(arr, cell);
//     k.atomicStore(arr, cell, 0);

noinline fn zatomicAdd(arr: anytype, idx: u32, val: u32) u32 {
    const prev: u32 = arr[idx];
    arr[idx] = prev +% val;
    return prev;
}

/// Atomic read-modify-write add. Returns the value stored BEFORE the add (the
/// WGSL `atomicAdd` semantics — the per-particle grid build uses this returned
/// value as the claimed slot index).
pub inline fn atomicAdd(arr: anytype, idx: u32, val: u32) u32 {
    if (is_gpu) {
        return zatomicAdd(arr, idx, val);
    }
    return @atomicRmw(u32, &arr[idx], .Add, val, .monotonic);
}

noinline fn zatomicLoad(arr: anytype, idx: u32) u32 {
    return arr[idx];
}

/// Atomic load of a single `u32` cell.
pub inline fn atomicLoad(arr: anytype, idx: u32) u32 {
    if (is_gpu) {
        return zatomicLoad(arr, idx);
    }
    return @atomicLoad(u32, &arr[idx], .monotonic);
}

noinline fn zatomicStore(arr: anytype, idx: u32, val: u32) void {
    arr[idx] = val;
}

/// Atomic store of a single `u32` cell.
pub inline fn atomicStore(arr: anytype, idx: u32, val: u32) void {
    if (is_gpu) {
        zatomicStore(arr, idx, val);
        return;
    }
    @atomicStore(u32, &arr[idx], val, .monotonic);
}

// The GPU-side `noinline` helpers with dummy bodies. MUST be `noinline` so the
// call survives to spv2wgsl (which rewrites it). The bodies are never executed
// on GPU — they exist only to give Zig a real OpFunction to call. Named with
// the `zatomic*` stems spv2wgsl matches on (it sees `<module>_zatomicAdd__anon_N`).

// ---- Workgroup shared memory + barriers (the tiling primitive) ----
// Same situation as atomics: Zig's SPIR-V backend (0.17.0-dev.704) has no
// `workgroupBarrier` intrinsic, so a `noinline` helper with an EMPTY body is
// routed through spv2wgsl, which emits the WGSL `workgroupBarrier()` builtin
// and DELETES the helper. The empty body survives to SPIR-V because `noinline`
// blocks elision (verified: the OpFunctionCall is present in the .spv).
//
// Shared memory is a GPU-ONLY OPTIMISATION. A workgroup-address-space variable
// has no CPU equivalent and the CPU runs kernels as a plain sequential loop
// (no concurrent workgroup), so a tiling kernel comptime-splits on `is_gpu`:
// the GPU path loads a tile into shared memory then barriers; the CPU path
// reads the SAME data straight from the global storage buffers. The CPU result
// is the oracle; the shared path is trusted because it only CACHES identical
// data. Never read shared memory on the CPU side.

/// This invocation's index WITHIN its workgroup (0..config.workgroup-1).
/// GPU-only — call it only inside an `if (k.is_gpu)` branch.
pub inline fn localId() u32 {
    return gpu.local_invocation_id[0];
}

/// This workgroup's index along x. GPU-only (see `localId`).
///
/// ⚠️ UNRELIABLE on some drivers (observed wrong for many threads on Adreno
/// 7xx). PREFER deriving the decomposition from `c.id` (global_invocation_id),
/// which is delivered correctly everywhere: with a workgroup size of `W`,
///     const cell = c.id / W;   // == workgroup_id
///     const lid  = c.id % W;   // == local_invocation_id
/// Only reach for this builtin if you have confirmed it works on your target.
pub inline fn workgroupId() u32 {
    return gpu.workgroup_id[0];
}

/// The pointer type `shared` returns: a workgroup-storage pointer on GPU, a
/// plain pointer on CPU (where the array is never read — the CPU path goes
/// through global memory).
fn SharedPtr(comptime T: type, comptime n: usize) type {
    return if (is_gpu) *addrspace(.shared) [n]T else *[n]T;
}

/// Declare/access a workgroup-shared array `[n]T` named `name`. DECLARE IT AT
/// MODULE LEVEL (like the `g.bind(.field)` storage aliases) — calling it inside
/// a function makes Zig materialise the name as a runtime array that spv2wgsl
/// can't lower. Returns a pointer to the `var<workgroup>` the backend emits.
///     const tile = k.shared(f32, 256, "rot_tile");   // at module scope
/// Read it only inside an `if (k.is_gpu)` branch.
pub inline fn shared(
    comptime T: type,
    comptime n: usize,
    comptime name: []const u8,
) SharedPtr(T, n) {
    if (is_gpu) {
        return @extern(*addrspace(.shared) [n]T, .{ .name = name });
    }
    // CPU twin: a static backing array so the module-level const typechecks.
    // Never read on the CPU side (the global-memory path is used there).
    const Holder = struct {
        var buf: [n]T = undefined;
    };
    return &Holder.buf;
}

noinline fn zworkgroupBarrier() void {}

/// Per-kernel-file configuration. `workgroup` is the threads-per-workgroup the
/// dispatch uses (v1 is 1D scalar; 2D/3D arrays come with the dimensional Ctx).
pub const Config = struct {
    max: u32,
    workgroup: u32 = 64,
};

/// The compute context handed to a kernel: `c.id` is this invocation's global
/// index, `c.params` is the kernel's `Params` by value. Buffers are NOT in here —
/// reach them through the module-level `b` alias (`b.field[c.id]`).
pub fn Ctx(comptime Module: type) type {
    return struct {
        id: u32,
        params: Module.Params,
    };
}

/// Workgroup barrier: every thread in the group waits here, so shared-memory
/// writes issued before the barrier are visible to reads after it. On the GPU
/// this lowers (via spv2wgsl) to WGSL `workgroupBarrier()`; on the CPU it is a
/// no-op (the global-memory path needs no barrier).
///
/// ⚠️ UNIFORM CONTROL FLOW (hard WGSL rule, learned the hard way): a barrier
/// must be executed by EVERY invocation in the workgroup. A data-dependent
/// early-return BEFORE the barrier makes it non-uniform — it compiles, but on
/// real drivers the barrier silently does not synchronise and shared reads
/// return zero. So NEVER write:
///     if (c.id >= count) return;   // ← some lanes exit
///     ...; k.workgroupBarrier();   // ← now non-uniform: BROKEN on device
/// Instead, dispatch an exact multiple of the workgroup size (so no lane is
/// out of range) and guard the per-lane WORK, not the barrier:
///     if (in_range) { tile[lid] = ...; }
///     k.workgroupBarrier();        // ← top-level, every lane reaches it
///     if (in_range) { out[gid] = tile[...]; }
/// (The `naga` WGSL validator — see `zig build wgsl-validate` — flags this as a
/// uniformity error, catching it without a device round-trip.)
pub inline fn workgroupBarrier() void {
    if (is_gpu) {
        zworkgroupBarrier();
    }
}
// Empty noinline helper: the body is never executed — it exists only to make
// Zig emit an `OpFunctionCall` that spv2wgsl rewrites into `workgroupBarrier()`
// and then deletes. Named with the `zworkgroupBarrier` stem spv2wgsl matches.

/// The element view a kernel sees for a `Buffers` field. Zig 1245 bans
/// `@Vector` fields inside `extern struct`s on CPU targets, so vector buffers
/// are DECLARED as `[N][M]f32` (extern-legal, guaranteed layout, `align(M*4)`
/// so the stride matches std430). A kernel wants the ergonomic `@Vector(M,f32)`
/// element, so `bind` re-presents `[N][M]f32` as `[N]@Vector(M,f32)` — the two
/// are byte-identical, and the `align(M*4)` on the field satisfies the vector's
/// alignment. Non-`[M]f32` fields (scalar arrays like `[N]u32`) pass through
/// unchanged.
fn BoundView(comptime FieldT: type) type {
    const info: std.builtin.Type = @typeInfo(FieldT);
    if (info != .array) {
        return FieldT;
    }
    const outer: std.builtin.Type.Array = info.array;
    const inner: std.builtin.Type = @typeInfo(outer.child);
    if (inner == .array and inner.array.child == f32 and
        (inner.array.len == 2 or inner.array.len == 4))
    {
        return [outer.len]@Vector(inner.array.len, f32);
    }
    return FieldT;
}

/// True when `FieldT` is a `[N][M]f32` vector buffer that `BoundView` reshapes.
fn isVecBuffer(comptime FieldT: type) bool {
    return BoundView(FieldT) != FieldT;
}

/// The module-level globals namespace. On GPU the buffers are an `extern` storage
/// binding and the params an `extern` uniform; on CPU both are plain `var`s the
/// host points at heap storage. A kernel file does
/// `pub const g = k.Globals(@This()); const b = &g.B;`.
pub fn Globals(comptime Module: type) type {
    return if (is_gpu) struct {
        pub extern const P: Module.Params addrspace(.uniform);

        /// One storage BINDING PER BUFFERS FIELD (t1178): the single
        /// megastruct binding (`extern var B: Buffers`) corrupted on Adreno
        /// above ~1000 invocations — large constant field offsets in one
        /// binding mis-addressed cross-field. Separate runtime-sized
        /// bindings (the shape every hand-written WebGPU demo uses) are
        /// stable on the same device. A kernel file aliases once per field:
        ///     const pos = g.bind(.pos);
        ///     ... pos[i] = ...;            // ptr-to-array indexes directly
        /// Binding NUMBERS are read back from the generated WGSL by the
        /// host (initGpu parses the headers), so no ordering contract is
        /// needed between this code and the SPIR-V backend.
        pub fn bind(
            comptime field: meta.FieldEnum(Module.Buffers),
        ) *addrspace(.storage_buffer) BoundView(@FieldType(Module.Buffers, @tagName(field))) {
            const FieldT = @FieldType(Module.Buffers, @tagName(field));
            // `[N][M]f32` storage is byte-identical to `[N]@Vector(M,f32)`, but a
            // storage-address-space pointer cast between the two is rejected by the
            // compiler. Declare the extern symbol AS the view type directly — same
            // symbol, same bytes — so no cast is needed. Scalar fields have
            // BoundView == FieldT, so this is unchanged for them.
            //
            // The BINDING must be a single-item pointer to a STRUCT — that is the
            // SPIR-V block shape a storage buffer takes, and the compiler rejects a
            // pointer straight at the array. Wrap the view in a one-field block and
            // hand back a pointer to that field: same symbol, same bytes, and a
            // kernel still writes `pos[i]` with no `.items` in sight.
            const Block = extern struct { items: BoundView(FieldT) };
            const block: *addrspace(.storage_buffer) Block = @extern(
                *addrspace(.storage_buffer) Block,
                .{ .name = "kbuf_" ++ @tagName(field) },
            );
            return &block.items;
        }

        // ===== ZNUM-UPSTREAM(lean-path): read the Params uniform via a module alias =====
        // The mirror of `bind`, but for the single `Params` uniform instead of a storage buffer.
        // A lean kernel file aliases it once at module scope:
        //     const P = g.uniform();
        //     ... if (id >= P.count) return; ...   // reads lower to uniform loads
        // Returning the uniform POINTER (instead of copying Params into a per-dispatch `Ctx`, as
        // `installKernel` does) is what lets `installKernelLean` emit half-size, dead-branch-free
        // WGSL. Same symbol `P` the stock path uses.
        pub fn uniform() Uniform(Module) {
            return @extern(*addrspace(.uniform) Module.Params, .{ .name = "P" });
        }
        // ===== END ZNUM-UPSTREAM(lean-path) =====
    } else struct {
        pub var B: Module.Buffers = undefined;
        pub var P: Module.Params = undefined;

        /// CPU twin of the per-field binding: a pointer into the module's
        /// plain `B` storage, so `pos[i]` indexes identically on both sides.
        /// Vector buffers are stored as `[N][M]f32` (extern-safe on 1245) and
        /// re-presented as `[N]@Vector(M,f32)` — same bytes, see `BoundView`.
        pub fn bind(
            comptime field: meta.FieldEnum(Module.Buffers),
        ) *BoundView(@FieldType(Module.Buffers, @tagName(field))) {
            const FieldT = @FieldType(Module.Buffers, @tagName(field));
            const ptr = &@field(B, @tagName(field));
            if (comptime isVecBuffer(FieldT)) {
                return @ptrCast(@alignCast(ptr));
            }
            return ptr;
        }

        // ===== ZNUM-UPSTREAM(lean-path): CPU twin of uniform() =====
        // On the CPU build there is no uniform address space; the host fills the module's plain
        // `P` before running the kernel loop, and the kernel reads it through this pointer. One
        // source, both backends — the same trick `bind` plays for the buffers.
        pub fn uniform() Uniform(Module) {
            return &P;
        }
        // ===== END ZNUM-UPSTREAM(lean-path) =====
    };
}

// ===== ZNUM-UPSTREAM(lean-path): the "lean" kernel form =====
// Merged from znum's delta ledger (`shaders/vendor/zimr/PROVENANCE.md`, recorded `offered`).
// Kept under its original markers so a re-sync can grep for it.
//
// WHY THIS EXISTS. The stock `installKernel` below builds a `Ctx` and copies `Params`
// field-by-field out of the uniform on every dispatch. That copy is CORRECT — see the long note
// in `installKernel` for the `OpCopyLogical` bug it avoids — but Zig's SPIR-V backend wraps it in
// a merge ladder of comptime-dead guard branches (`if (31u == 31u) { ... }`), so the emitted WGSL
// comes out about twice the size the kernel body warrants.
//
// The LEAN form reads the uniform DIRECTLY through a module-level alias (`const P = g.uniform();`),
// exactly the way buffers are read via `g.bind`. No Ctx, no field-by-field copy, no dead ladder.
// A lean kernel therefore takes a plain `id: u32` rather than a `Ctx`.
//
// PURELY ADDITIVE: `installKernel` and `Ctx` are untouched, so every existing zimr kernel is
// unaffected and can migrate one at a time.

/// The type `g.uniform()` returns: a pointer to the kernel's `Params`.
///   - GPU build: a pointer into the `uniform` address space — the shader's
///     `@group(0) @binding(0) var<uniform> P`. Reads become uniform loads.
///   - CPU build: a plain pointer into the module's `Globals.P`, which the host fills before
///     running the kernel loop. Reads become normal field reads.
/// One declaration, both backends — the essence of kompute's one-source model.
pub fn Uniform(comptime Module: type) type {
    return if (is_gpu)
        *addrspace(.uniform) Module.Params
    else
        *Module.Params;
}

/// The lean twin of `installKernel`: generate the SPIR-V compute entry for kernel `name`, but
/// invoke it as `Module.<name>(id)` with the raw thread index instead of constructing and passing
/// a `Ctx`. The kernel reads its parameters through the module-level `g.uniform()` alias, so NO
/// per-dispatch param copy is emitted — that is the whole point (see the block above).
///
/// A no-op on the CPU target: there a kernel is just a Zig function the host calls in a loop, so
/// there is nothing to export. Call once per kernel from the file's `comptime {}` block.
pub fn installKernelLean(comptime Module: type, comptime name: []const u8) void {
    // Off the GPU target there is no compute entry point to export; the host drives the CPU loop
    // itself. So compiling for the native/wasm host, this function does nothing.
    if (!is_gpu) {
        return;
    }

    // The workgroup size is fixed per kernel file by `config.workgroup`, and it is the single
    // source of truth: it is baked into the SPIR-V `LocalSize`, and spv2wgsl reads that back to
    // emit `@workgroup_size(N, 1, 1)`. Neither the build script nor the host repeats the number.
    const workgroup_x: u32 = Module.config.workgroup;

    // The exported entry point. WebGPU dispatches this once per thread; it reads the built-in
    // global invocation id, takes lane 0's component (the flat 1-D thread index), and hands it to
    // the kernel body. One `Entry` is generated per kernel `name`.
    const Entry = struct {
        fn run() callconv(.{ .spirv_kernel = .{ .x = workgroup_x, .y = 1, .z = 1 } }) void {
            // Compute kernels do not want implicit bounds-check traps; the kernel body guards its
            // own index (`if (id >= P.count) return;`).
            @setRuntimeSafety(false);

            const thread_id: u32 = gpu.global_invocation_id[0];
            @field(Module, name)(thread_id);
        }
    };

    // Export under exactly `name`, so the host selects this entry with
    // `createComputePipeline(module, name)` and spv2wgsl picks it via `--entry=<name>`.
    @export(&Entry.run, .{ .name = name });
}
// ===== END ZNUM-UPSTREAM(lean-path) =====

/// Generate the SPIR-V compute entry point for kernel `name` in `Module`. Reads
/// `global_invocation_id`, builds a `Ctx` (params by value from the uniform), and
/// calls `Module.<name>(ctx)`. The exported symbol is `name`, so the host selects
/// it with `createComputePipeline(module, name)`. A no-op on the CPU target.
/// Call once per kernel from the file's `comptime {}` block.
pub fn installKernel(comptime Module: type, comptime name: []const u8) void {
    if (!is_gpu) {
        return;
    }
    // `config.workgroup` is the single source of truth for the workgroup size:
    // emit it as the entry's SPIR-V `OpExecutionMode LocalSize` so spv2wgsl reads
    // the WGSL `@workgroup_size` straight off the compiled module. No build-side
    // `--workgroup` flag, no duplicated literal in build.zig.
    const wg_x: u32 = Module.config.workgroup;
    const Entry = struct {
        fn run() callconv(.{ .spirv_kernel = .{ .x = wg_x, .y = 1, .z = 1 } }) void {
            @setRuntimeSafety(false);

            // FIELD BY FIELD, never `.params = Module.g.P`.
            //
            // `P` lives in the UNIFORM address space, where SPIR-V decorates its struct
            // as a Block with explicit member Offsets. `Ctx.params` is a function-local,
            // with no such decorations. Writing `.params = Module.g.P` asks for a
            // whole-struct copy BETWEEN THOSE TWO LAYOUTS — an OpCopyLogical — and it
            // silently dropped a member: `n_cols` (field 15 of 20) arrived as 0 on device
            // while its neighbour `n_rows` (field 16) arrived correctly, so the uniform
            // buffer was right and the COPY was wrong. It cost a fluid sim that computed
            // a 5704-cell grid with n_cols = 0, collapsed every particle onto one cell,
            // and rendered a black screen.
            //
            // Reading each member instead emits an OpAccessChain + OpLoad at a known
            // offset — no cross-layout struct copy exists to get wrong. Scalars only, so
            // it is the same number of loads the kernel would have done anyway.
            // Iterate FIELD ENUM VALUES, not the `field_names` slice: iterating the
            // slice-of-slices makes the SPIR-V backend materialise every field NAME as
            // data (`array<u32,6>` = "count"+nul), and spv2wgsl cannot lower the
            // initialiser functions Zig emits for them. Enum values are plain integers.
            const FE = meta.FieldEnum(Module.Params);
            var params: Module.Params = undefined;
            inline for (comptime std.enums.values(FE)) |fe| {
                @field(params, @tagName(fe)) = @field(Module.g.P, @tagName(fe));
            }

            const c: Ctx(Module) = .{
                .id = gpu.global_invocation_id[0],
                .params = params,
            };
            @field(Module, name)(c);
        }
    };
    @export(&Entry.run, .{ .name = name });
}

/// Install EVERY kernel the module lists in its `pub const kernels` — the
/// one-call form of `installKernel`. A kernel file names its entries once:
///
///     pub const kernels = [_][:0]const u8{ "clearGrid", "countGrid", "scatter" };
///     comptime { k.installKernels(@This()); }
///
/// instead of repeating `installKernel(@This(), "clearGrid")` per kernel. The
/// host's `Compute(M).initGpu` reads the SAME `M.kernels` to build its
/// per-kernel WGSL array (`@embedFile(name ++ "_wgsl")` in a comptime loop), so
/// this one list is the single source of truth for "what kernels exist". The
/// payoff: a name in `kernels` that the build pipeline didn't generate WGSL for
/// is a missing-`@embedFile` *compile error*, not a silent runtime "kernel not
/// registered" (the old failure mode when the hand-kept host list drifted from
/// the `installKernel` calls). A no-op on the CPU target — there a kernel is
/// just a Zig fn the host calls in a loop, nothing to export.
pub fn installKernels(comptime Module: type) void {
    if (!is_gpu) {
        return;
    }
    inline for (Module.kernels) |name| {
        installKernel(Module, name);
    }
}
