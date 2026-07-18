//! examples/rt_workers/rt_workers.zig — a path tracer, rendered across the worker pool.
//!
//! THE POINT: the pool has always been parallel — `pump()` hands every free worker a job off
//! the queue — but until `jobs.Group` existed, using it meant N Job values, N polls and N
//! done-flags open-coded in every app. So nobody did, and the pool ran ONE thread for its
//! entire life. This is the first thing that uses it.
//!
//! What you are looking at:
//!
//!   * Tiles pop in AS THEY LAND, out of order. That is not a presentation trick — it is what
//!     out-of-order completion actually looks like, and `Group.next()` hands them over in
//!     whatever order the workers finish.
//!   * The dot keeps spinning. It is the only part of this that cannot be faked, and in
//!     `worker_png` it is what finally exposed a 95 ms stall that every number said was fine.
//!   * "MAIN THREAD" renders the identical tiles with the identical kernel, inline. The image
//!     is the same; the dot stops dead.
//!
//! What this is NOT: a speedup benchmark. The pool takes half your cores and never more than
//! four, ON PURPOSE — it exists to give the frame back, not to chase throughput (bridge.zig
//! measured 8 workers at only ~3.4x aggregate, and a hot CPU throttles the GPU). Selling a
//! multiplier would be selling a number the engine deliberately declined to optimise.
const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const kernels = @import("kernels.zig");
const tracer = @import("tracer.zig");

const Allocator = std.mem.Allocator;
const jobs = z.jobs;
const Sphere = tracer.Sphere;
const float = zm.float;
const clamp = zm.clamp;
const normalize = zm.normalize;
const cos = zm.cos;
const sin = zm.sin;
const bufPrint = std.fmt.bufPrint;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

/// Small on purpose: a phone, a CPU, and a path tracer. The image is stretched to the canvas.
const rt_w: u32 = 320;
const rt_h: u32 = 240;
const n_tiles: u32 = 16;

const Group = kernels.registry.Group(kernels.traceTile);

const scene = [_]Sphere{
    // ground
    .{ .cx = 0, .cy = -100.5, .cz = -1, .r = 100, .mr = 0.55, .mg = 0.55, .mb = 0.6, .mat = tracer.mat_diffuse },
    // a red diffuse ball
    .{ .cx = -0.85, .cy = 0.0, .cz = -1.1, .r = 0.5, .mr = 0.85, .mg = 0.25, .mb = 0.25, .mat = tracer.mat_diffuse },
    // a metal ball
    .{ .cx = 0.0, .cy = 0.05, .cz = -1.25, .r = 0.55, .mr = 0.85, .mg = 0.86, .mb = 0.9, .mat = tracer.mat_metal },
    // a green diffuse ball
    .{ .cx = 0.95, .cy = -0.05, .cz = -1.0, .r = 0.45, .mr = 0.3, .mg = 0.75, .mb = 0.4, .mat = tracer.mat_diffuse },
    // a warm emitter, tucked behind
    .{ .cx = -0.3, .cy = 1.15, .cz = -1.9, .r = 0.55, .mr = 4.5, .mg = 3.4, .mb = 2.2, .mat = tracer.mat_light },
};

const Ran = enum { nothing, workers, main_thread };

/// Samples while dragging. Noisy on purpose: you are aiming, not admiring.
const preview_spp: u32 = 2;

/// Matches `rt_sidebyside`'s feel: 0.005 rad/px, and a distance range that keeps the scene
/// framed on a phone.
const orbit_opts: z.OrbitOptions = .{
    .orbit_sensitivity = 0.005,
    .min_distance = 1.4,
    .max_distance = 9.0,
    .min_pitch = -0.35,
    .max_pitch = 1.25,
    .fovy_deg = 45.0,
};

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,

    fb: z.CpuFramebuffer,
    pixels: []u8, // rt_w * rt_h * RGBA

    /// The result buffer, allocated ONCE from the registry's own bound. Handing this to
    /// `Group.next` every frame is what keeps the landing frame free: `poll()` would allocate
    /// on the frame a tile arrives, and we measured what that costs (154 ms for 2.7 MB).
    /// Asking `registry.max_output` rather than typing a number means it cannot drift — a
    /// hand-typed constant that is too small fails as `OutputTooLarge`, on a phone.
    tile_buf: []u8,

    group: ?Group = null,
    dirty: bool = false,

    samples: u32 = 24,
    bounces: u32 = 6,
    seed: u32 = 1,

    /// The engine's orbit camera — the same one `rt_sidebyside` uses. ONE call gives drag to
    /// orbit, pinch to zoom and two-finger pan, and it already handles the things a
    /// hand-rolled version gets wrong: touch as well as mouse, and skipping the first drag
    /// frame so the camera does not POP by the pointer's initial delta.
    ///
    /// I wrote a hand-rolled left-drag first. It was worse, and it was worse in the specific
    /// way that phone-only development punishes: it had no pinch, no pan, and a pop.
    cam: z.OrbitCamera = .init(zm.vec(0.0, 0.15, -1.15), 3.1),

    /// The camera pose we last RENDERED. A path trace cannot be realtime, so the render is
    /// driven by CHANGE, not by every frame.
    last_yaw: f32 = 999.0,
    last_pitch: f32 = 999.0,
    last_dist: f32 = 999.0,

    /// PROGRESSIVE REFINEMENT, and it is the whole reason this works on a phone.
    ///
    /// A path trace cannot be realtime. So while you drag we render at `preview_spp` (a
    /// couple of samples — noisy, instant, good enough to aim with), and the moment you let
    /// go we re-render at full quality. Both go through the pool, so the frame never stalls
    /// either way and the dot never stops.
    ///
    /// This only works because a render is CHEAP TO ABANDON: `Group.deinit` cancels every
    /// job still in flight, host-side too, so a drag that outruns the tracer discards stale
    /// tiles instead of queueing a backlog of renders nobody wants to see.
    preview: bool = false,
    settled_frames: u32 = 0,

    /// Whatever went wrong, ON SCREEN. `std.log.err` goes to a console the phone-only
    /// developer cannot see, so an example that only logs its failures is an example that
    /// fails silently — which is how this shipped rendering a black rectangle.
    err_msg: []const u8 = "",
    submitted: u32 = 0,

    ran: Ran = .nothing,
    worst_gap_ms: f32 = 0,
    watching: bool = false,
    settle: u32 = 0,
    tiles_in: u32 = 0,
    render_ms: f32 = 0,
    started_at: f64 = 0,
};

/// `zm.cross` is Vec4. This is three lines and unambiguous.
fn cross3(a: zm.Vec3, b: zm.Vec3) zm.Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

const Basis = struct {
    eye: zm.Vec3,
    right: zm.Vec3,
    up: zm.Vec3,
    fwd: zm.Vec3,
};

/// The orbit camera, as an eye plus an orthonormal basis. Computed ONCE per render, on the
/// host — the kernel does no trigonometry at all (see the note on `tracer.Tile`).
///
/// `OrbitCamera` works in `Vec` (4-wide); the tracer works in Vec3. The conversion happens
/// exactly here, once, rather than being sprinkled through the kernel.
fn cameraBasis(s: *const State) Basis {
    const e4: zm.Vec = s.cam.eye();
    const t4: zm.Vec = s.cam.target;
    const eye: zm.Vec3 = .{ e4[0], e4[1], e4[2] };
    const tgt: zm.Vec3 = .{ t4[0], t4[1], t4[2] };

    const fwd: zm.Vec3 = normalize(tgt - eye);
    const world_up: zm.Vec3 = .{ 0, 1, 0 };
    const right: zm.Vec3 = normalize(cross3(fwd, world_up));
    const up: zm.Vec3 = cross3(right, fwd);
    return .{ .eye = eye, .right = right, .up = up, .fwd = fwd };
}

fn tileHeaders(s: *const State, buf: []Group.H, tiles: u32, spp: u32) []Group.H {
    const cam: Basis = cameraBasis(s);
    const rows: u32 = (rt_h + tiles - 1) / tiles;
    var i: u32 = 0;
    while (i < tiles) : (i += 1) {
        const y0: u32 = i * rows;
        const y1: u32 = @min(y0 + rows, rt_h);
        buf[i] = .{
            .y0 = y0,
            .y1 = y1,
            .w = rt_w,
            .h = rt_h,
            .samples = spp,
            .bounces = if (spp <= preview_spp) 3 else s.bounces,
            .n_spheres = scene.len,
            .seed = s.seed,
            .ex = cam.eye[0],
            .ey = cam.eye[1],
            .ez = cam.eye[2],
            .rx = cam.right[0],
            .ry = cam.right[1],
            .rz = cam.right[2],
            .ux = cam.up[0],
            .uy = cam.up[1],
            .uz = cam.up[2],
            .fx = cam.fwd[0],
            .fy = cam.fwd[1],
            .fz = cam.fwd[2],
            .focal = 1.6,
        };
    }
    return buf[0..tiles];
}

/// Blit a landed band into the framebuffer. `index` is the tile's position in the header
/// slice we submitted — which is how an out-of-order result still knows where it belongs.
fn blitTile(s: *State, index: usize, bytes: []const u8) void {
    const rows: u32 = (rt_h + n_tiles - 1) / n_tiles;
    const y0: u32 = @as(u32, @intCast(index)) * rows;
    const y1: u32 = @min(y0 + rows, rt_h);
    const want: usize = @as(usize, rt_w) * (y1 - y0) * 4;
    if (bytes.len < want) {
        return; // a short band is a bug, not something to paper over with a partial blit
    }
    const dst_off: usize = @as(usize, y0) * rt_w * 4;
    @memcpy(s.pixels[dst_off .. dst_off + want], bytes[0..want]);
    s.dirty = true;
}

fn startRender(s: *State, use_workers: bool, spp: u32) void {
    if (s.group) |*g| {
        g.deinit(); // cancels anything still in flight, host-side too
        s.group = null;
    }
    @memset(s.pixels, 0);
    s.dirty = true;
    s.tiles_in = 0;
    s.err_msg = "";
    s.worst_gap_ms = 0;
    s.watching = true;
    s.settle = 0;
    s.seed +%= 1;
    s.started_at = z.wgpu.nowMs();
    s.ran = if (use_workers) .workers else .main_thread;
    s.preview = spp <= preview_spp;

    var hdr_buf: [n_tiles]Group.H = undefined;
    const headers: []Group.H = tileHeaders(s, &hdr_buf, n_tiles, spp);
    const payload: []const u8 = std.mem.sliceAsBytes(&scene);

    if (use_workers) {
        // ONE line submits every tile. The pool's `pump()` then hands one to each free worker,
        // and re-pumps as each finishes — so N tiles occupy min(N, pool_size) cores without
        // this example knowing anything about how many cores there are.
        const submitted_group: Group = Group.submitAll(s.gpa, headers, payload) catch |submit_error| {
            s.err_msg = @errorName(submit_error);
            s.watching = false;
            s.submitted = 0;
            return;
        };
        s.group = submitted_group;
        s.submitted = n_tiles;
        return;
    }

    // The bad way, kept on purpose: the SAME kernel, run inline, right here. The image comes
    // out identical — the tracer is deterministic, and there is a test that says so — and the
    // frame simply does not happen while it runs.
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    for (headers, 0..) |h, i| {
        var w: std.Io.Writer = .fixed(s.tile_buf);
        tracer.traceTile(arena.allocator(), h, payload, &w) catch |err| {
            s.err_msg = @errorName(err);
            continue;
        };
        blitTile(s, i, w.buffered());
        s.tiles_in += 1;
    }
    s.render_ms = @floatCast(z.wgpu.nowMs() - s.started_at);
    s.settle = 3; // the frame we just blocked shows up on the NEXT frame's delta
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 20);
    const pixels: []u8 = try gpa.alloc(u8, rt_w * rt_h * 4);
    @memset(pixels, 0);

    s.* = .{
        .gpa = gpa,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .pixels = pixels,
        .tile_buf = try gpa.alloc(u8, kernels.registry.max_output),
        .fb = z.CpuFramebuffer.init(f.gpu.device, f.gpu.queue, rt_w, rt_h, pixels, "rt_workers_fb"),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    if (s.group) |*g| {
        g.deinit();
    }
    gpa.free(s.pixels);
    gpa.free(s.tile_buf);
    s.fb.deinit();
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    // Render once on arrival, rather than showing a black rectangle and hoping someone taps.
    if (s.ran == .nothing and s.group == null) {
        startRender(s, true, s.samples);
    }

    const gap_ms: f32 = f.time.delta_time * 1000.0;
    if (s.watching) {
        if (gap_ms > s.worst_gap_ms) {
            s.worst_gap_ms = gap_ms;
        }
        if (s.settle > 0) {
            s.settle -= 1;
        } else if (s.group == null or s.group.?.complete()) {
            s.watching = false;
        }
    }

    // ---- collect whatever landed THIS FRAME -------------------------------------------
    // Several tiles can arrive in one frame, and they arrive OUT OF ORDER — whichever worker
    // finished first. `index` is how a band still knows where it belongs.
    if (s.group) |*tile_group| {
        // Drain everything that finished THIS FRAME. Several tiles can land in one frame, and
        // they land OUT OF ORDER — whichever worker got there first. `landed.index` is the
        // position in the header slice we submitted, which is how an out-of-order band still
        // knows which scanlines it belongs to.
        while (true) {
            const landed_tile_or_null: ?Group.Landed = tile_group.next(s.tile_buf) catch |tile_error| {
                // A tile whose kernel failed. Report it ON SCREEN — `std.log.err` writes to a
                // console a phone-only developer cannot read, and an example that only logs
                // its failures is an example that fails silently.
                //
                // Prefer the KERNEL's own error name ("ShortPayload") over the transport's
                // ("KernelFailed"). The first says what is wrong; the second says only that
                // something is.
                const kernel_name: []const u8 = tile_group.lastErrorName();
                s.err_msg = if (kernel_name.len >= 1) kernel_name else @errorName(tile_error);
                break;
            };

            const landed_tile: Group.Landed = landed_tile_or_null orelse {
                // Nothing more is ready this frame. This is the common case.
                break;
            };

            blitTile(s, landed_tile.index, landed_tile.bytes);
            s.tiles_in += 1;
        }

        const every_tile_has_landed: bool = tile_group.complete();
        if (every_tile_has_landed) {
            const now_ms: f64 = z.wgpu.nowMs();
            s.render_ms = @floatCast(now_ms - s.started_at);

            // Keep watching the frame gap for a few more frames. A cost incurred INSIDE a
            // frame only shows up in the NEXT frame's delta, so stopping here would discard
            // the very number this example exists to report.
            s.settle = 3;

            tile_group.deinit();
            s.group = null;
        }
    }

    if (s.dirty) {
        s.fb.update(f.gpu.queue, s.pixels);
        s.dirty = false;
    }

    z.clearViewport(f, .{ .r = 11, .g = 15, .b = 24, .a = 255 });
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    _ = h;
    const fsz: f32 = clamp(w / 30.0, 13.0, 26.0);
    const bar_h: f32 = fsz * 7.6;

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // ---- the image, BELOW the control bar ----------------------------------------------
    const img_w: f32 = w - fsz * 2.0;
    const img_h: f32 = img_w * float(rt_h) / float(rt_w);
    const img_x: f32 = fsz;
    const img_y: f32 = bar_h + fsz * 3.4;
    s.fb.present(f.gl, img_x, img_y, img_w, img_h);

    // ---- DRAG to orbit, PINCH to zoom, TWO FINGERS to pan --------------------------------
    // One call. It reads touch AND mouse, and skips the first drag frame so the camera does
    // not pop. `wantCaptureMouse` keeps a drag that starts on a button from spinning the
    // scene.
    _ = s.cam.update(f, u.wantCaptureMouse(), orbit_opts);

    // A path trace cannot be realtime, so the render is driven by CHANGE, not by frames.
    //
    // While the camera is moving we render at `preview_spp` — noisy, instant, good enough to
    // aim with. When it stops, we re-render at full quality. Both go through the pool, so the
    // frame never stalls either way and the dot never stops.
    //
    // This only works because a render is CHEAP TO ABANDON: `Group.deinit` cancels every job
    // still in flight, host-side too. A camera that outruns the tracer discards stale tiles
    // rather than queueing a backlog of renders nobody will ever see. And a preview only
    // starts when the pool is FREE, so fast drags skip renders instead of piling up.
    const moved: bool = s.cam.yaw != s.last_yaw or
        s.cam.pitch != s.last_pitch or
        s.cam.distance != s.last_dist;

    if (moved) {
        s.last_yaw = s.cam.yaw;
        s.last_pitch = s.cam.pitch;
        s.last_dist = s.cam.distance;
        s.settled_frames = 0;
        if (s.group == null) {
            startRender(s, true, preview_spp);
        }
    } else if (s.preview and s.group == null) {
        // Held still for a few frames after a preview — go to full quality. The delay stops a
        // twitchy finger from kicking off a 24 spp render it is about to invalidate.
        s.settled_frames += 1;
        if (s.settled_frames > 6) {
            startRender(s, true, s.samples);
        }
    }

    // ---- the dot. Its smoothness IS the claim. -----------------------------------------
    const cx: f32 = w * 0.5;
    const cy: f32 = bar_h + fsz * 1.6;
    const orbit_r: f32 = fsz * 1.2;
    const a: f32 = f.time.time * 3.0;
    f.gl.circle(.{ cx, cy }, fsz * 1.45, .{ .color = .{ .r = 22, .g = 30, .b = 48, .a = 255 }, .segments = 32 });
    f.gl.circle(
        .{ cx + orbit_r * cos(a), cy + orbit_r * sin(a) },
        fsz * 0.34,
        .{ .color = .{ .r = 126, .g = 231, .b = 135, .a = 255 }, .segments = 16 },
    );
    u.style().font_size = fsz;
    u.style().frame_padding = .{ fsz * 0.35, fsz * 0.3 };
    u.style().item_spacing = .{ fsz * 0.4, fsz * 0.4 };
    u.style().window_padding = .{ fsz * 0.5, fsz * 0.5 };

    u.setNextWindowPos(.{ 0, 0 }, .{});
    u.setNextWindowSize(.{ w, bar_h }, .{});
    if (u.window("render", .{ .flags = .{
        .no_move = true,
        .no_resize = true,
        .no_title_bar = true,
    } })) |win| {
        defer win.close();
        const busy: bool = s.group != null;
        const bw: f32 = @min((w - fsz * 2.5) / 2.0, fsz * 12.0);
        const bh: f32 = fsz * 2.0;

        if (u.button("RENDER on WORKERS", .{ .size = .{ bw, bh } }) and !busy) {
            startRender(s, true, s.samples);
        }
        u.sameLine(.{});
        if (u.button("on MAIN THREAD", .{ .size = .{ bw, bh } }) and !busy) {
            startRender(s, false, s.samples);
        }

        if (u.button("samples /2", .{ .size = .{ bw * 0.6, bh } }) and !busy) {
            s.samples = @max(1, s.samples / 2);
        }
        u.sameLine(.{});
        if (u.button("samples x2", .{ .size = .{ bw * 0.6, bh } }) and !busy) {
            s.samples = @min(512, s.samples * 2);
        }
        u.sameLine(.{});
        u.text("{d} spp", .{s.samples});

        u.text("DRAG THE IMAGE to orbit.  workers: {s}   tiles {d}/{d}", .{
            if (jobs.parallel()) "REAL" else "NONE - inline",
            s.tiles_in,
            n_tiles,
        });

        // THE number. Not "how fast" — "did it cost you the frame".
        var buf: [96]u8 = undefined;
        const bad: bool = s.worst_gap_ms > 34.0;
        const txt: []const u8 = bufPrint(
            &buf,
            "worst frame gap {d:.0} ms   render {d:.0} ms   [{s}]",
            .{ s.worst_gap_ms, s.render_ms, @tagName(s.ran) },
        ) catch "?";
        u.textColored(if (bad) z.colors.red_400 else z.colors.emerald_400, "{s}", .{txt});

        // The diagnostics that would otherwise be invisible: what we asked for, what came
        // back, and what broke. An example that logs its failures to a console nobody can
        // read is an example that fails silently.
        if (s.err_msg.len >= 1) {
            u.textColored(z.colors.red_400, "ERROR: {s}", .{s.err_msg});
        } else {
            u.text("submitted {d}  max_out {d} KB  band {d} KB", .{
                s.submitted,
                kernels.registry.max_output / 1024,
                (rt_w * ((rt_h + n_tiles - 1) / n_tiles) * 4) / 1024,
            });
        }
    }
    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - jobs - a path tracer across the worker pool",
            .width = 480,
            .height = 760,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
