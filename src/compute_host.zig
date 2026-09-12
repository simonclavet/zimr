//! compute_host.zig — `z.Compute(M)`: run a kompute kernel module `M` on the CPU
//! (a plain `for id` loop calling the kernel) OR the GPU (a WGSL compute dispatch),
//! chosen at runtime via `.backend`. Same kernel source, same results.
//!
//! The footgun this erases: buffer + bind-layout sizes come from
//! `@sizeOf(M.Buffers)` / `@sizeOf(M.Params)` (comptime, off the schema) — never
//! hand-sized. A single storage buffer holds the whole `Buffers` struct; per-field
//! upload/read use `@offsetOf`. See `src/notes/tutorials/gpu-compute-tutorial.md`.
//!
//!     const M = @import("double_it.zig");      // schema + CPU kernel
//!     var pipe = Compute(M).initCpu();          // or initGpu(gpa, dev, queue, kernels)
//!     pipe.element_count = n;                    // for readback slicing; set once
//!     pipe.upload(.data, input);
//!     pipe.params = .{ .count = n };             // the kernel's own Params.count
//!     pipe.run("double", n);                     // CPU loop or GPU dispatch over n
//!     const out = pipe.readLatest(.data);        // CPU: the slice; GPU: frame-delayed
const std = @import("std");
const gpu = @import("gpu.zig");
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqualSlices = std.testing.expectEqualSlices;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const wgpu = @import("wgpu.zig");
const compute_pass = wgpu.compute_pass;
const shader_introspect = @import("shader_introspect.zig");
const jobs = @import("jobs.zig");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;

/// Where a kompute kernel runs. The SAME kernel source, on any of them.
///
///   .cpu    — a plain `for id` loop, right here. Synchronous; the answer is in `M.g.B`
///             the moment `run` returns. It also BLOCKS the frame for as long as it takes.
///
///   .worker — the SAME plain `for id` loop, in a Web Worker. Not faster; ELSEWHERE.
///             This exists so a device with no GPU gets a compute fallback that does not
///             freeze the frame — which is the whole point of `zimr.jobs`, applied to
///             kompute. It is asynchronous, so `readLatest` returns null until the job
///             lands, exactly as the GPU arm already does.
///
///   .gpu     — a WGSL compute dispatch. Asynchronous, ~1 frame of readback latency.
///
/// The three are interchangeable in CODE, not in COST. Read `.worker`'s doc on `run`
/// before reaching for it: it copies the entire `Buffers` to the worker and back on every
/// dispatch, and it runs ONE job at a time.
pub const Backend = enum { cpu, worker, gpu };

/// The header a kompute job carries to its worker: the dispatch count, and the kernel's
/// params by value.
///
/// `extern` because these bytes are memcpy'd out of the app's wasm and into the kernel's
/// — two SEPARATE compilations — and Zig's auto layout is free to reorder fields.
/// (`M.Params` is already extern: the GPU needs it for the std140 uniform.)
pub fn JobHeader(comptime M: type) type {
    return extern struct {
        n: u32,
        params: M.Params,
    };
}

fn JobKernelFn(comptime M: type) type {
    return fn (Allocator, JobHeader(M), []const u8, *std.Io.Writer) anyerror!void;
}

/// Turn a kompute kernel into a JOB kernel — the adapter that makes `.worker` cost an
/// adapter rather than a rewrite.
///
/// Look at the loop: it is byte-for-byte the `.cpu` arm of `run` below. The only
/// difference is WHERE it executes. It works because a worker instantiates its own copy
/// of the kernel wasm, so `M.g.B` in there is that worker's private memory — the module
/// globals kompute uses on the CPU are exactly what a worker needs, for free.
pub fn komputeKernel(comptime M: type, comptime name: []const u8) JobKernelFn(M) {
    return struct {
        fn run(
            gpa: Allocator,
            hdr: JobHeader(M),
            payload: []const u8,
            out: *std.Io.Writer,
        ) anyerror!void {
            if (payload.len != @sizeOf(M.Buffers)) {
                return error.MalformedJob;
            }

            // SNAPSHOT AND RESTORE the module globals around the run.
            //
            // In a real worker this is nearly pointless: `M.g.B` there is that worker's
            // own private memory and nobody can observe it. But when there is no worker
            // pool — the host, or a sandboxed iframe that refused `new Worker()` —
            // `zimr.jobs` runs this kernel INLINE, in the APP's address space, where
            // `M.g.B` is the app's own globals. Without the restore, a `.worker` dispatch
            // would silently trample them, and the backend would behave one way in Chrome
            // and another in an iframe. A bug that only appears where you cannot attach a
            // debugger is the worst kind there is, so pay two memcpys and have neither.
            //
            // Heap, via the job's arena — never `const saved = M.g.B`, which would put a
            // possibly-megabyte struct on the wasm shadow stack.
            const saved: *M.Buffers = try gpa.create(M.Buffers);
            @memcpy(std.mem.asBytes(saved), std.mem.asBytes(&M.g.B));
            defer @memcpy(std.mem.asBytes(&M.g.B), std.mem.asBytes(saved));

            @memcpy(std.mem.asBytes(&M.g.B), payload);
            M.g.P = hdr.params;

            // The second call site that had to learn the lean dialect. Same discriminator as the
            // in-process runner below: a lean kernel takes the raw index, a stock one a `Ctx`.
            const takes_raw_id: bool = @TypeOf(@field(M, name)) == fn (u32) void;
            var id: u32 = 0;
            while (id < hdr.n) : (id += 1) {
                if (takes_raw_id) {
                    @field(M, name)(id);
                } else {
                    @field(M, name)(.{ .id = id, .params = hdr.params });
                }
            }

            try out.writeAll(std.mem.asBytes(&M.g.B));
        }
    }.run;
}

/// One job kernel per name in `M.kernels`, as a table `jobs.Registry` can take.
///
/// NOTE — this is an ARRAY, and that limits composition. A page carries ONE kernel wasm, so
/// the launcher's would have to be built from the CONCATENATED tables of every example on it:
///
///     jobs.Registry(worker_png.job_kernels ++ four_ways.job_kernels, .{ ... })
///
/// `++` on two arrays needs a common element type, and these have none: every kernel carries
/// its own header type in its signature (`Size` there, `JobHeader(M)` here). Tuples would
/// concatenate, but this Zig (0.17.0-dev.1282) has no `@Type` and no `std.meta.Tuple`, and
/// `@Struct` with numeric field names yields a struct that does not support indexing. So the
/// composition SIMPLIFICATION the review claimed is not available today, and the launcher
/// ships without a kernel wasm — its jobs run inline, which is correct but hitchy.
///
/// The name-keyed exports still make the merge the RIGHT design (a merged wasm exports a
/// superset of the names; nobody renumbers anything). Only the Zig to express it is missing.
pub fn komputeTable(comptime M: type) [M.kernels.len]struct { []const u8, JobKernelFn(M) } {
    var table: [M.kernels.len]struct { []const u8, JobKernelFn(M) } = undefined;
    for (M.kernels, 0..) |kernel_name, i| {
        table[i] = .{ kernel_name, komputeKernel(M, kernel_name) };
    }
    return table;
}

/// The job registry for a kompute module — DERIVED, so an example that wants the
/// `.worker` backend configures nothing.
///
/// The bounds are exact rather than guessed: a job carries the header plus the whole
/// `Buffers` image, and returns the `Buffers` image.
///
/// The example's `kernels.zig` is then two lines, and build.zig's generated kernel root
/// needs no special case:
///
///     pub const registry = zimr.compute.komputeRegistry(@import("add_kernel.zig"));
pub fn komputeRegistry(comptime M: type) type {
    return jobs.Registry(komputeTable(M), .{
        .max_input = @sizeOf(JobHeader(M)) + @sizeOf(M.Buffers),
        .max_output = @sizeOf(M.Buffers),
    });
}

/// WebGPU's guaranteed floor for `maxStorageBuffersPerShaderStage`: every
/// conformant device grants at least this many storage buffers to a compute
/// stage (it's the spec default limit). A kernel that binds more than this may
/// run on a beefy desktop GPU but will fail to create its pipeline on a stock
/// device — so the per-kernel bind groups assert each kernel stays within it.
/// This is what lets us delete the old `maxStorageBuffersPerShaderStage` raise:
/// instead of asking the device for more, we make each kernel need fewer.
const max_portable_storage_buffers: u32 = 8;

/// A binding a kernel's WGSL declares: its number and declared variable name.
const WgslBinding = struct { num: u32, name: []const u8 };

fn isWgslIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_';
}

/// Does `name` appear as a WHOLE word in `line`? (So `kbuf_pos` does not match
/// inside `kbuf_pos2`, and `arr` does not match inside `narrow`.)
fn wgslRefsName(line: []const u8, name: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, name)) |pos| {
        const before_ok: bool = pos == 0 or !isWgslIdentChar(line[pos - 1]);
        const after_i: usize = pos + name.len;
        const after_ok: bool = after_i >= line.len or !isWgslIdentChar(line[after_i]);
        if (before_ok and after_ok) {
            return true;
        }
        start = pos + 1;
    }
    return false;
}

/// The variable name in a `... var<...> NAME: TYPE;` binding decl — the
/// identifier immediately before the first `:`. Name-agnostic on purpose: it
/// returns whatever the decl actually says (`kbuf_grid_counts`, `arr`, `P`),
/// so the cross-check below cannot be fooled by a buffer that lost its
/// `kbuf_<field>` name (exactly the 0.17-dev.956 atomic-buffer regression).
fn wgslDeclName(line: []const u8) ?[]const u8 {
    const colon: usize = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var end: usize = colon;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
    var begin: usize = end;
    while (begin > 0 and isWgslIdentChar(line[begin - 1])) : (begin -= 1) {}
    if (begin == end) {
        return null;
    }
    return line[begin..end];
}

/// Independent host<->WGSL binding cross-check. Returns the first binding the
/// kernel's WGSL DECLARES and REFERENCES in its body whose number is NOT in
/// `bound` (the binding numbers the host actually put in the layout), or null
/// when the layout covers every used binding.
///
/// This is deliberately NOT the `kbuf_<field>` usage scan that builds the
/// layout — it keys on each binding's declared var name and matches by binding
/// NUMBER, so a disagreement between the two is precisely the host<->WGSL drift
/// that otherwise surfaces only as Dawn's opaque "Binding doesn't exist"
/// cascade at pipeline creation. Catching it here names the kernel + binding.
fn unboundUsedBinding(wgsl: []const u8, bound: []const u32) ?WgslBinding {
    const tag: []const u8 = "@binding(";
    var it = std.mem.splitScalar(u8, wgsl, '\n');
    while (it.next()) |line| {
        const bpos: usize = std.mem.indexOf(u8, line, tag) orelse continue;
        const after: []const u8 = line[bpos + tag.len ..];
        const close: usize = std.mem.indexOfScalar(u8, after, ')') orelse continue;
        const num: u32 = std.fmt.parseInt(u32, after[0..close], 10) catch continue;
        const name: []const u8 = wgslDeclName(line) orelse continue;
        // Used = its declared name appears on some line that is NOT itself a
        // binding declaration (every kernel declares ALL bindings at module
        // scope; only the body lines are real uses).
        var used: bool = false;
        var bit = std.mem.splitScalar(u8, wgsl, '\n');
        while (bit.next()) |bline| {
            if (std.mem.indexOf(u8, bline, tag) != null) {
                continue;
            }
            if (wgslRefsName(bline, name)) {
                used = true;
                break;
            }
        }
        if (!used) {
            continue;
        }
        var covered: bool = false;
        for (bound) |b| {
            if (b == num) {
                covered = true;
                break;
            }
        }
        if (!covered) {
            return .{ .num = num, .name = name };
        }
    }
    return null;
}

pub fn Compute(comptime M: type) type {
    comptime {
        if (!@hasDecl(M, "config")) {
            @compileError("Compute(M): M needs a `config` (kompute.Config)");
        }
        if (!@hasDecl(M, "Buffers") or !@hasDecl(M, "Params") or !@hasDecl(M, "g")) {
            @compileError("Compute(M): M needs `Buffers`, `Params`, and `g = kompute.Globals(@This())`");
        }
        // A WGSL uniform block is std140-laid-out: its size is rounded up to a
        // multiple of 16 bytes on the GPU. If the host's Params isn't already a
        // multiple of 16, the host and shader disagree on the struct's size and
        // every field past the mismatch reads garbage on-device — a miserable,
        // silent bug. Catch it at build time and say exactly how to fix it.
        if (@sizeOf(M.Params) % 16 != 0) {
            @compileError(std.fmt.comptimePrint(
                "Compute(M): @sizeOf({s}.Params) == {d}, which is not a multiple of 16. " ++
                    "WGSL uniform blocks are std140-aligned (16 bytes), so a non-16 Params " ++
                    "silently mismatches the GPU and you read garbage. Pad it to a multiple " ++
                    "of 16 with a trailing `_pad: [N]u32 = .{{...}}` field.",
                .{ @typeName(M), @sizeOf(M.Params) },
            ));
        }
    }

    return struct {
        const Self = @This();
        const Buffers = M.Buffers;
        const Params = M.Params;
        const Field = meta.FieldEnum(Buffers);

        backend: Backend = .cpu,
        params: Params = undefined,
        /// Element count for slicing variable-length fields on READBACK (e.g.
        /// `num_particles`). Set once after init. This is no longer the dispatch
        /// width — that's the explicit `n` in `run(name, n)`. readLatest clamps to
        /// `@min(element_count, field.len)`, so fixed-size fields (grid_counts,
        /// cell_start) still slice to their own length, not the particle count.
        element_count: u32 = 0,
        gpu: ?Gpu = null,
        worker: ?Worker = null,

        /// The `.worker` backend's state — deliberately the same shape as `Gpu`'s.
        ///
        /// The MIRROR is the important part, and it is the reason a `.cpu` pipe and a
        /// `.worker` pipe do not stomp each other. `M.g.B` is a module-level SINGLETON
        /// (kompute declares `pub var B: Buffers`), so if the worker's result landed
        /// there it would overwrite whatever the CPU backend had just computed. The GPU
        /// arm already solved this by reading back into a heap mirror; the worker does
        /// exactly the same, and inherits the same independence.
        const Worker = struct {
            gpa: Allocator,
            /// One job at a time. Two in flight would both write into `mirror`, and the
            /// loser's result would be silently discarded.
            job: jobs.Job = .{},
            mirror: *Buffers,
            have_read: bool = false,
        };

        const Gpu = struct {
            gpa: Allocator,
            dev: wgpu.DeviceHandle,
            queue: wgpu.QueueHandle,
            field_bufs: [field_count]wgpu.BufferHandle,
            uniform: wgpu.BufferHandle,
            staging: wgpu.BufferHandle,
            /// One compute pipeline per installed kernel, parallel to
            /// `kernel_names`. Heap-sized to the kernel count, so there is no
            /// fixed cap to overflow — the old fixed array's overflow assert
            /// could constant-fold to a trap and DCE this whole registry in
            /// ReleaseSmall (the shaders silently vanished); that footgun is gone.
            pipelines: []wgpu.ComputePipelineHandle,
            kernel_names: [][]const u8,
            /// One bind group PER KERNEL, parallel to `pipelines`. Each binds
            /// only the fields its kernel uses (+ the uniform), so a kernel that
            /// touches one buffer doesn't drag in all ten — the change that keeps
            /// every kernel under the portable storage-buffer limit. `run` sets
            /// the bind group for the kernel it's dispatching (in a batch, that
            /// means per dispatch, since adjacent kernels differ).
            bind_groups: []wgpu.BindGroupHandle,
            /// Introspection metadata for `describe()` (a debug aid). The global
            /// binding number assigned to each Buffers field + the uniform, the
            /// per-kernel set of fields actually bound, and the last dispatch
            /// width each kernel ran at. Cheap to keep; only read by describe().
            bindings: [field_count]u32,
            uniform_binding: u32,
            kernel_used: [][field_count]bool,
            kernel_last_n: []u32,
            /// An open batch: while set, each `run` encodes its dispatch into this
            /// one compute pass instead of submitting a fresh encoder per call.
            /// WebGPU guarantees a storage write from dispatch N is visible to
            /// dispatch N+1 within a single pass, so this is equivalent to
            /// per-dispatch submits — it just collapses a frame's many submits
            /// into one.
            batch_enc: wgpu.CommandEncoderHandle = .invalid,
            batch_pass: wgpu.ComputePassEncoderHandle = .invalid,
            /// The Params recorded at `beginBatch`. `endBatch` asserts
            /// `self.params` still equals this — the uniform is written ONCE at
            /// beginBatch, so params changed afterward never reach the GPU; this
            /// catches that silent-stale trap by name.
            batch_params: Params = undefined,
            /// The Params value currently resident in `uniform`, or null if never
            /// written. Guards against re-uploading identical params: dependent
            /// kernels run as separate un-batched dispatches share one params
            /// value, and re-writing it each dispatch is a same-frame buffer
            /// clobber (queue timeline keeps only the last write). Deduping keeps
            /// a single write while preserving the per-dispatch submit barriers.
            uniform_synced: ?Params = null,
            read: wgpu.BufferRead = .invalid,
            have_read: bool = false,
            /// How many dispatches have been submitted, and how many are reflected in
            /// `mirror`. **The difference is what a caller needs and could not ask for.**
            ///
            /// `readLatest` polls: it returns `null` until a copy completes, then the mirror's
            /// contents. What it could never say is WHICH dispatch those contents came from -
            /// so a caller that dispatched row N and got data back had no way to know whether
            /// it was row N's or row N-1's still in flight.
            ///
            /// The zimrnum sweep worked around that with six fixed settle frames per row, a
            /// number that had already been wrong twice (three failed at 91 rows, and the
            /// symptom was another row's data arriving as `inf` against a zero bar). Six was
            /// chosen from the time budget rather than from a measurement, which the comment
            /// there says out loud.
            ///
            /// A counter replaces the guess. `readGeneration()` is the dispatch number the
            /// mirror holds; a caller compares it against its own and knows exactly when the
            /// data is its own - no waiting longer than necessary, and no reading too early.
            submitted: u64 = 0,
            mirrored: u64 = 0,
            /// The dispatch count at the moment the in-flight copy was encoded.
            copy_at: u64 = 0,
            /// Heap-allocated CPU readback buffer (the whole Buffers struct).
            /// Heap, NOT inline-by-value: Buffers can be megabytes (20k particles
            /// here ≈ 1.3 MB), and an inline field makes the whole Compute value
            /// that large — a by-value `initGpu` return then overflows the wasm
            /// shadow stack in debug (release elides the copy, so it only crashes
            /// in debug). Allocated in initGpu, freed in deinit.
            mirror: *Buffers,
        };

        fn ElemOf(comptime field: Field) type {
            return meta.Elem(meta.fieldInfo(Buffers, field).type);
        }

        /// CPU backend: zero GPU resources, instant. The kernel module's globals
        /// (`M.g.B` / `M.g.P`) ARE the storage — upload writes them, run loops.
        pub fn initCpu() Self {
            return .{ .backend = .cpu };
        }

        /// The same kernel, on a Web Worker: a compute fallback that does not freeze the
        /// frame. Needs an allocator (the GPU path does too) for the readback mirror and
        /// the job's payload.
        ///
        /// Where workers are unavailable — on the host, or in a sandboxed iframe that
        /// refuses `new Worker()` — `zimr.jobs` runs the kernel INLINE instead, so this
        /// backend still produces the right answer everywhere. It just blocks, exactly as
        /// `.cpu` would have.
        pub fn initWorker(gpa: Allocator) !Self {
            comptime {
                if (!@hasDecl(M, "kernels")) {
                    @compileError("Compute(" ++ @typeName(M) ++ ").initWorker: the .worker backend needs\n" ++
                        "    pub const kernels = [_][:0]const u8{ \"yourKernel\", ... };\n" ++
                        "on the module — the names it may run off-thread, so the kernel wasm knows what\n" ++
                        "to export. A lone `installKernel(\"name\")` is not introspectable (this Zig's\n" ++
                        "@typeInfo has no .decls), so the list has to be written down. Declare it and\n" ++
                        "swap `installKernel` for `installKernels(@This())`, which reads the same list.");
                }
            }
            // The mirror is this pipe's ENTIRE state: `upload` stages into it, `run` ships
            // it, `readLatest` reads the answer back into it. Zeroed so a field nobody
            // uploaded is deterministically 0 rather than whatever `create` handed back.
            const mirror: *Buffers = try gpa.create(Buffers);
            @memset(std.mem.asBytes(mirror), 0);
            return .{
                .backend = .worker,
                .worker = .{ .gpa = gpa, .mirror = mirror },
            };
        }

        /// Free the GPU-backed kernel registry (the heap-sized pipeline + name
        /// slices). The other GPU resources live for the program's lifetime, as
        /// before. No-op on the CPU backend.
        pub fn deinit(self: *Self) void {
            if (self.worker) |*wk| {
                wk.job.deinit(); // cancels it host-side too, if still in flight
                wk.gpa.destroy(wk.mirror);
                self.worker = null;
            }
            if (self.gpu) |*gp| {
                // GPU resources: one pipeline + one bind group per kernel, the
                // per-field storage buffers, and the uniform + staging buffers.
                for (gp.pipelines) |pl| {
                    if (pl != .invalid) {
                        wgpu.destroyComputePipeline(pl);
                    }
                }
                for (gp.bind_groups) |bg| {
                    if (bg != .invalid) {
                        wgpu.destroyBindGroup(bg);
                    }
                }
                for (gp.field_bufs) |b| {
                    if (b != .invalid) {
                        wgpu.destroyBuffer(b);
                    }
                }
                if (gp.uniform != .invalid) {
                    wgpu.destroyBuffer(gp.uniform);
                }
                if (gp.staging != .invalid) {
                    wgpu.destroyBuffer(gp.staging);
                }
                gp.gpa.free(gp.pipelines);
                gp.gpa.free(gp.kernel_names);
                gp.gpa.free(gp.bind_groups);
                gp.gpa.free(gp.kernel_used);
                gp.gpa.free(gp.kernel_last_n);
                gp.gpa.destroy(gp.mirror);
            }
        }

        /// The GPU storage buffer holding the whole `Buffers` struct, for zero-copy
        /// rendering (e.g. `z.drawPointsFromBuffer` reads a field by instance_index).
        /// null on the CPU backend. Field `f`'s data starts at `@offsetOf(Buffers, f)`.
        pub fn storageBuffer(self: *const Self) ?wgpu.BufferHandle {
            return if (self.gpu) |gp| gp.field_bufs[0] else null;
        }

        /// GPU backend: one storage buffer for the whole `Buffers` struct + a Params
        /// uniform + a MAP_READ staging buffer (sizes from `@sizeOf`), a bind group
        /// (uniform\@0, storage\@1, matching spv2wgsl's declaration order), and a
        /// compute pipeline from `wgsl` entry `kernel_name`.
        /// One kernel of a multi-kernel pipe: its entry name (matching the
        /// module's `installKernel` export) and its standalone WGSL module
        /// (the build pipeline translates the kompute module once per entry
        /// via spv2wgsl --entry).
        pub const KernelWgsl = struct {
            name: [:0]const u8,
            wgsl: []const u8,
        };

        pub fn initGpu(
            gpa: Allocator,
            dev: wgpu.DeviceHandle,
            queue: wgpu.QueueHandle,
            kernels: []const KernelWgsl,
        ) !Self {
            assertf(kernels.len >= 1, @src(), "initGpu: need at least one kernel, got {d}", .{kernels.len});

            // WEBGPU'S STORAGE-BUFFER CEILING. `maxStorageBuffersPerShaderStage` has a
            // GUARANTEED FLOOR OF 8, and one binding is used by the uniform, so a kompute
            // module gets at most 8 storage buffers — one per `Buffers` field.
            //
            // Go over it and NOTHING COMPLAINS. No validation error, no console warning: the
            // bindings past the limit simply do not take, and every write a kernel makes to
            // them is silently discarded. The kernel still runs, still reads its other
            // buffers correctly, still produces a plausible-looking result.
            //
            // It cost a very long hunt. `fluid_sort` declares TEN buffers (pos, prev, vel,
            // delta, density, grid_counts, cell_start, pos2, vel2, prev2) while its twin
            // `fluid_gpu` declares exactly EIGHT — so one fluid worked and the other filled
            // its box, with identical physics, identical parameters, and every kernel
            // reading correctly in isolation. The counting sort, the neighbour walk and the
            // density arithmetic all verified BIT-EXACT on device against brute force, and
            // the same source ran perfectly through the CPU backend (which has no such
            // limit). The buffers were simply not all there.
            //
            // A silent wrong answer is the worst failure mode a GPU API has. Trade it for a
            // loud one at init, naming the module and the count.
            comptime {
                if (field_count > 8) {
                    @compileError(std.fmt.comptimePrint(
                        "kompute module '" ++ @typeName(M) ++ "' declares {d} Buffers fields, " ++
                            "but WebGPU guarantees only 8 storage buffers per shader stage.\n" ++
                            "  Bindings past the 8th SILENTLY DO NOT BIND: writes to them are discarded " ++
                            "with no error, and the kernel appears to run fine while computing garbage.\n" ++
                            "  Pack fields together (e.g. one `[3*N]Vec2` scratch buffer instead of three " ++
                            "`[N]Vec2` ones), or reuse a buffer whose live range does not overlap.",
                        .{field_count},
                    ));
                }
            }
            assertf(@sizeOf(Buffers) > 0, @src(), "initGpu: Buffers has zero size", .{});
            const buf_bytes: u32 = @sizeOf(Buffers);
            // Per-field storage buffers (t1178): one buffer + one binding per
            // Buffers field — the megastruct single-binding shape corrupted
            // on Adreno. Binding numbers come from the kernels' own WGSL
            // headers (parsed below), so host and shader agree by definition.
            var field_bufs: [field_count]wgpu.BufferHandle = undefined;
            inline for (buffer_field_names, 0..) |fname, fi| {
                field_bufs[fi] = wgpu.createBuffer(dev, .{
                    .size = @sizeOf(@FieldType(Buffers, fname)),
                    .usage = .{ .storage = true, .copy_src = true, .copy_dst = true },
                    .label = "kbuf_" ++ fname,
                });
            }
            var bindings: [field_count]u32 = undefined;
            var uniform_binding: u32 = 0;
            try parseBindings(kernels, &bindings, &uniform_binding);
            const uniform: wgpu.BufferHandle = wgpu.createBuffer(dev, .{
                .size = @sizeOf(Params),
                .usage = .{ .uniform = true, .copy_dst = true },
                .label = "kompute_params",
            });
            const staging: wgpu.BufferHandle = wgpu.createBuffer(dev, .{
                .size = buf_bytes,
                .usage = .{ .map_read = true, .copy_dst = true },
                .label = "kompute_staging",
            });
            // ---- Per-kernel bind groups (the structural fix) ----
            // Each kernel binds ONLY the Buffers fields it actually uses (plus
            // the Params uniform), not the whole struct. Why this matters: a
            // stock WebGPU device guarantees only 8 storage buffers per shader
            // stage, but a pipeline like the sort declares 10 Buffers fields. The
            // old shared mega-bind-group bound all 10 to every kernel, so every
            // pipeline tripped the limit — which we papered over by RAISING the
            // device's `maxStorageBuffersPerShaderStage` (a band-aid that fails on
            // any device that won't grant the raise).
            //
            // Per the WebGPU spec a pipeline's explicit layout only needs the
            // bindings the entry STATICALLY USES; declared-but-unused module-scope
            // storage vars may be omitted. Each kernel's WGSL declares all fields
            // (the kompute module aliases them all at module scope) but its body
            // references only some, so `usedFields` parses the body and we bind
            // just that subset: clearGrid → {uniform, grid_counts} = 1 storage;
            // density → ~5; none over 8. Result: the sort runs on a stock device
            // with no limit-raising, and a kernel that WOULD exceed the budget
            // trips a named assert here instead of a silent pipeline failure.
            const pipelines: []wgpu.ComputePipelineHandle = try gpa.alloc(wgpu.ComputePipelineHandle, kernels.len);
            const kernel_names: [][]const u8 = try gpa.alloc([]const u8, kernels.len);
            const bind_groups: []wgpu.BindGroupHandle = try gpa.alloc(wgpu.BindGroupHandle, kernels.len);
            const kernel_used: [][field_count]bool = try gpa.alloc([field_count]bool, kernels.len);
            const kernel_last_n: []u32 = try gpa.alloc(u32, kernels.len);
            for (kernels, 0..) |k, i| {
                assertf(k.name.len > 0, @src(), "initGpu: kernel {d} has an empty name", .{i});
                assertf(
                    k.wgsl.len > 0,
                    @src(),
                    "initGpu: kernel '{s}' has empty WGSL (build/embed step failed?)",
                    .{k.name},
                );
                const used: [field_count]bool = usedFields(k.wgsl);
                // Build this kernel's layout + bind-group entries together: the
                // uniform first (always present — the Params block any kernel may
                // read), then one entry per USED field at its global binding
                // number. `n` is the dense count we actually fill; the binding
                // NUMBERS can be sparse (e.g. {0, 1, 5}) and WebGPU is fine with
                // that — we just don't emit slots for fields this kernel skips.
                var layout_entries: [field_count + 1]shader_introspect.BindGroupLayoutEntry = undefined;
                var bg_entries: [field_count + 1]gpu.BindGroupEntry = undefined;
                layout_entries[0] = .{
                    .binding = uniform_binding,
                    .visibility = .{ .compute = true },
                    .resource = .{ .uniform_buffer = .{ .min_size = @sizeOf(Params) } },
                };
                bg_entries[0] = .{ .binding = uniform_binding, .resource = .{ .buffer = .{ .handle = uniform } } };
                var n: usize = 1;
                var n_storage: u32 = 0;
                inline for (buffer_field_names, 0..) |fname, fi| {
                    if (used[fi]) {
                        layout_entries[n] = .{
                            .binding = bindings[fi],
                            .visibility = .{ .compute = true },
                            .resource = .{ .storage_buffer = .{
                                .read_only = false,
                                .min_size = @sizeOf(@FieldType(Buffers, fname)),
                            } },
                        };
                        bg_entries[n] = .{
                            .binding = bindings[fi],
                            .resource = .{ .buffer = .{ .handle = field_bufs[fi] } },
                        };
                        n += 1;
                        n_storage += 1;
                    }
                }
                // The whole point of per-kernel binding: keep each kernel within
                // the portable budget. A kernel over it won't bind on a stock
                // device, so flag it by name in dev (gone in ship).
                assertf(
                    n_storage <= max_portable_storage_buffers,
                    @src(),
                    "kernel '{s}' binds {d} storage buffers; portable limit is {d} (won't run on a stock device)",
                    .{ k.name, n_storage, max_portable_storage_buffers },
                );
                // Pre-flight host<->WGSL binding cross-check (init-only; gone in
                // ship). Independent of the `kbuf_<field>` usage scan that built
                // `layout_entries`: if the kernel's WGSL uses a binding the layout
                // omits, trap HERE naming the kernel + binding, instead of letting
                // Dawn raise its opaque "Binding doesn't exist" cascade at pipeline
                // creation. (This is the trap that would have pinned the atomic
                // grid buffer mis-named `arr` on 0.17-dev.956 in one line.)
                if (comptime zm.allow_assert) {
                    var bound_nums: [field_count + 1]u32 = undefined;
                    for (layout_entries[0..n], 0..) |e, ei| {
                        bound_nums[ei] = e.binding;
                    }
                    if (unboundUsedBinding(k.wgsl, bound_nums[0..n])) |miss| {
                        assertf(
                            false,
                            @src(),
                            "kernel '{s}': WGSL uses @binding({d}) '{s}' but the host bind-group " ++
                                "layout omits it — host<->WGSL binding drift (a buffer the usage scan " ++
                                "missed). This is the failure Dawn reports as \"Binding doesn't exist\".",
                            .{ k.name, miss.num, miss.name },
                        );
                    }
                }
                const bgl_blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(
                    gpa,
                    layout_entries[0..n],
                );
                defer gpa.free(bgl_blob);
                const bgl: wgpu.BindGroupLayoutHandle = wgpu.createBindGroupLayout(dev, bgl_blob, k.name);
                const pipeline_layout: wgpu.PipelineLayoutHandle = wgpu.createPipelineLayout(dev, &.{bgl}, k.name);
                const module: wgpu.ShaderModuleHandle = wgpu.createShaderModuleWgsl(dev, k.wgsl, k.name);
                assertf(module != .invalid, @src(), "kernel '{s}': WGSL module failed to compile", .{k.name});
                const pipeline: wgpu.ComputePipelineHandle = wgpu.createComputePipeline(
                    dev,
                    pipeline_layout,
                    module,
                    k.name,
                    k.name,
                );
                // A failed pipeline is stored as `.invalid` and would otherwise
                // only blow up later as a frozen device with no message; catch it
                // here, named, during development (stripped in ship builds).
                assertf(pipeline != .invalid, @src(), "kernel '{s}': compute pipeline failed to build", .{k.name});
                const bg_blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, bg_entries[0..n]);
                defer gpa.free(bg_blob);
                const bg: wgpu.BindGroupHandle = wgpu.createBindGroup(dev, bgl, bg_blob, k.name);
                pipelines[i] = pipeline;
                kernel_names[i] = k.name;
                bind_groups[i] = bg;
                kernel_used[i] = used;
                kernel_last_n[i] = 0;
                // Build-only: the pipeline + bind group are built, so their source
                // layout + module are no longer needed — release them per kernel.
                wgpu.destroyBindGroupLayout(bgl);
                wgpu.destroyPipelineLayout(pipeline_layout);
                wgpu.destroyShaderModule(module);
            }
            const mirror: *Buffers = try gpa.create(Buffers);
            return .{
                .backend = .gpu,
                .gpu = .{
                    .gpa = gpa,
                    .dev = dev,
                    .queue = queue,
                    .field_bufs = field_bufs,
                    .uniform = uniform,
                    .staging = staging,
                    .pipelines = pipelines,
                    .kernel_names = kernel_names,
                    .bind_groups = bind_groups,
                    .bindings = bindings,
                    .uniform_binding = uniform_binding,
                    .kernel_used = kernel_used,
                    .kernel_last_n = kernel_last_n,
                    .mirror = mirror,
                },
            };
        }

        /// Upload `data` into buffer `field`. CPU: memcpy into the module global.
        /// GPU: `queueWriteBuffer` at the field's `@offsetOf` in the storage buffer.
        /// The Buffers field names, in declaration order — the per-field
        /// buffer table is indexed by this order everywhere (t1178 refactor).
        const buffer_field_names = @typeInfo(Buffers).@"struct".field_names;
        const field_count: usize = buffer_field_names.len;

        fn fieldIndex(comptime name: []const u8) usize {
            inline for (buffer_field_names, 0..) |fname, fi| {
                if (comptime eql(u8, fname, name)) {
                    return fi;
                }
            }
            comptime unreachable;
        }

        /// The GPU buffer backing one Buffers field (e.g. for a renderer to
        /// bind directly). Null on the CPU backend.
        pub fn fieldBuffer(self: *const Self, comptime field: Field) ?wgpu.BufferHandle {
            return if (self.gpu) |gp| gp.field_bufs[fieldIndex(@tagName(field))] else null;
        }

        /// Is `ch` a character that can appear inside a WGSL identifier?
        fn isIdentChar(ch: u8) bool {
            return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                (ch >= '0' and ch <= '9') or ch == '_';
        }

        /// Does `ident` appear as a WHOLE word in `line`? Needed because field
        /// names nest: `kbuf_pos` is a prefix of `kbuf_pos2`, so a plain
        /// substring search would mark `pos` used on a line that only mentions
        /// `pos2`. A real match has a non-identifier char (or the string edge) on
        /// both sides — so `kbuf_pos` matches `kbuf_pos[i]` but not `kbuf_pos2`.
        fn refsIdent(line: []const u8, ident: []const u8) bool {
            var start: usize = 0;
            while (std.mem.indexOfPos(u8, line, start, ident)) |pos| {
                const before_ok: bool = pos == 0 or !isIdentChar(line[pos - 1]);
                const after_i: usize = pos + ident.len;
                const after_ok: bool = after_i >= line.len or !isIdentChar(line[after_i]);
                if (before_ok and after_ok) {
                    return true;
                }
                start = pos + 1;
            }
            return false;
        }

        /// Which Buffers fields kernel `wgsl` actually USES (references in its
        /// body), as flags over field indices. A field counts as used if its
        /// `kbuf_<field>` alias appears on a line that is NOT a binding
        /// declaration (declaration lines carry `@binding(`, and every kernel's
        /// WGSL declares ALL fields because the kompute module aliases them all
        /// at module scope). The per-kernel bind group needs exactly the fields
        /// the entry statically uses (WebGPU spec) — which is precisely the set
        /// referenced in the body. Example: clearGrid's body is only
        /// `atomicStore(&kbuf_grid_counts[..], 0u)`, so this returns {grid_counts}
        /// and clearGrid binds 1 storage buffer instead of all 10.
        fn usedFields(wgsl: []const u8) [field_count]bool {
            var used: [field_count]bool = @splat(false);
            var it = std.mem.splitScalar(u8, wgsl, '\n');
            while (it.next()) |line| {
                // Skip the `@binding(N) var<storage> kbuf_X: ...` declarations
                // (they list every field); we want USES, in the body.
                if (std.mem.indexOf(u8, line, "@binding(") != null) {
                    continue;
                }
                inline for (buffer_field_names, 0..) |fname, fi| {
                    if (refsIdent(line, "kbuf_" ++ fname)) {
                        used[fi] = true;
                    }
                }
            }
            return used;
        }

        /// Read binding numbers out of the generated WGSL headers: lines of
        /// the form `@group(0) @binding(N) var<storage, ...> kbuf_FIELD: ...`
        /// and `@binding(N) var<uniform>`. The SPIR-V backend assigns the
        /// numbers; parsing them here means host and shader cannot disagree.
        /// All kernels must agree (one module = one assignment); verified.
        fn parseBindings(
            kernels: []const KernelWgsl,
            bindings: *[field_count]u32,
            uniform_binding: *u32,
        ) !void {
            var seen: [field_count]bool = @splat(false);
            var seen_uniform: bool = false;
            for (kernels) |k| {
                var it = std.mem.splitScalar(u8, k.wgsl, '\n');
                while (it.next()) |line| {
                    const bind_tag: []const u8 = "@binding(";
                    const bpos: usize = std.mem.indexOf(u8, line, bind_tag) orelse continue;
                    const after: []const u8 = line[bpos + bind_tag.len ..];
                    const close: usize = std.mem.indexOfScalar(u8, after, ')') orelse continue;
                    const num: u32 = std.fmt.parseInt(u32, after[0..close], 10) catch continue;
                    if (std.mem.indexOf(u8, line, "var<uniform>") != null) {
                        if (seen_uniform and uniform_binding.* != num) {
                            return error.BindingMismatch;
                        }
                        uniform_binding.* = num;
                        seen_uniform = true;
                        continue;
                    }
                    const name_tag: []const u8 = "kbuf_";
                    // A @binding storage decl that ISN'T `kbuf_<field>` can't be
                    // mapped to a Buffers field: it would be silently dropped from
                    // every kernel's layout and surface only as a cryptic Dawn
                    // "Binding doesn't exist" at pipeline creation. Trap here with
                    // the offending line instead. (This is exactly how the atomic
                    // grid buffer mis-named `arr` by spv2wgsl on 0.17-dev.956 hid.)
                    assertf(
                        std.mem.indexOf(u8, line, name_tag) != null,
                        @src(),
                        "compute storage binding not named kbuf_<field>: '{s}' — host cannot map it to a buffer",
                        .{std.mem.trim(u8, line, " \t")},
                    );
                    const npos: usize = std.mem.indexOf(u8, line, name_tag).?;
                    const name_rest: []const u8 = line[npos + name_tag.len ..];
                    const name_end: usize = std.mem.indexOfScalar(u8, name_rest, ':') orelse continue;
                    const fname: []const u8 = name_rest[0..name_end];
                    inline for (buffer_field_names, 0..) |bfname, fi| {
                        if (eql(u8, bfname, fname)) {
                            if (seen[fi] and bindings[fi] != num) {
                                return error.BindingMismatch;
                            }
                            bindings[fi] = num;
                            seen[fi] = true;
                        }
                    }
                }
            }
            if (!seen_uniform) {
                return error.UniformBindingNotFound;
            }
            for (seen, 0..) |sv, fi| {
                if (!sv) {
                    // A field no kernel touches gets a fresh binding number
                    // above all parsed ones so the layout entry stays valid.
                    var max_b: u32 = uniform_binding.*;
                    for (bindings, 0..) |b, bj| {
                        if (seen[bj] and b > max_b) {
                            max_b = b;
                        }
                    }
                    bindings[fi] = max_b + 1 + @as(u32, @intCast(fi));
                }
            }
        }

        pub fn upload(self: *Self, comptime field: Field, data: []const ElemOf(field)) void {
            assertf(
                data.len <= @field(M.g.B, @tagName(field)).len,
                @src(),
                "upload to '" ++ @tagName(field) ++ "': {d} elements exceeds capacity {d}",
                .{ data.len, @field(M.g.B, @tagName(field)).len },
            );
            switch (self.backend) {
                .cpu => {
                    const dst: *@TypeOf(@field(M.g.B, @tagName(field))) = &@field(M.g.B, @tagName(field));
                    @memcpy(dst[0..data.len], data);
                },
                // A `.worker` pipe OWNS ITS STATE. It stages into its own mirror, ships that
                // mirror, and reads the answer back into it — it never touches `M.g.B` in
                // this address space at all.
                //
                // It used to share `.cpu`'s arm, on the reasoning that "the payload is
                // literally `asBytes(&M.g.B)`, so the staging area and the CPU's buffers are
                // the same memory — nothing to duplicate". That is true, and it is the bug:
                // `M.g.B` is a MODULE-LEVEL SINGLETON. A `.cpu` pipe's `run()` writes its
                // results there, and the next `.worker` dispatch would then ship those
                // results as its INPUT. Two live pipes on one module silently contaminate
                // each other — and `four_ways` exists precisely to run `.cpu`, `.worker` and
                // `.gpu` side by side.
                //
                // The mirror was already allocated for the readback. Using it for input as
                // well costs nothing, and it makes the arm SYMMETRIC: one buffer, in and out.
                .worker => {
                    if (comptime @hasDecl(M, "kernels")) {
                        const wk: *Worker = &(self.worker orelse {
                            assertUnreachable(@src(), "upload: .worker needs initWorker(gpa)", .{});
                            return;
                        });
                        const dst = &@field(wk.mirror.*, @tagName(field));
                        @memcpy(dst[0..data.len], data);
                    }
                },
                .gpu => {
                    const fi: usize = fieldIndex(@tagName(field));
                    wgpu.queueWriteBuffer(self.gpu.?.queue, self.gpu.?.field_bufs[fi], 0, std.mem.sliceAsBytes(data));
                },
            }
        }

        /// Open a single-pass batch: every following `run` encodes into one
        /// compute pass until `endBatch` submits it.
        ///
        /// Pass this batch's `Params` HERE. They're written to the uniform once,
        /// and every batched dispatch shares them — the uniform is NOT re-written
        /// per dispatch (that's the point of batching). So setting `self.params`
        /// AFTER beginBatch would be silently ignored on the GPU; taking params
        /// as an argument makes you compute them first, and `endBatch` asserts
        /// they didn't change, closing the old "runs one frame stale" trap.
        ///
        /// The bind group is NOT set here either: each `run` sets its own
        /// kernel's bind group per dispatch (adjacent kernels bind different
        /// buffer subsets now). CPU backend: just records params (runs read them).
        /// Upload `self.params` to the uniform buffer only if its contents differ
        /// from what's already there. See `uniform_synced`: this is what makes a
        /// sequence of dependent un-batched dispatches (which share one params
        /// value) write the uniform once instead of once-per-dispatch, avoiding a
        /// same-frame clobber without collapsing the barrier-giving submits.
        fn syncParamsUniform(self: *Self, gp: *Gpu) void {
            if (gp.uniform_synced) |cur| {
                if (meta.eql(self.params, cur)) {
                    return;
                }
            }
            wgpu.queueWriteBuffer(gp.queue, gp.uniform, 0, std.mem.asBytes(&self.params));
            gp.uniform_synced = self.params;
        }

        pub fn beginBatch(self: *Self, params: Params) void {
            self.params = params;
            if (self.backend != .gpu) {
                return;
            }
            const gp: *Gpu = &self.gpu.?;
            assertf(gp.batch_enc == .invalid, @src(), "beginBatch: a batch is already open", .{});
            gp.batch_params = params;
            self.syncParamsUniform(gp);
            gp.batch_enc = wgpu.createCommandEncoder(gp.dev);
            gp.batch_pass = compute_pass.begin(gp.batch_enc);
        }

        /// Close + submit the open batch.
        pub fn endBatch(self: *Self) void {
            if (self.backend != .gpu) {
                return;
            }
            const gp: *Gpu = &self.gpu.?;
            assertf(gp.batch_enc != .invalid, @src(), "endBatch: no batch is open", .{});
            // The uniform was written once at beginBatch; if params changed since,
            // those changes never reached the GPU (batched dispatches don't
            // re-upload). That's a silent-stale bug — flag it by name.
            assertf(
                meta.eql(self.params, gp.batch_params),
                @src(),
                "endBatch: params changed during the batch — pass them to beginBatch(params), " ++
                    "not after (a post-beginBatch change is silently ignored on-device)",
                .{},
            );
            compute_pass.end(gp.batch_pass);
            const cmd: wgpu.CommandBufferHandle = wgpu.finishCommandEncoder(gp.batch_enc);
            submitDispatch(gp, cmd);
            gp.batch_enc = .invalid;
            gp.batch_pass = .invalid;
        }

        /// Log a human-readable summary of the compiled pipeline: per kernel, its
        /// workgroup size, the buffer fields it actually binds (with their binding
        /// numbers), and the last dispatch width it ran at. A debugging aid — call
        /// it after init (or after a frame) to SEE what got wired, instead of
        /// decoding the wasm. Example line:
        ///   clearGrid  wg=256  binds:[P@0 grid_counts@1]  last n=1024
        /// CPU backend: kernels are ordinary Zig fns with no GPU bindings, so it
        /// just notes that.
        pub fn describe(self: *Self) void {
            const gp: *Gpu = if (self.gpu) |*g| g else {
                std.log.info(
                    "Compute({s}): CPU backend — {d} buffer fields; kernels run as Zig fns (no GPU bindings).",
                    .{ @typeName(M), field_count },
                );
                return;
            };
            std.log.info(
                "Compute({s}): GPU — {d} kernels, workgroup={d}:",
                .{ @typeName(M), gp.kernel_names.len, M.config.workgroup },
            );
            for (gp.kernel_names, 0..) |kn, i| {
                // Assemble this kernel's "field@binding" list into a stack buffer
                // (no allocation for a debug print). 512 bytes comfortably holds
                // every field even for the widest Buffers.
                var buf: [512]u8 = undefined;
                var len: usize = 0;
                inline for (buffer_field_names, 0..) |fname, fi| {
                    if (gp.kernel_used[i][fi]) {
                        const part: []u8 = bufPrint(
                            buf[len..],
                            "{s}@{d} ",
                            .{ fname, gp.bindings[fi] },
                        ) catch buf[len..len];
                        len += part.len;
                    }
                }
                std.log.info(
                    "  {s}  wg={d}  binds:[P@{d} {s}]  last n={d}",
                    .{ kn, M.config.workgroup, gp.uniform_binding, buf[0..len], gp.kernel_last_n[i] },
                );
            }
        }

        /// Run kernel `name` over exactly `n` invocations. `n` is the dispatch
        /// width FOR THIS CALL — explicit, because a multi-kernel pipeline mixes
        /// widths (clearGrid over grid_cells, the particle kernels over
        /// num_particles, prefixSum over 1). Passing it per call kills the old
        /// footgun of a mutable `pipe.count` you had to re-set between kernels:
        /// forget, and a kernel silently dispatched the PREVIOUS kernel's width.
        ///   CPU: a plain `for id in 0..n` loop calling the kernel (the dual-shape
        ///        source runs as ordinary Zig).
        ///   GPU: dispatch `ceil(n / config.workgroup)` workgroups — into the open
        ///        batch pass if one is active, else a fresh single-dispatch submit.
        /// Readback is unaffected by `n`; it slices by `element_count` (set once).
        pub fn run(self: *Self, comptime name: []const u8, n: u32) void {
            assertf(n > 0, @src(), "run('" ++ name ++ "'): n must be > 0", .{});
            assertf(
                n <= M.config.max,
                @src(),
                "run('" ++ name ++ "'): n={d} exceeds capacity config.max={d}",
                .{ n, M.config.max },
            );
            switch (self.backend) {
                .cpu => {
                    // `M.g.P` is set either way: the LEAN form reads it through `g.uniform()`,
                    // and the stock form's `Ctx` carries a copy.
                    M.g.P = self.params;
                    var id: u32 = 0;
                    while (id < n) : (id += 1) {
                        // ★★ A LEAN KERNEL TAKES THE RAW INDEX, a stock one takes a `Ctx`. The
                        // signature is the discriminator, so a file can mix both forms and
                        // neither has to declare which it is. Without this the CPU driver only
                        // spoke the `Ctx` dialect, and `installKernelLean` compiled but could
                        // never be run on the host — half a merge.
                        // Compared as a TYPE rather than through `@typeInfo`: on
                        // 0.17.0-dev.1980 `Type.Fn` no longer carries `.params`, and a direct
                        // comparison needs no reflection to survive.
                        const takes_raw_id: bool = @TypeOf(@field(M, name)) == fn (u32) void;
                        if (takes_raw_id) {
                            @field(M, name)(id);
                        } else {
                            @field(M, name)(.{ .id = id, .params = self.params });
                        }
                    }
                },
                // The same loop, somewhere else. Three things diverge from `.cpu`, and
                // they are the price of not freezing the frame:
                //
                //   1. It is ASYNCHRONOUS. `readLatest` returns null until the job lands
                //      — as the GPU arm already does, so an app written for `.gpu` needs
                //      no change.
                //   2. It runs ONE JOB AT A TIME. A `run` issued while a job is still out
                //      is DROPPED, because two jobs would both write back into the same
                //      mirror. `.cpu` and `.gpu` would simply run again; this cannot.
                //   3. It copies the WHOLE `Buffers` to the worker and back, every
                //      dispatch. Fine for one-shot work with modest state; a poor trade
                //      for a megabyte of particles you wanted stepped every frame. That
                //      is what `.gpu` is for.
                .worker => {
                    // Gated on `kernels` so a module that never opts in pays NOTHING for
                    // this arm — an untaken comptime `if` is never analyzed, so none of
                    // the jobs machinery is linked. Selecting `.worker` requires
                    // `initWorker`, which is a compile error without it.
                    if (comptime @hasDecl(M, "kernels")) {
                        const wk: *Worker = &(self.worker orelse {
                            assertUnreachable(@src(), "run('" ++ name ++ "'): .worker needs initWorker(gpa)", .{});
                            return;
                        });
                        if (wk.job.inFlight()) {
                            return; // still working on the last one — see (2) above
                        }
                        wk.job = komputeRegistry(M).submit(
                            wk.gpa,
                            komputeKernel(M, name),
                            .{ .n = n, .params = self.params },
                            std.mem.asBytes(wk.mirror), // OUR state, not the module's
                        ) catch |err| blk: {
                            std.log.err("Compute.run('" ++ name ++ "') on .worker: {s}", .{@errorName(err)});
                            break :blk .{};
                        };
                    }
                },
                .gpu => {
                    const gp: *Gpu = &self.gpu.?;
                    const workgroups: u32 = (n + M.config.workgroup - 1) / M.config.workgroup;
                    // Find this kernel's slot so we get BOTH its pipeline and its
                    // own bind group — each kernel binds a different subset of the
                    // buffers now, so the two always travel together.
                    const ki: usize = blk: {
                        for (gp.kernel_names, 0..) |kn, idx| {
                            if (eql(u8, kn, name)) {
                                break :blk idx;
                            }
                        }
                        // A correctly-registered kernel is always found; reaching
                        // here means a name typo or a kernel missing from initGpu's
                        // list. assertf gives a localized message in dev and lowers
                        // to the `unreachable` optimization hint once stripped.
                        assertUnreachable(@src(), "run: kernel '" ++ name ++ "' is not registered with this pipe", .{});
                        unreachable;
                    };
                    const pipeline: wgpu.ComputePipelineHandle = gp.pipelines[ki];
                    const bind_group: wgpu.BindGroupHandle = gp.bind_groups[ki];
                    gp.kernel_last_n[ki] = n; // for describe()
                    if (gp.batch_enc != .invalid) {
                        // Open batch: encode into the shared pass. Params were
                        // written once at beginBatch (all batched dispatches share
                        // them). The bind group is set PER DISPATCH now — adjacent
                        // kernels bind different buffer subsets, so it can't be
                        // hoisted to beginBatch the way the old shared one was.
                        compute_pass.setPipeline(gp.batch_pass, pipeline);
                        compute_pass.setBindGroup(gp.batch_pass, 0, bind_group);
                        compute_pass.dispatchWorkgroups(gp.batch_pass, .{ .x = workgroups });
                        return;
                    }
                    self.syncParamsUniform(gp);
                    const enc: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(gp.dev);
                    const cp: wgpu.ComputePassEncoderHandle = compute_pass.begin(enc);
                    compute_pass.setPipeline(cp, pipeline);
                    compute_pass.setBindGroup(cp, 0, bind_group);
                    compute_pass.dispatchWorkgroups(cp, .{ .x = workgroups });
                    compute_pass.end(cp);
                    const cmd: wgpu.CommandBufferHandle = wgpu.finishCommandEncoder(enc);
                    // Both dispatch paths go through `submitDispatch`, which counts. I
                    // incremented by hand at the batched site only, and every caller using
                    // `run()` outside a batch then saw `submitted == 0` - so the sweep retired
                    // each row before its own dispatch had executed. **7 of 105 on device**,
                    // with `inf` against bars of zero: another row's data.
                    submitDispatch(gp, cmd);
                },
            }
        }

        /// Read buffer `field` back. CPU: the live slice (zero latency). GPU:
        /// frame-delayed — returns LAST frame's mapped data and kicks off this
        /// frame's copy, never stalling (null until the first readback completes).
        /// What `readGeneration` reports.
        ///
        /// A NAMED type, not an anonymous one: each `Compute(M)` instantiation would otherwise
        /// get its own incompatible anonymous struct, and a caller holding results from two
        /// pipelines - which the zimrnum sweep does, one per kernel kind - cannot put them in the
        /// same variable. The compiler says so in a message naming two generated type names,
        /// which is not a fun one to read.
        /// Submit a DISPATCH and count it.
        ///
        /// ONE FUNCTION, SO THE COUNT CANNOT BE FORGOTTEN AGAIN
        ///
        /// There are two places a dispatch reaches the queue - batched and direct - and I
        /// incremented the counter at one of them. Every caller using `run()` outside a batch
        /// then saw `submitted == 0`, so the sweep's `mirrored >= wanted` was `0 >= 0` and each
        /// row retired before its own work had executed. The device said 7 of 105.
        ///
        /// A counter maintained at N call sites is a counter that will be wrong the first time
        /// someone adds the N+1th. Both sites call this now, and the readback copy deliberately
        /// does not - it submits a copy, not work.
        fn submitDispatch(gp: *Gpu, cmd: wgpu.CommandBufferHandle) void {
            wgpu.queueSubmit(gp.queue, cmd);
            gp.submitted += 1;
        }

        pub const Generation = struct {
            /// Dispatches submitted to the queue.
            submitted: u64,
            /// Dispatches the mirror's contents reflect.
            mirrored: u64,
        };

        /// How many dispatches the mirror's contents reflect, and how many have been submitted.
        ///
        /// WHAT THIS REPLACES: A FIXED WAIT WITH A GUESS IN IT
        ///
        /// `readLatest` polls, so it returns `null` until a copy lands - but it could never say
        /// WHICH dispatch the landed data came from. A caller that dispatched and got bytes back
        /// had no way to know they were its own rather than the previous dispatch's.
        ///
        /// The zimrnum sweep papered over that with six settle frames per row, a number its own
        /// comment admits was set from the time budget rather than measured - and which had
        /// already been wrong twice, the symptom being another row's data arriving as `inf`
        /// against a bar of zero.
        ///
        /// With this, a caller records `submitted` after its dispatch and waits until `mirrored`
        /// reaches it. That is exact: never early, never longer than necessary, and it does not
        /// move with row count or what else the browser is doing.
        ///
        /// On the CPU and worker backends there is no queue, so both numbers are equal and a
        /// caller's loop degenerates to reading immediately - which is correct and needs no
        /// special case at the call site.
        pub fn readGeneration(self: *Self) Generation {
            switch (self.backend) {
                .gpu => {
                    const gp: *Gpu = &self.gpu.?;
                    return .{ .submitted = gp.submitted, .mirrored = gp.mirrored };
                },
                else => return .{ .submitted = 0, .mirrored = 0 },
            }
        }

        pub fn readLatest(self: *Self, comptime field: Field) ?[]const ElemOf(field) {
            // Variable-count fields (pos/vel/…) are sized to capacity and slice to
            // the live `element_count`; fixed fields (grid_counts, cell_start) must
            // slice to THEIR OWN array length, never the particle count — else
            // grid_counts (grid_cells long) overruns the next field. Clamp to the
            // lesser of the two.
            const arr_len: usize = @field(M.g.B, @tagName(field)).len;
            const n: usize = @min(self.element_count, arr_len);
            switch (self.backend) {
                .cpu => {
                    return @field(M.g.B, @tagName(field))[0..n];
                },
                // Same contract as the GPU arm: null until it lands, then the data —
                // out of our OWN mirror, never out of `M.g.B`, so a `.cpu` pipe on the
                // same module keeps its answer.
                .worker => {
                    if (comptime @hasDecl(M, "kernels")) {
                        const wk: *Worker = &(self.worker orelse return null);
                        if (wk.job.poll()) |maybe_bytes| {
                            if (maybe_bytes) |bytes| {
                                if (bytes.len == @sizeOf(Buffers)) {
                                    @memcpy(std.mem.asBytes(wk.mirror), bytes);
                                    wk.have_read = true;
                                }
                                wk.job.deinit();
                            }
                        } else |err| {
                            std.log.err("Compute.readLatest on .worker: {s}", .{@errorName(err)});
                            wk.job.deinit();
                        }
                        if (!wk.have_read) {
                            return null;
                        }
                        return @field(wk.mirror.*, @tagName(field))[0..n];
                    }
                    return null;
                },
                .gpu => {
                    const gp: *Gpu = &self.gpu.?;
                    if (gp.read != .invalid and wgpu.bufferReadPoll(gp.read)) {
                        wgpu.bufferReadInto(gp.read, std.mem.asBytes(gp.mirror));
                        wgpu.bufferReadRelease(gp.read);
                        gp.read = .invalid;
                        gp.have_read = true;
                        // The mirror now holds whatever had been dispatched when this copy was
                        // ENCODED, which is `copy_at` - not `submitted`, which may have moved on
                        // since. Recording the wrong one of those two is the whole bug this
                        // counter exists to prevent, so it is stored at encode time below.
                        gp.mirrored = gp.copy_at;
                    }
                    if (gp.read == .invalid) {
                        // Stamp the encode, not the completion: everything submitted BEFORE this
                        // point is what the copy will capture. Anything dispatched afterwards is
                        // not in it, and a caller comparing generations needs that to be exact
                        // rather than approximately recent.
                        // NOT `submitted += 1` here, and the asymmetry is the point: this
                        // submits a COPY, not a dispatch. Counting it would make the mirror
                        // appear to reflect work that was never run.
                        gp.copy_at = gp.submitted;
                        const enc: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(gp.dev);
                        inline for (buffer_field_names, 0..) |fname, fi| {
                            wgpu.copyBufferToBuffer(
                                enc,
                                gp.field_bufs[fi],
                                0,
                                gp.staging,
                                @offsetOf(Buffers, fname),
                                @sizeOf(@FieldType(Buffers, fname)),
                            );
                        }
                        const cmd: wgpu.CommandBufferHandle = wgpu.finishCommandEncoder(enc);
                        wgpu.queueSubmit(gp.queue, cmd);
                        gp.read = wgpu.bufferReadStart(gp.staging, @sizeOf(Buffers));
                    }
                    if (!gp.have_read) {
                        return null;
                    }
                    return @field(gp.mirror.*, @tagName(field))[0..n];
                },
            }
        }
    };
}

test "Compute .worker runs the SAME kernel and gets the SAME answer" {
    // The claim of the .worker backend, checked on the host: one kernel source, two
    // backends, identical results. No browser and no wasm needed — with no worker pool,
    // `zimr.jobs` runs the kernel inline through the very same `invoke` a real worker
    // calls, so this exercises the actual adapter and not a mock of it.
    const M = struct {
        pub const config = .{ .max = 64, .workgroup = 64 };
        pub const Buffers = extern struct { data: [64]f32 };
        pub const Params = extern struct {
            count: u32,
            _pad0: u32 = 0,
            _pad1: u32 = 0,
            _pad2: u32 = 0,
        };
        pub const g = struct {
            pub var B: Buffers = undefined;
            pub var P: Params = undefined;
        };
        /// `.worker` needs the names it may run off-thread written down.
        pub const kernels = [_][:0]const u8{"triple"};
        pub fn triple(c: struct { id: u32, params: Params }) void {
            if (c.id >= c.params.count) {
                return;
            }
            g.B.data[c.id] = g.B.data[c.id] * 3.0;
        }
    };
    const n: u32 = 8;
    const input = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    var cpu: Compute(M) = .initCpu();
    cpu.element_count = n;
    cpu.params = .{ .count = n };
    cpu.upload(.data, &input);
    cpu.run("triple", n);
    // BY VALUE. `readLatest` on .cpu returns a slice INTO the module globals, and the
    // next pipe to touch them would silently rewrite what this "answer" points at. (The
    // first draft of this test held the slice, and passed for exactly that wrong reason.)
    const cpu_answer: [8]f32 = cpu.readLatest(.data).?[0..8].*;

    var wk: Compute(M) = try .initWorker(std.testing.allocator);
    defer wk.deinit();
    wk.element_count = n;
    wk.params = .{ .count = n };
    wk.upload(.data, &input);
    wk.run("triple", n);
    const wk_answer: [8]f32 = wk.readLatest(.data).?[0..8].*;

    for (0..n) |i| {
        try expectEqual(input[i] * 3.0, wk_answer[i]);
        try expectEqual(cpu_answer[i], wk_answer[i]); // same kernel, same answer
    }
}

test "Compute .worker OWNS its state — two live pipes on one module cannot contaminate each other" {
    // The property that makes the inline fallback HONEST.
    //
    // In a real worker, `M.g.B` is that worker's private memory. On the inline path there
    // is no worker, so the kernel runs in the app's own address space — and without the
    // snapshot/restore in `komputeKernel` it would trample the app's globals. The backend
    // would then behave one way in Chrome and another in a sandboxed iframe. This test is
    // the reason that restore exists.
    const M = struct {
        pub const config = .{ .max = 16, .workgroup = 16 };
        pub const Buffers = extern struct { data: [16]u32 };
        pub const Params = extern struct {
            add: u32,
            _pad0: u32 = 0,
            _pad1: u32 = 0,
            _pad2: u32 = 0,
        };
        pub const g = struct {
            pub var B: Buffers = undefined;
            pub var P: Params = undefined;
        };
        pub const kernels = [_][:0]const u8{"bump"};
        pub fn bump(c: struct { id: u32, params: Params }) void {
            g.B.data[c.id] = g.B.data[c.id] + c.params.add;
        }
    };

    // A CPU pipe, with its own data.
    var cpu: Compute(M) = .initCpu();
    cpu.element_count = 4;
    cpu.params = .{ .add = 100 };
    cpu.upload(.data, &[_]u32{ 1, 2, 3, 4 });
    cpu.run("bump", 4);
    try expectEqualSlices(u32, &[_]u32{ 101, 102, 103, 104 }, cpu.readLatest(.data).?[0..4]);

    // A WORKER pipe on the SAME module, with DIFFERENT data, live at the same time.
    var wk: Compute(M) = try .initWorker(std.testing.allocator);
    defer wk.deinit();
    wk.element_count = 4;
    wk.params = .{ .add = 100 };
    wk.upload(.data, &[_]u32{ 10, 20, 30, 40 });
    wk.run("bump", 4);

    // It computed over ITS OWN input — not the CPU pipe's {101..104}.
    //
    // This test used to assert the OPPOSITE: it dispatched the worker with no upload at
    // all and expected {201..204}, i.e. it expected the worker to pick up whatever the CPU
    // pipe had left in the module globals. That is cross-contamination between two live
    // pipes, and it was written down as intended behaviour. `four_ways` exists to run
    // `.cpu`, `.worker` and `.gpu` side by side, so it would have hit it immediately.
    try expectEqualSlices(u32, &[_]u32{ 110, 120, 130, 140 }, wk.readLatest(.data).?[0..4]);

    // ...and the CPU pipe still holds ITS answer. Two properties in one assertion: the
    // worker never read the globals, and the inline fallback's snapshot/restore put back
    // what the kernel body trampled while running in this address space.
    try expectEqualSlices(u32, &[_]u32{ 101, 102, 103, 104 }, cpu.readLatest(.data).?[0..4]);
}

test "Compute CPU backend runs a kernel as a plain loop" {
    // A self-contained kompute-shaped module (no kompute/zm import needed for the
    // CPU path — the DSL only generates this shape; here we hand-roll it).
    const M = struct {
        pub const config = .{ .max = 1024, .workgroup = 64 };
        pub const Buffers = extern struct { data: [1024]f32 };
        pub const Params = extern struct {
            count: u32,
            _pad0: u32 = 0,
            _pad1: u32 = 0,
            _pad2: u32 = 0,
        };
        pub const g = struct {
            pub var B: Buffers = undefined;
            pub var P: Params = undefined;
        };
        pub fn double(c: struct { id: u32, params: Params }) void {
            if (c.id >= c.params.count) {
                return;
            }
            g.B.data[c.id] = g.B.data[c.id] * 2.0;
        }
    };
    var pipe = Compute(M).initCpu();
    pipe.element_count = 5;
    pipe.params = .{ .count = 5 };
    const input = [_]f32{ 1, 2, 3, 4, 5 };
    pipe.upload(.data, &input);
    pipe.run("double", 5);
    // Exercise describe() here too: it's a generic method, so Zig only
    // type-checks its body when it's actually called. Invoking it on the CPU
    // backend analyzes the whole function (both backend branches) and keeps it
    // from silently rotting — a green build otherwise wouldn't cover it.
    pipe.describe();
    const out: []const f32 = pipe.readLatest(.data).?;
    try expectEqualSlices(f32, &[_]f32{ 2, 4, 6, 8, 10 }, out);
}

test "Compute CPU backend: multi-buffer gravity step (pos + vel)" {
    const M = struct {
        pub const config = .{ .max = 256, .workgroup = 64 };
        pub const Buffers = struct {
            // Plain struct (not extern): Zig 1245 bans @Vector fields in extern
            // structs on CPU. The GPU path binds each field by name via @extern
            // on the SPIR-V target (where vectors are legal); the CPU twin just
            // needs the Vec2 arrays for the rasterizer-style math below.
            pos: [256]Vec2,
            vel: [256]Vec2,
        };
        pub const Params = extern struct {
            count: u32,
            dt: f32,
            gravity: f32,
            _pad: f32 = 0,
        };
        pub const g = struct {
            pub var B: Buffers = undefined;
            pub var P: Params = undefined;
        };
        pub fn step(c: struct { id: u32, params: Params }) void {
            if (c.id >= c.params.count) {
                return;
            }
            g.B.vel[c.id][1] = g.B.vel[c.id][1] + c.params.gravity * c.params.dt;
            g.B.pos[c.id] = g.B.pos[c.id] + g.B.vel[c.id] * @as(Vec2, @splat(c.params.dt));
        }
    };
    var pipe = Compute(M).initCpu();
    pipe.element_count = 3;
    pipe.params = .{ .count = 3, .dt = 0.1, .gravity = 10.0 };
    const zeros = [_]Vec2{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    pipe.upload(.pos, &zeros);
    pipe.upload(.vel, &zeros);
    pipe.run("step", 3);
    const pos: []const Vec2 = pipe.readLatest(.pos).?;
    // After one step: vel.y = gravity*dt = 1.0; pos.y = vel.y*dt = 0.1.
    try expectApproxEqAbs(@as(f32, 0.1), pos[0][1], 1e-5);
}

test "unboundUsedBinding flags a used-but-unbound binding (the `arr` regression shape)" {
    // The atomic grid buffer is named `arr` and used in the body, but the host
    // layout (built by the kbuf_ scan) only carries binding 0 — so binding 1 is
    // unbound. This is exactly the drift that produced Dawn's "Binding doesn't
    // exist" before the spv2wgsl naming fix; the cross-check must catch it.
    const wgsl: []const u8 =
        \\@group(0) @binding(0) var<uniform> P: S8;
        \\@group(0) @binding(1) var<storage, read_write> arr: array<atomic<u32>>;
        \\fn clearGrid() { atomicStore(&arr[0u], 0u); }
    ;
    const miss: ?WgslBinding = unboundUsedBinding(wgsl, &.{0});
    try expect(miss != null);
    try expectEqual(@as(u32, 1), miss.?.num);
    try expectEqualStrings("arr", miss.?.name);
}

test "unboundUsedBinding passes when the layout covers every used binding" {
    const ok: []const u8 =
        \\@group(0) @binding(0) var<uniform> P: S8;
        \\@group(0) @binding(1) var<storage, read_write> kbuf_grid_counts: array<atomic<u32>>;
        \\fn clearGrid() { atomicStore(&kbuf_grid_counts[0u], 0u); }
    ;
    try expect(unboundUsedBinding(ok, &.{ 0, 1 }) == null);
    // A binding the kernel DECLARES but never references need not be in the
    // layout (per the WebGPU "statically used" rule) — must not false-fire.
    const unused: []const u8 =
        \\@group(0) @binding(0) var<uniform> P: S8;
        \\@group(0) @binding(5) var<storage, read_write> kbuf_spare: array<u32>;
        \\fn k() { let _x: S8 = P; }
    ;
    try expect(unboundUsedBinding(unused, &.{0}) == null);
}
