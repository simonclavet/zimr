//! lint:alias entities
// src/entities.zig - pool-anchored ECS world.
// `Entities(T_primary)` is a wrapper around `pool.Pool(T_primary)`
// and `Registry`.  Every entity carries the primary component
// through the pool's fast 2-load deref path; optional secondary
// components attach via the existing archetype ECS.
// User-facing entity handle: `pool.Handle(T_primary)`, re-exported
// as `Entity` on the world type.  Distinct primary types give
// distinct world types (phantom-typed by `T_primary`).
// Synchronization invariant: pool and ECS allocate entity indices
// in lockstep.  Both use LIFO free lists + bump allocation, so as
// long as every `spawn` calls both sides and every `destroy` calls
// both sides, the indices stay matched.  An assertion in `spawn`
// catches any divergence.
// Three iteration verbs spell out the access pattern at the call
// site (instead of inferring it from the callback signature):
//   - `forEachPrimary` - dense pool scan, primary only.
//   - `forEachWith`    - archetype filter + per-match primary deref.
//   - `forEach`        - pure archetype walk, no primary touched.

const std = @import("std");
const ArrayList = std.ArrayList;
const ArrayListAligned = std.ArrayListAligned;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const alignForward = std.mem.alignForward;
const zm = @import("zm");
const float = zm.float;
const maxInt = zm.maxInt;
const Vec2 = zm.Vec2;
const assert = zm.assert;
const log = std.log;
const math = zm;

// =============================================================================
// Top-level user-facing types
// =============================================================================

const world_stamp = struct {
    pub const enabled: bool = builtin.mode == .debug;

    /// The stamp type - `u32` in debug, `void` (zero-sized) in release.
    /// u32 specifically because wasm32's atomic ops cap at 32 bits, and
    /// 4 billion unique stamps per process is far more than any realistic
    /// program creates.
    /// Stored in handle structs as a field; in release the field is
    /// zero-sized and the containing struct's size shrinks accordingly.
    pub const Stamp = if (enabled) u32 else void;

    /// Sentinel stamp value reserved for nil/uninit handles.  Never matches
    /// any real world's stamp (worlds start counting from 1).  Handles
    /// carrying this value SKIP the stamp check - useful for nil sentinels
    /// and test-fixture handles constructed via `pack(...)`.
    pub const nil_stamp: Stamp = if (enabled) 0 else {};

    /// Process-global atomic counter.  Each world's `init` calls `next()`
    /// to acquire its stamp.  Resets on process restart - fine, because
    /// handles don't persist across restarts either.
    // lint:off module-var: atomic per-world stamp
    var counter: if (enabled) std.atomic.Value(u32) else void =
        if (enabled) std.atomic.Value(u32).init(1) else {};

    /// Acquire the next process-unique stamp.  Monotonic ordering is
    /// sufficient - we only need uniqueness, not happens-before semantics.
    /// In release builds returns `{}` and compiles to nothing.
    pub fn next() Stamp {
        if (comptime !enabled) {
            return {};
        }
        return counter.fetchAdd(1, .monotonic);
    }

    /// In debug, verify that a handle's stamp matches the world's stamp.
    /// Panics with a useful message if they differ.  Skips the check when
    /// `handle_stamp == nil_stamp` - nil and externally-constructed
    /// handles deliberately bypass the check.
    /// `context_desc` is a short string identifying the handle type at the
    /// call site, e.g. `"Handle(Texture)"` or `"Ref(GpuMesh)"`.  Shows up
    /// in the panic message to point the user at the right line.
    /// In release builds this is a no-op and compiles to nothing.
    pub fn assertMatch(
        comptime context_desc: []const u8,
        handle_stamp: Stamp,
        world: Stamp,
    ) void {
        if (comptime !enabled) {
            return;
        }
        if (handle_stamp == nil_stamp) {
            return;
        }
        if (handle_stamp == world) {
            return;
        }
        std.debug.panic(
            "{s}: handle dereferenced against wrong world. " ++
                "handle.debug_stamp={d}, world.debug_stamp={d}. " ++
                "Common cause: a handle allocated against world A was passed " ++
                "to deref against world B. Check the function signatures along " ++
                "the call chain to confirm the same world is threaded through.",
            .{ context_desc, handle_stamp, world },
        );
    }

    // ============================================================================
    // Tests
    // ============================================================================

    test "world_stamp: next() yields unique stamps in debug, void in release" {
        if (comptime !enabled) {
            // Release: just check that next() returns void and compiles.
            const s: Stamp = next();
            _ = s;
            return;
        }
        const a: Stamp = next();
        const b: Stamp = next();
        const c: Stamp = next();
        try expect(a != b);
        try expect(b != c);
        try expect(a != c);
    }

    test "world_stamp: assertMatch is a no-op when stamps match" {
        if (comptime !enabled) {
            return;
        }
        const s: Stamp = next();
        // Should not panic.
        assertMatch("Handle(Test)", s, s);
    }

    test "world_stamp: assertMatch is a no-op when handle stamp is nil" {
        if (comptime !enabled) {
            return;
        }
        const world_s: Stamp = next();
        // Even though world's stamp != nil, handle's nil stamp short-circuits.
        assertMatch("Handle(Test)", nil_stamp, world_s);
    }

    // Note: mismatch case can't be tested via `expectError` (it panics, not
    // errors).  Manual verification or a dedicated `expectPanic` framework
    // would be needed.  The mechanism is simple enough that visual review
    // suffices; cross-world detection in practice will be exercised once
    // callers misuse it during normal development.
};

// =============================================================================
// Archetype storage internals (formerly nested in `pub const ecs`)
// =============================================================================
// Inlined to file scope so `Node`, `CmdBuf`, `Registry`, etc. can be
// referenced unqualified.  Most of this is private machinery used
// by `Entities(T)`; the public surface is `Node`, `CmdBuf`, and
// `Registry` (the raw archetype container, exposed for the few
// callers that want it without the `Entities` wrapper).

// ============================================================================
// meta - small comptime helpers
// ============================================================================

/// Small comptime utilities.  Used internally by other zig
/// machinery; exposed because they're broadly useful.
pub const meta = struct {
    /// True if `value` was known at compile time.  The trick:
    /// putting `value` into an anonymous-struct literal and
    /// asking whether that struct's first field was compiled as
    /// `comptime`.  Comptime values get the `comptime` annotation
    /// in the synthesized struct; runtime values don't.
    pub inline fn isComptimeKnown(value: anytype) bool {
        return @typeInfo(@TypeOf(.{value})).@"struct".field_attrs[0].@"comptime";
    }

    test isComptimeKnown {
        try expect(isComptimeKnown(123));
        const foo: comptime_int = 456;
        try expect(isComptimeKnown(foo));
        var bar: u8 = 123;
        bar += 1;
        try expect(!isComptimeKnown(bar));
    }

    /// Like `@offsetOf` but the path can dot-traverse nested
    /// structs.  `offsetOf(Line, "start.x")` walks Line→start
    /// (Vec2), then Vec2→x.  Escaped field names (`@"..."`) are
    /// not supported - assertion catches the `@` if you try.
    pub fn offsetOf(T: type, comptime path: []const u8) comptime_int {
        for (path) |c| {
            assert(c != '@', @src());
        }
        var Obj: type = T;
        var offset: comptime_int = 0;
        var parts = std.mem.splitScalar(u8, path, '.');
        while (parts.next()) |field| {
            offset += @offsetOf(Obj, field);
            Obj = @FieldType(Obj, field);
        }
        return offset;
    }

    test offsetOf {
        // Legit struct-with-named-fields use - @offsetOf needs a
        // field name, not an index.  Named `Point` rather than
        // Vec2 to avoid colliding with the codebase-wide ban on
        // `struct { x, y }` Vec2 aliases (turn 350 directive:
        // Vec2 = @Vector(2, f32) only).
        const Point = struct { x: f32, y: f32 };
        const Line = struct { start: Point, end: Point };

        try expectEqual(
            @offsetOf(Point, "x"),
            offsetOf(Point, "x"),
        );
        try expectEqual(
            @offsetOf(Point, "y"),
            offsetOf(Point, "y"),
        );

        try expectEqual(
            @offsetOf(Line, "start") + @offsetOf(Point, "x"),
            offsetOf(Line, "start.x"),
        );
        try expectEqual(
            @offsetOf(Line, "start") + @offsetOf(Point, "y"),
            offsetOf(Line, "start.y"),
        );
        try expectEqual(
            @offsetOf(Line, "end") + @offsetOf(Point, "x"),
            offsetOf(Line, "end.x"),
        );
        try expectEqual(
            @offsetOf(Line, "end") + @offsetOf(Point, "y"),
            offsetOf(Line, "end.y"),
        );
    }
};

// ============================================================================
// slot_map - persistent-key handle table
// ============================================================================

const SlotMapOptions = struct {
    /// The integer type used to index slots.
    Index: type = u32,
    /// The integer type used for the generation counter.  Larger = more
    /// allocations before a slot saturates and retires.
    Generation: type = u32,
};

/// A persistent-key handle table.
/// `init` reserves space; `put` returns a generation-tagged key; `get`
/// validates the key's generation against the slot's; `remove` invalidates
/// a key by bumping the generation (and retires the slot if it overflows).
pub fn SlotMap(comptime Value: type, comptime options: SlotMapOptions) type {
    return struct {
        const Self = @This();

        /// The integer types used for index and generation.
        pub const IndexInt = options.Index;
        pub const GenerationInt = options.Generation;

        /// A persistent-key handle.
        pub const Key = packed struct {
            /// Integer type used to index slots.  Exposed as `Key.Index` so
            /// other enums can use it as their backing type.
            pub const Index = IndexInt;

            /// A generation counter on a slot.  `.invalid` is reserved as the
            /// sentinel for retired/empty slots.
            pub const Generation = enum(GenerationInt) {
                /// The reserved generation for empty or retired slots.  Keys
                /// holding this generation never validate.
                invalid = 0,
                _,

                fn next(self: Generation) Generation {
                    return @fromBackingInt(@intCast(@backingInt(self) + 1));
                }

                fn isMax(self: Generation) bool {
                    return @backingInt(self) == maxInt(GenerationInt);
                }
            };

            /// The physical slot the value lives in.
            index: Index,
            /// The generation counter the slot had when this key was issued.
            generation: Generation,

            /// An optional Key.  Stores `.none` as `generation == .invalid`,
            /// which is never a valid issued key.
            pub const Optional = packed struct {
                pub const none: Optional = .{
                    .index = 0,
                    .generation = .invalid,
                };

                index: Index,
                generation: Generation,

                pub fn unwrap(self: Optional) ?Key {
                    if (self.generation == .invalid) {
                        return null;
                    }
                    return .{
                        .index = self.index,
                        .generation = self.generation,
                    };
                }

                pub fn eql(self: Optional, other: Optional) bool {
                    return self.index == other.index and self.generation == other.generation;
                }

                pub fn format(
                    self: Optional,
                    writer: *std.Io.Writer,
                ) std.Io.Writer.Error!void {
                    if (self.generation == .invalid) {
                        return writer.writeAll(".none");
                    }
                    try writer.print(
                        "0x{X}:{X}",
                        .{ self.index, @backingInt(self.generation) },
                    );
                }
            };

            pub fn eql(self: Key, other: Key) bool {
                return self.index == other.index and self.generation == other.generation;
            }

            pub fn toOptional(self: Key) Optional {
                return .{
                    .index = self.index,
                    .generation = self.generation,
                };
            }

            pub fn format(
                self: Key,
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                try writer.print(
                    "0x{X}:{X}",
                    .{ self.index, @backingInt(self.generation) },
                );
            }
        };

        /// One entry in the table.  When the slot is live, `generation` is
        /// non-`.invalid` and `value` is meaningful; when dead, `generation`
        /// is `.invalid` and `value` is undefined.
        pub const Slot = struct {
            generation: Key.Generation = .invalid,
            value: Value = undefined,
        };

        slots: []Slot,
        capacity: IndexInt,
        /// One past the highest slot ever used.  All slots `[0, next_index)`
        /// have been touched at least once; slots beyond that are pristine.
        next_index: IndexInt,
        /// Head of the free list (using `.invalid` if empty).  Re-uses
        /// `slots[i].value` interpreted as a `Key.Index` for the next free
        /// slot when slot `i` is on the list.  We can't store `next` in the
        /// `Slot` itself because `Value` may be smaller than `IndexInt`; we
        /// use a side array for it.
        free_head: Key.Index,
        free_next: []Key.Index,
        /// The number of live entries.
        live: IndexInt,
        /// The number of slots that have saturated and been retired.  These
        /// stay out of circulation forever.
        saturated: u64,

        const free_none: Key.Index = maxInt(IndexInt);

        pub fn init(gpa: Allocator, capacity: IndexInt) Allocator.Error!Self {
            assert(capacity < maxInt(IndexInt), @src());

            const slots = try gpa.alloc(Slot, capacity);
            errdefer gpa.free(slots);
            @memset(slots, .{});

            const free_next = try gpa.alloc(Key.Index, capacity);
            errdefer gpa.free(free_next);
            @memset(free_next, free_none);

            return .{
                .slots = slots,
                .capacity = capacity,
                .next_index = 0,
                .free_head = free_none,
                .free_next = free_next,
                .live = 0,
                .saturated = 0,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.slots);
            gpa.free(self.free_next);
            self.* = undefined;
        }

        /// Number of live entries.
        pub fn count(self: Self) IndexInt {
            return self.live;
        }

        /// Grow to at least `new_capacity` slots, preserving every live entry and its index
        /// (indices/keys are stable across a grow — only raw `*Slot`/value pointers into the old
        /// arrays are invalidated, so callers must hold none across this call). The free list is
        /// index-based and survives unchanged; `next_index`/`live`/`saturated` are untouched, so a
        /// subsequent `put` simply bump-allocates into the new tail. No-op if already large enough.
        pub fn grow(self: *Self, gpa: Allocator, new_capacity: IndexInt) Allocator.Error!void {
            if (new_capacity <= self.capacity) {
                return;
            }
            assert(new_capacity < maxInt(IndexInt), @src());
            const old_cap: usize = self.capacity;

            const new_slots: []Slot = try gpa.alloc(Slot, new_capacity);
            @memcpy(new_slots[0..old_cap], self.slots);
            @memset(new_slots[old_cap..], .{}); // pristine: generation .invalid
            gpa.free(self.slots);
            self.slots = new_slots;

            const new_free_next: []Key.Index = try gpa.alloc(Key.Index, new_capacity);
            @memcpy(new_free_next[0..old_cap], self.free_next);
            @memset(new_free_next[old_cap..], free_none);
            gpa.free(self.free_next);
            self.free_next = new_free_next;

            self.capacity = new_capacity;
        }

        /// Inserts a value, returning a key that will validate to it until
        /// the slot is recycled or retired.
        pub fn put(self: *Self, value: Value) error{Overflow}!Key {
            // Try to reuse a slot from the free list first.
            if (self.free_head != free_none) {
                const idx_int = self.free_head;
                self.free_head = self.free_next[idx_int];
                self.free_next[idx_int] = free_none;

                // The slot's generation has already been bumped on remove;
                // its current value is the next valid one to issue.
                const slot = &self.slots[idx_int];
                slot.value = value;
                self.live += 1;
                return .{
                    .index = idx_int,
                    .generation = slot.generation,
                };
            }

            // No free slots; bump-allocate from the back.
            if (self.next_index >= self.capacity) {
                return error.Overflow;
            }

            const idx_int = self.next_index;
            self.next_index += 1;

            const slot = &self.slots[idx_int];
            // Pristine slots begin at `.invalid`; bump to the first valid
            // generation (1) when issuing the key.
            slot.generation = (Key.Generation.invalid).next();
            slot.value = value;
            self.live += 1;
            return .{
                .index = idx_int,
                .generation = slot.generation,
            };
        }

        /// Returns `true` if the key still validates against its slot.
        pub fn containsKey(self: *const Self, key: Key) bool {
            const idx_int = key.index;
            if (idx_int >= self.next_index) {
                return false;
            }
            return self.slots[idx_int].generation == key.generation and key.generation != .invalid;
        }

        /// Returns a pointer to the value if the key still validates, or
        /// `null` otherwise.
        pub fn get(self: anytype, key: Key) ?@TypeOf(&self.slots[0].value) {
            const idx_int = key.index;
            if (idx_int >= self.next_index) {
                return null;
            }
            const slot = &self.slots[idx_int];
            if (slot.generation != key.generation or key.generation == .invalid) {
                return null;
            }
            return &slot.value;
        }

        /// Invalidates a key and returns its slot to the free list. The slot's generation is
        /// bumped so the old key no longer validates; on overflow it WRAPS to the first valid
        /// generation rather than retiring the slot (see the body for the rationale and the
        /// one-cycle-aliasing contract). Has no effect if the key has already been invalidated.
        pub fn remove(self: *Self, key: Key) void {
            const idx_int = key.index;
            if (idx_int >= self.next_index) {
                return;
            }
            const slot = &self.slots[idx_int];
            if (slot.generation != key.generation or key.generation == .invalid) {
                return;
            }

            self.live -= 1;

            // Bump the generation so stale keys never validate, then return the slot to the
            // free list for reuse. At the max generation, wrap past the reserved `.invalid`
            // sentinel to the first valid generation rather than retiring the slot — slots stay
            // reusable forever under heavy churn (the washer churns thousands of bodies/sec).
            //
            // ABA contract: a freshly issued key can alias a long-dead holder of the same slot
            // only after the generation wraps the full 2^bits range of THAT exact slot. Don't
            // stash a Key across that many reuses of its slot; for the transient per-frame handles
            // that churn this fast, the window is unreachable in practice.
            if (slot.generation.isMax()) {
                slot.generation = Key.Generation.invalid.next();
            } else {
                slot.generation = slot.generation.next();
            }
            slot.value = undefined;
            self.free_next[idx_int] = self.free_head;
            self.free_head = key.index;
        }

        /// Like `remove`, but does not bump the generation.  This means old
        /// keys WILL still validate; only meaningful as part of a bulk reset
        /// (`recycleAll`) where the caller knows none of those keys will be
        /// dereferenced again.
        pub fn recycle(self: *Self, key: Key) void {
            const idx_int = key.index;
            if (idx_int >= self.next_index) {
                return;
            }
            const slot = &self.slots[idx_int];
            if (slot.generation != key.generation or key.generation == .invalid) {
                return;
            }

            self.live -= 1;
            slot.value = undefined;
            self.free_next[idx_int] = self.free_head;
            self.free_head = key.index;
        }

        /// Resets the table: every slot becomes free, generations are kept
        /// (so the saturated set remains retired).  All previously-issued
        /// keys are now dangling.
        pub fn recycleAll(self: *Self) void {
            // Walk all touched slots and rebuild the free list with the live
            // ones.  Skip retired (`.invalid`) slots.
            self.free_head = free_none;
            @memset(self.free_next, free_none);
            self.live = 0;

            var i: IndexInt = 0;
            while (i < self.next_index) : (i += 1) {
                const slot = &self.slots[i];
                if (slot.generation == .invalid) {
                    continue; // retired
                }
                slot.value = undefined;
                self.free_next[i] = self.free_head;
                self.free_head = i;
            }
        }
    };
}

test "smoke" {
    const Map = SlotMap(u32, .{});
    var m: Map = try .init(std.testing.allocator, 8);
    defer m.deinit(std.testing.allocator);

    const k0: Map.Key = try m.put(100);
    const k1: Map.Key = try m.put(200);
    try expect(m.containsKey(k0));
    try expectEqual(@as(u32, 100), m.get(k0).?.*);
    try expectEqual(@as(u32, 200), m.get(k1).?.*);
    try expectEqual(@as(u32, 2), m.count());

    m.remove(k0);
    try expect(!m.containsKey(k0));
    try expect(m.get(k0) == null);
    try expectEqual(@as(u32, 1), m.count());

    // Re-allocating reuses the slot but with a new generation.
    const k2: Map.Key = try m.put(300);
    try expectEqual(k0.index, k2.index);
    try expect(k0.generation != k2.generation);
    try expect(!m.containsKey(k0));
    try expect(m.containsKey(k2));
}

test "overflow" {
    const Map = SlotMap(u32, .{});
    var m: Map = try .init(std.testing.allocator, 2);
    defer m.deinit(std.testing.allocator);

    _ = try m.put(1);
    _ = try m.put(2);
    try expectError(error.Overflow, m.put(3));
}

test "optional" {
    const Map = SlotMap(u32, .{});
    var m: Map = try .init(std.testing.allocator, 4);
    defer m.deinit(std.testing.allocator);

    const k: Map.Key = try m.put(42);
    const opt: Map.Key.Optional = k.toOptional();
    try expectEqual(k, opt.unwrap().?);

    const none = Map.Key.Optional.none;
    try expect(none.unwrap() == null);
}

// ============================================================================
// PointerLock - pointer stability assertion
// ============================================================================

pub const PointerLock = struct {
    /// Pointer stability assertions for builds with runtime safety enabled.
    const enabled = std.debug.runtime_safety;

    /// The current pointer generation.
    pub const Generation = struct {
        n: if (enabled) u64 else u0 = 0,

        /// Increments the pointer generation.
        pub inline fn increment(self: *@This()) void {
            if (enabled) {
                self.n +%= 1;
            }
        }

        /// Returns a pointer lock with the current generation.
        pub inline fn lock(self: @This()) PointerLock {
            return .{ .generation = self };
        }
    };

    /// The pointer generation from when this lock was created.
    generation: Generation,

    /// Asserts that pointers have not been invalidated since this lock was created.
    pub fn check(self: @This(), generation: Generation) void {
        if (self.generation.n != generation.n) {
            @panic("pointers invalidated");
        }
    }
};

// ============================================================================
// TypeInfo, TypeId, typeId - runtime type identity
// ============================================================================

/// Pure-data identity record for a component type.  Two pointers
/// to TypeInfo compare equal iff they were produced by `typeId(T)`
/// for the same `T` - the comptime-allocated singleton trick gives
/// us address-stable type identity without any runtime mutation.
/// **No runtime-mutable state lives here.**  The CompFlag mapping
/// (which moves slot indices around as components get registered)
/// belongs to whichever `Registry` instance you registered with
/// see `Registry.registerComponent`, `Registry.getCompFlag`.
pub const TypeInfo = struct {
    /// The maximum allowed alignment.
    pub const max_align: std.mem.Alignment = .@"16";

    /// The component's type name.
    name: [:0]const u8,
    /// The component type's size.
    size: usize,
    /// The component type's alignment.
    alignment: u8,

    /// Returns the type ID for the given type.  The returned pointer
    /// is comptime-stable across the whole program: every call to
    /// `typeId(T)` returns the same address, so `*const TypeInfo`
    /// comparisons work for type identity.  The pointee is `const`
    /// - no runtime mutation, no globals.
    pub inline fn init(comptime T: type) *const @This() {
        comptime checkType(T);

        return &struct {
            const info: TypeInfo = .{
                .name = @typeName(T),
                .size = @sizeOf(T),
                .alignment = @alignOf(T),
            };
        }.info;
    }

    /// Asserts at compile time that mr_ecs's runtime type information supports this type.
    pub fn checkType(T: type) void {
        // Storing optionals, pointers, and `Entity` directly as components would create
        // ambiguities when creating entity views. It's unfortunate that we have to disallow
        // them, but the extra typing to wrap them in the rare case that you need this ability
        // is expected to be well worth it for the convenience views provide.
        // There's no reason these couldn't be allowed for `Any` in general, but we want to get
        // compile time errors when trying to use bad types, so we just rule them out for any use of
        // `Any` instead.
        // `Entity.Index` and `CmdBuf` are likely indicative of a mistake and so are ruled
        // out.
        if (@typeInfo(T) == .optional or
            // Same blacklist also rules out Entity/Entity.Index, and Entity registers its
            // component types via typeId (= TypeInfo.init) - a TypeInfo<->Entity cycle.
            // lint:off decl-order: TypeInfo<->Entity cycle (component-type blacklist)
            T == Entity or
            T == Entity.Index or
            // TypeInfo/Any blacklists CmdBuf as a component type, and CmdBuf records typed
            // ops via typeId (= TypeInfo.init) - a TypeInfo<->CmdBuf cycle. Naming CmdBuf
            // directly is the simplest guard; a marker trait would only add indirection.
            // lint:off decl-order: TypeInfo<->CmdBuf cycle (component-type blacklist)
            T == CmdBuf)
        {
            @compileError("unsupported component type '" ++ @typeName(T) ++ "'; consider wrapping in struct");
        }

        comptime assert(@alignOf(T) <= max_align.toByteUnits(), @src());
    }
};

/// This pointer can be used as a unique ID identifying a component type.
pub const TypeId = *const TypeInfo;

pub const typeId = TypeInfo.init;

// ============================================================================
// Any - type-erased pointer
// ============================================================================

pub const Any = struct {
    id: TypeId,
    ptr: *const anyopaque,

    /// Initialize a component from a pointer to a component type.
    pub fn init(T: type, ptr: *const T) @This() {
        return .{
            .id = typeId(T),
            .ptr = ptr,
        };
    }

    /// Returns the component as the given type if it matches its ID, or null otherwise.
    pub fn as(self: @This(), T: anytype) ?*const T {
        if (self.id != typeId(T)) {
            @branchHint(.unlikely);
            return null;
        }
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Returns the component as a constant slice of `u8`s.
    pub fn constSlice(self: @This()) []const u8 {
        return self.bytes()[0..self.id.size];
    }

    /// Similar to `constSlice`, but returns the data as a many item pointer.
    pub fn bytes(self: @This()) [*]const u8 {
        return @ptrCast(self.ptr);
    }
};

// ============================================================================
// CompFlag - registered component-type flag
// ============================================================================

/// The tag type for `Flag`.
const FlagInt = u6;

/// A tightly packed index for each registered component type.  The
/// mapping `TypeId → CompFlag` is owned by the `Registry` instance
/// (see `Registry.registerComponent`).  This enum is just the slot
/// width - knowing "I'm flag 7 in some world" tells you nothing
/// about which world or which type without going through that
/// world's flag table.
pub const CompFlag = enum(FlagInt) {
    /// The maximum registered component flags (one per CompFlag value).
    pub const max = maxInt(FlagInt);

    /// A set of component flags.  Used to describe an archetype as
    /// a packed bitset over the world's component-flag space.
    pub const Set = std.enums.EnumSet(CompFlag);

    _,
};

// ============================================================================
// viewLib - comptime helpers for entity views
// ============================================================================

/// Comptime helpers for "View" types - user-defined structs of
/// component pointers that drive iteration.  `iterator(View)` and
/// `forEachView` consume these.
/// A View is a struct where each field is one of:
///   - `*T` / `*const T` for component-by-value access
///   - `?*T` / `?*const T` for components that may not be present
///   - `Entity` to receive the entity handle itself
///   - (slice-mode only) `[]T` / `[]const T` / `[]const Entity.Index`
/// Slice-mode views (returned by `Chunk.view`) replace each
/// pointer with the corresponding slice over a whole chunk.
pub const viewLib = struct {
    /// Whether the View asks for one entity at a time (for
    /// per-entity iteration) or whole chunks at once (for
    /// chunk-batched iteration).
    pub const ViewOptions = struct {
        size: std.builtin.Type.Pointer.Size,
    };

    /// Pull the underlying component type out of a view-field
    /// type.  `?*const Position` → `Position`; `[]const Velocity`
    /// → `Velocity`; `Entity` → `Entity`; `[]const Entity.Index`
    /// → `Entity.Index`.
    pub fn UnwrapField(T: type, options: ViewOptions) type {
        // Single-entity view directly carries `Entity`.
        if (options.size == .one and T == Entity) {
            return Entity;
        }

        const SomePtr: type = Unwrap(T);
        comptime assert(@typeInfo(SomePtr).pointer.size == options.size, @src());
        const Result: type = @typeInfo(SomePtr).pointer.child;

        // Slice-mode view of `[]const Entity.Index` is the bulk
        // analogue of single-entity `Entity` - returned as-is so
        // chunk iteration can hand back the index slice.
        if (options.size != .one and Result == Entity.Index) {
            comptime assert(@typeInfo(T) != .optional, @src());
            comptime assert(@typeInfo(T).pointer.attrs.@"const" == true, @src());
            return Result;
        }

        TypeInfo.checkType(Result);
        return Result;
    }

    /// Build one entity-View from an index into the per-chunk
    /// slice-View `slices`.  Used inside `Iterator(View).next`
    /// to materialise each step.
    pub fn index(
        View: type,
        // viewLib's helpers take *const Registry to read component slices, while Registry
        // runs all its queries through viewLib (15 call sites) - a viewLib<->Registry cycle.
        // lint:off decl-order: viewLib<->Registry cycle (views read the registry)
        es: *const Registry,
        slices: anytype,
        i: u32,
    ) View {
        var result: View = undefined;
        inline for (@typeInfo(View).@"struct".field_names, slices) |field_name, slice| {
            if (UnwrapField(@TypeOf(slice), .{ .size = .slice }) == Entity.Index) {
                const entity_index: Entity.Index = slice[i];
                @field(result, field_name) = entity_index.toEntity(es);
            } else {
                @field(result, field_name) = switch (@typeInfo(@TypeOf(slice))) {
                    .optional => if (slice) |unwrapped| &unwrapped[i] else null,
                    else => &slice[i],
                };
            }
        }
        return result;
    }

    /// Collect the CompFlag.Set the View requires.  Returns null
    /// if any required (non-optional, non-Entity) component isn't
    /// registered with `es` yet - in which case no entity can
    /// possibly satisfy the View, and the iterator short-circuits
    /// to empty.  Optional fields and `Entity` fields don't
    /// contribute to the required set.
    pub inline fn comps(
        es: *const Registry,
        T: type,
        options: ViewOptions,
    ) ?CompFlag.Set {
        var arch: CompFlag.Set = .{};
        inline for (@typeInfo(T).@"struct".field_types) |field_type| {
            const is_required: bool = field_type != Entity and @typeInfo(field_type) != .optional;
            if (is_required) {
                const Unwrapped: type = UnwrapField(field_type, options);
                if (Unwrapped == Entity.Index) {
                    continue;
                }
                const flag: CompFlag = es.getCompFlag(typeId(Unwrapped)) orelse return null;
                arch.insert(flag);
            }
        }
        return arch;
    }

    /// Lift an entity-View type to its slice-View counterpart.
    /// `struct { p: *Position, v: *const Velocity, e: Entity }`
    /// → `struct { p: []Position, v: []const Velocity, e: []const Entity.Index }`
    /// (as a tuple-struct).  Used by `Chunk.view` to materialise
    /// the slice-shaped view a chunk wants.
    pub fn Slice(EntityView: type) type {
        const entity_view_types = @typeInfo(EntityView).@"struct".field_types;
        comptime var field_types: [entity_view_types.len]type = undefined;
        inline for (&field_types, entity_view_types) |*field_type, T| {
            const S: type = b: {
                if (T == Entity) {
                    break :b []const Entity.Index;
                }

                const Ptr: type = switch (@typeInfo(T)) {
                    .optional => |optional| optional.child,
                    .pointer => T,
                    else => @compileError("expected pointer, found " ++ @typeName(T)),
                };
                if (@typeInfo(Ptr) != .pointer) {
                    @compileError("expected pointer, found " ++ @typeName(T));
                }
                const Child: type = @typeInfo(Ptr).pointer.child;
                const S: type = if (@typeInfo(Ptr).pointer.attrs.@"const") []const Child else []Child;
                break :b if (@typeInfo(T) == .optional) ?S else S;
            };
            field_type.* = S;
        }
        return @Tuple(&field_types);
    }

    /// Type list of `T`'s function-type parameters.  Used by
    /// `forEach` / `forEachView` to derive the View shape from
    /// the user's update function signature.
    pub fn params(T: type) [@typeInfo(T).@"fn".param_types.len]type {
        var results: [@typeInfo(T).@"fn".param_types.len]type = undefined;
        inline for (&results, @typeInfo(T).@"fn".param_types) |*result, param| {
            result.* = if (param) |Param| Param else {
                @compileError("cannot get type of `anytype` parameter");
            };
        }
        return results;
    }

    /// Build a tuple type from a slice of types.  Like
    /// `std.meta.Tuple` but skips the `setEvalBranchQuota` call
    /// (we control the call sites and they're shallow).
    pub fn Tuple(types: []const type) type {
        comptime var field_types: [types.len]type = undefined;
        inline for (&field_types, types) |*field_type, param| {
            field_type.* = param;
        }
        return @Tuple(&field_types);
    }

    /// `?T` → `T`, anything else → unchanged.
    pub fn Unwrap(T: type) type {
        return switch (@typeInfo(T)) {
            .optional => |optional| optional.child,
            else => T,
        };
    }
};

// ============================================================================
// HandleTab
// ============================================================================

/// Persistent handle table keyed by `Entity`.  Uses an 8-bit
/// generation: each slot tolerates 254 alloc/free cycles before
/// retiring (slot 0 is reserved as the nil sentinel; generation 0
/// is reserved as `.invalid`).  This matches the cycle byte used by
/// the cpool side in `entities.Registry`, removing the need for
/// the previous parallel `ecs_gens` array that synced 32-bit ECS
/// generations to 8-bit cpool cycles.
/// For zimr's typical workload - per-frame entity churn well under
/// 256 per slot - this is plenty.  Long-lived entities don't churn;
/// short-lived ones get a fresh slot if their original retires.
pub const HandleTab = SlotMap(Entity.Location, .{ .Generation = u8 });

// ============================================================================
// Entity - persistent entity handle
// ============================================================================

/// Map from archetype (a bitset of CompFlags) to its `ChunkList`.
/// Backed by an `ArrayHashMapUnmanaged` with pointers locked - once
/// you've fetched a `*ChunkList`, it stays valid until the next
/// resize-driving operation, which only happens through the
/// controlled `getOrPut` / `clear` paths below.
/// "Archetype" = which components an entity has, packed as a
/// `CompFlag.Set` bitfield.  Two entities sharing an archetype
/// share storage layout and live in the same chunk list.
pub const Arches = struct {
    capacity: u32,
    map: std.ArrayHashMapUnmanaged(
        CompFlag.Set,
        // Arches stores ChunkLists, and ChunkList threads back to its Arches (getOrPut,
        // archetype transitions) - one archetype-storage SCC with Chunk/ChunkPool/Registry.
        // lint:off decl-order: Arches<->ChunkList cycle (archetype storage SCC)
        ChunkList,
        struct {
            pub fn eql(_: @This(), lhs: CompFlag.Set, rhs: CompFlag.Set, _: usize) bool {
                return lhs.eql(rhs);
            }
            // Hash the bit-set's raw bytes.  Can't reach into a
            // named field (`.mask` for `IntegerBitSet`, `.masks`
            // for `ArrayBitSet`) because `EnumSet(N)` picks
            // between the two based on whether N fits in
            // `@bitSizeOf(usize)` - and that differs between
            // wasm32 (usize = 32) and the typical 64-bit host.
            // Hashing bytes works for both shapes.
            pub fn hash(_: @This(), key: CompFlag.Set) u32 {
                return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&key.bits)));
            }
        },
        false,
    ),

    /// Pre-allocate the archetype map and lock its pointers.
    /// We over-reserve by one slot so `getOrPut` can stage a
    /// tentative insert into the spare slot, then either keep
    /// it or `swapRemove` on the error path.
    pub fn init(gpa: Allocator, capacity: u32) Allocator.Error!@This() {
        var map: @FieldType(@This(), "map") = .{};
        errdefer map.deinit(gpa);
        try map.ensureTotalCapacity(gpa, @as(u32, capacity) + 1);
        map.lockPointers();
        return .{
            .capacity = capacity,
            .map = map,
        };
    }

    /// Free the map.  After this `self.*` is undefined.
    pub fn deinit(self: *@This(), gpa: Allocator) void {
        self.map.unlockPointers();
        self.map.deinit(gpa);
        self.* = undefined;
    }

    /// Drop every archetype but keep the underlying allocation.
    /// Equivalent to "freshly initialized" for usage but skips
    /// the ensureTotalCapacity round-trip.
    pub fn clear(self: *@This()) void {
        self.map.unlockPointers();
        self.map.clearRetainingCapacity();
        self.map.lockPointers();
    }

    /// Find or create the chunk list for `arch`.
    /// The `getOrPutAssumeCapacity` + `errdefer swapRemove` shape
    /// works around the standard library not having a "get-or-put
    /// that returns OOM" - we always have one slot of headroom
    /// (reserved in `init`), insert into it tentatively, and
    /// swap-remove on error.  Pointers stay valid because
    /// swapRemove only moves the slot we just inserted.
    pub fn getOrPut(
        self: *@This(),
        es: *const Registry,
        // ChunkPool feeds Chunks into Arches' ChunkLists, and Chunk/ChunkList/Registry all
        // thread back to Arches - the same archetype-storage SCC; this is one of its back-edges.
        // lint:off decl-order: Arches<->ChunkPool cycle (archetype storage SCC)
        cpool: *const ChunkPool,
        arch: CompFlag.Set,
    ) error{ EcsChunkOverflow, EcsArchOverflow }!*ChunkList {
        const gop: @TypeOf(self.map).GetOrPutResult = self.map.getOrPutAssumeCapacity(arch);
        errdefer if (!gop.found_existing) {
            @branchHint(.cold);
            // swapRemove needs unlocked pointers, but it only
            // touches the slot we just added - already-stored
            // indices are unchanged.
            self.map.unlockPointers();
            assert(self.map.swapRemove(arch), @src());
            self.map.lockPointers();
        };
        if (!gop.found_existing) {
            @branchHint(.unlikely);
            if (self.map.count() > self.capacity) {
                return error.EcsArchOverflow;
            }
            gop.value_ptr.* = try .init(es, cpool, arch);
        }
        return gop.value_ptr;
    }

    /// Reverse-lookup a chunk list's index in this map.  Same
    /// shape as `ChunkPool.indexOf` - the index IS the position
    /// of the value in the underlying ArrayHashMap's value slice.
    pub fn indexOf(lists: *const @This(), self: *const ChunkList) ChunkList.Index {
        const vals: []ChunkList = lists.map.values();
        assert(@intFromPtr(self) >= @intFromPtr(vals.ptr), @src());
        assert(@intFromPtr(self) < @intFromPtr(vals.ptr) + vals.len * @sizeOf(ChunkList), @src());

        const offset: usize = @intFromPtr(self) - @intFromPtr(vals.ptr);
        const index: usize = offset / @sizeOf(ChunkList);
        return @fromBackingInt(@intCast(index));
    }

    /// Filter for `iterator`.  An archetype is yielded iff it
    /// contains every comp in `require` AND no comp in `skip`.
    pub const IteratorOptions = struct {
        require: CompFlag.Set = .{},
        skip: CompFlag.Set = .{},
    };

    /// Walk every archetype matching `options`.  Locks the
    /// world's pointer generation; mutating ops during iteration
    /// trip the safety check in `Iterator.next`.
    pub fn iterator(
        self: @This(),
        es: *const Registry,
        options: IteratorOptions,
    ) Iterator {
        return .{
            .require = options.require,
            .skip = options.skip,
            .all = self.map.iterator(),
            .pointer_lock = es.pointer_generation.lock(),
        };
    }

    /// Filtered iterator over chunk lists.
    pub const Iterator = struct {
        require: CompFlag.Set,
        skip: CompFlag.Set,
        all: @FieldType(Arches, "map").Iterator,
        pointer_lock: PointerLock,

        /// An iterator that yields nothing.  Used as the
        /// initial state when no archetype matches a View.
        pub fn empty(es: *const Registry) @This() {
            return .{
                .require = .{},
                .skip = .{},
                .all = b: {
                    const map: @FieldType(Arches, "map") = .{};
                    break :b map.iterator();
                },
                .pointer_lock = es.pointer_generation.lock(),
            };
        }

        /// Advance to the next archetype matching the filter,
        /// or null when exhausted.  Skipped archetypes don't
        /// count toward the iteration - the loop just keeps
        /// stepping internally until it finds one.
        pub fn next(self: *@This(), es: *const Registry) ?*const ChunkList {
            self.pointer_lock.check(es.pointer_generation);
            while (self.all.next()) |item| {
                const matches_require: bool = item.key_ptr.*.supersetOf(self.require);
                const has_no_skip: bool = item.key_ptr.*.intersectWith(self.skip).eql(.{});
                if (matches_require and has_no_skip) {
                    return item.value_ptr;
                }
            }
            return null;
        }
    };
};

/// A chunk of entity data where each entity has the same archetype. This type is mostly used
/// internally, you should prefer the higher level API in most cases.
pub const Chunk = opaque {
    /// A chunk's index in its `ChunkPool`.
    pub const Index = enum(u32) {
        /// The none index. The capacity is always less than this value, so there's no overlap.
        none = maxInt(u32),
        _,

        /// Resolve a chunk index back to its `*Chunk`.  Returns
        /// null for `.none` (the sentinel for "no such chunk").
        /// The `byte_idx` shift exploits chunks being aligned to
        /// chunk-size in the cpool buffer - index N starts at byte
        /// `N << log2(chunk_size)`.
        pub fn get(self: Index, cpool: *const ChunkPool) ?*Chunk {
            if (self == .none) {
                return null;
            }
            const byte_idx: u32 = @shlExact(
                @backingInt(self),
                @intCast(@backingInt(cpool.size_align)),
            );
            const result: *Chunk = @ptrCast(&cpool.buf[byte_idx]);
            assert(@backingInt(self) < cpool.reserved, @src());
            assert(cpool.indexOf(result) == self, @src());
            return result;
        }
    };

    /// Per-chunk metadata.  Lives at offset 0 of every chunk; the
    /// component buffers + index buffer follow it in memory.
    pub const Header = struct {
        /// Per-component byte offset from the chunk start, or 0
        /// when the component isn't part of this chunk's
        /// archetype.  Sized for every possible CompFlag in the
        /// world (sparse - most slots are 0).
        /// This duplicates state that `ChunkList` already knows,
        /// but inlining the offsets here measurably reduces cache
        /// misses on the hot iteration path.
        comp_buf_offsets: std.enums.EnumArray(CompFlag, u32),
        /// Which `ChunkList` this chunk belongs to, or `.none` if
        /// free in the cpool.
        list: ChunkList.Index,
        /// Linked-list of all chunks in the same `ChunkList`
        /// next, then previous.
        next: Index = .none,
        prev: Index = .none,
        /// Linked-list of chunks in the same `ChunkList` that
        /// still have free slots.  Separate from `next`/`prev`
        /// because not every chunk is available (some are full).
        next_avail: Index = .none,
        prev_avail: Index = .none,
        /// Number of entities currently stored in this chunk.
        /// Range `[1, chunk_capacity]`; zero means free, and free
        /// chunks return to the cpool rather than staying empty.
        len: u32,

        /// This chunk's archetype.  When checking a single
        /// component, prefer `comp_buf_offsets` - it's larger but
        /// closer in memory than walking through the chunk list.
        pub fn arch(self: *const @This(), lists: *const Arches) CompFlag.Set {
            return self.list.arch(lists);
        }
    };

    /// Byte offset from the chunk start to a component buffer.
    /// `none` (== 0) means "this chunk doesn't include that
    /// component" - the chunk header is at offset 0, so 0 is a
    /// safe sentinel.
    pub const CompBufOffset = enum(u32) {
        none = 0,
        _,

        /// Unwrap to a non-zero offset, or null if `.none`.
        pub inline fn unwrap(self: @This()) ?u32 {
            const result: u32 = @backingInt(self);
            if (result == 0) {
                return null;
            }
            return result;
        }
    };

    /// Walk the chunk's invariants and assert each.  No-op when
    /// `runtime_safety` is off.  Sprinkled around mutation entry
    /// points to catch linked-list corruption early.
    pub fn checkAssertions(
        self: *Chunk,
        es: *const Registry,
        mode: enum {
            /// Default: an empty chunk is a bug - empty chunks
            /// would have been returned to the cpool.
            default,
            /// For freshly-allocated chunks and chunks about to
            /// be cleared, skip the "must be non-empty" assert.
            allow_empty,
        },
    ) void {
        if (!std.debug.runtime_safety) {
            return;
        }

        const list: *ChunkList = self.header().list.get(&es.arches);
        const cpool: *const ChunkPool = &es.chunk_pool;

        // Doubly-linked: next.prev == self, prev.next == self.
        if (self.header().next.get(cpool)) |next_chunk| {
            assert(next_chunk.header().prev.get(cpool) == self, @src());
        }
        if (self.header().prev.get(cpool)) |prev_chunk| {
            assert(prev_chunk.header().next.get(cpool) == self, @src());
        }

        // List head has no prev; list tail has no next.
        if (self == list.head.get(cpool)) {
            assert(self.header().prev == .none, @src());
        }
        if (self == list.tail.get(cpool)) {
            assert(self.header().next == .none, @src());
        }

        const is_full: bool = self.header().len >= list.chunk_capacity;
        if (is_full) {
            // Full chunks: len == capacity exactly, and they're
            // OFF the available list (no next/prev avail links).
            assert(self.header().len == list.chunk_capacity, @src());
            assert(self.header().next_avail == .none, @src());
            assert(self.header().prev_avail == .none, @src());
        } else {
            // Available chunks must not be empty - empty ones go
            // back to the cpool.  `allow_empty` overrides this for
            // about-to-be-cleared chunks.
            assert(mode == .allow_empty or self.header().len > 0, @src());

            // The available-list is its own doubly-linked list
            // running through the same chunks.
            if (self.header().next_avail.get(cpool)) |next_avail_chunk| {
                assert(next_avail_chunk.header().prev_avail.get(cpool) == self, @src());
            }
            if (self.header().prev_avail.get(cpool)) |prev_avail_chunk| {
                assert(prev_avail_chunk.header().next_avail.get(cpool) == self, @src());
            }
            if (self == list.avail.get(cpool)) {
                assert(self.header().prev_avail == .none, @src());
            }
        }
    }

    /// Returns a pointer to the chunk header.
    pub inline fn header(self: *Chunk) *Header {
        return @ptrCast(@alignCast(self));
    }

    /// Empty the chunk's entity data and return it to the
    /// cpool's free list.  Unwires this chunk from both the
    /// archetype's main list AND its available-list, then
    /// nukes the header so reuse starts fresh.
    pub fn clear(self: *Chunk, es: *Registry) void {
        const cpool: *ChunkPool = &es.chunk_pool;
        const index: Index = cpool.indexOf(self);
        const list: *ChunkList = self.header().list.get(&es.arches);

        self.checkAssertions(es, .allow_empty);

        // If we ARE the head/tail/avail-head, the list's anchor
        // moves to whatever we point at next.
        if (list.head == index) {
            list.head = self.header().next;
        }
        if (list.tail == index) {
            list.tail = self.header().prev;
        }
        if (list.avail == index) {
            list.avail = self.header().next_avail;
        }

        // Splice ourselves out of both linked lists (main +
        // available).  Each side updates its peer's back-pointer
        // to skip us.
        if (self.header().prev.get(cpool)) |prev| {
            prev.header().next = self.header().next;
        }
        if (self.header().next.get(cpool)) |next| {
            next.header().prev = self.header().prev;
        }
        if (self.header().prev_avail.get(cpool)) |prev| {
            prev.header().next_avail = self.header().next_avail;
        }
        if (self.header().next_avail.get(cpool)) |next| {
            next.header().prev_avail = self.header().prev_avail;
        }

        // Header gets nuked, then we cons onto the cpool's free
        // list (intrusive single-link via `next`).
        self.header().* = undefined;
        self.header().next = es.chunk_pool.free;
        es.chunk_pool.free = index;

        list.checkAssertions(es);
    }

    /// Materialize a `View` (struct of slices) over every entity
    /// in this chunk.  Returns `null` if any required component
    /// in `View` isn't part of this chunk's archetype.
    /// `View` shape: each field is `[]T`, `[]const T`, `?[]T`, or
    /// `[]const Entity.Index`.  Optional slice fields are filled
    /// with `null` for components the chunk doesn't carry.
    pub fn view(
        self: *@This(),
        es: *const Registry,
        View: type,
    ) ?View {
        const list: *ChunkList = self.header().list.get(&es.arches);

        // Required component set for the View - null if any type
        // in View isn't even registered with this world.
        const view_arch: CompFlag.Set = viewLib.comps(es, View, .{ .size = .slice }) orelse
            return null;
        const chunk_arch: CompFlag.Set = self.header().arch(&es.arches);
        if (!chunk_arch.supersetOf(view_arch)) {
            return null;
        }

        var result: View = undefined;
        const view_info = @typeInfo(View).@"struct";
        inline for (view_info.field_names, view_info.field_types) |field_name, field_type| {
            const As: type = viewLib.UnwrapField(field_type, .{ .size = .slice });
            if (As == Entity.Index) {
                // Entity.Index lives in its own per-chunk slot,
                // not the per-component buffers.
                const unsized: [*]As = @ptrFromInt(@intFromPtr(self) + list.index_buf_offset);
                @field(result, field_name) = unsized[0..self.header().len];
            } else {
                // https://codeberg.org/Games-by-Mason/mr_ecs/issues/24
                const offset: u32 = if (es.getCompFlag(typeId(As))) |flag|
                    self.header().comp_buf_offsets.values[@backingInt(flag)]
                else
                    0;
                const is_missing_optional: bool =
                    @typeInfo(field_type) == .optional and offset == 0;
                if (is_missing_optional) {
                    @field(result, field_name) = null;
                } else {
                    assert(offset != 0, @src()); // archetype check above guarantees this
                    const unsized: [*]As = @ptrFromInt(@intFromPtr(self) + offset);
                    @field(result, field_name) = unsized[0..self.header().len];
                }
            }
        }
        return result;
    }

    /// Like `view`, but for a single runtime-typed component
    /// rather than a comptime View struct.  Returns the raw
    /// `[]u8` covering all entities in the chunk for that comp;
    /// caller `@ptrCast`s back to the real type.  Null when the
    /// component isn't registered with this world or isn't in
    /// the chunk's archetype.
    pub fn compsFromId(
        self: *Chunk,
        es: *const Registry,
        id: TypeId,
    ) ?[]u8 {
        const flag: CompFlag = es.getCompFlag(id) orelse return null;
        // https://codeberg.org/Games-by-Mason/mr_ecs/issues/24
        const offset: u32 = self.header().comp_buf_offsets.values[@backingInt(flag)];
        if (offset == 0) {
            return null;
        }
        const ptr: [*]u8 = @ptrFromInt(@intFromPtr(self) + offset);
        return ptr[0 .. self.header().len * id.size];
    }

    /// Drop the entity at `index_in_chunk` from this chunk and
    /// fill the hole by moving the last entity into the slot.
    /// Standard SoA swap-remove: O(1), reorders entities, updates
    /// the moved entity's `Location.index_in_chunk` in the handle
    /// table.
    /// Internal - external code should use `Entity.destroy` /
    /// `Entity.destroyImmediate` instead, which know about
    /// archetype membership and pointer-lock invalidation.
    pub fn swapRemove(
        self: *@This(),
        es: *Registry,
        index_in_chunk: Entity.Location.IndexInChunk,
    ) void {
        const cpool: *ChunkPool = &es.chunk_pool;
        const index: Index = cpool.indexOf(self);
        const list: *ChunkList = self.header().list.get(&es.arches);
        const was_full: bool = self.header().len >= list.chunk_capacity;

        // The last entity in the chunk - the one we're going to
        // hoist into the freed slot.  `@constCast` is safe: the
        // view returned a `const` slice but we own the storage.
        const indices = @constCast(self.view(es, struct {
            indices: []const Entity.Index,
        }).?.indices);
        const new_len: u32 = self.header().len - 1;
        const moved: Entity.Index = indices[new_len];

        // Removing the LAST entity is the easy path - no swap,
        // just shrink, possibly free the chunk if empty.
        if (@backingInt(index_in_chunk) == new_len) {
            if (std.debug.runtime_safety) {
                indices[@backingInt(index_in_chunk)] = undefined;
                var it: CompFlag.Set.Iterator = self.header().arch(&es.arches).iterator();
                while (it.next()) |flag| {
                    const id: TypeId = es.getCompType(flag);
                    const comp_buffer: []u8 = self.compsFromId(es, id).?;
                    const comp_offset: u32 = @intCast(new_len * id.size);
                    const comp: []u8 = comp_buffer[comp_offset..][0..id.size];
                    @memset(comp, undefined);
                }
            }

            if (new_len == 0) {
                self.clear(es);
            } else {
                self.header().len = new_len;
            }
            return;
        }

        // The general path: overwrite the freed slot with the
        // last entity's data, then shrink.

        // Index slot: just write the last entity's index.
        indices[@backingInt(index_in_chunk)] = moved;

        // Component slots: memcpy each comp from end → freed slot,
        // then poison the source slot under runtime_safety.
        {
            var move: CompFlag.Set.Iterator = self.header().arch(&es.arches).iterator();
            while (move.next()) |flag| {
                const id: TypeId = es.getCompType(flag);
                const comp_buffer: []u8 = self.compsFromId(es, id).?;

                const new_comp_offset: usize = @backingInt(index_in_chunk) * id.size;
                const new_comp: []u8 = comp_buffer[new_comp_offset..][0..id.size];

                const prev_comp_offset: usize = new_len * id.size;
                const prev_comp: []u8 = comp_buffer[prev_comp_offset..][0..id.size];

                @memcpy(new_comp, prev_comp);
                @memset(prev_comp, undefined);
            }
        }

        self.header().len = new_len;

        // The moved entity's stored location is stale - patch it.
        const moved_loc: *Entity.Location = &es.handle_tab.slots[@backingInt(moved)].value;
        assert(moved_loc.chunk.get(&es.chunk_pool) == self, @src());
        moved_loc.index_in_chunk = index_in_chunk;

        // We just dropped from full to non-full - relink onto the
        // chunk list's available list.  Insert AFTER the current
        // head (not at the head) so the head chunk stays the one
        // being filled - reduces fragmentation by keeping new
        // entities in a single chunk until it's full.
        if (was_full) {
            if (list.avail.get(cpool)) |head| {
                self.header().next_avail = head.header().next_avail;
                if (self.header().next_avail.get(cpool)) |next_avail| {
                    next_avail.header().prev_avail = index;
                }
                self.header().prev_avail = list.avail;
                head.header().next_avail = index;
            } else {
                list.avail = index;
            }
        }

        list.checkAssertions(es);
        self.checkAssertions(es, .default);
    }

    /// Iterate every committed entity in this chunk.  Locks the
    /// world's pointer-generation counter - any mutation during
    /// iteration trips a runtime-safety assert in `next`.
    pub fn iterator(self: *@This(), es: *const Registry) Iterator {
        return .{
            .chunk = self,
            .index_in_chunk = @fromBackingInt(@intCast(0)),
            .pointer_lock = es.pointer_generation.lock(),
        };
    }

    /// Single-chunk iterator.  Yields one `Entity` per slot in
    /// the chunk, oldest first.
    pub const Iterator = struct {
        chunk: *Chunk,
        index_in_chunk: Entity.Location.IndexInChunk,
        pointer_lock: PointerLock,

        pub fn next(self: *@This(), es: *const Registry) ?Entity {
            self.pointer_lock.check(es.pointer_generation);
            if (@backingInt(self.index_in_chunk) >= self.chunk.header().len) {
                @branchHint(.unlikely);
                return null;
            }
            const indices = self.chunk.view(es, struct {
                indices: []const Entity.Index,
            }).?.indices;
            const entity_index: Entity.Index = indices[@backingInt(self.index_in_chunk)];
            self.index_in_chunk = @fromBackingInt(@intCast(@backingInt(self.index_in_chunk) + 1));
            return entity_index.toEntity(es);
        }
    };
};

/// An unencoded representation of command buffer commands.
pub const Subcmd = union(enum) {
    /// Binds an existing entity.
    bind_entity: Entity,
    /// Destroys the bound entity.
    destroy: void,
    /// Queues a component to be added by value. The type ID is passed as an argument, component
    /// data is passed via any bytes.
    add_val: Any,
    /// Queues a component to be added by pointer. The type ID and a pointer to the component data
    /// are passed as arguments.
    add_ptr: Any,
    /// Queues an extension command to be added by value. The type ID is passed as an argument, the
    /// payload is passed via any bytes.
    ext_val: Any,
    /// Queues an extension command to be added by pointer. The type ID and a pointer to the
    /// component data are passed as arguments.
    ext_ptr: Any,
    /// Queues a component to be removed.
    remove: TypeId,

    /// If a new worst case command is introduced, also update the tests!
    pub const rename_when_changing_encoding = {};

    pub const TagEnum = @typeInfo(@This()).@"union".tag_type.?;

    /// Decodes encoded commands.
    pub const Decoder = struct {
        cb: *const CmdBuf,
        tag_index: usize = 0,
        arg_index: usize = 0,
        comp_bytes_index: usize = 0,

        pub inline fn next(self: *@This()) ?Subcmd {
            _ = rename_when_changing_encoding;

            // Decode the next command
            if (self.nextTag()) |tag| {
                switch (tag) {
                    .bind_entity => {
                        const arg: u64 = self.nextArg().?;
                        const entity: Entity = @bitCast(@as(
                            @Int(.unsigned, @bitSizeOf(Entity)),
                            @truncate(arg),
                        ));
                        return .{ .bind_entity = entity };
                    },
                    inline .add_val, .ext_val => |add| {
                        @setEvalBranchQuota(2000);
                        const id: TypeId = @ptrFromInt(@as(usize, @intCast(self.nextArg().?)));
                        const ptr = self.nextAny(id);
                        const any: Any = .{
                            .id = id,
                            .ptr = ptr,
                        };
                        return switch (add) {
                            .add_val => .{ .add_val = any },
                            .ext_val => .{ .ext_val = any },
                            else => comptime unreachable,
                        };
                    },
                    inline .add_ptr, .ext_ptr => |add| {
                        const id: TypeId = @ptrFromInt(@as(usize, @intCast(self.nextArg().?)));
                        const ptr: *const anyopaque = @ptrFromInt(@as(usize, @intCast(self.nextArg().?)));
                        const any: Any = .{
                            .id = id,
                            .ptr = ptr,
                        };
                        switch (add) {
                            .add_ptr => return .{ .add_ptr = any },
                            .ext_ptr => return .{ .ext_ptr = any },
                            else => comptime unreachable,
                        }
                    },
                    .remove => {
                        const id: TypeId = @ptrFromInt(@as(usize, @intCast(self.nextArg().?)));
                        return .{ .remove = id };
                    },
                    .destroy => return .destroy,
                }
            }

            // Assert that we're fully empty, and return null
            assert(self.tag_index == self.cb.tags.items.len, @src());
            assert(self.arg_index == self.cb.args.items.len, @src());
            assert(self.comp_bytes_index == self.cb.data.items.len, @src());
            return null;
        }

        pub fn clear(self: *@This()) void {
            self.tag_index = self.cb.tags.items.len;
            self.arg_index = self.cb.args.items.len;
            self.comp_bytes_index = self.cb.data.items.len;
        }

        pub inline fn peekTag(self: *@This()) ?Subcmd.TagEnum {
            if (self.tag_index < self.cb.tags.items.len) {
                return self.cb.tags.items[self.tag_index];
            } else {
                @branchHint(.unlikely);
                return null;
            }
        }

        pub inline fn nextTag(self: *@This()) ?Subcmd.TagEnum {
            const tag = self.peekTag() orelse return null;
            self.tag_index += 1;
            return tag;
        }

        pub inline fn nextArg(self: *@This()) ?u64 {
            if (self.arg_index < self.cb.args.items.len) {
                const arg = self.cb.args.items[self.arg_index];
                self.arg_index += 1;
                return arg;
            } else {
                return null;
            }
        }

        pub inline fn nextAny(self: *@This(), id: TypeId) *const anyopaque {
            // Align the read
            self.comp_bytes_index = std.mem.alignForward(
                usize,
                self.comp_bytes_index,
                id.alignment,
            );

            // Get the pointer as a slice, this way we don't fail on zero sized types
            const bytes = &self.cb.data.items[self.comp_bytes_index..][0..id.size];

            // Update the offset and return the pointer
            self.comp_bytes_index += id.size;
            return bytes.ptr;
        }
    };

    /// Encode adding a component to an entity by value. Returns a pointer to the encoded value
    /// that's valid until the command buffer is cleared.
    pub fn encodeAddVal(
        cb: *CmdBuf,
        entity: Entity,
        T: type,
        comp: T,
    ) error{EcsCmdBufOverflow}!*T {
        try Subcmd.encodeBind(cb, entity);
        return try Subcmd.encodeVal(cb, .add_val, T, comp);
    }

    /// Encode adding a component to an entity by pointer.
    pub fn encodeAddPtr(
        cb: *CmdBuf,
        entity: Entity,
        T: type,
        comp: *const T,
    ) error{EcsCmdBufOverflow}!void {
        try Subcmd.encodeBind(cb, entity);
        try Subcmd.encodePtr(cb, .add_ptr, T, comp);
    }

    /// Encode an extension command by value. Returns a pointer to the encoded value that's valid
    /// until the command buffer is cleared.
    pub fn encodeExtVal(
        cb: *CmdBuf,
        T: type,
        payload: T,
    ) error{EcsCmdBufOverflow}!*T {
        // Clear the binding. Archetype changes must start with a bind so we don't want it to be
        // cached across other commands.
        cb.binding = .none;
        return try Subcmd.encodeVal(cb, .ext_val, T, payload);
    }

    /// Encode an extension command by pointer.
    pub fn encodeExtPtr(
        cb: *CmdBuf,
        T: type,
        payload: *const T,
    ) error{EcsCmdBufOverflow}!void {
        // Clear the binding. Archetype changes must start with a bind so we don't want it to be
        // cached across other commands.
        cb.binding = .none;
        try Subcmd.encodePtr(cb, .ext_ptr, T, payload);
    }

    /// Encode removing a component from an entity.
    pub fn encodeRemove(
        cb: *CmdBuf,
        entity: Entity,
        id: TypeId,
    ) error{EcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };
        try Subcmd.encodeBind(cb, entity);

        if (cb.tags.items.len >= cb.tags.capacity) return error.EcsCmdBufOverflow;
        if (cb.args.items.len >= cb.args.capacity) return error.EcsCmdBufOverflow;
        cb.tags.appendAssumeCapacity(.remove);
        cb.args.appendAssumeCapacity(@intFromPtr(id));
    }

    /// Encode committing an entity.
    pub fn encodeCommit(
        cb: *CmdBuf,
        entity: Entity,
    ) error{EcsCmdBufOverflow}!void {
        try encodeBind(cb, entity);
    }

    /// Encode destroying an entity.
    pub fn encodeDestroy(
        cb: *CmdBuf,
        entity: Entity,
    ) error{EcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };
        try Subcmd.encodeBind(cb, entity);

        if (cb.tags.items.len >= cb.tags.capacity) return error.EcsCmdBufOverflow;
        cb.tags.appendAssumeCapacity(.destroy);
    }

    /// Encode binding an entity as part of a subcommand.
    fn encodeBind(cb: *CmdBuf, entity: Entity) error{EcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };
        if (cb.binding != entity.toOptional()) {
            if (cb.tags.items.len >= cb.tags.capacity) return error.EcsCmdBufOverflow;
            cb.binding = entity.toOptional();
            cb.tags.appendAssumeCapacity(.bind_entity);
            cb.args.appendAssumeCapacity(@as(u64, @as(@Int(.unsigned, @bitSizeOf(Entity)), @bitCast(entity))));
        }
    }

    /// Encode a value as part of a subcommand. Returns a pointer to the encoded value that's valid
    /// until the command buffer is cleared.
    fn encodeVal(cb: *CmdBuf, tag: TagEnum, T: type, val: T) error{EcsCmdBufOverflow}!*T {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };

        const aligned = std.mem.alignForward(usize, cb.data.items.len, @alignOf(T));
        if (cb.tags.items.len >= cb.tags.capacity) return error.EcsCmdBufOverflow;
        if (aligned + @sizeOf(T) > cb.data.capacity) return error.EcsCmdBufOverflow;
        cb.tags.appendAssumeCapacity(tag);
        cb.args.appendAssumeCapacity(@intFromPtr(typeId(T)));

        cb.data.items.len = aligned;
        const result = &cb.data.items.ptr[cb.data.items.len];
        cb.data.appendSliceAssumeCapacity(std.mem.asBytes(&val));
        return @ptrCast(@alignCast(result));
    }

    /// Encode a pointer as part of a subcommand.
    fn encodePtr(cb: *CmdBuf, tag: TagEnum, T: type, ptr: *const T) error{EcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };

        if (cb.tags.items.len >= cb.tags.capacity) return error.EcsCmdBufOverflow;
        if (cb.args.items.len + 2 > cb.args.capacity) return error.EcsCmdBufOverflow;

        cb.tags.appendAssumeCapacity(tag);
        cb.args.appendAssumeCapacity(@intFromPtr(typeId(T)));
        cb.args.appendAssumeCapacity(@intFromPtr(ptr));
    }
};

/// A persistent handle to one entity in the world.
/// Handles outlive destruction: an entity destroyed under one
/// handle leaves its slot reusable, but `Entity.exists` will
/// continue to report `false` for the old handle (the slot's
/// generation got bumped, breaking the match).  Useful when entity
/// lifetime depends on user input or game logic that stores
/// references across frames.
/// Two API flavors:
///   - **Buffered**: methods that take a `*CmdBuf` queue work for
///     replay at the next `Exec.immediate`.  Safe during
///     iteration, deterministic, the default.
///   - **Immediate** (`fooImmediate`): apply the change right
///     now.  Faster for one-off level-load setup, but invalidates
///     pointers and can't be called from inside an iterator.
pub const Entity = packed struct {
    /// An entity stripped of its generation tag.  Saves space
    /// in lower-level APIs that already know the index isn't
    /// dangling (chunks store these as their per-entity index
    /// buffer).  Don't persist these - there's no way to detect
    /// staleness without the generation.
    pub const Index = enum(HandleTab.Key.Index) {
        _,

        /// Recover the full `Entity` (with generation) from an
        /// index.  Caller must guarantee the index is live
        /// without the generation we can't detect dangling, the
        /// asserts will trip if it isn't.
        pub fn toEntity(self: @This(), es: *const Registry) Entity {
            const result: Entity = .{ .key = .{
                .index = @backingInt(self),
                .generation = es.handle_tab.slots[@backingInt(self)].generation,
            } };
            assert(result.key.generation != .invalid, @src());
            assert(result.key.index < es.handle_tab.next_index, @src());
            return result;
        }
    };

    /// Where an entity's data lives.  Indirection through this
    /// struct (rather than chunks pointing back to handles) is
    /// what lets entities relocate (swap-remove on delete, archetype
    /// changes) without invalidating outside handles.
    pub const Location = struct {
        /// Index within a chunk's entity slots.
        pub const IndexInChunk = enum(u32) { _ };

        /// Sentinel "reserved but not committed" location.
        pub const reserved: @This() = .{
            .chunk = .none,
            .index_in_chunk = if (std.debug.runtime_safety)
                @fromBackingInt(@intCast(maxInt(@typeInfo(IndexInChunk).@"enum".tag_type)))
            else
                undefined,
        };

        /// The chunk where this entity is stored, or `null` if it hasn't been committed.
        chunk: Chunk.Index = .none,
        /// The entity's index in the chunk, value is unspecified if not committed.
        index_in_chunk: IndexInChunk,

        /// The archetype of the entity at this location.  Returns
        /// the empty arch (= "no components") for uncommitted
        /// (reserved-only) entities.
        pub fn arch(self: @This(), es: *const Registry) CompFlag.Set {
            const chunk: *Chunk = self.chunk.get(&es.chunk_pool) orelse return .{};
            return chunk.header().arch(&es.arches);
        }
    };

    /// Packed `?Entity`.  Same bits as `Entity` itself but with
    /// `.none` as a valid in-band sentinel - the underlying
    /// `Key.Optional` reserves one bit pattern that no live key
    /// can take.  Use this in component fields where you'd
    /// otherwise need `?Entity`.
    pub const Optional = packed struct {
        pub const none: @This() = .{ .key = .none };

        key: HandleTab.Key.Optional,

        /// Unwrap to a plain `Entity`, or `null` if `.none`.
        pub fn unwrap(self: @This()) ?Entity {
            const key: HandleTab.Key = self.key.unwrap() orelse return null;
            return .{ .key = key };
        }

        /// Format as the underlying key (e.g. `[index:gen]` or
        /// `null`).
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.key.format(writer);
        }

        /// Bit-for-bit equality.  Two Optionals comparing equal
        /// here doesn't necessarily mean they refer to the same
        /// LIVE entity - that requires `unwrap()` then comparing
        /// generations against the world's current state.
        pub fn eql(self: @This(), other: @This()) bool {
            return self.key.eql(other.key);
        }

        // The methods below follow the same shape: unwrap, forward
        // to the matching `Entity` method, return a sensible zero
        // on `.none`.  Kept as parallel one-liners - anything more
        // belongs on `Entity` itself, not the Optional wrapper.

        /// True if non-none and not destroyed.
        pub fn exists(self: @This(), es: *const Registry) bool {
            const e: Entity = self.unwrap() orelse return false;
            return e.exists(es);
        }

        /// True if non-none and committed (has chunk storage).
        pub fn committed(self: @This(), es: *const Registry) bool {
            const e: Entity = self.unwrap() orelse return false;
            return e.committed(es);
        }

        /// True if non-none, exists, and has component `T`.
        pub fn has(
            self: @This(),
            es: *const Registry,
            T: type,
        ) bool {
            const e: Entity = self.unwrap() orelse return false;
            return e.has(es, T);
        }

        /// `has` for runtime-typed component IDs.
        pub fn hasId(
            self: @This(),
            es: *const Registry,
            id: TypeId,
        ) bool {
            const e: Entity = self.unwrap() orelse return false;
            return e.hasId(es, id);
        }

        /// Component `T` on this entity, or `null` if none / destroyed
        /// / missing.  See also `Registry.getComp`.
        pub fn get(
            self: @This(),
            es: *const Registry,
            T: type,
        ) ?*T {
            const e: Entity = self.unwrap() orelse return null;
            return e.get(es, T);
        }

        /// `get` for runtime-typed component IDs.  Returns the raw
        /// bytes - caller `@ptrCast` to the right type.
        pub fn getId(
            self: @This(),
            es: *const Registry,
            id: TypeId,
        ) ?[]u8 {
            const e: Entity = self.unwrap() orelse return null;
            return e.getId(es, id);
        }

        /// Materialise `View`, or `null` if none / missing required
        /// components / destroyed.
        pub fn view(
            self: @This(),
            es: *const Registry,
            View: type,
        ) ?View {
            const e: Entity = self.unwrap() orelse return null;
            return e.view(es, View);
        }
    };

    key: HandleTab.Key,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.key.eql(other.key);
    }

    /// Pops a reserved entity.
    /// Pops a reserved entity off the command buffer's reserve.
    /// Reserved entities have a persistent key but no chunk
    /// storage; they behave as empty entities and don't show up in
    /// iteration.  You can commit explicitly via `commit`, but
    /// add/remove also commits implicitly.
    pub fn reserve(cb: *CmdBuf) Entity {
        return reserveOrErr(cb) catch |err|
            @panic(@errorName(err));
    }

    /// `reserve` that surfaces the underflow error.  Underflow
    /// happens when the buffer's reserve is empty - usually means
    /// you didn't pre-fill the buffer for the burst of work this
    /// frame.
    pub fn reserveOrErr(cb: *CmdBuf) error{EcsReservedEntityUnderflow}!Entity {
        return cb.reserved.pop() orelse error.EcsReservedEntityUnderflow;
    }

    /// Like `reserve`, but reserves directly from the world
    /// instead of pulling from a command-buffer reserve.  Prefer
    /// `reserve`.  Doesn't invalidate pointers; not thread-safe.
    pub fn reserveImmediate(es: *Registry) Entity {
        return reserveImmediateOrErr(es) catch |err|
            @panic(@errorName(err));
    }

    /// `reserveImmediate` returning `error.EcsEntityOverflow`.
    pub fn reserveImmediateOrErr(es: *Registry) error{EcsEntityOverflow}!Entity {
        const pointer_lock: PointerLock = es.pointer_generation.lock();
        defer pointer_lock.check(es.pointer_generation);

        const key: HandleTab.Key = es.handle_tab.put(.reserved) catch |err| switch (err) {
            error.Overflow => return error.EcsEntityOverflow,
        };
        es.reserved_entities += 1;
        return .{ .key = key };
    }

    /// Queue this entity for destruction at the next `Exec.immediate`.
    /// Destroying an entity that no longer exists is a no-op.
    pub fn destroy(self: @This(), cb: *CmdBuf) void {
        self.destroyOrErr(cb) catch |err|
            @panic(@errorName(err));
    }

    /// `destroy` that surfaces the buffer-overflow error instead of
    /// panicking.  See `CmdBuf` doc for "undefined state on error".
    pub fn destroyOrErr(self: @This(), cb: *CmdBuf) error{EcsCmdBufOverflow}!void {
        try Subcmd.encodeDestroy(cb, self);
    }

    /// Like `destroy`, but immediate (no command buffer).  Returns
    /// true if the entity actually existed before this call
    /// destroying a non-existent entity is a no-op and returns
    /// false.  Invalidates pointers.
    pub fn destroyImmediate(self: @This(), es: *Registry) bool {
        es.pointer_generation.increment();
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key) orelse return false;

        // Either the entity was committed (has chunk storage we
        // need to swap-remove from) or it was reserve-only (just
        // decrement the reserved tally).
        if (entity_loc.chunk.get(&es.chunk_pool)) |chunk| {
            chunk.swapRemove(es, entity_loc.index_in_chunk);
        } else {
            es.reserved_entities -= 1;
        }
        es.handle_tab.remove(self.key);
        entity_loc.* = undefined;
        return true;
    }

    /// True if the entity hasn't been destroyed.  Doesn't check
    /// commitment - a reserved-but-uncommitted entity still
    /// "exists" in the sense that its handle is live.
    pub fn exists(self: @This(), es: *const Registry) bool {
        return es.handle_tab.containsKey(self.key);
    }

    /// True if the entity exists AND has chunk storage attached.
    /// Reserved entities return false here.
    pub fn committed(self: @This(), es: *const Registry) bool {
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key) orelse return false;
        return entity_loc.chunk != .none;
    }

    /// True if the entity has component `T`.  False on destroyed
    /// or unregistered-component-type.
    pub fn has(
        self: @This(),
        es: *const Registry,
        T: type,
    ) bool {
        return self.hasId(es, typeId(T));
    }

    /// `has` for runtime-typed component IDs.
    pub fn hasId(
        self: @This(),
        es: *const Registry,
        id: TypeId,
    ) bool {
        const flag: CompFlag = es.getCompFlag(id) orelse return false;
        return self.arch(es).contains(flag);
    }

    /// Get a pointer to component `T` on this entity, or `null` if
    /// it isn't attached / the entity is destroyed.
    /// We could route this through `compsFromId` for a smaller
    /// implementation, but benchmarks show a measurable speedup
    /// from doing the offset math inline - `get` is the inner-
    /// loop accessor and the indirection costs more than it
    /// saves.  See `Registry.getComp` for the variant that takes
    /// an arbitrary component pointer instead of a handle.
    pub fn get(
        self: @This(),
        es: *const Registry,
        T: type,
    ) ?*T {
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key) orelse return null;
        const chunk: *Chunk = entity_loc.chunk.get(&es.chunk_pool) orelse return null;
        const flag: CompFlag = es.getCompFlag(typeId(T)) orelse return null;
        // https://codeberg.org/Games-by-Mason/mr_ecs/issues/24
        const offset: u32 = chunk.header().comp_buf_offsets.values[@backingInt(flag)];
        if (offset == 0) {
            return null;
        }
        const comps_addr: usize = @intFromPtr(chunk) + offset;
        const comp_addr = comps_addr + @sizeOf(T) * @backingInt(entity_loc.index_in_chunk);
        return @ptrFromInt(comp_addr);
    }

    /// `get` for runtime-typed component IDs.  Returns the raw
    /// bytes - `@ptrCast` to the right type at the call site.
    pub fn getId(
        self: @This(),
        es: *const Registry,
        id: TypeId,
    ) ?[]u8 {
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key) orelse return null;
        const chunk: *Chunk = entity_loc.chunk.get(&es.chunk_pool) orelse return null;
        const comps: []u8 = chunk.compsFromId(es, id) orelse return null;
        return comps[@backingInt(entity_loc.index_in_chunk) * id.size ..][0..id.size];
    }

    /// Queue a component to be added the next time the buffer is
    /// flushed.  Returns a pointer to the encoded copy in the
    /// command buffer (not into chunk storage - that doesn't exist
    /// yet).  Adding to a destroyed entity is a quiet no-op.
    /// Inlining is required: the comptime-knownness check
    /// (`isComptimeKnown`) only works at the inline call site.
    /// The inline keyword stays.
    /// Batching add/removes on the same entity in sequence is more
    /// efficient than alternating between operations on different
    /// entities - the encoder coalesces adjacent ops on the same
    /// handle.
    /// For comptime-known values larger than a pointer, the
    /// implementation calls `addPtr` with an interned static
    /// pointer instead of copying the value through the buffer.
    pub inline fn add(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        comp: T,
    ) *const T {
        comptime assert(@typeInfo(@TypeOf(add)).@"fn".attrs.@"callconv" == .@"inline", @src());
        if (@sizeOf(T) > @sizeOf(*T) and meta.isComptimeKnown(comp)) {
            const Interned = struct {
                const value = comp;
            };
            const ptr = comptime &Interned.value;
            self.addPtr(cb, T, ptr);
            return ptr;
        }
        return self.addVal(cb, T, comp);
    }

    /// Like `add`, but always copies by value into the command
    /// buffer.  The returned pointer is valid until the next
    /// `clear()` (which happens during `Exec.immediate`).  Prefer
    /// `add` unless you need the returned pointer.
    pub fn addVal(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        comp: T,
    ) *T {
        return self.addValOrErr(cb, T, comp) catch |err|
            @panic(@errorName(err));
    }

    /// `addVal` that returns `error.EcsCmdBufOverflow` instead of
    /// panicking.  See `CmdBuf` doc for what "undefined state on
    /// error" means.
    pub fn addValOrErr(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        comp: T,
    ) error{EcsCmdBufOverflow}!*T {
        return Subcmd.encodeAddVal(cb, self, T, comp);
    }

    /// Like `add`, but always passes the component by pointer.
    /// The pointer must outlive the buffer flush (typical: a
    /// static const, or chunk-arena memory).  Prefer `add`.
    pub fn addPtr(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        comp: *const T,
    ) void {
        return self.addPtrOrErr(cb, T, comp) catch |err|
            @panic(@errorName(err));
    }

    /// `addPtr` returning `error.EcsCmdBufOverflow`.
    pub fn addPtrOrErr(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        comp: *const T,
    ) error{EcsCmdBufOverflow}!void {
        return Subcmd.encodeAddPtr(cb, self, T, comp);
    }

    /// Queue a component for removal at the next flush.  No-op if
    /// the component isn't present or the entity is gone.
    /// Performance note: see `add` - alternating add/remove on
    /// different entities defeats batching.
    pub fn remove(
        self: @This(),
        cb: *CmdBuf,
        T: type,
    ) void {
        self.removeId(cb, typeId(T)) catch |err|
            @panic(@errorName(err));
    }

    /// `remove` for runtime-typed component IDs that surfaces the
    /// buffer-overflow error instead of panicking.
    pub fn removeId(
        self: @This(),
        cb: *CmdBuf,
        id: TypeId,
    ) error{EcsCmdBufOverflow}!void {
        try Subcmd.encodeRemove(cb, self, id);
    }

    /// Queue this entity to be committed.  Implicit during add /
    /// remove / cmd, so really only needed when you want an empty
    /// entity in chunk storage.
    pub fn commit(self: @This(), cb: *CmdBuf) void {
        self.commitOrErr(cb) catch |err|
            @panic(@errorName(err));
    }

    /// `commit` returning `error.EcsCmdBufOverflow`.
    pub fn commitOrErr(self: @This(), cb: *CmdBuf) error{EcsCmdBufOverflow}!void {
        try Subcmd.encodeCommit(cb, self);
    }

    /// Options struct for `changeArchImmediate`.  Built at comptime
    /// so that an `Add` struct whose fields all have defaults gives
    /// an Options whose `add` itself has a default - letting users
    /// write `.{ .remove = ... }` without filling in `add`.
    pub fn ChangeArchImmediateOptions(Add: type) type {
        comptime var has_defaults: bool = true;
        for (@typeInfo(Add).@"struct".field_attrs) |field_attr| {
            if (field_attr.default_value_ptr == null) {
                has_defaults = false;
                break;
            }
        }
        if (has_defaults) {
            return struct {
                add: Add = .{},
                remove: CompFlag.Set = .{},
            };
        }
        return struct {
            add: Add,
            remove: CompFlag.Set = .{},
        };
    }

    /// Add the listed components, then remove the listed flags.
    /// `Add` is a tuple or struct of components-to-add (fields may
    /// be optional, letting the caller decide at runtime whether
    /// each should actually be added).  Returns true on success,
    /// false if the entity doesn't exist.
    /// `gpa` is needed because adding a component may register a
    /// fresh type with the world's flag table.  Invalidates
    /// pointers.
    pub fn changeArchImmediate(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        Add: type,
        changes: ChangeArchImmediateOptions(Add),
    ) bool {
        return self.changeArchImmediateOrErr(es, gpa, Add, changes) catch |err|
            @panic(@errorName(err));
    }

    /// `changeArchImmediate` returning errors instead of panicking.
    pub fn changeArchImmediateOrErr(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        Add: type,
        changes: ChangeArchImmediateOptions(Add),
    ) error{ OutOfMemory, EcsArchOverflow, EcsChunkOverflow, EcsChunkPoolOverflow, EcsCompTypeOverflow }!bool {
        // Components are keyed by type (`typeId(Comp)`), so two fields of the SAME type
        // would register one flag and write to one slot (last write wins) — silently
        // collapsing two components into one. Reject that at comptime: each component
        // needs a distinct type (wrap same-shaped data in named structs).
        comptime {
            const af_names = @typeInfo(Add).@"struct".field_names;
            const af_types = @typeInfo(Add).@"struct".field_types;
            for (af_types, af_names, 0..) |fa_type, fa_name, ia| {
                for (af_types[ia + 1 ..], af_names[ia + 1 ..]) |fb_type, fb_name| {
                    if (viewLib.Unwrap(fa_type) == viewLib.Unwrap(fb_type)) {
                        @compileError("ECS archetype has two components of the same type '" ++
                            @typeName(viewLib.Unwrap(fa_type)) ++ "' (fields '" ++ fa_name ++
                            "' and '" ++ fb_name ++ "'). Same-type components collide into one " ++
                            "(they're keyed by type). Give each component a distinct type.");
                    }
                }
            }
        }
        es.pointer_generation.increment();

        const add_info = @typeInfo(Add).@"struct";

        // Pass 1: register every component we plan to add and build
        // up the bitset for the arch transition.
        var add_comps: CompFlag.Set = .{};
        inline for (add_info.field_names, add_info.field_types) |field_name, field_type| {
            const Comp: type = viewLib.Unwrap(field_type);
            const present: bool = @typeInfo(field_type) != .optional or
                @field(changes.add, field_name) != null;
            if (present) {
                add_comps.insert(try es.registerComponent(gpa, typeId(Comp)));
            }
        }

        // Move the entity to the new arch (storage gets allocated
        // / copied, components left uninitialised in their slots).
        const arch_ok: bool = try self.changeArchUninitImmediateOrErr(es, .{
            .add = add_comps,
            .remove = changes.remove,
        });
        if (!arch_ok) {
            return false;
        }

        // Pass 2: write each present component's value into its
        // slot in the new chunk.  Both unwraps are safe - the
        // entity exists (we just got back true from the move) and
        // the flag was registered in pass 1.
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key).?;
        const new_chunk: *Chunk = entity_loc.chunk.get(&es.chunk_pool).?;
        inline for (add_info.field_names, add_info.field_types) |field_name, field_type| {
            const Comp: type = viewLib.Unwrap(field_type);
            const present: bool = @typeInfo(field_type) != .optional or
                @field(changes.add, field_name) != null;
            if (present) {
                const flag: CompFlag = es.getCompFlag(typeId(Comp)).?;
                if (!changes.remove.contains(flag)) {
                    // https://codeberg.org/Games-by-Mason/mr_ecs/issues/24
                    const offset: u32 = new_chunk.header().comp_buf_offsets.values[@backingInt(flag)];
                    assert(offset != 0, @src()); // present in arch by construction
                    const comp: *Comp = @ptrFromInt(@intFromPtr(new_chunk) +
                        offset +
                        @backingInt(entity_loc.index_in_chunk) * @sizeOf(Comp));
                    comp.* = @as(?Comp, @field(changes.add, field_name)).?;
                }
            }
        }

        return true;
    }

    /// Options for `changeArchAnyImmediate` (runtime-typed
    /// component list).
    pub const ChangeArchAnyImmediateOptions = struct {
        add: []const Any = &.{},
        remove: CompFlag.Set = .empty,
    };

    /// Runtime-typed cousin of `changeArchImmediate`.  Use when
    /// the component list is built dynamically (level-loader,
    /// scripting, etc.) rather than fixed at the call site.
    pub fn changeArchAnyImmediate(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        changes: ChangeArchAnyImmediateOptions,
    ) error{ OutOfMemory, EcsArchOverflow, EcsChunkOverflow, EcsChunkPoolOverflow, EcsCompTypeOverflow }!bool {
        es.pointer_generation.increment();

        // Pass 1: register every Any's TypeId, build the add-set.
        var add_comps: CompFlag.Set = .{};
        for (changes.add) |comp| {
            add_comps.insert(try es.registerComponent(gpa, comp.id));
        }

        // Move the entity to the new arch with components left
        // uninitialised in their slots.
        const arch_ok: bool = try self.changeArchUninitImmediateOrErr(es, .{
            .add = add_comps,
            .remove = changes.remove,
        });
        if (!arch_ok) {
            return false;
        }

        // Pass 2: memcpy each Any's bytes into the new chunk slot.
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key).?;
        const chunk: *Chunk = entity_loc.chunk.get(&es.chunk_pool).?;
        for (changes.add) |comp| {
            const flag: CompFlag = es.getCompFlag(comp.id).?; // registered above
            if (!changes.remove.contains(flag)) {
                // https://codeberg.org/Games-by-Mason/mr_ecs/issues/24
                const offset: u32 = chunk.header().comp_buf_offsets.values[@backingInt(flag)];
                assert(offset != 0, @src());
                const dest_unsized: [*]u8 = @ptrFromInt(@intFromPtr(chunk) +
                    offset +
                    @backingInt(entity_loc.index_in_chunk) * comp.id.size);
                const dest: []u8 = dest_unsized[0..comp.id.size];
                @memcpy(dest, comp.bytes());
            }
        }

        return true;
    }

    /// Options for the uninitialized variants of change archetype.
    pub const ChangeArchUninitImmediateOptions = struct {
        /// Component types to remove.
        remove: CompFlag.Set = .{},
        /// Component types to add.
        add: CompFlag.Set = .{},
    };

    /// Like `changeArchOrErr`, but the added components are left
    /// uninitialised - even if they had values before.  Useful when
    /// the caller is going to overwrite the slots immediately
    /// (e.g. `viewOrAddImmediate`'s second pass) and the
    /// init-then-overwrite would just be wasted work.
    /// On failure, internal allocator state may have shifted
    /// chunk lists created mid-call don't get rolled back even if
    /// no chunks could be allocated for them.  In practice this is
    /// fine because immediate arch changes happen at level-load
    /// time when failures are fatal anyway.
    /// Could go slightly faster with comptime-known types (the
    /// donor mirrors that split with `changeArchImmediate` vs
    /// `changeArchAnyImmediate`) - `@memcpy` with comptime length
    /// is a bit faster.  In practice nobody bulk-changes-arch at
    /// frame rate, so the win wouldn't show up.
    pub fn changeArchUninitImmediateOrErr(
        self: @This(),
        es: *Registry,
        options: ChangeArchUninitImmediateOptions,
    ) error{ EcsArchOverflow, EcsChunkOverflow, EcsChunkPoolOverflow }!bool {
        es.pointer_generation.increment();

        // Resolve current location + compute the target archetype.
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key) orelse return false;
        const old_chunk: ?*Chunk = entity_loc.chunk.get(&es.chunk_pool);
        const prev_arch: CompFlag.Set = entity_loc.arch(es);
        var new_arch: CompFlag.Set = prev_arch;
        new_arch = new_arch.unionWith(options.add);
        new_arch = new_arch.differenceWith(options.remove);

        // No-op if already committed to the right archetype.
        if (old_chunk) |chunk| {
            const chunk_header: *Chunk.Header = chunk.header();
            if (chunk_header.arch(&es.arches).eql(new_arch)) {
                @branchHint(.unlikely);
                return true;
            }
        }

        // Allocate the new home.  Splitting "find arch" from
        // "append entity" lets us bail cleanly if the chunk-list
        // exists but ran out of chunks.
        const chunk_list: *ChunkList = try es.arches.getOrPut(es, &es.chunk_pool, new_arch);
        const new_loc: Entity.Location = try chunk_list.append(es, self);
        const new_chunk: *Chunk = new_loc.chunk.get(&es.chunk_pool).?;
        errdefer comptime unreachable;

        // Newly-added (but not also being removed) components get
        // poisoned so reads before a write trip the safety check.
        if (std.debug.runtime_safety) {
            var added: CompFlag.Set.Iterator = options.add.differenceWith(options.remove).iterator();
            while (added.next()) |flag| {
                const id: TypeId = es.getCompType(flag);
                const comp_buffer: []u8 = new_chunk.compsFromId(es, id).?;
                const comp_offset: usize = @backingInt(new_loc.index_in_chunk) * id.size;
                const comp: []u8 = comp_buffer[comp_offset..][0..id.size];
                @memset(comp, undefined);
            }
        }

        // Carry over any components that survive the change
        // (present in prev, not in remove, not in add).
        if (old_chunk) |prev_chunk| {
            var move: CompFlag.Set.Iterator = prev_arch.differenceWith(options.remove)
                .differenceWith(options.add).iterator();
            while (move.next()) |flag| {
                const id: TypeId = es.getCompType(flag);

                const new_comp_buffer: []u8 = new_chunk.compsFromId(es, id).?;
                const new_comp_offset: usize = @backingInt(new_loc.index_in_chunk) * id.size;
                const new_comp: []u8 = new_comp_buffer[new_comp_offset..][0..id.size];

                const prev_comp_buffer: []u8 = prev_chunk.compsFromId(es, id).?;
                const prev_comp_offset: usize = @backingInt(entity_loc.index_in_chunk) * id.size;
                const prev_comp: []u8 = prev_comp_buffer[prev_comp_offset..][0..id.size];

                @memcpy(new_comp, prev_comp);
            }
        }

        // Drop the entity from its previous home (if any), or
        // decrement the reserve tally if it was reserve-only.
        if (old_chunk) |chunk| {
            chunk.swapRemove(es, entity_loc.index_in_chunk);
        } else {
            es.reserved_entities -= 1;
        }
        entity_loc.* = new_loc;

        return true;
    }

    /// Wrap as `Optional`.
    pub fn toOptional(self: @This()) Optional {
        return .{ .key = self.key.toOptional() };
    }

    /// Materialise a View for this entity, or `null` if it doesn't
    /// exist or is missing any required components.  See `viewLib`
    /// for what a "View" is - basically a struct of pointers /
    /// optional pointers / `Entity` fields whose names match
    /// component types in this world.
    /// We pre-check the entity's archetype against the view's
    /// requirement bitset before walking the View fields.  For
    /// large views this is measurably faster than letting each
    /// per-field flag lookup discover absence on its own; the
    /// pre-check has no measurable cost when it's not needed.
    pub fn view(
        self: @This(),
        es: *const Registry,
        View: type,
    ) ?View {
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key) orelse return null;
        const chunk: *Chunk = entity_loc.chunk.get(&es.chunk_pool) orelse return null;
        const view_arch = viewLib.comps(es, View, .{ .size = .one }) orelse return null;
        const entity_arch: CompFlag.Set = chunk.header().list.arch(&es.arches);
        if (!entity_arch.supersetOf(view_arch)) {
            return null;
        }

        var result: View = undefined;
        const view_info = @typeInfo(View).@"struct";
        inline for (view_info.field_names, view_info.field_types) |field_name, field_type| {
            const Unwrapped: type = viewLib.UnwrapField(field_type, .{ .size = .one });
            if (Unwrapped == Entity) {
                @field(result, field_name) = self;
            } else {
                // https://codeberg.org/Games-by-Mason/mr_ecs/issues/24
                const offset: u32 = if (es.getCompFlag(typeId(Unwrapped))) |flag|
                    chunk.header().comp_buf_offsets.values[@backingInt(flag)]
                else
                    0;
                const is_optional: bool = @typeInfo(field_type) == .optional;
                if (is_optional and offset == 0) {
                    @field(result, field_name) = null;
                } else {
                    // Already covered by the supersetOf check above.
                    assert(offset != 0, @src());
                    const comps_addr: usize = @intFromPtr(chunk) + offset;
                    const comp_addr = comps_addr +
                        @backingInt(entity_loc.index_in_chunk) * @sizeOf(Unwrapped);
                    @field(result, field_name) = @ptrFromInt(comp_addr);
                }
            }
        }
        return result;
    }

    /// Single-component shorthand for `viewOrAddImmediate`.  Get
    /// `*T` if it exists, else add it with `default` and return
    /// the new pointer.  Most common use case for "ensure this
    /// component exists" patterns.
    pub fn getOrAddImmediate(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        T: type,
        default: T,
    ) ?*T {
        return self.getOrAddImmediateOrErr(es, gpa, T, default) catch |err|
            @panic(@errorName(err));
    }

    /// `getOrAddImmediate` that surfaces errors.  `gpa` is for
    /// flag-table growth on first use of `T`.
    pub fn getOrAddImmediateOrErr(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        T: type,
        default: T,
    ) error{ OutOfMemory, EcsArchOverflow, EcsChunkOverflow, EcsChunkPoolOverflow, EcsCompTypeOverflow }!?*T {
        const result = try self.viewOrAddImmediateOrErr(es, gpa, struct { *T }, .{&default}) orelse
            return null;
        return result[0];
    }

    /// Like `view`, but adds any missing non-optional components on
    /// the spot, taking their initial values from `comps` (a struct
    /// of pointer-typed fields whose names match the View).  Use
    /// when you want "give me a handle to position+velocity, adding
    /// them with these defaults if absent".
    /// `gpa` is needed because adding a component may register a
    /// fresh type with the world's flag table.  Invalidates
    /// pointers.
    pub fn viewOrAddImmediate(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        View: type,
        comps: anytype,
    ) ?View {
        return self.viewOrAddImmediateOrErr(es, gpa, View, comps) catch |err|
            @panic(@errorName(err));
    }

    /// `viewOrAddImmediate` that surfaces errors instead of panicking.
    pub fn viewOrAddImmediateOrErr(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        View: type,
        comps: anytype,
    ) error{ OutOfMemory, EcsArchOverflow, EcsChunkOverflow, EcsChunkPoolOverflow, EcsCompTypeOverflow }!?View {
        // Two-step: first add any missing components leaving them
        // uninitialised; then fill those slots from `comps`.  This
        // way we walk the View's fields once for "what's missing"
        // and once for "copy the default in" - the in-between
        // archetype change is a single batch.
        const result = (try self.viewOrAddUninitImmediateOrErr(es, gpa, View)) orelse return null;

        const view_info = @typeInfo(View).@"struct";
        inline for (view_info.field_names, view_info.field_types) |field_name, field_type| {
            const Unwrapped: type = viewLib.UnwrapField(field_type, .{ .size = .one });
            const comp_flag: CompFlag = es.getCompFlag(typeId(Unwrapped)).?;
            const has_default: bool = @hasField(@TypeOf(comps), field_name);
            const was_added: bool = result.uninitialized.contains(comp_flag);
            if (has_default and was_added) {
                @field(result.view, field_name).* = @field(comps, field_name).*;
            }
        }
        return result.view;
    }

    /// What `viewOrAddUninitImmediate*` returns: the materialised
    /// view, plus a bitset of which components in the View were
    /// added by THIS call (caller must initialise those before
    /// dropping the view).
    pub fn VoaUninitResult(View: type) type {
        return struct {
            uninitialized: CompFlag.Set,
            view: View,
        };
    }

    /// Like `viewOrAddImmediate` but doesn't initialise the added
    /// components - returns `(view, uninitialized_set)` so caller
    /// can fill them in directly without re-fetching.
    pub fn viewOrAddUninitImmediate(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        View: type,
    ) ?VoaUninitResult(View) {
        return self.viewOrAddUninitImmediateOrErr(es, gpa, View) catch |err|
            @panic(@errorName(err));
    }

    /// `viewOrAddUninitImmediate` that surfaces errors.  `gpa`
    /// covers flag-table growth on first use of any component
    /// type in `View`.
    pub fn viewOrAddUninitImmediateOrErr(
        self: @This(),
        es: *Registry,
        gpa: Allocator,
        View: type,
    ) error{
        OutOfMemory,
        EcsArchOverflow,
        EcsChunkOverflow,
        EcsChunkPoolOverflow,
        EcsCompTypeOverflow,
    }!?VoaUninitResult(View) {
        es.pointer_generation.increment();

        const entity_loc: *Entity.Location = es.handle_tab.get(self.key) orelse return null;

        // Build the View's required-component bitset, registering
        // each comp with the world if it's a fresh type.  Skip
        // Entity-typed and optional fields - they're not "required".
        var view_arch: CompFlag.Set = .{};
        inline for (@typeInfo(View).@"struct".field_types) |field_type| {
            const skip: bool = field_type == Entity or @typeInfo(field_type) == .optional;
            if (!skip) {
                const Unwrapped: type = viewLib.UnwrapField(field_type, .{ .size = .one });
                const flag = try es.registerComponent(gpa, typeId(Unwrapped));
                view_arch.insert(flag);
            }
        }

        const curr_arch: CompFlag.Set = entity_loc.arch(es);
        const uninit_set: CompFlag.Set = view_arch.differenceWith(curr_arch);
        if (!curr_arch.supersetOf(view_arch)) {
            // changeArchUninit returns a bool indicating "did the
            // entity exist?".  We already proved it does (we
            // unwrapped entity_loc above), so the assert is safe.
            assert(try self.changeArchUninitImmediateOrErr(es, .{ .add = uninit_set }), @src());
        }

        return .{
            .view = self.view(es, View).?,
            .uninitialized = uninit_set,
        };
    }

    /// Default formatting.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.key.format(writer);
    }

    /// The entity's archetype, or the empty arch if it's destroyed
    /// or uncommitted.
    pub fn arch(self: @This(), es: *const Registry) CompFlag.Set {
        const entity_loc: *Entity.Location = es.handle_tab.get(self.key) orelse return .{};
        return entity_loc.arch(es);
    }
};

// ============================================================================
// Chunk - packed entity storage
// ============================================================================

// ============================================================================
// ChunkList - list of chunks for one archetype
// ============================================================================

/// All chunks for one archetype.  Maintains two intrusive
/// doubly-linked lists through the chunks: `head`/`tail` for
/// "every chunk for this archetype", `avail` for "chunks with
/// at least one free slot".  Splitting the available list out
/// keeps add-entity O(1) - we don't have to scan past full
/// chunks looking for space.
pub const ChunkList = struct {
    /// First chunk in this list, walked via each chunk's `next`.
    /// `.none` when the archetype has no committed entities yet.
    head: Chunk.Index,
    /// Last chunk in this list.  `.none` symmetric with `head`.
    tail: Chunk.Index,
    /// First chunk in this list with free slots, walked via
    /// `next_avail`.  `.none` when every chunk is full.
    avail: Chunk.Index,
    /// Byte offset from chunk start to the per-entity index
    /// buffer (the `[]Entity.Index` parallel to the comp data).
    index_buf_offset: u32,
    /// Per-component byte offset, mirrored on each chunk's
    /// header.  This copy exists for cold paths that don't have a
    /// chunk in hand; hot paths read from the chunk header
    /// because that's the cache line they already touched.
    comp_buf_offsets_cold: std.enums.EnumArray(CompFlag, u32),
    /// How many entities fit in a single chunk for this
    /// archetype.  Computed once in `init` from chunk size,
    /// per-comp sizes, and the index buffer overhead.
    chunk_capacity: u32,

    /// Position in the owning `Arches` map - the same value
    /// indexes both keys (the archetype CompFlag.Set) and values
    /// (the ChunkList).
    pub const Index = enum(u32) {
        _,

        /// Resolve to the actual `*ChunkList`.
        pub fn get(self: @This(), arches: *const Arches) *ChunkList {
            return &arches.map.values()[@backingInt(self)];
        }

        /// Look up the archetype for this index.
        pub fn arch(self: Index, arches: *const Arches) CompFlag.Set {
            return arches.map.keys()[@backingInt(self)];
        }
    };

    /// Build a fresh chunk list for `arch`.  No chunks committed
    /// - that happens lazily in `reserve`.  This call just
    /// computes the per-archetype layout (component offsets,
    /// capacity per chunk) and stashes it on the list.
    /// Errors when an archetype's combined size won't fit in a
    /// single chunk (`EcsChunkOverflow`).  That's a sizing
    /// problem with `ChunkPool.cap.chunk` - make chunks bigger.
    pub fn init(
        es: *const Registry,
        cpool: *const ChunkPool,
        arch: CompFlag.Set,
    ) error{EcsChunkOverflow}!@This() {

        // Sort components by alignment, biggest first.  Two
        // reasons: (1) packing alignment-N values first wastes
        // less padding; (2) gives a deterministic layout
        // independent of registration order.
        var flag_buf: [CompFlag.max]CompFlag = undefined;
        const sorted: []CompFlag = sortCompsByAlignment(es, &flag_buf, arch);

        // Largest alignment of (any component, Entity.Index).
        // The data area starts after the header, aligned to this.
        var max_align: u32 = @alignOf(Entity.Index);
        if (sorted.len > 0) {
            max_align = @max(max_align, es.getCompType(sorted[0]).alignment);
        }

        const data_offset: u32 = alignForward(u32, @sizeOf(Chunk.Header), max_align);

        // Bytes available for entity data after the header.
        const bytes: u32 = math.subChecked(
            u32,
            @intCast(cpool.size_align.toByteUnits()),
            data_offset,
        ) catch return error.EcsChunkOverflow;

        // Bytes per entity = index slot + sum of component sizes.
        var entity_size: u32 = @sizeOf(Entity.Index);
        for (sorted) |comp| {
            const comp_size: u32 = math.cast(u32, es.getCompType(comp).size) orelse
                return error.EcsChunkOverflow;
            entity_size = math.addChecked(u32, entity_size, comp_size) catch
                return error.EcsChunkOverflow;
        }

        const chunk_capacity: u32 = bytes / entity_size;
        if (chunk_capacity <= 0) {
            return error.EcsChunkOverflow;
        }

        // Lay out the per-component buffers.  We slot the index
        // buffer in among the comp buffers: place it at the
        // first slot where its alignment is satisfied (`<=
        // @alignOf(Entity.Index)`).  This keeps higher-alignment
        // comps contiguous up front.
        var offset: u32 = data_offset;
        var comp_buf_offsets: std.enums.EnumArray(CompFlag, u32) = .initFill(0);
        var index_buf_offset: u32 = 0;
        for (sorted) |comp| {
            const id: TypeId = es.getCompType(comp);

            const idx_buf_unplaced: bool = index_buf_offset == 0;
            const fits_alignment: bool = id.alignment <= @alignOf(Entity.Index);
            if (idx_buf_unplaced and fits_alignment) {
                assert(offset % @alignOf(Entity.Index) == 0, @src());
                index_buf_offset = offset;
                const buf_size: u32 = math.mulChecked(u32, @sizeOf(Entity.Index), chunk_capacity) catch
                    return error.EcsChunkOverflow;
                offset = math.addChecked(u32, offset, buf_size) catch
                    return error.EcsChunkOverflow;
            }

            assert(offset % id.alignment == 0, @src());
            comp_buf_offsets.set(comp, offset);
            const comp_size: u32 = math.cast(u32, id.size) orelse
                return error.EcsChunkOverflow;
            const buf_size: u32 = math.mulChecked(u32, comp_size, chunk_capacity) catch
                return error.EcsChunkOverflow;
            offset = math.addChecked(u32, offset, buf_size) catch
                return error.EcsChunkOverflow;
        }

        // No comp had small-enough alignment to host the index
        // buffer - append it at the end.
        if (index_buf_offset == 0) {
            index_buf_offset = offset;
            const buf_size: u32 = math.mulChecked(u32, @sizeOf(Entity.Index), chunk_capacity) catch
                return error.EcsChunkOverflow;
            offset = math.addChecked(u32, offset, buf_size) catch
                return error.EcsChunkOverflow;
        }

        assert(offset <= cpool.size_align.toByteUnits(), @src());

        return .{
            .head = .none,
            .tail = .none,
            .avail = .none,
            .comp_buf_offsets_cold = comp_buf_offsets,
            .index_buf_offset = index_buf_offset,
            .chunk_capacity = chunk_capacity,
        };
    }

    /// Append `e` to this archetype.  Bumps `len` of whichever
    /// chunk currently has space; reserves a fresh chunk on the
    /// cpool overflow path.  The returned `Entity.Location` points
    /// at the newly-occupied slot.
    pub fn append(
        self: *@This(),
        es: *Registry,
        e: Entity,
    ) error{EcsChunkPoolOverflow}!Entity.Location {
        const cpool: *ChunkPool = &es.chunk_pool;
        const arches: *Arches = &es.arches;

        // No chunk with space?  Reserve one and link it on.
        if (self.avail == .none) {
            const new: *Chunk = try cpool.reserve(es, arches.indexOf(self));
            const new_index: Chunk.Index = cpool.indexOf(new);

            self.avail = new_index;

            // Stitch onto the doubly-linked head/tail list.
            if (self.tail.get(cpool)) |tail| {
                new.header().prev = self.tail;
                tail.header().next = new_index;
                self.tail = new_index;
            } else {
                self.head = new_index;
                self.tail = new_index;
            }
        }

        // Pick up the chunk we'll write to.
        const chunk: *Chunk = self.avail.get(cpool).?;
        const header: *Chunk.Header = chunk.header();
        assert(header.len < self.chunk_capacity, @src());
        chunk.checkAssertions(es, .allow_empty);

        // The const-cast is fine: chunks are originally mutable,
        // we just don't expose mutable index-buf access publicly.
        const index_in_chunk: Entity.Location.IndexInChunk = @fromBackingInt(@intCast(header.len));
        header.len += 1;
        const index_buf: []Entity.Index = @constCast(chunk.view(es, struct {
            indices: []const Entity.Index,
        }).?.indices);
        index_buf[@backingInt(index_in_chunk)] = @fromBackingInt(@intCast(e.key.index));

        // Chunk filled up?  Drop it off the avail list.
        if (header.len == self.chunk_capacity) {
            @branchHint(.unlikely);
            assert(self.avail.get(cpool) == chunk, @src());
            self.avail = chunk.header().next_avail;
            header.next_avail = .none;
            if (self.avail.get(cpool)) |avail| {
                const available_header: *Chunk.Header = avail.header();
                assert(available_header.prev_avail.get(cpool) == chunk, @src());
                available_header.prev_avail = .none;
            }
        }

        self.checkAssertions(es);

        return .{
            .chunk = es.chunk_pool.indexOf(chunk),
            .index_in_chunk = index_in_chunk,
        };
    }

    // Checks internal consistency.
    /// Internal-consistency check.  No-op outside runtime-safety
    /// builds.  Asserts the head/tail/avail invariants - head==null
    /// implies tail==null and avail==null; head!=null implies tail
    /// is reachable; the avail head's prev_avail is null.
    pub fn checkAssertions(self: *const @This(), es: *const Registry) void {
        if (!std.debug.runtime_safety) {
            return;
        }

        const cpool: *const ChunkPool = &es.chunk_pool;

        if (self.head.get(cpool)) |head| {
            const header: *Chunk.Header = head.header();
            head.checkAssertions(es, .default);
            self.tail.get(cpool).?.checkAssertions(es, .default);
            assert(@intFromBool(header.next != .none) ^
                @intFromBool(head == self.tail.get(cpool)) != 0, @src());
            assert(self.tail != .none, @src());
        } else {
            assert(self.tail == .none, @src());
            assert(self.avail == .none, @src());
        }

        if (self.avail.get(cpool)) |avail| {
            const header: *Chunk.Header = avail.header();
            avail.checkAssertions(es, .default);
            assert(header.prev_avail == .none, @src());
        }
    }

    /// Iterator over the chunks in this list, in head→tail order.
    /// Mutating pointers during iteration trips the
    /// pointer-generation guard.
    pub fn iterator(self: *const @This(), es: *const Registry) Iterator {
        self.checkAssertions(es);
        return .{
            .chunk = self.head.get(&es.chunk_pool),
            .pointer_lock = es.pointer_generation.lock(),
        };
    }

    /// An iterator over a chunk list's chunks.
    pub const Iterator = struct {
        /// An iterator that yields nothing.  Returned when there's
        /// no head chunk to start from.
        pub fn empty(es: *const Registry) @This() {
            return .{
                .chunk = null,
                .pointer_lock = es.pointer_generation.lock(),
            };
        }

        chunk: ?*Chunk,
        pointer_lock: PointerLock,

        /// Advance and return the next chunk, or null at the end.
        pub fn next(self: *@This(), es: *const Registry) ?*Chunk {
            self.pointer_lock.check(es.pointer_generation);
            const chunk: *Chunk = self.chunk orelse {
                @branchHint(.unlikely);
                return null;
            };
            chunk.checkAssertions(es, .default);
            const header: *Chunk.Header = chunk.header();
            self.chunk = header.next.get(&es.chunk_pool);
            return chunk;
        }

        /// Current chunk without advancing.
        pub fn peek(self: @This(), es: *const Registry) ?*Chunk {
            self.pointer_lock.check(es.pointer_generation);
            return self.chunk;
        }
    };

    /// Sort comparator for `sortCompsByAlignment`.  Greater
    /// alignment first.  Context is `*const Registry` because the
    /// per-flag alignment lookup goes through the world's registry.
    fn alignmentGte(
        es: *const Registry,
        lhs: CompFlag,
        rhs: CompFlag,
    ) bool {
        const lhs_alignment: u8 = es.getCompType(lhs).alignment;
        const rhs_alignment: u8 = es.getCompType(rhs).alignment;
        return lhs_alignment >= rhs_alignment;
    }

    /// Returns a list of the components in this set sorted from
    /// greatest to least alignment.  The sort key (per-component
    /// alignment) lives in `es`'s registry, so the world has to
    /// be threaded in.  Optimization to reduce padding + necessary
    /// for consistent chunk cutoffs regardless of registration order.
    inline fn sortCompsByAlignment(
        es: *const Registry,
        buf: *[CompFlag.max]CompFlag,
        set: CompFlag.Set,
    ) []CompFlag {
        var comps: ArrayList(CompFlag) = .initBuffer(buf);
        var iter: CompFlag.Set.Iterator = set.iterator();
        while (iter.next()) |flag| {
            comps.appendAssumeCapacity(flag);
        }
        std.sort.pdq(CompFlag, comps.items, es, alignmentGte);
        return comps.items;
    }

    test sortCompsByAlignment {
        // Per-world registry: this test instantiates its own
        // `Registry` and registers components against it, no
        // process-global state involved.
        var es: Registry = try .init(.{
            .gpa = std.testing.allocator,
            .cap = .{ .entities = 32, .arches = 4, .chunks = 8, .chunk = 4096 },
        });
        defer es.deinit(std.testing.allocator);

        const ta: Allocator = std.testing.allocator;

        // Register various components with different alignments in an arbitrary order
        const a_1 = try es.registerComponent(ta, typeId(struct { x: u8 align(1) }));
        const e_2 = try es.registerComponent(ta, typeId(struct { x: u8 align(16) }));
        const d_2 = try es.registerComponent(ta, typeId(struct { x: u8 align(8) }));
        const e_0 = try es.registerComponent(ta, typeId(struct { x: u8 align(16) }));
        const b_2 = try es.registerComponent(ta, typeId(struct { x: u8 align(2) }));
        const d_0 = try es.registerComponent(ta, typeId(struct { x: u8 align(8) }));
        const a_2 = try es.registerComponent(ta, typeId(struct { x: u8 align(1) }));
        const e_1 = try es.registerComponent(ta, typeId(struct { x: u8 align(16) }));
        const c_0 = try es.registerComponent(ta, typeId(struct { x: u8 align(4) }));
        const b_0 = try es.registerComponent(ta, typeId(struct { x: u8 align(2) }));
        const b_1 = try es.registerComponent(ta, typeId(struct { x: u8 align(2) }));
        const a_0 = try es.registerComponent(ta, typeId(struct { x: u8 align(1) }));
        const c_2 = try es.registerComponent(ta, typeId(struct { x: u8 align(4) }));
        const c_1 = try es.registerComponent(ta, typeId(struct { x: u8 align(4) }));
        const d_1 = try es.registerComponent(ta, typeId(struct { x: u8 align(8) }));

        // Test sorting all of them
        {
            var flag_buf: [CompFlag.max]CompFlag = undefined;
            const sorted: []CompFlag = sortCompsByAlignment(&es, &flag_buf, .initMany(&.{
                e_0, c_1, d_0, e_1, a_1, b_1, b_0, a_0,
                d_1, c_0, c_2, e_2, a_2, b_2, d_2,
            }));
            try expectEqual(15, sorted.len);
            var prev: usize = math.maxInt(usize);
            for (sorted) |flag| {
                const curr: u8 = es.getCompType(flag).alignment;
                try expect(curr <= prev);
                prev = curr;
            }
        }

        // Test sorting a subset of them
        {
            var flag_buf: [CompFlag.max]CompFlag = undefined;
            const sorted: []CompFlag = sortCompsByAlignment(&es, &flag_buf, .initMany(&.{
                e_0, d_0, c_0, a_0, b_0,
            }));
            try expectEqual(5, sorted.len);
            try expectEqual(e_0, sorted[0]);
            try expectEqual(d_0, sorted[1]);
            try expectEqual(c_0, sorted[2]);
            try expectEqual(b_0, sorted[3]);
            try expectEqual(a_0, sorted[4]);
        }
    }
};

// ============================================================================
// ChunkPool - pre-allocated cpool of chunks
// ============================================================================

/// Pre-allocated cpool of fixed-size chunks.  All entity component
/// data lives in some chunk; chunks come from this cpool and return
/// to the free list when they're emptied.  No heap traffic during
/// gameplay - the whole cpool is allocated at `init` and the
/// allocator never sees another byte until `deinit`.
pub const ChunkPool = struct {
    /// The pre-allocated chunk arena.  Sized at init to
    /// `cap.chunks * cap.chunk`.  All chunks live somewhere in
    /// these bytes.
    buf: []u8,
    /// Bump pointer (in chunk units): how many chunks have been
    /// handed out since `clear`.  Indices `[0, reserved)` of the
    /// arena have been used at least once.
    reserved: u32,
    /// Chunk size AND chunk alignment, both equal.  Equal-and-
    /// aligned-to-size lets `Entity.from(*comp)` round a
    /// component pointer down to find its chunk header in one
    /// `& ~(chunk_size - 1)` op.  It also dodges false sharing
    /// (chunks don't straddle cache lines) and keeps internal
    /// allocations stable: alignment >= TypeInfo.max_align means
    /// chunk capacity doesn't depend on where in memory the cpool
    /// landed.
    size_align: Alignment,
    /// Linked list of freed chunks (via `Chunk.Header.next`),
    /// `.none` when empty.  `reserve` pops here before bumping.
    free: Chunk.Index = .none,

    /// The cpool's capacity.
    pub const Capacity = struct {
        /// Chunk count.  Range `[0, maxInt(u32))` - max-int is
        /// reserved as the `.none` sentinel for `Chunk.Index`.
        chunks: u16,
        /// Per-chunk byte size.  Must be ≥ `TypeInfo.max_align`
        /// (asserted at init).
        chunk: u32,
    };

    /// Allocate the chunk arena and return a fresh cpool.  Single
    /// upfront allocation; `deinit` is the only call that hits
    /// the allocator again.
    pub fn init(gpa: Allocator, cap: Capacity) Allocator.Error!@This() {
        // Max u32 is reserved for the .none sentinel.
        assert(cap.chunks < math.maxInt(u32), @src());
        assert(cap.chunk >= TypeInfo.max_align.toByteUnits(), @src());

        const alignment: Alignment = Alignment.fromByteUnits(cap.chunk);
        const len: usize = @as(usize, cap.chunk) * @as(usize, cap.chunks);
        const buf: []u8 = (gpa.rawAlloc(
            len,
            alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory)[0..len];
        errdefer comptime unreachable;

        return .{
            .buf = buf,
            .reserved = 0,
            .size_align = alignment,
        };
    }

    /// Free the arena.  After this `self.*` is undefined.
    pub fn deinit(self: *@This(), gpa: Allocator) void {
        gpa.rawFree(self.buf, self.size_align, @returnAddress());
        self.* = undefined;
    }

    /// Reset to "freshly initialized": empty free list, zero
    /// reserved.  The arena bytes stay; existing chunks become
    /// reusable on the next `reserve`.
    pub fn clear(self: *@This()) void {
        self.reserved = 0;
        self.free = .none;
    }

    /// Hand out a chunk.  Tries the free list first (LIFO), falls
    /// back to bumping into the arena.  Returns
    /// `EcsChunkPoolOverflow` when both are exhausted - that's the
    /// signal to grow `cap.chunks` in `Registry.init`.
    pub fn reserve(
        self: *@This(),
        es: *const Registry,
        list: ChunkList.Index,
    ) error{EcsChunkPoolOverflow}!*Chunk {
        const chunk: *Chunk = if (self.free.get(self)) |free| b: {
            self.free = free.header().next;
            break :b free;
        } else b: {
            // Bump the arena.
            const byte_idx: u32 = @shlExact(self.reserved, @intCast(@backingInt(self.size_align)));
            if (byte_idx >= self.buf.len) {
                return error.EcsChunkPoolOverflow;
            }
            const fresh: *Chunk = @ptrCast(&self.buf[byte_idx]);
            self.reserved = self.reserved + 1;
            break :b fresh;
        };
        errdefer comptime unreachable; // free list mutated above - no rollback path

        assert(self.size_align.check(@intFromPtr(chunk)), @src());

        const header: *Chunk.Header = chunk.header();
        header.* = .{
            .comp_buf_offsets = list.get(&es.arches).comp_buf_offsets_cold,
            .list = list,
            .len = 0,
        };
        return chunk;
    }

    /// Reverse-lookup a chunk's index in the arena.  The chunk
    /// must come from `self.buf`; out-of-cpool pointers trip the
    /// asserts.
    pub fn indexOf(self: *const @This(), chunk: *const Chunk) Chunk.Index {
        assert(@intFromPtr(chunk) >= @intFromPtr(self.buf.ptr), @src());
        assert(@intFromPtr(chunk) < @intFromPtr(self.buf.ptr) + self.buf.len, @src());
        const offset: usize = @intFromPtr(chunk) - @intFromPtr(self.buf.ptr);
        assert(offset < self.buf.len, @src());
        return @fromBackingInt(@intCast(@shrExact(offset, @backingInt(self.size_align))));
    }
};

// ============================================================================
// Arches - archetype → ChunkList map
// ============================================================================

// ============================================================================
// Subcmd - encoded subcommands for CmdBuf
// ============================================================================

// ============================================================================
// CmdBuf - buffered ECS commands
// ============================================================================

/// A queue of pending entity edits.  Replays atomically against
/// an `Registry` instance via `Exec.immediate`.  Useful when you
/// want to add/remove components or destroy entities while
/// iterating - direct mutation would invalidate the iterator,
/// while queueing into a `CmdBuf` defers all writes until the
/// iteration loop ends.
/// Allocation is upfront, like `Registry`: `init` reserves the
/// full `Capacity`, and overflow returns
/// `error.EcsCmdBufOverflow` rather than reallocating.
pub const CmdBuf = struct {
    name: ?[:0]const u8,
    /// Per-subcommand kind tags.  Two tags per command max.
    tags: ArrayList(Subcmd.TagEnum),
    /// Per-subcommand u64 args (entity handles, comp IDs,
    /// pointer values).  Three args per command max.
    args: ArrayList(u64),
    /// Inline payloads (component values copied by value,
    /// extension data).  Aligned to `TypeInfo.max_align` so any
    /// component can be stored in-place.
    data: ArrayListAligned(u8, TypeInfo.max_align),
    /// The currently-bound entity for the next encoded subcmd.
    /// Subcmd encoders skip emitting a redundant `bind` when
    /// the entity hasn't changed since the last command.
    binding: Entity.Optional = .none,
    /// Pre-reserved entity handles, drawn from `Entity.reserve` /
    /// `Entity.create`.  Refilled to capacity in `clear`.
    reserved: ArrayList(Entity),
    /// Runtime-safety latch: set when an OrErr op returns an
    /// error and the buffer is in a partially-encoded state.
    /// Subsequent ops assert against this to catch use-after-
    /// failure.  Compiled out in release builds.
    invalid: if (std.debug.runtime_safety) bool else void,
    /// Trigger a warning from `updateStats` when any of the four
    /// internal ArrayLists exceeds this fraction (0..1) of its
    /// capacity.  Set to 1.0 to disable.
    warn_ratio: f32,

    /// Options for `init`.
    pub const InitOptions = struct {
        /// Debug name for this buffer; surfaces in
        /// `updateStats` warnings.
        name: ?[:0]const u8,
        /// Backing allocator.  All four internal lists allocate
        /// from here once at init; nothing else.
        gpa: Allocator,
        /// Registry are reserved from here on init.
        es: *Registry,
        /// Up-front capacity for the four buffers.
        cap: Capacity = .{},
        /// Warn-threshold fraction for `updateStats`.  Default
        /// 0.2 = "warn at 20% so you have time to grow `cap`."
        warn_ratio: f32 = 0.2,
    };

    /// The capacity of a command buffer.  Tunable per the kind
    /// of workload - bulk spawn favors high `cmds`, bulk component
    /// add favors high `data`.
    pub const Capacity = struct {
        /// Default `cmds` if not specified.
        pub const default_cmds = 100000;
        /// Default ratio when `reserved_entities` is null:
        /// `cmds / 4`.  Each "create new entity" command consumes
        /// one reserved handle.
        pub const entities_ratio = 4;

        /// Reserve space for at least this many commands.  `null`
        /// → `default_cmds`.  Optional so `CmdPool` can override
        /// with a lower per-cpool value.
        cmds: ?usize = null,
        /// Reserve this much byte budget for inline payloads.
        /// `bytes_per_cmd` is the typical pick (multiplies by
        /// `cmds`); `bytes` lets you cap the absolute total.
        data: union(enum) {
            bytes: usize,
            bytes_per_cmd: u32,
        } = .{ .bytes_per_cmd = 2 * 16 * @sizeOf(f32) },
        /// Pre-reserved entity handle cpool size.  `null` →
        /// `cmds / entities_ratio`.
        reserved_entities: ?usize = null,

        /// `cmds` with the null fallback applied.
        fn getCmds(self: @This()) usize {
            return self.cmds orelse default_cmds;
        }

        /// Total `data` byte budget, fold-in of the union shape.
        fn dataBytes(self: @This()) usize {
            return switch (self.data) {
                .bytes => |bytes| bytes,
                .bytes_per_cmd => |bytes_per_cmd| self.getCmds() * bytes_per_cmd,
            };
        }

        /// `reserved_entities` with the null fallback applied.
        fn reservedEntities(self: @This()) usize {
            return self.reserved_entities orelse self.getCmds() / entities_ratio;
        }
    };

    /// Allocate the four backing buffers and pre-reserve the
    /// entity-handle cpool.  Errors on allocator OOM and on entity
    /// cpool exhaustion (the world's `cap.entities` ceiling).
    pub fn init(options: InitOptions) error{ OutOfMemory, EcsEntityOverflow }!@This() {
        comptime assert(CompFlag.max < maxInt(u64), @src());

        // Subcmd encoder uses at most two tags per command.
        _ = Subcmd.rename_when_changing_encoding;
        const cmds_cap: usize = options.cap.getCmds() * 2;
        var tags: ArrayList(Subcmd.TagEnum) = try .initCapacity(options.gpa, cmds_cap);
        errdefer tags.deinit(options.gpa);

        // Up to 3 args per command (the addPtr subcommand emits
        // a `bind` arg when the binding changed, plus comp ID
        // and pointer args of its own).
        _ = Subcmd.rename_when_changing_encoding;
        const args_cap: usize = cmds_cap * 3;
        var args: ArrayList(u64) = try .initCapacity(options.gpa, args_cap);
        errdefer args.deinit(options.gpa);

        var data: ArrayListAligned(u8, TypeInfo.max_align) = try .initCapacity(
            options.gpa,
            options.cap.dataBytes(),
        );
        errdefer data.deinit(options.gpa);

        var reserved_list: ArrayList(Entity) = try .initCapacity(
            options.gpa,
            options.cap.reservedEntities(),
        );
        errdefer reserved_list.deinit(options.gpa);
        for (0..reserved_list.capacity) |_| {
            reserved_list.appendAssumeCapacity(try Entity.reserveImmediateOrErr(options.es));
        }

        return .{
            .name = options.name,
            .reserved = reserved_list,
            .tags = tags,
            .args = args,
            .data = data,
            .invalid = if (std.debug.runtime_safety) false else {},
            .warn_ratio = options.warn_ratio,
        };
    }

    /// Free all four buffers and destroy the pre-reserved
    /// entities.  Caller must pass the same `gpa` and `es` they
    /// passed to `init`.
    pub fn deinit(
        self: *@This(),
        gpa: Allocator,
        es: *Registry,
    ) void {
        for (self.reserved.items) |entity| {
            assert(entity.destroyImmediate(es), @src());
        }
        self.reserved.deinit(gpa);
        self.data.deinit(gpa);
        self.args.deinit(gpa);
        self.tags.deinit(gpa);
        self.* = undefined;
    }

    /// Encode an extension command - a custom payload type that
    /// the executor handles via `Exec.extImmediateOrErr`.  Use
    /// extension commands for app-defined ops the core ECS
    /// doesn't model (sound triggers, scenegraph reparents, etc).
    /// Returns a pointer to the encoded copy of `payload`, valid
    /// until the next `clear`.  The pass-by-value/pass-by-ref
    /// distinction follows `Entity.add`: if `T` is bigger than a
    /// pointer AND the value is comptime-known, we intern the
    /// constant and store a pointer; otherwise we copy by value.
    pub inline fn ext(
        self: *@This(),
        T: type,
        payload: T,
    ) *const T {
        // Don't get tempted to remove inline from here - required
        // for `isComptimeKnown` to see the call-site value.
        comptime assert(@typeInfo(@TypeOf(ext)).@"fn".attrs.@"callconv" == .@"inline", @src());
        const big_and_known: bool =
            @sizeOf(T) > @sizeOf(*T) and meta.isComptimeKnown(payload);
        if (big_and_known) {
            const Interned = struct {
                const value = payload;
            };
            const ptr: *const T = comptime &Interned.value;
            self.extPtr(T, ptr);
            return ptr;
        } else {
            return self.extVal(T, payload);
        }
    }

    /// Force pass-by-value encoding.  Returns a pointer into the
    /// command buffer's `data` arena (valid until `clear`).
    /// Prefer `ext` unless you specifically want the in-buffer
    /// pointer back.
    pub fn extVal(
        self: *@This(),
        T: type,
        payload: T,
    ) *T {
        return self.extValOrErr(T, payload) catch |err|
            @panic(@errorName(err));
    }

    /// Like `extVal` but surfaces overflow as a return error.
    /// On error the buffer is in an undefined state - see the
    /// `CmdBuf` top-level doc.
    pub fn extValOrErr(
        self: *@This(),
        T: type,
        payload: T,
    ) error{EcsCmdBufOverflow}!*T {
        return Subcmd.encodeExtVal(self, T, payload);
    }

    /// Force pass-by-reference encoding.  The caller's `payload`
    /// must outlive the buffer.  Prefer `ext` unless you want
    /// the no-copy guarantee.
    pub fn extPtr(
        self: *@This(),
        T: type,
        payload: *const T,
    ) void {
        return self.extPtrOrErr(T, payload) catch |err|
            @panic(@errorName(err));
    }

    /// `extPtr` with error return.  See `extValOrErr`.
    pub fn extPtrOrErr(
        self: *@This(),
        T: type,
        payload: *const T,
    ) error{EcsCmdBufOverflow}!void {
        try Subcmd.encodeExtPtr(self, T, payload);
    }

    /// Reset the buffer for reuse and refill the reserved-entity
    /// cpool to capacity.  Called automatically by `Exec.immediate`
    /// after a successful run.
    pub fn clear(self: *@This(), es: *Registry) void {
        self.clearOrErr(es) catch |err| @panic(@errorName(err));
    }

    /// Like `clear` but surfaces the entity-cpool refill error
    /// instead of panicking.
    pub fn clearOrErr(self: *@This(), es: *Registry) error{EcsEntityOverflow}!void {
        self.data.clearRetainingCapacity();
        self.args.clearRetainingCapacity();
        self.tags.clearRetainingCapacity();
        self.binding = .none;
        while (self.reserved.items.len < self.reserved.capacity) {
            self.reserved.appendAssumeCapacity(try Entity.reserveImmediateOrErr(es));
        }
    }

    /// True when no commands are queued AND the reserved-entity
    /// cpool is full (i.e. nothing has been encoded since the
    /// last `clear`).
    pub fn isEmpty(self: @This()) bool {
        const no_cmds: bool = self.tags.items.len == 0;
        const reserved_full: bool = self.reserved.items.len == self.reserved.capacity;
        return no_cmds and reserved_full;
    }

    /// The fullest of the four internal buffers, as a 0..1
    /// fraction.  Buffers explicitly initialised with capacity 0
    /// score 0.  `reserved` is inverted: `items.len` shrinks as
    /// the cpool is consumed, so its usage is
    /// `(capacity - items.len) / capacity`, not
    /// `items.len / capacity` like the others.
    pub fn worstCaseUsage(self: @This()) f32 {
        const reserved_used: f32 = float(self.reserved.capacity - self.reserved.items.len);
        const reserved_usage: f32 = if (self.reserved.capacity == 0)
            0.0
        else
            reserved_used / float(self.reserved.capacity);
        return @max(
            usage(self.data),
            usage(self.args),
            usage(self.tags),
            reserved_usage,
        );
    }

    /// Length-over-capacity for any of the three append-only
    /// buffers (`data`, `args`, `tags`).  Three callers, so it
    /// earns its keep as a helper.  `reserved` doesn't fit this
    /// shape (its semantics are inverted) and inlines into
    /// `worstCaseUsage` directly.
    fn usage(list: anytype) f32 {
        if (list.capacity == 0) {
            return 0.0;
        }
        const len_f: f32 = float(list.items.len);
        const cap_f: f32 = float(list.capacity);
        return len_f / cap_f;
    }

    /// Iterate the encoded subcommands in insertion order.
    /// Each `next()` returns one `Batch` - either a contiguous
    /// run of arch-change ops on the same entity, or a single
    /// extension command.
    pub fn iterator(self: *const @This()) Iterator {
        if (std.debug.runtime_safety) {
            assert(!self.invalid, @src());
        }
        return .{ .decoder = .{ .cb = self } };
    }

    /// Emit a one-line warning if `worstCaseUsage` is past
    /// `warn_ratio`.  Called automatically at the end of
    /// `Exec.immediate`; user code can call it ad-hoc to check
    /// pressure mid-frame.
    pub fn updateStats(self: *const CmdBuf) void {
        const current_usage: f32 = self.worstCaseUsage();
        if (current_usage > self.warn_ratio) {
            log.warn("command buffer past 50% capacity (buffer name = {?s})", .{self.name});
        }
    }

    /// Default executor for a CmdBuf.  Holds no state of its
    /// own - every method is essentially a static function - but
    /// exists as a struct so extension types like
    /// `Node.Exec` can shadow it with their own
    /// `extImmediateOrErr` / `finish` overrides while reusing
    /// the same `immediate` / `immediateOrErr` driver shape.
    pub const Exec = struct {
        pub fn init() @This() {
            return .{};
        }

        /// Replay every queued subcommand against `es` and clear
        /// the buffer when done.  `gpa` is required because
        /// pending `add` ops may register fresh component types
        /// against the world's flag table.
        /// Invalidates pointers (the world's pointer-generation
        /// is bumped on entry).
        pub fn immediate(
            es: *Registry,
            gpa: Allocator,
            cb: *CmdBuf,
        ) void {
            immediateOrErr(es, gpa, cb) catch |err| @panic(@errorName(err));
        }

        /// Like `immediate`, but surfaces the failure path as an
        /// error union.  On error the buffer is left partially
        /// executed and `cb.invalid` is latched (debug builds).
        pub fn immediateOrErr(
            es: *Registry,
            gpa: Allocator,
            cb: *CmdBuf,
        ) error{
            OutOfMemory,
            EcsArchOverflow,
            EcsChunkOverflow,
            EcsChunkPoolOverflow,
            EcsCompTypeOverflow,
            EcsEntityOverflow,
        }!void {
            var self: @This() = .init();

            es.pointer_generation.increment();
            var iter: Iterator = cb.iterator();
            while (iter.next()) |batch| {
                switch (batch) {
                    .arch_change => |arch_change| {
                        const delta: Batch.ArchChange.Delta = try arch_change.deltaImmediate(es, gpa);
                        _ = try arch_change.execImmediateOrErr(es, delta);
                    },
                    .ext => |payload| self.extImmediateOrErr(payload),
                }
            }

            try self.finish(cb, es);
        }

        /// Hook for extension command handling - base `Exec`
        /// drops payloads on the floor.  Override on a custom
        /// `Exec`-like struct to handle your own `ext` types.
        pub fn extImmediateOrErr(self: *@This(), payload: Any) void {
            _ = self;
            _ = payload;
        }

        /// Hook for end-of-execution cleanup - base `Exec` runs
        /// `updateStats` then `clear`.  Override to add your own
        /// post-replay work (e.g. Node.Exec's deferred-tree-mutation
        /// flush).
        pub fn finish(
            self: *@This(),
            cb: *CmdBuf,
            es: *Registry,
        ) error{EcsEntityOverflow}!void { // lint:off useless-error-return: hook contract, overrides error
            _ = self;
            cb.updateStats();
            cb.clear(es);
        }
    };

    /// One unit of work yielded by the CmdBuf iterator.  Either
    /// a run of arch-change ops (add/remove/destroy) bound to a
    /// single entity, or one extension command's payload.
    pub const Batch = union(enum) {
        ext: Any,
        arch_change: ArchChange,

        /// All the queued add/remove/destroy ops for one entity.
        /// Replay happens in two phases: `deltaImmediate` first
        /// (collapses the ops into a single CompFlag.Set delta +
        /// destroy bool), then `execImmediateOrErr` (does the
        /// archetype change + component-byte writes).
        pub const ArchChange = struct {
            /// The collapsed effect of every add/remove/destroy in
            /// this batch.  Repeated add+remove of the same comp
            /// folds away; a `destroy` swallows everything after.
            pub const Delta = struct {
                add: CompFlag.Set = .{},
                remove: CompFlag.Set = .{},
                destroy: bool = false,

                /// Fold one op into the running delta.  add and
                /// remove may register fresh component types
                /// against `es`'s flag table - that's the only
                /// reason we take `gpa` here.
                pub inline fn updateImmediate(
                    self: *@This(),
                    es: *Registry,
                    gpa: Allocator,
                    op: Op,
                ) error{ OutOfMemory, EcsCompTypeOverflow }!void {
                    switch (op) {
                        .add => |comp| {
                            const flag: CompFlag = try es.registerComponent(gpa, comp.id);
                            self.add.insert(flag);
                            self.remove.remove(flag);
                        },
                        .remove => |id| {
                            const flag: CompFlag = try es.registerComponent(gpa, id);
                            self.add.remove(flag);
                            self.remove.insert(flag);
                        },
                        .destroy => self.destroy = true,
                    }
                }
            };

            /// Which entity this batch's ops apply to.
            entity: Entity,
            /// Decoder cursor positioned just after the
            /// `bind_entity` that started this batch.  Walking
            /// `iterator()` consumes from here.
            decoder: Subcmd.Decoder,

            /// Walk this batch's ops once, collapsing them into
            /// a `Delta`.  Registers any new component types
            /// with `es`.
            pub inline fn deltaImmediate(
                self: @This(),
                es: *Registry,
                gpa: Allocator,
            ) error{ OutOfMemory, EcsCompTypeOverflow }!Delta {
                var delta: Delta = .{};
                var ops = self.iterator();
                while (ops.next()) |op| {
                    try delta.updateImmediate(es, gpa, op);
                }
                return delta;
            }

            /// Iterate the individual ops in this batch.
            pub inline fn iterator(self: @This()) @This().Iterator {
                return .{ .decoder = self.decoder };
            }

            /// Replay this batch against `es`.  Returns `true` if
            /// the entity existed when ops applied, `false` if it
            /// was already destroyed by some earlier batch.
            /// `delta` must come from `deltaImmediate` on this
            /// SAME batch - that call registered any fresh comp
            /// types, so this one doesn't need `gpa`.
            pub fn execImmediate(
                self: @This(),
                es: *Registry,
                delta: Delta,
            ) bool {
                return self.execImmediateOrErr(es, delta) catch |err|
                    @panic(@errorName(err));
            }

            /// `execImmediate` with error return for the chunk-
            /// cpool / arch-table / arch-overflow paths.
            pub inline fn execImmediateOrErr(
                self: @This(),
                es: *Registry,
                delta: Delta,
            ) error{ EcsArchOverflow, EcsChunkOverflow, EcsChunkPoolOverflow }!bool {
                if (delta.destroy) {
                    return self.entity.destroyImmediate(es);
                }

                // Phase 1: shape the entity into its new archetype.
                // Empty delta still hits this path - it's how a
                // reserved (uncommitted) entity gets committed.
                const did_exist: bool = try self.entity.changeArchUninitImmediateOrErr(es, .{
                    .add = delta.add,
                    .remove = delta.remove,
                });
                if (!did_exist) {
                    return false;
                }

                // Phase 2: write component bytes for each `add`.
                // Phase 1 committed the entity if it was reserved,
                // so handle-table + chunk-cpool lookups must hit.
                const entity_loc: *Entity.Location = es.handle_tab.get(self.entity.key).?;
                const chunk: *Chunk = entity_loc.chunk.get(&es.chunk_pool).?;
                var ops: ArchChange.Iterator = self.iterator();
                while (ops.next()) |op| {
                    switch (op) {
                        .add => |comp| {
                            // Component could have been removed
                            // between Phase 1 and now (concurrent
                            // ops in another iterator branch)
                            // skip if no longer mapped.
                            const flag: CompFlag = es.getCompFlag(comp.id) orelse continue;
                            const offset: u32 = chunk.header()
                                .comp_buf_offsets.values[@backingInt(flag)];
                            if (offset == 0) {
                                continue;
                            }
                            const dest_unsized: [*]u8 = @ptrFromInt(@intFromPtr(chunk) +
                                offset +
                                @backingInt(entity_loc.index_in_chunk) * comp.id.size);
                            const dest: []u8 = dest_unsized[0..comp.id.size];
                            @memcpy(dest, comp.bytes());
                        },
                        .remove, .destroy => {},
                    }
                }

                return true;
            }

            /// One arch-change op: add a comp by value/pointer,
            /// remove a comp by ID, or destroy the entity.
            pub const Op = union(enum) {
                add: Any,
                remove: TypeId,
                destroy: void,
            };

            /// Walk one batch's queue of arch-change ops.
            /// Quirk: ops following a `destroy` are silently
            /// dropped.  Saves the executor from having to write
            /// "post-destroy nothing-matters" branches in every
            /// pre-exec loop.  No semantic loss - the entity is
            /// gone after destroy, anything else would be a no-op.
            pub const Iterator = struct {
                decoder: Subcmd.Decoder,

                /// Next op, or null at end of batch.
                pub inline fn next(self: *@This()) ?Op {
                    while (self.decoder.peekTag()) |tag| {
                        const op: Op = switch (tag) {
                            .add_val => .{ .add = self.decoder.next().?.add_val },
                            .add_ptr => .{ .add = self.decoder.next().?.add_ptr },
                            .remove => .{ .remove = self.decoder.next().?.remove },
                            .destroy => b: {
                                _ = self.decoder.next().?.destroy;
                                // Drop everything else in this
                                // batch - see Iterator docs above.
                                self.decoder.clear();
                                break :b .destroy;
                            },
                            // bind_entity / ext_val / ext_ptr
                            // start the NEXT batch - stop here.
                            .bind_entity, .ext_val, .ext_ptr => break,
                        };
                        return op;
                    }
                    return null;
                }
            };
        };
    };

    /// Iterates the encoded subcommand stream, lifting it from
    /// the per-subcmd "tag + args + data" representation into
    /// `Batch`-shaped chunks that group same-entity ops together.
    pub const Iterator = struct {
        decoder: Subcmd.Decoder,

        /// Next batch, or `null` at end of stream.
        pub inline fn next(self: *@This()) ?Batch {
            _ = Subcmd.rename_when_changing_encoding;

            // The decoder hands us atomic subcommands; we
            // gather the ones that belong to the same entity into
            // one Batch.arch_change by stashing the decoder
            // position alongside the entity handle and letting
            // ArchChange.iterator walk forward.  Extension
            // payloads (`ext_val` / `ext_ptr`) pass through as
            // their own one-shot batches.
            while (self.decoder.next()) |cmd| {
                switch (cmd) {
                    .bind_entity => |entity| return .{ .arch_change = .{
                        .entity = entity,
                        .decoder = self.decoder,
                    } },
                    .ext_val, .ext_ptr => |payload| return .{ .ext = payload },
                    // Add/remove/destroy are children of an
                    // arch_change batch - they're always preceded
                    // by a bind_entity, so we'll have returned
                    // before getting here unless they're trailing
                    // garbage from a prior batch's iterator
                    // position.  Skip and look for the next bind.
                    .add_ptr, .add_val, .remove, .destroy => {},
                }
            }

            return null;
        }
    };
};

// ============================================================================
// Registry - top-level storage
// ============================================================================

/// The world handle.  Owns every entity, every component, every
/// chunk, every per-world registry - pass `*Registry` (or
/// `*const Registry`) to anything that needs to read or mutate
/// world state.  Two `Registry` in the same process are fully
/// independent; sharing flags between them is undefined.
/// Lifecycle: `init(.{ .gpa = ... })` to allocate the preallocated
/// pools, `deinit(gpa)` to free them.  All allocations are upfront
/// against `cap`; growth past those limits returns
/// `EcsEntityOverflow` / `EcsArchOverflow` / `EcsChunkPoolOverflow`
/// rather than asking the allocator for more.  This shape
/// matches WASM use where heap growth is expensive.
pub const Registry = struct {
    handle_tab: HandleTab,
    arches: Arches,
    pointer_generation: PointerLock.Generation = .{},
    reserved_entities: usize = 0,
    chunk_pool: ChunkPool,
    /// Highest `handle_tab.saturated` value we've already warned
    /// about; lets `updateStats` only warn once per N saturations.
    warned_saturated: u64 = 0,
    /// One-shot flags so `updateStats` doesn't spam the log when
    /// any one preallocated cpool crosses `warn_ratio`.
    warned_capacity: bool = false,
    warned_chunk_pool: bool = false,
    warned_arches: bool = false,
    /// Fraction (0..1) of any preallocated cpool that triggers a
    /// warning.  Default 0.2 - warn when you're at 20% so you have
    /// time to grow `cap` before hitting the ceiling.  Set to 1.0
    /// to disable warnings entirely.
    warn_ratio: f32,

    /// Unique stamp acquired at `init`.  Used in debug builds to
    /// detect cross-world ref misuse - a ref allocated against world
    /// A but dereferenced against world B trips an assertion at the
    /// misuse site.  Zero-sized in release builds.
    debug_stamp: world_stamp.Stamp = world_stamp.nil_stamp,

    /// Per-world component-flag registry.  Owns the mapping
    /// `TypeId → CompFlag` for components seen by THIS world.  Two
    /// `Registry` instances in the same process register
    /// independently - flag-7 in world A might be a different
    /// component than flag-7 in world B.
    flag_table: std.AutoHashMapUnmanaged(TypeId, CompFlag) = .{},
    /// Reverse lookup `CompFlag → TypeId`.  Used by introspection
    /// / debug-print paths and by chunk-layout code that has a
    /// flag and needs to recover the type's size + alignment.
    /// Sized to `CompFlag.max + 1` so flag values
    /// `[0..reverse_len)` are valid indices.
    reverse_table: [@as(usize, CompFlag.max) + 1]TypeId = @splat(undefined),
    /// One past the highest CompFlag value handed out by
    /// `registerComponent`.  Slots `[0, reverse_len)` of
    /// `reverse_table` are the valid TypeIds.
    reverse_len: u8 = 0,

    /// Options for `init`.
    pub const InitOptions = struct {
        /// Used to allocate the entity storage.
        gpa: Allocator,
        /// The capacity of the entity storage.
        cap: Capacity = .{},
        /// When usage of preallocated buffers exceeds this ratio of full capacity, emit a warning.
        warn_ratio: f32 = 0.2,
    };

    /// The capacity of `Registry`.
    pub const Capacity = struct {
        /// The max number of entities.
        entities: u32 = 1000000,
        /// The max number of archetypes.
        arches: u32 = 64,
        /// The number of chunks to allocate.
        chunks: u16 = 4096,
        /// The size of a single chunk in bytes.
        chunk: u32 = 65536,
    };

    /// Allocate the preallocated pools and return a fresh world.
    /// All cap fields are committed upfront; the world will not
    /// ask the allocator for more memory after this call.
    pub fn init(options: InitOptions) Allocator.Error!@This() {
        var handle_tab: HandleTab = try .init(options.gpa, options.cap.entities);
        errdefer handle_tab.deinit(options.gpa);

        var chunk_pool: ChunkPool = try .init(options.gpa, .{
            .chunks = options.cap.chunks,
            .chunk = options.cap.chunk,
        });
        errdefer chunk_pool.deinit(options.gpa);

        var arches: Arches = try .init(options.gpa, options.cap.arches);
        errdefer arches.deinit(options.gpa);

        return .{
            .handle_tab = handle_tab,
            .arches = arches,
            .chunk_pool = chunk_pool,
            .warn_ratio = options.warn_ratio,
            .debug_stamp = world_stamp.next(),
        };
    }

    /// Free everything `init` allocated, leaving `self` in
    /// `undefined` state.  Caller must pass the same `gpa` they
    /// passed to `init`.
    pub fn deinit(self: *@This(), gpa: Allocator) void {
        self.flag_table.deinit(gpa);
        self.arches.deinit(gpa);
        self.chunk_pool.deinit(gpa);
        self.handle_tab.deinit(gpa);
        self.* = undefined;
    }

    /// Raise the entity ceiling to at least `new_capacity`. Only `handle_tab` is sized by entity
    /// count (arches/chunk_pool size archetype and component storage, which are independent), so this
    /// grows just that table. Entity keys/indices are stable across the grow; the pointer generation
    /// is bumped because `Entity.Location` pointers into the handle table move. The archetype/chunk
    /// side is untouched — primary-only pools never use it; component-bearing pools must size
    /// `cap.chunks` for their working set (chunk-arena growth is a separate concern).
    pub fn growEntities(
        self: *@This(),
        gpa: Allocator,
        new_capacity: u32,
    ) Allocator.Error!void {
        if (new_capacity <= self.handle_tab.capacity) {
            return;
        }
        self.pointer_generation.increment();
        try self.handle_tab.grow(gpa, new_capacity);
    }

    /// Look up the CompFlag for a component type ID in this world.
    /// `null` if the component hasn't been registered with this
    /// world yet - call `registerComponent` to register.
    pub fn getCompFlag(self: *const @This(), id: TypeId) ?CompFlag {
        return self.flag_table.get(id);
    }

    /// Register a component type with this world if it isn't
    /// already.  Idempotent - re-registering returns the existing
    /// flag.  Errors on flag exhaustion (more than `CompFlag.max`
    /// distinct components in this world) and on hashmap OOM.
    /// Reads/mutates `self.flag_table`, `self.reverse_table`,
    /// `self.reverse_len`.  Allocates from `gpa` for hashmap
    /// growth.
    pub fn registerComponent(
        self: *@This(),
        gpa: Allocator,
        id: TypeId,
    ) error{ OutOfMemory, EcsCompTypeOverflow }!CompFlag {
        if (self.flag_table.get(id)) |existing| {
            return existing;
        }

        std.log.scoped(.ecs).debug("register comp: {s}", .{id.name});

        // Single one-shot warning when we cross the halfway mark
        // gives the user time to either grow CompFlag.max (need
        // wider FlagInt) or audit which components they actually
        // need before hitting the hard ceiling.
        if (self.reverse_len == CompFlag.max / 2) {
            std.log.warn(
                "{} component types registered, you're at 50% the fatal capacity!",
                .{self.reverse_len},
            );
        }

        if (self.reverse_len >= CompFlag.max) {
            return error.EcsCompTypeOverflow;
        }

        const flag: CompFlag = @fromBackingInt(@intCast(self.reverse_len));
        try self.flag_table.put(gpa, id, flag);
        self.reverse_table[self.reverse_len] = id;
        self.reverse_len += 1;
        return flag;
    }

    /// Slice of every TypeId registered with this world, in
    /// registration order.  Suitable for introspection / dumps.
    pub fn getAllCompTypes(self: *const @This()) []const TypeId {
        return self.reverse_table[0..self.reverse_len];
    }

    /// Recover the TypeId that owns the given flag in this world.
    /// Asserts the flag is in-range - caller must have obtained it
    /// from this same world (flag layouts differ between worlds).
    pub fn getCompType(self: *const @This(), flag: CompFlag) TypeId {
        const idx: usize = @backingInt(flag);
        assert(idx < self.reverse_len, @src());
        return self.reverse_table[idx];
    }

    /// Destroys all entities matching the given arch immediately.
    /// Their handles become invalid (any later use is detected by
    /// generation mismatch).
    /// Invalidates pointers.
    pub fn destroyArchImmediate(self: *@This(), arch: CompFlag.Set) void {
        self.archWalkAndClear(arch, .destroy);
    }

    /// Like `destroyArchImmediate`, but the handles get returned to
    /// the slot map intact instead of being marked invalid - older
    /// references to the same Entity will silently rebind to
    /// whatever the slot is reused for.  Faster than destroy
    /// because it skips the generation-bump per entity, but only
    /// safe when you can prove no stale references remain (event
    /// pools, transient queues).
    /// Invalidates pointers.
    pub fn recycleArchImmediate(self: *@This(), arch: CompFlag.Set) void {
        self.archWalkAndClear(arch, .recycle);
    }

    /// What `archWalkAndClear` does to each entity it visits.
    const ArchClearAction = enum { destroy, recycle };

    /// Walk every chunk of every chunk-list whose archetype
    /// contains `arch`, drop each entity from the handle table
    /// (per `action`), and clear the chunk.  Shared between
    /// `destroyArchImmediate` and `recycleArchImmediate` - the
    /// only difference is which handle-table method runs per
    /// entity.
    fn archWalkAndClear(
        self: *@This(),
        arch: CompFlag.Set,
        action: ArchClearAction,
    ) void {
        self.pointer_generation.increment();
        var chunk_lists_iter: Arches.Iterator = self.arches.iterator(self, .{ .require = arch });
        while (chunk_lists_iter.next(self)) |chunk_list| {
            var chunk_list_iter: ChunkList.Iterator = chunk_list.iterator(self);
            while (chunk_list_iter.next(self)) |chunk| {
                var chunk_iter: Chunk.Iterator = chunk.iterator(self);
                while (chunk_iter.next(self)) |entity| {
                    switch (action) {
                        .destroy => self.handle_tab.remove(entity.key),
                        .recycle => self.handle_tab.recycle(entity.key),
                    }
                }
                chunk.clear(self);
            }
        }
    }

    /// Recycles all entities.
    /// Invalidates pointers.
    pub fn recycleImmediate(self: *@This()) void {
        self.pointer_generation.increment();
        self.handle_tab.recycleAll();
        self.reserved_entities = 0;
    }

    /// Number of committed entities (excludes reserved-but-uncommitted).
    pub fn count(self: *const @This()) usize {
        return self.handle_tab.count() - self.reserved_entities;
    }

    /// Number of entities reserved via `reserve` but not yet
    /// committed via `commit` / `add` etc.
    pub fn reserved(self: *const @This()) usize {
        return self.reserved_entities;
    }

    /// Reverse-lookup an Entity from a pointer to one of its
    /// non-zero-sized components.  Useful inside `forEachChunk`
    /// when you have `*Position` and want the entity it belongs
    /// to.
    /// Why non-zero-sized: zero-sized components have no per-
    /// instance storage so all "instances" share an address;
    /// reverse-lookup is ambiguous.  We could pack the entity
    /// handle into the pointer value (typical ptr is 64-bit,
    /// `Entity` fits) but that breaks `[]ZeroSized` slicing
    /// we chose to keep slicing.  This is a deliberate trade-off
    /// in the donor; if you later want zero-sized reverse lookup
    /// the path is "panic on zero-size, switch to packed
    /// representation, ensure live entities never serialize as
    /// fully-zero pointer bits".
    pub fn getEntity(es: *const Registry, from_comp: anytype) Entity {
        const T: type = @typeInfo(@TypeOf(from_comp)).pointer.child;
        comptime assert(@sizeOf(T) != 0, @src());
        return getEntityFromAny(es, .init(T, from_comp));
    }

    /// `getEntity` for runtime-typed component pointers.
    pub fn getEntityFromAny(es: *const Registry, from_comp: Any) Entity {
        const loc: Loc = getLoc(es, from_comp);
        const indices: []const Entity.Index = loc.chunk.view(es, struct { indices: []const Entity.Index }).?.indices;
        const entity_index: Entity.Index = indices[@backingInt(loc.index_in_chunk)];

        assert(@backingInt(entity_index) < es.handle_tab.next_index, @src());
        const entity: Entity = entity_index.toEntity(es);
        assert(entity.committed(es), @src());
        return entity;
    }

    /// Given a pointer to one component of an entity, fetch
    /// another component on the same entity.  Returns `null` if
    /// `Result` isn't attached.  Like `Entity.get` but skips the
    /// handle-table indirection (you already have a pointer into
    /// the entity's chunk).
    pub fn getComp(
        es: *const Registry,
        from: anytype,
        Result: type,
    ) ?*Result {
        const T: type = @typeInfo(@TypeOf(from)).pointer.child;
        comptime assert(@sizeOf(T) != 0, @src()); // see `getEntity`
        const slice: ?[]u8 = getCompFromAny(es, .init(T, from), typeId(Result));
        return @ptrCast(@alignCast(slice));
    }

    /// `getComp` for runtime-typed component pointers.  Returns
    /// the raw bytes (`[]u8` of `get_comp_id.size`) so the caller
    /// can `@ptrCast` to the right type - `getComp` does that
    /// cast automatically.
    pub fn getCompFromAny(
        self: *const Registry,
        from_comp: Any,
        get_comp_id: TypeId,
    ) ?[]u8 {
        if (std.debug.runtime_safety) {
            _ = self.getEntityFromAny(from_comp);
        }

        const flag: CompFlag = self.getCompFlag(get_comp_id) orelse return null;
        const loc: Loc = self.getLoc(from_comp);
        // https://codeberg.org/Games-by-Mason/mr_ecs/issues/24
        const comp_buf_offset: u32 = loc.chunk.header().comp_buf_offsets.values[@backingInt(flag)];
        if (comp_buf_offset == 0) {
            return null;
        }
        const unsized: [*]u8 = @ptrFromInt(@intFromPtr(loc.chunk) +
            comp_buf_offset +
            get_comp_id.size * @backingInt(loc.index_in_chunk));
        return unsized[0..get_comp_id.size];
    }

    /// Recover (chunk, index_in_chunk) from a pointer to one of
    /// the entity's non-zero-sized components.  Works because
    /// chunks are aligned to their size - round the pointer down
    /// to the chunk boundary, then back-compute the index from
    /// the offset within the component buffer.
    const Loc = struct {
        chunk: *Chunk,
        index_in_chunk: Entity.Location.IndexInChunk,
    };

    fn getLoc(self: *const Registry, from_comp: Any) Loc {
        assert(from_comp.id.size != 0, @src()); // see `getEntity`

        const cpool: *const ChunkPool = &self.chunk_pool;
        const flag: CompFlag = self.getCompFlag(from_comp.id).?;

        // The pointer must live inside the chunk cpool - out-of-
        // cpool pointers indicate the user passed something that
        // wasn't a component at all.
        assert(@intFromPtr(from_comp.ptr) >= @intFromPtr(cpool.buf.ptr), @src());
        assert(@intFromPtr(from_comp.ptr) <= @intFromPtr(&cpool.buf[cpool.buf.len - 1]), @src());

        // Round the pointer down to chunk alignment to find the
        // chunk header.  Chunks are aligned to chunk size for
        // exactly this reverse-lookup.
        const chunk: *Chunk = @ptrFromInt(cpool.size_align.backward(@intFromPtr(from_comp.ptr)));

        assert(chunk.header().arch(&self.arches).contains(flag), @src());
        const comp_offset: usize = @intFromPtr(from_comp.ptr) - @intFromPtr(chunk);
        assert(comp_offset != 0, @src()); // zero would mean "no such comp in this chunk"
        // https://codeberg.org/Games-by-Mason/mr_ecs/issues/24
        const comp_buf_offset: u32 = chunk.header().comp_buf_offsets.values[@backingInt(flag)];
        const index_in_chunk: usize = @divExact(comp_offset - comp_buf_offset, from_comp.id.size);

        return .{
            .chunk = chunk,
            .index_in_chunk = @fromBackingInt(@intCast(index_in_chunk)),
        };
    }

    /// Run `updateView` once per entity matching `View`.  `View` is
    /// derived from the first param of `updateView`; remaining
    /// params come from `ctx` (an anonymous tuple).
    /// Prefer this over `forEach` when your update logic wants
    /// helper methods on a struct (View can be any struct shape);
    /// downside is you don't get unused-param errors for fields you
    /// forgot to read.
    /// Invalidating pointers inside `updateView` triggers
    /// safety-checked illegal behavior.  The implementation only
    /// uses public ecs methods - fork into user code if your use
    /// case wants different iteration shape.
    pub fn forEachView(
        self: *@This(),
        comptime updateView: anytype,
        ctx: viewLib.Tuple(viewLib.params(@TypeOf(updateView))[1..]),
    ) void {
        self.forEachViewWithOptions(updateView, ctx, .{});
    }

    /// Like `forEachView` plus an `IteratorOptions` arg (currently
    /// just `skip` - the comp set to filter out).
    pub fn forEachViewWithOptions(
        self: *@This(),
        comptime updateView: anytype,
        ctx: viewLib.Tuple(viewLib.params(@TypeOf(updateView))[1..]),
        options: IteratorOptions,
    ) void {
        const params: []const type = &viewLib.params(@TypeOf(updateView));
        const View: type = params[0];
        var iter: Iterator(View) = self.iteratorWithOptions(View, options);
        while (iter.next(self)) |vw| {
            @call(.auto, updateView, .{vw} ++ ctx);
        }
    }

    /// Run `updateEntity` once per entity matching the unpacked-tuple
    /// view.  `updateEntity` takes `ctx` first, then a flat list of
    /// component pointers / optional component pointers / `Entity`
    /// args; the View shape is derived from those param types.
    /// Compared to `forEachView`: catches unused components at
    /// compile time (Zig's unused-param error) but the update fn
    /// can't be a method on a struct.
    /// Invalidating pointers inside `updateEntity` triggers
    /// safety-checked illegal behavior.
    pub fn forEach(
        self: *@This(),
        comptime updateEntity: anytype,
        ctx: viewLib.params(@TypeOf(updateEntity))[0],
    ) void {
        self.forEachWithOptions(updateEntity, ctx, .{});
    }

    /// Like `forEach` plus an `IteratorOptions` arg.
    pub fn forEachWithOptions(
        self: *@This(),
        comptime updateEntity: anytype,
        ctx: viewLib.params(@TypeOf(updateEntity))[0],
        options: IteratorOptions,
    ) void {
        const params: []const type = &viewLib.params(@TypeOf(updateEntity));
        const View: type = viewLib.Tuple(params[1..]);
        var iter: Iterator(View) = self.iteratorWithOptions(View, options);
        while (iter.next(self)) |vw| {
            @call(.auto, updateEntity, .{ctx} ++ vw);
        }
    }

    /// Options for `forEachChunk`.
    pub fn ForEachChunkOptions(f: type) type {
        return struct {
            const Ctx: type = viewLib.params(f)[0];
            ctx: Ctx,
            /// Skip entities containing any of these components.
            skip: CompFlag.Set = .{},
        };
    }

    /// Run `updateChunk` once per chunk matching the requested
    /// view.  `updateChunk` takes `ctx` first, then a flat list of
    /// component **slices** (one per chunk), optional component
    /// slices, or `[]const Entity.Index`.
    /// Use this when batch-processing a whole chunk at once buys
    /// you something - vectorisable inner loops, single-shot
    /// memcpy, etc.  Otherwise prefer `forEach`.
    pub fn forEachChunk(
        self: *@This(),
        comptime updateChunk: anytype,
        options: ForEachChunkOptions(@TypeOf(updateChunk)),
    ) void {
        const params: []const type = &viewLib.params(@TypeOf(updateChunk));
        const ChunkView: type = viewLib.Tuple(params[1..]);
        const require_comps: CompFlag.Set = viewLib.comps(self, ChunkView, .{ .size = .slice }) orelse return;
        var chunks: ChunkIterator = self.chunkIterator(.{
            .require = require_comps,
            .skip = options.skip,
        });
        while (chunks.next(self)) |chunk| {
            const chunk_view: ChunkView = chunk.view(self, ChunkView).?;
            @call(.auto, updateChunk, .{options.ctx} ++ chunk_view);
        }
    }

    /// Emit a warning if any preallocated cpool has crossed the
    /// `warn_ratio` threshold, or if entity slots have been
    /// saturated since the last call.  Each cpool warns at most
    /// once per world (`warned_*` flags); the saturation warning
    /// is rate-limited to one log per increment.
    /// Recommended call site: once per frame.
    pub fn updateStats(self: *@This()) void {
        // warn_ratio == 1.0 disables warnings entirely.
        if (self.warn_ratio >= 1.0) {
            return;
        }

        // Saturation is logged on edge: the count keeps growing,
        // we only want a fresh log when it grows past what we've
        // already reported.
        if (self.handle_tab.saturated > self.warned_saturated) {
            self.warned_saturated = self.handle_tab.saturated;
            log.warn("{} entity slots have been saturated", .{self.warned_saturated});
        }

        const pct: f32 = self.warn_ratio * 100.0;

        const handles: f32 = float(self.handle_tab.count());
        const handles_cap: f32 = float(self.handle_tab.capacity);
        if (!self.warned_capacity and handles > handles_cap * self.warn_ratio) {
            self.warned_capacity = true;
            log.warn("entities past {d}% capacity", .{pct});
        }

        const chunks: f32 = float(self.chunk_pool.reserved);
        const chunks_cap_int: usize = self.chunk_pool.buf.len / self.chunk_pool.size_align.toByteUnits();
        const chunks_cap: f32 = float(chunks_cap_int);
        if (!self.warned_chunk_pool and chunks > chunks_cap * self.warn_ratio) {
            self.warned_chunk_pool = true;
            log.warn("chunk cpool past {d}% capacity", .{pct});
        }

        const arches: f32 = float(self.arches.map.count());
        const arches_cap: f32 = float(self.arches.map.capacity());
        if (!self.warned_arches and arches > arches_cap * self.warn_ratio) {
            self.warned_arches = true;
            log.warn("archetypes past {d}% capacity", .{pct});
        }
    }

    pub const ChunkIteratorOptions = Arches.IteratorOptions;

    /// Returns an iterator over all the chunks with at least the components in `require_comps` in
    /// an implementation defined order.
    /// Invalidating pointers while iterating results in safety checked illegal behavior.
    pub fn chunkIterator(
        self: *const @This(),
        options: ChunkIteratorOptions,
    ) ChunkIterator {
        var lists: Arches.Iterator = self.arches.iterator(self, options);
        const chunks: ChunkList.Iterator = if (lists.next(self)) |l|
            l.iterator(self)
        else
            .empty(self);
        var result: ChunkIterator = .{
            .lists = lists,
            .chunks = chunks,
        };
        result.catchUp(self);
        return result;
    }

    /// See `chunkIterator`.
    pub const ChunkIterator = struct {
        lists: Arches.Iterator,
        chunks: ChunkList.Iterator,

        /// The shared pointer-lock guarding all iteration over
        /// this world.  `next` checks it against the world's
        /// generation; mutating ops (add/remove/destroy) increment
        /// the world generation so any iterator predating the
        /// mutation will trip the assert.
        pub fn pointerLock(self: *const ChunkIterator) PointerLock {
            return self.lists.pointer_lock;
        }

        /// An iterator that yields nothing.  Used as the
        /// `peek == null` initial state when `chunkIterator` finds
        /// no matching arches.
        pub fn empty(es: *const Registry) @This() {
            return .{
                .lists = .empty(es),
                .chunks = .empty(es),
            };
        }

        /// Step `chunks` forward until it points at a non-empty
        /// chunk, or both iterators are exhausted.  Chunks can't
        /// themselves be empty (free chunks return to the cpool),
        /// but chunk LISTS can be - `peek` would then see null and
        /// callers wouldn't know whether to advance further.
        fn catchUp(self: *@This(), es: *const Registry) void {
            while (self.chunks.chunk == null) {
                const chunk_list: *const ChunkList = self.lists.next(es) orelse {
                    return;
                };
                self.chunks = chunk_list.iterator(es);
            }
        }

        /// Current chunk without advancing.
        pub fn peek(self: *const @This(), es: *const Registry) ?*Chunk {
            return self.chunks.peek(es);
        }

        /// Advance the iterator and return the next chunk, or
        /// null if exhausted.  Chunk lists can be empty (no
        /// chunks yet committed), so we loop until we either
        /// find a populated chunk or run out of lists entirely.
        pub fn next(self: *@This(), es: *const Registry) ?*Chunk {
            self.pointerLock().check(es.pointer_generation);

            const chunk: *Chunk = while (true) {
                if (self.chunks.next(es)) |c| {
                    break c;
                }
                // Current list ran out - try the next list.
                if (self.lists.next(es)) |next_list| {
                    @branchHint(.likely);
                    self.chunks = next_list.iterator(es);
                } else {
                    return null;
                }
            };

            // Move the peek cursor onto whatever follows `chunk`
            // so the next `peek` sees the right thing.
            self.catchUp(es);

            return chunk;
        }
    };

    /// Iterate every entity carrying at least the components in
    /// `View`.  `View` is a struct whose fields are component
    /// pointers (`*Position`, `*const Velocity`), optional
    /// component pointers (`?*Color`), or `Entity`.  Each
    /// `next()` returns one filled-in `View`.
    /// Iteration order is "chunk order" - implementation defined
    /// in general, but with one useful guarantee: entities added
    /// to a fresh archetype with no intervening deletions iterate
    /// in insertion order.  Useful for transient event queues
    /// that are spawned + drained in one go.
    /// Mutating `Registry` from inside an iterator (add / remove /
    /// destroy) triggers safety-checked illegal behavior - the
    /// pointer-lock generation check catches it.
    pub fn iterator(self: *const @This(), View: type) Iterator(View) {
        return self.iteratorWithOptions(View, .{});
    }

    /// Options accepted by `iteratorWithOptions`,
    /// `forEachWithOptions`, and friends.
    pub const IteratorOptions = struct {
        /// Skip entities containing any of these components.
        /// Empty set (default) = no filter.
        skip: CompFlag.Set = .{},
    };

    /// `iterator` plus a `skip` filter.  Registry carrying any
    /// component in `options.skip` are excluded.
    pub fn iteratorWithOptions(
        self: *const @This(),
        View: type,
        options: IteratorOptions,
    ) Iterator(View) {
        // If any component in View isn't registered yet, no
        // entity can possibly carry it - return an empty iterator
        // rather than crash on lookup.
        const require_comps: CompFlag.Set = viewLib.comps(self, View, .{ .size = .one }) orelse
            return .empty(self);

        const chunks: ChunkIterator = self.chunkIterator(.{
            .require = require_comps,
            .skip = options.skip,
        });

        // Pre-prime the slice cache for the first chunk so
        // `Iterator.next` can index without re-fetching on the
        // common case.  `undefined` is fine here: empty iterators
        // hit the `peek == null` early return before ever reading
        // `slices`.
        const Slices = viewLib.Slice(View);
        const slices: Slices = if (chunks.peek(self)) |c|
            c.view(self, Slices).?
        else
            undefined;

        return .{
            .chunks = chunks,
            .slices = slices,
            .index_in_chunk = 0,
        };
    }

    /// See `Registry.iterator`.
    pub fn Iterator(View: type) type {
        return struct {
            const Slices = viewLib.Slice(View);

            chunks: ChunkIterator,
            slices: Slices,
            index_in_chunk: u32,

            /// An iterator that yields nothing.  `iteratorWithOptions`
            /// returns this when no archetype matches the View.
            pub fn empty(es: *const Registry) @This() {
                return .{
                    .chunks = .empty(es),
                    .slices = undefined,
                    .index_in_chunk = 0,
                };
            }

            /// Advance the iterator and return the next View, or
            /// null when exhausted.
            pub fn next(self: *@This(), es: *const Registry) ?View {
                // Trip if the world was mutated mid-iteration.
                self.chunks.pointerLock().check(es.pointer_generation);

                var chunk: *Chunk = self.chunks.peek(es) orelse {
                    @branchHint(.unlikely);
                    return null;
                };
                assert(chunk.header().len > 0, @src()); // free chunks return to the cpool

                // Walked off the end of the current chunk?  Step
                // to the next one and re-read its component slices.
                if (self.index_in_chunk >= chunk.header().len) {
                    _ = self.chunks.next(es).?;
                    chunk = self.chunks.peek(es) orelse {
                        @branchHint(.unlikely);
                        return null;
                    };
                    self.index_in_chunk = 0;
                    assert(chunk.header().len > 0, @src());
                    self.slices = chunk.view(es, Slices).?;
                }

                // index_in_chunk can't overflow u32: a chunk holds
                // fewer entities than it has bytes, and chunks are
                // sized in u32 bytes.
                const result: View = viewLib.index(View, es, self.slices, self.index_in_chunk);
                self.index_in_chunk += 1;
                return result;
            }
        };
    }
};

/// Phantom-typed reference to one entity slot in `Entities(T)`.
/// 8 bytes (4 of payload + zero-sized stamp in release builds;
/// 8 bytes in debug for the stamp).  Methods that operate on the
/// slot (`deref`, `destroy`, `isValid`, `get`, `attach`,
/// `attachAll`, `detach`) take a `*Entities(T)` and access the
/// storage directly.
pub fn Handle(comptime T_primary: type) type {
    return struct {
        bits: u32,
        debug_stamp: world_stamp.Stamp,

        /// The phantom primary type.  Reading this decl makes
        /// `Handle(A)` and `Handle(B)` distinct
        /// types at compile time even though both wrap a u32.
        pub const Primary = T_primary;

        pub const cycle_bits: u5 = 8;
        pub const index_bits: u5 = 24;
        const cycle_mask: u32 = (1 << cycle_bits) - 1;

        /// The reserved zero handle.  Carries `nil_stamp` so any
        /// dereference against any world short-circuits the stamp
        /// check (deref returns null on nil; no panic).
        pub const nil: @This() = .{
            .bits = 0,
            .debug_stamp = world_stamp.nil_stamp,
        };

        /// Build a synthetic handle from a (slot index, cycle byte)
        /// pair.  Carries `nil_stamp` so it skips the cross-world
        /// stamp check -- intended for tests that exercise OOB or
        /// stale code paths.  Real alloc'd handles are constructed
        /// inside `Entities.alloc` / `Entities.spawn` with the
        /// world's stamp.
        pub fn pack(idx: u24, cyc: u8) @This() {
            const bits: u32 = (@as(u32, idx) << cycle_bits) | cyc;
            return .{
                .bits = bits,
                .debug_stamp = world_stamp.nil_stamp,
            };
        }

        /// The slot index this handle refers to.
        pub fn index(self: @This()) u24 {
            return @truncate(self.bits >> cycle_bits);
        }

        /// The cycle byte recorded at the time of allocation.
        pub fn cycle(self: @This()) u8 {
            return @truncate(self.bits & cycle_mask);
        }

        /// True iff this is the reserved zero handle.  Doesn't
        /// require a world -- `@This().nil.isNil()` is true.
        pub fn isNil(self: @This()) bool {
            return self.bits == 0;
        }

        /// Structural equality.  Compares the packed bits only;
        /// the debug_stamp is ignored (two handles with the same
        /// bits from different worlds compare equal at this layer,
        /// but dereferencing one against the wrong world trips
        /// the stamp check at the misuse site).
        pub fn eql(self: @This(), other: @This()) bool {
            return self.bits == other.bits;
        }

        /// Lookup the primary component.  Two dependent loads.
        /// Returns null for nil or stale handles.
        // Handle and Entities are mutually recursive generic constructors: Handle's
        // deref/get/destroy take *Entities(T), and Entities returns/uses Handle(T)
        // (alloc, spawn). Neither generic can be declared before the other.
        // lint:off decl-order: Handle<->Entities mutual recursion
        pub fn deref(self: @This(), world: *const Entities(T_primary)) ?*T_primary {
            world_stamp.assertMatch(
                "Handle(" ++ @typeName(T_primary) ++ ")",
                self.debug_stamp,
                world.debug_stamp,
            );
            if (self.isNil()) {
                return null;
            }
            const idx: u32 = self.index();
            if (idx >= world.data.len) {
                return null;
            }
            // Liveness + freshness in one check: cycle 0 is the
            // nil-marker (never matches a real handle, since
            // `pack` requires cyc >= 1 to be meaningful and
            // `alloc` always returns cyc >= 1).  Otherwise the
            // recorded cycle must match the slot's current cycle.
            if (world.cycle[idx] != self.cycle()) {
                return null;
            }
            return &world.data[idx];
        }

        /// Release this handle's slot.  Returns true if the entity
        /// was live before this call; false for nil / stale / out-
        /// of-range.  Drops every attached secondary along with
        /// the primary slot.
        /// Does NOT release resources owned by secondaries (GL ids
        /// etc.) -- callers that own such state release it before
        /// calling `destroy`.
        pub fn destroy(self: @This(), world: *Entities(T_primary)) bool {
            world_stamp.assertMatch(
                "Handle(" ++ @typeName(T_primary) ++ ")",
                self.debug_stamp,
                world.debug_stamp,
            );
            if (self.deref(world) == null) {
                return false;
            }
            // ECS side: drop the entity (releases secondaries via
            // archetype cleanup).  Generations match the cycle so
            // we can synthesize the ECS handle without a lookup.
            const ecs_e: Entity = .{ .key = .{
                .index = self.index(),
                .generation = @fromBackingInt(@intCast(self.cycle())),
            } };
            _ = ecs_e.destroyImmediate(&world.ecs);

            // Pool side: bump the cycle byte (live -> free, by
            // making old handles fail the equality check) and
            // push the slot onto the LIFO free list.
            const idx: u32 = self.index();
            world.cycle[idx] +%= 1;
            world.free_list[world.free_count] = idx;
            world.free_count += 1;
            return true;
        }

        /// True iff `deref(world)` would return non-null.
        pub fn isValid(self: @This(), world: *const Entities(T_primary)) bool {
            return self.deref(world) != null;
        }

        /// Lookup any component on this entity.  Comptime-
        /// dispatched: if `T` is the primary type, takes the pool
        /// fast path; otherwise goes through the archetype lookup.
        /// Stale handles return null on either path.
        pub fn get(self: @This(), world: *const Entities(T_primary), comptime T: type) ?*T {
            if (T == T_primary) {
                return self.deref(world);
            }
            if (self.deref(world) == null) {
                return null;
            }
            const ecs_e: Entity = .{ .key = .{
                .index = self.index(),
                .generation = @fromBackingInt(@intCast(self.cycle())),
            } };
            return ecs_e.get(&world.ecs, T);
        }

        /// Attach a single secondary component to this entity.
        /// One archetype transition.  Returns false (no-op) for
        /// nil or stale handles.
        pub fn attach(
            self: @This(),
            gpa: Allocator,
            world: *Entities(T_primary),
            secondary: anytype,
        ) !bool {
            if (self.deref(world) == null) {
                return false;
            }
            const ecs_e: Entity = .{ .key = .{
                .index = self.index(),
                .generation = @fromBackingInt(@intCast(self.cycle())),
            } };
            const T: type = @TypeOf(secondary);
            return ecs_e.changeArchImmediateOrErr(&world.ecs, gpa, struct {
                c: T,
            }, .{ .add = .{ .c = secondary } });
        }

        /// Attach multiple secondary components atomically.
        /// `bundle` is an anonymous struct; the FIELD TYPES
        /// determine the components (field names are decorative).
        /// One archetype transition regardless of arity.
        /// Returns false (no-op) for nil or stale handles.
        pub fn attachAll(
            self: @This(),
            gpa: Allocator,
            world: *Entities(T_primary),
            bundle: anytype,
        ) !bool {
            if (self.deref(world) == null) {
                return false;
            }
            const ecs_e: Entity = .{ .key = .{
                .index = self.index(),
                .generation = @fromBackingInt(@intCast(self.cycle())),
            } };
            return ecs_e.changeArchImmediateOrErr(
                &world.ecs,
                gpa,
                @TypeOf(bundle),
                .{ .add = bundle },
            );
        }

        /// Detach a secondary component.  Returns true if the
        /// component was present (and the entity was live);
        /// false for nil / stale / component-not-present.
        pub fn detach(
            self: @This(),
            gpa: Allocator,
            world: *Entities(T_primary),
            comptime T: type,
        ) !bool {
            if (self.deref(world) == null) {
                return false;
            }
            const ecs_e: Entity = .{ .key = .{
                .index = self.index(),
                .generation = @fromBackingInt(@intCast(self.cycle())),
            } };
            return ecs_e.changeArchImmediateOrErr(&world.ecs, gpa, struct {
                c: T,
            }, .{ .remove = .initOne(T) });
        }
    };
}

/// A pool-anchored ECS world parameterized on a primary component
/// type.  Every entity carries the primary through the fast pool
/// deref path (2 dependent loads); optional secondaries attach via
/// the inlined archetype ECS.
/// `T_primary = struct {}` (empty struct) is fine -- gives an
/// ECS-only world where the primary is zero-sized and `spawn(.{})`
/// is the spawn verb.  See `gpu.Resources` for a typical use with
/// non-trivial primary types.
pub fn Entities(comptime T_primary: type) type {
    return struct {
        const Self = @This();

        /// The primary component type.  Distinct primaries give
        /// distinct world types (phantom-typed by `T_primary`).
        pub const Primary = T_primary;

        pub const SpawnError = error{ PoolExhausted, EcsEntityOverflow };

        // ---- Pool-side storage
        // Pool (formerly `pool.Pool(T_primary)`) inlined directly
        // the fields below are the entire pool.  Methods that act on
        // them (alloc, deref via Handle(T_primary), etc.) operate on `self.data`,
        // `self.cycle`, etc. directly with no indirection.
        // Hot path: `handle.deref(&world)` reads `world.cycle[idx]`
        // (one load), compares against `handle.cycle()` (no load,
        // packed in the handle bits), then if matching reads
        // `&world.data[idx]` (one load).  Two dependent loads total.

        /// Per-slot primary value storage.  `data[0]` is the reserved
        /// nil slot, never live.  Maximum live entities is
        /// `data.len - 1`.
        data: []T_primary = &.{},

        /// Per-slot generation counter (a.k.a. cycle byte).  Bumped
        /// on every destroy; reused on alloc.  The same byte serves
        /// as the ECS slot's generation -- after the merge they are
        /// one value.  Cycle 0 = the reserved nil-marker (slot 0 is
        /// always 0; `Handle(T_primary).nil` carries cycle 0 in its bits).
        cycle: []u8 = &.{},

        /// LIFO free list of slot indices released by `destroy`.
        /// `alloc` pops from here first; otherwise bumps `watermark`.
        free_list: []u32 = &.{},
        free_count: u32 = 0,

        /// Next never-allocated slot.  Starts at 1 (slot 0 is the
        /// reserved nil); walked monotonically until reaching
        /// `data.len`, after which freed slots come from `free_list`.
        watermark: u32 = 1,

        /// Unique stamp acquired at `init`.  In debug builds, every
        /// handle deref / destroy / isValid checks that the world's
        /// stamp matches the one captured when the handle was
        /// issued -- catches cross-world misuse.  Zero-sized in
        /// release builds.
        debug_stamp: world_stamp.Stamp = world_stamp.nil_stamp,

        // ---- ECS-side storage
        // Archetype container for secondary components.  Allocations
        // on this side are kept in lockstep with the pool side: the
        // same index identifies both, and the 8-bit ECS generation
        // matches the cycle byte exactly.

        ecs: Registry,

        // ---- Handle(T_primary)
        /// Phantom-typed reference to one entity slot.
        /// 8 bytes (4 of payload + zero-sized stamp in release builds;
        /// 8 bytes in debug for the stamp).  Methods that operate on
        /// the slot (`deref`, `destroy`, `isValid`, `get`, `attach`,
        /// `attachAll`, `detach`) take a `*Entities(T)` and access
        /// the storage directly -- no separate Pool indirection.

        // ---- Lifecycle on the world
        pub const Options = struct {
            /// Max number of live entities (includes the reserved
            /// slot 0).  The one knob most callers ever set.
            capacity: u32,

            /// Per-archetype storage tuning.  Leave `null` (the
            /// default) for sensible numbers suited to the pool-
            /// dominant case where most entities carry only the
            /// primary and few archetypes exist.  Override when you
            /// have many archetypes (scene-style game worlds with
            /// many distinct component combinations) or non-default
            /// chunk sizes are warranted.
            advanced: ?Advanced = null,

            pub const Advanced = struct {
                /// Max distinct archetypes -- roughly the number of
                /// distinct secondary-component combinations the
                /// world will ever see.
                arches: u32 = 4,
                /// Preallocated chunk count for archetype storage.
                chunks: u16 = 4,
                /// Bytes per chunk.
                chunk: u32 = 4096,
            };
        };

        pub fn init(gpa: Allocator, options: Options) !Self {
            assert(options.capacity > 0, @src());

            // Allocate the pool-side slices.
            const data = try gpa.alloc(T_primary, options.capacity);
            errdefer gpa.free(data);
            @memset(std.mem.sliceAsBytes(data), 0);

            const cycle = try gpa.alloc(u8, options.capacity);
            errdefer gpa.free(cycle);
            @memset(cycle, 0);

            const free_list = try gpa.alloc(u32, options.capacity);
            errdefer gpa.free(free_list);

            // Allocate the ECS-side container.  `entities` mirrors
            // `capacity`; the other fields come from `advanced` (or
            // its defaults if the caller didn't override).
            const adv: Options.Advanced = options.advanced orelse .{};
            const cap: Registry.Capacity = .{
                .entities = options.capacity,
                .arches = adv.arches,
                .chunks = adv.chunks,
                .chunk = adv.chunk,
            };
            var ecs_world: Registry = try .init(.{ .gpa = gpa, .cap = cap });
            errdefer ecs_world.deinit(gpa);

            // Burn ECS slot 0 to align with the pool's `Handle(T_primary).nil`
            // convention (slot 0 is the reserved nil-sentinel,
            // never live).  After this both sides start their first
            // real allocation at index 1, and LIFO free-list policies
            // on both sides keep them in lockstep.
            // The 8-bit ECS generation matches the cycle byte
            // exactly: both bump by 1 on every alloc/destroy.  Pool
            // starts cycle[0] = 0; ECS bumps to 1 on the anchor
            // reserve.  We copy that 1 into cycle[0] so the two
            // remain identical.  `Handle(T_primary).nil` still carries cycle 0
            // so deref of nil correctly fails against the bumped
            // slot.
            const anchor: Entity = try Entity.reserveImmediateOrErr(&ecs_world);
            assert(anchor.key.index == 0, @src());
            cycle[0] = @backingInt(anchor.key.generation);
            assert(cycle[0] == 1, @src());

            return .{
                .data = data,
                .cycle = cycle,
                .free_list = free_list,
                .free_count = 0,
                .watermark = 1,
                .debug_stamp = world_stamp.next(),
                .ecs = ecs_world,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.data);
            gpa.free(self.cycle);
            gpa.free(self.free_list);
            self.ecs.deinit(gpa);
            self.* = undefined;
        }

        /// Grow the entity capacity to at least `new_capacity`, preserving every live entity and its
        /// index. Grows the pool triple (data/cycle/free_list) and the ECS `handle_tab` to the SAME
        /// new capacity, which is what keeps the two sides in lockstep: `watermark`/`next_index` are
        /// untouched and both free lists are index-based, so the next `alloc()` issues an identical
        /// index on both sides exactly as before. Indices/handles stay valid; only raw `*T` pointers
        /// into `data` (or `*Entity.Location` into the handle table) are invalidated, so the caller
        /// must hold none across this call. No-op if already large enough. For primary-only pools
        /// this fully lifts the cap; pools that attach secondary components must additionally have
        /// enough chunk capacity for their working set.
        pub fn grow(self: *Self, gpa: Allocator, new_capacity: u32) Allocator.Error!void {
            const old_cap: usize = self.data.len;
            if (new_capacity <= old_cap) {
                return;
            }
            const new_data: []T_primary = try gpa.alloc(T_primary, new_capacity);
            @memcpy(new_data[0..old_cap], self.data);
            @memset(std.mem.sliceAsBytes(new_data[old_cap..]), 0);
            gpa.free(self.data);
            self.data = new_data;

            const new_cycle: []u8 = try gpa.alloc(u8, new_capacity);
            @memcpy(new_cycle[0..old_cap], self.cycle);
            @memset(new_cycle[old_cap..], 0); // fresh slots carry cycle 0 (the nil marker)
            gpa.free(self.cycle);
            self.cycle = new_cycle;

            const new_free_list: []u32 = try gpa.alloc(u32, new_capacity);
            @memcpy(new_free_list[0..old_cap], self.free_list);
            gpa.free(self.free_list);
            self.free_list = new_free_list;

            try self.ecs.growEntities(gpa, new_capacity);
        }

        /// Number of live entities. Slots `[1, watermark)` have been allocated
        /// fresh (slot 0 is the reserved nil); `free_count` of those are currently
        /// freed, so the rest are live.
        pub fn count(self: Self) u32 {
            return self.watermark - 1 - self.free_count;
        }

        /// Allocate a new entity slot without writing a primary
        /// value.  The primary's bytes are zeroed -- the caller
        /// populates them via `handle.deref(world)` before reading.
        /// For the GL-style two-phase pattern (`glGenTextures` then
        /// `glTexImage2D`).  Returns `Handle(T_primary).nil` on capacity
        /// exhaustion rather than an error.
        pub fn alloc(self: *Self) Handle(T_primary) {
            // Pool-side: pick a slot, bump or reuse its cycle byte.
            const fresh: bool = self.free_count == 0;
            const idx: u32 = blk: {
                if (self.free_count > 0) {
                    self.free_count -= 1;
                    break :blk self.free_list[self.free_count];
                }
                if (self.watermark >= self.data.len) {
                    return .nil;
                }
                const i = self.watermark;
                self.watermark += 1;
                break :blk i;
            };

            // Fresh slot -> cycle is still 0 (the nil-marker); bump
            // to 1 to make it a real handle.  Recycled slots reuse
            // the cycle the previous destroy already advanced.
            if (fresh) {
                self.cycle[idx] = 1;
            }
            const cyc: u8 = self.cycle[idx];

            // Zero the slot bytes (donor-pool convention).
            @memset(std.mem.asBytes(&self.data[idx]), 0);

            // ECS-side: reserve the matching slot.  On failure
            // release the pool slot to keep the two sides symmetric.
            const ecs_e: Entity = Entity.reserveImmediateOrErr(&self.ecs) catch {
                // Roll back: bump cycle past the value we issued so
                // any handle holding it fails, then push to free
                // list.
                self.cycle[idx] +%= 1;
                self.free_list[self.free_count] = idx;
                self.free_count += 1;
                return .nil;
            };
            assert(@as(u32, @intCast(ecs_e.key.index)) == idx, @src());
            assert(@backingInt(ecs_e.key.generation) == cyc, @src());

            const idx_u24: u24 = @intCast(idx);
            return .{
                .bits = (@as(u32, idx_u24) << Handle(T_primary).cycle_bits) | cyc,
                .debug_stamp = self.debug_stamp,
            };
        }

        /// Spawn a new entity.  The shape of `arg` decides the path:
        ///   - `arg: T_primary` (typed value)  -> fast pool-only path.
        ///     No archetype transition; `gpa` is unused.
        ///   - `arg: .{ ..., ... }` (anon struct, no
        ///     `.primary` field)  -> coerce to `T_primary` and take
        ///     the fast path.  This is the "looks like a struct
        ///     literal" form that beginners reach for.
        ///   - `arg: .{ .primary = ..., .tag = ..., ... }` (anon
        ///     struct WITH `.primary` field)  -> composite path:
        ///     spawn primary, then archetype-transition to attach
        ///     the other fields as secondary components in a single
        ///     transition.
        ///   - `arg: .{}` for `Entities(struct {})` (empty primary)
        ///     -> sugar for the composite path with no secondaries.
        /// Returns `error.PoolExhausted` or `error.EcsEntityOverflow`
        /// when the underlying storage hits a capacity ceiling.  The
        /// composite path may additionally return allocator errors
        /// from the archetype transition.
        pub fn spawn(
            self: *Self,
            gpa: Allocator,
            arg: anytype,
        ) !Handle(T_primary) {
            const T_arg = @TypeOf(arg);

            // Dispatch: does `arg` carry a `.primary` field, or is
            // this the empty-primary sugar?  Both go to the composite
            // path.  Everything else coerces to `T_primary` and takes
            // the fast path.
            const wants_composite: bool = comptime b: {
                if (T_arg == T_primary) break :b false;
                const ti = @typeInfo(T_arg);
                if (ti != .@"struct") break :b false;
                if (@hasField(T_arg, "primary")) break :b true;
                // Anon struct without `.primary`.  Empty-primary
                // worlds use this shape to attach secondaries without
                // a primary value (the primary is zero-sized; we
                // synthesize the default).  Non-empty-primary worlds
                // coerce the anon struct to `T_primary` on the fast
                // path instead.
                if (@sizeOf(T_primary) == 0) break :b true;
                break :b false;
            };

            if (comptime wants_composite) {
                return spawnComposite(self, gpa, arg);
            }

            // Fast path: arg is `T_primary` or coerces to it.  Caller
            // wrote `world.spawn(gpa, Primary{ .x = 1 })` (typed) or
            // `world.spawn(gpa, .{ .x = 1 })` (anon struct with the
            // same fields as `T_primary`).
            // Zig won't re-coerce an anon struct to a named struct
            // after capturing it through `anytype`, so do the field
            // copy ourselves when the types differ.  Mismatched fields
            // surface as compile errors from `@field`.
            // `gpa` is unused on this path -- no archetype transition.
            const primary_val: T_primary = if (T_arg == T_primary)
                arg
            else if (comptime @typeInfo(T_arg) == .@"struct") b: {
                // Anon struct shorthand.  Two valid shapes:
                //   1. `T_arg` lists every field of `T_primary` --
                //      start with `undefined`, copy each over.
                //   2. `T_arg` lists a subset of `T_primary`'s fields
                //      and the missing fields all have defaults --
                //      start with `.{}`, overwrite the supplied ones.
                // Anything else is a partial init with un-defaulted
                // fields = silent garbage hazard, so we reject it at
                // compile time.
                const arg_covers_all: bool = comptime cov: {
                    for (@typeInfo(T_primary).@"struct".field_names) |pf_name| {
                        if (!@hasField(T_arg, pf_name)) break :cov false;
                    }
                    break :cov true;
                };
                const all_have_defaults: bool = comptime ad: {
                    for (@typeInfo(T_primary).@"struct".field_attrs) |pf_attr| {
                        if (pf_attr.default_value_ptr == null) break :ad false;
                    }
                    break :ad true;
                };
                comptime {
                    if (!arg_covers_all and !all_have_defaults) {
                        @compileError("spawn anon-struct shorthand: arg is missing fields of " ++
                            @typeName(T_primary) ++ " AND those fields lack defaults. " ++
                            "Either name every field in the anon struct, give the missing fields " ++
                            "defaults, or pass a typed `" ++ @typeName(T_primary) ++ "{...}` value.");
                    }
                }
                var p: T_primary = if (comptime arg_covers_all) undefined else .{};
                inline for (@typeInfo(T_arg).@"struct".field_names) |f_name| {
                    @field(p, f_name) = @field(arg, f_name);
                }
                break :b p;
            } else
                // Scalar / comptime literal -- let Zig do its normal
                // coercion (e.g. `comptime_int` -> `u32`).
                arg;
            return spawnPrimary(self, primary_val);
        }

        /// Internal: fast-path spawn.  No archetype transition.  Used
        /// when `arg` is a `T_primary` value (typed or coercible from
        /// an anon struct literal).
        fn spawnPrimary(self: *Self, primary: T_primary) SpawnError!Handle(T_primary) {
            const h = self.alloc();
            if (h.isNil()) {
                // Distinguish pool exhaustion from ECS overflow by
                // re-trying the ECS reserve we know just failed --
                // a fresh `alloc` returns nil for both.  Cheap: the
                // common path is success.  Either error is rare.
                if (self.watermark >= self.data.len and self.free_count == 0) {
                    return error.PoolExhausted;
                }
                return error.EcsEntityOverflow;
            }
            self.data[h.index()] = primary;
            return h;
        }

        /// Internal: composite spawn.  Resolves the primary (from
        /// `composite.primary` or the zero-sized default), then runs
        /// a single archetype transition to attach the remaining
        /// fields as secondary components.  Field names in the
        /// composite are decorative -- field TYPES drive the ECS
        /// component registration.
        fn spawnComposite(self: *Self, gpa: Allocator, composite: anytype) !Handle(T_primary) {
            const T_composite: type = @TypeOf(composite);
            const ti = @typeInfo(T_composite);
            if (ti != .@"struct") {
                @compileError("spawnComposite expects a struct literal; got " ++ @typeName(T_composite));
            }

            // Resolve the primary value.  If `composite` carries a
            // `.primary` field, use it (and validate the type).
            // Otherwise -- only legal when the primary is zero-sized --
            // synthesize the default value.
            const primary_is_zero_sized: bool = @sizeOf(T_primary) == 0;
            const primary_val: T_primary = if (@hasField(T_composite, "primary")) b: {
                const v = @field(composite, "primary");
                if (@TypeOf(v) != T_primary) {
                    @compileError("spawn `.primary` field type mismatch: expected " ++
                        @typeName(T_primary) ++ ", got " ++ @typeName(@TypeOf(v)));
                }
                break :b v;
            } else b: {
                if (!primary_is_zero_sized) {
                    @compileError("spawn composite struct must have a `.primary` field of type " ++
                        @typeName(T_primary) ++ " (only worlds with a zero-sized primary may omit it)");
                }
                break :b T_primary{};
            };

            const e: Handle(T_primary) = try spawnPrimary(self, primary_val);
            errdefer _ = e.destroy(self);

            // Compute non-primary field count at comptime.
            const N: usize = comptime b: {
                var n: usize = 0;
                for (ti.@"struct".field_names) |f_name| {
                    if (!std.mem.eql(u8, f_name, "primary")) {
                        n += 1;
                    }
                }
                break :b n;
            };

            // Primary-only spawn: skip the archetype transition.
            if (N == 0) {
                return e;
            }

            // Build name/type/attribute arrays comptime, then assemble
            // an Add struct via the @Struct builtin.  ECS reads field
            // types to register components; field names are arbitrary
            // labels (re-used here just so we can copy values across).
            const Add: type = comptime b: {
                var names: [N][:0]const u8 = undefined;
                var types: [N]type = undefined;
                var attrs: [N]std.builtin.Type.Struct.FieldAttributes = undefined;
                var i: usize = 0;
                for (ti.@"struct".field_names, ti.@"struct".field_types) |f_name, f_type| {
                    if (std.mem.eql(u8, f_name, "primary")) {
                        continue;
                    }
                    names[i] = f_name;
                    types[i] = f_type;
                    attrs[i] = .{};
                    i += 1;
                }
                break :b @Struct(.auto, null, &names, &types, &attrs);
            };

            var add: Add = undefined;
            inline for (ti.@"struct".field_names) |f_name| {
                comptime if (std.mem.eql(u8, f_name, "primary")) {
                    continue;
                };
                @field(add, f_name) = @field(composite, f_name);
            }

            const ecs_e: Entity = .{ .key = .{
                .index = e.index(),
                .generation = @fromBackingInt(@intCast(e.cycle())),
            } };
            _ = try ecs_e.changeArchImmediateOrErr(&self.ecs, gpa, Add, .{ .add = add });
            return e;
        }

        // ---- Iteration
        /// Walk live entities, calling `cb` for each match.  One
        /// verb covers every walk shape; the cost model is chosen at
        /// comptime from the callback's signature.
        /// Callback parameters after `ctx`, in order:
        /// 1. Optional `Handle(T_primary)` -- the user-facing handle
        ///    for this entity.  Include it when you need to retain
        ///    a reference past the iteration.
        /// 2. Optional `*T_primary` or `*const T_primary` -- the
        ///    primary component, fast-pool deref'd.
        /// 3. Zero or more `*S` / `*const S` -- secondary components
        ///    to require (entities missing any of them are skipped).
        /// Walk shape (chosen automatically):
        ///   - No secondaries, only primary  -> pool scan (~1 byte
        ///     of liveness check + 1 data load per slot).
        ///   - Has secondaries               -> archetype walk; the
        ///     primary (if requested) is deref'd via the pool per
        ///     match.
        /// Examples:
        /// ```
        ///   // Walk every primary:
        ///   world.forEach(struct {
        ///       fn run(_: Empty, tex: *GpuTexture) void { _ = tex; }
        ///   }.run, .{});
        ///   // Walk entities with a secondary, deref primary:
        ///   world.forEach(struct {
        ///       fn run(c: *Ctx, mesh: *GpuMesh, mat: *const MaterialRef) void {
        ///           _ = c; _ = mesh; _ = mat;
        ///       }
        ///   }.run, &ctx);
        ///   // Walk entities with a secondary, also get the handle:
        ///   world.forEach(struct {
        ///       fn run(c: *Ctx, h: Handle(GpuMesh), _: *const Tag) void {
        ///           c.victims.append(h) catch {};
        ///       }
        ///   }.run, &ctx);
        /// ```
        pub fn forEach(
            self: *Self,
            comptime cb: anytype,
            ctx: anytype,
        ) void {
            const params = comptime viewLib.params(@TypeOf(cb));
            // params[0] is Ctx type; params[1..] are the entity-related args.

            comptime {
                if (params.len < 2) {
                    @compileError("forEach callback must take at least (ctx, ...) with one entity-related param");
                }
            }

            // Classify what the callback wants in positions [1..].
            const wants_handle: bool = comptime params[1] == Handle(T_primary);
            const sec_start_with_handle: usize = comptime if (wants_handle) 2 else 1;

            const wants_primary: bool = comptime b: {
                if (params.len <= sec_start_with_handle) break :b false;
                const P = params[sec_start_with_handle];
                break :b (P == *T_primary) or (P == *const T_primary);
            };
            const sec_start: usize = comptime sec_start_with_handle + @intFromBool(wants_primary);

            const SecondaryCount: usize = comptime params.len - sec_start;

            comptime {
                if (!wants_handle and !wants_primary and SecondaryCount == 0) {
                    @compileError("forEach callback has no entity params after ctx");
                }
                // Footgun guard: the primary, if present, must appear in
                // the right position (1 after ctx, or 2 if Handle is
                // first).  If `*T_primary` shows up in the secondaries
                // slot, the user almost certainly meant for it to be
                // treated as the primary -- but it would silently be
                // sent to the archetype filter where nothing matches and
                // the loop runs zero times.  Catch it here.
                for (params[sec_start..]) |P| {
                    if (P == *T_primary or P == *const T_primary) {
                        @compileError(
                            "forEach callback has *" ++ @typeName(T_primary) ++
                                " in a secondary-component slot. The primary must come " ++
                                "immediately after ctx (or after Handle if you want both). " ++
                                "Reorder the callback's parameters.",
                        );
                    }
                }
                // Same for Handle: if it appears anywhere past position 1,
                // it's likewise misplaced (the dispatch only checks
                // position 1).  No silent-zero hazard there, but a clear
                // error helps.
                for (params[sec_start_with_handle..]) |P| {
                    if (P == Handle(T_primary)) {
                        @compileError(
                            "forEach callback has Handle(" ++ @typeName(T_primary) ++
                                ") past position 1. The handle param must come " ++
                                "immediately after ctx. Reorder the callback's parameters.",
                        );
                    }
                }
            }

            // ---- Pool-scan path: no secondaries, primary required.
            if (comptime SecondaryCount == 0) {
                // We're in the no-secondaries case.  `wants_primary` must
                // be true (the no-secondaries-no-primary case is rejected
                // above unless `wants_handle` is also false).  If only
                // `wants_handle` is set, the user asked to iterate handles
                // without reading the primary -- support it by deref'ing
                // through the same pool scan but not dereferencing data.
                var i: u32 = 1; // slot 0 is reserved for Handle.nil
                while (i < self.watermark) : (i += 1) {
                    const key: HandleTab.Key = .{
                        .index = i,
                        .generation = @fromBackingInt(@intCast(self.cycle[i])),
                    };
                    if (!self.ecs.handle_tab.containsKey(key)) {
                        continue;
                    }
                    if (comptime wants_handle and wants_primary) {
                        const h: Handle(T_primary) = .pack(@intCast(i), self.cycle[i]);
                        const PrimaryParam = params[2];
                        const primary_ptr: PrimaryParam = &self.data[i];
                        cb(ctx, h, primary_ptr);
                    } else if (comptime wants_handle) {
                        const h: Handle(T_primary) = .pack(@intCast(i), self.cycle[i]);
                        cb(ctx, h);
                    } else {
                        const PrimaryParam = params[1];
                        const primary_ptr: PrimaryParam = &self.data[i];
                        cb(ctx, primary_ptr);
                    }
                }
                return;
            }

            // ---- Archetype-walk path: at least one secondary.
            // Build the ECS view.  If we need to identify the entity
            // (for handle or primary deref), prefix the view with
            // `Entity` so we can read the slot index per iteration.
            const needs_entity_in_view: bool = comptime wants_handle or wants_primary;

            const view_types: [if (needs_entity_in_view) SecondaryCount + 1 else SecondaryCount]type = comptime b: {
                var t: [if (needs_entity_in_view) SecondaryCount + 1 else SecondaryCount]type = undefined;
                var i: usize = 0;
                if (needs_entity_in_view) {
                    t[0] = Entity;
                    i = 1;
                }
                for (params[sec_start..], 0..) |p, j| {
                    t[i + j] = p;
                }
                break :b t;
            };
            const View: type = viewLib.Tuple(&view_types);

            // Args tuple type matching the full callback signature.
            const args_types: [params.len]type = comptime b: {
                var t: [params.len]type = undefined;
                for (params, 0..) |p, i| {
                    t[i] = p;
                }
                break :b t;
            };
            const ArgsTuple: type = viewLib.Tuple(&args_types);

            var iter: Registry.Iterator(View) = self.ecs.iteratorWithOptions(View, .{});
            while (iter.next(&self.ecs)) |vw| {
                var args: ArgsTuple = undefined;
                args[0] = ctx;

                if (comptime needs_entity_in_view) {
                    const ecs_e: Entity = vw[0];
                    if (comptime wants_handle) {
                        const h: Handle(T_primary) = .pack(
                            @intCast(ecs_e.key.index),
                            self.cycle[ecs_e.key.index],
                        );
                        args[1] = h;
                    }
                    if (comptime wants_primary) {
                        const PrimaryParam = params[sec_start_with_handle];
                        const primary_ptr: PrimaryParam = &self.data[ecs_e.key.index];
                        args[sec_start_with_handle] = primary_ptr;
                    }
                    // Secondaries start at vw[1].
                    inline for (sec_start..params.len) |i| {
                        args[i] = vw[i - sec_start + 1];
                    }
                } else {
                    // No entity prefix in the view; secondaries map 1:1.
                    inline for (1..params.len) |i| {
                        args[i] = vw[i - 1];
                    }
                }
                @call(.auto, cb, args);
            }
        }
    };
}

// =============================================================================
// SECTION - Tests
// =============================================================================

const testing = std.testing;

test "Entities: spawn + deref returns the value" {
    const TestPrimary = struct { x: i32, y: i32 };

    var w: Entities(TestPrimary) = try .init(testing.allocator, .{
        .capacity = 16,
    });
    defer w.deinit(testing.allocator);

    const e1: Handle(TestPrimary) = try w.spawn(testing.allocator, .{ .x = 1, .y = 2 });
    const e2: Handle(TestPrimary) = try w.spawn(testing.allocator, .{ .x = 3, .y = 4 });

    try testing.expect(!e1.eql(e2));

    const p1: *TestPrimary = e1.deref(&w).?;
    try testing.expectEqual(@as(i32, 1), p1.x);
    try testing.expectEqual(@as(i32, 2), p1.y);

    const p2: *TestPrimary = e2.deref(&w).?;
    try testing.expectEqual(@as(i32, 3), p2.x);
    try testing.expectEqual(@as(i32, 4), p2.y);
}

test "Entities: get(T_primary) takes the fast path" {
    const TestPrimary = struct { v: i32 };

    var w: Entities(TestPrimary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    const e: Handle(TestPrimary) = try w.spawn(testing.allocator, .{ .v = 42 });
    const p: *TestPrimary = e.get(&w, TestPrimary).?;
    try testing.expectEqual(@as(i32, 42), p.v);
}

test "Entities: destroy invalidates the entity" {
    const TestPrimary = struct { x: i32 };

    var w: Entities(TestPrimary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    const e: Handle(TestPrimary) = try w.spawn(testing.allocator, .{ .x = 42 });
    try testing.expect(e.destroy(&w));
    try testing.expect(e.deref(&w) == null);
    // Second destroy is a no-op.
    try testing.expect(!e.destroy(&w));
}

test "Entities: pool and ecs allocate matched indices through churn" {
    const TestPrimary = struct { v: i32 };

    var w: Entities(TestPrimary) = try .init(testing.allocator, .{
        .capacity = 16,
    });
    defer w.deinit(testing.allocator);

    const e1: Handle(TestPrimary) = try w.spawn(testing.allocator, .{ .v = 1 });
    const e2: Handle(TestPrimary) = try w.spawn(testing.allocator, .{ .v = 2 });
    const e3: Handle(TestPrimary) = try w.spawn(testing.allocator, .{ .v = 3 });

    // Free the middle slot.  Pool's LIFO free list pushes idx(e2);
    // ECS's free list pushes the same index.
    _ = e2.destroy(&w);

    // Next spawn re-uses the recycled slot.  Both sides have to
    // pick the same index for the synchronization to hold - the
    // assertion inside `spawn` catches divergence.
    const e4: Handle(TestPrimary) = try w.spawn(testing.allocator, .{ .v = 4 });
    try testing.expectEqual(e2.index(), e4.index());

    // Different cycle byte → distinct handle.
    try testing.expect(!e2.eql(e4));

    _ = e1;
    _ = e3;
}

test "Entities: attach + get(secondary) goes through the archetype" {
    const Primary = struct { x: i32 };
    const Mark = struct { id: u32 };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    const e: Handle(Primary) = try w.spawn(testing.allocator, .{ .x = 99 });

    // Initially no Mark → get returns null.
    try testing.expect(e.get(&w, Mark) == null);

    const attached: bool = try e.attach(testing.allocator, &w, Mark{ .id = 7 });
    try testing.expect(attached);

    const tag: *Mark = e.get(&w, Mark).?;
    try testing.expectEqual(@as(u32, 7), tag.id);

    // Primary still readable via the fast path.
    const p: *Primary = e.deref(&w).?;
    try testing.expectEqual(@as(i32, 99), p.x);
}

test "Entities: destroy drops attached secondaries" {
    const Primary = struct { x: i32 };
    const Mark = struct { id: u32 };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    const e: Handle(Primary) = try w.spawn(testing.allocator, .{ .x = 1 });
    _ = try e.attach(testing.allocator, &w, Mark{ .id = 7 });
    try testing.expect(e.destroy(&w));

    // Both primary and secondary unreachable after destroy.
    try testing.expect(e.deref(&w) == null);
    try testing.expect(e.get(&w, Mark) == null);
}

test "Entities: forEach (primary only) visits every live entity" {
    const Primary = struct { v: i32 };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 16,
    });
    defer w.deinit(testing.allocator);

    _ = try w.spawn(testing.allocator, .{ .v = 10 });
    _ = try w.spawn(testing.allocator, .{ .v = 20 });
    _ = try w.spawn(testing.allocator, .{ .v = 30 });

    const Ctx = struct { sum: i32 = 0 };
    var ctx: Ctx = .{};
    const visit = struct {
        fn cb(c: *Ctx, p: *Primary) void {
            c.sum += p.v;
        }
    }.cb;

    w.forEach(visit, &ctx);
    try testing.expectEqual(@as(i32, 60), ctx.sum);
}

test "Entities: spawn (composite) spawns primary + secondaries in one transition" {
    const Primary = struct { x: i32 };
    const MarkA = struct { id: u32 };
    const MarkB = struct { flag: bool };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    const e: Handle(Primary) = try w.spawn(testing.allocator, .{
        .primary = Primary{ .x = 100 },
        .tag = MarkA{ .id = 42 },
        .mark = MarkB{ .flag = true },
    });

    // Primary readable via the fast path.
    const p: *Primary = e.deref(&w).?;
    try testing.expectEqual(@as(i32, 100), p.x);

    // Both secondaries present in one archetype.
    const t: *MarkA = e.get(&w, MarkA).?;
    try testing.expectEqual(@as(u32, 42), t.id);

    const m: *MarkB = e.get(&w, MarkB).?;
    try testing.expect(m.flag);
}

test "Entities: spawn (composite) with only primary degenerates to fast path" {
    const Primary = struct { v: i32 };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    const e: Handle(Primary) = try w.spawn(testing.allocator, .{ .primary = Primary{ .v = 7 } });
    const p: *Primary = e.deref(&w).?;
    try testing.expectEqual(@as(i32, 7), p.v);
}

test "Entities: forEach with primary + secondaries on matched entities" {
    const Primary = struct { v: i32 };
    const Mark = struct { id: u32 };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 16,
    });
    defer w.deinit(testing.allocator);

    // Three entities total; only two carry Mark.
    _ = try w.spawn(testing.allocator, .{ .v = 1 });
    const e2: Handle(Primary) = try w.spawn(testing.allocator, .{
        .primary = Primary{ .v = 2 },
        .tag = Mark{ .id = 100 },
    });
    _ = try w.spawn(testing.allocator, .{ .v = 3 });
    const e4: Handle(Primary) = try w.spawn(testing.allocator, .{
        .primary = Primary{ .v = 4 },
        .tag = Mark{ .id = 200 },
    });

    const Ctx = struct {
        primary_sum: i32 = 0,
        tag_sum: u32 = 0,
        visits: u32 = 0,
    };
    var ctx: Ctx = .{};
    const visit = struct {
        fn cb(c: *Ctx, p: *Primary, t: *Mark) void {
            c.primary_sum += p.v;
            c.tag_sum += t.id;
            c.visits += 1;
        }
    }.cb;

    w.forEach(visit, &ctx);

    // Only the two Mark-carrying entities visited.
    try testing.expectEqual(@as(u32, 2), ctx.visits);
    try testing.expectEqual(@as(i32, 6), ctx.primary_sum); // 2 + 4
    try testing.expectEqual(@as(u32, 300), ctx.tag_sum); // 100 + 200
    _ = e2;
    _ = e4;
}

test "Entities: forEach works with multiple secondaries" {
    const Primary = struct { name: u32 };
    // Pos and Vel are nominally distinct so the ECS can keep them
    // in separate component slots; both wrap a Vec2 since that's
    // what they semantically are (turn 350 directive: Vec2 =
    // @Vector(2, f32), no `struct { x, y }` aliases).
    const Pos = struct { v: Vec2 };
    const Vel = struct { v: Vec2 };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    _ = try w.spawn(testing.allocator, .{
        .primary = Primary{ .name = 1 },
        .p = Pos{ .v = .{ 10, 20 } },
        .v = Vel{ .v = .{ 1, 2 } },
    });
    _ = try w.spawn(testing.allocator, .{
        .primary = Primary{ .name = 2 },
        .p = Pos{ .v = .{ 30, 40 } },
        // No Vel - should be skipped by the query.
    });

    var visited: u32 = 0;
    const visit = struct {
        fn cb(counter: *u32, _: *Primary, p: *Pos, v: *Vel) void {
            counter.* += 1;
            // Apply velocity to position to prove pointers are writable.
            p.v += v.v;
        }
    }.cb;

    w.forEach(visit, &visited);

    try testing.expectEqual(@as(u32, 1), visited);
}

test "Entities: empty primary - composite omits .primary, fast path takes .{}" {
    const Empty = struct {};
    const Pos = struct { x: f32 };

    var w: Entities(Empty) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    // spawn(.{}) - explicit empty value for the primary.
    const e1: Handle(Empty) = try w.spawn(testing.allocator, .{});
    try testing.expect(!e1.isNil());

    // composite without a .primary field - auto-defaults the empty primary.
    const e2: Handle(Empty) = try w.spawn(testing.allocator, .{
        .pos = Pos{ .x = 3.14 },
    });
    try testing.expect(!e2.isNil());

    const got: *Pos = e2.get(&w, Pos).?;
    try testing.expectEqual(@as(f32, 3.14), got.x);
}

test "Entities: forEach yields the user-facing Entity handle" {
    const Empty = struct {};
    const Mark = struct { id: u32 };

    var w: Entities(Empty) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    const e1: Handle(Empty) = try w.spawn(testing.allocator, .{ .t = Mark{ .id = 100 } });
    const e2: Handle(Empty) = try w.spawn(testing.allocator, .{ .t = Mark{ .id = 200 } });

    const Ctx = struct {
        seen: [2]Handle(Empty) = undefined,
        i: usize = 0,
    };
    var ctx: Ctx = .{};

    // Callback receives Entity (the user's handle), NOT Entity.
    const visit = struct {
        fn cb(c: *Ctx, e: Handle(Empty), _: *Mark) void {
            c.seen[c.i] = e;
            c.i += 1;
        }
    }.cb;

    w.forEach(visit, &ctx);

    try testing.expectEqual(@as(usize, 2), ctx.i);
    // Order matches archetype iteration order; both handles equal one of e1/e2.
    try testing.expect(ctx.seen[0].eql(e1) or ctx.seen[0].eql(e2));
    try testing.expect(ctx.seen[1].eql(e1) or ctx.seen[1].eql(e2));
    try testing.expect(!ctx.seen[0].eql(ctx.seen[1]));
}

test "Entities: forEach still works without an Entity param" {
    const Empty = struct {};
    const Mark = struct { id: u32 };

    var w: Entities(Empty) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    _ = try w.spawn(testing.allocator, .{ .t = Mark{ .id = 7 } });
    _ = try w.spawn(testing.allocator, .{ .t = Mark{ .id = 35 } });

    var sum: u32 = 0;
    const visit = struct {
        fn cb(s: *u32, t: *Mark) void {
            s.* += t.id;
        }
    }.cb;
    w.forEach(visit, &sum);

    try testing.expectEqual(@as(u32, 42), sum);
}

test "Entities: forEach with handle + primary + secondary" {
    const Primary = struct { v: u32 };
    const Mark = struct { id: u32 };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    const e1: Handle(Primary) = try w.spawn(testing.allocator, .{
        .primary = Primary{ .v = 10 },
        .t = Mark{ .id = 1 },
    });
    _ = e1;

    const Ctx = struct {
        seen_handle: bool = false,
        seen_v: u32 = 0,
        seen_id: u32 = 0,
    };
    var ctx: Ctx = .{};
    const visit = struct {
        fn cb(c: *Ctx, h: Handle(Primary), p: *Primary, m: *const Mark) void {
            c.seen_handle = !h.isNil();
            c.seen_v = p.v;
            c.seen_id = m.id;
        }
    }.cb;
    w.forEach(visit, &ctx);

    try testing.expect(ctx.seen_handle);
    try testing.expectEqual(@as(u32, 10), ctx.seen_v);
    try testing.expectEqual(@as(u32, 1), ctx.seen_id);
}

test "Entities: forEach pool-scan with handle + primary (no secondaries)" {
    const Primary = struct { v: u32 };

    var w: Entities(Primary) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    _ = try w.spawn(testing.allocator, .{ .v = 1 });
    _ = try w.spawn(testing.allocator, .{ .v = 2 });
    _ = try w.spawn(testing.allocator, .{ .v = 3 });

    const Ctx = struct {
        count: u32 = 0,
        sum: u32 = 0,
        any_handle_nil: bool = false,
    };
    var ctx: Ctx = .{};
    const visit = struct {
        fn cb(c: *Ctx, h: Handle(Primary), p: *Primary) void {
            c.count += 1;
            c.sum += p.v;
            if (h.isNil()) c.any_handle_nil = true;
        }
    }.cb;
    w.forEach(visit, &ctx);

    try testing.expectEqual(@as(u32, 3), ctx.count);
    try testing.expectEqual(@as(u32, 6), ctx.sum);
    try testing.expect(!ctx.any_handle_nil);
}

test "Entities: attachAll adds multiple components in one transition" {
    const Empty = struct {};
    const A = struct { v: u32 };
    const B = struct { s: []const u8 };

    var w: Entities(Empty) = try .init(testing.allocator, .{
        .capacity = 4,
    });
    defer w.deinit(testing.allocator);

    const e: Handle(Empty) = try w.spawn(testing.allocator, .{});
    try testing.expect(try e.attachAll(testing.allocator, &w, .{
        .a = A{ .v = 99 },
        .b = B{ .s = "hello" },
    }));

    try testing.expectEqual(@as(u32, 99), e.get(&w, A).?.v);
    try testing.expectEqualStrings("hello", e.get(&w, B).?.s);
}

test "Entities: alloc returns uninitialized handle, freeable like spawn" {
    const Texture = struct { id: u32, width: i32, height: i32 };

    var w: Entities(Texture) = try .init(testing.allocator, .{
        .capacity = 8,
    });
    defer w.deinit(testing.allocator);

    // GL-style two-phase: alloc the handle, then fill in the data.
    const h: Handle(Texture) = w.alloc();
    try testing.expect(!h.isNil());

    const tex: *Texture = h.deref(&w).?;
    tex.* = .{ .id = 42, .width = 256, .height = 256 };

    // Reading back works through the normal deref path.
    const got: *Texture = h.deref(&w).?;
    try testing.expectEqual(@as(u32, 42), got.id);

    // Destroy returns true for a live slot.
    try testing.expect(h.destroy(&w));
    try testing.expect(h.deref(&w) == null);
}

test "Entities: alloc returns nil on capacity exhaustion" {
    var w: Entities(u32) = try .init(testing.allocator, .{
        .capacity = 3,
    });
    defer w.deinit(testing.allocator);

    // pool_capacity=3 includes the reserved slot 0, so 2 usable.
    const h1: Handle(u32) = w.alloc();
    const h2: Handle(u32) = w.alloc();
    try testing.expect(!h1.isNil());
    try testing.expect(!h2.isNil());

    const h3: Handle(u32) = w.alloc();
    try testing.expect(h3.isNil());
}

test "Entities: cross-world handles get distinct debug stamps" {
    // Two worlds of the same primary type would normally produce
    // interchangeable handles -- the phantom-type system can't tell
    // them apart (both are `Handle(u32)`).  The world_stamp mechanism
    // catches misuse at runtime in debug builds.
    // We verify the stamps differ; the panic itself can't be tested
    // here (no `expectPanic`), but a different-stamp handle going
    // into deref will trip `assertMatch` in debug.
    if (comptime !world_stamp.enabled) {
        return; // release: stamps are void, no protection, no test
    }

    var w1: Entities(u32) = try .init(testing.allocator, .{ .capacity = 4 });
    defer w1.deinit(testing.allocator);
    var w2: Entities(u32) = try .init(testing.allocator, .{ .capacity = 4 });
    defer w2.deinit(testing.allocator);

    try testing.expect(w1.debug_stamp != w2.debug_stamp);

    const h1: Handle(u32) = try w1.spawn(testing.allocator, 100);
    const h2: Handle(u32) = try w2.spawn(testing.allocator, 200);
    try testing.expect(h1.debug_stamp == w1.debug_stamp);
    try testing.expect(h2.debug_stamp == w2.debug_stamp);
    try testing.expect(h1.debug_stamp != h2.debug_stamp);

    // Same-world deref works.
    try testing.expectEqual(@as(u32, 100), h1.deref(&w1).?.*);
    try testing.expectEqual(@as(u32, 200), h2.deref(&w2).?.*);

    // Cross-world deref would `assertMatch` panic -- can't test the
    // panic directly, but the stamp-difference proof above shows the
    // mechanism is armed.
}

// ============================================================================
// Registry stamp (formerly src/world_stamp.zig)
// ============================================================================
// Per-world debug stamps catch cross-world handle misuse in debug
// builds.  Wrapped in `const world_stamp = struct` so callers (the
// inlined pool and ECS code below) see the same `world_stamp.Stamp`,
// `world_stamp.next()`, `world_stamp.assertMatch(...)` API as before.

// ============================================================================
// ECS internals (formerly src/zig)
// ============================================================================
// Archetype-based ECS storage that backs `Entities`'s secondary
// components.  Wrapped in `const ecs = struct` so the existing
// `Registry`, `Entity`, `Node`, etc. references inside
// this file resolve unchanged.  `Node` is re-exported near the top
// for external callers.

// ============================================================================
// Node - parent/child trees (scenegraph foundation)
// ============================================================================

/// Configuration parameters for `NodeWithOptions`.
pub const NodeOptions = struct {
    /// User-pickable name field type.  `?[:0]const u8` (the
    /// default `Node` alias) is the common pick - null for
    /// unnamed nodes, static strings for named ones.  Use
    /// `void` if you don't want names; use `[16:0]u8` for
    /// inline fixed-cap names.
    Name: type,
};

/// Build a parent/child tree node parameterized on the name
/// field type.  Most code wants `Node` (the default
/// specialization with `?[:0]const u8` names) - call this
/// directly only when you have a specific reason to vary.
/// A node component, attached to an entity, places that
/// entity in a tree: each node carries handles for parent,
/// first_child, prev_sib, next_sib (intrusive linked list of
/// siblings).  The tree's anchor is a `Tree` value held in
/// user state - multiple Trees per world are fine, one per
/// scene-graph instance.
/// Mutation has two flavors that mirror the core ECS:
/// `*Immediate` ops apply now (load-time setup), the
/// command-buffer ops queue for `Node.Exec.afterCmdBuf`
/// (frame-rate-safe under iteration).
pub fn NodeWithOptions(node_options: NodeOptions) type {
    return struct {
        const Self = @This();

        /// User label.  Ignored by tree machinery - purely a
        /// debug/tools affordance.  Static strings are easy;
        /// dynamically-allocated names need a destruction
        /// hook to free them when the entity dies (no ECS
        /// support for that out of the box).
        /// Living on the node component (rather than as a
        /// separate component) reduces fragmentation: every
        /// node lives in the same archetype regardless of
        /// whether names are populated.
        name: node_options.Name = std.mem.zeroes(node_options.Name),
        /// Parent in the tree.  `.none` for roots.
        parent: Entity.Optional = .none,
        /// First (leftmost) child, walked via `next_sib`.
        first_child: Entity.Optional = .none,
        /// Previous sibling.  `.none` if leftmost.
        prev_sib: Entity.Optional = .none,
        /// Next sibling.  `.none` if rightmost.
        next_sib: Entity.Optional = .none,
        /// Local active flag - user-visible.  `false` typically
        /// means "hide this object" in scenegraph semantics.
        /// Distinct from `active` because a chain of inactive
        /// ancestors should override an `active_self = true`.
        active_self: bool = true,
        /// Effective active flag - `active_self AND every
        /// ancestor's active_self`.  Computed on-demand by
        /// `Node.Exec.afterCmdBuf` after tree mutations
        /// settle; reads are O(1).
        active: bool = true,

        /// The anchor for one tree's roots.  Lives in user
        /// state.  Multiple Trees per world is supported
        /// use one per scene-graph instance.
        pub const Tree = struct {
            pub const empty: @This() = .{ .first_child = .none };
            /// First root in this tree.
            first_child: Entity.Optional,

            /// First root, or null if the tree is empty.
            pub fn getFirstChild(self: @This(), es: *const Registry) ?*Self {
                const entity: Entity = self.first_child.unwrap() orelse return null;
                return entity.get(es, Self).?;
            }

            /// Iterate this tree's immediate roots (top-level
            /// children).  Doesn't descend - that's
            /// `Node.descendantIterator` on a specific node.
            pub fn childIterator(
                self: *const @This(),
                options: SiblingIterator.Options,
            ) SiblingIterator {
                return .{
                    .curr = self.first_child,
                    .active_only = options.active_only,
                };
            }

            /// Count the roots.  O(N) - walks them.  Prefer
            /// `childCountLt` / `hasChildren` for thresholds.
            pub fn countChildren(
                self: *const @This(),
                es: *Registry,
                options: SiblingIterator.Options,
            ) usize {
                var count: usize = 0;
                var iter = self.childIterator(options);
                while (iter.next(es)) |_| {
                    count += 1;
                }
                return count;
            }

            /// True if fewer than `n` roots.  Stops walking
            /// once the answer is known - cheaper than
            /// `countChildren() < n` when n is small.
            pub fn childCountLt(
                self: *const @This(),
                es: *Registry,
                n: usize,
                options: SiblingIterator.Options,
            ) bool {
                var iter = self.childIterator(options);
                for (0..n) |_| {
                    if (iter.next(es) == null) {
                        return true;
                    }
                }
                return false;
            }

            /// True if `<= n` roots.
            pub fn childCountLte(
                self: *const @This(),
                es: *Registry,
                n: usize,
                options: SiblingIterator.Options,
            ) bool {
                var iter = self.childIterator(options);
                for (0..n) |_| {
                    if (iter.next(es) == null) {
                        return true;
                    }
                }
                return iter.next(es) == null;
            }

            /// True iff there's at least one root.
            pub fn hasChildren(self: *const @This()) bool {
                return self.first_child.unwrap() != null;
            }
        };

        /// Pair an entity handle with a pointer to its node
        /// component.  Many tree operations need both - the
        /// entity for handle-table lookups, the node for the
        /// linked-list field reads.  `View` carries both so
        /// callers don't have to keep them in sync manually.
        pub const View = struct {
            entity: Entity,
            node: *Self,

            /// Parent View, or null at root.
            pub fn getParent(self: *const @This(), es: *const Registry) ?View {
                const e: Entity = self.node.parent.unwrap() orelse return null;
                return .{
                    .entity = e,
                    .node = e.get(es, Self).?,
                };
            }

            /// First child View, or null if leaf.
            pub fn getFirstChild(self: @This(), es: *const Registry) ?View {
                const e: Entity = self.node.first_child.unwrap() orelse return null;
                return .{
                    .entity = e,
                    .node = e.get(es, Self).?,
                };
            }

            /// Previous-sibling View, or null if leftmost.
            pub fn getPrevSib(self: *const @This(), es: *const Registry) ?View {
                const e: Entity = self.node.prev_sib.unwrap() orelse return null;
                return .{
                    .entity = e,
                    .node = e.get(es, Self).?,
                };
            }

            /// Next-sibling View, or null if rightmost.
            pub fn getNextSib(self: *const @This(), es: *const Registry) ?View {
                const e: Entity = self.node.next_sib.unwrap() orelse return null;
                return .{
                    .entity = e,
                    .node = e.get(es, Self).?,
                };
            }
        };

        /// Format as a debug-readable struct literal.  Skips
        /// `name` because its type is user-pickable and may
        /// not implement format itself.
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            // The body enumerates fields by hand - keep it in
            // sync with the actual field count.
            comptime assert(std.meta.fieldNames(@This()).len == 6, @src());

            try writer.writeAll(".{ ");
            try writer.print(".parent = {f}, ", .{self.parent});
            try writer.print(".first_child = {f}, ", .{self.first_child});
            try writer.print(".prev_sib = {f}, ", .{self.prev_sib});
            try writer.print(".next_sib = {f}, ", .{self.next_sib});
            try writer.print(".active_self = {}, ", .{self.active_self});
            try writer.print(".active = {}, ", .{self.active});
            try writer.writeAll("}");
        }

        /// Hook this node into `tr` as a new root.  Called
        /// automatically by the command-buffer flow; manual
        /// callers using the immediate API must call it
        /// before any mutation.
        /// Asserts the node is fresh (no parent/sibling links
        /// yet) so we don't silently leave stale pointers.
        pub fn init(self: *@This(), es: *Registry, tr: *Tree) void {
            assert(self.uninitialized(es, tr), @src());
            const entity: Entity = es.getEntity(self);
            self.next_sib = tr.first_child;
            if (tr.getFirstChild(es)) |fc| {
                fc.prev_sib = entity.toOptional();
            }
            tr.first_child = entity.toOptional();
        }

        /// True if this node has never been hooked into a
        /// tree.  Specifically: no parent, no prev_sib, AND
        /// not registered as the tree's first_child.  When
        /// those three hold, we also assert the symmetrical
        /// expectations (no next_sib, no first_child) - those
        /// are enforced by every mutation path.
        pub fn uninitialized(self: *const @This(), es: *const Registry, tr: *const Tree) bool {
            const entity: Entity = es.getEntity(self);
            const looks_uninit: bool =
                self.parent.unwrap() == null and
                self.prev_sib.unwrap() == null and
                tr.first_child != entity.toOptional();
            if (looks_uninit) {
                assert(self.next_sib.unwrap() == null, @src());
                assert(self.first_child.unwrap() == null, @src());
                return true;
            }
            return false;
        }

        /// Set local-active and propagate the effective-active
        /// recompute downward.  No-op when the new value
        /// matches - saves the descendant walk in the common
        /// case.
        pub fn setActive(self: *@This(), es: *const Registry, active: bool) void {
            if (self.active_self != active) {
                self.active_self = active;
                self.sync(es);
            }
        }

        /// Recompute `self.active` from `self.active_self` and
        /// the parent's effective active, then walk descendants
        /// and propagate.  Stops walking subtrees whose
        /// effective-active didn't change - saves a lot of
        /// work when a deep subtree's active state was
        /// already correct.
        /// Called automatically by `setActive`,
        /// `setParentImmediate`, `insertImmediate`.  Direct
        /// callers normally don't need this.
        pub fn sync(self: *@This(), es: *const Registry) void {
            self.active = b: {
                if (!self.active_self) {
                    break :b false;
                }
                const parent: *Self = self.getParent(es) orelse break :b true;
                break :b parent.active;
            };

            var nodes = self.preOrderIterator(es, .{});
            while (nodes.next(es)) |curr| {
                const new_active: bool = curr.node.active_self and
                    curr.node.getParent(es).?.active;
                if (new_active == curr.node.active) {
                    // Subtree's correct already - skip it.
                    nodes.skipSubtree(es, curr.node);
                } else {
                    curr.node.active = new_active;
                }
            }
        }

        /// Parent's node, or null at root.  Differs from
        /// `View.getParent` only in the return shape (raw
        /// pointer vs paired `View`) - pick whichever fits.
        pub fn getParent(self: *const @This(), es: *const Registry) ?*Self {
            const parent: Entity = self.parent.unwrap() orelse return null;
            return parent.get(es, Self).?;
        }

        /// First (leftmost) child node, or null if leaf.
        pub fn getFirstChild(self: *const @This(), es: *const Registry) ?*Self {
            const first_child: Entity = self.first_child.unwrap() orelse return null;
            return first_child.get(es, Self).?;
        }

        /// Previous (left) sibling, or null at leftmost.
        pub fn getPrevSib(self: *const @This(), es: *const Registry) ?*Self {
            const prev_sib: Entity = self.prev_sib.unwrap() orelse return null;
            return prev_sib.get(es, Self).?;
        }

        /// Next (right) sibling, or null at rightmost.
        pub fn getNextSib(self: *const @This(), es: *const Registry) ?*Self {
            const next_sib: Entity = self.next_sib.unwrap() orelse return null;
            return next_sib.get(es, Self).?;
        }

        /// Walk ancestors (immediate parent, then its parent,
        /// etc.) and return the nearest `*T`, or null if none
        /// of them carry T.  THE workhorse of scenegraph
        /// traversal - "find this child's enclosing Camera",
        /// "find the layout root", etc.
        pub fn getInAncestor(self: *const @This(), es: *const Registry, T: type) ?*T {
            var ancestors = self.ancestorIterator();
            while (ancestors.next(es)) |ancestor| {
                if (ancestor.entity.get(es, T)) |result| {
                    return result;
                }
            }
            return null;
        }

        /// True iff some ancestor carries `T`.  Cheaper than
        /// `getInAncestor() != null` only marginally - both
        /// short-circuit on the first hit.
        pub fn ancestorHas(self: *const @This(), es: *const Registry, T: type) bool {
            var ancestors = self.ancestorIterator();
            while (ancestors.next(es)) |ancestor| {
                if (ancestor.entity.has(es, T)) {
                    return true;
                }
            }
            return false;
        }

        /// Like `getInAncestor` but materialises a View
        /// (multi-component struct) on the matching ancestor.
        pub fn viewInAncestor(self: *const @This(), es: *const Registry, T: type) ?T {
            var ancestors = self.ancestorIterator();
            while (ancestors.next(es)) |ancestor| {
                if (ancestor.entity.view(es, T)) |result| {
                    return result;
                }
            }
            return null;
        }

        /// Re-parent `self` under `parent_opt` (or to the
        /// root when null).  Cycle-safe: silently no-ops if
        /// the result would put `self` under one of its own
        /// descendants.
        /// Implementation strategy: pluck self out (clean cut
        /// from current parent + siblings), then splice in
        /// at the new location's first_child slot.  The
        /// pointer-lock guard catches any concurrent
        /// iteration.
        pub fn setParentImmediate(
            self: *Self,
            es: *Registry,
            tr: *Tree,
            parent_opt: ?*Self,
        ) void {
            const pointer_lock: PointerLock = es.pointer_generation.lock();
            defer pointer_lock.check(es.pointer_generation);

            // Cycle / self-parent guard.
            if (parent_opt) |parent| {
                if (self == parent) {
                    return;
                }
                if (self.isAncestorOf(es, parent)) {
                    return;
                }
            }

            pluckImmediate(self, es, tr);

            // Splice into the new home - under `parent` if
            // given, else as a fresh root.
            if (parent_opt) |parent| {
                self.parent = es.getEntity(parent).toOptional();
                self.next_sib = parent.first_child;
                const child_entity: Entity = es.getEntity(self);
                if (parent.first_child.unwrap()) |first_child| {
                    first_child.get(es, Self).?.prev_sib = child_entity.toOptional();
                }
                parent.first_child = child_entity.toOptional();
            } else {
                const child: Entity = es.getEntity(self);
                self.next_sib = tr.first_child;
                if (tr.getFirstChild(es)) |fc| {
                    fc.prev_sib = child.toOptional();
                }
                tr.first_child = child.toOptional();
            }

            // Effective-active changed - propagate.
            self.sync(es);
        }

        /// Move `self` to immediately before/after `other` in
        /// the sibling list.  `relative` picks the side.
        /// Cycle-safe like `setParentImmediate`.
        /// Useful for explicit z-ordering: nodes earlier in
        /// the sibling list draw first; later siblings draw
        /// over them.
        pub fn insertImmediate(
            self: *Self,
            es: *Registry,
            tr: *Tree,
            relative: std.meta.Tag(Insert.Position),
            other: *Self,
        ) void {
            const pointer_lock: PointerLock = es.pointer_generation.lock();
            defer pointer_lock.check(es.pointer_generation);

            if (self == other) {
                return;
            }
            if (self.isAncestorOf(es, other)) {
                return;
            }

            pluckImmediate(self, es, tr);

            const self_entity: Entity = es.getEntity(self);
            const other_entity: Entity = es.getEntity(other);

            // Both branches: new node inherits other's parent.
            self.parent = other.parent;

            switch (relative) {
                .after => {
                    // self ←→ other.next_sib  becomes
                    // other ←→ self ←→ other.next_sib
                    self.next_sib = other.next_sib;
                    if (self.next_sib.unwrap()) |next_sib| {
                        next_sib.get(es, Self).?.prev_sib = self_entity.toOptional();
                    }
                    self.prev_sib = other_entity.toOptional();
                    other.next_sib = self_entity.toOptional();
                },
                .before => {
                    // other.prev_sib ←→ other  becomes
                    // other.prev_sib ←→ self ←→ other
                    // - but if other was leftmost, self
                    // takes over the first_child anchor on
                    // either parent or tree (whichever owns
                    // the sibling list).
                    self.prev_sib = other.prev_sib;
                    if (self.prev_sib.unwrap()) |prev_sib| {
                        prev_sib.get(es, Self).?.next_sib = self_entity.toOptional();
                    } else if (self.getParent(es)) |parent| {
                        assert(parent.first_child == other_entity.toOptional(), @src());
                        parent.first_child = self_entity.toOptional();
                    } else {
                        assert(tr.first_child == other_entity.toOptional(), @src());
                        tr.first_child = self_entity.toOptional();
                    }
                    self.next_sib = other_entity.toOptional();
                    other.prev_sib = self_entity.toOptional();
                },
            }

            self.sync(es);
        }

        /// Destroy this node, its entity, and the whole
        /// subtree underneath.  Auto-runs through `Node.Exec`
        /// when an entity carrying a node is destroyed via
        /// CmdBuf - direct callers only need this when
        /// destroying outside the deferred flow.
        /// Invalidates pointers - every chunk involved gets
        /// swap-removed, so the param is named
        /// `unstable_ptr` as a reminder to read it before
        /// calling internal mutators.
        pub fn destroyImmediate(unstable_ptr: *@This(), es: *Registry, tr: *Tree) void {
            // Stash the entity handle BEFORE pointers move
            // out from under us.
            const e: Entity = es.getEntity(unstable_ptr);

            unstable_ptr.destroyChildrenAndPluckImmediate(es, tr);

            assert(e.destroyImmediate(es), @src());
        }

        /// Cut this node out of its sibling list (and its
        /// parent's first_child anchor, or the tree's, as
        /// applicable) without re-rooting it elsewhere.
        /// After this the node has stale `first_child`
        /// (untouched - the children are still wired to it)
        /// but cleared parent + prev_sib + next_sib.  Caller
        /// must follow up with destroy / remove / re-insert
        /// to leave the tree in a well-formed state.
        /// Internal - exposed as `fn` (not `pub fn`) but
        /// callable from extension code that needs the
        /// surgical primitive.
        fn pluckImmediate(self: *@This(), es: *Registry, tr: *Tree) void {
            // Patch the prev side: prev_sib's next_sib
            // points around us, OR our parent's first_child
            // becomes our next_sib (we were leftmost), OR
            // the tree's first_child does (we were a root).
            if (self.getPrevSib(es)) |prev_sib| {
                prev_sib.next_sib = self.next_sib;
            } else if (self.getParent(es)) |parent| {
                assert(parent.first_child == es.getEntity(self).toOptional(), @src());
                parent.first_child = self.next_sib;
            } else {
                assert(tr.first_child == es.getEntity(self).toOptional(), @src());
                tr.first_child = self.next_sib;
                if (tr.getFirstChild(es)) |fc| {
                    fc.prev_sib = .none;
                }
            }

            // Patch the next side: next_sib's prev_sib
            // points around us.
            if (self.next_sib.unwrap()) |next_sib| {
                next_sib.get(es, Self).?.prev_sib = self.prev_sib;
            }

            // Null our own pointers - caller mostly destroys
            // us next, but be tidy in case the node lives.
            self.prev_sib = .none;
            self.next_sib = .none;
            self.parent = .none;
        }

        /// Pluck this node, then destroy the whole subtree
        /// that was hanging off it.  Two-phase to handle the
        /// pointer-invalidation problem: build the
        /// post-order child iterator BEFORE the first
        /// destroy, so subsequent invalidations don't touch
        /// the iterator's saved state.
        /// Invalidates pointers (after the first destroy
        /// inside the loop).
        pub fn destroyChildrenAndPluckImmediate(
            unstable_ptr: *@This(),
            es: *Registry,
            tr: *Tree,
        ) void {
            const pointer_lock: PointerLock = es.pointer_generation.lock();

            // Phase 1: snapshot the child iterator + pluck
            // self, all under the pointer lock (no destroys
            // yet, so unstable_ptr is still valid).
            var children = b: {
                defer pointer_lock.check(es.pointer_generation);
                const self = unstable_ptr;

                const iter = self.postOrderIterator(es, .{});
                self.pluckImmediate(es, tr);
                self.first_child = .none;

                break :b iter;
            };

            // Phase 2: walk the snapshot and destroy.  Bumps
            // the pointer generation so the iterator's
            // entity-handle replays don't tangle with stale
            // chunk pointers.
            es.pointer_generation.increment();
            while (children.next(es)) |curr| {
                assert(curr.entity.destroyImmediate(es), @src());
            }
        }

        /// True iff `descendant` is in the subtree rooted at
        /// `self`.  Self does NOT count as its own ancestor
        /// (matches the donor's convention; matches typical
        /// scenegraph semantics).
        pub fn isAncestorOf(
            self: *const @This(),
            es: *const Registry,
            descendant: *const Self,
        ) bool {
            var curr: *Self = descendant.getParent(es) orelse return false;
            while (true) {
                if (curr == self) {
                    return true;
                }
                curr = curr.getParent(es) orelse return false;
            }
        }

        /// Iterate this node's immediate children.  Doesn't
        /// descend - that's `descendantIterator`.  When
        /// `active_only` is set on a node that's itself
        /// inactive, returns the empty iterator (no
        /// descendant of an inactive node is effectively
        /// active).
        pub fn childIterator(
            self: *const @This(),
            options: SiblingIterator.Options,
        ) SiblingIterator {
            if (options.active_only and !self.active) {
                return .empty;
            }
            return .{
                .curr = self.first_child,
                .active_only = options.active_only,
            };
        }

        /// Count immediate children.  O(N) walk - prefer
        /// `childCountLt` / `hasChildren` for thresholds.
        pub fn countChildren(
            self: *const @This(),
            es: *Registry,
            options: SiblingIterator.Options,
        ) usize {
            var count: usize = 0;
            var iter = self.childIterator(options);
            while (iter.next(es)) |_| {
                count += 1;
            }
            return count;
        }

        /// True if `< n` immediate children.  Stops walking
        /// once the answer is known - cheaper than
        /// `countChildren() < n` for small `n`.
        pub fn childCountLt(
            self: *const @This(),
            es: *Registry,
            n: usize,
            options: SiblingIterator.Options,
        ) bool {
            var iter = self.childIterator(options);
            for (0..n) |_| {
                if (iter.next(es) == null) {
                    return true;
                }
            }
            return false;
        }

        /// True if `<= n` immediate children.  Same
        /// short-circuit shape as `childCountLt`.
        pub fn childCountLte(
            self: *const @This(),
            es: *Registry,
            n: usize,
            options: SiblingIterator.Options,
        ) bool {
            var iter = self.childIterator(options);
            for (0..n) |_| {
                if (iter.next(es) == null) {
                    return true;
                }
            }
            return iter.next(es) == null;
        }

        /// True iff this node has at least one child.  O(1).
        pub fn hasChildren(self: *const @This()) bool {
            return self.first_child.unwrap() != null;
        }

        /// Walk ancestors (parent, then its parent, etc.) up
        /// to the root.  Self is NOT yielded - first item is
        /// the parent if any.
        pub fn ancestorIterator(self: *const @This()) AncestorIterator {
            return .{ .curr = self.parent };
        }

        /// State for `ancestorIterator`.  Holds the next
        /// ancestor's handle; advancing reads its node and
        /// follows that node's `parent`.
        pub const AncestorIterator = struct {
            curr: Entity.Optional,

            /// Next ancestor View, or null at the root.
            pub fn next(self: *@This(), es: *const Registry) ?View {
                const entity: Entity = self.curr.unwrap() orelse return null;
                const next_view: View = entity.view(es, View).?;
                self.curr = next_view.node.parent;
                return next_view;
            }
        };

        /// Walk this node and its UPCOMING siblings (next,
        /// next-next, …).  Self IS yielded as the first
        /// item, in contrast to `ancestorIterator`.  Useful
        /// for "do something to this node and everything
        /// after it in the sibling list".
        pub fn siblingIterator(
            self: *const @This(),
            es: *const Registry,
            options: SiblingIterator.Options,
        ) SiblingIterator {
            return .{
                .curr = es.getEntity(self).toOptional(),
                .active_only = options.active_only,
            };
        }

        /// State for `childIterator` AND `siblingIterator`
        /// the difference is the starting cursor.
        pub const SiblingIterator = struct {
            curr: Entity.Optional,
            active_only: bool,

            /// Yields nothing.  Used by `childIterator` when
            /// `active_only` is set on an inactive node.
            pub const empty: @This() = .{
                .curr = .none,
                .active_only = false,
            };

            pub const Options = struct {
                active_only: bool = false,
            };

            /// Advance past the current sibling and return
            /// it.  When `active_only`, inactive siblings get
            /// transparently skipped - the consumer never
            /// sees them.
            pub fn next(self: *@This(), es: *const Registry) ?View {
                while (self.curr.unwrap()) |entity| {
                    const curr: View = entity.view(es, View).?;
                    self.curr = curr.node.next_sib;
                    if (self.active_only and !curr.node.active) {
                        continue;
                    }
                    return curr;
                }
                return null;
            }
        };

        /// Pre-order traversal: visit the node BEFORE its
        /// descendants (root first, then leftmost-deepest
        /// last).  Use when a parent's state needs to be set
        /// before descendants observe it (e.g. transform
        /// concatenation, layout passes).
        pub fn preOrderIterator(
            self: *const @This(),
            es: *const Registry,
            options: PreOrderIterator.Options,
        ) PreOrderIterator {
            if (options.active_only and !self.active) {
                return .empty;
            }
            const self_entity: Entity = es.getEntity(self);
            return .{
                .root = self_entity.toOptional(),
                .curr = if (options.include_root) self_entity.toOptional() else self.first_child,
                .active_only = options.active_only,
            };
        }

        /// Pre-order traversal state.  Walks `root`'s subtree
        /// (or excludes `root` itself per `include_root`).
        /// `skipSubtree` lets callers prune branches mid-walk.
        pub const PreOrderIterator = struct {
            root: Entity.Optional,
            curr: Entity.Optional,
            active_only: bool,

            pub const Options = struct {
                include_root: bool = false,
                active_only: bool = false,
            };

            /// Yields nothing.  Returned by `preOrderIterator`
            /// when `active_only` is set on an inactive root.
            pub const empty: @This() = .{
                .root = .none,
                .curr = .none,
                .active_only = false,
            };

            /// Step to the next View.  Algorithm: descend
            /// into first_child if any; else advance to
            /// next_sib at the deepest level that still has
            /// one (walking up parents until we find one).
            /// Stops cleanly at the root boundary.
            pub fn next(self: *@This(), es: *const Registry) ?View {
                while (true) {
                    const pre_entity: Entity = self.curr.unwrap() orelse return null;
                    const pre: View = pre_entity.view(es, View).?;

                    // Active-filter prunes a whole subtree
                    // its descendants are inactive too.
                    if (self.active_only and !pre.node.active) {
                        self.skipSubtree(es, pre.node);
                        continue;
                    }

                    if (pre.node.first_child != Entity.Optional.none) {
                        self.curr = pre.node.first_child;
                    } else if (self.curr.eql(self.root)) {
                        // include_root + childless root: one
                        // visit and we're done.
                        self.curr = .none;
                    } else {
                        // Walk up until we find an ancestor
                        // with a next_sib; that becomes our
                        // next visit.  Stop at the root
                        // its next_sib is outside our scope.
                        var has_next_sib = pre.node;
                        while (has_next_sib.next_sib.unwrap() == null) {
                            if (has_next_sib.parent.unwrap().? == self.root.unwrap().?) {
                                self.curr = .none;
                                return pre;
                            }
                            has_next_sib = has_next_sib.getParent(es).?;
                        }
                        self.curr = has_next_sib.next_sib.unwrap().?.toOptional();
                    }
                    return pre;
                }
            }

            /// Skip past `subtree` and everything inside it.
            /// Consumer hook used by `Node.sync`'s
            /// dirty-subtree-skip optimization.  Asserts
            /// `subtree` lives inside this iterator's root
            /// passing an outside node would loop forever.
            pub fn skipSubtree(self: *@This(), es: *const Registry, subtree: *const Self) void {
                if (std.debug.runtime_safety) {
                    if (self.root.unwrap()) |start| {
                        assert(start.get(es, Self).?.isAncestorOf(es, subtree), @src());
                    }
                }

                // Same up-walk as `next`'s next_sib seek,
                // but starting from `subtree` (not `pre`).
                var has_next_sib = subtree;
                while (has_next_sib.next_sib.unwrap() == null) {
                    if (has_next_sib.parent.unwrap().? == self.root.unwrap().?) {
                        self.curr = .none;
                        return;
                    }
                    has_next_sib = has_next_sib.getParent(es).?;
                }
                self.curr = has_next_sib.next_sib.unwrap().?.toOptional();
            }
        };

        /// Post-order traversal: visit descendants BEFORE
        /// the node itself (leftmost-deepest first, root
        /// last).  Use when child state must be torn down
        /// before parent's (destruction is the canonical
        /// example - that's why
        /// `destroyChildrenAndPluckImmediate` uses it).
        pub fn postOrderIterator(
            self: *const @This(),
            es: *const Registry,
            options: PostOrderIterator.Options,
        ) PostOrderIterator {
            const view: View = .{
                .entity = es.getEntity(self),
                // Safe @constCast: original storage is
                // mutable, we just don't want to define a
                // separate const-flavored View for this
                // internal-only path.
                .node = @constCast(self),
            };
            return .{
                .curr = leftmostLeafEntity(es, view, .{ .active_only = options.active_only }),
                .root = view.entity.toOptional(),
                .include_root = options.include_root,
                .active_only = options.active_only,
            };
        }

        /// Post-order traversal state.  Cursor starts at the
        /// leftmost-deepest leaf and works back up.
        pub const PostOrderIterator = struct {
            curr: Entity.Optional,
            root: Entity.Optional,
            include_root: bool,
            active_only: bool,

            /// Yields nothing.
            pub const empty: @This() = .{
                .curr = .none,
                .root = .none,
                .active_only = false,
                .include_root = false,
            };

            pub const Options = struct {
                include_root: bool = false,
                active_only: bool = false,
            };

            /// Step to the next View in post-order.
            /// Algorithm: at root, end (or yield root once
            /// per include_root).  Otherwise, descend the
            /// next_sib's leftmost-leaf; if no next_sib,
            /// climb to the parent (which becomes the next
            /// visit).
            pub fn next(self: *@This(), es: *const Registry) ?View {
                const post_entity: Entity = self.curr.unwrap() orelse return null;

                if (self.curr == self.root) {
                    if (self.include_root) {
                        self.curr = .none;
                        return post_entity.view(es, View).?;
                    } else {
                        return null;
                    }
                }

                const post: View = post_entity.view(es, View).?;
                if (post.getNextSib(es)) |next_sib| {
                    // Descend: leftmost leaf of right sibling.
                    const ll = leftmostLeafView(es, next_sib, .{
                        .active_only = self.active_only,
                    });
                    self.curr = if (ll) |some| some.entity.toOptional() else .none;
                } else {
                    // Climb: parent is next.
                    self.curr = self.curr.unwrap().?.get(es, Self).?.parent.unwrap().?.toOptional();
                }

                return post;
            }
        };

        const LeftmostLeafOptions = struct { active_only: bool };

        /// Walk down `root`'s leftmost child chain to the
        /// deepest leaf.  When `active_only`, skips inactive
        /// children - falls back to the next active sibling
        /// on each level, returning the parent if no active
        /// child exists.
        fn leftmostLeafView(
            es: *const Registry,
            root: View,
            options: LeftmostLeafOptions,
        ) ?View {
            if (options.active_only and !root.node.active) {
                return null;
            }

            var result = root;
            while (result.getFirstChild(es)) |candidate| {
                if (options.active_only) {
                    var sibling = candidate;
                    result = while (true) {
                        if (sibling.node.active) {
                            break sibling;
                        }
                        sibling = sibling.getNextSib(es) orelse return result;
                    } else return result;
                } else {
                    result = candidate;
                }
            }
            return result;
        }

        /// `leftmostLeafView` returning the entity handle.
        fn leftmostLeafEntity(
            es: *const Registry,
            root: View,
            options: LeftmostLeafOptions,
        ) Entity.Optional {
            const view: ?View = leftmostLeafView(es, root, options);
            return if (view) |v| v.entity.toOptional() else .none;
        }

        /// Encodes a command that requests to parent `child` and `parent`.
        /// * If the relationship would result in a cycle, parent and child are equal, or child no
        ///   longer exists, then no change is made.
        /// * If parent is `.none`, child is unparented.
        /// * If parent no longer exists, child is destroyed.
        pub const SetParent = struct {
            child: Entity,
            parent: Entity.Optional,
        };

        /// Encodes a command that requests to insert self relative to other.
        /// * If the relationship would result in a cycle, self and other are equal, or self no
        ///   longer exists, then no change is made.
        /// * If other no longer exists, self is destroyed.
        pub const Insert = struct {
            pub const Position = union(enum) {
                before: Entity,
                after: Entity,

                /// Pull the anchor entity out of the union
                /// (the one we're inserting relative to).
                pub fn entity(self: @This()) Entity {
                    return switch (self) {
                        .before => |e| e,
                        .after => |e| e,
                    };
                }
            };

            entity: Entity,
            position: Position,
        };

        /// CmdBuf integration for tree maintenance.  Sit
        /// `Node.Exec` in place of `CmdBuf.Exec` to get
        /// automatic tree wiring on add/remove/destroy of
        /// node components, plus deferred SetParent / Insert
        /// command handling.
        /// The tree mutations split across two hooks so other
        /// extension `Exec`s can compose: `beforeArchChangeImmediate`
        /// (clean up node state about to be invalidated) and
        /// `afterArchChangeImmediate` (init freshly-added nodes).
        /// This means `Node.Exec` calls into only the stable
        /// public ECS API - you can use these methods directly,
        /// or fork them as a starting point for your own
        /// CmdBuf executor.
        pub const Exec = struct {
            /// Drive the buffer to completion, applying all
            /// queued commands and maintaining the tree as a
            /// side effect.  Call once per frame after
            /// queueing this frame's commands.
            /// Invalidates pointers.
            pub fn immediate(
                es: *Registry,
                gpa: Allocator,
                cb: *CmdBuf,
                tr: *Tree,
            ) void {
                immediateOrErr(es, gpa, cb, tr) catch |err|
                    @panic(@errorName(err));
            }

            /// Like `immediate` but surfaces overflow / OOM as
            /// an error union.  On error the buffer is left
            /// partially evaluated - see `CmdBuf` doc on
            /// "undefined state on error".
            /// Invalidates pointers.
            pub fn immediateOrErr(
                es: *Registry,
                gpa: Allocator,
                cb: *CmdBuf,
                tr: *Tree,
            ) error{
                OutOfMemory,
                EcsArchOverflow,
                EcsChunkOverflow,
                EcsChunkPoolOverflow,
                EcsCompTypeOverflow,
                EcsEntityOverflow,
            }!void {
                var default_exec: CmdBuf.Exec = .init();

                es.pointer_generation.increment();

                var batches = cb.iterator();
                while (batches.next()) |batch| {
                    switch (batch) {
                        .arch_change => |arch_change| {
                            // Walk ops twice so we can hook
                            // before AND after each one.  The
                            // first walk also builds the delta
                            // we need to drive the actual
                            // arch transition.
                            {
                                var delta: CmdBuf.Batch.ArchChange.Delta = .{};
                                var ops = arch_change.iterator();
                                while (ops.next()) |op| {
                                    beforeArchChangeImmediate(es, tr, arch_change, delta, op);
                                    try delta.updateImmediate(es, gpa, op);
                                }
                                _ = try arch_change.execImmediateOrErr(es, delta);
                            }

                            {
                                var ops = arch_change.iterator();
                                while (ops.next()) |op| {
                                    afterArchChangeImmediate(es, tr, arch_change, op);
                                }
                            }
                        },
                        .ext => |ext| {
                            try extImmediateOrErr(es, gpa, tr, ext);
                            default_exec.extImmediateOrErr(ext);
                        },
                    }
                }

                try default_exec.finish(cb, es);
            }

            /// Handle SetParent / Insert extension commands.
            /// Other extension types pass through untouched
            /// caller layers them on with separate hooks.
            /// `gpa` covers `getOrAddImmediateOrErr`, which
            /// may register the Self component type with the
            /// world's flag table on first use.
            pub inline fn extImmediateOrErr(
                es: *Registry,
                gpa: Allocator,
                tr: *Tree,
                payload: Any,
            ) error{
                OutOfMemory,
                EcsArchOverflow,
                EcsChunkOverflow,
                EcsChunkPoolOverflow,
                EcsCompTypeOverflow,
            }!void {
                if (payload.as(SetParent)) |args| {
                    // Make sure the child entity has a node
                    // component (auto-add with defaults if
                    // absent), and that it's hooked into the
                    // tree as a fresh root.  Same for the
                    // parent if one was specified.
                    const child_node = try args.child.getOrAddImmediateOrErr(es, gpa, Self, .{});
                    if (child_node) |child| {
                        if (child.uninitialized(es, tr)) {
                            child.init(es, tr);
                        }
                    }

                    const parent_node = if (args.parent.unwrap()) |parent|
                        try parent.getOrAddImmediateOrErr(es, gpa, Self, .{})
                    else
                        null;
                    if (parent_node) |parent| {
                        if (parent.uninitialized(es, tr)) {
                            parent.init(es, tr);
                        }
                    }

                    // Wire up the relationship.  Three cases:
                    // (1) reparent under a real parent;
                    // (2) clear parent (caller passed .none);
                    // (3) caller passed a since-deleted
                    //     parent - kill the child too.
                    if (child_node) |child| {
                        if (parent_node) |parent| {
                            child.setParentImmediate(es, tr, parent);
                        } else if (args.parent.unwrap() == null) {
                            child.setParentImmediate(es, tr, null);
                        } else {
                            child.destroyImmediate(es, tr);
                        }
                    }
                } else if (payload.as(Insert)) |args| {
                    // Same auto-add+init shape as SetParent,
                    // for both the moved entity and the
                    // anchor entity.
                    const self_node = try args.entity.getOrAddImmediateOrErr(es, gpa, Self, .{});
                    if (self_node) |self| {
                        if (self.uninitialized(es, tr)) {
                            self.init(es, tr);
                        }
                    }

                    const other_node = try args.position.entity().getOrAddImmediateOrErr(
                        es,
                        gpa,
                        Self,
                        .{},
                    );
                    if (other_node) |other| {
                        if (other.uninitialized(es, tr)) {
                            other.init(es, tr);
                        }
                    }

                    if (self_node) |self| {
                        if (other_node) |other| {
                            self.insertImmediate(es, tr, std.meta.activeTag(args.position), other);
                        } else {
                            // Anchor was destroyed since
                            // command was queued - kill the
                            // moved entity instead of
                            // leaving it orphaned.
                            self.destroyImmediate(es, tr);
                        }
                    }
                }
            }

            /// Cleanup hook before a Self component leaves
            /// an entity (via destroy, remove, or overwrite).
            /// Plucks the node out of the tree and destroys
            /// its subtree.  Idempotent - safe to call when
            /// there's no node to clean up.
            pub fn beforeRemoveSelf(
                es: *Registry,
                tr: *Tree,
                entity: Entity,
                delta: CmdBuf.Batch.ArchChange.Delta,
            ) void {
                const comp_flag: CompFlag = es.getCompFlag(typeId(Self)) orelse {
                    // Self never registered - nothing to do.
                    return;
                };
                if (delta.remove.contains(comp_flag)) {
                    // Already being removed by the same delta.
                    return;
                }
                const node: *Self = entity.get(es, Self) orelse {
                    // Entity has no node, nothing to plumb.
                    return;
                };

                _ = node.destroyChildrenAndPluckImmediate(es, tr);
            }

            /// Pre-op hook: fires before each individual
            /// arch-change op runs.  We use it to clean up
            /// node state that's about to be invalidated
            /// destroy / remove-self / overwrite-self.
            pub inline fn beforeArchChangeImmediate(
                es: *Registry,
                tr: *Tree,
                arch_change: CmdBuf.Batch.ArchChange,
                delta: CmdBuf.Batch.ArchChange.Delta,
                op: CmdBuf.Batch.ArchChange.Op,
            ) void {
                switch (op) {
                    .destroy => {
                        beforeRemoveSelf(es, tr, arch_change.entity, delta);
                    },
                    .remove => |id| if (id == typeId(Self)) {
                        beforeRemoveSelf(es, tr, arch_change.entity, delta);
                    },
                    .add => |any| if (any.id == typeId(Self)) {
                        // Overwriting an existing node
                        // tear down the old one first.
                        beforeRemoveSelf(es, tr, arch_change.entity, delta);
                    },
                }
            }

            /// Post-op hook: fires after each individual
            /// arch-change op runs.  We use it to init nodes
            /// that just got added - they need to register
            /// themselves as a fresh root.
            pub inline fn afterArchChangeImmediate(
                es: *Registry,
                tr: *Tree,
                arch_change: CmdBuf.Batch.ArchChange,
                op: CmdBuf.Batch.ArchChange.Op,
            ) void {
                switch (op) {
                    .destroy => {},
                    .remove => {},
                    .add => |comp| if (comp.id == typeId(Self)) {
                        if (arch_change.entity.get(es, Self)) |node| {
                            if (node.uninitialized(es, tr)) {
                                node.init(es, tr);
                            }
                        }
                    },
                }
            }
        };
    };
}

/// The default Node specialization with `?[:0]const u8`
/// names.  Most code wants this - call `NodeWithOptions`
/// directly only if you need a different name type.
pub const Node = NodeWithOptions(.{ .Name = ?[:0]const u8 });

/// Marker component that classifies entities by *type at the
/// type level* - answers "what KIND of thing is this entity?"
/// without storing extra data.
/// Three ways to classify an entity, with their tradeoffs:
///   1. **Zero-sized struct per kind.**  `add(cb, Camera, .{})`,
///      `add(cb, Light, .{})` - works, but each kind becomes a
///      distinct component type, fragmenting archetypes.  Every
///      "Camera that's also a Light" gets its own chunk list.
///   2. **Enum field.**  `Kind = enum { camera, light, ... }`
///      no fragmentation, but enums aren't open to extension.
///      Downstream packages can't add new kinds without forking
///      the enum.
///   3. **`Tag(TypeId)`** (this type).  Stores a runtime TypeId
///      pointing to whatever marker type the user picked.  Open
///      to extension (any package can `Tag.init(MyKind)`), and
///      every Tag-carrying entity lives in one shared archetype
///      regardless of which kind it represents.
/// Pair with `findAncestorOf` for the common scenegraph query
/// "what's the nearest enclosing Camera?".
pub const Tag = struct {
    id: TypeId,

    /// Build a Tag from a marker type.  Pass an empty struct
    /// (`struct {}`) - only its identity matters.
    pub fn init(T: type) @This() {
        return .{ .id = typeId(T) };
    }

    /// Walk `node`'s ancestors and return the nearest one that
    /// carries a matching Tag, or `.none` if none do.
    /// Workhorse for "find the enclosing X" scenegraph queries.
    pub fn findAncestorOf(
        self: @This(),
        es: *const Registry,
        node: *Node,
    ) Entity.Optional {
        var ancestors: @TypeOf(node.ancestorIterator()) = node.ancestorIterator();
        while (ancestors.next(es)) |ancestor| {
            if (ancestor.entity.get(es, Tag)) |tag| {
                if (self.eql(tag.*)) {
                    return ancestor.entity.toOptional();
                }
            }
        }
        return .none;
    }

    /// True if `entity` carries a Tag matching `self`.  False
    /// for entities with no Tag, or with a Tag of a different
    /// kind.
    pub fn matches(
        self: @This(),
        es: *const Registry,
        entity: Entity,
    ) bool {
        const tag: *const Tag = entity.get(es, Tag) orelse return false;
        return self.eql(tag.*);
    }

    /// Tag equality = TypeId equality.  Don't try to fold this
    /// into a packed-struct bitwise compare - see
    /// https://github.com/ziglang/zig/issues/26044 for why
    /// packed-struct equality on this shape is unsafe.
    pub fn eql(lhs: @This(), rhs: @This()) bool {
        return lhs.id == rhs.id;
    }
};

/// Interface marker - a `fn (T: type) type` is a `GenericRef`
/// if the type it returns has a `Ctx` decl, plus `get` /
/// `getConst` methods with the canonical signatures
/// (validated by `checkGenericRef`).  Use this when you want
/// a system parameterized over different ref implementations
/// - e.g. `Ref` here, or a wrapper that adds invalidation
/// counters, or a test mock.
pub const GenericRef = fn (T: type) type;

/// Comptime check: does `F` look like a valid `GenericRef`?
/// Asserts the shape of `get` and `getConst` only.  Init
/// functions (`path`, `copy`, etc.) vary between
/// implementations and aren't part of the interface.
pub fn checkGenericRef(F: GenericRef) void {
    const DummyResult = struct {};
    const Get = @TypeOf(F(DummyResult).get);
    const GetConst = @TypeOf(F(DummyResult).getConst);
    comptime assert(Get == fn (*F(DummyResult), F(DummyResult).Ctx) ?*DummyResult, @src());
    comptime assert(GetConst == fn (*const F(DummyResult), F(DummyResult).Ctx) ?*const DummyResult, @src());
}

/// A typed reference into ECS-managed data.  Two flavors held
/// in one struct:
///   1. **Path ref** - points to a `T`-shaped sub-field at byte
///      `offset` inside component `loc` on entity `entity`.
///      Resurrected on each `get` by re-fetching the component
///      slice and adding the offset.  Survives chunk
///      compaction; goes null if the entity / component is
///      gone.
///   2. **Copy ref** - owns a `T` by value.  Useful when a
///      system accepts "T or a reference to T" as input - UI
///      sliders, animation curves, anything where the caller
///      sometimes wants a literal and sometimes wants a
///      live-tracking reference.  The discriminator is
///      `loc == typeId(CopyTag)`; that's why the `data` union
///      is untagged (we'd be paying for a tag bit we already
///      have).
/// See `GenericRef` if you want a system to be portable across
/// different Ref implementations (e.g. one with extra
/// invalidation tracking).
pub fn Ref(T: type) type {
    return struct {
        /// What gets passed to `get` - required by `GenericRef`.
        /// We need read-only ECS access to look up the
        /// component slice for path refs.
        pub const Ctx = *const Registry;

        /// Sentinel type used as `loc` when the data is held
        /// inline.  Has no instances; only its TypeId matters.
        pub const CopyTag = struct {};

        /// Either the component type we offset into, or
        /// `typeId(CopyTag)` to mean "data is inline".
        loc: TypeId,
        data: union {
            path: struct {
                /// Entity carrying the component we resolve into.
                entity: Entity,
                /// Byte offset into that component, pointing at
                /// the `T`-shaped sub-field.
                offset: usize,
            },
            copy: T,
        },

        /// Build a path ref at `Comp.<p>` on `e`.  `p` is a
        /// dot-path string passed to `meta.offsetOf`
        /// `"end.x"` walks `Comp.end` (a sub-struct), then
        /// `.x` (a field of that sub-struct).
        pub fn path(
            e: Entity,
            Comp: type,
            comptime p: []const u8,
        ) @This() {
            return .{
                .loc = typeId(Comp),
                .data = .{ .path = .{
                    .entity = e,
                    .offset = meta.offsetOf(Comp, p),
                } },
            };
        }

        /// Build a copy ref holding `value` inline.
        pub fn copy(value: T) @This() {
            return .{
                .loc = typeId(CopyTag),
                .data = .{ .copy = value },
            };
        }

        /// Resolve to a mutable pointer.  Returns `null` if
        /// this is a path ref and the entity / component is
        /// gone.  Copy refs always succeed - pointer is into
        /// the ref's own storage, so it's only valid as long
        /// as `self` is.
        pub fn get(self: *@This(), es: *const Registry) ?*T {
            return @constCast(self.getConst(es));
        }

        /// Read-only sibling of `get`.  Same lookup, same
        /// failure mode.
        pub fn getConst(self: *const @This(), es: *const Registry) ?*const T {
            if (self.loc == typeId(CopyTag)) {
                return &self.data.copy;
            }
            const comp: []const u8 = self.data.path.entity.getId(es, self.loc) orelse return null;
            assert(self.data.path.offset + @sizeOf(T) <= comp.len, @src());
            return @ptrFromInt(@intFromPtr(comp.ptr) + self.data.path.offset);
        }
    };
}

comptime {
    checkGenericRef(Ref);
}

test "ref" {
    // A two-vec component used to exercise both path-into-flat
    // (Point.y) and path-into-nested (Line.end.x) refs.  Named
    // `Point` (not Vec2) because `@Vector(2, f32)` doesn't have
    // named fields; the `.path` / @offsetOf reflection here
    // requires a real struct.  Codebase-wide ban on
    // `struct { x, y }` Vec2 aliases (turn 350) excepts these
    // intentional struct-field-semantics uses.
    const Point = struct { x: f32, y: f32 };
    const Line = struct { start: Point, end: Point };

    var es: Registry = try .init(.{
        .gpa = std.testing.allocator,
    });
    defer es.deinit(std.testing.allocator);

    var cb: CmdBuf = try .init(.{
        .name = null,
        .gpa = std.testing.allocator,
        .es = &es,
    });
    defer cb.deinit(std.testing.allocator, &es);

    // Build refs against an entity that doesn't have the
    // components yet - they should resolve to null.  This is
    // the "ref outlives target" semantic.
    const e: Entity = .reserve(&cb);
    var ry: Ref(f32) = .path(e, Point, "y");
    var rx: Ref(f32) = .path(e, Line, "end.x");
    var rc: Ref(f32) = .copy(123.456);

    // Commit the reservation but skip the component adds.
    try CmdBuf.Exec.immediateOrErr(&es, std.testing.allocator, &cb);
    cb.clear(&es);
    try expectEqual(null, ry.getConst(&es));
    try expectEqual(null, ry.get(&es));
    try expectEqual(null, rx.getConst(&es));
    try expectEqual(null, rx.get(&es));
    try expectEqual(123.456, rc.getConst(&es).?.*);
    try expectEqual(123.456, rc.get(&es).?.*);

    // Now add the components and verify the same refs resolve.
    _ = e.add(&cb, Point, .{ .x = 3.5, .y = 4.5 });
    _ = e.add(&cb, Line, .{
        .start = .{ .x = 5.5, .y = 6.5 },
        .end = .{ .x = 7.5, .y = 8.5 },
    });
    try CmdBuf.Exec.immediateOrErr(&es, std.testing.allocator, &cb);
    cb.clear(&es);
    try expectEqual(@as(f32, 4.5), ry.getConst(&es).?.*);
    try expectEqual(@as(f32, 4.5), ry.get(&es).?.*);
    try expectEqual(@as(f32, 7.5), rx.getConst(&es).?.*);
    try expectEqual(@as(f32, 7.5), rx.get(&es).?.*);
    try expectEqual(123.456, rc.getConst(&es).?.*);
    try expectEqual(123.456, rc.get(&es).?.*);
}

test {
    std.testing.refAllDecls(@This());
}
