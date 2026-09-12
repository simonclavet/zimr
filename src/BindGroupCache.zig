//! lint:alias BindGroupCache
// src/BindGroupCache.zig - bind group cache keyed by texture handle.
//
// In raylib-style 2D rendering, the same texture is drawn dozens or
// hundreds of times per frame.  Each draw needs a bind group that
// references the texture view + sampler.  Creating a bind group on
// every draw is wasteful — cache them by texture handle.
//
// Convention follows D6 (hierarchical bind groups):
//
//   - Group 0 — per-frame globals (view-projection, time, screen size).
//     One bind group per frame; created at `beginDrawing`.
//
//   - Group 1 — per-material (texture view + sampler + material UBO
//     if present).  Cached here, keyed by `(texture, sampler, ubo)`
//     tuple.  In the 2D fast path, sampler and UBO are constants, so
//     the key reduces to just the texture handle.
//
//   - Group 2 — per-draw (instance data, transform-not-in-storage).
//     Rare; not cached.
//
//   - Group 3 — storage buffers (compute, instanced).  Constructed
//     on shader load, lives for the shader's lifetime.
//
// This file caches Group 1 only.  Other groups are managed at their
// natural lifecycle level (Group 0 = per-frame, Group 3 = per-shader).

const std = @import("std");
const ArrayList = std.ArrayList;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const wgpu = @import("wgpu.zig");

/// The file *is* the BindGroupCache: `@import("BindGroupCache.zig")` gives this struct.
const BindGroupCache = @This();

/// Cache key for Group 1 bind groups.  For the simple 2D path where
/// the sampler + material UBO are fixed, only `texture` varies — but
/// we key on the full tuple so the cache is reusable for custom
/// pipelines too.
pub const Key = struct {
    texture_view: wgpu.TextureViewHandle,
    sampler: wgpu.SamplerHandle,
    material_ubo: wgpu.BufferHandle,
    layout: wgpu.BindGroupLayoutHandle,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h: u64 = 0xC0FFEE;
        h = std.hash.Wyhash.hash(h, std.mem.asBytes(&k.texture_view));
        h = std.hash.Wyhash.hash(h, std.mem.asBytes(&k.sampler));
        h = std.hash.Wyhash.hash(h, std.mem.asBytes(&k.material_ubo));
        h = std.hash.Wyhash.hash(h, std.mem.asBytes(&k.layout));
        return h;
    }
    pub fn eql(
        _: KeyContext,
        a: Key,
        b: Key,
    ) bool {
        return a.texture_view == b.texture_view and
            a.sampler == b.sampler and
            a.material_ubo == b.material_ubo and
            a.layout == b.layout;
    }
};

device: wgpu.DeviceHandle = .invalid,
gpa: Allocator,
entries: std.HashMapUnmanaged(Key, wgpu.BindGroupHandle, KeyContext, 80) = .{},

pub fn init(gpa: Allocator, device: wgpu.DeviceHandle) BindGroupCache {
    return .{ .device = device, .gpa = gpa };
}

pub fn deinit(self: *BindGroupCache) void {
    // Destroy every cached bind group before freeing the map storage — each key
    // maps to a distinct handle, so one destroy per value. Lets the shutdown
    // census reach zero instead of leaning on JS-side device release.
    var it: @TypeOf(self.entries).ValueIterator = self.entries.valueIterator();
    while (it.next()) |bg| {
        if (bg.* != .invalid) {
            wgpu.destroyBindGroup(bg.*);
        }
    }
    self.entries.deinit(self.gpa);
}

/// Get an existing entry or build + insert a new one.  The build
/// path (`buildFn`) is the caller's responsibility because the
/// exact bind group layout varies by use case (2D fast path vs
/// custom shader).
pub fn getOrBuild(
    self: *BindGroupCache,
    key: Key,
    ctx: anytype,
    comptime buildFn: fn (@TypeOf(ctx), Key) wgpu.BindGroupHandle,
) !wgpu.BindGroupHandle {
    if (self.entries.get(key)) |bg| {
        return bg;
    }
    const bg: wgpu.BindGroupHandle = buildFn(ctx, key);
    try self.entries.put(self.gpa, key, bg);
    return bg;
}

/// Drop the entry for a given key.  Called when a texture is
/// unloaded — the bind group references the texture view and
/// becomes invalid the moment the texture is destroyed.
pub fn invalidateForTexture(self: *BindGroupCache, tex_view: wgpu.TextureViewHandle) void {
    var to_remove: ArrayList(Key) = .empty;
    defer to_remove.deinit(self.gpa);

    var it: @TypeOf(self.entries).Iterator = self.entries.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.texture_view == tex_view) {
            to_remove.append(self.gpa, entry.key_ptr.*) catch break;
        }
    }
    for (to_remove.items) |k| {
        // TODO: release bind group JS-side when js_bind_group_release lands.
        _ = self.entries.remove(k);
    }
}

pub fn count(self: *const BindGroupCache) usize {
    return self.entries.count();
}

// ============================================================================
// Tests
// ============================================================================

test "BindGroupCache stores and retrieves entries" {
    var cache: BindGroupCache = .{ .gpa = std.testing.allocator };
    defer cache.deinit();

    const k1: Key = .{
        .texture_view = @fromBackingInt(@intCast(1)),
        .sampler = @fromBackingInt(@intCast(2)),
        .material_ubo = @fromBackingInt(@intCast(0)),
        .layout = @fromBackingInt(@intCast(3)),
    };
    try cache.entries.put(cache.gpa, k1, @fromBackingInt(@intCast(42)));
    try expectEqual(@as(usize, 1), cache.count());

    const found: ?wgpu.BindGroupHandle = cache.entries.get(k1);
    try expect(found != null);
    try expectEqual(@as(u32, 42), @backingInt(found.?));
}

test "invalidateForTexture removes only matching entries" {
    var cache: BindGroupCache = .{ .gpa = std.testing.allocator };
    defer cache.deinit();

    const tex_a: wgpu.TextureViewHandle = @fromBackingInt(@intCast(1));
    const tex_b: wgpu.TextureViewHandle = @fromBackingInt(@intCast(2));
    const sampler: wgpu.SamplerHandle = @fromBackingInt(@intCast(10));
    const layout: wgpu.BindGroupLayoutHandle = @fromBackingInt(@intCast(20));

    try cache.entries.put(cache.gpa, .{
        .texture_view = tex_a,
        .sampler = sampler,
        .material_ubo = @fromBackingInt(@intCast(0)),
        .layout = layout,
    }, @fromBackingInt(@intCast(100)));

    try cache.entries.put(cache.gpa, .{
        .texture_view = tex_b,
        .sampler = sampler,
        .material_ubo = @fromBackingInt(@intCast(0)),
        .layout = layout,
    }, @fromBackingInt(@intCast(200)));

    try expectEqual(@as(usize, 2), cache.count());
    cache.invalidateForTexture(tex_a);
    try expectEqual(@as(usize, 1), cache.count());
}
