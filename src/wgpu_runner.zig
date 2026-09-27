//! wgpu_runner.zig - the generic standalone runner for a DESCRIPTOR-ONLY wgpu
//! example. It is the exe root of an `addWgpuApp` build: it imports the example
//! as the `user_app` module (which exposes `pub const app = z.AppSpec(State){...}`
//! and nothing else - no `main`, no globals), owns the wasm entry and the single
//! beginDrawing/clearBackground/endDrawing, and ticks the app full-screen.
//!
//! Because the example never opens/closes the frame and draws in `f.window`-local
//! coords, the SAME example body is launcher-ready: the multi-app launcher (P3)
//! ticks it into a sub-rect via `z.pushViewport` instead of full-screen here.
//!
//! `std_options` lives HERE (the root) so the example's logs/asserts route to the
//! page; a module-level `std_options` in the example would be ignored.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const user_app = @import("user_app");

pub const std_options = z.std_options;

const spec = user_app.app;
const State = @TypeOf(spec).State;

pub var zimr_app: z.App = .{};

/// The runner owns the frame for LEGACY (unmigrated) apps: open it
/// (beginDrawing wipes to the config clear), let the app draw into the
/// full-screen frame, then present. A MIGRATED app (`manages_own_frame = true`)
/// owns its own `beginDrawing`/`endDrawing` so it can render offscreen (RTT)
/// before opening the screen - the runner just calls `update`. Once every
/// example is migrated, this branch and the flag are deleted.
fn runnerUpdate(f: *z.Frame, s: *State) void {
    // `--leak-trace` labels this frame's allocations "frame" (no-op otherwise).
    zimr_app.pushTracePhase("frame");
    defer zimr_app.popTracePhase();
    if (spec.manages_own_frame) {
        spec.update(f, s);
    } else {
        z.beginDrawing(f.gl);
        defer z.endDrawing(f.gl);
        spec.update(f, s);
    }
}

/// Adapt the spec's init to `App.run`'s in-place signature via `initInto`.
fn runnerInit(gpa: Allocator, f: *z.Frame, s: *State) anyerror!void {
    try z.initInto(spec, gpa, f, s);
}

pub fn main() !void {
    try zimr_app.run(spec.config, State, runnerInit, runnerUpdate);
}

/// Tear down the current example State by running its `deinit` - the entry point
/// the smoke/leak harness calls after ticking frames, so the GPU-handle balance
/// can be re-measured post-teardown (a non-zero delta from a clean baseline is a
/// leak). No-op if the example never initialized. A standalone never calls this
/// (it runs forever); only the harness does.
pub export fn runnerDeinit() void {
    zimr_app.pushTracePhase("deinit");
    defer zimr_app.popTracePhase();
    if (zimr_app.state) |st| {
        const sp: *State = @ptrCast(@alignCast(st));
        spec.deinit(zimr_app.gpa, sp);
        zimr_app.gpa.destroy(sp);
        zimr_app.state = null;
    }
    // The engine must not RETAIN this example's texture registrations - release
    // them so the registry doesn't grow across example lifecycles (the launcher
    // switch / long-running-app leak). The fixed engine resources (pipelines,
    // ortho ring, white texture) persist; only per-example registrations clear.
    if (zimr_app.renderer_2d) |*r| {
        r.resetRegistry();
    }
    if (zimr_app.cube3d) |*c| {
        c.resetRegistry();
    }
}

/// FULL engine teardown - the memory-accounting proof. After the leak harness has
/// run every example lifecycle (init/deinit/reinit/deinit), it calls this once to
/// tear down the ENGINE itself: the fixed baseline that deliberately PERSISTS
/// across example lifecycles. That baseline is the 3D subsystem (`Cube3D`), the 2D
/// renderer (`Renderer2D`, which also owns the white texture + ortho ring), and
/// the pipeline / bind-group caches. Each subsystem's `deinit` now destroys every
/// GPU handle it created, so once this returns the create/destroy census is all
/// zero. That clean-zero state is the proof that every handle zimr allocates is
/// accounted for - not that freeing is mandatory, but that nothing is untracked.
/// A standalone never calls this (it runs forever); only the harness does.
pub export fn runnerShutdown() void {
    // Defensive: an example State should already be gone (the harness runs
    // runnerDeinit before this), but never tear the engine down underneath one.
    if (zimr_app.state != null) {
        runnerDeinit();
    }
    if (zimr_app.cube3d) |*c| {
        c.deinit();
        zimr_app.cube3d = null;
    }
    if (zimr_app.renderer_2d) |*r| {
        r.deinit();
        zimr_app.renderer_2d = null;
    }
    // Caches last: their pipelines/bind groups may be referenced by the
    // subsystems above, which have now released their own references.
    zimr_app.bind_group_cache.deinit();
    zimr_app.pipeline_cache.deinit();

    // The engine depth target (created lazily by gpu_frame.ensureDepth, sized to
    // the surface, one live texture+view at a time). ensureDepth destroys the old
    // texture on resize but not the old view, so free both here explicitly.
    if (zimr_app.gpu_frame.depth_view != .invalid) {
        z.wgpu.destroyTextureView(zimr_app.gpu_frame.depth_view);
        zimr_app.gpu_frame.depth_view = .invalid;
    }
    if (zimr_app.gpu_frame.depth_texture != .invalid) {
        z.wgpu.destroyTexture(zimr_app.gpu_frame.depth_texture);
        zimr_app.gpu_frame.depth_texture = .invalid;
    }

    // The engine fullscreen quad VBO (created lazily by fullscreenVbo() the first
    // time an app blits a render texture / runs a fullscreen pass). Engine-owned,
    // one for the program's life - free it here so RTT examples leave the device
    // clean under the leak gate.
    if (zimr_app.fullscreen_vbo != .invalid) {
        z.wgpu.destroyBuffer(zimr_app.fullscreen_vbo);
        zimr_app.fullscreen_vbo = .invalid;
    }
}

/// Re-run the example's `init` on the SAME instance after a `runnerDeinit` - the
/// leak harness's TWICE-LIFECYCLE probe. The engine (Renderer2D) persists across
/// this (its lazy init is guarded), so lifecycle-2's handle census grows over
/// lifecycle-1's ONLY by what the example failed to free - isolating a per-run
/// leak from the fixed engine baseline. No-op unless currently torn down.
pub export fn runnerReinit() void {
    if (zimr_app.state != null) {
        return;
    }
    zimr_app.pushTracePhase("init");
    defer zimr_app.popTracePhase();
    const state_ptr: *State = zimr_app.gpa.create(State) catch return;
    var f: z.Frame = zimr_app.makeFrame();
    z.initInto(spec, zimr_app.gpa, &f, state_ptr) catch {
        zimr_app.gpa.destroy(state_ptr);
        return;
    };
    zimr_app.state = state_ptr;
}

/// The example's declared memory mode (0 = arena, 1 = managed) - the leak
/// harness only ENFORCES a flat twice-lifecycle census for `.managed` examples.
pub export fn runnerMemoryMode() i32 {
    return @backingInt(spec.memory);
}

/// Net live bytes currently handed out through the example's allocator - the
/// precise, fragmentation-free CPU twin of the GPU handle census. Growth across
/// the twice-lifecycle probe is exactly a per-lifecycle CPU leak.
pub export fn runnerLiveBytes() i32 {
    return clampToI32(zimr_app.counting.live_bytes);
}

/// `--leak-trace`: put the allocation tracer under both counters. The smoke harness calls
/// this right after `_initialize`, so the first lifecycle's blocks are known. A standalone
/// never does.
pub export fn runnerTraceBegin() void {
    zimr_app.beginLeakTrace();
}

/// `--leak-trace`: everything allocated from here is what the report lists. The harness
/// calls it just before `runnerReinit` (the second lifecycle).
pub export fn runnerTraceMark() void {
    zimr_app.markLeakTrace();
}

/// `--leak-trace`: log every allocation made since `runnerTraceMark` that is still live
/// (the harness prints them). No-op if tracing never began.
pub export fn runnerTraceReport() void {
    zimr_app.reportLeakTrace();
}

/// Net live bytes held by the ENGINE's own allocator (`App.engine_gpa`): the pipeline
/// and bind-group caches, `Renderer2D`, `Cube3D`. Across an example's lifecycle this
/// must not grow either - growth here means the engine kept memory the example caused.
pub export fn runnerEngineLiveBytes() i32 {
    return clampToI32(zimr_app.engine_counting.live_bytes);
}

/// How many frees (or shrinks) took more bytes than the counter they went through had
/// handed out - memory freed through the other side's allocator. Both counters summed;
/// the gate fails on any.
pub export fn runnerWrongSideFrees() i32 {
    // Saturating: a counter of mistakes must not itself trap on overflow in a safety build.
    const total: u32 = zimr_app.counting.wrong_side_frees +| zimr_app.engine_counting.wrong_side_frees;
    const i32_max: u32 = (1 << 31) - 1;
    return @intCast(@min(total, i32_max));
}

fn clampToI32(bytes: usize) i32 {
    const i32_max: usize = (1 << 31) - 1;
    if (bytes > i32_max) {
        return @intCast(i32_max);
    }
    return @intCast(bytes);
}
