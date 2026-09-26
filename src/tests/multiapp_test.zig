// src/multiapp_test.zig - kill/restart leak proof for the userland
// multi-app pattern (Turn 10 of cleanup-and-roadmap).
// The gallery example proves that 4 sub-apps can run in one Frame
// at once.  These tests prove the *lifecycle* story underneath:
//   - A sub-app whose state owns allocations can be deinit'd
//     cleanly.
//   - A parent can kill a child (drop its state) and restart it
//     from a fresh state with no leaks.
//   - Many kill/restart cycles in sequence don't leak.
//   - Random kill/restart patterns over many frames don't leak.
//   - A child with a per-child arena off the parent's gpa releases
//     everything when its arena is deinit'd.
// `std.testing.allocator` is a `DebugAllocator(.{ .safety = true })`
// - at the end of every test it asserts no live allocations
// remain.  Any leak in any path makes the test go red.
// We define a `TestSubApp` here that's representative of a real
// allocating sub-app shape: owns its name, owns a dynamic event
// history, owns a per-child `Logger.Prefixed`.  Then we drive it
// through various kill/restart patterns.

const std = @import("std");
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const logger_mod = @import("../runtime.zig").effects.logger;

// TestSubApp - a representative sub-app shape that owns allocations
const TestSubApp = struct {
    gpa: Allocator,
    name: []u8, // owned
    history: ArrayList(u32) = .empty,
    tick_count: u32 = 0,

    pub fn init(
        gpa: Allocator,
        name: []const u8,
    ) Allocator.Error!TestSubApp {
        const owned_name: []u8 = try gpa.dupe(u8, name);
        return .{
            .gpa = gpa,
            .name = owned_name,
        };
    }

    pub fn deinit(self: *TestSubApp) void {
        self.gpa.free(self.name);
        self.history.deinit(self.gpa);
    }

    /// Append the current tick number to the history.  Allocates as
    /// the ArrayList grows.
    pub fn tick(self: *TestSubApp) Allocator.Error!void {
        try self.history.append(self.gpa, self.tick_count);
        self.tick_count += 1;
    }
};

// Single kill/restart cycle
test "multiapp: single init -> tick -> deinit cycle is balanced" {
    const ta: Allocator = std.testing.allocator;
    var app: TestSubApp = try TestSubApp.init(ta, "single-cycle");
    defer app.deinit();

    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try app.tick();
    }
    try expect(app.tick_count == 50);
    try expect(app.history.items.len == 50);
}

test "multiapp: 10 sequential kill/restart cycles leak nothing" {
    const ta: Allocator = std.testing.allocator;
    var cycle: usize = 0;
    while (cycle < 10) : (cycle += 1) {
        var app: TestSubApp = try TestSubApp.init(ta, "cyclic");
        var i: u32 = 0;
        while (i < 25) : (i += 1) {
            try app.tick();
        }
        app.deinit();
        // After deinit, the slot is "dead" - next iteration starts
        // fresh.  Any imbalance between init and deinit shows up as
        // a leak when std.testing.allocator's deinit runs.
    }
}

// Multi-child slot pattern - what the gallery's parent actually does
const ChildSlots = struct {
    children: [4]?TestSubApp,

    pub fn init() ChildSlots {
        return .{ .children = .{ null, null, null, null } };
    }

    pub fn spawn(
        self: *ChildSlots,
        gpa: Allocator,
        slot: usize,
        name: []const u8,
    ) !void {
        if (self.children[slot] != null) {
            return error.SlotOccupied;
        }
        self.children[slot] = try TestSubApp.init(gpa, name);
    }

    pub fn kill(
        self: *ChildSlots,
        slot: usize,
    ) void {
        if (self.children[slot]) |*app| {
            app.deinit();
            self.children[slot] = null;
        }
    }

    pub fn killAll(self: *ChildSlots) void {
        for (0..self.children.len) |i| {
            self.kill(i);
        }
    }

    pub fn tickAll(self: *ChildSlots) !void {
        for (&self.children) |*maybe_child| {
            if (maybe_child.*) |*child| {
                try child.tick();
            }
        }
    }
};

test "multiapp: 4-slot parent - spawn, tick, kill all" {
    const ta: Allocator = std.testing.allocator;
    var slots: ChildSlots = ChildSlots.init();
    defer slots.killAll();

    try slots.spawn(ta, 0, "pulse");
    try slots.spawn(ta, 1, "spinner");
    try slots.spawn(ta, 2, "sparkles");
    try slots.spawn(ta, 3, "counter");

    var f: u32 = 0;
    while (f < 30) : (f += 1) {
        try slots.tickAll();
    }
}

test "multiapp: kill one child mid-run, leave others alive" {
    const ta: Allocator = std.testing.allocator;
    var slots: ChildSlots = ChildSlots.init();
    defer slots.killAll();

    try slots.spawn(ta, 0, "pulse");
    try slots.spawn(ta, 1, "spinner");
    try slots.spawn(ta, 2, "sparkles");
    try slots.spawn(ta, 3, "counter");

    var f: u32 = 0;
    while (f < 10) : (f += 1) {
        try slots.tickAll();
    }
    // Kill spinner mid-run.
    slots.kill(1);
    while (f < 30) : (f += 1) {
        try slots.tickAll();
    }
    // Survivors should each have 30 ticks; killed slot is null.
    try expect(slots.children[0].?.tick_count == 30);
    try expect(slots.children[1] == null);
    try expect(slots.children[2].?.tick_count == 30);
    try expect(slots.children[3].?.tick_count == 30);
}

test "multiapp: kill + restart + kill again leaks nothing" {
    const ta: Allocator = std.testing.allocator;
    var slots: ChildSlots = ChildSlots.init();
    defer slots.killAll();

    try slots.spawn(ta, 0, "first-life");
    var f: u32 = 0;
    while (f < 5) : (f += 1) {
        try slots.tickAll();
    }
    slots.kill(0);
    try expect(slots.children[0] == null);

    try slots.spawn(ta, 0, "second-life");
    while (f < 15) : (f += 1) {
        try slots.tickAll();
    }
    // Second life starts fresh - tick count is 10 (from f=5..15),
    // not 15.
    try expect(slots.children[0].?.tick_count == 10);
    slots.kill(0);

    try slots.spawn(ta, 0, "third-life");
    while (f < 20) : (f += 1) {
        try slots.tickAll();
    }
    try expect(slots.children[0].?.tick_count == 5);
}

// Random kill/restart pattern - the rough kind of churn a long-running
// multi-app demo might hit
test "multiapp: random kill/restart over 200 frames leaks nothing" {
    const ta: Allocator = std.testing.allocator;
    var slots: ChildSlots = ChildSlots.init();
    defer slots.killAll();

    // Spawn all 4 to start.
    try slots.spawn(ta, 0, "a");
    try slots.spawn(ta, 1, "b");
    try slots.spawn(ta, 2, "c");
    try slots.spawn(ta, 3, "d");

    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const r: std.Random = prng.random();

    var f: u32 = 0;
    while (f < 200) : (f += 1) {
        try slots.tickAll();
        // Every ~7 frames, randomly kill or restart a slot.
        if (f % 7 == 0) {
            const slot: usize = r.intRangeLessThan(usize, 0, 4);
            if (slots.children[slot] == null) {
                try slots.spawn(ta, slot, "respawn");
            } else {
                slots.kill(slot);
            }
        }
    }
}

// Per-child arena - releases everything when arena is dropped
//
// This mirrors the most idiomatic multi-app pattern: each child owns
// an ArenaAllocator off the parent's gpa.  The child can allocate
// freely from its arena; killing the child = arena.deinit() releases
// everything in one shot.  No need to track individual allocations.

const ArenaSubApp = struct {
    arena: std.heap.ArenaAllocator,
    /// Number of pieces of work the child has done.  Each tick
    /// allocates a small buffer.
    work_count: u32 = 0,

    pub fn init(parent_gpa: Allocator) ArenaSubApp {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_gpa),
        };
    }

    pub fn deinit(self: *ArenaSubApp) void {
        self.arena.deinit();
    }

    /// Each tick allocates a small message into the arena.  No
    /// individual frees - arena cleanup releases everything.
    pub fn tick(self: *ArenaSubApp) Allocator.Error!void {
        const gpa: Allocator = self.arena.allocator();
        const msg: []u8 = try allocPrint(gpa, "work item {d}", .{self.work_count});
        _ = msg;
        self.work_count += 1;
    }
};

test "multiapp: per-child arena pattern - 50 ticks then deinit" {
    const ta: Allocator = std.testing.allocator;
    var app: ArenaSubApp = ArenaSubApp.init(ta);
    defer app.deinit();

    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try app.tick();
    }
    try expect(app.work_count == 50);
}

test "multiapp: per-child arena - 20 kill/restart cycles" {
    const ta: Allocator = std.testing.allocator;
    var cycle: usize = 0;
    while (cycle < 20) : (cycle += 1) {
        var app: ArenaSubApp = ArenaSubApp.init(ta);
        var i: u32 = 0;
        while (i < 10) : (i += 1) {
            try app.tick();
        }
        app.deinit();
    }
}

// Logger.Prefixed lifetime in the kill/restart context
//
// The gallery builds Prefixed on the stack of `runSubApp` so its
// lifetime is bounded by the dispatch call.  Here we verify the
// other valid pattern: storing Prefixed in the child's state.  The
// Prefixed itself doesn't allocate (it's just two pointers + a
// slice), so storing it costs nothing - just need to make sure
// killing the child doesn't reach into the parent's logger after
// the child is gone.

const LoggingSubApp = struct {
    gpa: Allocator,
    /// Owned name (so the prefix outlives a moved logger).
    name: []u8,
    /// Owned prefix wrapper.  Built once at init, shared by all
    /// log calls within this child's lifetime.
    prefixed: logger_mod.Prefixed,

    pub fn init(
        gpa: Allocator,
        parent_log: logger_mod.Logger,
        name: []const u8,
    ) Allocator.Error!LoggingSubApp {
        const owned_name: []u8 = try gpa.dupe(u8, name);
        return .{
            .gpa = gpa,
            .name = owned_name,
            .prefixed = logger_mod.Prefixed.init(parent_log, owned_name),
        };
    }

    pub fn deinit(self: *LoggingSubApp) void {
        // Prefixed has no heap state - only the owned name needs
        // freeing.  Once name is freed, no surviving Logger can
        // safely reference self.prefixed (the prefix slice would be
        // dangling).  Conservative check: deinit before any clone of
        // the child's logger view escapes.
        self.gpa.free(self.name);
    }
};

test "multiapp: child with stored Logger.Prefixed - kill/restart x 10" {
    const ta: Allocator = std.testing.allocator;
    var cap: logger_mod.Capture = logger_mod.Capture.init(ta);
    defer cap.deinit();
    const parent_log: logger_mod.Logger = cap.logger();

    var cycle: usize = 0;
    while (cycle < 10) : (cycle += 1) {
        var app: LoggingSubApp = try LoggingSubApp.init(ta, parent_log, "logger-child");
        const log: logger_mod.Logger = app.prefixed.logger();
        log.info("hi from cycle {d}", .{cycle});
        app.deinit();
    }

    try expect(cap.lines.items.len == 10);
    // Every line should bear the prefix.
    for (cap.lines.items) |entry| {
        try expect(startsWith(u8, entry.msg, "logger-child: "));
    }
}
