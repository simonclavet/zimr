//! lint:alias memwatch
//! MemWatch - a per-frame wasm-linear-memory growth watchdog.
//!
//! Wasm linear memory only ever grows; an unbounded per-frame leak therefore
//! marches silently into the ~2GB trap and kills the tab with no diagnostic.
//! This is a smoke detector: sample `@wasmMemorySize` once per frame and shout
//! (once, then throttled) when memory climbs well past where it last settled.
//! It does not say *where* - it converts "silent death in 20s" into "something
//! is leaking, go look", which is the expensive half of the diagnosis.
//!
//! False positives are avoided without any manual hooks: a legitimate one-time
//! load (scene change, launcher child swap) grows memory then *plateaus*. When
//! growth stalls for `plateau_needed` frames we accept the new high-water as the
//! settled floor, so only growth that *keeps going* (a real leak) ever warns.
//!
//! State lives in a struct (held on the App), not a module global, and the whole
//! thing compiles to nothing in ship.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const leakwatch = @import("leakwatch.zig");

const is_wasm: bool = builtin.target.cpu.arch == .wasm32;
/// On in debug / release-with-asserts; compiled out in ship (matches assertf).
const active: bool = builtin.mode == .debug or
    (@hasDecl(build_options, "assert_log") and build_options.assert_log);

pub const MemWatch = struct {
    high_water_pages: u32 = 0, // most wasm pages (64 KiB) seen so far
    baseline_pages: u32 = 0, // last settled floor; growth is measured from here
    plateau_frames: u32 = 0, // consecutive frames with no new high-water
    next_warn_pages: u32 = 0, // throttle: stay quiet until the high-water reaches this

    const page_kib: u32 = 64;
    /// Growth above the settled floor that counts as "this is a leak, warn".
    /// Generous so a chunky one-time load never trips it before it plateaus.
    const warn_margin_pages: u32 = (128 * 1024) / page_kib; // 128 MiB
    /// Frames of no growth before we accept the high-water as the new floor.
    const plateau_needed: u32 = 120; // ~2s at 60fps

    /// Call once per frame, after the frame's work. `frame` is any monotonic
    /// per-frame counter (used only for the message).
    pub fn tick(self: *MemWatch, frame: u64) void {
        if (comptime !active) {
            return;
        }
        if (comptime !is_wasm) {
            return;
        }
        const pages: u32 = @intCast(@wasmMemorySize(0));
        if (self.high_water_pages == 0) {
            self.high_water_pages = pages;
            self.baseline_pages = pages;
            self.next_warn_pages = pages + warn_margin_pages;
            return;
        }
        if (pages > self.high_water_pages) {
            self.high_water_pages = pages;
            self.plateau_frames = 0;
        } else {
            self.plateau_frames += 1;
            if (self.plateau_frames >= plateau_needed) {
                // Settled - treat the current high-water as legitimate so a
                // one-time load doesn't read as a leak. Re-arm the throttle.
                self.baseline_pages = self.high_water_pages;
                self.next_warn_pages = self.baseline_pages + warn_margin_pages;
            }
        }
        if (self.high_water_pages >= self.next_warn_pages) {
            const grew_mib: u32 = ((self.high_water_pages - self.baseline_pages) * page_kib) / 1024;
            const total_mib: u32 = (self.high_water_pages * page_kib) / 1024;
            std.log.err(
                "memwatch: wasm memory climbed {d} MiB above its settled floor (now {d} MiB) " ++
                    "without plateauing (frame {d}) — likely a per-frame leak: an unreset frame " ++
                    "arena, an unfreed GPU readback, or a growing list. Wasm memory never shrinks, " ++
                    "so this trends toward the ~2GB trap.",
                .{ grew_mib, total_mib, frame },
            );
            // Re-arm one margin higher so a continuing leak keeps shouting
            // periodically rather than every frame.
            self.next_warn_pages = self.high_water_pages + warn_margin_pages;
        }
    }
};

/// An allocator shim that tracks NET live bytes through a backing allocator, for
/// the smoke harness's per-lifecycle CPU-leak probe - the precise, fragmentation-
/// free twin of the GPU handle census.
///
/// The app runs TWO of these over the same backing allocator - `label = "example"`
/// for what the example allocates, `"engine"` for the engine's own subsystems - so a
/// leak report can say which side grew (see `App.engine_gpa`).
///
/// ** THE ONE MISUSE A COUNTER CAN SEE BY ITSELF: freeing more than it handed out.
/// That means memory allocated through the OTHER counter was freed through this one -
/// an ownership mix-up, since both share the backing allocator and nothing else would
/// notice. Without a check it is a bare "integer overflow" panic in a Debug build and
/// a silent wrap in a release one. Instead it is logged with the label and the sizes,
/// counted in `wrong_side_frees`, and the tally clamps at zero. It cannot catch the
/// mirror case (a cross-free that does not underflow) - that is what the gate's
/// "net live bytes grew" on one side and shrank on the other would show.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    live_bytes: usize = 0,
    /// Which side this counts ("example" / "engine"), for the misuse message.
    label: []const u8 = "",
    /// Frees (or shrinks) that took more bytes than this counter had live - see above.
    wrong_side_frees: u32 = 0,
    /// The attribution tracer, when a host turned it on (`--leak-trace`): it sits UNDER
    /// this counter (`backing` is its allocator) and records every allocation with its
    /// side, phase and scope. Null the rest of the time, which costs one branch per call.
    watch: ?*leakwatch.LeakWatch = null,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// Remove `n` bytes from the tally, catching an ownership mix-up instead of
    /// wrapping around or panicking on an overflow nobody could read.
    fn subtract(self: *CountingAllocator, n: usize) void {
        if (n > self.live_bytes) {
            self.wrong_side_frees += 1;
            // `warn`, not `err`: the smoke gate fails on `wrong_side_frees` itself (a
            // number, not a log line), and an `err` log would fail this guard's own test.
            std.log.warn(
                "memwatch: the '{s}' allocator was asked to free {d} bytes but only {d} are live " ++
                    "through it - memory allocated through the OTHER allocator (example vs engine) " ++
                    "was freed through this one. Free with the allocator that made it.",
                .{ self.label, n, self.live_bytes },
            );
            self.live_bytes = 0;
            return;
        }
        self.live_bytes -= n;
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Tell the tracer (if any) which side the next call comes through.
    fn noteSide(self: *CountingAllocator) void {
        if (self.watch) |w| {
            w.side_hint = self.label;
        }
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.noteSide();
        const p: [*]u8 = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.live_bytes += len;
        return p;
    }

    /// Apply a size change: growth adds, shrinkage goes through `subtract`.
    fn adjust(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.live_bytes += new_len - old_len;
        } else {
            self.subtract(old_len - new_len);
        }
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.noteSide();
        if (self.backing.rawResize(memory, alignment, new_len, ra)) {
            self.adjust(memory.len, new_len);
            return true;
        }
        return false;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.noteSide();
        const p: [*]u8 = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.adjust(memory.len, new_len);
        return p;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.subtract(memory.len);
        self.backing.rawFree(memory, alignment, ra);
    }
};

/// Label everything allocated through `gpa` until the matching `popScope` - for the
/// `--leak-trace` report, so a surviving block says WHICH subsystem made it
/// ("frame: glyph_cache"). Engine code calls it at subsystem entry points with the
/// allocator it already holds; no global is involved.
///
/// A no-op unless `gpa` is a `CountingAllocator` with a tracer attached - i.e. everywhere
/// except a smoke run with `--leak-trace` - so it is safe to leave in hot-ish paths.
pub fn pushScope(gpa: std.mem.Allocator, label: []const u8) void {
    if (tracerOf(gpa)) |w| {
        w.push(label);
    }
}

/// End the scope `pushScope` began. Same no-op rule.
pub fn popScope(gpa: std.mem.Allocator) void {
    if (tracerOf(gpa)) |w| {
        w.pop();
    }
}

/// The tracer under `gpa`, when `gpa` is a `CountingAllocator` that has one. Recognised by
/// its vtable - the one thing an `Allocator` value says about what it is.
fn tracerOf(gpa: std.mem.Allocator) ?*leakwatch.LeakWatch {
    if (gpa.vtable != &CountingAllocator.vtable) {
        return null;
    }
    const counting: *CountingAllocator = @ptrCast(@alignCast(gpa.ptr));
    return counting.watch;
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "CountingAllocator: net live bytes follow alloc, grow, shrink and free" {
    var counting: CountingAllocator = .{ .backing = std.testing.allocator, .label = "example" };
    const gpa: std.mem.Allocator = counting.allocator();
    var list: std.ArrayList(u8) = .empty;
    try list.appendNTimes(gpa, 7, 100);
    try expectEqual(list.capacity, counting.live_bytes);
    list.shrinkAndFree(gpa, 10);
    try expectEqual(list.capacity, counting.live_bytes);
    list.deinit(gpa);
    try expectEqual(@as(usize, 0), counting.live_bytes);
    try expectEqual(@as(u32, 0), counting.wrong_side_frees);
}

test "CountingAllocator: a free through the wrong counter is caught, not wrapped" {
    // Two counters over one backing allocator, as the app runs them. The example
    // allocates; the ENGINE frees it. The engine never handed those bytes out, so its
    // tally would underflow - instead it counts the mix-up and clamps.
    var example: CountingAllocator = .{ .backing = std.testing.allocator, .label = "example" };
    var engine: CountingAllocator = .{ .backing = std.testing.allocator, .label = "engine" };
    const saved_log_level: std.log.Level = std.testing.log_level;
    std.testing.log_level = .err; // the warning IS the behaviour under test; keep a pass silent
    defer std.testing.log_level = saved_log_level;
    const block: []u8 = try example.allocator().alloc(u8, 64);
    engine.allocator().free(block);
    try expectEqual(@as(u32, 1), engine.wrong_side_frees);
    try expectEqual(@as(usize, 0), engine.live_bytes);
    // ...and the example's side still shows the 64 bytes as live: its lifecycle check
    // would report them, which is the other half of how a mix-up surfaces.
    try expectEqual(@as(usize, 64), example.live_bytes);
}

test "pushScope: engine code labels its allocations through the allocator it holds" {
    // The `--leak-trace` wiring: a tracer UNDER a counter, and engine code that only holds
    // the counter's `Allocator`. `pushScope` must find the tracer through it, and each entry
    // must record which side it came through.
    var watch: leakwatch.LeakWatch = .init(std.testing.allocator, std.testing.allocator);
    defer watch.deinit();
    var engine: CountingAllocator = .{ .backing = watch.allocator(), .label = "engine" };
    engine.watch = &watch;
    const engine_gpa: std.mem.Allocator = engine.allocator();

    pushScope(engine_gpa, "glyph_cache");
    const block: []u8 = try engine_gpa.alloc(u8, 32);
    defer engine_gpa.free(block);
    popScope(engine_gpa);

    var it: @TypeOf(watch.live).ValueIterator = watch.live.valueIterator();
    const entry: *leakwatch.Entry = it.next().?;
    try expectEqualStrings("glyph_cache", entry.label);
    try expectEqualStrings("engine", entry.side);

    // Any other allocator: a no-op, not a crash.
    pushScope(std.testing.allocator, "ignored");
    popScope(std.testing.allocator);
    try expectEqual(@as(usize, 0), watch.scopes.items.len);
}
