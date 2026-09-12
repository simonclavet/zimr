//! lint:alias jobs
//! src/jobs.zig — run a PURE kernel off the main thread, on a Web Worker.
//!
//! ===========================================================================
//! WHAT THIS BUYS (measured on-device, not guessed)
//! ===========================================================================
//! LATENCY, not throughput. The distinction shapes the entire design.
//!
//!   * THROUGHPUT IS A TRAP. Eight concurrent workers on a Pixel-class phone deliver
//!     only ~3.4x aggregate, and a partitioned frame tops out near 2.7x — the
//!     single-thread baseline runs on a BOOSTED prime core, and spreading out drops
//!     every core's clock. Worse: a hot CPU throttles the GPU, so buying CPU
//!     parallelism can cost you the thing a renderer actually cares about. Do not
//!     reach for this to go "N times faster". You will be disappointed, and your GPU
//!     will be slower.
//!
//!   * LATENCY IS THE WIN, and it is total. `codecs.png.encode` of a 1024x1024 image
//!     takes ~240 ms in wasm on a phone. On the main thread that is a 233 ms FROZEN
//!     FRAME — fourteen dropped frames, plainly visible. On a worker: 222 ms of encode
//!     and a worst frame gap of 17 ms. Nothing stalls. The job is not FASTER. It is
//!     ELSEWHERE, and elsewhere is what you wanted.
//!
//! Good: image encode/decode, glTF/OBJ parse, mesh bake, navmesh, procgen, runtime
//! shader transpile — anything one-shot and off the critical path.
//! Bad: per-frame rendering. That is what the GPU is for.
//!
//! ===========================================================================
//! WRITING A KERNEL
//! ===========================================================================
//!     fn encodePng(
//!         gpa: Allocator,                 // an arena; freed for you after the job
//!         hdr: struct { w: u32, h: u32 }, // small, POD, copied by value
//!         pixels: []const u8,             // the payload
//!         out: *std.Io.Writer,            // where the result goes
//!     ) !void {
//!         const png = try codecs.png.encode(gpa, pixels, hdr.w, hdr.h);
//!         try out.writeAll(png);
//!     }
//!
//! It is an ordinary Zig function: allocator first, as everywhere else in std, and a
//! plain `std.Io.Writer` for output — so a kernel composes with anything that already
//! writes to a writer, and `try out.print(...)` just works.
//!
//! A kernel runs in a SEPARATE wasm instance with its OWN linear memory. It cannot see
//! the app's globals even if it tries: purity is enforced by the address space, not by
//! a lint rule someone forgets. And the build ASSERTS the kernel wasm imports nothing
//! (see c2js `--kernel-wasm-embed`), so a kernel that reaches for the DOM is a build
//! error naming the offending import — not a worker that dies in a thread nobody is
//! watching.
//!
//! Three good things follow:
//!
//!   1. KERNELS ARE ORDINARY FUNCTIONS, so they unit-test on the host with no browser,
//!      no worker, no wasm and no mocking. See the tests at the bottom.
//!   2. EACH KERNEL GETS ITS OWN WASM EXPORT, named `zimr_job_<name>`. There is no id,
//!      no hash and no dispatch table, so a job cannot be routed to the wrong kernel —
//!      not because a test checks for it, but because there is no mechanism by which it
//!      could happen.
//!   3. NOTHING IS PAID FOR UNLESS USED. The worker's buffers live inside
//!      `exportWorkerEntry`, which only the kernel wasm calls.
//!
//! ===========================================================================
//! FALLBACK IS NOT OPTIONAL
//! ===========================================================================
//! `new Worker()` THROWS in a sandboxed iframe (the Claude artifact preview is one:
//! SecurityError on the blob: URL). It is also absent on the host. In BOTH cases
//! `submit` runs the kernel INLINE, through the very same `invoke` the worker calls,
//! and the job is already complete when you first `poll` it.
//!
//! So the API cannot fail, there is ONE code path, and an example that uses jobs works
//! everywhere — where workers are unavailable it merely hitches, exactly as it would
//! have if it had never used jobs at all. `parallel()` exists only so a demo can TELL
//! the user why it hitched.

const std = @import("std");
const builtin = @import("builtin");
const web = @import("web.zig");
const jobs_abi = @import("jobs_abi.zig");
const wgpu = @import("wgpu.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = error{
    /// The kernel returned an error. Its name is logged (see `logFailure`) — errors
    /// cannot cross a wasm boundary as values, so the app gets one error and the
    /// developer gets the name.
    KernelFailed,
    /// header + payload exceeded `Options.max_input`.
    InputTooLarge,
    /// The kernel wrote more than `Options.max_output`.
    OutputTooLarge,
    /// Every worker is busy and the queue is full.
    QueueFull,
    OutOfMemory,
};

/// A job in flight. Poll it once a frame; it never blocks.
///
/// It carries no kernel type, so it is one plain type rather than one per registry.
/// Diagnostic scaffolding for the landing-frame stall. `pollInto` does exactly two things
/// that cross into JS — ask the host whether the result is ready, and copy it out — and with
/// the allocation removed the frame STILL costs 93 ms for 2.7 MB (29 MB/s, when a
/// `TypedArray.set` runs at gigabytes/sec). One of these two is lying about being cheap.
pub var last_ready_ms: f32 = 0; // lint:off module-var: timing scaffold for the landing-frame stall
pub var last_copy_ms: f32 = 0; // lint:off module-var: timing scaffold for the landing-frame stall

pub const Job = struct {
    handle: u32 = 0,
    gpa: ?Allocator = null,
    result: ?[]u8 = null,
    /// A result written into a CALLER-owned buffer (`pollInto`). Distinct from `result`
    /// precisely so `deinit` cannot free memory it does not own.
    borrowed: ?[]const u8 = null,

    /// A failure that has ALREADY happened, waiting to be delivered at `poll`.
    ///
    /// This exists to make the two paths identical. A kernel that runs INLINE (no workers on
    /// this page) fails during `submit`, while a kernel on a WORKER fails later and surfaces
    /// at `poll`. Without this the app would have to handle failure in two different places,
    /// and would have to know which world it was in to know where to look — which is exactly
    /// the knowledge the jobs system promises it will never need.
    ///
    /// Now `submit` always returns a Job, and every failure — inline or remote — arrives at
    /// `poll`. One code path, one place to look.
    pending_failure: ?Error = null,

    /// The failed kernel's error NAME, if it failed. e.g. "ShortPayload".
    ///
    /// A fixed buffer, not an allocation: this is filled on the frame a failure lands, and a
    /// frame path must not allocate. 48 bytes holds every error name Zig can produce here with
    /// room to spare, and a longer one is TRUNCATED rather than lost — a clipped name still
    /// tells you more than `KernelFailed` ever did.
    error_name_buf: [48]u8 = @splat(0),
    error_name_len: u8 = 0,

    /// NON-BLOCKING. `null` while the kernel runs; the bytes when it is done; an error
    /// if it failed. The slice is owned by the Job — `deinit` when finished with it.
    ///
    ///     if (try job.poll()) |png| { save(png); job.deinit(); }
    /// Collect the result INTO A BUFFER THE CALLER ALREADY OWNS.
    ///
    /// Prefer this in a frame loop. `poll()` allocates the result for you, which is tidy and
    /// — measured on a phone, 2.7 MB PNG — costs **154 ms**, because a multi-megabyte request
    /// grows the wasm linear memory and the browser copies the whole thing. The encode itself
    /// was off-thread and cost the frame 17 ms; collecting it cost nine times that. The
    /// worker gave the frame back and `poll` took it away again.
    ///
    /// (`submit`'s 4 MB staging buffer is cheap for the opposite reason: it frees the block
    /// each run, so the next request is served from the allocator's free list. `poll` asks
    /// for a different size and misses it.)
    ///
    /// The buffer must be at least as large as the result; `Error.OutputTooLarge` if not.
    /// Allocate it ONCE, at init, and hand it back every frame:
    ///
    ///     s.buf = try gpa.alloc(u8, 8 << 20);          // once
    ///     if (try s.job.pollInto(s.buf)) |png| { ... } // every frame, no allocation
    pub fn pollInto(self: *Job, destination_buffer: []u8) Error!?[]const u8 {
        // A kernel that ran INLINE has already failed by the time we get here. Deliver it in
        // the same place a worker's failure would arrive, so the app has one code path.
        if (self.pending_failure) |already_failed| {
            return already_failed;
        }

        // Already collected? Hand back the same bytes. Polling twice must be free.
        if (self.result) |already_owned_result| {
            return already_owned_result;
        }
        if (self.borrowed) |already_borrowed_result| {
            return already_borrowed_result;
        }

        const job_is_in_flight: bool = self.handle != 0;
        if (!job_is_in_flight) {
            return null;
        }

        // ---- is it finished? -----------------------------------------------------------
        const time_before_ready_check: f64 = wgpu.nowMs();
        const result_length_or_status: i32 = web.jobs.poll(self.handle);
        last_ready_ms = @floatCast(wgpu.nowMs() - time_before_ready_check);

        const job_is_still_running: bool = result_length_or_status == web.jobs.pending;
        if (job_is_still_running) {
            return null;
        }

        const kernel_reported_failure: bool = result_length_or_status < 0;
        if (kernel_reported_failure) {
            // Take the NAME before cancelling — `cancel` clears the host's record of it.
            self.captureErrorName();
            web.jobs.cancel(self.handle);
            self.handle = 0;
            return Error.KernelFailed;
        }

        // ---- it finished. Is there room for it? ----------------------------------------
        const result_length: usize = @intCast(result_length_or_status);
        const destination_is_big_enough: bool = result_length <= destination_buffer.len;
        if (!destination_is_big_enough) {
            web.jobs.cancel(self.handle);
            self.handle = 0;
            return Error.OutputTooLarge;
        }

        // ---- copy it out ---------------------------------------------------------------
        const destination_slice: []u8 = destination_buffer[0..result_length];

        const time_before_copy: f64 = wgpu.nowMs();
        _ = web.jobs.take(self.handle, destination_slice);
        last_copy_ms = @floatCast(wgpu.nowMs() - time_before_copy);

        self.handle = 0;

        // `borrowed`, NOT `result`. The distinction is load-bearing: `deinit` frees `result`
        // and must never free this, because the buffer belongs to the CALLER.
        self.borrowed = destination_slice;
        return self.borrowed;
    }

    pub fn poll(self: *Job) Error!?[]const u8 {
        if (self.pending_failure) |already_failed| {
            return already_failed; // an inline kernel that failed during `submit`
        }
        if (self.borrowed) |b| {
            return b;
        }
        if (self.result) |r| {
            return r;
        }
        if (self.handle == 0) {
            return null;
        }
        const n: i32 = web.jobs.poll(self.handle);
        if (n == web.jobs.pending) {
            return null;
        }
        if (n < 0) {
            // Retire it host-side too, or the failure marker sits in the host's result
            // map for the life of the page.
            web.jobs.cancel(self.handle);
            self.handle = 0;
            return Error.KernelFailed;
        }
        const len: usize = @intCast(n);
        const gpa = self.gpa orelse return Error.KernelFailed;
        const buf: []u8 = gpa.alloc(u8, len) catch return Error.OutOfMemory;
        _ = web.jobs.take(self.handle, buf);
        self.handle = 0;
        self.result = buf;
        return buf;
    }

    pub fn inFlight(self: Job) bool {
        return self.handle != 0 and self.result == null and self.borrowed == null;
    }

    /// Release the result, and give up on the job if it is still running.
    ///
    /// The cancel is the important half: a worker is still computing a result for an
    /// abandoned job, and without telling the host to discard the reply, its buffer —
    /// megabytes, for an image — is parked in the host for the life of the page.
    /// The failed kernel's error name, or "" if it did not fail.
    ///
    /// `error.KernelFailed` is a Zig error, and a Zig error cannot carry a payload. So the name
    /// rides along here instead:
    ///
    ///     _ = job.pollInto(buf) catch |err| {
    ///         s.err_msg = if (job.errorName().len >= 1) job.errorName() else @errorName(err);
    ///     };
    pub fn errorName(self: *const Job) []const u8 {
        return self.error_name_buf[0..self.error_name_len];
    }

    /// Record an error name we already hold as a Zig string (the inline path).
    fn setErrorName(self: *Job, name: []const u8) void {
        const copied: usize = @min(name.len, self.error_name_buf.len);
        @memcpy(self.error_name_buf[0..copied], name[0..copied]);
        self.error_name_len = @intCast(copied);
    }

    /// Fetch an error name the HOST is holding for us (the worker path).
    fn captureErrorName(self: *Job) void {
        const written: usize = web.jobs.errorName(self.handle, &self.error_name_buf);
        self.error_name_len = @intCast(@min(written, self.error_name_buf.len));
    }

    pub fn deinit(self: *Job) void {
        if (self.handle != 0) {
            web.jobs.cancel(self.handle);
        }
        if (self.result) |r| {
            if (self.gpa) |gpa| {
                gpa.free(r);
            }
        }
        self.borrowed = null; // never ours to free
        self.* = .{};
    }
};

/// Is there a real worker pool, or will kernels run inline on the main thread?
/// Behaviour is identical either way — this is for telling the USER why the frame
/// hitched, and for nothing else.
pub fn parallel() bool {
    return web.jobs.available();
}

pub const Options = struct {
    /// Largest header + payload a kernel may receive. A policy cap, not a buffer: the
    /// worker allocates exactly what each job needs.
    max_input: usize = 8 << 20,
    /// Largest result a kernel may produce. `out` is a fixed writer over a buffer this
    /// size, so a runaway kernel gets `error.WriteFailed` rather than eating memory.
    max_output: usize = 24 << 20,
};

/// The job system for one app's kernels.
///
///     const registry = jobs.Registry(.{
///         .{ "encodePng", encodePng },
///     }, .{});
///
///     // in the kernel root (build.zig generates it):
///     comptime { registry.exportWorkerEntry(); }
///
///     // in the app:
///     app.job = try registry.submit(gpa, "encodePng", .{ .w = 1024, .h = 1024 }, pixels);
///     if (try app.job.poll()) |png| { ...; app.job.deinit(); }
///
/// The table is the SINGLE SOURCE OF TRUTH: `submit` looks kernels up in it, and
/// `exportWorkerEntry` emits one wasm export per entry. The two cannot get out of step.
///
/// It is explicit rather than reflected off a struct's decls because this Zig's
/// `@typeInfo` no longer exposes `decls`. That turns out to be a feature: because the
/// table is an ordinary comptime tuple, tables COMPOSE —
///
///     jobs.Registry(four_ways.job_kernels ++ worker_png.job_kernels, .{})
///
/// which is exactly what a page bundling several examples (the launcher) needs. Exports
/// are keyed by NAME, so a merged kernel wasm satisfies every example's `submit` without
/// anyone renumbering anything.
pub fn Registry(comptime kernels: anytype, comptime opts: Options) type {
    comptime validate(kernels);

    return struct {
        /// The bounds this registry was built with, RE-EXPOSED so registries can COMPOSE.
        ///
        /// A page carries ONE kernel wasm, but the launcher bundles many examples — so its
        /// kernel wasm is built from the concatenated tables, and needs bounds that fit
        /// every member:
        ///
        ///     jobs.Registry(a.job_kernels ++ b.job_kernels, .{
        ///         .max_input  = @max(a.registry.max_input,  b.registry.max_input),
        ///         .max_output = @max(a.registry.max_output, b.registry.max_output),
        ///     })
        ///
        /// Without this the merged root would have to hard-code numbers that silently drift
        /// from the registries they are supposed to cover — and a `max_input` too small does
        /// not fail loudly, it fails as `Error.InputTooLarge` on a phone.
        pub const max_input: usize = opts.max_input;
        pub const max_output: usize = opts.max_output;

        /// Find a kernel in the table by FUNCTION IDENTITY, at comptime.
        ///
        /// This is why `submit` takes the function itself rather than a name string: the
        /// call site names the kernel exactly once, in the only way that cannot be
        /// misspelled. A function that is not in the table is a build error that lists
        /// the ones that are.
        fn nameOf(comptime kernel: anytype) []const u8 {
            for (kernels) |entry| {
                // The type check is not redundant: two kernels with different header
                // types have different FUNCTION types, and `==` on mismatched function
                // types is a compile ERROR, not `false`. The comptime `if` prunes the
                // comparison for every entry that could not possibly match.
                if (@TypeOf(entry[1]) == @TypeOf(kernel)) {
                    if (entry[1] == kernel) {
                        return entry[0];
                    }
                }
            }
            comptime var known: []const u8 = "";
            for (kernels) |entry| {
                known = known ++ "\n    " ++ entry[0];
            }
            @compileError("jobs: that function is not in this registry's kernel table." ++
                "\n  Known kernels:" ++ known ++
                "\n  (add it to the table, or you will get a NoSuchKernel at runtime.)");
        }

        /// Hand a job to a worker and return IMMEDIATELY.
        ///
        ///     app.job = try registry.submit(gpa, encodePng, .{ .w = 1024, .h = 1024 }, pixels);
        ///
        /// `header` is type-checked against the kernel's own signature, so there is no
        /// byte-packing at the call site and a mismatch is a compile error.
        ///
        /// If there is no worker pool — on the host, or in a sandboxed iframe where
        /// `new Worker()` was refused — this runs the kernel INLINE through the same
        /// `invoke` the worker uses, and returns an already-finished Job. The caller
        /// cannot tell, and should not have to.
        /// N jobs, submitted together, collected as they finish.
        ///
        /// The pool has ALWAYS been parallel — `pump()` walks every worker and hands each
        /// free one a job off the queue — but until this existed, using it meant N `Job`
        /// values, N `pollInto` calls and N done-flags open-coded in every app. So nobody
        /// did, and the pool ran one thread for its entire life.
        ///
        /// Three properties, each load-bearing:
        ///
        ///   * `next` yields whatever is ready, OUT OF ORDER. That is the feature, not a
        ///     compromise: a tile that finishes first should be drawn first, and in-order
        ///     delivery would put back the head-of-line stall the pool exists to remove.
        ///   * `next(dst)` collects into a CALLER-OWNED buffer (`pollInto`, never `poll`).
        ///     Allocating on a landing frame cost 154 ms for 2.7 MB when we measured it, and
        ///     a Group lands many times a second.
        ///   * `progress()` is free — the bookkeeping exists anyway.
        ///
        /// KNOWN LIMIT, stated before it bites someone: `submitAll` stages `header ++ payload`
        /// PER JOB, so a shared payload is copied N times. For a scene of a few hundred bytes
        /// that is nothing. For a job set sharing a 4 MB mesh it would be everything, and the
        /// fix then is a payload the workers HOLD across jobs — not a bigger memcpy.
        pub fn Group(comptime kernel: anytype) type {
            return struct {
                const Self = @This();

                /// One finished job: WHICH one it was, and its bytes.
                pub const Landed = struct {
                    /// Index into the `headers` slice that `submitAll` was given. Results
                    /// arrive OUT OF ORDER, so this is how a caller knows what it just got.
                    index: usize,
                    /// Valid until the next call to `next()` — the bytes live in the CALLER's
                    /// buffer, which the next result will overwrite.
                    bytes: []const u8,
                };

                /// The header type is DERIVED from the kernel, never passed alongside it.
                /// Same discipline as `submit` taking the function rather than a name string:
                /// the call site names the kernel exactly once, in the only way that cannot
                /// be misspelled, and a header of the wrong type is a build error.
                pub const H = HeaderOf(kernel);

                gpa: Allocator,
                jobs: []Job,
                landed: []bool,
                n_landed: usize = 0,

                /// The NAME of the last kernel that failed in this group, e.g. "ShortPayload".
                /// Empty if nothing has failed. `next` returns `error.KernelFailed`, and a Zig
                /// error cannot carry a payload — so the name rides here.
                ///
                /// The Group OWNS these bytes. It must: the name lives in the failed `Job`'s
                /// own buffer, and `deinit` frees the job array — so handing out a slice into
                /// it would dangle the instant the group was torn down. `rt_workers` stores the
                /// name in its state and draws it every frame, which is precisely the shape
                /// that turns a borrowed slice into a use-after-free you only see as garbage on
                /// a phone screen. Copy it; it is 48 bytes.
                error_name_buf: [48]u8 = @splat(0),
                error_name_len: u8 = 0,

                /// Submit one job per header. They queue; the pool feeds every free worker,
                /// so N headers occupy min(N, pool_size) cores. `payload` is shared — each
                /// job gets its own copy of it (see KNOWN LIMIT above).
                pub fn submitAll(
                    gpa: Allocator,
                    headers: []const H,
                    shared_payload: []const u8,
                ) Error!Self {
                    const job_count: usize = headers.len;

                    const jobs_in_flight: []Job = gpa.alloc(Job, job_count) catch {
                        return Error.OutOfMemory;
                    };
                    errdefer gpa.free(jobs_in_flight);

                    const has_landed_flags: []bool = gpa.alloc(bool, job_count) catch {
                        return Error.OutOfMemory;
                    };
                    errdefer gpa.free(has_landed_flags);

                    @memset(jobs_in_flight, .{});
                    @memset(has_landed_flags, false);

                    for (headers, 0..) |this_header, job_index| {
                        const submitted_job: Job = submit(
                            gpa,
                            kernel,
                            this_header,
                            shared_payload,
                        ) catch |submit_error| {
                            // One submit failed, so CANCEL the ones already queued. Leaving
                            // them would strand orphaned jobs holding worker slots for the
                            // life of the page, running work whose result nobody will collect.
                            for (jobs_in_flight[0..job_index]) |*orphan| {
                                orphan.deinit();
                            }
                            gpa.free(jobs_in_flight);
                            gpa.free(has_landed_flags);
                            return submit_error;
                        };
                        jobs_in_flight[job_index] = submitted_job;
                    }

                    return .{
                        .gpa = gpa,
                        .jobs = jobs_in_flight,
                        .landed = has_landed_flags,
                    };
                }

                /// The next result that has FINISHED, copied into `dst`. `null` when nothing
                /// new is ready this frame — which is the common case and costs one host poll
                /// per outstanding job.
                ///
                /// Call it in a `while` loop: several tiles can land in one frame.
                pub fn next(self: *Self, destination_buffer: []u8) Error!?Landed {
                    for (self.jobs, 0..) |*this_job, job_index| {
                        const this_job_already_landed: bool = self.landed[job_index];
                        if (this_job_already_landed) {
                            continue;
                        }

                        const finished_bytes_or_null: ?[]const u8 = this_job.pollInto(
                            destination_buffer,
                        ) catch |kernel_error| {
                            // A kernel that failed RETIRES its own job and does not poison the
                            // rest of the group: the other tiles are still coming, and the
                            // caller still wants them.
                            //
                            // Keep the NAME. Without it the app can only report
                            // "KernelFailed", which on a phone — with no console to read — is
                            // the same as reporting nothing.
                            self.copyErrorNameFrom(this_job);
                            self.landed[job_index] = true;
                            self.n_landed += 1;
                            return kernel_error;
                        };

                        const finished_bytes: []const u8 = finished_bytes_or_null orelse {
                            // Still running. Ask the next job.
                            continue;
                        };

                        self.landed[job_index] = true;
                        self.n_landed += 1;
                        return .{ .index = job_index, .bytes = finished_bytes };
                    }

                    // Nothing new finished this frame. That is the COMMON case, and it costs
                    // one cheap host poll per outstanding job.
                    return null;
                }

                /// The last failed kernel's name, owned by this Group and valid for as long
                /// as the Group is.
                pub fn lastErrorName(self: *const Self) []const u8 {
                    return self.error_name_buf[0..self.error_name_len];
                }

                fn copyErrorNameFrom(self: *Self, failed_job: *const Job) void {
                    const name: []const u8 = failed_job.errorName();
                    const copied: usize = @min(name.len, self.error_name_buf.len);
                    @memcpy(self.error_name_buf[0..copied], name[0..copied]);
                    self.error_name_len = @intCast(copied);
                }

                pub fn complete(self: Self) bool {
                    return self.n_landed == self.jobs.len;
                }

                pub fn progress(self: Self) f32 {
                    if (self.jobs.len == 0) {
                        return 1.0;
                    }
                    const done: f32 = @floatFromInt(self.n_landed);
                    const all: f32 = @floatFromInt(self.jobs.len);
                    return done / all;
                }

                pub fn deinit(self: *Self) void {
                    for (self.jobs) |*j| {
                        j.deinit(); // cancels anything still in flight, host-side too
                    }
                    self.gpa.free(self.jobs);
                    self.gpa.free(self.landed);
                    self.jobs = &.{};
                    self.landed = &.{};
                    self.n_landed = 0;
                }
            };
        }

        pub fn submit(
            gpa: Allocator,
            comptime kernel: anytype,
            header: HeaderOf(kernel),
            payload: []const u8,
        ) Error!Job {
            const name = comptime nameOf(kernel);
            const H: type = @TypeOf(header);
            comptime assertPod(H, name);

            const header_bytes: []const u8 = std.mem.asBytes(&header);
            const total_input_bytes: usize = header_bytes.len + payload.len;
            if (total_input_bytes > opts.max_input) {
                return Error.InputTooLarge;
            }

            // NO STAGING BUFFER.
            //
            // This used to be `gpa.alloc(total)` plus two memcpys, to hand the host one
            // contiguous `header ++ payload`. That was a MULTI-MEGABYTE ALLOCATION ON EVERY
            // DISPATCH, in the frame path — the same mistake that cost `Job.poll` 154 ms on
            // the landing frame, still live here on the input side. And it bought nothing:
            // the host has to allocate a JS-owned buffer regardless (the one it TRANSFERS to
            // the worker), so it can join the two while it copies. Two copies of the payload
            // became one, and the allocation became zero.
            //
            // The worker still receives exactly the same bytes. `invoke` splits them back
            // apart at `@sizeOf(H)`, on whichever side runs the kernel — see `runInline`.
            if (!web.jobs.available()) {
                return runInline(gpa, name, kernel, header_bytes, payload);
            }

            const handle: u32 = web.jobs.submit(name, header_bytes, payload);
            if (handle == 0) {
                return Error.QueueFull;
            }
            return .{ .handle = handle, .gpa = gpa };
        }

        /// The no-worker path. Everything is heap here: an app that never gets a worker
        /// must not carry the worker's buffers, and the kernel's arena wraps the
        /// CALLER's allocator so a fallback job costs only what it actually needs.
        /// No workers on this page (a sandboxed iframe forbids them), so run the kernel right
        /// here, on the main thread. The app is none the wiser; it simply hitches, exactly as
        /// it would have if it had never used jobs at all.
        ///
        /// Note that this DOES NOT JOIN the header and payload. The worker receives them
        /// joined only because `postMessage` carries one buffer and the host joins them on the
        /// way out; here we already hold both pieces, so joining them would be an allocation
        /// and a memcpy performed purely to take them apart again on the next line.
        fn runInline(
            gpa: Allocator,
            comptime name: []const u8,
            comptime kernel: anytype,
            header_bytes: []const u8,
            payload: []const u8,
        ) Error!Job {
            const HeaderType: type = HeaderOf(kernel);
            if (header_bytes.len != @sizeOf(HeaderType)) {
                return Error.KernelFailed; // only reachable if `submit` and this disagree
            }

            // memcpy rather than @ptrCast: `header_bytes` carries no alignment guarantee, and
            // a misaligned load is a trap on some targets and merely wrong on others.
            var header: HeaderType = undefined;
            @memcpy(std.mem.asBytes(&header), header_bytes);

            const output_buffer: []u8 = gpa.alloc(u8, opts.max_output) catch {
                return Error.OutOfMemory;
            };
            defer gpa.free(output_buffer);

            var kernel_arena: std.heap.ArenaAllocator = .init(gpa);
            defer kernel_arena.deinit(); // whatever the kernel allocated, gone — always

            var output_writer: Writer = .fixed(output_buffer);
            kernel(kernel_arena.allocator(), header, payload, &output_writer) catch |err| {
                logFailure(name, err);

                // Do NOT propagate this out of `submit`. Park it on the Job, so it is
                // delivered at `poll` — exactly where a WORKER's failure would arrive. The
                // app must not have to know which world it is running in to know where its
                // errors will appear.
                var failed_job: Job = .{ .gpa = gpa };
                failed_job.pending_failure = if (err == error.WriteFailed)
                    Error.OutputTooLarge
                else
                    Error.KernelFailed;
                failed_job.setErrorName(@errorName(err));
                return failed_job;
            };

            const written_bytes: []const u8 = output_writer.buffered();
            const owned_result: []u8 = gpa.dupe(u8, written_bytes) catch {
                return Error.OutOfMemory;
            };
            return .{ .gpa = gpa, .result = owned_result };
        }

        /// Emit the wasm exports the KERNEL WASM exposes.
        /// `comptime { registry.exportWorkerEntry(); }` — in the kernel root ONLY.
        ///
        /// The protocol:
        ///     ptr = zimr_job_alloc(n)     // JS asks for a buffer of exactly n bytes
        ///     <JS copies header ++ payload into wasm memory at ptr>
        ///     len = zimr_job_<name>(n)    // ONE EXPORT PER KERNEL. len, or -1.
        ///     out = zimr_job_out_ptr()    // JS copies len bytes out of here
        ///     err = zimr_job_err_ptr/len  // on -1: the error's NAME, for the log
        ///
        /// One export per kernel is why there is no id, no hash and no dispatch table:
        /// the worker calls `ex["zimr_job_" + name]`, so a job CANNOT reach the wrong
        /// kernel. There is no mechanism by which it could.
        ///
        /// Everything is allocated from `std.heap.wasm_allocator`, which grows the
        /// instance's linear memory on demand. Static buffers would have declared 41 MB
        /// of initial memory PER WORKER — 164 MB for four, before a single job ran.
        /// This way an idle worker is ~1 MB and grows only to what a job needs; the
        /// arena is reused, so a stream of jobs settles at the high-water mark.
        /// The export names come from `jobs_worker.abi`, which is the SAME struct the
        /// worker's JS is generated from. They used to be string literals here AND string
        /// literals over there, with nothing checking that the two agreed — rename one and
        /// the worker fails silently, with no error and no result, forever.
        ///
        /// There is now exactly one spelling of each name in the whole engine.
        pub fn exportWorkerEntry() void {
            @export(&Worker.alloc, .{ .name = jobs_abi.alloc });
            @export(&Worker.outPtr, .{ .name = jobs_abi.out_ptr });
            @export(&Worker.errPtr, .{ .name = jobs_abi.err_ptr });
            @export(&Worker.errLen, .{ .name = jobs_abi.err_len });

            for (kernels) |entry| {
                const kernel = entry[1];
                const Entry = struct {
                    fn run(in_len: u32) callconv(.c) i32 {
                        return Worker.run(kernel, in_len);
                    }
                };
                @export(&Entry.run, .{ .name = jobs_abi.kernel_prefix ++ entry[0] });
            }
        }

        /// The kernel wasm's side of the protocol. Referenced only by
        /// `exportWorkerEntry`, so linking this Registry into the APP (which needs it
        /// for `submit`'s comptime checks) drags none of it along.
        const Worker = struct {
            var in_mem: []u8 = &.{};
            var out_mem: []u8 = &.{};
            var arena: std.heap.ArenaAllocator = undefined;
            var arena_ready: bool = false;
            /// The name of the last error, so a failure is legible instead of a bare -1.
            /// `@errorName` returns a static string, so this borrows and never owns.
            var err_name: []const u8 = "";

            fn alloc(len: u32) callconv(.c) u32 {
                const wa: Allocator = std.heap.wasm_allocator;
                if (in_mem.len != 0) {
                    wa.free(in_mem);
                    in_mem = &.{};
                }
                if (len > opts.max_input) {
                    return 0; // the host lied about the size; refuse
                }
                in_mem = wa.alloc(u8, len) catch return 0;
                return @intFromPtr(in_mem.ptr);
            }

            fn run(comptime kernel: anytype, in_len: u32) i32 {
                const wa: Allocator = std.heap.wasm_allocator;
                if (in_len > in_mem.len) {
                    err_name = "MalformedJob";
                    return -1;
                }
                if (out_mem.len == 0) {
                    out_mem = wa.alloc(u8, opts.max_output) catch {
                        err_name = "OutOfMemory";
                        return -1;
                    };
                }
                if (!arena_ready) {
                    arena = std.heap.ArenaAllocator.init(wa);
                    arena_ready = true;
                }
                // Reset, not free: a worker runs job after job, and retaining capacity
                // means it stops growing once it has seen the biggest one. A kernel
                // still cannot leak — everything it allocated is gone the moment the
                // next job starts.
                _ = arena.reset(.retain_capacity);

                var out: Writer = .fixed(out_mem);
                invoke(kernel, arena.allocator(), in_mem[0..in_len], &out) catch |err| {
                    err_name = @errorName(err);
                    return -1;
                };
                return @intCast(out.end);
            }

            fn outPtr() callconv(.c) u32 {
                return @intFromPtr(out_mem.ptr);
            }
            fn errPtr() callconv(.c) u32 {
                return @intFromPtr(err_name.ptr);
            }
            fn errLen() callconv(.c) u32 {
                return @intCast(err_name.len);
            }
        };
    };
}

// ---------------------------------------------------------------------------
// The one code path. The worker calls it; the inline fallback calls it; the tests call
// it. "It passed on the host" therefore means something.
// ---------------------------------------------------------------------------

/// Split `staged` into header ++ payload and hand them to the kernel.
fn invoke(
    comptime kernel: anytype,
    gpa: Allocator,
    staged: []const u8,
    out: *Writer,
) !void {
    const H: type = HeaderOf(kernel);
    if (staged.len < @sizeOf(H)) {
        return error.MalformedJob;
    }
    // memcpy rather than @ptrCast: `staged` carries no alignment guarantee, and a
    // misaligned load is a trap on some targets and merely wrong on others.
    var header: H = undefined;
    @memcpy(std.mem.asBytes(&header), staged[0..@sizeOf(H)]);
    try kernel(gpa, header, staged[@sizeOf(H)..], out);
}

fn HeaderOf(comptime kernel: anytype) type {
    return @typeInfo(@TypeOf(kernel)).@"fn".param_types[1].?;
}

/// Errors cannot cross a wasm boundary as values, so the app gets `KernelFailed` and
/// the developer gets the NAME — on the page's log overlay, which is visible on a phone
/// with no devtools attached. Without this a failing kernel is a bare `-1` and you are
/// guessing between OutOfMemory and InvalidPixelBufferSize.
///
/// Silent under test: the tests deliberately fail kernels, and Zig's test runner counts
/// a logged error as a failed run.
fn logFailure(comptime name: []const u8, err: anyerror) void {
    if (comptime builtin.is_test) {
        return;
    }
    std.log.err("zimr.jobs: kernel '" ++ name ++ "' failed: {s}", .{@errorName(err)});
}

/// Check the table's shape at comptime, so a malformed entry is a clear message here
/// rather than a baffling one from deep inside `invoke`.
fn validate(comptime kernels: anytype) void {
    if (kernels.len == 0) {
        @compileError("jobs.Registry: the kernel table is empty");
    }
    for (kernels) |entry| {
        if (entry.len != 2) {
            @compileError("jobs.Registry: each entry must be .{ \"name\", kernelFn }");
        }
        const name: []const u8 = entry[0];
        const info = @typeInfo(@TypeOf(entry[1]));
        if (info != .@"fn") {
            @compileError("jobs: kernel '" ++ name ++ "' is not a function");
        }
        const params = info.@"fn".param_types;
        if (params.len != 4) {
            @compileError("jobs: kernel '" ++ name ++ "' must take exactly 4 parameters:\n" ++
                "  fn (gpa: Allocator, hdr: <POD>, payload: []const u8, out: *std.Io.Writer) !void");
        }
        if (params[0].? != Allocator) {
            @compileError("jobs: kernel '" ++ name ++ "': parameter 1 must be std.mem.Allocator " ++
                "(allocator first, as everywhere else in Zig)");
        }
        if (params[2].? != []const u8) {
            @compileError("jobs: kernel '" ++ name ++ "': parameter 3 must be []const u8 (the payload)");
        }
        if (params[3].? != *Writer) {
            @compileError("jobs: kernel '" ++ name ++ "': parameter 4 must be *std.Io.Writer (the output)");
        }
    }
}

/// A header is memcpy'd out of the APP's wasm and into the KERNEL's wasm — two separate
/// compilations. So it must satisfy two things, and both are checked here rather than
/// discovered as garbage inside a worker you cannot breakpoint.
///
///   1. NO POINTERS. An address from one instance's linear memory means nothing in
///      another's.
///   2. AN ABI-GUARANTEED LAYOUT. Zig's `auto` layout is explicitly unspecified and it
///      really does reorder fields — `struct { a: u8, b: u32, c: u8 }` puts `b` at
///      offset 0. It happens to be deterministic for the same compiler and target, so an
///      auto-layout header works TODAY by luck. `extern` is what the language provides
///      for bytes that cross a boundary, so require it. An anonymous literal still
///      coerces to an extern struct, so no call site changes.
fn assertPod(comptime T: type, comptime kernel: []const u8) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("jobs: kernel '" ++ kernel ++ "' has a POINTER in its header (" ++
            @typeName(T) ++ "). The header is copied into another wasm instance, where that address " ++
            "means nothing. Pass the bytes as `payload` instead."),
        .@"struct" => |st| {
            if (st.layout == .auto) {
                @compileError("jobs: kernel '" ++ kernel ++ "' has an AUTO-LAYOUT header (" ++
                    @typeName(T) ++ "). The header is memcpy'd between two separately compiled wasm " ++
                    "modules, and Zig's auto layout is unspecified — it reorders fields for packing. " ++
                    "Declare it `extern struct` so the layout is ABI-guaranteed. The call site does " ++
                    "not change: an anonymous literal still coerces.");
            }
            for (st.field_types) |ft| {
                assertPod(ft, kernel);
            }
        },
        // A union's payload is copied just as a struct's is — and a slice hidden in one
        // used to sail straight through into a worker, where the pointer addressed
        // nothing.
        .@"union" => |un| {
            if (un.layout == .auto) {
                @compileError("jobs: kernel '" ++ kernel ++ "' has an AUTO-LAYOUT union in its header (" ++
                    @typeName(T) ++ "). Declare it `extern union` or `packed union` — the bytes cross " ++
                    "a compilation boundary and need a guaranteed layout.");
            }
            for (un.field_types) |ft| {
                assertPod(ft, kernel);
            }
        },
        .optional => |o| assertPod(o.child, kernel),
        .array => |a| assertPod(a.child, kernel),
        .vector => |v| assertPod(v.child, kernel),
        else => {},
    }
}

// ===========================================================================
// TESTS — the ergonomic payoff, not an afterthought.
//
// A kernel is an ordinary function and `submit` falls back to running it inline, so the
// WHOLE system tests on the host: no browser, no worker, no wasm, no mocking. What is
// left to go wrong is the transport, and that is the engine's problem, not the app
// author's. `testing.allocator` fails a test on any unfreed byte, so the leak tests
// below are assertions and not hopeful comments.
// ===========================================================================

const testing = std.testing;

fn tkRamp(
    gpa: Allocator,
    hdr: extern struct { n: u32 },
    payload: []const u8,
    out: *Writer,
) !void {
    _ = gpa;
    _ = payload;
    var i: u32 = 0;
    while (i < hdr.n) : (i += 1) {
        try out.writeByte(@truncate(i *% 2));
    }
}

fn tkEcho(
    gpa: Allocator,
    hdr: extern struct { pad: u32 },
    payload: []const u8,
    out: *Writer,
) !void {
    _ = hdr;
    // Allocates on purpose: proves the kernel's arena works and is released for it.
    const copy: []u8 = try gpa.alloc(u8, payload.len);
    @memcpy(copy, payload);
    try out.writeAll(copy);
}

fn tkBoom(
    gpa: Allocator,
    hdr: extern struct { pad: u32 },
    payload: []const u8,
    out: *Writer,
) !void {
    _ = gpa;
    _ = hdr;
    _ = payload;
    _ = out;
    return error.Nope;
}

const test_opts: Options = .{ .max_input = 4096, .max_output = 4096 };
const test_registry = Registry(.{
    .{ "ramp", tkRamp },
    .{ "echo", tkEcho },
    .{ "boom", tkBoom },
}, test_opts);

test "jobs: a kernel is just a function — call it directly, no engine involved" {
    var buf: [16]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try tkRamp(testing.allocator, .{ .n = 4 }, &.{}, &out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 2, 4, 6 }, out.buffered());
}

test "jobs: the output writer is bounded — an overrun is an error, not corruption" {
    var buf: [3]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try testing.expectError(error.WriteFailed, tkRamp(testing.allocator, .{ .n = 9 }, &.{}, &out));
}

test "jobs: submit/poll works end-to-end on the host via the inline fallback" {
    const gpa = testing.allocator;
    // This is EXACTLY the code an app writes in a browser with real workers.
    var job: Job = try test_registry.submit(gpa, tkRamp, .{ .n = 5 }, &.{});
    defer job.deinit();
    const got: []const u8 = (try job.poll()).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 2, 4, 6, 8 }, got);
}

test "jobs: payload round-trips, and a failing kernel surfaces as an error" {
    const gpa = testing.allocator;
    var job: Job = try test_registry.submit(gpa, tkEcho, .{ .pad = 0 }, "hello zimr");
    defer job.deinit();
    try testing.expectEqualStrings("hello zimr", (try job.poll()).?);

    // A failing kernel now surfaces at POLL, never at SUBMIT — see the dedicated test below
    // for why that matters.
    var boom: Job = try test_registry.submit(gpa, tkBoom, .{ .pad = 0 }, &.{});
    defer boom.deinit();
    try testing.expectError(Error.KernelFailed, boom.poll());
}

test "jobs: two kernels sharing a header TYPE still resolve to the right one" {
    // tkEcho and tkBoom have IDENTICAL function types — same header, same signature. The
    // table lookup must therefore disambiguate by function IDENTITY, not by type. If it
    // did not, `echo` would silently run `boom`, and only in the worker, where you cannot
    // breakpoint it.
    const gpa = testing.allocator;
    var job: Job = try test_registry.submit(gpa, tkEcho, .{ .pad = 0 }, "distinct");
    defer job.deinit();
    try testing.expectEqualStrings("distinct", (try job.poll()).?);
    // ...and tkBoom, submitted through the SAME registry, still blows up — proving the table
    // resolved it by function identity and not by its (identical) type. Failures arrive at
    // POLL now, never at SUBMIT.
    var boom: Job = try test_registry.submit(gpa, tkBoom, .{ .pad = 0 }, &.{});
    defer boom.deinit();
    try testing.expectError(Error.KernelFailed, boom.poll());
}

test "jobs: a kernel that overruns its output is OutputTooLarge, not a corrupted result" {
    const gpa = testing.allocator;
    const tiny = Registry(.{.{ "ramp", tkRamp }}, .{ .max_input = 64, .max_output = 4 });
    // Failures arrive at POLL now, never at SUBMIT — see "a failed kernel surfaces at POLL".
    var overrun: Job = try tiny.submit(gpa, tkRamp, .{ .n = 99 }, &.{});
    defer overrun.deinit();
    try testing.expectError(Error.OutputTooLarge, overrun.poll());
}

test "jobs: oversized input is rejected before it can corrupt anything" {
    const big = try testing.allocator.alloc(u8, test_opts.max_input + 1);
    defer testing.allocator.free(big);
    try testing.expectError(Error.InputTooLarge, test_registry.submit(testing.allocator, tkEcho, .{ .pad = 0 }, big));
}

test "jobs: a job dropped WITHOUT ever polling it leaks nothing" {
    var job: Job = try test_registry.submit(testing.allocator, tkEcho, .{ .pad = 0 }, "abandoned");
    job.deinit(); // never polled — the result must still be released
}

test "jobs: deinit is idempotent, and polling a retired job is not a use-after-free" {
    var job: Job = try test_registry.submit(testing.allocator, tkRamp, .{ .n = 3 }, &.{});
    _ = try job.poll();
    job.deinit();
    job.deinit(); // twice: must not double-free
    try testing.expectEqual(@as(?[]const u8, null), try job.poll()); // and must not resurrect
    try testing.expect(!job.inFlight());
}

test "jobs: a hundred submits in a row do not accumulate" {
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var job: Job = try test_registry.submit(testing.allocator, tkEcho, .{ .pad = 0 }, "x");
        try testing.expectEqualStrings("x", (try job.poll()).?);
        job.deinit();
    }
}

test "jobs: polling twice returns the same bytes and does not re-allocate" {
    var job: Job = try test_registry.submit(testing.allocator, tkRamp, .{ .n = 4 }, &.{});
    defer job.deinit();
    const a: []const u8 = (try job.poll()).?;
    const b: []const u8 = (try job.poll()).?;
    try testing.expectEqual(a.ptr, b.ptr); // cached, not re-fetched
}

test "jobs: invoke splits header from payload exactly, for worker and host alike" {
    // `invoke` is the single code path both the worker and the fallback go through.
    const Hdr = extern struct { n: u32 };
    var staged: [@sizeOf(Hdr) + 5]u8 = undefined;
    const hdr: Hdr = .{ .n = 3 };
    @memcpy(staged[0..@sizeOf(Hdr)], std.mem.asBytes(&hdr));
    @memcpy(staged[@sizeOf(Hdr)..], "abcde");

    // The kernel's allocator is an ARENA — that is the contract, and it is why a kernel
    // contains no `defer free`. Hand `invoke` a raw allocator and the kernel's
    // allocations leak, exactly as testing.allocator caught when this test first did it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buf: [16]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try invoke(tkEcho, arena.allocator(), &staged, &out);
    try testing.expectEqualStrings("abcde", out.buffered()); // payload only — header stripped
}

test "jobs.Group: every job lands exactly once, and each gets its OWN header" {
    const G: type = test_registry.Group(tkRamp);
    const headers = [_]G.H{ .{ .n = 1 }, .{ .n = 4 }, .{ .n = 2 }, .{ .n = 3 } };

    var g: G = try .submitAll(testing.allocator, &headers, &.{});
    defer g.deinit();

    var buf: [64]u8 = undefined;
    var seen: [4]bool = @splat(false);

    // Drain. On the host every job runs inline, so all four land immediately — but the loop
    // is written the way an app must write it, because in a browser they land whenever the
    // workers finish, in whatever order they finish.
    var guard: u32 = 0;
    while (!g.complete() and guard < 100) : (guard += 1) {
        while (try g.next(&buf)) |landed| {
            // The n-th job produced the n-th header's ramp — proof each job carried its own
            // header, not the last one submitted. (A shared staging buffer would break this
            // silently, which is exactly the bug shape to guard against.)
            try testing.expectEqual(headers[landed.index].n, @as(u32, @intCast(landed.bytes.len)));
            try testing.expect(!seen[landed.index]); // landed EXACTLY once
            seen[landed.index] = true;
        }
    }

    try testing.expect(g.complete());
    try testing.expectEqual(@as(f32, 1.0), g.progress());
    for (seen) |ok| {
        try testing.expect(ok);
    }
}

test "jobs.Group: progress is monotonic and an empty group is complete" {
    const G: type = test_registry.Group(tkRamp);

    var empty: G = try .submitAll(testing.allocator, &.{}, &.{});
    defer empty.deinit();
    try testing.expect(empty.complete());
    try testing.expectEqual(@as(f32, 1.0), empty.progress());

    const headers = [_]G.H{ .{ .n = 2 }, .{ .n = 2 } };
    var g: G = try .submitAll(testing.allocator, &headers, &.{});
    defer g.deinit();
    try testing.expect(!g.complete());

    var buf: [16]u8 = undefined;
    var last: f32 = 0;
    var guard: u32 = 0;
    while (!g.complete() and guard < 50) : (guard += 1) {
        _ = try g.next(&buf);
        try testing.expect(g.progress() >= last); // never goes backwards
        last = g.progress();
    }
    try testing.expect(g.complete());
}

test "jobs: submit passes header and payload SEPARATELY, and the kernel still sees them joined" {
    // The staging buffer is gone: `submit` no longer allocates `header ++ payload`. It hands
    // the two pieces to the host, which joins them into the buffer it had to allocate anyway.
    //
    // The kernel must not be able to tell the difference. This test is what says so.
    var job: Job = try test_registry.submit(testing.allocator, tkEcho, .{ .pad = 0 }, "payload-bytes");
    defer job.deinit();
    const result: []const u8 = (try job.poll()).?;
    try testing.expectEqualStrings("payload-bytes", result);
}

test "jobs: a failed kernel surfaces at POLL, inline or on a worker, and NAMES itself" {
    // Two things at once, and both are about the app having exactly ONE failure path:
    //
    //   1. `submit` SUCCEEDS even though the kernel is going to fail. Inline, the kernel has
    //      already run and blown up by this point — but propagating that out of `submit` would
    //      mean an app must handle failure in one place when workers exist and a different
    //      place when they do not, and must know which world it is in to know where to look.
    //
    //   2. The error NAME comes back. `error.KernelFailed` is a Zig error and a Zig error
    //      cannot carry a payload, so the name rides on the Job. Without it, every failure on
    //      a phone reads identically and says nothing.
    var job: Job = try test_registry.submit(testing.allocator, tkBoom, .{ .pad = 0 }, &.{});
    defer job.deinit();

    try testing.expectError(Error.KernelFailed, job.poll());
    try testing.expectEqualStrings("Nope", job.errorName()); // tkBoom returns error.Nope
}

test "jobs.Group: the failed kernel's name OUTLIVES the group's jobs" {
    // A use-after-free that shipped for exactly one turn. `Group` used to hand out a slice into
    // the failed Job's own buffer — and `deinit` frees the job array. `rt_workers` stores that
    // name in its state and draws it every frame, so the slice dangled the moment the group was
    // torn down: garbage on a phone screen, and nothing in any test.
    //
    // The Group owns the bytes now. This test is what says so: it reads the name AFTER the
    // group has freed everything it allocated.
    const G: type = test_registry.Group(tkBoom);
    const headers = [_]G.H{.{ .pad = 0 }};

    var g: G = try .submitAll(testing.allocator, &headers, &.{});
    var buf: [16]u8 = undefined;
    try testing.expectError(Error.KernelFailed, g.next(&buf));

    const name_before: []const u8 = g.lastErrorName();
    try testing.expectEqualStrings("Nope", name_before);

    g.deinit(); // frees the Job array the name used to point into

    try testing.expectEqualStrings("Nope", g.lastErrorName());
}
