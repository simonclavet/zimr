//! THE VULKAN HOST, HEADLESS - the native host driven through `wgpu.zig` exactly as the engine drives it, but without
//! a window, on whatever Vulkan driver the machine has: a GPU, or Mesa's software driver (lavapipe) where there is
//! none. Every run has the Khronos validation layer on, and passes only with no error and no warning from it - a run
//! without the layer fails, since silence from a layer that is not there proves nothing.
//!
//! The checks, in order:
//!
//!     clear   bring the device up headless, clear a texture in a render pass, submit, destroy what was made - the
//!             bring-up, the pass's barrier and attachment, the texture's zero-clear, the deferred destroys
//!     targets a render pass with two color targets and a depth target, its draws clipped to a scissor rectangle -
//!             the attachments of a multi-target pass, and the scissor, as the validation layer checks them
//!     copy    clear a texture to a color whose 8-bit values are exact, copy it into a buffer with WebGPU's row
//!             pitch, and read every texel back
//!     views   a mip-level view per level, each cleared by a pass of that level's size, and a 2D-array view
//!     read    write known words into a buffer, copy them into a `map_read` buffer and read them back: the write, the
//!             copy, the barrier to the host and the read, end to end, compared byte for byte
//!     compute run a kompute kernel (`double_it`) from its SPIR-V, as the native host runs every kernel - module,
//!             layout, pipeline, bind group, dispatch - twice in one pass, and read its buffer back: the floats it
//!             covers four times what they were (each dispatch saw the one before it), the ones past its count
//!             untouched
//!     engine  the same kernel through the engine's own compute path (`z.Compute`): its pipelines and bind
//!             groups made by `compute_host` from the SPIR-V, the data uploaded, two dispatches in one batch, and
//!             the result read back with `readLatest` once `readGeneration` shows it holds both
//!     zimrnum zimrnum's GPU sweep: every operation of `zn_conformance`'s table run through the engine on its kernel
//!             file's SPIR-V and judged against its CPU reference, as the `zimrnum_field` example judges it
//!     pipelines  every pipeline of zimrnum's training kernel files (`zn_train`, `zn_mlp`) made and released, the
//!             validation layer judging each
//!     kit     EfficientTDMPC's kernels of `zn_mlp` - the normed layer forward and backward (Mish and SimNorm), the
//!             two-hot loss, its gradient and its decode - run on the device and on the CPU twin from the same data,
//!             in the same order, and compared value by value: the row accessors, the shared row statistics and the
//!             uniform's newer fields, compiled for the device, compute what the host computes
//!     constant   a kernel writing storage-buffer elements by constant indices, at one level and at two, read back:
//!             the written elements hold their values and every other element its zero
//!     lifetimes  a texture view and a sampler released while a bind group holds them, and in the other order: the
//!             host keeps each alive until its handle and its last hold are gone, as WebGPU does
//!     sort    the counting sort (`sort_min`) - clear, count, prefix sum, scatter, four dispatches in one pass - and
//!             its result checked against the same sort on the CPU: the kernels' atomics, and the order the host
//!             keeps between the dispatches of a pass
//!     churn   create and destroy more bind groups than one descriptor pool page holds, writing a buffer and
//!             submitting once per round: freed descriptor sets must be used again and staging chunks recycled,
//!             so the host's pages and chunks stay bounded however long it runs
//!     large   repeat a write larger than a staging chunk: the dedicated chunk it needs must be reused round after
//!             round, not allocated anew
//!     screen  the headless screen, through the engine's surface calls: its size and format as given; a frame
//!             cleared to an exact color by a render pass into the current texture, then presented, reads back as
//!             that color in every texel; the next frame's texture, before anything draws, reads back as zeros

const std = @import("std");
const sortSlice = std.mem.sort;
const double_it = @import("double_it");
const constant_index = @import("constant_index");
const sort_min = @import("sort_min");
const conf = @import("zn_conformance");
const zn_binary = @import("zn_binary");
const zn_train = @import("zn_train");
const zn_mlp = @import("zn_mlp");
const zn_matmul = @import("zn_matmul");
const robotgpu_probe = @import("robotgpu_probe");
const robotgpu = @import("robotgpu");
const robotgpu_host = @import("robotgpu_host");
const zn = @import("zn");
const zn_unary = @import("zn_unary");
const zrl_binary = @import("zrl_binary");
const z = @import("zimr");
const zm = @import("zm");
const isFinite = zm.isFinite;

const eql = std.mem.eql;
const print = std.debug.print;
const test_options = @import("vk_host_test_options");
const writeInt = std.mem.writeInt;
const Allocator = std.mem.Allocator;
const asBytes = std.mem.asBytes;
const testing = std.testing;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const fieldNames = std.meta.fieldNames;
const FieldEnum = std.meta.FieldEnum;
const float = zm.float;
const inf = zm.inf;
const pi = zm.pi;
const sliceAsBytes = std.mem.sliceAsBytes;
const Random = std.Random;
const sort = sortSlice;

const wgpu = z.wgpu;
const vulkan_host = wgpu.vulkan_host;
const clamp = zm.clamp;

/// A render pass that clears a small texture, submitted and waited for by the shutdown that follows.
fn clearTexture(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) void {
    const texture: wgpu.TextureHandle = wgpu.createTexture(device, .{
        .width = 4,
        .height = 4,
        .format = .rgba8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true },
        .label = "clear target",
    });
    const view: wgpu.TextureViewHandle = wgpu.createTextureView(texture);
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    const pass: wgpu.RenderPassEncoderHandle = wgpu.render_pass.begin(.{
        .encoder = encoder,
        .color_view = view,
        .clear = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 },
    });
    wgpu.render_pass.end(pass);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    wgpu.destroyTextureView(view);
    wgpu.destroyTexture(texture);
}

/// An 8 by 8 texture a render pass can draw into.
fn createRenderTarget(
    device: wgpu.DeviceHandle,
    format: wgpu.TextureFormat,
    label: []const u8,
) wgpu.TextureHandle {
    return wgpu.createTexture(device, .{
        .width = 8,
        .height = 8,
        .format = format,
        .usage = .{ .render_attachment = true },
        .label = label,
    });
}

/// A render pass with two color targets and a depth target, cleared, a scissor rectangle set, submitted and waited
/// for by the shutdown that follows. Checked by the validation layer: any misuse is reported as a validation
/// message, and a message fails the test.
fn clearTwoTargets(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) void {
    const first_texture: wgpu.TextureHandle = createRenderTarget(device, .rgba8_unorm, "first target");
    const second_texture: wgpu.TextureHandle = createRenderTarget(device, .rgba8_unorm, "second target");
    const depth_texture: wgpu.TextureHandle = createRenderTarget(device, .depth24_plus, "depth target");
    const first_view: wgpu.TextureViewHandle = wgpu.createTextureView(first_texture);
    const second_view: wgpu.TextureViewHandle = wgpu.createTextureView(second_texture);
    const depth_view: wgpu.TextureViewHandle = wgpu.createTextureView(depth_texture);
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    const color_views = [_]wgpu.TextureViewHandle{ first_view, second_view };
    const pass: wgpu.RenderPassEncoderHandle = wgpu.render_pass.beginMrt(.{
        .encoder = encoder,
        .color_views = &color_views,
        .clear = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 },
        .depth_view = depth_view,
    });
    wgpu.render_pass.setScissorRect(pass, 2, 2, 4, 4);
    wgpu.render_pass.end(pass);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    wgpu.destroyTextureView(first_view);
    wgpu.destroyTextureView(second_view);
    wgpu.destroyTextureView(depth_view);
    wgpu.destroyTexture(first_texture);
    wgpu.destroyTexture(second_texture);
    wgpu.destroyTexture(depth_texture);
}

/// Writes `values` into `bytes` as consecutive little-endian u32: the bind-group blobs are built here by hand, from
/// their documented format, which also checks that the format the host reads is the one documented.
fn writeWords(bytes: []u8, values: []const u32) void {
    for (values, 0..) |value, index| {
        writeInt(u32, bytes[index * 4 ..][0..4], value, .little);
    }
}

/// The headless screen's size, in pixels: a row of `screen_width` texels fits one copy row (`copy_row_pitch`).
const screen_width: u32 = 16;
const screen_height: u32 = 8;

/// THE DEVICE THE TESTS SHARE: the engine's headless Vulkan host - one per process, as an engine's is - started by
/// the first test that asks, and its device and queue (`initDevice` gives every later caller the device already made).
/// An error without the validation layer: every check counts on it to see what the driver would not say.
const TestDevice = struct {
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    /// The validation layer's errors so far when the test opened the device: a test's own calls must add none.
    errors_at_open: u32,

    fn open() !TestDevice {
        if (!vulkan_host.isStarted()) {
            try vulkan_host.startHeadlessWithScreen(screen_width, screen_height);
        }
        const device: wgpu.DeviceHandle = wgpu.initDevice();
        if (!vulkan_host.isValidating()) {
            return error.ValidationLayerMissing;
        }
        const queue: wgpu.QueueHandle = wgpu.getQueue(device);
        const errors_at_open: u32 = vulkan_host.messageCounts().errors;
        const opened: TestDevice = .{ .device = device, .queue = queue, .errors_at_open = errors_at_open };
        return opened;
    }

    /// The validation layer reported no error since the test opened the device: what a call that returns nothing -
    /// a clear, a view, a pipeline made - is judged by, and what every other call must also keep.
    fn expectNoNewValidationErrors(opened: TestDevice) !void {
        const errors_now: u32 = vulkan_host.messageCounts().errors;
        try testing.expectEqual(opened.errors_at_open, errors_now);
    }
};

/// A TEST's OWN SECONDS, printed when it ends: the build records every test's time too, but shows it only in its web
/// interface (`--webui`), and a run in a terminal or a sandbox has none.
const TestTimer = struct {
    name: []const u8,
    started_ms: f64,

    fn start(name: []const u8) TestTimer {
        const timer: TestTimer = .{ .name = name, .started_ms = z.native_os.monotonicMilliseconds() };
        return timer;
    }

    fn report(timer: TestTimer) void {
        const seconds: f64 = (z.native_os.monotonicMilliseconds() - timer.started_ms) / 1000.0;
        std.debug.print("vk-host-test: [{d:6.1} s] {s}\n", .{ seconds, timer.name });
    }
};

/// HOW LONG A READ MAY TAKE TO HOLD WHAT IT WAITS FOR, by the wall clock - a read polled in a loop gives up only once
/// this has passed. A count of polls would be a window set by how fast the CPU spins, and on lavapipe the "GPU" is that
/// same CPU: a slow moment reported a read that never came (zimrnum's cases, "the read never held the dispatch", in
/// about one device run of three). Every read here takes milliseconds; the deadline is there for one that never ends.
const ReadDeadline = struct {
    started_ms: f64,
    limit_ms: f64 = 10_000,

    fn start() ReadDeadline {
        const deadline: ReadDeadline = .{ .started_ms = z.native_os.monotonicMilliseconds() };
        return deadline;
    }

    fn hasPassed(deadline: ReadDeadline) bool {
        const elapsed_ms: f64 = z.native_os.monotonicMilliseconds() - deadline.started_ms;
        return elapsed_ms >= deadline.limit_ms;
    }
};

/// Copies a buffer's first `bytes.len` bytes into `bytes`, through a `map_read` buffer: a copy in an encoder, a
/// submit, then the read, polled until it is ready as the engine polls. False when it never becomes ready.
fn readBufferInto(
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    source: wgpu.BufferHandle,
    bytes: []u8,
) bool {
    const size: u32 = @intCast(bytes.len);
    const staging: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = size,
        .usage = .{ .map_read = true, .copy_dst = true },
        .label = "read staging",
    });
    defer wgpu.destroyBuffer(staging);
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    wgpu.copyBufferToBuffer(encoder, source, 0, staging, 0, size);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    const read: wgpu.BufferRead = wgpu.bufferReadStart(staging, size);
    defer wgpu.bufferReadRelease(read);
    const deadline: ReadDeadline = .start();
    while (!wgpu.bufferReadPoll(read)) {
        if (deadline.hasPassed()) {
            print("vk-host-test: a read never became ready\n", .{});
            return false;
        }
    }
    wgpu.bufferReadInto(read, bytes);
    return true;
}

/// The bytes the copy check must read back: the clear color `0.2, 0.4, 0.8, 1.0`, each channel a multiple of 1/255, so
/// its 8-bit value is exact (0.2 * 255 = 51) with no rounding to argue about.
const copy_expected = [4]u8{ 51, 102, 204, 255 };

/// WebGPU's alignment of a texture copy's rows in a buffer, in bytes.
const copy_row_pitch: u32 = 256;

/// Clears a 4 by 4 texture, copies it into a buffer with rows `copy_row_pitch` apart, and reads it back: every texel
/// must hold `copy_expected`. The bytes between one row's end and the next row's start are not compared.
fn copyTexture(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) bool {
    const side: u32 = 4;
    const texture: wgpu.TextureHandle = wgpu.createTexture(device, .{
        .width = side,
        .height = side,
        .format = .rgba8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true },
        .label = "copy source",
    });
    defer wgpu.destroyTexture(texture);
    const view: wgpu.TextureViewHandle = wgpu.createTextureView(texture);
    defer wgpu.destroyTextureView(view);
    // The last row needs only its texels; the rows before it, the whole pitch.
    const buffer_size: u32 = (side - 1) * copy_row_pitch + side * copy_expected.len;
    const buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = buffer_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
        .label = "copy destination",
    });
    defer wgpu.destroyBuffer(buffer);
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    const pass: wgpu.RenderPassEncoderHandle = wgpu.render_pass.begin(.{
        .encoder = encoder,
        .color_view = view,
        .clear = .{ .r = 0.2, .g = 0.4, .b = 0.8, .a = 1.0 },
    });
    wgpu.render_pass.end(pass);
    wgpu.copyTextureToBuffer(encoder, texture, buffer, copy_row_pitch, side, side);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    var bytes: [(4 - 1) * copy_row_pitch + 4 * copy_expected.len]u8 = @splat(0);
    if (!readBufferInto(device, queue, buffer, &bytes)) {
        return false;
    }
    for (0..side) |row| {
        for (0..side) |column| {
            const at: usize = row * copy_row_pitch + column * copy_expected.len;
            if (!eql(u8, bytes[at..][0..copy_expected.len], &copy_expected)) {
                print("vk-host-test: texel ({d}, {d}) came back {any}\n", .{ column, row, bytes[at..][0..4] });
                return false;
            }
        }
    }
    return true;
}

/// A view per mip level of an 8 by 8 texture with four levels, each cleared by a render pass of its own level's size
/// (8, 4, 2 and 1 texels square), and a 2D-array view of a three-layer texture. Checked by the validation layer, which
/// reports a view outside its texture, or a pass larger than its view.
fn mipAndArrayViews(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) void {
    const level_count: u32 = 4;
    const mipped: wgpu.TextureHandle = wgpu.createTexture(device, .{
        .width = 8,
        .height = 8,
        .format = .rgba8_unorm,
        .usage = .{ .render_attachment = true },
        .mip_level_count = level_count,
        .label = "mipped",
    });
    defer wgpu.destroyTexture(mipped);
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    for (0..level_count) |level| {
        const view: wgpu.TextureViewHandle = wgpu.createTextureViewMip(mipped, @intCast(level), 1);
        const pass: wgpu.RenderPassEncoderHandle = wgpu.render_pass.begin(.{
            .encoder = encoder,
            .color_view = view,
            .clear = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        });
        wgpu.render_pass.end(pass);
        wgpu.destroyTextureView(view);
    }
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    const layered: wgpu.TextureHandle = wgpu.createTexture(device, .{
        .width = 4,
        .height = 4,
        .format = .rgba8_unorm,
        .usage = .{ .texture_binding = true },
        .array_layers = 3,
        .label = "layered",
    });
    defer wgpu.destroyTexture(layered);
    wgpu.destroyTextureView(wgpu.createTextureViewArray(layered, 3));
}

/// Writes known words into a buffer and reads them back through a `map_read` buffer, comparing byte for byte.
fn readBack(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) bool {
    const words = [_]u32{ 0x01234567, 0x89abcdef, 0xdeadbeef, 0x00c0ffee };
    var written: [words.len * 4]u8 = undefined;
    writeWords(&written, &words);
    const source: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = written.len,
        .usage = .{ .copy_src = true, .copy_dst = true },
        .label = "read source",
    });
    defer wgpu.destroyBuffer(source);
    wgpu.queueWriteBuffer(queue, source, 0, &written);
    var read_bytes: [words.len * 4]u8 = @splat(0);
    if (!readBufferInto(device, queue, source, &read_bytes)) {
        return false;
    }
    return eql(u8, &read_bytes, &written);
}

/// How many workgroups of `workgroup_size` cover `count` invocations: the count divided by the size, rounded up.
fn workgroupsFor(count: u32, workgroup_size: u32) u32 {
    return (count + workgroup_size - 1) / workgroup_size;
}

/// A kernel file's buffers, bound as the native host binds them (`compute_host` with SPIR-V kernels): the `Params`
/// uniform and one storage buffer per `Buffers` field, each at the binding kompute declares, all in one bind group
/// that every entry of the file uses - a Vulkan layout may hold bindings an entry does not use.
///
/// The layout blob is a count, then five words per entry: its binding, visibility, kind, minimum size and view. The
/// group blob is a count, then seven per entry: its binding, resource and handle, then a u64 offset and a u64 size,
/// two words each - zero here, the whole buffer.
fn KernelBindings(comptime Kernel: type) type {
    return struct {
        const Self = @This();
        const Field = FieldEnum(Kernel.Buffers);
        const field_names = fieldNames(Kernel.Buffers);
        /// The uniform, then the fields.
        const entry_count: u32 = 1 + field_names.len;

        params_buffer: wgpu.BufferHandle,
        field_buffers: [field_names.len]wgpu.BufferHandle,
        layout: wgpu.BindGroupLayoutHandle,
        pipeline_layout: wgpu.PipelineLayoutHandle,
        group: wgpu.BindGroupHandle,

        fn create(device: wgpu.DeviceHandle) Self {
            const compute_stage: u32 = @bitCast(wgpu.ShaderStage{ .compute = true });
            const uniform_kind: u32 = @backingInt(wgpu.BindingKind.uniform_buffer);
            const storage_kind: u32 = @backingInt(wgpu.BindingKind.storage_buffer);
            const buffer_resource: u32 = @backingInt(wgpu.BindingResource.buffer);
            // A buffer entry has no view; the field is read all the same, so it holds a valid value.
            const no_view: u32 = @backingInt(wgpu.TextureViewDimension.d1);
            const params_size: u32 = @sizeOf(Kernel.Params);

            const params_buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
                .size = params_size,
                .usage = .{ .uniform = true, .copy_dst = true },
                .label = "params",
            });
            var layout_words: [1 + 5 * entry_count]u32 = undefined;
            var group_words: [1 + 7 * entry_count]u32 = @splat(0);
            layout_words[0] = entry_count;
            group_words[0] = entry_count;
            const uniform_binding: u32 = Kernel.g.uniform_binding;
            layout_words[1..6].* = .{ uniform_binding, compute_stage, uniform_kind, params_size, no_view };
            group_words[1..4].* = .{ uniform_binding, buffer_resource, @backingInt(params_buffer) };
            var field_buffers: [field_names.len]wgpu.BufferHandle = undefined;
            inline for (field_names, 0..) |name, field_index| {
                const size: u32 = @sizeOf(@FieldType(Kernel.Buffers, name));
                const binding: u32 = Kernel.g.bindingOf(@field(Field, name));
                field_buffers[field_index] = wgpu.createBuffer(device, .{
                    .size = size,
                    .usage = .{ .storage = true, .copy_src = true, .copy_dst = true },
                    .label = name,
                });
                const layout_at: usize = 1 + 5 * (1 + field_index);
                const group_at: usize = 1 + 7 * (1 + field_index);
                layout_words[layout_at..][0..5].* = .{ binding, compute_stage, storage_kind, size, no_view };
                const field_handle: u32 = @backingInt(field_buffers[field_index]);
                group_words[group_at..][0..3].* = .{ binding, buffer_resource, field_handle };
            }
            var layout_blob: [4 * layout_words.len]u8 = undefined;
            writeWords(&layout_blob, &layout_words);
            var group_blob: [4 * group_words.len]u8 = undefined;
            writeWords(&group_blob, &group_words);
            const layout: wgpu.BindGroupLayoutHandle = wgpu.createBindGroupLayout(
                device,
                &layout_blob,
                "kernel layout",
            );
            return .{
                .params_buffer = params_buffer,
                .field_buffers = field_buffers,
                .layout = layout,
                .pipeline_layout = wgpu.createPipelineLayout(device, &.{layout}, "kernel pipeline layout"),
                .group = wgpu.createBindGroup(device, layout, &group_blob, "kernel group"),
            };
        }

        /// The storage buffer of a `Buffers` field.
        fn buffer(bindings: Self, comptime field: Field) wgpu.BufferHandle {
            return bindings.field_buffers[@backingInt(field)];
        }

        fn destroy(bindings: Self) void {
            wgpu.destroyBindGroup(bindings.group);
            wgpu.destroyPipelineLayout(bindings.pipeline_layout);
            wgpu.destroyBindGroupLayout(bindings.layout);
            for (bindings.field_buffers) |field_buffer| {
                wgpu.destroyBuffer(field_buffer);
            }
            wgpu.destroyBuffer(bindings.params_buffer);
        }
    };
}

/// `double_it`'s SPIR-V, built as the native host builds every kernel (the host test's step in `build.zig`): its one
/// entry, `double`, doubles each of the first `count` floats of its buffer in place.
const double_it_spirv: []const u8 = @embedFile("double_it_spv");

/// How many floats the check doubles: not a multiple of the workgroup size, so lanes of the last workgroup fall past
/// it and take the kernel's early return - and the floats after it must come back as written.
const doubled_count: u32 = 1000;

/// Runs `double_it` on the GPU - its module, layout, pipeline and bind group made as `compute_host` makes them,
/// from the kernel file's own configuration and kompute's binding numbers - twice in one pass, and reads its buffer
/// back: the first `doubled_count` floats must be four times what they were, the rest as they were. The second
/// dispatch must see the first's writes, as WebGPU orders a pass's dispatches; on a GPU that runs dispatches at once,
/// a missing barrier between them shows here as floats only doubled. (lavapipe runs them one after another, so there
/// the check holds either way.)
fn runKernel(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) bool {
    const bindings: KernelBindings(double_it) = .create(device);
    defer bindings.destroy();
    const module: wgpu.ShaderModuleHandle = wgpu.createShaderModuleWgsl(device, double_it_spirv, "double_it");
    defer wgpu.destroyShaderModule(module);
    const pipeline: wgpu.ComputePipelineHandle = wgpu.createComputePipeline(
        device,
        bindings.pipeline_layout,
        module,
        "double",
        "double_it",
    );
    defer wgpu.destroyComputePipeline(pipeline);

    const params: double_it.Params = .{ .count = doubled_count };
    var input: [double_it.config.max]f32 = undefined;
    for (&input, 0..) |*value, index| {
        value.* = @floatFromInt(index);
    }
    wgpu.queueWriteBuffer(queue, bindings.params_buffer, 0, asBytes(&params));
    wgpu.queueWriteBuffer(queue, bindings.buffer(.data), 0, sliceAsBytes(&input));
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    const pass: wgpu.ComputePassEncoderHandle = wgpu.compute_pass.begin(encoder);
    wgpu.compute_pass.setPipeline(pass, pipeline);
    wgpu.compute_pass.setBindGroup(pass, 0, bindings.group);
    const workgroup_count: u32 = workgroupsFor(doubled_count, double_it.config.workgroup);
    wgpu.compute_pass.dispatchWorkgroups(pass, .{ .x = workgroup_count });
    wgpu.compute_pass.dispatchWorkgroups(pass, .{ .x = workgroup_count });
    wgpu.compute_pass.end(pass);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));

    var output: [double_it.config.max]f32 = @splat(0);
    if (!readBufferInto(device, queue, bindings.buffer(.data), sliceAsBytes(&output))) {
        return false;
    }
    for (input, output, 0..) |written, result, index| {
        const expected: f32 = if (index < doubled_count) written * 4 else written;
        if (result != expected) {
            print("vk-host-test: float {d} came back {d}, expected {d}\n", .{ index, result, expected });
            return false;
        }
    }
    return true;
}

/// Runs `double_it` through the engine's own compute path, as an app does: `Compute(double_it).initGpu` builds the
/// pipelines and bind groups from the kernel's SPIR-V (`compute_host`'s native path - the SPIR-V recognised by its
/// first word, kompute's declared binding numbers, every field in each layout); the data is uploaded; one batch runs
/// `double` twice; and `readLatest` is polled until `readGeneration` shows the mirror holds both dispatches - the
/// result of this batch, not of an earlier read. The first `doubled_count` floats must be four times what they were.
fn runEngineCompute(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const DoubleIt: type = z.Compute(double_it);
    const kernels = [_]DoubleIt.KernelWgsl{.{ .name = "double", .wgsl = double_it_spirv }};
    var compute: DoubleIt = try .initGpu(gpa, device, queue, &kernels);
    defer compute.deinit();

    var input: [double_it.config.max]f32 = undefined;
    for (&input, 0..) |*value, index| {
        value.* = @floatFromInt(index);
    }
    compute.upload(.data, &input);
    compute.beginBatch(.{ .count = doubled_count });
    compute.run("double", doubled_count);
    compute.run("double", doubled_count);
    compute.endBatch();
    const dispatched: u64 = compute.readGeneration().submitted;

    const deadline: ReadDeadline = .start();
    while (!deadline.hasPassed()) {
        const latest: ?[]const f32 = compute.readLatest(.data);
        const holds_this_batch: bool = compute.readGeneration().mirrored >= dispatched;
        const output: []const f32 = latest orelse continue;
        if (!holds_this_batch) {
            continue;
        }
        for (input[0..output.len], output, 0..) |written, result, index| {
            const expected: f32 = if (index < doubled_count) written * 4 else written;
            if (result != expected) {
                print("vk-host-test: through the engine, float {d} came back {d}, expected {d}\n", .{
                    index,
                    result,
                    expected,
                });
                return false;
            }
        }
        return true;
    }
    print("vk-host-test: the engine's read never held the batch\n", .{});
    return false;
}

/// Each zimrnum kernel file's SPIR-V: one module per file, holding all of the file's entries.
const zn_train_spirv: []const u8 = @embedFile("zn_train_spv");
const zn_mlp_spirv: []const u8 = @embedFile("zn_mlp_spv");
const zn_binary_spirv: []const u8 = @embedFile("zn_binary_spv");
const zn_matmul_spirv: []const u8 = @embedFile("zn_matmul_spv");
const zn_unary_spirv: []const u8 = @embedFile("zn_unary_spv");
const zrl_binary_spirv: []const u8 = @embedFile("zrl_binary_spv");
const robotgpu_probe_spirv: []const u8 = @embedFile("robotgpu_probe_spv");
/// Geno's get-up clip, baked (`examples/geno_ppo/getup.zclip`): the tracking check's reference.
const getup_zclip: []const u8 = @embedFile("geno_getup_zclip");
const robotgpu_spirv: []const u8 = @embedFile("robotgpu_spv");

/// A kernel file's entry table for `Compute.initGpu`: every entry the file declares (`kernels`), each with the file's
/// SPIR-V - natively the module is per file, and the pipeline names its entry.
fn spirvEntries(comptime Kernel: type, spirv: []const u8) [Kernel.kernels.len]z.Compute(Kernel).KernelWgsl {
    var table: [Kernel.kernels.len]z.Compute(Kernel).KernelWgsl = undefined;
    inline for (Kernel.kernels, 0..) |name, index| {
        table[index] = .{ .name = name, .wgsl = spirv };
    }
    return table;
}

/// The device's readback of `field`, once it holds every dispatch so far - polled as `runEngineCompute` polls.
fn deviceReadback(
    comptime Kernel: type,
    comptime Element: type,
    pipe: *z.Compute(Kernel),
    comptime field: FieldEnum(Kernel.Buffers),
) ?[]const Element {
    const dispatched: u64 = pipe.readGeneration().submitted;
    const deadline: ReadDeadline = .start();
    while (!deadline.hasPassed()) {
        const latest: ?[]const Element = pipe.readLatest(field);
        const holds_every_dispatch: bool = pipe.readGeneration().mirrored >= dispatched;
        if (latest != null and holds_every_dispatch) {
            return latest;
        }
    }
    return null;
}

/// What the robotgpu probe found (`runRobotgpuProbe`): each reduction's largest gap from the twin, as a share of the
/// sum of the magnitudes it added - null for the subgroup sum on a device without subgroup arithmetic in compute
/// shaders - and whether two runs on the device gave the same bits.
const ProbeOutcome = struct {
    subgroup_gap: ?f32,
    workgroup_gap: f32,
    repeats_exactly: bool,
};

/// The largest gap between `device_sums` and `twin_sums`, each sum measured against the sum of the magnitudes it was
/// made from (`magnitude_sums`): adding n numbers in another order moves the result by at most about n x epsilon of
/// that, which is the scale on which a reordering's rounding shows - and nothing else should.
fn reductionGap(
    device_sums: []const f32,
    twin_sums: []const f32,
    magnitude_sums: []const f32,
) f32 {
    var largest_gap: f32 = 0;
    for (device_sums, twin_sums, magnitude_sums) |device_sum, twin_sum, magnitude_sum| {
        const difference: f32 = @abs(device_sum - twin_sum);
        const scale: f32 = @max(magnitude_sum, 1.0e-30);
        largest_gap = @max(largest_gap, difference / scale);
    }
    return largest_gap;
}

/// THE ROBOTGPU PROBE: its two reductions - a subgroup's sum in one instruction, a workgroup's
/// through shared memory and barriers (`robotgpu_probe.zig`'s head) - on the device and on the twin, from the same
/// values of mixed sizes and signs, and each run twice on the device:
///
///     values --> device: subgroup_sum --> sums --+--> against the twin's, within the reordering's rounding
///                                                +--> against a second device run, bit for bit
///     values --> device: workgroup_sum --> sums --- the same two comparisons
///
/// A device without subgroup arithmetic in compute shaders skips the subgroup sum (its gap null).
/// A LOOP ON A UNIFORM WORKGROUP VALUE, barriers inside (`robotgpu_probe.uniform_loop`): five workgroups count down
/// seven rounds, the loop's exit read by every invocation together. Every invocation's sum - seven times its lane plus
/// 0 + 1 + ... + 6 - must be the same on the device, on the twin and from the closed form, exactly: small whole
/// numbers, which floats hold exactly.
fn runUniformLoop(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    const workgroup_size: u32 = robotgpu_probe.config.workgroup;
    const invocation_count: u32 = 5 * workgroup_size;
    const rounds: u32 = 7;
    const pipes = [2]*ProbeCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.element_count = invocation_count;
        pipe.params = .{ .value_count = invocation_count, .subgroup_size = 1, .uniform_rounds = rounds };
        pipe.run("uniform_loop", invocation_count);
    }
    const device_sums: []f32 = try gpa.alloc(f32, invocation_count);
    defer gpa.free(device_sums);
    on_device.readRange(.sums, 0, device_sums);
    const twin_sums: []f32 = try gpa.alloc(f32, invocation_count);
    defer gpa.free(twin_sums);
    twin.readRange(.sums, 0, twin_sums);
    const rounds_triangle: u32 = rounds * (rounds - 1) / 2;
    for (device_sums, twin_sums, 0..) |device_sum, twin_sum, invocation| {
        const lane: u32 = @as(u32, @intCast(invocation)) % workgroup_size;
        const expected: f32 = @floatFromInt(rounds * lane + rounds_triangle);
        if (device_sum != expected or twin_sum != expected) {
            return false;
        }
    }
    return true;
}

fn runRobotgpuProbe(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !ProbeOutcome {
    const capabilities: wgpu.vulkan_host.ComputeCapabilities = wgpu.computeCapabilities();
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    // 37 full workgroups and 5 values more, so the last workgroup and the last subgroup are partly empty.
    const workgroup_size: u32 = robotgpu_probe.config.workgroup;
    const value_count: u32 = 37 * workgroup_size + 5;
    const workgroup_count: u32 = (value_count + workgroup_size - 1) / workgroup_size;
    const values: []f32 = try gpa.alloc(f32, value_count);
    defer gpa.free(values);
    for (values, 0..) |*value, index| {
        const position: f32 = @floatFromInt(index);
        const size: f32 = @floatFromInt(1 + index % 7);
        value.* = @sin(0.37 * position) * size;
    }
    const has_subgroup_sums: bool = capabilities.hasSubgroupArithmetic();
    const subgroup_size: u32 = if (has_subgroup_sums) capabilities.subgroup_size else 1;
    const pipes = [2]*ProbeCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.element_count = value_count;
        pipe.upload(.values, values);
        pipe.params = .{ .value_count = value_count, .subgroup_size = subgroup_size };
    }
    // Each sum's scale: the sum of the magnitudes of the values it adds, by the partition each entry adds over.
    const subgroup_magnitudes: []f32 = try gpa.alloc(f32, value_count);
    defer gpa.free(subgroup_magnitudes);
    const workgroup_magnitudes: []f32 = try gpa.alloc(f32, workgroup_count);
    defer gpa.free(workgroup_magnitudes);
    @memset(workgroup_magnitudes, 0);
    for (subgroup_magnitudes, 0..) |*magnitude_sum, index| {
        const first_of_subgroup: usize = index - index % subgroup_size;
        const end_of_subgroup: usize = @min(first_of_subgroup + subgroup_size, value_count);
        var total: f32 = 0;
        for (values[first_of_subgroup..end_of_subgroup]) |value| {
            total += @abs(value);
        }
        magnitude_sum.* = total;
        workgroup_magnitudes[index / workgroup_size] += @abs(values[index]);
    }
    var outcome: ProbeOutcome = .{ .subgroup_gap = null, .workgroup_gap = 0, .repeats_exactly = true };
    const entry_names = [2][:0]const u8{ "subgroup_sum", "workgroup_sum" };
    const sum_counts = [2]u32{ value_count, workgroup_count };
    inline for (entry_names, sum_counts, 0..) |entry_name, sum_count, entry_index| {
        const is_subgroup_entry: bool = entry_index == 0;
        const runs_here: bool = !is_subgroup_entry or has_subgroup_sums;
        if (runs_here) {
            on_device.run(entry_name, value_count);
            twin.run(entry_name, value_count);
            const first_sums: []f32 = try gpa.alloc(f32, sum_count);
            defer gpa.free(first_sums);
            on_device.readRange(.sums, 0, first_sums);
            const twin_sums: []f32 = try gpa.alloc(f32, sum_count);
            defer gpa.free(twin_sums);
            twin.readRange(.sums, 0, twin_sums);
            const magnitude_sums: []const f32 = if (is_subgroup_entry) subgroup_magnitudes else workgroup_magnitudes;
            const gap: f32 = reductionGap(first_sums, twin_sums, magnitude_sums);
            if (is_subgroup_entry) {
                outcome.subgroup_gap = gap;
            } else {
                outcome.workgroup_gap = gap;
            }
            on_device.run(entry_name, value_count);
            const second_sums: []f32 = try gpa.alloc(f32, sum_count);
            defer gpa.free(second_sums);
            on_device.readRange(.sums, 0, second_sums);
            const first_bits: []const u32 = @ptrCast(first_sums);
            const second_bits: []const u32 = @ptrCast(second_sums);
            outcome.repeats_exactly = outcome.repeats_exactly and eql(u32, first_bits, second_bits);
        }
    }
    return outcome;
}

/// ONE RESULT OF A PROBE TABLE (`runProbeTable`): its name, where it sits in a row of results, how many floats it
/// spans, and its BAR - how far the device may stray from the twin, in units of f32's epsilon at the result's scale.
const ProbeResult = struct {
    name: []const u8,
    offset: u32,
    width: u32,
    bar_epsilons: f32,
};

/// The draws a probe table's inputs are made of, from a seeded generator so every run sees the same table.
const ProbeInputs = struct {
    /// One float in [low, high).
    fn uniform(random: Random, low: f32, high: f32) f32 {
        const unit: f32 = random.float(f32);
        return low + unit * (high - low);
    }

    /// A three-dimensional direction scaled to a length in [min_length, max_length): never near zero, as
    /// `normalize3` needs.
    fn awayFromZero(random: Random, min_length: f32, max_length: f32) [3]f32 {
        while (true) {
            const along_x: f32 = uniform(random, -1.0, 1.0);
            const along_y: f32 = uniform(random, -1.0, 1.0);
            const along_z: f32 = uniform(random, -1.0, 1.0);
            const direction_length: f32 = @sqrt(along_x * along_x + along_y * along_y + along_z * along_z);
            if (direction_length < 0.1 or direction_length > 1.0) {
                continue;
            }
            const wanted_length: f32 = uniform(random, min_length, max_length);
            const scale: f32 = wanted_length / direction_length;
            return .{ along_x * scale, along_y * scale, along_z * scale };
        }
    }

    /// A unit quaternion (x y z w): a random axis turned by a random angle in [-pi, pi].
    fn unitQuaternion(random: Random) [4]f32 {
        const axis: [3]f32 = awayFromZero(random, 1.0, 1.0);
        const half_angle: f32 = uniform(random, -pi, pi) * 0.5;
        const sine: f32 = @sin(half_angle);
        return .{ axis[0] * sine, axis[1] * sine, axis[2] * sine, @cos(half_angle) };
    }

    /// A three-dimensional value into `inputs` at `at`, its fourth lane `w`.
    fn putVector(inputs: []f32, at: u32, value: [3]f32, w: f32) void {
        inputs[at] = value[0];
        inputs[at + 1] = value[1];
        inputs[at + 2] = value[2];
        inputs[at + 3] = w;
    }
};

/// Each result's largest difference between `device_outputs` and `twin_outputs` over `row_count` rows of
/// `output_width` floats, in units of f32's epsilon at the result's scale (`max(1, |twin|)`: results near one in units
/// of epsilon itself, larger ones relative to their size), into `gaps` in `results`' order.
fn measureProbeResults(
    results: []const ProbeResult,
    row_count: u32,
    output_width: u32,
    device_outputs: []const f32,
    twin_outputs: []const f32,
    gaps: []f32,
) void {
    // f32's epsilon, 2^-23: the gap between 1 and the next float.
    const epsilon: f32 = 0x1p-23;
    for (results, gaps) |result, *gap| {
        var largest: f32 = 0;
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            const first: u32 = row * output_width + result.offset;
            for (first..first + result.width) |at| {
                const twin_value: f32 = twin_outputs[at];
                const scale: f32 = @max(1.0, @abs(twin_value));
                const difference: f32 = @abs(device_outputs[at] - twin_value);
                largest = @max(largest, difference / (epsilon * scale));
            }
        }
        gap.* = largest;
    }
}

/// Each result against its bar, printed under `label`; whether every one is within its bar.
fn reportProbeResults(
    label: []const u8,
    results: []const ProbeResult,
    gaps: []const f32,
) bool {
    var every_result_holds: bool = true;
    for (results, gaps) |result, gap| {
        const within: bool = gap <= result.bar_epsilons;
        every_result_holds = every_result_holds and within;
        const verdict: []const u8 = if (within) "" else "  OVER THE BAR";
        print("vk-host-test: {s}: {s} {d:.2} epsilons from the twin (bar {d}){s}\n", .{
            label,
            result.name,
            gap,
            result.bar_epsilons,
            verdict,
        });
    }
    return every_result_holds;
}

/// The probe module's buffer fields, by name.
const ProbeField = FieldEnum(robotgpu_probe.Buffers);

/// A PROBE TABLE: one entry of `robotgpu_probe` run once per row, its inputs and results in two fields of the module
/// - how many rows, how wide each, how the inputs are filled, the parameters that size the run, and the results to
/// compare with their bars.
const ProbeTable = struct {
    entry_name: [:0]const u8,
    inputs_field: ProbeField,
    outputs_field: ProbeField,
    row_count: u32,
    input_width: u32,
    output_width: u32,
    fill: *const fn ([]f32) void,
    params: robotgpu_probe.Params,
    results: []const ProbeResult,
};

/// One probe table on the device and on the twin from the same inputs, each result's largest gap into `gaps`
/// (`measureProbeResults`). Returns false when a readback never came.
fn runProbeTable(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    comptime table: ProbeTable,
    gaps: []f32,
) !bool {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    const input_count: u32 = table.row_count * table.input_width;
    const output_count: u32 = table.row_count * table.output_width;
    const inputs: []f32 = try gpa.alloc(f32, input_count);
    defer gpa.free(inputs);
    table.fill(inputs);
    const pipes = [2]*ProbeCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.element_count = @max(input_count, output_count);
        pipe.upload(table.inputs_field, inputs);
        pipe.params = table.params;
        pipe.run(table.entry_name, table.row_count);
    }
    const device_results: []f32 = try gpa.alloc(f32, output_count);
    defer gpa.free(device_results);
    on_device.readRange(table.outputs_field, 0, device_results);
    const twin_results: []f32 = try gpa.alloc(f32, output_count);
    defer gpa.free(twin_results);
    twin.readRange(table.outputs_field, 0, twin_results);
    measureProbeResults(table.results, table.row_count, table.output_width, device_results, twin_results, gaps);
    return true;
}

/// RANGES REQUESTED, THEN COLLECTED: on the device and on the CPU twin, four requests - two ranges of `values`, one
/// of `pushed_words` made BEFORE a kernel writes 77 into it, and one given up - then other work, then the collecting.
/// A request holds its range as it was when requested, so the words come back zero though the write has happened:
///
///     request values[100..600], values[30000..33000], pushed_words[0..1000], values[0..16]
///     run write_pushed (77 into pushed_words)          discard the last request
///     collect the first by polling, wait for the second and third    ->  the upload, the upload, zeros
///     readRange pushed_words now                                     ->  77s: the write did happen
fn runRangeRequests(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    const value_count: u32 = robotgpu_probe.table_capacity;
    const uploaded: []f32 = try gpa.alloc(f32, value_count);
    defer gpa.free(uploaded);
    for (uploaded, 0..) |*value, index| {
        value.* = float(index) * 0.25;
    }
    const word_count: u32 = 1000;
    const zero_words: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(zero_words);
    @memset(zero_words, 0);
    const early_values: []f32 = try gpa.alloc(f32, 500);
    defer gpa.free(early_values);
    const late_values: []f32 = try gpa.alloc(f32, 3000);
    defer gpa.free(late_values);
    const words_as_requested: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(words_as_requested);
    const words_now: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(words_now);
    const pipes = [2]*ProbeCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.upload(.values, uploaded);
        pipe.upload(.pushed_words, zero_words);
        pipe.params = .{ .value_count = 0, .subgroup_size = 1, .pushed_region_size = word_count };
        var early_request: ProbeCompute.RangeRequest(.values) = try pipe.requestRange(gpa, .values, 100, 500);
        var late_request: ProbeCompute.RangeRequest(.values) = try pipe.requestRange(gpa, .values, 30000, 3000);
        var words_request: ProbeCompute.RangeRequest(.pushed_words) =
            try pipe.requestRange(gpa, .pushed_words, 0, word_count);
        var dropped_request: ProbeCompute.RangeRequest(.values) = try pipe.requestRange(gpa, .values, 0, 16);
        const write: robotgpu_probe.PushConstants = .{ .region_start = 0, .value = 77 };
        pipe.runPushed("write_pushed", word_count, write);
        dropped_request.discard();
        while (!early_request.collect(early_values)) {
            std.atomic.spinLoopHint();
        }
        late_request.wait(late_values);
        words_request.wait(words_as_requested);
        pipe.readRange(.pushed_words, 0, words_now);
        const values_match: bool = eql(f32, early_values, uploaded[100..600]) and
            eql(f32, late_values, uploaded[30000..33000]);
        var words_as_they_were: bool = true;
        var words_written_since: bool = true;
        for (words_as_requested, words_now) |as_requested, now| {
            words_as_they_were = words_as_they_were and as_requested == 0;
            words_written_since = words_written_since and now == 77;
        }
        if (!(values_match and words_as_they_were and words_written_since)) {
            return false;
        }
    }
    return true;
}

/// What stepping the device and the twin side by side found (`runRobotgpuSteps`): the comparison of every array the
/// step writes, and each world's ENERGY - robot.zig's own `energy`, computed on the CPU from the device's state and
/// from the twin's. Over many steps the device's last-bit roundings carry the two trajectories apart, so their arrays
/// drift apart too; the energy is a physical quantity they should still agree on. WHAT DRIVES THE WORLDS over the
/// steps: `driven` - applied joint forces, controls and the model's dampers as well as gravity, every force path of the
/// step exercised; `conservative` - gravity alone, no applied force, no control, the dampers taken out, so each world's
/// energy can change only by the integrator's own error, the scale the device's energy is judged against.
const StepInputs = enum { driven, conservative };

const SteppedOutcome = struct {
    verdict: robotgpu_host.StepVerdict,
    /// The floor slots holding a contact on the twin after the steps, over every world - so a comparison of the
    /// floor's arrays is known to have compared contacts, not empty slots.
    floor_contacts: u32 = 0,
    /// The largest difference between a world's energy on the device and on the twin after the steps, relative to the
    /// energy the world began with.
    largest_energy_gap: f32,
    /// The largest change of a world's energy on the twin over the steps, relative to the energy it began with - with
    /// `conservative` inputs, the integrator's own error, the scale the device's gap is read against.
    largest_energy_drift: f32,
};

/// `count` numbers of `sim`'s `world_f` arena from `offset`, read back into `out` - waiting for the copy, as only a
/// test may.
fn readWorldFloats(
    gpa: Allocator,
    sim: *robotgpu_host.Sim,
    offset: u32,
    out: []f32,
) !void {
    const count: u32 = @intCast(out.len);
    var request: robotgpu_host.Pipe.RangeRequest(.world_f) = try sim.pipe.requestRange(gpa, .world_f, offset, count);
    while (!request.collect(out)) {
        std.atomic.spinLoopHint();
    }
}

/// `out.len` integers of `sim`'s `world_u` arena from `offset`, read back into `out` - waiting for the copy, as only
/// a test may.
fn readWorldIntegers(
    gpa: Allocator,
    sim: *robotgpu_host.Sim,
    offset: u32,
    out: []u32,
) !void {
    const count: u32 = @intCast(out.len);
    var request: robotgpu_host.Pipe.RangeRequest(.world_u) = try sim.pipe.requestRange(gpa, .world_u, offset, count);
    while (!request.collect(out)) {
        std.atomic.spinLoopHint();
    }
}

/// The coordinates and velocities of every world of `sim`, read back into `positions` and `velocities` (each a world's
/// block after another, as the arena holds them) - waiting for the copies, as only a test may.
fn readWorldArrays(
    gpa: Allocator,
    sim: *robotgpu_host.Sim,
    state: robotgpu.WorldStateLayout,
    positions: []f32,
    velocities: []f32,
) !void {
    try readWorldFloats(gpa, sim, state.joint_positions.offset, positions);
    try readWorldFloats(gpa, sim, state.joint_velocities.offset, velocities);
}

/// The energy of a world of `model` whose coordinates and velocities are `positions` and `velocities`: robot.zig's
/// `energy`, after its kinematics, centre-of-mass frame and composite inertias have been computed in `data`.
fn worldEnergy(
    model: *const z.robot.Model,
    data: *z.robot.Data,
    positions: []const f32,
    velocities: []const f32,
) f32 {
    @memcpy(data.joint_positions, positions);
    @memcpy(data.joint_velocities, velocities);
    z.robot.kinematics(model, data);
    z.robot.comPos(model, data);
    z.robot.crb(model, data);
    return z.robot.energy(model, data);
}

/// THE KERNELS NO MODEL OF THIS TEST HAS WORK FOR - a dispatch with no invocations is left out
/// (`Sim.runDispatches`) - each with what a model would need for it. Every other kernel must reach the device.
const kernels_without_work_here = [_][]const u8{
    // No model simulated here has a site.
    "site_poses",
    // No model simulated here has an actuator with an activation state.
    "next_activations",
};

/// Whether `kernel` is one no model of this test has work for (`kernels_without_work_here`).
fn hasNoWorkInTheTestModels(kernel: []const u8) bool {
    for (kernels_without_work_here) |workless| {
        if (eql(u8, kernel, workless)) {
            return true;
        }
    }
    return false;
}

/// WHICH OF ROBOTGPU's KERNELS THIS RUN DISPATCHED ON THE DEVICE: every GPU simulator's dispatch counts
/// (`Compute.dispatch_counts`) added up as the simulator is freed, so the run can name every kernel it never sent to a
/// GPU - a check on the CPU twin alone proves nothing about the device.
const DeviceCoverage = struct {
    dispatches: [robotgpu.kernels.len]u64 = @splat(0),

    /// One simulator's dispatches added to the run's.
    fn add(coverage: *DeviceCoverage, sim: *const robotgpu_host.Sim) void {
        for (&coverage.dispatches, sim.pipe.dispatch_counts) |*total, count| {
            total.* += count;
        }
    }
};

/// THE CONSTRAINT PROGRAM ON THE DEVICE AGAINST THE TWIN: MuJoCo's humanoid - its hinges with ranges, a 0.05 margin
/// on each - in 64 worlds posed around their limits and moving, the step program up to the free acceleration, then
/// the constraint program (the rows, their projection, Newton) on both. Every world's rows - how many, which joint's
/// end, the Jacobian's dofs - and Newton's rounds must be the same; every quantity's gap is measured against its bar.
fn runRobotgpuConstraints(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    inertia: z.robot.ConstraintInertia,
) !robotgpu_host.ConstraintVerdict {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var humanoid: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_humanoid_model, .{});
    defer humanoid.deinit();
    // Its rows are its joint limits' and its floor's contacts': the step makes them, projects them and solves them.
    // Which inertia the rows' softness reads: the exact one solves J M^-1 J^T on the device, MuJoCo's default takes
    // each row's from the reference pose and solves nothing.
    humanoid.model.opt.constraint_inertia = inertia;
    for (humanoid.model.joint_range, humanoid.model.joint_limit_margin) |range, *margin| {
        if (range != null) {
            margin.* = 0.05;
        }
    }
    const model: *const z.robot.Model = &humanoid.model;
    const world_count: u32 = 64;
    var on_device: robotgpu_host.Sim = try .initGpu(gpa, device, queue, &entries, model, world_count);
    defer on_device.deinit();
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwin(gpa, model, world_count);
    defer twin.deinit();
    const coordinates: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(coordinates);
    const rates: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(rates);
    // A floor 2 cm above the lowest point of the first world's pose: its lowest geoms in it, and the other worlds,
    // posed apart, some deeper and some clear.
    robotgpu_host.poseAroundLimits(model, 0, coordinates, rates);
    const ground: z.robot.Floor = try robotgpu_host.floorUnderLowestPoint(gpa, model, coordinates, 0.02);
    const sims = [2]*robotgpu_host.Sim{ &on_device, &twin };
    for (sims) |sim| {
        try sim.setFloor(ground);
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            robotgpu_host.poseAroundLimits(model, world, coordinates, rates);
            sim.uploadWorldPositions(world, coordinates);
            sim.uploadWorldArray("joint_velocities", world, rates);
        }
        sim.submitStep();
    }
    var comparison: robotgpu_host.ConstraintComparison = try .request(gpa, &on_device, &twin);
    defer comparison.deinit(gpa);
    // Counted now, from the twin's arrays, before the next check's twin shares them.
    const contact_rows: u32 = robotgpu_host.countRowsOfKind(&twin, .contact);
    print("vk-host-test: robotgpu constraints at {s} - {d} of the rows the floor's contacts'\n", .{
        @tagName(inertia),
        contact_rows,
    });
    while (!comparison.collect()) {
        std.atomic.spinLoopHint();
    }
    return comparison.verdict;
}

/// What the steps on the floor found: the largest gap between a world's energy on the device and on the twin, relative
/// to the energy it began with; the deepest any geom ended in the floor, on each; whether every number stayed finite;
/// and the twin's rows of the floor's contacts after the first step.
const FloorStepsOutcome = struct {
    largest_energy_gap: f32 = 0,
    deepest_device_penetration: f32 = 0,
    deepest_twin_penetration: f32 = 0,
    all_finite: bool = true,
    first_step_contact_rows: u32 = 0,
};

/// How deep the deepest geom of `model` posed at `positions` lies in `ground` - robot.zig's floor contacts' smallest
/// distance, negated; zero when no geom is in it.
fn deepestPenetration(
    model: *const z.robot.Model,
    data: *z.robot.Data,
    positions: []const f32,
    ground: z.robot.Floor,
) !f32 {
    @memcpy(data.joint_positions, positions);
    z.robot.kinematics(model, data);
    data.clearContacts();
    try z.robot.pushFloorContacts(model, data, ground);
    var deepest: f32 = 0;
    for (data.contacts[0..data.contact_count]) |contact| {
        deepest = @max(deepest, -contact.distance);
    }
    return deepest;
}

/// Whether every number of `numbers` is finite.
fn allFinite(numbers: []const f32) bool {
    for (numbers) |number| {
        if (!zm.isFinite(number)) {
            return false;
        }
    }
    return true;
}

/// THE STEP ON THE FLOOR, MANY TIMES, DEVICE AGAINST TWIN: Geno with his training physics
/// (`robot_geno.physicsOptions`: 60 Hz, Newton at 3 rounds and 5 line-search iterations, the reference pose's
/// inertia, the warm start) in 64 worlds - the even ones standing in his reference pose, the odd ones lying, turned a
/// quarter about x and lowered so their lowest point lies as deep - on one floor 5 mm into the standing pose's lowest
/// point, with no servo: the standing ones fall, the lying ones settle. Stepped `step_count` times on both.
/// Trajectories drift apart in rounding, so what is compared must hold whatever the drift: each world's energy, how
/// deep any geom ends in the floor, and every number finite.
fn runRobotgpuFloorSteps(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    world_count: u32,
    step_count: u32,
) !FloorStepsOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *const z.robot.Model = &geno.model;
    // The two poses. Standing: the reference. Lying: the free root's orientation (coordinates 3 to 6, x y z w) turned
    // a quarter about x, then its height (coordinate 2) moved so its lowest point lies where the standing pose's does.
    const standing: []f32 = try gpa.dupe(f32, model.reference_joint_positions);
    defer gpa.free(standing);
    const lying: []f32 = try gpa.dupe(f32, model.reference_joint_positions);
    defer gpa.free(lying);
    const half_turn_sine: f32 = @sqrt(0.5);
    lying[3] = half_turn_sine;
    lying[4] = 0;
    lying[5] = 0;
    lying[6] = half_turn_sine;
    const depth: f32 = 0.005;
    const ground: z.robot.Floor = try robotgpu_host.floorUnderLowestPoint(gpa, model, standing, depth);
    const standing_lowest: f32 = ground.plane.point[2] - depth;
    const lying_probe: z.robot.Floor = try robotgpu_host.floorUnderLowestPoint(gpa, model, lying, 0);
    const lying_lowest: f32 = lying_probe.plane.point[2];
    lying[2] += standing_lowest - lying_lowest;
    var on_device: robotgpu_host.Sim = try .initGpu(gpa, device, queue, &entries, model, world_count);
    defer on_device.deinit();
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwin(gpa, model, world_count);
    defer twin.deinit();
    const sims = [2]*robotgpu_host.Sim{ &on_device, &twin };
    for (sims) |sim| {
        try sim.setFloor(ground);
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            const pose: []const f32 = if (world % 2 == 0) standing else lying;
            sim.uploadWorldPositions(world, pose);
        }
    }
    var data: z.robot.Data = try .init(gpa, model);
    defer data.deinit();
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    const positions_stride: u32 = state.joint_positions.stride;
    const velocities_stride: u32 = state.joint_velocities.stride;
    const twin_positions: []f32 = try gpa.alloc(f32, positions_stride * world_count);
    defer gpa.free(twin_positions);
    const twin_velocities: []f32 = try gpa.alloc(f32, velocities_stride * world_count);
    defer gpa.free(twin_velocities);
    const device_positions: []f32 = try gpa.alloc(f32, positions_stride * world_count);
    defer gpa.free(device_positions);
    const device_velocities: []f32 = try gpa.alloc(f32, velocities_stride * world_count);
    defer gpa.free(device_velocities);
    const energies_before: []f32 = try gpa.alloc(f32, world_count);
    defer gpa.free(energies_before);
    try readWorldArrays(gpa, &twin, state, twin_positions, twin_velocities);
    var world_before: u32 = 0;
    while (world_before < world_count) : (world_before += 1) {
        const positions: []const f32 = twin_positions[world_before * positions_stride ..][0..model.coordinate_count];
        const velocities: []const f32 = twin_velocities[world_before * velocities_stride ..][0..model.dof_count];
        energies_before[world_before] = worldEnergy(model, &data, positions, velocities);
    }
    var outcome: FloorStepsOutcome = .{};
    var step: u32 = 0;
    while (step < step_count) : (step += 1) {
        on_device.submitStep();
        twin.submitStep();
        if (step == 0) {
            outcome.first_step_contact_rows = robotgpu_host.countRowsOfKind(&twin, .contact);
        }
    }
    try readWorldArrays(gpa, &on_device, state, device_positions, device_velocities);
    try readWorldArrays(gpa, &twin, state, twin_positions, twin_velocities);
    outcome.all_finite = allFinite(device_positions) and allFinite(device_velocities) and
        allFinite(twin_positions) and allFinite(twin_velocities);
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        const twin_world_positions: []const f32 =
            twin_positions[world * positions_stride ..][0..model.coordinate_count];
        const device_world_positions: []const f32 =
            device_positions[world * positions_stride ..][0..model.coordinate_count];
        const twin_world_velocities: []const f32 = twin_velocities[world * velocities_stride ..][0..model.dof_count];
        const device_world_velocities: []const f32 =
            device_velocities[world * velocities_stride ..][0..model.dof_count];
        const twin_energy: f32 = worldEnergy(model, &data, twin_world_positions, twin_world_velocities);
        const device_energy: f32 = worldEnergy(model, &data, device_world_positions, device_world_velocities);
        const scale: f32 = @max(@abs(energies_before[world]), 1.0e-6);
        outcome.largest_energy_gap = @max(outcome.largest_energy_gap, @abs(device_energy - twin_energy) / scale);
        const device_depth: f32 = try deepestPenetration(model, &data, device_world_positions, ground);
        const twin_depth: f32 = try deepestPenetration(model, &data, twin_world_positions, ground);
        outcome.deepest_device_penetration = @max(outcome.deepest_device_penetration, device_depth);
        outcome.deepest_twin_penetration = @max(outcome.deepest_twin_penetration, twin_depth);
    }
    return outcome;
}

/// What the constrained steps found: the largest gap between a world's energy on the device and on the twin after the
/// steps, relative to the energy it began with; and how far past its range any limited joint ended up, on each.
const LimitStepsOutcome = struct {
    largest_energy_gap: f32 = 0,
    deepest_device_violation: f32 = 0,
    deepest_twin_violation: f32 = 0,
};

/// How far past its range world `positions`' deepest limited joint is - zero when every joint is inside.
fn deepestLimitViolation(model: *const z.robot.Model, positions: []const f32) f32 {
    var deepest: f32 = 0;
    for (model.joint_range, model.joint_first_coordinate) |range_or_none, first_coordinate| {
        const range: [2]f32 = range_or_none orelse continue;
        const position: f32 = positions[first_coordinate];
        const below: f32 = range[0] - position;
        const above: f32 = position - range[1];
        deepest = @max(deepest, @max(below, above));
    }
    return deepest;
}

/// THE CONSTRAINED STEP, MANY TIMES, DEVICE AGAINST TWIN: MuJoCo's humanoid in 64 worlds posed around its joint limits
/// and moving (`robotgpu_host.poseAroundLimits`), its contacts off and its rows at the reference pose's inertia (Geno's
/// training setting), stepped `step_count` times on both. Trajectories that start alike drift apart in rounding, so
/// what is compared is what must hold whatever the drift: each world's energy - which only the limits' and the joints'
/// dissipation changes - and how far past its range any joint ended, on each.
fn runRobotgpuLimitSteps(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    step_count: u32,
) !LimitStepsOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var humanoid: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_humanoid_model, .{});
    defer humanoid.deinit();
    humanoid.model.opt.constraint_inertia = .reference_pose;
    for (humanoid.model.joint_range, humanoid.model.joint_limit_margin) |range, *margin| {
        if (range != null) {
            margin.* = 0.05;
        }
    }
    const model: *const z.robot.Model = &humanoid.model;
    const world_count: u32 = 64;
    var on_device: robotgpu_host.Sim = try .initGpu(gpa, device, queue, &entries, model, world_count);
    defer on_device.deinit();
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwin(gpa, model, world_count);
    defer twin.deinit();
    const coordinates: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(coordinates);
    const rates: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(rates);
    const sims = [2]*robotgpu_host.Sim{ &on_device, &twin };
    for (sims) |sim| {
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            robotgpu_host.poseAroundLimits(model, world, coordinates, rates);
            sim.uploadWorldPositions(world, coordinates);
            sim.uploadWorldArray("joint_velocities", world, rates);
        }
    }
    var data: z.robot.Data = try .init(gpa, model);
    defer data.deinit();
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    const positions_stride: u32 = state.joint_positions.stride;
    const velocities_stride: u32 = state.joint_velocities.stride;
    const twin_positions: []f32 = try gpa.alloc(f32, positions_stride * world_count);
    defer gpa.free(twin_positions);
    const twin_velocities: []f32 = try gpa.alloc(f32, velocities_stride * world_count);
    defer gpa.free(twin_velocities);
    const device_positions: []f32 = try gpa.alloc(f32, positions_stride * world_count);
    defer gpa.free(device_positions);
    const device_velocities: []f32 = try gpa.alloc(f32, velocities_stride * world_count);
    defer gpa.free(device_velocities);
    const energies_before: []f32 = try gpa.alloc(f32, world_count);
    defer gpa.free(energies_before);
    try readWorldArrays(gpa, &twin, state, twin_positions, twin_velocities);
    var world_before: u32 = 0;
    while (world_before < world_count) : (world_before += 1) {
        const positions: []const f32 = twin_positions[world_before * positions_stride ..][0..model.coordinate_count];
        const velocities: []const f32 = twin_velocities[world_before * velocities_stride ..][0..model.dof_count];
        energies_before[world_before] = worldEnergy(model, &data, positions, velocities);
    }
    var step: u32 = 0;
    while (step < step_count) : (step += 1) {
        on_device.submitStep();
        twin.submitStep();
    }
    try readWorldArrays(gpa, &on_device, state, device_positions, device_velocities);
    try readWorldArrays(gpa, &twin, state, twin_positions, twin_velocities);
    var outcome: LimitStepsOutcome = .{};
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        const twin_world_positions: []const f32 =
            twin_positions[world * positions_stride ..][0..model.coordinate_count];
        const device_world_positions: []const f32 =
            device_positions[world * positions_stride ..][0..model.coordinate_count];
        const twin_world_velocities: []const f32 = twin_velocities[world * velocities_stride ..][0..model.dof_count];
        const device_world_velocities: []const f32 =
            device_velocities[world * velocities_stride ..][0..model.dof_count];
        const twin_energy: f32 = worldEnergy(model, &data, twin_world_positions, twin_world_velocities);
        const device_energy: f32 = worldEnergy(model, &data, device_world_positions, device_world_velocities);
        const scale: f32 = @max(@abs(energies_before[world]), 1.0e-6);
        outcome.largest_energy_gap = @max(outcome.largest_energy_gap, @abs(device_energy - twin_energy) / scale);
        const device_violation: f32 = deepestLimitViolation(model, device_world_positions);
        const twin_violation: f32 = deepestLimitViolation(model, twin_world_positions);
        outcome.deepest_device_violation = @max(outcome.deepest_device_violation, device_violation);
        outcome.deepest_twin_violation = @max(outcome.deepest_twin_violation, twin_violation);
    }
    return outcome;
}

fn runRobotgpuSteps(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    step_count: u32,
    inputs: StepInputs,
) !SteppedOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, .{});
    defer geno.deinit();
    // Stepped without its constraints: this check measures the smooth step and the integrator against the twin, and
    // the floor it is given is for its contacts' slots alone - with the constraints disabled, no row is made.
    geno.model.opt.disable_constraints = true;
    // With conservative inputs the dampers are taken out, on a copy of the model.
    const no_damping: []f32 = try gpa.alloc(f32, geno.model.joint_count);
    defer gpa.free(no_damping);
    @memset(no_damping, 0);
    var stepped_model: z.robot.Model = geno.model;
    if (inputs == .conservative) {
        stepped_model.joint_damping = no_damping;
        stepped_model.has_dof_damping = false;
    }
    const model: *const z.robot.Model = &stepped_model;
    const world_count: u32 = 64;
    var on_device: robotgpu_host.Sim = try .initGpu(gpa, device, queue, &entries, model, world_count);
    defer on_device.deinit();
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwin(gpa, model, world_count);
    defer twin.deinit();
    // A floor at the middle world's root height. The inputs below raise each world's root 0.15 m above the last's
    // (its z, the free root's third coordinate, `reference + 0.05 x 3 x (world + 1)`), so the worlds below the middle
    // are deep in the floor, every geom touching; the middle world's legs reach under it; the worlds above make no
    // contact - filled slots and empty ones, compared with the twin's among the step's arrays (`step_array_bars`).
    // The floor makes no row yet, so the dynamics are as before.
    const middle_world: f32 = @floatFromInt(world_count / 2 + 1);
    const floor_height: f32 = model.reference_joint_positions[2] + 0.05 * 3.0 * middle_world;
    const ground: z.robot.Floor = .{ .plane = .{ .point = .{ 0, 0, floor_height, 0 }, .normal = .{ 0, 0, 1, 0 } } };
    try on_device.setFloor(ground);
    try twin.setFloor(ground);
    const coordinates: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(coordinates);
    const forces: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(forces);
    const rates: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(rates);
    const controls: []f32 = try gpa.alloc(f32, model.actuator_count);
    defer gpa.free(controls);
    const sims = [2]*robotgpu_host.Sim{ &on_device, &twin };
    for (sims) |sim| {
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            for (coordinates, 0..) |*coordinate, index| {
                const coordinate_index: u32 = @intCast(index);
                const world_factor: f32 = @floatFromInt(world + 1);
                const coordinate_factor: f32 = @floatFromInt(coordinate_index % 7 + 1);
                coordinate.* = model.reference_joint_positions[index] + 0.05 * coordinate_factor * world_factor;
            }
            sim.uploadWorldPositions(world, coordinates);
            for (forces, 0..) |*force, index| {
                const dof_factor: f32 = @floatFromInt(index % 5 + 1);
                const world_factor: f32 = @floatFromInt(world + 1);
                force.* = switch (inputs) {
                    .driven => 0.05 * dof_factor * world_factor,
                    .conservative => 0,
                };
            }
            sim.uploadWorldArray("applied_joint_forces", world, forces);
            for (rates, 0..) |*rate, index| {
                const dof_factor: f32 = @floatFromInt(index % 7 + 1);
                const world_factor: f32 = @floatFromInt(world % 4 + 1);
                rate.* = 0.05 * dof_factor * world_factor;
            }
            sim.uploadWorldArray("joint_velocities", world, rates);
            for (controls, 0..) |*control, index| {
                const world_factor: f32 = @floatFromInt(world % 5 + 1);
                const actuator_factor: f32 = @floatFromInt(@as(i32, @intCast(index % 7)) - 3);
                control.* = switch (inputs) {
                    .driven => 0.05 * actuator_factor * world_factor,
                    .conservative => 0,
                };
            }
            sim.uploadWorldArray("controls", world, controls);
        }
    }
    // Each world's energy before the steps, from the state both were given.
    var data: z.robot.Data = try .init(gpa, model);
    defer data.deinit();
    const energies_before: []f32 = try gpa.alloc(f32, world_count);
    defer gpa.free(energies_before);
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    const positions_stride: u32 = state.joint_positions.stride;
    const velocities_stride: u32 = state.joint_velocities.stride;
    const twin_positions: []f32 = try gpa.alloc(f32, positions_stride * world_count);
    defer gpa.free(twin_positions);
    const twin_velocities: []f32 = try gpa.alloc(f32, velocities_stride * world_count);
    defer gpa.free(twin_velocities);
    const device_positions: []f32 = try gpa.alloc(f32, positions_stride * world_count);
    defer gpa.free(device_positions);
    const device_velocities: []f32 = try gpa.alloc(f32, velocities_stride * world_count);
    defer gpa.free(device_velocities);
    try readWorldArrays(gpa, &twin, state, twin_positions, twin_velocities);
    var world_before: u32 = 0;
    while (world_before < world_count) : (world_before += 1) {
        const positions: []const f32 = twin_positions[world_before * positions_stride ..][0..model.coordinate_count];
        const velocities: []const f32 = twin_velocities[world_before * velocities_stride ..][0..model.dof_count];
        energies_before[world_before] = worldEnergy(model, &data, positions, velocities);
    }
    var step: u32 = 0;
    while (step < step_count) : (step += 1) {
        on_device.submitStep();
        twin.submitStep();
    }
    var comparison: robotgpu_host.StepComparison = try .request(gpa, &on_device, &twin);
    defer comparison.deinit(gpa);
    while (!comparison.collect()) {
        std.atomic.spinLoopHint();
    }
    // Each world's energy after the steps, on the device and on the twin.
    try readWorldArrays(gpa, &on_device, state, device_positions, device_velocities);
    try readWorldArrays(gpa, &twin, state, twin_positions, twin_velocities);
    var outcome: SteppedOutcome = .{
        .verdict = comparison.verdict,
        .largest_energy_gap = 0,
        .largest_energy_drift = 0,
    };
    // The twin's filled floor slots, read from its own arrays - the twin's arenas are this process's memory.
    const filled: robotgpu.WorldArray(.world_u, .floor_slots) = twin.layout.world_u.floor_slot_filled;
    var counted_world: u32 = 0;
    while (counted_world < world_count) : (counted_world += 1) {
        var slot: u32 = 0;
        while (slot < twin.counts.floor_slot_count) : (slot += 1) {
            outcome.floor_contacts += filled.load(counted_world, slot);
        }
    }
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        const positions_start: u32 = world * positions_stride;
        const velocities_start: u32 = world * velocities_stride;
        const twin_energy: f32 = worldEnergy(
            model,
            &data,
            twin_positions[positions_start..][0..model.coordinate_count],
            twin_velocities[velocities_start..][0..model.dof_count],
        );
        const device_energy: f32 = worldEnergy(
            model,
            &data,
            device_positions[positions_start..][0..model.coordinate_count],
            device_velocities[velocities_start..][0..model.dof_count],
        );
        const energy_scale: f32 = @max(@abs(energies_before[world]), 1e-6);
        const gap: f32 = @abs(device_energy - twin_energy) / energy_scale;
        const drift: f32 = @abs(twin_energy - energies_before[world]) / energy_scale;
        outcome.largest_energy_gap = @max(outcome.largest_energy_gap, gap);
        outcome.largest_energy_drift = @max(outcome.largest_energy_drift, drift);
    }
    return outcome;
}

/// What a decision on the device left, against the twin's: every step array (`StepComparison`), and the decision's own
/// two - each world's applied action (the filter's) and its servo's targets (the clip's pose with the action on it) -
/// in epsilons, each world's block at its own scale.
const DecisionOutcome = struct {
    verdict: robotgpu_host.StepVerdict,
    applied_actions_gap_epsilons: f32,
    servo_targets_gap_epsilons: f32,
};

/// The largest gap of a world array between the device and the twin, in epsilons, each world's block at its own scale
/// (`largestGapEpsilons`).
fn worldArrayGap(
    gpa: Allocator,
    on_device: *robotgpu_host.Sim,
    twin: *robotgpu_host.Sim,
    offset: u32,
    stride: u32,
    world_count: u32,
) !f32 {
    const device_numbers: []f32 = try gpa.alloc(f32, stride * world_count);
    defer gpa.free(device_numbers);
    const twin_numbers: []f32 = try gpa.alloc(f32, stride * world_count);
    defer gpa.free(twin_numbers);
    try readWorldFloats(gpa, on_device, offset, device_numbers);
    try readWorldFloats(gpa, twin, offset, twin_numbers);
    return robotgpu_host.largestGapEpsilons(device_numbers, twin_numbers, stride);
}

/// One step array's gap in a verdict, and its bar (`step_array_bars`).
const StepArrayGap = struct {
    gap_epsilons: f32,
    bar_epsilons: f32,
};

/// Array `name`'s gap in `verdict`, with its bar.
fn stepArrayGap(verdict: robotgpu_host.StepVerdict, comptime name: []const u8) StepArrayGap {
    inline for (robotgpu_host.step_array_bars, 0..) |array_bar, index| {
        if (comptime eql(u8, array_bar.name, name)) {
            const found: StepArrayGap = .{
                .gap_epsilons = verdict.gaps_epsilons[index],
                .bar_epsilons = array_bar.bar_epsilons,
            };
            return found;
        }
    }
    @compileError("stepArrayGap: no step array named " ++ name);
}

/// THE DECISION, DEVICE AGAINST TWIN: Geno at his training physics, 64 worlds tracking one clip on both - his
/// reference pose carried a little further each frame - each world at its own frame with its own action, on the floor,
/// its servo driven by `reference_targets` through the filter at 0.5. One decision of two physics steps
/// submitted to each (`Sim.submitDecision`), then every step array compared (`StepComparison`), and the decision's own
/// two arrays read back from both.
fn runRobotgpuDecision(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
) !DecisionOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *const z.robot.Model = &geno.model;
    const coordinate_count: usize = model.coordinate_count;
    // The clip: the reference pose carried along a fixed velocity a little further each frame - every frame a valid
    // pose, standing on the floor.
    const frame_count: u32 = 20;
    const poses: []f32 = try gpa.alloc(f32, frame_count * coordinate_count);
    defer gpa.free(poses);
    const carried: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(carried);
    for (carried, 0..) |*rate, dof| {
        const dof_factor: f32 = @floatFromInt(@as(i32, @intCast(dof % 7)) - 3);
        rate.* = if (dof < z.robot.rootDofCount(model)) 0 else 0.2 * dof_factor;
    }
    for (0..frame_count) |frame| {
        const pose: []f32 = poses[frame * coordinate_count ..][0..coordinate_count];
        @memcpy(pose, model.reference_joint_positions);
        const elapsed: f32 = 0.05 * float(frame);
        z.robot.integratePos(model, pose, carried, elapsed);
    }
    const clips = [_]robotgpu.ClipPoses{.{ .poses = poses, .frame_count = frame_count, .frame_time = 0.05 }};
    const world_count: u32 = 64;
    var on_device: robotgpu_host.Sim = try .initGpuTracking(gpa, device, queue, &entries, model, world_count, &clips);
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, &clips);
    defer twin.deinit();
    const ground: z.robot.Floor = .{ .friction = 1.0 };
    const law: z.robot.ServoLaw = .{ .frequency = 20.0, .damping = 1.0, .max_acceleration = 3000.0 };
    const action_count: usize = z.robot.actionSize(model);
    const actions: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(actions);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    const sims = [2]*robotgpu_host.Sim{ &on_device, &twin };
    for (sims) |sim| {
        try sim.setFloor(ground);
        sim.setServo(law, .toward_rest);
        sim.setActionScale(0.2);
        sim.setActionFilter(0.5, 0.5);
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            const frame: u32 = world % (frame_count - 1);
            sim.uploadWorldPositions(world, poses[frame * coordinate_count ..][0..coordinate_count]);
            sim.uploadWorldArray("joint_velocities", world, still);
            sim.setWorldClip(world, 0, frame);
            for (actions, 0..) |*action, number| {
                // In [-1, 1], different in every world and number.
                const phase: f32 = 0.7 * float(number + 1) + float(world);
                action.* = @sin(phase);
            }
            sim.uploadWorldArray("actions", world, actions);
        }
    }
    const physics_steps: u32 = 2;
    on_device.submitDecision(physics_steps);
    twin.submitDecision(physics_steps);
    var comparison: robotgpu_host.StepComparison = try .request(gpa, &on_device, &twin);
    defer comparison.deinit(gpa);
    while (!comparison.collect()) {
        std.atomic.spinLoopHint();
    }
    const state: robotgpu.WorldStateLayout = twin.layout.world_f;
    const applied_offset: u32 = state.applied_actions.offset;
    const applied_stride: u32 = state.applied_actions.stride;
    const targets_offset: u32 = state.servo_targets.offset;
    const targets_stride: u32 = state.servo_targets.stride;
    const applied_gap: f32 = try worldArrayGap(gpa, &on_device, &twin, applied_offset, applied_stride, world_count);
    const targets_gap: f32 = try worldArrayGap(gpa, &on_device, &twin, targets_offset, targets_stride, world_count);
    const outcome: DecisionOutcome = .{
        .verdict = comparison.verdict,
        .applied_actions_gap_epsilons = applied_gap,
        .servo_targets_gap_epsilons = targets_gap,
    };
    return outcome;
}

/// One float array of the tracking task, and how far the device's may be from the twin's: its bar, in epsilons of
/// the largest number of each world's block (`robotgpu_host.largestGapEpsilons`).
const TrackedFloatArray = struct {
    name: [:0]const u8,
    bar_epsilons: f32,
};

/// THE TRACKING TASK's FLOAT ARRAYS A WHOLE DECISION LEAVES: what each world carries to its next decision - its pose
/// and velocities, its warm start, its actions as chosen, given, applied and previous, its episode's sums - and the
/// decision's results - the servo's last targets, each body's lowest point, the observation, the tracking terms, the
/// rewards and the effort. EACH BAR is several times the gaps measured (in brackets: the largest of its kind over
/// the check's three decisions, on lavapipe and then on an RTX 5070), as the step's bars are: every GPU rounds its
/// own way - fused multiply-adds, its own sine, cosine and logarithm - and the two measured so far differ by little.
const tracking_float_arrays = [_]TrackedFloatArray{
    // Poses, targets and heights [8.2, 7.4]: the positions' kind, as the step's.
    .{ .name = "joint_positions", .bar_epsilons = 256 },
    .{ .name = "servo_targets", .bar_epsilons = 256 },
    .{ .name = "body_lowest_points", .bar_epsilons = 256 },
    // Velocities after two contact steps, a push's direction and a start's noise - each drawn through a cosine or a
    // logarithm - and the observation that reads them [350, 367].
    .{ .name = "joint_velocities", .bar_epsilons = 4096 },
    .{ .name = "observations", .bar_epsilons = 4096 },
    // Newton's accelerations, kept as the next step's start: the solve's own conditioning [1,849, 1,895].
    .{ .name = "warmstart_accelerations", .bar_epsilons = 16384 },
    // The actions: numbers the kernels copy or blend from what was uploaded [0, 0.5].
    .{ .name = "chosen_actions", .bar_epsilons = 4 },
    .{ .name = "actions", .bar_epsilons = 4 },
    .{ .name = "applied_actions", .bar_epsilons = 4 },
    .{ .name = "previous_actions", .bar_epsilons = 4 },
    // The judgement's measures and the episode's sums [37, 28].
    .{ .name = "tracking_errors", .bar_epsilons = 1024 },
    .{ .name = "super_mimic_tracking", .bar_epsilons = 1024 },
    .{ .name = "termination_rule", .bar_epsilons = 1024 },
    .{ .name = "rewards", .bar_epsilons = 1024 },
    .{ .name = "super_mimic_rewards", .bar_epsilons = 1024 },
    .{ .name = "episode_discounted_returns", .bar_epsilons = 1024 },
    .{ .name = "episode_discount_powers", .bar_epsilons = 1024 },
    .{ .name = "episode_reward_sums", .bar_epsilons = 1024 },
    // The effort's sums over the decision's physics steps: torques times velocities [155, 177].
    .{ .name = "effort_energy", .bar_epsilons = 4096 },
    .{ .name = "effort_torque_squares", .bar_epsilons = 4096 },
};

/// THE TRACKING TASK's INTEGER ARRAYS A WHOLE DECISION LEAVES: each world's clip and frame, its episode's number,
/// counters and flags, its start's bin. The device's must be the twin's EXACTLY: an integer that differs is a kernel
/// translated wrong or a draw made at another number - never rounding.
const tracking_integer_arrays = [_][:0]const u8{
    "world_clip",
    "world_frame",
    "episode_numbers",
    "episode_steps",
    "episode_decisions",
    "episode_flags",
    "aftermath_steps_left",
    "return_streaks",
    "steps_since_loss",
    "start_bins",
    "return_lengths",
};

/// What the tracking check measured, over its compared decisions.
const TrackingOutcome = struct {
    /// Each float array's largest gap between the device and the twin, in epsilons (`tracking_float_arrays`' order).
    float_gaps_epsilons: [tracking_float_arrays.len]f32,
    /// How many of each integer array's numbers differed (`tracking_integer_arrays`' order).
    integer_differences: [tracking_integer_arrays.len]u32,
    /// What happened on the twin, so the worlds compared were worlds in these situations: episodes that ended and
    /// began again, aftermaths begun, returns, and worlds pushed during their episode.
    episodes_restarted: u32,
    aftermaths_begun: u32,
    returns: u32,
    worlds_pushed: u32,
    /// THE DEVICE ALONE, AFTER THE COMPARISON: how many more whole decisions it ran back to back, and the wall
    /// seconds they took - with the size they ran at, so the cost of a decision can be read by its worlds.
    timed_decisions: u32,
    timed_seconds: f64,
    /// How many dispatches the timed decisions sent to the device, every kernel's together.
    timed_dispatches: u64,
    reads_flags_every_decision: bool,
    /// What every world holds, all worlds together: its state's floats, its integers, its constraint rows' floats -
    /// what an arena must hold for this many worlds.
    state_floats: u32,
    state_integers: u32,
    constraint_floats: u32,
    world_count: u32,
    physics_steps: u32,
};

/// HOW LARGE A TRACKING CHECK RUNS: its worlds (eight at least: the check's two knocked characters are among them),
/// and how many more decisions the device then runs alone, timed.
const TrackingSize = struct {
    world_count: u32,
    timed_decisions: u32,
    /// Decisions the device runs before the clock starts, so the timed ones find worlds in the middle of their
    /// episodes - on the floor, in contact - at every size alike.
    warmup_decisions: u32 = 0,
    /// Whether the worlds are first compared with the twin's over the check's three decisions. Not at the largest
    /// sizes: the twin's own steps there would take longer than everything else, and its verdict is the small sizes'.
    compares_with_the_twin: bool = true,
    /// Whether the host reads every world's flags after each timed decision, as a trainer's round does, or only once
    /// after the last: the difference is what waiting for the GPU at every decision costs.
    reads_flags_every_decision: bool = true,
    /// Whether one more decision is then run with the GPU's timestamps on, and its kernels' times printed
    /// (`reportKernelTimes`): where a decision's time goes at this many worlds.
    profiles_kernels: bool = false,
};

/// THE CHECK's ACTIONS FOR ONE DECISION, INTO THE TWIN: for every world the joints' offsets, then a stiffness per limb
/// - different in every world, number and decision. `actions` is one world's row, used as scratch.
fn uploadTrackingActions(
    twin: *robotgpu_host.Sim,
    world_count: u32,
    decision: u32,
    actions: []f32,
) void {
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        for (actions, 0..) |*action, number| {
            const phase: f32 = 0.7 * float(number + 1) + float(world) + 0.3 * float(decision);
            action.* = 0.5 * @sin(phase);
        }
        twin.uploadWorldArray("actions", world, actions);
    }
}

/// THE DEVICE GIVEN THE TWIN's WORLDS, WHOLE: both world arenas read from the twin and uploaded to the device, so the
/// two hold one state - every array, numbers and integers. `twin_floats` and `twin_integers` are the arenas' lengths
/// (`Sim.worldArenaEnd`), and hold the twin's state afterwards.
fn giveDeviceTheTwinsWorlds(
    gpa: Allocator,
    twin: *robotgpu_host.Sim,
    on_device: *robotgpu_host.Sim,
    twin_floats: []f32,
    twin_integers: []u32,
) !void {
    try readWorldFloats(gpa, twin, 0, twin_floats);
    try readWorldIntegers(gpa, twin, 0, twin_integers);
    on_device.pipe.uploadAt(.world_f, 0, twin_floats);
    on_device.pipe.uploadAt(.world_u, 0, twin_integers);
}

/// How many dispatches `sim` has sent to its device so far, every kernel's together.
fn dispatchesSoFar(sim: *const robotgpu_host.Sim) u64 {
    var total: u64 = 0;
    for (sim.pipe.dispatch_counts) |count| {
        total += count;
    }
    return total;
}

/// WHERE A DECISION's TIME GOES ON THE DEVICE, PRINTED: the pipe's GPU timestamps switched on, one more whole decision
/// run and waited for, then each kernel's time in that decision - its last duration on the GPU times how often the
/// decision dispatched it - the twelve largest first, with their sum. A kernel dispatched several times a decision
/// (Newton's rounds, a step's kinematics) is counted at its last duration, so the table says where to look, not the
/// decision's exact cost: that is the wall clock's, measured before the timestamps were on.
fn reportKernelTimes(
    gpa: Allocator,
    on_device: *robotgpu_host.Sim,
    physics_steps: u32,
    clock: robotgpu.DecisionClock,
    flags_read: []u32,
) !void {
    try on_device.pipe.enableTimings();
    const kernel_count: usize = robotgpu.kernels.len;
    var dispatches_before: [kernel_count]u32 = undefined;
    @memcpy(&dispatches_before, &on_device.pipe.dispatch_counts);
    on_device.stepDecision(physics_steps, clock);
    const flags_offset: u32 = on_device.layout.world_u.episode_flags.offset;
    try readWorldIntegers(gpa, on_device, flags_offset, flags_read);
    var timings: [kernel_count]robotgpu_host.Pipe.KernelTiming = undefined;
    on_device.pipe.kernelTimings(&timings);
    var decision_microseconds: [kernel_count]f64 = undefined;
    var dispatches_in_decision: [kernel_count]u32 = undefined;
    var all_kernels_microseconds: f64 = 0;
    for (0..kernel_count) |kernel| {
        dispatches_in_decision[kernel] = on_device.pipe.dispatch_counts[kernel] - dispatches_before[kernel];
        const dispatches: f64 = @floatFromInt(dispatches_in_decision[kernel]);
        decision_microseconds[kernel] = timings[kernel].microseconds * dispatches;
        all_kernels_microseconds += decision_microseconds[kernel];
    }
    print("vk-host-test: robotgpu kernel times at {d} worlds - {d:.0} microseconds on the GPU a decision, its " ++
        "largest:\n", .{ on_device.counts.world_count, all_kernels_microseconds });
    const kernels_listed: usize = 12;
    for (0..kernels_listed) |_| {
        // The largest not yet printed; printed, it is struck out.
        var largest: usize = 0;
        for (decision_microseconds, 0..) |microseconds, kernel| {
            if (microseconds > decision_microseconds[largest]) {
                largest = kernel;
            }
        }
        const nothing_left: bool = decision_microseconds[largest] <= 0;
        if (nothing_left) {
            break;
        }
        print("vk-host-test:     {s}: {d:.0} microseconds ({d} dispatches of {d:.0})\n", .{
            robotgpu.kernels[largest],
            decision_microseconds[largest],
            dispatches_in_decision[largest],
            timings[largest].microseconds,
        });
        decision_microseconds[largest] = 0;
    }
}

/// THE TRACKING TASK, DEVICE AGAINST TWIN, BY WHOLE DECISIONS: Geno at his training physics on his get-up clip, eight
/// worlds - a fleet of them for the clip's reference tables, its curriculum's mixture and its settings
/// (`Fleet.trackingSettings`), as a trainer would set a device. A GPU's numbers are the twin's only within rounding,
/// and a world whose error sits at a limit can end on one and go on on the other, so NO TRAJECTORY IS COMPARED: before
/// each decision the device is given the twin's worlds whole (both world arenas), each runs the one decision
/// (`Sim.stepDecision`), and every array of the tracking task is compared - numbers by their gap in epsilons,
/// integers exactly. THE EVENTS, on worlds far from any limit: one character knocked a metre off lives on (a loss, an
/// aftermath), is then held on its reference (a return); another knocked off has no aftermath - its episode ends and
/// it starts again at the frame the curriculum draws, resting on the floor, with its noise, in trouble; every world
/// still in its episode is pushed each decision. THEN THE DEVICE ALONE, TIMED (`size.timed_decisions`): more whole
/// decisions back to back, each followed by the readback of every world's flags that a trainer's host makes before
/// the next - what a decision costs on this device at this many worlds, the learner's work apart.
fn runRobotgpuTracking(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    size: TrackingSize,
) !TrackingOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try .fromBytes(gpa, getup_zclip);
    defer clip.deinit();
    // The device's servo steps at the model's timestep, the fleet's at its clip's frame time: the two made one.
    clip.frame_time = model.opt.timestep;
    // The clip's first two seconds: every frame carries about a thousand numbers of tables (its coordinates, its
    // reference's features and bodies), and the test build's model arena holds a few hundred frames of them
    // (`robotgpu_sizes_test.zig`). The clip's storage is unchanged; only its length is.
    const compared_frames: usize = 120;
    clip.frame_count = @min(clip.frame_count, compared_frames);
    const world_count: u32 = size.world_count;
    try expect(world_count >= 8);
    const physics_steps: u32 = 2;
    const fleet: *z.robot_track.Fleet = try z.robot_track.Fleet.init(gpa, model, &.{&clip}, .{
        .envs = world_count,
        .capacity = 32,
        .decide_every = physics_steps,
        .action_filter = 0.5,
        .stiffness_filter = 0.25,
        .limb_stiffness = true,
        // The first half of the characters live on through a loss; the others' episodes end at it.
        .aftermath_steps = 30,
        .return_steps = 2,
        .aftermath_share = 0.5,
        // Every character still in its episode pushed each decision, and every start in trouble.
        .pushes = .{ .every = 1, .rate_per_second = 4.0, .speed_min = 0.3, .speed_max = 0.6, .start_share = 1.0 },
        .start_noise = .{ .pose = 0.05, .velocity = 0.2 },
        .curriculum = .{ .bin_seconds = 0.5 },
    });
    defer fleet.deinit();
    fleet.options.task.rest_on_floor = true;
    // The clip as the device takes it: each frame the model's coordinates, the reference's features and bodies.
    const coordinate_count: usize = model.coordinate_count;
    const root_len: usize = clip.nq - coordinate_count;
    const poses: []f32 = try gpa.alloc(f32, clip.frame_count * coordinate_count);
    defer gpa.free(poses);
    for (0..clip.frame_count) |frame| {
        @memcpy(poses[frame * coordinate_count ..][0..coordinate_count], clip.pose(frame)[root_len..]);
    }
    const features: []f32 = try gpa.alloc(f32, clip.frame_count * z.robot_track.localSize(model.body_count));
    defer gpa.free(features);
    var scratch_data: z.robot.Data = try .init(gpa, model);
    defer scratch_data.deinit();
    var scratch_state: z.robot_track.State = try .init(gpa, model.body_count);
    defer scratch_state.deinit(gpa);
    fleet.clipReferenceFeatures(&clip, &scratch_data, &scratch_state, features);
    const reference_body_count: usize = clip.frame_count * model.body_count * z.robot.reference_body_numbers;
    const reference_bodies: []f32 = try gpa.alloc(f32, reference_body_count);
    defer gpa.free(reference_bodies);
    fleet.clipReferenceBodies(&clip, &scratch_data, &scratch_state, reference_bodies);
    const bin_count: usize = fleet.bins_start[1] - fleet.bins_start[0];
    const clips = [_]robotgpu.ClipPoses{.{
        .poses = poses,
        .frame_count = @intCast(clip.frame_count),
        .frame_time = clip.frame_time,
        .curriculum_bins = @intCast(bin_count),
        .bin_frames = @intCast(z.robot_track.binFrames(&clip, fleet.options.curriculum)),
        .reference_features = features,
        .reference_bodies = reference_bodies,
    }};
    var on_device: robotgpu_host.Sim = try .initGpuTracking(gpa, device, queue, &entries, model, world_count, &clips);
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, &clips);
    defer twin.deinit();
    // The fleet's task on both, as a trainer mirrors it: one value, one call each.
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{});
    try on_device.setTracking(gpa, settings);
    try twin.setTracking(gpa, settings);
    // The curriculum's round as a trainer's host makes it: the fleet's start-bin mixture, summed in order into each
    // simulator's running sums, which a new episode's start is drawn from.
    const mixture: []f32 = try gpa.alloc(f32, bin_count);
    defer gpa.free(mixture);
    const softmax: []const f32 = fleet.bin_softmax[0..bin_count];
    const long_run: []const f32 = fleet.bin_history_weights[0..bin_count];
    z.robot.startBinMixture(fleet.options.curriculum.rule, softmax, long_run, mixture);
    var running_sum: f32 = 0;
    for (mixture, 0..) |probability, bin| {
        running_sum += probability;
        const sum_at: u32 = twin.layout.model_f.bin_running_sums.at(@intCast(bin));
        const sum = [1]f32{running_sum};
        on_device.pipe.uploadAt(.model_f, sum_at, &sum);
        twin.pipe.uploadAt(.model_f, sum_at, &sum);
    }
    // THE WORLDS' STARTS, given to the twin alone (the device takes the twin's worlds before each decision): each on
    // the clip at a frame of its own, at rest; two of them knocked a metre off - one that lives on through its loss,
    // one whose episode ends at it.
    // The second character is in the half that lives on; the third from the last is in the half that does not.
    const knocked_and_living_on: u32 = 1;
    const knocked_to_its_end: u32 = world_count - 3;
    // Start frames nine apart from the tenth, coming round again after nine worlds: every start leaves the compared
    // decisions' frames before the clip's end.
    const first_start_frame: u32 = 10;
    const start_frame_step: u32 = 9;
    const start_frame_span: u32 = 81;
    const last_frame_reached: u32 = first_start_frame + start_frame_span + 16;
    try expect(clip.frame_count > last_frame_reached);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    const pose: []f32 = try gpa.alloc(f32, coordinate_count);
    defer gpa.free(pose);
    var starting_world: u32 = 0;
    while (starting_world < world_count) : (starting_world += 1) {
        const frame: u32 = first_start_frame + (start_frame_step * starting_world) % start_frame_span;
        @memcpy(pose, poses[frame * coordinate_count ..][0..coordinate_count]);
        const is_knocked: bool = starting_world == knocked_and_living_on or starting_world == knocked_to_its_end;
        if (is_knocked) {
            pose[0] += 1.0;
        }
        twin.uploadWorldPositions(starting_world, pose);
        twin.uploadWorldArray("joint_velocities", starting_world, still);
        twin.setWorldClip(starting_world, 0, frame);
    }
    // Every world's state, both arenas whole, as read from each simulator.
    const float_count: u32 = twin.worldArenaEnd(.world_f);
    const integer_count: u32 = twin.worldArenaEnd(.world_u);
    const twin_floats: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(twin_floats);
    const device_floats: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(device_floats);
    const twin_integers: []u32 = try gpa.alloc(u32, integer_count);
    defer gpa.free(twin_integers);
    const device_integers: []u32 = try gpa.alloc(u32, integer_count);
    defer gpa.free(device_integers);
    const world_arrays: robotgpu.WorldStateLayout = twin.layout.world_f;
    const world_integers: robotgpu.WorldIntegersLayout = twin.layout.world_u;
    const velocities: robotgpu.WorldArray(.world_f, .dofs) = world_arrays.joint_velocities;
    const flags: robotgpu.WorldArray(.world_u, .single) = world_integers.episode_flags;
    const velocities_before_resets: []f32 = try gpa.alloc(f32, velocities.stride * world_count);
    defer gpa.free(velocities_before_resets);
    const action_count: usize = twin.counts.action_count;
    const actions: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(actions);
    var outcome: TrackingOutcome = .{
        .float_gaps_epsilons = @splat(0),
        .integer_differences = @splat(0),
        .episodes_restarted = 0,
        .aftermaths_begun = 0,
        .returns = 0,
        .worlds_pushed = 0,
        .timed_decisions = 0,
        .timed_seconds = 0,
        .timed_dispatches = 0,
        .reads_flags_every_decision = size.reads_flags_every_decision,
        .state_floats = float_count,
        .state_integers = integer_count,
        .constraint_floats = twin.worldArenaEnd(.efc_f),
        .world_count = world_count,
        .physics_steps = physics_steps,
    };
    const decision_count: u32 = if (size.compares_with_the_twin) 3 else 0;
    var decision: u32 = 0;
    while (decision < decision_count) : (decision += 1) {
        uploadTrackingActions(&twin, world_count, decision, actions);
        // From the second decision the character in its aftermath is held on its reference, at rest: after two such
        // decisions it has returned.
        const holds_now: bool = decision >= 1;
        if (holds_now) {
            const start_frame: u32 = first_start_frame + start_frame_step * knocked_and_living_on;
            const frame_now: u32 = start_frame + physics_steps * decision;
            const reference_pose: []const f32 = poses[frame_now * coordinate_count ..][0..coordinate_count];
            twin.uploadWorldPositions(knocked_and_living_on, reference_pose);
            twin.uploadWorldArray("joint_velocities", knocked_and_living_on, still);
        }
        // The device takes the twin's worlds whole, so the decision starts from one state on both.
        try giveDeviceTheTwinsWorlds(gpa, &twin, &on_device, twin_floats, twin_integers);
        const clock: robotgpu.DecisionClock = .{ .number = decision + 1, .push_schedule_share = 1.0 };
        on_device.stepDecision(physics_steps, clock);
        // The twin's decision in its parts, its velocities read before its resets: a world whose velocities the resets
        // changed without starting it again was pushed.
        twin.submitDecision(physics_steps);
        twin.submitDecisionEnd();
        try readWorldFloats(gpa, &twin, velocities.offset, velocities_before_resets);
        twin.runResets(clock);
        try readWorldFloats(gpa, &twin, 0, twin_floats);
        try readWorldIntegers(gpa, &twin, 0, twin_integers);
        try readWorldFloats(gpa, &on_device, 0, device_floats);
        try readWorldIntegers(gpa, &on_device, 0, device_integers);
        inline for (tracking_float_arrays, 0..) |tracked, index| {
            const array: @FieldType(robotgpu.WorldStateLayout, tracked.name) = @field(world_arrays, tracked.name);
            const array_length: usize = array.stride * world_count;
            const device_numbers: []const f32 = device_floats[array.offset..][0..array_length];
            const twin_numbers: []const f32 = twin_floats[array.offset..][0..array_length];
            const gap: f32 = robotgpu_host.largestGapEpsilons(device_numbers, twin_numbers, array.stride);
            outcome.float_gaps_epsilons[index] = @max(outcome.float_gaps_epsilons[index], gap);
        }
        inline for (tracking_integer_arrays, 0..) |array_name, index| {
            const array: @FieldType(robotgpu.WorldIntegersLayout, array_name) = @field(world_integers, array_name);
            const array_length: usize = array.stride * world_count;
            const device_numbers: []const u32 = device_integers[array.offset..][0..array_length];
            const twin_numbers: []const u32 = twin_integers[array.offset..][0..array_length];
            for (device_numbers, twin_numbers) |device_number, twin_number| {
                if (device_number != twin_number) {
                    outcome.integer_differences[index] += 1;
                }
            }
        }
        // What happened on the twin this decision.
        var judged_world: u32 = 0;
        while (judged_world < world_count) : (judged_world += 1) {
            const world_flags: u32 = twin_integers[flags.at(judged_world, 0)];
            const finished: bool = world_flags & robotgpu.episodeFlagBit(.finished) != 0;
            const aftermath_begins: bool = world_flags & robotgpu.episodeFlagBit(.aftermath_begins) != 0;
            const returned: bool = world_flags & robotgpu.episodeFlagBit(.returned) != 0;
            const first_before: usize = judged_world * velocities.stride;
            const before: []const f32 = velocities_before_resets[first_before..][0..velocities.stride];
            const after: []const f32 = twin_floats[velocities.at(judged_world, 0)..][0..velocities.stride];
            const resets_changed_velocities: bool = !eql(f32, before, after);
            if (finished) {
                outcome.episodes_restarted += 1;
            } else if (resets_changed_velocities) {
                outcome.worlds_pushed += 1;
            }
            if (aftermath_begins) {
                outcome.aftermaths_begun += 1;
            }
            if (returned) {
                outcome.returns += 1;
            }
        }
    }
    if (!size.compares_with_the_twin) {
        // No decision was compared, so the device has not been given its worlds yet: the twin's starts, with actions.
        uploadTrackingActions(&twin, world_count, 0, actions);
        try giveDeviceTheTwinsWorlds(gpa, &twin, &on_device, twin_floats, twin_integers);
    }
    // THE DEVICE ALONE, TIMED - FIRST ITS WORLD, AS A NIGHT's: a push every three seconds of a character's episode and
    // none at random, in place of the check's push at every decision, which fells most characters within a second.
    // The fleet's settings are built again from its changed options and given to the device.
    fleet.options.pushes.every = 90;
    fleet.options.pushes.rate_per_second = 0;
    try on_device.setTracking(gpa, fleet.trackingSettings(.{}));
    const flags_read: []u32 = try gpa.alloc(u32, flags.stride * world_count);
    defer gpa.free(flags_read);
    // THE WARM-UP: decisions that are not timed, then a read that waits for them. The clock then starts on worlds in
    // the middle of their episodes, at every size alike - a first decision from a pose at rest has no contact yet,
    // and costs a fraction of the ones that follow.
    var warmup_decision: u32 = 0;
    while (warmup_decision < size.warmup_decisions) : (warmup_decision += 1) {
        const warmup_clock: robotgpu.DecisionClock = .{
            .number = decision_count + 1 + warmup_decision,
            .push_schedule_share = 1.0,
        };
        on_device.stepDecision(physics_steps, warmup_clock);
    }
    try readWorldIntegers(gpa, &on_device, flags.offset, flags_read);
    // THE TIMED DECISIONS. The worlds keep their last actions and live through whatever comes - losses, ends, new
    // starts, pushes. After every decision the host reads every world's flags, as a trainer's round does before the
    // next - or, when the size says so, only once after the last decision, which shows what waiting for the GPU at
    // every decision costs. The last read waits for everything: the wall clock around the loop is the cost of the
    // decisions and nothing else.
    const first_timed_number: u32 = decision_count + 1 + size.warmup_decisions;
    const dispatches_before: u64 = dispatchesSoFar(&on_device);
    const timed_started_ms: f64 = z.native_os.monotonicMilliseconds();
    var timed_decision: u32 = 0;
    while (timed_decision < size.timed_decisions) : (timed_decision += 1) {
        const timed_clock: robotgpu.DecisionClock = .{
            .number = first_timed_number + timed_decision,
            .push_schedule_share = 1.0,
        };
        on_device.stepDecision(physics_steps, timed_clock);
        if (size.reads_flags_every_decision) {
            try readWorldIntegers(gpa, &on_device, flags.offset, flags_read);
        }
    }
    try readWorldIntegers(gpa, &on_device, flags.offset, flags_read);
    const timed_ms: f64 = z.native_os.monotonicMilliseconds() - timed_started_ms;
    outcome.timed_decisions = size.timed_decisions;
    outcome.timed_seconds = timed_ms / 1000.0;
    outcome.timed_dispatches = dispatchesSoFar(&on_device) - dispatches_before;
    if (size.profiles_kernels) {
        const profiled_clock: robotgpu.DecisionClock = .{
            .number = first_timed_number + size.timed_decisions,
            .push_schedule_share = 1.0,
        };
        try reportKernelTimes(gpa, &on_device, physics_steps, profiled_clock, flags_read);
    }
    return outcome;
}

/// ONE DEVICE, TWO PIPELINES, ONE COPY - the learner's device spike: numbers uploaded to a learning kit's pipeline
/// (`params`) are copied by `copyFieldInto` into a robotgpu simulator's `world_f` on the same device and queue,
/// then read back from the simulator - the very numbers. So experience can go from the physics to the learner (and
/// back) without leaving the GPU.
fn runCopyBetweenPipelines(kit_pipe: *z.Compute(zn_mlp), sim: *robotgpu_host.Sim) !bool {
    // Numbers no buffer holds by chance, uploaded to the kit's parameters.
    var numbers: [64]f32 = undefined;
    for (&numbers, 0..) |*number, index| {
        number.* = 0.25 * float(index) - 3.5;
    }
    kit_pipe.uploadAt(.params, 0, &numbers);
    // The copy, from the kit's field into the simulator's, on their shared queue.
    const destination: z.DeviceField = sim.pipe.deviceField(.world_f);
    const byte_count: u32 = @intCast(numbers.len * @sizeOf(f32));
    kit_pipe.copyFieldInto(.params, 0, destination, 0, byte_count);
    var read_back: [64]f32 = undefined;
    sim.pipe.readRange(.world_f, 0, &read_back);
    return eql(f32, &numbers, &read_back);
}

/// One dense layer on the CPU in `dense_fwd`'s order: each output its bias, then every input times its weight in
/// order, activated - the weights at `w` with their bias after them, `x.len x y.len`.
fn denseLayerOnCpu(
    params: []const f32,
    w: u32,
    x: []const f32,
    y: []f32,
    act: u32,
) void {
    for (y, 0..) |*out, o| {
        var sum: f32 = params[w + x.len * y.len + o];
        for (x, 0..) |value, i| {
            sum += value * params[w + i * y.len + o];
        }
        out.* = zn_mlp.activate(sum, act);
    }
}

/// THE POLICY ACTING FOR THE SIMULATOR ON ONE DEVICE: a kit with a policy - its features one of Geno's body states
/// wide, its actions the simulator's - acting on one row per world (`actWithSimulator`): rows of known numbers in the
/// simulator's `policy_inputs`, copied in, the three layers run on the GPU, the raw actions copied into the
/// simulator's `actions` and read back. Every action must be the CPU's forward pass within a GPU's rounding of tanh.
fn runActingOnTheDevice(
    gpa: Allocator,
    kit_pipe: *z.Compute(zn_mlp),
    sim: *robotgpu_host.Sim,
    model: *const z.robot.Model,
) !bool {
    const LatentKit: type = z.robot_latent_kit.LatentKit(zn_mlp);
    const world_count: u32 = sim.counts.world_count;
    const features: u32 = @intCast(z.robot.localSize(model.body_count));
    const actions: u32 = sim.counts.action_count;
    const policy_hidden: u32 = 16;
    const kit: LatentKit = try .init(kit_pipe, features, 2, actions, 8, 4, 1, features, policy_hidden);
    var layout: z.kit_mlp.KitLayout = .{
        .acts_floats = kit.total,
        .params_floats = kit.p_at + kit.policy_count,
        .dacts_floats = kit.dtotal,
    };
    const input_stride: u32 = sim.layout.world_f.policy_inputs.stride;
    const action_stride: u32 = sim.layout.world_f.actions.stride;
    const acting: LatentKit.PolicyRows = kit.reservePolicyRows(&layout, world_count, input_stride, action_stride);
    layout.requireFitsKit(zn_mlp);
    // Weights and inputs no buffer holds by chance, small enough that tanh stays in its curved range.
    const params: []f32 = try gpa.alloc(f32, layout.params_floats);
    defer gpa.free(params);
    for (params, 0..) |*number, index| {
        number.* = 0.02 * @sin(0.7 * float(index));
    }
    kit_pipe.upload(.params, params);
    const width: u32 = 2 * features;
    // Every world's row of inputs at its stride, the padding between rows zero.
    const inputs: []f32 = try gpa.alloc(f32, world_count * input_stride);
    defer gpa.free(inputs);
    @memset(inputs, 0);
    for (0..world_count) |row| {
        for (inputs[row * input_stride ..][0..width], 0..) |*number, column| {
            number.* = @cos(0.3 * float(row * width + column));
        }
    }
    const inputs_at: u32 = sim.layout.world_f.policy_inputs.at(0, 0);
    const given_at: u32 = sim.layout.world_f.actions.at(0, 0);
    const chosen_at: u32 = sim.layout.world_f.chosen_actions.at(0, 0);
    sim.pipe.uploadAt(.world_f, inputs_at, inputs);
    kit.actWithSimulator(acting, sim.pipe.deviceField(.world_f), inputs_at, given_at, chosen_at);
    const read_back: []f32 = try gpa.alloc(f32, world_count * action_stride);
    defer gpa.free(read_back);
    sim.pipe.readRange(.world_f, chosen_at, read_back);
    // And acting as one call (`Sim.actWithKit`): the policy's inputs, the policy, then the decision's action - with no
    // filter and no exploration, each action its choice exactly, or nothing where the choice was not finite.
    const quiet_clock: robotgpu.DecisionClock = .{ .number = 1, .push_schedule_share = 0, .exploration_spread = 0 };
    sim.actWithKit(zn_mlp, kit, acting, quiet_clock);
    const chosen_back: []f32 = try gpa.alloc(f32, world_count * action_stride);
    defer gpa.free(chosen_back);
    const actions_back: []f32 = try gpa.alloc(f32, world_count * action_stride);
    defer gpa.free(actions_back);
    sim.pipe.readRange(.world_f, chosen_at, chosen_back);
    sim.pipe.readRange(.world_f, given_at, actions_back);
    for (chosen_back, actions_back) |choice, action| {
        const usable: bool = isFinite(choice);
        const expected: f32 = if (usable) choice else 0.0;
        try expectEqual(expected, action);
    }
    // The CPU's forward pass, in the kernel's order.
    const weights: LatentKit.PolicyWeights = kit.policyWeights();
    const hidden1: []f32 = try gpa.alloc(f32, policy_hidden);
    defer gpa.free(hidden1);
    const hidden2: []f32 = try gpa.alloc(f32, policy_hidden);
    defer gpa.free(hidden2);
    const raw: []f32 = try gpa.alloc(f32, actions);
    defer gpa.free(raw);
    const tanh: u32 = @backingInt(zn_mlp.Act.tanh);
    const linear: u32 = @backingInt(zn_mlp.Act.linear);
    var largest_difference: f32 = 0;
    for (0..world_count) |row| {
        const x: []const f32 = inputs[row * input_stride ..][0..width];
        denseLayerOnCpu(params, weights.first, x, hidden1, tanh);
        denseLayerOnCpu(params, weights.second, hidden1, hidden2, tanh);
        denseLayerOnCpu(params, weights.third, hidden2, raw, linear);
        for (raw, 0..) |expected, action| {
            const difference: f32 = @abs(expected - read_back[row * action_stride + action]);
            largest_difference = @max(largest_difference, difference);
        }
    }
    const tolerance: f32 = 1.0e-5;
    if (largest_difference > tolerance) {
        print("vk-host-test: acting: largest difference {e}; first actions GPU {d:.6} {d:.6}, CPU row 7 {d:.6}\n", .{
            largest_difference,
            read_back[0],
            read_back[1],
            raw[0],
        });
    }
    return largest_difference <= tolerance;
}

/// THE SIMULATOR'S HOST: a `Sim` of Geno at 64 worlds on the device and one on the CPU twin, each made from the model
/// itself - counted, laid out, packed and uploaded. `world_u` is poisoned, a step submitted, every world's overflow
/// word requested and collected: each must be zero, the step's first dispatch having cleared it.
fn runRobotgpuSim(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
) !bool {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, .{});
    defer geno.deinit();
    // Stepped without its constraints: this check measures the smooth step and the integrator against the twin, and
    // the floor it is given is for its contacts' slots alone - with the constraints disabled, no row is made.
    geno.model.opt.disable_constraints = true;
    const world_count: u32 = 64;
    var on_device: robotgpu_host.Sim = try .initGpu(gpa, device, queue, &entries, &geno.model, world_count);
    defer on_device.deinit();
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwin(gpa, &geno.model, world_count);
    defer twin.deinit();
    const poison: u32 = 0xdead_beef;
    const world_u_length: usize = @typeInfo(@FieldType(robotgpu.Buffers, "world_u")).array.len;
    const poisoned: []u32 = try gpa.alloc(u32, world_u_length);
    defer gpa.free(poisoned);
    @memset(poisoned, poison);
    const sims = [2]*robotgpu_host.Sim{ &on_device, &twin };
    for (sims) |sim| {
        sim.pipe.upload(.world_u, poisoned);
        sim.submitStep();
        var request: robotgpu_host.Pipe.RangeRequest(.world_u) = try sim.requestOverflow(gpa);
        const collected: []u32 = try gpa.alloc(u32, sim.overflowWordCount());
        defer gpa.free(collected);
        request.wait(collected);
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            if (sim.overflowOf(collected, world) != 0) {
                return false;
            }
        }
    }
    return true;
}

/// THE SIMULATOR'S FIRST KERNEL: `clear_overflow` over 64 worlds of Geno (the engine's own model), on the device and on
/// its CPU twin. `world_u` starts full of a poison word; afterwards every world's overflow word must be zero and every
/// other word still the poison - the kernel found each world's word through the layout, and wrote nothing else:
///
///     world_u before   [ P P P P P P P P ... ]                 P = 0xdeadbeef
///     after            [ 0 P P P 0 P P P ... ]                 each world's overflow word at offset + w x stride
fn runRobotgpuOverflow(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const RobotgpuCompute: type = z.Compute(robotgpu);
    const entries: [robotgpu.kernels.len]RobotgpuCompute.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var on_device: RobotgpuCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: RobotgpuCompute = .initCpu();
    defer twin.deinit();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, .{});
    defer geno.deinit();
    const counts: robotgpu.Counts = robotgpu.countsOf(&geno.model, 64);
    const layout: robotgpu.Layout = try robotgpu.layoutFor(counts, .{});
    const overflow: robotgpu.WorldArray(.world_u, .single) = layout.world_u.overflow;
    const poison: u32 = 0xdead_beef;
    const word_count: u32 = 4096;
    const poisoned: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(poisoned);
    @memset(poisoned, poison);
    const read_back: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(read_back);
    const pipes = [2]*RobotgpuCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.upload(.world_u, poisoned);
        pipe.params = .{ .counts = counts, .layout = layout };
        pipe.run("clear_overflow", counts.world_count);
        pipe.readRange(.world_u, 0, read_back);
        for (read_back, 0..) |word, index| {
            const word_index: u32 = @intCast(index);
            const relative: u32 = word_index -% overflow.offset;
            const in_overflow: bool = word_index >= overflow.offset and
                relative < overflow.stride * counts.world_count and relative % overflow.stride == 0;
            const expected: u32 = if (in_overflow) 0 else poison;
            if (word != expected) {
                return false;
            }
        }
    }
    return true;
}

/// THE MEMORY ENVELOPE'S CHECK: one storage buffer as large as a binding may span - the most
/// one arena of a simulation can hold, capped at 256 MB to spare the machine the test runs on - allocated, a page of
/// words written at its start and at its very end, and both read back:
///
///     [ start page | .................. the arena .................. | end page ]
///         write          (nothing touched in between)                    write
///         read back                                                      read back
///
/// Returns the bytes allocated, or null when either page came back wrong.
fn runMemoryEnvelope(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !?u64 {
    const capabilities: wgpu.vulkan_host.ComputeCapabilities = wgpu.computeCapabilities();
    const sandbox_cap: u64 = 256 << 20;
    const arena_bytes: u32 = @intCast(@min(capabilities.max_storage_binding_bytes, sandbox_cap));
    const arena: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = arena_bytes,
        .usage = .{ .storage = true, .copy_src = true, .copy_dst = true },
        .label = "envelope_arena",
    });
    defer wgpu.destroyBuffer(arena);
    const page_words: u32 = 1024;
    const page_bytes: u32 = page_words * @sizeOf(u32);
    const end_page_at: u32 = arena_bytes - page_bytes;
    const start_page: []u32 = try gpa.alloc(u32, page_words);
    defer gpa.free(start_page);
    const end_page: []u32 = try gpa.alloc(u32, page_words);
    defer gpa.free(end_page);
    for (start_page, end_page, 0..) |*start_word, *end_word, index| {
        const word_index: u32 = @intCast(index);
        start_word.* = 0x5_7a77 + word_index;
        end_word.* = 0xe_d000 + word_index;
    }
    wgpu.queueWriteBuffer(queue, arena, 0, sliceAsBytes(start_page));
    wgpu.queueWriteBuffer(queue, arena, end_page_at, sliceAsBytes(end_page));
    const staging: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = 2 * page_bytes,
        .usage = .{ .map_read = true, .copy_dst = true },
        .label = "envelope_staging",
    });
    defer wgpu.destroyBuffer(staging);
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    wgpu.copyBufferToBuffer(encoder, arena, 0, staging, 0, page_bytes);
    wgpu.copyBufferToBuffer(encoder, arena, end_page_at, staging, page_bytes, page_bytes);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    const read: wgpu.BufferRead = wgpu.bufferReadStart(staging, 2 * page_bytes);
    while (!wgpu.bufferReadPoll(read)) {
        std.atomic.spinLoopHint();
    }
    const read_back: []u32 = try gpa.alloc(u32, 2 * page_words);
    defer gpa.free(read_back);
    wgpu.bufferReadInto(read, sliceAsBytes(read_back));
    wgpu.bufferReadRelease(read);
    const start_matches: bool = eql(u32, read_back[0..page_words], start_page);
    const end_matches: bool = eql(u32, read_back[page_words..], end_page);
    return if (start_matches and end_matches) arena_bytes else null;
}

/// What the Cholesky check measured (`runCholesky`): the device's L L^T against A, relative to A's largest entry;
/// the device's L against the twin's, and the twin's against zimrnum's `cholesky`, in epsilons at each entry's scale;
/// and whether two device runs gave the same bits.
const CholeskyOutcome = struct {
    reconstruction_relative: f64,
    device_twin_epsilons: f32,
    twin_zimrnum_epsilons: f32,
    repeats_exactly: bool,
};

/// The largest gap between two lower triangles of `matrix_count` matrices of `order`, in epsilons at each entry's
/// scale (`max(1, |reference|)`).
fn lowerTriangleGap(
    left: []const f32,
    reference: []const f32,
    order: usize,
    matrix_count: usize,
) f32 {
    // f32's epsilon, 2^-23: the gap between 1 and the next float.
    const epsilon: f32 = 0x1p-23;
    var largest: f32 = 0;
    for (0..matrix_count) |matrix| {
        const start: usize = matrix * order * order;
        for (0..order) |row| {
            for (0..row + 1) |column| {
                const at: usize = start + row * order + column;
                const scale: f32 = @max(1.0, @abs(reference[at]));
                const difference: f32 = @abs(left[at] - reference[at]);
                largest = @max(largest, difference / (epsilon * scale));
            }
        }
    }
    return largest;
}

/// THE CHOLESKY CHECK: eight random symmetric positive-definite matrices of order 76 - the
/// size of Geno's Newton Hessian - A = B B^T + 76 I with B uniform in [-1, 1], factored by `cholesky`, one workgroup
/// each, on the device and on the twin (robot.zig's `choleskyFactor`), and by zimrnum's `cholesky` as an independent
/// reference:
///
///     L L^T - A                  the factorisation itself, relative to A's largest entry
///     device L - twin L          the same arithmetic in the same order: only fused multiplies may differ
///     twin L - zimrnum's L       two independent implementations
///     device run 1 - run 2       bit for bit (D7)
///
/// The bars: measured 0 epsilons both ways on lavapipe, which fuses no multiplies. A GPU whose compiler fuses each
/// subtraction's multiply rounds once less per step, and over the 76 columns that can accumulate - 128 epsilons, the
/// order twice over, leaves room for it.
fn runCholesky(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !CholeskyOutcome {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    const order: u32 = robotgpu_probe.max_matrix_order;
    const matrix_count: u32 = 8;
    const element_count: u32 = order * order * matrix_count;
    const matrices: []f32 = try gpa.alloc(f32, element_count);
    defer gpa.free(matrices);
    var generator: Random.DefaultPrng = .init(0xc0_1e5c);
    const random: Random = generator.random();
    const factors: []f64 = try gpa.alloc(f64, order * order);
    defer gpa.free(factors);
    for (0..matrix_count) |matrix| {
        for (factors) |*factor| {
            factor.* = random.float(f64) * 2.0 - 1.0;
        }
        const start: usize = matrix * order * order;
        for (0..order) |row| {
            for (0..order) |column| {
                var product: f64 = 0;
                for (0..order) |inner| {
                    product += factors[row * order + inner] * factors[column * order + inner];
                }
                const diagonal_boost: f64 = if (row == column) @floatFromInt(order) else 0;
                matrices[start + row * order + column] = @floatCast(product + diagonal_boost);
            }
        }
    }
    const pipes = [2]*ProbeCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.upload(.values, matrices);
        pipe.params = .{ .value_count = 0, .subgroup_size = 1, .matrix_order = order, .matrix_count = matrix_count };
        pipe.run("cholesky", matrix_count * robotgpu_probe.config.workgroup);
    }
    const device_factors: []f32 = try gpa.alloc(f32, element_count);
    defer gpa.free(device_factors);
    on_device.readRange(.sums, 0, device_factors);
    const twin_factors: []f32 = try gpa.alloc(f32, element_count);
    defer gpa.free(twin_factors);
    twin.readRange(.sums, 0, twin_factors);
    // L L^T against A, over the lower triangle, relative to A's largest entry.
    var largest_entry: f64 = 0;
    for (matrices) |entry| {
        largest_entry = @max(largest_entry, @abs(@as(f64, entry)));
    }
    var reconstruction_gap: f64 = 0;
    for (0..matrix_count) |matrix| {
        const start: usize = matrix * order * order;
        for (0..order) |row| {
            for (0..row + 1) |column| {
                var product: f64 = 0;
                for (0..column + 1) |inner| {
                    const left: f64 = device_factors[start + row * order + inner];
                    const right: f64 = device_factors[start + column * order + inner];
                    product += left * right;
                }
                const original: f64 = matrices[start + row * order + column];
                reconstruction_gap = @max(reconstruction_gap, @abs(product - original));
            }
        }
    }
    // zimrnum's own Cholesky of each matrix, an independent implementation.
    const zimrnum_factors: []f32 = try gpa.alloc(f32, element_count);
    defer gpa.free(zimrnum_factors);
    for (0..matrix_count) |matrix| {
        const start: usize = matrix * order * order;
        const shape = [2]usize{ order, order };
        const original_tensor: zn.Tensor(f32) = try .fromSlice(matrices[start..][0 .. order * order], &shape);
        const factor_tensor: zn.Tensor(f32) = try .fromSlice(zimrnum_factors[start..][0 .. order * order], &shape);
        try zn.cholesky(f32, factor_tensor, original_tensor);
    }
    // A second device run, for repeatability.
    on_device.run("cholesky", matrix_count * robotgpu_probe.config.workgroup);
    const second_factors: []f32 = try gpa.alloc(f32, element_count);
    defer gpa.free(second_factors);
    on_device.readRange(.sums, 0, second_factors);
    const first_bits: []const u32 = @ptrCast(device_factors);
    const second_bits: []const u32 = @ptrCast(second_factors);
    const outcome: CholeskyOutcome = .{
        .reconstruction_relative = reconstruction_gap / largest_entry,
        .device_twin_epsilons = lowerTriangleGap(device_factors, twin_factors, order, matrix_count),
        .twin_zimrnum_epsilons = lowerTriangleGap(twin_factors, zimrnum_factors, order, matrix_count),
        .repeats_exactly = eql(u32, first_bits, second_bits),
    };
    return outcome;
}

/// BUFFER LENDING'S CHECK: a second probe pipe BORROWS the first's `pushed_words` buffer
/// (`lendField`, `initGpuBorrowing`) and runs `write_pushed` into it; the first reads its own buffer and finds the
/// second's writes - one buffer, two pipes, nothing uploaded or copied between them:
///
///     owner      pushed_words  [ 0 0 0 ... ]  --lent-->  borrower runs write_pushed (77)
///     owner      reads its own pushed_words:  [ 77 77 77 ... ]
fn runBorrowing(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var owner: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer owner.deinit();
    const word_count: u32 = 1000;
    const zeroed: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(zeroed);
    @memset(zeroed, 0);
    owner.upload(.pushed_words, zeroed);
    const borrowed = [1]ProbeCompute.Borrowed{.{ .field = .pushed_words, .loan = owner.lendField(.pushed_words) }};
    var borrower: ProbeCompute = try .initGpuBorrowing(gpa, device, queue, &entries, &borrowed);
    defer borrower.deinit();
    borrower.params = .{ .value_count = 0, .subgroup_size = 1, .pushed_region_size = word_count };
    const push: robotgpu_probe.PushConstants = .{ .region_start = 0, .value = 77 };
    borrower.runPushed("write_pushed", word_count, push);
    const owner_words: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(owner_words);
    owner.readRange(.pushed_words, 0, owner_words);
    var every_word_written: bool = true;
    for (owner_words) |word| {
        every_word_written = every_word_written and word == 77;
    }
    return every_word_written;
}

/// What the timings check measured (`runTimings`): `busy_work`'s duration with some rounds and with four times as
/// many, in microseconds, and whether a pipe without timings reported none.
const TimingOutcome = struct {
    one_times_microseconds: f64,
    four_times_microseconds: f64,
    untimed_reports_none: bool,
};

/// TIMINGS' CHECK: `busy_work` over 65,536 values, timed on the GPU - once with 2,000 rounds
/// a value, once with 8,000 - on a pipe with timings; then a pipe without them, which must report nothing:
///
///     [ start timestamp ] [ busy_work, 2,000 rounds ] [ end timestamp ]   ->  t1
///     [ start timestamp ] [ busy_work, 8,000 rounds ] [ end timestamp ]   ->  t4, longer than t1
fn runTimings(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !TimingOutcome {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    try on_device.enableTimings();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    const value_count: u32 = robotgpu_probe.table_capacity;
    const starting_values: []f32 = try gpa.alloc(f32, value_count);
    defer gpa.free(starting_values);
    @memset(starting_values, 1.0);
    on_device.upload(.values, starting_values);
    on_device.params = .{ .value_count = value_count, .subgroup_size = 1 };
    const busy_index: usize = comptime blk: {
        for (robotgpu_probe.kernels, 0..) |kernel_name, index| {
            if (eql(u8, kernel_name, "busy_work")) {
                break :blk index;
            }
        }
        @compileError("the probe has no busy_work entry");
    };
    var timings: [robotgpu_probe.kernels.len]ProbeCompute.KernelTiming = undefined;
    const base_rounds: u32 = 2000;
    const once: robotgpu_probe.PushConstants = .{ .region_start = 0, .value = 0, .iterations = base_rounds };
    on_device.runPushed("busy_work", value_count, once);
    on_device.kernelTimings(&timings);
    const one_times: f64 = timings[busy_index].microseconds;
    const four_times_rounds: u32 = 4 * base_rounds;
    const four_times_push: robotgpu_probe.PushConstants = .{
        .region_start = 0,
        .value = 0,
        .iterations = four_times_rounds,
    };
    on_device.runPushed("busy_work", value_count, four_times_push);
    on_device.kernelTimings(&timings);
    const four_times: f64 = timings[busy_index].microseconds;
    twin.kernelTimings(&timings);
    var untimed_reports_none: bool = true;
    for (timings) |timing| {
        untimed_reports_none = untimed_reports_none and timing.microseconds == 0;
    }
    const outcome: TimingOutcome = .{
        .one_times_microseconds = one_times,
        .four_times_microseconds = four_times,
        .untimed_reports_none = untimed_reports_none,
    };
    return outcome;
}

/// PUSH CONSTANTS' CHECK: `write_pushed` dispatched three times in ONE batch - one `Params`
/// for all three - each with its own push, a region's start and a value. Each region must hold its own value, on the
/// device and on the twin:
///
///     batch:  [ push (0, 11) | dispatch ]  [ push (1000, 22) | dispatch ]  [ push (2000, 33) | dispatch ]
///     words:  [ 11 11 ... 11 ][ 22 22 ... 22 ][ 33 33 ... 33 ]
fn runPushedBatch(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    const region_size: u32 = 1000;
    const pushed_values = [3]u32{ 11, 22, 33 };
    const word_count: u32 = region_size * pushed_values.len;
    const zeroed: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(zeroed);
    @memset(zeroed, 0);
    const batch_params: robotgpu_probe.Params = .{
        .value_count = 0,
        .subgroup_size = 1,
        .pushed_region_size = region_size,
    };
    const pipes = [2]*ProbeCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.upload(.pushed_words, zeroed);
        pipe.beginBatch(batch_params);
        for (pushed_values, 0..) |value, region| {
            const region_index: u32 = @intCast(region);
            const push: robotgpu_probe.PushConstants = .{ .region_start = region_index * region_size, .value = value };
            pipe.runPushed("write_pushed", region_size, push);
        }
        pipe.endBatch();
    }
    const words: []u32 = try gpa.alloc(u32, word_count);
    defer gpa.free(words);
    var every_region_holds: bool = true;
    for (pipes) |pipe| {
        pipe.readRange(.pushed_words, 0, words);
        for (pushed_values, 0..) |value, region| {
            const region_words: []const u32 = words[region * region_size ..][0..region_size];
            for (region_words) |word| {
                every_region_holds = every_region_holds and word == value;
            }
        }
    }
    return every_region_holds;
}

/// RANGED READBACK'S CHECK: an exact pattern uploaded into the probe's `values`, then read
/// back in three ranges through the probe's 4,096-byte staging buffer (1,024 floats a chunk) - the start, a stretch
/// crossing three chunk boundaries, and the end - each equal to the pattern bit for bit, on the device and on the twin.
fn runRangedReadback(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    const capacity: u32 = robotgpu_probe.table_capacity;
    const pattern: []f32 = try gpa.alloc(f32, capacity);
    defer gpa.free(pattern);
    for (pattern, 0..) |*value, index| {
        // Halves of whole numbers below 2^24: every one exact in f32.
        const position: f32 = @floatFromInt(index);
        value.* = position * 0.5 + 1.0;
    }
    const pipes = [2]*ProbeCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.upload(.values, pattern);
    }
    const Range = struct {
        first: u32,
        count: u32,
    };
    const ranges = [3]Range{
        .{ .first = 0, .count = 100 },
        .{ .first = 30_000, .count = 3_000 },
        .{ .first = capacity - 777, .count = 777 },
    };
    var every_range_matches: bool = true;
    for (ranges) |range| {
        const read_back: []f32 = try gpa.alloc(f32, range.count);
        defer gpa.free(read_back);
        const expected: []const f32 = pattern[range.first..][0..range.count];
        for (pipes) |pipe| {
            pipe.readRange(.values, range.first, read_back);
            const expected_bits: []const u32 = @ptrCast(expected);
            const read_bits: []const u32 = @ptrCast(read_back);
            every_range_matches = every_range_matches and eql(u32, expected_bits, read_bits);
        }
    }
    return every_range_matches;
}

/// THE LARGE DISPATCH'S CHECK: `dispatch_tally` over 5,000,000 invocations - 78,125
/// workgroups of 64, past the 65,535 one row holds, so the grid has two rows (`compute_host.dispatchGrid`). Every
/// index below the count must run exactly once: the device's two counters, and the twin's, must both equal the count
/// and the sum of the indices' low sixteen bits worked out here. Returns whether they do.
fn runDispatchTally(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    const invocation_count: u32 = 5_000_000;
    // The expected counters: the count, and the sum of every index's low sixteen bits, wrapping as a u32 does.
    var expected_sum: u32 = 0;
    var index: u32 = 0;
    while (index < invocation_count) : (index += 1) {
        expected_sum +%= index & 0xffff;
    }
    const zeroed = [2]u32{ 0, 0 };
    const pipes = [2]*ProbeCompute{ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.element_count = 2;
        pipe.upload(.dispatch_tally, &zeroed);
        pipe.params = .{ .value_count = 0, .subgroup_size = 1, .tally_count = invocation_count };
        pipe.run("dispatch_tally", invocation_count);
    }
    var device_tally: [2]u32 = undefined;
    on_device.readRange(.dispatch_tally, 0, &device_tally);
    var twin_tally: [2]u32 = undefined;
    twin.readRange(.dispatch_tally, 0, &twin_tally);
    print("vk-host-test: robotgpu large dispatch: device {d} invocations, index sum {d}; twin {d}, {d}; " ++
        "expected {d}, {d}\n", .{
        device_tally[0],
        device_tally[1],
        twin_tally[0],
        twin_tally[1],
        invocation_count,
        expected_sum,
    });
    const device_right: bool = device_tally[0] == invocation_count and device_tally[1] == expected_sum;
    const twin_right: bool = twin_tally[0] == invocation_count and twin_tally[1] == expected_sum;
    return device_right and twin_right;
}

/// The probe's row types and the helpers that read their layout (`robotgpu_probe.floatOffset`).
const MathsInputs = robotgpu_probe.MathsInputs;
const MathsResults = robotgpu_probe.MathsResults;
const SpatialInputs = robotgpu_probe.SpatialInputs;
const SpatialResults = robotgpu_probe.SpatialResults;
const PairFloats = robotgpu_probe.PairFloats;
const InertiaFloats = robotgpu_probe.InertiaFloats;
const floatOffset = robotgpu_probe.floatOffset;
const floatWidth = robotgpu_probe.floatWidth;
const rowWidth = robotgpu_probe.rowWidth;

/// The result at `field` of a probe table's result row `Results`, its place and width read from the declaration.
fn probeResult(
    comptime Results: type,
    comptime field: FieldEnum(Results),
    name: []const u8,
    bar_epsilons: f32,
) ProbeResult {
    const result: ProbeResult = .{
        .name = name,
        .offset = floatOffset(Results, field),
        .width = floatWidth(Results, field),
        .bar_epsilons = bar_epsilons,
    };
    return result;
}

/// THE MATHS PROBE'S TABLE: every zimrmath function robot.zig's arithmetic calls, in `robotgpu_probe.MathsResults`'
/// order, 1,024 rows. Each bar is two to four times the largest gap any device has shown, in epsilons at the result's
/// scale: lavapipe computes on the CPU and rounds as the twin does; an NVIDIA GPU fuses a multiply into an add (one
/// rounding where the twin rounds twice) and does not round its square root correctly, and each shows here:
///
///     result                   lavapipe   RTX 5070   bar    what is behind it
///     conjugate, normalize3,   0          0 - 1      4      plain arithmetic and square roots
///     cross, dot3, length3
///     qmul                     1.14       1.74       4      one fused multiply-add showing
///     rotate                   0          3.33       8      a rotation's products, fused on NVIDIA
///     the two axis-angle       1.00       1.50       8      zimrmath's GPU sine and cosine (polynomials) against
///     forms                                                 the CPU's library
///     acosRad                  1.91       11.44      32     zimrmath's GPU acos: a polynomial with a square root,
///                                                           steep near +-1, where an input's last bit moves the
///                                                           angle most
///     atan2Rad                 28         28.50      64     zimrmath's GPU atan2 - the least precise, about 1e-5
///                                                           radian near pi, far below what the physics resolves
const MathsCheck = struct {
    const row_count: u32 = 1024;

    const results = [_]ProbeResult{
        probeResult(MathsResults, .product, "qmul", 4),
        probeResult(MathsResults, .conjugated, "conjugate", 4),
        probeResult(MathsResults, .rotated, "rotate", 8),
        probeResult(MathsResults, .from_unit_axis, "quatFromNormAxisAngle", 8),
        probeResult(MathsResults, .from_axis, "quatFromAxisAngle", 8),
        probeResult(MathsResults, .normalized, "normalize3", 4),
        probeResult(MathsResults, .crossed, "cross", 4),
        probeResult(MathsResults, .dot_product, "dot3", 4),
        probeResult(MathsResults, .vector_length, "length3", 4),
        probeResult(MathsResults, .heading, "atan2Rad", 64),
        probeResult(MathsResults, .angle_between, "acosRad", 32),
    };

    /// Per row: a unit rotation; a quaternion and a vector whose three-dimensional parts stay away from zero; an angle
    /// in [-pi, pi] (`MathsInputs` places each).
    fn fillInputs(inputs: []f32) void {
        var generator: Random.DefaultPrng = .init(0x5eed_0b07);
        const random: Random = generator.random();
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            const at: u32 = row * rowWidth(MathsInputs);
            const rotation: [4]f32 = ProbeInputs.unitQuaternion(random);
            @memcpy(inputs[at + floatOffset(MathsInputs, .rotation) ..][0..4], &rotation);
            const other_part: [3]f32 = ProbeInputs.awayFromZero(random, 0.2, 1.5);
            const other_w: f32 = ProbeInputs.uniform(random, -1.5, 1.5);
            ProbeInputs.putVector(inputs, at + floatOffset(MathsInputs, .other), other_part, other_w);
            const vector: [3]f32 = ProbeInputs.awayFromZero(random, 0.2, 2.0);
            ProbeInputs.putVector(inputs, at + floatOffset(MathsInputs, .vector), vector, 0.0);
            inputs[at + floatOffset(MathsInputs, .angle)] = ProbeInputs.uniform(random, -pi, pi);
        }
    }

    const table: ProbeTable = .{
        .entry_name = "maths",
        .inputs_field = .maths_inputs,
        .outputs_field = .maths_outputs,
        .row_count = row_count,
        .input_width = rowWidth(MathsInputs),
        .output_width = rowWidth(MathsResults),
        .fill = &fillInputs,
        .params = .{ .value_count = 0, .subgroup_size = 1, .maths_rows = row_count },
        .results = &results,
    };
};

/// THE SPATIAL PROBE'S TABLE: robot.zig's spatial algebra in `robotgpu_probe.SpatialResults`' order - plain
/// arithmetic throughout, no transcendental function - 1,024 rows. Each bar is two to four times the largest gap any
/// device has shown, in epsilons at the result's scale (an NVIDIA GPU fuses a multiply into an add, rounding once where
/// the twin rounds twice):
///
///     result                   lavapipe   RTX 5070   bar    what is behind it
///     Inertia.rotated          0          2.00       4      products fused on NVIDIA
///     Inertia.mul,             1.00       1.41-1.91  4      one fused multiply-add showing
///     Inertia.translate
///     crossMotion              1.62       2.93       8      the same, with a little cancellation (velocities up to 3:
///                                                           terms to 9)
///     crossForce               8.61       8.61       16     CANCELLATION: forces up to 20 against velocities up to 3
///                                                           make terms near 60; where they cancel, the result is far
///                                                           smaller than what was rounded, and the gap is measured
///                                                           at the result's scale
///     dot6                     0          16.00      64     the same cancellation - six products near 60 summed into
///                                                           a small power - with every product fused on NVIDIA
/// The inputs are physically plausible: velocities
/// and forces whose parts stay away from zero, a mass in [0.5, 5], a centre of mass within 0.3 of the origin (so
/// `h` = mass x centre of mass), positive principal moments with small products of inertia, a unit rotation and an
/// offset within 0.5.
const SpatialCheck = struct {
    const row_count: u32 = 1024;

    const results = [_]ProbeResult{
        probeResult(SpatialResults, .motion_cross, "crossMotion", 8),
        probeResult(SpatialResults, .force_cross, "crossForce", 16),
        probeResult(SpatialResults, .inertia_times_motion, "Inertia.mul", 4),
        probeResult(SpatialResults, .translated, "Inertia.translate", 4),
        probeResult(SpatialResults, .rotated, "Inertia.rotated", 4),
        probeResult(SpatialResults, .power, "dot6", 64),
    };

    /// A Motion's or a Force's two parts into `inputs` at `at`, each a vector of a length in [min_length, max_length).
    fn putPair(
        random: Random,
        inputs: []f32,
        at: u32,
        min_length: f32,
        max_length: f32,
    ) void {
        const angular: [3]f32 = ProbeInputs.awayFromZero(random, min_length, max_length);
        const linear: [3]f32 = ProbeInputs.awayFromZero(random, min_length, max_length);
        ProbeInputs.putVector(inputs, at + floatOffset(PairFloats, .angular), angular, 0.0);
        ProbeInputs.putVector(inputs, at + floatOffset(PairFloats, .linear), linear, 0.0);
    }

    fn fillInputs(inputs: []f32) void {
        var generator: Random.DefaultPrng = .init(0x5ba7_1a15);
        const random: Random = generator.random();
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            const at: u32 = row * rowWidth(SpatialInputs);
            putPair(random, inputs, at + floatOffset(SpatialInputs, .velocity), 0.1, 3.0);
            putPair(random, inputs, at + floatOffset(SpatialInputs, .motion), 0.1, 3.0);
            putPair(random, inputs, at + floatOffset(SpatialInputs, .force), 0.1, 20.0);
            const inertia_at: u32 = at + floatOffset(SpatialInputs, .inertia);
            const mass: f32 = ProbeInputs.uniform(random, 0.5, 5.0);
            const centre_of_mass: [3]f32 = ProbeInputs.awayFromZero(random, 0.01, 0.3);
            const principal: [3]f32 = .{
                ProbeInputs.uniform(random, 0.02, 0.5),
                ProbeInputs.uniform(random, 0.02, 0.5),
                ProbeInputs.uniform(random, 0.02, 0.5),
            };
            const products: [3]f32 = .{
                ProbeInputs.uniform(random, -0.02, 0.02),
                ProbeInputs.uniform(random, -0.02, 0.02),
                ProbeInputs.uniform(random, -0.02, 0.02),
            };
            const first_moment: [3]f32 = .{
                mass * centre_of_mass[0],
                mass * centre_of_mass[1],
                mass * centre_of_mass[2],
            };
            ProbeInputs.putVector(inputs, inertia_at + floatOffset(InertiaFloats, .diag), principal, 0.0);
            ProbeInputs.putVector(inputs, inertia_at + floatOffset(InertiaFloats, .off), products, 0.0);
            ProbeInputs.putVector(inputs, inertia_at + floatOffset(InertiaFloats, .h), first_moment, 0.0);
            inputs[inertia_at + floatOffset(InertiaFloats, .mass)] = mass;
            const rotation: [4]f32 = ProbeInputs.unitQuaternion(random);
            @memcpy(inputs[at + floatOffset(SpatialInputs, .rotation) ..][0..4], &rotation);
            const offset: [3]f32 = ProbeInputs.awayFromZero(random, 0.01, 0.5);
            ProbeInputs.putVector(inputs, at + floatOffset(SpatialInputs, .offset), offset, 0.0);
        }
    }

    const table: ProbeTable = .{
        .entry_name = "spatial",
        .inputs_field = .spatial_inputs,
        .outputs_field = .spatial_outputs,
        .row_count = row_count,
        .input_width = rowWidth(SpatialInputs),
        .output_width = rowWidth(SpatialResults),
        .fill = &fillInputs,
        .params = .{ .value_count = 0, .subgroup_size = 1, .spatial_rows = row_count },
        .results = &results,
    };
};

/// Every pipeline of zimrnum's two training kernel files, made and released: `zn_train` (the two-layer network) and
/// `zn_mlp` (dense layers, their gradients, the optimisers). The sweep runs single operations; these files' kernels
/// index their buffers by constants too - a loss written to `loss[0]` and `loss[1]` - which the compiler lowers by
/// another path, and the validation layer judges each pipeline as it is made.
fn makeTrainingPipelines(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !void {
    var two_layer: z.Compute(zn_train) = try .initGpu(gpa, device, queue, &spirvEntries(zn_train, zn_train_spirv));
    two_layer.deinit();
    var dense_layers: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    dense_layers.deinit();
}

/// One dispatch of the kit's check: the kernel, its uniform, its thread count.
const KitStep = struct {
    kernel: []const u8,
    params: zn_mlp.Params,
    threads: u32,
};

/// The kit check (this file's head): its sizes, where its values live, and its sequences of dispatches. A normed
/// layer of 6 inputs and 16 outputs on 3 rows (SimNorm in groups of 8), and a two-hot head of BMPC's 101 bins on 5
/// rows. Params hold W, b, the gains, the norm biases; acts the input, the pre-activations, the normalised rows, the
/// scaled values, the outputs, the inverse spreads, the targets, then the two-hot head's logits, targets, losses and
/// values; dacts the gradients at the output, at the scaled values, at the pre-activations, at the input, and at the
/// two-hot head's logits - as `gpu_learn_tests.zig`'s known answers place them.
const KitCheck = struct {
    const rows: u32 = 3;
    const inputs: u32 = 6;
    const outputs: u32 = 16;
    const group: u32 = 8;
    const bins: u32 = 101;
    const two_hot_rows: u32 = 5;

    const block: u32 = rows * outputs;
    const gains: u32 = inputs * outputs + outputs;
    const params_end: u32 = gains + 2 * outputs;
    const input: u32 = 0;
    const linear: u32 = rows * inputs;
    const normalised: u32 = linear + block;
    const scaled: u32 = normalised + block;
    const output: u32 = scaled + block;
    const inverse_spreads: u32 = output + block;
    const targets: u32 = inverse_spreads + rows;
    const logits: u32 = targets + block;
    const two_hot_targets: u32 = logits + two_hot_rows * bins;
    const losses: u32 = two_hot_targets + two_hot_rows;
    const values: u32 = losses + two_hot_rows;
    // The flow policy's kernels on 3 rows of 2 actions, their wide rows [condition 4 | x 2 | time 6] 12 wide: the
    // wide rows, a velocity as the network would leave it, the rows an Euler step writes into, and each row's action,
    // noise, time, path velocity and cost gradient.
    const flow_rows: u32 = 3;
    const flow_actions: u32 = 2;
    const flow_width: u32 = 12;
    const flow_point_column: u32 = 4;
    const flow_time_column: u32 = 6;
    const flow_wide: u32 = values + two_hot_rows;
    const flow_velocity: u32 = flow_wide + flow_rows * flow_width;
    const flow_next: u32 = flow_velocity + flow_rows * flow_actions;
    const flow_action_values: u32 = flow_next + flow_rows * flow_width;
    const flow_noise: u32 = flow_action_values + flow_rows * flow_actions;
    const flow_times: u32 = flow_noise + flow_rows * flow_actions;
    const flow_path_velocities: u32 = flow_times + flow_rows;
    const flow_cost_gradients: u32 = flow_path_velocities + flow_rows * flow_actions;
    // The tracking planner's kernels: MPPI's warm start (2 states, a plan of 4 steps of 2 actions, shifted by 2), its
    // elites weighed relative to their spread (2 states, 8 candidates, 4 elites), and the planner's gather (2 states x
    // 2 rows, 3 steps, wide rows [goal 4 | state 4 | reference 3 | action 2], a reference table of 6 rows).
    const plan_states: u32 = 2;
    const plan_horizon: u32 = 4;
    const plan_actions: u32 = 2;
    const warm_flags: u32 = flow_cost_gradients + flow_rows * flow_actions;
    const warm_means: u32 = warm_flags + plan_states;
    const warm_spreads: u32 = warm_means + plan_states * plan_horizon * plan_actions;
    const elite_candidates: u32 = 8;
    const elite_count: u32 = 4;
    const elite_scores: u32 = warm_spreads + plan_states * plan_horizon * plan_actions;
    const elite_numbers: u32 = elite_scores + plan_states * elite_candidates;
    const elite_weights: u32 = elite_numbers + plan_states * elite_count;
    const gather_features: u32 = 4;
    const gather_references: u32 = 3;
    const gather_actions: u32 = 2;
    const gather_steps: u32 = 3;
    const gather_rows: u32 = 4;
    const gather_rows_per_state: u32 = 2;
    const gather_width: u32 = 2 * gather_features + gather_references + gather_actions;
    const gather_table_rows: u32 = 6;
    const gather_table: u32 = elite_weights + plan_states * elite_count;
    const gather_normaliser: u32 = gather_table + gather_table_rows * (gather_features + gather_references);
    const gather_inputs: u32 = gather_normaliser + 2 * gather_features;
    const gather_blocks: u32 = gather_inputs + plan_states * (gather_features + 2);
    const gather_goals: u32 = gather_blocks + (gather_steps + 1) * gather_rows * gather_width;
    const acts_end: u32 = gather_goals + gather_steps * gather_rows * gather_features;
    const output_gradient: u32 = 0;
    const scaled_gradient: u32 = block;
    const linear_gradient: u32 = 2 * block;
    const input_gradient: u32 = 3 * block;
    const logit_gradient: u32 = input_gradient + rows * inputs;
    const flow_velocity_gradient: u32 = logit_gradient + two_hot_rows * bins;
    const dacts_end: u32 = flow_velocity_gradient + flow_rows * flow_actions;

    /// A normed layer forward and backward, its activation's kernels named: Mish's or SimNorm's.
    fn normedLayerSteps(
        comptime forward_kernel: []const u8,
        comptime backward_kernel: []const u8,
        comptime activation_threads: u32,
    ) [9]KitStep {
        const steps = [9]KitStep{
            .{
                .kernel = "dense_fwd",
                .params = .{
                    .rows = rows,
                    .in_dim = inputs,
                    .out_dim = outputs,
                    .act = @backingInt(zn_mlp.Act.linear),
                    .x_off = input,
                    .y_off = linear,
                    .w_off = 0,
                },
                .threads = block,
            },
            .{
                .kernel = "norm_fwd",
                .params = .{
                    .rows = rows,
                    .out_dim = outputs,
                    .x_off = linear,
                    .w_off = gains,
                    .z_off = normalised,
                    .y_off = scaled,
                    .l_off = inverse_spreads,
                },
                .threads = rows,
            },
            .{
                .kernel = forward_kernel,
                .params = .{
                    .rows = rows,
                    .out_dim = outputs,
                    .x_off = scaled,
                    .y_off = output,
                    .simnorm_group = group,
                },
                .threads = activation_threads,
            },
            .{
                .kernel = "mse_bwd",
                .params = .{
                    .rows = rows,
                    .out_dim = outputs,
                    .y_off = output,
                    .t_off = targets,
                    .dy_off = output_gradient,
                },
                .threads = block,
            },
            .{
                .kernel = backward_kernel,
                .params = .{
                    .rows = rows,
                    .out_dim = outputs,
                    .x_off = scaled,
                    .y_off = output,
                    .dy_off = output_gradient,
                    .dx_off = scaled_gradient,
                    .simnorm_group = group,
                },
                .threads = activation_threads,
            },
            .{
                .kernel = "norm_params_bwd",
                .params = .{
                    .rows = rows,
                    .out_dim = outputs,
                    .dy_off = scaled_gradient,
                    .z_off = normalised,
                    .w_off = gains,
                },
                .threads = 2 * outputs,
            },
            .{
                .kernel = "norm_bwd",
                .params = .{
                    .rows = rows,
                    .out_dim = outputs,
                    .dy_off = scaled_gradient,
                    .w_off = gains,
                    .z_off = normalised,
                    .l_off = inverse_spreads,
                    .dx_off = linear_gradient,
                },
                .threads = rows,
            },
            .{
                .kernel = "dense_bwd_w",
                .params = .{
                    .rows = rows,
                    .in_dim = inputs,
                    .out_dim = outputs,
                    .x_off = input,
                    .dy_off = linear_gradient,
                    .w_off = 0,
                },
                .threads = inputs * outputs + outputs,
            },
            .{
                .kernel = "dense_bwd_x",
                .params = .{
                    .rows = rows,
                    .in_dim = inputs,
                    .out_dim = outputs,
                    .dy_off = linear_gradient,
                    .w_off = 0,
                    .dx_off = input_gradient,
                },
                .threads = rows * inputs,
            },
        };
        return steps;
    }

    /// The two-hot head's dispatches (BMPC's bins: symlog, [-10, 10]), the mean's divisor its rows.
    fn twoHotStep(
        comptime kernel: []const u8,
        comptime y_off: u32,
        comptime dy_off: u32,
    ) KitStep {
        const params: zn_mlp.Params = .{
            .rows = two_hot_rows,
            .out_dim = bins,
            .x_off = logits,
            .t_off = two_hot_targets,
            .y_off = y_off,
            .dy_off = dy_off,
            .twohot_divisor = two_hot_rows,
        };
        return .{ .kernel = kernel, .params = params, .threads = two_hot_rows };
    }

    /// The sequences, run in this order on each pipe: the Mish layer, then the SimNorm layer (whose dispatches
    /// overwrite the first's values - each comparison is of what its sequence leaves), then the two-hot head.
    const simnorm_groups: u32 = rows * (outputs / group);
    const mish_layer_steps: [9]KitStep = normedLayerSteps("mish_fwd", "mish_bwd", block);
    const simnorm_layer_steps: [9]KitStep = normedLayerSteps("simnorm_fwd", "simnorm_bwd", simnorm_groups);
    const two_hot_steps = [3]KitStep{
        twoHotStep("twohot_fwd", losses, 0),
        twoHotStep("twohot_bwd", 0, logit_gradient),
        twoHotStep("twohot_decode", values, 0),
    };

    /// The flow policy's kernels in the order a rollout's turn and a training step run them: the training times drawn
    /// and the base noise written (both hashed, so the device's integer hashing is compared with the twin's), the
    /// condition copied into the next rows, each row's time features at its own time, its point on the straight path
    /// and the path's velocity, one Euler step into the next rows, FlowDPG's gradient at the velocity, and that
    /// gradient carried back into acts.
    const flow_steps = [8]KitStep{
        .{
            .kernel = "hashed_uniforms",
            .params = .{
                .rows = flow_rows,
                .y_off = flow_times,
                .lat_seed = 55,
            },
            .threads = flow_rows,
        },
        .{
            .kernel = "hashed_noise",
            .params = .{
                .rows = flow_rows,
                .count = flow_actions,
                .y_off = flow_wide,
                .stride = flow_width,
                .col = flow_point_column,
                .lat_sigma = 0.3,
                .lat_seed = 77,
            },
            .threads = flow_rows * flow_actions,
        },
        .{
            .kernel = "copy_columns",
            .params = .{
                .rows = flow_rows,
                .count = flow_point_column,
                .x_off = flow_wide,
                .stride = flow_width,
                .col = 0,
                .y_off = flow_next,
                .destination_stride = flow_width,
                .destination_column = 0,
            },
            .threads = flow_rows * flow_point_column,
        },
        .{
            .kernel = "flow_time_features",
            .params = .{
                .rows = flow_rows,
                .y_off = flow_wide,
                .stride = flow_width,
                .col = flow_time_column,
                .t_off = flow_times,
                .flow_time_per_row = 1,
                .flow_frequencies = 3,
            },
            .threads = flow_rows * 3,
        },
        .{
            .kernel = "flow_path_points",
            .params = .{
                .rows = flow_rows,
                .count = flow_actions,
                .x_off = flow_action_values,
                .z_off = flow_noise,
                .t_off = flow_times,
                .y_off = flow_wide,
                .stride = flow_width,
                .col = flow_point_column,
                .u_off = flow_path_velocities,
            },
            .threads = flow_rows * flow_actions,
        },
        .{
            .kernel = "flow_euler_step",
            .params = .{
                .rows = flow_rows,
                .count = flow_actions,
                .x_off = flow_wide,
                .stride = flow_width,
                .col = flow_point_column,
                .z_off = flow_velocity,
                .y_off = flow_next,
                .flow_step = 0.25,
                .destination_stride = flow_width,
                .destination_column = flow_point_column,
            },
            .threads = flow_rows * flow_actions,
        },
        .{
            .kernel = "flow_dpg_bwd",
            .params = .{
                .rows = flow_rows,
                .count = flow_actions,
                .x_off = flow_velocity,
                .u_off = flow_path_velocities,
                .v_off = flow_cost_gradients,
                .t_off = flow_times,
                .dy_off = flow_velocity_gradient,
                .flow_step_share = 0.3,
                .flow_step_floor = 0.2,
                .flow_anchor = 0.5,
            },
            .threads = flow_rows,
        },
        .{
            .kernel = "copy_columns_from_gradients",
            .params = .{
                .rows = flow_rows,
                .count = flow_actions,
                .x_off = flow_velocity_gradient,
                .stride = flow_actions,
                .col = 0,
                .y_off = flow_next,
                .destination_stride = flow_width,
                .destination_column = flow_point_column,
            },
            .threads = flow_rows * flow_actions,
        },
    };

    /// The tracking planner's kernels: a warm start moving each warm plan forward two steps, the elites weighed
    /// relative to their own spread, and the planner's gather - whose table rows are integers carried as floats, the
    /// kind of arithmetic a device may round differently.
    const planner_steps = [3]KitStep{
        .{
            .kernel = "mppi_begin",
            .params = .{
                .rows = plan_states,
                .out_dim = plan_actions,
                .plan_horizon = plan_horizon,
                .mppi_max_spread = 1.5,
                .mppi_warm_shift = 2,
                .x_off = warm_flags,
                .t_off = warm_means,
                .u_off = warm_spreads,
            },
            .threads = plan_states * plan_actions,
        },
        .{
            .kernel = "mppi_elites",
            .params = .{
                .rows = plan_states,
                .plan_candidates = elite_candidates,
                .mppi_elites = elite_count,
                .mppi_temperature = 2,
                .mppi_temperature_mode = 1,
                .x_off = elite_scores,
                .y_off = elite_numbers,
                .z_off = elite_weights,
            },
            .threads = plan_states,
        },
        .{
            .kernel = "plan_gather",
            .params = .{
                .rows = gather_rows,
                .lat_features = gather_features,
                .lat_references = gather_references,
                .lat_actions = gather_actions,
                .lat_steps = gather_steps,
                .lat_lead = gather_features,
                .plan_candidates = gather_rows_per_state,
                .table_off = gather_table,
                .norm_off = gather_normaliser,
                .starts_off = gather_inputs,
                .blocks_off = gather_blocks,
                .goals_off = gather_goals,
            },
            .threads = gather_rows * (gather_steps + 1) * gather_width,
        },
    };

    /// The data both pipes start from: weights, inputs, gains and targets by formulas of their indices - spread
    /// enough that every kernel's arithmetic is exercised (a softmax far from uniform, gains away from 1) - and two-hot
    /// targets inside a pair of bins, on one, and past both ends.
    fn fillData(parameters: []f32, acts: []f32) void {
        @memset(parameters, 0);
        @memset(acts, 0);
        for (parameters[0..gains], 0..) |*value, index| {
            value.* = 0.4 * @sin(0.7 * float(index) + 0.3);
        }
        const gain_values: []f32 = parameters[gains..][0..outputs];
        const norm_bias_values: []f32 = parameters[gains + outputs ..][0..outputs];
        for (gain_values, norm_bias_values, 0..) |*gain, *norm_bias, feature| {
            gain.* = 0.5 + 0.1 * float(feature);
            norm_bias.* = 0.2 - 0.03 * float(feature);
        }
        for (acts[input..][0 .. rows * inputs], 0..) |*value, index| {
            value.* = 1.5 * @cos(0.9 * float(index));
        }
        for (acts[targets..][0..block], 0..) |*value, index| {
            value.* = 0.3 * @sin(float(index));
        }
        for (acts[logits..][0 .. two_hot_rows * bins], 0..) |*logit, index| {
            logit.* = 2.0 * @sin(0.37 * float(index)) + 0.5 * @cos(0.11 * float(index));
        }
        const target_values = [two_hot_rows]f32{ 0.5, -3.0, 0.0, 1.0e9, -1.0e9 };
        @memcpy(acts[two_hot_targets..][0..two_hot_rows], &target_values);
        // The flow's: a velocity, actions, noise, cost gradients by formulas, and times spread over [0, 1).
        const flow_packed: u32 = flow_rows * flow_actions;
        for (0..flow_packed) |index| {
            acts[flow_velocity + index] = 0.6 * @sin(0.8 * float(index) + 0.2);
            acts[flow_action_values + index] = 0.5 * @cos(0.6 * float(index));
            acts[flow_noise + index] = 0.9 * @sin(1.1 * float(index) + 0.4);
            acts[flow_cost_gradients + index] = 0.7 * @cos(0.5 * float(index) + 0.9);
        }
        const flow_time_values = [flow_rows]f32{ 0.1, 0.45, 0.8 };
        @memcpy(acts[flow_times..][0..flow_rows], &flow_time_values);
        // The planner's: one warm state and one cold, plans, scores and a reference table by formulas, a normaliser,
        // and each gathered state's start - its features, then its start row and its clip's last row, exact integers.
        acts[warm_flags] = 1;
        acts[warm_flags + 1] = 0;
        for (0..plan_states * plan_horizon * plan_actions) |index| {
            acts[warm_means + index] = 0.4 * @sin(0.9 * float(index) + 0.3);
        }
        for (0..plan_states * elite_candidates) |index| {
            acts[elite_scores + index] = -0.05 * (1.0 + @sin(1.7 * float(index)));
        }
        const table_floats: u32 = gather_table_rows * (gather_features + gather_references);
        for (0..table_floats) |index| {
            acts[gather_table + index] = @sin(0.37 * float(index) + 0.2);
        }
        for (0..gather_features) |column| {
            acts[gather_normaliser + column] = 0.1 * float(column);
            acts[gather_normaliser + gather_features + column] = 0.5 + 0.1 * float(column);
        }
        const start_rows = [plan_states]f32{ 1, 4 };
        for (0..plan_states) |state| {
            const inputs_at: usize = gather_inputs + state * (gather_features + 2);
            for (0..gather_features) |column| {
                acts[inputs_at + column] = 0.3 * float(state + 1) - 0.05 * float(column);
            }
            acts[inputs_at + gather_features] = start_rows[state];
            acts[inputs_at + gather_features + 1] = float(gather_table_rows - 1);
        }
    }
};

fn runKitSteps(pipe: *z.Compute(zn_mlp), comptime steps: []const KitStep) void {
    inline for (steps) |step| {
        pipe.params = step.params;
        pipe.run(step.kernel, step.threads);
    }
}

/// The largest difference between two runs of values, relative to the CPU twin's magnitude where it is above 1 - the
/// conformance sweep's measure. A value that is not finite on either side is no gap at all but a failure, and is
/// reported as an infinite one: `@max` returns its other operand when one is NaN, so a kernel writing NaN on the
/// device would otherwise pass as a gap of zero.
fn largestRelativeGap(device_values: []const f32, twin_values: []const f32) f32 {
    var largest: f32 = 0;
    for (device_values, twin_values) |device_value, twin_value| {
        const both_finite: bool = zm.isFinite(device_value) and zm.isFinite(twin_value);
        if (!both_finite) {
            return inf(f32);
        }
        const scale: f32 = @max(1.0, @abs(twin_value));
        largest = @max(largest, @abs(device_value - twin_value) / scale);
    }
    return largest;
}

/// The kit's buffers the check reads back.
const KitField = FieldEnum(zn_mlp.Buffers);

/// EfficientTDMPC's kernels of the kit on the device and on its CPU twin, from the same data, in the same order (this
/// file's head): every value each sequence leaves, compared. The two run the same Zig source, but the device's
/// transcendental functions are zimrmath's portable forms where the twin's are the host's, and its compiler may fuse
/// a multiply into an add - so the bar is a relative 1e-5, not equality. Returns the largest gap seen, or null when a
/// readback never came.
fn runKitKernels(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !?f32 {
    var on_device: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer on_device.deinit();
    var twin: z.Compute(zn_mlp) = .initCpu();
    defer twin.deinit();
    const parameters: []f32 = try gpa.alloc(f32, KitCheck.params_end);
    defer gpa.free(parameters);
    const acts: []f32 = try gpa.alloc(f32, KitCheck.acts_end);
    defer gpa.free(acts);
    KitCheck.fillData(parameters, acts);
    const pipes = [2]*z.Compute(zn_mlp){ &on_device, &twin };
    for (pipes) |pipe| {
        pipe.element_count = KitCheck.acts_end;
        pipe.upload(.params, parameters);
        pipe.upload(.acts, acts);
    }
    var largest_gap: f32 = 0;
    const sequences = [5][]const KitStep{
        &KitCheck.mish_layer_steps,
        &KitCheck.simnorm_layer_steps,
        &KitCheck.two_hot_steps,
        &KitCheck.flow_steps,
        &KitCheck.planner_steps,
    };
    const fields = [3]KitField{ .acts, .dacts, .grads };
    const field_ends = [3]u32{ KitCheck.acts_end, KitCheck.dacts_end, KitCheck.params_end };
    inline for (sequences) |sequence| {
        runKitSteps(&on_device, sequence);
        runKitSteps(&twin, sequence);
        inline for (fields, field_ends) |field, field_end| {
            const device_values: []const f32 = deviceReadback(zn_mlp, f32, &on_device, field) orelse return null;
            const twin_values: []const f32 = twin.readLatest(field) orelse return null;
            const gap: f32 = largestRelativeGap(device_values[0..field_end], twin_values[0..field_end]);
            largest_gap = @max(largest_gap, gap);
        }
    }
    return largest_gap;
}

const constant_index_spirv: []const u8 = @embedFile("constant_index_spv");

/// The constant-index kernel (`constant_index.zig`) run through the engine and read back: `values[2]` and
/// `grid[1][2]` hold what it wrote, every other element its zero - so each constant index reached the element it
/// names, at one level and at two.
fn runConstantIndex(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    const ConstantIndex: type = z.Compute(constant_index);
    var compute: ConstantIndex = try .initGpu(gpa, device, queue, &spirvEntries(constant_index, constant_index_spirv));
    defer compute.deinit();
    // Both fields read back whole: `readLatest` slices to the lesser of this count and a field's own length.
    compute.element_count = constant_index.config.max;
    const zero_values: [16]f32 = @splat(0);
    const zero_rows: [4][3]f32 = @splat(@splat(0));
    compute.upload(.values, &zero_values);
    compute.upload(.grid, &zero_rows);
    const one_thread: u32 = 1;
    compute.run("writeConstantElements", one_thread);
    const dispatched: u64 = compute.readGeneration().submitted;

    const deadline: ReadDeadline = .start();
    while (!deadline.hasPassed()) {
        const latest_values: ?[]const f32 = compute.readLatest(.values);
        const latest_rows: ?[]const [3]f32 = compute.readLatest(.grid);
        if (compute.readGeneration().mirrored < dispatched) {
            continue;
        }
        const values: []const f32 = latest_values orelse continue;
        const rows: []const [3]f32 = latest_rows orelse continue;
        for (values, 0..) |value, index| {
            const expected: f32 = if (index == 2) constant_index.value_written else 0;
            if (value != expected) {
                print("vk-host-test: values[{d}] came back {d}, expected {d}\n", .{ index, value, expected });
                return false;
            }
        }
        for (rows, 0..) |row, row_index| {
            for (row, 0..) |value, column_index| {
                const is_written: bool = row_index == 1 and column_index == 2;
                const expected: f32 = if (is_written) constant_index.grid_value_written else 0;
                if (value != expected) {
                    print("vk-host-test: grid[{d}][{d}] came back {d}, expected {d}\n", .{
                        row_index,
                        column_index,
                        value,
                        expected,
                    });
                    return false;
                }
            }
        }
        return true;
    }
    print("vk-host-test: the constant-index kernel's read never held its dispatch\n", .{});
    return false;
}

/// Runs one entry of a pipeline, then polls `readLatest(.out)` until the mirror holds that dispatch (`ReadDeadline`).
/// Null when it
/// never does.
fn runAndRead(
    comptime Kernel: type,
    pipeline: *z.Compute(Kernel),
    comptime entry: [:0]const u8,
    threads: u32,
) ?[]const f32 {
    pipeline.run(entry, threads);
    const dispatched: u64 = pipeline.readGeneration().submitted;
    const deadline: ReadDeadline = .start();
    while (!deadline.hasPassed()) {
        const latest: ?[]const f32 = pipeline.readLatest(.out);
        if (pipeline.readGeneration().mirrored < dispatched) {
            continue;
        }
        if (latest) |output| {
            return output;
        }
    }
    return null;
}

/// zimrnum's GPU sweep on the native host: the four pipelines set up as the `zimrnum_field` example sets them up -
/// the same inputs (`conf.Fixture`), the same parameters (`conf.binaryParams` and its siblings) - then every case of
/// the table run and judged as the example judges it: the worst difference over the case's own outputs against its
/// bar (`conf.barFor`). Returns how many cases failed.
fn runZimrnumSweep(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !u32 {
    var fixture: conf.Fixture = try .build(gpa);
    defer fixture.deinit(gpa);
    var binary: z.Compute(zn_binary) = try .initGpu(gpa, device, queue, &spirvEntries(zn_binary, zn_binary_spirv));
    defer binary.deinit();
    var matmul: z.Compute(zn_matmul) = try .initGpu(gpa, device, queue, &spirvEntries(zn_matmul, zn_matmul_spirv));
    defer matmul.deinit();
    var unary: z.Compute(zn_unary) = try .initGpu(gpa, device, queue, &spirvEntries(zn_unary, zn_unary_spirv));
    defer unary.deinit();
    var rl_binary: z.Compute(zrl_binary) = try .initGpu(
        gpa,
        device,
        queue,
        &spirvEntries(zrl_binary, zrl_binary_spirv),
    );
    defer rl_binary.deinit();
    binary.element_count = conf.count;
    matmul.element_count = conf.count;
    unary.element_count = conf.count;
    rl_binary.element_count = conf.count;
    binary.params = conf.binaryParams(zn_binary.Params);
    matmul.params = conf.matmulParams(zn_matmul.Params);
    unary.params = conf.unaryParams(zn_unary.Params);
    rl_binary.params = conf.rlBinaryParams(zrl_binary.Params);
    binary.upload(.a, fixture.a);
    binary.upload(.b, fixture.b);
    binary.upload(.c, fixture.mask);
    matmul.upload(.a, fixture.a);
    matmul.upload(.b, fixture.b);
    rl_binary.upload(.a, fixture.a);
    rl_binary.upload(.b, fixture.b);

    var failures: u32 = 0;
    // The cases unroll at compile time, since `Compute.run` takes its entry's name as a compile-time value; unrolling
    // all of them takes more backward branches than the compiler's default allowance of 1000.
    @setEvalBranchQuota(20_000);
    inline for (conf.cases, 0..) |case, case_index| {
        if (case.kind == .unary) {
            unary.upload(.x, fixture.inputFor(case));
        }
        const read: ?[]const f32 = switch (case.kind) {
            .binary => runAndRead(zn_binary, &binary, case.entry, case.threads),
            .matmul => runAndRead(zn_matmul, &matmul, case.entry, case.threads),
            .unary => runAndRead(zn_unary, &unary, case.entry, case.threads),
            .rl_binary => runAndRead(zrl_binary, &rl_binary, case.entry, case.threads),
        };
        if (read) |output| {
            const judged: usize = @min(output.len, case.out_len);
            const reference: []const f32 = fixture.references[case_index][0..judged];
            const comparison: conf.Comparison = conf.compare(output[0..judged], reference);
            const bar: f32 = conf.barFor(case, comparison.peak);
            if (comparison.worst > bar or judged != case.out_len) {
                print("vk-host-test: zimrnum {s}: worst {e}, bar {e}, {d} of {d} outputs\n", .{
                    case.label,
                    comparison.worst,
                    bar,
                    judged,
                    case.out_len,
                });
                failures += 1;
            }
        } else {
            print("vk-host-test: zimrnum {s}: the read never held the dispatch\n", .{case.label});
            failures += 1;
        }
    }
    return failures;
}

/// The orders in which an app may let go of a bind group and the view and sampler it holds.
const ReleaseOrder = enum { handles_first, group_first };

/// Releases a texture view and a sampler while a bind group still holds them, then the group - and the other way
/// round. WebGPU keeps the view and the sampler alive while a group holds them, however early the app releases its
/// handles; the host counts the group's holds and destroys each once its handle and its last hold are both gone.
/// Checked by the validation layer: an object destroyed twice is reported at once, and one never destroyed is
/// reported when the device is.
fn releaseWhileHeld(device: wgpu.DeviceHandle) void {
    const texture: wgpu.TextureHandle = wgpu.createTexture(device, .{
        .width = 8,
        .height = 8,
        .format = .rgba8_unorm,
        .usage = .{ .texture_binding = true },
        .label = "held texture",
    });
    defer wgpu.destroyTexture(texture);
    const fragment_stage: u32 = @bitCast(wgpu.ShaderStage{ .fragment = true });
    const texture_kind: u32 = @backingInt(wgpu.BindingKind.texture);
    const sampler_kind: u32 = @backingInt(wgpu.BindingKind.sampler);
    const view_2d: u32 = @backingInt(wgpu.TextureViewDimension.d2);
    // A sampler entry has no view; the field is read all the same, so it holds a valid value.
    const no_view: u32 = @backingInt(wgpu.TextureViewDimension.d1);
    // Binding 0 a sampled texture, binding 1 a filtering sampler (the extra word 0 for both).
    var layout_words: [1 + 2 * 5]u32 = undefined;
    layout_words[0] = 2;
    layout_words[1..6].* = .{ 0, fragment_stage, texture_kind, 0, view_2d };
    layout_words[6..11].* = .{ 1, fragment_stage, sampler_kind, 0, no_view };
    var layout_blob: [4 * layout_words.len]u8 = undefined;
    writeWords(&layout_blob, &layout_words);
    const layout: wgpu.BindGroupLayoutHandle = wgpu.createBindGroupLayout(device, &layout_blob, "held layout");
    defer wgpu.destroyBindGroupLayout(layout);

    for ([_]ReleaseOrder{ .handles_first, .group_first }) |order| {
        const view: wgpu.TextureViewHandle = wgpu.createTextureView(texture);
        const sampler: wgpu.SamplerHandle = wgpu.createSampler(device, .{});
        var group_words: [1 + 2 * 7]u32 = @splat(0);
        group_words[0] = 2;
        group_words[1..4].* = .{ 0, @backingInt(wgpu.BindingResource.texture_view), @backingInt(view) };
        group_words[8..11].* = .{ 1, @backingInt(wgpu.BindingResource.sampler), @backingInt(sampler) };
        var group_blob: [4 * group_words.len]u8 = undefined;
        writeWords(&group_blob, &group_words);
        const group: wgpu.BindGroupHandle = wgpu.createBindGroup(device, layout, &group_blob, "held group");
        switch (order) {
            .handles_first => {
                wgpu.destroyTextureView(view);
                wgpu.destroySampler(sampler);
                wgpu.destroyBindGroup(group);
            },
            .group_first => {
                wgpu.destroyBindGroup(group);
                wgpu.destroyTextureView(view);
                wgpu.destroySampler(sampler);
            },
        }
    }
}

/// `sort_min`'s SPIR-V, built as the native host builds every kernel: among its entries, the counting sort's four.
const sort_min_spirv: []const u8 = @embedFile("sort_min_spv");

/// The counting sort's entries, in the order they run.
const sort_entries = [_][:0]const u8{ "clearGrid", "countGrid", "prefixSum", "scatter" };

/// The cell a position falls in, by the kernel's own rule (`sort_min.cellOf`): its column and its row, each clamped
/// to the grid's edge.
fn sortCellOf(position: [2]f32) u32 {
    const last_column: f32 = @floatFromInt(sort_min.n_cols - 1);
    const last_row: f32 = @floatFromInt(sort_min.n_rows - 1);
    const column: u32 = @trunc(clamp(@floor(position[0] / sort_min.cell_size), 0.0, last_column));
    const row: u32 = @trunc(clamp(@floor(position[1] / sort_min.cell_size), 0.0, last_row));
    return column + row * sort_min.n_cols;
}

/// Whether one position sorts before another: by x, then by y.
fn positionLessThan(_: void, a: [2]f32, b: [2]f32) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

/// Sorts `sort_min.n_particles` particles into the grid's cells on the GPU, in the four dispatches of a counting sort
/// in one pass: clear each cell's count; count each cell's particles (`atomicAdd`); turn the counts into each cell's
/// first slot (`prefixSum`); move each particle into a slot of its cell (`scatter` - `atomicAdd` again, its returned
/// value the slot). The result is checked against the same sort on the CPU: each cell's count, each cell's first
/// slot, every particle inside its cell's range, and the sorted particles a permutation of the written ones. Several
/// particles share most cells, so a lost atomic update would show as a wrong count or two particles in one slot.
fn runCountingSort(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) bool {
    const particle_count: u32 = sort_min.n_particles;
    const cell_count: u32 = sort_min.n_cells;
    const bindings: KernelBindings(sort_min) = .create(device);
    defer bindings.destroy();
    const module: wgpu.ShaderModuleHandle = wgpu.createShaderModuleWgsl(device, sort_min_spirv, "sort_min");
    defer wgpu.destroyShaderModule(module);
    var pipelines: [sort_entries.len]wgpu.ComputePipelineHandle = undefined;
    for (sort_entries, &pipelines) |entry, *pipeline| {
        pipeline.* = wgpu.createComputePipeline(device, bindings.pipeline_layout, module, entry, entry);
    }
    defer for (pipelines) |pipeline| {
        wgpu.destroyComputePipeline(pipeline);
    };

    // The particles, spread over the grid's 800 by 400 units in a fixed scatter: two to a cell on average.
    var positions: [sort_min.n_particles][2]f32 = undefined;
    for (&positions, 0..) |*position, index| {
        const step: f32 = @floatFromInt(index);
        position.* = .{ @mod(step * 137.0, 800.0), @mod(step * 59.0, 400.0) };
    }
    const params: sort_min.Params = .{
        .count = particle_count,
        .n_cols = sort_min.n_cols,
        .n_rows = sort_min.n_rows,
        .h = sort_min.cell_size,
    };
    wgpu.queueWriteBuffer(queue, bindings.params_buffer, 0, asBytes(&params));
    wgpu.queueWriteBuffer(queue, bindings.buffer(.pos), 0, sliceAsBytes(&positions));

    // The four dispatches, in one pass: each must see what the ones before it wrote.
    const invocations = [sort_entries.len]u32{ cell_count, particle_count, 1, particle_count };
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    const pass: wgpu.ComputePassEncoderHandle = wgpu.compute_pass.begin(encoder);
    wgpu.compute_pass.setBindGroup(pass, 0, bindings.group);
    for (pipelines, invocations) |pipeline, invocation_count| {
        wgpu.compute_pass.setPipeline(pass, pipeline);
        const workgroup_count: u32 = workgroupsFor(invocation_count, sort_min.config.workgroup);
        wgpu.compute_pass.dispatchWorkgroups(pass, .{ .x = workgroup_count });
    }
    wgpu.compute_pass.end(pass);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));

    var counts: [sort_min.n_cells]u32 = @splat(0);
    var starts: [sort_min.n_cells + 1]u32 = @splat(0);
    var sorted: [sort_min.n_particles][2]f32 = undefined;
    const read_all: bool = readBufferInto(device, queue, bindings.buffer(.counts), sliceAsBytes(&counts)) and
        readBufferInto(device, queue, bindings.buffer(.starts), sliceAsBytes(&starts)) and
        readBufferInto(device, queue, bindings.buffer(.pos2), sliceAsBytes(&sorted));
    if (!read_all) {
        return false;
    }

    // The same sort's counts and first slots, on the CPU.
    var expected_counts: [sort_min.n_cells]u32 = @splat(0);
    for (positions) |position| {
        expected_counts[sortCellOf(position)] += 1;
    }
    var expected_starts: [sort_min.n_cells + 1]u32 = undefined;
    var running_total: u32 = 0;
    for (expected_counts, 0..) |count, cell| {
        expected_starts[cell] = running_total;
        running_total += count;
    }
    expected_starts[cell_count] = running_total;
    if (!eql(u32, &counts, &expected_counts)) {
        print("vk-host-test: the sort's cell counts differ from the CPU's\n", .{});
        return false;
    }
    if (!eql(u32, &starts, &expected_starts)) {
        print("vk-host-test: the sort's first slots differ from the CPU's\n", .{});
        return false;
    }
    // Every particle inside its cell's range; their order within a cell is the atomics', so it is not compared.
    for (0..cell_count) |cell| {
        for (sorted[starts[cell]..starts[cell + 1]]) |position| {
            const actual_cell: u32 = sortCellOf(position);
            if (actual_cell != cell) {
                print("vk-host-test: a particle of cell {d} sorted into cell {d}'s range\n", .{ actual_cell, cell });
                return false;
            }
        }
    }
    // And none lost, none twice: the sorted particles are the written ones, rearranged.
    var written_in_order: [sort_min.n_particles][2]f32 = positions;
    sort([2]f32, &written_in_order, {}, positionLessThan);
    sort([2]f32, &sorted, {}, positionLessThan);
    for (written_in_order, sorted) |written, result| {
        if (written[0] != result[0] or written[1] != result[1]) {
            print("vk-host-test: the sorted particles are not the written ones rearranged\n", .{});
            return false;
        }
    }
    return true;
}

/// More rounds than two descriptor pool pages hold (512 sets each): if freed sets were never used again, the third
/// page would be created.
const churn_rounds: u32 = 1300;

/// Creates and destroys a bind group per round, with a buffer write and a submit between; returns whether the
/// host's descriptor pages and staging chunks stayed bounded.
fn churnBindGroups(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) bool {
    const buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = 256,
        .usage = .{ .uniform = true, .copy_dst = true },
        .label = "churn buffer",
    });
    // One uniform buffer at binding 0, seen by the vertex stage: count, then binding, visibility, kind, extra, view.
    var layout_blob: [24]u8 = undefined;
    writeWords(&layout_blob, &.{ 1, 0, 1, 0, 0, 0 });
    const layout: wgpu.BindGroupLayoutHandle = wgpu.createBindGroupLayout(device, &layout_blob, "churn layout");
    // The whole buffer at binding 0: count, binding, resource (0: buffer), handle, then a u64 offset and size.
    var group_blob: [32]u8 = @splat(0);
    writeWords(group_blob[0..16], &.{ 1, 0, 0, @backingInt(buffer) });
    const payload: [64]u8 = @splat(7);
    for (0..churn_rounds) |_| {
        const group: wgpu.BindGroupHandle = wgpu.createBindGroup(device, layout, &group_blob, "churn group");
        wgpu.queueWriteBuffer(queue, buffer, 0, &payload);
        wgpu.destroyBindGroup(group);
        const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
        wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    }
    const statistics: vulkan_host.Statistics = vulkan_host.statistics();
    print("vk-host-test: after {d} rounds - {d} descriptor pages, {d} staging chunks, {d} destroys waiting\n", .{
        churn_rounds,
        statistics.descriptor_pages,
        statistics.staging_chunks,
        statistics.waiting_destroys,
    });
    wgpu.destroyBindGroupLayout(layout);
    wgpu.destroyBuffer(buffer);
    // One page holds every live set; a second may appear while freed sets wait for the GPU. The staging budget bounds
    // the chunks however far ahead of the GPU the rounds run.
    return statistics.descriptor_pages <= 2 and statistics.staging_chunks <= vulkan_host.staging_chunk_budget;
}

/// Larger than a staging chunk (4 MiB), so each write needs a dedicated chunk.
const large_write_bytes: usize = 6 << 20;
const large_write_rounds: u32 = 24;

/// Writes `large_write_bytes` into a buffer and submits, round after round; returns whether the staging chunks stayed
/// within the budget plus one - the budget's standard chunks, and one large chunk used again every round.
fn churnLargeWrites(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) !bool {
    const payload: []u8 = try std.heap.page_allocator.alloc(u8, large_write_bytes);
    defer std.heap.page_allocator.free(payload);
    @memset(payload, 3);
    const buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = large_write_bytes,
        .usage = .{ .storage = true, .copy_dst = true },
        .label = "large write buffer",
    });
    for (0..large_write_rounds) |_| {
        wgpu.queueWriteBuffer(queue, buffer, 0, payload);
        const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
        wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    }
    const statistics: vulkan_host.Statistics = vulkan_host.statistics();
    print("vk-host-test: after {d} writes of {d} MiB - {d} staging chunks\n", .{
        large_write_rounds,
        large_write_bytes >> 20,
        statistics.staging_chunks,
    });
    wgpu.destroyBuffer(buffer);
    return statistics.staging_chunks <= vulkan_host.staging_chunk_budget + 1;
}

/// Copies the screen's texture into a buffer and reads it back: every texel must hold `expected`.
fn screenReadsAs(
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    texture: wgpu.TextureHandle,
    expected: [4]u8,
) bool {
    const buffer_size: u32 = (screen_height - 1) * copy_row_pitch + screen_width * expected.len;
    const buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = buffer_size,
        .usage = .{ .copy_src = true, .copy_dst = true },
        .label = "screen read",
    });
    defer wgpu.destroyBuffer(buffer);
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    wgpu.copyTextureToBuffer(encoder, texture, buffer, copy_row_pitch, screen_width, screen_height);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    var bytes: [(screen_height - 1) * copy_row_pitch + screen_width * 4]u8 = @splat(0xaa);
    if (!readBufferInto(device, queue, buffer, &bytes)) {
        return false;
    }
    for (0..screen_height) |row| {
        for (0..screen_width) |column| {
            const at: usize = row * copy_row_pitch + column * expected.len;
            if (!eql(u8, bytes[at..][0..expected.len], &expected)) {
                print("vk-host-test: screen texel ({d}, {d}) came back {any}\n", .{ column, row, bytes[at..][0..4] });
                return false;
            }
        }
    }
    return true;
}

/// The headless screen, driven as the engine drives a window's surface (see the `screen` check above).
fn drawOnScreen(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) bool {
    const surface: wgpu.SurfaceHandle = wgpu.getSurface();
    const size: wgpu.SurfaceSize = wgpu.getSurfaceSize(surface);
    const is_size_given: bool = size.width == screen_width and size.height == screen_height;
    if (!is_size_given) {
        print("vk-host-test: the screen measures {d}x{d}\n", .{ size.width, size.height });
        return false;
    }
    if (wgpu.getSurfaceFormat(surface) != .rgba8_unorm) {
        print("vk-host-test: the screen's format is not rgba8_unorm\n", .{});
        return false;
    }
    const texture: wgpu.TextureHandle = @fromBackingInt(vulkan_host.headlessScreenTexture());
    // A frame drawn: one pass clearing the current texture to an exact color, then the present.
    const drawn_view: wgpu.TextureViewHandle = wgpu.getCurrentTextureView(surface);
    const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
    const pass: wgpu.RenderPassEncoderHandle = wgpu.render_pass.begin(.{
        .encoder = encoder,
        .color_view = drawn_view,
        .clear = .{ .r = 0.2, .g = 0.4, .b = 0.8, .a = 1.0 },
    });
    wgpu.render_pass.end(pass);
    wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    wgpu.surfacePresent(surface);
    if (!screenReadsAs(device, queue, texture, copy_expected)) {
        return false;
    }
    // The next frame, before anything draws: zeros.
    _ = wgpu.getCurrentTextureView(surface);
    const is_cleared: bool = screenReadsAs(device, queue, texture, .{ 0, 0, 0, 0 });
    wgpu.surfacePresent(surface);
    return is_cleared;
}

/// THE DEVICE's COVERAGE ACROSS THE TESTS: every robotgpu dispatch any test sends to the GPU, added up here. The one
/// piece of state the tests share - tests can share nothing else - and Zig runs a file's tests in the order they are
/// declared, so the last test, the report, sees the whole run.
// lint:off module-var: the one state the tests share - test blocks can share nothing else - for the coverage report
var tests_device_coverage: DeviceCoverage = .{};

/// THE FLOOR CHECK's SIZE: by default sized for llvmpipe, a GPU emulated on the CPU - at Geno's 64 worlds it took three
/// quarters of the test's six minutes - and at full size with `-Dlong-checks=true`. Fewer worlds, not fewer steps: a
/// lying world starts overlapping the floor, and its contacts need the 100 steps to push it within the depth bar (after
/// 25 it was still 3.5 cm in); each world's dynamics are its own, and the worlds alternate standing and lying, so 8
/// hold both and meet the same bars.
const FloorSize = struct {
    world_count: u32,
    step_count: u32,
};

fn floorSize() FloorSize {
    const world_count: u32 = if (test_options.long_checks) 64 else 8;
    const size: FloorSize = .{ .world_count = world_count, .step_count = 100 };
    return size;
}

/// Geno's worlds on the floor over their steps. The bars, from lavapipe's 0.0085% and 0.5 mm with room for other GPUs'
/// rounding: the energies may differ by a little as the trajectories drift; a floor that let a geom sink, or a number
/// that left the finite, would not; and rows of the floor's contacts were made, or the check would pass on a floor
/// nothing touched.
fn floorStepsHold(floor_steps: FloorStepsOutcome) bool {
    const energy_within_bar: bool = floor_steps.largest_energy_gap <= 0.01;
    const device_held_by_floor: bool = floor_steps.deepest_device_penetration <= 0.02;
    const twin_held_by_floor: bool = floor_steps.deepest_twin_penetration <= 0.02;
    const floor_was_touched: bool = floor_steps.first_step_contact_rows > 0;
    const held: bool = device_held_by_floor and twin_held_by_floor;
    return energy_within_bar and held and floor_steps.all_finite and floor_was_touched;
}

/// The humanoid's worlds on their joint limits over their steps. The bars, from lavapipe's 0.0104% and 0 rad with room
/// for other GPUs' rounding: trajectories drift apart, so the energy may differ by a little; a limit that let a joint
/// stay past its end would not.
fn limitStepsHold(limit_steps: LimitStepsOutcome) bool {
    const energy_within_bar: bool = limit_steps.largest_energy_gap <= 0.01;
    const device_limits_held: bool = limit_steps.deepest_device_violation <= 0.01;
    const twin_limits_held: bool = limit_steps.deepest_twin_violation <= 0.01;
    return energy_within_bar and device_limits_held and twin_limits_held;
}

/// The constraint program on the device against the twin, at one inertia: the rows' integers equal, and every array
/// within its bar in epsilons (`robotgpu_host.constraint_array_bars`). A miss is named, with its numbers.
fn constraintsHold(constraints: robotgpu_host.ConstraintVerdict) bool {
    var holds: bool = true;
    if (!constraints.integers_agree) {
        print("vk-host-test: constraints: the rows' integers are not the twin's - a world's row count, a row's " ++
            "candidate, its Jacobian's dofs or their count\n", .{});
        holds = false;
    }
    inline for (robotgpu_host.constraint_array_bars, 0..) |array_bar, index| {
        const gap_epsilons: f32 = constraints.gaps_epsilons[index];
        // Written so a gap that is not a number misses its bar too.
        const within_its_bar: bool = gap_epsilons <= array_bar.bar_epsilons;
        if (!within_its_bar) {
            print("vk-host-test: constraints: {s} is {d:.1} epsilons from the twin's, its bar {d:.0}\n", .{
                array_bar.name,
                gap_epsilons,
                array_bar.bar_epsilons,
            });
            holds = false;
        }
    }
    return holds;
}

/// THE CONSTRAINT CHECK's MEASURES, PRINTED: every array's gap beside its bar, how many rows were compared, and
/// Newton's rounds on each side. A run on another GPU is read for these, as the tracking check's gaps are.
fn reportConstraintGaps(constraints: robotgpu_host.ConstraintVerdict) void {
    inline for (robotgpu_host.constraint_array_bars, 0..) |array_bar, index| {
        print("vk-host-test: robotgpu constraints: {s} {d:.2} epsilons from the twin (bar {d:.0})\n", .{
            array_bar.name,
            constraints.gaps_epsilons[index],
            array_bar.bar_epsilons,
        });
    }
    const integers: []const u8 = if (constraints.integers_agree) "the twin's" else "NOT the twin's";
    print("vk-host-test: robotgpu constraints: {d} rows compared, their integers {s}; Newton's rounds {d} on the " ++
        "device and {d} on the twin, differing in {d} worlds by at most {d}\n", .{
        constraints.rows_compared,
        integers,
        constraints.device_rounds,
        constraints.twin_rounds,
        constraints.worlds_rounds_differ,
        constraints.largest_rounds_difference,
    });
}

/// One driven step of Geno's worlds: the floor made contacts to compare, and the device's step is the twin's within
/// the step's bars (`StepVerdict.agrees`).
fn oneStepHolds(one_step: SteppedOutcome) bool {
    return one_step.floor_contacts > 0 and one_step.verdict.agrees();
}

/// A DECISION's VERDICT judges what a decision adds to the steps it takes. Measured on lavapipe: its own arithmetic
/// - the filter's applied actions 0 epsilons from the twin's, the servo's targets 1 (a ball's target turned through
/// the device's own sine and cosine) - and the poses it leaves 79.6; its last physics step's velocities up to 977
/// and accelerations up to 8574. A 20 Hz servo multiplies a target's last-bit difference by its stiffness, omega^2
/// about 16000, so over two physics steps the velocities and accelerations part further than one free step's bars
/// allow: those are reported, not judged, and the step's own arithmetic is judged by the one-step comparison above.
/// What is judged: the decision's own two arrays within a few epsilons, and the poses within the step's bar - a
/// decision composed wrongly (a dispatch missed, out of order, the wrong frame or action read) misses both by far.
fn decisionHolds(decision: DecisionOutcome) bool {
    const own_arrays_bar_epsilons: f32 = 16;
    const positions_bar: StepArrayGap = stepArrayGap(decision.verdict, "joint_positions");
    const actions_within: bool = decision.applied_actions_gap_epsilons <= own_arrays_bar_epsilons;
    const targets_within: bool = decision.servo_targets_gap_epsilons <= own_arrays_bar_epsilons;
    const poses_within: bool = positions_bar.gap_epsilons <= positions_bar.bar_epsilons;
    return actions_within and targets_within and poses_within;
}

/// THE TRACKING CHECK's GAPS, PRINTED as the probes print theirs - each float array's gap beside its bar. A run on
/// another GPU is read for these: its rounding is not lavapipe's, and the bars are refined from what it shows.
fn reportTrackingGaps(tracking: TrackingOutcome) void {
    inline for (tracking_float_arrays, 0..) |tracked, index| {
        std.debug.print("vk-host-test: robotgpu tracking: {s} {d:.2} epsilons from the twin (bar {d:.0})\n", .{
            tracked.name,
            tracking.float_gaps_epsilons[index],
            tracked.bar_epsilons,
        });
    }
}

/// WHAT A WHOLE DECISION COSTS ON THE DEVICE, PRINTED: the timed decisions' wall seconds as decisions a second and as
/// world-decisions a second - the worlds' count times that, the number a night's budget is made of - and the
/// decision's dispatches with the microseconds each one took on average: where a decision's cost is its dispatches'
/// own overhead, that number stays the same as the worlds grow.
fn reportTrackingThroughput(tracking: TrackingOutcome) void {
    const decisions: f64 = @floatFromInt(tracking.timed_decisions);
    const worlds: f64 = @floatFromInt(tracking.world_count);
    const dispatches: f64 = @floatFromInt(tracking.timed_dispatches);
    const decisions_per_second: f64 = decisions / tracking.timed_seconds;
    const world_decisions_per_second: f64 = worlds * decisions_per_second;
    const dispatches_per_decision: f64 = dispatches / decisions;
    const microseconds_per_dispatch: f64 = tracking.timed_seconds * 1_000_000.0 / dispatches;
    const flags_read: []const u8 = if (tracking.reads_flags_every_decision) "every decision" else "at the end";
    print("vk-host-test: robotgpu tracking throughput: {d} worlds, flags read {s} - {d} decisions of {d} physics " ++
        "steps in {d:.3} s: {d:.1} decisions a second, {d:.0} world-decisions a second; {d:.0} dispatches a " ++
        "decision, {d:.1} microseconds each\n", .{
        tracking.world_count,
        flags_read,
        tracking.timed_decisions,
        tracking.physics_steps,
        tracking.timed_seconds,
        decisions_per_second,
        world_decisions_per_second,
        dispatches_per_decision,
        microseconds_per_dispatch,
    });
    const floats_a_world: u32 = tracking.state_floats / tracking.world_count;
    const integers_a_world: u32 = tracking.state_integers / tracking.world_count;
    const constraint_floats_a_world: u32 = tracking.constraint_floats / tracking.world_count;
    print("vk-host-test:     a world holds {d} floats of state, {d} integers and {d} floats of constraint rows\n", .{
        floats_a_world,
        integers_a_world,
        constraint_floats_a_world,
    });
}

/// Whether `failure` is a simulator refused for its size: some arena of this build holds fewer worlds than were asked
/// for (`robotgpu.LayoutError`).
fn isArenaTooSmall(failure: anyerror) bool {
    return switch (failure) {
        error.WorldStateTooSmall,
        error.WorldIntegersTooSmall,
        error.ConstraintRowsTooSmall,
        error.ModelTablesTooSmall,
        error.ModelConstantsTooSmall,
        => true,
        else => false,
    };
}

/// WHETHER THE TRACKING CHECK HOLDS: every float array within its bar, every integer array the twin's exactly, and
/// the events the check is built around all there - an episode that ended and began again, an aftermath begun, a
/// return, worlds pushed during their episode. A miss is named, with its numbers.
fn trackingHolds(tracking: TrackingOutcome) bool {
    var holds: bool = true;
    inline for (tracking_float_arrays, 0..) |tracked, index| {
        const gap_epsilons: f32 = tracking.float_gaps_epsilons[index];
        // Written so a gap that is not a number misses its bar too.
        const within_its_bar: bool = gap_epsilons <= tracked.bar_epsilons;
        if (!within_its_bar) {
            std.debug.print("vk-host-test: tracking: {s} is {d:.1} epsilons from the twin's, its bar {d:.0}\n", .{
                tracked.name,
                gap_epsilons,
                tracked.bar_epsilons,
            });
            holds = false;
        }
    }
    inline for (tracking_integer_arrays, 0..) |array_name, index| {
        const differing: u32 = tracking.integer_differences[index];
        if (differing != 0) {
            std.debug.print("vk-host-test: tracking: {d} of {s}'s integers are not the twin's\n", .{
                differing,
                array_name,
            });
            holds = false;
        }
    }
    const an_episode_began_again: bool = tracking.episodes_restarted >= 1;
    const an_aftermath_began: bool = tracking.aftermaths_begun >= 1;
    const a_character_returned: bool = tracking.returns >= 1;
    const worlds_were_pushed: bool = tracking.worlds_pushed >= 1;
    const events_happened: bool = an_episode_began_again and an_aftermath_began and a_character_returned and
        worlds_were_pushed;
    if (!events_happened) {
        std.debug.print("vk-host-test: tracking: {d} restarts, {d} aftermaths, {d} returns, {d} pushes - " ++
            "each must happen at least once\n", .{
            tracking.episodes_restarted,
            tracking.aftermaths_begun,
            tracking.returns,
            tracking.worlds_pushed,
        });
        holds = false;
    }
    return holds;
}

/// Over many steps the trajectories part, so the device is held to a physical quantity: under gravity alone each
/// world's energy can change only by the integrator's own error, and the device's must differ from the twin's by
/// less than a hundredth of that. Over Geno's 64 worlds and 100 steps, the twin's drift is 7.08e-2 of the starting
/// energy, and the device's energy differs from the twin's by 2.15e-6 on lavapipe and 2.40e-6 on an RTX 5070.
fn hundredStepsHold(hundred_steps: SteppedOutcome) bool {
    const energy_bar: f32 = hundred_steps.largest_energy_drift / 100;
    return hundred_steps.largest_energy_gap < energy_bar;
}

/// The kit's learning kernels against their CPU twin: the largest relative gap within float rounding; none measured
/// is a failure.
fn kitMatches(kit_gap: ?f32) bool {
    const kit_gap_limit: f32 = 1.0e-5;
    const gap: f32 = kit_gap orelse return false;
    return gap <= kit_gap_limit;
}

/// The robotgpu probe's reductions: within the reordering's rounding of the twin, and exactly themselves run after
/// run (a device without subgroup arithmetic has no subgroup sum to judge).
fn probeHolds(probe: ProbeOutcome) bool {
    const probe_gap_limit: f32 = 1.0e-5;
    const subgroup_holds: bool = if (probe.subgroup_gap) |gap| gap <= probe_gap_limit else true;
    const workgroup_holds: bool = probe.workgroup_gap <= probe_gap_limit;
    return subgroup_holds and workgroup_holds and probe.repeats_exactly;
}

/// The workgroup Cholesky: a true factorisation (L L^T within float rounding of A), the twin's arithmetic and
/// zimrnum's within 128 epsilons, and the same bits every run.
fn factorisationHolds(factorisation: CholeskyOutcome) bool {
    const reconstructs: bool = factorisation.reconstruction_relative <= 1.0e-5;
    const near_twin: bool = factorisation.device_twin_epsilons <= 128;
    const twin_near_zimrnum: bool = factorisation.twin_zimrnum_epsilons <= 128;
    return reconstructs and near_twin and twin_near_zimrnum and factorisation.repeats_exactly;
}

/// The timings: four times the work takes longer than once, and a pipe without timings reports none.
fn timingsHold(timing: TimingOutcome) bool {
    const measured: bool = timing.one_times_microseconds > 0;
    const longer: bool = timing.four_times_microseconds > timing.one_times_microseconds;
    return measured and longer and timing.untimed_reports_none;
}

test "robotgpu clear_overflow clears every world's overflow word and writes nothing else" {
    const timer: TestTimer = .start("robotgpu clear_overflow");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runRobotgpuOverflow(testing.allocator, opened.device, opened.queue));
}

test "robotgpu large dispatch runs every index exactly once" {
    const timer: TestTimer = .start("robotgpu large dispatch");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runDispatchTally(testing.allocator, opened.device, opened.queue));
}

test "robotgpu ranged readback returns each range as it was uploaded" {
    const timer: TestTimer = .start("robotgpu ranged readback");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runRangedReadback(testing.allocator, opened.device, opened.queue));
}

test "robotgpu pushed dispatches each write their own pushed value" {
    const timer: TestTimer = .start("robotgpu pushed dispatches");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runPushedBatch(testing.allocator, opened.device, opened.queue));
}

test "a borrowing pipe's writes are in the owner's buffer" {
    const timer: TestTimer = .start("buffer lending");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runBorrowing(testing.allocator, opened.device, opened.queue));
}

test "robotgpu range requests are collected as they were when requested" {
    const timer: TestTimer = .start("robotgpu range requests");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runRangeRequests(testing.allocator, opened.device, opened.queue));
}

test "zimrnum's kernels give the CPU's answers on the device, every case" {
    const timer: TestTimer = .start("zimrnum's conformance sweep");
    defer timer.report();
    const opened: TestDevice = try .open();
    const failures: u32 = try runZimrnumSweep(testing.allocator, opened.device, opened.queue);
    try testing.expectEqual(@as(u32, 0), failures);
}

test "the kit's learning kernels match their CPU twin" {
    const timer: TestTimer = .start("the kit's learning kernels");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(kitMatches(try runKitKernels(testing.allocator, opened.device, opened.queue)));
}

test "robotgpu probe's reductions are the twin's within rounding, and repeat exactly" {
    const timer: TestTimer = .start("robotgpu probe");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(probeHolds(try runRobotgpuProbe(testing.allocator, opened.device, opened.queue)));
}

test "robotgpu workgroup Cholesky factorises, as the twin does, the same every run" {
    const timer: TestTimer = .start("robotgpu Cholesky");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(factorisationHolds(try runCholesky(testing.allocator, opened.device, opened.queue)));
}

test "robotgpu timings: four times the work takes longer, and an untimed pipe reports none" {
    const timer: TestTimer = .start("robotgpu timings");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(timingsHold(try runTimings(testing.allocator, opened.device, opened.queue)));
}

test "robotgpu on the floor: Geno's worlds standing and lying stay out of the floor, energy kept" {
    const timer: TestTimer = .start("robotgpu on the floor");
    defer timer.report();
    const opened: TestDevice = try .open();
    const size: FloorSize = floorSize();
    const outcome: FloorStepsOutcome = try runRobotgpuFloorSteps(
        testing.allocator,
        opened.device,
        opened.queue,
        &tests_device_coverage,
        size.world_count,
        size.step_count,
    );
    try expect(floorStepsHold(outcome));
}

test "robotgpu constrained steps: the humanoid's worlds on their limits stay within them, energy kept" {
    const timer: TestTimer = .start("robotgpu constrained steps");
    defer timer.report();
    const opened: TestDevice = try .open();
    const outcome: LimitStepsOutcome = try runRobotgpuLimitSteps(
        testing.allocator,
        opened.device,
        opened.queue,
        &tests_device_coverage,
        100,
    );
    try expect(limitStepsHold(outcome));
}

test "robotgpu's Sim: a step clears every world's overflow word" {
    const timer: TestTimer = .start("robotgpu Sim");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runRobotgpuSim(testing.allocator, opened.device, opened.queue, &tests_device_coverage));
}

test "robotgpu constraints at the exact inertia: the device's rows and solve are the twin's" {
    const timer: TestTimer = .start("robotgpu constraints at the exact inertia");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const verdict: robotgpu_host.ConstraintVerdict =
        try runRobotgpuConstraints(testing.allocator, opened.device, opened.queue, coverage, .exact);
    // At full size the run is on a real GPU, whose gaps the bars are refined from: printed, pass or not.
    if (test_options.long_checks) {
        reportConstraintGaps(verdict);
    }
    try expect(constraintsHold(verdict));
}

test "robotgpu constraints at the reference pose's inertia: the device's rows and solve are the twin's" {
    const timer: TestTimer = .start("robotgpu constraints at the reference pose's inertia");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const verdict: robotgpu_host.ConstraintVerdict =
        try runRobotgpuConstraints(testing.allocator, opened.device, opened.queue, coverage, .reference_pose);
    if (test_options.long_checks) {
        reportConstraintGaps(verdict);
    }
    try expect(constraintsHold(verdict));
}

test "robotgpu step: one driven step on the device is the twin's within the step's bars, the floor touched" {
    const timer: TestTimer = .start("robotgpu step");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const outcome: SteppedOutcome =
        try runRobotgpuSteps(testing.allocator, opened.device, opened.queue, coverage, 1, .driven);
    try expect(oneStepHolds(outcome));
}

test "robotgpu over 100 steps under gravity: the device's energy within a hundredth of the integrator's drift" {
    const timer: TestTimer = .start("robotgpu over 100 steps");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const outcome: SteppedOutcome =
        try runRobotgpuSteps(testing.allocator, opened.device, opened.queue, coverage, 100, .conservative);
    try expect(hundredStepsHold(outcome));
}

test "robotgpu decision: the filter, the clip's targets and two physics steps are the twin's" {
    const timer: TestTimer = .start("robotgpu decision");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const decision: DecisionOutcome = try runRobotgpuDecision(testing.allocator, opened.device, opened.queue, coverage);
    try expect(decisionHolds(decision));
}

test "robotgpu tracking: whole decisions on the device are the twin's - a loss, an end and a new start, pushes" {
    const timer: TestTimer = .start("robotgpu tracking");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const size: TrackingSize = .{ .world_count = 8, .timed_decisions = 0 };
    const tracking: TrackingOutcome = try runRobotgpuTracking(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
        size,
    );
    // At full size the run is on a real GPU, whose gaps the bars are refined from: printed, pass or not.
    if (test_options.long_checks) {
        reportTrackingGaps(tracking);
    }
    try expect(trackingHolds(tracking));
    try opened.expectNoNewValidationErrors();
}

test "robotgpu tracking throughput: what a whole decision costs on the device, by its worlds" {
    const timer: TestTimer = .start("robotgpu tracking throughput");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    // By default a few decisions of a few worlds, sized for lavapipe. At full size (`-Dlong-checks`, a real GPU) a
    // hundred decisions at each size: how the cost of a decision grows with its worlds says how far the GPU is from
    // full, and the same size with the flags read once says what waiting for the GPU at every decision costs.
    const full_sizes = [_]TrackingSize{
        .{ .world_count = 8, .timed_decisions = 100, .warmup_decisions = 30 },
        .{ .world_count = 32, .timed_decisions = 100, .warmup_decisions = 30 },
        .{ .world_count = 64, .timed_decisions = 100, .warmup_decisions = 30, .profiles_kernels = true },
        .{ .world_count = 64, .timed_decisions = 100, .warmup_decisions = 30, .reads_flags_every_decision = false },
        // Sizes only a build with larger arenas holds (`-Dhost-test-sizes`); the twin's comparison is the small sizes'.
        .{ .world_count = 256, .timed_decisions = 100, .warmup_decisions = 30, .compares_with_the_twin = false },
        .{
            .world_count = 1024,
            .timed_decisions = 100,
            .warmup_decisions = 30,
            .compares_with_the_twin = false,
            .profiles_kernels = true,
        },
        .{
            .world_count = 1024,
            .timed_decisions = 100,
            .warmup_decisions = 30,
            .compares_with_the_twin = false,
            .reads_flags_every_decision = false,
        },
    };
    const small_sizes = [_]TrackingSize{
        .{ .world_count = 8, .timed_decisions = 4, .warmup_decisions = 1 },
    };
    const sizes: []const TrackingSize = if (test_options.long_checks) &full_sizes else &small_sizes;
    // Every size is run and reported before any verdict: a miss at one size does not cost the others' numbers.
    var every_size_holds: bool = true;
    for (sizes) |size| {
        const tracking: TrackingOutcome = runRobotgpuTracking(
            testing.allocator,
            opened.device,
            opened.queue,
            coverage,
            size,
        ) catch |failure| {
            if (!isArenaTooSmall(failure)) {
                return failure;
            }
            const not_run: []const u8 = "vk-host-test: robotgpu tracking throughput: {d} worlds do not fit this " ++
                "build's arenas ({s}) - not run\n";
            print(not_run, .{ size.world_count, @errorName(failure) });
            continue;
        };
        reportTrackingThroughput(tracking);
        if (!size.compares_with_the_twin) {
            continue;
        }
        const holds: bool = trackingHolds(tracking);
        if (!holds) {
            every_size_holds = false;
        }
    }
    try expect(every_size_holds);
    try opened.expectNoNewValidationErrors();
}

test "a loop on a uniform workgroup value runs on the device as on the CPU" {
    const timer: TestTimer = .start("uniform loop");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runUniformLoop(testing.allocator, opened.device, opened.queue));
}

test "an arena as large as a binding comes back right at its start and its end" {
    const timer: TestTimer = .start("memory envelope");
    defer timer.report();
    const opened: TestDevice = try .open();
    const arena_bytes: ?u64 = try runMemoryEnvelope(testing.allocator, opened.device, opened.queue);
    try expect(arena_bytes != null);
}

test "robotgpu maths probe: every result within its bar of the twin" {
    const timer: TestTimer = .start("robotgpu maths probe");
    defer timer.report();
    const opened: TestDevice = try .open();
    var maths_gaps: [MathsCheck.results.len]f32 = undefined;
    try expect(try runProbeTable(testing.allocator, opened.device, opened.queue, MathsCheck.table, &maths_gaps));
    try expect(reportProbeResults("robotgpu maths probe", &MathsCheck.results, &maths_gaps));
}

test "robotgpu spatial probe: every result within its bar of the twin" {
    const timer: TestTimer = .start("robotgpu spatial probe");
    defer timer.report();
    const opened: TestDevice = try .open();
    var spatial_gaps: [SpatialCheck.results.len]f32 = undefined;
    try expect(try runProbeTable(testing.allocator, opened.device, opened.queue, SpatialCheck.table, &spatial_gaps));
    try expect(reportProbeResults("robotgpu spatial probe", &SpatialCheck.results, &spatial_gaps));
}

test "an element written by a constant index comes back as written" {
    const timer: TestTimer = .start("constant index");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runConstantIndex(testing.allocator, opened.device, opened.queue));
}

test "the counting sort on the device is the CPU's" {
    const timer: TestTimer = .start("counting sort");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(runCountingSort(opened.device, opened.queue));
}

test "a kernel's output is four times its input" {
    const timer: TestTimer = .start("a kernel");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(runKernel(opened.device, opened.queue));
}

test "a texture clears without a validation error" {
    const timer: TestTimer = .start("clear a texture");
    defer timer.report();
    const opened: TestDevice = try .open();
    clearTexture(opened.device, opened.queue);
    try opened.expectNoNewValidationErrors();
}

test "two render targets clear in one pass without a validation error" {
    const timer: TestTimer = .start("clear two targets");
    defer timer.report();
    const opened: TestDevice = try .open();
    clearTwoTargets(opened.device, opened.queue);
    try opened.expectNoNewValidationErrors();
}

test "a texture reads back as it was written" {
    const timer: TestTimer = .start("read back");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(readBack(opened.device, opened.queue));
    try opened.expectNoNewValidationErrors();
}

test "a texture copies to another unchanged" {
    const timer: TestTimer = .start("copy a texture");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(copyTexture(opened.device, opened.queue));
    try opened.expectNoNewValidationErrors();
}

test "a draw lands on the headless screen as expected" {
    const timer: TestTimer = .start("draw on the screen");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(drawOnScreen(opened.device, opened.queue));
    try opened.expectNoNewValidationErrors();
}

test "mip levels and array layers are viewed without a validation error" {
    const timer: TestTimer = .start("mip and array views");
    defer timer.report();
    const opened: TestDevice = try .open();
    mipAndArrayViews(opened.device, opened.queue);
    try opened.expectNoNewValidationErrors();
}

test "the engine's compute doubles its input on the device" {
    const timer: TestTimer = .start("the engine's compute");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runEngineCompute(testing.allocator, opened.device, opened.queue));
    try opened.expectNoNewValidationErrors();
}

test "the training pipelines are made without a validation error" {
    const timer: TestTimer = .start("training pipelines");
    defer timer.report();
    const opened: TestDevice = try .open();
    try makeTrainingPipelines(testing.allocator, opened.device, opened.queue);
    try opened.expectNoNewValidationErrors();
}

test "one device, two pipelines: a kit's field reaches a simulator's exactly, and the policy acts for the simulator" {
    // The learning kit's pipeline (zn_mlp) and the simulator's (robotgpu) on Geno's model, shared by the two checks:
    // llvmpipe keeps the memory of a simulator after it is freed, so each simulator a run makes adds to its peak.
    const timer: TestTimer = .start("one device, two pipelines");
    defer timer.report();
    const opened: TestDevice = try .open();
    const KitKernelEntry: type = z.Compute(zn_mlp).KernelWgsl;
    const kit_kernel_entries: [zn_mlp.kernels.len]KitKernelEntry = spirvEntries(zn_mlp, zn_mlp_spirv);
    var kit_pipe: z.Compute(zn_mlp) = try .initGpu(testing.allocator, opened.device, opened.queue, &kit_kernel_entries);
    defer kit_pipe.deinit();
    const SimulatorKernelEntry: type = robotgpu_host.Pipe.KernelWgsl;
    const simulator_kernel_entries: [robotgpu.kernels.len]SimulatorKernelEntry = spirvEntries(robotgpu, robotgpu_spirv);
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(testing.allocator, z.robot_geno_model, .{});
    defer geno.deinit();
    const geno_model: *const z.robot.Model = &geno.model;
    const simulated_world_count: u32 = 8;
    const simulator_entries: []const SimulatorKernelEntry = &simulator_kernel_entries;
    var simulator: robotgpu_host.Sim = try .initGpu(
        testing.allocator,
        opened.device,
        opened.queue,
        simulator_entries,
        geno_model,
        simulated_world_count,
    );
    defer simulator.deinit();
    defer tests_device_coverage.add(&simulator);
    try expect(try runCopyBetweenPipelines(&kit_pipe, &simulator));
    try expect(try runActingOnTheDevice(testing.allocator, &kit_pipe, &simulator, geno_model));
    try opened.expectNoNewValidationErrors();
}

test "a view and a sampler released while a bind group holds them are destroyed once, after the group" {
    const timer: TestTimer = .start("release while held");
    defer timer.report();
    const opened: TestDevice = try .open();
    releaseWhileHeld(opened.device);
    try opened.expectNoNewValidationErrors();
}

test "bind groups made and destroyed round after round keep the host's descriptor pages and staging bounded" {
    const timer: TestTimer = .start("bind group churn");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(churnBindGroups(opened.device, opened.queue));
    try opened.expectNoNewValidationErrors();
}

test "large writes round after round keep the staging within its budget and one large chunk" {
    const timer: TestTimer = .start("large write churn");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try churnLargeWrites(opened.device, opened.queue));
    try opened.expectNoNewValidationErrors();
}

test "the validation layer reported no error over the whole run" {
    // No call of any test made the layer complain - judged at the host's shutdown, since an object never destroyed is
    // reported only when the device is. Declared next to last: every device test before it has run, and the coverage
    // report after it needs no device.
    if (!vulkan_host.isStarted()) {
        return error.SkipZigTest;
    }
    const counts: vulkan_host.MessageCounts = vulkan_host.shutdown();
    try testing.expectEqual(@as(u32, 0), counts.errors);
}

test "the device's coverage: which robotgpu kernels the tests dispatched on the GPU" {
    // A run limited by `-Dtest-filter` dispatches only its part: nothing to report.
    if (test_options.filtered) {
        return error.SkipZigTest;
    }
    var never_dispatched: usize = 0;
    var missing_from_the_device: usize = 0;
    for (robotgpu.kernels, tests_device_coverage.dispatches) |kernel, dispatched| {
        if (dispatched != 0) {
            continue;
        }
        never_dispatched += 1;
        if (hasNoWorkInTheTestModels(kernel)) {
            std.debug.print("vk-host-test: robotgpu kernel '{s}' has no work in this test's models\n", .{kernel});
        } else {
            std.debug.print("vk-host-test: robotgpu kernel '{s}' never dispatched on the device\n", .{kernel});
            missing_from_the_device += 1;
        }
    }
    const dispatched_kernels: usize = robotgpu.kernels.len - never_dispatched;
    std.debug.print("vk-host-test: robotgpu device coverage - {d} of {d} kernels dispatched on the device\n", .{
        dispatched_kernels,
        robotgpu.kernels.len,
    });
    // A kernel no test sends to a GPU is checked on the CPU twin alone, which proves nothing about the device.
    try expectEqual(@as(usize, 0), missing_from_the_device);
}
