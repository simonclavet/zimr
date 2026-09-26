//! examples/four_ways/four_ways.zig - ONE Zig function, FOUR machines.
//!
//! `escape.zig` is seven lines and says nothing about threads, GPUs or compile time. This
//! app runs it on all four:
//!
//!   comptime  a 32x16 fractal in CHARACTERS, computed before the program existed. The
//!             binary holds the text and no loop at all.
//!   cpu       the real fractal, on the main thread. Watch the frame hitch.
//!   worker    the same work, on another core. Watch it NOT hitch.
//!   gpu       12288 invocations, 64 wide.
//!
//! The three runtime panels share the KERNEL (`escape_kernel.zig`); all four share the
//! FUNCTION. That distinction is the honest one, and you can see it: the comptime panel is
//! the same shape, drawn in characters.
//!
//! And the point the demo actually exists to make: **the backends are interchangeable in
//! CODE, not in COST.** The lines that dispatch them are identical -
//!
//!     pipe.run("mandel", n);                     // cpu | worker | gpu
//!     if (pipe.readLatest(.out)) |px| { ... }    // same line for all three
//!
//! - and their costs span four orders of magnitude. Both halves are true, and a demo that
//! showed only the first would be a magic trick with a false bottom.
const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const fk = @import("escape_kernel.zig");
const escape = @import("escape.zig").escape;

const Allocator = std.mem.Allocator;
const Vec2 = zm.Vec2;
const float = zm.float;
const clamp = zm.clamp;
const bufPrint = std.fmt.bufPrint;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Pipe = z.Compute(fk);

/// Each kernel's transpiled WGSL, embedded by the build.
const kernel_wgsls: [fk.kernels.len]Pipe.KernelWgsl = blk: {
    var arr: [fk.kernels.len]Pipe.KernelWgsl = undefined;
    for (fk.kernels, 0..) |name, i| {
        arr[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    break :blk arr;
};

// ---------------------------------------------------------------------------------------
// MACHINE 1 - COMPTIME.
//
// The strange one, and it earns its place by being strange: this fractal's pixels were
// decided before the program ran. There is no loop in the binary for it - just the text.
//
// Note what is being called: `escape`, the FUNCTION. Not the kernel. The kernel indexes
// `M.g.B`, a module-level `var`, and comptime cannot touch runtime memory. So comptime gets
// the function and the other three get the kernel that wraps it - which is exactly the
// claim this demo is making, and the reason it is worth making.
const ascii_w: usize = 40;
const ascii_h: usize = 18;
const ramp = " .:-=+*#%@";

const ascii_art: [ascii_h][ascii_w]u8 = blk: {
    @setEvalBranchQuota(2_000_000);
    var rows: [ascii_h][ascii_w]u8 = undefined;
    for (0..ascii_h) |py| {
        for (0..ascii_w) |px| {
            const u: f32 = (float(@as(u32, @intCast(px))) / ascii_w - 0.5) * 3.0 - 0.6;
            const v: f32 = (float(@as(u32, @intCast(py))) / ascii_h - 0.5) * 2.2;
            const it: u32 = escape(u, v, 40); // <-- THE SAME FUNCTION, at compile time
            const idx: usize = @min(it * ramp.len / 40, ramp.len - 1);
            rows[py][px] = ramp[idx];
        }
    }
    break :blk rows;
};

const Machine = enum { comptime_, cpu, worker, gpu };

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,

    /// Three pipes, three backends, ONE module. Each owns its own state - a `.cpu` pipe and
    /// a `.worker` pipe on the same module used to contaminate each other through kompute's
    /// module-level globals; they no longer can, which is what makes this panel layout
    /// possible at all.
    cpu: Pipe,
    worker: ?Pipe = null,
    gpu: Pipe,

    /// Pixels, per machine, as `escape` returned them.
    img: [3][fk.pixels]u32 = @splat(@splat(0)),

    /// Has this pipe been DISPATCHED since the app started?
    ///
    /// Load-bearing, and I got it wrong the first time. A `.cpu` pipe's `readLatest` is
    /// never "not ready" - it hands back `M.g.B` directly - so polling it before any
    /// dispatch returns the ZEROED buffer, and the panel cheerfully drew 12288 pixels of
    /// `escape = 0`. Uniform dark blue, no fractal, and no error anywhere. The `.gpu` and
    /// `.worker` arms genuinely do return null until their readback lands; `.cpu` cannot,
    /// because there is nothing asynchronous about it. So the app has to remember.
    sent: [3]bool = @splat(false),
    got: [3]bool = @splat(false),
    ms: [3]f32 = @splat(0),

    /// Worst frame gap seen since this machine's dispatch - the number the whole demo rests
    /// on, and the first version could not see it.
    ///
    /// Two reasons it read 0 ms while the main thread stalled for two seconds:
    ///
    ///   * `gap_watch` was ONE slot, so `RUN ALL` (cpu, then worker, then gpu) left it
    ///     pointing at `.gpu`. The CPU's stall was charged to the GPU, or to nobody.
    ///   * a `.cpu` pipe finishes SYNCHRONOUSLY, so `got[cpu]` went true on the same frame as
    ///     the dispatch - clearing the watch BEFORE the next frame could report the gap the
    ///     dispatch had just caused. The cost always lands on the frame AFTER.
    ///
    /// So: watch one machine at a time, and keep watching for a few frames after it lands.
    worst_gap_ms: [3]f32 = @splat(0),
    gap_watch: ?Machine = null,
    settle: u32 = 0,

    /// `RUN ALL` STAGGERS the three, one per frame-window. Dispatching them together would
    /// confound the measurement outright: the worker and the GPU would be charged for the
    /// two seconds the CPU spent blocking the same frame they were queued on.
    queue: [3]Machine = undefined,
    queue_len: usize = 0,
    queue_i: usize = 0,

    zoom: f32 = 1.0,

    /// Deliberately EXPENSIVE. At 64 iterations the CPU pass is ~800k inner steps - two
    /// milliseconds, no hitch, and the `.worker` panel has nothing to prove. The demo only
    /// says anything if the main-thread pass actually costs you frames, so the default is
    /// 12288 px x 1500 = ~18M steps, which visibly stalls a phone.
    max_iter: u32 = 1500,
    running: ?Machine = null,
};

fn paramsNow(s: *const State) fk.Params {
    return .{
        .max_iter = s.max_iter,
        .w = fk.width,
        .h = fk.height,
        .cx = -0.6,
        .cy = 0.0,
        .zoom = s.zoom,
    };
}

fn slot(m: Machine) usize {
    return switch (m) {
        .comptime_ => 0, // never used - comptime has no pipe
        .cpu => 0,
        .worker => 1,
        .gpu => 2,
    };
}

/// Dispatch `escape` on one machine. **These two lines are identical for all three.** That
/// is the entire feature; everything else in this file is presentation.
fn dispatch(s: *State, m: Machine) void {
    const p: *Pipe = switch (m) {
        .cpu => &s.cpu,
        .worker => &(s.worker orelse return),
        .gpu => &s.gpu,
        .comptime_ => return,
    };
    p.element_count = fk.pixels;
    p.params = paramsNow(s);
    p.run("mandel", fk.pixels); // <-- cpu | worker | gpu

    s.sent[slot(m)] = true;
    s.got[slot(m)] = false;
    s.worst_gap_ms[slot(m)] = 0;
    s.gap_watch = m;
    s.settle = 3; // keep watching past the landing frame - the cost shows up AFTER
    s.running = m;
}

fn poll(s: *State, m: Machine) void {
    const i: usize = slot(m);
    if (s.got[i] or !s.sent[i]) {
        return; // never dispatched -> `.cpu` would hand back a zeroed g.B and look "done"
    }
    const p: *Pipe = switch (m) {
        .cpu => &s.cpu,
        .worker => &(s.worker orelse return),
        .gpu => &s.gpu,
        .comptime_ => return,
    };
    if (p.readLatest(.out)) |px| { // <-- and this line is identical too
        @memcpy(s.img[i][0..@min(px.len, fk.pixels)], px[0..@min(px.len, fk.pixels)]);
        s.got[i] = true;
        if (s.running == m) {
            s.running = null;
        }
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);

    s.* = .{
        .gpa = gpa,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .cpu = Pipe.initCpu(),
        .gpu = try Pipe.initGpu(gpa, f.gpu.device, f.gpu.queue, &kernel_wgsls),
    };
    // The worker backend needs a kernel wasm. If the page did not ship one - or the browser
    // refused `new Worker()` - `jobs` runs the kernel INLINE and the panel behaves exactly
    // like the CPU one, hitch and all. That is the honest fallback, and it is why the panel
    // reports which it got rather than assuming.
    s.worker = Pipe.initWorker(gpa) catch null;
}

fn update(f: *z.Frame, s: *State) void {
    const t_frame: f32 = f.time.delta_time * 1000.0;

    // The number that tells the truth. A dispatch that blocks the main thread shows up here
    // as a spike; one that does not, does not.
    if (s.gap_watch) |m| {
        const i: usize = slot(m);
        if (t_frame > s.worst_gap_ms[i]) {
            s.worst_gap_ms[i] = t_frame;
        }
        if (s.got[i]) {
            // Landed - but do NOT stop watching yet. A `.cpu` dispatch blocks INSIDE its
            // frame, so the frame time that proves it only arrives on the next one.
            if (s.settle > 0) {
                s.settle -= 1;
            } else {
                s.gap_watch = null;
            }
        }
    }

    poll(s, .cpu);
    poll(s, .worker);
    poll(s, .gpu);

    // One at a time, so each machine's gap is ITS OWN.
    if (s.queue_i < s.queue_len and s.gap_watch == null) {
        dispatch(s, s.queue[s.queue_i]);
        s.queue_i += 1;
    }

    z.clearViewport(f, z.colors.slate_900);
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    // Twice the old size. The SOURCE gets its own, smaller size: it is code, its longest
    // line is ~56 characters, and a monospace listing that overflows the canvas is worse
    // than a small one.
    const fsz: f32 = clamp(w / 26.0, 16.0, 30.0);
    const src_fsz: f32 = clamp(w / 54.0, 9.0, 15.0);

    // The control bar goes at the TOP. It used to sit at the bottom of a canvas taller than
    // a phone viewport, which put it off-screen entirely - the demo shipped with no reachable
    // RUN button.
    const bar_h: f32 = fsz * 5.6;
    var y: f32 = bar_h + fsz * 0.8;

    // ---- the source. It is seven lines, so show it, and let the viewer confirm there is
    // no annotation, no attribute, no pragma. That IS the demo.
    const src = [_][]const u8{
        "pub fn escape(cx: f32, cy: f32, max: u32) u32 {",
        "    var x: f32 = 0.0;  var y: f32 = 0.0;  var i: u32 = 0;",
        "    while (i < max and x * x + y * y < 4.0) : (i += 1) {",
        "        const t: f32 = x * x - y * y + cx;",
        "        y = 2.0 * x * y + cy;",
        "        x = t;",
        "    }",
        "    return i;",
        "}",
    };
    for (src) |line| {
        f.gl.text(.{ fsz * 0.5, y }, line, .{
            .size = src_fsz,
            .color = z.colors.slate_400,
            .font = &s.font,
        });
        y += src_fsz * 1.25;
    }
    y += fsz * 0.5;
    f.gl.text(.{ fsz * 0.5, y }, "ONE function.  FOUR machines.", .{
        .size = fsz,
        .color = z.colors.amber_400,
        .font = &s.font,
    });
    y += fsz * 1.3;
    // The point, said out loud. Four identical fractals prove nothing on their own - the
    // claim is about WHERE the same seven lines ran, and what each one COST.
    f.gl.text(
        .{ fsz * 0.5, y },
        "RUN ALL, then compare the frame gaps.",
        .{ .size = fsz * 0.8, .color = z.colors.slate_400, .font = &s.font },
    );
    y += fsz * 1.6;

    // ---- four panels.
    const panel_w: f32 = (w - fsz * 3.0) / 2.0;
    const panel_h: f32 = (h - y - fsz * 3.0) / 2.0;
    drawPanel(f, s, .comptime_, .{ fsz, y }, .{ panel_w, panel_h }, fsz);
    drawPanel(f, s, .cpu, .{ fsz * 2.0 + panel_w, y }, .{ panel_w, panel_h }, fsz);
    drawPanel(f, s, .worker, .{ fsz, y + panel_h + fsz }, .{ panel_w, panel_h }, fsz);
    drawPanel(f, s, .gpu, .{ fsz * 2.0 + panel_w, y + panel_h + fsz }, .{ panel_w, panel_h }, fsz);

    // ---- controls. A WINDOW is not optional: `u.button` outside one draws nothing, which
    // is how the first build shipped with no RUN button and four panels of zeroes.
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    u.style().font_size = fsz;
    u.style().frame_padding = .{ fsz * 0.35, fsz * 0.3 };
    u.style().item_spacing = .{ fsz * 0.4, fsz * 0.4 };
    u.style().window_padding = .{ fsz * 0.5, fsz * 0.5 };
    u.style().title_bar_height = fsz * 1.6;

    u.setNextWindowPos(.{ 0, 0 }, .{});
    u.setNextWindowSize(.{ w, bar_h }, .{});
    if (u.window("run", .{ .flags = .{
        .no_move = true,
        .no_resize = true,
        .no_title_bar = true,
    } })) |win| {
        defer win.close();
        const bh: f32 = fsz * 2.0;
        const bw: f32 = @min((w - fsz * 3.0) / 4.0, fsz * 8.0);

        if (u.button("RUN ALL", .{ .size = .{ bw, bh } })) {
            s.queue = .{ .cpu, .worker, .gpu };
            s.queue_len = 3;
            s.queue_i = 0;
        }
        u.sameLine(.{});
        if (u.button("cpu", .{ .size = .{ bw * 0.8, bh } })) {
            dispatch(s, .cpu);
        }
        u.sameLine(.{});
        if (u.button("worker", .{ .size = .{ bw * 0.8, bh } })) {
            dispatch(s, .worker);
        }
        u.sameLine(.{});
        if (u.button("gpu", .{ .size = .{ bw * 0.8, bh } })) {
            dispatch(s, .gpu);
        }

        // Row 2 - the cost knob. No keyboard on a phone, so halve/double buttons rather
        // than a slider: the whole useful range in a few taps.
        if (u.button("iter /2", .{ .size = .{ bw * 0.8, bh } })) {
            s.max_iter = @max(64, s.max_iter / 2);
        }
        u.sameLine(.{});
        if (u.button("iter x2", .{ .size = .{ bw * 0.8, bh } })) {
            s.max_iter = @min(12000, s.max_iter * 2);
        }
        u.sameLine(.{});
        u.text("iter {d}   workers {s}", .{
            s.max_iter,
            if (z.jobs.parallel()) "REAL" else "INLINE (no worker wasm)",
        });
    }
    s.ui_host.render(f);
}

fn drawPanel(
    f: *z.Frame,
    s: *State,
    m: Machine,
    at: Vec2,
    size: Vec2,
    fsz: f32,
) void {
    f.gl.rect(
        .{ .x = at[0], .y = at[1], .width = size[0], .height = size[1] },
        .{ .color = z.colors.slate_700, .outline = 1.0 },
    );

    const title: []const u8 = switch (m) {
        .comptime_ => "comptime",
        .cpu => "CPU - main thread",
        .worker => "CPU - worker",
        .gpu => "GPU - compute",
    };
    // Short, because they are now twice the size and the panel is half the width.
    const caption: []const u8 = switch (m) {
        .comptime_ => "ran in the COMPILER",
        .cpu => "BLOCKS the frame",
        .worker => "another core. NO hitch",
        .gpu => "SPIR-V. 12288 at once",
    };
    f.gl.text(.{ at[0] + fsz * 0.4, at[1] + fsz * 0.3 }, title, .{
        .size = fsz,
        .color = z.colors.sky_300,
        .font = &s.font,
    });
    f.gl.text(.{ at[0] + fsz * 0.4, at[1] + fsz * 1.3 }, caption, .{
        .size = fsz * 0.75,
        .color = z.colors.slate_500,
        .font = &s.font,
    });

    const body_y: f32 = at[1] + fsz * 2.6;

    if (m == .comptime_) {
        // The binary holds these characters. There is no loop for them anywhere in the
        // program - the answer existed before the program did.
        const cw: f32 = @min(size[0] / float(ascii_w + 1), fsz * 0.5);
        var yy: f32 = body_y;
        for (ascii_art) |row| {
            f.gl.text(.{ at[0] + fsz * 0.4, yy }, &row, .{
                .size = cw * 1.6,
                .color = z.colors.emerald_400,
                .font = &s.font,
            });
            yy += cw * 1.5;
        }
        f.gl.text(.{ at[0] + fsz * 0.4, at[1] + size[1] - fsz * 1.5 }, "no loop in the binary", .{
            .size = fsz * 0.85,
            .color = z.colors.slate_500,
            .font = &s.font,
        });
        return;
    }

    const i: usize = slot(m);
    if (!s.got[i]) {
        const msg: []const u8 = if (s.running == m) "working..." else "tap RUN";
        f.gl.text(.{ at[0] + fsz * 0.4, body_y }, msg, .{
            .size = fsz,
            .color = z.colors.slate_500,
            .font = &s.font,
        });
        return;
    }

    // Draw the fractal as a grid of cells. Deliberately dumb - the interesting thing is the
    // number underneath, not the rendering.
    const cell: f32 = @min(
        (size[0] - fsz) / float(fk.width),
        (size[1] - fsz * 3.5) / float(fk.height),
    );
    for (0..fk.height) |py| {
        for (0..fk.width) |px| {
            const it: u32 = s.img[i][py * fk.width + px];
            if (it >= s.max_iter) {
                continue; // in the set - leave it black
            }
            const t: f32 = float(it) / float(s.max_iter);
            const c: zm.Color = .{
                .r = @intFromFloat(clamp(t * 3.0, 0, 1) * 90.0),
                .g = @intFromFloat(clamp(t * 2.0, 0, 1) * 190.0),
                .b = @intFromFloat(clamp(0.35 + t, 0, 1) * 255.0),
                .a = 255,
            };
            f.gl.rect(.{
                .x = at[0] + fsz * 0.4 + float(@as(u32, @intCast(px))) * cell,
                .y = body_y + float(@as(u32, @intCast(py))) * cell,
                .width = cell + 0.6,
                .height = cell + 0.6,
            }, .{ .color = c });
        }
    }

    // THE HONEST NUMBER. Not "how fast", but "did it cost you a frame".
    const gap: f32 = s.worst_gap_ms[i];
    const bad: bool = gap > 34.0; // two dropped frames at 60 Hz
    var buf: [96]u8 = undefined;

    // An INLINE worker is not a worker. Rather than let the panel imply a contrast it is not
    // making, it says so - a green 0 ms here with no real thread behind it would be a lie.
    if (m == .worker and !z.jobs.parallel()) {
        f.gl.text(
            .{ at[0] + fsz * 0.4, at[1] + size[1] - fsz * 1.5 },
            "NO WORKER - inline",
            .{ .size = fsz * 0.9, .color = z.colors.amber_400, .font = &s.font },
        );
        return;
    }

    const txt: []const u8 = bufPrint(&buf, "frame gap {d:.0} ms", .{gap}) catch "?";
    f.gl.text(.{ at[0] + fsz * 0.4, at[1] + size[1] - fsz * 1.5 }, txt, .{
        .size = fsz,
        .color = if (bad) z.colors.red_400 else z.colors.emerald_400,
        .font = &s.font,
    });
}

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.gpu.deinit();
    if (s.worker) |*wk| {
        wk.deinit();
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - one function, four machines",
            .width = 1000,
            .height = 760,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
