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
const sort_min = @import("sort_min");
const conf = @import("zn_conformance");
const zn_binary = @import("zn_binary");
const zn_matmul = @import("zn_matmul");
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
const sliceAsBytes = std.mem.sliceAsBytes;
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
const zn_binary_spirv: []const u8 = @embedFile("zn_binary_spv");
const zn_matmul_spirv: []const u8 = @embedFile("zn_matmul_spv");
const zn_unary_spirv: []const u8 = @embedFile("zn_unary_spv");
const zrl_binary_spirv: []const u8 = @embedFile("zrl_binary_spv");

/// A kernel file's entry table for `Compute.initGpu`: every entry the file declares (`kernels`), each with the file's
/// SPIR-V - natively the module is per file, and the pipeline names its entry.
fn spirvEntries(comptime Kernel: type, spirv: []const u8) [Kernel.kernels.len]z.Compute(Kernel).KernelWgsl {
    var table: [Kernel.kernels.len]z.Compute(Kernel).KernelWgsl = undefined;
    inline for (Kernel.kernels, 0..) |name, index| {
        table[index] = .{ .name = name, .wgsl = spirv };
    }
    return table;
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
            "vk-host-test: clear, targets, read, copy, screen, views, compute, engine, zimrnum, lifetimes, sort, " ++
                "churn and large writes" ++
                " - no validation errors, no warnings\n",
            .{},
        );
        return 0;
    }
    print("vk-host-test: FAILED - {d} validation errors, {d} warnings\n", .{ counts.errors, counts.warnings });
    return 1;
}
