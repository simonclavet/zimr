//! worker_png — start a task on a worker, and watch the frame NOT freeze.
//!
//! `codecs.png.encode` of a 1024x1024 image costs ~240 ms in wasm on a phone.
//!
//!   * On the MAIN THREAD that is a 233 ms frozen frame — fourteen dropped frames. The
//!     orbiting dot below stops dead, and the "worst frame gap" readout says so.
//!   * On a WORKER the encode still takes ~222 ms, but the worst frame gap is 17 ms.
//!     Nothing stalls. The dot never even flickers.
//!
//! The job is not FASTER. It is ELSEWHERE, and elsewhere is the whole feature.
//!
//! Tap either button and watch the dot. That is the demo.
//!
//! (Where workers are unavailable — a sandboxed iframe refuses `new Worker()` — the
//! kernel runs inline on the main thread instead, so this example still WORKS. It just
//! hitches on both buttons, and the readout tells you why.)

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const kernels = @import("kernels.zig");
const jobs = z.jobs;
const cos = zm.cos;
const sin = zm.sin;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// 1024x1024 RGBA — 4 MB in, ~2.7 MB of PNG out. Big enough that the main-thread encode
/// is unmissable; small enough to stay inside the registry's 8 MB bounds.
const dim: u32 = 1024;

const State = struct {
    gpa: Allocator,
    ui_host: z.UiHost,
    font: z.Font,
    /// The image we encode. Filled once, never touched again — the kernel gets a COPY.
    pixels: []u8,

    /// The result buffer, allocated ONCE. Handing this to `pollInto` every frame is the
    /// difference between a 17 ms landing frame and a 154 ms one: `poll()` would allocate
    /// 2.7 MB on the frame the PNG arrives, and a multi-megabyte request grows the wasm
    /// linear memory — which Chrome services by copying the whole thing. The worker had
    /// already handed the frame back; collecting the answer took it away again.
    result_buf: []u8,

    /// The one piece of job state an app carries: a handle you poll.
    job: jobs.Job = .{},

    png_kb: usize = 0,
    png_ok: bool = false,
    /// Worst frame gap seen while a job was outstanding. THIS is the measurement.
    worst_gap_ms: f32 = 0,
    watching: bool = false,

    /// WHERE the main thread actually spent the time. A single "worst gap" told us a worker
    /// run still cost 157 ms and left us guessing which part of the round trip did it — and
    /// guessing is how you spend a day bisecting the wrong layer. So the number is broken
    /// into the three places it can possibly come from:
    ///
    ///   submit  the frame we called `submit()`. Blame: staging the 4 MB payload (a Zig
    ///           alloc + memcpy, then a JS-owned copy), and — the first time only — bringing
    ///           the worker pool up, which `available()` does lazily INSIDE a frame.
    ///   wait    the worst frame while the worker was actually working. This one SHOULD be
    ///           ~16 ms. If it is not, the work is not really off-thread and the feature is
    ///           a lie.
    ///   land    the frame the result arrived. Blame: allocating and copying the 2.7 MB PNG
    ///           back out of the host.
    submit_ms: f32 = 0,
    wait_ms: f32 = 0,
    land_ms: f32 = 0,

    /// LAND is 149 ms and does not shrink with repetition, so it is not a one-off
    /// `memory.grow` — and `submit` allocates a BIGGER buffer (4 MB) in 17 ms, so a large
    /// wasm_allocator alloc is not inherently slow either. Both of my hypotheses died.
    ///
    /// So: stop inferring from frame gaps and time the landing frame from the inside.
    /// `poll_ms` is wall-clock around `job.poll()` alone — the alloc, the copy-out, the
    /// handle retire. If the 149 ms is in there, it is ours. If it is NOT, the cost is
    /// elsewhere in the frame (GC from churning 7 MB a run is the next suspect) and no
    /// amount of tuning `poll` would have touched it.
    poll_ms: f32 = 0,
    /// `pollInto` crosses into JS exactly twice: ask if the result is ready, then copy it
    /// out. With the allocation gone it STILL costs 93 ms for 2.7 MB — 29 MB/s, when a
    /// native `TypedArray.set` runs at gigabytes/sec. So one of these two is not what it
    /// looks like, and the only way to know which is to time them apart.
    ready_ms: f32 = 0,
    copy_ms: f32 = 0,
    phase: enum { idle, submitted, waiting, landed } = .idle,

    /// Keep watching for a few frames after the work "finishes".
    ///
    /// Load-bearing. A main-thread encode BLOCKS INSIDE its own frame, so the frame time that
    /// proves it only arrives on the NEXT frame. Clearing `watching` the moment the encode
    /// returned meant the 233 ms this example exists to show was never actually recorded —
    /// the headline number could not measure itself.
    settle: u32 = 0,
    ran_on: enum { nothing, main_thread, worker } = .nothing,

    /// Which run this is. A wasm `memory.grow` is paid ONCE — if `land` collapses on run 2,
    /// the 2.7 MB result alloc was growing the heap, and the fix is to keep a buffer rather
    /// than allocate one per job.
    runs: u32 = 0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);

    const pixels: []u8 = try gpa.alloc(u8, dim * dim * 4);
    // ONCE, and sized from the REGISTRY rather than from a number typed here.
    //
    // A hand-written constant that drifts from `max_output` does not fail loudly — it fails as
    // `Error.OutputTooLarge`, on a phone, on the frame a result lands. The registry already
    // knows the answer; there is no reason to know it twice.
    const result_buf: []u8 = try gpa.alloc(u8, kernels.registry.max_output);
    for (0..dim * dim) |i| {
        const x: u32 = @intCast(i % dim);
        const y: u32 = @intCast(i / dim);
        // Gradients plus noise: compresses like a real screenshot, so the encoder does
        // real work rather than running away with a trivial RLE.
        pixels[i * 4 + 0] = @truncate(x ^ y);
        pixels[i * 4 + 1] = @truncate(x +% y);
        pixels[i * 4 + 2] = @truncate((i *% 2654435761) >> 24);
        pixels[i * 4 + 3] = 255;
    }

    s.* = .{
        .gpa = gpa,
        .result_buf = result_buf,
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
        .pixels = pixels,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    s.job.deinit(); // cancels it host-side too, if it is still in flight
    gpa.free(s.pixels);
    gpa.free(s.result_buf);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    // ---- the measurement -----------------------------------------------------
    // The worst gap between frames while a job was outstanding. On the main thread this
    // reads ~233 ms (the frame simply did not happen). On a worker it reads ~17 ms.
    const gap_ms: f32 = f.time.delta_time * 1000.0;
    if (s.watching) {
        if (gap_ms > s.worst_gap_ms) {
            s.worst_gap_ms = gap_ms;
        }
        // Attribute this frame's cost to the phase that CAUSED it. A dispatch blocks inside
        // its own frame, so the cost always lands on the frame AFTER — which is why the
        // phase advances here, one frame late, rather than at the call site.
        switch (s.phase) {
            .submitted => {
                s.submit_ms = gap_ms;
                s.phase = .waiting;
            },
            .waiting => {
                if (gap_ms > s.wait_ms) {
                    s.wait_ms = gap_ms;
                }
            },
            .landed => {
                // The landing frame AND the ones just after it: the 2.7 MB copy-out, the
                // free, and any wasm `memory.grow` the alloc triggered can all land a frame
                // or two late. Attribute the whole tail here rather than let it hide in
                // `.idle` and surface only as an unexplained `worst`.
                if (gap_ms > s.land_ms) {
                    s.land_ms = gap_ms;
                }
            },
            .idle => {},
        }
        if (s.settle > 0) {
            s.settle -= 1;
        }
    }

    // ---- collect the job -----------------------------------------------------
    // One line, once a frame, never blocks. Identical whether a real worker ran it or
    // the inline fallback did.
    const t_poll0: f64 = z.wgpu.nowMs();
    if (s.job.pollInto(s.result_buf)) |maybe_png| {
        if (maybe_png) |png| {
            s.png_kb = png.len / 1024;
            // Cheap end-to-end proof that the bytes really crossed two wasm instances
            // intact: a PNG starts with this signature.
            s.png_ok = png.len > 8 and std.mem.eql(u8, png[0..4], &[_]u8{ 0x89, 'P', 'N', 'G' });
            s.phase = .landed; // the copy-out cost shows up on the NEXT frame
            s.settle = 3;
            s.job.deinit();
        }
    } else |err| {
        std.log.err("worker_png: job failed: {s}", .{@errorName(err)});
        s.watching = false;
        s.job.deinit();
    }
    const poll_took: f32 = @floatCast(z.wgpu.nowMs() - t_poll0);
    if (s.phase == .landed and poll_took > s.poll_ms) {
        s.poll_ms = poll_took;
        s.ready_ms = jobs.last_ready_ms;
        s.copy_ms = jobs.last_copy_ms;
    }

    // The watch ends only after the settle frames, so the blocking frame's cost is counted.
    if (s.watching and s.settle == 0 and !s.job.inFlight() and s.png_kb > 0) {
        s.watching = false;
    }

    z.clearViewport(f, .{ .r = 11, .g = 15, .b = 24, .a = 255 });
    const u: z.ui_real.Ui = s.ui_host.begin(f);

    const fw: f32 = f.window.widthf();

    // ---- the orbiting dot: its smoothness IS the demo ------------------------
    // A frozen frame stops it dead. You cannot miss it, and you cannot fake it.
    const cx: f32 = fw * 0.5;
    const cy: f32 = 110.0;
    const angle: f32 = f.time.time * 3.0;
    const orbit: f32 = 46.0;
    f.gl.circle(.{ cx, cy }, 52.0, .{ .color = .{ .r = 22, .g = 30, .b = 48, .a = 255 }, .segments = 32 });
    f.gl.circle(
        .{ cx + orbit * cos(angle), cy + orbit * sin(angle) },
        11.0,
        .{ .color = .{ .r = 126, .g = 231, .b = 135, .a = 255 }, .segments = 16 },
    );

    // ---- the buttons ---------------------------------------------------------
    u.setNextWindowPos(.{ 8, 190 }, .{});
    u.setNextWindowSize(.{ fw - 16, 330 }, .{}); // tall enough that no number hides below the fold
    if (u.window("encode a 1024x1024 PNG", .{})) |w| {
        defer w.close();

        const busy: bool = s.job.inFlight();

        const bh: f32 = 44.0; // a real tap target; this is a phone-first engine
        if (u.button("Encode on the MAIN THREAD", .{ .size = .{ 0, bh } }) and !busy) {
            s.worst_gap_ms = 0;
            s.submit_ms = 0;
            s.wait_ms = 0;
            s.land_ms = 0;
            s.watching = true;
            s.settle = 0;
            s.phase = .submitted; // the whole encode happens inside this one frame
            s.ran_on = .main_thread;
            // The bad way, kept on purpose. This BLOCKS the frame for ~240 ms — the dot
            // stops, and `worst frame gap` below records exactly how long for.
            if (z.codecs.png.encode(s.gpa, s.pixels, dim, dim)) |png| {
                defer s.gpa.free(png);
                s.png_kb = png.len / 1024;
                s.png_ok = true;
            } else |err| {
                std.log.err("worker_png: main-thread encode failed: {s}", .{@errorName(err)});
            }
            // NOT `s.watching = false` — see `settle`. The 240 ms just spent blocking shows
            // up as the NEXT frame's delta, and stopping the watch here would discard it.
            s.settle = 3;
        }

        if (u.button("Encode on a WORKER", .{ .size = .{ 0, bh } }) and !busy) {
            s.worst_gap_ms = 0;
            s.submit_ms = 0;
            s.wait_ms = 0;
            s.land_ms = 0;
            s.poll_ms = 0;
            s.watching = true;
            s.settle = 0;
            s.phase = .submitted;
            s.ran_on = .worker;
            s.runs += 1;
            // The good way. Returns IMMEDIATELY; `poll` above collects it whenever it
            // lands. Note the kernel is named by the FUNCTION, not a string — so a typo
            // is a compile error, not a NoSuchKernel at runtime.
            s.job = kernels.registry.submit(
                s.gpa,
                kernels.encodePng,
                .{ .w = dim, .h = dim },
                s.pixels,
            ) catch |err| blk: {
                std.log.err("worker_png: submit failed: {s}", .{@errorName(err)});
                s.watching = false;
                break :blk .{};
            };
        }

        u.separator();

        u.text("workers: {s}", .{
            if (jobs.parallel()) "available" else "UNAVAILABLE - running inline",
        });
        if (s.png_kb > 0) {
            u.text("png: {d} KB  signature {s}  (ran on {s})", .{
                s.png_kb,
                if (s.png_ok) "OK" else "BAD",
                @tagName(s.ran_on),
            });
        }
        // THE number, DECOMPOSED. `wait` is the one that matters: it is the only one that
        // says whether the work is really off the main thread.
        const dropped: f32 = s.worst_gap_ms / 16.7;
        u.textColored(
            if (s.worst_gap_ms > 34.0) z.colors.red_400 else z.colors.emerald_400,
            "worst gap {d:.0} ms  (~{d:.0} frames dropped)",
            .{ s.worst_gap_ms, @max(0.0, dropped - 1.0) },
        );
        u.textColored(
            if (s.wait_ms > 34.0) z.colors.red_400 else z.colors.emerald_400,
            "  WAIT   {d:.0} ms  <- is the work really off-thread?",
            .{s.wait_ms},
        );
        u.text("  submit {d:.0} ms  (4 MB staged + copied to the worker)", .{s.submit_ms});
        u.textColored(
            if (s.land_ms > 34.0) z.colors.red_400 else z.colors.emerald_400,
            "  LAND   {d:.0} ms  (2.7 MB PNG alloc'd + copied back)",
            .{s.land_ms},
        );
        u.textColored(
            if (s.poll_ms > 34.0) z.colors.red_400 else z.colors.emerald_400,
            "    pollInto {d:.0} ms  = ready {d:.0} + copy {d:.0}",
            .{ s.poll_ms, s.ready_ms, s.copy_ms },
        );
        u.text("run #{d}   (2.7 MB copy should be ~2 ms)", .{s.runs});
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - jobs - PNG encode on a worker",
            .width = 420,
            .height = 480,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
