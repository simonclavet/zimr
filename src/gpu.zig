//! lint:alias gpu
//! gpu.zig - zimr's WebGPU resource layer over the raw `wgpu` bindings. One
//! flat module (merged from pipeline_cache + descriptor_encoder + gpu_frame):
//!   - pipeline state caching: StateCombo / CacheKey / PipelineCache + hashers
//!   - descriptor encoding: RenderPipelineDescriptor / BindGroupEntry / Vertex* + encode*
//!   - per-frame GPU state: Backend / GpuFrame
//! BindGroupCache stays its own file-struct; this module imports it.

const std = @import("std");
const ArrayList = std.ArrayList;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const indexOf = std.mem.indexOf;
const asBytes = std.mem.asBytes;
const readInt = std.mem.readInt;
const writeInt = std.mem.writeInt;
const wgpu = @import("wgpu.zig");
const shader_introspect = @import("shader_introspect.zig");
const BindGroupCache = @import("BindGroupCache.zig");
const gpu_abi = @import("gpu_abi.zig");

// ============================ pipeline state cache ============================

/// Packed state-combination identifier.  Compared by value; cheap to
/// hash.  Every field of the pipeline state that affects WHICH
/// pipeline object WebGPU needs goes in here.
pub const StateCombo = packed struct(u64) {
    topology: u4 = @backingInt(wgpu.PrimitiveTopology.triangle_list),
    blend: u4 = @backingInt(wgpu.BlendMode.alpha),
    depth: u4 = @backingInt(wgpu.DepthMode.none),
    cull: u4 = @backingInt(wgpu.CullMode.none),
    color_format: u8 = @backingInt(wgpu.TextureFormat.rgba8_unorm),
    depth_format: u8 = @backingInt(wgpu.TextureFormat.undefined_),
    sample_count: u4 = 1,
    _pad: u28 = 0,

    pub fn fromParts(
        topology: wgpu.PrimitiveTopology,
        blend: wgpu.BlendMode,
        depth: wgpu.DepthMode,
        cull: wgpu.CullMode,
        color_format: wgpu.TextureFormat,
        depth_format: wgpu.TextureFormat,
        sample_count: u4,
    ) StateCombo {
        return .{
            .topology = @intCast(@backingInt(topology)),
            .blend = @intCast(@backingInt(blend)),
            .depth = @intCast(@backingInt(depth)),
            .cull = @intCast(@backingInt(cull)),
            .color_format = @intCast(@backingInt(color_format)),
            .depth_format = @intCast(@backingInt(depth_format)),
            .sample_count = sample_count,
        };
    }
};

pub const CacheKey = packed struct(u128) {
    source_hash: u64,
    state_combo: u64,

    pub fn from(source_hash: u64, state: StateCombo) CacheKey {
        return .{ .source_hash = source_hash, .state_combo = @bitCast(state) };
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: CacheKey) u64 {
        return std.hash.Wyhash.hash(0, asBytes(&k));
    }
    pub fn eql(
        _: KeyContext,
        a: CacheKey,
        b: CacheKey,
    ) bool {
        return @as(u128, @bitCast(a)) == @as(u128, @bitCast(b));
    }
};

pub const PipelineCache = struct {
    device: wgpu.DeviceHandle = .invalid,
    entries: std.HashMapUnmanaged(CacheKey, wgpu.RenderPipelineHandle, KeyContext, 80) = .{},
    gpa: Allocator,

    pub fn init(gpa: Allocator, device: wgpu.DeviceHandle) PipelineCache {
        return .{ .device = device, .gpa = gpa };
    }

    pub fn deinit(self: *PipelineCache) void {
        // Destroy every cached pipeline. Each CacheKey maps to a distinct pipeline
        // handle (dedup means a key HIT reuses the handle rather than creating a
        // new one), so a single destroy per value is exactly right. Previously
        // these were left for JS-side device release; destroying them explicitly
        // lets the create/destroy census return to zero at shutdown.
        var it: @TypeOf(self.entries).ValueIterator = self.entries.valueIterator();
        while (it.next()) |p| {
            if (p.* != .invalid) {
                wgpu.destroyRenderPipeline(p.*);
            }
        }
        self.entries.deinit(self.gpa);
    }

    /// Look up a pipeline by key.  Returns `null` if not cached.
    pub fn lookup(self: *const PipelineCache, key: CacheKey) ?wgpu.RenderPipelineHandle {
        return self.entries.get(key);
    }

    /// Insert a pre-built pipeline under `key`.  Caller owns the
    /// build - see `pipeline_builder.zig` (TODO, blocked on transpiler)
    /// for the build flow.
    pub fn put(
        self: *PipelineCache,
        key: CacheKey,
        pipeline: wgpu.RenderPipelineHandle,
    ) !void {
        try self.entries.put(self.gpa, key, pipeline);
    }

    /// Invalidate all entries for a given shader source.  Called on
    /// hot-reload when a shader file is edited; the new source has a
    /// new hash, so the OLD entries become orphans we should remove
    /// to free JS-side pipeline objects.
    pub fn invalidateSource(self: *PipelineCache, source_hash: u64) void {
        var to_remove: ArrayList(CacheKey) = .empty;
        defer to_remove.deinit(self.gpa);

        var it: @TypeOf(self.entries.iterator()) = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.source_hash == source_hash) {
                to_remove.append(self.gpa, entry.key_ptr.*) catch break;
            }
        }
        for (to_remove.items) |k| {
            // TODO: release pipeline JS-side when js_pipeline_release lands.
            _ = self.entries.remove(k);
        }
    }
};

// ============================================================================
// SECTION - pre-bake list
// ============================================================================

/// The 8 hot combos pre-baked at app init for the default 2D shader.
/// See D4 in `notes/MIGRATION_DECISIONS.md`.
pub fn hotCombos2D(color_format: wgpu.TextureFormat) [8]StateCombo {
    const color_fmt_u8: u8 = @intCast(@backingInt(color_format));
    // Local builder: every hot 2D combo shares the same color format
    // and differs only in (topology, blend).  Folding the repeated
    // `@intFromEnum(...)` boilerplate into one call keeps the table
    // readable and under the line-length limit.
    const S = struct {
        fn combo(
            topology: wgpu.PrimitiveTopology,
            blend: wgpu.BlendMode,
            color_fmt: u8,
        ) StateCombo {
            return .{
                .topology = @intCast(@backingInt(topology)),
                .blend = @intCast(@backingInt(blend)),
                .color_format = color_fmt,
            };
        }
    };
    return .{
        S.combo(.triangle_list, .alpha, color_fmt_u8),
        S.combo(.triangle_list, .additive, color_fmt_u8),
        S.combo(.triangle_list, .multiply, color_fmt_u8),
        S.combo(.triangle_list, .none, color_fmt_u8),
        S.combo(.line_list, .alpha, color_fmt_u8),
        S.combo(.line_list, .none, color_fmt_u8),
        S.combo(.triangle_strip, .alpha, color_fmt_u8),
        S.combo(.point_list, .alpha, color_fmt_u8),
    };
}

/// Hash a shader source string.  We use the first 8 bytes of sha256
/// truncated - collisions theoretically possible but practically
/// impossible in zimr's workload size.
pub fn hashSource(source: []const u8) u64 {
    return std.hash.Wyhash.hash(0xC0FFEE, source);
}

/// Hash a (VS, FS) pair into a single u64 cache key.  Used by the
/// shader runtime to dedup render pipelines: two consumers using
/// the SAME (vs, fs) pair share a cached pipeline; two consumers
/// using different VS or different FS get distinct entries.
pub fn hashSource2(vs_source: []const u8, fs_source: []const u8) u64 {
    var hasher: std.hash.Wyhash = .init(0xC0FFEE);
    hasher.update(vs_source);
    // Separator byte so concat(A,B) != concat(A',B') when A|B overlap.
    hasher.update(&[1]u8{0});
    hasher.update(fs_source);
    return hasher.final();
}

// ============================================================================
// Tests
// ============================================================================

test "StateCombo fits in u64" {
    try expectEqual(@as(usize, 8), @sizeOf(StateCombo));
}

test "CacheKey fits in u128" {
    try expectEqual(@as(usize, 16), @sizeOf(CacheKey));
}

test "hashSource is deterministic" {
    const a: u64 = hashSource("foo");
    const b: u64 = hashSource("foo");
    const c: u64 = hashSource("bar");
    try expectEqual(a, b);
    try expect(a != c);
}

test "invalidateSource removes only matching entries" {
    var cache: PipelineCache = .{ .gpa = testing_allocator };
    defer cache.deinit();

    const shader_a: u64 = 0xAAAA_AAAA_AAAA_AAAA;
    const shader_b: u64 = 0xBBBB_BBBB_BBBB_BBBB;
    const state: StateCombo = .{};

    try cache.put(CacheKey.from(shader_a, state), @fromBackingInt(@intCast(1)));
    try cache.put(CacheKey.from(shader_b, state), @fromBackingInt(@intCast(2)));

    try expectEqual(@as(usize, 2), cache.entries.count());
    cache.invalidateSource(shader_a);
    try expectEqual(@as(usize, 1), cache.entries.count());
    try expect(cache.lookup(CacheKey.from(shader_b, state)) != null);
}

// ============================= descriptor encoding ============================

// ============================================================================
// Primitive writers - the little-endian byte writers every encoder below uses
// ============================================================================

//
// Format (per entry):
//   u32 binding
//   u32 visibility (ShaderStage bits packed as u32)
//   u32 type_tag  (0=uniform 1=storage_ro 2=storage_rw
//                  3=sampler 4=texture 5=storage_texture)
//   u32 extra     (type-specific data; see below)
//
// Header: u32 entry_count

fn writeU32(
    gpa: Allocator,
    buf: *ArrayList(u8),
    v: u32,
) !void {
    var bytes: [4]u8 = undefined;
    writeInt(u32, &bytes, v, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn writeF64(
    gpa: Allocator,
    buf: *ArrayList(u8),
    v: f64,
) !void {
    var bytes: [8]u8 = undefined;
    writeInt(u64, &bytes, @bitCast(v), .little);
    try buf.appendSlice(gpa, &bytes);
}

fn writeU64(
    gpa: Allocator,
    buf: *ArrayList(u8),
    v: u64,
) !void {
    var bytes: [8]u8 = undefined;
    writeInt(u64, &bytes, v, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn writeStr(
    gpa: Allocator,
    buf: *ArrayList(u8),
    s: []const u8,
) !void {
    try writeU32(gpa, buf, @intCast(s.len));
    try buf.appendSlice(gpa, s);
}

// ============================================================================
// SECTION 1 - bind group layout entries
// ============================================================================

pub fn encodeBindGroupLayoutEntries(
    gpa: Allocator,
    entries: []const shader_introspect.BindGroupLayoutEntry,
) ![]u8 {
    var buf: ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try writeU32(gpa, &buf, @intCast(entries.len));
    for (entries) |e| {
        try writeU32(gpa, &buf, e.binding);
        try writeU32(gpa, &buf, @bitCast(e.visibility));
        const tag: u32 = switch (e.resource) {
            .uniform_buffer => 0,
            .storage_buffer => |sb| @as(u32, if (sb.read_only) 1 else 2),
            .sampler => 3,
            .texture => 4,
            .storage_texture => 5,
        };
        try writeU32(gpa, &buf, tag);
        const extra: u32 = switch (e.resource) {
            .uniform_buffer => |ub| @intCast(ub.min_size),
            .storage_buffer => |sb| @intCast(sb.min_size),
            .sampler => |s| @as(u32, if (s.filtering) 0 else 1),
            .texture => 0,
            .storage_texture => 0,
        };
        try writeU32(gpa, &buf, extra);
        const view_dim: u32 = switch (e.resource) {
            .texture => |t| @backingInt(t.view_dimension),
            .storage_texture => |st| @backingInt(st.view_dimension),
            else => 0,
        };
        try writeU32(gpa, &buf, view_dim);
    }
    return buf.toOwnedSlice(gpa);
}

// ============================================================================
// SECTION 2 - bind group entries (resource bindings)
// ============================================================================

//
// Format (per entry):
//   u32 binding
//   u32 resource_type (0=buffer 1=sampler 2=texture_view)
//   u32 resource_handle
//   u64 offset (buffer only; 0 otherwise)
//   u64 size   (buffer only; 0 = whole buffer)
//
// Header: u32 entry_count

pub const BindGroupEntry = struct {
    binding: u32,
    resource: Resource,

    pub const Resource = union(enum) {
        buffer: struct { handle: wgpu.BufferHandle, offset: u64 = 0, size: u64 = 0 },
        sampler: wgpu.SamplerHandle,
        texture_view: wgpu.TextureViewHandle,
    };
};

/// A bind-group layout holding ONE uniform buffer at binding 0 - the overwhelmingly common
/// case for a custom pipeline's per-stage uniforms.
///
/// * THIS EXACT HELPER WAS COPIED INTO TWELVE EXAMPLES before it lived here (`shadowmap`,
/// `deferred_render`, `cel_shading`, `fog_rendering`, `mesh_picking`, `geno_dance`, ...). It is
/// not example scaffolding - it is what every hand-built pipeline needs before it can bind
/// anything, and twelve copies is twelve chances for one of them to drift.
pub fn uniformBindGroupLayout(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    min_size: u64,
    visibility: wgpu.ShaderStage,
    label: []const u8,
) !wgpu.BindGroupLayoutHandle {
    const entries = [_]shader_introspect.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = visibility,
            .resource = .{ .uniform_buffer = .{ .min_size = min_size } },
        },
    };
    const blob: []const u8 = try encodeBindGroupLayoutEntries(gpa, &entries);
    defer gpa.free(blob);
    return wgpu.createBindGroupLayout(device, blob, label);
}

pub fn encodeBindGroupEntries(
    gpa: Allocator,
    entries: []const BindGroupEntry,
) ![]u8 {
    var buf: ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try writeU32(gpa, &buf, @intCast(entries.len));
    for (entries) |e| {
        try writeU32(gpa, &buf, e.binding);
        switch (e.resource) {
            .buffer => |b| {
                try writeU32(gpa, &buf, 0);
                try writeU32(gpa, &buf, @backingInt(b.handle));
                try writeU64(gpa, &buf, b.offset);
                try writeU64(gpa, &buf, b.size);
            },
            .sampler => |s| {
                try writeU32(gpa, &buf, 1);
                try writeU32(gpa, &buf, @backingInt(s));
                try writeU64(gpa, &buf, 0);
                try writeU64(gpa, &buf, 0);
            },
            .texture_view => |tv| {
                try writeU32(gpa, &buf, 2);
                try writeU32(gpa, &buf, @backingInt(tv));
                try writeU64(gpa, &buf, 0);
                try writeU64(gpa, &buf, 0);
            },
        }
    }
    return buf.toOwnedSlice(gpa);
}

/// The matching bind group: one uniform buffer bound at 0.
pub fn uniformBindGroup(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    layout: wgpu.BindGroupLayoutHandle,
    buffer: wgpu.BufferHandle,
    size: u64,
    label: []const u8,
) !wgpu.BindGroupHandle {
    const entries = [_]BindGroupEntry{
        .{
            .binding = 0,
            .resource = .{ .buffer = .{ .handle = buffer, .offset = 0, .size = size } },
        },
    };
    const blob: []const u8 = try encodeBindGroupEntries(gpa, &entries);
    defer gpa.free(blob);
    return wgpu.createBindGroup(device, layout, blob, label);
}

// ============================================================================
// SECTION 3 - render pipeline descriptor
// ============================================================================

//
// Format:
//   u32 vertex_buffer_layouts_count
//   per VBL:
//     u32 array_stride
//     u32 step_mode  (0=vertex 1=instance)
//     u32 attrs_count
//     per attr:
//       u32 format (VertexFormat enum index)
//       u32 offset
//       u32 shader_location
//   u32 vs_entry_len; bytes vs_entry (no null terminator)
//   u32 fs_entry_len; bytes fs_entry
//   u32 topology
//   u32 cull_mode
//   u32 blend_mode
//   u32 depth_mode
//   u32 color_format
//   u32 depth_format
//   u32 sample_count

pub const VertexAttribute = struct {
    format: wgpu.VertexFormat,
    offset: u32,
    shader_location: u32,
};

pub const VertexBufferLayout = struct {
    array_stride: u32,
    step_mode: wgpu.VertexStepMode = .vertex,
    attributes: []const VertexAttribute,
};

/// One pipeline-overridable constant: the WGSL `override` name and its value.
pub const PipelineConstant = struct {
    name: []const u8,
    value: f64,
};

pub const RenderPipelineDescriptor = struct {
    vertex_buffer_layouts: []const VertexBufferLayout = &.{},
    vs_entry_point: []const u8 = "vs_main",
    fs_entry_point: []const u8 = "fs_main",
    state: StateCombo = .{},
    /// WGSL pipeline-overridable constants set at creation (raygpu `override`).
    /// Applied to both the vertex and fragment stage.
    constants: []const PipelineConstant = &.{},
    /// MRT: color-target formats for fragment output locations 1..N -
    /// location 0 stays `state.color_format` (with the StateCombo's blend);
    /// the extras are created blend-free, which is what a G-buffer wants
    /// (blending world positions would be nonsense).  Empty = the classic
    /// single-target pipeline, byte-identical blob to before.
    extra_color_formats: []const wgpu.TextureFormat = &.{},
};

pub fn encodeRenderPipelineDescriptor(
    gpa: Allocator,
    desc: RenderPipelineDescriptor,
) ![]u8 {
    var buf: ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try writeU32(gpa, &buf, @intCast(desc.vertex_buffer_layouts.len));
    for (desc.vertex_buffer_layouts) |vbl| {
        try writeU32(gpa, &buf, vbl.array_stride);
        try writeU32(gpa, &buf, @backingInt(vbl.step_mode));
        try writeU32(gpa, &buf, @intCast(vbl.attributes.len));
        for (vbl.attributes) |attr| {
            try writeU32(gpa, &buf, @backingInt(attr.format));
            try writeU32(gpa, &buf, attr.offset);
            try writeU32(gpa, &buf, attr.shader_location);
        }
    }
    try writeStr(gpa, &buf, desc.vs_entry_point);
    try writeStr(gpa, &buf, desc.fs_entry_point);
    try writeU32(gpa, &buf, desc.state.topology);
    try writeU32(gpa, &buf, desc.state.cull);
    try writeU32(gpa, &buf, desc.state.blend);
    try writeU32(gpa, &buf, desc.state.depth);
    try writeU32(gpa, &buf, desc.state.color_format);
    try writeU32(gpa, &buf, desc.state.depth_format);
    try writeU32(gpa, &buf, desc.state.sample_count);
    // Depth compare + write resolved HERE from the typed DepthMode (its
    // exhaustive depthCompare()/writesDepth()), baked into the blob so the JS
    // bridge consumes them directly and never re-derives depth semantics from a
    // raw int. See wgpu.DepthMode: adding a mode is a compile error until both
    // are stated, so a passive mode can't silently end up writing depth again.
    const depth_mode: wgpu.DepthMode = @fromBackingInt(@intCast(desc.state.depth));
    try writeStr(gpa, &buf, depth_mode.depthCompare());
    try writeU32(gpa, &buf, @intFromBool(depth_mode.writesDepth()));

    try writeU32(gpa, &buf, @intCast(desc.constants.len));
    for (desc.constants) |k| {
        try writeStr(gpa, &buf, k.name);
        try writeF64(gpa, &buf, k.value);
    }

    // MRT tail: extra color-target formats for locations 1..N (0 = none -
    // the classic single-target pipeline).  Kept LAST so the blob stays a
    // strict prefix-extension of the old layout.
    try writeU32(gpa, &buf, @intCast(desc.extra_color_formats.len));
    for (desc.extra_color_formats) |fmt| {
        try writeU32(gpa, &buf, @backingInt(fmt));
    }

    return buf.toOwnedSlice(gpa);
}

// ============================================================================
// Tests
// ============================================================================

test "encodeBindGroupLayoutEntries emits expected bytes for a UBO entry" {
    const entries: []const shader_introspect.BindGroupLayoutEntry = &.{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true, .fragment = true },
            .resource = .{ .uniform_buffer = .{ .min_size = 16 } },
        },
    };
    const bytes: []const u8 = try encodeBindGroupLayoutEntries(testing_allocator, entries);
    defer testing_allocator.free(bytes);

    // 4 (count) + 4 (binding) + 4 (visibility) + 4 (type_tag) + 4 (extra)
    //   + 4 (view_dim) = 24
    try expectEqual(@as(usize, 24), bytes.len);
    // count = 1
    try expectEqual(@as(u32, 1), readInt(u32, bytes[0..4], .little));
    // binding = 0
    try expectEqual(@as(u32, 0), readInt(u32, bytes[4..8], .little));
    // type_tag = 0 (uniform)
    try expectEqual(@as(u32, 0), readInt(u32, bytes[12..16], .little));
    // extra = 16
    try expectEqual(@as(u32, 16), readInt(u32, bytes[16..20], .little));
    // view_dim = 0 (unused for a buffer entry)
    try expectEqual(@as(u32, 0), readInt(u32, bytes[20..24], .little));
}

test "encodeBindGroupEntries handles mixed resource types" {
    const entries: []const BindGroupEntry = &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = @fromBackingInt(@intCast(42)), .size = 256 } } },
        .{ .binding = 1, .resource = .{ .sampler = @fromBackingInt(@intCast(7)) } },
        .{ .binding = 2, .resource = .{ .texture_view = @fromBackingInt(@intCast(99)) } },
    };
    const bytes: []const u8 = try encodeBindGroupEntries(testing_allocator, entries);
    defer testing_allocator.free(bytes);

    // 4 (count) + 3 x (4+4+4+8+8) = 4 + 84 = 88
    try expectEqual(@as(usize, 88), bytes.len);
    try expectEqual(@as(u32, 3), readInt(u32, bytes[0..4], .little));
    // First entry: binding=0, type=0 (buffer), handle=42, offset=0, size=256
    try expectEqual(@as(u32, 0), readInt(u32, bytes[4..8], .little));
    try expectEqual(@as(u32, 0), readInt(u32, bytes[8..12], .little));
    try expectEqual(@as(u32, 42), readInt(u32, bytes[12..16], .little));
    try expectEqual(@as(u64, 256), readInt(u64, bytes[24..32], .little));
}

test "encodeRenderPipelineDescriptor round-trips entry-point strings" {
    const desc = RenderPipelineDescriptor{
        .vertex_buffer_layouts = &.{
            .{
                .array_stride = 20,
                .step_mode = .vertex,
                .attributes = &.{
                    .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
                    .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
                    .{ .format = .uint8x4_unorm, .offset = 16, .shader_location = 2 },
                },
            },
        },
        .vs_entry_point = "main_vs",
        .fs_entry_point = "main_fs",
    };
    const bytes: []const u8 = try encodeRenderPipelineDescriptor(testing_allocator, desc);
    defer testing_allocator.free(bytes);

    // Header should contain VBL count = 1
    try expectEqual(@as(u32, 1), readInt(u32, bytes[0..4], .little));
    // Entry-point strings should appear in the blob
    const idx = indexOf(u8, bytes, "main_vs");
    try expect(idx != null);
    try expect(indexOf(u8, bytes, "main_fs") != null);
}

test "encodeRenderPipelineDescriptor appends pipeline-overridable constants" {
    const desc = RenderPipelineDescriptor{
        .vs_entry_point = "vs",
        .fs_entry_point = "fs",
        .constants = &.{
            .{ .name = "scl", .value = 0.5 },
            .{ .name = "tint_r", .value = 1.0 },
        },
    };
    const bytes: []const u8 = try encodeRenderPipelineDescriptor(testing_allocator, desc);
    defer testing_allocator.free(bytes);

    // Names appear, and a trailing f64 0.5 (little-endian bits) is present.
    try expect(indexOf(u8, bytes, "scl") != null);
    try expect(indexOf(u8, bytes, "tint_r") != null);
    const half_bits: u64 = @bitCast(@as(f64, 0.5));
    var half_le: [8]u8 = undefined;
    writeInt(u64, &half_le, half_bits, .little);
    try expect(indexOf(u8, bytes, &half_le) != null);
}

test "encodeRenderPipelineDescriptor appends the MRT extra-target tail" {
    const desc = RenderPipelineDescriptor{
        .vs_entry_point = "vs",
        .fs_entry_point = "fs",
        .extra_color_formats = &.{ .rgba16_float, .rgba8_unorm },
    };
    const bytes: []const u8 = try encodeRenderPipelineDescriptor(testing_allocator, desc);
    defer testing_allocator.free(bytes);

    // The tail is count + N formats, LAST in the blob (the bridge decoder
    // reads it after the constants block).  Pin it byte-for-byte so a
    // reordering on either side fails here, not on a black screen.
    const tail: []const u8 = bytes[bytes.len - 12 ..];
    try expectEqual(@as(u32, 2), readInt(u32, tail[0..4], .little));
    try expectEqual(
        @as(u32, @backingInt(wgpu.TextureFormat.rgba16_float)),
        readInt(u32, tail[4..8], .little),
    );
    try expectEqual(
        @as(u32, @backingInt(wgpu.TextureFormat.rgba8_unorm)),
        readInt(u32, tail[8..12], .little),
    );
}

// ============================== per-frame GPU state ===========================

/// Tag identifying which backend is active.  Used by
/// `if (f.gpu.backend == .wgpu) { ... }` gates in user code that opts
/// out of software-renderer compatibility.
pub const Backend = enum(u8) { wgpu, sw };

pub const GpuFrame = struct {
    // ------------------------------------------------------------------
    // LONG-LIVED - lifetime = app
    // ------------------------------------------------------------------
    backend: Backend = .wgpu,
    device: wgpu.DeviceHandle = .invalid,
    queue: wgpu.QueueHandle = .invalid,
    surface: wgpu.SurfaceHandle = .invalid,
    backbuffer_format: wgpu.TextureFormat = .undefined_,
    depth_format: ?wgpu.TextureFormat = null,

    // Depth attachment, OWNED by the frame. Created lazily on the first
    // beginFrame (when depth_format != null) and auto-resized whenever the
    // surface size changes. WebGPU requires the depth attachment to match the
    // color (surface) attachment's size exactly -- a mismatch makes it drop
    // the entire render pass -- so the only robust place to own the depth
    // texture is here, re-checked against the live surface each frame.
    // (Same pattern as raygpu's backend_wgpu.c GetNewTexture.)
    depth_texture: wgpu.TextureHandle = .invalid,
    depth_view: wgpu.TextureViewHandle = .invalid,
    depth_width: u32 = 0,
    depth_height: u32 = 0,

    pipeline_cache: ?*PipelineCache = null,
    bind_group_cache: ?*BindGroupCache = null,

    // ------------------------------------------------------------------
    // PER-FRAME TRANSIENT - lifetime = current frame
    // ------------------------------------------------------------------
    //
    // These are written by `WgpuBackend.beginFrame` AND ALSO returned
    // from it as a `FrameContext` value the caller threads explicitly.
    // The struct fields are kept as a convenience shortcut for older
    // call sites; new code should use the returned value.
    surface_view: wgpu.TextureViewHandle = .invalid,
    encoder: wgpu.CommandEncoderHandle = .invalid,

    // ------------------------------------------------------------------
    // OPTIONAL - software renderer backend
    // ------------------------------------------------------------------
    /// When `backend == .sw`, this points at the software rasterizer
    /// context.  When `backend == .wgpu`, this is `null`.  The type
    /// is `*anyopaque` to avoid a circular dependency with `raster.zig`;
    /// the SW path knows its real type.
    sw_ctx: ?*anyopaque = null,

    /// Initialise a fresh GpuFrame.  Caller provides the long-lived
    /// resources (device, queue, surface, caches).  Per-frame
    /// transients (encoder, surface_view) stay at their default
    /// invalid handles until `beginFrame` populates them.
    pub fn init(
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        surface: wgpu.SurfaceHandle,
        backbuffer_format: wgpu.TextureFormat,
        pc: *PipelineCache,
        bgc: *BindGroupCache,
    ) GpuFrame {
        return .{
            .device = device,
            .queue = queue,
            .surface = surface,
            .backbuffer_format = backbuffer_format,
            .pipeline_cache = pc,
            .bind_group_cache = bgc,
        };
    }

    /// Ensure the owned depth texture exists and matches the current surface
    /// size. Called by `beginFrame` before opening the render pass. No-op when
    /// `depth_format == null` (a depth-less 2D pass). Recreates the depth
    /// texture (and its view) whenever the surface has resized since last frame,
    /// which is also how canvas resize is handled for the depth attachment.
    pub fn ensureDepth(self: *GpuFrame) void {
        const format: wgpu.TextureFormat = self.depth_format orelse return;
        const size: wgpu.SurfaceSize = wgpu.getSurfaceSize(self.surface);
        if (size.width == 0 or size.height == 0) {
            return;
        }
        const is_match: bool = self.depth_texture != .invalid and
            self.depth_width == size.width and self.depth_height == size.height;
        if (is_match) {
            return;
        }
        // Size changed (or first frame): drop the old depth view and texture and
        // make new ones matching the surface.
        if (self.depth_view != .invalid) {
            wgpu.destroyTextureView(self.depth_view);
            self.depth_view = .invalid;
        }
        if (self.depth_texture != .invalid) {
            wgpu.destroyTexture(self.depth_texture);
        }
        self.depth_texture = wgpu.createTexture(self.device, .{
            .width = size.width,
            .height = size.height,
            .format = format,
            .usage = .{ .render_attachment = true },
            .label = "gpu_frame_depth",
        });
        self.depth_view = wgpu.createTextureView(self.depth_texture);
        self.depth_width = size.width;
        self.depth_height = size.height;
    }

    /// Reset all per-frame transient state.  Called at frame
    /// boundary.  Does NOT free long-lived resources.
    pub fn resetFrameState(self: *GpuFrame) void {
        self.surface_view = .invalid;
        self.encoder = .invalid;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GpuFrame default-initialises to safe state" {
    const gf: GpuFrame = .{};
    try expectEqual(Backend.wgpu, gf.backend);
    try expectEqual(wgpu.DeviceHandle.invalid, gf.device);
    try expectEqual(wgpu.CommandEncoderHandle.invalid, gf.encoder);
    try expectEqual(@as(?*anyopaque, null), gf.sw_ctx);
}

// ============================================================================
// The encoders against gpu_abi's decoders: what `gpu.zig` writes is what the Vulkan host reads.
// ============================================================================

test "gpu_abi round trip: shader_introspect's view dimensions are numbered as gpu_abi's" {
    const ViewDimension = shader_introspect.BindGroupLayoutEntry.ViewDimension;
    inline for (@typeInfo(ViewDimension).@"enum".field_names) |name| {
        const abi_value: u32 = @backingInt(@field(gpu_abi.TextureViewDimension, name));
        try expectEqual(abi_value, @backingInt(@field(ViewDimension, name)));
    }
}

test "gpu_abi round trip: every bind-group layout entry kind decodes to what was encoded" {
    const gpa: Allocator = testing_allocator;
    const entries = [_]shader_introspect.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true, .fragment = true },
            .resource = .{ .uniform_buffer = .{ .min_size = 64 } },
        },
        .{
            .binding = 1,
            .visibility = .{ .compute = true },
            .resource = .{ .storage_buffer = .{ .read_only = true, .min_size = 16 } },
        },
        .{ .binding = 2, .visibility = .{ .compute = true }, .resource = .{ .storage_buffer = .{} } },
        .{ .binding = 3, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{ .filtering = false } } },
        .{
            .binding = 4,
            .visibility = .{ .fragment = true },
            .resource = .{ .texture = .{ .view_dimension = .d2_array } },
        },
        .{
            .binding = 5,
            .visibility = .{ .compute = true },
            .resource = .{ .storage_texture = .{ .format = .rgba8_unorm, .view_dimension = .d2 } },
        },
    };
    const blob: []u8 = try encodeBindGroupLayoutEntries(gpa, &entries);
    defer gpa.free(blob);
    var room: [8]gpu_abi.BindGroupLayoutEntry = undefined;
    const decoded: []gpu_abi.BindGroupLayoutEntry = try gpu_abi.decodeBindGroupLayout(blob, &room);
    try expectEqual(entries.len, decoded.len);
    const kinds = [_]gpu_abi.BindingKind{
        .uniform_buffer,
        .read_only_storage_buffer,
        .storage_buffer,
        .sampler,
        .texture,
        .storage_texture,
    };
    for (entries, decoded, kinds) |entry, read_back, kind| {
        try expectEqual(entry.binding, read_back.binding);
        try expectEqual(entry.visibility, read_back.visibility);
        try expectEqual(kind, read_back.kind);
    }
    try expectEqual(@as(u32, 64), decoded[0].extra);
    try expectEqual(@as(u32, 16), decoded[1].extra);
    try expectEqual(@as(u32, 1), decoded[3].extra);
    try expectEqual(gpu_abi.TextureViewDimension.d2_array, decoded[4].view_dimension);
}

test "gpu_abi round trip: a bind group's buffer range, sampler and view decode to what was encoded" {
    const gpa: Allocator = testing_allocator;
    const entries = [_]BindGroupEntry{
        .{
            .binding = 0,
            .resource = .{ .buffer = .{ .handle = @fromBackingInt(@intCast(5)), .offset = 256, .size = 1024 } },
        },
        .{ .binding = 1, .resource = .{ .sampler = @fromBackingInt(@intCast(6)) } },
        .{ .binding = 2, .resource = .{ .texture_view = @fromBackingInt(@intCast(7)) } },
    };
    const blob: []u8 = try encodeBindGroupEntries(gpa, &entries);
    defer gpa.free(blob);
    var room: [4]gpu_abi.BindGroupEntry = undefined;
    const decoded: []gpu_abi.BindGroupEntry = try gpu_abi.decodeBindGroup(blob, &room);
    try expectEqual(@as(usize, 3), decoded.len);
    try expectEqual(gpu_abi.BindingResource.buffer, decoded[0].resource);
    try expectEqual(@as(u32, 5), decoded[0].handle);
    try expectEqual(@as(u64, 256), decoded[0].offset);
    try expectEqual(@as(u64, 1024), decoded[0].size);
    try expectEqual(gpu_abi.BindingResource.sampler, decoded[1].resource);
    try expectEqual(@as(u32, 6), decoded[1].handle);
    try expectEqual(gpu_abi.BindingResource.texture_view, decoded[2].resource);
    try expectEqual(@as(u32, 7), decoded[2].handle);
}

test "gpu_abi round trip: a render pipeline's layouts, state, depth semantics and tails decode to what was encoded" {
    const gpa: Allocator = testing_allocator;
    const position_and_uv = [_]VertexAttribute{
        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x2, .offset = 12, .shader_location = 1 },
    };
    const per_instance = [_]VertexAttribute{.{ .format = .uint8x4_unorm, .offset = 0, .shader_location = 2 }};
    const descriptor: RenderPipelineDescriptor = .{
        .vertex_buffer_layouts = &.{
            .{ .array_stride = 20, .attributes = &position_and_uv },
            .{ .array_stride = 4, .step_mode = .instance, .attributes = &per_instance },
        },
        .vs_entry_point = "entry",
        .fs_entry_point = "fs_entry",
        .state = .{
            .topology = @backingInt(wgpu.PrimitiveTopology.triangle_strip),
            .cull = @backingInt(wgpu.CullMode.back),
            .blend = @backingInt(wgpu.BlendMode.premultiplied),
            .depth = @backingInt(wgpu.DepthMode.less_no_write),
            .color_format = @backingInt(wgpu.TextureFormat.bgra8_unorm),
            .depth_format = @backingInt(wgpu.TextureFormat.depth24_plus),
            .sample_count = 4,
        },
        .constants = &.{.{ .name = "scale", .value = 2.5 }},
        .extra_color_formats = &.{ .rgba16_float, .rgba32_float },
    };
    const blob: []u8 = try encodeRenderPipelineDescriptor(gpa, descriptor);
    defer gpa.free(blob);
    const decoded: gpu_abi.RenderPipelineDescriptor = try gpu_abi.decodeRenderPipeline(blob);
    try expectEqual(@as(usize, 2), decoded.vertexBuffers().len);
    const instance_layout: gpu_abi.VertexBufferLayout = decoded.vertexBuffers()[1];
    try expectEqual(@as(u32, 4), instance_layout.array_stride);
    try expectEqual(wgpu.VertexStepMode.instance, instance_layout.step_mode);
    try expectEqual(wgpu.VertexFormat.uint8x4_unorm, decoded.attributesOf(instance_layout)[0].format);
    try expectEqual(@as(u32, 1), decoded.attributesOf(decoded.vertexBuffers()[0])[1].shader_location);
    try expectEqualStrings("entry", decoded.vs_entry_point);
    try expectEqualStrings("fs_entry", decoded.fs_entry_point);
    try expectEqual(wgpu.PrimitiveTopology.triangle_strip, decoded.topology);
    try expectEqual(wgpu.BlendMode.premultiplied, decoded.blend);
    try expectEqual(wgpu.TextureFormat.depth24_plus, decoded.depth_format);
    try expectEqual(@as(u32, 4), decoded.sample_count);
    // `less_no_write` tests "less" and does not write: resolved by the encoder, read back as such.
    try expectEqualStrings("less", decoded.depth_compare);
    try expect(!decoded.writes_depth);
    try expectEqual(@as(u32, 1), decoded.constant_count);
    try expectEqual(@as(usize, 2), decoded.extraColorFormats().len);
    try expectEqual(wgpu.TextureFormat.rgba32_float, decoded.extraColorFormats()[1]);
}
