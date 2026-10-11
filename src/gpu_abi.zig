//! THE GPU ABI - what the engine and its GPU hosts must agree on, in one place both can import.
//!
//! Every GPU call the engine makes goes through `wgpu.zig` as a handful of numbers: u32 handles, u32 enumerations,
//! flag words, and three descriptors encoded as byte blobs by `gpu.zig`. Two hosts receive those numbers:
//!
//!     web      `bridge.zig`, compiled to JavaScript, turns them into WebGPU calls in the browser
//!     native   `wgpu_vulkan.zig` turns them into Vulkan calls
//!
//! This file is the contract between the two sides: how every enumeration is numbered, how every flag word is laid
//! out, and how each blob is written, byte by byte - with a decoder for each blob, which the Vulkan host uses (the
//! bridge reads blobs through a JavaScript DataView and keeps its own reader). `wgpu.zig` re-exports the types, so
//! engine code names them as before; the Vulkan host imports this file directly, since importing `wgpu.zig` would
//! close an import cycle. Tests in `gpu.zig` encode with the real encoders and decode with these decoders, so the
//! two cannot drift apart. Std only.
//!
//! ---- THE THREE BLOBS ----
//!
//! Every number is little-endian and written with no padding, so a u64 can sit at any byte offset: decoders read
//! bytes, never aligned words. A string is a u32 length followed by its bytes (no terminating zero).
//!
//! A BIND-GROUP LAYOUT is a u32 entry count, then five u32 per entry:
//!
//!     binding         the binding number in the group
//!     visibility      the stages that see it (a `ShaderStage` word)
//!     kind            0 uniform buffer, 1 read-only storage buffer, 2 storage buffer, 3 sampler, 4 texture,
//!                     5 storage texture (`BindingKind`)
//!     extra           buffers: the minimum binding size (0: any); samplers: 1 when the sampler must not filter
//!     view dimension  textures and storage textures: `TextureViewDimension`; 0 otherwise
//!
//! A BIND GROUP is a u32 entry count, then 28 bytes per entry:
//!
//!     u32 binding, u32 resource (0 buffer, 1 sampler, 2 texture view: `BindingResource`), u32 handle,
//!     u64 offset, u64 size        (buffers only; a size of 0 means "to the end of the buffer")
//!
//! A RENDER PIPELINE is, in order:
//!
//!     u32 vertex-buffer count; per buffer: u32 stride, u32 step mode, u32 attribute count,
//!         per attribute: u32 format, u32 offset, u32 shader location
//!     string vertex entry point, string fragment entry point
//!     u32 topology, u32 cull mode, u32 blend mode, u32 depth mode, u32 color format, u32 depth format,
//!         u32 sample count
//!     string depth compare (WebGPU's name: "less-equal"), u32 writes depth (0 or 1) - resolved from the depth mode
//!         by the encoder, so no host re-derives them
//!     u32 constant count; per constant: string name, f64 value (WGSL `override`s; web only)
//!     u32 extra color-target count; per target: u32 format (MRT: locations 1..N, blending off) - LAST, so a blob
//!         without it reads as a single-target pipeline

const std = @import("std");

const fromInt = std.enums.fromInt;
const readInt = std.mem.readInt;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const writeInt = std.mem.writeInt;

// ---- Enumerations and flag words ----

pub const TextureFormat = enum(u32) {
    undefined_ = 0,
    rgba8_unorm = 1,
    rgba8_unorm_srgb = 2,
    bgra8_unorm = 3,
    bgra8_unorm_srgb = 4,
    rgba16_float = 5,
    rgba32_float = 6,
    r8_unorm = 7,
    rg8_unorm = 8,
    depth16_unorm = 9,
    depth24_plus = 10,
    depth32_float = 11,
};

pub const BufferUsage = packed struct(u32) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,
    _pad: u22 = 0,
};

pub const TextureUsage = packed struct(u32) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    _pad: u27 = 0,
};

pub const ShaderStage = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _pad: u29 = 0,
};

pub const LoadOp = enum(u32) { load = 0, clear = 1 };
pub const StoreOp = enum(u32) { store = 0, discard = 1 };

pub const PrimitiveTopology = enum(u32) {
    point_list = 0,
    line_list = 1,
    line_strip = 2,
    triangle_list = 3,
    triangle_strip = 4,
};

pub const CullMode = enum(u32) { none = 0, front = 1, back = 2 };

pub const BlendMode = enum(u32) {
    /// Disabled - fragment color overwrites destination.
    none = 0,
    /// Standard alpha blend: src * src.a + dst * (1 - src.a).
    alpha = 1,
    /// Additive: src + dst.
    additive = 2,
    /// Multiplicative: src * dst.
    multiply = 3,
    /// Premultiplied alpha: src + dst * (1 - src.a).
    premultiplied = 4,
};

/// A depth comparison: WebGPU's `GPUCompareFunction`. A fragment passes the depth test when `its depth OP the stored
/// depth` holds; with depth growing away from the viewer, `less` keeps the nearest surface.
pub const CompareFunction = enum {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,

    /// WebGPU's name for the comparison, as the browser takes it: the tag with hyphens (`less_equal` is
    /// "less-equal").
    pub fn webgpuName(self: CompareFunction) []const u8 {
        return switch (self) {
            .never => "never",
            .less => "less",
            .equal => "equal",
            .less_equal => "less-equal",
            .greater => "greater",
            .not_equal => "not-equal",
            .greater_equal => "greater-equal",
            .always => "always",
        };
    }
};

/// How a pipeline uses the depth buffer: which comparison its depth test makes, and whether it writes depth. Each
/// mode answers both questions through an exhaustive switch below, so a new mode fails to compile until it states
/// its comparison and its writing; the descriptor encoder bakes both answers into the pipeline blob, and each host
/// reads them there rather than deriving them again.
pub const DepthMode = enum(u32) {
    /// No depth test: the pipeline draws without a depth attachment, or ignores it.
    none = 0,
    less = 1,
    less_equal = 2,
    greater = 3,
    greater_equal = 4,
    equal = 5,
    always = 6,
    /// Depth-tested (less) but not written: transparent and sprite draws, which must not hide what is drawn after
    /// them.
    less_no_write = 7,
    /// Depth-tested (less-equal) but not written: projected decals, which lie exactly on a surface that already wrote
    /// its depth (so equal must pass) and must not write it again (so stacked decals do not fight over it).
    less_equal_no_write = 8,

    /// The comparison this mode's depth test makes. A mode without a test compares `always`, which every fragment
    /// passes.
    pub fn compareFunction(self: DepthMode) CompareFunction {
        return switch (self) {
            .none, .always => .always,
            .less, .less_no_write => .less,
            .less_equal, .less_equal_no_write => .less_equal,
            .greater => .greater,
            .greater_equal => .greater_equal,
            .equal => .equal,
        };
    }

    /// The comparison's WebGPU name, as the encoder writes it into the pipeline blob for the browser bridge.
    pub fn depthCompare(self: DepthMode) []const u8 {
        return self.compareFunction().webgpuName();
    }

    /// Whether this mode writes depth. The passive modes - `none` (no attachment), `always` (overlays, and the 2D
    /// renderer's full-screen clear) and the two no-write modes - must not: a passive full-screen draw that wrote
    /// depth would stamp the whole depth buffer, and every later depth-tested draw would fail against it.
    pub fn writesDepth(self: DepthMode) bool {
        return switch (self) {
            .less, .less_equal, .greater, .greater_equal, .equal => true,
            .none, .always, .less_no_write, .less_equal_no_write => false,
        };
    }
};

pub const VertexFormat = enum(u32) {
    float32 = 0,
    float32x2 = 1,
    float32x3 = 2,
    float32x4 = 3,
    uint32 = 4,
    uint32x2 = 5,
    uint8x4 = 6,
    uint8x4_unorm = 7,
};

pub const VertexStepMode = enum(u32) { vertex = 0, instance = 1 };

pub const IndexFormat = enum(u32) { uint16 = 0, uint32 = 1 };

pub const ColorF32 = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// How a sampler treats coordinates outside [0, 1], on every axis.
pub const AddressMode = enum(u32) {
    clamp_to_edge = 0,
    repeat = 1,
    mirror_repeat = 2,
};

/// A texture binding's view dimension, as the bind-group layout blob carries it (the numbering of
/// `shader_introspect`'s `ViewDimension`, checked by a test in `gpu.zig`).
pub const TextureViewDimension = enum(u32) {
    d1 = 0,
    d2 = 1,
    d2_array = 2,
    cube = 3,
    cube_array = 4,
    d3 = 5,
};

/// What a bind-group layout entry binds.
pub const BindingKind = enum(u32) {
    uniform_buffer = 0,
    read_only_storage_buffer = 1,
    storage_buffer = 2,
    sampler = 3,
    texture = 4,
    storage_texture = 5,
};

/// What a bind-group entry's handle names.
pub const BindingResource = enum(u32) {
    buffer = 0,
    sampler = 1,
    texture_view = 2,
};

// ---- Reading a blob ----

pub const DecodeError = error{
    /// The blob ends before the data its counts announce.
    BlobTruncated,
    /// A number names no value of its enumeration.
    BlobBadValue,
    /// More entries than the decoder has room for - and than WebGPU allows.
    BlobTooManyEntries,
};

/// Reads a blob front to back: little-endian numbers at any byte offset.
pub const BlobReader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn take(reader: *BlobReader, count: usize) DecodeError![]const u8 {
        if (reader.bytes.len - reader.position < count) {
            return DecodeError.BlobTruncated;
        }
        const taken: []const u8 = reader.bytes[reader.position .. reader.position + count];
        reader.position += count;
        return taken;
    }

    pub fn readU32(reader: *BlobReader) DecodeError!u32 {
        const bytes: []const u8 = try reader.take(4);
        return readInt(u32, bytes[0..4], .little);
    }

    pub fn readU64(reader: *BlobReader) DecodeError!u64 {
        const bytes: []const u8 = try reader.take(8);
        return readInt(u64, bytes[0..8], .little);
    }

    pub fn readF64(reader: *BlobReader) DecodeError!f64 {
        return @bitCast(try reader.readU64());
    }

    /// A length-prefixed string, as a slice into the blob.
    pub fn readString(reader: *BlobReader) DecodeError![]const u8 {
        const length: u32 = try reader.readU32();
        return reader.take(length);
    }

    /// A u32 as a value of `Enumeration`; a number that names none is `BlobBadValue`.
    pub fn readEnum(reader: *BlobReader, comptime Enumeration: type) DecodeError!Enumeration {
        const raw: u32 = try reader.readU32();
        return fromInt(Enumeration, raw) orelse DecodeError.BlobBadValue;
    }
};

// ---- Bind-group layouts ----

pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: ShaderStage,
    kind: BindingKind,
    /// Buffers: the minimum binding size (0: any). Samplers: 1 when the sampler must not filter.
    extra: u32,
    view_dimension: TextureViewDimension,
};

/// The entries of a bind-group layout blob, written into `entries` (which must have room for all of them).
pub fn decodeBindGroupLayout(blob: []const u8, entries: []BindGroupLayoutEntry) DecodeError![]BindGroupLayoutEntry {
    var reader: BlobReader = .{ .bytes = blob };
    const count: u32 = try reader.readU32();
    if (count > entries.len) {
        return DecodeError.BlobTooManyEntries;
    }
    for (entries[0..count]) |*entry| {
        const binding: u32 = try reader.readU32();
        const visibility: ShaderStage = @bitCast(try reader.readU32());
        const kind: BindingKind = try reader.readEnum(BindingKind);
        const extra: u32 = try reader.readU32();
        const view_dimension: TextureViewDimension = try reader.readEnum(TextureViewDimension);
        entry.* = .{
            .binding = binding,
            .visibility = visibility,
            .kind = kind,
            .extra = extra,
            .view_dimension = view_dimension,
        };
    }
    return entries[0..count];
}

// ---- Bind groups ----

pub const BindGroupEntry = struct {
    binding: u32,
    resource: BindingResource,
    /// A buffer, sampler or texture-view handle, by `resource`.
    handle: u32,
    /// Buffers: the bound range's start, and its size (0: to the end of the buffer).
    offset: u64,
    size: u64,
};

/// The entries of a bind-group blob, written into `entries` (which must have room for all of them).
pub fn decodeBindGroup(blob: []const u8, entries: []BindGroupEntry) DecodeError![]BindGroupEntry {
    var reader: BlobReader = .{ .bytes = blob };
    const count: u32 = try reader.readU32();
    if (count > entries.len) {
        return DecodeError.BlobTooManyEntries;
    }
    for (entries[0..count]) |*entry| {
        const binding: u32 = try reader.readU32();
        const resource: BindingResource = try reader.readEnum(BindingResource);
        const handle: u32 = try reader.readU32();
        const offset: u64 = try reader.readU64();
        const size: u64 = try reader.readU64();
        entry.* = .{ .binding = binding, .resource = resource, .handle = handle, .offset = offset, .size = size };
    }
    return entries[0..count];
}

// ---- Render pipelines ----

/// WebGPU's limits, which bound the decoded pipeline's fixed arrays.
pub const max_vertex_buffers: usize = 8;
pub const max_vertex_attributes: usize = 16;
pub const max_color_targets: usize = 8;

pub const VertexAttribute = struct {
    format: VertexFormat,
    offset: u32,
    shader_location: u32,
};

/// One vertex buffer's layout; its attributes are `attribute_count` entries of the pipeline's `attributes`, from
/// `first_attribute`.
pub const VertexBufferLayout = struct {
    array_stride: u32,
    step_mode: VertexStepMode,
    first_attribute: u32,
    attribute_count: u32,
};

/// A render-pipeline blob, decoded. Strings are slices into the blob, which must outlive this value.
pub const RenderPipelineDescriptor = struct {
    vertex_buffers: [max_vertex_buffers]VertexBufferLayout,
    vertex_buffer_count: u32,
    attributes: [max_vertex_attributes]VertexAttribute,
    attribute_count: u32,
    vs_entry_point: []const u8,
    fs_entry_point: []const u8,
    topology: PrimitiveTopology,
    cull: CullMode,
    blend: BlendMode,
    depth: DepthMode,
    color_format: TextureFormat,
    depth_format: TextureFormat,
    sample_count: u32,
    /// WebGPU's name for the depth comparison ("less", "less-equal", ...), for the browser bridge, which passes it to
    /// WebGPU as it is; the native host reads the comparison from `depth` (`DepthMode.compareFunction`).
    depth_compare: []const u8,
    writes_depth: bool,
    /// How many WGSL `override` constants the blob carries (their names and values are web only).
    constant_count: u32,
    /// MRT: the formats of color targets 1..N; target 0 is `color_format`.
    extra_color_formats: [max_color_targets - 1]TextureFormat,
    extra_color_format_count: u32,

    pub fn vertexBuffers(descriptor: *const RenderPipelineDescriptor) []const VertexBufferLayout {
        return descriptor.vertex_buffers[0..descriptor.vertex_buffer_count];
    }

    pub fn attributesOf(
        descriptor: *const RenderPipelineDescriptor,
        layout: VertexBufferLayout,
    ) []const VertexAttribute {
        return descriptor.attributes[layout.first_attribute .. layout.first_attribute + layout.attribute_count];
    }

    pub fn extraColorFormats(descriptor: *const RenderPipelineDescriptor) []const TextureFormat {
        return descriptor.extra_color_formats[0..descriptor.extra_color_format_count];
    }
};

pub fn decodeRenderPipeline(blob: []const u8) DecodeError!RenderPipelineDescriptor {
    var reader: BlobReader = .{ .bytes = blob };
    var descriptor: RenderPipelineDescriptor = undefined;
    descriptor.vertex_buffer_count = try reader.readU32();
    if (descriptor.vertex_buffer_count > max_vertex_buffers) {
        return DecodeError.BlobTooManyEntries;
    }
    descriptor.attribute_count = 0;
    for (descriptor.vertex_buffers[0..descriptor.vertex_buffer_count]) |*layout| {
        const array_stride: u32 = try reader.readU32();
        const step_mode: VertexStepMode = try reader.readEnum(VertexStepMode);
        const attribute_count: u32 = try reader.readU32();
        if (descriptor.attribute_count + attribute_count > max_vertex_attributes) {
            return DecodeError.BlobTooManyEntries;
        }
        layout.* = .{
            .array_stride = array_stride,
            .step_mode = step_mode,
            .first_attribute = descriptor.attribute_count,
            .attribute_count = attribute_count,
        };
        for (0..attribute_count) |_| {
            const format: VertexFormat = try reader.readEnum(VertexFormat);
            const offset: u32 = try reader.readU32();
            const shader_location: u32 = try reader.readU32();
            descriptor.attributes[descriptor.attribute_count] = .{
                .format = format,
                .offset = offset,
                .shader_location = shader_location,
            };
            descriptor.attribute_count += 1;
        }
    }
    descriptor.vs_entry_point = try reader.readString();
    descriptor.fs_entry_point = try reader.readString();
    descriptor.topology = try reader.readEnum(PrimitiveTopology);
    descriptor.cull = try reader.readEnum(CullMode);
    descriptor.blend = try reader.readEnum(BlendMode);
    descriptor.depth = try reader.readEnum(DepthMode);
    descriptor.color_format = try reader.readEnum(TextureFormat);
    descriptor.depth_format = try reader.readEnum(TextureFormat);
    descriptor.sample_count = try reader.readU32();
    descriptor.depth_compare = try reader.readString();
    descriptor.writes_depth = try reader.readU32() != 0;
    descriptor.constant_count = try reader.readU32();
    for (0..descriptor.constant_count) |_| {
        _ = try reader.readString();
        _ = try reader.readF64();
    }
    descriptor.extra_color_format_count = try reader.readU32();
    if (descriptor.extra_color_format_count > max_color_targets - 1) {
        return DecodeError.BlobTooManyEntries;
    }
    for (descriptor.extra_color_formats[0..descriptor.extra_color_format_count]) |*format| {
        format.* = try reader.readEnum(TextureFormat);
    }
    return descriptor;
}

// ---- Tests: hand-written blobs (the encoders' round trips are in gpu.zig) ----

/// Writes test blobs the way the encoders do: little-endian, no padding.
const TestBlob = struct {
    bytes: [256]u8 = undefined,
    length: usize = 0,

    fn u32Word(blob: *TestBlob, value: u32) void {
        writeInt(u32, blob.bytes[blob.length..][0..4], value, .little);
        blob.length += 4;
    }

    fn u64Word(blob: *TestBlob, value: u64) void {
        writeInt(u64, blob.bytes[blob.length..][0..8], value, .little);
        blob.length += 8;
    }

    fn string(blob: *TestBlob, text: []const u8) void {
        blob.u32Word(@intCast(text.len));
        @memcpy(blob.bytes[blob.length .. blob.length + text.len], text);
        blob.length += text.len;
    }

    fn written(blob: *const TestBlob) []const u8 {
        return blob.bytes[0..blob.length];
    }
};

test "gpu_abi: a bind-group layout blob decodes entry by entry" {
    var blob: TestBlob = .{};
    blob.u32Word(2);
    // A uniform buffer at 0 for both stages, at least 64 bytes.
    for ([_]u32{ 0, 0b011, 0, 64, 0 }) |word| {
        blob.u32Word(word);
    }
    // A 2D-array texture at 3 for the fragment stage.
    for ([_]u32{ 3, 0b010, 4, 0, 2 }) |word| {
        blob.u32Word(word);
    }
    var room: [4]BindGroupLayoutEntry = undefined;
    const entries: []BindGroupLayoutEntry = try decodeBindGroupLayout(blob.written(), &room);
    try expectEqual(@as(usize, 2), entries.len);
    try expectEqual(BindingKind.uniform_buffer, entries[0].kind);
    try expectEqual(@as(u32, 64), entries[0].extra);
    try expect(entries[0].visibility.vertex and entries[0].visibility.fragment);
    try expectEqual(@as(u32, 3), entries[1].binding);
    try expectEqual(BindingKind.texture, entries[1].kind);
    try expectEqual(TextureViewDimension.d2_array, entries[1].view_dimension);
    try expect(!entries[1].visibility.vertex and entries[1].visibility.fragment);
}

test "gpu_abi: a bind-group blob's u64s are read at unaligned offsets" {
    var blob: TestBlob = .{};
    blob.u32Word(2);
    blob.u32Word(0);
    blob.u32Word(@backingInt(BindingResource.buffer));
    blob.u32Word(7);
    blob.u64Word(0x1_0000_0100);
    blob.u64Word(256);
    blob.u32Word(1);
    blob.u32Word(@backingInt(BindingResource.sampler));
    blob.u32Word(9);
    blob.u64Word(0);
    blob.u64Word(0);
    var room: [4]BindGroupEntry = undefined;
    const entries: []BindGroupEntry = try decodeBindGroup(blob.written(), &room);
    try expectEqual(@as(usize, 2), entries.len);
    try expectEqual(@as(u32, 7), entries[0].handle);
    try expectEqual(@as(u64, 0x1_0000_0100), entries[0].offset);
    try expectEqual(@as(u64, 256), entries[0].size);
    try expectEqual(BindingResource.sampler, entries[1].resource);
}

test "gpu_abi: a render-pipeline blob decodes in order; its MRT tail is optional in length" {
    var blob: TestBlob = .{};
    blob.u32Word(1);
    blob.u32Word(20);
    blob.u32Word(@backingInt(VertexStepMode.vertex));
    blob.u32Word(2);
    for ([_]u32{ @backingInt(VertexFormat.float32x3), 0, 0, @backingInt(VertexFormat.float32x2), 12, 1 }) |word| {
        blob.u32Word(word);
    }
    blob.string("entry");
    blob.string("entry");
    for ([_]u32{ 3, 2, 1, 2, 1, 11, 4 }) |word| {
        blob.u32Word(word);
    }
    blob.string("less-equal");
    blob.u32Word(1);
    blob.u32Word(0);
    blob.u32Word(1);
    blob.u32Word(@backingInt(TextureFormat.rgba16_float));
    const descriptor: RenderPipelineDescriptor = try decodeRenderPipeline(blob.written());
    try expectEqual(@as(usize, 1), descriptor.vertexBuffers().len);
    const attributes: []const VertexAttribute = descriptor.attributesOf(descriptor.vertexBuffers()[0]);
    try expectEqual(@as(usize, 2), attributes.len);
    try expectEqual(VertexFormat.float32x2, attributes[1].format);
    try expectEqual(@as(u32, 12), attributes[1].offset);
    try expectEqualStrings("entry", descriptor.fs_entry_point);
    try expectEqual(PrimitiveTopology.triangle_list, descriptor.topology);
    try expectEqual(CullMode.back, descriptor.cull);
    try expectEqual(BlendMode.alpha, descriptor.blend);
    try expectEqual(DepthMode.less_equal, descriptor.depth);
    try expectEqual(TextureFormat.depth32_float, descriptor.depth_format);
    try expectEqual(@as(u32, 4), descriptor.sample_count);
    try expectEqualStrings("less-equal", descriptor.depth_compare);
    try expect(descriptor.writes_depth);
    try expectEqual(@as(usize, 1), descriptor.extraColorFormats().len);
    try expectEqual(TextureFormat.rgba16_float, descriptor.extraColorFormats()[0]);
}

test "gpu_abi: a short blob, a bad value and too many entries are named errors" {
    var blob: TestBlob = .{};
    blob.u32Word(1);
    blob.u32Word(0);
    var room: [1]BindGroupLayoutEntry = undefined;
    try expectError(DecodeError.BlobTruncated, decodeBindGroupLayout(blob.written(), &room));
    var bad: TestBlob = .{};
    bad.u32Word(1);
    for ([_]u32{ 0, 1, 99, 0, 0 }) |word| {
        bad.u32Word(word);
    }
    try expectError(DecodeError.BlobBadValue, decodeBindGroupLayout(bad.written(), &room));
    var many: TestBlob = .{};
    many.u32Word(2);
    try expectError(DecodeError.BlobTooManyEntries, decodeBindGroupLayout(many.written(), &room));
}
