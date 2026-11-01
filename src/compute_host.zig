//! compute_host.zig - `z.Compute(M)`: run a kompute kernel module `M` on the CPU
//! (a plain `for id` loop calling the kernel) OR the GPU (a WGSL compute dispatch),
//! chosen at runtime via `.backend`. Same kernel source, same results.
//!
//! The footgun this erases: buffer + bind-layout sizes come from
//! `@sizeOf(M.Buffers)` / `@sizeOf(M.Params)` (comptime, off the schema) - never
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
const readInt = std.mem.readInt;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqualSlices = std.testing.expectEqualSlices;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const indexOf = std.mem.indexOf;
const indexOfScalar = std.mem.indexOfScalar;
const asBytes = std.mem.asBytes;
const zeroes = std.mem.zeroes;
const splitScalar = std.mem.splitScalar;
const parseInt = std.fmt.parseInt;
const Io = std.Io;
const indexOfPos = std.mem.indexOfPos;
const sliceAsBytes = std.mem.sliceAsBytes;
const trim = std.mem.trim;
const wgpu = @import("wgpu.zig");
const host = @import("host.zig");
const compute_pass = wgpu.compute_pass;
const shader_introspect = @import("shader_introspect.zig");
const jobs = @import("jobs.zig");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;
const splat2 = zm.splat2;
const float64 = zm.float64;

/// Where a kompute kernel runs. The SAME kernel source, on any of them.
///
///   .cpu    - a plain `for id` loop, right here. Synchronous; the answer is in `M.g.B`
///             the moment `run` returns. It also BLOCKS the frame for as long as it takes.
///
///   .worker - the SAME plain `for id` loop, in a Web Worker. Not faster; ELSEWHERE.
///             This exists so a device with no GPU gets a compute fallback that does not
///             freeze the frame - which is the whole point of `zimr.jobs`, applied to
///             kompute. It is asynchronous, so `readLatest` returns null until the job
///             lands, exactly as the GPU arm already does.
///
///   .gpu     - a WGSL compute dispatch. Asynchronous, ~1 frame of readback latency.
///
/// The three are interchangeable in CODE, not in COST. Read `.worker`'s doc on `run`
/// before reaching for it: it copies the entire `Buffers` to the worker and back on every
/// dispatch, and it runs ONE job at a time.
pub const Backend = enum { cpu, worker, gpu };

/// The header a kompute job carries to its worker: the dispatch count, and the kernel's
/// params by value.
///
/// `extern` because these bytes are memcpy'd out of the app's wasm and into the kernel's
/// - two SEPARATE compilations - and Zig's auto layout is free to reorder fields.
/// (`M.Params` is already extern: the GPU needs it for the std140 uniform.)
pub fn JobHeader(comptime M: type) type {
    return extern struct {
        n: u32,
        params: M.Params,
    };
}

fn JobKernelFn(comptime M: type) type {
    return fn (Allocator, JobHeader(M), []const u8, *Io.Writer) anyerror!void;
}

/// Turn a kompute kernel into a JOB kernel - the adapter that makes `.worker` cost an
/// adapter rather than a rewrite.
///
/// Look at the loop: it is byte-for-byte the `.cpu` arm of `run` below. The only
/// difference is WHERE it executes. It works because a worker instantiates its own copy
/// of the kernel wasm, so `M.g.B` in there is that worker's private memory - the module
/// globals kompute uses on the CPU are exactly what a worker needs, for free.
pub fn komputeKernel(comptime M: type, comptime name: []const u8) JobKernelFn(M) {
    return struct {
        fn run(
            gpa: Allocator,
            hdr: JobHeader(M),
            payload: []const u8,
            out: *Io.Writer,
        ) anyerror!void {
            if (payload.len != @sizeOf(M.Buffers)) {
                return error.MalformedJob;
            }

            // SNAPSHOT AND RESTORE the module globals around the run.
            //
            // In a real worker this is nearly pointless: `M.g.B` there is that worker's
            // own private memory and nobody can observe it. But when there is no worker
            // pool - the host, or a sandboxed iframe that refused `new Worker()` -
            // `zimr.jobs` runs this kernel INLINE, in the APP's address space, where
            // `M.g.B` is the app's own globals. Without the restore, a `.worker` dispatch
            // would silently trample them, and the backend would behave one way in Chrome
            // and another in an iframe. A bug that only appears where you cannot attach a
            // debugger is the worst kind there is, so pay two memcpys and have neither.
            //
            // Heap, via the job's arena - never `const saved = M.g.B`, which would put a
            // possibly-megabyte struct on the wasm shadow stack.
            const saved: *M.Buffers = try gpa.create(M.Buffers);
            @memcpy(asBytes(saved), asBytes(&M.g.B));
            defer @memcpy(asBytes(&M.g.B), asBytes(saved));

            @memcpy(asBytes(&M.g.B), payload);
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

            try out.writeAll(asBytes(&M.g.B));
        }
    }.run;
}

/// One job kernel per name in `M.kernels`, as a table `jobs.Registry` can take.
///
/// NOTE - this is an ARRAY, and that limits composition. A page carries ONE kernel wasm, so
/// the launcher's would have to be built from the CONCATENATED tables of every example on it:
///
///     jobs.Registry(worker_png.job_kernels ++ four_ways.job_kernels, .{ ... })
///
/// `++` on two arrays needs a common element type, and these have none: every kernel carries
/// its own header type in its signature (`Size` there, `JobHeader(M)` here). Tuples would
/// concatenate, but this Zig (0.17.0-dev.1282) has no `@Type` and no `std.meta.Tuple`, and
/// `@Struct` with numeric field names yields a struct that does not support indexing. So the
/// composition SIMPLIFICATION the review claimed is not available today, and the launcher
/// ships without a kernel wasm - its jobs run inline, which is correct but hitchy.
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

/// The job registry for a kompute module - DERIVED, so an example that wants the
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
        // The kernel works in `M.g`, the module's globals: natively, inline rather than on a thread, which would share
        // them with the app while its frame reads them.
        .kernels_work_in_globals = true,
    });
}

/// WebGPU's guaranteed floor for `maxStorageBuffersPerShaderStage`: every
/// conformant device grants at least this many storage buffers to a compute
/// stage (it's the spec default limit). A kernel that binds more than this may
/// run on a beefy desktop GPU but will fail to create its pipeline on a stock
/// device - so the per-kernel bind groups assert each kernel stays within it.
/// This is what lets us delete the old `maxStorageBuffersPerShaderStage` raise:
/// instead of asking the device for more, we make each kernel need fewer.
const max_portable_storage_buffers: u32 = 8;

/// A binding a kernel's WGSL declares: its number and declared variable name.
const WgslBinding = struct { num: u32, name: []const u8 };

fn isWgslIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_';
}

/// The first word of every SPIR-V module, read little-endian.
const spirv_magic: u32 = 0x07230203;

/// Whether a kernel's embedded bytes are a SPIR-V module rather than WGSL text: the native host embeds the kernel
/// file's SPIR-V where the web embeds WGSL, under the same import name, and no WGSL text begins with this word.
fn isSpirv(bytes: []const u8) bool {
    return bytes.len >= 4 and readInt(u32, bytes[0..4], .little) == spirv_magic;
}

/// Does `name` appear as a WHOLE word in `line`? (So `kbuf_pos` does not match
/// inside `kbuf_pos2`, and `arr` does not match inside `narrow`.)
fn wgslRefsName(line: []const u8, name: []const u8) bool {
    var start: usize = 0;
    while (indexOfPos(u8, line, start, name)) |pos| {
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

/// The variable name in a `... var<...> NAME: TYPE;` binding decl - the
/// identifier immediately before the first `:`. Name-agnostic on purpose: it
/// returns whatever the decl actually says (`kbuf_grid_counts`, `arr`, `P`),
/// so the cross-check below cannot be fooled by a buffer that lost its
/// `kbuf_<field>` name (exactly the 0.17-dev.956 atomic-buffer regression).
fn wgslDeclName(line: []const u8) ?[]const u8 {
    const colon: usize = indexOfScalar(u8, line, ':') orelse return null;
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
/// layout - it keys on each binding's declared var name and matches by binding
/// NUMBER, so a disagreement between the two is precisely the host<->WGSL drift
/// that otherwise surfaces only as Dawn's opaque "Binding doesn't exist"
/// cascade at pipeline creation. Catching it here names the kernel + binding.
fn unboundUsedBinding(wgsl: []const u8, bound: []const u32) ?WgslBinding {
    const tag: []const u8 = "@binding(";
    var it = splitScalar(u8, wgsl, '\n');
    while (it.next()) |line| {
        const bpos: usize = indexOf(u8, line, tag) orelse continue;
        const after: []const u8 = line[bpos + tag.len ..];
        const close: usize = indexOfScalar(u8, after, ')') orelse continue;
        const num: u32 = parseInt(u32, after[0..close], 10) catch continue;
        const name: []const u8 = wgslDeclName(line) orelse continue;
        // Used = its declared name appears on some line that is NOT itself a
        // binding declaration (every kernel declares ALL bindings at module
        // scope; only the body lines are real uses).
        var used: bool = false;
        var bit = splitScalar(u8, wgsl, '\n');
        while (bit.next()) |bline| {
            if (indexOf(u8, bline, tag) != null) {
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

/// The most workgroups one dimension of a dispatch may count: WebGPU's `maxComputeWorkgroupsPerDimension` and the least
/// Vulkan guarantees (`maxComputeWorkGroupCount`).
const max_workgroups_per_dimension: u32 = 65535;

/// A dispatch's grid of workgroups: `x` along a row, `y` rows.
const DispatchGrid = struct {
    x: u32,
    y: u32,
};

/// The grid for `workgroups` workgroups: one row when they fit, else rows of `max_workgroups_per_dimension` - only
/// for a module that recovers its index from the rows (`kompute.Config.large_dispatch`; `run` refuses the others).
fn dispatchGrid(workgroups: u32) DispatchGrid {
    if (workgroups <= max_workgroups_per_dimension) {
        const one_row: DispatchGrid = .{ .x = workgroups, .y = 1 };
        return one_row;
    }
    const rows: u32 = @divCeil(workgroups, max_workgroups_per_dimension);
    const grid: DispatchGrid = .{ .x = max_workgroups_per_dimension, .y = rows };
    return grid;
}

test "compute_host: a large dispatch spreads over rows of at most 65,535 workgroups" {
    const small: DispatchGrid = dispatchGrid(10);
    try expectEqual(@as(u32, 10), small.x);
    try expectEqual(@as(u32, 1), small.y);
    const full_row: DispatchGrid = dispatchGrid(65535);
    try expectEqual(@as(u32, 1), full_row.y);
    const two_rows: DispatchGrid = dispatchGrid(78125);
    try expectEqual(@as(u32, 65535), two_rows.x);
    try expectEqual(@as(u32, 2), two_rows.y);
    const covered: u64 = @as(u64, two_rows.x) * two_rows.y;
    try expect(covered >= 78125);
}

/// A FIELD'S GPU BUFFER, LENT by one pipe to another (`Compute.lendField`, `Compute.initGpuBorrowing`): the buffer, its
/// bytes, and the owner's count of loans still out, which the borrower decrements when it is done. One copy of the
/// data serves two kernel modules, with no upload or copy between them:
///
///     owner pipe      field `ring`          ----+
///                                               |   the same GPU buffer, bound by both pipes
///     borrower pipe   field `observations`  <---+
///
/// The owner must outlive every borrower (its `deinit` asserts that every loan came back), and must not move while it
/// lends: the loan points at its count.
pub const FieldLoan = struct {
    buffer: wgpu.BufferHandle,
    bytes: u64,
    owner_loans: *u32,
};

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
        // every field past the mismatch reads garbage on-device - a miserable,
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
        /// width - that's the explicit `n` in `run(name, n)`. readLatest clamps to
        /// `@min(element_count, field.len)`, so fixed-size fields (grid_counts,
        /// cell_start) still slice to their own length, not the particle count.
        element_count: u32 = 0,
        gpu: ?Gpu = null,
        worker: ?Worker = null,

        /// The `.worker` backend's state - deliberately the same shape as `Gpu`'s.
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
            /// fixed cap to overflow - the old fixed array's overflow assert
            /// could constant-fold to a trap and DCE this whole registry in
            /// ReleaseSmall (the shaders silently vanished); that footgun is gone.
            pipelines: []wgpu.ComputePipelineHandle,
            kernel_names: [][]const u8,
            /// One bind group PER KERNEL, parallel to `pipelines`. Each binds
            /// only the fields its kernel uses (+ the uniform), so a kernel that
            /// touches one buffer doesn't drag in all ten - the change that keeps
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
            /// per-dispatch submits - it just collapses a frame's many submits
            /// into one.
            batch_enc: wgpu.CommandEncoderHandle = .invalid,
            batch_pass: wgpu.ComputePassEncoderHandle = .invalid,
            /// The Params recorded at `beginBatch`. `endBatch` asserts
            /// `self.params` still equals this - the uniform is written ONCE at
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
            /// -- RECORDING (`beginRecording` .. `submitRecording`) --
            /// The open encoder every recorded dispatch goes into; the params TABLE (a GPU buffer
            /// its slots are uploaded to in ONE write, and copied from into `uniform` before each
            /// dispatch, on the GPU timeline); its CPU side; and the slots used.
            rec_enc: wgpu.CommandEncoderHandle = .invalid,
            rec_table: wgpu.BufferHandle = .invalid,
            rec_slots: []Params = &.{},
            rec_count: u32 = 0,
            /// Where the open recording's slots start: the table is a RING across recordings, so
            /// two recordings in one frame never write the same bytes of it (see `flushRecording`).
            rec_base: u32 = 0,
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
            /// Whether the copy in flight was encoded before an upload that replaced what it copies
            /// (`discardReadback`): when it lands it is released unread, and the next copy - encoded
            /// after the upload - is the first the mirror takes.
            discard_copy_in_flight: bool = false,
            /// Bytes the in-flight copy packs into `staging` (each field's first
            /// `element_count` elements, back to back), and that `element_count`.
            read_bytes: u32 = 0,
            read_count: usize = 0,
            /// Heap-allocated CPU readback buffer (the whole Buffers struct).
            /// Heap, NOT inline-by-value: Buffers can be megabytes (20k particles
            /// here ~ 1.3 MB), and an inline field makes the whole Compute value
            /// that large - a by-value `initGpu` return then overflows the wasm
            /// shadow stack in debug (release elides the copy, so it only crashes
            /// in debug). Allocated in initGpu, freed in deinit.
            /// None for a `.ranges` module (`kompute.Readback`), which reads with `readRange` instead.
            mirror: ?*Buffers,
            /// TIMINGS (`enableTimings`): a timestamp pool of two slots per kernel, its start and its end - 0 when
            /// the pipe does not time its kernels - and, per kernel, whether a dispatch wrote its slots since the last
            /// read.
            timestamp_pool: u32 = 0,
            kernel_timed: []bool = &.{},
            /// LENDING (`lendField`, `initGpuBorrowing`): how many of this pipe's buffers other pipes still borrow,
            /// and per field the loan count of the pipe this one borrowed it from - null for a buffer of its own.
            loans_out: u32 = 0,
            borrowed_from: []?*u32 = &.{},
        };

        fn ElemOf(comptime field: Field) type {
            return meta.Elem(meta.fieldInfo(Buffers, field).type);
        }

        /// CPU backend: zero GPU resources, instant. The kernel module's globals
        /// (`M.g.B` / `M.g.P`) ARE the storage - upload writes them, run loops.
        pub fn initCpu() Self {
            return .{ .backend = .cpu };
        }

        /// The same kernel, on a Web Worker: a compute fallback that does not freeze the
        /// frame. Needs an allocator (the GPU path does too) for the readback mirror and
        /// the job's payload.
        ///
        /// Where workers are unavailable - on the host, or in a sandboxed iframe that
        /// refuses `new Worker()` - `zimr.jobs` runs the kernel INLINE instead, so this
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
            @memset(asBytes(mirror), 0);
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
                const every_loan_back: bool = gp.loans_out == 0;
                assertf(every_loan_back, @src(), "deinit: {d} of this pipe's buffers are still lent", .{gp.loans_out});
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
                for (gp.field_bufs, gp.borrowed_from) |b, owner_loans| {
                    if (owner_loans) |loans| {
                        // A borrowed buffer goes back to its owner, who destroys it.
                        loans.* -= 1;
                        continue;
                    }
                    if (b != .invalid) {
                        wgpu.destroyBuffer(b);
                    }
                }
                gp.gpa.free(gp.borrowed_from);
                if (gp.uniform != .invalid) {
                    wgpu.destroyBuffer(gp.uniform);
                }
                // An open recording at teardown is a missing `submitRecording`: its encoder would
                // leak, and its dispatches never run.
                assertf(gp.rec_enc == .invalid, @src(), "deinit with a recording open (no submitRecording)", .{});
                if (gp.rec_table != .invalid) {
                    wgpu.destroyBuffer(gp.rec_table);
                }
                if (gp.rec_slots.len > 0) {
                    gp.gpa.free(gp.rec_slots);
                }
                if (gp.staging != .invalid) {
                    wgpu.destroyBuffer(gp.staging);
                }
                gp.gpa.free(gp.pipelines);
                gp.gpa.free(gp.kernel_names);
                gp.gpa.free(gp.bind_groups);
                gp.gpa.free(gp.kernel_used);
                gp.gpa.free(gp.kernel_last_n);
                if (gp.mirror) |mirror| {
                    gp.gpa.destroy(mirror);
                }
                destroyTimestampPool(gp);
                gp.gpa.free(gp.kernel_timed);
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
        /// One kernel entry, as the app embeds it.
        pub const KernelWgsl = struct {
            /// The entry's name: the kernel function's.
            name: [:0]const u8,
            /// The entry's shader: WGSL on the web; on the native host, the kernel file's SPIR-V, which holds every
            /// entry of the file. The import keeps its WGSL name on both platforms, and so does this field.
            wgsl: []const u8,
        };

        /// A field this pipe BORROWS from another rather than owns (`initGpuBorrowing`, `FieldLoan`).
        pub const Borrowed = struct {
            field: Field,
            loan: FieldLoan,
        };

        /// `initGpuBorrowing` with every field a buffer of the pipe's own.
        pub fn initGpu(
            gpa: Allocator,
            dev: wgpu.DeviceHandle,
            queue: wgpu.QueueHandle,
            kernels: []const KernelWgsl,
        ) !Self {
            const owns_every_field: []const Borrowed = &.{};
            return initGpuBorrowing(gpa, dev, queue, kernels, owns_every_field);
        }

        /// Lend `field`'s GPU buffer to another pipe, which binds it in place of a buffer of its own
        /// (`initGpuBorrowing`). Counted until the borrower's `deinit` gives it back; this pipe's `deinit` asserts
        /// that every loan came back. A GPU pipe only - a CPU pipe's fields are the module's globals.
        pub fn lendField(self: *Self, comptime field: Field) FieldLoan {
            assertf(self.backend == .gpu, @src(), "lendField: only a GPU pipe has buffers to lend", .{});
            const gp: *Gpu = &self.gpu.?;
            gp.loans_out += 1;
            const field_bytes: u64 = @sizeOf(@FieldType(Buffers, @tagName(field)));
            const field_buffer: wgpu.BufferHandle = gp.field_bufs[fieldIndex(@tagName(field))];
            const loan: FieldLoan = .{ .buffer = field_buffer, .bytes = field_bytes, .owner_loans = &gp.loans_out };
            return loan;
        }

        /// The loan `borrowed` holds for the field at `field_index`, if any.
        fn loanOfField(borrowed: []const Borrowed, field_index: usize) ?FieldLoan {
            for (borrowed) |entry| {
                const entry_index: usize = @backingInt(entry.field);
                if (entry_index == field_index) {
                    return entry.loan;
                }
            }
            return null;
        }

        /// THE GPU PIPE, with the fields `borrowed` bound to buffers other pipes lend (`lendField`) instead of buffers
        /// of its own - each lent buffer at least as large as the field.
        pub fn initGpuBorrowing(
            gpa: Allocator,
            dev: wgpu.DeviceHandle,
            queue: wgpu.QueueHandle,
            kernels: []const KernelWgsl,
            borrowed: []const Borrowed,
        ) !Self {
            assertf(kernels.len >= 1, @src(), "initGpu: need at least one kernel, got {d}", .{kernels.len});

            // WEBGPU'S STORAGE-BUFFER CEILING. `maxStorageBuffersPerShaderStage` has a
            // GUARANTEED FLOOR OF 8, and one binding is used by the uniform, so a kompute
            // module gets at most 8 storage buffers - one per `Buffers` field.
            //
            // Go over it and NOTHING COMPLAINS. No validation error, no console warning: the
            // bindings past the limit simply do not take, and every write a kernel makes to
            // them is silently discarded. The kernel still runs, still reads its other
            // buffers correctly, still produces a plausible-looking result.
            //
            // It cost a very long hunt. `fluid_sort` declares TEN buffers (pos, prev, vel,
            // delta, density, grid_counts, cell_start, pos2, vel2, prev2) while its twin
            // `fluid_gpu` declares exactly EIGHT - so one fluid worked and the other filled
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
            // Buffers field - the megastruct single-binding shape corrupted
            // on Adreno. Binding numbers are the ones kompute declares (below).
            var field_bufs: [field_count]wgpu.BufferHandle = undefined;
            const borrowed_from: []?*u32 = try gpa.alloc(?*u32, field_count);
            errdefer gpa.free(borrowed_from);
            @memset(borrowed_from, null);
            inline for (buffer_field_names, 0..) |fname, fi| {
                const field_bytes: u64 = @sizeOf(@FieldType(Buffers, fname));
                if (loanOfField(borrowed, fi)) |loan| {
                    // A lent buffer: bound as it is, never created or destroyed here.
                    assertf(loan.bytes >= field_bytes, @src(), "initGpuBorrowing: `" ++ fname ++
                        "` needs {d} bytes, and the lent buffer has {d}", .{ field_bytes, loan.bytes });
                    field_bufs[fi] = loan.buffer;
                    borrowed_from[fi] = loan.owner_loans;
                } else {
                    field_bufs[fi] = wgpu.createBuffer(dev, .{
                        .size = field_bytes,
                        .usage = .{ .storage = true, .copy_src = true, .copy_dst = true },
                        .label = "kbuf_" ++ fname,
                    });
                }
            }
            // * A FAILED INIT MUST NOT LEAK THEM. Everything below can fail, and the caller never
            // gets a `Self` to deinit - the smoke runner's lifecycle check saw exactly these,
            // buffer+7 per cycle.
            errdefer for (field_bufs, borrowed_from) |fb, owner_loans| {
                if (owner_loans == null) {
                    wgpu.destroyBuffer(fb);
                }
            };
            // The binding numbers kompute declares (`M.g.bindingOf`, `M.g.uniform_binding`). On the web the WGSL
            // carries the same numbers - spv2wgsl copies them from the SPIR-V - and reading them back must agree;
            // natively the kernels are SPIR-V, with no text to read.
            var bindings: [field_count]u32 = undefined;
            inline for (buffer_field_names, 0..) |fname, fi| {
                bindings[fi] = M.g.bindingOf(@field(Field, fname));
            }
            const uniform_binding: u32 = M.g.uniform_binding;
            // The kernels' form, shared by all of them (one build embeds one form): SPIR-V on the native host, WGSL
            // on the web.
            const kernels_are_spirv: bool = kernels.len > 0 and isSpirv(kernels[0].wgsl);
            if (!kernels_are_spirv) {
                const agrees: bool = wgslBindingsAgree(kernels, &bindings, uniform_binding);
                assertf(agrees, @src(), "initGpu: the WGSL's binding numbers differ from kompute's declared ones", .{});
            }
            const uniform: wgpu.BufferHandle = wgpu.createBuffer(dev, .{
                .size = @sizeOf(Params),
                .usage = .{ .uniform = true, .copy_dst = true },
                .label = "kompute_params",
            });
            // The staging buffer: the size of all of `Buffers` for the mirror, `staging_bytes` for ranges.
            const staging_size: u32 = if (reads_ranges) staging_bytes else buf_bytes;
            const staging: wgpu.BufferHandle = wgpu.createBuffer(dev, .{
                .size = staging_size,
                .usage = .{ .map_read = true, .copy_dst = true },
                .label = "kompute_staging",
            });
            // ---- Per-kernel bind groups (the structural fix) ----
            // Each kernel binds ONLY the Buffers fields it actually uses (plus
            // the Params uniform), not the whole struct. Why this matters: a
            // stock WebGPU device guarantees only 8 storage buffers per shader
            // stage, but a pipeline like the sort declares 10 Buffers fields. The
            // old shared mega-bind-group bound all 10 to every kernel, so every
            // pipeline tripped the limit - which we papered over by RAISING the
            // device's `maxStorageBuffersPerShaderStage` (a band-aid that fails on
            // any device that won't grant the raise).
            //
            // Per the WebGPU spec a pipeline's explicit layout only needs the
            // bindings the entry STATICALLY USES; declared-but-unused module-scope
            // storage vars may be omitted. Each kernel's WGSL declares all fields
            // (the kompute module aliases them all at module scope) but its body
            // references only some, so `usedFields` parses the body and we bind
            // just that subset: clearGrid -> {uniform, grid_counts} = 1 storage;
            // density -> ~5; none over 8. Result: the sort runs on a stock device
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
                // Which fields the kernel uses, from its WGSL; a SPIR-V kernel (the native host) lists every field -
                // a Vulkan layout may hold bindings its shader does not use.
                const used: [field_count]bool = if (kernels_are_spirv) @splat(true) else usedFields(k.wgsl);
                // Build this kernel's layout + bind-group entries together: the
                // uniform first (always present - the Params block any kernel may
                // read), then one entry per USED field at its global binding
                // number. `n` is the dense count we actually fill; the binding
                // NUMBERS can be sparse (e.g. {0, 1, 5}) and WebGPU is fine with
                // that - we just don't emit slots for fields this kernel skips.
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
                        assertUnreachable(
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
                // layout + module are no longer needed - release them per kernel.
                wgpu.destroyBindGroupLayout(bgl);
                wgpu.destroyPipelineLayout(pipeline_layout);
                wgpu.destroyShaderModule(module);
            }
            const mirror: ?*Buffers = if (reads_ranges) null else try gpa.create(Buffers);
            return .{
                .backend = .gpu,
                .gpu = .{
                    .gpa = gpa,
                    .dev = dev,
                    .queue = queue,
                    .field_bufs = field_bufs,
                    .borrowed_from = borrowed_from,
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
        /// The Buffers field names, in declaration order - the per-field
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

        /// The field indices in MEMORY order - which for a plain (auto-layout) `Buffers` is NOT
        /// declaration order: Zig sorts fields by alignment, so `sort_smoke`'s `[32]u32` counts
        /// land after its `[64]Vec2` arrays. The packed readback must walk fields in this order.
        /// Packed in declaration order, a field's packed offset could pass its real one, and the
        /// in-place unpack overwrote prefixes it had yet to move (counts came back as float bits).
        const fields_by_offset: [field_count]usize = blk: {
            var order: [field_count]usize = undefined;
            for (&order, 0..) |*o, fi| {
                o.* = fi;
            }
            for (1..field_count) |i| {
                var j: usize = i;
                while (j > 0 and @offsetOf(Buffers, buffer_field_names[order[j - 1]]) >
                    @offsetOf(Buffers, buffer_field_names[order[j]])) : (j -= 1)
                {
                    const t: usize = order[j];
                    order[j] = order[j - 1];
                    order[j - 1] = t;
                }
            }
            break :blk order;
        };

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
        /// both sides - so `kbuf_pos` matches `kbuf_pos[i]` but not `kbuf_pos2`.
        fn refsIdent(line: []const u8, ident: []const u8) bool {
            var start: usize = 0;
            while (indexOfPos(u8, line, start, ident)) |pos| {
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
        /// the entry statically uses (WebGPU spec) - which is precisely the set
        /// referenced in the body. Example: clearGrid's body is only
        /// `atomicStore(&kbuf_grid_counts[..], 0u)`, so this returns {grid_counts}
        /// and clearGrid binds 1 storage buffer instead of all 10.
        fn usedFields(wgsl: []const u8) [field_count]bool {
            var used: [field_count]bool = @splat(false);
            var it = splitScalar(u8, wgsl, '\n');
            while (it.next()) |line| {
                // Skip the `@binding(N) var<storage> kbuf_X: ...` declarations
                // (they list every field); we want USES, in the body.
                if (indexOf(u8, line, "@binding(") != null) {
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

        /// Whether the binding numbers in the kernels' WGSL headers - lines of the form
        /// `@group(0) @binding(N) var<storage, ...> kbuf_FIELD: ...` and `@binding(N) var<uniform>` -
        /// are the ones kompute declares (`bindings`, `uniform_binding`). spv2wgsl copies them from the
        /// SPIR-V, so they should be; this reads them back to be sure.
        ///
        /// Only what appears can be compared. A build compiles the entry points its page lists, and a
        /// buffer only the others use - or the uniform, when no listed entry point reads its parameters -
        /// is not in its WGSL at all. The layout is built from the declared numbers either way, so an
        /// absent binding is not a disagreement.
        fn wgslBindingsAgree(
            kernels: []const KernelWgsl,
            bindings: *const [field_count]u32,
            uniform_binding: u32,
        ) bool {
            for (kernels) |k| {
                var it = splitScalar(u8, k.wgsl, '\n');
                while (it.next()) |line| {
                    const bind_tag: []const u8 = "@binding(";
                    const bpos: usize = indexOf(u8, line, bind_tag) orelse continue;
                    const after: []const u8 = line[bpos + bind_tag.len ..];
                    const close: usize = indexOfScalar(u8, after, ')') orelse continue;
                    const num: u32 = parseInt(u32, after[0..close], 10) catch continue;
                    if (indexOf(u8, line, "var<uniform>") != null) {
                        if (num != uniform_binding) {
                            return false;
                        }
                        continue;
                    }
                    const name_tag: []const u8 = "kbuf_";
                    // A @binding storage decl that ISN'T `kbuf_<field>` can't be
                    // mapped to a Buffers field: it would be silently dropped from
                    // every kernel's layout and surface only as a cryptic Dawn
                    // "Binding doesn't exist" at pipeline creation. Trap here with
                    // the offending line instead.
                    assertf(
                        indexOf(u8, line, name_tag) != null,
                        @src(),
                        "compute storage binding not named kbuf_<field>: '{s}' — host cannot map it to a buffer",
                        .{trim(u8, line, " \t")},
                    );
                    const npos: usize = indexOf(u8, line, name_tag).?;
                    const name_rest: []const u8 = line[npos + name_tag.len ..];
                    const name_end: usize = indexOfScalar(u8, name_rest, ':') orelse continue;
                    const fname: []const u8 = name_rest[0..name_end];
                    var names_a_field: bool = false;
                    inline for (buffer_field_names, 0..) |bfname, fi| {
                        if (eql(u8, bfname, fname)) {
                            names_a_field = true;
                            if (num != bindings[fi]) {
                                return false;
                            }
                        }
                    }
                    // A buffer the WGSL binds but the kernel module does not declare would surface later as
                    // a pipeline the device refuses; name it here instead.
                    assertf(names_a_field, @src(), "compute storage binding kbuf_{s} names no Buffers field", .{fname});
                }
            }
            return true;
        }

        /// `upload` at an ELEMENT offset into the field, not at its start.
        ///
        /// * Two steps in one frame that upload their inputs to DISJOINT ranges of one field stay
        /// correct under any model of the queue - including one where every write in a frame lands
        /// before the frame's submission, as with a renderer's single frame encoder, where two writes
        /// to the same (buffer, offset) clobber each other. SuperTrack's world and policy steps each
        /// upload only their own region with this.
        pub fn uploadAt(
            self: *Self,
            comptime field: Field,
            offset: usize,
            data: []const ElemOf(field),
        ) void {
            assertf(
                offset + data.len <= @field(M.g.B, @tagName(field)).len,
                @src(),
                "uploadAt to '" ++ @tagName(field) ++ "': {d} + {d} elements exceeds capacity {d}",
                .{ offset, data.len, @field(M.g.B, @tagName(field)).len },
            );
            switch (self.backend) {
                .cpu => {
                    const dst: *@TypeOf(@field(M.g.B, @tagName(field))) = &@field(M.g.B, @tagName(field));
                    @memcpy(dst[offset..][0..data.len], data);
                },
                .worker => {
                    if (comptime @hasDecl(M, "kernels")) {
                        const wk: *Worker = &(self.worker orelse {
                            assertUnreachable(@src(), "uploadAt: .worker needs initWorker(gpa)", .{});
                            return;
                        });
                        const field_name: [:0]const u8 = @tagName(field);
                        const dst: *@TypeOf(@field(wk.mirror.*, field_name)) = &@field(wk.mirror.*, field_name);
                        @memcpy(dst[offset..][0..data.len], data);
                    }
                },
                .gpu => {
                    const fi: usize = fieldIndex(@tagName(field));
                    const byte_offset: u32 = @intCast(offset * @sizeOf(ElemOf(field)));
                    const gp: *Gpu = &self.gpu.?;
                    wgpu.queueWriteBuffer(gp.queue, gp.field_bufs[fi], byte_offset, sliceAsBytes(data));
                },
            }
        }

        pub fn upload(
            self: *Self,
            comptime field: Field,
            data: []const ElemOf(field),
        ) void {
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
                // mirror, and reads the answer back into it - it never touches `M.g.B` in
                // this address space at all.
                //
                // It used to share `.cpu`'s arm, on the reasoning that "the payload is
                // literally `asBytes(&M.g.B)`, so the staging area and the CPU's buffers are
                // the same memory - nothing to duplicate". That is true, and it is the bug:
                // `M.g.B` is a MODULE-LEVEL SINGLETON. A `.cpu` pipe's `run()` writes its
                // results there, and the next `.worker` dispatch would then ship those
                // results as its INPUT. Two live pipes on one module silently contaminate
                // each other - and `four_ways` exists precisely to run `.cpu`, `.worker` and
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
                        const field_name: [:0]const u8 = @tagName(field);
                        const dst: *@TypeOf(@field(wk.mirror.*, field_name)) = &@field(wk.mirror.*, field_name);
                        @memcpy(dst[0..data.len], data);
                    }
                },
                .gpu => {
                    const fi: usize = fieldIndex(@tagName(field));
                    wgpu.queueWriteBuffer(self.gpu.?.queue, self.gpu.?.field_bufs[fi], 0, sliceAsBytes(data));
                },
            }
        }

        /// Open a single-pass batch: every following `run` encodes into one
        /// compute pass until `endBatch` submits it.
        ///
        /// Pass this batch's `Params` HERE. They're written to the uniform once,
        /// and every batched dispatch shares them - the uniform is NOT re-written
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
            wgpu.queueWriteBuffer(gp.queue, gp.uniform, 0, asBytes(&self.params));
            gp.uniform_synced = self.params;
        }

        /// Slots in the params table: past this many dispatches a recording submits what it has
        /// and carries on in a new one.
        const recording_slots: u32 = 2048;

        /// -- MANY DISPATCHES, ONE SUBMISSION, EACH WITH ITS OWN PARAMS --
        ///
        /// Until `submitRecording`, every `run` is RECORDED rather than submitted: its params go
        /// into a slot of a params table, a copy of that slot into the uniform is encoded before
        /// it, and the dispatch follows in its own compute pass - all in one command encoder,
        /// submitted once, with the table uploaded in one `writeBuffer` just before (queue writes
        /// land before the submission that follows them). Unbatched `run` is one submission per
        /// dispatch - and a per-layer SuperTrack iteration is ~1,050 dispatches (a fused one, 8).
        /// `beginBatch` shares ONE params value, so it cannot carry per-dispatch offsets.
        /// Pipelines, bind groups and WGSL are untouched: the uniform is still the uniform,
        /// filled on the GPU timeline instead.
        ///
        /// * Upload a recording's inputs BEFORE `beginRecording`, or at least before the dispatches
        /// that read them: a `writeBuffer` issued mid-recording lands before the WHOLE recording
        /// executes, not between its dispatches. On the CPU and worker backends `run` executes
        /// at once, as always - the same results, so every CPU-twin check covers this path.
        pub fn beginRecording(self: *Self) void {
            if (self.backend != .gpu) {
                return;
            }
            const gp: *Gpu = &self.gpu.?;
            const idle: bool = gp.rec_enc == .invalid and gp.batch_enc == .invalid;
            assertf(idle, @src(), "beginRecording: a recording or batch is already open", .{});
            // Each half of the table guarded by its OWN existence: allocating the CPU side whenever
            // the GPU side was missing would leak it on a retry.
            if (gp.rec_slots.len == 0) {
                gp.rec_slots = gp.gpa.alloc(Params, recording_slots) catch {
                    // Without the CPU side there is nothing to upload: stay unrecorded (correct,
                    // only slower).
                    return;
                };
            }
            if (gp.rec_table == .invalid) {
                gp.rec_table = wgpu.createBuffer(gp.dev, .{
                    .size = recording_slots * @sizeOf(Params),
                    .usage = .{ .copy_src = true, .copy_dst = true },
                    .label = "kompute_params_table",
                });
            }
            gp.rec_enc = wgpu.createCommandEncoder(gp.dev);
            gp.rec_count = 0;
        }

        /// Upload the params table and submit everything recorded since `beginRecording`.
        pub fn submitRecording(self: *Self) void {
            if (self.backend != .gpu) {
                return;
            }
            const gp: *Gpu = &self.gpu.?;
            if (gp.rec_enc == .invalid) {
                return; // beginRecording stayed unrecorded (no table): nothing is open
            }
            flushRecording(gp);
        }

        fn flushRecording(gp: *Gpu) void {
            if (gp.rec_count > 0) {
                const used: []const Params = gp.rec_slots[gp.rec_base..][0..gp.rec_count];
                const at: u32 = gp.rec_base * @sizeOf(Params);
                wgpu.queueWriteBuffer(gp.queue, gp.rec_table, at, sliceAsBytes(used));
            }
            const cmd: wgpu.CommandBufferHandle = wgpu.finishCommandEncoder(gp.rec_enc);
            submitDispatch(gp, cmd);
            gp.rec_enc = .invalid;
            // * The next recording continues AFTER these slots. Restarting at slot 0 made two
            // recordings in a frame (SuperTrack's world and policy steps) write the table's same
            // bytes twice: correct by WebGPU's queue ordering (each write lands before the
            // submission after it), but a clobber under the smoke runner's frame model, and
            // needlessly fragile. A ring costs nothing.
            gp.rec_base = (gp.rec_base + gp.rec_count) % recording_slots;
            gp.rec_count = 0;
            // The uniform now holds the LAST slot's params, written on the GPU: the host's record
            // of what it holds is stale, and an unbatched `run` must upload its own again.
            gp.uniform_synced = null;
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
            // re-upload). That's a silent-stale bug - flag it by name.
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
        /// numbers), and the last dispatch width it ran at. A debugging aid - call
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

        /// Whether this module reads ranges rather than keeping a mirror (`kompute.Readback`), and its staging buffer's
        /// bytes when it does. A module whose `config` is a plain struct literal without the fields keeps the mirror.
        const reads_ranges: bool = @hasField(@TypeOf(M.config), "readback") and M.config.readback == .ranges;
        const staging_bytes: u32 = if (@hasField(@TypeOf(M.config), "staging_bytes")) M.config.staging_bytes else 0;
        comptime {
            // A GPU copy moves whole 4-byte words: the staging buffer's chunks must be a positive multiple of 4.
            const staging_fits_words: bool = staging_bytes > 0 and staging_bytes % 4 == 0;
            if (reads_ranges and !staging_fits_words) {
                @compileError("a `.ranges` module's `staging_bytes` must be a positive multiple of 4");
            }
        }

        /// Whether this module recovers its index from rows of workgroups (`kompute.Config.large_dispatch`). A module
        /// whose `config` is a plain struct literal without the field dispatches one row.
        const large_dispatch: bool = @hasField(@TypeOf(M.config), "large_dispatch") and M.config.large_dispatch;

        /// Run kernel `name` over exactly `n` invocations. `n` is the dispatch
        /// width FOR THIS CALL - explicit, because a multi-kernel pipeline mixes
        /// widths (clearGrid over grid_cells, the particle kernels over
        /// num_particles, prefixSum over 1). Passing it per call kills the old
        /// footgun of a mutable `pipe.count` you had to re-set between kernels:
        /// forget, and a kernel silently dispatched the PREVIOUS kernel's width.
        ///   CPU: a plain `for id in 0..n` loop calling the kernel (the dual-shape
        ///        source runs as ordinary Zig).
        ///   GPU: dispatch `ceil(n / config.workgroup)` workgroups - into the open
        ///        batch pass if one is active, else a fresh single-dispatch submit.
        /// Readback is unaffected by `n`; it slices by `element_count` (set once).
        pub fn run(self: *Self, comptime name: []const u8, n: u32) void {
            const no_push_constants: []const u8 = &.{};
            self.dispatchKernel(name, n, false, no_push_constants);
        }

        /// `run`, with PUSH CONSTANTS for this dispatch (`kompute`'s `PushConstants`): `values` are written into the
        /// command stream just before the dispatch, so each dispatch of a batch carries its own - what a kernel run
        /// once for each level of a tree needs, the level pushed every time:
        ///
        ///     one batch:   [ push level 0 | dispatch ]  [ push level 1 | dispatch ]  [ push level 2 | dispatch ]
        ///
        /// On the CPU twin the values go into the module's variable the kernel loop reads (`g.push()`). Native only:
        /// WebGPU has no push constants, so a browser build that calls this does not compile.
        pub fn runPushed(
            self: *Self,
            comptime name: []const u8,
            n: u32,
            values: M.PushConstants,
        ) void {
            if (comptime host.is_browser) {
                @compileError("runPushed: push constants are native only, and WebGPU has none");
            }
            M.g.pushed_values = values;
            const values_bytes: []const u8 = asBytes(&values);
            self.dispatchKernel(name, n, true, values_bytes);
        }

        /// Push constants for the pass's next dispatch (`wgpu_vulkan.computePassSetPushConstants`): nothing to do
        /// without a GPU.
        fn pushValues(pass: wgpu.ComputePassEncoderHandle, bytes: []const u8) void {
            if (comptime !host.has_gpu) {
                return;
            }
            wgpu.vulkan_host.computePassSetPushConstants(@backingInt(pass), bytes.ptr, bytes.len);
        }

        /// TIME THIS PIPE'S KERNELS ON THE GPU. From now on every dispatch is bracketed by two timestamps - the GPU's
        /// clock at the top of the pipeline before it and at the bottom after it, in the kernel's two slots of a pool -
        /// and `kernelTimings` reads each kernel's last duration:
        ///
        ///     kernel k's slots:   2k = start, 2k + 1 = end
        ///     a dispatch:         [ reset 2k, 2k + 1 ] [ write 2k at the top ] [ dispatch ]
        ///                         [ write 2k + 1 at the bottom ]
        ///
        /// Native only - Vulkan's timestamps; WebGPU's cover render passes alone - and a pipe on the CPU has nothing to
        /// time. The device must write timestamps in compute (`ComputeCapabilities.timestamps_in_compute`).
        pub fn enableTimings(self: *Self) Allocator.Error!void {
            if (comptime host.is_browser) {
                @compileError("enableTimings: GPU timestamps for compute are native only");
            }
            if (self.backend != .gpu) {
                return;
            }
            const gp: *Gpu = &self.gpu.?;
            if (gp.timestamp_pool != 0) {
                return;
            }
            const capabilities: wgpu.vulkan_host.ComputeCapabilities = wgpu.computeCapabilities();
            const no_timestamps: []const u8 = "enableTimings: this device writes no compute timestamps";
            assertf(capabilities.timestamps_in_compute, @src(), no_timestamps, .{});
            const kernel_count: usize = gp.kernel_names.len;
            gp.kernel_timed = try gp.gpa.alloc(bool, kernel_count);
            @memset(gp.kernel_timed, false);
            const slot_count: u32 = @intCast(2 * kernel_count);
            gp.timestamp_pool = wgpu.vulkan_host.createTimestampPool(slot_count);
        }

        /// One kernel's last time on the GPU (`kernelTimings`).
        pub const KernelTiming = struct {
            name: []const u8,
            microseconds: f64,
        };

        /// Each kernel's last duration on the GPU, in microseconds, into `timings` in the pipe's kernel order - zero
        /// for a kernel not dispatched since the last read, and for every kernel of a pipe without timings. A duration
        /// is the difference of the kernel's two timestamps, in ticks, times the device's tick in nanoseconds. It waits
        /// until the dispatches have run, so not inside an open batch or recording, whose commands are not yet
        /// submitted.
        pub fn kernelTimings(self: *Self, timings: *[M.kernels.len]KernelTiming) void {
            if (comptime host.is_browser) {
                @compileError("kernelTimings: GPU timestamps for compute are native only");
            }
            for (timings) |*timing| {
                timing.* = .{ .name = "", .microseconds = 0 };
            }
            if (self.backend != .gpu) {
                return;
            }
            const gp: *Gpu = &self.gpu.?;
            if (gp.timestamp_pool == 0) {
                return;
            }
            const outside_batch: bool = gp.batch_enc == .invalid and gp.rec_enc == .invalid;
            assertf(outside_batch, @src(), "kernelTimings inside an open batch or recording", .{});
            const tick_nanoseconds: f64 = wgpu.computeCapabilities().timestamp_period_ns;
            for (gp.kernel_names, gp.kernel_timed, timings, 0..) |name, *was_timed, *timing, kernel_index| {
                timing.name = name;
                if (!was_timed.*) {
                    continue;
                }
                var ticks: [2]u64 = undefined;
                const first_slot: u32 = @intCast(2 * kernel_index);
                const answered: bool = wgpu.vulkan_host.timestampPoolRead(gp.timestamp_pool, first_slot, 2, &ticks);
                if (answered) {
                    // A clock with fewer than 64 valid bits wraps: the difference wraps with it.
                    const elapsed_ticks: u64 = ticks[1] -% ticks[0];
                    const elapsed_nanoseconds: f64 = float64(elapsed_ticks) * tick_nanoseconds;
                    timing.microseconds = elapsed_nanoseconds / 1000.0;
                }
                was_timed.* = false;
            }
        }

        /// With timings on: kernel `kernel_index`'s two slots reset, and the GPU's clock written into the first, at the
        /// top of the pipeline, before the dispatch that follows. Nothing on the web or without a GPU.
        fn timeKernelStart(
            gp: *Gpu,
            pass: wgpu.ComputePassEncoderHandle,
            kernel_index: usize,
        ) void {
            if (comptime host.is_browser or !host.has_gpu) {
                return;
            }
            if (gp.timestamp_pool == 0) {
                return;
            }
            const pass_id: u32 = @backingInt(pass);
            const start_slot: u32 = @intCast(2 * kernel_index);
            wgpu.vulkan_host.computePassResetTimestamps(pass_id, gp.timestamp_pool, start_slot, 2);
            wgpu.vulkan_host.computePassWriteTimestamp(pass_id, gp.timestamp_pool, start_slot, false);
        }

        /// With timings on: the GPU's clock written into kernel `kernel_index`'s second slot, at the bottom of the
        /// pipeline, once the dispatch before has finished.
        fn timeKernelEnd(
            gp: *Gpu,
            pass: wgpu.ComputePassEncoderHandle,
            kernel_index: usize,
        ) void {
            if (comptime host.is_browser or !host.has_gpu) {
                return;
            }
            if (gp.timestamp_pool == 0) {
                return;
            }
            const pass_id: u32 = @backingInt(pass);
            const end_slot: u32 = @intCast(2 * kernel_index + 1);
            wgpu.vulkan_host.computePassWriteTimestamp(pass_id, gp.timestamp_pool, end_slot, true);
            gp.kernel_timed[kernel_index] = true;
        }

        /// The timings' pool released with the pipe.
        fn destroyTimestampPool(gp: *Gpu) void {
            if (comptime host.is_browser or !host.has_gpu) {
                return;
            }
            if (gp.timestamp_pool != 0) {
                wgpu.vulkan_host.timestampPoolDestroy(gp.timestamp_pool);
                gp.timestamp_pool = 0;
            }
        }

        /// `run` and `runPushed`'s body: `pushes` (compile-time, so a module that never pushes never reaches the
        /// native call) says whether `push_bytes` go into the pass before the dispatch.
        fn dispatchKernel(
            self: *Self,
            comptime name: []const u8,
            n: u32,
            comptime pushes: bool,
            push_bytes: []const u8,
        ) void {
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
                        // ** A LEAN KERNEL TAKES THE RAW INDEX, a stock one takes a `Ctx`. The
                        // signature is the discriminator, so a file can mix both forms and
                        // neither has to declare which it is. Without this the CPU driver only
                        // spoke the `Ctx` dialect, and `installKernelLean` compiled but could
                        // never be run on the host - half a merge.
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
                //      - as the GPU arm already does, so an app written for `.gpu` needs
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
                    // this arm - an untaken comptime `if` is never analyzed, so none of
                    // the jobs machinery is linked. Selecting `.worker` requires
                    // `initWorker`, which is a compile error without it.
                    if (comptime @hasDecl(M, "kernels")) {
                        const wk: *Worker = &(self.worker orelse {
                            assertUnreachable(@src(), "run('" ++ name ++ "'): .worker needs initWorker(gpa)", .{});
                            return;
                        });
                        if (wk.job.inFlight()) {
                            return; // still working on the last one - see (2) above
                        }
                        wk.job = komputeRegistry(M).submit(
                            wk.gpa,
                            komputeKernel(M, name),
                            .{ .n = n, .params = self.params },
                            asBytes(wk.mirror), // OUR state, not the module's
                        ) catch |err| blk: {
                            std.log.err("Compute.run('" ++ name ++ "') on .worker: {s}", .{@errorName(err)});
                            break :blk .{};
                        };
                    }
                },
                .gpu => {
                    const gp: *Gpu = &self.gpu.?;
                    const workgroups: u32 = @divCeil(n, M.config.workgroup);
                    // More than one row of workgroups only for a module that recovers its index from the rows.
                    const fits_one_row: bool = workgroups <= max_workgroups_per_dimension;
                    assertf(
                        fits_one_row or large_dispatch,
                        @src(),
                        "run('" ++ name ++ "'): {d} workgroups, past {d} - a module dispatching more sets " ++
                            "`config.large_dispatch`",
                        .{ workgroups, max_workgroups_per_dimension },
                    );
                    const grid: DispatchGrid = dispatchGrid(workgroups);
                    // Find this kernel's slot so we get BOTH its pipeline and its
                    // own bind group - each kernel binds a different subset of the
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
                    if (gp.rec_enc != .invalid) {
                        // Recording: this dispatch's params into the next table slot, a copy of
                        // that slot into the uniform, and the dispatch in its own pass - all in
                        // the ONE open encoder. The copies execute in order on the GPU timeline,
                        // so every dispatch sees exactly its own params.
                        if (gp.rec_base + gp.rec_count == recording_slots) {
                            // The ring's end: submit what is recorded, carry on from its start.
                            flushRecording(gp);
                            gp.rec_base = 0;
                            gp.rec_enc = wgpu.createCommandEncoder(gp.dev);
                        }
                        const slot: u32 = gp.rec_base + gp.rec_count;
                        gp.rec_slots[slot] = self.params;
                        const size: u32 = @sizeOf(Params);
                        wgpu.copyBufferToBuffer(gp.rec_enc, gp.rec_table, slot * size, gp.uniform, 0, size);
                        const rp: wgpu.ComputePassEncoderHandle = compute_pass.begin(gp.rec_enc);
                        compute_pass.setPipeline(rp, pipeline);
                        compute_pass.setBindGroup(rp, 0, bind_group);
                        if (comptime pushes) {
                            pushValues(rp, push_bytes);
                        }
                        timeKernelStart(gp, rp, ki);
                        compute_pass.dispatchWorkgroups(rp, .{ .x = grid.x, .y = grid.y });
                        timeKernelEnd(gp, rp, ki);
                        compute_pass.end(rp);
                        gp.rec_count += 1;
                        return;
                    }
                    if (gp.batch_enc != .invalid) {
                        // Open batch: encode into the shared pass. Params were
                        // written once at beginBatch (all batched dispatches share
                        // them). The bind group is set PER DISPATCH now - adjacent
                        // kernels bind different buffer subsets, so it can't be
                        // hoisted to beginBatch the way the old shared one was.
                        compute_pass.setPipeline(gp.batch_pass, pipeline);
                        compute_pass.setBindGroup(gp.batch_pass, 0, bind_group);
                        if (comptime pushes) {
                            pushValues(gp.batch_pass, push_bytes);
                        }
                        timeKernelStart(gp, gp.batch_pass, ki);
                        compute_pass.dispatchWorkgroups(gp.batch_pass, .{ .x = grid.x, .y = grid.y });
                        timeKernelEnd(gp, gp.batch_pass, ki);
                        return;
                    }
                    self.syncParamsUniform(gp);
                    const enc: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(gp.dev);
                    const cp: wgpu.ComputePassEncoderHandle = compute_pass.begin(enc);
                    compute_pass.setPipeline(cp, pipeline);
                    compute_pass.setBindGroup(cp, 0, bind_group);
                    if (comptime pushes) {
                        pushValues(cp, push_bytes);
                    }
                    timeKernelStart(gp, cp, ki);
                    compute_pass.dispatchWorkgroups(cp, .{ .x = grid.x, .y = grid.y });
                    timeKernelEnd(gp, cp, ki);
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
        /// frame-delayed - returns LAST frame's mapped data and kicks off this
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

        /// The bytes of a field's first `count` elements (the whole field when it has fewer),
        /// rounded up to the 4 bytes a buffer copy requires.
        fn prefixBytes(comptime fname: []const u8, count: usize) u32 {
            const F = @FieldType(Buffers, fname);
            const whole: u64 = @sizeOf(F);
            if (@typeInfo(F) != .array) {
                return @intCast(whole);
            }
            const elem: u64 = @sizeOf(@typeInfo(F).array.child);
            const len: u64 = @typeInfo(F).array.len;
            const bytes: u64 = @min(@as(u64, count), len) * elem;
            return @intCast(@min(whole, @divCeil(bytes, 4) * 4));
        }

        /// The packed copy sits at the mirror's start, its fields in MEMORY order
        /// (`fields_by_offset`); move each field's prefix up to the field's own offset. LAST
        /// FIELD FIRST: in memory order a packed offset never exceeds the real one, so a
        /// destination only ever covers bytes already moved or never used.
        fn unpackPrefixes(mirror_bytes: []u8, count: usize) void {
            var packed_ends: [field_count]u32 = undefined;
            var at: u32 = 0;
            inline for (fields_by_offset, 0..) |fi, k| {
                at += prefixBytes(buffer_field_names[fi], count);
                packed_ends[k] = at;
            }
            comptime var k: usize = field_count;
            inline while (k > 0) {
                k -= 1;
                const fname: []const u8 = buffer_field_names[fields_by_offset[k]];
                const bytes: usize = @intCast(prefixBytes(fname, count));
                const from: usize = @intCast(packed_ends[k] - bytes);
                const to: usize = @offsetOf(Buffers, fname);
                if (bytes > 0 and from != to) {
                    std.mem.copyBackwards(u8, mirror_bytes[to..][0..bytes], mirror_bytes[from..][0..bytes]);
                }
            }
        }

        /// Forgets what the readback holds, and the copy in flight if there is one: from here, `readLatest` returns
        /// null until a copy encoded AFTER this call has landed. For a caller that has just replaced buffers by
        /// upload - a learner resumed from a saved state: a copy encoded before the upload would bring back exactly
        /// what the upload replaced, and anything reading the readback (a mirror of the weights) would go back to it.
        ///
        /// On the CPU backend the buffers are the module's own and every read is current: nothing to forget. On the
        /// worker backend an upload writes the readback's own mirror, so the readback holds the upload already; a job
        /// still in flight would overwrite it on landing, and is not guarded here - no learner runs on that backend.
        pub fn discardReadback(self: *Self) void {
            switch (self.backend) {
                .cpu, .worker => {},
                .gpu => {
                    const gp: *Gpu = &self.gpu.?;
                    gp.have_read = false;
                    gp.discard_copy_in_flight = gp.read != .invalid;
                },
            }
        }

        /// A RANGE OF ONE FIELD, read back now: `destination.len` elements of `field` from element `first`, into
        /// `destination`. CPU: copied from the module's globals. GPU - a `.ranges` module (`kompute.Readback`): each
        /// chunk of up to `staging_bytes` is copied into the staging buffer by a command submitted after every dispatch
        /// so far, and waited for, so the range holds what every earlier dispatch wrote:
        ///
        ///     field   [ .......... first [ chunk 0 | chunk 1 | chunk 2 ] .......... ]
        ///                                    |          |          |
        ///     staging                     [ one chunk at a time ] -> destination, in order
        ///
        /// Not inside an open batch or recording, whose dispatches are not yet submitted. Native only: the wait is a
        /// poll of the device's timeline, which a browser cannot do.
        pub fn readRange(
            self: *Self,
            comptime field: Field,
            first: u32,
            destination: []ElemOf(field),
        ) void {
            const Element: type = ElemOf(field);
            const field_length: usize = @field(M.g.B, @tagName(field)).len;
            const end: usize = @as(usize, first) + destination.len;
            assertf(end <= field_length, @src(), "readRange: elements {d}..{d} of a field of {d}", .{
                first,
                end,
                field_length,
            });
            switch (self.backend) {
                .cpu => {
                    const source: []const Element = @field(M.g.B, @tagName(field))[first..end];
                    @memcpy(destination, source);
                },
                .worker => {
                    assertUnreachable(@src(), "readRange: a worker pipe reads through readLatest", .{});
                },
                .gpu => {
                    if (comptime host.is_browser) {
                        @compileError("readRange waits for the GPU, which a browser cannot: `.ranges` is native only");
                    }
                    if (comptime @sizeOf(Element) % 4 != 0) {
                        @compileError("readRange: the GPU copies whole 4-byte words, and `" ++ @tagName(field) ++
                            "` holds " ++ @typeName(Element));
                    }
                    assertf(reads_ranges, @src(), "readRange on a `.mirror` module: use readLatest", .{});
                    const gp: *Gpu = &self.gpu.?;
                    const outside_batch: bool = gp.batch_enc == .invalid and gp.rec_enc == .invalid;
                    assertf(outside_batch, @src(), "readRange inside an open batch or recording", .{});
                    const field_buffer: wgpu.BufferHandle = gp.field_bufs[fieldIndex(@tagName(field))];
                    const destination_bytes: []u8 = sliceAsBytes(destination);
                    // The copy's offsets are 32-bit: the range must end within the field's first 4 GB.
                    const first_byte_wide: u64 = @as(u64, first) * @sizeOf(Element);
                    const end_byte_wide: u64 = first_byte_wide + destination_bytes.len;
                    const within_32_bits: bool = end_byte_wide <= zm.maxInt(u32);
                    assertf(within_32_bits, @src(), "readRange: bytes up to {d}, past a copy's 32-bit offsets", .{
                        end_byte_wide,
                    });
                    const first_byte: u32 = @intCast(first_byte_wide);
                    var copied: u32 = 0;
                    const total: u32 = @intCast(destination_bytes.len);
                    while (copied < total) {
                        const chunk: u32 = @min(staging_bytes, total - copied);
                        const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(gp.dev);
                        wgpu.copyBufferToBuffer(encoder, field_buffer, first_byte + copied, gp.staging, 0, chunk);
                        const commands: wgpu.CommandBufferHandle = wgpu.finishCommandEncoder(encoder);
                        wgpu.queueSubmit(gp.queue, commands);
                        const read: wgpu.BufferRead = wgpu.bufferReadStart(gp.staging, chunk);
                        while (!wgpu.bufferReadPoll(read)) {
                            std.atomic.spinLoopHint();
                        }
                        wgpu.bufferReadInto(read, destination_bytes[copied..][0..chunk]);
                        wgpu.bufferReadRelease(read);
                        copied += chunk;
                    }
                },
            }
        }

        pub fn readLatest(self: *Self, comptime field: Field) ?[]const ElemOf(field) {
            // Variable-count fields (pos/vel/...) are sized to capacity and slice to
            // the live `element_count`; fixed fields (grid_counts, cell_start) must
            // slice to THEIR OWN array length, never the particle count - else
            // grid_counts (grid_cells long) overruns the next field. Clamp to the
            // lesser of the two.
            const arr_len: usize = @field(M.g.B, @tagName(field)).len;
            const n: usize = @min(self.element_count, arr_len);
            switch (self.backend) {
                .cpu => {
                    return @field(M.g.B, @tagName(field))[0..n];
                },
                // Same contract as the GPU arm: null until it lands, then the data -
                // out of our OWN mirror, never out of `M.g.B`, so a `.cpu` pipe on the
                // same module keeps its answer.
                .worker => {
                    if (comptime @hasDecl(M, "kernels")) {
                        const wk: *Worker = &(self.worker orelse return null);
                        if (wk.job.poll()) |maybe_bytes| {
                            if (maybe_bytes) |bytes| {
                                if (bytes.len == @sizeOf(Buffers)) {
                                    @memcpy(asBytes(wk.mirror), bytes);
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
                    const keeps_a_mirror: bool = !reads_ranges;
                    const no_mirror: []const u8 = "readLatest on a `.ranges` module, which has no mirror: readRange";
                    assertf(keeps_a_mirror, @src(), no_mirror, .{});
                    const gp: *Gpu = &self.gpu.?;
                    const copy_has_landed: bool = gp.read != .invalid and wgpu.bufferReadPoll(gp.read);
                    if (copy_has_landed and gp.discard_copy_in_flight) {
                        // A copy of what an upload has since replaced (`discardReadback`): released
                        // unread. The block below encodes a fresh one, after the upload.
                        wgpu.bufferReadRelease(gp.read);
                        gp.read = .invalid;
                        gp.discard_copy_in_flight = false;
                    } else if (copy_has_landed) {
                        const mirror_bytes: []u8 = asBytes(gp.mirror.?);
                        wgpu.bufferReadInto(gp.read, mirror_bytes[0..gp.read_bytes]);
                        unpackPrefixes(mirror_bytes, gp.read_count);
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
                        // ** ONLY WHAT `readLatest` CAN RETURN: each field's first
                        // `element_count` elements, packed back to back. This copied every field
                        // WHOLE - 7 MiB a readback for the zn_mlp kit's 1 MiB fields, mapped and
                        // copied into wasm memory up to 60 times a second, to return 6 KB of
                        // weights. The data a caller sees is unchanged: it was always sliced to
                        // `element_count`.
                        const count: usize = self.element_count;
                        const enc: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(gp.dev);
                        // In MEMORY order, which `unpackPrefixes` relies on (`fields_by_offset`).
                        var packed_at: u32 = 0;
                        inline for (fields_by_offset) |fi| {
                            const bytes: u32 = prefixBytes(buffer_field_names[fi], count);
                            if (bytes > 0) {
                                wgpu.copyBufferToBuffer(enc, gp.field_bufs[fi], 0, gp.staging, packed_at, bytes);
                            }
                            packed_at += bytes;
                        }
                        const cmd: wgpu.CommandBufferHandle = wgpu.finishCommandEncoder(enc);
                        wgpu.queueSubmit(gp.queue, cmd);
                        gp.read_bytes = packed_at;
                        gp.read_count = count;
                        if (packed_at > 0) {
                            gp.read = wgpu.bufferReadStart(gp.staging, packed_at);
                        } else {
                            // Nothing to return (element_count 0): the copy is trivially complete.
                            gp.mirrored = gp.copy_at;
                            gp.have_read = true;
                        }
                    }
                    if (!gp.have_read) {
                        return null;
                    }
                    return @field(gp.mirror.?.*, @tagName(field))[0..n];
                },
            }
        }
    };
}

test "Compute .worker runs the SAME kernel and gets the SAME answer" {
    // The claim of the .worker backend, checked on the host: one kernel source, two
    // backends, identical results. No browser and no wasm needed - with no worker pool,
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

    var wk: Compute(M) = try .initWorker(testing_allocator);
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

test "Compute .worker OWNS its state - two live pipes on one module cannot contaminate each other" {
    // The property that makes the inline fallback HONEST.
    //
    // In a real worker, `M.g.B` is that worker's private memory. On the inline path there
    // is no worker, so the kernel runs in the app's own address space - and without the
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
    var wk: Compute(M) = try .initWorker(testing_allocator);
    defer wk.deinit();
    wk.element_count = 4;
    wk.params = .{ .add = 100 };
    wk.upload(.data, &[_]u32{ 10, 20, 30, 40 });
    wk.run("bump", 4);

    // It computed over ITS OWN input - not the CPU pipe's {101..104}.
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
    // CPU path - the DSL only generates this shape; here we hand-roll it).
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
    // from silently rotting - a green build otherwise wouldn't cover it.
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
            g.B.pos[c.id] = g.B.pos[c.id] + g.B.vel[c.id] * splat2(c.params.dt);
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
    // layout (built by the kbuf_ scan) only carries binding 0 - so binding 1 is
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
    // layout (per the WebGPU "statically used" rule) - must not false-fire.
    const unused: []const u8 =
        \\@group(0) @binding(0) var<uniform> P: S8;
        \\@group(0) @binding(5) var<storage, read_write> kbuf_spare: array<u32>;
        \\fn k() { let _x: S8 = P; }
    ;
    try expect(unboundUsedBinding(unused, &.{0}) == null);
}

test "Compute readback: each field's element_count prefix, packed, unpacks to its own offset" {
    // The GPU arm copies only each field's first `element_count` elements, back to back, into
    // the staging buffer, reads that into the mirror's START, and moves each prefix up to its
    // field's offset, last field first. Pack exactly as the encode does, unpack, and every
    // field's prefix must hold its own values - including a field shorter than the count.
    const M = struct {
        pub const config = .{ .max = 64, .workgroup = 64 };
        pub const Buffers = extern struct { a: [16]f32, b: [8]u32, c: [16]f32 };
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
    };
    const C = Compute(M);
    const count: usize = 10; // past b's 8: b is copied whole
    var source: M.Buffers = undefined;
    for (&source.a, 0..) |*v, i| {
        v.* = 100.0 + float(i);
    }
    for (&source.b, 0..) |*v, i| {
        v.* = 200 + @as(u32, @intCast(i));
    }
    for (&source.c, 0..) |*v, i| {
        v.* = 300.0 + float(i);
    }
    var mirror: M.Buffers = zeroes(M.Buffers);
    const bytes: []u8 = asBytes(&mirror);
    // Pack as the encode does.
    var at: usize = 0;
    inline for (C.fields_by_offset) |fi| {
        const fname: []const u8 = C.buffer_field_names[fi];
        const n: usize = C.prefixBytes(fname, count);
        @memcpy(bytes[at..][0..n], asBytes(&@field(source, fname))[0..n]);
        at += n;
    }
    try expectEqual(@as(usize, 10 * 4 + 8 * 4 + 10 * 4), at);
    C.unpackPrefixes(bytes, count);
    try expectEqualSlices(f32, source.a[0..10], mirror.a[0..10]);
    try expectEqualSlices(u32, source.b[0..8], mirror.b[0..8]);
    try expectEqualSlices(f32, source.c[0..10], mirror.c[0..10]);
}

test "Compute readback: a plain Buffers that Zig REORDERS unpacks every field intact" {
    // `sort_smoke`'s shape: a plain struct whose `[N]u32` sits between `[N]Vec2`s in the source,
    // and which Zig moves after them in memory. Packed in declaration order, `visc` landed on
    // `counts`' packed bytes before they were moved, and `counts` came back as float bits - the
    // integer overflow in `sort_smoke.checkStages`. The count covers every field whole, which is
    // when packed and real offsets sit closest and the old order went wrong.
    const M = struct {
        pub const config = .{ .max = 8, .workgroup = 8 };
        pub const Buffers = struct { pos: [8]Vec2, counts: [4]u32, visc: [8]Vec2 };
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
    };
    const C = Compute(M);
    // The precondition this test exists for: memory order is not declaration order.
    try expect(@offsetOf(M.Buffers, "counts") > @offsetOf(M.Buffers, "visc"));
    const count: usize = 8;
    var source: M.Buffers = undefined;
    for (&source.pos, &source.visc, 0..) |*p, *v, i| {
        p.* = .{ 100.0 + float(i), 150.0 + float(i) };
        v.* = .{ -1.0 - float(i), 0.5 + float(i) };
    }
    for (&source.counts, 0..) |*v, i| {
        v.* = 200 + @as(u32, @intCast(i));
    }
    var mirror: M.Buffers = zeroes(M.Buffers);
    const bytes: []u8 = asBytes(&mirror);
    var at: usize = 0;
    inline for (C.fields_by_offset) |fi| {
        const fname: []const u8 = C.buffer_field_names[fi];
        const n: usize = C.prefixBytes(fname, count);
        @memcpy(bytes[at..][0..n], asBytes(&@field(source, fname))[0..n]);
        at += n;
    }
    C.unpackPrefixes(bytes, count);
    try expectEqualSlices(Vec2, &source.pos, &mirror.pos);
    try expectEqualSlices(u32, &source.counts, &mirror.counts);
    try expectEqualSlices(Vec2, &source.visc, &mirror.visc);
}
