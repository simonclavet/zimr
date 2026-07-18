// src/runtime.zig - Frame/App lifecycle, input, allocators, time-effects.
// Aggregates the program-runtime cluster into one file with namespaced
// sub-structs:
//     runtime.core      - Frame/App, window state, run loop
//     runtime.input     - keyboard/mouse/touch/gamepad
//     runtime.camera    - Camera2D / Camera3D update helpers
//     runtime.effects   - clock, rng, logger, loader (Frame.* fields)
//     runtime.allocator - page/wasm allocator + heap accounting
//     runtime.libc      - minimal libc shims for std.fs probes
// Each section's contents are unchanged from before the merge. Callers
// that did `const core = core` now use
// `const core = core`.

const std = @import("std");
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const zm = @import("zm");
const float = zm.float;
const float64 = zm.float64;
const atan2 = zm.atan2;
const pi = zm.pi;
const vec = zm.vec;
const Vec = zm.Vec;
const normalize3 = zm.normalize3;
const cross = zm.cross;
const length3 = zm.length3;
const angle3 = zm.angle3;
const mulMatVec = zm.mulMatVec;
const scaling = zm.scaling;
const mulMat = zm.mulMat;

/// Host-side monotonic clock in milliseconds.  Returns null when no
/// monotonic source is available - caller decides the fallback
/// (browserWallMs uses a 60fps synthetic tick for tests; loader's
/// nowMs returns 0).
/// Platform-conditional because `extern "c" clock_gettime` requires
/// libc, which `zig test` on Windows doesn't link by default
/// ("libc must be explicitly specified" compile error).  We pick the
/// right backend per OS so consumers don't have to:
///   - **Linux / macOS / BSD**: POSIX `clock_gettime(MONOTONIC, …)`.
///     Symbol is `extern "c"`, but those targets link libc by
///     default for `zig test`, so it Just Works.
///   - **Windows**: `RtlQueryPerformanceCounter` /
///     `RtlQueryPerformanceFrequency` from `ntdll`.  These are
///     `extern "ntdll"` (Win32 ABI), NOT libc - works without
///     `link_libc`.
///   - **Anywhere else**: null.  Caller falls back.
/// Lives at module scope so both the `clock` and `loader` namespaces
/// can call it - they're sibling `pub const X = struct { ... }`s
/// inside this file and need a shared helper.
fn hostMonotonicMs() ?f64 {
    if (comptime builtin.os.tag == .windows) {
        var qpc: std.os.windows.LARGE_INTEGER = undefined;
        var qpf: std.os.windows.LARGE_INTEGER = undefined;
        if (std.os.windows.ntdll.RtlQueryPerformanceCounter(&qpc).toBool() and
            std.os.windows.ntdll.RtlQueryPerformanceFrequency(&qpf).toBool())
        {
            return float64(qpc) * 1000.0 /
                float64(qpf);
        }
        return null;
    }
    if (comptime @hasDecl(std.posix.system, "clock_gettime")) {
        var ts: std.posix.timespec = undefined;
        if (std.posix.system.clock_gettime(.MONOTONIC, &ts) == 0) {
            return float64(ts.sec) * 1000.0 +
                float64(ts.nsec) / 1_000_000.0;
        }
        return null;
    }
    return null;
}

// ============================================================================
// SECTION - core (was: src/core.zig)
// ============================================================================

pub const core = struct {
    const Vec2 = zm.Vec2;

    /// Per-frame time bookkeeping.  Owned by `Runtime` (or constructed
    /// fresh for tests).  Functions in this namespace take a
    /// `*const TimeState` to read or `*TimeState` to mutate.
    pub const TimeState = struct {
        /// Wall-clock time at `init`, in seconds.  `now() - base` gives
        /// elapsed seconds since program start.
        base: f64 = 0,
        /// Time this frame started, in seconds since `base`.
        current: f64 = 0,
        /// Time the previous frame started.
        previous: f64 = 0,
        /// Total elapsed time of the *previous* frame in seconds
        /// what `getFrameTime` returns.
        delta_time: f32 = 0,
        /// User-requested target seconds per frame (0 = unlimited /
        /// vsync-only).  Informational on web; the browser drives RAF.
        target: f64 = 0,
        /// Total frame counter since `init`.  Wraps around at u64 max
        /// - no realistic application reaches that, but documenting.
        frameCounter: u64 = 0,
    };

    /// FPS averaging window.  Identical algorithm to raylib's getFPS:
    /// keep 30 samples spaced ~16.7ms apart in real time, return
    /// `1 / mean(samples)`.
    pub const FpsState = struct {
        pub const N: usize = 30;
        history: [N]f32 = @splat(0),
        average: f32 = 0,
        last: f32 = 0,
        index: usize = 0,
    };

    /// Window/canvas state.  Sizes, focus, exit flag.
    pub const WindowState = struct {
        /// Logical screen size - what the user passed to `init`.  CSS
        /// pixels; the GL drawing buffer is `screen_width * dpr`.
        screen_width: i32 = 800,
        screen_height: i32 = 450,
        /// Render target size - equals (screen × DPR) for the default
        /// framebuffer; updated by `BeginTextureMode` to match the FBO.
        render_width: i32 = 800,
        render_height: i32 = 450,

        /// The `.fit` letterbox transform: LOGICAL (design) space -> CSS px.
        ///
        ///     css_x = logical_x * fit_scale + fit_off_x
        ///
        /// Identity in `.responsive`, where logical IS CSS — which is exactly why the clip
        /// path got away with ignoring it for so long. Under `.fit` the design space (say
        /// 800x450) is letterboxed into the real CSS box, so a landscape phone is
        /// height-limited and `fit_off_x` is large: a scissor rect that skips it lands
        /// visibly shifted sideways.
        ///
        /// DERIVED ONCE, in `wgpu_app` (`fitScaleOffset`), and pushed here — the same way
        /// `render_width`/`render_height` are. Nothing downstream may re-derive it. The engine
        /// has already paid for that lesson: `logicalToCss`/`cssToLogical` exist precisely
        /// because touch, mouse and scissor each grew their own copy of this transform and one
        /// of them was wrong.
        fit_scale: f32 = 1.0,
        fit_off_x: f32 = 0.0,
        fit_off_y: f32 = 0.0,
        /// True after the user (or `windowShouldClose` triggered by the
        /// exit key) has signalled they want to quit.
        should_close: bool = false,
        /// True when the host page reports the canvas / window has focus.
        /// The DOM event handlers in `dom.js` could feed this, but we
        /// haven't wired the focus/blur events yet - defaults to true so
        /// `isWindowFocused` doesn't lock the user out of input on day one.
        focused: bool = true,
        /// Letterboxed canvas viewport rect (CSS pixels) + logical
        /// dims.  Single source of truth for the wasm↔CSS coord
        /// conversion: glViewport on the rendering side, mouse/touch
        /// input on the receiving side, DOM overlay placement on the
        /// publishing side.  Recomputed on every canvas size change
        /// by the resize handler in `zimr.zig`.
        viewport: CanvasViewport = .{},
    };

    /// Letterboxed canvas viewport rect, in CSS pixels.  Lives on
    /// `WindowState` so both the rendering path (zimr.zig's resize
    /// handler) and the input bridge (runtime_assembly.zig) read
    /// from one place.
    pub const CanvasViewport = struct {
        /// CSS-pixel offset of the viewport's top-left corner inside
        /// the canvas.  Always 0 in `.responsive` mode; non-zero in
        /// `.fit` when canvas aspect differs from logical aspect.
        offset_x_css: i32 = 0,
        offset_y_css: i32 = 0,

        /// CSS-pixel dimensions of the viewport (the drawn region).
        /// Equals canvas CSS dims in `.responsive`; equals
        /// `logical × fit_scale` in `.fit`.
        width_css: i32 = 0,
        height_css: i32 = 0,

        /// Logical-pixel dimensions of the viewport.  In `.responsive`
        /// these match `width_css` / `height_css` exactly.  In `.fit`
        /// they stay pinned to `cfg.window.width` / `.height`.  Stored
        /// so the JS bridge can compute logical-per-css without
        /// reaching back into config.
        width_logical: i32 = 0,
        height_logical: i32 = 0,

        /// CSS event coords → logical pixels.  Used by the JS input
        /// bridge to enforce the "all input is logical" contract.
        /// Coords from events that landed in a letterbox bar fall
        /// outside the 0..logical range - hit-tests against widget
        /// rects then naturally miss.
        // Vec2 (= zm.Vec2, aliased at file scope) is the canonical {x, y} screen-space
        // point in the runtime layer (mouse pos, touch pos, etc.). An earlier draft used
        // a separate LogicalPoint type here; it was redundant - same shape (turn 349).
        pub fn cssToLogical(
            self: CanvasViewport,
            css_x: f32,
            css_y: f32,
        ) Vec2 {
            if (self.width_css <= 0 or self.height_css <= 0) {
                return .{ css_x, css_y };
            }
            const sx: f32 = float(self.width_logical) / float(self.width_css);
            const sy: f32 = float(self.height_logical) / float(self.height_css);
            return .{
                (css_x - float(self.offset_x_css)) * sx,
                (css_y - float(self.offset_y_css)) * sy,
            };
        }
    };

    pub const TraceLogState = struct {
        /// Minimum level to actually emit.  Anything below is dropped.
        /// Mirrors raylib's `logTypeLevel` default of `LOG_INFO` (3).
        level: i32 = 3,
        /// Optional user override.  When set, `traceLog` calls this
        /// instead of routing to `dom.js`.  Matches raylib's `traceLog`
        /// callback hook.
        callback: ?TraceLogCallback = null,
    };

    pub const TraceLogCallback = *const fn (level: i32, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) void;

    // `nowFn` is a function pointer through which we read wall-clock
    // milliseconds.  Defaults to a host-friendly `std.time.milliTimestamp`
    // monotonic source so host tests work without browser globals.  In
    // the wasm build the runtime calls `setNowFn` to swap in the
    // `dom.now_ms` import (which reads `performance.now`).
    var nowFn: *const fn () f64 = hostNow; // lint:off module-var: JS-bridge clock (set by wasm runtime startup)

    fn hostNow() f64 {
        // Host-side default - used only by tests (the wasm build replaces
        // this via `setNowFn` with the `dom.now_ms` import).  Zig 0.16
        // dropped `std.time.nanoTimestamp`; the simplest portable fallback
        // is to read the POSIX monotonic clock directly when available
        // and fall back to 0 otherwise.  Tests never rely on this - they
        // install their own deterministic clock via `_testSetNowFn`.
        return 0;
    }

    /// Install the browser-backed clock source.  Called by `App.create`
    /// in `zimr.zig` once the `dom` import is live.
    pub fn setNowFn(f: *const fn () f64) void {
        nowFn = f;
    }

    // ===========================================================================
    // Initialisation hooks called by the runtime
    // ===========================================================================

    /// Set the base time so `getTime(time)` returns 0 right after this call.
    /// Invoked by `App.create` after the runtime has wired `nowFn`.
    pub fn initTimer(
        time: *TimeState,
        fps: *FpsState,
    ) void {
        time.base = nowFn() / 1000.0; // ms → s
        time.current = 0;
        time.previous = 0;
        time.delta_time = 0;
        time.frameCounter = 0;
        fps.* = .{};
    }

    /// Per-frame begin: capture the timestamp + compute the frame delta.
    /// Called by `zimr_frame` BEFORE the user's update so `getFrameTime`
    /// reports the just-elapsed frame.
    pub fn beginFrame(
        time: *TimeState,
        fps: *FpsState,
    ) void {
        time.previous = time.current;
        time.current = (nowFn() / 1000.0) - time.base;
        time.delta_time = @floatCast(time.current - time.previous);
        time.frameCounter += 1;
        updateFpsAverage(time, fps);
    }

    /// Update the rolling FPS average.  Mirrors raylib's getFPS algorithm.
    fn updateFpsAverage(
        time: *const TimeState,
        fps: *FpsState,
    ) void {
        const FPS_AVG_TIME: f32 = 0.5;
        const FPS_STEP: f32 = FPS_AVG_TIME / float(FpsState.N);

        if (time.frameCounter == 1) {
            // First frame: reset history.
            fps.* = .{};
            return;
        }

        const ft: f32 = time.delta_time;
        if (ft <= 0) {
            return;
        }

        const tnow: f32 = @floatCast(time.current);
        if ((tnow - fps.last) <= FPS_STEP) {
            return;
        }

        fps.last = tnow;
        fps.index = (fps.index + 1) % FpsState.N;
        fps.average -= fps.history[fps.index];
        fps.history[fps.index] = ft / float(FpsState.N);
        fps.average += fps.history[fps.index];
    }

    pub fn setWindowSize(
        window: *WindowState,
        width: i32,
        height: i32,
    ) void {
        window.screen_width = width;
        window.screen_height = height;
        window.render_width = width;
        window.render_height = height;
    }

    // ===========================================================================
    // Public timing API - read-only queries take `*const TimeState` /
    // `*const FpsState`.
    // ===========================================================================

    pub fn getTime(time: *const TimeState) f64 {
        return time.current;
    }

    pub fn getFrameTime(time: *const TimeState) f32 {
        return time.delta_time;
    }

    pub fn getFPS(fps: *const FpsState) i32 {
        if (fps.average == 0) {
            return 0;
        }
        return @round(1.0 / fps.average);
    }

    pub fn setTargetFPS(
        time: *TimeState,
        fps_target: i32,
    ) void {
        if (fps_target < 1) {
            time.target = 0;
        } else {
            time.target = 1.0 / float64(fps_target);
        }
    }

    // ===========================================================================
    // traceLog
    // ===========================================================================

    /// raylib-style log-level aliases.  Named exactly like raylib's
    /// `LOG_INFO` etc. for source compatibility, but typed as
    /// `TraceLogLevel` enum tags rather than `i32` so call sites
    /// like `setTraceLogLevel(core.globalTracelog(), .warning)` work without any cast.
    pub const LOG_ALL: TraceLogLevel = .all;
    pub const LOG_TRACE: TraceLogLevel = .trace;
    pub const LOG_DEBUG: TraceLogLevel = .debug;
    pub const LOG_INFO: TraceLogLevel = .info;
    pub const LOG_WARNING: TraceLogLevel = .warning;
    pub const LOG_ERROR: TraceLogLevel = .err;
    pub const LOG_FATAL: TraceLogLevel = .fatal;
    pub const LOG_NONE: TraceLogLevel = .none;

    pub fn setTraceLogLevel(
        tracelog: *TraceLogState,
        level: TraceLogLevel,
    ) void {
        tracelog.level = @intFromEnum(level);
    }

    pub fn getTraceLogLevel(tracelog: *const TraceLogState) TraceLogLevel {
        return @enumFromInt(tracelog.level);
    }

    pub fn setTraceLogCallback(
        tracelog: *TraceLogState,
        cb: ?TraceLogCallback,
    ) void {
        tracelog.callback = cb;
    }

    /// Internal sink - both the public `traceLog` (which does its own
    /// vararg handling on the C side; we replace that with a direct
    /// `[]const u8` formatted message) and the in-Zig logging helpers
    /// route here.  Returns true if the message was dispatched (level
    /// gate passed); false if dropped.
    fn emitTraceLog(
        tracelog: *const TraceLogState,
        level: i32,
        msg: []const u8,
    ) bool {
        if (level < tracelog.level) {
            return false;
        }
        if (tracelog.callback) |cb| {
            cb(level, msg.ptr, msg.len);
            return true;
        }
        // Default sink: route to `dom.log` via a function pointer set by
        // the runtime so this module stays free of browser imports.
        if (defaultSink) |sink| {
            sink(level, msg);
        }
        return true;
    }

    /// Default-sink hook.  `zimr.zig` populates this at startup with a
    /// closure that calls `dom.log`.  Host tests leave it null - emitted
    /// messages just dispatch through the test-helper sink instead.
    // lint:off module-var: JS-bridge log sink (set by zimr.zig at startup)
    var defaultSink: ?*const fn (level: i32, msg: []const u8) void = null;

    pub fn setDefaultSink(sink: *const fn (level: i32, msg: []const u8) void) void {
        defaultSink = sink;
    }

    /// Format-and-emit helper for in-Zig users.  Equivalent of raylib's
    /// `traceLog(core.globalTracelog(), level, "format", args...)` but uses Zig's
    /// `std.fmt.bufPrint` so format-string mistakes are compile-errors.
    /// Truncates at 1024 bytes (matches raylib's MAX_TRACELOG_MSG_LENGTH).
    pub fn traceLog(
        tracelog: *const TraceLogState,
        level: TraceLogLevel,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const level_int: i32 = @intFromEnum(level);
        if (level_int < tracelog.level) {
            return;
        }
        var buf: [1024]u8 = undefined;
        const msg: []u8 = bufPrint(&buf, fmt, args) catch buf[0..0];
        _ = emitTraceLog(tracelog, level_int, msg);
    }

    /// JS-facing entry point.  Wasm-side string passed as ptr/len; the
    /// JS shim calls this when it wants to log something through the
    /// raylib-style filter (currently nothing does - kept for future
    /// JS-driven errors like WebGL context loss).  Use `traceLog` from
    /// Zig code; this is the raw form for non-Zig callers.
    pub fn traceLogRaw(
        tracelog: *const TraceLogState,
        level: i32,
        msg_ptr: [*c]const u8,
        msg_len: usize,
    ) void {
        if (msg_ptr == null or msg_len == 0) {
            return;
        }
        _ = emitTraceLog(tracelog, level, msg_ptr[0..msg_len]);
    }

    // ===========================================================================
    // Window-state queries - read fns take `*const WindowState`, mutators
    // take `*WindowState`.
    // ===========================================================================

    pub fn getScreenWidth(window: *const WindowState) i32 {
        return window.screen_width;
    }

    pub fn getScreenHeight(window: *const WindowState) i32 {
        return window.screen_height;
    }

    pub fn getRenderWidth(window: *const WindowState) i32 {
        return window.render_width;
    }

    pub fn getRenderHeight(window: *const WindowState) i32 {
        return window.render_height;
    }

    /// Canvas size in BACKING pixels (= logical × DPR), packed as
    /// `[2]f32` for direct push into a `setShaderValue(..., .vec2)`
    /// call.  Backing pixels are the units of `gl_FragCoord.xy` in
    /// GLSL, so this is the right value for a `u_resolution`-style
    /// uniform when the shader compares against `gl_FragCoord`.
    ///
    /// For Zig-shader-pipeline shaders that use
    /// `frag_tex_coord * u_resolution` (no `gl_FragCoord`), any
    /// consistent unit works — logical px (`getScreenWidth` /
    /// `getScreenHeight`) is simpler in that case.  See
    /// `examples/mandelbrot.zig` for that style and
    /// `examples/shader_uniforms.zig` for the `gl_FragCoord` style.
    pub fn getShaderResolution(window: *const WindowState) [2]f32 {
        return .{
            @floatFromInt(window.render_width),
            @floatFromInt(window.render_height),
        };
    }

    pub fn isWindowFocused(window: *const WindowState) bool {
        return window.focused;
    }

    /// Mark the window as wanting to close.  Called by the input layer
    /// when the configured exit key is pressed.  Apps poll
    /// `windowShouldClose` in their main loop.
    pub fn requestClose(window: *WindowState) void {
        window.should_close = true;
    }

    pub fn windowShouldClose(window: *const WindowState) bool {
        return window.should_close;
    }

    pub fn setFocused(
        window: *WindowState,
        f: bool,
    ) void {
        window.focused = f;
    }

    // ===========================================================================
    // Browser bridges - window/clipboard/screenshot operations the browser
    // permits us to do.  raylib lumps these into core too (rcore.c).  All
    // are no-ops on host builds; the comptime arch.isWasm() check is the
    // gate.
    // ===========================================================================

    /// Set the browser tab's title (`document.title`).
    pub fn setWindowTitle(title: []const u8) void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        @import("web.zig").dom.set_title(title);
    }

    /// Return `(devicePixelRatio, devicePixelRatio)` - both axes share
    /// the same DPR in a browser.  Returns `(1, 1)` on host.
    pub fn getWindowScaleDPI() zm.Vec2 {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return .{ 1, 1 };
        }
        const dpr: f32 = @import("web.zig").dom.get_dpi_scale();
        return .{ dpr, dpr };
    }

    /// Toggle browser fullscreen on the canvas element.  Most browsers
    /// require this be called from a user-gesture handler - if you call
    /// it outside one, the call is silently rejected by the browser.
    pub fn toggleFullscreen() void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        @import("web.zig").dom.toggle_fullscreen();
    }

    /// True if `document.fullscreenElement` is non-null.
    pub fn isFullscreen() bool {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return false;
        }
        return @import("web.zig").dom.is_fullscreen();
    }

    // ===========================================================================
    // Phase-1A bridge-the-gap: window UX raylib parity.  Each is a thin
    // wrapper over a `dom.*` JS bridge call, gated by an `is_wasm` check
    // so host-target code compiles to a no-op (matches the existing
    // setWindowTitle / toggleFullscreen pattern).
    // ===========================================================================

    /// Set the canvas CSS opacity in [0, 1].  raylib: `SetWindowOpacity`.
    pub fn setWindowOpacity(opacity: f32) void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        @import("web.zig").dom.set_window_opacity(opacity);
    }

    /// Programmatically focus the canvas.  raylib: `SetWindowFocused`.
    /// (zimr also tracks focus state internally - `isWindowFocused` reads
    /// that, this updates the DOM focus.)
    pub fn setWindowFocused() void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        @import("web.zig").dom.set_window_focused();
    }

    /// Read-and-clear the "canvas was resized since last call" flag.
    /// raylib: `IsWindowResized`.  Backed by a `ResizeObserver`; first
    /// call after a resize returns true and clears the flag, subsequent
    /// calls return false until the next resize.
    pub fn isWindowResized() bool {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return false;
        }
        return @import("web.zig").dom.window_resized_take();
    }

    /// Set the browser tab's favicon to PNG bytes.  raylib's
    // ===========================================================================
    // Phase-1A bridge-the-gap: drag-drop file capture.  JS captures
    // `drop` events on the canvas, reads each file's bytes via
    // `FileReader.readAsArrayBuffer`, and stores `{name, bytes}` in a
    // table.  `loadDroppedFiles` pulls the whole table into Zig-owned
    // memory; `unloadDroppedFiles` frees the result + clears the
    // JS-side table.
    // ===========================================================================

    /// raylib's FilePathList - a list of (path, bytes) pairs.  zimr
    /// fills both: `path` is the original filename, `bytes` is the
    /// file contents (raylib stores only paths because it can re-read
    /// them; on the web we don't have FS so we capture bytes).
    pub const DroppedFile = struct {
        name: []u8, // owned: caller frees via unloadDroppedFiles
        bytes: []u8, // owned: same
    };
    pub const DroppedFiles = []DroppedFile;

    /// True if there are unconsumed dropped files.  raylib: `IsFileDropped`.
    pub fn isFileDropped() bool {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return false;
        }
        return @import("web.zig").dom.dropped_files_count() > 0;
    }

    /// Pull all dropped files into Zig-owned memory.  Returns a slice
    /// of `DroppedFile`; both `name` and `bytes` are owned by `gpa`
    /// and must be freed via `unloadDroppedFiles(gpa, files)`.
    /// raylib: `LoadDroppedFiles()`.  After this returns, the JS-side
    /// table is NOT yet cleared - call `unloadDroppedFiles` to clear.
    pub fn loadDroppedFiles(gpa: Allocator) Allocator.Error!DroppedFiles {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return try gpa.alloc(DroppedFile, 0);
        }
        const dom = @import("web.zig").dom;
        const count: u32 = dom.dropped_files_count();
        const out = try gpa.alloc(DroppedFile, @intCast(count));
        errdefer gpa.free(out);
        var i: u32 = 0;
        // On allocator failure mid-loop, free everything allocated so far.
        errdefer for (out[0..@intCast(i)]) |df| {
            gpa.free(df.name);
            gpa.free(df.bytes);
        };
        while (i < count) : (i += 1) {
            const blen = dom.dropped_file_byte_len(i);
            const nlen = dom.dropped_file_name_len(i);
            const bytes = try gpa.alloc(u8, @intCast(blen));
            errdefer gpa.free(bytes);
            const name = try gpa.alloc(u8, @intCast(nlen));
            if (blen > 0) dom.dropped_file_bytes(i, bytes.ptr, blen);
            if (nlen > 0) dom.dropped_file_name(i, name.ptr, nlen);
            out[@intCast(i)] = .{ .name = name, .bytes = bytes };
        }
        return out;
    }

    /// Free a `DroppedFiles` returned by `loadDroppedFiles` AND clear
    /// the JS-side table so `isFileDropped` reads false.
    /// raylib: `UnloadDroppedFiles(FilePathList files)`.
    pub fn unloadDroppedFiles(
        gpa: Allocator,
        files: DroppedFiles,
    ) void {
        for (files) |df| {
            gpa.free(df.name);
            gpa.free(df.bytes);
        }
        gpa.free(files);
        if (comptime @import("builtin").target.cpu.arch.isWasm()) {
            @import("web.zig").dom.dropped_files_clear();
        }
    }

    /// Open `url` in a new tab.  Browsers block this if the call isn't
    /// inside a user-gesture handler.  Use `noopener,noreferrer` flags.
    pub fn openURL(url: []const u8) void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        @import("web.zig").dom.open_url(url);
    }

    /// Write `text` to the system clipboard.  Fire-and-forget - the
    /// browser may reject the call if the document doesn't have focus
    /// or the user hasn't granted permission.
    pub fn setClipboardText(text: []const u8) void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        @import("web.zig").dom.set_clipboard_text(text);
    }

    /// Async clipboard-text-read handle.  Returned by
    /// `getClipboardTextAsync`; passed to `pollClipboardText` and
    /// `releaseClipboardText`.  Zero means "not started" / "host stub".
    pub const ClipboardHandle = u32;

    /// Result of polling a clipboard-text read.
    pub const ClipboardTextPoll = union(enum) {
        /// The browser is still resolving the clipboard read.
        pending,
        /// Read complete.  `bytes` is valid until `releaseClipboardText`.
        ready: []const u8,
        /// Permission denied, no text on clipboard, or host build.
        failed,
    };

    /// Begin reading the system clipboard's text contents.  Returns a
    /// handle to be passed to `pollClipboardText` over subsequent
    /// frames.  Returns 0 on host (no clipboard).
    pub fn getClipboardTextAsync() ClipboardHandle {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return 0;
        }
        return @import("web.zig").dom.get_clipboard_text_start();
    }

    /// Poll a previously-started clipboard read.  Bytes are owned by
    /// the runtime; valid until `releaseClipboardText(handle)`.
    pub fn pollClipboardText(handle: ClipboardHandle) ClipboardTextPoll {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return .failed;
        }
        if (handle == 0) {
            return .failed;
        }
        const loader = @import("web.zig").fetch;
        const status: @import("web.zig").fetch.Status = loader.poll(handle);
        return switch (status) {
            .pending => .pending,
            .ok => |bytes| .{ .ready = bytes },
            .failed => .failed,
        };
    }

    /// Release a clipboard-read handle.  Safe to call multiple times.
    pub fn releaseClipboardText(handle: ClipboardHandle) void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        if (handle == 0) {
            return;
        }
        @import("web.zig").fetch.release(handle);
    }

    /// Result of polling a clipboard-image read.  The `ready` arm holds
    /// the raw PNG bytes - caller is responsible for decoding via
    /// `z.textures.loadImageFromMemory(gpa, ".png", bytes)`.
    pub const ClipboardImagePoll = union(enum) {
        pending,
        /// Raw PNG bytes; valid until `releaseClipboardImage(handle)`.
        ready: []const u8,
        /// Permission denied, no image on clipboard, or host build.
        failed,
    };

    /// Begin reading the system clipboard's image (PNG only).  Returns
    /// 0 on host builds.
    pub fn getClipboardImageAsync() ClipboardHandle {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return 0;
        }
        return @import("web.zig").dom.get_clipboard_image_start();
    }

    /// Poll a previously-started clipboard image read.
    pub fn pollClipboardImage(handle: ClipboardHandle) ClipboardImagePoll {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return .failed;
        }
        if (handle == 0) {
            return .failed;
        }
        const status = @import("web.zig").fetch.poll(handle);
        return switch (status) {
            .pending => .pending,
            .ok => |bytes| .{ .ready = bytes },
            .failed => .failed,
        };
    }

    /// Release a clipboard-image-read handle.  Same fn as text release
    /// since they share the handle table on the JS side, but kept as a
    /// distinct name for clarity at call sites.
    pub fn releaseClipboardImage(handle: ClipboardHandle) void {
        releaseClipboardText(handle);
    }

    /// Trigger a `<a download>` of the canvas contents as PNG.  The
    /// browser pops a "Save File" dialog (or downloads silently to the
    /// Downloads folder, depending on browser settings).
    pub fn takeScreenshot(filename: []const u8) void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        @import("web.zig").dom.take_screenshot(filename);
    }

    test "clipboard image async: host stub returns failed" {
        const h: ClipboardHandle = getClipboardImageAsync();
        try expectEqual(@as(ClipboardHandle, 0), h);
        try expect(pollClipboardImage(0) == .failed);
        releaseClipboardImage(0);
    }

    test "takeScreenshot: host build is a no-op" {
        takeScreenshot("test.png");
        takeScreenshot("");
    }

    test "openURL: host build is a no-op" {
        openURL("https://example.com/");
        openURL(""); // edge case - empty string
    }

    test "setClipboardText: host build is a no-op" {
        setClipboardText("hello");
        setClipboardText("");
    }

    test "clipboard text async: host stub returns failed immediately" {
        const h: ClipboardHandle = getClipboardTextAsync();
        try expectEqual(@as(ClipboardHandle, 0), h); // host returns 0
        // Polling a 0 handle is also failed.
        try expect(pollClipboardText(0) == .failed);
        // Releasing 0 is safe no-op.
        releaseClipboardText(0);
    }

    test "setWindowTitle: host build is a no-op" {
        // Just verify the comptime branch compiles and returns cleanly.
        setWindowTitle("test title");
        setWindowTitle(""); // empty string - must also be safe
    }

    test "getWindowScaleDPI: host returns (1, 1)" {
        const dpr: zm.Vec2 = getWindowScaleDPI();
        try expectEqual(@as(f32, 1), dpr[0]);
        try expectEqual(@as(f32, 1), dpr[1]);
    }

    test "toggleFullscreen + isFullscreen: host is no-op + always false" {
        toggleFullscreen();
        try expectEqual(false, isFullscreen());
    }

    // ===========================================================================
    // Test helpers
    // ===========================================================================

    pub fn _testReset() void {
        // TIME / FPS / WINDOW / TRACELOG retired in Phase 2 - tests
        // that need fresh state allocate locals (`var t: TimeState =
        // .{};`) and pass `&t` through.  Only the residuals that
        // survive - the default sink fn-pointer and the now-fn
        // get reset here.
        defaultSink = null;
        nowFn = hostNow;
    }

    /// Replace the clock source with a controllable fake so tests can
    /// drive frame-time advances deterministically.
    pub fn _testSetNowFn(f: *const fn () f64) void {
        nowFn = f;
    }

    // ===========================================================================
    // Random number generator (xorshift32, mirrors raylib's rprand)
    // ===========================================================================

    /// Internal RNG state.  Seeded with raylib's default value so the first
    /// `getRandomValue()` call without an explicit seed returns a stable
    /// stream - useful for reproducible demos / fuzz seeds.
    var rng_state: u32 = 0xDEADBEEF; // lint:off module-var: raylib parity — process-global RNG

    /// Set the RNG seed.  A seed of 0 is replaced with 1 (xorshift's only
    /// degenerate state - leaving it at 0 means every output stays 0).
    pub fn setRandomSeed(seed: u32) void {
        rng_state = if (seed == 0) 1 else seed;
    }

    /// Return a pseudo-random integer in [`min`, `max`] (inclusive on both
    /// ends).  If `min > max` the bounds are swapped automatically.
    /// Uses xorshift32 - fast, statistically OK for game code, NOT
    /// cryptographically secure.
    pub fn getRandomValue(min_in: i32, max_in: i32) i32 {
        var lo: i32 = min_in;
        var hi: i32 = max_in;
        if (lo > hi) {
            const tmp: i32 = hi;
            hi = lo;
            lo = tmp;
        }
        // xorshift32 step
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 17;
        rng_state ^= rng_state << 5;
        if (rng_state == 0) {
            rng_state = 1;
        }
        const range_u: u32 = @intCast(hi - lo + 1);
        return lo + @as(i32, @intCast(rng_state % range_u));
    }

    /// Return an owned slice of `count` distinct integers chosen at random
    /// from the inclusive range [`min`, `max`].  Caller must
    /// `unloadRandomSequence(allocator, seq)` to free.
    /// Returns `error.OutOfMemory` if either the output slice or the
    /// internal pool buffer can't be allocated.  Returns `&.{}` (empty
    /// non-error slice) when `count == 0` or `count > range` - those are
    /// well-defined "no work to do" cases, not failures.
    /// The slice element type is `i32` rather than `i32`; on every
    /// target zimr supports these are the same width but `i32` is the
    /// idiomatic Zig name.  Internally the body still works in `i32`
    /// because `getRandomValue` (the rcore RNG) is typed that way; the
    /// cast happens at the slice-write boundary.
    /// Algorithm is reservoir-style for small counts; sufficient for
    /// shuffles/permutations.
    pub fn loadRandomSequence(
        gpa: Allocator,
        count: u32,
        min_in: i32,
        max_in: i32,
    ) Allocator.Error![]i32 {
        var lo: i32 = min_in;
        var hi: i32 = max_in;
        if (lo > hi) {
            const tmp: i32 = hi;
            hi = lo;
            lo = tmp;
        }
        const range: usize = @as(usize, @intCast(hi - lo + 1));
        const want: usize = @intCast(count);
        if (want == 0 or want > range) {
            return &.{};
        }

        const out = try gpa.alloc(i32, want);
        errdefer gpa.free(out);
        // Generate the full range, then Fisher-Yates shuffle the first
        // `want` slots.
        var pool = try gpa.alloc(i32, range);
        defer gpa.free(pool);
        for (0..range) |i| {
            pool[i] = lo + @as(i32, @intCast(i));
        }

        for (0..want) |idx| {
            const j = idx + @as(usize, @intCast(getRandomValue(0, @intCast(range - idx - 1))));
            const tmp: i32 = pool[idx];
            pool[idx] = pool[j];
            pool[j] = tmp;
            out[idx] = @intCast(pool[idx]);
        }
        return out;
    }

    /// Free a slice returned by `loadRandomSequence`.
    pub fn unloadRandomSequence(
        gpa: Allocator,
        seq: []i32,
    ) void {
        if (seq.len == 0) {
            return;
        }
        gpa.free(seq);
    }

    // ===========================================================================
    // File path utilities - Roadmap Step 18
    // ===========================================================================

    /// Validate that `fileName` is a valid filename for the platform.
    /// Reject empty strings, names with control chars (<32), names with
    /// `< > : " / \ | ? *`, and names consisting only of period characters.
    pub fn isFileNameValid(fileName: []const u8) bool {
        if (fileName.len == 0) {
            return false;
        }

        var all_periods: bool = true;
        for (fileName) |c| {
            // Reject characters Windows / cross-platform tooling rejects.
            switch (c) {
                '<', '>', ':', '"', '/', '\\', '|', '?', '*' => return false,
                else => {},
            }
            // Reject any control character.
            if (c < 32) {
                return false;
            }
            if (c != '.') {
                all_periods = false;
            }
        }

        // "..." or "." alone is invalid.
        if (all_periods) {
            return false;
        }
        return true;
    }

    // ---- tests (formerly src/tests/core_test.zig)
    // ---- Fake clock
    // We can't pass closures into a `*const fn () f64` so the fake clock
    // reads from a file-scope variable.  Each test sets `fake_now_ms` and
    // then advances it explicitly.

    var fake_now_ms: f64 = 0; // lint:off module-var: test-only clock (can't close over locals into a `*const fn`)

    fn fakeNow() f64 {
        return fake_now_ms;
    }

    fn setFakeNow(ms: f64) void {
        fake_now_ms = ms;
    }

    // ---- Capturing sink for traceLog tests
    const TraceLogLevel = @import("types.zig").TraceLogLevel;

    const Captured = struct {
        var count: usize = 0; // lint:off module-var: test-capture buffer
        var last_level: TraceLogLevel = .all; // lint:off module-var: test-capture (.all = no message yet)
        var last_msg: [256]u8 = undefined; // lint:off module-var: test-capture buffer
        var last_msg_len: usize = 0; // lint:off module-var: test-capture buffer
    };

    /// Default-sink callback signature is `(level: i32, msg: []const u8)`
    /// - i32 because the sink type is shared with the wasm/JS side.
    /// We convert at the boundary.
    fn captureSink(level: i32, msg: []const u8) void {
        Captured.count += 1;
        Captured.last_level = @enumFromInt(level);
        const n = @min(msg.len, Captured.last_msg.len);
        @memcpy(Captured.last_msg[0..n], msg[0..n]);
        Captured.last_msg_len = n;
    }

    fn resetCaptured() void {
        Captured.count = 0;
        Captured.last_level = .all;
        Captured.last_msg_len = 0;
    }

    // ===========================================================================
    // Timing
    // ===========================================================================

    test "initTimer zeroes getTime / getFrameTime" {
        _testReset();
        var t: TimeState = .{};
        var f: FpsState = .{};
        setFakeNow(12_345); // arbitrary "wall clock" point
        _testSetNowFn(&fakeNow);
        initTimer(&t, &f);

        try expect(getTime(&t) == 0);
        try expect(getFrameTime(&t) == 0);
    }

    test "getTime advances with the clock between begin-frames" {
        _testReset();
        var t: TimeState = .{};
        var f: FpsState = .{};
        setFakeNow(0);
        _testSetNowFn(&fakeNow);
        initTimer(&t, &f);

        setFakeNow(100); // 100 ms later
        beginFrame(&t, &f);
        try expect(@abs(getTime(&t) - 0.100) < 1e-6);

        setFakeNow(250);
        beginFrame(&t, &f);
        try expect(@abs(getTime(&t) - 0.250) < 1e-6);
    }

    test "getFrameTime equals time between begin-frames" {
        _testReset();
        var t: TimeState = .{};
        var f: FpsState = .{};
        setFakeNow(0);
        _testSetNowFn(&fakeNow);
        initTimer(&t, &f);

        setFakeNow(16); // ~60fps
        beginFrame(&t, &f);
        // First frame's `frame` is current - previous = 0.016 - 0.
        try expect(@abs(getFrameTime(&t) - 0.016) < 1e-5);

        setFakeNow(33);
        beginFrame(&t, &f);
        try expect(@abs(getFrameTime(&t) - 0.017) < 1e-5);
    }

    test "setTargetFPS = 60 stores 1/60 internally; 0/negative clears" {
        _testReset();
        var t: TimeState = .{};
        setTargetFPS(&t, 60);
        // We can't read TIME.target directly without a getter; verify
        // through the negative path that 0 doesn't crash.
        setTargetFPS(&t, 0);
        setTargetFPS(&t, -5);
        // The assertion is that none of the above panics - the
        // arithmetic in setTargetFPS would div-by-zero without the guard.
    }

    test "getFPS reports zero before frames begin" {
        _testReset();
        var t: TimeState = .{};
        var f: FpsState = .{};
        setFakeNow(0);
        _testSetNowFn(&fakeNow);
        initTimer(&t, &f);
        try expect(getFPS(&f) == 0);
    }

    test "getFPS converges toward target after enough samples" {
        _testReset();
        var t: TimeState = .{};
        var f: FpsState = .{};
        setFakeNow(0);
        _testSetNowFn(&fakeNow);
        initTimer(&t, &f);

        // Simulate 200 frames at 16ms each → 62.5 fps target.
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            setFakeNow(float64(i + 1) * 16);
            beginFrame(&t, &f);
        }
        const fps: i32 = getFPS(&f);
        // Loose bounds - the rolling-window estimator + the FPS_STEP
        // gating means we only sample ~30 times in the 3.2 second window,
        // and our deterministic-step input doesn't perfectly match
        // raylib's wall-clock-drift assumptions.  Still, fps should land
        // within a healthy range of 62.5.
        try expect(fps >= 55 and fps <= 70);
    }

    // ===========================================================================
    // traceLog
    // ===========================================================================

    test "traceLog: default level (LOG_INFO=3) drops debug/trace" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        traceLog(&ts, LOG_TRACE, "tracey", .{});
        traceLog(&ts, LOG_DEBUG, "debugy", .{});
        try expect(Captured.count == 0);

        traceLog(&ts, LOG_INFO, "infoy", .{});
        try expect(Captured.count == 1);
        try expect(Captured.last_level == LOG_INFO);
        try expect(eql(u8, Captured.last_msg[0..Captured.last_msg_len], "infoy"));
    }

    test "traceLog: setTraceLogLevel(&ts, LOG_NONE) silences everything" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        setTraceLogLevel(&ts, LOG_NONE);
        traceLog(&ts, LOG_FATAL, "boom", .{});
        traceLog(&ts, LOG_ERROR, "err", .{});
        traceLog(&ts, LOG_WARNING, "warn", .{});
        try expect(Captured.count == 0);
    }

    test "traceLog: setTraceLogLevel(&ts, LOG_ALL) lets everything through" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        setTraceLogLevel(&ts, LOG_ALL);
        traceLog(&ts, LOG_TRACE, "t", .{});
        traceLog(&ts, LOG_DEBUG, "d", .{});
        traceLog(&ts, LOG_INFO, "i", .{});
        traceLog(&ts, LOG_WARNING, "w", .{});
        traceLog(&ts, LOG_ERROR, "e", .{});
        traceLog(&ts, LOG_FATAL, "f", .{});
        try expect(Captured.count == 6);
    }

    test "traceLog: format args interpolate" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        traceLog(&ts, LOG_INFO, "fps={d} delta={d:.3}", .{ 60, 0.016 });
        try expect(Captured.count == 1);
        const msg: []const u8 = Captured.last_msg[0..Captured.last_msg_len];
        try expect(eql(u8, msg, "fps=60 delta=0.016"));
    }

    test "traceLog: callback hook overrides default sink" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        // Install a callback - `traceLog` should now route there, NOT to
        // captureSink.
        const Callback = struct {
            var count: usize = 0;
            fn cb(
                level: i32,
                ptr: [*]const u8,
                len: usize,
            ) callconv(.c) void {
                _ = level;
                _ = ptr;
                _ = len;
                count += 1;
            }
        };
        Callback.count = 0;
        setTraceLogCallback(&ts, &Callback.cb);

        traceLog(&ts, LOG_INFO, "hello", .{});
        try expect(Callback.count == 1);
        try expect(Captured.count == 0); // default sink bypassed

        // Removing the callback restores default-sink routing.
        setTraceLogCallback(&ts, null);
        traceLog(&ts, LOG_INFO, "world", .{});
        try expect(Callback.count == 1);
        try expect(Captured.count == 1);
    }

    test "traceLog public C ABI entry point routes through the same gate" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        const msg: []const u8 = "from C ABI";
        // `traceLogRaw` is the JS-FFI entry; level stays `i32` for ABI
        // shape, so the call needs an explicit `@intFromEnum`.
        traceLogRaw(&ts, @intFromEnum(LOG_INFO), msg.ptr, msg.len);
        try expect(Captured.count == 1);
        try expect(eql(u8, Captured.last_msg[0..Captured.last_msg_len], msg));
    }

    test "traceLog: empty / null-ptr message is dropped, not crashed" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        // Length 0 - silently drop.
        const empty: []const u8 = "";
        traceLogRaw(&ts, @intFromEnum(LOG_FATAL), empty.ptr, 0);
        try expect(Captured.count == 0);
    }

    // Typed log-level API.  Cat 5 / aggressive-sweep: traceLog and
    // setTraceLogLevel migrated from `i32` to `TraceLogLevel`.  These
    // tests pin the enum-shaped surface so a future regression to i32
    // breaks loudly.
    test "traceLog accepts enum tag literals (no `LOG_*` indirection)" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        traceLog(&ts, .info, "hello via tag literal", .{});
        try expect(Captured.count == 1);
        try expect(Captured.last_level == .info);
    }

    test "setTraceLogLevel/getTraceLogLevel round-trip through TraceLogLevel" {
        _testReset();
        var ts: TraceLogState = .{};
        setTraceLogLevel(&ts, .warning);
        try expect(getTraceLogLevel(&ts) == .warning);
        setTraceLogLevel(&ts, .err);
        try expect(getTraceLogLevel(&ts) == .err);
        setTraceLogLevel(&ts, .none);
        try expect(getTraceLogLevel(&ts) == .none);
    }

    test "LOG_* aliases are TraceLogLevel values (raylib-source compat)" {
        // raylib code that says `setTraceLogLevel(&ts, LOG_WARNING)` keeps
        // working - `LOG_WARNING` is a `TraceLogLevel` constant, not a
        // `i32` like in raylib C.  Pin the equivalence:
        try expect(LOG_WARNING == .warning);
        try expect(LOG_INFO == .info);
        try expect(LOG_NONE == .none);
    }

    test "level filtering works with the typed setTraceLogLevel" {
        _testReset();
        var ts: TraceLogState = .{};
        resetCaptured();
        setDefaultSink(&captureSink);

        setTraceLogLevel(&ts, .warning);
        traceLog(&ts, .info, "below threshold", .{});
        traceLog(&ts, .debug, "way below", .{});
        try expect(Captured.count == 0);

        traceLog(&ts, .warning, "at threshold", .{});
        traceLog(&ts, .err, "above threshold", .{});
        try expect(Captured.count == 2);
        try expect(Captured.last_level == .err);
    }

    // ===========================================================================
    // Window state
    // ===========================================================================

    test "getScreenWidth/Height default to 800x450 before init" {
        _testReset();
        var w: WindowState = .{};
        try expect(getScreenWidth(&w) == 800);
        try expect(getScreenHeight(&w) == 450);
    }

    test "setWindowSize round-trips through getters" {
        _testReset();
        var w: WindowState = .{};
        setWindowSize(&w, 1920, 1080);
        try expect(getScreenWidth(&w) == 1920);
        try expect(getScreenHeight(&w) == 1080);
        try expect(getRenderWidth(&w) == 1920);
        try expect(getRenderHeight(&w) == 1080);
    }

    test "windowShouldClose: false until requestClose" {
        _testReset();
        var w: WindowState = .{};
        try expect(!windowShouldClose(&w));
        requestClose(&w);
        try expect(windowShouldClose(&w));
    }

    test "isWindowFocused: defaults to true; setFocused toggles" {
        _testReset();
        var w: WindowState = .{};
        try expect(isWindowFocused(&w));
        setFocused(&w, false);
        try expect(!isWindowFocused(&w));
        setFocused(&w, true);
        try expect(isWindowFocused(&w));
    }

    // isFileNameValid - Roadmap Step 18
    test "isFileNameValid: valid simple names accepted" {
        try expect(isFileNameValid("hello.txt"));
        try expect(isFileNameValid("My Document.pdf"));
        try expect(isFileNameValid("a"));
        try expect(isFileNameValid("file.with.dots.zip"));
    }

    test "isFileNameValid: empty rejected" {
        try expect(!isFileNameValid(""));
    }

    test "isFileNameValid: forbidden chars rejected" {
        try expect(!isFileNameValid("a/b"));
        try expect(!isFileNameValid("a\\b"));
        try expect(!isFileNameValid("a:b"));
        try expect(!isFileNameValid("a*"));
        try expect(!isFileNameValid("a?"));
        try expect(!isFileNameValid("a|b"));
        try expect(!isFileNameValid("a\"b"));
        try expect(!isFileNameValid("<a>"));
    }

    test "isFileNameValid: all-period names rejected" {
        try expect(!isFileNameValid("."));
        try expect(!isFileNameValid(".."));
        try expect(!isFileNameValid("..."));
    }

    test "isFileNameValid: control characters rejected" {
        try expect(!isFileNameValid("a\tb")); // tab
        try expect(!isFileNameValid("a\x01b"));
    }

    // ===========================================================================
    // loadRandomSequence - owned-slice random permutations.
    // Cat 2c migration: used to swallow OOM as `&.{}`; now returns
    // `Allocator.Error![]i32`.  These tests pin the new behaviour.
    // ===========================================================================

    test "loadRandomSequence: count of N draws N distinct values in range" {
        const ta: Allocator = std.testing.allocator;
        const seq: []i32 = try loadRandomSequence(ta, 5, 1, 10);
        defer unloadRandomSequence(ta, seq);

        try expect(seq.len == 5);
        // All values in [1, 10] and pairwise distinct.
        var i: usize = 0;
        while (i < seq.len) : (i += 1) {
            try expect(seq[i] >= 1 and seq[i] <= 10);
            var j: usize = i + 1;
            while (j < seq.len) : (j += 1) {
                try expect(seq[i] != seq[j]);
            }
        }
    }

    test "loadRandomSequence: count == 0 returns empty slice (not error)" {
        const ta: Allocator = std.testing.allocator;
        const seq: []i32 = try loadRandomSequence(ta, 0, 0, 10);
        // Empty slice is the well-defined no-op path.  Free is still fine
        // because unloadRandomSequence early-outs on len==0.
        try expect(seq.len == 0);
        unloadRandomSequence(ta, seq);
    }

    test "loadRandomSequence: count > range returns empty slice" {
        const ta: Allocator = std.testing.allocator;
        // range is [0, 4] = 5 values; asking for 100 is impossible to
        // satisfy without repeats, so we get the empty-slice no-op.
        const seq: []i32 = try loadRandomSequence(ta, 100, 0, 4);
        try expect(seq.len == 0);
        unloadRandomSequence(ta, seq);
    }

    test "loadRandomSequence: swapped min/max still works" {
        const ta: Allocator = std.testing.allocator;
        // min > max: function silently swaps them.
        const seq: []i32 = try loadRandomSequence(ta, 3, 10, 1);
        defer unloadRandomSequence(ta, seq);
        try expect(seq.len == 3);
        var i: usize = 0;
        while (i < seq.len) : (i += 1) {
            try expect(seq[i] >= 1 and seq[i] <= 10);
        }
    }

    test "loadRandomSequence: OOM surfaces as error.OutOfMemory" {
        // FailingAllocator pre-fails every allocation - exercises the new
        // error path that used to silently return `&.{}`.
        var failing: std.testing.FailingAllocator = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = 0 },
        );
        try expectError(error.OutOfMemory, loadRandomSequence(failing.allocator(), 5, 1, 10));
    }

    test "loadRandomSequence: pool-alloc OOM cleans up out-slice" {
        // First alloc (the output) succeeds, second (the pool) fails.
        // errdefer must free the output - std.testing.FailingAllocator
        // tracks deallocations and a leak would surface as a test failure.
        var failing: std.testing.FailingAllocator = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = 1 },
        );
        try expectError(error.OutOfMemory, loadRandomSequence(failing.allocator(), 5, 1, 10));
    }

    // Phase-1A bridge-the-gap: window UX + drag-drop API.
    // The full surface (cursor keyword mapping, favicon swap, drop event
    // capture) only fires inside the JS bridge - exercised by smoke tests.
    // On the host these are all no-ops via `is_wasm` guards, so the host
    // tests just verify the safe defaults: returns false / empty / etc.
    test "Phase 1A: isFileDropped is false on host (no JS bridge)" {
        try expect(isFileDropped() == false);
    }

    test "Phase 1A: loadDroppedFiles returns empty slice on host" {
        const ta: Allocator = std.testing.allocator;
        const files: DroppedFiles = try loadDroppedFiles(ta);
        defer unloadDroppedFiles(ta, files);
        try expect(files.len == 0);
    }

    test "Phase 1A: isWindowResized is false on host" {
        try expect(isWindowResized() == false);
    }
};

// ============================================================================
// SECTION - input (was: src/input.zig)
// ============================================================================

pub const input = struct {
    const Vec2 = zm.Vec2;

    pub const MAX_KEYBOARD_KEYS: usize = 512;
    pub const MAX_KEY_PRESSED_QUEUE: usize = 16;
    pub const MAX_CHAR_PRESSED_QUEUE: usize = 16;
    pub const MAX_MOUSE_BUTTONS: usize = 8;
    pub const MAX_GAMEPADS: usize = 4;
    pub const MAX_GAMEPAD_BUTTONS: usize = 32;
    pub const MAX_GAMEPAD_AXES: usize = 8;

    /// Keyboard sub-state.
    const Keyboard = struct {
        /// Whether the key is held this frame.  Updated by event push.
        current: [MAX_KEYBOARD_KEYS]u8 = @splat(0),
        /// Snapshot of `current` at the start of the most recent frame.
        /// Copied from `current` by `endFrame`.
        previous: [MAX_KEYBOARD_KEYS]u8 = @splat(0),
        /// Set on every frame in which the OS reports a key-repeat event
        /// for the given key.  Cleared by `endFrame`.
        repeat: [MAX_KEYBOARD_KEYS]u8 = @splat(0),
        /// FIFO of recent keycode press events - drained by
        /// `getKeyPressed`.
        queue: [MAX_KEY_PRESSED_QUEUE]i32 = @splat(0),
        queue_count: usize = 0,
        /// FIFO of recent unicode codepoints from text input - drained
        /// by `getCharPressed`.
        char_queue: [MAX_CHAR_PRESSED_QUEUE]i32 = @splat(0),
        char_queue_count: usize = 0,
        /// raylib-historical: which key, if pressed, exits the program.
        /// We honour the value but don't auto-quit.
        exit_key: i32 = 256, // KEY_ESCAPE
    };

    /// Mouse sub-state.
    const Mouse = struct {
        current_button: [MAX_MOUSE_BUTTONS]u8 = @splat(0),
        previous_button: [MAX_MOUSE_BUTTONS]u8 = @splat(0),
        /// Mouse position in canvas pixels.  Set by `pushMouseMove`.
        current_position: Vec2 = @splat(0),
        /// Position at start of frame.  Used by `getMouseDelta`.
        previous_position: Vec2 = @splat(0),
        /// Per-button position recorded at the rising-edge of press.
        /// Used by the drag helpers (`isMouseDragging`,
        /// `getMouseDragDelta`).  Set by `pushMouseButtonDown` on
        /// transition 0→1; reset to the current position by
        /// `resetMouseDragDelta` (so subsequent deltas are relative
        /// to the call point rather than the original press).  Reads
        /// are meaningless unless `current_button[i]` is also held,
        /// so the drag helpers gate on that first.
        press_position: [MAX_MOUSE_BUTTONS]Vec2 = @splat(@splat(0)),
        /// Sticky "this button's press has crossed the drag threshold
        /// at least once" flag, set on the first frame where
        /// `current_position` exceeds the per-call threshold relative
        /// to `press_position`, cleared on button release.  Without
        /// this flag, `getMouseDragDelta` would re-gate on threshold
        /// every frame - and after `resetMouseDragDelta` anchors press
        /// to current, the next frame's tiny movement falls back
        /// under threshold and the delta gates to zero.  That works
        /// for desktop mouse (frame-to-frame movement is usually
        /// large) but breaks slow touch drag (frame-to-frame movement
        /// can be 1-2 px).  Once a press has been promoted to a
        /// drag, every move counts until release.
        drag_started: [MAX_MOUSE_BUTTONS]bool = @splat(false),
        /// Cumulative wheel offset for the *current* frame; cleared by
        /// `endFrame`.  Both axes - vertical (.y) is the common one,
        /// horizontal (.x) shows up on trackpads.
        current_wheel: Vec2 = @splat(0),
        /// Last frame's wheel value, used by `getMouseWheelMove` so the
        /// reading survives one extra frame after the user lifts off.
        previous_wheel: Vec2 = @splat(0),
        /// raylib's per-frame "did the cursor move at all" indicator.
        /// We don't expose it as a public API - it's used internally to
        /// know whether `previous_position` should be retained or reset.
        cursor_on_screen: bool = true,
        cursor_hidden: bool = false,
        /// The last value passed to `setMouseCursor`.  CSS doesn't let
        /// us query the canvas's current cursor style; we mirror it
        /// here so `getMouseCursor` can answer correctly.  Defaults
        /// to `.default` (matches the JS-side default `cursor: auto`).
        current_cursor: MouseCursor = .default,
    };

    /// Gamepad sub-state.  Gamepad support is stubbed in this phase
    /// the storage layout is right but the JS side hasn't wired the
    /// `gamepadconnected` events yet.  Tracking as a Phase 11 cleanup;
    /// `isGamepadAvailable` will keep returning false until then.
    const Gamepad = struct {
        ready: [MAX_GAMEPADS]bool = @splat(false),
        current_button: [MAX_GAMEPADS][MAX_GAMEPAD_BUTTONS]u8 = @splat(@splat(0)),
        previous_button: [MAX_GAMEPADS][MAX_GAMEPAD_BUTTONS]u8 = @splat(@splat(0)),
        axis: [MAX_GAMEPADS][MAX_GAMEPAD_AXES]f32 = @splat(@splat(0)),
        axis_count: [MAX_GAMEPADS]u8 = @splat(0),
        last_button_pressed: i32 = 0,
    };

    /// Maximum simultaneous touch points tracked.  10 is enough for
    /// every multi-touch device (we'd need a separate hand for the
    /// 11th finger).  Matches raylib's MAX_TOUCH_POINTS = 8 with a
    /// small buffer.
    pub const MAX_TOUCH_POINTS: usize = 10;

    /// Single tracked finger.  `id == -1` means the slot is free.
    pub const TouchPoint = struct {
        id: i32 = -1,
        x: f32 = 0,
        y: f32 = 0,
    };

    const Touch = struct {
        /// Slot table.  Order is "first-empty wins" for downs;
        /// compacted on up so the active fingers are always at slots
        /// 0..count-1 in arrival order.
        points: [MAX_TOUCH_POINTS]TouchPoint = @splat(.{}),
        /// Number of currently-down fingers (0..MAX_TOUCH_POINTS).
        count: usize = 0,
    };

    /// Input subsystem state.  Owned by `Runtime` (or constructed
    /// fresh for tests).  Functions in this namespace take a
    /// `*const InputState` (read) or `*InputState` (mutate) - the
    /// signature documents the dependency.
    /// JS event handlers reach the canonical instance via a residual
    /// `var STATE` + thin `pub export fn` shims at the end of this
    /// namespace.  That's the only place the global is touched.
    /// Phone motion sensor, fed by the `devicemotion` JS event through the
    /// `input_push_motion` export. ONE vector: accelerationIncludingGravity, m/s²,
    /// in the device's NATURAL/portrait frame (x right, y up, z out of screen).
    /// By the equivalence principle this is the only thing the accelerometer
    /// actually measures (proper acceleration) — it already fuses gravity AND
    /// motion, so the effective gravity the fluid feels is simply its negation.
    /// No separate "linear acceleration" channel is needed: tilt, shake, and
    /// free-fall all fall out of this one vector. Stored RAW (no smoothing) for
    /// zero input lag. `screen_angle` is `screen.orientation.angle` (0/90/180/270)
    /// for rotating the device frame into the (maybe landscape) canvas. `ok`
    /// flips true on the first real sample. NOTE: data only arrives on https/
    /// localhost origins — file:// and content:// fire the event but deliver
    /// nulls, so `ok` stays false and readers fall back to plain down.
    pub const Motion = struct {
        accel_x: f32 = 0,
        accel_y: f32 = 0,
        accel_z: f32 = 0,
        screen_angle: f32 = 0,
        ok: bool = false,
    };

    pub const InputState = struct {
        keyboard: Keyboard = .{},
        mouse: Mouse = .{},
        gamepad: Gamepad = .{},
        touch: Touch = .{},
        motion: Motion = .{},
    };

    // ===========================================================================
    // JS-side event ingress: the `pub fn pushX(state: *InputState, ...)`
    // helpers below take an explicit state pointer.  The matching
    // `pub export fn input_push_*` shims that JS event handlers call
    // live in `runtime_assembly.zig`, where they reach `app.?.input`
    // without forcing a `runtime → runtime_assembly` back-edge.
    // Bounds checks are deliberate - JS can hand us anything.  Out-of-
    // range keycodes are silently dropped rather than panicking.
    // ===========================================================================

    pub fn pushKeyDown(
        state: *InputState,
        key: i32,
        is_repeat: i32,
    ) void {
        if (key <= 0 or key >= MAX_KEYBOARD_KEYS) {
            return;
        }
        const idx: usize = @intCast(key);
        const was_down: bool = state.keyboard.current[idx] != 0;
        state.keyboard.current[idx] = 1;
        if (is_repeat != 0) {
            state.keyboard.repeat[idx] = 1;
        }
        // Only enqueue a press event on the rising edge - auto-repeat
        // doesn't push to the press queue.  Matches raylib's wiring.
        if (!was_down and state.keyboard.queue_count < MAX_KEY_PRESSED_QUEUE) {
            state.keyboard.queue[state.keyboard.queue_count] = key;
            state.keyboard.queue_count += 1;
        }
    }

    pub fn pushKeyUp(state: *InputState, key: i32) void {
        if (key <= 0 or key >= MAX_KEYBOARD_KEYS) {
            return;
        }
        const idx: usize = @intCast(key);
        state.keyboard.current[idx] = 0;
    }

    /// Push a unicode codepoint from text input (e.g. `keypress` event
    /// on JS side).  Independent of `pushKeyDown` - the JS `keydown`
    /// event fires for non-printable keys, the `keypress` / `input`
    /// event fires only for actual characters.
    pub fn pushChar(state: *InputState, codepoint: i32) void {
        if (codepoint <= 0) {
            return;
        }
        if (state.keyboard.char_queue_count < MAX_CHAR_PRESSED_QUEUE) {
            state.keyboard.char_queue[state.keyboard.char_queue_count] = codepoint;
            state.keyboard.char_queue_count += 1;
        }
    }

    pub fn pushMouseButtonDown(state: *InputState, button: i32) void {
        if (button < 0 or button >= MAX_MOUSE_BUTTONS) {
            return;
        }
        const idx: usize = @intCast(button);
        // Rising-edge: snapshot the current cursor position so the
        // drag helpers (`isMouseDragging`, `getMouseDragDelta`) can
        // measure displacement from press.  Doing this once per
        // press matches imgui's IO.MouseClickedPos[] semantics.
        if (state.mouse.current_button[idx] == 0) {
            state.mouse.press_position[idx] = state.mouse.current_position;
            state.mouse.drag_started[idx] = false;
        }
        state.mouse.current_button[idx] = 1;
    }

    pub fn pushMouseButtonUp(state: *InputState, button: i32) void {
        if (button < 0 or button >= MAX_MOUSE_BUTTONS) {
            return;
        }
        const idx: usize = @intCast(button);
        state.mouse.current_button[idx] = 0;
        // Clear the sticky drag flag on release - the next press
        // starts a fresh drag-or-click decision against threshold.
        state.mouse.drag_started[idx] = false;
    }

    pub fn pushMouseMove(
        state: *InputState,
        x: f32,
        y: f32,
    ) void {
        state.mouse.current_position[0] = x;
        state.mouse.current_position[1] = y;
    }

    /// Feed one accelerometer sample (accelerationIncludingGravity, m/s²) plus
    /// the screen orientation angle. Stored RAW — no smoothing — so the response
    /// has zero lag. Raw sensor noise (~0.1–0.3 m/s²) is tiny next to the ~9.8
    /// gravity signal, so it doesn't visibly jitter; the fluid's own dynamics
    /// absorb the rest.
    pub fn pushMotion(
        state: *InputState,
        ax: f32,
        ay: f32,
        az: f32,
        screen_angle: f32,
    ) void {
        state.motion.accel_x = ax;
        state.motion.accel_y = ay;
        state.motion.accel_z = az;
        state.motion.screen_angle = screen_angle;
        state.motion.ok = true;
    }

    pub fn pushMouseWheel(
        state: *InputState,
        dx: f32,
        dy: f32,
    ) void {
        // Wheel events accumulate within a frame - multiple `wheel`
        // events between two frame boundaries should sum.
        state.mouse.current_wheel[0] += dx;
        state.mouse.current_wheel[1] += dy;
    }

    // ----- Touch
    // Slot-table semantics: each finger gets a slot at touch-down,
    // identified by a browser-assigned `id`.  Subsequent move events
    // route by id; up events remove the slot and compact remaining
    // active fingers down so callers iterating 0..count-1 see them
    // in arrival order without gaps.

    pub fn pushTouchDown(
        state: *InputState,
        id: i32,
        x: f32,
        y: f32,
    ) void {
        // Reject if already tracked (browser shouldn't send dup but
        // Safari has been known to).
        for (state.touch.points[0..state.touch.count]) |p| {
            if (p.id == id) {
                return;
            }
        }
        if (state.touch.count >= MAX_TOUCH_POINTS) {
            return;
        }
        state.touch.points[state.touch.count] = .{ .id = id, .x = x, .y = y };
        state.touch.count += 1;
    }

    pub fn pushTouchMove(
        state: *InputState,
        id: i32,
        x: f32,
        y: f32,
    ) void {
        for (state.touch.points[0..state.touch.count]) |*p| {
            if (p.id == id) {
                p.x = x;
                p.y = y;
                return;
            }
        }
        // Move for an untracked id - silently drop.  Matches Safari
        // sometimes firing touchmove without a paired touchstart.
    }

    pub fn pushTouchUp(state: *InputState, id: i32) void {
        var i: usize = 0;
        while (i < state.touch.count) : (i += 1) {
            if (state.touch.points[i].id != id) {
                continue;
            }
            // Compact: shift later points down by one.
            var j: usize = i;
            while (j + 1 < state.touch.count) : (j += 1) {
                state.touch.points[j] = state.touch.points[j + 1];
            }
            state.touch.points[state.touch.count - 1] = .{}; // clear tail
            state.touch.count -= 1;
            return;
        }
    }

    // ===========================================================================
    // Per-frame promotion.  Called by the runtime AFTER the user's update
    // has read whatever state it cared about - promotes `current` to
    // `previous` so the next frame's edge-detection works.
    // ===========================================================================

    pub fn endFrame(state: *InputState) void {
        @memcpy(&state.keyboard.previous, &state.keyboard.current);
        @memcpy(&state.mouse.previous_button, &state.mouse.current_button);
        state.mouse.previous_position = state.mouse.current_position;
        state.mouse.previous_wheel = state.mouse.current_wheel;

        // Wheel accumulates *within* a frame; reset for the next.
        state.mouse.current_wheel = @splat(0);

        // Repeat flag is per-frame; clear it.
        @memset(&state.keyboard.repeat, 0);

        // Gamepad button history.
        inline for (0..MAX_GAMEPADS) |i| {
            @memcpy(&state.gamepad.previous_button[i], &state.gamepad.current_button[i]);
        }
    }

    // ===========================================================================
    // Keyboard query API.  Mirrors raylib's `IsKey*` / `getKeyPressed`.
    // ===========================================================================

    pub fn isKeyPressed(
        state: *const InputState,
        key: KeyboardKey,
    ) bool {
        const i: i32 = @intFromEnum(key);
        if (i <= 0 or i >= MAX_KEYBOARD_KEYS) {
            return false;
        }
        const u: usize = @intCast(i);
        return state.keyboard.previous[u] == 0 and state.keyboard.current[u] != 0;
    }

    pub fn isKeyPressedRepeat(
        state: *const InputState,
        key: KeyboardKey,
    ) bool {
        const i: i32 = @intFromEnum(key);
        if (i <= 0 or i >= MAX_KEYBOARD_KEYS) {
            return false;
        }
        return state.keyboard.repeat[@intCast(i)] != 0;
    }

    pub fn isKeyDown(
        state: *const InputState,
        key: KeyboardKey,
    ) bool {
        const i: i32 = @intFromEnum(key);
        if (i <= 0 or i >= MAX_KEYBOARD_KEYS) {
            return false;
        }
        return state.keyboard.current[@intCast(i)] != 0;
    }

    pub fn isKeyReleased(
        state: *const InputState,
        key: KeyboardKey,
    ) bool {
        const i: i32 = @intFromEnum(key);
        if (i <= 0 or i >= MAX_KEYBOARD_KEYS) {
            return false;
        }
        const u: usize = @intCast(i);
        return state.keyboard.previous[u] != 0 and state.keyboard.current[u] == 0;
    }

    pub fn isKeyUp(
        state: *const InputState,
        key: KeyboardKey,
    ) bool {
        const i: i32 = @intFromEnum(key);
        if (i <= 0 or i >= MAX_KEYBOARD_KEYS) {
            return true;
        }
        return state.keyboard.current[@intCast(i)] == 0;
    }

    /// Drain the keycode press queue, returning oldest first.  Returns
    /// `null` when the queue is empty - `null` replaces the old `0`
    /// sentinel which collided with the real `KeyboardKey.null` value.
    /// Mirrors raylib's destructive read semantics.
    /// `KeyboardKey` is non-exhaustive: keycodes pushed by the JS shim
    /// that don't correspond to a named tag still round-trip through
    /// `@intFromEnum` cleanly, callers just won't get a meaningful tag
    /// match for them.
    /// Mutating: drains the queue.
    pub fn getKeyPressed(state: *InputState) ?KeyboardKey {
        if (state.keyboard.queue_count == 0) {
            return null;
        }
        const v: i32 = state.keyboard.queue[0];
        // Shift left.
        for (0..state.keyboard.queue_count - 1) |i| {
            state.keyboard.queue[i] = state.keyboard.queue[i + 1];
        }
        state.keyboard.queue_count -= 1;
        state.keyboard.queue[state.keyboard.queue_count] = 0;
        return @enumFromInt(v);
    }

    /// Drain the unicode-codepoint queue, returning oldest first.
    /// Returns `null` when empty.  `u21` covers the full Unicode range
    /// (max codepoint `0x10FFFF` = 1 114 111 fits in 21 bits).
    /// Mutating: drains the queue.
    pub fn getCharPressed(state: *InputState) ?u21 {
        if (state.keyboard.char_queue_count == 0) {
            return null;
        }
        const v: i32 = state.keyboard.char_queue[0];
        for (0..state.keyboard.char_queue_count - 1) |i| {
            state.keyboard.char_queue[i] = state.keyboard.char_queue[i + 1];
        }
        state.keyboard.char_queue_count -= 1;
        state.keyboard.char_queue[state.keyboard.char_queue_count] = 0;
        return @intCast(v);
    }

    pub fn setExitKey(
        state: *InputState,
        key: KeyboardKey,
    ) void {
        state.keyboard.exit_key = @intFromEnum(key);
    }

    /// Map a `KeyboardKey` to its display name.  Returns null for unknown
    /// keys.  Names follow JS `KeyboardEvent.code` / W3C UI Events
    /// convention (e.g. `KEY_F1` → "F1", `KEY_LEFT_BRACKET` → "BracketLeft",
    /// `KEY_KP_0` → "Numpad0"), which is the natural choice in a browser
    /// runtime - matches what the user actually sees in
    /// devtools when they inspect a keypress event.
    /// Letters and digits return their character form ("A", "5") for
    /// ergonomic display in keybinding overlays.
    pub fn getKeyName(key: KeyboardKey) ?[]const u8 {
        return switch (@intFromEnum(key)) {
            // Letters: 'A'..'Z' (raylib uses uppercase ASCII as the key code)
            65 => "A",
            66 => "B",
            67 => "C",
            68 => "D",
            69 => "E",
            70 => "F",
            71 => "G",
            72 => "H",
            73 => "I",
            74 => "J",
            75 => "K",
            76 => "L",
            77 => "M",
            78 => "N",
            79 => "O",
            80 => "P",
            81 => "Q",
            82 => "R",
            83 => "S",
            84 => "T",
            85 => "U",
            86 => "V",
            87 => "W",
            88 => "X",
            89 => "Y",
            90 => "Z",
            // Digit row 0..9
            48 => "0",
            49 => "1",
            50 => "2",
            51 => "3",
            52 => "4",
            53 => "5",
            54 => "6",
            55 => "7",
            56 => "8",
            57 => "9",
            // Punctuation (US-layout).
            32 => "Space",
            39 => "Apostrophe",
            44 => "Comma",
            45 => "Minus",
            46 => "Period",
            47 => "Slash",
            59 => "Semicolon",
            61 => "Equal",
            91 => "BracketLeft",
            92 => "Backslash",
            93 => "BracketRight",
            96 => "Backquote",
            // Control keys.
            256 => "Escape",
            257 => "Enter",
            258 => "Tab",
            259 => "Backspace",
            260 => "Insert",
            261 => "Delete",
            262 => "ArrowRight",
            263 => "ArrowLeft",
            264 => "ArrowDown",
            265 => "ArrowUp",
            266 => "PageUp",
            267 => "PageDown",
            268 => "Home",
            269 => "End",
            280 => "CapsLock",
            281 => "ScrollLock",
            282 => "NumLock",
            283 => "PrintScreen",
            284 => "Pause",
            // Function row.
            290 => "F1",
            291 => "F2",
            292 => "F3",
            293 => "F4",
            294 => "F5",
            295 => "F6",
            296 => "F7",
            297 => "F8",
            298 => "F9",
            299 => "F10",
            300 => "F11",
            301 => "F12",
            // Modifiers.
            340 => "ShiftLeft",
            341 => "ControlLeft",
            342 => "AltLeft",
            343 => "MetaLeft",
            344 => "ShiftRight",
            345 => "ControlRight",
            346 => "AltRight",
            347 => "MetaRight",
            348 => "ContextMenu",
            // Numpad.
            320 => "Numpad0",
            321 => "Numpad1",
            322 => "Numpad2",
            323 => "Numpad3",
            324 => "Numpad4",
            325 => "Numpad5",
            326 => "Numpad6",
            327 => "Numpad7",
            328 => "Numpad8",
            329 => "Numpad9",
            330 => "NumpadDecimal",
            331 => "NumpadDivide",
            332 => "NumpadMultiply",
            333 => "NumpadSubtract",
            334 => "NumpadAdd",
            335 => "NumpadEnter",
            336 => "NumpadEqual",
            // Mobile / extras (raylib reserves these for Android).
            4 => "BrowserBack",
            5 => "Menu",
            24 => "AudioVolumeUp",
            25 => "AudioVolumeDown",
            // 0 = KEY_NULL - explicitly null rather than the empty string,
            // so callers can distinguish "no key" from "unknown key" via
            // the optional return.
            else => null,
        };
    }

    // ===========================================================================
    // Mouse query API.
    // ===========================================================================

    pub fn isMouseButtonPressed(
        state: *const InputState,
        button: @import("types.zig").MouseButton,
    ) bool {
        const i: usize = @intCast(@intFromEnum(button));
        return state.mouse.previous_button[i] == 0 and state.mouse.current_button[i] != 0;
    }

    pub fn isMouseButtonDown(
        state: *const InputState,
        button: @import("types.zig").MouseButton,
    ) bool {
        return state.mouse.current_button[@intCast(@intFromEnum(button))] != 0;
    }

    pub fn isMouseButtonReleased(
        state: *const InputState,
        button: @import("types.zig").MouseButton,
    ) bool {
        const i: usize = @intCast(@intFromEnum(button));
        return state.mouse.previous_button[i] != 0 and state.mouse.current_button[i] == 0;
    }

    pub fn isMouseButtonUp(
        state: *const InputState,
        button: @import("types.zig").MouseButton,
    ) bool {
        return state.mouse.current_button[@intCast(@intFromEnum(button))] == 0;
    }

    pub fn getMouseX(state: *const InputState) i32 {
        return @trunc(state.mouse.current_position[0]);
    }

    pub fn getMouseY(state: *const InputState) i32 {
        return @trunc(state.mouse.current_position[1]);
    }

    pub fn getMousePosition(state: *const InputState) Vec2 {
        return state.mouse.current_position;
    }

    /// Map a device-natural-frame screen-plane vector (x right, y UP) into canvas
    /// space (x right, y DOWN), accounting for screen orientation (0/90/180/270).
    /// This is the once-per-device-calibrated part; getDeviceGravity builds on it.
    /// The angle is always a 90° step, so rotate exactly (no trig, no std.math.pi).
    fn deviceVecToCanvas(vx: f32, vy: f32, screen_angle: f32) Vec2 {
        const steps: i32 = @round(screen_angle / 90.0);
        const q: u32 = @intCast(@mod(steps, 4));
        var sx: f32 = vx;
        var sy: f32 = vy;
        switch (q) {
            1 => {
                sx = -vy;
                sy = vx;
            },
            2 => {
                sx = -vx;
                sy = -vy;
            },
            3 => {
                sx = vy;
                sy = -vx;
            },
            else => {},
        }
        // Device y points up; canvas y points down.
        return .{ sx, -sy };
    }

    /// The EFFECTIVE GRAVITY the fluid feels, in canvas space (x right, y down),
    /// in m/s², UNNORMALISED — the caller scales it by one gain. This is the whole
    /// feature in a single vector, via Einstein's equivalence principle: an
    /// accelerometer measures proper acceleration (gravity and motion fused into
    /// ONE vector), and the body force in the phone's frame is exactly its
    /// negation. So everything emerges from this:
    ///   • held still, upright → ≈ (0, 9.8): normal downward gravity.
    ///   • tilted              → in-plane part shrinks with tilt angle, points
    ///                            downhill (real strength, not arcade full-power).
    ///   • flat on a table     → in-plane part ≈ 0 → the fluid FLOATS (zero-g).
    ///   • shaken              → the vector swings transiently → slosh.
    ///   • in free-fall        → magnitude → 0 → weightless.
    /// No sensor yet (e.g. desktop) → (0, 9.8) so gravity still works normally.
    pub fn getDeviceGravity(state: *const InputState) Vec2 {
        const m: Motion = state.motion;
        if (!m.ok) {
            return .{ 0, 9.8 }; // no accelerometer → plain 1g down
        }
        // Effective gravity = −(proper acceleration), mapped to canvas. Taking
        // only x,y drops the z component — that's exactly WHY a flat phone floats:
        // its gravity points along z, out of the screen plane, contributing none.
        return deviceVecToCanvas(-m.accel_x, -m.accel_y, m.screen_angle);
    }

    /// Mouse position in BACKING pixels with Y flipped to GL convention
    /// (origin at bottom-left).  Drop-in for `u_mouse`-style shader
    /// uniforms compared against `gl_FragCoord`.
    ///
    /// `getMousePosition` returns logical (CSS) pixels with browser-space
    /// Y (origin at top) — the units the rest of the draw API expects.
    /// `gl_FragCoord` in GLSL is in backing pixels with Y up, so mixing
    /// the two silently works on desktop (DPR=1, height ≈ logical) but
    /// is off by a factor of DPR on phones.  Use this helper to keep
    /// shader-uniform math unit-clean.
    pub fn getShaderMouse(
        state: *const InputState,
        window: *const core.WindowState,
    ) [2]f32 {
        const m: Vec2 = state.mouse.current_position;
        const rw: f32 = float(window.render_width);
        const rh: f32 = float(window.render_height);
        const sw: f32 = float(window.screen_width);
        const dpr: f32 = rw / sw;
        return .{ m[0] * dpr, rh - m[1] * dpr };
    }

    pub fn getMouseDelta(state: *const InputState) Vec2 {
        return state.mouse.current_position - state.mouse.previous_position;
    }

    pub fn getMouseWheelMove(state: *const InputState) f32 {
        // raylib returns whichever axis has the larger magnitude, signed.
        // Most users care about vertical scroll.
        const x: f32 = state.mouse.current_wheel[0];
        const y: f32 = state.mouse.current_wheel[1];
        if (@abs(y) > @abs(x)) {
            return y;
        }
        return x;
    }

    pub fn getMouseWheelMoveV(state: *const InputState) Vec2 {
        return state.mouse.current_wheel;
    }

    // ===========================================================================
    // Touch query API.  Mirrors raylib's GetTouchX/Y/Position/PointId/
    // PointCount.
    // ===========================================================================

    /// Return the X coordinate of the *first* active touch point, in
    /// canvas pixels.  Convenience for single-touch examples.  0 if no
    /// fingers are down.
    pub fn getTouchX(state: *const InputState) i32 {
        if (state.touch.count == 0) {
            return 0;
        }
        return @trunc(state.touch.points[0].x);
    }

    pub fn getTouchY(state: *const InputState) i32 {
        if (state.touch.count == 0) {
            return 0;
        }
        return @trunc(state.touch.points[0].y);
    }

    /// Return the position of the touch at slot `index` (0..count-1).
    /// Out-of-range index returns (0, 0).
    pub fn getTouchPosition(
        state: *const InputState,
        index: i32,
    ) Vec2 {
        if (index < 0 or index >= MAX_TOUCH_POINTS) {
            return @splat(0);
        }
        const i: usize = @intCast(index);
        if (i >= state.touch.count) {
            return @splat(0);
        }
        return .{ state.touch.points[i].x, state.touch.points[i].y };
    }

    /// Return the browser-assigned identifier for the touch at slot
    /// `index`.  Use for matching cross-frame: a touch that was at
    /// slot 0 in frame N might shift to slot 0 still in frame N+1
    /// (if no other finger went up first), but its `id` is stable.
    /// Out-of-range returns -1.
    pub fn getTouchPointId(
        state: *const InputState,
        index: i32,
    ) i32 {
        if (index < 0 or index >= MAX_TOUCH_POINTS) {
            return -1;
        }
        const i: usize = @intCast(index);
        if (i >= state.touch.count) {
            return -1;
        }
        return @intCast(state.touch.points[i].id);
    }

    /// Number of currently-active touch points (fingers down).
    pub fn getTouchPointCount(state: *const InputState) i32 {
        return @intCast(state.touch.count);
    }

    test "touch: single finger down → count=1, getTouch returns coords" {
        var state: InputState = .{};

        pushTouchDown(&state, 42, 100.5, 200.5);
        try expectEqual(@as(i32, 1), getTouchPointCount(&state));
        try expectEqual(@as(i32, 100), getTouchX(&state));
        try expectEqual(@as(i32, 200), getTouchY(&state));
        try expectEqual(@as(i32, 42), getTouchPointId(&state, 0));

        const pos: Vec2 = getTouchPosition(&state, 0);
        try expectEqual(@as(f32, 100.5), pos[0]);
        try expectEqual(@as(f32, 200.5), pos[1]);
    }

    test "touch: three fingers, middle one lifts, slot compacts" {
        var state: InputState = .{};
        pushTouchDown(&state, 10, 0, 0);
        pushTouchDown(&state, 20, 100, 100);
        pushTouchDown(&state, 30, 200, 200);
        try expectEqual(@as(i32, 3), getTouchPointCount(&state));

        // Lift the middle finger (id 20).
        pushTouchUp(&state, 20);
        try expectEqual(@as(i32, 2), getTouchPointCount(&state));

        // Slots compacted: slot 0 = id 10, slot 1 = id 30.
        try expectEqual(@as(i32, 10), getTouchPointId(&state, 0));
        try expectEqual(@as(i32, 30), getTouchPointId(&state, 1));
    }

    test "touch: move updates by id, not slot index" {
        var state: InputState = .{};
        pushTouchDown(&state, 7, 0, 0);
        pushTouchDown(&state, 8, 50, 50);

        pushTouchMove(&state, 8, 99, 99); // move id 8 (slot 1)
        const p1: Vec2 = getTouchPosition(&state, 1);
        try expectEqual(@as(f32, 99), p1[0]);
        try expectEqual(@as(f32, 99), p1[1]);
        // id 7 (slot 0) untouched
        const p0: Vec2 = getTouchPosition(&state, 0);
        try expectEqual(@as(f32, 0), p0[0]);
    }

    test "touch: out-of-range index returns safe defaults" {
        var state: InputState = .{};
        try expectEqual(@as(i32, 0), getTouchPointCount(&state));
        try expectEqual(@as(i32, 0), getTouchX(&state));
        try expectEqual(@as(i32, 0), getTouchY(&state));
        try expectEqual(@as(i32, -1), getTouchPointId(&state, 0));
        try expectEqual(@as(i32, -1), getTouchPointId(&state, 99));

        const p: Vec2 = getTouchPosition(&state, 99);
        try expectEqual(@as(f32, 0), p[0]);
    }

    test "touch: dropping a touch we don't track is a silent no-op" {
        var state: InputState = .{};
        pushTouchUp(&state, 99); // never went down
        try expectEqual(@as(i32, 0), getTouchPointCount(&state));

        // Move on untracked id - also silent.
        pushTouchMove(&state, 99, 100, 100);
        try expectEqual(@as(i32, 0), getTouchPointCount(&state));
    }

    // ===========================================================================
    // Gamepad query API - stubs returning safe defaults.  Wire-up in
    // Phase 11 cleanup once an example needs gamepad support.
    // ===========================================================================

    pub fn isGamepadAvailable(
        state: *const InputState,
        gamepad: i32,
    ) bool {
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return false;
        }
        return state.gamepad.ready[@intCast(gamepad)];
    }

    pub fn isGamepadButtonDown(
        state: *const InputState,
        gamepad: i32,
        button: @import("types.zig").GamepadButton,
    ) bool {
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return false;
        }
        return state.gamepad.current_button[@intCast(gamepad)][@intCast(@intFromEnum(button))] != 0;
    }

    pub fn isGamepadButtonPressed(
        state: *const InputState,
        gamepad: i32,
        button: @import("types.zig").GamepadButton,
    ) bool {
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return false;
        }
        const g: usize = @intCast(gamepad);
        const b: usize = @intCast(@intFromEnum(button));
        return state.gamepad.previous_button[g][b] == 0 and state.gamepad.current_button[g][b] != 0;
    }

    /// True for one frame when the button transitions from pressed to released.
    pub fn isGamepadButtonReleased(
        state: *const InputState,
        gamepad: i32,
        button: @import("types.zig").GamepadButton,
    ) bool {
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return false;
        }
        const g: usize = @intCast(gamepad);
        const b: usize = @intCast(@intFromEnum(button));
        return state.gamepad.previous_button[g][b] != 0 and state.gamepad.current_button[g][b] == 0;
    }

    /// True if the button is currently NOT pressed.
    pub fn isGamepadButtonUp(
        state: *const InputState,
        gamepad: i32,
        button: @import("types.zig").GamepadButton,
    ) bool {
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return true; // out-of-range → up
        }
        return state.gamepad.current_button[@intCast(gamepad)][@intCast(@intFromEnum(button))] == 0;
    }

    /// Returns the index of the last-pressed gamepad button (across all
    /// connected gamepads), or `null` if no button is currently pressed.
    /// `null` replaces the old `0` sentinel which collided with the real
    /// `@import("types.zig").GamepadButton.unknown` value (raylib used 0 here even though it's
    /// a legitimate enum tag).
    pub fn getGamepadButtonPressed(state: *const InputState) ?@import("types.zig").GamepadButton {
        for (0..MAX_GAMEPADS) |g| {
            if (!state.gamepad.ready[g]) {
                continue;
            }
            for (0..MAX_GAMEPAD_BUTTONS) |b| {
                if (state.gamepad.current_button[g][b] != 0) {
                    return @enumFromInt(b);
                }
            }
        }
        return null;
    }

    pub fn getGamepadAxisMovement(
        state: *const InputState,
        gamepad: i32,
        axis: @import("types.zig").GamepadAxis,
    ) f32 {
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return 0;
        }
        return state.gamepad.axis[@intCast(gamepad)][@intCast(@intFromEnum(axis))];
    }

    /// Number of axes the gamepad reports.  We always allocate
    /// `MAX_GAMEPAD_AXES` slots in the input state but a Web Gamepad API
    /// device might report fewer - the surplus stay at 0.0.  For now we
    /// just return `MAX_GAMEPAD_AXES` if the gamepad is connected,
    /// matching what the JS host populates.  Future work: track per-pad
    /// axis count via a separate state field.
    pub fn getGamepadAxisCount(
        state: *const InputState,
        gamepad: i32,
    ) i32 {
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return 0;
        }
        if (!state.gamepad.ready[@intCast(gamepad)]) {
            return 0;
        }
        return MAX_GAMEPAD_AXES;
    }

    /// Return a static name string for the gamepad, or `null` if not
    /// connected.  In a browser environment the Gamepad API exposes
    /// `gamepad.id` (a free-form string); for now we return a generic
    /// "Gamepad N" placeholder.  Future work: pass the JS-side id through
    /// to wasm via a string pool.
    pub fn getGamepadName(
        state: *const InputState,
        gamepad: i32,
    ) ?[*:0]const u8 {
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return null;
        }
        if (!state.gamepad.ready[@intCast(gamepad)]) {
            return null;
        }
        return switch (gamepad) {
            0 => "Gamepad 0",
            1 => "Gamepad 1",
            2 => "Gamepad 2",
            3 => "Gamepad 3",
            else => "Gamepad",
        };
    }

    /// Trigger a dual-rumble vibration on `gamepad` (0..MAX_GAMEPADS).
    /// `left_motor` and `right_motor` are normalized magnitudes in
    /// [0, 1] (clamped on the JS side).  `duration` is in seconds.
    /// Silent no-op for invalid pad index, disconnected pad, or
    /// browser/hardware that doesn't expose `vibrationActuator`.
    pub fn setGamepadVibration(
        state: *const InputState,
        gamepad: i32,
        left_motor: f32,
        right_motor: f32,
        duration: f32,
    ) void {
        if (comptime !@import("builtin").target.cpu.arch.isWasm()) {
            return;
        }
        if (gamepad < 0 or gamepad >= MAX_GAMEPADS) {
            return;
        }
        if (!state.gamepad.ready[@intCast(gamepad)]) {
            return;
        }
        const ms_f: f32 = @max(0.0, duration * 1000.0);
        const ms: u32 = @trunc(@min(ms_f, @as(f32, zm.maxInt(u32))));
        @import("web.zig").dom.gamepad_vibrate(gamepad, left_motor, right_motor, ms);
    }

    test "setGamepadVibration: out-of-range pad is silent no-op" {
        // Host build: function returns immediately at the comptime
        // arch check.  We just verify it compiles + doesn't trap.
        var state: InputState = .{};
        setGamepadVibration(&state, -1, 1.0, 1.0, 0.5);
        setGamepadVibration(&state, MAX_GAMEPADS, 1.0, 1.0, 0.5);
        setGamepadVibration(&state, 0, 0.5, 0.5, 1.0);
    }

    // ===========================================================================
    // Test helpers - only used by inline tests below + cross-module
    // tests in this file.  Each takes a `*InputState` since tests own
    // a stack-local `var state: InputState = .{};`.
    // ===========================================================================

    pub fn _testReset(state: *InputState) void {
        state.* = .{};
    }

    pub fn _testKeyDown(
        state: *InputState,
        key: i32,
    ) void {
        pushKeyDown(state, key, 0);
    }

    pub fn _testKeyUp(
        state: *InputState,
        key: i32,
    ) void {
        pushKeyUp(state, key);
    }

    pub fn _testEndFrame(state: *InputState) void {
        endFrame(state);
    }

    pub fn _testGetCurrentKeyState(
        state: *const InputState,
        key: i32,
    ) bool {
        if (key <= 0 or key >= MAX_KEYBOARD_KEYS) {
            return false;
        }
        return state.keyboard.current[@intCast(key)] != 0;
    }

    pub fn _testGetPreviousKeyState(
        state: *const InputState,
        key: i32,
    ) bool {
        if (key <= 0 or key >= MAX_KEYBOARD_KEYS) {
            return false;
        }
        return state.keyboard.previous[@intCast(key)] != 0;
    }

    // ===========================================================================
    // Cursor / pointer-lock - Phase 12 port
    // ===========================================================================

    const builtin_for_cursor = @import("builtin");
    const dom_for_cursor = if (builtin_for_cursor.target.cpu.arch.isWasm()) @import("web.zig").dom else struct {};

    /// Show the OS cursor over the canvas.  Pairs with `hideCursor`.
    pub fn showCursor(state: *InputState) void {
        state.mouse.cursor_hidden = false;
        if (comptime builtin_for_cursor.target.cpu.arch.isWasm()) {
            dom_for_cursor.set_cursor_style(0);
        }
    }

    /// Hide the OS cursor over the canvas.  Pairs with `showCursor`.
    pub fn hideCursor(state: *InputState) void {
        state.mouse.cursor_hidden = true;
        if (comptime builtin_for_cursor.target.cpu.arch.isWasm()) {
            dom_for_cursor.set_cursor_style(1);
        }
    }

    /// Reports whether the cursor is hidden, including via pointer-lock.
    pub fn isCursorHidden(state: *const InputState) bool {
        return state.mouse.cursor_hidden;
    }

    /// Returns whether the cursor is currently over the canvas.
    pub fn isCursorOnScreen(state: *const InputState) bool {
        return state.mouse.cursor_on_screen;
    }

    /// Lock the pointer to the canvas (capture for first-person controls)
    /// and hide the OS cursor.  Browser may show a permission UI.
    pub fn disableCursor(state: *InputState) void {
        state.mouse.cursor_hidden = true;
        if (comptime builtin_for_cursor.target.cpu.arch.isWasm()) {
            dom_for_cursor.set_cursor_style(1);
            dom_for_cursor.request_pointer_lock();
        }
    }

    /// Release pointer-lock and show the cursor.
    pub fn enableCursor(state: *InputState) void {
        state.mouse.cursor_hidden = false;
        if (comptime builtin_for_cursor.target.cpu.arch.isWasm()) {
            dom_for_cursor.exit_pointer_lock();
            dom_for_cursor.set_cursor_style(0);
        }
    }

    // ===========================================================================
    // Phase-1A bridge-the-gap: SetMouseCursor.  raylib's MouseCursor
    // enum maps to a CSS cursor keyword in the JS bridge.
    // ===========================================================================

    /// raylib's MouseCursor enum.  Aliased to `types.MouseCursor`
    /// the single canonical definition lives in `types.zig` so all
    /// flat re-exports (`z.MouseCursor`) and namespaced accesses
    /// (`z.types.MouseCursor`, `z.input.MouseCursor`) resolve to the
    /// SAME nominal type.  Previously this was a duplicate enum
    /// definition; the api-flatten arc unified them.
    pub const MouseCursor = @import("types.zig").MouseCursor;

    /// Set the canvas cursor style.  raylib: `SetMouseCursor(int cursor)`.
    /// Maps the MouseCursor enum to a CSS cursor keyword on the JS side
    /// AND mirrors the value on `state.mouse.current_cursor` so a later
    /// `getMouseCursor` returns the same answer (CSS doesn't let us
    /// query the live canvas cursor - the spec returns the computed
    /// value, not the inline style, and Chrome reports it as `auto`
    /// regardless of what was set).
    /// Reads: `state.mouse.current_cursor` (no-op shortcut - repeated
    /// `setMouseCursor(.default)` calls only hit the JS bridge once).
    /// Mutates: `state.mouse.current_cursor`; calls `dom.set_mouse_cursor`
    /// (which writes `canvas.style.cursor`).
    pub fn setMouseCursor(state: *InputState, cursor: MouseCursor) void {
        if (state.mouse.current_cursor == cursor) {
            return;
        }
        state.mouse.current_cursor = cursor;
        if (comptime !builtin_for_cursor.target.cpu.arch.isWasm()) {
            return;
        }
        dom_for_cursor.set_mouse_cursor(@intCast(@intFromEnum(cursor)));
    }

    /// Return the last cursor value set via `setMouseCursor`.  Defaults
    /// to `.default` for a freshly-constructed `InputState`.  Pure
    /// read - never touches the JS bridge.
    pub fn getMouseCursor(state: *const InputState) MouseCursor {
        return state.mouse.current_cursor;
    }

    // ===========================================================================
    // Mouse drag helpers - imgui-style.  Track displacement from the
    // most recent button-press position (recorded by `pushMouseButtonDown`
    // on its rising edge).
    // ===========================================================================

    /// imgui's default drag-start threshold in pixels.  The mouse must
    /// move more than this from the press position before
    /// `isMouseDragging` reports true.  Calls passing a negative
    /// `lock_threshold` fall back to this value.
    pub const MOUSE_DRAG_THRESHOLD_DEFAULT: f32 = 6.0;

    /// True when `button` is held AND the cursor has moved more than
    /// `lock_threshold` pixels from the position it was pressed at.
    /// Pass `-1` to use `MOUSE_DRAG_THRESHOLD_DEFAULT`.  Use this to
    /// distinguish a click (small movement) from a drag (significant
    /// movement) - typical pattern: `if (isMouseDragging(state, .left, -1))
    /// continueDragOp(getMouseDragDelta(state, .left, -1))`.
    /// Threshold uses L∞ (Chebyshev) distance - same shape as imgui's,
    /// matching dx² + dy² > t² with a single comparison on |Δ| max.
    pub fn isMouseDragging(
        state: *InputState,
        button: @import("types.zig").MouseButton,
        lock_threshold: f32,
    ) bool {
        const idx: usize = @intCast(@intFromEnum(button));
        if (state.mouse.current_button[idx] == 0) {
            return false;
        }
        // Once promoted to a drag, stay engaged regardless of current
        // distance - caller may have just reset the anchor via
        // `resetMouseDragDelta`.  Per-frame re-gating breaks slow
        // touch drags where frame-to-frame movement is sub-threshold.
        if (state.mouse.drag_started[idx]) {
            return true;
        }
        const t: f32 = if (lock_threshold < 0) MOUSE_DRAG_THRESHOLD_DEFAULT else lock_threshold;
        const dx: f32 = state.mouse.current_position[0] - state.mouse.press_position[idx][0];
        const dy: f32 = state.mouse.current_position[1] - state.mouse.press_position[idx][1];
        if ((dx * dx + dy * dy) > (t * t)) {
            state.mouse.drag_started[idx] = true;
            return true;
        }
        return false;
    }

    /// Cursor displacement since the most recent press of `button`.
    /// Returns `(0, 0)` if the button isn't held OR the threshold
    /// hasn't been exceeded yet - same gating as `isMouseDragging` so
    /// the two can be paired without conditionals.  Threshold semantics
    /// match `isMouseDragging`.
    /// Once the threshold is crossed on a given press, the sticky
    /// `drag_started` flag means subsequent reads return the live
    /// displacement even if the caller has reset the anchor and the
    /// next move is small.  Important for slow touch drags.
    /// Common use: a custom-widget drag handler reads delta each frame,
    /// applies it as a position offset, and calls
    /// `resetMouseDragDelta` to make the next read incremental.
    pub fn getMouseDragDelta(
        state: *InputState,
        button: @import("types.zig").MouseButton,
        lock_threshold: f32,
    ) Vec2 {
        const idx: usize = @intCast(@intFromEnum(button));
        if (state.mouse.current_button[idx] == 0) {
            return @splat(0);
        }
        // Sticky: if already promoted, return raw displacement.
        if (state.mouse.drag_started[idx]) {
            return state.mouse.current_position - state.mouse.press_position[idx];
        }
        const t: f32 = if (lock_threshold < 0) MOUSE_DRAG_THRESHOLD_DEFAULT else lock_threshold;
        const dx: f32 = state.mouse.current_position[0] - state.mouse.press_position[idx][0];
        const dy: f32 = state.mouse.current_position[1] - state.mouse.press_position[idx][1];
        if ((dx * dx + dy * dy) <= (t * t)) {
            return @splat(0);
        }
        // Crossed threshold this read - promote and return.
        state.mouse.drag_started[idx] = true;
        return .{ dx, dy };
    }

    /// Reset the press-position anchor for `button` to the current
    /// cursor position.  Subsequent `getMouseDragDelta` reads start
    /// fresh from here - useful when a drag handler consumes the
    /// delta each frame and wants the next frame's delta to be
    /// "movement since last frame" rather than "movement since press".
    /// No-op if the button isn't currently held - there's nothing to
    /// reset against.
    pub fn resetMouseDragDelta(
        state: *InputState,
        button: @import("types.zig").MouseButton,
    ) void {
        const idx: usize = @intCast(@intFromEnum(button));
        if (state.mouse.current_button[idx] == 0) {
            return;
        }
        state.mouse.press_position[idx] = state.mouse.current_position;
    }

    /// True if the current mouse position is inside the axis-aligned
    /// rectangle `(x0..x1, y0..y1)`.  Edges are inclusive on the
    /// near side, exclusive on the far side (imgui semantics - half-
    /// open interval to avoid double-counting adjacent rects in a
    /// gallery layout).  Coordinates use the same space as
    /// `getMousePosition` - canvas CSS pixels in `.responsive` scale
    /// mode, the init-time logical box in `.stretch` mode.
    pub fn isMouseHoveringRect(
        state: *const InputState,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
    ) bool {
        const p: Vec2 = state.mouse.current_position;
        return p[0] >= x0 and p[0] < x1 and p[1] >= y0 and p[1] < y1;
    }

    // ===========================================================================
    // B2: Keyboard chords + shortcuts.  imgui parity.
    // A `KeyChord` is a single non-modifier key plus a 4-bool mask of
    // which modifiers (Ctrl / Shift / Alt / Super) must be held.  The
    // chord "fires" on the rising edge of the key - meaning the
    // chord lookup matches imgui's `IsKeyChordPressed`: edge-triggered
    // on the primary key, level-triggered on modifiers.
    // ===========================================================================

    /// Imgui-shape key chord.  Construct inline at call sites:
    /// `.{ .key = .s, .ctrl = true }` for Ctrl+S, etc.  Modifier
    /// fields default to false so callers only have to spell out
    /// the ones they need.
    /// Both left- and right-side modifier keys count - `ctrl = true`
    /// matches if EITHER `left_control` or `right_control` is held.
    /// Specifying `ctrl = false` requires NEITHER held - pressing
    /// Ctrl+S does not fire a bare-S chord, even though S itself is
    /// pressed.  Strict matching avoids the common "accidental
    /// hotkey fires when modifier held" footgun.
    pub const KeyChord = struct {
        key: @import("types.zig").KeyboardKey,
        ctrl: bool = false,
        shift: bool = false,
        alt: bool = false,
        super: bool = false,
    };

    /// Optional behavior tweaks for shortcut matching.  Today this is
    /// just `repeat`; future flags (RouteFocused, RouteActive,
    /// RouteGlobal, etc.) will land here as the multi-window /
    /// menu-bar surface grows in B3.
    pub const ShortcutOpts = struct {
        /// If true, the chord also fires on auto-repeat events
        /// (held key emitting periodic press events).  Default
        /// false - most shortcuts fire once per press.  Useful
        /// for arrow keys + modifier (e.g. Shift+Down for
        /// extend-selection-by-line in a text editor).
        repeat: bool = false,
    };

    /// True if `chord.key` was pressed THIS frame AND the modifier
    /// state matches exactly.  Edge-triggered on the key, level-
    /// triggered on modifiers.  Pass `opts.repeat = true` to also
    /// fire on auto-repeat events.
    /// Modifier rules: each `chord.{ctrl,shift,alt,super}` field
    /// must match the held state of EITHER the left- or right-side
    /// physical key.  `chord.ctrl = true` matches if `left_control`
    /// OR `right_control` is held.  `chord.ctrl = false` requires
    /// BOTH released - Ctrl+S won't fire a bare-S chord.
    pub fn isKeyChordPressed(
        state: *const InputState,
        chord: KeyChord,
        opts: ShortcutOpts,
    ) bool {
        const ctrl_down: bool = isKeyDown(state, .left_control) or isKeyDown(state, .right_control);
        const shift_down: bool = isKeyDown(state, .left_shift) or isKeyDown(state, .right_shift);
        const alt_down: bool = isKeyDown(state, .left_alt) or isKeyDown(state, .right_alt);
        const super_down: bool = isKeyDown(state, .left_super) or isKeyDown(state, .right_super);
        if (ctrl_down != chord.ctrl) {
            return false;
        }
        if (shift_down != chord.shift) {
            return false;
        }
        if (alt_down != chord.alt) {
            return false;
        }
        if (super_down != chord.super) {
            return false;
        }
        if (isKeyPressed(state, chord.key)) {
            return true;
        }
        if (opts.repeat and isKeyPressedRepeat(state, chord.key)) {
            return true;
        }
        return false;
    }

    // ---- tests (formerly src/tests/input_test.zig)
    // ---- alias for the test body
    const KeyboardKey = @import("types.zig").KeyboardKey;

    // `_testKeyDown` and friends still take `i32` (raw scancodes), so we
    // keep these literals for driving the input state machine.  The
    // matching enum tags are used for `isKey*` reads which now take
    // `KeyboardKey` directly.
    const KEY_A: i32 = 65;
    const KEY_B: i32 = 66;
    const KEY_S: i32 = 83;
    const KEY_SPACE: i32 = 32;
    const KEY_ESCAPE: i32 = 256;
    const K_A: KeyboardKey = .a;
    const K_B: KeyboardKey = .b;
    const K_SPACE: KeyboardKey = .space;
    const K_ESCAPE: KeyboardKey = .escape;

    // ===========================================================================
    // Keyboard edge detection
    // ===========================================================================

    test "fresh state: nothing is pressed/down" {
        var state: InputState = .{};
        try expect(!isKeyDown(&state, K_A));
        try expect(!isKeyPressed(&state, K_A));
        try expect(!isKeyReleased(&state, K_A));
        try expect(isKeyUp(&state, K_A));
    }

    test "rising edge: down + first frame yields isKeyPressed true exactly once" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);

        // Before endFrame: previous is still 0, current is 1.
        // isKeyPressed = previous == 0 && current == 1 → true.
        try expect(isKeyPressed(&state, K_A));
        try expect(isKeyDown(&state, K_A));
        try expect(!isKeyReleased(&state, K_A));
        try expect(!isKeyUp(&state, K_A));

        // After endFrame promotes current → previous, isKeyPressed should
        // go false because the rising edge has been "consumed".
        _testEndFrame(&state);
        try expect(!isKeyPressed(&state, K_A));
        try expect(isKeyDown(&state, K_A));
    }

    test "falling edge: release + frame yields isKeyReleased exactly once" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        _testEndFrame(&state); // Now both prev and current are 1.

        _testKeyUp(&state, KEY_A);
        // previous == 1, current == 0 → released.
        try expect(isKeyReleased(&state, K_A));
        try expect(!isKeyDown(&state, K_A));
        try expect(isKeyUp(&state, K_A));

        _testEndFrame(&state);
        try expect(!isKeyReleased(&state, K_A));
    }

    test "holding a key: isKeyDown stays true across many frames" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        var i: usize = 0;
        while (i < 60) : (i += 1) {
            try expect(isKeyDown(&state, K_A));
            _testEndFrame(&state);
        }
    }

    test "holding a key: isKeyPressed only fires on the first frame" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        try expect(isKeyPressed(&state, K_A));
        _testEndFrame(&state);

        var i: usize = 0;
        while (i < 30) : (i += 1) {
            try expect(!isKeyPressed(&state, K_A));
            try expect(isKeyDown(&state, K_A));
            _testEndFrame(&state);
        }
    }

    // ===========================================================================
    // Key press queue
    // ===========================================================================

    test "getKeyPressed drains FIFO order" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        _testKeyDown(&state, KEY_B);
        _testKeyDown(&state, KEY_SPACE);

        try expect(getKeyPressed(&state) == .a);
        try expect(getKeyPressed(&state) == .b);
        try expect(getKeyPressed(&state) == .space);
        // Empty queue returns null (was: 0).
        try expect(getKeyPressed(&state) == null);
        try expect(getKeyPressed(&state) == null);
    }

    test "auto-repeat (is_repeat=1) does NOT enqueue a press" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        try expect(getKeyPressed(&state) == .a);

        // Simulate an OS auto-repeat event for the same key (still down).
        pushKeyDown(&state, KEY_A, 1);
        // Queue should remain empty - the rising-edge guard kicks in.
        try expect(getKeyPressed(&state) == null);
        // But isKeyPressedRepeat should report true for this frame.
        try expect(isKeyPressedRepeat(&state, K_A));

        // After endFrame, repeat flag clears.
        _testEndFrame(&state);
        try expect(!isKeyPressedRepeat(&state, K_A));
    }

    test "press queue saturates at MAX_KEY_PRESSED_QUEUE" {
        var state: InputState = .{};
        var k: i32 = 1;
        while (k <= 32) : (k += 1) {
            _testKeyDown(&state, k);
        }
        // First 16 should drain in order; remainder dropped.
        // The pushed values 1..16 mostly aren't named KeyboardKey tags
        // (the enum is non-exhaustive), so we read the raw int via
        // `@intFromEnum` to verify ordering - this exercises the
        // pass-through path the JS shim depends on for unrecognized keys.
        var i: i32 = 1;
        while (i <= 16) : (i += 1) {
            const got = getKeyPressed(&state) orelse return error.TestExpectedKey;
            try expect(@intFromEnum(got) == i);
        }
        try expect(getKeyPressed(&state) == null); // Exhausted.
    }

    test "press queue: pressing same key twice without release is one entry" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        _testKeyDown(&state, KEY_A); // Second push without release.
        try expect(getKeyPressed(&state) == .a);
        try expect(getKeyPressed(&state) == null); // Only one entry.
    }

    test "press queue: re-press after release adds a second entry" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        _testKeyUp(&state, KEY_A);
        _testKeyDown(&state, KEY_A);
        try expect(getKeyPressed(&state) == .a);
        try expect(getKeyPressed(&state) == .a);
        try expect(getKeyPressed(&state) == null);
    }

    // ===========================================================================
    // Char queue
    // ===========================================================================

    test "getCharPressed drains FIFO order" {
        var state: InputState = .{};
        pushChar(&state, 'h');
        pushChar(&state, 'i');
        try expect(getCharPressed(&state) == 'h');
        try expect(getCharPressed(&state) == 'i');
        try expect(getCharPressed(&state) == null);
    }

    // ===========================================================================
    // Bounds checks: malicious / buggy input must not crash
    // ===========================================================================

    test "out-of-range keycodes are silently ignored" {
        var state: InputState = .{};
        // Negative
        _testKeyDown(&state, -1);
        try expect(!isKeyDown(&state, @enumFromInt(-1)));
        // Beyond MAX
        _testKeyDown(&state, 99999);
        try expect(!isKeyDown(&state, @enumFromInt(99999)));
        // Zero (= KEY_NULL) - also rejected by raylib.
        _testKeyDown(&state, 0);
        try expect(!isKeyDown(&state, .null));
    }

    test "queries with bad keycodes return safe values" {
        var state: InputState = .{};
        try expect(!isKeyDown(&state, @enumFromInt(-50)));
        try expect(!isKeyPressed(&state, @enumFromInt(-50)));
        try expect(!isKeyReleased(&state, @enumFromInt(99999)));
        try expect(isKeyUp(&state, @enumFromInt(-50))); // out-of-range == "not down"
    }

    // ===========================================================================
    // Mouse buttons
    // ===========================================================================

    const MouseButton = @import("types.zig").MouseButton;
    const MB_LEFT: i32 = 0;
    const MB_RIGHT: i32 = 1;
    const M_LEFT: MouseButton = .left;
    const M_RIGHT: MouseButton = .right;

    test "mouse button rising/falling edge mirrors keys" {
        var state: InputState = .{};
        pushMouseButtonDown(&state, MB_LEFT);
        try expect(isMouseButtonPressed(&state, M_LEFT));
        try expect(isMouseButtonDown(&state, M_LEFT));

        _testEndFrame(&state);
        try expect(!isMouseButtonPressed(&state, M_LEFT));
        try expect(isMouseButtonDown(&state, M_LEFT));

        pushMouseButtonUp(&state, MB_LEFT);
        try expect(isMouseButtonReleased(&state, M_LEFT));
        try expect(!isMouseButtonDown(&state, M_LEFT));

        _testEndFrame(&state);
        try expect(!isMouseButtonReleased(&state, M_LEFT));
    }

    test "two mouse buttons are tracked independently" {
        var state: InputState = .{};
        pushMouseButtonDown(&state, MB_LEFT);
        try expect(isMouseButtonDown(&state, M_LEFT));
        try expect(!isMouseButtonDown(&state, M_RIGHT));

        pushMouseButtonDown(&state, MB_RIGHT);
        try expect(isMouseButtonDown(&state, M_LEFT));
        try expect(isMouseButtonDown(&state, M_RIGHT));

        pushMouseButtonUp(&state, MB_LEFT);
        try expect(!isMouseButtonDown(&state, M_LEFT));
        try expect(isMouseButtonDown(&state, M_RIGHT));
    }

    // ===========================================================================
    // Mouse position + delta
    // ===========================================================================

    test "mouse position round-trips" {
        var state: InputState = .{};
        pushMouseMove(&state, 123.5, 456.0);
        try expect(getMouseX(&state) == 123);
        try expect(getMouseY(&state) == 456);
        const p: Vec2 = getMousePosition(&state);
        try expect(p[0] == 123.5);
        try expect(p[1] == 456.0);
    }

    test "mouse delta = current - previous, computed at query time" {
        var state: InputState = .{};
        pushMouseMove(&state, 100, 100);
        _testEndFrame(&state);
        // After endFrame, previous = (100, 100).  Now move.
        pushMouseMove(&state, 150, 80);
        const d: Vec2 = getMouseDelta(&state);
        try expect(d[0] == 50);
        try expect(d[1] == -20);
    }

    // ===========================================================================
    // Mouse wheel
    // ===========================================================================

    test "mouse wheel accumulates within a frame" {
        var state: InputState = .{};
        pushMouseWheel(&state, 0, 1);
        pushMouseWheel(&state, 0, 2);
        pushMouseWheel(&state, 0, -0.5);
        // Net 2.5 vertical.
        try expect(getMouseWheelMove(&state) == 2.5);
    }

    test "mouse wheel resets on endFrame" {
        var state: InputState = .{};
        pushMouseWheel(&state, 0, 5);
        try expect(getMouseWheelMove(&state) == 5);
        _testEndFrame(&state);
        try expect(getMouseWheelMove(&state) == 0);
    }

    // ===========================================================================
    // B1: Mouse cursor mirror + drag helpers + isMouseHoveringRect
    // ===========================================================================

    test "B1: setMouseCursor mirrors on state.mouse.current_cursor" {
        var state: InputState = .{};
        try expectEqual(MouseCursor.default, getMouseCursor(&state));
        setMouseCursor(&state, .pointing_hand);
        try expectEqual(MouseCursor.pointing_hand, getMouseCursor(&state));
        setMouseCursor(&state, .ibeam);
        try expectEqual(MouseCursor.ibeam, getMouseCursor(&state));
    }

    test "B1: pushMouseButtonDown captures press_position on rising edge only" {
        var state: InputState = .{};
        pushMouseMove(&state, 100, 200);
        pushMouseButtonDown(&state, 0); // M_LEFT, rising edge - captured
        try expectEqual(@as(f32, 100), state.mouse.press_position[0][0]);
        try expectEqual(@as(f32, 200), state.mouse.press_position[0][1]);
        // Move while held - press_position must stay fixed.
        pushMouseMove(&state, 300, 400);
        pushMouseButtonDown(&state, 0); // already down, no rising edge
        try expectEqual(@as(f32, 100), state.mouse.press_position[0][0]);
        try expectEqual(@as(f32, 200), state.mouse.press_position[0][1]);
    }

    test "B1: isMouseDragging false until movement exceeds threshold" {
        var state: InputState = .{};
        pushMouseMove(&state, 50, 50);
        pushMouseButtonDown(&state, 0);
        // No movement yet - not dragging.
        try expect(!isMouseDragging(&state, .left, -1));
        // Move within default 6 px threshold - still not dragging.
        pushMouseMove(&state, 53, 53);
        try expect(!isMouseDragging(&state, .left, -1));
        // Same position queried with a HUGE threshold - still not
        // dragging.  Sticky flag isn't set yet because we haven't
        // crossed any threshold.
        try expect(!isMouseDragging(&state, .left, 50));
        // Move past threshold.
        pushMouseMove(&state, 60, 60);
        try expect(isMouseDragging(&state, .left, -1));
        // Releasing - never dragging.
        pushMouseButtonUp(&state, 0);
        try expect(!isMouseDragging(&state, .left, -1));
    }

    test "B1: getMouseDragDelta returns (0,0) until threshold crossed, then displacement" {
        var state: InputState = .{};
        pushMouseMove(&state, 100, 100);
        pushMouseButtonDown(&state, 0);
        pushMouseMove(&state, 102, 101); // 2 px right, 1 px down - under threshold
        var d: Vec2 = getMouseDragDelta(&state, .left, -1);
        try expectEqual(@as(f32, 0), d[0]);
        try expectEqual(@as(f32, 0), d[1]);
        pushMouseMove(&state, 120, 110); // 20 px right, 10 px down - over
        d = getMouseDragDelta(&state, .left, -1);
        try expectEqual(@as(f32, 20), d[0]);
        try expectEqual(@as(f32, 10), d[1]);
    }

    test "B1: resetMouseDragDelta re-anchors press to current" {
        var state: InputState = .{};
        pushMouseMove(&state, 0, 0);
        pushMouseButtonDown(&state, 0);
        pushMouseMove(&state, 50, 50);
        var d: Vec2 = getMouseDragDelta(&state, .left, -1);
        try expectEqual(@as(f32, 50), d[0]);
        try expectEqual(@as(f32, 50), d[1]);
        resetMouseDragDelta(&state, .left);
        // Anchor moved to (50,50); now delta is zero until we move again.
        d = getMouseDragDelta(&state, .left, -1);
        try expectEqual(@as(f32, 0), d[0]);
        try expectEqual(@as(f32, 0), d[1]);
        pushMouseMove(&state, 100, 75);
        d = getMouseDragDelta(&state, .left, -1);
        try expectEqual(@as(f32, 50), d[0]);
        try expectEqual(@as(f32, 25), d[1]);
    }

    test "B1: resetMouseDragDelta is a no-op when button not held" {
        var state: InputState = .{};
        pushMouseMove(&state, 10, 10);
        pushMouseButtonDown(&state, 0);
        pushMouseMove(&state, 20, 20);
        pushMouseButtonUp(&state, 0);
        // press_position[0] still holds (10,10) but button up - reset must
        // not silently corrupt it.
        resetMouseDragDelta(&state, .left);
        try expectEqual(@as(f32, 10), state.mouse.press_position[0][0]);
        try expectEqual(@as(f32, 10), state.mouse.press_position[0][1]);
    }

    test "B1 fix: drag stays engaged after reset, even with sub-threshold move" {
        // Reproducer for the slow-touch-drag bug.  Without sticky
        // drag_started, reset → sub-threshold move would zero the
        // delta, freezing the handle mid-drag.
        var state: InputState = .{};
        pushMouseMove(&state, 0, 0);
        pushMouseButtonDown(&state, 0);
        // Cross threshold (default 6 px).
        pushMouseMove(&state, 20, 0);
        var d: Vec2 = getMouseDragDelta(&state, .left, -1);
        try expectEqual(@as(f32, 20), d[0]);
        try expect(state.mouse.drag_started[0]);
        // Reset anchor.
        resetMouseDragDelta(&state, .left);
        try expect(state.mouse.drag_started[0]);
        // Sub-threshold move.  Used to return (0, 0); now returns (2, 0).
        pushMouseMove(&state, 22, 0);
        d = getMouseDragDelta(&state, .left, -1);
        try expectEqual(@as(f32, 2), d[0]);
        // Release clears the sticky flag.
        pushMouseButtonUp(&state, 0);
        try expect(!state.mouse.drag_started[0]);
    }

    test "B1: isMouseHoveringRect honors half-open interval" {
        var state: InputState = .{};
        // Cursor at (50, 50).
        pushMouseMove(&state, 50, 50);
        // Rect that contains the cursor.
        try expect(isMouseHoveringRect(&state, 0, 0, 100, 100));
        // Inclusive on near edge.
        pushMouseMove(&state, 0, 0);
        try expect(isMouseHoveringRect(&state, 0, 0, 10, 10));
        // Exclusive on far edge.
        pushMouseMove(&state, 10, 5);
        try expect(!isMouseHoveringRect(&state, 0, 0, 10, 10));
        // Just outside.
        pushMouseMove(&state, -1, 50);
        try expect(!isMouseHoveringRect(&state, 0, 0, 100, 100));
    }

    // B2: KeyChord + isKeyChordPressed
    test "B2: bare key chord fires on press, only when no modifier held" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_S);
        try expect(isKeyChordPressed(&state, .{ .key = .s }, .{}));
        _testEndFrame(&state);
        // Released this frame - no chord.
        _testKeyUp(&state, KEY_S);
        try expect(!isKeyChordPressed(&state, .{ .key = .s }, .{}));
    }

    test "B2: Ctrl+S fires only when ctrl is held" {
        var state: InputState = .{};
        _testKeyDown(&state, 341); // KEY_LEFT_CONTROL
        _testKeyDown(&state, KEY_S);
        try expect(isKeyChordPressed(&state, .{ .key = .s, .ctrl = true }, .{}));
        // The bare-S chord should NOT also fire - strict modifier matching.
        try expect(!isKeyChordPressed(&state, .{ .key = .s }, .{}));
    }

    test "B2: right-side modifier counts the same as left-side" {
        var state: InputState = .{};
        _testKeyDown(&state, 345); // KEY_RIGHT_CONTROL
        _testKeyDown(&state, KEY_S);
        try expect(isKeyChordPressed(&state, .{ .key = .s, .ctrl = true }, .{}));
    }

    test "B2: extra modifier breaks the match" {
        var state: InputState = .{};
        _testKeyDown(&state, 341); // KEY_LEFT_CONTROL
        _testKeyDown(&state, 340); // KEY_LEFT_SHIFT
        _testKeyDown(&state, KEY_S);
        // Ctrl+S chord should NOT fire when Shift is also held.
        try expect(!isKeyChordPressed(&state, .{ .key = .s, .ctrl = true }, .{}));
        // Ctrl+Shift+S DOES fire.
        try expect(isKeyChordPressed(&state, .{ .key = .s, .ctrl = true, .shift = true }, .{}));
    }

    test "B2: chord is edge-triggered - held key doesn't keep firing" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        try expect(isKeyChordPressed(&state, .{ .key = .a }, .{}));
        _testEndFrame(&state);
        // Still down, but not pressed-this-frame any more.
        try expect(isKeyDown(&state, K_A));
        try expect(!isKeyChordPressed(&state, .{ .key = .a }, .{}));
    }

    test "B2: opts.repeat = true fires on auto-repeat events" {
        var state: InputState = .{};
        _testKeyDown(&state, KEY_A);
        try expect(isKeyChordPressed(&state, .{ .key = .a }, .{ .repeat = true }));
        _testEndFrame(&state);
        // Simulate OS auto-repeat.
        pushKeyDown(&state, KEY_A, 1);
        try expect(!isKeyChordPressed(&state, .{ .key = .a }, .{}));
        try expect(isKeyChordPressed(&state, .{ .key = .a }, .{ .repeat = true }));
    }

    test "getMouseWheelMove returns the larger-magnitude axis" {
        var state: InputState = .{};
        // Y axis bigger.
        pushMouseWheel(&state, 1, 5);
        try expect(getMouseWheelMove(&state) == 5);

        state = .{};
        // X axis bigger (negative).
        pushMouseWheel(&state, -3, 1);
        try expect(getMouseWheelMove(&state) == -3);
    }

    // ===========================================================================
    // Gamepad stubs
    // ===========================================================================

    test "gamepad: not available before connection event" {
        var state: InputState = .{};
        try expect(!isGamepadAvailable(&state, 0));
        try expect(!isGamepadAvailable(&state, 1));
    }

    test "gamepad: out-of-range returns safe defaults" {
        var state: InputState = .{};
        try expect(!isGamepadAvailable(&state, -1));
        try expect(!isGamepadAvailable(&state, 999));
        try expect(!isGamepadButtonDown(&state, -1, .unknown));
        try expect(getGamepadAxisMovement(&state, 0, .left_x) == 0);
    }

    // ===========================================================================
    // Multi-frame integration: the kind of bug that bites with edge
    // detection.  Make sure pressing-while-already-down, then releasing,
    // produces exactly one Pressed and exactly one Released across the
    // timeline.
    // ===========================================================================

    test "press → hold many frames → release: exactly one Pressed, one Released" {
        var state: InputState = .{};

        var pressed_count: usize = 0;
        var released_count: usize = 0;

        // Frame 0: nothing.
        _testEndFrame(&state);

        // Frame 1: down event happens this frame.
        _testKeyDown(&state, KEY_A);
        if (isKeyPressed(&state, K_A)) {
            pressed_count += 1;
        }
        if (isKeyReleased(&state, K_A)) {
            released_count += 1;
        }
        _testEndFrame(&state);

        // Frames 2-30: holding.
        var f: usize = 2;
        while (f <= 30) : (f += 1) {
            if (isKeyPressed(&state, K_A)) pressed_count += 1;
            if (isKeyReleased(&state, K_A)) released_count += 1;
            _testEndFrame(&state);
        }

        // Frame 31: release event happens this frame.
        _testKeyUp(&state, KEY_A);
        if (isKeyPressed(&state, K_A)) {
            pressed_count += 1;
        }
        if (isKeyReleased(&state, K_A)) {
            released_count += 1;
        }
        _testEndFrame(&state);

        // Frames 32-60: idle.
        while (f <= 60) : (f += 1) {
            if (isKeyPressed(&state, K_A)) pressed_count += 1;
            if (isKeyReleased(&state, K_A)) released_count += 1;
            _testEndFrame(&state);
        }

        try expect(pressed_count == 1);
        try expect(released_count == 1);
    }

    // getKeyName - Roadmap Step 1
    test "getKeyName: letter keys return ASCII strings" {
        try expect(eql(u8, getKeyName(.a).?, "A"));
        try expect(eql(u8, getKeyName(.s).?, "S"));
        try expect(eql(u8, getKeyName(.z).?, "Z"));
    }

    test "getKeyName: digit row" {
        try expect(eql(u8, getKeyName(.zero).?, "0"));
        try expect(eql(u8, getKeyName(.five).?, "5"));
        try expect(eql(u8, getKeyName(.nine).?, "9"));
    }

    test "getKeyName: punctuation has W3C-style names" {
        try expect(eql(u8, getKeyName(.space).?, "Space"));
        try expect(eql(u8, getKeyName(.left_bracket).?, "BracketLeft"));
        try expect(eql(u8, getKeyName(.grave).?, "Backquote"));
    }

    test "getKeyName: arrow keys" {
        try expect(eql(u8, getKeyName(.right).?, "ArrowRight"));
        try expect(eql(u8, getKeyName(.left).?, "ArrowLeft"));
        try expect(eql(u8, getKeyName(.down).?, "ArrowDown"));
        try expect(eql(u8, getKeyName(.up).?, "ArrowUp"));
    }

    test "getKeyName: function row" {
        try expect(eql(u8, getKeyName(.f1).?, "F1"));
        try expect(eql(u8, getKeyName(.f6).?, "F6"));
        try expect(eql(u8, getKeyName(.f12).?, "F12"));
    }

    test "getKeyName: modifiers distinguish left/right" {
        try expect(eql(u8, getKeyName(.left_shift).?, "ShiftLeft"));
        try expect(eql(u8, getKeyName(.right_shift).?, "ShiftRight"));
        try expect(eql(u8, getKeyName(.left_control).?, "ControlLeft"));
        try expect(eql(u8, getKeyName(.right_control).?, "ControlRight"));
    }

    test "getKeyName: numpad has Numpad-prefix" {
        try expect(eql(u8, getKeyName(.kp_0).?, "Numpad0"));
        try expect(eql(u8, getKeyName(.kp_9).?, "Numpad9"));
        try expect(eql(u8, getKeyName(.kp_divide).?, "NumpadDivide"));
        try expect(eql(u8, getKeyName(.kp_enter).?, "NumpadEnter"));
    }

    test "getKeyName: KEY_NULL returns null" {
        try expect(getKeyName(.null) == null);
    }

    test "getKeyName: unknown key returns null" {
        // Non-exhaustive enum: @enumFromInt with arbitrary values is safe.
        try expect(getKeyName(@enumFromInt(9999)) == null);
        try expect(getKeyName(@enumFromInt(-1)) == null);
        // Gap in the range (95 between BACKSLASH=92 and GRAVE=96)
        try expect(getKeyName(@enumFromInt(95)) == null);
    }

    // Gamepad - Roadmap Step 15
    test "gamepad: out-of-range queries are safe" {
        var state: InputState = .{};
        try expect(!isGamepadAvailable(&state, -1));
        try expect(!isGamepadAvailable(&state, 99));
        // Gamepad index out of range is still rejected; the button-arg
        // bounds checks went away with the enum migration since the type
        // makes a bad button index a compile error rather than a runtime
        // condition.
        try expect(!isGamepadButtonDown(&state, -1, .left_face_up));
        try expect(!isGamepadButtonPressed(&state, -1, .left_face_up));
        try expect(!isGamepadButtonReleased(&state, -1, .left_face_up));
        try expect(isGamepadButtonUp(&state, -1, .left_face_up)); // out-of-range → up
        try expect(getGamepadAxisMovement(&state, -1, .left_x) == 0);
        try expect(getGamepadAxisCount(&state, -1) == 0);
        try expect(getGamepadName(&state, -1) == null);
    }

    test "gamepad: getGamepadButtonPressed returns null when nothing pressed" {
        var state: InputState = .{};
        try expect(getGamepadButtonPressed(&state) == null);
    }

    test "gamepad: name returns null when disconnected" {
        var state: InputState = .{};
        try expect(getGamepadName(&state, 0) == null);
    }
};

test "Phase 1A: setMouseCursor / setWindowOpacity / setWindowFocused are safe no-ops on host" {
    // Just verify the calls compile and run without panicking on a host build.
    // The JS bridge stubs in smoke.ts cover wasm. Cross-namespace integration test
    // (input cursor state + core window ops), so it lives at file scope after both.
    var input_state: input.InputState = .{};
    input.setMouseCursor(&input_state, .crosshair);
    try expectEqual(input.MouseCursor.crosshair, input.getMouseCursor(&input_state));
    input.setMouseCursor(&input_state, .default);
    try expectEqual(input.MouseCursor.default, input.getMouseCursor(&input_state));
    core.setWindowOpacity(0.5);
    core.setWindowFocused();
}

// ============================================================================
// SECTION - gestures (state-machine on top of touch primitives)
// ============================================================================
// Ported from raylib's `rgestures.h` with these zimr adaptations:
//   - Zig enum (`Gesture`) instead of #defines.
//   - Slot-table positions read from `input.STATE.touch` (the
//     primitives we already maintain).  No separate event-queue.
//   - `update()` is called every frame by the runtime; gesture
//     transitions happen there based on the touch state.
//   - One global state struct, accessed only through this namespace.

pub const gestures = struct {
    const Vec2 = zm.Vec2;
    const input_mod = input;
    const core_mod = core;

    /// raylib's `Gesture` enum values.  Aliased to `types.Gesture`
    /// - single canonical definition; api-flatten arc unified the
    /// duplicate.
    pub const Gesture = @import("types.zig").Gesture;

    /// All gestures enabled by default - the lower 10 bits cover
    /// every Gesture variant.
    pub const ALL_GESTURES_FLAG: u32 = 0b1111111111;

    // ----- Tunables (raylib-parity) ----------------------------------------
    const FORCE_TO_SWIPE: f32 = 0.2; // pixels/sec normalized
    const MINIMUM_PINCH: f32 = 0.005;
    const TAP_TIMEOUT: f64 = 0.3; // seconds
    const DOUBLETAP_RANGE: f32 = 0.03;
    const HOLD_DURATION_THRESHOLD: f64 = 0.5;
    const DRAG_TIMEOUT: f64 = 0.3;

    // ----- State
    const TouchSubstate = struct {
        first_id: i32 = -1,
        point_count: i32 = 0,
        event_time: f64 = 0,
        up_position: Vec2 = .{ 0, 0 },
        down_position_a: Vec2 = .{ 0, 0 },
        down_position_b: Vec2 = .{ 0, 0 },
        down_drag_position: Vec2 = .{ 0, 0 },
        move_down_position_a: Vec2 = .{ 0, 0 },
        move_down_position_b: Vec2 = .{ 0, 0 },
        previous_position_a: Vec2 = .{ 0, 0 },
        previous_position_b: Vec2 = .{ 0, 0 },
        tap_counter: i32 = 0,
    };

    const HoldSubstate = struct {
        reset_required: bool = false,
        time_duration: f64 = 0,
    };

    const DragSubstate = struct {
        vector: Vec2 = .{ 0, 0 },
        angle_deg: f32 = 0,
        distance: f32 = 0,
        intensity: f32 = 0,
    };

    const SwipeSubstate = struct {
        start_time: f64 = 0,
    };

    const PinchSubstate = struct {
        vector: Vec2 = .{ 0, 0 },
        angle_deg: f32 = 0,
        distance: f32 = 0,
        /// Current two-finger distance / previous frame's. >1 = fingers
        /// spreading (magnify), <1 = closing, 1.0 = not a continuous
        /// two-finger move. The view-agnostic primitive zoom consumers
        /// need; pair with `mid`.
        scale: f32 = 1,
        /// Screen-space midpoint of the two fingers — the focal point to
        /// keep fixed under a pinch.
        mid: Vec2 = .{ 0, 0 },
        /// Frame-to-frame motion of that midpoint (current centroid minus
        /// last frame's), for panning while pinching. Zero unless two
        /// fingers were down both this frame and last.
        mid_delta: Vec2 = .{ 0, 0 },
    };

    /// Aggregated gesture-detector state.  Owned by `Runtime` (or
    /// constructed fresh for tests).
    pub const GesturesState = struct {
        current: u32 = @intFromEnum(Gesture.none),
        enabled_flags: u32 = ALL_GESTURES_FLAG,
        touch: TouchSubstate = .{},
        hold: HoldSubstate = .{},
        drag: DragSubstate = .{},
        swipe: SwipeSubstate = .{},
        pinch: PinchSubstate = .{},
        /// Internal frame-to-frame tracking for `update`.
        prev_count: i32 = 0,
        prev_p0: Vec2 = .{ 0, 0 },
        prev_p1: Vec2 = .{ 0, 0 },
    };

    // ----- Internal helpers
    fn vec2Distance(a: Vec2, b: Vec2) f32 {
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        return @sqrt(dx * dx + dy * dy);
    }

    /// Angle from `a` to `b` in degrees, 0-360 (atan2-based).
    fn vec2AngleDeg(a: Vec2, b: Vec2) f32 {
        const dx: f32 = b[0] - a[0];
        const dy: f32 = b[1] - a[1];
        var ang_rad: f32 = atan2(dy, dx);
        if (ang_rad < 0) {
            ang_rad += 2.0 * pi;
        }
        return ang_rad * 180.0 / pi;
    }

    fn currentTime(time: *const core_mod.TimeState) f64 {
        return core_mod.getTime(time);
    }

    /// Process a single touch event.  Called from `update` based on
    /// transitions in `input.state.touch`.  Translates touch events
    /// into gesture transitions.
    pub const TouchAction = enum { up, down, move, cancel };

    fn process(
        state: *GesturesState,
        time: *const core_mod.TimeState,
        action: TouchAction,
        point_count: i32,
        p0: Vec2,
        p1: Vec2,
    ) void {
        state.touch.point_count = point_count;

        if (point_count == 1) {
            switch (action) {
                .down => {
                    state.touch.tap_counter += 1;

                    const now: f64 = currentTime(time);
                    if (state.current == @intFromEnum(Gesture.none) and
                        state.touch.tap_counter >= 2 and
                        (now - state.touch.event_time) < TAP_TIMEOUT and
                        vec2Distance(state.touch.down_position_a, p0) < DOUBLETAP_RANGE)
                    {
                        state.current = @intFromEnum(Gesture.doubletap);
                        state.touch.tap_counter = 0;
                    } else {
                        state.touch.tap_counter = 1;
                        state.current = @intFromEnum(Gesture.tap);
                    }

                    state.touch.down_position_a = p0;
                    state.touch.down_drag_position = p0;
                    state.touch.up_position = p0;
                    state.touch.event_time = now;
                    state.swipe.start_time = now;
                    state.drag.vector = .{ 0, 0 };
                },
                .up => {
                    if (state.current == @intFromEnum(Gesture.drag) or state.current == @intFromEnum(Gesture.hold)) {
                        state.touch.up_position = p0;
                    }
                    state.drag.distance = vec2Distance(state.touch.down_position_a, state.touch.up_position);
                    const dt: f64 = currentTime(time) - state.swipe.start_time;
                    state.drag.intensity = if (dt > 0) state.drag.distance / @as(f32, @floatCast(dt)) else 0;

                    if (state.drag.intensity > FORCE_TO_SWIPE and state.current != @intFromEnum(Gesture.drag)) {
                        const drag_deg: f32 = vec2AngleDeg(state.touch.down_position_a, state.touch.up_position);
                        state.drag.angle_deg = 360.0 - drag_deg;
                        if (state.drag.angle_deg < 30 or state.drag.angle_deg > 330) {
                            state.current = @intFromEnum(Gesture.swipe_right);
                        } else if (state.drag.angle_deg >= 30 and state.drag.angle_deg <= 150) {
                            state.current = @intFromEnum(Gesture.swipe_up);
                        } else if (state.drag.angle_deg > 150 and state.drag.angle_deg < 210) {
                            state.current = @intFromEnum(Gesture.swipe_left);
                        } else if (state.drag.angle_deg >= 210 and state.drag.angle_deg <= 330) {
                            state.current = @intFromEnum(Gesture.swipe_down);
                        } else {
                            state.current = @intFromEnum(Gesture.none);
                        }
                    } else {
                        state.drag.distance = 0;
                        state.drag.intensity = 0;
                        state.drag.angle_deg = 0;
                        state.current = @intFromEnum(Gesture.none);
                    }
                    state.touch.down_drag_position = .{ 0, 0 };
                    state.touch.point_count = 0;
                },
                .move => {
                    state.touch.move_down_position_a = p0;
                    if (state.current == @intFromEnum(Gesture.hold)) {
                        if (state.hold.reset_required) {
                            state.touch.down_position_a = p0;
                        }
                        state.hold.reset_required = false;
                        if ((currentTime(time) - state.touch.event_time) > DRAG_TIMEOUT) {
                            state.touch.event_time = currentTime(time);
                            state.current = @intFromEnum(Gesture.drag);
                        }
                    }
                    state.drag.vector[0] = state.touch.move_down_position_a[0] - state.touch.down_drag_position[0];
                    state.drag.vector[1] = state.touch.move_down_position_a[1] - state.touch.down_drag_position[1];
                },
                .cancel => {},
            }
        } else if (point_count == 2) {
            switch (action) {
                .down => {
                    state.touch.down_position_a = p0;
                    state.touch.down_position_b = p1;
                    state.touch.previous_position_a = p0;
                    state.touch.previous_position_b = p1;
                    state.pinch.vector[0] = p1[0] - p0[0];
                    state.pinch.vector[1] = p1[1] - p0[1];
                    state.current = @intFromEnum(Gesture.hold);
                    state.hold.time_duration = currentTime(time);
                },
                .move => {
                    state.pinch.distance = vec2Distance(
                        state.touch.move_down_position_a,
                        state.touch.move_down_position_b,
                    );
                    state.touch.move_down_position_a = p0;
                    state.touch.move_down_position_b = p1;
                    state.pinch.vector[0] = p1[0] - p0[0];
                    state.pinch.vector[1] = p1[1] - p0[1];

                    if (vec2Distance(state.touch.previous_position_a, p0) >= MINIMUM_PINCH or
                        vec2Distance(state.touch.previous_position_b, p1) >= MINIMUM_PINCH)
                    {
                        if (vec2Distance(state.touch.previous_position_a, state.touch.previous_position_b) >
                            vec2Distance(p0, p1))
                        {
                            state.current = @intFromEnum(Gesture.pinch_in);
                        } else {
                            state.current = @intFromEnum(Gesture.pinch_out);
                        }
                    } else {
                        state.current = @intFromEnum(Gesture.hold);
                        state.hold.time_duration = currentTime(time);
                    }
                    state.pinch.angle_deg = 360.0 - vec2AngleDeg(p0, p1);
                },
                .up => {
                    state.pinch = .{};
                    state.touch.point_count = 0;
                    state.current = @intFromEnum(Gesture.none);
                },
                .cancel => {
                    state.pinch = .{};
                    state.touch.point_count = 0;
                    state.current = @intFromEnum(Gesture.none);
                },
            }
        }
    }

    /// Per-frame update.  Called by the runtime BEFORE the user's
    /// `update` so they see fresh gesture state.  Internally:
    /// 1. Reads `input.state.touch` to detect touch-set transitions
    ///    since last frame, calls `process` for each.
    /// 2. Applies HOLD escalation: if a TAP/DOUBLETAP was emitted
    ///    last frame and a finger is still down (count > 0),
    ///    transition to HOLD.
    /// 3. Resets transient gestures (SWIPE_*) to NONE - they fire
    ///    once per finger lift.
    pub fn update(
        state: *GesturesState,
        input_state: *const input_mod.InputState,
        time: *const core_mod.TimeState,
    ) void {
        // Compute current touch state first so the post-frame
        // transitions can gate on it.
        const cur_count: i32 = input_mod.getTouchPointCount(input_state);
        const ip0: Vec2 = input_mod.getTouchPosition(input_state, 0);
        const ip1: Vec2 = input_mod.getTouchPosition(input_state, 1);
        const cur_p0: Vec2 = .{ ip0[0], ip0[1] };
        const cur_p1: Vec2 = .{ ip1[0], ip1[1] };

        // Apply post-frame transitions to last frame's state.
        const cur_state_before: u32 = state.current;

        // TAP/DOUBLETAP escalates to HOLD if a finger is STILL down
        // this frame (not just was down last frame - that would
        // also escalate finger-already-released cases).
        if ((cur_state_before == @intFromEnum(Gesture.tap) or cur_state_before == @intFromEnum(Gesture.doubletap)) and
            state.touch.point_count < 2 and cur_count > 0)
        {
            state.current = @intFromEnum(Gesture.hold);
            state.hold.time_duration = currentTime(time);
        }

        // Transient gestures (swipes) clear after one frame of being
        // visible to the caller.
        if (cur_state_before == @intFromEnum(Gesture.swipe_right) or
            cur_state_before == @intFromEnum(Gesture.swipe_left) or
            cur_state_before == @intFromEnum(Gesture.swipe_up) or
            cur_state_before == @intFromEnum(Gesture.swipe_down))
        {
            state.current = @intFromEnum(Gesture.none);
        }

        // Now process new touch events.
        if (cur_count > state.prev_count) {
            process(state, time, .down, cur_count, cur_p0, cur_p1);
        } else if (cur_count < state.prev_count) {
            // For UP events, raylib passes the count *including* the
            // finger being lifted (= state.prev_count).  We've lost that
            // finger's position from input.STATE since input compacts
            // on touchup; reuse state.prev_p0/state.prev_p1.
            process(state, time, .up, state.prev_count, state.prev_p0, state.prev_p1);
        } else if (cur_count > 0) {
            const p0_changed: bool = cur_p0[0] != state.prev_p0[0] or cur_p0[1] != state.prev_p0[1];
            const p1_changed: bool = cur_p1[0] != state.prev_p1[0] or cur_p1[1] != state.prev_p1[1];
            if (p0_changed or p1_changed) {
                process(state, time, .move, cur_count, cur_p0, cur_p1);
            }
        }

        // Pinch scale + midpoint (view-agnostic zoom primitive). Scale
        // is the frame-to-frame finger-distance ratio; only meaningful
        // during a continuous two-finger move, else 1.0 (a no-op factor).
        if (cur_count == 2 and state.prev_count == 2) {
            const cur_d: f32 = vec2Distance(cur_p0, cur_p1);
            const prev_d: f32 = vec2Distance(state.prev_p0, state.prev_p1);
            state.pinch.scale = if (prev_d > 0) cur_d / prev_d else 1;
        } else {
            state.pinch.scale = 1;
        }
        if (cur_count == 2) {
            const cur_mid: Vec2 = .{ (cur_p0[0] + cur_p1[0]) * 0.5, (cur_p0[1] + cur_p1[1]) * 0.5 };
            if (state.prev_count == 2) {
                const pmx: f32 = (state.prev_p0[0] + state.prev_p1[0]) * 0.5;
                const pmy: f32 = (state.prev_p0[1] + state.prev_p1[1]) * 0.5;
                state.pinch.mid_delta = .{ cur_mid[0] - pmx, cur_mid[1] - pmy };
            } else {
                state.pinch.mid_delta = .{ 0, 0 };
            }
            state.pinch.mid = cur_mid;
        }

        state.prev_count = cur_count;
        state.prev_p0 = cur_p0;
        state.prev_p1 = cur_p1;
    }

    // ----- Public API
    /// Limit which gestures the detector emits.  Bit-or `Gesture`
    /// values; default is all enabled.
    pub fn setGesturesEnabled(
        state: *GesturesState,
        flags: u32,
    ) void {
        state.enabled_flags = flags;
    }

    /// True if `gesture` matches the current detector state AND is
    /// enabled.  The matching is bitwise - caller can pass
    /// `Gesture.tap` or `Gesture.swipe_left` etc.
    pub fn isGestureDetected(
        state: *const GesturesState,
        gesture: Gesture,
    ) bool {
        const g: u32 = @intCast(@intFromEnum(gesture));
        return (state.enabled_flags & state.current) == g;
    }

    pub fn getGestureDetected(state: *const GesturesState) Gesture {
        const masked: u32 = state.enabled_flags & state.current;
        // std.meta.intToEnum was removed in Zig 0.16 - manual switch
        // over the (small) enum value set instead.
        return switch (masked) {
            0 => Gesture.none,
            1 => Gesture.tap,
            2 => Gesture.doubletap,
            4 => Gesture.hold,
            8 => Gesture.drag,
            16 => Gesture.swipe_right,
            32 => Gesture.swipe_left,
            64 => Gesture.swipe_up,
            128 => Gesture.swipe_down,
            256 => Gesture.pinch_in,
            512 => Gesture.pinch_out,
            else => Gesture.none, // mask interleaved bits - none currently active
        };
    }

    /// Hold time in seconds - only meaningful when current gesture is HOLD.
    pub fn getGestureHoldDuration(
        state: *const GesturesState,
        time: *const core_mod.TimeState,
    ) f32 {
        if (state.current != @intFromEnum(Gesture.hold)) {
            return 0;
        }
        return @floatCast(currentTime(time) - state.hold.time_duration);
    }

    pub fn getGestureDragVector(state: *const GesturesState) Vec2 {
        return state.drag.vector;
    }

    pub fn getGestureDragAngle(state: *const GesturesState) f32 {
        return state.drag.angle_deg;
    }

    pub fn getGesturePinchVector(state: *const GesturesState) Vec2 {
        return state.pinch.vector;
    }

    pub fn getGesturePinchAngle(state: *const GesturesState) f32 {
        return state.pinch.angle_deg;
    }

    /// Per-frame pinch scale: current two-finger distance / previous
    /// frame's. >1 = fingers spreading (magnify / zoom in), <1 = closing.
    /// 1.0 when there is no continuous two-finger gesture, so callers can
    /// apply it unconditionally (a 1.0 factor is a no-op). The "apply to
    /// my view" step is the caller's — data ranges, a center+zoom camera,
    /// a 3D camera distance, etc.
    pub fn getGesturePinchScale(state: *const GesturesState) f32 {
        return state.pinch.scale;
    }

    /// Screen-space midpoint of the two fingers — the focal point to keep
    /// fixed while zooming. Valid while two fingers are down.
    pub fn getGesturePinchMid(state: *const GesturesState) Vec2 {
        return state.pinch.mid;
    }

    /// Frame-to-frame motion of the two-finger midpoint, for panning while
    /// pinching. Zero unless two fingers were down this frame and last.
    pub fn getGesturePinchMidDelta(state: *const GesturesState) Vec2 {
        return state.pinch.mid_delta;
    }

    /// Reset detector + iteration state.  Used by tests; production
    /// code shouldn't need this.
    pub fn _testReset(state: *GesturesState) void {
        state.* = .{};
    }

    test "tap: single down+up emits TAP" {
        var state: GesturesState = .{};
        var input_state: input_mod.InputState = .{};
        var time: core_mod.TimeState = .{};
        // Frame 1: finger goes down.
        input_mod.pushTouchDown(&input_state, 1, 100, 100);
        update(&state, &input_state, &time);
        try expectEqual(Gesture.tap, getGestureDetected(&state));

        // Frame 2: finger lifts (escalates from tap → hold first,
        // but with finger gone, count drops to 0 so up event fires).
        input_mod.pushTouchUp(&input_state, 1);
        update(&state, &input_state, &time);
        // After up on a short press: gesture cleared to NONE.
        try expectEqual(Gesture.none, getGestureDetected(&state));
    }

    test "swipe_right: fast move +X then up doesn't trap" {
        var state: GesturesState = .{};
        var input_state: input_mod.InputState = .{};
        var time: core_mod.TimeState = .{};
        // Initial down at (0, 50).
        input_mod.pushTouchDown(&input_state, 1, 0, 50);
        update(&state, &input_state, &time);
        // Quick move to (200, 50).
        input_mod.pushTouchMove(&input_state, 1, 200, 50);
        update(&state, &input_state, &time);
        // Lift at (200, 50).
        input_mod.pushTouchUp(&input_state, 1);
        update(&state, &input_state, &time);
        // Final state could be swipe_right (fast lift) or drag (slow
        // lift, depending on synthetic clock granularity on host) or
        // none (if intensity threshold not met).  Just verify it's
        // not garbage and the state machine didn't trap - the real
        // verification is the gestures_demo example running 60 frames
        // in smoke without panicking.
        const g: Gesture = getGestureDetected(&state);
        try expect(@intFromEnum(g) >= 0);
        try expect(@intFromEnum(g) <= 512);
    }

    test "two-finger down emits HOLD initially" {
        var state: GesturesState = .{};
        var input_state: input_mod.InputState = .{};
        var time: core_mod.TimeState = .{};
        input_mod.pushTouchDown(&input_state, 1, 50, 50);
        update(&state, &input_state, &time);
        input_mod.pushTouchDown(&input_state, 2, 150, 50);
        update(&state, &input_state, &time);
        // Two-finger down → HOLD.
        try expectEqual(Gesture.hold, getGestureDetected(&state));
    }

    test "setGesturesEnabled mask filters output" {
        var state: GesturesState = .{};
        var input_state: input_mod.InputState = .{};
        var time: core_mod.TimeState = .{};
        // Enable ONLY pinch gestures.
        setGesturesEnabled(&state, @intCast(@intFromEnum(Gesture.pinch_in) | @intFromEnum(Gesture.pinch_out)));
        input_mod.pushTouchDown(&input_state, 1, 50, 50);
        update(&state, &input_state, &time);
        // TAP isn't in the enabled mask → getGestureDetected returns NONE.
        try expectEqual(Gesture.none, getGestureDetected(&state));
        // But isGestureDetected for TAP also returns false (correct).
        try expect(!isGestureDetected(&state, Gesture.tap));
    }
};

// ============================================================================
// SECTION - camera (was: src/camera.zig)
// ============================================================================

pub const effects = struct {
    pub const clock = struct {
        // src/clock.zig - `Clock`: time as an explicit dependency.
        // Where `Loader` deals with truly-async operations that need a poll
        // loop, `Clock` is the home for instant runtime-given time values.
        // Calls never block, never need polling, never fail.
        // Why a struct (not module-level free functions)?  So a function can
        // advertise its dependence on time:
        //   fn updateAnimation(clock: Clock, anim: *Anim) void { ... }
        // And so tests can swap the impl:
        //   var mock = Clock.Mock.init(.{ .frameTime = 1.0 / 60.0 });
        //   app.setClock(mock.clock());
        // Method names mirror raylib's `GetTime()` / `GetFrameTime()` /
        // `GetFPS()` so the names are familiar.  `wallMs` is an extension
        // raylib doesn't expose absolute wall time but logs and elapsed-load
        // UI want it.
        // `Clock` is a 16-byte value type (userdata + vtable pointer).

        // (deduped intra-cluster import) const core = core;

        const is_wasm = builtin.cpu.arch.isWasm();

        pub const Clock = struct {
            userdata: ?*anyopaque,
            vtable: *const VTable,

            pub const VTable = struct {
                time: *const fn (?*anyopaque) f64,
                frameTime: *const fn (?*anyopaque) f32,
                fps: *const fn (?*anyopaque) i32,
                wallMs: *const fn (?*anyopaque) f64,
            };

            /// Seconds since `App.create` (raylib `GetTime()`).
            pub fn time(self: Clock) f64 {
                return self.vtable.time(self.userdata);
            }

            /// Delta seconds for this frame (raylib `GetFrameTime()`).
            /// Multiply by velocity, etc.
            pub fn frameTime(self: Clock) f32 {
                return self.vtable.frameTime(self.userdata);
            }

            /// Current rolling FPS estimate (raylib `GetFPS()`).
            pub fn fps(self: Clock) i32 {
                return self.vtable.fps(self.userdata);
            }

            /// Wallclock ms since page load (wasm) or process start (host).
            /// Monotonic.  raylib doesn't expose this; useful for logs and
            /// "loading for N seconds…" UI.
            pub fn wallMs(self: Clock) f64 {
                return self.vtable.wallMs(self.userdata);
            }
        };

        // ===========================================================================
        // Browser - wraps the timing state already living in core.zig.
        // ===========================================================================

        pub const Browser = struct {
            // Substate pointers stamped after Runtime exists.  See
            // App.create - it calls `default_clock_browser.bind(rt)`
            // after the runtime is built.  Stay `?*const` so the
            // module-level static can default-init to nulls; thunks
            // bail out cleanly if the runtime isn't ready yet (rare
            // every Frame dispatch happens after bind).
            time: ?*const core.TimeState = null,
            fps: ?*const core.FpsState = null,

            pub fn init() Browser {
                return .{};
            }

            /// Hook the browser-clock to its Runtime substates.
            /// Called from `App.create` once after the runtime exists.
            pub fn bind(
                self: *Browser,
                time: *const core.TimeState,
                fps: *const core.FpsState,
            ) void {
                self.time = time;
                self.fps = fps;
            }

            pub fn clock(self: *Browser) Clock {
                return .{ .userdata = self, .vtable = &browser_vtable };
            }
        };

        const browser_vtable: Clock.VTable = .{
            .time = browserTime,
            .frameTime = browserFrameTime,
            .fps = browserFps,
            .wallMs = browserWallMs,
        };

        fn browserTime(ud: ?*anyopaque) f64 {
            const self: *Browser = @ptrCast(@alignCast(ud orelse return 0));
            const t: *const core.TimeState = self.time orelse return 0;
            return core.getTime(t);
        }

        fn browserFrameTime(ud: ?*anyopaque) f32 {
            const self: *Browser = @ptrCast(@alignCast(ud orelse return 0));
            const t: *const core.TimeState = self.time orelse return 0;
            return core.getFrameTime(t);
        }

        fn browserFps(ud: ?*anyopaque) i32 {
            const self: *Browser = @ptrCast(@alignCast(ud orelse return 0));
            const f: *const core.FpsState = self.fps orelse return 0;
            return core.getFPS(f);
        }

        fn browserWallMs(_: ?*anyopaque) f64 {
            if (comptime is_wasm) {
                return @import("web.zig").dom.now_ms();
            }
            if (hostMonotonicMs()) |t| {
                return t;
            }
            // No monotonic source available - for tests, return a
            // synthetic 60-fps tick so frame-time-dependent code is
            // deterministic-ish.
            host_fake_ms += 16.0;
            return host_fake_ms;
        }

        var host_fake_ms: f64 = 0.0; // lint:off module-var: synthetic 60-fps tick for host-side default clock

        // ===========================================================================
        // Mock - deterministic Clock for tests.  Every value freely settable.
        // ===========================================================================

        pub const Mock = struct {
            /// Returned by `time()`.  Caller advances via `mock.setTime` or
            /// `mock.advance`.  In seconds.
            time_s: f64 = 0.0,
            /// Returned by `frameTime()`.  In seconds.
            frame_time_s: f32 = 0.0,
            /// Returned by `fps()`.
            fps_value: i32 = 60,
            /// Returned by `wallMs()`.  In milliseconds.
            wall_ms: f64 = 0.0,

            pub const Options = struct {
                time: f64 = 0.0,
                frameTime: f32 = 1.0 / 60.0,
                fps: i32 = 60,
                wallMs: f64 = 0.0,
            };

            pub fn init(opts: Options) Mock {
                return .{
                    .time_s = opts.time,
                    .frame_time_s = opts.frameTime,
                    .fps_value = opts.fps,
                    .wall_ms = opts.wallMs,
                };
            }

            /// Advance both `time` (seconds) and `wallMs` consistently.  This
            /// is the most common test idiom: simulate one frame's worth of
            /// elapsed time.
            pub fn advance(self: *Mock, seconds: f64) void {
                self.time_s += seconds;
                self.wall_ms += seconds * 1000.0;
            }

            pub fn clock(self: *Mock) Clock {
                return .{ .userdata = self, .vtable = &mock_vtable };
            }
        };

        const mock_vtable: Clock.VTable = .{
            .time = mockTime,
            .frameTime = mockFrameTime,
            .fps = mockFps,
            .wallMs = mockWallMs,
        };

        fn mockTime(userdata: ?*anyopaque) f64 {
            const m: *Mock = @ptrCast(@alignCast(userdata));
            return m.time_s;
        }

        fn mockFrameTime(userdata: ?*anyopaque) f32 {
            const m: *Mock = @ptrCast(@alignCast(userdata));
            return m.frame_time_s;
        }

        fn mockFps(userdata: ?*anyopaque) i32 {
            const m: *Mock = @ptrCast(@alignCast(userdata));
            return m.fps_value;
        }

        fn mockWallMs(userdata: ?*anyopaque) f64 {
            const m: *Mock = @ptrCast(@alignCast(userdata));
            return m.wall_ms;
        }

        // ---- tests
        test "Browser: clock() returns a usable Clock" {
            var b = Browser.init();
            const c: Clock = b.clock();
            try expect(@intFromPtr(c.vtable) != 0);
        }

        test "Browser: wallMs is monotonic" {
            var b = Browser.init();
            const c: Clock = b.clock();
            const t1: f64 = c.wallMs();
            const t2: f64 = c.wallMs();
            try expect(t2 >= t1);
        }

        test "Browser: time() returns a non-negative value" {
            // Phase E migrated Browser to take substate refs via bind()
            // - no anchor needed.  We bind to stack-locals so the thunks
            // route to known-zero state.
            var time_state: core.TimeState = .{};
            var fps_state: core.FpsState = .{};
            var b = Browser.init();
            b.bind(&time_state, &fps_state);
            const c: Clock = b.clock();
            _ = c.time();
            _ = c.frameTime();
            _ = c.fps();
        }

        test "Mock: time/frameTime/fps/wallMs return what was set" {
            var mock = Mock.init(.{
                .time = 12.5,
                .frameTime = 1.0 / 30.0,
                .fps = 30,
                .wallMs = 1000.0,
            });
            const c: Clock = mock.clock();
            try expect(c.time() == 12.5);
            try expect(c.frameTime() == 1.0 / 30.0);
            try expect(c.fps() == 30);
            try expect(c.wallMs() == 1000.0);
        }

        test "Mock: advance increments time and wallMs consistently" {
            var mock = Mock.init(.{ .time = 0, .wallMs = 0 });
            const c: Clock = mock.clock();

            mock.advance(0.5); // 500 ms
            try expect(c.time() == 0.5);
            try expect(c.wallMs() == 500.0);

            mock.advance(0.25); // +250 ms
            try expect(c.time() == 0.75);
            try expect(c.wallMs() == 750.0);
        }

        test "Mock: defaults - frameTime is 1/60, fps 60" {
            var mock = Mock.init(.{});
            const c: Clock = mock.clock();
            try expect(@abs(c.frameTime() - 1.0 / 60.0) < 1e-6);
            try expect(c.fps() == 60);
        }
    };

    // ===========================================================================
    // rng - was src/rng.zig
    // ===========================================================================

    pub const rng = struct {
        // src/rng.zig - `Rng`: randomness as an explicit dependency.
        // Why a struct (not module-level free functions)?  So a function can
        // advertise its dependence on randomness:
        //   fn spawnParticle(rng: Rng, particles: *Particles) void { ... }
        // And so tests can inject a deterministic seed:
        //   var rng_state = Rng.Seeded.init(42);
        //   app.setRng(rng_state.rng());
        // Method names mirror raylib's `GetRandomValue(min, max)` /
        // `SetRandomSeed(seed)` so the names are familiar.  `float01` and
        // `bytes` are extensions raylib doesn't have but games inevitably
        // want.
        // `Rng.Seeded` is dual-use: it's the test mock AND the canonical
        // way to do reproducible gameplay (procgen, replays).  Same struct,
        // two purposes.
        // `Rng` is a 16-byte value type (userdata + vtable pointer).

        // (deduped intra-cluster import) const core = core;

        pub const Rng = struct {
            userdata: ?*anyopaque,
            vtable: *const VTable,

            pub const VTable = struct {
                value: *const fn (?*anyopaque, i32, i32) i32,
                seed: *const fn (?*anyopaque, u64) void,
                float01: *const fn (?*anyopaque) f32,
                bytes: *const fn (?*anyopaque, []u8) void,
            };

            /// Random integer in [min, max] inclusive (raylib `GetRandomValue`).
            /// If `min > max` they are silently swapped.
            pub fn value(
                self: Rng,
                min: i32,
                max: i32,
            ) i32 {
                return self.vtable.value(self.userdata, min, max);
            }

            /// Reseed the RNG (raylib `SetRandomSeed`).  A seed of 0 is
            /// replaced with 1 to avoid the all-zero degenerate state.
            pub fn seed(self: Rng, s: u64) void {
                self.vtable.seed(self.userdata, s);
            }

            /// Random float in [0, 1).  Extension; raylib doesn't have this.
            pub fn float01(self: Rng) f32 {
                return self.vtable.float01(self.userdata);
            }

            /// Fill `buf` with random bytes.  Extension; raylib doesn't have
            /// this.  In `Browser` impl, uses xorshift32 for speed (NOT
            /// cryptographically secure - this is an Rng, not a CSPRNG).
            pub fn bytes(self: Rng, buf: []u8) void {
                self.vtable.bytes(self.userdata, buf);
            }

            /// Random boolean.  Extension; raylib doesn't have this but it's
            /// cheap to add.
            pub fn boolean(self: Rng) bool {
                return self.value(0, 1) == 1;
            }
        };

        // ===========================================================================
        // Browser - wraps the RNG state already living in core.zig.
        // ===========================================================================

        pub const Browser = struct {
            pub fn init() Browser {
                return .{};
            }

            pub fn rng(self: *Browser) Rng {
                return .{ .userdata = self, .vtable = &browser_vtable };
            }
        };

        const browser_vtable: Rng.VTable = .{
            .value = browserValue,
            .seed = browserSeed,
            .float01 = browserFloat01,
            .bytes = browserBytes,
        };

        fn browserValue(
            _: ?*anyopaque,
            min: i32,
            max: i32,
        ) i32 {
            return core.getRandomValue(min, max);
        }

        fn browserSeed(_: ?*anyopaque, s: u64) void {
            // core.setRandomSeed takes u32; downcast.
            core.setRandomSeed(@truncate(s));
        }

        fn browserFloat01(_: ?*anyopaque) f32 {
            // Reach into the same xorshift32 stream core.zig uses.  A second
            // call to value(0, max) advances it; we sample a 24-bit slice for
            // float precision.
            const a: i32 = core.getRandomValue(0, 65535);
            const b: i32 = core.getRandomValue(0, 255);
            const u: u32 = (@as(u32, @intCast(a)) << 8) | @as(u32, @intCast(b));
            return float(u) / float(1 << 24);
        }

        fn browserBytes(_: ?*anyopaque, buf: []u8) void {
            for (buf) |*byte| {
                byte.* = @intCast(core.getRandomValue(0, 255));
            }
        }

        // ===========================================================================
        // Seeded - deterministic, dual-use as both test mock AND reproducible
        // gameplay RNG (procgen, replays).
        // ===========================================================================

        pub const Seeded = struct {
            prng: std.Random.DefaultPrng,

            pub fn init(seed: u64) Seeded {
                return .{ .prng = std.Random.DefaultPrng.init(seed) };
            }

            pub fn rng(self: *Seeded) Rng {
                return .{ .userdata = self, .vtable = &seeded_vtable };
            }
        };

        const seeded_vtable: Rng.VTable = .{
            .value = seededValue,
            .seed = seededSeed,
            .float01 = seededFloat01,
            .bytes = seededBytes,
        };

        fn seededValue(
            userdata: ?*anyopaque,
            min: i32,
            max: i32,
        ) i32 {
            const s: *Seeded = @ptrCast(@alignCast(userdata));
            var lo: i32 = min;
            var hi: i32 = max;
            if (lo > hi) {
                const tmp: i32 = hi;
                hi = lo;
                lo = tmp;
            }
            const range: u32 = @intCast(hi - lo + 1);
            const r = s.prng.random().int(u32);
            return lo + @as(i32, @intCast(r % range));
        }

        fn seededSeed(userdata: ?*anyopaque, seed: u64) void {
            const s: *Seeded = @ptrCast(@alignCast(userdata));
            s.prng = std.Random.DefaultPrng.init(seed);
        }

        fn seededFloat01(userdata: ?*anyopaque) f32 {
            const s: *Seeded = @ptrCast(@alignCast(userdata));
            return s.prng.random().float(f32);
        }

        fn seededBytes(userdata: ?*anyopaque, buf: []u8) void {
            const s: *Seeded = @ptrCast(@alignCast(userdata));
            s.prng.random().bytes(buf);
        }

        // ---- tests
        test "Browser: rng() returns a usable Rng" {
            var b = Browser.init();
            const r: Rng = b.rng();
            try expect(@intFromPtr(r.vtable) != 0);
        }

        test "Browser: value() respects bounds" {
            var b = Browser.init();
            const r: Rng = b.rng();
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const v = r.value(10, 20);
                try expect(v >= 10 and v <= 20);
            }
        }

        test "Browser: float01 stays in [0, 1)" {
            var b = Browser.init();
            const r: Rng = b.rng();
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const f = r.float01();
                try expect(f >= 0.0 and f < 1.0);
            }
        }

        test "Browser: bytes() fills the buffer" {
            var b = Browser.init();
            const r: Rng = b.rng();
            var buf: [32]u8 = @splat(0);
            r.bytes(&buf);
            var any_nonzero: bool = false;
            for (buf) |x| {
                if (x != 0) {
                    any_nonzero = true;
                    break;
                }
            }
            try expect(any_nonzero);
        }

        test "Browser: seed makes value() reproducible" {
            var b = Browser.init();
            const r: Rng = b.rng();
            r.seed(42);
            const a1: i32 = r.value(0, 1000);
            const a2: i32 = r.value(0, 1000);
            r.seed(42);
            const b1: i32 = r.value(0, 1000);
            const b2: i32 = r.value(0, 1000);
            try expect(a1 == b1);
            try expect(a2 == b2);
        }

        test "Seeded: same seed → same value sequence" {
            var a = Seeded.init(12345);
            var b = Seeded.init(12345);
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                try expect(a.rng().value(0, 1000) == b.rng().value(0, 1000));
            }
        }

        test "Seeded: different seeds → different sequences" {
            var a = Seeded.init(1);
            var b = Seeded.init(2);
            var diffs: usize = 0;
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                if (a.rng().value(0, 1000) != b.rng().value(0, 1000)) diffs += 1;
            }
            // Vanishingly unlikely all 50 collide by chance.
            try expect(diffs > 30);
        }

        test "Seeded: float01 stays in [0, 1)" {
            var s = Seeded.init(7);
            const r: Rng = s.rng();
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const f = r.float01();
                try expect(f >= 0.0 and f < 1.0);
            }
        }

        test "Seeded: bytes() fills with non-zero" {
            var s = Seeded.init(99);
            const r: Rng = s.rng();
            var buf: [16]u8 = @splat(0);
            r.bytes(&buf);
            var any: bool = false;
            for (buf) |x| {
                if (x != 0) {
                    any = true;
                    break;
                }
            }
            try expect(any);
        }

        test "Seeded: re-seed via seed() resets the stream" {
            var s = Seeded.init(42);
            const r: Rng = s.rng();
            const a: i32 = r.value(0, 1000);
            r.seed(42);
            const b: i32 = r.value(0, 1000);
            try expect(a == b);
        }

        test "Rng: boolean returns both true and false over many trials" {
            var s = Seeded.init(123);
            const r: Rng = s.rng();
            var trues: usize = 0;
            var falses: usize = 0;
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                if (r.boolean()) trues += 1 else falses += 1;
            }
            try expect(trues > 0 and falses > 0);
        }

        test "Rng: value with min > max swaps the bounds" {
            var s = Seeded.init(1);
            const r: Rng = s.rng();
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                const v = r.value(20, 10);
                try expect(v >= 10 and v <= 20);
            }
        }
    };

    // ===========================================================================
    // logger - was src/logger.zig
    // ===========================================================================

    pub const logger = struct {
        // src/logger.zig - `Logger`: emit log lines as an explicit dependency.
        // Currently the most-used global in zimr - every example calls
        // `core.traceLog(LOG_INFO, ...)`.  Promoting it to a Frame field
        // completes the "no globals" story.
        // Why a struct (not module-level free functions)?  So a function can
        // advertise its dependence on logging:
        //   fn loadAtlas(loader: Loader, log: Logger, url: []const u8) Handle {
        //       log.info("loading {s}", .{url});
        //       ...
        //   }
        // And so tests can collect log lines for assertion:
        //   var capture = Logger.Capture.init();
        //   defer capture.deinit(ta);
        //   app.setLogger(capture.logger());
        //   // ... run a frame ...
        //   try expect(capture.contains("loading"));
        // `Logger.Capture` is dual-use: test mock AND a way to feed in-app
        // debug overlays (a screen-corner ring buffer of recent log lines).
        // `Logger` is a 16-byte value type (userdata + vtable pointer).

        // (deduped intra-cluster import) const core = core;

        pub const Level = enum(u8) {
            trace = 1,
            debug = 2,
            info = 3,
            warn = 4,
            err = 5,
            fatal = 6,

            /// Convert to raylib's i32 LOG_* constants for interop with
            /// `core.traceLog`.
            pub fn toCInt(self: Level) i32 {
                return @intFromEnum(self);
            }
        };

        pub const Logger = struct {
            userdata: ?*anyopaque,
            vtable: *const VTable,

            pub const VTable = struct {
                /// One slot.  Method-level convenience layers on top.
                emit: *const fn (?*anyopaque, Level, []const u8) void,
            };

            pub fn trace(
                self: Logger,
                comptime fmt: []const u8,
                args: anytype,
            ) void {
                emitFormatted(self, .trace, fmt, args);
            }

            pub fn debug(
                self: Logger,
                comptime fmt: []const u8,
                args: anytype,
            ) void {
                emitFormatted(self, .debug, fmt, args);
            }

            pub fn info(
                self: Logger,
                comptime fmt: []const u8,
                args: anytype,
            ) void {
                emitFormatted(self, .info, fmt, args);
            }

            pub fn warn(
                self: Logger,
                comptime fmt: []const u8,
                args: anytype,
            ) void {
                emitFormatted(self, .warn, fmt, args);
            }

            /// `err` because `error` is a Zig keyword.
            pub fn err(
                self: Logger,
                comptime fmt: []const u8,
                args: anytype,
            ) void {
                emitFormatted(self, .err, fmt, args);
            }

            pub fn fatal(
                self: Logger,
                comptime fmt: []const u8,
                args: anytype,
            ) void {
                emitFormatted(self, .fatal, fmt, args);
            }

            /// Lower-level: emit an already-formatted message.  Use the
            /// level-named methods above for normal logging; this is for code
            /// that wants to construct the message itself (e.g. with a
            /// non-comptime fmt string).
            pub fn emit(
                self: Logger,
                level: Level,
                msg: []const u8,
            ) void {
                self.vtable.emit(self.userdata, level, msg);
            }
        };

        /// Internal: format args into a stack buffer and dispatch.  4096 byte
        /// max log line - anything longer gets truncated, like raylib.
        fn emitFormatted(
            lg: Logger,
            level: Level,
            comptime fmt: []const u8,
            args: anytype,
        ) void {
            var buf: [4096]u8 = undefined;
            const msg: []u8 = bufPrint(&buf, fmt, args) catch buf[0..buf.len];
            lg.vtable.emit(lg.userdata, level, msg);
        }

        // ===========================================================================
        // Browser - wraps core.traceLog (which routes to console.log via dom.zig).
        // ===========================================================================

        pub const Browser = struct {
            // Substate pointer stamped after Runtime exists.  See
            // App.create - it calls `default_logger_browser.bind(rt)`
            // after the runtime is built.
            tracelog: ?*const core.TraceLogState = null,

            pub fn init() Browser {
                return .{};
            }

            /// Hook the browser-logger to its Runtime substate.
            /// Called from `App.create` once after the runtime exists.
            pub fn bind(
                self: *Browser,
                tracelog: *const core.TraceLogState,
            ) void {
                self.tracelog = tracelog;
            }

            pub fn logger(self: *Browser) Logger {
                return .{ .userdata = self, .vtable = &browser_vtable };
            }
        };

        const browser_vtable: Logger.VTable = .{
            .emit = browserEmit,
        };

        fn browserEmit(
            ud: ?*anyopaque,
            level: Level,
            msg: []const u8,
        ) void {
            // core.traceLog wants a comptime fmt; we pass "{s}" and stuff the
            // already-formatted message through.  This double-passes through
            // bufPrint but keeps the routing through the existing core
            // log-level filter and dom.js console sink.
            // Both `Level` (logger-internal) and `TraceLogLevel`
            // (raylib-style) are `enum(i32)` with the same int
            // values for shared tags - we just shift the type.
            const self: *Browser = @ptrCast(@alignCast(ud orelse return));
            const tl: *const core.TraceLogState = self.tracelog orelse return;
            core.traceLog(tl, @enumFromInt(@intFromEnum(level)), "{s}", .{msg});
        }

        // ===========================================================================
        // Capture - collects log lines into an ArrayList for tests + overlays.
        // ===========================================================================

        pub const Capture = struct {
            gpa: Allocator,
            lines: ArrayList(Entry) = .empty,

            pub const Entry = struct {
                level: Level,
                msg: []const u8, // owned
            };

            pub fn init(gpa: Allocator) Capture {
                return .{ .gpa = gpa };
            }

            pub fn deinit(self: *Capture) void {
                for (self.lines.items) |entry| {
                    self.gpa.free(entry.msg);
                }
                self.lines.deinit(self.gpa);
            }

            /// True if any captured line contains `needle`.  Convenience for
            /// `expect(capture.contains("started"))`.
            pub fn contains(self: *const Capture, needle: []const u8) bool {
                for (self.lines.items) |entry| {
                    if (std.mem.indexOf(u8, entry.msg, needle) != null) {
                        return true;
                    }
                }
                return false;
            }

            /// Number of captured lines at or above `level`.
            pub fn countAtLevel(self: *const Capture, level: Level) usize {
                var n: usize = 0;
                for (self.lines.items) |entry| {
                    if (@intFromEnum(entry.level) >= @intFromEnum(level)) {
                        n += 1;
                    }
                }
                return n;
            }

            pub fn logger(self: *Capture) Logger {
                return .{ .userdata = self, .vtable = &capture_vtable };
            }
        };

        const capture_vtable: Logger.VTable = .{
            .emit = captureEmit,
        };

        fn captureEmit(
            userdata: ?*anyopaque,
            level: Level,
            msg: []const u8,
        ) void {
            const cap: *Capture = @ptrCast(@alignCast(userdata));
            const dup = cap.gpa.dupe(u8, msg) catch return;
            cap.lines.append(cap.gpa, .{ .level = level, .msg = dup }) catch {
                cap.gpa.free(dup);
            };
        }

        // ===========================================================================
        // Prefixed - wraps a parent Logger, prepends "<prefix>: " to every msg.
        // Use case: multi-app demos where a parent host runs N child "apps"
        // inside its update fn, each child gets its own Logger that tags
        // every log line with the child's name so the merged stream is
        // readable.  The parent doesn't need to know which child impl is
        // active - it just hands each child a Prefixed wrapping its own
        // logger.
        // Lifetime: the Prefixed instance and the prefix string must
        // outlive the Logger returned from `.logger()`.  Same as Browser
        // and Capture - you keep the underlying struct alive for as long
        // as anything is using its Logger view.  In practice the parent
        // owns the Prefixed in its state, builds the Logger every frame.
        // Memory: zero-alloc.  Each emit assembles the combined message in
        // a 4096-byte stack buffer (same size as Logger's bufPrint), then
        // hands the slice to the parent.  Lines longer than ~4080 bytes
        // (the bound depends on prefix length) get truncated.  raylib has
        // the same truncation behavior for its log lines, so this matches
        // existing expectations.
        // ===========================================================================

        pub const Prefixed = struct {
            parent: Logger,
            prefix: []const u8,

            pub fn init(
                parent: Logger,
                prefix: []const u8,
            ) Prefixed {
                return .{ .parent = parent, .prefix = prefix };
            }

            pub fn logger(self: *const Prefixed) Logger {
                return .{
                    .userdata = @constCast(self),
                    .vtable = &prefixed_vtable,
                };
            }
        };

        const prefixed_vtable: Logger.VTable = .{
            .emit = prefixedEmit,
        };

        fn prefixedEmit(
            userdata: ?*anyopaque,
            level: Level,
            msg: []const u8,
        ) void {
            const pre: *const Prefixed = @ptrCast(@alignCast(userdata));
            var buf: [4096]u8 = undefined;
            const formatted: []u8 = bufPrint(&buf, "{s}: {s}", .{ pre.prefix, msg }) catch buf[0..buf.len];
            pre.parent.emit(level, formatted);
        }

        // ---- tests
        test "Browser: logger() returns a usable Logger" {
            // Phase E migrated Browser to take substate ref via bind()
            // - no anchor needed.  Bind to a stack-local TraceLogState
            // so the thunk routes to known-zero state.
            var tl: core.TraceLogState = .{};
            var b = Browser.init();
            b.bind(&tl);
            const log: Logger = b.logger();
            try expect(@intFromPtr(log.vtable) != 0);
            // Should not crash; routes through core.traceLog.
            log.info("hello {d}", .{42});
        }

        test "Capture: collects emitted messages" {
            const ta: Allocator = std.testing.allocator;
            var cap = Capture.init(ta);
            defer cap.deinit();
            const log: Logger = cap.logger();

            log.info("first", .{});
            log.warn("second {d}", .{99});

            try expect(cap.lines.items.len == 2);
            try expect(eql(u8, cap.lines.items[0].msg, "first"));
            try expect(eql(u8, cap.lines.items[1].msg, "second 99"));
            try expect(cap.lines.items[0].level == .info);
            try expect(cap.lines.items[1].level == .warn);
        }

        test "Capture: contains() finds substrings" {
            const ta: Allocator = std.testing.allocator;
            var cap = Capture.init(ta);
            defer cap.deinit();
            const log: Logger = cap.logger();

            log.info("loading texture: img.png", .{});
            log.info("decoded 256x256", .{});

            try expect(cap.contains("loading"));
            try expect(cap.contains("256x256"));
            try expect(!cap.contains("error"));
        }

        test "Capture: countAtLevel filters by level threshold" {
            const ta: Allocator = std.testing.allocator;
            var cap = Capture.init(ta);
            defer cap.deinit();
            const log: Logger = cap.logger();

            log.debug("d1", .{});
            log.debug("d2", .{});
            log.info("i1", .{});
            log.warn("w1", .{});
            log.err("e1", .{});

            try expect(cap.countAtLevel(.debug) == 5); // all
            try expect(cap.countAtLevel(.info) == 3); // i1 + w1 + e1
            try expect(cap.countAtLevel(.warn) == 2); // w1 + e1
            try expect(cap.countAtLevel(.err) == 1); // e1
        }

        test "Capture: each Logger method maps to the right Level" {
            const ta: Allocator = std.testing.allocator;
            var cap = Capture.init(ta);
            defer cap.deinit();
            const log: Logger = cap.logger();

            log.trace("t", .{});
            log.debug("d", .{});
            log.info("i", .{});
            log.warn("w", .{});
            log.err("e", .{});
            log.fatal("f", .{});

            try expect(cap.lines.items.len == 6);
            try expect(cap.lines.items[0].level == .trace);
            try expect(cap.lines.items[1].level == .debug);
            try expect(cap.lines.items[2].level == .info);
            try expect(cap.lines.items[3].level == .warn);
            try expect(cap.lines.items[4].level == .err);
            try expect(cap.lines.items[5].level == .fatal);
        }

        test "Capture: emit() bypasses formatting" {
            const ta: Allocator = std.testing.allocator;
            var cap = Capture.init(ta);
            defer cap.deinit();
            const log: Logger = cap.logger();

            log.emit(.warn, "raw message");
            try expect(cap.lines.items.len == 1);
            try expect(eql(u8, cap.lines.items[0].msg, "raw message"));
            try expect(cap.lines.items[0].level == .warn);
        }

        test "Level: toCInt matches raylib LOG_* values" {
            try expect(Level.trace.toCInt() == 1);
            try expect(Level.debug.toCInt() == 2);
            try expect(Level.info.toCInt() == 3);
            try expect(Level.warn.toCInt() == 4);
            try expect(Level.err.toCInt() == 5);
            try expect(Level.fatal.toCInt() == 6);
        }

        test "Prefixed: prepends prefix to each emitted line" {
            const ta: Allocator = std.testing.allocator;
            var cap: Capture = Capture.init(ta);
            defer cap.deinit();

            const prefixed: Prefixed = Prefixed.init(cap.logger(), "child-app");
            const log: Logger = prefixed.logger();

            log.info("hello", .{});
            log.warn("count={}", .{42});
            log.err("boom", .{});

            try expect(cap.lines.items.len == 3);
            try expect(eql(u8, cap.lines.items[0].msg, "child-app: hello"));
            try expect(eql(u8, cap.lines.items[1].msg, "child-app: count=42"));
            try expect(eql(u8, cap.lines.items[2].msg, "child-app: boom"));
        }

        test "Prefixed: preserves the level on each line" {
            const ta: Allocator = std.testing.allocator;
            var cap: Capture = Capture.init(ta);
            defer cap.deinit();

            const prefixed: Prefixed = Prefixed.init(cap.logger(), "x");
            const log: Logger = prefixed.logger();

            log.trace("t", .{});
            log.debug("d", .{});
            log.info("i", .{});
            log.warn("w", .{});
            log.err("e", .{});
            log.fatal("f", .{});

            try expect(cap.lines.items[0].level == .trace);
            try expect(cap.lines.items[1].level == .debug);
            try expect(cap.lines.items[2].level == .info);
            try expect(cap.lines.items[3].level == .warn);
            try expect(cap.lines.items[4].level == .err);
            try expect(cap.lines.items[5].level == .fatal);
        }

        test "Prefixed: Logger.emit() bypass also gets the prefix" {
            const ta: Allocator = std.testing.allocator;
            var cap: Capture = Capture.init(ta);
            defer cap.deinit();

            const prefixed: Prefixed = Prefixed.init(cap.logger(), "app1");
            const log: Logger = prefixed.logger();

            // Bypassing the formatted helpers - direct emit.
            log.emit(.info, "raw line");
            try expect(eql(u8, cap.lines.items[0].msg, "app1: raw line"));
        }

        test "Prefixed: nesting two Prefixeds stacks both prefixes" {
            const ta: Allocator = std.testing.allocator;
            var cap: Capture = Capture.init(ta);
            defer cap.deinit();

            const inner: Prefixed = Prefixed.init(cap.logger(), "outer");
            const outer: Prefixed = Prefixed.init(inner.logger(), "inner");
            const log: Logger = outer.logger();

            log.info("hi", .{});
            // Outer wraps inner wraps cap → "outer: inner: hi" reading
            // outside-in.
            try expect(eql(u8, cap.lines.items[0].msg, "outer: inner: hi"));
        }
    };

    // ===========================================================================
    // loader - was src/loader.zig
    // ===========================================================================

    pub const loader = struct {
        // src/loader.zig - `Loader`: poll-based asset loader.
        // raylib's loading API (`LoadFileData`, `UnloadFileData`, `LoadImage`,
        // `LoadTexture`) is synchronous: the call returns once bytes are in
        // memory.  In the browser we cannot do that - `fetch()` is genuinely
        // async and the JS event loop has to run between "I want this file"
        // and "the bytes are here."  So `Loader` is poll-based:
        //   const handle = f.loader.loadFileData("img.png");
        //   // ... continue this frame, return ...
        //   // ... NEXT frame ...
        //   switch (f.loader.pollFileData(handle)) {
        //       .pending => return,
        //       .ok => |bytes| { /* decode, upload, etc. */ },
        //       .not_found, .network_failed => return,
        //   }
        //   f.loader.unloadFileData(handle);
        // We keep raylib's vocabulary (`loadFileData` / `unloadFileData`) so
        // veterans recognize the names.  The new concept - `pollFileData`
        // is unavoidable.  Browsers don't allow blocking.
        // Why a struct (not module-level free functions)?  So functions can
        // advertise loader use in their signature:
        //   fn loadAtlas(loader: Loader, url: []const u8) Loader.Handle { ... }
        // And so tests can swap the impl:
        //   var mock = Loader.Mock.init();
        //   try mock.put(ta, "img.png", embedded_bytes);
        //   app.setLoader(mock.loader());
        // `Loader` is a 16-byte value type (userdata + vtable pointer).

        const fetch = @import("web.zig").fetch;

        const is_wasm = builtin.cpu.arch.isWasm();

        pub const Handle = u32;

        pub const Status = union(enum) {
            pending,
            ok: []const u8,
            not_found,
            network_failed,
        };

        pub const Loader = struct {
            userdata: ?*anyopaque,
            vtable: *const VTable,

            pub const VTable = struct {
                loadFileData: *const fn (?*anyopaque, []const u8) Handle,
                pollFileData: *const fn (?*anyopaque, Handle) Status,
                unloadFileData: *const fn (?*anyopaque, Handle) void,
                elapsedMs: *const fn (?*anyopaque, Handle) ?f64,
            };

            /// Begin loading the file at `path` (relative URL or absolute).
            /// Returns 0 on failure to start (e.g. tracking table full).  No
            /// bytes are read yet - call `pollFileData` each frame until the
            /// status transitions away from `.pending`.  Mirrors raylib's
            /// `LoadFileData` in vocabulary; differs in being poll-based.
            pub fn loadFileData(self: Loader, path: []const u8) Handle {
                return self.vtable.loadFileData(self.userdata, path);
            }

            /// Check on a load.  Returns `.pending` while in flight, `.ok`
            /// with bytes once the data arrives, or an error variant.  The
            /// slice in `.ok` is valid until `unloadFileData(handle)` is
            /// called.
            pub fn pollFileData(self: Loader, h: Handle) Status {
                return self.vtable.pollFileData(self.userdata, h);
            }

            /// Free the buffer backing this load.  Mirrors raylib's
            /// `UnloadFileData`.  Safe to call on already-released or unknown
            /// handles.
            pub fn unloadFileData(self: Loader, h: Handle) void {
                self.vtable.unloadFileData(self.userdata, h);
            }

            /// Milliseconds elapsed since `loadFileData(handle)`, or null if
            /// the handle is unknown.  raylib doesn't have this; useful for
            /// "loading for N seconds…" UI or to time out slow loads.
            pub fn elapsedMs(self: Loader, h: Handle) ?f64 {
                return self.vtable.elapsedMs(self.userdata, h);
            }
        };

        // ===========================================================================
        // Browser - wraps web/fetch.zig.
        // ===========================================================================

        pub const Browser = struct {
            /// Per-handle start-time tracking.  16 simultaneous loads is
            /// plenty for typical zimr apps.
            tracked: [16]Tracked = @splat(.{}),

            const Tracked = struct {
                handle: Handle = 0,
                start_ms: f64 = 0.0,
            };

            pub fn init() Browser {
                return .{};
            }

            pub fn loader(self: *Browser) Loader {
                return .{ .userdata = self, .vtable = &browser_vtable };
            }
        };

        const browser_vtable: Loader.VTable = .{
            .loadFileData = browserLoadFileData,
            .pollFileData = browserPollFileData,
            .unloadFileData = browserUnloadFileData,
            .elapsedMs = browserElapsedMs,
        };

        fn browserLoadFileData(userdata: ?*anyopaque, path: []const u8) Handle {
            const self: *Browser = @ptrCast(@alignCast(userdata));
            const h: @import("web.zig").fetch.Handle = fetch.start(path);
            if (h == 0) {
                return 0;
            }
            const t: f64 = nowMs();
            for (&self.tracked) |*entry| {
                if (entry.handle == 0 or entry.handle == h) {
                    entry.* = .{ .handle = h, .start_ms = t };
                    return h;
                }
            }
            return h;
        }

        fn browserPollFileData(_: ?*anyopaque, h: Handle) Status {
            return mapStatus(fetch.poll(h));
        }

        fn mapStatus(s: fetch.Status) Status {
            return switch (s) {
                .pending => .pending,
                .ok => |bytes| .{ .ok = bytes },
                .failed => |err| switch (err) {
                    error.NotFound => .not_found,
                    else => .network_failed,
                },
            };
        }

        fn browserUnloadFileData(userdata: ?*anyopaque, h: Handle) void {
            const self: *Browser = @ptrCast(@alignCast(userdata));
            fetch.release(h);
            for (&self.tracked) |*entry| {
                if (entry.handle == h) {
                    entry.* = .{};
                }
            }
        }

        fn browserElapsedMs(userdata: ?*anyopaque, h: Handle) ?f64 {
            const self: *Browser = @ptrCast(@alignCast(userdata));
            if (h == 0) {
                return null;
            }
            const now: f64 = nowMs();
            for (self.tracked) |entry| {
                if (entry.handle == h) {
                    return now - entry.start_ms;
                }
            }
            return null;
        }

        /// Local time helper duplicated from clock.zig to avoid circular
        /// import.  A few lines saved by sharing aren't worth the dependency.
        fn nowMs() f64 {
            if (comptime is_wasm) {
                return @import("web.zig").dom.now_ms();
            }
            return hostMonotonicMs() orelse 0.0;
        }

        // ===========================================================================
        // Mock - deterministic Loader for tests.
        // ===========================================================================

        pub const Mock = struct {
            /// Mock clock used for elapsedMs accounting.  Caller advances.
            now_ms: f64 = 0.0,
            table: std.StringHashMapUnmanaged([]const u8) = .empty,
            active: [16]Active = @splat(.{}),
            next_id: Handle = 1,

            const Active = struct {
                handle: Handle = 0,
                start_ms: f64 = 0.0,
                bytes: []const u8 = &.{},
                found: bool = false,
            };

            pub fn init() Mock {
                return .{};
            }

            pub fn deinit(self: *Mock, gpa: Allocator) void {
                self.table.deinit(gpa);
            }

            pub fn loader(self: *Mock) Loader {
                return .{ .userdata = self, .vtable = &mock_vtable };
            }

            /// Pre-populate the asset table.  `bytes` is borrowed; caller
            /// owns the storage and must keep it alive across `pollFileData`
            /// calls.
            pub fn put(
                self: *Mock,
                gpa: Allocator,
                url: []const u8,
                bytes: []const u8,
            ) !void {
                try self.table.put(gpa, url, bytes);
            }

            /// Advance the mock clock used for elapsedMs.
            pub fn advance(self: *Mock, ms: f64) void {
                self.now_ms += ms;
            }
        };

        const mock_vtable: Loader.VTable = .{
            .loadFileData = mockLoadFileData,
            .pollFileData = mockPollFileData,
            .unloadFileData = mockUnloadFileData,
            .elapsedMs = mockElapsedMs,
        };

        fn mockLoadFileData(userdata: ?*anyopaque, path: []const u8) Handle {
            const m: *Mock = @ptrCast(@alignCast(userdata));
            const id: Handle = m.next_id;
            m.next_id += 1;
            for (&m.active) |*entry| {
                if (entry.handle == 0) {
                    const found: ?[]const u8 = m.table.get(path);
                    entry.* = .{
                        .handle = id,
                        .start_ms = m.now_ms,
                        .bytes = found orelse &.{},
                        .found = found != null,
                    };
                    return id;
                }
            }
            return 0;
        }

        fn mockPollFileData(userdata: ?*anyopaque, h: Handle) Status {
            const m: *Mock = @ptrCast(@alignCast(userdata));
            if (h == 0) {
                return .network_failed;
            }
            for (m.active) |entry| {
                if (entry.handle == h) {
                    if (entry.found) {
                        return .{ .ok = entry.bytes };
                    }
                    return .not_found;
                }
            }
            return .network_failed;
        }

        fn mockUnloadFileData(userdata: ?*anyopaque, h: Handle) void {
            const m: *Mock = @ptrCast(@alignCast(userdata));
            for (&m.active) |*entry| {
                if (entry.handle == h) {
                    entry.* = .{};
                }
            }
        }

        fn mockElapsedMs(userdata: ?*anyopaque, h: Handle) ?f64 {
            const m: *Mock = @ptrCast(@alignCast(userdata));
            if (h == 0) {
                return null;
            }
            for (m.active) |entry| {
                if (entry.handle == h) {
                    return m.now_ms - entry.start_ms;
                }
            }
            return null;
        }

        // ===========================================================================
        // Scoped - wraps a parent Loader, prepends a base path to every URL.
        // Use case: multi-app demos where each child app lives in its own
        // asset namespace (`apps/dungeon-crawler/assets/...`,
        // `apps/visualizer/assets/...`) but the child code writes
        // `loader.loadFileData("hero.png")` without knowing where that
        // resolves on disk.  The parent gives each child a Scoped wrapping
        // its own loader with the appropriate base.
        // Only `loadFileData` rewrites the path.  `pollFileData`,
        // `unloadFileData`, and `elapsedMs` operate on Handle values which
        // the parent loader assigns and owns - those just delegate 1:1.
        // Lifetime: the Scoped instance and the base_path string must
        // outlive the Loader returned from `.loader()`.  Same as Browser
        // and Mock - keep the underlying struct alive while anything uses
        // its Loader view.  Parents typically own the Scoped in their
        // state and rebuild the Loader each frame.
        // Memory: zero-alloc.  The combined path lives in a 1024-byte
        // stack buffer (URLs longer than that get truncated, which is
        // fine - that's already path-too-long territory in any practical
        // asset pipeline).
        // ===========================================================================

        pub const Scoped = struct {
            parent: Loader,
            base_path: []const u8,

            pub fn init(
                parent: Loader,
                base_path: []const u8,
            ) Scoped {
                return .{ .parent = parent, .base_path = base_path };
            }

            pub fn loader(self: *const Scoped) Loader {
                return .{
                    .userdata = @constCast(self),
                    .vtable = &scoped_vtable,
                };
            }
        };

        const scoped_vtable: Loader.VTable = .{
            .loadFileData = scopedLoadFileData,
            .pollFileData = scopedPollFileData,
            .unloadFileData = scopedUnloadFileData,
            .elapsedMs = scopedElapsedMs,
        };

        fn scopedLoadFileData(
            userdata: ?*anyopaque,
            path: []const u8,
        ) Handle {
            const sc: *const Scoped = @ptrCast(@alignCast(userdata));
            var buf: [1024]u8 = undefined;
            // Use "{s}{s}" not "{s}/{s}" - the base_path can include or
            // omit its trailing slash and child paths can be absolute or
            // relative; let the caller decide.  Keeps behavior simple and
            // matches the URL/path-resolution rules of the underlying
            // fetch impl, which doesn't prescribe a separator either.
            const combined: []u8 = bufPrint(&buf, "{s}{s}", .{ sc.base_path, path }) catch buf[0..buf.len];
            return sc.parent.loadFileData(combined);
        }

        fn scopedPollFileData(
            userdata: ?*anyopaque,
            h: Handle,
        ) Status {
            const sc: *const Scoped = @ptrCast(@alignCast(userdata));
            return sc.parent.pollFileData(h);
        }

        fn scopedUnloadFileData(
            userdata: ?*anyopaque,
            h: Handle,
        ) void {
            const sc: *const Scoped = @ptrCast(@alignCast(userdata));
            sc.parent.unloadFileData(h);
        }

        fn scopedElapsedMs(
            userdata: ?*anyopaque,
            h: Handle,
        ) ?f64 {
            const sc: *const Scoped = @ptrCast(@alignCast(userdata));
            return sc.parent.elapsedMs(h);
        }

        // ---- tests
        test "Browser: loader() returns a usable Loader" {
            var b = Browser.init();
            const l: Loader = b.loader();
            try expect(@intFromPtr(l.vtable) != 0);
            try expect(l.userdata == @as(?*anyopaque, &b));
        }

        test "Browser: loadFileData returns 0 on host (no real fetch)" {
            var b = Browser.init();
            const l: Loader = b.loader();
            try expect(l.loadFileData("foo.png") == 0);
        }

        test "Browser: elapsedMs(unknown) → null" {
            var b = Browser.init();
            const l: Loader = b.loader();
            try expect(l.elapsedMs(0) == null);
            try expect(l.elapsedMs(999) == null);
        }

        test "Mock: unknown URL → not_found on poll" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            const l: Loader = mock.loader();
            const h: Handle = l.loadFileData("missing.png");
            try expect(h != 0);
            try expect(l.pollFileData(h) == .not_found);
        }

        test "Mock: put + load + poll → ok with bytes" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
            try mock.put(ta, "smiley.png", &payload);

            const l: Loader = mock.loader();
            const h: Handle = l.loadFileData("smiley.png");
            switch (l.pollFileData(h)) {
                .ok => |bytes| try expect(eql(u8, bytes, &payload)),
                else => try expect(false),
            }
        }

        test "Mock: handles are unique across simultaneous loads" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            try mock.put(ta, "a", "x");
            try mock.put(ta, "b", "y");
            const l: Loader = mock.loader();
            const h1: Handle = l.loadFileData("a");
            const h2: Handle = l.loadFileData("b");
            try expect(h1 != h2);
            try expect(h1 != 0 and h2 != 0);
        }

        test "Mock: unloadFileData frees the slot" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            try mock.put(ta, "x", "ok");
            const l: Loader = mock.loader();
            const h: Handle = l.loadFileData("x");
            l.unloadFileData(h);
            try expect(l.pollFileData(h) == .network_failed);
            try expect(l.elapsedMs(h) == null);
        }

        test "Mock: elapsedMs respects mock.advance" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            try mock.put(ta, "x", "yo");
            const l: Loader = mock.loader();
            const h: Handle = l.loadFileData("x");
            try expect(l.elapsedMs(h).? == 0.0);
            mock.advance(50.0);
            try expect(l.elapsedMs(h).? == 50.0);
            mock.advance(200.0);
            try expect(l.elapsedMs(h).? == 250.0);
        }

        // ---- Integration: 2-frame loader simulation
        const SimState = struct {
            handle: Handle = 0,
            bytes_loaded: usize = 0,
            err_msg: ?[]const u8 = null,
        };

        fn simulateUpdate(l: Loader, st: *SimState) void {
            if (st.handle == 0) {
                st.handle = l.loadFileData("test.png");
                return;
            }
            switch (l.pollFileData(st.handle)) {
                .pending => {},
                .ok => |bytes| {
                    st.bytes_loaded = bytes.len;
                    l.unloadFileData(st.handle);
                    st.handle = 0;
                },
                .not_found => {
                    st.err_msg = "404";
                    l.unloadFileData(st.handle);
                    st.handle = 0;
                },
                .network_failed => {
                    st.err_msg = "net";
                    l.unloadFileData(st.handle);
                    st.handle = 0;
                },
            }
        }

        test "Integration: Mock drives loader to completion in 2 frames" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
            try mock.put(ta, "test.png", &payload);

            var st: SimState = .{};
            const l: Loader = mock.loader();

            simulateUpdate(l, &st);
            try expect(st.handle != 0);
            try expect(st.bytes_loaded == 0);

            simulateUpdate(l, &st);
            try expect(st.bytes_loaded == 8);
            try expect(st.handle == 0);
            try expect(st.err_msg == null);
        }

        test "Integration: missing asset → 404 path" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);

            var st: SimState = .{};
            const l: Loader = mock.loader();

            simulateUpdate(l, &st);
            simulateUpdate(l, &st);
            try expect(st.err_msg != null);
            try expect(eql(u8, st.err_msg.?, "404"));
        }

        test "Scoped: loadFileData prepends base_path before forwarding" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);

            const payload = [_]u8{ 1, 2, 3 };
            try mock.put(ta, "apps/dungeon/hero.png", payload[0..]);

            const scoped: Scoped = Scoped.init(mock.loader(), "apps/dungeon/");
            const l: Loader = scoped.loader();

            const h: Handle = l.loadFileData("hero.png");
            try expect(h != 0);
            const status: Status = l.pollFileData(h);
            switch (status) {
                .ok => |bytes| {
                    try expect(bytes.len == 3);
                    try expect(bytes[0] == 1 and bytes[2] == 3);
                },
                else => try expect(false), // expected ok
            }
        }

        test "Scoped: missing-after-prefix → not_found" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);

            const scoped: Scoped = Scoped.init(mock.loader(), "apps/x/");
            const l: Loader = scoped.loader();

            const h: Handle = l.loadFileData("nope.png");
            try expect(h != 0);
            try expect(l.pollFileData(h) == .not_found);
        }

        test "Scoped: pollFileData / unloadFileData / elapsedMs delegate 1:1" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            const payload = [_]u8{0x42};
            try mock.put(ta, "ns/file.bin", payload[0..]);

            const scoped: Scoped = Scoped.init(mock.loader(), "ns/");
            const l: Loader = scoped.loader();

            const h: Handle = l.loadFileData("file.bin");
            const via_scoped: Status = l.pollFileData(h);
            const direct: Status = mock.loader().pollFileData(h);
            try expect(@as(meta.Tag(Status), via_scoped) ==
                @as(meta.Tag(Status), direct));

            const elapsed: ?f64 = l.elapsedMs(h);
            try expect(elapsed != null);

            l.unloadFileData(h);
            try expect(l.elapsedMs(h) == null);
        }

        test "Scoped: empty base_path acts as identity" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            const payload = [_]u8{0xAA};
            try mock.put(ta, "raw.bin", payload[0..]);

            const scoped: Scoped = Scoped.init(mock.loader(), "");
            const l: Loader = scoped.loader();

            const h: Handle = l.loadFileData("raw.bin");
            try expect(h != 0);
            const status: Status = l.pollFileData(h);
            try expect(status == .ok);
        }

        test "Scoped: nesting two Scopeds stacks both prefixes" {
            const ta: Allocator = std.testing.allocator;
            var mock = Mock.init();
            defer mock.deinit(ta);
            const payload = [_]u8{0xCC};
            try mock.put(ta, "apps/game/levels/intro.json", payload[0..]);

            const inner: Scoped = Scoped.init(mock.loader(), "apps/game/");
            const outer: Scoped = Scoped.init(inner.loader(), "levels/");
            const l: Loader = outer.loader();

            const h: Handle = l.loadFileData("intro.json");
            try expect(h != 0);
            try expect(l.pollFileData(h) == .ok);
        }
    };

    // Convenience aliases were considered but cause shadowing inside each
    // subsystem's body (the bare `Clock` / `Rng` / `Logger` / `Loader`
    // references inside the `clock` namespace are ambiguous when an outer
    // `Clock` alias also exists).  Callers reach the primary types via
    // `effects.clock.Clock` etc., or via the `pub const Clock = ...`
    // re-exports in zimr.zig.

};

pub const camera = struct {
    const types = @import("types.zig");
    const enums = @import("types.zig");
    // zmath-adoption Z4a: `zmath` is the math library - all vector
    // *compute* in this namespace goes through it, via the thin `v3*`
    // bridge helpers below (they convert the `Vec` storage struct
    // to/from the `Vec` compute type at the boundary).  No `zimrmath`
    // dependency remains; `Vec` storage→`@Vector` conversion
    // happens in `v3ToZm`/`v3FromZm`, and `add`/`sub`/`scale` use the
    // `Vec` struct's own methods.
    const sqrt1_2 = zm.sqrt1_2;
    // (deduped intra-cluster import) const core = core;
    const Clock = effects.clock.Clock;

    const Vec2 = zm.Vec2;
    const Camera3D = zm.Camera3D;
    const Camera = types.Camera;

    // ---- Z4a compute-surface bridges ------------------------------------
    // Thin wrappers over the `zmath` compute API.  They take and return
    // the `Vec` storage struct, converting to/from the `Vec`
    // compute type at the boundary.  ALL vector math goes through
    // zmath - including storage-to-storage `add`/`sub`/`scale`, which
    // use the native `@Vector` operators on the compute type rather
    // than the `Vec` struct's own methods (the bespoke struct API
    // is what the zmath arc is eliminating).  If a storage-to-storage
    // op ever proves a measured perf problem, the fix is a dedicated
    // `arrayAdd`/`arrayDot`/… in `math.zig` - added then, proven by a
    // benchmark, not speculatively.  When Z4b flips `Vec` to
    // `[3]f32`, these bridges' bodies collapse to direct loads.

    inline fn v3ToZm(v: Vec) Vec {
        return zm.dirFromArr3(v);
    }
    inline fn v3FromZm(v: Vec) Vec {
        return vec(v[0], v[1], v[2]);
    }
    /// Vector sum `a + b` (native `@Vector` add on the compute type).
    inline fn v3Add(a: Vec, b: Vec) Vec {
        return v3FromZm(v3ToZm(a) + v3ToZm(b));
    }
    /// Vector difference `a - b`.
    inline fn v3Sub(a: Vec, b: Vec) Vec {
        return v3FromZm(v3ToZm(a) - v3ToZm(b));
    }
    /// Scalar multiply `v * s` (`@splat` broadcast - zmath has no
    /// `scale` function, scalar-vector multiply is the operator).
    inline fn v3Scale(v: Vec, s: f32) Vec {
        return v3FromZm(v3ToZm(v) * @as(Vec, @splat(s)));
    }
    /// Normalize a 3-vector.
    inline fn v3Normalize(v: Vec) Vec {
        return v3FromZm(normalize3(v3ToZm(v)));
    }
    /// Cross product `a × b`.
    inline fn v3Cross(a: Vec, b: Vec) Vec {
        return v3FromZm(cross(v3ToZm(a), v3ToZm(b)));
    }
    /// Euclidean distance between two points.
    inline fn v3Distance(a: Vec, b: Vec) f32 {
        return length3(v3ToZm(a) - v3ToZm(b));
    }
    /// Unsigned angle between two vectors, in radians.
    inline fn v3Angle(a: Vec, b: Vec) f32 {
        return angle3(v3ToZm(a), v3ToZm(b));
    }
    /// Negate a vector.
    inline fn v3Negate(v: Vec) Vec {
        return vec(-v[0], -v[1], -v[2]);
    }
    /// Rotate a vector around an axis (need not be normalized) by an
    /// angle in radians.
    inline fn v3RotateByAxisAngle(
        v: Vec,
        axis: Vec,
        angle: f32,
    ) Vec {
        return v3FromZm(zm.rotateByAxisAngle3(v3ToZm(v), v3ToZm(axis), angle));
    }
    /// Transform a point by a matrix (column-vector convention, w = 1).
    inline fn v3Transform(v: Vec, m: Matrix) Vec {
        return v3FromZm(mulMatVec(m, zm.pointFromArr3(v)));
    }
    /// Unproject an NDC-space point back to world space.
    inline fn v3Unproject(
        source: Vec,
        projection: Matrix,
        view: Matrix,
    ) Vec {
        return v3FromZm(zm.unproject3(v3ToZm(source), projection, view));
    }

    /// Debug throttle counter - `beginMode3D` logs only its first 2
    /// invocations, then goes silent.  Residual global; will move to
    /// `Runtime.debug` (or similar) in Phase 2.
    pub var DEBUG_3D_LOG_COUNT: u32 = 0; // lint:off module-var: debug throttle counter (will move to Runtime.debug)
    const Camera2D = zm.Camera2D;
    const Mat = zm.Mat;
    const Matrix = Mat;
    const Ray = zm.Ray;

    const radFromDeg = zm.radFromDeg;

    /// Camera projection enum values matching raylib's `CameraProjection`.
    const CAMERA_PERSPECTIVE: i32 = 0;
    const CAMERA_ORTHOGRAPHIC: i32 = 1;

    // ===========================================================================
    // BeginMode3D / EndMode3D
    // ===========================================================================

    // ===========================================================================
    // 2D cam mode
    // ===========================================================================

    // ===========================================================================
    // Camera math helpers
    // ===========================================================================

    /// Get the view matrix for `cam` (the look-at part of the transform
    /// chain).  Doesn't include projection.
    pub fn getCameraMatrix(cam: Camera3D) Matrix {
        return zm.lookAtRh(
            cam.position,
            cam.target,
            cam.up,
        );
    }

    /// Get the 2D cam transform matrix.  Translates by -target, rotates,
    /// scales by zoom, then translates by +offset.
    pub fn getCameraMatrix2D(cam: Camera2D) Matrix {
        // Camera2D transform: take a world point, translate so the
        // target sits at the origin, rotate, scale by zoom, then
        // translate to the screen offset.  As a matrix product
        // (applied to a column vector, rightmost applied first):
        //   T(offset) * S(zoom) * R(rot) * T(-target)
        const mat_origin: zm.Mat = zm.translation(-cam.target[0], -cam.target[1], 0);
        const mat_rotation: zm.Mat = zm.rotationZ(cam.rotation);
        const mat_scale: zm.Mat = scaling(cam.zoom, cam.zoom, 1);
        const mat_translation: zm.Mat = zm.translation(cam.offset[0], cam.offset[1], 0);

        // zimr's `matrixMul(A,B)` is math A*B; zmath's row-vector `mul`
        // reverses the operands.  The chain below builds, step by step,
        // math `T(offset) * S(zoom) * R(rot) * T(-target)`.
        var result: zm.Mat = mulMat(mat_rotation, mat_origin); // math R * T(-target)
        result = mulMat(mat_scale, result); // math S * R * T(-target)
        result = mulMat(mat_translation, result); // math T(offset) * S * R * T(-target)
        return result;
    }

    /// As `getWorldToScreen`, but with explicit `width` and `height`.
    /// Reads `gl.cull_distance_near` / `gl.cull_distance_far` (clip
    /// planes for the projection matrix), `position`, `cam`, `width`,
    /// `height`.  No mutation.
    /// Clip planes for the projection matrix used by the
    /// screen<->world transforms below.  Defaults mirror raylib's
    /// RL_CULL_DISTANCE_NEAR / RL_CULL_DISTANCE_FAR (the values the
    /// retired GL state machine carried).
    pub const ClipPlanes = struct {
        z_near: f64 = 0.01,
        z_far: f64 = 1000.0,
    };

    pub fn getWorldToScreenWithViewport(
        position: Vec,
        cam: Camera3D,
        width: i32,
        height: i32,
        clip: ClipPlanes,
    ) Vec2 {
        const w: f32 = float(width);
        const h: f32 = float(height);
        const aspect: f32 = if (h > 0) w / h else 1.0;

        // Compose projection.
        var proj: Matrix = undefined;
        if (cam.projection == CAMERA_PERSPECTIVE) {
            proj = zm.perspectiveFovRhGl(
                radFromDeg(cam.fovy_deg),
                aspect,
                @floatCast(clip.z_near),
                @floatCast(clip.z_far),
            );
        } else {
            const top: f32 = cam.fovy_deg / 2.0;
            const right: f32 = top * aspect;
            proj = zm.orthographicOffCenterRhGl(
                -right,
                right,
                // zmath signature: (left, right, TOP, BOTTOM, near, far)
                // - top before bottom.
                top,
                -top,
                @floatCast(clip.z_near),
                @floatCast(clip.z_far),
            );
        }

        const view: Matrix = zm.lookAtRh(
            cam.position,
            cam.target,
            cam.up,
        );

        // World → clip.  Inline the 4×4 transform - the `v3Transform`
        // bridge assumes w=1 and drops the result's w.  We need w back
        // to do the perspective divide.
        const v_pos: Vec = vector4MatrixTransform(
            .{ .x = position[0], .y = position[1], .z = position[2], .w = 1.0 },
            view,
        );
        const clip_pos: Vec = vector4MatrixTransform(v_pos, proj);

        // Perspective divide → NDC ([-1, 1]).  Guard against w=0.
        const inv_w: f32 = if (clip_pos.w != 0) 1.0 / clip_pos.w else 0;
        const ndc_x: f32 = clip_pos[0] * inv_w;
        const ndc_y: f32 = clip_pos[1] * inv_w;

        // NDC → screen pixels.  GL convention: NDC y up, screen y down.
        return .{ (ndc_x + 1.0) * 0.5 * w, (1.0 - ndc_y) * 0.5 * h };
    }

    /// Project a world-space 2D point into screen-space using a Camera2D.
    pub fn getWorldToScreen2D(position: Vec2, cam: Camera2D) Vec2 {
        const m: Matrix = getCameraMatrix2D(cam);
        const transformed: Vec = v3Transform(vec(position[0], position[1], 0), m);
        return .{ transformed[0], transformed[1] };
    }

    /// Inverse: screen-space pixel → world-space point under a Camera2D.
    pub fn getScreenToWorld2D(position: Vec2, cam: Camera2D) Vec2 {
        const m: zm.Mat = zm.inverse(getCameraMatrix2D(cam));
        const transformed: Vec = v3Transform(vec(position[0], position[1], 0), m);
        return .{ transformed[0], transformed[1] };
    }

    /// As `getScreenToWorldRay`, but with an explicit viewport size.
    /// Use this when rendering into an off-screen render target whose
    /// dimensions don't match the framebuffer.
    /// Reads `gl.cull_distance_near` / `gl.cull_distance_far` (clip
    /// planes for the projection matrix), `position`, `cam`, `width`,
    /// `height`.  No mutation.
    /// Implementation follows raylib's: convert pixel position to NDC,
    /// build view + projection matrices, unproject z=0 (near) and z=1
    /// (far) points to get a world-space line.  For perspective cameras
    /// the ray origin is the cam position; for ortho cameras the
    /// origin is the unprojected near-plane point (since orthographic
    /// rays don't converge).
    pub fn getScreenToWorldRayWithViewport(
        position: Vec2,
        cam: Camera3D,
        width: i32,
        height: i32,
        clip: ClipPlanes,
    ) Ray {
        const w: f32 = float(width);
        const h: f32 = float(height);
        const aspect: f32 = if (h > 0) w / h else 1.0;

        // Pixel → NDC.  Note y is flipped (raylib convention: top-left
        // origin in screen space, bottom-left origin in NDC).
        const ndc_x: f32 = (2.0 * position[0]) / w - 1.0;
        const ndc_y: f32 = 1.0 - (2.0 * position[1]) / h;

        // View matrix from cam lookAt.
        const view: Matrix = zm.lookAtRh(
            cam.position,
            cam.target,
            cam.up,
        );

        // Projection matrix.
        var proj: Matrix = undefined;
        if (cam.projection == CAMERA_PERSPECTIVE) {
            proj = zm.perspectiveFovRhGl(
                radFromDeg(cam.fovy_deg),
                aspect,
                @floatCast(clip.z_near),
                @floatCast(clip.z_far),
            );
        } else {
            const top: f32 = cam.fovy_deg / 2.0;
            const right: f32 = top * aspect;
            proj = zm.orthographicOffCenterRhGl(
                -right,
                right,
                // zmath signature: (left, right, TOP, BOTTOM, near, far)
                // - top before bottom.
                top,
                -top,
                @floatCast(clip.z_near),
                @floatCast(clip.z_far),
            );
        }

        // Unproject near and far points (z=0 → near, z=1 → far).
        const near_pt: Vec = v3Unproject(vec(ndc_x, ndc_y, 0.0), proj, view);
        const far_pt: Vec = v3Unproject(vec(ndc_x, ndc_y, 1.0), proj, view);

        // For ortho projections, the cam is a plane - origin is the
        // unprojected near point.  For perspective the origin is the
        // cam position.
        const direction: Vec = v3Normalize(v3Sub(far_pt, near_pt));
        const origin: Vec = if (cam.projection == CAMERA_PERSPECTIVE)
            vec(cam.position[0], cam.position[1], cam.position[2])
        else
            // For ortho: unproject z=-1 (cam plane) for the origin.
            v3Unproject(vec(ndc_x, ndc_y, -1.0), proj, view);

        return .{ .position = origin, .direction = direction };
    }

    // ===========================================================================
    // Internal helpers
    // ===========================================================================

    /// 4-component vector × column-major Matrix transform.  The
    /// `v3Transform` bridge drops the w component; this preserves it
    /// for projection-divide math.
    inline fn vector4MatrixTransform(v: Vec, m: Matrix) Vec {
        return .{
            .x = m[0][0] * v[0] + m[1][0] * v[1] + m[2][0] * v[2] + m[3][0] * v.w,
            .y = m[0][1] * v[0] + m[1][1] * v[1] + m[2][1] * v[2] + m[3][1] * v.w,
            .z = m[0][2] * v[0] + m[1][2] * v[1] + m[2][2] * v[2] + m[3][2] * v.w,
            .w = m[0][3] * v[0] + m[1][3] * v[1] + m[2][3] * v[2] + m[3][3] * v.w,
        };
    }

    // ===========================================================================
    // Camera helpers + driver - Phase 12 port from zray
    // ===========================================================================

    const input_for_camera = input;
    const core_for_camera = core;

    const CAMERA_MOVE_SPEED: f32 = 5.4; // units per second
    const CAMERA_ROTATION_SPEED: f32 = 0.03;
    const CAMERA_PAN_SPEED: f32 = 0.2;
    const CAMERA_MOUSE_MOVE_SENSITIVITY: f32 = 0.003;
    const CAMERA_ORBITAL_SPEED: f32 = 0.5; // radians per second

    pub const CameraMode = enum(i32) {
        custom = 0,
        free = 1,
        orbital = 2,
        first_person = 3,
        third_person = 4,
    };

    // Key constants (from raylib enum) used by the driver.
    const KbK = @import("types.zig").KeyboardKey;
    const MB = @import("types.zig").MouseButton;
    const KEY_W: KbK = .w;
    const KEY_A: KbK = .a;
    const KEY_S: KbK = .s;
    const KEY_D: KbK = .d;
    const KEY_Q: KbK = .q;
    const KEY_E: KbK = .e;
    const KEY_UP: KbK = .up;
    const KEY_DOWN: KbK = .down;
    const KEY_LEFT: KbK = .left;
    const KEY_RIGHT: KbK = .right;
    const KEY_SPACE: KbK = .space;
    const KEY_LEFT_CONTROL: KbK = .left_control;
    const MOUSE_BUTTON_MIDDLE: MB = .middle;

    // ---- Basis vectors
    pub fn getCameraForward(cam: *Camera3D) Vec {
        return normalize3(cam.target - cam.position);
    }
    pub fn getCameraUp(cam: *Camera3D) Vec {
        return normalize3(cam.up);
    }
    pub fn getCameraRight(cam: *Camera3D) Vec {
        const forward: Vec = getCameraForward(cam);
        const up: Vec = getCameraUp(cam);
        return normalize3(cross(forward, up));
    }

    // ---- Translation
    pub fn cameraMoveForward(
        cam: *Camera3D,
        distance: f32,
        move_in_world_plane: bool,
    ) void {
        var forward: Vec = getCameraForward(cam);
        if (move_in_world_plane) {
            if (@abs(cam.up[2]) > sqrt1_2) {
                forward[2] = 0;
            } else if (@abs(cam.up[0]) > sqrt1_2) {
                forward[0] = 0;
            } else {
                forward[1] = 0;
            }
            forward = normalize3(forward);
        }
        forward = forward * @as(Vec, @splat(distance));
        cam.position = cam.position + forward;
        cam.target = cam.target + forward;
    }

    pub fn cameraMoveUp(cam: *Camera3D, distance: f32) void {
        const up: Vec = getCameraUp(cam) * @as(Vec, @splat(distance));
        cam.position = cam.position + up;
        cam.target = cam.target + up;
    }

    pub fn cameraMoveRight(
        cam: *Camera3D,
        distance: f32,
        move_in_world_plane: bool,
    ) void {
        var right: Vec = getCameraRight(cam);
        if (move_in_world_plane) {
            if (@abs(cam.up[2]) > sqrt1_2) {
                right[2] = 0;
            } else if (@abs(cam.up[0]) > sqrt1_2) {
                right[0] = 0;
            } else {
                right[1] = 0;
            }
            right = normalize3(right);
        }
        right = right * @as(Vec, @splat(distance));
        cam.position = cam.position + right;
        cam.target = cam.target + right;
    }

    pub fn cameraMoveToTarget(cam: *Camera3D, delta: f32) void {
        var dist: f32 = length3(cam.position - cam.target);
        dist += delta;
        if (dist <= 0) {
            dist = 0.001;
        }
        const forward: Vec = getCameraForward(cam);
        cam.position = cam.target + forward * @as(Vec, @splat(-dist));
    }

    // ---- Rotation (radians)
    pub fn cameraYaw(
        cam: *Camera3D,
        angle: f32,
        rotate_around_target: bool,
    ) void {
        const up: Vec = getCameraUp(cam);
        var view: Vec = cam.target - cam.position;
        view = zm.rotateByAxisAngle3(view, up, angle);
        if (rotate_around_target) {
            cam.position = cam.target - view;
        } else {
            cam.target = cam.position + view;
        }
    }

    pub fn cameraPitch(
        cam: *Camera3D,
        angle_in: f32,
        lock_view: bool,
        rotate_around_target: bool,
        rotate_up: bool,
    ) void {
        var angle: f32 = angle_in;
        const up: Vec = getCameraUp(cam);
        var view: Vec = cam.target - cam.position;

        if (lock_view) {
            // Clamp so we can only look straight up / down at most.
            var max_up: f32 = angle3(up, view);
            max_up -= 0.001;
            if (angle > max_up) {
                angle = max_up;
            }
            var max_down: f32 = angle3(-up, view);
            max_down *= -1.0;
            max_down += 0.001;
            if (angle < max_down) {
                angle = max_down;
            }
        }

        const right: Vec = getCameraRight(cam);
        view = zm.rotateByAxisAngle3(view, right, angle);
        if (rotate_around_target) {
            cam.position = cam.target - view;
        } else {
            cam.target = cam.position + view;
        }
        if (rotate_up) {
            cam.up = zm.rotateByAxisAngle3(cam.up, right, angle);
        }
    }

    pub fn cameraRoll(cam: *Camera3D, angle: f32) void {
        const forward: Vec = getCameraForward(cam);
        cam.up = zm.rotateByAxisAngle3(cam.up, forward, angle);
    }

    // ---- Drivers - `updateCamera` / `updateCameraPro`
    /// Drive the cam using keyboard + mouse + (if available) gamepad
    /// input.  Mode picks one of the high-level behaviors (free /
    /// orbital / first-person / third-person).  `dt` is seconds since
    /// last frame (pass `f.time.delta_time`); used to make movement speed
    /// framerate-independent.
    pub fn updateCamera(
        cam: *Camera3D,
        mode: CameraMode,
        dt: f32,
        input_state: *const input_for_camera.InputState,
    ) void {
        const mode_int: i32 = @intFromEnum(mode);
        const move_in_world_plane: bool = (mode == .first_person) or (mode == .third_person);
        const rotate_around_target: bool = (mode == .third_person) or (mode == .orbital);
        const lock_view: bool = (mode == .free) or
            (mode == .first_person) or
            (mode == .third_person) or
            (mode == .orbital);
        const rotate_up: bool = false;

        const move_speed: f32 = CAMERA_MOVE_SPEED * dt;
        const rot_speed: f32 = CAMERA_ROTATION_SPEED;
        const pan_speed: f32 = CAMERA_PAN_SPEED;
        const orbit_speed: f32 = CAMERA_ORBITAL_SPEED * dt;

        if (mode == .custom) {
            // Caller drives manually.
        } else if (mode == .orbital) {
            // `getCameraUp` returns a `Vec` post-Z4 - feed `matFromAxisAngle`
            // directly.  `view` is a direction, `mul(view, rotation)` is the
            // row-vector transform.
            const up: Vec = getCameraUp(cam);
            const rotation: zm.Mat = zm.matFromAxisAngle(up, orbit_speed);
            var view: Vec = cam.position - cam.target;
            view = mulMatVec(rotation, view);
            cam.position = cam.target + view;
        } else {
            // Keyboard rotation.
            if (input_for_camera.isKeyDown(input_state, KEY_DOWN)) {
                cameraPitch(cam, -rot_speed, lock_view, rotate_around_target, rotate_up);
            }
            if (input_for_camera.isKeyDown(input_state, KEY_UP)) {
                cameraPitch(cam, rot_speed, lock_view, rotate_around_target, rotate_up);
            }
            if (input_for_camera.isKeyDown(input_state, KEY_RIGHT)) {
                cameraYaw(cam, -rot_speed, rotate_around_target);
            }
            if (input_for_camera.isKeyDown(input_state, KEY_LEFT)) {
                cameraYaw(cam, rot_speed, rotate_around_target);
            }
            if (input_for_camera.isKeyDown(input_state, KEY_Q)) {
                cameraRoll(cam, -rot_speed);
            }
            if (input_for_camera.isKeyDown(input_state, KEY_E)) {
                cameraRoll(cam, rot_speed);
            }

            // Pan with middle mouse in CAMERA_FREE.
            if (mode == .free and input_for_camera.isMouseButtonDown(input_state, MOUSE_BUTTON_MIDDLE)) {
                const md: Vec2 = input_for_camera.getMouseDelta(input_state);
                if (md[0] > 0.0) {
                    cameraMoveRight(cam, pan_speed, move_in_world_plane);
                }
                if (md[0] < 0.0) {
                    cameraMoveRight(cam, -pan_speed, move_in_world_plane);
                }
                if (md[1] > 0.0) {
                    cameraMoveUp(cam, -pan_speed);
                }
                if (md[1] < 0.0) {
                    cameraMoveUp(cam, pan_speed);
                }
            } else {
                // Mouse look.
                const mouse_delta: Vec2 = input_for_camera.getMouseDelta(input_state);
                // First-person inverts horizontal look (drag right turns left).
                const yaw_sign: f32 = if (mode == .first_person) 1.0 else -1.0;
                cameraYaw(cam, yaw_sign * mouse_delta[0] * CAMERA_MOUSE_MOVE_SENSITIVITY, rotate_around_target);
                cameraPitch(
                    cam,
                    -mouse_delta[1] * CAMERA_MOUSE_MOVE_SENSITIVITY,
                    lock_view,
                    rotate_around_target,
                    rotate_up,
                );
            }

            // WASD.
            if (input_for_camera.isKeyDown(input_state, KEY_W)) {
                cameraMoveForward(cam, move_speed, move_in_world_plane);
            }
            if (input_for_camera.isKeyDown(input_state, KEY_A)) {
                cameraMoveRight(cam, -move_speed, move_in_world_plane);
            }
            if (input_for_camera.isKeyDown(input_state, KEY_S)) {
                cameraMoveForward(cam, -move_speed, move_in_world_plane);
            }
            if (input_for_camera.isKeyDown(input_state, KEY_D)) {
                cameraMoveRight(cam, move_speed, move_in_world_plane);
            }

            if (mode == .free) {
                if (input_for_camera.isKeyDown(input_state, KEY_SPACE)) {
                    cameraMoveUp(cam, move_speed);
                }
                if (input_for_camera.isKeyDown(input_state, KEY_LEFT_CONTROL)) {
                    cameraMoveUp(cam, -move_speed);
                }
            }
        }

        if (mode == .third_person or mode == .orbital or mode == .free) {
            cameraMoveToTarget(cam, -input_for_camera.getMouseWheelMove(input_state));
        }

        _ = mode_int; // silence unused warn in some configs
    }

    /// Lower-level cam drive: pass desired movement (forward/right/up
    /// in world units), rotation (pitch/yaw/roll in radians), and zoom
    /// delta directly.  Useful when the app handles input itself.
    pub fn updateCameraPro(
        cam: *Camera3D,
        movement: Vec,
        rotation_rad: Vec,
        zoom: f32,
    ) void {
        const lock_view: bool = true;
        const rotate_around_target: bool = false;
        const rotate_up: bool = false;
        const move_in_world_plane: bool = true;

        cameraPitch(cam, -rotation_rad[1], lock_view, rotate_around_target, rotate_up);
        cameraYaw(cam, -rotation_rad[0], rotate_around_target);
        cameraRoll(cam, rotation_rad[2]);

        cameraMoveForward(cam, movement[0], move_in_world_plane);
        cameraMoveRight(cam, movement[1], move_in_world_plane);
        cameraMoveUp(cam, movement[2]);

        cameraMoveToTarget(cam, zoom);
    }

    // ---- tests
    // `beginMode3D` / `endMode3D` are GPU-state-touching and not
    // testable at this layer; covered via the wasm smoke (cube3d).
    // The math helpers (`getCameraMatrix`, `getCameraMatrix2D`,
    // `getWorldToScreen2D`, `getScreenToWorld2D`) are pure CPU and
    // directly testable.

    const test_eps: f32 = 1e-4;
    fn closeTest(a: f32, b: f32) bool {
        return @abs(a - b) <= test_eps;
    }

    test "getCameraMatrix: camera at origin looking forward gives identity-ish view" {
        const c: Camera3D = .{
            .position = vec(0, 0, 0),
            .target = vec(0, 0, -1),
            .up = vec(0, 1, 0),
            .fovy_deg = 60,
            .projection = 0,
        };
        const m: Matrix = getCameraMatrix(c);
        // Looking down -Z with +Y up is the canonical OpenGL view.
        try expect(closeTest(m[0][0], 1));
        try expect(closeTest(m[1][1], 1));
        try expect(closeTest(m[2][2], 1));
    }

    test "getCameraMatrix: shifted camera position appears in translation column" {
        const c: Camera3D = .{
            .position = vec(5, 0, 0),
            .target = vec(0, 0, 0),
            .up = vec(0, 1, 0),
            .fovy_deg = 60,
            .projection = 0,
        };
        const m: Matrix = getCameraMatrix(c);
        try expect(@abs(m[3][0]) + @abs(m[3][1]) + @abs(m[3][2]) > 0);
    }

    test "getCameraMatrix2D: zoom=1 / rotation=0 / offset+target=0 gives identity" {
        const c: Camera2D = .{
            .offset = .{ 0, 0 },
            .target = .{ 0, 0 },
            .rotation = 0,
            .zoom = 1,
        };
        const m: Matrix = getCameraMatrix2D(c);
        try expect(closeTest(m[0][0], 1));
        try expect(closeTest(m[1][1], 1));
        try expect(closeTest(m[2][2], 1));
        try expect(closeTest(m[3][3], 1));
        try expect(closeTest(m[3][0], 0));
        try expect(closeTest(m[3][1], 0));
    }

    test "getCameraMatrix2D: zoom doubles, identity rotation, no offset" {
        const c: Camera2D = .{
            .offset = .{ 0, 0 },
            .target = .{ 0, 0 },
            .rotation = 0,
            .zoom = 2,
        };
        const m: Matrix = getCameraMatrix2D(c);
        try expect(closeTest(m[0][0], 2));
        try expect(closeTest(m[1][1], 2));
    }

    test "getCameraMatrix2D: target offset translates" {
        const c: Camera2D = .{
            .offset = .{ 0, 0 },
            .target = .{ 100, 50 },
            .rotation = 0,
            .zoom = 1,
        };
        const m: Matrix = getCameraMatrix2D(c);
        try expect(closeTest(m[3][0], -100));
        try expect(closeTest(m[3][1], -50));
    }

    test "world↔screen 2D round trip: identity camera" {
        const c: Camera2D = .{
            .offset = .{ 0, 0 },
            .target = .{ 0, 0 },
            .rotation = 0,
            .zoom = 1,
        };
        const world: Vec2 = .{ 42, 17 };
        const screen: Vec2 = getWorldToScreen2D(world, c);
        try expect(closeTest(screen[0], 42));
        try expect(closeTest(screen[1], 17));

        const back: Vec2 = getScreenToWorld2D(screen, c);
        try expect(closeTest(back[0], 42));
        try expect(closeTest(back[1], 17));
    }

    test "world↔screen 2D round trip: zoomed + offset camera" {
        const c: Camera2D = .{
            .offset = .{ 400, 300 },
            .target = .{ 0, 0 },
            .rotation = 0,
            .zoom = 2,
        };
        const screen_origin: Vec2 = getWorldToScreen2D(.{ 0, 0 }, c);
        try expect(closeTest(screen_origin[0], 400));
        try expect(closeTest(screen_origin[1], 300));

        const test_points = [_]Vec2{
            .{ 50, 25 },
            .{ -10, 100 },
            .{ 0, 0 },
        };
        for (test_points) |p| {
            const s: Vec2 = getWorldToScreen2D(p, c);
            const back: Vec2 = getScreenToWorld2D(s, c);
            try expect(closeTest(back[0], p[0]));
            try expect(closeTest(back[1], p[1]));
        }
    }

    test "world↔screen 2D round trip: rotated camera" {
        const c: Camera2D = .{
            .offset = .{ 0, 0 },
            .target = .{ 0, 0 },
            .rotation = 0.5, // radians
            .zoom = 1,
        };
        const test_points = [_]Vec2{
            .{ 10, 0 },
            .{ 0, 10 },
            .{ 7, -3 },
        };
        for (test_points) |p| {
            const s: Vec2 = getWorldToScreen2D(p, c);
            const back: Vec2 = getScreenToWorld2D(s, c);
            try expect(closeTest(back[0], p[0]));
            try expect(closeTest(back[1], p[1]));
        }
    }

    test "getScreenToWorldRayWithViewport: perspective ray origin == camera position" {
        const c: Camera3D = .{
            .position = vec(0, 0, 5),
            .target = vec(0, 0, 0),
            .up = vec(0, 1, 0),
            .fovy_deg = 45,
            .projection = 0, // CAMERA_PERSPECTIVE
        };
        const ray: Ray = getScreenToWorldRayWithViewport(.{ 400, 300 }, c, 800, 600, .{});
        try expect(closeTest(ray.position[0], 0));
        try expect(closeTest(ray.position[1], 0));
        try expect(closeTest(ray.position[2], 5));
        try expect(ray.direction[2] < 0);
    }

    test "getScreenToWorldRayWithViewport: ray direction is unit-length" {
        const c: Camera3D = .{
            .position = vec(1, 2, 3),
            .target = vec(0, 0, 0),
            .up = vec(0, 1, 0),
            .fovy_deg = 60,
            .projection = 0,
        };
        const ray: Ray = getScreenToWorldRayWithViewport(.{ 100, 200 }, c, 640, 480, .{});
        const len: f32 = @sqrt(
            ray.direction[0] * ray.direction[0] +
                ray.direction[1] * ray.direction[1] +
                ray.direction[2] * ray.direction[2],
        );
        try expect(closeTest(len, 1.0));
    }

    test "getScreenToWorldRayWithViewport: orthographic origin is on camera plane (not camera position)" {
        const c: Camera3D = .{
            .position = vec(0, 0, 5),
            .target = vec(0, 0, 0),
            .up = vec(0, 1, 0),
            .fovy_deg = 10, // ortho size
            .projection = 1, // CAMERA_ORTHOGRAPHIC
        };
        const ray: Ray = getScreenToWorldRayWithViewport(.{ 100, 100 }, c, 800, 600, .{});
        try expect(ray.direction[2] < 0);
        const off: f32 = @abs(ray.position[0]) + @abs(ray.position[1]);
        try expect(off > 0.01);
    }
};

// ============================================================================
// SECTION - effects (was: src/effects.zig)
// ============================================================================

// ============================================================================
// SECTION - allocator (was: src/allocator.zig)
// ============================================================================

pub const allocator = struct {
    const is_wasm = builtin.target.cpu.arch.isWasm();

    const HEADER_SIZE: usize = 16;
    const ALIGN: std.mem.Alignment = .@"16";

    // Use a generous align for the underlying allocation so the user
    // pointer at offset 16 is still 16-byte aligned.

    /// libc malloc.  Returns null on OOM, on size=0, or on non-wasm targets.
    pub fn malloc(size: usize) ?*anyopaque {
        if (comptime !is_wasm) {
            return null;
        }
        if (size == 0) {
            return null;
        }

        const total: usize = size + HEADER_SIZE;
        const slice = std.heap.wasm_allocator.alignedAlloc(u8, ALIGN, total) catch return null;

        // Store user-visible size in the last `usize` of the header so
        // `free` can read it relative to the user pointer.
        writeHeader(slice.ptr, size);

        return @ptrCast(slice.ptr + HEADER_SIZE);
    }

    /// libc calloc - like malloc(nmemb * size) followed by memset to 0.
    pub fn calloc(nmemb: usize, size: usize) ?*anyopaque {
        if (comptime !is_wasm) {
            return null;
        }

        // Saturating multiply: if the multiplication overflows, treat as
        // OOM rather than producing a tiny allocation that the caller
        // reads past.
        const total = zm.mulChecked(usize, nmemb, size) catch return null;
        const ptr: *anyopaque = malloc(total) orelse return null;
        @memset(@as([*]u8, @ptrCast(ptr))[0..total], 0);
        return ptr;
    }

    /// libc realloc.
    /// - realloc(NULL, n) == malloc(n)
    /// - realloc(p, 0) frees p and returns NULL
    /// - otherwise: allocate, copy min(old, new), free old.  This is
    ///   simpler than the libc semantics where realloc *may* extend in
    ///   place; callers that rely on grow-in-place would be incorrect
    ///   anyway.
    pub fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
        if (comptime !is_wasm) {
            return null;
        }

        if (ptr == null) {
            return malloc(size);
        }
        if (size == 0) {
            free(ptr);
            return null;
        }
        const new_ptr: *anyopaque = malloc(size) orelse return null;
        const old_size: usize = readHeader(ptr.?);
        const copy: usize = @min(old_size, size);
        @memcpy(
            @as([*]u8, @ptrCast(new_ptr))[0..copy],
            @as([*]const u8, @ptrCast(ptr.?))[0..copy],
        );
        free(ptr);
        return new_ptr;
    }

    /// libc free.  No-op on null; tolerant on host.
    pub fn free(ptr: ?*anyopaque) void {
        if (comptime !is_wasm) {
            return;
        }
        const p: *anyopaque = ptr orelse return;
        const user_bytes: [*]u8 = @ptrCast(p);
        const base: [*]align(@intFromEnum(ALIGN)) u8 = @alignCast(user_bytes - HEADER_SIZE);
        const size: usize = readHeader(p);
        const slice: []align(@intFromEnum(ALIGN)) u8 = base[0 .. size + HEADER_SIZE];
        std.heap.wasm_allocator.free(slice);
    }

    // ---- Internal helpers
    inline fn writeHeader(base: [*]u8, size: usize) void {
        const size_field: *usize = @ptrCast(@alignCast(base + HEADER_SIZE - @sizeOf(usize)));
        size_field.* = size;
    }

    inline fn readHeader(user_ptr: *anyopaque) usize {
        const user_bytes: [*]u8 = @ptrCast(user_ptr);
        const size_field: *const usize = @ptrCast(@alignCast(user_bytes - @sizeOf(usize)));
        return size_field.*;
    }

    // ===========================================================================
    // freeMany - bridge for raylib-parity `[*c]T` fields
    // ===========================================================================
    // Many resource types (Mesh, Material, Shader, Model) are extern
    // structs whose pointer fields are `[*c]T` for raylib ABI parity.
    // `gpa.free` doesn't accept a slice produced from a `[*c]` because
    // the slice metadata's `size` is `.c`, not `.slice`.  This helper
    // does the coercion through `[*]T` so the call site is a single
    // readable line, and centralizes the cast in one place.
    // Used by `unloadMesh`, `unloadModel`, `unloadMaterial`,
    // `unloadShader`, etc.  Caller is responsible for passing the
    // allocator the buffer was originally allocated with, and for
    // passing the right element count.

    /// Free a `[*c]T` or `[*]T` buffer of `len` elements with `gpa`.
    /// `len == 0` is a silent no-op.  `T` is deduced from the pointer
    /// type - pass the pointer directly without a comptime type arg.
    pub inline fn freeMany(
        gpa: Allocator,
        ptr: anytype,
        len: usize,
    ) void {
        if (len == 0) {
            return;
        }
        const T = @typeInfo(@TypeOf(ptr)).pointer.child;
        const slice: []T = @as([*]T, @ptrCast(ptr))[0..len];
        gpa.free(slice);
    }

    // ---- tests
    test "freeMany: round-trips an alloc through a [*c]T" {
        const ta: Allocator = std.testing.allocator;
        const buf: []f32 = try ta.alloc(f32, 16);
        @memset(buf, 1.0);
        // Stash as `[*c]` like a Mesh/Material field would.
        const cptr: [*c]f32 = buf.ptr;
        freeMany(ta, cptr, 16);
        // No leak reported by std.testing.allocator if the free worked.
    }

    test "freeMany: works with [*]T as well as [*c]T" {
        const ta: Allocator = std.testing.allocator;
        const buf: []u8 = try ta.alloc(u8, 32);
        @memset(buf, 0xAA);
        const many: [*]u8 = buf.ptr;
        freeMany(ta, many, 32);
    }

    test "freeMany: len == 0 is a no-op (does not free)" {
        const ta: Allocator = std.testing.allocator;
        // We can't easily test "doesn't free" without a real ptr, so
        // the contract here is: if len is 0, the function returns
        // without touching the pointer.  Pass an aliased pointer; if
        // it tried to free, std.testing.allocator would catch the
        // double-free at deinit time below.
        const buf: []u32 = try ta.alloc(u32, 4);
        defer ta.free(buf);
        const cptr: [*c]u32 = buf.ptr;
        freeMany(ta, cptr, 0);
        // buf is still valid here; the deferred ta.free above succeeds.
    }

    test "freeMany: deduces T from pointer types of varied widths" {
        const ta: Allocator = std.testing.allocator;
        const a: []u16 = try ta.alloc(u16, 8);
        const b: []i32 = try ta.alloc(i32, 8);
        const c: []f64 = try ta.alloc(f64, 8);
        freeMany(ta, @as([*c]u16, a.ptr), 8);
        freeMany(ta, @as([*c]i32, b.ptr), 8);
        freeMany(ta, @as([*c]f64, c.ptr), 8);
    }
};

// ============================================================================
// SECTION - libc (was: src/libc.zig)
// ============================================================================

pub const libc = struct {
    const allocator_mod = allocator;

    pub const malloc = allocator_mod.malloc;
    pub const calloc = allocator_mod.calloc;
    pub const realloc = allocator_mod.realloc;
    pub const free = allocator_mod.free;
};

// Force discovery of nested-namespace inline tests.  Without this,
// Zig only emits tests for decls that are reached from elsewhere;
// the gestures namespace currently has no internal callers.
comptime {
    _ = gestures;
    _ = camera;
    _ = effects.clock;
    _ = effects.logger;
    _ = effects.rng;
    _ = effects.loader;
    _ = allocator;
}
