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
const zn = @import("zn");
const zn_unary = @import("zn_unary");
const zrl_binary = @import("zrl_binary");
const z = @import("zimr");
const zm = @import("zm");

const eql = std.mem.eql;
const print = std.debug.print;
const writeInt = std.mem.writeInt;
const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator;
const asBytes = std.mem.asBytes;
const indexOf = std.mem.indexOf;
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

/// The most times `readBack` polls before calling the read lost: far more than a 16-byte copy takes on any driver.
const read_poll_limit: u32 = 50_000_000;

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
    var polls: u32 = 0;
    while (!wgpu.bufferReadPoll(read)) {
        polls += 1;
        if (polls == read_poll_limit) {
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

/// How many times `readLatest` is polled before the check gives up: each poll is one frame's worth of waiting in an
/// app, and lavapipe finishes this work in a few.
const engine_poll_limit: u32 = 1_000_000;

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

    var polls: u32 = 0;
    while (polls < engine_poll_limit) : (polls += 1) {
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
    var polls: u32 = 0;
    while (polls < engine_poll_limit) : (polls += 1) {
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
        pipe.run("clear_overflow", counts.nworld);
        pipe.readRange(.world_u, 0, read_back);
        for (read_back, 0..) |word, index| {
            const word_index: u32 = @intCast(index);
            const relative: u32 = word_index -% overflow.offset;
            const in_overflow: bool = word_index >= overflow.offset and
                relative < overflow.stride * counts.nworld and relative % overflow.stride == 0;
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

/// THE MATHS PROBE'S TABLE: every zimrmath function robot.zig's arithmetic calls, in
/// `robotgpu_probe.MathsResults`' order. The bars were set from the first measurement on lavapipe, 1,024 rows, with
/// headroom for the fused multiply-adds and square roots of other devices:
///
///     result                   measured    bar    what is behind it
///     conjugate, rotate,       0           4      plain arithmetic and square roots - exact on lavapipe; a device
///     normalize3, cross,                          may fuse a multiply into an add, or round a square root once more
///     dot3, length3
///     qmul                     1.14        4      the same, one fused multiply-add showing
///     the two axis-angle       1.00        8      zimrmath's GPU sine and cosine (polynomials) against the CPU's
///     forms                                       library: within one epsilon
///     acosRad                  1.91        8      zimrmath's GPU acos
///     atan2Rad                 28          64     zimrmath's GPU atan2 - the least precise, about 1e-5 radian
///                                                 near pi, far below what the physics resolves
const MathsCheck = struct {
    const row_count: u32 = 1024;

    const results = [_]ProbeResult{
        probeResult(MathsResults, .product, "qmul", 4),
        probeResult(MathsResults, .conjugated, "conjugate", 4),
        probeResult(MathsResults, .rotated, "rotate", 4),
        probeResult(MathsResults, .from_unit_axis, "quatFromNormAxisAngle", 8),
        probeResult(MathsResults, .from_axis, "quatFromAxisAngle", 8),
        probeResult(MathsResults, .normalized, "normalize3", 4),
        probeResult(MathsResults, .crossed, "cross", 4),
        probeResult(MathsResults, .dot_product, "dot3", 4),
        probeResult(MathsResults, .vector_length, "length3", 4),
        probeResult(MathsResults, .heading, "atan2Rad", 64),
        probeResult(MathsResults, .angle_between, "acosRad", 8),
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

/// THE SPATIAL PROBE'S TABLE: robot.zig's spatial algebra in `robotgpu_probe.SpatialResults`'
/// order - plain arithmetic throughout, no transcendental function. The bars were set from the first measurement on
/// lavapipe, 1,024 rows:
///
///     result                   measured    bar    what is behind it
///     Inertia.rotated, dot6    0           4      exact on lavapipe
///     Inertia.mul,             1.00        4      one fused multiply-add showing
///     Inertia.translate
///     crossMotion              1.62        4      the same, a little cancellation (velocities up to 3: terms to 9)
///     crossForce               8.61        16     CANCELLATION: forces up to 20 against velocities up to 3 make
///                                                 terms near 60; where they cancel, the result is far smaller than
///                                                 what was rounded, and the gap is measured at the result's scale
/// The inputs are physically plausible: velocities
/// and forces whose parts stay away from zero, a mass in [0.5, 5], a centre of mass within 0.3 of the origin (so
/// `h` = mass x centre of mass), positive principal moments with small products of inertia, a unit rotation and an
/// offset within 0.5.
const SpatialCheck = struct {
    const row_count: u32 = 1024;

    const results = [_]ProbeResult{
        probeResult(SpatialResults, .motion_cross, "crossMotion", 4),
        probeResult(SpatialResults, .force_cross, "crossForce", 16),
        probeResult(SpatialResults, .inertia_times_motion, "Inertia.mul", 4),
        probeResult(SpatialResults, .translated, "Inertia.translate", 4),
        probeResult(SpatialResults, .rotated, "Inertia.rotated", 4),
        probeResult(SpatialResults, .power, "dot6", 4),
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

    var polls: u32 = 0;
    while (polls < engine_poll_limit) : (polls += 1) {
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

/// Runs one entry of a pipeline, then polls `readLatest(.out)` until the mirror holds that dispatch. Null when it
/// never does.
fn runAndRead(
    comptime Kernel: type,
    pipeline: *z.Compute(Kernel),
    comptime entry: [:0]const u8,
    threads: u32,
) ?[]const f32 {
    pipeline.run(entry, threads);
    const dispatched: u64 = pipeline.readGeneration().submitted;
    var polls: u32 = 0;
    while (polls < engine_poll_limit) : (polls += 1) {
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

/// The headless screen's size, in pixels: a row of `screen_width` texels fits one copy row (`copy_row_pitch`).
const screen_width: u32 = 16;
const screen_height: u32 = 8;

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

pub fn main() !u8 {
    try vulkan_host.startHeadlessWithScreen(screen_width, screen_height);
    const device: wgpu.DeviceHandle = wgpu.initDevice();
    const queue: wgpu.QueueHandle = wgpu.getQueue(device);
    if (!vulkan_host.isValidating()) {
        print("vk-host-test: the validation layer is not on - install it (`vulkan-validationlayers`)\n", .{});
        _ = vulkan_host.shutdown();
        return 2;
    }

    clearTexture(device, queue);
    clearTwoTargets(device, queue);
    const read_matches: bool = readBack(device, queue);
    const copy_matches: bool = copyTexture(device, queue);
    const screen_matches: bool = drawOnScreen(device, queue);
    mipAndArrayViews(device, queue);
    var adapter_buffer: [256]u8 = undefined;
    const adapter: []const u8 = wgpu.adapterInfo(&adapter_buffer);
    print("vk-host-test: adapter: {s}\n", .{adapter});
    const names_vulkan: bool = indexOf(u8, adapter, "Vulkan") != null;
    const kernel_doubles: bool = runKernel(device, queue);
    var debug_allocator: DebugAllocator(.{}) = .init;
    const engine_doubles: bool = try runEngineCompute(debug_allocator.allocator(), device, queue);
    const zimrnum_failures: u32 = try runZimrnumSweep(debug_allocator.allocator(), device, queue);
    try makeTrainingPipelines(debug_allocator.allocator(), device, queue);
    const kit_gap: ?f32 = try runKitKernels(debug_allocator.allocator(), device, queue);
    const probe: ProbeOutcome = try runRobotgpuProbe(debug_allocator.allocator(), device, queue);
    const tally_holds: bool = try runDispatchTally(debug_allocator.allocator(), device, queue);
    const ranges_match: bool = try runRangedReadback(debug_allocator.allocator(), device, queue);
    const pushes_hold: bool = try runPushedBatch(debug_allocator.allocator(), device, queue);
    const timing: TimingOutcome = try runTimings(debug_allocator.allocator(), device, queue);
    const lending_holds: bool = try runBorrowing(debug_allocator.allocator(), device, queue);
    const factorisation: CholeskyOutcome = try runCholesky(debug_allocator.allocator(), device, queue);
    const envelope_bytes: ?u64 = try runMemoryEnvelope(debug_allocator.allocator(), device, queue);
    const overflow_cleared: bool = try runRobotgpuOverflow(debug_allocator.allocator(), device, queue);
    var maths_gaps: [MathsCheck.results.len]f32 = undefined;
    const maths_read: bool =
        try runProbeTable(debug_allocator.allocator(), device, queue, MathsCheck.table, &maths_gaps);
    var spatial_gaps: [SpatialCheck.results.len]f32 = undefined;
    const spatial_read: bool =
        try runProbeTable(debug_allocator.allocator(), device, queue, SpatialCheck.table, &spatial_gaps);
    const constants_land: bool = try runConstantIndex(debug_allocator.allocator(), device, queue);
    const engine_leaked: bool = debug_allocator.deinit() == .leak;
    const sort_matches: bool = runCountingSort(device, queue);
    releaseWhileHeld(device);
    const bounded: bool = churnBindGroups(device, queue) and try churnLargeWrites(device, queue);

    const counts: vulkan_host.MessageCounts = vulkan_host.shutdown();
    if (!read_matches) {
        print("vk-host-test: FAILED - the bytes read back differ from those written\n", .{});
        return 1;
    }
    if (!copy_matches) {
        print("vk-host-test: FAILED - the copied texture differs from its clear color\n", .{});
        return 1;
    }
    if (!screen_matches) {
        print("vk-host-test: FAILED - the headless screen's frames read back wrong\n", .{});
        return 1;
    }
    if (!names_vulkan) {
        print("vk-host-test: FAILED - the adapter info names no Vulkan version\n", .{});
        return 1;
    }
    if (!kernel_doubles) {
        print("vk-host-test: FAILED - the kernel's output differs from four times its input\n", .{});
        return 1;
    }
    if (!engine_doubles) {
        print("vk-host-test: FAILED - the engine's compute path gave a wrong result\n", .{});
        return 1;
    }
    if (zimrnum_failures > 0) {
        print("vk-host-test: FAILED - {d} of zimrnum's {d} cases differ from the CPU\n", .{
            zimrnum_failures,
            conf.cases.len,
        });
        return 1;
    }
    const kit_gap_limit: f32 = 1.0e-5;
    const kit_matches: bool = if (kit_gap) |gap| gap <= kit_gap_limit else false;
    if (kit_gap) |gap| {
        print("vk-host-test: the kit's learning kernels: largest relative gap {e} from the CPU twin\n", .{gap});
    }
    if (!kit_matches) {
        print("vk-host-test: FAILED - the kit's learning kernels differ from their CPU twin\n", .{});
        return 1;
    }
    // The robotgpu probe: within the reordering's rounding of the twin, and exactly itself run after run.
    const probe_gap_limit: f32 = 1.0e-5;
    if (probe.subgroup_gap) |gap| {
        print("vk-host-test: robotgpu probe: subgroup sum {e} of its magnitudes from the twin\n", .{gap});
    } else {
        print("vk-host-test: robotgpu probe: subgroup sum not applicable - no subgroup arithmetic in compute\n", .{});
    }
    const two_runs: []const u8 = if (probe.repeats_exactly) "identical" else "DIFFERENT";
    print("vk-host-test: robotgpu probe: workgroup sum {e} of its magnitudes from the twin; two device runs {s}\n", .{
        probe.workgroup_gap,
        two_runs,
    });
    const subgroup_holds: bool = if (probe.subgroup_gap) |gap| gap <= probe_gap_limit else true;
    const workgroup_holds: bool = probe.workgroup_gap <= probe_gap_limit;
    const probe_holds: bool = subgroup_holds and workgroup_holds and probe.repeats_exactly;
    if (!probe_holds) {
        print("vk-host-test: FAILED - the robotgpu probe's reductions\n", .{});
        return 1;
    }
    // The simulator's first kernel: every world's overflow word cleared, nothing else touched, device and twin alike.
    if (!overflow_cleared) {
        print("vk-host-test: FAILED - robotgpu's clear_overflow\n", .{});
        return 1;
    }
    print("vk-host-test: robotgpu clear_overflow: 64 worlds' overflow words cleared, nothing else written\n", .{});
    // The memory envelope: an arena as large as a binding may span, its first and last pages written and read back.
    const arena_bytes: u64 = envelope_bytes orelse {
        print("vk-host-test: FAILED - an arena as large as a binding came back wrong at its start or end\n", .{});
        return 1;
    };
    print("vk-host-test: robotgpu memory envelope: a {d} MB arena, its first and last pages written and read back\n", .{
        arena_bytes >> 20,
    });
    // The workgroup Cholesky: a true factorisation, the twin's arithmetic, and the same bits every run.
    print("vk-host-test: robotgpu Cholesky: L L^T within {e} of A; device {d:.2} epsilons from the twin; " ++
        "twin {d:.2} from zimrnum's; two device runs {s}\n", .{
        factorisation.reconstruction_relative,
        factorisation.device_twin_epsilons,
        factorisation.twin_zimrnum_epsilons,
        if (factorisation.repeats_exactly) "identical" else "DIFFERENT",
    });
    const factorisation_holds: bool = factorisation.reconstruction_relative <= 1.0e-5 and
        factorisation.device_twin_epsilons <= 128 and factorisation.twin_zimrnum_epsilons <= 128 and
        factorisation.repeats_exactly;
    if (!factorisation_holds) {
        print("vk-host-test: FAILED - the robotgpu Cholesky\n", .{});
        return 1;
    }
    // Lending: a borrower's writes are in the owner's buffer, with nothing copied between them.
    if (!lending_holds) {
        print("vk-host-test: FAILED - a borrowing pipe's writes are not in the owner's buffer\n", .{});
        return 1;
    }
    print("vk-host-test: robotgpu buffer lending: the borrower's writes read back from the owner's buffer\n", .{});
    // Timings: four times the work takes longer; a pipe without timings reports none.
    const timing_ratio: f64 = timing.four_times_microseconds / @max(timing.one_times_microseconds, 1.0e-9);
    print("vk-host-test: robotgpu timings: busy_work {d:.0} us, four times the rounds {d:.0} us ({d:.2}x)\n", .{
        timing.one_times_microseconds,
        timing.four_times_microseconds,
        timing_ratio,
    });
    const timings_hold: bool = timing.one_times_microseconds > 0 and
        timing.four_times_microseconds > timing.one_times_microseconds and timing.untimed_reports_none;
    if (!timings_hold) {
        print("vk-host-test: FAILED - the robotgpu timings\n", .{});
        return 1;
    }
    // Push constants: three dispatches of one batch, each with its own push, each region its own value.
    if (!pushes_hold) {
        print("vk-host-test: FAILED - a robotgpu pushed dispatch wrote another dispatch's value\n", .{});
        return 1;
    }
    print("vk-host-test: robotgpu push constants: one batch, three dispatches, each region its own value\n", .{});
    // Ranged readback: three ranges of one field, through chunks of the staging buffer, equal to what was uploaded.
    if (!ranges_match) {
        print("vk-host-test: FAILED - a robotgpu ranged readback differs from what was uploaded\n", .{});
        return 1;
    }
    print("vk-host-test: robotgpu ranged readback: three ranges, one across three chunks, equal to the upload\n", .{});
    // The large dispatch: every index below the count run exactly once, across two rows of workgroups.
    if (!tally_holds) {
        print("vk-host-test: FAILED - the robotgpu large dispatch did not run every index exactly once\n", .{});
        return 1;
    }
    // The maths and spatial probes: each result within its bar of the twin, in epsilons at the result's scale.
    if (!maths_read or !spatial_read) {
        print("vk-host-test: FAILED - a robotgpu probe table's readback never came\n", .{});
        return 1;
    }
    const maths_holds: bool = reportProbeResults("robotgpu maths probe", &MathsCheck.results, &maths_gaps);
    const spatial_holds: bool = reportProbeResults("robotgpu spatial probe", &SpatialCheck.results, &spatial_gaps);
    if (!maths_holds or !spatial_holds) {
        print("vk-host-test: FAILED - a robotgpu probe table\n", .{});
        return 1;
    }
    if (!constants_land) {
        print("vk-host-test: FAILED - an element written by a constant index came back wrong\n", .{});
        return 1;
    }
    if (engine_leaked) {
        print("vk-host-test: FAILED - the engine's compute path leaked memory\n", .{});
        return 1;
    }
    if (!sort_matches) {
        print("vk-host-test: FAILED - the counting sort differs from the CPU's\n", .{});
        return 1;
    }
    if (!bounded) {
        print("vk-host-test: FAILED - descriptor pages or staging chunks grew without bound\n", .{});
        return 1;
    }
    if (counts.errors == 0 and counts.warnings == 0) {
        print(
            "vk-host-test: clear, targets, read, copy, screen, views, compute, engine, zimrnum, pipelines, kit, " ++
                "constant, lifetimes, sort, churn and large writes" ++
                " - no validation errors, no warnings\n",
            .{},
        );
        return 0;
    }
    print("vk-host-test: FAILED - {d} validation errors, {d} warnings\n", .{ counts.errors, counts.warnings });
    return 1;
}
