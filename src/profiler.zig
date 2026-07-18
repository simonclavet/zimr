//! profiler.zig — zimr's integrated, in-process profiler (Tracy-inspired).
//!
//! Comptime-gated by `build_options.profile_enabled` (derived from `-Dmode`:
//! on for `debug`/`release`, stripped in `ship`).  When disabled every entry
//! point is an empty inline no-op and NO storage is reserved, so a `ship`
//! build pays nothing (the impl fns referencing `store` live only inside
//! `if (enabled)` comptime-dead branches and are never analyzed).
//!
//! Model (locked in design): a HYBRID live+freeze profiler.  One set of ring
//! buffers is always recording; "freeze" merely stops them advancing.  Every
//! view defaults to the LONGEST frame in a rolling ~2 second window — the
//! hitch, not the average.
//!
//! Identity is the comptime `@src()` call site, so statistics aggregate by
//! location; optional per-call `.text()`/`.value()`/`.setColor()` annotate a
//! single zone for the detail view without changing its identity.
//!
//! This file is the COLLECTION backbone only: zones, frame marks, the
//! frame/zone rings, and the worst-frame tracker.  The overlay views
//! (flamegraph, frame strip, statistics table) read these buffers and are
//! built separately; the coarse engine phase-zones are added at call sites.

const std = @import("std");
const zm = @import("zm");
const float64 = zm.float64;
const build_options = @import("build_options");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Compile-time master switch.  Defensive `@hasDecl` so any module whose
/// build_options predate this option simply compiles the profiler out
/// instead of failing — only `debug`/`release` of the main modules turn it on.
pub const enabled: bool = if (@hasDecl(build_options, "profile_enabled"))
    build_options.profile_enabled
else
    false;

// ---- static capacities (BSS-resident, and only when enabled) ----
const frame_cap: usize = 256; // ring of frames (>= 2s even at 128 fps)
const gpu_cap: usize = 128; // ring of recent GPU pass-time samples (ms)
const zone_cap: usize = 1 << 16; // 65536 zone events shared across frames
const src_cap: usize = 1024; // distinct instrumented call sites
const window_ms: f64 = 2000.0; // rolling worst-frame window
const text_inline: usize = 31; // inline annotation text per zone (no arena)
const no_zone: u32 = ~@as(u32, 0); // sentinel: "not recording" (u32 max)
// When disabled the arrays collapse to length 0 (storage stripped); the impl
// that indexes them lives only in comptime-dead branches and is never analyzed.
const fcap: usize = if (enabled) frame_cap else 0;
const gcap: usize = if (enabled) gpu_cap else 0;
const zcap: usize = if (enabled) zone_cap else 0;
const scap: usize = if (enabled) src_cap else 0;

/// A distinct instrumented call site, interned once from `@src()`.
pub const SourceLoc = struct {
    name: []const u8 = "",
    file: []const u8 = "",
    line: u32 = 0,
    color: u32 = 0, // 0 => auto (hash of name) at render time
};

/// One timed scope.  `t1 == t0` until the zone is ended.
pub const ZoneEvent = struct {
    src: u32 = 0, // index into the source registry
    t0: f64 = 0, // begin timestamp (ms)
    t1: f64 = 0, // end timestamp (ms)
    depth: u16 = 0, // nesting depth within the frame
    color: u32 = 0, // 0 => use srcloc/auto
    value: u64 = 0,
    has_value: bool = false,
    text_len: u8 = 0,
    text: [text_inline]u8 = undefined,
};

/// One frame's bounds and the span of zones it owns in the zone ring.
pub const Frame = struct {
    index: u64 = 0, // monotonic frame number
    t0: f64 = 0,
    t1: f64 = 0,
    dur: f64 = 0, // t1 - t0 (ms)
    zone_first: u64 = 0, // monotonic zone index of its first zone
    zone_count: u32 = 0,
};

// ---- clock: pluggable so the engine can install the fast performance.now()
// import in wasm while native tests drive a deterministic fake clock. ----
// Default until the engine installs the real clock.  Returns 0 so an
// un-wired build is harmless (zero-duration frames) rather than dragging in
// a platform time API; wasm sets performance.now(), tests set a fake clock.
fn fallbackClock() f64 {
    return 0;
}
var clock_fn: *const fn () f64 = &fallbackClock; // lint:off module-var: profiler clock, installed by engine startup

/// Install the real high-resolution clock (engine calls this at startup with
/// a thin `() => performance.now()` accessor).
pub fn setClock(f: *const fn () f64) void {
    if (enabled) {
        clock_fn = f;
    }
}

var timer_res_ms: f64 = 0; // lint:off module-var: measured clock resolution (one-shot probe)

/// Sample the installed clock to estimate its resolution: the smallest non-zero
/// delta between consecutive reads. Call once after setClock. Without cross-origin
/// isolation browsers clamp performance.now() to ~100us; with it, ~5us — this
/// reports which you actually got, so a sub-resolution phase reading 0 is explained.
pub fn probeResolution() void {
    if (enabled) {
        var best: f64 = 1.0e9;
        var prev: f64 = clock_fn();
        var i: usize = 0;
        while (i < 4000) : (i += 1) {
            const t: f64 = clock_fn();
            const d: f64 = t - prev;
            if (d > 0 and d < best) {
                best = d;
            }
            prev = t;
        }
        timer_res_ms = if (best >= 1.0e9) 0 else best;
    }
}

/// The probed clock resolution in milliseconds (0 if not probed / unavailable).
pub fn timerResolutionMs() f64 {
    if (enabled) {
        return timer_res_ms;
    }
    return 0;
}

// ---- storage: a single struct, void (zero size) when disabled ----
const Store = struct {
    frames: [fcap]Frame = undefined,
    frame_head: usize = 0, // next write slot
    frame_count: usize = 0, // valid frames (<= frame_cap)
    frame_seq: u64 = 0, // monotonic frame counter

    zones: [zcap]ZoneEvent = undefined,
    zone_seq: u64 = 0, // monotonic zone counter; next slot = zone_seq % zone_cap

    srcs: [scap]SourceLoc = undefined,
    src_count: u32 = 0,

    depth: u16 = 0,
    cur_t0: f64 = 0, // start time of the in-progress frame
    cur_first: u64 = 0, // zone_seq at the start of the in-progress frame
    started: bool = false,
    frozen: bool = false,

    // GPU pass time (ms), fed each frame from the timestamp-query readback. It's
    // a separate ring because the value lands a frame or two after the matching
    // CPU frame (async readback), so it isn't tied to a specific Frame slot.
    gpu_ms: [gcap]f64 = @splat(0),
    gpu_head: usize = 0,
    gpu_count: usize = 0,
    gpu_last: f64 = 0,
};

var store: Store = .{}; // lint:off module-var: the profiler ring buffers (one in-process collector)

/// A live zone handle.  End it with `defer z.end();`.
pub const Zone = struct {
    idx: u32 = no_zone,

    pub inline fn end(self: Zone) void {
        if (enabled) {
            endZone(self);
        }
    }
    pub inline fn text(self: Zone, s: []const u8) void {
        if (enabled) {
            annotateText(self, s);
        }
    }
    pub inline fn value(self: Zone, v: u64) void {
        if (enabled) {
            annotateValue(self, v);
        }
    }
    pub inline fn setColor(self: Zone, c: u32) void {
        if (enabled) {
            annotateColor(self, c);
        }
    }
};

// ---- public API (inline, folds to nothing when disabled) ----

/// Begin a zone auto-named from the enclosing function.
pub inline fn zone(src: std.builtin.SourceLocation) Zone {
    if (enabled) {
        return beginZone(src, src.fn_name, 0);
    }
    return .{};
}

/// Begin a zone with an explicit label (identity is still the call site).
pub inline fn zoneNamed(src: std.builtin.SourceLocation, name: []const u8) Zone {
    if (enabled) {
        return beginZone(src, name, 0);
    }
    return .{};
}

/// Close the current frame and open the next.  Call once per rendered frame.
pub inline fn frameMark() void {
    if (enabled) {
        markFrame();
    }
}

/// Stop the rings advancing (snapshot for analysis).  Recording resumes on
/// `unfreeze()`.
pub fn freeze() void {
    if (enabled) {
        store.frozen = true;
    }
}
pub fn unfreeze() void {
    if (enabled) {
        store.frozen = false;
        auto_froze = false;
    }
}
pub fn isFrozen() bool {
    if (enabled) {
        return store.frozen;
    }
    return false;
}

// ---- auto-freeze-on-spike ----
var auto_armed: bool = false; // lint:off module-var: auto-freeze armed by the app
var auto_froze: bool = false; // lint:off module-var: set when a spike auto-froze
var spike_factor: f64 = 2.0; // lint:off module-var: spike = dur > factor * baseline
var spike_floor_ms: f64 = 4.0; // lint:off module-var: ignore spikes under this (ms)
var dur_ema: f64 = 0; // lint:off module-var: smoothed frame-duration baseline

/// Arm auto-freeze: the next frame whose duration exceeds `factor` x the smoothed
/// baseline (and is at least `floor_ms`) freezes the profiler automatically. Stays
/// armed across unfreeze, so it re-captures the next spike until disarmed.
pub fn armAutoFreeze(factor: f64, floor_ms: f64) void {
    if (enabled) {
        auto_armed = true;
        auto_froze = false;
        spike_factor = factor;
        spike_floor_ms = floor_ms;
    }
}
pub fn disarmAutoFreeze() void {
    if (enabled) {
        auto_armed = false;
        auto_froze = false;
    }
}
pub fn isAutoArmed() bool {
    if (enabled) {
        return auto_armed;
    }
    return false;
}
/// True when the current frozen snapshot was triggered by a spike (not a manual freeze).
pub fn autoFroze() bool {
    if (enabled) {
        return auto_froze;
    }
    return false;
}

// ---- GPU timing (fed externally; the profiler stays dependency-free) ----

/// Feed the latest GPU pass time (ms) from the timestamp-query readback. Ignored
/// when <= 0 (unsupported / not yet sampled) and while frozen, so the displayed
/// GPU figure snapshots with everything else. The value lags the matching CPU
/// frame by a frame or two (async readback), so it's a rolling figure.
pub fn recordGpuMs(ms: f64) void {
    if (enabled) {
        if (ms <= 0 or store.frozen) {
            return;
        }
        store.gpu_ms[store.gpu_head] = ms;
        store.gpu_head = (store.gpu_head + 1) % gpu_cap;
        if (store.gpu_count < gpu_cap) {
            store.gpu_count += 1;
        }
        store.gpu_last = ms;
    }
}
/// The most recent GPU pass-time sample (ms), or 0 if none.
pub fn gpuMsLast() f64 {
    if (enabled) {
        return store.gpu_last;
    }
    return 0;
}
/// Mean GPU pass time (ms) over the recent sample ring, or 0 if none.
pub fn gpuMsMean() f64 {
    if (enabled) {
        if (store.gpu_count == 0) {
            return 0;
        }
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < store.gpu_count) : (i += 1) {
            sum += store.gpu_ms[i];
        }
        return sum / float64(store.gpu_count);
    }
    return 0;
}
/// Mean CPU frame time (ms) across the rolling window, or 0 if none.
pub fn frameMeanMs() f64 {
    if (enabled) {
        if (store.frame_count == 0) {
            return 0;
        }
        const newest_slot: usize = (store.frame_head + frame_cap - 1) % frame_cap;
        const now_t: f64 = store.frames[newest_slot].t1;
        var sum: f64 = 0;
        var n: usize = 0;
        var fi: usize = 0;
        while (fi < store.frame_count) : (fi += 1) {
            const slot: usize = (store.frame_head + frame_cap - 1 - fi) % frame_cap;
            const f: Frame = store.frames[slot];
            if (now_t - f.t1 > window_ms) {
                break;
            }
            sum += f.dur;
            n += 1;
        }
        if (n == 0) {
            return 0;
        }
        return sum / float64(n);
    }
    return 0;
}

/// Clear all recorded state (used by tests and a manual reset button).
pub fn reset() void {
    if (enabled) {
        store = .{};
        dur_ema = 0;
        auto_froze = false;
    }
}

/// Number of valid frames currently retained.
pub fn frameCount() usize {
    if (enabled) {
        return store.frame_count;
    }
    return 0;
}

/// The longest frame within the rolling ~2s window, or null if none yet.
pub fn worstFrame() ?Frame {
    if (enabled) {
        return findWorst();
    }
    return null;
}

/// Iterator over one frame's zones (handles the shared zone ring's wrap).
pub const ZoneIter = struct {
    seq: u64 = 0,
    end_seq: u64 = 0,

    pub fn next(self: *ZoneIter) ?ZoneEvent {
        if (enabled) {
            if (self.seq >= self.end_seq) {
                return null;
            }
            const slot: usize = @intCast(self.seq % zone_cap);
            self.seq += 1;
            return store.zones[slot];
        }
        return null;
    }
};

/// Zones belonging to `f`, oldest-first (depth order is begin order).
pub fn frameZones(f: Frame) ZoneIter {
    if (enabled) {
        return .{ .seq = f.zone_first, .end_seq = f.zone_first + f.zone_count };
    }
    return .{};
}

/// The interned source location for a zone's `src` id.
pub fn srcOf(id: u32) SourceLoc {
    if (enabled) {
        if (id < store.src_count) {
            return store.srcs[id];
        }
    }
    return .{};
}

/// The i-th most recent retained frame (i = 0 is newest), or null.
pub fn frameAt(i: usize) ?Frame {
    if (enabled) {
        if (i >= store.frame_count) {
            return null;
        }
        const slot: usize = (store.frame_head + frame_cap - 1 - i) % frame_cap;
        return store.frames[slot];
    }
    return null;
}

/// Per-source-location aggregate over the rolling window (the "statistics").
pub const SrcStat = struct {
    src: u32 = 0,
    count: u32 = 0,
    total_ms: f64 = 0,
    min_ms: f64 = 0,
    max_ms: f64 = 0,
};

/// Accumulate per-call-site stats across every frame in the ~2s window into
/// `out` (indexed by src id). Returns the number of entries written; entries
/// with count == 0 never fired in the window.
pub fn aggregate(out: []SrcStat) usize {
    if (enabled) {
        const n: usize = @min(store.src_count, out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = .{ .src = @intCast(i) };
        }
        if (store.frame_count == 0) {
            return n;
        }
        const newest_slot: usize = (store.frame_head + frame_cap - 1) % frame_cap;
        const now_t: f64 = store.frames[newest_slot].t1;
        var fi: usize = 0;
        while (fi < store.frame_count) : (fi += 1) {
            const slot: usize = (store.frame_head + frame_cap - 1 - fi) % frame_cap;
            const f: Frame = store.frames[slot];
            if (now_t - f.t1 > window_ms) {
                break;
            }
            var zit: ZoneIter = frameZones(f);
            while (zit.next()) |z| {
                if (z.src >= n) {
                    continue;
                }
                const d: f64 = z.t1 - z.t0;
                const st: *SrcStat = &out[z.src];
                if (st.count == 0 or d < st.min_ms) {
                    st.min_ms = d;
                }
                if (d > st.max_ms) {
                    st.max_ms = d;
                }
                st.total_ms += d;
                st.count += 1;
            }
        }
        return n;
    }
    return 0;
}

/// Fill `out` with one value per frame in the rolling window: the total (inclusive)
/// time spent in zones matching `src` that frame, newest first. Returns the count.
/// Feeds the find-zone histogram (the per-frame distribution of one call site).
pub fn frameSeriesFor(src: u32, out: []f64) usize {
    if (enabled) {
        if (store.frame_count == 0) {
            return 0;
        }
        const newest_slot: usize = (store.frame_head + frame_cap - 1) % frame_cap;
        const now_t: f64 = store.frames[newest_slot].t1;
        var n: usize = 0;
        var fi: usize = 0;
        while (fi < store.frame_count and n < out.len) : (fi += 1) {
            const slot: usize = (store.frame_head + frame_cap - 1 - fi) % frame_cap;
            const f: Frame = store.frames[slot];
            if (now_t - f.t1 > window_ms) {
                break;
            }
            var sum: f64 = 0;
            var zit: ZoneIter = frameZones(f);
            while (zit.next()) |z| {
                if (z.src == src) {
                    sum += z.t1 - z.t0;
                }
            }
            out[n] = sum;
            n += 1;
        }
        return n;
    }
    return 0;
}

// ---- implementation (analyzed only when enabled) ----

fn ptrEq(a: []const u8, b: []const u8) bool {
    return a.ptr == b.ptr and a.len == b.len;
}

fn internSrc(src: std.builtin.SourceLocation, name: []const u8, color: u32) u32 {
    var i: u32 = 0;
    while (i < store.src_count) : (i += 1) {
        const s: *const SourceLoc = &store.srcs[i];
        if (s.line == src.line and ptrEq(s.file, src.file) and ptrEq(s.name, name)) {
            return i;
        }
    }
    if (store.src_count >= src_cap) {
        return 0; // registry full: bucket everything further into slot 0
    }
    const id: u32 = store.src_count;
    store.srcs[id] = .{ .name = name, .file = src.file, .line = src.line, .color = color };
    store.src_count += 1;
    return id;
}

fn beginZone(src: std.builtin.SourceLocation, name: []const u8, color: u32) Zone {
    if (store.frozen or !store.started) {
        return .{ .idx = no_zone };
    }
    const sid: u32 = internSrc(src, name, color);
    const slot: u32 = @intCast(store.zone_seq % zone_cap);
    const t: f64 = clock_fn();
    store.zones[slot] = .{
        .src = sid,
        .t0 = t,
        .t1 = t,
        .depth = store.depth,
        .color = color,
        .value = 0,
        .has_value = false,
        .text_len = 0,
        .text = undefined,
    };
    store.zone_seq += 1;
    store.depth += 1;
    return .{ .idx = slot };
}

fn endZone(z: Zone) void {
    if (z.idx == no_zone) {
        return;
    }
    if (store.depth > 0) {
        store.depth -= 1;
    }
    store.zones[z.idx].t1 = clock_fn();
}

fn annotateText(z: Zone, s: []const u8) void {
    if (z.idx == no_zone) {
        return;
    }
    const n: usize = @min(s.len, text_inline);
    @memcpy(store.zones[z.idx].text[0..n], s[0..n]);
    store.zones[z.idx].text_len = @intCast(n);
}

fn annotateValue(z: Zone, v: u64) void {
    if (z.idx == no_zone) {
        return;
    }
    store.zones[z.idx].value = v;
    store.zones[z.idx].has_value = true;
}

fn annotateColor(z: Zone, c: u32) void {
    if (z.idx == no_zone) {
        return;
    }
    store.zones[z.idx].color = c;
}

fn markFrame() void {
    const t: f64 = clock_fn();
    if (!store.started) {
        store.started = true;
        store.cur_t0 = t;
        store.cur_first = store.zone_seq;
        return;
    }
    if (store.frozen) {
        return;
    }
    const slot: usize = store.frame_head;
    store.frames[slot] = .{
        .index = store.frame_seq,
        .t0 = store.cur_t0,
        .t1 = t,
        .dur = t - store.cur_t0,
        .zone_first = store.cur_first,
        .zone_count = @intCast(store.zone_seq - store.cur_first),
    };
    store.frame_head = (slot + 1) % frame_cap;
    if (store.frame_count < frame_cap) {
        store.frame_count += 1;
    }
    store.frame_seq += 1;
    // Auto-freeze on a relative spike: a frame much worse than the smoothed
    // baseline (and over an absolute floor) freezes the rings so the hitch is
    // captured without racing to hit a button. Steady-slow scenes don't trip it
    // (the baseline tracks them); only genuine outliers do.
    const cur_dur: f64 = t - store.cur_t0;
    if (auto_armed and store.frame_count > 20 and dur_ema > 0) {
        if (cur_dur > spike_factor * dur_ema and cur_dur > spike_floor_ms) {
            store.frozen = true;
            auto_froze = true;
        }
    }
    if (dur_ema <= 0) {
        dur_ema = cur_dur;
    } else {
        dur_ema = dur_ema * 0.9 + cur_dur * 0.1;
    }
    // open the next frame
    store.cur_t0 = t;
    store.cur_first = store.zone_seq;
    store.depth = 0; // safety: never let an unbalanced zone leak across frames
}

fn findWorst() ?Frame {
    if (store.frame_count == 0) {
        return null;
    }
    const newest_slot: usize = (store.frame_head + frame_cap - 1) % frame_cap;
    const now_t: f64 = store.frames[newest_slot].t1;
    var best: ?Frame = null;
    var i: usize = 0;
    while (i < store.frame_count) : (i += 1) {
        const slot: usize = (store.frame_head + frame_cap - 1 - i) % frame_cap;
        const f: Frame = store.frames[slot];
        if (now_t - f.t1 > window_ms) {
            break; // iterating newest -> oldest; everything past here is older
        }
        if (best == null or f.dur > best.?.dur) {
            best = f;
        }
    }
    return best;
}

// ---- tests (deterministic fake clock) ----
var test_now: f64 = 0; // lint:off module-var: test-only fake clock
fn testClock() f64 {
    return test_now;
}

test "records frames and picks the worst in the window" {
    if (!enabled) {
        return;
    }
    setClock(&testClock);
    test_now = 0;
    reset();

    frameMark(); // starts the first frame at t=0
    {
        const z: Zone = zone(@src());
        test_now += 4;
        z.end();
    }
    test_now += 6;
    frameMark(); // close frame 1: ~10ms

    test_now += 25;
    frameMark(); // close frame 2: ~25ms (the hitch)

    test_now += 8;
    frameMark(); // close frame 3: ~8ms

    try expectEqual(@as(usize, 3), frameCount());
    const w: Frame = worstFrame().?;
    try expect(w.dur >= 24.0 and w.dur <= 26.0);
}

test "auto-freeze fires on a spike but not on steady frames" {
    if (!enabled) {
        return;
    }
    setClock(&testClock);
    test_now = 0;
    reset();
    disarmAutoFreeze();
    armAutoFreeze(2.0, 4.0);

    frameMark(); // start
    // 30 steady ~10ms frames: baseline settles, no spike.
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        test_now += 10;
        frameMark();
    }
    try expect(!isFrozen());

    // one 40ms hitch: > 2x the ~10ms baseline and over the 4ms floor -> auto-freeze.
    test_now += 40;
    frameMark();
    try expect(isFrozen());
    try expect(autoFroze());

    // frozen rings: further marks don't advance the frame count.
    const fc: usize = frameCount();
    test_now += 10;
    frameMark();
    try expectEqual(fc, frameCount());
}

test "disabled build is inert" {
    // When stripped, the API must still be callable and cost nothing.
    if (enabled) {
        return;
    }
    const z: Zone = zone(@src());
    z.end();
    frameMark();
    try expectEqual(@as(usize, 0), frameCount());
    try expect(worstFrame() == null);
}
