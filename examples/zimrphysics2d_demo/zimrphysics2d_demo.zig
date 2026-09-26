//! zimrphysics2d_demo — a box2d-style testbed for the `zimrphysics2d` engine.
//!
//! The world is the single source of truth: each frame we step the solver on a fixed
//! timestep, then hand the whole world to `phys.draw`, which fires the DebugDraw
//! callbacks in render.zig to push batched geometry into the UI's background draw
//! list. A small control window switches scenes, pauses, zooms, and toggles the
//! joint / AABB / contact decoration layers.
//!
//! Drawing path rationale: see render.zig. One DebugDraw→DrawList adapter covers
//! every shape/joint/contact the engine emits, so scenes never write rendering code.

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const assertUnreachable = zm.assertUnreachable;
const float64 = zm.float64;
const builtin = @import("builtin");
const ui = z.ui_real;
const render = @import("render.zig");
const scenes = @import("scenes.zig");

const phys = z.zimrphysics2d;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const Rot2 = zm.Rot2;
const Transform2 = zm.Transform2;
const clamp = zm.clamp;
const transformPoint2 = zm.transformPoint2;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const backdrop: Color = .{ .r = 17, .g = 24, .b = 39, .a = 255 }; // slate-900
const leash_color: Color = .{ .r = 250, .g = 204, .b = 21, .a = 255 }; // amber drag line
const world_capacity: u32 = 2048;
const fixed_dt: f32 = 1.0 / 60.0;
// Determinism|SnapShot loop: capture a checkpoint at this sub-step, restore it at the later one
// (then rewind the counter to the capture point so the snap-back repeats). Mirrors box2d's 50/150.
const snapshot_capture_step: u32 = 50;
const snapshot_restore_step: u32 = 200;

// -- Pointer dragging: box2d v3.1's mouse-pick, a soft motor joint between the
// picked body and a movable anchor. The anchor *owns* the joint, so releasing is
// just destroyBody(anchor) — the joint is torn down with it.

/// An active drag. `anchor` is a static body parked at the pointer; the motor joint
/// (held by the anchor) pulls the picked body's grabbed point toward it.
const Drag = struct {
    anchor: phys.BodyHandle,
    picked: usize, // BodyIndex of the grabbed body (for the leash visual)
    grab_local: Vec2, // grabbed point in the picked body's local frame
};

/// World point → a body's local frame (inverse rigid transform: R(-θ)·(w − p)).
fn invTransformPoint(xf: Transform2, w: Vec2) Vec2 {
    const dx: f32 = w[0] - xf.p[0];
    const dy: f32 = w[1] - xf.p[1];
    const lx: f32 = xf.q.cosine * dx + xf.q.sine * dy;
    const ly: f32 = -xf.q.sine * dx + xf.q.cosine * dy;
    return .{ lx, ly };
}

/// Squared distance from a point to a segment, for capsule hit-testing.
fn pointSegDist2(p: Vec2, q1: Vec2, q2: Vec2) f32 {
    const ex: f32 = q2[0] - q1[0];
    const ey: f32 = q2[1] - q1[1];
    const len2: f32 = ex * ex + ey * ey;
    var t: f32 = 0.0;
    if (len2 > 1.0e-9) {
        t = clamp(((p[0] - q1[0]) * ex + (p[1] - q1[1]) * ey) / len2, 0.0, 1.0);
    }
    const cx: f32 = q1[0] + t * ex;
    const cy: f32 = q1[1] + t * ey;
    const dx: f32 = p[0] - cx;
    const dy: f32 = p[1] - cy;
    return dx * dx + dy * dy;
}

/// Exact point-in-shape test (local-space), so overlapping boxes pick cleanly.
fn pointInGeom(geom: phys.Geometry, xf: Transform2, world_pt: Vec2) bool {
    const local: Vec2 = invTransformPoint(xf, world_pt);
    switch (geom) {
        .circle => |c| {
            const dx: f32 = local[0] - c.center[0];
            const dy: f32 = local[1] - c.center[1];
            return dx * dx + dy * dy <= c.radius * c.radius;
        },
        .polygon => |p| {
            var i: u32 = 0;
            while (i < p.count) : (i += 1) {
                const dvx: f32 = local[0] - p.vertices[i][0];
                const dvy: f32 = local[1] - p.vertices[i][1];
                const dist: f32 = p.normals[i][0] * dvx + p.normals[i][1] * dvy;
                if (dist > p.radius) {
                    return false;
                }
            }
            return true;
        },
        .capsule => |c| {
            return pointSegDist2(local, c.center1, c.center2) <= c.radius * c.radius;
        },
        else => {
            return false;
        },
    }
}

const PickCtx = struct {
    world: *phys.World,
    point: Vec2,
    best: ?usize = null,
    best_d2: f32 = 0,
};

/// overlapAabb visitor: keep the nearest dynamic body whose shape contains the point.
fn pickCallback(shape: phys.ShapeIndex, cptr: *anyopaque) bool {
    const pc: *PickCtx = @ptrCast(@alignCast(cptr));
    const s: *const phys.Shape = &pc.world.shapes.data[shape];
    const bi: usize = s.body;
    const b: *const phys.Body = &pc.world.bodies.data[bi];
    if (b.motion_type != .dynamic) {
        return true;
    }
    if (!pointInGeom(s.geom, b.transform, pc.point)) {
        return true;
    }
    const dx: f32 = b.center[0] - pc.point[0];
    const dy: f32 = b.center[1] - pc.point[1];
    const d2: f32 = dx * dx + dy * dy;
    if (pc.best == null or d2 < pc.best_d2) {
        pc.best = bi;
        pc.best_d2 = d2;
    }
    return true; // scan all overlaps, then take the nearest
}

/// Grab whatever dynamic body sits under `world_pt`, if any.
fn beginDrag(s: *State, world_pt: Vec2) void {
    const eps: f32 = 0.01;
    const box: phys.Aabb2 = .{
        .lower = .{ world_pt[0] - eps, world_pt[1] - eps },
        .upper = .{ world_pt[0] + eps, world_pt[1] + eps },
    };
    var pc: PickCtx = .{ .world = &s.world, .point = world_pt };
    phys.overlapAabb(&s.world, box, .{}, pickCallback, &pc);
    const bi: usize = pc.best orelse return;

    const anchor: phys.BodyHandle = phys.createBody(&s.world, .{
        .motion_type = .static,
        .position = world_pt,
    }) catch return;
    const b: *const phys.Body = &s.world.bodies.data[bi];
    const grab_local: Vec2 = invTransformPoint(b.transform, world_pt);
    const mass: f32 = if (b.mass > 0.0) b.mass else 1.0;
    // Index-only handle: createJoint consumes body handles via `.index()` and stores
    // a BodyIndex, so a packed handle is the correct, complete input here.
    const picked: phys.BodyHandle = phys.BodyHandle.pack(@intCast(bi), 0);
    _ = phys.createMotorJoint(&s.world, .{
        .base = .{
            .body_a = anchor,
            .body_b = picked,
            .local_frame_a = Transform2.identity,
            .local_frame_b = .{ .p = grab_local, .q = Rot2.identity },
        },
        .linear_hertz = 6.0,
        .linear_damping_ratio = 0.7,
        .max_spring_force = 1000.0 * mass,
    }) catch {
        phys.destroyBody(&s.world, anchor);
        return;
    };
    s.drag = .{ .anchor = anchor, .picked = bi, .grab_local = grab_local };
}

fn endDrag(s: *State) void {
    if (s.drag) |dg| {
        phys.destroyBody(&s.world, dg.anchor); // frees the owned motor joint too
        s.drag = null;
    }
}

/// Wraps a child allocator and tracks live bytes of everything allocated through it. Both the
/// physics world AND the UI host are routed through it, so the "heap" HUD line is the demo's whole
/// tracked Zig-heap footprint — no per-subsystem blind spot (the UI path being untracked is what
/// let the zimr404 frame-arena leak hide). The "wasm total" HUD line is the ground-truth global
/// (every page, incl. untracked GPU/interop); a climb there with this flat localises a leak.
/// Heap-allocated (initState) so its self-pointer stays stable regardless of where State lives.
const CountingAllocator = struct {
    child: Allocator,
    bytes: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: Allocator.VTable = .{
        .alloc = allocImpl,
        .resize = resizeImpl,
        .remap = remapImpl,
        .free = freeImpl,
    };
    fn bump(self: *CountingAllocator) void {
        if (self.bytes > self.peak) {
            self.peak = self.bytes;
        }
    }
    fn allocImpl(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p: [*]u8 = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr) orelse return null;
        self.bytes += len;
        self.bump();
        return p;
    }
    fn resizeImpl(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (self.child.vtable.resize(self.child.ptr, buf, alignment, new_len, ret_addr) == false) {
            return false;
        }
        self.bytes = self.bytes + new_len - buf.len;
        self.bump();
        return true;
    }
    fn remapImpl(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p: ?[*]u8 = self.child.vtable.remap(self.child.ptr, buf, alignment, new_len, ret_addr);
        if (p != null) {
            self.bytes = self.bytes + new_len - buf.len;
            self.bump();
        }
        return p;
    }
    fn freeImpl(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, buf, alignment, ret_addr);
        self.bytes -= buf.len;
    }
};

const State = struct {
    gpa: Allocator,
    mem: *CountingAllocator,
    ui_host: z.UiHost,
    font: z.Font,
    world: phys.World,
    cam: render.Camera2D = .{ .flip_y = true },
    current_scene: usize = 0,
    cat_index: usize = 0,
    scene_state: scenes.SceneState = .{},
    time: f32 = 0,
    phys_accum: f32 = 0,
    paused: bool = false,
    draw_joints: bool = false,
    draw_aabbs: bool = false,
    draw_contacts: bool = false,
    drag: ?Drag = null,
    // On-screen control-button held state (set during UI build, read by `control` scenes).
    btn: scenes.SceneInput = .{},
    // Smoothed perf readout (exponential moving averages over recent frames).
    perf_frame_ms: f32 = 0,
    perf_phys_ms: f32 = 0,
    perf_draw_ms: f32 = 0,
    perf_substeps: u32 = 0,
    // World snapshot for the Determinism|SnapShot scene (host-driven capture/restore loop).
    snap: ?phys.WorldSnapshot = null,
};

fn loadScene(s: *State, idx: usize) !void {
    s.drag = null; // old anchor/joint die with the old world
    if (s.snap) |*sn| {
        sn.deinit(s.mem.allocator());
        s.snap = null;
    }
    s.world.deinit(s.mem.allocator());
    s.world = try phys.World.init(s.mem.allocator(), world_capacity);
    s.world.settings.gravity = .{ 0, -10 };
    s.current_scene = idx;
    s.cat_index = scenes.categoryIndex(scenes.list[idx].category);
    s.phys_accum = 0;
    s.scene_state = .{};
    s.btn = .{};
    const sc: scenes.Scene = scenes.list[idx];
    if (sc.build_s) |f| {
        try f(&s.world, &s.scene_state);
    } else if (sc.build) |f| {
        try f(&s.world);
    }
    // Per-scene camera framing (default when the scene gives no hint).
    if (scenes.list[idx].cam) |ch| {
        s.cam.target = ch.target;
        s.cam.zoom = ch.ppm;
    } else {
        s.cam.target = .{ 0, 4.5 };
        s.cam.zoom = 34;
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    const mem: *CountingAllocator = try gpa.create(CountingAllocator);
    mem.* = .{ .child = gpa };
    var world: phys.World = try phys.World.init(mem.allocator(), world_capacity);
    world.settings.gravity = .{ 0, -10 };
    try scenes.list[0].build.?(&world);
    s.* = .{
        .gpa = gpa,
        .mem = mem,
        .ui_host = z.UiHost.init(mem.allocator(), font),
        .font = font,
        .world = world,
        .cam = .{ .target = .{ 0, 4.5 }, .zoom = 34, .flip_y = true },
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    if (s.snap) |*sn| {
        sn.deinit(s.mem.allocator());
        s.snap = null;
    }
    s.world.deinit(s.mem.allocator());
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    gpa.destroy(s.mem);
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, backdrop);
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    s.cam.offset = .{ f.window.widthf() * 0.5, f.window.heightf() * 0.5 };

    // Pointer drag (mouse or primary touch). Resolve the pointer in world space, then
    // begin / move / end the soft drag *before* stepping so the solver sees the new
    // target this frame. wantCaptureMouse() keeps clicks on the UI from grabbing.
    const pointer_world: Vec2 = s.cam.screenToWorld(z.getMousePosition(f.input));
    if (s.drag != null) {
        if (z.isMouseButtonDown(f.input, .left)) {
            phys.setTransform(&s.world, s.drag.?.anchor, pointer_world, Rot2.identity) catch
                assertUnreachable(@src(), "OOM", .{});
        } else {
            endDrag(s);
        }
    } else if (z.isMouseButtonPressed(f.input, .left) and !u.wantCaptureMouse()) {
        beginDrag(s, pointer_world);
    }

    // Fixed-timestep accumulator: box2d's TGS-Soft solver wants a constant dt, so we
    // owe the solver real seconds and pay them off in 1/60 chunks (capped so a long
    // stall can't spiral the loop).
    if (!s.paused) {
        const phys_t0: f64 = z.wgpu.nowMs();
        // Interactive scenes read input once per frame (not per sub-step) so impulse
        // actions like jump fire exactly once per press. Input = on-screen buttons OR keys.
        const sc_ctl: scenes.Scene = scenes.list[s.current_scene];
        if (sc_ctl.control) |hook| {
            const in: scenes.SceneInput = .{
                .left = s.btn.left or z.isKeyDown(f.input, .left),
                .right = s.btn.right or z.isKeyDown(f.input, .right),
                .up = s.btn.up or z.isKeyDown(f.input, .up),
                .down = s.btn.down or z.isKeyDown(f.input, .down),
                .action = s.btn.action or z.isKeyDown(f.input, .space),
            };
            hook(&s.world, &s.scene_state, in);
        }
        var steps_run: u32 = 0;
        // Spiral-of-death guard: cap how much sim time a single frame may demand. Above ~30fps the
        // frame's real dt is under this cap and the sim runs real-time; once a frame takes longer
        // than 1/30s the surplus is dropped and the world runs in slow motion instead of trying to
        // catch up (which would only fall further behind). 1/30s of sim is at most two fixed steps.
        const max_frame_dt: f32 = 1.0 / 30.0;
        s.phys_accum += clamp(f.time.delta_time, 0.0, max_frame_dt);
        var guard: u32 = 0;
        // 1/30s of sim time is at most two fixed 1/60 steps, so two is also the hard substep cap:
        // once a frame can't be served in two steps the world slows down rather than spiraling.
        while (s.phys_accum >= fixed_dt and guard < 2) : (guard += 1) {
            const sc: scenes.Scene = scenes.list[s.current_scene];
            if (sc.update_s) |hook| {
                hook(&s.world, &s.scene_state);
            } else if (sc.update) |hook| {
                hook(&s.world);
            }
            phys.step(&s.world, fixed_dt) catch assertUnreachable(@src(), "OOM", .{});
            s.phys_accum -= fixed_dt;
            steps_run += 1;

            // Determinism|SnapShot: capture a checkpoint once the scene has begun to settle,
            // then restore it on a loop so the world visibly snaps back to the captured frame.
            if (sc.auto_snapshot) {
                s.scene_state.u[0] += 1;
                const tick: u32 = s.scene_state.u[0];
                if (tick == snapshot_capture_step and s.snap == null) {
                    s.snap = phys.snapshot(&s.world, s.mem.allocator()) catch null;
                } else if (tick >= snapshot_restore_step) {
                    if (s.snap) |*sn| {
                        phys.restore(&s.world, s.mem.allocator(), sn) catch assertUnreachable(@src(), "OOM", .{});
                    }
                    s.scene_state.u[0] = snapshot_capture_step; // loop: re-diverge from the checkpoint
                }
            }
        }
        s.perf_phys_ms += (@as(f32, @floatCast(z.wgpu.nowMs() - phys_t0)) - s.perf_phys_ms) * 0.15;
        s.perf_substeps = steps_run;
    }

    // Draw the world under the UI via the DebugDraw→DrawList adapter.
    const draw_t0: f64 = z.wgpu.nowMs();
    const bg: ui.DrawListHandle = u.getBackgroundDrawList();
    var ctx: render.DrawCtx = .{ .dl = bg, .cam = s.cam };
    var dd: phys.DebugDraw = render.debugDraw(&ctx, .{
        .draw_joints = s.draw_joints,
        .draw_bounds = s.draw_aabbs,
        .draw_contacts = s.draw_contacts,
    });
    phys.draw(&s.world, &dd) catch assertUnreachable(@src(), "OOM", .{});
    s.perf_draw_ms += (@as(f32, @floatCast(z.wgpu.nowMs() - draw_t0)) - s.perf_draw_ms) * 0.15;
    s.perf_frame_ms += (f.time.delta_time * 1000.0 - s.perf_frame_ms) * 0.15;

    // Drag leash: a line from the grabbed point on the body to the pointer.
    if (s.drag) |dg| {
        const b: *const phys.Body = &s.world.bodies.data[dg.picked];
        const grab_world: Vec2 = transformPoint2(b.transform, dg.grab_local);
        const a_px: Vec2 = s.cam.worldToScreen(grab_world);
        const p_px: Vec2 = s.cam.worldToScreen(pointer_world);
        bg.addLine(a_px, p_px, leash_color, 2);
        bg.addCircleFilled(a_px, 4, leash_color);
        bg.addCircleFilled(p_px, 5, leash_color);
    }

    // Collision-lab visualiser: if the active scene has a `lab` fn, run it (the world
    // is static; the pointer is the probe). Drawn on top of the geometry.
    if (scenes.list[s.current_scene].lab) |labfn| {
        s.time += f.time.delta_time;
        var lab_ctx: render.LabCtx = .{
            .world = &s.world,
            .dl = bg,
            .cam = s.cam,
            .pointer = pointer_world,
            .pointer_down = z.isMouseButtonDown(f.input, .left),
            .time = s.time,
        };
        labfn(&lab_ctx);
    }

    // Control window.
    if (u.window("zimrphysics2d", .{
        .initial_pos = .{ 16, 16 },
        .initial_size = .{ 260, 300 },
    })) |win| {
        defer win.close();
        u.text("Scene {d}/{d}", .{ s.current_scene + 1, scenes.list.len });
        // Live perf readout — the device is the only honest profiler for the wasm build.
        const fps: f32 = if (s.perf_frame_ms > 0.01) 1000.0 / s.perf_frame_ms else 0;
        u.text("{d:.0} fps  {d:.1} ms/frame", .{ fps, s.perf_frame_ms });
        u.text("phys {d:.1} ms x{d}  draw {d:.1} ms", .{ s.perf_phys_ms, s.perf_substeps, s.perf_draw_ms });
        u.text("bodies {d}  contacts {d}  awake {d}", .{
            s.world.bodies.count(),
            s.world.contacts.count(),
            s.world.active.items.len,
        });
        // Per-phase step breakdown from the profiler (mean ms/step over the ~2s window). Shows
        // where the physics step actually spends its time — broadphase vs narrowphase vs solve etc.
        if (z.profiler.enabled) {
            var stats: [256]z.profiler.SrcStat = undefined;
            const n: usize = z.profiler.aggregate(&stats);
            for (stats[0..n]) |st| {
                if (st.count == 0) {
                    continue;
                }
                const name: []const u8 = z.profiler.srcOf(st.src).name;
                if (std.mem.startsWith(u8, name, "p2d.") == false) {
                    continue;
                }
                const mean_ms: f64 = st.total_ms / float64(st.count);
                u.text("  {s} {d:.1} ms", .{ name[4..], mean_ms });
            }
        }
        // Memory + broadphase structure sizes — to catch a leak (monotonic climb at constant
        // body count). tree-node counts only grow when the tree genuinely needs more nodes; for a
        // fixed body count they should plateau near 2N. pairs = live contact pairs in the set.
        u.text("heap {d} KB  peak {d} KB", .{ s.mem.bytes / 1024, s.mem.peak / 1024 });
        // Total wasm linear memory (everything, not just the world) — climbs toward the cap if
        // something outside the tracked world allocator (UI / render / GPU staging) is leaking.
        if (comptime builtin.target.cpu.arch == .wasm32) {
            u.text("wasm total {d} MB", .{@as(usize, @wasmMemorySize(0)) * 64 / 1024});
        }
        const dts: phys.TreeStats = s.world.broadphase.trees[2].stats();
        u.text("dyn-tree h{d} area{d:.0} nodes{d}  pairs {d}", .{
            dts.height,
            dts.area_ratio,
            dts.nodes,
            s.world.broadphase.pair_set.count,
        });
        u.separator();
        // Prev/Next walk the whole list and cross category boundaries automatically
        // (loadScene resets cat_index from the new scene's category, so the combos follow).
        const nav: ui.ButtonOpts = .{ .size = .{ 116, 30 } };
        if (u.button("< Prev", nav)) {
            const n: usize = scenes.list.len;
            loadScene(s, if (s.current_scene == 0) n - 1 else s.current_scene - 1) catch
                assertUnreachable(@src(), "OOM", .{});
        }
        u.sameLine(.{});
        if (u.button("Next >", nav)) {
            loadScene(s, (s.current_scene + 1) % scenes.list.len) catch assertUnreachable(@src(), "OOM", .{});
        }
        u.separator();
        // Category dropdown, then a dropdown of that category's scenes: any of the
        // scenes is two taps away, with no nested touch-scrolling.
        var cat_i: i32 = @intCast(s.cat_index);
        if (u.combo("category", &cat_i, &scenes.categories, .{})) {
            s.cat_index = @intCast(cat_i);
            loadScene(s, scenes.firstInCategory(s.cat_index)) catch assertUnreachable(@src(), "OOM", .{});
        }
        var names: [40][]const u8 = undefined;
        var globals: [40]usize = undefined;
        var count: usize = 0;
        var local_sel: i32 = 0;
        var si: usize = 0;
        while (si < scenes.list.len) : (si += 1) {
            if (!std.mem.eql(u8, scenes.list[si].category, scenes.categories[s.cat_index])) {
                continue;
            }
            if (si == s.current_scene) {
                local_sel = @intCast(count);
            }
            names[count] = scenes.list[si].name;
            globals[count] = si;
            count += 1;
        }
        if (u.combo("scene", &local_sel, names[0..count], .{})) {
            loadScene(s, globals[@intCast(local_sel)]) catch assertUnreachable(@src(), "OOM", .{});
        }
        u.separator();
        _ = u.checkbox("paused", &s.paused);
        if (u.button("reset scene", .{})) {
            loadScene(s, s.current_scene) catch assertUnreachable(@src(), "OOM", .{});
        }
        _ = u.slider("zoom (px/m)", &s.cam.zoom, .{ .min = 8, .max = 120 });
        u.separator();
        u.text("Debug draw", .{});
        _ = u.checkbox("joints", &s.draw_joints);
        _ = u.checkbox("AABBs", &s.draw_aabbs);
        _ = u.checkbox("contacts", &s.draw_contacts);
        u.separator();
        if (scenes.list[s.current_scene].lab != null) {
            u.text("Move the pointer to probe.", .{});
        } else {
            u.text("Drag bodies with mouse / touch.", .{});
        }
    }

    // Big on-screen control pad for interactive scenes — a separate window anchored to the
    // bottom-centre of the canvas (outside the main panel) so it's thumb-reachable on a phone.
    if (scenes.list[s.current_scene].control != null) {
        const screen_w: f32 = f.window.widthf();
        const screen_h: f32 = f.window.heightf();
        const bw: f32 = 72; // button edge (~2x the default frame height)
        const pad: f32 = 12;
        const win_w: f32 = bw * 4 + pad * 5;
        const win_h: f32 = bw + pad * 2 + 6;
        u.setNextWindowPos(.{ (screen_w - win_w) * 0.5, screen_h - win_h - 18 }, .{});
        u.setNextWindowSize(.{ win_w, win_h }, .{});
        if (u.window("controls", .{ .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .no_scrollbar = true,
            .no_saved_settings = true,
        } })) |cwin| {
            defer cwin.close();
            const bsz: Vec2 = .{ bw, bw };
            _ = u.button("<", .{ .size = bsz });
            s.btn.left = u.isItemActive();
            u.sameLine(.{});
            _ = u.button(">", .{ .size = bsz });
            s.btn.right = u.isItemActive();
            u.sameLine(.{});
            _ = u.button("^", .{ .size = bsz });
            s.btn.up = u.isItemActive();
            u.sameLine(.{});
            _ = u.button("O", .{ .size = bsz });
            s.btn.action = u.isItemActive();
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - zimrphysics2d demo",
            .width = 900,
            .height = 600,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
