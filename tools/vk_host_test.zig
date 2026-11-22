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
//!             two-hot loss, its gradient and its decode - then the flow policy's, the tracking planner's and the
//!             labels' kernels, run on the device and on the CPU twin from the same data, in the same order, and
//!             compared value by value: the row accessors, the shared row statistics and the uniform's newer fields,
//!             compiled for the device, compute what the host computes
//!     fit     zimrnum_fit's network (`examples/zimrnum_fit`) handed from the device to the CPU twin and from the twin
//!             to the device, as the page's toggle hands it, each against the twin's own uninterrupted run: the
//!             device steps as the twin does, and the training's state carries everything a step reads
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
const latent_kit = z.robot_latent_kit;
const kit_mlp = z.kit_mlp;
const zm = @import("zm");
const isFinite = zm.isFinite;
const startsWith = std.mem.startsWith;
const indexOfScalar = std.mem.indexOfScalar;
const bytesToValue = std.mem.bytesToValue;

const eql = std.mem.eql;
const print = std.debug.print;
const test_options = @import("vk_host_test_options");
/// The test runner (`src/test_runner.zig`): whether a `--filter` chose this run's tests.
const test_root = @import("root");
const writeInt = std.mem.writeInt;
const Allocator = std.mem.Allocator;
const asBytes = std.mem.asBytes;
const testing = std.testing;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const copyForwards = std.mem.copyForwards;
const fieldNames = std.meta.fieldNames;
const FieldEnum = std.meta.FieldEnum;
const float = zm.float;
const float64 = zm.float64;
const inf = zm.inf;
const nan = zm.nan;
const pi = zm.pi;
const sinTurns = zm.sinTurns;
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
        const scale: f32 = @max(magnitude_sum, 1.0e-30);
        const gap: f32 = robotgpu_host.gapInUnits(device_sum, twin_sum, scale);
        largest_gap = @max(largest_gap, gap);
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
    // Each float at its own scale: groups of one number.
    const one_number_a_scale: u32 = 1;
    for (results, gaps) |result, *gap| {
        var largest: f32 = 0;
        var row: u32 = 0;
        while (row < row_count) : (row += 1) {
            // The result's floats in this row, side by side.
            const first: u32 = row * output_width + result.offset;
            const device_floats: []const f32 = device_outputs[first..][0..result.width];
            const twin_floats: []const f32 = twin_outputs[first..][0..result.width];
            const row_gap: f32 = robotgpu_host.largestGapEpsilons(device_floats, twin_floats, one_number_a_scale);
            largest = @max(largest, row_gap);
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

/// SITES AND STATEFUL ACTUATORS, DEVICE AGAINST TWIN: the arm made for them (`robot_sites_and_activations_arm`) - three
/// sites, one turned on its link, and an integrator, a filter and an exactly integrated filter beside a servo with no
/// state - in 64 worlds, each with its own coordinates, velocities, controls and activations, one step on both, every
/// array compared (`StepComparison`). The other models simulated here have no site and no actuator with a state, so
/// without the arm two kernels would never run on a GPU: `site_poses`, which places each site on its body, and
/// `next_activations`, which carries each activation across the step.
///
/// The inputs walk each quantity through both signs and several sizes as the world changes: the angles to 1.2 rad, the
/// speeds to 1.2 rad/s, the activations to 0.3, and the controls to 2 - past the integrator's range of 1, so its clamp
/// is taken in some worlds and not in others.
fn runRobotgpuSitesAndActivations(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
) !robotgpu_host.StepVerdict {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var arm: z.robot.Model = try z.robot_sites_and_activations_arm.Model.build(gpa);
    defer arm.deinit();
    // Stepped without constraints, as the twin's check against robot.zig steps it: the arm has no joint range and no
    // floor here, so no row would be made either way.
    arm.opt.disable_constraints = true;
    const model: *const z.robot.Model = &arm;
    const world_count: u32 = 64;
    var on_device: robotgpu_host.Sim = try .initGpu(gpa, device, queue, &entries, model, world_count);
    defer on_device.deinit();
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwin(gpa, model, world_count);
    defer twin.deinit();
    const coordinates: []f32 = try gpa.alloc(f32, model.coordinate_count);
    defer gpa.free(coordinates);
    const velocities: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(velocities);
    const controls: []f32 = try gpa.alloc(f32, model.actuator_count);
    defer gpa.free(controls);
    const activations: []f32 = try gpa.alloc(f32, model.activation_count);
    defer gpa.free(activations);
    const sims = [2]*robotgpu_host.Sim{ &on_device, &twin };
    for (sims) |sim| {
        var world: u32 = 0;
        while (world < world_count) : (world += 1) {
            // Each a small whole number from -4 to 4, or -3 to 3, that moves with the world and the element.
            for (coordinates, 0..) |*coordinate, index| {
                const element_factor: f32 = @floatFromInt(index % 3 + 1);
                const world_factor: f32 = @floatFromInt(@as(i32, @intCast(world % 9)) - 4);
                coordinate.* = 0.1 * element_factor * world_factor;
            }
            sim.uploadWorldPositions(world, coordinates);
            for (velocities, 0..) |*velocity, index| {
                const element_factor: f32 = @floatFromInt(index % 3 + 1);
                const world_factor: f32 = @floatFromInt(@as(i32, @intCast(world % 5)) - 2);
                velocity.* = 0.2 * element_factor * world_factor;
            }
            sim.uploadWorldArray("joint_velocities", world, velocities);
            for (controls, 0..) |*control, index| {
                const shifted: u32 = @intCast(index + world);
                const factor: f32 = @floatFromInt(@as(i32, @intCast(shifted % 9)) - 4);
                control.* = 0.5 * factor;
            }
            sim.uploadWorldArray("controls", world, controls);
            for (activations, 0..) |*activation, index| {
                const shifted: u32 = @intCast(index + 2 * world);
                const factor: f32 = @floatFromInt(@as(i32, @intCast(shifted % 7)) - 3);
                activation.* = 0.1 * factor;
            }
            sim.uploadWorldArray("activations", world, activations);
        }
    }
    on_device.submitStep();
    twin.submitStep();
    var comparison: robotgpu_host.StepComparison = try .request(gpa, &on_device, &twin);
    defer comparison.deinit(gpa);
    while (!comparison.collect()) {
        std.atomic.spinLoopHint();
    }
    return comparison.verdict;
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

/// THE CURRICULUM's BINS A WHOLE DECISION LEAVES, the four shared arrays of the host's window
/// (`robotgpu.HostWindowLayout`), as each side's own round kept them (`robotgpu.curriculum_round`): the bins' returns,
/// folded from the episodes the decision ended; their softmax shares, through the device's own exponential; their
/// long-run weights; and the mixture's running sums a start is drawn against. Each bar is many times the gap
/// measured on lavapipe (in brackets), in epsilons of the array's largest number, as the tracking arrays' are: a
/// GPU's exponential is its own.
const tracking_bin_arrays = [_]TrackedFloatArray{
    // A fold of the episode's sums [3.50]: their kind, and their bar.
    .{ .name = "bin_returns", .bar_epsilons = 1024 },
    // Shares of at most 1, through the exponential [0.25], and what is folded and summed from them [0, 0].
    .{ .name = "bin_softmax", .bar_epsilons = 64 },
    .{ .name = "bin_history_weights", .bar_epsilons = 64 },
    .{ .name = "bin_running_sums", .bar_epsilons = 64 },
};

/// What the tracking check measured, over its compared decisions.
const TrackingOutcome = struct {
    /// Each float array's largest gap between the device and the twin, in epsilons (`tracking_float_arrays`' order).
    float_gaps_epsilons: [tracking_float_arrays.len]f32,
    /// How many of each integer array's numbers differed (`tracking_integer_arrays`' order).
    integer_differences: [tracking_integer_arrays.len]u32,
    /// Each array of the curriculum's bins: its largest gap between the device and the twin, in epsilons
    /// (`tracking_bin_arrays`' order) - and how many of the twin's bin returns moved from the returns it was given, so
    /// the bins compared were bins its rounds had folded episodes into.
    bin_gaps_epsilons: [tracking_bin_arrays.len]f32,
    bin_returns_moved: u32,
    /// What happened on the twin, so the worlds compared were worlds in these situations: episodes that ended and
    /// began again, aftermaths begun, returns, and worlds pushed during their episode.
    episodes_restarted: u32,
    aftermaths_begun: u32,
    returns: u32,
    worlds_pushed: u32,
    /// Watched pushes ended in a way the brake counts - kept, returned or failed (`robot.PushBrake`).
    watched_pushes_ended: u32,
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

/// `sim`'s host window - the `io` arena as far as its arrays reach (`Sim.worldArenaEnd`), the curriculum's bins -
/// read back into `out`, waiting for the copy, as only a test may.
fn readHostWindow(
    gpa: Allocator,
    sim: *robotgpu_host.Sim,
    out: []f32,
) !void {
    const count: u32 = @intCast(out.len);
    var request: robotgpu_host.Pipe.RangeRequest(.io) = try sim.pipe.requestRange(gpa, .io, 0, count);
    while (!request.collect(out)) {
        std.atomic.spinLoopHint();
    }
}

/// THE CURRICULUM's BINS, DEVICE AGAINST TWIN, after one decision on each from one state: each array of
/// `tracking_bin_arrays`, its gap in epsilons of its largest number (`largestGapEpsilons`, the array one group), kept
/// in `out_outcome.bin_gaps_epsilons` where it is the largest so far. The two slices are each simulator's host
/// window, whole.
fn compareTrackingBins(
    layout: robotgpu.Layout,
    device_window: []const f32,
    twin_window: []const f32,
    out_outcome: *TrackingOutcome,
) void {
    inline for (tracking_bin_arrays, 0..) |tracked, index| {
        const array: @FieldType(robotgpu.HostWindowLayout, tracked.name) = @field(layout.io, tracked.name);
        const device_numbers: []const f32 = device_window[array.offset..][0..array.count];
        const twin_numbers: []const f32 = twin_window[array.offset..][0..array.count];
        const whole_array_one_scale: u32 = 0;
        const gap: f32 = robotgpu_host.largestGapEpsilons(device_numbers, twin_numbers, whole_array_one_scale);
        out_outcome.bin_gaps_epsilons[index] = @max(out_outcome.bin_gaps_epsilons[index], gap);
    }
}

/// How many dispatches `sim` has sent to its device so far, every kernel's together.
fn dispatchesSoFar(sim: *const robotgpu_host.Sim) u64 {
    var total: u64 = 0;
    for (sim.pipe.dispatch_counts) |count| {
        total += count;
    }
    return total;
}

/// WHERE A DECISION's TIME GOES ON THE DEVICE, PRINTED: every dispatch of the pipe timed (`Compute.enableTimings`,
/// a segment per dispatch), one more whole decision run and waited for, then each kernel's time summed over that
/// decision's dispatches - the twelve largest first, with their sum and the decision's three phases'.
fn reportKernelTimes(
    gpa: Allocator,
    on_device: *robotgpu_host.Sim,
    physics_steps: u32,
    clock: robotgpu.DecisionClock,
    flags_read: []u32,
) !void {
    const marks_for_a_decision: u32 = 1 << 14;
    const is_timed: bool =
        try on_device.pipe.enableTimings(.{ .mark_capacity = marks_for_a_decision, .per_dispatch = true });
    if (!is_timed) {
        print("vk-host-test: robotgpu kernel times: this device writes no compute timestamps\n", .{});
        return;
    }
    on_device.stepDecision(physics_steps, clock);
    const flags_offset: u32 = on_device.layout.world_u.episode_flags.offset;
    try readWorldIntegers(gpa, on_device, flags_offset, flags_read);
    const kernel_names: []const []const u8 = on_device.pipe.kernelNames();
    const kernel_microseconds: []f64 = try gpa.alloc(f64, kernel_names.len);
    defer gpa.free(kernel_microseconds);
    const kernel_dispatches: []u64 = try gpa.alloc(u64, kernel_names.len);
    defer gpa.free(kernel_dispatches);
    @memset(kernel_microseconds, 0);
    @memset(kernel_dispatches, 0);
    var phase_microseconds: [z.robot.RoundPhase.count]f64 = @splat(0);
    var phase_segments: [z.robot.RoundPhase.count]u32 = @splat(0);
    const read: z.TimingsRead = on_device.pipe.readTimings(
        &phase_microseconds,
        &phase_segments,
        kernel_microseconds,
        kernel_dispatches,
    );
    var all_kernels_microseconds: f64 = 0;
    for (kernel_microseconds) |microseconds| {
        all_kernels_microseconds += microseconds;
    }
    print("vk-host-test: robotgpu kernel times at {d} worlds - {d:.0} microseconds on the GPU a decision in {d} " ++
        "dispatches ({d} untimed): the physics {d:.0}, the judgement {d:.0}, the resets {d:.0}; its largest:\n", .{
        on_device.counts.world_count,
        all_kernels_microseconds,
        read.segments,
        read.untimed_dispatches,
        phase_microseconds[@backingInt(z.robot.RoundPhase.physics)],
        phase_microseconds[@backingInt(z.robot.RoundPhase.judgement)],
        phase_microseconds[@backingInt(z.robot.RoundPhase.resets)],
    });
    const kernels_listed: usize = 12;
    for (0..kernels_listed) |_| {
        // The largest not yet printed; printed, it is struck out.
        var largest: usize = 0;
        for (kernel_microseconds, 0..) |microseconds, kernel| {
            if (microseconds > kernel_microseconds[largest]) {
                largest = kernel;
            }
        }
        const nothing_left: bool = kernel_microseconds[largest] <= 0;
        if (nothing_left) {
            break;
        }
        print("vk-host-test:     {s}: {d:.0} microseconds in {d} dispatches\n", .{
            kernel_names[largest],
            kernel_microseconds[largest],
            kernel_dispatches[largest],
        });
        kernel_microseconds[largest] = 0;
    }
}

/// THE TRACKING CHECKS' CLIP: the first two seconds of Geno's get-up clip, its frame time made the model's timestep -
/// the device's servo steps at the model's timestep and the fleet's at its clip's frame time, so the two must be one.
/// Two seconds, because every frame carries about a thousand numbers of tables (its coordinates, its reference's
/// features and bodies - `robotgpu_host.RunTables`), and the test build's model arena holds a few hundred frames of
/// them (`robotgpu_sizes_test.zig`). The clip's storage is unchanged; only its length is. The caller owns the clip.
fn loadTrackingClip(gpa: Allocator, model: *const z.robot.Model) !z.robot_dance.Clip {
    var clip: z.robot_dance.Clip = try .fromBytes(gpa, getup_zclip);
    clip.frame_time = model.opt.timestep;
    const compared_frames: usize = 120;
    clip.frame_count = @min(clip.frame_count, compared_frames);
    return clip;
}

/// THE TRACKING CHECKS' FLEET: `world_count` characters of `model` on `clip`, a decision every `physics_steps` steps,
/// set so that a few decisions meet everything a decision can decide - a trainer's fleet in small, and what the
/// simulators are then set from (`Fleet.trackingSettings`): the action filtered at the physics rate, a stiffness per
/// limb, an aftermath for the first half of the characters, a push at every decision, starts with noise, in trouble
/// and drawn by a curriculum, each new pose rested on the floor. The fleet keeps `model` and `clip` by pointer: both
/// stay where they are for as long as it lives. The caller owns the fleet (`deinit`).
fn initTrackingFleet(
    gpa: Allocator,
    model: *z.robot.Model,
    clip: *const z.robot_dance.Clip,
    world_count: u32,
    physics_steps: u32,
) !*z.robot_track.Fleet {
    const fleet: *z.robot_track.Fleet = try z.robot_track.Fleet.init(gpa, model, &.{clip}, .{
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
        // Every character still in its episode pushed each decision - but one whose last push is watched: the
        // brake's watch on half the pushes, a decision long - and every start in trouble.
        .pushes = .{
            .every = 1,
            .rate_per_second = 4.0,
            .speed_min = 0.3,
            .speed_max = 0.6,
            .brake = .{ .come_back_bar = 0.6, .watched_share = 0.5, .watch_seconds = 0 },
            .start_share = 1.0,
        },
        .start_noise = .{ .pose = 0.05, .velocity = 0.2 },
        .curriculum = .{ .bin_seconds = 0.5 },
    });
    fleet.options.task.rest_on_floor = true;
    return fleet;
}

/// WHERE THE TRACKING CHECK's WORLDS START, and which two are knocked off their reference. Every world starts on the
/// clip at a frame of its own, at rest: frames `frame_step` apart from `first_frame`, coming round again after
/// `frame_span` frames - nine worlds - so every start leaves the compared decisions' frames before the clip's end
/// (`lastFrameReached`). Two characters start `knock_distance` away from their reference, far past any limit a
/// rounding could cross: one in the half of the worlds that lives on through a loss, one in the half whose episode
/// ends at it.
const TrackingStarts = struct {
    first_frame: u32 = 10,
    frame_step: u32 = 9,
    frame_span: u32 = 81,
    /// Frames kept free after the latest start: more than the compared decisions take - three decisions of two
    /// physics steps, and the goal one frame ahead.
    frames_after_last_start: u32 = 16,
    /// How far along x a knocked character's root starts from its reference, in metres.
    knock_distance: f32 = 1.0,
    /// The knocked character that lives on - a loss and an aftermath, then a return.
    knocked_and_living_on: u32,
    /// The knocked character with no aftermath - its episode ends at its loss, and it starts again.
    knocked_to_its_end: u32,

    /// The starts of `world_count` worlds: the second world is knocked and lives on (the first half of the worlds
    /// has an aftermath); the third from the last is knocked to its end (the second half has none).
    fn forWorlds(world_count: u32) TrackingStarts {
        return .{ .knocked_and_living_on = 1, .knocked_to_its_end = world_count - 3 };
    }

    /// The clip's frame world `world` starts at.
    fn frameOf(starts: TrackingStarts, world: u32) u32 {
        return starts.first_frame + (starts.frame_step * world) % starts.frame_span;
    }

    /// The last frame the compared decisions can reach from any start: the clip must be longer than this.
    fn lastFrameReached(starts: TrackingStarts) u32 {
        return starts.first_frame + starts.frame_span + starts.frames_after_last_start;
    }

    /// Whether world `world` starts knocked off its reference.
    fn isKnocked(starts: TrackingStarts, world: u32) bool {
        return world == starts.knocked_and_living_on or world == starts.knocked_to_its_end;
    }
};

/// THE WORLDS' STARTS, given to the twin alone (the device takes the twin's worlds before each decision): each world on
/// the clip at its start frame (`TrackingStarts.frameOf`), at rest, a knocked character's root moved along x by the
/// knock's distance. `poses` is the clip's coordinates, a frame a row of `coordinate_count` (`RunTables.poses`);
/// `still` is one world's velocities, all zero.
fn placeTrackingStarts(
    gpa: Allocator,
    twin: *robotgpu_host.Sim,
    starts: TrackingStarts,
    poses: []const f32,
    coordinate_count: usize,
    still: []const f32,
) !void {
    // One world's pose, scratch that lives for this call alone.
    const pose: []f32 = try gpa.alloc(f32, coordinate_count);
    defer gpa.free(pose);
    var world: u32 = 0;
    while (world < twin.counts.world_count) : (world += 1) {
        const frame: u32 = starts.frameOf(world);
        @memcpy(pose, poses[frame * coordinate_count ..][0..coordinate_count]);
        if (starts.isKnocked(world)) {
            pose[0] += starts.knock_distance;
        }
        twin.uploadWorldPositions(world, pose);
        twin.uploadWorldArray("joint_velocities", world, still);
        twin.setWorldClip(world, 0, frame);
    }
}

/// THE TRACKING TASK's ARRAYS, DEVICE AGAINST TWIN, after one decision on each from one state. Every float array of
/// `tracking_float_arrays`: its gap in epsilons, a world's block sharing one scale (`largestGapEpsilons`), kept in
/// `out_outcome.float_gaps_epsilons` where it is the largest so far. Every integer array of `tracking_integer_arrays`:
/// its numbers that differ, counted into `out_outcome.integer_differences`. The four slices are every world's state as
/// read from each simulator - both world arenas whole, as far as the worlds reach (`Sim.worldArenaEnd`).
fn compareTrackingArrays(
    layout: robotgpu.Layout,
    world_count: u32,
    device_floats: []const f32,
    twin_floats: []const f32,
    device_integers: []const u32,
    twin_integers: []const u32,
    out_outcome: *TrackingOutcome,
) void {
    inline for (tracking_float_arrays, 0..) |tracked, index| {
        const array: @FieldType(robotgpu.WorldStateLayout, tracked.name) = @field(layout.world_f, tracked.name);
        const array_length: usize = array.stride * world_count;
        const device_numbers: []const f32 = device_floats[array.offset..][0..array_length];
        const twin_numbers: []const f32 = twin_floats[array.offset..][0..array_length];
        const gap: f32 = robotgpu_host.largestGapEpsilons(device_numbers, twin_numbers, array.stride);
        out_outcome.float_gaps_epsilons[index] = @max(out_outcome.float_gaps_epsilons[index], gap);
    }
    inline for (tracking_integer_arrays, 0..) |array_name, index| {
        const array: @FieldType(robotgpu.WorldIntegersLayout, array_name) = @field(layout.world_u, array_name);
        const array_length: usize = array.stride * world_count;
        const device_numbers: []const u32 = device_integers[array.offset..][0..array_length];
        const twin_numbers: []const u32 = twin_integers[array.offset..][0..array_length];
        for (device_numbers, twin_numbers) |device_number, twin_number| {
            if (device_number != twin_number) {
                out_outcome.integer_differences[index] += 1;
            }
        }
    }
}

/// WHAT HAPPENED ON THE TWIN IN ONE DECISION, counted into `out_outcome`, so the check can require that its events took
/// place: an episode that ended and began again; a world pushed - one whose velocities the resets changed without
/// starting it again; an aftermath begun; a return. `twin_floats` and `twin_integers` are the twin's world arenas after
/// the decision's resets; `velocities_before_resets` is every world's velocities read after the decision's end and
/// before those resets.
fn countTwinEvents(
    layout: robotgpu.Layout,
    world_count: u32,
    twin_floats: []const f32,
    twin_integers: []const u32,
    velocities_before_resets: []const f32,
    out_outcome: *TrackingOutcome,
) void {
    const velocities: robotgpu.WorldArray(.world_f, .dofs) = layout.world_f.joint_velocities;
    const flags: robotgpu.WorldArray(.world_u, .single) = layout.world_u.episode_flags;
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        const world_flags: u32 = twin_integers[flags.at(world, 0)];
        const finished: bool = world_flags & robotgpu.episodeFlagBit(.finished) != 0;
        const aftermath_begins: bool = world_flags & robotgpu.episodeFlagBit(.aftermath_begins) != 0;
        const returned: bool = world_flags & robotgpu.episodeFlagBit(.returned) != 0;
        const watched_push_ended: bool = world_flags & robotgpu.episodeFlagBit(.watched_push_settled) != 0;
        const first_before: usize = world * velocities.stride;
        const before: []const f32 = velocities_before_resets[first_before..][0..velocities.stride];
        const after: []const f32 = twin_floats[velocities.at(world, 0)..][0..velocities.stride];
        const resets_changed_velocities: bool = !eql(f32, before, after);
        if (finished) {
            out_outcome.episodes_restarted += 1;
        } else if (resets_changed_velocities) {
            out_outcome.worlds_pushed += 1;
        }
        if (aftermath_begins) {
            out_outcome.aftermaths_begun += 1;
        }
        if (watched_push_ended) {
            out_outcome.watched_pushes_ended += 1;
        }
        if (returned) {
            out_outcome.returns += 1;
        }
    }
}

/// THE DEVICE ALONE, TIMED, after the compared decisions: what a whole decision costs on this device at this many
/// worlds, the learner's work apart. First the decisions of the warm-up, not timed; then `size.timed_decisions` whole
/// decisions back to back under the wall clock, the host reading every world's flags after each one as a trainer's
/// round does (or once at the end - `size.reads_flags_every_decision`); then, where the size asks for it, one more
/// decision with the GPU's timestamps on and its kernels' times printed (`reportKernelTimes`). The decisions take
/// their clock numbers from `first_decision_number` on. Written into `out_outcome`: how many decisions were timed, the
/// seconds they took, and the dispatches they sent.
fn timeDeviceDecisions(
    gpa: Allocator,
    on_device: *robotgpu_host.Sim,
    size: TrackingSize,
    physics_steps: u32,
    first_decision_number: u32,
    out_outcome: *TrackingOutcome,
) !void {
    const world_count: u32 = on_device.counts.world_count;
    const flags: robotgpu.WorldArray(.world_u, .single) = on_device.layout.world_u.episode_flags;
    // Every world's flags as the host reads them back, scratch that lives for this call alone.
    const flags_read: []u32 = try gpa.alloc(u32, flags.stride * world_count);
    defer gpa.free(flags_read);
    // THE WARM-UP: decisions that are not timed, then a read that waits for them. The clock then starts on worlds in
    // the middle of their episodes, at every size alike - a first decision from a pose at rest has no contact yet,
    // and costs a fraction of the ones that follow.
    var warmup_decision: u32 = 0;
    while (warmup_decision < size.warmup_decisions) : (warmup_decision += 1) {
        const warmup_clock: robotgpu.DecisionClock = .{
            .number = first_decision_number + warmup_decision,
            .push_top_share = 1.0,
        };
        on_device.stepDecision(physics_steps, warmup_clock);
    }
    try readWorldIntegers(gpa, on_device, flags.offset, flags_read);
    // THE TIMED DECISIONS. The worlds keep their last actions and live through whatever comes - losses, ends, new
    // starts, pushes. After every decision the host reads every world's flags, as a trainer's round does before the
    // next - or, when the size says so, only once after the last decision, which shows what waiting for the GPU at
    // every decision costs. The last read waits for everything: the wall clock around the loop is the cost of the
    // decisions and nothing else.
    const first_timed_number: u32 = first_decision_number + size.warmup_decisions;
    const dispatches_before: u64 = dispatchesSoFar(on_device);
    const timed_started_ms: f64 = z.native_os.monotonicMilliseconds();
    var timed_decision: u32 = 0;
    while (timed_decision < size.timed_decisions) : (timed_decision += 1) {
        const timed_clock: robotgpu.DecisionClock = .{
            .number = first_timed_number + timed_decision,
            .push_top_share = 1.0,
        };
        on_device.stepDecision(physics_steps, timed_clock);
        if (size.reads_flags_every_decision) {
            try readWorldIntegers(gpa, on_device, flags.offset, flags_read);
        }
    }
    try readWorldIntegers(gpa, on_device, flags.offset, flags_read);
    const timed_ms: f64 = z.native_os.monotonicMilliseconds() - timed_started_ms;
    out_outcome.timed_decisions = size.timed_decisions;
    out_outcome.timed_seconds = timed_ms / 1000.0;
    out_outcome.timed_dispatches = dispatchesSoFar(on_device) - dispatches_before;
    if (size.profiles_kernels) {
        const profiled_clock: robotgpu.DecisionClock = .{
            .number = first_timed_number + size.timed_decisions,
            .push_top_share = 1.0,
        };
        try reportKernelTimes(gpa, on_device, physics_steps, profiled_clock, flags_read);
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
    const world_count: u32 = size.world_count;
    try expect(world_count >= 8);
    const physics_steps: u32 = 2;
    // THE SCENE the two simulators are made from: Geno at his training physics, his get-up clip's first two seconds,
    // a CPU fleet of the check's characters on it, and the clip's tables as a device takes them.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    const poses: []const f32 = tables.poses;
    const coordinate_count: usize = model.coordinate_count;
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        world_count,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer twin.deinit();
    // The fleet's task on both, as a trainer mirrors it: one value, one call each.
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{});
    try on_device.setTracking(gpa, settings);
    try twin.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    try twin.uploadStartBins(gpa, fleet);
    // THE WORLDS' STARTS, given to the twin alone (the device takes the twin's worlds before each decision).
    const starts: TrackingStarts = .forWorlds(world_count);
    try expect(clip.frame_count > starts.lastFrameReached());
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &twin, starts, poses, coordinate_count, still);
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
    const velocities: robotgpu.WorldArray(.world_f, .dofs) = twin.layout.world_f.joint_velocities;
    const velocities_before_resets: []f32 = try gpa.alloc(f32, velocities.stride * world_count);
    defer gpa.free(velocities_before_resets);
    const action_count: usize = twin.counts.action_count;
    const actions: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(actions);
    // Each simulator's host window, whole: the curriculum's bins, which each side keeps itself.
    const window_count: u32 = twin.worldArenaEnd(.io);
    const twin_window: []f32 = try gpa.alloc(f32, window_count);
    defer gpa.free(twin_window);
    const device_window: []f32 = try gpa.alloc(f32, window_count);
    defer gpa.free(device_window);
    var outcome: TrackingOutcome = .{
        .float_gaps_epsilons = @splat(0),
        .integer_differences = @splat(0),
        .bin_gaps_epsilons = @splat(0),
        .bin_returns_moved = 0,
        .episodes_restarted = 0,
        .aftermaths_begun = 0,
        .returns = 0,
        .worlds_pushed = 0,
        .watched_pushes_ended = 0,
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
            const start_frame: u32 = starts.frameOf(starts.knocked_and_living_on);
            const frame_now: u32 = start_frame + physics_steps * decision;
            const reference_pose: []const f32 = poses[frame_now * coordinate_count ..][0..coordinate_count];
            twin.uploadWorldPositions(starts.knocked_and_living_on, reference_pose);
            twin.uploadWorldArray("joint_velocities", starts.knocked_and_living_on, still);
        }
        // The device takes the twin's worlds whole, and its bins, so the decision starts from one state on both.
        try giveDeviceTheTwinsWorlds(gpa, &twin, &on_device, twin_floats, twin_integers);
        try readHostWindow(gpa, &twin, twin_window);
        on_device.pipe.uploadAt(.io, 0, twin_window);
        const clock: robotgpu.DecisionClock = .{ .number = decision + 1, .push_top_share = 1.0 };
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
        compareTrackingArrays(
            twin.layout,
            world_count,
            device_floats,
            twin_floats,
            device_integers,
            twin_integers,
            &outcome,
        );
        countTwinEvents(
            twin.layout,
            world_count,
            twin_floats,
            twin_integers,
            velocities_before_resets,
            &outcome,
        );
        // The bins, as each side's own round left them.
        try readHostWindow(gpa, &twin, twin_window);
        try readHostWindow(gpa, &on_device, device_window);
        compareTrackingBins(twin.layout, device_window, twin_window, &outcome);
    }
    if (size.compares_with_the_twin) {
        // The twin's bin returns that are no longer the fleet's it was given: bins its rounds folded episodes into.
        const returns: @FieldType(robotgpu.HostWindowLayout, "bin_returns") = twin.layout.io.bin_returns;
        const twin_returns: []const f32 = twin_window[returns.offset..][0..returns.count];
        for (twin_returns, fleet.bin_returns) |twin_return, given_return| {
            if (twin_return != given_return) {
                outcome.bin_returns_moved += 1;
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
    try timeDeviceDecisions(gpa, &on_device, size, physics_steps, decision_count + 1, &outcome);
    return outcome;
}

/// What `runRobotgpuGiving` measured: the give program on a device against the twin's, from one state.
const GivingOutcome = struct {
    /// The largest gap of the explored choices (`chosen_actions`) and of the actions given (`actions`), device against
    /// twin, in epsilons at a world's scale.
    chosen_gap_epsilons: f32,
    actions_gap_epsilons: f32,
    /// How many of the choices given to the twin were finite, and how many of those its exploration moved.
    finite_choices: u32,
    choices_explored: u32,
    /// How many of the twin's actions are their choice unchanged: none, where the filter's shares are below 1.
    actions_equal_to_choice: u32,
    /// How many of the device's actions are not finite: none, whatever the choices were.
    device_actions_not_finite: u32,
};

/// The bars of the give program's two arrays, in epsilons at a world's scale: several times the larger of two devices'
/// gaps - 0.99 and 0.50 on a software Vulkan, 1.50 and 0.50 on an RTX 5070, for the explored choices and the actions.
/// A draw goes through the device's own logarithm, square root and cosine, so every device's gaps are its own - the
/// report prints them at full size. What the check is for stands far past either bar: a draw taken at the wrong
/// counter or a wrong share is a gap of millions of epsilons, a number not finite on one side an infinite one.
const GivingBars = struct {
    chosen: f32 = 16,
    actions: f32 = 8,
};

/// THE GIVE PROGRAM, DEVICE AGAINST TWIN, FROM ONE STATE: what stands between a policy's choices and the physics
/// (`Sim.giveActions`) - `explore_actions`, which adds a draw of noise to every number of the action, and
/// `filter_decision`, which blends each explored choice with the action given at the last decision.
///
///     chosen_actions   the policy's choice    ->   choice + spread x a normal draw          explore_actions, in place
///     actions          the last decision's    ->   a share of the explored choice,          filter_decision
///                                                  the rest the last action
///
/// The scene is the tracking check's, with a trainer's filter at each decision: a quarter of a new choice in the
/// joints' offsets, a half in the limbs' stiffnesses. The twin is given the last decision's actions and this
/// decision's choices, known numbers different in every world; the device takes the twin's worlds whole; both run the
/// program at a decision whose exploration is on; the two arrays are compared. A draw goes through a logarithm and a
/// cosine, which a GPU rounds in its own way, so the explored choices are the twin's within a bar and not bit for bit.
/// TWO OF THE CHOICES ARE NOT FINITE - a joint's offset that is not a number, a limb's stiffness that is infinite. Such
/// a choice asks for nothing: the filter takes it as zero, and the physics never sees it. That guard is a comparison
/// (`isFinite`), which a GPU's compiler may assume away, so the device's actions are read for it.
fn runRobotgpuGiving(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
) !GivingOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const world_count: u32 = 8;
    const physics_steps: u32 = 2;
    // THE SCENE, as the tracking check's.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        world_count,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer twin.deinit();
    // The fleet's task on both, with a trainer's filter at each decision.
    const shares: z.robot.DecisionFilterShares = .{ .offsets = 0.25, .stiffness = 0.5 };
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(shares);
    try on_device.setTracking(gpa, settings);
    try twin.setTracking(gpa, settings);
    // THE STATE, on the twin: the actions given at the last decision, then this decision's choices.
    const action_count: usize = twin.counts.action_count;
    const number_count: usize = action_count * world_count;
    const last_actions_row: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(last_actions_row);
    uploadTrackingActions(&twin, world_count, 0, last_actions_row);
    const choices: []f32 = try gpa.alloc(f32, number_count);
    defer gpa.free(choices);
    for (choices, 0..) |*choice, at| {
        const world: usize = at / action_count;
        const number: usize = at % action_count;
        const phase: f32 = 0.9 * float(number + 1) + 1.7 * float(world);
        choice.* = 0.4 * @cos(phase);
    }
    // The two choices that are not finite: the third world's first offset, the sixth world's last stiffness.
    const not_a_number_at: usize = 2 * action_count;
    const infinite_at: usize = 5 * action_count + action_count - 1;
    choices[not_a_number_at] = nan(f32);
    choices[infinite_at] = inf(f32);
    var choosing_world: u32 = 0;
    while (choosing_world < world_count) : (choosing_world += 1) {
        const world_choices: []const f32 = choices[choosing_world * action_count ..][0..action_count];
        twin.uploadWorldArray("chosen_actions", choosing_world, world_choices);
    }
    // Every world's state, the float arena whole, as read from each simulator; the integers for the device's copy.
    const float_count: u32 = twin.worldArenaEnd(.world_f);
    const twin_floats: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(twin_floats);
    const device_floats: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(device_floats);
    const twin_integers: []u32 = try gpa.alloc(u32, twin.worldArenaEnd(.world_u));
    defer gpa.free(twin_integers);
    // The device takes the twin's worlds whole - its seeds among them - so the program starts from one state on both.
    try giveDeviceTheTwinsWorlds(gpa, &twin, &on_device, twin_floats, twin_integers);
    const clock: robotgpu.DecisionClock = .{ .number = 1, .push_top_share = 1.0, .exploration_spread = 0.3 };
    on_device.giveActions(clock);
    twin.giveActions(clock);
    try readWorldFloats(gpa, &twin, 0, twin_floats);
    try readWorldFloats(gpa, &on_device, 0, device_floats);
    const chosen_array: @FieldType(robotgpu.WorldStateLayout, "chosen_actions") = twin.layout.world_f.chosen_actions;
    const actions_array: @FieldType(robotgpu.WorldStateLayout, "actions") = twin.layout.world_f.actions;
    // A world's block is `stride` numbers wide, which can be more than the action's count: the arrays are compared by
    // whole blocks, and a single number is read where the array says it is (`at`).
    const chosen_length: usize = chosen_array.stride * world_count;
    const actions_length: usize = actions_array.stride * world_count;
    const device_chosen: []const f32 = device_floats[chosen_array.offset..][0..chosen_length];
    const twin_chosen: []const f32 = twin_floats[chosen_array.offset..][0..chosen_length];
    const device_actions: []const f32 = device_floats[actions_array.offset..][0..actions_length];
    const twin_actions: []const f32 = twin_floats[actions_array.offset..][0..actions_length];
    var outcome: GivingOutcome = .{
        .chosen_gap_epsilons = robotgpu_host.largestGapEpsilons(device_chosen, twin_chosen, chosen_array.stride),
        .actions_gap_epsilons = robotgpu_host.largestGapEpsilons(device_actions, twin_actions, actions_array.stride),
        .finite_choices = 0,
        .choices_explored = 0,
        .actions_equal_to_choice = 0,
        .device_actions_not_finite = 0,
    };
    for (choices, 0..) |choice, at| {
        const world: u32 = @intCast(at / action_count);
        const number: u32 = @intCast(at % action_count);
        const explored: f32 = twin_floats[chosen_array.at(world, number)];
        const twin_action: f32 = twin_floats[actions_array.at(world, number)];
        const device_action: f32 = device_floats[actions_array.at(world, number)];
        if (isFinite(choice)) {
            outcome.finite_choices += 1;
            if (explored != choice) {
                outcome.choices_explored += 1;
            }
        }
        if (twin_action == explored) {
            outcome.actions_equal_to_choice += 1;
        }
        if (!isFinite(device_action)) {
            outcome.device_actions_not_finite += 1;
        }
    }
    return outcome;
}

/// ONE ARRAY's GAP BESIDE ITS BAR: how far a device's array is from the twin's, in epsilons at a world's scale
/// (`largestGapEpsilons`), and the most it may be.
const MeasuredGap = struct {
    array_name: []const u8,
    gap_epsilons: f32,
    bar_epsilons: f32,
};

/// Whether every gap of `gaps` is within its bar. A miss is named with its numbers, under the check's name.
fn gapsHold(check_name: []const u8, gaps: []const MeasuredGap) bool {
    var holds: bool = true;
    for (gaps) |measured| {
        // Written so a gap that is not a number misses its bar too.
        const within_its_bar: bool = measured.gap_epsilons <= measured.bar_epsilons;
        if (!within_its_bar) {
            print("vk-host-test: {s}: {s} is {d:.1} epsilons from the twin's, its bar {d:.0}\n", .{
                check_name,
                measured.array_name,
                measured.gap_epsilons,
                measured.bar_epsilons,
            });
            holds = false;
        }
    }
    return holds;
}

/// The gaps of `gaps` printed beside their bars: what a device measured, which the bars are refined from.
fn reportGaps(check_name: []const u8, gaps: []const MeasuredGap) void {
    for (gaps) |measured| {
        print("vk-host-test: robotgpu {s}: {s} {d:.2} epsilons from the twin (bar {d:.0})\n", .{
            check_name,
            measured.array_name,
            measured.gap_epsilons,
            measured.bar_epsilons,
        });
    }
}

/// The bars of the policy's inputs check, in epsilons at a world's scale: several times the larger of two devices'
/// gaps from one state - the observation 3.50 on a software Vulkan and 6.18 on an RTX 5070, the inputs 2.81 and
/// 3.46, the records 1.33 and 1.67. The observation here is the kinematics of one pose, with no physics step between
/// the two simulators. A record's largest number is its table row, so its features' gap is small against the block's
/// scale, and a row off by one is tens of thousands of epsilons. The report prints a device's gaps at full size.
const PolicyInputsBars = struct {
    observations: f32 = 64,
    policy_inputs: f32 = 64,
    records: f32 = 16,
};

/// What `runRobotgpuPolicyInputs` measured.
const PolicyInputsOutcome = struct {
    /// The observation's gap, the policy's inputs' and the learner's records', device against twin, each beside its
    /// bar.
    gaps: [3]MeasuredGap,
    /// How many of the device's inputs are not finite: none.
    device_inputs_not_finite: u32,
};

/// THE POLICY's INPUTS, DEVICE AGAINST TWIN, FROM ONE STATE (`policy_inputs_program`): every world observed as it is
/// now, then its row of features for the policy to read - the goal (the reference one frame ahead) and the state (the
/// observation's first half), each `(x - mean) / spread` with the normaliser's tables.
///
///     observations     the bodies in the root's frame, then the reference's        the observation program
///     policy_inputs    [ goal features | state features ], each normalised         policy_inputs
///
/// The twin lives one decision from the tracking check's starts under known actions, so its worlds are in motion and
/// the two knocked characters have lost their reference. Both simulators are given one normaliser, distinct numbers
/// for every feature; the device takes the twin's worlds whole; both run the program; the observation and the inputs
/// are compared. The normaliser's tables are model constants the host uploads (`Sim.setFeatureNormalizer`): a device
/// without them divides by a spread of zero, and its inputs are infinite or not numbers.
fn runRobotgpuPolicyInputs(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    bars: PolicyInputsBars,
) !PolicyInputsOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const world_count: u32 = 8;
    const physics_steps: u32 = 2;
    // THE SCENE, as the tracking check's.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        world_count,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer twin.deinit();
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{});
    try on_device.setTracking(gpa, settings);
    try twin.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    try twin.uploadStartBins(gpa, fleet);
    // THE STATE, on the twin: the tracking check's starts, then one decision under known actions.
    const starts: TrackingStarts = .forWorlds(world_count);
    try expect(clip.frame_count > starts.lastFrameReached());
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &twin, starts, tables.poses, model.coordinate_count, still);
    const actions_row: []f32 = try gpa.alloc(f32, twin.counts.action_count);
    defer gpa.free(actions_row);
    uploadTrackingActions(&twin, world_count, 0, actions_row);
    const decision_clock: robotgpu.DecisionClock = .{ .number = 1, .push_top_share = 1.0 };
    twin.stepDecision(physics_steps, decision_clock);
    // THE NORMALISER, distinct numbers for every feature, onto both.
    const feature_count: usize = z.robot_track.localSize(model.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    for (means, spreads, 0..) |*mean, *spread, feature| {
        const position: f32 = float(feature);
        mean.* = 0.01 * position;
        spread.* = 0.5 + 0.001 * position;
    }
    on_device.setFeatureNormalizer(means, spreads);
    twin.setFeatureNormalizer(means, spreads);
    // Every world's state, the float arena whole, as read from each simulator; the integers for the device's copy.
    const float_count: u32 = twin.worldArenaEnd(.world_f);
    const twin_floats: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(twin_floats);
    const device_floats: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(device_floats);
    const twin_integers: []u32 = try gpa.alloc(u32, twin.worldArenaEnd(.world_u));
    defer gpa.free(twin_integers);
    // The device takes the twin's worlds whole, so the program starts from one state on both.
    try giveDeviceTheTwinsWorlds(gpa, &twin, &on_device, twin_floats, twin_integers);
    on_device.submitDispatches(&robotgpu.policy_inputs_program);
    twin.submitDispatches(&robotgpu.policy_inputs_program);
    // The learner's records too, packed from the same observation (`record_program`): each world's features, its
    // action - the known actions the twin was given - and the table row of its frame.
    on_device.submitDispatches(&robotgpu.record_program);
    twin.submitDispatches(&robotgpu.record_program);
    try readWorldFloats(gpa, &twin, 0, twin_floats);
    try readWorldFloats(gpa, &on_device, 0, device_floats);
    const observed: @FieldType(robotgpu.WorldStateLayout, "observations") = twin.layout.world_f.observations;
    const inputs: @FieldType(robotgpu.WorldStateLayout, "policy_inputs") = twin.layout.world_f.policy_inputs;
    const records: @FieldType(robotgpu.WorldStateLayout, "records") = twin.layout.world_f.records;
    // Each array compared by whole blocks of its stride, a world's block sharing one scale.
    const observed_length: usize = observed.stride * world_count;
    const inputs_length: usize = inputs.stride * world_count;
    const device_observed: []const f32 = device_floats[observed.offset..][0..observed_length];
    const twin_observed: []const f32 = twin_floats[observed.offset..][0..observed_length];
    const device_inputs: []const f32 = device_floats[inputs.offset..][0..inputs_length];
    const twin_inputs: []const f32 = twin_floats[inputs.offset..][0..inputs_length];
    const records_length: usize = records.stride * world_count;
    const device_records: []const f32 = device_floats[records.offset..][0..records_length];
    const twin_records: []const f32 = twin_floats[records.offset..][0..records_length];
    var outcome: PolicyInputsOutcome = .{
        .gaps = .{
            .{
                .array_name = "observations",
                .gap_epsilons = robotgpu_host.largestGapEpsilons(device_observed, twin_observed, observed.stride),
                .bar_epsilons = bars.observations,
            },
            .{
                .array_name = "policy_inputs",
                .gap_epsilons = robotgpu_host.largestGapEpsilons(device_inputs, twin_inputs, inputs.stride),
                .bar_epsilons = bars.policy_inputs,
            },
            .{
                .array_name = "records",
                .gap_epsilons = robotgpu_host.largestGapEpsilons(device_records, twin_records, records.stride),
                .bar_epsilons = bars.records,
            },
        },
        .device_inputs_not_finite = 0,
    };
    // A world's inputs are the goal - its features, the root target's slots - then the state's features.
    const inputs_per_world: u32 = @intCast(2 * feature_count + z.robot.root_target_size);
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        var number: u32 = 0;
        while (number < inputs_per_world) : (number += 1) {
            const device_input: f32 = device_floats[inputs.at(world, number)];
            if (!isFinite(device_input)) {
                outcome.device_inputs_not_finite += 1;
            }
        }
    }
    return outcome;
}

/// THE ACTING CHECK's POLICY ON ONE PIPE: a kit whose policy reads a world's row of inputs and writes the simulator's
/// actions, its acting rows reserved for the simulator's worlds at the simulator's own strides, and the check's
/// parameters uploaded - the same numbers whatever the pipe, so a GPU's kit and a CPU's hold one policy.
const ActingPolicy = struct {
    kit: z.robot_latent_kit.LatentKit(zn_mlp),
    rows: z.robot_latent_kit.LatentKit(zn_mlp).PolicyRows,

    fn init(
        gpa: Allocator,
        pipe: *z.Compute(zn_mlp),
        simulator: *const robotgpu_host.Sim,
        model: *const z.robot.Model,
    ) !ActingPolicy {
        const LatentKit: type = z.robot_latent_kit.LatentKit(zn_mlp);
        const features: u32 = @intCast(z.robot.localSize(model.body_count));
        // The goal: the features, then the root target's slots - the simulator's rows (`robotgpu.policy_inputs`).
        const goal_width: u32 = features + @as(u32, z.robot.root_target_size);
        const actions: u32 = simulator.counts.action_count;
        const policy_hidden: u32 = 16;
        const kit: LatentKit = try .init(pipe, features, 2, actions, 8, 4, 1, goal_width, policy_hidden);
        var layout: z.kit_mlp.KitLayout = .{
            .acts_floats = kit.total,
            .params_floats = kit.p_at + kit.policy_count,
            .dacts_floats = kit.dtotal,
        };
        const world_count: u32 = simulator.counts.world_count;
        const input_stride: u32 = simulator.layout.world_f.policy_inputs.stride;
        const action_stride: u32 = simulator.layout.world_f.actions.stride;
        const rows: LatentKit.PolicyRows = kit.reservePolicyRows(&layout, world_count, input_stride, action_stride);
        layout.requireFitsKit(zn_mlp);
        // Weights no buffer holds by chance, sized so that every layer's sums are of order one: each layer then
        // shapes the action, and tanh stays in its curved range. The first layer sums several hundred inputs, so
        // its weights are small; the second and the third sum the few hidden units, and the applied block the
        // actions, so theirs are larger. Were they all small, the last actions would barely move the choice, and
        // a policy that never read them would pass. The numbers are scratch that lives for this call alone, the
        // pipe keeping its own copy.
        const first_layer_scale: f32 = 0.02;
        const later_layers_scale: f32 = 0.2;
        const applied_block_scale: f32 = 0.1;
        const weights: LatentKit.PolicyWeights = kit.policyWeights();
        const params: []f32 = try gpa.alloc(f32, layout.params_floats);
        defer gpa.free(params);
        for (params, 0..) |*number, index| {
            const in_applied_block: bool = index >= weights.applied;
            const in_later_layers: bool = index >= weights.second and !in_applied_block;
            const scale: f32 = if (in_applied_block)
                applied_block_scale
            else if (in_later_layers)
                later_layers_scale
            else
                first_layer_scale;
            number.* = scale * @sin(0.7 * float(index));
        }
        pipe.upload(.params, params);
        return .{ .kit = kit, .rows = rows };
    }
};

/// The bars of the acting check, in epsilons at a world's scale. The inputs' is the inputs check's. The choices' and
/// the actions' are several times the larger of two devices' gaps - 1.50 and 0.50 on a software Vulkan, 1.75 and 0.50
/// on an RTX 5070: the choices pass through the policy's two tanh layers and the exploration's logarithm and cosine,
/// each rounded in the device's own way. What the check is for stands far past them: a policy that is not given the
/// last actions is 11,773 and 5,604 epsilons away. The report prints a device's gaps at full size.
const ActingBars = struct {
    policy_inputs: f32 = 64,
    chosen_actions: f32 = 16,
    actions: f32 = 8,
};

/// A DECISION's ACTING AS ONE CALL ON THE DEVICE (`Sim.actWithKit`) AGAINST THE TWIN's OWN COMPOSITION, from one state:
///
///     1  the policy's inputs       the inputs program                           the simulator
///     2  the policy                inputs and last actions -> raw actions       the kit beside it
///     3  the decision's actions    explore_actions, filter_decision             the simulator
///
/// On the device the three are one call, and nothing is read back between them: the kit's pipeline takes the
/// simulator's inputs and last actions, and leaves its raw actions in the simulator's choices, by copies on the GPU.
/// The twin does the same three steps by hand, as the kit's own tests compose them: its simulator's inputs program; a
/// kit on a CPU pipe holding the same parameters, given the inputs and the last actions, run, and read; the raw
/// actions written into the twin's choices; its give program. Each step has a check of its own (the inputs', the
/// giving's, the policy's forward pass against a CPU's); this one is of their joining - that the copies carry the
/// right rows to the right places, that the policy's block reads the last actions, and that what the policy chose
/// is what the give program explores and filters. The scene and the twin's state are the inputs check's, with a
/// trainer's filter at each decision and a clock whose exploration is on.
fn runRobotgpuActing(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    bars: ActingBars,
) ![3]MeasuredGap {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const world_count: u32 = 8;
    const physics_steps: u32 = 2;
    // THE SCENE, as the tracking check's.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        world_count,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer twin.deinit();
    // The fleet's task on both, with a trainer's filter at each decision.
    const shares: z.robot.DecisionFilterShares = .{ .offsets = 0.25, .stiffness = 0.5 };
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(shares);
    try on_device.setTracking(gpa, settings);
    try twin.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    try twin.uploadStartBins(gpa, fleet);
    // THE STATE, on the twin: the tracking check's starts, then one decision under known actions - the last actions.
    const starts: TrackingStarts = .forWorlds(world_count);
    try expect(clip.frame_count > starts.lastFrameReached());
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &twin, starts, tables.poses, model.coordinate_count, still);
    const actions_row: []f32 = try gpa.alloc(f32, twin.counts.action_count);
    defer gpa.free(actions_row);
    uploadTrackingActions(&twin, world_count, 0, actions_row);
    const stepped_clock: robotgpu.DecisionClock = .{ .number = 1, .push_top_share = 1.0 };
    twin.stepDecision(physics_steps, stepped_clock);
    // THE NORMALISER, distinct numbers for every feature, onto both.
    const feature_count: usize = z.robot_track.localSize(model.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    for (means, spreads, 0..) |*mean, *spread, feature| {
        const position: f32 = float(feature);
        mean.* = 0.01 * position;
        spread.* = 0.5 + 0.001 * position;
    }
    on_device.setFeatureNormalizer(means, spreads);
    twin.setFeatureNormalizer(means, spreads);
    // ONE POLICY ON TWO PIPES: the GPU's beside the simulator, a CPU's for the twin.
    var device_kit_pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer device_kit_pipe.deinit();
    var twin_kit_pipe: z.Compute(zn_mlp) = .initCpu();
    defer twin_kit_pipe.deinit();
    const device_policy: ActingPolicy = try .init(gpa, &device_kit_pipe, &on_device, model);
    const twin_policy: ActingPolicy = try .init(gpa, &twin_kit_pipe, &twin, model);
    // The device takes the twin's worlds whole, so the acting starts from one state on both.
    const twin_floats: []f32 = try gpa.alloc(f32, twin.worldArenaEnd(.world_f));
    defer gpa.free(twin_floats);
    const twin_integers: []u32 = try gpa.alloc(u32, twin.worldArenaEnd(.world_u));
    defer gpa.free(twin_integers);
    try giveDeviceTheTwinsWorlds(gpa, &twin, &on_device, twin_floats, twin_integers);
    const acting_clock: robotgpu.DecisionClock = .{
        .number = 2,
        .push_top_share = 1.0,
        .exploration_spread = 0.3,
    };
    // ON THE DEVICE, as one call.
    on_device.actWithKit(zn_mlp, device_policy.kit, device_policy.rows, 0, acting_clock);
    // ON THE TWIN, the same three steps by hand. First the policy's inputs.
    const arrays: robotgpu.WorldStateLayout = twin.layout.world_f;
    twin.submitDispatches(&robotgpu.policy_inputs_program);
    // Then the policy: every world's inputs and last actions into the CPU kit's rows, the policy run, its raw
    // actions read back.
    const twin_rows: z.robot_latent_kit.LatentKit(zn_mlp).PolicyRows = twin_policy.rows;
    const twin_inputs: []f32 = try gpa.alloc(f32, world_count * twin_rows.input_stride);
    defer gpa.free(twin_inputs);
    const last_actions: []f32 = try gpa.alloc(f32, world_count * twin_rows.raw_stride);
    defer gpa.free(last_actions);
    const raw_actions: []f32 = try gpa.alloc(f32, world_count * twin_rows.raw_stride);
    defer gpa.free(raw_actions);
    try readWorldFloats(gpa, &twin, arrays.policy_inputs.at(0, 0), twin_inputs);
    try readWorldFloats(gpa, &twin, arrays.actions.at(0, 0), last_actions);
    // The policy's block reads the last actions: were they all zero, the check would say nothing of it.
    var last_actions_not_zero: u32 = 0;
    for (last_actions) |last_action| {
        if (last_action != 0) {
            last_actions_not_zero += 1;
        }
    }
    try expect(last_actions_not_zero > 0);
    twin_kit_pipe.uploadAt(.acts, twin_rows.inputs_at, twin_inputs);
    twin_kit_pipe.uploadAt(.acts, twin_rows.applied_at, last_actions);
    twin_policy.kit.actOnRows(twin_rows);
    twin_kit_pipe.readRange(.acts, twin_rows.raw_at, raw_actions);
    // Then the decision's actions: the raw actions are the twin's choices, explored and filtered.
    twin.pipe.uploadAt(.world_f, arrays.chosen_actions.at(0, 0), raw_actions);
    twin.giveActions(acting_clock);
    // THE THREE ARRAYS, device against twin, each by whole blocks of its stride.
    const inputs_gap: f32 = try worldArrayGap(
        gpa,
        &on_device,
        &twin,
        arrays.policy_inputs.offset,
        arrays.policy_inputs.stride,
        world_count,
    );
    const chosen_gap: f32 = try worldArrayGap(
        gpa,
        &on_device,
        &twin,
        arrays.chosen_actions.offset,
        arrays.chosen_actions.stride,
        world_count,
    );
    const actions_gap: f32 = try worldArrayGap(
        gpa,
        &on_device,
        &twin,
        arrays.actions.offset,
        arrays.actions.stride,
        world_count,
    );
    return .{
        .{ .array_name = "policy_inputs", .gap_epsilons = inputs_gap, .bar_epsilons = bars.policy_inputs },
        .{ .array_name = "chosen_actions", .gap_epsilons = chosen_gap, .bar_epsilons = bars.chosen_actions },
        .{ .array_name = "actions", .gap_epsilons = actions_gap, .bar_epsilons = bars.actions },
    };
}

/// The bar of the ring's comparison, in epsilons at a record's scale: a record in the ring is a simulator's record
/// row, so the bar is the records' of the inputs check (`PolicyInputsBars.records`).
const RingBars = struct {
    ring: f32 = 16,
};

/// What `runRobotgpuRecordsIntoRing` measured.
const RingOutcome = struct {
    /// The two rings' gap, slot for slot over the whole ring - the slots no decision wrote among them.
    gap: MeasuredGap,
    /// How many records of the device kit's ring hold a table row, and how many the decisions should have left.
    records_in_the_device_ring: u32,
    records_expected: u32,
    /// Whether the books kept from the device's flags are the books kept from the twin's, array for array; and how
    /// many stretches of unbroken motion the decisions started past each world's first.
    books_alike: bool,
    stretches_started: u32,
    /// The device's dispatches over a decision - its acting, its record and its physics - on average.
    dispatches_per_decision: f32,
};

/// A STEP's RECORDS INTO THE LEARNER's RING BY ONE COPY ON THE GPU (`RecordRing.appendFromSimulator`), against the
/// host's own way with the twin's rows (`Resident.uploadStep`):
///
///     the device    record_rows   ->   one copy on the GPU               ->   the GPU kit's ring
///     the twin      record_rows   ->   read back, uploaded by the host   ->   a CPU kit's ring
///
/// Both rings are laid out for the simulator's action (`initWithActions`), on the tracking check's scene. At each of
/// twelve decisions the twin is given known actions, the device takes the twin's worlds whole, both observe and pack
/// their records, and each ring takes the step its own way; then BOTH live the decision. The decisions' indices run
/// across the ring's end - its last six slots, then its first six - so the copy's destination is checked where the
/// ring wraps. The two rings are then read back whole and compared.
///
/// THE BOOKS, each side's from its own flags. Before each decision's records, each side's books take every world's
/// moment (`recordMomentsFrom`) from that side's own counters, as its own last decision left them - read before the
/// device is given the twin's worlds again, which would overwrite its counters with the twin's. The two books must be
/// the same, array for array: the same stretches, steps and rows after the loss. The fleet pushes at every decision
/// and two characters start knocked off their reference, so stretches start - asserted.
fn runRobotgpuRecordsIntoRing(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    bars: RingBars,
) !RingOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const world_count: u32 = 8;
    const physics_steps: u32 = 2;
    // THE SCENE, as the tracking check's.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        world_count,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer twin.deinit();
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{});
    try on_device.setTracking(gpa, settings);
    try twin.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    try twin.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    try expect(clip.frame_count > starts.lastFrameReached());
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &twin, starts, tables.poses, model.coordinate_count, still);
    // ONE RING ON TWO PIPES, each laid out for the simulator's action: the GPU's beside the simulator, a CPU's for
    // the twin's rows. Laid out after some floats of other use, with room for a few windows' starts.
    const Ring: type = z.robot_latent_kit.Resident(zn_mlp);
    var device_kit_pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer device_kit_pipe.deinit();
    var twin_kit_pipe: z.Compute(zn_mlp) = .initCpu();
    defer twin_kit_pipe.deinit();
    const ring_start: u32 = 1000;
    const window_rows: u32 = 4;
    const start_slots: u32 = 2;
    const action_count: u32 = twin.counts.action_count;
    var device_ring: Ring = try .initWithActions(
        gpa,
        &device_kit_pipe,
        fleet,
        ring_start,
        window_rows,
        start_slots,
        action_count,
    );
    defer device_ring.deinit();
    var twin_ring: Ring = try .initWithActions(
        gpa,
        &twin_kit_pipe,
        fleet,
        ring_start,
        window_rows,
        start_slots,
        action_count,
    );
    defer twin_ring.deinit();
    const records: @FieldType(robotgpu.WorldStateLayout, "records") = twin.layout.world_f.records;
    // Every world's records as read from the twin, and the worlds' arenas for the device's copy of them.
    const twin_rows: []f32 = try gpa.alloc(f32, world_count * records.stride);
    defer gpa.free(twin_rows);
    const twin_floats: []f32 = try gpa.alloc(f32, twin.worldArenaEnd(.world_f));
    defer gpa.free(twin_floats);
    const twin_integers: []u32 = try gpa.alloc(u32, twin.worldArenaEnd(.world_u));
    defer gpa.free(twin_integers);
    const actions_row: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(actions_row);
    // THE BOOKS, one a side, as long as the rings; each side's moments, and the device's integers to read them from.
    const Books: type = z.robot_track.KeptBooks;
    var device_books: Books = try .init(gpa, world_count, device_ring.ring.capacity);
    defer device_books.deinit(gpa);
    var twin_books: Books = try .init(gpa, world_count, twin_ring.ring.capacity);
    defer twin_books.deinit(gpa);
    const device_moments: []z.robot.RecordMoment = try gpa.alloc(z.robot.RecordMoment, world_count);
    defer gpa.free(device_moments);
    const twin_moments: []z.robot.RecordMoment = try gpa.alloc(z.robot.RecordMoment, world_count);
    defer gpa.free(twin_moments);
    const device_integers: []u32 = try gpa.alloc(u32, on_device.worldArenaEnd(.world_u));
    defer gpa.free(device_integers);
    // THE DECISIONS, their indices across the ring's end.
    const decision_count: u32 = 12;
    const first_index: u64 = device_ring.ring.capacity - decision_count / 2;
    const dispatches_before: u64 = dispatchesSoFar(&on_device);
    var decision: u32 = 0;
    while (decision < decision_count) : (decision += 1) {
        const index: u64 = first_index + decision;
        // Each side's books, from its own counters as its last decision left them.
        try readWorldIntegers(gpa, &twin, 0, twin_integers);
        try readWorldIntegers(gpa, &on_device, 0, device_integers);
        const no_plans: ?u32 = null;
        robotgpu_host.recordMomentsFrom(twin.layout.world_u, 0, twin_integers, no_plans, twin_moments);
        robotgpu_host.recordMomentsFrom(on_device.layout.world_u, 0, device_integers, no_plans, device_moments);
        twin_books.appendStep(twin_moments);
        device_books.appendStep(device_moments);
        uploadTrackingActions(&twin, world_count, decision, actions_row);
        // One state on both, then each observes and packs its records - where a fleet's step records.
        try giveDeviceTheTwinsWorlds(gpa, &twin, &on_device, twin_floats, twin_integers);
        on_device.submitDispatches(&robotgpu.observe_program);
        twin.submitDispatches(&robotgpu.observe_program);
        on_device.submitDispatches(&robotgpu.record_program);
        twin.submitDispatches(&robotgpu.record_program);
        // The device's step into its ring: one copy on the GPU.
        device_ring.ring.appendFromSimulator(
            device_kit_pipe.deviceField(.ring),
            index,
            on_device.pipe.deviceField(.world_f),
            records.offset,
            records.stride,
        );
        // The twin's step into its ring: read back, uploaded by the host.
        try readWorldFloats(gpa, &twin, records.offset, twin_rows);
        twin_ring.uploadStep(index, twin_rows);
        const clock: robotgpu.DecisionClock = .{ .number = decision + 1, .push_top_share = 1.0 };
        twin.stepDecision(physics_steps, clock);
        on_device.stepDecision(physics_steps, clock);
    }
    const dispatches: u64 = dispatchesSoFar(&on_device) - dispatches_before;
    const dispatches_per_decision: f32 = float(dispatches) / float(decision_count);
    // THE TWO BOOKS, array for array.
    const segments_alike: bool = eql(u32, device_books.segments, twin_books.segments);
    const steps_alike: bool = eql(?u32, device_books.episode_steps, twin_books.episode_steps);
    const after_loss_alike: bool = eql(bool, device_books.after_loss, twin_books.after_loss);
    const written_alike: bool = eql(u64, device_books.written, twin_books.written);
    const books_alike: bool = segments_alike and steps_alike and after_loss_alike and written_alike;
    // Ids from `world_count` on are stretches begun after each world's first.
    const stretches_started: u32 = twin_books.next_segment - world_count;
    // THE TWO RINGS, whole.
    const record: u32 = device_ring.ring.record;
    const ring_floats: usize = device_ring.ring.capacity * device_ring.ring.envs * record;
    const device_ring_floats: []f32 = try gpa.alloc(f32, ring_floats);
    defer gpa.free(device_ring_floats);
    const twin_ring_floats: []f32 = try gpa.alloc(f32, ring_floats);
    defer gpa.free(twin_ring_floats);
    // The device kit's ring is read from its buffer itself. The kit's module is read through its mirror, which is
    // refreshed after the kit's own dispatches - and none ran: the ring was written by copies from the simulator.
    const float_bytes: usize = @sizeOf(f32);
    const ring_first_byte: usize = device_ring.ring.at * float_bytes;
    const kit_ring_bytes: []u8 = try gpa.alloc(u8, ring_first_byte + ring_floats * float_bytes);
    defer gpa.free(kit_ring_bytes);
    const kit_ring_buffer: wgpu.BufferHandle = device_kit_pipe.deviceField(.ring).buffer;
    try expect(readBufferInto(device, queue, kit_ring_buffer, kit_ring_bytes));
    @memcpy(sliceAsBytes(device_ring_floats), kit_ring_bytes[ring_first_byte..]);
    twin_kit_pipe.readRange(.ring, twin_ring.ring.at, twin_ring_floats);
    // A record that was written holds its table row, which is never zero here: every world starts past its clip's
    // first frames.
    const feature_count: u32 = @intCast(z.robot_track.localSize(model.body_count));
    const table_row_at: u32 = zn_mlp.latRecordTableRow(feature_count, action_count);
    var records_in_the_device_ring: u32 = 0;
    var record_start: usize = 0;
    while (record_start < ring_floats) : (record_start += record) {
        const table_row: f32 = device_ring_floats[record_start + table_row_at];
        if (table_row != 0) {
            records_in_the_device_ring += 1;
        }
    }
    return .{
        .gap = .{
            .array_name = "the ring",
            .gap_epsilons = robotgpu_host.largestGapEpsilons(device_ring_floats, twin_ring_floats, record),
            .bar_epsilons = bars.ring,
        },
        .records_in_the_device_ring = records_in_the_device_ring,
        .records_expected = decision_count * world_count,
        .books_alike = books_alike,
        .stretches_started = stretches_started,
        .dispatches_per_decision = dispatches_per_decision,
    };
}

/// What `runRobotgpuTrainerOnDevice` found.
const TrainerOnDeviceOutcome = struct {
    /// Decisions driven, and the records each world's books hold - one a decision.
    decisions: u32,
    books_records_short: u32,
    /// Stretches of unbroken motion begun past each world's first: pushes and new episodes reached the books.
    stretches_started: u32,
    /// The ring's first and latest index: every decision's records arrived, in order, from the first.
    ring_first: ?u64,
    ring_latest: ?u64,
    /// How many of the device's given actions are not finite after the last decision.
    actions_not_finite: u32,
    /// Whether the trainer drew a batch of windows from what its books and ring hold.
    windows_drawn: bool,
    /// Whether the ring's newest step is the characters' record block, to the bit - not the batch's first worlds',
    /// which, with candidates in front of the characters, begin with the candidates' blocks.
    ring_holds_the_characters: bool,
    /// Whether the candidates in front of the characters were left exactly as they were - every coordinate, to the bit
    /// - by the decisions: a decision runs over the characters alone (`Counts.first_world`). True with no candidates.
    candidates_untouched: bool,
    /// The trainer's counts - decisions at risk and losses of the reference - and the same counted by the check
    /// from each decision's flags, read by itself. Everything the check counts itself is counted with one decision a
    /// call only (`TrainerCalls`), and is zero otherwise.
    exposure: u64,
    failures: u64,
    expected_exposure: u64,
    expected_failures: u64,
    /// THE PUSHES AND THEIR WATCHES (`robot.PushBrake`). As the host counted them from the decisions' flags
    /// (`robotgpu_host.DeviceEvents`), with its sum of the pushes' speeds; as the check counted them from the same
    /// flags, read by itself; and as the trainer's fleet holds the watches' ends, told each by the host.
    host_events: robotgpu_host.DeviceEvents,
    expected_pushes: u64,
    expected_watched_settled: u64,
    expected_watched_came_back: u64,
    fleet_watched_settled: u64,
    fleet_watched_came_back: u64,
    /// The pushes' speeds summed by the check: each pushed world's speed drawn again at the number the check gave the
    /// decision it was pushed in.
    expected_push_speed_sum: f64,
};

/// HOW A TRAINER-ON-THE-DEVICE CHECK MAKES ITS 40 DECISIONS (`runRobotgpuTrainerOnDevice`).
const TrainerCalls = enum {
    /// One decision a call. After each, the check reads the worlds' flags itself and counts what the decision did:
    /// what the host's counts are held against.
    one_decision_each,
    /// Calls of 1, 7, 2, 10 and 20 decisions, as a round's acting is one call of many. Within a call the host counts
    /// a decision at the next one's read, and the call's last at a read of its own; the worlds' flags last a
    /// decision, so the check cannot count them - its totals are held against the other pattern's.
    of_several_lengths,
};

/// A TRAINER DRIVEN ON THE DEVICE (`Sim.actTrainerOnDevice`): the learner of a SuperTrack run on a GPU kit pipe,
/// Geno's worlds on the GPU's simulator, nothing simulated on the CPU. The trainer accepts device acting for the
/// simulator's worlds, the worlds start as the tracking check's do (two knocked off their reference), and forty
/// decisions are driven - its policy acting, every record copied into its ring on the GPU, its books kept from the
/// device's flags. What must follow: the books hold every decision, stretches began (episodes ending, the knocked
/// characters' first), the ring holds every decision from the first, no action given is non-finite, and the trainer
/// can draw its windows from them. Whether those windows hold the same numbers as a CPU-fed learner's is the next
/// check's question; this one is of the loop's wiring.
///
/// THE HOST's COUNTS are part of that wiring: the decisions at risk and the losses the trainer keeps, the pushes and
/// their speeds, the returns, and the watched pushes' ends the brake reads - each counted from a decision's flags
/// (`robotgpu_host.countTrainerDecisions`). The decisions are made in the pattern `calls` names; with one decision
/// a call the check counts the same events from the flags it reads itself.
fn runRobotgpuTrainerOnDevice(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    candidate_count: u32,
    calls: TrainerCalls,
) !TrainerOnDeviceOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    // The trainer's characters, after `candidate_count` candidates at the batch's start.
    const world_count: u32 = 8;
    const first_world: u32 = candidate_count;
    const simulated_worlds: u32 = candidate_count + world_count;
    const physics_steps: u32 = 2;
    // THE SCENE, as the tracking check's.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        simulated_worlds,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    // PUSHES ON A SCHEDULE: one every twelve decisions of an episode, none at random - half of them watched for three
    // decisions by the brake (`robot.PushBrake`). The tracking check's push at every decision cuts every stretch to
    // one record, shorter than any window, and a trainer then draws nothing.
    fleet.options.pushes.every = 12;
    fleet.options.pushes.rate_per_second = 0;
    fleet.options.pushes.brake.watch_seconds = 3 * fleet.decisionSeconds();
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{ .offsets = 0.25, .stiffness = 0.5 });
    try on_device.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(simulated_worlds);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &on_device, starts, tables.poses, model.coordinate_count, still);
    // THE CANDIDATES: copies of the first characters, never restarted or pushed. Their records are packed at each
    // decision as every world's, and no ring of the trainer's takes them.
    const sources: []?u32 = try gpa.alloc(?u32, simulated_worlds);
    defer gpa.free(sources);
    @memset(sources, null);
    for (sources[0..candidate_count], 0..) |*source, candidate| {
        source.* = first_world + @as(u32, @intCast(candidate));
    }
    try on_device.copyWorlds(gpa, sources);
    // THE TRAINER, on a kit pipe of the same device, with a normaliser of distinct numbers.
    var kit_pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer kit_pipe.deinit();
    const feature_count: usize = z.robot_track.localSize(model.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    for (means, spreads, 0..) |*mean, *spread, feature| {
        const position: f32 = float(feature);
        mean.* = 0.01 * position;
        spread.* = 0.5 + 0.001 * position;
    }
    const Trainer: type = z.robot_track_resident.Resident(zn_mlp);
    const normalizer: z.robot_latent.Normalizer = .{ .mean = means, .spread = spreads };
    const trainer: *Trainer = try .init(gpa, &kit_pipe, fleet, normalizer, .{
        .rows = 4,
        .window = 4,
        .hidden = 16,
        .policy_hidden = 16,
        .collect = 4,
    });
    defer trainer.deinit();
    const arrays: robotgpu.WorldStateLayout = on_device.layout.world_f;
    try trainer.acceptDeviceActing(first_world, world_count, arrays.policy_inputs.stride, arrays.actions.stride);
    // THE DECISIONS, 40 of them in either pattern of calls (`TrainerCalls`), numbered from 1 across the calls.
    const one_decision_each: [40]u32 = @splat(1);
    const several_lengths = [_]u32{ 1, 7, 2, 10, 20 };
    const call_lengths: []const u32 = switch (calls) {
        .one_decision_each => &one_decision_each,
        .of_several_lengths => &several_lengths,
    };
    const exploration_spread: f32 = 0.3;
    // THE CANDIDATES' COORDINATES before the decisions, to be held against theirs after: no decision runs over them.
    const state_layout: robotgpu.WorldStateLayout = on_device.layout.world_f;
    const coordinates: @FieldType(robotgpu.WorldStateLayout, "joint_positions") = state_layout.joint_positions;
    const candidate_floats: usize = candidate_count * coordinates.stride;
    const candidates_before: []f32 = try gpa.alloc(f32, candidate_floats);
    defer gpa.free(candidates_before);
    const candidates_after: []f32 = try gpa.alloc(f32, candidate_floats);
    defer gpa.free(candidates_after);
    if (candidate_count > 0) {
        try readWorldFloats(gpa, &on_device, coordinates.at(0, 0), candidates_before);
    }
    var decision_count: u32 = 0;
    var expected_exposure: u64 = 0;
    var expected_failures: u64 = 0;
    var expected_pushes: u64 = 0;
    var expected_watched_settled: u64 = 0;
    var expected_watched_came_back: u64 = 0;
    var expected_push_speed_sum: f64 = 0;
    var device_events: robotgpu_host.DeviceEvents = .{};
    const integers: []u32 = try gpa.alloc(u32, on_device.worldArenaEnd(.world_u));
    defer gpa.free(integers);
    const counters: robotgpu.WorldIntegersLayout = on_device.layout.world_u;
    // The pushes' settings as the simulator holds them, and how far the fleet's top is open.
    const push_options: robotgpu.StepOptions = on_device.pipe.params.options;
    const push_top_share: f32 = fleet.pushTopShare();
    for (call_lengths) |call_length| {
        const first_decision_number: u32 = 1 + decision_count;
        try on_device.actTrainerOnDevice(
            zn_mlp,
            gpa,
            trainer,
            call_length,
            first_decision_number,
            physics_steps,
            .{ .exploration_spread = exploration_spread, .flow_scale = 1 },
            null,
            &device_events,
        );
        decision_count += call_length;
        if (calls != .one_decision_each) {
            continue;
        }
        // THE DECISION JUST MADE, COUNTED BY THE CHECK from the flags it reads itself. A pushed world's speed is
        // drawn again at the number the check gave the decision, the clock the device drew it at.
        try readWorldIntegers(gpa, &on_device, 0, integers);
        var counted_world: u32 = 0;
        while (counted_world < world_count) : (counted_world += 1) {
            const world: u32 = first_world + counted_world;
            const flags: u32 = integers[counters.episode_flags.at(world, 0)];
            const lost: bool = flags & robotgpu.episodeFlagBit(.lost) != 0;
            const in_aftermath: bool = flags & robotgpu.episodeFlagBit(.in_aftermath) != 0;
            if (!in_aftermath) {
                expected_exposure += 1;
            }
            if (lost) {
                expected_failures += 1;
            }
            const watch_settled: bool = flags & robotgpu.episodeFlagBit(.watched_push_settled) != 0;
            const watch_came_back: bool = flags & robotgpu.episodeFlagBit(.watched_push_came_back) != 0;
            expected_watched_settled += @intFromBool(watch_settled);
            expected_watched_came_back += @intFromBool(watch_came_back);
            const pushed: bool = flags & robotgpu.episodeFlagBit(.pushed) != 0;
            if (!pushed) {
                continue;
            }
            expected_pushes += 1;
            const speed_draw: f32 = z.robot.drawUniform(
                push_options.draw_seed,
                world,
                first_decision_number,
                .push_speed,
                0,
            );
            const speed: f32 = z.robot.pushSpeed(
                push_options.push_speed_min,
                push_options.push_speed_max,
                push_top_share,
                speed_draw,
            );
            expected_push_speed_sum += speed;
        }
    }
    try expectEqual(@as(u32, 40), decision_count);
    if (candidate_count > 0) {
        try readWorldFloats(gpa, &on_device, coordinates.at(0, 0), candidates_after);
    }
    const candidates_untouched: bool = eql(f32, candidates_before, candidates_after);
    const books: z.robot_track.KeptBooks = trainer.device_acting.?.books;
    var books_records_short: u32 = 0;
    for (books.written) |written| {
        if (written != decision_count) {
            books_records_short += 1;
        }
    }
    // The device's given actions after the last decision.
    const action_floats: []f32 = try gpa.alloc(f32, arrays.actions.stride * world_count);
    defer gpa.free(action_floats);
    try readWorldFloats(gpa, &on_device, arrays.actions.at(first_world, 0), action_floats);
    var actions_not_finite: u32 = 0;
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        var number: u32 = 0;
        while (number < on_device.counts.action_count) : (number += 1) {
            const given: f32 = action_floats[world * arrays.actions.stride + number];
            if (!isFinite(given)) {
                actions_not_finite += 1;
            }
        }
    }
    const windows_drawn: bool = trainer.drawWindows(0, .anywhere);
    // THE RING's LAST STEP AGAINST THE CHARACTERS' RECORD BLOCK: the records stay where the last decision packed them
    // (its physics writes none), so the ring's newest slot must be the characters' block, to the bit - not the
    // first worlds', whose blocks the decision packed too.
    const records: @FieldType(robotgpu.WorldStateLayout, "records") = arrays.records;
    const step_floats: usize = world_count * records.stride;
    const characters_records: []f32 = try gpa.alloc(f32, step_floats);
    defer gpa.free(characters_records);
    try readWorldFloats(gpa, &on_device, records.at(first_world, 0), characters_records);
    const ring: *const z.robot_latent_kit.RecordRing = &trainer.data.ring;
    const newest_index: u64 = ring.appended.?;
    const newest_slot: u64 = newest_index % ring.capacity;
    const float_bytes: usize = @sizeOf(f32);
    const ring_step_byte: usize = (ring.at + newest_slot * step_floats) * float_bytes;
    const ring_bytes: []u8 = try gpa.alloc(u8, ring_step_byte + step_floats * float_bytes);
    defer gpa.free(ring_bytes);
    try expect(readBufferInto(device, queue, kit_pipe.deviceField(.ring).buffer, ring_bytes));
    const ring_step: []const u8 = ring_bytes[ring_step_byte..];
    const ring_holds_the_characters: bool = eql(u8, ring_step, sliceAsBytes(characters_records));
    return .{
        .ring_holds_the_characters = ring_holds_the_characters,
        .candidates_untouched = candidates_untouched,
        .decisions = decision_count,
        .books_records_short = books_records_short,
        .stretches_started = books.next_segment - world_count,
        .ring_first = trainer.data.ring.first_appended,
        .ring_latest = trainer.data.ring.appended,
        .actions_not_finite = actions_not_finite,
        .windows_drawn = windows_drawn,
        .exposure = trainer.exposure,
        .failures = trainer.failures,
        .expected_exposure = expected_exposure,
        .expected_failures = expected_failures,
        .host_events = device_events,
        .expected_pushes = expected_pushes,
        .expected_watched_settled = expected_watched_settled,
        .expected_watched_came_back = expected_watched_came_back,
        .fleet_watched_settled = fleet.watched_pushes_settled,
        .fleet_watched_came_back = fleet.watched_pushes_came_back,
        .expected_push_speed_sum = expected_push_speed_sum,
    };
}

/// What `runRobotgpuTrainerFedTwoWays` found.
const TrainerFedTwoWaysOutcome = struct {
    /// Whether the two trainers' weights - every parameter but the world model's running statistics - were the same,
    /// bit for bit, before training; and where the first that differed was, when one did.
    started_alike: bool,
    first_start_difference: ?usize,
    /// How far apart the world model's running statistics were before training, beside its bar: the fold that writes
    /// them at init (`Resident.writeWorldStatistics`) divides and takes square roots on each trainer's own pipe -
    /// IEEE on the CPU twin, within a few ulps on a GPU - so they agree to rounding, not to the bit.
    statistics_at_start: MeasuredGap,
    /// How far apart their parameters are after one round, in epsilons of the largest parameter, beside its bar.
    parameters: MeasuredGap,
    /// Each trainer's updates made and windows refused in the round.
    device_fed_updates: u64,
    cpu_fed_updates: u64,
    windows_refused: u64,
};

/// A trainer's parameters - every weight of its world model and its policy - read from its kit's buffer.
fn readTrainerParameters(
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    trainer: *z.robot_track_resident.Resident(zn_mlp),
    out_parameters: []f32,
) !void {
    const parameters_buffer: wgpu.BufferHandle = trainer.kit.pipe.deviceField(.params).buffer;
    try expect(readBufferInto(device, queue, parameters_buffer, sliceAsBytes(out_parameters)));
}

/// ONE TRAINER's DATA GIVEN TO ANOTHER, so both learn from the same records and draw the same windows: every step
/// the source's ring still holds, read back from its GPU kit and uploaded into the target's ring in order
/// (`uploadStep`), and the source's books copied whole. The source acts on the device; the target, of the same
/// options and on any pipe, has accepted device acting for the same worlds and holds nothing yet. A ring holds its
/// last `capacity` steps: a step at index `i` sits in slot `i mod capacity`, every world's record side by side.
fn giveTrainerDataTo(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    source: *z.robot_track_resident.Resident(zn_mlp),
    target: *z.robot_track_resident.Resident(zn_mlp),
) !void {
    const RecordRing: type = z.robot_latent_kit.RecordRing;
    const held: RecordRing.HeldSteps = source.data.ring.held() orelse return error.SourceHoldsNothing;
    const capacity: u64 = source.data.ring.capacity;
    const world_count: usize = source.data.ring.envs;
    const record: u32 = source.data.ring.record;
    const step_floats: usize = world_count * record;
    // The source's whole ring, read from its kit's replay buffer.
    const float_bytes: usize = @sizeOf(f32);
    const ring_first_byte: usize = source.data.ring.at * float_bytes;
    const ring_floats_count: usize = capacity * step_floats;
    const ring_bytes: []u8 = try gpa.alloc(u8, ring_first_byte + ring_floats_count * float_bytes);
    defer gpa.free(ring_bytes);
    const ring_buffer: wgpu.BufferHandle = source.kit.pipe.deviceField(.ring).buffer;
    try expect(readBufferInto(device, queue, ring_buffer, ring_bytes));
    const ring_floats: []f32 = try gpa.alloc(f32, ring_floats_count);
    defer gpa.free(ring_floats);
    @memcpy(sliceAsBytes(ring_floats), ring_bytes[ring_first_byte..]);
    // Every held step into the target's ring, oldest first.
    var step_index: u64 = held.first;
    while (step_index <= held.last) : (step_index += 1) {
        const slot: u64 = step_index % capacity;
        const step_records: []const f32 = ring_floats[slot * step_floats ..][0..step_floats];
        target.data.uploadStep(step_index, step_records);
    }
    // The books, copied whole.
    const source_books: z.robot_track.KeptBooks = source.device_acting.?.books;
    const target_books: *z.robot_track.KeptBooks = &target.device_acting.?.books;
    target_books.copyFrom(source_books);
}

/// THE SAME LEARNING FROM THE DEVICE's DATA AS FROM THE HOST's: one trainer fed by the device, one fed on the CPU
/// with the same records and the same books, one round of training on each - their parameters must agree.
///
///     device-fed   a GPU kit pipe; driven on the device (`actTrainerOnDevice`): its ring by copies on the GPU, its
///                  books from the device's flags
///     CPU-fed      a CPU kit pipe; the device-fed trainer's ring read back and uploaded step by step
///                  (`uploadStep`), its books copied
///
/// Both trainers have the same options and seed, so they start from the same weights - checked, bit for bit, and the
/// world model's running statistics, which each pipe's fold writes, to rounding - and draw the same windows from the
/// same books. One round (`train`): a world-model update, then a policy update. What
/// differs between them afterwards is only how a GPU and a CPU round the same arithmetic. A record placed in the
/// wrong slot, a book kept wrong, or a window gathered from the wrong rows would set them far apart. With
/// `root_target`, the policy's goal carries the root target: the device acts on it, and the policy's update moves
/// the root through its rollout (`LatentKit.imagined_root`) - on the device's kernels for one trainer, the CPU's
/// for the other.
fn runRobotgpuTrainerFedTwoWays(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    parameters_bar: f32,
    statistics_bar: f32,
    root_target: bool,
) !TrainerFedTwoWaysOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const world_count: u32 = 8;
    const physics_steps: u32 = 2;
    // THE SCENE, as the trainer-on-the-device check's: a night's pushes, so windows exist.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        world_count,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    fleet.options.pushes.every = 90;
    fleet.options.pushes.rate_per_second = 0;
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{ .offsets = 0.25, .stiffness = 0.5 });
    try on_device.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &on_device, starts, tables.poses, model.coordinate_count, still);
    // THE TWO TRAINERS: the same options and seed, a normaliser of distinct numbers.
    const feature_count: usize = z.robot_track.localSize(model.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    for (means, spreads, 0..) |*mean, *spread, feature| {
        const position: f32 = float(feature);
        mean.* = 0.01 * position;
        spread.* = 0.5 + 0.001 * position;
    }
    const normalizer: z.robot_latent.Normalizer = .{ .mean = means, .spread = spreads };
    const Trainer: type = z.robot_track_resident.Resident(zn_mlp);
    const trainer_options: z.robot_track_resident.Options = .{
        .rows = 4,
        .window = 4,
        .hidden = 16,
        .policy_hidden = 16,
        .collect = 4,
        .world_updates = 1,
        .policy_updates = 1,
        .root_target = root_target,
    };
    var device_kit_pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer device_kit_pipe.deinit();
    var cpu_kit_pipe: z.Compute(zn_mlp) = .initCpu();
    defer cpu_kit_pipe.deinit();
    const device_fed: *Trainer = try .init(gpa, &device_kit_pipe, fleet, normalizer, trainer_options);
    defer device_fed.deinit();
    const cpu_fed: *Trainer = try .init(gpa, &cpu_kit_pipe, fleet, normalizer, trainer_options);
    defer cpu_fed.deinit();
    const arrays: robotgpu.WorldStateLayout = on_device.layout.world_f;
    const input_stride: u32 = arrays.policy_inputs.stride;
    const action_stride: u32 = arrays.actions.stride;
    try device_fed.acceptDeviceActing(0, world_count, input_stride, action_stride);
    try cpu_fed.acceptDeviceActing(0, world_count, input_stride, action_stride);
    // THEIR STARTING WEIGHTS, bit for bit.
    const parameter_count: usize = device_fed.params_end;
    const device_fed_parameters: []f32 = try gpa.alloc(f32, parameter_count);
    defer gpa.free(device_fed_parameters);
    const cpu_fed_parameters: []f32 = try gpa.alloc(f32, parameter_count);
    defer gpa.free(cpu_fed_parameters);
    try readTrainerParameters(device, queue, device_fed, device_fed_parameters);
    cpu_kit_pipe.readRange(.params, 0, cpu_fed_parameters);
    // The weights before the statistics and after them, bit for bit; the statistics to rounding.
    const statistics_start: usize = device_fed.input_moments_at;
    const statistics_end: usize = statistics_start + device_fed.world_statistics_count;
    var first_start_difference: ?usize = null;
    for (device_fed_parameters, cpu_fed_parameters, 0..) |device_number, cpu_number, index| {
        const in_statistics: bool = index >= statistics_start and index < statistics_end;
        const differs: bool = @as(u32, @bitCast(device_number)) != @as(u32, @bitCast(cpu_number));
        if (differs and !in_statistics) {
            first_start_difference = index;
            break;
        }
    }
    const started_alike: bool = first_start_difference == null;
    const statistics_gap: f32 = robotgpu_host.largestGapEpsilons(
        device_fed_parameters[statistics_start..statistics_end],
        cpu_fed_parameters[statistics_start..statistics_end],
        0,
    );
    // THE DEVICE-FED TRAINER's DATA: thirty decisions on the device - fewer than the ring holds, so no slot is
    // written twice.
    const decision_count: u32 = 30;
    try expect(decision_count < device_fed.data.ring.capacity);
    var device_events: robotgpu_host.DeviceEvents = .{};
    try on_device.actTrainerOnDevice(
        zn_mlp,
        gpa,
        device_fed,
        decision_count,
        1,
        physics_steps,
        .{ .exploration_spread = 0.3, .flow_scale = 1 },
        null,
        &device_events,
    );
    // THE CPU-FED TRAINER's DATA: the device-fed trainer's ring and books.
    try giveTrainerDataTo(gpa, device, queue, device_fed, cpu_fed);
    // ONE ROUND OF TRAINING EACH, then their parameters.
    device_fed.train();
    cpu_fed.train();
    try readTrainerParameters(device, queue, device_fed, device_fed_parameters);
    cpu_kit_pipe.readRange(.params, 0, cpu_fed_parameters);
    const parameters_gap: f32 = robotgpu_host.largestGapEpsilons(device_fed_parameters, cpu_fed_parameters, 0);
    return .{
        .started_alike = started_alike,
        .first_start_difference = first_start_difference,
        .statistics_at_start = .{
            .array_name = "the world model's running statistics at the start",
            .gap_epsilons = statistics_gap,
            .bar_epsilons = statistics_bar,
        },
        .parameters = .{ .array_name = "parameters", .gap_epsilons = parameters_gap, .bar_epsilons = parameters_bar },
        .device_fed_updates = device_fed.world_updates + device_fed.policy_updates,
        .cpu_fed_updates = cpu_fed.world_updates + cpu_fed.policy_updates,
        .windows_refused = device_fed.windows_refused + cpu_fed.windows_refused,
    };
}

/// SEVERAL EXPECTATIONS OF ONE MEASUREMENT, EACH LOOKED AT: one that does not hold is printed under the
/// measurement's name and counted, and the ones after it are still looked at - a run shows every expectation that
/// fails, not the first alone. `finish` fails the test if any did.
const Expectations = struct {
    of: []const u8,
    failed: u32 = 0,

    fn holds(
        expectations: *Expectations,
        condition: bool,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (condition) {
            return;
        }
        print("vk-host-test: {s}: does not hold - " ++ format ++ "\n", .{expectations.of} ++ args);
        expectations.failed += 1;
    }

    fn finish(expectations: Expectations) !void {
        try expectEqual(@as(u32, 0), expectations.failed);
    }
};

/// THE DEVICE's TIME BY PHASE OF A TRAINING ROUND (`z.robot.RoundPhase`), read from the timed pipes of one device
/// (`Compute.readTimings`): each read adds its pipe's segments to the same sums, as a trainer's round does with its
/// simulator's pipe and its learner's.
const PhaseTimes = struct {
    microseconds: [z.robot.RoundPhase.count]f64 = @splat(0),
    segments: [z.robot.RoundPhase.count]u32 = @splat(0),
    /// The dispatches no segment covered, over the pipes read.
    untimed_dispatches: u32 = 0,
    /// From the earliest first mark among the pipes read to the latest last mark, on the device's clock
    /// (`z.timingsSpanMicroseconds`).
    span_microseconds: f64 = 0,
    /// What each read covered: two pipes at most.
    reads: [2]z.TimingsRead = @splat(.{}),
    reads_made: usize = 0,

    /// One pipe's timings since its last read, added. Waits for the device.
    fn readFrom(
        times: *PhaseTimes,
        comptime M: type,
        pipe: *z.Compute(M),
    ) void {
        const read: z.TimingsRead = pipe.readTimings(&times.microseconds, &times.segments, &.{}, &.{});
        times.reads[times.reads_made] = read;
        times.reads_made += 1;
        times.untimed_dispatches += read.untimed_dispatches;
        times.span_microseconds = z.timingsSpanMicroseconds(times.reads[0..times.reads_made]);
    }

    /// One pipe's timings since its last read, alone.
    fn ofPipe(comptime M: type, pipe: *z.Compute(M)) PhaseTimes {
        var times: PhaseTimes = .{};
        times.readFrom(M, pipe);
        return times;
    }

    fn microsecondsOf(times: PhaseTimes, phase: z.robot.RoundPhase) f64 {
        return times.microseconds[@backingInt(phase)];
    }

    fn segmentsOf(times: PhaseTimes, phase: z.robot.RoundPhase) u32 {
        return times.segments[@backingInt(phase)];
    }

    /// Every phase's time together.
    fn sumMicroseconds(times: PhaseTimes) f64 {
        var sum: f64 = 0;
        for (times.microseconds) |microseconds| {
            sum += microseconds;
        }
        return sum;
    }

    /// Every segment timed, over the pipes read.
    fn segmentsTimed(times: PhaseTimes) u32 {
        var timed: u32 = 0;
        for (times.reads[0..times.reads_made]) |read| {
            timed += read.segments;
        }
        return timed;
    }

    /// The round's line for these times and `clock`, which the caller has ended (`lab.RoundTimeLog.lineOf`).
    fn lineWith(times: PhaseTimes, clock: z.robot.PhaseClock) z.robot_lab.RoundTimeLog.Line {
        const measured: z.robot_lab.RoundTimeLog.Measured = .{
            .round = 1,
            .training_minutes = 0,
            .between_rounds_ms = 0,
            .gpu_microseconds = times.microseconds,
            .gpu_segments = times.segments,
            .gpu_span_microseconds = times.span_microseconds,
            .clock = clock,
            .submissions = 0,
            .dispatches = 0,
            .untimed_dispatches = times.untimed_dispatches,
        };
        return z.robot_lab.RoundTimeLog.lineOf(measured);
    }
};

/// A STRETCH OF A TRAINER's WORK, TIMED AS A ROUND IS: the device's time by phase over the stretch's pipes, the
/// host's clock the simulator and the learner told the phases, and how the calls left the phase.
const MeasuredPhases = struct {
    device: PhaseTimes = .{},
    clock: z.robot.PhaseClock = .{},
    /// The calls that left the host's clock or one of the pipes in a phase other than `other`: a call's phases end
    /// with it, so what the host does next is not counted under the call's last phase.
    calls_ending_elsewhere: u32 = 0,

    /// Whether the clock and the pipes' phases (`Compute.phase`) are all `other`.
    fn leftInOther(clock: z.robot.PhaseClock, pipe_phases: []const u32) bool {
        if (clock.phase != .other) {
            return false;
        }
        for (pipe_phases) |pipe_phase| {
            if (pipe_phase != @backingInt(z.robot.RoundPhase.other)) {
                return false;
            }
        }
        return true;
    }

    fn hostMsOf(measured: MeasuredPhases, phase: z.robot.RoundPhase) f64 {
        return measured.clock.host_ms[@backingInt(phase)];
    }

    fn waitMsOf(measured: MeasuredPhases, phase: z.robot.RoundPhase) f64 {
        return measured.clock.wait_ms[@backingInt(phase)];
    }

    /// THE PHASES THAT RAN, AND NO OTHER: each of `ran` with a segment or more for each of its `least_segments` and
    /// time on the device; every other phase with no segment and no time; no dispatch untimed; and the phases'
    /// times together within the span of the device's clock they were measured over - nothing counted twice. Each
    /// that does not hold is noted in `expectations`.
    fn expectDevicePhases(
        measured: MeasuredPhases,
        expectations: *Expectations,
        ran: []const z.robot.RoundPhase,
        least_segments: []const u32,
    ) void {
        const device: PhaseTimes = measured.device;
        expectations.holds(device.untimed_dispatches == 0, "{d} dispatches untimed", .{device.untimed_dispatches});
        for (ran, least_segments) |phase, least| {
            const segments: u32 = device.segmentsOf(phase);
            const microseconds: f64 = device.microsecondsOf(phase);
            const ran_on_device: bool = segments >= least and microseconds > 0;
            expectations.holds(ran_on_device, "{s} ran: {d} segments of {d} or more, {d:.0} microseconds", .{
                @tagName(phase),
                segments,
                least,
                microseconds,
            });
        }
        for (0..z.robot.RoundPhase.count) |phase_number| {
            const phase: z.robot.RoundPhase = @fromBackingInt(@intCast(phase_number));
            const did_run: bool = indexOfScalar(z.robot.RoundPhase, ran, phase) != null;
            if (did_run) {
                continue;
            }
            const segments: u32 = device.segmentsOf(phase);
            const microseconds: f64 = device.microsecondsOf(phase);
            const absent: bool = segments == 0 and microseconds == 0;
            expectations.holds(absent, "{s} did not run: {d} segments, {d:.0} microseconds", .{
                @tagName(phase),
                segments,
                microseconds,
            });
        }
        // A sum of segments against a difference of two marks: the same ticks, added in another order.
        const rounding_allowed: f64 = 1.0e-9 * device.span_microseconds;
        const sum_microseconds: f64 = device.sumMicroseconds();
        const within_span: bool = sum_microseconds <= device.span_microseconds + rounding_allowed;
        expectations.holds(within_span, "the phases' {d:.3} microseconds within their span of {d:.3}", .{
            sum_microseconds,
            device.span_microseconds,
        });
    }
};

/// A stretch's time by phase, printed for a long run of the checks: each phase's time on the device with its
/// segments, the host's time in it and its waits.
fn printPhases(label: []const u8, measured: MeasuredPhases) void {
    print("vk-host-test: {s}: {d:.1} ms on the device in a span of {d:.1} ms -", .{
        label,
        measured.device.sumMicroseconds() / 1000.0,
        measured.device.span_microseconds / 1000.0,
    });
    for (0..z.robot.RoundPhase.count) |phase_number| {
        const phase: z.robot.RoundPhase = @fromBackingInt(@intCast(phase_number));
        print(" {s} {d:.1} ms in {d} (host {d:.1}, waiting {d:.1})", .{
            @tagName(phase),
            measured.device.microsecondsOf(phase) / 1000.0,
            measured.device.segmentsOf(phase),
            measured.hostMsOf(phase),
            measured.waitMsOf(phase),
        });
    }
    print("\n", .{});
}

/// The smoke run's decisions, collected in one call, and its rounds of training on their data.
const smoke_decisions: u32 = 64;
const smoke_rounds: u32 = 16;

/// What `runRobotgpuTrainingSmoke` found: the world model's loss after each round that trained, in order, and
/// whether every parameter stayed finite.
const TrainingSmokeOutcome = struct {
    world_model_losses: [smoke_rounds]f32,
    /// The control's: a trainer given the same data whose world model does not learn, on the same windows.
    control_losses: [smoke_rounds]f32,
    rounds_trained: u32,
    parameters_not_finite: u32,
    /// The 64 decisions' one call timed as a round's acting is: both pipes by phase, and the host's clock.
    acting_phases: MeasuredPhases,
    /// The call's pushes and their watches, as the host counted them (`robotgpu_host.DeviceEvents`).
    acting_events: robotgpu_host.DeviceEvents,
    /// The rounds of training timed as a run's are: the trainer's kit pipe by phase and the host's clock, with the
    /// policy's updates among them.
    phases: MeasuredPhases,
    policy_updates: u64,
};

/// A SHORT TRAINING RUN ON THE DEVICE PATH, the learner at toy size: 64 decisions driven on the device
/// (`actTrainerOnDevice`) fill its ring and books; then rounds of training on that data (`train`: eight world-model
/// updates, one policy update), the world model's loss on its latest update read after each round from the
/// learner's numbers for the log (`DeviceStats`, in its parameter buffer). The data is collected first and then held:
/// a loss read while new decisions keep arriving measures each round's fresh batch and the data's drift - later
/// decisions hold more falls - as much as the model.
///
/// THE CONTROL. Each round's loss is measured on that round's batch of windows, and the batches differ more than an
/// update moves the model: a trainer whose world model does not learn at all shows nearly the same curve. So beside
/// the trainer stands a CONTROL - the same options and seed, its world model's learning rate zero - given the
/// trainer's data (`giveTrainerDataTo`). The two draw the same windows round after round, so their losses differ only
/// by what the trainer's world model has learned. Learning is the trainer's loss below the control's.
///
/// THE RUN's TIME. The decisions' call and the trainer's rounds are timed as a training run's are (`MeasuredPhases`):
/// the pipes' dispatches by the phase they were for, and the host's clock by the phase it was in.
fn runRobotgpuTrainingSmoke(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
) !TrainingSmokeOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const world_count: u32 = 8;
    const physics_steps: u32 = 2;
    // THE SCENE, as the trainer checks': a night's pushes.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        world_count,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    // The trainer check's pushes: one every twelve decisions of an episode, half of them watched for three. Here
    // they come inside one call of many decisions, where the host counts each decision at the next one's read - and
    // checks, at every watched push, that the draw it makes again is the device's (`countTrainerDecisions`).
    fleet.options.pushes.every = 12;
    fleet.options.pushes.rate_per_second = 0;
    fleet.options.pushes.brake.watch_seconds = 3 * fleet.decisionSeconds();
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{ .offsets = 0.25, .stiffness = 0.5 });
    try on_device.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &on_device, starts, tables.poses, model.coordinate_count, still);
    // THE TRAINER, with a unit normaliser: the smoke run's features are left as they are.
    const feature_count: usize = z.robot_track.localSize(model.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    const normalizer: z.robot_latent.Normalizer = .{ .mean = means, .spread = spreads };
    var kit_pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer kit_pipe.deinit();
    const Trainer: type = z.robot_track_resident.Resident(zn_mlp);
    const trainer_options: z.robot_track_resident.Options = .{
        .rows = 4,
        .window = 4,
        .hidden = 16,
        .policy_hidden = 16,
        .collect = 8,
        .world_updates = 8,
        .policy_updates = 1,
    };
    const trainer: *Trainer = try .init(gpa, &kit_pipe, fleet, normalizer, trainer_options);
    defer trainer.deinit();
    // THE CONTROL: the same options and seed on a kit pipe of its own, its world model learning nothing.
    var control_options: z.robot_track_resident.Options = trainer_options;
    control_options.world_rate = 0;
    var control_kit_pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer control_kit_pipe.deinit();
    const control: *Trainer = try .init(gpa, &control_kit_pipe, fleet, normalizer, control_options);
    defer control.deinit();
    const arrays: robotgpu.WorldStateLayout = on_device.layout.world_f;
    const input_stride: u32 = arrays.policy_inputs.stride;
    const action_stride: u32 = arrays.actions.stride;
    try trainer.acceptDeviceActing(0, world_count, input_stride, action_stride);
    try control.acceptDeviceActing(0, world_count, input_stride, action_stride);
    // The parameter buffer as far as the learner's numbers for the log reach, read after each round.
    const stats_end: usize = trainer.stats_at + z.robot_latent_kit.DeviceStats.floats;
    const parameter_numbers: []f32 = try gpa.alloc(f32, stats_end);
    defer gpa.free(parameter_numbers);
    var outcome: TrainingSmokeOutcome = .{
        .world_model_losses = @splat(0),
        .control_losses = @splat(0),
        .rounds_trained = 0,
        .parameters_not_finite = 0,
        .acting_phases = .{},
        .acting_events = .{},
        .phases = .{},
        .policy_updates = 0,
    };
    // THE DATA: 64 decisions on the device in one call, then held - the call timed as a round's acting is: both
    // pipes by phase, and a host's clock the simulator tells the phases.
    const decisions_collected: u32 = smoke_decisions;
    const exploration_spread: f32 = 0.3;
    const no_planners: ?robotgpu_host.TrainerPlanners = null;
    var device_events: robotgpu_host.DeviceEvents = .{};
    try expect(try on_device.pipe.enableTimings(.{}));
    try expect(try kit_pipe.enableTimings(.{}));
    on_device.phase_clock = &outcome.acting_phases.clock;
    outcome.acting_phases.clock.begin(wgpu.nowMs());
    try on_device.actTrainerOnDevice(
        zn_mlp,
        gpa,
        trainer,
        decisions_collected,
        1,
        physics_steps,
        .{ .exploration_spread = exploration_spread, .flow_scale = 1 },
        no_planners,
        &device_events,
    );
    const pipe_phases_after_acting = [_]u32{ on_device.pipe.phase, kit_pipe.phase };
    const acting_left_in_other: bool =
        MeasuredPhases.leftInOther(outcome.acting_phases.clock, &pipe_phases_after_acting);
    outcome.acting_phases.calls_ending_elsewhere += @intFromBool(!acting_left_in_other);
    outcome.acting_phases.clock.end(wgpu.nowMs());
    on_device.phase_clock = null;
    outcome.acting_phases.device.readFrom(robotgpu, &on_device.pipe);
    outcome.acting_phases.device.readFrom(zn_mlp, &kit_pipe);
    outcome.acting_events = device_events;
    try giveTrainerDataTo(gpa, device, queue, trainer, control);
    // THE ROUNDS OF TRAINING on it, the trainer and the control side by side - the trainer's timed as a run's are:
    // its kit pipe by phase from here on, and a host's clock it tells the phases.
    const control_parameters: []f32 = try gpa.alloc(f32, stats_end);
    defer gpa.free(control_parameters);
    trainer.phase_clock = &outcome.phases.clock;
    defer trainer.phase_clock = null;
    outcome.phases.clock.begin(wgpu.nowMs());
    var training_round: u32 = 0;
    while (training_round < smoke_rounds) : (training_round += 1) {
        const world_updates_before: u64 = trainer.world_updates;
        trainer.train();
        const left_in_other: bool = MeasuredPhases.leftInOther(outcome.phases.clock, &.{kit_pipe.phase});
        outcome.phases.calls_ending_elsewhere += @intFromBool(!left_in_other);
        control.train();
        const round_trained: bool = trainer.world_updates > world_updates_before;
        if (!round_trained) {
            continue;
        }
        const DeviceStats: type = z.robot_latent_kit.DeviceStats;
        try readTrainerParameters(device, queue, trainer, parameter_numbers);
        const stats_numbers: []const f32 = parameter_numbers[trainer.stats_at..stats_end];
        const stats: DeviceStats = bytesToValue(DeviceStats, sliceAsBytes(stats_numbers));
        try readTrainerParameters(device, queue, control, control_parameters);
        const control_stats_numbers: []const f32 = control_parameters[control.stats_at..stats_end];
        const control_stats: DeviceStats = bytesToValue(DeviceStats, sliceAsBytes(control_stats_numbers));
        outcome.world_model_losses[outcome.rounds_trained] = stats.world_model_loss;
        outcome.control_losses[outcome.rounds_trained] = control_stats.world_model_loss;
        outcome.rounds_trained += 1;
    }
    outcome.phases.clock.end(wgpu.nowMs());
    outcome.phases.device.readFrom(zn_mlp, &kit_pipe);
    outcome.policy_updates = trainer.policy_updates;
    // Every parameter after the last round.
    for (parameter_numbers[0..trainer.params_end]) |parameter| {
        if (!isFinite(parameter)) {
            outcome.parameters_not_finite += 1;
        }
    }
    return outcome;
}

/// THE COPY ON THE DEVICE (`Sim.copyWorlds`): Geno's worlds made different by a few decisions with pushes, then
/// world 3 made a copy of world 1. Every block of both world arenas - every array the layouts list but the copy
/// table - must be world 1's to the bit: a copy is no arithmetic, so a device rounds nothing. Returns how many
/// numbers differ between the copy and its source, and between world 2 and world 1, which must differ.
fn runRobotgpuCopy(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
) ![2]u32 {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const world_count: u32 = 4;
    const physics_steps: u32 = 2;
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        world_count,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    try on_device.setTracking(gpa, fleet.trackingSettings(.{}));
    try on_device.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &on_device, starts, tables.poses, model.coordinate_count, still);
    // A few decisions, a push at each: every world its own state.
    var decision: u32 = 0;
    while (decision < 3) : (decision += 1) {
        const clock: robotgpu.DecisionClock = .{ .number = decision + 1, .push_top_share = 1.0 };
        on_device.stepDecision(physics_steps, clock);
    }
    const source: u32 = 1;
    const copy: u32 = 3;
    const sources = [_]?u32{ null, null, null, source };
    try on_device.copyWorlds(gpa, &sources);
    // Both arenas whole, as far as the worlds reach.
    const numbers: []f32 = try gpa.alloc(f32, on_device.worldArenaEnd(.world_f));
    defer gpa.free(numbers);
    const integers: []u32 = try gpa.alloc(u32, on_device.worldArenaEnd(.world_u));
    defer gpa.free(integers);
    try readWorldFloats(gpa, &on_device, 0, numbers);
    try readWorldIntegers(gpa, &on_device, 0, integers);
    var differences = [2]u32{ 0, 0 };
    const compared = [2][2]u32{ .{ copy, source }, .{ 2, source } };
    for (compared, &differences) |pair, *differing| {
        inline for (@typeInfo(robotgpu.WorldStateLayout).@"struct".field_names) |field_name| {
            const Array: type = @FieldType(robotgpu.WorldStateLayout, field_name);
            const array: Array = @field(on_device.layout.world_f, field_name);
            const first_block: []const f32 = numbers[array.offset + pair[0] * array.stride ..][0..array.stride];
            const second_block: []const f32 = numbers[array.offset + pair[1] * array.stride ..][0..array.stride];
            for (first_block, second_block) |first_number, second_number| {
                const first_bits: u32 = @bitCast(first_number);
                const second_bits: u32 = @bitCast(second_number);
                if (first_bits != second_bits) {
                    differing.* += 1;
                }
            }
        }
        inline for (@typeInfo(robotgpu.WorldIntegersLayout).@"struct".field_names) |field_name| {
            const is_copy_table: bool = comptime eql(u8, field_name, "copy_source");
            if (!is_copy_table) {
                const Array: type = @FieldType(robotgpu.WorldIntegersLayout, field_name);
                const array: Array = @field(on_device.layout.world_u, field_name);
                const first_block: []const u32 = integers[array.offset + pair[0] * array.stride ..][0..array.stride];
                const second_block: []const u32 = integers[array.offset + pair[1] * array.stride ..][0..array.stride];
                for (first_block, second_block) |first_integer, second_integer| {
                    if (first_integer != second_integer) {
                        differing.* += 1;
                    }
                }
            }
        }
    }
    return differences;
}

/// What `runRobotgpuTwoClips` found.
const TwoClipsOutcome = struct {
    /// Each clip's frames and bins on the twin, as the tables gave them.
    clip_frames: [2]u32,
    clip_bins: [2]u32,
    /// Each clip's reference features in the tables against the fleet's for that clip alone: numbers that differ.
    feature_differences: [2]u32,
    /// Each clip's last running sum, which must be 1, and whether each clip's sums never fall.
    last_sums: [2]f32,
    sums_never_fall: bool,
    /// After every world's restart: worlds on a clip not their own (`world % 2`), worlds whose start bin is not one of
    /// their clip's, and worlds whose start frame differs from the fleet's draw.
    worlds_on_another_clip: u32,
    worlds_outside_their_bins: u32,
    frames_unlike_the_fleet: u32,
};

/// A RUN OF TWO CLIPS ON THE TWIN, as a trainer's simulator holds its clips: the tracking checks' clip and a second,
/// shorter one - its frames 30 to 119, so no frame of the two is alike and 90 frames against 120 give them different
/// numbers of bins - each world on its own clip by
/// character (`world % 2`), the curriculum on, its bins' returns made unequal so each clip's mixture is its own. The
/// tables and the curriculum's mixture come from the fleet (`robotgpu_host.RunTables`, `Sim.uploadStartBins`);
/// then every world is marked finished and restarted by the twin's resets (`begin_reset`). Read back: each clip's
/// running sums, and each world's clip, start bin and start frame - the frame against the fleet's own draw for the
/// same world and episode (`Fleet.drawStartFrame`).
fn runRobotgpuTwoClips(gpa: Allocator) !TwoClipsOutcome {
    const world_count: u32 = 8;
    const physics_steps: u32 = 2;
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var first_clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer first_clip.deinit();
    var second_clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer second_clip.deinit();
    // The second clip is the first's frames 30 to 119, moved to its front.
    const second_clip_first_frame: usize = 30;
    const second_clip_frames: usize = 90;
    const pose_numbers: usize = second_clip.nq;
    const kept_first: usize = second_clip_first_frame * pose_numbers;
    const kept: []const f32 = second_clip.targets[kept_first..][0 .. second_clip_frames * pose_numbers];
    copyForwards(f32, second_clip.targets[0..kept.len], kept);
    second_clip.frame_count = second_clip_frames;
    const fleet: *z.robot_track.Fleet = try z.robot_track.Fleet.init(gpa, model, &.{ &first_clip, &second_clip }, .{
        .envs = world_count,
        .capacity = 32,
        .decide_every = physics_steps,
        .clip_assignment = .by_character,
        .curriculum = .{ .bin_seconds = 0.5 },
    });
    defer fleet.deinit();
    // Each bin's return its own, so a bin drawn from the wrong clip's mixture is drawn at the wrong rate - and the
    // mixtures refreshed from them, as a round refreshes them.
    for (fleet.bin_returns, 0..) |*bin_return, bin| {
        bin_return.* = 0.3 * float(bin);
    }
    fleet.refreshStartBins();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer twin.deinit();
    try twin.setTracking(gpa, fleet.trackingSettings(.{}));
    try twin.uploadStartBins(gpa, fleet);
    var outcome: TwoClipsOutcome = .{
        .clip_frames = .{ tables.clips[0].frame_count, tables.clips[1].frame_count },
        .clip_bins = .{ tables.clips[0].curriculum_bins, tables.clips[1].curriculum_bins },
        .feature_differences = .{ 0, 0 },
        .last_sums = .{ 0, 0 },
        .sums_never_fall = true,
        .worlds_on_another_clip = 0,
        .worlds_outside_their_bins = 0,
        .frames_unlike_the_fleet = 0,
    };
    // EACH CLIP's TABLE against the fleet's own, made for that clip alone.
    const feature_row: usize = z.robot_track.localSize(model.body_count);
    var scratch_data: z.robot.Data = try .init(gpa, model);
    defer scratch_data.deinit();
    var scratch_state: z.robot_track.State = try .init(gpa, model.body_count);
    defer scratch_state.deinit(gpa);
    const both_clips = [2]*const z.robot_dance.Clip{ &first_clip, &second_clip };
    for (both_clips, 0..) |clip, clip_index| {
        const expected_features: []f32 = try gpa.alloc(f32, clip.frame_count * feature_row);
        defer gpa.free(expected_features);
        fleet.clipReferenceFeatures(clip, &scratch_data, &scratch_state, expected_features);
        const given_features: []const f32 = tables.clips[clip_index].reference_features;
        for (expected_features, given_features) |expected, given| {
            if (@as(u32, @bitCast(expected)) != @as(u32, @bitCast(given))) {
                outcome.feature_differences[clip_index] += 1;
            }
        }
    }
    // EACH CLIP's RUNNING SUMS, read back from the twin.
    const bin_total: u32 = twin.counts.curriculum_bin_total;
    const sums: []f32 = try gpa.alloc(f32, bin_total);
    defer gpa.free(sums);
    const sums_at: u32 = twin.layout.io.bin_running_sums.at(0);
    var sums_read: robotgpu_host.Pipe.RangeRequest(.io) =
        try twin.pipe.requestRange(gpa, .io, sums_at, bin_total);
    while (!sums_read.collect(sums)) {
        std.atomic.spinLoopHint();
    }
    for (0..2) |clip_index| {
        const bins_first: usize = fleet.bins_start[clip_index];
        const bins_end: usize = fleet.bins_start[clip_index + 1];
        var previous_sum: f32 = 0;
        for (sums[bins_first..bins_end]) |sum| {
            if (sum < previous_sum) {
                outcome.sums_never_fall = false;
            }
            previous_sum = sum;
        }
        outcome.last_sums[clip_index] = sums[bins_end - 1];
    }
    // EVERY WORLD's FIRST EPISODE, as a run begins them (`Sim.startEveryWorld`): no episode has ended, so the bins
    // stay as given, and every start is drawn from them.
    const counters: robotgpu.WorldIntegersLayout = twin.layout.world_u;
    const no_pushes: robotgpu.DecisionClock = .{ .number = 1, .push_top_share = 0 };
    try twin.startEveryWorld(gpa, 0, no_pushes);
    const integers: []u32 = try gpa.alloc(u32, twin.worldArenaEnd(.world_u));
    defer gpa.free(integers);
    try readWorldIntegers(gpa, &twin, 0, integers);
    var world: u32 = 0;
    while (world < world_count) : (world += 1) {
        const clip: u32 = integers[counters.world_clip.at(world, 0)];
        const start_bin: u32 = integers[counters.start_bins.at(world, 0)];
        const frame: u32 = integers[counters.world_frame.at(world, 0)];
        const episode: u32 = integers[counters.episode_numbers.at(world, 0)];
        const own_clip: u32 = world % 2;
        if (clip != own_clip) {
            outcome.worlds_on_another_clip += 1;
            continue;
        }
        const bins_first: usize = fleet.bins_start[clip];
        const bins_end: usize = fleet.bins_start[clip + 1];
        const within_its_bins: bool = start_bin >= bins_first and start_bin < bins_end;
        if (!within_its_bins) {
            outcome.worlds_outside_their_bins += 1;
        }
        // The fleet's draw for the same world and episode, from the same mixture.
        fleet.episode_numbers[world] = episode;
        const fleet_frame: usize = fleet.drawStartFrame(world, clip);
        if (fleet_frame != frame) {
            outcome.frames_unlike_the_fleet += 1;
        }
    }
    return outcome;
}

/// What `runRobotgpuCandidates` found, decision after decision.
const CandidatesOutcome = struct {
    /// The source's restarts: its episode ended at its loss, and a new one began.
    source_restarts: u32,
    /// Whether the candidate lost its reference too - its judgement ran - and whether it was ever restarted or
    /// pushed.
    candidate_lost: bool,
    candidate_restarted: bool,
    candidate_pushed: bool,
    /// The candidate's block of records after the last decision set against the action it took at that decision:
    /// the action's numbers compared, and those not in the record.
    candidate_action_numbers_compared: u32,
    candidate_action_numbers_not_recorded: u32,
    /// Pushes given to the worlds that are no candidates: the decisions did push.
    other_worlds_pushed: u32,
};

/// CANDIDATES ON THE TWIN: a world made a copy of a knocked character (`Sim.copyWorlds`) - the character in the half
/// of the worlds without an aftermath, whose episode ends at its loss. The candidate is judged as any world is, so
/// it loses its reference with its source, and its record is packed as any world's - its block holds the action it
/// took at the last decision; but the source is restarted and the candidate is not, and no push reaches it while
/// every decision pushes the other worlds (`robotgpu.isCandidate`).
fn runRobotgpuCandidates(gpa: Allocator) !CandidatesOutcome {
    const world_count: u32 = 8;
    const physics_steps: u32 = 2;
    // THE SCENE, as the tracking check's: a push at every decision, two characters knocked off their reference.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var twin: robotgpu_host.Sim = try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer twin.deinit();
    try twin.setTracking(gpa, fleet.trackingSettings(.{}));
    try twin.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &twin, starts, tables.poses, model.coordinate_count, still);
    // THE CANDIDATE: the last world, a copy of the character knocked to its episode's end.
    const source: u32 = starts.knocked_to_its_end;
    const candidate: u32 = world_count - 1;
    try expect(source != candidate);
    var sources: [8]?u32 = @splat(null);
    sources[candidate] = source;
    try twin.copyWorlds(gpa, &sources);
    const counters: robotgpu.WorldIntegersLayout = twin.layout.world_u;
    const records: @FieldType(robotgpu.WorldStateLayout, "records") = twin.layout.world_f.records;
    const integers: []u32 = try gpa.alloc(u32, twin.worldArenaEnd(.world_u));
    defer gpa.free(integers);
    const candidate_records: []f32 = try gpa.alloc(f32, records.stride);
    defer gpa.free(candidate_records);
    try readWorldIntegers(gpa, &twin, 0, integers);
    const source_first_episode: u32 = integers[counters.episode_numbers.at(source, 0)];
    const candidate_first_episode: u32 = integers[counters.episode_numbers.at(candidate, 0)];
    var outcome: CandidatesOutcome = .{
        .source_restarts = 0,
        .candidate_lost = false,
        .candidate_restarted = false,
        .candidate_pushed = false,
        .candidate_action_numbers_compared = 0,
        .candidate_action_numbers_not_recorded = 0,
        .other_worlds_pushed = 0,
    };
    // THE DECISIONS: known actions; each world's record packed before its physics, as a trainer's are.
    const actions_row: []f32 = try gpa.alloc(f32, twin.counts.action_count);
    defer gpa.free(actions_row);
    const decision_count: u32 = 12;
    var decision: u32 = 0;
    while (decision < decision_count) : (decision += 1) {
        uploadTrackingActions(&twin, world_count, decision, actions_row);
        twin.submitDispatches(&robotgpu.observe_program);
        twin.submitDispatches(&robotgpu.record_program);
        const clock: robotgpu.DecisionClock = .{ .number = decision + 1, .push_top_share = 1.0 };
        twin.stepDecision(physics_steps, clock);
        try readWorldIntegers(gpa, &twin, 0, integers);
        const source_episode: u32 = integers[counters.episode_numbers.at(source, 0)];
        const candidate_episode: u32 = integers[counters.episode_numbers.at(candidate, 0)];
        const candidate_flags: u32 = integers[counters.episode_flags.at(candidate, 0)];
        outcome.source_restarts = source_episode - source_first_episode;
        if (candidate_episode != candidate_first_episode) {
            outcome.candidate_restarted = true;
        }
        if (candidate_flags & robotgpu.episodeFlagBit(.lost) != 0) {
            outcome.candidate_lost = true;
        }
        if (candidate_flags & robotgpu.episodeFlagBit(.pushed) != 0) {
            outcome.candidate_pushed = true;
        }
        var world: u32 = 0;
        while (world < candidate) : (world += 1) {
            const flags: u32 = integers[counters.episode_flags.at(world, 0)];
            if (flags & robotgpu.episodeFlagBit(.pushed) != 0) {
                outcome.other_worlds_pushed += 1;
            }
        }
    }
    // The candidate's block of records: packed at the last decision as every world's - the features, then the action
    // it took, which nothing has changed since.
    try readWorldFloats(gpa, &twin, records.at(candidate, 0), candidate_records);
    const action_taken: []f32 = try gpa.alloc(f32, twin.counts.action_count);
    defer gpa.free(action_taken);
    try readWorldFloats(gpa, &twin, twin.layout.world_f.actions.at(candidate, 0), action_taken);
    const feature_count: usize = z.robot_track.localSize(model.body_count);
    const action_recorded: []const f32 = candidate_records[feature_count..][0..action_taken.len];
    for (action_recorded, action_taken) |recorded, taken| {
        outcome.candidate_action_numbers_compared += 1;
        if (recorded != taken) {
            outcome.candidate_action_numbers_not_recorded += 1;
        }
    }
    return outcome;
}

/// A SENTINEL FOR A POSITION of a float arena: a number no kernel computes by chance, and distinct from every other
/// position's in the arena's first million - so a number copied from elsewhere is caught as surely as one computed.
/// Exact in f32: below 2^24.
fn sentinelAt(position: usize) f32 {
    const position_in_range: usize = position % 1_000_000;
    return 7.0e6 + float(position_in_range);
}

/// THE BLOCKS OF WORLDS `first_world` TO `world_end` IN ARENA `arena` SET TO SENTINELS: every array's block of each of
/// those worlds - in a float arena each number its position's sentinel (`sentinelAt`), in an integer arena zero, in
/// range for every index a kernel takes from one (no rows, clip 0, frame 0).
fn fillBlocksWithSentinels(
    gpa: Allocator,
    sim: *robotgpu_host.Sim,
    comptime arena: robotgpu.Arena,
    first_world: u32,
    world_end: u32,
) !void {
    // Every array of the arena's layout walked at compile time, each with the pipe's generic calls for this arena:
    // more compile-time branches than the default budget of a function.
    @setEvalBranchQuota(20_000);
    const Element: type = robotgpu.ArenaElement(arena);
    const ArenaLayout: type = @FieldType(robotgpu.Layout, @tagName(arena));
    const arena_layout: ArenaLayout = @field(sim.layout, @tagName(arena));
    inline for (@typeInfo(ArenaLayout).@"struct".field_names) |array_name| {
        const array: @FieldType(ArenaLayout, array_name) = @field(arena_layout, array_name);
        const block: []Element = try gpa.alloc(Element, array.stride);
        defer gpa.free(block);
        var world: u32 = first_world;
        while (world < world_end) : (world += 1) {
            const block_start: u32 = array.at(world, 0);
            for (block, 0..) |*number, number_in_block| {
                number.* = if (Element == f32) sentinelAt(block_start + number_in_block) else 0;
            }
            sim.pipe.uploadAt(arena, block_start, block);
        }
    }
}

/// How many numbers of the blocks `fillBlocksWithSentinels` set are no longer their sentinels, read back.
fn countSentinelsOverwritten(
    gpa: Allocator,
    sim: *robotgpu_host.Sim,
    comptime arena: robotgpu.Arena,
    first_world: u32,
    world_end: u32,
) !u32 {
    // As in `fillBlocksWithSentinels`: the layout walked at compile time takes more branches than the default budget.
    @setEvalBranchQuota(20_000);
    const Element: type = robotgpu.ArenaElement(arena);
    const ArenaLayout: type = @FieldType(robotgpu.Layout, @tagName(arena));
    const arena_layout: ArenaLayout = @field(sim.layout, @tagName(arena));
    const whole_arena: []Element = try gpa.alloc(Element, sim.worldArenaEnd(arena));
    defer gpa.free(whole_arena);
    const arena_length: u32 = @intCast(whole_arena.len);
    var whole_read: robotgpu_host.Pipe.RangeRequest(arena) = try sim.pipe.requestRange(gpa, arena, 0, arena_length);
    while (!whole_read.collect(whole_arena)) {
        std.atomic.spinLoopHint();
    }
    var overwritten: u32 = 0;
    inline for (@typeInfo(ArenaLayout).@"struct".field_names) |array_name| {
        const array: @FieldType(ArenaLayout, array_name) = @field(arena_layout, array_name);
        var world: u32 = first_world;
        while (world < world_end) : (world += 1) {
            const block_start: u32 = array.at(world, 0);
            const block: []const Element = whole_arena[block_start..][0..array.stride];
            for (block, 0..) |number, number_in_block| {
                const sentinel: Element = if (Element == f32) sentinelAt(block_start + number_in_block) else 0;
                if (number != sentinel) {
                    overwritten += 1;
                }
            }
        }
    }
    return overwritten;
}

/// What `runRobotgpuLookahead` found.
const LookaheadOutcome = struct {
    /// The planners' numbers that the lookahead changed: none, if they held.
    planner_floats_changed: u32,
    planner_integers_changed: u32,
    /// The planners' numbers, in every arena - their state, their integers, their constraint rows - that a lookahead
    /// wrote over, the planners first set to sentinels: none, if every kernel keeps to the batch's worlds.
    planner_sentinels_overwritten: u32,
    /// Whether the lookahead moved the candidates at all.
    candidates_moved: bool,
    /// The candidates' numbers that differ between the lookahead and an ordinary run of every world: none.
    candidate_floats_differing: u32,
    candidate_integers_differing: u32,
};

/// CANDIDATES RUN AHEAD WHILE THEIR PLANNERS HOLD (`Sim.stepCandidatesAhead`), on the twin or on a device. Four
/// candidates - the first four worlds - are made copies of the planners after them (`copyWorlds`); six decisions of
/// lookahead; every planner's number must be what it was, to the bit. Then the candidates are copied afresh and the
/// same six decisions run in a batch of every world: a world's step reads only its own state, so each candidate must
/// end where the lookahead left it, to the bit. Last, the planners' blocks set to sentinels, one more decision of
/// lookahead must leave every one of them.
fn runRobotgpuLookahead(
    gpa: Allocator,
    on_a_device: ?TestDevice,
    coverage: *DeviceCoverage,
) !LookaheadOutcome {
    const world_count: u32 = 8;
    const candidate_count: u32 = 4;
    const physics_steps: u32 = 2;
    const lookahead_decisions: u32 = 6;
    // THE SCENE, as the tracking check's: the knocked character among the planners, so a candidate loses too.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var sim: robotgpu_host.Sim = if (on_a_device) |opened|
        try .initGpuTracking(gpa, opened.device, opened.queue, &entries, model, world_count, tables.clips)
    else
        try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer sim.deinit();
    // On a device, its dispatches counted for the run's coverage, before the simulator is freed.
    defer if (on_a_device != null) coverage.add(&sim);
    try sim.setTracking(gpa, fleet.trackingSettings(.{}));
    try sim.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &sim, starts, tables.poses, model.coordinate_count, still);
    const actions_row: []f32 = try gpa.alloc(f32, sim.counts.action_count);
    defer gpa.free(actions_row);
    uploadTrackingActions(&sim, world_count, 0, actions_row);
    // THE CANDIDATES: worlds 0 and 1 copies of the knocked planner, 2 and 3 of two others.
    var sources: [8]?u32 = @splat(null);
    sources[0] = starts.knocked_to_its_end;
    sources[1] = starts.knocked_to_its_end;
    sources[2] = 6;
    sources[3] = 7;
    for (sources[0..candidate_count]) |source| {
        try expect(source.? >= candidate_count);
    }
    try sim.copyWorlds(gpa, &sources);
    // Every world's numbers before the lookahead, after it, and after an ordinary run of every world.
    const float_count: u32 = sim.worldArenaEnd(.world_f);
    const integer_count: u32 = sim.worldArenaEnd(.world_u);
    const floats_before: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(floats_before);
    const integers_before: []u32 = try gpa.alloc(u32, integer_count);
    defer gpa.free(integers_before);
    const floats_ahead: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(floats_ahead);
    const integers_ahead: []u32 = try gpa.alloc(u32, integer_count);
    defer gpa.free(integers_ahead);
    const floats_ordinary: []f32 = try gpa.alloc(f32, float_count);
    defer gpa.free(floats_ordinary);
    const integers_ordinary: []u32 = try gpa.alloc(u32, integer_count);
    defer gpa.free(integers_ordinary);
    try readWorldFloats(gpa, &sim, 0, floats_before);
    try readWorldIntegers(gpa, &sim, 0, integers_before);
    // THE LOOKAHEAD, the candidates' plans from their first decision.
    const plans_begin: u32 = 0;
    sim.stepCandidatesAhead(candidate_count, plans_begin, lookahead_decisions, physics_steps);
    try readWorldFloats(gpa, &sim, 0, floats_ahead);
    try readWorldIntegers(gpa, &sim, 0, integers_ahead);
    // THE REFERENCE: the candidates copied afresh, then the same decisions for every world - a batch of every world
    // where the lookahead's was the candidates'.
    try sim.copyWorlds(gpa, &sources);
    sim.stepCandidatesAhead(world_count, plans_begin, lookahead_decisions, physics_steps);
    try readWorldFloats(gpa, &sim, 0, floats_ordinary);
    try readWorldIntegers(gpa, &sim, 0, integers_ordinary);
    var outcome: LookaheadOutcome = .{
        .planner_floats_changed = 0,
        .planner_integers_changed = 0,
        .planner_sentinels_overwritten = 0,
        .candidates_moved = false,
        .candidate_floats_differing = 0,
        .candidate_integers_differing = 0,
    };
    // Array by array, world by world: a planner's block before and after the lookahead; a candidate's after the
    // lookahead and after the ordinary run.
    const arrays: robotgpu.WorldStateLayout = sim.layout.world_f;
    inline for (@typeInfo(robotgpu.WorldStateLayout).@"struct".field_names) |field_name| {
        // The scores' own bookkeeping is the lookahead's alone: an ordinary decision keeps none.
        const is_score_bookkeeping: bool = comptime startsWith(u8, field_name, "candidate_");
        const array: @FieldType(robotgpu.WorldStateLayout, field_name) = @field(arrays, field_name);
        var world: u32 = if (is_score_bookkeeping) world_count else 0;
        while (world < world_count) : (world += 1) {
            const block_start: usize = array.offset + world * array.stride;
            const before: []const f32 = floats_before[block_start..][0..array.stride];
            const ahead: []const f32 = floats_ahead[block_start..][0..array.stride];
            const ordinary: []const f32 = floats_ordinary[block_start..][0..array.stride];
            const is_candidate: bool = world < candidate_count;
            for (before, ahead, ordinary) |number_before, number_ahead, number_ordinary| {
                const before_bits: u32 = @bitCast(number_before);
                const ahead_bits: u32 = @bitCast(number_ahead);
                const ordinary_bits: u32 = @bitCast(number_ordinary);
                if (is_candidate) {
                    if (ahead_bits != before_bits) {
                        outcome.candidates_moved = true;
                    }
                    if (ahead_bits != ordinary_bits) {
                        outcome.candidate_floats_differing += 1;
                    }
                } else if (ahead_bits != before_bits) {
                    outcome.planner_floats_changed += 1;
                }
            }
        }
    }
    const counters: robotgpu.WorldIntegersLayout = sim.layout.world_u;
    inline for (@typeInfo(robotgpu.WorldIntegersLayout).@"struct".field_names) |field_name| {
        const is_score_bookkeeping: bool = comptime startsWith(u8, field_name, "candidate_");
        const array: @FieldType(robotgpu.WorldIntegersLayout, field_name) = @field(counters, field_name);
        var world: u32 = if (is_score_bookkeeping) world_count else 0;
        while (world < world_count) : (world += 1) {
            const block_start: usize = array.offset + world * array.stride;
            const before: []const u32 = integers_before[block_start..][0..array.stride];
            const ahead: []const u32 = integers_ahead[block_start..][0..array.stride];
            const ordinary: []const u32 = integers_ordinary[block_start..][0..array.stride];
            const is_candidate: bool = world < candidate_count;
            for (before, ahead, ordinary) |number_before, number_ahead, number_ordinary| {
                if (is_candidate) {
                    if (number_ahead != number_ordinary) {
                        outcome.candidate_integers_differing += 1;
                    }
                } else if (number_ahead != number_before) {
                    outcome.planner_integers_changed += 1;
                }
            }
        }
    }
    // THE PLANNERS AS SENTINELS: a planner left as it was can still be written by a kernel that ignores the batch's
    // world count, when what it writes is what was there (a solve from its own last solution). So the planners'
    // blocks in every arena are set to sentinels, and one more decision of lookahead must leave every one of them.
    const planners_from: u32 = candidate_count;
    try fillBlocksWithSentinels(gpa, &sim, .world_f, planners_from, world_count);
    try fillBlocksWithSentinels(gpa, &sim, .world_u, planners_from, world_count);
    try fillBlocksWithSentinels(gpa, &sim, .efc_f, planners_from, world_count);
    const one_decision: u32 = 1;
    sim.stepCandidatesAhead(candidate_count, lookahead_decisions, one_decision, physics_steps);
    outcome.planner_sentinels_overwritten =
        try countSentinelsOverwritten(gpa, &sim, .world_f, planners_from, world_count) +
        try countSentinelsOverwritten(gpa, &sim, .world_u, planners_from, world_count) +
        try countSentinelsOverwritten(gpa, &sim, .efc_f, planners_from, world_count);
    return outcome;
}

/// What `runRobotgpuCandidateScores` found.
const CandidateScoresOutcome = struct {
    /// The candidates' scores, kept on the simulator and computed by the check from each decision's rewards and flags.
    kept: [4]f32,
    computed: [4]f32,
    /// How many candidates lost their reference in the lookahead.
    candidates_lost: u32,
    /// Each planner's best candidate - of the knocked planner's two, and of each of the two others' one - chosen
    /// from the kept scores and from the computed (`bestInBlock`).
    best_of_kept: [3]usize,
    best_of_computed: [3]usize,
};

/// A LOOKAHEAD SCORED (`score_candidates`), on the twin or a device: the lookahead scene of `runRobotgpuLookahead`,
/// six decisions stepped one at a time; after each, the check reads every candidate's SuperMimic reward and flags and
/// computes the scores itself - each decision's reward at its discount, a loss's cost at the loss's, nothing after a
/// loss. The kept and the computed must agree; the knocked planner's candidates must lose; each planner's best, chosen
/// from either, must be the same candidate.
fn runRobotgpuCandidateScores(
    gpa: Allocator,
    on_a_device: ?TestDevice,
    coverage: *DeviceCoverage,
) !CandidateScoresOutcome {
    const world_count: u32 = 8;
    const candidate_count: u32 = 4;
    const physics_steps: u32 = 2;
    const lookahead_decisions: u32 = 6;
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var sim: robotgpu_host.Sim = if (on_a_device) |opened|
        try .initGpuTracking(gpa, opened.device, opened.queue, &entries, model, world_count, tables.clips)
    else
        try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer sim.deinit();
    // On a device, its dispatches counted for the run's coverage, before the simulator is freed.
    defer if (on_a_device != null) coverage.add(&sim);
    try sim.setTracking(gpa, fleet.trackingSettings(.{}));
    try sim.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &sim, starts, tables.poses, model.coordinate_count, still);
    const actions_row: []f32 = try gpa.alloc(f32, sim.counts.action_count);
    defer gpa.free(actions_row);
    uploadTrackingActions(&sim, world_count, 0, actions_row);
    // The candidates: two of the knocked planner, one each of two others.
    var sources: [8]?u32 = @splat(null);
    sources[0] = starts.knocked_to_its_end;
    sources[1] = starts.knocked_to_its_end;
    sources[2] = 6;
    sources[3] = 7;
    try sim.copyWorlds(gpa, &sources);
    sim.beginCandidateScores(candidate_count);
    // The check's own scores, decision by decision.
    const plan_discount: f32 = sim.pipe.params.options.plan_discount;
    const plan_loss_cost: f32 = sim.pipe.params.options.plan_loss_cost;
    var computed: [4]f32 = @splat(0);
    var discount_powers: [4]f32 = @splat(1);
    var lost: [4]bool = @splat(false);
    const floats: []f32 = try gpa.alloc(f32, sim.worldArenaEnd(.world_f));
    defer gpa.free(floats);
    const integers: []u32 = try gpa.alloc(u32, sim.worldArenaEnd(.world_u));
    defer gpa.free(integers);
    const rewards: @FieldType(robotgpu.WorldStateLayout, "super_mimic_rewards") =
        sim.layout.world_f.super_mimic_rewards;
    const counters: robotgpu.WorldIntegersLayout = sim.layout.world_u;
    var decision: u32 = 0;
    while (decision < lookahead_decisions) : (decision += 1) {
        const one_decision: u32 = 1;
        sim.stepCandidatesAhead(candidate_count, decision, one_decision, physics_steps);
        try readWorldFloats(gpa, &sim, 0, floats);
        try readWorldIntegers(gpa, &sim, 0, integers);
        var candidate: u32 = 0;
        while (candidate < candidate_count) : (candidate += 1) {
            if (lost[candidate]) {
                continue;
            }
            const reward: f32 = floats[rewards.at(candidate, 0)];
            const flags: u32 = integers[counters.episode_flags.at(candidate, 0)];
            const lost_now: bool = flags & robotgpu.episodeFlagBit(.lost) != 0;
            const loss_cost: f32 = if (lost_now) plan_loss_cost else 0;
            computed[candidate] += discount_powers[candidate] * (reward - loss_cost);
            discount_powers[candidate] *= plan_discount;
            lost[candidate] = lost_now;
        }
    }
    var outcome: CandidateScoresOutcome = .{
        .kept = undefined,
        .computed = computed,
        .candidates_lost = 0,
        .best_of_kept = undefined,
        .best_of_computed = undefined,
    };
    try sim.readCandidateScores(gpa, &outcome.kept);
    for (lost) |candidate_lost| {
        if (candidate_lost) {
            outcome.candidates_lost += 1;
        }
    }
    // Each planner's block of candidates: its first, and how many.
    const planner_blocks = [_][2]usize{ .{ 0, 2 }, .{ 2, 1 }, .{ 3, 1 } };
    for (planner_blocks, 0..) |block, planner_index| {
        const first_candidate: usize = block[0];
        const block_length: usize = block[1];
        const kept_block: []const f32 = outcome.kept[first_candidate..][0..block_length];
        const computed_block: []const f32 = outcome.computed[first_candidate..][0..block_length];
        outcome.best_of_kept[planner_index] = first_candidate + robotgpu_host.bestInBlock(kept_block);
        outcome.best_of_computed[planner_index] = first_candidate + robotgpu_host.bestInBlock(computed_block);
    }
    return outcome;
}

/// What `runRobotgpuPlanActions` found: across every candidate, number and lookahead decision, the largest gap between
/// the action the simulator gave and the host's interpolation of the knots, in epsilons of the knots' scale.
const PlanActionsOutcome = struct {
    largest_gap_epsilons: f32,
    actions_compared: u32,
};

/// THE PLAN's ACTIONS IN A LOOKAHEAD (`plan_actions`), on the twin or a device: four candidates of the lookahead
/// scene, each given knots of its own - distinct numbers at every knot - then, before each of the horizon's decisions
/// and at its end, the plans' actions given, read back and set against the host's interpolation: the knot position
/// d (K - 1) / H, the two knots around it, the straight line between. Each decision is then stepped, as a lookahead
/// steps it.
fn runRobotgpuPlanActions(
    gpa: Allocator,
    on_a_device: ?TestDevice,
    coverage: *DeviceCoverage,
) !PlanActionsOutcome {
    const world_count: u32 = 8;
    const candidate_count: u32 = 4;
    const physics_steps: u32 = 2;
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var sim: robotgpu_host.Sim = if (on_a_device) |opened|
        try .initGpuTracking(gpa, opened.device, opened.queue, &entries, model, world_count, tables.clips)
    else
        try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer sim.deinit();
    // On a device, its dispatches counted for the run's coverage, before the simulator is freed.
    defer if (on_a_device != null) coverage.add(&sim);
    try sim.setTracking(gpa, fleet.trackingSettings(.{}));
    try sim.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &sim, starts, tables.poses, model.coordinate_count, still);
    var sources: [8]?u32 = @splat(null);
    for (sources[0..candidate_count], 0..) |*source, candidate| {
        source.* = candidate_count + @as(u32, @intCast(candidate));
    }
    try sim.copyWorlds(gpa, &sources);
    // THE KNOTS: every candidate's own, a different number at every knot and freedom, within half a radian.
    const action_count: u32 = sim.counts.action_count;
    const knot_count: u32 = sim.counts.plan_knot_count;
    const knot_numbers: u32 = knot_count * action_count;
    const knots: []f32 = try gpa.alloc(f32, candidate_count * knot_numbers);
    defer gpa.free(knots);
    for (knots, 0..) |*knot_number, at| {
        knot_number.* = 0.5 * @sin(0.37 * float(at) + 0.11);
    }
    var candidate: u32 = 0;
    while (candidate < candidate_count) : (candidate += 1) {
        sim.uploadWorldArray("plan_knots", candidate, knots[candidate * knot_numbers ..][0..knot_numbers]);
    }
    // EACH DECISION OF THE HORIZON, and its end: the actions given, read, set against the host's line.
    const horizon: u32 = sim.counts.plan_horizon;
    const actions_array: @FieldType(robotgpu.WorldStateLayout, "actions") = sim.layout.world_f.actions;
    const given: []f32 = try gpa.alloc(f32, actions_array.stride * candidate_count);
    defer gpa.free(given);
    var outcome: PlanActionsOutcome = .{ .largest_gap_epsilons = 0, .actions_compared = 0 };
    // The host's line (`planActionAt`), one action at a time.
    const expected_action: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(expected_action);
    var plan_decision: u32 = 0;
    while (plan_decision <= horizon) : (plan_decision += 1) {
        sim.followPlans(plan_decision);
        try readWorldFloats(gpa, &sim, actions_array.at(0, 0), given);
        candidate = 0;
        while (candidate < candidate_count) : (candidate += 1) {
            const candidate_knots: []const f32 = knots[candidate * knot_numbers ..][0..knot_numbers];
            robotgpu_host.planActionAt(
                candidate_knots,
                knot_count,
                action_count,
                float(horizon),
                float(plan_decision),
                expected_action,
            );
            var number: u32 = 0;
            while (number < action_count) : (number += 1) {
                const expected: f32 = expected_action[number];
                const kept: f32 = given[candidate * actions_array.stride + number];
                // The knots' scale is one: their numbers are within half a radian.
                const gap: f32 = robotgpu_host.gapInUnits(kept, expected, 0x1p-23);
                outcome.largest_gap_epsilons = @max(outcome.largest_gap_epsilons, gap);
                outcome.actions_compared += 1;
            }
        }
        const one_decision: u32 = 1;
        sim.stepCandidatesAhead(candidate_count, plan_decision, one_decision, physics_steps);
    }
    return outcome;
}

/// A simulator's world arenas as read back whole (`readWorldFloats`, `readWorldIntegers` from 0): its numbers and its
/// integers, every world's blocks as the layouts place them.
const WorldReadBack = struct {
    floats: []const f32,
    integers: []const u32,
};

/// THE NUMBERS OF `worlds` THAT DIFFER between two read-backs of simulators of the same `layout`: every array of
/// each world's numbers and integers, compared to the bit - but the planning's own bookkeeping, which a replan writes
/// by design and no physics reads: the candidates' scores and losses, the plans' knots, the planners' following.
fn worldsNumbersDiffering(
    layout: robotgpu.Layout,
    worlds: []const u32,
    first: WorldReadBack,
    second: WorldReadBack,
) u32 {
    var differing: u32 = 0;
    const numbers: robotgpu.WorldStateLayout = layout.world_f;
    inline for (@typeInfo(robotgpu.WorldStateLayout).@"struct".field_names) |field_name| {
        const is_planning_bookkeeping: bool = comptime startsWith(u8, field_name, "candidate_") or
            eql(u8, field_name, "plan_knots");
        if (!is_planning_bookkeeping) {
            const array: @FieldType(robotgpu.WorldStateLayout, field_name) = @field(numbers, field_name);
            for (worlds) |world| {
                const from: usize = array.at(world, 0);
                const to: usize = from + array.stride;
                for (first.floats[from..to], second.floats[from..to]) |first_number, second_number| {
                    const first_bits: u32 = @bitCast(first_number);
                    const second_bits: u32 = @bitCast(second_number);
                    if (first_bits != second_bits) {
                        differing += 1;
                    }
                }
            }
        }
    }
    const integers: robotgpu.WorldIntegersLayout = layout.world_u;
    inline for (@typeInfo(robotgpu.WorldIntegersLayout).@"struct".field_names) |field_name| {
        const is_planning_bookkeeping: bool = comptime startsWith(u8, field_name, "candidate_") or
            eql(u8, field_name, "plan_following");
        if (!is_planning_bookkeeping) {
            const array: @FieldType(robotgpu.WorldIntegersLayout, field_name) = @field(integers, field_name);
            for (worlds) |world| {
                const from: usize = array.at(world, 0);
                const to: usize = from + array.stride;
                for (first.integers[from..to], second.integers[from..to]) |first_integer, second_integer| {
                    if (first_integer != second_integer) {
                        differing += 1;
                    }
                }
            }
        }
    }
    return differing;
}

/// What `runRobotgpuReplan` found.
const ReplanOutcome = struct {
    /// The characters' numbers the replan changed: none - a lookahead steps the candidates alone.
    character_numbers_changed: u32,
    /// Whether each planner's candidate 0 was its warm start, and whether its new plan is the knots of the candidate
    /// the check finds best from the scores itself.
    warm_starts_kept: bool,
    plans_are_the_best: bool,
    /// Whether the candidates' scores moved from zero: the lookahead ran.
    scores_moved: bool,
    /// Whether some planner's best was another than its candidate 0: the choice was exercised.
    some_best_not_the_warm_start: bool,
};

/// A REPLAN (`Sim.replan`), on the twin or a device: sixteen worlds - eight candidates first, four for each of two
/// planners, then eight characters - the knocked character one of the planners. The plans start from a poor action,
/// every offset at half a radian, so candidates drawn about it can do better and the choice is exercised: some
/// planner's best must be another than its candidate 0. One replan. Every character's number must be what it was;
/// each planner's candidate 0 its warm start (a plan held at one action moves on to itself); each planner's new plan
/// the knots of its highest-scoring candidate, found by the check from the scores read back.
fn runRobotgpuReplan(
    gpa: Allocator,
    on_a_device: ?TestDevice,
    coverage: *DeviceCoverage,
) !ReplanOutcome {
    const world_count: u32 = 16;
    const candidates_per_planner: u32 = 4;
    const physics_steps: u32 = 2;
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    var sim: robotgpu_host.Sim = if (on_a_device) |opened|
        try .initGpuTracking(gpa, opened.device, opened.queue, &entries, model, world_count, tables.clips)
    else
        try .initTwinTracking(gpa, model, world_count, tables.clips);
    defer sim.deinit();
    // On a device, its dispatches counted for the run's coverage, before the simulator is freed.
    defer if (on_a_device != null) coverage.add(&sim);
    try sim.setTracking(gpa, fleet.trackingSettings(.{}));
    try sim.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(world_count);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &sim, starts, tables.poses, model.coordinate_count, still);
    const actions_row: []f32 = try gpa.alloc(f32, sim.counts.action_count);
    defer gpa.free(actions_row);
    uploadTrackingActions(&sim, world_count, 0, actions_row);
    // THE PLANNERS: the knocked character and another, both after the candidates.
    const planner_worlds = [_]u32{ starts.knocked_to_its_end, 10 };
    const offset_count: u32 = @intCast(z.robot.actionSize(model));
    const replan_interval: u32 = 4;
    // A share of 0: each planner will take its plan's first action alone. A replan writes the planners' knots and
    // following, and must leave every other number of every character as it was.
    const plan_following_share: f32 = 0;
    var planning: robotgpu_host.Planning = try .init(
        gpa,
        sim.counts,
        sim.layout,
        &planner_worlds,
        offset_count,
        fleet.options.action_scale,
        .{
            .candidates_per_planner = candidates_per_planner,
            .replan_interval = replan_interval,
            .plan_following_share = plan_following_share,
        },
    );
    defer planning.deinit(gpa);
    // The plans: a poor action held - every offset half a radian from the reference, the stiffnesses as acted.
    try sim.startPlansFromActions(gpa, &planning);
    const poor_offset: f32 = 0.5 / fleet.options.action_scale;
    for (planning.plans, 0..) |*number, at| {
        const is_offset: bool = at % planning.action_count < offset_count;
        if (is_offset) {
            number.* = poor_offset;
        }
    }
    const candidate_count: u32 = planning.candidateCount();
    // The characters' numbers before the replan.
    const floats_before: []f32 = try gpa.alloc(f32, sim.worldArenaEnd(.world_f));
    defer gpa.free(floats_before);
    const integers_before: []u32 = try gpa.alloc(u32, sim.worldArenaEnd(.world_u));
    defer gpa.free(integers_before);
    const floats_after: []f32 = try gpa.alloc(f32, sim.worldArenaEnd(.world_f));
    defer gpa.free(floats_after);
    const integers_after: []u32 = try gpa.alloc(u32, sim.worldArenaEnd(.world_u));
    defer gpa.free(integers_after);
    try readWorldFloats(gpa, &sim, 0, floats_before);
    try readWorldIntegers(gpa, &sim, 0, integers_before);
    // Each planner's plan before: a held action, so its warm start is itself.
    const plan_numbers: usize = planning.plan_numbers;
    const plans_before: []f32 = try gpa.dupe(f32, planning.plans);
    defer gpa.free(plans_before);
    // THE REPLAN.
    var stream: Random.DefaultPrng = .init(11);
    try sim.replan(gpa, &planning, stream.random(), physics_steps);
    try readWorldFloats(gpa, &sim, 0, floats_after);
    try readWorldIntegers(gpa, &sim, 0, integers_after);
    var outcome: ReplanOutcome = .{
        .character_numbers_changed = 0,
        .warm_starts_kept = true,
        .plans_are_the_best = true,
        .scores_moved = false,
        .some_best_not_the_warm_start = false,
    };
    // Every character's number - the lookahead's own bookkeeping apart.
    const before: WorldReadBack = .{ .floats = floats_before, .integers = integers_before };
    const after: WorldReadBack = .{ .floats = floats_after, .integers = integers_after };
    var character_worlds: [world_count]u32 = undefined;
    for (&character_worlds, 0..) |*character_world, index| {
        character_world.* = @intCast(index);
    }
    const characters: []const u32 = character_worlds[candidate_count..];
    outcome.character_numbers_changed = worldsNumbersDiffering(sim.layout, characters, before, after);
    // Each planner: candidate 0 its warm start; its new plan its best candidate's knots, by the check's own search.
    for (planner_worlds, 0..) |_, planner_index| {
        const first_candidate: usize = planner_index * candidates_per_planner;
        const warm_start: []const f32 = plans_before[planner_index * plan_numbers ..][0..plan_numbers];
        const candidate_zero: []const f32 = planning.candidateKnots(first_candidate);
        if (!eql(f32, warm_start, candidate_zero)) {
            outcome.warm_starts_kept = false;
        }
        var best: usize = first_candidate;
        var candidate: usize = first_candidate;
        while (candidate < first_candidate + candidates_per_planner) : (candidate += 1) {
            const score: f32 = planning.candidate_scores[candidate];
            if (score != 0) {
                outcome.scores_moved = true;
            }
            if (score > planning.candidate_scores[best]) {
                best = candidate;
            }
        }
        if (best != first_candidate) {
            outcome.some_best_not_the_warm_start = true;
        }
        const best_knots: []const f32 = planning.candidateKnots(best);
        if (!eql(f32, best_knots, planning.planOf(planner_index))) {
            outcome.plans_are_the_best = false;
        }
    }
    return outcome;
}

/// HOW A RUN OF THE PLANNERS-IN-THE-LOOP SCENE PLANS (`runRobotgpuPlannersInTheLoop`).
const PlannersInTheLoop = enum {
    /// The trainer's loop with no planners: the loop as it was before planning.
    no_planners,
    /// Planners at a following share of 0: each takes its plan's action at the replans' own decisions alone.
    planners_following_first_decisions,
    /// Planners at a following share of 1: each follows every plan whole.
    planners_following_every_decision,
    /// Planners at a following share of 1 in the training's second phase, their plans offsets around the policy
    /// (`robot.PlanForm.offsets_around_policy`): at every decision each acts with its policy's choice plus its plan's
    /// offset, and its candidates' lookaheads are the policy's with their offsets.
    planners_around_policy,
};

/// WHAT A RUN OF THE SCENE LEFT, for a comparison with another run of it: every world's numbers and integers read
/// back whole, the layout they are placed by, the trainer's ring as the kit holds it, its books, and its counts. The
/// slices and the books are the struct's own, allocated from the run's `gpa` and freed by `deinit`.
const LoopFinish = struct {
    layout: robotgpu.Layout,
    /// The characters are the worlds from `first_character` to `world_count`: the candidates are before them. Among
    /// them, the planners.
    first_character: u32,
    world_count: u32,
    planner_worlds: [2]u32,
    /// The ring's records are `record_width` numbers each, every character's for a step side by side (step-major).
    record_width: u32,
    floats: []f32,
    integers: []u32,
    ring: []f32,
    books: z.robot_track.KeptBooks,
    exposure: u64,
    failures: u64,

    fn deinit(finish: LoopFinish, gpa: Allocator) void {
        gpa.free(finish.floats);
        gpa.free(finish.integers);
        gpa.free(finish.ring);
        finish.books.deinit(gpa);
    }

    fn worlds(finish: LoopFinish) WorldReadBack {
        return .{ .floats = finish.floats, .integers = finish.integers };
    }
};

/// A RING's RECORD for env `env` at replay index `index` (`RecordRing.recordAt`), in a kit's replay buffer read back.
fn ringRecord(
    replay_records: []const f32,
    ring: z.robot_latent_kit.RecordRing,
    env: usize,
    index: u64,
) []const f32 {
    return replay_records[ring.recordAt(env, index)..][0..ring.record];
}

/// A learner's counts after a world-model update (`Resident.trainWorld`).
const WorldUpdateCounts = struct {
    world_updates: u32 = 0,
    candidate_world_updates: u64 = 0,
    critic_updates: u32 = 0,
    windows_refused: u64 = 0,
    candidate_batches_refused: u64 = 0,
};

/// WHAT THE TRAINER's LABELS' BOOKS KEPT after a run of the planners-in-the-loop scene (`track.LabelBooks`), set
/// against the labels the planners' own flags say are kept - reckoned on the host from each planner's following and
/// its flags at every decision - and what one label update on the device did (`Resident.trainPolicyOnLabels`).
const LabelsKept = struct {
    /// The labels the reckoning keeps; those the books keep; those of the reckoning the books do not keep, and those
    /// the books keep that the reckoning does not.
    expected: u32 = 0,
    found: u32 = 0,
    missing: u32 = 0,
    unexpected: u32 = 0,
    /// The books' counts of labels dropped: with a failed plan, as a stretch's decisions after a loss, and as a
    /// stretch's last where its episode ended.
    dropped_with_failed_plans: u64 = 0,
    dropped_after_losses: u64 = 0,
    dropped_at_episode_ends: u64 = 0,
    /// The label update: how many ran and were refused, the windows it staged that were no kept label, the world
    /// model's weights it changed (none), and whether it moved the policy's.
    label_updates: u64 = 0,
    label_batches_refused: u64 = 0,
    staged_not_kept: u32 = 0,
    world_numbers_changed: u32 = 0,
    policy_moved: bool = false,
};

/// WHAT THE CANDIDATES' RECORDING HELD after a run of the planners-in-the-loop scene with planners
/// (`acceptCandidateRecording`), set against what the planners lived; and what the world model's batches by kind did.
const CandidatesRecorded = struct {
    /// Each replan's winners' records in the candidates' ring set against their planners' in the characters' ring, at
    /// the decisions each planner lived as its winner had: those compared, and those not the same to the bit. And the
    /// other candidates' first records that are the same as their planner's (none: a winner mistaken would be seen).
    winner_records_compared: u32 = 0,
    winner_records_differing: u32 = 0,
    loser_records_matching: u32 = 0,
    /// The lookaheads complete, and the candidates whose favoured flag is not whether they won their lookahead: a
    /// planner's best quarter of four candidates is its winner alone.
    lookaheads_complete: u64 = 0,
    favoured_mistaken: u32 = 0,
    /// THE GATE's PAIRS IN THE RING: each replan's candidates of one planner at its first decision, their states set
    /// against the planner's first candidate's - those compared, and those not the same to the bit (none: one copy) -
    /// and their actions against each other's - pairs the same (none: each candidate its own plan).
    pair_states_compared: u32 = 0,
    pair_states_differing: u32 = 0,
    pair_actions_same: u32 = 0,
    /// The learner's counts after a world-model update at a candidates' share of 1, then after one at 0.
    after_candidates_update: WorldUpdateCounts = .{},
    after_characters_update: WorldUpdateCounts = .{},
};

/// THE WORLD MODEL's GATE ON THE DEVICE, after the planners-in-the-loop scene with planners: a round of training whose
/// only work is the gate's measurement (`Resident.measureWorldModel`), its pairs as gathered, and its judgement once
/// the copy of the device's numbers reflects the round (`Resident.judgeGate`).
const GateOnDevice = struct {
    /// The measurements made and judged; and whether the judgement came within the round itself - the readback's lag
    /// decides that, so it is reported, not required.
    measurements: u64 = 0,
    judged: u64 = 0,
    judged_within_round: bool = false,
    /// The round's submission, and the readback generation the judged numbers came from: at least it.
    round_submission: u64 = 0,
    stats_mirrored: u64 = 0,
    /// The pairs gathered; those whose two first states are not the same to the bit (none: one replan, one copy);
    /// whose two first actions are the same (none: two candidates, two plans); whose states after the first step are
    /// the same (none: two actions, two outcomes).
    pairs: u32 = 0,
    pair_states_differing: u32 = 0,
    pair_actions_same: u32 = 0,
    pair_outcomes_same: u32 = 0,
    /// The reading judged, and the gate's numbers read straight from the device's parameters after every dispatch.
    reading: ?z.robot_track_resident.GateReading = null,
    read_back: ?z.robot_track_resident.GateReading = null,
};

/// The learner's counts after a world-model update.
fn worldUpdateCountsOf(trainer: *const z.robot_track_resident.Resident(zn_mlp)) WorldUpdateCounts {
    return .{
        .world_updates = trainer.world_updates,
        .candidate_world_updates = trainer.candidate_world_updates,
        .critic_updates = trainer.critic_updates,
        .windows_refused = trainer.windows_refused,
        .candidate_batches_refused = trainer.candidate_batches_refused,
    };
}

/// What `runRobotgpuPlannersInTheLoop` found. Its `finish` is owned: `deinit`.
const PlannersInTheLoopOutcome = struct {
    /// The planners' decisions that took their plan's action, by each planner's following read after the decision:
    /// every one at a following share of 1 (no new episode among them clears the following), the replans' own at 0.
    decisions_following: u32,
    /// Around the policy, where the learner has a flow actor: whether the last decision's flow corrections of the
    /// characters that are no planners hold numbers - the flow ran - beside the planners', which no flow corrected.
    flow_corrected_others: bool = false,
    /// Around the policy: teacher 2's examples kept on the device - how many, and how many of their numbers differ
    /// from what the check kept itself at each following decision (the follower's acting row: its condition, the
    /// action applied before, its raw action plus its plan's line), the first two to the bit, the choice within a
    /// few epsilons.
    flow_examples_kept: u32 = 0,
    flow_examples_expected: u32 = 0,
    flow_examples_of_plans_not_teaching: u32 = 0,
    flow_example_numbers_differing: u32 = 0,
    /// A round's batch drawn from the ring on the device: its rows, and those that are no kept example whole.
    flow_batch_rows: u32 = 0,
    flow_batch_rows_unmatched: u32 = 0,
    /// The batch's targets, taken against the policy before an update (`Resident.retargetFlowBatch`): the numbers
    /// that are not the synergies' projection of the row's plan's line, the policy being as it acted; then, the
    /// policy's every raw action moved by a shift, the numbers whose move is not minus the shift's projection.
    flow_target_numbers_off: u32 = 0,
    flow_target_moves_off: u32 = 0,
    /// Only plans that ended well: the ring's slots whose good mark is not "the books keep its record's label", the
    /// good slots, and the batch's and the mode rows' slots that are not good.
    flow_slots_misjudged: u32 = 0,
    flow_slots_good: u32 = 0,
    flow_batch_slots_not_good: u32 = 0,
    mode_slots_not_good: u32 = 0,
    /// On the policy's average, the live policy answering one number throughout: the last decision's raw actions
    /// that are that number (none should be: the characters act through the average), and whether the live policy,
    /// made to act on the same rows after, answered it everywhere.
    acting_numbers_from_live: u32 = 0,
    live_answers_everywhere: bool = false,
    /// One label update on the flow's main mode after the run (`Resident.trainPolicyOnFlowMode`): the kit's rows it
    /// drew, those that are no example of the ring whole, whether it was counted as a label update, and whether the
    /// live policy's weights moved.
    /// One update on the recorded labels after the run: whether it was counted, and whether the flow's weights moved
    /// in it (teacher 2's step).
    label_update_counted: bool = false,
    label_update_moved_flow: bool = false,
    /// Teacher 2's weight in that update: the physics' plans are not weighed by the trust in the critic.
    distillation_weight_after_labels: f32 = 0,
    mode_rows_drawn: u32 = 0,
    mode_rows_unmatched: u32 = 0,
    mode_update_counted: bool = false,
    mode_moved_policy: bool = false,
    /// Around the policy, with the model planner: its states after the run - how many, how many are the physics'
    /// planners (none should be), and the numbers of their characters' corrections that are not the planner's
    /// chosen first correction (none should be: its plans take the flow's place).
    model_states: u32 = 0,
    model_states_on_planners: u32 = 0,
    model_correction_numbers_differing: u32 = 0,
    /// The funnel, at the last replan: the planners whose second candidate - right after the warm start, the policy's
    /// own candidate off here - was their seed, the model planner's plan as knots, not all zero.
    funnel_planners_seeded: u32 = 0,
    /// And its states' inputs at the last decision: the features that are not their characters' acting rows' state.
    model_state_numbers_differing: u32 = 0,
    /// The following planners' recorded action numbers set against their plans' line, and the largest gap.
    actions_compared: u32,
    largest_gap_epsilons: f32,
    /// Whether some compared action differs from its plan's action a decision later: the line moves, so a planner
    /// taking its plan's action at the wrong decision would be seen.
    plan_line_moved: bool,
    /// The trainer's books' labels: the records labelled, and those whose label is not whether their world took its
    /// plan's action at that decision - every character's record compared, the planners' and the others'.
    labelled_records: u32,
    label_mismatches: u32,
    /// With planners, the candidates' lookaheads as the trainer recorded them; without, nothing.
    candidates_recorded: CandidatesRecorded,
    /// The labels the trainer kept, against the planners' own flags, and a label update on them.
    labels_kept: LabelsKept,
    /// With planners, the world model's gate measured and judged on the device; without, nothing.
    gate_on_device: GateOnDevice,
    /// The decisions' calls timed as a round's are: the simulator's pipe and the trainer's kit's by phase, and the
    /// host's clock.
    phases: MeasuredPhases,
    finish: LoopFinish,

    fn deinit(outcome: PlannersInTheLoopOutcome, gpa: Allocator) void {
        outcome.finish.deinit(gpa);
    }
};

/// THE LABELS ONE PLANNER's DECISIONS LEAVE KEPT, reckoned from what it did at each of the scene's decisions - whether
/// it followed its plan (`followed`), whether the decision failed - lost its reference, or ended its episode at a
/// loss (`failed`) - and whether it ended its episode (`episode_ended`) - and where the replans fell, every
/// `replan_interval` decisions from the first: the labels' books' rule (`track.LabelBooks`) written again from the
/// planner's side, for the books to be set against. A STRETCH is a run of followed decisions, begun anew at each
/// replan's own; it is settled once the decision after its last exists - dropped where a decision of it failed, kept
/// but for its last where its episode ended after it, kept whole otherwise - and a stretch still running at the end is
/// not settled. `out_kept[d]` says whether decision d's label is kept.
fn reckonKeptLabels(
    followed: []const bool,
    failed: []const bool,
    episode_ended: []const bool,
    replan_interval: u32,
    out_kept: []bool,
) void {
    @memset(out_kept, false);
    const decision_count: usize = followed.len;
    var first: usize = 0;
    while (first < decision_count) {
        if (!followed[first]) {
            first += 1;
            continue;
        }
        // A stretch from `first`: on while the next decision follows the same plan.
        var last: usize = first;
        var any_failed: bool = failed[first];
        const settled: bool = while (last + 1 < decision_count) {
            const next: usize = last + 1;
            const next_begins_a_plan: bool = next % replan_interval == 0;
            const same_plan_goes_on: bool = followed[next] and !next_begins_a_plan;
            if (!same_plan_goes_on) {
                break true;
            }
            last = next;
            any_failed = any_failed or failed[last];
        } else false;
        if (settled and !any_failed) {
            const kept_end: usize = if (episode_ended[last]) last else last + 1;
            @memset(out_kept[first..kept_end], true);
        }
        first = last + 1;
    }
}

/// THE WORLD MODEL's GATE, MEASURED AND JUDGED ON THE DEVICE (`GateOnDevice`), by a trainer that records its planners'
/// candidates: a round of `train` with phases on, a measurement due and no update - so the measurement's gathered
/// blocks are still in the kit afterwards - read straight from the device; then rounds' ends polled
/// (`refreshDeviceStats`, `judgeGate`) until the measurement is judged, as the rounds after it would; and the gate's
/// numbers read straight from the device's parameters once more.
fn measureGateOnDevice(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    trainer: *z.robot_track_resident.Resident(zn_mlp),
) !GateOnDevice {
    var gate_on_device: GateOnDevice = .{};
    trainer.options.phases.enabled = true;
    trainer.options.phases.gate.measure_every_minutes = 0;
    trainer.options.world_updates = 0;
    trainer.options.policy_updates = 0;
    trainer.train();
    gate_on_device.measurements = trainer.gate_measurements;
    gate_on_device.judged_within_round = trainer.gate_judged > 0;
    gate_on_device.round_submission = trainer.kit.pipe.readGeneration().submitted;
    // THE PAIRS, AS GATHERED: rows 2p and 2p + 1 of the kit's blocks.
    const kit: *const z.robot_latent_kit.LatentKit(zn_mlp) = &trainer.kit;
    const blocks: []f32 = try gpa.alloc(f32, kit.total);
    defer gpa.free(blocks);
    try expect(readBufferInto(device, queue, trainer.kit.pipe.deviceField(.acts).buffer, sliceAsBytes(blocks)));
    const features: usize = kit.features;
    const action_column: usize = kit.lead + kit.features + kit.references;
    for (0..kit.rows / 2) |pair| {
        const rows = [2]usize{ 2 * pair, 2 * pair + 1 };
        var first_states: [2][]const f32 = undefined;
        var first_actions: [2][]const f32 = undefined;
        var outcomes: [2][]const f32 = undefined;
        for (rows, 0..) |row, side| {
            const wide_row_at: usize = kit.blockX(0) + row * kit.width;
            first_states[side] = blocks[wide_row_at + kit.lead ..][0..features];
            first_actions[side] = blocks[wide_row_at + action_column ..][0..kit.actions];
            outcomes[side] = blocks[kit.blockT(1) + row * features ..][0..features];
        }
        gate_on_device.pairs += 1;
        const same_state: bool = eql(u8, sliceAsBytes(first_states[0]), sliceAsBytes(first_states[1]));
        const same_action: bool = eql(u8, sliceAsBytes(first_actions[0]), sliceAsBytes(first_actions[1]));
        const same_outcome: bool = eql(u8, sliceAsBytes(outcomes[0]), sliceAsBytes(outcomes[1]));
        gate_on_device.pair_states_differing += @intFromBool(!same_state);
        gate_on_device.pair_actions_same += @intFromBool(same_action);
        gate_on_device.pair_outcomes_same += @intFromBool(same_outcome);
    }
    // THE JUDGEMENT, polled as the rounds' ends after the measurement would poll it.
    const deadline: ReadDeadline = .start();
    while (trainer.gate_judged == 0 and !deadline.hasPassed()) {
        trainer.refreshDeviceStats();
        trainer.judgeGate();
    }
    gate_on_device.judged = trainer.gate_judged;
    gate_on_device.stats_mirrored = trainer.device_stats_mirrored orelse 0;
    gate_on_device.reading = trainer.gate_latest;
    // THE GATE's NUMBERS, straight from the device's parameters, after every dispatch: through the stats block, which
    // lies past the networks' weights.
    const stats_floats: usize = z.robot_latent_kit.DeviceStats.floats;
    const stats_end: usize = trainer.stats_at + stats_floats;
    const parameters: []f32 = try gpa.alloc(f32, stats_end);
    defer gpa.free(parameters);
    try readTrainerParameters(device, queue, trainer, parameters);
    const stats_numbers: []const f32 = parameters[trainer.stats_at..stats_end];
    const DeviceStats: type = z.robot_latent_kit.DeviceStats;
    const stats: DeviceStats = bytesToValue(DeviceStats, sliceAsBytes(stats_numbers));
    gate_on_device.read_back = .of(stats);
    return gate_on_device;
}

/// THE GATE ON THE DEVICE AS IT MUST BE (`GateOnDevice`): one measurement made and judged, from numbers that reflect
/// its round; its pairs from one state each, with two actions and two outcomes; the reading judged the device's own,
/// to the bit; every number of it finite, the no-change error and the model's above 0, the cosines in [-1, 1] and
/// not 0, the ratios above 0.
fn expectGateOnDevice(gate_on_device: GateOnDevice, pairs_expected: u32) !void {
    try expectEqual(@as(u64, 1), gate_on_device.measurements);
    try expectEqual(@as(u64, 1), gate_on_device.judged);
    try expect(gate_on_device.stats_mirrored >= gate_on_device.round_submission);
    try expectEqual(pairs_expected, gate_on_device.pairs);
    try expectEqual(@as(u32, 0), gate_on_device.pair_states_differing);
    try expectEqual(@as(u32, 0), gate_on_device.pair_actions_same);
    try expectEqual(@as(u32, 0), gate_on_device.pair_outcomes_same);
    const reading: z.robot_track_resident.GateReading = gate_on_device.reading orelse return error.NotJudged;
    const read_back: z.robot_track_resident.GateReading = gate_on_device.read_back orelse return error.NotReadBack;
    try expect(eql(u8, asBytes(&reading), asBytes(&read_back)));
    try expect(reading.world_error > 0 and isFinite(reading.world_error));
    try expect(reading.no_change_error > 0 and isFinite(reading.no_change_error));
    for ([2]f32{ reading.first_response_cosine, reading.last_response_cosine }) |cosine| {
        try expect(cosine != 0 and @abs(cosine) <= 1);
    }
    for ([2]f32{ reading.first_response_ratio, reading.last_response_ratio }) |ratio| {
        try expect(ratio > 0 and isFinite(ratio));
    }
}

/// THE LOOP's TIME BY PHASE AS IT MUST BE (`MeasuredPhases`, over `decisions` decisions with `replans` replans
/// among them - none without planners):
///
///     on the device   a decision's acting, physics, judgement and resets each a segment or more a decision, and the
///                     replans a segment or more each; no segment under the books - a read of counters, which
///                     dispatches nothing - nor under any phase the loop does not run; the times together within the
///                     span they were measured over; of a decision's three parts the physics the longest
///     on the host     the books' time holds the wait for the decision before, and is not all wait; the replans hold
///                     the wait for their candidates' scores - and no time at all without planners; every call left
///                     the phase at `other`
fn expectLoopPhases(
    measured: MeasuredPhases,
    decisions: u32,
    replans: u32,
) !void {
    const RoundPhase: type = z.robot.RoundPhase;
    var expectations: Expectations = .{ .of = "the loop's time by phase" };
    const has_planners: bool = replans > 0;
    if (has_planners) {
        const ran = [_]RoundPhase{ .replans, .acting, .physics, .judgement, .resets };
        const least_segments = [_]u32{ replans, decisions, decisions, decisions, decisions };
        measured.expectDevicePhases(&expectations, &ran, &least_segments);
    } else {
        const ran = [_]RoundPhase{ .acting, .physics, .judgement, .resets };
        const least_segments = [_]u32{ decisions, decisions, decisions, decisions };
        measured.expectDevicePhases(&expectations, &ran, &least_segments);
    }
    const physics_microseconds: f64 = measured.device.microsecondsOf(.physics);
    const judgement_microseconds: f64 = measured.device.microsecondsOf(.judgement);
    const resets_microseconds: f64 = measured.device.microsecondsOf(.resets);
    const physics_is_longest: bool =
        physics_microseconds > judgement_microseconds and physics_microseconds > resets_microseconds;
    expectations.holds(physics_is_longest, "the physics, {d:.0} microseconds, longer than the judgement, {d:.0}, " ++
        "and the resets, {d:.0}", .{ physics_microseconds, judgement_microseconds, resets_microseconds });
    // The host.
    const books_wait_ms: f64 = measured.waitMsOf(.books);
    const books_host_ms: f64 = measured.hostMsOf(.books);
    const books_wait_counted: bool = books_wait_ms > 0 and books_wait_ms < books_host_ms;
    expectations.holds(books_wait_counted, "the books' wait, {d:.3} ms, above 0 and below their {d:.3} ms", .{
        books_wait_ms,
        books_host_ms,
    });
    const replans_wait_ms: f64 = measured.waitMsOf(.replans);
    const replans_host_ms: f64 = measured.hostMsOf(.replans);
    if (has_planners) {
        const replans_wait_counted: bool = replans_wait_ms > 0 and replans_wait_ms < replans_host_ms;
        expectations.holds(replans_wait_counted, "the replans' wait, {d:.3} ms, above 0 and below their {d:.3} ms", .{
            replans_wait_ms,
            replans_host_ms,
        });
    } else {
        expectations.holds(replans_host_ms == 0, "no host time in replans without planners: {d:.3} ms", .{
            replans_host_ms,
        });
    }
    const calls_ending_elsewhere: u32 = measured.calls_ending_elsewhere;
    expectations.holds(calls_ending_elsewhere == 0, "{d} calls left the phase elsewhere than at `other`", .{
        calls_ending_elsewhere,
    });
    try expectations.finish();
}

/// PLANNERS IN A TRAINER's LOOP ON THE DEVICE (`Sim.actTrainerOnDevice` with planners, or without - `planning`):
/// the trainer-on-device scene with eight candidate worlds in front of its eight characters, two of the characters
/// planners. Eight decisions from decision 4 - two replans, at 4 and 8 - driven one call at a time. After each call,
/// each planner's following is read (`robotgpu.PlanFollowing`); where it says the planner followed its plan at that
/// decision, the planner's record - the action the physics took and the trainer's ring keeps - is set against its
/// plan's line at the decisions since the replan (`planActionAt`). With planners, the trainer records its candidates'
/// lookaheads (`acceptCandidateRecording`), and each replan's winners are noted - each planner's best candidate - to
/// be set against what the planners lived (`CandidatesRecorded`). At the end, what the run left (`LoopFinish`). On
/// the device only: the trainer acts through a GPU kit. The line itself is checked on the twin and the device by the
/// plan-actions check. AROUND THE POLICY (`PlannersInTheLoop.planners_around_policy`) a following planner's choice -
/// what the action filter then blends - is set against the policy's raw action, read from the kit's rows, plus its
/// plan's line: the offset added, nothing else.
fn runRobotgpuPlannersInTheLoop(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
    planning_mode: PlannersInTheLoop,
) !PlannersInTheLoopOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    // Two planners of four candidates each, the candidates the batch's first worlds, the characters after them.
    const planner_count: u32 = 2;
    const candidates_per_planner: u32 = 4;
    const candidate_count: u32 = planner_count * candidates_per_planner;
    const world_count: u32 = 8;
    const first_world: u32 = candidate_count;
    const simulated_worlds: u32 = candidate_count + world_count;
    const physics_steps: u32 = 2;
    // THE SCENE, as the trainer-on-device check's.
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        simulated_worlds,
        tables.clips,
    );
    defer on_device.deinit();
    // This simulator's dispatches counted for the run's coverage, before it is freed.
    defer coverage.add(&on_device);
    // Pushes as a night has them: none in the check's few decisions.
    fleet.options.pushes.every = 90;
    fleet.options.pushes.rate_per_second = 0;
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{ .offsets = 0.25, .stiffness = 0.5 });
    try on_device.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    const starts: TrackingStarts = .forWorlds(simulated_worlds);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &on_device, starts, tables.poses, model.coordinate_count, still);
    // THE PLANNERS: two steady characters - neither knocked off its reference, so neither begins a new episode in
    // the check's decisions, which would clear its flag.
    const planner_worlds = [_]u32{ first_world + 1, first_world + 3 };
    for (planner_worlds) |planner_world| {
        try expect(!starts.isKnocked(planner_world));
    }
    const offset_count: u32 = @intCast(z.robot.actionSize(model));
    const plan_horizon: u32 = on_device.counts.plan_horizon;
    const replan_interval: u32 = 4;
    const replan_count: u32 = 2;
    const plan_following_share: f32 = switch (planning_mode) {
        .no_planners, .planners_following_first_decisions => 0,
        .planners_following_every_decision, .planners_around_policy => 1,
    };
    const around_policy: bool = planning_mode == .planners_around_policy;
    var planning: robotgpu_host.Planning = try .init(
        gpa,
        on_device.counts,
        on_device.layout,
        &planner_worlds,
        offset_count,
        fleet.options.action_scale,
        // No baseline candidate: the checks follow the test's own ramps, which the policy alone, or the servo, could
        // beat (the baseline and the plans it ranks are checked with the planners chosen by trouble).
        .{
            .candidates_per_planner = candidates_per_planner,
            .replan_interval = replan_interval,
            .plan_following_share = plan_following_share,
            .baseline_candidate = false,
        },
    );
    defer planning.deinit(gpa);
    // The plans: the planners' actions with a gentle ramp on the offsets - 0.05 radians more at each knot - so the
    // line moves from decision to decision whichever candidate wins: a drawn one, or the warm start, which is the
    // ramp moved on. A plan held flat would take the same action at every decision, and a planner reading its plan a
    // decision late would pass unseen. Gentle, because a followed plan is lived: a plan far from the reference loses
    // it at once, and the new episode clears the planner's following.
    // Around the policy the plans are offsets from the start - zero, the policy itself, as the switch to the second
    // phase leaves them - and the ramp is on the offsets alone: a line that moves away from the policy's choice.
    if (around_policy) {
        planning.planAroundPolicy();
    } else {
        try on_device.startPlansFromActions(gpa, &planning);
    }
    const ramp_per_knot: f32 = 0.05 / fleet.options.action_scale;
    for (planning.plans, 0..) |*number, at| {
        const knot_index: usize = (at / planning.action_count) % planning.knot_count;
        const number_in_action: usize = at % planning.action_count;
        const is_offset: bool = number_in_action < offset_count;
        if (is_offset) {
            number.* += float(knot_index) * ramp_per_knot;
        }
    }
    var stream: Random.DefaultPrng = .init(13);
    const planners: ?robotgpu_host.TrainerPlanners = switch (planning_mode) {
        .no_planners => null,
        .planners_following_first_decisions, .planners_following_every_decision, .planners_around_policy => .{
            .planning = &planning,
            .random = stream.random(),
        },
    };
    // THE TRAINER, as the trainer-on-device check's.
    var kit_pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer kit_pipe.deinit();
    const feature_count: usize = z.robot_track.localSize(model.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    for (means, spreads, 0..) |*mean, *spread, feature| {
        const position: f32 = float(feature);
        mean.* = 0.01 * position;
        spread.* = 0.5 + 0.001 * position;
    }
    const Trainer: type = z.robot_track_resident.Resident(zn_mlp);
    const normalizer: z.robot_latent.Normalizer = .{ .mean = means, .spread = spreads };
    // Around the policy, the training is in its second phase from the start - the plans switch to offsets at the
    // first replan - and its actor is a flow correcting the policy: the planners that follow their plans take their
    // plans' offsets in its place, and every other character its correction.
    const trainer_options: z.robot_track_resident.Options = .{
        .rows = 4,
        .window = 4,
        .hidden = 16,
        .policy_hidden = 16,
        .collect = 4,
        .train_critic = true,
        .phases = .{ .enabled = around_policy },
        .actor = if (around_policy) .flow else .gaussian,
        // The flow learns from the plans alone, and corrects the policy's slow average: the characters, the
        // candidates and the model planner act through the average, and teacher 2's targets are taken against it.
        .flow = .{ .hidden_width = 8, .hidden_layers = 1, .fpo_rows = 0, .flow_dpg = false, .base = .policy_average },
        .policy_average_decay = if (around_policy) 0.995 else 0,
        // Around the policy, the world model has its skip head; and the model planner plans too: for the physics'
        // two planners and one character beside them, each decision, its plans' last step through the skip head. The
        // skip head is a last layer beside the dense model's, so the world model takes SuperTrack's dense form there
        // rather than the foundation's normed one (`robot_latent_kit.LatentKit.initInForm`).
        .skip_steps = if (around_policy) 4 else 0,
        .world_form = if (around_policy) .dense_tanh else .normed_silu,
        .planning = .{
            .enabled = around_policy,
            .flags = .{ .budget = 3 },
            .candidates = 8,
            .horizon = 4,
            .skip_steps = 1,
            .rounds = 2,
            .elites = 2,
            .flow_plans = 1,
        },
    };
    const trainer: *Trainer = try .init(gpa, &kit_pipe, fleet, normalizer, trainer_options);
    defer trainer.deinit();
    if (around_policy) {
        trainer.beginPhaseTwo();
    }
    const arrays: robotgpu.WorldStateLayout = on_device.layout.world_f;
    try trainer.acceptDeviceActing(first_world, world_count, arrays.policy_inputs.stride, arrays.actions.stride);
    // THE CANDIDATES' RECORDING, with planners: every replan's lookahead - its decisions' records and the state after
    // them - kept whole, both replans'.
    const lookahead_records: u32 = plan_horizon + 1;
    if (planners != null) {
        try trainer.acceptCandidateRecording(candidate_count, candidates_per_planner, plan_horizon, replan_count);
    }
    if (around_policy) {
        try trainer.acceptCandidateActing(candidate_count);
    }
    // Around the policy, on the average: the live policy made to answer one number - its last layer's weights zero,
    // its bias that number - while the average keeps the weights it started from. Any action the live policy chose
    // would show it.
    const live_answer: f32 = 7;
    if (around_policy) {
        const live_weights: z.robot_latent_kit.LatentKit(zn_mlp).PolicyWeights = trainer.kit.policyWeights();
        const last_layer_count: usize = trainer.kit.policy_hidden * trainer.kit.actions;
        const last_layer: []f32 = try gpa.alloc(f32, last_layer_count + trainer.kit.actions);
        defer gpa.free(last_layer);
        @memset(last_layer[0..last_layer_count], 0);
        @memset(last_layer[last_layer_count..], live_answer);
        kit_pipe.uploadAt(.params, live_weights.third, last_layer);
    }
    // Around the policy: each following planner's choice, and the policy's raw actions - the characters' acting rows
    // of the kit, read from its activations' start to their end.
    const chosen_block: []f32 = try gpa.alloc(f32, on_device.counts.action_count);
    defer gpa.free(chosen_block);
    const character_rows: z.robot_latent_kit.LatentKit(zn_mlp).PolicyRows = trainer.device_acting.?.rows;
    // The acting rows' raw actions, then the actions applied before them, reserved after.
    const raw_rows_end: usize = character_rows.applied_at + character_rows.rows * character_rows.raw_stride;
    const kit_activations_to_raw: []f32 = try gpa.alloc(f32, raw_rows_end);
    defer gpa.free(kit_activations_to_raw);
    // Around the policy: teacher 2's examples as the check expects them, in the order they were kept - decision by
    // decision, the followers in the order of their rows - a condition, an applied action and a choice each; and
    // each one's plan's line, the offset its target should be while the policy stays as it acted.
    const condition_width: usize = trainer.kit.lead + trainer.kit.features;
    const example_width: usize = condition_width + 2 * trainer.kit.actions;
    const expected_examples: []f32 = try gpa.alloc(f32, planner_count * 8 * example_width);
    defer gpa.free(expected_examples);
    const expected_offsets: []f32 = try gpa.alloc(f32, planner_count * 8 * trainer.kit.actions);
    defer gpa.free(expected_offsets);
    var expected_example_count: usize = 0;
    var examples_of_plans_not_teaching: u32 = 0;
    // THE DECISIONS, one call each, from a replan's own number: the first decision replans.
    const first_decision_number: u32 = replan_interval;
    const decision_count: u32 = replan_count * replan_interval;
    const exploration_spread: f32 = 0.3;
    const records: @FieldType(robotgpu.WorldStateLayout, "records") = arrays.records;
    const counters: robotgpu.WorldIntegersLayout = on_device.layout.world_u;
    const action_count: u32 = on_device.counts.action_count;
    const record_block: []f32 = try gpa.alloc(f32, records.stride);
    defer gpa.free(record_block);
    const expected_action: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(expected_action);
    const later_action: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(later_action);
    var following_read: [1]u32 = undefined;
    // Whether each planner took its plan's action at each decision, by its following: what its record's label must
    // say.
    var followed_at: [planner_count][decision_count]bool = @splat(@splat(false));
    // Whether each planner's decision failed - lost its reference, or ended its episode at a loss - and whether it
    // ended the episode, from the flags the decision left: what the labels' books must make of each stretch.
    var failed_at: [planner_count][decision_count]bool = @splat(@splat(false));
    var episode_ended_at: [planner_count][decision_count]bool = @splat(@splat(false));
    var flags_read: [1]u32 = undefined;
    // Each replan's winners: each planner's best candidate, whose knots became its plan.
    var winners: [replan_count][planner_count]usize = @splat(@splat(0));
    var decisions_following: u32 = 0;
    var actions_compared: u32 = 0;
    var largest_gap_epsilons: f32 = 0;
    var plan_line_moved: bool = false;
    var device_events: robotgpu_host.DeviceEvents = .{};
    // THE DECISIONS' TIME BY PHASE, measured as a training round's is: both pipes timed from here on - the
    // simulator's and the trainer's kit's - and a host's clock the simulator tells the phases.
    var phases: MeasuredPhases = .{};
    try expect(try on_device.pipe.enableTimings(.{}));
    try expect(try kit_pipe.enableTimings(.{}));
    on_device.phase_clock = &phases.clock;
    defer on_device.phase_clock = null;
    phases.clock.begin(wgpu.nowMs());
    var decision: u32 = 0;
    while (decision < decision_count) : (decision += 1) {
        const decision_number: u32 = first_decision_number + decision;
        const one_decision: u32 = 1;
        try on_device.actTrainerOnDevice(
            zn_mlp,
            gpa,
            trainer,
            one_decision,
            decision_number,
            physics_steps,
            .{ .exploration_spread = exploration_spread, .flow_scale = 1 },
            planners,
            &device_events,
        );
        const pipe_phases = [_]u32{ on_device.pipe.phase, kit_pipe.phase };
        const left_in_other: bool = MeasuredPhases.leftInOther(phases.clock, &pipe_phases);
        phases.calls_ending_elsewhere += @intFromBool(!left_in_other);
        const decisions_since_replan: u32 = decision_number % replan_interval;
        const is_replan_decision: bool = decisions_since_replan == 0;
        if (planners != null and is_replan_decision) {
            const replan_index: u32 = decision / replan_interval;
            for (&winners[replan_index], 0..) |*winner, planner_index| {
                const first_candidate: usize = planning.firstCandidateOf(planner_index);
                const scores: []const f32 = planning.candidate_scores;
                const block_scores: []const f32 = scores[first_candidate..][0..candidates_per_planner];
                winner.* = first_candidate + robotgpu_host.bestInBlock(block_scores);
            }
        }
        for (planner_worlds, 0..) |planner_world, planner_index| {
            // Whether the planner took its plan's action at this decision: by its following, and the decision.
            try readWorldIntegers(gpa, &on_device, counters.plan_following.at(planner_world, 0), &following_read);
            const following: u32 = following_read[0];
            const at_every_decision: bool = following == @backingInt(robotgpu.PlanFollowing.every_decision);
            const at_first_decision: bool = following == @backingInt(robotgpu.PlanFollowing.first_decision);
            const followed: bool = at_every_decision or (at_first_decision and is_replan_decision);
            followed_at[planner_index][decision] = followed;
            try readWorldIntegers(gpa, &on_device, counters.episode_flags.at(planner_world, 0), &flags_read);
            const flags: u32 = flags_read[0];
            const lost: bool = flags & robotgpu.episodeFlagBit(.lost) != 0;
            const ended_at_a_loss: bool = flags & robotgpu.episodeFlagBit(.ends_at_loss) != 0;
            failed_at[planner_index][decision] = lost or ended_at_a_loss;
            episode_ended_at[planner_index][decision] = flags & robotgpu.episodeFlagBit(.finished) != 0;
            if (!followed) {
                continue;
            }
            decisions_following += 1;
            // The record: the features, then the action as the physics took it.
            try readWorldFloats(gpa, &on_device, records.at(planner_world, 0), record_block);
            const recorded_action: []const f32 = record_block[feature_count..][0..action_count];
            const plan: []const f32 = planning.planOf(planner_index);
            const knot_count: u32 = planning.knot_count;
            const horizon: f32 = float(plan_horizon);
            const plan_decision: f32 = float(decisions_since_replan);
            robotgpu_host.planActionAt(plan, knot_count, action_count, horizon, plan_decision, expected_action);
            const next_plan_decision: f32 = plan_decision + 1;
            robotgpu_host.planActionAt(plan, knot_count, action_count, horizon, next_plan_decision, later_action);
            if (!eql(f32, expected_action, later_action)) {
                plan_line_moved = true;
            }
            if (around_policy) {
                // The choice the filter blended: the policy's raw action plus the plan's line, unexplored.
                try readWorldFloats(gpa, &on_device, arrays.chosen_actions.at(planner_world, 0), chosen_block);
                const acts_buffer: wgpu.BufferHandle = kit_pipe.deviceField(.acts).buffer;
                try expect(readBufferInto(device, queue, acts_buffer, sliceAsBytes(kit_activations_to_raw)));
                const planner_env: u32 = planner_world - first_world;
                const raw_at: usize = character_rows.raw_at + planner_env * character_rows.raw_stride;
                const raw_action: []const f32 = kit_activations_to_raw[raw_at..][0..action_count];
                for (chosen_block, raw_action, expected_action) |chosen, raw, offset| {
                    const raw_with_offset: f32 = raw + offset;
                    const gap: f32 = robotgpu_host.gapInUnits(chosen, raw_with_offset, 0x1p-21);
                    largest_gap_epsilons = @max(largest_gap_epsilons, gap);
                    actions_compared += 1;
                }
                // Teacher 2's example of this decision - when the planner's plan teaches (`Planning.planTeaches`) -
                // from the follower's acting row: its condition, the action applied before, its raw action plus its
                // plan's line.
                if (!planning.planTeaches(planner_world)) {
                    examples_of_plans_not_teaching += 1;
                    continue;
                }
                const policy_actions: usize = trainer.kit.actions;
                const example: []f32 = expected_examples[expected_example_count * example_width ..][0..example_width];
                const inputs_at: usize = character_rows.inputs_at + planner_env * character_rows.input_stride;
                const applied_at: usize = character_rows.applied_at + planner_env * character_rows.raw_stride;
                @memcpy(example[0..condition_width], kit_activations_to_raw[inputs_at..][0..condition_width]);
                const applied_kept: []f32 = example[condition_width..][0..policy_actions];
                @memcpy(applied_kept, kit_activations_to_raw[applied_at..][0..policy_actions]);
                const choice_kept: []f32 = example[condition_width + policy_actions ..][0..policy_actions];
                const raw_kept: []const f32 = raw_action[0..policy_actions];
                const line_kept: []const f32 = expected_action[0..policy_actions];
                for (choice_kept, raw_kept, line_kept) |*choice, raw, line| {
                    choice.* = raw + line;
                }
                const offsets_at: usize = expected_example_count * policy_actions;
                const offset_kept: []f32 = expected_offsets[offsets_at..][0..policy_actions];
                @memcpy(offset_kept, expected_action[0..policy_actions]);
                expected_example_count += 1;
                continue;
            }
            for (recorded_action, expected_action) |recorded, expected| {
                // A plan's offsets stay within their reach, three action units; its stiffnesses are the policy's,
                // of the same size: a scale of four.
                const gap: f32 = robotgpu_host.gapInUnits(recorded, expected, 0x1p-21);
                largest_gap_epsilons = @max(largest_gap_epsilons, gap);
                actions_compared += 1;
            }
        }
        // Around the policy, after each replan: the second planner's plan made one that does not teach, until the
        // next replan judges again - its examples must not be kept.
        if (around_policy and is_replan_decision) {
            planning.teaches[1] = false;
        }
    }
    // Around the policy: the flow's corrections of the characters that are no planners, as the last decision left them.
    var flow_corrected_others: bool = false;
    if (around_policy) {
        const corrections: @FieldType(robotgpu.WorldStateLayout, "flow_corrections") = arrays.flow_corrections;
        const correction_row: []f32 = try gpa.alloc(f32, corrections.stride);
        defer gpa.free(correction_row);
        var character: u32 = 0;
        while (character < world_count) : (character += 1) {
            const world: u32 = first_world + character;
            const is_planner: bool = indexOfScalar(u32, &planner_worlds, world) != null;
            if (is_planner) {
                continue;
            }
            try readWorldFloats(gpa, &on_device, corrections.at(world, 0), correction_row);
            for (correction_row[0..on_device.counts.action_count]) |number| {
                flow_corrected_others = flow_corrected_others or number != 0;
            }
        }
    }
    // Around the policy: the model planner's states, and its characters' corrections against its chosen first
    // corrections (the synergies the identity: the same numbers).
    var model_states: u32 = 0;
    var model_states_on_planners: u32 = 0;
    var model_correction_numbers_differing: u32 = 0;
    var model_state_numbers_differing: u32 = 0;
    var funnel_planners_seeded: u32 = 0;
    if (trainer.planner != null) {
        for (planner_worlds, 0..) |_, planner_index| {
            const first_candidate: usize = planning.firstCandidateOf(planner_index);
            const seed: []const f32 = planning.seedOf(planner_index);
            // Without the policy's own candidate here, the seed is right after the warm start.
            const second: []const f32 = planning.candidateKnots(first_candidate + 1);
            const seed_taken: bool = eql(u8, sliceAsBytes(seed), sliceAsBytes(second));
            const seed_moves: bool = for (seed) |number| {
                if (number != 0) {
                    break true;
                }
            } else false;
            funnel_planners_seeded += @intFromBool(seed_taken and seed_moves);
        }
    }
    if (trainer.planner) |planner| {
        const corrections: @FieldType(robotgpu.WorldStateLayout, "flow_corrections") = arrays.flow_corrections;
        const correction_row: []f32 = try gpa.alloc(f32, corrections.stride);
        defer gpa.free(correction_row);
        const state_width: usize = trainer.kit.features + 2;
        const chosen_end: usize = @max(
            planner.mppi.actions_offset + trainer.slot_owners.len * trainer.kit.actions,
            @max(planner.state_inputs_at + trainer.slot_owners.len * state_width, raw_rows_end),
        );
        const kit_acts_to_chosen: []f32 = try gpa.alloc(f32, chosen_end);
        defer gpa.free(kit_acts_to_chosen);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.acts).buffer, sliceAsBytes(kit_acts_to_chosen)));
        for (trainer.slot_owners, 0..) |owner, state| {
            const character: u32 = @intCast(owner orelse continue);
            model_states += 1;
            const world: u32 = first_world + character;
            model_states_on_planners += @intFromBool(indexOfScalar(u32, &planner_worlds, world) != null);
            try readWorldFloats(gpa, &on_device, corrections.at(world, 0), correction_row);
            const chosen_at: usize = planner.mppi.actions_offset + state * trainer.kit.actions;
            const chosen: []const f32 = kit_acts_to_chosen[chosen_at..][0..trainer.kit.actions];
            for (correction_row[0..trainer.kit.actions], chosen) |correction, chosen_number| {
                model_correction_numbers_differing += @intFromBool(correction != chosen_number);
            }
            // The state it planned from: its character's acting row's state, after the goal.
            const inputs_at: usize = character_rows.inputs_at + character * character_rows.input_stride;
            const state_at: usize = inputs_at + trainer.kit.lead;
            const acting_state: []const f32 = kit_acts_to_chosen[state_at..][0..trainer.kit.features];
            const planned_at: usize = planner.state_inputs_at + state * state_width;
            const planned_from: []const f32 = kit_acts_to_chosen[planned_at..][0..trainer.kit.features];
            for (acting_state, planned_from) |acting_number, planned_number| {
                model_state_numbers_differing += @intFromBool(acting_number != planned_number);
            }
        }
    }
    // Around the policy: teacher 2's ring, read back, against the examples the check kept.
    var flow_examples_kept: u32 = 0;
    var flow_example_numbers_differing: u32 = 0;
    var flow_batch_rows: u32 = 0;
    var flow_batch_rows_unmatched: u32 = 0;
    var flow_target_numbers_off: u32 = 0;
    var flow_target_moves_off: u32 = 0;
    var flow_slots_misjudged: u32 = 0;
    var flow_slots_good: u32 = 0;
    var flow_batch_slots_not_good: u32 = 0;
    if (trainer.device_acting.?.flow_examples) |examples| {
        flow_examples_kept = examples.count;
        // Each slot good exactly when the books keep its record's label: its stretch ended well.
        const labels: z.robot_track.LabelBooks = trainer.device_acting.?.books.labels;
        const kept_labels: []const z.robot_track.Label = labels.kept[0..labels.kept_count];
        for (0..examples.count) |slot| {
            const label_kept: bool = for (kept_labels) |label| {
                const is_its_label: bool = label.env == examples.slot_character[slot] and
                    label.index == examples.slot_record[slot];
                if (is_its_label) {
                    break true;
                }
            } else false;
            flow_slots_misjudged += @intFromBool(examples.slot_good[slot] != label_kept);
            flow_slots_good += @intFromBool(examples.slot_good[slot]);
        }
        const ring_end: usize = examples.ring_at + expected_example_count * example_width;
        const kit_acts_to_ring: []f32 = try gpa.alloc(f32, ring_end);
        defer gpa.free(kit_acts_to_ring);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.acts).buffer, sliceAsBytes(kit_acts_to_ring)));
        const ring: []const f32 = kit_acts_to_ring[examples.ring_at..ring_end];
        for (ring, expected_examples[0 .. expected_example_count * example_width], 0..) |kept, expected, at| {
            const is_choice: bool = at % example_width >= condition_width + trainer.kit.actions;
            const same: bool = if (is_choice)
                robotgpu_host.gapInUnits(kept, expected, 0x1p-21) <= 4
            else
                kept == expected;
            flow_example_numbers_differing += @intFromBool(!same);
        }
        // A round's batch, drawn on the device: every row one of the ring's examples - its condition, applied action
        // and choice - whole, to the bit.
        // Drawn into the learner's own distillation, as a round draws it: the targets below are taken from it.
        const learning: *z.robot_latent_kit.FlowActor(zn_mlp).Learning = &trainer.kit.flow_actor.?.learning.?;
        const distillation: *z.robot_latent_kit.FlowActor(zn_mlp).Distillation = &learning.distillation.?;
        trainer.drawFlowBatchOnDevice(examples, distillation);
        for (examples.batch_table) |slot_number| {
            const slot: usize = @trunc(slot_number);
            flow_batch_slots_not_good += @intFromBool(!examples.slot_good[slot]);
        }
        const batch_rows: usize = distillation.trainer.rows;
        const action_count_policy: usize = trainer.kit.actions;
        const synergy_count: usize = trainer.kit.flow_actor.?.correction.synergy_count;
        const batch_end: usize = @max(
            distillation.conditions_at + batch_rows * condition_width,
            @max(
                examples.batch_applied_at + batch_rows * action_count_policy,
                examples.batch_choices_at + batch_rows * action_count_policy,
            ),
        );
        const kit_acts_to_batch: []f32 = try gpa.alloc(f32, batch_end);
        defer gpa.free(kit_acts_to_batch);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.acts).buffer, sliceAsBytes(kit_acts_to_batch)));
        flow_batch_rows = @intCast(batch_rows);
        // Each batch row's slot, for its targets below.
        const batch_slots: []?usize = try gpa.alloc(?usize, batch_rows);
        defer gpa.free(batch_slots);
        for (0..batch_rows, batch_slots) |row, *batch_slot| {
            const condition: []const f32 =
                kit_acts_to_batch[distillation.conditions_at + row * condition_width ..][0..condition_width];
            const applied: []const f32 =
                kit_acts_to_batch[examples.batch_applied_at + row * action_count_policy ..][0..action_count_policy];
            const choice: []const f32 =
                kit_acts_to_batch[examples.batch_choices_at + row * action_count_policy ..][0..action_count_policy];
            batch_slot.* = for (0..expected_example_count) |slot| {
                const kept: []const f32 = ring[slot * example_width ..][0..example_width];
                const kept_applied: []const f32 = kept[condition_width..][0..action_count_policy];
                const kept_choice: []const f32 = kept[condition_width + action_count_policy ..][0..action_count_policy];
                const same_condition: bool = eql(u8, sliceAsBytes(kept[0..condition_width]), sliceAsBytes(condition));
                const same_applied: bool = eql(u8, sliceAsBytes(kept_applied), sliceAsBytes(applied));
                const same_choice: bool = eql(u8, sliceAsBytes(kept_choice), sliceAsBytes(choice));
                if (same_condition and same_applied and same_choice) {
                    break slot;
                }
            } else null;
            flow_batch_rows_unmatched += @intFromBool(batch_slot.* == null);
        }
        // The targets against the policy as it acted: each row's plan's line, in the synergies' coefficients
        // c[j] = sum over a of B[j][a] line[a] - the policy answering the same row as it did when it acted.
        const correction: z.robot_latent_kit.FlowActor(zn_mlp).Correction = trainer.kit.flow_actor.?.correction;
        // The base's weights - the average's: the policy the targets are taken against.
        const policy_weights: z.robot_latent_kit.LatentKit(zn_mlp).PolicyWeights = trainer.baseKit().policyWeights();
        const bias_at: usize = policy_weights.third + trainer.kit.policy_hidden * action_count_policy;
        const synergies_end: usize = correction.synergies_at + synergy_count * action_count_policy;
        const params_end: usize = @max(synergies_end, bias_at + action_count_policy);
        const kit_params: []f32 = try gpa.alloc(f32, params_end);
        defer gpa.free(kit_params);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.params).buffer, sliceAsBytes(kit_params)));
        const synergies: []const f32 = kit_params[correction.synergies_at..][0 .. synergy_count * action_count_policy];
        trainer.retargetFlowBatch();
        const targets_end: usize = distillation.trainer.actions_at + batch_rows * synergy_count;
        const targets_before: []f32 = try gpa.alloc(f32, targets_end);
        defer gpa.free(targets_before);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.acts).buffer, sliceAsBytes(targets_before)));
        for (batch_slots, 0..) |batch_slot, row| {
            const slot: usize = batch_slot orelse continue;
            const line: []const f32 = expected_offsets[slot * action_count_policy ..][0..action_count_policy];
            for (0..synergy_count) |synergy| {
                const synergy_row: []const f32 = synergies[synergy * action_count_policy ..][0..action_count_policy];
                var projected: f32 = 0;
                for (synergy_row, line) |basis, offset| {
                    projected += basis * offset;
                }
                const target: f32 = targets_before[distillation.trainer.actions_at + row * synergy_count + synergy];
                flow_target_numbers_off += @intFromBool(robotgpu_host.gapInUnits(target, projected, 0x1p-18) > 4);
            }
        }
        // The base's every raw action moved by a shift - its last layer's bias - and the targets taken again: each
        // moves by minus the shift's projection, what the policy now answers no longer the flow's to add. The bias
        // put back after.
        const shift: f32 = 0.25;
        const bias: []const f32 = kit_params[bias_at..][0..action_count_policy];
        const shifted_bias: []f32 = try gpa.alloc(f32, action_count_policy);
        defer gpa.free(shifted_bias);
        for (shifted_bias, bias) |*shifted, original| {
            shifted.* = original + shift;
        }
        kit_pipe.uploadAt(.params, @intCast(bias_at), shifted_bias);
        trainer.retargetFlowBatch();
        const targets_after: []f32 = try gpa.alloc(f32, targets_end);
        defer gpa.free(targets_after);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.acts).buffer, sliceAsBytes(targets_after)));
        kit_pipe.uploadAt(.params, @intCast(bias_at), bias);
        for (0..batch_rows) |row| {
            for (0..synergy_count) |synergy| {
                const synergy_row: []const f32 = synergies[synergy * action_count_policy ..][0..action_count_policy];
                var shift_projected: f32 = 0;
                for (synergy_row) |basis| {
                    shift_projected += basis * shift;
                }
                const target_at: usize = distillation.trainer.actions_at + row * synergy_count + synergy;
                const moved: f32 = targets_after[target_at] - targets_before[target_at];
                flow_target_moves_off += @intFromBool(robotgpu_host.gapInUnits(moved, -shift_projected, 0x1p-18) > 4);
            }
        }
    }
    // Around the policy, on the average: the last decision's raw actions, none the live policy's answer; then the
    // live policy acting on the same rows, its every answer that number - the check could have seen it.
    var acting_numbers_from_live: u32 = 0;
    var live_answers_everywhere: bool = false;
    if (around_policy) {
        const acts_buffer: wgpu.BufferHandle = kit_pipe.deviceField(.acts).buffer;
        try expect(readBufferInto(device, queue, acts_buffer, sliceAsBytes(kit_activations_to_raw)));
        for (0..character_rows.rows) |row| {
            const raw_at: usize = character_rows.raw_at + row * character_rows.raw_stride;
            for (kit_activations_to_raw[raw_at..][0..trainer.kit.actions]) |number| {
                acting_numbers_from_live += @intFromBool(number == live_answer);
            }
        }
        trainer.kit.actOnRows(character_rows);
        try expect(readBufferInto(device, queue, acts_buffer, sliceAsBytes(kit_activations_to_raw)));
        live_answers_everywhere = for (0..character_rows.rows) |row| {
            const raw_at: usize = character_rows.raw_at + row * character_rows.raw_stride;
            const answers: []const f32 = kit_activations_to_raw[raw_at..][0..trainer.kit.actions];
            const all_the_answer: bool = for (answers) |number| {
                if (number != live_answer) {
                    break false;
                }
            } else true;
            if (!all_the_answer) {
                break false;
            }
        } else true;
    }
    // Around the policy: one update on the recorded labels - the flow's turn at the plans inside it: counted as a
    // label update, the flow's weights moved by teacher 2's step.
    var label_update_counted: bool = false;
    var label_update_moved_flow: bool = false;
    var distillation_weight_after_labels: f32 = 0;
    if (trainer.device_acting.?.flow_examples != null) {
        const network = trainer.kit.flow_actor.?.flow.network;
        const flow_start: usize = network.paramsStart();
        const flow_end: usize = network.paramsEnd();
        const flow_before: []f32 = try gpa.alloc(f32, flow_end);
        defer gpa.free(flow_before);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.params).buffer, sliceAsBytes(flow_before)));
        const labels_before: u64 = trainer.label_updates;
        const first_slot: u32 = 0;
        trainer.trainPolicyOnLabels(first_slot);
        label_update_counted = trainer.label_updates == labels_before + 1;
        const flow_after: []f32 = try gpa.alloc(f32, flow_end);
        defer gpa.free(flow_after);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.params).buffer, sliceAsBytes(flow_after)));
        label_update_moved_flow = !eql(f32, flow_before[flow_start..flow_end], flow_after[flow_start..flow_end]);
        const learning_after: z.robot_latent_kit.FlowActor(zn_mlp).Learning = trainer.kit.flow_actor.?.learningPart();
        distillation_weight_after_labels = learning_after.distillation.?.weight;
    }
    // Around the policy: one label update on the flow's main mode - its rows drawn from the ring, each of the kit's
    // label rows (its condition, its applied action) and its choice one of the ring's examples whole; counted as a
    // label update; the live policy's weights moved.
    var mode_rows_unmatched: u32 = 0;
    var mode_rows_drawn: u32 = 0;
    var mode_slots_not_good: u32 = 0;
    var mode_update_counted: bool = false;
    var mode_moved_policy: bool = false;
    if (trainer.device_acting.?.flow_examples) |examples| {
        const policy_end: usize = trainer.kit.p_at + trainer.kit.policy_count;
        const policy_before: []f32 = try gpa.alloc(f32, policy_end);
        defer gpa.free(policy_before);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.params).buffer, sliceAsBytes(policy_before)));
        const label_updates_before: u64 = trainer.label_updates;
        trainer.trainPolicyOnFlowMode();
        mode_update_counted = trainer.label_updates == label_updates_before + 1;
        for (examples.mode_table) |slot_number| {
            const slot: usize = @trunc(slot_number);
            mode_slots_not_good += @intFromBool(!examples.slot_good[slot]);
        }
        const policy_after: []f32 = try gpa.alloc(f32, policy_end);
        defer gpa.free(policy_after);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.params).buffer, sliceAsBytes(policy_after)));
        const live_before: []const f32 = policy_before[trainer.kit.p_at..policy_end];
        mode_moved_policy = !eql(f32, live_before, policy_after[trainer.kit.p_at..policy_end]);
        const label_rows: z.robot_latent_kit.LatentKit(zn_mlp).LabelRows = trainer.kit.labelRows();
        const policy_actions: usize = trainer.kit.actions;
        const mode_rows: usize = examples.mode_table.len;
        const ring_end: usize = examples.ring_at + expected_example_count * example_width;
        const acts_end: usize = @max(
            @max(ring_end, examples.mode_choices_at + mode_rows * policy_actions),
            @max(
                label_rows.conditions_at + mode_rows * label_rows.condition_stride,
                label_rows.applied_at + mode_rows * policy_actions,
            ),
        );
        const kit_acts_to_mode: []f32 = try gpa.alloc(f32, acts_end);
        defer gpa.free(kit_acts_to_mode);
        try expect(readBufferInto(device, queue, kit_pipe.deviceField(.acts).buffer, sliceAsBytes(kit_acts_to_mode)));
        const ring_now: []const f32 = kit_acts_to_mode[examples.ring_at..ring_end];
        mode_rows_drawn = @intCast(mode_rows);
        for (0..mode_rows) |row| {
            const conditions_at: usize = label_rows.conditions_at + row * label_rows.condition_stride;
            const condition: []const f32 = kit_acts_to_mode[conditions_at..][0..condition_width];
            const applied_at: usize = label_rows.applied_at + row * policy_actions;
            const applied: []const f32 = kit_acts_to_mode[applied_at..][0..policy_actions];
            const choice_at: usize = examples.mode_choices_at + row * policy_actions;
            const choice: []const f32 = kit_acts_to_mode[choice_at..][0..policy_actions];
            const matched: bool = for (0..expected_example_count) |slot| {
                const kept: []const f32 = ring_now[slot * example_width ..][0..example_width];
                const kept_applied: []const f32 = kept[condition_width..][0..policy_actions];
                const kept_choice: []const f32 = kept[condition_width + policy_actions ..][0..policy_actions];
                const same_condition: bool = eql(u8, sliceAsBytes(kept[0..condition_width]), sliceAsBytes(condition));
                const same_applied: bool = eql(u8, sliceAsBytes(kept_applied), sliceAsBytes(applied));
                const same_choice: bool = eql(u8, sliceAsBytes(kept_choice), sliceAsBytes(choice));
                if (same_condition and same_applied and same_choice) {
                    break true;
                }
            } else false;
            mode_rows_unmatched += @intFromBool(!matched);
        }
    }
    // The decisions' time, read once after the last: the read waits for both pipes' marks.
    phases.clock.end(wgpu.nowMs());
    phases.device.readFrom(robotgpu, &on_device.pipe);
    phases.device.readFrom(zn_mlp, &kit_pipe);
    // THE LABELS IN THE BOOKS: a planner's record labelled exactly where it took its plan's action, no other
    // character's ever.
    const run_books: z.robot_track.KeptBooks = trainer.device_acting.?.books;
    var labelled_records: u32 = 0;
    var label_mismatches: u32 = 0;
    var env: u32 = 0;
    while (env < world_count) : (env += 1) {
        const character_world: u32 = first_world + env;
        const planner_found: ?usize = indexOfScalar(u32, &planner_worlds, character_world);
        var record_index: u32 = 0;
        while (record_index < decision_count) : (record_index += 1) {
            const labelled: bool = run_books.labelledAt(env, record_index);
            const expected: bool = if (planner_found) |planner_index|
                followed_at[planner_index][record_index]
            else
                false;
            if (labelled) {
                labelled_records += 1;
            }
            if (labelled != expected) {
                label_mismatches += 1;
            }
        }
    }
    // THE KIT's REPLAY BUFFER, read once: the characters' ring, and the candidates' where they were recorded.
    const characters_ring: z.robot_latent_kit.RecordRing = trainer.data.ring;
    try expect(characters_ring.capacity >= decision_count);
    var records_end: usize = characters_ring.at + characters_ring.floats();
    if (trainer.candidate_recording) |recording| {
        records_end = @max(records_end, recording.ring.at + recording.ring.floats());
    }
    const replay_records: []f32 = try gpa.alloc(f32, records_end);
    defer gpa.free(replay_records);
    try expect(readBufferInto(device, queue, kit_pipe.deviceField(.ring).buffer, sliceAsBytes(replay_records)));
    // THE WINNERS' LOOKAHEADS, LIVED: each replan's winner recorded its lookahead in the candidates' ring, decision
    // by decision; its planner then lived the same decisions, recorded in the characters' ring, for as long as it
    // followed its plan - from the replan's own decision until the first it did not follow, after which it stands
    // elsewhere. Those records are the same to the bit: the planner was the winner's copy, took the winner's
    // actions, and was stepped by the same programs. The other candidates' first records are not the planner's -
    // the same state, other actions - so a winner mistaken would be seen.
    var candidates_recorded: CandidatesRecorded = .{};
    if (trainer.candidate_recording) |recording| {
        const candidate_ring: z.robot_latent_kit.RecordRing = recording.ring;
        for (winners, 0..) |replan_winners, replan_index| {
            const replan_decision: u32 = @as(u32, @intCast(replan_index)) * replan_interval;
            const lookahead_first_index: u64 = replan_index * lookahead_records;
            for (planner_worlds, replan_winners, 0..) |planner_world, winner, planner_index| {
                const planner_env: usize = planner_world - first_world;
                var plan_decision: u32 = 0;
                while (plan_decision < replan_interval) : (plan_decision += 1) {
                    const decision_lived: u32 = replan_decision + plan_decision;
                    if (!followed_at[planner_index][decision_lived]) {
                        break;
                    }
                    const lived: []const f32 = ringRecord(replay_records, characters_ring, planner_env, decision_lived);
                    const lookahead_index: u64 = lookahead_first_index + plan_decision;
                    const looked_ahead: []const f32 =
                        ringRecord(replay_records, candidate_ring, winner, lookahead_index);
                    candidates_recorded.winner_records_compared += 1;
                    if (!eql(u8, sliceAsBytes(lived), sliceAsBytes(looked_ahead))) {
                        candidates_recorded.winner_records_differing += 1;
                    }
                }
                const replan_record: []const f32 =
                    ringRecord(replay_records, characters_ring, planner_env, replan_decision);
                const first_candidate: usize = planning.firstCandidateOf(planner_index);
                for (first_candidate..first_candidate + candidates_per_planner) |candidate| {
                    if (candidate == winner) {
                        continue;
                    }
                    const loser_record: []const f32 =
                        ringRecord(replay_records, candidate_ring, candidate, lookahead_first_index);
                    if (eql(u8, sliceAsBytes(loser_record), sliceAsBytes(replan_record))) {
                        candidates_recorded.loser_records_matching += 1;
                    }
                }
            }
        }
        // THE FAVOURED: each lookahead's best quarter of each planner's four candidates - one, its winner.
        candidates_recorded.lookaheads_complete = recording.lookaheads_complete;
        for (winners, 0..) |replan_winners, replan_index| {
            const favoured: []const bool = recording.favouredOf(replan_index);
            for (favoured, 0..) |is_favoured, candidate| {
                const planner_index: usize = candidate / candidates_per_planner;
                const is_winner: bool = candidate == replan_winners[planner_index];
                if (is_favoured != is_winner) {
                    candidates_recorded.favoured_mistaken += 1;
                }
            }
        }
        // THE GATE's PAIRS, IN THE RING: at a replan's first decision a planner's candidates hold one state - its
        // copy's - and each its own action.
        const record_states: usize = trainer.kit.features;
        const record_actions: usize = trainer.kit.actions;
        for (0..replan_count) |replan_index| {
            const lookahead_first_index: u64 = replan_index * lookahead_records;
            for (0..planner_count) |planner_index| {
                const first_candidate: usize = planning.firstCandidateOf(planner_index);
                const end_candidate: usize = first_candidate + candidates_per_planner;
                const block_first: []const f32 =
                    ringRecord(replay_records, candidate_ring, first_candidate, lookahead_first_index);
                for (first_candidate..end_candidate) |candidate| {
                    const record: []const f32 =
                        ringRecord(replay_records, candidate_ring, candidate, lookahead_first_index);
                    if (candidate != first_candidate) {
                        const states: [2][]const f32 = .{ record[0..record_states], block_first[0..record_states] };
                        const same_state: bool = eql(u8, sliceAsBytes(states[0]), sliceAsBytes(states[1]));
                        candidates_recorded.pair_states_compared += 1;
                        candidates_recorded.pair_states_differing += @intFromBool(!same_state);
                    }
                    const action: []const f32 = record[record_states..][0..record_actions];
                    for (candidate + 1..end_candidate) |other| {
                        const other_record: []const f32 =
                            ringRecord(replay_records, candidate_ring, other, lookahead_first_index);
                        const other_action: []const f32 = other_record[record_states..][0..record_actions];
                        const same_action: bool = eql(u8, sliceAsBytes(action), sliceAsBytes(other_action));
                        candidates_recorded.pair_actions_same += @intFromBool(same_action);
                    }
                }
            }
        }
    }
    // WHAT THE RUN LEFT: every world's numbers and integers, the trainer's ring, its books.
    const floats: []f32 = try gpa.alloc(f32, on_device.worldArenaEnd(.world_f));
    errdefer gpa.free(floats);
    try readWorldFloats(gpa, &on_device, 0, floats);
    const integers: []u32 = try gpa.alloc(u32, on_device.worldArenaEnd(.world_u));
    errdefer gpa.free(integers);
    try readWorldIntegers(gpa, &on_device, 0, integers);
    // The ring: `capacity` steps of every character's record block, step-major.
    const ring: []f32 = try gpa.dupe(f32, replay_records[characters_ring.at..][0..characters_ring.floats()]);
    errdefer gpa.free(ring);
    // The books, copied whole.
    const kept: z.robot_track.KeptBooks = trainer.device_acting.?.books;
    var books: z.robot_track.KeptBooks = try .init(gpa, kept.envs, kept.capacity);
    errdefer books.deinit(gpa);
    books.copyFrom(kept);
    // THE WORLD MODEL's BATCHES BY KIND, with planners, after everything above is read: an update at a candidates'
    // share of 1 trains on the candidates' lookaheads and leaves the critic alone; one at 0 trains on the characters'
    // records, and the critic with them.
    if (planners != null) {
        trainer.options.candidate_batch_share = 1.0;
        trainer.trainWorld(0);
        candidates_recorded.after_candidates_update = worldUpdateCountsOf(trainer);
        trainer.options.candidate_batch_share = 0.0;
        trainer.trainWorld(1);
        candidates_recorded.after_characters_update = worldUpdateCountsOf(trainer);
    }
    // THE LABELS KEPT, against the reckoning from each planner's own decisions; any other character's label kept is
    // one the reckoning does not keep.
    var labels_kept: LabelsKept = .{};
    const label_books: z.robot_track.LabelBooks = trainer.device_acting.?.books.labels;
    const kept_labels: []const z.robot_track.Label = label_books.keptLabels();
    labels_kept.found = @intCast(kept_labels.len);
    labels_kept.dropped_with_failed_plans = label_books.labels_dropped_with_failed_plans;
    labels_kept.dropped_after_losses = label_books.labels_dropped_after_losses;
    labels_kept.dropped_at_episode_ends = label_books.labels_dropped_at_episode_ends;
    var reckoned_kept: [planner_count][decision_count]bool = undefined;
    for (planner_worlds, 0..) |planner_world, planner_index| {
        const kept_by_reckoning: []bool = &reckoned_kept[planner_index];
        reckonKeptLabels(
            &followed_at[planner_index],
            &failed_at[planner_index],
            &episode_ended_at[planner_index],
            replan_interval,
            kept_by_reckoning,
        );
        const planner_env: u32 = planner_world - first_world;
        for (kept_by_reckoning, 0..) |reckoned, record_index| {
            const kept_by_books: bool = for (kept_labels) |label| {
                if (label.env == planner_env and label.index == record_index) {
                    break true;
                }
            } else false;
            labels_kept.expected += @intFromBool(reckoned);
            labels_kept.missing += @intFromBool(reckoned and !kept_by_books);
        }
    }
    for (kept_labels) |label| {
        const label_world: u32 = first_world + label.env;
        const planner_found: ?usize = indexOfScalar(u32, &planner_worlds, label_world);
        const reckoned: bool = if (planner_found) |planner_index|
            label.index < decision_count and reckoned_kept[planner_index][@intCast(label.index)]
        else
            false;
        labels_kept.unexpected += @intFromBool(!reckoned);
    }
    // ONE LABEL UPDATE ON THE DEVICE, in a recording of its own as a round's updates are: every window it stages a
    // kept label, the world model's weights not touched, the policy's moved. Without labels it is refused.
    const parameter_count: usize = trainer.params_end;
    const parameters_before: []f32 = try gpa.alloc(f32, parameter_count);
    defer gpa.free(parameters_before);
    const parameters_after: []f32 = try gpa.alloc(f32, parameter_count);
    defer gpa.free(parameters_after);
    try readTrainerParameters(device, queue, trainer, parameters_before);
    const label_slot: u32 = 0;
    trainer.kit.pipe.beginRecording();
    trainer.trainPolicyOnLabels(label_slot);
    trainer.kit.pipe.submitRecording();
    try readTrainerParameters(device, queue, trainer, parameters_after);
    labels_kept.label_updates = trainer.label_updates;
    labels_kept.label_batches_refused = trainer.label_batches_refused;
    if (trainer.label_updates > 0) {
        for (trainer.starts) |start| {
            const staged_is_kept: bool = for (kept_labels) |label| {
                if (label.env == start.env and label.index == start.index) {
                    break true;
                }
            } else false;
            labels_kept.staged_not_kept += @intFromBool(!staged_is_kept);
        }
    }
    const world_end: usize = trainer.kit.p_at;
    for (parameters_before[0..world_end], parameters_after[0..world_end]) |before, after| {
        const before_bits: u32 = @bitCast(before);
        const after_bits: u32 = @bitCast(after);
        labels_kept.world_numbers_changed += @intFromBool(before_bits != after_bits);
    }
    const policy_end: usize = world_end + trainer.kit.policy_count;
    const policy_before: []const f32 = parameters_before[world_end..policy_end];
    const policy_after: []const f32 = parameters_after[world_end..policy_end];
    labels_kept.policy_moved = !eql(u8, sliceAsBytes(policy_before), sliceAsBytes(policy_after));
    const gate_on_device: GateOnDevice = if (planners != null)
        try measureGateOnDevice(gpa, device, queue, trainer)
    else
        .{};
    return .{
        .decisions_following = decisions_following,
        .flow_corrected_others = flow_corrected_others,
        .flow_examples_kept = flow_examples_kept,
        .flow_examples_expected = @intCast(expected_example_count),
        .flow_examples_of_plans_not_teaching = examples_of_plans_not_teaching,
        .flow_example_numbers_differing = flow_example_numbers_differing,
        .flow_batch_rows = flow_batch_rows,
        .flow_batch_rows_unmatched = flow_batch_rows_unmatched,
        .flow_target_numbers_off = flow_target_numbers_off,
        .flow_target_moves_off = flow_target_moves_off,
        .flow_slots_misjudged = flow_slots_misjudged,
        .flow_slots_good = flow_slots_good,
        .flow_batch_slots_not_good = flow_batch_slots_not_good,
        .mode_slots_not_good = mode_slots_not_good,
        .acting_numbers_from_live = acting_numbers_from_live,
        .live_answers_everywhere = live_answers_everywhere,
        .label_update_counted = label_update_counted,
        .label_update_moved_flow = label_update_moved_flow,
        .distillation_weight_after_labels = distillation_weight_after_labels,
        .mode_rows_drawn = mode_rows_drawn,
        .mode_rows_unmatched = mode_rows_unmatched,
        .mode_update_counted = mode_update_counted,
        .mode_moved_policy = mode_moved_policy,
        .model_states = model_states,
        .model_states_on_planners = model_states_on_planners,
        .model_correction_numbers_differing = model_correction_numbers_differing,
        .model_state_numbers_differing = model_state_numbers_differing,
        .funnel_planners_seeded = funnel_planners_seeded,
        .actions_compared = actions_compared,
        .largest_gap_epsilons = largest_gap_epsilons,
        .plan_line_moved = plan_line_moved,
        .labelled_records = labelled_records,
        .label_mismatches = label_mismatches,
        .candidates_recorded = candidates_recorded,
        .labels_kept = labels_kept,
        .gate_on_device = gate_on_device,
        .phases = phases,
        .finish = .{
            .layout = on_device.layout,
            .first_character = first_world,
            .world_count = simulated_worlds,
            .planner_worlds = planner_worlds,
            .record_width = records.stride,
            .floats = floats,
            .integers = integers,
            .ring = ring,
            .books = books,
            .exposure = trainer.exposure,
            .failures = trainer.failures,
        },
    };
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
    // The goal: the features, then the root target's slots - the simulator's rows (`robotgpu.policy_inputs`).
    const goal_width: u32 = features + @as(u32, z.robot.root_target_size);
    const actions: u32 = sim.counts.action_count;
    const policy_hidden: u32 = 16;
    const kit: LatentKit = try .init(kit_pipe, features, 2, actions, 8, 4, 1, goal_width, policy_hidden);
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
    const width: u32 = goal_width + features;
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
    const quiet_clock: robotgpu.DecisionClock = .{ .number = 1, .push_top_share = 0, .exploration_spread = 0 };
    sim.actWithKit(zn_mlp, kit, acting, 0, quiet_clock);
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
            // The absolute difference, by the pair's rule at a unit of one: an action that is not finite on the
            // device is infinitely far from the CPU's, where a plain difference would be a NaN that `@max` drops.
            const device_action: f32 = read_back[row * action_stride + action];
            const difference: f32 = robotgpu_host.gapInUnits(device_action, expected, 1.0);
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
    // Each entry at its own scale: groups of one number.
    const one_number_a_scale: u32 = 1;
    var largest: f32 = 0;
    for (0..matrix_count) |matrix| {
        const start: usize = matrix * order * order;
        for (0..order) |row| {
            // A row of the lower triangle: its entries up to and including the diagonal's, side by side.
            const row_start: usize = start + row * order;
            const entries_in_row: usize = row + 1;
            const left_row: []const f32 = left[row_start..][0..entries_in_row];
            const reference_row: []const f32 = reference[row_start..][0..entries_in_row];
            const row_gap: f32 = robotgpu_host.largestGapEpsilons(left_row, reference_row, one_number_a_scale);
            largest = @max(largest, row_gap);
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

/// What the timings check measured (`runTimings`), each part on the probe's `busy_work`.
const TimingOutcome = struct {
    /// Two submissions, the first under one phase and the second - four times the work - under another: each
    /// phase's time, and its segments.
    one_times_microseconds: f64,
    four_times_microseconds: f64,
    one_times_segments: u32,
    four_times_segments: u32,
    /// One batch of two dispatches under the first phase and then one under the second, and one recording of the
    /// same: each phase's segments.
    batch_segments: [2]u32,
    recording_segments: [2]u32,
    /// The batch's two segments' times together against the batch's span on the device's clock: the same, the two
    /// segments sharing the mark between them.
    batch_sum_microseconds: f64,
    batch_span_microseconds: f64,
    /// THE HOST KEPT AWAY WHILE THE DEVICE HAS NOTHING TO DO, between two submissions: how long, the round's idle
    /// time by its line (`lab.RoundTimeLog.lineOf`), and the line's host time in the phase the host stayed away in.
    idle_away_ms: f64,
    idle_round_idle_ms: f64,
    idle_round_away_phase_host_ms: f64,
    /// THE HOST KEPT AWAY WHILE THE DEVICE WORKS on a dispatch twice as long as the stay - 20 ms of the device's
    /// time or more, whatever the device: how long, and the round's idle time by its line.
    busy_away_ms: f64,
    busy_round_idle_ms: f64,
    /// A PIPE OF FIVE MARKS. Three submissions of a dispatch each: the segments timed and the dispatches left
    /// untimed. After that read, one batch of five dispatches with the phase changing at each: its segments and its
    /// untimed dispatches. After that read, one more submission: its segments.
    short_segments: u32,
    short_untimed: u32,
    short_batch_segments: u32,
    short_batch_untimed: u32,
    short_segments_after_reads: u32,
    /// A pipe timing every dispatch, three dispatches in one batch: the kernel's timed dispatches, the batch's
    /// segments, and the kernel's time against its phase's.
    kernel_dispatches: u64,
    per_dispatch_segments: u32,
    kernel_microseconds: f64,
    per_dispatch_phase_microseconds: f64,
    untimed_reports_none: bool,
};

/// The host kept away from the device for `milliseconds`: its thread spinning on the clock, submitting and reading
/// nothing.
fn stayAwayFor(milliseconds: f64) void {
    const began_ms: f64 = wgpu.nowMs();
    while (wgpu.nowMs() - began_ms < milliseconds) {
        std.atomic.spinLoopHint();
    }
}

/// TIMINGS' CHECK: the probe's `busy_work`, timed on the GPU by phase (`Compute.enableTimings`) - a segment of
/// dispatches between two marks on the device's clock - in seven parts:
///
///     two submissions        one under a phase, four times the work under another: the second phase's time is the
///                            longer, a segment each
///     a batch, a recording   two dispatches under one phase, then one under another: a segment each, and in the
///                            batch the two times together are its span - the mark between them is shared
///     away, device idle      two submissions with the host kept away between them, in a phase of its own: the
///                            round's line gives that stay as idle time and as that phase's host time
///     away, device busy      the host kept away while the device works on a dispatch twice as long as the stay:
///                            next to no idle time
///     five marks             three submissions: two timed, the third - one mark left, not a segment's two -
///                            counted untimed; a batch of five phases: four segments on the five marks, the fifth
///                            dispatch untimed; and the marks start over after each read
///     every dispatch         three dispatches in a batch: three segments, the kernel's three, its time the phase's
///     no timings             a pipe on the CPU reports nothing
///
/// The round's line is the lab's (`RoundTimeLog.lineOf`), with a host clock told the phases as a trainer's is.
fn runTimings(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !TimingOutcome {
    const ProbeCompute: type = z.Compute(robotgpu_probe);
    const RoundPhase: type = z.robot.RoundPhase;
    const entries: [robotgpu_probe.kernels.len]ProbeCompute.KernelWgsl =
        spirvEntries(robotgpu_probe, robotgpu_probe_spirv);
    var on_device: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer on_device.deinit();
    try expect(try on_device.enableTimings(.{}));
    // A quarter of the table: each dispatch is tens of milliseconds on a CPU driver, and the check a few seconds.
    const value_count: u32 = robotgpu_probe.table_capacity / 4;
    const starting_values: []f32 = try gpa.alloc(f32, robotgpu_probe.table_capacity);
    defer gpa.free(starting_values);
    @memset(starting_values, 1.0);
    on_device.upload(.values, starting_values);
    on_device.params = .{ .value_count = value_count, .subgroup_size = 1 };
    const base_rounds: u32 = 2000;
    const once: robotgpu_probe.PushConstants = .{ .region_start = 0, .value = 0, .iterations = base_rounds };
    const four_times: robotgpu_probe.PushConstants = .{ .region_start = 0, .value = 0, .iterations = 4 * base_rounds };
    // The phases, a round's own: a light one, a heavy one, and one the host only stays away in.
    const light: RoundPhase = .acting;
    const heavy: RoundPhase = .physics;
    const away: RoundPhase = .books;

    // The kernel's first dispatch pays for the driver's own preparation of it (a CPU driver compiles the kernel
    // then): run once and read away before anything is measured.
    on_device.runPushed("busy_work", value_count, once);
    _ = PhaseTimes.ofPipe(robotgpu_probe, &on_device);

    // 1  Two submissions under two phases.
    on_device.setPhase(@backingInt(light));
    on_device.runPushed("busy_work", value_count, once);
    on_device.setPhase(@backingInt(heavy));
    on_device.runPushed("busy_work", value_count, four_times);
    const two_submissions: PhaseTimes = .ofPipe(robotgpu_probe, &on_device);
    const one_times_ms: f64 = two_submissions.microsecondsOf(light) / 1000.0;

    // 2  One batch, the phase changing inside it.
    on_device.beginBatch(on_device.params);
    on_device.setPhase(@backingInt(light));
    on_device.runPushed("busy_work", value_count, once);
    on_device.runPushed("busy_work", value_count, once);
    on_device.setPhase(@backingInt(heavy));
    on_device.runPushed("busy_work", value_count, once);
    on_device.endBatch();
    const batch: PhaseTimes = .ofPipe(robotgpu_probe, &on_device);
    // And one recording of the same.
    on_device.beginRecording();
    on_device.setPhase(@backingInt(light));
    on_device.runPushed("busy_work", value_count, once);
    on_device.runPushed("busy_work", value_count, once);
    on_device.setPhase(@backingInt(heavy));
    on_device.runPushed("busy_work", value_count, once);
    on_device.submitRecording();
    const recording: PhaseTimes = .ofPipe(robotgpu_probe, &on_device);

    // 3  The host away while the device has nothing to do, between two dispatches - the first waited for: eight
    //    times a dispatch's time, so the stay is long beside the host's two waits for the dispatches.
    const idle_away_ms: f64 = @max(8 * one_times_ms, 40);
    var one_sum: [1]f32 = undefined;
    var idle_clock: z.robot.PhaseClock = .{};
    idle_clock.begin(wgpu.nowMs());
    idle_clock.enter(wgpu.nowMs(), light);
    on_device.setPhase(@backingInt(light));
    on_device.runPushed("busy_work", value_count, once);
    const first_wait_began_ms: f64 = wgpu.nowMs();
    on_device.readRange(.sums, 0, &one_sum);
    idle_clock.addWait(wgpu.nowMs() - first_wait_began_ms);
    idle_clock.enter(wgpu.nowMs(), away);
    stayAwayFor(idle_away_ms);
    idle_clock.enter(wgpu.nowMs(), light);
    on_device.runPushed("busy_work", value_count, once);
    idle_clock.enter(wgpu.nowMs(), .other);
    const idle_read_began_ms: f64 = wgpu.nowMs();
    const idle_times: PhaseTimes = .ofPipe(robotgpu_probe, &on_device);
    idle_clock.addWait(wgpu.nowMs() - idle_read_began_ms);
    idle_clock.end(wgpu.nowMs());
    const idle_line: z.robot_lab.RoundTimeLog.Line = idle_times.lineWith(idle_clock);

    // 4  The host away while the device works. The dispatch is first made long beside what a submission and a
    //    read cost on any device: its rounds doubled, from the base, until it takes 20 ms or more of the device's
    //    time - once on a CPU driver, a dozen times and more on a fast GPU, each run and read on its own. Then that
    //    dispatch once more, the host away for half its time.
    const long_enough_microseconds: f64 = 20_000;
    const most_doublings: u32 = 20;
    var busy_push: robotgpu_probe.PushConstants = once;
    var busy_microseconds: f64 = two_submissions.microsecondsOf(light);
    var doublings: u32 = 0;
    while (busy_microseconds < long_enough_microseconds and doublings < most_doublings) : (doublings += 1) {
        busy_push.iterations *= 2;
        on_device.setPhase(@backingInt(heavy));
        on_device.runPushed("busy_work", value_count, busy_push);
        const lengthened: PhaseTimes = .ofPipe(robotgpu_probe, &on_device);
        busy_microseconds = lengthened.microsecondsOf(heavy);
    }
    const busy_away_ms: f64 = busy_microseconds / 1000.0 / 2;
    var busy_clock: z.robot.PhaseClock = .{};
    busy_clock.begin(wgpu.nowMs());
    busy_clock.enter(wgpu.nowMs(), heavy);
    on_device.setPhase(@backingInt(heavy));
    on_device.runPushed("busy_work", value_count, busy_push);
    stayAwayFor(busy_away_ms);
    busy_clock.enter(wgpu.nowMs(), .other);
    const busy_read_began_ms: f64 = wgpu.nowMs();
    const busy_times: PhaseTimes = .ofPipe(robotgpu_probe, &on_device);
    busy_clock.addWait(wgpu.nowMs() - busy_read_began_ms);
    busy_clock.end(wgpu.nowMs());
    const busy_line: z.robot_lab.RoundTimeLog.Line = busy_times.lineWith(busy_clock);

    // 5  Five marks. Three submissions of a dispatch each: the third finds one mark left, and a segment needs its
    //    start and the mark kept back for its end.
    var short_pipe: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer short_pipe.deinit();
    try expect(try short_pipe.enableTimings(.{ .mark_capacity = 5 }));
    short_pipe.upload(.values, starting_values);
    short_pipe.params = on_device.params;
    const short_phases = [_]RoundPhase{ light, heavy, away };
    for (short_phases) |phase| {
        short_pipe.setPhase(@backingInt(phase));
        short_pipe.runPushed("busy_work", value_count, once);
    }
    const short_times: PhaseTimes = .ofPipe(robotgpu_probe, &short_pipe);
    //    One batch of five dispatches, the phase changing at each: the five marks bound four segments, and the
    //    fifth dispatch begins none - no mark is left to end it.
    const short_batch_phases = [_]RoundPhase{ light, heavy, away, light, heavy };
    short_pipe.beginBatch(short_pipe.params);
    for (short_batch_phases) |phase| {
        short_pipe.setPhase(@backingInt(phase));
        short_pipe.runPushed("busy_work", value_count, once);
    }
    short_pipe.endBatch();
    const short_batch_times: PhaseTimes = .ofPipe(robotgpu_probe, &short_pipe);
    short_pipe.runPushed("busy_work", value_count, once);
    const short_times_after: PhaseTimes = .ofPipe(robotgpu_probe, &short_pipe);

    // 6  Every dispatch a segment: the kernel's own sums.
    var per_dispatch_pipe: ProbeCompute = try .initGpu(gpa, device, queue, &entries);
    defer per_dispatch_pipe.deinit();
    try expect(try per_dispatch_pipe.enableTimings(.{ .per_dispatch = true }));
    per_dispatch_pipe.upload(.values, starting_values);
    per_dispatch_pipe.params = on_device.params;
    per_dispatch_pipe.setPhase(@backingInt(light));
    per_dispatch_pipe.beginBatch(per_dispatch_pipe.params);
    for (0..3) |_| {
        per_dispatch_pipe.runPushed("busy_work", value_count, once);
    }
    per_dispatch_pipe.endBatch();
    const kernel_names: []const []const u8 = per_dispatch_pipe.kernelNames();
    const kernel_microseconds: []f64 = try gpa.alloc(f64, kernel_names.len);
    defer gpa.free(kernel_microseconds);
    const kernel_dispatches: []u64 = try gpa.alloc(u64, kernel_names.len);
    defer gpa.free(kernel_dispatches);
    @memset(kernel_microseconds, 0);
    @memset(kernel_dispatches, 0);
    var per_dispatch_microseconds: [RoundPhase.count]f64 = @splat(0);
    var per_dispatch_segments: [RoundPhase.count]u32 = @splat(0);
    _ = per_dispatch_pipe.readTimings(
        &per_dispatch_microseconds,
        &per_dispatch_segments,
        kernel_microseconds,
        kernel_dispatches,
    );
    const busy_index: usize = for (kernel_names, 0..) |kernel_name, index| {
        if (eql(u8, kernel_name, "busy_work")) {
            break index;
        }
    } else return error.NoBusyWorkKernel;

    // 7  A pipe on the CPU reports nothing.
    var twin: ProbeCompute = .initCpu();
    defer twin.deinit();
    try expect(!try twin.enableTimings(.{}));
    const twin_times: PhaseTimes = .ofPipe(robotgpu_probe, &twin);
    var untimed_reports_none: bool = twin_times.segmentsTimed() == 0;
    for (twin_times.microseconds) |microseconds| {
        untimed_reports_none = untimed_reports_none and microseconds == 0;
    }

    const light_index: usize = @backingInt(light);
    const outcome: TimingOutcome = .{
        .one_times_microseconds = two_submissions.microsecondsOf(light),
        .four_times_microseconds = two_submissions.microsecondsOf(heavy),
        .one_times_segments = two_submissions.segmentsOf(light),
        .four_times_segments = two_submissions.segmentsOf(heavy),
        .batch_segments = .{ batch.segmentsOf(light), batch.segmentsOf(heavy) },
        .recording_segments = .{ recording.segmentsOf(light), recording.segmentsOf(heavy) },
        .batch_sum_microseconds = batch.microsecondsOf(light) + batch.microsecondsOf(heavy),
        .batch_span_microseconds = batch.span_microseconds,
        .idle_away_ms = idle_away_ms,
        .idle_round_idle_ms = idle_line.gpu_idle_share * idle_line.wall_ms,
        .idle_round_away_phase_host_ms = idle_line.phases[@backingInt(away)].host_ms,
        .busy_away_ms = busy_away_ms,
        .busy_round_idle_ms = busy_line.gpu_idle_share * busy_line.wall_ms,
        .short_segments = short_times.segmentsTimed(),
        .short_untimed = short_times.untimed_dispatches,
        .short_batch_segments = short_batch_times.segmentsTimed(),
        .short_batch_untimed = short_batch_times.untimed_dispatches,
        .short_segments_after_reads = short_times_after.segmentsTimed(),
        .kernel_dispatches = kernel_dispatches[busy_index],
        .per_dispatch_segments = per_dispatch_segments[light_index],
        .kernel_microseconds = kernel_microseconds[busy_index],
        .per_dispatch_phase_microseconds = per_dispatch_microseconds[light_index],
        .untimed_reports_none = untimed_reports_none,
    };
    if (test_options.long_checks) {
        print("vk-host-test: timings - once {d:.0} us and four times {d:.0} us; a batch's segments {d:.3} us of " ++
            "a span of {d:.3} us; away {d:.0} ms with the device idle: {d:.1} ms idle, {d:.1} ms of host time in " ++
            "the phase; away {d:.0} ms with the device busy: {d:.1} ms idle\n", .{
            outcome.one_times_microseconds,
            outcome.four_times_microseconds,
            outcome.batch_sum_microseconds,
            outcome.batch_span_microseconds,
            outcome.idle_away_ms,
            outcome.idle_round_idle_ms,
            outcome.idle_round_away_phase_host_ms,
            outcome.busy_away_ms,
            outcome.busy_round_idle_ms,
        });
    }
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

/// A kernel check's report said (`latent_kit.KernelCheckReport`): each sequence's largest gap from the twin, and for
/// one past the bar its worst field's worst value.
fn printKernelCheck(report: *const latent_kit.KernelCheckReport, options: latent_kit.KernelCheckOptions) void {
    for (report.measured()) |sequence| {
        if (sequence.worst) |worst| {
            print("vk-host-test: the kit's {s}: {s} - {d} values past the bar, the worst at {d}: device {e:.6}, " ++
                "twin {e:.6}\n", .{
                sequence.name,
                worst.field,
                worst.values_past_bar,
                worst.index,
                worst.device_value,
                worst.twin_value,
            });
        }
        print("vk-host-test: the kit's {s}: largest gap {e:.2} from the twin (bar {e:.0})\n", .{
            sequence.name,
            sequence.largest_gap,
            options.gap_limit,
        });
    }
    if (!report.complete) {
        print("vk-host-test: the kit's check: a readback never came\n", .{});
    }
}

/// The kit's learning kernels on the device and on its CPU twin (`latent_kit.checkKitKernels`), from the same data, in
/// the same order, every value each sequence leaves compared; each sequence's largest gap said. Returns the largest
/// gap seen, or null when a readback never came.
fn runKitKernels(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !?f32 {
    var on_device: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer on_device.deinit();
    var twin: z.Compute(zn_mlp) = .initCpu();
    defer twin.deinit();
    const options: latent_kit.KernelCheckOptions = .{};
    var report: latent_kit.KernelCheckReport = .{};
    try latent_kit.checkKitKernels(zn_mlp, zn_mlp, gpa, &on_device, &twin, options, &report);
    printKernelCheck(&report, options);
    if (!report.complete) {
        return null;
    }
    return report.largestGap();
}

/// The blocked products on the device and on its CPU twin (`latent_kit.checkBlockedProducts`), compared as the kit
/// check compares its own. The largest gap, or null when a readback never came.
fn runBlockedProducts(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !?f32 {
    var on_device: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer on_device.deinit();
    var twin: z.Compute(zn_mlp) = .initCpu();
    defer twin.deinit();
    const options: latent_kit.KernelCheckOptions = .{};
    var report: latent_kit.KernelCheckReport = .{};
    try latent_kit.checkBlockedProducts(zn_mlp, zn_mlp, gpa, &on_device, &twin, options, &report);
    printKernelCheck(&report, options);
    if (!report.complete) {
        return null;
    }
    return report.largestGap();
}

/// ZIMRNUM_FIT's NETWORK (`examples/zimrnum_fit`) on the kit's buffers: a dense network over the page's grid of 512
/// samples, as its panel makes it by default - three hidden layers of 64, tanh, Adam - and as SGD with momentum over
/// relu, each at the page's rate.
const FitNetwork = kit_mlp.KitMlp(zn_mlp);
const FitCase = struct {
    activation: kit_mlp.DenseActivation,
    optimizer: kit_mlp.MlpOptimizer,
    rate: f32,
};
const fit_cases = [_]FitCase{
    .{ .activation = .tanh, .optimizer = .adam, .rate = 5.0e-3 },
    .{ .activation = .relu, .optimizer = .{ .sgd = .{ .momentum = 0.9 } }, .rate = 1.0e-2 },
};
const fit_hidden_widths = [_]u32{ 64, 64, 64 };
const fit_rows: u32 = 512;
/// The steps on each side of a hand-over: enough for Adam's corrections and SGD's velocity to have moved.
const fit_steps: u32 = 4;
const fit_seed: u64 = 1;

/// A case's network as the kit's `Spec`, from `seed`.
fn fitSpec(fit_case: FitCase, seed: u64) kit_mlp.Spec {
    const spec: kit_mlp.Spec = .{
        .inputs = 1,
        .hidden = &fit_hidden_widths,
        .outputs = 1,
        .act = fit_case.activation,
        .rows = fit_rows,
        .optimizer = fit_case.optimizer,
        .rate = fit_case.rate,
        .seed = seed,
    };
    return spec;
}

/// The numbers a run of the page's network ends with: its training state - the weights and both moments - then the
/// curve, then the loss.
fn fitNumberCount(parameter_count: usize) usize {
    return 3 * parameter_count + fit_rows + 1;
}

/// A network's numbers into `out`, as every step submitted so far left them - each readback waited for, as a native
/// host may (`RangeRequest.wait`) - and its step count.
fn readFitNumbers(gpa: Allocator, network: *FitNetwork, out: []f32) !u32 {
    const parameter_count: usize = network.param_count;
    var state: kit_mlp.TrainingState = .{
        .weights = out[0..parameter_count],
        .first_moments = out[parameter_count..][0..parameter_count],
        .second_moments = out[2 * parameter_count ..][0..parameter_count],
        .step_count = 0,
    };
    var state_request: FitNetwork.StateRequest = try network.requestState(gpa);
    while (!state_request.collect(&state)) {
        std.atomic.spinLoopHint();
    }
    var curve_request: z.Compute(zn_mlp).RangeRequest(.acts) = try network.requestOutputs(gpa);
    curve_request.wait(out[3 * parameter_count ..][0..fit_rows]);
    var loss_request: z.Compute(zn_mlp).RangeRequest(.loss) = try network.pipe.requestRange(gpa, .loss, 0, 1);
    loss_request.wait(out[3 * parameter_count + fit_rows ..][0..1]);
    return state.step_count;
}

/// `2 x fit_steps` of a case's network on `pipe`, uninterrupted: what a hand-over must reproduce. Its numbers, owned by
/// the caller.
fn fitStepsStraight(
    gpa: Allocator,
    pipe: *z.Compute(zn_mlp),
    fit_case: FitCase,
    inputs: []const f32,
    targets: []const f32,
) ![]f32 {
    const network: *FitNetwork = try FitNetwork.init(gpa, pipe, fitSpec(fit_case, fit_seed));
    defer network.deinit();
    network.setBatch(inputs, targets);
    network.trainSteps(2 * fit_steps);
    const numbers: []f32 = try gpa.alloc(f32, fitNumberCount(network.param_count));
    errdefer gpa.free(numbers);
    _ = try readFitNumbers(gpa, network, numbers);
    return numbers;
}

/// THE PAGE's HAND-OVER: `fit_steps` of a case's network on `first`, its state put on a network on `second` - made from
/// another seed, so that nothing but the state carries the training across - and `fit_steps` more there. Its numbers,
/// owned by the caller.
fn fitStepsHandedOver(
    gpa: Allocator,
    first: *z.Compute(zn_mlp),
    second: *z.Compute(zn_mlp),
    fit_case: FitCase,
    inputs: []const f32,
    targets: []const f32,
) ![]f32 {
    const first_network: *FitNetwork = try FitNetwork.init(gpa, first, fitSpec(fit_case, fit_seed));
    defer first_network.deinit();
    first_network.setBatch(inputs, targets);
    first_network.trainSteps(fit_steps);
    const parameter_count: usize = first_network.param_count;
    const handed: []f32 = try gpa.alloc(f32, fitNumberCount(parameter_count));
    defer gpa.free(handed);
    const step_count: u32 = try readFitNumbers(gpa, first_network, handed);

    const second_network: *FitNetwork = try FitNetwork.init(gpa, second, fitSpec(fit_case, fit_seed + 1));
    defer second_network.deinit();
    second_network.putState(.{
        .weights = handed[0..parameter_count],
        .first_moments = handed[parameter_count..][0..parameter_count],
        .second_moments = handed[2 * parameter_count ..][0..parameter_count],
        .step_count = step_count,
    });
    second_network.setBatch(inputs, targets);
    second_network.trainSteps(fit_steps);
    const numbers: []f32 = try gpa.alloc(f32, fitNumberCount(parameter_count));
    errdefer gpa.free(numbers);
    _ = try readFitNumbers(gpa, second_network, numbers);
    return numbers;
}

/// ZIMRNUM_FIT's TOGGLE, BOTH WAYS: the page's network handed from the device to the twin and from the twin to the
/// device, each against the twin's own uninterrupted run - equal to rounding only if the device steps as the twin does
/// AND the state carries everything a step reads. Every number is compared: the weights, both moments, the curve and
/// the loss. Returns the largest relative gap (`latent_kit.largestRelativeGap`).
fn runFitHandOver(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !f32 {
    var on_device: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer on_device.deinit();
    var twin: z.Compute(zn_mlp) = .initCpu();
    defer twin.deinit();
    // The page's grid and its starting curve: two periods of a sine.
    var inputs: [fit_rows]f32 = undefined;
    var targets: [fit_rows]f32 = undefined;
    for (&inputs, &targets, 0..) |*input, *target, sample_index| {
        input.* = -1.0 + 2.0 * float(sample_index) / float(fit_rows - 1);
        target.* = 0.8 * sinTurns(input.*);
    }
    const options: latent_kit.KernelCheckOptions = .{};
    var largest_gap: f32 = 0;
    for (fit_cases) |fit_case| {
        const straight: []f32 = try fitStepsStraight(gpa, &twin, fit_case, &inputs, &targets);
        defer gpa.free(straight);
        const device_to_twin: []f32 = try fitStepsHandedOver(gpa, &on_device, &twin, fit_case, &inputs, &targets);
        defer gpa.free(device_to_twin);
        const twin_to_device: []f32 = try fitStepsHandedOver(gpa, &twin, &on_device, fit_case, &inputs, &targets);
        defer gpa.free(twin_to_device);
        const device_to_twin_gap: f32 = latent_kit.largestRelativeGap(device_to_twin, straight);
        const twin_to_device_gap: f32 = latent_kit.largestRelativeGap(twin_to_device, straight);
        print("vk-host-test: zimrnum_fit's hand-over, {s}: device to twin {e:.2}, twin to device {e:.2} from the " ++
            "twin's own run (bar {e:.0})\n", .{
            @tagName(fit_case.optimizer),
            device_to_twin_gap,
            twin_to_device_gap,
            options.gap_limit,
        });
        largest_gap = @max(largest_gap, @max(device_to_twin_gap, twin_to_device_gap));
    }
    return largest_gap;
}

/// The numbers not zero in every buffer of `pipe`, as far as a kernel check reaches (`latent_kit.kernelCheckReach`):
/// read by range requests, each copied after every write and dispatch so far.
fn countNumbersReached(gpa: Allocator, pipe: *z.Compute(zn_mlp)) !usize {
    const reach: u32 = latent_kit.kernelCheckReach(zn_mlp);
    const read_back: []f32 = try gpa.alloc(f32, reach);
    defer gpa.free(read_back);
    var numbers_not_zero: usize = 0;
    inline for (@typeInfo(zn_mlp.Buffers).@"struct".field_names) |field_name| {
        const field_length: usize = @typeInfo(@FieldType(zn_mlp.Buffers, field_name)).array.len;
        const read_count: u32 = @intCast(@min(field_length, reach));
        const field: FieldEnum(zn_mlp.Buffers) = @field(FieldEnum(zn_mlp.Buffers), field_name);
        var request: z.Compute(zn_mlp).RangeRequest(field) = try pipe.requestRange(gpa, field, 0, read_count);
        request.wait(read_back[0..read_count]);
        for (read_back[0..read_count]) |value| {
            numbers_not_zero += @intFromBool(value != 0);
        }
    }
    return numbers_not_zero;
}

/// A KERNEL CHECK LEAVES ITS PIPE AS IT WAS MADE (`latent_kit.clearKernelCheckData`) - what the trainer relies on when
/// it checks its learner's own pipe at a run's start: both checks run on a new pipe, which is then cleared, and every
/// buffer read back as far as the checks reach (`latent_kit.kernelCheckReach`) - by range requests, copied after the
/// clearing's writes - must hold zeros, the pipe's readback length and uniform as they were before. False when a
/// number is left, a setting changed, or the checks did not finish.
fn runKernelCheckClearing(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
) !bool {
    var on_device: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer on_device.deinit();
    var twin: z.Compute(zn_mlp) = .initCpu();
    defer twin.deinit();
    const count_before: u32 = on_device.element_count;
    const params_before: zn_mlp.Params = on_device.params;
    const options: latent_kit.KernelCheckOptions = .{};
    const report: latent_kit.KernelCheckReport =
        try latent_kit.checkKernelsAgainstTwin(zn_mlp, zn_mlp, gpa, &on_device, &twin, options);
    const settings_kept: bool = on_device.element_count == count_before and
        std.meta.eql(on_device.params, params_before);
    // What the checks left, then what the clearing leaves: the first many, the second none.
    const numbers_written: usize = try countNumbersReached(gpa, &on_device);
    try latent_kit.clearKernelCheckData(zn_mlp, gpa, &on_device);
    const numbers_left: usize = try countNumbersReached(gpa, &on_device);
    print("vk-host-test: the kernel check left {d} numbers in the pipe's buffers, the clearing {d}, its settings " ++
        "{s}\n", .{ numbers_written, numbers_left, if (settings_kept) "as they were" else "changed" });
    return report.complete and settings_kept and numbers_written > 0 and numbers_left == 0;
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

/// The sizes of `growStagingWithLargerWrites`' writes, in MiB: each larger than a staging chunk (4 MiB) and than
/// every write before it.
const growing_write_mebibytes = [_]usize{ 5, 6, 7, 8, 9, 10 };

/// WRITES EACH LARGER THAN EVERY ONE BEFORE, each submitted - what a run makes whose worlds grow from one test to
/// the next. A write larger than a standard chunk is staged in a chunk of its own size, and a chunk lives for the
/// host's life, so each of these leaves one behind: the staging then holds more chunks than its budget, which bounds
/// the chunks that wait for the GPU and not these. Returns whether the last and largest write arrived whole, read
/// back byte for byte.
fn growStagingWithLargerWrites(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) !bool {
    const largest_bytes: usize = growing_write_mebibytes[growing_write_mebibytes.len - 1] << 20;
    const payload: []u8 = try std.heap.page_allocator.alloc(u8, largest_bytes);
    defer std.heap.page_allocator.free(payload);
    const read_back: []u8 = try std.heap.page_allocator.alloc(u8, largest_bytes);
    defer std.heap.page_allocator.free(read_back);
    const buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
        .size = largest_bytes,
        .usage = .{ .storage = true, .copy_dst = true, .copy_src = true },
        .label = "growing write buffer",
    });
    defer wgpu.destroyBuffer(buffer);
    const chunks_before: usize = vulkan_host.statistics().staging_chunks;
    var last_value: u8 = 0;
    for (growing_write_mebibytes, 0..) |mebibytes, write| {
        // Each write its own byte, so the one read back is known to be the last.
        last_value = @intCast(write + 1);
        const write_bytes: usize = mebibytes << 20;
        @memset(payload[0..write_bytes], last_value);
        wgpu.queueWriteBuffer(queue, buffer, 0, payload[0..write_bytes]);
        const encoder: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
        wgpu.queueSubmit(queue, wgpu.finishCommandEncoder(encoder));
    }
    const chunks_after: usize = vulkan_host.statistics().staging_chunks;
    print("vk-host-test: after writes of {d} to {d} MiB - {d} staging chunks ({d} before, the budget {d})\n", .{
        growing_write_mebibytes[0],
        growing_write_mebibytes[growing_write_mebibytes.len - 1],
        chunks_after,
        chunks_before,
        vulkan_host.staging_chunk_budget,
    });
    if (!readBufferInto(device, queue, buffer, read_back)) {
        print("vk-host-test: the largest write was never read back\n", .{});
        return false;
    }
    for (read_back, 0..) |byte, at| {
        if (byte != last_value) {
            print("vk-host-test: the largest write's byte {d} is {d}, written {d}\n", .{ at, byte, last_value });
            return false;
        }
    }
    return true;
}

/// More rounds than two descriptor pool pages hold (512 sets each): if freed sets were never used again, the third
/// page would be created.
const churn_rounds: u32 = 1300;

/// Creates and destroys a bind group per round, with a buffer write and a submit between; returns whether the
/// host's descriptor pages stayed bounded and the rounds added no staging chunk past the budget. The staging is
/// measured against what this test finds: earlier writes may have left chunks of their own sizes (a write larger
/// than a standard chunk gets one, kept for the host's life), which are not these rounds' doing.
fn churnBindGroups(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) bool {
    const chunks_before: usize = vulkan_host.statistics().staging_chunks;
    const chunks_allowed: usize = @max(chunks_before, vulkan_host.staging_chunk_budget);
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
    print("vk-host-test: {d} rounds - {d} descriptor pages, {d} staging chunks ({d} before), {d} destroys waiting\n", .{
        churn_rounds,
        statistics.descriptor_pages,
        statistics.staging_chunks,
        chunks_before,
        statistics.waiting_destroys,
    });
    wgpu.destroyBindGroupLayout(layout);
    wgpu.destroyBuffer(buffer);
    // One page holds every live set; a second may appear while freed sets wait for the GPU. The staging budget bounds
    // the chunks however far ahead of the GPU the rounds run: the rounds make a chunk only while the staging holds
    // fewer than the budget.
    return statistics.descriptor_pages <= 2 and statistics.staging_chunks <= chunks_allowed;
}

/// Larger than a staging chunk (4 MiB), so each write needs a dedicated chunk.
const large_write_bytes: usize = 6 << 20;
const large_write_rounds: u32 = 24;

/// Writes `large_write_bytes` into a buffer and submits, round after round; returns whether the rounds added at most
/// one staging chunk past the budget - the one large chunk they use again every round, where the staging had none
/// large enough. Measured against the staging as this test finds it, as `churnBindGroups` is.
fn churnLargeWrites(device: wgpu.DeviceHandle, queue: wgpu.QueueHandle) !bool {
    const chunks_before: usize = vulkan_host.statistics().staging_chunks;
    const chunks_allowed: usize = @max(chunks_before, vulkan_host.staging_chunk_budget) + 1;
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
    print("vk-host-test: after {d} writes of {d} MiB - {d} staging chunks ({d} before)\n", .{
        large_write_rounds,
        large_write_bytes >> 20,
        statistics.staging_chunks,
        chunks_before,
    });
    wgpu.destroyBuffer(buffer);
    return statistics.staging_chunks <= chunks_allowed;
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
    inline for (tracking_bin_arrays, 0..) |tracked, index| {
        std.debug.print("vk-host-test: robotgpu tracking: {s} {d:.2} epsilons from the twin (bar {d:.0})\n", .{
            tracked.name,
            tracking.bin_gaps_epsilons[index],
            tracked.bar_epsilons,
        });
    }
    std.debug.print("vk-host-test: robotgpu tracking: {d} bin returns moved by the twin's rounds\n", .{
        tracking.bin_returns_moved,
    });
}

/// WHETHER THE GIVING CHECK HOLDS: both arrays within their bars, every finite choice moved by the twin's exploration,
/// no action left equal to its choice by the filter, and no action of the device's not finite. A miss is named, with
/// its numbers.
fn givingHolds(giving: GivingOutcome, bars: GivingBars) bool {
    var holds: bool = true;
    // Written so a gap that is not a number misses its bar too.
    const chosen_within_its_bar: bool = giving.chosen_gap_epsilons <= bars.chosen;
    if (!chosen_within_its_bar) {
        print("vk-host-test: giving: chosen_actions is {d:.1} epsilons from the twin's, its bar {d:.0}\n", .{
            giving.chosen_gap_epsilons,
            bars.chosen,
        });
        holds = false;
    }
    const actions_within_their_bar: bool = giving.actions_gap_epsilons <= bars.actions;
    if (!actions_within_their_bar) {
        print("vk-host-test: giving: actions is {d:.1} epsilons from the twin's, its bar {d:.0}\n", .{
            giving.actions_gap_epsilons,
            bars.actions,
        });
        holds = false;
    }
    if (giving.choices_explored != giving.finite_choices) {
        print("vk-host-test: giving: the twin's exploration moved {d} of {d} finite choices\n", .{
            giving.choices_explored,
            giving.finite_choices,
        });
        holds = false;
    }
    if (giving.actions_equal_to_choice != 0) {
        print("vk-host-test: giving: {d} of the twin's actions are their choice unchanged - no filter\n", .{
            giving.actions_equal_to_choice,
        });
        holds = false;
    }
    if (giving.device_actions_not_finite != 0) {
        print("vk-host-test: giving: {d} of the device's actions are not finite\n", .{
            giving.device_actions_not_finite,
        });
        holds = false;
    }
    return holds;
}

/// THE GIVING CHECK's GAPS, PRINTED: what a device measured, beside each bar - what the bars are refined from.
fn reportGivingGaps(giving: GivingOutcome, bars: GivingBars) void {
    print("vk-host-test: robotgpu giving: chosen_actions {d:.2} epsilons from the twin (bar {d:.0})\n", .{
        giving.chosen_gap_epsilons,
        bars.chosen,
    });
    print("vk-host-test: robotgpu giving: actions {d:.2} epsilons from the twin (bar {d:.0})\n", .{
        giving.actions_gap_epsilons,
        bars.actions,
    });
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
    inline for (tracking_bin_arrays, 0..) |tracked, index| {
        const gap_epsilons: f32 = tracking.bin_gaps_epsilons[index];
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
    // The bins compared were bins a round had folded an episode into.
    const a_bin_was_folded_into: bool = tracking.bin_returns_moved >= 1;
    if (!a_bin_was_folded_into) {
        std.debug.print("vk-host-test: tracking: no bin's return moved - the curriculum's round folded nothing\n", .{});
        holds = false;
    }
    const an_episode_began_again: bool = tracking.episodes_restarted >= 1;
    const an_aftermath_began: bool = tracking.aftermaths_begun >= 1;
    const a_character_returned: bool = tracking.returns >= 1;
    const worlds_were_pushed: bool = tracking.worlds_pushed >= 1;
    const a_watched_push_ended: bool = tracking.watched_pushes_ended >= 1;
    const events_happened: bool = an_episode_began_again and an_aftermath_began and a_character_returned and
        worlds_were_pushed and a_watched_push_ended;
    if (!events_happened) {
        std.debug.print("vk-host-test: tracking: {d} restarts, {d} aftermaths, {d} returns, {d} pushes, {d} " ++
            "watched pushes ended - each must happen at least once\n", .{
            tracking.episodes_restarted,
            tracking.aftermaths_begun,
            tracking.returns,
            tracking.worlds_pushed,
            tracking.watched_pushes_ended,
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
    const gap: f32 = kit_gap orelse return false;
    const options: latent_kit.KernelCheckOptions = .{};
    return gap <= options.gap_limit;
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

/// The timings, part by part (`runTimings`), each part that does not hold said:
///
///     the phases        each of two submissions a segment under its own phase, four times the work the longer
///     a submission      a batch's and a recording's two phases a segment each; the batch's two times together are
///                       its span, to a microsecond
///     the idle time     the host away with the device idle: nine tenths of the stay or more is idle time, and the
///                       stay is that phase's host time; away with the device busy: less than half the stay is
///     the marks         five marks time two of three submissions and count the third untimed; they bound four
///                       segments of a batch of five phases, its fifth dispatch untimed; then they start over
///     every dispatch    three dispatches are three segments and the kernel's three, its time the phase's exactly
///     no timings        a pipe on the CPU reports nothing
fn timingsHold(timing: TimingOutcome) bool {
    const measured: bool = timing.one_times_microseconds > 0;
    const longer: bool = timing.four_times_microseconds > timing.one_times_microseconds;
    const a_segment_each: bool = timing.one_times_segments == 1 and timing.four_times_segments == 1;
    const phases_hold: bool = measured and longer and a_segment_each;
    const batch_splits: bool = timing.batch_segments[0] == 1 and timing.batch_segments[1] == 1;
    const recording_splits: bool = timing.recording_segments[0] == 1 and timing.recording_segments[1] == 1;
    const batch_gap_microseconds: f64 = @abs(timing.batch_span_microseconds - timing.batch_sum_microseconds);
    const batch_adds_up: bool = timing.batch_sum_microseconds > 0 and batch_gap_microseconds <= 1.0;
    const submission_holds: bool = batch_splits and recording_splits and batch_adds_up;
    const idle_is_seen: bool = timing.idle_round_idle_ms >= 0.9 * timing.idle_away_ms;
    const away_is_host_time: bool = timing.idle_round_away_phase_host_ms >= timing.idle_away_ms;
    const busy_is_not_idle: bool = timing.busy_round_idle_ms <= 0.5 * timing.busy_away_ms;
    const idle_holds: bool = idle_is_seen and away_is_host_time and busy_is_not_idle;
    const submissions_run_out: bool = timing.short_segments == 2 and timing.short_untimed == 1;
    const batch_runs_out: bool = timing.short_batch_segments == 4 and timing.short_batch_untimed == 1;
    const marks_hold: bool = submissions_run_out and batch_runs_out and timing.short_segments_after_reads == 1;
    const kernel_counted: bool = timing.kernel_dispatches == 3 and timing.per_dispatch_segments == 3;
    const kernel_time_is_the_phases: bool = timing.kernel_microseconds > 0 and
        timing.kernel_microseconds == timing.per_dispatch_phase_microseconds;
    const per_dispatch_holds: bool = kernel_counted and kernel_time_is_the_phases;
    const parts = [_]bool{
        phases_hold,
        submission_holds,
        idle_holds,
        marks_hold,
        per_dispatch_holds,
        timing.untimed_reports_none,
    };
    const part_names = [_][]const u8{
        "the phases",
        "a submission",
        "the idle time",
        "the marks",
        "every dispatch",
        "no timings",
    };
    var holds: bool = true;
    for (parts, part_names) |part_holds, part_name| {
        if (!part_holds) {
            print("vk-host-test: timings: {s} - does not hold: {any}\n", .{ part_name, timing });
            holds = false;
        }
    }
    return holds;
}

test "a number that is not finite is never within a bar: its gap from a finite one is infinite" {
    // One quantity of four numbers sharing a scale - its largest magnitude, 52. The arrays are variables, read from
    // memory when the gap is measured, so the arithmetic checked is the running code's and not the compiler's.
    const quantity_scale: f32 = 52.0;
    var twin_numbers: [4]f32 = .{ quantity_scale, 0.0004, -0.0002, 12.0 };
    var device_numbers: [4]f32 = twin_numbers;
    const numbers_sharing_scale: u32 = 4;
    // f32's epsilon, 2^-23: the gap between 1 and the next float.
    const epsilon: f32 = 0x1p-23;
    const three_epsilons: f32 = 3.0;
    const rounding_of_the_sum: f32 = 1.0e-3;

    // TWO FINITE NUMBERS: the device's smallest number differs by three epsilons of the QUANTITY's size - three, where
    // against the number's own size it would be hundreds of thousands.
    device_numbers[1] += three_epsilons * epsilon * quantity_scale;
    const finite_gap: f32 = robotgpu_host.largestGapEpsilons(&device_numbers, &twin_numbers, numbers_sharing_scale);
    try testing.expectApproxEqAbs(three_epsilons, finite_gap, rounding_of_the_sum);

    // THE DEVICE's NUMBER A NaN, THE TWIN's FINITE: no rounding explains it - the gap is infinite, past every bar.
    device_numbers[2] = nan(f32);
    const device_nan_gap: f32 = robotgpu_host.largestGapEpsilons(&device_numbers, &twin_numbers, numbers_sharing_scale);
    try expectEqual(inf(f32), device_nan_gap);

    // A NaN ON BOTH SIDES: the same on both, so the pair agrees - and the three epsilons beside it are still measured.
    twin_numbers[2] = nan(f32);
    const both_nan_gap: f32 = robotgpu_host.largestGapEpsilons(&device_numbers, &twin_numbers, numbers_sharing_scale);
    try testing.expectApproxEqAbs(three_epsilons, both_nan_gap, rounding_of_the_sum);

    // THE TWIN's NUMBER A NaN, THE DEVICE's FINITE: infinite, as the other way round.
    device_numbers[2] = -0.0002;
    const twin_nan_gap: f32 = robotgpu_host.largestGapEpsilons(&device_numbers, &twin_numbers, numbers_sharing_scale);
    try expectEqual(inf(f32), twin_nan_gap);

    // THE SAME INFINITY ON BOTH SIDES: the pair agrees, and it sets no scale - against an infinite scale the three
    // epsilons beside it would measure nothing.
    twin_numbers[2] = inf(f32);
    device_numbers[2] = inf(f32);
    const same_infinity_gap: f32 =
        robotgpu_host.largestGapEpsilons(&device_numbers, &twin_numbers, numbers_sharing_scale);
    try testing.expectApproxEqAbs(three_epsilons, same_infinity_gap, rounding_of_the_sum);

    // OPPOSITE INFINITIES: not the same number - infinite.
    device_numbers[2] = -inf(f32);
    const opposite_infinities_gap: f32 =
        robotgpu_host.largestGapEpsilons(&device_numbers, &twin_numbers, numbers_sharing_scale);
    try expectEqual(inf(f32), opposite_infinities_gap);
}

test "the target acceleration's bar holds what its inputs' bars become through a row's damping and stiffness" {
    // A row's target acceleration is `-damping * velocity - stiffness * impedance * violation` (`constraint_rows`), so
    // a rounding in its velocity arrives multiplied by the damping, and one in its violation by the stiffness times
    // the impedance. With the default softness - what the constraint tests' humanoid has - those are about 105 and
    // 2,600: the bar of the target acceleration cannot be the bar of a quantity the mass matrix's solve made.
    const softness: z.robot.Softness = .{};
    const impedance: z.robot.Impedance = .{};
    const largest_impedance: f32 = impedance.max;
    const time_constant: f32 = softness.time_const_s;
    const damp_ratio: f32 = softness.damp_ratio;
    const damping: f32 = 2.0 / (largest_impedance * time_constant);
    const stiffness_denominator: f32 = largest_impedance * largest_impedance * time_constant * time_constant *
        damp_ratio * damp_ratio;
    const stiffness: f32 = 1.0 / stiffness_denominator;
    var violation_bar: f32 = 0;
    var velocity_bar: f32 = 0;
    var target_acceleration_bar: f32 = 0;
    for (robotgpu_host.constraint_array_bars) |array_bar| {
        if (eql(u8, array_bar.name, "constraint_violation")) {
            violation_bar = array_bar.bar_epsilons;
        } else if (eql(u8, array_bar.name, "constraint_velocity")) {
            velocity_bar = array_bar.bar_epsilons;
        } else if (eql(u8, array_bar.name, "constraint_target_acceleration")) {
            target_acceleration_bar = array_bar.bar_epsilons;
        }
    }
    try expect(violation_bar > 0 and velocity_bar > 0 and target_acceleration_bar > 0);
    // Every gap is in epsilons at a scale of one or more, so the inputs' bars pass through at most as they are.
    const through_the_damping: f32 = damping * velocity_bar;
    const through_the_stiffness: f32 = stiffness * largest_impedance * violation_bar;
    const what_the_inputs_allow: f32 = through_the_damping + through_the_stiffness;
    try expect(target_acceleration_bar >= what_the_inputs_allow);
    // And no looser than it need be: within the next step of the table's bars, which go by fours.
    try expect(target_acceleration_bar < 4.0 * what_the_inputs_allow);
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

test "the kit's blocked products over several blocks match their CPU twin" {
    const timer: TestTimer = .start("the kit's blocked products");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(kitMatches(try runBlockedProducts(testing.allocator, opened.device, opened.queue)));
}

test "the kit's check leaves its pipe as it was made: every number it wrote zero, its settings kept" {
    const timer: TestTimer = .start("the kit's check, cleared");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try runKernelCheckClearing(testing.allocator, opened.device, opened.queue));
}

test "zimrnum_fit's network handed between the device and the twin, both ways, goes on as the twin's own run" {
    const timer: TestTimer = .start("zimrnum_fit's hand-over");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(kitMatches(try runFitHandOver(testing.allocator, opened.device, opened.queue)));
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

test "robotgpu timings: segments by phase, a round's idle time the device's own, an untimed pipe reports none" {
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

test "robotgpu sites and stateful actuators: one step of the arm on the device is the twin's within the step's bars" {
    const timer: TestTimer = .start("robotgpu sites and stateful actuators");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const verdict: robotgpu_host.StepVerdict =
        try runRobotgpuSitesAndActivations(testing.allocator, opened.device, opened.queue, coverage);
    try expect(verdict.agrees());
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

test "robotgpu giving: the device explores and filters a policy's choices as the twin does, the non-finite ones too" {
    const timer: TestTimer = .start("robotgpu giving");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const giving: GivingOutcome = try runRobotgpuGiving(testing.allocator, opened.device, opened.queue, coverage);
    const bars: GivingBars = .{};
    // At full size the run is on a real GPU, whose gaps the bars are refined from: printed, pass or not.
    if (test_options.long_checks) {
        reportGivingGaps(giving, bars);
    }
    try expect(givingHolds(giving, bars));
    try opened.expectNoNewValidationErrors();
}

test "robotgpu policy inputs and records: the device's observation, inputs and record rows are the twin's" {
    const timer: TestTimer = .start("robotgpu policy inputs");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const bars: PolicyInputsBars = .{};
    const measured: PolicyInputsOutcome = try runRobotgpuPolicyInputs(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
        bars,
    );
    // At full size the run is on a real GPU, whose gaps the bars are refined from: printed, pass or not.
    if (test_options.long_checks) {
        reportGaps("policy inputs", &measured.gaps);
    }
    const gaps_hold: bool = gapsHold("policy inputs", &measured.gaps);
    const every_input_is_finite: bool = measured.device_inputs_not_finite == 0;
    if (!every_input_is_finite) {
        print("vk-host-test: policy inputs: {d} of the device's inputs are not finite\n", .{
            measured.device_inputs_not_finite,
        });
    }
    try expect(gaps_hold and every_input_is_finite);
    try opened.expectNoNewValidationErrors();
}

test "robotgpu acting as one call: the device's decision is the twin's own composition, from one state" {
    const timer: TestTimer = .start("robotgpu acting as one call");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const bars: ActingBars = .{};
    const gaps: [3]MeasuredGap = try runRobotgpuActing(testing.allocator, opened.device, opened.queue, coverage, bars);
    // At full size the run is on a real GPU, whose gaps the bars are refined from: printed, pass or not.
    if (test_options.long_checks) {
        reportGaps("acting as one call", &gaps);
    }
    try expect(gapsHold("acting as one call", &gaps));
    try opened.expectNoNewValidationErrors();
}

test "robotgpu records into the ring: the device acts, records and steps as the twin does, its ring and books alike" {
    const timer: TestTimer = .start("robotgpu records into the ring");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const bars: RingBars = .{};
    const measured: RingOutcome = try runRobotgpuRecordsIntoRing(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
        bars,
    );
    const gaps = [_]MeasuredGap{measured.gap};
    // At full size the run is on a real GPU, whose gaps the bars are refined from: printed, pass or not.
    if (test_options.long_checks) {
        reportGaps("records into the ring", &gaps);
    }
    const gap_holds: bool = gapsHold("records into the ring", &gaps);
    const every_record_arrived: bool = measured.records_in_the_device_ring == measured.records_expected;
    if (!every_record_arrived) {
        print("vk-host-test: records into the ring: {d} records in the device's ring, {d} expected\n", .{
            measured.records_in_the_device_ring,
            measured.records_expected,
        });
    }
    if (!measured.books_alike) {
        print("vk-host-test: records into the ring: the books kept from the device's flags are not the twin's\n", .{});
    }
    // The decisions started stretches - pushes and the knocked characters' ends - so the books were tested.
    const stretches_were_started: bool = measured.stretches_started > 0;
    if (!stretches_were_started) {
        print("vk-host-test: records into the ring: no stretch was started past each world's first\n", .{});
    }
    if (test_options.long_checks) {
        print("vk-host-test: robotgpu records into the ring: {d} stretches started; {d:.1} dispatches a decision\n", .{
            measured.stretches_started,
            measured.dispatches_per_decision,
        });
    }
    try expect(gap_holds and every_record_arrived and measured.books_alike and stretches_were_started);
    try opened.expectNoNewValidationErrors();
}

/// THE CHECKS ON A TRAINER DRIVEN ON THE DEVICE that hold in either pattern of calls: its books and its ring whole,
/// its actions finite, windows drawn, and the ring's newest step the characters' records.
fn expectTrainerDataWhole(found: TrainerOnDeviceOutcome) !void {
    const latest_expected: u64 = found.decisions - 1;
    const ring_whole: bool = found.ring_first == 0 and found.ring_latest == latest_expected;
    try expectEqual(@as(u32, 0), found.books_records_short);
    try expect(found.stretches_started > 0);
    try expect(ring_whole);
    try expectEqual(@as(u32, 0), found.actions_not_finite);
    try expect(found.windows_drawn);
    try expect(found.ring_holds_the_characters);
    try expect(found.candidates_untouched);
}

fn expectTrainerOnDevice(candidate_count: u32) !void {
    const timer: TestTimer = .start("robotgpu trainer on the device");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const found: TrainerOnDeviceOutcome = try runRobotgpuTrainerOnDevice(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
        candidate_count,
        .one_decision_each,
    );
    const host: robotgpu_host.DeviceEvents = found.host_events;
    if (test_options.long_checks) {
        print("vk-host-test: robotgpu trainer on the device: {d} decisions, {d} stretches started\n", .{
            found.decisions,
            found.stretches_started,
        });
        print("vk-host-test: robotgpu trainer on the device: {d} decisions at risk, {d} losses\n", .{
            found.exposure,
            found.failures,
        });
        print("vk-host-test: robotgpu trainer on the device: {d} pushes at {d:.3} m/s, {d} watched pushes ended, " ++
            "{d} come back from, {d} returns\n", .{
            host.pushes,
            host.push_speed_sum / float64(@max(host.pushes, 1)),
            host.watched_pushes_settled,
            host.watched_pushes_came_back,
            host.returns,
        });
    }
    try expectTrainerDataWhole(found);
    // THE HOST's COUNTS ARE THE FLAGS', counted by the check after each decision - and each was tested: a loss
    // among the decisions at risk, pushes given, watches ended. The trainer's fleet, whose top the brake holds, was
    // told every watch that ended. The pushes' speeds, which the host draws again, sum to the check's own, drawn
    // at the numbers the check gave the decisions; the host itself stops at a watched push whose draw is not the
    // device's (`robotgpu_host.countTrainerDecisions`).
    var counts: Expectations = .{ .of = "robotgpu trainer on the device, a decision a call" };
    counts.holds(found.exposure == found.expected_exposure, "{d} decisions at risk counted, the flags say {d}", .{
        found.exposure,
        found.expected_exposure,
    });
    counts.holds(found.failures == found.expected_failures, "{d} losses counted, the flags say {d}", .{
        found.failures,
        found.expected_failures,
    });
    counts.holds(found.failures > 0, "no loss among the decisions", .{});
    counts.holds(host.pushes == found.expected_pushes, "{d} pushes counted, the flags say {d}", .{
        host.pushes,
        found.expected_pushes,
    });
    counts.holds(host.pushes > 0, "no push among the decisions", .{});
    const settled_as_flagged: bool = host.watched_pushes_settled == found.expected_watched_settled;
    counts.holds(settled_as_flagged, "{d} watched pushes ended by the host's count, the flags say {d}", .{
        host.watched_pushes_settled,
        found.expected_watched_settled,
    });
    const came_back_as_flagged: bool = host.watched_pushes_came_back == found.expected_watched_came_back;
    counts.holds(came_back_as_flagged, "{d} watched pushes come back from by the host's count, the flags say {d}", .{
        host.watched_pushes_came_back,
        found.expected_watched_came_back,
    });
    counts.holds(host.watched_pushes_settled > 0, "no watched push ended among the decisions", .{});
    const fleet_told_settled: bool = found.fleet_watched_settled == found.expected_watched_settled;
    counts.holds(fleet_told_settled, "the fleet was told of {d} watched pushes ended, the flags say {d}", .{
        found.fleet_watched_settled,
        found.expected_watched_settled,
    });
    const fleet_told_came_back: bool = found.fleet_watched_came_back == found.expected_watched_came_back;
    counts.holds(fleet_told_came_back, "the fleet was told of {d} watched pushes come back from, the flags say {d}", .{
        found.fleet_watched_came_back,
        found.expected_watched_came_back,
    });
    const speeds_as_drawn: bool = host.push_speed_sum == found.expected_push_speed_sum;
    counts.holds(speeds_as_drawn, "the pushes' speeds sum to {d} by the host's draws, {d} by the check's", .{
        host.push_speed_sum,
        found.expected_push_speed_sum,
    });
    // THE SAME DECISIONS IN CALLS OF SEVERAL LENGTHS, on a simulator and a trainer made the same way: within a call
    // the host counts each decision at the next one's read - the path a round's acting takes. The device does the
    // same work in the same order, so every count is the other pattern's, and the speeds' sum to the bit. The
    // returns are not among them: no character of this check comes back to its reference, in either pattern.
    const in_long_calls: TrainerOnDeviceOutcome = try runRobotgpuTrainerOnDevice(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
        candidate_count,
        .of_several_lengths,
    );
    try expectTrainerDataWhole(in_long_calls);
    const long_host: robotgpu_host.DeviceEvents = in_long_calls.host_events;
    var alike: Expectations = .{ .of = "robotgpu trainer on the device, calls of several lengths" };
    alike.holds(in_long_calls.exposure == found.exposure, "{d} decisions at risk, {d} a decision a call", .{
        in_long_calls.exposure,
        found.exposure,
    });
    alike.holds(in_long_calls.failures == found.failures, "{d} losses, {d} a decision a call", .{
        in_long_calls.failures,
        found.failures,
    });
    alike.holds(long_host.pushes == host.pushes, "{d} pushes, {d} a decision a call", .{
        long_host.pushes,
        host.pushes,
    });
    alike.holds(long_host.push_speed_sum == host.push_speed_sum, "speeds summing to {d}, {d} a decision a call", .{
        long_host.push_speed_sum,
        host.push_speed_sum,
    });
    const settled_alike: bool = long_host.watched_pushes_settled == host.watched_pushes_settled;
    alike.holds(settled_alike, "{d} watched pushes ended, {d} a decision a call", .{
        long_host.watched_pushes_settled,
        host.watched_pushes_settled,
    });
    const came_back_alike: bool = long_host.watched_pushes_came_back == host.watched_pushes_came_back;
    alike.holds(came_back_alike, "{d} watched pushes come back from, {d} a decision a call", .{
        long_host.watched_pushes_came_back,
        host.watched_pushes_came_back,
    });
    const fleet_settled_alike: bool = in_long_calls.fleet_watched_settled == found.fleet_watched_settled;
    alike.holds(fleet_settled_alike, "the fleet told of {d} watched pushes ended, {d} a decision a call", .{
        in_long_calls.fleet_watched_settled,
        found.fleet_watched_settled,
    });
    const fleet_came_back_alike: bool = in_long_calls.fleet_watched_came_back == found.fleet_watched_came_back;
    alike.holds(fleet_came_back_alike, "the fleet told of {d} come back from, {d} a decision a call", .{
        in_long_calls.fleet_watched_came_back,
        found.fleet_watched_came_back,
    });
    try counts.finish();
    try alike.finish();
    try opened.expectNoNewValidationErrors();
}

test "robotgpu trainer on the device: its policy acts, its ring and books fill, its windows can be drawn" {
    try expectTrainerOnDevice(0);
}

test "robotgpu trainer on the device after candidates: its characters are the worlds after them, and only those" {
    try expectTrainerOnDevice(4);
}

/// THE TRAINER FED TWO WAYS (`runRobotgpuTrainerFedTwoWays`), its report and its checks - the root target on or off.
fn expectTrainerFedTwoWays(root_target: bool) !void {
    const label: []const u8 = if (root_target) "trainer fed two ways, root target" else "trainer fed two ways";
    const timer: TestTimer = .start(label);
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    // Several times what a software Vulkan measures (7.78): a GPU and a CPU round the same updates differently -
    // the forward passes' tanh, the gradients' sums, Adam's square root. A record in a wrong slot sets the two
    // trainers thousands of epsilons apart.
    const parameters_bar: f32 = 64;
    // The statistics' fold at init: a division and a square root a number on each pipe, Vulkan's division within 2.5
    // ulps and its root within 3 - a few epsilons at the statistics' scale, where a number in a wrong place is far
    // past any.
    const statistics_bar: f32 = 16;
    const found: TrainerFedTwoWaysOutcome = try runRobotgpuTrainerFedTwoWays(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
        parameters_bar,
        statistics_bar,
        root_target,
    );
    const gaps = [_]MeasuredGap{ found.statistics_at_start, found.parameters };
    if (test_options.long_checks) {
        reportGaps(label, &gaps);
        print("vk-host-test: robotgpu {s}: updates {d} and {d}, windows refused {d}\n", .{
            label,
            found.device_fed_updates,
            found.cpu_fed_updates,
            found.windows_refused,
        });
    }
    if (found.first_start_difference) |index| {
        print("vk-host-test: {s}: the trainers' weights differ before training, first at parameter {d}\n", .{
            label,
            index,
        });
    }
    try expect(found.started_alike);
    try expectEqual(@as(u64, 2), found.device_fed_updates);
    try expectEqual(@as(u64, 2), found.cpu_fed_updates);
    try expectEqual(@as(u64, 0), found.windows_refused);
    try expect(gapsHold(label, &gaps));
    try opened.expectNoNewValidationErrors();
}

test "robotgpu trainer fed two ways: one round from the device's data learns what it learns from the host's" {
    try expectTrainerFedTwoWays(false);
}

test "robotgpu trainer fed two ways, the root target on: the root imagined on the device as on the host" {
    try expectTrainerFedTwoWays(true);
}

test "robotgpu training smoke: on the device path, the world model learns - its loss below a control's" {
    const timer: TestTimer = .start("robotgpu training smoke");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const found: TrainingSmokeOutcome = try runRobotgpuTrainingSmoke(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
    );
    const trained_losses: []const f32 = found.world_model_losses[0..found.rounds_trained];
    if (test_options.long_checks) {
        print("vk-host-test: robotgpu training smoke: {d} rounds trained, world model's loss", .{found.rounds_trained});
        for (trained_losses) |world_model_loss| {
            print(" {d:.4}", .{world_model_loss});
        }
        print("\n", .{});
    }
    // Every round trained, every parameter stayed finite, and over the second half of the rounds the trainer's loss
    // is below the control's - the same windows, its world model learning and the control's not.
    try expectEqual(smoke_rounds, found.rounds_trained);
    try expectEqual(@as(u32, 0), found.parameters_not_finite);
    const second_half_first: usize = smoke_rounds / 2;
    var trainer_sum: f32 = 0;
    var control_sum: f32 = 0;
    for (found.world_model_losses[second_half_first..], found.control_losses[second_half_first..]) |loss, control| {
        trainer_sum += loss;
        control_sum += control;
    }
    if (test_options.long_checks) {
        print("vk-host-test: robotgpu training smoke: second half's loss {d:.4} against the control's {d:.4}\n", .{
            trainer_sum / float(smoke_rounds - second_half_first),
            control_sum / float(smoke_rounds - second_half_first),
        });
    }
    try expect(trainer_sum < control_sum);
    // THE ROUNDS' TIME BY PHASE: the kit's pipe timed the world model's updates and the policy's - a segment of each
    // a round or more - and nothing under any other phase; the host's clock counted time in both, and every round
    // left the phase at `other`.
    // THE DECISIONS' TIME BY PHASE, one call of 64: each decision's acting, physics, judgement and resets a segment
    // or more; and the books' time nearly all a wait for the device - each decision's read of the counters waits
    // for the decision before, and what the host does with them is quick. More than half, where a wait counted at
    // the call's last read alone would be a 64th.
    var acting_expected: Expectations = .{ .of = "the decisions' time by phase" };
    const acted_phases = [_]z.robot.RoundPhase{ .acting, .physics, .judgement, .resets };
    const least_acted = [_]u32{ smoke_decisions, smoke_decisions, smoke_decisions, smoke_decisions };
    found.acting_phases.expectDevicePhases(&acting_expected, &acted_phases, &least_acted);
    const books_wait_ms: f64 = found.acting_phases.waitMsOf(.books);
    const books_host_ms: f64 = found.acting_phases.hostMsOf(.books);
    const books_mostly_wait: bool = books_wait_ms > 0.5 * books_host_ms and books_wait_ms < books_host_ms;
    acting_expected.holds(books_mostly_wait, "the books' wait, {d:.1} ms, most of their {d:.1} ms", .{
        books_wait_ms,
        books_host_ms,
    });
    const acting_ending_elsewhere: u32 = found.acting_phases.calls_ending_elsewhere;
    acting_expected.holds(acting_ending_elsewhere == 0, "the call left the phase elsewhere than at `other`", .{});
    if (test_options.long_checks) {
        printPhases("robotgpu training smoke, its decisions", found.acting_phases);
        printPhases("robotgpu training smoke, its training", found.phases);
    }
    try expect(found.policy_updates >= smoke_rounds);
    var phases_expected: Expectations = .{ .of = "the training rounds' time by phase" };
    const trained_phases = [_]z.robot.RoundPhase{ .world_model, .policy };
    found.phases.expectDevicePhases(&phases_expected, &trained_phases, &.{ smoke_rounds, smoke_rounds });
    for (trained_phases) |phase| {
        const host_ms: f64 = found.phases.hostMsOf(phase);
        phases_expected.holds(host_ms > 0, "the host's time in {s}: {d:.3} ms", .{ @tagName(phase), host_ms });
    }
    const rounds_ending_elsewhere: u32 = found.phases.calls_ending_elsewhere;
    phases_expected.holds(rounds_ending_elsewhere == 0, "{d} rounds left the phase elsewhere than at `other`", .{
        rounds_ending_elsewhere,
    });
    // THE CALL's PUSHES: given, and watches among them - so the host's draws were held against the device's
    // (`robotgpu_host.countTrainerDecisions` stops the program at a draw that is not the push's).
    const acting_events: robotgpu_host.DeviceEvents = found.acting_events;
    var pushes_expected: Expectations = .{ .of = "the call's pushes" };
    pushes_expected.holds(acting_events.pushes > 0, "no push in the call's decisions", .{});
    pushes_expected.holds(acting_events.watched_pushes_settled > 0, "no watched push ended in the call", .{});
    try acting_expected.finish();
    try phases_expected.finish();
    try pushes_expected.finish();
    try opened.expectNoNewValidationErrors();
}

test "robotgpu copies: a world made a copy of another on the device holds its source's whole state, to the bit" {
    const timer: TestTimer = .start("robotgpu copies");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const differences: [2]u32 = try runRobotgpuCopy(testing.allocator, opened.device, opened.queue, coverage);
    // The copy is its source; another world is not.
    try expectEqual(@as(u32, 0), differences[0]);
    try expect(differences[1] > 0);
    try opened.expectNoNewValidationErrors();
}

test "robotgpu two clips: each clip's tables and curriculum as the fleet's, and every world restarts on its own" {
    const timer: TestTimer = .start("robotgpu two clips");
    defer timer.report();
    const found: TwoClipsOutcome = try runRobotgpuTwoClips(testing.allocator);
    // The tables: 120 and 90 frames, 4 and 3 bins of half a second at 60 Hz; each clip's rows the fleet's own.
    try expectEqual([2]u32{ 120, 90 }, found.clip_frames);
    try expectEqual([2]u32{ 4, 3 }, found.clip_bins);
    try expectEqual([2]u32{ 0, 0 }, found.feature_differences);
    // Each clip's running sums climb from its own first bin to 1.
    try expect(found.sums_never_fall);
    try testing.expectApproxEqAbs(@as(f32, 1), found.last_sums[0], 1.0e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), found.last_sums[1], 1.0e-6);
    // Every world restarted on its own clip, in one of its clip's bins, at the frame the fleet draws.
    try expectEqual(@as(u32, 0), found.worlds_on_another_clip);
    try expectEqual(@as(u32, 0), found.worlds_outside_their_bins);
    try expectEqual(@as(u32, 0), found.frames_unlike_the_fleet);
}

test "robotgpu candidates: a copy run ahead of its planner is judged and recorded, but never restarted or pushed" {
    const timer: TestTimer = .start("robotgpu candidates");
    defer timer.report();
    const found: CandidatesOutcome = try runRobotgpuCandidates(testing.allocator);
    // The source lost its reference and began again; the candidate lost it too - and was left as it was.
    try expect(found.source_restarts > 0);
    try expect(found.candidate_lost);
    try expect(!found.candidate_restarted);
    try expect(!found.candidate_pushed);
    try expect(found.other_worlds_pushed > 0);
    // Its record packed at the last decision, as every world's: the whole action it took (75 numbers).
    try expectEqual(@as(u32, 75), found.candidate_action_numbers_compared);
    try expectEqual(@as(u32, 0), found.candidate_action_numbers_not_recorded);
}

test "robotgpu lookahead: candidates run ahead while their planners hold, on the twin and on the device" {
    const timer: TestTimer = .start("robotgpu lookahead");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const on_the_twin: LookaheadOutcome = try runRobotgpuLookahead(testing.allocator, null, coverage);
    const on_the_device: LookaheadOutcome = try runRobotgpuLookahead(testing.allocator, opened, coverage);
    print("vk-host-test: robotgpu lookahead: planners' sentinels overwritten - twin {d}, device {d}\n", .{
        on_the_twin.planner_sentinels_overwritten,
        on_the_device.planner_sentinels_overwritten,
    });
    for ([_]LookaheadOutcome{ on_the_twin, on_the_device }) |found| {
        try expectEqual(@as(u32, 0), found.planner_floats_changed);
        try expectEqual(@as(u32, 0), found.planner_integers_changed);
        try expectEqual(@as(u32, 0), found.planner_sentinels_overwritten);
        try expect(found.candidates_moved);
        try expectEqual(@as(u32, 0), found.candidate_floats_differing);
        try expectEqual(@as(u32, 0), found.candidate_integers_differing);
    }
    try opened.expectNoNewValidationErrors();
}

test "a planner's best candidate is its block's highest score, the first on a tie, never one not a number" {
    try expectEqual(@as(usize, 1), robotgpu_host.bestInBlock(&.{ 1.0, 2.0, 0.5 }));
    // A tie keeps the first: the warm start, when nothing beats it.
    try expectEqual(@as(usize, 0), robotgpu_host.bestInBlock(&.{ 3.0, 3.0, 1.0 }));
    // A candidate whose physics failed is never the best, wherever it stands.
    const failed: f32 = nan(f32);
    try expectEqual(@as(usize, 2), robotgpu_host.bestInBlock(&.{ failed, -1.0, 4.0 }));
    try expectEqual(@as(usize, 0), robotgpu_host.bestInBlock(&.{ 2.0, failed, 1.0 }));
}

test "robotgpu candidate scores: rewards discounted, a loss's cost, on the twin and the device as the host computes" {
    const timer: TestTimer = .start("robotgpu candidate scores");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const on_the_twin: CandidateScoresOutcome = try runRobotgpuCandidateScores(testing.allocator, null, coverage);
    const on_the_device: CandidateScoresOutcome =
        try runRobotgpuCandidateScores(testing.allocator, opened, coverage);
    for ([_]CandidateScoresOutcome{ on_the_twin, on_the_device }) |found| {
        // A score is a sum of a few products: kept and computed agree to a few epsilons of its size.
        for (found.kept, found.computed) |kept, computed| {
            const unit: f32 = 0x1p-23 * @max(1.0, @abs(computed));
            try expect(robotgpu_host.gapInUnits(kept, computed, unit) <= 8);
        }
        try expect(found.candidates_lost >= 2);
        for (found.best_of_kept, found.best_of_computed) |kept_best, computed_best| {
            try expectEqual(computed_best, kept_best);
        }
    }
    try opened.expectNoNewValidationErrors();
}

test "robotgpu plan actions: a candidate's action at each lookahead decision is its knots' line, twin and device" {
    const timer: TestTimer = .start("robotgpu plan actions");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const on_the_twin: PlanActionsOutcome = try runRobotgpuPlanActions(testing.allocator, null, coverage);
    const on_the_device: PlanActionsOutcome = try runRobotgpuPlanActions(testing.allocator, opened, coverage);
    if (test_options.long_checks) {
        print("vk-host-test: robotgpu plan actions: twin {d:.2}, device {d:.2} epsilons of the line\n", .{
            on_the_twin.largest_gap_epsilons,
            on_the_device.largest_gap_epsilons,
        });
    }
    for ([_]PlanActionsOutcome{ on_the_twin, on_the_device }) |found| {
        // Every candidate, freedom and decision of the horizon and its end compared: 4 x 75 x 9.
        try expectEqual(@as(u32, 4 * 75 * 9), found.actions_compared);
        // A line's point is a multiply and an add: within an epsilon or two of the host's.
        try expect(found.largest_gap_epsilons <= 2);
    }
    try opened.expectNoNewValidationErrors();
}

test "the characters in most trouble: the largest, in increasing order, ties to the earlier, not-a-number last" {
    // The worked example: two chosen of five - the two at 0.9.
    var two: [2]u32 = undefined;
    robotgpu_host.mostInTrouble(&[_]f32{ 0.1, 0.9, 0.4, 0.9, 0.2 }, &two);
    try expectEqualSlices(u32, &[_]u32{ 1, 3 }, &two);
    // Three of equal troubles: the earliest three.
    var three: [3]u32 = undefined;
    robotgpu_host.mostInTrouble(&[_]f32{ 0.5, 0.5, 0.5, 0.5 }, &three);
    try expectEqualSlices(u32, &[_]u32{ 0, 1, 2 }, &three);
    // A world whose physics failed is chosen only when nothing else is left.
    const not_a_number: f32 = nan(f32);
    robotgpu_host.mostInTrouble(&[_]f32{ not_a_number, 0.2, 0.1 }, &two);
    try expectEqualSlices(u32, &[_]u32{ 1, 2 }, &two);
    robotgpu_host.mostInTrouble(&[_]f32{ not_a_number, 0.2, 0.1 }, &three);
    try expectEqualSlices(u32, &[_]u32{ 0, 1, 2 }, &three);
}

test "the top share's start: the lowest of the top share of sorted numbers, at least one of them" {
    // Ten at 0.4: the top four, from index 6; at 1, all of them, from 0; a share too small for one still keeps the
    // highest; one number is its own top.
    try expectEqual(@as(usize, 6), robotgpu_host.topShareStart(10, 0.4));
    try expectEqual(@as(usize, 0), robotgpu_host.topShareStart(10, 1.0));
    try expectEqual(@as(usize, 9), robotgpu_host.topShareStart(10, 0.01));
    try expectEqual(@as(usize, 0), robotgpu_host.topShareStart(1, 0.4));
}

test "a model plan as a physics plan's knots: each knot the correction of the model step covering it, a decision on" {
    // The worked example: model steps of 1, 1, 4, 4 decisions, one number an action, corrections 10, 11, 12, 13;
    // the replan one decision later, 3 knots over 8 decisions - at 0, 4, 8 - read the model at 1, 5, 9: 11, 12, 13.
    const model_plan = [_]f32{ 10, 11, 12, 13 };
    const spans = [_]u32{ 1, 1, 4, 4 };
    var knots: [3]f32 = undefined;
    robotgpu_host.modelPlanAsKnots(&model_plan, &spans, 1, 3, 8, &knots);
    try expectEqualSlices(f32, &[_]f32{ 11, 12, 13 }, &knots);
    // Past the model plan's end its last step holds: single steps of 1, 1, 1, 1 read at 1, 5, 9 - 11, 13, 13.
    const single_spans = [_]u32{ 1, 1, 1, 1 };
    robotgpu_host.modelPlanAsKnots(&model_plan, &single_spans, 1, 3, 8, &knots);
    try expectEqualSlices(f32, &[_]f32{ 11, 13, 13 }, &knots);
}

test "a warm start is the previous plan moved on: each knot at its time plus the shift, held past the end" {
    // K = 3 over H = 8: knots at decisions 0, 4 and 8. Two numbers an action.
    const previous = [_]f32{ 0, 10, 4, 14, 8, 18 };
    var shifted: [6]f32 = undefined;
    // Moved on 4: the new knots are the previous plan at 4, 8 and 12 - the last held at the previous end.
    robotgpu_host.shiftedPlan(&previous, 3, 2, 8, 4, &shifted);
    try expectEqualSlices(f32, &[_]f32{ 4, 14, 8, 18, 8, 18 }, &shifted);
    // Moved on 2: the new first knot halfway between the previous first two.
    robotgpu_host.shiftedPlan(&previous, 3, 2, 8, 2, &shifted);
    try expectEqualSlices(f32, &[_]f32{ 2, 12, 6, 16, 8, 18 }, &shifted);
}

test "a candidate drawn about the warm start: offsets within the reach, stiffnesses held, at the noise's scale" {
    // Three knots of an action of five numbers - four offsets, one limb's stiffness - and 63 candidates drawn.
    const knot_count: u32 = 3;
    const action_count: u32 = 5;
    const offset_count: u32 = 4;
    const drawn_count: usize = 63;
    const plan_numbers: usize = knot_count * action_count;
    const action_scale: f32 = 0.2;
    const drawing: robotgpu_host.PlanDrawing = .{};
    var warm_start: [plan_numbers]f32 = @splat(0);
    for (0..knot_count) |knot| {
        warm_start[knot * action_count + offset_count] = 0.7;
    }
    var plans: [drawn_count * plan_numbers]f32 = undefined;
    var stream: Random.DefaultPrng = .init(7);
    const random: Random = stream.random();
    for (0..drawn_count) |drawn| {
        const plan: []f32 = plans[drawn * plan_numbers ..][0..plan_numbers];
        robotgpu_host.drawPlanAbout(random, &warm_start, action_count, offset_count, action_scale, drawing, plan);
    }
    // Every offset within the reach, in action units; every stiffness the warm start's (no stiffness noise).
    const reach: f32 = drawing.offset_reach_radians / action_scale;
    var offsets_drawn: f32 = 0;
    var squares_sum: f32 = 0;
    for (plans, 0..) |number, at| {
        const is_offset: bool = at % action_count < offset_count;
        if (is_offset) {
            try expect(@abs(number) <= reach);
            offsets_drawn += 1;
            squares_sum += number * number;
        } else {
            try expectEqual(@as(f32, 0.7), number);
        }
    }
    // The noise is there, at about its scale: a normal of 1.5 units clamped at 3 keeps some 0.94 of its spread.
    const spread: f32 = @sqrt(squares_sum / offsets_drawn);
    const noise: f32 = drawing.offset_noise_radians / action_scale;
    try expect(spread > 0.8 * noise and spread < 1.05 * noise);
    // The same stream draws the same candidates.
    var again: [drawn_count * plan_numbers]f32 = undefined;
    var same_stream: Random.DefaultPrng = .init(7);
    const same_random: Random = same_stream.random();
    for (0..drawn_count) |drawn| {
        const plan: []f32 = again[drawn * plan_numbers ..][0..plan_numbers];
        robotgpu_host.drawPlanAbout(same_random, &warm_start, action_count, offset_count, action_scale, drawing, plan);
    }
    try expectEqualSlices(f32, &plans, &again);
}

test "robotgpu replan: candidates drawn about each warm start, scored ahead, the best kept - characters untouched" {
    const timer: TestTimer = .start("robotgpu replan");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const on_the_twin: ReplanOutcome = try runRobotgpuReplan(testing.allocator, null, coverage);
    const on_the_device: ReplanOutcome = try runRobotgpuReplan(testing.allocator, opened, coverage);
    for ([_]ReplanOutcome{ on_the_twin, on_the_device }) |found| {
        try expectEqual(@as(u32, 0), found.character_numbers_changed);
        try expect(found.warm_starts_kept);
        try expect(found.plans_are_the_best);
        try expect(found.scores_moved);
        try expect(found.some_best_not_the_warm_start);
    }
    try opened.expectNoNewValidationErrors();
}

/// THE LABELS' CHECK of the planners-in-the-loop scene: `expected_count` labels kept, every one as the planners' own
/// flags reckon it and no other, none dropped - the scene's planners neither fail, nor live on after a loss, nor end
/// their episodes - and one label update on them that moved the policy alone; or, with no label to draw, an update
/// refused that moved nothing.
fn expectLabelsKept(labels: LabelsKept, expected_count: u32) !void {
    try expectEqual(expected_count, labels.expected);
    try expectEqual(expected_count, labels.found);
    try expectEqual(@as(u32, 0), labels.missing);
    try expectEqual(@as(u32, 0), labels.unexpected);
    try expectEqual(@as(u64, 0), labels.dropped_with_failed_plans);
    try expectEqual(@as(u64, 0), labels.dropped_after_losses);
    try expectEqual(@as(u64, 0), labels.dropped_at_episode_ends);
    try expectEqual(@as(u32, 0), labels.staged_not_kept);
    try expectEqual(@as(u32, 0), labels.world_numbers_changed);
    const has_labels: bool = expected_count > 0;
    const updates_run: u64 = @intFromBool(has_labels);
    const updates_refused: u64 = @intFromBool(!has_labels);
    try expectEqual(updates_run, labels.label_updates);
    try expectEqual(updates_refused, labels.label_batches_refused);
    try expectEqual(has_labels, labels.policy_moved);
}

test "robotgpu planners following: a planner following its plan takes its actions, and lives its winner's lookahead" {
    const timer: TestTimer = .start("robotgpu planners following");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const found: PlannersInTheLoopOutcome = try runRobotgpuPlannersInTheLoop(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
        .planners_following_every_decision,
    );
    defer found.deinit(testing.allocator);
    if (test_options.long_checks) {
        print("vk-host-test: robotgpu planners following: {d} of 16 decisions, {d:.2} epsilons of the line\n", .{
            found.decisions_following,
            found.largest_gap_epsilons,
        });
    }
    // Two planners, eight decisions each, following at every one; each decision's whole action compared (75).
    try expectEqual(@as(u32, 2 * 8), found.decisions_following);
    // Every one of their records labelled in the trainer's books, and no other character's.
    try expectEqual(@as(u32, 2 * 8), found.labelled_records);
    try expectEqual(@as(u32, 0), found.label_mismatches);
    try expectEqual(@as(u32, 2 * 8 * 75), found.actions_compared);
    try expect(found.plan_line_moved);
    // A line's point is a multiply and an add: within an epsilon or two of the host's.
    try expect(found.largest_gap_epsilons <= 2);
    // THE WINNERS' LOOKAHEADS, LIVED: each planner, after each of the two replans, lived its winner's four decisions
    // before the next replan - each the winner's record to the bit; and no loser's first record was the planner's.
    const recorded: CandidatesRecorded = found.candidates_recorded;
    try expectEqual(@as(u32, 2 * 2 * 4), recorded.winner_records_compared);
    try expectEqual(@as(u32, 0), recorded.winner_records_differing);
    try expectEqual(@as(u32, 0), recorded.loser_records_matching);
    // The candidates' recording: both lookaheads complete, each one's favoured exactly its planners' winners - a
    // planner's best quarter of four candidates is one.
    try expectEqual(@as(u64, 2), recorded.lookaheads_complete);
    try expectEqual(@as(u32, 0), recorded.favoured_mistaken);
    // THE GATE's PAIRS, IN THE RING: at each of the two replans, each planner's other three candidates in its first
    // candidate's state to the bit, and no two of its four with one action.
    try expectEqual(@as(u32, 2 * 2 * 3), recorded.pair_states_compared);
    try expectEqual(@as(u32, 0), recorded.pair_states_differing);
    try expectEqual(@as(u32, 0), recorded.pair_actions_same);
    // The world model's batches by kind: at a candidates' share of 1 the candidates' lookaheads, the critic left
    // alone; at 0 the characters' records, the critic with them. No batch refused.
    const after_candidates: WorldUpdateCounts = .{ .world_updates = 1, .candidate_world_updates = 1 };
    try expectEqual(after_candidates, recorded.after_candidates_update);
    const after_characters: WorldUpdateCounts = .{
        .world_updates = 2,
        .candidate_world_updates = 1,
        .critic_updates = 1,
    };
    try expectEqual(after_characters, recorded.after_characters_update);
    // THE LABELS KEPT: each planner's first plan, followed four decisions and ended well by the second replan, whose
    // own plan still runs at the end - 2 x 4 labels; and a label update on them.
    try expectLabelsKept(found.labels_kept, 2 * 4);
    // THE GATE ON THE DEVICE: the trainer's four rows, two pairs.
    if (test_options.long_checks) {
        print("vk-host-test: the gate on the device - judged within its round: {}\n", .{
            found.gate_on_device.judged_within_round,
        });
    }
    try expectGateOnDevice(found.gate_on_device, 2);
    // THE DECISIONS' TIME BY PHASE: eight decisions, two replans among them.
    if (test_options.long_checks) {
        printPhases("robotgpu planners following", found.phases);
    }
    try expectLoopPhases(found.phases, 8, 2);
    try opened.expectNoNewValidationErrors();
}

/// What `runRobotgpuPlannersByTrouble` found, after each of its two replans.
const PlannersByTroubleOutcome = struct {
    /// Whether the planners were the characters the check ranks highest by trouble, from the loss fractions it read
    /// back just before the replan - a replan's own choice made from the same numbers.
    planners_as_ranked: [2]bool = @splat(false),
    /// The candidates' copy table: each planner's block its copies, every block after them none.
    copy_tables_as_chosen: [2]bool = @splat(false),
    /// The lookahead's record: the planners it ran, and favoured candidates in their blocks alone.
    planners_recorded: [2]u32 = @splat(0),
    favoured_past_the_planners: u32 = 0,
    /// After the second replan: the characters that follow a plan - the planners, none other.
    characters_following_not_planners: u32 = 0,
    planners_following: u32 = 0,
    /// The largest trouble read, and the number of characters with a loss fraction above zero: the measure is alive.
    largest_trouble: f32 = 0,
    characters_with_a_fraction: u32 = 0,
    /// At each replan, the plans that teach the flow (`Planning.judgePlans`), judged again by the check: the plans
    /// judged, those that teach, those judged otherwise than the check would; and the policy's candidates - each
    /// block's place 1 - that were not all zero.
    plans_judged: u32 = 0,
    plans_teaching: u32 = 0,
    plans_judged_otherwise: u32 = 0,
    policy_candidates_not_zero: u32 = 0,
    /// Teacher 2's examples kept, decision by decision: how many, and how many of a character whose plan did not teach
    /// when it was kept.
    flow_slots_kept: u32 = 0,
    flow_slots_of_plans_not_teaching: u32 = 0,
    /// The judgement on scores written by hand (a planning of the same simulator, its lookaheads never run): the
    /// planners whose teaching came out otherwise than worked by hand, three replans of two planners.
    hand_judgements_off: u32 = 0,
    /// The teacher's running totals after the three judgements: the plans judged, those that taught, and their
    /// advantages' sum (`Planning.judged_plans`, `teaching_plans`, `advantage_sum`).
    hand_judged_plans: u64 = 0,
    hand_teaching_plans: u64 = 0,
    hand_advantage_sum: f64 = 0,
    /// The first replan's scores judged again as whole actions, the servo's candidate the baseline: the judgements
    /// that differ from around the policy's.
    hand_whole_action_judgements_off: u32 = 0,
};

/// THE PLANNERS CHOSEN BY TROUBLE (`robot.PlanningOptions.trouble_planners`), on the device: the trainer-on-device
/// scene with four blocks of four candidates in front of eight characters, the trainer in its second phase, two
/// planners chosen at each replan among the characters. Before each of the two replans (decisions 4 and 8), the
/// characters' loss fractions are read back and ranked by the check itself (`robot.projectedHazard`,
/// `robotgpu_host.mostInTrouble`); the replan's planners must be its ranking's, their blocks the only copies, the
/// recorded lookahead theirs alone - and after the second, the planners the only characters that follow a plan.
fn runRobotgpuPlannersByTrouble(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    queue: wgpu.QueueHandle,
    coverage: *DeviceCoverage,
) !PlannersByTroubleOutcome {
    const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = spirvEntries(robotgpu, robotgpu_spirv);
    const blocks: u32 = 4;
    const candidates_per_planner: u32 = 4;
    const candidate_capacity: u32 = blocks * candidates_per_planner;
    const world_count: u32 = 8;
    const first_world: u32 = candidate_capacity;
    const simulated_worlds: u32 = candidate_capacity + world_count;
    const physics_steps: u32 = 2;
    const training_physics: z.robot.Options = z.robot_geno.physicsOptions();
    var geno: z.robot_mjcf.Imported = try z.robot_mjcf.importSource(gpa, z.robot_geno_model, training_physics);
    defer geno.deinit();
    const model: *z.robot.Model = &geno.model;
    var clip: z.robot_dance.Clip = try loadTrackingClip(gpa, model);
    defer clip.deinit();
    const fleet: *z.robot_track.Fleet = try initTrackingFleet(gpa, model, &clip, world_count, physics_steps);
    defer fleet.deinit();
    const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
    defer tables.deinit(gpa);
    var on_device: robotgpu_host.Sim = try .initGpuTracking(
        gpa,
        device,
        queue,
        &entries,
        model,
        simulated_worlds,
        tables.clips,
    );
    defer on_device.deinit();
    defer coverage.add(&on_device);
    fleet.options.pushes.every = 90;
    fleet.options.pushes.rate_per_second = 0;
    const settings: z.robot.TrackingSettings = fleet.trackingSettings(.{ .offsets = 0.25, .stiffness = 0.5 });
    try on_device.setTracking(gpa, settings);
    try on_device.uploadStartBins(gpa, fleet);
    // The scene's starts, among them knocked characters: some in trouble from the first decision.
    const starts: TrackingStarts = .forWorlds(simulated_worlds);
    const still: []f32 = try gpa.alloc(f32, model.dof_count);
    defer gpa.free(still);
    @memset(still, 0);
    try placeTrackingStarts(gpa, &on_device, starts, tables.poses, model.coordinate_count, still);
    // THE PLANNING: room for four planners, the first four characters until the first replan chooses.
    const first_planners = [_]u32{ first_world, first_world + 1, first_world + 2, first_world + 3 };
    const offset_count: u32 = @intCast(z.robot.actionSize(model));
    const replan_interval: u32 = 4;
    const trouble_planners: u32 = 2;
    const lookahead_decisions: f32 = 4;
    var planning: robotgpu_host.Planning = try .init(
        gpa,
        on_device.counts,
        on_device.layout,
        &first_planners,
        offset_count,
        fleet.options.action_scale,
        .{
            .candidates_per_planner = candidates_per_planner,
            .replan_interval = replan_interval,
            .plan_following_share = 1,
            .trouble_planners = trouble_planners,
            .trouble_lookahead_decisions = lookahead_decisions,
            // The plans teach in the top half of a window of three advantages - shorter than the run's, so it wraps.
            .teach_share = 0.5,
            .teach_window = 3,
        },
    );
    defer planning.deinit(gpa);
    try on_device.copyWorlds(gpa, planning.copy_sources);
    var stream: Random.DefaultPrng = .init(17);
    const planners: robotgpu_host.TrainerPlanners = .{ .planning = &planning, .random = stream.random() };
    // THE TRAINER, in its second phase from the start.
    var kit_pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &spirvEntries(zn_mlp, zn_mlp_spirv));
    defer kit_pipe.deinit();
    const feature_count: usize = z.robot_track.localSize(model.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    @memset(means, 0);
    @memset(spreads, 1);
    const Trainer: type = z.robot_track_resident.Resident(zn_mlp);
    const normalizer: z.robot_latent.Normalizer = .{ .mean = means, .spread = spreads };
    const trainer: *Trainer = try .init(gpa, &kit_pipe, fleet, normalizer, .{
        .rows = 4,
        .window = 4,
        .hidden = 16,
        .policy_hidden = 16,
        .collect = 4,
        .phases = .{ .enabled = true },
        // A flow learning from the plans, so the plans that teach fill teacher 2's ring.
        .actor = .flow,
        .flow = .{ .hidden_width = 8, .hidden_layers = 1, .fpo_rows = 0, .flow_dpg = false },
    });
    defer trainer.deinit();
    trainer.beginPhaseTwo();
    const arrays: robotgpu.WorldStateLayout = on_device.layout.world_f;
    try trainer.acceptDeviceActing(first_world, world_count, arrays.policy_inputs.stride, arrays.actions.stride);
    const plan_horizon: u32 = on_device.counts.plan_horizon;
    const replan_count: u32 = 2;
    try trainer.acceptCandidateRecording(candidate_capacity, candidates_per_planner, plan_horizon, replan_count);
    try trainer.acceptCandidateActing(candidate_capacity);
    var outcome: PlannersByTroubleOutcome = .{};
    var device_events: robotgpu_host.DeviceEvents = .{};
    const fractions_now: []f32 = try gpa.alloc(f32, world_count);
    defer gpa.free(fractions_now);
    const fractions_before: []f32 = try gpa.alloc(f32, world_count);
    defer gpa.free(fractions_before);
    const troubles: []f32 = try gpa.alloc(f32, world_count);
    defer gpa.free(troubles);
    const one_decision: u32 = 1;
    const exploration_spread: f32 = 0.3;
    // Decisions 3 to 8: the replans at 4 and 8, each preceded by the check's own ranking.
    var decision_number: u32 = replan_interval - 1;
    while (decision_number <= replan_count * replan_interval) : (decision_number += 1) {
        const is_replan: bool = decision_number % replan_interval == 0;
        var ranked: [trouble_planners]u32 = undefined;
        if (is_replan) {
            const fraction_array: @FieldType(robotgpu.WorldStateLayout, "loss_fraction") = arrays.loss_fraction;
            const before_array: @FieldType(robotgpu.WorldStateLayout, "previous_loss_fraction") =
                arrays.previous_loss_fraction;
            for (fractions_now, fractions_before, 0..) |*now, *before, character| {
                const world: u32 = first_world + @as(u32, @intCast(character));
                var number: [1]f32 = undefined;
                try readWorldFloats(gpa, &on_device, fraction_array.at(world, 0), &number);
                now.* = number[0];
                try readWorldFloats(gpa, &on_device, before_array.at(world, 0), &number);
                before.* = number[0];
            }
            for (troubles, fractions_now, fractions_before) |*trouble, now, before| {
                trouble.* = z.robot.projectedHazard(now, before, lookahead_decisions);
                outcome.largest_trouble = @max(outcome.largest_trouble, trouble.*);
            }
            for (fractions_now) |fraction| {
                outcome.characters_with_a_fraction += @intFromBool(fraction > 0);
            }
            robotgpu_host.mostInTrouble(troubles, &ranked);
            for (&ranked) |*character| {
                character.* += first_world;
            }
        }
        const examples_before: u32 = if (trainer.device_acting.?.flow_examples) |examples| examples.next else 0;
        try on_device.actTrainerOnDevice(
            zn_mlp,
            gpa,
            trainer,
            one_decision,
            decision_number,
            physics_steps,
            .{ .exploration_spread = exploration_spread, .flow_scale = 1 },
            planners,
            &device_events,
        );
        // The examples this decision kept: each a character's whose plan teaches now.
        if (trainer.device_acting.?.flow_examples) |examples| {
            var slot: u32 = examples_before;
            while (slot != examples.next) : (slot = (slot + 1) % examples.capacity) {
                const world: u32 = first_world + examples.slot_character[slot];
                outcome.flow_slots_kept += 1;
                outcome.flow_slots_of_plans_not_teaching += @intFromBool(!planning.planTeaches(world));
            }
        }
        if (!is_replan) {
            continue;
        }
        const replan_index: usize = decision_number / replan_interval - 1;
        outcome.planners_as_ranked[replan_index] = eql(u32, planning.planners(), &ranked);
        // The plans that teach, judged again: each planner's advantage - its winner's score less that of the policy's
        // candidate - and the window's top half, by the check's own sort; the policy's candidates all zero.
        const window: []const f32 = planning.advantages[0..planning.advantage_count];
        var window_sorted: [3]f32 = undefined;
        @memcpy(window_sorted[0..window.len], window);
        sortSlice(f32, window_sorted[0..window.len], {}, std.sort.asc(f32));
        const below_half: usize = @trunc(0.5 * float(window.len));
        const top_count: usize = @max(1, window.len - below_half);
        const threshold: f32 = window_sorted[window.len - top_count];
        for (planning.planners(), 0..) |_, planner_index| {
            const first_candidate: usize = planning.firstCandidateOf(planner_index);
            const block_scores: []const f32 = planning.candidate_scores[first_candidate..][0..candidates_per_planner];
            const winner: usize = robotgpu_host.bestInBlock(block_scores);
            const advantage: f32 = block_scores[winner] - block_scores[1];
            const teaches: bool = advantage > 0 and advantage >= threshold;
            outcome.plans_judged += 1;
            outcome.plans_teaching += @intFromBool(planning.teaches[planner_index]);
            outcome.plans_judged_otherwise += @intFromBool(planning.teaches[planner_index] != teaches);
            const policy_knots: []const f32 = planning.candidateKnots(first_candidate + 1);
            const all_zero: bool = for (policy_knots) |number| {
                if (number != 0) {
                    break false;
                }
            } else true;
            outcome.policy_candidates_not_zero += @intFromBool(!all_zero);
        }
        var copies_as_chosen: bool = true;
        for (planning.copy_sources, 0..) |source, world| {
            const block: usize = world / candidates_per_planner;
            const expected: ?u32 = if (world < candidate_capacity and block < trouble_planners)
                ranked[block]
            else
                null;
            copies_as_chosen = copies_as_chosen and source == expected;
        }
        outcome.copy_tables_as_chosen[replan_index] = copies_as_chosen;
        const recording: z.robot_track_resident.CandidateRecording = trainer.candidate_recording.?;
        outcome.planners_recorded[replan_index] = recording.plannersOf(replan_index);
        const favoured: []const bool = recording.favouredOf(replan_index);
        for (favoured[trouble_planners * candidates_per_planner ..]) |is_favoured| {
            outcome.favoured_past_the_planners += @intFromBool(is_favoured);
        }
    }
    // THE JUDGEMENT ON SCORES BY HAND: two planners, blocks of four - the warm start, the policy's candidate, two
    // drawn - three replans, a window of four advantages and a share of a half.
    //
    //     replan  planner 0 scores       advantage   planner 1 scores       advantage   window sorted        teaches
    //     1       1.0 0.5 0.9 0.2        0.5         0.3 0.6 0.4 0.1        0 (policy)  0 0.5                yes no
    //     2       0.2 0.1 0.3 0.0        0.2         0.9 0.2 0.5 0.4        0.7         0 0.2 0.5 0.7        no yes
    //     3       nan 0.1 0.0 0.0        0 (policy)  0.5 nan 0.4 0.3        nan, kept   0 0 0.2 0.7 (wrap)   no no
    //
    // The threshold is the lowest of the window's top half: 0.5, then 0.5, then 0.2.
    const hand_worlds = [_]u32{ first_world, first_world + 1 };
    var by_hand: robotgpu_host.Planning = try .init(
        gpa,
        on_device.counts,
        on_device.layout,
        &hand_worlds,
        offset_count,
        fleet.options.action_scale,
        .{ .candidates_per_planner = 4, .teach_share = 0.5, .teach_window = 4 },
    );
    defer by_hand.deinit(gpa);
    by_hand.planAroundPolicy();
    const not_a_number: f32 = nan(f32);
    const hand_scores = [3][8]f32{
        .{ 1.0, 0.5, 0.9, 0.2, 0.3, 0.6, 0.4, 0.1 },
        .{ 0.2, 0.1, 0.3, 0.0, 0.9, 0.2, 0.5, 0.4 },
        .{ not_a_number, 0.1, 0.0, 0.0, 0.5, not_a_number, 0.4, 0.3 },
    };
    const hand_teaches = [3][2]bool{ .{ true, false }, .{ false, true }, .{ false, false } };
    for (hand_scores, hand_teaches) |scores, expected| {
        @memcpy(by_hand.candidate_scores, &scores);
        by_hand.judgePlans();
        for (by_hand.teaches, expected) |teaches, expected_teaches| {
            outcome.hand_judgements_off += @intFromBool(teaches != expected_teaches);
        }
    }
    outcome.hand_judged_plans = by_hand.judged_plans;
    outcome.hand_teaching_plans = by_hand.teaching_plans;
    outcome.hand_advantage_sum = by_hand.advantage_sum;
    // AS WHOLE ACTIONS the same rule against the servo, the plan of zeros in the same place: the first replan's
    // scores judged alike - planner 0 teaches, planner 1, whose winner is its baseline, does not.
    var whole_actions: robotgpu_host.Planning = try .init(
        gpa,
        on_device.counts,
        on_device.layout,
        &hand_worlds,
        offset_count,
        fleet.options.action_scale,
        .{ .candidates_per_planner = 4, .teach_share = 0.5, .teach_window = 4 },
    );
    defer whole_actions.deinit(gpa);
    @memcpy(whole_actions.candidate_scores, &hand_scores[0]);
    whole_actions.judgePlans();
    for (whole_actions.teaches, hand_teaches[0]) |teaches, expected_teaches| {
        outcome.hand_whole_action_judgements_off += @intFromBool(teaches != expected_teaches);
    }
    // Who follows a plan after the second replan: the planners, by a following share of 1; no other character.
    const counters: robotgpu.WorldIntegersLayout = on_device.layout.world_u;
    var character: u32 = 0;
    while (character < world_count) : (character += 1) {
        const world: u32 = first_world + character;
        var following: [1]u32 = undefined;
        try readWorldIntegers(gpa, &on_device, counters.plan_following.at(world, 0), &following);
        const follows: bool = following[0] != @backingInt(robotgpu.PlanFollowing.none);
        const is_planner: bool = indexOfScalar(u32, planning.planners(), world) != null;
        outcome.planners_following += @intFromBool(follows and is_planner);
        outcome.characters_following_not_planners += @intFromBool(follows and !is_planner);
    }
    return outcome;
}

test "robotgpu planners by trouble: each replan's planners are the characters in most trouble, their blocks alone" {
    const timer: TestTimer = .start("robotgpu planners by trouble");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const found: PlannersByTroubleOutcome =
        try runRobotgpuPlannersByTrouble(testing.allocator, opened.device, opened.queue, coverage);
    if (test_options.long_checks) {
        print("vk-host-test: robotgpu planners by trouble: largest trouble {d:.3}, {d} characters off\n", .{
            found.largest_trouble,
            found.characters_with_a_fraction,
        });
    }
    // The measure is alive: knocked characters are off their references.
    try expect(found.largest_trouble > 0.5);
    try expect(found.characters_with_a_fraction >= 2);
    for (found.planners_as_ranked, found.copy_tables_as_chosen, found.planners_recorded) |ranked, copied, recorded| {
        try expect(ranked);
        try expect(copied);
        // Two planners of the four blocks the room has.
        try expectEqual(@as(u32, 2), recorded);
    }
    try expectEqual(@as(u32, 0), found.favoured_past_the_planners);
    try expectEqual(@as(u32, 2), found.planners_following);
    try expectEqual(@as(u32, 0), found.characters_following_not_planners);
    // Every plan judged against the policy's own candidate, all zeros, as the check judges it.
    try expectEqual(@as(u32, 2 * 2), found.plans_judged);
    try expectEqual(@as(u32, 0), found.plans_judged_otherwise);
    try expectEqual(@as(u32, 0), found.policy_candidates_not_zero);
    // Teacher 2 keeps the plans that teach alone (here the planners are the characters knocked over, which rarely
    // follow long: the keeping is checked with the planners around the policy).
    try expectEqual(@as(u32, 0), found.flow_slots_of_plans_not_teaching);
    // The judgement on scores by hand: the window's top half, the policy beaten, a score not a number left out.
    try expectEqual(@as(u32, 0), found.hand_judgements_off);
    // Judged: two plans at each of the first two replans, one at the third (planner 1's baseline not a number);
    // taught: one at each of the first two; the advantages 0.5 + 0 + 0.2 + 0.7 + 0.
    try expectEqual(@as(u64, 5), found.hand_judged_plans);
    try expectEqual(@as(u64, 2), found.hand_teaching_plans);
    try testing.expectApproxEqAbs(@as(f64, 1.4), found.hand_advantage_sum, 1e-6);
    try expectEqual(@as(u32, 0), found.hand_whole_action_judgements_off);
    try opened.expectNoNewValidationErrors();
}

test "robotgpu planners around the policy: a follower's choice is the policy's plus its offset, its lookahead lived" {
    const timer: TestTimer = .start("robotgpu planners around the policy");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const found: PlannersInTheLoopOutcome = try runRobotgpuPlannersInTheLoop(
        testing.allocator,
        opened.device,
        opened.queue,
        coverage,
        .planners_around_policy,
    );
    defer found.deinit(testing.allocator);
    if (test_options.long_checks) {
        print("vk-host-test: robotgpu planners around the policy: {d} of 16 decisions, {d:.2} epsilons\n", .{
            found.decisions_following,
            found.largest_gap_epsilons,
        });
    }
    // Two planners, eight decisions each, following at every one, every record labelled and no other.
    try expectEqual(@as(u32, 2 * 8), found.decisions_following);
    try expectEqual(@as(u32, 2 * 8), found.labelled_records);
    try expectEqual(@as(u32, 0), found.label_mismatches);
    // Each following decision's choice: the policy's raw action plus the plan's line, all 75 numbers - one add after
    // the line's multiply and add, within a few epsilons; unexplored, though the others explore at 0.3.
    try expectEqual(@as(u32, 2 * 8 * 75), found.actions_compared);
    try expect(found.largest_gap_epsilons <= 4);
    // The offsets were no zeros: the ramp's line moved from decision to decision.
    try expect(found.plan_line_moved);
    // The learner's flow corrected the characters that are no planners - and none of the followers' choices above,
    // which are the policy's and the plan's alone.
    try expect(found.flow_corrected_others);
    // Teacher 2's examples: one a following decision, each the follower's acting row and its whole choice.
    // Not those of a plan that does not teach: the second planner's after each replan's own decision.
    try expect(found.flow_examples_of_plans_not_teaching > 0);
    try expectEqual(found.flow_examples_expected, found.flow_examples_kept);
    try expectEqual(@as(u32, 0), found.flow_example_numbers_differing);
    // And a round's batch drawn from them on the device: every row one of them, whole.
    try expect(found.flow_batch_rows > 0);
    try expectEqual(@as(u32, 0), found.flow_batch_rows_unmatched);
    // Only plans that ended well: each slot good exactly when its stretch's labels were kept - some, not all: the last
    // stretch has not settled - and the batch drawn from the good alone.
    try expectEqual(@as(u32, 0), found.flow_slots_misjudged);
    try expect(found.flow_slots_good > 0 and found.flow_slots_good < found.flow_examples_kept);
    try expectEqual(@as(u32, 0), found.flow_batch_slots_not_good);
    // Its targets taken against the policy: the plan's line while the policy is as it acted; and when the policy's
    // answers move, the targets move back by as much - the flow keeps only what the policy has not learned.
    try expectEqual(@as(u32, 0), found.flow_target_numbers_off);
    try expectEqual(@as(u32, 0), found.flow_target_moves_off);
    // The characters acted through the policy's average: the live policy, which answers 7 everywhere, chose none.
    try expect(found.live_answers_everywhere);
    try expectEqual(@as(u32, 0), found.acting_numbers_from_live);
    // An update on the recorded labels, counted, the flow learning the plans in it.
    try expect(found.label_update_counted);
    try expect(found.label_update_moved_flow);
    // At its full weight from the first update: the physics' plans need no trust in the critic.
    const distill_weight: f32 = (z.robot_track_resident.PlanningSettings{}).distill_weight;
    try expectEqual(distill_weight, found.distillation_weight_after_labels);
    // A label update on the flow's main mode: every one of the kit's rows an example of the ring whole, counted, the
    // live policy moved.
    try expect(found.mode_rows_drawn > 0);
    try expectEqual(@as(u32, 0), found.mode_rows_unmatched);
    try expectEqual(@as(u32, 0), found.mode_slots_not_good);
    try expect(found.mode_update_counted);
    try expect(found.mode_moved_policy);
    // The model planner: its three states on the physics' two planners and one other character, each one's correction
    // its chosen first correction to the bit - added for the other, in the flow's place; the planners follow their
    // physics plans.
    try expectEqual(@as(u32, 3), found.model_states);
    try expectEqual(@as(u32, 2), found.model_states_on_planners);
    // The funnel, at the second replan: each planner's candidates its warm start, then the model's plan.
    try expectEqual(@as(u32, 2), found.funnel_planners_seeded);
    try expectEqual(@as(u32, 0), found.model_correction_numbers_differing);
    try expectEqual(@as(u32, 0), found.model_state_numbers_differing);
    // THE WINNERS' LOOKAHEADS, LIVED: the lookahead's policy - the candidates' rows of the kit - is the characters'
    // to the bit, and the action filter blends the same choice from the same action, so each planner lives its
    // winner's four decisions record for record; no loser's first record is the planner's - their offsets differ.
    const recorded: CandidatesRecorded = found.candidates_recorded;
    try expectEqual(@as(u32, 2 * 2 * 4), recorded.winner_records_compared);
    try expectEqual(@as(u32, 0), recorded.winner_records_differing);
    try expectEqual(@as(u32, 0), recorded.loser_records_matching);
    try expectEqual(@as(u64, 2), recorded.lookaheads_complete);
    try expectEqual(@as(u32, 0), recorded.favoured_mistaken);
    // At each replan's first decision a planner's candidates share its state and none shares an action.
    try expectEqual(@as(u32, 2 * 2 * 3), recorded.pair_states_compared);
    try expectEqual(@as(u32, 0), recorded.pair_states_differing);
    try expectEqual(@as(u32, 0), recorded.pair_actions_same);
    try opened.expectNoNewValidationErrors();
}

test "robotgpu planners at a share of 0: each takes its plan's first action alone, and no other world changes" {
    const timer: TestTimer = .start("robotgpu planners at a share of 0");
    defer timer.report();
    const opened: TestDevice = try .open();
    const coverage: *DeviceCoverage = &tests_device_coverage;
    const gpa: Allocator = testing.allocator;
    const without: PlannersInTheLoopOutcome =
        try runRobotgpuPlannersInTheLoop(gpa, opened.device, opened.queue, coverage, .no_planners);
    defer without.deinit(gpa);
    const first_decisions: PlannersInTheLoopOutcome = try runRobotgpuPlannersInTheLoop(
        gpa,
        opened.device,
        opened.queue,
        coverage,
        .planners_following_first_decisions,
    );
    defer first_decisions.deinit(gpa);
    // EACH PLANNER TOOK ITS PLAN's ACTION AT THE REPLANS' OWN DECISIONS ALONE: two planners, two replans (at 4 and
    // 8), each decision's whole action (75) on its plan's line - its first knot.
    try expectEqual(@as(u32, 2 * 2), first_decisions.decisions_following);
    try expectEqual(@as(u32, 2 * 2 * 75), first_decisions.actions_compared);
    try expect(first_decisions.largest_gap_epsilons <= 2);
    // Their records at those decisions labelled, and no other record - none at all without planners.
    try expectEqual(@as(u32, 2 * 2), first_decisions.labelled_records);
    try expectEqual(@as(u32, 0), first_decisions.label_mismatches);
    try expectEqual(@as(u32, 0), without.labelled_records);
    // Each planner lived its winner's lookahead for the replan's own decision alone: its winner's first record.
    const recorded: CandidatesRecorded = first_decisions.candidates_recorded;
    try expectEqual(@as(u32, 2 * 2), recorded.winner_records_compared);
    try expectEqual(@as(u32, 0), recorded.winner_records_differing);
    try expectEqual(@as(u32, 0), recorded.loser_records_matching);
    // THE LABELS KEPT: each replan's own decision a stretch of one, settled by the decision after it - 2 x 2 labels;
    // and a label update on them. Without planners none, and the label update refused.
    try expectLabelsKept(first_decisions.labels_kept, 2 * 2);
    try expectLabelsKept(without.labels_kept, 0);
    // THE DECISIONS' TIME BY PHASE, without planners: eight decisions, and no replan - no segment and no host time
    // under that phase.
    if (test_options.long_checks) {
        printPhases("robotgpu without planners", without.phases);
    }
    try expectLoopPhases(without.phases, 8, 0);
    // EVERY OTHER WORLD AS THE LOOP WITHOUT PLANNERS LEFT IT, to the bit - the characters that are no planners, their
    // numbers and their records in the ring. What the loop without planners left is no trivial match: every
    // character recorded every decision, and the ring holds numbers.
    const plain: LoopFinish = without.finish;
    const planned: LoopFinish = first_decisions.finish;
    for (plain.books.written, planned.books.written) |plain_written, planned_written| {
        try expectEqual(@as(u64, 8), plain_written);
        try expectEqual(plain_written, planned_written);
    }
    var other_worlds_buffer: [16]u32 = undefined;
    var other_world_count: usize = 0;
    var world: u32 = plain.first_character;
    while (world < plain.world_count) : (world += 1) {
        const is_planner: bool = indexOfScalar(u32, &plain.planner_worlds, world) != null;
        if (!is_planner) {
            other_worlds_buffer[other_world_count] = world;
            other_world_count += 1;
        }
    }
    const other_worlds: []const u32 = other_worlds_buffer[0..other_world_count];
    try expectEqual(@as(usize, 6), other_worlds.len);
    const numbers_differing: u32 = worldsNumbersDiffering(plain.layout, other_worlds, plain.worlds(), planned.worlds());
    // The ring is step-major: each step's slot holds every character's record side by side.
    const character_count: usize = plain.world_count - plain.first_character;
    const step_floats: usize = character_count * plain.record_width;
    const step_count: usize = plain.ring.len / step_floats;
    var ring_numbers_set: u32 = 0;
    var ring_numbers_differing: u32 = 0;
    var step: usize = 0;
    while (step < step_count) : (step += 1) {
        for (other_worlds) |other_world| {
            const env: usize = other_world - plain.first_character;
            const record_at: usize = step * step_floats + env * plain.record_width;
            const plain_record: []const f32 = plain.ring[record_at..][0..plain.record_width];
            const planned_record: []const f32 = planned.ring[record_at..][0..plain.record_width];
            for (plain_record, planned_record) |plain_number, planned_number| {
                if (plain_number != 0) {
                    ring_numbers_set += 1;
                }
                const plain_bits: u32 = @bitCast(plain_number);
                const planned_bits: u32 = @bitCast(planned_number);
                if (plain_bits != planned_bits) {
                    ring_numbers_differing += 1;
                }
            }
        }
    }
    if (test_options.long_checks or numbers_differing != 0 or ring_numbers_differing != 0) {
        print("vk-host-test: robotgpu planners at a share of 0: {d} other characters' numbers, {d} of their " ++
            "ring numbers differ\n", .{ numbers_differing, ring_numbers_differing });
    }
    try expect(ring_numbers_set > 0);
    try expectEqual(@as(u32, 0), numbers_differing);
    try expectEqual(@as(u32, 0), ring_numbers_differing);
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

test "writes each larger than the last are staged whole" {
    // Declared before the two churn tests, so that on every device they start from a staging that earlier writes
    // have grown past its budget - as a run with large worlds leaves it.
    const timer: TestTimer = .start("growing writes");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(try growStagingWithLargerWrites(opened.device, opened.queue));
    try opened.expectNoNewValidationErrors();
}

test "bind groups made and destroyed round after round keep the descriptor pages bounded and add no staging chunk" {
    const timer: TestTimer = .start("bind group churn");
    defer timer.report();
    const opened: TestDevice = try .open();
    try expect(churnBindGroups(opened.device, opened.queue));
    try opened.expectNoNewValidationErrors();
}

test "large writes round after round add at most one staging chunk, used again every round" {
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
    // A run limited by `--filter` dispatches only its part: nothing to report.
    if (test_root.tests_are_filtered) {
        return error.SkipZigTest;
    }
    var never_dispatched: usize = 0;
    for (robotgpu.kernels, tests_device_coverage.dispatches) |kernel, dispatched| {
        if (dispatched != 0) {
            continue;
        }
        std.debug.print("vk-host-test: robotgpu kernel '{s}' never dispatched on the device\n", .{kernel});
        never_dispatched += 1;
    }
    const dispatched_kernels: usize = robotgpu.kernels.len - never_dispatched;
    std.debug.print("vk-host-test: robotgpu device coverage - {d} of {d} kernels dispatched on the device\n", .{
        dispatched_kernels,
        robotgpu.kernels.len,
    });
    // A kernel no test sends to a GPU is checked on the CPU twin alone, which proves nothing about the device. A
    // kernel with no work in any model here is no exception: a model with work for it belongs among the tests.
    try expectEqual(@as(usize, 0), never_dispatched);
}
