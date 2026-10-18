//! THE VULKAN HOST - the native twin of `bridge.zig`: the same GPU calls, answered by Vulkan.
//!
//! Every GPU call the engine makes passes through `wgpu.zig` as numbers - u32 handles, enumerations, flag words, and
//! descriptor blobs (`gpu_abi.zig`). In a browser, `bridge.zig` turns each call into WebGPU. In a native build
//! (`host.kind == .native`), `wgpu.zig` calls the function of the same name here, and this file turns it into Vulkan.
//! Above `wgpu.zig`, nothing in the engine or the examples knows which host it runs on.
//!
//! Each call is named after the browser's without its `js_` prefix and takes exactly the same parameters; every web
//! build checks that, so a call missing here, or declared differently, fails the build by name. A call not written
//! yet is a compile error naming itself: a native build that reaches it lists exactly what is missing, and nothing
//! ever answers with a silently wrong value.
//!
//! ---- KEEPING WEBGPU'S PROMISES ON VULKAN ----
//!
//! WebGPU promises things that Vulkan leaves to the program, and most of this file keeps those promises:
//!
//!     ordering without barriers    every image stays in the GENERAL layout, and one full memory barrier comes
//!                                  before every pass and every write, so whatever ran before is visible to it
//!     destroying at any time       a released object is destroyed only after the GPU has finished every
//!                                  submission that may use it (`deferDestroy`, and the timeline below)
//!     writes ordered on the queue  write calls record into `uploads`, a command buffer submitted ahead of the next
//!                                  batch: a write lands after everything submitted before it, and before
//!                                  everything submitted after it
//!     new memory reads as zeros    a buffer is filled, and a texture cleared, with zeros when it is created
//!     Y up in clip space           the viewport is flipped (a negative height), so Vulkan's Y-down clip space
//!                                  draws exactly where WebGPU's Y-up one does
//!
//! ---- OBJECTS ----
//!
//! The browser keeps its GPU objects in JavaScript tables; this host keeps them in one `Host`, behind one module
//! global. A window's native loop starts it (`attachWindow`); a program without a window starts it headless
//! (`startHeadless`) and draws only into textures. The engine's first GPU call (`initDevice`) brings Vulkan up, and
//! `shutdown` tears it down after the app's own teardown. Every object the engine creates is a u32 handle into a
//! `Pool` - a slot, and that slot's generation - so a handle used after its object was destroyed fails by name.
//!
//! ---- THE TIMELINE ----
//!
//! One timeline semaphore - a 64-bit counter the GPU advances as work completes - numbers every submission. Reading
//! it tells, without waiting, which submissions are done. Command buffers, staging chunks and released objects are
//! reclaimed as the counter passes the submissions that used them: after every submission, and before every frame.
//!
//! ---- A FRAME ----
//!
//!     current texture   wait until this frame slot's previous present has finished (at most two frames ahead);
//!                       acquire a swapchain image, signalling the slot's acquire semaphore; record the image's
//!                       move to GENERAL, and its clear to zeros, into `uploads`
//!     submit            `uploads` (closed by a full barrier) and the encoder's commands, in one batch that waits
//!                       for the acquire if no earlier batch did, and signals the timeline's next number
//!     present           a small command buffer moves the image to PRESENT_SRC; its batch signals the image's
//!                       present semaphore, which `vkQueuePresentKHR` waits for
//!
//!     CPU   acquire --- record --- submit #n --------- present --- acquire (next frame) ...
//!                                     |                    |
//!     GPU                   [ uploads | encoder ]   [ to PRESENT_SRC ]
//!                                          |                        |
//!                                 the counter reaches n      the image is shown
//!
//! ---- MEMORY ----
//!
//! One allocation per resource, of the memory type the resource asks for. Writes are copied through staging chunks:
//! host-visible memory mapped for the host's life, 4 MiB each (or exactly the size of a larger write), filled by
//! consecutive writes and consumed by the next submission. A chunk the GPU has finished with serves the next write it
//! fits; once a budget of chunks exists, an upload waits for the oldest to come back rather than allocate another,
//! which bounds staging memory when nothing else paces submission, as in a host without a window.
//!
//! ---- THE SWAPCHAIN ----
//!
//! RGBA8 UNORM when the surface offers it, else BGRA8 UNORM - and `getSurfaceFormat` reports which, so the engine
//! builds its pipelines for the format it actually presents, as it does for a browser canvas. FIFO presents at the
//! display's rate, as `requestAnimationFrame` does. Each image's view has ONE handle for the host's whole life: a
//! rebuild (a resize, `OUT_OF_DATE`, `SUBOPTIMAL`) refreshes the views behind the same handles.

const std = @import("std");
const vk = @import("vk.zig");
const native_os = @import("native_os.zig");
const win32 = @import("win32.zig");
const gpu_abi = @import("gpu_abi.zig");
const spv_vulkan = @import("spv_vulkan.zig");
const zm = @import("zm");
const clamp = zm.clamp;
const maxInt = zm.maxInt;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const alignForward = std.mem.alignForward;
const indexOf = std.mem.indexOf;
const span = std.mem.span;
const parseInt = std.fmt.parseInt;
const bufPrint = std.fmt.bufPrint;
const panic = std.debug.panic;
const indexOfScalar = std.mem.indexOfScalar;
const sliceAsBytes = std.mem.sliceAsBytes;
const swap = std.mem.swap;
const log = std.log.scoped(.vulkan);

/// The host's own allocations (its tables, its swapchain arrays): the process heap.
const heap: Allocator = std.heap.smp_allocator;

/// How many frames the CPU may record ahead of the GPU.
const frames_in_flight: usize = 2;

/// "Wait as long as it takes", for the timeline and for acquire.
const no_timeout: u64 = zm.maxInt(u64);

// ---- Handles ----

/// A handle as the engine holds it: which slot of its pool, and which generation of that slot. The slot is stored
/// plus one, so the all-zero handle names no object - zimr's and WebGPU's "none". Being a packed struct, its fields
/// ARE the bits: the slot in the low 24, the generation in the high 8.
const Handle = packed struct(u32) {
    slot_plus_one: u24,
    generation: u8,

    fn ofSlot(slot: u32, generation: u8) Handle {
        return .{ .slot_plus_one = @intCast(slot + 1), .generation = generation };
    }
};

/// A table of host objects addressed by `Handle`s. Removing an object frees its slot for reuse under the next
/// generation, so a handle kept past its object's destruction no longer matches its slot, and `get` refuses it by
/// name instead of reaching the object that replaced it.
fn Pool(comptime Slot: type) type {
    return struct {
        entries: ArrayList(Entry) = .empty,
        free_slots: ArrayList(u32) = .empty,

        const Self = @This();
        const Entry = struct { slot: Slot, generation: u8, live: bool };
        /// The most slots a pool holds: as many as `slot_plus_one`'s 24 bits can number.
        const max_slots: u32 = zm.maxInt(u24);

        fn add(pool: *Self, gpa: Allocator, slot: Slot) Allocator.Error!u32 {
            if (pool.free_slots.pop()) |index| {
                const entry: *Entry = &pool.entries.items[index];
                entry.* = .{ .slot = slot, .generation = entry.generation +% 1, .live = true };
                return @bitCast(Handle.ofSlot(index, entry.generation));
            }
            const index: u32 = @intCast(pool.entries.items.len);
            if (index >= max_slots) {
                panic("vulkan host: more than {d} live objects of one kind", .{max_slots});
            }
            try pool.entries.append(gpa, .{ .slot = slot, .generation = 0, .live = true });
            return @bitCast(Handle.ofSlot(index, 0));
        }

        fn get(pool: *Self, handle: u32, comptime kind: []const u8) *Slot {
            const entry: *Entry = pool.entryOf(handle, kind);
            return &entry.slot;
        }

        /// The slot `handle` names, or null when its object was destroyed (or the handle names nothing): for an
        /// object that may legitimately be gone, where `get` would end the program.
        fn find(pool: *Self, handle: u32) ?*Slot {
            const entry: *Entry = pool.entryAt(handle) orelse return null;
            return if (holds(entry, handle)) &entry.slot else null;
        }

        fn remove(
            pool: *Self,
            gpa: Allocator,
            handle: u32,
            comptime kind: []const u8,
        ) Allocator.Error!Slot {
            const entry: *Entry = pool.entryOf(handle, kind);
            entry.live = false;
            const parts: Handle = @bitCast(handle);
            try pool.free_slots.append(gpa, @as(u32, parts.slot_plus_one) - 1);
            return entry.slot;
        }

        /// The entry the slot part of `handle` names, or null when it names none (handle 0, or past the table).
        fn entryAt(pool: *Self, handle: u32) ?*Entry {
            const parts: Handle = @bitCast(handle);
            const is_null: bool = parts.slot_plus_one == 0;
            const is_past_table: bool = parts.slot_plus_one > pool.entries.items.len;
            if (is_null or is_past_table) {
                return null;
            }
            return &pool.entries.items[parts.slot_plus_one - 1];
        }

        /// Whether `entry` still holds the object `handle` was given for: live, and not reused since (a reused slot
        /// has a newer generation).
        fn holds(entry: *const Entry, handle: u32) bool {
            const parts: Handle = @bitCast(handle);
            return entry.live and entry.generation == parts.generation;
        }

        fn entryOf(pool: *Self, handle: u32, comptime kind: []const u8) *Entry {
            const entry: *Entry = pool.entryAt(handle) orelse
                panic("vulkan host: unknown {s} handle {d}", .{ kind, handle });
            if (!holds(entry, handle)) {
                panic("vulkan host: {s} handle {d} used after its object was destroyed", .{ kind, handle });
            }
            return entry;
        }

        fn deinit(pool: *Self, gpa: Allocator) void {
            pool.entries.deinit(gpa);
            pool.free_slots.deinit(gpa);
        }
    };
}

/// A texture view: the Vulkan view, and what passes and copies need to know about its image.
const TextureViewSlot = struct {
    view: vk.ImageView,
    image: vk.Image,
    format: vk.Format,
    extent: vk.Extent2D,
    /// A swapchain image's view belongs to the host: the engine never destroys it, and a rebuild refreshes it in
    /// place behind the same handle.
    is_swapchain_image: bool,
    is_depth: bool = false,
    /// How many live bind groups hold this view - WebGPU keeps a view alive while one does, however early the app
    /// releases its handle (`releaseTextureView`).
    bind_group_count: u32 = 0,
    /// Whether the app has released its handle.
    released: bool = false,
    /// The sample count, as Vulkan's flags (one bit set).
    samples: vk.SampleCountFlags = .{ .@"1" = true },
};

const TextureSlot = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    format: vk.Format,
    is_depth: bool,
    extent: vk.Extent2D,
    mip_levels: u32,
    array_layers: u32,
    samples: vk.SampleCountFlags,
    texel_bytes: u32,
};

/// Who gives up a reference to an object: the app, releasing its handle, or an object built on it - a pipeline on its
/// layout, a bind group on its samplers and views.
const Holder = enum { app, dependent };

/// A sampler. WebGPU keeps a sampler alive while a bind group holds it, however early the app releases its handle; so
/// does the host (`releaseSampler`).
const SamplerSlot = struct {
    sampler: vk.Sampler,
    /// How many live bind groups hold this sampler.
    bind_group_count: u32 = 0,
    /// Whether the app has released its handle.
    released: bool = false,
};

const ShaderModuleSlot = struct {
    module: vk.ShaderModule,
};

const BindGroupLayoutSlot = struct {
    layout: vk.DescriptorSetLayout,
    /// The decoded entries, owned: writing a bind group needs each binding's kind.
    entries: []gpu_abi.BindGroupLayoutEntry,
};

/// A descriptor set, and the index of the pool page it came from (it returns there when freed).
const DescriptorSetSlot = struct {
    set: vk.DescriptorSet,
    page: u32,
};

/// A sampler or texture view a bind group holds.
const HeldBindable = struct {
    kind: enum { sampler, texture_view },
    handle: u32,
};

/// The most bindings one group may have here: zimr's groups have a handful (WebGPU's own limit is 1000).
const max_bindings_per_group: usize = 32;

/// A bind group: one descriptor set, and the samplers and views it holds - each kept alive until the group is released
/// (buffers need no holding: the app destroys a buffer explicitly, after which WebGPU too refuses its use).
const BindGroupSlot = struct {
    descriptor_set: DescriptorSetSlot,
    held: [max_bindings_per_group]HeldBindable = undefined,
    held_count: u32 = 0,
};

/// A descriptor pool page. Sets are allocated from a page until Vulkan reports it full; a destroyed bind group's
/// set returns to its page, which then has room again. `has_room` records the last answer, so allocation skips
/// pages known to be full instead of asking Vulkan each time.
const DescriptorPage = struct {
    pool: vk.DescriptorPool,
    has_room: bool = true,
};

/// zimr binds at most this many bind groups (groups 0, 1 and 2; every Vulkan device binds at least 4).
const max_bind_groups: usize = 4;

/// One bit per bind-group slot of a pass.
const GroupSet = std.bit_set.IntegerBitSet(max_bind_groups);

/// A pipeline layout. WebGPU lets an app release a pipeline layout as soon as its pipelines exist - each pipeline keeps
/// what it needs - but Vulkan's binding calls use the layout object itself for as long as commands are recorded with
/// those pipelines. So the layout lives until the app has released it and the last pipeline made from it is gone
/// (`releasePipelineLayout`).
const PipelineLayoutSlot = struct {
    layout: vk.PipelineLayout,
    set_count: u32,
    /// The sets whose layout has no bindings - no shader reads them, so nothing is bound there (`bindDirtyGroups`).
    empty_sets: GroupSet = .empty,
    /// How many live pipelines were made from this layout.
    pipeline_count: u32 = 0,
    /// Whether the app has released its handle.
    released: bool = false,
};

/// A render or compute pipeline, with its layout: a pass binds bind groups against the layout of the pipeline bound.
const PipelineSlot = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    /// The pipeline layout's handle: the pipeline holds one of its references (`PipelineLayoutSlot.pipeline_count`).
    layout_handle: u32,
    set_count: u32,
    /// The layout's sets with no bindings (`PipelineLayoutSlot.empty_sets`).
    empty_sets: GroupSet,
};

/// A render or compute pass being recorded into its encoder's command buffer. Bind groups are recorded as they are
/// set and bound at the next draw or dispatch, against the layout of the pipeline bound then - WebGPU lets a group be
/// set before the pipeline it will be used with.
const PassSlot = struct {
    command_buffer: vk.CommandBuffer,
    /// Which pipelines and groups the pass binds: a render pass's, or a compute pass's.
    bind_point: vk.PipelineBindPoint = .graphics,
    pipeline_layout: vk.PipelineLayout = .null_handle,
    pipeline_set_count: u32 = 0,
    /// The bound pipeline's sets with no bindings, which no group is bound to.
    pipeline_empty_sets: GroupSet = .empty,
    groups: [max_bind_groups]vk.DescriptorSet = @splat(.null_handle),
    /// The group slots to bind at the next draw: set since the last draw bound them, or since a pipeline change.
    dirty_groups: GroupSet = .empty,
    /// A compute pass: whether a dispatch is recorded already. Each later one waits for the writes before it.
    has_dispatched: bool = false,
};

// ---- The host ----

/// What the validation layer reported, counted by the debug messenger.
pub const MessageCounts = struct {
    errors: u32 = 0,
    warnings: u32 = 0,
};

/// The GPU chosen at bring-up: its handle and name, and the queue family that renders, computes and presents.
const Gpu = struct {
    physical_device: vk.PhysicalDevice,
    name: [vk.max_physical_device_name_size]u8,
    device_type: vk.PhysicalDeviceType,
    /// The vendor's PCI id (`adapterInfo` names the usual ones) and the Vulkan version the driver offers.
    vendor_id: u32,
    api_version: u32,
    queue_family: u32,
    /// How many `vkAllocateMemory` allocations may be live at once (one per buffer or image here).
    max_memory_allocations: u32,
    /// How many descriptor sets a pipeline may bind: WebGPU's group number is the set number, up to 3 in zimr.
    max_bound_descriptor_sets: u32,
};

/// A command buffer waiting for the timeline to pass `serial`, after which it is reset and reused.
const Retiring = struct {
    serial: u64,
    command_buffer: vk.CommandBuffer,
};

const Swapchain = struct {
    handle: vk.SwapchainKHR = .null_handle,
    format: vk.Format = .undefined,
    extent: vk.Extent2D = .{},
    images: []vk.Image = &.{},
    /// One per image: signalled by the batch that presents the image, waited by the present.
    /// One per image index, KEPT across rebuilds (only added to when the image count grows): a present has no fence,
    /// so nothing says when the presentation engine has consumed its semaphore wait - destroying a present semaphore
    /// while recreating the swapchain could pull it from under a present in flight. They go only at shutdown.
    present_semaphores: ArrayList(vk.Semaphore) = .empty,
    /// One per image, kept across rebuilds: the texture-view handles the engine sees.
    view_handles: ArrayList(u32) = .empty,
};

/// A command encoder: the command buffer it records into, begun at creation.
const EncoderSlot = struct {
    command_buffer: vk.CommandBuffer,
};

/// A finished command buffer, waiting for `queueSubmit`.
const CommandBufferSlot = struct {
    command_buffer: vk.CommandBuffer,
};

const BufferSlot = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    size: u64,
    /// A `map_read` buffer's memory, mapped for the buffer's whole life; null for device-local memory.
    mapped: ?[*]u8,
};

/// A read of a `map_read` buffer (`bufferReadStart`, WebGPU's `mapAsync`). It is ready once the timeline reaches
/// `serial` - the batch submitted when the read started, after everything submitted before it - and its bytes are then
/// copied out, so later work on the buffer cannot change what the read returns, as the browser copies a mapped range
/// out before unmapping it.
const ReadSlot = struct {
    /// The buffer read, by handle: it may be destroyed while the read is pending, so it is looked up again when the
    /// read completes (`Pool.find`).
    buffer_handle: u32,
    /// How many bytes, from the buffer's start.
    size: u64,
    /// The timeline value the read is ready at: the number of the batch submitted when it started.
    serial: u64,
    /// The bytes, once ready.
    data: ?[]u8 = null,
};

/// A Vulkan object the engine has released but the GPU may still be using.
const Destroy = union(enum) {
    buffer: struct { buffer: vk.Buffer, memory: vk.DeviceMemory },
    image: struct { image: vk.Image, memory: vk.DeviceMemory },
    image_view: vk.ImageView,
    sampler: vk.Sampler,
    descriptor_set: DescriptorSetSlot,
    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
};

/// A destroy waiting for the timeline to pass `serial`.
const RetiringDestroy = struct {
    serial: u64,
    destroy: Destroy,
};

/// Where write calls put the caller's bytes on their way to the GPU: chunks of host-visible, coherent memory, mapped
/// for their whole life. A chunk is filled front to back; the batch that consumes it (the next submit) numbers it,
/// and it is reused once the timeline passes that number.
const staging_chunk_size: u64 = 4 << 20;

/// How many staging chunks the host may hold before an upload waits for the GPU instead of allocating another. A
/// windowed host rarely reaches it: acquiring an image already waits for the frame two frames back. A host without a
/// window has no such pacing - the processor can submit faster than the GPU completes - and every submission in
/// flight keeps its chunk, so without a budget staging memory would grow with the GPU's backlog.
pub const staging_chunk_budget: usize = 4;

const StagingChunk = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: [*]u8,
    size: u64,
    used: u64,
};

const RetiringChunk = struct {
    serial: u64,
    index: usize,
};

const Staging = struct {
    chunks: ArrayList(StagingChunk) = .empty,
    /// The chunk being filled, if any.
    current: ?usize = null,
    /// Chunks written since the last submit: the next batch consumes them.
    in_use: ArrayList(usize) = .empty,
    /// Chunks consumed by a submission, each with that submission's number - in submission order, which
    /// `reclaimOldestStagingChunk` relies on to find the oldest.
    retiring: ArrayList(RetiringChunk) = .empty,
    /// Chunks the GPU has finished with, emptied and ready to fill again.
    free: ArrayList(usize) = .empty,
};

/// Where a write's bytes were staged.
const Staged = struct {
    buffer: vk.Buffer,
    offset: u64,
};

/// A headless host's screen (`startHeadlessWithScreen`): the image frames draw into in place of a window's swapchain
/// image, so that a program without a window renders exactly as it would with one, and its frames can be read back -
/// copied from `texture`, as from any texture. The surface calls serve it as they serve a swapchain: its size and
/// format, the current texture - cleared to zeros when each frame first asks for it, as WebGPU's is - and the present,
/// which ends the frame. It is made the first time the engine asks for the surface, since textures need the device.
const Screen = struct {
    width: u32,
    height: u32,
    /// The texture and its view; 0 until made.
    texture: u32 = 0,
    view: u32 = 0,
    /// Whether the current frame has asked for its texture: cleared then, and ended by the present.
    is_frame_begun: bool = false,
    /// How many frames have been drawn on the screen: asked for its texture, then presented.
    drawn_frame_count: u64 = 0,
};

/// A copy of the frame a window last presented, kept while asked for (`keepPresentedFrames`): the swapchain image is
/// copied into a buffer the CPU can read just before it is presented - after which it belongs to the display - so that
/// a script's `capture` can save the frame last drawn on a window, as on a headless screen (`readLastFrame`).
const KeptFrame = struct {
    /// The buffer the copy lands in (a `map_read` buffer of the host's), 0 until the first copy; remade when the
    /// window's size changes.
    buffer: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// The batch that made the copy: it is ready once the timeline reaches it.
    serial: u64 = 0,
    /// Whether the swapchain's texels are blue, green, red, alpha - swapped when read back.
    is_bgra: bool = false,
};

/// The format a screen draws in: 8-bit RGBA, read back byte for byte in that order.
const screen_format: gpu_abi.TextureFormat = .rgba8_unorm;

const Host = struct {
    gpa: Allocator,
    /// The window drawn into; null for a headless host, which draws only into textures (the host's tests, offline
    /// rendering) and has no surface, no swapchain, and none of their commands.
    window: ?*win32.Window,
    /// A headless host's screen, when it has one (`Screen`); null with a window, which has its swapchain instead.
    screen: ?Screen = null,
    /// Whether each frame a window presents is copied for reading back (`KeptFrame`), and the copy.
    keeps_presented_frames: bool = false,
    kept_frame: KeptFrame = .{},
    counts: MessageCounts = .{},
    library: ?native_os.VulkanLibrary = null,
    global: vk.GlobalDispatch = undefined,
    instance: vk.Instance = .null_handle,
    instance_dispatch: vk.InstanceDispatch = undefined,
    /// The window-system commands: loaded only with a window.
    surface_dispatch: vk.SurfaceDispatch = undefined,
    messenger: vk.DebugUtilsMessengerEXT = .null_handle,
    surface: vk.SurfaceKHR = .null_handle,
    gpu: Gpu = undefined,
    device: vk.Device = .null_handle,
    device_dispatch: vk.DeviceDispatch = undefined,
    /// The swapchain commands: loaded only with a window.
    swapchain_dispatch: vk.SwapchainDispatch = undefined,
    queue: vk.Queue = .null_handle,
    command_pool: vk.CommandPool = .null_handle,
    free_command_buffers: ArrayList(vk.CommandBuffer) = .empty,
    retiring_command_buffers: ArrayList(Retiring) = .empty,
    /// Counts submits: submit number n signals the value n when it finishes.
    timeline: vk.Semaphore = .null_handle,
    submitted: u64 = 0,
    /// The timeline's value when last read.
    completed: u64 = 0,
    /// The write calls' command buffer, begun lazily; it runs ahead of the next submit.
    uploads: vk.CommandBuffer = .null_handle,
    acquire_semaphores: [frames_in_flight]vk.Semaphore = @splat(.null_handle),
    /// Per frame slot: the number of the submit that presented its last image.
    present_serials: [frames_in_flight]u64 = @splat(0),
    frame_slot: usize = 0,
    acquired_image: ?u32 = null,
    acquire_waited: bool = false,
    /// The swapchain image acquired before its frame began (`tryAcquireAhead`), which the frame's `acquireImage`
    /// takes; null when the frame acquires its own.
    image_acquired_ahead: ?u32 = null,
    swapchain: Swapchain = .{},
    swapchain_dirty: bool = false,
    texture_views: Pool(TextureViewSlot) = .{},
    memory_properties: vk.PhysicalDeviceMemoryProperties = .{},
    /// Live `vkAllocateMemory` allocations.
    allocations: u32 = 0,
    /// Encoders created and not yet submitted. While one is open, a released object may still be used by commands it
    /// recorded, so destroys wait (WebGPU lets an object be released while an unsubmitted encoder uses it).
    open_encoders: u32 = 0,
    encoders: Pool(EncoderSlot) = .{},
    command_buffers: Pool(CommandBufferSlot) = .{},
    buffers: Pool(BufferSlot) = .{},
    textures: Pool(TextureSlot) = .{},
    samplers: Pool(SamplerSlot) = .{},
    shader_modules: Pool(ShaderModuleSlot) = .{},
    bind_group_layouts: Pool(BindGroupLayoutSlot) = .{},
    bind_groups: Pool(BindGroupSlot) = .{},
    pipeline_layouts: Pool(PipelineLayoutSlot) = .{},
    render_pipelines: Pool(PipelineSlot) = .{},
    render_passes: Pool(PassSlot) = .{},
    compute_pipelines: Pool(PipelineSlot) = .{},
    compute_passes: Pool(PassSlot) = .{},
    reads: Pool(ReadSlot) = .{},
    /// Descriptor pool pages, oldest first. A bind group's set comes from the newest page with room; a new page is
    /// added only when every page is full, so sets freed in older pages are used again.
    descriptor_pages: ArrayList(DescriptorPage) = .empty,
    /// The set layout with no bindings, made on first need: a pipeline layout's empty group slots use it.
    empty_set_layout: vk.DescriptorSetLayout = .null_handle,
    staging: Staging = .{},
    /// Released while an encoder was open: numbered by the first submit after the last encoder closes.
    pending_destroys: ArrayList(Destroy) = .empty,
    retiring_destroys: ArrayList(RetiringDestroy) = .empty,
};

// One host per process, as a browser page has one GPU device. It is a module global for the same reason as
// `wgpu_app`'s `active_app`: the calls arrive as free functions, with no context argument to carry it.
// lint:off module-var: the process's one host; the calls carry no context that could hold it instead
var host: ?*Host = null;

/// The running host. Every GPU call goes through it, so a call made before a window is attached or a headless
/// host is started is reported by name.
fn theHost() *Host {
    return host orelse panic("vulkan host: none started - attach a window, or start a headless host, first", .{});
}

/// An integer the engine passed across the host boundary, as the enumeration it stands for. The browser's calls carry
/// enumerations as their numbers, and the same entry points serve this host; a number the enumeration does not have
/// ends the program, naming the argument (`what`), rather than turning silently into some other value.
fn enumFromValue(comptime Enum: type, value: u32, what: []const u8) Enum {
    return std.enums.fromInt(Enum, value) orelse panic("vulkan host: {s} has no value {d}", .{ what, value });
}

/// Every allocation failure inside a GPU call ends the program here: the calls cannot return errors (their browser
/// twins cannot either), and a GPU host that has run out of memory has nothing sensible left to draw.
fn outOfMemory() noreturn {
    panic("vulkan host: out of memory", .{});
}

/// The host's window; a headless host has none, and fails by name where a window is needed.
fn theWindow(self: *Host) *win32.Window {
    return self.window orelse panic("vulkan host: this host is headless - no window, no surface", .{});
}

/// Gives the host the window it draws into. The native loop calls this after opening the window and before the
/// engine's first GPU call; Vulkan itself comes up in `initDevice`.
pub fn attachWindow(window: *win32.Window) Allocator.Error!void {
    if (host != null) {
        panic("vulkan host: a host has already started", .{});
    }
    const created: *Host = try heap.create(Host);
    created.* = .{ .gpa = heap, .window = window };
    host = created;
}

/// Starts a host without a window: it draws only into textures, and asks the GPU for nothing a window needs (no
/// surface, no swapchain). The host's tests run this way - on Linux too, on Mesa's software driver. Vulkan comes up
/// in `initDevice`, as with a window; the surface calls fail by name.
pub fn startHeadless() Allocator.Error!void {
    if (host != null) {
        panic("vulkan host: a host has already started", .{});
    }
    const created: *Host = try heap.create(Host);
    created.* = .{ .gpa = heap, .window = null };
    host = created;
}

/// The host's screen; a host with a window, or headless without a screen, has none, and fails by name.
fn theScreen(self: *Host) *Screen {
    if (self.screen) |*screen| {
        return screen;
    }
    panic("vulkan host: this host has no screen - start it with `startHeadlessWithScreen` to draw frames", .{});
}

/// Starts a host without a window but with a screen of `width` by `height` pixels (`Screen`): a program draws its
/// frames as it would into a window, and they can be read back from `headlessScreenTexture` - how programs run
/// headless with their frames captured.
pub fn startHeadlessWithScreen(width: u32, height: u32) Allocator.Error!void {
    try startHeadless();
    theHost().screen = .{ .width = @max(width, 1), .height = @max(height, 1) };
}

/// The texture a headless host's screen draws into, for the copies that read its frames back; 0 until the engine has
/// asked for the surface, which makes it.
pub fn headlessScreenTexture() u32 {
    return theScreen(theHost()).texture;
}

/// A headless host's screen size in pixels: width, then height.
pub fn headlessScreenSize() [2]u32 {
    const screen: *Screen = theScreen(theHost());
    return .{ screen.width, screen.height };
}

/// How many frames have been drawn on a headless host's screen (`Screen.drawn_frame_count`).
pub fn headlessScreenDrawnFrameCount() u64 {
    return theScreen(theHost()).drawn_frame_count;
}

/// The validation layer's messages so far (all zero when it is off): a headless test asserts them before shutting
/// down, when the layer's own leak report at device destruction is not yet in.
pub fn messageCounts() MessageCounts {
    return theHost().counts;
}

/// Whether the validation layer is on: without it, `messageCounts` stays zero and proves nothing.
pub fn isValidating() bool {
    return theHost().messenger != .null_handle;
}

/// What the host holds that could grow without bound if reclaiming failed: descriptor pool pages, staging chunks,
/// and destroys still waiting for the GPU. A test drives the host for many frames and checks these stay small.
pub const Statistics = struct {
    descriptor_pages: usize,
    staging_chunks: usize,
    waiting_destroys: usize,
};

/// The host's current counts, as `Statistics` describes them.
pub fn statistics() Statistics {
    const self: *Host = theHost();
    return .{
        .descriptor_pages = self.descriptor_pages.items.len,
        .staging_chunks = self.staging.chunks.items.len,
        .waiting_destroys = self.retiring_destroys.items.len + self.pending_destroys.items.len,
    };
}

// ---- Bring-up: instance, surface, GPU, device ----
//
// Before the first buffer exists, a Vulkan program builds a chain of objects, each needing the one before:
//
//     loader     the Vulkan library (`native_os.openVulkanLibrary`), and the one command taken from it by name
//     instance   the program's connection to the loader: the API version, the layers, the instance extensions
//     surface    the window's drawable area, which the chosen GPU must be able to present to (only with a window)
//     GPU        a physical device with the features the host relies on, and a queue family that can run it
//     device     the program's handle on that GPU: its features enabled, its queue - then every other object
//
// Vulkan answers "which layers, extensions, devices or queue families are there?" with a TWO-CALL ENUMERATION: called
// with no array, a command reports how many items there are; called again with an array that long, it fills it. The
// lookups below all work that way.

/// Why bring-up stopped, besides an error reported by Vulkan itself.
const BringUpError = error{
    /// The loader offers an API version below 1.3, which the host is written against: dynamic rendering and
    /// synchronization2 are core from 1.3 (timeline semaphores from 1.2).
    VulkanTooOld,
    /// No GPU has the features the host relies on, and a queue family that can run it.
    NoSuitableGpu,
    /// `ZIMR_GPU` names a GPU - by index or by part of its name - that is not among the suitable ones.
    RequestedGpuNotFound,
    /// The window's surface offers no format the host can present.
    NoSurfaceFormat,
} || vk.ResultError || vk.LoadError || native_os.VulkanLibraryError || Allocator.Error;

/// The debug messenger's callback. The validation layer calls it - usually during the call it reports, on that call's
/// thread - for each message at the severities the messenger asked for, warnings and errors. Each is logged and counted
/// in the host's `MessageCounts` (passed as `user_data`); an error also fails the report at exit. The message types
/// (general, validation, performance) are not needed: the severity decides how a message is logged. The return value
/// tells the layer whether to abort the call it reports; Vulkan reserves `true` for developing layers, so it is
/// `false`.
fn debugMessage(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: *const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(vk.call_conv) vk.Bool32 {
    _ = message_types;
    const counts: *MessageCounts = @ptrCast(@alignCast(user_data orelse return vk.bool_false));
    const text: [*:0]const u8 = callback_data.p_message orelse "(no message)";
    if (message_severity.@"error") {
        counts.errors += 1;
        log.err("validation: {s}", .{text});
    } else {
        counts.warnings += 1;
        log.warn("validation: {s}", .{text});
    }
    return vk.bool_false;
}

/// Whether the Vulkan loader offers the instance layer `name`. The validation layer is installed apart from the
/// driver - with the Vulkan SDK, or a distribution's package - so its presence is asked, never assumed.
fn hasInstanceLayer(self: *Host, name: [*:0]const u8) BringUpError!bool {
    var count: u32 = 0;
    try vk.check(self.global.enumerateInstanceLayerProperties(&count, null));
    const layers: []vk.LayerProperties = try self.gpa.alloc(vk.LayerProperties, count);
    defer self.gpa.free(layers);
    try vk.check(self.global.enumerateInstanceLayerProperties(&count, layers.ptr));
    const wanted: []const u8 = span(name);
    for (layers[0..count]) |layer| {
        const layer_name: []const u8 = vk.fixedName(&layer.layer_name);
        if (eql(u8, layer_name, wanted)) {
            return true;
        }
    }
    return false;
}

/// Whether `extensions` lists the extension `name`: the search the instance and device extension lookups share.
fn hasExtensionNamed(extensions: []const vk.ExtensionProperties, name: [*:0]const u8) bool {
    const wanted: []const u8 = span(name);
    for (extensions) |extension| {
        const extension_name: []const u8 = vk.fixedName(&extension.extension_name);
        if (eql(u8, extension_name, wanted)) {
            return true;
        }
    }
    return false;
}

/// Whether the Vulkan loader offers the instance extension `name` - an extension of the instance itself, such as the
/// window system's surfaces or the debug messenger.
fn hasInstanceExtension(self: *Host, name: [*:0]const u8) BringUpError!bool {
    var count: u32 = 0;
    try vk.check(self.global.enumerateInstanceExtensionProperties(null, &count, null));
    const extensions: []vk.ExtensionProperties = try self.gpa.alloc(vk.ExtensionProperties, count);
    defer self.gpa.free(extensions);
    try vk.check(self.global.enumerateInstanceExtensionProperties(null, &count, extensions.ptr));
    return hasExtensionNamed(extensions[0..count], name);
}

/// The instance, the program's connection to the Vulkan loader, created with
///
///     an API version   1.3, the version the host is written against, which the loader must offer
///     its layers       the validation layer, when it is installed and not turned off (`ZIMR_VK_VALIDATE=0`)
///     its extensions   the window system's surfaces with a window; the debug-utils extension with validation
///
/// and, with validation, its debug messenger - the object through which the validation layer reports each problem it
/// finds (`debugMessage`). The instance's dispatch tables are loaded once it exists.
fn createInstance(self: *Host, get_instance_proc_address: vk.PfnGetInstanceProcAddr) BringUpError!void {
    // The loader's own version: the highest API version an instance can ask it for.
    var version: u32 = 0;
    try vk.check(self.global.enumerateInstanceVersion(&version));
    if (version < vk.api_version_1_3) {
        return BringUpError.VulkanTooOld;
    }
    var setting_buffer: [16]u8 = undefined;
    const validation_setting: ?[]const u8 = native_os.environmentVariable("ZIMR_VK_VALIDATE", &setting_buffer);
    const validation_wanted: bool = if (validation_setting) |setting| !eql(u8, setting, "0") else true;
    // Validation runs when it is wanted and possible: the layer installed, and the debug-utils extension - through
    // which the layer's messages reach the messenger - available.
    const has_validation_layer: bool = try hasInstanceLayer(self, vk.khronos_validation_layer_name);
    const has_debug_utils: bool = try hasInstanceExtension(self, vk.ext_debug_utils_extension_name);
    const validate: bool = validation_wanted and has_validation_layer and has_debug_utils;

    const layers = [_][*:0]const u8{vk.khronos_validation_layer_name};
    // The window-system extensions only with a window; the messenger's only with the validation layer.
    var extensions: [3][*:0]const u8 = undefined;
    var extension_count: u32 = 0;
    if (self.window != null) {
        extensions[0] = vk.khr_surface_extension_name;
        extensions[1] = vk.khr_win32_surface_extension_name;
        extension_count = 2;
    }
    if (validate) {
        extensions[extension_count] = vk.ext_debug_utils_extension_name;
        extension_count += 1;
    }
    const application_info: vk.ApplicationInfo = .{
        .p_application_name = "zimr",
        .p_engine_name = "zimr",
        .api_version = vk.api_version_1_3,
    };
    // The messenger's description serves twice: for the messenger created below, and in the instance's `p_next`
    // chain. A `p_next` chain extends a create-info with further structures, each pointing to the next; this one makes
    // the loader report through a temporary messenger while the instance itself is created, so that call is validated
    // too.
    const messenger_info: vk.DebugUtilsMessengerCreateInfoEXT = .{
        .message_severity = .{ .warning = true, .@"error" = true },
        .message_type = .{ .general = true, .validation = true, .performance = true },
        .pfn_user_callback = @ptrCast(&debugMessage),
        .p_user_data = &self.counts,
    };
    const instance_info: vk.InstanceCreateInfo = .{
        .p_next = if (validate) &messenger_info else null,
        .p_application_info = &application_info,
        .enabled_layer_count = if (validate) 1 else 0,
        .pp_enabled_layer_names = &layers,
        .enabled_extension_count = extension_count,
        .pp_enabled_extension_names = &extensions,
    };
    try vk.check(self.global.createInstance(&instance_info, null, &self.instance));
    // The instance's commands are looked up through the instance; its window-system commands only with a window.
    self.instance_dispatch = try vk.loadInstanceDispatch(get_instance_proc_address, self.instance);
    if (self.window != null) {
        self.surface_dispatch = try vk.loadSurfaceDispatch(get_instance_proc_address, self.instance);
    }
    // The messenger's commands are optional in the table: they exist only with the debug-utils extension enabled.
    if (validate) {
        if (self.instance_dispatch.createDebugUtilsMessengerEXT) |create_messenger| {
            try vk.check(create_messenger(self.instance, &messenger_info, null, &self.messenger));
        }
    }
    log.info("Vulkan {d}.{d}, validation {s}", .{
        vk.apiVersionMajor(version),
        vk.apiVersionMinor(version),
        if (self.messenger != .null_handle) "on" else "off",
    });
}

/// How strongly a kind of device is preferred when no GPU is named: a discrete GPU first, then an integrated one,
/// then a virtual one; software devices (lavapipe), and any type a newer driver may report, last.
fn typeRank(device_type: vk.PhysicalDeviceType) u32 {
    return switch (device_type) {
        .discrete_gpu => 3,
        .integrated_gpu => 2,
        .virtual_gpu => 1,
        else => 0,
    };
}

/// Whether `physical_device` offers `VK_KHR_swapchain`, a device extension: a GPU that cannot present is of no use to
/// a host with a window.
fn hasSwapchainExtension(self: *Host, physical_device: vk.PhysicalDevice) BringUpError!bool {
    var count: u32 = 0;
    try vk.check(self.instance_dispatch.enumerateDeviceExtensionProperties(physical_device, null, &count, null));
    const extensions: []vk.ExtensionProperties = try self.gpa.alloc(vk.ExtensionProperties, count);
    defer self.gpa.free(extensions);
    try vk.check(self.instance_dispatch.enumerateDeviceExtensionProperties(
        physical_device,
        null,
        &count,
        extensions.ptr,
    ));
    return hasExtensionNamed(extensions[0..count], vk.khr_swapchain_extension_name);
}

/// The queue family the host would use on `physical_device`, or null when that GPU cannot run the host. A GPU's
/// queues come in families, each running some kinds of work - graphics, compute, transfers - and some able to present
/// to a given surface. The host submits everything to one queue, so it needs one family that renders, computes and,
/// with a window, presents. A suitable GPU also offers Vulkan 1.3, the features the host relies on, and - with a
/// window - the swapchain extension.
fn suitableQueueFamily(
    self: *Host,
    physical_device: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
) BringUpError!?u32 {
    if (properties.api_version < vk.api_version_1_3) {
        return null;
    }
    // The features, asked in one call through a `p_next` chain: the core structure points to the Vulkan 1.2
    // features, which point to the 1.3 ones, and the driver fills all three.
    var vulkan_13: vk.PhysicalDeviceVulkan13Features = .{};
    var vulkan_12: vk.PhysicalDeviceVulkan12Features = .{ .p_next = &vulkan_13 };
    var features: vk.PhysicalDeviceFeatures2 = .{ .p_next = &vulkan_12 };
    self.instance_dispatch.getPhysicalDeviceFeatures2(physical_device, &features);
    // The features the host relies on, which `createDevice` enables: render passes begun without render-pass
    // objects, the newer barriers and submissions, layouts released once the objects made from them exist, one
    // counter numbering every submission, and out-of-bounds buffer accesses kept inside their buffers.
    const has_dynamic_rendering: bool = vulkan_13.dynamic_rendering == vk.bool_true;
    const has_synchronization_2: bool = vulkan_13.synchronization_2 == vk.bool_true;
    const has_maintenance_4: bool = vulkan_13.maintenance_4 == vk.bool_true;
    const has_timeline_semaphores: bool = vulkan_12.timeline_semaphore == vk.bool_true;
    const has_robust_buffer_access: bool = features.features.robust_buffer_access == vk.bool_true;
    const has_features: bool = has_dynamic_rendering and has_synchronization_2 and has_maintenance_4 and
        has_timeline_semaphores and has_robust_buffer_access;
    if (!has_features) {
        return null;
    }
    const needs_presenting: bool = self.window != null;
    if (needs_presenting and !try hasSwapchainExtension(self, physical_device)) {
        return null;
    }
    // The queue families, by the two-call enumeration.
    var family_count: u32 = 0;
    self.instance_dispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);
    const families: []vk.QueueFamilyProperties = try self.gpa.alloc(vk.QueueFamilyProperties, family_count);
    defer self.gpa.free(families);
    self.instance_dispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);
    for (families[0..family_count], 0..) |family, index| {
        const renders_and_computes: bool = family.queue_flags.graphics and family.queue_flags.compute;
        if (!renders_and_computes) {
            continue;
        }
        const family_index: u32 = @intCast(index);
        if (!needs_presenting) {
            return family_index;
        }
        // On a laptop with two GPUs, the one that does not drive the display may not present to it: ask.
        var presents: vk.Bool32 = vk.bool_false;
        try vk.check(self.surface_dispatch.getPhysicalDeviceSurfaceSupportKHR(
            physical_device,
            family_index,
            self.surface,
            &presents,
        ));
        if (presents == vk.bool_true) {
            return family_index;
        }
    }
    return null;
}

/// The GPU the host runs on. Every GPU is logged, with whether it can run the host; among those that can, the one
/// `ZIMR_GPU` names - its index in the log, or part of its name, the last match winning - or else the best by type
/// (`typeRank`).
fn chooseGpu(self: *Host) BringUpError!Gpu {
    var choice_buffer: [128]u8 = undefined;
    const choice: ?[]const u8 = native_os.environmentVariable("ZIMR_GPU", &choice_buffer);
    var count: u32 = 0;
    try vk.check(self.instance_dispatch.enumeratePhysicalDevices(self.instance, &count, null));
    const physical_devices: []vk.PhysicalDevice = try self.gpa.alloc(vk.PhysicalDevice, count);
    defer self.gpa.free(physical_devices);
    try vk.check(self.instance_dispatch.enumeratePhysicalDevices(self.instance, &count, physical_devices.ptr));

    var best: ?Gpu = null;
    var requested: ?Gpu = null;
    for (physical_devices[0..count], 0..) |physical_device, index| {
        var properties: vk.PhysicalDeviceProperties = .{};
        self.instance_dispatch.getPhysicalDeviceProperties(physical_device, &properties);
        const name: []const u8 = vk.fixedName(&properties.device_name);
        const queue_family: ?u32 = try suitableQueueFamily(self, physical_device, properties);
        log.info("GPU {d}: {s} ({s}){s}", .{
            index,
            name,
            @tagName(properties.device_type),
            if (queue_family == null) " - cannot run the host" else "",
        });
        const family: u32 = queue_family orelse continue;
        const candidate: Gpu = .{
            .physical_device = physical_device,
            .name = properties.device_name,
            .device_type = properties.device_type,
            .vendor_id = properties.vendor_id,
            .api_version = properties.api_version,
            .queue_family = family,
            .max_memory_allocations = properties.limits.max_memory_allocation_count,
            .max_bound_descriptor_sets = properties.limits.max_bound_descriptor_sets,
        };
        if (choice) |wanted| {
            const index_wanted: ?usize = parseInt(usize, wanted, 10) catch null;
            const matches_index: bool = index_wanted != null and index_wanted.? == index;
            const matches_name: bool = indexOf(u8, name, wanted) != null;
            if (matches_index or matches_name) {
                requested = candidate;
            }
        }
        const ranks_higher: bool = best == null or typeRank(candidate.device_type) > typeRank(best.?.device_type);
        if (ranks_higher) {
            best = candidate;
        }
    }
    if (choice != null and requested == null) {
        return BringUpError.RequestedGpuNotFound;
    }
    const chosen: Gpu = requested orelse best orelse return BringUpError.NoSuitableGpu;
    log.info("using {s}", .{vk.fixedName(&chosen.name)});
    return chosen;
}

/// The device: the program's handle on the chosen GPU, through which every later object is made. Creating it asks for
/// one queue from the chosen family, enables exactly the features the host stands on - a feature the GPU merely
/// offers is not on until it is enabled here - and, with a window, the swapchain extension. The device's dispatch
/// tables are loaded once it exists, and its queue is fetched.
fn createDevice(self: *Host) BringUpError!void {
    // One queue, at the highest priority (priorities only rank a device's queues against each other).
    const priority: f32 = 1.0;
    const queue_info: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = self.gpu.queue_family,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priority),
    };
    // The features to enable, through the same `p_next` chain that asked for them: Vulkan 1.3's dynamic rendering,
    // synchronization2 and maintenance4, Vulkan 1.2's timeline semaphores, and two core features below.
    //
    // maintenance4 is WebGPU's order of release: an app may release a bind group layout as soon as the pipeline layouts
    // made from it exist, as `compute_host` does for every kernel. Without the feature, a pipeline layout is valid only
    // while its descriptor set layouts are, and a pipeline made from it cannot be bound once they are destroyed. Every
    // Vulkan 1.3 device has it. (The pipeline layout itself must still outlive the commands recorded with it, which
    // the host's count of a layout's pipelines sees to.)
    var vulkan_13: vk.PhysicalDeviceVulkan13Features = .{
        .dynamic_rendering = vk.bool_true,
        .synchronization_2 = vk.bool_true,
        .maintenance_4 = vk.bool_true,
    };
    var vulkan_12: vk.PhysicalDeviceVulkan12Features = .{ .p_next = &vulkan_13, .timeline_semaphore = vk.bool_true };
    var supported: vk.PhysicalDeviceFeatures2 = .{};
    self.instance_dispatch.getPhysicalDeviceFeatures2(self.gpu.physical_device, &supported);
    // WebGPU bounds-checks every buffer access; robust buffer access keeps out-of-bounds behaviour alike. Vertex
    // stores are enabled when offered (every desktop GPU does): a vertex-stage storage buffer the legalizer cannot
    // prove read-only (its pointer passed into a function) stays undecorated, which is legal only with this feature.
    const features: vk.PhysicalDeviceFeatures2 = .{
        .p_next = &vulkan_12,
        .features = .{
            .robust_buffer_access = vk.bool_true,
            .vertex_pipeline_stores_and_atomics = supported.features.vertex_pipeline_stores_and_atomics,
        },
    };
    const extensions = [_][*:0]const u8{vk.khr_swapchain_extension_name};
    const extension_count: u32 = if (self.window != null) 1 else 0;
    const device_info: vk.DeviceCreateInfo = .{
        .p_next = &features,
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&queue_info),
        .enabled_extension_count = extension_count,
        .pp_enabled_extension_names = &extensions,
    };
    try vk.check(self.instance_dispatch.createDevice(self.gpu.physical_device, &device_info, null, &self.device));
    self.device_dispatch = try vk.loadDeviceDispatch(self.instance_dispatch.getDeviceProcAddr, self.device);
    if (self.window != null) {
        self.swapchain_dispatch = try vk.loadSwapchainDispatch(self.instance_dispatch.getDeviceProcAddr, self.device);
    }
    self.device_dispatch.getDeviceQueue(self.device, self.gpu.queue_family, 0, &self.queue);
}

/// A binary semaphore: a flag signalled by one GPU operation and waited on by one other - the handshakes between
/// acquiring an image, rendering into it and presenting it.
fn createBinarySemaphore(self: *Host) BringUpError!vk.Semaphore {
    const semaphore_info: vk.SemaphoreCreateInfo = .{};
    var semaphore: vk.Semaphore = .null_handle;
    try vk.check(self.device_dispatch.createSemaphore(self.device, &semaphore_info, null, &semaphore));
    return semaphore;
}

/// The objects every frame uses:
///
///     the command pool        where command buffers come from; each can be reset on its own, so a finished one is
///                             recorded again
///     the timeline            a semaphore holding a counter rather than a flag (its type given in a `p_next`
///                             structure), which numbers every submission
///     the acquire semaphores  one per frame slot, signalled when the presentation engine hands over an image
fn createFrameObjects(self: *Host) BringUpError!void {
    const pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = self.gpu.queue_family,
    };
    try vk.check(self.device_dispatch.createCommandPool(self.device, &pool_info, null, &self.command_pool));
    const timeline_type: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = .timeline, .initial_value = 0 };
    const timeline_info: vk.SemaphoreCreateInfo = .{ .p_next = &timeline_type };
    try vk.check(self.device_dispatch.createSemaphore(self.device, &timeline_info, null, &self.timeline));
    for (&self.acquire_semaphores) |*semaphore| {
        semaphore.* = try createBinarySemaphore(self);
    }
}

/// Everything from the loader to the device, in order: each step needs the one before (the surface comes before
/// the GPU choice, because presenting to it is part of what makes a GPU suitable). A headless host skips every
/// window-system step.
fn bringUp(self: *Host) BringUpError!void {
    const library: native_os.VulkanLibrary = try native_os.openVulkanLibrary();
    self.library = library;
    const get_instance_proc_address: vk.PfnGetInstanceProcAddr = library.get_instance_proc_address;
    self.global = try vk.loadGlobalDispatch(get_instance_proc_address);
    try createInstance(self, get_instance_proc_address);
    // The window's surface: Win32's, from the window's module and handle.
    if (self.window) |window| {
        var surface_info: vk.Win32SurfaceCreateInfoKHR = .{
            .hinstance = window.module,
            .hwnd = window.handle,
        };
        try vk.check(self.surface_dispatch.createWin32SurfaceKHR(self.instance, &surface_info, null, &self.surface));
    }
    self.gpu = try chooseGpu(self);
    // Each bind group is a descriptor set, and a pipeline may use all of them at once.
    if (self.gpu.max_bound_descriptor_sets < max_bind_groups) {
        panic("vulkan host: {s} binds {d} descriptor sets; zimr's bind groups need {d}", .{
            vk.fixedName(&self.gpu.name),
            self.gpu.max_bound_descriptor_sets,
            max_bind_groups,
        });
    }
    // The GPU's memory heaps and types, kept for every allocation's choice of type (`memoryTypeIndex`).
    self.instance_dispatch.getPhysicalDeviceMemoryProperties(self.gpu.physical_device, &self.memory_properties);
    try createDevice(self);
    try createFrameObjects(self);
}

// ---- Memory, names and destroys ----
//
// Vulkan describes a GPU's memory as a few HEAPS (video memory, system memory) and MEMORY TYPES on them, each with
// properties: device-local (fast for the GPU), host-visible (the CPU can map it), host-coherent (no flushes needed),
// host-cached (fast for the CPU to read). A resource reports which types may hold it as a bit mask - bit i set means
// type i - and the program chooses one and allocates from it. The host gives every resource an allocation of its own,
// names objects for the validation layer's messages, and destroys an object only once the GPU can no longer be using
// it.

/// The first memory type that `type_bits` allows and that has every property in `required`, as an index into the
/// GPU's list of types; null when there is none. `type_bits` is a resource's mask of acceptable types.
fn memoryTypeIndex(self: *Host, type_bits: u32, required: vk.MemoryPropertyFlags) ?u32 {
    const type_count: u32 = self.memory_properties.memory_type_count;
    const types: []const vk.MemoryType = self.memory_properties.memory_types[0..type_count];
    for (types, 0..) |memory_type, index| {
        const type_bit: u32 = @as(u32, 1) << @intCast(index);
        const is_allowed: bool = type_bits & type_bit != 0;
        const has_properties: bool = vk.hasAllFlags(vk.MemoryPropertyFlags, memory_type.property_flags, required);
        if (is_allowed and has_properties) {
            return @intCast(index);
        }
    }
    return null;
}

/// One allocation for one resource - each resource has its own, until a measurement asks for sub-allocation. The
/// type is the first with both the `preferred` and the `required` properties, else the first with the `required`
/// ones. Drivers limit how many allocations may exist at once (often 4096), so the host stops at 80% of the limit,
/// naming the allocation, rather than at an error from deep inside the driver.
fn allocateMemory(
    self: *Host,
    requirements: vk.MemoryRequirements,
    required: vk.MemoryPropertyFlags,
    preferred: vk.MemoryPropertyFlags,
    label: []const u8,
) BringUpError!vk.DeviceMemory {
    const allocation_ceiling: u32 = self.gpu.max_memory_allocations / 10 * 8;
    if (self.allocations >= allocation_ceiling) {
        panic("vulkan host: {d} live allocations, 80% of the device's limit, allocating `{s}`", .{
            self.allocations,
            label,
        });
    }
    const allowed_types: u32 = requirements.memory_type_bits;
    const both: vk.MemoryPropertyFlags = vk.mergeFlags(vk.MemoryPropertyFlags, preferred, required);
    const preferred_type: ?u32 = memoryTypeIndex(self, allowed_types, both);
    const required_type: ?u32 = memoryTypeIndex(self, allowed_types, required);
    const type_index: u32 = preferred_type orelse required_type orelse
        panic("vulkan host: no memory type for `{s}`", .{label});
    const allocate_info: vk.MemoryAllocateInfo = .{
        .allocation_size = requirements.size,
        .memory_type_index = type_index,
    };
    var memory: vk.DeviceMemory = .null_handle;
    const result: vk.Result = self.device_dispatch.allocateMemory(self.device, &allocate_info, null, &memory);
    if (result != .success) {
        panic("vulkan host: allocating {d} bytes for `{s}` failed: {s}", .{
            requirements.size,
            label,
            @tagName(result),
        });
    }
    self.allocations += 1;
    return memory;
}

/// Puts a zimr label on a Vulkan object, so that the validation layer's messages name it, as Dawn's messages do on
/// the web. Names serve only those messages, so naming happens only with the messenger, and is best-effort: its
/// result changes nothing the host does. A label is cut at 128 bytes, ample for zimr's labels.
fn nameObject(
    self: *Host,
    object_type: vk.ObjectType,
    object_handle: u64,
    label: []const u8,
) void {
    if (label.len == 0 or self.messenger == .null_handle) {
        return;
    }
    const set_name: vk.PfnSetDebugUtilsObjectNameEXT =
        self.device_dispatch.setDebugUtilsObjectNameEXT orelse return;
    var name_buffer: [128:0]u8 = @splat(0);
    const name_length: usize = @min(label.len, name_buffer.len);
    @memcpy(name_buffer[0..name_length], label[0..name_length]);
    const name_info: vk.DebugUtilsObjectNameInfoEXT = .{
        .object_type = object_type,
        .object_handle = object_handle,
        .p_object_name = &name_buffer,
    };
    _ = set_name(self.device, &name_info);
}

/// Destroys one released object, now that the GPU has finished every submission that could use it. A buffer or an
/// image also frees its memory allocation (each has its own), lowering the count `allocateMemory` checks; a bind
/// group's descriptor set goes back to its pool page, which then has room again.
fn executeDestroy(self: *Host, destroy: Destroy) void {
    switch (destroy) {
        .buffer => |buffer| {
            self.device_dispatch.destroyBuffer(self.device, buffer.buffer, null);
            self.device_dispatch.freeMemory(self.device, buffer.memory, null);
            self.allocations -= 1;
        },
        .image => |image| {
            self.device_dispatch.destroyImage(self.device, image.image, null);
            self.device_dispatch.freeMemory(self.device, image.memory, null);
            self.allocations -= 1;
        },
        .image_view => |view| self.device_dispatch.destroyImageView(self.device, view, null),
        .sampler => |sampler| self.device_dispatch.destroySampler(self.device, sampler, null),
        .descriptor_set => |group| {
            const page: *DescriptorPage = &self.descriptor_pages.items[group.page];
            const sets = [_]vk.DescriptorSet{group.set};
            _ = self.device_dispatch.freeDescriptorSets(self.device, page.pool, 1, &sets);
            page.has_room = true;
        },
        .descriptor_set_layout => |layout| self.device_dispatch.destroyDescriptorSetLayout(self.device, layout, null),
        .pipeline_layout => |layout| self.device_dispatch.destroyPipelineLayout(self.device, layout, null),
        .pipeline => |pipeline| self.device_dispatch.destroyPipeline(self.device, pipeline, null),
    }
}

/// Releases a Vulkan object once nothing can still use it. WebGPU lets a program release an object the GPU may still be
/// using; Vulkan requires the program to wait. So the object is numbered with the submission that could last use it
/// - the next one while commands are unsubmitted (an open encoder, or pending writes), else the last one - and
/// destroyed when the timeline passes that number (`retireDestroys`).
fn deferDestroy(self: *Host, destroy: Destroy) Allocator.Error!void {
    // Commands not yet submitted - an open encoder's, or the write calls' in `uploads` (a buffer created, written and
    // released before any submit) - may use the object: it waits for the number of the submit that carries them.
    if (self.open_encoders > 0 or self.uploads != .null_handle) {
        try self.pending_destroys.append(self.gpa, destroy);
    } else {
        try self.retiring_destroys.append(self.gpa, .{ .serial = self.submitted, .destroy = destroy });
    }
}

// ---- Command buffers and the timeline ----
//
// Commands are recorded into COMMAND BUFFERS and handed to the queue in SUBMISSIONS. The host numbers every submission
// on the TIMELINE, a semaphore holding a counter that the GPU raises to a submission's number as it finishes it.
// Everything a submission consumed - its command buffers, the staging memory of its writes, the objects released
// while it was recorded - is reclaimed once the counter passes its number.

/// Waits until the timeline reaches `value`: every submission numbered `value` or lower has finished. `completed`
/// remembers the highest value seen, so waiting for one already reached costs nothing.
fn waitTimeline(self: *Host, value: u64) vk.ResultError!void {
    if (value <= self.completed) {
        return;
    }
    const semaphores = [_]vk.Semaphore{self.timeline};
    const values = [_]u64{value};
    const wait_info: vk.SemaphoreWaitInfo = .{
        .semaphore_count = 1,
        .p_semaphores = &semaphores,
        .p_values = &values,
    };
    try vk.check(self.device_dispatch.waitSemaphores(self.device, &wait_info, no_timeout));
    self.completed = value;
}

/// Returns to the free list each command buffer whose submission has finished; the others keep their order.
fn retireCommandBuffers(self: *Host) Allocator.Error!void {
    var kept: usize = 0;
    for (self.retiring_command_buffers.items) |retiring| {
        if (retiring.serial <= self.completed) {
            try self.free_command_buffers.append(self.gpa, retiring.command_buffer);
        } else {
            self.retiring_command_buffers.items[kept] = retiring;
            kept += 1;
        }
    }
    self.retiring_command_buffers.shrinkRetainingCapacity(kept);
}

/// Frees each staging chunk whose submission has finished - emptied, and back on the free list. The others keep their
/// submission order, which `waitForOldestStagingChunk` relies on.
fn retireStagingChunks(self: *Host) Allocator.Error!void {
    var kept_chunks: usize = 0;
    for (self.staging.retiring.items) |retiring| {
        if (retiring.serial <= self.completed) {
            self.staging.chunks.items[retiring.index].used = 0;
            try self.staging.free.append(self.gpa, retiring.index);
        } else {
            self.staging.retiring.items[kept_chunks] = retiring;
            kept_chunks += 1;
        }
    }
    self.staging.retiring.shrinkRetainingCapacity(kept_chunks);
}

/// Destroys each released object whose submission has finished; the others keep their order.
fn retireDestroys(self: *Host) void {
    var kept_destroys: usize = 0;
    for (self.retiring_destroys.items) |retiring| {
        if (retiring.serial <= self.completed) {
            executeDestroy(self, retiring.destroy);
        } else {
            self.retiring_destroys.items[kept_destroys] = retiring;
            kept_destroys += 1;
        }
    }
    self.retiring_destroys.shrinkRetainingCapacity(kept_destroys);
}

/// How far the GPU has come: the number of the last batch it has finished, read from the timeline's counter without
/// waiting, and kept in `completed` (which only grows).
fn readCompleted(self: *Host) BringUpError!u64 {
    var counter: u64 = 0;
    try vk.check(self.device_dispatch.getSemaphoreCounterValue(self.device, self.timeline, &counter));
    self.completed = @max(self.completed, counter);
    return self.completed;
}

/// Reads how far the GPU has come, and reclaims everything it has finished with. Each list is compacted in place:
/// finished entries are acted on, and the others move down, keeping their submission order.
fn retireCompleted(self: *Host) BringUpError!void {
    _ = try readCompleted(self);
    try retireCommandBuffers(self);
    try retireStagingChunks(self);
    retireDestroys(self);
}

/// A command buffer ready to record one submission's commands: a finished one from the free list, reset, or else a
/// new one from the command pool. It is begun as one-time-submit - recorded, submitted once, then reset - which lets
/// the driver prepare it for exactly that.
fn beginCommandBuffer(self: *Host) BringUpError!vk.CommandBuffer {
    var command_buffer: vk.CommandBuffer = .null_handle;
    if (self.free_command_buffers.pop()) |reusable| {
        command_buffer = reusable;
        try vk.check(self.device_dispatch.resetCommandBuffer(command_buffer, .{}));
    } else {
        const allocate_info: vk.CommandBufferAllocateInfo = .{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        const command_buffers: [*]vk.CommandBuffer = @ptrCast(&command_buffer);
        try vk.check(self.device_dispatch.allocateCommandBuffers(self.device, &allocate_info, command_buffers));
    }
    const begin_info: vk.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit = true } };
    try vk.check(self.device_dispatch.beginCommandBuffer(command_buffer, &begin_info));
    return command_buffer;
}

/// The write calls' command buffer (`uploads`), begun on its first use since the last submission. WebGPU orders a
/// queue's writes before everything submitted after them, so the next submission runs `uploads` first.
fn uploadsCommandBuffer(self: *Host) BringUpError!vk.CommandBuffer {
    if (self.uploads == .null_handle) {
        self.uploads = try beginCommandBuffer(self);
    }
    return self.uploads;
}

/// One memory barrier between everything before it in the command buffer and everything after: every earlier
/// command, of any stage, finishes, and its writes become visible to every later command's reads and writes. This is
/// the host's whole synchronization strategy - correct for any two uses of anything, at the price of no overlap
/// across it.
fn fullBarrier(self: *Host, command_buffer: vk.CommandBuffer) void {
    const barrier: vk.MemoryBarrier2 = .{
        .src_stage_mask = .{ .all_commands = true },
        .src_access_mask = .{ .memory_write = true },
        .dst_stage_mask = .{ .all_commands = true },
        .dst_access_mask = .{ .memory_read = true, .memory_write = true },
    };
    const dependency: vk.DependencyInfo = .{ .memory_barrier_count = 1, .p_memory_barriers = @ptrCast(&barrier) };
    self.device_dispatch.cmdPipelineBarrier2(command_buffer, &dependency);
}

/// Makes every earlier command's writes visible to the CPU. Vulkan keeps the device's memory and the host's apart: a
/// write the GPU made reaches a CPU read only through a barrier whose destination is the host (the `host` stage, the
/// `host_read` access) - a full barrier stops at the queue's own stages, and a semaphore signal moves nothing to the
/// host. Recorded before a read of a buffer (`bufferReadStart`); once the CPU has seen the batch complete on the
/// timeline, the bytes are visible to it, and coherent memory needs no further call.
fn hostReadBarrier(self: *Host, command_buffer: vk.CommandBuffer) void {
    const barrier: vk.MemoryBarrier2 = .{
        .src_stage_mask = .{ .all_commands = true },
        .src_access_mask = .{ .memory_write = true },
        .dst_stage_mask = .{ .host = true },
        .dst_access_mask = .{ .host_read = true },
    };
    const dependency: vk.DependencyInfo = .{ .memory_barrier_count = 1, .p_memory_barriers = @ptrCast(&barrier) };
    self.device_dispatch.cmdPipelineBarrier2(command_buffer, &dependency);
}

/// One color mip level of one layer: a swapchain image, whole.
const single_color_range: vk.ImageSubresourceRange = .{
    .aspect_mask = .{ .color = true },
    .level_count = 1,
    .layer_count = 1,
};

/// A full barrier that also moves `image` from layout `from` to layout `to` - the arrangement of its texels in memory
/// that the next use expects. The host keeps every image in GENERAL, so this happens only at the edges: a new image
/// leaves UNDEFINED, and a swapchain image goes to PRESENT_SRC before the display reads it. The queue-family indices
/// are "ignored": the image stays with the one queue family the host uses.
fn imageBarrier(
    self: *Host,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    range: vk.ImageSubresourceRange,
    from: vk.ImageLayout,
    to: vk.ImageLayout,
) void {
    const barrier: vk.ImageMemoryBarrier2 = .{
        .src_stage_mask = .{ .all_commands = true },
        .src_access_mask = .{ .memory_write = true },
        .dst_stage_mask = .{ .all_commands = true },
        .dst_access_mask = .{ .memory_read = true, .memory_write = true },
        .old_layout = from,
        .new_layout = to,
        .src_queue_family_index = vk.queue_family_ignored,
        .dst_queue_family_index = vk.queue_family_ignored,
        .image = image,
        .subresource_range = range,
    };
    const dependency: vk.DependencyInfo = .{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    };
    self.device_dispatch.cmdPipelineBarrier2(command_buffer, &dependency);
}

/// Numbers with a submitted batch everything it consumed, to be reclaimed when the timeline passes `serial`: its
/// command buffers; the staging chunks its writes came from (the next write starts a fresh chunk); and the objects
/// released while it was recorded - once no encoder is open, since an open one may still record a use.
fn retireWithBatch(
    self: *Host,
    serial: u64,
    command_infos: []const vk.CommandBufferSubmitInfo,
) Allocator.Error!void {
    for (command_infos) |info| {
        const retiring: Retiring = .{ .serial = serial, .command_buffer = info.command_buffer };
        try self.retiring_command_buffers.append(self.gpa, retiring);
    }
    self.uploads = .null_handle;
    for (self.staging.in_use.items) |index| {
        try self.staging.retiring.append(self.gpa, .{ .serial = serial, .index = index });
    }
    self.staging.in_use.clearRetainingCapacity();
    self.staging.current = null;
    if (self.open_encoders == 0) {
        for (self.pending_destroys.items) |destroy| {
            try self.retiring_destroys.append(self.gpa, .{ .serial = serial, .destroy = destroy });
        }
        self.pending_destroys.clearRetainingCapacity();
    }
}

/// Submits one batch - the pending writes (`uploads`, closed by a full barrier), then `commands` (already ended) -
/// numbered on the timeline. The batch waits for the acquired swapchain image if no earlier batch has, and signals
/// the timeline with its number, and `present_semaphore` when it is the batch the present waits for. Everything it
/// consumed is numbered with it (`retireWithBatch`). Returns the number.
fn submitBatch(
    self: *Host,
    commands: vk.CommandBuffer,
    present_semaphore: vk.Semaphore,
) BringUpError!u64 {
    // The command buffers: the pending writes first, so they land before the commands that read them.
    var command_infos: [2]vk.CommandBufferSubmitInfo = undefined;
    var command_count: u32 = 0;
    if (self.uploads != .null_handle) {
        fullBarrier(self, self.uploads);
        try vk.check(self.device_dispatch.endCommandBuffer(self.uploads));
        command_infos[command_count] = .{ .command_buffer = self.uploads };
        command_count += 1;
    }
    // The engine's commands - none in a batch of pending writes alone (`flushUploads`).
    const has_commands: bool = commands != .null_handle;
    if (has_commands) {
        command_infos[command_count] = .{ .command_buffer = commands };
        command_count += 1;
    }

    // The wait: the acquired image's semaphore, by the first batch of commands submitted after the acquire. A batch of
    // writes alone does not touch the image, so the wait stays for the commands that do.
    var wait_infos: [1]vk.SemaphoreSubmitInfo = undefined;
    var wait_count: u32 = 0;
    const waits_for_acquire: bool = has_commands and self.acquired_image != null and !self.acquire_waited;
    if (waits_for_acquire) {
        wait_infos[0] = .{
            .semaphore = self.acquire_semaphores[self.frame_slot],
            .stage_mask = .{ .all_commands = true },
        };
        wait_count = 1;
        self.acquire_waited = true;
    }

    // The signals: the timeline, with this batch's number; and the present semaphore, when one is given.
    const serial: u64 = self.submitted + 1;
    var signal_infos: [2]vk.SemaphoreSubmitInfo = undefined;
    signal_infos[0] = .{
        .semaphore = self.timeline,
        .value = serial,
        .stage_mask = .{ .all_commands = true },
    };
    var signal_count: u32 = 1;
    const presents: bool = present_semaphore != .null_handle;
    if (presents) {
        signal_infos[1] = .{ .semaphore = present_semaphore, .stage_mask = .{ .all_commands = true } };
        signal_count = 2;
    }
    const submit_info: vk.SubmitInfo2 = .{
        .wait_semaphore_info_count = wait_count,
        .p_wait_semaphore_infos = &wait_infos,
        .command_buffer_info_count = command_count,
        .p_command_buffer_infos = &command_infos,
        .signal_semaphore_info_count = signal_count,
        .p_signal_semaphore_infos = &signal_infos,
    };
    try vk.check(self.device_dispatch.queueSubmit2(self.queue, 1, @ptrCast(&submit_info), .null_handle));
    self.submitted = serial;
    try retireWithBatch(self, serial, command_infos[0..command_count]);
    // Every submission also reclaims what earlier ones have finished with. A host without a window never acquires
    // an image, so without this it would never recycle a staging chunk or destroy a released object.
    try retireCompleted(self);
    return serial;
}

/// Submits the pending writes on their own, when there are any - so that work started now (a read) is ordered after
/// them, without waiting for the engine's next submit.
fn flushUploads(self: *Host) BringUpError!void {
    if (self.uploads == .null_handle) {
        return;
    }
    _ = try submitBatch(self, .null_handle, .null_handle);
}

// ---- The swapchain ----
//
// A window's images belong to the PRESENTATION ENGINE, the part of the system that puts them on screen. A swapchain is
// a set of them, lent to the program one at a time: acquired, drawn into, presented, handed back. Its format, color
// space, image count and size are fixed when it is created, so a window that changes size gets a new swapchain
// (`rebuildSwapchain`). The engine sees each image only as a texture view, by a handle that stays the same across
// rebuilds.

/// The surface's format: RGBA8 UNORM when offered, else BGRA8 UNORM - the byte orders the engine renders in - each in
/// the sRGB color space, the standard one: the display shows the stored values as sRGB, as a browser shows a
/// canvas's. A surface with neither fails bring-up by name.
fn chooseSurfaceFormat(self: *Host) BringUpError!vk.SurfaceFormatKHR {
    var count: u32 = 0;
    const physical_device: vk.PhysicalDevice = self.gpu.physical_device;
    try vk.check(self.surface_dispatch.getPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        self.surface,
        &count,
        null,
    ));
    const formats: []vk.SurfaceFormatKHR = try self.gpa.alloc(vk.SurfaceFormatKHR, count);
    defer self.gpa.free(formats);
    try vk.check(self.surface_dispatch.getPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        self.surface,
        &count,
        formats.ptr,
    ));
    const preferred_formats = [_]vk.Format{ .r8g8b8a8_unorm, .b8g8r8a8_unorm };
    for (preferred_formats) |wanted| {
        for (formats[0..count]) |format| {
            const is_wanted_format: bool = format.format == wanted;
            const is_srgb_space: bool = format.color_space == .srgb_nonlinear_khr;
            if (is_wanted_format and is_srgb_space) {
                return format;
            }
        }
    }
    return BringUpError.NoSurfaceFormat;
}

/// How the window system combines the presented image with whatever is behind the window: the first mode the surface
/// supports, opaque first - the image's alpha ignored, the window covering what is behind it. A swapchain may only ask
/// for a mode its surface supports.
fn compositeAlpha(supported: vk.CompositeAlphaFlagsKHR) vk.CompositeAlphaFlagsKHR {
    const preference = [_]vk.CompositeAlphaFlagsKHR{
        .{ .@"opaque" = true },
        .{ .pre_multiplied = true },
        .{ .post_multiplied = true },
        .{ .inherit = true },
    };
    for (preference) |mode| {
        if (vk.hasAllFlags(vk.CompositeAlphaFlagsKHR, supported, mode)) {
            return mode;
        }
    }
    return .{ .@"opaque" = true };
}

/// A swapchain for the window's surface, replacing `old` when given (a rebuild):
///
///     format         `chooseSurfaceFormat`'s
///     image count    one more than the surface's minimum, so one image can be drawn while the display holds another
///     size           the surface's own, or - when it states none - the window's, within the surface's limits
///     usage          rendered into, cleared (a transfer), and copied from
///     presentation   FIFO: images shown in order, one per display refresh, never torn - the one mode every surface
///                    supports
///
/// A window with no area (minimized) gets no swapchain until it has one. Each image's view is refreshed behind the
/// handle it already had, so the engine's view handles survive a rebuild.
fn createSwapchain(self: *Host, old: vk.SwapchainKHR) BringUpError!void {
    var capabilities: vk.SurfaceCapabilitiesKHR = .{};
    try vk.check(self.surface_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(
        self.gpu.physical_device,
        self.surface,
        &capabilities,
    ));
    // The surface's own size when it states one. A surface that leaves the size to the swapchain says so with the
    // largest 32-bit value, and the window's size is used, within the surface's limits.
    const surface_states_size: bool = capabilities.current_extent.width != maxInt(u32);
    var extent: vk.Extent2D = capabilities.current_extent;
    if (!surface_states_size) {
        const window: *win32.Window = theWindow(self);
        extent = .{
            .width = clamp(
                window.client_width,
                capabilities.min_image_extent.width,
                capabilities.max_image_extent.width,
            ),
            .height = clamp(
                window.client_height,
                capabilities.min_image_extent.height,
                capabilities.max_image_extent.height,
            ),
        };
    }
    if (extent.width == 0 or extent.height == 0) {
        return;
    }
    const surface_format: vk.SurfaceFormatKHR = try chooseSurfaceFormat(self);
    // One image more than the surface's minimum, within its maximum - where a maximum of 0 means there is none.
    const one_more_than_minimum: u32 = capabilities.min_image_count + 1;
    const has_maximum: bool = capabilities.max_image_count != 0;
    const image_count: u32 = if (has_maximum)
        @min(one_more_than_minimum, capabilities.max_image_count)
    else
        one_more_than_minimum;
    const swapchain_info: vk.SwapchainCreateInfoKHR = .{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment = true, .transfer_dst = true, .transfer_src = true },
        // One queue family uses the images. The transform is the surface's current one, which declares the content
        // already in the display's orientation: the identity on a desktop display. A rotated display - a phone's -
        // would need the content rendered rotated to match, or the identity here and the compositor rotating each
        // frame. `clipped`: pixels other windows hide need not be rendered.
        .image_sharing_mode = .exclusive,
        .pre_transform = capabilities.current_transform,
        .composite_alpha = compositeAlpha(capabilities.supported_composite_alpha),
        .present_mode = .fifo_khr,
        .clipped = vk.bool_true,
        .old_swapchain = old,
    };
    var handle: vk.SwapchainKHR = .null_handle;
    try vk.check(self.swapchain_dispatch.createSwapchainKHR(self.device, &swapchain_info, null, &handle));
    self.swapchain.handle = handle;
    self.swapchain.format = surface_format.format;
    self.swapchain.extent = extent;

    // The images, by the two-call enumeration, and one present semaphore per image: a present has no fence, so the
    // only moment a present semaphore is known to be free again is when its image is acquired again.
    var count: u32 = 0;
    try vk.check(self.swapchain_dispatch.getSwapchainImagesKHR(self.device, handle, &count, null));
    self.swapchain.images = try self.gpa.alloc(vk.Image, count);
    const images: [*]vk.Image = self.swapchain.images.ptr;
    try vk.check(self.swapchain_dispatch.getSwapchainImagesKHR(self.device, handle, &count, images));
    while (self.swapchain.present_semaphores.items.len < count) {
        try self.swapchain.present_semaphores.append(self.gpa, try createBinarySemaphore(self));
    }
    // A view of each image, behind the handle the engine already holds for that position when there is one.
    for (self.swapchain.images, 0..) |image, index| {
        const view_info: vk.ImageViewCreateInfo = .{
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .subresource_range = single_color_range,
        };
        var view: vk.ImageView = .null_handle;
        try vk.check(self.device_dispatch.createImageView(self.device, &view_info, null, &view));
        const slot: TextureViewSlot = .{
            .view = view,
            .image = image,
            .format = surface_format.format,
            .extent = extent,
            .is_swapchain_image = true,
        };
        if (index < self.swapchain.view_handles.items.len) {
            self.texture_views.get(self.swapchain.view_handles.items[index], "texture view").* = slot;
        } else {
            const view_handle: u32 = try self.texture_views.add(self.gpa, slot);
            try self.swapchain.view_handles.append(self.gpa, view_handle);
        }
    }
}

/// The swapchain for the window's current size. The device is waited idle first - the simplest way to know that no
/// image of the old swapchain is still in use - and the old views destroyed. The new swapchain is created with the
/// old one handed over (`old_swapchain`), so the presentation engine can move to it smoothly; the old one is destroyed
/// after. The views keep their handles: each slot is refreshed in place, and slots are added only when the image
/// count grows. A zero-sized surface (a minimized window) gets no swapchain until it has a size again.
fn rebuildSwapchain(self: *Host) BringUpError!void {
    try vk.check(self.device_dispatch.deviceWaitIdle(self.device));
    const old: vk.SwapchainKHR = self.swapchain.handle;
    for (self.swapchain.view_handles.items) |view_handle| {
        const slot: *TextureViewSlot = self.texture_views.get(view_handle, "texture view");
        if (slot.view != .null_handle) {
            self.device_dispatch.destroyImageView(self.device, slot.view, null);
            slot.view = .null_handle;
        }
    }
    self.gpa.free(self.swapchain.images);
    self.swapchain.images = &.{};
    self.swapchain.handle = .null_handle;
    try createSwapchain(self, old);
    if (old != .null_handle) {
        self.swapchain_dispatch.destroySwapchainKHR(self.device, old, null);
    }
    self.swapchain_dirty = false;
}

// ---- The frame: acquire and present ----
//
// Each frame borrows one swapchain image, through three handshakes with the presentation engine:
//
//     acquire   the engine names the next image, and signals the frame slot's acquire semaphore once the image is
//               really free - it may still be on screen when the call returns; the first batch after waits for it
//     render    the frame's batches, numbered on the timeline
//     present   a last batch moves the image to PRESENT_SRC and signals the image's present semaphore, which the
//               present waits for
//
// The host stays at most `frames_in_flight` frames ahead of the GPU: before acquiring for a frame slot, it waits for
// the batch that last presented from that slot.

/// Asks the presentation engine for the swapchain's next image, to signal the frame slot's acquire semaphore when the
/// image is free; its index lands in `image_index`. The result also says whether the swapchain still matches its
/// surface: `suboptimal_khr`, usable but not ideal; `error_out_of_date_khr`, no longer usable.
fn acquireNextImage(self: *Host, image_index: *u32, timeout_nanoseconds: u64) vk.Result {
    return self.swapchain_dispatch.acquireNextImageKHR(
        self.device,
        self.swapchain.handle,
        timeout_nanoseconds,
        self.acquire_semaphores[self.frame_slot],
        .null_handle,
        image_index,
    );
}

/// An acquired image made ready for its frame: kept as the frame's (`acquired_image`), and its preparation - its one
/// layout change, and a clear - recorded into `uploads`, which the first batch after the acquire runs once the image
/// is free. The handle of its view, as the engine sees the image.
fn prepareAcquiredImage(self: *Host, image_index: u32) BringUpError!u32 {
    self.acquired_image = image_index;
    self.acquire_waited = false;
    // The image's preparation, into `uploads`: from UNDEFINED - its old contents are not needed - to GENERAL.
    const uploads: vk.CommandBuffer = try uploadsCommandBuffer(self);
    const image: vk.Image = self.swapchain.images[image_index];
    imageBarrier(self, uploads, image, single_color_range, .undefined, .general);
    // WebGPU's current texture starts as zeros (transparent black) every frame: a first pass that LOADS instead of
    // clearing sees black on the web, so it must here too - not whatever the image held.
    const zero_color: vk.ClearColorValue = .{ .float_32 = @splat(0) };
    self.device_dispatch.cmdClearColorImage(uploads, image, .general, &zero_color, 1, @ptrCast(&single_color_range));
    return self.swapchain.view_handles.items[image_index];
}

/// Whether the next frame can begin without waiting - and if so, its image acquired already (`image_acquired_ahead`):
/// the batch that last presented from the frame slot finished (the timeline read without waiting, `readCompleted`),
/// and an image free at once (`acquireNextImageKHR` with a timeout of 0). The native loop asks before each frame and,
/// between askings, handles the window's messages, so that input arriving during the frame's wait reaches the app the
/// moment it arrives (`AppSpec.on_input`) - the wait moved from inside the frame's `acquireImage` to before the frame,
/// where no app code runs. True also when there is nothing to wait for here - no host; a swapchain to rebuild, an
/// image out of date, an error - each left to the frame's own `acquireImage`, so that the loop never waits on them.
pub fn tryAcquireAhead() bool {
    const self: *Host = host orelse return true;
    if (self.image_acquired_ahead != null) {
        return true;
    }
    const completed: u64 = readCompleted(self) catch return true;
    if (completed < self.present_serials[self.frame_slot]) {
        return false;
    }
    const window: *win32.Window = theWindow(self);
    const is_stale: bool = self.swapchain_dirty or window.size_changed or self.swapchain.handle == .null_handle;
    if (is_stale) {
        return true;
    }
    var image_index: u32 = 0;
    const result: vk.Result = acquireNextImage(self, &image_index, 0);
    switch (result) {
        .success, .suboptimal_khr => {
            // An image WAS acquired: this frame uses it, and a suboptimal swapchain is rebuilt at the next.
            if (result == .suboptimal_khr) {
                self.swapchain_dirty = true;
            }
            self.image_acquired_ahead = image_index;
            return true;
        },
        .not_ready, .timeout => return false,
        else => return true,
    }
}

/// The next swapchain image, as the engine sees it: the handle of its view. An image acquired before the frame
/// (`tryAcquireAhead`) is taken as it is; otherwise the frame slot is waited for, a stale swapchain rebuilt, and the
/// image acquired. Then its preparation (`prepareAcquiredImage`).
fn acquireImage(self: *Host) BringUpError!u32 {
    if (self.image_acquired_ahead) |ahead_index| {
        self.image_acquired_ahead = null;
        try retireCompleted(self);
        return prepareAcquiredImage(self, ahead_index);
    }
    // The frame slot: the batch that last presented from it must be done; reclaim what is.
    try waitTimeline(self, self.present_serials[self.frame_slot]);
    try retireCompleted(self);
    // A stale swapchain - the window resized, or a present reported a mismatch - is rebuilt before acquiring.
    const window: *win32.Window = theWindow(self);
    if (window.size_changed) {
        self.swapchain_dirty = true;
        window.size_changed = false;
    }
    const is_stale: bool = self.swapchain_dirty or self.swapchain.handle == .null_handle;
    if (is_stale) {
        try rebuildSwapchain(self);
    }
    if (self.swapchain.handle == .null_handle) {
        // The native loop skips frames while the window is minimized, so this means a zero-sized window it missed.
        panic("vulkan host: no swapchain - the window is zero-sized", .{});
    }
    var image_index: u32 = 0;
    var result: vk.Result = acquireNextImage(self, &image_index, no_timeout);
    if (result == .error_out_of_date_khr) {
        // Nothing was acquired and the semaphore was not signalled: rebuild, and acquire once more.
        try rebuildSwapchain(self);
        result = acquireNextImage(self, &image_index, no_timeout);
    }
    try vk.check(result);
    if (result == .suboptimal_khr) {
        // An image WAS acquired: this frame uses it, the next one rebuilds.
        self.swapchain_dirty = true;
    }
    return prepareAcquiredImage(self, image_index);
}

/// Presents the acquired image. A batch of its own - with any writes still pending - moves the image to PRESENT_SRC
/// and signals the image's present semaphore, which the present waits for. A present that reports the swapchain out
/// of date, or suboptimal, marks it for a rebuild at the next acquire. The frame slot then advances.
fn presentImage(self: *Host) BringUpError!void {
    const image_index: u32 = self.acquired_image orelse panic("vulkan host: present without a current texture", .{});
    // The batch: the image's move to PRESENT_SRC, signalling its present semaphore.
    const command_buffer: vk.CommandBuffer = try beginCommandBuffer(self);
    const image: vk.Image = self.swapchain.images[image_index];
    if (self.keeps_presented_frames) {
        // lint:off decl-order: the kept frame's buffer is a resource, made and read with the resources below
        try copyPresentedFrame(self, command_buffer, image);
    }
    imageBarrier(self, command_buffer, image, single_color_range, .general, .present_src_khr);
    try vk.check(self.device_dispatch.endCommandBuffer(command_buffer));
    const present_semaphore: vk.Semaphore = self.swapchain.present_semaphores.items[image_index];
    const serial: u64 = try submitBatch(self, command_buffer, present_semaphore);
    if (self.keeps_presented_frames) {
        self.kept_frame.serial = serial;
    }

    // The present, once the batch has signalled.
    const present_waits = [_]vk.Semaphore{present_semaphore};
    const swapchains = [_]vk.SwapchainKHR{self.swapchain.handle};
    const image_indices = [_]u32{image_index};
    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &present_waits,
        .swapchain_count = 1,
        .p_swapchains = &swapchains,
        .p_image_indices = &image_indices,
    };
    const presented: vk.Result = self.swapchain_dispatch.queuePresentKHR(self.queue, &present_info);
    const needs_rebuild: bool = presented == .error_out_of_date_khr or presented == .suboptimal_khr;
    if (needs_rebuild) {
        self.swapchain_dirty = true;
    } else {
        try vk.check(presented);
    }
    // The next acquire for this frame slot waits for this present's batch.
    self.present_serials[self.frame_slot] = serial;
    self.frame_slot = (self.frame_slot + 1) % frames_in_flight;
    self.acquired_image = null;
}

/// Packs a size as the browser's calls return it: width in the high 16 bits, height in the low.
fn packSize(width: u32, height: u32) u32 {
    // `@min` with a 16-bit bound narrows to u16: widen before shifting.
    const packed_width: u32 = @min(width, 0xffff);
    const packed_height: u32 = @min(height, 0xffff);
    return (packed_width << 16) | packed_height;
}

// ---- Staging and buffers ----
//
// A buffer the GPU reads fast lives in device-local memory, which the CPU usually cannot see, so data crosses in two
// steps: the CPU copies it into STAGING memory it can write - host-visible chunks, mapped once for the host's life -
// and a copy command recorded into `uploads` moves it on into the buffer or texture. A chunk fills with consecutive
// writes, is consumed by the next submission, and comes back free when the timeline passes that submission; a budget
// bounds how many chunks exist (`staging_chunk_budget`).

/// A new staging chunk of `size` bytes: a buffer copies can read from, in host-visible, coherent memory - the CPU
/// writes it directly, and coherent memory needs no flush to make the writes visible to the GPU - mapped once, for the
/// host's life.
fn createStagingChunk(self: *Host, size: u64) BringUpError!usize {
    const buffer_info: vk.BufferCreateInfo = .{
        .size = size,
        .usage = .{ .transfer_src = true },
        .sharing_mode = .exclusive,
    };
    var buffer: vk.Buffer = .null_handle;
    try vk.check(self.device_dispatch.createBuffer(self.device, &buffer_info, null, &buffer));
    var requirements: vk.MemoryRequirements = .{};
    self.device_dispatch.getBufferMemoryRequirements(self.device, buffer, &requirements);
    const host_memory: vk.MemoryPropertyFlags = .{ .host_visible = true, .host_coherent = true };
    const memory: vk.DeviceMemory = try allocateMemory(self, requirements, host_memory, .{}, "staging");
    try vk.check(self.device_dispatch.bindBufferMemory(self.device, buffer, memory, 0));
    var mapped: ?*anyopaque = null;
    try vk.check(self.device_dispatch.mapMemory(self.device, memory, 0, vk.whole_size, .{}, &mapped));
    const bytes: [*]u8 = @ptrCast(mapped orelse panic("vulkan host: mapping staging memory gave no address", .{}));
    const chunk: StagingChunk = .{ .buffer = buffer, .memory = memory, .mapped = bytes, .size = size, .used = 0 };
    try self.staging.chunks.append(self.gpa, chunk);
    return self.staging.chunks.items.len - 1;
}

/// Takes a free chunk with room for `byte_count` bytes - the smallest that fits, so a large chunk stays available
/// for the large writes that need one - or null when no free chunk is big enough.
fn takeFreeStagingChunk(self: *Host, byte_count: u64) ?usize {
    var best_position: ?usize = null;
    var best_size: u64 = zm.maxInt(u64);
    for (self.staging.free.items, 0..) |chunk_index, position| {
        const size: u64 = self.staging.chunks.items[chunk_index].size;
        if (size >= byte_count and size < best_size) {
            best_position = position;
            best_size = size;
        }
    }
    const position: usize = best_position orelse return null;
    return self.staging.free.swapRemove(position);
}

/// With the budget's chunks all held by submissions the GPU has not finished, waits for the oldest of those
/// submissions and reclaims what it used; returns whether it waited. It does not wait while the budget still allows a
/// new chunk, nor when every chunk belongs to work not yet submitted, which cannot be waited for.
fn waitForOldestStagingChunk(self: *Host) BringUpError!bool {
    const budget_allows_a_new_chunk: bool = self.staging.chunks.items.len < staging_chunk_budget;
    const no_submission_holds_a_chunk: bool = self.staging.retiring.items.len == 0;
    if (budget_allows_a_new_chunk or no_submission_holds_a_chunk) {
        return false;
    }
    // `retiring` is in submission order, so its first entry is the oldest.
    try waitTimeline(self, self.staging.retiring.items[0].serial);
    try retireCompleted(self);
    return true;
}

/// The chunk a write of `byte_count` bytes goes into, in order of preference: the chunk being filled, when it has
/// room; a free chunk that fits; with the budget spent, a chunk freed by waiting for the oldest submission; else a
/// new chunk - of the standard size, or exactly as large as a bigger write.
fn stagingChunkFor(self: *Host, byte_count: u64, alignment: u64) BringUpError!usize {
    if (self.staging.current) |index| {
        const chunk: StagingChunk = self.staging.chunks.items[index];
        const write_offset: u64 = std.mem.alignForward(u64, chunk.used, alignment);
        const has_room: bool = write_offset + byte_count <= chunk.size;
        if (has_room) {
            return index;
        }
    }
    if (takeFreeStagingChunk(self, byte_count)) |index| {
        return index;
    }
    if (try waitForOldestStagingChunk(self)) {
        if (takeFreeStagingChunk(self, byte_count)) |index| {
            return index;
        }
    }
    return createStagingChunk(self, @max(staging_chunk_size, byte_count));
}

/// Copies `data` into staging memory, 16-byte aligned (every copy's source offset then suits every texel size), and
/// says where it went. The next submit consumes it.
fn stage(self: *Host, data: []const u8) BringUpError!Staged {
    const alignment: u64 = 16;
    const byte_count: u64 = data.len;
    const index: usize = try stagingChunkFor(self, byte_count, alignment);
    const chunk: *StagingChunk = &self.staging.chunks.items[index];
    const offset: u64 = std.mem.alignForward(u64, chunk.used, alignment);
    @memcpy(chunk.mapped[offset .. offset + byte_count], data);
    chunk.used = offset + byte_count;
    self.staging.current = index;
    if (indexOfScalar(usize, self.staging.in_use.items, index) == null) {
        try self.staging.in_use.append(self.gpa, index);
    }
    return .{ .buffer = chunk.buffer, .offset = offset };
}

/// Every buffer can be copied from and to (writes, readback, copies); the rest follows WebGPU's usage.
fn bufferUsageFlags(usage: gpu_abi.BufferUsage) vk.BufferUsageFlags {
    return .{
        .transfer_src = true,
        .transfer_dst = true,
        .uniform_buffer = usage.uniform,
        .storage_buffer = usage.storage,
        .index_buffer = usage.index,
        .vertex_buffer = usage.vertex,
        .indirect_buffer = usage.indirect,
    };
}

/// A buffer in device memory - or, for one the CPU reads back (`map_read`), in host-visible, cached memory mapped for
/// its whole life - filled with zeros first, because WebGPU guarantees a new buffer reads as zeros and Vulkan memory
/// starts undefined.
fn createBuffer(
    self: *Host,
    size: u64,
    usage: gpu_abi.BufferUsage,
    label: []const u8,
) BringUpError!u32 {
    // Vulkan refuses a zero size; four-byte multiples suit fills and copies.
    const buffer_size: u64 = @max(std.mem.alignForward(u64, size, 4), 4);
    const buffer_info: vk.BufferCreateInfo = .{
        .size = buffer_size,
        .usage = bufferUsageFlags(usage),
        .sharing_mode = .exclusive,
    };
    var buffer: vk.Buffer = .null_handle;
    try vk.check(self.device_dispatch.createBuffer(self.device, &buffer_info, null, &buffer));
    var requirements: vk.MemoryRequirements = .{};
    self.device_dispatch.getBufferMemoryRequirements(self.device, buffer, &requirements);
    // Memory: device-local, for the GPU's use; for a buffer the CPU reads back, host-visible memory - cached, so the
    // CPU's reads are fast, and coherent, so the GPU's writes reach the CPU without an invalidate call - mapped once
    // for the buffer's life.
    const readable: bool = usage.map_read;
    const required: vk.MemoryPropertyFlags = .{ .host_visible = readable };
    const preferred: vk.MemoryPropertyFlags = if (readable)
        .{ .host_cached = true, .host_coherent = true }
    else
        .{ .device_local = true };
    const memory: vk.DeviceMemory = try allocateMemory(self, requirements, required, preferred, label);
    try vk.check(self.device_dispatch.bindBufferMemory(self.device, buffer, memory, 0));
    var mapped: ?[*]u8 = null;
    if (readable) {
        var address: ?*anyopaque = null;
        try vk.check(self.device_dispatch.mapMemory(self.device, memory, 0, vk.whole_size, .{}, &address));
        mapped = @ptrCast(address);
    }
    // Zeros, as WebGPU promises for a new buffer: a fill in `uploads`, which runs before anything submitted after.
    const uploads: vk.CommandBuffer = try uploadsCommandBuffer(self);
    fullBarrier(self, uploads);
    self.device_dispatch.cmdFillBuffer(uploads, buffer, 0, vk.whole_size, 0);
    nameObject(self, .buffer, @backingInt(buffer), label);
    return self.buffers.add(self.gpa, .{ .buffer = buffer, .memory = memory, .size = buffer_size, .mapped = mapped });
}

/// Stages `data` and records its copy into the buffer at `offset`, in `uploads`: it lands after everything submitted
/// before and before everything submitted after, as WebGPU's queue orders a write.
fn writeBuffer(
    self: *Host,
    buffer_handle: u32,
    offset: u64,
    data: []const u8,
) BringUpError!void {
    if (data.len == 0) {
        return;
    }
    const slot: *BufferSlot = self.buffers.get(buffer_handle, "buffer");
    const staged: Staged = try stage(self, data);
    const uploads: vk.CommandBuffer = try uploadsCommandBuffer(self);
    fullBarrier(self, uploads);
    const region: vk.BufferCopy = .{ .src_offset = staged.offset, .dst_offset = offset, .size = data.len };
    self.device_dispatch.cmdCopyBuffer(uploads, staged.buffer, slot.buffer, 1, @ptrCast(&region));
}

// ---- Textures, samplers, shader modules ----
//
// A texture is a Vulkan IMAGE - a grid of texels, with mip levels and array layers - in device-local memory, which
// shaders read through VIEWS and SAMPLERS. Its texels are arranged as the GPU prefers (optimal tiling), so from the
// CPU's side only copies reach them. Shader modules complete the objects a pipeline is made from.

/// What the host needs to know about a texture format: Vulkan's format, the bytes one texel takes in a write, and
/// whether it holds depth - which decides the aspect that views, copies and clears address.
const FormatInfo = struct {
    format: vk.Format,
    texel_bytes: u32,
    is_depth: bool,
};

/// zimr's texture formats in Vulkan, in one table so the three facts cannot disagree. `depth24_plus` becomes
/// D32_SFLOAT, as Dawn and mach choose it: WebGPU promises only "at least 24 bits", and some GPUs have no 24-bit
/// depth attachment.
fn formatInfo(format: gpu_abi.TextureFormat) FormatInfo {
    return switch (format) {
        .undefined_ => .{ .format = .undefined, .texel_bytes = 0, .is_depth = false },
        .rgba8_unorm => .{ .format = .r8g8b8a8_unorm, .texel_bytes = 4, .is_depth = false },
        .rgba8_unorm_srgb => .{ .format = .r8g8b8a8_srgb, .texel_bytes = 4, .is_depth = false },
        .bgra8_unorm => .{ .format = .b8g8r8a8_unorm, .texel_bytes = 4, .is_depth = false },
        .bgra8_unorm_srgb => .{ .format = .b8g8r8a8_srgb, .texel_bytes = 4, .is_depth = false },
        .rgba16_float => .{ .format = .r16g16b16a16_sfloat, .texel_bytes = 8, .is_depth = false },
        .rgba32_float => .{ .format = .r32g32b32a32_sfloat, .texel_bytes = 16, .is_depth = false },
        .r8_unorm => .{ .format = .r8_unorm, .texel_bytes = 1, .is_depth = false },
        .rg8_unorm => .{ .format = .r8g8_unorm, .texel_bytes = 2, .is_depth = false },
        .depth16_unorm => .{ .format = .d16_unorm, .texel_bytes = 2, .is_depth = true },
        .depth24_plus, .depth32_float => .{ .format = .d32_sfloat, .texel_bytes = 4, .is_depth = true },
    };
}

/// A sample count as Vulkan's flags, one bit set: 0 and 1 are one sample, 2, 4 and 8 their own bits; null for a
/// count Vulkan has no bit for.
fn sampleCountFlags(count: u32) ?vk.SampleCountFlags {
    return switch (count) {
        0, 1 => .{ .@"1" = true },
        2 => .{ .@"2" = true },
        4 => .{ .@"4" = true },
        8 => .{ .@"8" = true },
        else => null,
    };
}

/// The image aspect that views, copies and clears of a texture address: its depth, or its color.
fn aspectOf(is_depth: bool) vk.ImageAspectFlags {
    return if (is_depth) .{ .depth = true } else .{ .color = true };
}

/// What a texture is made with, as the browser's call passes it.
const TextureRequest = struct {
    width: u32,
    height: u32,
    format: u32,
    usage: u32,
    label: []const u8,
    sample_count: u32,
    mip_level_count: u32,
    array_layers: u32,
};

/// A 2D texture in device memory, moved to GENERAL (every image stays there) and cleared to zero - WebGPU guarantees a
/// new texture reads as zeros, as it does for buffers. Every texture can be copied from and to; the rest of its usage
/// follows WebGPU's.
fn createTexture(self: *Host, request: TextureRequest) BringUpError!u32 {
    const label: []const u8 = request.label;
    const format: gpu_abi.TextureFormat = std.enums.fromInt(gpu_abi.TextureFormat, request.format) orelse
        panic("vulkan host: texture `{s}` has an unknown format {d}", .{ label, request.format });
    if (format == .undefined_) {
        panic("vulkan host: texture `{s}` has no format", .{label});
    }
    const usage: gpu_abi.TextureUsage = @bitCast(request.usage);
    const info: FormatInfo = formatInfo(format);
    const is_depth: bool = info.is_depth;
    const usage_flags: vk.ImageUsageFlags = .{
        .transfer_src = true,
        .transfer_dst = true,
        .sampled = usage.texture_binding,
        .storage = usage.storage_binding,
        .depth_stencil_attachment = usage.render_attachment and is_depth,
        .color_attachment = usage.render_attachment and !is_depth,
    };
    const samples: vk.SampleCountFlags = sampleCountFlags(request.sample_count) orelse
        panic("vulkan host: texture `{s}` asks for {d} samples", .{ label, request.sample_count });
    const mip_levels: u32 = @max(request.mip_level_count, 1);
    const array_layers: u32 = @max(request.array_layers, 1);
    const image_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = info.format,
        .extent = .{ .width = request.width, .height = request.height, .depth = 1 },
        .mip_levels = mip_levels,
        .array_layers = array_layers,
        .samples = samples,
        // The GPU's own arrangement of the texels, which only copies cross; the contents start undefined.
        .tiling = .optimal,
        .usage = usage_flags,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    var image: vk.Image = .null_handle;
    try vk.check(self.device_dispatch.createImage(self.device, &image_info, null, &image));
    var requirements: vk.MemoryRequirements = .{};
    self.device_dispatch.getImageMemoryRequirements(self.device, image, &requirements);
    const device_local: vk.MemoryPropertyFlags = .{ .device_local = true };
    const memory: vk.DeviceMemory = try allocateMemory(self, requirements, .{}, device_local, label);
    try vk.check(self.device_dispatch.bindImageMemory(self.device, image, memory, 0));

    const range: vk.ImageSubresourceRange = .{
        .aspect_mask = aspectOf(is_depth),
        .level_count = mip_levels,
        .layer_count = array_layers,
    };
    const uploads: vk.CommandBuffer = try uploadsCommandBuffer(self);
    imageBarrier(self, uploads, image, range, .undefined, .general);
    // Zeros, as WebGPU promises for a new texture - a depth texture too, a depth of 0. (A render pass that clears
    // depth sets 1.0, the far end of the range: that is the start of drawing, not the texture's creation.)
    if (is_depth) {
        const zero_depth: vk.ClearDepthStencilValue = .{ .depth = 0, .stencil = 0 };
        self.device_dispatch.cmdClearDepthStencilImage(uploads, image, .general, &zero_depth, 1, @ptrCast(&range));
    } else {
        const zero_color: vk.ClearColorValue = .{ .float_32 = @splat(0) };
        self.device_dispatch.cmdClearColorImage(uploads, image, .general, &zero_color, 1, @ptrCast(&range));
    }
    nameObject(self, .image, @backingInt(image), label);
    return self.textures.add(self.gpa, .{
        .image = image,
        .memory = memory,
        .format = info.format,
        .is_depth = is_depth,
        .extent = .{ .width = request.width, .height = request.height },
        .mip_levels = mip_levels,
        .array_layers = array_layers,
        .samples = samples,
        .texel_bytes = info.texel_bytes,
    });
}

/// Which part of a texture a view sees, as WebGPU's view descriptor says it: a range of mip levels, and the layers.
const ViewRange = struct {
    base_mip: u32 = 0,
    /// Null: every level from `base_mip` on.
    mip_count: ?u32 = null,
    /// Null: every layer - one layer as a 2D view, several as a 2D array, as WebGPU's default view. A count: a 2D
    /// array of that many layers from the first.
    layer_count: ?u32 = null,
    /// Set: a 2D view of this one layer, whatever `layer_count` says - what a render pass draws into, or a shader
    /// samples as an ordinary 2D texture (WebGPU's `dimension: "2d"` with `baseArrayLayer`).
    base_layer: ?u32 = null,
};

/// A view of a texture over `range`. A view's extent is its base level's - halved per level, never below 1 - since a
/// render pass sizes itself from its first view.
fn createTextureView(
    self: *Host,
    texture_handle: u32,
    range: ViewRange,
) BringUpError!u32 {
    const texture: TextureSlot = self.textures.get(texture_handle, "texture").*;
    const mip_count: u32 = range.mip_count orelse texture.mip_levels -| range.base_mip;
    const base_layer: u32 = range.base_layer orelse 0;
    const layer_count: u32 = if (range.base_layer != null) 1 else range.layer_count orelse texture.array_layers;
    const fits: bool = mip_count > 0 and range.base_mip + mip_count <= texture.mip_levels and layer_count > 0 and
        base_layer + layer_count <= texture.array_layers;
    if (!fits) {
        const message: []const u8 = "vulkan host: a view of mip levels {d}..{d} and {d} layers, " ++
            "of a texture with {d} levels and {d} layers";
        panic(message, .{
            range.base_mip,
            range.base_mip + mip_count,
            base_layer + layer_count,
            texture.mip_levels,
            texture.array_layers,
        });
    }
    const is_array: bool = range.base_layer == null and (range.layer_count != null or texture.array_layers > 1);
    const view_info: vk.ImageViewCreateInfo = .{
        .image = texture.image,
        .view_type = if (is_array) .@"2d_array" else .@"2d",
        .format = texture.format,
        .subresource_range = .{
            .aspect_mask = aspectOf(texture.is_depth),
            .base_mip_level = range.base_mip,
            .level_count = mip_count,
            .base_array_layer = base_layer,
            .layer_count = layer_count,
        },
    };
    var view: vk.ImageView = .null_handle;
    try vk.check(self.device_dispatch.createImageView(self.device, &view_info, null, &view));
    const base_extent: vk.Extent2D = .{
        .width = @max(1, texture.extent.width >> @intCast(range.base_mip)),
        .height = @max(1, texture.extent.height >> @intCast(range.base_mip)),
    };
    return self.texture_views.add(self.gpa, .{
        .view = view,
        .image = texture.image,
        .format = texture.format,
        .extent = base_extent,
        .is_swapchain_image = false,
        .is_depth = texture.is_depth,
        .samples = texture.samples,
    });
}

/// Makes the screen's texture and view, the first time the engine asks for the surface: a texture like any other -
/// drawn into, copied from and to, sampled - whose view is the host's, as a swapchain image's is, so that an app
/// releasing the current texture's view leaves it.
fn makeScreen(self: *Host, screen: *Screen) BringUpError!void {
    if (screen.texture != 0) {
        return;
    }
    const usage: gpu_abi.TextureUsage = .{
        .copy_src = true,
        .copy_dst = true,
        .texture_binding = true,
        .render_attachment = true,
    };
    screen.texture = try createTexture(self, .{
        .width = screen.width,
        .height = screen.height,
        .format = @backingInt(screen_format),
        .usage = @backingInt(usage),
        .label = "screen",
        .sample_count = 1,
        .mip_level_count = 1,
        .array_layers = 1,
    });
    screen.view = try createTextureView(self, screen.texture, .{});
    self.texture_views.get(screen.view, "texture view").is_swapchain_image = true;
}

/// Begins a frame on the screen, as acquiring begins one on a swapchain: once the frame slot's last frame is done on
/// the GPU, the image's old contents are dropped and it is cleared to zeros, as WebGPU's current texture starts every
/// frame. Asked again before the present, it is the same frame. Returns the screen's view.
fn beginScreenFrame(self: *Host, screen: *Screen) BringUpError!u32 {
    if (screen.is_frame_begun) {
        return screen.view;
    }
    try waitTimeline(self, self.present_serials[self.frame_slot]);
    try retireCompleted(self);
    const uploads: vk.CommandBuffer = try uploadsCommandBuffer(self);
    const image: vk.Image = self.textures.get(screen.texture, "texture").image;
    imageBarrier(self, uploads, image, single_color_range, .undefined, .general);
    const zero_color: vk.ClearColorValue = .{ .float_32 = @splat(0) };
    self.device_dispatch.cmdClearColorImage(uploads, image, .general, &zero_color, 1, @ptrCast(&single_color_range));
    screen.is_frame_begun = true;
    return screen.view;
}

/// Ends a frame on the screen, as presenting ends one on a swapchain - with nothing to show it to: a batch numbered on
/// the timeline, carrying any writes still pending, which the frame slot's next frame waits for. The frame slot then
/// advances. A frame that never asked for the current texture ends nothing, as a present without one shows nothing.
fn endScreenFrame(self: *Host, screen: *Screen) BringUpError!void {
    if (!screen.is_frame_begun) {
        return;
    }
    const command_buffer: vk.CommandBuffer = try beginCommandBuffer(self);
    try vk.check(self.device_dispatch.endCommandBuffer(command_buffer));
    const serial: u64 = try submitBatch(self, command_buffer, .null_handle);
    self.present_serials[self.frame_slot] = serial;
    self.frame_slot = (self.frame_slot + 1) % frames_in_flight;
    screen.is_frame_begun = false;
    screen.drawn_frame_count += 1;
}

/// Where a texture write lands: a rectangle of one mip level of layer 0, rows `bytes_per_row` apart in the data.
const TextureRegion = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    mip_level: u32,
};

/// Stages `data` and records its copy into the texture, in `uploads` - ordered like every other write.
fn writeTexture(
    self: *Host,
    texture_handle: u32,
    region: TextureRegion,
    data: []const u8,
) BringUpError!void {
    if (data.len == 0 or region.width == 0 or region.height == 0) {
        return;
    }
    const texture: TextureSlot = self.textures.get(texture_handle, "texture").*;
    if (region.bytes_per_row % texture.texel_bytes != 0) {
        panic("vulkan host: texture rows of {d} bytes are not whole {d}-byte texels", .{
            region.bytes_per_row,
            texture.texel_bytes,
        });
    }
    const staged: Staged = try stage(self, data);
    const uploads: vk.CommandBuffer = try uploadsCommandBuffer(self);
    fullBarrier(self, uploads);
    const copy: vk.BufferImageCopy = .{
        .buffer_offset = staged.offset,
        // Vulkan measures the data's rows in texels; 0 rows of height means "the copy's own height".
        .buffer_row_length = region.bytes_per_row / texture.texel_bytes,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = aspectOf(texture.is_depth),
            .mip_level = region.mip_level,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = @intCast(region.x), .y = @intCast(region.y), .z = 0 },
        .image_extent = .{ .width = region.width, .height = region.height, .depth = 1 },
    };
    self.device_dispatch.cmdCopyBufferToImage(uploads, staged.buffer, texture.image, .general, 1, @ptrCast(&copy));
}

/// What a sampler is made from, as the engine's call passes it. Each filter chooses how texels are combined: linear
/// blends the nearest texels by distance, nearest takes the closest one.
const SamplerRequest = struct {
    /// Magnification, a texture drawn larger than its size (one texel across several pixels).
    magnify_linear: bool,
    /// Minification, a texture drawn smaller than its size (several texels under one pixel), within one mip level.
    minify_linear: bool,
    /// Between the two mip levels nearest the drawn size.
    mipmap_linear: bool,
    /// What coordinates outside 0 to 1 read, on the u and v axes.
    address_mode: gpu_abi.AddressMode,
};

/// How a sampler reads coordinates outside 0 to 1, as Vulkan's address mode: the edge texel, the texture repeated, or
/// the texture repeated with every other copy mirrored. WebGPU's `mirror_repeat` is Vulkan's `mirrored_repeat`.
fn samplerAddressMode(mode: gpu_abi.AddressMode) vk.SamplerAddressMode {
    return switch (mode) {
        .clamp_to_edge => .clamp_to_edge,
        .repeat => .repeat,
        .mirror_repeat => .mirrored_repeat,
    };
}

/// A sampler, made exactly as the browser's bridge makes it, so a texture reads the same on both hosts: the three
/// filters, the address mode on u and v (w keeps WebGPU's default, clamp to edge), and WebGPU's default
/// level-of-detail range, 0 to 32 - every mip level a texture can have.
fn createSampler(self: *Host, request: SamplerRequest) BringUpError!u32 {
    const address_mode: vk.SamplerAddressMode = samplerAddressMode(request.address_mode);
    const sampler_info: vk.SamplerCreateInfo = .{
        .mag_filter = if (request.magnify_linear) .linear else .nearest,
        .min_filter = if (request.minify_linear) .linear else .nearest,
        .mipmap_mode = if (request.mipmap_linear) .linear else .nearest,
        .address_mode_u = address_mode,
        .address_mode_v = address_mode,
        .address_mode_w = .clamp_to_edge,
        .min_lod = 0,
        .max_lod = 32,
    };
    var sampler: vk.Sampler = .null_handle;
    try vk.check(self.device_dispatch.createSampler(self.device, &sampler_info, null, &sampler));
    return self.samplers.add(self.gpa, .{ .sampler = sampler });
}

/// A shader module from the compiler's SPIR-V - natively, the bytes embedded under the shader's name are SPIR-V -
/// legalized on the way for Vulkan's rules, which the compiler's output does not all meet (`spv_vulkan.legalize`,
/// whose header lists each adjustment). The embedded bytes are only byte-aligned, so they are copied into words first.
fn createShaderModule(
    self: *Host,
    bytes: []const u8,
    label: []const u8,
) BringUpError!u32 {
    const not_spirv: []const u8 = "vulkan host: shader `{s}` is not SPIR-V - " ++
        "a module written in WGSL has no native path";
    const is_spirv_sized: bool = bytes.len >= 20 and bytes.len % 4 == 0;
    if (!is_spirv_sized) {
        panic(not_spirv, .{label});
    }
    const words: []u32 = try self.gpa.alloc(u32, bytes.len / 4);
    defer self.gpa.free(words);
    @memcpy(sliceAsBytes(words), bytes);
    const legal: []u32 = spv_vulkan.legalize(self.gpa, words) catch |err| switch (err) {
        error.NotSpirv => panic(not_spirv, .{label}),
        else => panic("vulkan host: shader `{s}` cannot run on Vulkan: {s}", .{ label, @errorName(err) }),
    };
    defer self.gpa.free(legal);
    const module_info: vk.ShaderModuleCreateInfo = .{ .code_size = legal.len * 4, .p_code = legal.ptr };
    var module: vk.ShaderModule = .null_handle;
    try vk.check(self.device_dispatch.createShaderModule(self.device, &module_info, null, &module));
    nameObject(self, .shader_module, @backingInt(module), label);
    return self.shader_modules.add(self.gpa, .{ .module = module });
}

// ---- Bind groups and layouts ----
//
// A WebGPU bind group is a Vulkan DESCRIPTOR SET: the GPU's record of the resources a group of shader bindings refers
// to. Its LAYOUT, a descriptor-set layout, gives the group's shape - each binding's kind, and the stages that see it -
// and a PIPELINE LAYOUT lists a pipeline's group layouts in order. Sets come from DESCRIPTOR POOLS, which the host
// keeps as pages: a set is taken from a page with room, and goes back to its page when its group is destroyed.

/// What one descriptor pool page holds: enough for a few hundred bind groups of the engine's usual shapes.
const sets_per_pool_page: u32 = 512;

/// The shader stages that see a binding, as Vulkan's stage flags.
fn stageFlags(visibility: gpu_abi.ShaderStage) vk.ShaderStageFlags {
    return .{ .vertex = visibility.vertex, .fragment = visibility.fragment, .compute = visibility.compute };
}

/// A WebGPU binding as a Vulkan descriptor: both storage-buffer kinds are storage
/// buffers (read-only is a promise WebGPU checks, not a different descriptor), textures are sampled images.
fn descriptorType(kind: gpu_abi.BindingKind) vk.DescriptorType {
    return switch (kind) {
        .uniform_buffer => .uniform_buffer,
        .read_only_storage_buffer, .storage_buffer => .storage_buffer,
        .sampler => .sampler,
        .texture => .sampled_image,
        .storage_texture => .storage_image,
    };
}

/// A descriptor-set layout from a bind-group layout blob; the decoded entries are kept for the groups made from it.
/// An empty blob makes a layout with no bindings, which the engine's placeholder groups use.
fn createBindGroupLayout(
    self: *Host,
    blob: []const u8,
    label: []const u8,
) BringUpError!u32 {
    var room: [max_bindings_per_group]gpu_abi.BindGroupLayoutEntry = undefined;
    const entries: []gpu_abi.BindGroupLayoutEntry = gpu_abi.decodeBindGroupLayout(blob, &room) catch |err| {
        panic("vulkan host: bind-group layout `{s}`: {s}", .{ label, @errorName(err) });
    };
    var bindings: [max_bindings_per_group]vk.DescriptorSetLayoutBinding = undefined;
    for (entries, bindings[0..entries.len]) |entry, *binding| {
        binding.* = .{
            .binding = entry.binding,
            .descriptor_type = descriptorType(entry.kind),
            .descriptor_count = 1,
            .stage_flags = stageFlags(entry.visibility),
        };
    }
    const layout_info: vk.DescriptorSetLayoutCreateInfo = .{
        .binding_count = @intCast(entries.len),
        .p_bindings = &bindings,
    };
    var layout: vk.DescriptorSetLayout = .null_handle;
    try vk.check(self.device_dispatch.createDescriptorSetLayout(self.device, &layout_info, null, &layout));
    nameObject(self, .descriptor_set_layout, @backingInt(layout), label);
    const kept: []gpu_abi.BindGroupLayoutEntry = try self.gpa.dupe(gpu_abi.BindGroupLayoutEntry, entries);
    return self.bind_group_layouts.add(self.gpa, .{ .layout = layout, .entries = kept });
}

/// The set layout with no bindings, created on first use and kept for the host's life.
fn emptySetLayout(self: *Host) BringUpError!vk.DescriptorSetLayout {
    if (self.empty_set_layout == .null_handle) {
        const layout_info: vk.DescriptorSetLayoutCreateInfo = .{};
        try vk.check(self.device_dispatch.createDescriptorSetLayout(
            self.device,
            &layout_info,
            null,
            &self.empty_set_layout,
        ));
    }
    return self.empty_set_layout;
}

/// A new descriptor pool page, sized for a few hundred bind groups of the engine's usual shapes; appended to the
/// pages, and returned.
fn createDescriptorPoolPage(self: *Host) BringUpError!vk.DescriptorPool {
    const sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .uniform_buffer, .descriptor_count = 2 * sets_per_pool_page },
        .{ .type = .storage_buffer, .descriptor_count = 2 * sets_per_pool_page },
        .{ .type = .sampler, .descriptor_count = sets_per_pool_page },
        .{ .type = .sampled_image, .descriptor_count = 2 * sets_per_pool_page },
        .{ .type = .storage_image, .descriptor_count = sets_per_pool_page / 2 },
    };
    // FREE_DESCRIPTOR_SET: a bind group's set returns to its page when the group is destroyed.
    const pool_info: vk.DescriptorPoolCreateInfo = .{
        .flags = .{ .free_descriptor_set = true },
        .max_sets = sets_per_pool_page,
        .pool_size_count = sizes.len,
        .p_pool_sizes = &sizes,
    };
    var pool: vk.DescriptorPool = .null_handle;
    try vk.check(self.device_dispatch.createDescriptorPool(self.device, &pool_info, null, &pool));
    try self.descriptor_pages.append(self.gpa, .{ .pool = pool });
    return pool;
}

/// Tries to allocate one set of `layout` from `pool`: the set, or null when the pool has no room for it (Vulkan
/// reports a full pool as out of pool memory, or as fragmented when its free space is split into pieces too small).
fn allocateFromPool(
    self: *Host,
    pool: vk.DescriptorPool,
    layout: vk.DescriptorSetLayout,
) BringUpError!?vk.DescriptorSet {
    const layouts = [_]vk.DescriptorSetLayout{layout};
    const allocate_info: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = &layouts,
    };
    var set: vk.DescriptorSet = .null_handle;
    const sets: [*]vk.DescriptorSet = @ptrCast(&set);
    const result: vk.Result = self.device_dispatch.allocateDescriptorSets(self.device, &allocate_info, sets);
    if (result == .error_out_of_pool_memory or result == .error_fragmented_pool) {
        return null;
    }
    try vk.check(result);
    return set;
}

/// One descriptor set of `layout`: from the newest page with room - newest first, since older pages are the likelier
/// to be full - and from a new page only when every page is full.
fn allocateDescriptorSet(self: *Host, layout: vk.DescriptorSetLayout) BringUpError!DescriptorSetSlot {
    var index: usize = self.descriptor_pages.items.len;
    while (index > 0) {
        index -= 1;
        const page: *DescriptorPage = &self.descriptor_pages.items[index];
        if (!page.has_room) {
            continue;
        }
        if (try allocateFromPool(self, page.pool, layout)) |set| {
            return .{ .set = set, .page = @intCast(index) };
        }
        page.has_room = false;
    }
    const pool: vk.DescriptorPool = try createDescriptorPoolPage(self);
    const set: vk.DescriptorSet = try allocateFromPool(self, pool, layout) orelse
        panic("vulkan host: a new descriptor pool page cannot hold one set", .{});
    return .{ .set = set, .page = @intCast(self.descriptor_pages.items.len - 1) };
}

/// The kind of `binding` in a layout's entries; a binding the layout lacks fails by name.
fn bindingKind(
    entries: []const gpu_abi.BindGroupLayoutEntry,
    binding: u32,
    label: []const u8,
) gpu_abi.BindingKind {
    for (entries) |entry| {
        if (entry.binding == binding) {
            return entry.kind;
        }
    }
    panic("vulkan host: bind group `{s}` binds {d}, which its layout does not declare", .{ label, binding });
}

/// Drops one reference to a sampler, and destroys it once the app has released it and no bind group holds it.
fn releaseSampler(self: *Host, handle: u32, holder: Holder) void {
    const slot: *SamplerSlot = self.samplers.get(handle, "sampler");
    switch (holder) {
        .app => slot.released = true,
        .dependent => slot.bind_group_count -= 1,
    }
    if (slot.released and slot.bind_group_count == 0) {
        const removed: SamplerSlot = self.samplers.remove(self.gpa, handle, "sampler") catch outOfMemory();
        deferDestroy(self, .{ .sampler = removed.sampler }) catch outOfMemory();
    }
}

/// Drops one reference to a texture view, and destroys it once the app has released it and no bind group holds it.
fn releaseTextureView(self: *Host, handle: u32, holder: Holder) void {
    const slot: *TextureViewSlot = self.texture_views.get(handle, "texture view");
    switch (holder) {
        .app => slot.released = true,
        .dependent => slot.bind_group_count -= 1,
    }
    if (slot.released and slot.bind_group_count == 0) {
        const removed: TextureViewSlot = self.texture_views.remove(self.gpa, handle, "texture view") catch
            outOfMemory();
        deferDestroy(self, .{ .image_view = removed.view }) catch outOfMemory();
    }
}

/// Releases a texture: its image and memory are destroyed once the GPU is done with every batch that used them.
fn releaseTexture(self: *Host, handle: u32) void {
    const slot: TextureSlot = self.textures.remove(self.gpa, handle, "texture") catch outOfMemory();
    deferDestroy(self, .{ .image = .{ .image = slot.image, .memory = slot.memory } }) catch outOfMemory();
}

/// A bind group: one descriptor set, written once - WebGPU bind groups never change after creation. Each entry's
/// descriptor type comes from its layout's binding; a buffer size of 0 binds the rest of the buffer.
fn createBindGroup(
    self: *Host,
    layout_handle: u32,
    blob: []const u8,
    label: []const u8,
) BringUpError!u32 {
    const layout: BindGroupLayoutSlot = self.bind_group_layouts.get(layout_handle, "bind-group layout").*;
    var room: [max_bindings_per_group]gpu_abi.BindGroupEntry = undefined;
    const entries: []gpu_abi.BindGroupEntry = gpu_abi.decodeBindGroup(blob, &room) catch |err| {
        panic("vulkan host: bind group `{s}`: {s}", .{ label, @errorName(err) });
    };
    var group: BindGroupSlot = .{ .descriptor_set = try allocateDescriptorSet(self, layout.layout) };
    var buffer_infos: [max_bindings_per_group]vk.DescriptorBufferInfo = undefined;
    var image_infos: [max_bindings_per_group]vk.DescriptorImageInfo = undefined;
    var writes: [max_bindings_per_group]vk.WriteDescriptorSet = undefined;
    for (entries, 0..) |entry, index| {
        const kind: gpu_abi.BindingKind = bindingKind(layout.entries, entry.binding, label);
        writes[index] = .{
            .dst_set = group.descriptor_set.set,
            .dst_binding = entry.binding,
            .descriptor_count = 1,
            .descriptor_type = descriptorType(kind),
        };
        switch (entry.resource) {
            .buffer => {
                const buffer: *BufferSlot = self.buffers.get(entry.handle, "buffer");
                buffer_infos[index] = .{
                    .buffer = buffer.buffer,
                    .offset = entry.offset,
                    .range = if (entry.size == 0) vk.whole_size else entry.size,
                };
                writes[index].p_buffer_info = @ptrCast(&buffer_infos[index]);
            },
            .sampler => {
                const sampler: *SamplerSlot = self.samplers.get(entry.handle, "sampler");
                image_infos[index] = .{ .sampler = sampler.sampler };
                writes[index].p_image_info = @ptrCast(&image_infos[index]);
                sampler.bind_group_count += 1;
                group.held[group.held_count] = .{ .kind = .sampler, .handle = entry.handle };
                group.held_count += 1;
            },
            .texture_view => {
                const view: *TextureViewSlot = self.texture_views.get(entry.handle, "texture view");
                image_infos[index] = .{ .image_view = view.view, .image_layout = .general };
                writes[index].p_image_info = @ptrCast(&image_infos[index]);
                view.bind_group_count += 1;
                group.held[group.held_count] = .{ .kind = .texture_view, .handle = entry.handle };
                group.held_count += 1;
            },
        }
    }
    const no_copies = [_]vk.CopyDescriptorSet{};
    self.device_dispatch.updateDescriptorSets(self.device, @intCast(entries.len), &writes, 0, &no_copies);
    nameObject(self, .descriptor_set, @backingInt(group.descriptor_set.set), label);
    return self.bind_groups.add(self.gpa, group);
}

/// A pipeline layout over the groups' set layouts, without push constants. WebGPU's group number IS the Vulkan set
/// number (every device binds at least 4, checked at bring-up); a 0 handle - an empty slot - gets the empty layout.
fn createPipelineLayout(
    self: *Host,
    layout_handles: []const u32,
    label: []const u8,
) BringUpError!u32 {
    if (layout_handles.len > max_bind_groups) {
        panic("vulkan host: pipeline layout `{s}` has {d} groups; zimr binds at most {d}", .{
            label,
            layout_handles.len,
            max_bind_groups,
        });
    }
    var set_layouts: [max_bind_groups]vk.DescriptorSetLayout = undefined;
    var empty_sets: GroupSet = .empty;
    for (layout_handles, set_layouts[0..layout_handles.len], 0..) |handle, *set_layout, index| {
        if (handle == 0) {
            set_layout.* = try emptySetLayout(self);
            empty_sets.set(index);
            continue;
        }
        const group_layout: *BindGroupLayoutSlot = self.bind_group_layouts.get(handle, "bind-group layout");
        set_layout.* = group_layout.layout;
        if (group_layout.entries.len == 0) {
            empty_sets.set(index);
        }
    }
    const layout_info: vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = @intCast(layout_handles.len),
        .p_set_layouts = &set_layouts,
    };
    var layout: vk.PipelineLayout = .null_handle;
    try vk.check(self.device_dispatch.createPipelineLayout(self.device, &layout_info, null, &layout));
    nameObject(self, .pipeline_layout, @backingInt(layout), label);
    return self.pipeline_layouts.add(self.gpa, .{
        .layout = layout,
        .set_count = @intCast(layout_handles.len),
        .empty_sets = empty_sets,
    });
}

// ---- Render pipelines ----
//
// A render pipeline fixes, in one object, everything about how a draw runs: its shaders, how vertices are fetched and
// assembled into primitives, which faces are culled, how depth is tested, how colors blend, and the formats of the
// targets drawn into. Vulkan compiles all of it ahead of time, which is why a pipeline is created once and bound for
// many draws. The engine describes each pipeline in a blob (`gpu_abi.decodeRenderPipeline`). The functions below
// translate its parts, each an exhaustive switch from the engine's enumeration to Vulkan's: a value added on either
// side fails to compile until it is mapped.

/// A vertex attribute's format, as Vulkan's. Vulkan names a format by its components in memory order, each with its
/// size in bits, then how the bits are read: `sfloat` a signed floating-point number, `uint` an unsigned integer,
/// `unorm` an unsigned integer read as a fraction of its largest value (a byte's 0 to 255 as 0.0 to 1.0). So
/// `float32x3`, three 32-bit floats, is `r32g32b32_sfloat`, and `uint8x4_unorm`, four bytes read as fractions - a
/// color - is `r8g8b8a8_unorm`.
fn vertexFormat(format: gpu_abi.VertexFormat) vk.Format {
    return switch (format) {
        .float32 => .r32_sfloat,
        .float32x2 => .r32g32_sfloat,
        .float32x3 => .r32g32b32_sfloat,
        .float32x4 => .r32g32b32a32_sfloat,
        .uint32 => .r32_uint,
        .uint32x2 => .r32g32_uint,
        .uint8x4 => .r8g8b8a8_uint,
        .uint8x4_unorm => .r8g8b8a8_unorm,
    };
}

/// Whether a vertex buffer advances once per vertex or once per instance, as Vulkan's input rate. A per-instance
/// buffer holds what each copy of a mesh needs - its transform, its color - when one draw repeats the mesh.
fn inputRate(step_mode: gpu_abi.VertexStepMode) vk.VertexInputRate {
    return switch (step_mode) {
        .vertex => .vertex,
        .instance => .instance,
    };
}

/// How vertices assemble into primitives, as Vulkan's topology. A list takes vertices in independent groups - two
/// for each line, three for each triangle; a strip shares them, each new vertex adding one line or one triangle to
/// the ones before.
fn primitiveTopology(topology: gpu_abi.PrimitiveTopology) vk.PrimitiveTopology {
    return switch (topology) {
        .point_list => .point_list,
        .line_list => .line_list,
        .line_strip => .line_strip,
        .triangle_list => .triangle_list,
        .triangle_strip => .triangle_strip,
    };
}

/// Which faces are culled, as Vulkan's flags: none, the faces seen from the front, or the faces seen from behind.
/// Which side is the front, the pipeline's front-face rule decides (`createRenderPipeline`).
fn cullModeFlags(cull: gpu_abi.CullMode) vk.CullModeFlags {
    return switch (cull) {
        .none => .{},
        .front => .{ .front = true },
        .back => .{ .back = true },
    };
}

/// A depth comparison, as Vulkan's compare op. The two APIs name the comparisons alike, except that Vulkan spells
/// `less_equal` and `greater_equal` as `less_or_equal` and `greater_or_equal`.
fn compareOp(compare: gpu_abi.CompareFunction) vk.CompareOp {
    return switch (compare) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_or_equal,
        .always => .always,
    };
}

/// The four factors of a blend. The color channels and the alpha channel are each a sum of two products: the source
/// (what the fragment shader outputs) times its factor, and the destination (what the target already holds) times
/// its factor.
const BlendFactors = struct {
    source_color: vk.BlendFactor,
    destination_color: vk.BlendFactor,
    source_alpha: vk.BlendFactor,
    destination_alpha: vk.BlendFactor,
};

/// Color target 0's blending for each zimr blend mode - the factors the browser bridge gives WebGPU, so the two hosts
/// blend alike:
///
///     result.rgb = source.rgb * source_color + destination.rgb * destination_color
///     result.a   = source.a   * source_alpha + destination.a   * destination_alpha
///
/// `alpha` is transparency: the source covers the destination in proportion to its alpha. `additive` adds the
/// source's light, weighted by its alpha. `multiply` scales the destination by the source - shadows, tints.
/// `premultiplied` is transparency for colors already multiplied by their alpha. `none` writes the source as it
/// is. Every mode writes all four channels.
fn blendAttachment(mode: gpu_abi.BlendMode) vk.PipelineColorBlendAttachmentState {
    const all_channels: vk.ColorComponentFlags = .{ .r = true, .g = true, .b = true, .a = true };
    const factors: BlendFactors = switch (mode) {
        .none => return .{ .color_write_mask = all_channels },
        .alpha => .{
            .source_color = .src_alpha,
            .destination_color = .one_minus_src_alpha,
            .source_alpha = .one,
            .destination_alpha = .one_minus_src_alpha,
        },
        .additive => .{
            .source_color = .src_alpha,
            .destination_color = .one,
            .source_alpha = .one,
            .destination_alpha = .one,
        },
        .multiply => .{
            .source_color = .dst_color,
            .destination_color = .zero,
            .source_alpha = .dst_alpha,
            .destination_alpha = .zero,
        },
        .premultiplied => .{
            .source_color = .one,
            .destination_color = .one_minus_src_alpha,
            .source_alpha = .one,
            .destination_alpha = .one_minus_src_alpha,
        },
    };
    return .{
        .blend_enable = vk.bool_true,
        .src_color_blend_factor = factors.source_color,
        .dst_color_blend_factor = factors.destination_color,
        .color_blend_op = .add,
        .src_alpha_blend_factor = factors.source_alpha,
        .dst_alpha_blend_factor = factors.destination_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = all_channels,
    };
}

/// A shader stage's entry point name, zero-terminated, as Vulkan takes it. The engine's names (`vs_main`,
/// `fs_main`) are short; 64 bytes holds any of them.
const EntryName = [64:0]u8;

/// An entry point's name in an `EntryName`; a name longer than the buffer fails by name.
fn entryName(name: []const u8, label: []const u8) EntryName {
    var terminated: EntryName = @splat(0);
    if (name.len > terminated.len) {
        panic("vulkan host: render pipeline `{s}` has an entry point name of {d} bytes", .{ label, name.len });
    }
    @memcpy(terminated[0..name.len], name);
    return terminated;
}

/// What a render pipeline is made from, as the engine's call passes it: the pipeline layout and the two shader
/// modules (by handle), the blob describing everything else, and a label for messages.
const RenderPipelineRequest = struct {
    layout: u32,
    vs_module: u32,
    fs_module: u32,
    blob: []const u8,
    label: []const u8,
};

/// Takes one reference to a pipeline layout, for a pipeline made from it.
fn retainPipelineLayout(self: *Host, handle: u32) void {
    self.pipeline_layouts.get(handle, "pipeline layout").pipeline_count += 1;
}

/// Drops one reference to a pipeline layout, and destroys the layout once the app has released it and no pipeline
/// made from it remains.
fn releasePipelineLayout(self: *Host, handle: u32, holder: Holder) void {
    const slot: *PipelineLayoutSlot = self.pipeline_layouts.get(handle, "pipeline layout");
    switch (holder) {
        .app => slot.released = true,
        .dependent => slot.pipeline_count -= 1,
    }
    if (slot.released and slot.pipeline_count == 0) {
        const removed: PipelineLayoutSlot = self.pipeline_layouts.remove(self.gpa, handle, "pipeline layout") catch
            outOfMemory();
        deferDestroy(self, .{ .pipeline_layout = removed.layout }) catch outOfMemory();
    }
}

/// A render pipeline from its blob, built as the browser bridge builds its WebGPU pipeline, so the two hosts draw
/// alike. The pipeline is a set of state blocks, each answering one question about the draw:
///
///     shader stages    the vertex and fragment modules, and their entry points
///     vertex input     each vertex buffer's stride and step (its binding is its slot), and each attribute
///     input assembly   how vertices assemble into primitives
///     viewport         dynamic: one viewport and one scissor, set by every pass
///     rasterization    filled polygons, the cull mode, and which winding faces front
///     multisample      the sample count
///     depth            whether depth is tested and written, and the comparison
///     color blend      target 0 blends by the pipeline's mode; further targets are written unblended
///     rendering        the target formats, which every pass using the pipeline must match
fn createRenderPipeline(self: *Host, request: RenderPipelineRequest) BringUpError!u32 {
    const label: []const u8 = request.label;
    const descriptor: gpu_abi.RenderPipelineDescriptor = gpu_abi.decodeRenderPipeline(request.blob) catch |err| {
        panic("vulkan host: render pipeline `{s}`: {s}", .{ label, @errorName(err) });
    };
    // WGSL override constants are a WebGPU feature; the SPIR-V the native host runs has no counterpart for them.
    if (descriptor.constant_count > 0) {
        panic("vulkan host: render pipeline `{s}` sets WGSL override constants, which have no native path", .{label});
    }
    const layout: PipelineLayoutSlot = self.pipeline_layouts.get(request.layout, "pipeline layout").*;

    // Shader stages: each module with its entry point.
    const vertex_module: vk.ShaderModule = self.shader_modules.get(request.vs_module, "shader module").module;
    const fragment_module: vk.ShaderModule = self.shader_modules.get(request.fs_module, "shader module").module;
    const vertex_entry: EntryName = entryName(descriptor.vs_entry_point, label);
    const fragment_entry: EntryName = entryName(descriptor.fs_entry_point, label);
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = vertex_module, .p_name = &vertex_entry },
        .{ .stage = .{ .fragment = true }, .module = fragment_module, .p_name = &fragment_entry },
    };

    // Vertex input: a binding per vertex buffer - its slot, its stride (the bytes from one vertex to the next), and
    // whether it steps per vertex or per instance - and an attribute per shader input, which reads its binding at an
    // offset, in a format, into the input at its location.
    var bindings: [gpu_abi.max_vertex_buffers]vk.VertexInputBindingDescription = undefined;
    var attributes: [gpu_abi.max_vertex_attributes]vk.VertexInputAttributeDescription = undefined;
    var attribute_count: u32 = 0;
    for (descriptor.vertexBuffers(), 0..) |buffer_layout, slot| {
        bindings[slot] = .{
            .binding = @intCast(slot),
            .stride = buffer_layout.array_stride,
            .input_rate = inputRate(buffer_layout.step_mode),
        };
        for (descriptor.attributesOf(buffer_layout)) |attribute| {
            attributes[attribute_count] = .{
                .location = attribute.shader_location,
                .binding = @intCast(slot),
                .format = vertexFormat(attribute.format),
                .offset = attribute.offset,
            };
            attribute_count += 1;
        }
    }
    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = descriptor.vertex_buffer_count,
        .p_vertex_binding_descriptions = &bindings,
        .vertex_attribute_description_count = attribute_count,
        .p_vertex_attribute_descriptions = &attributes,
    };

    // Input assembly: the topology.
    const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = primitiveTopology(descriptor.topology),
    };

    // Viewport: dynamic, one viewport and one scissor, which every pass sets when it begins - the viewport with the
    // flip that makes Y point up, as in WebGPU.
    const viewport_state: vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .scissor_count = 1 };

    // Rasterization: filled polygons, the cull mode, and counter-clockwise triangles facing front - WebGPU's default,
    // and still right after the flip, because both APIs judge a triangle's winding in framebuffer coordinates.
    const rasterization: vk.PipelineRasterizationStateCreateInfo = .{
        .polygon_mode = .fill,
        .cull_mode = cullModeFlags(descriptor.cull),
        .front_face = .counter_clockwise,
        .line_width = 1,
    };

    // Multisampling: the sample count, which must equal the targets' (the engine gives both the same count).
    const sample_flags: vk.SampleCountFlags = sampleCountFlags(descriptor.sample_count) orelse
        panic("vulkan host: render pipeline `{s}` asks for {d} samples", .{ label, descriptor.sample_count });
    const multisample: vk.PipelineMultisampleStateCreateInfo = .{ .rasterization_samples = sample_flags };

    // Depth: tested only when the mode tests depth and the pipeline has a depth target to test against - the
    // bridge's rule - and written only when the mode also writes. Without a test, the comparison is `always`.
    const mode_tests_depth: bool = descriptor.depth != .none;
    const has_depth_target: bool = descriptor.depth_format != .undefined_;
    const tests_depth: bool = mode_tests_depth and has_depth_target;
    const writes_depth: bool = tests_depth and descriptor.writes_depth;
    const depth_compare: vk.CompareOp = if (tests_depth) compareOp(descriptor.depth.compareFunction()) else .always;
    const depth_stencil: vk.PipelineDepthStencilStateCreateInfo = .{
        .depth_test_enable = vk.bool32(tests_depth),
        .depth_write_enable = vk.bool32(writes_depth),
        .depth_compare_op = depth_compare,
    };

    // Color blend: target 0 blends by the pipeline's mode; any further targets - several outputs of one fragment
    // shader, written together - are written unblended.
    var blend_attachments: [gpu_abi.max_color_targets]vk.PipelineColorBlendAttachmentState = undefined;
    var color_formats: [gpu_abi.max_color_targets]vk.Format = undefined;
    blend_attachments[0] = blendAttachment(descriptor.blend);
    color_formats[0] = formatInfo(descriptor.color_format).format;
    for (descriptor.extraColorFormats(), 1..) |format, target| {
        blend_attachments[target] = blendAttachment(.none);
        color_formats[target] = formatInfo(format).format;
    }
    const target_count: u32 = 1 + descriptor.extra_color_format_count;
    const color_blend: vk.PipelineColorBlendStateCreateInfo = .{
        .attachment_count = target_count,
        .p_attachments = &blend_attachments,
    };

    // Dynamic state: what each pass sets instead of the pipeline - the viewport and the scissor.
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    // Dynamic rendering: the formats of the targets this pipeline draws into, which every pass using it must match.
    const depth_format: vk.Format = if (tests_depth) formatInfo(descriptor.depth_format).format else .undefined;
    const rendering: vk.PipelineRenderingCreateInfo = .{
        .color_attachment_count = target_count,
        .p_color_attachment_formats = &color_formats,
        .depth_attachment_format = depth_format,
    };
    const pipeline_info: vk.GraphicsPipelineCreateInfo = .{
        .p_next = &rendering,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterization,
        .p_multisample_state = &multisample,
        .p_depth_stencil_state = &depth_stencil,
        .p_color_blend_state = &color_blend,
        .p_dynamic_state = &dynamic_state,
        .layout = layout.layout,
    };
    var pipeline: vk.Pipeline = .null_handle;
    const pipelines: [*]vk.Pipeline = @ptrCast(&pipeline);
    try vk.check(self.device_dispatch.createGraphicsPipelines(
        self.device,
        .null_handle,
        1,
        @ptrCast(&pipeline_info),
        null,
        pipelines,
    ));
    nameObject(self, .pipeline, @backingInt(pipeline), label);
    retainPipelineLayout(self, request.layout);
    return self.render_pipelines.add(self.gpa, .{
        .pipeline = pipeline,
        .layout = layout.layout,
        .layout_handle = request.layout,
        .set_count = layout.set_count,
        .empty_sets = layout.empty_sets,
    });
}

// ---- Render passes ----
//
// A render pass is a stretch of drawing into fixed targets - here one color target, with a depth target and a
// multisample resolve when given - begun with dynamic rendering, so no render-pass or framebuffer objects exist. What
// the targets hold when it begins (loaded, or cleared) and whether what is drawn is kept (stored, or discarded) are
// fixed when it begins. Bind groups set during a pass are bound at the next draw (`bindDirtyGroups`).

/// What a pass's color target holds when the pass begins, as Vulkan's load op: its previous contents (load), or one
/// color everywhere (clear).
fn attachmentLoadOp(op: gpu_abi.LoadOp) vk.AttachmentLoadOp {
    return switch (op) {
        .load => .load,
        .clear => .clear,
    };
}

/// Whether what a pass drew is kept when the pass ends, as Vulkan's store op: kept (store), or not needed (discard,
/// which Vulkan calls `dont_care`) - a GPU may then skip writing the target back to memory.
fn attachmentStoreOp(op: gpu_abi.StoreOp) vk.AttachmentStoreOp {
    return switch (op) {
        .store => .store,
        .discard => .dont_care,
    };
}

/// An index buffer's element size, as Vulkan's index type: 16-bit indices take half the memory and reach 65536
/// vertices; 32-bit indices reach any mesh.
fn indexType(format: gpu_abi.IndexFormat) vk.IndexType {
    return switch (format) {
        .uint16 => .uint16,
        .uint32 => .uint32,
    };
}

/// What a render pass is begun with, as the browser's call passes it.
const RenderPassRequest = struct {
    encoder: u32,
    /// The color targets, one to `gpu_abi.max_color_targets`, all the same size.
    color_views: []const u32,
    clear: [4]f32,
    load_op: gpu_abi.LoadOp,
    store_op: gpu_abi.StoreOp,
    /// 0: no depth attachment.
    depth_view: u32,
    /// 0: no multisample resolve. A resolve needs exactly one color target.
    resolve_view: u32,
};

/// A render pass, begun as the browser's bridge begins one. Every color target is treated alike: loaded, or cleared
/// to the pass's color; stored, or discarded. With one color target and a resolve target, its samples are averaged
/// into the resolve target at the end. A depth target, when given, is cleared to 1.0 - the far end of the depth
/// range - and stored. A full barrier comes first, as before every pass; the render area, the viewport and the
/// scissor come from the first color target (WebGPU requires every target to be the same size).
fn beginRenderPass(self: *Host, request: RenderPassRequest) BringUpError!u32 {
    const command_buffer: vk.CommandBuffer = self.encoders.get(request.encoder, "command encoder").command_buffer;
    const color_count: usize = request.color_views.len;
    if (color_count == 0 or color_count > gpu_abi.max_color_targets) {
        const limit: usize = gpu_abi.max_color_targets;
        panic("vulkan host: a render pass has {d} color targets (1 to {d})", .{ color_count, limit });
    }
    const has_resolve: bool = request.resolve_view != 0;
    if (has_resolve and color_count != 1) {
        panic("vulkan host: a render pass resolves only with one color target, not {d}", .{color_count});
    }
    const first_color: TextureViewSlot = self.texture_views.get(request.color_views[0], "texture view").*;
    fullBarrier(self, command_buffer);
    var color_attachments: [gpu_abi.max_color_targets]vk.RenderingAttachmentInfo = undefined;
    for (request.color_views, 0..) |view_handle, target| {
        const color: TextureViewSlot = self.texture_views.get(view_handle, "texture view").*;
        color_attachments[target] = .{
            .image_view = color.view,
            .image_layout = .general,
            .load_op = attachmentLoadOp(request.load_op),
            .store_op = attachmentStoreOp(request.store_op),
            .clear_value = .{ .color = .{ .float_32 = request.clear } },
        };
    }
    if (has_resolve) {
        const resolve: TextureViewSlot = self.texture_views.get(request.resolve_view, "texture view").*;
        color_attachments[0].resolve_mode = .{ .average = true };
        color_attachments[0].resolve_image_view = resolve.view;
        color_attachments[0].resolve_image_layout = .general;
    }
    var depth_attachment: vk.RenderingAttachmentInfo = undefined;
    const has_depth: bool = request.depth_view != 0;
    if (has_depth) {
        const depth: TextureViewSlot = self.texture_views.get(request.depth_view, "texture view").*;
        depth_attachment = .{
            .image_view = depth.view,
            .image_layout = .general,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
        };
    }
    const rendering_info: vk.RenderingInfo = .{
        .render_area = .{ .extent = first_color.extent },
        .layer_count = 1,
        .color_attachment_count = @intCast(color_count),
        .p_color_attachments = &color_attachments,
        .p_depth_attachment = if (has_depth) &depth_attachment else null,
    };
    self.device_dispatch.cmdBeginRendering(command_buffer, &rendering_info);
    // WebGPU's normalized device coordinates point Y up; Vulkan's point it down. A viewport of negative height,
    // starting at the bottom, flips Y back - and both APIs then agree on where every pixel lands.
    const width: f32 = @floatFromInt(first_color.extent.width);
    const height: f32 = @floatFromInt(first_color.extent.height);
    const viewport: vk.Viewport = .{
        .x = 0,
        .y = height,
        .width = width,
        .height = -height,
        .min_depth = 0,
        .max_depth = 1,
    };
    self.device_dispatch.cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));
    const scissor: vk.Rect2D = .{ .extent = first_color.extent };
    self.device_dispatch.cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor));
    return self.render_passes.add(self.gpa, .{ .command_buffer = command_buffer });
}

/// Binds every group set since the last draw or dispatch (or since the pipeline changed) against the bound pipeline's
/// layout, at the pass's bind point.
///
/// A set whose layout in the pipeline is empty gets nothing. WebGPU lets such a slot keep whatever group was bound
/// there before - the engine's shader runtime fills the slots below a shader's own groups with empty layouts, and the
/// 2D renderer's groups stay bound in them - since no shader can read an empty set. Vulkan requires a bound set to
/// match the pipeline's set layout, and needs nothing bound where the shaders read nothing; so the host binds nothing
/// there.
fn bindDirtyGroups(self: *Host, pass: *PassSlot) void {
    const no_dynamic_offsets = [_]u32{};
    for (0..pass.pipeline_set_count) |index| {
        const set: vk.DescriptorSet = pass.groups[index];
        const is_empty_in_pipeline: bool = pass.pipeline_empty_sets.isSet(index);
        if (!pass.dirty_groups.isSet(index) or set == .null_handle or is_empty_in_pipeline) {
            continue;
        }
        const sets = [_]vk.DescriptorSet{set};
        self.device_dispatch.cmdBindDescriptorSets(
            pass.command_buffer,
            pass.bind_point,
            pass.pipeline_layout,
            @intCast(index),
            1,
            &sets,
            0,
            &no_dynamic_offsets,
        );
        pass.dirty_groups.unset(index);
    }
}

// ---- Compute pipelines ----
//
// A compute pipeline is one kernel entry of a shader module, with the pipeline layout its bind groups follow. The
// module is the kernel file's SPIR-V, holding every entry of the file; the pipeline names the one it runs. A compute
// pass records dispatches into its encoder's command buffer like a render pass records draws - groups recorded as
// they are set, bound at the next dispatch, at the compute bind point - but begins no rendering: a full barrier at
// its start orders it after everything before, and one before each later dispatch orders the dispatches among
// themselves, as WebGPU orders them.

/// A compute pipeline running the entry `entry_point` of `module_handle`, laid out by `layout_handle`.
fn createComputePipeline(
    self: *Host,
    layout_handle: u32,
    module_handle: u32,
    entry_point: []const u8,
    label: []const u8,
) BringUpError!PipelineSlot {
    const layout: PipelineLayoutSlot = self.pipeline_layouts.get(layout_handle, "pipeline layout").*;
    const module: vk.ShaderModule = self.shader_modules.get(module_handle, "shader module").module;
    const entry: EntryName = entryName(entry_point, label);
    const create_info: vk.ComputePipelineCreateInfo = .{
        .stage = .{ .stage = .{ .compute = true }, .module = module, .p_name = &entry },
        .layout = layout.layout,
        // Not derived from another pipeline.
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = .null_handle;
    const no_pipeline_cache: vk.PipelineCache = .null_handle;
    const result: vk.Result = self.device_dispatch.createComputePipelines(
        self.device,
        no_pipeline_cache,
        1,
        @ptrCast(&create_info),
        null,
        @ptrCast(&pipeline),
    );
    // A refusal's own code in the log - the driver's, raw - since `vk.check` folds the codes it does not name into
    // one, and a compute pipeline is where a driver refuses a shader it cannot compile.
    if (result != .success) {
        log.err("compute pipeline '{s}' (entry '{s}'): the driver answered {d}", .{
            label,
            entry_point,
            @backingInt(result),
        });
    }
    try vk.check(result);
    nameObject(self, .pipeline, @backingInt(pipeline), label);
    retainPipelineLayout(self, layout_handle);
    return .{
        .pipeline = pipeline,
        .layout = layout.layout,
        .layout_handle = layout_handle,
        .set_count = layout.set_count,
        .empty_sets = layout.empty_sets,
    };
}

// ---- Shutdown ----
//
// Vulkan objects are destroyed before what created them: the device's objects before the device, the device and the
// surface before the instance, and the instance before the library closes. The host destroys in that order, once the
// GPU has finished everything.

/// Tears the host down after the app's own teardown: waits for the GPU, destroys everything it created, closes the
/// library, and returns what the validation layer counted (its object tracker reports anything still alive as an
/// error when the device and instance are destroyed - after this returns, the counts are final).
pub fn shutdown() MessageCounts {
    const self: *Host = host orelse return .{};
    // The screen's texture and view, and the kept frame's buffer, are the host's: released here, with everything
    // else the app released.
    if (self.screen) |screen| {
        if (screen.view != 0) {
            releaseTextureView(self, screen.view, .app);
            releaseTexture(self, screen.texture);
        }
    }
    // lint:off decl-order: the kept frame's buffer is released as the app releases its own, with the commands below
    bufferDestroy(self.kept_frame.buffer);
    self.kept_frame.buffer = 0;
    if (self.device != .null_handle) {
        // The GPU's work done. The result is not needed: a device that was lost is torn down just the same.
        _ = self.device_dispatch.deviceWaitIdle(self.device);
        // Everything released has finished on the GPU now: destroy it all, then the staging memory.
        for (self.pending_destroys.items) |destroy| {
            executeDestroy(self, destroy);
        }
        for (self.retiring_destroys.items) |retiring| {
            executeDestroy(self, retiring.destroy);
        }
        for (self.staging.chunks.items) |chunk| {
            self.device_dispatch.destroyBuffer(self.device, chunk.buffer, null);
            self.device_dispatch.freeMemory(self.device, chunk.memory, null);
        }
        // Destroying a pool page frees every set still allocated from it.
        for (self.descriptor_pages.items) |page| {
            self.device_dispatch.destroyDescriptorPool(self.device, page.pool, null);
        }
        if (self.empty_set_layout != .null_handle) {
            self.device_dispatch.destroyDescriptorSetLayout(self.device, self.empty_set_layout, null);
        }
        // The swapchain's semaphores, views and swapchain; then the frame's semaphores, the timeline and the pool.
        for (self.swapchain.present_semaphores.items) |semaphore| {
            self.device_dispatch.destroySemaphore(self.device, semaphore, null);
        }
        for (self.swapchain.view_handles.items) |view_handle| {
            const slot: *TextureViewSlot = self.texture_views.get(view_handle, "texture view");
            if (slot.view != .null_handle) {
                self.device_dispatch.destroyImageView(self.device, slot.view, null);
            }
        }
        if (self.swapchain.handle != .null_handle) {
            self.swapchain_dispatch.destroySwapchainKHR(self.device, self.swapchain.handle, null);
        }
        for (self.acquire_semaphores) |semaphore| {
            if (semaphore != .null_handle) {
                self.device_dispatch.destroySemaphore(self.device, semaphore, null);
            }
        }
        if (self.timeline != .null_handle) {
            self.device_dispatch.destroySemaphore(self.device, self.timeline, null);
        }
        if (self.command_pool != .null_handle) {
            self.device_dispatch.destroyCommandPool(self.device, self.command_pool, null);
        }
        self.device_dispatch.destroyDevice(self.device, null);
    }
    // The instance's objects - the surface, the messenger - and then the instance.
    if (self.instance != .null_handle) {
        if (self.surface != .null_handle) {
            self.surface_dispatch.destroySurfaceKHR(self.instance, self.surface, null);
        }
        if (self.messenger != .null_handle) {
            if (self.instance_dispatch.destroyDebugUtilsMessengerEXT) |destroy_messenger| {
                destroy_messenger(self.instance, self.messenger, null);
            }
        }
        self.instance_dispatch.destroyInstance(self.instance, null);
    }
    if (self.library) |library| {
        native_os.closeVulkanLibrary(library);
    }
    // The host's own lists, on the CPU side.
    const counts: MessageCounts = self.counts;
    self.swapchain.present_semaphores.deinit(self.gpa);
    self.gpa.free(self.swapchain.images);
    self.swapchain.view_handles.deinit(self.gpa);
    self.free_command_buffers.deinit(self.gpa);
    self.retiring_command_buffers.deinit(self.gpa);
    self.texture_views.deinit(self.gpa);
    self.encoders.deinit(self.gpa);
    self.command_buffers.deinit(self.gpa);
    self.buffers.deinit(self.gpa);
    self.textures.deinit(self.gpa);
    self.samplers.deinit(self.gpa);
    self.shader_modules.deinit(self.gpa);
    for (self.bind_group_layouts.entries.items) |entry| {
        if (entry.live) {
            self.gpa.free(entry.slot.entries);
        }
    }
    self.bind_group_layouts.deinit(self.gpa);
    self.bind_groups.deinit(self.gpa);
    self.pipeline_layouts.deinit(self.gpa);
    self.render_pipelines.deinit(self.gpa);
    self.render_passes.deinit(self.gpa);
    self.compute_pipelines.deinit(self.gpa);
    self.compute_passes.deinit(self.gpa);
    for (self.reads.entries.items) |entry| {
        if (entry.live) {
            if (entry.slot.data) |data| {
                self.gpa.free(data);
            }
        }
    }
    self.reads.deinit(self.gpa);
    self.descriptor_pages.deinit(self.gpa);
    self.staging.chunks.deinit(self.gpa);
    self.staging.in_use.deinit(self.gpa);
    self.staging.retiring.deinit(self.gpa);
    self.staging.free.deinit(self.gpa);
    self.pending_destroys.deinit(self.gpa);
    self.retiring_destroys.deinit(self.gpa);
    self.gpa.destroy(self);
    host = null;
    return counts;
}

// ---- The calls: device, surface, frame, clock ----
//
// The entry points the engine calls through `wgpu.zig`: one for each call the browser's bridge answers, with the same
// names and arguments - handles and enumerations as integers, as JavaScript passes them. Each finds the host
// (`theHost`), converts what it was given (`enumFromValue`), and calls the function above that does the work; a
// failure ends the program, naming the call.

/// The browser's `requestAdapter` and `requestDevice` in one: brings Vulkan up, and returns the one device's handle.
pub fn initDevice() u32 {
    const self: *Host = theHost();
    bringUp(self) catch |err| panic("vulkan host: bringing Vulkan up failed: {s}", .{@errorName(err)});
    return 1;
}

/// The device's queue. A host has one, and its handle is 1.
pub fn deviceGetQueue(device: u32) u32 {
    _ = device;
    return 1;
}

/// The one surface: the window's swapchain, created here on first use.
pub fn getSurface() u32 {
    const self: *Host = theHost();
    if (self.window == null) {
        makeScreen(self, theScreen(self)) catch |err| {
            panic("vulkan host: creating the screen failed: {s}", .{@errorName(err)});
        };
        return 1;
    }
    if (self.swapchain.handle == .null_handle) {
        rebuildSwapchain(self) catch |err| panic("vulkan host: creating the swapchain failed: {s}", .{@errorName(err)});
    }
    return 1;
}

/// The format the swapchain presents in, as WebGPU names it - what `getPreferredCanvasFormat` answers in a browser.
pub fn surfaceGetFormat(surface: u32) u32 {
    _ = surface;
    const self: *Host = theHost();
    if (self.screen != null) {
        return @backingInt(screen_format);
    }
    const format: gpu_abi.TextureFormat = switch (self.swapchain.format) {
        .b8g8r8a8_unorm => .bgra8_unorm,
        else => .rgba8_unorm,
    };
    return @backingInt(format);
}

/// The swapchain's size in physical pixels (the window's, before the first swapchain).
pub fn surfaceGetSize(surface: u32) u32 {
    _ = surface;
    const self: *Host = theHost();
    if (self.screen) |screen| {
        return packSize(screen.width, screen.height);
    }
    if (self.swapchain.handle == .null_handle) {
        const window: *win32.Window = theWindow(self);
        return packSize(@max(window.client_width, 1), @max(window.client_height, 1));
    }
    return packSize(self.swapchain.extent.width, self.swapchain.extent.height);
}

/// The window's client size in logical pixels - the browser's CSS pixels: physical pixels over the monitor's scale.
pub fn surfaceGetCssSize(surface: u32) u32 {
    _ = surface;
    const self: *Host = theHost();
    // A screen has no monitor, so no scale: its logical pixels are its physical ones.
    if (self.screen) |screen| {
        return packSize(screen.width, screen.height);
    }
    const window: *win32.Window = theWindow(self);
    const scale: f32 = window.scale();
    const width: f32 = @floatFromInt(@max(window.client_width, 1));
    const height: f32 = @floatFromInt(@max(window.client_height, 1));
    const logical_width: u32 = @round(@max(width / scale, 1));
    const logical_height: u32 = @round(@max(height / scale, 1));
    return packSize(logical_width, logical_height);
}

/// The view of the image this frame draws into, acquired by the frame's first call.
pub fn surfaceGetCurrentTexture(surface: u32) u32 {
    _ = surface;
    const self: *Host = theHost();
    if (self.screen) |*screen| {
        return beginScreenFrame(self, screen) catch |err| {
            panic("vulkan host: beginning a frame on the screen failed: {s}", .{@errorName(err)});
        };
    }
    // WebGPU hands out ONE texture per frame: asked again before the present, it is the same texture.
    if (self.acquired_image) |image_index| {
        return self.swapchain.view_handles.items[image_index];
    }
    return acquireImage(self) catch |err| {
        panic("vulkan host: acquiring the next image failed: {s}", .{@errorName(err)});
    };
}

/// Presents the frame's image.
pub fn surfacePresent(surface: u32) void {
    _ = surface;
    const self: *Host = theHost();
    if (self.screen) |*screen| {
        endScreenFrame(self, screen) catch |err| {
            panic("vulkan host: ending a frame on the screen failed: {s}", .{@errorName(err)});
        };
        return;
    }
    // A frame that never asked for the current texture presents nothing, as in the browser.
    if (self.acquired_image == null) {
        return;
    }
    presentImage(self) catch |err| panic("vulkan host: presenting failed: {s}", .{@errorName(err)});
}

/// Milliseconds on a monotonic clock, as `performance.now()` gives them.
pub fn nowMs() f64 {
    return native_os.monotonicMilliseconds();
}

/// The last frame's GPU time in milliseconds; 0 means "not measured", as on a browser without timestamp queries.
pub fn gpuMsLast() f64 {
    return 0;
}

// ---- The calls: encoders, submits, buffers ----

/// A command encoder: a command buffer begun for recording. While any encoder is open, released objects wait for
/// the submission that closes it (`deferDestroy`).
pub fn deviceCreateCommandEncoder(device: u32) u32 {
    _ = device;
    const self: *Host = theHost();
    const command_buffer: vk.CommandBuffer = beginCommandBuffer(self) catch |err| {
        panic("vulkan host: creating a command encoder failed: {s}", .{@errorName(err)});
    };
    self.open_encoders += 1;
    const slot: EncoderSlot = .{ .command_buffer = command_buffer };
    return self.encoders.add(self.gpa, slot) catch outOfMemory();
}

/// Ends an encoder's recording; the command buffer gets a handle of its own, for `queueSubmit`.
pub fn commandEncoderFinish(encoder: u32) u32 {
    const self: *Host = theHost();
    const slot: EncoderSlot = self.encoders.remove(self.gpa, encoder, "command encoder") catch outOfMemory();
    vk.check(self.device_dispatch.endCommandBuffer(slot.command_buffer)) catch |err| {
        panic("vulkan host: finishing a command encoder failed: {s}", .{@errorName(err)});
    };
    const finished: CommandBufferSlot = .{ .command_buffer = slot.command_buffer };
    return self.command_buffers.add(self.gpa, finished) catch outOfMemory();
}

/// Submits a finished command buffer, after the queue's pending writes (`uploads`).
pub fn queueSubmit(queue: u32, cmd_buffer: u32) void {
    _ = queue;
    const self: *Host = theHost();
    const slot: CommandBufferSlot = self.command_buffers.remove(self.gpa, cmd_buffer, "command buffer") catch
        outOfMemory();
    // The encoder closes with its submit: when it was the last one open, this submit numbers the pending destroys.
    self.open_encoders -= 1;
    _ = submitBatch(self, slot.command_buffer, .null_handle) catch |err| {
        panic("vulkan host: submitting failed: {s}", .{@errorName(err)});
    };
}

/// A buffer that reads as zeros, as WebGPU promises (`createBuffer`).
pub fn deviceCreateBuffer(
    device: u32,
    size: u64,
    usage: u32,
    label_ptr: [*]const u8,
    label_len: usize,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const label: []const u8 = label_ptr[0..label_len];
    return createBuffer(self, size, @bitCast(usage), label) catch |err| {
        panic("vulkan host: creating buffer `{s}` ({d} bytes) failed: {s}", .{ label, size, @errorName(err) });
    };
}

/// Releases a buffer; it is destroyed once the GPU has finished with it.
pub fn bufferDestroy(buffer: u32) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (buffer == 0) {
        return;
    }
    const self: *Host = theHost();
    const slot: BufferSlot = self.buffers.remove(self.gpa, buffer, "buffer") catch outOfMemory();
    deferDestroy(self, .{ .buffer = .{ .buffer = slot.buffer, .memory = slot.memory } }) catch outOfMemory();
}

/// Writes bytes into a buffer, ordered on the queue as WebGPU's `writeBuffer` is (`writeBuffer`).
pub fn queueWriteBuffer(
    queue: u32,
    buffer: u32,
    offset: u64,
    data_ptr: [*]const u8,
    data_len: usize,
) void {
    _ = queue;
    const self: *Host = theHost();
    writeBuffer(self, buffer, offset, data_ptr[0..data_len]) catch |err| {
        panic("vulkan host: writing {d} bytes into a buffer failed: {s}", .{ data_len, @errorName(err) });
    };
}

/// Copies `size` bytes from one buffer to another in the encoder's commands, after a full barrier like every transfer.
pub fn encoderCopyBufferToBuffer(
    encoder: u32,
    source_handle: u32,
    source_offset: u32,
    destination_handle: u32,
    destination_offset: u32,
    size: u32,
) void {
    if (size == 0) {
        return;
    }
    const self: *Host = theHost();
    const command_buffer: vk.CommandBuffer = self.encoders.get(encoder, "command encoder").command_buffer;
    const source: vk.Buffer = self.buffers.get(source_handle, "buffer").buffer;
    const destination: vk.Buffer = self.buffers.get(destination_handle, "buffer").buffer;
    fullBarrier(self, command_buffer);
    const region: vk.BufferCopy = .{ .src_offset = source_offset, .dst_offset = destination_offset, .size = size };
    self.device_dispatch.cmdCopyBuffer(command_buffer, source, destination, 1, @ptrCast(&region));
}

/// Starts reading the first `size` bytes of a `map_read` buffer (WebGPU's `mapAsync`): the read sees everything
/// submitted before it, writes still pending included. A barrier to the host and the pending writes are submitted
/// now, and the read is ready when that batch completes.
pub fn bufferReadStart(
    buffer_handle: u32,
    size: u32,
) u32 {
    const self: *Host = theHost();
    const slot: *BufferSlot = self.buffers.get(buffer_handle, "buffer");
    if (slot.mapped == null) {
        panic("vulkan host: reading a buffer created without map_read", .{});
    }
    if (size > slot.size) {
        panic("vulkan host: reading {d} bytes of a {d}-byte buffer", .{ size, slot.size });
    }
    const uploads: vk.CommandBuffer = uploadsCommandBuffer(self) catch |err| {
        panic("vulkan host: starting a buffer read failed: {s}", .{@errorName(err)});
    };
    hostReadBarrier(self, uploads);
    flushUploads(self) catch |err| {
        panic("vulkan host: starting a buffer read failed: {s}", .{@errorName(err)});
    };
    const read: ReadSlot = .{ .buffer_handle = buffer_handle, .size = size, .serial = self.submitted };
    return self.reads.add(self.gpa, read) catch outOfMemory();
}

/// Whether a read is ready, without waiting: 0 while the GPU has work before it to finish, 1 once its bytes are
/// copied out (as the bridge's poll).
pub fn bufferReadPoll(read_handle: u32) u32 {
    const self: *Host = theHost();
    const read: *ReadSlot = self.reads.get(read_handle, "buffer read");
    if (read.data != null) {
        return 1;
    }
    const completed: u64 = readCompleted(self) catch |err| {
        panic("vulkan host: reading the timeline failed: {s}", .{@errorName(err)});
    };
    if (completed < read.serial) {
        return 0;
    }
    // A buffer destroyed while its read was pending ends the read with no bytes, as WebGPU rejects the map and the
    // bridge then reports the read ready and empty.
    const source: *BufferSlot = self.buffers.find(read.buffer_handle) orelse {
        read.data = self.gpa.alloc(u8, 0) catch outOfMemory();
        return 1;
    };
    const mapped: [*]u8 = source.mapped orelse panic("vulkan host: a read's buffer lost its mapping", .{});
    const bytes: []u8 = self.gpa.alloc(u8, read.size) catch outOfMemory();
    @memcpy(bytes, mapped[0..read.size]);
    read.data = bytes;
    return 1;
}

/// Copies a ready read's bytes into `ptr`, as many as both hold; nothing before the read is ready.
pub fn bufferReadInto(
    read_handle: u32,
    destination_ptr: [*]u8,
    destination_len: u32,
) void {
    const self: *Host = theHost();
    const read: *ReadSlot = self.reads.get(read_handle, "buffer read");
    const data: []u8 = read.data orelse return;
    const count: usize = @min(destination_len, data.len);
    @memcpy(destination_ptr[0..count], data[0..count]);
}

/// Releases a read and its bytes.
pub fn bufferReadRelease(read_handle: u32) void {
    const self: *Host = theHost();
    const read: ReadSlot = self.reads.remove(self.gpa, read_handle, "buffer read") catch outOfMemory();
    if (read.data) |data| {
        self.gpa.free(data);
    }
}

// ---- The calls: textures, samplers, shader modules ----

/// A texture that reads as zeros, as WebGPU promises (`createTexture`).
pub fn deviceCreateTexture(
    device: u32,
    width: u32,
    height: u32,
    format: u32,
    usage: u32,
    label_ptr: [*]const u8,
    label_len: usize,
    sample_count: u32,
    mip_level_count: u32,
    array_layers: u32,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const request: TextureRequest = .{
        .width = width,
        .height = height,
        .format = format,
        .usage = usage,
        .label = label_ptr[0..label_len],
        .sample_count = sample_count,
        .mip_level_count = mip_level_count,
        .array_layers = array_layers,
    };
    return createTexture(self, request) catch |err| {
        panic("vulkan host: creating texture `{s}` ({d}x{d}) failed: {s}", .{
            request.label,
            width,
            height,
            @errorName(err),
        });
    };
}

/// The texture's default view (`createTextureView`).
pub fn textureCreateView(texture: u32) u32 {
    const self: *Host = theHost();
    return createTextureView(self, texture, .{}) catch |err| {
        panic("vulkan host: creating a texture view failed: {s}", .{@errorName(err)});
    };
}

/// Releases a texture; it is destroyed once the GPU has finished with it.
pub fn textureDestroy(texture: u32) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (texture == 0) {
        return;
    }
    releaseTexture(theHost(), texture);
}

/// Releases a texture view. A swapchain image's view belongs to the host, which keeps it.
pub fn textureViewDestroy(id: u32) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (id == 0) {
        return;
    }
    const self: *Host = theHost();
    // A swapchain image's view belongs to the host, which keeps it for the swapchain's life.
    if (self.texture_views.get(id, "texture view").is_swapchain_image) {
        return;
    }
    releaseTextureView(self, id, .app);
}

/// Writes a whole mip level of a texture, from its corner, ordered on the queue as WebGPU's `writeTexture` is.
pub fn queueWriteTexture(
    queue: u32,
    texture: u32,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    data_ptr: [*]const u8,
    data_len: usize,
    mip_level: u32,
) void {
    _ = queue;
    const self: *Host = theHost();
    const region: TextureRegion = .{
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
        .bytes_per_row = bytes_per_row,
        .mip_level = mip_level,
    };
    writeTexture(self, texture, region, data_ptr[0..data_len]) catch |err| {
        panic("vulkan host: writing a texture failed: {s}", .{@errorName(err)});
    };
}

/// Writes a rectangle of a texture's first mip level, ordered on the queue.
pub fn queueWriteTextureRegion(
    queue: u32,
    texture: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    data_ptr: [*]const u8,
    data_len: usize,
) void {
    _ = queue;
    const self: *Host = theHost();
    const region: TextureRegion = .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .bytes_per_row = bytes_per_row,
        .mip_level = 0,
    };
    writeTexture(self, texture, region, data_ptr[0..data_len]) catch |err| {
        panic("vulkan host: writing a texture region failed: {s}", .{@errorName(err)});
    };
}

/// A sampler, as the browser's bridge creates one (`createSampler`).
pub fn deviceCreateSampler(
    device: u32,
    mag_filter_linear: u32,
    min_filter_linear: u32,
    address_mode: u32,
    mipmap_filter_linear: u32,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const request: SamplerRequest = .{
        .magnify_linear = mag_filter_linear != 0,
        .minify_linear = min_filter_linear != 0,
        .mipmap_linear = mipmap_filter_linear != 0,
        .address_mode = enumFromValue(gpu_abi.AddressMode, address_mode, "a sampler's address mode"),
    };
    return createSampler(self, request) catch |err| {
        panic("vulkan host: creating a sampler failed: {s}", .{@errorName(err)});
    };
}

/// Releases the app's handle to a sampler; the sampler lives on while bind groups hold it, and is destroyed once the
/// GPU has finished with it.
pub fn samplerDestroy(id: u32) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (id == 0) {
        return;
    }
    const self: *Host = theHost();
    releaseSampler(self, id, .app);
}

/// Natively the module's bytes are the compiler's SPIR-V: the build embeds them under the name the web build gives
/// the WGSL, so the engine's call and its arguments are the same on both hosts.
pub fn deviceCreateShaderModuleWgsl(
    device: u32,
    wgsl_ptr: [*]const u8,
    wgsl_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const label: []const u8 = label_ptr[0..label_len];
    return createShaderModule(self, wgsl_ptr[0..wgsl_len], label) catch |err| {
        panic("vulkan host: creating shader module `{s}` failed: {s}", .{ label, @errorName(err) });
    };
}

/// Vulkan reads a shader module only while creating a pipeline, so it can go at once.
pub fn shaderModuleDestroy(id: u32) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (id == 0) {
        return;
    }
    const self: *Host = theHost();
    const slot: ShaderModuleSlot = self.shader_modules.remove(self.gpa, id, "shader module") catch outOfMemory();
    self.device_dispatch.destroyShaderModule(self.device, slot.module, null);
}

// ---- The calls: bind groups and layouts ----

/// A bind-group layout from its blob (`createBindGroupLayout`).
pub fn deviceCreateBindGroupLayout(
    device: u32,
    entries_ptr: [*]const u8,
    entries_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const label: []const u8 = label_ptr[0..label_len];
    return createBindGroupLayout(self, entries_ptr[0..entries_len], label) catch |err| {
        panic("vulkan host: creating bind-group layout `{s}` failed: {s}", .{ label, @errorName(err) });
    };
}

/// A bind group from its blob, written once (`createBindGroup`).
pub fn deviceCreateBindGroup(
    device: u32,
    layout: u32,
    entries_ptr: [*]const u8,
    entries_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const label: []const u8 = label_ptr[0..label_len];
    return createBindGroup(self, layout, entries_ptr[0..entries_len], label) catch |err| {
        panic("vulkan host: creating bind group `{s}` failed: {s}", .{ label, @errorName(err) });
    };
}

/// A pipeline layout over bind-group layouts (`createPipelineLayout`).
pub fn deviceCreatePipelineLayout(
    device: u32,
    bgls_ptr: [*]const u32,
    bgls_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const label: []const u8 = label_ptr[0..label_len];
    return createPipelineLayout(self, bgls_ptr[0..bgls_len], label) catch |err| {
        panic("vulkan host: creating pipeline layout `{s}` failed: {s}", .{ label, @errorName(err) });
    };
}

/// Releases a bind group; its descriptor set returns to its pool page once the GPU has finished with it.
pub fn bindGroupDestroy(
    id: u32,
) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (id == 0) {
        return;
    }
    const self: *Host = theHost();
    const slot: BindGroupSlot = self.bind_groups.remove(self.gpa, id, "bind group") catch outOfMemory();
    deferDestroy(self, .{ .descriptor_set = slot.descriptor_set }) catch outOfMemory();
    // The samplers and views the group held: released now, their destruction numbered by the same rule as the set's
    // (`deferDestroy`), so neither outlives the other's last use.
    for (slot.held[0..slot.held_count]) |held| {
        switch (held.kind) {
            .sampler => releaseSampler(self, held.handle, .dependent),
            .texture_view => releaseTextureView(self, held.handle, .dependent),
        }
    }
}

/// Releases a bind-group layout.
pub fn bindGroupLayoutDestroy(
    id: u32,
) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (id == 0) {
        return;
    }
    const self: *Host = theHost();
    const slot: BindGroupLayoutSlot = self.bind_group_layouts.remove(self.gpa, id, "bind-group layout") catch
        outOfMemory();
    // The entries are the CPU's alone; the Vulkan layout waits like any other object.
    self.gpa.free(slot.entries);
    deferDestroy(self, .{ .descriptor_set_layout = slot.layout }) catch outOfMemory();
}

/// Releases the app's handle to a pipeline layout; the layout itself lives on while pipelines made from it do
/// (`PipelineLayoutSlot`).
pub fn pipelineLayoutDestroy(
    id: u32,
) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (id == 0) {
        return;
    }
    const self: *Host = theHost();
    releasePipelineLayout(self, id, .app);
}

// ---- The calls: render pipelines and passes ----

/// A render pipeline from its blob (`createRenderPipeline`).
pub fn deviceCreateRenderPipeline(
    device: u32,
    layout: u32,
    vs_module: u32,
    fs_module: u32,
    descriptor_ptr: [*]const u8,
    descriptor_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const request: RenderPipelineRequest = .{
        .layout = layout,
        .vs_module = vs_module,
        .fs_module = fs_module,
        .blob = descriptor_ptr[0..descriptor_len],
        .label = label_ptr[0..label_len],
    };
    return createRenderPipeline(self, request) catch |err| {
        panic("vulkan host: creating render pipeline `{s}` failed: {s}", .{ request.label, @errorName(err) });
    };
}

/// Releases a render pipeline.
pub fn renderPipelineDestroy(
    id: u32,
) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (id == 0) {
        return;
    }
    const self: *Host = theHost();
    const slot: PipelineSlot = self.render_pipelines.remove(self.gpa, id, "render pipeline") catch outOfMemory();
    deferDestroy(self, .{ .pipeline = slot.pipeline }) catch outOfMemory();
    releasePipelineLayout(self, slot.layout_handle, .dependent);
}

/// Begins a render pass in an encoder (`beginRenderPass`).
pub fn encoderBeginRenderPass(
    encoder: u32,
    color_view: u32,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    load_op: u32,
    store_op: u32,
    depth_view: u32,
    resolve_view: u32,
) u32 {
    const self: *Host = theHost();
    const color_views = [_]u32{color_view};
    const request: RenderPassRequest = .{
        .encoder = encoder,
        .color_views = &color_views,
        .clear = .{ clear_r, clear_g, clear_b, clear_a },
        .load_op = enumFromValue(gpu_abi.LoadOp, load_op, "a render pass's load op"),
        .store_op = enumFromValue(gpu_abi.StoreOp, store_op, "a render pass's store op"),
        .depth_view = depth_view,
        .resolve_view = resolve_view,
    };
    return beginRenderPass(self, request) catch |err| {
        panic("vulkan host: beginning a render pass failed: {s}", .{@errorName(err)});
    };
}

/// Begins a render pass with several color targets in an encoder: each loaded or cleared, stored or discarded alike,
/// as the bridge begins one; no resolve.
pub fn encoderBeginRenderPassMrt(
    encoder: u32,
    views_ptr: [*]const u32,
    views_len: usize,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    load_op: u32,
    store_op: u32,
    depth_view: u32,
) u32 {
    const self: *Host = theHost();
    const request: RenderPassRequest = .{
        .encoder = encoder,
        .color_views = views_ptr[0..views_len],
        .clear = .{ clear_r, clear_g, clear_b, clear_a },
        .load_op = enumFromValue(gpu_abi.LoadOp, load_op, "a render pass's load op"),
        .store_op = enumFromValue(gpu_abi.StoreOp, store_op, "a render pass's store op"),
        .depth_view = depth_view,
        .resolve_view = 0,
    };
    return beginRenderPass(self, request) catch |err| {
        panic("vulkan host: beginning a render pass failed: {s}", .{@errorName(err)});
    };
}

/// Binds a render pipeline for the pass's next draws.
pub fn renderPassSetPipeline(
    pass: u32,
    pipeline: u32,
) void {
    const self: *Host = theHost();
    const slot: *PassSlot = self.render_passes.get(pass, "render pass");
    const bound: PipelineSlot = self.render_pipelines.get(pipeline, "render pipeline").*;
    self.device_dispatch.cmdBindPipeline(slot.command_buffer, .graphics, bound.pipeline);
    // Every group binds again at the next draw, against this pipeline's layout.
    slot.pipeline_layout = bound.layout;
    slot.pipeline_set_count = bound.set_count;
    slot.pipeline_empty_sets = bound.empty_sets;
    slot.dirty_groups = .full;
}

/// Sets a bind group for the pass's next draws. It is bound at the next draw, against the pipeline bound then.
pub fn renderPassSetBindGroup(
    pass: u32,
    group_index: u32,
    bind_group: u32,
) void {
    // A group of handle 0 is skipped, as the bridge skips it.
    if (bind_group == 0) {
        return;
    }
    const self: *Host = theHost();
    if (group_index >= max_bind_groups) {
        panic("vulkan host: bind group index {d}; zimr binds at most {d}", .{ group_index, max_bind_groups });
    }
    const slot: *PassSlot = self.render_passes.get(pass, "render pass");
    slot.groups[group_index] = self.bind_groups.get(bind_group, "bind group").descriptor_set.set;
    slot.dirty_groups.set(group_index);
}

/// Binds a vertex buffer to a slot, from `offset` to the buffer's end.
pub fn renderPassSetVertexBuffer(
    pass: u32,
    slot_index: u32,
    buffer: u32,
    offset: u64,
    size: u64,
) void {
    // Bound to the end of the buffer, as the bridge binds it (WebGPU's size is not passed on).
    _ = size;
    if (buffer == 0) {
        return;
    }
    const self: *Host = theHost();
    const slot: *PassSlot = self.render_passes.get(pass, "render pass");
    const buffers = [_]vk.Buffer{self.buffers.get(buffer, "buffer").buffer};
    const offsets = [_]vk.DeviceSize{offset};
    self.device_dispatch.cmdBindVertexBuffers(slot.command_buffer, slot_index, 1, &buffers, &offsets);
}

/// Binds the index buffer - 16- or 32-bit indices - from `offset` to the buffer's end.
pub fn renderPassSetIndexBuffer(
    pass: u32,
    buffer: u32,
    format: u32,
    offset: u64,
    size: u64,
) void {
    // Bound to the end of the buffer, as the bridge binds it.
    _ = size;
    if (buffer == 0) {
        return;
    }
    const self: *Host = theHost();
    const slot: *PassSlot = self.render_passes.get(pass, "render pass");
    const index_format: gpu_abi.IndexFormat = enumFromValue(gpu_abi.IndexFormat, format, "an index buffer's format");
    const index_type: vk.IndexType = indexType(index_format);
    const bound: vk.Buffer = self.buffers.get(buffer, "buffer").buffer;
    self.device_dispatch.cmdBindIndexBuffer(slot.command_buffer, bound, offset, index_type);
}

/// Draws primitives without an index buffer - vertices taken in order - first binding the groups set since the last
/// draw.
pub fn renderPassDraw(
    pass: u32,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void {
    const self: *Host = theHost();
    const slot: *PassSlot = self.render_passes.get(pass, "render pass");
    bindDirtyGroups(self, slot);
    self.device_dispatch.cmdDraw(slot.command_buffer, vertex_count, instance_count, first_vertex, first_instance);
}

/// Clips the pass's draws to a rectangle of the target, in pixels from its top-left corner. Both APIs place that
/// corner the same way - zimr's Y flip is the viewport's alone - so the rectangle passes through unchanged.
pub fn renderPassSetScissorRect(
    pass: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) void {
    const self: *Host = theHost();
    const slot: *PassSlot = self.render_passes.get(pass, "render pass");
    const scissor: vk.Rect2D = .{
        .offset = .{ .x = @intCast(x), .y = @intCast(y) },
        .extent = .{ .width = w, .height = h },
    };
    self.device_dispatch.cmdSetScissor(slot.command_buffer, 0, 1, @ptrCast(&scissor));
}

/// Draws indexed primitives, first binding the groups set since the last draw.
pub fn renderPassDrawIndexed(
    pass: u32,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    first_instance: u32,
) void {
    const self: *Host = theHost();
    const slot: *PassSlot = self.render_passes.get(pass, "render pass");
    bindDirtyGroups(self, slot);
    self.device_dispatch.cmdDrawIndexed(
        slot.command_buffer,
        index_count,
        instance_count,
        first_index,
        base_vertex,
        first_instance,
    );
}

/// Ends the render pass.
pub fn renderPassEnd(
    pass: u32,
) void {
    const self: *Host = theHost();
    const slot: PassSlot = self.render_passes.remove(self.gpa, pass, "render pass") catch outOfMemory();
    self.device_dispatch.cmdEndRendering(slot.command_buffer);
}

// ---- The calls: compute ----

/// A compute pipeline running one entry of a kernel module (`createComputePipeline`).
pub fn deviceCreateComputePipeline(
    device: u32,
    layout: u32,
    shader_module: u32,
    entry_point_ptr: [*]const u8,
    entry_point_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32 {
    _ = device;
    const self: *Host = theHost();
    const entry_point: []const u8 = entry_point_ptr[0..entry_point_len];
    const label: []const u8 = label_ptr[0..label_len];
    const slot: PipelineSlot = createComputePipeline(self, layout, shader_module, entry_point, label) catch |err| {
        panic("vulkan host: creating compute pipeline '{s}' failed: {s}", .{ label, @errorName(err) });
    };
    return self.compute_pipelines.add(self.gpa, slot) catch outOfMemory();
}

/// Releases a compute pipeline.
pub fn computePipelineDestroy(
    id: u32,
) void {
    // Releasing nothing (handle 0) is a no-op, as the browser's object table makes it.
    if (id == 0) {
        return;
    }
    const self: *Host = theHost();
    const slot: PipelineSlot = self.compute_pipelines.remove(self.gpa, id, "compute pipeline") catch outOfMemory();
    deferDestroy(self, .{ .pipeline = slot.pipeline }) catch outOfMemory();
    releasePipelineLayout(self, slot.layout_handle, .dependent);
}

/// Begins a compute pass in an encoder, after a full barrier like every pass.
pub fn encoderBeginComputePass(
    encoder: u32,
) u32 {
    const self: *Host = theHost();
    const command_buffer: vk.CommandBuffer = self.encoders.get(encoder, "command encoder").command_buffer;
    fullBarrier(self, command_buffer);
    return self.compute_passes.add(self.gpa, .{
        .command_buffer = command_buffer,
        .bind_point = .compute,
    }) catch outOfMemory();
}

/// Binds a compute pipeline for the pass's next dispatches.
pub fn computePassSetPipeline(
    pass: u32,
    pipeline: u32,
) void {
    const self: *Host = theHost();
    const slot: *PassSlot = self.compute_passes.get(pass, "compute pass");
    const bound: PipelineSlot = self.compute_pipelines.get(pipeline, "compute pipeline").*;
    self.device_dispatch.cmdBindPipeline(slot.command_buffer, .compute, bound.pipeline);
    // Every group binds again at the next dispatch, against this pipeline's layout.
    slot.pipeline_layout = bound.layout;
    slot.pipeline_set_count = bound.set_count;
    slot.pipeline_empty_sets = bound.empty_sets;
    slot.dirty_groups = .full;
}

/// Sets a bind group for the pass's next dispatches, bound at the next dispatch against the pipeline bound then.
pub fn computePassSetBindGroup(
    pass: u32,
    group_index: u32,
    bind_group: u32,
) void {
    // A group of handle 0 is skipped, as the bridge skips it.
    if (bind_group == 0) {
        return;
    }
    const self: *Host = theHost();
    if (group_index >= max_bind_groups) {
        panic("vulkan host: bind group index {d}; zimr binds at most {d}", .{ group_index, max_bind_groups });
    }
    const slot: *PassSlot = self.compute_passes.get(pass, "compute pass");
    slot.groups[group_index] = self.bind_groups.get(bind_group, "bind group").descriptor_set.set;
    slot.dirty_groups.set(group_index);
}

/// Dispatches `x * y * z` workgroups of the bound pipeline, first binding the groups set since the last dispatch.
///
/// WebGPU orders the dispatches of a pass: each one sees everything the ones before it wrote - a counting pass reads
/// the counts the pass before it cleared. Vulkan orders nothing by itself: two dispatches in one command buffer may
/// run at once, unless a barrier stands between them. So every dispatch after the pass's first waits behind a full
/// barrier, as every pass and transfer does (the first is ordered by the barrier that began the pass).
pub fn computePassDispatchWorkgroups(
    pass: u32,
    x: u32,
    y: u32,
    z: u32,
) void {
    const self: *Host = theHost();
    const slot: *PassSlot = self.compute_passes.get(pass, "compute pass");
    if (slot.has_dispatched) {
        fullBarrier(self, slot.command_buffer);
    }
    slot.has_dispatched = true;
    bindDirtyGroups(self, slot);
    self.device_dispatch.cmdDispatch(slot.command_buffer, x, y, z);
}

/// Ends the compute pass. Nothing is recorded: the next pass's full barrier orders what follows after it.
pub fn computePassEnd(
    pass: u32,
) void {
    const self: *Host = theHost();
    _ = self.compute_passes.remove(self.gpa, pass, "compute pass") catch outOfMemory();
}

/// A view of `mip_count` mip levels from `base_mip`: what a mipmap generator renders into, one level at a time.
pub fn textureCreateViewMip(
    texture: u32,
    base_mip: u32,
    mip_count: u32,
) u32 {
    const self: *Host = theHost();
    return createTextureView(self, texture, .{ .base_mip = base_mip, .mip_count = mip_count }) catch |err| {
        panic("vulkan host: creating a mip-level view failed: {s}", .{@errorName(err)});
    };
}

/// A 2D-array view of the first `layer_count` layers.
pub fn textureCreateViewArray(
    texture: u32,
    layer_count: u32,
) u32 {
    const self: *Host = theHost();
    return createTextureView(self, texture, .{ .layer_count = layer_count }) catch |err| {
        panic("vulkan host: creating an array view failed: {s}", .{@errorName(err)});
    };
}

/// A 2D view of the one layer `layer`: what a render pass draws into, layer by layer, and what a shader samples as
/// an ordinary 2D texture.
pub fn textureCreateViewLayer(
    texture: u32,
    layer: u32,
) u32 {
    const self: *Host = theHost();
    return createTextureView(self, texture, .{ .mip_count = 1, .base_layer = layer }) catch |err| {
        panic("vulkan host: creating a layer view failed: {s}", .{@errorName(err)});
    };
}

/// The vendor's name for a PCI vendor id, for the usual GPU makers; null for the rest.
fn vendorName(vendor_id: u32) ?[]const u8 {
    return switch (vendor_id) {
        0x10de => "NVIDIA",
        0x1002 => "AMD",
        0x8086 => "Intel",
        0x13b5 => "ARM",
        0x5143 => "Qualcomm",
        0x106b => "Apple",
        0x10005 => "Mesa",
        else => null,
    };
}

/// The GPU, described as the browser's adapter info is - `vendor | device | description` - into `ptr[0..cap]`:
/// the vendor named from its PCI id (or the id in hexadecimal), the device's name, and the Vulkan version its driver
/// offers. Returns how many bytes were written, cut at `cap`.
pub fn adapterInfo(
    ptr: [*]u8,
    cap: u32,
) u32 {
    const self: *Host = theHost();
    const gpu: Gpu = self.gpu;
    var vendor_buffer: [16]u8 = undefined;
    const vendor: []const u8 = vendorName(gpu.vendor_id) orelse
        (bufPrint(&vendor_buffer, "0x{x}", .{gpu.vendor_id}) catch "unknown");
    var text_buffer: [vk.max_physical_device_name_size + 64]u8 = undefined;
    const text: []const u8 = bufPrint(&text_buffer, "{s} | {s} | Vulkan {d}.{d}", .{
        vendor,
        vk.fixedName(&gpu.name),
        vk.apiVersionMajor(gpu.api_version),
        vk.apiVersionMinor(gpu.api_version),
    }) catch "adapter info unavailable";
    const written: usize = @min(text.len, cap);
    @memcpy(ptr[0..written], text[0..written]);
    return @intCast(written);
}

/// Copies a texture's first `width` by `height` texels - mip level 0, layer 0, from the corner - into a buffer, each
/// row `bytes_per_row` apart, as WebGPU's `copyTextureToBuffer` does with those arguments. Vulkan counts a row's pitch
/// in texels, so the pitch must be a whole number of them (WebGPU's 256-byte multiple always is). Every image lives in
/// the GENERAL layout, which a copy reads from; a full barrier first orders it after the work that drew the texture.
pub fn encoderCopyTextureToBuffer(
    encoder: u32,
    texture_handle: u32,
    destination_handle: u32,
    bytes_per_row: u32,
    width: u32,
    height: u32,
) void {
    const self: *Host = theHost();
    const command_buffer: vk.CommandBuffer = self.encoders.get(encoder, "command encoder").command_buffer;
    const texture: TextureSlot = self.textures.get(texture_handle, "texture").*;
    const destination: vk.Buffer = self.buffers.get(destination_handle, "buffer").buffer;
    if (bytes_per_row % texture.texel_bytes != 0) {
        panic("vulkan host: a texture copy's rows are {d} bytes apart, not a whole number of {d}-byte texels", .{
            bytes_per_row,
            texture.texel_bytes,
        });
    }
    fullBarrier(self, command_buffer);
    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = bytes_per_row / texture.texel_bytes,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = aspectOf(texture.is_depth),
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    const regions: *const [1]vk.BufferImageCopy = &region;
    self.device_dispatch.cmdCopyImageToBuffer(command_buffer, texture.image, .general, destination, 1, regions);
}

/// Starts or stops keeping a copy of each frame the window presents (`KeptFrame`), for `readLastFrame`.
pub fn keepPresentedFrames(keep: bool) void {
    theHost().keeps_presented_frames = keep;
}

/// Records, into the present's batch, the copy of the swapchain image about to be presented into the kept frame's
/// buffer: a full barrier orders it after the frame's drawing, and a barrier to the host makes it readable once the
/// batch is done. The buffer is made at the first copy, and remade when the window's size changes.
fn copyPresentedFrame(
    self: *Host,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
) BringUpError!void {
    const extent: vk.Extent2D = self.swapchain.extent;
    const kept: *KeptFrame = &self.kept_frame;
    const is_buffer_fitting: bool = kept.buffer != 0 and kept.width == extent.width and kept.height == extent.height;
    if (!is_buffer_fitting) {
        if (kept.buffer != 0) {
            bufferDestroy(kept.buffer);
        }
        const byte_count: u64 = @as(u64, extent.width) * extent.height * 4;
        kept.buffer = try createBuffer(self, byte_count, .{ .map_read = true, .copy_dst = true }, "kept frame");
        kept.width = extent.width;
        kept.height = extent.height;
    }
    kept.is_bgra = switch (self.swapchain.format) {
        .b8g8r8a8_unorm, .b8g8r8a8_srgb => true,
        else => false,
    };
    imageBarrier(self, command_buffer, image, single_color_range, .general, .general);
    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        // Rows packed one after the other: a row length and image height of 0 mean the image's own.
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
    };
    const buffer: vk.Buffer = self.buffers.get(kept.buffer, "buffer").buffer;
    self.device_dispatch.cmdCopyImageToBuffer(command_buffer, image, .general, buffer, 1, @ptrCast(&region));
    hostReadBarrier(self, command_buffer);
}

/// The size of the frame last drawn, in pixels: the headless screen's, or the kept frame's of a window.
pub fn lastFrameSize() [2]u32 {
    const self: *Host = theHost();
    if (self.screen) |screen| {
        return .{ screen.width, screen.height };
    }
    return .{ self.kept_frame.width, self.kept_frame.height };
}

/// Reads the frame last drawn back as 8-bit RGBA, rows top to bottom, `width * height * 4` bytes into `out`: the
/// headless screen's (`readHeadlessScreen`), or the copy of a window's last presented frame (`KeptFrame`) - waited for
/// on the timeline, its channels put in RGBA order, its alpha made opaque, as the display shows it.
pub fn readLastFrame(out: []u8) BringUpError!void {
    const self: *Host = theHost();
    if (self.screen != null) {
        // lint:off decl-order: the screen's own read, with the copies it makes, follows
        return readHeadlessScreen(out);
    }
    const kept: KeptFrame = self.kept_frame;
    if (kept.buffer == 0) {
        panic("vulkan host: no frame kept to read - keepPresentedFrames, then present a frame", .{});
    }
    if (out.len != @as(usize, kept.width) * kept.height * 4) {
        const kept_byte_count: usize = @as(usize, kept.width) * kept.height * 4;
        panic("vulkan host: reading the kept frame into {d} bytes, not {d}", .{ out.len, kept_byte_count });
    }
    try waitTimeline(self, kept.serial);
    const mapped: [*]u8 = self.buffers.get(kept.buffer, "buffer").mapped orelse {
        panic("vulkan host: the kept frame's buffer is not mapped", .{});
    };
    @memcpy(out, mapped[0..out.len]);
    var texel_start: usize = 0;
    while (texel_start < out.len) : (texel_start += 4) {
        if (kept.is_bgra) {
            swap(u8, &out[texel_start], &out[texel_start + 2]);
        }
        out[texel_start + 3] = 255;
    }
}

/// Reads a headless host's screen back - the frame last drawn on it - as 8-bit RGBA, its rows top to bottom with none
/// of a copy's padding: `width * height * 4` bytes into `out`. It goes the way an app reads a texture back: a copy into
/// a buffer the CPU can map, its rows 256 bytes apart as WebGPU requires, then a read of that buffer - waited for here,
/// on the timeline, until the batch holding the copy has finished.
pub fn readHeadlessScreen(out: []u8) BringUpError!void {
    const self: *Host = theHost();
    const screen: *Screen = theScreen(self);
    const row_bytes: u32 = screen.width * 4;
    if (out.len != @as(usize, row_bytes) * screen.height) {
        panic("vulkan host: reading the screen into {d} bytes, not {d}", .{ out.len, row_bytes * screen.height });
    }
    const row_pitch: u32 = alignForward(u32, row_bytes, 256);
    const buffer_size: u32 = row_pitch * (screen.height - 1) + row_bytes;
    const usage: gpu_abi.BufferUsage = .{ .map_read = true, .copy_dst = true };
    const label: []const u8 = "screen read";
    const buffer: u32 = deviceCreateBuffer(1, buffer_size, @backingInt(usage), label.ptr, label.len);
    defer bufferDestroy(buffer);
    const encoder: u32 = deviceCreateCommandEncoder(1);
    encoderCopyTextureToBuffer(encoder, screen.texture, buffer, row_pitch, screen.width, screen.height);
    queueSubmit(1, commandEncoderFinish(encoder));
    const read_handle: u32 = bufferReadStart(buffer, buffer_size);
    defer bufferReadRelease(read_handle);
    try waitTimeline(self, self.reads.get(read_handle, "buffer read").serial);
    if (bufferReadPoll(read_handle) == 0) {
        panic("vulkan host: the screen's read is not ready after its batch finished", .{});
    }
    const padded: []u8 = self.gpa.alloc(u8, buffer_size) catch outOfMemory();
    defer self.gpa.free(padded);
    bufferReadInto(read_handle, padded.ptr, buffer_size);
    for (0..screen.height) |row| {
        @memcpy(out[row * row_bytes ..][0..row_bytes], padded[row * row_pitch ..][0..row_bytes]);
    }
}
