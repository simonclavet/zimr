//! THE VULKAN BINDING GENERATOR - writes the generated part of `src/vk.zig` from the Vulkan registry.
//!
//! The registry, `vk.xml`, is the XML file the official C headers are generated from: every type, structure member,
//! command, parameter and enumerant of the API, with metadata the headers drop - which pointers are arrays and how
//! long, which are optional. zimr declares only the subset its native host calls, listed below, and this tool turns
//! that subset into Zig in three steps:
//!
//!     read      `codecs.xml` parses the registry into a tree
//!     model     the types, commands and enumerants are indexed by name, and every enumerant's value is computed
//!     render    the listed declarations become Zig, spliced between `vk.zig`'s hand-written parts
//!
//! Run it with `zig build vk-gen -Dvulkan-registry=path/to/vk.xml`, which rewrites `src/vk.zig`; then check the
//! result with `zig build vk-abi-check -Dvulkan-headers=...`. To declare one more command: add it to `command_levels`,
//! and any structure or enumeration it needs to `structures` or `enumerations`, then regenerate and check.
//!
//! Values come from the registry alone, as Vulkan defines them: an enumerant gives its value directly, or as a bit
//! position, or - when an extension adds it - as an offset within the block of numbers that extension owns. The
//! official headers stay an independent oracle: `zig build vk-abi-check` compares the result with them.

const std = @import("std");
const codecs = @import("codecs");

const xml = codecs.xml;
const Allocator = std.mem.Allocator;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const ArrayList = std.ArrayList;
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const endsWith = std.mem.endsWith;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const indexOfScalar = std.mem.indexOfScalar;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const sortSlice = std.mem.sort;
const startsWith = std.mem.startsWith;
const ArenaAllocator = std.heap.ArenaAllocator;
const isValidId = std.zig.isValidId;
const isPrimitive = std.zig.primitives.isPrimitive;

// ---- What zimr declares ----

/// An enumeration, by its Zig name, and the C names of the enumerants zimr uses.
const Enumeration = struct {
    name: []const u8,
    values: []const []const u8,
};

/// Which dispatch table loads a command: the levels of `vk.zig`'s tables.
const Level = enum { global, instance, surface, device, swapchain };

const CommandLevel = struct {
    level: Level,
    commands: []const []const u8,
};

/// A constant whose value is written here rather than read from the registry.
const SpecialConstant = struct {
    name: []const u8,
    zig_type: []const u8,
    value: []const u8,
    doc: []const u8,
};

/// The structures declared in full, in this order.
const structures = [_][]const u8{
    "ApplicationInfo",
    "InstanceCreateInfo",
    "LayerProperties",
    "ExtensionProperties",
    "Extent2D",
    "Extent3D",
    "Offset2D",
    "Offset3D",
    "Rect2D",
    "PhysicalDeviceLimits",
    "PhysicalDeviceSparseProperties",
    "PhysicalDeviceProperties",
    "QueueFamilyProperties",
    "PhysicalDeviceFeatures",
    "PhysicalDeviceFeatures2",
    "PhysicalDeviceVulkan12Features",
    "PhysicalDeviceVulkan13Features",
    "DeviceQueueCreateInfo",
    "DeviceCreateInfo",
    "SurfaceCapabilitiesKHR",
    "SurfaceFormatKHR",
    "SwapchainCreateInfoKHR",
    "PresentInfoKHR",
    "Win32SurfaceCreateInfoKHR",
    "ComponentMapping",
    "ImageSubresourceRange",
    "ImageViewCreateInfo",
    "SemaphoreCreateInfo",
    "SemaphoreTypeCreateInfo",
    "SemaphoreWaitInfo",
    "CommandPoolCreateInfo",
    "CommandBufferAllocateInfo",
    "CommandBufferBeginInfo",
    "SemaphoreSubmitInfo",
    "CommandBufferSubmitInfo",
    "SubmitInfo2",
    "MemoryBarrier2",
    "ImageMemoryBarrier2",
    "BufferMemoryBarrier2",
    "DependencyInfo",
    "ClearColorValue",
    "ClearDepthStencilValue",
    "ClearValue",
    "RenderingAttachmentInfo",
    "RenderingInfo",
    "DebugUtilsLabelEXT",
    "DebugUtilsObjectNameInfoEXT",
    "DebugUtilsMessengerCreateInfoEXT",
    "DebugUtilsMessengerCallbackDataEXT",
    "MemoryType",
    "MemoryHeap",
    "PhysicalDeviceMemoryProperties",
    "MemoryRequirements",
    "MemoryAllocateInfo",
    "BufferCreateInfo",
    "BufferCopy",
    "ImageSubresourceLayers",
    "ImageCreateInfo",
    "BufferImageCopy",
    "SamplerCreateInfo",
    "ShaderModuleCreateInfo",
    "DescriptorSetLayoutBinding",
    "DescriptorSetLayoutCreateInfo",
    "DescriptorPoolSize",
    "DescriptorPoolCreateInfo",
    "DescriptorSetAllocateInfo",
    "DescriptorBufferInfo",
    "DescriptorImageInfo",
    "WriteDescriptorSet",
    "CopyDescriptorSet",
    "PushConstantRange",
    "PipelineLayoutCreateInfo",
    "PipelineShaderStageCreateInfo",
    "VertexInputBindingDescription",
    "VertexInputAttributeDescription",
    "PipelineVertexInputStateCreateInfo",
    "PipelineInputAssemblyStateCreateInfo",
    "Viewport",
    "PipelineViewportStateCreateInfo",
    "PipelineRasterizationStateCreateInfo",
    "PipelineMultisampleStateCreateInfo",
    "StencilOpState",
    "PipelineDepthStencilStateCreateInfo",
    "PipelineColorBlendAttachmentState",
    "PipelineColorBlendStateCreateInfo",
    "PipelineDynamicStateCreateInfo",
    "PipelineRenderingCreateInfo",
    "GraphicsPipelineCreateInfo",
    "ComputePipelineCreateInfo",
};

/// Structures used only through pointers: declared opaque.
const opaque_structures = [_][]const u8{
    "AllocationCallbacks",
    "CommandBufferInheritanceInfo",
    "SpecializationInfo",
    "PipelineTessellationStateCreateInfo",
};

/// The enumerations, each with the enumerants zimr uses. `StructureType` lists none: its enumerants are the `sType`
/// values of the structures above, collected while they are rendered.
const enumerations = [_]Enumeration{
    .{ .name = "Result", .values = &.{
        "VK_SUCCESS",
        "VK_NOT_READY",
        "VK_TIMEOUT",
        "VK_EVENT_SET",
        "VK_EVENT_RESET",
        "VK_INCOMPLETE",
        "VK_SUBOPTIMAL_KHR",
        "VK_ERROR_OUT_OF_HOST_MEMORY",
        "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        "VK_ERROR_INITIALIZATION_FAILED",
        "VK_ERROR_DEVICE_LOST",
        "VK_ERROR_MEMORY_MAP_FAILED",
        "VK_ERROR_LAYER_NOT_PRESENT",
        "VK_ERROR_EXTENSION_NOT_PRESENT",
        "VK_ERROR_FEATURE_NOT_PRESENT",
        "VK_ERROR_INCOMPATIBLE_DRIVER",
        "VK_ERROR_TOO_MANY_OBJECTS",
        "VK_ERROR_FORMAT_NOT_SUPPORTED",
        "VK_ERROR_SURFACE_LOST_KHR",
        "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR",
        "VK_ERROR_OUT_OF_DATE_KHR",
        "VK_ERROR_VALIDATION_FAILED_EXT",
        "VK_ERROR_UNKNOWN",
        "VK_ERROR_FRAGMENTED_POOL",
        "VK_ERROR_OUT_OF_POOL_MEMORY",
    } },
    .{ .name = "Format", .values = &.{
        "VK_FORMAT_UNDEFINED",
        "VK_FORMAT_R8_UNORM",
        "VK_FORMAT_R8G8_UNORM",
        "VK_FORMAT_R8G8B8A8_UNORM",
        "VK_FORMAT_R8G8B8A8_SRGB",
        "VK_FORMAT_R8G8B8A8_UINT",
        "VK_FORMAT_B8G8R8A8_UNORM",
        "VK_FORMAT_B8G8R8A8_SRGB",
        "VK_FORMAT_A2B10G10R10_UNORM_PACK32",
        "VK_FORMAT_R16G16B16A16_SFLOAT",
        "VK_FORMAT_R32_UINT",
        "VK_FORMAT_R32_SFLOAT",
        "VK_FORMAT_R32G32_UINT",
        "VK_FORMAT_R32G32_SFLOAT",
        "VK_FORMAT_R32G32B32_SFLOAT",
        "VK_FORMAT_R32G32B32A32_SFLOAT",
        "VK_FORMAT_D16_UNORM",
        "VK_FORMAT_D32_SFLOAT",
    } },
    .{ .name = "ColorSpaceKHR", .values = &.{
        "VK_COLOR_SPACE_SRGB_NONLINEAR_KHR",
    } },
    .{ .name = "PresentModeKHR", .values = &.{
        "VK_PRESENT_MODE_IMMEDIATE_KHR",
        "VK_PRESENT_MODE_MAILBOX_KHR",
        "VK_PRESENT_MODE_FIFO_KHR",
        "VK_PRESENT_MODE_FIFO_RELAXED_KHR",
    } },
    .{ .name = "PhysicalDeviceType", .values = &.{
        "VK_PHYSICAL_DEVICE_TYPE_OTHER",
        "VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU",
        "VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU",
        "VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU",
        "VK_PHYSICAL_DEVICE_TYPE_CPU",
    } },
    .{ .name = "ImageLayout", .values = &.{
        "VK_IMAGE_LAYOUT_UNDEFINED",
        "VK_IMAGE_LAYOUT_GENERAL",
        "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR",
    } },
    .{ .name = "AttachmentLoadOp", .values = &.{
        "VK_ATTACHMENT_LOAD_OP_LOAD",
        "VK_ATTACHMENT_LOAD_OP_CLEAR",
        "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
    } },
    .{ .name = "AttachmentStoreOp", .values = &.{
        "VK_ATTACHMENT_STORE_OP_STORE",
        "VK_ATTACHMENT_STORE_OP_DONT_CARE",
    } },
    .{ .name = "ImageViewType", .values = &.{
        "VK_IMAGE_VIEW_TYPE_2D",
        "VK_IMAGE_VIEW_TYPE_2D_ARRAY",
    } },
    .{ .name = "ComponentSwizzle", .values = &.{
        "VK_COMPONENT_SWIZZLE_IDENTITY",
    } },
    .{ .name = "SharingMode", .values = &.{
        "VK_SHARING_MODE_EXCLUSIVE",
        "VK_SHARING_MODE_CONCURRENT",
    } },
    .{ .name = "SemaphoreType", .values = &.{
        "VK_SEMAPHORE_TYPE_BINARY",
        "VK_SEMAPHORE_TYPE_TIMELINE",
    } },
    .{ .name = "CommandBufferLevel", .values = &.{
        "VK_COMMAND_BUFFER_LEVEL_PRIMARY",
    } },
    .{ .name = "ObjectType", .values = &.{
        "VK_OBJECT_TYPE_UNKNOWN",
        "VK_OBJECT_TYPE_INSTANCE",
        "VK_OBJECT_TYPE_DEVICE",
        "VK_OBJECT_TYPE_QUEUE",
        "VK_OBJECT_TYPE_SEMAPHORE",
        "VK_OBJECT_TYPE_COMMAND_BUFFER",
        "VK_OBJECT_TYPE_BUFFER",
        "VK_OBJECT_TYPE_IMAGE",
        "VK_OBJECT_TYPE_DEVICE_MEMORY",
        "VK_OBJECT_TYPE_IMAGE_VIEW",
        "VK_OBJECT_TYPE_SHADER_MODULE",
        "VK_OBJECT_TYPE_PIPELINE_LAYOUT",
        "VK_OBJECT_TYPE_PIPELINE",
        "VK_OBJECT_TYPE_DESCRIPTOR_SET_LAYOUT",
        "VK_OBJECT_TYPE_SAMPLER",
        "VK_OBJECT_TYPE_DESCRIPTOR_SET",
        "VK_OBJECT_TYPE_COMMAND_POOL",
        "VK_OBJECT_TYPE_SWAPCHAIN_KHR",
    } },
    .{ .name = "ImageType", .values = &.{
        "VK_IMAGE_TYPE_2D",
        "VK_IMAGE_TYPE_3D",
    } },
    .{ .name = "ImageTiling", .values = &.{
        "VK_IMAGE_TILING_OPTIMAL",
        "VK_IMAGE_TILING_LINEAR",
    } },
    .{ .name = "Filter", .values = &.{
        "VK_FILTER_NEAREST",
        "VK_FILTER_LINEAR",
    } },
    .{ .name = "SamplerMipmapMode", .values = &.{
        "VK_SAMPLER_MIPMAP_MODE_NEAREST",
        "VK_SAMPLER_MIPMAP_MODE_LINEAR",
    } },
    .{ .name = "SamplerAddressMode", .values = &.{
        "VK_SAMPLER_ADDRESS_MODE_REPEAT",
        "VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT",
        "VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE",
    } },
    .{ .name = "BorderColor", .values = &.{
        "VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK",
    } },
    .{ .name = "CompareOp", .values = &.{
        "VK_COMPARE_OP_NEVER",
        "VK_COMPARE_OP_LESS",
        "VK_COMPARE_OP_EQUAL",
        "VK_COMPARE_OP_LESS_OR_EQUAL",
        "VK_COMPARE_OP_GREATER",
        "VK_COMPARE_OP_NOT_EQUAL",
        "VK_COMPARE_OP_GREATER_OR_EQUAL",
        "VK_COMPARE_OP_ALWAYS",
    } },
    .{ .name = "DescriptorType", .values = &.{
        "VK_DESCRIPTOR_TYPE_SAMPLER",
        "VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE",
        "VK_DESCRIPTOR_TYPE_STORAGE_IMAGE",
        "VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER",
        "VK_DESCRIPTOR_TYPE_STORAGE_BUFFER",
    } },
    .{ .name = "PipelineBindPoint", .values = &.{
        "VK_PIPELINE_BIND_POINT_GRAPHICS",
        "VK_PIPELINE_BIND_POINT_COMPUTE",
    } },
    .{ .name = "VertexInputRate", .values = &.{
        "VK_VERTEX_INPUT_RATE_VERTEX",
        "VK_VERTEX_INPUT_RATE_INSTANCE",
    } },
    .{ .name = "PrimitiveTopology", .values = &.{
        "VK_PRIMITIVE_TOPOLOGY_POINT_LIST",
        "VK_PRIMITIVE_TOPOLOGY_LINE_LIST",
        "VK_PRIMITIVE_TOPOLOGY_LINE_STRIP",
        "VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST",
        "VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP",
    } },
    .{ .name = "PolygonMode", .values = &.{
        "VK_POLYGON_MODE_FILL",
    } },
    .{ .name = "FrontFace", .values = &.{
        "VK_FRONT_FACE_COUNTER_CLOCKWISE",
        "VK_FRONT_FACE_CLOCKWISE",
    } },
    .{ .name = "BlendFactor", .values = &.{
        "VK_BLEND_FACTOR_ZERO",
        "VK_BLEND_FACTOR_ONE",
        "VK_BLEND_FACTOR_SRC_COLOR",
        "VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR",
        "VK_BLEND_FACTOR_DST_COLOR",
        "VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR",
        "VK_BLEND_FACTOR_SRC_ALPHA",
        "VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA",
        "VK_BLEND_FACTOR_DST_ALPHA",
        "VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA",
    } },
    .{ .name = "BlendOp", .values = &.{
        "VK_BLEND_OP_ADD",
    } },
    .{ .name = "LogicOp", .values = &.{
        "VK_LOGIC_OP_COPY",
    } },
    .{ .name = "StencilOp", .values = &.{
        "VK_STENCIL_OP_KEEP",
    } },
    .{ .name = "DynamicState", .values = &.{
        "VK_DYNAMIC_STATE_VIEWPORT",
        "VK_DYNAMIC_STATE_SCISSOR",
    } },
    .{ .name = "IndexType", .values = &.{
        "VK_INDEX_TYPE_UINT16",
        "VK_INDEX_TYPE_UINT32",
    } },
    .{ .name = "StructureType", .values = &.{} },
};

/// The constants: limits and special values, each a 32-bit value. Flag bits are fields of the flags structures.
const constants = [_][]const u8{
    "VK_MAX_MEMORY_TYPES",
    "VK_MAX_MEMORY_HEAPS",
    "VK_MAX_EXTENSION_NAME_SIZE",
    "VK_MAX_DESCRIPTION_SIZE",
    "VK_MAX_PHYSICAL_DEVICE_NAME_SIZE",
    "VK_UUID_SIZE",
    "VK_QUEUE_FAMILY_IGNORED",
    "VK_REMAINING_MIP_LEVELS",
    "VK_REMAINING_ARRAY_LAYERS",
};

/// Constants written by hand: neither 32-bit integers nor flag bits.
const special_constants = [_]SpecialConstant{
    .{
        .name = "whole_size",
        .zig_type = "DeviceSize",
        .value = "0xffff_ffff_ffff_ffff",
        .doc = "VK_WHOLE_SIZE: the rest of the buffer",
    },
    .{
        .name = "lod_clamp_none",
        .zig_type = "f32",
        .value = "1000.0",
        .doc = "VK_LOD_CLAMP_NONE: no upper bound on a sampler's level of detail",
    },
};

/// The commands, by the dispatch table that loads them.
const command_levels = [_]CommandLevel{
    .{ .level = .global, .commands = &.{
        "vkCreateInstance",
        "vkEnumerateInstanceLayerProperties",
        "vkEnumerateInstanceExtensionProperties",
        "vkEnumerateInstanceVersion",
    } },
    .{ .level = .instance, .commands = &.{
        "vkDestroyInstance",
        "vkEnumeratePhysicalDevices",
        "vkGetPhysicalDeviceProperties",
        "vkGetPhysicalDeviceQueueFamilyProperties",
        "vkGetPhysicalDeviceFeatures2",
        "vkEnumerateDeviceExtensionProperties",
        "vkCreateDevice",
        "vkGetDeviceProcAddr",
        "vkGetPhysicalDeviceMemoryProperties",
        "vkCreateDebugUtilsMessengerEXT",
        "vkDestroyDebugUtilsMessengerEXT",
    } },
    .{ .level = .surface, .commands = &.{
        "vkCreateWin32SurfaceKHR",
        "vkDestroySurfaceKHR",
        "vkGetPhysicalDeviceSurfaceSupportKHR",
        "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
        "vkGetPhysicalDeviceSurfaceFormatsKHR",
        "vkGetPhysicalDeviceSurfacePresentModesKHR",
    } },
    .{ .level = .device, .commands = &.{
        "vkDestroyDevice",
        "vkGetDeviceQueue",
        "vkDeviceWaitIdle",
        "vkCreateImageView",
        "vkDestroyImageView",
        "vkCreateSemaphore",
        "vkDestroySemaphore",
        "vkWaitSemaphores",
        "vkGetSemaphoreCounterValue",
        "vkCreateCommandPool",
        "vkDestroyCommandPool",
        "vkAllocateCommandBuffers",
        "vkResetCommandBuffer",
        "vkBeginCommandBuffer",
        "vkEndCommandBuffer",
        "vkCmdPipelineBarrier2",
        "vkCmdBeginRendering",
        "vkCmdEndRendering",
        "vkQueueSubmit2",
        "vkSetDebugUtilsObjectNameEXT",
        "vkCreateBuffer",
        "vkDestroyBuffer",
        "vkGetBufferMemoryRequirements",
        "vkAllocateMemory",
        "vkFreeMemory",
        "vkBindBufferMemory",
        "vkMapMemory",
        "vkCmdCopyBuffer",
        "vkCmdFillBuffer",
        "vkCreateImage",
        "vkDestroyImage",
        "vkGetImageMemoryRequirements",
        "vkBindImageMemory",
        "vkCmdCopyBufferToImage",
        "vkCmdCopyImageToBuffer",
        "vkCmdClearColorImage",
        "vkCmdClearDepthStencilImage",
        "vkCreateSampler",
        "vkDestroySampler",
        "vkCreateShaderModule",
        "vkDestroyShaderModule",
        "vkCreateDescriptorSetLayout",
        "vkDestroyDescriptorSetLayout",
        "vkCreatePipelineLayout",
        "vkDestroyPipelineLayout",
        "vkCreateDescriptorPool",
        "vkDestroyDescriptorPool",
        "vkAllocateDescriptorSets",
        "vkFreeDescriptorSets",
        "vkUpdateDescriptorSets",
        "vkCreateGraphicsPipelines",
        "vkCreateComputePipelines",
        "vkDestroyPipeline",
        "vkCmdBindPipeline",
        "vkCmdBindDescriptorSets",
        "vkCmdBindVertexBuffers",
        "vkCmdBindIndexBuffer",
        "vkCmdDraw",
        "vkCmdDrawIndexed",
        "vkCmdSetViewport",
        "vkCmdSetScissor",
        "vkCmdDispatch",
    } },
    .{ .level = .swapchain, .commands = &.{
        "vkCreateSwapchainKHR",
        "vkDestroySwapchainKHR",
        "vkGetSwapchainImagesKHR",
        "vkAcquireNextImageKHR",
        "vkQueuePresentKHR",
    } },
};

// ---- The registry ----

/// How the registry gives an enumerant's value.
const EnumerantValue = union(enum) {
    /// A number: given directly (`value`), as a bit (`bitpos`), or computed from an extension's block (`offset`).
    number: i128,
    /// The name of another enumerant, whose value this one shares.
    alias: []const u8,
};

/// The first number of the block reserved for extensions' enumerants: extension N owns the thousand numbers starting
/// at `extension_block_base + (N - 1) * 1000`.
const extension_block_base: i128 = 1_000_000_000;

/// One bit of a flags type, under the registry's name for it.
const FlagBit = struct {
    name: []const u8,
    position: u7,
};

const FlagBitList = ArrayList(FlagBit);

/// Each flag-bits enumeration's bits, by the enumeration's name.
const FlagBitIndex = StringHashMapUnmanaged(FlagBitList);

/// Registry elements by name.
const ElementIndex = StringHashMapUnmanaged(*const xml.Element);

/// Enumerant values by name.
const EnumerantIndex = StringHashMapUnmanaged(EnumerantValue);

/// The parts of the registry the generator reads, indexed by name. Keys and elements point into `document`, which
/// this owns, and into the source text, which must outlive it.
const Registry = struct {
    document: xml.Document,
    /// Every type by name - structures, unions, handles, enumerations, bitmasks, function pointers - the first
    /// definition of each.
    types: ElementIndex = .empty,
    /// Every command by name, for the Vulkan API (the registry also describes Vulkan SC, whose variants are skipped);
    /// an alias's element names the command it stands for.
    commands: ElementIndex = .empty,
    /// Every enumerant by name: from the enumerations themselves, and from the features and extensions that add to
    /// them.
    enumerants: EnumerantIndex = .empty,
    /// The API constants (`VK_MAX_EXTENSION_NAME_SIZE`, ...), as the C expressions the registry writes them in.
    api_constants: StringHashMapUnmanaged([]const u8) = .empty,
    /// The flag-bits enumerations whose bits are 64-bit (`VkPipelineStageFlagBits2`, ...).
    wide_flag_bits: StringHashMapUnmanaged(void) = .empty,
    /// Each flag-bits enumeration's bits (`VkImageUsageFlagBits`): its own, and those Vulkan's features and enabled
    /// extensions add to it. Aliases are left out - they repeat a bit under another name.
    flag_bits: FlagBitIndex = .empty,
    /// The flags type each flag-bits enumeration names the bits of (`VkImageUsageFlagBits` -> `VkImageUsageFlags`).
    flags_of_bits: StringHashMapUnmanaged([]const u8) = .empty,

    fn deinit(registry: *Registry, gpa: Allocator) void {
        registry.types.deinit(gpa);
        registry.commands.deinit(gpa);
        registry.enumerants.deinit(gpa);
        registry.api_constants.deinit(gpa);
        registry.wide_flag_bits.deinit(gpa);
        var bit_lists: FlagBitIndex.ValueIterator = registry.flag_bits.valueIterator();
        while (bit_lists.next()) |bit_list| {
            bit_list.deinit(gpa);
        }
        registry.flag_bits.deinit(gpa);
        registry.flags_of_bits.deinit(gpa);
        registry.document.deinit();
    }

    fn attribute(
        registry: *const Registry,
        element: *const xml.Element,
        name: []const u8,
    ) ?[]const u8 {
        return registry.document.attribute(element, name);
    }

    fn childText(
        registry: *const Registry,
        element: *const xml.Element,
        name: []const u8,
    ) ?[]const u8 {
        const found: *const xml.Element = registry.document.child(element, name) orelse return null;
        return found.text;
    }

    /// The text of the first element named `name` anywhere below `element`, in document order: a function-pointer
    /// type writes its name inside a `<proto>`, one level down.
    fn descendantText(
        registry: *const Registry,
        element: *const xml.Element,
        name: []const u8,
    ) ?[]const u8 {
        for (registry.document.childrenOf(element)) |*inner| {
            if (eql(u8, inner.name, name)) {
                return inner.text;
            }
            if (registry.descendantText(inner, name)) |found| {
                return found;
            }
        }
        return null;
    }
};

/// Whether an element applies to the Vulkan API: it names no API, or its list includes `vulkan`.
fn appliesToVulkan(registry: *const Registry, element: *const xml.Element) bool {
    const apis: []const u8 = registry.attribute(element, "api") orelse return true;
    var names = std.mem.tokenizeScalar(u8, apis, ',');
    while (names.next()) |api| {
        if (eql(u8, api, "vulkan")) {
            return true;
        }
    }
    return false;
}

/// Whether an extension is one Vulkan offers: its `supported` list names `vulkan` (a disabled extension's is
/// `disabled`; its numbers are reserved, and may collide with real bits).
fn supportsVulkan(registry: *const Registry, extension: *const xml.Element) bool {
    const supported: []const u8 = registry.attribute(extension, "supported") orelse return false;
    var names = std.mem.tokenizeScalar(u8, supported, ',');
    while (names.next()) |api| {
        if (eql(u8, api, "vulkan")) {
            return true;
        }
    }
    return false;
}

/// Records an `<enum>` element that names a bit of `bits_name` (it has a `bitpos`, and is not an alias).
fn recordFlagBit(
    gpa: Allocator,
    registry: *Registry,
    bits_name: []const u8,
    element: *const xml.Element,
) Allocator.Error!void {
    if (registry.attribute(element, "alias") != null or !appliesToVulkan(registry, element)) {
        return;
    }
    const position_text: []const u8 = registry.attribute(element, "bitpos") orelse return;
    const position: u7 = parseInt(u7, position_text, 10) catch return;
    const name: []const u8 = registry.attribute(element, "name") orelse return;
    const entry: FlagBitIndex.GetOrPutResult = try registry.flag_bits.getOrPut(gpa, bits_name);
    if (!entry.found_existing) {
        entry.value_ptr.* = .empty;
    }
    for (entry.value_ptr.items) |known| {
        if (eql(u8, known.name, name)) {
            return;
        }
    }
    try entry.value_ptr.append(gpa, .{ .name = name, .position = position });
}

/// An enumerant's value as one `<enum>` element gives it; null for an element that gives none (a string constant,
/// say). `extension_number` is the number of the extension the element sits in, if any.
fn enumerantValueOf(
    registry: *const Registry,
    element: *const xml.Element,
    extension_number: ?i128,
) ?EnumerantValue {
    if (registry.attribute(element, "alias")) |target| {
        return .{ .alias = target };
    }
    if (registry.attribute(element, "bitpos")) |position_text| {
        const position: u7 = parseInt(u7, position_text, 10) catch return null;
        return .{ .number = @as(i128, 1) << position };
    }
    if (registry.attribute(element, "offset")) |offset_text| {
        const offset: i128 = parseInt(i128, offset_text, 10) catch return null;
        // An `extnumber` names the owning extension when it is not the enclosing one (a promoted enumerant).
        const owner: i128 = if (registry.attribute(element, "extnumber")) |number_text|
            parseInt(i128, number_text, 10) catch return null
        else
            extension_number orelse return null;
        const magnitude: i128 = extension_block_base + (owner - 1) * 1000 + offset;
        const is_negative: bool = if (registry.attribute(element, "dir")) |dir| eql(u8, dir, "-") else false;
        return .{ .number = if (is_negative) -magnitude else magnitude };
    }
    if (registry.attribute(element, "value")) |value_text| {
        // Base 0: decimal, or hexadecimal with `0x`; quoted strings and C expressions are not numbers.
        return .{ .number = parseInt(i128, value_text, 0) catch return null };
    }
    return null;
}

fn indexTypes(
    gpa: Allocator,
    registry: *Registry,
    section: *const xml.Element,
) Allocator.Error!void {
    for (registry.document.childrenOf(section)) |*definition| {
        if (!eql(u8, definition.name, "type") or !appliesToVulkan(registry, definition)) {
            continue;
        }
        const name: []const u8 = registry.attribute(definition, "name") orelse
            registry.descendantText(definition, "name") orelse continue;
        const entry: ElementIndex.GetOrPutResult = try registry.types.getOrPut(gpa, name);
        if (!entry.found_existing) {
            entry.value_ptr.* = definition;
        }
        // A flags type names the enumeration of its bits: `requires` for 32-bit flags, `bitvalues` for 64-bit ones.
        if (registry.attribute(definition, "requires") orelse registry.attribute(definition, "bitvalues")) |bits_name| {
            if (eql(u8, registry.attribute(definition, "category") orelse "", "bitmask")) {
                try registry.flags_of_bits.put(gpa, bits_name, name);
            }
        }
    }
}

fn indexCommands(
    gpa: Allocator,
    registry: *Registry,
    section: *const xml.Element,
) Allocator.Error!void {
    for (registry.document.childrenOf(section)) |*definition| {
        if (!eql(u8, definition.name, "command") or !appliesToVulkan(registry, definition)) {
            continue;
        }
        const name: []const u8 = if (registry.document.child(definition, "proto")) |prototype|
            registry.childText(prototype, "name") orelse continue
        else
            registry.attribute(definition, "name") orelse continue;
        try registry.commands.put(gpa, name, definition);
    }
}

/// An enumeration block: its enumerants' values, or - for the block named "API Constants" - the constants' C text.
fn indexEnumeration(
    gpa: Allocator,
    registry: *Registry,
    block: *const xml.Element,
) Allocator.Error!void {
    const block_name: []const u8 = registry.attribute(block, "name") orelse "";
    const is_api_constants: bool = eql(u8, block_name, "API Constants");
    const is_flag_bits: bool = eql(u8, registry.attribute(block, "type") orelse "", "bitmask");
    if (registry.attribute(block, "bitwidth")) |width| {
        if (eql(u8, width, "64")) {
            try registry.wide_flag_bits.put(gpa, block_name, {});
        }
    }
    for (registry.document.childrenOf(block)) |*element| {
        if (!eql(u8, element.name, "enum")) {
            continue;
        }
        const name: []const u8 = registry.attribute(element, "name") orelse continue;
        if (is_api_constants) {
            if (registry.attribute(element, "value")) |value_text| {
                try registry.api_constants.put(gpa, name, value_text);
            }
            continue;
        }
        if (is_flag_bits) {
            try recordFlagBit(gpa, registry, block_name, element);
        }
        const value: EnumerantValue = enumerantValueOf(registry, element, null) orelse continue;
        const entry: EnumerantIndex.GetOrPutResult = try registry.enumerants.getOrPut(gpa, name);
        if (!entry.found_existing) {
            entry.value_ptr.* = value;
        }
    }
}

/// The enumerants a feature (a core version) or an extension adds to existing enumerations, in its `<require>`
/// blocks. The first definition of each name wins; repeated ones carry the same value.
fn indexAdditions(
    gpa: Allocator,
    registry: *Registry,
    addition: *const xml.Element,
    extension_number: ?i128,
    adds_bits: bool,
) Allocator.Error!void {
    for (registry.document.childrenOf(addition)) |*requirement| {
        if (!eql(u8, requirement.name, "require")) {
            continue;
        }
        const requirement_adds_bits: bool = adds_bits and appliesToVulkan(registry, requirement);
        for (registry.document.childrenOf(requirement)) |*element| {
            if (!eql(u8, element.name, "enum")) {
                continue;
            }
            if (requirement_adds_bits) {
                if (registry.attribute(element, "extends")) |bits_name| {
                    try recordFlagBit(gpa, registry, bits_name, element);
                }
            }
            const name: []const u8 = registry.attribute(element, "name") orelse continue;
            const value: EnumerantValue = enumerantValueOf(registry, element, extension_number) orelse continue;
            const entry: EnumerantIndex.GetOrPutResult = try registry.enumerants.getOrPut(gpa, name);
            if (!entry.found_existing) {
                entry.value_ptr.* = value;
            }
        }
    }
}

/// Reads the registry from `source`, which must outlive the result.
fn loadRegistry(gpa: Allocator, source: []const u8) (xml.Error || Allocator.Error)!Registry {
    var registry: Registry = .{ .document = try xml.parse(gpa, source, null) };
    errdefer registry.deinit(gpa);
    const root: *const xml.Element = registry.document.rootElement();
    for (registry.document.childrenOf(root)) |*section| {
        if (eql(u8, section.name, "types")) {
            try indexTypes(gpa, &registry, section);
        } else if (eql(u8, section.name, "commands")) {
            try indexCommands(gpa, &registry, section);
        } else if (eql(u8, section.name, "enums")) {
            try indexEnumeration(gpa, &registry, section);
        } else if (eql(u8, section.name, "feature")) {
            try indexAdditions(gpa, &registry, section, null, appliesToVulkan(&registry, section));
        } else if (eql(u8, section.name, "extensions")) {
            for (registry.document.childrenOf(section)) |*extension| {
                const number_text: []const u8 = registry.attribute(extension, "number") orelse continue;
                const number: i128 = parseInt(i128, number_text, 10) catch continue;
                try indexAdditions(gpa, &registry, extension, number, supportsVulkan(&registry, extension));
            }
        }
    }
    return registry;
}

/// An enumerant's numeric value, following aliases; null when the registry does not define it.
fn enumerantNumber(registry: *const Registry, name: []const u8) ?i128 {
    var current: []const u8 = name;
    // A short bound on alias chains: the registry's are one or two steps long.
    for (0..8) |_| {
        switch (registry.enumerants.get(current) orelse return null) {
            .number => |number| return number,
            .alias => |target| current = target,
        }
    }
    return null;
}

/// The registry's category of a type (`struct`, `handle`, `enum`, `bitmask`, ...), or null for one it does not list.
fn categoryOf(registry: *const Registry, type_name: []const u8) ?[]const u8 {
    const element: *const xml.Element = registry.types.get(type_name) orelse return null;
    return registry.attribute(element, "category");
}

/// The type an alias finally names (`VkFooKHR` -> `VkFoo`).
fn resolveAlias(registry: *const Registry, type_name: []const u8) []const u8 {
    var current: []const u8 = type_name;
    for (0..8) |_| {
        const element: *const xml.Element = registry.types.get(current) orelse return current;
        current = registry.attribute(element, "alias") orelse return current;
    }
    return current;
}

/// The enumeration a flags type's bits are named in (`VkImageUsageFlags` -> `VkImageUsageFlagBits`), or null for a
/// type whose bits are all reserved still (`VkDeviceCreateFlags`).
fn bitsOfFlags(registry: *const Registry, flags_name: []const u8) ?[]const u8 {
    const definition: *const xml.Element = registry.types.get(flags_name) orelse return null;
    return registry.attribute(definition, "requires") orelse registry.attribute(definition, "bitvalues");
}

/// The flags type a C type stands for, when it stands for one with named bits: a flags type itself, or the
/// flag-bits type of a single bit (`VkSampleCountFlagBits samples`).
fn flagsTypeOf(registry: *const Registry, type_name: []const u8) ?[]const u8 {
    const resolved: []const u8 = resolveAlias(registry, type_name);
    const category: []const u8 = categoryOf(registry, resolved) orelse return null;
    const is_flag_bits: bool = eql(u8, category, "enum") and indexOf(u8, resolved, "FlagBits") != null;
    const flags_name: []const u8 = if (eql(u8, category, "bitmask"))
        resolved
    else if (is_flag_bits)
        registry.flags_of_bits.get(resolved) orelse return null
    else
        return null;
    const bits_name: []const u8 = bitsOfFlags(registry, flags_name) orelse return null;
    if (!registry.flag_bits.contains(bits_name)) {
        return null;
    }
    return flags_name;
}

// ---- Rendering: the subset as Zig ----

/// `text` as a Zig name: as it is when it is a plain identifier, otherwise quoted, `@"text"` - a keyword (`opaque`,
/// `error`), a primitive's name (`type`, `bool`, `null`), or a name starting with a digit (`4`). The standard library
/// decides, so every keyword and primitive Zig has is covered.
fn quotedIfNeeded(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (isValidId(text) and !isPrimitive(text)) {
        return text;
    }
    return allocPrint(arena, "@\"{s}\"", .{text});
}

/// A registry name in camelCase (`pEnabledLayerNames`) as a Zig name in snake_case (`p_enabled_layer_names`): an
/// underscore before each capital that follows a lower-case letter, and before each digit that follows a letter.
fn snakeCase(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: ArrayList(u8) = .empty;
    for (name, 0..) |character, index| {
        if (index > 0) {
            const previous: u8 = name[index - 1];
            const starts_word: bool = std.ascii.isUpper(character) and std.ascii.isLower(previous);
            const starts_number: bool = std.ascii.isDigit(character) and std.ascii.isAlphabetic(previous);
            if (starts_word or starts_number) {
                try out.append(arena, '_');
            }
        }
        try out.append(arena, std.ascii.toLower(character));
    }
    return quotedIfNeeded(arena, out.items);
}

/// A C type the registry does not define as a Vulkan type, and its Zig spelling.
const BuiltinType = struct {
    c: []const u8,
    zig: []const u8,
};

const builtin_types = [_]BuiltinType{
    .{ .c = "void", .zig = "anyopaque" },                .{ .c = "char", .zig = "u8" },
    .{ .c = "uint8_t", .zig = "u8" },                    .{ .c = "uint16_t", .zig = "u16" },
    .{ .c = "uint32_t", .zig = "u32" },                  .{ .c = "uint64_t", .zig = "u64" },
    .{ .c = "int32_t", .zig = "i32" },                   .{ .c = "int64_t", .zig = "i64" },
    .{ .c = "float", .zig = "f32" },                     .{ .c = "double", .zig = "f64" },
    .{ .c = "size_t", .zig = "usize" },                  .{ .c = "int", .zig = "c_int" },
    .{ .c = "VkBool32", .zig = "Bool32" },               .{ .c = "VkDeviceSize", .zig = "DeviceSize" },
    .{ .c = "VkDeviceAddress", .zig = "DeviceAddress" }, .{ .c = "VkSampleMask", .zig = "u32" },
    .{ .c = "VkFlags", .zig = "Flags" },                 .{ .c = "VkFlags64", .zig = "Flags64" },
    .{ .c = "HINSTANCE", .zig = "?*anyopaque" },         .{ .c = "HWND", .zig = "?*anyopaque" },
    .{ .c = "HMONITOR", .zig = "?*anyopaque" },          .{ .c = "HANDLE", .zig = "?*anyopaque" },
    .{ .c = "DWORD", .zig = "u32" },                     .{ .c = "LPCWSTR", .zig = "?[*:0]const u16" },
};

const GenerateError = error{
    /// A type the generator cannot translate: a new category, or a platform type not in `builtin_types`.
    UnknownType,
    /// A listed name the registry does not define.
    NotInRegistry,
    /// `src/vk.zig` lacks a marker the splice needs, or its result does not parse.
    MalformedOutput,
    /// Two bits of one flags type would get the same field name.
    FlagNameCollision,
    /// The registry says something the generator does not expect: a bit past its flags type's width.
    UnexpectedRegistry,
} || Allocator.Error;

/// The Zig type a C type name stands for, before any pointer or array: `VkExtent2D` is `Extent2D`, a flags type is
/// `Flags` or `Flags64`, a function-pointer type is untyped.
fn baseType(registry: *const Registry, type_name: []const u8) GenerateError![]const u8 {
    for (builtin_types) |builtin| {
        if (eql(u8, builtin.c, type_name)) {
            return builtin.zig;
        }
    }
    const resolved: []const u8 = resolveAlias(registry, type_name);
    // A flags type with named bits, or one bit of it, is its flags structure (`ImageUsageFlags`).
    if (flagsTypeOf(registry, resolved)) |flags_name| {
        return flags_name[2..];
    }
    const category: []const u8 = categoryOf(registry, resolved) orelse "";
    if (eql(u8, category, "bitmask")) {
        const definition: *const xml.Element = registry.types.get(resolved).?;
        const underlying: []const u8 = registry.childText(definition, "type") orelse "VkFlags";
        return if (eql(u8, underlying, "VkFlags64")) "Flags64" else "Flags";
    }
    if (eql(u8, category, "enum") and indexOf(u8, resolved, "FlagBits") != null) {
        return if (registry.wide_flag_bits.contains(resolved)) "Flags64" else "Flags";
    }
    if (eql(u8, category, "funcpointer")) {
        return "?*const anyopaque";
    }
    const is_named_type: bool = eql(u8, category, "handle") or eql(u8, category, "enum") or
        eql(u8, category, "struct") or eql(u8, category, "union");
    if (is_named_type) {
        return if (startsWith(u8, resolved, "Vk")) resolved[2..] else resolved;
    }
    std.debug.print("vk-gen: no Zig spelling for the C type {s} (category '{s}')\n", .{ type_name, category });
    return GenerateError.UnknownType;
}

/// A member's or parameter's C declaration, in the pieces the registry writes it in: `const <type>char</type>*
/// const* <name>ppNames</name>` is the prefix "const", the type "char", the pointer part "* const*", the name; an
/// array bound follows the name (`[4]`, or `[<enum>VK_UUID_SIZE</enum>]`).
const Declaration = struct {
    prefix: []const u8,
    type_name: []const u8,
    pointer_part: []const u8,
    name: []const u8,
    after_name: []const u8,
};

fn declarationOf(
    arena: Allocator,
    registry: *const Registry,
    element: *const xml.Element,
) GenerateError!Declaration {
    const type_element: *const xml.Element = registry.document.child(element, "type") orelse
        return GenerateError.NotInRegistry;
    const name_element: *const xml.Element = registry.document.child(element, "name") orelse
        return GenerateError.NotInRegistry;
    var after_name: []const u8 = name_element.tail;
    if (registry.document.child(element, "enum")) |bound| {
        after_name = try std.mem.concat(arena, u8, &.{ after_name, bound.text, bound.tail });
    }
    return .{
        .prefix = element.text,
        .type_name = type_element.text,
        .pointer_part = type_element.tail,
        .name = name_element.text,
        .after_name = after_name,
    };
}

/// The Zig type of a declaration. `has_len`: a pointer to several elements (the registry's `len`), not to one;
/// `optional`: a pointer that may be null.
fn zigType(
    arena: Allocator,
    registry: *const Registry,
    declaration: Declaration,
    has_len: bool,
    optional: bool,
) GenerateError![]const u8 {
    const is_const: bool = indexOf(u8, declaration.prefix, "const") != null;
    const stars: usize = std.mem.count(u8, declaration.pointer_part, "*");
    const base: []const u8 = try baseType(registry, declaration.type_name);
    if (stars == 0) {
        // Array bounds, innermost last: `[3][4]` is `[3][4]T`; a named bound is the API constant's value.
        var bounds: ArrayList([]const u8) = .empty;
        var rest: []const u8 = declaration.after_name;
        while (indexOfScalar(u8, rest, '[')) |open| {
            const close: usize = indexOfScalarPos(u8, rest, open, ']') orelse break;
            try bounds.append(arena, rest[open + 1 .. close]);
            rest = rest[close + 1 ..];
        }
        var result: []const u8 = base;
        var index: usize = bounds.items.len;
        while (index > 0) {
            index -= 1;
            const bound: []const u8 = bounds.items[index];
            const value: []const u8 = registry.api_constants.get(bound) orelse bound;
            result = try allocPrint(arena, "[{s}]{s}", .{ value, result });
        }
        return result;
    }
    if (eql(u8, declaration.type_name, "char")) {
        if (stars == 1) {
            return if (optional) "?[*:0]const u8" else "[*:0]const u8";
        }
        return "?[*]const [*:0]const u8";
    }
    const qualifier: []const u8 = if (is_const) "const " else "";
    if (eql(u8, declaration.type_name, "void")) {
        return allocPrint(arena, "?*{s}anyopaque", .{qualifier});
    }
    const pointee: []const u8 = if (startsWith(u8, base, "?")) base[1..] else base;
    var pointer: []const u8 = if (has_len)
        try allocPrint(arena, "[*]{s}{s}", .{ qualifier, pointee })
    else
        try allocPrint(arena, "*{s}{s}", .{ qualifier, pointee });
    if (stars == 2) {
        pointer = try allocPrint(arena, "[*]const {s}", .{pointer});
    }
    return if (optional) allocPrint(arena, "?{s}", .{pointer}) else pointer;
}

/// Whether a declaration points to several elements: the registry gives it a `len`, other than a string's.
fn pointsToSeveral(registry: *const Registry, element: *const xml.Element) bool {
    const length: []const u8 = registry.attribute(element, "len") orelse return false;
    return !startsWith(u8, length, "null-terminated");
}

/// The default value of a structure field: its own `sType`, null, zeros, or a null handle - so a structure literal
/// names only the fields it sets. A union field has none.
fn defaultFor(
    arena: Allocator,
    registry: *const Registry,
    zig: []const u8,
    member_name: []const u8,
    structure_tag: ?[]const u8,
) Allocator.Error!?[]const u8 {
    if (eql(u8, member_name, "sType")) {
        if (structure_tag) |tag| {
            const bare: []const u8 = if (startsWith(u8, tag, "VK_STRUCTURE_TYPE_")) tag[18..] else tag;
            return try allocPrint(arena, ".{s}", .{try std.ascii.allocLowerString(arena, bare)});
        }
    }
    if (startsWith(u8, zig, "?")) {
        return "null";
    }
    if (startsWith(u8, zig, "[")) {
        const element_type: []const u8 = zig[std.mem.lastIndexOfScalar(u8, zig, ']').? + 1 ..];
        const numeric_elements = [_][]const u8{ "u8", "u32", "i32", "f32", "u64", "Bool32", "DeviceSize", "usize" };
        for (numeric_elements) |numeric| {
            if (eql(u8, element_type, numeric)) {
                return "@splat(0)";
            }
        }
        return "@splat(.{})";
    }
    const zero_types = [_][]const u8{
        "u8",
        "u16",
        "u32",
        "u64",
        "i32",
        "i64",
        "f32",
        "f64",
        "usize",
        "c_int",
        "Bool32",
        "DeviceSize",
        "DeviceAddress",
        "Flags",
        "Flags64",
    };
    for (zero_types) |zero_type| {
        if (eql(u8, zig, zero_type)) {
            return "0";
        }
    }
    const c_name: []const u8 = try allocPrint(arena, "Vk{s}", .{zig});
    const category: []const u8 = categoryOf(registry, c_name) orelse "";
    if (eql(u8, category, "handle")) {
        return ".null_handle";
    }
    if (eql(u8, category, "enum")) {
        return "@enumFromInt(0)";
    }
    if (eql(u8, category, "union")) {
        return null;
    }
    return ".{}";
}

/// Lines of Zig text, joined with newlines at the end.
const Lines = ArrayList([]const u8);

/// `Arguments` must be a tuple of format arguments, as `std.fmt` takes them: `.{ name, value }`.
fn requireFormatTuple(comptime Arguments: type) void {
    const info: std.builtin.Type = @typeInfo(Arguments);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("expected a tuple of format arguments, such as .{ name, value }; found " ++ @typeName(Arguments));
    }
}

/// Appends one line, formatted: `arguments` is a tuple, as `std.fmt` takes (the one `anytype` in this file - a
/// format's arguments have whatever types its placeholders name).
fn addLine(
    arena: Allocator,
    lines: *Lines,
    comptime format: []const u8,
    arguments: anytype,
) Allocator.Error!void {
    comptime requireFormatTuple(@TypeOf(arguments));
    try lines.append(arena, try allocPrint(arena, format, arguments));
}

fn joinLines(arena: Allocator, lines: Lines) Allocator.Error![]const u8 {
    return std.mem.join(arena, "\n", lines.items);
}

/// One structure or union, by its Zig name: each member a field of its Zig type, with its default (a union's fields
/// have none). A structure's `sType` value is appended to `structure_tags`.
fn renderStructure(
    arena: Allocator,
    registry: *const Registry,
    name: []const u8,
    lines: *Lines,
    structure_tags: *ArrayList([]const u8),
) GenerateError!void {
    const c_name: []const u8 = try allocPrint(arena, "Vk{s}", .{name});
    const definition: *const xml.Element = registry.types.get(resolveAlias(registry, c_name)) orelse {
        std.debug.print("vk-gen: the registry has no structure {s}\n", .{c_name});
        return GenerateError.NotInRegistry;
    };
    const is_union: bool = eql(u8, registry.attribute(definition, "category") orelse "", "union");
    try addLine(arena, lines, "pub const {s} = extern {s} {{", .{ name, if (is_union) "union" else "struct" });
    for (registry.document.childrenOf(definition)) |*member| {
        if (!eql(u8, member.name, "member") or !appliesToVulkan(registry, member)) {
            continue;
        }
        const declaration: Declaration = try declarationOf(arena, registry, member);
        const zig: []const u8 = try zigType(arena, registry, declaration, pointsToSeveral(registry, member), true);
        const structure_tag: ?[]const u8 = registry.attribute(member, "values");
        if (structure_tag) |tag| {
            try structure_tags.append(arena, tag);
        }
        const field: []const u8 = try snakeCase(arena, declaration.name);
        const default: ?[]const u8 = if (is_union)
            null
        else
            try defaultFor(arena, registry, zig, declaration.name, structure_tag);
        if (default) |value| {
            try addLine(arena, lines, "    {s}: {s} = {s},", .{ field, zig, value });
        } else {
            try addLine(arena, lines, "    {s}: {s},", .{ field, zig });
        }
    }
    try lines.append(arena, "};\n");
}

/// The structures, opaque ones first. Collects each structure's `sType` value into `structure_tags`.
fn renderStructures(
    arena: Allocator,
    registry: *const Registry,
    structure_tags: *ArrayList([]const u8),
) GenerateError![]const u8 {
    var lines: Lines = .empty;
    try lines.append(arena, "// ---- Structures (layouts from the Vulkan registry; checked against the C headers by " ++
        "`vk-abi-check`) ----\n");
    for (opaque_structures) |name| {
        try addLine(arena, &lines, "pub const {s} = opaque {{}};\n", .{name});
    }
    for (structures) |name| {
        try renderStructure(arena, registry, name, &lines, structure_tags);
    }
    return joinLines(arena, lines);
}

/// The C prefix an enumeration's enumerants share: `VkPhysicalDeviceType` names `VK_PHYSICAL_DEVICE_TYPE_...`; a
/// `KHR` or `EXT` suffix is not part of it, and `Result`'s enumerants share only `VK_`.
fn enumerantPrefix(arena: Allocator, enumeration_name: []const u8) Allocator.Error![]const u8 {
    if (eql(u8, enumeration_name, "Result")) {
        return "VK_";
    }
    var bare: []const u8 = enumeration_name;
    if (endsWith(u8, bare, "KHR") or endsWith(u8, bare, "EXT")) {
        bare = bare[0 .. bare.len - 3];
    }
    var out: ArrayList(u8) = .empty;
    try out.appendSlice(arena, "VK_");
    for (bare, 0..) |character, index| {
        if (index > 0 and std.ascii.isUpper(character)) {
            const previous: u8 = bare[index - 1];
            if (std.ascii.isLower(previous) or std.ascii.isDigit(previous)) {
                try out.append(arena, '_');
            }
        }
        try out.append(arena, std.ascii.toUpper(character));
    }
    try out.append(arena, '_');
    return out.items;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// The enumerations, as non-exhaustive Zig enumerations of the enumerants zimr uses. `StructureType`'s enumerants
/// are the collected `sType` values, sorted and without repeats.
fn renderEnumerations(
    arena: Allocator,
    registry: *const Registry,
    structure_tags: []const []const u8,
) GenerateError![]const u8 {
    var lines: Lines = .empty;
    try lines.append(arena, "// ---- Enumerations: the values zimr uses, non-exhaustive so a driver's other values " ++
        "stay representable ----\n");
    var sorted_tags: ArrayList([]const u8) = .empty;
    for (structure_tags) |tag| {
        for (sorted_tags.items) |kept| {
            if (eql(u8, kept, tag)) {
                break;
            }
        } else {
            try sorted_tags.append(arena, tag);
        }
    }
    sortSlice([]const u8, sorted_tags.items, {}, lessThanString);
    for (enumerations) |enumeration| {
        const values: []const []const u8 = if (eql(u8, enumeration.name, "StructureType"))
            sorted_tags.items
        else
            enumeration.values;
        const prefix: []const u8 = try enumerantPrefix(arena, enumeration.name);
        try addLine(arena, &lines, "pub const {s} = enum(i32) {{", .{enumeration.name});
        for (values) |tag| {
            const number: i128 = enumerantNumber(registry, tag) orelse {
                std.debug.print("vk-gen: the registry gives no value for {s}\n", .{tag});
                return GenerateError.NotInRegistry;
            };
            const unprefixed: []const u8 = if (startsWith(u8, tag, prefix)) tag[prefix.len..] else tag[3..];
            const short: []const u8 = try quotedIfNeeded(arena, try std.ascii.allocLowerString(arena, unprefixed));
            try addLine(arena, &lines, "    {s} = {d},", .{ short, number });
        }
        try lines.append(arena, "    _,");
        try lines.append(arena, "};\n");
    }
    return joinLines(arena, lines);
}

/// The constants named all-ones in C (`(~0U)`), written as the 32-bit value.
const all_ones_constants = [_][]const u8{
    "VK_QUEUE_FAMILY_IGNORED",
    "VK_REMAINING_MIP_LEVELS",
    "VK_REMAINING_ARRAY_LAYERS",
};

/// A constant's value as Zig text: the 32-bit all-ones value for the three C writes as `(~0U)`, an API constant's
/// own number, or an enumerant's value.
fn constantValue(
    arena: Allocator,
    registry: *const Registry,
    name: []const u8,
) GenerateError![]const u8 {
    for (all_ones_constants) |all_ones| {
        if (eql(u8, all_ones, name)) {
            return "0xffff_ffff";
        }
    }
    if (registry.api_constants.get(name)) |text| {
        return text;
    }
    const number: i128 = enumerantNumber(registry, name) orelse {
        std.debug.print("vk-gen: the registry gives no value for {s}\n", .{name});
        return GenerateError.NotInRegistry;
    };
    return allocPrint(arena, "{d}", .{number});
}

fn renderConstants(arena: Allocator, registry: *const Registry) GenerateError![]const u8 {
    var lines: Lines = .empty;
    try lines.append(arena, "// ---- Constants: each C name lower-cased without `VK_` (VK_MAX_MEMORY_TYPES is " ++
        "`max_memory_types`) ----\n");
    for (constants) |name| {
        const zig_name: []const u8 = try std.ascii.allocLowerString(arena, name[3..]);
        const value: []const u8 = try constantValue(arena, registry, name);
        try addLine(arena, &lines, "pub const {s}: u32 = {s};", .{ zig_name, value });
    }
    for (special_constants) |constant| {
        try addLine(arena, &lines, "/// {s}.", .{constant.doc});
        try addLine(arena, &lines, "pub const {s}: {s} = {s};", .{ constant.name, constant.zig_type, constant.value });
    }
    try lines.append(arena, "");
    return joinLines(arena, lines);
}

/// A command's definition for Vulkan, through its alias if it is one.
fn commandDefinition(registry: *const Registry, name: []const u8) GenerateError!*const xml.Element {
    const definition: *const xml.Element = registry.commands.get(name) orelse {
        std.debug.print("vk-gen: the registry has no command {s}\n", .{name});
        return GenerateError.NotInRegistry;
    };
    const target: []const u8 = registry.attribute(definition, "alias") orelse return definition;
    return registry.commands.get(target) orelse GenerateError.NotInRegistry;
}

/// What each dispatch table is called and documented as.
fn tableTitle(level: Level) []const u8 {
    return switch (level) {
        .global => "GlobalDispatch",
        .instance => "InstanceDispatch",
        .surface => "SurfaceDispatch",
        .device => "DeviceDispatch",
        .swapchain => "SwapchainDispatch",
    };
}

fn tableDoc(level: Level) []const u8 {
    return switch (level) {
        .global => "The commands that exist before an instance.",
        .instance => "One instance's commands.",
        .surface => "An instance's window-system commands (VK_KHR_surface, VK_KHR_win32_surface): loaded only by " ++
            "a\n/// host with a window.",
        .device => "One device's commands.",
        .swapchain => "A device's swapchain commands (VK_KHR_swapchain): loaded only by a host with a window.",
    };
}

/// A command's name without its `vk` prefix: `vkCmdBeginRendering` is `CmdBeginRendering`, and its function-pointer
/// type is `PfnCmdBeginRendering`.
fn commandTitle(name: []const u8) []const u8 {
    return name[2..];
}

/// A command's table field: its title starting lower-case, as Zig functions do (`cmdBeginRendering`).
fn commandField(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const title: []const u8 = commandTitle(name);
    return allocPrint(arena, "{c}{s}", .{ std.ascii.toLower(title[0]), title[1..] });
}

/// A command's return type in Zig: `VkResult` is `Result`, an untyped command `?PfnVoidFunction`, any other type its
/// base type (`uint64_t` is `u64`, `VkBool32` is `Bool32`).
fn returnTypeOf(registry: *const Registry, c_type: []const u8) GenerateError![]const u8 {
    if (eql(u8, c_type, "void")) {
        return "void";
    }
    if (eql(u8, c_type, "VkResult")) {
        return "Result";
    }
    if (eql(u8, c_type, "PFN_vkVoidFunction")) {
        return "?PfnVoidFunction";
    }
    return baseType(registry, c_type);
}

/// One command's function-pointer type, by the command's C name: its parameters in order, and its return type. An
/// alias is rendered with its own name and the command it stands for's parameters.
fn renderCommandType(
    arena: Allocator,
    registry: *const Registry,
    name: []const u8,
    lines: *Lines,
) GenerateError!void {
    const definition: *const xml.Element = try commandDefinition(registry, name);
    const prototype: *const xml.Element = registry.document.child(definition, "proto") orelse
        return GenerateError.NotInRegistry;
    const return_c: []const u8 = registry.childText(prototype, "type") orelse
        return GenerateError.NotInRegistry;
    try addLine(arena, lines, "pub const Pfn{s} = *const fn (", .{commandTitle(name)});
    for (registry.document.childrenOf(definition)) |*parameter| {
        if (!eql(u8, parameter.name, "param") or !appliesToVulkan(registry, parameter)) {
            continue;
        }
        const declaration: Declaration = try declarationOf(arena, registry, parameter);
        // `optional` may list one answer per pointer level; the first is the parameter's own.
        const optional_text: []const u8 = registry.attribute(parameter, "optional") orelse "false";
        const optional: bool = startsWith(u8, optional_text, "true");
        const is_string: bool = eql(u8, declaration.type_name, "char") and
            std.mem.count(u8, declaration.pointer_part, "*") == 1;
        const zig: []const u8 = if (is_string)
            (if (optional) "?[*:0]const u8" else "[*:0]const u8")
        else
            try zigType(arena, registry, declaration, pointsToSeveral(registry, parameter), optional);
        try addLine(arena, lines, "    {s}: {s},", .{ try snakeCase(arena, declaration.name), zig });
    }
    try addLine(arena, lines, ") callconv(call_conv) {s};\n", .{try returnTypeOf(registry, return_c)});
}

/// One function-pointer type per command, then the dispatch tables that hold them.
fn renderCommands(arena: Allocator, registry: *const Registry) GenerateError![]const u8 {
    var lines: Lines = .empty;
    try lines.append(arena, "// ---- Commands: one function-pointer type per command, filled by name into the " ++
        "dispatch tables ----\n");
    for (command_levels) |level| {
        for (level.commands) |name| {
            try renderCommandType(arena, registry, name, &lines);
        }
    }
    for (command_levels) |level| {
        try addLine(arena, &lines, "/// {s}", .{tableDoc(level.level)});
        try addLine(arena, &lines, "pub const {s} = struct {{", .{tableTitle(level.level)});
        for (level.commands) |name| {
            const field: []const u8 = try commandField(arena, name);
            try addLine(arena, &lines, "    {s}: Pfn{s},", .{ field, commandTitle(name) });
        }
        try lines.append(arena, "};\n");
    }
    return joinLines(arena, lines);
}

// ---- Flags: one packed structure per flags type ----

/// Adds the flags types of `definition`'s declarations (its `member`s or `param`s) to `used`, once each.
fn noteFlagsTypes(
    arena: Allocator,
    registry: *const Registry,
    used: *ArrayList([]const u8),
    definition: *const xml.Element,
    declaration_kind: []const u8,
) Allocator.Error!void {
    for (registry.document.childrenOf(definition)) |*declaration| {
        if (!eql(u8, declaration.name, declaration_kind) or !appliesToVulkan(registry, declaration)) {
            continue;
        }
        const type_name: []const u8 = registry.childText(declaration, "type") orelse continue;
        const flags_name: []const u8 = flagsTypeOf(registry, type_name) orelse continue;
        for (used.items) |known| {
            if (eql(u8, known, flags_name)) {
                break;
            }
        } else {
            try used.append(arena, flags_name);
        }
    }
}

/// The flags types the subset's structures and commands use, by C name, sorted.
fn usedFlagsTypes(arena: Allocator, registry: *const Registry) GenerateError![]const []const u8 {
    var used: ArrayList([]const u8) = .empty;
    for (structures) |name| {
        const c_name: []const u8 = try allocPrint(arena, "Vk{s}", .{name});
        const definition: *const xml.Element = registry.types.get(resolveAlias(registry, c_name)) orelse continue;
        try noteFlagsTypes(arena, registry, &used, definition, "member");
    }
    for (command_levels) |level| {
        for (level.commands) |name| {
            try noteFlagsTypes(arena, registry, &used, try commandDefinition(registry, name), "param");
        }
    }
    sortSlice([]const u8, used.items, {}, lessThanString);
    return used.items;
}

/// The vendor tag ending a flag-bits enumeration's name (`KHR` in `VkCompositeAlphaFlagBitsKHR`), or "".
fn vendorTagOf(bits_name: []const u8) []const u8 {
    const at: usize = indexOf(u8, bits_name, "FlagBits") orelse return "";
    var tag: []const u8 = bits_name[at + "FlagBits".len ..];
    while (tag.len > 0 and std.ascii.isDigit(tag[0])) {
        tag = tag[1..];
    }
    return tag;
}

/// The C prefix a flag-bits enumeration's bits share: `VkImageUsageFlagBits` names `VK_IMAGE_USAGE_...`, and
/// `VkPipelineStageFlagBits2` names `VK_PIPELINE_STAGE_2_...`.
fn flagBitsPrefix(arena: Allocator, bits_name: []const u8) Allocator.Error![]const u8 {
    const bare: []const u8 = if (startsWith(u8, bits_name, "Vk")) bits_name[2..] else bits_name;
    const at: usize = indexOf(u8, bare, "FlagBits") orelse return "VK_";
    const base_prefix: []const u8 = try enumerantPrefix(arena, bare[0..at]);
    const after: []const u8 = bare[at + "FlagBits".len ..];
    if (after.len > 0 and std.ascii.isDigit(after[0])) {
        return allocPrint(arena, "{s}{c}_", .{ base_prefix, after[0] });
    }
    return base_prefix;
}

/// A bit's field name: `VK_IMAGE_USAGE_TRANSFER_DST_BIT` is `transfer_dst`. The prefix, the word `BIT` and the
/// enumeration's own vendor tag are left out; a bit an extension added keeps its tag (`fragment_density_map_ext`);
/// a keyword or a name starting with a digit is quoted (`@"opaque"`, `@"4"`).
fn flagFieldName(
    arena: Allocator,
    bits_name: []const u8,
    bit_name: []const u8,
) Allocator.Error![]const u8 {
    const prefix: []const u8 = try flagBitsPrefix(arena, bits_name);
    const remainder: []const u8 = if (startsWith(u8, bit_name, prefix)) bit_name[prefix.len..] else bit_name[3..];
    const own_tag: []const u8 = vendorTagOf(bits_name);
    var words: ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeScalar(u8, remainder, '_');
    while (tokens.next()) |token| {
        if (!eql(u8, token, "BIT")) {
            try words.append(arena, token);
        }
    }
    if (own_tag.len > 0 and words.items.len > 1 and eql(u8, words.items[words.items.len - 1], own_tag)) {
        words.items.len -= 1;
    }
    const joined: []const u8 = try std.mem.join(arena, "_", words.items);
    const field: []const u8 = if (joined.len > 0) joined else remainder;
    return quotedIfNeeded(arena, try std.ascii.allocLowerString(arena, field));
}

/// One packed structure per flags type: a `bool` per bit, at the bit's position, so `.{ .transfer_dst = true }` is
/// the flags value with that one bit set. Positions no bit is named for yet are reserved fields.
fn renderFlags(
    arena: Allocator,
    registry: *const Registry,
    flags_names: []const []const u8,
) GenerateError![]const u8 {
    var lines: Lines = .empty;
    try lines.append(arena, "// ---- Flags: one packed structure per flags type, a field per bit ----\n");
    for (flags_names) |flags_name| {
        const bits_name: []const u8 = bitsOfFlags(registry, flags_name).?;
        const bits: FlagBitList = registry.flag_bits.get(bits_name).?;
        const width: usize = if (registry.wide_flag_bits.contains(bits_name)) 64 else 32;
        var fields: [64]?[]const u8 = @splat(null);
        for (bits.items) |bit| {
            if (bit.position >= width) {
                std.debug.print("vk-gen: {s} is past the width of {s}\n", .{ bit.name, flags_name });
                return GenerateError.UnexpectedRegistry;
            }
            // The first name given to a position keeps it; a later one is another name for the same bit.
            if (fields[bit.position] == null) {
                fields[bit.position] = try flagFieldName(arena, bits_name, bit.name);
            }
        }
        for (0..width) |position| {
            const field: []const u8 = fields[position] orelse continue;
            for (0..position) |earlier| {
                const earlier_field: []const u8 = fields[earlier] orelse continue;
                if (eql(u8, earlier_field, field)) {
                    std.debug.print("vk-gen: two bits of {s} would both be named {s}\n", .{ flags_name, field });
                    return GenerateError.FlagNameCollision;
                }
            }
        }
        const backing: []const u8 = if (width == 64) "Flags64" else "Flags";
        try addLine(arena, &lines, "pub const {s} = packed struct({s}) {{", .{ flags_name[2..], backing });
        for (0..width) |position| {
            if (fields[position]) |field| {
                try addLine(arena, &lines, "    {s}: bool = false,", .{field});
            } else {
                try addLine(arena, &lines, "    _reserved_bit_{d}: bool = false,", .{position});
            }
        }
        try lines.append(arena, "};\n");
    }
    return joinLines(arena, lines);
}

/// The generated part of `vk.zig`, before the splice: enumerations, constants, structures, commands.
fn renderSubset(arena: Allocator, registry: *const Registry) GenerateError![]const u8 {
    var structure_tags: ArrayList([]const u8) = .empty;
    const structures_text: []const u8 = try renderStructures(arena, registry, &structure_tags);
    const enumerations_text: []const u8 = try renderEnumerations(arena, registry, structure_tags.items);
    const constants_text: []const u8 = try renderConstants(arena, registry);
    const commands_text: []const u8 = try renderCommands(arena, registry);
    const flags_names: []const []const u8 = try usedFlagsTypes(arena, registry);
    const flags_text: []const u8 = try renderFlags(arena, registry, flags_names);
    return std.mem.join(arena, "\n", &.{
        enumerations_text,
        flags_text,
        constants_text,
        structures_text,
        commands_text,
    });
}

// ---- The splice: the generated part between vk.zig's hand-written parts ----

/// Commands that exist only with an extension the host may not enable (the validation layer's messenger): optional
/// in their tables.
const optional_commands = [_][]const u8{
    "vkCreateDebugUtilsMessengerEXT", "vkDestroyDebugUtilsMessengerEXT", "vkSetDebugUtilsObjectNameEXT",
};

/// A parameter whose pointer kind the registry's metadata gets wrong, and its correct text.
const ParameterFix = struct {
    wrong: []const u8,
    right: []const u8,
};

const parameter_fixes = [_]ParameterFix{
    // vkMapMemory's ppData receives the mapped address: a pointer to a pointer, not a pointer.
    .{ .wrong = "    pp_data: ?*anyopaque,", .right = "    pp_data: *?*anyopaque," },
};

/// Replaces the one occurrence of `old` in `text`.
fn replaceOnce(
    arena: Allocator,
    text: []const u8,
    old: []const u8,
    new: []const u8,
) GenerateError![]const u8 {
    const at: usize = indexOf(u8, text, old) orelse {
        std.debug.print("vk-gen: a hand edit no longer applies - the generated text has no `{s}`\n", .{old});
        return GenerateError.MalformedOutput;
    };
    if (indexOfPos(u8, text, at + old.len, old) != null) {
        std.debug.print("vk-gen: a hand edit is ambiguous - the generated text has `{s}` more than once\n", .{old});
        return GenerateError.MalformedOutput;
    }
    return std.mem.concat(arena, u8, &.{ text[0..at], new, text[at + old.len ..] });
}

/// Where `vk.zig`'s parts begin: the generated part starts with the enumerations; the debug messenger's callback
/// type, written by hand, sits just before the commands; the hand-written loading code ends the file.
const enumerations_marker: []const u8 = "// ---- Enumerations";
const callback_marker: []const u8 = "/// The debug messenger's callback";
const commands_marker: []const u8 = "// ---- Commands:";
const loading_marker: []const u8 = "// ---- Loading: the dispatch tables, filled by name ----";

/// Where `marker` begins in `text`; `text_name` names the text for the message when it is missing.
fn findMarker(
    text: []const u8,
    marker: []const u8,
    text_name: []const u8,
) GenerateError!usize {
    return indexOf(u8, text, marker) orelse {
        std.debug.print("vk-gen: {s} has no `{s}`, which the splice needs\n", .{ text_name, marker });
        return GenerateError.MalformedOutput;
    };
}

/// `vk.zig` with its generated part replaced: the hand-written head (up to the enumerations), the debug messenger's
/// callback type (before the commands) and the loading code (at the end) are kept as they are.
fn splice(
    arena: Allocator,
    current: []const u8,
    generated_text: []const u8,
) GenerateError![]const u8 {
    var generated: []const u8 = generated_text;
    for (optional_commands) |name| {
        const field_name: []const u8 = try commandField(arena, name);
        const title: []const u8 = commandTitle(name);
        const field: []const u8 = try allocPrint(arena, "    {s}: Pfn{s},", .{ field_name, title });
        const optional_field: []const u8 = try allocPrint(arena, "    {s}: ?Pfn{s},", .{ field_name, title });
        generated = try replaceOnce(arena, generated, field, optional_field);
    }
    for (parameter_fixes) |fix| {
        generated = try replaceOnce(arena, generated, fix.wrong, fix.right);
    }
    const head_end: usize = try findMarker(current, enumerations_marker, "src/vk.zig");
    const callback_start: usize = try findMarker(current, callback_marker, "src/vk.zig");
    const callback_end: usize = try findMarker(current, commands_marker, "src/vk.zig");
    const loading_start: usize = try findMarker(current, loading_marker, "src/vk.zig");
    const callback: []const u8 = std.mem.trimEnd(u8, current[callback_start..callback_end], "\n");
    const commands_at: usize = try findMarker(generated, commands_marker, "the generated text");
    return std.mem.concat(arena, u8, &.{
        current[0..head_end],
        generated[0..commands_at],
        callback,
        "\n\n",
        std.mem.trimEnd(u8, generated[commands_at..], "\n"),
        "\n\n",
        current[loading_start..],
    });
}

/// Zig source formatted as `zig fmt` formats it.
fn formatZig(arena: Allocator, source: []const u8) GenerateError![]const u8 {
    const terminated: [:0]const u8 = try arena.dupeSentinel(u8, source, 0);
    var tree: std.zig.Ast = try .parse(arena, terminated, .{});
    if (tree.errors.len > 0) {
        std.debug.print("vk-gen: the spliced vk.zig does not parse ({d} errors); the first:\n", .{tree.errors.len});
        // Each error's line and the source line it is on: almost always a generated name Zig cannot read.
        for (tree.errors[0..@min(tree.errors.len, 5)]) |parse_error| {
            const location: std.zig.Ast.Location = tree.tokenLocation(0, parse_error.token);
            const line_end: usize = location.line_end;
            std.debug.print("  line {d}: {s}\n", .{ location.line + 1, terminated[location.line_start..line_end] });
        }
        return GenerateError.MalformedOutput;
    }
    return tree.renderAlloc(arena);
}

// ---- The program ----

pub fn main(init: std.process.Init) !u8 {
    const arena: Allocator = init.arena.allocator();
    const io: Io = init.io;
    const arguments: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    if (arguments.len != 3) {
        std.debug.print("usage: vk_gen <path to vk.xml> <path to vk.zig>\n", .{});
        return 2;
    }
    const registry_path: []const u8 = arguments[1];
    const output_path: []const u8 = arguments[2];
    const cwd: Io.Dir = .cwd();
    const source: []u8 = try cwd.readFileAlloc(io, registry_path, arena, .unlimited);
    const registry: Registry = try loadRegistry(arena, source);
    const generated: []const u8 = try renderSubset(arena, &registry);
    const current: []u8 = try cwd.readFileAlloc(io, output_path, arena, .unlimited);
    const formatted: []const u8 = try formatZig(arena, try splice(arena, current, generated));
    try cwd.writeFile(io, .{ .sub_path = output_path, .data = formatted });
    var command_count: usize = 0;
    for (command_levels) |level| {
        command_count += level.commands.len;
    }
    const structure_count: usize = structures.len + opaque_structures.len;
    const constant_count: usize = constants.len + special_constants.len;
    std.debug.print("vk-gen: {d} structures, {d} enumerations, {d} constants, {d} commands -> {s}\n", .{
        structure_count,
        enumerations.len,
        constant_count,
        command_count,
        output_path,
    });
    return 0;
}

// ---- Tests: real excerpts of the registry ----

const testing = std.testing;
const testing_allocator = testing.allocator;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

const excerpt: []const u8 =
    \\<registry>
    \\  <types>
    \\    <type category="handle" parent="VkPhysicalDevice"><type>VK_DEFINE_HANDLE</type>(<name>VkDevice</name>)</type>
    \\    <type category="handle"><type>VK_DEFINE_HANDLE</type>(<name>VkPhysicalDevice</name>)</type>
    \\    <type name="VkStructureType" category="enum"/>
    \\    <type category="struct" name="VkSampleCreateInfo">
    \\      <member values="VK_STRUCTURE_TYPE_SAMPLE_CREATE_INFO">
    \\        <type>VkStructureType</type> <name>sType</name></member>
    \\      <member optional="true">const <type>void</type>* <name>pNext</name></member>
    \\      <member><type>uint32_t</type> <name>layerCount</name></member>
    \\      <member len="layerCount">const <type>char</type>* const* <name>ppLayerNames</name></member>
    \\      <member><type>float</type> <name>blendConstants</name>[4]</member>
    \\      <member><type>char</type> <name>deviceName</name>[<enum>VK_MAX_EXTENSION_NAME_SIZE</enum>]</member>
    \\      <member api="vulkansc"><type>uint32_t</type> <name>scOnly</name></member>
    \\      <member><type>VkDevice</type> <name>device</name></member>
    \\    </type>
    \\    <type category="struct" name="VkExtent2D">
    \\      <member><type>uint32_t</type> <name>width</name></member>
    \\      <member><type>uint32_t</type> <name>height</name></member>
    \\    </type>
    \\    <type category="struct" name="VkExtent2D"><member><type>float</type> <name>later</name></member></type>
    \\    <type category="funcpointer"><proto><type>VkBool32</type> <name>PFN_vkCallbackEXT</name></proto></type>
    \\    <type requires="VkQueueFlagBits" category="bitmask">typedef <type>VkFlags</type>
    \\      <name>VkQueueFlags</name>;</type>
    \\    <type requires="VkCompositeAlphaFlagBitsKHR" category="bitmask">typedef <type>VkFlags</type>
    \\      <name>VkCompositeAlphaFlagsKHR</name>;</type>
    \\  </types>
    \\  <enums name="API Constants" type="constants">
    \\    <enum type="uint32_t" value="256" name="VK_MAX_EXTENSION_NAME_SIZE"/>
    \\    <enum type="uint32_t" value="(~0U)" name="VK_QUEUE_FAMILY_IGNORED"/>
    \\  </enums>
    \\  <enums name="VkResult" type="enum">
    \\    <enum value="0" name="VK_SUCCESS"/>
    \\    <enum value="-4" name="VK_ERROR_DEVICE_LOST"/>
    \\  </enums>
    \\  <enums name="VkQueueFlagBits" type="bitmask">
    \\    <enum bitpos="0" name="VK_QUEUE_GRAPHICS_BIT"/>
    \\    <enum bitpos="1" name="VK_QUEUE_COMPUTE_BIT"/>
    \\  </enums>
    \\  <enums name="VkCompositeAlphaFlagBitsKHR" type="bitmask">
    \\    <enum bitpos="0" name="VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR"/>
    \\  </enums>
    \\  <enums name="VkAccessFlagBits2" type="bitmask" bitwidth="64">
    \\    <enum bitpos="40" name="VK_ACCESS_2_FAR_BIT"/>
    \\  </enums>
    \\  <commands>
    \\    <command api="vulkan,vulkanbase"><proto><type>VkResult</type> <name>vkCreateDevice</name></proto>
    \\      <param><type>VkPhysicalDevice</type> <name>physicalDevice</name></param></command>
    \\    <command api="vulkansc"><proto><type>VkResult</type> <name>vkCreateDevice</name></proto>
    \\      <param><type>VkPhysicalDevice</type> <name>scVariant</name></param></command>
    \\    <command name="vkCreateDeviceKHR" alias="vkCreateDevice"/>
    \\  </commands>
    \\  <feature api="vulkan" name="VK_VERSION_1_3" number="1.3">
    \\    <require>
    \\      <enum extends="VkStructureType" extnumber="45" offset="0" name="VK_STRUCTURE_TYPE_PROMOTED"/>
    \\    </require>
    \\  </feature>
    \\  <extensions>
    \\    <extension name="VK_KHR_swapchain" number="2" supported="vulkan">
    \\      <require>
    \\        <enum value="70" name="VK_KHR_SWAPCHAIN_SPEC_VERSION"/>
    \\        <enum value="&quot;VK_KHR_swapchain&quot;" name="VK_KHR_SWAPCHAIN_EXTENSION_NAME"/>
    \\        <enum offset="4" extends="VkResult" dir="-" name="VK_ERROR_OUT_OF_DATE_KHR"/>
    \\        <enum extends="VkResult" name="VK_ERROR_OUT_OF_DATE" alias="VK_ERROR_OUT_OF_DATE_KHR"/>
    \\        <enum bitpos="5" extends="VkQueueFlagBits" name="VK_QUEUE_VIDEO_BIT_KHR"/>
    \\        <enum extends="VkQueueFlagBits" name="VK_QUEUE_GFX_BIT" alias="VK_QUEUE_GRAPHICS_BIT"/>
    \\      </require>
    \\    </extension>
    \\    <extension name="VK_EXT_withdrawn" number="9" supported="disabled">
    \\      <require><enum bitpos="7" extends="VkQueueFlagBits" name="VK_QUEUE_RESERVED_7_BIT_EXT"/></require>
    \\    </extension>
    \\  </extensions>
    \\</registry>
;

test "vk_gen: enumerant values - direct, bit positions, extension blocks, aliases" {
    var registry: Registry = try loadRegistry(testing_allocator, excerpt);
    defer registry.deinit(testing_allocator);
    try expectEqual(@as(?i128, 0), enumerantNumber(&registry, "VK_SUCCESS"));
    try expectEqual(@as(?i128, -4), enumerantNumber(&registry, "VK_ERROR_DEVICE_LOST"));
    try expectEqual(@as(?i128, 2), enumerantNumber(&registry, "VK_QUEUE_COMPUTE_BIT"));
    // A 64-bit flag beyond 32 bits, and its enumeration recorded as wide.
    try expectEqual(@as(?i128, 1 << 40), enumerantNumber(&registry, "VK_ACCESS_2_FAR_BIT"));
    try expectEqual(true, registry.wide_flag_bits.contains("VkAccessFlagBits2"));
    // Extension 2's block, offset 4, negated: the header's VK_ERROR_OUT_OF_DATE_KHR.
    try expectEqual(@as(?i128, -1000001004), enumerantNumber(&registry, "VK_ERROR_OUT_OF_DATE_KHR"));
    try expectEqual(@as(?i128, -1000001004), enumerantNumber(&registry, "VK_ERROR_OUT_OF_DATE"));
    // A promoted enumerant names its original extension's number.
    try expectEqual(@as(?i128, 1000044000), enumerantNumber(&registry, "VK_STRUCTURE_TYPE_PROMOTED"));
    // A string constant is not a number; an unknown name has no value.
    try expectEqual(@as(?i128, null), enumerantNumber(&registry, "VK_KHR_SWAPCHAIN_EXTENSION_NAME"));
    try expectEqual(@as(?i128, null), enumerantNumber(&registry, "VK_NOT_A_NAME"));
}

test "vk_gen: types, commands and API constants are indexed by name" {
    var registry: Registry = try loadRegistry(testing_allocator, excerpt);
    defer registry.deinit(testing_allocator);
    // A handle named by its <name> child; a structure by its attribute - the first definition kept.
    try expectEqualStrings("handle", registry.attribute(registry.types.get("VkDevice").?, "category").?);
    // A function-pointer type names itself inside its <proto>.
    try expectEqualStrings("funcpointer", registry.attribute(registry.types.get("PFN_vkCallbackEXT").?, "category").?);
    const extent: *const xml.Element = registry.types.get("VkExtent2D").?;
    try expectEqual(@as(usize, 2), registry.document.childrenOf(extent).len);
    // The Vulkan SC variant of a command is skipped; an alias is indexed under its own name.
    const create_device: *const xml.Element = registry.commands.get("vkCreateDevice").?;
    const parameter: *const xml.Element = registry.document.child(create_device, "param").?;
    try expectEqualStrings("physicalDevice", registry.childText(parameter, "name").?);
    const alias_command: *const xml.Element = registry.commands.get("vkCreateDeviceKHR").?;
    try expectEqualStrings("vkCreateDevice", registry.attribute(alias_command, "alias").?);
    // API constants keep their C text.
    try expectEqualStrings("256", registry.api_constants.get("VK_MAX_EXTENSION_NAME_SIZE").?);
    try expectEqualStrings("(~0U)", registry.api_constants.get("VK_QUEUE_FAMILY_IGNORED").?);
}

test "vk_gen: flags - bits gathered from the registry, named, placed" {
    var registry: Registry = try loadRegistry(testing_allocator, excerpt);
    defer registry.deinit(testing_allocator);
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // The core bits and an enabled extension's; not the alias, not the disabled extension's.
    const queue_bits: FlagBitList = registry.flag_bits.get("VkQueueFlagBits").?;
    try expectEqual(@as(usize, 3), queue_bits.items.len);
    try expectEqualStrings("VkQueueFlags", registry.flags_of_bits.get("VkQueueFlagBits").?);
    // Names: the prefix and BIT left out; an extension's bit keeps its tag; the enumeration's own tag is dropped,
    // and a keyword quoted.
    try expectEqualStrings("graphics", try flagFieldName(arena, "VkQueueFlagBits", "VK_QUEUE_GRAPHICS_BIT"));
    try expectEqualStrings("video_khr", try flagFieldName(arena, "VkQueueFlagBits", "VK_QUEUE_VIDEO_BIT_KHR"));
    const composite_bits: []const u8 = "VkCompositeAlphaFlagBitsKHR";
    const opaque_field: []const u8 = try flagFieldName(arena, composite_bits, "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR");
    try expectEqualStrings("@\"opaque\"", opaque_field);
    try expectEqualStrings("@\"4\"", try flagFieldName(arena, "VkSampleCountFlagBits", "VK_SAMPLE_COUNT_4_BIT"));
    const stage_prefix: []const u8 = try flagBitsPrefix(arena, "VkPipelineStageFlagBits2");
    try expectEqualStrings("VK_PIPELINE_STAGE_2_", stage_prefix);
    // The structure: a field at each named position, reserved ones between, 32 bits in all.
    const text: []const u8 = try renderFlags(arena, &registry, &.{"VkQueueFlags"});
    try expectEqual(true, indexOf(u8, text, "pub const QueueFlags = packed struct(Flags) {") != null);
    try expectEqual(true, indexOf(u8, text, "    graphics: bool = false,\n    compute: bool = false,\n") != null);
    const around_video: []const u8 = "    _reserved_bit_4: bool = false,\n    video_khr: bool = false,\n";
    try expectEqual(true, indexOf(u8, text, around_video) != null);
    try expectEqual(true, indexOf(u8, text, "    _reserved_bit_31: bool = false,\n};") != null);
}

test "vk_gen: a structure and a command type render as Zig" {
    var registry: Registry = try loadRegistry(testing_allocator, excerpt);
    defer registry.deinit(testing_allocator);
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // Members: sType's own value, pointers null, numbers and arrays zero, a named array bound's value, a handle's
    // null - and the Vulkan SC member left out.
    var lines: Lines = .empty;
    var structure_tags: ArrayList([]const u8) = .empty;
    try renderStructure(arena, &registry, "SampleCreateInfo", &lines, &structure_tags);
    try expectEqualStrings(
        \\pub const SampleCreateInfo = extern struct {
        \\    s_type: StructureType = .sample_create_info,
        \\    p_next: ?*const anyopaque = null,
        \\    layer_count: u32 = 0,
        \\    pp_layer_names: ?[*]const [*:0]const u8 = null,
        \\    blend_constants: [4]f32 = @splat(0),
        \\    device_name: [256]u8 = @splat(0),
        \\    device: Device = .null_handle,
        \\};
        \\
    , try joinLines(arena, lines));
    try expectEqual(@as(usize, 1), structure_tags.items.len);
    // A command: the Vulkan definition's parameters (not the Vulkan SC variant's), and an alias under its own name.
    var command_lines: Lines = .empty;
    try renderCommandType(arena, &registry, "vkCreateDeviceKHR", &command_lines);
    try expectEqualStrings(
        \\pub const PfnCreateDeviceKHR = *const fn (
        \\    physical_device: PhysicalDevice,
        \\) callconv(call_conv) Result;
        \\
    , try joinLines(arena, command_lines));
}

test "vk_gen: names Zig cannot read bare are quoted" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    try expectEqualStrings("transfer_dst", try quotedIfNeeded(arena, "transfer_dst"));
    try expectEqualStrings("@\"opaque\"", try quotedIfNeeded(arena, "opaque"));
    try expectEqualStrings("@\"inline\"", try quotedIfNeeded(arena, "inline"));
    try expectEqualStrings("@\"bool\"", try quotedIfNeeded(arena, "bool"));
    try expectEqualStrings("@\"4\"", try quotedIfNeeded(arena, "4"));
}

test "vk_gen: addLine takes a tuple of format arguments" {
    comptime requireFormatTuple(@TypeOf(.{ "name", 4 }));
    comptime requireFormatTuple(@TypeOf(.{}));
}
