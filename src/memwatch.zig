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
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    live_bytes: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p: [*]u8 = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.live_bytes += len;
        return p;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (self.backing.rawResize(memory, alignment, new_len, ra)) {
            self.live_bytes = self.live_bytes + new_len - memory.len;
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
        const p: [*]u8 = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.live_bytes = self.live_bytes + new_len - memory.len;
        return p;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.live_bytes -= memory.len;
        self.backing.rawFree(memory, alignment, ra);
    }
};
