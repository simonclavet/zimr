//! THE SHADER PROBE - every engine shader, exactly as the native host would load it, handed to Vulkan with the
//! Khronos validation layer watching.
//!
//! The native host never loads the compiler's SPIR-V as is: `spv_vulkan.legalize` first declares `DepthReplacing`
//! where a fragment shader writes depth, marks read-only vertex-stage storage buffers `NonWritable`, and drops the
//! pointer strides Vulkan rejects. Whether the result is VALID Vulkan SPIR-V is a question only Vulkan's own
//! validator answers completely: the validation layer runs the SPIR-V validator on every module at
//! `vkCreateShaderModule`. This probe asks it about every engine shader, so a module the layer would reject is found
//! at build time, on any machine with a Vulkan driver - a GPU, or Mesa's software driver (lavapipe) where there is
//! none.
//!
//! For each shader, given as `name=path` arguments, the probe
//!
//!     1. reads the compiler's SPIR-V and legalizes it, as the host does when the engine creates the module;
//!     2. runs `spv_vulkan.check` on the legalized words - the rules zimr knows, which must all pass;
//!     3. creates a Vulkan shader module from the legalized words, counting what the validation layer reports.
//!
//! It prints the device it used, every finding with its shader's name, and a summary; any finding fails the run.
//! The device is created with the features the native host enables, so the layer judges each module against the
//! same device the host would create.

const builtin = @import("builtin");
const std = @import("std");
const spv_vulkan = @import("spv_vulkan");
const vk = @import("vk");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const indexOfScalar = std.mem.indexOfScalar;
const print = std.debug.print;
const sliceAsBytes = std.mem.sliceAsBytes;

// ---- The commands the probe uses ----

/// The instance commands the probe calls - a small table of its own, loaded like the host's, so the probe runs where
/// the window-system commands do not exist (no surface, no swapchain).
const InstanceCommands = struct {
    destroyInstance: vk.PfnDestroyInstance,
    enumeratePhysicalDevices: vk.PfnEnumeratePhysicalDevices,
    getPhysicalDeviceProperties: vk.PfnGetPhysicalDeviceProperties,
    getPhysicalDeviceQueueFamilyProperties: vk.PfnGetPhysicalDeviceQueueFamilyProperties,
    getPhysicalDeviceFeatures2: vk.PfnGetPhysicalDeviceFeatures2,
    createDevice: vk.PfnCreateDevice,
    getDeviceProcAddr: vk.PfnGetDeviceProcAddr,
    createDebugUtilsMessengerEXT: ?vk.PfnCreateDebugUtilsMessengerEXT,
    destroyDebugUtilsMessengerEXT: ?vk.PfnDestroyDebugUtilsMessengerEXT,
};

const DeviceCommands = struct {
    destroyDevice: vk.PfnDestroyDevice,
    createShaderModule: vk.PfnCreateShaderModule,
    destroyShaderModule: vk.PfnDestroyShaderModule,
};

// ---- What the validation layer reports ----

/// The validation layer's reports while one shader is being created: the messenger's callback adds to these.
const Findings = struct {
    errors: u32 = 0,
    warnings: u32 = 0,
    /// The shader being created, so each printed message names it.
    shader_name: []const u8 = "(before the first shader)",
};

/// The debug messenger's callback: prints the message under the current shader's name and counts it.
fn reportMessage(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: *const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(vk.call_conv) vk.Bool32 {
    _ = message_types;
    const findings: *Findings = @ptrCast(@alignCast(user_data.?));
    const is_error: bool = severity.@"error";
    if (is_error) {
        findings.errors += 1;
    } else {
        findings.warnings += 1;
    }
    const message: [*:0]const u8 = callback_data.p_message orelse "(no message)";
    print("  [{s}] {s}: {s}\n", .{ if (is_error) "ERROR" else "warning", findings.shader_name, message });
    return vk.bool_false;
}

// ---- Bring-up ----

/// The loader, the instance with the validation layer and its messenger, and a device with the host's features.
const Probe = struct {
    library: std.DynLib,
    global: vk.GlobalDispatch,
    instance: vk.Instance,
    instance_commands: InstanceCommands,
    messenger: vk.DebugUtilsMessengerEXT,
    device: vk.Device,
    device_commands: DeviceCommands,
    findings: *Findings,

    const BringUpError = error{
        NoVulkanLoader,
        NoValidationLayer,
        NoDevice,
        NoQueueFamily,
    } || vk.LoadError || vk.ResultError || Allocator.Error || std.DynLib.Error;

    fn open(gpa: Allocator, findings: *Findings) BringUpError!Probe {
        const library_name: []const u8 = if (builtin.os.tag == .windows) "vulkan-1.dll" else "libvulkan.so.1";
        var library: std.DynLib = std.DynLib.open(library_name) catch return error.NoVulkanLoader;
        errdefer library.close();
        const get_instance_proc_address: vk.PfnGetInstanceProcAddr =
            library.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.NoVulkanLoader;
        const global: vk.GlobalDispatch = try vk.loadGlobalDispatch(get_instance_proc_address);
        if (!try hasValidationLayer(gpa, global)) {
            return error.NoValidationLayer;
        }

        const layers = [_][*:0]const u8{vk.khronos_validation_layer_name};
        const extensions = [_][*:0]const u8{vk.ext_debug_utils_extension_name};
        const application_info: vk.ApplicationInfo = .{
            .p_application_name = "zimr shader probe",
            .api_version = vk.api_version_1_3,
        };
        const messenger_info: vk.DebugUtilsMessengerCreateInfoEXT = .{
            .message_severity = .{ .warning = true, .@"error" = true },
            .message_type = .{ .general = true, .validation = true },
            .pfn_user_callback = @ptrCast(&reportMessage),
            .p_user_data = findings,
        };
        const instance_info: vk.InstanceCreateInfo = .{
            .p_next = &messenger_info,
            .p_application_info = &application_info,
            .enabled_layer_count = layers.len,
            .pp_enabled_layer_names = &layers,
            .enabled_extension_count = extensions.len,
            .pp_enabled_extension_names = &extensions,
        };
        var instance: vk.Instance = .null_handle;
        try vk.check(global.createInstance(&instance_info, null, &instance));
        const instance_commands: InstanceCommands =
            try vk.loadDispatch(InstanceCommands, vk.Instance, get_instance_proc_address, instance);
        errdefer instance_commands.destroyInstance(instance, null);
        var messenger: vk.DebugUtilsMessengerEXT = .null_handle;
        if (instance_commands.createDebugUtilsMessengerEXT) |create_messenger| {
            try vk.check(create_messenger(instance, &messenger_info, null, &messenger));
        }

        const physical_device: vk.PhysicalDevice = try choosePhysicalDevice(gpa, instance_commands, instance);
        const device: vk.Device = try createDevice(gpa, instance_commands, physical_device);
        const device_commands: DeviceCommands =
            try vk.loadDispatch(DeviceCommands, vk.Device, instance_commands.getDeviceProcAddr, device);
        return .{
            .library = library,
            .global = global,
            .instance = instance,
            .instance_commands = instance_commands,
            .messenger = messenger,
            .device = device,
            .device_commands = device_commands,
            .findings = findings,
        };
    }

    fn close(probe: *Probe) void {
        probe.device_commands.destroyDevice(probe.device, null);
        if (probe.instance_commands.destroyDebugUtilsMessengerEXT) |destroy_messenger| {
            destroy_messenger(probe.instance, probe.messenger, null);
        }
        probe.instance_commands.destroyInstance(probe.instance, null);
        probe.library.close();
    }

    fn hasValidationLayer(gpa: Allocator, global: vk.GlobalDispatch) BringUpError!bool {
        var count: u32 = 0;
        try vk.check(global.enumerateInstanceLayerProperties(&count, null));
        const layers: []vk.LayerProperties = try gpa.alloc(vk.LayerProperties, count);
        defer gpa.free(layers);
        try vk.check(global.enumerateInstanceLayerProperties(&count, layers.ptr));
        const wanted: []const u8 = std.mem.span(vk.khronos_validation_layer_name);
        for (layers[0..count]) |layer| {
            const name: []const u8 = std.mem.sliceTo(&layer.layer_name, 0);
            if (eql(u8, name, wanted)) {
                return true;
            }
        }
        return false;
    }

    /// The first device of the most capable type: discrete, then integrated, virtual, and the CPU (lavapipe).
    fn choosePhysicalDevice(
        gpa: Allocator,
        commands: InstanceCommands,
        instance: vk.Instance,
    ) BringUpError!vk.PhysicalDevice {
        var count: u32 = 0;
        try vk.check(commands.enumeratePhysicalDevices(instance, &count, null));
        if (count == 0) {
            return error.NoDevice;
        }
        const devices: []vk.PhysicalDevice = try gpa.alloc(vk.PhysicalDevice, count);
        defer gpa.free(devices);
        try vk.check(commands.enumeratePhysicalDevices(instance, &count, devices.ptr));
        const preference = [_]vk.PhysicalDeviceType{ .discrete_gpu, .integrated_gpu, .virtual_gpu, .cpu, .other };
        for (preference) |wanted_type| {
            for (devices[0..count]) |device| {
                var properties: vk.PhysicalDeviceProperties = .{};
                commands.getPhysicalDeviceProperties(device, &properties);
                if (properties.device_type == wanted_type) {
                    print("device: {s} ({s}, Vulkan {d}.{d})\n", .{
                        std.mem.sliceTo(&properties.device_name, 0),
                        @tagName(properties.device_type),
                        vk.apiVersionMajor(properties.api_version),
                        vk.apiVersionMinor(properties.api_version),
                    });
                    return device;
                }
            }
        }
        return error.NoDevice;
    }

    /// A device with one graphics queue and the features the native host enables (`wgpu_vulkan.zig`'s bring-up):
    /// dynamic rendering, synchronization2, timeline semaphores, robust buffer access, and vertex-stage stores when
    /// offered. The validation layer checks each module's capabilities against these.
    fn createDevice(
        gpa: Allocator,
        commands: InstanceCommands,
        physical_device: vk.PhysicalDevice,
    ) BringUpError!vk.Device {
        var family_count: u32 = 0;
        commands.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);
        const families: []vk.QueueFamilyProperties = try gpa.alloc(vk.QueueFamilyProperties, family_count);
        defer gpa.free(families);
        commands.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);
        const family_index: u32 = for (families[0..family_count], 0..) |family, index| {
            if (family.queue_flags.graphics) {
                break @intCast(index);
            }
        } else return error.NoQueueFamily;

        var supported: vk.PhysicalDeviceFeatures2 = .{};
        commands.getPhysicalDeviceFeatures2(physical_device, &supported);
        var vulkan_13: vk.PhysicalDeviceVulkan13Features = .{
            .dynamic_rendering = vk.bool_true,
            .synchronization_2 = vk.bool_true,
        };
        var vulkan_12: vk.PhysicalDeviceVulkan12Features = .{
            .p_next = &vulkan_13,
            .timeline_semaphore = vk.bool_true,
        };
        const features: vk.PhysicalDeviceFeatures2 = .{
            .p_next = &vulkan_12,
            .features = .{
                .robust_buffer_access = vk.bool_true,
                .vertex_pipeline_stores_and_atomics = supported.features.vertex_pipeline_stores_and_atomics,
            },
        };
        const priorities = [_]f32{1.0};
        const queue_info: vk.DeviceQueueCreateInfo = .{
            .queue_family_index = family_index,
            .queue_count = 1,
            .p_queue_priorities = &priorities,
        };
        const device_info: vk.DeviceCreateInfo = .{
            .p_next = &features,
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_info),
        };
        var device: vk.Device = .null_handle;
        try vk.check(commands.createDevice(physical_device, &device_info, null, &device));
        return device;
    }
};

// ---- Probing one shader ----

/// What went wrong with one shader, for the summary.
const Outcome = struct {
    name: []const u8,
    legalize_error: ?spv_vulkan.Error = null,
    check_violations: usize = 0,
    layer_errors: u32 = 0,
    layer_warnings: u32 = 0,

    fn failed(outcome: Outcome) bool {
        return outcome.legalize_error != null or outcome.check_violations > 0 or outcome.layer_errors > 0;
    }
};

fn probeShader(
    io: Io,
    gpa: Allocator,
    probe: *Probe,
    name: []const u8,
    path: []const u8,
) !Outcome {
    var outcome: Outcome = .{ .name = name };
    const cwd: Io.Dir = .cwd();
    const bytes: []u8 = try cwd.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    // SPIR-V is a sequence of 32-bit words; the file's bytes are copied into aligned words.
    const words: []u32 = try gpa.alloc(u32, bytes.len / 4);
    defer gpa.free(words);
    @memcpy(sliceAsBytes(words), bytes[0 .. words.len * 4]);

    const legal: []u32 = spv_vulkan.legalize(gpa, words) catch |err| {
        print("  [LEGALIZE] {s}: {s}\n", .{ name, @errorName(err) });
        outcome.legalize_error = err;
        return outcome;
    };
    defer gpa.free(legal);

    const violations: []spv_vulkan.Violation = try spv_vulkan.check(gpa, legal);
    defer gpa.free(violations);
    for (violations) |violation| {
        print("  [CHECK] {s}: {s} (id {d})\n", .{ name, @tagName(violation.kind), violation.id });
    }
    outcome.check_violations = violations.len;

    probe.findings.* = .{ .shader_name = name };
    const module_info: vk.ShaderModuleCreateInfo = .{ .code_size = legal.len * 4, .p_code = legal.ptr };
    var module: vk.ShaderModule = .null_handle;
    const created: vk.Result = probe.device_commands.createShaderModule(probe.device, &module_info, null, &module);
    if (created == .success) {
        probe.device_commands.destroyShaderModule(probe.device, module, null);
    } else {
        print("  [CREATE] {s}: vkCreateShaderModule returned {s}\n", .{ name, @tagName(created) });
        probe.findings.errors += 1;
    }
    outcome.layer_errors = probe.findings.errors;
    outcome.layer_warnings = probe.findings.warnings;
    return outcome;
}

// ---- The run ----

pub fn main(init: std.process.Init) !u8 {
    const gpa: Allocator = init.gpa;
    const arguments: []const [:0]const u8 = try init.minimal.args.toSlice(init.arena.allocator());

    var findings: Findings = .{};
    var probe: Probe = Probe.open(gpa, &findings) catch |err| {
        print("vk-shader-probe: cannot start: {s}\n", .{@errorName(err)});
        if (err == error.NoValidationLayer) {
            const hint: []const u8 = "the probe needs the Khronos validation layer";
            print("  {s} (the Vulkan SDK, or `vulkan-validationlayers`)\n", .{hint});
        }
        return 2;
    };
    defer probe.close();

    var outcomes: ArrayList(Outcome) = .empty;
    defer outcomes.deinit(gpa);
    for (arguments[1..]) |argument| {
        const separator: usize = indexOfScalar(u8, argument, '=') orelse {
            print("vk-shader-probe: argument `{s}` is not name=path\n", .{argument});
            return 2;
        };
        const name: []const u8 = argument[0..separator];
        const path: []const u8 = argument[separator + 1 ..];
        const outcome: Outcome = try probeShader(init.io, gpa, &probe, name, path);
        try outcomes.append(gpa, outcome);
    }

    var failures: usize = 0;
    var warnings: u32 = 0;
    for (outcomes.items) |outcome| {
        warnings += outcome.layer_warnings;
        if (outcome.failed()) {
            failures += 1;
        }
    }
    if (failures == 0) {
        print("vk-shader-probe: {d} shaders, every one valid for Vulkan ({d} warnings)\n", .{
            outcomes.items.len,
            warnings,
        });
        return 0;
    }
    print("vk-shader-probe: {d} of {d} shaders FAILED:\n", .{ failures, outcomes.items.len });
    for (outcomes.items) |outcome| {
        if (outcome.failed()) {
            print("  {s}: legalize {s}, {d} check violations, {d} layer errors\n", .{
                outcome.name,
                if (outcome.legalize_error) |err| @errorName(err) else "ok",
                outcome.check_violations,
                outcome.layer_errors,
            });
        }
    }
    return 1;
}
