//! VK_HELLO - a window that clears, through Vulkan, with no engine (vulkan_port_plan_v2.md stage S1).
//!
//! The smallest program that exercises every platform piece the Vulkan host stands on: the Win32 window and its
//! messages (`win32.zig`), the Vulkan loader and the hand-declared API (`vk.zig`), choosing a GPU, a surface and a
//! swapchain, and the frame protocol the host will use for everything - one timeline semaphore numbering every
//! submit, at most two frames in flight, every image in the GENERAL layout with full barriers. Each frame clears the
//! window to a slowly cycling color.
//!
//!     vk_hello.exe                 run until the window is closed
//!     vk_hello.exe --frames=600    exit after 600 frames (for a scripted run)
//!     vk_hello.exe --gpu=1         use the second listed GPU (or --gpu=NVIDIA: a name substring); also ZIMR_GPU
//!     ZIMR_VK_VALIDATE=0           skip the validation layer even when it is installed
//!
//! It prints the GPUs it found and the one it chose, the surface's formats and present modes, and at exit the frame
//! count, the swapchain rebuilds and the validation layer's error and warning counts. The exit code is 0 only when
//! the layer reported no error (or was not installed).
//!
//! ---- THE FRAME ----
//!
//!     wait until the timeline reaches this slot's last submit     (at most `frames_in_flight` frames ahead)
//!     acquire a swapchain image                                   (signals the slot's acquire semaphore)
//!     record: image UNDEFINED -> GENERAL, clear it by a rendering pass, GENERAL -> PRESENT_SRC
//!     submit: wait for the acquire; signal the image's present semaphore and the timeline's next number
//!     present: wait for the image's present semaphore
//!
//! The present semaphore belongs to the IMAGE, not to the frame slot: a present has no fence, so a semaphore is known
//! to be free again only when its image is acquired again. The acquire semaphore belongs to the slot, and is free once
//! the timeline shows the slot's last submit finished.

const std = @import("std");
const vk = @import("vk.zig");
const win32 = @import("win32.zig");
const zm = @import("zm");
const clamp = zm.clamp;
const pi = zm.pi;

const Allocator = std.mem.Allocator;
const indexOf = std.mem.indexOf;
const eql = std.mem.eql;
const span = std.mem.span;
const startsWith = std.mem.startsWith;
const parseInt = std.fmt.parseInt;
const log = std.log.scoped(.vk_hello);

/// How many frames the CPU may record ahead of the GPU.
const frames_in_flight: usize = 2;

/// "Wait as long as it takes", for the timeline and for acquire.
const no_timeout: u64 = zm.maxInt(u64);

const HelloError = error{
    VulkanTooOld,
    NoSuitableGpu,
    RequestedGpuNotFound,
    NoSurfaceFormat,
} || vk.ResultError || vk.LoadError || win32.VulkanLibraryError || win32.WindowError || Allocator.Error;

const Options = struct {
    /// Exit after this many frames; 0 runs until the window is closed.
    frame_limit: u64 = 0,
    /// A GPU's list index or a substring of its name.
    gpu_choice: ?[]const u8 = null,
    validate: bool = true,
};

/// What the validation layer reported, counted by the debug messenger.
const MessageCounts = struct {
    errors: u32 = 0,
    warnings: u32 = 0,
};

/// A GPU that can run the host: its handle, its name, and the queue family that renders, computes and presents.
const Candidate = struct {
    physical_device: vk.PhysicalDevice,
    name: [vk.max_physical_device_name_size]u8,
    device_type: vk.PhysicalDeviceType,
    queue_family: u32,
};

/// The swapchain and what is made per image.
const Swapchain = struct {
    handle: vk.SwapchainKHR = .null_handle,
    format: vk.Format = .undefined,
    extent: vk.Extent2D = .{},
    images: []vk.Image = &.{},
    views: []vk.ImageView = &.{},
    present_semaphores: []vk.Semaphore = &.{},
};

const Hello = struct {
    gpa: Allocator,
    window: *win32.Window,
    counts: MessageCounts,
    global: vk.GlobalDispatch,
    instance: vk.Instance,
    instance_dispatch: vk.InstanceDispatch,
    surface_dispatch: vk.SurfaceDispatch,
    messenger: vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
    chosen: Candidate,
    device: vk.Device,
    device_dispatch: vk.DeviceDispatch,
    swapchain_dispatch: vk.SwapchainDispatch,
    queue: vk.Queue,
    command_pool: vk.CommandPool,
    command_buffers: [frames_in_flight]vk.CommandBuffer,
    acquire_semaphores: [frames_in_flight]vk.Semaphore,
    /// Counts submits: submit number n signals the value n when it finishes.
    timeline: vk.Semaphore,
    submitted: u64,
    /// Per frame slot: the number of the last submit that used it.
    slot_serials: [frames_in_flight]u64,
    swapchain: Swapchain,
    swapchain_dirty: bool,
    frame_index: u64,
    rebuilds: u32,
};

fn readOptions(arguments: []const [:0]const u8, environment: *std.process.Environ.Map) Options {
    var options: Options = .{};
    // The first argument is the program's own name.
    const flags: []const [:0]const u8 = if (arguments.len > 1) arguments[1..] else &.{};
    for (flags) |argument| {
        if (startsWith(u8, argument, "--frames=")) {
            options.frame_limit = parseInt(u64, argument["--frames=".len..], 10) catch 0;
        } else if (startsWith(u8, argument, "--gpu=")) {
            options.gpu_choice = argument["--gpu=".len..];
        }
    }
    if (options.gpu_choice == null) {
        options.gpu_choice = environment.get("ZIMR_GPU");
    }
    if (environment.get("ZIMR_VK_VALIDATE")) |setting| {
        options.validate = !eql(u8, setting, "0");
    }
    return options;
}

// ---- Instance, device, queue ----

fn hasInstanceLayer(hello: *Hello, name: [*:0]const u8) HelloError!bool {
    var count: u32 = 0;
    try vk.check(hello.global.enumerateInstanceLayerProperties(&count, null));
    const layers: []vk.LayerProperties = try hello.gpa.alloc(vk.LayerProperties, count);
    defer hello.gpa.free(layers);
    try vk.check(hello.global.enumerateInstanceLayerProperties(&count, layers.ptr));
    for (layers[0..count]) |layer| {
        if (eql(u8, vk.fixedName(&layer.layer_name), span(name))) {
            return true;
        }
    }
    return false;
}

fn hasInstanceExtension(hello: *Hello, name: [*:0]const u8) HelloError!bool {
    var count: u32 = 0;
    try vk.check(hello.global.enumerateInstanceExtensionProperties(null, &count, null));
    const extensions: []vk.ExtensionProperties = try hello.gpa.alloc(vk.ExtensionProperties, count);
    defer hello.gpa.free(extensions);
    try vk.check(hello.global.enumerateInstanceExtensionProperties(null, &count, extensions.ptr));
    for (extensions[0..count]) |extension| {
        if (eql(u8, vk.fixedName(&extension.extension_name), span(name))) {
            return true;
        }
    }
    return false;
}

/// The validation layer's messages: printed, and counted for the exit code.
fn debugMessage(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: *const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(vk.call_conv) vk.Bool32 {
    _ = message_types;
    const counts: *MessageCounts = @ptrCast(@alignCast(user_data orelse return vk.bool_false));
    const is_error: bool = message_severity.@"error";
    if (is_error) {
        counts.errors += 1;
    } else {
        counts.warnings += 1;
    }
    const text: [*:0]const u8 = callback_data.p_message orelse "(no message)";
    if (is_error) {
        log.err("validation: {s}", .{text});
    } else {
        log.warn("validation: {s}", .{text});
    }
    return vk.bool_false;
}

fn createInstance(
    hello: *Hello,
    get_instance_proc_address: vk.PfnGetInstanceProcAddr,
    options: Options,
) HelloError!void {
    var version: u32 = 0;
    try vk.check(hello.global.enumerateInstanceVersion(&version));
    log.info("Vulkan loader {d}.{d}", .{ vk.apiVersionMajor(version), vk.apiVersionMinor(version) });
    if (version < vk.api_version_1_3) {
        return HelloError.VulkanTooOld;
    }

    // The validation layer, when installed and wanted, and the debug utilities that carry its messages.
    const validation_available: bool = try hasInstanceLayer(hello, vk.khronos_validation_layer_name);
    const debug_utils_available: bool = try hasInstanceExtension(hello, vk.ext_debug_utils_extension_name);
    const validate: bool = options.validate and validation_available and debug_utils_available;
    if (!validation_available) {
        log.info("the validation layer is not installed (the LunarG Vulkan SDK provides it)", .{});
    }
    const layers = [_][*:0]const u8{vk.khronos_validation_layer_name};
    const extensions = [_][*:0]const u8{
        vk.khr_surface_extension_name,
        vk.khr_win32_surface_extension_name,
        vk.ext_debug_utils_extension_name,
    };
    const extension_count: u32 = if (validate) 3 else 2;

    const application_info: vk.ApplicationInfo = .{
        .p_application_name = "vk_hello",
        .p_engine_name = "zimr",
        .api_version = vk.api_version_1_3,
    };
    // The messenger's description also goes in the instance's chain, so instance creation itself is validated.
    const messenger_info: vk.DebugUtilsMessengerCreateInfoEXT = .{
        .message_severity = .{ .warning = true, .@"error" = true },
        .message_type = .{ .general = true, .validation = true, .performance = true },
        .pfn_user_callback = @ptrCast(&debugMessage),
        .p_user_data = &hello.counts,
    };
    const instance_info: vk.InstanceCreateInfo = .{
        .p_next = if (validate) &messenger_info else null,
        .p_application_info = &application_info,
        .enabled_layer_count = if (validate) 1 else 0,
        .pp_enabled_layer_names = &layers,
        .enabled_extension_count = extension_count,
        .pp_enabled_extension_names = &extensions,
    };
    try vk.check(hello.global.createInstance(&instance_info, null, &hello.instance));
    hello.instance_dispatch = try vk.loadInstanceDispatch(get_instance_proc_address, hello.instance);
    hello.surface_dispatch = try vk.loadSurfaceDispatch(get_instance_proc_address, hello.instance);
    if (validate) {
        const create_messenger: vk.PfnCreateDebugUtilsMessengerEXT =
            hello.instance_dispatch.createDebugUtilsMessengerEXT orelse return;
        try vk.check(create_messenger(hello.instance, &messenger_info, null, &hello.messenger));
        log.info("validation layer on", .{});
    }
}

fn typeRank(device_type: vk.PhysicalDeviceType) u32 {
    return switch (device_type) {
        .discrete_gpu => 3,
        .integrated_gpu => 2,
        .virtual_gpu => 1,
        else => 0,
    };
}

fn hasSwapchainExtension(hello: *Hello, physical_device: vk.PhysicalDevice) HelloError!bool {
    var count: u32 = 0;
    try vk.check(hello.instance_dispatch.enumerateDeviceExtensionProperties(physical_device, null, &count, null));
    const extensions: []vk.ExtensionProperties = try hello.gpa.alloc(vk.ExtensionProperties, count);
    defer hello.gpa.free(extensions);
    try vk.check(hello.instance_dispatch.enumerateDeviceExtensionProperties(
        physical_device,
        null,
        &count,
        extensions.ptr,
    ));
    for (extensions[0..count]) |extension| {
        if (eql(u8, vk.fixedName(&extension.extension_name), span(vk.khr_swapchain_extension_name))) {
            return true;
        }
    }
    return false;
}

/// A queue family that renders, computes and presents to the window - if the GPU has one and also has Vulkan 1.3,
/// the swapchain extension, and the three features the host requires.
fn suitableQueueFamily(
    hello: *Hello,
    physical_device: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
) HelloError!?u32 {
    if (properties.api_version < vk.api_version_1_3) {
        return null;
    }
    var vulkan_13: vk.PhysicalDeviceVulkan13Features = .{};
    var vulkan_12: vk.PhysicalDeviceVulkan12Features = .{ .p_next = &vulkan_13 };
    var features: vk.PhysicalDeviceFeatures2 = .{ .p_next = &vulkan_12 };
    hello.instance_dispatch.getPhysicalDeviceFeatures2(physical_device, &features);
    const has_features: bool = vulkan_13.dynamic_rendering == vk.bool_true and
        vulkan_13.synchronization_2 == vk.bool_true and vulkan_12.timeline_semaphore == vk.bool_true;
    if (!has_features or !try hasSwapchainExtension(hello, physical_device)) {
        return null;
    }
    var family_count: u32 = 0;
    hello.instance_dispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);
    const families: []vk.QueueFamilyProperties = try hello.gpa.alloc(vk.QueueFamilyProperties, family_count);
    defer hello.gpa.free(families);
    hello.instance_dispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);
    for (families[0..family_count], 0..) |family, index| {
        if (!family.queue_flags.graphics or !family.queue_flags.compute) {
            continue;
        }
        // On a laptop with two GPUs, the one that does not drive the display may not present to it: ask.
        var presents: vk.Bool32 = vk.bool_false;
        const family_index: u32 = @intCast(index);
        try vk.check(hello.surface_dispatch.getPhysicalDeviceSurfaceSupportKHR(
            physical_device,
            family_index,
            hello.surface,
            &presents,
        ));
        if (presents == vk.bool_true) {
            return family_index;
        }
    }
    return null;
}

/// Every GPU that can run the host, listed; then the requested one, or the best by type (discrete first).
fn chooseGpu(hello: *Hello, choice: ?[]const u8) HelloError!Candidate {
    var count: u32 = 0;
    try vk.check(hello.instance_dispatch.enumeratePhysicalDevices(hello.instance, &count, null));
    const physical_devices: []vk.PhysicalDevice = try hello.gpa.alloc(vk.PhysicalDevice, count);
    defer hello.gpa.free(physical_devices);
    try vk.check(hello.instance_dispatch.enumeratePhysicalDevices(hello.instance, &count, physical_devices.ptr));

    var best: ?Candidate = null;
    var requested: ?Candidate = null;
    for (physical_devices[0..count], 0..) |physical_device, index| {
        var properties: vk.PhysicalDeviceProperties = .{};
        hello.instance_dispatch.getPhysicalDeviceProperties(physical_device, &properties);
        const name: []const u8 = vk.fixedName(&properties.device_name);
        const queue_family: ?u32 = try suitableQueueFamily(hello, physical_device, properties);
        log.info("GPU {d}: {s} ({s}, Vulkan {d}.{d}){s}", .{
            index,
            name,
            @tagName(properties.device_type),
            vk.apiVersionMajor(properties.api_version),
            vk.apiVersionMinor(properties.api_version),
            if (queue_family == null) " - cannot run the host" else "",
        });
        const family: u32 = queue_family orelse continue;
        const candidate: Candidate = .{
            .physical_device = physical_device,
            .name = properties.device_name,
            .device_type = properties.device_type,
            .queue_family = family,
        };
        if (choice) |wanted| {
            const index_wanted: ?usize = parseInt(usize, wanted, 10) catch null;
            const matches_index: bool = index_wanted != null and index_wanted.? == index;
            if (matches_index or indexOf(u8, name, wanted) != null) {
                requested = candidate;
            }
        }
        if (best == null or typeRank(candidate.device_type) > typeRank(best.?.device_type)) {
            best = candidate;
        }
    }
    if (choice != null and requested == null) {
        return HelloError.RequestedGpuNotFound;
    }
    const chosen: Candidate = requested orelse best orelse return HelloError.NoSuitableGpu;
    log.info("using {s}", .{vk.fixedName(&chosen.name)});
    return chosen;
}

fn createDevice(hello: *Hello) HelloError!void {
    const priority: f32 = 1.0;
    const queue_info: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = hello.chosen.queue_family,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priority),
    };
    // The three features the host stands on, enabled explicitly (a feature that is only checked is not on).
    var vulkan_13: vk.PhysicalDeviceVulkan13Features = .{
        .dynamic_rendering = vk.bool_true,
        .synchronization_2 = vk.bool_true,
    };
    var vulkan_12: vk.PhysicalDeviceVulkan12Features = .{ .p_next = &vulkan_13, .timeline_semaphore = vk.bool_true };
    const features: vk.PhysicalDeviceFeatures2 = .{ .p_next = &vulkan_12 };
    const extensions = [_][*:0]const u8{vk.khr_swapchain_extension_name};
    const device_info: vk.DeviceCreateInfo = .{
        .p_next = &features,
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&queue_info),
        .enabled_extension_count = 1,
        .pp_enabled_extension_names = &extensions,
    };
    const physical_device: vk.PhysicalDevice = hello.chosen.physical_device;
    try vk.check(hello.instance_dispatch.createDevice(physical_device, &device_info, null, &hello.device));
    hello.device_dispatch = try vk.loadDeviceDispatch(hello.instance_dispatch.getDeviceProcAddr, hello.device);
    hello.swapchain_dispatch = try vk.loadSwapchainDispatch(hello.instance_dispatch.getDeviceProcAddr, hello.device);
    hello.device_dispatch.getDeviceQueue(hello.device, hello.chosen.queue_family, 0, &hello.queue);
}

fn createBinarySemaphore(hello: *Hello) HelloError!vk.Semaphore {
    const semaphore_info: vk.SemaphoreCreateInfo = .{};
    var semaphore: vk.Semaphore = .null_handle;
    try vk.check(hello.device_dispatch.createSemaphore(hello.device, &semaphore_info, null, &semaphore));
    return semaphore;
}

fn createFrameObjects(hello: *Hello) HelloError!void {
    const pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = hello.chosen.queue_family,
    };
    try vk.check(hello.device_dispatch.createCommandPool(hello.device, &pool_info, null, &hello.command_pool));
    const buffers_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = hello.command_pool,
        .level = .primary,
        .command_buffer_count = frames_in_flight,
    };
    try vk.check(hello.device_dispatch.allocateCommandBuffers(hello.device, &buffers_info, &hello.command_buffers));
    for (&hello.acquire_semaphores) |*semaphore| {
        semaphore.* = try createBinarySemaphore(hello);
    }
    const timeline_type: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = .timeline, .initial_value = 0 };
    const timeline_info: vk.SemaphoreCreateInfo = .{ .p_next = &timeline_type };
    try vk.check(hello.device_dispatch.createSemaphore(hello.device, &timeline_info, null, &hello.timeline));
}

// ---- The swapchain ----

/// A swapchain for the window's current size, handing over from `old` (which the caller then destroys).
fn createSwapchain(hello: *Hello, old: vk.SwapchainKHR) HelloError!void {
    const surface_dispatch: *const vk.SurfaceDispatch = &hello.surface_dispatch;
    const physical_device: vk.PhysicalDevice = hello.chosen.physical_device;
    var capabilities: vk.SurfaceCapabilitiesKHR = .{};
    try vk.check(surface_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(
        physical_device,
        hello.surface,
        &capabilities,
    ));

    var format_count: u32 = 0;
    try vk.check(surface_dispatch.getPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        hello.surface,
        &format_count,
        null,
    ));
    const formats: []vk.SurfaceFormatKHR = try hello.gpa.alloc(vk.SurfaceFormatKHR, format_count);
    defer hello.gpa.free(formats);
    try vk.check(surface_dispatch.getPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        hello.surface,
        &format_count,
        formats.ptr,
    ));
    // RGBA8 UNORM, what the browser's canvas is configured with; BGRA8 UNORM when a surface lacks it.
    var chosen_format: ?vk.SurfaceFormatKHR = null;
    for ([_]vk.Format{ .r8g8b8a8_unorm, .b8g8r8a8_unorm }) |wanted| {
        for (formats[0..format_count]) |format| {
            if (chosen_format == null and format.format == wanted and format.color_space == .srgb_nonlinear_khr) {
                chosen_format = format;
            }
        }
    }
    const surface_format: vk.SurfaceFormatKHR = chosen_format orelse return HelloError.NoSurfaceFormat;
    if (old == .null_handle) {
        log.info("surface offers {d} formats; using {s}, FIFO present", .{
            format_count,
            @tagName(surface_format.format),
        });
    }

    // The surface's own size when it states one; otherwise the window's, within the surface's limits.
    var extent: vk.Extent2D = capabilities.current_extent;
    if (extent.width == 0xffff_ffff) {
        extent = .{
            .width = clamp(
                hello.window.client_width,
                capabilities.min_image_extent.width,
                capabilities.max_image_extent.width,
            ),
            .height = clamp(
                hello.window.client_height,
                capabilities.min_image_extent.height,
                capabilities.max_image_extent.height,
            ),
        };
    }
    if (extent.width == 0 or extent.height == 0) {
        // A zero-sized surface (a window between states) cannot have a swapchain: none until the size returns.
        hello.swapchain = .{};
        return;
    }
    var image_count: u32 = capabilities.min_image_count + 1;
    if (capabilities.max_image_count != 0) {
        image_count = @min(image_count, capabilities.max_image_count);
    }
    const swapchain_info: vk.SwapchainCreateInfoKHR = .{
        .surface = hello.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment = true, .transfer_dst = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = capabilities.current_transform,
        .composite_alpha = .{ .@"opaque" = true },
        .present_mode = .fifo_khr,
        .clipped = vk.bool_true,
        .old_swapchain = old,
    };
    var swapchain: Swapchain = .{ .format = surface_format.format, .extent = extent };
    try vk.check(hello.swapchain_dispatch.createSwapchainKHR(hello.device, &swapchain_info, null, &swapchain.handle));

    var count: u32 = 0;
    try vk.check(hello.swapchain_dispatch.getSwapchainImagesKHR(hello.device, swapchain.handle, &count, null));
    swapchain.images = try hello.gpa.alloc(vk.Image, count);
    try vk.check(hello.swapchain_dispatch.getSwapchainImagesKHR(
        hello.device,
        swapchain.handle,
        &count,
        swapchain.images.ptr,
    ));
    swapchain.views = try hello.gpa.alloc(vk.ImageView, count);
    swapchain.present_semaphores = try hello.gpa.alloc(vk.Semaphore, count);
    for (swapchain.images, swapchain.views, swapchain.present_semaphores) |image, *view, *semaphore| {
        const view_info: vk.ImageViewCreateInfo = .{
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .subresource_range = .{ .aspect_mask = .{ .color = true }, .level_count = 1, .layer_count = 1 },
        };
        try vk.check(hello.device_dispatch.createImageView(hello.device, &view_info, null, view));
        semaphore.* = try createBinarySemaphore(hello);
    }
    hello.swapchain = swapchain;
}

/// Destroys what was made per image (not the swapchain handle: a rebuild hands it over first).
fn destroySwapchainImages(hello: *Hello) void {
    for (hello.swapchain.views) |view| {
        hello.device_dispatch.destroyImageView(hello.device, view, null);
    }
    for (hello.swapchain.present_semaphores) |semaphore| {
        hello.device_dispatch.destroySemaphore(hello.device, semaphore, null);
    }
    hello.gpa.free(hello.swapchain.views);
    hello.gpa.free(hello.swapchain.present_semaphores);
    hello.gpa.free(hello.swapchain.images);
    hello.swapchain.views = &.{};
    hello.swapchain.present_semaphores = &.{};
    hello.swapchain.images = &.{};
}

fn rebuildSwapchain(hello: *Hello) HelloError!void {
    try vk.check(hello.device_dispatch.deviceWaitIdle(hello.device));
    const old: vk.SwapchainKHR = hello.swapchain.handle;
    destroySwapchainImages(hello);
    try createSwapchain(hello, old);
    if (old != .null_handle) {
        hello.swapchain_dispatch.destroySwapchainKHR(hello.device, old, null);
    }
    hello.swapchain_dirty = false;
    hello.rebuilds += 1;
}

// ---- The frame ----

fn waitTimeline(hello: *Hello, value: u64) HelloError!void {
    const semaphores = [_]vk.Semaphore{hello.timeline};
    const values = [_]u64{value};
    const wait_info: vk.SemaphoreWaitInfo = .{ .semaphore_count = 1, .p_semaphores = &semaphores, .p_values = &values };
    try vk.check(hello.device_dispatch.waitSemaphores(hello.device, &wait_info, no_timeout));
}

/// One full memory barrier that also moves `image` from layout `from` to layout `to`.
fn imageBarrier(
    hello: *Hello,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
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
        .subresource_range = .{ .aspect_mask = .{ .color = true }, .level_count = 1, .layer_count = 1 },
    };
    const dependency: vk.DependencyInfo = .{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    };
    hello.device_dispatch.cmdPipelineBarrier2(command_buffer, &dependency);
}

fn drawFrame(hello: *Hello, seconds: f32) HelloError!void {
    const dispatch: *const vk.DeviceDispatch = &hello.device_dispatch;
    const slot: usize = @intCast(hello.frame_index % frames_in_flight);
    // At most `frames_in_flight` frames ahead: this slot's previous submit must be done before its objects are reused.
    try waitTimeline(hello, hello.slot_serials[slot]);

    var image_index: u32 = 0;
    const acquired: vk.Result = hello.swapchain_dispatch.acquireNextImageKHR(
        hello.device,
        hello.swapchain.handle,
        no_timeout,
        hello.acquire_semaphores[slot],
        .null_handle,
        &image_index,
    );
    if (acquired == .error_out_of_date_khr) {
        // Nothing was acquired and the semaphore was not signaled: rebuild and try next frame.
        hello.swapchain_dirty = true;
        return;
    }
    try vk.check(acquired);
    if (acquired == .suboptimal_khr) {
        // An image WAS acquired: render and present it, then rebuild.
        hello.swapchain_dirty = true;
    }
    const image: vk.Image = hello.swapchain.images[image_index];

    const command_buffer: vk.CommandBuffer = hello.command_buffers[slot];
    try vk.check(dispatch.resetCommandBuffer(command_buffer, .{}));
    const begin_info: vk.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit = true } };
    try vk.check(dispatch.beginCommandBuffer(command_buffer, &begin_info));
    imageBarrier(hello, command_buffer, image, .undefined, .general);
    // A slowly cycling color: three sine waves a third of a turn apart.
    const third_turn: f32 = 2.0 * pi / 3.0;
    const color_attachment: vk.RenderingAttachmentInfo = .{
        .image_view = hello.swapchain.views[image_index],
        .image_layout = .general,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{
            0.5 + 0.4 * @sin(seconds),
            0.5 + 0.4 * @sin(seconds + third_turn),
            0.5 + 0.4 * @sin(seconds + 2.0 * third_turn),
            1.0,
        } } },
    };
    const rendering_info: vk.RenderingInfo = .{
        .render_area = .{ .extent = hello.swapchain.extent },
        .layer_count = 1,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment),
    };
    dispatch.cmdBeginRendering(command_buffer, &rendering_info);
    dispatch.cmdEndRendering(command_buffer);
    imageBarrier(hello, command_buffer, image, .general, .present_src_khr);
    try vk.check(dispatch.endCommandBuffer(command_buffer));

    // Wait for the acquire; signal the image's present semaphore and the timeline's next number.
    hello.submitted += 1;
    const wait_semaphores = [_]vk.SemaphoreSubmitInfo{.{
        .semaphore = hello.acquire_semaphores[slot],
        .stage_mask = .{ .all_commands = true },
    }};
    const signal_semaphores = [_]vk.SemaphoreSubmitInfo{
        .{
            .semaphore = hello.swapchain.present_semaphores[image_index],
            .stage_mask = .{ .all_commands = true },
        },
        .{ .semaphore = hello.timeline, .value = hello.submitted, .stage_mask = .{ .all_commands = true } },
    };
    const command_buffers = [_]vk.CommandBufferSubmitInfo{.{ .command_buffer = command_buffer }};
    const submit_info: vk.SubmitInfo2 = .{
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = &wait_semaphores,
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &command_buffers,
        .signal_semaphore_info_count = 2,
        .p_signal_semaphore_infos = &signal_semaphores,
    };
    try vk.check(dispatch.queueSubmit2(hello.queue, 1, @ptrCast(&submit_info), .null_handle));
    hello.slot_serials[slot] = hello.submitted;

    const present_wait = [_]vk.Semaphore{hello.swapchain.present_semaphores[image_index]};
    const swapchains = [_]vk.SwapchainKHR{hello.swapchain.handle};
    const image_indices = [_]u32{image_index};
    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &present_wait,
        .swapchain_count = 1,
        .p_swapchains = &swapchains,
        .p_image_indices = &image_indices,
    };
    const presented: vk.Result = hello.swapchain_dispatch.queuePresentKHR(hello.queue, &present_info);
    if (presented == .error_out_of_date_khr or presented == .suboptimal_khr) {
        hello.swapchain_dirty = true;
    } else {
        try vk.check(presented);
    }
    hello.frame_index += 1;
}

// ---- Teardown ----

fn deinitHello(hello: *Hello) void {
    if (hello.device != .null_handle) {
        _ = hello.device_dispatch.deviceWaitIdle(hello.device);
        destroySwapchainImages(hello);
        if (hello.swapchain.handle != .null_handle) {
            hello.swapchain_dispatch.destroySwapchainKHR(hello.device, hello.swapchain.handle, null);
        }
        for (hello.acquire_semaphores) |semaphore| {
            if (semaphore != .null_handle) {
                hello.device_dispatch.destroySemaphore(hello.device, semaphore, null);
            }
        }
        if (hello.timeline != .null_handle) {
            hello.device_dispatch.destroySemaphore(hello.device, hello.timeline, null);
        }
        if (hello.command_pool != .null_handle) {
            hello.device_dispatch.destroyCommandPool(hello.device, hello.command_pool, null);
        }
        hello.device_dispatch.destroyDevice(hello.device, null);
    }
    if (hello.instance != .null_handle) {
        if (hello.surface != .null_handle) {
            hello.surface_dispatch.destroySurfaceKHR(hello.instance, hello.surface, null);
        }
        if (hello.messenger != .null_handle) {
            if (hello.instance_dispatch.destroyDebugUtilsMessengerEXT) |destroy_messenger| {
                destroy_messenger(hello.instance, hello.messenger, null);
            }
        }
        hello.instance_dispatch.destroyInstance(hello.instance, null);
    }
}

// ---- The program ----

fn initHello(
    hello: *Hello,
    gpa: Allocator,
    window: *win32.Window,
    library: win32.VulkanLibrary,
    options: Options,
) HelloError!void {
    const get_instance_proc_address: vk.PfnGetInstanceProcAddr = @ptrCast(library.get_instance_proc_address);
    hello.* = .{
        .gpa = gpa,
        .window = window,
        .counts = .{},
        .global = try vk.loadGlobalDispatch(get_instance_proc_address),
        .instance = .null_handle,
        .instance_dispatch = undefined,
        .surface_dispatch = undefined,
        .messenger = .null_handle,
        .surface = .null_handle,
        .chosen = undefined,
        .device = .null_handle,
        .device_dispatch = undefined,
        .swapchain_dispatch = undefined,
        .queue = .null_handle,
        .command_pool = .null_handle,
        .command_buffers = @splat(.null_handle),
        .acquire_semaphores = @splat(.null_handle),
        .timeline = .null_handle,
        .submitted = 0,
        .slot_serials = @splat(0),
        .swapchain = .{},
        .swapchain_dirty = false,
        .frame_index = 0,
        .rebuilds = 0,
    };
    try createInstance(hello, get_instance_proc_address, options);
    var surface_info: vk.Win32SurfaceCreateInfoKHR = .{ .hinstance = window.module, .hwnd = window.handle };
    try vk.check(hello.surface_dispatch.createWin32SurfaceKHR(hello.instance, &surface_info, null, &hello.surface));
    hello.chosen = try chooseGpu(hello, options.gpu_choice);
    try createDevice(hello);
    try createFrameObjects(hello);
    try createSwapchain(hello, .null_handle);
}

pub fn main(init: std.process.Init) !u8 {
    const arguments: []const [:0]const u8 = try init.minimal.args.toSlice(init.arena.allocator());
    const options: Options = readOptions(arguments, init.environ_map);

    var window: win32.Window = undefined;
    try window.open(.{ .title = "zimr - Vulkan hello", .logical_width = 960, .logical_height = 540 });
    defer window.close();
    const library: win32.VulkanLibrary = try win32.openVulkanLibrary();
    defer win32.closeVulkanLibrary(library);

    var hello: Hello = undefined;
    try initHello(&hello, init.gpa, &window, library, options);
    defer deinitHello(&hello);

    const start_ms: f64 = win32.monotonicMilliseconds();
    while (!window.close_requested) {
        window.pump();
        if (window.close_requested) {
            break;
        }
        if (window.minimized) {
            // Like a hidden browser tab: no frames until the window returns.
            win32.Sleep(16);
            continue;
        }
        if (window.size_changed or hello.swapchain_dirty) {
            window.size_changed = false;
            try rebuildSwapchain(&hello);
        }
        if (hello.swapchain.handle == .null_handle) {
            // The surface was zero-sized at the last rebuild: wait for the next size change.
            win32.Sleep(16);
            continue;
        }
        const seconds: f64 = (win32.monotonicMilliseconds() - start_ms) / 1000.0;
        try drawFrame(&hello, @floatCast(seconds));
        if (options.frame_limit != 0 and hello.frame_index >= options.frame_limit) {
            break;
        }
    }
    const elapsed_ms: f64 = win32.monotonicMilliseconds() - start_ms;
    const frames_float: f64 = @floatFromInt(@max(hello.frame_index, 1));
    log.info("{d} frames in {d:.1} s ({d:.2} ms per frame), {d} swapchain rebuilds", .{
        hello.frame_index, elapsed_ms / 1000.0, elapsed_ms / frames_float, hello.rebuilds,
    });
    log.info("validation: {d} errors, {d} warnings{s}", .{
        hello.counts.errors,
        hello.counts.warnings,
        if (hello.messenger == .null_handle) " (layer not active)" else "",
    });
    return if (hello.counts.errors == 0) 0 else 1;
}
