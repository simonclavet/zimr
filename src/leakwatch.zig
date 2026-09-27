//! lint:alias leakwatch
//! LeakWatch - an allocator wrapper that says WHERE a leak came from.
//!
//! -- * THE GAP THIS FILLS --
//!
//! `std.heap.SafeAllocator` (the testing allocator) already detects leaks and reports the size.
//! In a Debug build it also captures a stack trace, and that is usually enough. In ReleaseSafe
//! it does not - traces are stripped - so a leak reports as
//!
//!     leaked [addr: 0x..., len: 3324 align: 8] allocated at: (empty stack trace)
//!
//! which tells you a leak exists and nothing about it. `memwatch.zig` has the same shape of
//! limitation by design: it converts "silent death in 20s" into "something leaks", and says so
//! in its own header.
//!
//! * AND THE PROBLEM IS WORSE THAN A MISSING TRACE. A test suite's leak is attributed to
//! whichever test was running when the check fired, which need not be the test that leaked -
//! so the first thing to establish is not "where was it allocated" but "is this test even
//! responsible". That took most of a session to establish by hand, by truncating a test and
//! watching the leak survive.
//!
//! -- ** WHAT THIS DOES INSTEAD --
//!
//! Wraps any allocator and records, per live allocation, a caller-supplied LABEL. Labels are
//! scoped: `watch.push("mjcf.readRobot")` ... `watch.pop()`, so every allocation made inside
//! carries the enclosing scope without any call site being edited. On `report`, what survived
//! is printed by label and size.
//!
//! * A LABEL BEATS A STACK TRACE FOR THIS PURPOSE, and not only because it survives
//! optimisation. A trace tells you the innermost frame - usually `ArrayList.ensureCapacity`,
//! which is true and useless. A label tells you the SUBSYSTEM, which is the level at which
//! ownership is actually decided.
//!
//! ** WHAT IT CANNOT TELL YOU: where a buffer was originally created. A growing `ArrayList`
//! allocates a new block, copies, and frees the old one - three unrelated vtable calls - so the
//! label names where the LIVE allocation was made, which for a grown buffer is where it last
//! grew. Still the right answer for "who is holding this memory now"; not an answer to "where
//! did this come from". See the growth test at the bottom of this file.
//!
//! -- * COST, AND WHY IT IS OFF THE HOT PATH --
//!
//! One hash-map entry per live allocation, and a slice copy of the label pointer (labels are
//! `[]const u8` literals, not copied). Intended for tests and for a debug session, not for a
//! shipping frame loop - `memwatch` is the one that is cheap enough to leave on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expect = std.testing.expect;

/// One live allocation, and the scope that made it.
pub const Entry = struct {
    len: usize,
    label: []const u8,
    /// Monotonic counter, so a report can be read in allocation order - which usually
    /// reconstructs the call sequence better than sorting by address.
    ordinal: u64,
    /// The OUTERMOST scope when it was made - the phase a host pushed first ("init",
    /// "frame", "deinit") - so a report reads "frame: glyph_cache", not just the leaf.
    phase: []const u8 = "",
    /// Which counter it came through ("example" / "engine"), when a `CountingAllocator`
    /// sits on top and says so (`side_hint`). Empty otherwise.
    side: []const u8 = "",
    /// Non-zero when this allocation was PROBABLY a container growing: the very next call
    /// freed an older block with the same label, of this many bytes (see `free`).
    grew_from: usize = 0,
};

pub const LeakWatch = struct {
    child: Allocator,
    live: std.AutoHashMapUnmanaged(usize, Entry),
    scopes: std.ArrayListUnmanaged([]const u8),
    bookkeeping: Allocator,
    next_ordinal: u64,
    /// Set to a byte count to trace every allocation of exactly that size - the fastest way to
    /// go from "3324 bytes leaked" to "this call made it". Zero disables.
    watch_size: usize = 0,
    watch_hits: u32 = 0,
    /// `reportSinceMark` lists only allocations made at or after this ordinal (see `mark`).
    mark_ordinal: u64 = 0,
    /// Set by a `CountingAllocator` layered on top just before it forwards a call, so each
    /// entry records which counter (example / engine) it came through.
    side_hint: []const u8 = "",
    /// The address the PREVIOUS vtable call allocated, if that call was an `alloc` - zero
    /// otherwise. It is what lets `free` spot the grow-by-copy shape (see `free`).
    previous_call_allocated: usize = 0,

    /// `bookkeeping` holds the tracking tables.
    ///
    /// ** IT MAY BE THE SAME ALLOCATOR AS `child` - they are different LAYERS, not different
    /// pools. `child` is what this wrapper forwards to; `bookkeeping` is used directly, without
    /// passing through the wrapper, so the tables never appear in their own report. Handing the
    /// WRAPPED allocator here would be the mistake, and it is not expressible: `allocator()`
    /// cannot be called before `init` returns.
    pub fn init(child: Allocator, bookkeeping: Allocator) LeakWatch {
        return .{
            .child = child,
            .live = .empty,
            .scopes = .empty,
            .bookkeeping = bookkeeping,
            .next_ordinal = 0,
            .watch_size = 0,
            .watch_hits = 0,
        };
    }

    pub fn deinit(self: *LeakWatch) void {
        self.live.deinit(self.bookkeeping);
        self.scopes.deinit(self.bookkeeping);
    }

    /// Everything allocated until the matching `pop` is attributed to `label`.
    ///
    /// * NESTING IS THE POINT. `push("import")` around a whole subsystem and `push("sensors")`
    /// inside it gives `import/sensors`, so a report reads as a path rather than a leaf.
    pub fn push(self: *LeakWatch, label: []const u8) void {
        // A tracker that fails to record a scope must not take down the program it is
        // diagnosing; the report just says "(no scope pushed)" for anything made inside.
        // lint:off catch-suppression: diagnostics must not be able to fail the run
        self.scopes.append(self.bookkeeping, label) catch {};
    }

    pub fn pop(self: *LeakWatch) void {
        _ = self.scopes.pop();
    }

    pub fn allocator(self: *LeakWatch) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// How much is live, in bytes. Zero at a clean shutdown.
    pub fn liveBytes(self: *const LeakWatch) usize {
        var total: usize = 0;
        var it: @TypeOf(self.live).ValueIterator = self.live.valueIterator();
        while (it.next()) |entry| {
            total += entry.len;
        }
        return total;
    }

    /// Print every surviving allocation, in the order it was made.
    ///
    /// Returns the number of leaks, so a caller can assert on it.
    pub fn report(self: *const LeakWatch, comptime who: []const u8) usize {
        if (self.live.count() == 0) {
            return 0;
        }
        std.log.err(who ++ ": {d} live allocations, {d} bytes", .{ self.live.count(), self.liveBytes() });
        // Ordered by ordinal: allocation order reconstructs the call sequence better than
        // address order, which is whatever the allocator happened to hand out.
        var ordered: std.ArrayListUnmanaged(Entry) = .empty;
        defer ordered.deinit(self.bookkeeping);
        var it: @TypeOf(self.live).ValueIterator = self.live.valueIterator();
        while (it.next()) |entry| {
            ordered.append(self.bookkeeping, entry.*) catch break;
        }
        std.mem.sort(Entry, ordered.items, {}, struct {
            fn before(_: void, a: Entry, b: Entry) bool {
                return a.ordinal < b.ordinal;
            }
        }.before);
        for (ordered.items) |entry| {
            std.log.err("  #{d:<6} {d:>10} bytes  {s}", .{
                entry.ordinal,
                entry.len,
                if (entry.label.len == 0) "(no scope pushed)" else entry.label,
            });
        }
        return self.live.count();
    }

    /// Everything allocated from now on is what `reportSinceMark` will list. The smoke gate
    /// marks just before an example's SECOND lifecycle, so the report holds only what that
    /// lifecycle made and did not give back.
    pub fn mark(self: *LeakWatch) void {
        self.mark_ordinal = self.next_ordinal;
    }

    /// Print every allocation made since `mark` that is still live, in allocation order,
    /// with its side, phase, scope and - when it looks like one - the container growth that
    /// made it. Returns how many there were.
    pub fn reportSinceMark(self: *const LeakWatch, comptime who: []const u8) usize {
        var ordered: std.ArrayListUnmanaged(Entry) = .empty;
        defer ordered.deinit(self.bookkeeping);
        var it: @TypeOf(self.live).ValueIterator = self.live.valueIterator();
        while (it.next()) |entry| {
            if (entry.ordinal < self.mark_ordinal) {
                continue;
            }
            ordered.append(self.bookkeeping, entry.*) catch break;
        }
        if (ordered.items.len == 0) {
            return 0;
        }
        std.mem.sort(Entry, ordered.items, {}, struct {
            fn before(_: void, a: Entry, b: Entry) bool {
                return a.ordinal < b.ordinal;
            }
        }.before);
        std.log.warn(who ++ ": {d} allocation(s) made since the mark are still live:", .{ordered.items.len});
        for (ordered.items) |entry| {
            const side: []const u8 = if (entry.side.len == 0) "?" else entry.side;
            const phase: []const u8 = if (entry.phase.len == 0) "(no phase)" else entry.phase;
            const scope: []const u8 = if (entry.label.len == 0) "(no scope pushed)" else entry.label;
            if (entry.grew_from != 0) {
                std.log.warn(
                    who ++ ":   {s} +{d} bytes  {s}: {s}  - replaced a {d}-byte block of the same scope: " ++
                        "probably a container that GREW (something appends, nothing clears), not a missed free",
                    .{ side, entry.len, phase, scope, entry.grew_from },
                );
            } else {
                std.log.warn(who ++ ":   {s} +{d} bytes  {s}: {s}", .{ side, entry.len, phase, scope });
            }
        }
        return ordered.items.len;
    }

    /// The outermost scope - the phase a host pushed first.
    fn currentPhase(self: *const LeakWatch) []const u8 {
        if (self.scopes.items.len == 0) {
            return "";
        }
        return self.scopes.items[0];
    }

    fn currentLabel(self: *const LeakWatch) []const u8 {
        // The innermost scope. A deeper join would need to allocate, and an allocator that
        // allocates to describe an allocation is a bad idea in a leak tracker.
        if (self.scopes.items.len == 0) {
            return "";
        }
        return self.scopes.items[self.scopes.items.len - 1];
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *LeakWatch = @ptrCast(@alignCast(ctx));
        const out: [*]u8 = self.child.rawAlloc(len, alignment, ra) orelse return null;
        if (self.watch_size != 0 and len == self.watch_size) {
            self.watch_hits += 1;
            std.log.err("leakwatch: allocation #{d} of exactly {d} bytes, scope '{s}'", .{
                self.next_ordinal,
                len,
                if (self.currentLabel().len == 0) "(none)" else self.currentLabel(),
            });
        }
        // lint:off catch-suppression: as above - losing one record beats aborting
        self.live.put(self.bookkeeping, @intFromPtr(out), .{
            .len = len,
            .label = self.currentLabel(),
            .ordinal = self.next_ordinal,
            .phase = self.currentPhase(),
            .side = self.side_hint,
            // lint:off catch-suppression: diagnostics must never abort the run they diagnose
        }) catch {};
        self.next_ordinal += 1;
        self.previous_call_allocated = @intFromPtr(out);
        return out;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *LeakWatch = @ptrCast(@alignCast(ctx));
        self.previous_call_allocated = 0;
        if (!self.child.rawResize(buf, alignment, new_len, ra)) {
            return false;
        }
        // * THE POINTER DOES NOT MOVE ON A RESIZE - that is what distinguishes it from a remap -
        // so only the recorded length changes. Removing and re-adding here would lose the
        // ordinal and the label for no reason.
        if (self.live.getPtr(@intFromPtr(buf.ptr))) |entry| {
            entry.len = new_len;
        }
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *LeakWatch = @ptrCast(@alignCast(ctx));
        self.previous_call_allocated = 0;
        const out: [*]u8 = self.child.rawRemap(buf, alignment, new_len, ra) orelse return null;
        // * A REMAP IS A FREE AND AN ALLOC AT ONCE, and forgetting the free half makes the
        // tracker report a leak for memory that merely moved. The label is carried across here
        // because this call CAN see both halves - unlike a grow that goes through separate
        // `alloc`/`free` calls, where nothing links them. See the growth test.
        const carried: Entry = if (self.live.fetchRemove(@intFromPtr(buf.ptr))) |kv| kv.value else .{
            .len = new_len,
            .label = self.currentLabel(),
            .ordinal = self.next_ordinal,
        };
        // lint:off catch-suppression: as above - losing one record beats aborting
        self.live.put(self.bookkeeping, @intFromPtr(out), .{
            .len = new_len,
            .label = carried.label,
            .ordinal = carried.ordinal,
            // lint:off catch-suppression: diagnostics must never abort the run they diagnose
        }) catch {};
        self.next_ordinal += 1;
        return out;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *LeakWatch = @ptrCast(@alignCast(ctx));
        const freed: ?Entry = if (self.live.fetchRemove(@intFromPtr(buf.ptr))) |kv| kv.value else null;
        // ** THE GROW-BY-COPY SHAPE: `alloc(new)` immediately followed by `free(old)`, where
        // `old` is OLDER and carries the same scope. That is how ArrayList and HashMap grow
        // (allocate, copy, free - three unlinked calls, see the growth test below). Nothing
        // PROVES the two belong together, so the report says "probably"; but in a leak hunt
        // it is exactly the difference between "a deinit forgot a free" and "something keeps
        // appending to a container nobody clears", and those are fixed in different places.
        const just_allocated: usize = self.previous_call_allocated;
        self.previous_call_allocated = 0;
        if (freed) |old| {
            if (just_allocated != 0) {
                if (self.live.getPtr(just_allocated)) |new| {
                    const old_is_older: bool = old.ordinal < new.ordinal;
                    const same_scope: bool = std.mem.eql(u8, old.label, new.label);
                    if (old_is_older and same_scope and new.len > old.len) {
                        new.grew_from = old.len;
                    }
                }
            }
        }
        self.child.rawFree(buf, alignment, ra);
    }
};

test "leakwatch: names the scope that leaked" {
    const gpa: Allocator = std.testing.allocator;
    var watch: LeakWatch = .init(gpa, gpa);
    defer watch.deinit();
    const a: Allocator = watch.allocator();

    watch.push("innocent");
    const freed: []u8 = try a.alloc(u8, 64);
    a.free(freed);
    watch.pop();

    watch.push("the guilty one");
    const kept: []u8 = try a.alloc(u8, 128);
    watch.pop();

    // * ONLY THE SURVIVOR IS LIVE, and it carries the scope that made it - which is the whole
    // point: the size alone was never the hard part.
    try expectEqual(@as(usize, 1), watch.live.count());
    try expectEqual(@as(usize, 128), watch.liveBytes());
    var it: @TypeOf(watch.live).ValueIterator = watch.live.valueIterator();
    try expectEqualStrings("the guilty one", it.next().?.label);

    a.free(kept);
    try expectEqual(@as(usize, 0), watch.live.count());
}

test "leakwatch: a grown buffer is attributed to where it GREW, and why" {
    // *** THE LIMIT OF WHAT AN ALLOCATOR WRAPPER CAN KNOW, and it is worth stating precisely
    // because the obvious guess is wrong.
    //
    // The first version of this test asserted that a buffer keeps the label of the scope that
    // CREATED it, on the reasoning that `remap` is a free and an alloc at once and the label
    // could be carried across. Measured: it is not carried, because `ArrayList` does not grow
    // by `remap` here. It allocates a new buffer, copies, and frees the old one - **three
    // separate vtable calls with nothing linking them.** A wrapper sees an unrelated `alloc`
    // and an unrelated `free`, and no amount of care recovers the connection.
    //
    // * SO THE LABEL NAMES WHERE THE LIVE ALLOCATION WAS MADE, which for a grown buffer is
    // where it last grew. That is still the useful answer for leak-hunting - it says which
    // subsystem is holding the memory now - but it is not "where was this born", and a tool
    // that claimed to answer that would mislead exactly when it mattered.
    //
    // (`remap` IS handled and does carry the label, for the allocators and sizes where it
    // happens. It simply is not the path a growing `ArrayList` takes.)
    const gpa: Allocator = std.testing.allocator;
    var watch: LeakWatch = .init(gpa, gpa);
    defer watch.deinit();
    const a: Allocator = watch.allocator();

    watch.push("born here");
    var list: std.ArrayListUnmanaged(u32) = .empty;
    // * `defer` BEFORE THE ASSERTIONS. A failed expectation would otherwise skip the cleanup
    // and report a LEAK on top of the mismatch - two failures for one cause, the second
    // pointing somewhere else entirely. The first version of this test did exactly that, and it
    // cost a round of blaming the tracker.
    defer list.deinit(a);
    try list.appendSlice(a, &.{ 1, 2, 3, 4 });
    watch.pop();

    {
        var it: @TypeOf(watch.live).ValueIterator = watch.live.valueIterator();
        try expectEqualStrings("born here", it.next().?.label);
    }

    watch.push("grew here");
    for (0..2000) |i| {
        try list.append(a, @intCast(i));
    }
    watch.pop();

    // Still one live buffer, however many times it moved.
    try expectEqual(@as(usize, 1), watch.live.count());
    var it: @TypeOf(watch.live).ValueIterator = watch.live.valueIterator();
    try expectEqualStrings("grew here", it.next().?.label);
}

test "leakwatch: since a mark, a container that grew is told apart from a missed free" {
    // The smoke gate's shape, in miniature: lifecycle 1 fills a table, the gate marks,
    // lifecycle 2 appends more to the SAME table (it grows by copying) and also forgets one
    // plain allocation. The report must list both, flag the first as growth, and not the second.
    const gpa: Allocator = std.testing.allocator;
    var watch: LeakWatch = .init(gpa, gpa);
    defer watch.deinit();
    const a: Allocator = watch.allocator();
    var table: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer table.deinit(a);

    watch.push("frame");
    watch.push("glyph_cache");
    for (0..20) |i| {
        try table.put(a, @intCast(i), i);
    }
    watch.pop();
    watch.pop();

    watch.mark();

    watch.push("frame");
    watch.push("glyph_cache");
    for (20..200) |i| {
        try table.put(a, @intCast(i), i);
    }
    watch.pop();
    watch.push("forgotten");
    const missed: []u8 = try a.alloc(u8, 48);
    defer a.free(missed);
    watch.pop();
    watch.pop();

    const saved_log_level: std.log.Level = std.testing.log_level;
    std.testing.log_level = .err; // the report IS the behaviour; keep a passing test silent
    defer std.testing.log_level = saved_log_level;
    try expectEqual(@as(usize, 2), watch.reportSinceMark("test"));

    var saw_growth: bool = false;
    var saw_missed_free: bool = false;
    var it: @TypeOf(watch.live).ValueIterator = watch.live.valueIterator();
    while (it.next()) |entry| {
        if (entry.ordinal < watch.mark_ordinal) {
            continue;
        }
        if (std.mem.eql(u8, entry.label, "glyph_cache")) {
            saw_growth = entry.grew_from != 0 and entry.grew_from < entry.len;
            try expectEqualStrings("frame", entry.phase);
        } else if (std.mem.eql(u8, entry.label, "forgotten")) {
            saw_missed_free = entry.grew_from == 0 and entry.len == 48;
        }
    }
    try expect(saw_growth);
    try expect(saw_missed_free);
}
