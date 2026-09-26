//! FrameArena — an `ArenaAllocator` that enforces its own per-frame reset.
//!
//! A plain arena used as a per-frame scratch has an unwritten contract: reset
//! it every frame or it grows without bound. On wasm32 that contract failing is
//! lethal and silent — linear memory only ever grows, so a forgotten reset
//! climbs straight into the ~2GB trap (this is exactly how the UI `frame_arena`
//! leak hid for so long). FrameArena turns that silent climb into a located
//! panic: the reset contract becomes part of the type instead of a comment.
//!
//! How it works: every `alloc` adds to a `live_bytes` tally; `reset` zeroes it.
//! If the tally crosses `ceiling` — set generously above one honest frame's
//! needs and far below the wall — `alloc` trips `assertf`. The check lives in
//! `alloc` (which always runs) rather than `reset` (which a forgotten reset
//! never calls), so "never reset" is caught within the first few frames. The
//! panic names the arena via `label` (the only localisation: an `@src()` here
//! resolves to this file, not the owner's frame loop).
//!
//! It is a drop-in for `std.heap.ArenaAllocator` at the call sites that matter:
//! `allocator()`, `reset(mode)` and `deinit()` mirror the arena, so only the
//! `init` site changes.
const std = @import("std");
const expectEqual = std.testing.expectEqual;
const zm = @import("zm");
const assertf = zm.assertf;
const Allocator = std.mem.Allocator;

pub const FrameArena = struct {
    arena: std.heap.ArenaAllocator,
    /// Bytes requested since the last reset. A forgotten per-frame reset makes
    /// this climb without bound — the tripwire below watches it.
    live_bytes: usize = 0,
    /// Panic ceiling. Pick it well above one legitimate frame and far below the
    /// wasm32 ~2GB wall, so it only ever fires on genuine runaway growth.
    ceiling: usize,
    /// Names the offending arena in the panic message.
    label: []const u8,

    pub fn init(
        child: Allocator,
        ceiling_bytes: usize,
        label: []const u8,
    ) FrameArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(child),
            .ceiling = ceiling_bytes,
            .label = label,
        };
    }

    pub fn deinit(self: *FrameArena) void {
        self.arena.deinit();
    }

    /// Drop-in for `ArenaAllocator.reset`. Clears the live-byte tally, then
    /// resets the wrapped arena. Keep `.retain_capacity` in the hot path so
    /// wasm memory plateaus at one frame's high-water instead of re-growing.
    pub fn reset(self: *FrameArena, mode: std.heap.ArenaAllocator.ResetMode) bool {
        self.live_bytes = 0;
        return self.arena.reset(mode);
    }

    pub fn queryCapacity(self: *FrameArena) usize {
        return self.arena.queryCapacity();
    }

    pub fn allocator(self: *FrameArena) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = allocImpl,
        .resize = resizeImpl,
        .remap = remapImpl,
        .free = freeImpl,
    };

    fn trip(self: *FrameArena) void {
        assertf(
            self.live_bytes <= self.ceiling,
            @src(),
            "FrameArena '{s}' reached {d} bytes since its last reset (ceiling {d}). " ++
                "A per-frame arena is not being reset every frame — check its owner's " ++
                "frame loop for a missing reset().",
            .{ self.label, self.live_bytes, self.ceiling },
        );
    }

    fn allocImpl(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        const child: Allocator = self.arena.allocator();
        const p: [*]u8 = child.vtable.alloc(child.ptr, len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        self.trip();
        return p;
    }

    fn resizeImpl(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        const child: Allocator = self.arena.allocator();
        if (child.vtable.resize(child.ptr, buf, alignment, new_len, ret_addr) == false) {
            return false;
        }
        if (new_len > buf.len) {
            self.live_bytes += new_len - buf.len;
            self.trip();
        }
        return true;
    }

    fn remapImpl(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        const child: Allocator = self.arena.allocator();
        const p: ?[*]u8 = child.vtable.remap(child.ptr, buf, alignment, new_len, ret_addr);
        if (p != null and new_len > buf.len) {
            self.live_bytes += new_len - buf.len;
            self.trip();
        }
        return p;
    }

    fn freeImpl(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        const child: Allocator = self.arena.allocator();
        child.vtable.free(child.ptr, buf, alignment, ret_addr);
    }
};

test "FrameArena resets the tally and stays under ceiling" {
    var fa: FrameArena = FrameArena.init(std.testing.allocator, 1 << 20, "test");
    defer fa.deinit();
    const a: Allocator = fa.allocator();
    var f: u32 = 0;
    while (f < 1000) : (f += 1) {
        const buf: []u8 = try a.alloc(u8, 256);
        _ = buf;
        _ = fa.reset(.retain_capacity);
        try expectEqual(@as(usize, 0), fa.live_bytes);
    }
}
